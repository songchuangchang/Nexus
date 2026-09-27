import 'package:flutter/material.dart';

import '../models/chat_message.dart';
import '../ui/tokens.dart';

/// build140（真机反馈⑥）：待办清单从**消息气泡内部**搬出来，改成**输入框上方常驻条**。
///
/// ## 为什么原来的位置不对
/// 原来它渲染在气泡里（`message_bubble_v2._buildTodoCard`）：往上翻就看不见、
/// 往下滚就丢了。而多步任务的用户诉求恰恰是「随时知道自己走到第几步」。
/// ⇒ 参考形态借的是**语义**（逐条状态 / 已完成加删除线 / n-m 进度），
///   不抄它的配色、圆环与字号（本 App 走 V2 朴素风令牌）。
///
/// ## 三条硬约束（本仓库踩过的坑，写在这里防止再踩）
/// 1. **不挂 `Scaffold.bottomNavigationBar`**（教训 #164：那个槽位不参与键盘避让，
///    一打字整条沉到键盘底下）。调用点把它放在 body 的 `Column` 里、输入区之前。
/// 2. **不做成 `Stack` 里的浮层**（教训 #163：贴底浮层写成流内节点会整列上下跳；
///    反过来，真正的浮层又要锁三处锚点）。这里就是普通流内节点，
///    出现/消失与展开/折叠一律经 [AnimatedSize] 过渡，不是一帧硬跳。
/// 3. **与上下文用量条、「回到底部」胶囊共存**：用量条贴输入框上沿、胶囊浮在列表区，
///    本条排在用量条**之前**（更靠列表），三者互不占位。
///
/// ## 数据口径（本期拍板，写清楚免得日后当成 bug 改）
/// - 显示的是**本会话最后一条带清单的助手消息**那份（[latestFrom]），
///   不是"所有消息的并集"——AI 每轮重写清单，并集会留下早已作废的条目。
/// - **勾态不落库**（与搬走前完全一致）：清单本身来自 `<todo>` 标签在载入时重解析，
///   手动勾的格子只活在这次打开期间。全部完成后自动收成 `n/n` 药丸形态，
///   不整条消失——消失会让人以为"东西被吞了"。
/// - 勾选**不回灌给模型**：它表达的是"用户自己看到了进度"，不是新的用户意图。
class ChatTodoStrip extends StatelessWidget {
  const ChatTodoStrip({
    super.key,
    required this.items,
    required this.zh,
    required this.expanded,
    required this.onToggleExpanded,
    required this.onToggle,
  });

  /// 每项：`{'text': String, 'done': bool}`（与 `ChatMessage.todoItems` 同构）
  final List<Map<String, dynamic>> items;
  final bool zh;

  /// 折叠态只显示「当前进行项 + n/m 药丸」，展开态列全量。
  /// 默认折叠：常驻的东西不能再吃列表高度。
  final bool expanded;
  final VoidCallback onToggleExpanded;

  /// 勾选某一项（回调只给下标，状态由调用方写回那份 `todoItems` 后 setState）
  final ValueChanged<int> onToggle;

  /// 展开区高度：build157（⑫）之前是**写死 168**，既不跟视口高度也不跟字号档
  /// （大字号下三行就把面板顶满、小屏/键盘弹起时又反过来挤掉输入区）。
  /// 现在按「视口高 × 系数 × 字号档」算，再夹进下面这对常量里。
  static const double _kExpandedMinHeight = 96;
  static const double _kExpandedMaxHeight = 300;
  static const double _kExpandedViewportFactor = 0.28;

  /// 展开区高度上限（纯函数，便于机检：见 `test/build157_tap_targets_test.dart`）。
  ///
  /// **返回值恒在 [96, 300] 之间，绝不可能是负数**，三层保险：
  /// ① 入参先被折成有限非负数（视口 NaN/0/负 → 0，字号 NaN/≤0 → 1）；
  /// ② `clamp` 的两个界都是写死的正常量，`lowerLimit <= upperLimit` 恒成立，
  ///    所以结果不可能落到 0 以下 —— 这一点必须成立，因为
  ///    `BoxConstraints(maxHeight: 负数)` 是直接 assert 崩、不是"矮一点"；
  /// ③ 上限 300 保证它再怎么乘字号也盖不过输入区。
  static double expandedMaxHeight(double viewportHeight, double fontScale) {
    final vh =
        viewportHeight.isFinite && viewportHeight > 0 ? viewportHeight : 0.0;
    final fs = fontScale.isFinite && fontScale > 0 ? fontScale : 1.0;
    return (vh * _kExpandedViewportFactor * fs)
        .clamp(_kExpandedMinHeight, _kExpandedMaxHeight)
        .toDouble();
  }

  /// 会话里**最后一条**带待办的助手消息的清单；没有则 null（整条不渲染）。
  ///
  /// 用户角色一律跳过：`<todo>` 只可能由模型产出，若把用户消息也卷进来，
  /// 引用/编辑重发时复制过来的正文会伪造出一份"待办"。
  static List<Map<String, dynamic>>? latestFrom(List<ChatMessage> messages) {
    for (final m in messages.reversed) {
      if (m.role != MessageRole.assistant) continue;
      if (m.todoItems.isEmpty) continue;
      return m.todoItems;
    }
    return null;
  }

  static int doneCount(List<Map<String, dynamic>> items) =>
      items.where((e) => e['done'] == true).length;

