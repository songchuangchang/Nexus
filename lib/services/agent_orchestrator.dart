// v1.7.34：子代理编排器
//
// 流程：
//   主 Agent（route） → 专家（0~3 个，串行）→ 主 Agent（synthesize）
//
// build132：**专家之间仍是串行**（route → 搜索专家 → 合成专家 是真实依赖链，
//   合成必须等检索结果），唯一可并行的是「一轮内的多条检索查询」——已由
//   全串行改为「首条串行 + 其余并发」（成本闸不变，见 _executeSearch）。
//
// 与 ReAct 循环的分工（build146 重定，判据唯一入口 [subagentModeUsesOrchestrator]）：
//   - auto / main_only / force_plugin → 完全走现有 ReAct 循环（不动）
//   - force_search / force_synthesis → 走本编排器（深度研究由 auto 升档而来）
//
// 上限：一次用户消息最多 4 次 LLM 调用（主 → 专家 → 主合成，最多两轮专家）
//
// build129（#107）**接线**：宿主入口是
//   lib/screens/chat_screen_orchestrator.dart 的 _runOrchestratedAnswer，
//   由 lib/screens/chat_screen_message.dart 的 _sendMessage 在进 ReAct 之前调用。
//   返回 null / 抛异常 → 宿主撤销占位气泡并回退 ReAct（不静默）。
//   两个可选钩子 onStep / onAnswerDelta 供宿主实时上屏，不传则行为与接入前一致。

import '../models/api_config.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../models/web_search_config.dart';
import '../prompts/agent_prompts.dart';
import 'agent_parser.dart';
import 'api_service.dart';
import 'logger_service.dart';
import 'web_search_service.dart';

/// 编排结果
class OrchestrationResult {
  final String answer;
  final List<ReasoningStep> reasoningSteps;
  final int llmCallCount;

  /// build129（#107）：本编排实际注入的网络搜索条数。
  ///
  /// 原实现只把命中数写进 reasoning step 文本（`hits=N`），宿主拿不到 →
  /// 气泡的「已联网注入 N 条」徽标无法显示。此处显式回传，宿主必须经
  /// [ChatMessage.sanitizeSearchHits] 过滤后落库（历史 999999999 事故同源）。
  final int searchHitCount;

  /// build130：**交回 ReAct 执行**的信号（当前仅插件目标使用）。
  ///
  /// 编排器内**没有插件执行引擎**：插件专家的产物是
  /// `<plugin_call name="图片生成">` 这类**文本**，既不是 ReAct 的动作语法
  /// （`<image_gen .../>`），也没有任何执行点。此前这条路会一路跑到「合成」，
  /// 把那段 XML 当散文揉进回答 ⇒ 用户看到的是「说了要生成、图没出来」。
  /// 真机日志 2026-09-19 11:59 实锤：route→plugin 后**无任何 `[ImageGen] POST`**，
  /// 仅 `[Orch] 完成 … llmCalls=3 hits=0`。
  ///
  /// ReAct 循环才是插件的执行者 ⇒ 该目标下编排器只产出**路由结论**即返回，
  /// 由宿主静默交回 ReAct（省掉专家 + 合成两次 LLM 调用，且不再有"假完成"）。
  final bool delegateToReact;

  /// build132：本轮实际路由到的目标（`self` / `search` / `synthesis` / `plugin`）。
  ///
  /// 面板文案人话化后，route 步骤的 content 变成「路由判断：<原因>（target=self）」，
  /// 而宿主收尾日志 `[Orch] 完成 … target=…` 此前是**从 route 步骤文本里抠**的
  /// ⇒ 日志会变成一长串中文。显式回传后，日志仍是机器可读的 `target=self`，
  /// 而面板可以放心说人话（二者解耦）。
  final String target;

  OrchestrationResult({
    required this.answer,
    required this.reasoningSteps,
    required this.llmCallCount,
    this.searchHitCount = 0,
    this.delegateToReact = false,
    this.target = '',
  });
}

/// build146（取证闸）：Step 2 到底跑不跑**检索链**——唯一判据。
///
/// `target == 'synthesis'` 在联网可用时也要先检索：合成档的语义是"以结构化分析
/// 为主"，**不等于"不许有证据"**。旧实现写死 `evidence: ''`，于是这一档交付的
/// 是"没有证据的结构化改写"，却仍以研究成果的样子落地（本项目反复修的"假完成"族）。
/// 联网不可用（`webSearchEnabled == false`）时无处可查，才允许无证据综合，
/// 并且必须配一条 [emptyEvidenceNotice] 步骤——**二选一，不许含糊**。
bool shouldRunSearchExpert({
  required String target,
  required bool webSearchEnabled,
}) =>
    target == 'search' || (target == 'synthesis' && webSearchEnabled);

