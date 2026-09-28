import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../services/logger_service.dart';
// build166：这一处只要 `AppWait`（非动画的等待时长），而 D1 的口径是"字面时长只许住
// tokens.dart"—— 键盘"坐稳"那条判据的 200ms 也不例外，别在这里写死。
import '../ui/tokens.dart';

/// 键盘是否真的占住底部空间 —— **全项目唯一判据**（教训 #62：同一语义只允许一个实现）。
///
/// ## 为什么需要这个文件（build140 反馈③，A 级自我回归）
///
/// 这一支判据在三个版本里塌了两次，塌的方向**正好相反**：
///
/// | 写法 | 塌在哪 | 症状 |
/// |---|---|---|
/// | `viewInsets.bottom > 0`（build138 及以前） | 部分 ROM 走 edge-to-edge 时把**系统导航条**也算进 `viewInsets` ⇒ **恒真** | 键盘没弹也撑高、按返回收不回（build139 反馈①） |
/// | `viewInsets.bottom > padding.bottom`（build139 第二轮） | 另一类机器键盘弹起时把 `padding.bottom` **一起抬到键盘高** ⇒ 两个值相等 ⇒ **恒假** | 聚焦了永远一行、"输入框又无法展开"（build140 反馈③） |
///
/// **共同错误是同一个**：拿**同一帧**里同时读到的两个数互相减。
/// 这两个数在不同 ROM 上的语义并不固定 —— 可能一个是"导航条"、另一个也是"导航条"，
/// 也可能两个都变成"键盘"。同帧比较在原理上就不可靠，只是恰好在一类机器上能用。
///
/// ## 这里换的口径：跨帧基线 + 绝对增量
///
/// 记一个**静止基线** = 本布局上下文中观测到的**最小** `viewInsets.bottom`
/// （几乎一定是"没有键盘"时的那一帧，可能是 0，也可能是导航条那一截）。
/// 判据 = `当前 viewInsets.bottom - 基线 > [kKeyboardMinRise]`。
///
/// 三种塌法逐一验过：
/// - 经典（无键盘 0 / 有键盘 300）：基线 0 ⇒ 增量大 ⇒ **真**；收起 ⇒ 0 ⇒ **假**。✅
/// - `> 0` 恒真那类（无键盘 48 / 有键盘 300）：基线 48 ⇒ 收起增量 0 ⇒ **假**（治 build139 反馈①）；
///   弹起增量 252 ⇒ **真**。✅
/// - `> padding` 恒假那类（键盘弹起时 padding 跟着涨）：本判据**根本不读 padding**，
///   只看 viewInsets 相对基线的涨幅 ⇒ 收起 **假** / 弹起 **真**。✅
///
/// 基线只做**只降不升**的 min-tracking ⇒ 自愈：万一首帧就带着键盘（从后台恢复到正在输入的会话），
/// 那一轮判不出来，但键盘一收就会把基线拉到真·静止值，下一轮即正常。
/// 反过来基线被"拉得过低"也不会错判 —— 基线越小 ⇒ 越接近经典口径，是安全方向。
class KeyboardInsetJudge {
  /// 认为"键盘占位"所需的最小涨幅（逻辑像素）。
  ///
  /// 取值理由：导航条/手势条那一截在实测机型上 ≤ 48dp，而任何真实键盘（含横屏、
  /// 平板悬浮键盘）都 ≥ 120dp。96 落在两者中间，两侧都有余量 ——
  /// 关键是**它必须是绝对量**，不能再写成与同帧另一个 inset 比大小。
  static const double kKeyboardMinRise = 96.0;

  double _resting = double.nan;

  /// 本布局上下文里**窗口自身高度**的历次最高值（= 没有键盘占位时的高度）。
  /// build146 新增，理由见 [observe] 里那段「为什么是 max-tracking 而不是再猜基线」。
  double _tallest = double.nan;

  /// 当前静止基线（未观测过为 NaN）。测试与诊断用。
  double get restingBaseline => _resting;