  /// 折叠态当门面展示的那一条：**第一个未完成项**；全完成时显示收尾文案。
  static Map<String, dynamic>? currentItem(List<Map<String, dynamic>> items) {
    for (final e in items) {
      if (e['done'] != true) return e;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final total = items.length;
    final done = doneCount(items);
    final allDone = done == total;
    final current = currentItem(items);
    final headline = allDone
        ? (zh ? '待办已全部完成' : 'All tasks done')
        : (current?['text'] as String? ?? '');
    final progressText = '$done/$total';

    return AnimatedSize(
      duration: AppMotion.duration(context, AppDur.slow),
      curve: AppCurve.enter,
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppGap.md, 0, AppGap.md, AppGap.xs),
        child: Material(
          // build139 的教训：底色/描边要由 Material 承担，
          // 否则头部的 InkWell 水波纹没有落点（点了没反应的静默缺陷）。
          type: MaterialType.canvas,
          color: cs.appPanelLight,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(
                expanded ? AppRadius.panel : AppRadius.pill),
            side: BorderSide(color: cs.appBorder),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InkWell(
                onTap: onToggleExpanded,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppGap.md, vertical: AppGap.sm),
                  child: Row(
                    children: [
                      Icon(
                        allDone
                            ? Icons.check_circle_outline
                            : Icons.checklist,
                        size: 16,
                        color: allDone ? cs.primary : cs.appTextSub,
                      ),
                      const SizedBox(width: AppGap.sm),
                      Expanded(
                        child: Text(
                          headline,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: tt.bodySmall?.copyWith(
                            color: allDone ? cs.appTextSub : cs.onSurface,
                            fontWeight:
                                allDone ? FontWeight.w500 : FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppGap.sm),
                      _ProgressPill(text: progressText, allDone: allDone),
                      const SizedBox(width: AppGap.xs),
                      Icon(
                        expanded ? Icons.expand_less : Icons.expand_more,
                        size: 16,
                        color: cs.appTextSub,
                      ),
                    ],
                  ),
                ),
              ),
              if (expanded)
                ConstrainedBox(
                  // 高度跟着视口与字号档走（build157 ⑫，算法见 expandedMaxHeight）：
                  // 这里改的只有 maxHeight 一项，行宽一个字没动 ⇒
                  // 折叠头部与勾选行都不会因此横向溢出。
                  constraints: BoxConstraints(
                    maxHeight: expandedMaxHeight(
                      MediaQuery.of(context).size.height,
                      MediaQuery.of(context).textScaler.scale(1.0),
                    ),
                  ),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(
                        AppGap.sm, 0, AppGap.sm, AppGap.sm),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(
                              AppGap.md, 0, AppGap.md, AppGap.xs),
                          child: Text(
                            zh ? '待办清单 $progressText' : 'Todo $progressText',
                            style: tt.labelSmall?.copyWith(
                                color: cs.appTextSub,
                                fontWeight: FontWeight.w600),
                          ),
                        ),
                        for (var i = 0; i < items.length; i++)
                          _TodoRow(
                            index: i,
                            item: items[i],
                            zh: zh,
                            onToggle: onToggle,
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 进度药丸：**文字**「n/m」，不做独立圆环——本 App 已有上下文用量条那种
/// 横向占用表达，再挂一个环形读数会两种进度语言打架（反馈⑥记录里定下的口径）。
class _ProgressPill extends StatelessWidget {
  const _ProgressPill({required this.text, required this.allDone});

  final String text;
  final bool allDone;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppGap.sm, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.inline),
        border: Border.all(color: allDone ? cs.primary : cs.appBorder),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          height: 1.2,
          color: allDone ? cs.primary : cs.appTextSub,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 一条待办：状态图标复用四态图标（`AppRunState.ok`）的 `check_circle_outline`，
/// 未完成用同族的中性圈；已完成加删除线（借参考图那三点语义之一）。
class _TodoRow extends StatelessWidget {
  const _TodoRow({
    required this.index,
    required this.item,
    required this.zh,
    required this.onToggle,
  });

  final int index;
  final Map<String, dynamic> item;
  final bool zh;
  final ValueChanged<int> onToggle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final done = item['done'] == true;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.inline),
      onTap: () => onToggle(index),
      // build157（⑫）：勾选行原本 `vertical: AppGap.xs` → 实测约 24dp 高，点不中。
      // 只补**高度**（ConstrainedBox minHeight:40，抄 message_action_button 那套
      // 已验证写法）：Row 的横向一个字没加 ⇒ 不会把图标+文字顶出气泡宽度；
      // 纵向多出来的 16dp 由外层那个有 maxHeight 的滚动区吸收（超出即滚动，
      // 不是溢出），所以整条待办条的高度也不会越过 expandedMaxHeight 的 cap。
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 40),
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppGap.md, vertical: AppGap.xs),
          child: Row(
            children: [
              Icon(
                done
                    ? Icons.check_circle_outline
                    : Icons.radio_button_unchecked,
                size: 16,
                color: done ? cs.primary : cs.appTextSub,
              ),
              const SizedBox(width: AppGap.sm),
              Expanded(
                child: Text(
                  item['text'] as String? ?? '',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: tt.bodySmall?.copyWith(
                    color: done ? cs.appTextSub : cs.onSurface,
                    decoration: done
                        ? TextDecoration.lineThrough
                        : TextDecoration.none,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
