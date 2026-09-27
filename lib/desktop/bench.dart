/// B1 性能实测支撑：帧耗时统计 + 合成大文件生成。
/// bench 驱动本体在 workbench_screen.dart（要碰 State），这里只放纯逻辑。
library;

import 'dart:ui' show FramePhase;

import 'package:flutter/scheduler.dart';

/// 单帧总耗时（vsync→raster 完成）超过该值记一次 span 卡顿。60Hz 一帧 ≈ 16.7ms。
/// 注意：UI/raster 两线程流水时 totalSpan 会把跨帧重叠也算进来，偏严，
/// 只当参考口径保留；主判据用下面的 gap 口径。
const int kJankThresholdMicros = 16700;

/// 掉帧口径：相邻两帧 raster 完成时刻的间隔超过 1.5 个预算（25ms）记一次掉帧。
/// 流水线下只要持续产出，totalSpan 超预算并不等于用户看到卡顿；
/// raster 完成间隔才是「屏幕上两帧画面之间隔了多久」。
const int kGapJankThresholdMicros = 25000;

class JankMeter {
  int frames = 0;
  int spanJank = 0;
  int worstSpanMicros = 0;
  int gapJank = 0;
  int worstGapMicros = 0;
  final List<int> _buildMicros = [];
  final List<int> _rasterMicros = [];
  int? _lastRasterFinish;

  void start() {
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  void stop() {
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      frames++;
      _buildMicros.add(t.buildDuration.inMicroseconds);
      _rasterMicros.add(t.rasterDuration.inMicroseconds);
      final span = t.totalSpan.inMicroseconds;
      if (span > worstSpanMicros) worstSpanMicros = span;
      if (span > kJankThresholdMicros) spanJank++;
      final finish = t.timestampInMicroseconds(FramePhase.rasterFinish);
      final prev = _lastRasterFinish;
      if (prev != null && finish > prev) {
        final gap = finish - prev;
        if (gap > worstGapMicros) worstGapMicros = gap;
        if (gap > kGapJankThresholdMicros) gapJank++;
      }
      _lastRasterFinish = finish;
    }
  }

  static double _p(List<int> xs, double q) {
    if (xs.isEmpty) return 0;
    final s = List<int>.from(xs)..sort();
    return double.parse(
        (s[((s.length - 1) * q).round()] / 1000).toStringAsFixed(2));
  }

  Map<String, dynamic> toJson({int? wallMs}) => {
        'frames': frames,
        if (wallMs != null) 'wallMs': wallMs,
        if (wallMs != null && wallMs > 0)
          'effectiveFps':
              double.parse((frames * 1000 / wallMs).toStringAsFixed(1)),
        'buildP50Ms': _p(_buildMicros, 0.50),
        'buildP95Ms': _p(_buildMicros, 0.95),
        'buildWorstMs': _p(_buildMicros, 1),
        'rasterP50Ms': _p(_rasterMicros, 0.50),
        'rasterP95Ms': _p(_rasterMicros, 0.95),
        'rasterWorstMs': _p(_rasterMicros, 1),
        // 旧口径（含流水线重叠，偏严），留作对照。
        'spanJank': spanJank,
        'worstFrameMs':
            double.parse((worstSpanMicros / 1000).toStringAsFixed(2)),
        // 主口径：屏幕上真实掉帧次数。
        'gapJank': gapJank,
        'worstGapMs':
            double.parse((worstGapMicros / 1000).toStringAsFixed(2)),
      };
}

/// 合成 N 行「像真的」Dart 源码：中文、全角、字符串、注释、转义都混上。
/// bench 用它造 67k 行大文件（本仓真实最大文件只有 ~3.2k 行，67k 是
/// 验收口径里的目标规模，只能合成）。
String buildSynthSource(int lines) {
  final buf = StringBuffer();
  for (var i = 0; i < lines; i++) {
    switch (i % 5) {
      case 0:
        buf.writeln("final value$i = '字符串内容 $i，全角标点。！';");
      case 1:
        buf.writeln('// 注释：第 $i 行 comment with some english words');
      case 2:
        buf.writeln('int compute$i(int a, int b) => a * $i + b; // 尾注释');
      case 3:
        buf
            .writeln('const key$i = "escaped \\"quote\\" and backslash $i";');
      default:
        buf.writeln(
            'class Widget$i extends StatelessWidget { /* 块注释 $i */ }');
    }
  }
  return buf.toString();
}
