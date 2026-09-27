import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../ui/tokens.dart';
import '../utils/ask_user_option.dart';

/// build139（真机反馈④）· 反问面板重构
///
/// 用户原话：「反问的推荐好像用不了，反问 UI 也重构吧」。两件事分开看：
///  · **推荐（选项）用不了** 的主因在解析侧（`AskUserPlugin.cleanOptions` 把清洗后
///    只剩 1 条的选项整组丢空 ⇒ 面板只剩一个输入框），见该函数与
///    `test/build93_stopgap_test.dart` 的同名用例；本文件负责另一半。
///  · 老面板是 `chat_screen_react.dart` 里手搓的 130 行 AlertDialog：
///    选项用「宽度随文字、密集并排」的那类浅底 chip 控件（可点区远小于 44dp ⇒
///    真机上点不中或点错相邻项）；问题底色写死主题容器色的一半透明度 + 裸圆角；
///    占位选项（「其他」）点下去只把光标丢进输入框，而输入框在滚动区外时**看不出
///    任何变化** ⇒ 这三条在用户眼里都是「推荐点了没用」。
///
/// 重构后的形态（与 build138 输入区改造同一套口径：装饰只留一层、可点区抬到 44dp、
/// 取色取圆角一律走 token）：
///  · 一行一个**整宽选项行**（leading 圆点 + 文案 + trailing 箭头），minHeight 44；
///  · 占位选项 = 滚动到输入框并聚焦（`ensureVisible`），不再是"点了没反应"；
///  · 输入区常驻（有选项时也不藏），标签写清「或直接自己输入」；
///  · 键盘弹起时整块上推 + 内容区自己滚，「跳过 / 提交」钉在 actions 不被顶没
///    （老实现读的是聊天页的 MediaQuery，对话框是另一个 route，那个值恒为 0）；
///  · 「提交」只在真有文字时可用 —— 不再保留"空提交＝跳过"这条与点跳过等价、
///    却会被用户当成"按了没反应"的隐蔽路径。
///
/// 返回契约与重构前**逐字一致**：点选项 / 输入后提交 ⇒ 该字符串；跳过 / 关闭 ⇒ null。
/// （null 会被上层记进 `skippedAskFps`，改语义会连带污染 O1 的「同一缺口不再问」。）
///
/// 仍用 showDialog 而非 showAppSheet：`lib/ui/app_sheet.dart` 的注意事项里写明
/// 反问必须不能被下滑手势擦掉（擦了等于用户没答，问题会永久丢失）。

/// 「点了应当让用户自己写、而不是直接把这句发出去」的占位选项
/// （v1.7.31 起存在，build139 从聊天页挪到面板这一侧：它只服务于渲染，
/// 不该散在 ReAct 状态机的代码里）。
const Set<String> kAskUserPlaceholderOptions = {
  '其他',
  '其它',
  '自定义',
  '手动输入',
  '自己输入',
  '其他选项',
  '其他格式',
  '其他类型',
  '都不是',
  '以上都不是',
  '无',
  '没有',
  '不确定',
  '不清楚',
  'other',
  'custom',
  'none',
  'n/a',
  'other (please specify)',
};

/// 该选项是否"只是让用户自己写"的占位。
bool isAskUserPlaceholder(String opt) =>
    kAskUserPlaceholderOptions.contains(opt.toLowerCase().trim());

/// 弹反问面板。[options] 可以为空（只给输入框）。
///
/// [options] 的每一项是**线格式**：`标题[::说明][::推荐]`（build140 反馈⑦）。
/// 本文件不自己 split —— 一律交给 [AskUserOption.parse]，旧写法（没有 `::`）
/// 逐字等价于"只有标题"。
///
/// [quickReplies]（build140 反馈④）：宿主**在弹窗之前**就发起的一次轻量生成，
/// 内容是"用户也可能直接这样答复"的短句。传进来只为"到货即渲染"，
/// 面板不关心它何时发、失败怎样 —— 拿不到就整段不出现（不占位、不显示错误）。
///
/// 返回用户最终答复；跳过 / 关闭返回 null。
Future<String?> showAskUserPanel(
  BuildContext context, {
  required String question,
  required List<String> options,
  Future<List<String>>? quickReplies,
}) =>
    showDialog<String>(
      context: context,
      // 反问是"必须有个交代"的交互：点遮罩关闭会走 null ⇒ 被当成用户拒绝，
      // 所以保持不可点遮罩关闭（与重构前一致）。
      barrierDismissible: false,
      builder: (ctx) => _AskUserDialog(
        question: question,
        options: options,
        quickReplies: quickReplies,
      ),
    );

