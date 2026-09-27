import 'package:flutter/material.dart';

import 'tokens.dart';

/// 骨架形态（由命名构造器固化，避免用「有没有给行数」这种不可靠信号去猜）。
enum _Shape { bar, lines, bubble, card, circle, list }

/// 骨架屏（build133）：等宽条 + 一条滑过的高光。
///
/// 为什么不用 `CircularProgressIndicator` 顶替：整页/整块内容加载时，骨架屏给出的是
/// **版式预期**（这里将出现三行文字 / 一个头像 + 两行），转圈只给出「在转」。
/// 但它不是万能的：只在「形状可预知」时用；未知形状（如整段 markdown）用四态图标。
///
/// 三条实现纪律：
/// ① 高光靠 `GradientTransform` 平移渐变（不是 `ShaderMask`），少一层合成；
/// ② 时长走 [AppDur.skeleton]，**reduced 时停表并落静态灰条**（不闪）；
/// ③ 形状圆角一律用令牌（[AppRadius]），与真内容对齐 —— 骨架与真内容圆角不一致，
///    切换瞬间会「跳一下」，比不显示骨架还刺眼。
///
/// ⚠️ 与 [AppPulse] 同：无限循环动画，测试里别用 `pumpAndSettle()`。
class AppSkeleton extends StatelessWidget {
  /// 单条灰条。
  const AppSkeleton({
    super.key,
    this.width,
    this.height = 12,
    this.radius = AppRadius.inline,
    this.spacing = AppGap.sm,
    this.lastFactor = 0.6,
  })  : _shape = _Shape.bar,
        _count = 0;

  /// 单行文字占位（与默认构造同形，读起来更明确）。
  const AppSkeleton.line({
    super.key,
    this.width,
    this.height = 12,
    this.radius = AppRadius.inline,
    this.spacing = AppGap.sm,
    this.lastFactor = 0.6,
  })  : _shape = _Shape.bar,
        _count = 0;

  /// 多行文字占位：末行按 [lastFactor] 收短（真段落不会等宽）。
  const AppSkeleton.lines(
    int count, {
    super.key,
    this.width,
    this.height = 12,
    this.radius = AppRadius.inline,
    this.spacing = AppGap.sm,
    this.lastFactor = 0.6,
  })  : _shape = _Shape.lines,
        _count = count;

  /// 思考面板占位（与真面板同底、同圆角 [AppRadius.panel]）。
  const AppSkeleton.bubble({
    super.key,
    int count = 3,
    this.width,
    this.height = 12,
    this.radius = AppRadius.inline,
    this.spacing = AppGap.sm,
    this.lastFactor = 0.6,
  })  : _shape = _Shape.bubble,
        _count = count;

  /// 设置分组卡片占位（[AppRadius.card]）。
  const AppSkeleton.card({
    super.key,
    int count = 3,
    this.width,
    this.height = 12,
    this.radius = AppRadius.inline,
    this.spacing = AppGap.sm,
    this.lastFactor = 0.6,
  })  : _shape = _Shape.card,
        _count = count;

  /// 头像 / 缩略图占位。
  const AppSkeleton.circle({super.key, double size = 32})
      : _shape = _Shape.circle,
        _count = 0,
        width = size,
        height = size,
        radius = 999,
        spacing = AppGap.sm,
        lastFactor = 0.6;

  /// 会话列表占位：[count] 行「头像 + 两行文字」。
  const AppSkeleton.list({
    super.key,
    int count = 3,
    this.width,
    this.height = 12,
    this.radius = AppRadius.inline,
    this.spacing = AppGap.sm,
    this.lastFactor = 0.6,
  })  : _shape = _Shape.list,
        _count = count;

  final double? width;
  final double height;
  final double radius;

  /// 多行之间的间距。
  final double spacing;

  /// 末行宽度比例。
  final double lastFactor;

  final _Shape _shape;
  final int _count;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    switch (_shape) {
      case _Shape.bar:
      case _Shape.circle:
        return _bar(width: width, height: height, radius: radius);
      case _Shape.lines:
        return _linesBlock();
      case _Shape.bubble:
        return Container(
          padding: AppPad.panel,
          decoration: BoxDecoration(
            color: cs.appPanel,
            borderRadius: BorderRadius.circular(AppRadius.panel),
          ),
          child: _linesBlock(),
        );
      case _Shape.card:
        return Container(
          padding: AppPad.card,
          decoration: BoxDecoration(
            color: cs.appPanel,
            borderRadius: BorderRadius.circular(AppRadius.card),
          ),
          child: _linesBlock(),
        );
      case _Shape.list:
        return _listBlock();
    }
  }

  Widget _linesBlock() {
    final n = _count <= 0 ? 1 : _count;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (int i = 0; i < n; i++) ...<Widget>[
          if (i > 0) SizedBox(height: spacing),
          if (i == n - 1 && n > 1)
            FractionallySizedBox(
              widthFactor: lastFactor,
              alignment: Alignment.centerLeft,
              child: _bar(width: null, height: height, radius: radius),
            )
          else
            _bar(width: width, height: height, radius: radius),
        ],
      ],
    );
  }

  Widget _listBlock() {
    final n = _count <= 0 ? 1 : _count;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < n; i++) ...<Widget>[
          if (i > 0) const SizedBox(height: AppGap.lg),
          const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              AppSkeleton.circle(size: 32),
              SizedBox(width: AppGap.md),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    AppSkeleton(height: 12),
                    SizedBox(height: AppGap.sm),
                    AppSkeleton(width: 120, height: 12),
                  ],
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _bar({required double? width, required double height, required double radius}) =>
      _SkeletonBar(width: width, height: height, radius: radius);
}

/// 高光滑块：把渐变整体左右平移，形成「一条高光扫过」的观感。
class _SlideGradient extends GradientTransform {
  const _SlideGradient(this.slide);

  final double slide;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(bounds.width * slide, 0, 0);
}

/// 单条骨架（唯一持有动画的地方）。
class _SkeletonBar extends StatefulWidget {
  const _SkeletonBar({this.width, this.height = 12, this.radius = AppRadius.inline});

  final double? width;
  final double height;
  final double radius;

  @override
  State<_SkeletonBar> createState() => _SkeletonBarState();
}

class _SkeletonBarState extends State<_SkeletonBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: AppDur.skeleton,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.reduced(context)) {
      if (_c.isAnimating) _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose(); // 铁律：销毁后回调不得再跑
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final reduced = AppMotion.reduced(context);
    final base = cs.surfaceContainerHighest.withValues(alpha: 0.5);
    final highlight = cs.surfaceContainerHighest.withValues(alpha: 0.15);
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Container(
        width: widget.width ?? double.infinity,
        height: widget.height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.radius),
          color: reduced ? base : null,
          gradient: reduced
              ? null
              : LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: <Color>[base, highlight, base],
                  stops: const <double>[0.1, 0.5, 0.9],
                  transform: _SlideGradient(_c.value * 2 - 1),
                ),
        ),
      ),
    );
  }
}
