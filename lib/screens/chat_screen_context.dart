// part 文件通过 extension 访问宿主 _ChatScreenState 的受保护成员 setState，
// 属 part-of + extension 拆分架构的固有模式，统一豁免。
// ignore_for_file: invalid_use_of_protected_member, library_private_types_in_public_api
part of 'chat_screen.dart';

extension ChatScreenContextExt on _ChatScreenState {
  /// v1.7.37（⑱）：估算当前上下文用量并刷新用量条。
  /// 与 ContextBudgetService.select 口径近似：被压缩段覆盖的消息按摘要估算，
  /// 未覆盖消息按原文估算；预算 = Max 开 1M / 关取 config.contextWindowTokens（默认 200K）。
  void _refreshContextUsage() {
    if (!mounted) return;
    // 审查 B-3：会话内可能临时切换模型，预算须与会话模型口径一致
    final cfg = _currentSessionModel ?? _apiConfig;
    final budget = widget.conversation.largeContextMax
        ? ContextBudgetService.maxContextTokens
        : (cfg?.contextWindowTokens ??
            ContextBudgetService.defaultContextTokens);
    final covered = <String>{};
    // 审查 B-4：与 _normalizeSegments 对齐——锚点失效（start/end 找不到）的段
    // 整条忽略（不覆盖、摘要 tokens 也不计入），避免双重计数系统性高估
    final validSegs = <ContextCompactionSegment>[];
    for (final seg in _compactionSegments) {
      final start = _messages.indexWhere((m) => m.id == seg.startMessageId);
      final end = _messages.indexWhere((m) => m.id == seg.endMessageId);
      if (start < 0 || end < start) continue;
      validSegs.add(seg);
      for (var i = start; i <= end; i++) {
        covered.add(_messages[i].id);
      }
    }
    var used = 0;
    for (final m in _messages) {
      if (!covered.contains(m.id)) used += ApiServiceTokenEstimate.message(m);
    }
    for (final seg in validSegs) {
      used += ApiServiceTokenEstimate.text(seg.summary);
    }
    setState(() {
      _contextUsedTokens = used;
      _contextBudgetTokens = budget;
    });
  }

  /// build103（I9）：上下文容量面板（对标 Trae，第 4 项立项落地）——用量条点开的
  /// 底部弹层：①总量/预算（本地估算 content/2.5，标注「估算」）②分类占比
  /// （用户消息/AI 回复/压缩摘要；附件与 OCR 文本计入所在消息，工具 Schema/
  /// 系统提示词/搜索结果按轮动态注入暂未单列）③会话级平均缓存命中率
  /// （两族字段口径：DeepSeek 族 hit÷(hit+miss)；通用族 read÷prompt）。
  Future<void> _showContextCapacityPanel() async {
    if (!mounted) return;
    if (!GuardedOverlay.tryEnter('ctx_sheet')) {
      // 诊断（build127）：守卫被长期占用 ⇒ 上一次打开未释放，用户侧表现就是
      // 「点了没反应」。若本行反复出现而下面的「已关闭」从未出现，即坐实泄漏点。
      _logger.warn('上下文容量面板被守卫拦下：ctx_sheet 仍被占用（疑似上次未释放）',
          tag: 'ctx_sheet');
      return;
    }
    _logger.info('打开上下文容量面板', cat: LogCat.ui, tag: 'ctx_sheet');
    try {
      return await _showCtxSheetInner();
    } finally {
      _logger.info('上下文容量面板关闭，释放守卫', cat: LogCat.ui, tag: 'ctx_sheet');
      GuardedOverlay.exit('ctx_sheet');
    }
  }