/// build146（子代理：路由不再单独花钱）：**唯一**的「这一档这一轮到底算什么」口径。
///
/// 输入是库里存的原值（`conversations.subagentMode`，TEXT 五档，**无迁移无新列**）
/// 加「本轮是否深度研究」（`reasoningEffort` 拉满 1.0，判据 `ApiService.isDeepResearchEffort`），
/// 输出归一化后的档位（仍是那 5 个字符串之一）：
///
/// | 存值 | deep | 归一化 | 落点 |
/// |---|---|---|---|
/// | `auto` | false | `auto` | ReAct |
/// | `auto` | true | `force_search` | 编排：先取证，**不付路由调用** |
/// | `main_only` | false | `main_only` | ReAct |
/// | `main_only` | true | `force_search` | 编排（深度研究优先于"只用主代理"，见下）|
/// | `force_search` | 任意 | `force_search` | 编排 |
/// | `force_synthesis` | 任意 | `force_synthesis` | 编排（空取证时先补检索，见 [emptyEvidenceNotice]）|
/// | `force_plugin` | 任意 | `force_plugin` | ReAct（ReAct 才是插件执行者）|
///
/// `main_only` + 深度研究也升档：用户把思考强度拉满就是明确说了「要研究」，
/// 而"只用主代理"这一档在 build146 之后与 `auto` 落到同一条路（都归 ReAct），
/// 不升档的话这两档在深度研究下**完全一样**、且研究名存实亡。
///
/// 为什么深度研究要在**这里**升档而不是在宿主各判一次：用户把思考强度拉到 1.0
/// 已经说了「研究」，再让编排器花一次 LLM 调用去问「要不要研究」是重复付费；
/// 升档后 Step 1 直接命中强制分支（run 的 `force_search` 分支），
/// 既跳过路由调用，也顺带绕开「deep 且 target=self → 强行改 synthesis」那条
/// 把深度研究推进**零取证**分支的 override。
///
/// 为什么是纯函数：门控（宿主）、编排器内部（Step 1 走哪条分支）、单测三方必须读到
/// 同一个答案 —— 同一语义写两遍必出漂移（设计法则 #62）。
String effectiveSubagentMode({required String storedMode, required bool deep}) {
  if (deep && (storedMode == 'auto' || storedMode == 'main_only')) {
    return 'force_search';
  }
  return storedMode;
}

/// build146：本轮**没有外部资料**却仍要交付时，必须对用户说的那句实话。
///
/// 只在这里写一次措辞：两处调用点（检索 0 命中 / 本会话没开联网）此前各写一遍
/// 就会漂移，最后变成「一处说实话一处不说」。
String emptyEvidenceNotice({required bool isZh, required bool searchEnabled}) {
  if (!searchEnabled) {
    return isZh
        ? '未经检索：本会话未启用联网搜索，以下结论只基于模型已有知识'
        : 'Not searched: web search is off for this chat, the answer relies on model knowledge only';
  }
  return isZh
      ? '未经检索：本轮检索 0 条可用结果，以下结论只基于模型已有知识'
      : 'Not searched: this round got 0 usable results, the answer relies on model knowledge only';
}

/// build129（#107）建、build146 改：发送链路门控——**唯一**判定入口。
///
/// 旧实现是 `mode != 'main_only'`，于是**默认档 `auto` 每轮都要先付一次非流式
/// LLM 路由调用**（本文件 run 的 Step 1 else 分支，原 :162-176，30s 超时在原 :174），
/// 路由回 `target=self` 时还要再付一次合成调用（原 :340-379）才拿到正文
/// ⇒ 一次普通聊天 = 2 次 LLM 调用 + 双份首字延迟，而第二次调用才是能动手的那次。
/// 业界两种形态都不是这样：模型路由器是**专用小模型**（明确"不是 LLM"，开销可忽略、
/// 且只做选择、不加一轮生成）；agent 框架则让**主模型在自己那一轮里**决定委派
/// （显式 @ 才强制）。我们两条都不满足 ⇒ `auto` 归 ReAct：ReAct 每轮的
/// `<search>` / `<image_gen/>` 就是"能动手的那次调用自己决定"。
///
/// 现在只有 `force_search` / `force_synthesis` 走编排器（深度研究经
/// [effectiveSubagentMode] 升为 `force_search`，因此端到端仍然可用，见该函数表格）。
/// `force_plugin` 走 ReAct **不是回退**：编排器内没有插件执行引擎，
/// 原本 `target=plugin` 只能 `delegateToReact` 交回（run 的 Step 1 之后那段早返回），
/// 走编排器只是白付一次路由调用再落到同一个目的地。
bool subagentModeUsesOrchestrator(String mode, {bool deep = false}) {
  final effective = effectiveSubagentMode(storedMode: mode, deep: deep);
  return effective == 'force_search' || effective == 'force_synthesis';
}

