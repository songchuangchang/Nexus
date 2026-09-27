// part 文件通过 extension 访问宿主 _ChatScreenState 的受保护成员 setState，
// 属 part-of + extension 拆分架构的固有模式，统一豁免。
// ignore_for_file: invalid_use_of_protected_member, library_private_types_in_public_api
// build129（#107）：子代理编排器接入发送链路。
//
// 背景：AgentOrchestrator（lib/services/agent_orchestrator.dart，v1.7.34 落地）此前
// **全库零调用点**——会话设置里的「子代理模式」5 档（自动 / 仅主 Agent / 强制搜索 /
// 强制综合 / 强制插件）除了 main_only 正好等于"从未接线"的现状，其余 4 档全是空档：
// 选了也不生效，且没有任何反馈。本文件把它接进 _sendMessage 的 ReAct 分叉点。
//
// 分工（唯一判定入口：services 层 subagentModeUsesOrchestrator，build146 重定）：
//   - auto / main_only / force_plugin → 走原有 ReAct 循环，**一行不改**
//     （force_plugin 本就由 ReAct 执行；auto 不再付路由调用；深度研究的 auto
//      经 effectiveSubagentMode 升为 force_search 才落到下面这条）
//   - force_search / force_synthesis → 先走编排器；拿到结果则整轮结束
//
// 回退契约（不静默）：
//   编排器返回 null（LLM 调用超上限）或抛异常（网络/鉴权/格式）时：
//     ① 撤销占位气泡（UI + DB 各一次，否则会话里留一个空白助手气泡）；
//     ② 记 warn 日志；
//     ③ 弹一条「已回退到自主思考」提示；
//     ④ 交回 ReAct 继续答——单个编排故障不会把整条发送链路打死。
//   只有一种例外不回退：**用户主动按了停止**。此时保留已产出内容并收尾，
//   否则用户按下停止反而触发新一轮生成（把"停止"变成"重来"）。
//
// 与 ReAct 的收尾同构：复位生成态 → 消费插话队列 → 落库 → 触发记忆摘要 →
// 刷新用量条/吸底。

part of 'chat_screen.dart';

extension ChatScreenOrchestratorExt on _ChatScreenState {
  /// build132：编排路径补上下文的体积上限（防止把路由/专家/合成 prompt 撑爆）。
  static const int kOrchHistoryMaxMessages = 8;
  static const int kOrchHistoryPerMessageChars = 600;
  static const int kOrchHistoryTotalChars = 4000;
  static const int kOrchAttachmentChars = 1200;

