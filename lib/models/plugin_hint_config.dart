import 'package:shared_preferences/shared_preferences.dart';

/// v1.7.17：🔌 插件提示三态开关配置模型。
///
/// 三态语义（与目录注入策略对应）：
///   - [off]    不注入 MCP/Skill 目录（内置 5 插件始终注入）
///   - [manual] 只注入 [selectedIds] 勾选的 MCP/Skill
///   - [auto]   注入全部 enabled 的 MCP/Skill
///
/// 存储用 SharedPreferences（不引 DB schema），键：
///   - `plugin_hint_mode`     (String)      mode.name
///   - `plugin_hint_selected` (StringList)  手动勾选的 MCP/Skill 插件 id
///   - `plugin_hint_extra`    (StringList)  用户附加提示词（兼容旧 `plugin_hint_items`）
///
/// 迁移：无新键时读旧键 `plugin_hint_enabled`(bool)：
///   - true  → mode=auto，旧 `plugin_hint_items` 迁移到 extraHints
///   - false → mode=off
enum PluginHintMode { off, manual, auto }

class PluginHintConfig {
  static const String kModeKey = 'plugin_hint_mode';
  static const String kSelectedKey = 'plugin_hint_selected';
  static const String kExtraKey = 'plugin_hint_extra';
  static const String kLegacyEnabledKey = 'plugin_hint_enabled';
  static const String kLegacyItemsKey = 'plugin_hint_items';

  final PluginHintMode mode;
  final List<String> selectedIds;
  final List<String> extraHints;

  const PluginHintConfig({
    this.mode = PluginHintMode.off,
    this.selectedIds = const [],
    this.extraHints = const [],
  });

  PluginHintConfig copyWith({
    PluginHintMode? mode,
    List<String>? selectedIds,
    List<String>? extraHints,
  }) =>
      PluginHintConfig(
        mode: mode ?? this.mode,
        selectedIds: selectedIds ?? this.selectedIds,
        extraHints: extraHints ?? this.extraHints,
      );

  Map<String, dynamic> toMap() => {
        'mode': mode.name,
        'selectedIds': selectedIds,
        'extraHints': extraHints,
      };

  factory PluginHintConfig.fromMap(Map<String, dynamic> m) => PluginHintConfig(
        mode: _parseMode(m['mode'] as String?),
        selectedIds: _stringList(m['selectedIds']),
        extraHints: _stringList(m['extraHints']),
      );

  Map<String, dynamic> toJson() => toMap();

  factory PluginHintConfig.fromJson(Map<String, dynamic> json) =>
      PluginHintConfig.fromMap(json);

  /// 从 SharedPreferences 读取（新键优先，无新键迁移旧键）。
  static Future<PluginHintConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    return fromPrefs(prefs);
  }

  /// 纯读取逻辑（便于单测注入 mock prefs）。
  static PluginHintConfig fromPrefs(SharedPreferences prefs) {
    final modeName = prefs.getString(kModeKey);
    if (modeName != null) {
      return PluginHintConfig(
        mode: _parseMode(modeName),
        selectedIds: prefs.getStringList(kSelectedKey) ?? const [],
        extraHints: prefs.getStringList(kExtraKey) ?? const [],
      );
    }
    // 迁移旧键
    final legacyEnabled = prefs.getBool(kLegacyEnabledKey);
    if (legacyEnabled != null) {
      if (legacyEnabled) {
        return PluginHintConfig(
          mode: PluginHintMode.auto,
          extraHints: prefs.getStringList(kLegacyItemsKey) ?? const [],
        );
      }
      return const PluginHintConfig(mode: PluginHintMode.off);
    }
    return const PluginHintConfig();
  }

  /// 写入 SharedPreferences（新键）。
  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await saveTo(prefs);
  }

  /// 纯写入逻辑。
  Future<void> saveTo(SharedPreferences prefs) async {
    await prefs.setString(kModeKey, mode.name);
    await prefs.setStringList(kSelectedKey, selectedIds);
    await prefs.setStringList(kExtraKey, extraHints);
  }

  static PluginHintMode _parseMode(String? name) {
    return PluginHintMode.values.any((e) => e.name == name)
        ? PluginHintMode.values.byName(name!)
        : PluginHintMode.off;
  }

  static List<String> _stringList(dynamic v) {
    if (v is List) return v.whereType<String>().toList(growable: false);
    return const [];
  }

  @override
  String toString() =>
      'PluginHintConfig(mode=${mode.name}, selected=${selectedIds.length}, '
      'extra=${extraHints.length})';
}
