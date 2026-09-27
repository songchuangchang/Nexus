import 'package:flutter/material.dart';

/// build168：**宽屏（平板）档的唯一所有者**。
///
/// ## 为什么要有这个文件
/// 机主从手机换到平板，报的第一眼症状是「输入框上面那一排按钮不适应」。但真正的根因
/// 比那一排大得多：**这个 App 从来没有宽屏档**。全仓在改动前
///  - 没有任何 `LayoutBuilder` 之外的宽度判据（`grep "sizeClass|isTablet|width > 6" lib/` ⇒ 0 命中），
///  - `lib/screens/*.dart` 里 `ConstrainedBox(maxWidth:)` ⇒ 0 命中，
///  - 气泡宽度是 `MediaQuery.size.width * 0.82`（**吃的是屏幕**，不是内容列）。
/// 于是 424dp 手机上处处正确的比例，到 914dp 平板上就变成：
///  · 一行回答约 750dp 宽（约 47 个汉字，眼睛回不到行首）；
///  · 功能行那个 `Spacer()` 把全部余量吞掉，`+` 贴最左、按钮簇贴最右，中间空 700dp。
///
/// ## 这条判据为什么必须只有一个家
/// 「尺寸不许有第二个所有者」在本仓已经为**高度**立过一条闸（D3），教训是同一句话：
/// 一旦每页各自写自己的 magic number，就会出现两种口径并存，下一页照样踩。
/// 所以本文件只定**两个数**（断点、内容列上限），并且只暴露**一个读点**
/// （[AppContent.widthOf]）。逐页 `if (width > 600)` 是这次任务的失败结局，不是解法。
///
/// 数值档与 Material 3 的 window size class 对齐（600 / 840），因为这套断点本来就是
/// 按「多宽才算平板」定的，且 Flutter 官方 `NavigationRail`/`Adaptive` 系列文档用的也是它；
/// 我们**不引** `flutter/foundation` 的 `WindowWidthSizeClass`（3.x 里它在 Material 侧，
/// 且只给档不给列宽），自己写两个常量比挂一个用不上的类型更清楚。
///
/// ## 手机侧零改变是怎么保证的
/// [maxContentWidthFor] 在 compact 档**原样返回屏幕宽度**，[AppContentColumn] 于是
/// 算出 `side == 0` ⇒ 不插 `Padding`。424dp 下渲染树与改动前逐节点同尺寸。
/// 上限只在越过 600dp 之后才咬人，所以手机/窄折叠屏外屏不可能被这次改动挪动。
enum AppSizeTier { compact, medium, expanded }

/// 屏幕档（宽度以**逻辑像素 dp** 计：手机 1080px@408dpi = 424dp，
/// 平板 2400px@420dpi = 914dp —— 判据只能吃 dp，吃物理像素会在两种 dpi 上分叉）。
abstract final class AppBreakpoint {
  /// `medium` 档下界：600dp。
  ///
  /// 出处：Material 3 window size class（compact 上界）。真机两台分别 424 / 914dp，
  /// 这条线两侧各留了 176dp 与 314dp 的余量，落在两档之间的设备（大折叠屏外屏）
  /// 目前一台都没有，所以取标准值而不是自己找一条更好看的线。
  static const double mediumMin = 600;

  /// `expanded` 档下界：840dp（同上，M3 的 medium 上界）。
  static const double expandedMin = 840;

  /// 宽度 → 档。**只此一处**做这个判断，别处一律走它（或走 [AppContent.isWide]）。
  static AppSizeTier tierOf(double width) {
    // NaN / Infinity（无界约束下被误传进来）当紧凑处理：宁可少夹一次，
    // 也不要在没设计过的宽度上凭空造出一个居中的窄列。
    if (!width.isFinite) return AppSizeTier.compact;
    if (width >= expandedMin) return AppSizeTier.expanded;
    if (width >= mediumMin) return AppSizeTier.medium;
    return AppSizeTier.compact;
  }
}

/// 内容列（正文实际占用的那一条）宽度的唯一读点。
abstract final class AppContent {
  /// medium 档列宽上限：640dp。
  ///
  /// 定档口径 = **行长**，不是「看起来还剩多少空地」：正文 15–16sp、汉字字宽≈ 16dp。
  /// 两条线各自算过：
  ///  · 助手正文是**通栏**的（`width: double.infinity`，只减列表 16 + 气泡 20 内边距）
  ///    ⇒ 640 那一档一行约 **38 个汉字**；
  ///  · 用户气泡再乘 0.82（`message_bubble_v2.dart` 那条系数）⇒ 约 31 个汉字。
  /// 40 字上下是中文排版的通行可读带（拉丁侧口径是 60–75 字符，换算过来同一条），
  /// 而改动前平板上是 **49–57 个汉字**一行 —— 行尾回到行主要靠眼球长距离搜寻，
  /// 机主在平板上报的正是这个。
  static const double maxForMedium = 640;

