import 'package:flutter/material.dart';

import 'tokens.dart';

/// build133：呼吸点（流式/处理中的最弱指示器）。
///
/// 与 `CircularProgressIndicator` 的分工：转圈表达「正在加载/占位」，呼吸点表达
/// 「这条流还活着」。思考面板里已经有一个计时器在跳数字，再叠一个转圈就是双重
/// 噪声 —— 一个缓慢的透明度呼吸既说明「没卡死」，又不抢计时器的信息位。
///
/// 实现取舍：必须用 [AnimationController] 循环 —— `TweenAnimationBuilder` 只跑
/// 一次 0→1 就停在终态（写成那样会「呼吸一下就冻住」）。**reduced 时停表并落终态**：
/// 无障碍模式下不能让一个无限循环的动画继续吃电。
///
/// ⚠️ 测试注意：这是**无限循环**动画，`pumpAndSettle()` 会一直等不到静止而超时；
/// 验证时用 `pump()` / `pump(Duration)`。
class AppPulse extends StatefulWidget {
  const AppPulse({
    super.key,
    this.size = 8,
    this.height,
    this.borderRadius,
    this.color,
    this.period = AppDur.pulse,
  });

  /// 宽度（圆点时即直径）。
  final double size;

  /// 高度；null ⇒ 等于 [size]（圆点）。给值 ⇒ 竖条形态（流式光标）。
  final double? height;

  /// 圆角；null ⇒ 圆形（`shape: circle`）。给值 ⇒ 圆角矩形。
  ///
  /// 流式光标用 `height` + 微圆角表达「文本末尾的竖条」，不要用圆点 ——
  /// 圆点会被读成「又一个 loading」，竖条才读成「光标停在这里」。
  final double? borderRadius;

  /// 颜色；默认取次级文字色（中性，不抢焦点）。
  final Color? color;

  /// 一次呼吸（单程）的时长（令牌）。
  final Duration period;

  @override
  State<AppPulse> createState() => _AppPulseState();
}

class _AppPulseState extends State<AppPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.period,
  );

  @override
  void initState() {
    super.initState();
    // 不在 initState 起表：这里读不到 MediaQuery（reduced 判定），
    // 统一交给 didChangeDependencies 的 _sync()，避免「先转起来再停」。
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // MediaQuery（disableAnimations）变化会走到这里
    _sync();
  }

  @override
  void didUpdateWidget(covariant AppPulse old) {
    super.didUpdateWidget(old);
    if (old.period != widget.period) {
      _c.duration = widget.period;
      _sync();
    }
  }

  /// 让控制器状态与「是否允许动画」保持一致。
  void _sync() {
    if (AppMotion.reduced(context)) {
      if (_c.isAnimating) _c.stop();
      _c.value = 1.0; // 落终态，不停在「半透明」上
    } else if (!_c.isAnimating) {
      _c.repeat(reverse: true);
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
    final color = widget.color ?? cs.onSurfaceVariant;
    // BoxDecoration 里 shape:circle 与 borderRadius **互斥**（后者会断言失败），
    // 所以按形态二选一，而不是两个都传。
    final isBar = widget.height != null || widget.borderRadius != null;
    // 呼吸幅度对齐规格 C1（1.0 ↔ 0.35）：此前实现写的是 0.25，与文档不一致，
    // 统一到文档值 —— 顺带让流式光标在浅色背景下更清楚一点。
    return FadeTransition(
      opacity: _c.drive(Tween<double>(begin: 0.35, end: 1)),
      child: Container(
        width: widget.size,
        height: widget.height ?? widget.size,
        decoration: BoxDecoration(
          color: color,
          shape: isBar ? BoxShape.rectangle : BoxShape.circle,
          borderRadius:
              isBar ? BorderRadius.circular(widget.borderRadius ?? 0) : null,
        ),
      ),
    );
  }
}
