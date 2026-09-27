import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'logger_service.dart';
import '../models/web_search_config.dart';
import 'package:flutter/foundation.dart';

/// 搜索结果项（统一格式：Bing / Tavily / SearXNG 都转成这个）
class SearchResultItem {
  final String title;
  final String url;
  final String snippet;

  /// 来源（'bing' / 'tavily' / 'searxng'）用于调试
  final String provider;

  /// 发布时间（可选）
  final String? publishedDate;

  SearchResultItem({
    required this.title,
    required this.url,
    required this.snippet,
    this.provider = 'bing',
    this.publishedDate,
  });
}

/// v1.7.24 (#1)：搜索后端策略接口 —— 把按 provider 的 switch 分发改为多态策略。
///
/// 每个搜索后端实现 [search]（通用搜索）与 [test]（连接测试）。
/// 注册表 [kSearchEngines]：加新引擎只需
///   ① enum 加值 → ② 新增策略类 → ③ 在 [kSearchEngines] 注册一行
/// 无需再改分发逻辑（原 testConnection / searchGeneral 两处 switch 已移除）。
abstract class SearchEngine {
  WebSearchProvider get provider;
  Future<List<SearchResultItem>> search(String query, WebSearchConfig cfg);
  Future<(bool ok, String message, int? latencyMs)> test(WebSearchConfig cfg);
}

/// 搜索服务（v1.3.0 重构，v1.3.9 扩展 7 个搜索后端）
///
/// v1.3.9 支持的搜索后端：
///   1) Bing 直爬（默认，无需 Key）
///   2) Tavily API（需 Key）
///   3) SearXNG（自建/公共实例）
///   4) DuckDuckGo 直爬（无需 Key）
///   5) SerpAPI 聚合搜索（需 Key，100次/月免费）
///   6) Brave Search API（需 Key，2000次/月免费）
///   7) Google CSE 自定义搜索（需 Key + cx，100次/天免费）
class WebSearchService {
  static const _bingUrl = 'https://cn.bing.com/search';
  static const _ddgUrl = 'https://html.duckduckgo.com/html/';
  static const _tavilyUrl = 'https://api.tavily.com/search';
  static const _serpApiUrl = 'https://serpapi.com/search';
  static const _braveUrl = 'https://api.search.brave.com/res/v1/web/search';
  static const _googleCseUrl = 'https://www.googleapis.com/customsearch/v1';
  static const _ua =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Mobile Safari/537.36';

  // v1.7.1 fix m3: 抽出已知可信 APK 域名常量，避免 searchApkLinks 两处重复定义
  static const _knownApkDomains = [
    'dldir1.qq.com',
    'dldir1v6.qq.com',
    'downv6.qq.com',
    'telegram.org',
    'whatsapp.com',
    'douyin.com',
    'apkpure.com',
    'apkmirror.com',
    'coolapk.com',
    'uptodown.com',
    'f-droid.org',
    'apkmonk.com',
    'apksos.com',
  ];

  static final _logger = LoggerService.instance;

  // ==========================================================================
  // 0) 测试搜索连接（v1.3.1）：设置页"测试连接"按钮用
  //    返回 (ok, message, latencyMs?)
  // ==========================================================================
  static Future<(bool ok, String message, int? latencyMs)> testConnection(
      WebSearchConfig cfg) async {
    final provider = cfg.effectiveProvider();
    _logger.info('[WebSearch] Test connection via=${provider.name}', tag: 'WS');
    final t0 = DateTime.now();

    try {
      final engine = kSearchEngines[provider];
      if (engine == null) {
        return (false, '未知搜索后端：${provider.name}', null);
      }
      return await engine.test(cfg);
    } catch (e) {
      final ms = DateTime.now().difference(t0).inMilliseconds;
      _logger.error('[WebSearch] Test connection failed via=${provider.name}',
          error: e, tag: 'WS');
      return (false, '异常 / Exception: $e', ms);
    }
  }

  // ==========================================================================
  // 1) 通用搜索入口：聊天时 AI RAG 用
  // ==========================================================================
  /// 空结果常量（命名记录的第一个位置需要明确类型，`const []` 会推成 `List<dynamic>`）。
  static const List<SearchResultItem> _emptyResults = <SearchResultItem>[];

  /// build139（静默降级修复）：搜索的**带原因**版本。
  ///
  /// 原 `searchGeneral` 把「主后端炸了 + Bing 兜底也炸了」和「一切正常、只是没搜到」
  /// 都返回成 `[]`，而消费端（builtin_plugins.dart 的 SearchPlugin）拿空列表渲染
  /// 「未找到有效结果」并原样回灌给模型 —— 于是网络/Key/限流故障被说成「网上没有」，
  /// 模型会据此降低自信甚至改口，用户也完全看不出是服务故障。
  /// [error] 非 null 表示**至少一条**真实失败（含兜底），null 表示确实零结果。
  static Future<(List<SearchResultItem>, String? error)> searchGeneralDetailed(
    String query,
    WebSearchConfig cfg,
  ) async {
    if (!cfg.webSearchEnabled) {
      _logger.info('[WebSearch] Disabled by user (总开关关闭)，跳过搜索', tag: 'WS');
      return (_emptyResults, null);
    }
    if (query.trim().isEmpty) return (_emptyResults, null);

    final provider = cfg.effectiveProvider();
    _logger.info(
      '[WebSearch] general search via=${provider.name} query="$query"',
      tag: 'WS',
    );

    try {
      final engine = kSearchEngines[provider];
      if (engine == null) {
        // 没注册引擎同样是"能力缺失"而不是"没结果"，必须报出去。
        return (_emptyResults, '未注册搜索后端：${provider.name}');
      }
      return (await engine.search(query, cfg), null);
    } catch (e, st) {
      _logger.error(
        '[WebSearch] searchGeneral failed via=${provider.name}',
        error: e,
        stack: st,
        tag: 'WS',
      );
      // 失败时降级 Bing（如果本来不是 Bing）
      if (provider != WebSearchProvider.bing) {
        try {
          _logger.info(
              '[WebSearch] fallback to Bing after ${provider.name} failure',
              tag: 'WS');
          return (await _bingGeneralSearch(query), null);
        } catch (e2) {
          // build139：兜底也失败原先是 `catch (_) => []`，一个字都不留。
          // 两跳都记进同一条 error 里，导出日志时能一眼看出"主链路 + 兜底全灭"。
          _logger.error(
            '[WebSearch] Bing 兜底同样失败（${provider.name} → Bing 全链路不可用）',
            error: e2,
            tag: 'WS',
          );
          return (_emptyResults, '${provider.name} 与 Bing 兜底均失败：$e2');
        }
      }
      return (_emptyResults, '${provider.name} 搜索失败：$e');
    }
  }

  static Future<List<SearchResultItem>> searchGeneral(
    String query,
    WebSearchConfig cfg,
  ) async {
    final (results, _) = await searchGeneralDetailed(query, cfg);
    return results;
  }

  /// 解析搜索服务返回的 JSON 对象；失败返回 null 并记一条 warn。
  ///
  /// 全量缺陷扫描修复：5 个 provider（Tavily / SearXNG / SerpAPI / Brave /
  /// Google CSE）此前都直接写
  /// `jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>`，
  /// 与各自的既有约定「失败就 `return []` 并 warn」**不一致**：
  ///   · 返回 HTML 时（SearXNG 未启用 `format=json`、网关拦截页）→ FormatException；
  ///   · 返回 JSON 数组/标量时 → `as Map` 抛 TypeError
  ///     （它属 `Error` 而非 `Exception`，调用方 `on Exception` 兜不住）。
  /// 统一收敛到与「非 200」分支相同的失败语义，避免搜索异常冒到 UI。
  static Map<String, dynamic>? _decodeJsonObject(String body, String provider) {
    if (body.isEmpty) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (e) {
      _logger.warn(
          '[WebSearch] $provider 返回的不是合法 JSON（可能被网关拦截）：${e.message}',
          tag: 'WS');
      return null;
    }
    if (decoded is! Map<String, dynamic>) {
      _logger.warn(
          '[WebSearch] $provider 返回结构异常：期望 JSON 对象，实际为 '
          '${decoded.runtimeType}',
          tag: 'WS');
      return null;
    }
    return decoded;
  }