class _AskUserDialog extends StatefulWidget {
  const _AskUserDialog({
    required this.question,
    required this.options,
    this.quickReplies,
  });

  final String question;
  final List<String> options;
  final Future<List<String>>? quickReplies;

  @override
  State<_AskUserDialog> createState() => _AskUserDialogState();
}

class _AskUserDialogState extends State<_AskUserDialog> {
  final TextEditingController _text = TextEditingController();
  final FocusNode _fieldFocus = FocusNode();
  final GlobalKey _fieldKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // 「提交」的可用性跟着输入走 ⇒ 必须监听 controller。
    // （漏了这一句的表现很隐蔽：字打了、键却还是灰的，只有真点一下才发现。）
    _text.addListener(_onTextChanged);
  }

  void _onTextChanged() => setState(() {});

  @override
  void dispose() {
    _text.removeListener(_onTextChanged);
    _text.dispose();
    _fieldFocus.dispose();
    super.dispose();
  }

  bool get _canSubmit => _text.text.trim().isNotEmpty;

  /// build140（反馈⑦）：线格式选项 ⇒ 渲染用的 `(标题, 说明, 推荐)`。
  ///
  /// 解析集中在这一处做好，渲染与点击都读同一份结果——若两条路各 split 一遍，
  /// 就会出现"看到的标题和发回去的标题不一致"（教训 #62）。
  List<AskUserOption> get _options =>
      widget.options.map(AskUserOption.parse).toList(growable: false);

  /// 点一个选项。**pop 出去的是标题，不是整条线格式**：
  /// `::说明` 是给人看的理由，把它发回模型等于让它以为用户打了一整句形容词；
  /// 占位选项（「其他」这类）仍然只做"把光标送进输入框"，判定看标题而不是原始串。
  void _onOptionTap(AskUserOption option) {
    if (isAskUserPlaceholder(option.title)) {
      _focusOwnField();
      return;
    }
    Navigator.pop(context, option.title);
  }

  /// 占位选项：它不是答案本身，而是"我要自己写"这个动作。所以把光标送到输入框，
  /// 并且**先滚过去**——老实现只 requestFocus，输入框在滚动区外时看着毫无反应。
  void _focusOwnField() {
    final target = _fieldKey.currentContext;
    if (target != null) {
      Scrollable.ensureVisible(target, alignment: 0.1);
    }
    _fieldFocus.requestFocus();
  }

  void _submit() {
    if (!_canSubmit) return;
    Navigator.pop(context, _text.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final options = _options;
    final viewInsets = MediaQuery.viewInsetsOf(context).bottom;
    // 内容区自己限高（按钮走 AlertDialog.actions，天然常驻）：
    // 键盘 300dp + 8 个选项时不封顶会把「跳过 / 提交」推到屏幕外。
    final maxBodyHeight =
        (MediaQuery.sizeOf(context).height * 0.55 - viewInsets)
            .clamp(140.0, double.infinity);
    return AlertDialog(
      // 键盘占位**不能再加一遍**：`Dialog` 已经把 `MediaQuery.viewInsets`
      // 叠在 `insetPadding` 上（material/dialog.dart 的 effectivePadding），
      // 这里再补一次 = 同一份高度扣两遍，面板被压到屏幕外（build139 自查抓到，
      // 由 test/build139_ask_user_test.dart 的「键盘弹起」用例钉住）。
      // 老实现真正的毛病是下面算内容高度时读的是**聊天页**的 MediaQuery，
      // 而对话框是另一个 route，那个值恒为 0 ⇒ 键盘弹起时内容不缩水、提交键被顶没。
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      title: Row(
        children: [
          Icon(Icons.help_outline, size: 20, color: cs.primary),
          const SizedBox(width: AppGap.sm),
          Expanded(
            child: Text(isZh ? 'AI 想问你' : 'AI wants to ask you',
                style: tt.titleMedium),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxBodyHeight),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _AskQuestionPanel(question: widget.question),
              if (options.isNotEmpty) ...[
                const SizedBox(height: AppGap.md),
                for (var i = 0; i < options.length; i++) ...[
                  if (i > 0) const SizedBox(height: AppGap.sm),
                  _AskOptionRow(
                    option: options[i],
                    isPlaceholder: isAskUserPlaceholder(options[i].title),
                    onTap: () => _onOptionTap(options[i]),
                  ),
                ],
              ],
              const SizedBox(height: AppGap.md),
              // build140 反馈④：反问那一轮也要有推荐，而且是**弹窗这一帧就在**的位置。
              // 放在选项之后、输入框之前 —— 它回答的是"除了这几个选项我还能怎么答"，
              // 与选项同为"答"，与消息底部的"追问推荐"不是一回事（那属于 assistantMsg）。
              if (widget.quickReplies != null)
                _AskQuickReplies(
                  future: widget.quickReplies!,
                  onPick: (t) => Navigator.pop(context, t),
                ),
              const SizedBox(height: AppGap.md),
              Text(isZh ? '或直接自己输入：' : 'Or type your own:',
                  style: tt.bodySmall?.copyWith(color: cs.appTextSub)),
              const SizedBox(height: AppGap.xs),
              TextField(
                key: _fieldKey,
                controller: _text,
                focusNode: _fieldFocus,
                minLines: 1,
                maxLines: 3,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  hintText: isZh ? '输入你的回答…' : 'Type your answer…',
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: AppGap.md, vertical: AppGap.sm),
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(isZh ? '跳过' : 'Skip'),
        ),
        FilledButton(
          onPressed: _canSubmit ? _submit : null,
          child: Text(isZh ? '提交' : 'Submit'),
        ),
      ],
    );
  }
}

