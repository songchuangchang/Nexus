import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 聊天页功能按钮配置（Chatbox 朴素风重构）。
///
/// v1.7.38：皮肤开关已移除（V2 朴素皮肤常驻），此类只保留
/// 输入框功能按钮（🤖模型/🌐搜索/🧠思考/🔌插件）的显隐与顺序：
/// `chatFeatureButtonOrder`（StringList，按序存可见按钮 id），
/// `chatFeatureButtonHidden`（StringList，隐藏的按钮 id）。
///
/// build101（D1~D5）：新增「外观开关族」+ 头像/背景图路径 + 主题模式。
/// 设计口径（用户 2026-09-12 拍板）：**全部默认关**，朴素风是默认态，
/// 头像是可选装饰层，二者不冲突。
class ChatSkinProvider extends ChangeNotifier {
  static const String _orderKey = 'chatFeatureButtonOrder';
  static const String _hiddenKey = 'chatFeatureButtonHidden';

  // ============ build101（D1/D2）头像与背景图路径 ============
  static const String _userAvatarKey = 'chatUserAvatarPath';
  static const String _aiAvatarKey = 'chatAiAvatarPath';
  static const String _backgroundKey = 'chatBackgroundPath';

  // ============ build101（D3）显示开关族 ============
  static const String _showAvatarKey = 'chatShowAvatar';
  static const String _showBubbleKey = 'chatShowBubble';
  static const String _leftAlignKey = 'chatLeftAlign';
  static const String _showTimestampKey = 'chatShowTimestamp';
  static const String _showModelNameKey = 'chatShowModelName';
  static const String _showTokenUsageKey = 'chatShowTokenUsage';
  static const String _showCharCountKey = 'chatShowCharCount';
  static const String _showFirstTokenLatencyKey = 'chatShowFirstTokenLatency';
  static const String _hideSystemPromptKey = 'chatHideSystemPrompt';
  static const String _autoScrollTopKey = 'chatAutoScrollTop';
  static const String _autoTitleKey = 'chatAutoGenerateTitle';
  static const String _pasteAsFileKey = 'chatPasteLongAsFile';
  static const String _metaInjectionKey = 'chatInjectMetadata';

  // ============ build101（D5）主题模式 ============
  static const String _themeModeKey = 'chatThemeMode';

  /// 全部可配置的功能按钮 id（固定全集，顺序=默认顺序）
  static const List<String> allButtonIds = [
    'model',
    'search',
    'react',
    'plugin'
  ];

  List<String> _order = List.of(allButtonIds);
  Set<String> _hidden = {};

  // 头像 / 背景图（空串 = 未设置）
  String _userAvatarPath = '';
  String _aiAvatarPath = '';
  String _backgroundPath = '';

  // 显示开关族（默认全部关/保持现状）
  bool _showAvatar = false;
  bool _showBubble = false; // false = AI 侧通栏无气泡（现有朴素风）
  bool _leftAlign = false; // false = 现有布局（AI 左 / 用户右）
  bool _showTimestamp = false;
  bool _showModelName = true; // 现有行为：模型名常驻
  bool _showTokenUsage = true; // 现有行为：token 常驻
  bool _showCharCount = false;
  bool _showFirstTokenLatency = false;
  bool _hideSystemPrompt = false;
  bool _autoScrollTop = false;
  bool _autoTitle = false;
  bool _pasteAsFile = false;
  bool _injectMetadata = false;

  // 主题模式：system / light / dark
  String _themeMode = 'system';

  String get userAvatarPath => _userAvatarPath;
  String get aiAvatarPath => _aiAvatarPath;
  String get backgroundPath => _backgroundPath;

  bool get showAvatar => _showAvatar;
  bool get showBubble => _showBubble;
  bool get leftAlign => _leftAlign;
  bool get showTimestamp => _showTimestamp;
  bool get showModelName => _showModelName;
  bool get showTokenUsage => _showTokenUsage;
  bool get showCharCount => _showCharCount;
  bool get showFirstTokenLatency => _showFirstTokenLatency;
  bool get hideSystemPrompt => _hideSystemPrompt;
  bool get autoScrollTop => _autoScrollTop;
  bool get autoTitle => _autoTitle;
  bool get pasteAsFile => _pasteAsFile;
  bool get injectMetadata => _injectMetadata;
  String get themeMode => _themeMode;

  /// 当前生效的按钮顺序（只含未隐藏的，未知 id 自动过滤）
  /// build98（P2）：旧版本存档里缺新增按钮 id 时自动补到末尾，不只过滤
  List<String> get visibleButtonOrder {
    final known =
        _order.where((id) => allButtonIds.contains(id)).toList();
    for (final id in allButtonIds) {
      if (!known.contains(id)) known.add(id); // 新增按钮补全
    }
    return known.where((id) => !_hidden.contains(id)).toList();
  }

  /// 完整顺序（含隐藏的，供设置页展示/排序）
  List<String> get fullOrder {
    final result = _order.where(allButtonIds.contains).toList();
    for (final id in allButtonIds) {
      if (!result.contains(id)) result.add(id);
    }
    return result;
  }

  bool isHidden(String id) => _hidden.contains(id);

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final order = prefs.getStringList(_orderKey);
    if (order != null && order.isNotEmpty) {
      _order = order;
    }
    _hidden = (prefs.getStringList(_hiddenKey) ?? []).toSet();