  // ==========================================================================
  // 2) Tavily API
  //    POST https://api.tavily.com/search
  //    body: { api_key, query, search_depth, max_results, ... }
  // ==========================================================================
  static Future<List<SearchResultItem>> _tavilySearch(
    String query,
    WebSearchConfig cfg,
  ) async {
    if (cfg.tavilyApiKey.trim().isEmpty) {
      _logger.warn('[WebSearch] Tavily API Key empty, skipping', tag: 'WS');
      return [];
    }
    final body = jsonEncode({
      'api_key': cfg.tavilyApiKey.trim(),
      'query': query,
      // v1.3.5：auto=AI自决深度，默认 basic，AI 可通过 <search depth="advanced"/> 覆盖
      'search_depth':
          cfg.tavilySearchDepth == 'advanced' ? 'advanced' : 'basic',
      // build98：tavilyAutoMaxResults=true（自动档）时不传 max_results，
      // 交由服务端/AI 决定条数；固定档保留原 clamp 行为
      if (!cfg.tavilyAutoMaxResults)
        'max_results': cfg.tavilyMaxResults.clamp(3, 10),
      'include_answer': false,
      'include_raw_content': false,
      'include_images': false,
    });
    final resp = await http
        .post(
          Uri.parse(_tavilyUrl),
          headers: {
            'Content-Type': 'application/json',
            'User-Agent': 'AIChat-Android/1.3',
            'Accept': 'application/json',
          },
          body: body,
        )
        .timeout(const Duration(seconds: 20));

    if (resp.statusCode != 200) {
      _logger.warn(
          '[WebSearch] Tavily HTTP ${resp.statusCode}: '
          '${resp.body.length <= 200 ? resp.body : resp.body.substring(0, 200)}',
          tag: 'WS');
      return [];
    }
    final data =
        _decodeJsonObject(utf8.decode(resp.bodyBytes), 'Tavily');
    if (data == null) return [];
    final list = data['results'] as List<dynamic>? ?? [];
    final results = <SearchResultItem>[];
    for (final item in list) {
      if (item is! Map<String, dynamic>) continue;
      final url = (item['url'] as String? ?? '').trim();
      if (url.isEmpty) continue;
      results.add(SearchResultItem(
        title: item['title'] as String? ?? url,
        url: url,
        snippet: item['content'] as String? ?? item['snippet'] as String? ?? '',
        provider: 'tavily',
        publishedDate: item['published_date'] as String?,
      ));
    }
    return results;
  }

