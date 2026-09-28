// part 文件通过 extension 访问宿主 _ChatScreenState 的受保护成员 setState，
// 属 part-of + extension 拆分架构的固有模式，统一豁免。
// ignore_for_file: invalid_use_of_protected_member, library_private_types_in_public_api
part of 'chat_screen.dart';

extension ChatScreenReActExt on _ChatScreenState {
  /// v1.7.34：跨对话记忆——每次保存 assistant 消息后触发（不 await，静默后台）
  void _triggerMemorySummaryIfDue() {
    unawaited(ConversationSummaryService.instance
        .maybeRegenerate(conversationId: widget.conversation.id));
  }

  Future<void> _runReActLoop(
    ChatMessage userMsg,
    ApiService apiSvc,
    StorageService storage,
  ) async {
    // v1.7.24：行为指纹兜底 —— 连续 3 轮 thinking 内容指纹相同 → 立即注入自检（不等 20 秒定时器）
    // 场景：AI 原地复读（每轮输出一模一样的 thinking）时空转，20 秒定时器还没触发；指纹检测提前打断。
    String? loopLastThinkingFp;
    int loopRepeatThinkingCount = 0;
    // O9（build96）：零产出空转守卫——连续 N 轮无 answer 无主动作（search/mcp 等）
    // → 第 3 轮注入强约束、第 4 轮仍零产出则强制收尾（与「完全相同指纹」检测互补）。
    int zeroOutputStreak = 0;
    // G39（build129）：**连续无结论轮**收敛——与 O9 互补的第二条闸门。
    // O9 只在「既无 answer 又无动作」时计数，而真机病灶（09-19 10:05 导出日志）
    // 恰恰是**连着检索**（每轮都有 toolresult ⇒ O9 永远 streak=1）却始终不给结论，
    // 一路空转到 maxRounds 由用户手动停止。判定与文案见 react_parser 的 G39 段。
    int inconclusiveStreak = 0;
    // build164（#82）：阶段小结（<progress>）的序号，跨轮累加、每条消息一套，
    // 只为日志形状 `[ReAct] 阶段小结 #N：<原文>`（用户要求能在日志里数出第几条）。
    int progressNoteSeq = 0;
    // build164（#82）：G39 计数期间每轮的最后一个动作，攒着给放弃文案**按事实说话**
    // （旧文案写「① 中转站返回空流 / 502」，用户用的是官方端点，被他原话顶回来：
    //  「我用的是官方的，不是中转站的」）。streak 清零时本列表一并清零，保证
    // 文案里报的就是"最近这一段连续空转"。
    final inconclusiveActions = <String>[];
    // build164（#82 取证 ③，顺带补 #84 留的接线位）：本条消息里是否出现过
    // 「被 maxTokens 打满而收口」这一事实。三态刻意保留：
    //  - null = 一条流都没收完过（连接阶段就失败），该说"未知"就说未知；
    //  - false = 收完过且没打满；true = 至少有一轮是被长度上限截断收的口。
    // 耗时画像那行（round_timing 的 `maxTokens 打满：…`）此前在这条路径上恒报
    // 「未知（该路径未告知）」——用户看到的"老是中断"在日志里就是没有凭据的那一格。
    bool? sawMaxTokensTruncation;
    // v1.7.26：流式 answer 过滤跨 chunk 状态（[0]=是否处于 <answer> 块内）
    final ansState = <bool>[false];
    // v1.7.29：跨 chunk 未闭合标签缓冲（流式把 <thinking> 切成 <thin|king> 时暂存，下 chunk 拼接后再剥）
    final pendingTag = <String>[''];
    // v1.7.37：答案流式缓冲——<answer> 块内容边流边写入答案气泡
    final answerStreamBuf = StringBuffer();
    var lastAnswerStreamLen = 0;
    // A1（W6）：本轮是否已见 <ask_user>（跨 chunk 状态，流式阶段拦答案写入）。
    // 规则：一轮出现 ask_user 即为提问轮，本轮不落地任何最终答案。
    final askUserSeenState = <bool>[false];
    // build162（核 161 留下的那条疑点，结论：**成立**）：当轮"已收但还没落进气泡"的
    // 那半截正文只活在 while 作用域里的流缓冲（`typedAnswerBuf` :604 /
    // `answerStreamBuf` :35）—— `rawResp`（:799）与回写 `workingMessages`（:884）
    // 都要等这一轮的流**正常结束**才发生，而气泡那一句还受 300ms/500 字节节流
    // （:757）。中途被对端掐掉时下面那两处取值（`assistantMsg.content` +
    // `_lastRoundAssistantContent`）可以双双为空 ⇒ "有半截答案可续"被误判成
    // "0 字没有落点"。这里放一个**取值口**，在每次尝试开始时接一次（不是每个 chunk，
    // 流式期间零分配），外层 catch 才够得着 while 作用域。
    String Function() partialRoundAnswer = () => '';
    // build167（用户 26 日 18:4x 那条反馈带出的 164 老洞）：**思考落点**的同款取值口。
    // 「本轮有没有可续的内容」以前只认正文（`hasReceivedContent` 一族），纯 thinking 的轮
    // 一旦断了就塌成报错；总闸（`lib/utils/background_run_switch.dart`）开着不再掐线之后，
    // 这条会以更难看的形状出现 ⇒ 判据改成"正文**或**思考落点"，成本口径是
    // "最坏多付一轮 token"（他 164 就认过）。判据住在 `drop_continue.dart`，
    // 这里只把"流里到底收到过多少 reasoning"交出去 —— 取值口与上面那条同一配方
    // （每次尝试接一次，不是每个 chunk，流式期间零分配）。
    // 旧链（`kUseTypedKernel == false`）**交回空串**：那条路上 rawBuf 把 thinking 与
    // answer 混在一条流里，拿它当"思考落点"会把答案残片算成思考 ⇒ 那种轮次退回
    // "只认正文"的 166 行为（该模式在生产上恒不成立，见 constants.dart:27）。
    String Function() partialRoundThinking = () => '';
    // A1：最后一次执行的轮次是否为提问轮（maxRounds 兜底不得把被压制的
    // answer 重新捞回来当结论）。TODO(R4): 随状态机删除。
    var lastRoundWasAskUser = false;
    // O7（build98）：流式净化节流状态
    var lastAnswerSanitizeAt = DateTime.fromMillisecondsSinceEpoch(0);
    var lastAnswerSanitizeLen = 0;

    final l = AppLocalizations.of(context);
    final isZh = l.locale.languageCode == 'zh';
    // v1.7.25：思考程度/强度改为每对话独有 → 从 conversation 读取
    final isAuto = widget.conversation.reactAutoMode;
    // v1.7.37：深度研究并入思考强度——拉满（1.0）即深度研究（80 轮 / MCP 32 / 深研提示词）
    final registry = context.read<PluginRegistry>();
    final deepResearchOn =
        ApiService.isDeepResearchEffort(widget.conversation.reasoningEffort);
    // 思考强度 > 0 时覆盖 ReAct 最大轮数（0.1→3 轮 … 0.9→11 轮，1.0=深度档→80 轮）
    var maxRounds = widget.conversation.reactMaxRounds;
    final effortRounds =
        ApiService.reasoningRoundsForValue(widget.conversation.reasoningEffort);
    if (effortRounds > 0) maxRounds = effortRounds;
    final effort = ApiService.reasoningEffortForConversation(
        widget.conversation,
        inReAct: true);

    // v1.7.9 (M7 修复)：循环内多轮 await 之后不能再 context.read（页面退出后
    // 会抛 "deactivated widget's ancestor" 崩溃）—— 方法入口一次性缓存服务引用
    final dlSvc = context.read<AppDownloadService>();

    // v1.6.9：PluginRegistry 决定哪些插件能 dispatch，哪些插件的协议能进 prompt。
    //   - 禁用的插件 → registry.dispatch 跳过（不触发功能）
    //   - 禁用的插件 → promptProtocol 也不拼给 AI（AI 根本看不到协议，自然不会输出对应标签）
    final enabledPlugins = registry.plugins
        .where((p) => registry.isEnabled(p.metadata.id))
        .toList(growable: false);
    // build98：提示词插件依赖检测——kPromptPluginMcpDeps 声明了依赖 MCP host
    // 的纯提示词插件，依赖未安装时不注入提示词（防 AI 有规则没工具）。
    final installedMcpHosts = enabledPlugins
        .where((p) => p.metadata.kind.isRemote)
        .map((p) =>
            Uri.tryParse(p.metadata.extra['endpoint']?.toString() ?? '')
                ?.host ??
            '')
        .where((h) => h.isNotEmpty)
        .toSet();
    final effectivePlugins = enabledPlugins
        .where((p) =>
            kPromptPluginMcpDeps[p.metadata.id] == null ||
            installedMcpHosts.contains(kPromptPluginMcpDeps[p.metadata.id]))
        .toList(growable: false);
    if (effectivePlugins.length != enabledPlugins.length) {
      _logger.info(
          '[ReAct] build98 dep-gate: skipped ${enabledPlugins.length - effectivePlugins.length} prompt plugin(s) with missing MCP dep',
          cat: LogCat.react,
          tag: 'ReAct');
    }
    // 阶段1(T2/T4)：工具 Schema 化——内置 6 工具 + 启用的 MCP 远程工具
    //（按 6000 字符预算拼入）。模型不支持 tools 时由 T7 自动降级回标签协议。
    // N10：MCP 工具名注册表按本循环局部持有，多会话并发互不串名。
    final mcpToolRegistry = <String, (String, String)>{};
    final agentTools = buildAgentTools(
      registry: mcpToolRegistry,
      mcpPlugins: enabledPlugins
          .where((p) => p.metadata.kind.isRemote)
          .map((p) => (
                pluginId: p.metadata.id,
                tools: p.metadata.extra['tools'] is List
                    ? (p.metadata.extra['tools'] as List)
                        .whereType<Map>()
                        .map(Map<String, dynamic>.from)
                        .toList()
                    : <Map<String, dynamic>>[],
              ))
          .toList(),
    );
    final hasDownloadPlugin =
        enabledPlugins.any((p) => p.triggerType == 'download');

    // N6（build94）：MCP 同 (pluginId, tool) 熔断计数按「一条用户消息」为界，
    // 每次进入 ReAct 循环（= 处理新用户消息）清零。
    registry.resetMcpCircuit();

    // v1.7.31：缓存思考过程日志开关（避免每轮都读 SharedPreferences）
    final logThinking = (await SharedPreferences.getInstance())
            .getBool('log_thinking_process') ??
        false;

    _logger.info(
      '[ReAct] Entering loop, STREAMING mode, auto=$isAuto, maxRounds=$maxRounds, effort=$effort, enabledPlugins=${enabledPlugins.map((p) => p.triggerType).join(',')}',
      cat: LogCat.react,
      tag: 'ReAct',
    );

    // build142（灵动岛）：长轮上岛。刻意挂在「进循环之前」而不是 for 里 ——
    // 进不了循环（提前 return / 抛错）时不该留下一条假的「进行中」；结束统一在 finally 摘。
    // build150：这一行是"本轮到底怎么结束的"的**唯一对外口径**（成功留「· 已完成」、
    // 失败留「· 失败 + 原因」），所以收尾要能区分成功/真崩溃/用户停止三种出口 ——
    // `reactLoopError` 就是给 finally 用的那一个标记，别拿它当第二份错误日志。
    //
    // build161（真机反馈「那个灵动岛他不是一瞬间就出来的…它是过几秒钟之后才有的」）：
    // **这里已经不是"第一次上岛"的地方了** —— 岛上那一行早在 `_sendMessage` 入口、
    // 任何 await 之前就由 `SendIslandRow.register()` 登记好（按下发送的那一帧就有
    // 「已发送 · 正在准备」）。这次调用留在原地只做一件事：把文案换成本轮真实的轮数。
    // 留原处、不改名、不挪位置的理由都核过（`live_task_wiring.dart` 的 `onResearchStart`
    // 注释里是同一条）：
    //  · 同一 id 重复 start = `LiveTaskCenter.upsert` 覆盖 ⇒ **只有一行**，不会挂出第二行；
    //  · `startedAt` 不重置（`_trackDeadlines` 明写「同 id 再次 upsert 不重置 startedAt」）
    //    ⇒ build156 那条时限仍从第一次登记算起，中途再 start 一次不给它续命；
    //  · `onResearchUpdate` 本来就是 `onResearchStart` 的别名，换名字不改变任何行为，
    //    而这一行前面还压着 SharedPreferences 与插件枚举 —— 轮数文案必须等它们算得出。
    Object? reactLoopError;
    // build161 ①：本轮的发送路径快照 —— 循环入口时 `_sendSeq` 就是本轮号；
    // 掉线决策若发现它变了，说明用户已用新一轮接管，自动续写作废（判据现成，
    // 不新造标志）。
    final int dropRoundSeq = _sendSeq;
    // 本次掉线被纯函数判成"可以自动续一轮"：气泡不挂掉线文案、岛上不写 ✗，
    // 由 `_runDropContinueRound` 接手（判据见 lib/utils/drop_continue.dart）。
    var dropArmed = false;
    // build162：**什么时候起**由这台时机状态机给（[DropContinuePlan]），
    // "该不该续"仍是上面那个 `decideDropContinue` 说了算。前台 ⇒ `startNow`
    // （161 的行为，一字未改）；后台 ⇒ `pendUntilForeground`，由
    // `_onAppResumedForDropContinue` 在回到前台那一刻兑现。
    var dropPlan = DropContinuePlan.giveUpWithButton;
    // 决策时认定的"已收到什么"——回填气泡与失败收尾共用，不再各扫一遍。
    var dropReceived = '';
    // build165 ①：本轮是不是"因离开 App 被本端收起"（`endKind` 的镜像，
    // 只给 finally 那次岛的收尾分出口用 —— 判据仍然只住 `drop_continue.dart` 那一份，
    // 这里只是把它已经给过的结论带过 await，不重算第二遍）。
    var bgAborted = false;
    // build167：攒下那一笔**能不能接断点**（判据 = `dropContinueEntryKindForDropped`，
    // 与气泡上那枚按钮同源）。false = 有正文，从断点往下接；true = 一个字正文都没有
    // （只有思考落点，或被本端收起的那一笔），发生的是整轮重发 ⇒ 岛上的话必须写
    // 「重新发起这一轮」，写「接着写」就是用户 165 那句「回去之后他又重新开始搞」。
    // 这里只是把判据已经给过的结论带过 await 给 finally 用，不重算第二遍。
    var dropWholeRound = false;
    unawaited(LiveTaskWiring.onResearchStart(userMsg.id, '准备中 · 上限 $maxRounds 轮',
        deep: deepResearchOn));

    // v1.6.9：按用户要求"分成两半"——启动的插件拼 promptProtocol（启动版），
    // 禁用的插件完全不拼（不启动版）。市场安装的新插件 register 时顺序在 system 之后，自然追加。
    // v1.7.17：传 hint 走目录层+格式层（详情按需加载）。
    final hint = _pluginHintConfig;
    final reactProtocolPrompt =
        buildReactSystemPromptFromPlugins(effectivePlugins, hint: hint);
    // v1.7.17：🔌 用户附加提示由 _pluginHintConfig.extraHints 驱动。
    final pluginHintBlock = hint.extraHints.isNotEmpty
        ? '\n\n=== 用户附加提示 ===\n${hint.extraHints.join('\n')}'
        : '';
    // 构造一个"临时 system 消息"：给 AI 注入 ReAct 协议（不落库，只在本循环内存中用）
    // v1.7.34：跨对话记忆——如果开启，拼最近几条对话摘要进 system prompt
    String memoryBlock = '';
    if (widget.conversation.memoryEnabled) {
      try {
        final summaries = await storage.getRecentSummaries(3,
            excludeId: widget.conversation.id);
        if (summaries.isNotEmpty) {
          final sb = StringBuffer();
          sb.writeln(isZh
              ? '【跨对话记忆 · 最近对话摘要】'
              : '[Cross-chat memory · Recent conversation summaries]');
          for (final s in summaries) {
            final title = (s['title'] as String?) ?? '';
            final sum = (s['summary'] as String?) ?? '';
            sb.writeln('- $title: $sum');
          }
          memoryBlock = sb.toString().trim();
        }
      } catch (_) {
        // 静默失败，不影响主流程
      }
    }
    // v1.7.38 build90（⑧）：全局/项目记忆并入 system 前缀末尾
    // build94 (D3)：受 longTermMemoryEnabled 独立开关控制（与跨对话摘要拆分）
    final memBlockText = widget.conversation.longTermMemoryEnabled
        ? await MemoryBlockBuilder.build(
            widget.conversation.projectId,
            isZh: isZh)
        : '';
    if (memBlockText.isNotEmpty) {
      memoryBlock =
          memoryBlock.isEmpty ? memBlockText : '$memoryBlock\n\n$memBlockText';
    }
    // build93(M5)：跨对话摘要部分在循环内不变，缓存基底用于记忆块重建
    final memSummariesBlock = memoryBlock.endsWith(memBlockText) &&
            memBlockText.isNotEmpty
        ? memoryBlock.substring(0, memoryBlock.length - memBlockText.length).trim()
        : memoryBlock;
    var memDirty = false;
    var memoryWriteDone = false; // build93(M3)：本条消息是否真实落库过记忆
    // build146（prompt cache ③）：ReAct 的 system 前缀不再揉成**一条** reactSystemMsg——
    // 拆成按档位分块的文本（协议骨架 / 插件目录 / 深研协议 / 长期记忆 / 跨对话摘要各一块），
    // 由每轮的 planPromptPrefix 决定拼装顺序（见 utils/prompt_prefix.dart）。收益：
    // memDirty 中途重建只改写 longTermMemoryText 这一块，协议/目录/摘要三块字节不动，
    // 前缀缓存不会被一次记忆写入整段刷掉。旧写法（整段拼接 + 越靠近用户权重越高）留档：
    // '$reactProtocolPrompt$pluginHintBlock' + 深研 + memoryBlock —— 现交给分块 + planPromptPrefix。
    final crossChatSummaryText = memSummariesBlock; // 循环内不变（跨对话摘要）
    final deepResearchProtocolText =
        deepResearchOn ? kDeepResearchProtocol : ''; // 会话级开关，循环内不变
    var longTermMemoryText = memBlockText; // 唯一可中途改写的稳定块（见 memDirty 分支）

    // 用于发给 API 的消息列表（系统 prompt + 历史 + user + 每轮 toolresult）
    // 注意：assistant 的 <thinking>/<search> 直接当 assistant 消息发回去（原始完整文本）
    // v1.7.17：重置本循环的 detail 去重集合（同一循环内跨轮去重）。
    _injectedDetails.clear();
    final workingMessages = <ChatMessage>[];
    for (final m in _messages.where(
        (m) => m.role != MessageRole.assistant || m.content.isNotEmpty)) {
      if (m.id != userMsg.id) workingMessages.add(m);
    }

    workingMessages.add(userMsg);
    // build103（I4）：本轮消息起点——workingMessages 前半是历史对话，
    // 停止路径回扫「最后一条有内容的 assistant 消息」时必须跳过历史，
    // 否则会把上一轮的结论当成"当前进度"回填到本轮气泡（实机 bug）。
    final runStart = workingMessages.length;

    // UI：先加 userMsg + assistant 占位（带"思考中…"初始 thinking step）
    final assistantMsg = ChatMessage.create(
      conversationId: widget.conversation.id,
      role: MessageRole.assistant,
      content: '',
      modelName: (_currentSessionModel ?? _apiConfig)?.model,
      showStaleFootnote: false,
      injectedWebSearchCount: 0,
    )
      ..retryOf = userMsg.retryOf
      ..retryIndex = userMsg.retryIndex
      ..addReasoning(ReasoningStep(
        'thinking',
        isAuto
            ? (isZh
                ? '正在思考是否需要联网搜索…（自动档：AI 自决轮次，上限 $maxRounds 轮）'
                : 'Thinking whether to search the web... (Auto: AI decides, up to $maxRounds rounds)')
            : (isZh
                ? '正在思考是否需要联网搜索…'
                : 'Thinking whether to search the web...'),
        phase: 'phase1_think',
        round: 1,
      ));

    // 重置终止标志 —— build155：**不再无脑清 false**。
    // 这一行原来坐在"连接测试 / 知识库 / RAG 向量化 / 人设装配"这串 await 之后（真机几十秒），
    // 用户在那几十秒里按的「停止」在这里被抹掉 ⇒ 循环照跑完 ⇒ 岛写「· 已完成」，
    // 而 App 里那条消息显示"已手动停止"（用户原话：「写已完成回去就写我已手动停止」）。
    // 判据换成"本轮是否被停过"（`reactStopCarried`），build152 那条
    // 「点过一次停止后该会话永久失效」的修复仍然成立：新一轮开始时旧轮的停止不算数。
    _reactLoopStopRequested =
        reactStopCarried(stopRound: _reactStopRound, round: _reactRound);
    // build155：同一判据再算一遍"用户这一轮停过吗"。上面那行还包含触顶/熔断的
    // 终止请求，所以两半不能合并成一个布尔 —— 分岔点在 `stopNote` 的文案上。
    _reactLoopUserStopped =
        reactStopCarried(stopRound: _reactStopRound, round: _reactRound);

    // O6（build95）：新一轮 = 新 generation，并停掉上一轮残留的同 scope
    // 活跃流（典型：上一轮定稿后仍在跑的 suggest 兜底流）——
    // 否则旧流占着生成态，用户下一条消息被阻塞/误停。
    _reactGeneration++;
    // build126：补 reason——这行是**宿主每轮开头的清理**，不是用户操作。
    // 此前不传 reason，日志一律打印 'Generation stopped by user'（真机日志里
    // 每轮 Entering loop 后 4~11ms 必跟一行），把宿主行为伪装成用户操作、带偏排查。
    apiSvc.stopGeneration(
        scope: widget.conversation.id, reason: '新一轮开始，清理上一轮残留流');
    // build120：suggest 兜底流改用专属 scope 后不会再被上面这行覆盖，
    // 必须在这里显式清理（该流可能是上一轮定稿后残留的）。
    _abortSuggestStream(apiSvc, reason: '新一轮开始，清理残留兜底流');

    if (mounted) {
      setState(() {
        if (!_messages.contains(userMsg)) _messages.add(userMsg);
        _messages.add(assistantMsg);
        _isStreaming = true;
      });
      // SF-1：发新消息强制复位跟随并吸底
      _autoFollow = true;
      _scrollToBottom();
    }

    // ===== v1.4.5：ReAct 循环实时写入 DB（防崩溃丢失）—— 预插入 + 重置节流 =====
    _lastAssistantDbSaveMs = 0;
    _lastAssistantDbSaveLen = 0;
    await _persistRoundAssistant(storage, assistantMsg);

    // v1.3.4：20 秒确认改成"向 AI 自检"——不弹窗，而是注入系统自检消息
    // AI 下一轮看到消息后输出 <self_check continue="true|false" reason="..."/>
    // continue=false → 终止循环；continue=true → 继续
    var latestRawResp = '';
    Timer? checkTimer;
    // N3（build94）：等待用户输入（ask_user 弹窗 / 下载确认面板）期间暂停 20s 自检注入，
    // 避免弹窗挂起期间堆叠重复陈旧自检（真机日志实测一次弹窗堆了 8 条）。
    var awaitingUserInput = false;
    // N4（build94）：传输错误自动重试的退避等待期同样暂停自检注入
    var retryBackoff = false;
    // O1（build95）：被用户跳过（拒绝回答）的 ask_user 问题指纹集合——
    // 模型就同一缺口换措辞再次反问时，宿主直接拦截返回 null（不再弹窗），
    // 配合 builtin_plugins 的指令性 toolresult 阻断跨轮重复反问。
    final skippedAskFps = <String>[];
    // O5（build95）：answered 声明前移到定时器之前（Dart 闭包词法作用域，
    // 定时器回调不能引用后声明的局部变量）；定稿后定时器立即停注入。
    bool answered = false;
    // build147 第 11 轮：本轮是不是被**强制收尾/放弃**（O9 连续零产出、G39 连续无结论）。
    // 这种轮次交付的是「⚠️ 模型没答上来 + 点 ↻ 重试」这类报错文案，
    // 再拿它当【回答】去生成 3 条追问，等于在失败气泡下面挂一组"看起来很顺利"的推荐
    // （G39 早就靠 `_reactLoopStopRequested` 顺带挡掉了这件事，O9 没挡 ⇒ 同一族缺陷
    // 在两条闸门里只修了一条）。这里用**专用标记**而不是继续蹭停止标志，
    // 因为那个标志在 catch 里还被当成"用户按了停止"。
    bool roundGivenUp = false;
    // O5（build95）：自检改为「距上次模型活动 ≥20s 的空闲检测」——
    // 原实现每 20s 无条件注入，答完后（answered）仍继续注入干扰。
    // 节拍降为 5s 轮询，只有空闲满 20s 且未定稿才注入。
    var lastModelActivity = DateTime.now();
    if (_enable20sCheck) {
      checkTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        if (!mounted || !_isStreaming || latestRawResp.isEmpty) return;
        if (answered || awaitingUserInput || retryBackoff) return;
        if (DateTime.now().difference(lastModelActivity).inSeconds < 20) return;
        _injectSelfCheck(workingMessages, latestRawResp);
      });
    }

    final apiCfg = _apiConfig!;

    // build132（真机：AI 不看绑定的知识库/助手）——ReAct 是默认执行路径，而
    // `_buildKnowledgeContext` / `_buildAssistantBlock` 的**唯一调用点**此前在
    // chat_screen_message.dart 的普通路径分支（line 358 / 375）。开了 ReAct 的会话
    // 走 line 194 直接 return，两个块从未构建 ⇒ 面板上绑定的知识库文件、助手人设
    // **从未进入任何一次请求**，真机表现就是「AI 看不到我之前放进去的文件」。
    // 与 build131 同型铁律：能力/上下文没进真正执行的那条路径 = 对模型等于不存在。
    // 两者复用同一 part 文件内的同一函数（同源，不另写一份），避免再次各写一半。
    // 只在循环外算一次：RAG 含 embedding 调用，绝不能每轮重算。
    final kbBlockMsg = await _buildKnowledgeContext(
      userMsg.content,
      apiCfg,
      isZh: isZh,
    );
    final assistantBlockMsg = await _buildAssistantBlock();

    var mcpCalls = 0;
    // build146（透明度）：本轮**实际跑了几个生成轮次**的计数器。
    // 纯计数、不参与任何判断 ⇒ ReAct 的行为一个字节都没改；它只服务于收尾那条
    // 「本轮路径」步骤（用户要能看出这一轮走的是哪条路、花了几次 LLM 调用）。
    // 轮次变量 `round` 是 for 循环作用域，finally 读不到，故提到 try 外面。
    var reactRoundsUsed = 0;
    // build164（#84 与 #82 之间那条没人认领的线，我来接）：**本轮流式段的首末时间戳**。
    // 真机凭据是 1.7.106+163 那两行 `[Timing] 本轮 2 步 / 总 0 秒` —— 那一轮在流上跑了
    // 29~30 秒、收了 717 / 1077 个 chunk，而画像里的「总 0 秒」是按 reasoningSteps 的
    // 时间戳算 max−min，那 2 个 step 都是建消息时同毫秒打的 thinking 占位（差约 50ms），
    // chunk 只往 `step.content` 里追加、既不动 ts 也不加 step ⇒ 那 30 秒在日志里**不存在**。
    // 于是"后台到底有没有在收"这种最该回答的问题，只能靠探针那一行反推。
    // 这里只**记事实**（第几帧、首帧、末帧），不参与任何判断，行为一个字节都没改；
    // 提到 try 外面是因为 finally 里的画像要读它（与 `reactRoundsUsed` 同一个理由）。
    final roundStream = RoundStreamTracker();
    // v1.7.34：深度研究模式 MCP 上限 8 → 32（配合更多轮数做深度探索）
    // v1.7.37：深度研究=思考强度拉满（1.0），MCP 上限 8→32（deepResearchOn 已在循环入口计算）
    final maxMcpCallsPerMessage = deepResearchOn ? 32 : 8;
    // E5（build94）：精准熔断——同一动作类型+同一参数指纹累计次数。
    // 第 3 次重复：不执行真实调用，注入 is_error observation 让模型换路；
    // 仍重复（第 4 次）才熔断停循环（保留已产出内容）。只统计主动工具件。
    final toolRepeatCount = <String, int>{};
    // v1.7.26 (D1)：ReAct 多轮请求级 usage 累加（替换废弃的共享计数器）
    var reactUsage = const TokenUsage();

    try {
      // v1.7.26 (E2)：循环边界应为 maxRounds（此前 +1 导致实际多执行一轮）
      for (int round = 0; round < maxRounds; round++) {
        // 用户在 20 秒确认弹窗里点了"终止" → 立即跳出循环
        if (_reactLoopStopRequested) break;
        // build165 ①：人已经离开 App、本端已经把连接收起来了 ⇒ **不再开下一条流**。
        // 走 throw 而不是 break，是为了让这次中止落进下面那个 catch 的**同一条收口路径**
        // （气泡文案 / 挂"回前台重发"那一笔 / 岛的终态 / 落库全在那里，见
        // `StreamEndKind.leftAppAborted` 那一格）—— break 出去会走 maxRounds 兜底，
        // 那一条会把"被收起"写成「_(本轮由系统提前结束思考)_」，又是一句假话。
        // 判据只住 `drop_continue.dart` 那一份（教训 #62），这里不认字符串、不自造标志。
        if (leftAppAbortCarried(
            abortedRound: _leftAppAbortRound, round: _reactRound)) {
          throw const LeftAppAbortSignal();
        }
        // build146：本轮确实开始跑生成才算一轮（终止/跳出在上面，不计）
        reactRoundsUsed = round + 1;

        // 轮次写进通知摘要行：用户在通知栏能看到「第 3/8 轮」。fire-and-forget，
        // 不给主循环加 await —— 这里每轮都要跑，多一个 await 就多一个卡点。
        // build153（真机反馈「你确定按了 oppo 的布局了吗」）：同一行再带**分段进度**。
        // 段表就是上面这个 `round`/`maxRounds`（同一次读取，不另存计数器）——
        // 152 的分段条只接在了编排那一条路上，而默认档几乎所有普通对话都走这里，
        // 所以真机上看到的仍然是"一根不动的线"。
        unawaited(LiveTaskWiring.onResearchUpdate(userMsg.id,
            '第 ${round + 1}/$maxRounds 轮',
            deep: deepResearchOn,
            stages: LiveTaskWiring.roundStages(
                doneRounds: round, totalRounds: maxRounds)));

        // ===== 每轮开始前先 drain 用户中途插话队列 =====
        if (_pendingFollowupMessages.isNotEmpty) {
          final pending = List<String>.from(_pendingFollowupMessages);
          _pendingFollowupMessages.clear();
          if (mounted) setState(() {});
              _followBottomIfNeeded(); // 更新 pendingFollowupCount 显示
          for (final text in pending) {
            workingMessages.add(ChatMessage.create(
              conversationId: widget.conversation.id,
              role: MessageRole.user,
              content: '(用户中途补充)：$text',
            ));
            assistantMsg.appendLastThinking(isZh
                ? '\n📩 用户中途补充了一条消息：「$text」，已加入思考上下文。\n'
                : '\n📩 User added a message mid-thinking: "$text", injected into context.\n');
          }
          if (mounted) setState(() {});
              _followBottomIfNeeded();
        }

        // build93(M5)：循环内记忆缓存——memory_write 成功后置脏，
        // 下一轮重建记忆块，当轮写入当轮可读（原实现循环外固化，重启才生效）
        if (memDirty) {
          memDirty = false;
          final fresh = widget.conversation.longTermMemoryEnabled
              ? await MemoryBlockBuilder.build(
                  widget.conversation.projectId,
                  isZh: isZh)
              : '';
          // build146（prompt cache ③）：只重算长期记忆这一块 —— 协议骨架/插件目录/
          // 深研协议/跨对话摘要四块的文本保持不变，它们的字节（以及其前的缓存前缀）
          // 不受影响。旧实现把整段拼进 reactSystemMsg.content ⇒ 一次记忆写入连带
          // 刷掉整段协议前缀的缓存。
          longTermMemoryText = fresh;
        }
        // 每轮都按共享 token 预算重选历史，稳定前缀始终排在历史之前。
        // build146（prompt cache ③）：分块顺序交给 planPromptPrefix（唯一真身），
        // stableTexts 供下面这次 streamChat 打断点。与 :454 的去重口径一致：
        // userSystemPrompt 计入 plan，去重把它从发出内容里剥掉、_buildMessagesPayload
        // 再在开头补回 ⇒ 那条内容一直在名单里，跨度不会算错。
        final reactStablePlan = planPromptPrefix([
          PromptBlock(PromptBlockKind.userSystemPrompt,
              text: apiCfg.systemPrompt),
          PromptBlock(PromptBlockKind.assistantPersona,
              text: assistantBlockMsg?.content ?? ''),
          PromptBlock(PromptBlockKind.reactProtocol, text: reactProtocolPrompt),
          // pluginHintBlock 自带前导 '\n\n'（它是为"拼在一段文本尾巴上"设计的）；
          // 现在它独立成块、由 plan 用 '\n\n' 连接 ⇒ 不 trim 就会出现两个空行。
          PromptBlock(PromptBlockKind.pluginCatalog,
              text: pluginHintBlock.trim()),
          PromptBlock(PromptBlockKind.deepResearchProtocol,
              text: deepResearchProtocolText),
          PromptBlock(PromptBlockKind.longTermMemory, text: longTermMemoryText),
          PromptBlock(PromptBlockKind.crossChatSummary,
              text: crossChatSummaryText),
          PromptBlock(PromptBlockKind.knowledgeRetrieval,
              text: kbBlockMsg?.content ?? ''),
        ]);
        final stablePrefix = <ChatMessage>[
          for (final b in reactStablePlan.blocks)
            ChatMessage.create(
              conversationId: widget.conversation.id,
              role: MessageRole.system,
              content: b.text,
            ),
        ];
        final reactStableSystemTexts = reactStablePlan.stableTexts;

        final currentMessage = workingMessages.removeLast();
        var segments = await storage.getContextCompactionSegments(
          widget.conversation.id,
        );
        var selection = ContextBudgetService.select(
          conversation: widget.conversation,
          config: apiCfg,
          messages: workingMessages,
          segments: segments,
          currentMessage: currentMessage,
          stablePrefix: stablePrefix,
          components: ContextBudgetComponents(
            workspaceTokens: ApiServiceTokenEstimate.text(
              'ReAct round ${round + 1} of $maxRounds; reserve workspace context.',
            ),
            toolCallTokens: ApiServiceTokenEstimate.text(
              'Reserve space for future tool calls and tool results.',
            ),
            selfCheckTokens: _enable20sCheck
                ? ApiServiceTokenEstimate.text(
                    'Reserve space for a self-check message.',
                  )
                : 0,
            temporaryMessageTokens: ApiServiceTokenEstimate.text(
              'Reserve space for user follow-up messages and temporary injections.',
            ),
          ),
        );
        // v1.7.37 互斥：更大上下文 Max 开启时自动压缩不生效（预算已 1M）
        if (!widget.conversation.largeContextMax &&
            widget.conversation.autoCompress &&
            selection.isNearLimit) {
          await _autoCompressContextIfNeeded(workingMessages);
          segments = await storage.getContextCompactionSegments(
            widget.conversation.id,
          );
          selection = ContextBudgetService.select(
            conversation: widget.conversation,
            config: apiCfg,
            messages: workingMessages,
            segments: segments,
            currentMessage: currentMessage,
            stablePrefix: stablePrefix,
            components: ContextBudgetComponents(
              workspaceTokens: ApiServiceTokenEstimate.text(
                'ReAct round ${round + 1} of $maxRounds; reserve workspace context.',
              ),
              toolCallTokens: ApiServiceTokenEstimate.text(
                'Reserve space for future tool calls and tool results.',
              ),
              selfCheckTokens: _enable20sCheck
                  ? ApiServiceTokenEstimate.text(
                      'Reserve space for a self-check message.',
                    )
                  : 0,
              temporaryMessageTokens: ApiServiceTokenEstimate.text(
                'Reserve space for user follow-up messages and temporary injections.',
              ),
            ),
          );
        }
        final reqList = <ChatMessage>[];
        var skippedApiPrompt = false;
        for (final message in selection.messages) {
          if (message.role == MessageRole.system &&
              message.content == apiCfg.systemPrompt &&
              !skippedApiPrompt) {
            skippedApiPrompt = true;
            continue;
          }
          reqList.add(message);
        }
        workingMessages.add(currentMessage);

        // ---- 调 LLM（v1.5.5：流式化，实时显示思考过程）----
        final thinkingProgressMsg = isZh
            ? (isAuto
                ? '🧠 思考中…（轮次 ${round + 1}/$maxRounds，自动档 $effort）'
                : '🧠 思考中…（轮次 ${round + 1}/$maxRounds，程度 $effort）')
            : (isAuto
                ? '🧠 Thinking... (round ${round + 1}/$maxRounds, auto $effort)'
                : '🧠 Thinking... (round ${round + 1}/$maxRounds, effort $effort)');
        _logger.info(
            '[ReAct] Round ${round + 1} start, effort=$effort, auto=$isAuto',
            cat: LogCat.react,
            tag: 'ReAct');
        assistantMsg.startNewThinking('\n$thinkingProgressMsg\n');
        assistantMsg.setLastReasoningPhase(
            'phase${round + 1}_think', round + 1);
        ansState[0] = false; // v1.7.26：每轮重置 answer 流式状态
        pendingTag[0] = ''; // v1.7.29：每轮重置未闭合标签缓冲
        askUserSeenState[0] = false; // A1：每轮重置提问轮标志
        if (mounted) setState(() {});
              _followBottomIfNeeded();

        // build93(S4) 曾把这里的下限抬到 4096（"ReAct 多标签协议输出较长"）。
        // **build167 撤掉这道抬升**：用户 26 日拍板「可以」= 把 `max_tokens` 的默认交回上游。
        // 官方口径（api-docs.deepseek.com，2026-09-26 取）是不传时非思考档 8K、思考档 64K，
        // 我们发的 4096 **比厂商默认还低一半** ⇒ 一轮里要装 thinking + 整页 HTML 必然被拦腰
        // （真机形状：气泡头写「输出被截断，自动续写中…」、正文停在半截 CSS）。
        // 上限不是预算：不发它不多花钱，被切掉的那半截反而已经付过、还多触发一轮续写。
        // 现在"发不发"由 `api_service.requestMaxTokens` 一处决定（他明确配过更大的数 ⇒ 照发）。
        final reactApiCfg = _conversationApiConfig;
        // 这一轮**实际上线**的上限：日志与截断标注一律读这一行，不读 `reactApiCfg.maxTokens`
        // —— 后者只是配置值，真不发的时候把它打出去就是"把没上线的数字当事实"。
        final reactMaxTokensNote =
            '${requestMaxTokens(configured: reactApiCfg.maxTokens) ?? '未传(上游默认)'}';
        // 阶段1(T4)：本轮模型返回的 tool_calls（硬约束通道），流末归一化为 AgentAction
        final roundToolCalls = <Map<String, dynamic>>[];
        // 阶段1(T7)：带 tools 请求被 400/422 拒绝 → 本轮自动去 tools 重试成功，
        // 流后把该模型 supportToolCalls 记为 false（用户无感降级）
        var toolsRejected = false;
        // build126 (C1)：视觉被拒标记（与 toolsRejected 对称，流结束后统一落库）
        var visionRejected = false;
        // N4（build94）：传输类错误（连接/空闲超时、断网、连接重置、5xx）自动重试
        // 最多 2 次、指数退避（2s/4s），复用同一 reqList 不重复落库；
        // 鉴权/参数类（401/400/404）重试无效直接抛出，由外层 catch 硬终止。
        const kMaxTransportRetries = 2;
        var transportAttempt = 0;
        // build158（用户那份导出的结论「甲：进程活着、流在收，卡在岛的刷新」）：
        // 岛上的摘要行此前只在**每轮开始**时写一次，而一轮里模型可以连吐 49 秒 /
        // 747 个 chunk —— 那 49 秒通知栏一动不动，用户读到的就是"跑着跑着冻住了"。
        // 下面那个节流点用这个时间戳把"正在收"显示出来（有新内容才推，≥5 秒一次）。
        var lastIslandBeat = DateTime.now();
        // N11（build94）：max_tokens 截断自动续拉一次的状态。
        // n11ContinuationUsed：本条消息只允许续拉一次（防无限续拉）；
        // n11InContinuation：当前 while 迭代是续拉轮（保留 answer 流式缓冲做增量追加）；
        // n11ContinuationInAnswer：截断发生在 answer 块内（续拉输出应继续流入答案气泡）；
        // n11PrevRaw：截断前已收到的原始文本（续拉成功后拼接成完整 rawResp）。
        var n11ContinuationUsed = false;
        var n11InContinuation = false;
        var n11ContinuationInAnswer = false;
        var n11PrevRaw = '';
        var rawResp = '';
        // A1（W6，build117 止血）：本轮开始前的答案快照——提问轮需回退到该状态
        // （本轮 answer 不得落地）。取 contentBeforeAttempt 之外的轮级快照，
        // 因为后者在重试循环内、会被后续尝试覆盖。
        // TODO(R4): 随状态机删除。
        final contentBeforeRound = assistantMsg.content;
        // build115（typed 内核最小切片）：content 段交给内核**分类**（而非简单
        // 拼接）——裸文本与 <answer> 块归 answer、<thinking> 块归 thinking、
        // 工具标签归 tool。reasoning_content 根本不进这里（物理分开累积），
        // 因此思考永远不会被当答案（根治 W4「结论混着思考」）。
        var typedAdapter = TypedStreamAdapter(
          isToolTag: (t) => kToolTagNames.contains(t),
        );
        final typedAnswerBuf = StringBuffer();
        final typedThinkingBuf = StringBuffer();
        var typedToolCount = 0;
        // build121（R2/A3，C-04）：结构化模式下 UI 只由 typed item 驱动——
        // 思考面板在 consumeTyped 里直接追加，答案气泡经脏标记在本 chunk 的
        // 循环体里节流刷新；旧链 display/answerStreamBuf 不再驱动渲染。
        var typedAnswerDirty = false;
        var typedThinkingDirty = false;
        void consumeTyped(List<AgentItem> items) {
          for (final it in items) {
            if (it.isAnswer) {
              typedAnswerBuf.write(it.content);
              if (kUseTypedKernel) typedAnswerDirty = true;
            } else if (it.isThinking) {
              typedThinkingBuf.write(it.content);
              // 结构化模式：思考面板只由 typed item 驱动——reasoning_content
              // 与 <thinking> 块都在这里落点，物理上不可能进答案气泡
              if (kUseTypedKernel && it.content.isNotEmpty) {
                assistantMsg.appendLastThinking(it.content);
                typedThinkingDirty = true;
              }
            } else if (it.isTool) {
              typedToolCount++;
              // A1：ask_user 经内核 tool 件上报（与旧链 scrubber 的
              // askUserSeen 同语义——一轮出现即为提问轮）
              if (kUseTypedKernel && it.toolName == 'ask_user') {
                askUserSeenState[0] = true;
              }
            }
          }
        }

        while (true) {
          final rawBuf = StringBuffer();
          // 每次尝试（含重试/续拉）重置内核状态，避免半截块跨轮污染
          typedAdapter = TypedStreamAdapter(
            isToolTag: (t) => kToolTagNames.contains(t),
          );
          // build121：N11 续拉轮不清 typed 缓冲——续拉前的 answer/thinking
          // 已经累计，清掉会让 finalize 只拿到续拉段（答案被截半）。
          // 适配器仍需重建（状态机归零），续拉内容以 bare→answer 语义续接。
          if (!n11InContinuation) {
            typedAnswerBuf.clear();
            typedThinkingBuf.clear();
            typedToolCount = 0;
          }
          typedAnswerDirty = false;
          typedThinkingDirty = false;

          final contentBeforeAttempt = assistantMsg.content;
          // v1.7.37（审查 P2）：每次尝试（含重试）重置流式状态——半截 <answer> 残留
          // 若不清空，重试后答案会拼接成脏内容；重试还要恢复尝试前的答案内容。
          // N11：续拉轮例外——answer 缓冲保留（续拉内容增量追加到截断的答案上），
          // answer 未闭合时保持流入 answerSink。
          ansState[0] = n11InContinuation && n11ContinuationInAnswer;
          pendingTag[0] = '';
          if (!n11InContinuation) {
            answerStreamBuf.clear();
            lastAnswerStreamLen = 0;
            lastAnswerSanitizeAt = DateTime.fromMillisecondsSinceEpoch(0);
            lastAnswerSanitizeLen = 0;
          }
          roundToolCalls.clear();
          toolsRejected = false;
          visionRejected = false;
          // build162：把"当轮已收正文"接给外层 catch（见 :43 那段说明）。
          // 取的是**答案通道**而不是 rawBuf：raw 里混着 thinking 与工具标签，
          // 拿它当"可续的正文"会把协议残片回填进气泡（W4「结论混着思考」同族）。
          // 两种模式各取自己那条驱动气泡的缓冲，与下面 :768 / :787 两处出口一致。
          partialRoundAnswer = () => kUseTypedKernel
              ? typedAnswerBuf.toString()
              : answerStreamBuf.toString();
          // build167：思考落点的取值口（见 :63 那段说明）。typed 内核里 reasoning_content
          // 与 `<thinking>` 块都进 `typedThinkingBuf`（:669 那一条，与答案缓冲物理分开），
          // 所以这一格读到的是**模型真的吐过思考**，不是进度占位文字。
          partialRoundThinking = () =>
              kUseTypedKernel ? typedThinkingBuf.toString() : '';
          if (transportAttempt > 0) {
            assistantMsg.content = contentBeforeAttempt;
            assistantMsg.startNewThinking(
                '\n${isZh ? '网络中断，自动重试第 $transportAttempt 次…' : 'Network interrupted, retrying (attempt $transportAttempt)…'}\n');
            if (mounted) setState(() {});
              _followBottomIfNeeded();
          }
          try {
            await for (final chunk in apiSvc.streamChat(
              config: reactApiCfg,
              messages: reqList,
              // build146（prompt cache ③）：本轮"内容不变"的 system 块名单 → Anthropic 断点。
              // 按内容认，所以剥掉/补回 systemPrompt、预算丢掉几条前缀都不影响跨度。
              stableSystemTexts: reactStableSystemTexts,
              reasoningEffort: effort,
              yieldReasoning: true,
              tools: agentTools,
              // build115（typed 内核）：content 段单独累积——裸文本兜底的答案
              // 来源改为这里（模型给用户的正文），不再用混流拼接文本
              onContent: (c) {
                if (kUseTypedKernel) consumeTyped(typedAdapter.feedContent(c));
              },
              // S5（build124）：ReAct 路径**必须**把 reasoning_content 单独喂内核。
              // 旧实现只接 onContent → 内核 `gotReasoning` 恒为 false：
              //   ① decision 永远是 bareNeedsJudgment（通道判据失真）；
              //   ② 结构化模式下思考面板不驱动旧链 display，于是推理模型的
              //      reasoning **整段不显示**（用户看不到思考，只有空转）；
              //   ③ 混流（yieldReasoning=true）把 reasoning 拼进 rawResp，
              //      旧解析器会把推理正文当 thinking 片段，污染 answerStreamBuf 兜底源。
              // 单独接线后 reasoning 走 thinking 通道（零猜测），与 content 物理分开。
              onReasoning: (rc) {
                if (kUseTypedKernel) consumeTyped(typedAdapter.feedReasoning(rc));
              },
              onToolCalls: (calls) => roundToolCalls.addAll(calls),
              onToolsRejected: () => toolsRejected = true,
              // build126 (C1/C2)：视觉能力**双向学习**。
              //   false → 上游拒图：标记待落库（走下面 toolsRejected 同款流程），
              //           并写记忆，后续不再把图当图发（省掉一次注定 400 的请求）；
              //   true  → 带图真实成功：写记忆，让白名单漏掉的新视觉模型
              //           （qwen3-vl / internvl / llava…）不再被启发式打回 false。
              // 写记忆是 fire-and-forget：失败只影响「下次默认值」，不该打断对话。
              onVisionCapability: (supported) {
                if (!supported) visionRejected = true;
                unawaited(
                    ModelCapabilityMemory.learnVision(reactApiCfg.model, supported));
              },
              // v1.7.26 (D1/D5)：scope 级停止 + 每轮 usage 累加（替换废弃的共享计数器）
              stopScope: widget.conversation.id,
              onUsage: (usage) {
                reactUsage = reactUsage.merge(usage);
              },
            )) {
              if (_reactLoopStopRequested) break;
              // build164（#84）：只记不判 —— 首帧/末帧/帧数进 finally 的耗时画像。
              roundStream.noteChunk();
              rawBuf.write(chunk);
              // build158（甲那条）：**岛的实时性靠内容驱动，不靠空转心跳** ——
              // 每来一个 chunk 就重贴一次会把通知刷爆，5 秒一次刚好把"还在收"显示出来；
              // 而完全没内容的那一段（上游卡住）本来就有 SSE 空闲闸与时限兜底在说话。
              final beatAt = DateTime.now();
              if (beatAt.difference(lastIslandBeat).inSeconds >= 5) {
                lastIslandBeat = beatAt;
                unawaited(LiveTaskWiring.onResearchUpdate(
                    userMsg.id,
                    isZh
                        ? '第 ${round + 1}/$maxRounds 轮 · 已收 ${rawBuf.length} 字'
                        : 'Round ${round + 1}/$maxRounds · ${rawBuf.length} chars',
                    deep: deepResearchOn,
                    stages: LiveTaskWiring.roundStages(
                        doneRounds: round, totalRounds: maxRounds)));
              }
              // 状态机副作用保留（两种模式都要）：N11 截断检测的
              // pendingTag/ansState、A1 的 askUserSeen、answerStreamBuf 兜底源
              final display = _stripReActTagsForStream(
                  chunk, ansState, pendingTag, answerStreamBuf,
                  askUserSeen: askUserSeenState);
              if (kUseTypedKernel) {
                // build121（R2/A3，C-04）：结构化模式——思考面板已在
                // consumeTyped 里由 typed item 直接追加（reasoning_content 与
                // <thinking> 块物理进不了答案气泡），这里只节流刷新答案气泡；
                // 旧链 display / answerStreamBuf **不再驱动任何 UI**。
                if (typedAnswerDirty || typedThinkingDirty) {
                  if (typedAnswerDirty) {
                    // O7-2（build96）同款节流：无 '<' 跳过正则，有 '<' 300ms/500 字节
                    final bufStr = typedAnswerBuf.toString();
                    final now = DateTime.now();
                    final needSanitize = bufStr.contains('<');
                    final throttleOk = now.difference(lastAnswerSanitizeAt) >
                            const Duration(milliseconds: 300) ||
                        bufStr.length - lastAnswerSanitizeLen > 500;
                    if (!needSanitize || throttleOk) {
                      assistantMsg.content =
                          needSanitize ? stripControlTags(bufStr) : bufStr;
                      lastAnswerSanitizeAt = now;
                      lastAnswerSanitizeLen = bufStr.length;
                      typedAnswerDirty = false;
                    }
                  }
                  if (mounted) setState(() {});
                  _followBottomIfNeeded();
                  typedThinkingDirty = false;
                }
              } else {
                // 兼容模式（kUseTypedKernel=false 一键回退）：旧链驱动
                if (display.isNotEmpty) {
                  assistantMsg.appendLastThinking(display);
                  if (mounted) setState(() {});
              _followBottomIfNeeded();
                }
                // v1.7.37（⑰）：answer 块内容增量写入答案气泡，结论也流式输出
                if (answerStreamBuf.length > lastAnswerStreamLen) {
                  lastAnswerStreamLen = answerStreamBuf.length;
                  // O7-2（build96）：流式展示也过控制标签净化，self_check 等残片不闪现在气泡
                  // O7（build98）：无 '<' 时跳过多轮正则（每 chunk 全量净化是 O(n²)），
                  // 有 '<' 也做 300ms/500 字节节流，最终落地统一净化兜底
                  final bufStr = answerStreamBuf.toString();
                  final now = DateTime.now();
                  final needSanitize = bufStr.contains('<');
                  final throttleOk = now.difference(lastAnswerSanitizeAt) >
                          const Duration(milliseconds: 300) ||
                      bufStr.length - lastAnswerSanitizeLen > 500;
                  if (!needSanitize || throttleOk) {
                    assistantMsg.content =
                        needSanitize ? stripControlTags(bufStr) : bufStr;
                    lastAnswerSanitizeAt = now;
                    lastAnswerSanitizeLen = bufStr.length;
                    if (mounted) setState(() {});
              _followBottomIfNeeded();
                  }
                }
              }
            }
            rawResp = rawBuf.toString();
            // build165 ①：本端在"离开 App"那一刻收起的这条流**不会抛异常** ——
            // api 层让它安静结束（`api_service.dart` 里 `if (stopFlag[0]) { log.info(
            // 「本端已主动关闭连接（自我中止，不计为故障）」); return; }`，build141
            // 为了"自我取消不许伪装成网络故障"写的那一段）。所以这里必须自己认这次中止，
            // 否则下面 N11 会在后台里续拉一条新流、for 还会再开一条 —— 那正是探针
            // 08:03 抓到的「离开 46s，一个 chunk 都没收到 ⇒ 整条流在后台停摆」那一段。
            // 判据与轮首那一处同一份（`drop_continue.dart`），抛出去交给同一个 catch 收口。
            if (leftAppAbortCarried(
                abortedRound: _leftAppAbortRound, round: _reactRound)) {
              throw const LeftAppAbortSignal();
            }
            // N11（build94）：续拉轮拼接截断前的原始文本，得到完整响应
            if (n11InContinuation) {
              rawResp = n11PrevRaw + rawResp;
              n11PrevRaw = '';
              n11InContinuation = false;
            }
            // N11（build94）：max_tokens 截断自动续拉一次——
            // 流结束仍有未闭合标签/answer 未闭合时，把已输出作为 assistant 回合，
            // 请模型从截断处继续；仅续拉一次，避免无限续拉。
            final n11Truncated = pendingTag[0].isNotEmpty ||
                (ansState[0] && !rawResp.contains('</answer>'));
            if (n11Truncated &&
                !n11ContinuationUsed &&
                !_reactLoopStopRequested) {
              n11ContinuationUsed = true;
              n11InContinuation = true;
              n11ContinuationInAnswer =
                  ansState[0] && !rawResp.contains('</answer>');
              n11PrevRaw = rawResp;
              _logger.warn(
                  '[ReAct] N11 truncated output — auto-continuing once '
                  '(round ${round + 1}, pendingTag=${pendingTag[0]}, inAnswer=$n11ContinuationInAnswer, '
                  'maxTokens=$reactMaxTokensNote)',
                  cat: LogCat.react,
                  tag: 'ReAct');
              assistantMsg.startNewThinking(
                  '\n${isZh ? '输出被截断，自动续写中…' : 'Output truncated, auto-continuing…'}\n');
              if (mounted) setState(() {});
              _followBottomIfNeeded();
              reqList.add(ChatMessage.create(
                conversationId: widget.conversation.id,
                role: MessageRole.assistant,
                content: rawResp,
              ));
              // build120：续写指令必须显式禁止再写 thinking。
              // 真机证据（2026-09-16 21:34 导出日志，「生成一个可视化表格」）：
              //   1) 首轮 maxTok=4096 截断 → N11 触发续写；
              //   2) 续写轮 raw response 3877 字符里，2500+ 字符又是 <thinking> 复述
              //      （"用户说…考虑几种理解…最好的做法…我应该用 ws_write"）；
              //   3) Token 预算被 reasoning 吃光 → 真正该产生的 ws_write 工具调用
              //      没有余量输出 → 用户看到的「结论混着思考、可视化没落地」。
              // 旧文案只说「从截断处继续」，模型自然会先「想一下从哪继续」——
              // 对 reasoning 模型这等于把续写预算重复烧在思考上。
              reqList.add(ChatMessage.create(
                conversationId: widget.conversation.id,
                role: MessageRole.user,
                content: isZh
                    ? '你的上一条输出因长度限制被截断。请从截断处继续，不要重复已输出的部分，不要重新开头。'
                        '重要：本轮不要再输出任何 <thinking> 内容——你已经思考过了，现在只输出行动与结论。'
                        '如果还缺工具调用，直接输出该工具标签（如 <ws_write path="..." content="..." />）；'
                        '如果 <answer> 未闭合，直接续写正文并用 </answer> 闭合。'
                    : 'Your previous output was truncated. Continue from exactly where it stopped; do not repeat or restart. '
                        'IMPORTANT: do not emit any <thinking> content this round — you have already thought enough; output actions and results only. '
                        'If a tool call is still missing, emit that tool tag directly (e.g. <ws_write path="..." content="..." />); '
                        'if <answer> was left open, continue the body and close with </answer>.',
              ));
              continue; // 再走一轮 while：续拉
            }
            break; // 本轮成功，跳出重试循环
          } catch (err) {
            if (transportAttempt >= kMaxTransportRetries ||
                !_isTransportRetryable(err)) {
              rethrow; // 重试耗尽或不可重试 → 交外层 catch 处理
            }
            transportAttempt++;
            final waitSec = transportAttempt * 2; // 指数退避：2s → 4s
            _logger.warn(
                '[ReAct] Round ${round + 1} transport error '
                '(attempt $transportAttempt/$kMaxTransportRetries), retry in ${waitSec}s: $err',
                cat: LogCat.react,
                tag: 'ReAct');
            retryBackoff = true;
            try {
              await Future<void>.delayed(Duration(seconds: waitSec));
            } finally {
              retryBackoff = false;
            }
          }
        }
        latestRawResp = rawResp;
        // B-027：把本轮助手原文（含 thinking / 动作标签）作为 assistant 消息回写工作区。
        // 181 行注释声明的设计意图「assistant 的 thinking/search 直接当 assistant 消息
        // 发回去（原始完整文本）」此前从未实现 —— rawResp 只进一次性 reqList，导致第 2 轮起
        // 模型看不到自己上一轮的动作链（易重复发起相同搜索，宿主侧 E5 熔断只是在打补丁）。
        // 位置说明：本行在本轮工具分发之前，故序列恢复为「assistant 原文 → 其后各 toolresult」，
        // 与标准 ReAct 交替一致。
        workingMessages.add(ChatMessage.create(
          conversationId: widget.conversation.id,
          role: MessageRole.assistant,
          content: rawResp,
        ));
        // O5：每轮模型活动刷新空闲基准（20s 无新输出才允许注入自检）
        lastModelActivity = DateTime.now();
        // build93(S3)：残段检测——流结束时仍有未闭合标签/未闭合 answer，
        // 说明输出被截断，残段不得当作完整结论静默落地
        final streamTruncated = pendingTag[0].isNotEmpty ||
            (ansState[0] && !rawResp.contains('</answer>'));
        if (streamTruncated) {
          // 给耗时画像留这一格事实（见声明处的三态口径：收完过才允许报 true/false）
          sawMaxTokensTruncation = true;
          // build164（#82 取证 ③）：这条日志必须把**上限是多少**与**是否已经用过那
          // 一次续写**一起写出来。真机上"老是中断"的根因就是 maxTokens 打满
          // （build164 队列里那条取证），旧日志只说 truncated、不说被什么限制住，
          // 排查时只能靠猜。
          _logger.warn(
              '[ReAct] stream truncated by maxTokens=$reactMaxTokensNote: '
              'pendingTag=${pendingTag[0]} inAnswer=${ansState[0]} '
              'continuationUsed=$n11ContinuationUsed',
              cat: LogCat.react,
              tag: 'ReAct');
        }

        _logger.verbose(
            '[ReAct] Round ${round + 1} raw response (${rawResp.length} chars): ${rawResp.substring(0, rawResp.length > 500 ? 500 : rawResp.length)}${rawResp.length > 500 ? '...' : ''}',
            cat: LogCat.react,
            tag: 'ReAct');

        // ---- v1.7.24 行为指纹兜底：连续 3 轮 thinking 内容相同 → 提前注入自检 ----
        final fpText = _extractThinkingFingerprint(rawResp);
        // v1.7.31：用户开启"记录思考过程"时，将完整 thinking 写入日志
        if (logThinking && fpText.isNotEmpty) {
          _logger.verbose(
              '[ReAct] Round ${round + 1} thinking (${fpText.length} chars):\n$fpText',
              cat: LogCat.react,
              tag: 'ReAct-thinking');
        }
        if (fpText.isNotEmpty) {
          if (loopLastThinkingFp != null && fpText == loopLastThinkingFp) {
            loopRepeatThinkingCount++;
          } else {
            loopRepeatThinkingCount = 1;
          }
          loopLastThinkingFp = fpText;
          if (loopRepeatThinkingCount >= 3) {
            _logger.warn(
                '[ReAct] Behavior fingerprint: $loopRepeatThinkingCount consecutive identical thinking rounds — injecting self-check early (not waiting 20s)',
                cat: LogCat.react,
                tag: 'ReAct');
            _injectSelfCheck(workingMessages, rawResp);
            // 注入后重置，避免每轮重复注入；AI 读到自检消息后会改变输出
            loopRepeatThinkingCount = 0;
            loopLastThinkingFp = null;
          }
        }

        // 用户在 LLM 调用期间点了"终止" → 不解析了直接跳出
        if (_reactLoopStopRequested) break;

        // ---- v1.6.9：解析 LLM 输出，再用 PluginRegistry.dispatch 分发插件执行 ----
        //   这里做的事情：
        //     1) _parseReActOutput 依然按顺序识别 <thinking>/<search>/<answer> 等片段
        //     2) 对每个片段构造 PluginContext（承载 workingMessages/UI/SnackBar/保存 assistant 等回调）
        //     3) 交给 registry.dispatch(type, attrs) → 一行分发，不再 if/else 317 行
        // 阶段1(T7)：记住该模型不支持 tools，后续请求不再携带
        //
        // build164（#82 用户指令「工具调用呢，全部都默认开启，因为很少模型是不支持的」）：
        // 探测被拒 **不再落库**。旧实现把一次 400/422 的判定 `saveApiConfig` 写死成
        // supportToolCalls=false ⇒ 一次误判（网关瞬时故障、tool_choice 不认、参数白名单
        // 差异）就把这条配置**永久降级**，而且下次开机也不会自愈。
        // `api_config.dart:363` 的注释同样点名这条路径（它曾把「密钥没读到」的标记洗掉，
        // 酿成 build147 那条 Key 消失 P0）——copyWith + 落库这条组合是本仓最容易被踩的。
        // 新口径：只改**会话内**的配置对象（本轮/本条消息继续按无 tools 跑，标签协议照旧），
        // 库里那份一个字都不动。用户在设置页手动关掉 supportToolCalls 仍然是有效配置
        // ——那走的是 api_config_edit_screen 的保存路径，是用户意图，不在本次改动范围内。
        if (toolsRejected) {
          final baseCfg = _currentSessionModel ?? _apiConfig;
          if (baseCfg != null && baseCfg.supportToolCalls) {
            final downgraded = baseCfg.copyWith(supportToolCalls: false);
            if (_currentSessionModel != null) {
              _currentSessionModel = downgraded;
            } else {
              _apiConfig = downgraded;
            }
            _logger.warn(
                '[ReAct] model ${baseCfg.model} rejected tools (400/422) — '
                '本轮临时按不支持工具调用继续（改的是会话内配置），配置未改动、未落库；'
                '标签协议照常执行',
                cat: LogCat.react,
                tag: 'ReAct');
          }
        }

        // build126 (C1)：视觉被拒标记（与 toolsRejected 对称）。
        // build164（#82）：与 tools 同罪——探测被拒**不再 saveApiConfig 落库**。
        // 少掉一次「记住」的代价只是重启后再撞一次 400，而误判的代价是用户的
        // supportVision 被永久写死成 false、他手动开了也没用（与上面同一条 P0 家族）。
        // 真正的双向学习仍然存在：`ModelCapabilityMemory.learnVision`（上面 streamChat
        // 的 onVisionCapability 里）按模型名记忆，设置页读的是那份，不依赖这条落库。
        if (visionRejected) {
          final baseCfg = _currentSessionModel ?? _apiConfig;
          if (baseCfg != null && baseCfg.supportVision) {
            final downgraded = baseCfg.copyWith(supportVision: false);
            if (_currentSessionModel != null) {
              _currentSessionModel = downgraded;
            } else {
              _apiConfig = downgraded;
            }
            _logger.warn(
                '[ReAct] model ${baseCfg.model} rejected vision (400/422) — '
                '本轮临时按不支持图片继续、改用本机 OCR，配置未改动、未落库',
                cat: LogCat.react,
                tag: 'ReAct');
          }
        }

        final parsed = _parseReActOutput(rawResp);
        // 阶段1(T4)：tool_calls 硬约束通道归一化为 AgentAction piece，
        // 并入 parsed 走既有分发循环（与标签通道同构）
        // N2（build94）：双通道合流排序——thinking→被动件→answer→suggest→交互动作；
        //   ask_user 跨通道去重只留一个；answer 与 ask_user 同轮时 ask_user 优先。
        if (roundToolCalls.isNotEmpty) {
          final tagActions = actionsFromTagPieces(parsed);
          final toolActions = actionsFromToolCallsExpanded(roundToolCalls,
              registry: mcpToolRegistry);
          // build110（U9 日志实锤）：模型幻觉的未知函数名此前被静默丢弃，
          // 模型与用户都无感知——喂回教学 toolresult（同名内置插件已由
          // kBuiltinRoutableTriggers 路由，到不了这里）
          final knownToolNames = <String>{
            for (final t in builtinAgentToolSchemas())
              (t['function'] as Map)['name'] as String,
            ...kBuiltinRoutableTriggers,
          };
          for (final call in roundToolCalls) {
            final callName = call['name']?.toString() ?? '';
            if (callName.isEmpty ||
                knownToolNames.contains(callName) ||
                parseMcpToolName(callName, mcpToolRegistry) != null) {
              continue;
            }
            _logger.warn(
                '[ReAct] unknown tool_call dropped: $callName — feeding back teaching toolresult',
                cat: LogCat.react,
                tag: 'ReAct');
            // 此处尚无 pc（per-piece 才构造），直接操作 workingMessages +
            // assistantMsg（与 pc.addMessage/addReasoningStep 同效果）
            assistantMsg.addReasoning(ReasoningStep(
              'mcp_call',
              '未知函数调用：$callName',
              toolName: callName,
              status: 'not_found',
              resultSummary: '该函数不在可用函数列表中，已忽略',
            ));
            workingMessages.add(ChatMessage.create(
              conversationId: widget.conversation.id,
              role: MessageRole.user,
              content:
                  '<toolresult kind="$callName" is_error="true">未知函数「$callName」：不在可用函数列表里。内置插件请直接输出其原生标签（如 <log_query category="ERROR" tail="40" />）；联网搜索用 web_search；MCP 工具用列表里的准确名称。</toolresult>',
            ));
            if (mounted) setState(() {});
              _followBottomIfNeeded();
          }
          final merged = mergeChannelActions(tagActions, toolActions,
              onLog: (m) =>
                  _logger.info('[ReAct] $m', cat: LogCat.react, tag: 'ReAct'));
          parsed
            ..clear()
            ..addAll(merged.map((a) => a.toPiece()));
        }
        // ===== G37（build124）：标签通道的「不可识别工具块」显式引导 =====
        // ChatML 归一化遇到宿主不认识的 invoke 名时产出 <unknown_tool_call>，
        // 这里回灌教学 toolresult（与 FC 通道未知函数同构）。**不得静默当文本**：
        // 弱模型会以为调用已发生，接着编造结果。
        for (final p in parsed.where((e) => e['type'] == 'unknown_tool_call')) {
          final badName = (p['name'] ?? '').trim();
          if (badName.isEmpty) continue;
          _logger.warn(
              '[ReAct] G37 unknown tag-channel tool: $badName — feeding back teaching toolresult',
              cat: LogCat.react,
              tag: 'ReAct');
          assistantMsg.addReasoning(ReasoningStep(
            'mcp_call',
            '未知工具调用：$badName',
            toolName: badName,
            status: 'not_found',
            resultSummary: '该工具不在可用列表中，已忽略并引导模型改用正确语法',
          ));
          workingMessages.add(ChatMessage.create(
            conversationId: widget.conversation.id,
            role: MessageRole.user,
            content:
                '<toolresult kind="$badName" is_error="true">未知工具「$badName」：不在可用工具列表里。内置插件请直接输出其原生标签（如 <log_query category="ERROR" tail="40" />）；联网搜索用 <search query="关键词" />；MCP 工具用 <mcp_call plugin_id="插件ID" tool="工具名">{"参数":"值"}</mcp_call>。不要使用 &lt;|invoke|&gt; 形式。</toolresult>',
          ));
        }
        // v1.7.38（A）：轮末解析打点——片段类型一览，定位"解析无 answer"类问题
        _logger.info(
            '[ReAct] Round ${round + 1} parsed: ${parsed.map((e) => e['type']).join(',')}'
            ' | answerStreamBuf=${answerStreamBuf.length} chars'
            ' | typedAnswerBuf=${typedAnswerBuf.length} chars'
            ' | typedThinkingBuf=${typedThinkingBuf.length} chars'
            ' | typedTools=$typedToolCount',
            cat: LogCat.react,
            tag: 'ReAct');
        // ===== G32/G34（build124）：轮次终态判定（过渡语 vs 结论）=====
        //
        // 判据必须是**轮级的**（单看片段类型永远判不出「后面还有动作」），
        // 具体规则见 [judgeRoundTerminal]（纯函数、可单测）。真机病灶：
        // 弱模型把过渡语写进 <answer>、同轮再发 mcp_call → 过渡语被当结论定稿。
        final verdict = judgeRoundTerminal(parsed);
        if (verdict.downgradedCount > 0) {
          parsed
            ..clear()
            ..addAll(verdict.pieces);
          _logger.warn(
              '[ReAct] G34 transition-answer downgraded: ${verdict.downgradedCount} piece(s) / '
              '${verdict.downgradedChars} chars answer→thinking '
              '(round=${round + 1}, lastAction=${verdict.lastActionIndex})',
              cat: LogCat.react,
              tag: 'ReAct');
        }
        final roundIsToolRound = verdict.isToolRound;
        if (roundIsToolRound) {
          // 工具轮：本轮不落地任何最终答案（唯一产出是 toolresult + 下一轮答案）。
          // 气泡回滚到本轮起点——过渡语/JSON 参数不得留在气泡里，也不得被轮末
          // 兜底当结论（真机：68 字符 mcp 参数 JSON 被定稿 + 触发 suggest）。
          final leakedTyped = typedAnswerBuf.length;
          final leakedLegacy = answerStreamBuf.length;
          typedAnswerBuf.clear();
          typedAnswerDirty = false;
          answerStreamBuf.clear();
          lastAnswerStreamLen = 0;
          if (assistantMsg.content != contentBeforeRound) {
            assistantMsg.content = contentBeforeRound;
          }
          if (mounted) setState(() {});
          _followBottomIfNeeded();
          _logger.warn(
              '[ReAct] G32 tool round: finalize suppressed'
              ' (leaked typed=$leakedTyped / legacy=$leakedLegacy chars rolled back)',
              cat: LogCat.react,
              tag: 'ReAct');
        }
        int totalSearchHitsSnapshot = 0;
        // build93(S1)：一轮只弹一次 ask_user——同轮多个时只取最后一个，其余丢弃
        int lastAskIdx = -1;
        for (var i = 0; i < parsed.length; i++) {
          if (parsed[i]['type'] == 'ask_user') lastAskIdx = i;
        }
        // A1（W6，build117 止血）：**一轮出现 ask_user 即为提问轮，本轮不落地
        // 任何最终答案**。原实现分发不互斥：弱模型同轮输出 `<ask_user>` 与
        // `<answer>`（真机日志 parsed: thinking,ask_user,thinking,answer |
        // answerStreamBuf=715）→ 反问卡片与 715 字结论气泡同屏、结论把反问
        // 重说一遍。714 行注释自称「ask_user 优先」但从无压制代码。
        // TODO(R4): 随状态机删除——类型层天然互斥后本止血代码不再需要。
        final hasAskUserThisRound = lastAskIdx >= 0;
        // build110（U9）：本轮已见动作指纹（同轮去重用，每轮新建）
        final roundSeenActionFps = <String>{};
        for (var pi = 0; pi < parsed.length; pi++) {
          final p = parsed[pi];
          final type = p['type']!;
          if (type == 'ask_user' && pi != lastAskIdx) {
            _logger.info('[ReAct] drop duplicate ask_user piece #$pi',
                cat: LogCat.react, tag: 'ReAct');
            continue;
          }
          if (type == 'mcp_call') {
            if (mcpCalls >= maxMcpCallsPerMessage) {
              _logger.warn('[ReAct] MCP call limit reached for message',
                  cat: LogCat.react, tag: 'ReAct');
              _reactLoopStopRequested = true;
              break;
            }
            mcpCalls++;
          }
          if (type == 'thinking') {
            // v1.5.5 流式模式：流式过程中已实时追加，解析时跳过避免重复
            continue;
          }
          if (type == kProgressTagName) {
            // build164（#82）：阶段小结 —— **只**成 reasoning step，绝不进正文。
            // 三条理由：① content 是复制/朗读/上下文回灌的源，塞进去会污染（用户要的是
            // 气泡里看得见，不是正文里多一句）；② AnswerFinalizer/O7 定稿链会把控制标签
            // 从正文里剥掉，塞进去等于送给清洗链吃掉；③ reasoningSteps 随 ChatMessage.toMap
            // 整体落库 ⇒ 零 DB 迁移（schema v39 不许加列）。
            // 位置：就在本片段处落 step ⇒ 与工具步骤的相对顺序与模型输出顺序一致。
            final noteText = (p['content'] ?? '').trim();
            if (noteText.isEmpty) continue;
            progressNoteSeq++;
            assistantMsg.addReasoning(buildProgressNoteStep(
              noteText,
              round: round + 1,
              phase: 'phase${round + 1}_think',
            ));
            _logger.info(
                formatProgressNoteLog(progressNoteSeq, noteText),
                cat: LogCat.react,
                tag: 'ReAct');
            if (mounted) setState(() {});
            _followBottomIfNeeded();
            continue;
          }
          if (type == 'unknown_tool_call') {
            // G37：已在轮前回灌教学 toolresult，这里不 dispatch（无插件可执行）
            continue;
          }
          // 构造 PluginContext：作为「插件调用的 UI/服务 隔离层」，
          // 统一管理 setState / mounted / SnackBar / workingMessages append / answer finalize 等行为。
          final pc = PluginContext(
            workingMessages: workingMessages,
            assistantMsg: assistantMsg,
            webSearchCfg: _webSearchCfg,
            // build101（C3）：把本会话思考强度传给插件——≥0.8 时搜索会额外抓网页正文
            currentReasoningEffort: widget.conversation.reasoningEffort,
            conversationApiConfig: _conversationApiConfig,
            userMsg: userMsg,
            rawResp: rawResp,
            storage: storage,
            // WebSearchService 是静态类，没有 instance，所以 webSearch 参数留空
            // SearchPlugin 会直接用静态方法 WebSearchService.searchGeneral(...)
            // v1.7.9 (M7)：用入口缓存的 dlSvc，不再 context.read（跨 async 崩溃）
            appDownload: dlSvc,
            logger: _logger,
            answerBuffer: StringBuffer(),
            answered: answered,
            mounted: mounted,
            rootContext: mounted ? context : null,
            onRequestStop: () {
              _reactLoopStopRequested = true;
            },
            onAppendReasoning: (text) {
              if (mounted) setState(() {});
              _followBottomIfNeeded();
            },
            onAppendUserMessage: (text) {
              if (mounted) setState(() {});
              _followBottomIfNeeded();
            },
            onFinalizeAnswer: (text,
                {injectedWebSearchCount = 0, forceSave = true}) async {
              // build121（R2/A3，C-04）：答案**源**切换——结构化模式下不再用
              // parseReActOutput 的 answer piece（其「无闭合 <answer> 即切到
              // 流末」正是 G3 误切点），改用内核已按「字面提及 vs 真包裹」
              // 判别过的 typed 分类结果。typed 缓冲为空（如纯工具轮）时回退
              // 旧源，保证工具链为 answer 件填充内容的路径不回归。
              final typedSource = kUseTypedKernel && typedAnswerBuf.isNotEmpty;
              final source =
                  typedSource ? typedAnswerBuf.toString() : text;
              // G36（build124）：日志必须打印**真实答案源**，而不是开关状态。
              // 旧打点 `typed=$kUseTypedKernel` 在开关=true 时也说「typed」，
              // 与「typed 缓冲为空、实际取的是 answer piece」的真实来源相反——
              // 排查时把两条不同链路当成一条（真机误导过一次）。
              final srcTag = typedSource
                  ? 'typed-kernel-buf'
                  : (kUseTypedKernel
                      ? 'legacy-piece(buf-empty)'
                      : 'legacy-piece(kernel-off)');
              // v1.7.38（A）：答案落地打点——此前全链路零日志，无法定位"答案丢失"
              _logger.info(
                  '[ReAct] finalizeAnswer called, ${source.length} chars'
                  ' (source=$srcTag), round=${round + 1}',
                  cat: LogCat.react,
                  tag: 'ReAct');
              // O7-2/O7-3（build96）：答案落地统一过控制标签净化——气泡显示、
              // DB 落库、suggest【回答】三处都读 assistantMsg.content，此处净化即三处同源。
              final cleanText = stripControlTags(source);
              if (cleanText.length != source.length) {
                _logger.warn(
                    '[ReAct] O7 stripped control tags from answer: ${source.length} -> ${cleanText.length} chars',
                    cat: LogCat.react,
                    tag: 'ReAct');
              }
              // build121（冻结令 C-03/C-04）：结构化模式**跳过 L1/W4 词表链**
              // （stripLeadingMetaTalk / stripChineseMetaProcess）——类型层已把
              // 思考与结论物理分开（含 G3 字面提及判别），词表猜写在结构化模式
              // 不再驱动落库；只保留两条**确定性硬规则**：标签剥离 + 占位 URL。
              // 兼容模式（kUseTypedKernel=false）维持原链不变。
              final ({String clean, String stripped}) scrubbed;
              if (typedSource) {
                final noTags = AnswerFinalizer.stripTags(cleanText);
                final (cleanOnly, fakeUrls) =
                    AnswerFinalizer.scrubPlaceholderUrls(noTags);
                scrubbed = (
                  clean: cleanOnly,
                  stripped: fakeUrls.isEmpty
                      ? ''
                      : '（剥除占位链接）\n$fakeUrls',
                );
              } else {
                // L1（build107）：剥掉 answer 开头的 deliberation 过程话术——
                // 剥掉的行回 thinking 面板，不丢信息。
                // build112：统一走唯一 finalize 出口（AnswerFinalizer）
                scrubbed = AnswerFinalizer.finalize(cleanText);
              }
              if (scrubbed.stripped.isNotEmpty) {
                _logger.warn(
                    '[ReAct] finalize stripped ${scrubbed.stripped.length} chars from answer (source=$srcTag, round=${round + 1})',
                    cat: LogCat.react,
                    tag: 'ReAct');
                assistantMsg.appendLastThinking('\n${scrubbed.stripped}\n');
              }
              assistantMsg.content = scrubbed.clean;
              assistantMsg.injectedWebSearchCount = injectedWebSearchCount;
              if (forceSave) {
                await _throttledSaveAssistantContent(
                    storage, assistantMsg, scrubbed.clean,
                    force: true);
              }
              answered = true;
            },
            onSetState: (fn) {
              if (mounted) {
                fn();
                setState(() {});
              }
            },
            // build129：形参对齐 PluginContext（count=**真实命中数**，force 独立传入）。
            // 顺带补一个「接口承诺没兑现」：旧实现忽略了 force、恒走节流保存，
            // 插件要的「立刻落盘」从未生效；现在照 force 执行。
            onSaveAssistantContent: (count, {bool force = false}) async {
              totalSearchHitsSnapshot = count;
              await _throttledSaveAssistantContent(
                  storage, assistantMsg, assistantMsg.content,
                  force: force);
            },
            onShowAskUser: (question, options) async {
              if (!mounted) return null;
              // O1（build95）：同一缺口被跳过后，模型换措辞再反问 → 宿主拦截，
              // 不弹窗直接返回 null（插件层会注入「禁止再反问」指令性 toolresult）。
              final fp = normalizeAskUserQuestion(question);
              if (skippedAskFps.any((prev) => isSameAskUserGap(prev, fp))) {
                _logger.warn(
                    '[ReAct] O1 blocked repeated ask_user for skipped gap: "$question"',
                    cat: LogCat.react,
                    tag: 'ReAct');
                return null;
              }
              // build142（灵动岛）：反问是「等你回来答」，只发提醒、不起服务。
              unawaited(LiveTaskWiring.onAskUserStart(
                  widget.conversation.id,
                  question.length > 80 ? '${question.substring(0, 80)}…' : question));
              // N3：弹窗等待期间暂停 20s 自检
              awaitingUserInput = true;
              // build140 反馈④：反问那一轮也要有推荐，且**与弹窗同帧**（反馈⑤的时机口径）。
              // 做法：弹窗一出现就并行发起一次轻量生成，产出"用户可能直接这样答"的
              // 快捷回复，由面板自己渲染成可点行。
              // 两条刻意的设计：
              //  · 种子只有【反问正文 + 选项】，不是 thinking 原文 —— A4（W7）当年正是
              //    拿 thinking 当【回答】补推荐，才产出三条无关追问；
              //  · 结果**不写进 assistantMsg.suggestions**（那是"追问"语义、要随答案落库），
              //    面板关掉即随作用域一起丢弃 ⇒ 不会出现"答完之后还挂着过期答复"。
              final askQuickReplyScope =
                  'suggest:${widget.conversation.id}:ask:'
                  '${DateTime.now().microsecondsSinceEpoch}';
              final quickReplies = _streamSuggestItems(
                apiSvc,
                buildAskUserSuggestPrompt(
                  question: question,
                  options: options,
                  isZh: isZh,
                ),
                label: 'AskUser quick replies',
                // build141（观察 A）：给这条链一个**具名 scope**，面板一关就能精确取消它。
                scope: askQuickReplyScope,
                onUsage: (u) => reactUsage = reactUsage.merge(u),
              );
              try {
                final reply = await _showAskUserDialog(
                  question,
                  options,
                  quickReplies: quickReplies,
                );
                if (reply == null || reply.trim().isEmpty) {
                  skippedAskFps.add(fp);
                }
                return reply;
              } finally {
                awaitingUserInput = false;
                unawaited(LiveTaskWiring.onAskUserEnd(widget.conversation.id));
                // build141（真机日志观察 A/B）：面板都已经关了，这条快捷回复流再跑下去
                // **没有任何接收者**。上一版它要一直挂到 6s 空闲闸才被掐，
                // 那 4.8 秒是白烧的一次请求；更糟的是掐它的时候 close 上游，
                // 冒出来的 `ClientException: Connection closed while receiving data`
                // 以 runZonedGuarded 未捕获 + ERROR 级落进日志（真机 23:22:16 那两条），
                // 读起来像网络故障 —— 自我取消伪装成故障，比静默更坏。
                _abortOneSuggestScope(apiSvc, askQuickReplyScope,
                    reason: '反问面板已关闭');
              }
            },
            onPresentAppDownloadSources: hasDownloadPlugin
                ? ({
                    required userText,
                    required keyword,
                    required altKeywords,
                    required officialDomains,
                    existingUserMsg,
                    existingPlaceholder,
                    platform = 'android',
                  }) async {
                    answered = true;
                    // N3：下载确认面板等待期间暂停 20s 自检
                    awaitingUserInput = true;
                    try {
                      await _presentDownloadSources(
                        userText: userText,
                        keyword: keyword,
                        altKeywords: altKeywords,
                        officialDomains: officialDomains,
                        existingUserMsg: existingUserMsg,
                        existingPlaceholder: existingPlaceholder,
                        platform: platform,
                      );
                    } finally {
                      awaitingUserInput = false;
                    }
                  }
                : null,
            onPresentFileSources: hasDownloadPlugin
                ? ({
                    required userText,
                    required query,
                    fileType,
                    existingUserMsg,
                    existingPlaceholder,
                  }) async {
                    answered = true;
                    // N3：文件下载确认面板等待期间暂停 20s 自检
                    awaitingUserInput = true;
                    try {
                      await _presentFileDownloadSources(
                        userText: userText,
                        query: query,
                        fileType: fileType ?? 'file',
                        existingUserMsg: existingUserMsg,
                        existingPlaceholder: existingPlaceholder,
                      );
                    } finally {
                      awaitingUserInput = false;
                    }
                  }
                : null,
            onGenericDownload: hasDownloadPlugin
                ? (url, amsg) async {
                    answered = true;
                    await _reactGenericDownload(url, amsg);
                  }
                : null,
          );
          // A1（W6）：提问轮压制 answer——同一轮已出现 ask_user 时，answer 件
          // 不 dispatch（不落地、不入库），反问卡片是唯一产出。
          // TODO(R4): 随状态机删除。
          if (hasAskUserThisRound && type == 'answer') {
            _logger.warn(
                '[ReAct] A1: drop answer piece in ask-user round (question-only round)',
                cat: LogCat.react,
                tag: 'ReAct');
            continue;
          }
          // build93(P1)：answer 落盘前不得 break——answered 后仍放行被动件
          // （suggest/todo/memory_write，顺序无关），其余主动件丢弃并打点。
          // 修复 R1：suggest 排在 answer 后时被整段吞掉（日志实测 0 次渲染）
          if (answered &&
              type != 'suggest' &&
              type != 'todo' &&
              type != 'memory_write' &&
              type != 'memory_delete') {
            _logger.info('[ReAct] drop piece after answer: $type',
                cat: LogCat.react, tag: 'ReAct');
            continue;
          }
          // ---- v1.7.17：detail 标签（只读加载协议，无副作用）不经过 dispatch ----
          // 直接调契约层纯函数拿详情文本，复用 toolresult 通道注入，_injectedDetails 去重。
          if (type == 'plugin_detail' ||
              type == 'mcp_detail' ||
              type == 'skill_detail') {
            final String detailText;
            final String dedupKey;
            if (type == 'plugin_detail') {
              final name = p['name'] ?? '';
              detailText = resolvePluginDetail(name, enabledPlugins);
              dedupKey = 'plugin:$name';
            } else if (type == 'mcp_detail') {
              // build116：与 mcp_call 共用统一归一入口（三段式 mcp:id:tool 也能拆）。
              // 真机日志实锤：模型整串照抄目录 id → 旧实现 Detail not found →
              // 拿不到参数定义 → 更容易乱调。
              final target = normalizeMcpTarget(
                p['pluginId'] ?? '',
                p['tool'] ?? '',
                isKnownId: (id) => enabledPlugins.any((e) =>
                    e.metadata.kind.isRemote && e.metadata.id == id),
              );
              detailText = resolveMcpDetail(
                  target.pluginId, target.tool, enabledPlugins);
              dedupKey = 'mcp:${target.pluginId}.${target.tool}';
            } else {
              final name = p['name'] ?? '';
              detailText = resolveSkillDetail(name, enabledPlugins);
              dedupKey = 'skill:$name';
            }
            if (detailText.isNotEmpty && _injectedDetails.add(dedupKey)) {
              pc.addMessage(ChatMessage.create(
                conversationId: widget.conversation.id,
                role: MessageRole.user,
                content: '<toolresult kind="$type">$detailText</toolresult>',
              ));
              _logger.info(
                  '[ReAct] Injected detail $dedupKey (${detailText.length} chars)',
                  cat: LogCat.react,
                  tag: 'ReAct');
            } else if (detailText.isEmpty) {
              _logger.warn('[ReAct] Detail not found: $dedupKey',
                  cat: LogCat.react, tag: 'ReAct');
            }
            continue;
          }
          // ---- v1.7.39 build92：<suggest> 推荐后续问题 ----
          // 与 detail 标签同理不走 dispatch：纯 UI 状态提取到 assistantMsg.suggestions，
          // 由气泡渲染可点击推荐气泡（点击直接发送），不落库。
          if (type == 'suggest') {
            // N14（build94）：解析逻辑抽为纯函数 parseSuggestItems，与兜底补生成共用同一口径
            final items = parseSuggestItems(p['content'] ?? '');
            if (items.isNotEmpty) {
              assistantMsg.suggestions
                ..clear()
                ..addAll(items);
              if (mounted) setState(() {});
              _followBottomIfNeeded();
              _logger.info('[ReAct] Suggest: ${items.length} items',
                  cat: LogCat.react, tag: 'ReAct');
            }
            continue;
          }
          // ---- 核心：一行 dispatch，替换 317 行 if/else ----
          final attrs = Map<String, dynamic>.from(p);
          attrs['raw'] = rawResp;
          // E5（build94）：精准熔断——同一动作+同一参数指纹重复时先喂 is_error 再停
          const e5ActionTypes = {
            // build122：生成类动作纳入指纹去重（同轮重复生成同一提示词会被拦）
            'image_gen',
            'video_gen',
            'search',
            'mcp_call',
            'skill_call',
            'download',
            'install_skill',
            'get_location',
            'ip_locate',
            'query_quota',
            'log_query',
          };
          if (e5ActionTypes.contains(type)) {
            final fp = buildToolCallFingerprint(p);
            // build110（U9 日志实锤）：同轮同指纹去重——模型在思考文本里复述
            // 标签（「我输出 <log_query /> 标签」）会产生多个相同动作 piece，
            // 只执行第一次：防确认弹窗连弹 + E5 被叙述件触发误熔断
            if (!roundSeenActionFps.add(fp)) {
              _logger.info(
                  '[ReAct] dedupe: drop repeated action $fp in same round',
                  cat: LogCat.react,
                  tag: 'ReAct');
              continue;
            }
            final n = (toolRepeatCount[fp] ?? 0) + 1;
            toolRepeatCount[fp] = n;
            if (n >= 4) {
              _logger.warn(
                  '[ReAct] E5 circuit break: $fp repeated $n times — stopping loop (keep produced content)',
                  cat: LogCat.react,
                  tag: 'ReAct');
              pc.addMessage(ChatMessage.create(
                conversationId: widget.conversation.id,
                role: MessageRole.user,
                content: '<toolresult kind="$type" is_error="true">'
                    '${isZh ? '同一调用已重复 $n 次且没有新信息，循环已终止。' : 'Same call repeated $n times with no new info; loop terminated.'}'
                    '</toolresult>',
              ));
              _reactLoopStopRequested = true;
              break;
            }
            if (n == 3) {
              _logger.warn(
                  '[ReAct] E5 repeat intercept: $fp repeated 3 times — injecting is_error observation instead of executing',
                  cat: LogCat.react,
                  tag: 'ReAct');
              pc.addMessage(ChatMessage.create(
                conversationId: widget.conversation.id,
                role: MessageRole.user,
                content: '<toolresult kind="$type" is_error="true">'
                    '${isZh ? '该工具已被宿主停用：同参数已重复 3 次且全部失败，禁止再用相同参数重试。请立即改用替代方案（换工具、换参数，或基于已有信息直接给出 <answer>）。绝对不要在答案里编造带占位符（如 xxxx）的数据或链接——没有真实数据就明说拿不到。' : 'This tool has been disabled by the host: identical arguments repeated 3 times and all failed. Do NOT retry with the same arguments. Switch to an alternative (another tool/arguments) or answer with <answer> based on what you have. NEVER fabricate data or links containing placeholders (e.g. xxxx) in your answer; if you have no real data, say so.'}'
                    '</toolresult>',
              ));
              continue;
            }
          }
          if (!mounted) return;
          // build138（扫描 P2-3）：pc.mounted 是**构造时的快照**，而 setMounted()
          // 全库零调用点 ⇒ 退页后插件里那 ~18 处 `if (!mounted) return` 护栏全部失效
          // （它们读的是这个永远为 true 的字段）。这里把当前 pc 挂到 state 上，
          // 由 dispose() 统一 setMounted(false)，护栏才真正接得上执行点。
          _livePluginContext = pc;
          await registry.dispatch(context, pc, type, attrs);
          // build93(M5)：记忆写入成功，下一轮重建记忆块
          if (type == 'memory_write') {
            memDirty = true;
            memoryWriteDone = true;
          }
          if (type == 'search' || type == 'search_result') {
            assistantMsg.setLastReasoningPhase(
                'phase${round + 1}_$type', round + 1);
          }
          // 插件通过 setAnswered / finalizeAnswer 标志是否本轮结束
          if (pc.answered) {
            answered = true;
          }
          // build129：命中数先净化——超限值只可能是脏值（历史把「强制保存」
          // 编成 999999999 塞进 count），丢弃 + 告警，绝不写进气泡页脚。
          final saneSnapshot =
              ChatMessage.sanitizeSearchHits(totalSearchHitsSnapshot);
          if (totalSearchHitsSnapshot > saneSnapshot) {
            _logger.warn(
                '[ReAct] 丢弃异常搜索命中数 $totalSearchHitsSnapshot'
                '（合理上限 ${ChatMessage.maxSaneSearchHits}）——疑似上游借用了该字段',
                cat: LogCat.react,
                tag: 'ReAct');
          }
          if (saneSnapshot > 0) {
            assistantMsg.injectedWebSearchCount = saneSnapshot;
          }
          // 同步 pc 内维护的 mounted 回外层（防 mounted 不一致）
          final sanePcHits = ChatMessage.sanitizeSearchHits(pc.totalSearchHits);
          if (sanePcHits > 0) {
            assistantMsg.injectedWebSearchCount = sanePcHits;
          }
          // build93(P1)：answered 不再 break（上方守卫已丢弃主动件），
          // 仅当插件/限额请求停止时才中断遍历
          if (_reactLoopStopRequested) break;
        } // end for parsed
        // build115：内核流末收尾（未闭合块/残片按类型归位，默认不吞）
        if (kUseTypedKernel) consumeTyped(typedAdapter.flush());
        // A1（W6，build117 止血）：提问轮回退——本轮若有 answer 已通过任何路径
        // 写进气泡（流式显示 / dispatch），一律回退到本轮开始前的快照，
        // 清空流式缓冲、不保存。提问轮的唯一产出是反问卡片。
        // TODO(R4): 随状态机删除。
        if (hasAskUserThisRound) {
          if (answerStreamBuf.isNotEmpty) {
            _logger.warn(
                '[ReAct] A1: rollback ${answerStreamBuf.length} chars of streamed answer in ask-user round',
                cat: LogCat.react,
                tag: 'ReAct');
          }
          answerStreamBuf.clear();
          // build121：typed 缓冲一并清——提问轮的 typed answer 也不得落地
          // （否则兜底①/answer 件源覆盖会把已回退的答案又写回去）
          typedAnswerBuf.clear();
          typedAnswerDirty = false;
          lastAnswerStreamLen = 0;
          assistantMsg.content = contentBeforeRound;
          answered = false;
          if (mounted) setState(() {});
          _followBottomIfNeeded();
        }
        // ===== v1.7.38（A/C）：轮末双兜底 =====
        // A1（W6）：提问轮两道兜底全部关闭——本轮不落地任何最终答案。
        // G32（build124）：工具轮同样全关——本轮是过渡轮，答案在工具回灌之后
        // （真机：工具轮被兜底①用 68 字符 JSON 参数定稿，循环当场结束）。
        // TODO(R4): 随状态机删除。
        // ① 流式 answer 缓冲非空但解析未产出 answer 片段（闭合丢失/dispatch 异常等）
        //    → 直接用流式内容落地，不让已到手的答案凭空消失（实测"你好"场景）
        if (!answered &&
            !_reactLoopStopRequested &&
            !hasAskUserThisRound &&
            !roundIsToolRound) {
          // build121：兜底①的答案源在结构化模式下切到 typed 缓冲——
          // answerStreamBuf 来自旧链状态机（无 G3 判别），typedAnswerBuf
          // 已按「字面提及 vs 真包裹」结算过。
          final streamedAnswer = (kUseTypedKernel
                  ? typedAnswerBuf.toString()
                  : answerStreamBuf.toString())
              .trim();
          final hasAnswerPiece = parsed.any((p) => p['type'] == 'answer');
          // G35（build124）：兜底源若是工具参数/标签残片，**不是答案**——
          // 宁可这轮不落地（下一轮模型会重说），也不把 JSON 当结论定稿。
          final streamedIsControl =
              AnswerFinalizer.isControlFragment(streamedAnswer);
          if (streamedIsControl && streamedAnswer.isNotEmpty) {
            _logger.warn(
                '[ReAct] G35 stream fallback source is a control fragment'
                ' (${streamedAnswer.length} chars) — refusing to finalize',
                cat: LogCat.react,
                tag: 'ReAct');
          }
          // G38（build129）：**终态闸门**——候选文本"配不配当结论"。
          //
          // 真机实证（nexus_export_2026-09-19T10-05 / Round 4）：轮末打点是
          // `typedAnswerBuf=0 / typedThinkingBuf=312`（打点在 flush 之前，所以看不出
          // 异常），模型只写了中文思考 + 英文套话「I'm sorry, but the video
          // generation tool …」且**没闭合 `<answer>`**；内核流末 flush 把这段思考态
          // 文本当 answer 件放出 → 这里把它定稿成了用户可见的结论。
          //
          // 两条判据（任一命中即不定稿，且**不静默丢弃**：文本回思考块）：
          //  ① 候选来自「未闭合答案段的 flush」且本轮没有真正的 answer 片段
          //     = 话没写完，不构成结论（**与语言无关**，两种界面都生效）；
          //  ② 候选是英文占位/拒答套话，且本轮确有思考内容（= 内容判为思考态）。
          //     ②额外要求**界面语言为中文**：中文界面下「中文思考 + 英文道歉」是
          //     跨语言串味的产物；英文界面里英文道歉可能就是模型的真实（虽无用）
          //     回答，对它做二次判定等于误杀用户本该看到的文本——宁可漏判。
          final typedFromUnclosedFlush =
              kUseTypedKernel && typedAdapter.answerFromUnclosedFlush;
          final String? g38Reason = streamedAnswer.isEmpty
              ? null
              : (typedFromUnclosedFlush && !hasAnswerPiece)
                  ? 'source is an UNCLOSED <answer> segment (kernel flush)'
                  : (isZh &&
                          typedThinkingBuf.isNotEmpty &&
                          AnswerFinalizer.isPlaceholderTemplate(streamedAnswer))
                      ? 'source is a placeholder/refusal template while the round has thinking'
                      : null;
          if (g38Reason != null) {
            _logger.warn(
                '[ReAct] G38 terminal gate: refusing to finalize ${streamedAnswer.length}'
                ' chars — $g38Reason',
                cat: LogCat.react,
                tag: 'ReAct');
            assistantMsg.appendLastThinking('\n$streamedAnswer\n');
            typedAnswerBuf.clear();
            typedAnswerDirty = false;
            if (mounted) setState(() {});
          }
          if (!hasAnswerPiece &&
              streamedAnswer.isNotEmpty &&
              !streamedIsControl &&
              g38Reason == null) {
            // G36（build124）：来源打点写清「取的是哪条缓冲」，不再用开关状态冒充
            const streamSrcTag = kUseTypedKernel
                ? 'stream-fallback(typed-buf)'
                : 'stream-fallback(legacy-buf)';
            _logger.warn(
                '[ReAct] No <answer> piece parsed but stream buffer has ${streamedAnswer.length} chars'
                ' (source=$streamSrcTag) — finalizing from stream buffer',
                cat: LogCat.react,
                tag: 'ReAct');
            // build93(S3)：截断残段落地时附加可见标记，不冒充完整结论
            // O7-2（build96）：兜底落地同样过控制标签净化
            final cleanStreamed = stripControlTags(streamedAnswer);
            // build121（冻结令）：结构化模式跳过 L1/W4 词表链（与 finalize 主口
            // 同口径——类型层已分离，词表不再驱动落库）；兼容模式维持原链。
            final ({String clean, String stripped}) scrubbedStream;
            if (kUseTypedKernel) {
              final noTags = AnswerFinalizer.stripTags(cleanStreamed);
              final (cleanOnly, fakeUrls) =
                  AnswerFinalizer.scrubPlaceholderUrls(noTags);
              scrubbedStream = (clean: cleanOnly, stripped: fakeUrls);
            } else {
              // L1（build107）：流式兜底口同样剥头部过程话术
              // build112：统一走唯一 finalize 出口（AnswerFinalizer）
              scrubbedStream = AnswerFinalizer.finalize(cleanStreamed);
            }
            if (scrubbedStream.stripped.isNotEmpty) {
              _logger.warn(
                  '[ReAct] finalize stripped ${scrubbedStream.stripped.length} chars from stream fallback (source=$streamSrcTag)',
                  cat: LogCat.react,
                  tag: 'ReAct');
              assistantMsg.appendLastThinking('\n${scrubbedStream.stripped}\n');
            }
            // build164（#82 取证 ③）：这里**不再**自己拼截断标记。旧写法有三个毛病：
            // 只有这一支贴得上一句标记（经插件 dispatch 正常定稿那一支完全不贴）、
            // 中英界面都贴中文、句子不含"被什么限制住"。现在"被长度上限截断"这件事
            // 由下面那条**统一**的 [applyTruncationNotice] 分支负责（同一语义只此一处，#62）。
            assistantMsg.content = scrubbedStream.clean;
            unawaited(_throttledSaveAssistantContent(
                storage, assistantMsg, assistantMsg.content,
                force: true));
            answered = true;
          }
        }
        // ② 裸文本兜底：整段响应不含任何协议标签（弱模型直接回话），
        //    解析全成 thinking、无 answer 无动作 → 把内容当答案，不再空转下一轮
        //    G32（build124）：工具轮不适用——本轮有动作，答案在下一轮。
        if (!answered &&
            !_reactLoopStopRequested &&
            !hasAskUserThisRound &&
            !roundIsToolRound) {
          const actionTypes = {
            // build122：生成类动作——有它们就不算「纯裸文本」，不该走裸文本兜底
            'image_gen',
            'video_gen',
            'search',
            'mcp_call',
            'skill_call',
            'download',
            'ask_user',
            'install_skill',
            'self_check',
            'todo',
            'memory_write',
            'get_location',
            'ip_locate',
            'query_quota',
            'log_query',
          };
          // build138（同型第 7 次）：这里的两张名单原本是**手写**的，
          // 新增动作（memory_delete、ws_make_file）就会漏——漏了 hasAnyTag 侧
          // 表现为「模型打了标签却被当裸文本兜底定稿」，漏了 hasAction 侧表现为
          // 「工具轮走了裸文本」。改成由 react_parser 的唯一真相源派生，
          // 以后只往 kReActTagNames 加，这里不会再脱节。
          final hasAction = parsed.any((p) =>
              actionTypes.contains(p['type']) ||
              kToolTagNames.contains(p['type']));
          final hasAnyTag = RegExp(
            '</?(${kReActTagNames.join('|')})\\b',
            caseSensitive: false,
          ).hasMatch(rawResp);
          if (!hasAction && !hasAnyTag) {
            // build115（typed 内核最小切片）：裸文本兜底的答案来源切换。
            //
            // 旧行为（kUseTypedKernel=false）：bare = parsed 里全部 thinking 的
            // 拼接——而 parsed 来自 reasoning_content + content 的**混流文本**，
            // 于是「模型的中文思考（reasoning）」被当成答案定稿 → 用户所见
            // 「结论混着大段思考过程」（实测 28 批中 26 批涉及此类）。
            //
            // 新行为（true）：bare = **content 段**（模型给用户的正文，
            // 与 reasoning 物理分开累积）→ 思考再也不会被当答案。
            // 若 content 段为空（模型只输出思考就停了），bare 空 → 不进兜底、
            // 交给后续轮/O9 守卫（正确语义：没答案就不该定稿）。
            final bare = kUseTypedKernel
                ? typedAnswerBuf.toString().trim()
                : parsed
                    .where((p) => p['type'] == 'thinking')
                    .map((p) => p['content']!)
                    .join('\n')
                    .trim();
            if (kUseTypedKernel) {
              _logger.info(
                  '[ReAct] typed-kernel: bare-text fallback source = content-answer '
                  'segment (${typedAnswerBuf.length} chars answer / '
                  '${typedThinkingBuf.length} chars thinking-in-content / '
                  '$typedToolCount tools; reasoning excluded)',
                  cat: LogCat.react,
                  tag: 'ReAct');
            }
            if (AnswerFinalizer.isControlFragment(bare)) {
              // G35（build124）：整段就是一个 JSON 参数体 / 标签残片 → 不是答案。
              // 真机：mcp 参数 JSON 漏进答案缓冲后正是从这里被定稿的。
              _logger.warn(
                  '[ReAct] G35 bare-text source is a control fragment (${bare.length} chars) — refusing to finalize',
                  cat: LogCat.react,
                  tag: 'ReAct');
            } else if (bare.length >= 20) {
              // O11（build98）：整段纯独白（无用户语言锚点，O4 剥不动）不落
              // 答案——归入 thinking，交给后续轮/O9 零产出守卫处理。
              // G38（build129）：占位/拒答套话 + 未闭合答案段的 flush 产物同办
              //（判据见 react_parser / answer_finalizer 的 G38 段）。
              final bareFromUnclosedFlush =
                  kUseTypedKernel && typedAdapter.answerFromUnclosedFlush;
              final g38Bare = typedThinkingBuf.isNotEmpty &&
                  ((isZh && AnswerFinalizer.isPlaceholderTemplate(bare)) ||
                      bareFromUnclosedFlush);
              // build168（BUGSCAN_build166 ①-1 修法①）：判据从「整段一票制」
              // 改成**逐行**——计划语行剥回思考面板，结论行照常定稿。
              // 旧行为两头都错：任何一行像给用户看的文字 ⇒ 整段放行（166 那轮
              // 一条中文标题替 7 行英文计划背书），反之一处线索 ⇒ 整段丢弃。
              // 判据只住 react_parser 的 scanMonologue/isMonologueLine 一处。
              final monoScan = scanMonologue(bare, isZh: isZh);
              final monoLeftText =
                  monoScan.hasMonologue ? monoScan.keptText : bare;
              if (monoScan.looksPurelyLikeMonologue ||
                  monoLeftText.trim().isEmpty ||
                  g38Bare) {
                _logger.warn(
                    '[ReAct] ${g38Bare ? 'G38 terminal gate' : 'O11'} bare-text'
                    '${g38Bare ? ' (placeholder/unclosed answer)' : ' looks like pure monologue'},'
                    ' ${bare.length} chars — NOT finalizing as answer',
                    cat: LogCat.react,
                    tag: 'ReAct');
                assistantMsg.appendLastThinking('\n$bare\n');
                typedAnswerBuf.clear();
                typedAnswerDirty = false;
                if (mounted) setState(() {});
              } else {
              // build168：剥下来的计划语一行都不丢——原样回思考面板
              if (monoScan.hasMonologue) {
                _logger.warn(
                    '[ReAct] build168 per-line monologue gate: ${monoScan.dropped.length} '
                    'planning line(s) moved to thinking panel, ${bare.length} -> '
                    '${monoLeftText.length} chars of answer',
                    cat: LogCat.react,
                    tag: 'ReAct');
                assistantMsg
                    .appendLastThinking('\n${monoScan.droppedText}\n');
                if (kUseTypedKernel) {
                  typedAnswerBuf
                    ..clear()
                    ..write(monoLeftText);
                  typedAnswerDirty = false;
                  if (mounted) setState(() {});
                }
              }
              // O4（build95）：裸文本常是「英文内心独白 + 中文正文」，整段当答案
              // 会让用户在气泡前看到一串英文推理，且脏答案回填历史/喂 suggest。
              // 落地前以会话语言为锚剥离异语言独白前缀；剥掉的归入 reasoningStep。
              final o4Clean = stripForeignMonologue(monoLeftText, isZh: isZh);
              if (o4Clean.length != monoLeftText.length) {
                final cutIdx = monoLeftText.indexOf(o4Clean);
                final monologue = cutIdx > 0
                    ? monoLeftText.substring(0, cutIdx).trim()
                    : '';
                if (monologue.isNotEmpty) {
                  assistantMsg.appendLastThinking('\n$monologue\n');
                }
                _logger.warn(
                    '[ReAct] O4 stripped foreign monologue prefix: ${monoLeftText.length} -> ${o4Clean.length} chars',
                    cat: LogCat.react,
                    tag: 'ReAct');
              }
              // O7-2（build96）：裸文本兜底同样过控制标签净化
              final cleaned = stripControlTags(o4Clean);
              // L1（build107）：裸文本口剥头部过程话术（第三道落地口）
              // build112：统一走唯一 finalize 出口（AnswerFinalizer）
              final scrubbedBare = AnswerFinalizer.finalize(cleaned);
              if (scrubbedBare.stripped.isNotEmpty) {
                _logger.warn(
                    '[ReAct] L1 stripped ${scrubbedBare.stripped.length} chars of leading meta talk from bare-text fallback',
                    cat: LogCat.react,
                    tag: 'ReAct');
                assistantMsg.appendLastThinking('\n${scrubbedBare.stripped}\n');
              }
              _logger.warn(
                  '[ReAct] Bare-text response (no protocol tags), ${scrubbedBare.clean.length} chars — finalizing as answer instead of idling next round',
                  cat: LogCat.react,
                  tag: 'ReAct');
              assistantMsg.content = scrubbedBare.clean;
              unawaited(_throttledSaveAssistantContent(
                  storage, assistantMsg, scrubbedBare.clean,
                  force: true));
              answered = true;
              }
            }
          }
        }
        // ===== build164（#82 取证 ③）：被 maxTokens 打满而收口的轮次，事实必须看得见 =====
        // 判据刻意只用「<answer> 开到流末都没闭合」（[isAnswerTruncated]），比上面那条
        // 更宽的 streamTruncated 窄：流末残留半截 `<thin`、而 answer 早已正常闭合的轮次，
        // 正文是完整的，给它贴"被截断"等于说谎。
        // 为什么原来看不见这件事：N11 只自动续写**一次**（防无限续拉），续写完仍被打满、
        // 或这一轮直接经插件 dispatch 定稿的，旧链一句提示都不给，半截话就冒充结论落库
        // ——build164 队列里用户那句「老是中断」的取证正是这条（maxTokens 4096 打满）。
        final answerTruncatedThisRound = isAnswerTruncated(
            inAnswerBlock: ansState[0], rawResp: rawResp);
        if (answerTruncatedThisRound &&
            !_reactLoopStopRequested &&
            !roundIsToolRound &&
            !hasAskUserThisRound) {
          final marked = applyTruncationNotice(assistantMsg.content,
              // build171（同源）：`0` 的意思是"本应用没发这个字段"，文案会照实写
              // 「未传(上游默认)」。但 **Anthropic 那一支从 171 起永远发了数**
              // （未配置时发 kAnthropicUnsetOutputCeiling=8192），所以这一路再无条件走
              // `?? 0`，就会在被真截断的那一轮写下"未传"——同一轮里请求体发 8192、
              // 界面说未传。api_service 侧 171 已经修，这里是编排/ReAct 侧的同一个残口。
              maxTokens: resolveChatProtocol(reactApiCfg) ==
                      ChatProtocol.anthropicMessages
                  ? anthropicMaxTokens(configured: reactApiCfg.maxTokens)
                  : (requestMaxTokens(configured: reactApiCfg.maxTokens) ?? 0),
              isZh: isZh);
          if (marked != assistantMsg.content) {
            assistantMsg.content = marked;
            unawaited(_throttledSaveAssistantContent(
                storage, assistantMsg, marked,
                force: true));
            _logger.warn(
                '[ReAct] 本轮 <answer> 未闭合、被长度上限截断（maxTokens=$reactMaxTokensNote）'
                ' —— 已在正文标注，不静默收口 (answered=$answered, continuationUsed=$n11ContinuationUsed)',
                cat: LogCat.react,
                tag: 'ReAct');
            if (mounted) setState(() {});
            _followBottomIfNeeded();
          }
        }
        // ===== O9（build96）：零产出空转守卫 =====
        // 连续零产出轮（无 answer、无主动作）：第 3 轮注入强约束，第 4 轮仍零产出
        // 则把最近一轮面向用户的内容（O4 剥独白 + O7 剥控制标签后）强制落成答案；
        // 无内容可落时给出可见提示，不再空转到 maxRounds。
        if (!answered && !_reactLoopStopRequested) {
          if (isZeroOutputRound(parsed,
              answerStreamLen: answerStreamBuf.length)) {
            zeroOutputStreak++;
            _logger.warn(
                '[ReAct] O9 zero-output round ${round + 1}: streak=$zeroOutputStreak',
                cat: LogCat.react,
                tag: 'ReAct');
            if (zeroOutputStreak == 3) {
              workingMessages.add(ChatMessage.create(
                conversationId: widget.conversation.id,
                role: MessageRole.user,
                content: buildZeroOutputConstraintMessage(zeroOutputStreak,
                    isZh: isZh),
              ));
              _logger.warn('[ReAct] O9 strong constraint injected (streak=3)',
                  cat: LogCat.react, tag: 'ReAct');
            } else if (zeroOutputStreak >= 4) {
              final bare = parsed
                  .where((p) => p['type'] == 'thinking')
                  .map((p) => p['content']!)
                  .join('\n')
                  .trim();
              if (bare.length >= 20) {
                // build112：O9 强制收尾口也收敛到唯一 finalize 出口
                //（原实现自己拼 stripControlTags+stripForeignMonologue，
                // 少一层 L1 头部话术剥离 —— 这是第 6 个各写一套的出口）
                final cleaned = AnswerFinalizer.finalize(
                        stripForeignMonologue(bare, isZh: isZh))
                    .clean;
                // build164（#82）：删掉「多为中转站空流/502 所致」这句猜测。用户用的是
                // **官方端点**（api.deepseek.com），这句把责任指向中转站、害他白排查一轮
                // （原话「我用的是官方的，不是中转站的」）；而空流/502 本来就在传输层抛错、
                // 走不到这一支。改成只说这份数据能证实的事实（连续多轮只有 thinking）。
                assistantMsg.content = isZh
                    ? '$cleaned\n\n> ⚠️ 模型连续多轮只思考未作答（本轮没有任何动作或结论落地），已强制收尾。点本条消息下方的 ↻ 可重试。'
                    : '$cleaned\n\n> ⚠️ The model kept thinking without answering across several rounds (no action and no conclusion landed in these rounds); force-finalized. Tap ↻ below to retry.';
              } else {
                // build103（I1）：明确指出可能原因 + 指向真实存在的 ↻ 重试按钮
                //（气泡操作行常驻该按钮，canRetry 在流式结束后即可用）
                // build164（#82）：同上，不再猜"中转站空流/502"。
                assistantMsg.content = isZh
                    ? '⚠️ 模型连续多轮只思考，未产出答案（这几轮里没有任何动作或结论落地）。\n\n点本条消息下方的 ↻ 按钮重试；若反复出现，请换问法或稍后再试。'
                    : '⚠️ The model kept thinking without producing an answer (no action and no conclusion landed in these rounds).\n\nTap the ↻ button below this message to retry; if it keeps happening, rephrase or try again later.';
              }
              unawaited(_throttledSaveAssistantContent(
                  storage, assistantMsg, assistantMsg.content,
                  force: true));
              _logger.warn(
                  '[ReAct] O9 force-finalized after $zeroOutputStreak zero-output rounds',
                  cat: LogCat.react,
                  tag: 'ReAct');
              // build147：放弃轮不再补推荐追问（原来只置 answered，N14 会拿这段
              // 报错文案当【回答】去生成 3 条"接下来问什么"）。
              roundGivenUp = true;
              answered = true;
            }
          } else {
            zeroOutputStreak = 0;
          }
        }
        // ===== G39（build129）：连续无结论轮收敛（与 O9 互补的第二条闸门）=====
        // 判据、阈值、文案都在 react_parser（纯函数可单测）；这里只做计数与落地。
        // 位置必须在两道轮末兜底之后：兜底成功即 answered=true，不该再算空转。
        if (answered) {
          inconclusiveStreak = 0;
          // build164（#82）：动作账本与 streak 同步清零——放弃文案报的必须是
          // "最近这一段连续空转"，不能把上一轮之前的动作也数进去。
          inconclusiveActions.clear();
        } else if (!_reactLoopStopRequested) {
          final inconclusive = isInconclusiveRound(parsed,
              answered: answered, answerStreamLen: answerStreamBuf.length);
          if (!inconclusive) {
            inconclusiveStreak = 0;
            inconclusiveActions.clear();
          } else {
            inconclusiveStreak++;
            // 本轮最后一个非 thinking/answer 的动作类型 → 收敛提示给出**具体**可行动项
            // （真机场景是「反复问怎么传 model 参数」，提示要落到设置页而不是空泛安慰）
            String? roundLastAction;
            for (final p in parsed) {
              final t = p['type'];
              // build164（#82）：`progress` 是给用户看的一句话、不是动作，必须排除——
              // 否则阶段小结算进动作账本，放弃文案会报出「最后一次动作是 progress」
              // 这种没有信息量的话（而那正是用户要避免的形态）。
              if (t != null &&
                  t != 'thinking' &&
                  t != 'answer' &&
                  t != kProgressTagName) {
                roundLastAction = t;
              }
            }
            inconclusiveActions.add(roundLastAction ?? 'none');
            _logger.warn(
                '[ReAct] G39 inconclusive round ${round + 1}: streak=$inconclusiveStreak'
                ' (lastAction=${roundLastAction ?? 'none'})',
                cat: LogCat.react,
                tag: 'ReAct');
            if (inconclusiveStreak == kInconclusiveHintStreak) {
              workingMessages.add(ChatMessage.create(
                conversationId: widget.conversation.id,
                role: MessageRole.user,
                content: buildInconclusiveConstraintMessage(
                  inconclusiveStreak,
                  isZh: isZh,
                  lastAction: roundLastAction,
                ),
              ));
              _logger.warn(
                  '[ReAct] G39 wrap-up constraint injected (streak=$inconclusiveStreak)',
                  cat: LogCat.react,
                  tag: 'ReAct');
            } else if (inconclusiveStreak == kInconclusiveProgressStreak) {
              // build164（#82 核心）：**强制小结轮**。到第 4 轮不再只是催它收口，
              // 而是要求它先输出一句 <progress> 阶段小结（已掌握什么、还缺什么），
              // 然后**允许继续查**。用户要的就是这句人话出现在正文可见位置；
              // 旧链在这里什么都不给用户，一路憋到 force 那一支甩一段模板报错。
              workingMessages.add(ChatMessage.create(
                conversationId: widget.conversation.id,
                role: MessageRole.user,
                content: buildInconclusiveProgressMessage(
                  inconclusiveStreak,
                  isZh: isZh,
                  lastAction: roundLastAction,
                ),
              ));
              _logger.warn(
                  '[ReAct] G39 progress-note constraint injected (streak=$inconclusiveStreak)',
                  cat: LogCat.react,
                  tag: 'ReAct');
            } else if (inconclusiveStreak >= kInconclusiveForceStreak) {
              // 强制收敛：停搜 + 落地「明确事实 + 可行动项」（不现编结论）
              //
              // build164（#82）：**不再整条覆盖正文**。旧那一支把 content 直接赋值成
              // 放弃文案的返回值，本轮已经产出、用户已经看到的可见内容就被原地抹掉
              // （旧形状的真机凭据就是 1.7.106+163 那份 23:17 日志：那一段模板报错
              // 直接盖掉了本轮已有的可见内容）。
              // 新口径：保留可见内容、在其后追加放弃说明，
              // 本轮什么都没有时才只落放弃说明。
              final merged = composeGiveUpContent(
                assistantMsg.content,
                buildInconclusiveGiveUpMessage(
                  inconclusiveStreak,
                  isZh: isZh,
                  lastAction: roundLastAction,
                  recentActions: List<String>.of(inconclusiveActions),
                ),
              );
              assistantMsg.content = merged;
              unawaited(_throttledSaveAssistantContent(
                  storage, assistantMsg, merged,
                  force: true));
              // 本轮工具已执行完、结果已在 workingMessages 里；置位后不再进入下一轮。
              // 注：该标志在 catch 分支被当作「用户停止」看待（info 级 + 不覆盖已有
              // 正文）——此处 answers 已写定，即便后面抛异常也不会污染这条文案；
              // 同时它会让 N14 suggest 兜底跳过（放弃轮不该再推荐追问）。
              _reactLoopStopRequested = true;
              roundGivenUp = true;
              answered = true;
              _logger.warn(
                  '[ReAct] G39 force-converged after $inconclusiveStreak inconclusive rounds'
                  ' (kept ${merged.length} chars, actions=${inconclusiveActions.join(',')})',
                  cat: LogCat.react,
                  tag: 'ReAct');
            }
          }
        }
        // ===== v1.4.5：ReAct 每轮解析完毕 → 节流保存（防崩溃丢思考步骤 + 已生成 answer） =====
        // build93(M3)：空口承诺拦截——答案声称"已记住/已记录"但本轮没有真实
        // memory_write 落库，打点+提示用户（日志实测模型常在 thinking 里假写标签）
        if (answered && !memoryWriteDone) {
          final ans = assistantMsg.content;
          final promised = RegExp(r"已(经)?(记住|记录|记下来|存下)|记下了|已保存到记忆|remembered|noted down|saved to memory",
                  caseSensitive: false)
              .hasMatch(ans);
          if (promised) {
            _logger.warn(
                '[ReAct] false memory promise detected: answer claims remembered but no memory_write executed',
                cat: LogCat.react,
                tag: 'ReAct');
            if (mounted) {
              AppSnackBar.showSnackBar(context, 
                SnackBar(
                  content: Text(isZh
                      ? '⚠️ AI 声称已记住，但未实际写入记忆（可能放错了标签位置）'
                      : '⚠️ AI claimed to remember but no memory was written'),
                  duration: const Duration(seconds: 4),
                ),
              );
            }
          }
        }
        // A1（W6，build117 止血）：记录本轮是否为提问轮，供轮末兜底判定——
        // 循环退出时若最后一轮是提问轮，maxRounds 兜底不得把它当结论落地。
        // TODO(R4): 随状态机删除。
        if (hasAskUserThisRound) lastRoundWasAskUser = true;
        unawaited(_throttledSaveAssistantContent(
            storage, assistantMsg, assistantMsg.content));
        if (answered || _reactLoopStopRequested) {
          // O5（build95）：定稿即停自检定时器（原来要等 finally 才 cancel，
          // 答完后的空窗期仍可能再注入一条自检）
          if (answered) checkTimer?.cancel();
          break;
        }
      } // end for rounds

      // ---- 兜底：到最后一轮还是没 <answer> → 强制取最后一个 assistant 消息的答案
      if (!answered) {
        if (_reactLoopStopRequested) {
          // 用户主动终止 → 取最近一条 assistant 内容
          ChatMessage? lastWorking;
          // B-026：下限必须是 runStart（本轮起点）——本轮各轮 rawResp 虽已回写
          //（B-027），仍不得越过本轮捞历史对话的结论（I4 只在 catch 分支修了 1301 一处）。
          for (int i = workingMessages.length - 1; i >= runStart; i--) {
            final m = workingMessages[i];
            if (m.role == MessageRole.assistant && m.content.isNotEmpty) {
              lastWorking = m;
              break;
            }
          }
          final fallback = lastWorking?.content ?? '';
          final lastAnswer = _extractFirstAnswer(fallback);
          // build155：这一句以前无论如何都写"用户已终止思考"，而走到这里的
          // 还有 MCP 调用触顶与 E5 熔断两条**系统自己决定停**的路 ——
          // 那句假话会跟着落库，留在用户的聊天记录里。文案按"谁停的"分岔，
          // 判据与理由见 `lib/utils/stop_round.dart` 的 `stopNote`。
          assistantMsg.content = lastAnswer.isNotEmpty
              ? '$lastAnswer\n\n${stopNote(userStopped: _reactLoopUserStopped, hasContent: true, isZh: isZh)}'
              : stopNote(
                  userStopped: _reactLoopUserStopped,
                  hasContent: false,
                  isZh: isZh);
          // ===== v1.4.5：ReAct 用户终止兜底 answer → 强制保存 =====
          unawaited(_throttledSaveAssistantContent(
              storage, assistantMsg, assistantMsg.content,
              force: true));
          _logger.info(
              '[ReAct] Loop stopped at round end by '
              '${_reactLoopUserStopped ? 'user' : 'an internal limit'}',
              cat: LogCat.react, tag: 'ReAct');
        } else {
          ChatMessage? lastWorking;
          // B-026：下限必须是 runStart（本轮起点）——本轮各轮 rawResp 虽已回写
          //（B-027），仍不得越过本轮捞历史对话的结论（I4 只在 catch 分支修了 1301 一处）。
          for (int i = workingMessages.length - 1; i >= runStart; i--) {
            final m = workingMessages[i];
            if (m.role == MessageRole.assistant && m.content.isNotEmpty) {
              lastWorking = m;
              break;
            }
          }
          final fallback = lastWorking?.content ?? '';
          final lastAnswer = _extractFirstAnswer(fallback);
          // A1（W6，build117 止血）：若最后一轮是提问轮，不得把该轮的 answer
          // 当结论捞回来落地——反问轮的唯一产出是反问卡片，这里只给提示文案。
          // TODO(R4): 随状态机删除。
          assistantMsg.content = lastAnswer.isNotEmpty && !lastRoundWasAskUser
              ? lastAnswer
              : (isZh
                  ? '（抱歉，达到最大思考轮次（$maxRounds 轮）仍未得出最终回答。${isAuto ? "可在 20 秒确认弹窗里手动终止，或" : ""}在设置中把思考程度调高后重试。）'
                  : '(Sorry, reached the max thinking rounds ($maxRounds) without a final answer. ${isAuto ? "You can stop manually in the 20s confirm dialog, or " : ""}raise the thinking level in Settings and retry.)');
          _logger.warn(
              '[ReAct] Reached max rounds without <answer> tag, used fallback',
              cat: LogCat.react,
              tag: 'ReAct');
        }
        assistantMsg.injectedWebSearchCount =
            assistantMsg.injectedWebSearchCount > 0
                ? assistantMsg.injectedWebSearchCount
                : 0;
        assistantMsg.showStaleFootnote =
            assistantMsg.injectedWebSearchCount == 0;
      }

      // ---- N14（build94）：suggest 兜底补生成 ----
      // 模型给了 answer 但没给 <suggest> 时，追问区会空白；
      // 这里做一次独立轻量生成补齐（失败静默，绝不影响已定稿的答案）。
      if (needsSuggestFallback(
        answered: answered,
        stopRequested: _reactLoopStopRequested,
        answerContent: assistantMsg.content,
        suggestions: assistantMsg.suggestions,
        // A4（W7）：提问轮不触发推荐——反问停留期不得用 thinking 原文当
        // 【回答】补出无关推荐（真机日志实锤）。
        hasAskUserThisRound: lastRoundWasAskUser,
        // build147：O9/G39 的强制收尾轮不补推荐（那是一条报错，不是一次回答）。
        giveUpThisRound: roundGivenUp,
      )) {
        // O6（build95）：suggest 兜底转后台——原实现 await 在 finally 之前，
        // 占着 _isStreaming 生成态，用户下一条消息被阻塞到 suggest 跑完。
        // 现在 unawaited 立即放行 finally 收尾；suggest 成功后自行落库+刷新。
        // generation 守卫：用户已发新消息（_reactGeneration 已递增）时，
        // 入口的 stopGeneration(scope:) 会杀掉这条流，此处双保险直接丢弃结果。
        final suggestGen = _reactGeneration;
        unawaited(_fallbackGenerateSuggestions(
          apiSvc,
          userMsg,
          assistantMsg,
          isZh,
          onUsage: (u) => reactUsage = reactUsage.merge(u),
        ).then((_) async {
          if (!mounted || _reactGeneration != suggestGen) return;
          // B-032：代次没变不代表消息还在——删除/撤回不递增 _reactGeneration，
          // 若用户在这几秒窗口内删掉/撤回了这条回复，下面的 saveMessage（按 id replace）
          // 会把刚删掉的行重新插回 DB（重进会话「复活」，撤回场景还会留下孤儿气泡）。
          if (!_isMessageAlive(assistantMsg.id)) return;
          // 兜底流自带 usage，合并后补齐 finally 里已保存过的 token 字段
          assistantMsg.promptTokens = reactUsage.promptTokens;
          assistantMsg.completionTokens = reactUsage.completionTokens;
          assistantMsg.totalTokens = reactUsage.totalTokens;
          await _persistRoundAssistant(storage, assistantMsg);
          if (mounted) setState(() {});
              _followBottomIfNeeded();
        }));
      }
    } catch (e, st) {
      // v1.7.38（E）：用户主动停止（流被 stopFlag 关闭抛 ClientException 等）不算崩溃——
      // 记 info 而非 error，写"已终止"进度文案而非 ❌ 错误文案（后者会留在会话历史污染下轮上下文）
      // build158（用户 07:19:55 那份导出）：旧判据是
      // `_reactLoopStopRequested || e.contains('Connection closed') || …`
      // —— 把"网络断了"当成"用户按了停止"。同毫秒里 api 层刚写完
      // 「ClientException during streamChat（非本端关闭）」，这里却写
      // 「Loop stopped by user」，两层各说一套；更糟的是这一支不设 `reactLoopError`，
      // 于是 finally 那次 `onResearchEnd(error: null, quiet: false)` 在灵动岛上
      // 写成「AI 思考 · 已完成」，而那一轮其实被断在中途（49 秒收了 747 个 chunk）。
      // 现在三种收尾分开认，判据本身是纯函数（`classifyStreamEnd`）。
      // build165：这次中止**不是**"用户按了停止"，所以判据走 `leftAppAbortCarried`
      // （轮次戳，住在 `drop_continue.dart`），`_reactLoopStopRequested` 一个字都没动 ——
      // build158 修的正是"把掉线谎报成用户停止"，反过来把本端收起说成用户停止是同一个谎
      // 的另一个方向（那条假话还会跟着落库，留在用户的聊天记录里）。
      final endKind = classifyStreamEnd(
        stopRequested: _reactLoopStopRequested,
        userStopped: _reactLoopUserStopped,
        errorText: e.toString(),
        leftAppAborted: leftAppAbortCarried(
            abortedRound: _leftAppAbortRound, round: _reactRound),
      );
      final streamClosed = endKind != StreamEndKind.other;
      // 「这一轮到底收到了什么正文」的三个来源，取值顺序**只这一处**实现：
      // 气泡已落的正文 → 本轮（runStart 之后）最后一条 assistant 结论 → 还整段停在
      // 流缓冲里的当轮正文（build162 补的第三源）。build165 的退后台分支与对端掉线
      // 分支共用它 —— 这段顺序复制第二份，两条路的"有没有落点"就会各自漂移。
      String collectReceivedAnswer() {
        final direct = assistantMsg.content.trim().isNotEmpty
            ? assistantMsg.content
            : _extractFirstAnswer(
                _lastRoundAssistantContent(workingMessages, runStart));
        if (direct.trim().isNotEmpty) return direct;
        return stripControlTags(partialRoundAnswer());
      }

      if (streamClosed) {
        switch (endKind) {
          case StreamEndKind.networkDropped:
            // 与 api 层那行「非本端关闭」同一口径；级别 warn：它不是崩溃，
            // 但也没有交付完整答案，不能再报成"用户自己停的"。
            _logger.warn('[ReAct] 流被对端关闭（非用户停止）：$e',
                cat: LogCat.react, tag: 'ReAct');
            // 这一行就是"岛不再谎报已完成"的全部机制：交给 finally 分出口。
            // build161 下方若判成"自动续"会把它收回 —— 续写进行中 ✗ 是假故障。
            reactLoopError = e;
            dropReceived = collectReceivedAnswer();
            // build167：「有没有可续的内容」从"只认正文"改成"**正文或思考落点**"
            // （判据一份都在 `drop_continue.dart` 的 `decideDropContinue`，取证与成本口径
            // 写在那一条的注释里：用户 26 日 18:4x「我开了后台，退出来又给我暂停」⇒
            // 总闸开着不再掐线之后，纯 thinking 的轮断了塌成报错这件事会更难看）。
            // 没有正文的那一笔欠的是**整轮重发**（`dropContinueEntryKindForDropped` 给答案，
            // 与气泡上那枚「重新发起这一轮」同源），岛上那句话随之而变。
            final hasAnswer = dropReceived.trim().isNotEmpty;
            dropWholeRound = dropContinueEntryKindForDropped(
                    hasReceivedContent: hasAnswer) ==
                ContinueEntryKind.restartWholeRound;
            dropPlan = _dropCont.armAtDrop(
              round: _reactRound,
              choice: decideDropContinue(
                  autoContinued: _dropCont.usedIn(_reactRound),
                  hasReceivedContent: hasAnswer,
                  hasReceivedThinking: partialRoundThinking().trim().isNotEmpty,
                  stoppedOrSuperseded: _reactLoopStopRequested ||
                      _sendSeq != dropRoundSeq ||
                      _pendingFollowupMessages.isNotEmpty),
              // 本 build 改的就是这一个输入：人在后台 ⇒ 不立刻起（真机结论：
              // 后台里新起的流必然几秒内被对端关闭，立刻续 = 白烧一次额度）。
              inForeground: AppResumeSignal.instance.inForeground,
              pending: PendingDropContinue(
                  assistantMsgId: assistantMsg.id,
                  userMsgId: userMsg.id,
                  isZh: isZh,
                  deep: deepResearchOn,
                  armedSeq: dropRoundSeq,
                  wholeRound: dropWholeRound),
            );
            dropArmed = dropPlan != DropContinuePlan.giveUpWithButton;
            if (dropArmed) {
              reactLoopError = null;
              _logger.warn(
                  '[ReAct] 掉线${dropPlan == DropContinuePlan.startNow ? '自动续一轮' : '续写挂起，等回到前台'}'
                  '（第 ${_dropCont.used}/$kMaxAutoContinuesPerUserRound 次，'
                  '${dropWholeRound ? '整轮重发：只有思考落点' : '从断点接着写'}），已收 '
                  '${dropReceived.trim().length} 字'
                  ' / ${partialRoundThinking().trim().length} 字思考',
                  cat: LogCat.react, tag: 'ReAct');
            } else {
              // 没判成可续 ⇒ 这一笔不是整轮重发，别让 finally 拿旧值去写岛上的话。
              dropWholeRound = false;
            }
          case StreamEndKind.leftAppAborted:
            // build165 ①：这是**本端**在 `paused`/`hidden` 那一刻收的连接。
            // 三件"不是它"都要说清，因为这三条都是这个仓真付过代价的谎：
            //  · 不是用户按的停止 —— `_reactLoopStopRequested` / `_reactLoopUserStopped`
            //    一个字都没动，蹭它就是把一句"用户已终止"写进他的聊天记录（build158）；
            //  · 不是网络故障 —— 真机上那 8 次报错的形状（`Software caused connection
            //    abort` / `Connection closed while receiving data`）我们自己关线时
            //    一模一样，所以 `classifyStreamEnd` 里这一格必须排在串匹配之前；
            //  · 不是崩溃 —— 走 `other` 会被写成 ❌ 并弹「去设置」，那是把省电行为
            //    说成配置坏了。
            _logger.warn(
                '[ReAct] 离开 App 时本端收起了这条连接（非用户停止、非网络故障）'
                '：round=$_reactRound',
                cat: LogCat.react,
                tag: 'ReAct');
            dropReceived = collectReceivedAnswer();
            // 额度仍归同一本账（最多 1 次），且**永远攒到回到前台**：人在后台时起的那条
            // 流就是这条要被收起的流（build162 的结论），当场重发只是再杀一次。
            dropPlan = _dropCont.armAtLeaveAppAbort(
              round: _reactRound,
              stoppedOrSuperseded: _reactLoopStopRequested ||
                  _sendSeq != dropRoundSeq ||
                  _pendingFollowupMessages.isNotEmpty,
              pending: PendingDropContinue(
                  assistantMsgId: assistantMsg.id,
                  userMsgId: userMsg.id,
                  isZh: isZh,
                  deep: deepResearchOn,
                  armedSeq: dropRoundSeq,
                  wholeRound: true),
            );
            dropArmed = dropPlan != DropContinuePlan.giveUpWithButton;
            bgAborted = true;
            // build167：这一族本来就欠整轮重发（`armAtLeaveAppAbort` 里那个
            // `wholeRound: true` 有 assert 钉着），把结论同步给 finally 那次分岔，
            // 不留一个"半旧半新"的局部值。总闸开着时根本走不到这一格
            // （`shouldAbortStreamOnLeaveApp` 收了 `backgroundRunAllowed` ⇒ 没人收起
            // 这条流 ⇒ `endKind` 不会是 `leftAppAborted`），所以这一支的行为与 166 一致。
            dropWholeRound = true;
          case StreamEndKind.userStopped:
            _logger.info('[ReAct] 用户按了停止，流关闭：$e',
                cat: LogCat.react, tag: 'ReAct');
          default:
            _logger.info('[ReAct] 本轮被系统提前结束（退页/触顶/熔断），流关闭：$e',
                cat: LogCat.react, tag: 'ReAct');
        }
        // build165（任务 #86）：**掉线那一刻的心跳读数**，紧挨上面那几行同一帧打出去
        // （`[ReAct] 流被对端关闭…` / `离开 App 时本端收起…` 之后、任何落库之前）。
        // 只加读数：上面那个 switch 已经跑完，`classifyStreamEnd` / `decideDropContinue` /
        // `armAtDrop` 的入参一个字都没动 ⇒ 这一行改不了任何判据。
        // 为什么必须在这一刻问、不等下面 finally 那次 `[Timing]`：ticks 要的就是
        // "这一瞬主线程还跳不跳"，中间多隔几个 await 拿到的就不是掉线那一瞬了。
        _logger.info(
            '[ReAct] ${await LiveTaskWiring.heartbeatLineAtDrop(endKind: endKind.name)}',
            cat: LogCat.react,
            tag: 'ReAct');
        // 优先保留已生成的答案内容，没有则给终止提示
        if (bgAborted) {
          // build165 ①：这一轮的当前事实就是"被我们自己收起来了"，气泡必须这么说 ——
          // **即使已经攒下自动重发也照写**：人此刻不在 App 前，气泡空着连一句话都没有
          // 就是静默（真机上纯 thinking 的那一轮塌成"本轮没有结果"就是这么来的）；
          // 而那一句也正是 ③ 那枚「重新发起这一轮」的出现判据（`continueEntryKindFor`）。
          // 不用 `_settleFailedDropContinue` 那条网络文案，是因为那一句把责任推给了网。
          final body = stripRoundAbortNote(
              assistantMsg.content.trim().isNotEmpty
                  ? assistantMsg.content
                  : dropReceived);
          assistantMsg.content = body.trim().isEmpty
              ? bgPauseNote(hasContent: false, isZh: isZh)
              : '$body\n\n${bgPauseNote(hasContent: true, isZh: isZh)}';
        } else if (dropArmed) {
          // build161 ①：决定续写时气泡只留已收正文，**不挂掉线文案** ——
          // 那一句是 ③ 那枚按钮的出现判据，续写正当中写上它，
          // 等于让气泡抢在结果之前先宣布失败；真续不上由 `_runDropContinueRound`
          // 补回来。占位气泡（content 为空）则回填本轮 rawBuf 里已有的结论。
          if (assistantMsg.content.trim().isEmpty) {
            assistantMsg.content = dropReceived;
          }
        } else if (assistantMsg.content.trim().isEmpty) {
          ChatMessage? lastWorking;
          // build103（I4）：只扫本轮（runStart 之后），不再回捞历史轮的结论
          for (int i = workingMessages.length - 1; i >= runStart; i--) {
            final m = workingMessages[i];
            if (m.role == MessageRole.assistant && m.content.isNotEmpty) {
              lastWorking = m;
              break;
            }
          }
          final partial = _extractFirstAnswer(lastWorking?.content ?? '');
          // build155：与上面那处同一判据（`stopNote`）。这里是"流被关闭抛
          // ClientException"那条出口，`isUserStop` 本身就还包含
          // `Connection closed` 这类**根本不是停止**的情形（见上面那三行或条件），
          // 更不许一口断定是用户按的。
          assistantMsg.content = endKind == StreamEndKind.networkDropped
              ? (partial.isNotEmpty
                  ? '$partial\n\n${networkDropNote(hasContent: true, isZh: isZh)}'
                  : networkDropNote(hasContent: false, isZh: isZh))
              : partial.isNotEmpty
                  ? '$partial\n\n${stopNote(userStopped: _reactLoopUserStopped, hasContent: true, isZh: isZh)}'
                  : stopNote(
                      userStopped: _reactLoopUserStopped,
                      hasContent: false,
                      isZh: isZh);
        } else if (endKind == StreamEndKind.networkDropped) {
          // 已经落了半截答案的一轮也必须说一句"是被断的" ——
          // 否则那半截读起来就是一份完整回答，用户不知道后面还有内容没到。
          assistantMsg.content =
              '${assistantMsg.content}\n\n${networkDropNote(hasContent: true, isZh: isZh)}';
        }
        unawaited(_throttledSaveAssistantContent(
            storage, assistantMsg, assistantMsg.content,
            force: true));
        // build96 (O13 根因③)：throttled 只写 content 列，用户终止时思考步骤会丢，
        // 补一次完整 saveMessage 持久化 reasoningSteps
        // build98（O13 P2 复核）：finally 块末尾也有一次全量 saveMessage（同一
        // assistantMsg 对象，且先补 token 字段），功能上已覆盖本次保存；此处属防御性
        // 冗余——实机验收无异常，保留可防 finally 保存逻辑日后变更时丢 reasoningSteps，
        // 暂留待后续统一清理，勿单独删除。
        await _persistRoundAssistant(storage, assistantMsg);
      } else {
        // build150：真崩溃要带给岛上看 —— 这一支以前只在消息里写 ❌ 文案，
        // finally 那行却按"没 error"处理，于是崩溃的一轮在通知栏里报成「已完成」。
        reactLoopError = e;
        _logger.error('[ReAct] loop crashed',
            error: e, stack: st, cat: LogCat.react, tag: 'ReAct');
        // E3（build94）：C 类不可恢复错误（鉴权/配额/模型不存在/未配置 key）——
        // 写人话文案（不含原始堆栈）并弹「去设置」动作按钮，不让用户猜原因。
        final fatalKind = fatalConfigErrorKind(e, isZh: isZh);
        if (fatalKind != null) {
          assistantMsg.content = isZh
              ? '⚠️ $fatalKind，本轮对话无法继续。\n\n请检查 API 配置后重试（已自动重试的传输错误不会走到这里）。'
              : '⚠️ $fatalKind — this conversation cannot continue.\n\nPlease check your API settings and retry.';
          assistantMsg.showStaleFootnote = true;
          unawaited(_throttledSaveAssistantContent(
              storage, assistantMsg, assistantMsg.content,
              force: true));
          if (mounted) {
            AppSnackBar.showSnackBar(context, 
              SnackBar(
                content: Text(fatalKind),
                duration: const Duration(seconds: 6),
                action: SnackBarAction(
                  label: isZh ? '去设置' : 'Settings',
                  onPressed: () {
                    // build104（I15）：rootNavigator——嵌套栈/弹层状态下
                    // 普通 push 会把设置页压到被覆盖的层，点击看似无反应
                    //（与 model_switcher v1.7.42 同类陷阱）
                    Navigator.of(context, rootNavigator: true).push(
                      MaterialPageRoute(
                          builder: (_) => const ApiConfigScreen()),
                    );
                  },
                ),
              ),
            );
          }
        } else if (assistantMsg.content.trim().isNotEmpty) {
          assistantMsg.content = isZh
              ? '${assistantMsg.content}\n\n---\n⚠️ 传输中断（自动重试已耗尽）：${e.toString()}'
              : '${assistantMsg.content}\n\n---\n⚠️ Transport interrupted (auto-retries exhausted): ${e.toString()}';
        } else {
          assistantMsg.content = isZh
              ? '❌ 思考过程出错：${e.toString()}\n\n你可以：\n1. 降低思考程度再试；\n2. 临时关闭「自主思考搜索循环」，退回普通联网搜索模式。'
              : '❌ Thinking loop error: ${e.toString()}\n\nTry:\n1. Lower the thinking level;\n2. Temporarily disable the autonomous thinking loop and fall back to normal web search mode.';
        }
        assistantMsg.showStaleFootnote = true;
        // ===== v1.4.5：ReAct 崩溃 catch 里写的错误提示 → 强制保存 =====
        unawaited(_throttledSaveAssistantContent(
            storage, assistantMsg, assistantMsg.content,
            force: true));
        // build96 (O13 根因③)：崩溃路径同样补完整保存，防思考步骤丢失
        // build98（O13 P2 复核）：finally 的全量 saveMessage 已覆盖同一对象，
        // 此处为防御性冗余保存，保留原因同上（用户终止分支处注释）。
        await _persistRoundAssistant(storage, assistantMsg);
      }
    } finally {
      checkTimer?.cancel();
      // build126：**复位必须是 finally 的第一件事**，且不受 mounted / 后续 await 影响。
      // 旧实现把 `_isStreaming = false` 放在 `await storage.saveMessage(assistantMsg)`
      // **之后**、并包在 `if (mounted)` 里：只要落库抛错、_drainPendingFollowups 抛错
      // 或页面已卸载，标志就永久卡 true（真机 58225 秒计时器 / 撤回失败 / 输入栏入队的根因）。
      // 顺带修好下面 _drainPendingFollowups() 的**空转**：它开头是
      // `if (!mounted || _isStreaming) return;`，此前因标志尚未复位而永远直接返回，
      // B-028 承诺的「已入队消息下一轮处理」实际从未生效。
      _isStreaming = false;
      // build150：取"用户按了停止"这个标记必须排在复位**之前**、又必须在
      // `_isStreaming = false;` **之后** —— 前者因为下一行就把它清成 false，
      // 后者因为 build126 钉死「finally 首个可执行语句是 `_isStreaming = false`」
      // （标志卡 true 的代价真机付过：58225 秒计时器 / 撤回失败 / 输入栏永远入队）。
      // 只给下面那次 `onResearchEnd` 分出口用：本轮**没正常跑完**的那些出口
      // 既不写「已完成」也不写「失败」（前者是假消息、后者是吓人的假故障），走 quiet 撤条。
      // build155 改名：旧名 `stoppedByUser` 是这次要修的假前提本身 —— 这个布尔的
      // 写入方还有退页 dispose / MCP 触顶 / E5 熔断，用户没按停止时它同样为真。
      // "到底是谁停的"另记在 `_reactLoopUserStopped`，只管文案（见 `stopNote`）。
      final endedEarly = _reactLoopStopRequested;
      _reactLoopStopRequested = false;
      _reactLoopUserStopped = false;
      // build142（灵动岛）：正常定稿 / 提前结束 / 异常三条出口都要摘掉这条常驻通知。
      // 形状与 build141 那条教训一致：**start 必有配对的 end，且 end 写在 finally**。
      // build150 起这条 end 还要**分得清是哪种出口**：成功留「· 已完成」、
      // 崩溃留「· 失败 + 原因」、提前结束走 quiet（两个都不写，见 `endedEarly`
      // 与 `reactLoopError` —— 它们都在复位之前取好，所以顺序动不得）。
      // build161 ①：判成"自动续一轮"的那次掉线**不在这里收尾** —— 岛上那行
      // 不撤、只换文案（续写进行中先写 ✗ 再偷偷复活，正是 build150/158 反复
      // 修的"出口分不清"；终态由 `_runDropContinueRound` 给它配对的 end）。
      // build161（岛即时出现）：这一行是 `_sendMessage` 入口登记的，两条分支都要先
      // **认领**：入口那层兜底 finally 见到已认领就不再动它。不认领的后果不是重复摘，
      // 而是**抢在续写之前把行撤了**——`_runDropContinueRound` 是在这之后才接着用
      // 这一行显示「正在接着写」的（它是 unawaited 的尾巴，本函数已经返回）。
      _claimSendIsland(userMsg.id);
      // #97：这一轮"到底是谁收掉的"只判**一次**，岛与气泡吃同一个读数。
      // 前两支是"续写进行中"（本轮还没收尾），根本没有终态 ⇒ 留 null，
      // 下面那句气泡补话因此绝不会抢在结果之前宣布"停在这里"。
      RoundExitKind? islandExit;
      if (bgAborted && dropArmed) {
        // build165 ①②：这一刻没有任何流在跑，所以岛上写的是"回到 App 后会重发"，
        // 不是"正在重发"（build162 为同一件事立的红线）。额度是现成的 `_dropCont.used`，
        // 文案住在 `drop_continue.dart`，这里不抄第二份。
        unawaited(LiveTaskWiring.onResearchUpdate(userMsg.id,
            bgRestartPendingIslandLabel(used: _dropCont.used, isZh: isZh),
            deep: deepResearchOn));
      } else if (dropArmed) {
        // build162：挂起那一笔不许写"正在接着写"—— 那一刻真的没有在跑任何东西，
        // 岛上那句话必须说的是事实（与 161 清掉的那族假话同一条红线）。
        // build167：四种形状（能不能接断点 × 现在起/等回前台）的话由 `drop_continue.dart`
        // 那一张表一次给完，这里不再自己写第二串三元 —— 只有思考落点的那一轮
        // 接不了断点，实际发生的是整轮重发，话就必须写「重新发起这一轮」。
        unawaited(LiveTaskWiring.onResearchUpdate(userMsg.id,
            dropContinueIslandLabelFor(
                wholeRound: dropWholeRound,
                startsNow: dropPlan == DropContinuePlan.startNow,
                used: _dropCont.used,
                isZh: isZh),
            deep: deepResearchOn));
      } else {
        // build165 ①：`bgAborted` 也归进 quiet —— 被本端收起的这一轮既没跑完
        // （写「· 已完成」是假消息）也不是故障（✗ 会把我们主动关线说成网络坏了），
        // 而人此刻不在 App 前；额度已用掉 / 已被新一轮接管时就是这一支。
        // build168 ①/#97：这四件事的分岔**不再由这里的三元各写一遍**。
        // `endedEarly` / `bgAborted` / `reactLoopError` / 本轮是否结束在反问上
        // 一起交给 `utils/round_exit.dart` 的 [judgeRoundExitKind]（判据只住一处，
        // 逐页补迟早漂成两种口径 —— 那文件顶上写明了它唯一的存在理由与三条红线）。
        // 优先级由它钉死：**提前结束排最前**。用户按停止那一瞬恰好停在反问上的轮次
        // 走 quiet，得到的是一句真话（什么都没写），不是「等你回答」这种
        // 什么都不会重发的假承诺。
        // 反问那一格的取法：`lastRoundWasAskUser` 是**单调真**的（一轮问过就记得），
        // 所以要与 `answered` 合取才是"结束在等人上"——问完之后又答成功的那一轮
        // 两个条件同时成立，绝不能被报成等人。
        islandExit = judgeRoundExitKind(
            endedEarly: endedEarly,
            bgAborted: bgAborted,
            // 这里只借它的**有没有**（null = 本轮没坏）；上屏那句原因仍由下面
            // `describeApiProbeFailure` 现取现译，判据不改写、也不编。
            error: reactLoopError?.toString(),
            askUserPending: lastRoundWasAskUser && !answered);
        unawaited(LiveTaskWiring.onResearchEnd(userMsg.id,
            deep: deepResearchOn,
            quiet: islandExit == RoundExitKind.quiet,
            waitingUser: islandExit == RoundExitKind.waitingUser,
            isZh: isZh,
            error: islandExit == RoundExitKind.failed && reactLoopError != null
                ? describeApiProbeFailure(reactLoopError, isZh: isZh)
                : null));
      }
      // build141（用户：「计时器问题（多次）超时计录」）：本轮**耗时画像**留痕。
      // 真机报「思考过程 910 秒」时，日志里关于这 910 秒花在哪一个字都没有 ——
      // SSE 空闲闸只在「流已建立后断粮」时说话，「上游 200 后迟迟不吐字」
      // 「编排三步各等了多久」全是静默的，于是每次只能靠猜。
      // 放 finally 的第一段：正常定稿 / 用户停止 / 异常三条出口都要留下这条，
      // 否则最该看的（卡住、中止）反而没有。
      // build164（#82 取证 ③）：把「本轮是不是被 maxTokens 打满收的口」交给画像——
      // 接线口径照 `round_timing.dart` 注释里写的那份（三态，没收完过流就留 null）。
      // 不接线的后果就是用户看到的那格「maxTokens 打满：未知」，"老是中断"在日志里
      // 始终没有凭据。
      // `stream:` 那一格由我（审核方）补接：#82 与 #84 当时互相把这一格推给对方，
      // 谁都没接 —— 这正是本仓那条"注释承诺了但没人实现"的形状，故在此写明归属，
      // 事实源是循环入口的 `roundStream`（每个 chunk 记一帧）。
      final timing = describeRoundTiming(assistantMsg.reasoningSteps,
          stream: roundStream.toSpan(),
          hitMaxTokens: sawMaxTokensTruncation);
      if (timing.isSlow) {
        _logger.warn('[Timing] ${timing.line}',
            cat: LogCat.react, tag: 'ReAct');
      } else {
        _logger.info('[Timing] ${timing.line}', cat: LogCat.react, tag: 'ReAct');
      }
      // build146（透明度，与编排路径同款）：ReAct 轮也要在**消息里**留下"这一轮走了哪条路"。
      // 改完门控后默认档 `auto` 就落在 ReAct，只有编排轮有路径行的话，
      // 最常见的轮次反而最不可读（用户问的正是"这一轮走的是哪条路、花了几次 LLM 调用"）。
      // 口径必须说准：ReAct 每轮至少一次生成调用（截断续写、工具观察不另计），
      // 所以这里报**轮次**，不假装报一个精确的调用数。
      // 放在耗时画像之后：那条日志的 stepCount 口径保持"纯模型产出步骤"，不受本行影响。
      final orchWasPlanned = subagentModeUsesOrchestrator(
          widget.conversation.subagentMode,
          deep: deepResearchOn);
      assistantMsg.addReasoning(ReasoningStep(
        'path',
        isZh
            ? '本轮路径：自主思考循环（ReAct）· 子代理档 ${widget.conversation.subagentMode}'
                '${orchWasPlanned ? '（编排未产出，已回退）' : ''} · '
                '思考 $reactRoundsUsed 轮，每轮至少 1 次生成调用'
            : 'Round path: ReAct loop · sub-agent mode ${widget.conversation.subagentMode}'
                '${orchWasPlanned ? ' (orchestration unfinished, fell back)' : ''} · '
                '$reactRoundsUsed thinking round(s), at least 1 generation call each',
        phase: 'react',
        round: reactRoundsUsed,
      ));
      // B-028：ReAct 定稿轮 break 后不再进下一轮 for，轮首 drain 到不了；
      // 统一在收尾处消费插话队列，避免「已入队」消息永不发送 + 角标残留。
      _drainPendingFollowups();
      // v1.3.6：保存 token 用量
      // v1.7.26 (D1)：由各轮 streamChat 的 onUsage 回调累加（上面调用处）
      assistantMsg.promptTokens = reactUsage.promptTokens;
      assistantMsg.completionTokens = reactUsage.completionTokens;
      assistantMsg.totalTokens = reactUsage.totalTokens;
      assistantMsg.cacheReadTokens = reactUsage.cacheReadTokens;
      assistantMsg.cacheWriteTokens = reactUsage.cacheWriteTokens;
      assistantMsg.cacheHitTokens = reactUsage.cacheHitTokens;
      assistantMsg.cacheMissTokens = reactUsage.cacheMissTokens;
      // #97 ②「无法就地操作」的那一半：**岛没出现时，这一格不许是静默的**。
      // 总闸关着（默认档，build167 有意保留）时 `alert` 与投影都 early-return，
      // 通知栏里一个字都没有 ⇒ 他读到的最后一句还是那句像"跑完了"的正文，
      // 而真实情况是任务停在他面前、不会自己往下走。
      // 所以这里由气泡补那一格（与 `drop_continue.dart` 的 `bgPauseNote` 同一族、
      // 同一形状：写进 `assistantMsg.content` 尾部，**排在下面那次落库之前**，
      // 重启后这一句还在）。话只住 `utils/round_exit.dart`，这里不抄第二份。
      // 判据不吃第二遍：用的就是上面那次 [judgeRoundExitKind] 的读数 ——
      // 岛上写「等你回答」与气泡补「等你回答」必须是同一件事的两种投影，
      // 不是两套各判一次（那正是本仓反复复发的形状）。
      // 岛已经替他说过这一格的场合（总闸开着且通道就绪）**不重复补**：
      // 同一句话在屏上出现两遍，读起来像这 App 在凑字数。
      // 两半都不在这里判：`exit`（这一轮怎么收的）与 `projectionBlocked`（岛出没出）
      // 原样交给 `round_exit.dart`，那张表由单测逐格打 ⇒ 界面这一行只是赋值。
      assistantMsg.content = waitingUserBubbleForRound(
            exit: islandExit,
            projectionBlocked: LiveTaskWiring.projectionBlocked,
            content: assistantMsg.content,
            isZh: isZh,
          ) ??
          assistantMsg.content;
      await _persistRoundAssistant(storage, assistantMsg);
      // v1.7.34：跨对话记忆——assistant 消息落库后触发摘要生成
      _triggerMemorySummaryIfDue();
      final finalSearchCount = assistantMsg.injectedWebSearchCount > 0
          ? assistantMsg.injectedWebSearchCount
          : 0;
      if (mounted) {
        // build126：不再重复赋值 _isStreaming（已在 finally 首行复位）——
        // 上面的 _drainPendingFollowups() 现在能真正生效，它可能已起新一轮
        // （_isStreaming 重新为 true），此处再赋值会把这新一轮的生成态抹掉。
        setState(() {});
        // SF-1：定稿强制复位跟随并吸底
        _autoFollow = true;
        _refreshContextUsage();
        _scrollToBottom();
        if (finalSearchCount > 0) {
          AppSnackBar.showSnackBar(context, 
            SnackBar(
              content: Text(l.tr('searchResultCount',
                  args: {'count': '$finalSearchCount'})),
              duration: const Duration(seconds: 3),
            ),
          );
        }
      }
      // build161 ①：自动续写必须等 finally 全部落地之后再起 —— 此刻
      // `_isStreaming` 已复位、本轮已按当前（无文案的）正文落库、drain 也跑过，
      // `_continueFromMessage` 要求的"非流式 + 最后一条 + 自己重新登记 _sendSeq"
      // 三条前提都成立了。await 会卡死在 finally 里，unawaited 让它自持终态。
      // build162：这条**只在前台成立**。人在后台时这里想起的那条新流会在几秒内被
      // 对端关闭（用户 16:45 那份日志：16:40:30.952 出去 → 16:40:37.016
      // `continue-from failed: Connection closed while receiving data`），所以后台
      // 掉线只攒一笔（arm 已在 catch 里记过额度），起飞交给
      // `_onAppResumedForDropContinue`。前台那一支的行为与 161 完全一致。
      if (dropPlan == DropContinuePlan.startNow) {
        if (dropWholeRound) {
          // build167：只有思考落点、一个字正文都没有 ⇒ `_continueFromMessage` 无处可接
          // （它对空正文直接 return），这一笔兑现的是**整轮重发**，走既有的
          // `_retryMessage` 通道（token 因此天然进本轮账单，与 165 ② 同一条路）。
          // 岛的这一行到此了结（quiet 撤条）：重发会为新的用户消息另开一行。
          unawaited(_restartWholeRound(assistantMsg,
              islandEndUserMsgId: userMsg.id, deep: deepResearchOn));
        } else {
          unawaited(_runDropContinueRound(
              assistantMsg, userMsg.id, isZh, deepResearchOn, dropRoundSeq));
        }
      }
    }
  }

  /// build161：本轮（runStart 之后）最后一条有内容的 assistant 正文。
  ///
  /// B-026 的口径：下限必须是 runStart，不得越过本轮去捞历史轮的结论。
  /// catch 兜底与停止兜底原先各嵌了一份同样的 for —— 这里给"掉线有没有东西
  /// 可续"的决策复用同一实现，不再添第四份。
  String _lastRoundAssistantContent(List<ChatMessage> working, int runStart) {
    for (int i = working.length - 1; i >= runStart; i--) {
      final m = working[i];
      if (m.role == MessageRole.assistant && m.content.isNotEmpty) {
        return m.content;
      }
    }
    return '';
  }

  /// build162：自动续写**起飞之前的新鲜度复核**，全仓只这一份实现。
  ///
  /// 161 把它写成 `_runDropContinueRound` 开头那个 `stale` 局部 bool；162 多了一个
  /// 起飞时刻（回到前台），两个时刻查的是同一件事，所以共用这一个薄壳，
  /// 判据本身抽在 [dropContinueStale]（纯函数、可单测）。
  /// [assistantMsg] 传 null 表示"按 id 已经找不着那条气泡了"（被删/被撤回）⇒ 过期。
  bool _dropContinueStale(ChatMessage? assistantMsg, int armedSeq) =>
      dropContinueStale(
        noAssistantMessage: assistantMsg == null ||
            !_isMessageAlive(assistantMsg.id),
        notMounted: !mounted,
        streaming: _isStreaming,
        stopRequested: _reactLoopStopRequested,
        supersededByNewerRound: _sendSeq != armedSeq,
        hasQueuedFollowup: _pendingFollowupMessages.isNotEmpty,
      );

  /// build161 ①：掉线自动续写的**唯一**接手续写体。
  ///
  /// 不另起发送路径 —— 正文直接进 `_continueFromMessage`（chat_screen_message.dart
  /// build101/F4 的"从该条续写"入口：历史带到该条、续写提示拼在该条正文尾部、
  /// 增量接到同一条气泡并落库、自己登记 `_sendSeq`）。这个壳只管它管不了的三件事：
  ///  · **岛的终态**：finally 那次 onResearchUpdate 把这行留在了"进行中"，
  ///    start 必有配对 end（build142 的红线），在这里给；
  ///  · **失败形状**：续不出来就把「网络中断」文案补回气泡 —— ③的「接着写」
  ///    按钮以那一句为出现判据，补回文案 = 按钮交还给用户；
  ///  · **过期复核**：catch 决策到这里之间还隔着 finally 的几次 await（162 之后
  ///    还可能隔着几分钟的后台），用户可能刚发了新一轮 / 按了停止。
  /// build162：[userMsgId] 由 `ChatMessage` 改成 id —— 挂起那一笔（[PendingDropContinue]）
  /// 按规格只带 id 不带对象，兑现时按 id 现找；本函数体内用到 userMsg 的只有
  /// `userMsg.id` 这一处（岛的行归它认），改成 id 不丢任何信息。
  Future<void> _runDropContinueRound(
    ChatMessage assistantMsg,
    String userMsgId,
    bool isZh,
    bool deep,
    int armedSeq,
  ) async {
    if (_dropContinueStale(assistantMsg, armedSeq)) {
      await _settleFailedDropContinue(assistantMsg, userMsgId, isZh, deep,
          islandError: isZh
              ? '网络中断：新一轮已开始，自动续写作废'
              : 'Connection dropped — superseded by a newer round');
      return;
    }
    String? continueStreamErr;
    final before = assistantMsg.content;
    try {
      await _continueFromMessage(assistantMsg,
          onStreamError: (r) => continueStreamErr = r);
    } catch (e) {
      // 能逃到这里的是落库/列表操作这类外围错。不许让它逃出去：这一行的终态只有这里能给。
      _logger.warn('[ReAct] 掉线续写外围错：$e', cat: LogCat.react, tag: 'ReAct');
      continueStreamErr ??= e.toString();
    }
    if (!mounted || !_isMessageAlive(assistantMsg.id)) {
      unawaited(LiveTaskWiring.onResearchEnd(userMsgId,
          deep: deep, quiet: true));
      return;
    }
    // build161（收尾）：**「正文变长」不再单独当"续完了"的判据** —— 续写这一腿自己
    // 再掉线时正文同样会长，而 `_continueFromMessage` 的流异常现在经 `onStreamError`
    // 透到这里（那一处 catch 以前只 warn 就吞掉）。
    // 两个条件一起成立才算成功：没有流异常 **且** 真的写进了东西。
    // 反向说清楚：`grew` 仍然必须查，因为"连接活着但一个字没吐"不是掉线，
    // 拿它去写「网络中断」就是把别的失败说成断线（build158 刚清掉的那类假话）。
    final grew = assistantMsg.content.trim() != before.trim();
    if (continueRoundSettledOk(streamError: continueStreamErr, grew: grew)) {
      unawaited(LiveTaskWiring.onResearchEnd(userMsgId, deep: deep));
      return;
    }
    await _settleFailedDropContinue(assistantMsg, userMsgId, isZh, deep,
        islandError: isZh
            ? '网络中断：自动续写一轮仍未成功，回到 App 可点「接着写」再试'
            : 'Connection dropped — auto-continue produced nothing');
  }

  /// 自动续写作废/失败后的落点：气泡补回「网络中断」那一句（③按钮随它出现）、
  /// 落库、岛写 ✗。这里不 quiet：用户已经在岛上看到过"正在接着写"，静默撤条
  /// 会让岛的最后一句话消失 —— build150「三条出口都要分得清」挡的就是这个。
  /// 唯一的例外是"两条消息已经不在"（删除/撤回）：没有气泡可补文案，那一支由
  /// 调用方按 `quiet` 撤条，与本函数的判据不冲突。
  Future<void> _settleFailedDropContinue(
    ChatMessage assistantMsg,
    String userMsgId,
    bool isZh,
    bool deep, {
    required String islandError,
  }) async {
    if (mounted && _isMessageAlive(assistantMsg.id)) {
      final body = stripNetworkDropNote(assistantMsg.content);
      // `hasBgPauseNote` 这一道闸是 build165 加的：那一轮如果已经挂着「已暂停：离开 App
      // 时收起了这条连接」，再往下面叠一句「网络中断」= 同一条气泡里两个互相矛盾的原因，
      // 用户读到的就是"这 App 在编"。摘句走同一份判据（`stripRoundAbortNote`）。
      if (body.trim().isNotEmpty &&
          !hasNetworkDropNote(assistantMsg.content) &&
          !hasBgPauseNote(assistantMsg.content)) {
        setState(() => assistantMsg.content =
            '$body\n\n${networkDropNote(hasContent: true, isZh: isZh)}');
      }
      final storage = context.read<StorageService>();
      await _persistRoundAssistant(storage, assistantMsg);
      if (mounted) setState(() {});
    }
    unawaited(LiveTaskWiring.onResearchEnd(userMsgId,
        deep: deep, error: islandError));
  }

  /// build162：回到前台那一下兑现"待前台续"那一笔。
  ///
  /// 起飞时刻从"掉线当时"挪到这里，是因为真机把后台起流判死了（见
  /// `DropContinuePlan` 顶上那段日志结论）。三条纪律：
  ///  · 没有挂起的恢复**什么都不做**（直接 return）：这一路不许去查任何状态，
  ///    否则每次解锁都在替 build161 背锅；
  ///  · 过期复核用 161 那一份实现（[_dropContinueStale]），不复制第二份；
  ///  · 起不来的那一支不许静默：气泡补回「网络中断」= ③ 的「接着写」按钮随之
  ///    回来，岛写 ✗ + 原因（用户已经在岛上看过一句"回到 App 后自动接着写"）。
  /// 由 `AppResumeSignal` 叫起（注册/注销在 chat_screen.dart 的 initState/dispose）。
  void _onAppResumedForDropContinue() {
    final p = _dropCont.pending;
    if (p == null) return;
    // 按 id 现找：挂起期间用户可能删掉/撤回过这两条（那两条路都不递增
    // `_reactGeneration`，代次守卫认不出来）。
    ChatMessage? assistant;
    ChatMessage? user;
    for (final m in _messages) {
      if (m.id == p.assistantMsgId) {
        assistant = m;
      } else if (m.id == p.userMsgId) {
        user = m;
      }
    }
    final plan = _dropCont.takeOnResume(
        stale: _dropContinueStale(assistant, p.armedSeq) || user == null);
    if (plan == DropContinuePlan.startNow) {
      if (p.wholeRound) {
        // build165 ②：这一笔欠的是**整轮重发**，不是"从断点接上"。
        // 文案与动作必须一起换：真机上被收起的那些轮 5/7 次一个字正文都没收到
        // （只有 thinking 在飞），`_continueFromMessage` 对空正文直接 return ⇒
        // 写"接着写"的按钮/岛文案点下去什么都不发生，而实际该做的是重发这一轮。
        // 走 `_restartWholeRound`（既有的 `_retryMessage` 通道）= 本轮的 token
        // 天然经过 ReAct 的 `reactUsage.merge` / 编排的 `applyOrchUsage` 落账（④）。
        _logger.info(
            '[ReAct] 回到 App，兑现整轮重发（第 ${_dropCont.used}/'
            '$kMaxAutoContinuesPerUserRound 次）',
            cat: LogCat.react,
            tag: 'ReAct');
        unawaited(LiveTaskWiring.onResearchUpdate(p.userMsgId,
            bgRestartRunningIslandLabel(used: _dropCont.used, isZh: p.isZh),
            deep: p.deep));
        // 重发会为新那条用户消息在岛上开**另一行**（`_sendMessage` 入口登记的），
        // 这一行（挂在旧 userMsgId 上）到此了结：quiet 撤条，不写「已完成」也不写 ✗。
        unawaited(_restartWholeRound(
            assistant!,
            islandEndUserMsgId: p.userMsgId,
            deep: p.deep));
        return;
      }
      _logger.info(
          '[ReAct] 回到前台，兑现掉线续写（第 ${_dropCont.used}/'
          '$kMaxAutoContinuesPerUserRound 次）',
          cat: LogCat.react,
          tag: 'ReAct');
      // 岛上那句话跟着事实改口：此刻真的开始在跑了，才配得上"正在接着写"。
      unawaited(LiveTaskWiring.onResearchUpdate(p.userMsgId,
          dropContinueIslandLabel(used: _dropCont.used, isZh: p.isZh),
          deep: p.deep));
      // `_runDropContinueRound` 里还会用同一个 `_dropContinueStale` 复核一次：
      // 两次调用同一份判据，不是第二份实现。
      unawaited(_runDropContinueRound(
          assistant!, p.userMsgId, p.isZh, p.deep, p.armedSeq));
      return;
    }
    if (assistant == null || user == null) {
      // 气泡或用户消息已经不在了（删除/撤回）：没有正文可补文案，岛那一行只能
      // 就地安静撤 —— 与 161 在 `_runDropContinueRound` 里 `!mounted` 那一支同形。
      unawaited(LiveTaskWiring.onResearchEnd(p.userMsgId,
          deep: p.deep, quiet: true));
      return;
    }
    unawaited(_settleFailedDropContinue(assistant, p.userMsgId, p.isZh, p.deep,
        islandError: p.isZh
            ? '网络中断：回到 App 时这一笔已过期，自动续写作废'
            : 'Connection dropped — pending continue expired before resuming'));
  }

  /// build165 ③：气泡上那一枚按钮的**唯一**落点 —— 按与出现判据同源的那一份分岔。
  ///
  /// 为什么必须在宿主分岔、而不是让 `_continueAfterDrop` 自己判断：按钮"写什么"
  /// 与"点了发生什么"必须是同一个判据（`continueEntryKindFor` / `continueEntryLabel`）
  /// 给出来的，否则迟早出现"写着『重新发起这一轮』、点的却是接断点"。
  /// 手动点的那一次**不占**自动额度（与 161 同一条规矩：额度防的是没人同意就连环
  /// 替用户付 token，他亲手按的不在此列），所以这里不问 `_dropCont`。
  Future<void> _onContinueEntryTap(ChatMessage msg) async {
    final kind = continueEntryKindFor(msg.content);
    if (kind == null) return;
    if (kind == ContinueEntryKind.restartWholeRound) {
      await _restartWholeRound(msg);
      return;
    }
    await _continueAfterDrop(msg);
  }

  /// build161 ③：气泡上常驻的「接着写」按钮。
  ///
  /// 与 ① 走同一条实现（`_continueFromMessage`），区别只在：用户亲手点的**不占**
  /// 自动额度（额度防的是"没人同意就连环替用户付 token"），且此刻岛的终态行早已
  /// 撤过、不再上岛。气泡正文此刻尾挂着「网络中断」文案，必须先摘 —— 续写入口
  /// 会把整段当"模型已写过的内容"，那半句提示会跟着喂给模型。
  Future<void> _continueAfterDrop(ChatMessage msg) async {
    if (_isStreaming) return;
    final body = stripNetworkDropNote(msg.content);
    if (body.trim().isEmpty) return;
    final hadNote = body != msg.content;
    if (hadNote) {
      setState(() => msg.content = body);
    }
    final before = msg.content;
    String? manualStreamErr;
    try {
      await _continueFromMessage(msg,
          onStreamError: (r) => manualStreamErr = r);
    } catch (e) {
      _logger.warn('[ReAct] 「接着写」外围错：$e',
          cat: LogCat.react, tag: 'ReAct');
      manualStreamErr ??= e.toString();
    }
    if (!mounted || !_isMessageAlive(msg.id)) return;
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    // 判据与 ① 同源：**「一个字没多」和「这一腿又抛了流异常」都算没续上**。
    // 只看正文变没变会漏掉"续了一半又断"：那种情况正文确实长了，按钮却会消失，
    // 而那一轮根本没答完 —— 用户既拿不到「接着写」，也不知道该再点一次。
    if (hadNote &&
        !continueRoundSettledOk(
            streamError: manualStreamErr,
            grew: msg.content.trim() != before.trim())) {
      // 这一次又没续动（含再掉线）：文案挂回去、按钮留在原地 —— 手动入口不设
      // 上限，上限只管"自动"那一次。没挂过句子的普通续写**不许**被这里贴上
      // "网络中断"的标签（那是把别的失败说成断线，build158 刚清掉的那类假话）。
      setState(() => msg.content =
          '$body\n\n${networkDropNote(hasContent: true, isZh: isZh)}');
      final storage = context.read<StorageService>();
      await _persistRoundAssistant(storage, msg);
      if (mounted) setState(() {});
    }
  }

  // ==========================================================================
  // v1.3.3 build 13 新增：AI 反向提问对话框
  // 解析到 <ask_user> 标签时调用，返回用户回复（选项点选或自由输入）
  //
  // build139（真机反馈④）：**整块 UI 挪进 lib/widgets/ask_user_dialog.dart**。
  // 留这个薄壳只为两件事：① 调用点（onShowAskUser）与 `awaitingUserInput` 的
  // 暂停/恢复时序不动；② 返回契约不动 —— null 仍然表示"用户没答"，上层据此
  // 记 skippedAskFps（O1：同一缺口不再问）。改成别的语义会连带污染那条判定。
  /// [quickReplies] 是 build140 反馈④ 的"与弹窗同帧的可选答复"，**在弹窗之前就已发起**，
  /// 面板内用 FutureBuilder 到货即渲染。传 null ⇒ 面板不显示这一段（保持旧形态）。
  Future<String?> _showAskUserDialog(
    String question,
    List<String> options, {
    Future<List<String>>? quickReplies,
  }) async {
    if (!mounted) return null;
    return showAskUserPanel(context,
        question: question, options: options, quickReplies: quickReplies);
  }

  // ==========================================================================
  // v1.3.3 build 13 新增：20 秒确认对话框（防卡壳）
  // 用户可选"继续思考"或"终止并输出当前结果"
  // ==========================================================================
  // N14（build94）：suggest 兜底补生成
  // 答案已定稿但模型没输出 <suggest> 时，用一次独立轻量请求补生成推荐追问。
  // 不携带 ReAct 协议与 tools，输出解析与 <suggest> 标签同口径（parseSuggestItems）；
  // 任何失败静默吞掉——追问区空着也不能影响已定稿的答案。
  // ==========================================================================
  // ==========================================================================
  /// build120：中止 suggest 兜底流（唯一收口）。
  ///
  /// 该流用专属 scope（见 [_suggestScope] 的说明），不会随 conversation scope
  /// 的停止一起被清理，所以每个「本会话停止/换轮」入口都必须显式调用这里。
  void _abortSuggestStream(ApiService apiSvc, {required String reason}) {
    if (_suggestScopes.isEmpty) return;
    // 先取副本再清空：`stopGeneration` 会同步走流的 sink，边遍历边删会
    // ConcurrentModificationError（这条路径正是「用户点停止」，抛了就等于停不下来）。
    final scopes = _suggestScopes.toList(growable: false);
    _suggestScopes.clear();
    for (final s in scopes) {
      _stopSuggestScope(apiSvc, s, reason);
    }
  }

  /// 只停**自己这一条**（超时回调专用：别人的流不该被我这条的超时杀掉）。
  void _abortOneSuggestScope(ApiService apiSvc, String scope,
      {required String reason}) {
    if (!_suggestScopes.remove(scope)) return;
    _stopSuggestScope(apiSvc, scope, reason);
  }

  void _stopSuggestScope(ApiService apiSvc, String scope, String reason) {
    try {
      apiSvc.stopGeneration(scope: scope, reason: reason);
    } catch (e) {
      _logger.warn('[ReAct] 中止 suggest 流失败: $e',
          cat: LogCat.react, tag: 'ReAct');
    }
  }

  Future<void> _fallbackGenerateSuggestions(
    ApiService apiSvc,
    ChatMessage userMsg,
    ChatMessage assistantMsg,
    bool isZh, {
    void Function(TokenUsage)? onUsage,
  }) async {
    final items = await _streamSuggestItems(
      apiSvc,
      buildSuggestFallbackPrompt(
        question: userMsg.content,
        answer: assistantMsg.content,
        isZh: isZh,
      ),
      label: 'N14 suggest fallback',
      onUsage: onUsage,
    );
    if (items.isEmpty) return;
    assistantMsg.suggestions
      ..clear()
      ..addAll(items);
    if (mounted) setState(() {});
    _followBottomIfNeeded();
  }

  /// 一次轻量推荐生成的**唯一**流式管线（教训 #62：同一语义只允许一个实现）。
  ///
  /// 两个调用方只差 prompt：
  ///  · [needsSuggestFallback] 兜底链 —— 答案定稿后补"追问推荐"；
  ///  · build140 反馈④ 的反问面板 —— 弹窗那一刻并行补"可选答复"。
  /// 失败/超时一律返回空列表（静默降级），绝不向上抛：推荐区空着也不能影响主流程。
  Future<List<String>> _streamSuggestItems(
    ApiService apiSvc,
    String prompt, {
    required String label,
    void Function(TokenUsage)? onUsage,
    String? scope,
  }) async {
    // build141：scope 可由调用方注入 —— 反问面板需要在**自己关闭的那一刻**精确取消
    // 这一条流（见 onShowAskUser 的 finally），而 `_suggestScopes` 是集合，
    // 没有标识就没法只停自己这一条。
    final suggestScope = scope ??
        'suggest:${widget.conversation.id}:${DateTime.now().microsecondsSinceEpoch}';
    try {
      final buf = StringBuffer();
      // build120：给 suggest 兜底一个**专属 stopScope**。
      // 此前它复用 `widget.conversation.id`，与主生成同一 scope —— 想单独中止它
      // 就会连主生成一起杀掉，所以只能靠 `.timeout()` 硬断，而 `.timeout()` 的
      // `sink.close()` 只关闭「下游包装流」，**上游 HTTP 连接并不会被取消**。
      // 真机证据（2026-09-16 21:35~21:37 导出日志）：
      //   21:35:01 `O6-1 suggest fallback: 6s idle timeout, abort`（已放弃）
      //   21:37:23 `SSE stream idle timeout (30s) during streamChat` + `[ZONE] runZonedGuarded`
      // 即 abort 后那个请求又活了 22 秒，最后以无人接收的异常形式冒泡到全局 zone
      // （注释声称的「防止后台协程泄漏」实际没做到）。
      // 修法：专属 scope + 超时时显式 stopGeneration → 真正 close 掉 http client。
      _suggestScopes.add(suggestScope);
      // O6-1（build96）：兜底 suggest 流加 6s 空闲超时——模型卡住不出字时
      // 不再无限挂起，超时放弃（追问区保持为空）。
      await for (final chunk in apiSvc
          .streamChat(
        config: _conversationApiConfig.maxTokens < 512
            ? _conversationApiConfig.copyWith(maxTokens: 512)
            : _conversationApiConfig,
        messages: [
          ChatMessage.create(
            conversationId: widget.conversation.id,
            role: MessageRole.user,
            content: prompt,
          ),
        ],
        yieldReasoning: false,
        stopScope: suggestScope,
        onUsage: onUsage,
      )
          .timeout(const Duration(seconds: 6), onTimeout: (sink) {
        _logger.warn(
            '[ReAct] O6-1 $label: 6s idle timeout, abort (关闭上游连接)',
            cat: LogCat.react,
            tag: 'ReAct');
        // build120：真正取消上游——close 掉该 scope 的 http client，
        // 否则连接与协程会继续存活至 30s 空闲超时，并以无人接收的异常冒泡到 zone。
        // build141：只停**自己这一条**（集合里可能同时挂着兜底链与反问快捷回复链）。
        _abortOneSuggestScope(apiSvc, suggestScope,
            reason: '$label 空闲超时');
        sink.close();
      })) {
        if (_reactLoopStopRequested) return const [];
        buf.write(chunk);
      }
      final items = parseSuggestItems(buf.toString());
      if (items.isEmpty) {
        _logger.warn('[ReAct] $label: no usable items parsed',
            cat: LogCat.react, tag: 'ReAct');
      } else {
        _logger.info('[ReAct] $label: ${items.length} items',
            cat: LogCat.react, tag: 'ReAct');
      }
      return items;
    } catch (e) {
      // 静默失败：追问区保持为空，打点即可
      _logger.warn('[ReAct] $label failed: $e',
          cat: LogCat.react, tag: 'ReAct');
      return const [];
    } finally {
      // build141：走完 / 超时 / 异常 / 提前 return 四条出口都要摘掉自己的登记，
      // 否则「停止生成」会去停一条早就结束的流（不止无害：它会掩盖真正的漏取消）。
      _suggestScopes.remove(suggestScope);
    }
  }

  // ==========================================================================
  /// N4（build94）：委托给顶层纯函数 isTransportRetryableError（可单测）。
  bool _isTransportRetryable(Object e) => isTransportRetryableError(e);

  // ==========================================================================
  /// v1.3.4：向 workingMessages 注入"系统自检"消息（替代之前的弹窗方案）
  /// AI 下一轮看到这条消息后会输出 <self_check continue="true|false" reason="..."/>
  /// 不弹窗、不打断用户，纯 AI 自检。continue=false → 主循环终止。
  void _injectSelfCheck(List<ChatMessage> workingMessages, String rawContent) {
    // v1.7.4 fix: 解析真实的 ReAct 标签内容，而非 reasoningSteps 中的 UI 进度文字
    final parsed = _parseReActOutput(rawContent);
    final recentSteps = parsed
        .where((p) => p['type'] == 'thinking' || p['type'] == 'search')
        .toList()
        .reversed
        .take(3)
        .map((p) {
      final type = p['type']!;
      final content = p['content'] ?? '';
      final display = content.length > 80 ? content.substring(0, 80) : content;
      return '• [$type] $display';
    }).join('\n');
    final checkContent = '[系统自检] 你已思考一段时间。最近步骤：\n$recentSteps\n\n'
        '请判断：\n'
        '1) 你是否在重复同样的搜索/思考动作？\n'
        '2) 是否已经接近答案，需要继续？\n'
        '3) 是否该终止并基于已有信息给出回答？\n\n'
        '请输出 <self_check continue="true|false" reason="简短理由" />';
    // N3（build94）：与最近一条自检内容相同则不注入（防长流式期间堆叠重复自检）
    for (var i = workingMessages.length - 1; i >= 0; i--) {
      final m = workingMessages[i];
      if (m.role == MessageRole.user && m.content.startsWith('[系统自检]')) {
        if (m.content == checkContent) {
          _logger.info('[Chat] Self-check skipped (identical to last)',
              cat: LogCat.chat, tag: 'Chat');
          return;
        }
        break; // 只与最近一条自检比对，更早的视为已被 AI 消费
      }
    }
    workingMessages.add(ChatMessage.create(
      conversationId: widget.conversation.id,
      role: MessageRole.user,
      content: checkContent,
    ));
    _logger.info('[Chat] Self-check injected (20s timer)',
        cat: LogCat.chat, tag: 'Chat');
  }

  // 解析 <thinking>/<search query="..."/>/<answer>/<download />/<ask_user>...</ask_user> 混合输出，按出现顺序返回 list
  // piece: {'type': 'thinking' | 'search' | 'answer' | 'download' | 'ask_user', 'content': String, +attributes...}
  // v1.3.3: <ask_user> 的 content 可能含 "问题||选项1||选项2" 格式（用 || 分隔预设选项）
  List<Map<String, String>> _parseReActOutput(String s) => parseReActOutput(s);

  /// v1.7.24：提取原始响应中的 thinking 纯文本（用于行为指纹，判断 AI 是否原地复读）
  /// 只取真实 <thinking> 内容，不含 UI 进度文字（后者混在 reasoningSteps 里，不适合做指纹）。
  String _extractThinkingFingerprint(String rawResp) {
    final buf = StringBuffer();
    for (final m
        in RegExp(r'<thinking>([\s\S]*?)</thinking>').allMatches(rawResp)) {
      buf.write(m.group(1));
    }
    return buf.toString().trim();
  }

  /// v1.5.5：流式显示时去掉 ReAct 协议标签，只保留纯文本（避免用户看到 <search>/<thinking> 等）
  /// v1.7.26 修复（v2，状态化）：<answer> 标签可能跨多个流式 chunk（如 `<answer>内` 一个 chunk、
  /// `容</answer>` 下一个 chunk），纯正则逐 chunk 替换匹配不到未闭合的 answer 块，
  /// 导致最终答案提前混入 thinking step（"思考没结束就出结果、思考完又刷新"）。
  /// 现在用外部状态容器 ansState[0] 跨 chunk 追踪 answer 块。
  /// v1.7.37（⑰）：answer 块内容不再丢弃，而是增量 append 到 answerSink，
  /// 调用方据此实时刷新最终答案气泡，实现"结论也流式输出"；
  /// 轮末 _parseReActOutput 的最终解析只做确认/替换，两者同源不冲突。
  /// build114（补充单03 W5）：薄封装——实际逻辑已抽到
  /// `ReactStreamScrubber.scrub` 纯函数（可单测），状态由调用方持有。
  String _stripReActTagsForStream(String s, List<bool> ansState,
      List<String> pendingTag, StringBuffer answerSink,
      {List<bool>? askUserSeen}) {
    final r = ReactStreamScrubber.scrub(
      s,
      pendingTag: pendingTag[0],
      inAnswer: ansState[0],
      askUserSeen: askUserSeen?[0] ?? false,
    );
    pendingTag[0] = r.pendingTag;
    ansState[0] = r.inAnswer;
    if (askUserSeen != null) askUserSeen[0] = r.askUserSeen;
    // A1（W6）：提问轮止血——本轮已见 <ask_user> 时，answer 块内容不再流入
    // 答案缓冲（反问卡片与结论不得同屏）。answer 仍从 rawResp 解析出来，
    // 由下方「hasAskUserThisRound」守卫在分发层丢弃，这里只拦流式显示。
    if (r.answerOut.isNotEmpty && !(askUserSeen?[0] ?? false)) {
      answerSink.write(r.answerOut);
    }
    return r.display;
  }

  // v1.3.7 Bug #7：方法名从 _extractLastAnswer 改为 _extractFirstAnswer
  // 因为实现用 firstMatch（取第一个）。AI 协议规定只输出一次 <answer>，
  // firstMatch 与 lastMatch 行为等价，方法名与实现保持一致即可。
  String _extractFirstAnswer(String s) {
    final m = RegExp(r'<answer>([\s\S]*?)</answer>', caseSensitive: false)
        .firstMatch(s);
    if (m != null) return m.group(1)!.trim();
    // 没 <answer>：剥离协议思考标签，避免思考内容落入最终答案
    final t = s
        .replaceAll(
            RegExp(r'<(?:thinking|think)>[\s\S]*?</(?:thinking|think)>',
                caseSensitive: false),
            '')
        .replaceAll(
            RegExp(r'<(?:thinking|think)>[\s\S]*$', caseSensitive: false), '')
        .trim();
    if (t.isNotEmpty) return t;
    return RegExp(r'<(?:thinking|think)>', caseSensitive: false).hasMatch(s)
        ? ''
        : s;
  }
}