class AgentOrchestrator {
  AgentOrchestrator(this.api, this.logger);

  final ApiService api;
  final LoggerService logger;

  /// 本次运行的 usage 回传钩子（由 run() 赋值，`_call` 与 `_callStreaming` 共用一个出口）。
  /// 编排器实例是**每轮新建**的（`chat_screen_orchestrator.dart` 里现场构造），
  /// 所以放实例上不共享状态；换成复用实例就会串台，故刻意不用静态。
  void Function(TokenUsage usage)? _onUsage;

  static const int kMaxLlmCalls = 4;

  /// 运行一次编排。若返回 null 表示编排失败（调用方可回退到 ReAct 循环）。
  ///
  /// build129（#107）：新增两个**可选**接线钩子，用于把内部进度实时透出给宿主
  /// （不传时行为与接入前逐字一致，纯新增参数、零回归）：
  /// - [onStep]：每产出一条 reasoning step 立即回调一次——宿主追加到占位气泡的
  ///   思考块，用户在多轮编排（最长 4 次 LLM 调用）期间能看到「路由 → 专家 → 合成」
  ///   的实时进度，而不是一个没有任何反馈的空等待。
  /// - [onAnswerDelta]：传入时，**最后一步合成调用改走流式**，正文边产边回调，
  ///   宿主即可像 ReAct 一样逐字上屏；不传则仍用一次性 completeChat。
  ///   专家调用（路由/搜索取证/综合）保持非流式——它们产出的是中间物，不需要上屏。
  Future<OrchestrationResult?> run({
    required ChatMessage userMsg,
    required ApiConfig cfg,
    required Conversation conversation,
    required WebSearchConfig webCfg,
    // build130：`availablePlugins` 参数**已删除** —— 插件目标整体交回 ReAct，
    // 编排器内没有任何消费方。此前它是按**显示名**（「图片生成」）组织的清单，
    // 而插件执行需要 id / tool 名 ⇒ 专家照名输出 `<plugin_call>` 无人能执行
    // （真机 2026-09-19「图片生成不了」的诱因）。留着空参数只会诱导后来者
    // 再照原样递一份 AI 调不动的清单，故一并删除（详见 `_dispatchPluginAgent` 删除处）。
    Duration timeout = const Duration(minutes: 5),
    void Function(ReasoningStep step)? onStep,
    void Function(String delta)? onAnswerDelta,

    /// build135：合成调用的 `reasoning_content` **分流**回调（与直聊路径同源，见
    /// `streamChat` 的 `onReasoning`）。此前编排路径既不开 `yieldReasoning` 也不接
    /// 这个回调 ⇒ 模型真实推理整段被丢，编排轮次的「思考过程」里只剩
    /// `[Orch] route/synthesis/final_answer` 这类内部账本行，用户体感就是
    /// 「有时没有思考过程」（ReAct 轮有、编排轮没有）。
    void Function(String delta)? onReasoning,
    // build146（第 10 轮 · 账单不许静默）：编排路径此前**零 onUsage 接线**——`_call` 不转、
    // 宿主不接，而气泡与用量统计读的都是 messages 表的 token 列
    // ⇒ 走编排的每一轮在用户账上等于"没花钱"（步数看得见、token 看不见）。
    // 判据是微软那条「响应里的 model / usage 字段不许藏」的本地版：谁发的请求，
    // 谁就必须把 usage 交回宿主，中间层不做选择性沉默。
    void Function(TokenUsage usage)? onUsage,
  }) async {
    _onUsage = onUsage;
    final isZh = conversation.title.isNotEmpty &&
        conversation.title.runes.any((r) =>
            (r >= 0x4E00 && r <= 0x9FFF) || (r >= 0x3400 && r <= 0x4DBF));
    // v1.7.37：深度研究并入思考强度——拉满（1.0）即深度研究
    final deep = ApiService.isDeepResearchEffort(conversation.reasoningEffort);
    // build146：Step 1 走**归一化后**的档位（不是库里的原值）——
    // `auto` + 深度研究在此变成 `force_search`，于是这一轮**根本不进**下面的
    // 路由 LLM 调用（原 :162-176 那段 else 分支）。
    // 与宿主门控 [subagentModeUsesOrchestrator] 调的是同一个纯函数，两边不会各判一套。
    final forceMode =
        effectiveSubagentMode(storedMode: conversation.subagentMode, deep: deep);

    final steps = <ReasoningStep>[];
    var callCount = 0;
    // build129（#107）：搜索命中数（宿主落库前必须过 sanitizeSearchHits）
    var searchHitCount = 0;
    // build129（#107）：步骤**统一出口**——本地 steps 与宿主钩子永远同源，
    // 杜绝「宿主少收一步 → 思考面板与返回值不一致」这类只在真机上才看得出的偏差。
    void emit(ReasoningStep s) {
      steps.add(s);
      onStep?.call(s);
    }

    // =========================================================================
    // Step 1: 主 Agent —— 路由
    // =========================================================================
    String target;
    String routeReason = '';
    if (forceMode == 'force_search') {
      target = 'search';
      routeReason = 'forced by user';
    } else if (forceMode == 'force_synthesis') {
      target = 'synthesis';
      routeReason = 'forced by user';
    } else if (forceMode == 'force_plugin') {
      target = 'plugin';
      routeReason = 'forced by user';
    } else {
      // build146：只剩存值为 `auto`（或脏值）才走到这条**要花钱**的路由分支。
      // 经门控进来的正常链路里 `main_only` / `force_plugin` 根本不会到这里
      // （门控把它们留在 ReAct），深度研究的 `auto` 也已被 [effectiveSubagentMode]
      // 升成 `force_search` ⇒ 会话档位只要是从库里读出来的
      // （`Conversation._sanitizeSubagentMode` 收敛到那 5 个值），
      // 这条路由调用就只在**非深度研究**的轮次发生。
      final routerPrompt = buildMainAgentPrompt(
        isZh: isZh,
        deepResearch: deep,
        stageSynthesize: false,
      );
      final routeResp = await _call(
        cfg: cfg,
        messages: [
          ChatMessage.create(
              conversationId: conversation.id,
              role: MessageRole.system,
              content: routerPrompt),
          ChatMessage.create(
              conversationId: conversation.id,
              role: MessageRole.user,
              content: userMsg.content),
        ],
        timeout: const Duration(seconds: 30),
        // build146（第 10 轮回归）：路由这一发也要能被「停止生成」打断。
        stopScope: conversation.id,
      );
      callCount++;
      final parsedRoute = parseRouteTag(routeResp);
      if (parsedRoute.reason == 'no <route> tag') {
        logger.warn(
            '[Orchestrator] no <route> tag found in route response; falling back to self. raw=${routeResp.length > 200 ? '${routeResp.substring(0, 200)}…' : routeResp}',
            tag: 'Orch');
      }
      target = parsedRoute.target;
      routeReason = parsedRoute.reason;
      // 深度研究模式强制不允许 self。
      // build146：override 的**目标**从 `synthesis` 改成 `search` ——
      // 原实现把「deep 且路由说 self」推进 Step 2 的 `target == 'synthesis'` 分支，
      // 而那个分支写死 `evidence: ''`（原 :296-316），于是一次「深度研究」
      // 实际交付的是**零取证的结构化改写**（面板里那行「无外部资料…」也压不住：
      // 正文照样以研究成果的样子落地）。研究就得先拿证据，故改指检索链。
      if (deep && target == 'self') {
        target = 'search';
        routeReason += ' [deep-research override]';
      }
      logger.info(
          '[Orchestrator] route → target=$target reason=$routeReason (deep=$deep, force=$forceMode)',
          tag: 'Orch');
    }
    // build129（#107）：route 步骤移出 else 分支——强制档（force_search /
    // force_synthesis / force_plugin）此前**一条 route 步骤都不产**，思考面板
    // 看不到"被强制路由到哪个专家"，用户以为编排没跑。现在三档同样可见
    // （reason='forced by user'）。
    // build132：面板文案人话化——此前原样输出 `target=self reason=…` 这种**内部标记**，
    // 真机导出的「思考过程」三行全是标记（编排中 / target=… / chars=240），
    // 用户体感就是「没有思考过程」。现在把判断讲成人话，`target=` 仍留在括号里，
    // 便于日后从面板导出定位问题（机器可读的日志行 [Orchestrator] route → … 不变）。
    final reasonText = routeReason == 'forced by user'
        ? (isZh ? '用户强制指定该档位' : 'forced by user')
        : routeReason;
    emit(ReasoningStep(
      'route',
      isZh
          ? '路由判断：$reasonText（target=$target）'
          : 'Routing: $reasonText (target=$target)',
      phase: 'route',
      round: 1,
    ));

    // build130：**插件目标 = 交回 ReAct**（真机回归修复，见 [delegateToReact] 注释）。
    // 放在 Step 2 之前：既省掉两次注定无效的 LLM 调用，也杜绝「专家吐出
    // `<plugin_call>` 文本 → 合成把它当散文 → 用户以为生成失败」的假完成。
    // 这里**只保留 route 步骤**（思考面板照旧可见「被路由到插件」），
    // 宿主收到信号后静默交回 ReAct，由后者真正执行 `<image_gen/>` 等动作。
    if (target == 'plugin') {
      logger.info(
          '[Orchestrator] target=plugin → delegate to ReAct (orchestrator has no plugin executor)',
          tag: 'Orch');
      return OrchestrationResult(
        answer: '',
        reasoningSteps: steps,
        llmCallCount: callCount,
        searchHitCount: searchHitCount,
        delegateToReact: true,
        target: target,
      );
    }

    // =========================================================================
    // Step 2: 分派专家
    // =========================================================================
    final expertOutputs = <String, String>{};
    // build146（取证闸）：本轮**真实**拿到的外部资料。空串 = 没拿到
    // （注意不能拿 `joined` 当判据——`_formatSearchResults` 在 0 命中时返回的是
    // 「（无搜索结果）」这个非空串，用它判等于永远判不出"没证据"）。
    var evidence = '';
    // build146：`target == 'synthesis'` 的档位语义是"以分析为主"，**不等于"不许有证据"**。
    // 空取证的综合 = 把用户的话换个说法重排一遍却挂着"研究成果"的样子交付，
    // 这正是本项目反复修的"假完成"族。所以联网可用时**先补取证再综合**
    // （复用下面同一条检索链，不另写一份，见 #62）；联网不可用时才允许无证据综合，
    // 且必须用 [emptyEvidenceNotice] 把"没查"这件事在步骤里说出口。
    final runSearchExpert = shouldRunSearchExpert(
      target: target,
      webSearchEnabled: webCfg.webSearchEnabled,
    );

    if (target == 'self') {
      // 主 Agent 自己答（跳过专家），走合成阶段。
      // build132：此处**刻意不产额外步骤**——route 步骤已人话化为
      // 「路由判断：<原因>（target=self）」，再补一条「无需检索/专家」纯属复述；
      // 保持 self 流程 = [route, final_answer] 也让既有契约测试
      // （agent_orchestrator_run_test 断言该序列）继续成立。
    }
    if (runSearchExpert) {
      if (callCount >= kMaxLlmCalls) return null;
      if (target == 'synthesis') {
        emit(ReasoningStep(
          'route',
          isZh
              ? '合成前先补取证：本轮没有资料可综合，改走检索链（target=synthesis→search）'
              : 'Fetching evidence before synthesis: nothing to synthesize, switching to search (target=synthesis→search)',
          phase: 'route',
          round: 1,
        ));
      }
      final queries = await _dispatchSearchAgent(
        cfg: cfg,
        conversation: conversation,
        userText: userMsg.content,
        isZh: isZh,
      );
      callCount++;
      emit(ReasoningStep(
        'search_queries',
        isZh
            ? '检索词 ${queries.length} 条：${queries.join(' ｜ ')}'
            : 'Queries (${queries.length}): ${queries.join(' | ')}',
        phase: 'expert',
        round: 1,
      ));
      // 执行实际网络搜索
      final searchResults = await _executeSearch(queries, webCfg);
      final joined = _formatSearchResults(searchResults);
      // 注入用的文本照旧（0 命中时是「（无搜索结果）」，模型据此知道该承认没查到），
      // 但"有没有证据"另用 [evidence] 判——两者语义不同，不能合成一个值。
      expertOutputs['search'] = joined;
      // build129（#107）：命中数回传宿主（气泡「已联网注入 N 条」徽标用）
      searchHitCount = searchResults.length;
      evidence = searchResults.isEmpty ? '' : joined;
      emit(ReasoningStep(
        'search_results',
        isZh
            ? '检索命中 ${searchResults.length} 条，注入 ${joined.length} 字资料'
            : '${searchResults.length} hits, ${joined.length} chars injected',
        phase: 'expert',
        round: 1,
      ));

      // 资料足够才值得再花一次分析调用：0 命中时综合专家只能凭空改写（build146 的
      // 取证闸），跳过它既省钱也不谎称"已综合资料"。
      if ((deep || target == 'synthesis') &&
          evidence.isNotEmpty &&
          callCount < kMaxLlmCalls) {
        final synText = await _dispatchSynthesisAgent(
          cfg: cfg,
          conversation: conversation,
          userText: userMsg.content,
          evidence: evidence,
          isZh: isZh,
        );
        callCount++;
        expertOutputs['synthesis'] = synText;
        emit(ReasoningStep(
          'synthesis',
          isZh
              ? '资料已综合成 ${synText.length} 字的分析'
              : 'Synthesized ${synText.length} chars',
          phase: 'expert',
          round: 2,
        ));
      }
      if (evidence.isEmpty) {
        emit(ReasoningStep(
          'unresearched',
          emptyEvidenceNotice(isZh: isZh, searchEnabled: webCfg.webSearchEnabled),
          phase: 'expert',
          round: 2,
        ));
      }
    } else if (target == 'synthesis') {
      // 到这里只剩一种情形：合成档但**本会话没启用联网搜索** ⇒ 无证据可综合。
      // 仍交付（模型已有知识做结构化分析是真有用的），但先把"没查"写进步骤：
      // build146 的口径是"要么先检索，要么在面板里明说未经检索"，二选一，不许含糊。
      if (callCount >= kMaxLlmCalls) return null;
      emit(ReasoningStep(
        'unresearched',
        emptyEvidenceNotice(isZh: isZh, searchEnabled: webCfg.webSearchEnabled),
        phase: 'expert',
        round: 1,
      ));
      final synText = await _dispatchSynthesisAgent(
        cfg: cfg,
        conversation: conversation,
        userText: userMsg.content,
        evidence: '',
        isZh: isZh,
      );
      callCount++;
      expertOutputs['synthesis'] = synText;
      emit(ReasoningStep(
        'synthesis',
        isZh
            ? '基于已有知识完成 ${synText.length} 字的结构化分析（本轮未经检索）'
            : 'Structured analysis (${synText.length} chars, not searched)',
        phase: 'expert',
        round: 1,
      ));
    }
    // build130：`target == 'plugin'` 分支**已删** —— 它在 Step 1 之后就被
    // 交回 ReAct（见上方 delegateToReact 早返回）。保留一个"永远不会执行到"
    // 的插件专家分支只会让人以为编排器能执行插件（这正是本次真机回归的成因）。

    // =========================================================================
    // Step 3: 主 Agent —— 合成最终回答
    // =========================================================================
    if (callCount >= kMaxLlmCalls) {
      logger.warn(
          '[Orchestrator] LLM call limit reached before synthesis; using expert output as fallback',
          tag: 'Orch');
      final fallback = expertOutputs.values.join('\n\n').isEmpty
          ? '（编排未产出最终回答）'
          : expertOutputs.values.join('\n\n');
      return OrchestrationResult(
        answer: fallback,
        reasoningSteps: steps,
        llmCallCount: callCount,
        searchHitCount: searchHitCount,
        target: target,
      );
    }

    final synthPrompt = buildMainAgentPrompt(
      isZh: isZh,
      deepResearch: deep,
      stageSynthesize: true,
    );
    final expertBlock = expertOutputs.entries.map((e) {
      return '=== ${e.key.toUpperCase()} 专家输出 ===\n${e.value}';
    }).join('\n\n');

    // build129（#107）：合成请求体只构造一次——流式/非流式两条路共用同一 payload，
    // 避免日后只改一条路导致「流式与非流式的提示词悄悄漂移」。
    final synthMessages = [
      ChatMessage.create(
          conversationId: conversation.id,
          role: MessageRole.system,
          content: synthPrompt),
      ChatMessage.create(
          conversationId: conversation.id,
          role: MessageRole.user,
          content: '用户问题：${userMsg.content}\n\n$expertBlock'),
    ];

    // build129（#107）：传入 onAnswerDelta 时最后一步合成改走流式（正文边产边上屏，
    // 且带 stopScope 可被「停止生成」打断）；未传则保持一次性 completeChat，
    // 与接入前逐字一致。
    final synthResp = onAnswerDelta == null
        ? await _call(
            cfg: cfg,
            messages: synthMessages,
            timeout: timeout,
            // build146（第 10 轮回归）：一次性合成的那一发同样要能被「停止生成」打断
            // —— 传 onAnswerDelta 的流式分支早就带了 stopScope，只有这一支漏了，
            // 于是"同一个语义两处口径"又出现一次（用户点停止后仍会跑完一次 90s 调用）。
            stopScope: conversation.id,
          )
        : await _callStreaming(
            cfg: cfg,
            messages: synthMessages,
            timeout: timeout,
            stopScope: conversation.id,
            onDelta: onAnswerDelta,
            onReasoning: onReasoning,
          );
    callCount++;
    emit(ReasoningStep(
      'final_answer',
      isZh
          ? '已生成回答（${synthResp.length} 字）'
          : 'Answer generated (${synthResp.length} chars)',
      phase: 'synthesize',
      round: steps.length ~/ 2 + 1,
    ));

    final answer = stripAnswerTag(synthResp);
    return OrchestrationResult(
      answer: answer,
      reasoningSteps: steps,
      llmCallCount: callCount,
      searchHitCount: searchHitCount,
      target: target,
    );
  }

