import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

// build182 扫描轮：读数合并窗的时长走令牌（D1：字面时长只许住 tokens.dart）。
import 'tokens.dart';

/// **整窗背景 + 系统条避让的唯一所有者**（build182 / #160）。
///
/// ## 为什么现在才立这一条
/// 用户 2026-10-03 的话是「平板功能键这些也是，我们目的是通用」「目的是大部份设备都通用」。
/// 在这之前这两件事**没有所有者**：
///  · 背景：每个 `Scaffold` 各画各的 `scaffoldBackgroundColor`，页面没铺满的那一条
///    （宽屏内容列两翼、旋转/分屏后新露出来的边）落给谁画，全凭下一帧谁先到；
///  · 避让：全仓 `grep "systemGestureInsets|viewPadding" lib/` ⇒ **0 命中**，
///    `MediaQuery.padding` 只在 `chat_input.dart:171` 被读过一次（`.top`），
///    49 个屏幕里 37 个连 `SafeArea` 都没写。
/// 之所以一直没出事，是因为 `ScrollView` 在 `padding==null` 时**自己**去吃
/// `MediaQuery.padding`（`scroll_view.dart:900-920`，并且会把吃掉的这份从交给子孙的
/// MediaQuery 里摘掉，所以套在列表里的 `SafeArea` 不会重复扣）。也就是说
/// **避让一直是"顺带生效"的，不是被谁定下来的** —— 系统报了 insets 就正好对，
/// 系统不报就正好错，而这两条路都没有人守着。
///
/// ## 真机读数（这台平板，2026-10-03 23:5x 现读，不是推断）
///  · `wm size` 2400x3392 / `wm density` 420 ⇒ 914.3x1292.2dp；`navigation_mode=2`；
///  · `dumpsys window`：`init=2400x3392 app=2400x3392`（窗口真的铺满整块屏），
///    `statusBars frame=[0,0][2400,105]`（=40dp），
///    `navigationBars frame=[0,0][0,0] insetsSize=Insets{bottom=0} flags=SUPPRESS_SCRIM|TASK_BAR`
///    ⇒ **系统一条都不给**；
///  · 屏幕像素侧再用 `tablet_sweep/pill_scan.py` 连查两张（idle 与刚交互后）：
///    底部 340 行中央 60% 区域里**没有**宽 ≥24dp 的横条 ⇒ 这台机是"隐藏手势条"的形态。
/// 结论有两条，方向相反，都得认：
///  ① 这台平板**当前没有被系统栏压住的控件** —— 所以"避让量"不许写死成任何一个数，
///     写死了就是在这台机上凭空抬一条带子，正是用户反对的"给平板开特例"；
///  ② 但"报 0"是**这一台**的事实，不是全平台的事实：`systemGestureInsets` 这一路
///     （Android Q 起，系统在该区域内吃掉滑动、不给 App）与 `padding` 是**两个独立来源**，
///     谁大谁才算真带子。绝大多数设备 `padding` 已 ≥ 它，少数（三键＋沉浸式、
///     部分厂商全屏手势）是 `padding=0` 而手势区照吃不误 —— 那才是"点不到"的那一类。
///
/// ## 因此唯一判据是：**上下两条边**取 max、只抬不降；左右不参与
/// `band.top/bottom = max(padding, systemGestureInsets − viewInsets)`，左右只跟 `padding`（挖孔/刘海那条）。
/// 这条算术本身就是"手机侧零改变"的证明，不需要信念：
/// 手机（含这台平板）今天上下两条 `padding ≥ gestureInsets` ⇒ `band == padding` ⇒ 交给子孙的
/// MediaQuery 与改动前**逐字段相同**，渲染树一个节点都不多。只有"系统吃触摸却不预留"
/// 的那一类设备会被抬起来，而那正是需要修的那种。
/// 左右这一维**是装机之后才砍掉的**：平板横屏第一帧就报 `left/right=29.7 lifted=1`，
/// 全边 max 等于把整屏内容往里缩 60dp —— 那个位置该让给"横向拖的控件"，不该让正文陪绑
/// （判据与 Flutter 原文逐字写在 [AppSystemBand.of]）。
///
/// ## 为什么落在 `MaterialApp.builder` 而不是逐页
/// 逐页 `SafeArea` 是 37 处改动，且下一版新页照样漏（本仓为宽度立 `AppContent` 时
/// 已经付过一次"两种口径并存"的学费，见 `lib/ui/app_content.dart` 文件头）。
/// 装在 builder 一处 ⇒ 49 个屏幕、以后新增的每一屏、路由栈里所有 push 页共用同一份
/// 读数；页面自己爱用 `SafeArea` 还是让列表自动吃，吃的都是**同一个数**。
class AppWindowChrome extends StatefulWidget {
  const AppWindowChrome({
    super.key,
    required this.child,
    this.readout,
  });