// ============================================================================
// N14（build94）：suggest 解析与兜底补生成的纯函数（可单测，无 Flutter 依赖）
// ============================================================================

/// 解析推荐追问文本为条目列表（与 <suggest> 标签处理同口径）：
/// 剥离 <suggest> 标签 → 先按 || 切分，只有 1 条时退按换行切分 →
/// 去行首序号/项目符号 → 过滤空项与超长项（>80 字）→ 去重 → 最多 4 条。
List<String> parseSuggestItems(String raw) {
  var text = raw
      .replaceAll(
          RegExp(r'</?suggest\b[^>]*>', caseSensitive: false), '')
      .trim();
  if (text.isEmpty) return const [];
  // 优先 || 分隔（协议格式）；只有一条时按行切（兜底生成可能直接逐行输出）
  var parts = text.split('||');
  if (parts.length <= 1) parts = text.split('\n');
  final items = <String>[];
  for (var p in parts) {
    // 去行首项目符号（- * •）与序号（1. / 1、 / (1)）
    p = p
        .trim()
        .replaceFirst(RegExp(r'^[-*•]\s*'), '')
        .replaceFirst(RegExp(r'^[（(]?\d{1,2}[）)、.．]\s*'), '')
        .trim();
    if (p.isEmpty || p.length > 80) continue;
    if (!items.contains(p)) items.add(p); // build93(S2)：去重
    if (items.length >= 4) break;
  }
  return items;
}