  // ===========================================================================
  // LLM 调用薄封装（temperature=0.1，reasoningEffort=low 便于快速决策）
  // ===========================================================================
  Future<String> _call({
    required ApiConfig cfg,
    required List<ChatMessage> messages,
    required Duration timeout,
    // build146（第 10 轮回归）：**每一步都必须带 stopScope**。
    // 原来这里什么都不传 ⇒ `completeChat` 注册的是"无归属"的 stopFlag，
    // 用户点「停止生成」（按 conversation.id 作用域停）根本打不到编排器的中间调用：
    // 路由/取证/综合这几步会一路跑完，`timeout` 又是 30s~90s，
    // 表现就是"点了停止还在转、还继续烧 token"。流式那支（[_callStreaming]）
    // 早就传了，非流式这一支是漏的 —— 同一个语义两处口径。
    required String stopScope,
  }) async {
    return api.completeChat(
      config: cfg,
      messages: messages,
      reasoningEffort: 'low',
      timeout: timeout,
      stopScope: stopScope,
      onUsage: _onUsage,
    );
  }

  /// build129（#107）：非流式 [_call] 的流式孪生——只用于**最后一步合成**。
  ///
  /// 取正文的方式与直聊/续写路径同源：`streamChat` 默认 `yieldReasoning: false`
  /// 时，流里 yield 出来的就是正文 chunk（不再依赖 `onContent` 回调，避免
  /// 「有的供应商不回调 onContent → 答案整段丢失」这类只在某家 API 上出现的坑）。
  /// 返回值为累积全文，语义与 [completeChat] 的返回值一致，因此后续
  /// `stripAnswerTag` 等处理对两条路完全通用。
  Future<String> _callStreaming({
    required ApiConfig cfg,
    required List<ChatMessage> messages,
    required Duration timeout,
    required String stopScope,
    required void Function(String delta) onDelta,
    void Function(String delta)? onReasoning,
  }) async {
    final buf = StringBuffer();
    // 注：timeout 由 streamChat 内部按分块空闲判定，这里不需要额外包一层
    // （包了反而会把「模型思考时长」算进总超时，长回答被误杀）。
    final stream = api.streamChat(
      config: cfg,
      messages: messages,
      reasoningEffort: 'low',
      stopScope: stopScope,
      // build135：与直聊路径同源——`onReasoning` 与 `yieldReasoning` 在 streamChat
      // 里是**相互独立**的两条出口（api_service.dart:859-861），因此这里保持
      // yieldReasoning=false（推理文本不会混进正文流），只把它分流给思考面板。
      onReasoning: onReasoning,
      onUsage: _onUsage,
    );
    await for (final delta in stream) {
      if (delta.isEmpty) continue;
      buf.write(delta);
      onDelta(delta);
    }
    return buf.toString();
  }