  /// 喂一帧 `viewInsets.bottom`，返回"键盘是否占位"。
  ///
  /// [layoutKey] 标识布局上下文（方向 / 宽度档位）。**换了上下文必须重置基线**：
  /// 竖屏的导航条高度与横屏不是一回事，拿竖屏基线判横屏会整段失真。
  ///
  /// ## build141 反馈③：为什么这一版**没有**再动判据
  ///
  /// 用户 2026-09-22 报「输入框现在是直接展开了」＝这条判据疑似**第三次**塌（这次偏真）。
  /// 本轮认真推演过三种改法，全部被自己否掉，因为每一种都会引入新的塌法：
  /// 1. **新低值要连续两帧同值才认**（防 Android 首帧 `viewInsets` 仍为全 0 的毛刺）
  ///    ⇒ 若用户在静止值确认之前就点开键盘，配对会锁在**键盘高度**上
  ///    ⇒ 首次展开失效（等于把 build140 反馈③ 的恒假换个地方复现）。
  /// 2. **稳定 1.5s 即视为静止值**（不要求两帧）⇒ 键盘**一直开着**时同样稳定，
  ///    基线被抬到键盘高 ⇒ 打字打到一半框收回去。
  /// 3. 稳定值只允许把基线**往下**收敛 ⇒ 若这台机器从未出现过低于阈值的静止值，
  ///    基线永远确认不了，还是回到恒真。
  ///
  /// 三条的病根是同一个：**判据的输入本身在说谎，而我们在猜它怎么说谎**。
  /// build140 的教训是「别拿同一帧两个数互相减」；换成「拿一个语义不固定的数比常量」
  /// 一样不可靠 —— 除非先知道这台机器**无键盘时到底报多少**。
  /// ⇒ 本轮**只加可观测性**（[KeyboardSample] + [keyboardOccludesBottom] 的节流日志），
  ///   下次真机日志导出里就有那一行数字，一次定位；在那之前再改判据，
  ///   就是拿用户已经报过三次的东西赌第四把。
  bool observe(double viewInsetsBottom,
      {required String layoutKey,
      double? surfaceHeight,
      bool keyboardCertainlyClosed = false}) {
    if (_layoutKey != layoutKey) {
      _layoutKey = layoutKey;
      _resting = double.nan;
      _tallest = double.nan;
      _refFromClosed = false;
    }
    if (_resting.isNaN || viewInsetsBottom < _resting) {
      _resting = viewInsetsBottom;
    }
    // build146（输入框伸缩：判据加一条**绝对参照**）：本机 `adjustResize` 下
    // `viewInsets.bottom` 全程 0 ⇒ 上面那一支永远判假 ⇒ 点输入框根本不撑高。
    // 新参照不读 inset，读「窗口自己的高度相对无键盘参照掉了多少」：
    //   · 窗口被 IME 压缩 ⇒ 掉的就是键盘高度（Android 在 adjustResize 下缩的是窗口，
    //     这正是 viewInsets 报 0 的原因，也正是这条能量到的东西）；
    //   · 布局上下文（[layoutKey]）一切换就重来，绝不跨方向/跨宽度复用。
    // 第 10 轮审查把这条判据的**上一版注释**推翻了：那里写着
    // 「分屏/折叠展开也不受误伤 —— 基线取本窗口最高过的高度，不会凭空多出 50% 的
    // 假键盘」。那句话是**错的**：手机**上下**分屏时方向不变、宽度不变
    // ⇒ `layoutKey` 不变 ⇒ 纯 max 跟踪会把全屏时的高度永久留在参照里
    // ⇒ `shrink` 恒真 ⇒ 输入框停在撑高档、收键盘也不缩。所以参照的更新规则改成下面
    // 这一套（焦点信号是我们自己产生的，不依赖任何厂商对 inset 的报道方式）：
    //  · 「键盘确定关着」的帧 ⇒ **直接采纳当前高度**（不是取 max）。
    //    这一支是整条判据里唯一能区分「窗口被键盘压掉」与「窗口自己变小了」的信号。
    //  · 其余帧 ⇒ 只允许参照**往上**走（max 跟踪）。键盘开着时窗口只会变矮，
    //    拿它抬参照会把键盘高度本身吃进基线里（那三条失败改法的病根）。
    //  · 例外：`viewInsets` 自己就报出键盘高的那些机器上，「没焦点但 inset 很大」
    //    是互相矛盾的帧（多半是别的输入框接管了键盘）⇒ 不采纳，等下一帧。
    // 剩余的失手窗口（**一次性**，与旧判据"永久判假"不是一个量级）：
    //  ① 本会话第一次观测时键盘就已经开着 ⇒ 参照定在带键盘的高度，这一轮判不出来，
    //     键盘一收（出现"没焦点"的帧）就纠正；
    //  ② 键盘开着的时候拖动窗口改大小 ⇒ 参照偏高，同样到下一次"没焦点"的帧纠正。
    if (surfaceHeight != null) {
      if (keyboardCertainlyClosed && viewInsetsBottom <= kKeyboardMinRise) {
        _tallest = surfaceHeight;
        _refFromClosed = true;
      } else if (_tallest.isNaN || surfaceHeight > _tallest) {
        _tallest = surfaceHeight;
        _refFromClosed = false;
      }
    }
    final shrink = surfaceHeight == null || _tallest.isNaN
        ? 0.0
        : _tallest - surfaceHeight;
    final verdict = viewInsetsBottom - _resting > kKeyboardMinRise ||
        shrink > kKeyboardMinRise;
    // 诊断快照（含未确认基线的那一帧）：调用方只在签名变化时写日志。
    _last = KeyboardSample(
      viewInsetsBottom: viewInsetsBottom,
      restingBaseline: _resting,
      occludes: verdict,
      layoutKey: layoutKey,
      surfaceHeight: surfaceHeight,
      tallestSurface: _tallest,
      refFromClosedFrame: _refFromClosed,
    );
    return verdict;
  }

  String? _layoutKey;

  /// 参照高度最近一次是「键盘确定关着的那一帧」给的，还是「更高的一帧」抬上去的。
  /// 只服务日志：真机上如果 `shrink` 恒真，这一位能直接区分
  /// 「参照被分屏污染了」（`false`）与「焦点信号没送到」（`true`）。
  bool _refFromClosed = false;

  KeyboardSample? _last;

  /// 最近一次观测的快照（未观测过为 null）。诊断与单测用。
  KeyboardSample? get lastSample => _last;

  /// 仅供测试：清成"未观测"态。
  void resetForTest() {
    _resting = double.nan;
    _tallest = double.nan;
    _refFromClosed = false;
    _layoutKey = null;
    _last = null;
  }
}

/// 一帧键盘占位判据的**完整现场**（build141 反馈③：这条判据必须可观测）。
class KeyboardSample {
  /// 这一帧读到的 `MediaQuery.viewInsets.bottom`。
  final double viewInsetsBottom;