  final Widget child;

  /// 读数出口（真机验收唯一通道）。规则三条，缺一不可：
  ///  · **只在数值真的变了**时才算一次（含 `raw`：那一行印的 `rawBottom`/`lifted` 由它算，
  ///    只比 `band` 会让"系统从报 48 改成报 0"这类过渡永不重报 ⇒ 旧行长期撒谎）；
  ///  · 变化**并成一条**（静默 [AppWait.readoutQuiet] 后报当下那一份），否则 IME 动画逐帧刷，
  ///    `logger_service` 的环形缓冲整层被换掉；
  ///  · 但**不许被合并窗闷死**：连续变档不安静时最长 [AppWait.readoutMaxWait] 仍出一条，
  ///    且**第一行不等静默**（装机后第一次启动必须一定读得到）。
  final void Function(AppBandReadout readout)? readout;

  @override
  State<AppWindowChrome> createState() => _AppWindowChromeState();
}

class _AppWindowChromeState extends State<AppWindowChrome> {
  AppBandReadout? _last;
  AppBandReadout? _pending;
  Timer? _debounce;
  Timer? _cap;

  /// 读数合并窗口：取自 [AppWait.readoutQuiet]（**不在这里写字面时长** ——
  /// D1 那道闸的口径是"字面时长只许住 tokens.dart"，我 10-04 先在这儿写了 400ms，
  /// `desktop_motion_guard_test` 当场判红，红得对）。
  /// 为什么要合并：IME 弹出/收起那 ~15 帧里 `padding.bottom` 是**连续插值**的，
  /// 逐帧回调＝一次开键盘几十条日志，把 `logger_service` 的环形缓冲整层换掉。
  /// 稳定之后报**当下那一份**：值没丢（报的是最新一次），条数从"每帧"变成"每态"。
  static const Duration _quiet = AppWait.readoutQuiet;

  /// 合并窗的**上限**（[AppWait.readoutMaxWait]，第二轮扫描报的）：
  /// 纯 trailing 的 debounce 在"连续变化永不静"的那一类设备上是**会一声不响**的——
  /// 分屏拖动、DeX／自由窗口缩放、抖动型 IME 都会让合并窗不断重新计时 ⇒
  /// 整段操作一行都不落，而这一行是 #160 装机后唯一的通道。
  /// 到点强制出一行：报的还是当下那一份，只是不再等"静"。
  static const Duration _maxWait = AppWait.readoutMaxWait;

  @override
  void dispose() {
    _debounce?.cancel();
    _cap?.cancel();
    _pending = null;
    super.dispose();
  }

  /// 落一行读数。两条纪律：
  ///  · **不许在 build 里同步回调**（回调方是 `LoggerService`，但这是个公开出口，
  ///    下一个调用方完全可能写成 setState）⇒ 首个读数走微任务，同帧但不在这帧的 build 里；
  ///  · 取的是**落盘那一刻**的 `widget.readout`，不是排期那一刻的引用
  ///    （第二轮扫描第三条：换回调或置 null 之后，旧闭包还会替人报一次）。
  void _flush() {
    _debounce?.cancel();
    _debounce = null;
    _cap?.cancel();
    _cap = null;
    final pending = _pending;
    _pending = null;
    if (pending == null || !mounted) return;
    widget.readout?.call(pending);
  }

