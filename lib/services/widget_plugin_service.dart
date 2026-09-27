import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'logger_service.dart';
import 'security_gate.dart';

/// build108（Q2 一期）：声明式小部件插件——「不跑任意代码的第三方生态」。
///
/// 背景：用户看到 DSH（DeepSeek Harness）社区用开源插件给界面加「余额提示」，
/// 问 Nexus 能不能支持。直接兼容 DSH 插件格式不可行（Node/JS + Web GUI 扩展点
/// vs 原生 Flutter），本服务提供安全的一期替代：**声明式 JSON manifest**——
/// HTTP 数据源 + 白名单域名 + 字段映射模板，不执行任何第三方代码，安装过
/// SecurityGate URL 审查（仅 https / 私网拦截 / 黑名单 / 重定向复检）。
/// 覆盖余额卡 / 状态卡 / 资讯卡类社区需求；JS 运行时生态缓做另立项。
///
/// Manifest 形态（一期仅支持以下字段，超集拒绝安装）：
/// ```json
/// {
///   "id": "community.weather_card",
///   "name": "天气卡",
///   "version": "1.0.0",
///   "author": "someone",
///   "description": "主页天气卡片",
///   "placement": "home_top",
///   "source": {"url": "https://api.example.com/weather", "method": "GET"},
///   "allowDomains": ["api.example.com"],
///   "refreshMinutes": 30,
///   "fields": [{"path": "data.temp", "label": "温度", "suffix": "°C"}],
///   "linkOnTap": "https://example.com"   // 可选
/// }
/// ```

class WidgetPluginManifest {
  static const int maxManifestChars = 16 * 1024;
  static const int maxFields = 6;
  static const int maxNameLen = 30;
  static const int maxDescLen = 100;

  final String id;
  final String name;
  final String version;
  final String author;
  final String description;
  final String placement; // 一期仅 'home_top'
  final String sourceUrl;
  final List<String> allowDomains;
  final int refreshMinutes;
  final List<WidgetField> fields;
  final String linkOnTap;

