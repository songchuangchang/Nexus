import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'logger_service.dart';
import 'storage_service.dart';

/// v1.7.38（待办 F-泛化）：GitHub 内容统一拉取服务。
///
/// 设计目标（用户拍板：零配置自适应，国内外通吃）：
/// 1. 用户配置的代理 = 最高优先级覆盖（排最前，失败仍走自适应链）
/// 2. 自适应探测：成功记忆路由 → 直连短超时先行 → 失败切镜像链
/// 3. 对冲并发（hedged）：首个候选 2 秒未决胜 → 并行发出其余候选，谁先成功用谁
/// 4. 成功记忆持久化（SharedPreferences），下次优先该路由
/// 5. 超时拆分：建连/首包短超时（8s） + 下载总长超时（60s，小文件）分开
/// 6. 全链路日志（待办 G）：试了哪个候选、失败原因全部落日志
///
/// 候选序列：
///   [user-proxy?] → [上次成功路由提前] → direct → ghproxy.net →
///   mirror.ghproxy.com → gh-proxy.com → jsdelivr(raw 互转)
///
/// 大文件（APK 等）请用 [resolveBestUrl] 选路由后交给下载器，
/// 避免对冲并发浪费流量。
class GitHubContentFetcher {
  GitHubContentFetcher._();

  static const String _memoryKey = 'gh_fetch_route_memory_v1';

  /// 内置镜像前缀（ghproxy 三兄弟，与 build87 app_update 同一条链）
  static const List<String> mirrorPrefixes = [
    'https://ghproxy.net/',
    'https://mirror.ghproxy.com/',
    'https://gh-proxy.com/',
  ];

  static const Duration hedgeDelay = Duration(seconds: 2);
  static const Duration connectTimeout = Duration(seconds: 8);
  static const Duration defaultTotalTimeout = Duration(seconds: 60);

  static String? _rememberedRoute;
  static bool _memoryLoaded = false;

  static final LoggerService _logger = LoggerService.instance;

  /// 仅测试用：清空记忆
  static void clearMemoryForTest() {
    _rememberedRoute = null;
    _memoryLoaded = true;
  }