  /// 当前静止基线（未确认时为 NaN —— 本判据里它一经 `observe` 就会被赋值，
  /// 保留 NaN 分支是为了将来把「确认」语义加回来时不必改签名）。
  final double restingBaseline;

  /// 本帧判定结果（true = 键盘占住底部，输入区该撑高）。
  final bool occludes;

  /// 布局上下文标识（方向 + 宽度档位）。
  final String layoutKey;

  /// 这一帧**窗口自身**的高度（逻辑像素）。build146：`adjustResize` 下
  /// `viewInsets.bottom` 恒 0，能看出键盘的唯一绝对量就是它被压掉了多少。
  final double? surfaceHeight;

  /// 本布局上下文里的**无键盘参照高度**（未观测为 NaN）。
  /// build146 第 10 轮：不再是"最高见过的一次"——纯 max 跟踪会被分屏污染，
  /// 见 [refFromClosedFrame] 与 `observe` 的更新规则注释。
  final double tallestSurface;

  /// 参照高度最近一次是不是「键盘确定关着（本帧输入框没焦点）」的那一帧给的。
  /// 只有日志意义：`shrink` 恒真时用它区分「参照被窗口变小污染」与「焦点信号没到」。
  final bool refFromClosedFrame;

  const KeyboardSample({
    required this.viewInsetsBottom,
    required this.restingBaseline,
    required this.occludes,
    required this.layoutKey,
    this.surfaceHeight,
    this.tallestSurface = double.nan,
    this.refFromClosedFrame = false,
  });

  /// 窗口相对无键盘参照被压掉的量（逻辑像素）。键盘高度就落在这个数上。
  double get shrink =>
      (surfaceHeight == null || tallestSurface.isNaN)
          ? 0.0
          : tallestSurface - surfaceHeight!;

  /// 日志节流签名。
  ///
  /// 只含「上下文 + 两条基线 + 判定结果」，**不含原始的 `viewInsets.bottom`
  /// 与窗口高度** —— 键盘动画逐帧连续变化，带上原值会变成每次开关刷几十条；
  /// 而要看的数（那台机器静止时到底报多少、窗口到底被压掉多少）恰好落在
  /// 「基线刚被确认」与「判定翻转」这两个时刻上，一条都不会漏。
  /// 末尾的 `g<代数>`：日志被清空之后签名必然变，
  /// 于是「清空 → 复现 → 导出」这条路一定拿得到数字（build142 修的核心）。
  String get signature =>
      '$layoutKey|${restingBaseline.isNaN ? -1 : restingBaseline.round()}'
      '|${tallestSurface.isNaN ? -1 : tallestSurface.round()}'
      '|${refFromClosedFrame ? 'c' : 'm'}'
      '|$occludes|g${LoggerService.instance.clearGeneration}';

  /// 人话一行：写进日志，导出后能直接回答两件事——
  /// 「这台机器无键盘时 inset 到底报多少」和「窗口到底被压掉了多少」。
  String describe() => 'viewInsets.bottom=${viewInsetsBottom.toStringAsFixed(1)}'
      ' 基线=${restingBaseline.isNaN ? '未确认' : restingBaseline.toStringAsFixed(1)}'
      ' 窗口=${surfaceHeight == null ? '?' : surfaceHeight!.toStringAsFixed(0)}'
      '/参照=${tallestSurface.isNaN ? '?' : tallestSurface.toStringAsFixed(0)}'
      '(${refFromClosedFrame ? '无键盘帧' : '更高帧'})'
      ' 压掉=${shrink.toStringAsFixed(0)}'
      ' 判定=${occludes ? '占位' : '不占位'} 上下文=$layoutKey';
}

/// build161：**键盘盖住底部、而布局没收到**的那一截高度（逻辑像素）。
///
/// 为什么第十次不再改判据，而是新增这一个量：
/// 用户 11:49 那份 1.7.103+160 导出把两件事分开钉死了 ——
///  · `正文` 119→176→290→119：**框自己会长会缩，这一半九轮下来第一次被证实是对的**；
///  · `原生insets` 键盘弹起时 5→29→…→220，而**同一段时间里** `上限` 恒为 852
///    （852 = 932 窗高 - 0 - 顶部 chrome）⇒ 树里 `MediaQuery.viewInsets.bottom` 一直是 0。
/// `Scaffold.resizeToAvoidBottomInset` 读的正是 MediaQuery ⇒ 它**根本没抬**，
/// 涨出来的那 171 像素整个跑到键盘后面去了。用户读到的是"不伸不缩"，
/// 实际发生的是"伸了，但在屏幕看不见的地方伸"。
/// 前九轮全在布局层里换判据，而布局层从没收到过键盘，所以每一次"测出来都是好的"。
///
/// 所以这里取的是**引擎自己的数**（`View.viewInsets`，系统直接派给 FlutterView 的 IME 占位，
/// 不经过任何 MediaQuery 覆写），并且只做"补差"，不做"再算一遍高度"：
/// - [windowShrinkLogical] = 同一布局上下文里**窗口自己变矮了多少**（历次最高窗高 - 本帧窗高）。
///   老式 `adjustResize` 机器上窗口会随键盘变矮（此时键盘已经在窗口外面，
///   输入区天然贴在它上方），差值把抬起量抵成 0 ⇒ **不会双重抬起**。
///   Android 16 + `setDecorFitsSystemWindows(false)`（本机）窗口恒 932、只给 insets
///   ⇒ 差值 0 ⇒ 抬起量 = 整段键盘高。
/// - **不减导航条**：那要把键盘高与同一帧的另一个读数互相减 —— 而本文件开头那张
///   塌法表记的就是这种写法在各 ROM 之间怎么塌的（两次反向翻车都源于此）。
///   键盘是从窗口底算起、连导航条那一截一起盖住的 ⇒ 垫到键盘上沿就对了；
///   键盘**收起**时导航条仍由外层 `SafeArea` 负责（消费方按 `lift <= 0` 开关它，
///   见 `chat_input.dart` 那行 `bottom: imeLift <= 0`）。
///
/// 已知代价（写清楚，别当没有）：[windowShrinkLogical] 来自"历次最高窗高"，
/// 若某台 adjustResize 机器**冷启动第一帧就带着键盘**，那一帧的基线就是缩过的高度
/// ⇒ 多抬一次；键盘一收就把基线拉回真值，下一帧自愈。
/// 反向塌法（少抬、框还压在键盘下）不成立：基线只降不升的方向是安全的。
double imeLiftLogical({
  required double imeInsetBottomLogical,
  double windowShrinkLogical = 0,
}) {
  if (imeInsetBottomLogical <= 0) return 0;
  final shrink = windowShrinkLogical > 0 ? windowShrinkLogical : 0;
  final lift = imeInsetBottomLogical - shrink;
  return lift <= 0 ? 0 : lift;
}

