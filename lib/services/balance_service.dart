import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/api_config.dart';
import 'logger_service.dart';

/// build108（Q1 立项）：API 余额/用量查询服务。
///
/// 用户在 DSH（DeepSeek Harness）生态里见到「余额提示」插件——Nexus 官方直接
/// 做：无需第三方代码，只查「该配置自己的 base_url / 官方余额端点」，key 不出
/// 本服务。支持三类端点自动探测：
/// ①OpenAI billing 兼容（`/v1/dashboard/billing/subscription` + `/usage`，
///   one-api/new-api/Veloera 系中转普遍支持）；
/// ②DeepSeek 官方（`/user/balance`，域名含 deepseek 才尝试）；
/// ③SiliconFlow 官方（`/v1/user/info`，域名含 siliconflow 才尝试）。
/// 失败静默返回 null（不支持的端点不报错、不出 UI 噪音）。
/// 结果缓存 SharedPreferences（TTL 10 分钟），key 不落缓存/日志。

class BalanceInfo {
  /// 直接可展示的一句话，如「余额 $4.20 / 共 $10.00」或「¥110.00」
  final String display;

  /// 端点类别：openai_billing / deepseek / siliconflow
  final String kind;

  const BalanceInfo({required this.display, required this.kind});

  Map<String, dynamic> toMap() => {'display': display, 'kind': kind};

  static BalanceInfo fromMap(Map<String, dynamic> m) => BalanceInfo(
        display: m['display']?.toString() ?? '',
        kind: m['kind']?.toString() ?? '',
      );
}

class BalanceService {
  /// build138（G52）：缓存键从 config.id 换成 **账号 id** ⇒ 桶的格式变了，
  /// 键名一并升 v2，避免老缓存里按 config.id 存的条目被当成账号命中
  /// （那会是「换个模型显示别人的余额」，比没缓存更糟）。
  static const String _cacheKey = 'balance_cache_v2';
  static const Duration _ttl = Duration(minutes: 10);
  static const Duration _timeout = Duration(seconds: 8);

  static final LoggerService _logger = LoggerService.instance;

  /// 读缓存（过期返回 null）。首帧可能还没加载完（返回 null），UI 拿到
  /// cachedForAsync 结果后 setState 即可。
  static BalanceInfo? cachedFor(String cacheKey) {
    if (!_cacheLoaded) {
      unawaited(_ensureCacheLoaded());
      return null;
    }
    final hit = _cacheSnapshot[cacheKey];
    if (hit == null) return null;
    final t = (hit['t'] as num?)?.toInt() ?? 0;
    if (DateTime.now().millisecondsSinceEpoch - t > _ttl.inMilliseconds) {
      return null;
    }
    return BalanceInfo.fromMap(hit);
  }

  /// 查询指定配置的余额。失败/不支持 → null（不抛异常）。
  ///
  /// build138（G52）：键用 [ApiConfig.balanceCacheKey]（= 账号 id）。
  /// 另外加**在途合并**：一个账号下 3 个模型同屏渲染时，列表页会连着发 3 次
  /// fetchFor —— 光换缓存键挡不住（第一个还没返回，后两个就都判「无缓存」），
  /// 所以同键的并发请求共用同一个 Future，一次探活真的只发一次。
  static final Map<String, Future<BalanceInfo?>> _inFlight = {};

