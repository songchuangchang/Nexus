// part 文件通过 extension 访问宿主 _ChatScreenState 的受保护成员 setState，
// 属 part-of + extension 拆分架构的固有模式，统一豁免。
// ignore_for_file: invalid_use_of_protected_member, library_private_types_in_public_api
part of 'chat_screen.dart';

/// ===== v1.7.22：重试版本快照（原地切换用） =====
/// v1.7.26 (E3)：RetryVersion 已下沉至 models/chat_message.dart（供 StorageService
/// 持久化到 message_versions 表），此处仅保留引用注释。

extension ChatScreenMessageExt on _ChatScreenState {
  Future<void> _sendMessage({String? retryOf, int retryIndex = 0}) async {
    final text = _inputController.text.trim();
    // v1.3.6：允许只发附件不写文字（图片提问等场景）
    if (text.isEmpty && _pendingAttachments.isEmpty) return;

    // v1.3.3 build 13：思考循环进行中 → 用户中途插话入队，不打断
    if (_isStreaming) {
      // build154（会话状态机 S2）：入队出口只存**文本**，但入口判据允许
      // 「只有附件」通过 ⇒ 旧行为把空串塞进队列（承诺「下一轮会处理」实际发出
      // 空气泡），而 `_pendingAttachments` 的 chip 留在输入栏，之后被用户下一条
      // 消息**无声捎带**（附件错挂到别的提问上）。与 build152 S2「破坏性操作
      // 在入口挡掉」同口径：带附件的发送在流式期间明确拒绝，输入框原样保留。
      if (_pendingAttachments.isNotEmpty) {
        final isZh =
            AppLocalizations.of(context).locale.languageCode == 'zh';
        if (mounted) {
          AppSnackBar.showSnackBar(
            context,
            SnackBar(
              content: Text(isZh
                  ? 'AI 正在生成，附件还无法排队；请等本轮结束后再发送。'
                  : 'AI is generating — attachments can\'t be queued yet. '
                      'Send them after this round finishes.'),
              duration: const Duration(seconds: 3),
              behavior: SnackBarBehavior.floating,
              width: 300,
            ),
          );
        }
        _logger.warn(
            '[Chat] Attachment send rejected during streaming: '
            'pending=${_pendingAttachments.length}, textLen=${text.length}',
            cat: LogCat.chat,
            tag: 'Chat');
        return; // 不清输入框、不入队——文本与附件都原样留着
      }
      _inputController.clear();
      _pendingFollowupMessages.add(text);
      _logger.info(
          '[Chat] Followup queued during streaming: len=${text.length}, queueSize=${_pendingFollowupMessages.length}',
          cat: LogCat.chat,
          tag: 'Chat');
      final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
      if (mounted) {
        setState(() {}); // 更新 ChatInput 的 pendingFollowupCount 显示
        AppSnackBar.showSnackBar(
          context,
          SnackBar(
            content: Text(isZh
                ? '📩 已加入思考队列（第 ${_pendingFollowupMessages.length} 条）。AI 下一轮会处理。'
                : '📩 Queued (#${_pendingFollowupMessages.length}). AI will process it next round.'),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
            width: 300,
          ),
        );
      }
      return;
    }

    _inputController.clear();
    // build149（真机反馈「发消息键盘无法收回」）：发送后**主动交还焦点**。
    // 以前这里只清文本，焦点一直留在输入框里 ⇒ IME 不收起，用户发完一条还得
    // 自己去找地方点一下。
    // ⚠️ 当年这里还写了第二条理由——"149 的口径是高度只认焦点，焦点不交还就等于
    //    那 3 行撑高档赖着不走"。**build153 撤掉档③ 之后那条理由已经不存在了**
    //    （高度只跟内容，焦点不再撑高）。本行剩下的理由是独立的、仍然成立：
    //    发完一条就该把键盘交出去。别把它当成"撑高档的补丁"删掉。
    // 只在这一条路径上做（真正发起一轮）；上面的"流式插话入队"分支刻意不动 ——
    // 那种时候人还在连续打字，收键盘反而打断。
    _inputFocus.unfocus();
    _saveDraft();
    // build126：本轮发送序号（仅"真正发起一轮"才递增；插话入队分支不递增）
    final int mySeq = ++_sendSeq;
    // build152（状态扫描 S3，P1）：每发起一轮都要清一次"用户按了停止"标记。
    // 这个标记原来只有 ReAct 循环入口与编排器会清 ⇒ **直聊路径（ReAct 关）点一次「停止」
    // 后就永久留 true**，而 `chat_screen_download.dart` 的联网检索循环与推荐追问流
    // 都读它：之后在这个会话说"帮我下载 X"，检索第一次迭代就 break，
    // 只剩内置 catalog，没命中就回"联网搜索后未找到可下载链接"——
    // 用户读成"搜索坏了"，而日志里一行都没有（break 处无打点）。
    // 放在 `++_sendSeq` 旁边是因为这正是"新一轮开始"的唯一时刻。
    // build155：这里同时给停止标记**盖轮次戳** —— 旧写法是无脑 `= false`，
    // 而 ReAct 循环入口（在几十秒装配之后）还会再清一次，中间到达的停止就被抹了
    // （岛写「已完成」、App 写「已手动停止」的真因）。现在统一走"按轮次继承"：
    // 刚开新一轮时本轮必然还没被停过 ⇒ 结果仍是 false，152 那条修复一字不动地保留。
    _reactRound = mySeq;
    // build165 ②：这一次发送如果是"因离开 App 被收起之后的整轮重发"，要把自动续写
    // 额度的**归属**搬进这个新轮号（判据与记账都在 `drop_continue.dart`）。
    // 不搬的代价很具体：重发那一轮自己在后台又被收起时 `usedIn(新轮号)` 读回 0
    // ⇒ 又攒一笔 ⇒ 用户批的"最坏多付一轮"变成"每次进出 App 各多付一轮"
    // （他原话「回去之后他又重新开始搞」就是这个形状）。
    // 放在这里而不是 ReAct 循环入口：`_reactRound` 就在上一行赋值，中间零 await，
    // 而三条发送路径（ReAct / 编排 / 直聊）都要认这一次交接。
    if (_bgRestartHandoff) {
      _bgRestartHandoff = false;
      _dropCont.adoptRound(mySeq);
      _logger.info(
          '[Chat] 本轮由「离开 App 收起连接」重发开启（round=$mySeq，'
          '退后台重发的额度已并入同一条链）',
          cat: LogCat.chat,
          tag: 'Chat');
    }
    _reactLoopStopRequested =
        reactStopCarried(stopRound: _reactStopRound, round: mySeq);
    // build155：用户停过的痕迹同样按轮次继承 —— 上一轮那一按不许算到这一轮头上
    // （否则这一轮收尾又会追加一句"用户已终止思考"，正是本次要消灭的假话）。
    _reactLoopUserStopped =
        reactStopCarried(stopRound: _reactStopRound, round: mySeq);
    // v1.7.26 (E1)：尽早置为流式状态——后续有多个 await（testConnection/搜索/下载意图判定），
    // 若置太晚，用户可在这段窗口内再次点发送绕过 _isStreaming guard 造成并发流
    _isStreaming = true;
    // v1.3.6：快照待发送附件并清空输入栏的 chip 预览
    final pendingAtts = List<MessageAttachment>.from(_pendingAttachments);
    if (mounted) setState(() => _pendingAttachments.clear());
    // 🌐 开关：常驻（不再每次发送后 reset 为 false）
    final bool wasSearchMode = _searchMode;

    // build161：用户消息挪到下面那串 await（探活/改标题/落库）**之前**构造。
    // 不是为了省事 —— 而是**灵动岛那一行必须拿它的 id 当行 id**（见下方那段），
    // 循环/编排两侧收尾认的就是这个 id。这条消息本身仍是"纯构造"，一个 await 都没有，
    // 唯一被提前算的是 `createdAt`：从此它是"按下发送那一刻"，而不是"探活通过之后"。
    final userMsg = ChatMessage.create(
      conversationId: widget.conversation.id,
      role: MessageRole.user,
      content: text,
      modelName: (_currentSessionModel ?? _apiConfig)?.model,
    );
    if (retryOf != null) {
      userMsg.retryOf = retryOf;
      userMsg.retryIndex = retryIndex;
    }
    // v1.3.6：把待发送附件挂到 userMsg（API 调用时由 _buildMessagesPayload 处理多模态）
    if (pendingAtts.isNotEmpty) {
      userMsg.attachments.addAll(pendingAtts);
    }

    // ===== build161（真机反馈「那个灵动岛他不是一瞬间就出来的，不是发消息之后
    // 立刻出来的，它是过几秒钟之后才有的」）=====
    // 岛上是先有「这一轮开始了」还是先跑完探活 + 改标题 + 落库 + 插件枚举 + MCP 注册 +
    // SharedPreferences + 记忆块 + RAG 向量化，决定了用户等几秒。真机日志两份实测：
    // 11:48:45 发送 → 11:48:51 才 active=1（6 秒）；07:18:45 → 07:19:04（19 秒）。
    // 所以登记点从「进循环之前」搬到**这里**：上面全是同步语句，下面 `_runSendRound`
    // 才是第一个 await —— 点发送的那一帧，岛上就有这一行了。
    // 文案只说这一刻能说的实话（`SendIslandRow.register` 那段解释了为什么不写「正在生成」）。
    //
    // 出口归属逐条核过（谁摘这一行）：
    //  ① ReAct 路 —— `_runReActLoop` 自己的 finally 摘（`chat_screen_react.dart` 收尾段），
    //     它在 try 之前登记的行现在只是同一行换个文案（`onResearchStart` 是 upsert，
    //     同一 id 一行、时限不重置，见 `live_task_wiring.dart` 的说明）；
    //  ② ReAct 路装配期间抛错（那段没有 finally 兜着）—— `_runSendRound` 里那个
    //     build126 的 catch 摘（带 error，落成「· 失败 + 原因」）；
    //  ③ 编排路 —— 它自己的两个出口摘（定稿 / 用户停止）；**回退 ReAct 的那几条
    //     `return false` 刻意不摘**：行还要给接手的那一轮用，摘早了用户就看不见后半程；
    //  ④ 普通直聊路（shouldUseReAct == false，以前根本不上岛）—— 由
    //     `_runSendRound` 末尾那个 build126 的 finally 摘（成功「· 已完成」/失败带原因）；
    //  ⑤ 上面这些之前任何一条早退（无 AI 配置、探活弹框点「取消」、`!mounted`）
    //     与任何一处抛错 —— 下面这层 finally 兜底：没人认领过就按 [SendIslandRow] 那条
    //     规矩安静撤掉。`_sendSeq` 只决定 `_isStreaming` 的复位归属，不参与这一行的归属：
    //     每轮各按自己的 id 摘，新一轮的行不会被旧一轮动到。
    final island = SendIslandRow(userMsg.id,
        deep: ApiService.isDeepResearchEffort(widget.conversation.reasoningEffort));
    _sendIsland = island;
    unawaited(island.register());
    try {
      await _runSendRound(
        userMsg: userMsg,
        text: text,
        mySeq: mySeq,
        wasSearchMode: wasSearchMode,
        retryOf: retryOf,
        retryIndex: retryIndex,
      );
    } finally {
      await island.releaseIfUnowned();
    }
  }