  // ===========================================================================
  // 解析工具
  // ===========================================================================

  // 解析逻辑已抽到 lib/services/agent_parser.dart（纯函数，可单测）

  // ===========================================================================
  // 专家分派（每个专家 = 一次独立 LLM 调用）
  // ===========================================================================
  Future<List<String>> _dispatchSearchAgent({
    required ApiConfig cfg,
    required Conversation conversation,
    required String userText,
    required bool isZh,
  }) async {
    final prompt = buildSearchAgentPrompt(isZh: isZh);
    final resp = await _call(
      cfg: cfg,
      messages: [
        ChatMessage.create(
            conversationId: conversation.id,
            role: MessageRole.system,
            content: prompt),
        ChatMessage.create(
            conversationId: conversation.id,
            role: MessageRole.user,
            content: userText),
      ],
      timeout: const Duration(seconds: 40),
      stopScope: conversation.id,
    );
    final queries = extractQueries(resp);
    // 保底：一条都没有时至少用原文
    if (queries.isEmpty) return [userText];
    return queries;
  }

  Future<String> _dispatchSynthesisAgent({
    required ApiConfig cfg,
    required Conversation conversation,
    required String userText,
    required String evidence,
    required bool isZh,
  }) async {
    final prompt = buildSynthesisAgentPrompt(isZh: isZh);
    final evidenceBlock = evidence.isEmpty ? '（无外部证据，仅基于你已有的知识）' : evidence;
    final resp = await _call(
      cfg: cfg,
      messages: [
        ChatMessage.create(
            conversationId: conversation.id,
            role: MessageRole.system,
            content: prompt),
        ChatMessage.create(
            conversationId: conversation.id,
            role: MessageRole.user,
            content: '用户问题：$userText\n\n已收集证据：\n$evidenceBlock'),
      ],
      timeout: const Duration(minutes: 3),
      stopScope: conversation.id,
    );
    return extractSynthesis(resp);
  }

