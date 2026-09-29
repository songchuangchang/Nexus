import 'dart:async';
import 'dart:io';
// build138 真机反馈③：「回到底部」胶囊改毛玻璃需要 ImageFilter.blur，
// 它只由 dart:ui 直接导出（package:flutter/material.dart 不带出这个符号）。
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../l10n/app_localizations.dart';
import '../models/api_account.dart';
import '../models/api_config.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../models/memory_models.dart';
import '../models/knowledge_base.dart';
import '../models/assistant.dart';
import '../models/context_compaction_segment.dart';
import '../models/shared_payload.dart';
import '../models/plugin_hint_config.dart';
import '../models/web_search_config.dart';
import '../models/usage_stat.dart';
import '../plugins/builtin_plugin_i18n.dart';
import '../plugins/plugin_context.dart';
import '../plugins/plugin_interface.dart';
import '../plugins/plugin_registry.dart';
import '../providers/chat_skin_provider.dart';
import '../services/live_task_wiring.dart';
// build162：「回到前台」那一下的通知点（唯一通知方是 main.dart 那个 lifecycle observer）。
import '../services/app_resume_signal.dart';
import '../services/answer_finalizer.dart';
import '../services/agent_orchestrator.dart';
import '../services/agent_tools.dart';
import '../services/api_service.dart';
import '../services/app_download_service.dart';
// build171：编排/ReAct 那一条的截断标注要与出网体同源，需要 resolveChatProtocol
// 与 anthropicMaxTokens 判"这一支到底发没发 max_tokens"。放在宿主库里 import
// （part 文件不许带 import），两个 part 文件 chat_screen_react / chat_screen_orchestrator 共用。
import '../services/protocol/anthropic_protocol.dart';
import '../services/attachment_service.dart';
import '../services/conversation_summary_service.dart';
import '../services/context_budget_service.dart';
import '../services/logger_service.dart';
import '../services/memory_block_builder.dart';
import '../services/model_capability_memory.dart';
import '../constants.dart' show kUseTypedKernel;
import '../services/plugin_prompt_catalog.dart';
import '../services/mcp_id_normalizer.dart';
import '../services/react_stream_scrubber.dart';
import '../services/rag_service.dart';
import '../services/agent_kernel.dart';
import '../services/react_parser.dart';
import '../services/share_intent_service.dart';
// O11（build96）：直聊路径 todo 补解析复用同一套纯函数（mergeTodoItems），
// 与 ReAct 路径行为一致（add 增量合并，不再清空重建）。
import '../plugins/builtin_plugins.dart'
    show mergeTodoItems, kPromptPluginMcpDeps;
import '../services/security_scan_service.dart';
import '../services/storage_service.dart';
// build129：对话设置面板里的「生成模型」选择器要读两边的「上游建议模型」缓存。
import '../services/image_gen_service.dart';
import '../services/video_gen_service.dart';
import '../services/text_recognition_service.dart';
import '../services/web_search_service.dart';
import 'api_config_screen.dart';
import 'model_compare_screen.dart';
import '../widgets/app_source_selector.dart';
// build139（真机反馈④）：反问面板抽成独立 widget 后，本文件的 part（
// chat_screen_react.dart）继续用 showAskUserPanel —— part 共用主文件的 import，
// 所以这一行不能挪到 part 里，也不能删（删了 part 就找不到符号）。
import '../widgets/ask_user_dialog.dart';
import '../widgets/download_confirm_dialog.dart';
// build147：`download_progress_widget.dart` 的 import 随 AI 直链下载不再弹进度框
// 而失效（唯一引用点在 chat_screen_download 的那段已删），留着就是未使用 import。
import '../widgets/chat_input.dart';
import '../widgets/chat_input_actions.dart';
import '../widgets/chat_input_config.dart';
import '../widgets/chat_screen_widgets.dart';
import '../widgets/chat_todo_strip.dart';
import '../widgets/message_bubble_v2.dart';
import 'chat_search_screen.dart';
import 'plugin_management_screen.dart';
import 'settings_screen.dart';
import 'web_search_settings_screen.dart';
import '../utils/app_snackbar.dart';
// build140（P0 缺口⑤ 接线）：知识库检索阈值的用户偏好。
// 消费点在 part 文件 chat_screen_message.dart 的 _buildKnowledgeContext()——
// part 文件不能自带 import（见下方注释），所以偏好键的导入必须落在这个宿主上。
import '../utils/kb_retrieval_settings.dart';
import '../utils/round_exit.dart';
import '../utils/round_timing.dart';
import '../utils/stop_round.dart';
// build146（prompt cache ②③④）：注入块前缀稳定排序。消费点在 part 文件
// chat_screen_{message,react,orchestrator}.dart —— part 文件不能自带 import，
// 故 prompt_prefix 的导入必须落在本宿主（同上方 kb_retrieval_settings 口径）。
import '../utils/prompt_prefix.dart';
// build161 ①③：掉线自动续一轮的判据（纯函数）。消费点在 part 文件
// chat_screen_react.dart（catch 决策 + finally 接手续写）与本文件的气泡接线——
// part 文件不能自带 import，同上方 prompt_prefix 口径落在宿主上。
import '../utils/drop_continue.dart';
// build167（用户 26 日 18:4x「我开了后台，退出来又给我暂停」）：「愿意后台化」总闸的
// 持久化位。消费点在 part 文件 chat_screen_message.dart 的 `_onAppLeftForeground`
// —— part 文件不能自带 import（同上方 drop_continue 口径），所以导入落在宿主这里。
// 判据本身在 `drop_continue.dart` 的 `shouldAbortStreamOnLeaveApp`，这里只读那一位。
import '../utils/background_run_switch.dart';
// build126 (B2)：弹层统一入口 + 设计令牌。
// 注意：本文件是 chat_screen_{context,download,message,react}.dart 的 part 宿主，
// 那 4 个 part 文件不能自带 import，所以它们的弹层改造也依赖这两行。
import '../ui/app_sheet.dart';
// build168（宽屏档）：内容列宽度的唯一所有者。断点与列宽都不写在页面上，
// 本文件只负责把聊天内容那一棵子树交给 AppContentColumn（见 _withBackground）。
import '../ui/app_content.dart';
// build138（甲3）：「只看收藏」筛到零条时的空态——复用统一四态外壳与空态组件，
// 不再手搓一个居中大灰字（那正是本项目空态最常见的失败形态：看不出为什么空、
// 也看不出怎么出去）。
import '../ui/app_async_view.dart';
import '../ui/app_state_view.dart';
import '../ui/tokens.dart';

part 'chat_screen_context.dart';
part 'chat_screen_download.dart';
part 'chat_screen_message.dart';
part 'chat_screen_orchestrator.dart';
part 'chat_screen_react.dart';

/// 聊天主界面（v1.3.0 大改版点）
///
/// 相比 v1.2.4 的变化：
/// - 增加 🌐 搜索按钮驱动的"消息发送前联网搜索"
/// - 当搜索模式关闭（searchMode=false）或搜索无结果时，**在回复消息顶部插入黄色警告条**："⚠️ 基于AI内置知识 — 可能已过时"
/// - APP 下载请求整合 AI 决策流程：
///     1. 先用 AI 识别意图（已用 detectDownloadIntent，无变化）
///     2. 若在内置目录 → 直接展示结果，但仍弹出"AI内置知识可能过时"的确认对话框
///     3. 不在内置目录 → 弹出"需要联网搜索，第三方链接需你确认"的提示
///     4. 若总开关关了 → 弹出"联网搜索已关闭，是否前往设置打开"
/// - 全程通过 LoggerService 写事件日志（严格不记聊天内容 / API Key）
class ChatScreen extends StatefulWidget {
  final Conversation conversation;

  /// build123：由「分享到 Nexus」带进来的载荷。
  /// 文本/网址 → 直接粘进输入框（不自动发送）；文件 → 变成待发附件
  /// （输入框上方出现预览条，点 × 即取消）。
  final SharedPayload? initialShare;

  const ChatScreen({super.key, required this.conversation, this.initialShare});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _inputController = TextEditingController();
  final LoggerService _logger = LoggerService.instance;
  late final VoidCallback _inputListener;
  /// build138（扫描 P2-3）：当前这一轮 ReAct 交给插件层的 [PluginContext]。
  /// 只为让 `dispose()` 能把它置为 unmounted —— 插件里那些
  /// `if (!pc.mounted) return` 护栏此前读的是构造时快照，退页后仍为 true。
  /// 赋值点在 chat_screen_react.dart 的 dispatch 之前。
  PluginContext? _livePluginContext;
  // build90 ⑨：斜杠命令面板当前匹配项（空 = 面板隐藏）
  List<SlashCommand> _slashMatches = const [];
  String get _draftPrefsKey => 'chat_draft_${widget.conversation.id}';

  // v1.7.18：ChatInput v2（5 参数重构）需要外部 FocusNode
  final FocusNode _inputFocus = FocusNode();

  // ===== v1.7.22：撤回重试系统（v1.7.26 (E3) 起版本快照持久化到
  // message_versions 表，此处仅作为会话内缓存，重启后由 _loadData 恢复）=====
  final Map<String, List<RetryVersion>> _retryVersionStore = {};
  final Map<String, int> _activeRetryVersionIndex = {};

  // ===== v1.7.21 P1-2：发送前 API 连接快速自检（30 秒缓存，避免每条消息都测）=====
  DateTime? _lastApiTestTime;
  bool _lastApiTestOk = false;

  List<ChatMessage> _messages = [];
  // build101（B4）：本会话被引用（星标）的消息 id 集合。
  // 从 widget.conversation.starredIds 初始化；长按菜单里切换后就地 setState 刷新。
  Set<String> _starredIds = {};
  // build138（甲3）：只看收藏。是**视图态**而非数据态——不落库、不持久化，
  // 因为它的语义只属于"这一次翻看"，重进会话还带着筛选会让人找不到新消息。
  bool _starredOnly = false;

  /// build138（甲3）：列表取数唯一入口（口径在 applyStarredFilter）。
  ///
  /// 刻意用 getter 而不是缓存在 setState 里重算：_messages/_starredIds 的写点
  /// 分散在本文件的 5 个 part 里（流式追加、重试、撤回、删除、收藏切换），
  /// 缓存一旦漏更新一处就是"筛后少一条且没人知道为什么"。
  /// 一次 O(n) 过滤换掉一整类不同步 bug，n 是单会话消息数，代价可忽略。
  List<ChatMessage> get _visibleMessages =>
      applyStarredFilter(_messages, _starredIds, starredOnly: _starredOnly);
  // v1.7.37：压缩段（Trae 式可见化）——消息流里渲染「📦 已压缩」卡片
  List<ContextCompactionSegment> _compactionSegments = [];
  // v1.7.37（⑱）：上下文用量条（已用 / 预算 tokens）
  int _contextUsedTokens = 0;

  /// build141（反馈④）：**自愈护栏**用的上一次消息条数快照。
  ///
  /// 用量是 `_messages` 的派生值，历史上全靠 12 个「记得调用 `_refreshContextUsage()`」
  /// 的点维持一致，结果已经漏掉 3 处（撤回 / 删除 / 无 Key 下载兜底）——
  /// 这类漏点靠人审查是兜不住的（同一个动作的两条分支，一条补了一条没补）。
  /// 所以在 build 顶部再补一道结构性兜底：**条数变了却没重算过，就排一次刷新**。
  /// 走 post-frame 而不是就地调用：`_refreshContextUsage()` 内部有 `setState`，
  /// 在 build 期间同步 setState 会直接抛「setState() called during build」。
  int _contextUsageMessageCount = -1;
  int _contextBudgetTokens = ContextBudgetService.defaultContextTokens;
  // build104（I13/I14）：压缩进行中标志——AppBar 菜单项禁用态 + 手动/自动压缩互斥
  bool _compressInProgress = false;
  ApiConfig? _apiConfig;
  List<ApiConfig> _apiConfigs = [];
  /// build138（G48）：模型条目所属账号，喂给 ModelSwitcher 做「同厂商多账号」小标题。
  /// 与 [_apiConfigs] 同处刷新，二者永远来自同一批读取（不会出现条目有 accountId
  /// 而账号表里查不到名字的半更新状态）。
  List<ApiAccount> _apiAccounts = [];
  ApiConfig? _currentSessionModel;
  WebSearchConfig _webSearchCfg = WebSearchConfig();

  bool _isLoading = true;
  bool _isStreaming = false;

  // ===== build113（SF-1/SF-3）：流式吸底跟随 =====
  /// true → 流式增量后自动 jumpTo 吸底；用户上滑超过阈值即让位（false），
  /// 滑回底部 / 发新消息 / 定稿 / 切会话时复位 true。
  bool _autoFollow = true;

  /// 帧级节流：一帧最多排一次吸底，防高频 chunk 堆积 jumpTo。
  bool _followScheduled = false;

  /// 离底阈值（逻辑像素）：超过即视为「用户离开底部」。
  static const double _followThreshold = 80.0;

  /// build140（反馈⑥）：输入框上方待办常驻条的展开态。
  ///
  /// **默认折叠**（常驻区不能再吃掉列表高度），且**只由用户点头部切换**——
  /// 不跟清单内容走，否则会变成"AI 一更新清单我自己就长高了"那类跳变。
  bool _todoExpanded = false;

