import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../ui/app_content.dart';
import '../ui/app_elapsed.dart';
import '../ui/app_pulse.dart';
import '../ui/app_skeleton.dart';
import '../ui/tokens.dart';
import '../utils/model_name_cleaner.dart';
import '../plugins/builtin_plugin_i18n.dart';
import '../l10n/app_localizations.dart';
import '../models/chat_message.dart';
import '../services/deep_link_markdown.dart';
import 'markdown_builders.dart';
import 'message_action_button.dart';
import 'interact_card.dart';
import '../utils/launcher_utils.dart';
import '../utils/app_snackbar.dart';
// build161 ③：「接着写」按钮的出现判据（正文尾挂着「网络中断」那一句）。
import '../utils/drop_continue.dart';
// build162：「预览」按钮的出现判据（整条正文就是一份 HTML 文档）。
import '../utils/html_preview.dart';
// build163：附件卡片的点击判据（哪些附件拿得到内容、点开给什么）。
import '../utils/attachment_tap.dart';
// build164（#83）：工作区产物卡片的判据（哪一步真的落盘、卡片上有哪些字、点开读什么）。
// progressNote（#82 新增的 step kind）的可见行判据也住在同一个文件里，见它的文件头。
import '../utils/agent_artifact_cards.dart';
// build167：这里**不再 import** `app_container_transform.dart` ——
// 165（#89）把「产物卡片 → HTML 预览页」接过容器转场，用户 26 日 19:02 报
// 「会闪屏，不到一秒就好」：那块 shuttle 是"正文留在原位、容器从上面盖过去"，
// 而本页第一帧就把内容画好了 ⇒ 450ms 里是一块近黑容器盖在真内容上。
// 撤接线不撤组件（组件仍被 build165 的 ⑤ 组直接测着），原因与前置条件写在
// `docs/BUGSCAN_build166_20260926.md` ④ 与 `lib/ui/app_container_transform.dart` 文件头。
import '../screens/html_preview_screen.dart';
import '../services/logger_service.dart';
import '../services/workspace_service.dart';
import '../services/biometric_service.dart';
import '../services/file_open_service.dart';
import '../ui/app_sheet.dart';
import '../ui/image_decode.dart';

/// 聊天消息气泡 V2（Chatbox 朴素风）。
///
/// 与旧版 [MessageBubble] 的差异：
/// - AI 消息通栏（无气泡底色/边框），正文下方一行小图标操作（复制/重试/版本切换）
/// - 用户消息右对齐浅灰底圆角块
/// - 思考过程为朴素折叠区块：一行标题「思考过程 12s · N 步」+ 展开箭头，
///   点开为浅灰正文，无 emoji、无彩色面板；保留导出 Markdown 能力
/// - 保留 📎 来源引用卡片能力（朴素化样式）
/// - 代码块深色底 + 顶栏（语言名 + 复制）由 CodeBlockBuilder 统一提供
class MessageBubbleV2 extends StatefulWidget {
  final ChatMessage message;
  final bool isStreaming;
  final String? modelName;
  final VoidCallback? onRetry;
  final int retryVersionCount;
  final int retryVersionIndex;
  final void Function(int direction)? onSwitchVersion;
  final VoidCallback? onRollback;

  /// build103：用户消息「编辑重发」入口上浮（功能 build101 B3 已有，藏在长按
  /// 菜单里；对标 Chatbox 把它放到操作行提高可发现性）——null = 不显示
  final VoidCallback? onEdit;

  /// v1.7.38（card 协议）：卡片选项点选 → 以快捷回复发送一条用户消息
  final void Function(String text)? onQuickReply;

  // ============ build101（D1/D3）：外观可选项 ============
  /// 显示头像（默认关；关时完全不渲染，零布局开销）
  final bool showAvatar;

  /// 用户头像本地路径（空串 = 用占位图标）
  final String userAvatarPath;

  /// AI 头像本地路径（空串 = 用占位图标）
  final String aiAvatarPath;

  /// AI 消息是否加气泡底色（默认关 = 通栏无底色）
  final bool showBubble;

  /// 是否双向左对齐（默认 = 用户右 / AI 左）
  final bool leftAlign;

  /// 显示时间戳
  final bool showTimestamp;

  /// 显示模型名
  final bool showModelName;

  /// 显示 token 消耗
  final bool showTokenUsage;

  /// 显示字数统计
  final bool showCharCount;

  /// build101（F2）：会话内查找跳转落点——短暂描边提示该条消息。
  final bool highlighted;

  /// 显示首字耗时（毫秒；<=0 表示无数据）
  final int firstTokenLatencyMs;

  /// build133（⑦）：本条消息是否已被收藏（星标）。
  /// 此前该状态只体现在长按菜单的图标上 —— 写入 `starredMessageIds` 却没有读取点，
  /// 收藏过的消息在正文里完全看不出来。这里给状态一个可见的落点。
  final bool isStarred;

  /// build161 ③：掉线气泡上的常驻续写入口。
  ///
  /// 为什么过去只有文案没有按钮：↻ 重试是**整轮重跑**（重发提问、重烧检索轮），
  /// 而掉线要的是"从已收的半截接着写"——两件事成本与语义都不同，不能拿重试凑数。
  /// build165 ③：这一枚按钮现在覆盖三种"这一轮没跑完"（对端断线有正文 / 0 正文 /
  /// 本端因离开 App 收线），**文字由 [continueEntryKindFor] 一并给出**，
  /// 所以宿主挂上来的回调也必须按同一个判据分岔（`_onContinueEntryTap`）。
  /// 出现条件 = 传了回调 **且** 正文尾挂着那三句之一（见 _buildActionRow）；
  /// "最后一条 / 非流式"这类只有宿主知道的事实由调用方挡。
  final VoidCallback? onContinue;

  const MessageBubbleV2({
    super.key,
    required this.message,
    this.isStreaming = false,
    this.modelName,
    this.onRetry,
    this.retryVersionCount = 0,
    this.retryVersionIndex = 0,
    this.onSwitchVersion,
    this.onRollback,
    this.onEdit,
    this.onQuickReply,
    this.showAvatar = false,
    this.userAvatarPath = '',
    this.aiAvatarPath = '',
    this.showBubble = false,
    this.leftAlign = false,
    this.showTimestamp = false,
    this.highlighted = false,
    this.showModelName = true,
    this.showTokenUsage = true,
    this.showCharCount = false,
    this.firstTokenLatencyMs = 0,
    this.isStarred = false,
    this.onContinue,
  });

  @override
  State<MessageBubbleV2> createState() => _MessageBubbleV2State();
}

class _MessageBubbleV2State extends State<MessageBubbleV2> {
  // build96 (O13)：两层嵌套折叠——外层 key='_all'，内层节点 key='n$idx'，
  // 各自独立开合（还原 v1.7.37 旧版形态）
  final Set<String> _expandedPhases = {};
  bool _userToggledManually = false;

  /// SF-2：本轮流式中正文首字是否已落地（落地后思考不再自动展开）
  bool _answerStarted = false;

  /// C3（G29）：token 明细（↑↓ 与缓存读写/命中率）默认折叠——
  /// metaRow 已唯一显示总量，footnote 再平铺一行「Tokens: ↑x + ↓y」同屏重复。
  /// 点「详情」才展开，保持信息可查而不制造噪音。
  bool _showTokenDetail = false;

  /// build164（#83）：产物卡片「点开」的并发闸。
  /// 点开要读盘（异步），读盘期间再点第二下会堆出第二趟路由 ——
  /// 同一个文件叠两层预览页，用户按返回键要按两下。
  bool _artifactOpening = false;

