import 'package:flutter/material.dart';

import 'tokens.dart';

/// 任务 #89（build165）：容器级连续过渡（"无缝"的正身：连续的是容器，不是某张图）。
///
/// ## ⚠️ build167 起：**本文件当前没有生产调用点**（接线已撤，组件保留）
/// 165 把它接在「产物卡片 → HTML 预览页」。用户 26 日 19:02 报
/// 「会闪屏，不到一秒就好」并附截图（截图正是飞行中途那一帧）：
/// shuttle 的形状是"正文留在原位、容器从它上面盖过去"，而预览页主体是
/// **平台视图 WebView**、进页第一帧就把内容画好了 ⇒ 那 450ms 里屏幕上是一块
/// **近黑的不透明容器**在长大，盖在已经看得见的表格上面。
/// 取证与决定见 `docs/BUGSCAN_build166_20260926.md` ④；
/// 预览页一侧另有一条源码契约闸，禁止有人"因为好看"再把它接回去
/// （`test/build165_motion_tokens_test.dart` 的 ⑥ 组）。
///
/// **重新接线之前必须先解决的两件事**（不是"以后再说"，是接之前的硬条件）：
///  1. 目标页**不能是平台视图**（WebView / 视频 / 地图）—— 飞行体内放平台视图是
///     官方明令避坑的形态，而且它盖住已渲染内容的问题与这里一模一样；
///  2. **同屏不许出现两个同 tag 的源**（`tagOf` 含 messageId 只挡住了跨消息撞车；
///     同一条消息里同一张图渲染两处会直接触发框架的 duplicate-tag 断言）。
///     图片全屏预览是最合适的下一个落点，但落之前要先确认这一点（或给 tag 加序号）。
/// 组件本身仍然被 ⑤ 组直接测着（真飞行 / 可打断 / reduced 一帧落终态），
/// 所以它不是死代码，只是**没有消费者**——这两件事本仓从不混着说。
///
/// ## 形态（以本仓 Flutter 3.47 SDK 实读为准）
/// 该 SDK **没有** M3 expressive 的 container transform API
/// （`grep -rin containertransform packages/flutter/lib` 0 命中，
/// 无 `MaterialHeroController`/`containerTransformBuilder`/`ContainerTransition`）。
/// 所以这里用 `Hero` + 自定义 `flightShuttleBuilder` 手搓官方等价形态：
///  · 飞的是**容器**：圆角半径 + 底色 + 矩形几何连续插值（卡片是圆角浅灰块，
///    落位是全屏直角容器 ⇒ 形状/尺寸全程连续，没有硬切）；
///  · 卡片文字与目标页正文**不飞行**（目标页主体是平台视图 WebView，飞行体内
///    放平台视图是官方明令避坑的形态）；内容交替由目标页路由淡入承担
///    （container transform "内容交叉淡变"的那一半）；
///  · 矩形路径 **linear**（`createRectTween` 给普通 `RectTween`，
///    不用 MaterialApp 默认的弧线 `MaterialRectArcTween` —— MDC 对
///    container transform 的 motionPath 规定就是 linear）；
///  · 曲线 [AppSpring.spatialSlowShape]（"转场用 slow + 空间量用 spatial"，
///    轻微 overshoot）；时长 [AppDur.containerEnter]（long1 进入）/
///    [AppDur.slow]（medium2 离开），由调用点经 `AppMotion.duration` 取。
///
/// ## 可打断
/// 飞行挂在路由动画上（SDK `widgets/heroes.dart` 实读：push 飞行
/// `parent = toRoute.animation`，pop/divert 走 `ReverseAnimation`/`divert`），
/// 中途系统返回 = 路由原地倒放，shuttle 沿同一形状飞回卡片；
/// 再次开合同类转场由框架 `divert` 接管。不存在"半程残影"路径。
///
/// ## 两条硬约束都守住
///  · **不新增动画开关**：`disableAnimations` 的唯一读点仍是
///    [AppMotion.reduced]；reduced 时本组件用 `HeroMode(enabled: false)`
///    干脆不起飞 + 调用点时长已被 `AppMotion.duration` 归零 ⇒ 同帧落终态
///    （弹簧档在此同样落终态：`AppSpringShape.transform(≥1) == 1.0`，
///    且时长为 0 时路由动画没有"收敛中"的中间帧可言）。
///  · **不给布局尺寸引入第二个所有者**：shuttle 是 overlay 里的独立容器，
///    不读任何 child.size；`AnimatedSize`/`AnimatedContainer`/`SizeTransition`
///    在本文件零出现（桌面侧 D3 闸同拦，这里不但不碰、也不给自己开口子）。
class AppContainerHero extends StatelessWidget {
  const AppContainerHero({
    super.key,
    required this.tag,
    required this.child,
    this.holdChildInFlight = false,
  });