  Future<void> _showCtxSheetInner() async {
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    final budget = _contextBudgetTokens <= 0
        ? ContextBudgetService.defaultContextTokens
        : _contextBudgetTokens;
    final ratio = (_contextUsedTokens / budget).clamp(0.0, 1.0);
    // 数值格式统一走 UsageStat.fmtTokens（与顶部用量条、统计页同一份实现）——
    // 原先这里各有一份本地 fmt，<1M 一律按 K 显示，于是 900 会写成「0.9K」。

    // —— 分类占比（覆盖口径与 _refreshContextUsage 严格一致，防双重计数） ——
    final covered = <String>{};
    var summaryTokens = 0;
    for (final seg in _compactionSegments) {
      final start = _messages.indexWhere((m) => m.id == seg.startMessageId);
      final end = _messages.indexWhere((m) => m.id == seg.endMessageId);
      if (start < 0 || end < start) continue;
      for (var i = start; i <= end; i++) {
        covered.add(_messages[i].id);
      }
      summaryTokens += ApiServiceTokenEstimate.text(seg.summary);
    }
    var userTokens = 0;
    var assistantTokens = 0;
    for (final m in _messages) {
      if (covered.contains(m.id)) continue;
      if (m.role == MessageRole.user) {
        userTokens += ApiServiceTokenEstimate.message(m);
      } else if (m.role == MessageRole.assistant) {
        assistantTokens += ApiServiceTokenEstimate.message(m);
      }
    }

    // —— 会话级缓存命中率（仅统计 assistant 消息的 usage 字段） ——
    var cacheHit = 0, cacheMiss = 0, cacheRead = 0, promptSum = 0;
    for (final m in _messages) {
      if (m.role != MessageRole.assistant) continue;
      cacheHit += m.cacheHitTokens ?? 0;
      cacheMiss += m.cacheMissTokens ?? 0;
      cacheRead += m.cacheReadTokens ?? 0;
      promptSum += m.promptTokens ?? 0;
    }
    final dsBase = cacheHit + cacheMiss;
    final dsRate = dsBase > 0 ? cacheHit / dsBase : null;
    final genericRate =
        (cacheRead > 0 && promptSum > 0) ? cacheRead / promptSum : null;

    if (!mounted) return;
    // build126 (B2)：裸 showModalBottomSheet → 统一入口 showAppSheet。
    // 原先这里自己写 SafeArea + SingleChildScrollView + fromLTRB(20,4,20,20)，
    // 圆角/拖拽手柄/最大高度/入场动画都跟别处弹层各说各话；现统一由 AppSheet 提供。
    await showAppSheet<void>(
      context: context,
      scrollable: true,
      builder: (sheetCtx) {
        final tt = Theme.of(sheetCtx).textTheme;
        final scs = Theme.of(sheetCtx).colorScheme;
        final usedText = UsageStat.fmtTokens(_contextUsedTokens);
        final budgetText = UsageStat.fmtTokens(budget);
        final pctText = '${(ratio * 100).toStringAsFixed(1)}%';
        // 两色制，与顶部用量条同一判据（同一个 contextUsageLevel），
        // 避免同一条数据两处颜色不同。
        final level = contextUsageLevel(ratio);
        final barColor =
            level == ContextUsageLevel.normal ? scs.primary : scs.error;

        /// 一条占比：标签 + 数值 + 该分类自己的比例条。
        /// 原先只有「标签 —— 12.3K · 6.1%」两段文字，读不出谁占大头；
        /// 加条子后分类之间的量级差一眼可见。
        Widget row(String label, int tokens) {
          final r = budget <= 0 ? 0.0 : (tokens / budget).clamp(0.0, 1.0);
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: AppGap.xs),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(label, style: tt.bodyMedium)),
                    Text(
                      '${UsageStat.fmtTokens(tokens)} · '
                      '${(r * 100).toStringAsFixed(1)}%',
                      style: tt.bodySmall?.copyWith(color: scs.appTextSub),
                    ),
                  ],
                ),
                const SizedBox(height: AppGap.xs),
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.inline),
                  child: LinearProgressIndicator(
                    value: r,
                    minHeight: 4,
                    backgroundColor: scs.surfaceContainerHighest,
                    valueColor: AlwaysStoppedAnimation<Color>(scs.primary),
                  ),
                ),
              ],
            ),
          );
        }

        Widget caption(String text) =>
            Text(text, style: tt.bodySmall?.copyWith(color: scs.appTextFaint));

        // showAppSheet 自身只负责圆角/手柄/安全区，**不提供滚动** ——
        // 长内容必须由调用方用 Flexible + SingleChildScrollView 兜住，
        // 否则超一屏会直接 RenderFlex 溢出（原实现自带 SingleChildScrollView）。
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 总量/占比进副标题，正文让给「大号百分比 + 条子」：
            // 一眼读出用掉多少，不必先读一行小字再自己换算。
            AppSheetHeader(
              title: isZh ? '上下文容量' : 'Context capacity',
              subtitle: '$usedText / $budgetText · $pctText'
                  '${isZh ? '（本地估算）' : ' (estimated)'}',
            ),
            Flexible(
              child: SingleChildScrollView(
                // build128 修回归：build126（B2）迁到 showAppSheet 时把原来自己写的
                // `fromLTRB(20,4,20,20)` 一并丢了，而 showAppSheet 只提供圆角/手柄/
                // 安全区、**不含水平内边距** ⇒ 正文贴屏幕左右缘被裁。AppSheetHeader
                // 自带边距，所以只有正文看得出错位（真机截图坐实）。
                // 补齐 `AppGap.lg`，与「编辑标题」「对话设置」两处写法保持一致。
                padding: const EdgeInsets.symmetric(horizontal: AppGap.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ① 总览：大号百分比 + 占用条（文字兜底，不靠颜色单独表意）
                    Text(
                      pctText,
                      style: tt.headlineSmall?.copyWith(
                        color: barColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: AppGap.sm),
                    ClipRRect(
                      // R3：不再散落裸数字。进度条高 6，取 inline(6) 会被 Flutter
                      // 按半高钳制成 3 —— 与原来的 circular(3) 视觉完全一致。
                      borderRadius: BorderRadius.circular(AppRadius.inline),
                      child: LinearProgressIndicator(
                        value: ratio,
                        minHeight: 6,
                        backgroundColor: scs.surfaceContainerHighest,
                        valueColor: AlwaysStoppedAnimation<Color>(barColor),
                      ),
                    ),
                    if (level != ContextUsageLevel.normal) ...[
                      const SizedBox(height: AppGap.sm),
                      Text(
                        level == ContextUsageLevel.atLimit
                            ? (isZh
                                ? '已达上限 · 即将自动压缩'
                                : 'At limit · auto-compaction imminent')
                            : (isZh
                                ? '接近上限 · 自动压缩阈值 '
                                    '${(kContextNearLimitRatio * 100).toStringAsFixed(0)}%'
                                : 'Near limit · auto-compaction at '
                                    '${(kContextNearLimitRatio * 100).toStringAsFixed(0)}%'),
                        style: tt.bodySmall?.copyWith(
                          color: scs.error,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    const SizedBox(height: AppGap.lg),

                    // ② 分类占比
                    AppSectionCard(
                      title: isZh ? '分类占比（估算）' : 'Breakdown (estimated)',
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: AppGap.md, vertical: AppGap.xs),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              row(isZh ? '用户消息' : 'User messages', userTokens),
                              row(isZh ? 'AI 回复' : 'AI replies',
                                  assistantTokens),
                              row(isZh ? '压缩摘要' : 'Compaction summaries',
                                  summaryTokens),
                              const SizedBox(height: AppGap.sm),
                              caption(isZh
                                  ? '附件/OCR 文本计入所在消息；工具 Schema、系统提示词、搜索结果为按轮动态注入，暂未单列。'
                                  : 'Attachment/OCR text counts toward its message; tool schemas, system prompts and search results are injected per turn and not itemized yet.'),
                            ],
                          ),
                        ),
                      ],
                    ),

                    // ③ 会话级缓存命中率
                    AppSectionCard(
                      title: isZh
                          ? '会话平均缓存命中率'
                          : 'Session cache hit rate',
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: AppGap.md, vertical: AppGap.xs),
                          child: dsRate != null
                              ? Text(
                                  isZh
                                      ? 'DeepSeek 族（hit/miss）：${(dsRate * 100).toStringAsFixed(1)}%  ·  命中 ${UsageStat.fmtTokens(cacheHit)} / 共 ${UsageStat.fmtTokens(dsBase)}'
                                      : 'DeepSeek family (hit/miss): ${(dsRate * 100).toStringAsFixed(1)}%  ·  ${UsageStat.fmtTokens(cacheHit)} / ${UsageStat.fmtTokens(dsBase)}',
                                  style: tt.bodyMedium,
                                )
                              : genericRate != null
                                  ? Text(
                                      isZh
                                          ? '通用族（cache_read/prompt）：${(genericRate * 100).toStringAsFixed(1)}%  ·  读 ${UsageStat.fmtTokens(cacheRead)} / 输入 ${UsageStat.fmtTokens(promptSum)}'
                                          : 'Generic (cache_read/prompt): ${(genericRate * 100).toStringAsFixed(1)}%  ·  ${UsageStat.fmtTokens(cacheRead)} / ${UsageStat.fmtTokens(promptSum)}',
                                      style: tt.bodyMedium,
                                    )
                                  : caption(isZh
                                      ? '暂无数据——需模型返回缓存字段（DeepSeek prompt_cache_hit/miss 或通用 cache_read）。'
                                      : 'No data yet — the model must return cache fields (DeepSeek prompt_cache_hit/miss or generic cache_read).'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // v1.7.34：子代理模式的中英标签
  // build146：标签只是**档位名**，不承诺行为（"自动"不再暗示编排）；
  // 每一档真正做什么写在下面 _subagentModeHint 里，二者不许互相打架。
  String _subagentModeLabel(String mode, bool isZh) {
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

  String _subagentModeHint(String mode, bool isZh) {
    // build146（子代理：路由不再单独花钱）：文案必须对上**真实落点**——
    // 判据只有一个入口（services 层 subagentModeUsesOrchestrator +
    // effectiveSubagentMode），这里的每一句都要能在那两个函数里对上号。
    // 旧文案最大的问题是「自动」暗示会编排：实际上编排器每次都要先付一次
    // 非流式 LLM 路由调用（30s 超时），说 self 之后还要再付一次合成调用才出正文，
    // 普通聊天因此双倍首字延迟 ⇒ 现在 auto 直接归自主思考循环。
    switch (mode) {
      case 'auto':
        return isZh
            ? '主代理每轮自己决定要不要检索或调插件（自主思考循环），不再单独花一次路由调用'
            : 'The main agent decides each turn whether to search or call a plugin (thinking loop) — no separate routing call';
      case 'main_only':
        return isZh
            ? '只用主代理的自主思考循环，不派专家；与「自动」当前落到同一条路（深度研究时同样升为强制检索）'
            : 'Main agent thinking loop only, no experts — currently the same destination as Auto (deep research still upgrades to forced search)';
      case 'force_search':
        return isZh
            ? '强制子代理取证：先联网检索再综合作答，跳过路由判断（适合「最新/热榜」类问题）'
            : 'Force the sub-agent: web search first, then answer (router call skipped; good for "latest/hot" questions)';
      case 'force_synthesis':
        return isZh
            ? '强制子代理综合：以结构化分析为主；本轮无资料时先联网取证，未启用联网则在步骤里写明「未经检索」'
            : 'Force the sub-agent: structured analysis first; it searches when there is no evidence, and states "not searched" in the steps when web search is off';
      case 'force_plugin':
        return isZh
            ? '强制走插件：交给自主思考循环直接调用已安装插件（MCP / 内置）——插件只有它能执行'
            : 'Force plugin: hand to the thinking loop to call installed plugins (MCP / built-in) — only it can execute them';
      default:
        return '';
    }
  }

  ApiConfig get _conversationApiConfig {
    final base = (_currentSessionModel ?? _apiConfig)!;
    return base.copyWith(
      name: base.name,
      model: base.model,
      baseUrl: base.baseUrl,
      apiKey: base.apiKey,
      systemPrompt: base.systemPrompt,
      maxTokens: base.maxTokens,
      temperature: widget.conversation.temperature,
      topP: widget.conversation.topP,
    );
  }

  /// build129：选一个「生成模型」（图片 / 视频共用）。
  ///
  /// 返回：选中的模型名；`''` = 用户显式选择「跟随对话模型」；`null` = 取消（调用方忽略）。
  /// 候选顺序：上游 400 里点名的可用模型（最准）→ 已拉取的模型列表 → 内置预设；
  /// 输入框可直接手输——中转站模型名层出不穷，纯下拉一定不够用。
  Future<String?> _pickGenModel({
    required bool isVideo,
    required String current,
    required bool isZh,
  }) async {
    final upstream = isVideo
        ? VideoGenService.lastUpstreamSuggestedVideoModels
        : ImageGenService.lastUpstreamSuggestedModels;
    final cached = _conversationApiConfig.cachedModelsList;
    const imagePresets = <String>[
      'gpt-image-1',
      'dall-e-3',
      'grok-imagine-image',
      'flux-schnell',
      'doubao-seedream',
    ];
    const videoPresets = <String>[
      'grok-imagine-video',
      'kling-video-o1',
      'sora-2',
      'veo-3',
      'doubao-seedance',
    ];
    final presets = isVideo ? videoPresets : imagePresets;
    final picks = <String>[
      ...upstream,
      ...cached.where((m) => !upstream.contains(m)),
      ...presets.where((m) => !upstream.contains(m) && !cached.contains(m)),
    ];
    final controller = TextEditingController(text: current);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isVideo
            ? (isZh ? '选择视频模型' : 'Pick a video model')
            : (isZh ? '选择图片模型' : 'Pick an image model')),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                decoration: InputDecoration(
                  isDense: true,
                  labelText: isZh ? '模型名（可直接手输）' : 'Model name',
                  hintText: isVideo ? 'grok-imagine-video' : 'gpt-image-1',
                ),
              ),
              const SizedBox(height: 10),
              // 固定最大高度而非 Flexible：AlertDialog 内容区高度不可控，
              // min-size Column 里塞 Flexible + shrinkWrap 列表在矮屏上会溢出。
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        isZh
                            ? '跟随对话模型（多数中转会报 400）'
                            : 'Follow the chat model (usually 400)',
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing: current.isEmpty
                          ? const Icon(Icons.check, size: 16)
                          : null,
                      onTap: () => Navigator.pop(ctx, ''),
                    ),
                    for (final m in picks)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(m, style: const TextStyle(fontSize: 13)),
                        trailing:
                            m == current ? const Icon(Icons.check, size: 16) : null,
                        onTap: () => Navigator.pop(ctx, m),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(isZh ? '取消' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(isZh ? '用输入框的值' : 'Use typed value'),
          ),
        ],
      ),
    ).whenComplete(controller.dispose); // 控制器须显式释放（同 §3 约定）
    return result;
  }

  /// build129：对话设置里的一行「生成模型」。
  ///
  /// 为什么显示在对话设置里、却写回 API 配置：模型名必须与 baseUrl/apiKey 同源，
  /// 若做成会话级字段，会出现「这个会话选了 A 站的模型、却用 B 站的 key」的错配。
  /// 所以这里定位为「配置的快捷入口」，与「API 配置」页那两行是同一份数据。
  Widget _buildGenModelRow({
    required bool isZh,
    required bool isVideo,
    required String current,
    required VoidCallback onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    final label = isVideo
        ? (isZh ? '视频模型' : 'Video model')
        : (isZh ? '图片模型' : 'Image model');
    final value =
        current.isEmpty ? (isZh ? '跟随对话模型' : 'Follow chat model') : current;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(isVideo ? Icons.movie_outlined : Icons.image_outlined,
                size: 18, color: cs.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(fontSize: 13)),
                  Text(
                    value,
                    style: TextStyle(
                      fontSize: 11,
                      color: current.isEmpty ? cs.error : cs.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  Future<void> _editConversationTitle() async {
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    final controller = TextEditingController(text: widget.conversation.title);
    // build126 (B2)：AlertDialog → 底部弹层。keyboardAware 必须开——
    // 弹层从底部升起，不按键盘高度让位会直接盖住「保存」按钮。
    final result = await showAppSheet<String>(
      context: context,
      keyboardAware: true,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppSheetHeader(title: isZh ? '编辑标题' : 'Edit Title'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppGap.lg),
            child: TextField(
              controller: controller,
              maxLength: 50,
              autofocus: true,
              decoration: InputDecoration(
                hintText: isZh ? '输入对话标题' : 'Enter conversation title',
              ),
            ),
          ),
          AppSheetActions(children: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(isZh ? '取消' : 'Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: Text(isZh ? '保存' : 'Save'),
            ),
          ]),
        ],
      ),
    ).whenComplete(controller.dispose); // P3：弹层控制器须显式释放（同 §3）
    if (result != null &&
        result.isNotEmpty &&
        result != widget.conversation.title) {
      // ① showAppSheet 本身也是一次 async gap，下面要用 context → 先校验一次。
      //    这一条同时满足 use_build_context_synchronously 的约束。
      if (!mounted) return;
      widget.conversation.title = result;
      await context
          .read<StorageService>()
          .updateConversationTitle(widget.conversation.id, result);
      // ② 落库是第二个 async gap。
      //    全量缺陷扫描修复：此前**只有**上面①那一处校验，覆盖不到这里 ——
      //    在 updateConversationTitle 落库期间返回/切页后，这里的 setState 会抛
      //    Flutter 的「在 dispose 之后调用刷新方法」异常。
      //    注意 use_build_context_synchronously 只约束 context、**不约束 setState**，
      //    所以这个漏网不会被 lint 发现，只能显式补上。
      if (!mounted) return;
      setState(() {});
    }
  }

  Future<void> _showConversationSettings() async {
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    double temperature = widget.conversation.temperature;
    double topP = widget.conversation.topP;
    bool enable20sCheck = widget.conversation.enable20sCheck;
    bool autoCompress = widget.conversation.autoCompress;
    // build138（乙·方案①）：条数上限此前是死字段（零读取点），现已接进
    // context_budget_service.select 的唯一选史口径 ⇒ 这里的开关拨动真的会生效。
    bool contextAuto = widget.conversation.contextAuto;
    int contextLimit = widget.conversation.contextLimit;
    // v1.7.37：更大上下文 Max 挪入 🧠 思考强度弹层（此处只读，用于互斥置灰）
    final largeContextMax = widget.conversation.largeContextMax;
    // v1.7.25：思考相关（每对话独有）
    bool reactEnabled = widget.conversation.reactEnabled;
    bool reactAutoMode = widget.conversation.reactAutoMode;
    int reactMaxRounds = widget.conversation.reactMaxRounds;
    double reasoningEffort = widget.conversation.reasoningEffort;
    // v1.7.34：跨对话记忆 + 子代理模式（深度研究开关已并入思考强度 1.0 档，v1.7.37）
    bool memoryEnabled = widget.conversation.memoryEnabled;
    // build94 (D3)：长期记忆独立开关
    bool longTermMemoryEnabled = widget.conversation.longTermMemoryEnabled;
    // build101（C1）：本会话绑定的知识库 id
    String knowledgeBaseId = widget.conversation.knowledgeBaseId;
    // build101（E8）：本会话绑定的助手 id
    String assistantId = widget.conversation.assistantId;
    String subagentMode = widget.conversation.subagentMode;
    // build90 ⑧：所属项目（空 = 无项目）
    final projects = await _storage.loadProjects();
    if (!mounted) return;
    String projectId = widget.conversation.projectId;

    // build129：生成模型（用户口径：「在对话里直接选生图/生视频用的模型」）。
    // 取值来源 = 该会话所用的 API 配置；保存时写回配置本身（见面板尾部 saveApiConfig）。
    final genConfig = _conversationApiConfig;
    String genImageModel = genConfig.imageModel.trim();
    String genVideoModel = genConfig.videoModel.trim();

    // B-018：记忆注入预览的 future 提到 showDialog 之前**只算一次**。
    // 此前它直接写在 StatefulBuilder 内部 —— 每次 setDialogState（拖温度/思考
    // 强度滑块会连续触发几十次）都重建 FutureBuilder、重跑一遍「读全局+项目记忆
    // 两张表」，低端机上拖滑块明显掉帧。切项目时在 Dropdown 回调里显式重建。
    var memFuture = MemoryBlockBuilder.buildParts(projectId);

    // build126 (B2)：AlertDialog → 底部弹层（scrollable：内容远超一屏）。
    // StatefulBuilder + setDialogState **原样保留** —— 弹层内同样靠它重建
    // 滑块/开关，交互语义与对话框时期完全一致，只是容器换了。
    final saved = await showAppSheet<bool>(
      context: context,
      scrollable: true,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppSheetHeader(title: isZh ? '对话设置' : 'Chat Settings'),
            // Flexible：内容区吃掉剩余高度并可滚，标题/操作行常驻不被挤走
            Flexible(
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppGap.lg),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isZh
                            ? '上下文预算：默认约 200K tokens；输入框 🧠 面板可开启「更大上下文 Max」（约 1M）'
                            : 'Context budget: ~200K tokens by default; enable "Larger context Max" (~1M) in the 🧠 panel',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(isZh ? '自动压缩' : 'Auto compress'),
                        subtitle: Text(largeContextMax
                            ? (isZh
                                ? '更大上下文 Max 开启时不可用（在 🧠 面板关闭 Max 后可调）'
                                : 'Unavailable while Larger context Max is on (turn it off in the 🧠 panel first)')
                            : (isZh
                                ? '接近上下文预算时自动生成并持久化摘要；原始消息仍保留'
                                : 'Persist a summary when the context approaches its budget; original messages remain available')),
                        value: autoCompress,
                        // v1.7.37：Max×自动压缩互斥——开 Max 时置灰不可点
                        onChanged: largeContextMax
                            ? null
                            : (value) =>
                                setDialogState(() => autoCompress = value),
                      ),
                      // build138（乙·方案①）：conversation.dart 的 contextLimit /
                      // contextAuto 两列从建表起就没有任何读取点（第 6 次踩
                      // 「看起来已经接好了」那一族）。消费端已在
                      // context_budget_service.select 接好：手动档取「条数」与
                      // 「token 预算」更严的一侧，自动档（默认）完全不看条数，
                      // 所以老用户与未动过这个开关的用户行为零变化。
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                            isZh ? '按条数限制上下文' : 'Limit context by count'),
                        subtitle: Text(contextAuto
                            ? (isZh
                                ? '自动（默认）：只按 token 预算取历史，不看条数'
                                : 'Auto (default): history follows the token budget only')
                            : (isZh
                                ? '手动：最多带最近 $contextLimit 条历史，与 token 预算取更严的一侧'
                                : 'Manual: at most the latest $contextLimit messages, stricter of count and budget')),
                        value: !contextAuto,
                        onChanged: (value) =>
                            setDialogState(() => contextAuto = !value),
                      ),
                      if (!contextAuto) ...[
                        Text(
                          isZh
                              ? '历史条数上限：$contextLimit 条'
                              : 'History limit: $contextLimit messages',
                          style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant),
                        ),
                        Slider(
                          value: contextLimit.toDouble().clamp(1, 100),
                          min: 1,
                          max: 100,
                          divisions: 99,
                          onChanged: (v) =>
                              setDialogState(() => contextLimit = v.round()),
                        ),
                      ],
                      // ===== v1.7.25：思考相关（每对话独有，原全局 ReAct 页已删）=====
                      const Divider(height: 20),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(isZh
                            ? '自主思考 (ReAct)'
                            : 'Autonomous thinking (ReAct)'),
                        subtitle: Text(isZh
                            ? 'AI 自主多轮思考后给出答复'
                            : 'AI thinks over multiple rounds before answering'),
                        value: reactEnabled,
                        onChanged: (v) =>
                            setDialogState(() => reactEnabled = v),
                      ),
                      if (reactEnabled) ...[
                        Text(
                          isZh ? '思考程度（轮数）：' : 'Thinking rounds:',
                          style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant),
                        ),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final opt in const [
                              (label: '关 Off', rounds: 0, auto: false),
                              (label: '低 Low', rounds: 2, auto: false),
                              (label: '中 Medium', rounds: 5, auto: false),
                              (label: '高 High', rounds: 8, auto: false),
                              (label: '自动 Auto', rounds: 30, auto: true),
                            ])
                              ChoiceChip(
                                showCheckmark: false,
                                label: Text(opt.label,
                                    style: const TextStyle(fontSize: 11)),
                                selected: opt.auto
                                    ? reactAutoMode
                                    : !reactAutoMode &&
                                        opt.rounds == reactMaxRounds,
                                selectedColor: Theme.of(context)
                                    .colorScheme
                                    .primary
                                    .withValues(alpha: 0.12),
                                onSelected: (_) => setDialogState(() {
                                  if (opt.auto) {
                                    reactAutoMode = true;
                                    reactMaxRounds = 30;
                                  } else {
                                    reactAutoMode = false;
                                    reactMaxRounds = opt.rounds;
                                  }
                                }),
                              ),
                          ],
                        ),
                        if (!reactAutoMode) ...[
                          Text(isZh
                              ? '自定义：$reactMaxRounds 轮'
                              : 'Custom: $reactMaxRounds rounds'),
                          Slider(
                            value: reactMaxRounds.toDouble().clamp(0, 100),
                            min: 0,
                            max: 100,
                            divisions: 100,
                            onChanged: (v) => setDialogState(
                                () => reactMaxRounds = v.round()),
                          ),
                        ],
                        const SizedBox(height: 8),
                        // 思考强度滑块：0.0–1.0 连续（0.1 步进），0=默认(自动)
                        Text(
                          isZh
                              ? '思考强度：${reasoningEffortLabel(reasoningEffort, true)}'
                              : 'Reasoning effort: ${reasoningEffortLabel(reasoningEffort, false)}',
                          style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant),
                        ),
                        Slider(
                          value: reasoningEffort.clamp(0.0, 1.0),
                          min: 0,
                          max: 1,
                          divisions: 10,
                          onChanged: (v) => setDialogState(() {
                            reasoningEffort =
                                double.parse(v.toStringAsFixed(1));
                          }),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(isZh ? '默认 0.0' : 'Default 0.0',
                                style: const TextStyle(fontSize: 11)),
                            Text(isZh ? '中 0.5' : 'Medium 0.5',
                                style: const TextStyle(fontSize: 11)),
                            Text(isZh ? '高 1.0' : 'High 1.0',
                                style: const TextStyle(fontSize: 11)),
                          ],
                        ),
                        const Divider(height: 16),
                      ],
                      Text(isZh
                          ? '温度：${temperature.toStringAsFixed(1)}'
                          : 'Temp: ${temperature.toStringAsFixed(1)}'),
                      Slider(
                        value: temperature,
                        min: 0,
                        max: 2,
                        divisions: 20,
                        onChanged: (value) =>
                            setDialogState(() => temperature = value),
                      ),
                      Text(isZh
                          ? 'Top P：${topP.toStringAsFixed(2)}'
                          : 'Top P: ${topP.toStringAsFixed(2)}'),
                      Slider(
                        value: topP,
                        min: 0.05,
                        max: 1,
                        divisions: 19,
                        onChanged: (value) =>
                            setDialogState(() => topP = value),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(isZh ? '20 秒防卡壳' : '20s anti-stall'),
                        subtitle: Text(isZh
                            ? '默认开启，每 20 秒让 AI 自检是否继续'
                            : 'On by default; AI self-checks every 20s whether to continue'),
                        value: enable20sCheck,
                        onChanged: (value) =>
                            setDialogState(() => enable20sCheck = value),
                      ),
                      // ===== v1.7.34：跨对话记忆 + 子代理编排（深度研究开关已并入 🧠 思考强度 1.0 档）=====
                      const Divider(height: 20),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(isZh ? '跨对话摘要' : 'Cross-chat summaries'),
                        subtitle: Text(isZh
                            ? '发送前把最近几条历史对话摘要拼进 system prompt，AI 记住你之前聊过什么'
                            : 'Injects recent chat summaries into system prompt so the AI remembers prior conversations'),
                        value: memoryEnabled,
                        onChanged: (value) =>
                            setDialogState(() => memoryEnabled = value),
                      ),
                      // build94 (D3)：长期记忆独立开关——此前长期记忆恒注入、
                      // 用户关「记忆」以为全关，实际全局/项目记忆还在（开关语义统一）
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(isZh ? '长期记忆' : 'Long-term memory'),
                        subtitle: Text(isZh
                            ? '注入「记忆管理」里的全局/项目记忆（AI 自动记住的偏好事实）；与上面的跨对话摘要互不影响'
                            : 'Injects global/project memories from Memory Management; independent from cross-chat summaries above'),
                        value: longTermMemoryEnabled,
                        onChanged: (value) =>
                            setDialogState(() => longTermMemoryEnabled = value),
                      ),
                      // build102（F）：记忆注入预览 —— 用户能看到 AI 实际读到的记忆内容
                      //（数据源与发送链路同源：MemoryBlockBuilder.build，读全局/项目记忆表）
                      // build103（I11）：预览分「全局记忆 / 项目记忆」两段，各自空态独立提示
                      FutureBuilder<(List<String>, List<String>)>(
                        future: memFuture,
                        builder: (ctx, snap) {
                          final globals = snap.data?.$1 ?? const <String>[];
                          final projects = snap.data?.$2 ?? const <String>[];
                          final hasProject =
                              widget.conversation.projectId.isNotEmpty;
                          Widget section(String title, String empty,
                                  List<String> items) =>
                              Container(
                                width: double.infinity,
                                margin: const EdgeInsets.only(bottom: 8),
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: Theme.of(ctx)
                                      .colorScheme
                                      .surfaceContainerHighest
                                      .withValues(alpha: 0.5),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(title,
                                        style: Theme.of(ctx)
                                            .textTheme
                                            .labelSmall
                                            ?.copyWith(
                                                fontWeight: FontWeight.w600)),
                                    const SizedBox(height: 4),
                                    Text(
                                      items.isEmpty
                                          ? empty
                                          : items.map((e) => '- $e').join('\n'),
                                      style: Theme.of(ctx).textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              );
                          return ExpansionTile(
                            // ExpansionTile 无 contentPadding 参数；tilePadding 归零对齐
                            tilePadding: EdgeInsets.zero,
                            childrenPadding:
                                const EdgeInsets.fromLTRB(0, 0, 0, 8),
                            title: Text(
                                isZh ? '记忆注入预览' : 'Memory injection preview'),
                            subtitle: Text(
                              // build132：预览必须与注入条件同源。此前预览恒定读
                              // 「全局+项目记忆」两表，不看 longTermMemoryEnabled ——
                              // 开关关着时仍显示「AI 每轮实际读到的记忆内容」，
                              // 用户看到内容在预览里，就以为 AI 读到了（实机误判来源）。
                              !longTermMemoryEnabled
                                  ? (isZh
                                      // build133：去掉 ⚠️ emoji（R1 规则：用户可见字符串禁 emoji，
                                      // 文案本身已足够明确）
                                      ? '「长期记忆」开关已关闭 —— 以下内容不会注入给 AI'
                                      : 'Long-term memory is OFF — the content below is NOT sent to the AI')
                                  : (isZh
                                      ? ((globals.isEmpty && projects.isEmpty)
                                          ? '当前没有可注入的记忆'
                                          : 'AI 每轮实际读到的记忆内容')
                                      : ((globals.isEmpty && projects.isEmpty)
                                          ? 'No memory to inject'
                                          : 'What the AI actually reads each turn')),
                            ),
                            children: [
                              section(
                                isZh ? '【全局记忆】' : '[Global memory]',
                                isZh
                                    ? '（无全局记忆——去「设置 → 记忆管理」添加，或长按消息选「保存到记忆」）'
                                    : '(no global memory — add via Settings → Memory, or long-press a message → Save to memory)',
                                globals,
                              ),
                              section(
                                isZh ? '【项目记忆】' : '[Project memory]',
                                isZh
                                    ? (hasProject
                                        ? '（该项目还没有记忆）'
                                        : '（当前对话未绑定项目，项目记忆不注入）')
                                    : (hasProject
                                        ? '(no project memory in this project yet)'
                                        : '(this chat is not bound to a project; project memory not injected)'),
                                projects,
                              ),
                            ],
                          );
                        },
                      ),
                      // build101（C1 知识库 RAG）：绑定知识库 → 发送前自动检索引用
                      const Divider(height: 20),
                      Text(
                        isZh ? '知识库：' : 'Knowledge base:',
                        style: TextStyle(
                            fontSize: 12,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 4),
                      _KnowledgeBasePicker(
                        isZh: isZh,
                        selectedId: knowledgeBaseId,
                        onChanged: (v) =>
                            setDialogState(() => knowledgeBaseId = v),
                      ),
                      const Divider(height: 20),
                      // build101（E8 自定义助手）：绑定角色人设
                      Text(
                        isZh ? '助手人设：' : 'Assistant persona:',
                        style: TextStyle(
                            fontSize: 12,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 4),
                      _AssistantPicker(
                        isZh: isZh,
                        selectedId: assistantId,
                        onChanged: (v) => setDialogState(() => assistantId = v),
                      ),
                      const Divider(height: 20),
                      // 子代理模式：auto / main_only / force_search / force_synthesis / force_plugin
                      // build146：五档**全部保留**（存量会话存的就是这五个字符串，
                      // 不迁移不新增列），但落点已重定：只有中间两档走编排器，
                      // 其余三档走自主思考循环——所以这里不再给"哪档会编排"的暗示，
                      // 具体说在哪行的 hint 里（_subagentModeHint），判据在
                      // services 层 subagentModeUsesOrchestrator（唯一入口）。
                      Text(
                        isZh ? '子代理模式：' : 'Sub-agent mode:',
                        style: TextStyle(
                            fontSize: 12,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final m in Conversation.kSubagentModes)
                            ChoiceChip(
                              showCheckmark: false,
                              label: Text(_subagentModeLabel(m, isZh),
                                  style: const TextStyle(fontSize: 11)),
                              selected: subagentMode == m,
                              selectedColor: Theme.of(context)
                                  .colorScheme
                                  .primary
                                  .withValues(alpha: 0.12),
                              onSelected: (_) =>
                                  setDialogState(() => subagentMode = m),
                            ),
                        ],
                      ),
                      Text(
                        _subagentModeHint(subagentMode, isZh),
                        style: TextStyle(
                            fontSize: 11,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                      // ===== build90 ⑧：所属项目 =====
                      const Divider(height: 20),
                      DropdownButtonFormField<String>(
                        initialValue: projects.any((p) => p.id == projectId)
                            ? projectId
                            : '',
                        decoration: InputDecoration(
                          labelText: isZh ? '所属项目' : 'Project',
                          isDense: true,
                        ),
                        items: [
                          DropdownMenuItem(
                              value: '',
                              child: Text(isZh ? '无项目' : 'No project')),
                          for (final p in projects)
                            DropdownMenuItem(
                                value: p.id,
                                child: Text(p.name,
                                    overflow: TextOverflow.ellipsis)),
                        ],
                        // B-018：切项目才重建记忆预览 future（其余 rebuild 复用同一实例）
                        onChanged: (v) => setDialogState(() {
                          projectId = v ?? '';
                          memFuture = MemoryBlockBuilder.buildParts(projectId);
                        }),
                      ),
                      // ===== build129：生成模型（生图 / 生视频）=====
                      // 真机日志 nexus_export_2026-09-19T10-05 的直接修复点：用户
                      // 想生视频，AI 打 video_gen 稳定 400，而 App 内没有任何地方能
                      // 指定视频模型 → AI 只能连搜 7 轮「怎么传 model 参数」。
                      const Divider(height: 20),
                      Text(
                        isZh
                            ? '生成模型（保存到当前 API 配置，与该对话共用同一份）'
                            : 'Generation models (saved to the current API config)',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      _buildGenModelRow(
                        isZh: isZh,
                        isVideo: false,
                        current: genImageModel,
                        onTap: () async {
                          final v = await _pickGenModel(
                              isVideo: false, current: genImageModel, isZh: isZh);
                          if (v != null) {
                            setDialogState(() => genImageModel = v);
                          }
                        },
                      ),
                      _buildGenModelRow(
                        isZh: isZh,
                        isVideo: true,
                        current: genVideoModel,
                        onTap: () async {
                          final v = await _pickGenModel(
                              isVideo: true, current: genVideoModel, isZh: isZh);
                          if (v != null) {
                            setDialogState(() => genVideoModel = v);
                          }
                        },
                      ),
                      if (genImageModel.isEmpty || genVideoModel.isEmpty)
                        Text(
                          isZh
                              ? '「跟随对话模型」= 拿对话模型去打生图/视频端点，多数中转会直接报 400'
                              : 'Follow chat model = the chat model hits the gen endpoint; most relays return 400',
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            AppSheetActions(children: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(isZh ? '取消' : 'Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(isZh ? '保存' : 'Save'),
              ),
            ]),
          ],
        ),
      ),
    );

    if (saved != true) return;
    widget.conversation.temperature = temperature;
    widget.conversation.topP = topP;
    widget.conversation.enable20sCheck = enable20sCheck;
    widget.conversation.autoCompress = autoCompress;
    // build138（乙）：两列首次真正有消费者，落库走 conversation.toMap 既有路径
    widget.conversation.contextAuto = contextAuto;
    widget.conversation.contextLimit = contextLimit;
    widget.conversation.reactEnabled = reactEnabled;
    widget.conversation.reactAutoMode = reactAutoMode;
    widget.conversation.reactMaxRounds = reactMaxRounds;
    widget.conversation.reasoningEffort = reasoningEffort;
    // v1.7.34：跨对话记忆 + 子代理模式
    widget.conversation.memoryEnabled = memoryEnabled;
    widget.conversation.longTermMemoryEnabled = longTermMemoryEnabled;
    widget.conversation.knowledgeBaseId = knowledgeBaseId;
    widget.conversation.assistantId = assistantId;
    widget.conversation.subagentMode = subagentMode;
    widget.conversation.projectId = projectId;
    await _storage.saveConversation(widget.conversation);
    // build129：生成模型写回 API 配置（仅在有变化时写，避免无谓的 notifyListeners
    // 触发整棵聊天界面重建）。失败不阻断——配置没存上时用户下次进配置页还能看到旧值。
    if (genConfig.imageModel.trim() != genImageModel ||
        genConfig.videoModel.trim() != genVideoModel) {
      await _storage.saveApiConfig(genConfig.copyWith(
        imageModel: genImageModel,
        videoModel: genVideoModel,
      ));
    }
    if (mounted) setState(() => _enable20sCheck = enable20sCheck);
  }

  // ==========================================================================
  // 上下文压缩：手动或自动生成持久化摘要，原始消息始终保留。
  // ==========================================================================
  Future<void> _compressContext() async {
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    // build104（I14）：与自动压缩互斥
    if (_compressInProgress) {
      AppSnackBar.showSnackBar(
          context,
          SnackBar(
            content: Text(isZh ? '正在压缩中，请稍候' : 'Compression in progress'),
            behavior: SnackBarBehavior.floating,
          ));
      return;
    }
    if (_apiConfig == null) {
      if (mounted) {
        AppSnackBar.showSnackBar(
            context,
            SnackBar(
              content: Text(isZh
                  ? '请先连接 AI 密钥再压缩上下文'
                  : 'Configure an API key before compressing'),
              behavior: SnackBarBehavior.floating,
            ));
      }
      return;
    }
    if (_isStreaming) return; // AI 正在思考时不压缩
    if (_messages.length <= 4) {
      if (mounted) {
        AppSnackBar.showSnackBar(
            context,
            SnackBar(
              content: Text(isZh
                  ? '消息还不够多，暂时不用压缩'
                  : 'Not enough messages to compress yet'),
              behavior: SnackBarBehavior.floating,
            ));
      }
      return;
    }

    final existing =
        await _storage.getContextCompactionSegments(widget.conversation.id);
    if (!mounted) return;
    final oldMsgs = ContextBudgetService.selectCompactionSource(
      conversationId: widget.conversation.id,
      messages: _messages,
      segments: existing,
    );
    if (oldMsgs.isEmpty) {
      if (mounted) {
        AppSnackBar.showSnackBar(
            context,
            SnackBar(
              content: Text(isZh
                  ? '没有可压缩的未摘要消息'
                  : 'There are no unsummarized messages to compress'),
              behavior: SnackBarBehavior.floating,
            ));
      }
      return;
    }
    final apiSvc = context.read<ApiService>();
    // build104（I13/I14）：进度状态长在 AppBar 菜单项上（⏳ 压缩中… + 禁用），
    // 不再用常驻 SnackBar——旧方案遮挡输入栏、不自动消失、易误触（实机反馈 I13）。
    if (mounted) setState(() => _compressInProgress = true);

    try {
      final summary = await _summarizeMessages(apiSvc, oldMsgs);
      if (summary.isEmpty) throw Exception('AI 返回的摘要为空');

      final segment = ContextCompactionSegment(
        id: const Uuid().v4(),
        conversationId: widget.conversation.id,
        summary: summary,
        startMessageId: oldMsgs.first.id,
        endMessageId: oldMsgs.last.id,
        sourceTokenEstimate: ApiService.estimateTokens(oldMsgs),
        createdAt: DateTime.now(),
      );
      await _storage.saveContextCompactionSegment(segment);
      _logger.info(
          '[Chat] Manually compressed context: ${oldMsgs.length} msgs → persisted segment',
          tag: 'Chat');
      // build104（I14）：流式安全刷新——压缩期间用户可能已发出新消息且模型
      // 正在流式回答，此时整表替换 _messages 会让流式气泡冻结（实锤竞态）。
      if (_isStreaming) {
        _compactionSegments =
            await _storage.getContextCompactionSegments(widget.conversation.id);
        if (mounted) setState(() {});
      } else {
        await _loadData();
      }
      if (mounted) {
        final beforeK = (segment.sourceTokenEstimate / 1000).toStringAsFixed(1);
        final afterK = (ApiServiceTokenEstimate.text(segment.summary) / 1000)
            .toStringAsFixed(1);
        AppSnackBar.showSnackBar(
            context,
            SnackBar(
              content: Text(isZh
                  ? '✅ 压缩完成：${oldMsgs.length} 条 → 摘要（前 ${beforeK}K → 后 ${afterK}K）'
                  : '✅ Compressed: ${oldMsgs.length} msgs → summary (${beforeK}K → ${afterK}K)'),
            ));
      }
    } catch (e) {
      _logger.error('[Chat] Compress context failed',
          error: e, cat: LogCat.chat, tag: 'Chat');
      var reason = e.toString().trim();
      final nl = reason.indexOf('\n');
      if (nl > 0) reason = reason.substring(0, nl);
      if (mounted) {
        AppSnackBar.showSnackBar(
            context,
            SnackBar(
              content:
                  Text(isZh ? '❌ 压缩失败：$reason' : '❌ Compress failed: $reason'),
            ));
      }
    } finally {
      if (mounted) setState(() => _compressInProgress = false);
      _refreshContextUsage();
    }
  }

  /// v1.4.2：把一批消息交给 LLM 总结成结构化摘要
  /// 输出包含：关键决定、用户诉求、AI 结论、未完成事项
  Future<String> _summarizeMessages(
      ApiService apiSvc, List<ChatMessage> msgs) async {
    final lines = msgs.map((m) {
      final who = m.role == MessageRole.user ? '用户' : 'AI';
      final c = m.content.length > 800
          ? '${m.content.substring(0, 800)}…'
          : m.content;
      return '$who: $c';
    }).join('\n');
    final resp = await apiSvc.completeChat(
      config: _conversationApiConfig.copyWith(temperature: 0.2),
      messages: [
        ChatMessage.create(
          conversationId: widget.conversation.id,
          role: MessageRole.system,
          content: '''你是专业的对话上下文压缩器。请把下面的对话历史压缩成一段极简摘要，格式如下：

## 高层推理
- 对话的核心目标、关键决策、结论（1-3 条）

## 工具使用
- 调用了哪些工具/搜索了什么/得到什么关键结果（1-3 条）

## 任务依赖
- 未完成的待办、需要后续跟进的依赖项（如有，1-2 条）

要求：
1. 总计 100-150 字，能省则省
2. 只保留影响后续对话的信息，闲聊/客套全删
3. 只输出摘要正文，不要输出任何其他内容''',
        ),
        ChatMessage.create(
          conversationId: widget.conversation.id,
          role: MessageRole.user,
          content: lines,
        ),
      ],
      timeout: const Duration(seconds: 60),
    );
    return _extractFirstAnswer(resp);
  }

  // ==========================================================================
  // v1.7.17：🔌 插件提示三态（off/manual/auto）切换 + 长按编辑面板（从主文件迁入）
  // ==========================================================================
  /// v1.7.17：点按 🔌 三态循环 off → manual → auto → off（立即持久化）。
  Future<void> _togglePluginHint() async {
    final next = _pluginHintConfig.mode == PluginHintMode.off
        ? PluginHintMode.manual
        : _pluginHintConfig.mode == PluginHintMode.manual
            ? PluginHintMode.auto
            : PluginHintMode.off;
    final nextConfig = _pluginHintConfig.copyWith(mode: next);
    setState(() => _pluginHintConfig = nextConfig);
    await nextConfig.save();
  }

  /// v1.7.17：长按 🔌 弹「三态选择」面板——Radio 选 off/manual/auto；
  /// manual 下列出已启用（registry.isEnabled）的 MCP(kind==mcpRemote) 与
  /// Skill(kind==declarative 且非 system) 插件，多选勾选写入 selectedIds；
  /// 底部保留 extraHints 自由提示词的增删编辑（兼容旧 plugin_hint_items）。
  Future<void> _editPluginHint() async {
    final l = AppLocalizations.of(context);
    final isZh = l.locale.languageCode == 'zh';
    final registry = context.read<PluginRegistry>();
    // 手动勾选候选 = 已启用的 MCP + Skill（排除 system 内置声明式插件，与目录层一致）
    final selectable = registry.plugins
        .where((p) => registry.isEnabled(p.metadata.id))
        .where((p) =>
            p.metadata.kind == PluginKind.mcpRemote ||
            (p.metadata.kind == PluginKind.declarative &&
                p.source != PluginSource.system))
        .toList();
    final enabledIds = selectable.map((p) => p.metadata.id).toSet();

    var mode = _pluginHintConfig.mode;
    // 勾选集合与已启用集合取交集：禁用掉的插件不再出现在勾选列表，也不会残留。
    final selected = <String>{
      ..._pluginHintConfig.selectedIds.where(enabledIds.contains),
    };
    final extra = List<String>.from(_pluginHintConfig.extraHints);
    final addCtrl = TextEditingController();

    // build126 (B2)：AlertDialog → 底部弹层（scrollable：manual 模式下列出全部
    // 已启用插件，条目多时会超一屏）。StatefulBuilder 原样保留。
    // 顺带去掉标题里的 🔌 emoji —— 标题改由 AppSheetHeader 统一排版。
    // build145（循环审查第 6 轮 P0）：`keyboardAware` 必须开 —— 这个弹层里就有
    // 一个"补充提示"输入框（上面的 addCtrl）。`showAppSheet` 默认不开
    // （ui/app_sheet.dart:52 才按 viewInsets 让位），所以打字时输入框被键盘盖死：
    // 看不见字、"完成"点不到。同文件 :520 与 chat_screen_message.dart:1401
    // 两处带输入框的弹层早就开了，唯独这处漏了（三处同一语义，不该有两种写法）。
    final save = await showAppSheet<bool>(
      context: context,
      scrollable: true,
      keyboardAware: true,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppSheetHeader(title: isZh ? '插件提示' : 'Plugin hint'),
                Flexible(
                  child: SizedBox(
                    width: double.maxFinite,
                    child: SingleChildScrollView(
                      child: RadioGroup<PluginHintMode>(
                        groupValue: mode,
                        onChanged: (v) => setDialogState(() => mode = v!),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            RadioListTile<PluginHintMode>(
                              value: PluginHintMode.off,
                              title: Text(isZh ? '关闭' : 'Off'),
                              subtitle: Text(isZh
                                  ? '不注入 MCP/Skill 目录'
                                  : 'No MCP/Skill catalog'),
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                            ),
                            RadioListTile<PluginHintMode>(
                              value: PluginHintMode.manual,
                              title: Text(isZh ? '手动' : 'Manual'),
                              subtitle: Text(isZh
                                  ? '只注入下方勾选的 MCP/Skill'
                                  : 'Only inject selected MCP/Skill'),
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                            ),
                            if (mode == PluginHintMode.manual) ...[
                              if (selectable.isEmpty)
                                Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 8),
                                  child: Text(
                                    isZh
                                        ? '暂无已启用的 MCP/Skill 插件'
                                        : 'No enabled MCP/Skill plugins',
                                    style: TextStyle(
                                        fontSize: 13,
                                        color: Theme.of(dialogCtx).hintColor),
                                  ),
                                ),
                              ...selectable.map((p) => CheckboxListTile(
                                    value: selected.contains(p.metadata.id),
                                    onChanged: (v) => setDialogState(() {
                                      if (v == true) {
                                        selected.add(p.metadata.id);
                                      } else {
                                        selected.remove(p.metadata.id);
                                      }
                                    }),
                                    title: Text(
                                        p.metadata.displayName(isZh),
                                        style: const TextStyle(fontSize: 13)),
                                    subtitle: Text(
                                      '${p.metadata.kind == PluginKind.mcpRemote ? 'MCP' : 'Skill'} · ${p.metadata.id}',
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: Theme.of(dialogCtx).hintColor),
                                    ),
                                    dense: true,
                                    controlAffinity:
                                        ListTileControlAffinity.leading,
                                    contentPadding: EdgeInsets.zero,
                                  )),
                              const Divider(),
                            ],
                            RadioListTile<PluginHintMode>(
                              value: PluginHintMode.auto,
                              title: Text(isZh ? '自动' : 'Auto'),
                              subtitle: Text(isZh
                                  ? '注入全部已启用的 MCP/Skill'
                                  : 'Inject all enabled MCP/Skill'),
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              isZh ? '附加提示词（自由文本）' : 'Extra hints (free text)',
                              style: const TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w600),
                            ),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 180),
                              child: ListView(
                                shrinkWrap: true,
                                children: [
                                  for (int i = 0; i < extra.length; i++)
                                    ListTile(
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                      title: Text(extra[i],
                                          style: const TextStyle(fontSize: 13)),
                                      trailing: IconButton(
                                        icon: const Icon(Icons.delete_outline,
                                            size: 20),
                                        tooltip: isZh ? '删除' : 'Delete',
                                        onPressed: () => setDialogState(
                                            () => extra.removeAt(i)),
                                      ),
                                    ),
                                  if (extra.isEmpty)
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 8),
                                      child: Text(
                                        isZh ? '暂无提示词' : 'No hints',
                                        style: TextStyle(
                                            fontSize: 13,
                                            color:
                                                Theme.of(dialogCtx).hintColor),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: addCtrl,
                                    decoration: InputDecoration(
                                      isDense: true,
                                      hintText: isZh ? '新增提示词…' : 'Add a hint…',
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                IconButton(
                                  icon: const Icon(Icons.add),
                                  tooltip: isZh ? '添加' : 'Add',
                                  onPressed: () {
                                    final t = addCtrl.text.trim();
                                    if (t.isEmpty) return;
                                    setDialogState(() {
                                      extra.add(t);
                                      addCtrl.clear();
                                    });
                                  },
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                AppSheetActions(children: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogCtx, false),
                    child: Text(isZh ? '取消' : 'Cancel'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(dialogCtx, true),
                    child: Text(isZh ? '完成' : 'Done'),
                  ),
                ]),
              ],
            );
          },
        );
      },
    );
    addCtrl.dispose();
    if (save != true || !mounted) return;
    final nextConfig = PluginHintConfig(
      mode: mode,
      selectedIds: selected.where(enabledIds.contains).toList()..sort(),
      extraHints: extra,
    );
    setState(() => _pluginHintConfig = nextConfig);
    await nextConfig.save();
  }
}