  // build130：`_dispatchPluginAgent` 已删除。
  //
  // 它产出的 `<plugin_call name="…">` 文本**没有任何执行点**（编排器不是插件
  // 执行器），此前却被当作"插件专家"接进发送链路，真机上表现为「说要生成图、
  // 图不出来」。插件的执行权归 ReAct 循环：`target == 'plugin'` 现在直接
  // 返回 `delegateToReact`（见 run 的 Step 1 之后）。
  // 提示词构造器 `buildPluginAgentPrompt` 仍保留在 lib/prompts/agent_prompts.dart，
  // 供回归测试服务（regression_test_service.dart）做提示词自检使用。

  // ===========================================================================
  // 实际网络搜索（复用现有 WebSearchService）
  // ===========================================================================
  /// build132：改为「首条串行 + 其余并发」两段式，**成本闸不变**。
  ///
  /// 为什么不做「3 条无条件并发」：单条查询请求的条数由 `tavilyMaxResults`
  /// （clamp 3~10）决定，而 `maxResultsInject` 默认只有 5 ⇒ 首条查询通常就已填满，
  /// 旧实现 `take(3)` 的后两条在多数轮次**根本不会执行**；无条件并发等于给常见
  /// 路径白加 2 次搜索（配额 + 延迟），注入量却一样。
  /// 所以只在**确实不够量**时才并发跑剩余查询（最坏 2 次串行 → 1 次并发），
  /// 合并规则（按查询顺序 / URL 去重 / 截断）抽成纯函数 [mergeSearchResults] 以便单测。
  Future<List<SearchResultItem>> _executeSearch(
      List<String> queries, WebSearchConfig cfg) async {
    if (!cfg.webSearchEnabled || queries.isEmpty) return [];
    final wanted = queries.take(3).toList();
    final cap = cfg.maxResultsInject.clamp(1, 10);
    final batches = <List<SearchResultItem>>[];
    try {
      // 第 1 条：串行——它通常就够量，够量即不再多搜（沿用旧的早退语义）
      batches.add(await _searchOne(wanted.first, cfg));
      if (mergeSearchResults(batches, cap).length < cap && wanted.length > 1) {
        // 不够量：剩余查询**并发**跑（每条独立兜底，互不拖累）
        batches.addAll(
            await Future.wait(wanted.skip(1).map((q) => _searchOne(q, cfg))));
      }
    } catch (e) {
      logger.warn('[Orchestrator] web search failed: $e', tag: 'Orch');
    }
    final merged = mergeSearchResults(batches, cap);
    if (merged.isEmpty) {
      // G36 日志说真话：0 条与「没搜」不是一回事，宿主徽标会按命中数显示
      logger.warn(
          '[Orchestrator] web search produced 0 usable results (queries=${wanted.length})',
          tag: 'Orch');
    }
    return merged;
  }