  // ==========================================================================
  // 3) SearXNG（可选自建/公共实例）
  //    GET {instance}/search?q=xxx&format=json
  // ==========================================================================
  static Future<List<SearchResultItem>> _searxngSearch(
    String query,
    WebSearchConfig cfg,
  ) async {
    final base = cfg.searxngInstanceUrl.trim();
    if (base.isEmpty) return [];
    final instance =
        base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final url = '$instance/search?q=${Uri.encodeComponent(query)}'
        '&format=json&language=zh-CN&safesearch=1';
    final resp = await http.get(
      Uri.parse(url),
      headers: {
        'User-Agent': _ua,
        'Accept': 'application/json',
      },
    ).timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) {
      _logger.warn('[WebSearch] SearXNG HTTP ${resp.statusCode}', tag: 'WS');
      return [];
    }
    final data =
        _decodeJsonObject(utf8.decode(resp.bodyBytes), 'SearXNG');
    if (data == null) return [];
    final list = data['results'] as List<dynamic>? ?? [];
    final results = <SearchResultItem>[];
    for (final item in list) {
      if (item is! Map<String, dynamic>) continue;
      final u = (item['url'] as String? ?? '').trim();
      if (u.isEmpty) continue;
      results.add(SearchResultItem(
        title: item['title'] as String? ?? u,
        url: u,
        snippet: item['content'] as String? ?? '',
        provider: 'searxng',
        publishedDate: item['publishedDate'] as String?,
      ));
    }
    return results;
  }

  // ==========================================================================
  // v1.3.9 新增 4 个搜索后端实现
  // ==========================================================================

  // --- DuckDuckGo HTML 直爬（无需 Key） ---
  // POST https://html.duckduckgo.com/html/ body: q=xxx
  static Future<List<SearchResultItem>> _duckDuckGoSearch(String query) async {
    try {
      final resp = await http.post(
        Uri.parse(_ddgUrl),
        headers: {
          'User-Agent': _ua,
          'Accept': 'text/html,application/xhtml+xml',
          'Accept-Language': 'zh-CN,zh;q=0.9',
        },
        body: {'q': query, 'b': '1'},
      ).timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        _logger.warn('[WebSearch] DDG HTTP ${resp.statusCode}', tag: 'WS');
        return [];
      }
      final html = utf8.decode(resp.bodyBytes, allowMalformed: true);
      return _parseDdgResults(html);
    } catch (e, st) {
      _logger.error('[WebSearch] DDG search failed',
          error: e, stack: st, tag: 'WS');
      return [];
    }
  }

  /// 解析 DuckDuckGo HTML 结果页（结果链接 class="result__a"）
  static List<SearchResultItem> _parseDdgResults(String html) {
    final results = <SearchResultItem>[];
    // 结果链接：<a class="result__a" href="//duckduckgo.com/l/?uddg=<encoded url>">title</a>
    final linkRe = RegExp(
      r'<a[^>]+class="result__a"[^>]+href="([^"]+)"[^>]*>(.*?)</a>',
      caseSensitive: false,
      dotAll: true,
    );
    // 摘要：<a class="result__snippet">snippet</a>
    final snippetRe = RegExp(
      r'<a[^>]+class="result__snippet"[^>]*>(.*?)</a>',
      caseSensitive: false,
      dotAll: true,
    );

    String stripHtml(String s) => s
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .trim()
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&nbsp;', ' ');

    String decodeUddg(String href) {
      // DuckDuckGo 链接形式：//duckduckgo.com/l/?uddg=<URL-encoded real URL>&rut=...
      // 或：https://duckduckgo.com/l/?uddg=...
      final m = RegExp(r'uddg=([^&]+)').firstMatch(href);
      if (m != null) {
        return Uri.decodeComponent(m.group(1)!);
      }
      // 不是 uddg 形式，直接返回
      if (href.startsWith('//')) {
        return 'https:$href';
      }
      return href;
    }

    final links = linkRe.allMatches(html).toList();
    final snippets = snippetRe.allMatches(html).toList();
    for (var i = 0; i < links.length && i < 15; i++) {
      final href = links[i].group(1) ?? '';
      final rawTitle = links[i].group(2) ?? '';
      if (href.isEmpty) continue;
      final url = decodeUddg(href);
      if (url.isEmpty ||
          url.contains('duckduckgo.com') ||
          url.contains('duck.com')) {
        continue;
      }
      final title = stripHtml(rawTitle);
      final snippet =
          i < snippets.length ? stripHtml(snippets[i].group(1) ?? '') : '';
      results.add(SearchResultItem(
        title: title.isEmpty ? url : title,
        url: url,
        snippet: snippet,
        provider: 'duckduckgo',
      ));
    }
    _logger.info('[WebSearch] Parsed ${results.length} items from DuckDuckGo',
        tag: 'WS');
    return results;
  }

  // --- SerpAPI（聚合 Google/Bing/Baidu 等引擎，需 Key） ---
  // GET https://serpapi.com/search?engine=google&q=xxx&api_key=KEY
  static Future<List<SearchResultItem>> _serpApiSearch(
    String query,
    WebSearchConfig cfg,
  ) async {
    final key = cfg.serpApiKey.trim();
    if (key.isEmpty) {
      _logger.warn('[WebSearch] SerpAPI Key empty, skipping', tag: 'WS');
      return [];
    }
    final engine =
        cfg.serpapiEngine.trim().isEmpty ? 'google' : cfg.serpapiEngine.trim();
    final uri = Uri.parse(_serpApiUrl).replace(queryParameters: {
      'engine': engine,
      'q': query,
      'api_key': key,
      if (!cfg.tavilyAutoMaxResults)
        'num': cfg.tavilyMaxResults.clamp(3, 10).toString(),
    });
    try {
      final resp = await http.get(uri, headers: {
        'User-Agent': 'AIChat-Android/1.3.9',
        'Accept': 'application/json',
      }).timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) {
        _logger.warn(
            '[WebSearch] SerpAPI HTTP ${resp.statusCode}: '
            '${resp.body.length <= 200 ? resp.body : resp.body.substring(0, 200)}',
            tag: 'WS');
        return [];
      }
      final data =
          _decodeJsonObject(utf8.decode(resp.bodyBytes), 'SerpAPI');
      if (data == null) return [];
      final list = data['organic_results'] as List<dynamic>? ?? [];
      final results = <SearchResultItem>[];
      for (final item in list) {
        if (item is! Map<String, dynamic>) continue;
        final link = (item['link'] as String? ?? '').trim();
        if (link.isEmpty) continue;
        // SerpAPI 的 snippet 可能叫 snippet / description
        final snip =
            item['snippet'] as String? ?? item['description'] as String? ?? '';
        // 可能带 date 字段
        final dateStr = item['date'] as String?;
        results.add(SearchResultItem(
          title: item['title'] as String? ?? link,
          url: link,
          snippet: snip,
          provider: 'serpapi',
          publishedDate: dateStr,
        ));
      }
      return results;
    } catch (e, st) {
      _logger.error('[WebSearch] SerpAPI search failed',
          error: e, stack: st, tag: 'WS');
      return [];
    }
  }

  // --- Brave Search API（需 Key，2000次/月免费） ---
  // GET https://api.search.brave.com/res/v1/web/search?q=xxx
  // Header: X-Subscription-Token: KEY
  static Future<List<SearchResultItem>> _braveSearch(
    String query,
    WebSearchConfig cfg,
  ) async {
    final key = cfg.braveApiKey.trim();
    if (key.isEmpty) {
      _logger.warn('[WebSearch] Brave Key empty, skipping', tag: 'WS');
      return [];
    }
    final uri = Uri.parse(_braveUrl).replace(queryParameters: {
      'q': query,
      if (!cfg.tavilyAutoMaxResults)
        'count': cfg.tavilyMaxResults.clamp(3, 10).toString(),
      'country': 'cn',
      'search_lang': 'zh-hans',
    });
    try {
      final resp = await http.get(uri, headers: {
        'User-Agent': 'AIChat-Android/1.3.9',
        'Accept': 'application/json',
        'Accept-Encoding': 'gzip',
        'X-Subscription-Token': key,
      }).timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) {
        _logger.warn(
            '[WebSearch] Brave HTTP ${resp.statusCode}: '
            '${resp.body.length <= 200 ? resp.body : resp.body.substring(0, 200)}',
            tag: 'WS');
        return [];
      }
      final data =
          _decodeJsonObject(utf8.decode(resp.bodyBytes), 'Brave');
      if (data == null) return [];
      final web = data['web']?['results'] as List<dynamic>? ?? [];
      final results = <SearchResultItem>[];
      for (final item in web) {
        if (item is! Map<String, dynamic>) continue;
        final u =
            (item['url'] as String? ?? item['link'] as String? ?? '').trim();
        if (u.isEmpty) continue;
        // Brave 的 date 字段：page_age / publish_date
        final dateStr =
            item['page_age'] as String? ?? item['publish_date'] as String?;
        results.add(SearchResultItem(
          title: item['title'] as String? ?? u,
          url: u,
          snippet: item['description'] as String? ??
              item['snippet'] as String? ??
              '',
          provider: 'brave',
          publishedDate: dateStr,
        ));
      }
      return results;
    } catch (e, st) {
      _logger.error('[WebSearch] Brave search failed',
          error: e, stack: st, tag: 'WS');
      return [];
    }
  }

  // --- Google CSE 自定义搜索（需 Key + cx，100次/天免费） ---
  // GET https://www.googleapis.com/customsearch/v1?key=KEY&cx=CX&q=xxx
  static Future<List<SearchResultItem>> _googleCseSearch(
    String query,
    WebSearchConfig cfg,
  ) async {
    final key = cfg.googleCseApiKey.trim();
    final cx = cfg.googleCseId.trim();
    if (key.isEmpty || cx.isEmpty) {
      _logger.warn('[WebSearch] Google CSE Key/cx empty, skipping', tag: 'WS');
      return [];
    }
    final uri = Uri.parse(_googleCseUrl).replace(queryParameters: {
      'key': key,
      'cx': cx,
      'q': query,
      if (!cfg.tavilyAutoMaxResults)
        'num': cfg.tavilyMaxResults.clamp(3, 10).toString(),
    });
    try {
      final resp = await http.get(uri, headers: {
        'User-Agent': 'AIChat-Android/1.3.9',
        'Accept': 'application/json',
      }).timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) {
        _logger.warn(
            '[WebSearch] Google CSE HTTP ${resp.statusCode}: '
            '${resp.body.length <= 200 ? resp.body : resp.body.substring(0, 200)}',
            tag: 'WS');
        return [];
      }
      final data =
          _decodeJsonObject(utf8.decode(resp.bodyBytes), 'Google CSE');
      if (data == null) return [];
      final items = data['items'] as List<dynamic>? ?? [];
      final results = <SearchResultItem>[];
      for (final item in items) {
        if (item is! Map<String, dynamic>) continue;
        final u = (item['link'] as String? ?? '').trim();
        if (u.isEmpty) continue;
        // Google CSE 有 pagemap.metatags.Created / Date 等
        String? dateStr;
        final pagemap = item['pagemap'] as Map<String, dynamic>?;
        if (pagemap != null) {
          final metatags = pagemap['metatags'] as List?;
          if (metatags != null && metatags.isNotEmpty) {
            final mt = metatags[0] as Map<String, dynamic>?;
            dateStr = mt?['article:published_time'] as String? ??
                mt?['date'] as String? ??
                mt?['created'] as String?;
          }
        }
        results.add(SearchResultItem(
          title: item['title'] as String? ?? u,
          url: u,
          snippet: item['snippet'] as String? ?? '',
          provider: 'googlecse',
          publishedDate: dateStr,
        ));
      }
      return results;
    } catch (e, st) {
      _logger.error('[WebSearch] Google CSE search failed',
          error: e, stack: st, tag: 'WS');
      return [];
    }
  }

  // ==========================================================================
  // Bing 通用搜索（复用现有解析，宽松一点：不再只过滤 APK 关键词）
  // ==========================================================================
  static Future<List<SearchResultItem>> _bingGeneralSearch(String query) async {
    final url = '$_bingUrl?q=${Uri.encodeComponent(query)}&setlang=zh-CN&cc=CN';
    try {
      final resp = await http.get(
        Uri.parse(url),
        headers: {
          'User-Agent': _ua,
          'Accept-Language': 'zh-CN,zh;q=0.9',
          'Accept': 'text/html,application/xhtml+xml',
        },
      ).timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        _logger.warn('[WebSearch] Bing general HTTP ${resp.statusCode}',
            tag: 'WS');
        return [];
      }
      final html = utf8.decode(resp.bodyBytes, allowMalformed: true);
      final results = _parseBingResults(html, query);
      return results.where((r) {
        final u = r.url.toLowerCase();
        return !(u.contains('bing.com') ||
            u.contains('microsoft.com') ||
            u.contains('go.microsoft'));
      }).toList();
    } catch (e, st) {
      _logger.error('[WebSearch] Bing general failed',
          error: e, stack: st, tag: 'WS');
      return [];
    }
  }

  /// v1.4.2：Bing 图片搜索（直爬），返回真实图片直链（murl），
  /// 用于「AI 搜索下载图片」场景。文本搜索只会返回图片详情页，无法直接下载。
  static Future<List<SearchResultItem>> _bingImageSearch(String query) async {
    final url =
        'https://cn.bing.com/images/search?q=${Uri.encodeComponent(query)}&setlang=zh-CN';
    try {
      final resp = await http.get(
        Uri.parse(url),
        headers: {
          'User-Agent': _ua,
          'Accept-Language': 'zh-CN,zh;q=0.9',
          'Accept': 'text/html,application/xhtml+xml',
        },
      ).timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        _logger.warn('[WebSearch] Bing image HTTP ${resp.statusCode}',
            tag: 'WS');
        return [];
      }
      final html = utf8.decode(resp.bodyBytes, allowMalformed: true);
      final results = _parseBingImageResults(html);
      _logger.info('[WebSearch] Bing image parsed ${results.length} links',
          tag: 'WS');
      return results;
    } catch (e, st) {
      _logger.error('[WebSearch] Bing image failed',
          error: e, stack: st, tag: 'WS');
      return [];
    }
  }

  /// 从 Bing 图片搜索结果 HTML 里提取真实图片直链（murl 字段）
  static List<SearchResultItem> _parseBingImageResults(String html) {
    final results = <SearchResultItem>[];

    // Bing 图片页的图片直链以 "murl":"https://..." 或 HTML 转义形式
    // murl&quot;:&quot;https:\/\/...&quot; 存在。
    final murlRegex = RegExp(
      r'murl(?:&quot;|")\s*:\s*(?:&quot;|")(.*?)(?:&quot;|")',
      caseSensitive: false,
    );

    String unescape(String s) => s
        .replaceAll(r'\/', '/')
        .replaceAll('&quot;', '"')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&#x27;', "'")
        .replaceAll(r'\u002F', '/');

    final seen = <String>{};
    final imgExtRe = RegExp(r'\.(jpg|jpeg|png|gif|webp|bmp|avif)(\?|#|$)');

    for (final m in murlRegex.allMatches(html)) {
      var raw = unescape((m.group(1) ?? '').trim());
      if (!raw.startsWith('http')) {
        continue;
      }
      final lower = raw.toLowerCase();
      if (lower.contains('bing.com') || lower.contains('microsoft.com')) {
        continue;
      }
      // 只保留明确图片扩展名的直链，确保下载后能正确分类到 AIChat-图片
      if (!imgExtRe.hasMatch(lower)) continue;
      if (seen.contains(raw)) continue;
      seen.add(raw);

      // 标题优先从 URL 末段推断（如 cat.jpg）
      String title = raw;
      try {
        final seg = Uri.parse(raw).pathSegments.where((s) => s.isNotEmpty).last;
        if (seg.isNotEmpty) title = Uri.decodeComponent(seg);
      } catch (e) { debugPrint('catch 静默异常: $e'); }

      results.add(SearchResultItem(
        title: title,
        url: raw,
        snippet: 'Bing 图片直链',
        provider: 'bing',
      ));
      if (results.length >= 20) break;
    }

    return results;
  }

  // ==========================================================================
  // 5) 搜索上下文格式化 → 直接塞给 LLM 的 prompt
  // ==========================================================================
  /// 把搜索结果格式化为一段 prompt，用户消息前/后拼上即可。
  ///
  /// 返回的段落类似：
  /// ```
  /// 【联网搜索结果，仅供参考】
  /// [1] 标题1
  ///     URL: https://xxx
  ///     摘要：xxxx
  ///
  /// [2] 标题2 ...
  /// ```
  static String formatAsSearchContext(
    List<SearchResultItem> results,
    WebSearchConfig cfg, {
    String query = '',

    /// v1.3.1 build 11：如果传了 tagQuery，结果块会写成"query / tagQuery"分开显示
    /// 用于 ReAct 的 toolresult 场景：query=显示给人类看的搜索关键词, tagQuery=原始 LLM 发的 query
    String? tagQuery,
    bool isZh = true,
  }) {
    if (results.isEmpty) return '';

    final maxResults = cfg.maxResultsInject.clamp(1, 10);
    final maxChars = cfg.maxSnippetCharsPerResult.clamp(80, 2000);
    final displayQuery =
        (tagQuery != null && tagQuery.isNotEmpty) ? tagQuery : query;

    // m12 fix: URL 去重，避免相同结果重复注入浪费 token
    final seenUrls = <String>{};
    final deduplicated = results.where((r) => seenUrls.add(r.url)).toList();

    final sb = StringBuffer();
    if (isZh) {
      sb.writeln('【联网搜索结果（query: "$displayQuery"） — 请基于以下内容回答，若内容不足请说明】');
    } else {
      sb.writeln(
          '[Web Search Results (query: "$displayQuery") — Answer based on the following content; if insufficient, say so]');
    }
    var count = 0;
    for (final r in deduplicated) {
      if (count >= maxResults) break;
      count++;
      final snippet = r.snippet.length > maxChars
          ? '${r.snippet.substring(0, maxChars)}…'
          : r.snippet;
      sb.writeln('[$count] ${r.title.isEmpty ? r.url : r.title}');
      sb.writeln('    URL: ${r.url}');
      if (r.publishedDate != null && r.publishedDate!.isNotEmpty) {
        if (isZh) {
          sb.writeln('    发布时间: ${r.publishedDate}');
        } else {
          sb.writeln('    Published: ${r.publishedDate}');
        }
      }
      if (isZh) {
        sb.writeln('    摘要: $snippet');
      } else {
        sb.writeln('    Summary: $snippet');
      }
      sb.writeln('');
    }
    if (isZh) {
      sb.writeln('—— 搜索结果结束 ——');
    } else {
      sb.writeln('—— End of search results ——');
    }
    return sb.toString();
  }

  // ==========================================================================
  // —— 下方为 v1.2.x 下载功能保留的方法，API 不变 ——
  // ==========================================================================

  /// 搜索 APK 下载链接（下载场景专用，永远走 Bing 严格解析 + APK 关键词过滤）
  static Future<List<SearchResultItem>> searchApkLinks(
    String appName, [
    WebSearchConfig? cfg,
  ]) async {
    // v1.3.1: 如果传入了配置且非 Bing → 走 Tavily/SearXNG（尊重用户设置的联网 API）
    if (cfg != null && cfg.webSearchEnabled) {
      final provider = cfg.effectiveProvider();
      if (provider != WebSearchProvider.bing) {
        // v1.5.1：查询词加可信直链源域名提示，优先 APKMirror/Uptodown/F-Droid
        final query =
            '$appName APK 直链 下载 最新版 android (apkmirror OR uptodown OR f-droid OR apkpure)';
        _logger.info(
          '[WebSearch] APK search via=${provider.name} query="$query"',
          tag: 'WS-DL',
        );
        try {
          final results = await searchGeneral(query, cfg);
          // 对 Tavily/SearXNG 结果做和 Bing 一样的 APK/下载页过滤
          final filtered = results.where((r) {
            final lowerUrl = r.url.toLowerCase();
            final lowerTitle = r.title.toLowerCase();
            final lowerSnippet = r.snippet.toLowerCase();
            if (lowerUrl.contains('bing.com') ||
                lowerUrl.contains('go.microsoft.com')) {
              return false;
            }
            if (lowerUrl.endsWith('.apk') ||
                lowerUrl.contains('.apk?') ||
                lowerUrl.contains('.apk#')) {
              return true;
            }
            if (lowerTitle.contains('下载') ||
                lowerTitle.contains('apk') ||
                lowerSnippet.contains('直链') ||
                lowerSnippet.contains('.apk') ||
                lowerSnippet.contains('官方下载')) {
              return true;
            }
            for (final domain in _knownApkDomains) {
              if (lowerUrl.contains(domain)) return true;
            }
            return false;
          }).toList();
          _logger.info(
            '[WebSearch] APK via ${provider.name}: raw=${results.length}, filtered=${filtered.length} for "$appName"',
            tag: 'WS-DL',
          );
          // 如果 Tavily/SearXNG 有结果就用它；没结果则降级到 Bing 抓取
          if (filtered.isNotEmpty) return filtered;
          _logger.info(
            '[WebSearch] ${provider.name} returned 0 after filter, fallback to Bing HTML',
            tag: 'WS-DL',
          );
        } catch (e, st) {
          _logger.error(
              '[WebSearch] APK via ${provider.name} failed, fallback to Bing',
              error: e,
              stack: st,
              tag: 'WS-DL');
        }
      }
    }

    // --- Bing HTML 抓取（默认 / 降级路径） ---
    final query = Uri.encodeComponent('$appName APK 直链 下载 最新版 android');
    final url = '$_bingUrl?q=$query&setlang=zh-CN&cc=CN';

    _logger.info('[WebSearch] Searching APK (Bing): $appName', tag: 'WS-DL');

    try {
      final response = await http.get(
        Uri.parse(url),
        headers: {
          'User-Agent': _ua,
          'Accept-Language': 'zh-CN,zh;q=0.9',
          'Accept': 'text/html,application/xhtml+xml',
        },
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        _logger.warn(
            '[WebSearch] Bing APK search returned ${response.statusCode}',
            tag: 'WS-DL');
        return [];
      }

      final html = utf8.decode(response.bodyBytes, allowMalformed: true);
      final results = _parseBingResults(html, appName);

      // 过滤：只保留包含 apk/download/直链 关键词的结果
      final filtered = results.where((r) {
        final lowerUrl = r.url.toLowerCase();
        final lowerTitle = r.title.toLowerCase();
        final lowerSnippet = r.snippet.toLowerCase();

        if (lowerUrl.contains('bing.com') ||
            lowerUrl.contains('go.microsoft.com')) {
          return false;
        }
        if (lowerUrl.endsWith('.apk') ||
            lowerUrl.contains('.apk?') ||
            lowerUrl.contains('.apk#')) {
          return true;
        }
        if (lowerTitle.contains('下载') ||
            lowerTitle.contains('apk') ||
            lowerSnippet.contains('直链') ||
            lowerSnippet.contains('.apk') ||
            lowerSnippet.contains('官方下载')) {
          return true;
        }
        for (final domain in _knownApkDomains) {
          if (lowerUrl.contains(domain)) return true;
        }
        return false;
      }).toList();

      _logger.info(
          '[WebSearch] APK: raw=${results.length}, filtered=${filtered.length} for "$appName"',
          tag: 'WS-DL');
      _logger.verbose(
          '[WebSearch] APK filtered results for "$appName":\n${filtered.map((item) => '  - ${item.title}\n    URL: ${item.url}').join('\n')}',
          tag: 'WS-DL');
      return filtered;
    } catch (e, st) {
      _logger.error('[WebSearch] APK search failed',
          error: e, stack: st, tag: 'WS-DL');
      return [];
    }
  }

  /// v1.4.2：通用文件下载搜索（视频/图片/音频/文档等）
  /// [query]：搜索关键词
  /// [fileType]：文件类型（video/image/audio/document/any）
  static Future<List<SearchResultItem>> searchFileDownloads(
    String query, [
    WebSearchConfig? cfg,
    String fileType = 'any',
  ]) async {
    final typeKeywords = switch (fileType) {
      'video' => '视频 mp4 下载',
      'image' => '图片 hd 下载',
      'audio' => '音频 mp3 下载',
      'document' => '文档 pdf 下载',
      _ => '文件 下载',
    };

    final searchQuery = '$query $typeKeywords 直链 免费';
    _logger.info(
      '[WebSearch] File search: query="$searchQuery" type=$fileType',
      tag: 'WS-FILE',
    );

    try {
      // v1.4.2 修复（踩坑 #45）：image 类型走专门图片直链搜索。
      // 文本搜索只会返回图片详情页 URL（如 pexels.com/photo/xxx），下载下来是 HTML 垃圾文件。
      if (fileType == 'image') {
        final images = await _bingImageSearch(query);
        _logger.info(
          '[WebSearch] File search(image): ${images.length} direct links for "$query"',
          tag: 'WS-FILE',
        );
        return images;
      }

      final effectiveCfg = cfg ?? WebSearchConfig();
      final results = await searchGeneral(searchQuery, effectiveCfg);
      final filtered = results.where((r) {
        final lowerUrl = r.url.toLowerCase();
        final lowerTitle = r.title.toLowerCase();
        final lowerSnippet = r.snippet.toLowerCase();

        // 过滤搜索引擎自身
        if (lowerUrl.contains('bing.com') ||
            lowerUrl.contains('google.com') ||
            lowerUrl.contains('baidu.com') ||
            lowerUrl.contains('sogou.com') ||
            lowerUrl.contains('so.com')) {
          return false;
        }

        // v1.7.31：过滤目录列表页（URL 以 / 结尾或含 index.html/list/ 等目录特征）
        if (lowerUrl.endsWith('/') ||
            lowerUrl.contains('/index.htm') ||
            lowerUrl.contains('/list/') ||
            lowerUrl.contains('/directory') ||
            lowerUrl.contains('/browse/')) {
          return false;
        }

        // 文件直链特征
        final directExts = [
          '.mp4', '.webm', '.mov', '.mkv', '.avi',
          '.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp',
          '.mp3', '.wav', '.ogg', '.flac',
          '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx',
          '.zip', '.rar', '.7z', '.tar', '.gz',
          '.txt', '.json', '.csv', '.xml',
          // v1.7.31：移除 .html —— HTML 是网页不是可下载文件，保留会导致搜到一堆网页当文件
        ];
        for (final ext in directExts) {
          if (lowerUrl.contains(ext) ||
              lowerUrl.contains('$ext?') ||
              lowerUrl.contains('$ext#')) {
            return true;
          }
        }

        // 下载页特征
        if (lowerTitle.contains('下载') ||
            lowerTitle.contains('download') ||
            lowerSnippet.contains('直链') ||
            lowerSnippet.contains('download') ||
            lowerSnippet.contains('下载')) {
          return true;
        }

        // 已知文件分享/CDN 域名（v1.7.1 fix M5: 改为精确域名匹配，避免误判）
        const fileDomains = [
          'dropbox.com',
          'drive.google.com',
          'onedrive.live.com',
          'mega.nz',
          'mediafire.com',
          'rapidshare.com',
          'pexels.com',
          'pixabay.com',
          'unsplash.com',
          'videvo.net',
          'mixkit.co',
          'coverr.co',
          'archive.org',
          'wikimedia.org',
        ];
        // 精确匹配完整域名
        for (final domain in fileDomains) {
          if (lowerUrl.contains(domain)) return true;
        }
        // CDN 前缀匹配需要确保是子域名（如 cdn.example.com）
        final uri = Uri.tryParse(r.url);
        if (uri != null) {
          final host = uri.host.toLowerCase();
          if (host.startsWith('cdn.') ||
              host.startsWith('download.') ||
              host.startsWith('files.') ||
              host.startsWith('assets.')) {
            return true;
          }
        }

        return false;
      }).toList();

      _logger.info(
        '[WebSearch] File search: raw=${results.length}, filtered=${filtered.length} for "$query"',
        tag: 'WS-FILE',
      );
      return filtered;
    } catch (e, st) {
      _logger.error('[WebSearch] File search failed',
          error: e, stack: st, tag: 'WS-FILE');
      return [];
    }
  }

  /// 从 Bing 搜索结果 HTML 中解析链接（通用 + APK 共用解析器）
  static List<SearchResultItem> _parseBingResults(
      String html, String fallbackTitle) {
    final results = <SearchResultItem>[];

    final blockRegex = RegExp(
      r'<li\s+class="b_algo"[^>]*>(.*?)</li>',
      caseSensitive: false,
      dotAll: true,
    );
    final hrefRegex = RegExp(
      r'<h2[^>]*>.*?<a[^>]+href="(https?://[^"]+)"[^>]*>(.*?)</a>',
      caseSensitive: false,
      dotAll: true,
    );
    final snippetRegex = RegExp(
      r'<p[^>]*class="[^"]*b_caption[^"]*"[^>]*>(.*?)</p>',
      caseSensitive: false,
      dotAll: true,
    );
    final pRegex = RegExp(
      r'</h2>.*?<p[^>]*>(.*?)</p>',
      caseSensitive: false,
      dotAll: true,
    );

    String stripHtml(String s) => s
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .trim()
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&#xFFFD;', '');

    for (final block in blockRegex.allMatches(html)) {
      final blockHtml = block.group(1) ?? '';

      final hrefMatch = hrefRegex.firstMatch(blockHtml);
      final url = hrefMatch?.group(1) ?? '';
      if (url.isEmpty ||
          url.contains('bing.com') ||
          url.contains('microsoft.com') ||
          url.contains('go.microsoft')) {
        continue;
      }

      final rawTitle = hrefMatch?.group(2) ?? '';
      final title = stripHtml(rawTitle);

      final snippetMatch =
          snippetRegex.firstMatch(blockHtml) ?? pRegex.firstMatch(blockHtml);
      final snippet = stripHtml(snippetMatch?.group(1) ?? '');

      results.add(SearchResultItem(
        title: title.isEmpty ? fallbackTitle : title,
        url: url,
        snippet: snippet,
        provider: 'bing',
      ));
    }

    // fallback: b_algo 没抓到就退化为正则抓所有链接
    if (results.isEmpty) {
      _logger.info('[WebSearch] b_algo empty, fallback to regex-only parse',
          tag: 'WS');
      final urlRegex = RegExp(r'href="(https?://[^"]+)"', caseSensitive: false);
      final titleRe = RegExp(r'<h2[^>]*><a[^>]*>(.*?)</a>',
          caseSensitive: false, dotAll: true);

      final urls = <String>{};
      for (final m in urlRegex.allMatches(html)) {
        final u = m.group(1) ?? '';
        if (u.startsWith('http') &&
            !u.contains('bing.com') &&
            !u.contains('microsoft.com') &&
            !u.contains('go.microsoft')) {
          urls.add(u);
        }
      }
      final titles = <String>[];
      for (final m in titleRe.allMatches(html)) {
        final t = stripHtml(m.group(1) ?? '');
        if (t.isNotEmpty) titles.add(t);
      }
      final urlList = urls.toList();
      for (var i = 0; i < urlList.length && i < 15; i++) {
        results.add(SearchResultItem(
          title: i < titles.length ? titles[i] : fallbackTitle,
          url: urlList[i],
          snippet: '',
          provider: 'bing',
        ));
      }
    }

    _logger.info('[WebSearch] Parsed ${results.length} items from Bing',
        tag: 'WS');
    return results;
  }

  /// 验证 URL 是否是可下载的 APK 直链
  static Future<String?> validateUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      if (!_isSafePublicUri(uri)) {
        return 'Blocked: private/internal address';
      }

      int? statusCode;
      Map<String, String>? headers;
      final headResult =
          await _sendHopByHop('HEAD', url, const Duration(seconds: 5));
      statusCode = headResult.$1;
      headers = headResult.$2;
      if (statusCode == null || statusCode == 405 || statusCode == 403) {
        final getResult =
            await _sendHopByHop('GET', url, const Duration(seconds: 5));
        statusCode = getResult.$1;
        headers = getResult.$2;
      }

      if (statusCode == null) return '网络无法访问，请检查网络连接';
      if (statusCode < 200 || statusCode >= 400) {
        return '服务器返回错误 HTTP $statusCode';
      }

      final clStr = headers?['content-length'];
      if (clStr != null) {
        final cl = int.tryParse(clStr) ?? 0;
        if (cl > 0 && cl < 10 * 1024) return '文件太小（$cl字节），可能不是APK';
      }
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  /// 轻量可访问性检查（仅判断能不能连上，不管 Content-Type）
  static Future<bool> checkReachable(String url) async {
    try {
      // v1.7.1 fix C4: SSRF 防护 - 检查是否为内网地址
      final uri = Uri.parse(url);
      if (!_isSafePublicUri(uri)) {
        return false;
      }

      final result =
          await _sendHopByHop('GET', url, const Duration(seconds: 15));
      final sc = result.$1;
      return sc != null && sc >= 200 && sc < 404;
    } catch (_) {
      return false;
    }
  }

  static Future<(int?, Map<String, String>?)> _sendHopByHop(
    String method,
    String url,
    Duration timeout,
  ) async {
    var current = url;
    for (var hop = 0; hop <= 5; hop++) {
      final uri = Uri.parse(current);
      if (!_isSafePublicUri(uri)) {
        return (null, null);
      }
      final request = http.Request(method, uri);
      request.headers['User-Agent'] = _ua;
      request.followRedirects = false;
      final client = http.Client();
      try {
        final response = await client.send(request).timeout(timeout);
        final sc = response.statusCode;
        if (sc >= 300 && sc < 400) {
          final location = response.headers['location'];
          if (location == null || location.isEmpty) {
            return (sc, response.headers);
          }
          current = uri.resolve(location).toString();
          continue;
        }
        return (sc, response.headers);
      } catch (_) {
        return (null, null);
      } finally {
        client.close();
      }
    }
    return (null, null);
  }

  /// v1.7.1 fix C4: SSRF 防护 - 检查 URI 是否为安全的公网地址（非内网/环回/链路本地）
  static bool _isSafePublicUri(Uri uri) {
    if (uri.host.isEmpty) return false;
    final host = uri.host.toLowerCase();

    // 禁止 localhost 和 .local 域名
    if (host == 'localhost' ||
        host.endsWith('.localhost') ||
        host.endsWith('.local')) {
      return false;
    }

    // 解析 IP 地址并检查是否为私网/环回/链路本地
    final address = InternetAddress.tryParse(host);
    if (address == null) return true; // 域名无法解析为 IP，暂且放行（DNS 解析由系统处理）

    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      final a = bytes[0];
      final b = bytes[1];
      // 禁止：0.x.x.x, 10.x.x.x, 127.x.x.x, 100.64-127.x.x, 169.254.x.x,
      //       172.16-31.x.x, 192.0.x.x, 192.168.x.x, 198.18-19.x.x, 224+ (组播)
      return a != 0 &&
          a != 10 &&
          a != 127 &&
          !(a == 100 && b >= 64 && b <= 127) &&
          !(a == 169 && b == 254) &&
          !(a == 172 && b >= 16 && b <= 31) &&
          !(a == 192 && (b == 0 || b == 168)) &&
          !(a == 198 && (b == 18 || b == 19)) &&
          a < 224;
    }

    // IPv6 检查
    if (bytes.length == 16) {
      // 禁止全 0、::1、fc00::/7 (唯一本地)、fe80::/10 (链路本地)、ff00::/8 (组播)
      if (bytes.every((value) => value == 0) ||
          (bytes.take(15).every((value) => value == 0) && bytes[15] == 1) ||
          (bytes[0] & 0xfe) == 0xfc ||
          (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) ||
          bytes[0] == 0xff) {
        return false;
      }
      // IPv4-mapped IPv6 (::ffff:x.x.x.x)
      if (bytes.take(10).every((value) => value == 0) &&
          bytes[10] == 0xff &&
          bytes[11] == 0xff) {
        final a = bytes[12];
        final b = bytes[13];
        return !(a == 0 ||
            a == 10 ||
            a == 127 ||
            (a == 100 && b >= 64 && b <= 127) ||
            (a == 169 && b == 254) ||
            (a == 172 && b >= 16 && b <= 31) ||
            (a == 192 && (b == 0 || b == 168)) ||
            (a == 198 && (b == 18 || b == 19)) ||
            a >= 224);
      }
    }

    return true;
  }
}