  @override
  void didUpdateWidget(covariant MessageBubbleV2 oldWidget) {
    super.didUpdateWidget(oldWidget);
    // build96 (O13)：流式期间自动展开外层 + 当前进行节点；定稿后外层自动收起。
    // 用户手动开合过后，本轮不再被自动态覆盖。
    // build98 (O13-P2)：新一轮流式开始时复位手动标记（旧实现永久置位，
    // 用户碰过一次后本条消息永远失去自动态）；流式期间自动展开只增不减，
    // 定稿时把已完成节点也一并收掉，只留外层折叠。
    if (!oldWidget.isStreaming && widget.isStreaming) {
      _userToggledManually = false;
      // SF-2：新一轮流式开始，复位「正文已开始」标记
      _answerStarted = false;
    }
    // SF-2：正文首字落地即折叠思考（DeepSeek 式）——ReAct 边答边想的零星
    // reasoning 也不再自动展开；手动点开仍允许（_userToggledManually 挡）。
    if (widget.isStreaming &&
        !_answerStarted &&
        oldWidget.message.content.isEmpty &&
        widget.message.content.isNotEmpty) {
      _answerStarted = true;
      _expandedPhases.remove('_all');
      _expandedPhases.removeWhere((k) => k.startsWith('n'));
    }
    if (_userToggledManually) return;
    final steps = widget.message.reasoningSteps;
    if (widget.isStreaming && steps.isNotEmpty && !_answerStarted) {
      _expandedPhases.add('_all');
      _expandedPhases.add('n${_mergeNodes(steps).length - 1}');
    } else if (oldWidget.isStreaming && !widget.isStreaming) {
      // SF-2：定稿兜底收起保留为最后防线；但纯思考被停止/出错（正文仍空）
      // 不强行折叠，保留现场。
      if (_answerStarted || widget.message.content.isNotEmpty) {
        _expandedPhases.remove('_all');
        // 内层节点只增不减 → 定稿时清理非当前节点的展开态
        _expandedPhases.removeWhere((k) => k.startsWith('n'));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    final isUser = m.role == MessageRole.user;
    final theme = Theme.of(context);
    final l = AppLocalizations.of(context);
    final zh = l.locale.languageCode == 'zh';

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 思考过程朴素折叠区块（正文之前，默认收起）
        // build164（#83）：闸门从 `m.hasReasoning` 收紧成「面板里真有话」。
        // `hasReasoning` 认的是"任何一条不是纯进度占位的步骤"，而 #82 新加的
        // progressNote 恰好不是占位 ⇒ 整轮只有一句阶段小结时它会放行一个
        // 「点开什么都没有」的空壳面板（build133 已把那个形状按缺陷处理过）。
        // progressNote 因此不进面板，改在下面按正文样式画成可见的一行。
        if (!isUser && m.hasReasoning && hasThinkingPanelSteps(m.reasoningSteps))
          _buildReasoningBlock(theme, zh),
        // build164（#83）：面向用户的一句话阶段进展（#82 落的 `progressNote` 步骤）
        // —— 可见、正文样式、**不**折进上面那个面板。
        // 找不到该 kind（同事那边还没落地）时返回空盒，渲染与改前逐像素一致，
        // 所以这条新通道不是崩溃面。
        if (!isUser) _buildProgressNotes(theme),
        // build140（反馈⑥）：待办清单**已从气泡内部搬走**，改由输入框上方的
        // `ChatTodoStrip` 常驻显示（`chat_screen` 里排在用量条之前）。
        // 搬走的理由不是"这里不好看"，而是**位置错了**：气泡里的清单往上翻就看不见，
        // 而多步任务要的是"随时知道走到第几步"。同一语义只允许一处实现（教训 #62），
        // 所以这里不再保留卡片——勾态与清单数据仍挂在 `ChatMessage.todoItems` 上。
        if (m.attachments.isNotEmpty) _buildAttachmentPreview(theme, zh),
        // build122：AI 生成产物（图片/视频）——与附件分开渲染，因为这类内容
        // 是「模型的产出」而不是「用户提供的输入」，且**不进 API 请求**。
        if (m.generatedFiles.isNotEmpty) _buildGeneratedFiles(theme, zh),
        // build140 反馈②：这条独立状态行与思考面板头部**同源同值**（同一个 AppElapsed：
        // 呼吸点 + 计时 + 「整理上下文」阶段），思考面板一旦出现就是同一句话说两遍
        // ⇒ 显示条件必须与面板互斥：只有「本轮还没有可展示的思考步骤」时才画它。
        // 早于首步的窗口（`hasReasoning` 为 false，纯进度占位不算真实思考）仍由这一行
        // 负责，不能一起删掉——那时没有任何「还在跑」的指示。
        if (m.content.isEmpty && widget.isStreaming && !m.hasReasoning)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // build133（M4）：转圈 → 呼吸点。这一行已经有个在跳的计时器，
              // 再转一个圈是第二重「在忙」的噪声；呼吸点更弱、不抢计时器。
              const AppPulse(size: 7),
              const SizedBox(width: 8),
              AppElapsed(
                startTs:
                    m.hasReasoning ? m.reasoningSteps.first.ts : m.createdAt,
                zh: zh,
                prefix: zh ? '思考中' : 'Thinking',
                stage: m.hasReasoning ? _liveStage(m.reasoningSteps, zh) : null,
              ),
            ],
          )
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // v1.7.38（card 协议）：先提取 <card> 块，正文交 Markdown、卡片原生渲染
              Builder(builder: (_) {
                final (md, cards) = isUser
                    ? (m.content, const <InteractCardData>[])
                    : splitCardBlocks(m.content);
                // 提取 <error> 块 → 渲染为可折叠错误卡片
                final (cleanMd, errorMsg) = _splitErrorBlock(md);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (errorMsg != null)
                      _ErrorCollapsibleCard(error: errorMsg, zh: zh),
                    if (cleanMd.isNotEmpty)
                      MarkdownBody(
                        // build107（U5）：AI 答案里的地图深链（含反引号代码段内的）
                        // 统一转成可点链接——实机样本深链写在代码段里点了没反应
                        data: _preprocessHtmlDivs(
                            isUser ? cleanMd : linkifyDeepUris(cleanMd)),
                        selectable: !widget.isStreaming,
                        onTapLink: _onTapLink,
                        builders: {
                          'pre': CodeBlockBuilder(),
                          'nx_table': TableBuilder(),
                        },
                        blockSyntaxes: [NexusTableSyntax()],
                        styleSheet: _buildMarkdownStyleSheet(theme, isUser),
                      ),
                    for (final c in cards)
                      InteractCard(
                        card: c,
                        zh: zh,
                        onQuickReply: widget.onQuickReply,
                      ),
                  ],
                );
              }),
              if (!isUser && _hasFootnote(m)) _buildFootnote(theme, m, zh),
              // 来源引用卡片（朴素化）
              if (!isUser && m.searchSources.isNotEmpty)
                _SourceCitationCardV2(
                    sources: m.searchSources, theme: theme, zh: zh),
            ],
          ),
        // build134：流式光标也要**呼吸**（AppDur.pulse = 900ms，与思考面板同一档）。
        // 旧实现是静态字符 `▋` —— 于是「正文还没出」时有呼吸点、「正文在出」时
        // 反而冻住，用户看到的就成了「有时在动、有时不动」。光标是竖条不是圆点：
        // 圆点会被读成又一个 loading，竖条才读成「字还没写完」。
        if (widget.isStreaming && m.content.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: AppPulse(
              size: 7,
              height: 15,
              borderRadius: 1.5,
              color: theme.colorScheme.onSurface,
            ),
          ),
        // build164（#83）：本轮真的写进工作区、且 App 内还能渲染的文件 ⇒ 一张卡片。
        // 位置在正文之后、推荐之前：卡片是**产出**，比推荐追问更挨着它说的那句话。
        // 流式中也画（写入那一步 status 落 success 就是已经落盘，用户可以立刻点开，
        // 不必等整轮收口 —— 判据要求 success，所以"还在写"的时候它本来就不出现）。
        if (!isUser) _buildAgentArtifactCards(theme, zh),
        // v1.7.39（build92）：推荐追问气泡（点击直接发送）
        // build140 反馈⑤「结论推荐要同时出来」：**去掉 `!widget.isStreaming` 这道闸**。
        // 原来气泡整排要等本轮流结束（isStreaming 落回 false）才画 ⇒ 带内 <suggest>
        // 明明已经解析进 m.suggestions，却要再等一轮收尾才"啪"地冒出来，看起来就是
        // "结论先出、推荐迟到"。suggestions 非空这件事本身就是"推荐已到"的唯一信号
        // （只有 <suggest> 解析成功或兜底流拿到条目才会写进来），所以直接以它为准。
        // 注意与下一行的分工：操作行（复制/重试）仍要等流结束，那是"这条回答已定稿"
        // 的语义，与推荐到没到货无关。
        if (!isUser && m.suggestions.isNotEmpty) _buildSuggestions(theme, zh),
        // AI 消息底部一行小图标操作（复制 / 版本切换 / 重试）
        if (!isUser && !widget.isStreaming) _buildActionRow(theme, zh),
        if (isUser && !widget.isStreaming && widget.onRollback != null)
          Align(
            alignment: Alignment.centerRight,
            // build103：编辑重发（对标 Chatbox）+ 撤回 并排
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.onEdit != null)
                  MessageActionButton(
                    icon: Icons.edit_outlined,
                    tooltip: zh ? '编辑重发' : 'Edit & resend',
                    onTap: widget.onEdit!,
                  ),
                MessageActionButton(
                  icon: Icons.undo,
                  tooltip: zh ? '撤回' : 'Undo',
                  onTap: widget.onRollback,
                ),
              ],
            ),
          ),
        // build101（D3）：底部元信息行（时间戳 / 模型名 / token / 字数 / 首字耗时）
        _buildMetaRow(theme, zh, isUser),
      ],
    );

    final Widget body = isUser
        ? Align(
            // 用户消息：默认右对齐；leftAlign 开启后改为左对齐
            alignment:
                widget.leftAlign ? Alignment.centerLeft : Alignment.centerRight,
            child: Container(
              constraints: BoxConstraints(
                // build168（宽屏档）：系数 0.82 一位未动，**动的只是它吃的宽度** ——
                // 原来吃 `MediaQuery.size.width`（屏幕），现在吃内容列
                // （`AppContent.widthOf`，见 lib/ui/app_content.dart）。
                // 手机 424dp 下两者是同一个数（compact 档不夹），所以这里
                // 347.68 → 347.68，一像素不动；平板 914dp 下旧写法给出 749dp
                // 的一行（约 47 个汉字，行尾找不到行首），现在落到 590dp。
                // 为什么必须读列宽而不是就地 `LayoutBuilder` 量：气泡在 ListView
                // （自带 8dp 内边距）里量到的是 408，乘 0.82 就少 13dp —— 那正是
                // 「手机侧不许动」这条判据要挡住的挪法。列宽由定它的那一层给。
                maxWidth: AppContent.widthOf(context) * 0.82,
              ),
              margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.65),
                borderRadius: BorderRadius.circular(12),
              ),
              child: content,
            ),
          )
        : Container(
            width: double.infinity,
            margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
            // build101（D3）：AI 气泡底色开关（默认关 = 通栏朴素风）
            decoration: widget.showBubble
                ? BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(12),
                  )
                : null,
            child: content,
          );

    // build101（D1）：头像开关（默认关，关时零附加布局）
    // build101（F2/F7）：无头像路径也要过高亮与无障碍装饰
    if (!widget.showAvatar) return _decorate(theme, isUser, body);
    final avatar = _Avatar(
      path: isUser ? widget.userAvatarPath : widget.aiAvatarPath,
      isUser: isUser,
      theme: theme,
    );
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      textDirection: isUser ? TextDirection.rtl : TextDirection.ltr,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: avatar,
        ),
        const SizedBox(width: 8),
        Expanded(child: body),
      ],
    );
    final wrapped = Container(
      margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
      child: row,
    );
    return _decorate(theme, isUser, wrapped);
  }

  /// build101（F2 / F7）：气泡最外层统一装饰。
  ///
  /// - 高亮描边（F2）：会话内查找跳转落点，1.6s 后由 ChatScreen 清 flag；
  ///   注意必须放在**最外层**——否则 showAvatar=false 时会被提前 return 掉。
  /// - 无障碍（F7）：给整条消息一个 Semantics 容器，读屏会朗读
  ///   「[我 / 助手]：正文」，而不是逐个碎块念。
  Widget _decorate(ThemeData theme, bool isUser, Widget child) {
    final cs = theme.colorScheme;
    var out = child;
    if (widget.highlighted) {
      out = Container(
        margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
        padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
        decoration: BoxDecoration(
          color: cs.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: cs.primary.withValues(alpha: 0.6),
            width: 1.5,
          ),
        ),
        child: out,
      );
    }
    final zh = AppLocalizations.of(context).locale.languageCode == 'zh';
    final roleLabel = isUser
        ? (zh ? '我的消息' : 'My message')
        : (zh ? '助手消息' : 'Assistant message');
    final plain = widget.message.content
        .replaceAll(RegExp(r'[#*`>\-\[\]()]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final spoken = plain.isEmpty
        ? widget.message.attachments.map((a) => a.fileName).join('、')
        : plain;
    return Semantics(
      container: true,
      label:
          '$roleLabel${spoken.isEmpty ? '' : '：${spoken.length > 200 ? '${spoken.substring(0, 200)}…' : spoken}'}',
      child: out,
    );
  }

  // ================= build101（D3）底部元信息行 =================

  /// 按开关渲染时间戳 / 模型名 / token 消耗 / 字数 / 首字耗时。
  /// 全关时返回空 widgets（不产生额外高度）。
  Widget _buildMetaRow(ThemeData theme, bool zh, bool isUser) {
    final m = widget.message;
    final parts = <Widget>[];

    final style = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
      fontSize: 11,
    );

    if (widget.isStarred) {
      // build133（⑦）：星标指示（脚注原本可能为空 ⇒ 由它决定是否渲染这一行）。
      parts.add(Icon(Icons.star, size: 12, color: theme.colorScheme.primary));
    }
    if (widget.showTimestamp) {
      parts.add(Text(_fmtTime(m.createdAt), style: style));
    }
    if (widget.showModelName && !isUser && widget.modelName != null) {
      // MN-3：统一走清洗名，与顶部切换器写法一致（不再显示原始 ID）
      parts.add(Text(ModelNameCleaner.cleanModelName(widget.modelName!),
          style: style));
    }
    // MN-1 补漏（build118，真机反馈「重复了/感觉没什么意义」）：footnote 不再显示
    // 「N tokens」总量的重复段——token 的唯一权威在 metaRow（↑↓增量 + 缓存明细
    // 或「token 详情」折叠），footnote 只保留时间/字数/首字耗时这些不重复的项。
    if (widget.showCharCount && m.content.isNotEmpty) {
      parts.add(Text(
        zh ? '${m.content.length} 字' : '${m.content.length} chars',
        style: style,
      ));
    }
    // G65①（build136）：**总量只在这里显示，全 App 唯一一处**。
    // 上面那段注释从 build118 起就写着「token 的唯一权威在 metaRow」，但代码只渲染了
    // 时间/模型名/字数/TTFT —— 注释是意图，不是实现。后果：只回 total_tokens 的模型
    // （DeepSeek 等只给总量的场景）在气泡里一个 token 数字都看不到。
    // 明细（↑↓ 与缓存）仍在 footnote，且那里**不再重复总量**。
    if (widget.showTokenUsage && !isUser && m.totalTokens != null) {
      parts.add(Text('${m.totalTokens} tokens', style: style));
    }
    if (widget.firstTokenLatencyMs > 0 && !isUser) {
      parts.add(Text(
        zh
            ? '首字 ${widget.firstTokenLatencyMs}ms'
            : 'TTFT ${widget.firstTokenLatencyMs}ms',
        style: style,
      ));
    }

    if (parts.isEmpty) return const SizedBox.shrink();

    final children = <Widget>[];
    for (var i = 0; i < parts.length; i++) {
      if (i > 0) {
        children.add(Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text('·', style: style),
        ));
      }
      children.add(parts[i]);
    }

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Align(
        alignment: isUser && !widget.leftAlign
            ? Alignment.centerRight
            : Alignment.centerLeft,
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: children,
        ),
      ),
    );
  }

  /// build101（F10）：时间戳分今天 / 非今天两档。
  /// 今天只显示 HH:mm:ss（省略日期，减噪）；非今天显示 MM-dd HH:mm:ss。
  /// 秒级精度对「连续快速对话」的场景很有用（分钟级会显示成同一时间）。
  static String _fmtTime(DateTime dt) {
    String two(int v) => v.toString().padLeft(2, '0');
    final t = '${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
    final now = DateTime.now();
    final sameDay =
        dt.year == now.year && dt.month == now.month && dt.day == now.day;
    if (sameDay) return t;
    return '${two(dt.month)}-${two(dt.day)} $t';
  }

  // ================= 底部操作行 =================

  /// build133：复制成功后就地变勾的短暂状态。
  bool _copied = false;
  Timer? _copiedTimer;

  @override
  void dispose() {
    // 铁律：widget 销毁后回调不得再跑 —— 定时器必须在 dispose 里取消，
    // 否则 900ms 后会在已卸载的 State 上 setState。
    _copiedTimer?.cancel();
    super.dispose();
  }

  /// 复制正文 + 就地反馈（替代原先的 SnackBar）。
  void _copyWithFeedback() {
    Clipboard.setData(ClipboardData(text: widget.message.content));
    setState(() => _copied = true);
    _copiedTimer?.cancel();
    _copiedTimer = Timer(AppDur.toast, () {
      if (!mounted) return;
      setState(() => _copied = false);
    });
  }

  Widget _buildActionRow(ThemeData theme, bool zh) {
    final hasVersions = widget.retryVersionCount > 1;
    final showRetry = widget.onRetry != null;
    // build161 ③：掉线失败气泡上的常驻续写入口。判据取**两侧与**：
    // 调用方按"最后一条 + 非流式"传回调，这里再认正文尾部那句"这一轮没跑完"——
    // 按钮和文案必须同生同灭：那一句被摘掉（续写进行中）按钮就该消失，
    // 只靠调用方传不传，早晚会出现"回调还挂着、文案已续走"的幽灵按钮。
    // build165 ③：判据换成 [continueEntryKindFor]（三句都认，含"0 正文"那一句），
    // 按钮的文字由**同一个判据**给（[continueEntryLabel]）—— 这里不许再抄一份字符串：
    // 只有真能接上断点的那种才写「接着写」，整轮重跑的那一类写「重新发起这一轮」。
    final continueKind = continueEntryKindFor(widget.message.content);
    final showContinue =
        widget.onContinue != null && continueKind != null;
    // build162：整条正文就是一份 HTML 文档时给一枚「预览」。判据是纯函数
    // （utils/html_preview.dart），与文件入口同一口径。混排说明文字的那一类
    // **故意不给** —— 那种内容拆开看比整页渲染有用，用户要的是「复制」。
    // 「只给助手消息、流式进行中不给」由调用点那道闸负责
    // （`if (!isUser && !widget.isStreaming) _buildActionRow(...)`），
    // 这里不再重抄一遍——半截文档本来也过不了判据（没有闭合 </html>）。
    final htmlDoc = extractHtmlDocument(widget.message.content);
    // 没有任何操作时不渲染空行（htmlDoc 非空必然有正文，不必进这道闸）
    if (!showRetry && !hasVersions && !showContinue &&
        widget.message.content.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      // build175 平板遍历：这一行原本是 `Row(mainAxisSize.min)`。156 那一轮据此把
      // 命中区做成"只补高不撑宽"，代价是四个键横向都停在 25.9~26.3dp（Material
      // 下限 48dp），并在注释里明确写着"横向留给『操作行改可换行 Wrap』那类设计变更"。
      // 这一刀就是那一刀：键横向抬到 48 之后，由**外层换行**消化宽度，而不是让键
      // 去迁就一行。助手气泡本身是 `Container(width: double.infinity)`，
      // Wrap 铺满的是同一宽度，所以未换行时视觉与改前逐像素相同。
      child: Wrap(
        spacing: 0,
        runSpacing: 0,
        children: [
          if (widget.message.content.isNotEmpty)
            MessageActionButton(
              // build133：复制反馈从「底部弹 SnackBar」改为**图标就地变勾**。
              // 理由：复制是低风险、高频的动作，弹条会遮住刚复制的内容、还要等它消失；
              // 就地变勾既不打断阅读，反馈位置也正好在手指落点上。
              icon: _copied ? Icons.check : Icons.copy_outlined,
              tooltip: _copied ? (zh ? '已复制' : 'Copied') : (zh ? '复制' : 'Copy'),
              onTap: _copyWithFeedback,
            ),
          if (htmlDoc != null)
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => _openHtmlPreview(htmlDoc),
              child: Padding(
                // build156/build157/build161 同一口径：命中区**只补高不撑宽**
                // （操作行是 mainAxisSize.min 的 Row，气泡宽上限屏宽 82%，
                // 横向撑宽会顶出 OVERFLOWED —— build157 回退过的坑）。
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 40),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.html_outlined,
                          size: 15, color: theme.colorScheme.primary),
                      const SizedBox(width: 4),
                      Text(
                        zh ? '预览' : 'Preview',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: theme.colorScheme.primary),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (showContinue)
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: widget.onContinue,
              child: Padding(
                // build156/build157 同一口径：命中区**只补高不撑宽**（操作行是
                // mainAxisSize.min 的 Row，气泡宽上限屏宽 82%，横向撑宽会在窄屏
                // 顶出 OVERFLOWED）。这一枚带文字，minHeight 40 就是"一整行"。
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 40),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.play_for_work,
                          size: 15, color: theme.colorScheme.primary),
                      const SizedBox(width: 4),
                      Text(
                        continueEntryLabel(continueKind, isZh: zh),
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: theme.colorScheme.primary),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (hasVersions) ...[
            MessageActionButton(
              icon: Icons.chevron_left,
              tooltip: zh ? '上一版本' : 'Previous version',
              onTap: () => widget.onSwitchVersion?.call(-1),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Text(
                '${widget.retryVersionIndex}/${widget.retryVersionCount}',
                style: TextStyle(
                    fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            MessageActionButton(
              icon: Icons.chevron_right,
              tooltip: zh ? '下一版本' : 'Next version',
              onTap: () => widget.onSwitchVersion?.call(1),
            ),
          ],
          if (showRetry)
            MessageActionButton(
              icon: Icons.refresh,
              tooltip: zh ? '重试' : 'Retry',
              onTap: widget.onRetry,
            ),
        ],
      ),
    );
  }

  /// build162：预览走 App 内 WebView（[HtmlPreviewScreen]）。
  ///
  /// 为什么回调不上浮到 ChatScreen：这一枚按钮只交出一段已经落库的正文，
  /// 不需要会话状态；同文件 [_openGeneratedFile] 早就在气泡里自己推路由（图片
  /// 全屏预览），这里是同一形态。**这一条入口沿用默认 [MaterialPageRoute]**：
  /// 它没有"源卡片容器"可共享，#89 的容器转场只接产物卡片那条路（见
  /// [_openAgentArtifact]；162 时代"本仓不许新增动画"的总闸口径已被 #89 取代）。
  /// 落盘/分享都在预览页自己的 action 里，不在这里。
  ///
  /// build163 起有两个调用点：操作行的「预览」（交正文，无文件名）与附件卡片
  /// （交 `extractedText` + 文件名）。两条都**不读文件**，所以不带第二份读盘口径。
  void _openHtmlPreview(String html, {String? fileName}) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => HtmlPreviewScreen(html: html, fileName: fileName),
    ));
  }

  // ================= build164（#83）：工作区产物卡片 + 阶段小结可见行 =================

  /// 本轮写进工作区、App 内还能渲染的文件 → 一行卡片。
  ///
  /// 位置补的是取证点名的那条缺口：正文里 `<ws_write content="整页 HTML">` 会被
  /// `react_parser.dart` 的 `_ctrlPaired` 整段剥掉 ⇒ 读正文的「预览」按钮永远判不出东西，
  /// 而附件卡片只挂在用户消息上、`generatedFiles` 只认 mp4/mov ⇒ 助手消息下方当时**没有**
  /// 任何入口。判据全部住在 `utils/agent_artifact_cards.dart`（画不画 / 上面有哪些字 /
  /// 点开读什么都由它一处决定），这里只排版。
  Widget _buildAgentArtifactCards(ThemeData theme, bool zh) {
    // 用户 02:40 定的三层："卡片全部都画，能开的开、不能开的什么都不承诺"。
    // 两条收集器共用判据层那一个私有收集器（只差类型闸的方向），这里只是并排画出来。
    final cards = [
      ...collectArtifactCards(widget.message.reasoningSteps),
      ...collectExternalArtifactCards(widget.message.reasoningSteps),
    ];
    if (cards.isEmpty) return const SizedBox.shrink();
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final c in cards)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: agentArtifactTapFor(c) == AgentArtifactTap.inAppPreview
                    ? () => _openAgentArtifact(c, zh)
                    : () => _openAgentArtifactExternal(c, zh),
                child: Container(
                  // 整张卡片就是命中区（InkWell 包住 Container，padding 那一圈也吃点击）。
                  // 口径同 build156/157/161/162/163：**只补高不撑宽** —— 这一张的高度由
                  // 左边那块 40 高的方形缩略块天然给到（40 + 上下 8 = 56dp ≥ 40），
                  // 所以这里**不需要**再写一份 minHeight 命中区约束；宽度用 maxWidth 封顶
                  // （窄屏上由父级先收到 420 以下），不但不撑宽、还保证 Expanded 有界。
                  constraints: const BoxConstraints(maxWidth: 420),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 8),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      _AgentArtifactThumb(colorScheme: cs),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // 文件名**不截断到看不清**（用户那张参照图点名的一条）：
                            // 给整段剩余宽度、允许折两行，超过两行才省略。
                            Text(
                              c.fileName,
                              softWrap: true,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: cs.onSurface,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            // 「字节数」这一列永远画（判据层交回的 sizeLabel 恒非空）：
                            // 真机同一秒里同一个路径先写 3 字节、后写 2004 字节，
                            // 少了这一列就分不清点开的是哪一份。
                            Text(
                              c.writes > 1
                                  ? '${c.sizeLabel(zh: zh)}'
                                      ' · ${zh ? '本轮第 ${c.writes} 次写入' : 'write #${c.writes}'}'
                                  : c.sizeLabel(zh: zh),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // 参照图里那枚青色「预览 ›」。**只在 App 内真能渲染时画**：
                      // 用户 02:40 的原话是"不支持的什么都不说，就直接弹一个分享/默认应用打开"
                      // ⇒ 渲染不了的类型连"预览"两个字都不出现，但卡片照画、点了照有反应
                      //   （交给系统那条既有通道）。承诺一件做不到的事，比不承诺更糟。
                      if (artifactShowsPreviewLabel(c)) ...[
                        const SizedBox(width: 6),
                        Text(
                          zh ? '预览 ›' : 'Preview ›',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: cs.primary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 点开卡片：**读盘只走 [WorkspaceService.readText] 这一条既有通道**
  /// （文件管理页预览 html 用的就是它 —— 路径校验、二进制拒绝、1MB 限额、
  /// 30000 字符截断标注都在它里面）。自己 `File(...).readAsString` 就是第二真源，
  /// 那套拒绝/标注会白写（教训 #62，build162 在同一处也写过这条）。
  ///
  /// 读不到 ⇒ **不推路由**，把原因显示出来：卡片是"本轮确实落盘"的断言，
  /// 文件后来被删/被改名是另一件事，那种情况下点开必须是这句话，而不是白屏。
  Future<void> _openAgentArtifact(AgentArtifactCard card, bool zh) async {
    if (_artifactOpening) return; // 读盘是异步的：连点两下不许堆出两趟路由
    _artifactOpening = true;
    String? failure;
    String? body;
    var truncated = false;
    try {
      // 与文件管理页同一把尺子（同一个函数、同一套返回三元组）
      final (content, cut, err) = await WorkspaceService.readText(card.rel);
      body = content;
      truncated = cut;
      failure = err;
    } catch (e) {
      failure = '$e';
    } finally {
      if (mounted) _artifactOpening = false;
    }
    if (!mounted) return;
    final log = LoggerService.instance;
    if (failure != null || body == null || body.trim().isEmpty) {
      final reason = failure ?? (zh ? '读回来是空的' : 'empty content');
      log.warn('HTML 产物卡点开失败：${card.rel}（$reason）', tag: 'HtmlPreview');
      AppSnackBar.showSnackBar(
        context,
        SnackBar(
          content: Text(zh
              ? '预览失败：$reason\n文件：${card.rel}'
              : 'Preview failed: $reason\nFile: ${card.rel}'),
          duration: const Duration(seconds: 5),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    log.info('HTML 产物卡点开：${card.rel}（${card.sizeLabel(zh: zh)}）',
        tag: 'HtmlPreview');
    // build167（用户 26 日 19:02「会闪屏，不到一秒就好」）：**这条入口退回默认路由**。
    // 165（#89）把它接过容器级连续过渡，而那个 shuttle 的形状是
    // 「正文留在原位、容器从它上面盖过去」（见 `app_container_transform.dart:78`）——
    // 目标页主体是**平台视图 WebView**、且进页第一帧就已经把内容画出来了，
    // 于是那 450ms（`AppDur.containerEnter`）里屏幕上是一块**近黑的不透明容器**在长大，
    // 盖在已经看得见的表格上面 ⇒ 他拍到的那张"黑屏"就是飞行中途那一帧。
    // 两头都不该接这个转场：MDC 的 container transform 要求"源与目标是同一个容器"，
    // 而"飞行体内放平台视图"是官方明令避坑的形态（该文件注释自己也写着）。
    // 组件没删 —— 改接到**图片全屏预览**那条路（`_openGeneratedFile`），
    // 那里源与目标真的是同一张图、也不是平台视图。
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => HtmlPreviewScreen(
        html: body!,
        fileName: card.fileName,
        workspaceRel: card.rel,
        truncated: truncated,
      ),
    ));
  }

  /// 第 3 层（用户 2026-09-26 02:40：「不支持的**什么都不说**，就直接弹一个分享
  /// 链接什么之类的，让他打开默认的」）。
  ///
  /// App 内没有能渲染这个类型的页 ⇒ 卡片上连「预览」两个字都不画（不承诺做不到的事），
  /// 但**卡片照画、点了照有反应** —— 反应就是交给系统：走 [WorkspaceService.openExternal]
  /// 这条**既有**通道，不自己调 open_filex。理由与 build138 那条一致：它先过沙箱路径校验，
  /// 而且在本机没有能打开该类型的应用时会**如实回落分享面板**、并把"回落了"回报回来，
  /// 所以用户永远知道刚才发生了什么，不会以为是自己点错了。
  ///
  /// 与 [_openAgentArtifact] 共用同一把 `_artifactOpening` 闩：两条路都不许连点堆出两趟。
  Future<void> _openAgentArtifactExternal(
      AgentArtifactCard card, bool zh) async {
    if (_artifactOpening) return;
    _artifactOpening = true;
    String? err;
    var fellBackToShare = false;
    try {
      final (e, shared) = await WorkspaceService.openExternal(card.rel);
      err = e;
      fellBackToShare = shared;
    } catch (e) {
      // 平台通道抛异常（无 Activity / 权限）也要说清楚，不许点一下没反应
      err = '$e';
    } finally {
      if (mounted) _artifactOpening = false;
    }
    LoggerService.instance.info(
        '产物卡交给系统：${card.rel}（${card.sizeLabel(zh: zh)}）'
        '${err != null ? ' 失败=$err' : (fellBackToShare ? ' 已回落分享面板' : '')}',
        tag: 'Artifact');
    if (!mounted) return;
    if (err != null) {
      AppSnackBar.showSnackBar(
        context,
        SnackBar(
          content: Text(zh
              ? '打不开：$err\n文件：${card.rel}'
              : 'Cannot open: $err\nFile: ${card.rel}'),
          duration: const Duration(seconds: 5),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    if (fellBackToShare) {
      AppSnackBar.showSnackBar(
        context,
        SnackBar(
          content: Text(zh
              ? '本机没有能直接打开它的应用，已改为分享面板'
              : 'No app can open it directly — showed the share sheet instead'),
          duration: const Duration(seconds: 5),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  /// 阶段小结（#82 的 `progressNote` 步骤）：正文样式、可见、不折进思考面板。
  Widget _buildProgressNotes(ThemeData theme) {
    final notes = progressNoteTexts(widget.message.reasoningSteps);
    if (notes.isEmpty) return const SizedBox.shrink();
    final cs = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final n in notes)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              n,
              // 「按正文样式」= 与 MarkdownBody 的 p 同一档（见 [_buildMarkdownStyleSheet]
              // 的 `p: TextStyle(color: cs.onSurface)`），字号走主题默认 bodyMedium。
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: cs.onSurface, height: 1.5),
            ),
          ),
      ],
    );
  }

  // ================= 推荐追问（v1.7.39 build92） =================
  // 待办清单卡片 `_buildTodoCard` 已于 build140（反馈⑥）整体搬到
  // `lib/widgets/chat_todo_strip.dart`（输入框上方常驻条），此处**不留半成品**：
  // 两处各画一份会立刻变成"勾一处、另一处不变"的双真源缺陷。

  /// 推荐追问气泡：AI 用 <suggest> 标签给出，点击直接发送
  Widget _buildSuggestions(ThemeData theme, bool zh) {
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 2),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          for (final q in widget.message.suggestions)
            InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: widget.onQuickReply != null
                  ? () => widget.onQuickReply!(q)
                  : null,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  border: Border.all(
                      color: cs.outlineVariant.withValues(alpha: 0.8)),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  q,
                  style: theme.textTheme.bodySmall?.copyWith(color: cs.primary),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ================= 思考过程：两层嵌套折叠区块（build96 O13 还原旧版形态） =================

  /// 扁平 steps 归并成节点（照搬旧版规则）：
  /// - search 与紧邻的 search_result 配对成一个「联网查找」节点
  /// - mcp_call / skill_call 各成一个节点
  /// - ask_user 各成一个「AI 提问」节点（build140 反馈⑦：问答成对要留痕）
  /// - 其余（thinking 等）合成「思考过程」节点
  static List<_ReasonNodeV2> _mergeNodes(List<ReasoningStep> steps) {
    final nodes = <_ReasonNodeV2>[];
    for (int i = 0; i < steps.length; i++) {
      final s = steps[i];
      // build142：宿主自己发的进度占位（`正在思考是否需要联网搜索…`）**不许**成为一个节点。
      // 折叠面板早就靠 `hasReasoning` 挡住了它，但面板一旦因为别的真实步骤而展开，
      // 这一条就会顶着「思考过程」的标题出现在第一行 —— 用户看到的正是这个假节点。
      if (s.isProgressPlaceholderOnly) continue;
      // build164（#83）：progressNote 也不成为一个节点 —— 它是**给人看的一句话**，
      // 已经由 [_buildProgressNotes] 按正文样式画在面板外面了。留在面板里就是
      // 同一句话同屏两次（一次可见、一次要展开才看见），正是 build140 反馈② 修过的那类重复。
      if (isProgressNoteStep(s)) continue;
      if (s.kind == 'search') {
        final result =
            (i + 1 < steps.length && steps[i + 1].kind == 'search_result')
                ? steps[i + 1]
                : null;
        nodes.add(_ReasonNodeV2(
            type: 'search', step: s, result: result, startIndex: i));
      } else if (s.kind == 'search_result') {
        continue; // 已被前一个 search 节点消费
      } else if (s.kind == 'mcp_call' || s.kind == 'skill_call') {
        nodes.add(
            _ReasonNodeV2(type: s.kind, step: s, result: null, startIndex: i));
      } else if (s.kind == 'ask_user') {
        // build140（反馈⑦ 第 2 条）：反问此前落进 `else` ⇒ 变成一行「思考过程」，
        // 用户回头看不出这一轮 AI 问过自己什么、自己又答了什么（它是这一步里
        // 唯一"有来有回"的节点，混进思考等于抹掉问答对）。
        nodes.add(_ReasonNodeV2(
            type: 'ask_user', step: s, result: null, startIndex: i));
      } else {
        nodes.add(_ReasonNodeV2(
            type: 'thinking', step: s, result: null, startIndex: i));
      }
    }
    return nodes;
  }

  Widget _buildReasoningBlock(ThemeData theme, bool zh) {
    // build164（#83）：面板只吃「思考 / 工具」那几类步骤。progressNote 是给人看的
    // 一句话，已经由 [_buildProgressNotes] 画在正文位置 —— 标题上的「N 步」
    // 与 `_plainReasoning` 的降级正文都必须按同一份列表算，否则同屏两个口径
    // （面板写「3 步」而里面只有 2 个节点，正是 build140 反馈② 那类"加不起来"）。
    final steps = thinkingPanelSteps(widget.message.reasoningSteps);
    final nodes = _mergeNodes(steps);
    final totalMs = steps.length >= 2
        ? steps.last.ts.difference(steps.first.ts).inMilliseconds
        : 0;
    final cs = theme.colorScheme;
    final expandedAll = _expandedPhases.contains('_all');

    // build126：实时计时器的锚点与时效护栏。
    // ① 锚点改为「**本轮**首步」——此前固定用 steps.first.ts（消息里最早一步），
    //    多轮消息显示的是整条消息跨度（第一轮至今），与「本轮思考了多久」语义不符；
    // ② 更要紧的是时效：一旦 isStreaming 因异常卡住（见 build126 状态机修复），
    //    旧消息会显示「思考过程 58225 秒」这种荒谬值（真机日志实锤，锚点停在
    //    09-17 21:33，之后一直涨）。锚点距今超过 kLiveTimerMaxAge 即视为陈旧
    //    → 退回静态文案：宁可不跳动，也不显示假数据。
    // build133（M4 四态）：锚点在「一步都还没有」时改用消息创建时间 ——
    // 此前用 DateTime.now() 当锚点，因为下面又要求 steps.isNotEmpty 才走实时标题，
    // 那条路永远走不到；现在把「首步尚未产生」也纳入实时态（骨架 + 计时 + 呼吸点），
    // 锚点必须是个**稳定值**，否则每帧重建都从 0 开始跳。
    final int liveRound = steps.isEmpty ? 0 : steps.last.round;
    final DateTime liveAnchor = steps.isEmpty
        ? widget.message.createdAt
        : steps
            .firstWhere((s) => s.round == liveRound, orElse: () => steps.last)
            .ts;
    final bool liveFresh =
        DateTime.now().difference(liveAnchor) < kLiveTimerMaxAge;
    final bool liveTitle = widget.isStreaming && liveFresh;
    final Widget title = liveTitle
        ? AppElapsed(
            startTs: liveAnchor,
            zh: zh,
            prefix: zh ? '思考过程' : 'Thinking',
            // build133（M4）：秒数后面接「当前阶段」，让等待有信息量
            stage: _liveStage(steps, zh),
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          )
        : Text(
            (zh
                    ? '思考过程 ${_fmtSec(totalMs, zh)} · ${steps.length} 步'
                    : 'Thinking ${_fmtSec(totalMs, zh)} · ${steps.length} steps') +
                _lastStepSummary(steps),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          );

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 外层大折叠行：箭头 + 标题 + 导出 Markdown
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => setState(() {
              _userToggledManually = true;
              if (expandedAll) {
                _expandedPhases.remove('_all');
              } else {
                _expandedPhases.add('_all');
              }
            }),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  // build134（规格 C2）：箭头不再硬切图标，改**旋转** 0→0.25 turn（90°）。
                  // keyboard_arrow_right 顺时针转 90° 恰好就是 keyboard_arrow_down，
                  // 所以只需一个图标；旧实现切图标是瞬变，和面板 280ms 不同步。
                  AnimatedRotation(
                    turns: expandedAll ? 0.25 : 0,
                    duration: AppMotion.duration(context, AppDur.slow),
                    curve: AppCurve.enter,
                    child: Icon(
                      Icons.keyboard_arrow_right,
                      size: 16,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 2),
                  // build133（M4）：流式态用呼吸点表示「这条流还活着」。计时器已经在
                  // 跳数字，再叠一个转圈就是双重噪声 —— 呼吸点只表达「没卡死」。
                  if (liveTitle) ...[
                    AppPulse(size: 6, color: cs.onSurfaceVariant),
                    const SizedBox(width: 6),
                  ],
                  Expanded(child: title),
                  MessageActionButton(
                    icon: Icons.ios_share,
                    size: 14,
                    tooltip: zh ? '导出 Markdown' : 'Export Markdown',
                    onTap: () => _exportReasoningMarkdown(zh),
                  ),
                ],
              ),
            ),
          ),
          // build134：展开/收起必须有**过程**（280ms / easeOutCubic）。
          // 旧实现是 `if (expandedAll)` 直接增删子树 ⇒ 高度瞬间跳变、内容「啪」地出现。
          // 用 AnimatedSize 而不是 AnimatedCrossFade：这里只要高度平滑过渡，
          // 交叉淡入会把「空盒」那一帧也画出来（展开瞬间闪一下白）。
          // reduced 时 AppMotion 给 Duration.zero ⇒ 直接到位。
          AnimatedSize(
            duration: AppMotion.duration(context, AppDur.slow),
            curve: AppCurve.enter,
            alignment: Alignment.topLeft,
            child: !expandedAll
                ? const SizedBox(width: double.infinity)
                : Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(top: 2),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // build133（M4 四态）：流式但**一步都还没产出** ⇒ 骨架占位，
                        // 给出「这里将出现若干思考节点」的版式预期，而不是一片空白。
                        if (widget.isStreaming && nodes.isEmpty)
                          const AppSkeleton.lines(3, height: 11)
                        // 既没在流、又没有可解析的步骤（历史消息缺 reasoningSteps，
                        // 或解析失败）⇒ 降级为纯文本，至少把模型原文交出去。
                        else if (nodes.isEmpty)
                          Text(
                            _plainReasoning(steps, zh),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: cs.appTextSub,
                              height: 1.5,
                            ),
                          )
                        else ...[
                          // 内层小节点：各自独立折叠
                          for (int i = 0; i < nodes.length; i++)
                            _buildReasoningNode(nodes[i], steps, theme, zh, i),
                          // 末尾小结（纯前端统计，不依赖模型；只报次数不报时长）
                          _buildSummaryLine(nodes, theme, zh),
                        ],
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// build133（M4）：流式态的「当前阶段」文案。
  ///
  /// 只认已知类型，未知类型**返回 null 而不是猜一个词** —— 阶段文案宁缺勿错：
  /// 显示「思考」而实际在检索，比不显示更容易误导（用户会据此判断卡在哪一步）。
  String? _liveStage(List<ReasoningStep> steps, bool zh) {
    if (!widget.isStreaming || steps.isEmpty) return null;
    switch (steps.last.kind) {
      case 'search':
        return zh ? '检索资料' : 'searching';
      case 'thinking':
        return zh ? '思考' : 'thinking';
      // build135：编排路径的阶段都是**已知**类型（不是猜），此前一律落 null
      // ⇒ 编排期间那一行阶段文案整段空缺，看着像卡住。
      case 'context':
        return zh ? '整理上下文' : 'context';
      case 'route':
        return zh ? '路由判断' : 'routing';
      case 'search_queries':
        return zh ? '生成检索词' : 'queries';
      case 'search_results':
        return zh ? '检索命中' : 'results';
      case 'synthesis':
        return zh ? '资料综合' : 'synthesis';
      case 'final_answer':
        return zh ? '生成回答' : 'answering';
      // build146：收口两行的 kind。`unresearched` 是编排中途真会停在最后的一步
      // （检索 0 命中 → 还要继续合成），漏了它那一行阶段文案就空缺，看着像卡住。
      case 'unresearched':
        return zh ? '未经检索' : 'not searched';
      case 'path':
        return zh ? '收尾记账' : 'wrapping up';
      default:
        return null;
    }
  }

  /// build133（M4 降级态）：节点合并不出来时，退回**纯文本**思考过程。
  ///
  /// 为什么要有这一档：`_mergeNodes` 依赖步骤类型与轮次，历史消息（或格式变体）
  /// 可能一条节点也合不出来 —— 此时若继续渲染空面板，用户看到的是一个能展开、
  /// 展开后什么都没有的壳。宁可把原始步骤文本平铺出来，也不给一个空壳。
  String _plainReasoning(List<ReasoningStep> steps, bool zh) {
    final buf = steps
        .map((s) => s.content.trim())
        .where((s) => s.isNotEmpty)
        .join('\n\n');
    if (buf.isNotEmpty) return buf;
    return zh ? '（本轮没有可展示的思考过程）' : '(no reasoning recorded)';
  }

  /// 内层小节点行：小箭头 + 类型图标 + 名称 + 耗时 + 中文状态文字
  Widget _buildReasoningNode(_ReasonNodeV2 n, List<ReasoningStep> steps,
      ThemeData theme, bool zh, int idx) {
    final key = 'n$idx';
    final isExpanded = _expandedPhases.contains(key);
    final cs = theme.colorScheme;

    // build140（反馈②「三个时长口径加不起来」）：节点耗时**测不出就不显示**。
    // 联网查找用 search_result 实测 latencyMs；其余用与下一 step 的时间差。
    // 关键在最后一档：旧实现在「没有下一个 step」时写 0，于是标签显示
    // 「思考过程 · 0.0 秒」——那不是"这一步用了 0 秒"，而是"我们根本不知道"。
    // 真机截图里子节点 0.0 / 0.5 秒与头部 1.0 秒对不上，一半原因就在这里：
    // 一个假零被当成了实测值参与比较。现在这种情形返回 null（标签省掉时长段），
    // null 同时也就是「这一步还在跑」的判据（见下方 showLive）。
    final int? ms;
    if (n.type == 'search' && n.result != null && n.result!.latencyMs != null) {
      ms = n.result!.latencyMs!;
    } else if (n.type != 'search' && n.step.latencyMs != null) {
      ms = n.step.latencyMs!;
    } else if (n.startIndex + 1 < steps.length) {
      ms = steps[n.startIndex + 1]
          .ts
          .difference(steps[n.startIndex].ts)
          .inMilliseconds;
    } else {
      ms = null;
    }

    final String label;
    final IconData icon;
    final Color iconColor;
    if (n.type == 'thinking') {
      label = zh
          ? ['思考过程', if (ms != null) _fmtSec(ms, zh)].join(' · ')
          : ['Thinking', if (ms != null) _fmtSec(ms, zh)].join(' · ');
      icon = Icons.psychology_alt;
      iconColor = cs.onSurfaceVariant;
    } else if (n.type == 'search') {
      final count = n.result?.resultCount ?? 0;
      final running = n.result == null && widget.isStreaming;
      final statusText = running
          ? (zh ? '执行中' : 'Running')
          : (count > 0 ? (zh ? '成功' : 'OK') : (zh ? '失败' : 'Failed'));
      label = zh
          ? [
              '联网查找',
              if (ms != null) _fmtSec(ms, zh),
              statusText
            ].join(' · ')
          : [
              'Web Search',
              if (ms != null) _fmtSec(ms, zh),
              statusText
            ].join(' · ');
      icon = Icons.search;
      iconColor =
          running ? cs.onSurfaceVariant : (count > 0 ? cs.primary : cs.error);
    } else if (n.type == 'ask_user') {
      // build140（反馈⑦ 第 2 条）：参考图里答完之后聊天会留一行「AskUserQuestion …
      // 已回答」的工具状态条。这里同一语义：标签写「AI 提问」，答没答**直接进标签**，
      // 用户不必展开就知道这一轮欠不欠自己一个回答。
      // 未回答**不许**用 error 色：跳过是 build93 就承认的正当选择（O1 据此记
      // skippedAskFps），标成红色等于把用户的决定报成故障。
      final answered = (n.step.resultSummary ?? '').trim().isNotEmpty;
      label = [
        zh ? 'AI 提问' : 'Asked you',
        if (ms != null) _fmtSec(ms, zh),
        answered ? (zh ? '已回答' : 'Answered') : (zh ? '未回答' : 'Skipped'),
      ].join(' · ');
      icon = Icons.help_outline;
      iconColor = answered ? cs.primary : cs.onSurfaceVariant;
    } else {
      final isMcp = n.type == 'mcp_call';
      // build133（⑤）：内置插件名走 i18n 字典（英文界面此前直接显示中文插件名）；
      // 第三方/MCP 插件字典未命中 ⇒ 回退元数据原名，不出现空白。
      final name = pluginDisplayName(
        n.step.pluginId ?? '',
        n.step.pluginName ?? n.step.pluginId ?? (isMcp ? 'MCP' : 'Skill'),
        isZh: zh,
      );
      final target = isMcp ? n.step.toolName : null;
      label = [
        isMcp ? 'MCP · $name' : 'Skill · $name',
        if (target != null) target,
        if (ms != null) _fmtSec(ms, zh),
        _statusLabel(n.step.status, zh),
      ].join(' · ');
      icon = isMcp ? Icons.extension_outlined : Icons.auto_awesome_outlined;
      iconColor = n.step.status == 'running'
          ? cs.onSurfaceVariant
          : (n.step.status == 'success' || n.step.status == 'injected'
              ? cs.primary
              : cs.error);
    }

    // 流式期间正在运行的思考/搜索节点实时计时（时长测不出来 = 这一步还没结束）
    //
    // build141（真机截图「思考过程 910 秒 / 末节点 906 秒」，用户：计时器问题（多次））：
    // `ms == null` 只代表**它是最后一个节点**（没有下一个 step 可作差），
    // **不代表这一步还在跑**。截图那一轮的末节点是编排路径的 `final_answer` 步
    // （内容「已生成回答（528 字）」）—— 答案早就落地了，却因为归进「思考过程」
    // 这一类而按 live 一路涨到 906 秒。用户读到的是「这一步用了 906 秒」，
    // 真实含义却是「这步从 906 秒前开始，我们没测它何时结束」。
    // ⇒ 计时只留给**确实还没产出**的节点：
    //   ① 只有 `kind == 'thinking'`（模型正在想/正在吐字）或 `search`（等搜索结果）
    //      允许 live；`final_answer` / `synthesis` / `route` / `context` 这些
    //      **账本行本身就是完成标记**，不许再涨。
    //   ② 该步已有 `resultSummary` 或 `status` 已是终态 ⇒ 同样不许计时。
    // 不满足时按 build140 反馈② 的口径显示「测不出」（标签里省掉时长段），
    // 而不是继续跳一个只会变大的数。
    final stepFinished = (n.step.resultSummary ?? '').trim().isNotEmpty ||
        n.step.status == 'success' ||
        n.step.status == 'injected' ||
        n.step.status == 'failed';
    final liveEligible = n.type == 'search' || n.step.kind == 'thinking';
    final showLive = widget.isStreaming &&
        ms == null &&
        liveEligible &&
        !stepFinished;

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Container(
        decoration: BoxDecoration(
          color: cs.surface.withValues(alpha: 0.6),
          border: Border.all(color: theme.dividerColor.withValues(alpha: 0.3)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => setState(() {
                _userToggledManually = true;
                if (isExpanded) {
                  _expandedPhases.remove(key);
                } else {
                  _expandedPhases.add(key);
                }
              }),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  children: [
                    // build134（规格 C2）：内层节点箭头同样走旋转（与外层同一时长）
                    AnimatedRotation(
                      turns: isExpanded ? 0.25 : 0,
                      duration: AppMotion.duration(context, AppDur.slow),
                      curve: AppCurve.enter,
                      child: Icon(
                        Icons.keyboard_arrow_right,
                        size: 15,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 3),
                    Icon(icon, size: 14, color: iconColor),
                    const SizedBox(width: 6),
                    Expanded(
                      child: showLive
                          ? AppElapsed(
                              startTs: steps[n.startIndex].ts,
                              zh: zh,
                              prefix: n.type == 'thinking'
                                  ? (zh ? '思考过程' : 'Thinking')
                                  : (zh ? '联网查找' : 'Web Search'),
                              style: theme.textTheme.labelSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: cs.onSurfaceVariant,
                              ),
                            )
                          : Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
            // build134（规格 C2）：内层节点折叠走 AnimatedCrossFade（base 200ms）。
            // 这里用 CrossFade 而外层用 AnimatedSize：内层是「一次性内容替换」，
            // 交叉淡入给出「正文浮上来」的过程；外层是整体高度，纯尺寸过渡更干净。
            AnimatedCrossFade(
              duration: AppMotion.duration(context, AppDur.base),
              sizeCurve: AppCurve.enter,
              firstCurve: AppCurve.exit,
              secondCurve: AppCurve.enter,
              alignment: Alignment.topLeft,
              crossFadeState: isExpanded
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              firstChild: const SizedBox(width: double.infinity),
              secondChild: Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                child: _buildNodeContent(n, theme, zh),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 节点展开内容：thinking=斜体正文；mcp/skill=插件/工具/状态/参数/结果；search=搜索词+结果数+来源列表
  Widget _buildNodeContent(_ReasonNodeV2 n, ThemeData theme, bool zh) {
    final cs = theme.colorScheme;
    if (n.type == 'thinking') {
      final content = n.step.content.trim();
      if (content.isEmpty) return const SizedBox.shrink();
      return Align(
        alignment: Alignment.centerLeft,
        child: Text(
          content,
          style: theme.textTheme.bodySmall?.copyWith(
            color: cs.onSurface.withValues(alpha: 0.78),
            fontStyle: FontStyle.italic,
            height: 1.35,
          ),
        ),
      );
    }
    if (n.type == 'ask_user') {
      // 问 ↔ 答成对：上面那行是「AI 问了什么 + 给了哪几个选项」（addReasoningStep
      // 的 content 原样），下面是「你答了什么」。没答就**只出问题那一行**，
      // 不留「回答：（空）」这种半空槽。
      final question = n.step.content.trim();
      final answer = (n.step.resultSummary ?? '').trim();
      if (question.isEmpty && answer.isEmpty) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (question.isNotEmpty)
            Text(
              '${zh ? '问' : 'Q'}：$question',
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.78),
              ),
            ),
          if (answer.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '${zh ? '你的回答' : 'Your answer'}：$answer',
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.68),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      );
    }
    if (n.type == 'mcp_call' || n.type == 'skill_call') {
      final step = n.step;
      final isMcp = n.type == 'mcp_call';
      // build133（⑤）：同上 —— 详情行里的插件名也走 i18n 字典。
      final pluginLabel = pluginDisplayName(
        step.pluginId ?? '',
        step.pluginName ?? step.pluginId ?? '-',
        isZh: zh,
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isMcp
                ? '${zh ? '插件' : 'Plugin'}：$pluginLabel\n${zh ? '工具' : 'Tool'}：${step.toolName ?? '-'}'
                : 'Skill：$pluginLabel',
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSurface.withValues(alpha: 0.78),
            ),
          ),
          if (step.arguments?.trim().isNotEmpty == true) ...[
            const SizedBox(height: 4),
            Text(
              '${zh ? '参数' : 'Arguments'}\n${step.arguments}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.68),
                fontFamily: 'monospace',
              ),
            ),
          ],
          if (step.resultSummary?.trim().isNotEmpty == true) ...[
            const SizedBox(height: 4),
            _ExpandableResultV2(
              content: '${zh ? '结果' : 'Result'}\n${step.resultSummary}',
              theme: theme,
              zh: zh,
            ),
          ],
        ],
      );
    }
    // search 节点：搜索动作 + 结果摘要 + 来源列表（可再展开）
    final result = n.result;
    final count = result?.resultCount ?? 0;
    final doneLine = result != null
        ? (zh ? '完成：返回 $count 条结果' : 'Done: $count results')
        : (zh ? '未完成' : 'Incomplete');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          n.step.content,
          style: theme.textTheme.bodySmall?.copyWith(
            color: cs.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          doneLine,
          style: theme.textTheme.labelSmall?.copyWith(
            color: count > 0 ? cs.primary : cs.error,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (result != null && result.content.trim().isNotEmpty && count > 0)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: _ExpandableResultV2(
              content: result.content.trim(),
              theme: theme,
              zh: zh,
            ),
          ),
      ],
    );
  }

  /// build96 (O13)：末尾小结——按归并节点统计，如「联网 2 次（成功 2）· MCP 1 次（成功 1）」
  ///
  /// build140（反馈②）：这里**不再报时长**。小结原先固定挂一句思考总时长，
  /// 算法是「整条消息首步→末步」；面板头部（流式态）却是「本轮首步→现在」。
  /// 同一轮里两个数不同源、不同终点，用户按字面理解就是「三个口径加不起来」
  /// （0.0 / 0.5 / 1.0 那组）。按教训 #62，同一个语义只留一个实现：
  /// 时长只由面板头部负责，小结只统计次数。
  /// 相应地，若一个可统计的调用节点都没有（纯思考轮），整行不再渲染——
  /// 否则只剩「小结：」三个字，比没有更像坏掉了。
  Widget _buildSummaryLine(
      List<_ReasonNodeV2> nodes, ThemeData theme, bool zh) {
    final cs = theme.colorScheme;
    final searches = nodes.where((n) => n.type == 'search').toList();
    final mcps = nodes.where((n) => n.type == 'mcp_call').toList();
    final skills = nodes.where((n) => n.type == 'skill_call').toList();
    int okCount(List<_ReasonNodeV2> list) => list
        .where((n) =>
            n.step.status == 'success' ||
            n.step.status == 'injected' ||
            (n.type == 'search' && (n.result?.resultCount ?? 0) > 0))
        .length;
    final parts = <String>[
      if (searches.isNotEmpty)
        zh
            ? '联网 ${searches.length} 次（成功 ${okCount(searches)}）'
            : 'Search ×${searches.length} (ok ${okCount(searches)})',
      if (mcps.isNotEmpty)
        zh
            ? 'MCP ${mcps.length} 次（成功 ${okCount(mcps)}）'
            : 'MCP ×${mcps.length} (ok ${okCount(mcps)})',
      if (skills.isNotEmpty)
        zh
            ? 'Skill ${skills.length} 次（成功 ${okCount(skills)}）'
            : 'Skill ×${skills.length} (ok ${okCount(skills)})',
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        '${zh ? '小结' : 'Summary'}：${parts.join(' · ')}',
        style: theme.textTheme.labelSmall?.copyWith(
          color: cs.onSurfaceVariant.withValues(alpha: 0.8),
        ),
      ),
    );
  }

  /// 中文状态文字（替代旧版 emoji ✓/✗/…）
  static String _statusLabel(String status, bool zh) {
    switch (status) {
      case 'running':
        return zh ? '执行中' : 'Running';
      case 'success':
        return zh ? '成功' : 'OK';
      case 'injected':
        return zh ? '已注入' : 'Injected';
      case 'rejected':
        return zh ? '已拒绝' : 'Rejected';
      case 'not_found':
        return zh ? '未找到' : 'Not found';
      case 'invalid':
        return zh ? '参数无效' : 'Invalid';
      case 'failed':
        return zh ? '失败' : 'Failed';
      default:
        return zh ? '已记录' : 'Recorded';
    }
  }

  /// v1.7.39（build92）：折叠标题尾部摘要——最后一步内容的单行截断
  ///
  /// build113 修复「标题第一行太长」：steps.last 常是流式进度占位行
  /// （🧠 思考中…（轮次 1/30，自动档 high）），逐行剔除占位后再取摘要；
  /// 剩不下真实文本就不拼摘要，标题只留「思考过程 X秒 · N 步」。
  static String _lastStepSummary(List<ReasoningStep> steps) {
    if (steps.isEmpty) return '';
    for (final s in steps.reversed) {
      if (s.kind != 'thinking') continue;
      final real = s.content
          .split('\n')
          .where((line) => line.trim().isNotEmpty)
          .where((line) => !(line.contains('🧠') ||
              line.contains('📦') ||
              line.contains('📩') ||
              line.contains('思考中…') ||
              RegExp(r'Thinking\.\.\.').hasMatch(line)))
          .join(' ')
          .trim()
          .replaceAll(RegExp(r'\s+'), ' ');
      if (real.isEmpty) continue;
      final cut = real.length <= 24 ? real : '${real.substring(0, 24)}…';
      return ' · $cut';
    }
    return '';
  }

  /// 导出思考过程为 Markdown（复制到剪贴板）——与旧皮肤能力对齐
  void _exportReasoningMarkdown(bool zh) {
    final steps = widget.message.reasoningSteps;
    final buf = StringBuffer();
    buf.writeln(zh ? '## 思考过程' : '## Thinking');
    for (final s in steps) {
      // build142：导出与面板同一判据（判据见 ReasoningStep.isProgressPlaceholderOnly）。
      // 真机反馈「第一个为啥会思考标签」＝这里以前不筛，占位行被原样导出成一步思考。
      if (s.isProgressPlaceholderOnly) continue;
      final label = switch (s.kind) {
        'search' => zh ? '联网查找' : 'Web search',
        'search_result' => zh ? '搜索结果' : 'Search result',
        'mcp_call' => 'MCP ${s.toolName ?? ''}',
        // build133（⑤）：导出的「思考过程」也是用户可见内容 ⇒ 插件名同样走字典
        'skill_call' => 'Skill ${pluginDisplayName(s.pluginId ?? '', s.pluginName ?? '', isZh: zh)}',
        'todo' => zh ? '待办清单' : 'Todo',
        // build140（反馈⑦）：导出的思考过程里反问也不能顶成「思考」——
        // 那正是 build135 修掉的那类"看不出这一步做了什么"。
        'ask_user' => zh ? 'AI 提问' : 'Asked you',
        'memory_write' => zh ? '写入记忆' : 'Memory write',
        // build135：编排路径的步骤此前**全部**落进 default 兜底成「思考」——
        // 真机导出 1:1 复现：一行「正在编排」+ 一行「本轮上下文」+ 一行「路由判断」
        // + 一行「已生成回答」，四行同名「思考」，等于看不出这一轮做了什么。
        // 这里把编排器实际 emit 的 kind（agent_orchestrator.dart）逐个命名。
        'context' => zh ? '上下文' : 'Context',
        'route' => zh ? '路由' : 'Routing',
        'search_queries' => zh ? '检索词' : 'Queries',
        'search_results' => zh ? '检索结果' : 'Search results',
        'synthesis' => zh ? '资料综合' : 'Synthesis',
        'final_answer' => zh ? '生成回答' : 'Answer',
        // build146（透明度）：本轮"走了哪条路 / 到底查没查"两类收口行。
        // 没有它们的话导出的思考过程会把它兜底成「思考」，正是 build135 修过的毛病。
        'path' => zh ? '本轮路径' : 'Round path',
        'unresearched' => zh ? '未经检索' : 'Not searched',
        // build164（#83）：#82 的新 kind。导出里也必须有名有姓 —— 它兜底成「思考」
        // 就是 build135 修过的那毛病复发（一连串同名标题看不出这步做了什么）。
        'progressNote' => zh ? '阶段小结' : 'Progress note',
        _ => zh ? '思考' : 'Thinking',
      };
      final ts = s.ts.toLocal().toString().substring(11, 19);
      buf.writeln('\n### [$ts] $label');
      if (s.content.trim().isNotEmpty) buf.writeln(s.content.trim());
      final rs = s.resultSummary ?? '';
      if (rs.isNotEmpty) buf.writeln('> $rs');
    }
    Clipboard.setData(ClipboardData(text: buf.toString()));
    AppSnackBar.showSnackBar(
        context,
        SnackBar(
          content: Text(zh
              ? '思考过程 Markdown 已复制到剪贴板'
              : 'Thinking Markdown copied to clipboard'),
          duration: const Duration(seconds: 1),
          behavior: SnackBarBehavior.floating,
        ));
  }

  // ================= 样式 / footnote / 附件 =================

  MarkdownStyleSheet _buildMarkdownStyleSheet(ThemeData theme, bool isUser) {
    final cs = theme.colorScheme;
    return MarkdownStyleSheet(
      p: TextStyle(color: cs.onSurface),
      code: TextStyle(
        backgroundColor: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        color: cs.onSurface,
      ),
      codeblockDecoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(8),
      ),
      a: TextStyle(color: cs.secondary),
      blockquote: TextStyle(color: cs.onSurface, fontSize: 14, height: 1.5),
      blockquoteDecoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
        border: Border(
          left: BorderSide(color: cs.outlineVariant, width: 3),
        ),
        borderRadius: BorderRadius.circular(4),
      ),
      blockquotePadding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
    );
  }

  bool _hasFootnote(ChatMessage m) {
    // MN-1：模型名不再构成 footnote 显示条件（气泡内模型名唯一权威是 metaRow）
    return m.showStaleFootnote ||
        m.injectedWebSearchCount > 0 ||
        m.promptTokens != null ||
        m.completionTokens != null ||
        m.totalTokens != null ||
        m.cacheReadTokens != null ||
        m.cacheWriteTokens != null ||
        m.cacheHitTokens != null ||
        m.cacheMissTokens != null;
  }

  Widget _buildFootnote(ThemeData theme, ChatMessage m, bool zh) {
    final cs = theme.colorScheme;
    final style = TextStyle(
      fontSize: 10.5,
      color: cs.onSurfaceVariant.withValues(alpha: 0.5),
      height: 1.25,
    );
    // G65④（build136）：先把可渲染项收进 list，一条都没有就整块不渲染。
    // 原因：_hasFootnote 只看「有没有 token 数据」、不看「开关开没开」，于是
    // showTokenUsage=false 且只有 token 数据时会渲染出一个空 Wrap，在气泡底部
    // 留下 6px 空白（真机表现为「这条消息莫名比别的消息高一点」）。
    final items = <Widget>[
      if (m.showStaleFootnote)
        Text(
          zh
              ? '基于 AI 内置知识生成，可能已过时。'
              : 'Generated from AI training data, may be outdated.',
          style: style,
        ),
      // build129：加合理性上界——历史脏值（魔数哨兵 999999999）曾在此
      // 渲成「已联网注入 999999999 条搜索结果」，根因虽已修，展示端仍兜底。
      if (m.injectedWebSearchCount > 0 &&
          m.injectedWebSearchCount <= ChatMessage.maxSaneSearchHits)
        Text(
          zh
              ? '已联网注入 ${m.injectedWebSearchCount} 条搜索结果'
              : 'Live web search injected ${m.injectedWebSearchCount} results',
          style: style,
        ),
      // MN-1：footnote 只保留 metaRow 没有的增量明细 ↑↓ 与缓存读/写/命中率，
      // 总 token 一律由 metaRow 唯一显示；整段受 showTokenUsage 门控。
      // C3（G29）：明细改为**默认折叠**——总量已在 metaRow 显示一次，
      // 此处再平铺「Tokens: ↑x + ↓y」是同屏重复。点「详情」展开。
      // G65②（build136）：条件里补 totalTokens —— 此前只回总量的模型
      // （prompt/completion 均为 null）连「token 详情」入口都渲染不出来。
      if (widget.showTokenUsage &&
          (m.promptTokens != null ||
              m.completionTokens != null ||
              m.totalTokens != null ||
              m.cacheReadTokens != null ||
              m.cacheWriteTokens != null ||
              m.cacheHitTokens != null) &&
          !_showTokenDetail)
        // build175 平板遍历：这一条实测 41.5×11.0dp（语义树里它就是那行 11 号字的
        // 高度）—— 等于"只有字本身能点"，手指压在它上下 1dp 之外就不响应。
        // 两处都是必要的，缺一个就是假修复：
        //  · `behavior: opaque`：GestureDetector 默认 deferToChild，只在**子节点自己**
        //    那块地方响应；不写这一句，补出来的空白只是把行撑高，仍然点不中。
        //  · 高度用 padding 给、外层再垫一个 48 的下限：下限保证字号缩放后仍然 ≥48，
        //    而这里**不用 Center** —— metaRow 是 Wrap，Center 会把条目撑到整行宽，
        //    每个条目各占一行，等于把这一行拆散。
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _showTokenDetail = true),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 18),
              child: Text(
                zh ? 'token 详情' : 'token details',
                style: style.copyWith(
                  decoration: TextDecoration.underline,
                  decorationStyle: TextDecorationStyle.dotted,
                ),
              ),
            ),
          ),
        ),
      // G65②（build136）：展开区拆成两支 ——
      // 有 ↑↓ 明细就显示明细（总量已在 metaRow 显示过一次，这里不再重复）；
      // 只有总量时给一句说明，而不是渲染「↑— + ↓—」这种看着像坏掉的破折号。
      if (widget.showTokenUsage &&
          _showTokenDetail &&
          (m.promptTokens != null || m.completionTokens != null))
        Text(
          'Tokens: ↑${m.promptTokens ?? '—'} + ↓${m.completionTokens ?? '—'}',
          style: style,
        ),
      if (widget.showTokenUsage &&
          _showTokenDetail &&
          m.promptTokens == null &&
          m.completionTokens == null &&
          m.totalTokens != null)
        Text(
          zh
              ? '总量 ${m.totalTokens}（上游未返回明细）'
              : 'Total ${m.totalTokens} (no breakdown from upstream)',
          style: style,
        ),
      if (widget.showTokenUsage && _showTokenDetail && m.cacheReadTokens != null)
        Text(
          zh ? '缓存读取: ${m.cacheReadTokens}' : 'Cache read: ${m.cacheReadTokens}',
          style: style,
        ),
      if (widget.showTokenUsage &&
          _showTokenDetail &&
          m.cacheWriteTokens != null)
        Text(
          zh
              ? '缓存写入: ${m.cacheWriteTokens}'
              : 'Cache write: ${m.cacheWriteTokens}',
          style: style,
        ),
      if (widget.showTokenUsage &&
          _showTokenDetail &&
          m.cacheHitTokens != null &&
          m.cacheMissTokens != null &&
          m.cacheHitTokens! + m.cacheMissTokens! > 0)
        Text(
          zh
              ? '缓存命中率: ${(m.cacheHitTokens! * 100 / (m.cacheHitTokens! + m.cacheMissTokens!)).toStringAsFixed(1)}%'
              : 'Cache hit rate: ${(m.cacheHitTokens! * 100 / (m.cacheHitTokens! + m.cacheMissTokens!)).toStringAsFixed(1)}%',
          style: style,
        ),
      // MN-1：删除 footnote 末尾的 modelName 段——模型名唯一权威在 metaRow
    ];
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(spacing: 8, runSpacing: 2, children: items),
    );
  }

  /// build122：渲染 AI 生成产物（图片/视频）。
  ///
  /// 与 [_buildAttachmentPreview] 的差别（刻意分开，不合并）：
  /// - 附件是**用户提供的输入**（会被回灌进 API）；生成产物是**模型的输出**，只做本地展示；
  /// - 生成的图是「成果」，所以给**更大的尺寸 + 可点开看全屏**，而不是附件的 80×80 缩略图
  ///   （build163 起缩略图也可点开同一个全屏看图器，尺寸差是"成果 vs 输入"的表达，
  ///    不再是"能点 vs 不能点"）。
  /// - 视频用 🎬 占位卡（点开走系统播放器），避免在消息列表里内联解码多路视频。
  Widget _buildGeneratedFiles(ThemeData theme, bool zh) {
    final files = widget.message.generatedFiles;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final path in files)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _buildGeneratedItem(theme, zh, path),
            ),
        ],
      ),
    );
  }

  Widget _buildGeneratedItem(ThemeData theme, bool zh, String path) {
    final scheme = theme.colorScheme;
    final isVideo = path.toLowerCase().endsWith('.mp4') ||
        path.toLowerCase().endsWith('.mov');
    final file = File(path);

    if (isVideo) {
      return InkWell(
        onTap: () => _openGeneratedFile(path, isVideo: true),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.movie_outlined, size: 20, color: scheme.primary),
              const SizedBox(width: 8),
              Text(
                zh ? '生成的视频（点击播放）' : 'Generated video (tap to play)',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      );
    }

    // 图片：最大 240 高，保持比例；点开看全屏
    return InkWell(
      onTap: () => _openGeneratedFile(path, isVideo: false),
      borderRadius: BorderRadius.circular(10),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 240),
          child: Image.file(
            file,
            fit: BoxFit.contain,
            // build138（扫描 P2-4）：生成的图片按 DPR×屏宽限宽解码。
            // 这里宽度不固定（ConstrainedBox 只限高 240），故取屏宽作上限口径——
            // 渲染宽度不可能超过屏幕，比不限宽解码 4000px 原图省一个数量级。
            cacheWidth: decodeCacheWidth(context, MediaQuery.of(context).size.width),
            errorBuilder: (_, __, ___) => Container(
              padding: const EdgeInsets.all(12),
              color: scheme.surfaceContainerHighest,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.broken_image_outlined,
                      size: 18, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Text(
                    zh ? '图片已丢失（文件不存在）' : 'Image missing',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 打开生成产物：图片走内置全屏预览（零新依赖），视频交系统播放器。
  ///
  /// 为什么图片不直接交系统：用户刚生成完就想看，多一步「选应用」很烦；
  /// 视频则相反——内联播放器要额外依赖与解码开销，交系统更稳。
  ///
  /// build163：聊天里的**图片附件**也走这一条（它是全仓唯一一面内置看图器，
  /// 为附件另写第二份 = 教训 #62）。附件永远是本地文件，`isVideo` 恒为 false。
  void _openGeneratedFile(String path, {required bool isVideo}) {
    final root = Navigator.of(context, rootNavigator: true);
    if (isVideo) {
      unawaited(BiometricService.guardActivityTransition(
        () => FileOpenService.open(path),
        fallbackDuration: const Duration(seconds: 120),
      ));
      return;
    }
    root.push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black87,
        pageBuilder: (ctx, _, __) => GestureDetector(
          onTap: () => Navigator.of(ctx).pop(),
          child: InteractiveViewer(
            maxScale: 5,
            child: Center(
              child: Image.file(
                File(path),
                errorBuilder: (_, __, ___) => const Icon(
                  Icons.broken_image_outlined,
                  color: Colors.white70,
                  size: 48,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// build163：附件卡片**整张可点**（用户 20:49 的截图：聊天里点那张 `.html` 卡片，
  /// 应用内打不开 ⇒ 能力等于不存在。build162 只在文件管理页那条既有分派上加了分支，
  /// 而用户最常用的路径是聊天里这张卡片）。判据不住在这里，在 `attachment_tap.dart`。
  ///
  /// 三条来源逐条核对过（结论也写进了判据文件的注释里）：
  ///  · **用户选/分享进来的 `.html`**：内容在 `extractedText` 里 ⇒ 走 build162 的
  ///    [HtmlPreviewScreen]（与气泡操作行那枚「预览」同一个入口口径 [_openHtmlPreview]，
  ///    不复制一份读文件逻辑——这一类附件**根本没有路径可读**）；
  ///  · **图片附件**：带 `localPath` ⇒ 走本文件既有的内置看图 [_openGeneratedFile]
  ///    （build122 为生成图写的那一条，不为附件另写第二套）。缩略图本身就是可点的
  ///    视觉语言（生成图卡片同样没有额外提示），且 80×80 已远大于 40dp 命中区口径，
  ///    所以这一支**不加**「预览」字样；
  ///  · **其余（pdf / docx / xlsx / csv / 纯文本…）**：只有抽取出的文本、**没有文件路径**
  ///    （`AttachmentService._processTextFile` 那一批从不写 localPath），App 里也没有
  ///    任何一面能展示抽取文本的页 ⇒ 保持不可点。做成可点就是假入口，
  ///    而"点开是空白/报错"比"压根点不动"更让用户以为是自己操作错了；
  ///  · **模型工作区落盘的 html 不从这里走**：助手消息从来不带 attachments
  ///    （全库几处写入点 —— `chat_screen_message.dart` 发送时把待发附件挂上去、
  ///    `chat_screen_orchestrator.dart` 的编排副本 —— 落的都是**用户角色**的消息），
  ///    模型产物走 `generatedFiles`（只有图片/视频，本就可点）与文件管理页 /
  ///    气泡「预览」按钮那两条 162 的路。
  ///  · **待发附件那一排**（输入框上方）画在 `lib/widgets/chat_input.dart`，
  ///    本批禁区 ⇒ 这一处**不做**，不留"注释承诺了但没人实现"的分支。
  Widget _buildAttachmentPreview(ThemeData theme, bool zh) {
    final m = widget.message;
    final onCol = theme.colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: m.attachments.map((a) {
          final imgPath = attachmentImagePath(a);
          // 「是不是图片、有没有本地路径」这道判据只在 attachment_tap.dart 里写一遍
          if (imgPath != null) {
            // 整张缩略图就是命中区（80×80，远大于 40dp 口径）：InkWell 内部那个
            // GestureDetector 本就是 `HitTestBehavior.opaque`，图片没铺满/加载失败时
            // 那块底也吃点击 —— 点它同样有反应。
            return InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => _openGeneratedFile(imgPath, isVideo: false),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.file(
                  File(imgPath),
                  width: 80,
                  height: 80,
                  // build138（扫描 P2-4）：附件缩略图同样限宽（样板见 build129 头像）
                  cacheWidth: decodeCacheWidth(context, 80),
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    width: 80,
                    height: 80,
                    color: theme.colorScheme.surfaceContainerHighest,
                    child: Icon(_iconFor(a), color: onCol),
                  ),
                ),
              ),
            );
          }
          final htmlBody = attachmentHtmlBody(a);
          final onTap = htmlBody == null
              ? null
              : () => _openHtmlPreview(htmlBody, fileName: a.fileName);
          final card = Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(6),
            ),
            // build156/157/161/162 同一口径：命中区**只补高不撑宽**（这一排是 Wrap，
            // 卡片宽由内容定，横向撑宽会顶出 OVERFLOWED）。minHeight 40 = 整张卡片。
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 40),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(_iconFor(a), size: 14, color: onCol),
                  const SizedBox(width: 4),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 100),
                    child: Text(
                      a.fileName,
                      style: TextStyle(fontSize: 11, color: onCol),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // 可点提示：只在**真的可点**时画（画在一个点不动的卡片上就是假入口）
                  if (onTap != null) ...[
                    const SizedBox(width: 6),
                    Text(
                      zh ? '预览' : 'Preview',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: theme.colorScheme.primary),
                    ),
                  ],
                ],
              ),
            ),
          );
          if (onTap == null) return card;
          return InkWell(
            borderRadius: BorderRadius.circular(6),
            // 整张卡片可点：InkWell 内部那个 GestureDetector 本就是
            // `HitTestBehavior.opaque`，Container 那一圈 padding 也吃点击。
            // （换成 GestureDetector + deferToChild 的写法点 padding 就是"没反应"，
            //  正是这次要消灭的形状。）
            onTap: onTap,
            child: card,
          );
        }).toList(),
      ),
    );
  }

  IconData _iconFor(MessageAttachment a) {
    switch (a.type) {
      case AttachmentType.image:
        return Icons.image_outlined;
      case AttachmentType.text:
        return Icons.description_outlined;
      case AttachmentType.doc:
        return Icons.article_outlined;
    }
  }

  // ================= HTML 剥离（与旧皮肤一致） =================

  String _preprocessHtmlDivs(String content) {
    final parts = content.split('```');
    if (parts.length == 1) return _stripHtmlTags(content);
    final buf = <String>[];
    for (var i = 0; i < parts.length; i++) {
      buf.add(i.isOdd ? parts[i] : _stripHtmlTags(parts[i]));
    }
    return buf.join('```');
  }

  String _stripHtmlTags(String content) {
    var result = content;
    for (int i = 0; i < 3; i++) {
      final prev = result;
      result = result.replaceAllMapped(
        RegExp(
            r'<(?:div|blockquote|section|aside|figure|article|fieldset|details|summary)[^>]*>([\s\S]*?)</(?:div|blockquote|section|aside|figure|article|fieldset|details|summary)>'),
        (m) {
          final inner = m.group(1)!.trim();
          if (inner.isEmpty) return '';
          return '\n${inner.split('\n').map((l) => '> $l').join('\n')}\n';
        },
      );
      if (result == prev) break;
    }
    result = result.replaceAllMapped(
      RegExp(
          r'<(span|font|mark|em|strong|b|i|p|code|pre|label|small|sub|sup|u|s|h[1-6])\s+[^>]*(?:style|color)[^>]*>([\s\S]*?)</\1>'),
      (m) => m.group(2)!.trim(),
    );
    result = result.replaceAllMapped(
      RegExp(r'<(\w+)[^>]*style="[^"]*"[^>]*>([\s\S]*?)</\1>'),
      (m) => m.group(2)!.trim(),
    );
    result =
        result.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    result = result.replaceAll(
        RegExp(r'<hr\s*/?>', caseSensitive: false), '\n---\n');
    result = result.replaceAll(RegExp(r'</?[a-zA-Z][^>]*>'), '');
    return result;
  }

  Future<void> _onTapLink(String text, String? href, String title) async {
    final url = href ?? '';
    if (url.isEmpty) return;
    final l = AppLocalizations.of(context);
    final isZh = l.locale.languageCode == 'zh';
    final cs = Theme.of(context).colorScheme;
    // SB-3：同类弹层防叠——快速连点链接不再叠多层
    if (!GuardedOverlay.tryEnter('link_sheet')) return;
    try {
      return await _showLinkSheet(url, isZh, cs);
    } finally {
      GuardedOverlay.exit('link_sheet');
    }
  }

  Future<void> _showLinkSheet(String url, bool isZh, ColorScheme cs) async {
    // build126 (B2)：裸 showModalBottomSheet → 统一入口 showAppSheet。
    // 原先 URL 直接当标题（等宽字体两行省略），现补上 AppSheetHeader 一级标题，
    // 与其它弹层对齐；安全区/圆角/拖拽手柄也一并交给 AppSheet。
    await showAppSheet<void>(
      context: context,
      scrollable: true,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppSheetHeader(title: isZh ? '链接操作' : 'Link actions'),
          // showAppSheet 自身不带滚动，用 Flexible 兜住
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text(
                      url,
                      style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurfaceVariant,
                          fontFamily: 'monospace'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: Icon(Icons.open_in_new, color: cs.primary),
                    title: Text(isZh ? '在浏览器中打开' : 'Open in browser'),
                    onTap: () async {
                      Navigator.pop(ctx);
                      // W3：统一走 LauncherUtils（内部含生物锁守卫 + 中文 percent-encode
                      // + 成功/失败日志），不再各写一份 launchUrl
                      {
                        try {
                          final ok = await LauncherUtils.openExternalUrl(url);
                          if (mounted && ok != true) {
                            AppSnackBar.showSnackBar(
                              context,
                              SnackBar(
                                content: Text(isZh
                                    ? '未能唤起目标应用（可能未安装，链接已可复制）'
                                    : 'Could not open the target app (it may not be installed)'),
                                duration: const Duration(seconds: 3),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          }
                        } catch (e) {
                          debugPrint('launchUrl failed: $e');
                          if (mounted) {
                            AppSnackBar.showSnackBar(
                              context,
                              SnackBar(
                                content: Text(isZh
                                    ? '未能唤起目标应用（可能未安装，链接已可复制）'
                                    : 'Could not open the target app (it may not be installed)'),
                                duration: const Duration(seconds: 3),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          }
                        }
                      }
                    },
                  ),
                  ListTile(
                    leading: Icon(Icons.copy, color: cs.primary),
                    title: Text(isZh ? '复制链接' : 'Copy link'),
                    onTap: () async {
                      Navigator.pop(ctx);
                      await Clipboard.setData(ClipboardData(text: url));
                      if (mounted) {
                        AppSnackBar.showSnackBar(
                          context,
                          SnackBar(
                            content: Text(isZh ? '已复制链接' : 'Link copied'),
                            duration: const Duration(seconds: 1),
                          ),
                        );
                      }
                    },
                  ),
                  ListTile(
                    leading: Icon(Icons.close, color: cs.onSurfaceVariant),
                    title: Text(AppLocalizations.of(context).tr('cancel')),
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

  String _fmtSec(int ms, bool zh) {
    final s = ms / 1000.0;
    final str = s < 10 ? s.toStringAsFixed(1) : s.round().toString();
    return zh ? '$str 秒' : '${str}s';
  }
}

/// 从 markdown 正文中提取 `<error>...</error>` 块。
/// 返回 (剥离错误块后的正文, 错误原文或 null)。
(String, String?) _splitErrorBlock(String md) {
  final re = RegExp(r'<error>([\s\S]*?)</error>');
  final match = re.firstMatch(md);
  if (match == null) return (md, null);
  final errorText = (match.group(1) ?? '').trim();
  final cleaned = md.replaceFirst(match.group(0)!, '').trim();
  return (cleaned, errorText.isEmpty ? null : errorText);
}

/// 可折叠错误卡片：默认收起显示「⚠️ 出错了」，展开显示原始错误信息。
class _ErrorCollapsibleCard extends StatefulWidget {
  const _ErrorCollapsibleCard({required this.error, required this.zh});
  final String error;
  final bool zh;

  @override
  State<_ErrorCollapsibleCard> createState() => _ErrorCollapsibleCardState();
}

class _ErrorCollapsibleCardState extends State<_ErrorCollapsibleCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 4),
      decoration: BoxDecoration(
        color: cs.errorContainer.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.error.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.error_outline, size: 18, color: cs.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.zh
                          ? '出错了，点击展开详情'
                          : 'Error occurred, tap to expand',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.error,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                    color: cs.error,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Divider(height: 1, color: cs.error.withValues(alpha: 0.2)),
                  const SizedBox(height: 8),
                  SelectableText(
                    widget.error,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurface.withValues(alpha: 0.8),
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(height: 6),
                  GestureDetector(
                    onTap: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      await Clipboard.setData(
                          ClipboardData(text: widget.error));
                      if (mounted) {
                        messenger.showSnackBar(
                          SnackBar(
                            content:
                                Text(widget.zh ? '已复制错误信息' : 'Error copied'),
                            duration: const Duration(seconds: 1),
                          ),
                        );
                      }
                    },
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.copy, size: 14, color: cs.onSurfaceVariant),
                        const SizedBox(width: 4),
                        Text(
                          widget.zh ? '复制' : 'Copy',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 来源引用卡片（朴素风）：一行标题「来源 N」+ 展开箭头，
/// 每条 = 序号 + 标题 + 域名，点击整行打开浏览器，行尾复制按钮。
class _SourceCitationCardV2 extends StatefulWidget {
  final List<SearchSource> sources;
  final ThemeData theme;
  final bool zh;

  const _SourceCitationCardV2({
    required this.sources,
    required this.theme,
    required this.zh,
  });

  @override
  State<_SourceCitationCardV2> createState() => _SourceCitationCardV2State();
}

class _SourceCitationCardV2State extends State<_SourceCitationCardV2> {
  bool _expanded = false;

  Future<void> _openUrl(String url) async {
    // W3：统一走 LauncherUtils（生物锁守卫 + percent-encode + 日志）
    try {
      await LauncherUtils.openExternalUrl(url);
    } catch (e) {
      debugPrint('catch 静默异常: $e');
    }
  }

  void _copyUrl(String url) {
    Clipboard.setData(ClipboardData(text: url));
    AppSnackBar.showSnackBar(
      context,
      SnackBar(
        content: Text(widget.zh ? '已复制链接' : 'Link copied'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = widget.theme.colorScheme;
    final sources = widget.sources;
    const collapsedCount = 3;
    final visible = _expanded ? sources : sources.take(collapsedCount).toList();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: sources.length > collapsedCount
                ? () => setState(() => _expanded = !_expanded)
                : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Icon(Icons.link, size: 14, color: cs.onSurfaceVariant),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      widget.zh
                          ? '来源 ${sources.length}'
                          : 'Sources ${sources.length}',
                      style: widget.theme.textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (sources.length > collapsedCount)
                    Icon(
                      _expanded
                          ? Icons.keyboard_arrow_up
                          : Icons.keyboard_arrow_down,
                      size: 16,
                      color: cs.onSurfaceVariant,
                    ),
                ],
              ),
            ),
          ),
          for (int i = 0; i < visible.length; i++)
            Builder(builder: (context) {
              final s = visible[i];
              final domain = s.domain;
              return InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () => _openUrl(s.url),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                  child: Row(
                    children: [
                      Text(
                        '${i + 1}',
                        style: widget.theme.textTheme.labelSmall?.copyWith(
                          color: cs.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              s.title.isEmpty ? s.url : s.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: widget.theme.textTheme.bodySmall?.copyWith(
                                color: cs.onSurface.withValues(alpha: 0.85),
                                fontSize: 12,
                              ),
                            ),
                            if (domain.isNotEmpty)
                              Text(
                                domain,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style:
                                    widget.theme.textTheme.labelSmall?.copyWith(
                                  color: cs.onSurfaceVariant
                                      .withValues(alpha: 0.6),
                                  fontSize: 10,
                                ),
                              ),
                          ],
                        ),
                      ),
                      MessageActionButton(
                        icon: Icons.copy,
                        size: 13,
                        tooltip: widget.zh ? '复制链接' : 'Copy link',
                        onTap: () => _copyUrl(s.url),
                      ),
                    ],
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }
}

/// build96 (O13)：归并后的思考节点模型（移植自 v1.7.37 _ReasonNode）
class _ReasonNodeV2 {
  final String type; // 'thinking' | 'search' | 'mcp_call' | 'skill_call'
  final ReasoningStep step;
  final ReasoningStep? result; // search 节点配对的 search_result
  final int startIndex; // 在原 steps 中的起始索引（算耗时用）
  const _ReasonNodeV2({
    required this.type,
    required this.step,
    this.result,
    required this.startIndex,
  });
}

/// build96 (O13)：搜索结果/工具结果的可再展开区块（移植自 v1.7.37
/// _ExpandableSearchResult）：解析 `[n] 标题` + `URL:` 行产出可点/可复制的
/// 来源列表；解析失败回退纯文本截断展开。
class _ExpandableResultV2 extends StatefulWidget {
  final String content;
  final ThemeData theme;
  final bool zh;

  const _ExpandableResultV2({
    required this.content,
    required this.theme,
    required this.zh,
  });

  @override
  State<_ExpandableResultV2> createState() => _ExpandableResultV2State();
}

class _ExpandableResultV2State extends State<_ExpandableResultV2> {
  bool _expanded = false;

  List<({String index, String title, String url})> _parseSources() {
    final sources = <({String index, String title, String url})>[];
    final titleRe = RegExp(r'^\s*\[(\d+)\]\s*(.*)$');
    final urlRe = RegExp(r'^\s*URL:\s*(\S+)\s*$', caseSensitive: false);
    String? curIndex;
    String? curTitle;
    for (final line in widget.content.split('\n')) {
      final tm = titleRe.firstMatch(line);
      final um = urlRe.firstMatch(line);
      if (tm != null) {
        curIndex = tm.group(1);
        curTitle = tm.group(2) ?? '';
      } else if (um != null && curIndex != null) {
        final url = um.group(1)!;
        if (url.startsWith('http')) {
          sources.add((
            index: curIndex,
            title: (curTitle == null || curTitle.isEmpty) ? url : curTitle,
            url: url,
          ));
        }
        curIndex = null;
        curTitle = null;
      }
    }
    return sources;
  }

  Future<void> _openUrl(String url) async {
    // B-003：思考结果展开体里的链接也是外链跳转，统一走 LauncherUtils
    //（内部含 guard + 120s 兜底 + 异常吞掉），防返回时误弹生物锁。
    await LauncherUtils.openExternalUrl(url);
  }

  void _copyUrl(String url) {
    Clipboard.setData(ClipboardData(text: url));
    AppSnackBar.showSnackBar(
      context,
      SnackBar(
        content: Text(widget.zh ? '已复制链接' : 'Link copied'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final textStyle = widget.theme.textTheme.bodySmall?.copyWith(
      color: widget.theme.colorScheme.onSurface.withValues(alpha: 0.6),
      fontSize: 11,
    );
    final sources = _parseSources();
    if (sources.isEmpty) {
      return GestureDetector(
        onTap: () => setState(() => _expanded = !_expanded),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.content,
              maxLines: _expanded ? null : 3,
              overflow: _expanded ? null : TextOverflow.ellipsis,
              style: textStyle,
            ),
            Text(
              _expanded
                  ? (widget.zh ? '收起' : 'Show less')
                  : (widget.zh ? '展开全部' : 'Show all'),
              style: widget.theme.textTheme.labelSmall?.copyWith(
                color: widget.theme.colorScheme.primary,
                fontSize: 10,
              ),
            ),
          ],
        ),
      );
    }

    const collapsedCount = 2;
    final visible = _expanded ? sources : sources.take(collapsedCount).toList();
    return GestureDetector(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final s in visible)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '[${s.index}] ${s.title}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textStyle,
                    ),
                  ),
                  InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => _openUrl(s.url),
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: Icon(
                        Icons.open_in_new,
                        size: 13,
                        color: widget.theme.colorScheme.primary,
                      ),
                    ),
                  ),
                  InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => _copyUrl(s.url),
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: Icon(
                        Icons.copy,
                        size: 13,
                        color: widget.theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (sources.length > collapsedCount)
            Text(
              _expanded
                  ? (widget.zh ? '收起' : 'Show less')
                  : (widget.zh
                      ? '展开全部（${sources.length} 条）'
                      : 'Show all (${sources.length})'),
              style: widget.theme.textTheme.labelSmall?.copyWith(
                color: widget.theme.colorScheme.primary,
                fontSize: 10,
              ),
            ),
        ],
      ),
    );
  }
}

/// build164（#83）：产物卡片左边那块**方形缩略块**（用户参照图里的那一格）。
///
/// 为什么是一块类型徽标而不是真截图：真截图要么开 WebView 截、要么读文件再渲染 ——
/// 两者都是"渲染时读盘"，正是这次明令禁止的那件事（点开才读）。一期只画 html，
/// 类型是确定的，所以这块按 html 徽标画，宽度 40 固定、不参与文字换行计算。
/// 形状也顺手把命中区顶到 56dp（40 + 卡片上下各 8），比再写一份 minHeight 约束更实在。
class _AgentArtifactThumb extends StatelessWidget {
  const _AgentArtifactThumb({required this.colorScheme});
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    final cs = colorScheme;
    return Container(
      // Key 是给单测的（`build164_artifact_card_test.dart` 钉"左边是方形缩略块、
      // 不是 14px 文件图标"）：Container 的 width/height 会被折进 constraints，
      // 按字段找不可靠，撑宽/裁形这类回归也就看不见。
      key: const ValueKey('agent-artifact-thumb'),
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        // primary 12% 底色 + primary 图标：跟随主题色（深色卡上仍是那枚"青色"块，
        // 但不写死 Color(0x…) —— 本仓 V2 UI 棘轮 R7 明令禁用硬编码色）
        color: cs.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(Icons.html_outlined, size: 20, color: cs.primary),
    );
  }
}