  /// build132：给编排器补「上下文」（跨对话记忆 / 长期记忆 / 知识库 / 助手人设 / 历史尾巴）。
  ///
  /// 根因（真机：「上下文记忆有点问题，AI 不会看，包括之前的文件」）：
  /// `AgentOrchestrator.run` 只收 `userMsg`，路由/专家/合成三步的 prompt 里
  /// **只有当前这一句**（见 `_dispatchSynthesisAgent` 的
  /// `'用户问题：$userText\n\n已收集证据：…'`）。而 build132 当时门控是
  /// 「非 main_only 全走编排」（`subagentModeUsesOrchestrator`，旧口径见 services 层
  /// 该函数的 build146 注释）⇒ **默认档每轮都先走这条路**，于是：
  ///   ① 记忆（跨对话摘要 / 全局·项目记忆）照常生成、却从不注入；
  ///   ② 会话绑定的知识库、助手人设看不到；
  ///   ③ 之前聊过的内容、之前放进去的文件全都看不到。
  ///
  /// 修法：**不改编排器内部提示词**（那是路由逻辑，动它风险大），在宿主侧把上下文
  /// 拼进交给它的那条用户消息——路由/专家/合成三步天然都读得到。构造与开关判断
  /// 与 ReAct / 普通路径同源（同一批函数），不再各写一份、也不再漏一段。
  /// 无上下文可补时**原样返回**（行为与改动前逐字一致，零回归）。
  /// 同时返回一句**注入摘要**（如「历史 6 条 · 知识库 · 助手人设」），由宿主写进
  /// 思考面板——面板从此能自证「这一轮到底读到了什么」，不必导出日志才能核对。
  Future<(ChatMessage, String)> _buildOrchestratorUserMessage(
    ChatMessage userMsg,
    ApiConfig cfg,
    bool isZh,
  ) async {
    // build146（prompt cache ④）：这一段最终拼进**一条 user 消息**，不参与 Anthropic
    // system 断点，但仍按同一档位顺序「稳定在前、每轮变的在后」重排 —— 与各调用点
    // 共用同一个排序真身 planPromptPrefix，不再各写一套顺序（每块带自己的 PromptBlockKind）。
    final prefixBlocks = <PromptBlock>[];
    final marks = <String>[];

    // ① 跨对话摘要（memoryEnabled 控制，与 ReAct 同源）
    if (widget.conversation.memoryEnabled) {
      try {
        final summaries = await context
            .read<StorageService>()
            .getRecentSummaries(3, excludeId: widget.conversation.id);
        if (summaries.isNotEmpty) {
          final sb = StringBuffer(isZh
              ? '【跨对话记忆 · 最近对话摘要】'
              : '[Cross-chat memory · recent summaries]');
          for (final s in summaries) {
            sb.write(
                '\n- ${(s['title'] as String?) ?? ''}: ${(s['summary'] as String?) ?? ''}');
          }
          prefixBlocks.add(PromptBlock(PromptBlockKind.crossChatSummary,
              text: sb.toString()));
          marks.add(isZh ? '跨对话记忆 ${summaries.length} 段' : 'memory ${summaries.length}');
        }
      } catch (_) {
        // 静默降级：记忆读失败不影响本轮回答
      }
    }

    // ② 长期记忆（全局/项目，longTermMemoryEnabled 独立开关控制）
    if (widget.conversation.longTermMemoryEnabled) {
      try {
        final mem = await MemoryBlockBuilder.build(
            widget.conversation.projectId, isZh: isZh);
        if (mem.isNotEmpty) {
          prefixBlocks.add(PromptBlock(PromptBlockKind.longTermMemory,
              text: mem));
          marks.add(isZh ? '长期记忆' : 'long-term memory');
        }
      } catch (_) {
        // 静默降级
      }
    }

    // ③ 知识库 RAG（按本轮问题检索；与普通/ReAct 路径同一个函数）
    try {
      final kb = await _buildKnowledgeContext(userMsg.content, cfg, isZh: isZh);
      if (kb != null && kb.content.trim().isNotEmpty) {
        prefixBlocks.add(PromptBlock(PromptBlockKind.knowledgeRetrieval,
            text: kb.content.trim()));
        marks.add(isZh ? '知识库' : 'knowledge base');
      }
    } catch (_) {
      // 静默降级
    }

    // ④ 助手人设（会话绑定的自定义助手）
    try {
      final ab = await _buildAssistantBlock();
      if (ab != null && ab.content.trim().isNotEmpty) {
        prefixBlocks.add(PromptBlock(PromptBlockKind.assistantPersona,
            text:
                '${isZh ? '【助手人设】' : '[Assistant persona]'}\n${ab.content.trim()}'));
        marks.add(isZh ? '助手人设' : 'assistant persona');
      }
    } catch (_) {
      // 静默降级
    }

    // ⑤ 历史尾巴（含历史消息里的附件正文——「之前的文件」主要就在这里）
    final hist = _messages
        .where((m) => m.id != userMsg.id)
        .where((m) => m.role != MessageRole.assistant || m.content.isNotEmpty)
        .toList();
    final tail = hist.length > kOrchHistoryMaxMessages
        ? hist.sublist(hist.length - kOrchHistoryMaxMessages)
        : hist;
    if (tail.isNotEmpty) {
      final sb = StringBuffer(isZh ? '【最近对话】' : '[Recent conversation]');
      var used = 0;
      for (final m in tail) {
        if (used >= kOrchHistoryTotalChars) break;
        final who = m.role == MessageRole.user
            ? (isZh ? '用户' : 'User')
            : (isZh ? 'AI' : 'AI');
        var line = '$who: ${_clipForOrchestrator(m.content, kOrchHistoryPerMessageChars)}';
        for (final a in m.attachments) {
          final t = a.extractedText;
          if (t != null && t.isNotEmpty) {
            line +=
                '\n  [附件] ${a.fileName}: ${_clipForOrchestrator(t, kOrchAttachmentChars)}';
          }
        }
        sb.write('\n$line');
        used += line.length;
      }
      // 历史尾巴：没有专用档位（PromptBlockKind 里没有 history 档）。它随对话增长
      // 每轮都在变 ⇒ 按硬约束保守归 unknown，落到易变段**最末尾**（rank 900），
      // 绝不允许它把前面的稳定块带偏。
      prefixBlocks.add(PromptBlock(PromptBlockKind.unknown,
          text: sb.toString()));
      marks.add(isZh ? '历史 ${tail.length} 条' : 'history ${tail.length}');
    }

    // ⑥ 本条消息的附件正文（编排器的 _call 只发文本、不解析多模态）
    final curAtt = StringBuffer();
    for (final a in userMsg.attachments) {
      final t = a.extractedText;
      if (t != null && t.isNotEmpty) {
        curAtt.write(
            '\n[附件] ${a.fileName}:\n${_clipForOrchestrator(t, kOrchAttachmentChars)}');
      } else {
        curAtt.write('\n[附件] ${a.fileName}'
            '（${isZh ? '未抽取到正文' : 'no extracted text'}）');
      }
    }
    if (userMsg.attachments.isNotEmpty) {
      marks.add(isZh
          ? '本条附件 ${userMsg.attachments.length} 个'
          : '${userMsg.attachments.length} attachment(s)');
    }

    if (prefixBlocks.isEmpty && curAtt.isEmpty) return (userMsg, '');

    final header = isZh
        ? '（以下为理解该问题所需的会话上下文，请一并参考；不要复述本段）'
        : '(Context below helps you understand the question; do not repeat it.)';
    // build146（prompt cache ④）：交给 planPromptPrefix 决定这些块的顺序
    // （人设 rank20 → 长期记忆 rank100 → 跨对话摘要 rank110 → 知识库 rank200
    // → 历史 unknown rank900），稳定在前、每轮变的在后；拼接分隔符与原 parts.join
    // 保持 '\n\n' 一致（render 默认分隔符）。它拼进的是**一条 user 消息**，
    // 不参与 Anthropic 断点，所以这里只取顺序、不数 stableBlockCount。
    final orderedContext = planPromptPrefix(prefixBlocks).render();
    final content = '${userMsg.content}'
        '${curAtt.isNotEmpty ? '\n$curAtt' : ''}'
        '\n\n--- $header ---\n$orderedContext';

    final enriched = ChatMessage.create(
      conversationId: userMsg.conversationId,
      role: MessageRole.user,
      content: content,
      modelName: userMsg.modelName,
    )
      // 撤回/重发靠这两个字段关联，必须原样带上（宿主占位气泡也读它）
      ..retryOf = userMsg.retryOf
      ..retryIndex = userMsg.retryIndex
      ..attachments.addAll(userMsg.attachments);

    return (enriched, marks.join(' · '));
  }

