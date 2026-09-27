/// 底部弹层统一封装（B2）。
///
/// ## 为什么要有这个文件
/// 对话页原来有 17 处弹层调用：12 处 `showDialog` + 5 处手写 `showModalBottomSheet`。
/// 手写的那 5 处圆角各不相同（默认 28 / 硬编码 20 / 不带把手），
/// `AlertDialog` 的默认圆角也不在 tokens 允许集里 —— 视觉上「每种弹层长得都不一样」。
///
/// 这里收敛成**唯一入口**：圆角取 `AppRadius.card`(14)、统一拖拽把手、统一安全区、
/// 统一键盘避让。之后新增弹层只要调 [showAppSheet]，不会再各写各的。
///
/// ## 使用边界（不是所有弹窗都该换成弹层）
/// 只用于**操作型 / 设置型 / 输入型**弹层。以下场景**必须继续用 `showDialog`**，
/// 因为弹层可以下滑关闭，会破坏它们赖以成立的模态性：
///   · 破坏性确认（删除 / 清空 / 覆盖）—— 误滑关闭 = 用户以为没删，实际删了；
///   · 进行中任务（下载进度）—— 下滑后任务继续但没有任何反馈，比对话框更糟；
///   · 必须回答的提问（AI `ask_user`）—— 下滑关闭 = 提问丢失、对话卡住；
///   · 安全警示（未知来源安装包）—— 需要强阻断。
library;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// 统一的底部弹层入口。
///
/// 与直接调 `showModalBottomSheet` 的区别：自动套用统一圆角（[AppRadius.card]）、
/// 拖拽把手、安全区，并在 [keyboardAware] 时按键盘高度让位。
///
/// [scrollable] 内容超一屏（长表单 / 列表）时置 true，否则小内容会被挤在底部。
/// [keyboardAware] 含输入框时置 true，否则键盘会盖住弹层。
Future<T?> showAppSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool scrollable = false,
  bool keyboardAware = false,
  bool showDragHandle = true,
}) {
  return showModalBottomSheet<T>(
    context: context,
    // 键盘避让必须 isScrollControlled，否则 viewInsets 让位无效
    isScrollControlled: scrollable || keyboardAware,
    useSafeArea: true,
    showDragHandle: showDragHandle,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(AppRadius.card),
      ),
    ),
    // 注意：viewInsets 必须在 builder 内读 —— 调用时刻键盘还没弹出，读到的是 0。
    builder: (sheetCtx) => Padding(
      padding: EdgeInsets.only(
        bottom: keyboardAware ? MediaQuery.viewInsetsOf(sheetCtx).bottom : 0,
      ),
      child: builder(sheetCtx),
    ),
  );
}

/// 弹层统一标题块。用于替换 `AlertDialog(title: ...)`。
class AppSheetHeader extends StatelessWidget {
  const AppSheetHeader({super.key, required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppGap.lg,
        0,
        AppGap.lg,
        AppGap.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: tt.titleMedium),
          if (subtitle != null) ...[
            const SizedBox(height: AppGap.xs),
            Text(
              subtitle!,
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}

/// 弹层统一底部操作行。用于替换 `AlertDialog(actions: ...)`。
///
/// 只负责布局（右对齐 + 统一内边距）；按钮样式沿用 Material 的
/// `TextButton`（次要）/ `FilledButton`（主要），与对话框时期保持一致。
class AppSheetActions extends StatelessWidget {
  const AppSheetActions({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppGap.lg,
        AppGap.sm,
        AppGap.lg,
        AppGap.lg,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(width: AppGap.sm),
            children[i],
          ],
        ],
      ),
    );
  }
}
