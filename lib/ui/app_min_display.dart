import 'dart:async';

import 'package:flutter/material.dart';

import 'tokens.dart';

/// 「还要再等多久才能切走」——纯函数，便于单测。
///
/// 已等够（或本来就不需要等）返回 [Duration.zero]；否则返回剩余时长。
/// 之所以提成纯函数：最小停留是**时间语义**，不该只能靠 widget 测试里的
/// `pump(Duration)` 去间接验证边界。
Duration minDisplayRemain({
  required Duration elapsed,
  required Duration minDisplay,
}) {
  // build133：负的 elapsed 是脏输入（时钟回拨 / 计时起点未初始化）。
  // 先夹到 0 再相减 —— 否则 `minDisplay - (-50ms)` 会比 minDisplay 还长，
  // 等于凭一个脏输入把加载态又延长一截。测试里专门钉住了这条边界。
  final e = elapsed.isNegative ? Duration.zero : elapsed;
  final remain = minDisplay - e;
  return remain > Duration.zero ? remain : Duration.zero;
}

/// build133：让 loading 态**至少停留** [minDisplay] 再切到结果（四态切换的守门人）。
///
/// 为什么需要：只按真实耗时切态时，快请求会让加载态一闪而过 —— 用户看到的不是
/// 「正在加载」而是「闪了一下」，比不显示更廉价；反过来，慢请求又必须让加载态
/// 留够时间。两次取值见 [AppDur.minLoading]（首屏/整页 400ms）与
/// [AppDur.minAsync]（局部 200ms）。
///
/// 用法是**二选一开关**（不是包一层 loading）：
/// ```dart
/// AppMinDisplay(
///   loading: _loading,
///   loadingChild: const AppSkeleton.lines(3),
///   child: _error != null ? ErrorState(...) : EmptyState(...),
///   minDisplay: AppDur.minAsync,
/// )
/// ```
/// 内部用 [AnimatedSwitcher] 交叉淡入，时长走 [AppMotion.duration]（reduced 时归零）。
///
/// ⚠️ 边界：`loading` 由 true 变 false 时才计时；「false → true」立刻显示 loading，
/// 不做延迟出现（延迟出现需要另一个阈值，属于防闪烁，与本组件职责不同）。
class AppMinDisplay extends StatefulWidget {
  const AppMinDisplay({
    super.key,
    required this.loading,
    required this.loadingChild,
    required this.child,
    this.minDisplay = AppDur.minLoading,
  });

  /// 真实加载态（来自 future / 请求）。
  final bool loading;

  /// loading 期间显示的子树。
  final Widget loadingChild;

  /// loading 结束后显示的子树（空态 / 错误态 / 内容）。
  final Widget child;

  /// loading 至少显示的时长。
  final Duration minDisplay;

  @override
  State<AppMinDisplay> createState() => _AppMinDisplayState();
}

class _AppMinDisplayState extends State<AppMinDisplay> {
  /// 当前**实际**展示 loading 吗（可能比 [AppMinDisplay.loading] 多留一会儿）。
  bool _showLoading = false;
  DateTime? _since;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _showLoading = widget.loading;
    if (_showLoading) _since = DateTime.now();
  }

  @override
  void didUpdateWidget(covariant AppMinDisplay old) {
    super.didUpdateWidget(old);
    if (old.loading == widget.loading) return;
    if (widget.loading) {
      // 重新进入 loading：清掉待执行的切走回调，重新计时
      _timer?.cancel();
      _timer = null;
      setState(() {
        _showLoading = true;
        _since = DateTime.now();
      });
      return;
    }
    // 离开 loading：算够不够最小停留
    final since = _since;
    final remain = since == null
        ? Duration.zero
        : minDisplayRemain(
            elapsed: DateTime.now().difference(since),
            minDisplay: widget.minDisplay,
          );
    if (remain == Duration.zero) {
      setState(() {
        _showLoading = false;
        _since = null;
      });
      return;
    }
    _timer?.cancel();
    _timer = Timer(remain, () {
      if (!mounted) return;
      setState(() {
        _showLoading = false;
        _since = null;
      });
    });
  }

  @override
  void dispose() {
    // 铁律：页面销毁后回调不得再跑
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 无障碍「移除动画」：最小停留的意义是让用户看见加载，而该模式下用户明确
    // 要求别等 ⇒ 直接跟随真实状态，不延时。
    final showLoading =
        AppMotion.reduced(context) ? widget.loading : _showLoading;
    return AnimatedSwitcher(
      duration: AppMotion.duration(context, AppDur.fast),
      switchInCurve: AppCurve.enter,
      switchOutCurve: AppCurve.exit,
      child: showLoading
          ? KeyedSubtree(
              key: const ValueKey<String>('loading'),
              child: widget.loadingChild,
            )
          : KeyedSubtree(
              key: const ValueKey<String>('ready'),
              child: widget.child,
            ),
    );
  }
}