/// N14 兜底触发判定：答案已定稿、非用户终止、答案非空且 suggest 为空时才补生成。
///
/// A4（W7）：加提问轮维度——反问轮**不得**触发推荐。真机日志实锤：反问停留
/// 65 秒后用 thinking 原文当【回答】补出 3 条无关推荐。推荐只在 finalAnswer
/// 定稿后触发，入参必须是净化后的最终答案正文（不读 reasoning/thinking）。
///
/// G35（build124）：再加**控制片段维度**——答案正文若是工具调用参数/标签残片
/// （真机：68 字符 mcp 参数 JSON 被兜底定稿），它不是给用户的话，拿它当【回答】
/// 只会生成 3 条无关推荐。判据是确定性的结构判定（[AnswerFinalizer.isControlFragment]），
/// 不做词表猜写。
bool needsSuggestFallback({
  required bool answered,
  required bool stopRequested,
  required String answerContent,
  required List<String> suggestions,
  bool hasAskUserThisRound = false,
  // build147 第 11 轮：本轮被强制收尾/放弃（O9 零产出、G39 无结论）时，
  // 交付的是报错文案 + ↻ 重试，此时补一组"接下来问什么"是在粉饰失败。
  // 与 `stopRequested` 分开是刻意的：那个标志在 catch 里等于"用户按了停止"，
  // 蹭它会顺手改掉错误分级（本来就有两个不同含义，别再叠第三个）。
  bool giveUpThisRound = false,
}) {
  if (hasAskUserThisRound) return false;
  if (giveUpThisRound) return false;
  if (AnswerFinalizer.isControlFragment(answerContent)) return false;
  return answered &&
      !stopRequested &&
      answerContent.trim().isNotEmpty &&
      suggestions.isEmpty;
}