/// build166：这一帧键盘**占了地方**的那个量（逻辑像素）—— [imeOpenProgress] 的分子。
///
/// 为什么不直接拿 [imeLiftLogical] 的输出当分子（这是本轮最容易自己踩进去的坑）：
/// `imeLiftLogical` 在老式 `adjustResize` 机器上**故意**返回 0 —— 窗口已经被系统缩掉
/// 一整截，输入区天然贴在键盘上方，再垫一次就是双重抬起（build161 钉着那条）。
/// 可那台机器上键盘**真的开着**，"画几行"必须知道这件事。所以这里给的是
/// 两种机型形状共用的一份分子：`max(ime, shrink)`。
///  - 本机（Android 16 edge-to-edge）：`ime > 0`、`shrink == 0` ⇒ 结果**就等于 ime**
///    （`test/build166_composer_progress_test.dart` 逐条钉着这个等式）；
///  - 老式 `adjustResize`：`ime == 0`、窗口被压掉一截 ⇒ 结果 == shrink；
///  - 少数两个信号一起报的机器：取 **max 而不是相加** —— 相加会把同一截键盘数两遍，
///    而引擎那两个数并不保证同帧更新，不同帧时就会算出一个假进度。
/// 读不到（NaN）的那一份按 0 处理，**不连着把读到的那一份也丢掉**。
double imeSpaceLogical({
  required double imeInsetBottomLogical,
  double windowShrinkLogical = 0,
}) {
  final ime = imeInsetBottomLogical.isFinite && imeInsetBottomLogical > 0
      ? imeInsetBottomLogical
      : 0.0;
  final shrink =
      windowShrinkLogical.isFinite && windowShrinkLogical > 0
          ? windowShrinkLogical
          : 0.0;
  return ime > shrink ? ime : shrink;
}

/// build166（方案①：**一条时钟**）：本轮键盘"开到哪儿了"的连续进度 0..1。
///
/// 用户 2026-09-26 13:20 装完 1.7.108+165 报「输入框展开是正常的，收缩还是有卡顿」。
/// 第十一轮取证给出的成因是**两把表**：抬起跟着引擎的 IME 动画走（OPPO 真机约 270ms、
/// 节拍不规则），行数却跟着我们自己那个 200ms `TweenAnimationBuilder` 走，而且翻档时刻
/// 方向不对称（弹起在第一帧就翻满、收起要等最后一帧才翻回）⇒ 收缩读起来是
/// "框先落回底部、停一下、再收行"。修法不是给第二把表换个转速，而是**让它退休**：
/// 抬起与"画几行"消费同一个由引擎逐帧给的量，于是
/// **不新增任何动画开关** —— 引擎一步到位（系统"移除动画"、或某些 ROM 的输入法
/// 根本不 animate）时 t 直接 0→1，自然没有中间档。
///
/// 分母是**本轮峰值**（[peakSpaceLogical]，由 `ImeLift` 逐帧 max-tracking 维护）：
///  - 峰值未建立（<=0）⇒ 返回 0。这条是刻意的："没有事实"与"开了 0%"给消费者的答案一样，
///    而**绝不返回 0.5 之类的猜值**（第十一轮第二个成因就是拿猜出来的量当输入）。
///  - 本机键盘高度在开键过程中会变（悬浮键盘、九宫格、候选栏收起）⇒ 峰值只在这一轮里有效，
///    `space` 回到 0 时整轮复位，见 [_ImeLiftState]。
///  - 已知代价（写清楚，别当没有）：展开方向上峰值就是本帧的 `space` ⇒ 第一帧起 t≡1、
///    行数直接落满档，位移由引擎的抬起继续完成。收起方向反过来（峰值已经建好）⇒
///    行数随 `lift` 一路同步落回去，那正是用户报的这一段。**这是本轮选择的方向**：
///    用户原话"展开是正常的"，要修的是收缩；如果下一份真机导出显示"展开跳太快"，
///    该改的是峰值跨轮保留（分母来自上一轮），**不是**再装一把表回去。
///  - 引擎中途报了一格更小的占位（真机上见过候选栏收起导致的 1~2px 抖动）⇒ t 会跟着
///    回一格，行数抖一格、下一帧自愈。这比"我们替引擎把曲线抹平"诚实：抹平就是第二把表。
double imeOpenProgress({
  required double imeInsetBottomLogical,
  double windowShrinkLogical = 0,
  required double peakSpaceLogical,
}) {
  final peak = peakSpaceLogical.isFinite && peakSpaceLogical > 0
      ? peakSpaceLogical
      : 0.0;
  if (peak <= 0) return 0; // 本轮还没有任何事实可依据
  final space = imeSpaceLogical(
    imeInsetBottomLogical: imeInsetBottomLogical,
    windowShrinkLogical: windowShrinkLogical,
  );
  if (space <= 0) return 0; // 一轮结束 / 键盘没开
  final t = space / peak;
  return t >= 1 ? 1 : t; // 引擎最后一帧比峰值那一帧还高一两像素是常态 ⇒ 只夹上界
}