  /// 单条查询的搜索，**独立兜底**：单条失败只丢它自己，不拖累同批其它查询。
  ///
  /// （旧实现是整段 try/catch 包住串行循环 ⇒ 首条抛错会连后两条一起跳过。）
  Future<List<SearchResultItem>> _searchOne(
      String q, WebSearchConfig cfg) async {
    try {
      return await WebSearchService.searchGeneral(q, cfg);
    } catch (e) {
      logger.warn('[Orchestrator] web search failed for "$q": $e', tag: 'Orch');
      return const <SearchResultItem>[];
    }
  }

  String _formatSearchResults(List<SearchResultItem> items) {
    if (items.isEmpty) return '（无搜索结果）';
    final sb = StringBuffer();
    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      sb.writeln('[${i + 1}] ${it.title}');
      sb.writeln('URL: ${it.url}');
      sb.writeln('摘要: ${it.snippet}');
      sb.writeln();
    }
    return sb.toString().trim();
  }
}

// =============================================================================
// build132：检索结果合并（顶层纯函数，便于单测）
// =============================================================================

/// 合并多批检索结果：**按批次（＝查询）顺序**、URL 去重、截断到 [maxItems]。
///
/// 提成顶层纯函数的原因：并发合并只在真机上才看得见，纯逻辑必须能进单测
/// （契约测试只能证明「写了 Future.wait」，证明不了合并规则对）。
///
/// - `url` 为空的结果**不参与去重**（无 URL 的条目一律保留，避免被空串误判成重复）；
/// - [maxItems] ≤ 0 视为不截断（调用方已 clamp 到 1~10，此处只作兜底）。
List<SearchResultItem> mergeSearchResults(
    List<List<SearchResultItem>> batches, int maxItems) {
  final out = <SearchResultItem>[];
  final seen = <String>{};
  for (final batch in batches) {
    for (final item in batch) {
      if (item.url.isNotEmpty && !seen.add(item.url)) continue;
      out.add(item);
      if (maxItems > 0 && out.length >= maxItems) return out;
    }
  }
  return out;
}
