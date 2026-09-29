import 'package:flutter/material.dart';
import '../models/api_config.dart';
import '../models/chat_message.dart';

/// ChatInput 回调集合（v1.7.18 需求2）
///
/// 把原 ChatInput 9 个可选回调归并为一个不可变 value object。
/// - [onLongPressSearch] 🌐 长按 → 跳转联网搜索设置页
/// - [onLongPressReact]  🧠 长按 → 跳转自主思考设置页（build173：**长按原行为不动**，
///   档位切换并进的是🧠**点按**那个弹层，见 [onSubagentModeChanged]）
/// - [onLongTextPasted] build101（F5）长文本自动转文件：只在
///   `ChatInputConfig.pasteLongAsFile` 为 true 且文本超阈值时触发。
/// - [onModelChanged] 只承载真模型选中；选「➕编辑模型」由 ModelSwitcher
///   内部 Navigator.push(SettingsScreen)，不走此回调。
@immutable
class ChatInputActions {
  final VoidCallback? onToggleSearch;
  final VoidCallback? onOpenSearchSettings;
  final VoidCallback? onLongPressSearch;
  final VoidCallback? onLongPressReact;
  final ValueChanged<double>? onReasoningEffortChanged;
  // v1.7.37：更大上下文 Max（🧠 弹层内开关）
  final ValueChanged<bool>? onLargeContextMaxChanged;
  // build173 第三片：子代理档位（🧠 弹层内五档 chip）。与上面两个开关同一条纪律——
  // **点「应用」才写**，滑过/选中过程中不落库；原值没变时不回调（宿主无需去重）。
  final ValueChanged<String>? onSubagentModeChanged;
  final VoidCallback? onTogglePluginHint;
  final VoidCallback? onEditPluginHint;
  final ValueChanged<ApiConfig>? onModelChanged;
  final VoidCallback? onPickAttachment;
  final void Function(MessageAttachment)? onRemoveAttachment;
  /// build101（F5）：输入框内容超阈值且开启「长文本粘贴为文件」时，
  /// ChatInput 不自行落盘，只把整段文本回调上来，由 ChatScreen 生成附件。
  final ValueChanged<String>? onLongTextPasted;

  const ChatInputActions({
    this.onToggleSearch,
    this.onOpenSearchSettings,
    this.onLongPressSearch,
    this.onLongPressReact,
    this.onReasoningEffortChanged,
    this.onLargeContextMaxChanged,
    this.onSubagentModeChanged,
    this.onTogglePluginHint,
    this.onEditPluginHint,
    this.onModelChanged,
    this.onPickAttachment,
    this.onRemoveAttachment,
    this.onLongTextPasted,
  });
}