  const WidgetPluginManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.author,
    required this.description,
    required this.placement,
    required this.sourceUrl,
    required this.allowDomains,
    required this.refreshMinutes,
    required this.fields,
    this.linkOnTap = '',
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'version': version,
        'author': author,
        'description': description,
        'placement': placement,
        'source': {'url': sourceUrl, 'method': 'GET'},
        'allowDomains': allowDomains,
        'refreshMinutes': refreshMinutes,
        'fields': fields.map((f) => f.toMap()).toList(),
        if (linkOnTap.isNotEmpty) 'linkOnTap': linkOnTap,
      };

  static WidgetField _parseField(Object raw) {
    if (raw is! Map) throw const FormatException('fields 元素必须是对象');
    return WidgetField(
      path: raw['path']?.toString() ?? '',
      label: raw['label']?.toString() ?? '',
      suffix: raw['suffix']?.toString() ?? '',
    );
  }

  /// 从解码后的 JSON 构造；格式不合法抛 FormatException（消息可直接展示）。
  factory WidgetPluginManifest.fromJson(Map<String, dynamic> j) {
    final id = j['id']?.toString() ?? '';
    if (!RegExp(r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*){1,3}$').hasMatch(id)) {
      throw const FormatException(
          'id 不合法：需形如 community.weather_card（小写字母/数字/下划线，1~3 个点分段）');
    }
    final name = j['name']?.toString() ?? '';
    if (name.isEmpty || name.length > maxNameLen) {
      throw const FormatException('name 需为 1~$maxNameLen 字');
    }
    final description = j['description']?.toString() ?? '';
    if (description.length > maxDescLen) {
      throw const FormatException('description 不超过 $maxDescLen 字');
    }
    final placement = j['placement']?.toString() ?? '';
    if (placement != 'home_top') {
      throw const FormatException('placement 仅支持 "home_top"');
    }
    final source = j['source'];
    if (source is! Map) {
      throw const FormatException('缺少 source 对象（{"url": "...", "method": "GET"}）');
    }
    final sourceUrl = source['url']?.toString() ?? '';
    final method = (source['method']?.toString() ?? 'GET').toUpperCase();
    if (method != 'GET') {
      throw const FormatException('source.method 一期仅支持 GET');
    }
    final domainsRaw = j['allowDomains'];
    if (domainsRaw is! List || domainsRaw.isEmpty || domainsRaw.length > 5) {
      throw const FormatException('allowDomains 需为 1~5 个域名的数组');
    }
    final domains = domainsRaw.map((e) => e.toString().toLowerCase().trim()).toList();
    final host = Uri.tryParse(sourceUrl)?.host.toLowerCase() ?? '';
    if (sourceUrl.isEmpty ||
        Uri.tryParse(sourceUrl)?.scheme != 'https' ||
        host.isEmpty) {
      throw const FormatException('source.url 必须是合法的 https 地址');
    }
    var covered = false;
    for (final d in domains) {
      if (!RegExp(r'^[a-z0-9][a-z0-9.-]*$').hasMatch(d)) {
        throw FormatException('allowDomains 域名不合法：$d');
      }
      if (host == d || host.endsWith('.$d')) covered = true;
    }
    if (!covered) {
      throw FormatException('source.url 的域名（$host）必须出现在 allowDomains 白名单里');
    }
    final refresh = (j['refreshMinutes'] is num)
        ? (j['refreshMinutes'] as num).toInt()
        : int.tryParse('${j['refreshMinutes']}') ?? 0;
    if (refresh < 5 || refresh > 1440) {
      throw const FormatException('refreshMinutes 需在 5~1440 之间（防滥用限频）');
    }
    final fieldsRaw = j['fields'];
    if (fieldsRaw is! List || fieldsRaw.isEmpty || fieldsRaw.length > maxFields) {
      throw const FormatException('fields 需为 1~6 个的数组');
    }
    final fields = fieldsRaw.map((e) => _parseField(e)).toList();
    for (final f in fields) {
      if (f.path.isEmpty || f.path.length > 64) {
        throw const FormatException('fields[].path 需为 1~64 字符的 JSON 路径（如 data.temp）');
      }
      if (f.label.isEmpty || f.label.length > 12) {
        throw const FormatException('fields[].label 需为 1~12 字');
      }
      if (f.suffix.length > 8) {
        throw const FormatException('fields[].suffix 不超过 8 字');
      }
    }
    final link = j['linkOnTap']?.toString() ?? '';
    if (link.isNotEmpty && Uri.tryParse(link)?.scheme != 'https') {
      throw const FormatException('linkOnTap 必须是 https 地址');
    }
    return WidgetPluginManifest(
      id: id,
      name: name,
      version: j['version']?.toString() ?? '1.0.0',
      author: j['author']?.toString() ?? '',
      description: description,
      placement: placement,
      sourceUrl: sourceUrl,
      allowDomains: domains,
      refreshMinutes: refresh,
      fields: fields,
      linkOnTap: link,
    );
  }

  factory WidgetPluginManifest.fromMap(Map<String, dynamic> m) =>
      WidgetPluginManifest.fromJson(m);
}

class WidgetField {
  final String path;
  final String label;
  final String suffix;

  const WidgetField({
    required this.path,
    required this.label,
    this.suffix = '',
  });

  Map<String, dynamic> toMap() =>
      {'path': path, 'label': label, 'suffix': suffix};
}

/// JSON 点路径取值：支持对象键与数组下标（如 "data.list.0.temp"）。
/// 任何一步取不到返回 null。纯函数，可单测。
String? resolveJsonPath(Object? root, String path) {
  if (path.isEmpty) return null;
  final segs = path.split('.');
  if (segs.length > 8) return null;
  Object? cur = root;
  for (final seg in segs) {
    if (cur is Map) {
      cur = cur[seg];
    } else if (cur is List) {
      final idx = int.tryParse(seg);
      if (idx == null || idx < 0 || idx >= cur.length) return null;
      cur = cur[idx];
    } else {
      return null;
    }
  }
  if (cur == null) return null;
  final s = cur.toString();
  return s.length > 64 ? '${s.substring(0, 64)}…' : s;
}

class WidgetPluginService {
  static const String _listKey = 'widget_plugins_v1';
  static const String _payloadKey = 'widget_plugin_payload_v1';
  static const Duration _fetchTimeout = Duration(seconds: 10);
  static const int _maxPayloadBytes = 64 * 1024;

  static final LoggerService _logger = LoggerService.instance;

