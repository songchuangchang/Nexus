import 'dart:async';

import 'package:flutter/material.dart';

import 'app_min_display.dart';
import 'app_pulse.dart';
import 'tokens.dart';

/// 四态（build133）：加载中 / 成功 / 空 / 失败。
///
/// 之所以只有四态：这是「一个异步区块」能出现的全部结果。把它们收成一个枚举，
/// 是为了禁止各处再自造 `bool loading + bool empty + String? error` 三件套 ——
/// 那种写法必然出现「loading 与 error 同时为 true」的非法组合。
enum AppRunState { loading, ok, empty, error }

/// build133：四态图标（统一 16px 中性色 + 语义标签）。
///
/// 与裸 `Icon` 的差别不在画得像不像，而在三件事：
/// ① **最小停留**：loading → 结果 至少显示 [minDisplay]（见 [AppMinDisplay] 的理由）；
/// ② **有语义标签**：`Semantics(label:)` 让读屏能说出「加载中/没有结果/失败」——
///    光一个图标对无障碍等于不存在；
/// ③ **reduced 下不动**：动画时长走 [AppMotion.duration]，loading 态换成静止图形。
///
/// 配色沿用朴素风：成功/失败用中性灰阶 + Material 图标语义，不引入红绿大色块
/// （列表里一眼一片红绿会盖过内容本身）。
class AppStateIcon extends StatefulWidget {
  const AppStateIcon({
    super.key,
    required this.state,
    this.size = 16,
    this.zh = true,
    this.minDisplay = AppDur.minLoading,
    this.loadingChild,
  });

  final AppRunState state;
  final double size;
  final bool zh;

  /// loading 至少显示的时长。
  final Duration minDisplay;

  /// 自定义 loading 图形；默认 [AppPulse]。
  final Widget? loadingChild;

  @override
  State<AppStateIcon> createState() => _AppStateIconState();
}

class _AppStateIconState extends State<AppStateIcon> {
  late AppRunState _shown = widget.state;
  DateTime? _since;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (_shown == AppRunState.loading) _since = DateTime.now();
  }

  @override
  void didUpdateWidget(covariant AppStateIcon old) {
    super.didUpdateWidget(old);
    if (old.state == widget.state) return;
    _switchTo(widget.state);
  }

  /// 切态：**离开 loading** 时才需要等够最小停留；其余切换立即生效
  /// （loading → 结果 若反过来延迟，用户会看到「已经好了却还在转」）。
  void _switchTo(AppRunState next) {
    _timer?.cancel();
    _timer = null;
    if (next == AppRunState.loading) {
      setState(() {
        _shown = next;
        _since = DateTime.now();
      });
      return;
    }
    final since = _since;
    final remain = since == null
        ? Duration.zero
        : minDisplayRemain(
            elapsed: DateTime.now().difference(since),
            minDisplay: widget.minDisplay,
          );
    if (remain == Duration.zero) {
      setState(() {
        _shown = next;
        _since = null;
      });
      return;
    }
    _timer = Timer(remain, () {
      if (!mounted) return;
      setState(() {
        _shown = next;
        _since = null;
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  IconData _iconFor(AppRunState s) => switch (s) {
        AppRunState.loading => Icons.hourglass_empty,
        AppRunState.ok => Icons.check_circle_outline,
        AppRunState.empty => Icons.inbox_outlined,
        AppRunState.error => Icons.error_outline,
      };

  String _labelFor(AppRunState s) => switch (s) {
        AppRunState.loading => widget.zh ? '加载中' : 'Loading',
        AppRunState.ok => widget.zh ? '已完成' : 'Done',
        AppRunState.empty => widget.zh ? '没有结果' : 'No results',
        AppRunState.error => widget.zh ? '失败' : 'Failed',
      };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // build133：reduced 下**一律以 widget.state 为准**（不做最小停留）。
    //
    // 这里修掉一个自测抓到的真缺陷：此前 `showLoading` 看 `widget.state`、
    // 而 `_icon`/`_label` 看 `_shown` ⇒ reduced 时状态已切到 ok，图标却还是
    // loading 那一个（**显示错图标**，读屏还会念错）。现在收敛成单一来源
    // `effective`，颜色/图标/标签/动画键全部跟着它，不再可能互相打架。
    final effective = AppMotion.reduced(context) ? widget.state : _shown;
    final color = switch (effective) {
      AppRunState.loading => cs.onSurfaceVariant,
      AppRunState.ok => cs.onSurfaceVariant,
      AppRunState.empty => cs.onSurfaceVariant,
      AppRunState.error => cs.error,
    };
    final showLoading = effective == AppRunState.loading;
    final child = showLoading
        ? (widget.loadingChild ??
            AppPulse(size: widget.size * 0.6, color: color))
        : Icon(_iconFor(effective), size: widget.size, color: color);
    return Semantics(
      label: _labelFor(effective),
      child: AnimatedSwitcher(
        duration: AppMotion.duration(context, AppDur.fast),
        switchInCurve: AppCurve.enter,
        switchOutCurve: AppCurve.exit,
        child: KeyedSubtree(
          key: ValueKey<String>(showLoading ? 'loading' : effective.name),
          child: SizedBox(
            width: widget.size,
            height: widget.size,
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}