  static String _clipForOrchestrator(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…';

  /// 用子代理编排器回答一条用户消息。
  ///
  /// 返回 true  = 本轮已处理完（含被用户停止），调用方**不要**再进 ReAct；
  /// 返回 false = 编排未产出（未配置 / null / 异常且非用户停止），调用方回退 ReAct。
  Future<bool> _runOrchestratedAnswer(
    ChatMessage userMsg,
    ApiService apiSvc,
    StorageService storage,
  ) async {
    final cfg = _apiConfig;
    if (cfg == null) return false; // 无 AI 配置：交给既有分支出「未配置」提示
    final mode = widget.conversation.subagentMode;
    // build146（子代理：路由不再单独花钱）：面板与日志都要报**归一化后**的档位。
    // 只报存值的话，深度研究那一轮会写着「子代理模式：auto」却实际按 force_search
    // 跑（不花路由调用）——写在面板上的就是假信息。判据仍是 services 层那一个纯函数。
    final deep =
        ApiService.isDeepResearchEffort(widget.conversation.reasoningEffort);
    final effectiveMode =
        effectiveSubagentMode(storedMode: mode, deep: deep);
    final l = AppLocalizations.of(context);
    final isZh = l.locale.languageCode == 'zh';

    // 1) 占位气泡：与 ReAct 同构——先加 user + assistant、预插 DB，
    //    这样编排期间的进度/流式正文都有地方落，进程被杀也不丢已产出内容。
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
        isZh
            ? '正在编排：取证 → 综合 → 作答（档位 $mode → 实际 $effectiveMode，本轮不花路由调用）'
            : 'Orchestrating: evidence → synthesis → answer (mode $mode → $effectiveMode, no router call this round)',
        phase: 'orchestrate',
        round: 1,
      ));

    // build155：与 `chat_screen_react.dart:244` 同一个竞态 —— 这一行在
    // `_assembleOrchestrationContext()`（记忆 / 知识库 / RAG 向量化，真机几十秒）**之前**，
    // 但发送入口到此处之间仍可能吃到一次「停止」；无脑清 false 会让那一按凭空消失，
    // 于是岛写「· 已完成」而 App 写「已手动停止」。判据统一走 `reactStopCarried`。
    _reactLoopStopRequested =
        reactStopCarried(stopRound: _reactStopRound, round: _reactRound);
    // build155：与 ReAct 入口同构 —— "谁停的"那一半单独记，收尾文案才不至于
    // 把系统自己决定的提前结束说成用户的操作。
    _reactLoopUserStopped =
        reactStopCarried(stopRound: _reactStopRound, round: _reactRound);

    // 与 ReAct 轮首同构：清理上一轮残留的流，避免旧流占着生成态导致本条被误停。
    apiSvc.stopGeneration(
        scope: widget.conversation.id, reason: '编排路径开始，清理上一轮残留流');
    _abortSuggestStream(apiSvc, reason: '编排路径开始，清理残留兜底流');

    if (mounted) {
      setState(() {
        if (!_messages.contains(userMsg)) _messages.add(userMsg);
        _messages.add(assistantMsg);
        _isStreaming = true;
      });
      _autoFollow = true;
      _scrollToBottom();
    }
    _lastAssistantDbSaveMs = 0;
    _lastAssistantDbSaveLen = 0;
    await _persistRoundAssistant(storage, assistantMsg);