// ============================================================================
// #1 Strategy Pattern 策略实现（v1.7.24）
// 每个搜索后端一个策略类：search（通用搜索）+ test（连接测试）。
// 注册表 kSearchEngines 见文件末尾。加新引擎：
//   ① WebSearchProvider enum 加值 → ② 新增策略类 → ③ kSearchEngines 注册一行
// ============================================================================

class BingSearchEngine implements SearchEngine {
  @override
  WebSearchProvider get provider => WebSearchProvider.bing;

  @override
  Future<List<SearchResultItem>> search(String query, WebSearchConfig cfg) =>
      WebSearchService._bingGeneralSearch(query);

  @override
  Future<(bool ok, String message, int? latencyMs)> test(
      WebSearchConfig cfg) async {
    const probe = 'android latest version';
    final t0 = DateTime.now();
    try {
      final resp = await http.get(
        Uri.parse(
            '${WebSearchService._bingUrl}?q=${Uri.encodeQueryComponent(probe)}&setlang=en-US'),
        headers: {'User-Agent': WebSearchService._ua},
      ).timeout(const Duration(seconds: 15));
      final ms = DateTime.now().difference(t0).inMilliseconds;
      if (resp.statusCode == 200) {
        WebSearchService._logger.info(
            '[WebSearch] Test Bing OK ${ms}ms len=${resp.body.length}',
            tag: 'WS');
        return (true, 'Bing OK · ${ms}ms · 返回 HTML ${resp.body.length} 字节', ms);
      }
      return (false, 'Bing HTTP ${resp.statusCode}', ms);
    } catch (e) {
      final ms = DateTime.now().difference(t0).inMilliseconds;
      WebSearchService._logger.error(
          '[WebSearch] Test connection failed via=bing',
          error: e,
          tag: 'WS');
      return (false, '异常 / Exception: $e', ms);
    }
  }
}