  static Future<void> _loadMemory() async {
    if (_memoryLoaded) return;
    _memoryLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _rememberedRoute = prefs.getString(_memoryKey);
    } catch (e) { debugPrint('catch 静默异常: $e'); }
  }

  static Future<void> _rememberRoute(String route) async {
    if (_rememberedRoute == route) return;
    _rememberedRoute = route;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_memoryKey, route);
    } catch (e) { debugPrint('catch 静默异常: $e'); }
  }

  /// raw.githubusercontent.com → fastly.jsdelivr.net 镜像
  static String? jsdelivrMirror(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host != 'raw.githubusercontent.com') return null;
    final segs = uri.pathSegments;
    if (segs.length < 4) return null;
    return 'https://fastly.jsdelivr.net/gh/${segs[0]}/${segs[1]}@${segs[2]}/${segs.sublist(3).join('/')}';
  }

  /// fastly.jsdelivr.net/gh/… → raw.githubusercontent.com 原链（反向互转）
  static String? jsdelivrToRaw(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        (uri.host != 'fastly.jsdelivr.net' && uri.host != 'cdn.jsdelivr.net')) {
      return null;
    }
    final segs = uri.pathSegments;
    // /gh/{owner}/{repo}@{branch}/{path...}
    if (segs.length < 4 || segs[0] != 'gh') return null;
    final repoSeg = segs[2]; // repo@branch
    final at = repoSeg.indexOf('@');
    if (at <= 0 || at >= repoSeg.length - 1) return null;
    final repo = repoSeg.substring(0, at);
    final branch = repoSeg.substring(at + 1);
    final path = segs.sublist(3).join('/');
    return 'https://raw.githubusercontent.com/${segs[1]}/$repo/$branch/$path';
  }

  /// 公共：判断 URL 是否 GitHub 系（含 jsdelivr CDN）
  static bool isGitHubUrl(String url) => _isGitHubLike(url);

  static bool _isGitHubLike(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    return host == 'raw.githubusercontent.com' ||
        host == 'github.com' ||
        host == 'codeload.github.com' ||
        host == 'objects.githubusercontent.com' ||
        host == 'api.github.com' ||
        host == 'fastly.jsdelivr.net' ||
        host == 'cdn.jsdelivr.net';
  }

  static List<_Candidate> _candidates(String url, String? userProxy) {
    final list = <_Candidate>[];
    final seen = <String>{};
    void add(String route, String u) {
      if (u.isNotEmpty && seen.add(u)) list.add(_Candidate(route, u));
    }

    final proxy = userProxy?.trim() ?? '';
    if (proxy.isNotEmpty) {
      // 代理前缀需以 / 结尾再拼接，否则 host 会和原 URL 粘连
      // （如 https://mirror.ghproxy.com + https://… → host 变成 mirror.ghproxy.comhttps）。
      var p = proxy;
      if (!p.endsWith('/')) p = '$p/';
      final joined = '$p$url';
      final proxyHost = Uri.tryParse(proxy)?.host ?? '';
      final joinedHost = Uri.tryParse(joined)?.host ?? '';
      // 拼接结果的 host 必须等于代理自身 host，否则视为配置非法，跳过该候选
      if (proxyHost.isNotEmpty && joinedHost == proxyHost) {
        add('user-proxy', joined);
      }
    }
    add('direct', url);
    // GitHub 系 URL 才挂镜像前缀；jsdelivr URL 先转回 raw 再挂
    final rawish = jsdelivrToRaw(url) ?? url;
    if (_isGitHubLike(rawish)) {
      for (final p in mirrorPrefixes) {
        add('mirror:${Uri.parse(p).host}', '$p$rawish');
      }
      final jsd = jsdelivrMirror(rawish);
      if (jsd != null) add('jsdelivr', jsd);
      // 若入参是 jsdelivr，raw 直连也作候选（jsdelivr 近年不稳）
      final raw = jsdelivrToRaw(url);
      if (raw != null) add('direct-raw', raw);
    }
    // 成功记忆提前（user-proxy 仍最前）
    final remembered = _rememberedRoute;
    if (remembered != null) {
      final idx = list.indexWhere((c) => c.route == remembered);
      if (idx > 0) {
        final c = list.removeAt(idx);
        list.insert(proxy.isNotEmpty ? 1 : 0, c);
      }
    }
    return list;
  }

  /// 测试用：暴露候选 URL 列表（route:url），校验代理拼接等纯逻辑
  @visibleForTesting
  static List<String> debugCandidateUrls(String url, String? userProxy) =>
      _candidates(url, userProxy).map((c) => '${c.route}:${c.url}').toList();

  static Future<Uint8List> _tryFetch(
    _Candidate c,
    Map<String, String> headers,
    Duration totalTimeout,
    String tag,
  ) async {
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(c.url));
      req.headers.addAll(headers);
      // 建连+首包短超时
      final resp = await client.send(req).timeout(connectTimeout);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        // 排空 body 以复用连接
        try {
          await resp.stream.drain<void>();
        } catch (e) { debugPrint('catch 静默异常: $e'); }
        throw Exception('HTTP ${resp.statusCode}');
      }
      // 下载总长超时（拆分：连上后不再被建连超时卡）
      final bytes = await resp.stream.toBytes().timeout(totalTimeout);
      _logger.info('[GhFetch] $tag 成功 via ${c.route} (${bytes.length} 字节)',
          tag: 'Net');
      return bytes;
    } finally {
      client.close();
    }
  }

  /// 拉取内容字节（对冲并发）。失败抛 Exception（消息含每个候选的失败原因）。
  static Future<Uint8List> fetchBytes(
    String url, {
    String? userProxy,
    Map<String, String>? headers,
    Duration totalTimeout = defaultTotalTimeout,
    String tag = 'fetch',
  }) async {
    await _loadMemory();
    final cands = _candidates(url, userProxy);
    final hdrs = <String, String>{
      'User-Agent': 'Nexus-App/1.0',
      ...?headers,
    };
    _logger.info(
        '[GhFetch] $tag 开始，候选 ${cands.length} 个: ${cands.map((c) => c.route).join(' → ')}',
        tag: 'Net');

    final completer = Completer<Uint8List>();
    final failures = <String>[];
    var launched = 0;
    var failedCount = 0;
    var allLaunched = false;

    void launch(_Candidate c) {
      launched++;
      _tryFetch(c, hdrs, totalTimeout, tag).then((bytes) {
        if (!completer.isCompleted) {
          completer.complete(bytes);
          unawaited(_rememberRoute(c.route));
        }
      }).catchError((Object e) {
        failedCount++;
        failures.add('${c.route}: $e');
        // build145：候选级失败降到 VERBOSE。原因不是它不该记，而是**上层已经有一条
        // 汇总 WARN 把每个候选的失败原因都拼进去了**（`全部 N 个候选失败 — …`），
        // 于是这里是「同一个事实记两遍、且按候选数放大」：真机 43 秒里刷出 50+ 行，
        // 把日志里真正要看的东西（键盘、通知、上游断连）全挤掉了。汇总那条照旧保留。
        _logger.verbose('[GhFetch] $tag 候选 ${c.route} 失败: $e', tag: 'Net');
        if (allLaunched && failedCount >= launched && !completer.isCompleted) {
          completer.completeError(
              Exception('全部 ${cands.length} 个候选失败 — ${failures.join(' | ')}'));
        }
      });
    }

    launch(cands.first);
    unawaited(Future.delayed(hedgeDelay, () {
      if (completer.isCompleted) return;
      for (final c in cands.skip(1)) {
        if (completer.isCompleted) break;
        _logger.info(
            '[GhFetch] $tag ${hedgeDelay.inSeconds}s 未决胜，对冲并发 ${c.route}',
            tag: 'Net');
        launch(c);
      }
      allLaunched = true;
      // 首个候选在 hedgeDelay 内就已失败且其余尚未启动的极端情况
      if (failedCount >= launched && !completer.isCompleted) {
        completer.completeError(
            Exception('全部 ${cands.length} 个候选失败 — ${failures.join(' | ')}'));
      }
    }));
    return completer.future;
  }

  /// 拉取文本（UTF-8）
  static Future<String> fetchString(
    String url, {
    String? userProxy,
    Map<String, String>? headers,
    Duration totalTimeout = defaultTotalTimeout,
    String tag = 'fetch',
  }) async {
    final bytes = await fetchBytes(url,
        userProxy: userProxy,
        headers: headers,
        totalTimeout: totalTimeout,
        tag: tag);
    return utf8Decode(bytes);
  }

  /// 便捷：自动读取用户配置的 GitHub 代理作为最高优先级覆盖
  ///
  /// build139（静默降级修复）：读配置失败原先 `catch (_) => null`，等价于
  /// **把用户自己设的代理悄悄丢掉**、直连 GitHub（在需要代理的网络下就表现为
  /// 「怎么又超时了」，且日志里没有任何线索）。现在留一条 warn 痕迹。
  static Future<String?> _userProxyFromStorage() async {
    try {
      final cfg = await StorageService.instance.getWebSearchConfig();
      final p = cfg.githubProxyUrl.trim();
      return p.isEmpty ? null : p;
    } catch (e) {
      _logger.warn(
          '[GhFetch] 读取用户 GitHub 代理失败，本次按「无代理」直连：$e',
          tag: 'Net');
      return null;
    }
  }

  /// 拉取文本（自动读用户代理）
  static Future<String> fetchText(
    String url, {
    Map<String, String>? headers,
    Duration totalTimeout = defaultTotalTimeout,
    String tag = 'fetch',
  }) async {
    final proxy = await _userProxyFromStorage();
    return fetchString(url,
        userProxy: proxy,
        headers: headers,
        totalTimeout: totalTimeout,
        tag: tag);
  }

  /// 大文件选路由（自动读用户代理）
  static Future<String> resolveBest(
    String url, {
    Map<String, String>? headers,
    String tag = 'resolve',
  }) async {
    final proxy = await _userProxyFromStorage();
    return resolveBestUrl(url, userProxy: proxy, headers: headers, tag: tag);
  }

  /// 大文件场景：串行探测选最优 URL（建连短超时，拉到响应头即关闭），
  /// 调用方拿到 URL 后用下载器自行下载。
  static Future<String> resolveBestUrl(
    String url, {
    String? userProxy,
    Map<String, String>? headers,
    String tag = 'resolve',
  }) async {
    await _loadMemory();
    final cands = _candidates(url, userProxy);
    _logger.info(
        '[GhFetch] $tag 选路由，候选: ${cands.map((c) => c.route).join(' → ')}',
        tag: 'Net');
    Object? lastErr;
    for (final c in cands) {
      final client = http.Client();
      try {
        final req = http.Request('GET', Uri.parse(c.url));
        req.headers.addAll({
          'User-Agent': 'Nexus-App/1.0',
          // 只探测首包，不拉全量
          'Range': 'bytes=0-0',
          ...?headers,
        });
        final resp = await client.send(req).timeout(connectTimeout);
        await resp.stream.drain<void>();
        // 200 或 206(Range) 均视为可用
        if ((resp.statusCode >= 200 && resp.statusCode < 300) ||
            resp.statusCode == 206) {
          _logger.info('[GhFetch] $tag 选中 ${c.route}', tag: 'Net');
          unawaited(_rememberRoute(c.route));
          return c.url;
        }
        lastErr = 'HTTP ${resp.statusCode}';
        _logger.warn('[GhFetch] $tag ${c.route} → HTTP ${resp.statusCode}',
            tag: 'Net');
      } catch (e) {
        lastErr = e;
        _logger.warn('[GhFetch] $tag ${c.route} 探测失败: $e', tag: 'Net');
      } finally {
        client.close();
      }
    }
    throw Exception('所有候选均不可用: $lastErr');
  }
}

class _Candidate {
  _Candidate(this.route, this.url);
  final String route;
  final String url;
}

/// UTF-8 解码
String utf8Decode(List<int> bytes) => utf8.decode(bytes);
