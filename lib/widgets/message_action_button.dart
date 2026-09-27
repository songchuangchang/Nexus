import 'package:flutter/material.dart';

/// 聊天消息底部通用小图标操作按钮（Chatbox 朴素风）。
///
/// 用于 AI 消息底部操作行（复制 / 重试 / 版本切换 / 导出 等）：
/// 仅一个小图标，无底色无边框，hover/点击有浅灰圆角反馈。
class MessageActionButton extends StatelessWidget {
  final IconData icon;
  final String? tooltip;
  final VoidCallback? onTap;
  final Color? color;
  final double size;

  const MessageActionButton({
    super.key,
    required this.icon,
    this.tooltip,
    this.onTap,
    this.color,
    this.size = 16,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final effectiveColor = color ?? cs.onSurfaceVariant;
    // build156（真机 UI 扫描 P1）：命中区原本是 5 + 16 + 5 = **26dp 高**，点不中。
    // 但宽度**一律不许动**：_buildActionRow 是 `Row(mainAxisSize.min)` 且没有滚动包裹，
    // 一行最多可同时出现复制/上版本/下版本/重试/导出/分享六个键，
    // 而气泡宽度上限只有屏宽的 82%（360dp 机约 295dp）——
    // 每个键横向撑 4dp 就可能在窄屏顶出 RENDER OVERFLOWED。
    // 所以这里只补垂直命中区（26 → 40），横向留给"操作行改可换行 Wrap"那类
    // 设计变更，不在一次 bug 修复里顺手改布局语义。
    final child = InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 40),
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Center(
            child: Icon(icon, size: size, color: effectiveColor),
          ),
        ),
      ),
    );
    if (tooltip == null) return child;
    return Tooltip(message: tooltip!, child: child);
  }
}