class TavilySearchEngine implements SearchEngine {
  @override
  WebSearchProvider get provider => WebSearchProvider.tavily;

  @override
  Future<List<SearchResultItem>> search(String query, WebSearchConfig cfg) =>
      WebSearchService._tavilySearch(query, cfg);

  @override
  Future<(bool ok, String message, int? latencyMs)> test(
      WebSearchConfig cfg) async {
    const probe = 'android latest version';
    final t0 = DateTime.now();
    final key = cfg.tavilyApiKey.trim();
    if (key.isEmpty) {
      return (false, '请先填入 Tavily API Key 再测试', null);
    }
    try {
      final resp = await http
          .post(
            Uri.parse(WebSearchService._tavilyUrl),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              'User-Agent': 'AIChat-Android/1.3',
            },
            body: jsonEncode({
              'api_key': key,
              'query': probe,
              'search_depth': 'basic',
              'max_results': 2,
              'include_answer': false,
              'include_images': false,
            }),
          )
          .timeout(const Duration(seconds: 20));
      final ms = DateTime.now().difference(t0).inMilliseconds;
      if (resp.statusCode == 200) {
        try {
          final j = jsonDecode(resp.body) as Map<String, dynamic>;
          final n = (j['results'] as List?)?.length ?? 0;
          WebSearchService._logger
              .info('[WebSearch] Test Tavily OK ${ms}ms results=$n', tag: 'WS');
          return (true, 'Tavily OK · ${ms}ms · 返回 $n 条结果', ms);
        } catch (_) {
          return (true, 'Tavily HTTP 200 · ${ms}ms', ms);
        }
      }
      String detail = 'Tavily HTTP ${resp.statusCode}';
      try {
        final j = jsonDecode(resp.body) as Map<String, dynamic>;
        final err = j['error'] ?? j['message'];
        if (err != null) detail += ' · $err';
      } catch (e) { debugPrint('catch 静默异常: $e'); }
      WebSearchService._logger
          .warn('[WebSearch] Test Tavily fail: $detail', tag: 'WS');
      return (false, detail, ms);
    } catch (e) {
      final ms = DateTime.now().difference(t0).inMilliseconds;
      WebSearchService._logger.error(
          '[WebSearch] Test connection failed via=tavily',
          error: e,
          tag: 'WS');
      return (false, '异常 / Exception: $e', ms);
    }
  }
}

