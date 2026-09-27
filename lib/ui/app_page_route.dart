import 'package:flutter/material.dart';

import 'tokens.dart';

/// 统一页面转场（build133）：淡入 + 2% 轻微上移。
///
/// 为什么自己写一条：Flutter 各平台默认转场不一致（Android 上是 `ZoomPageTransitionsBuilder`
/// 那种「整页放大」），在一个强调「朴素、克制」的 App 里显得过火；而 Material 3 的
/// 默认转场会带一点缩放，和聊天页「内容从下方接着长出来」的观感不一致。
///
/// 三个刻意的取值：
/// ① **位移只有 2%**：位移越大越像「翻页」，越小越像「内容浮现」；
/// ② 时长走 [AppDur.base]（200ms）——比系统默认（300ms）快，聊天场景要「跟手」；
/// ③ `reverseTransitionDuration` 同长：退出比进入慢会显得黏。
///
/// ⚠️ reduced（无障碍「移除动画」）时直接返回子页，不做任何过渡 —— 但**时长仍会流逝**
/// 一瞬（路由时长在构造期定死，`MediaQuery` 那时还拿不到），实测无感，故不额外处理。
class AppPageRoute<T> extends PageRouteBuilder<T> {
  AppPageRoute({
    required WidgetBuilder builder,
    super.settings,
    super.fullscreenDialog,
    Duration? duration,
  }) : super(
          transitionDuration: duration ?? AppDur.base,
          reverseTransitionDuration: duration ?? AppDur.base,
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            if (AppMotion.reduced(context)) return child;
            final curved = CurvedAnimation(
              parent: animation,
              curve: AppCurve.enter,
              reverseCurve: AppCurve.exit,
            );
            return FadeTransition(
              opacity: curved,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.02),
                  end: Offset.zero,
                ).animate(curved),
                child: child,
              ),
            );
          },
        );
}
