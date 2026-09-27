import 'package:flutter/material.dart';

import 'app_state_icon.dart';
import 'tokens.dart';

/// 空态（build133）：图标 + 一句话 +（可选）一个动作。
///
/// 纪律：空态**必须**说清「为什么空」和「接下来能做什么」。只画一个灰图标加
/// 「暂无数据」，用户只能退出去猜 —— 这是空态最常见的失败。
/// 所以 [title] 必填，[subtitle]/[action] 视场景给（无动作可给时宁可把 title 写细）。
class AppEmptyView extends StatelessWidget {
  const AppEmptyView({
    super.key,
    required this.title,
    this.subtitle,
    this.icon = Icons.inbox_outlined,
    this.action,
    this.compact = false,
  });

  final String title;
  final String? subtitle;
  final IconData icon;

  /// 主动作（如「去创建」）；不给则不占位。
  final Widget? action;

  /// 紧凑版（嵌在卡片/面板里用），缩小间距。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final Widget content = Padding(
          padding: EdgeInsets.symmetric(
            horizontal: AppGap.xl,
            vertical: compact ? AppGap.lg : AppGap.xl * 2,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: compact ? 24 : 32, color: cs.appTextFaint),
              SizedBox(height: compact ? AppGap.sm : AppGap.md),
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (subtitle != null) ...<Widget>[
                const SizedBox(height: AppGap.xs),
                Text(
                  subtitle!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.appTextFaint,
                  ),
                ),
              ],
              if (action != null) ...<Widget>[
                SizedBox(height: compact ? AppGap.md : AppGap.lg),
                action!,
              ],
            ],
          ),
        );
        // L7：空态承诺的那条"出路"（action 按钮）不能被顶出屏幕——
        // 溢出（或画到视口外）的子节点不参与命中测试，用户只能退出这个页面。
        // 所以：外面套 SingleChildScrollView 保证滚得到；再用
        // ConstrainedBox(minHeight: 视口高) + Center 保住"空间够时居中"。
        // minHeight 给到 Center 的约束下限，Center 会把自身撑满视口、内容居中；
        // 内容超过视口时又自然回到可滚动。父级无界（嵌在列表里）时不设下限。
        final double viewportHeight = constraints.maxHeight;
        return SingleChildScrollView(
          child: viewportHeight.isFinite
              ? ConstrainedBox(
                  constraints: BoxConstraints(minHeight: viewportHeight),
                  child: Center(child: content),
                )
              : Center(child: content),
        );
      },
    );
  }
}

/// 错误态（build133）：图标 + 说明 + 重试。
///
/// 与 [AppEmptyView] 分开而不是合成一个 `StateView`：错误**必须有出路**（重试），
/// 空态通常没有；合成一个组件后，调用方总有一半参数用不上，最终还是会分叉。
///
/// [detail] 默认不展示原始异常文本（`Exception: ...` 对用户无意义），
/// 需要排查时由调用方显式传入。
class AppErrorView extends StatelessWidget {
  const AppErrorView({
    super.key,
    this.title,
    this.detail,
    this.onRetry,
    this.zh = true,
    this.compact = false,
  });

  final String? title;
  final String? detail;
  final VoidCallback? onRetry;
  final bool zh;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: AppGap.xl,
          vertical: compact ? AppGap.lg : AppGap.xl * 2,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const AppStateIcon(state: AppRunState.error, size: 28),
            SizedBox(height: compact ? AppGap.sm : AppGap.md),
            Text(
              title ?? (zh ? '加载失败' : 'Failed to load'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: cs.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (detail != null) ...<Widget>[
              const SizedBox(height: AppGap.xs),
              Text(
                detail!,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.appTextFaint,
                ),
              ),
            ],
            if (onRetry != null) ...<Widget>[
              SizedBox(height: compact ? AppGap.md : AppGap.lg),
              TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 16),
                label: Text(zh ? '重试' : 'Retry'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
