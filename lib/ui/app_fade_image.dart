import 'package:flutter/material.dart';

import 'app_skeleton.dart';
import 'tokens.dart';

/// 网络图片统一入口（build133）：淡入 + 骨架占位 + 失败回退。
///
/// 为什么必须统一：`Image.network` 的默认行为是三处一致的老问题 ——
/// ① 加载完成是**硬切**（白块 → 图），滚动列表里一屏十几张图会「闪」；
/// ② 失败时显示的是 Flutter 的破图（一个带感叹号的方框），在朴素风里格外扎眼；
/// ③ 圆角要么忘记裁、要么各自写 `ClipRRect`，裁出来的圆角还不一致。
///
/// 本组件把这三件事一次做对：`frameBuilder` 淡入、`errorBuilder` 走中性占位、
/// 圆角统一 [AppRadius.panel]。**不做**缓存与重试（那是 `ImageProvider` 层的事）。
class AppFadeImage extends StatelessWidget {
  const AppFadeImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.radius = AppRadius.panel,
    this.headers,
    this.placeholder,
    this.errorChild,
    this.semanticLabel,
  });

  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;

  /// 圆角（令牌）。
  final double radius;

  final Map<String, String>? headers;

  /// 加载中占位；默认骨架条。
  final Widget? placeholder;

  /// 失败占位；默认中性「图片不可用」图标。
  /// 刻意**不提供 onError 回调** —— 在 errorBuilder 里回调父层等于在 build 期间
  /// 触发外部副作用（父层很可能 setState），这类写法迟早撞上「setState during build」。
  final Widget? errorChild;

  /// 无障碍描述；图片有信息含义时必须传。
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.network(
        url,
        width: width,
        height: height,
        fit: fit,
        headers: headers,
        semanticLabel: semanticLabel,
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return placeholder ??
              AppSkeleton(
                width: width,
                height: height ?? 160,
                radius: radius,
              );
        },
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (wasSynchronouslyLoaded) return child;
          return AnimatedOpacity(
            opacity: frame == null ? 0 : 1,
            duration: AppMotion.duration(context, AppDur.base),
            curve: AppCurve.enter,
            child: child,
          );
        },
        errorBuilder: (context, error, stack) =>
            errorChild ??
            Container(
              width: width,
              height: height ?? 120,
              color: cs.appPanel,
              alignment: Alignment.center,
              child: Icon(
                Icons.image_not_supported_outlined,
                size: 20,
                color: cs.appTextFaint,
              ),
            ),
      ),
    );
  }
}