/// 问题本体：一层浅面板（`appPanel`），不再用主题容器色的半透明底。
///
/// 方案 B 的口径是「主区之外不出现第二处彩色」，问题文案靠字号/字重区分即可；
/// 老写法那层蓝底在暗色下比气泡亮一大块，反而把选项行的边界压没了。
class _AskQuestionPanel extends StatelessWidget {
  const _AskQuestionPanel({required this.question});

  final String question;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppGap.md),
      decoration: BoxDecoration(
        color: cs.appPanel,
        borderRadius: BorderRadius.circular(AppRadius.panel),
      ),
      child: Text(
        question,
        style: Theme.of(context)
            .textTheme
            .bodyLarge
            ?.copyWith(fontWeight: FontWeight.w500),
      ),
    );
  }
}

/// 单个选项：整宽一行，可点区 44dp（Material 无障碍最小命中区）。
///
/// 占位选项（「其他」这类）尾部换成铅笔图标，视觉上就与真答案分开——
/// 用户不必点下去才知道它不是答案。
///
/// build140（反馈⑦）：一行变成"标题 + 一行说明 + 可选的『推荐』徽标"。
/// 说明是**次要层**（`appTextSub` + `bodySmall`），没有说明时整行与改造前一样高，
/// 所以旧写法（模型没给 `::`）不会出现半空槽。
class _AskOptionRow extends StatelessWidget {
  const _AskOptionRow({
    required this.option,
    required this.isPlaceholder,
    required this.onTap,
  });