/// [ImeLift] 一帧交出来的东西（build166）。
///
/// 为什么从"两个参数"变成一个对象：用户要修的正是"抬起与行数不同步"，那么这两个量
/// 就**必须出自同一次求值**——分开发出去，早晚会有人在一侧再算一遍。
/// 本仓的高度口径是"不许有第二个所有者"（build156），这一条是它的孪生：
/// **键盘时间线不许有第二个所有者**，而唯一的观测点就在这里。
class ImeFrame {
  const ImeFrame({
    required this.lift,
    required this.t,
    required this.keyboardUp,
    required this.peakSpace,
  });

  /// 该往上垫多少逻辑像素（[imeLiftLogical] 的输出，build161 的口径一字未动）。
  final double lift;

  /// 本轮键盘开到哪儿了（[imeOpenProgress] 的输出，0..1）。
  /// **这是"画几行"唯一的输入** —— 布尔那份不是。
  final double t;

  /// 引擎侧的"键盘到底开着没有"（`ime > 0 || shrink > 0`，与 build162/163 同一条）。
  /// build166 起**只进日志**（与树内那份判据对账），不再参与画几行：
  /// 布尔天生只能表达"开/关"，用它驱动行数就必然出现"某一帧整档翻过去"的时刻错。
  final bool keyboardUp;

  /// 本轮峰值占位量 = [t] 的分母（0 = 本轮还没建立峰值）。只有日志读。
  final double peakSpace;

  /// 键盘完全没消息时的一帧（`View.maybeOf` 拿不到 View 的兜底）。
  static const ImeFrame none =
      ImeFrame(lift: 0, t: 0, keyboardUp: false, peakSpace: 0);
}

/// [imeLiftLogical] / [imeOpenProgress] 的取值 + 重绘触发器。
///
/// 为什么必须自己挂 [WidgetsBindingObserver]：不能赌"键盘弹起时会有人重画这一带"。
/// 158 那份日志里 insets 能逐帧变化，是因为他正好在打字、文本变化顺手触发了重建；
/// 只看不写的时候并不成立。`didChangeMetrics` 是引擎在 IME 占位变化时必然要发的通知。
///
/// **build161 真机订正**（写在这里免得下一轮又被假前提带偏）：161 之前我以为
/// "树里 `MediaQuery.viewInsets` 恒 0"，而 16:45 那份 1.7.104+161 的导出里
/// `原生insets=219 树内insets=219`（同帧、逐帧相等）⇒ 那个前提**不成立**，
/// 真正的坏点是 `Scaffold` 那一层没把占位交给输入区（现在由 [ImeLift] 独家抬）。
/// 抬起量仍然读引擎这一份，为的是"唯一所有者"，不是因为树里的数不可信。
class ImeLift extends StatefulWidget {
  const ImeLift({super.key, required this.builder});

  /// 拿到"该往上垫多少、开到哪儿了、键盘到底开着没有"再画 —— 三件事**同一帧同一份**。
  /// 消费者**只准**用 [ImeFrame.lift] 决定抬起、用 [ImeFrame.t] 决定画几行；
  /// 不许再回去读 `MediaQuery.viewInsets`、不许自己拿焦点猜、更不许给自己加时长
  /// （[ImeFrame.keyboardUp] 是引擎报的事实，焦点不是；而布尔驱动不了连续过程）。
  final Widget Function(BuildContext context, ImeFrame frame) builder;

  @override
  State<ImeLift> createState() => _ImeLiftState();
}

class _ImeLiftState extends State<ImeLift> with WidgetsBindingObserver {
  /// 本布局上下文历次**最高**窗高 = 没有键盘占位时的那一个（口径同 [KeyboardInsetJudge]）。
  double _tallestWindow = 0;
  int? _widthKey;

  /// 本轮键盘占位峰值（[imeOpenProgress] 的分母）。
  ///
  /// 维护规则只有两条，且**不依赖任何计时器**（本轮的病根就是自己开了一把表）：
  ///  - 上升取 max：引擎每一帧给的 [imeSpaceLogical] 都是事实，我们不预测终值；
  ///  - `space` 回到 0 ⇒ 这一轮结束了，整轮复位。下一轮重新学一截高度 ——
  ///    同一台机器上全键盘 / 悬浮键盘 / 九宫格的高度本来就不是一回事，
  ///    拿上一轮的峰值当这一轮的分母会一路算出假进度。
  /// 只在 `build` 里读写、由 [didChangeMetrics] 驱动 ⇒ 同一帧重跑结果一致（幂等），
  /// 所以这里不需要、也不许再有第二次 setState。
  double _peakSpace = 0;