class SearxngSearchEngine implements SearchEngine {
  @override
  WebSearchProvider get provider => WebSearchProvider.searxng;

  @override
  Future<List<SearchResultItem>> search(String query, WebSearchConfig cfg) =>
      WebSearchService._searxngSearch(query, cfg);

  @override
  Future<(bool ok, String message, int? latencyMs)> test(
      WebSearchConfig cfg) async {
    const probe = 'android latest version';
    final t0 = DateTime.now();
    final raw = cfg.searxngInstanceUrl.trim();
    if (raw.isEmpty) {
      return (false, '请先填入 SearXNG 实例地址再测试', null);
    }
    final base = raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
    try {
      final uri = Uri.parse('$base/search').replace(queryParameters: {
        'q': probe,
        'format': 'json',
        'categories': 'general'
      });
      final resp = await http.get(uri, headers: {
        'Accept': 'application/json',
        'User-Agent': WebSearchService._ua
      }).timeout(const Duration(seconds: 15));
      final ms = DateTime.now().difference(t0).inMilliseconds;
      if (resp.statusCode == 200) {
        try {
          final j = jsonDecode(resp.body) as Map<String, dynamic>;
          final n = (j['results'] as List?)?.length ?? 0;
          WebSearchService._logger.info(
              '[WebSearch] Test SearXNG OK ${ms}ms results=$n',
              tag: 'WS');
          return (true, 'SearXNG OK · ${ms}ms · 返回 $n 条结果', ms);
        } catch (_) {
          return (
            false,
            'SearXNG 返回格式不是合法 JSON（实例地址对吗？确认结尾/search 支持 format=json）',
            ms
          );
        }
      }
      return (false, 'SearXNG HTTP ${resp.statusCode}', ms);
    } catch (e) {
      final ms = DateTime.now().difference(t0).inMilliseconds;
      WebSearchService._logger.error(
          '[WebSearch] Test connection failed via=searxng',
          error: e,
          tag: 'WS');
      return (false, '异常 / Exception: $e', ms);
    }
  }
}