  final AskUserOption option;
  final bool isPlaceholder;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    // 读屏要把标题和说明连成一句：分开读的话，"推荐"徽标会插在中间。
    final semanticLabel = option.desc.isEmpty
        ? option.title
        : '${option.title}，${option.desc}';
    return Semantics(
      button: true,
      label: semanticLabel,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.card),
          child: Container(
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(
                horizontal: AppGap.md, vertical: AppGap.sm),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.card),
              border: Border.all(color: cs.appBorder),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(
                  isPlaceholder ? Icons.edit_outlined : Icons.circle_outlined,
                  size: 16,
                  color: cs.appTextSub,
                ),
                const SizedBox(width: AppGap.md),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child:
                                Text(option.title, style: tt.bodyMedium),
                          ),
                          if (option.recommended) ...[
                            const SizedBox(width: AppGap.sm),
                            _AskRecommendBadge(zh: isZh),
                          ],
                        ],
                      ),
                      if (option.desc.isNotEmpty) ...[
                        const SizedBox(height: AppGap.xs),
                        Text(option.desc,
                            style:
                                tt.bodySmall?.copyWith(color: cs.appTextSub)),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: AppGap.sm),
                Icon(
                  isPlaceholder
                      ? Icons.keyboard_arrow_down
                      : Icons.chevron_right,
                  size: 18,
                  color: cs.appTextSub,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 「推荐」徽标：靠 `primary` 描边 + `primary` 文字，**不是第二块彩色底**
/// （方案 B 的口径：主区之外不出现第二处彩色；老问题面板就是败在多了一层蓝底）。
///
/// 只有模型显式写了 `::推荐` 才出现——不替用户猜哪个最好，也不给没有依据的
/// 第一个选项自动加标。
class _AskRecommendBadge extends StatelessWidget {
  const _AskRecommendBadge({required this.zh});

  final bool zh;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppGap.sm, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: cs.primary),
      ),
      child: Text(zh ? '推荐' : 'Best',
          style: Theme.of(context)
              .textTheme
              .labelSmall
              ?.copyWith(color: cs.primary, fontWeight: FontWeight.w600)),
    );
  }
}

/// build140 反馈④ · 反问面板内的「也可以这样答」。
///
/// 为什么放在面板里而不是消息底部：
///  · 消息底部那排气泡挂在 `assistantMsg.suggestions` 上，语义是**答完之后的追问**，
///    而反问轮按 A1 规则不落地答案 ⇒ 那一排按设计不会出现（这正是反馈④ 的机制成因）；
///  · 弹窗是模态的，消息层的气泡点不到，等于"推荐在但用不了"；
///  · 用户此刻要的是"除了这几个选项我还能怎么答"，与问题同屏才有意义。
///
/// 三条刻意取舍：
///  · 到货即出、**不到货不占位**（`waiting`/`error` 一律 shrink）：这一段是锦上添花，
///    绝不能在面板里留一块"正在生成…"的空槽——那会把 44dp 选项行挤下去，
///    也会让生成失败变成一次可见的故障（宿主侧超时是静默的，见 `_streamSuggestItems`）；
///  · 点了就 `Navigator.pop(context, 文案)`，与点选项**同一条返回契约** ⇒
///    上层 `skippedAskFps` / `_injectDeclined` 的判定完全不受影响；
///  · 与选项的视觉分工：选项是整宽行（1..8 个主路径），这里是胶囊（次要路径），
///    所以不抢选项的可点区，也不会被误读成"第 9 个选项"。
class _AskQuickReplies extends StatelessWidget {
  const _AskQuickReplies({required this.future, required this.onPick});

  final Future<List<String>> future;
  final void Function(String reply) onPick;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    return FutureBuilder<List<String>>(
      future: future,
      // 只在建新帧时保留旧内容：到货前是 shrink（不占位），到货后一次性铺开。
      builder: (context, snap) {
        final items = snap.data ?? const <String>[];
        if (items.isEmpty) return const SizedBox.shrink();
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: AppGap.md),
            Text(isZh ? '也可以这样答：' : 'Or reply with:',
                style: tt.bodySmall?.copyWith(color: cs.appTextSub)),
            const SizedBox(height: AppGap.xs),
            Wrap(
              spacing: AppGap.sm,
              runSpacing: AppGap.sm,
              children: [
                for (final r in items)
                  Semantics(
                    button: true,
                    label: r,
                    child: Material(
                      color: cs.appPanel,
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      child: InkWell(
                        onTap: () => onPick(r),
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                        child: Container(
                          constraints: const BoxConstraints(minHeight: 36),
                          padding: const EdgeInsets.symmetric(
                              horizontal: AppGap.md, vertical: AppGap.sm),
                          decoration: BoxDecoration(
                            borderRadius:
                                BorderRadius.circular(AppRadius.pill),
                            border: Border.all(color: cs.appBorder),
                          ),
                          alignment: Alignment.center,
                          child: Text(r, style: tt.bodyMedium),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}
