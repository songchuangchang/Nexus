// build169（169-B · 帧探针）：把 **build 与 raster 分开**报出来——这是合成器侧给不了的一维。
//
// 先记一条我自己犯过的错，因为它一度是这文件的立项理由：
// 27 日我在平板上测 `dumpsys SurfaceFlinger --latency`，**层名漏了结尾的 `#<id>`**，
// 只回一行 vsync 周期；我又拿同样漏了 id 的系统 Taskbar 层当对照组（它当然也空），
// 于是写下"这台平板没有任何外部帧尺子"，一路写进发版说明和记忆。
// 后来按 `…(BLAST)#68596` 整串传，**125 帧 / 中位 8.33ms / 120Hz 立刻出来了**。
// ⇒ 教训：**对照组如果和被测对象犯同一个错，它就不是独立证据。**
//
// 所以这个探针的真实价值不是"唯一出路"，而是补那一维：
//   * SurfaceFlinger 只知道"这帧什么时候上屏"——它能告诉你掉没掉帧，**分不出为什么掉**；
//   * `FrameTiming` 给 `buildDuration`（我们 widget 树重建侧）与 `rasterDuration`
//     （GPU 光栅化侧），这两半要修的人完全不同。
// 走 App 自己的日志通道 ⇒ 遍历机械 `adb logcat` 直接能收，不需要机主动手。
//
// 三条自我约束（都是这个仓反复复发的坑，先写死）：
//  1. **不许出现 `Duration(` 字面量**（D1 闸：字面时长只许住 `lib/ui/tokens.dart`）。
//     窗口用**帧数**而不是时长，读数用微秒整数做减法 —— 全程零个 Duration。
//     连 `getBuildDuration(...)` 这种 API 名都不碰：它的字面里就含 `Duration(`，
//     D1 的正则一视同仁，别去赌它有没有词边界。
//  2. **静止时不许刷日志**。没有帧就没有读数，"这一秒 0 帧"是正确事实而不是性能问题，
//     但把它写成日志会让机主以为在掉帧。所以不足 `_minFlushFrames` 直接丢弃。
//  3. **读数不许冒充"没掉帧"**。探针只报数，不写"流畅/卡顿"这类判断词；
//     判"卡"必须有 build/raster 的中位数与 p95，且来自真机 —— 这条口径已进记忆。
//
// 已知代价（写清楚，别当成零成本）：每条读数会经 `LoggerService` 串行异步落盘一次。
// 一次写一行、约每 120 帧才一行，且落盘不在帧路径上；但它确实不是免费的，
// 所以窗口宁可大不可小。

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../services/logger_service.dart';

/// 帧耗时探针。**只在 `main()` 里 `start()` 一次**，没有第二处入口。
class FrameProbe {
  FrameProbe._();

  static final FrameProbe instance = FrameProbe._();

  /// 攒够这么多帧就出一条读数。
  static const int windowFrames = 120;

  /// 不足这么多帧的残窗直接丢弃（切后台、退页都会留下残窗）。
  static const int minFlushFrames = 20;

  /// 两帧之间隔这么久（微秒）就先把已攒的窗口冲出去，不等满 120 帧。
  /// 为什么需要：动画只有 40 帧就停了的话，那 40 帧永远凑不满窗口 ⇒ 这一段**根本没有读数**，
  /// 而"短动画"恰恰是最该看的。用微秒整数而不是 Duration，见文件头约束 1。
  static const int idleGapUs = 1000000;

  /// 一帧的 build + raster 超过这么久（微秒）算一次"长帧"。
  /// 60Hz 一帧 16667µs、120Hz 8333µs —— 取 33000 是"跨不过两个连续 vsync"的量。
  static const int longFrameUs = 33000;

  final List<int> _buildUs = <int>[];
  final List<int> _rasterUs = <int>[];
  int _longFrames = 0;

  /// 上一批帧被回调到的**挂钟**微秒。**只用来判断"动画停了没有"**（两批之间隔太久就
  /// 把残窗冲出去），不参与任何读数。
  int _lastFrameWallUs = -1;

  /// 窗口内 `totalSpan` 之和（微秒）= 这一段真花在管线上的时间。
  ///
  /// **为什么这里不是跨度、也没有 fps**（169 出包后第一批真机读数自己抓出来的假数）：
  /// 这版 Flutter 的 `FrameTiming` 只给 `buildDuration` / `rasterDuration` / `totalSpan`
  /// 三个**时长**，不给原始时间戳（`buildStart` / `rasterFinish` 在这个版本上不存在，
  /// 我照文档写完，analyze 直接 6 个 undefined_getter）。第一版于是改用"回调到达的挂钟"
  /// 当窗口首尾 —— 而 `addTimingsCallback` **一次回调可能带着攒起来的几十帧**，
  /// 整批共享同一个戳 ⇒ 量出 `span=0ms`，换算出 `fps=898`。
  /// 那是彻底的假数，而且假得很像好消息。所以读数一律只吃帧自己的时长。
  int _busyUs = 0;
  bool _running = false;