class DuckDuckGoSearchEngine implements SearchEngine {
  @override
  WebSearchProvider get provider => WebSearchProvider.duckduckgo;

  @override
  Future<List<SearchResultItem>> search(String query, WebSearchConfig cfg) =>
      WebSearchService._duckDuckGoSearch(query);

  @override
  Future<(bool ok, String message, int? latencyMs)> test(
      WebSearchConfig cfg) async {
    const probe = 'android latest version';
    final t0 = DateTime.now();
    try {
      final resp = await http.post(
        Uri.parse(WebSearchService._ddgUrl),
        headers: {
          'User-Agent': WebSearchService._ua,
          'Accept': 'text/html,application/xhtml+xml',
          'Accept-Language': 'zh-CN,zh;q=0.9',
        },
        body: {'q': probe, 'b': '1'},
      ).timeout(const Duration(seconds: 15));
      final ms = DateTime.now().difference(t0).inMilliseconds;
      if (resp.statusCode == 200) {
        final r = WebSearchService._parseDdgResults(
            utf8.decode(resp.bodyBytes, allowMalformed: true));
        WebSearchService._logger.info(
            '[WebSearch] Test DuckDuckGo OK ${ms}ms results=${r.length}',
            tag: 'WS');
        return (true, 'DuckDuckGo OK · ${ms}ms · 返回 ${r.length} 条结果', ms);
      }
      return (false, 'DuckDuckGo HTTP ${resp.statusCode}', ms);
    } catch (e) {
      final ms = DateTime.now().difference(t0).inMilliseconds;
      WebSearchService._logger.error(
          '[WebSearch] Test connection failed via=duckduckgo',
          error: e,
          tag: 'WS');
      return (false, '异常 / Exception: $e', ms);
    }
  }
}

class SerpApiSearchEngine implements SearchEngine {
  @override
  WebSearchProvider get provider => WebSearchProvider.serpapi;