  static Future<BalanceInfo?> fetchFor(ApiConfig config,
      {bool force = false}) async {
    final key = config.balanceCacheKey;
    if (!force) {
      final hit = cachedFor(key);
      if (hit != null) return hit;
      final running = _inFlight[key];
      if (running != null) return running;
    }
    if (config.apiKey.trim().isEmpty) return null;
    final future = _probeAndCache(key, config);
    _inFlight[key] = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlight[key], future)) _inFlight.remove(key);
    }
  }

  static Future<BalanceInfo?> _probeAndCache(String key, ApiConfig config) async {
    try {
      final info = await _probe(config);
      if (info != null) {
        _writeCache(key, info);
      }
      return info;
    } catch (e) {
      _logger.info('Balance probe failed for ${config.name}: $e', tag: 'Balance');
      return null;
    }
  }

  // -------------------------------------------------------------------------
  // 端点探测
  // -------------------------------------------------------------------------

  static Future<BalanceInfo?> _probe(ApiConfig config) async {
    final base = config.baseUrl.trim().isEmpty
        ? ''
        : config.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (base.isEmpty) return null;
    final host = Uri.tryParse(base)?.host.toLowerCase() ?? '';

    // B-001 修复：官方判定改为「精确域名」——名字里恰含 deepseek/siliconflow
    // 的第三方中转（如 deepseek.relay.io）不再被劫持到官方端点，改走 ① billing 分支。
    final route = routeBalanceEndpoint(base);

    // ② DeepSeek 官方
    if (route == 'deepseek') {
      final j = await _getJson('https://api.deepseek.com/user/balance',
          config.apiKey, host);
      final r = parseDeepSeekBalance(j);
      if (r != null) return r;
      // B-001：官方端点拿不到数据时回落 billing 兼容分支，而不是直接 return null
    }
    // ③ SiliconFlow 官方
    if (route == 'siliconflow') {
      final j = await _getJson('https://api.siliconflow.cn/v1/user/info',
          config.apiKey, host);
      final r = parseSiliconFlowInfo(j);
      if (r != null) return r;
    }
    // ① OpenAI billing 兼容（one-api/new-api 系中转普遍支持）
    final sub = await _getJson('$base/v1/dashboard/billing/subscription',
        config.apiKey, host);
    final now = DateTime.now();
    final usage = await _getJson(
      '$base/v1/dashboard/billing/usage'
      '?start_date=2023-01-01&end_date=${now.add(const Duration(days: 1)).toIso8601String().substring(0, 10)}',
      config.apiKey,
      host,
    );
    return parseOpenAIBilling(sub, usage);
  }

  /// B-001：端点路由（纯函数，可单测）。
  ///
  /// 只有**精确域名**才走官方端点（`api.deepseek.com` 或 `*.deepseek.com`）；
  /// 名字里恰好含 "deepseek"/"siliconflow" 的第三方中转（如 `deepseek.relay.io`、
  /// `xxx.siliconflow.xyz`）一律走 OpenAI billing 兼容分支——避免被劫持到官方
  /// 域名后用中转 key 打官方接口（必 401，余额永远空白）。
  @visibleForTesting
  static String routeBalanceEndpoint(String baseUrl) {
    final host = Uri.tryParse(baseUrl.trim())?.host.toLowerCase() ?? '';
    if (host.isEmpty) return 'openai_billing';
    bool official(String domain) =>
        host == 'api.$domain' || host.endsWith('.$domain');
    if (official('deepseek.com')) return 'deepseek';
    if (official('siliconflow.cn')) return 'siliconflow';
    return 'openai_billing';
  }

  static Future<Map<String, dynamic>?> _getJson(
      String url, String apiKey, String hostForLog) async {
    final resp = await http
        .get(Uri.parse(url), headers: {
      'Authorization': 'Bearer $apiKey',
      'Accept': 'application/json',
    }).timeout(_timeout);
    if (resp.statusCode != 200) {
      _logger.info(
          'Balance endpoint HTTP ${resp.statusCode} @ $hostForLog', tag: 'Balance');
      return null;
    }
    // B-002 修复：200 但 body 非 JSON（中转错误页/空体）时不能抛异常——
    // 否则整个探测链被中断，后面候选端点（含 B-001 的回落分支）没有机会执行。
    try {
      final decoded =
          jsonDecode(utf8.decode(resp.bodyBytes, allowMalformed: true));
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      _logger.info('Balance endpoint non-JSON body @ $hostForLog',
          tag: 'Balance');
      return null;
    }
  }

  // -------------------------------------------------------------------------
  // 纯函数解析（可单测）
  // -------------------------------------------------------------------------

  /// `/billing/subscription` → hard_limit_usd（解析不到返回 0）
  static double parseSubscriptionLimit(Map<String, dynamic>? json) {
    if (json == null) return 0;
    final v = json['hard_limit_usd'] ?? json['system_hard_limit_usd'];
    return (v is num) ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0);
  }

  /// ① OpenAI billing 兼容组装：余额 = hard_limit - total_usage/100（美分→美元）
  static BalanceInfo? parseOpenAIBilling(
      Map<String, dynamic>? sub, Map<String, dynamic>? usage) {
    if (sub == null && usage == null) return null;
    final limit = parseSubscriptionLimit(sub);
    final usedRaw = usage?['total_usage'];
    final used = (usedRaw is num) ? usedRaw.toDouble() : 0.0;
    final usedUsd = used / 100.0;
    if (limit > 0) {
      final remain = limit - usedUsd;
      return BalanceInfo(
        display: '余额 \$${remain.toStringAsFixed(2)} / 共 \$${limit.toStringAsFixed(2)}',
        kind: 'openai_billing',
      );
    }
    if (used > 0) {
      return BalanceInfo(
        display: '已用 \$${usedUsd.toStringAsFixed(2)}',
        kind: 'openai_billing',
      );
    }
    return null;
  }

  /// ② DeepSeek `/user/balance` → balance_infos[0].total_balance
  static BalanceInfo? parseDeepSeekBalance(Map<String, dynamic>? json) {
    if (json == null) return null;
    final infos = json['balance_infos'];
    if (infos is! List || infos.isEmpty) return null;
    final first = infos.first;
    if (first is! Map) return null;
    final total = first['total_balance']?.toString() ?? '';
    if (total.isEmpty) return null;
    final currency = first['currency']?.toString() ?? '';
    final symbol = currency == 'USD' ? '\$' : (currency == 'CNY' ? '¥' : '$currency ');
    return BalanceInfo(display: '$symbol$total', kind: 'deepseek');
  }

  /// ③ SiliconFlow `/v1/user/info` → data.totalBalance / balance
  static BalanceInfo? parseSiliconFlowInfo(Map<String, dynamic>? json) {
    if (json == null) return null;
    final data = json['data'];
    if (data is! Map) return null;
    final total = (data['totalBalance'] ?? data['balance'])?.toString() ?? '';
    if (total.isEmpty) return null;
    return BalanceInfo(display: '¥$total', kind: 'siliconflow');
  }

  // -------------------------------------------------------------------------
  // 缓存
  // -------------------------------------------------------------------------

  static Map<String, dynamic> _cacheSnapshot = {};
  static bool _cacheLoaded = false;

  static Future<void> _ensureCacheLoaded() async {
    if (_cacheLoaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_cacheKey);
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          _cacheSnapshot = Map<String, dynamic>.from(decoded);
        }
      } catch (_) {}
    }
    _cacheLoaded = true;
  }

  static Future<void> _writeCache(String configId, BalanceInfo info) async {
    await _ensureCacheLoaded();
    _cacheSnapshot[configId] = {
      't': DateTime.now().millisecondsSinceEpoch,
      ...info.toMap(),
    };
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey, jsonEncode(_cacheSnapshot));
    } catch (e) {
      debugPrint('balance cache write failed: $e');
    }
  }

  /// 缓存读取统一走异步初始化（cachedFor 供 UI 同步首屏用，走快照即可）
  static Future<BalanceInfo?> cachedForAsync(String configId) async {
    await _ensureCacheLoaded();
    final hit = _cacheSnapshot[configId];
    if (hit == null) return null;
    final t = (hit['t'] as num?)?.toInt() ?? 0;
    if (DateTime.now().millisecondsSinceEpoch - t > _ttl.inMilliseconds) {
      return null;
    }
    return BalanceInfo.fromMap(hit);
  }
}