/// 流式期间实时计时器（每 500ms 刷新一次）
/// build101（D1）：消息头像。path 为空时用占位图标。
class _Avatar extends StatelessWidget {
  final String path;
  final bool isUser;
  final ThemeData theme;

  const _Avatar(
      {required this.path, required this.isUser, required this.theme});

  @override
  Widget build(BuildContext context) {
    final fallback = CircleAvatar(
      radius: 14,
      backgroundColor: isUser
          ? theme.colorScheme.primary.withValues(alpha: 0.15)
          : theme.colorScheme.surfaceContainerHighest,
      child: Icon(
        isUser ? Icons.person_outline : Icons.smart_toy_outlined,
        size: 15,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
    if (path.trim().isEmpty) return fallback;
    // build129（性能）：删掉 build 内的 `File(path).existsSync()`。
    // 那是每次重建都阻塞主线程一次的同步磁盘 IO；而本组件在流式期间会被
    // 每个 token 连带重建，长会话里等于持续做无谓系统调用。
    // 文件不存在/不可读时 `Image.file` 本就会走下面的 errorBuilder 落到
    // **同一个 fallback**，所以去掉预检后语义不变、只是不再有每帧 IO。
    final file = File(path);
    // build103（I10）：cover → contain——正方形/竖图不再被中心放大裁掉，
    // 完整显示整张照片；底色沿用 fallback 同色，留白不突兀。
    // build129（性能）：加 cacheWidth——头像只显示 28dp，此前未限宽会把原图
    // （手机照动辄 4000×3000）整张解码进图像缓存，单张位图就 ~48MB，
    // 解码 CPU 与内存双高。按 DPR 折算物理像素限宽解码；**只给 cacheWidth**
    // 以保留宽高比（同时给两个会把非方图压扁）。
    final cacheW = (28 * MediaQuery.of(context).devicePixelRatio).round();
    return ClipOval(
      child: Container(
        width: 28,
        height: 28,
        color: isUser
            ? theme.colorScheme.primary.withValues(alpha: 0.15)
            : theme.colorScheme.surfaceContainerHighest,
        child: Image.file(
          file,
          fit: BoxFit.contain,
          cacheWidth: cacheW,
          errorBuilder: (_, __, ___) => fallback,
        ),
      ),
    );
  }
}