  /// 上一帧的占位量 + 它**最后一次发生变化**的时刻（build166 的"坐稳"判据用）。
  ///
  /// 要挡的是这一改自己带进来的新失效模式：键盘开着的时候换输入法布局
  /// （全键盘 ↔ 九宫格、悬浮键盘收起）会让占位量**稳定地**变矮一截，而分母还记着
  /// 本轮更高的那一档 ⇒ `t` 再也回不到 1 ⇒ 输入框**永久少一行**，直到收键重开。
  /// 165 之前不会出这个形状（那时行数是布尔量驱动的，跟高度无关），所以这条不修
  /// 就是拿用户没报过的代价换他报过的那一条。
  ///
  /// 为什么用"多久没变"而不是"连续几帧没变"：键盘坐稳之后**再也没有帧**（没有
  /// `didChangeMetrics`、也没人重画这一带），按帧数根本攒不到阈值。时间戳的写法是
  /// 下一次自然重建时（打字、页面任何一次 setState）才补上这次改锚，最坏晚一帧可见。
  /// 反向风险也写清楚：收起动画中途若真出现 ≥[AppWait.imeSettleHold] 的字节级平台，
  /// 改锚会让行数弹回高档 —— 那正好等于 166 之前的形状（抬起没归零而行数还挂着），
  /// 下一帧自愈，不是新的坏法。
  double _lastSpace = 0;
  int _lastSpaceChangedUs = 0;

  /// 本轮内"已经按坐稳改过一次锚"的记号：只改一次，不允许软收敛
  /// （谁要是加"每帧往当前值靠一点"，那就是第三把表 —— 这条记号就是拿来挡它的）。
  bool _peakSettled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final view = View.maybeOf(context);
    if (view == null) return widget.builder(context, ImeFrame.none);
    final dpr = view.devicePixelRatio == 0 ? 1.0 : view.devicePixelRatio;
    final mq = MediaQuery.of(context);
    final ime = view.viewInsets.bottom / dpr;
    final windowH = view.physicalSize.height / dpr;
    // 宽度变了就是另一个布局上下文（转屏 / 折叠屏展开 / 分屏），基线必须重来 ——
    // 拿竖屏的窗高去减横屏的窗高，会得到一个假的"窗口被缩掉了"。
    // 峰值也必须一起清掉：横屏键盘高度与竖屏不是一回事（build166）。
    final widthKey = mq.size.width.round();
    if (_widthKey != widthKey) {
      _widthKey = widthKey;
      _tallestWindow = 0;
      // 峰值与"上一帧的占位量"一起清：只清峰值的话，转屏后若键盘恰好报回**同一个**
      // 高度，下面会走"没变化"那一支 ⇒ 峰值停在 0、t 算成 0，输入框当场缩成一行。
      _peakSpace = 0;
      _lastSpace = 0;
      _peakSettled = false;
    }
    if (windowH > _tallestWindow) _tallestWindow = windowH;
    final shrink = _tallestWindow - windowH;
    final lift = imeLiftLogical(
      imeInsetBottomLogical: ime,
      windowShrinkLogical: shrink,
    );
    final space = imeSpaceLogical(
      imeInsetBottomLogical: ime,
      windowShrinkLogical: shrink,
    );
    // 本帧的时间戳：用调度器自己的时钟（widget 测试里 `pump(duration)` 推得动它，
    // 真机上它就是 vsync 的时钟）。SDK 这一版把它声明成 `Duration`（自引擎启动起算），
    // 不是 `Timestamp` —— 取值一律走 `inMicroseconds`，别写 `microsecondsSinceEpoch`。
    final nowUs =
        SchedulerBinding.instance.currentSystemFrameTimeStamp.inMicroseconds;
    if (space <= 0) {
      // 一轮结束：峰值与"坐稳"的证据一起清零，下一轮重新学一截高度。
      _peakSpace = 0;
      _lastSpace = 0;
      _peakSettled = false;
      _lastSpaceChangedUs = nowUs;
    } else if (space != _lastSpace) {
      // 占位量还在动 ⇒ 逐帧取 max，并刷新"最后一次发生变化"的时刻。
      if (space > _peakSpace) _peakSpace = space;
      _lastSpace = space;
      _lastSpaceChangedUs = nowUs;
      _peakSettled = false;
    } else if (!_peakSettled &&
        space < _peakSpace &&
        nowUs - _lastSpaceChangedUs >= AppWait.imeSettleHold.inMicroseconds) {
      // 已经 ≥[AppWait.imeSettleHold] 没有任何变化、而当前值低于本轮峰值
      // ⇒ 键盘换了布局并停在这一档，分母改锚到当前值（否则永久少一行）。
      _peakSpace = space;
      _peakSettled = true;
    }
    final t = imeOpenProgress(
      imeInsetBottomLogical: ime,
      windowShrinkLogical: shrink,
      peakSpaceLogical: _peakSpace,
    );
    // 「键盘开着」= 引擎给了占位 **或** 窗口被系统缩掉一整截（老式 adjustResize 上
    // 前者是 0、只有后者）。这两个都是引擎侧的事实；**焦点不是事实**（"焦点在而键盘
    // 没弹"与"键盘弹着而焦点在别处"本机都出现过）。
    // build166 起这个 bool 只进日志：`space > 0` 与旧的 `ime > 0 || shrink > 0` 是
    // 同一个条件（两个数都夹过非负），只是复用上面那一个分子，判据一字未动。
    return widget.builder(
      context,
      ImeFrame(
        lift: lift,
        t: t,
        keyboardUp: space > 0,
        peakSpace: _peakSpace,
      ),
    );
  }
}