    final webCfg = await storage.getWebSearchConfig();
    // build130：不再向编排器递插件清单 —— 插件目标已交回 ReAct 执行
    // （编排器无插件执行引擎，递清单只会让"插件专家"照着输出调不动的调用）。

    // 流式原始缓冲（未剥标签）。净化用**全量重算**而不是增量拼接：
    // ReAct 那条路为了性能维护了跨 chunk 标签状态机（ansState/pendingTag），
    // 编排路径的正文量级小得多，全量重算既简单又不会漏状态。
    final rawBuf = StringBuffer();
    var searchHits = 0;
    // build146（第 10 轮 · 账单不许静默）：编排路径的多轮 LLM 调用此前**一条 token
    // 都不回传**——用户看气泡上的用量以为是「这次回答花了多少」，实际是空的。
    // 累积语义与 ReAct 同款（`merge`），不新造机制。
    // 声明在 try **外面**：catch 里的「用户已停止」收尾路径也要落账，
    // 放进去就看不见这个变量了（Dart 的 try 块自带作用域）。
    var orchUsage = const TokenUsage();
    // 只写一次的实现：两条收尾路径（正常 / 用户停止）都要落账，
    // 复制两遍就会出现「一条改了另一条没改」。
    void applyOrchUsage() {
      assistantMsg.promptTokens = orchUsage.promptTokens;
      assistantMsg.completionTokens = orchUsage.completionTokens;
      assistantMsg.totalTokens = orchUsage.totalTokens;
      assistantMsg.cacheReadTokens = orchUsage.cacheReadTokens;
      assistantMsg.cacheWriteTokens = orchUsage.cacheWriteTokens;
      assistantMsg.cacheHitTokens = orchUsage.cacheHitTokens;
      assistantMsg.cacheMissTokens = orchUsage.cacheMissTokens;
    }

    // build149（真机反馈「在这些地方退出没有灵动岛」）：编排这条路**以前完全不上岛**。
    // `onResearchStart` 只挂在 `chat_screen_react.dart:134`（进 ReAct 循环之前），
    // 而这条路在 `chat_screen_message.dart:245` 就分流出去了 —— 编排成功时
    // `if (handled) return`，那一行根本没机会创建。截图里那 7 步（正在编排 /
    // 本轮上下文 / 路由判断 / 检索词 / 检索命中）全在编排器内部，所以整段期间
    // 退到后台就是"没有岛"。`live_task_wiring.dart` 的注释从 build148 起就写着
    // "那条由 chat_screen_orchestrator.dart 自己接同样的 start/update/end" ——
    // 那是一句**没有实现的承诺**，本次把它兑现。
    // 起点刻意放在 `try` 之前、上下文装配之前：装配（记忆/知识库/RAG 向量化）
    // 本身就是用户会退出去等的几十秒。
    //
    // build161（真机反馈「那个灵动岛他不是一瞬间就出来的…它是过几秒钟之后才有的」）：
    // 现在**这一行早就在了** —— `_sendMessage` 入口在任何 await 之前就登记了
    // 「已发送 · 正在准备」，上面那些 await（探活 / 落库 / 插件枚举 / MCP 注册 / 装配）
    // 全部落在"屏幕上已经有这一行"之后。这次调用只把文案换成本轮的真实形状。
    // 不必改成"只更新文案"的另一半入口：同一 id 重复 `onResearchStart` 是
    // `LiveTaskCenter.upsert` 覆盖 ⇒ 一行、且 build156 那条时限不重置
    // （语义见 `live_task_wiring.dart` 里 `onResearchStart` 的那段核对）。
    //
    // 归属逐条对得上（谁摘这一行）：
    //  · 定稿成功 / 用户按停止 —— 本文件下面那两个出口自己 end（各自先 `_claimSendIsland`）；
    //  · `return false` 回退 ReAct 的几条出口 —— **刻意不 end**：接手的那一轮还要用
    //    这一行显示后半程，在这里摘就是"岛闪一下又没了"；真出事由 ReAct 的 finally
    //    或 `_sendMessage` 入口那层兜底 finally 收（没人认领 ⇒ 安静撤掉）。
    unawaited(LiveTaskWiring.onResearchStart(userMsg.id,
        '编排 · 路由 → 专家 → 合成（$effectiveMode）', deep: deep));