/// build101（C1 知识库 RAG）：会话设置里的知识库选择器。
///
/// 独立成 StatefulWidget 是因为需要异步加载知识库列表；
/// 空列表时显示「未建知识库」引导，避免下拉框空白让人困惑。
class _KnowledgeBasePicker extends StatefulWidget {
  final bool isZh;
  final String selectedId;
  final ValueChanged<String> onChanged;

  const _KnowledgeBasePicker({
    required this.isZh,
    required this.selectedId,
    required this.onChanged,
  });

  @override
  State<_KnowledgeBasePicker> createState() => _KnowledgeBasePickerState();
}

class _KnowledgeBasePickerState extends State<_KnowledgeBasePicker> {
  List<KnowledgeBase> _list = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final storage = context.read<StorageService>();
    final list = await storage.listKnowledgeBases();
    if (!mounted) return;
    setState(() {
      _list = list;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final zh = widget.isZh;
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: SizedBox(
          height: 16,
          width: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_list.isEmpty) {
      return Text(
        zh
            ? '还没有知识库。到「设置 → 知识库」导入文档后可在此绑定。'
            : 'No knowledge base yet. Import docs in Settings -> Knowledge Base.',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    // 选中项若已被删除 → 回落到「不使用」
    final valid = _list.any((k) => k.id == widget.selectedId);
    return DropdownButtonFormField<String>(
      initialValue: valid ? widget.selectedId : '',
      isDense: true,
      decoration: const InputDecoration(
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      ),
      items: [
        DropdownMenuItem(
          value: '',
          child: Text(zh ? '不使用知识库' : 'None',
              style: const TextStyle(fontSize: 13)),
        ),
        for (final kb in _list)
          DropdownMenuItem(
            value: kb.id,
            child: Text(kb.name, style: const TextStyle(fontSize: 13)),
          ),
      ],
      onChanged: (v) => widget.onChanged(v ?? ''),
    );
  }
}

/// build101（E8 自定义助手）：会话设置里的助手选择器。
///
/// 与知识库选择器同构；空列表时引导到设置页创建。
class _AssistantPicker extends StatefulWidget {
  final bool isZh;
  final String selectedId;
  final ValueChanged<String> onChanged;

  const _AssistantPicker({
    required this.isZh,
    required this.selectedId,
    required this.onChanged,
  });

  @override
  State<_AssistantPicker> createState() => _AssistantPickerState();
}

class _AssistantPickerState extends State<_AssistantPicker> {
  List<Assistant> _list = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final storage = context.read<StorageService>();
    final list = await storage.listAssistants();
    if (!mounted) return;
    setState(() {
      _list = list;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final zh = widget.isZh;
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: SizedBox(
          height: 16,
          width: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_list.isEmpty) {
      return Text(
        zh
            ? '还没有助手。到「设置 → 自定义助手」创建后可在此绑定。'
            : 'No assistant yet. Create one in Settings -> Custom Assistants.',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    final valid = _list.any((a) => a.id == widget.selectedId);
    return DropdownButtonFormField<String>(
      initialValue: valid ? widget.selectedId : '',
      isDense: true,
      decoration: const InputDecoration(
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      ),
      items: [
        DropdownMenuItem(
          value: '',
          child:
              Text(zh ? '不使用助手' : 'None', style: const TextStyle(fontSize: 13)),
        ),
        for (final a in _list)
          DropdownMenuItem(
            value: a.id,
            child: Text('${a.emoji} ${a.name}',
                style: const TextStyle(fontSize: 13)),
          ),
      ],
      onChanged: (v) => widget.onChanged(v ?? ''),
    );
  }
}