    // build101：外观一族
    _userAvatarPath = prefs.getString(_userAvatarKey) ?? '';
    _aiAvatarPath = prefs.getString(_aiAvatarKey) ?? '';
    _backgroundPath = prefs.getString(_backgroundKey) ?? '';
    _showAvatar = prefs.getBool(_showAvatarKey) ?? false;
    _showBubble = prefs.getBool(_showBubbleKey) ?? false;
    _leftAlign = prefs.getBool(_leftAlignKey) ?? false;
    _showTimestamp = prefs.getBool(_showTimestampKey) ?? false;
    _showModelName = prefs.getBool(_showModelNameKey) ?? true;
    _showTokenUsage = prefs.getBool(_showTokenUsageKey) ?? true;
    _showCharCount = prefs.getBool(_showCharCountKey) ?? false;
    _showFirstTokenLatency = prefs.getBool(_showFirstTokenLatencyKey) ?? false;
    _hideSystemPrompt = prefs.getBool(_hideSystemPromptKey) ?? false;
    _autoScrollTop = prefs.getBool(_autoScrollTopKey) ?? false;
    _autoTitle = prefs.getBool(_autoTitleKey) ?? false;
    _pasteAsFile = prefs.getBool(_pasteAsFileKey) ?? false;
    _injectMetadata = prefs.getBool(_metaInjectionKey) ?? false;
    _themeMode = prefs.getString(_themeModeKey) ?? 'system';

    notifyListeners();
  }

  Future<void> setButtonHidden(String id, bool hidden) async {
    if (hidden) {
      _hidden.add(id);
    } else {
      _hidden.remove(id);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_hiddenKey, _hidden.toList());
    notifyListeners();
  }

  Future<void> setButtonOrder(List<String> order) async {
    _order = List.of(order);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_orderKey, _order);
    notifyListeners();
  }

  /// 设置页 ReorderableListView onReorderItem 回调辅助
  /// （onReorderItem 已对 newIndex 做过移除项修正，此处不再 -1）
  Future<void> reorderItem(int oldIndex, int newIndex) async {
    final list = fullOrder;
    final item = list.removeAt(oldIndex);
    list.insert(newIndex, item);
    await setButtonOrder(list);
  }

  // ==================== build101：外观写入方法 ====================

  /// 设置头像（path 为空串 = 清除）
  Future<void> setAvatar({required bool isUser, required String path}) async {
    if (isUser) {
      _userAvatarPath = path;
    } else {
      _aiAvatarPath = path;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(isUser ? _userAvatarKey : _aiAvatarKey, path);
    notifyListeners();
  }

  Future<void> setBackground(String path) async {
    _backgroundPath = path;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_backgroundKey, path);
    notifyListeners();
  }

  /// 通用显示开关写入（key 用内部前缀常量，避免调用方拼错）
  Future<void> setFlag(String key, bool value) async {
    switch (key) {
      case 'showAvatar':
        _showAvatar = value;
        break;
      case 'showBubble':
        _showBubble = value;
        break;
      case 'leftAlign':
        _leftAlign = value;
        break;
      case 'showTimestamp':
        _showTimestamp = value;
        break;
      case 'showModelName':
        _showModelName = value;
        break;
      case 'showTokenUsage':
        _showTokenUsage = value;
        break;
      case 'showCharCount':
        _showCharCount = value;
        break;
      case 'showFirstTokenLatency':
        _showFirstTokenLatency = value;
        break;
      case 'hideSystemPrompt':
        _hideSystemPrompt = value;
        break;
      case 'autoScrollTop':
        _autoScrollTop = value;
        break;
      case 'autoTitle':
        _autoTitle = value;
        break;
      case 'pasteAsFile':
        _pasteAsFile = value;
        break;
      case 'injectMetadata':
        _injectMetadata = value;
        break;
      default:
        return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsKeyOf(key), value);
    notifyListeners();
  }

  bool flagOf(String key) {
    switch (key) {
      case 'showAvatar':
        return _showAvatar;
      case 'showBubble':
        return _showBubble;
      case 'leftAlign':
        return _leftAlign;
      case 'showTimestamp':
        return _showTimestamp;
      case 'showModelName':
        return _showModelName;
      case 'showTokenUsage':
        return _showTokenUsage;
      case 'showCharCount':
        return _showCharCount;
      case 'showFirstTokenLatency':
        return _showFirstTokenLatency;
      case 'hideSystemPrompt':
        return _hideSystemPrompt;
      case 'autoScrollTop':
        return _autoScrollTop;
      case 'autoTitle':
        return _autoTitle;
      case 'pasteAsFile':
        return _pasteAsFile;
      case 'injectMetadata':
        return _injectMetadata;
      default:
        return false;
    }
  }

  String _prefsKeyOf(String key) {
    switch (key) {
      case 'showAvatar':
        return _showAvatarKey;
      case 'showBubble':
        return _showBubbleKey;
      case 'leftAlign':
        return _leftAlignKey;
      case 'showTimestamp':
        return _showTimestampKey;
      case 'showModelName':
        return _showModelNameKey;
      case 'showTokenUsage':
        return _showTokenUsageKey;
      case 'showCharCount':
        return _showCharCountKey;
      case 'showFirstTokenLatency':
        return _showFirstTokenLatencyKey;
      case 'hideSystemPrompt':
        return _hideSystemPromptKey;
      case 'autoScrollTop':
        return _autoScrollTopKey;
      case 'autoTitle':
        return _autoTitleKey;
      case 'pasteAsFile':
        return _pasteAsFileKey;
      case 'injectMetadata':
        return _metaInjectionKey;
      default:
        return key;
    }
  }

  Future<void> setThemeMode(String mode) async {
    _themeMode = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeModeKey, mode);
    notifyListeners();
  }
}

