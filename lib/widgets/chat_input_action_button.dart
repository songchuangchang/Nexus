import 'package:flutter/material.dart';
import '../ui/tokens.dart';

/// 紧凑型切换按钮（v1.7.18 需求2/7）
///
/// 抽自 ChatInput._buildCompactToggle，承载 搜索 / 思考 / 插件 三处复用。
/// 图标 + 可选文字标签，比 IconButton 更小；支持 badge（角标）与 onLongPress。
///
/// 需求7：搜索/思考 的 onLongPress 由调用方注入「弹 SnackBar 提示左滑打开快速菜单」，
/// 插件的 onLongPress 注入 onEditPluginHint（长按弹插件面板）——本组件不感知语义，
/// 仅按注入的回调执行。
///
/// build126（B1）：**去掉 emoji 标签**（原来 label 直接传 '🌐' / '🧠' / '🔌'，
/// 等于用 emoji 当按钮文字）。`label` 改为可空，传 null 时渲染为**纯图标按钮**，
/// 适配 composer 底部功能行的高度。
///
/// build138（#3）：**角标由「六七像素的小字」改为「无字圆点」**。原来三个按钮的角标是
/// `DEF` / `MAX` / `65%` / `AUTO` / `3` 这类字符串，缩到六七像素后在真机上糊成一团，
/// 还与提示条文字、裸状态文字重复表达同一件事（同屏三处）。现在视觉只留一个
/// 8dp 圆点表示「此态已生效」，**具体档位/数量折进 `Semantics.label`**，读屏与
/// tooltip 仍能给全信息（`badge` 参数语义不变：null = 不画点）。
///
/// ⚠️ 无障碍回归防护：改造前读屏靠**可见文字**识别这三个按钮，纯图标化后会读不出来。
/// 因此这里统一用 `Semantics(button: true, enabled: ..., label: tooltip)` 补上，
/// 由 tooltip 充当读屏标签。**刻意不包 Tooltip** —— Tooltip 默认
/// `TooltipTriggerMode.longPress` 会抢走 onLongPress，破坏「长按跳设置页」。
class ActionButton extends StatelessWidget {
  final IconData icon;

  /// 可见文字标签。build126 起可空；null = 纯图标（不再用 emoji 当标签）。
  final String? label;
  final bool enabled;
  final bool active;
  final String tooltip;

  /// 角标语义。**build138 起只决定「画不画圆点」与读屏文案，文字本身不再渲染**；
  /// null = 无角标。传 `'DEF'` / `'65%'` / `'AUTO'` / `'3'` 等仍照旧进 Semantics。
  final String? badge;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const ActionButton({
    super.key,
    required this.icon,
    required this.enabled,
    required this.active,
    required this.tooltip,
    this.label,
    this.badge,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final iconColor = !enabled
        ? cs.outline
        : active
            ? cs.onSurface
            : cs.onSurfaceVariant;
    return Semantics(
      button: true,
      enabled: enabled,
      // build138（#3）：角标由文字改无字圆点后，「DEF / 65% / AUTO / 3」这些值只有
      // 这里还能拿到 —— 折进读屏标签，视觉上省略、无障碍上不丢信息。
      label: badge == null ? tooltip : '$tooltip · $badge',
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        behavior: HitTestBehavior.opaque,
        child: Container(
          margin: const EdgeInsets.only(right: 4),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: active ? cs.appPanel : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.panel),
            border: active ? Border.all(color: cs.appBorder) : null,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(icon, size: 18, color: iconColor),
                  if (badge != null)
                    // build138（#3）：无字圆点。7dp、贴在图标右上角（不越出按钮框），
                    // 生效态用 primary、未生效却带角标（如思考档为 0 仍显示 DEF）用
                    // error 兜底。取色跟随已批准的方案 B 视觉稿 `.bdg.dot`。
                    Positioned(
                      right: 0,
                      top: 0,
                      child: Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: active ? cs.primary : cs.error,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                ],
              ),

              if (label != null) ...[
                const SizedBox(height: 2),
                Text(
                  label!,
                  style: TextStyle(fontSize: 10, color: iconColor),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