  void _scheduleReport(AppBandReadout next, {required bool isFirst}) {
    _pending = next;
    if (isFirst) {
      // 装机后第一次启动必须一定读得到：这一行不等静默窗（微任务＝同一帧内）。
      scheduleMicrotask(_flush);
      return;
    }
    _debounce?.cancel();
    _debounce = Timer(_quiet, _flush);
    if (!(_cap?.isActive ?? false)) _cap = Timer(_maxWait, _flush);
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final band = AppSystemBand.of(mq);
    final next = AppBandReadout(
      raw: mq.padding,
      band: band,
      side: AppSystemBand.sideGestureOf(mq),
    );
    final last = _last;
    if (last == null || last != next) {
      // **没接线就一格都不记**（10-04 第三轮扫描第四条）：`_last = next` 原来写在
      // `widget.readout != null` 那道闸的**外面**，于是"第一帧没接 readout、之后才接上"
      // 那条路上 `_last` 早已非空 ⇒ `isFirst` 再也不为真 ⇒ 上面刚承诺的
      // "装机后第一次启动必须一定读得到"只对**恰好从第一帧就接线**的调用方成立。
      // 今天 `main.dart` 确实每帧都传 ⇒ 这是洞、不是事故；补上是为了下一个接线的人
      // 不必先读源码才知道"要在第一帧之前就接好"。
      if (widget.readout != null) {
        _last = next;
        _scheduleReport(next, isFirst: last == null);
      }
    }
    // 只抬不降：`viewPadding` 一起抬，保持 `viewPadding ≥ padding` 这条不变式
    //（`Scaffold` 的 snack bar / `extendBody` 那几处同时读这两个值，
    //  只动一个会造出"预留比屏幕外沿还小"的第三种口径）。
    final raised = mq.copyWith(
      padding: band,
      viewPadding: AppSystemBand.atLeast(base: mq.viewPadding, gesture: band),
    );
    return MediaQuery(
      data: raised,
      // 背景落在这一层、且落在 Navigator **外面**：整块窗口由它负责，
      // 页面画到哪儿为止都不影响"画不满的那一条是什么颜色"。
      child: ColoredBox(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: widget.child,
      ),
    );
  }
}

/// 系统条带子的**唯一算式**。纯函数，所以四档设备画像能在单测里逐格判。
abstract final class AppSystemBand {
  /// 逐条边 `max(padding, systemGestureInsets)`，**但只作用在上下两条边**。
  ///
  /// 左右为什么不抬（10-04 06:45 装机现读改的口径，不是设计时想出来的）：
  /// 平板横屏那一档真机报的是 `top=40 bottom=0 left=29.7 right=29.7 lifted=1`
  /// —— 侧边那 29.7dp 是**系统吃掉横向返回滑动**的区域，`padding` 不报它。
  /// 按 `max` 全边抬，等于把整屏内容左右各让 29.7dp：横屏 1292dp 白掉 60dp，
  /// 而 Flutter 对这一路读数的原话是
  /// "Apps should avoid locating **gesture detectors** within the system gesture insets area.
  ///  Apps should feel free to put **visual elements** within this area."
  /// （`widgets/media_query.dart:553-559`）⇒ 它是"**别把横向拖的控件放这儿**"，
  /// 不是"整页内容往里缩"。真需要它的控件（Slider、滑动删除）自己读
  /// [sideGestureOf]，别拿全局平移去替它。
  /// 上下反过来：那两条带子是**遮挡**（pill／导航条／状态栏压在控件上），所以照抬。
  ///
  /// ⚠ 键盘那一格是 10-04 扫描席报的（我回读 `rendering/window.dart` 与
  /// `platform_dispatcher/binding` 后确认成立）：`padding` 是**已经减掉键盘**的那一份
  /// （键盘顶起来时 `padding.bottom` 会掉到 0），而 `systemGestureInsets` **不减** ——
  /// 直接拿它 max，等于在已经让开键盘的窗口里再让一次导航条高度：三键导航的手机上
  /// 输入框会浮在键盘上方 24–48dp，而且读数会写出假的 `lifted=1`。
  /// 所以手势这一路先减 `viewInsets`、钳到 0 再参与 max。
  static EdgeInsets of(MediaQueryData mq) => bandFor(
        padding: mq.padding,
        gesture: withoutViewInsets(mq.systemGestureInsets, mq.viewInsets),
      );

  /// 键盘／手写笔占掉的那一块不许算进"系统条带子"（见 [of]）。
  /// 单独成函数是为了能在画像表里直接喂，不必伪造整个 `MediaQueryData`。
  static EdgeInsets withoutViewInsets(EdgeInsets gesture, EdgeInsets viewInsets) =>
      EdgeInsets.fromLTRB(
        math.max(0.0, gesture.left - viewInsets.left),
        math.max(0.0, gesture.top - viewInsets.top),
        math.max(0.0, gesture.right - viewInsets.right),
        math.max(0.0, gesture.bottom - viewInsets.bottom),
      );

