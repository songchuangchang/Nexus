import 'package:flutter/material.dart';
import '../models/api_account.dart';
import '../models/api_config.dart';
import '../models/chat_message.dart';
import '../models/plugin_hint_config.dart';

/// ChatInput 状态快照（v1.7.18 需求2）
///
/// 把原 ChatInput 26 个零散构造参数中的「状态类」参数按 7 组归并为一个
/// 不可变 value object，使 ChatInput 构造函数降至 5 参数（config + actions +
/// controller + onSend + onStop）。
///
/// 纯数据、无逻辑、const 构造。所有字段带默认值，保证 chat_screen 迁移时
/// 漏传的字段退化为安全默认（不崩、不破坏现有行为）。
@immutable
class ChatInputConfig {
  // -------- 🌐 搜索组 --------
  final bool searchMode;
  final bool searchEnabled;

  // -------- 🧠 思考组 --------
  final int reactRounds;
  final String reactLevelLabel;
  final bool reactEnabled;
  final bool reactAutoMode;
  // 思考强度（每对话独有）0.0=默认 0.1–1.0 连续小数（1.0=深度研究档）
  final double reasoningEffort;
  // 更大上下文 Max（v1.7.37 挪入 🧠 弹层）：false=200K，true=1M
  final bool largeContextMax;

  // -------- 🔌 插件组（v1.7.17 三态）--------
  final PluginHintMode pluginHintMode;
  final int pluginHintManualCount;

  // -------- 🤖 模型组（v1.6.0）--------
  final List<ApiConfig> availableConfigs;
  final ApiConfig? currentConfig;
  /// build138（G48 账号维度）：模型条目所属的**账号**（`api_accounts`）。
  /// 只用于给「同一服务商下的两个账号」渲染小标题；缺省空列表 = 退化成
  /// 「按连接桶 + Key 切分」，分组本身不受影响（见 [splitByAccount]）。
  final List<ApiAccount> availableAccounts;

  // -------- 📎 附件组（v1.3.6）--------
  final List<MessageAttachment> pendingAttachments;

  // -------- 队列 / 状态组 --------
  final int pendingFollowupCount;
  final bool isGenerating;

  // -------- build101（F5）长文本粘贴转文件 --------
  /// 开启后，输入框内容长度达到 [pasteLongAsFileThreshold] 时**先问一句**
  /// （build129 #106 前是静默转），确认后才转成 text 类型附件
  /// （走 [ChatInputActions.onLongTextPasted]），不塞满输入框。
  final bool pasteLongAsFile;
  final int pasteLongAsFileThreshold;

  /// 阈值的**唯一取值来源**：宿主（粘贴与「外部分享进来的长文本」两条入口）
  /// 也要按同一阈值追问，不能各写一个 2000（口径分散必然漂移）。
  static const int defaultPasteLongAsFileThreshold = 2000;

  /// 功能按钮（model/search/react/plugin）的显示顺序（只含可见按钮）。
  /// 默认全部按固定顺序显示；由设置页自定义显隐/顺序（ChatSkinProvider）。
  final List<String> buttonOrder;

  const ChatInputConfig({
    this.searchMode = false,
    this.searchEnabled = true,
    this.reactRounds = 3,
    this.reactLevelLabel = '中 (Medium)',
    this.reactEnabled = true,
    this.reactAutoMode = false,
    this.reasoningEffort = 0.0,
    this.largeContextMax = false,
    this.pluginHintMode = PluginHintMode.off,
    this.pluginHintManualCount = 0,
    this.availableConfigs = const <ApiConfig>[],
    this.availableAccounts = const <ApiAccount>[],
    this.currentConfig,
    this.pendingAttachments = const <MessageAttachment>[],
    this.pendingFollowupCount = 0,
    this.isGenerating = false,
    this.pasteLongAsFile = false,
    this.pasteLongAsFileThreshold = defaultPasteLongAsFileThreshold,
    this.buttonOrder = const ['model', 'search', 'react', 'plugin'],
  });
}

/// 思考强度数值 → 展示文案（与 ApiService.reasoningEffortForConversation 阈值一致）
/// 0.0=默认(自动)；≤0.33 低；≤0.66 中；<1.0 高；1.0=深度研究档
/// build138（#4）：深度研究档原有 🔬 前缀 —— 该串会进按钮 tooltip 与弹层「当前：」
/// 行，是 V2 朴素风「去 emoji」在 lib/widgets 侧的最后一处残留（棘轮基线 emoji 1 → 0）。
String reasoningEffortLabel(double v, bool isZh) {
  if (v <= 0) return isZh ? '默认（自动）' : 'Default (auto)';
  if (v >= 1.0) return isZh ? '深度研究 MAX' : 'Deep research MAX';
  final s = v.toStringAsFixed(1);
  if (v <= 0.33) return isZh ? '低 $s' : 'Low $s';
  if (v <= 0.66) return isZh ? '中 $s' : 'Medium $s';
  return isZh ? '高 $s' : 'High $s';
}
