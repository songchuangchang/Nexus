import 'package:flutter/material.dart';

import 'app_min_display.dart';
import 'app_skeleton.dart';
import 'app_state_view.dart';
import 'tokens.dart';

/// 异步区块的统一外壳（build133）：加载 → 结果 / 空 / 失败，四态一次接好。
///
/// 用法（把「三件套布尔」收成一个组件）：
/// ```dart
/// AppAsyncView(
///   loading: _loading,
///   error: _error,
///   onRetry: _load,
///   child: _items.isEmpty ? const AppEmptyView(title: '还没有会话') : _list(),
/// )
/// ```
///
/// 它替调用方处理掉两件最容易被漏掉的事：
/// ① **最小停留**（[AppMinDisplay]）——快请求不让加载态一闪而过；
/// ② **错误优先于加载**：`error` 非空时不再展示加载态（否则「转圈 + 报错」同屏）。
///
/// 刻意不做的事：不接管 future/状态管理、不打印日志、不弹 SnackBar ——
/// 它只是一个**版式**组件，把状态映射成界面；重试由调用方通过 [onRetry] 决定做什么。
class AppAsyncView extends StatelessWidget {
  const AppAsyncView({
    super.key,
    required this.loading,
    required this.child,
    this.error,
    this.loadingChild,
    this.onRetry,
    this.errorTitle,
    this.zh = true,
    this.minDisplay = AppDur.minAsync,
  });

  /// 是否正在加载。
  final bool loading;

  /// 加载完成后的内容（含调用方自己的空态）。
  final Widget child;

  /// 非空即视为失败。
  final Object? error;

  /// 加载中占位；默认思考面板形状的骨架。
  final Widget? loadingChild;

  /// 重试回调；不给则错误态不显示按钮。
  final VoidCallback? onRetry;

  final String? errorTitle;
  final bool zh;

  /// 最小停留时长（局部默认 [AppDur.minAsync]，整页场景传 [AppDur.minLoading]）。
  final Duration minDisplay;

  @override
  Widget build(BuildContext context) {
    final failed = error != null;
    return AppMinDisplay(
      loading: loading && !failed,
      minDisplay: minDisplay,
      loadingChild: loadingChild ?? const AppSkeleton.bubble(),
      child: failed
          ? AppErrorView(
              title: errorTitle,
              onRetry: onRetry,
              zh: zh,
              compact: true,
            )
          : child,
    );
  }
}