    try {
      // build132：编排路径此前只把「当前这一句」交给模型（见
      // _buildOrchestratorUserMessage 注释）⇒ 记忆/知识库/助手/历史全都看不到。
      // 这里把上下文拼进用户消息；日志 + 思考面板**双留证据**（真机可直接核对）。
      final (orchUserMsg, ctxMarks) =
          await _buildOrchestratorUserMessage(userMsg, cfg, isZh);
      _logger.info(
          '[Orch] 上下文注入：${orchUserMsg.content.length} 字符'
          '（原消息 ${userMsg.content.length}）'
          '${ctxMarks.isEmpty ? ' · 无上下文可补' : ' · $ctxMarks'}',
          cat: LogCat.react,
          tag: 'Orch');
      // build132：面板自证——此前导出的「思考过程」只有 `target=…` / `chars=240`
      // 这类内部标记，用户体感是「没有思考过程」。把「本轮实际读到了什么」
      // 讲成人话，面板即可自证注入是否生效，不必导出日志才能核对。
      if (ctxMarks.isNotEmpty) {
        assistantMsg.addReasoning(ReasoningStep(
          'context',
          isZh ? '本轮上下文：$ctxMarks' : 'Context: $ctxMarks',
          phase: 'orchestrate',
          round: 1,
        ));
        if (mounted) setState(() {});
      }
      final result = await AgentOrchestrator(apiSvc, _logger).run(
        userMsg: orchUserMsg,
        cfg: cfg,
        conversation: widget.conversation,
        webCfg: webCfg,
        onUsage: (u) => orchUsage = orchUsage.merge(u),
        onStep: (step) {
          // 实时进度：用户在多轮编排期间能看到「路由/取证/合成」逐步出现
          assistantMsg.addReasoning(step);
          if (mounted) setState(() {});
          _followBottomIfNeeded();
          // build149：同一个事件刷到灵动岛那条行 —— 面板与岛**必须同源同步**，
          // 否则岛会一直停在「准备中」那一行（正是 148 反馈③ 的形状）。
          // 走 `onStep` 而不是另找时机：这是编排器唯一的进度出口，写第二处
          // 就会有两套口径。detail 由 `oneLine` 统一裁长度（岛里只有一行地方）。
          // build152（用户「一直是准备中，下面一条线有什么用」）：同一行事件再带上
          // **分段进度**。阶段从面板已有的步骤里推（上面刚 addReasoning 过），
          // 不在这里另存一个计数器 —— 与上一句同一个理由：存两份就有两套口径。
          unawaited(LiveTaskWiring.onResearchUpdate(userMsg.id,
              LiveTaskWiring.oneLine(step.content),
              deep: deep,
              stages: LiveTaskWiring.orchStagesFromPhase(
                  assistantMsg.reasoningSteps.map((s) => s.phase))));
        },
        // build135：合成阶段的真实推理并入思考面板——此前编排路径把它整段丢掉，
        // 面板里只剩「正在编排 / 路由判断 / 已生成回答」这类账本行，用户体感就是
        // 「有时没有思考过程」（ReAct 轮有、编排轮没有）。累积语义直接复用 ReAct
        // 同款 `appendLastThinking`，不新造机制。
        onReasoning: (rc) {
          if (rc.isEmpty) return;
          assistantMsg.appendLastThinking(rc);
          if (mounted) setState(() {});
        },
        onAnswerDelta: (delta) {
          if (delta.isEmpty) return;
          rawBuf.write(delta);
          assistantMsg.content = AnswerFinalizer.stripTags(rawBuf.toString());
          if (mounted) setState(() {});
          _followBottomIfNeeded();
          // 与 ReAct 同构的**节流落库**：合成正文是"专家跑完才出"的最后一段，
          // 但这段往往最长；不落库的话进程被杀就整段丢失（本文件开头承诺的
          // "进程被杀也不丢已产出内容"必须由这一行兑现，而不是靠占位气泡）。
          unawaited(_throttledSaveAssistantContent(
            storage,
            assistantMsg,
            assistantMsg.content,
          ));
        },
      );

      // build165 ①：本端在"离开 App"那一刻把这条流收起来了 ⇒ 手里这份"完成"不可信
      // （连接是我们关的，正文很可能是半截）。抛给自己的 catch 走那**一个**落点，
      // 不在这里再写一份收尾文案：定稿只有 `answer_finalizer.dart` 一条出口，
      // 退后台那一态的判据与文案只有 `drop_continue.dart` 一份（教训 #62）。
      if (leftAppAbortCarried(
          abortedRound: _leftAppAbortRound, round: _reactRound)) {
        throw const LeftAppAbortSignal();
      }

      if (result == null) {
        await _rollbackOrchestrationPlaceholder(assistantMsg, storage,
            burned: orchUsage);
        _logger.warn(
            '[Orch] 编排未产出内容（mode=$mode，LLM 调用超上限）→ 回退 ReAct',
            cat: LogCat.react,
            tag: 'Orch');
        _notifyOrchestratorFallback(isZh);
        return false;
      }

      // build130：**插件目标交回 ReAct**（真机回归修复）。
      // 编排器没有插件执行引擎，`target=plugin` 时它只回一条路由结论；
      // 这里静默撤销占位气泡并交回 ReAct，由后者真正执行 `<image_gen/>` 等动作。
      // ⚠️ 必须**静默**（不出 SnackBar）：这不是失败，是正常交接——真机上
      // 「生成图片」这类请求全都走这条交接，弹提示只会让用户以为又出错了。
      if (result.delegateToReact) {
        await _rollbackOrchestrationPlaceholder(assistantMsg, storage,
            burned: orchUsage);
        _logger.info(
            '[Orch] target=plugin → 交回 ReAct 执行（编排器无插件执行引擎，llmCalls=${result.llmCallCount}）',
            cat: LogCat.react,
            tag: 'Orch');
        return false;
      }

      // 2) 定稿：正文以返回值（完整文本）为准——流式期间 buffer 是半截的，
      //    这里覆盖成权威结果，顺带纠正「流式没来得及剥干净的半截标签」。
      var answer =
          result.answer.isNotEmpty ? result.answer : rawBuf.toString();
      final fin = AnswerFinalizer.finalize(answer);
      if (fin.stripped.isNotEmpty) {
        // 与直聊/ReAct 同规则：剥除物回思考块，**不静默丢弃**
        _logger.warn(
            '[Orch] L1 stripped ${fin.stripped.length} chars of meta talk from synthesized answer',
            cat: LogCat.react,
            tag: 'Orch');
        assistantMsg.appendLastThinking('\n${fin.stripped}\n');
      }
      answer = fin.clean;

      if (answer.trim().isEmpty) {
        // 极端：模型只吐控制标签 / 空串 → 等同于没答出来，仍走回退而非落地空气泡
        await _rollbackOrchestrationPlaceholder(assistantMsg, storage,
            burned: orchUsage);
        _logger.warn('[Orch] 净化后正文为空（mode=$mode）→ 回退 ReAct',
            cat: LogCat.react, tag: 'Orch');
        _notifyOrchestratorFallback(isZh);
        return false;
      }

      assistantMsg.content = answer;
      // 命中数落库前必须过 sanitizeSearchHits——历史上 999999999 这类脏值
      // 会把气泡徽标顶爆（ChatMessage.maxSaneSearchHits 就是为此而立）。
      searchHits = ChatMessage.sanitizeSearchHits(result.searchHitCount);
      assistantMsg.injectedWebSearchCount = searchHits;

      // build132：target 改由 OrchestrationResult 显式回传——route 步骤的 content
      // 已人话化（「路由判断：<原因>（target=self）」），若继续从步骤文本里抠，
      // 收尾日志会变成一长串中文，破坏「[Orch] 完成 … target=…」的可检索性。
      _logger.info(
          '[Orch] 完成 mode=$mode effective=$effectiveMode target=${result.target} '
          'llmCalls=${result.llmCallCount} hits=$searchHits chars=${answer.length}',
          cat: LogCat.react,
          tag: 'Orch');

      // build146（透明度，"响应里的 model 字段不许藏"那条原则的本地版）：这一轮
      // 走的哪条路、花了几次 LLM 调用，必须能在**消息本身**里读到，而不是只有日志。
      // 复用已随消息持久化的 `reasoningSteps`（不新增 DB 列）；orchestrator 侧的
      // llmCallCount / target 本来就是 OrchestrationResult 的现成字段。
      assistantMsg.addReasoning(ReasoningStep(
        'path',
        isZh
            ? '本轮路径：编排器（$effectiveMode → target=${result.target}）· '
                'LLM 调用 ${result.llmCallCount} 次 · 检索命中 $searchHits 条'
            : 'Round path: orchestrator ($effectiveMode → target=${result.target}) · '
                '${result.llmCallCount} LLM calls · $searchHits search hits',
        phase: 'orchestrate',
        round: 1,
      ));

      applyOrchUsage();
      await _finishOrchestratedAnswer(assistantMsg, storage, searchHits);
      // build149：谁开的行谁关。build150 起成功也**留在岛上写一行「· 已完成」**
      // （用户：「完成之后是没退了但也没显示完成√」）——停 `terminalHold` 秒再撤，
      // 与 ReAct 的 finally 同口径，两边不再一条留、一条直接消失。
      // build161：先认领再收尾 —— 这一行是 `_sendMessage` 入口登记的，
      // 不认领就会被入口那层兜底 finally 抢先把「· 已完成」撤掉。
      _claimSendIsland(userMsg.id);
      unawaited(LiveTaskWiring.onResearchEnd(userMsg.id, deep: deep));
      return true;
    } catch (e, st) {
      // 3) 异常分两类，处置**必须不同**：
      //    · 用户按了停止 → 保留已产出内容直接收尾（回退 ReAct 会把"停止"变成"重来"）；
      //    · 真错误（网络/鉴权/格式）→ 撤销占位、提示、回退 ReAct。
      // build155 订正变量名：这个布尔的写入方**不止用户**（还有退页 dispose、
      // MCP 触顶、E5 熔断），所以控制流按"要不要停"走，**文案与日志按"谁停的"分岔**
      // （判据 `stopNote` / `_reactLoopUserStopped`）。原来它叫 `userStopped`，
      // 于是这一族把系统自己的决定一路说成是用户干的。
      final stopRequested = _reactLoopStopRequested;

      // build165 ①：本端在"离开 App"那一刻收的线 ⇒ **既不是编排失败、也不是用户停止**。
      // 这一支必须排在下面那条 `_logger.error('编排异常')` 与 `return false` 之前：
      //  · 走 `return false` 会回退 ReAct，而那等于在后台里再开一条流（正是本轮要挡的事）；
      //  · 记 error 会把一次省电行为写成崩溃，读日志的人（和机主自己）又一次猜原因。
      // 判据与全部文案都取自 `drop_continue.dart`（这里不写第二份字符串）。
      if (leftAppAbortCarried(
          abortedRound: _leftAppAbortRound, round: _reactRound)) {
        _logger.warn(
            '[Orch] 离开 App 时本端收起了这条流（非用户停止、非网络故障）mode=$mode',
            cat: LogCat.react,
            tag: 'Orch');
        final kept = stripRoundAbortNote(assistantMsg.content);
        assistantMsg.content = kept.trim().isEmpty
            ? bgPauseNote(hasContent: false, isZh: isZh)
            : '$kept\n\n${bgPauseNote(hasContent: true, isZh: isZh)}';
        // ④ 账单：编排这几发 LLM 调用是真花了钱的，"被收起"不是把它们抹掉的理由。
        applyOrchUsage();
        // 额度**在 drain 之前**记：`_finishOrchestratedAnswer` 里那次
        // `_drainPendingFollowups()` 可能立刻起新一轮，届时 `_sendSeq` 已不是本轮的了。
        final plan = _dropCont.armAtLeaveAppAbort(
          round: _reactRound,
          stoppedOrSuperseded:
              stopRequested || _pendingFollowupMessages.isNotEmpty,
          pending: PendingDropContinue(
              assistantMsgId: assistantMsg.id,
              userMsgId: userMsg.id,
              isZh: isZh,
              deep: deep,
              armedSeq: _sendSeq,
              wholeRound: true),
        );
        await _finishOrchestratedAnswer(assistantMsg, storage, searchHits);
        _claimSendIsland(userMsg.id);
        if (plan == DropContinuePlan.pendUntilForeground) {
          unawaited(LiveTaskWiring.onResearchUpdate(userMsg.id,
              bgRestartPendingIslandLabel(used: _dropCont.used, isZh: isZh),
              deep: deep));
        } else {
          // 额度已用掉 / 已被接管：不写「已完成」（没交付完）也不写 ✗（不是故障），
          // 安静撤条，交回气泡上那枚「重新发起这一轮」。
          unawaited(LiveTaskWiring.onResearchEnd(userMsg.id,
              deep: deep, quiet: true));
        }
        return true;
      }

      _logger.error(
          '[Orch] ${stopRequested ? (_reactLoopUserStopped ? '编排被用户停止' : '编排被系统提前结束') : '编排异常'} mode=$mode',
          error: e,
          stack: st,
          cat: LogCat.react,
          tag: 'Orch');

      if (stopRequested) {
        final kept = assistantMsg.content.trim();
        assistantMsg.content = kept.isNotEmpty
            ? '$kept\n\n${stopNote(userStopped: _reactLoopUserStopped, hasContent: true, isZh: isZh, activityZh: '编排', activityEn: 'orchestration')}'
            : stopNote(
                userStopped: _reactLoopUserStopped,
                hasContent: false,
                isZh: isZh,
                activityZh: '编排',
                activityEn: 'orchestration');
        assistantMsg.showStaleFootnote = true;
        // 停止也要落账：前几轮已经真实烧掉的 token 不该因为"用户按了停止"消失。
        applyOrchUsage();
        await _finishOrchestratedAnswer(assistantMsg, storage, searchHits);
        // build149：停止同样要撤岛。build150 用 `quiet` 把这件事说清楚：
        // **用户自己按的停止既不写「已完成」也不写「失败」**（前者是假消息，
        // 后者是吓人的假故障），直接撤条；真错误那一条出口仍留「· 失败 + 原因」。
        // build161：认领同上一条（用户按停止走 quiet：两个都不写）。
        _claimSendIsland(userMsg.id);
        unawaited(LiveTaskWiring.onResearchEnd(userMsg.id,
            deep: deep, quiet: true));
        return true;
      }

      await _rollbackOrchestrationPlaceholder(assistantMsg, storage,
          burned: orchUsage);
      _notifyOrchestratorFallback(isZh, reason: e);
      return false;
    }
  }

  /// 撤销编排占位气泡：UI 与 DB 各删一次。
  ///
  /// 少了这一步，回退 ReAct 后会话里会**并排两条回复**（第一条空白），
  /// 用户既不知道发生过回退，也没法撤掉空壳。DB 删除失败只 warn——UI 已清掉，
  /// 残留行下次拉取会话时会被"空内容助手消息"过滤吗？不会，所以必须留日志可查。
  ///
  /// [burned]（build146 第 10 轮）：气泡一删，挂在它身上的用量也就没了地方落账，
  /// 而**这几发 LLM 调用是真花了钱的**（`result==null` 这条路是编排器已经付完
  /// 路由/取证/合成 3~4 发之后才判定失败的），随后 ReAct 还要再花一遍。
  /// 所以撤销之前必须先把数记进日志：账单可以从气泡上消失，不许从可排查性上消失。
  /// 四个回退出口共用这一处实现，漏一个就是静默。
  Future<void> _rollbackOrchestrationPlaceholder(
    ChatMessage placeholder,
    StorageService storage, {
    TokenUsage? burned,
  }) async {
    if (burned != null &&
        (burned.totalTokens != null || burned.promptTokens != null)) {
      _logger.warn(
          '[Orch] 回退 ReAct：编排已烧 prompt=${burned.promptTokens ?? 0} '
          'completion=${burned.completionTokens ?? 0} total=${burned.totalTokens ?? 0}'
          '（占位气泡将被撤销 ⇒ 这些数不会出现在任何一条消息上，只在日志里）',
          cat: LogCat.react,
          tag: 'Orch');
    }
    _messages.remove(placeholder);
    if (mounted) setState(() {});
    try {
      await storage.deleteMessage(placeholder.id);
    } catch (e) {
      _logger.warn('[Orch] 占位消息 DB 回滚失败（UI 已移除，id=${placeholder.id}）：$e',
          cat: LogCat.react, tag: 'Orch');
    }
  }

  /// 编排路径收尾——与 ReAct `finally` 的收尾同构。
  ///
  /// `_isStreaming = false` 放第一件事：旧 ReAct 曾把它放在 await 之后，一旦落库
  /// 抛错就会永久卡 true（输入栏变「加入队列」、停止计时器一直涨），此处不重蹈。
  Future<void> _finishOrchestratedAnswer(
    ChatMessage assistantMsg,
    StorageService storage,
    int searchHits,
  ) async {
    _isStreaming = false;
    _reactLoopStopRequested = false;
    // build141：与 ReAct `finally` 同一份耗时画像 —— 真机截图那一轮（910 秒 /
    // 末节点 906 秒）走的正是编排路径（末步 kind=`final_answer`），
    // 只在 ReAct 收尾打日志的话，最该看的那条路径反而没有。
    final timing = describeRoundTiming(assistantMsg.reasoningSteps);
    if (timing.isSlow) {
      _logger.warn('[Timing] ${timing.line}', cat: LogCat.react, tag: 'Orch');
    } else {
      _logger.info('[Timing] ${timing.line}', cat: LogCat.react, tag: 'Orch');
    }
    _drainPendingFollowups();
    await _persistRoundAssistant(storage, assistantMsg);
    _triggerMemorySummaryIfDue();
    if (!mounted) return;
    setState(() {});
    _autoFollow = true;
    _refreshContextUsage();
    _scrollToBottom();
    if (searchHits > 0) {
      AppSnackBar.showSnackBar(
        context,
        SnackBar(
          content: Text(AppLocalizations.of(context)
              .tr('searchResultCount', args: {'count': '$searchHits'})),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  /// 回退提示：回退本身不是错，但**必须出声**。
  ///
  /// 用户明明选了「强制搜索」却被悄悄退回 ReAct，等于设置项失效且无人知晓——
  /// 这正是本项目反复出现的"假完成"形态，所以这里给一条可见提示。
  void _notifyOrchestratorFallback(bool isZh, {Object? reason}) {
    if (!mounted) return;
    AppSnackBar.showSnackBar(
      context,
      SnackBar(
        content: Text(isZh
            ? '子代理编排未完成，已回退到自主思考${reason == null ? '' : '（$reason）'}'
            : 'Sub-agent orchestration unfinished — fell back to the thinking loop'),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  // build130：`_orchestratorAvailablePlugins()` 已删除。
  //
  // 它把**插件显示名**（如「图片生成」）当作专家可调用的工具清单递出去，而插件
  // 执行需要的是 id / tool 名（`nexus.builtin.image_gen` / `image_gen`）——专家
  // 照着显示名输出的 `<plugin_call name="图片生成">` 无人能执行（真机 2026-09-19
  // 11:59 的「图片生成不了」就是这么来的）。插件目标现已整体交回 ReAct，该清单
  // 没有任何消费方，留着只会诱导下一个人再走一遍这条路。
}