/// 输入区专用实例。
///
/// 为什么是**进程级单例**而不是 widget 状态：静止基线本质是**设备/ROM 属性**，
/// 与某个页面实例无关；而 `ChatInput` 是 `StatelessWidget`，放状态要么改有状态
/// （牵动 build138/#8 那套 AnimatedSize 结构）要么每次 build 重建（基线永远拿不到）。
/// 单例 + [KeyboardInsetJudge.observe] 的 `layoutKey` 重置，已经覆盖了方向切换失真。
final KeyboardInsetJudge chatInputKeyboardJudge = KeyboardInsetJudge();

/// 上一次写日志时的签名（节流用）。
String _lastKeyboardLogSignature = '';

/// 输入框**实际渲染成的形状**（build145 第 4 轮补的采数）。
///
/// 为什么判据的输入不够：真机连续两份导出（13:16 与 14:28）里 `[Keyboard]` 只有
/// 「bottom=0.0 判定=不占位」这一种样本 —— 也就是**判据侧从来没有真的恒真过**，
/// 而用户仍报"直接展开"。这说明展开的成因压根不在判据上（可能是 `focused` 恒真 +
/// 别处撑高、文本本身长、或上方提示条被算成框的一部分）。继续换判据就是第四次猜。
/// 现在把「控件最后按几行画」也打出来：`focused`、`keyboardUp`、`minLines`、`maxLines`、
/// 文本长度 —— 三个假设一眼分开。同样只在**形状变化时**写一行，不刷屏。
/// build166 起再加两个数：`t=`（本帧进度）与 `峰值=`（它的分母），
/// 让导出能自证"抬起与行数同一把表"（节流口径不变，见函数体里那段注释）。
String _lastShape = '';
void logComposerShape({
  required bool focused,
  required bool keyboardUp,
  required bool engineKeyboardUp,
  required double progress,
  required double peakSpace,
  required int minLines,
  required int maxLines,
  required int textLength,
}) {
  // build166：`t=` 与 `峰值=` 是**同一帧**的进度和它的分母。用户报的是"收缩卡顿"，
  // 而要判断的是"行数有没有跟着抬起走" —— 导出里把 `minLines=` 与 `t=` 并排打出来，
  // 一路 `t=0.89 minLines=4` / `t=0.63 minLines=3` / … 就是同一把表的直接证据；
  // 反过来若出现 `t` 一路在掉而 `minLines` 钉在 4（163 那版收起方向的实际形状），
  // 说明还有第二把表在驱动行数。`引擎键盘=` 与 `keyboardUp=` 两列是对账用的：
  // 前者是 [ImeFrame.keyboardUp]（引擎侧），后者是树内那份旧判据（[keyboardOccludesBottom]）。
  final shape = 'focused=$focused keyboardUp=$keyboardUp 引擎键盘=$engineKeyboardUp '
      'minLines=$minLines maxLines=$maxLines 文本=$textLength 字 '
      't=${progress.toStringAsFixed(2)} 峰值=${peakSpace.toStringAsFixed(0)}';
  // 节流键里的进度**必须量化**（1/8 一档）：t 是引擎逐帧给的连续量，直接拼进键
  // 就把本函数"只在形状变化时写一行"变成"每帧一行"（一轮开键几十行），
  // 而 build141 那次的教训正是刷屏 —— 刷屏的日志等于没有日志。
  // 逐帧的那一份本来就有人记：[logComposerGeom] 的 `抬起=` 每帧都在变，
  // 它现在同一行里也带 `t=`，两个数同帧同行才是"一把表"的完整证据。
  final tStep = (progress * 8).floor().clamp(0, 8);
  // build145（第 9 轮 P2-10）：节流键必须带**清库代数**，同文件上面那个签名就是这么修的。
  // 少了它，「清空日志 → 复现 → 导出」这条路可能一行形状都没有 —— 用户已经把日志清了，
  // 我们却因为他"没改变形状"而不报，等于把采数窗口自己关掉。
  final key = '$shape|t档=$tStep|g${LoggerService.instance.clearGeneration}';
  if (key == _lastShape) return;
  _lastShape = key;
  LoggerService.instance.info('输入框形状 $shape', cat: LogCat.ui, tag: 'Keyboard');
}