  /// build113（WP-3）：安装/卸载后 bump，主页监听它即时刷新小部件条
  /// （装机后立即可见、卸载后消失，不必等下一次 _loadData）。
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static Future<List<WidgetPluginManifest>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_listKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((m) => WidgetPluginManifest.fromMap(Map<String, dynamic>.from(m)))
          .toList();
    } catch (e) {
      _logger.warn('widget plugin list parse failed: $e', tag: 'Widget');
      return [];
    }
  }

  static Future<void> _saveAll(List<WidgetPluginManifest> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _listKey, jsonEncode(list.map((m) => m.toMap()).toList()));
  }

  /// 安装：URL 审查（SecurityGate）+ 重复 id 检查 + 持久化。
  /// 返回错误文案（null = 成功）。
  static Future<String?> add(WidgetPluginManifest manifest) async {
    try {
      final findings = await SecurityGate.auditUrl(manifest.sourceUrl);
      if (findings.isNotEmpty) {
        return '安全审查未通过：${findings.map((f) => f.title).join('；')}';
      }
      if (manifest.linkOnTap.isNotEmpty) {
        final linkFindings = await SecurityGate.auditUrl(manifest.linkOnTap);
        if (linkFindings.isNotEmpty) {
          return '安全审查未通过（linkOnTap）：${linkFindings.map((f) => f.title).join('；')}';
        }
      }
    } catch (e) {
      return '安全审查异常：$e';
    }
    final list = await load();
    if (list.any((m) => m.id == manifest.id)) {
      list.removeWhere((m) => m.id == manifest.id);
    }
    list.add(manifest);
    await _saveAll(list);
    _logger.info(
        'widget plugin installed: ${manifest.id} (${manifest.name})', tag: 'Widget');
    revision.value++;
    return null;
  }

  static Future<void> remove(String id) async {
    final list = await load();
    list.removeWhere((m) => m.id == id);
    await _saveAll(list);
    revision.value++;
    final prefs = await SharedPreferences.getInstance();
    final payloads = await _loadPayloads();
    payloads.remove(id);
    await prefs.setString(_payloadKey, jsonEncode(payloads));
  }

  // -------------------------------------------------------------------------
  // 数据拉取（带缓存 + 限频）
  // -------------------------------------------------------------------------

  static Future<Map<String, dynamic>> _loadPayloads() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_payloadKey);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } catch (_) {
      return {};
    }
  }

  /// 取某小部件的展示数据：先读缓存（含过期数据用于即时渲染），再按
  /// [refreshMinutes] 限频拉新。[force] 绕过限频（用户手动刷新）。
  /// 返回 (payload, refreshed)；payload 为 null 表示从未成功拉取。
  static Future<(Map<String, dynamic>?, bool)> fetchLatest(
      WidgetPluginManifest manifest,
      {bool force = false}) async {
    final payloads = await _loadPayloads();
    final hit = payloads[manifest.id];
    Map<String, dynamic>? payload;
    var lastT = 0;
    if (hit is Map) {
      payload = hit['data'] is Map
          ? Map<String, dynamic>.from(hit['data'] as Map)
          : null;
      lastT = (hit['t'] as num?)?.toInt() ?? 0;
    }
    final age = DateTime.now().millisecondsSinceEpoch - lastT;
    final due = lastT == 0 ||
        age > Duration(minutes: manifest.refreshMinutes).inMilliseconds;
    if (!force && !due) return (payload, false);
    final (fresh, ok) = await _fetch(manifest);
    if (ok && fresh != null) {
      payloads[manifest.id] = {
        't': DateTime.now().millisecondsSinceEpoch,
        'data': fresh,
      };
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_payloadKey, jsonEncode(payloads));
      } catch (e) {
        debugPrint('widget payload cache write failed: $e');
      }
      return (fresh, true);
    }
    return (payload, false);
  }

  /// 拉取数据源；非 https/非 200/超限/解析失败都返回 (null, false)，不抛异常。
  static Future<(Map<String, dynamic>?, bool)> _fetch(
      WidgetPluginManifest manifest) async {
    try {
      final resp = await http
          .get(Uri.parse(manifest.sourceUrl),
              headers: {'Accept': 'application/json'})
          .timeout(_fetchTimeout);
      if (resp.statusCode != 200) return (null, false);
      if (resp.bodyBytes.length > _maxPayloadBytes) {
        _logger.warn(
            'widget ${manifest.id} payload too large: ${resp.bodyBytes.length}',
            tag: 'Widget');
        return (null, false);
      }
      final decoded = jsonDecode(utf8.decode(resp.bodyBytes, allowMalformed: true));
      if (decoded is! Map) return (null, false);
      return (Map<String, dynamic>.from(decoded), true);
    } catch (e) {
      _logger.info('widget ${manifest.id} fetch failed: $e', tag: 'Widget');
      return (null, false);
    }
  }
}