/// N4（build94）：传输类错误判定（纯函数，可单测）——连接/空闲超时、网络断开、
/// 连接重置、5xx、429 可自动重试；鉴权/参数类（401/400/404 等其它 4xx）重试无效。
/// api_service 统一 throw Exception(中文/英文消息串)，故按消息特征判定。
bool isTransportRetryableError(Object e) {
  final s = e.toString();
  // 用户主动停止不算传输错误 —— 只认这一条**真的是停止**的签名。
  //
  // build158 订正：旧写法在这里还顺带 `return false` 掉了
  // `Connection closed` / `closed while receiving`，注释写的是"用户主动停止"。
  // 那是把**网络签名当成"谁按了停止"的代答** —— 与 `catch` 里那次同一个错前提
  // （`classifyStreamEnd` 修的就是它），后果是这一类掉线**永远不走自动重试**。
  // 行为这里**故意先不改**：一轮已经收了 700 个 chunk 时自动重跑就是再付一次钱，
  // 值不值由用户定（他说 07:19:55 那次是他自己测后台）。
  // 想让它自动重试：删掉下面那个 `return false;` 即可 —— 再往下 `Network error`
  // 那一条本来就会把这类判成可重试。删之前请把这句注释一起更新，别留第二处假前提。
  if (s.contains('已停止')) return false;
  if (s.contains('Connection closed') || s.contains('closed while receiving')) {
    return false; // ← 有意保守：掉线不自动重跑（会重复计费），见上面注释
  }
  if (s.contains('连接超时') || s.contains('响应超时')) return true;
  if (s.contains('Network error') || s.contains('HTTP error')) return true;
  if (s.contains('SocketException') || s.contains('Connection reset')) {
    return true;
  }
  if (RegExp(r'HTTP 5\d\d').hasMatch(s)) return true;
  if (s.contains('HTTP 429')) return true; // 限流，退避后可重试
  return false;
}