  /// **策略本体**（画像表直接喂它，这样"左右不参与"与"只抬上下"这两条政策本身是被测的，
  /// 而不是藏在 `of` 里靠调用点碰运气）。⚠ 喂进来的 `gesture` 必须是**已经减掉 viewInsets**
  /// 的那一份（见 [of] 与 [withoutViewInsets]）——键盘那一格是 10-04 扫描轮补的，
  /// 画像表要新增这一维时请走 `of`，别在 `bandFor` 这一层重新加回键盘。
  static EdgeInsets bandFor({
    required EdgeInsets padding,
    required EdgeInsets gesture,
  }) =>
      atLeast(base: padding, gesture: verticalOnly(gesture));

  /// 把一份 insets 压成"只剩上下"。左右那两条由 [sideGestureOf] 单独供给。
  static EdgeInsets verticalOnly(EdgeInsets g) =>
      EdgeInsets.fromLTRB(0, g.top, 0, g.bottom);

  /// 侧边手势区（**只给需要横向拖的控件读**，不参与全局避让）。
  static EdgeInsets sideGestureOf(MediaQueryData mq) => EdgeInsets.fromLTRB(
        mq.systemGestureInsets.left,
        0,
        mq.systemGestureInsets.right,
        0,
      );

  /// 上面那条算式的本体，拆出来是为了能在单测里直接喂四档画像，
  /// 不必伪造 `MediaQueryData`（它的构造在 3.47 里要一个真 `FlutterView`）。
  static EdgeInsets atLeast({
    required EdgeInsets base,
    EdgeInsets gesture = EdgeInsets.zero,
  }) =>
      EdgeInsets.fromLTRB(
        math.max(base.left, gesture.left),
        math.max(base.top, gesture.top),
        math.max(base.right, gesture.right),
        math.max(base.bottom, gesture.bottom),
      );

  /// 这一条边是否被"抬"过（=系统吃触摸却没预留的那一类设备）。读数用。
  ///
  /// ⚠ 左右那两条 clause 在**今天的 `of()` 下永远不会为真**（`verticalOnly` 把侧边压成 0，
  /// 所以 `band.left == raw.left`）——10-04 第三轮扫描第二条点出的就是这一格。
  /// 式子本身留着（它是"任一边被抬"这句通用判据，将来若有别的调用方抬侧边它照样管用），
  /// 但**装机后认设备不能再靠它**：横屏平板那种"系统吃 29.7dp 侧滑、padding 却不报"的机型，
  /// 与桌面那种"什么都没有"的机型，`lifted` 两个都是 0。
  /// 所以读数另外带 `sideLeft/sideRight` 两格（见 [AppBandReadout.side]），
  /// 这两种设备从日志上分得开才是 #160 那条通道该有的样子。
  static bool lifted(EdgeInsets raw, EdgeInsets band) =>
      band.top > raw.top ||
      band.bottom > raw.bottom ||
      band.left > raw.left ||
      band.right > raw.right;
}

/// 一次真机读数的形状（写进日志，装机后用它判"这台机到底报了什么"）。
@immutable
class AppBandReadout {
  const AppBandReadout(
      {required this.raw, required this.band, required this.side});

  /// 系统原样给的 `padding`。
  final EdgeInsets raw;

  /// 本文件算出来的、交给全 App 的那一份。
  final EdgeInsets band;

  /// 系统报的**侧边手势区**（左右两条，本层不拿它抬内容，只把它落到读数里）。
  ///
  /// 为什么要单独带这一份（10-04 第三轮扫描第二条）：`verticalOnly` 之后
  /// `band.left/right` 恒等于 `raw.left/right` ⇒ 只报 band 的这行字
  /// **分不出**"横屏平板：系统吃掉两侧各 29.7dp 的返回滑动、padding 却不报"与
  /// "桌面窗口：什么都没有"这两档，而这两档正是装机后要区分的东西
  ///（`sideGestureOf` 至今在 `lib/` 里零调用点：侧边避让这件事还没有任何控件消费它，
  /// 这条欠账登记在 `docs/FLUTTER_LOCK.md` 的队列里，不在本包做）。
  final EdgeInsets side;

  bool get lifted => AppSystemBand.lifted(raw, band);

  /// 一行、可 grep、字段顺序固定（真机日志的读法与 `BrowserAction` 同一套）。
  String toLine() =>
      'AppWindowChrome top=${_n(band.top)} bottom=${_n(band.bottom)} '
      'left=${_n(band.left)} right=${_n(band.right)} '
      'rawBottom=${_n(raw.bottom)} lifted=${lifted ? 1 : 0} '
      'sideLeft=${_n(side.left)} sideRight=${_n(side.right)}';

  static String _n(double v) => v.toStringAsFixed(1);