  /// 幂等：重复调用只装一次回调。
  void start([WidgetsBinding? binding]) {
    if (_running) return;
    final w = binding ?? WidgetsBinding.instance;
    _running = true;
    w.addTimingsCallback(_onTimings);
  }

  /// 只给测试用：把状态清干净，好逐例验窗口逻辑。
  void resetForTest() {
    _buildUs.clear();
    _rasterUs.clear();
    _longFrames = 0;
    _busyUs = 0;
    _lastFrameWallUs = -1;
  }

  void _onTimings(List<FrameTiming> timings) {
    if (timings.isEmpty) return;
    final nowUs = DateTime.now().microsecondsSinceEpoch;
    if (_buildUs.isNotEmpty && nowUs - _lastFrameWallUs > idleGapUs) {
      _flush();
    }
    for (final t in timings) {
      // build 与 raster 各自独立计数：raster 长是 GPU/光栅化侧，build 长是
      // 我们的 widget 树重建侧。混成一个"帧时间"就分不出该修哪一边。
      final build = t.buildDuration.inMicroseconds;
      final raster = t.rasterDuration.inMicroseconds;
      _buildUs.add(build);
      _rasterUs.add(raster);
      _busyUs += t.totalSpan.inMicroseconds;
      if (build + raster > longFrameUs) _longFrames++;
    }
    _lastFrameWallUs = nowUs;
    if (_buildUs.length >= windowFrames) _flush();
  }

  void _flush() {
    final n = _buildUs.length;
    if (!shouldFlush(n)) {
      resetForTest();
      return;
    }
    LoggerService.instance.info(
      formatWindow(
          buildUs: _buildUs, rasterUs: _rasterUs, busyUs: _busyUs, longFrames: _longFrames),
      cat: LogCat.perf,
      tag: 'FrameProbe',
    );
    resetForTest();
  }

  /// 残窗要不要冲出去。不足 `minFlushFrames` 就丢弃 —— 见文件头约束 2：
  /// "这一阵子没帧"是正确事实，写成日志会被读成"在掉帧"。
  @visibleForTesting
  static bool shouldFlush(int frames) => frames >= minFlushFrames;

  /// **线格式**：一条读数长什么样。遍历机械靠正则吃这行，所以它是契约而不是排版 ——
  /// 字段改名/换序都会让机械静默读到 0 条读数（比崩更难查）。`build169` 的判据钉住它。
  ///
  /// build 与 raster 分开报：raster 长是 GPU/光栅化侧，build 长是我们的 widget 树
  /// 重建侧，混成一个"帧时间"就分不出该修哪一边。
  ///
  /// **为什么是 `busy=` 而不是 `span=` 也没有 `fps=`**（169 出包后第一次真机读数就抓出来的）：
  /// 这版 `FrameTiming` 不给原始时间戳，只有 `buildDuration`/`rasterDuration`/`totalSpan`
  /// 三个时长。我第一版用"回调到达的挂钟"当窗口首尾去算跨度，而 `addTimingsCallback`
  /// **一次回调可能带着攒起来的几十帧** ⇒ 整批共享同一个时间戳，跨度量出来是 0ms 或 128ms，
  /// 换算出的 fps 高达 898 —— 是个彻底假的数量。真能负责的还是帧自己的时长，
  /// 所以这里报 `busy`（窗口内 `totalSpan` 之和），**不报窗口墙钟跨度、不报 fps**。
  @visibleForTesting
  static String formatWindow({
    required List<int> buildUs,
    required List<int> rasterUs,
    required int busyUs,
    required int longFrames,
  }) {
    final b = List<int>.from(buildUs)..sort();
    final r = List<int>.from(rasterUs)..sort();
    return 'Perf frames=${b.length} busy=${(busyUs / 1000.0).toStringAsFixed(0)}ms '
        'build_med=${_pct(b, 0.5)} build_p95=${_pct(b, 0.95)} build_max=${_max(b)} '
        'raster_med=${_pct(r, 0.5)} raster_p95=${_pct(r, 0.95)} raster_max=${_max(r)} '
        'long33ms=$longFrames';
  }

  static String _max(List<int> sorted) => _us(sorted.isEmpty ? 0 : sorted.last);

  static String _us(int v) => (v / 1000.0).toStringAsFixed(2);

  static String _pct(List<int> sorted, double p) {
    if (sorted.isEmpty) return '0.00';
    final i = ((sorted.length - 1) * p).round();
    return _us(sorted[i]);
  }
}