  /// build161：`_sendMessage` 的"真正那一轮"——岛上那一行已经由入口登记好了，
  /// 这里只跑探活、落库与三条分流（编排 / ReAct / 普通直聊）。
  ///
  /// 参数全是入口算好的同一批值（`userMsg`/`text`/`mySeq`/`wasSearchMode`），
  /// 这里不再重算：重算就有两份真源，`_sendSeq` 与附件快照都会各拿一套（教训 #62）。
  Future<void> _runSendRound({
    required ChatMessage userMsg,
    required String text,
    required int mySeq,
    required bool wasSearchMode,
    String? retryOf,
    int retryIndex = 0,
  }) async {
    if (_apiConfig == null) {
      // 没 AI API Key：只能走"纯下载捷径（正则+内置目录+联网）"兜底，因为无法调 AI
      final handled = await _tryHandleDownloadIntent(text);
      if (handled) {
        // v1.7.26 (E1)：提前置位后需在此复位
        _isStreaming = false;
        if (mounted) setState(() {});
        _followBottomIfNeeded();
        // build141（反馈④ 同类漏点第 3 处）：B-5 当年只给「有 API Key」那条分支
        // 补了刷新（见下方 `handled` 分支的 `_refreshContextUsage()`），
        // 这条 `_apiConfig == null` 的兜底分支同样会往 `_messages` 里
        // add 用户消息与助手回执，却没人重算用量 ⇒ 同一个动作两条分支一条有一条没有。
        _refreshContextUsage();
        return;
      }
      if (mounted) {
        AppSnackBar.showSnackBar(
          context,
          SnackBar(
              content:
                  Text(AppLocalizations.of(context).tr('apiConfigNotFound'))),
        );
      }
      _isStreaming = false;
      if (mounted) setState(() {});
      _followBottomIfNeeded();
      return;
    }

    final l = AppLocalizations.of(context);
    final storage = context.read<StorageService>();
    final apiSvc = context.read<ApiService>();
    final registry = context.read<PluginRegistry>();

    // ===== build172（照片读取修复）：图片附件**入口 OCR**，三条分流（编排 /
    // ReAct / 直聊）之前统一跑 =====
    //
    // 三条路径此前只有直聊有 OCR 兜底——编排路径的 `_call` 只发文本，图片永远
    // 是占位文本（真机 28 日 18:44 带图编排实测；build171 的"说实话"只解决
    // "模型不猜"，没解决"读到"）。在分流之前把识别结果写进附件的 extractedText：
    //  · 编排器既有的「extractedText 非空即正文」分支自动带上（无需改编排器）；
    //  · 直聊/ReAct 的 `_buildMessagesPayload` 优先读 extractedText（视觉模型
    //    仍发原图，不受影响）；
    //  · 引擎失败写 O2-4 口径的实话（不伪造正文），并 SnackBar 明示。
    // 代价：视觉模型也会多跑一次本机 OCR（数百毫秒、不出网）——换三条路径
    // 行为一致，值得。重试/续跑经 extractedText 非空跳过，不重复识别。
    // 放在探活之前：OCR 是本地操作，与上游健康无关；失败也应让用户尽早看到。
    if (userMsg.attachments
        .any((a) => a.type == AttachmentType.image && a.localPath != null)) {
      final entryOcrEngineFailed =
          await TextRecognitionService.ensureImagesOcrd(userMsg.attachments);
      if (!mounted) return;
      if (entryOcrEngineFailed) {
        AppSnackBar.showSnackBar(
          context,
          SnackBar(
            content: Text(l.locale.languageCode == 'zh'
                ? '⚠️ 本机图片识别不可用，当前模型看不到图片内容；可切换支持视觉的模型，或手动输入图中文字'
                : '⚠️ On-device OCR unavailable — the model cannot see the image. Switch to a vision model or type the text manually.'),
            duration: const Duration(seconds: 5),
          ),
        );
      }
      _logger.info(
          '[Chat] 入口 OCR 完成：图片 ${userMsg.attachments.where((a) => a.type == AttachmentType.image).length} 张，'
          'engineFailed=$entryOcrEngineFailed',
          cat: LogCat.chat,
          tag: 'Chat');
    }

    final now = DateTime.now();
    final cacheValid = _lastApiTestTime != null &&
        _lastApiTestOk &&
        now.difference(_lastApiTestTime!) < const Duration(seconds: 30);
    if (!cacheValid) {
      // build148（真机反馈②「发送是第一步骤，重试不行再报错」）：
      // 原来这里**一次 10 秒超时就弹框问用户**"是否仍然发送"，两头的错都占了 ——
      //  ① 探活是 `stream:false` + `max_tokens:50`（`api_service.dart:1126`），
      //     要等上游把整包生成完才回头；真聊天是流式，首字常在 10s 内到。
      //     外层这 10s 又只有真发送预算（60s 建连 / 30s 空闲）的 1/6，
      //     还把 `testConnection` 自己的 30s 抢在前面顶死（`api_service.dart:1147`）。
      //     ⇒ 慢中转/推理模型上，这个框拦住的是**一次本来能成的发送**；
      //     用户每次都点「仍然发送」就是这件事的现场证据。
      //  ② 而它报的还是内部异常原文（`TimeoutException after 0:00:10.000000:
      //     Future not completed`），既没分类也没给可行动项。
      // 改法按用户那句原话走：**先自己重试，重试还不行才报错**，
      // 弹框里的文案换成分级人话（内部异常降级成第二行小字，供导出日志用）。
      // 代价说清楚：探活是一次真金白银的模型请求，多试一次 = 故障期每 30 秒窗口
      // 多烧一发；只在失败路径上发生，成功时仍然只发一次。
      Object? probeError;
      for (var attempt = 1; attempt <= kApiProbeAttempts; attempt++) {
        try {
          await apiSvc
              .testConnection(_conversationApiConfig)
              .timeout(attempt == 1
                  ? kApiProbeTimeout
                  : const Duration(seconds: 20));
          probeError = null;
          break;
        } catch (e) {
          probeError = e;
          if (attempt < kApiProbeAttempts && !isProbeFatalConfigError(e)) {
            _logger.warn(
                '[API] 探活第 $attempt 次失败，${kApiProbeRetryWait.inSeconds}s 后重试：$e',
                cat: LogCat.api,
                tag: 'Send');
            await Future<void>.delayed(kApiProbeRetryWait);
            continue;
          }
          break;
        }
      }
      if (probeError == null) {
        _lastApiTestOk = true;
        _lastApiTestTime = now;
      } else {
        final e = probeError;
        _lastApiTestOk = false;
        _lastApiTestTime = now;
        if (mounted) {
          final isZh = l.locale.languageCode == 'zh';
          final headline = describeApiProbeFailure(e, isZh: isZh);
          final errStr = e.toString();
          final shortErr =
              errStr.length > 200 ? '${errStr.substring(0, 200)}...' : errStr;
          final retried = kApiProbeAttempts > 1 && !isProbeFatalConfigError(e);
          final proceed = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(isZh ? '⚠️ 连不上 API 服务器' : '⚠️ API unreachable'),
              content: Text(isZh
                  ? '$headline\n\n${retried ? '已自动重试 $kApiProbeAttempts 次，都没成功。' : ''}\n'
                      '（详情：$shortErr）\n\n要仍然发送吗？发送本身会再试一次，'
                      '失败会在消息里告诉你原因。'
                  : '$headline\n\n${retried ? 'Retried $kApiProbeAttempts times, all failed. ' : ''}'
                      '(detail: $shortErr)\n\nSend anyway? The send itself retries once, '
                      'and a failure will say why in the message.'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(isZh ? '取消' : 'Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(isZh ? '仍然发送' : 'Send Anyway'),
                ),
              ],
            ),
          );
          if (proceed != true) {
            // v1.7.26 (E1)：提前置位后需在此复位
            _isStreaming = false;
            if (mounted) setState(() {});
            _followBottomIfNeeded();
            return;
          }
        }
      }
    }

    // 用户消息本体（含附件与重试标记）已在 `_sendMessage` 入口、任何 await 之前建好，
    // 这里接着用它 —— 岛上那一行的行 id 就是 `userMsg.id`，两边必须是同一个对象。
    // 自动用首条消息设置对话标题
    if (widget.conversation.title == 'New Chat') {
      final newTitle = text.length > 30 ? '${text.substring(0, 30)}...' : text;
      await storage.updateConversationTitle(widget.conversation.id, newTitle);
      widget.conversation.title = newTitle;
      // build101（D4）：开启后首轮回答完成时用 AI 生成更贴切的短标题
      _maybeAutoGenerateTitle(text);
      if (mounted) setState(() {});
      _followBottomIfNeeded();
    }
    await storage.saveMessage(userMsg);

    // ===== v1.3.2：ReAct 自主思考 + 搜索循环（Chatbox 风格）=====
    // v1.6.9 build42 修复问题4：思考循环与联网搜索解耦——
    //   - 不再依赖 wasSearchMode / webSearchEnabled（关搜索也能思考，只思考不搜索）
    //   - 依赖 self_check 插件启用（失去自检终止保护则 🧠 整体禁用）
    // v1.7.25：思考相关每对话独有 → 读 conversation
    // build98（P2）：思考程度「关 Off」(reactMaxRounds=0) 不应静默压制
    // 思考强度/深度研究——reasoningEffort>0 时由 reasoningRoundsForValue 换算轮数
    final shouldUseReAct = widget.conversation.reactEnabled &&
        (widget.conversation.reactMaxRounds > 0 ||
            widget.conversation.reasoningEffort > 0) &&
        registry.isEnabled(PluginRegistry.kSelfCheckPluginId) &&
        _apiConfig != null; // 无 AI 配置时不跑自主思考

    if (shouldUseReAct) {
      // build126：异常兜底复位。_runReActLoop 内部（chat_screen_react.dart 296 行起）
      // 有自己的 try/finally，但**入口段（13~295 行）在 try 之外**——那里任何一个
      // 异常（如 284 行 `_apiConfig!`、context.read、历史/记忆装配）都会绕过收尾，
      // 让 _isStreaming 永久卡 true：输入栏变「思考中…加入队列」（新消息发不出去）、
      // 长按菜单的撤回/编辑重发被隐藏、思考计时器一直涨（真机 58225 秒）。
      // 与下方 B-023 下载意图分支属同一类缺陷（那次只修了非 ReAct 路径）。
      try {
        // build129（#107）建、build146 改：子代理门控。
        // 只在 ReAct 分支内分流：编排器是"自主思考"的一种实现而非替代品——
        // 把 ReAct 关掉的会话不该因为改了个子代理模式就凭空开始编排。
        // build146（子代理：路由不再单独花钱）：门控读**归一化后**的档位——
        // 默认档 `auto` 现在留在 ReAct（旧口径 `mode != 'main_only'` 让它每轮
        // 先付一次 LLM 路由调用，路由说 self 时还要再付一次合成调用才拿到正文）；
        // 深度研究（思考强度拉满 1.0）经 `effectiveSubagentMode` 升为 `force_search`，
        // 仍然走编排器取证，且**不再花路由那次调用**。
        // 判据只此一处（`deep` 只在这里为门控算一次；编排器内部要升档时
        // 调的是同一个纯函数 `effectiveSubagentMode`，不另写一套）。
        final deepForGate =
            ApiService.isDeepResearchEffort(widget.conversation.reasoningEffort);
        final storedModeForGate = widget.conversation.subagentMode;
        final effectiveModeForLog = effectiveSubagentMode(
            storedMode: storedModeForGate, deep: deepForGate);
        if (subagentModeUsesOrchestrator(storedModeForGate,
            deep: deepForGate)) {
          final handled =
              await _runOrchestratedAnswer(userMsg, apiSvc, storage);
          if (handled) return;
          _logger.info(
              '[Chat] 编排路径未产出，回退 ReAct（subagentMode=$storedModeForGate，'
              'effective=$effectiveModeForLog）',
              cat: LogCat.chat,
              tag: 'Chat');
        } else {
          // build146（透明度）：本轮走的是哪条路必须留痕——默认档改成 ReAct 之后，
          // 日志里若只有一堆 [ReAct] 行，排查时仍要猜"编排到底跑没跑"。
          _logger.info(
              '[Chat] 本轮路径=ReAct（subagentMode=$storedModeForGate，'
              'effective=$effectiveModeForLog，deep=$deepForGate，未付 LLM 路由调用）',
              cat: LogCat.chat,
              tag: 'Chat');
        }
        await _runReActLoop(userMsg, apiSvc, storage);
      } catch (e, st) {
        _logger.error('[Chat] ReAct loop escaped without cleanup',
            error: e, stack: st, cat: LogCat.chat, tag: 'Chat');
        // build148（真机反馈③「一直是准备中」的真因）：上面那段注释（build126）说的
        // 「入口段在 try 之外」同样适用于**灵动岛那条行**：登记与配对的 `onResearchEnd`
        // 之间原来还隔着 200 行（RAG 向量化、记忆装配、上下文预算…）全在 try 外面，
        // 那里任何一次抛错（真机 21:30 那次就是上游连不上）都会让 finally 根本没挂上，
        // 于是通知栏永驻「深度研究中 · 准备中」，用户以为还在跑。
        // 带上 error：这一支是"通知栏里那条还在写进行中，人其实已经失败了"，
        // 按用户要求要落成 ❌ + 原因并停留一会儿，而不是无声撤条。
        // build161 改口径（原来这两行写的是「onResearchEnd 是 remove，按 id 幂等 ⇒
        // 正常路径再叫一次也毫无副作用」，那是 build148 之前的旧事实）：
        // 现在 `onResearchEnd` 写的是**终态行**（停留 8 秒才撤，build148/150 的规格），
        // 重复叫一次会把循环自己写好的那一行改写成第二次结果。所以这一支必须先
        // **认领**这一行（`_claimSendIsland`）：认领之后入口那层兜底 finally 就只管不再
        // 撤条，第二次收尾不会再发生；而循环的 finally 只有在没跑到时才轮得到这里。
        _claimSendIsland(userMsg.id);
        unawaited(LiveTaskWiring.onResearchEnd(
          userMsg.id,
          deep: ApiService.isDeepResearchEffort(widget.conversation.reasoningEffort),
          error: describeApiProbeFailure(e, isZh: l.locale.languageCode == 'zh'),
        ));
        // 仅当没有更新的一轮接手时才复位（见 _sendSeq 说明）
        if (_isStreaming && _sendSeq == mySeq) {
          _isStreaming = false;
          if (mounted) setState(() {});
        }
        rethrow;
      }
      return;
    }

    // ===== 未触发 ReAct 时：下载意图先判（不会被先拦截了）=====
    // 先手动把 userMsg 加到 UI 上，因为 _tryHandleDownloadIntent 如果命中也会优先加 existingUserMsg
    if (mounted) {
      setState(() {
        if (!_messages.contains(userMsg)) _messages.add(userMsg);
      });
      _scrollToBottom();
    }
    final handled = await _tryHandleDownloadIntentWithExisting(userMsg, text);
    if (handled) {
      // B-023：**必须复位 _isStreaming**——E1 已把置位提前到多个 await 之前，
      // 此处 return 会绕过末尾的 finally 复位，标志永久卡 true → 之后再发消息
      // 全部走「插话入队」（直聊路径无消费者，消息永不发出）、长按菜单的
      // 编辑重发/续写/撤回全被隐藏、输入栏停在停止态，整个会话锁死到退出重进。
      // 对照下方「无 API 配置」分支已有显式复位。
      _isStreaming = false;
      if (mounted) setState(() {});
      _followBottomIfNeeded();
      _refreshContextUsage(); // 审查 B-5：下载意图早退也刷新用量条
      return;
    }

    // ===== 之前的"一次性前置搜索 + 流式回复"流程 =====
    String searchContextBlock = '';
    bool willWarnStaleKnowledge = true;
    int searchHitCount = 0;
    if (wasSearchMode && _webSearchCfg.webSearchEnabled) {
      _logger.info(
        '[Chat] Web search before send: query length=${text.length}',
        tag: 'Chat',
      );
      final placeholder = ChatMessage.create(
        conversationId: widget.conversation.id,
        role: MessageRole.assistant,
        content: '🌐 ${l.tr('searchingNow')}',
      );
      if (mounted) {
        setState(() {
          // v1.7.9 (M6 修复)：userMsg 在 L1824 已加入，这里只补 placeholder
          // （之前无条件重复 add → 消息气泡重复显示 + API payload 把重复 user 消息发给 LLM）
          if (!_messages.contains(userMsg)) _messages.add(userMsg);
          _messages.add(placeholder);
        });
        _scrollToBottom();
      }

      final (results, searchError) =
          await WebSearchService.searchGeneralDetailed(text, _webSearchCfg);
      // build139（静默降级）：这条路径本来把「搜索服务炸了」和「没搜到」揉成
      // 同一个空列表 —— 回答会照常生成，只是没有任何联网上下文，用户完全看不出
      // 区别。行为不能变（无结果就按无结果作答），但故障必须在日志里留痕。
      if (searchError != null) {
        _logger.warn(
            '[Chat] 发送前联网搜索失败，本轮无检索上下文：$searchError',
            cat: LogCat.ws,
            tag: 'Chat');
      }
      searchHitCount = results.length;
      _logger.verbose(
          '[Chat] Pre-send search results ($searchHitCount items):\n${results.take(5).map((r) => '  - ${r.title}\n    ${r.url}\n    ${r.snippet.substring(0, r.snippet.length > 100 ? 100 : r.snippet.length)}').join('\n')}',
          cat: LogCat.chat,
          tag: 'Chat');
      if (results.isNotEmpty) {
        searchContextBlock = WebSearchService.formatAsSearchContext(
          results,
          _webSearchCfg,
          query: text,
        );
        willWarnStaleKnowledge = false;
      }
      // remove placeholder before assistant streaming starts
      if (mounted) setState(() => _messages.remove(placeholder));
    }

    // 3) 若没搜索（或搜索无结果）+ 总开关关了 → 也要过时警告（脚注）
    if (!_webSearchCfg.webSearchEnabled) {
      willWarnStaleKnowledge = true;
    }

    // UI：加用户消息 + 空 assistant 占位
    final assistantMsg = ChatMessage.create(
      conversationId: widget.conversation.id,
      role: MessageRole.assistant,
      content: '',
      modelName: (_currentSessionModel ?? _apiConfig)?.model,
      showStaleFootnote: willWarnStaleKnowledge,
      injectedWebSearchCount: searchHitCount,
    );
    if (retryOf != null) {
      assistantMsg.retryOf = retryOf;
      assistantMsg.retryIndex = retryIndex;
    }

    // v1.6.8 修复 Bug#5：上面有多个 await（_tryHandleDownloadIntent / searchGeneral），
    // 用户可能已退出页面，setState 必须检查 mounted
    if (!mounted) return;
    setState(() {
      if (!_messages.contains(userMsg)) _messages.add(userMsg);
      _messages.add(assistantMsg);
      _isStreaming = true;
    });
    _scrollToBottom();
    // build156（真机 P1：整条回答会丢）：v1.4.5 的「流式实时落库防崩溃丢失」
    // 在**直聊路径上一直空转**。证据是它自己的文档注释
    // （chat_screen.dart:344「前提：msg 必须已通过 saveMessage INSERT 到 DB」）
    // 与这里首次真 INSERT 的位置（流结束后 _persistRoundAssistant，见下方 :904）
    // 互相矛盾 ⇒ 节流里的 `updateMessageContent` 打在还不存在的行上，
    // sqflite 未命中**不抛错**，`:361-362` 还把 `_lastAssistantDbSaveMs/Len`
    // 照常推进 ⇒ 一行日志都没有。关掉 ReAct 发一条消息、流到一半杀进程，
    // 重进会话这条回答整段消失。
    // 修法不是新发明：ReAct 路径 :282-284 与编排路径早就是「预插入 + 重置节流」
    // 这三行，直聊漏了。saveMessage 必须幂等 —— react 结尾还会再 persist 一次，
    // 幂等性是那条路径已经在依赖的前提。
    _lastAssistantDbSaveMs = 0;
    _lastAssistantDbSaveLen = 0;
    await _persistRoundAssistant(storage, assistantMsg);

    final history = _messages
        .where((m) => m.role != MessageRole.assistant || m.content.isNotEmpty)
        .where((m) => m.id != assistantMsg.id)
        .where((m) => m.id != userMsg.id)
        .toList();

    // 注入内容都作为稳定前缀参与同一套预算，原始消息仍只保留在数据库。
    // build146（prompt cache ②）：拼装顺序不再由代码书写顺序决定 —— 每块带上自己的
    // PromptBlockKind，交给 planPromptPrefix 按「变化频率升序」重排（见 utils/prompt_prefix.dart）。
    // 旧的「离用户消息越近权重越高」写法把每轮都变的 kb 块排在人设/协议之前 ⇒ 前缀永不命中。
    final apiConfig = _conversationApiConfig;
    final prefixBlocks = <PromptBlock>[];
    final hintInjection = _buildNormalChatPluginHint(registry);
    if (hintInjection.trim().isNotEmpty) {
      prefixBlocks.add(PromptBlock(PromptBlockKind.pluginCatalog,
          text: hintInjection));
    }

    var memoryContextBlock = '';
    if (widget.conversation.memoryEnabled) {
      try {
        final summaries = await storage.getRecentSummaries(3,
            excludeId: widget.conversation.id);
        if (summaries.isNotEmpty) {
          final sb = StringBuffer();
          final isZh = l.locale.languageCode == 'zh';
          sb.writeln(isZh
              ? '【跨对话记忆 · 最近对话摘要】'
              : '[Cross-chat memory · Recent conversation summaries]');
          for (final s in summaries) {
            sb.writeln(
                '- ${(s['title'] as String?) ?? ''}: ${(s['summary'] as String?) ?? ''}');
          }
          memoryContextBlock = sb.toString().trim();
          prefixBlocks.add(PromptBlock(PromptBlockKind.crossChatSummary,
              text: memoryContextBlock));
        }
      } catch (e) {
        // build156（真机扫描 P2）：原来是 `debugPrint('catch 静默异常')` ——
        // release 包里 debugPrint 不进可导出日志 ⇒ 记忆读取一旦失败（坏行/磁盘忙），
        // 本轮 system 前缀里记忆块整段消失，AI 突然"忘光"之前对话，
        // 用户和排障的人两头发蒙。行为**不变**（读不到就按无记忆作答），
        // 但故障必须留痕 —— 与本文件 :398-403 那条「搜索失败也照常回答、只是必须写日志」
        // 是同一口径（build139 为消灭这个形状立的规矩），此前只有这支漏了。
        _logger.warn('[Chat] 跨对话记忆读取失败，本轮无记忆注入：$e',
            cat: LogCat.chat, tag: 'Chat');
      }
    }

    // v1.7.38 build90（⑧）：全局/项目记忆。build94 (D3)：受 longTermMemoryEnabled
    // 独立开关控制。慢变（只有落记忆/手动存删才动）⇒ 归长期记忆档。
    final memoryBlock = widget.conversation.longTermMemoryEnabled
        ? await MemoryBlockBuilder.buildMessage(
            userMsg.conversationId,
            projectId: widget.conversation.projectId,
            isZh: l.locale.languageCode == 'zh',
          )
        : null;
    if (memoryBlock != null) {
      prefixBlocks.add(PromptBlock(PromptBlockKind.longTermMemory,
          text: memoryBlock.content));
    }

    // build101（C1 知识库 RAG）：**本轮问题向量决定内容 ⇒ 易变段**，
    // 必须排在稳定段之后（这正是审计点名的头号前缀破坏者）。
    final kbBlock = await _buildKnowledgeContext(userMsg.content, apiConfig,
        isZh: l.locale.languageCode == 'zh');
    if (kbBlock != null) {
      prefixBlocks.add(PromptBlock(PromptBlockKind.knowledgeRetrieval,
          text: kbBlock.content));
    }

    // 用户自定义 systemPrompt：api_service._buildMessagesPayload 会在 system 段开头
    // 补回它（下面 :509 的去重把它从发出内容里剥掉，避免双份）。这里仍纳入 plan，
    // 是为了让"哪些内容不变"这份名单**完整** —— 补回来的那一条也在名单里，
    // 协议层才会把它算进可缓存跨度。
    if (apiConfig.systemPrompt.isNotEmpty) {
      prefixBlocks.add(PromptBlock(PromptBlockKind.userSystemPrompt,
          text: apiConfig.systemPrompt));
    }

    // build101（E8）：会话绑定的助手人设 —— 会话级稳定，档位排在协议/记忆之前
    // （从「最贴近用户」挪到「最靠前」，收益是人设从此永久可缓存；风险见 prompt_prefix 头注）。
    final assistantBlock = await _buildAssistantBlock();
    if (assistantBlock != null) {
      prefixBlocks.add(PromptBlock(PromptBlockKind.assistantPersona,
          text: assistantBlock.content));
    }

    // 唯一排序真身：planPromptPrefix。stableTexts 是本轮 Anthropic 断点的依据，
    // 由下面那次真正发出的 streamChat 消费；调用点不再自己数「我觉得有几块稳定」。
    final prefixPlan = planPromptPrefix(prefixBlocks);
    final stablePrefix = <ChatMessage>[
      for (final b in prefixPlan.blocks)
        ChatMessage.create(
          conversationId: userMsg.conversationId,
          role: MessageRole.system,
          content: b.text,
        ),
    ];
    final stableSystemTexts = prefixPlan.stableTexts;

    final requestUser = searchContextBlock.isEmpty
        ? userMsg
        : ChatMessage.create(
            conversationId: userMsg.conversationId,
            role: MessageRole.user,
            content: '$searchContextBlock\n\n用户问题：${userMsg.content}',
          )
      ..attachments.addAll(userMsg.attachments);
    // build168（#99）：这里原来还有一份 `textAttachmentTokens`（非图片附件的
    // extractedText 合计），只为塞进下面 components 的 `attachmentTokens`。
    // 那份合计**已经由 `TokenEstimator.message(requestUser)` 计过一次**（它逐条加
    // attachments 的 extractedText），所以整个局部量随那次重复计费一起删掉。
    final imageAttachments = requestUser.attachments
        .where((a) => a.type == AttachmentType.image)
        .toList();
    // build172（照片读取修复）：OCR 已**上移到发送入口**（ensureImagesOcrd，
    // 分流之前三条路径统一跑），识别结果在附件的 extractedText 里——
    // 由 `TokenEstimator.message(requestUser)` 计入 attachmentTokens，此处
    // 不再重复识别、也不再单独计 token（那会双算）。载荷组装
    // （_buildMessagesPayload）优先读 extractedText；历史消息里没有入口
    // 结果的图片仍由它现场补识别（函数内置兜底）。
    const ocrResults = <String, TextRecognitionResult>{};
    // build168（#99 的另一半）：这里以前把**已经进了发出内容**的四块又算了一遍
    // （`select()` 里 `reserved = … + components.totalTokens`，而 `fixedCost` 又单独
    //  加 `_estimate(stablePrefix)` 与 `currentCost`）⇒ 同一份 token 收两次费，
    // 历史被提前挤掉。逐条核对过去向：
    //  · searchTokens —— 拼进 `requestUser.content`（见上面 `$searchContextBlock\n\n用户问题：`），
    //    已由 `currentCost` 计 ⇒ 删。
    //  · temporaryMessageTokens（那串「用户问题：」）—— 同上一条，本来就在 currentCost 里 ⇒ 删。
    //  · memoryTokens —— 是 `prefixBlocks` 的一块（`PromptBlockKind.longTermMemory`），
    //    已由 `_estimate(stablePrefix)` 计 ⇒ 删。
    //  · attachmentTokens —— 是 `requestUser.attachments[].extractedText`，
    //    `TokenEstimator.message` 逐条加过（token_estimator.dart:63-66）⇒ 删。
    // 留下的两条是**真的没被别处计到**的：图片（`message()` 只看文本，不看图）
    // 与本机 OCR 文本（它经 `ocrResults:` 走请求组装，不在 requestUser/stablePrefix 里）。
    // build172 备注：OCR 文本已改走 extractedText（计入 attachmentTokens），
    // ocrTokens 恒 0；字段保留是为不改 ContextBudgetComponents 的形状。
    const ocrTextTokens = 0;
    final components = ContextBudgetComponents(
      imageTokens: apiConfig.supportVision ? imageAttachments.length : 0,
      ocrTokens: ocrTextTokens,
    );
    var segments =
        await storage.getContextCompactionSegments(widget.conversation.id);
    var selection = ContextBudgetService.select(
      conversation: widget.conversation,
      config: apiConfig,
      messages: history,
      segments: segments,
      currentMessage: requestUser,
      stablePrefix: stablePrefix,
      components: components,
    );

    // v1.7.37 互斥：更大上下文 Max 开启时自动压缩不生效（预算已 1M）
    if (!widget.conversation.largeContextMax &&
        widget.conversation.autoCompress &&
        selection.isNearLimit) {
      await _autoCompressContextIfNeeded(history);
      segments =
          await storage.getContextCompactionSegments(widget.conversation.id);
      selection = ContextBudgetService.select(
        conversation: widget.conversation,
        config: apiConfig,
        messages: history,
        segments: segments,
        currentMessage: requestUser,
        stablePrefix: stablePrefix,
        components: components,
      );
    }

    // ApiService 会自动发送 config.systemPrompt；其余稳定前缀按选择结果保留。
    final outgoing = <ChatMessage>[];
    var skippedApiPrompt = false;
    for (final message in selection.messages) {
      if (message.role == MessageRole.system &&
          message.content == apiConfig.systemPrompt &&
          !skippedApiPrompt) {
        skippedApiPrompt = true;
        continue;
      }
      outgoing.add(message);
    }
    if (outgoing.isEmpty || outgoing.last.id != requestUser.id) {
      outgoing.add(requestUser);
    }

    if (selection.isNearLimit && mounted) {
      AppSnackBar.showSnackBar(
        context,
        SnackBar(
            content: Text(l.locale.languageCode == 'zh'
                ? '上下文接近预算上限：${selection.estimatedTokens}/${selection.budgetTokens} tokens'
                : 'Context is near its budget: ${selection.estimatedTokens}/${selection.budgetTokens} tokens')),
      );
    }

    // build161：岛上那一行的收尾要在这里分出口，所以把"这一轮到底怎么结束的"记下来。
    // 两个变量都声明在 try **外面**（Dart 的 try 块自带作用域，放进去 finally 看不见）。
    String? streamError; // 非空 = 流式途中抛错，原因要带给岛上看（不许报成已完成）
    String fullResponse = '';
    // build165 ①：这一轮是不是"因离开 App 被本端收起"（同样声明在 try **外面**：
    // 下面 finally 要拿它分出口，而 Dart 的 try 块自带作用域）。
    var bgAbortedSend = false;
    try {
      _logger.info(
          '[Chat] Send message: length=${text.length}, searchMode=$wasSearchMode, hits=$searchHitCount',
          cat: LogCat.chat,
          tag: 'Chat');
      _logger.verbose('[Chat] User message: $text',
          cat: LogCat.chat, tag: 'Chat');
      await for (final chunk in apiSvc.streamChat(
        config: _conversationApiConfig,
        messages: outgoing,
        // v1.7.25：思考强度每对话独有（手动选时传，默认不传保持现状）
        reasoningEffort: ApiService.reasoningEffortForConversation(
            widget.conversation,
            inReAct: false),
        // v1.7.26 (D1/D5)：scope 级停止 + 请求级 usage 归账（替换废弃的共享计数器）
        stopScope: widget.conversation.id,
        ocrResults: ocrResults,
        // build146（prompt cache ②）：本轮"内容不变"的 system 块名单 → Anthropic 断点。
        // 按内容认，所以中间谁多一块少一块（协议层丢空白、api 补回 systemPrompt、
        // 上下文预算丢掉几条）都不会把断点推到易变块上。非 Anthropic 渠道忽略此参数。
        stableSystemTexts: stableSystemTexts,
        // build96 (O13)：直聊也展示模型原生推理——reasoning_content 走回调写入
        // 思考步骤，不混入正文；模型无推理输出时回调不触发，不造空块。
        onReasoning: (rc) {
          if (assistantMsg.reasoningSteps.isEmpty ||
              assistantMsg.reasoningSteps.last.kind != 'thinking') {
            assistantMsg.startNewThinking(rc);
          } else {
            assistantMsg.appendLastThinking(rc);
          }
          if (mounted) setState(() {});
          _followBottomIfNeeded();
        },
        onUsage: (usage) {
          assistantMsg.promptTokens = usage.promptTokens;
          assistantMsg.completionTokens = usage.completionTokens;
          assistantMsg.totalTokens = usage.totalTokens;
          assistantMsg.cacheReadTokens = usage.cacheReadTokens;
          assistantMsg.cacheWriteTokens = usage.cacheWriteTokens;
          assistantMsg.cacheHitTokens = usage.cacheHitTokens;
          assistantMsg.cacheMissTokens = usage.cacheMissTokens;
        },
      )) {
        fullResponse += chunk;
        // v1.6.8 修复 Bug#4：流式 chunk 循环内 setState 必须检查 mounted，
        // 用户在流式期间按返回键退出页面，未检查会导致 setState after dispose 崩溃
        if (mounted) {
          setState(() {
            // build152（状态扫描 S4）：写**本轮那个对象**，不再用 `_messages.last` 定位。
            // 流式期间长按「删除本条」或「清空对话」都没有门禁（S2），一旦末条不再是
            // 这条助手气泡，旧写法会把 AI 正文一路写进别的气泡（下一轮还当历史发出去）。
            // B-032 早就有 `_isMessageAlive`，主循环这里一直是漏用的那一处。
            assistantMsg.content = fullResponse;
          });
        }
        // build152（性能扫描 P2 + SF-1 补漏）：这里原来是每 chunk 一次
        // `_scrollToBottom()` = `animateTo(280ms)`，而 chunk 间隔约 66ms ⇒ 动画永不收敛、
        // 每帧重排，且**绕过了 SF-1 拍板的"流式中禁 animateTo"与用户上滑让位闸门**
        // （ReAct 那 13 处 + 直聊 10 处当年都改了，这一处是漏的）。
        // `_followBottomIfNeeded()` 自带 `_autoFollow`/`_isStreaming` 双闸门 + 帧级节流 + jumpTo。
        _followBottomIfNeeded();
        // ===== v1.4.5：AI 回复实时写入 DB（防崩溃丢失）—— 流式过程节流保存 =====
        // 注意：不 await，流式优先保证 UI 流畅；IO 本身已串行（SQLite 单线程）
        unawaited(_throttledSaveAssistantContent(
            storage, assistantMsg, fullResponse));
      }

      // build165 ①：直聊这一路（`shouldUseReAct == false` 时才会走到）也要认这次中止。
      // api 层被我们关掉的流是**安静结束**的（`stopFlag[0] ⇒ return`，不抛），所以这里
      // 不认的话下面那条正常定稿就会把半截（或 0 字）写成一份"答完了"的回答，
      // finally 再在岛上补一句「· 已完成」—— 正是 build150/158 那一族假话。
      if (leftAppAbortCarried(
          abortedRound: _leftAppAbortRound, round: _reactRound)) {
        bgAbortedSend = true;
        final zh = l.locale.languageCode == 'zh';
        final kept = stripRoundAbortNote(fullResponse);
        fullResponse = kept.trim().isEmpty
            ? bgPauseNote(hasContent: false, isZh: zh)
            : '$kept\n\n${bgPauseNote(hasContent: true, isZh: zh)}';
        // 额度与 ReAct / 编排同一本账（最多 1 次），欠的也是"整轮重发"。
        _dropCont.armAtLeaveAppAbort(
          round: _reactRound,
          stoppedOrSuperseded:
              _reactLoopStopRequested || _pendingFollowupMessages.isNotEmpty,
          pending: PendingDropContinue(
              assistantMsgId: assistantMsg.id,
              userMsgId: userMsg.id,
              isZh: zh,
              deep: false,
              armedSeq: mySeq,
              wholeRound: true),
        );
        _logger.warn(
            '[Chat] 离开 App 时本端收起了直聊这条流（非用户停止、非网络故障）'
            '：round=$_reactRound，已收 ${kept.trim().length} 字',
            cat: LogCat.chat,
            tag: 'Chat');
      }

      // v1.3.1：不再在回复最前面塞一大段"⚠️ 可能已过时"，改为气泡底部 footnote（小字体 + 淡色）
      // 对应逻辑已写入 assistantMsg.showStaleFootnote / injectedWebSearchCount，MessageBubble 直接渲染

      // 如果搜索有结果 → 底部附上"搜索结果N条注入"摘要（不写入正式内容，只做一个 toast 提示）
      if (wasSearchMode && _webSearchCfg.webSearchEnabled && mounted) {
        final msg = searchHitCount == 0
            ? l.tr('searchResultEmpty')
            : l.tr('searchResultCount', args: {'count': '$searchHitCount'});
        AppSnackBar.showSnackBar(
          context,
          SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
        );
      }

      assistantMsg.content = fullResponse;
      // build93(M1)：普通直聊路径流末补解析——模型在直聊也可能输出
      // memory_write / suggest / todo 标签（此前整条当正文显示，记忆静默丢失）。
      // 这里剥离标签并执行对应动作；脱钩但感知。
      // build97 (P1-4 修复)：门控与剥离与 ReAct 路径同源——hasReActTag
      // 识别全集标签（含自闭合 <suggest items="..."/>、裸 <todo> 等容错写法），
      // stripControlTags 净化控制标签；suggest/card 不在控制集，suggest 单独剥。
      // 旧实现用 3 个字面量 contains + 手写正则，N7 同型漏标签（标签原文露在气泡、
      // 推荐追问丢失）。
      if (hasReActTag(fullResponse)) {
        for (final piece in parseReActOutput(fullResponse)) {
          final ptype = piece['type'] ?? '';
          if (ptype == 'suggest') {
            final items = (piece['content'] ?? '')
                .split('||')
                .map((e) => e.trim())
                .where((e) => e.isNotEmpty)
                .toSet()
                .take(4)
                .toList();
            if (items.isNotEmpty) {
              assistantMsg.suggestions
                ..clear()
                ..addAll(items);
            }
          } else if (ptype == 'memory_write') {
            final scope = (piece['scope'] ?? 'global').toLowerCase();
            final key = (piece['key'] ?? '').trim();
            final value = (piece['value'] ?? '').trim();
            if (key.isEmpty || value.isEmpty) continue;
            final memContent = '$key：$value';
            var blockedByManual = false;
            if (scope == 'project' &&
                widget.conversation.projectId.isNotEmpty) {
              final pid = widget.conversation.projectId;
              for (final m in await storage.loadProjectMemories(pid)) {
                // build93(D1)：只覆盖 auto 记忆；build94(E6)：手动同 key 跳过不双写
                if (m.content.startsWith('$key：')) {
                  if (m.source == 'auto') {
                    await storage.deleteProjectMemory(m.id);
                  } else {
                    blockedByManual = true;
                  }
                }
              }
              if (!blockedByManual) {
                await storage.saveProjectMemory(ProjectMemory(
                  id: 'pm_${DateTime.now().millisecondsSinceEpoch}',
                  projectId: pid,
                  content: memContent,
                  source: 'auto',
                ));
              }
            } else {
              for (final m in await storage.loadGlobalMemories()) {
                if (m.content.startsWith('$key：')) {
                  if (m.source == 'auto' && !m.pinned) {
                    await storage.deleteGlobalMemory(m.id);
                  } else {
                    blockedByManual = true;
                  }
                }
              }
              if (!blockedByManual) {
                await storage.saveGlobalMemory(GlobalMemory(
                  id: 'gm_${DateTime.now().millisecondsSinceEpoch}',
                  content: memContent,
                  source: 'auto',
                ));
              }
            }
            _logger.info(
                '[Chat] memory_write (直聊路径): $memContent${blockedByManual ? '（跳过：手动/置顶同 key）' : ''}',
                cat: LogCat.chat,
                tag: 'Chat');
            if (mounted && !blockedByManual) {
              // M2：标明作用域
              final scopeLabel =
                  scope == 'project' && widget.conversation.projectId.isNotEmpty
                      ? '【本项目】'
                      : '【全局】';
              AppSnackBar.showSnackBar(
                context,
                SnackBar(
                    content: Text('已记住$scopeLabel：$memContent'),
                    duration: const Duration(seconds: 2)),
              );
            }
          } else if (ptype == 'todo') {
            // O11（build96）：直聊路径补齐 add/done/clear，与 ReAct 路径同一套
            // 纯函数——add 增量合并（保留勾态），done 勾选，clear 清空。
            final todoAction = (piece['action'] ?? 'add').toLowerCase();
            final items = (piece['items'] ?? '')
                .split('||')
                .map((e) => e.trim())
                .where((e) => e.isNotEmpty)
                .toList();
            final list = assistantMsg.todoItems;
            switch (todoAction) {
              case 'add':
                if (items.isNotEmpty) {
                  mergeTodoItems(list, items);
                }
              case 'done':
                for (final item in items) {
                  final needle = item.trim();
                  if (needle.isEmpty) continue;
                  for (final entry in list) {
                    final text = (entry['text'] as String? ?? '').trim();
                    if (text == needle ||
                        (text.isNotEmpty &&
                            (text.contains(needle) || needle.contains(text)))) {
                      if (entry['done'] != true) {
                        entry['done'] = true;
                      }
                    }
                  }
                }
              case 'clear':
                if (list.isNotEmpty) {
                  list.clear();
                }
            }
          }
        }
        // 标签原文的剥离已移到门控外（见下方 N-1 段）——此处只负责动作副作用。
      }
      // N-1（A5）：定稿净化必须**无条件执行**，不能缩在 hasReActTag 门控内。
      //
      // 原实现把 AnswerFinalizer.finalize 整段写在 `if (hasReActTag(...))` 里，
      // 于是**弱模型直聊给纯文本答案（无任何标签，最常见形态）时完全不过净化**：
      // L1 头部话术 / stripChineseMetaProcess 一律不生效，元话术与过程自语直接
      // 进结论。同文件的续写口 `_continueFromMessage` 本是无条件 finalize（正确），
      // 两相对照即漏。此处对齐为「每个最终答案恰好净化一次」。
      //
      // 剥离内容：①stripControlTags 剥全部内部控制标签（memory_write/todo/search/
      // download/mcp_call 等，代码围栏内不动）；②suggest 不在控制集，单独剥
      // 配对 + 自闭合两种写法；③L1 头部过程话术 + 中文元过程自语（build112 起
      // 收敛到唯一 finalize 出口，避免各处各写一套）。
      // 幂等：已净化文本二次执行不变。
      final fin = AnswerFinalizer.finalize(fullResponse);
      if (fin.stripped.isNotEmpty) {
        _logger.warn(
            '[Chat] L1 stripped ${fin.stripped.length} chars of leading meta talk from main-stream answer',
            cat: LogCat.chat,
            tag: 'Chat');
        // A7（N-3）：剥除物归思考块，不静默丢弃——与 ReAct 口同源
        assistantMsg.appendLastThinking('\n${fin.stripped}\n');
      }
      fullResponse = fin.clean;
      assistantMsg.content = fullResponse;
      _logger.verbose(
          '[Chat] AI response (${fullResponse.length} chars): ${fullResponse.substring(0, fullResponse.length > 500 ? 500 : fullResponse.length)}${fullResponse.length > 500 ? '...' : ''}',
          cat: LogCat.chat,
          tag: 'Chat');
      // v1.7.26 (D1)：由 streamChat 的 onUsage 回调捕获（上面调用处），这里不再读已废弃的共享计数器
      // 确保脚注标志同步（以防 streaming 期间被覆盖）
      assistantMsg.showStaleFootnote = willWarnStaleKnowledge;
      assistantMsg.injectedWebSearchCount = searchHitCount;
      await _persistRoundAssistant(storage, assistantMsg);
      // build132（真机：AI 不看上下文记忆）——跨对话摘要的生成触发
      // `_triggerMemorySummaryIfDue()` 此前**只有 ReAct（react.dart:2061 finally）
      // 与编排（orchestrator.dart:248）两条路径**调用，普通路径落库后从不触发
      // ⇒ 关掉「自主思考循环」的会话 conversations.summary 恒为空，
      // getRecentSummaries 恒空 → 记忆块恒空 → AI 完全没有跨对话记忆。
      // 与 ReAct 路径同源：assistant 消息落库后触发（内部自判 memoryEnabled +
      // 每 5 条间隔 + 并发去重，fire-and-forget 不阻塞界面）。
      _triggerMemorySummaryIfDue();
      if (mounted) setState(() {});
      _followBottomIfNeeded();

      if (widget.conversation.title == 'New Chat' && _messages.length <= 3) {
        final title = text.length > 30 ? '${text.substring(0, 30)}...' : text;
        await storage.updateConversationTitle(widget.conversation.id, title);
      }
    } catch (e, st) {
      _logger.error(
          '[Chat] Stream failed: config=${_apiConfig?.name ?? 'null'}, model=${_apiConfig?.model ?? 'null'}',
          error: e,
          stack: st,
          cat: LogCat.chat,
          tag: 'Chat');
      // 用 <error> 标签包裹，气泡渲染为可折叠错误卡片（默认收起，展开看原话）
      final err = '<error>$e</error>';
      // build161：这一支的原因要给下面 finally 那次岛上收尾用（口径与 ReAct 的
      // `reactLoopError` 同源：崩溃的一轮绝不许在通知栏里读成「已完成」）。
      streamError = e.toString();
      assistantMsg.content = err;
      // ===== v1.4.5：出错也强制保存（保证用户能看到出错前收到的内容已被覆盖为 Error 信息） =====
      await _throttledSaveAssistantContent(storage, assistantMsg, err,
          force: true);
      await _persistRoundAssistant(storage, assistantMsg);
      // v1.6.8 修复 Bug#6：catch 内 setState 必须检查 mounted。
      // Bug#4 流式循环 setState 崩溃会被本 catch 接住，若这里再 setState 又抛
      // → 级联未捕获异常。改为只在 mounted 时 setState，避免级联。
      if (mounted) {
        setState(() {
          // build152（S4 的第二处）：错误分支同样不能用 `_messages.last` 定位本轮气泡。
          // 流式中长按「删除本条」/「清空对话」都没有门禁（S2），一旦末条已不是这条
          // 助手消息，错误文案就会写进别的气泡；这里还额外踩一个雷 ——
          // 表被清空后 `_messages.last` 直接抛 StateError，而它就在 catch 体内，
          // 于是变成**级联未捕获异常**（v1.6.8 Bug#6 当年加 mounted 判断就是为了挡这个，
          // 但只挡了"页面没了"，没挡"列表空了"）。
          assistantMsg.content = err;
        });
      }
    } finally {
      // build161：普通直聊这一轮（`shouldUseReAct == false`）**以前根本不上岛**，
      // 现在这一行是 `_sendMessage` 入口登记的，摘它的责任就落在这里——不能再留给别人。
      // 放在 `if (mounted)` **之外**：页面已卸载时更要摘，否则这一行没人管（`onResearchEnd`
      // 走的是单例中枢，不需要 BuildContext）。
      // 先认领再收尾：不认领的话入口那层兜底 finally 会赶在下面这次写终态之后把行撤掉，
      // 用户读到的就是 build148 明令不许的「跑着跑着没了」。
      // 三种出口与 ReAct 的 finally 同一口径：成功「· 已完成」、失败「· 失败 + 原因」、
      // 本轮被提前结束（用户按停止）走 quiet —— 两个都不写。
      final endedEarly = _reactLoopStopRequested;
      _claimSendIsland(userMsg.id);
      if (bgAbortedSend && _dropCont.pending != null) {
        // build165 ①②：已经攒下"回到 App 重新发起这一轮" ⇒ 这一行留在岛上，
        // 写的是"回去会重发"（此刻没有任何流在跑，不许写"正在"）。
        unawaited(LiveTaskWiring.onResearchUpdate(userMsg.id,
            bgRestartPendingIslandLabel(
                used: _dropCont.used,
                isZh: l.locale.languageCode == 'zh'),
            deep: ApiService.isDeepResearchEffort(
                widget.conversation.reasoningEffort)));
      } else {
        unawaited(LiveTaskWiring.onResearchEnd(
          userMsg.id,
          deep: ApiService.isDeepResearchEffort(widget.conversation.reasoningEffort),
          // 被本端收起的一轮既没跑完（「· 已完成」是假消息）也不是故障（✗ 会把
          // 我们主动关线说成网络坏了）⇒ 与"用户按了停止"同一条 quiet 出口。
          quiet: endedEarly || bgAbortedSend,
          error: bgAbortedSend ? null : streamError,
        ));
      }
      if (mounted) {
        setState(() {
          _isStreaming = false;
        });
        _refreshContextUsage();
        // B-028：流结束统一收尾插话队列——直聊路径此前只入队不消费
        //（ReAct 路径有轮首 drain，直聊没有任何消费者）。
        _drainPendingFollowups();
      }
    }
  }

  /// build161：认领「本轮在岛上那一行」的收尾权，同时关掉 `_sendMessage` 入口那层
  /// 兜底摘除（[SendIslandRow.releaseIfUnowned]）。
  ///
  /// 为什么是"认领"而不是各出口直接摘：这一行的结束由接手方按自己的出口写
  /// （`onResearchEnd` 从 build148 起写的是一条**停留 8 秒的结果行**，不是单纯 remove），
  /// 入口若再兜底撤一次，就会把刚写好的「· 已完成」抹掉 —— 正好退回用户最烦的
  /// 「跑着跑着没了」。
  /// 只认 id 相同的那一行：新一轮已经登记过的时候，旧一轮不许碰新一轮的行。
  void _claimSendIsland(String sessionId) {
    final row = _sendIsland;
    if (row == null || row.sessionId != sessionId) return;
    row.claim();
  }

  /// build154（会话状态机 S1）：本轮助手消息落库的唯一出口。
  ///
  /// 「删除本条」在流式期间没有门禁（对照 build152 S2 只给「清空对话」加了门禁），
  /// 用户删掉正在生成的小气泡后，流末尾的 `saveMessage` 是**按 id replace**，
  /// 会把已删除的行重新插回 DB ⇒ 重进会话幽灵复活。这正是 B-032 在 N14 兜底
  /// 推荐流上用 `_isMessageAlive` 挡掉的同一形状，但主循环三条路（直聊
  /// success/catch、ReAct catch/finally、编排收尾）全都漏了守卫。
  /// 跳过落库时**必须留一行日志**（本仓口径：静默=不可排查）。
  Future<void> _persistRoundAssistant(
      StorageService storage, ChatMessage msg) async {
    if (!_isMessageAlive(msg.id)) {
      _logger.warn(
          '[Chat] 本轮助手消息已在流式期间被删除，跳过定稿落库（id=${msg.id}）',
          cat: LogCat.chat,
          tag: 'Chat');
      return;
    }
    await storage.saveMessage(msg);
  }

  Future<void> _autoCompressContextIfNeeded(List<ChatMessage> history) async {
    // build104（I14）：与手动压缩互斥——手动压缩进行中时静默跳过本轮自动压缩
    if (_compressInProgress) return;
    if (mounted) setState(() => _compressInProgress = true);
    try {
      final storage = context.read<StorageService>();
      final apiSvc = context.read<ApiService>();
      final existing =
          await storage.getContextCompactionSegments(widget.conversation.id);
      if (!mounted) return;

      final source = ContextBudgetService.selectCompactionSource(
        conversationId: widget.conversation.id,
        messages: history,
        segments: existing,
      );
      if (source.isEmpty) return;

      // N12：ReAct 路径传入的 history 含未落库注入消息（toolresult/自检），
      // 段边界必须落在持久化消息上，否则重载后摘要段被静默丢弃。
      final persistedIds = _messages.map((m) => m.id).toSet();
      final clamped = ContextBudgetService.clampCompactionSourceToPersisted(
          source, persistedIds);
      if (clamped.isEmpty) return;

      final summary = await _summarizeMessages(apiSvc, clamped);
      if (summary.trim().isEmpty || !mounted) return;

      await storage.saveContextCompactionSegment(ContextCompactionSegment(
        id: const Uuid().v4(),
        conversationId: widget.conversation.id,
        summary: summary.trim(),
        startMessageId: clamped.first.id,
        endMessageId: clamped.last.id,
        sourceTokenEstimate: ApiService.estimateTokens(clamped),
        createdAt: DateTime.now(),
      ));
      _logger.info(
        '[Chat] Auto-compressed ${clamped.length} messages into a persisted segment',
        tag: 'Chat',
      );
      // v1.7.37：刷新压缩卡片（聊天流即时出现「📦 已压缩」）
      _compactionSegments =
          await storage.getContextCompactionSegments(widget.conversation.id);
      if (mounted) setState(() {});
      _followBottomIfNeeded();
      _refreshContextUsage();
    } finally {
      if (mounted) setState(() => _compressInProgress = false);
    }
  }

  void _stopGeneration() {
    // v1.7.26 (D5)：scope 级停止——只停当前会话的流（ReAct 循环走 _reactLoopStopRequested 自有开关）
    final apiSvc = context.read<ApiService>();
    apiSvc.stopGeneration(scope: widget.conversation.id);
    // build120：suggest 兜底流用专属 scope（见 _suggestScope 说明），
    // 不在 conversation scope 内，必须显式一并停掉——否则用户点停止后
    // 它仍在后台跑，与「停不下来」的体感一致。
    _abortSuggestStream(apiSvc, reason: '用户停止生成');
    // v1.4.2 修复：停止按钮同时终止 ReAct 循环。
    // 之前只 stopGeneration()（只对 streamChat 的 _shouldStop 生效），
    // ReAct 循环走 completeChat（非流式）停不下来，导致按钮"点不动"。
    _reactLoopStopRequested = true;
    // build155：这一行才是"用户真的按了停止"的唯一现场（上面那行还有三个非用户写入方）。
    // 收尾文案与岛的 quiet 都只认这个，不认那个共用的终止请求。
    _reactLoopUserStopped = true;
    // build155：盖上"是哪一轮停的"。ReAct 循环入口在几十秒装配之后，那里不再无脑清，
    // 而是按这个戳判断本轮是否已被停（否则岛写「已完成」、App 写「已手动停止」）。
    _reactStopRound = _reactRound;
    _logger.info('[Chat] Generation stopped by user',
        cat: LogCat.chat, tag: 'Chat');
    // build126：停止只是"请求停止"——真正的复位靠 ReAct 收尾。若收尾因异常/早退
    // 没走到，标志会永久卡 true，用户只能杀进程。这里挂看门狗兜底。
    _armStreamingWatchdog();
  }

  /// build165 ①：人离开 App（`paused`/`hidden`）的那一刻，**由本端**把这一轮还在飞的
  /// 那条连接收起来。
  ///
  /// 为什么要主动收：真机（OPPO / ColorOS，包 1.7.107+164）带后台的 7 轮里 5 轮只收到
  /// 0~1 个 chunk，8 次报错全落在 `Lifecycle: resumed` 之前 0.10~0.19 秒 ——
  /// 最自洽的机制是"进程被厂商侧冻结 ⇒ 没人读 socket ⇒ 缓冲填满 ⇒ 上游关线 ⇒ 解冻的
  /// 一瞬 read 立刻报错"，而厂商侧没有任何可申请免冻结的 API（AOSP 的 Doze /
  /// 资源表 "Network: No restrictions" / cached-apps freezer 三条都已用官方原文排除）。
  /// 等它断，得到的是一句"网络中断"和一个说不清的随机时长；自己收，得到的是一件
  /// 我们做过的事（气泡与岛都写「已暂停：离开 App 时收起了这条连接」）+ 一次有额度的重发。
  ///
  /// 三条硬约束（都写成过事故，见 `drop_continue.dart` 顶部那一段）：
  ///  · **不碰 `_reactLoopStopRequested` / `_reactLoopUserStopped`**：那两个字段的语义是
  ///    "用户按了停止"，蹭它就是把一句他没做过的操作写进他的聊天记录（build158 修的
  ///    就是反方向的同一件事），而且岛的收尾会走 quiet ⇒ 回到 App 什么都看不见；
  ///  · 走**既有的**停止通道（`ApiService.stopGeneration(scope:)` + suggest 兜底流），
  ///    不新造第二条关连接的路；
  ///  · 只记轮号（`_leftAppAbortRound`），不记 bool：新一轮一开始旧的这一次就自动作废。
  ///
  /// build167（用户 26 日 18:4x「第一个问题我开了后台，退出来又给我暂停」）：这一整段
  /// 现在挂在设置里那道「愿意后台化」总闸上 —— **本方法只负责把那个持久化位读出来
  /// 交给判据**，收不收流由 `shouldAbortStreamOnLeaveApp` 一处决定；这里再写一份
  /// `if (backgroundRunAllowed)` 就是第二个真源（教训 #62），而且会把"开着总闸时
  /// `BgForensics` 那两行读数"一起带跑。
  /// 读那一位要 await ⇒ 前后各查一次 `mounted`，中间不碰任何状态；读失败按 `false`
  /// 处理（= 166 的原路），猜一个"他大概想要后台"不是我们能替他决定的事。
  Future<void> _onAppLeftForeground() async {
    if (!mounted) return;
    var backgroundRunAllowed = false;
    try {
      backgroundRunAllowed = await loadBackgroundRunAllowed();
    } catch (e) {
      _logger.warn(
          '[Chat] 读「愿意后台化」总闸失败，本轮按总闸关着处理（= 退后台仍由本端收流）：$e',
          cat: LogCat.chat,
          tag: 'Chat');
    }
    if (!mounted) return;
    final apiSvc = context.read<ApiService>();
    final round = _reactRound;
    if (!shouldAbortStreamOnLeaveApp(
      leavingApp: AppResumeSignal.instance.leavingApp,
      // "真有连接在飞"才收：装配阶段/两轮之间没有 socket，那时硬记这一态会在流
      // **正常答完**之后把它误判成中止 —— 把一份好答案扔掉比让它停摆更糟。
      roundInFlight:
          _isStreaming && apiSvc.hasActiveStream(widget.conversation.id),
      alreadyAborted: leftAppAbortCarried(
          abortedRound: _leftAppAbortRound, round: round),
      backgroundRunAllowed: backgroundRunAllowed,
    )) {
      return;
    }
    _leftAppAbortRound = round;
    // 岛：这句话**现在就写**。进程一旦冻住，这条通知就是他回来之前唯一看得见的东西，
    // 等循环的 finally 再补就晚了（那一次 update 可能已经排在冻结之后）。
    final island = _sendIsland;
    if (island != null) {
      unawaited(LiveTaskWiring.onResearchUpdate(
          island.sessionId,
          bgPauseIslandLabel(
              isZh: AppLocalizations.of(context).locale.languageCode == 'zh'),
          deep: island.deep));
    }
    // reason 必填（build120 的口径）：不传就会打印成 'Generation stopped by user'，
    // 把本端行为伪装成用户操作 —— 那正是本轮要消灭的那类假话在日志里的形状。
    apiSvc.stopGeneration(
        scope: widget.conversation.id,
        reason: '离开 App（paused/hidden）：本端收起本轮连接，回前台重发');
    _abortSuggestStream(apiSvc, reason: '离开 App：收起本轮兜底/反问流');
    _logger.info(
        '[Chat] 离开 App：本轮（round=$round）的连接已由本端收起'
        '（不是用户停止，也不计为网络故障）',
        cat: LogCat.chat,
        tag: 'Chat');
  }

  /// build165 ②③：把「重新发起这一轮」落到实处 —— 走既有的**整轮重跑**通道。
  ///
  /// 为什么复用 `_retryMessage` 而不是自己拼一次发送：那一条是唯一"把同一个提问原样
  /// 再发一次"的现成路径，它接的是完整的 `_runSendRound`（ReAct 的
  /// `onUsage: (u) => reactUsage = reactUsage.merge(u)` 与编排的 `applyOrchUsage`
  /// 都在里面）⇒ **重发那一次的 token 天然进本轮账单**（④），且自动留下一个版本快照，
  /// 用户能按 ← → 在"被收起的那半截"和"重发的结果"之间来回看。
  /// 自己另起一条发送路径就是第二个定稿出口（`lib/services/answer_finalizer.dart`
  /// 那条"定稿唯一出口"的规矩挡的正是这个）。
  ///
  /// 与 `↻ 重试` 的唯一区别就是这里多的那句账单行与额度交接（`_bgRestartHandoff`）。
  Future<void> _restartWholeRound(ChatMessage assistantMsg,
      {String? islandEndUserMsgId, bool deep = false}) async {
    if (!mounted || _isStreaming) return;
    if (!_isMessageAlive(assistantMsg.id)) return;
    // 旧那一行到此了结（自动重发那条路调用方传了 id）：重发会为**新**那条用户消息在岛上
    // 开另一行（`_sendMessage` 入口登记的），留着这行就有两行并存。
    // quiet：这一轮既没跑完（「· 已完成」是假消息）也不是故障（✗ 会把本端收起说成网络坏了）。
    // 写在所有守卫之后、任何早退之前 —— 早退的那几条同样没人再认这一行。
    if (islandEndUserMsgId != null) {
      unawaited(LiveTaskWiring.onResearchEnd(islandEndUserMsgId,
          deep: deep, quiet: true));
    }
    final idx = _messages.indexOf(assistantMsg);
    ChatMessage? userMsg;
    for (int i = idx - 1; i >= 0; i--) {
      if (_messages[i].role == MessageRole.user) {
        userMsg = _messages[i];
        break;
      }
    }
    if (idx <= 0 || userMsg == null) {
      _logger.warn('[Chat] 整轮重发被跳过：找不到这一轮的提问（idx=$idx）',
          cat: LogCat.chat, tag: 'Chat');
      return;
    }
    final retryOfId = userMsg.retryOf.isEmpty ? userMsg.id : userMsg.retryOf;
    // 先把系统那句「已暂停…」/「网络中断…」摘掉再重发：`_retryMessage` 会把当前正文
    // 存成一个**版本快照**，挂着我们的提示语进去 = 版本切换时给用户看一句系统话术。
    // 摘句用的还是 `drop_continue.dart` 里那一份判据（`stripRoundAbortNote`），
    // 不在这里重写字符串，也不新增第二处清洗路径。
    final body = stripRoundAbortNote(assistantMsg.content);
    if (body != assistantMsg.content) {
      setState(() => assistantMsg.content = body);
    }
    final seqBefore = _sendSeq;
    _bgRestartHandoff = true;
    _logger.info(
        '[Chat] 整轮重发起飞（走 _retryMessage 重跑这一轮，不是接断点）',
        cat: LogCat.chat,
        tag: 'Chat');
    await _retryMessage(assistantMsg);
    if (_sendSeq == seqBefore) {
      // 一条都没发出去（守卫挡下的那些出口）：一次性交接不许留给用户下一条消息。
      _bgRestartHandoff = false;
      _logger.warn('[Chat] 整轮重发未起飞（被 _retryMessage 的守卫挡下）',
          cat: LogCat.chat, tag: 'Chat');
      return;
    }
    // ④ 账单不许静默：重发那一轮的 token 落在新那条助手消息上，日志里必须数得出来。
    ChatMessage? billed;
    for (int i = _messages.length - 1; i >= 0; i--) {
      final m = _messages[i];
      if (m.role == MessageRole.assistant &&
          m.retryOf == retryOfId &&
          m.id != assistantMsg.id) {
        billed = m;
        break;
      }
    }
    _logger.info(
        '[Chat] ${bgRestartBillingLine(
            times: 1,
            promptTokens: billed?.promptTokens ?? 0,
            completionTokens: billed?.completionTokens ?? 0,
            totalTokens: billed?.totalTokens ?? 0)}',
        cat: LogCat.chat,
        tag: 'Chat');
  }

  /// build126：停止生成后的**看门狗**（卡死自愈）。
  ///
  /// 真机日志实证（nexus_2026-09-18）：停止后 _isStreaming 始终没复位 →
  /// ①「停止并撤回」在 _stopAndRollback 里等 3 秒等不到 → 弹「未能及时停止生成，
  /// 已保留当前消息」（用户报的"撤回失败"）；②输入栏永远停在停止态；
  /// ③思考计时器从 09-17 21:33 一直涨到 58225 秒。
  /// 停止动作本身只做两件事（置 _reactLoopStopRequested + close 客户端），
  /// 复位依赖循环收尾——循环一旦异常/早退就没人复位。
  ///
  /// 判定口径：3 秒后若该会话**已无任何活跃流**（ApiService 侧实测）但 UI 仍是
  /// 流式态 → 属状态机漏复位，强制收口。若还有流在跑则不动，交给它自己收尾。
  void _armStreamingWatchdog() {
    final scope = widget.conversation.id;
    final apiSvc = context.read<ApiService>();
    // build132（计时器审计）：3 秒后若已由**新一轮**接手（_sendSeq 递增），不得再动手。
    // 新一轮的开场段（落库 / 知识库构建 / 人设装配）可能超过 3 秒、且尚未打开流，
    // `hasActiveStream` 判不出来 —— 误伤会把新一轮的流式态按掉，输入栏与思考计时器
    // 跟着一起错（与 ReAct 兜底复位同一套「防误伤」判据）。
    final int mySeq = _sendSeq;
    Future<void>.delayed(const Duration(seconds: 3), () {
      if (!mounted) return;
      if (_sendSeq != mySeq) return; // 新一轮已接手 → 交给它自己收尾
      if (!_isStreaming) return;
      if (apiSvc.hasActiveStream(scope)) return;
      _logger.warn(
          '[Chat] Streaming watchdog fired: no active stream for scope but '
          '_isStreaming stuck (queued=${_pendingFollowupMessages.length}) -> force reset',
          cat: LogCat.chat,
          tag: 'Chat');
      _reactLoopStopRequested = false;
      // 看门狗是"这一轮已经没人收尾了，强制收口"，两个标志一起清才不会出现
      // "终止请求清了、用户停过的痕迹还挂着"→ 下一轮又追加一句假话。
      _reactLoopUserStopped = false;
      setState(() => _isStreaming = false);
      _refreshContextUsage();
    });
  }

  Future<void> _retryMessage(ChatMessage assistantMsg) async {
    final idx = _messages.indexOf(assistantMsg);
    if (idx <= 0) return;

    ChatMessage? userMsg;
    for (int i = idx - 1; i >= 0; i--) {
      if (_messages[i].role == MessageRole.user) {
        userMsg = _messages[i];
        break;
      }
    }
    if (userMsg == null) return;

    if (_isStreaming) return;

    final retryOfId = userMsg.retryOf.isEmpty ? userMsg.id : userMsg.retryOf;

    // v1.7.26 (E3)：重试版本快照持久化到独立 message_versions 表——v1.7.22
    // 的快照仅存内存，App 重启后版本切换与计数全部丢失
    final versions = _retryVersionStore.putIfAbsent(retryOfId, () => []);
    // B-024：判重——第二次起重试时「当前回答」已作为 versions.last 存在过
    //（上一轮重试收尾时存过），无条件 add 会累积重复项：版本计数虚高、
    // 切到相邻两个版本内容完全一样、message_versions 表冗余增长。
    final alreadyStored =
        versions.isNotEmpty && versions.last.content == assistantMsg.content;
    if (!alreadyStored) {
      versions.add(RetryVersion(
        content: assistantMsg.content,
        reasoningSteps: List<ReasoningStep>.from(assistantMsg.reasoningSteps),
        promptTokens: assistantMsg.promptTokens,
        completionTokens: assistantMsg.completionTokens,
        totalTokens: assistantMsg.totalTokens,
        cacheReadTokens: assistantMsg.cacheReadTokens,
        cacheWriteTokens: assistantMsg.cacheWriteTokens,
        cacheHitTokens: assistantMsg.cacheHitTokens,
        cacheMissTokens: assistantMsg.cacheMissTokens,
        injectedWebSearchCount: assistantMsg.injectedWebSearchCount,
        showStaleFootnote: assistantMsg.showStaleFootnote,
        modelName: assistantMsg.modelName ?? '',
        searchSources: List<SearchSource>.from(assistantMsg.searchSources),
      ));
    }
    _activeRetryVersionIndex[retryOfId] = versions.length;
    final storage = context.read<StorageService>();
    if (!alreadyStored) {
      await storage.saveMessageVersion(
          retryOfId, versions.length, versions.last);
    }

    // v1.7.26 (E4)：原位重插需沿用旧 pair 的 createdAt。DB 按 createdAt ASC
    // 排序加载会话，若沿用新时间，重载后重试 pair 会跑到列表末尾
    final oldUserCreatedAt = userMsg.createdAt;
    final oldAssistantCreatedAt = assistantMsg.createdAt;

    final userMsgId = userMsg.id;
    final assistantMsgId = assistantMsg.id;

    // B-007 调用面：两条消息一次事务删除——原两次独立 delete 若第二条失败
    // 会留半删（内存 removeWhere 在其后一次性删，还会造成内存与 DB 不一致）。
    await storage.deleteMessagesByIds([assistantMsgId, userMsgId]);

    int maxIndex = 0;
    for (final m in _messages) {
      if (m.retryOf == retryOfId) {
        if (m.retryIndex > maxIndex) maxIndex = m.retryIndex;
      }
    }
    final nextIndex = maxIndex + 1;

    _inputController.text = userMsg.content;
    _pendingAttachments
      ..clear()
      ..addAll(userMsg.attachments);
    if (mounted) {
      setState(() {
        _messages
            .removeWhere((m) => m.id == userMsgId || m.id == assistantMsgId);
      });
    }

    await _sendMessage(retryOf: retryOfId, retryIndex: nextIndex);

    if (mounted && _messages.isNotEmpty) {
      // 从末尾找新生成的 user/assistant pair（普通路径与 ReAct 路径都会带 retryOf）。
      // 无 AI 配置时 _sendMessage 走下载兜底直接返回、不产生新 pair → 整体跳过。
      ChatMessage? newUser;
      ChatMessage? newAssistant;
      for (int i = _messages.length - 1; i >= 0; i--) {
        final m = _messages[i];
        if (m.role == MessageRole.assistant && m.retryOf == retryOfId) {
          newAssistant ??= m;
        } else if (m.role == MessageRole.user && m.retryOf == retryOfId) {
          newUser ??= m;
        }
        if (newAssistant != null && newUser != null) break;
      }

      if (newAssistant != null) {
        final versions = _retryVersionStore.putIfAbsent(retryOfId, () => []);
        versions.add(RetryVersion(
          content: newAssistant.content,
          reasoningSteps: List<ReasoningStep>.from(newAssistant.reasoningSteps),
          promptTokens: newAssistant.promptTokens,
          completionTokens: newAssistant.completionTokens,
          totalTokens: newAssistant.totalTokens,
          cacheReadTokens: newAssistant.cacheReadTokens,
          cacheWriteTokens: newAssistant.cacheWriteTokens,
          cacheHitTokens: newAssistant.cacheHitTokens,
          cacheMissTokens: newAssistant.cacheMissTokens,
          injectedWebSearchCount: newAssistant.injectedWebSearchCount,
          showStaleFootnote: newAssistant.showStaleFootnote,
          modelName: newAssistant.modelName ?? '',
          searchSources: List<SearchSource>.from(newAssistant.searchSources),
        ));
        _activeRetryVersionIndex[retryOfId] = versions.length;
        await storage.saveMessageVersion(
            retryOfId, versions.length, versions.last);

        if (newUser != null) {
          // v1.7.26 (E4)：原位重插——把追加到末尾的新 pair 移回旧 pair 原本的
          // 位置（旧 pair 已被移除，插入点即 idx - 1），并回写 createdAt 后重新
          // 落库（saveMessage 为 replace 语义按 id 覆盖），保证 DB 重载顺序不变
          final nu = newUser;
          final na = newAssistant;
          final targetIdx = idx - 1;
          nu.createdAt = oldUserCreatedAt;
          na.createdAt = oldAssistantCreatedAt;
          _messages
            ..removeWhere((m) => m.id == nu.id || m.id == na.id)
            ..insert(targetIdx, nu)
            ..insert(targetIdx, na);
          await storage.saveMessage(nu);
          await storage.saveMessage(na);
        }
        if (mounted) setState(() {});
        _followBottomIfNeeded();
      }
    }
  }

  /// build101（B4）：长按消息的统一操作菜单
  ///
  /// 原 build90 的长按「保存到记忆」并入本菜单首项，其余为新增能力：
  /// 引用（收藏）/ 编辑重发（仅用户消息）/ 删除本条 / 复制文本。
  Future<void> _showMessageMenu(ChatMessage msg, int index) async {
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    final isUser = msg.role == MessageRole.user;
    // build129（#105）：与气泡行内同一个口径（共用纯函数）——只有最新一轮才给
    // 「编辑并重发」，历史消息长按也不再出现该入口。
    final isLatestUserMsg = isLatestRoundMessage(
        msgs: _messages, index: index, role: MessageRole.user);
    // build101：星标状态从 _starredIds 读（initState 时由会话初始化，切换后同步更新）
    final starred = _starredIds.contains(msg.id);
    // build126 (B2)：裸 showModalBottomSheet → 统一入口 showAppSheet，
    // 并补上 AppSheetHeader（原先无标题）。菜单项本身一字未动。
    final action = await showAppSheet<String>(
      context: context,
      scrollable: true,
      builder: (bctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppSheetHeader(title: isZh ? '消息操作' : 'Message actions'),
          // showAppSheet 自身不带滚动，用 Flexible 兜住：条目数随
          // 星标/流式状态变化（最多 6 条），加上标题会顶破默认高度上限。
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: const Icon(Icons.bookmark_add_outlined),
                    title: Text(isZh ? '保存到记忆' : 'Save to memory'),
                    onTap: () => Navigator.pop(bctx, 'memory'),
                  ),
                  ListTile(
                    leading: Icon(starred ? Icons.star : Icons.star_border),
                    // build133（⑦）：中文文案与行为对齐 —— 这个入口切换的是
                    // conversations.starredMessageIds（收藏/星标），图标也是星标，
                    // 英文一直是 "Star message"，只有中文写成「引用此条」，
                    // 而"引用"（把原消息插进输入框）从来不存在 ⇒ 改回收藏语义。
                    title: Text(starred
                        ? (isZh ? '取消收藏' : 'Unstar')
                        : (isZh ? '收藏此条' : 'Star message')),
                    onTap: () => Navigator.pop(bctx, 'star'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.copy_outlined),
                    title: Text(isZh ? '复制文本' : 'Copy text'),
                    onTap: () => Navigator.pop(bctx, 'copy'),
                  ),
                  // build129（#105）：编辑重发只留最新一轮——此前这里只判 `isUser`，
                  // 行内按钮收口后长按菜单成了唯一破口（老消息仍可编辑重发）。
                  // 与行内共用 isLatestRoundMessage，口径不会再各写一遍。
                  if (isUser && isLatestUserMsg && !_isStreaming)
                    ListTile(
                      leading: const Icon(Icons.edit_outlined),
                      title: Text(isZh ? '编辑并重发' : 'Edit and resend'),
                      subtitle: Text(
                        isZh ? '会删除此条之后的所有消息' : 'Deletes all later messages',
                        style: Theme.of(bctx).textTheme.bodySmall,
                      ),
                      onTap: () => Navigator.pop(bctx, 'edit'),
                    ),
                  // build101（F4）：中断续接——对最后一条助手消息续写
                  if (!isUser && !_isStreaming)
                    ListTile(
                      leading: const Icon(Icons.play_circle_outline),
                      title: Text(isZh ? '从此条继续生成' : 'Continue from here'),
                      subtitle: Text(
                        isZh
                            ? '接着这条回复往下写（适配上一次被中断的情况）'
                            : 'Keep writing from this reply',
                        style: Theme.of(bctx).textTheme.bodySmall,
                      ),
                      onTap: () => Navigator.pop(bctx, 'continue'),
                    ),
                  // C1（O12 子项）：生成中「停止并撤回」——原实现编辑重发/续写被
                  // `!_isStreaming` 门禁隐藏，流式进行中用户无法终止并回滚本轮。
                  // 仅对活跃问答对（本轮用户消息 + 流式中的助手消息）显示。
                  if (_isStreaming && index >= _messages.length - 2)
                    ListTile(
                      leading: Icon(Icons.stop_circle_outlined,
                          color: Theme.of(bctx).colorScheme.error),
                      title: Text(isZh ? '停止并撤回' : 'Stop and roll back',
                          style: TextStyle(
                              color: Theme.of(bctx).colorScheme.error)),
                      subtitle: Text(
                        isZh
                            ? '终止本次生成，并删除本轮提问与回答'
                            : 'Stop generating and delete this round',
                        style: Theme.of(bctx).textTheme.bodySmall,
                      ),
                      onTap: () => Navigator.pop(bctx, 'stop_rollback'),
                    ),
                  ListTile(
                    leading: Icon(Icons.delete_outline,
                        color: Theme.of(bctx).colorScheme.error),
                    title: Text(isZh ? '删除本条' : 'Delete message',
                        style:
                            TextStyle(color: Theme.of(bctx).colorScheme.error)),
                    onTap: () => Navigator.pop(bctx, 'delete'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'memory':
        await _saveMessageToMemory(msg.content);
        break;
      case 'star':
        final storage = context.read<StorageService>();
        final cid = widget.conversation.id;
        await storage.toggleStarMessage(cid, msg.id);
        final refreshed = await storage.getConversation(cid);
        if (!mounted) break;
        setState(() {
          _starredIds = refreshed?.starredIds ?? _starredIds;
        });
        break;
      case 'copy':
        await Clipboard.setData(ClipboardData(text: msg.content));
        if (!mounted) break;
        AppSnackBar.showSnackBar(
          context,
          SnackBar(
            content: Text(isZh ? '已复制' : 'Copied'),
            duration: const Duration(seconds: 1),
          ),
        );
        break;
      case 'continue':
        await _continueFromMessage(msg);
        break;
      case 'edit':
        await _editAndResend(msg, index);
        break;
      case 'delete':
        await _deleteSingleMessage(msg);
        break;
      case 'stop_rollback':
        await _stopAndRollback(msg);
        break;
    }
  }

  /// C1（O12 子项）：生成中「停止并撤回」。
  ///
  /// 语义：先停生成（沿用现有 stopRequested 链路），再走 `_rollbackMessage`
  /// 同一路径回滚本轮（提问 + 未完成的回答一起删）。
  ///
  /// 边界（施工口径要求「停止失败不删消息」）：
  /// - 只允许对本轮活跃问答对操作（调用点已用 `index >= _messages.length - 2`
  ///   门禁；此处再校验一次，防止列表在弹窗期间变化）；
  /// - 若流未能在超时内停止，**不删消息**，仅提示用户重试停止。
  Future<void> _stopAndRollback(ChatMessage msg) async {
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    if (!_isStreaming) return;

    // ① 停止生成（scope 级 + ReAct 循环开关，与 _stopGeneration 同源）
    _stopGeneration();

    // ② 等流真正落地——最多 3 秒；停止失败则不删任何消息
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (_isStreaming && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!mounted) return;
    if (_isStreaming) {
      // build164（#84）：这条分支过去只有一句 SnackBar，日志里零痕迹 ——
      // 而 #74（「停止并撤回」被误判成未停）要的正是"到底停没停下来"这一行的证据。
      _logger.warn(
          describeMessageDeletionForLog(
              action: '撤回未执行（停止并撤回）',
              deleted: const [],
              verboseEnabled: _logger.verboseEnabled,
              skippedBecause: '流未能在 3 秒内停止，本轮消息已按原样保留'),
          cat: LogCat.chat,
          tag: 'Chat');
      AppSnackBar.showSnackBar(
        context,
        SnackBar(
          content: Text(isZh
              ? '未能及时停止生成，已保留当前消息（可稍后手动删除）'
              : 'Could not stop in time; messages kept (delete manually if needed)'),
          duration: const Duration(seconds: 3),
        ),
      );
      return;
    }

    // ③ 回滚本轮：定位触发本轮的**用户消息**（助手消息往前找最近一条 user）
    final idx = _messages.indexOf(msg);
    if (idx < 0) {
      _logger.warn(
          describeMessageDeletionForLog(
              action: '撤回未执行（停止并撤回）',
              deleted: const [],
              verboseEnabled: _logger.verboseEnabled,
              skippedBecause: '该消息已不在当前列表'),
          cat: LogCat.chat,
          tag: 'Chat');
      return;
    }
    ChatMessage? userMsg;
    if (msg.role == MessageRole.user) {
      userMsg = msg;
    } else {
      for (int i = idx - 1; i >= 0; i--) {
        if (_messages[i].role == MessageRole.user) {
          userMsg = _messages[i];
          break;
        }
      }
    }
    if (userMsg == null) {
      _logger.warn(
          describeMessageDeletionForLog(
              action: '撤回未执行（停止并撤回）',
              deleted: const [],
              verboseEnabled: _logger.verboseEnabled,
              startIndex: idx,
              skippedBecause: '这条助手消息前面找不到提问，本轮无法整体撤回'),
          cat: LogCat.chat,
          tag: 'Chat');
      return;
    }
    await _rollbackMessage(userMsg);
    if (mounted) {
      AppSnackBar.showSnackBar(
        context,
        SnackBar(
          content: Text(isZh ? '已停止并撤回本轮' : 'Stopped and rolled back'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  /// build101（F4）：从指定助手消息「继续生成」。
  ///
  /// 适用场景：上一次生成被用户停止 / 网络中断 / 达到 max_tokens，
  /// 回复在句子中间断掉。此时不想重头再来（重试会丢掉已有内容），
  /// 而是希望模型**接着往下写**。
  ///
  /// 实现：不发新用户消息，而是把「已有回复」+ 一条 continue 指令
  /// 作为历史上下文，让模型续写；续写结果**替换**该条消息的正文
  /// （而非新增一条），这样列表不会出现半截 + 完整两份。
  ///
  /// 边界：
  /// - 只允许对**本会话最后一条**助手消息操作（续写中间的历史回复，
  ///   会让后续消息失去上下文意义）；
  /// - 流式中禁用。
  /// build161：[onStreamError] 把**流异常**透给调用方（落库/列表那类外围错照旧只记日志）。
  ///
  /// 为什么只开这一个口子、而不是把返回值改成 `Future<String?>`：这个函数里有五条提前
  /// return 的守卫（正在流式 / 不是最后一条 / 正文空 / 无配置），改返回类型要连带动它们
  /// 一遍，而其中任何一条走错都会让续写"看起来成功"。流异常是本轮唯一需要的信号，
  /// 就在 catch 那一处给出去。
  /// 消费点：`chat_screen_react.dart` 的 `_runDropContinueRound`（① 自动续）与
  /// `_continueAfterDrop`（③ 用户点「接着写」）—— 两处都不许再拿"正文有没有变"
  /// 当"续完了"的判据，那是把**再掉线**写成「· 已完成」的那一条假话。
  Future<void> _continueFromMessage(ChatMessage assistantMsg,
      {void Function(String reason)? onStreamError}) async {
    if (_isStreaming) return;
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';

    // 只允许续写最后一条助手消息（且其后面不能还有别的消息）
    final lastAssistantIndex = _messages.lastIndexWhere(
        (m) => m.role == MessageRole.assistant && m.content.trim().isNotEmpty);
    if (lastAssistantIndex < 0 ||
        _messages[lastAssistantIndex].id != assistantMsg.id ||
        lastAssistantIndex != _messages.length - 1) {
      AppSnackBar.showSnackBar(
        context,
        SnackBar(
          content: Text(isZh
              ? '只能对最后一条回复续写（否则会打乱后续对话上下文）'
              : 'Can only continue the last reply'),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    if (assistantMsg.content.trim().isEmpty) return;

    final storage = context.read<StorageService>();
    final apiSvc = context.read<ApiService>();
    final config = _currentSessionModel ?? _apiConfig;
    if (config == null) return;

    final originalTail = assistantMsg.content;
    final continueHint = isZh
        ? '\n\n[继续] 上面的回复被中断了，请**直接从断点处接着写**，'
            '不要重复已写过的内容，不要重新开头，不要加任何解释性前缀。'
        : '\n\n[Continue] The reply above was interrupted. '
            '**Continue writing directly from where it stopped.** '
            'Do not repeat what was already written, do not restart, '
            'and do not add any explanatory prefix.';

    // 历史 = 该条之前的全部消息 + 该条自身；hint 拼在该条正文尾部
    // （streamChat 无独立 system 参数，用正文尾注是最小侵入的做法）
    final history = _messages
        .take(lastAssistantIndex + 1)
        .where((m) => m.role != MessageRole.assistant || m.content.isNotEmpty)
        .map((m) => m.id == assistantMsg.id
            ? ChatMessage(
                id: m.id,
                conversationId: m.conversationId,
                role: m.role,
                content: m.content + continueHint,
                createdAt: m.createdAt,
              )
            : m)
        .toList();

    // build157（会话状态机 S3 ⑩）：续写**也是一轮**，过去它只置 `_isStreaming` 却不登记
    // `_sendSeq` ⇒ 两个后果：① 停止看门狗（`_armStreamingWatchdog`，build132 的判据就是
    // `_sendSeq != mySeq`）认不出"续写这一轮已经开始"，于是上一轮遗留的看门狗会在续写
    // 正当中把 `_isStreaming` 按掉、顺手清掉终止标志；② 本出口无法判断"有没有更新的
    // 一轮已经接手"，收尾只能无脑复位。登记后与 :338 完全同形。
    final int mySeq = ++_sendSeq;
    setState(() => _isStreaming = true);

    // 把续写增量接到原消息尾部，视觉上像"内容自己长出来"
    final base = originalTail;
    var appended = '';
    var sawDelta = false;

    try {
      final stream = apiSvc.streamChat(
        config: config,
        messages: history,
        stopScope: widget.conversation.id,
      );
      // build101（F4）：续写指令通过"最后一条消息尾部追加"注入——
      // streamChat 不接受独立 system 参数，故把 hint 拼到该条正文末尾，
      // 流结束后再从落库内容里剥离，避免污染正文。
      await for (final delta in stream) {
        if (!mounted) break;
        if (!sawDelta) sawDelta = true;
        appended += delta;
        setState(() {
          // B-030/build112：流式展示同样过唯一出口净化——否则续写期间气泡会实时
          // 显示 <memory_write>/<todo> 等控制标签原文。
          assistantMsg.content = AnswerFinalizer.stripTags(base + appended);
        });
      }
    } catch (e) {
      _logger.warn('[Chat] continue-from failed: $e',
          cat: LogCat.chat, tag: 'Chat');
      // build161：这一句就是"续写这一腿到底有没有跑完"的唯一出口。吞掉它，
      // 调用方就只能拿"正文长了没有"猜 ⇒ 中途再掉线会被写成「· 已完成」。
      onStreamError?.call(e.toString());
    } finally {
      // build157：与 :338 同形的复位判据 —— 只有"这一轮还是最新一轮"才由本出口收口。
      // 今天看这条判断恒真（续写期间用户点发送只会入队，不会起新一轮），但它挡的是
      // 以后有人在续写里插入 drain / 重发的那一次改动，成本为零。
      if (mounted && _isStreaming && _sendSeq == mySeq) {
        setState(() => _isStreaming = false);
      }
    }

    if (!mounted) return;
    // build154（会话状态机 S3）：续写是第五个持过 `_isStreaming` 的出口，但历史上
    // 它既不 drain 插话队列、也不刷用量条——用户在续写期间点发送会走 `_sendMessage`
    // 的入队分支（那条分支不认识「续写」，照样承诺「AI 下一轮会处理」），续写结束后
    // 这句话无人消费、角标残留；续写增量也已写进 DB，用量条却还停在续写前
    // （build141 B-5「每个改了 `_messages` 的出口都要刷新」同族漏点）。
    _refreshContextUsage();
    // build157（S3 ⑩）：drain 原来就压在这一行 —— **在定稿之前**。于是插话队列一旦
    // 非空，新一轮已经起流、正在往 `_messages` 追加消息，续写却还在后面做
    // 「回滚显示 / updateMessageContent」，两边同时改同一会话的真源，
    // 结果是历史（内存）、DB、以及新一轮发给模型的上下文三者可能分叉。
    // 现在 drain 挪到本方法**每一条出口的最后**（见 _drainAfterContinue）。
    // B-030：续写是**第四个**「把模型流定稿成消息」的出口，此前只 trim 就
    // updateMessageContent —— 控制标签（memory_write/todo/suggest/search/thinking）
    // 原样落库并显示，且与主流式出口的净化口径不一致。这里补齐 stripControlTags
    //（续写语义是「接断点补正文」，不在此执行记忆/待办等副作用动作）。
    // build112：续写是第四个定稿出口，同样收敛到唯一出口（含 L1 头部话术剥离）
    final finMerged = AnswerFinalizer.finalize(base + appended);
    if (finMerged.stripped.isNotEmpty) {
      _logger.warn(
          '[Chat] L1 stripped ${finMerged.stripped.length} chars of leading meta talk from continue-from',
          cat: LogCat.chat,
          tag: 'Chat');
    }
    final merged = finMerged.clean;
    if (!sawDelta || merged == base.trim()) {
      // 模型没吐出任何新内容：回滚显示，提示用户
      // build157：回滚前先看这条还在不在 `_messages` 里 —— 续写期间用户"编辑重发"
      // 会截断该条之后的消息，`assistantMsg` 是**对象引用**，截断后照样能写，
      // 写进一个已经不在列表里的对象 = 白写（内存与显示分叉），下面那句
      // `updateMessageContent` 更会把正文落回一条已删的行。
      if (_isMessageAlive(assistantMsg.id)) {
        setState(() => assistantMsg.content = originalTail);
      } else {
        _logger.warn('[Chat] continue-from rollback skipped: message gone from list',
            cat: LogCat.chat, tag: 'Chat');
      }
      AppSnackBar.showSnackBar(
        context,
        SnackBar(
          content: Text(isZh
              ? '未能续写（模型没有返回新内容），已恢复原回复'
              : 'Nothing new generated; original reply restored'),
          duration: const Duration(seconds: 2),
        ),
      );
      _drainAfterContinue(mySeq);
      return;
    }
    if (!_isMessageAlive(assistantMsg.id)) {
      // 同上，但这一支更严重：不守住就会**往一条已经不存在的消息写正文**，
      // 而内存里那条已被截掉 ⇒ DB 里多出一段没有任何气泡承载的内容。
      _logger.warn('[Chat] continue-from skipped DB write: message no longer alive',
          cat: LogCat.chat, tag: 'Chat');
      _drainAfterContinue(mySeq);
      return;
    }
    // 落库：更新该条消息正文（不新增消息）
    await storage.updateMessageContent(assistantMsg.id, merged);
    if (mounted) {
      AppSnackBar.showSnackBar(
        context,
        SnackBar(
          content: Text(isZh ? '已续写并保存' : 'Continued and saved'),
          duration: const Duration(seconds: 1),
        ),
      );
    }
    // build157（S3 ⑩）：drain 只能在**定稿之后**发生（原来在之前，见上方注释）。
    _drainAfterContinue(mySeq);
  }

  /// build157（S3 ⑩）：续写收尾的唯一 drain 出口。
  ///
  /// 判据 `_sendSeq == mySeq`：若续写结束后用户已经手工发起了更新的一轮，
  /// 那条插话归那一轮 drain（它自己的出口都会走到），这里再 drain 一次就是
  /// 两轮流抢同一队列。与 `_armStreamingWatchdog`、`:338` 的"按轮次认归属"同口径。
  void _drainAfterContinue(int mySeq) {
    if (!mounted || _sendSeq != mySeq) return;
    _drainPendingFollowups();
  }

  /// build101（B3）：编辑用户消息并重发
  ///
  /// 流程：编辑框 → 确认后**截断该条之后的所有消息** → 用新内容替换该条 →
  /// 直接重新发起生成（保留原有附件）。
  Future<void> _editAndResend(ChatMessage userMsg, int index) async {
    if (_isStreaming) return;
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    final controller = TextEditingController(text: userMsg.content);
    // build126 (B2)：AlertDialog → 底部弹层。keyboardAware 必须开 ——
    // 这里是 8 行多行输入框，弹层从底部升起时若不避让键盘，
    // 「重发」按钮会被输入法完全盖住。
    final newText = await showAppSheet<String>(
      context: context,
      keyboardAware: true,
      builder: (dctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppSheetHeader(title: isZh ? '编辑并重发' : 'Edit and resend'),
          // showAppSheet 自身不带滚动：keyboardAware 会把键盘高度垫在底部，
          // 矮屏上「标题+8 行输入框+按钮」可能顶破可用高度，故用 Flexible 兜住。
          Flexible(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppGap.lg),
                child: TextField(
                  controller: controller,
                  autofocus: true,
                  maxLines: 8,
                  minLines: 3,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    hintText: isZh ? '修改后重新发送' : 'Edit and resend',
                  ),
                ),
              ),
            ),
          ),
          AppSheetActions(children: [
            TextButton(
              onPressed: () => Navigator.pop(dctx),
              child: Text(isZh ? '取消' : 'Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dctx, controller.text),
              child: Text(isZh ? '重发' : 'Resend'),
            ),
          ]),
        ],
      ),
    );
    // B-009：编辑框 controller 在取消/空值/重发三路径都要释放
    controller.dispose();
    if (newText == null || !mounted) return;
    final edited = newText.trim();
    if (edited.isEmpty) return;

    final storage = context.read<StorageService>();
    // 1) 截断该条之后的所有消息（含上下文压缩片段的失效清理）
    //    注意顺序：必须在删掉本条**之前**执行（truncate 依赖本条 createdAt 定位）。
    await storage.truncateMessagesAfter(userMsg.conversationId, userMsg.id);
    // B-025：再删除本条用户消息——旧实现保留它（还 updateMessageContent 成新内容）
    // 又让 _sendMessage 内部 ChatMessage.create 新建一条同内容用户消息并 add/save，
    // 结果同一句提问在列表与 DB 各存两份（旧编辑版 + 新发送版），对话结构错乱。
    // 对照 _retryMessage：它发送前会先摘掉旧 pair。此处用单事务批量删除（B-007 口径）。
    await storage.deleteMessagesByIds([userMsg.id]);

    if (!mounted) return;
    // 2) 本地状态同步：移除该条及其后消息（新用户消息由 _sendMessage 插入）
    setState(() {
      _messages.removeRange(index, _messages.length);
    });
    // 3) 重新发起生成（复用发送链路；输入框文本即新问题）
    _inputController.text = edited;
    _pendingAttachments
      ..clear()
      ..addAll(userMsg.attachments);
    await _sendMessage(retryOf: userMsg.id);
  }

  /// build101（B4）：删除单条消息
  Future<void> _deleteSingleMessage(ChatMessage msg) async {
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text(isZh ? '删除这条消息？' : 'Delete this message?'),
        content: Text(isZh
            ? '仅删除选定的一条消息，其余消息不受影响。'
            : 'Only this message will be removed.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: Text(isZh ? '取消' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, true),
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(dctx).colorScheme.error),
            child: Text(isZh ? '删除' : 'Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final storage = context.read<StorageService>();
    final fact = DeletedMsgFact.of(msg);
    final idx = _messages.indexOf(msg);
    await storage.deleteMessage(msg.id);
    // build164（#84）：单条删除也要留痕 —— ⑥ 那次整份日志里连"删过"都搜不出来。
    _logger.warn(
        describeMessageDeletionForLog(
            action: '删除单条',
            deleted: [fact],
            verboseEnabled: _logger.verboseEnabled,
            startIndex: idx),
        cat: LogCat.chat,
        tag: 'Chat');
    if (!mounted) return;
    setState(() => _messages.remove(msg));
    // build141（反馈④ 同类漏点第 2 处）：删除同样改了 `_messages`，必须重算用量。
    _refreshContextUsage();
  }

  Future<void> _rollbackMessage(ChatMessage userMsg) async {
    // build164（#84）：撤回留痕。**只加日志，撤回语义一个字没动**
    // （"删除"还是"标记"是待决项 #74，用户另有决定；这里不替它选边）。
    final verboseOn = _logger.verboseEnabled;
    if (_isStreaming) {
      // 这一条以前是纯静默：用户按了撤回、什么都没发生、日志里也一个字都没有。
      _logger.warn(
          describeMessageDeletionForLog(
              action: '撤回未执行',
              deleted: const [],
              verboseEnabled: verboseOn,
              skippedBecause: '仍在流式生成中（本轮还没落地）'),
          cat: LogCat.chat,
          tag: 'Chat');
      return;
    }
    final idx = _messages.indexOf(userMsg);
    if (idx < 0) {
      _logger.warn(
          describeMessageDeletionForLog(
              action: '撤回未执行',
              deleted: const [],
              verboseEnabled: verboseOn,
              skippedBecause: '提问已不在当前列表'),
          cat: LogCat.chat,
          tag: 'Chat');
      return;
    }

    // v1.7.25 修复：撤回支持任意一条用户消息（v1.7.22 误加"仅最后一条"限制，
    // 导致历史消息撤回点了没反应）。语义：撤回该条提问 → 级联删除它及其后的
    // 所有消息（后续回答/追问都依赖这条提问）。
    if (_messages.length < 2) {
      _logger.warn(
          describeMessageDeletionForLog(
              action: '撤回未执行',
              deleted: const [],
              verboseEnabled: verboseOn,
              startIndex: idx,
              skippedBecause: '会话只剩一条消息'),
          cat: LogCat.chat,
          tag: 'Chat');
      return;
    }
    final toDelete = _messages.sublist(idx).toList();
    // 撤了哪些：在**动手删之前**把角色/id/字数抄下来（删完就从列表里拿不到了）。
    final facts = toDelete.map(DeletedMsgFact.of).toList();

    final storage = context.read<StorageService>();
    // v1.7.26 (E5)：级联删除走单事务，避免中途失败留下半删状态
    await storage.deleteMessagesByIds(toDelete.map((m) => m.id).toList());
    // 留痕写在删除**成功之后**：事务抛异常时不会留下一行"已经撤了"的假话。
    _logger.warn(
        describeMessageDeletionForLog(
            action: '撤回本轮',
            deleted: facts,
            verboseEnabled: verboseOn,
            startIndex: idx),
        cat: LogCat.chat,
        tag: 'Chat');

    // v1.7.22：清理重试版本存储
    final retryOfId = userMsg.retryOf.isEmpty ? userMsg.id : userMsg.retryOf;
    // v1.7.26 (E3)：同步清理持久化版本快照，避免孤儿数据残留
    await storage.deleteMessageVersions(retryOfId);
    _retryVersionStore.remove(retryOfId);
    _activeRetryVersionIndex.remove(retryOfId);

    _inputController.text = userMsg.content;
    _pendingAttachments
      ..clear()
      ..addAll(userMsg.attachments);

    if (mounted) {
      setState(() {
        _messages.removeWhere((m) => toDelete.contains(m));
      });
      // build141（真机反馈④「撤回后还要发消息才能刷新」）：用量条读的是
      // `_contextUsedTokens` 这份**可派生缓存**，撤回把消息删了却没重算 ⇒
      // 数字一直停在撤回前，直到下一次「发消息」之类的动作才被动纠正。
      // 同类漏点还有 `_deleteMessage` 与「无 API Key 的下载兜底」分支，三处一起补。
      _refreshContextUsage();
    }
  }

  String _retryOfId(ChatMessage msg) {
    if (msg.retryOf.isNotEmpty) return msg.retryOf;
    if (msg.role != MessageRole.assistant) return '';
    final idx = _messages.indexOf(msg);
    if (idx <= 0) return '';
    for (int i = idx - 1; i >= 0; i--) {
      if (_messages[i].role == MessageRole.user) {
        return _messages[i].retryOf.isEmpty
            ? _messages[i].id
            : _messages[i].retryOf;
      }
    }
    return '';
  }

  int _computeRetryVersionCount(ChatMessage msg) {
    if (msg.role != MessageRole.assistant) return 0;
    final retryOf = _retryOfId(msg);
    if (retryOf.isEmpty) return 0;
    final versions = _retryVersionStore[retryOf];
    return versions?.length ?? 0;
  }

  /// build101（E8 自定义助手）：读取本会话绑定的助手，返回可插入
  /// system 前缀的人设消息；未绑定/已删除/提示词为空都返回 null。
  Future<ChatMessage?> _buildAssistantBlock() async {
    final id = widget.conversation.assistantId;
    if (id.isEmpty) return null;
    try {
      final assistant = await context.read<StorageService>().getAssistant(id);
      if (assistant == null || assistant.systemPrompt.trim().isEmpty) {
        return null;
      }
      return ChatMessage.create(
        conversationId: widget.conversation.id,
        role: MessageRole.system,
        content: assistant.systemPrompt.trim(),
      );
    } catch (e) {
      debugPrint('catch 静默异常: $e');
      return null;
    }
  }

  /// build101（C1 知识库 RAG）：按当前对话绑定的知识库做向量检索，
  /// 返回可直接插入 system 前缀的资料块；未绑定/无命中/失败都返回 null。
  ///
  /// build102（E）：绑定库之外追加所有「全局可用」（isPublic）的库一起检索，
  /// 合并结果按相似度降序，总量不超过各库 topK 的最大值（注入体积可控）。
  ///
  /// 失败一律静默降级（不阻塞正常对话）——embedding 接口挂掉时，
  /// 用户仍应得到一次正常回答，只是没有知识库引用。
  Future<ChatMessage?> _buildKnowledgeContext(
    String query,
    ApiConfig apiConfig, {
    required bool isZh,
  }) async {
    if (query.trim().isEmpty) return null;
    try {
      final storage = context.read<StorageService>();
      final configs = await storage.getApiConfigs();

      // 收集检索目标：绑定的库优先，再追加全局可用库（按 id 去重）
      final targets = <KnowledgeBase>[];
      final kbId = widget.conversation.knowledgeBaseId;
      if (kbId.isNotEmpty) {
        final kb = await storage.getKnowledgeBase(kbId);
        if (kb != null && kb.embeddingModel.trim().isNotEmpty) {
          targets.add(kb);
        }
      }
      try {
        for (final kb in await storage.getPublicKnowledgeBases()) {
          if (kb.embeddingModel.trim().isEmpty) continue;
          if (targets.any((t) => t.id == kb.id)) continue;
          targets.add(kb);
        }
      } catch (_) {
        // 公共库查询失败不拖垮绑定库
      }
      if (targets.isEmpty || configs.isEmpty) return null;

      final allHits = <KnowledgeHit>[];
      // build140（P0 缺口⑤）：检索阈值从"写死 0.15"改成用户可调。
      // 读取一次、供本轮所有库共用（阈值是全局口径，不是按库；理由见
      // lib/utils/kb_retrieval_settings.dart 头注）。
      // 失败必须回落默认值而不是抛：这条链路的设计是"知识库挂了也不能挡住回答"，
      // 外层 catch 会静默降级成"没有引用"，把偏好读取失败也算进去会让用户
      // 误以为知识库坏了。
      // 注：不能写成 `final double minScore; try{...}catch{minScore=默认}`——
      // Dart 的明确赋值分析会认为 try 里可能已经赋过值，catch 里再赋就是
      // assignment_to_final_local。所以先用可变量接、再收敛成 final。
      double minScoreLoaded = KbRetrievalSettings.kDefault;
      try {
        minScoreLoaded = await KbRetrievalSettings.load(
            await SharedPreferences.getInstance());
      } catch (_) {
        // 读取失败就吃默认值
      }
      final double minScore = minScoreLoaded;
      // build104（S1）：同一 (embedding 配置, 模型) 只算一次 query 向量——
      // 修复多库检索时 embedding API 按库数重复计费（费用×N）
      final qvecCache = <String, List<double>>{};
      // 第 15 轮扫描 P2：哪些库这一轮是**抛异常**没出结果，而不是"查了没查到"。
      final failedKbs = <String>[];
      for (final kb in targets) {
        try {
          // 解析该库 embedding 用的 API 配置
          ApiConfig? embCfg;
          if (kb.embeddingConfigId.isNotEmpty) {
            for (final c in configs) {
              if (c.id == kb.embeddingConfigId) {
                embCfg = c;
                break;
              }
            }
          }
          embCfg ??= configs.first;

          final chunks = await storage.loadChunksForSearch(kb.id);
          if (chunks.isEmpty) continue;
          final pairKey = '${kb.embeddingConfigId}|${kb.embeddingModel.trim()}';
          if (!qvecCache.containsKey(pairKey)) {
            final vecs = await RagService.embed(
                config: embCfg,
                model: kb.embeddingModel.trim(),
                texts: [query]);
            qvecCache[pairKey] = vecs.isNotEmpty ? vecs.first : const [];
          }
          final qv = qvecCache[pairKey]!;
          if (qv.isEmpty) continue;
          final outcome = await RagService.retrieveWithDiagnostics(
            config: embCfg,
            model: kb.embeddingModel.trim(),
            chunks: chunks,
            query: query,
            queryVector: qv,
            topK: kb.topK,
            minScore: minScore,
          );
          allHits.addAll(outcome.hits);
          // 全量缺陷扫描修复：把「切片没参与打分」从**静默**变成可见。
          // 其中「维度不符」几乎总是换过 embedding 模型 —— 此时该库旧切片会
          // 全部检索不到，用户只会觉得「知识库失效了」，此前没有任何线索。
          final ragDiag = outcome.diag;
          if (ragDiag.skipped > 0) {
            _logger.warn(
              '[RAG] kb="${kb.name}" ${ragDiag.skipped}/${ragDiag.total} 切片未参与打分'
              '（空向量 ${ragDiag.skippedEmpty} / 维度不符 ${ragDiag.skippedDim}）'
              '${ragDiag.skippedDim > 0 ? ' —— 维度不符通常是换过 embedding 模型，建议重建该库索引' : ''}',
              cat: LogCat.chat,
              tag: 'RAG',
            );
          }
        } catch (e) {
          // 单库失败不拖垮其它库 —— 但**必须留痕**（第 15 轮扫描 P2）。
          // 旧写法是 `catch (_) {}`：一行日志都没有，于是"embedding 配置被改名/过期"
          // 这类故障在导出日志里的表现是 0 条，而紧接着那句
          // 「N 个库均未命中（检索阈值 X）」会把人推向阈值旋钮 ——
          // 一条**指错方向的假线索**比没有线索更费时间。
          failedKbs.add(kb.name);
          _logger.warn(
            '[RAG] kb="${kb.name}" 这一库检索失败，已跳过（不影响其它库）：$e',
            cat: LogCat.chat,
            tag: 'RAG',
          );
        }
      }
      if (allHits.isEmpty) {
        if (failedKbs.isNotEmpty) {
          // 归因说在前头：有库抛异常时，"没命中"根本不是阈值问题。
          _logger.warn(
            '[RAG] ${targets.length} 个库全部无结果，其中 ${failedKbs.length} 个是'
            '**异常**（${failedKbs.join("、")}）—— 先看上面每条失败原因，'
            '调阈值不会有用',
            cat: LogCat.chat,
            tag: 'RAG',
          );
        }
        // build140（P0 缺口⑤）：阈值既然用户可调，"一条都没命中"就必须留痕——
        // 否则用户把阈值调高之后只会看到「知识库没生效」，仍然无从下手。
        // 与上面 skipped 的诊断同一条思路：**静默 = 不可排查**。
        _logger.info(
          '[RAG] ${targets.length} 个库均未命中（检索阈值 $minScore）'
          ' —— 阈值可在「知识库」页调整，调低会注入更多资料',
          cat: LogCat.chat,
          tag: 'RAG',
        );
        return null;
      }
      allHits.sort((a, b) => b.score.compareTo(a.score));
      final cap = targets.map((t) => t.topK).reduce((a, b) => a > b ? a : b);
      final merged = allHits.take(cap).toList();
      final block = RagService.buildContextBlock(merged, zh: isZh);
      if (block.isEmpty) return null;
      return ChatMessage.create(
        conversationId: widget.conversation.id,
        role: MessageRole.system,
        content: block,
      );
    } catch (e) {
      // 第 15 轮扫描 P2：外层整条 RAG 失败原来只 `debugPrint` ——
      // release 包里 `debugPrint` 不进可导出的日志（build156 就是这么定的口径），
      // 于是"这轮根本没做知识库检索"在日志里同样是 0 条。
      _logger.warn('[RAG] 本轮知识库检索整体失败，已按无资料继续：$e',
          cat: LogCat.chat, tag: 'RAG');
      return null;
    }
  }

  /// build101（D3）：首字耗时估算——取第一条推理步骤的 latencyMs
  /// （思考/首 token 到达的时间），无数据返回 0 不渲染。
  /// 注：ChatMessage 本身不落库该指标，避免 DB 迁移；仅对有思考链的消息有意义。
  int _firstTokenLatencyOf(ChatMessage msg) {
    for (final s in msg.reasoningSteps) {
      final v = s.latencyMs;
      if (v != null && v > 0) return v;
    }
    return 0;
  }

  /// build101（D4）：AI 自动生成会话标题。
  ///
  /// 在阶段 3（外观族）之前，标题只是「首条消息前 30 字」截断。
  /// 开启聊天外观页的「自动生成标题」开关后，首轮对话结束时额外发一次
  /// 轻量非流式请求，让模型把首轮问答浓缩成 ≤12 字的短标题。
  ///
  /// 设计约束：
  /// - 完全 fire-and-forget，失败静默（不打扰用户、不改动截断降级结果）
  /// - 用独立 stopScope，避免用户点停止时把标题请求一起打断
  /// - 只在「标题仍等于首轮截断值」时才覆盖，用户手动改过就不动
  void _maybeAutoGenerateTitle(String userText) {
    final skin = context.read<ChatSkinProvider>();
    if (!skin.autoTitle) return;
    final cfg = _currentSessionModel ?? _apiConfig;
    if (cfg == null) return;
    final convId = widget.conversation.id;
    final expected =
        userText.length > 30 ? '${userText.substring(0, 30)}...' : userText;
    unawaited(() async {
      try {
        final api = context.read<ApiService>();
        final zh = AppLocalizations.of(context).locale.languageCode == 'zh';
        final reply = await api.completeChat(
          config: cfg,
          messages: [
            ChatMessage(
              id: 'title-gen',
              conversationId: convId,
              role: MessageRole.user,
              content: zh
                  ? '请用不超过12个字概括下面这段对话的主题，只输出标题本身，'
                      '不要引号、不要标点、不要解释：\n\n$userText'
                  : 'Summarize the topic of the following message in at most '
                      '6 words. Output only the title, no quotes, no '
                      'punctuation, no explanation:\n\n$userText',
              createdAt: DateTime.now(),
            ),
          ],
          timeout: const Duration(seconds: 30),
          stopScope: 'title_gen_$convId',
        );
        if (!mounted) return;
        var title = reply.trim();
        // 清掉模型可能带上的引号/换行/前缀
        title = title.replaceAll('\n', ' ').trim();
        title =
            title.replaceAll(RegExp('^[\\s"\u201c\u201d\u2018\u2019]+'), '');
        title =
            title.replaceAll(RegExp('[\\s"\u201c\u201d\u2018\u2019]+\$'), '');
        title = title.replaceAll(RegExp(r'^(标题|Title)\s*[:：]\s*'), '');
        title = title.trim();
        if (title.isEmpty || title.length > 40) return;
        // 用户已手动改过标题 → 不覆盖
        if (widget.conversation.title != expected) return;
        final storage = context.read<StorageService>();
        await storage.updateConversationTitle(convId, title);
        if (!mounted) return;
        widget.conversation.title = title;
        setState(() {});
      } catch (_) {
        // 静默失败：标题保持首轮截断结果
      }
    }());
  }

  int _computeRetryVersionIndex(ChatMessage msg) {
    if (msg.role != MessageRole.assistant) return 0;
    final retryOf = _retryOfId(msg);
    if (retryOf.isEmpty) return 0;
    return _activeRetryVersionIndex[retryOf] ?? 0;
  }

  Future<void> _switchRetryVersion(
      ChatMessage currentMsg, int direction) async {
    // build97 (P1-1)：纵深防御——流式期间禁止切版本。
    // 否则会改写 content/reasoningSteps 并 saveMessage 落库，随后被流式 chunk 覆盖（脏写+闪跳）。
    if (_isStreaming) return;
    final retryOf = _retryOfId(currentMsg);
    if (retryOf.isEmpty) return;

    final versions = _retryVersionStore[retryOf];
    if (versions == null || versions.length <= 1) return;

    final currentIdx = _activeRetryVersionIndex[retryOf] ?? versions.length;
    final newIdx = (currentIdx + direction).clamp(1, versions.length);
    if (newIdx == currentIdx) return;

    _activeRetryVersionIndex[retryOf] = newIdx;
    final target = versions[newIdx - 1];

    currentMsg.content = target.content;
    currentMsg.reasoningSteps
      ..clear()
      ..addAll(target.reasoningSteps);
    currentMsg.promptTokens = target.promptTokens;
    currentMsg.completionTokens = target.completionTokens;
    currentMsg.totalTokens = target.totalTokens;
    currentMsg.cacheReadTokens = target.cacheReadTokens;
    currentMsg.cacheWriteTokens = target.cacheWriteTokens;
    currentMsg.cacheHitTokens = target.cacheHitTokens;
    currentMsg.cacheMissTokens = target.cacheMissTokens;
    currentMsg.injectedWebSearchCount = target.injectedWebSearchCount;
    currentMsg.showStaleFootnote = target.showStaleFootnote;
    currentMsg.searchSources
      ..clear()
      ..addAll(target.searchSources);
    currentMsg.modelName =
        target.modelName.isNotEmpty ? target.modelName : null;

    // v1.7.26 (E3)：切换结果落库——原地切换不新建会话，若不持久化则重启后
    // 展示的 content/reasoningSteps 仍是切换前的版本，切换等于丢失。
    await context.read<StorageService>().saveMessage(currentMsg);

    if (mounted) setState(() {});
    _followBottomIfNeeded();
    _refreshContextUsage(); // 审查 B-2：版本内容长度可能差很多，刷新用量条
  }
}

/// build129（#105）：这条消息是否属于「最新一轮」——只有它才配显示编辑重发 / 重试入口。
///
/// 为什么抽成共用纯函数：同一个口径此前在**两处各写一遍**（气泡行内的 ✏️/↻ 判定、
/// 长按菜单的「编辑并重发」判定），build129 只收紧行内那处，长按菜单就漏了——
/// 用户点开老消息仍能编辑重发。口径分散就一定会漂移，这里收敛成唯一实现。
///
/// 判定成本 **O(1)**：本函数会被消息列表 builder 每个 token 调用一次，
/// 用 lastIndexWhere 之类扫列表会被放大成 O(n²)。
///
/// 口径（**与行内旧实现逐字对齐**，只收口不改变语义）：
///   用户消息：① 它是最新一条；② 或它是倒数第二条且末条是助手回复
///            （即"触发这轮回复的那条提问"）。
///   助手消息：① 它是最新一条；② 或它是倒数第二条且**末条不是**助手回复
///            —— 末条已是助手时，倒数第二条助手属历史（如连续两条助手气泡），
///            不能算最新一轮。
bool isLatestRoundMessage({
  required List<ChatMessage> msgs,
  required int index,
  required MessageRole role,
}) {
  if (index < 0 || index >= msgs.length) return false;
  if (msgs[index].role != role) return false;
  if (index == msgs.length - 1) return true;
  if (index != msgs.length - 2) return false;
  final endsWithAssistant = msgs.last.role == MessageRole.assistant;
  return role == MessageRole.user ? endsWithAssistant : !endsWithAssistant;
}

/// build138（甲3）：「只看收藏」的唯一取数口径。
///
/// 为什么又收成纯函数（与上面 isLatestRoundMessage 同一个教训）：这件事的
/// 结论会同时被**四处**读到——列表 `itemCount`、日期头、`_jumpToMessage`
/// 的落点换算、以及「已筛掉 N 条」浮层。写进 itemBuilder 里就是一处一份，
/// build129 那次「两处各写一遍就分叉了」在这里会重演一遍（而且更贵：
/// 散开后要 pump 整个 ChatScreen 才能测，界面依赖 StorageService/Provider）。
///
/// 口径：
/// - [starredOnly] false ⇒ **原样返回入参**（同一引用，不复制不重排）——
///   没开筛选时与 build137 逐字等价，零开销；
/// - true ⇒ 只留 id 命中 [starredIds] 的消息，顺序按 `msgs` 走。
///   ⚠️ 绝不能按 `starredIds`（Set）迭代：那是收藏序，会把对话打乱；
/// - 空集/空表都安全返回空表。最新一轮没被收藏时它**就是不出现**，
///   渲染层靠"可见表"判长度、靠主表下标问 isLatestRoundMessage，
///   所以少几条既不会越界也不会错渲（用例见 test/build138_starred_filter_test.dart）。
List<ChatMessage> applyStarredFilter(
  List<ChatMessage> msgs,
  Set<String> starredIds, {
  required bool starredOnly,
}) {
  if (!starredOnly) return msgs;
  if (msgs.isEmpty || starredIds.isEmpty) return const [];
  return msgs.where((m) => starredIds.contains(m.id)).toList();
}

/// build138（甲3）：开筛选时被藏起来的条数（浮层文案里的 N）。
///
/// 单独成函数只为可测；口径必须与 [applyStarredFilter] 同源，
/// 否则「已筛掉 N 条」会和用户实际看到的差值不符（比 N 写错更糟的是不可信）。
int starredHiddenCount(List<ChatMessage> msgs, Set<String> starredIds) =>
    msgs.length - applyStarredFilter(msgs, starredIds, starredOnly: true).length;

// ═══════════════ build148（真机反馈②）：发送前探活的重试与分级文案 ═══════════════

/// 探活最多试几次（含第一次）。**1 = 回到旧行为**（一次超时就问用户）。
const int kApiProbeAttempts = 2;

/// 第一次的等待。刻意比旧的 10s 宽一点、又比真发送的 60s 窄很多：
/// 探活是 `stream:false` 的整包请求，慢中转上 10s 常常是"它其实活着"。
const Duration kApiProbeTimeout = Duration(seconds: 12);

/// 两次尝试之间的等待（秒级退避，不给故障上游雪上加霜）。
const Duration kApiProbeRetryWait = Duration(seconds: 2);

/// 这把错误是不是**配置类**（鉴权失败 / 额度 / 模型不存在 / 没填 Key）。
/// 配置类重试没有意义（再试三次也是 401），而且每试一次都是真发一发请求 ⇒ 直接报错。
/// 判据复用 [fatalConfigErrorKind]（全仓唯一一份），不在这里再造第二套字符串匹配。
bool isProbeFatalConfigError(Object e) =>
    fatalConfigErrorKind(e, isZh: true) != null;

/// 探活失败给用户看的那句**人话**（内部异常串降级成第二行小字，供导出日志核对）。
///
/// 旧写法是把 `e.toString()` 直接当正文 ⇒ 用户读到的是
/// 「TimeoutException after 0:00:10.000000: Future not completed」，
/// 既不知道该怎么办，也分不出"网络不通"和"Key 坏了"（后者的正确动作是去改设置，
/// 不是点"仍然发送"）。
String describeApiProbeFailure(Object e, {required bool isZh}) {
  final config = fatalConfigErrorKind(e, isZh: isZh);
  if (config != null) return config;
  final s = e.toString();
  final lower = s.toLowerCase();
  if (lower.contains('timeoutexception') ||
      s.contains('超时') ||
      s.contains('Timeout')) {
    return isZh
        ? '连接超时：服务器在限定时间内没有响应（常见于中转较慢或线路被干扰）。'
        : 'Connection timed out — the server did not respond in time (often a slow relay or an interrupted route).';
  }
  if (s.contains('SocketException') ||
      lower.contains('failed host lookup') ||
      lower.contains('network is unreachable')) {
    return isZh
        ? '网络不通或域名解析失败，请检查这台设备的联网状态。'
        : 'Network unreachable or DNS lookup failed — check this device’s connection.';
  }
  final http5xx = RegExp(r'HTTP 5\d\d').hasMatch(s);
  if (http5xx || lower.contains('network error') || lower.contains('http error')) {
    return isZh
        ? '服务器暂时不可用（上游返回了错误）。'
        : 'The server is temporarily unavailable (upstream error).';
  }
  return isZh ? '无法连接到 API 服务器。' : 'Cannot connect to the API server.';
}

// ═══════════════ build164（#84）：撤回/删除要留痕（只加日志，不动撤回语义） ═══════════════
//
// 真机 1.7.106+163 的两份新导出里，`rollback` / 撤回 / 删除 **全 0 命中**
// （`docs/BUGSCAN_build164_20260925.md` ⑥）。用户问的是「撤回了，你还能看到吗？」——
// 而现在连"撤了没有、撤了哪几条、各多少字"都看不到。
// 撤回走 `_stopAndRollback` → `_rollbackMessage`，把本轮提问 + 回答**一起从库里删**，
// 比一次普通发送还安静：发送有 `POST …`、有 `[Timing]`、有落库，撤什么也没有。
//
// 下面这几个纯函数只**拼那一行**：
//  · 不判语义（撤回到底是删除还是标记，是待决项 #74，本批一个字不动）；
//  · 不碰正文 —— 只带字数。日志会被导出、被分享，正文进日志等于把"删掉"变成"复制一份"；
//  · 在 flutter_test 里可直接调（`chat_screen.dart` 这份库已被
//    `test/build129_latest_round_test.dart` / `build138_starred_filter_test.dart` 导入过，
//    走的是同一批纯函数），不需要平台通道。

/// 被删掉的**一条**消息在日志里留下的最小事实：角色 + id + 正文字数。
///
/// [chars] 是 `content.length`（Dart 字符数，不是字节）——这一行的用途是
/// "对得上字数"，不是还原内容，所以不必换成字节口径。
class DeletedMsgFact {
  final String role;
  final String id;
  final int chars;

  const DeletedMsgFact({
    required this.role,
    required this.id,
    required this.chars,
  });

  /// 从一条真实消息取那三项（纯取值，不做任何判断）。
  ///
  /// 角色串取 `MessageRoleExtension.value`（库里唯一那份角色口径，
  /// DB 序列化也走它）；`role.name` 会给出同样的字符串，但那是第二份口径（教训 #62）。
  factory DeletedMsgFact.of(ChatMessage m) =>
      DeletedMsgFact(role: m.role.value, id: m.id, chars: m.content.length);

  /// `user#a1b2c3(1203字)` —— id 打全，便于拿它去对 `saveMessage id=` 那些行。
  String toDetail() => '$role#$id($chars字)';
}

/// 明细最多列几条（撤回会级联删一整串，一串几十个 id 糊在一行里等于没写）。
const int kDeletedMsgDetailCap = 6;

/// VERBOSE 开关开着时，ReAct 那行 `Round N raw response` 实际存下来的**字数上限**。
///
/// ⚠️ 这个数字的**源头在 `chat_screen_react.dart`** 那句
/// `rawResp.substring(0, rawResp.length > 500 ? 500 : ...)`，这里只是它的口径副本：
/// 那个文件归本轮另一位同事（#82），这次没去改成共享常量。
/// **谁改了那 500，就必须同步改这里**，否则"能不能追回"会说出反话。
const int kVerboseRawResponseCap = 500;

/// 「撤掉的内容还能不能从日志里追回」这一项的措辞（三态，别写成一句保证）。
///
/// 确定的只有两件事：① 这一行本身不含正文；② 只有 VERBOSE 开着时
/// ReAct 才会写那句 `raw response`，而且**最多前 [kVerboseRawResponseCap] 字**。
/// 除此之外一律说"追不回"——做不到就明说，不编（本仓红线：不许把"我不知道"
/// 压成假事实，也不许反过来把"也许有"说成"一定在"）。
String deletedContentRecoverNote({
  required int totalChars,
  required bool verboseEnabled,
}) {
  if (!verboseEnabled) {
    return '否（VERBOSE 未开：正文一个字都没进过日志，$totalChars 字已随删除消失）';
  }
  if (totalChars <= kVerboseRawResponseCap) {
    return '仅疑似可追（VERBOSE 已开：本轮 raw response 存前 $kVerboseRawResponseCap 字，'
        '$totalChars字在范围内；但那是模型原文、不是删掉的正文本体）';
  }
  return '否（VERBOSE 已开，但 raw response 那行只存前 $kVerboseRawResponseCap 字，'
      '$totalChars字超出部分日志里没有）';
}

/// 撤回 / 单条删除那一行的日志正文（**纯函数**，可单测）。
///
/// 一行要能回答用户那两句「撤回了，你还能看到吗？」：
/// 撤了什么（角色 + id + 字数）、有没有连提问一起撤、还能不能追回。
///
/// [skippedBecause] 非空 = 用户按了但**一条都没删**（例如流没在 3 秒内停下、
/// `_rollbackMessage` 被 `_isStreaming` 挡住）。那种"点了没反应"过去是完全静默的，
/// 正是 #74 到现在还定不下性的原因之一 ⇒ 也必须有一行。
String describeMessageDeletionForLog({
  required String action,
  required List<DeletedMsgFact> deleted,
  required bool verboseEnabled,
  int? startIndex,
  String? skippedBecause,
}) {
  final total = deleted.fold<int>(0, (sum, e) => sum + e.chars);
  final withUser = deleted.any((e) => e.role == 'user');
  final detail = deleted.length <= kDeletedMsgDetailCap
      ? deleted.map((e) => e.toDetail()).join(' ')
      : '${deleted.take(kDeletedMsgDetailCap).map((e) => e.toDetail()).join(' ')} '
          '…另 ${deleted.length - kDeletedMsgDetailCap} 条';
  final posNote =
      startIndex == null || startIndex < 0 ? '' : ' 起始下标=$startIndex';
  if (skippedBecause != null) {
    return '$action: 未删除任何条目 原因=$skippedBecause$posNote';
  }
  return '$action: 共 ${deleted.length} 条$posNote 连提问=${withUser ? '是' : '否'} '
      '正文合计=$total 字 明细=[$detail] '
      '可追回=${deletedContentRecoverNote(totalChars: total, verboseEnabled: verboseEnabled)}';
}