  @override
  bool operator ==(Object other) =>
      // **含 raw**（10-04 第二轮扫描第一条，我核后确认成立；方向与第一轮那条相反）：
      // 这一行印的是 `rawBottom`/`lifted`，两个都由 raw 参与算出来 ⇒ 只比 band 的话，
      // "系统从报 48 改成报 0（沉浸隐藏导航条）而带子由手势区兜住没变"这一类过渡
      // **永远不会重报**，屏幕上留着的旧行就还在说 `rawBottom=48.0 lifted=0`
      // ⇒ #160 唯一通道从此分不出"这台机什么都不报"与"这台机报了 48"，
      // 而那正是这一层要区分的那两种设备。
      // 第一轮担心的是"含 raw＝每帧刷缓冲"——那个问题现在归**合并窗**管
      // （静默 400ms 并成一条，见 `_quiet`/`_maxWait`），不再靠把 raw 从相等判断里摘掉来防刷屏。
      // 一次开/关导航条＝一条，一次 IME 动画＝一条，这才是"每态一条"的正确读法。
      other is AppBandReadout &&
          other.raw == raw &&
          other.band == band &&
          // `side` 也要进相等判断（第三轮扫描第二条的同一格）：横竖屏切换时
          // `band` 与 `raw` 的上下两条边可能一个字都没变，变的只有侧边手势区
          // ⇒ 不含 side 就**不重报**，日志里留下的是转屏前那一档的侧边读数。
          other.side == side;

  @override
  int get hashCode => Object.hash(raw, band, side);
}

/// 聊天壁纸层：把"放大到多少倍"变成**看得懂的背景**（#160 第二刀）。
///
/// ## 现象与真因（用户 2026-10-03 拍的那张平板照片）
/// 聊天页背景以前是 `Positioned.fill(Image.file(fit: BoxFit.cover))` +
/// 一层 `alpha 0.72` 遮罩（`chat_screen.dart` 的 `_withBackground`）。
/// 手机截图当壁纸时，图在手机上按**原生分辨率**画 ⇒ 遮罩下几乎看不出字；
/// 同一张图到平板上被铺满 2400px 宽的屏，等于把截图里的中文标签**放大两倍多**摆在正文后面，
/// 固定的 0.72 压不住 ⇒ 用户读作"背景残影"。#127 当时定性成"用户自设壁纸、非缺陷"，
/// 那句只对一半：**图是他设的，认不出是他设的没错；放大两倍还读得清是渲染的问题**。
///
/// ## 判据只能来自几何，不能来自设备
/// 这里没有任何 `if (平板)`：唯一输入是**窗口尺寸、原图像素尺寸、devicePixelRatio**，
/// 输出是"该糊多少 / 该多暗"。倍率 1（图按原生分辨率画）时两个量都落在**与改动前逐字相同**
/// 的档位（模糊 0、遮罩 0.72），所以手机侧不需要"应该没变吧"这种信念 —— 见
/// `test/build182_window_chrome_test.dart` 里 `scale == 1 ⇒ 与旧常量全等` 那一格。
///
/// ## 倍率为什么必须按**物理像素**算
/// `BoxFit.cover` 是在逻辑像素里排布的，但"糊不糊"发生在面板上：一张 1080×2400 的手机截图
/// 摆进 914×1292dp 的平板窗口，逻辑上是被**缩小**的（914/1080<1），看着却比手机上大一圈
/// —— 因为平板的 dpr 是 2.625，物理上是 2400/1080=**2.22 倍**。拿逻辑尺寸算会得出
/// "不用糊"的结论，而那正是用户拍到的那一屏。所以 [AppWallpaper.coverScale] 吃 dpr。
class AppWallpaper extends StatefulWidget {
  const AppWallpaper({
    super.key,
    required this.image,
    required this.child,
    this.maskColor,
  });

  /// 壁纸图源。**不限宽解码**与改动前一致（旧代码那一句也没给 `cacheWidth`）；
  /// 要收这条成本是另一件事，不在本刀里顺手改，避免"修观感"顺带把内存画像挪了。
  final ImageProvider image;

  /// 压在壁纸上面的那条内容（通常是 `AppContentColumn`）。
  final Widget child;

  /// 遮罩底色：调用方给 `colorScheme.surface`，本层只负责**它的浓度**。
  final Color? maskColor;