  /// SF-1：流式内容变更后的吸底跟随（仅 _isStreaming && _autoFollow 生效；
  /// post-frame 内 jumpTo，禁 animateTo 防动画堆积抖动；一帧一次）。
  void _followBottomIfNeeded() {
    if (!_autoFollow || !_isStreaming) return;
    if (_followScheduled) return;
    _followScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _followScheduled = false;
      if (!mounted || !_autoFollow || !_isStreaming) return;
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  /// v1.3.1 build 11：🌐 按钮状态改为"常驻"
  /// - 初始化读 persistentWebSearchToggle
  /// - 用户切换后立即持久化，不再"发完就重置为 false"
  bool _searchMode = false;

  // ===== v1.7.17：🔌 插件提示三态开关（off / manual / auto）=====
  /// 状态存 SharedPreferences（避免为一个小配置动 DB schema）。
  /// 旧键迁移（plugin_hint_enabled→auto / off，plugin_hint_items→extraHints）
  /// 已在 PluginHintConfig.load 内实现。
  PluginHintConfig _pluginHintConfig = const PluginHintConfig();

  // ===== v1.3.3 build 13 新增状态 =====
  /// 思考循环期间用户中途插话的消息队列（FIFO）
  /// _runReActLoop 每轮 LLM 返回后会 drain 这个队列到 workingMessages
  final List<String> _pendingFollowupMessages = [];

  /// B-022：斜杠面板查询序列号（丢弃晚归的旧查询结果）
  int _slashSeq = 0;
  int get pendingFollowupCount => _pendingFollowupMessages.length;

  /// 是否启用"每 20 秒确认一次"防卡壳机制（用户用 ⏱️ 按钮切换）
  bool _enable20sCheck = true;

  /// 用户在 20 秒确认弹窗里点了"终止输出" → ReAct 循环检测到后立即结束
  bool _reactLoopStopRequested = false;

  /// build155（真机反馈「岛上写已完成，回去 App 写我已手动停止」）：
  /// 上面那个布尔**单独存在时说不清"是谁停的、哪一轮停的"**，于是它有三次写：
  /// 发送入口清、ReAct 循环入口清、停止入口置 —— 而前两次清之间隔着几十秒的
  /// 上下文装配（连接测试 / 知识库 / RAG / 人设），用户就在那几十秒里按的停止
  /// 被第二次清抹掉 ⇒ 循环跑完按"正常完成"收尾（岛写「· 已完成」），
  /// App 里那条却显示"已手动停止"。
  /// 解法是给停止请求记下它属于哪一轮（`_sendSeq` 的当前值），
  /// 循环入口不再无脑清，而是问"这一轮被停过吗"（判据在 `lib/utils/stop_round.dart`，纯函数可测）。
  int _reactRound = 0;
  int _reactStopRound = 0;

  /// 这一轮**用户自己**停过吗（build155 从上面那个布尔里分出来的）。
  ///
  /// 为什么要分：`_reactLoopStopRequested` 有四个写入方 —— 用户按停止、退页 `dispose`、
  /// MCP 调用数触顶（`chat_screen_react.dart` 的 maxMcpCallsPerMessage）、E5 重复调用熔断。
  /// 后三个都**不是用户的动作**，却与第一个共用同一个布尔，于是循环收尾按"用户停的"处理：
  /// 往他的回答后面追加一句 `_(用户已终止思考，输出当前进度)_` 并**落库**，
  /// 同时把岛的收尾判成 `quiet`（既不写已完成也不写失败）。
  /// 用户看到的就是"我根本没按停止，为什么说我自己停了"—— 一条写进聊天记录的假话。
  /// 现在只有 `_stopGeneration`（真按了停止）与按轮次继承会置真它；
  /// 触顶/熔断仍写"要停循环"那一半，但不再冒充用户。
  bool _reactLoopUserStopped = false;

  /// build129（#106）：长文本粘贴「转附件 or 留在输入框」追问的两个门闩。
  ///
  /// 该追问由 `onChanged`（不是粘贴事件本身）触发，**每次按键都会回调**，
  /// 因此必须有门闩：`_longTextAskShowing` 防弹层叠加，`_longTextAskSuppressed`
  /// 记住"用户已选留在输入框，本次别再问"，输入框清空时自动复位（见 _inputListener）。
  bool _longTextAskShowing = false;
  bool _longTextAskSuppressed = false;

  /// O6（build95）：ReAct 代次计数——每启动一轮 +1。
  /// 用于让后台异步尾巴（如 suggest 兜底流）识别"自己已被新一轮取代"，
  /// 配合入口 stopGeneration(scope:) 防止旧流占着生成态阻塞新消息。
  int _reactGeneration = 0;

  /// build126：发送序号——每次真正发起一轮发送 +1。
  ///
  /// 用途：`_sendMessage` 的 ReAct 分支在**异常兜底复位** _isStreaming 前，
  /// 必须先确认「没有更新的一轮接手」——因为 ReAct 收尾里的
  /// `_drainPendingFollowups()` 会立刻起新一轮（把 _isStreaming 重新置 true），
  /// 无条件复位会把这新一轮的生成态抹掉。
  int _sendSeq = 0;

  /// build161（真机反馈「那个灵动岛他不是一瞬间就出来的…它是过几秒钟之后才有的」）：
  /// 本轮发送在岛上那一行的把手，由 `_sendMessage` 在**任何 await 之前**创建并登记，
  /// 一轮一个（新一轮直接覆盖：认领与兜底撤除都按 `sessionId` 认，见 `SendIslandRow`）。
  ///
  /// 为什么放在宿主而不是 `_sendMessage` 的局部：负责收尾的是另外两个 part 文件
  /// （`chat_screen_react.dart` 的 finally、`chat_screen_orchestrator.dart` 的两个出口），
  /// 它们要在这里认领，才会同时关掉入口那层兜底。
  SendIslandRow? _sendIsland;

  /// build161 ①：一条用户消息引发的这一轮里，「掉线自动续一轮」已用掉的次数，
  /// 以及 build162 新增的"待前台续"那一笔。
  ///
  /// 为什么不写成"发送入口清 false"那种第四处复位（`_reactLoopStopRequested`
  /// 就是因为有三个写入方两个时刻不同的清理，才出了 build155 那桩"岛说已完成、
  /// App 说手动停止"的假话）：记账按 `_reactRound` 记轮号 —— 新一轮开始时轮号
  /// 一对不上，旧计数自动作废，谁都不需要"记得清零"。与 `reactStopCarried` 同配方。
  /// build162 把这两个裸 int 收进 [DropContinueScheduler]（语义一行未改），为的是
  /// "什么时候起"这台时机状态机有唯一持有者、可单测（见 drop_continue.dart 末尾）。
  final DropContinueScheduler _dropCont = DropContinueScheduler();

  /// build165 ①：**哪一轮**是被"离开 App"收起的（0 = 没有这一回事）。
  ///
  /// 记轮号而不是 bool，与 build155 的 `_reactStopRound` 同一配方：新一轮号一对不上，
  /// 旧的那一次中止自动作废，谁都不需要"记得清零"（清零那一族就是 `_reactLoopStopRequested`
  /// 三个写入方两个时刻不同 → 岛说「已完成」、App 说「已手动停止」的由来）。
  ///
  /// 它**不**与 `_reactLoopStopRequested` 共用：那个布尔在 ReAct 的 catch 里等于
  /// "用户按了停止"，蹭它就等于在用户的聊天记录里写一句他没做过的操作，
  /// 而且岛的收尾会走 quiet —— 回到 App 什么都看不见。判据是
  /// `leftAppAbortCarried`（`lib/utils/drop_continue.dart`，只住那一处）。
  int _leftAppAbortRound = 0;

  /// build165 ②：一次性交接 —— 下一次 `_sendMessage` 是"因退后台而重发"开的那一轮。
  ///
  /// 只用来把 `_dropCont` 的额度归属搬进新轮号（`adoptRound`）：整轮重发会让
  /// `_reactRound` 跟着 `_sendSeq` 走，不搬的话重发那一轮在后台又被收起时额度读回 0
  /// ⇒ 又攒一笔 ⇒ "最多一次"变成"每次进出 App 各一次"。
  /// 刻意不做成"每轮开头清 false"的第四个复位点：它是 send 入口同步读写的一次性交接，
  /// 中间没有任何 await。
  bool _bgRestartHandoff = false;

  /// suggest 类辅助流（答案兜底 / 反问快捷回复）的**专属 scope 集合**。
  ///
  /// 为什么不能复用 conversation scope：这些流的 6s 空闲超时想精确中止**它自己**。
  /// 若共用 conversation scope，一旦用户在超时窗口内发了新消息（新一轮用同一
  /// scope 起流），6s 后这次超时就会把**用户的新生成**一起杀掉（build120 的原始动机）。
  ///
  /// 反向要求：专属 scope 让「新一轮清理」不会自动覆盖它，
  /// 因此所有「本会话停止」入口都必须显式调用 [_abortSuggestStream]。
  ///
  /// 为什么是**集合**而不是单个字段（build141）：单值时两条链一旦重叠
  /// ——例如上一轮的兜底还在 6s 窗口里、这一轮的反问面板又起一条——
  /// 后发起的会把前一个 scope **覆盖掉**：停止时停的是别人的流，
  /// 自己那条继续跑到 30s 空闲超时、再以无人接收的异常冒泡到全局 zone
  /// （正是 build120 想根治的那个形态，只是换了触发条件）。
  /// 集合语义：每条链登记自己的 scope，四条出口（走完/超时/异常/早退）都摘掉，
  /// 「本会话停止」入口一次性全摘。
  final Set<String> _suggestScopes = <String>{};

  /// v1.7.17：detail 标签注入去重（key=plugin:xxx / mcp:xxx.yyy / skill:xxx）。
  /// 单次 ReAct 循环内同一详情只注入一次，防止上下文膨胀。
  final Set<String> _injectedDetails = {};

  // ===== v1.4.5：AI 回复实时写入 DB（防崩溃丢失） =====
  /// 节流：上一次 assistant 内容写入 DB 的时间戳
  int _lastAssistantDbSaveMs = 0;

  /// 节流：上一次 assistant 内容写入 DB 时的 content 长度
  int _lastAssistantDbSaveLen = 0;

  /// 流式 / ReAct 过程中实时保存 assistant 消息内容到 DB（节流）。
  ///
  /// 触发条件（任一满足）：
  ///   - [force] = true（如：answer 首次落地、用户停止、出错后）
  ///   - 距上次保存 >= [minIntervalMs]（默认 2 秒）
  ///   - content 长度较上次新增 >= [minDeltaChars]（默认 300 字）
  ///
  /// 用 StorageService.updateMessageContent（只 UPDATE content 列），
  /// 避免 updateMessageContent 每帧触发 notifyListeners + conversation 表更新。
  /// 前提：[msg] 必须已通过 saveMessage INSERT 到 DB（id 已存在）。
  Future<void> _throttledSaveAssistantContent(
    StorageService storage,
    ChatMessage msg,
    String content, {
    bool force = false,
    int minIntervalMs = 2000,
    int minDeltaChars = 300,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final len = content.length;
    final byInterval = now - _lastAssistantDbSaveMs >= minIntervalMs;
    final byLength = len - _lastAssistantDbSaveLen >= minDeltaChars;
    if (!force && !byInterval && !byLength) return;

    try {
      await storage.updateMessageContent(msg.id, content);
      _lastAssistantDbSaveMs = now;
      _lastAssistantDbSaveLen = len;
    } catch (e, st) {
      _logger.error(
        '[Chat] _throttledSaveAssistantContent failed: $e',
        error: e,
        stack: st,
        cat: LogCat.chat,
        tag: 'Chat',
      );
    }
  }

  // ===== v1.3.6：📎 附件（待发送的附件，发送后挂到 userMsg 上）=====
  final AttachmentService _attachmentService = AttachmentService();
  final List<MessageAttachment> _pendingAttachments = [];

  /// build101（F2）：会话内查找跳转后的临时高亮消息 id（1.6s 后自动清除）
  String? _highlightedMessageId;
  Timer? _highlightTimer;

  // ===== v1.3.4 build 14 新增：监听设置页配置变化 =====
  /// ChatScreen 监听 StorageService 的 notifyListeners，
  /// 设置页保存配置（总开关/档位/代理/Tavily key 等）后，
  /// ChatScreen 立即重新加载 _webSearchCfg，刷新 🌐/🧠 按钮状态。
  /// 修复 v1.3.3 的 bug：设置页关总开关后，聊天页 🌐 按钮颜色不变。
  late final StorageService _storage;
  late final VoidCallback _storageListener;
  /// build169（#102，真机遍历抓到的第一条）：`dispose()` 里要停本页那一轮的流，
  /// 但那时元素已经失效 —— 旧写法在 dispose 里现读 `context.read<ApiService>()`，
  /// Provider 内部对可空元素用 `!` ⇒ 真机每退一次对话页就抛一条
  /// `Null check operator used on a null value`，被 catch 咽成一行 debugPrint，
  /// **而 `stopGeneration` 一次都没执行到**（流继续跑、继续往已经离开的会话写）。
  /// 服务活在 app 级 Provider 里、比这一页长寿 ⇒ 照 [_storage] 的老办法在
  /// `initState` 取一次存字段，dispose 只碰字段，全程不再碰 context。
  /// 用可空而不是 `late final`：`initState` 万一在赋值前就抛，dispose 仍会跑，
  /// `late` 会在那里再抛一次 LateInitializationError，把退页路径二次堵死。
  ApiService? _api;

  Future<void> _saveSearchToggle(bool value) async {
    final storage = context.read<StorageService>();
    final newCfg = _webSearchCfg.copyWith(persistentWebSearchToggle: value);
    await storage.saveWebSearchConfig(newCfg);
    if (mounted) {
      setState(() {
        _webSearchCfg = newCfg;
        _searchMode = value;
      });
    }
  }

  /// v1.7.25：从 conversation 生成思考程度标签（用于输入框 tooltip）
  String get _conversationReactLevelLabel {
    final c = widget.conversation;
    if (c.reactAutoMode) return '自动 Auto';
    if (c.reactMaxRounds <= 0) return '关 Off';
    if (c.reactMaxRounds <= 2) return '低 Low';
    if (c.reactMaxRounds <= 5) return '中 Medium';
    return '高 High';
  }

  /// 🧠 思考强度（每对话独有）0.0=默认(自动) 0.1–1.0 连续小数
  Future<void> _saveReasoningEffort(double e) async {
    final storage = context.read<StorageService>();
    widget.conversation.reasoningEffort = e;
    await storage.saveConversation(widget.conversation);
    if (!mounted) return;
    setState(() {});
    _refreshContextUsage();
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    AppSnackBar.showSnackBar(
        context,
        SnackBar(
          content: Text(isZh
              ? (e >= 1.0
                  ? '🔬 深度研究模式已开启（最多 80 轮）'
                  : '🧠 思考强度：${reasoningEffortLabel(e, true)}')
              : (e >= 1.0
                  ? '🔬 Deep research enabled (up to 80 rounds)'
                  : '🧠 Reasoning effort: ${reasoningEffortLabel(e, false)}')),
          duration: AppDur.toast,
          behavior: SnackBarBehavior.floating,
          width: 280,
        ));
  }

  /// build103（I7）：切换模型同步落库——此前 onModelChanged 只 setState 改内存，
  /// 会话重载/重进后回退到建会话时的旧 apiConfigId（实机日志：两个同名模型
  /// 配置反复横跳）。落库后重进保持用户所选。
  Future<void> _onModelChanged(ApiConfig newCfg) async {
    if (!mounted) return;
    setState(() {
      _currentSessionModel = newCfg;
    });
    widget.conversation.apiConfigId = newCfg.id;
    try {
      await context
          .read<StorageService>()
          .saveConversation(widget.conversation);
    } catch (e) {
      // build138（扫描 P1-6）：此前这里只有一行无人认领的 debugPrint 兜底——
      // 真机上"切了模型、重进会话又变回去"就是这里落库失败，但用户零感知，
      // release 包里连日志都进不去。改为：分类日志 + 一次性 SnackBar。
      _logger.warn('[Chat] 切换模型落库失败：$e', tag: 'ModelSwitch');
      if (!mounted) return;
      final isZh =
          AppLocalizations.of(context).locale.languageCode == 'zh';
      AppSnackBar.showSnackBar(
          context,
          SnackBar(
            content: Text(isZh
                ? '本会话模型已切换，但没能保存——重进会话可能回到原模型'
                : 'Model switched for this session, but saving failed — it may revert when you reopen'),
            duration: AppDur.toast,
            behavior: SnackBarBehavior.floating,
            width: 300,
          ));
    }
    if (!mounted) return;
    _refreshContextUsage(); // 审查 B-3：换模型后预算口径随之刷新
  }

  /// v1.7.37：压缩卡片——聊天流内可见的「上下文已压缩」，点开展开完整摘要。
  /// 原始消息始终保留在 DB，卡片不进 API 消息流（segments 不在 messages 表）。
  Widget _buildCompactionCard(ContextCompactionSegment seg, bool isZh) {
    final cs = Theme.of(context).colorScheme;
    final kb = (seg.sourceTokenEstimate / 1000).toStringAsFixed(1);
    final ts = seg.createdAt.toLocal().toString().substring(0, 16);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
      elevation: 0,
      child: ExpansionTile(
        dense: true,
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        // build157（⑫）：图标位去 emoji —— `tokens.dart:6-7` 那条「去 emoji：
        // 图标一律 Material 图标 + 中性色」是本仓库自己写死的口径，压缩卡片原本
        // 用一个 emoji 文本节点当 leading，是漏网的一处。取 `Icons.compress`：与
        // AppBar 菜单里「压缩上下文 / 压缩中…」那一项同一个图标
        // （chat_screen_widgets.dart:201），同一个语义同一张图，不在两处各画一遍。
        // 尺寸 16 = 原来那枚 emoji 的字号，取色 = title 同色（onSurfaceVariant），
        // 只换 leading 内容、不改 ExpansionTile 的任何 padding ⇒ 卡片高度宽度都不变。
        leading: Icon(Icons.compress, size: 16, color: cs.onSurfaceVariant),
        title: Text(
          isZh
              ? '上下文已压缩 · 原文约 ${kb}K tokens'
              : 'Context compressed · ~${kb}K tokens',
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
        ),
        subtitle: Text(ts,
            style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant)),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(seg.summary, style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  /// v1.7.37（⑱）：上下文用量条——常驻显示「已用 x.xK / 200K（或 1M）」，
  /// 颜色随占用率变化（<60% 主色 / ≥60% 橙 / ≥85% 红，与压缩阈值一致）。
  // ================= build101（F10）日期分组头 =================

  /// 若 [list] 第 `index` 条与上一条不在同一天，返回一个居中日期分隔条；否则 null。
  /// 首条消息永远显示日期头（让用户一眼看到对话起点）。
  ///
  /// build138（甲3）：数据源从 `_messages` 改成**传入的渲染列表**——只看收藏时
  /// "上一条"是上一条**可见**消息，不是上一条存在的主表消息。否则筛后第一条
  /// 收藏消息若不跨天就没有日期头，用户看到的是一串没有时间锚点的消息。
  Widget? _buildDayHeader(List<ChatMessage> list, int index, bool isZh) {
    if (index < 0 || index >= list.length) return null;
    final cur = list[index].createdAt;
    var show = index == 0;
    if (!show) {
      final prev = list[index - 1].createdAt;
      show = cur.year != prev.year ||
          cur.month != prev.month ||
          cur.day != prev.day;
    }
    if (!show) return null;

    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Divider(
              height: 1,
              thickness: 0.5,
              color: cs.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              _fmtDayLabel(cur, isZh),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: cs.onSurfaceVariant.withValues(alpha: 0.75),
                    fontSize: 11,
                  ),
            ),
          ),
          Expanded(
            child: Divider(
              height: 1,
              thickness: 0.5,
              color: cs.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }

  /// 日期头文案：今天 / 昨天 / MM月dd日（跨年补年份）。
  static String _fmtDayLabel(DateTime dt, bool isZh) {
    final now = DateTime.now();
    final d0 = DateTime(dt.year, dt.month, dt.day);
    final n0 = DateTime(now.year, now.month, now.day);
    final diff = n0.difference(d0).inDays;
    if (diff == 0) return isZh ? '今天' : 'Today';
    if (diff == 1) return isZh ? '昨天' : 'Yesterday';
    final mm = dt.month.toString().padLeft(2, '0');
    final dd = dt.day.toString().padLeft(2, '0');
    if (dt.year != now.year) {
      return isZh ? '${dt.year}年$mm月$dd日' : '${dt.year}-$mm-$dd';
    }
    return isZh ? '$mm月$dd日' : '$mm-$dd';
  }

  /// build140（反馈⑥）：输入框上方的待办常驻条。
  ///
  /// 为什么放在这里而不是别的地方（三条都是本仓库踩过的坑）：
  /// · **不能挂 `Scaffold` 的底部槽位** —— 那个槽位不参与键盘避让（教训 #164）；
  /// · **不做成 `Stack` 浮层** —— 贴底浮层一旦写成流内节点，一出现就整列上下跳
  ///   （教训 #163 的成因）；这里就是普通流内节点，出现/展开都走 `AnimatedSize`；
  /// · **默认折叠** —— 常驻区不能反过来吃掉消息列表的高度。
  ///
  /// 清单只取**本会话最后一条带 `<todo>` 的助手消息**那份（见 `ChatTodoStrip.latestFrom`）。
  /// 勾态沿用搬走前的口径：**不落库、不回灌模型**，重进会话后由 `<todo>` 标签重解析出
  /// 清单本身，手动勾的那几笔不保留（本期明确接受，写在这里免得日后被当 bug 改）。
  Widget _buildTodoStrip(bool isZh) {
    final todos = ChatTodoStrip.latestFrom(_messages);
    // 没有清单时**整条不出现**（而不是画一个空壳占位）：多数对话压根不产 `<todo>`，
    // 常驻一个"暂无待办"比"看不见"更吵。真出现时只有这一次高度变化，
    // 且它正是"AI 开了任务清单"这个有意义的时刻，AnimatedSize 负责不硬跳。
    if (todos == null) return const SizedBox.shrink();
    return ChatTodoStrip(
      items: todos,
      zh: isZh,
      expanded: _todoExpanded,
      onToggleExpanded: () => setState(() => _todoExpanded = !_todoExpanded),
      // 直接写回那条消息的 todoItems（搬走前的气泡卡片同样是在这份数据上就地改，
      // 数据源只有一处 ⇒ 不会出现"勾一处、另一处不变"的双真源）
      onToggle: (i) => setState(() {
        final item = todos[i];
        item['done'] = !(item['done'] == true);
      }),
    );
  }

  Widget _buildContextUsageBar(bool isZh) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final budget = _contextBudgetTokens <= 0
        ? ContextBudgetService.defaultContextTokens
        : _contextBudgetTokens;
    final ratio = (_contextUsedTokens / budget).clamp(0.0, 1.0);
    // 数值格式统一走 UsageStat.fmtTokens：原先这里是本地 fmt（<1M 一律按 K 显示），
    // 于是同一条数据在用量条显示「0.9K」、在统计页显示「900」——同一件事两种写法。
    final usedText = UsageStat.fmtTokens(_contextUsedTokens);
    final budgetText = UsageStat.fmtTokens(budget);
    // 分档只留两色（正常＝主色 / 达阈值＝错误色）。第三档原先写死 Colors.orange：
    // 既不是主题色（深色或自定义主题下与周围格格不入），又把「接近上限」变成只能
    // 靠颜色区分——色觉障碍用户读不出来。第三档改由**文字**承担（下面的 hint）。
    final level = contextUsageLevel(ratio);
    final color = level == ContextUsageLevel.normal ? cs.primary : cs.error;
    final hint = switch (level) {
      ContextUsageLevel.atLimit => isZh ? '已达上限' : 'At limit',
      ContextUsageLevel.nearLimit => isZh ? '接近上限' : 'Near limit',
      ContextUsageLevel.normal => null,
    };
    // build103（I9）：整条可点 → 「上下文容量」面板（对标 Trae：总量/预算 +
    // 分类占比 + 会话缓存命中率；实现见 chat_screen_context.dart 扩展）。
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppGap.md, vertical: 2),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _showContextCapacityPanel,
        child: Tooltip(
          message: isZh ? '点击查看容量详情' : 'Tap for capacity details',
          child: Row(
            children: [
              Expanded(
                // 占用率变化时让条子「长」过去而不是瞬间跳变。时长一律走 AppMotion
                // （它是唯一读 disableAnimations 的地方；reduced 时归零 ⇒ 直接落终态）。
                child: TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: 0, end: ratio),
                  duration: AppMotion.duration(context, AppDur.base),
                  curve: AppCurve.standard,
                  builder: (ctx, v, _) => ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.inline),
                    child: LinearProgressIndicator(
                      value: v,
                      minHeight: 4,
                      backgroundColor: cs.surfaceContainerHighest,
                      valueColor: AlwaysStoppedAnimation<Color>(color),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: AppGap.sm),
              if (hint != null) ...[
                Text(
                  hint,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: AppGap.xs),
              ],
              Text(
                '${isZh ? '上下文' : 'Context'} $usedText / $budgetText',
                style:
                    theme.textTheme.labelSmall?.copyWith(color: cs.appTextSub),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// v1.7.37：更大上下文 Max（🧠 弹层开关）——200K ↔ 1M，即时存库
  Future<void> _saveLargeContextMax(bool v) async {
    final storage = context.read<StorageService>();
    widget.conversation.largeContextMax = v;
    await storage.saveConversation(widget.conversation);
    if (!mounted) return;
    setState(() {});
    _refreshContextUsage();
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    AppSnackBar.showSnackBar(
        context,
        SnackBar(
          content: Text(v
              ? (isZh
                  ? '📏 上下文已提升到 1M，自动压缩已禁用'
                  : '📏 Context raised to 1M; auto-compress disabled')
              : (isZh ? '📏 上下文已恢复 200K' : '📏 Context restored to 200K')),
          duration: AppDur.toast,
          behavior: SnackBarBehavior.floating,
          width: 280,
        ));
  }

  @override
  void initState() {
    super.initState();
    // v1.3.4：缓存 storage 引用 + 注册 listener，设置页改配置后能实时刷新
    _storage = context.read<StorageService>();
    // build169（#102）：ApiService 同样在这里缓存 —— 见 [_api] 的注释，
    // 退页时 dispose 已经拿不到 context，只能现在取。
    _api = context.read<ApiService>();
    _storageListener = _onStorageChanged;
    _storage.addListener(_storageListener);
    _inputListener = () {
      _saveDraft();
      _refreshSlashPanel();
      // build129（#106）：输入框清空 → 解除"本次不要再追问粘贴处理方式"的抑制。
      // 不解除的话，用户一旦选过「留在输入框」，之后每次粘贴长文都不会再问。
      if (_inputController.text.isEmpty) _longTextAskSuppressed = false;
    };
    _inputController.addListener(_inputListener);
    // build123：注册「暖启动分享投递口」——该会话正开着时，新到的分享直接
    // 落进本页输入框，而不是再压一层重复的 ChatScreen（栈里两个同一会话
    // 会导致「发完一条，上一层的列表不刷新」这类错位）。
    ShareIntentService.instance
        .registerInserter(widget.conversation.id, _applyShare);
    // build162：掉线续写的起飞时刻挂到"回到前台"这一下（通知点唯一，见
    // `AppResumeSignal`）。注册键与上面那条同用 conversationId：同一会话同时
    // 只会有一页开着（build123 就是为这个立的规矩），dispose 里成对注销。
    AppResumeSignal.instance
        .register(widget.conversation.id, _onAppResumedForDropContinue);
    // build165 ①：对称的那半条腿 —— 出去那一下把这条流收起来（判据/文案在
    // `lib/utils/drop_continue.dart`，通知点与上面同在这一处，页面不自己 addObserver）。
    AppResumeSignal.instance
        .registerLeavingApp(widget.conversation.id, _onAppLeftForeground);
    _loadData();
    final share = widget.initialShare;
    if (share != null) {
      // 首帧后再插：SnackBar 需要已挂载的 context；也确保 _loadData 的
      // 草稿恢复先跑（草稿恢复只在输入框为空时生效，不会被分享内容顶掉）
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _applyShare(share);
      });
    }
  }

  /// build123：把「分享到 Nexus」的载荷落进输入区。
  ///
  /// 设计取舍（为什么是这样而不是别的）：
  /// - **文本/网址只粘贴、不自动发送**：分享常常只是「先存一下」，自动发送
  ///   会立刻烧一次 API 且用户没机会补话；网址也原样粘，不做任何包装改写。
  /// - **文件走既有待发附件通道**：输入框上方的附件预览条自带 × 取消，
  ///   「预览 + 插入输入框 + 可取消」三件事一次满足，不新造一套 UI。
  /// - 解析失败**必须出声**：静默失败会让用户以为「分享了但没反应」，
  ///   这正是本项目历史上反复出现的「假完成」形态。
  Future<void> _applyShare(SharedPayload payload) async {
    if (!mounted) return;
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    if (payload.isText) {
      final text = payload.text!;
      // build129（#106）：分享进来的长文本也走「先问一句」——与粘贴同一个阈值、
      // 同一个弹层（[_askLongTextHandling]）。不这么做的话，用户分享一段长文
      // 当时什么都没发生，等下一次敲键盘才突然弹出「怎么处理」，等于把一次
      // 静默转换推后成一次莫名其妙的追问。设置关着时照旧直接插入输入框（不设硬上限）。
      final skin = context.read<ChatSkinProvider>();
      if (skin.pasteAsFile &&
          text.length >= ChatInputConfig.defaultPasteLongAsFileThreshold) {
        final toAttachment = await _askLongTextHandling(text);
        if (!mounted) return;
        if (toAttachment == true) {
          _attachPastedText(text, isZh);
          _logger.info('[Share] 长文本已按用户选择转附件（${text.length} 字符）',
              cat: LogCat.chat, tag: 'Share');
          return;
        }
        if (toAttachment == null) {
          _logger.info('[Share] 用户关闭长文本处理弹层，未插入', cat: LogCat.chat, tag: 'Share');
          return;
        }
        // false = 留在输入框 → 落到下面的插入路径
      }
      final existing = _inputController.text;
      final merged = existing.trim().isEmpty ? text : '$existing\n$text';
      _inputController.value = TextEditingValue(
        text: merged,
        selection: TextSelection.collapsed(offset: merged.length),
      );
      _logger.info('[Share] 文本已插入输入框（${text.length} 字符）',
          cat: LogCat.chat, tag: 'Share');
      AppSnackBar.showSnackBar(
          context,
          SnackBar(
            content: Text(isZh
                ? '已粘贴分享内容，编辑后发送'
                : 'Shared content pasted — edit, then send'),
            duration: const Duration(seconds: 3),
          ));
      return;
    }
    if (payload.hasError || payload.filePath == null) {
      // 原生侧复制失败（无权限 / IO 错误）——必须出声，不能装作没事
      _logger.warn('[Share] 文件分享失败：${payload.describe()}',
          cat: LogCat.chat, tag: 'Share');
      AppSnackBar.showSnackBar(
          context,
          SnackBar(
            content: Text(isZh
                ? '读取这个文件失败，请换一个文件或先保存到本机再分享'
                : 'Could not read the shared file — try saving it locally first'),
            duration: const Duration(seconds: 4),
          ));
      return;
    }
    // build129（#106）：体积过大不再硬拒绝——先量体积，过大问一次，确认后照办。
    // 旧行为：超 50MB 直接给一条「附件超过 50 MB 限制」的错误附件，用户没法坚持
    //（用户口径：插入文件不受限，过大也要问，但不设硬上限）。
    var allowOversize = false;
    final size = await _attachmentService.sizeOfFile(payload.filePath!);
    if (size != null && size > AttachmentService.maxRawFileBytes) {
      final mb = (size / (1024 * 1024)).toStringAsFixed(1);
      const limitMb = AttachmentService.maxRawFileBytes ~/ (1024 * 1024);
      if (!mounted) return;
      final go = await showAppSheet<bool>(
        context: context,
        scrollable: true,
        builder: (bctx) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppSheetHeader(title: isZh ? '文件有点大' : 'Large file'),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                isZh
                    ? '这个文件 $mb MB，超过默认的 $limitMb MB 上限。仍然可以插入，但解析会更耗时、也可能失败。'
                    : 'This file is $mb MB, over the default $limitMb MB limit. You can still attach it, but parsing takes longer and may fail.',
                style: Theme.of(bctx).textTheme.bodySmall,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.download_done),
              title: Text(isZh ? '仍然插入' : 'Attach anyway'),
              onTap: () => Navigator.pop(bctx, true),
            ),
            ListTile(
              leading: const Icon(Icons.close),
              title: Text(isZh ? '取消' : 'Cancel'),
              onTap: () => Navigator.pop(bctx, false),
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
      if (!mounted) return;
      if (go != true) {
        _logger.info('[Share] 大文件插入被用户取消：$mb MB',
            cat: LogCat.chat, tag: 'Share');
        return;
      }
      allowOversize = true;
    }
    final att = await _attachmentService.attachSharedFile(
      payload.filePath!,
      displayName: payload.fileName,
      mimeType: payload.mimeType,
      allowOversize: allowOversize,
    );
    if (!mounted) return;
    if (att == null) {
      _logger.warn('[Share] 文件无法作为附件：${payload.describe()}',
          cat: LogCat.chat, tag: 'Share');
      AppSnackBar.showSnackBar(
          context,
          SnackBar(
            content: Text(isZh
                ? '这个文件暂时用不了（格式不支持或体积过大）'
                : 'This file cannot be attached (unsupported type or too large)'),
            duration: const Duration(seconds: 4),
          ));
      return;
    }
    setState(() => _pendingAttachments.add(att));
    _logger.info('[Share] 文件已插入待发附件：${att.fileName}',
        cat: LogCat.chat, tag: 'Share');
    AppSnackBar.showSnackBar(
        context,
        SnackBar(
          content: Text(isZh
              ? (payload.extraCount != null && payload.extraCount! > 1
                  ? '已插入附件（多选只取第一个），点 × 可取消'
                  : '已插入附件，点 × 可取消')
              : (payload.extraCount != null && payload.extraCount! > 1
                  ? 'Attachment added (only the first of several), tap × to remove'
                  : 'Attachment added, tap × to remove')),
          duration: const Duration(seconds: 3),
        ));
  }

  /// v1.3.4：StorageService.notifyListeners 触发 → 重新读 webSearchConfig 刷新 UI
  /// 修复 v1.3.3 bug：设置页关总开关后聊天页 🌐 按钮颜色不变
  /// v1.6.0：同时刷新 _apiConfigs / _apiConfig / _currentSessionModel
  void _onStorageChanged() {
    if (!mounted) return;
    // 用 postFrame 避免在 build 期间 setState
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final webCfg = await _storage.getWebSearchConfig();
      final allConfigs = await _storage.getApiConfigs();
      final allAccounts = await _storage.getApiAccounts();
      final config =
          await _storage.getApiConfig(widget.conversation.apiConfigId);
      if (!mounted) return;
      setState(() {
        _webSearchCfg = webCfg;
        _apiConfigs = allConfigs;
        _apiAccounts = allAccounts;
        _apiConfig = config;
        // _currentSessionModel 如果已经在 allConfigs 中就保留，否则重置
        if (_currentSessionModel != null &&
            !allConfigs.any((c) => c.id == _currentSessionModel!.id)) {
          _currentSessionModel =
              _apiConfig ?? (allConfigs.isNotEmpty ? allConfigs.first : null);
        }
        // _searchMode 保留用户当前选择；总开关关了 → active 自动算 false
      });
      // v1.3.4：同步详细日志模式到 LoggerService 单例
      if (LoggerService.instance.verboseEnabled != webCfg.verboseLogging) {
        LoggerService.instance.verboseEnabled = webCfg.verboseLogging;
      }
    });
  }

  void _saveDraft() {
    final text = _inputController.text;
    // 全量缺陷扫描 §2（低危）：草稿保存此前**无任何错误接管** ——
    // `getInstance()` 或后续写入失败（磁盘满、平台通道异常）会让异常以
    // 「未捕获的 Future 错误」冒到 FlutterError.onError，真机表现为日志刷红；
    // 而草稿丢失对用户又是完全静默的，出了问题无从查起。
    // 这里补 catchError：失败只记一条日志，不干扰输入 —— 草稿本就尽力而为。
    // 注：写入**仍然不 await**（保留原设计）——SharedPreferences 的内存缓存是
    // 同步更新的，所以不存在「后写被先写覆盖」的乱序风险，await 只会给
    // 每次按键都加一次微任务开销。两个分支统一返回 Future<bool> 以便接管。
    SharedPreferences.getInstance().then((prefs) {
      if (text.isEmpty) {
        return prefs.remove(_draftPrefsKey);
      }
      return prefs.setString(_draftPrefsKey, text);
    }).catchError((Object e) {
      _logger.warn('[Chat] 草稿保存失败（不影响输入）：$e',
          cat: LogCat.chat, tag: 'DRAFT');
      return false; // catchError 需返回 Future 的元素类型
    });
  }

  // ==========================================================================
  // build90 ⑨：斜杠命令面板——输入行首 `/` 唤起，项目命令优先于全局同名
  // ==========================================================================
  Future<void> _refreshSlashPanel() async {
    final text = _inputController.text;
    if (!text.startsWith('/')) {
      if (_slashMatches.isNotEmpty) {
        setState(() => _slashMatches = const []);
      }
      return;
    }
    // 已含空格 = 已选命令在补参数，收起面板
    if (text.contains(' ')) {
      if (_slashMatches.isNotEmpty) {
        setState(() => _slashMatches = const []);
      }
      return;
    }
    final pid = widget.conversation.projectId;
    // B-022：加查询序列号——两次按键并发在途时，较早的 /a 查询可能晚于 /ab 完成，
    // 并用固化的旧 prefix 过滤后 setState 覆盖面板（列表与输入框不符）。
    final seq = ++_slashSeq;
    final globals = await _storage.loadSlashCommands(scope: 'global');
    final projectCmds = pid.isEmpty
        ? const <SlashCommand>[]
        : await _storage.loadSlashCommands(scope: 'project:$pid');
    if (!mounted || seq != _slashSeq) return;
    // 用 await 之后**当前**的输入重新算前缀与收起条件，而不是闭包里的旧值
    final cur = _inputController.text;
    if (!cur.startsWith('/') || cur.contains(' ')) return;
    final prefix = cur.substring(1).toLowerCase();
    // 项目命令优先展示；过滤同前缀
    final all = [...projectCmds, ...globals];
    final matches =
        all.where((c) => c.name.toLowerCase().startsWith(prefix)).toList();
    if (!mounted) return;
    setState(() => _slashMatches = matches);
  }

  /// B-028：消费「流式中插话」队列——直聊流结束 / ReAct 定稿后统一调用。
  ///
  /// 旧实现只有 ReAct 每轮轮首会 drain，直聊路径「只入不出」：用户收到
  /// 「已加入思考队列，AI 下一轮会处理」的明确承诺，但这句话永远不会发出、
  /// 输入栏角标永久残留；关 ReAct（或关自检插件）的用户则彻底卡死。
  void _drainPendingFollowups() {
    if (!mounted || _isStreaming) return;
    if (_pendingFollowupMessages.isEmpty) return;
    final next = _pendingFollowupMessages.removeAt(0);
    // build152（状态扫描 S6）：**输入框里有字就不许接管它**。
    // 原实现直接 `_inputController.text = next` 再 `_saveDraft()` ——
    // 用户上一轮流式期间发了「A」（入队），随后开始打「B」，本轮结束 drain 时
    // 「B」被原地替换成「A」并连带写进草稿键 ⇒ **内存与 prefs 两份都没了**，
    // 这是本路唯一真正丢用户数据的一条。改成"框非空就把 A 插回队头、这轮不接管"，
    // 下一次 drain（或用户自己点发送后）再消费，A 不会丢、B 也不会被吞。
    if (_inputController.text.trim().isNotEmpty) {
      _pendingFollowupMessages.insert(0, next);
      if (mounted) setState(() {});
      _logger.info(
          '[Chat] 插话队列延后消费：输入框非空（${_inputController.text.trim().length} 字草稿）'
          '，保留队首 ${next.length} 字待下一次 drain',
          cat: LogCat.chat,
          tag: 'Chat');
      return;
    }
    setState(() {});
    _inputController.text = next;
    _saveDraft();
    // 续发：复用发送链路（unawaited，避免阻塞调用方的 finally）
    unawaited(_sendMessage());
  }

  /// B-032：消息是否仍存活于当前会话（异步尾巴落库前校验）。
  ///
  /// 删除/撤回不递增 _reactGeneration，N14 兜底推荐等 unawaited 后台流
  /// 完成后会按 id replace 把已删除的行重新插回 DB（重进会话「复活」）。
  bool _isMessageAlive(String id) => _messages.any((m) => m.id == id);

  /// 点选命令：模板填入输入框；含 {{input}} 时移除占位符并光标定位到原位置
  void _applySlashCommand(SlashCommand cmd) {
    final template = cmd.promptTemplate;
    if (cmd.hasInputPlaceholder) {
      final idx = template.indexOf('{{input}}');
      _inputController.text = template.replaceAll('{{input}}', '');
      _inputController.selection = TextSelection.collapsed(offset: idx);
    } else {
      _inputController.text = template;
      _inputController.selection =
          TextSelection.collapsed(offset: template.length);
    }
    _inputFocus.requestFocus();
  }

  /// 消息长按 → 保存到记忆（全局 / 当前对话所属项目）
  Future<void> _saveMessageToMemory(String content) async {
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    final pid = widget.conversation.projectId;
    final projects = pid.isEmpty
        ? const <Project>[]
        : (await _storage.loadProjects()).where((p) => p.id == pid).toList();
    if (!mounted) return;
    final projectName = projects.isNotEmpty ? projects.first.name : null;
    // build126 (B2)：SimpleDialog → 底部弹层。纯「选一项」的操作，
    // 从底部弹出比居中弹窗更贴拇指，也不再和 AlertDialog 各长一个样。
    // 顺带把 🌐/📁 emoji 换成图标（emoji 跨平台渲染不一致，也不跟随主题色）。
    final choice = await showAppSheet<String>(
      context: context,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppSheetHeader(title: isZh ? '保存到记忆' : 'Save to memory'),
          ListTile(
            leading: const Icon(Icons.public),
            title: Text(isZh ? '全局记忆（所有对话生效）' : 'Global memory'),
            onTap: () => Navigator.pop(ctx, 'global'),
          ),
          if (projectName != null)
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: Text(isZh
                  ? '项目「$projectName」记忆'
                  : 'Project "$projectName" memory'),
              onTap: () => Navigator.pop(ctx, 'project'),
            ),
          const SizedBox(height: AppGap.sm),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    final excerpt = content.trim();
    if (excerpt.isEmpty) return;
    final id = const Uuid().v4();
    final src = 'conversation:${widget.conversation.id}';
    if (choice == 'global') {
      await _storage.saveGlobalMemory(
          GlobalMemory(id: id, content: excerpt, source: src));
    } else {
      await _storage.saveProjectMemory(
          ProjectMemory(id: id, projectId: pid, content: excerpt, source: src));
    }
    if (!mounted) return;
    AppSnackBar.showSnackBar(
        context,
        SnackBar(
          content: Text(isZh ? '✅ 已存入记忆' : '✅ Saved to memory'),
          duration: AppDur.toast,
          behavior: SnackBarBehavior.floating,
          width: 220,
        ));
  }

  Future<void> _loadData() async {
    final messages = await _storage.getMessages(widget.conversation.id);
    final config = await _storage.getApiConfig(widget.conversation.apiConfigId);
    final allConfigs = await _storage.getApiConfigs();
    // build138（G48）：账号表与会话数据同批读，避免进会话时切换器先只按 host
    // 分组、下一次刷新才冒出账号名（同一份数据两种形状）。
    final allAccounts = await _storage.getApiAccounts();
    final webCfg = await _storage.getWebSearchConfig();
    // v1.7.37：加载压缩段（聊天流内渲染可见卡片）
    final segments =
        await _storage.getContextCompactionSegments(widget.conversation.id);
    // v1.7.17：读 🔌 插件提示三态配置（旧键迁移已在 load 内实现）
    final hintConfig = await PluginHintConfig.load();
    final prefs = await SharedPreferences.getInstance();
    final draft = prefs.getString(_draftPrefsKey) ?? '';
    // v1.7.26 (E3)：恢复持久化的重试版本快照（此前仅内存，重启后版本切换丢失）
    final versionMap = await _storage.loadMessageVersions();
    if (mounted) {
      setState(() {
        _pluginHintConfig = hintConfig;
        _messages = messages;
        // build101（B4）：引用（星标）集合随会话加载
        _starredIds = widget.conversation.starredIds;
        _compactionSegments = segments;
        _apiConfig = config;
        _apiConfigs = allConfigs;
        _apiAccounts = allAccounts;
        _currentSessionModel =
            _apiConfig ?? (allConfigs.isNotEmpty ? allConfigs.first : null);
        _webSearchCfg = webCfg;
        _enable20sCheck = widget.conversation.enable20sCheck;
        _searchMode = webCfg.persistentWebSearchToggle;
        _retryVersionStore
          ..clear()
          ..addAll(versionMap);
        if (draft.isNotEmpty && _inputController.text.isEmpty) {
          _inputController.value = TextEditingValue(
            text: draft,
            selection: TextSelection.collapsed(offset: draft.length),
          );
        }
        for (final e in _retryVersionStore.entries) {
          _activeRetryVersionIndex[e.key] = e.value.length;
        }
        _isLoading = false;
      });
      // v1.3.4：启动时同步详细日志模式
      LoggerService.instance.verboseEnabled = webCfg.verboseLogging;
      _refreshContextUsage();
      _scrollToBottom();
    }
  }

  /// v1.7.17：非 ReAct 普通聊天路径的 🔌 提示文本。
  /// - off：空串（不注入）
  /// - manual/auto：注入 extraHints
  /// - auto：额外注入 enabled MCP/Skill 的小目录摘要（一行一个，不引入 detail 协议）
  String _buildNormalChatPluginHint(PluginRegistry registry) {
    final cfg = _pluginHintConfig;
    if (cfg.mode == PluginHintMode.off) return '';
    final parts = <String>[];
    if (cfg.extraHints.isNotEmpty) parts.add(cfg.extraHints.join('\n'));
    if (cfg.mode == PluginHintMode.auto) {
      final entries = <String>[];
      for (final p in registry.plugins) {
        if (!registry.isEnabled(p.metadata.id)) continue;
        final m = p.metadata;
        if (m.kind == PluginKind.mcpRemote) {
          entries.add('- MCP ${m.name} (${m.id})');
        } else if (m.kind == PluginKind.declarative &&
            p.source != PluginSource.system) {
          entries.add('- Skill ${m.name} (${m.id})');
        }
      }
      if (entries.isNotEmpty) {
        parts.add('已启用插件目录：\n${entries.join('\n')}');
      }
    }
    return parts.join('\n\n');
  }

  /// v1.7.17：手动模式下实际生效的勾选数（selectedIds ∩ 已启用插件 id）。
  int _effectiveManualSelectedCount(PluginRegistry registry) {
    if (_pluginHintConfig.mode != PluginHintMode.manual) return 0;
    final enabledIds = registry.plugins
        .where((p) => registry.isEnabled(p.metadata.id))
        .map((p) => p.metadata.id)
        .toSet();
    return _pluginHintConfig.selectedIds.where(enabledIds.contains).length;
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: AppDur.slow,
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ===== v1.3.6：📎 附件选择 / 删除 =====
  /// 点 📎 按钮：弹出底部选择条（相册 / 拍照 / 文档）
  Future<void> _pickAttachment() async {
    if (_isStreaming) return;
    final cs = Theme.of(context).colorScheme;
    final l = AppLocalizations.of(context);
    final isZh = l.locale.languageCode == 'zh';
    // build126 (B2)：裸 showModalBottomSheet → 统一入口 showAppSheet，
    // 并补上 AppSheetHeader —— 原先是唯一没有标题的弹层，和其它弹层并列会
    // 显得少了一行；补标题后每个弹层都有统一的一级标题。
    await showAppSheet<void>(
      context: context,
      scrollable: true,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppSheetHeader(title: isZh ? '添加附件' : 'Add attachment'),
          // showAppSheet 自身不带滚动，用 Flexible 兜住：条目再多也不会溢出
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: Icon(Icons.photo_outlined, color: cs.primary),
                    title: Text(isZh ? '相册选照片' : 'Choose from gallery'),
                    onTap: () async {
                      Navigator.pop(ctx);
                      final att =
                          await _attachmentService.pickImageFromGallery();
                      if (att != null && mounted) {
                        setState(() => _pendingAttachments.add(att));
                      }
                    },
                  ),
                  ListTile(
                    leading: Icon(Icons.camera_alt_outlined, color: cs.primary),
                    title: Text(isZh ? '拍照' : 'Take photo'),
                    onTap: () async {
                      Navigator.pop(ctx);
                      final att =
                          await _attachmentService.pickImageFromCamera();
                      if (att != null && mounted) {
                        setState(() => _pendingAttachments.add(att));
                      }
                    },
                  ),
                  ListTile(
                    leading:
                        Icon(Icons.description_outlined, color: cs.primary),
                    title: Text(isZh
                        ? '选文档（txt/md/pdf/docx）'
                        : 'Pick document (txt/md/pdf/docx)'),
                    onTap: () async {
                      Navigator.pop(ctx);
                      final att = await _attachmentService.pickDocument();
                      if (att != null && mounted) {
                        setState(() => _pendingAttachments.add(att));
                      }
                    },
                  ),
                  ListTile(
                    leading: Icon(Icons.close, color: cs.onSurfaceVariant),
                    title: Text(l.tr('cancel')),
                    onTap: () => Navigator.pop(ctx),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _removeAttachment(MessageAttachment att) {
    setState(() => _pendingAttachments.remove(att));
  }

  // ================= build101（F1/F2）会话内查找与跳转 =================

  /// 打开会话内查找页；用户点某条命中时回传消息下标，这里负责滚动定位。
  Future<void> _openChatSearch() async {
    final idx = await Navigator.push<int>(
      context,
      MaterialPageRoute(
        builder: (_) => ChatSearchScreen(
          conversationId: widget.conversation.id,
          conversationTitle: widget.conversation.title,
        ),
      ),
    );
    if (!mounted || idx == null) return;
    await _jumpToMessage(idx);
  }

  /// build101（F2）：滚动定位到第 [index] 条消息并短暂高亮提示。
  ///
  /// 实现说明：消息列表用的是普通 `ListView.builder` + 变高 item，
  /// 无法直接算出精确偏移。这里按「平均高度估算 + 底部吸附兜底」处理：
  /// 用 `maxScrollExtent / 消息数` 估平均高度算目标偏移；若目标靠近底部
  /// 则直接吸底。对变高气泡足够稳，且不引入 scrollable_positioned_list
  /// 依赖（避免大改现有列表结构）。
  ///
  /// [index] 是 **`_messages` 主表下标**（会话内查找页按全量消息回传）。
  /// build138（甲3）：开着只看收藏时，命中的那条可能被筛掉了——
  /// "点了搜索结果却没有任何反应"是这里最糟的结果，故先自动退出筛选再定位。
  /// 反查成**可见列表下标**是必须的：偏移量按可见条数估，直接用主表下标
  /// 会在筛后的短列表上把落点算飞（越界还会被 clamp 到底部、看起来像 bug）。
  Future<void> _jumpToMessage(int index) async {
    if (index < 0 || index >= _messages.length) return;
    final id = _messages[index].id;
    if (_starredOnly && !_starredIds.contains(id)) {
      setState(() => _starredOnly = false);
      // 等一帧：此刻 maxScrollExtent 还是"筛后短列表"的高度，
      // 按它估平均高度会把落点算偏（列表重建要在下一帧才完成）。
      await WidgetsBinding.instance.endOfFrame;
    }
    if (!mounted || !_scrollController.hasClients) return;
    final visible = _visibleMessages;
    final target = visible.indexWhere((m) => m.id == id);
    if (target < 0) return;
    final pos = _scrollController.position;
    final count = visible.length;
    final avg = pos.maxScrollExtent / (count <= 1 ? 1 : count);
    final offset = (avg * target - 80).clamp(0.0, pos.maxScrollExtent);
    await _scrollController.animateTo(
      offset,
      duration: AppDur.slow,
      curve: Curves.easeOutCubic,
    );
    if (!mounted) return;
    setState(() => _highlightedMessageId = id);
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _highlightedMessageId = null);
    });
    if (mounted && _scrollController.hasClients) {
      final after = _scrollController.position;
      if (after.pixels >= after.maxScrollExtent - 120) {
        _scrollToBottom();
      }
    }
  }

  /// build138（甲3）：切换「只看收藏」。
  ///
  /// 打开时给一条**可撤销**的浮层（N = 被藏起来的条数）：筛选是隐藏内容，
  /// 没有反馈的隐藏会被当成"消息丢了"（真机上用户第一反应就是去找那几条）。
  /// 撤销就一个动作：把开关关回去。N 为 0 时不弹——列表本来就一条没少，
  /// 弹「已筛掉 0 条」只会让人觉得系统在凑话。
  ///
  /// 同时复位 [_autoFollow]：列表长度骤变后"离底多远"已失去参照，
  /// 胶囊（回到底部）留在屏上是上一屏的结论。
  void _toggleStarredFilter() {
    final isZh =
        AppLocalizations.of(context).locale.languageCode == 'zh';
    final next = !_starredOnly;
    final hidden = next ? starredHiddenCount(_messages, _starredIds) : 0;
    setState(() {
      _starredOnly = next;
      _autoFollow = true;
    });
    if (!next) return;
    if (hidden > 0) {
      AppSnackBar.showSnackBar(
        context,
        SnackBar(
          content: Text(
              isZh ? '已筛掉 $hidden 条' : '$hidden messages hidden'),
          duration: const Duration(seconds: 4),
          action: SnackBarAction(
            label: isZh ? '撤销' : 'Undo',
            onPressed: () {
              if (mounted) setState(() => _starredOnly = false);
            },
          ),
        ),
      );
    }
    // 筛完停在**最新一条收藏**上（列表变短，原来的偏移可能已越过末尾）
    _scrollToBottom();
  }

  /// build101（F5）：长文本粘贴自动转附件。
  ///
  /// 输入框内容长度超阈值时由 ChatInput 回调上来。此处生成一个 text 类型
  /// 附件挂到待发列表并清空输入框——长内容不挤占输入区，同时完整保留原文，
  /// 发送时与文档附件同路径（attachment.extractedText 注入 prompt）。
  ///
  /// build129（#106）：不再**静默**照办——先问一句"转附件 / 留在输入框"。
  /// 旧实现只要输入框里出现超阈值文本就立刻转附件并清空输入框，用户看不到
  /// 自己的字被搬走、也无法拒绝（想直接在框里改这段长文只能放弃）。
  /// 注：追问只在设置项「长文本自动转文件」开启时触发（ChatInput 侧门禁）。
  Future<void> _onLongTextPasted(String text) async {
    if (text.trim().isEmpty) return;
    // 门闩：弹层已开（onChanged 会连发）/ 用户本次已表态 → 不再追问
    if (_longTextAskShowing || _longTextAskSuppressed) return;
    _longTextAskShowing = true;
    bool? toAttachment;
    try {
      toAttachment = await _askLongTextHandling(text);
    } finally {
      _longTextAskShowing = false;
    }
    if (!mounted) return;
    if (toAttachment != true) {
      // 用户选择留在输入框：本次不再追问（输入框清空后自动复位）
      _longTextAskSuppressed = true;
      return;
    }
    _attachPastedText(text, AppLocalizations.of(context).locale.languageCode == 'zh');
  }

  /// 弹一次「这段内容怎么处理？」：true=转附件 / false=留在输入框 / null=关掉弹层。
  ///
  /// build129（#106）：把问法抽出来给**两条**入口共用——① 粘贴超阈值触发
  /// （[_onLongTextPasted]）；② 外部 App 分享进来的长文本（[_applyShare]）。
  /// 用户口径是「插入过大也要问，不设硬上限，确认后照办」，
  /// 同一件事两条入口若有两种脾气（一个问、一个静默照办）就不算修好。
  Future<bool?> _askLongTextHandling(String text) async {
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    return showAppSheet<bool>(
      context: context,
      scrollable: true,
      builder: (bctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppSheetHeader(title: isZh ? '这段内容怎么处理？' : 'What to do with it?'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              isZh
                  ? '这段内容有 ${text.length} 字。可以转成附件（不挤占输入区，原文完整保留），也可以留在输入框里继续改。'
                  : 'This content is ${text.length} chars. Convert it into an attachment, or keep editing it in the input box.',
              style: Theme.of(bctx).textTheme.bodySmall,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.attach_file),
            title: Text(isZh ? '转为附件' : 'Convert to attachment'),
            onTap: () => Navigator.pop(bctx, true),
          ),
          ListTile(
            leading: const Icon(Icons.edit_note),
            title: Text(isZh ? '留在输入框' : 'Keep in the input box'),
            onTap: () => Navigator.pop(bctx, false),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  /// 把粘贴的长文本转成 text 类型附件并清空输入框（原 build101 F5 行为）。
  void _attachPastedText(String text, bool isZh) {
    final att = MessageAttachment(
      id: 'paste_${DateTime.now().microsecondsSinceEpoch}',
      type: AttachmentType.text,
      fileName: isZh
          ? '粘贴文本-${text.length}字.txt'
          : 'pasted-text-${text.length}chars.txt',
      extractedText: text,
      mimeType: 'text/plain',
      sizeBytes: text.length,
    );
    setState(() {
      _pendingAttachments.add(att);
      // 清空输入框（同时清掉已经存下的草稿，避免下次进会话被还原）
      _inputController.clear();
    });
    _saveDraft();
    if (mounted) {
      AppSnackBar.showSnackBar(
        context,
        SnackBar(
          content: Text(isZh
              ? '长文本已转为附件（${text.length} 字）'
              : 'Long text converted to attachment (${text.length} chars)'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  // ================= build101（F6）外接键盘快捷键 =================

  /// 包一层 Shortcuts + Actions + Focus，让外接键盘也能高效操作。
  ///
  /// 支持的按键：
  /// - Ctrl/Cmd + Enter：发送（或流式中把内容加入队列）
  /// - Esc：停止生成
  /// - Ctrl/Cmd + F：在对话中查找
  /// - Alt + ↑ / Alt + ↓：跳到对话顶部 / 底部
  /// - Ctrl/Cmd + Shift + C：复制最后一条助手消息
  ///
  /// 注意：Enter 单独按下**不发送**（保持换行，移动端习惯），
  /// 必须配合 Ctrl/Cmd 才发送 —— 避免外接键盘误触。
  Widget _withShortcuts({required Widget child}) {
    final isMac = Theme.of(context).platform == TargetPlatform.macOS ||
        Theme.of(context).platform == TargetPlatform.iOS;
    final single = isMac
        ? const SingleActivator(LogicalKeyboardKey.enter, meta: true)
        : const SingleActivator(LogicalKeyboardKey.enter, control: true);
    final find = isMac
        ? const SingleActivator(LogicalKeyboardKey.keyF, meta: true)
        : const SingleActivator(LogicalKeyboardKey.keyF, control: true);
    final copyLast = isMac
        ? const SingleActivator(LogicalKeyboardKey.keyC,
            meta: true, shift: true)
        : const SingleActivator(LogicalKeyboardKey.keyC,
            control: true, shift: true);

    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        single: const _SendIntent(),
        const SingleActivator(LogicalKeyboardKey.escape): const _StopIntent(),
        find: const _FindInChatIntent(),
        const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true):
            const _ScrollTopIntent(),
        const SingleActivator(LogicalKeyboardKey.arrowDown, alt: true):
            const _ScrollBottomIntent(),
        copyLast: const _CopyLastIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _SendIntent: CallbackAction<_SendIntent>(
            onInvoke: (_) {
              if (_isLoading || _apiConfig == null) return null;
              _sendMessage();
              return null;
            },
          ),
          _StopIntent: CallbackAction<_StopIntent>(
            onInvoke: (_) {
              if (_isStreaming) _stopGeneration();
              return null;
            },
          ),
          _FindInChatIntent: CallbackAction<_FindInChatIntent>(
            onInvoke: (_) {
              if (!_isLoading) _openChatSearch();
              return null;
            },
          ),
          _ScrollTopIntent: CallbackAction<_ScrollTopIntent>(
            onInvoke: (_) {
              _scrollToTop();
              return null;
            },
          ),
          _ScrollBottomIntent: CallbackAction<_ScrollBottomIntent>(
            onInvoke: (_) {
              _scrollToBottom();
              return null;
            },
          ),
          _CopyLastIntent: CallbackAction<_CopyLastIntent>(
            onInvoke: (_) {
              _copyLastAssistantMessage();
              return null;
            },
          ),
        },
        child: Focus(autofocus: false, child: child),
      ),
    );
  }

  /// build101（F6）：跳到对话顶部（带一段动画，避免瞬移失去方向感）。
  void _scrollToTop() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      0,
      duration: AppDur.slow,
      curve: Curves.easeOutCubic,
    );
  }

  /// build101（F6）：复制最后一条非空助手消息到剪贴板。
  Future<void> _copyLastAssistantMessage() async {
    ChatMessage? last;
    for (var i = _messages.length - 1; i >= 0; i--) {
      final m = _messages[i];
      if (m.role == MessageRole.assistant && m.content.trim().isNotEmpty) {
        last = m;
        break;
      }
    }
    if (last == null) return;
    await Clipboard.setData(ClipboardData(text: last.content));
    if (!mounted) return;
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    AppSnackBar.showSnackBar(
      context,
      SnackBar(
        content: Text(isZh ? '已复制最后一条回复' : 'Copied last reply'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  /// 打开设置页（联网搜索配置）
  void _openSearchSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
  }

  // ==========================================================================
  // UI
  // ==========================================================================
  @override
  Widget build(BuildContext context) {
    // build141（反馈④）：结构性自愈护栏 —— 消息条数变了却没重算用量，就补一次。
    // 显式刷新点仍然保留（撤回/删除/下载兜底三处本轮已补上），这里只兜
    // 「下一个新增的变更入口又忘了调」这一类，代价是条数变化时多一趟 post-frame。
    if (_contextUsageMessageCount != _messages.length) {
      _contextUsageMessageCount = _messages.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _refreshContextUsage();
      });
    }
    final l = AppLocalizations.of(context);
    final isZh = l.locale.languageCode == 'zh';
    final webEnabled = _webSearchCfg.webSearchEnabled;
    // v1.6.9 build42 修复问题1/4：监听插件启用状态，使输入框 🌐/🧠 随插件开关实时刷新。
    final registry = context.watch<PluginRegistry>();
    final searchPluginOn = registry.isEnabled(PluginRegistry.kSearchPluginId);
    final selfCheckPluginOn =
        registry.isEnabled(PluginRegistry.kSelfCheckPluginId);
    // 聊天外观：新/旧皮肤开关 + 输入框按钮显隐/顺序（设置页可改）
    final chatSkin = context.watch<ChatSkinProvider>();
    // build138（甲3）：一次 build 内取数一次。列表的 itemCount / 日期头 /
    // 尾部孤儿压缩段都读这份，读两次就会出现"长度与渲染不一致"。
    final visible = _visibleMessages;
    // itemBuilder 拿到的是**可见下标**，而长按菜单/编辑重发要的是主表下标
    // （那两处内部按 `_messages.removeRange(index, …)` 这类主表位置动刀）。
    // 只在真在筛选时才建反查表：没筛时 visible 与 _messages 是同一份引用、
    // 下标天然相等，而本函数在流式期每个 chunk 都要重跑一遍 build，
    // 无条件建表就是把 O(n) 白烧在最常见的路径上。
    final masterIndexOf = _starredOnly
        ? {for (var i = 0; i < _messages.length; i++) _messages[i].id: i}
        : null;

    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_apiConfig == null) {
      return NoApiKeyView(
        l: l,
        isZh: isZh,
        onBack: () => Navigator.pop(context),
      );
    }

    return _withShortcuts(
      child: Scaffold(
        // build161：键盘占位交给输入区自己抬（`ChatInput` 里的 [ImeLift]），这里显式弃权。
        // 为什么必须写出来而不是留着不管：本机（Android 16 + `setDecorFitsSystemWindows(false)`）
        // 窗口不随键盘缩，而树内 `MediaQuery.viewInsets` 恒为 0 ⇒ 这个开关**从来没起过作用**
        // （证据：`上限` 恒 852 = 932 - 0 - chrome）。将来 Flutter 把这一环修好了，
        // 它就会和 `ImeLift` 各抬一次 ⇒ 输入框悬在屏幕中间。尺寸不许有第二个所有者。
        resizeToAvoidBottomInset: false,
        appBar: AppBar(
          // v1.7.21 P0-2：标题可自定义（点击编辑）；v1.7.20：首条消息后自动设标题
          title: GestureDetector(
            onTap: () => _editConversationTitle(),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    widget.conversation.title,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 6),
                Icon(
                  Icons.edit_outlined,
                  size: 16,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
          actions: [
            // build138（甲3）：只看收藏——顶栏常驻开关（不放 AppBar 菜单里：
            // 这是个"反复进出"的视图态，藏在二级菜单里等于没有）。
            _StarredFilterToggle(
              isZh: isZh,
              selected: _starredOnly,
              count: visible.length,
              onChanged: _toggleStarredFilter,
            ),
            ChatAppBarMenu(
              l: l,
              isZh: isZh,
              compressBusy: _compressInProgress,
              onSelected: (value) async {
                if (value == 'pluginManager') {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const PluginManagementScreen()),
                  );
                } else if (value == 'settings') {
                  await _showConversationSettings();
                } else if (value == 'compress') {
                  await _compressContext();
                } else if (value == 'findInChat') {
                  // build101（F1/F2）：会话内查找 → 命中项回传下标 → 滚动定位
                  await _openChatSearch();
                } else if (value == 'compare') {
                  // build101（E5）：带着当前输入框内容进对比页
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ModelCompareScreen(
                        initialQuestion: _inputController.text.trim(),
                      ),
                    ),
                  );
                } else if (value == 'download') {
                  await _showGenericDownloadDialog();
                } else if (value == 'clear') {
                  // build152（状态扫描 S2）：流式进行中不许清空对话。
                  // 原来这里没有门禁，且 `_loadData()` 不 await ⇒ 两条后果：
                  // ① 直聊路径在途 chunk 回来时列表已被整表替换成空，
                  //    写 `_messages.last` 抛 StateError（catch 里再写一次 = 二次抛错、
                  //    逃出 try 进 runZonedGuarded）；
                  // ② ReAct 路径更安静：循环跑完 `saveMessage` 按 id replace，
                  //    把刚清空的那条**插回 DB**，重进会话冒出一条没有提问的孤立回答。
                  // 与其在两条异步尾巴上都补判据，不如在入口挡掉 —— 清空是破坏性操作，
                  // "请先停止生成"比"清了一半又复活一条"诚实得多。
                  if (_isStreaming) {
                    final zh =
                        AppLocalizations.of(context).locale.languageCode == 'zh';
                    AppSnackBar.showSnackBar(
                      context,
                      SnackBar(
                        content: Text(zh
                            ? 'AI 正在生成，请先点「停止」再清空对话'
                            : 'Stop generating before clearing the conversation'),
                        duration: const Duration(seconds: 2),
                        behavior: SnackBarBehavior.floating,
                        width: 300,
                      ),
                    );
                    return;
                  }
                  final storage = context.read<StorageService>();
                  await storage
                      .deleteMessagesByConversation(widget.conversation.id);
                  _loadData();
                }
              },
            ),
          ],
        ),
        body: _withBackground(
          chatSkin,
          Column(
            children: [
              Expanded(
                // build139（真机反馈③的第二半）：胶囊原先是这个 Column 的
                // **流内**子节点 —— 它一出现就吃掉一截列表高度（消息整列被顶得
                // 上跳），而且它背后永远只有页面背景，所谓「毛玻璃」糊不到任何
                // 消息文字（0.30 底 + 模糊形同虚设）。改成与列表同一个 Stack 的
                // 悬浮层后：布局不再因它出现而跳动，模糊与描边才真的作用在消息上。
                child: Stack(
                  children: [
                    _messages.isEmpty
                    ? Center(
                        child: EmptyChatHint(
                          l: l,
                          isZh: isZh,
                          model: _apiConfig!.model,
                          onPromptTap: (text) {
                            _inputController.text = text;
                            _inputFocus.requestFocus();
                          },
                        ),
                      )
                    // build138（甲3）：开着只看收藏却一条都没收藏 ⇒ 走统一空态。
                    // 这里**必须**给出路（空态只画"还没有收藏"是不够的，
                    // 用户不知道收藏这件事怎么做、也不知道怎么退出这个视图），
                    // 故 subtitle 写清入口、action 直接关掉筛选。
                    // 用 AppAsyncView 包一层：它就是这个工程"加载/失败/空/数据"
                    // 四态的统一外壳（build133），空态是它的 child 分支。
                    // 旧实现在这种组合下是**白屏**——看着像会话被清空了。
                    : visible.isEmpty
                        ? AppAsyncView(
                            loading: false,
                            zh: isZh,
                            child: AppEmptyView(
                              icon: Icons.star_border,
                              title: isZh
                                  ? '还没有收藏的消息'
                                  : 'No starred messages yet',
                              subtitle: isZh
                                  ? '长按任意消息 →「收藏此条」，之后就能在这里只看收藏'
                                  : 'Long-press a message and pick "Star message" to collect it here.',
                              action: OutlinedButton(
                                onPressed: () =>
                                    setState(() => _starredOnly = false),
                                child: Text(isZh
                                    ? '退出只看收藏'
                                    : 'Show all messages'),
                              ),
                            ),
                          )
                        : NotificationListener<ScrollNotification>(
                            // SF-1：用户手势让位——拖动离底 >80px 暂停跟随，滑回底部恢复。
                            // 仅认用户拖动（dragDetails 非空），自己 jumpTo 引发的滚动不误判。
                            onNotification: (n) {
                              if (n.depth != 0) return false;
                              final isUserDrag = n is UserScrollNotification ||
                                  (n is ScrollUpdateNotification &&
                                      n.dragDetails != null);
                              if (!isUserDrag) return false;
                              final pos = _scrollController.position;
                              final dist = pos.maxScrollExtent - pos.pixels;
                              if (dist > _followThreshold) {
                                if (_autoFollow) {
                                  setState(() => _autoFollow = false);
                                }
                              } else if (!_autoFollow) {
                                setState(() => _autoFollow = true);
                              }
                              return false;
                            },
                            child: ListView.builder(
                              controller: _scrollController,
                              padding: const EdgeInsets.all(8),
                              // build138（甲3）：只看收藏时**只有可见列表进这里**。
                              // itemCount 若还跟 _messages 走，尾部会渲染出空白 item
                              // （index 越界前的一条条空气泡），是最容易漏的一处。
                              itemCount: visible.length,
                              itemBuilder: (context, index) {
                                final msg = visible[index];
                                // build138（甲3）：mi = 这条消息在 _messages 主表里的
                                // 下标（没筛时它与可见下标天然相等，见 build 顶上的说明）。
                                // 所有"按主表位置动刀"的地方（活跃判定、最新一轮判定、
                                // 长按菜单、编辑重发）一律用 mi，不能用 index。
                                final mi = masterIndexOf == null
                                    ? index
                                    : (masterIndexOf[msg.id] ?? index);
                                // 末条语义分两支：
                                // · isLastMaster —— 流式高亮跟的是**主表**末条，
                                //   没收藏的最新回答就是不出现（不是把它挪到别处显示）；
                                // · isLastVisible —— 孤儿压缩段挂可见列表末尾，否则
                                //   筛选下锚点被删的摘要会彻底看不见。
                                final isLastMaster = mi == _messages.length - 1;
                                final isLastVisible = index == visible.length - 1;
                                final isStreaming = isLastMaster && _isStreaming;
                                final displayCfg =
                                    _currentSessionModel ?? _apiConfig;
                                // v1.7.22：撤回 / 重试 / 版本切换回调（闭包调用 extension 成员）
                                // build96 (O12)：按消息活跃判定——流式期间仅禁用活跃中的
                                // 最后一条助手消息及其触发的用户消息，历史消息按钮保留
                                // build97 (P1-1 修复)：边界写反过——index >= activeFrom 才是活跃。
                                // 流式中活跃的是 N-2(触发提问)/N-1(流式回答)，历史 0..N-3 保留；
                                // 非流式 activeFrom=N，全部可用。
                                final activeFrom = _isStreaming
                                    ? _messages.length - 2
                                    : _messages.length;
                                // build129（#105）：用户反馈「之前的老消息不要再显示编辑并重发了」——
                                // 行内 ✏️编辑重发 / ↻重试 只留给**最新一轮**，历史消息不再出现。
                                // 口径收敛在 isLatestRoundMessage（纯函数，O(1)）：
                                // 长按菜单里的同名项此前各写一遍、漏掉了收口，两处必须共用同一实现。
                                // build138（甲3）：传的仍是**主表** msgs + mi——
                                // "最新一轮"是对整个对话的事实，不能因为视图筛掉了消息就改口；
                                // 筛掉后它不出现，入口自然也不会冒出来（口径与不筛时逐字一致）。
                                final bool isLatestUserMsg = isLatestRoundMessage(
                                    msgs: _messages,
                                    index: mi,
                                    role: MessageRole.user);
                                final bool isLatestAssistantMsg = isLatestRoundMessage(
                                    msgs: _messages,
                                    index: mi,
                                    role: MessageRole.assistant);
                                // 版本切换（‹ 1/3 ›）仍按原「活跃判定」保留：老消息的多版本
                                // 对比是既有能力，不属于本次要收掉的「重发」入口。
                                final canSwitchVersion =
                                    msg.role == MessageRole.assistant &&
                                        mi < activeFrom;
                                final canRetry =
                                    canSwitchVersion && isLatestAssistantMsg;
                                // v1.7.26 (E6)：按消息 id 稳定 Key——重试/撤回列表重建时避免
                                // Flutter 复用旧元素状态导致滚动位置/动画错乱
                                // v1.7.38：V2 朴素皮肤常驻（旧皮肤已移除）
                                final bubble = MessageBubbleV2(
                                  key: ValueKey(msg.id),
                                  message: msg,
                                  // build133（⑦）：把收藏（星标）状态交给气泡 ——
                                  // 此前它只在长按菜单里切图标，写入后没有任何读取点。
                                  isStarred: _starredIds.contains(msg.id),
                                  isStreaming: isStreaming,
                                  // build102（B）：历史气泡显示消息落库时的模型名（ChatMessage.modelName），
                                  // 仅该消息没存过模型名时回退当前所选模型 —— 旧实现直接传
                                  // displayCfg.model，切模型后所有历史消息的模型标签全跟着变
                                  //（build101 实测反馈；重试路径 chat_screen_message.dart:785 本就用
                                  // assistantMsg.modelName，此处对齐）
                                  modelName: (msg.modelName?.isNotEmpty ?? false)
                                      ? msg.modelName!
                                      : (displayCfg != null &&
                                              displayCfg.model.isNotEmpty)
                                          ? displayCfg.model
                                          : isZh
                                              ? '内置'
                                              : 'Built-in',
                                  onRetry:
                                      canRetry ? () => _retryMessage(msg) : null,
                                  // build161 ③：掉线失败气泡常驻的续写按钮。判据三条缺一不可：
                                  //  · 最后一条助手消息 —— 与 `_continueFromMessage` 的"只能续
                                  //    最后一条"是同一事实，这里先挡住，免得点了才弹SnackBar；
                                  //  · 正文尾挂着"这一轮没跑完"那三句之一（[continueEntryKindFor]）；
                                  //  · 本轮没在流式 —— 续写进行中按钮是多余的（岛正在说同一件事）。
                                  // build165 ③：出现判据从 `hasNetworkDropNote` 换成
                                  // [continueEntryKindFor] —— 旧的那条**刻意不认**"0 正文"那一句，
                                  // 于是纯 thinking 的一轮（真机 7 轮里 5 轮如此）既不自动续、
                                  // 也没有任何可点的东西，屏幕上只剩一句"本轮没有结果"。
                                  // 用户此刻最直接的痛就是这个（「我给他终止了」之后他没按钮可点）。
                                  // 按钮**写什么**由同一个判据给（`continueEntryLabel`）：
                                  // 整轮重跑的那一类写「重新发起这一轮」，不写"接着写"。
                                  onContinue: (msg.role ==
                                              MessageRole.assistant &&
                                          isLatestAssistantMsg &&
                                          !isStreaming &&
                                          continueEntryKindFor(
                                                  msg.content) !=
                                              null)
                                      ? () => _onContinueEntryTap(msg)
                                      : null,
                                  retryVersionCount: _computeRetryVersionCount(msg),
                                  retryVersionIndex: _computeRetryVersionIndex(msg),
                                  // v1.7.38（card 协议）：卡片选项点选 → 快捷回复（同重试路径：走输入框再发送）
                                  onQuickReply: (text) {
                                    _inputController.text = text;
                                    _sendMessage();
                                  },
                                  onSwitchVersion: canSwitchVersion
                                      ? (direction) =>
                                          _switchRetryVersion(msg, direction)
                                      : null,
                                  onRollback: (msg.role == MessageRole.user &&
                                          mi < activeFrom)
                                      ? () => _rollbackMessage(msg)
                                      : null,
                                  // build103：编辑重发入口上浮到操作行（功能 build101 B3 已有，
                                  // 藏在长按菜单里用户找不到——发现性修复，复用既有实现）
                                  // build129（#105）：再收一道——只有**最后一条用户消息**保留该入口；
                                  // 长按菜单里的同名项用同一个 isLatestRoundMessage 收口，
                                  // 两处口径一致（历史消息在任何入口都不再出现编辑重发）。
                                  onEdit: (msg.role == MessageRole.user &&
                                          mi < activeFrom &&
                                          isLatestUserMsg)
                                      ? () => _editAndResend(msg, mi)
                                      : null,
                                  // build101（D1/D3）：外观开关透传
                                  showAvatar: chatSkin.showAvatar,
                                  userAvatarPath: chatSkin.userAvatarPath,
                                  aiAvatarPath: chatSkin.aiAvatarPath,
                                  showBubble: chatSkin.showBubble,
                                  leftAlign: chatSkin.leftAlign,
                                  showTimestamp: chatSkin.showTimestamp,
                                  // MN-2：模型名只在「消息落库的模型 ≠ 当前会话所选模型」时
                                  // 显示——当前模型每条气泡重复标注是噪音；未存 modelName
                                  // 的消息（回退当前模型）也不显示。重试版本/多模型对比
                                  // msg.modelName 天然与当前不同，仍会标注。
                                  showModelName: chatSkin.showModelName &&
                                      (msg.modelName?.isNotEmpty ?? false) &&
                                      msg.modelName != displayCfg?.model,
                                  showTokenUsage: chatSkin.showTokenUsage,
                                  showCharCount: chatSkin.showCharCount,
                                  firstTokenLatencyMs:
                                      chatSkin.showFirstTokenLatency
                                          ? _firstTokenLatencyOf(msg)
                                          : 0,
                                  // build101（F2）：会话内查找跳转落点高亮
                                  highlighted: _highlightedMessageId == msg.id,
                                );
                                // build101（B4）：长按消息 → 统一操作菜单
                                // （保存到记忆 / 引用 / 编辑重发 / 删除本条 / 复制）
                                // 原 build90 的长按直接存记忆已并入菜单首项。
                                // build138（甲3）：传 mi 而非可见下标——菜单内部要拿它
                                // 回主表定位（编辑重发的截断、"停止并撤回"的活跃判定）。
                                final wrappedBubble = GestureDetector(
                                  onLongPress: () => _showMessageMenu(msg, mi),
                                  child: bubble,
                                );
                                // v1.7.37：压缩卡片（Trae 式可见化）——挂在覆盖区间末尾消息下方
                                final segCards = _compactionSegments
                                    .where((s) => s.endMessageId == msg.id)
                                    .map((s) => _buildCompactionCard(s, isZh))
                                    .toList();
                                // 审查 B-4：锚点消息已被撤回/删除的孤儿段兜底挂在最后一条消息下，
                                // 避免摘要还在（或曾）参与上下文却完全不可见
                                // build138（甲3）：兜底点跟**可见**末条走（isLastMaster 在
                                // 筛选下可能永远不成立，摘要就成了永远翻不到的一段）。
                                if (isLastVisible) {
                                  final msgIds = _messages.map((m) => m.id).toSet();
                                  segCards.addAll(_compactionSegments
                                      .where(
                                          (s) => !msgIds.contains(s.endMessageId))
                                      .map((s) => _buildCompactionCard(s, isZh)));
                                }
                                // build101（F10）：日期分组头——与上一条跨天时插入
                                // build138（甲3）：数据源是可渲染列表，理由见 _buildDayHeader。
                                final dayHeader =
                                    _buildDayHeader(visible, index, isZh);
                                if (segCards.isEmpty) {
                                  if (dayHeader == null) return wrappedBubble;
                                  return Column(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [dayHeader, wrappedBubble],
                                  );
                                }
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    if (dayHeader != null) dayHeader,
                                    wrappedBubble,
                                    ...segCards,
                                  ],
                                );
                              },
                            ),
                          ),
                    // SF-3：「↓ 回到底部」悬浮按钮——仅在用户上滑让位（_autoFollow=false）时出现
                    if (!_autoFollow)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Align(
                          alignment: Alignment.center,
                  child: Padding(
                    // build136 修「回到底部会侧挡」：胶囊与 _buildContextUsageBar 是
                    // 同一个 Stack 的兄弟节点，且用量条**排在其后**（后绘制＝盖在上面），
                    // 两者又都贴底对齐 ⇒ 原来只让位 4px，实际压在用量条（约 22px 高）上
                    // （真机截图红圈即此处）。30 = 用量条高度 + 呼吸量。
                    // ⚠️ 改这里请连带看 _buildContextUsageBar 的 Padding/行高。
                    padding: const EdgeInsets.only(bottom: 30),
                    child: ClipRRect(
                      // build138 真机反馈③：「回到底部不是透明，是实体有一个长方形
                      // 遮住了」。上一版只把底色调到 0.65 并留着 2 级投影 ——
                      // 暗色下 0.65 的 surfaceContainerHighest 依然不透消息，投影又
                      // 额外画出一圈"板子落在屏幕上"的阴影 ⇒ 观感仍是实心长方形。
                      // 现在改成正经毛玻璃：背后内容真模糊（BackdropFilter）+ 底色
                      // 压到 appFloating(0.30) + 1px 描边交代边界 + **投影归零**。
                      // ⚠️ BackdropFilter 必须包在 ClipRRect 里，否则模糊会糊到整个
                      //   Stack 的矩形区域（比胶囊大一圈的"雾面方块"，正是本次反馈）。
                      //   （本段区域由 test/build138_realdevice_ui_test.dart 锁死：
                      //   出现任何投影参数即判失败，故此处的注释也别写那个英文字。）
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color:
                                Theme.of(context).colorScheme.appFloating,
                            borderRadius: BorderRadius.circular(AppRadius.pill),
                            border: Border.all(
                                color: Theme.of(context).colorScheme.appBorder),
                          ),
                          child: Material(
                            type: MaterialType.transparency,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(AppRadius.pill),
                              onTap: () {
                                setState(() => _autoFollow = true);
                                WidgetsBinding.instance
                                    .addPostFrameCallback((_) {
                                  if (!_scrollController.hasClients) return;
                                  _scrollController.animateTo(
                                    _scrollController.position.maxScrollExtent,
                                    duration: AppDur.slow,
                                    curve: Curves.easeOut,
                                  );
                                });
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 6),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.keyboard_arrow_down,
                                        size: 18,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant),
                                    Text(
                                      isZh ? '回到底部' : 'Bottom',
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall
                                          ?.copyWith(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                        ),
                      ),
                  ],
                ),
              ),
              // build140（反馈⑥）：待办常驻条排在用量条**之前**（更靠列表），
              // 三层各占一位：胶囊浮在列表区 / 待办条与用量条排在输入框上方。
              _buildTodoStrip(isZh),
              _buildContextUsageBar(isZh),
              // build90 ⑨：斜杠命令匹配面板（输入行首 / 时出现）
              if (_slashMatches.isNotEmpty)
                Container(
                  constraints: const BoxConstraints(maxHeight: 200),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    border: Border(
                      top: BorderSide(
                          color: Theme.of(context)
                              .dividerColor
                              .withValues(alpha: 0.3)),
                    ),
                  ),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _slashMatches.length,
                    itemBuilder: (context, i) {
                      final c = _slashMatches[i];
                      return ListTile(
                        dense: true,
                        leading: const Icon(Icons.terminal, size: 18),
                        title: Text('/${c.name}'),
                        subtitle: Text(c.promptTemplate,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () => _applySlashCommand(c),
                      );
                    },
                  ),
                ),
              ChatInput(
                config: ChatInputConfig(
                  searchMode: _searchMode,
                  searchEnabled: webEnabled && searchPluginOn,
                  reactRounds: widget.conversation.reactMaxRounds,
                  reactLevelLabel: _conversationReactLevelLabel,
                  reactEnabled:
                      widget.conversation.reactEnabled && selfCheckPluginOn,
                  reactAutoMode: widget.conversation.reactAutoMode,
                  reasoningEffort: widget.conversation.reasoningEffort,
                  largeContextMax: widget.conversation.largeContextMax,
                  // build173 第三片：档位镜像进 🧠 弹层（只传原值，语义仍由 services 层判）
                  subagentMode: widget.conversation.subagentMode,
                  pluginHintMode: _pluginHintConfig.mode,
                  pluginHintManualCount:
                      _effectiveManualSelectedCount(registry),
                  availableConfigs: _apiConfigs,
                  availableAccounts: _apiAccounts,
                  currentConfig: _currentSessionModel,
                  pendingAttachments: _pendingAttachments,
                  // build101（F5）：长文本粘贴转文件（设置页开关）
                  pasteLongAsFile: chatSkin.pasteAsFile,
                  pendingFollowupCount: pendingFollowupCount,
                  isGenerating: _isStreaming,
                  buttonOrder: chatSkin.visibleButtonOrder,
                ),
                actions: ChatInputActions(
                  onToggleSearch: () async {
                    // build 11+：切换后立即持久化（常驻，不再发完就 reset）
                    await _saveSearchToggle(!_searchMode);
                  },
                  onOpenSearchSettings: _openSearchSettings,
                  // v1.7.18 需求7：🌐/🧠 长按分别跳转联网搜索 / 自主思考设置页
                  onLongPressSearch: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const WebSearchSettingsScreen()),
                    );
                  },
                  // v1.7.25：ReAct 全局设置页已删 → 长按 🧠 打开对话设置面板
                  onLongPressReact: () => _showConversationSettings(),
                  onReasoningEffortChanged: _saveReasoningEffort,
                  onLargeContextMaxChanged: _saveLargeContextMax,
                  // build173 第三片：档位入口并进 🧠 点按弹层（长按仍进对话设置，一位没动）
                  onSubagentModeChanged: _saveSubagentMode,
                  onTogglePluginHint: _togglePluginHint,
                  onEditPluginHint: _editPluginHint,
                  onModelChanged: _onModelChanged,
                  onPickAttachment: _pickAttachment,
                  // build101（F5）：长文本自动转附件
                  onLongTextPasted: _onLongTextPasted,
                  onRemoveAttachment: _removeAttachment,
                ),
                controller: _inputController,
                focusNode: _inputFocus,
                onSend: () => _sendMessage(),
                onStop: () => _stopGeneration(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// build101（D2）：聊天背景图。未设背景时原样返回 body（零开销）。
  ///
  /// build168（宽屏档）：内容列**也**落在这一个函数里，而不是落在调用点上——
  /// 这里两条分支（有背景图 / 无背景图）交出去的是同一个 `content`，所以
  /// 「设了聊天壁纸就把列宽弄丢」这种半更新不可能发生（壁纸本身仍通栏，
  /// 被夹的只是压在它上面的那条内容列）。全 App 只有这一处把子树交给
  /// [AppContentColumn]：列表、待办条、用量条、输入区共用同一列 ⇒ 天然对齐。
  /// 数值（600/840 断点、640/720 上限）不住在本文件，见 `lib/ui/app_content.dart`。
  Widget _withBackground(ChatSkinProvider skin, Widget body) {
    final content = AppContentColumn(child: body);
    final path = skin.backgroundPath;
    if (path.trim().isEmpty) return content;
    final file = File(path);
    if (!file.existsSync()) return content;
    return Stack(
      children: [
        Positioned.fill(
          child: Image.file(
            file,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
        ),
        // 半透明遮罩保证消息可读
        Positioned.fill(
          child: ColoredBox(
            color:
                Theme.of(context).colorScheme.surface.withValues(alpha: 0.72),
          ),
        ),
        Positioned.fill(child: content),
      ],
    );
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    // v1.7.16 修复：退页后停止 ReAct 循环 + 活跃流，避免后台继续烧 API / 写库
    _reactLoopStopRequested = true;
    // build138（扫描 P2-3）：让插件层的 `if (!pc.mounted) return` 护栏真的生效——
    // 此前没有任何地方调用 setMounted(false)，退页后插件仍会继续 setState /
    // 写库 / 烧 API（pc 内快照恒为 true）。
    _livePluginContext?.setMounted(false);
    _livePluginContext = null;
    // build169（#102）：这里**以前**是 `context.read<ApiService>().stopGeneration(...)`
    // 包在一个 catch 里。dispose 时元素已失效，Provider 内部对可空元素用 `!`
    // ⇒ 真机上每退一次对话页就抛一条 `Null check operator used on a null value`，
    // 被那句 `debugPrint('catch 静默异常')` 咽成一行看起来像正常路径的日志，
    // 而 **stopGeneration 一次都没执行到**：这一轮的流没人停，继续烧 token、
    // 继续往用户已经离开的会话里写。装机取证见 docs/BUGSCAN_build166_20260926.md ⑩。
    // 现在吃 initState 缓存的 [_api]，全程不碰 context；也**不再包 catch** ——
    // 这个 catch 正是把缺陷藏了 4 个版本的东西，再包一层等于把哨兵拆了留着。
    final api = _api;
    if (api == null) {
      // 不假装成功：initState 没跑到就退页是可能的（构造期就抛），
      // 那种情况下这一轮的流确实没人收 —— 讲明，别塌成一条读起来像正常路径的字。
      _logger.warn(
        'chat screen disposed without a cached ApiService: this round\'s stream '
        'was NOT stopped (scope=${widget.conversation.id})',
        tag: 'Chat',
      );
    } else {
      // build132：**按作用域停**。此前是无 scope 调用，而 api_service 的判定是
      // `scope == null || _activeScopes[i] == scope` ⇒ 会命中**所有**作用域。
      // 退本页只应停本页的流：ChatScreen 走 Navigator.push（分享深链 main.dart:200
      // 可压在任意页之上），两页同栈时无 scope 调用会把下面那页正在跑的流一并停掉。
      // （v1.7.26 D5 引入 scope 本就为「页面只停自己」，dispose 是当时漏掉的一处。）
      api.stopGeneration(
        scope: widget.conversation.id,
        reason: 'chat screen disposed',
      );
    }
    // v1.3.4：移除 storage listener，避免内存泄漏
    _storage.removeListener(_storageListener);
    // build123：注销分享投递口（否则会话页销毁后回调仍指向已 dispose 的 State）
    ShareIntentService.instance.unregisterInserter(widget.conversation.id);
    // build162：连着注销"回前台续写"的挂点，并把攒着的那一笔就地了结。
    // 为什么必须了结而不能留着：本页销毁后再没有人按 id 找得到这两条消息，
    // 而岛上那一行是我们留下的（`dropContinuePendingIslandLabel` 写过的「进行中」）
    // —— 永驻的「进行中」比不出现更糟（build148/150/156 一整族都在为它买单），
    // 所以这里与 161 在 `_runDropContinueRound` 里 `!mounted` 那一支同形：安静撤条。
    AppResumeSignal.instance.unregister(widget.conversation.id);
    final pendDrop = _dropCont.pending;
    if (pendDrop != null) {
      _dropCont.clearPending();
      unawaited(LiveTaskWiring.onResearchEnd(pendDrop.userMsgId,
          deep: pendDrop.deep, quiet: true));
    }
    _inputController.removeListener(_inputListener);
    _scrollController.dispose();
    _inputController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }
}

// ================= build138（甲3）顶栏「只看收藏」开关 =================

/// 顶栏筛选开关。**为什么是常驻 chip 而不是 AppBar 菜单项**：
/// 收藏这件事的真实用法是「翻一段」——进去看一眼、马上要出来，
/// 二级菜单里的一次开关 = 两次点击 + 一个看不见的当前状态。
///
/// 样式沿用工程既有 FilterChip（日志页 / 对比页的筛选条都是它），
/// 只改三处：不画对勾（选中态靠底色 + 实心星表达，对勾在这里是第三份
/// 冗余信息）、圆角取 [AppRadius.inline]（R3 只允许 {6,8,12,14}）、
/// 描边/文字取 `cs.appBorder` / `cs.appTextSub`（不写死颜色）。
///
/// [count] 只在选中态显示，取**当前可见条数**：筛完剩几条要一眼可比，
/// 而 starredIds 里可能留着已删除消息的残留 id（toggleStarMessage 不清理），
/// 拿它当数字会「显示 5 条、屏上只有 4 条」。
class _StarredFilterToggle extends StatelessWidget {
  const _StarredFilterToggle({
    required this.isZh,
    required this.selected,
    required this.count,
    required this.onChanged,
  });

  final bool isZh;
  final bool selected;
  final int count;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final label = isZh ? '只看收藏' : 'Starred only';
    return Padding(
      // AppBar actions 自带右侧间距，这里只补它与菜单按钮之间的一点呼吸
      padding: const EdgeInsets.only(right: AppGap.xs),
      child: FilterChip(
        // 空间紧：标题是 Flexible 会先让位，但开关自己也别占宽
        visualDensity: VisualDensity.compact,
        labelPadding: const EdgeInsets.symmetric(horizontal: AppGap.xs),
        showCheckmark: false,
        tooltip: isZh
            ? '只看收藏（长按消息可收藏）'
            : 'Show starred messages only',
        avatar: Icon(
          selected ? Icons.star : Icons.star_border,
          size: 16,
          color: selected ? cs.onSurface : cs.appTextSub,
        ),
        label: Text(
          selected && count > 0 ? '$label ($count)' : label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: selected ? cs.onSurface : cs.appTextSub, fontSize: 12),
        ),
        selected: selected,
        selectedColor: cs.appBubble,
        backgroundColor: cs.appPanelLight,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.inline),
          side: BorderSide(color: cs.appBorder),
        ),
        onSelected: (_) => onChanged(),
      ),
    );
  }
}

// ================= build101（F6）快捷键 Intent =================

/// Ctrl/Cmd + Enter：发送
class _SendIntent extends Intent {
  const _SendIntent();
}

/// Esc：停止生成
class _StopIntent extends Intent {
  const _StopIntent();
}

/// Ctrl/Cmd + F：在对话中查找
class _FindInChatIntent extends Intent {
  const _FindInChatIntent();
}

/// Alt + ↑：跳到顶部
class _ScrollTopIntent extends Intent {
  const _ScrollTopIntent();
}

/// Alt + ↓：跳到底部
class _ScrollBottomIntent extends Intent {
  const _ScrollBottomIntent();
}

/// Ctrl/Cmd + Shift + C：复制最后一条助手消息
class _CopyLastIntent extends Intent {
  const _CopyLastIntent();
}