  /// expanded 档列宽上限：720dp（一行约 43 汉字，仍在带内）。
  ///
  /// 为什么不是一档到底：840dp 以上再放宽**列**，可读性并不继续变好，变好的只是
  /// **两翼留白**。平板 OPD2409（914dp）夹到 720 ⇒ 左右各 97dp 墙，列占屏 79% ——
  /// 与手机上「气泡 82%」是同一个观感比例，而行长只比 medium 档多 5 个字。
  /// 要再宽就该走**多栏**（列表一栏 / 侧栏一栏），那不在本 slice 内。
  static const double maxForExpanded = 720;

  /// 屏幕宽度 → 内容列宽度。**手机（compact）原样返回 ⇒ 零改变**。
  static double maxContentWidthFor(double screenWidth) {
    switch (AppBreakpoint.tierOf(screenWidth)) {
      case AppSizeTier.compact:
        return screenWidth;
      case AppSizeTier.medium:
        return screenWidth < maxForMedium ? screenWidth : maxForMedium;
      case AppSizeTier.expanded:
        return screenWidth < maxForExpanded ? screenWidth : maxForExpanded;
    }
  }

  /// 当前这一支子树该按多宽排正文。**下游唯一读点**。
  ///
  /// 有 [AppContentColumn] 祖先时读它定下的那份（见 [AppContentScope]）；
  /// 没有就退化成「按屏幕宽度现算」—— 这条退化正是气泡在平板上的旧口径
  /// （`MediaQuery.size.width * 0.82`）在 compact 档的**同一个数**，
  /// 所以没被列进内容列的页面（设置页、对比页）行为一字不变。
  static double widthOf(BuildContext context) {
    final scoped = AppContentScope.maybeWidthOf(context);
    if (scoped != null) return scoped;
    return maxContentWidthFor(MediaQuery.sizeOf(context).width);
  }

  /// 内容列已经宽到该换排布了吗（当前只有 composer 功能行用这一档）。
  ///
  /// 判据吃的是**列宽**而不是屏宽：功能行真正被摆在列宽里排版，吃屏宽会在
  /// 「列已被夹窄、屏还很宽」的组合下排出一个更空的两端分离。
  static bool isWide(BuildContext context) =>
      AppBreakpoint.tierOf(widthOf(context)) != AppSizeTier.compact;
}

/// [AppContentColumn] 交给后代的那份列宽。
///
/// 为什么不能让消费者自己 `LayoutBuilder` 量：气泡在 `ListView`（自带 8dp 内边距）
/// 里面量到的是 **408**，而它今天吃的是屏幕 **424** ⇒ 0.82 一乘就少 13dp，
/// 手机侧当场"变窄一点"，正是任务里禁止的那种挪动。列宽必须由**定它的那一层**给，
/// 后代只读，不参与推导。
class AppContentScope extends InheritedWidget {
  const AppContentScope({
    super.key,
    required this.contentWidth,
    required super.child,
  });

  /// 这一支的内容列宽度（dp）。
  final double contentWidth;

  static double? maybeWidthOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<AppContentScope>()
      ?.contentWidth;

  /// 只在**列宽真的变了**时通知依赖者。
  ///
  /// 少了这一条，聊天页每来一帧流式 `setState` 都会把整棵内容列标脏：
  /// 流式期间气泡是逐 token 重建的，那种"祖先一抖全家重画"本文件不该引入。
  @override
  bool updateShouldNotify(AppContentScope oldWidget) =>
      contentWidth != oldWidget.contentWidth;
}

/// 把子节点收进内容列：**居中 + 夹宽**，两件事只在这一处发生。
///
/// 用 `Padding`（两侧各让出 `(可用宽 - 列宽)/2`）而不是 `Center + ConstrainedBox`：
/// 后者会把**纵向**约束也松开（`Align` 给孩子的最小约束归零），
/// 而内容列里放的是 `Expanded → ListView`，纵向一旦松开就是整列高度重算；
/// 手机侧更要紧的是 `side == 0` 时可以**一个节点都不插**（见 build），
/// 于是 424dp 下渲染树与改动前逐字相同，不需要"看起来应该没变"这种信念。
class AppContentColumn extends StatelessWidget {
  const AppContentColumn({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // 本层是列宽的**定义点**，所以它吃屏幕宽度；后代改吃 [AppContent.widthOf]。
    final cap =
        AppContent.maxContentWidthFor(MediaQuery.sizeOf(context).width);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final available = constraints.maxWidth;
        if (!available.isFinite || available <= cap) {
          // 无界（横向滚动容器里）或还没到要夹的宽度 ⇒ 不插 Padding，只把列宽告诉后代。
          return AppContentScope(
            contentWidth: available.isFinite ? available : cap,
            child: child,
          );
        }
        final side = (available - cap) / 2.0;
        return AppContentScope(
          contentWidth: cap,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: side),
            child: child,
          ),
        );
      },
    );
  }
}