  /// 倍率 → 遮罩不透明度。起点 0.72 就是改动前那个写死的数。
  ///
  /// 为什么糊了还要再暗：模糊解决"认得出是字"，遮罩解决"与正文抢对比度"。
  /// 每多放大 1 倍加 0.04，封顶 0.86 —— 再暗就等同纯色背景，不如让用户直接关掉壁纸。
  static double maskAlphaFor(double scale) =>
      (0.72 + (scale - 1.0) * 0.04).clamp(0.72, 0.86);

  /// 倍率 → 高斯模糊半径（**逻辑像素**，`ImageFilter.blur` 的单位）。
  ///
  /// 定档口径是**笔画宽度**：截图里的中文笔画在原图上约 1.5–2 个像素，被放大 `scale` 倍
  /// （物理倍率，见 [coverScale]）之后仍是"两三个像素"这一量级的一根线；要让"字"退化成
  /// "色块"，σ 不光要盖住这根线，还要盖住**线与线之间的空隙**（字框 16px 量级），
  /// 于是取 `4·(scale-1)`。上下限：
  ///  · 0 ⇒ 倍率 ≤1 时**完全不糊**（手机壁纸就是这一档，与改动前逐字相同；
  ///    系数从 2 抬到 4 不动这一条，因为锚点在 scale=1）；
  ///  · 12 ⇒ 再大的倍率也不继续糊（4 倍与 12 倍看着都是"氛围色"，但更往上会把整张图糊成
  ///    灰汤，用户会以为壁纸丢了）。
  ///
  /// **这个 4 是看图挑出来的，不是推出来的**：10-04 07:3x 用 `test/zz_182_wallpaper_shot_test.dart`
  /// （一次性探针）在同一张"细笔画合成手机截图"、同一 914x1292 视口上渲了 σ=0/2.31/3.47/4.62
  /// 四档：2.31 那档斜笔化掉但**字框仍是一颗颗**（还是用户抱怨的那个"残影"），
  /// 3.47 勉强，4.62 起整行退化成纹理 ⇒ 取 4。探针跑完即删，四张图留在 `<本机路径>`。
  static double blurSigmaFor(double scale) =>
      ((scale - 1.0) * 4.0).clamp(0.0, 12.0);

  /// `BoxFit.cover` 的真实倍率：**按物理像素算**，取较大那条边（这正是"填满窗口"的定义）。
  ///
  /// [screen] 是逻辑尺寸、[image] 是位图的像素尺寸，所以必须先把逻辑尺寸乘 dpr 换算到
  /// 面板上，否则"手机截图摆进平板"会被算成缩小（见类注释那一节）。
  static double coverScale({
    required Size screen,
    required Size image,
    double devicePixelRatio = 1,
  }) {
    if (image.width <= 0 || image.height <= 0) return 1;
    if (screen.width <= 0 || screen.height <= 0) return 1;
    final dpr = devicePixelRatio.isFinite && devicePixelRatio > 0
        ? devicePixelRatio
        : 1.0;
    return math.max(
      screen.width * dpr / image.width,
      screen.height * dpr / image.height,
    );
  }

  @override
  State<AppWallpaper> createState() => _AppWallpaperState();
}

class _AppWallpaperState extends State<AppWallpaper> {
  ui.Image? _image;
  ImageStreamListener? _listener;
  ImageStream? _stream;
  ImageProvider? _resolvedFor;