  /// 两端的同一个标识。卡片侧与预览页侧都经 [AppContainerHero.tagOf] 生成，
  /// 保证"同一份口径"（预览页自己不猜 tag）。
  final Object tag;

  /// 无飞行时的本体（卡片主体 / 预览页 body）。
  final Widget child;

  /// 目标页一侧置 true：飞行期间目标页正文**留在原位继续渲染**，
  /// 由飞行的容器从上盖过 —— SDK 默认会把目标 hero 的 child 藏到飞行结束，
  /// 那样变形容器周围会露出一个空洞。卡片侧不需要（默认 placeholder
  /// 已经保住占位尺寸，聊天列表不跳动）。
  final bool holdChildInFlight;

  /// 转场两端共享的 tag：**必须含 messageId** —— 同一会话里不同消息
  /// 各自写过同一个 rel 是真实存在过的场景，同屏两个同名 Hero 会直接
  /// 触发框架的 duplicate-tag 断言。
  static String tagOf(String messageId, String workspaceRel) =>
      'artifact:$messageId:$workspaceRel';

  @override
  Widget build(BuildContext context) {
    final hero = Hero(
      tag: tag,
      // 形状：慢空间弹簧（MDC：转场/全屏 → slow；位移/尺寸 → spatial）
      curve: AppSpring.spatialSlowShape,
      // 路径：linear（container transform 的 motionPath 规定）
      createRectTween: (Rect? begin, Rect? end) =>
          RectTween(begin: begin, end: end),
      flightShuttleBuilder: _containerShuttle,
      // SDK typedef（3.47 实测）：(context, heroSize, child) => Widget。
      // 目标页一侧把原 child 原样放回 ⇒ 飞行期间正文留在原位（容器从它上面
      // 盖过去）；卡片侧用框架默认 placeholder（保位不塌）。
      placeholderBuilder:
          holdChildInFlight ? (context, size, child) => child : null,
      child: child,
    );
    if (AppMotion.reduced(context)) {
      // 整棵子树的 Hero 退出飞行匹配 ⇒ 硬切到终态，弹簧也不"收敛中"。
      return HeroMode(enabled: false, child: hero);
    }
    return hero;
  }
}

/// 飞行体：**只有容器在变形**（圆角 radius 连续收到 0、底色从卡片档
/// 过渡到页面档）。不引用任何一端的 child —— 两端内容分别由
/// "源侧 placeholder"与"目标侧原位渲染 + 路由淡入"交代。
Widget _containerShuttle(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection flightDirection,
  BuildContext fromHeroContext,
  BuildContext toHeroContext,
) {
  final cs = Theme.of(flightContext).colorScheme;
  return AnimatedBuilder(
    animation: animation,
    builder: (context, _) {
      // 弹簧档允许轻微 overshoot：圆角/颜色这类装饰量落到端点就停，
      // 不许出现负半径（BorderRadius 会 assert），所以几何量用 raw、
      // 装饰量用 clamp 后的值。
      final raw = animation.value;
      final t = raw.clamp(0.0, 1.0);
      return ClipRRect(
        borderRadius: BorderRadius.circular(
          (AppRadius.panel * (1.0 - t)).clamp(0.0, AppRadius.panel),
        ),
        child: ColoredBox(
          color: Color.lerp(cs.surfaceContainerHighest, cs.surface, t)!,
        ),
      );
    },
  );
}

/// 承载 [AppContainerHero] 的路由：只做**淡入淡出**，位移全在飞行的容器上。
///
/// `duration/reverseDuration` 必须由调用点经 `AppMotion.duration(context, …)`
/// 传入（reduced ⇒ Duration.zero ⇒ 同帧落终态，飞行根本来不及有中间帧）。
class AppContainerTransformRoute<T> extends PageRouteBuilder<T> {
  AppContainerTransformRoute({
    required WidgetBuilder builder,
    super.settings,
    required Duration duration,
    required Duration reverseDuration,
  }) : super(
          transitionDuration: duration,
          reverseTransitionDuration: reverseDuration,
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            if (AppMotion.reduced(context)) return child;
            final curved = CurvedAnimation(
              parent: animation,
              curve: AppCurve.standard,
              reverseCurve: AppCurve.exit,
            );
            return FadeTransition(opacity: curved, child: child);
          },
        );
}