  @override
  Future<List<SearchResultItem>> search(String query, WebSearchConfig cfg) =>
      WebSearchService._serpApiSearch(query, cfg);

  @override
  Future<(bool ok, String message, int? latencyMs)> test(
      WebSearchConfig cfg) async {
    const probe = 'android latest version';
    final t0 = DateTime.now();
    final key = cfg.serpApiKey.trim();
    if (key.isEmpty) {
      return (false, '请先填入 SerpAPI Key 再测试', null);
    }
    try {
      final uri =
          Uri.parse(WebSearchService._serpApiUrl).replace(queryParameters: {
        'engine': cfg.serpapiEngine.trim().isEmpty
            ? 'google'
            : cfg.serpapiEngine.trim(),
        'q': probe,
        'api_key': key,
        'num': '2',
      });
      final resp = await http.get(uri, headers: {
        'User-Agent': 'AIChat-Android/1.3.9',
        'Accept': 'application/json',
      }).timeout(const Duration(seconds: 20));
      final ms = DateTime.now().difference(t0).inMilliseconds;
      if (resp.statusCode == 200) {
        try {
          final j = jsonDecode(resp.body) as Map<String, dynamic>;
          final organic = j['organic_results'] as List? ?? [];
          WebSearchService._logger.info(
              '[WebSearch] Test SerpAPI OK ${ms}ms results=${organic.length}',
              tag: 'WS');
          return (true, 'SerpAPI OK · ${ms}ms · 返回 ${organic.length} 条结果', ms);
        } catch (_) {
          return (true, 'SerpAPI HTTP 200 · ${ms}ms', ms);
        }
      }
      String detail = 'SerpAPI HTTP ${resp.statusCode}';
      try {
        final j = jsonDecode(resp.body) as Map<String, dynamic>;
        final err = j['error'] ?? j['message'];
        if (err != null) detail += ' · $err';
      } catch (e) { debugPrint('catch 静默异常: $e'); }
      WebSearchService._logger
          .warn('[WebSearch] Test SerpAPI fail: $detail', tag: 'WS');
      return (false, detail, ms);
    } catch (e) {
      final ms = DateTime.now().difference(t0).inMilliseconds;
      WebSearchService._logger.error(
          '[WebSearch] Test connection failed via=serpapi',
          error: e,
          tag: 'WS');
      return (false, '异常 / Exception: $e', ms);
    }
  }
}

class BraveSearchEngine implements SearchEngine {
  @override
  WebSearchProvider get provider => WebSearchProvider.brave;

  @override
  Future<List<SearchResultItem>> search(String query, WebSearchConfig cfg) =>
      WebSearchService._braveSearch(query, cfg);

  @override
  Future<(bool ok, String message, int? latencyMs)> test(
      WebSearchConfig cfg) async {
    const probe = 'android latest version';
    final t0 = DateTime.now();
    final key = cfg.braveApiKey.trim();
    if (key.isEmpty) {
      return (false, '请先填入 Brave Search API Key 再测试', null);
    }
    try {
      final uri =
          Uri.parse(WebSearchService._braveUrl).replace(queryParameters: {
        'q': probe,
        'count': '2',
        'country': 'cn',
        'search_lang': 'zh-hans',
      });
      final resp = await http.get(uri, headers: {
        'User-Agent': 'AIChat-Android/1.3.9',
        'Accept': 'application/json',
        'Accept-Encoding': 'gzip',
        'X-Subscription-Token': key,
      }).timeout(const Duration(seconds: 20));
      final ms = DateTime.now().difference(t0).inMilliseconds;
      if (resp.statusCode == 200) {
        try {
          final j = jsonDecode(resp.body) as Map<String, dynamic>;
          final web = (j['web']?['results'] as List?) ?? [];
          WebSearchService._logger.info(
              '[WebSearch] Test Brave OK ${ms}ms results=${web.length}',
              tag: 'WS');
          return (true, 'Brave OK · ${ms}ms · 返回 ${web.length} 条结果', ms);
        } catch (_) {
          return (true, 'Brave HTTP 200 · ${ms}ms', ms);
        }
      }
      String detail = 'Brave HTTP ${resp.statusCode}';
      try {
        final j = jsonDecode(resp.body) as Map<String, dynamic>;
        final err = j['error']?['message'] ?? j['message'];
        if (err != null) detail += ' · $err';
      } catch (e) { debugPrint('catch 静默异常: $e'); }
      WebSearchService._logger
          .warn('[WebSearch] Test Brave fail: $detail', tag: 'WS');
      return (false, detail, ms);
    } catch (e) {
      final ms = DateTime.now().difference(t0).inMilliseconds;
      WebSearchService._logger.error(
          '[WebSearch] Test connection failed via=brave',
          error: e,
          tag: 'WS');
      return (false, '异常 / Exception: $e', ms);
    }
  }
}

class GoogleCseSearchEngine implements SearchEngine {
  @override
  WebSearchProvider get provider => WebSearchProvider.googlecse;

  @override
  Future<List<SearchResultItem>> search(String query, WebSearchConfig cfg) =>
      WebSearchService._googleCseSearch(query, cfg);

  @override
  Future<(bool ok, String message, int? latencyMs)> test(
      WebSearchConfig cfg) async {
    const probe = 'android latest version';
    final t0 = DateTime.now();
    final key = cfg.googleCseApiKey.trim();
    final cx = cfg.googleCseId.trim();
    if (key.isEmpty || cx.isEmpty) {
      return (false, '请先填入 Google CSE API Key 和搜索引擎 ID (cx) 再测试', null);
    }
    try {
      final uri =
          Uri.parse(WebSearchService._googleCseUrl).replace(queryParameters: {
        'key': key,
        'cx': cx,
        'q': probe,
        'num': '2',
      });
      final resp = await http.get(uri, headers: {
        'User-Agent': 'AIChat-Android/1.3.9',
        'Accept': 'application/json',
      }).timeout(const Duration(seconds: 20));
      final ms = DateTime.now().difference(t0).inMilliseconds;
      if (resp.statusCode == 200) {
        try {
          final j = jsonDecode(resp.body) as Map<String, dynamic>;
          final items = j['items'] as List? ?? [];
          WebSearchService._logger.info(
              '[WebSearch] Test Google CSE OK ${ms}ms items=${items.length}',
              tag: 'WS');
          return (true, 'Google CSE OK · ${ms}ms · 返回 ${items.length} 条结果', ms);
        } catch (_) {
          return (true, 'Google CSE HTTP 200 · ${ms}ms', ms);
        }
      }
      String detail = 'Google CSE HTTP ${resp.statusCode}';
      try {
        final j = jsonDecode(resp.body) as Map<String, dynamic>;
        final err = j['error']?['message'];
        if (err != null) detail += ' · $err';
      } catch (e) { debugPrint('catch 静默异常: $e'); }
      WebSearchService._logger
          .warn('[WebSearch] Test Google CSE fail: $detail', tag: 'WS');
      return (false, detail, ms);
    } catch (e) {
      final ms = DateTime.now().difference(t0).inMilliseconds;
      WebSearchService._logger.error(
          '[WebSearch] Test connection failed via=googlecse',
          error: e,
          tag: 'WS');
      return (false, '异常 / Exception: $e', ms);
    }
  }
}

/// 搜索引擎注册表（#1）：加新引擎在此注册一行即可，分发逻辑无需改动。
final Map<WebSearchProvider, SearchEngine> kSearchEngines = {
  WebSearchProvider.bing: BingSearchEngine(),
  WebSearchProvider.tavily: TavilySearchEngine(),
  WebSearchProvider.searxng: SearxngSearchEngine(),
  WebSearchProvider.duckduckgo: DuckDuckGoSearchEngine(),
  WebSearchProvider.serpapi: SerpApiSearchEngine(),
  WebSearchProvider.brave: BraveSearchEngine(),
  WebSearchProvider.googlecse: GoogleCseSearchEngine(),
};