  /// 上一次**失败**时试的是哪一把键，以及这把键已经失败过几次。
  /// 同一条键失败过就不再自动重试（见 onError 那一段），换壁纸与依赖变化各给一次机会，
  /// 但**总量封顶**：`_maxAttemptsPerKey` 之后连依赖变化也不再看它——
  /// 真删掉的文件不会因为用户多点两次主题就多读两次盘。
  ImageProvider? _failedFor;
  int _failedAttempts = 0;
  static const int _maxAttemptsPerKey = 3;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 依赖变化＝**人为的**重看一眼（换主题、改字号、平板转屏换档），不是每帧都来：
    // 实测聊天页流式渲染期间这个回调一次都不跑（它只在 InheritedWidget 真变时才来，
    // `MediaQuery` 的 padding-only 变化走的是选择性依赖，不点这一家的名）。
    // "瞬时失败不许把壁纸从此弄没"这条要求就落在这里，而不是落在 `didUpdateWidget` 上。
    final failed = _failedFor;
    // 这里**只**放开"再看一眼"，额度统一在 [_resolveIfChanged] 那一道闸上判
    //（尺寸不许有第二个所有者，重试额度也一样：两处各判一次就有一处是死的）。
    if (failed != null && failed == widget.image) _resolvedFor = null;
    _resolveIfChanged();
  }

  @override
  void didUpdateWidget(AppWallpaper oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 用户在设置页换壁纸 ⇒ 同一个元素、新的 `FileImage`（`FileImage ==` 比的是路径）。
    // 少了这一行会**一直显示上一张**：`didChangeDependencies` 只在依赖变化时才来。
    _resolveIfChanged();
  }

  void _resolveIfChanged() {
    if (_resolvedFor == widget.image) return;
    // 同一条键已经失败到顶 ⇒ 连"人为重看一眼"那道路径也不再去读盘。
    if (_failedFor == widget.image && _failedAttempts >= _maxAttemptsPerKey) return;
    _resolve();
  }

  void _resolve() {
    _release();
    if (_failedFor != widget.image) {
      // 换了一把键＝用户换了壁纸 ⇒ 失败计数与额度都重新起（新文件该有全新的三次机会）。
      _failedFor = null;
      _failedAttempts = 0;
    }
    _resolvedFor = widget.image;
    final stream = widget.image.resolve(createLocalImageConfiguration(context));
    final listener = ImageStreamListener((info, _) {
      // 这一份 `ui.Image` 是 `ImageStreamCompleter` 派给**本监听者**的句柄
      // （`image_stream.dart:563/764/1070` 每次派发都 `.clone()` 一份），
      // 所以"我们不拥有它"那句旧注释是错的；正确的口径是：
      // **我们拥有这个句柄，而把它交给 `RawImage` 之后，句柄的 dispose 归 RenderImage**
      // （`rendering/image.dart:447` `dispose(){_image?.dispose();}`）。
      // 由此得出一条必须守住的结构性约束：**同一个句柄不许交给第二个 RenderObject**
      // ——见 build 里 `ImageFiltered(enabled:)` 那一格。
      if (!mounted) return;
      // 读出来了就把"这把键失败过"与额度一起擦掉：留着的话以后真出点事，
      // 依赖变化那道路径会因为旧记录而**不再**重试。
      setState(() {
        _failedFor = null;
        _failedAttempts = 0;
        _image = info.image;
      });
    }, onError: (exception, stackTrace) {
      // 与改动前的 `errorBuilder: (…) => SizedBox.shrink()` 同一条路：读不出来就只留遮罩。
      //
      // 10-04 扫描席报的那一格成立：旧注释说"`_image` 本来就是 null"只在**第一次**解析成立。
      // 换壁纸时 `_resolve()` 先 `_release()` 摘掉旧监听，如果新文件读不出来（截断的 jpg、
      // 改名的 heic），旧句柄会一直挂在 `_image` 上 ⇒ 屏幕上永远是上一张，
      // 用户看到"换了但没换"。这里清掉它，旧句柄由正在卸载的 RenderImage dispose。
      //
      // 第二轮扫描立的那条要求还站着：**一次瞬时失败（文件正被别处写、系统忙）不许把
      // 壁纸从此弄没**——换主题、改字号之后得再看一眼。它当时用的手段（把 `_resolvedFor`
      // 清成 null）把这条要求实现成了"每帧重读一次"，代价见下面第三轮的读数；
      // 手段换了，要求没换，重试点从这一版起落在 [_resolveIfChanged] 的两个入口上。
      if (!mounted) return;
      // **记住"失败的是哪一把键"，而不是把 `_resolvedFor` 抹成 null**
      //（10-04 第三轮扫描第一条，成立，也是本包最重的一处）。
      // 上一版清 null 的动机是对的——"别把一次瞬时失败变成壁纸从此消失"——
      // 但它顺手把重试点改成了**每一次 build**：聊天页每来一个 token 就 setState
      //（`chat_screen_message.dart:834`，那头的注释自己写的间隔约 66ms），
      // 每一次都走 `didUpdateWidget` → 看见 `_resolvedFor == null` → 再 resolve 一次，
      // 而 `evict()` 恰好已经把缓存里那把键赶走了 ⇒ 整张多 MB 的图**重新读盘、重新解码、
      // 再失败一次**，一秒十几次 IO 外加一次壁纸子树重建，全落在"壁纸文件是坏的"这条路上。
      // 这里注释原先写"重试点在依赖或 widget 变化那一刻，不是每次 build"——那句前提是错的：
      // `AppWallpaper` 是在 build 里现造的，`didUpdateWidget` 每帧都跑。
      // 现在的口径：同一条键失败过就**不再自动重试**；换壁纸（键变了）与依赖变化
      //（换主题、改字号，走 `didChangeDependencies`）各给一次重看的机会。
      _failedFor = widget.image;
      _failedAttempts += 1;
      // 只记键**还不够**那一格仍然成立：`ImageCache.putIfAbsent` 认的是**键**，
      // 失败的 completer 会一直挂在键上，不 `evict()` 的话下次换回这张图拿到的是
      // 同一个"已经错过的"对象，`loadImage` 根本不会再跑。
      unawaited(widget.image.evict());
      setState(() => _image = null);
    });
    stream.addListener(listener);
    _stream = stream;
    _listener = listener;
  }

  void _release() {
    final listener = _listener;
    if (listener != null) _stream?.removeListener(listener);
    _listener = null;
    _stream = null;
  }

  @override
  void dispose() {
    _release();
    // 句柄本身不在这儿 dispose：它已经交给 `RenderImage`，卸载时由那边减一次引用
    // （`dart:ui` 的 `Image.clone` 文档：所有句柄都释放后底图才真正回收）。
    // 这里只断引用，免得这个 State 在被卸载的树上再被读到。
    _image = null;
    super.dispose();
  }

  /// 模糊滤镜的**唯一实例**（按 sigma 记忆）。
  ///
  /// 为什么必须记忆：`ui.ImageFilter` 没有值相等（`==` 是标识），
  /// 而 `_ImageFilterRenderObject.imageFilter=` 是 `if (value != _imageFilter) markNeedsCompositedLayerUpdate()`
  /// （`widgets/image_filter.dart:90-95`）⇒ 每次 build 现造一个，就等于**每次 build 都把
  /// 整窗的离屏模糊层重建一次**。聊天页流式渲染每来一个 token 就 build 一次。
  ui.ImageFilter? _filter;
  double _filterSigma = -1;

  ui.ImageFilter _filterFor(double sigma) {
    final cached = _filter;
    if (cached != null && _filterSigma == sigma) return cached;
    _filterSigma = sigma;
    return _filter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);
  }

  @override
  Widget build(BuildContext context) {
    final base = widget.maskColor ?? Theme.of(context).colorScheme.surface;
    final image = _image;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final size = constraints.biggest;
        final scale = image == null
            ? 1.0
            : AppWallpaper.coverScale(
                screen: size,
                image: Size(image.width.toDouble(), image.height.toDouble()),
                devicePixelRatio: dpr,
              );
        final sigma = AppWallpaper.blurSigmaFor(scale);
        return Stack(
          children: [
            Positioned.fill(
              child: RepaintBoundary(
                // ⚠ 结构约束（10-04 扫描席报的 P1，我回读 SDK 后确认成立）：
                // **不许在 `ImageFiltered(RawImage)` 与 `RawImage` 之间换树形**。
                // 换形 ⇒ 旧 element 卸载 ⇒ `RenderImage.dispose()` 把它那份句柄 dispose 掉，
                // 而 State 里的 `_image` 还是**同一个对象**，新挂上的 RenderImage 拿到的就是
                // 一个已释放的句柄 ⇒ 每帧"用已释放的图"（壁纸没了／红屏）。
                // 触发条件很平常：倍率跨过 1.0 就换形 —— 同一张壁纸，竖屏 1.78、
                // 横屏／分屏 1.00，转一次方向就踩到。
                // `ImageFiltered.enabled` 是 Flutter 给这一格准备的答案
                // （`widgets/image_filter.dart:46-51`："Prefer setting enabled to false
                //  instead of creating a no-op filter"）：树形恒定，sigma=0 那一档
                // 走 `alwaysNeedsCompositedLayering=false`，不建离屏层、不糊，
                // 所以手机侧仍然与改动前逐字相同。
                child: image == null
                    // 还没解码出来（首帧）或解码失败：只留遮罩，不闪图、也不闪"图没了"。
                    ? const SizedBox.shrink()
                    : ImageFiltered(
                        enabled: sigma > 0,
                        // `TileMode.clamp`（默认）：糊到边缘时复制边像素，不会啃出一圈透明。
                        imageFilter: _filterFor(sigma),
                        child: RawImage(
                          image: image,
                          fit: BoxFit.cover,
                          width: size.width,
                          height: size.height,
                        ),
                      ),
              ),
            ),
            Positioned.fill(
              child: ColoredBox(
                color: base.withValues(alpha: AppWallpaper.maskAlphaFor(scale)),
              ),
            ),
            Positioned.fill(child: widget.child),
          ],
        );
      },
    );
  }
}
