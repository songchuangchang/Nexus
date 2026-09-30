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
    // build156（真机 UI 扫描 P1）把高度从 26 抬到 40，宽度**一位没动**；当时写下的
    // 理由是"操作行是 Row(mainAxisSize.min)、气泡宽上限屏宽 82%，横向撑宽会顶出
    // RENDER OVERFLOWED"。那个理由是对的，错的是把它读成"宽度不归命中区管"。
    // build175 平板遍历（1.7.117 / OPD2409 / dp = px ÷ 2.625）实测：
    //   复制 25.9×40.0、撤回 25.9×40.0、编辑重发 26.3×40.0、重试 25.9×40.0 ——
    //   26dp = 图标 16 + 左右各 5，拇指压在图标边缘外 1dp 就落进键与键的空隙。
    // 现在两轴一起补到 Material 48dp，并且**不把 48 塞进图标**：
    //  · 横向仍由 padding 给（16 + 图标 + 16），`size` 只决定视觉大小，不是命中区；
    //  · 外层 BoxConstraints 的 48 是**下限**：传大图标（size: 20）盒子跟着长，
    //    传小图标（附件卡片「复制链接」size: 13 ⇒ padding 只给到 45）由下限兜住，
    //    兜的是盒子不是字号。
    //  · 撑宽原来的溢出风险改由**外层**消化：气泡操作行已从 Row 换成可换行的 Wrap
    //    （lib/widgets/message_bubble_v2.dart 的 `_buildActionRow`），
    //    窄屏（320dp 机）四个键齐住时换行，不顶框。
    //  · `widthFactor/heightFactor: 1.0` 是这条链能不能进 Wrap 的关键：
    //    Center 默认不设因子时会把盒子铺满父给的 maxWidth，在 Row(mainAxisSize.min) 里
    //    看不出来，进 Wrap 就变成"每个图标占满整行、一行只住得下一个键"
    //    （本轮量到 1264dp 宽）。钉上因子＝尺寸只跟图标，48 由外层约束兜。
    final child = InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Center(
            widthFactor: 1.0,
            heightFactor: 1.0,
            child: Icon(icon, size: size, color: effectiveColor),
          ),
        ),
      ),
    );
    if (tooltip == null) return child;
    return Tooltip(message: tooltip!, child: child);
  }
}