/// E5（build94）：工具调用指纹（纯函数，可单测）。
/// 同一动作类型+关键参数归一化后拼接，用于识别"同一插件同一参数"的重复调用。
/// 参数整体 trim+压缩空白，避免模型输出空白抖动绕过检测。
///
/// build111 修复（build110 检测批发现）：原实现只读 tools 通道的字段名，
/// 标签通道（parseReActOutput 产出）的实际字段读不到——search 的 query 在
/// `content` 里、mcp_call 在 `arguments` 里、log_query 在 `category` 里 →
/// 同类动作指纹恒等（`search|` / `log_query|`）。后果：①E5 把「3 次不同搜索」
/// 误判为重复调用并熔断（潜伏自 build94）；②build110 的同轮去重会把第二个
/// 不同参数的同类动作直接丢弃。现按「两通道字段名双兼容 + 动作特征参数」重建。
String buildToolCallFingerprint(Map<String, String> p) {
  String norm(String? s) =>
      (s ?? '').trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
  final type = p['type'] ?? '';
  switch (type) {
    case 'search':
      // 标签通道 query 落在 content；tools 通道同样落 content（AgentAction）
      final q = p['content'] ?? p['query'];
      return 'search|${norm(q)}|${norm(p['depth'])}';
    case 'mcp_call':
      // 标签通道参数在 arguments（JSON 串）；旧代码读 content 恒空
      final args = p['arguments'] ?? p['content'];
      return 'mcp|${norm(p['pluginId'])}|${norm(p['tool'])}|${norm(args)}';
    case 'skill_call':
      final args = p['arguments'] ?? p['content'];
      return 'skill|${norm(p['name'])}|${norm(args)}';
    case 'download':
      return 'download|${norm(p['url'] ?? p['keyword'] ?? p['content'])}';
    case 'install_skill':
      return 'install_skill|${norm(p['name'] ?? p['url'] ?? p['query'])}';
    case 'log_query':
      // build111：日志查询的区分参数在 category/keyword/tail（此前全丢）
      return 'log_query|${norm(p['category'])}|${norm(p['keyword'])}|${norm(p['tail'])}';
    case 'query_quota':
      return 'query_quota|${norm(p['refresh'])}';
    case 'get_location':
    case 'ip_locate':
      // 无参动作：同类型即同调用
      return type;
    default:
      return '$type|${norm(p['content'])}';
  }
}

