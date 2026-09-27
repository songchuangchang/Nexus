import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data_pack_pref_keys.dart';
import 'data_pack_protocol.dart';

/// v1.7.24 (#5/#6)：内置插件 ReAct 协议目录 —— 内置默认 + 远程 JSON 覆盖。
///
/// 解决两个硬编码痛点：
///   #5 builtin_plugins 的 promptProtocol 硬编码在代码里（改提示词需发版）；
///   #6 ReAct prompt 模板 / 触发词需改代码才能加协议标签。
///
/// 方案：内置默认保留（离线兜底），运行时先查远程覆盖（按插件 id），
/// 命中则用远程文本，否则回落内置。这样「改协议 / 加标签」只需更新远程 JSON，无需发版。
///
/// 远程 JSON 格式（二选一）：
///   A. `{"plugins": [ {"id": "nexus.builtin.search", "promptProtocol": "..."}, ... ]}`
///   B. `{"prompts": {"nexus.builtin.search": "..."}, "triggerWords": {"download": ["..."]}}`
///
/// build138（G54–G56）：缓存读写 / 多源有序回退 / 版本与 sha256 闸门 / 状态记账
/// **已全部收敛到 `DataPackService`**（本文件不再自己拉网络、不再自己排 7 天刷新），
/// 这里只保留「把已校验的 JSON 应用进内存 + 按 key 解析生效值」。
class BuiltinPromptCatalog {
  BuiltinPromptCatalog._();

  static final BuiltinPromptCatalog instance = BuiltinPromptCatalog._();

  final Map<String, String> _remotePrompts = {};
  final Map<String, String> _remoteFormats = {};
  final Map<String, List<String>> _remoteTriggerWords = {};

  String lastMessage = '';

  DateTime? lastUpdatedAt;

  bool get hasRemote => _remotePrompts.isNotEmpty;

  /// 测试钩子：清空远程覆盖（单例是进程级状态，用例之间必须隔离）。
  @visibleForTesting
  void resetForTest() {
    _remotePrompts.clear();
    _remoteFormats.clear();
    _remoteTriggerWords.clear();
    lastMessage = '';
    lastUpdatedAt = null;
  }

  /// build131：缓存「陈旧到不可信」的阈值（判定实现收敛到 data_pack_protocol）。
  ///
  /// 原策略是「刷新失败不清空旧缓存」（容忍网络抖动）——这条本身没错，但它没有
  /// 上界：源一旦永久失效，设备上那份**旧覆盖会被无限期沿用**，发版改好的内置协议
  /// 在这台设备上永远不生效。折中由 `DataPackService` 统一执行：抖动期照旧保留，
  /// 陈旧超过阈值又刷不上新才丢弃。
  static bool isCacheStale(
    DateTime? updatedAt,
    DateTime now, {
    Duration staleAfter = kDataPackCacheStaleAfter,
  }) =>
      isDataPackCacheStale(updatedAt, now, staleAfter: staleAfter);

  /// 丢弃远程覆盖、回落内置默认（build131：陈旧缓存自愈；也供测试直接驱动）。
  Future<void> discardRemoteCache(SharedPreferences? prefs) async {
    _remotePrompts.clear();
    _remoteFormats.clear();
    _remoteTriggerWords.clear();
    lastUpdatedAt = null;
    if (prefs != null) await prefs.remove(DataPackPrefKeys.promptsJson);
    lastMessage = '远程协议刷新失败且本地缓存已过期，已回落内置默认';
  }

  /// 解析生效协议：远程覆盖优先，否则内置默认。
  String resolve(String pluginId, String builtin) =>
      _remotePrompts[pluginId] ?? builtin;

  String resolveFormat(String triggerType, String builtin) =>
      _remoteFormats[triggerType] ?? builtin;

  List<String> triggerWords(String triggerType) =>
      List.unmodifiable(_remoteTriggerWords[triggerType] ?? const []);

  /// build140（P0 缺口⑤）：这一条协议的**生效值是否来自远程覆盖**。
  ///
  /// 存在的唯一理由：以前用户/开发者看不出「我改了远程 JSON 到底生效没有」——
  /// `resolve()` 静默返回一段文本，没人知道它是内置的还是覆盖来的。
  /// 浏览页（`builtin_prompt_catalog_screen.dart`）用它标「远程覆盖 / 内置默认」。
  bool isPromptOverridden(String pluginId) => _remotePrompts.containsKey(pluginId);

  /// 被远程覆盖的插件 id 集合（只读快照，供浏览页统计条数）。
  List<String> get overriddenPluginIds => List.unmodifiable(_remotePrompts.keys);

  bool matchesTriggerWords(String triggerType, String raw) {
    final text = raw.trim().toLowerCase();
    return triggerWords(triggerType)
        .any((word) => text.contains(word.toLowerCase()));
  }

  /// 用原始 JSON 字符串更新（本地资产 / 测试复用）。
  bool applyJson(String rawJson) {
    try {
      final decoded = jsonDecode(rawJson);
      final prompts = _extractPrompts(decoded);
      final formats = _extractFormats(decoded);
      final triggerWords = _extractTriggerWords(decoded);
      if (prompts.isEmpty && formats.isEmpty && triggerWords.isEmpty) {
        lastMessage = 'JSON 中无有效协议、格式或触发词';
        return false;
      }
      _remotePrompts
        ..clear()
        ..addAll(prompts);
      _remoteFormats
        ..clear()
        ..addAll(formats);
      _remoteTriggerWords
        ..clear()
        ..addAll(triggerWords);
      lastUpdatedAt = DateTime.now();
      lastMessage = '已更新 ${prompts.length} 条协议';
      return true;
    } catch (e) {
      lastMessage = '解析失败: $e';
      return false;
    }
  }

  Map<String, String> _extractFormats(Object? decoded) {
    if (decoded is! Map || decoded['formats'] is! Map) return const {};
    final out = <String, String>{};
    (decoded['formats'] as Map).forEach((k, v) {
      final value = v?.toString() ?? '';
      if (value.isNotEmpty) out[k.toString()] = value;
    });
    return out;
  }

  Map<String, List<String>> _extractTriggerWords(Object? decoded) {
    if (decoded is! Map || decoded['triggerWords'] is! Map) return const {};
    final out = <String, List<String>>{};
    (decoded['triggerWords'] as Map).forEach((k, v) {
      if (v is List) {
        final words = v
            .map((item) => item.toString().trim())
            .where((item) => item.isNotEmpty)
            .toList(growable: false);
        if (words.isNotEmpty) out[k.toString()] = words;
      }
    });
    return out;
  }

  Map<String, String> _extractPrompts(Object? decoded) {
    final out = <String, String>{};
    if (decoded is Map && decoded['plugins'] is List) {
      for (final p in (decoded['plugins'] as List).whereType<Map>()) {
        final id = p['id']?.toString();
        final pp = p['promptProtocol']?.toString();
        if (id != null && id.isNotEmpty && pp != null && pp.isNotEmpty) {
          out[id] = pp;
        }
      }
    } else if (decoded is Map && decoded['prompts'] is Map) {
      (decoded['prompts'] as Map).forEach((k, v) {
        final s = v.toString();
        if (s.isNotEmpty) out[k.toString()] = s;
      });
    }
    return out;
  }
}