/// 输入区**实际几何**（build158，第 9 次「多行不撑高」反馈专用的帧后采数）。
///
/// 为什么现有的两行日志还不够：`[Keyboard]` 那两行打的是**判据的输入**
/// （viewInsets / 焦点 / minLines-maxLines / 字数），而用户报的是**结果**——
/// "敲了回车，框不涨"。八轮下来我们一直在换判据，却没有一行日志写着
/// "这个框这一帧到底量到多高、上面允许它多高、视口给它多高"。
/// 真机上三个数一比就能定死责任方，不用再猜第九次（详见调用点的注释）。
///
/// 与 [logComposerShape] 同一条节流口径：**签名里必须带清库代数**，
/// 否则「清空日志 → 复现 → 导出」这条路会因为"几何没变"而一行都不留 ——
/// 那等于把采数窗口自己关掉（build145 第 9 轮就为这件事踩过一次）。
String _lastGeom = '';
void logComposerGeom({
  required double? fieldHeight,
  required double? fieldWidth,
  required double? viewportHeight,
  required double capHeight,
  required int chars,
  required int newlines,
  double? rawImeInsetLogical,
  double? rawWindowHeightLogical,
  double? treeInsetsLogical,
  double? liftLogical,
  double? fieldTopY,
  double? progressLogical,
  double? peakSpaceLogical,
}) {
  // `宽=` 是 build158 第二轮补的那一个数：用户 09:57 那帧给出「52 字 / 0 换行 / 高没变」
  // 而同一条日志里 10 个换行能把框顶到 290 ⇒ **长高是好的，坏的是软换行没发生**。
  // （159 那轮量出宽=408、有界，软换行其实是正常工作的：31 字=119 / 97 字=176 /
  //  10 换行=290 / 删空回 119 —— 所以"伸缩坏了"这个假设本身是错的。）
  //
  // build160 曾补两个数，因为它们才是要害：**平台派给引擎的 IME 占位**(`原生insets`)
  // 与**引擎以为的窗口高**(`窗高`)。用户 11:04 那份导出里，连 `focused=true` 的帧都是
  // `窗口=932 / 上限=852 / viewInsets=0 / keyboardUp=false` ⇒ 框照常 119→176→290→119
  // 地涨缩，**但涨到键盘后面去了**：布局从头到尾不知道键盘存在。
  // 九轮全在布局层里修，而布局层从没收到过键盘，所以每一次"测出来都是好的"。
  //
  // build161：**上面那个二选一已经有答案了** —— 原生insets 会到 220，而 上限 恒 852
  // （852 = 932 - 0 - chrome）⇒ 树里那一份是 0，即 View→MediaQuery/Scaffold 这一环没把
  // 键盘交给布局。于是本轮开始由 [ImeLift] 直接吃引擎的数，并新增三个**核对用**的量：
  //  · `树内insets` 与 `原生insets` 打在**同一帧**：不再拿两份不同时刻的日志互相比；
  //  · `抬起` ＝本帧真正垫给布局的那一截（[imeLiftLogical] 的输出）；
  //  · `顶边y` ＝输入框顶边的屏幕坐标。**这一列才是用户看到的东西**：
  //    键盘弹起时它必须变小（约一截键盘高），不变小就是还在键盘后面。
  //    前十轮量的一直是"框有多高"，而没有一行日志写着"框在哪儿"。
  // build166（用户"收缩还是有卡顿"）：`抬起` 旁边再加 `t` 与 `峰值`。
  //  这一行本来就每帧随 `抬起` 变，所以把进度放在**同一行**才是"一把表"的完整证据：
  //  `抬起=141 t=0.63 峰值=224` 一路读下来，行数为啥是 3 行一目了然；
  //  若出现 `抬起` 一路在掉而 `t` 钉在 1.00（或反过来），那就是还有第二个所有者。
  final geom = '正文=${_fmt(fieldHeight)}x${_fmt(fieldWidth)} '
      '视口=${_fmt(viewportHeight)} '
      '上限=${_fmt(capHeight < 0 ? null : capHeight)} '
      '文字=$chars 字/换行=$newlines '
      '原生insets=${_fmt(rawImeInsetLogical)} 树内insets=${_fmt(treeInsetsLogical)} '
      '抬起=${_fmt(liftLogical)} '
      't=${progressLogical == null ? '?' : progressLogical.toStringAsFixed(2)} '
      '峰值=${_fmt(peakSpaceLogical)} '
      '顶边y=${_fmt(fieldTopY)} '
      '窗高=${_fmt(rawWindowHeightLogical)}';
  final key = '$geom|g${LoggerService.instance.clearGeneration}';
  if (key == _lastGeom) return;
  _lastGeom = key;
  LoggerService.instance.info('输入区几何 $geom', cat: LogCat.ui, tag: 'Keyboard');
}

String _fmt(double? v) =>
    v == null ? '?' : (v.isInfinite ? '∞' : v.toStringAsFixed(0));

/// 纯函数壳：给定一帧的 `viewInsets.bottom` 判"键盘占位"。
///
/// 两处消费点（`compactInput` 与 `minLines` 撑高）**必须都走这里**，
/// 判据不一致就一定会有人只改对一边。
bool keyboardOccludesBottom(BuildContext context,
    {bool keyboardCertainlyClosed = false}) {
  final mq = MediaQuery.of(context);
  // 方向 + 宽度档位一起进 key：折叠屏展开/分屏改宽度时基线要重来。
  final layoutKey =
      '${mq.orientation.name}|${(mq.size.width / 100).floor()}';
  final verdict = chatInputKeyboardJudge.observe(mq.viewInsets.bottom,
      layoutKey: layoutKey,
      surfaceHeight: mq.size.height,
      keyboardCertainlyClosed: keyboardCertainlyClosed);
  // build141 反馈③：这条判据已经塌过三次，而**三次都没有一条日志** ——
  // 全程是「用户描述症状 → AI 猜 ROM 机制 → 换判据」。从此每次
  // 「基线确认 / 判定翻转」留一行现场，下一轮定位不必再猜。
  final sample = chatInputKeyboardJudge.lastSample;
  if (sample != null) {
    final signature = sample.signature;
    if (signature != _lastKeyboardLogSignature) {
      _lastKeyboardLogSignature = signature;
      LoggerService.instance.info(sample.describe(),
          cat: LogCat.ui, tag: 'Keyboard');
    }
  }
  return verdict;
}