/// E3（build94）：C 类不可恢复配置错误判定（纯函数，可单测）。
/// 命中时返回人话原因；未命中返回 null（走传输中断/通用错误分支）。
/// 覆盖：401/403 鉴权、配额不足、model not found、未配置 API key。
/// 注意与 _isTransportRetryable 互斥：B 类（429/5xx/超时/断连）不在这里。
String? fatalConfigErrorKind(Object e, {required bool isZh}) {
  final s = e.toString().toLowerCase();
  // 用户主动停止/传输类不归这里
  if (s.contains('connection closed') ||
      s.contains('closed while receiving') ||
      s.contains('已停止')) {
    return null;
  }
  final has401 = s.contains('401') || s.contains('unauthorized');
  final has403 = s.contains('403') || s.contains('forbidden');
  final hasAuthWord = s.contains('authentication') ||
      s.contains('invalid api key') ||
      s.contains('invalid_api_key') ||
      s.contains('incorrect api key') ||
      s.contains('鉴权') ||
      s.contains('认证失败');
  if (has401 || has403 || hasAuthWord) {
    return isZh ? 'API 密钥无效或已过期（鉴权失败）' : 'Invalid or expired API key (authentication failed)';
  }
  if (s.contains('quota') ||
      s.contains('insufficient') ||
      s.contains('余额不足') ||
      s.contains('配额') ||
      s.contains('billing') ||
      s.contains('exceeded your current quota')) {
    return isZh ? 'API 配额/余额不足' : 'API quota or balance exhausted';
  }
  if (s.contains('model not found') ||
      s.contains('model_not_found') ||
      (s.contains('does not exist') && s.contains('model')) ||
      s.contains('模型不存在') ||
      s.contains('invalid model')) {
    return isZh
        ? '所选模型不存在或已下线'
        : 'Selected model not found or deprecated';
  }
  if ((s.contains('api key') &&
          (s.contains('missing') ||
              s.contains('empty') ||
              s.contains('not set') ||
              s.contains('未配置') ||
              s.contains('为空'))) ||
      s.contains('未配置 api') ||
      s.contains('请先配置') ||
      s.contains('no api key')) {
    return isZh ? '未配置 API 密钥' : 'API key not configured';
  }
  return null;
}

