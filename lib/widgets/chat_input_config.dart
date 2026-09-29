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
  // build173 第三片：子代理档位（`conversations.subagentMode` 的原值，五档）。
  // **只是宿主当前值的镜像**，本文件不解释语义、不判走不走编排（判据唯一入口在
  // services 层 subagentModeUsesOrchestrator）；默认 'auto' 与 Conversation 的
  // 默认值同字，不改任何默认行为。
  final String subagentMode;

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
    this.subagentMode = 'auto',
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

/// 子代理五档的**档位名唯一所有者**（build173 第三片）。
///
/// 为什么要搬到这里：这一档现在有两处入口——🧠 点按弹层（本片的入口）与对话设置页，
/// 两张中文档位表分家必然漂（本仓口径「两处同毛病先查共享组件，逐页补会留两种口径」）。
/// 画法住在 [SubagentModePicker]（`chat_input.dart`），两处共用同一个组件、同一个名字表。
///
/// 只管**展示名**：合法值仍是 `Conversation.kSubagentModes`（模型层唯一真源），
/// 落点（走不走编排）仍只由 services 层 `subagentModeUsesOrchestrator` 判，这里不另判一套。
String subagentModeLabel(String mode, bool isZh) {
  switch (mode) {
    case 'auto':
      return isZh ? '自动 Auto' : 'Auto';
    case 'main_only':
      return isZh ? '仅主代理' : 'Main only';
    case 'force_search':
      return isZh ? '强制搜索' : 'Force search';
    case 'force_synthesis':
      return isZh ? '强制合成' : 'Force synthesis';
    case 'force_plugin':
      return isZh ? '强制插件' : 'Force plugin';
    default:
      return mode;
  }
}

/// 选中的那一档下面**一行真话**（🧠 点按弹层用，build173 第三片）。
///
/// 用户报的是「子代理启用不明显，看不出来有没有用」，而入口这一片要回答的是
/// 「我选的这一档到底会不会多花钱」⇒ 每档一行、中英文各 ≤28 字、无 emoji（R1）。
///  · `auto` 这一句必须是**否定式承诺**：默认档不走编排、不多花路由与专家调用
///    （真值出处 `services/agent_orchestrator.dart:155-157` 只认
///    `force_search` / `force_synthesis`，`:118` 只有深度研究才把 auto 归一上去）；
///  · 深度研究会把 `auto` / `main_only` 升成 `force_search`，那两行都得把这条例外
///    写进去——写了"永不派专家"就是假话；
///  · 对话设置页里那句**整句详解**（`_subagentModeHint`）留在
///    `chat_screen_context.dart`（build146 的源码锚点钉着它），本函数只给一行，
///    同一屏各说一句、不重复堆同一条事实。
String subagentModeLaneNote(String mode, bool isZh) {
  switch (mode) {
    case 'auto':
      return isZh
          ? '默认不走编排，不多花路由与专家调用'
          : 'No orchestration, no extras';
    case 'main_only':
      return isZh
          ? '只用主代理，不派专家（深度研究除外）'
          : 'Main only; deep is forced';
    case 'force_search':
      return isZh ? '每轮都走编排：先检索再作答' : 'Forced: search then answer';
    case 'force_synthesis':
      return isZh ? '每轮都走编排：以综合分析为主' : 'Forced: synthesis first';
    case 'force_plugin':
      return isZh ? '插件走自主思考循环，不经编排' : 'Plugins via the loop only';
    default:
      return '';
  }
}