/// 构造兜底补生成的轻量提示词（不带 ReAct 协议，只要 || 分隔的追问）。
/// question/answer 截断防超长，控制请求体量。
String buildSuggestFallbackPrompt({
  required String question,
  required String answer,
  required bool isZh,
}) {
  String trunc(String s, int n) => s.length > n ? s.substring(0, n) : s;
  final q = trunc(question.trim(), 500);
  final a = trunc(answer.trim(), 1500);
  return isZh
      ? '基于下面的用户提问和回答，生成 3 条用户最可能追问的后续问题。\n'
          '要求：每条一行或用 || 分隔；不要序号；每条不超过 30 字；'
          '只输出问题本身，不要任何解释。\n\n'
          '【用户提问】$q\n\n【回答】$a'
      : 'Based on the user question and answer below, generate 3 follow-up '
          'questions the user is most likely to ask next.\n'
          'Rules: one per line or separated by ||; no numbering; '
          'each under 30 chars; output the questions only, no explanation.\n\n'
          '[Question] $q\n\n[Answer] $a';
}

/// build140 反馈④：反问面板的「可选答复」提示词。
///
/// 与 [buildSuggestFallbackPrompt] 的**语义不同**，所以必须另写一条而不是复用：
///  · 兜底链产出的是"用户接下来会问什么"（追问），入参是**已定稿的答案**；
///  · 这条产出的是"用户可以怎么答"（答复），入参是**反问正文 + 选项**。
/// A4（W7）当年的病灶正是"拿 thinking 原文当【回答】去补推荐"⇒ 三条无关追问。
/// 这里从根上避开：种子只有反问那一句话和它给出的选项，模型看不到也编不出别的。
String buildAskUserSuggestPrompt({
  required String question,
  required List<String> options,
  required bool isZh,
}) {
  String trunc(String s, int n) => s.length > n ? s.substring(0, n) : s;
  final q = trunc(question.trim(), 300);
  final opts = options.map((e) => trunc(e.trim(), 40)).where((e) => e.isNotEmpty).join(' / ');
  return isZh
      ? 'AI 正在向用户提一个澄清问题，并已给出下列可选项。\n'
          '请生成 3 条**用户也可能直接这样答复**的短句，作为可点选的快捷回复；'
          '要求：\n'
          '- 不要重复已经列出的选项，也不要写进选项里已有措辞的同义改写；\n'
          '- 可以是"多个都要""让用户替我选一个""都不是，我补充说明"这类答复方向；\n'
          '- 每条不超过 20 字；用 || 分隔或一行一条；不要序号；只输出答复本身。\n\n'
          '【问题】$q\n\n【已给出的选项】${opts.isEmpty ? "（无）" : opts}'
      : 'The AI is asking the user a clarifying question and has listed options below.\n'
          'Generate 3 short replies the user might instead send, as tappable quick replies.\n'
          'Rules:\n'
          '- Do NOT repeat the listed options or paraphrase them;\n'
          '- Directions like "both/all", "you pick one", "none of these, let me explain" are valid;\n'
          '- Each under 20 chars; separate by || or one per line; no numbering; output replies only.\n\n'
          '[Question] $q\n\n[Given options] ${opts.isEmpty ? "(none)" : opts}';
}
