import 'package:flutter/widgets.dart';

/// 缩略图/头像类 `Image.file` 的**限宽解码**工具。
///
/// 立项原因（build137 全量扫描 P2-4，build138 落地）：手机拍照动辄 4000×3000，
/// 而 UI 上只显示 28–80dp。不给 `cacheWidth` 就是把原图整张解码进图像缓存——
/// 单张位图 ~48MB，解码 CPU 与内存双高；长会话里多条带图消息会直接把低端机打穿。
///
/// 全库原本只有一处做对了（`message_bubble_v2.dart` 的 build129 头像），
/// 其余 6 处（输入区附件条 / 气泡内联图 / 附件缩略图 / 生图与生视频的参考图 /
/// 厂商头像）都漏了。本文件把那处样板抽成函数，让"只给 cacheWidth"这条
/// 约束有唯一实现点，不必在 6 个地方各自注释一遍。
///
/// ⚠️ **只给 cacheWidth，不要同时给 cacheHeight**：两个都给会把非方图按
/// 各自边长拉伸裁切；只限宽可保留宽高比。

/// 按 [displayLogicalWidth]（dp）与设备 DPR 折算出物理像素限宽。
///
/// 与调用点的 `width:` 保持同一口径：调用点显示多大，这里就按多大折算。
int decodeCacheWidth(BuildContext context, double displayLogicalWidth) {
  final dpr = MediaQuery.of(context).devicePixelRatio;
  // DPR 异常（0 / NaN 在测试桩里出现过）时退回 1，避免 round() 出 0 ——
  // cacheWidth: 0 会让解码器拿到无效尺寸。
  final safeDpr = dpr.isFinite && dpr > 0 ? dpr : 1.0;
  final w = (displayLogicalWidth * safeDpr).round();
  return w < 1 ? 1 : w;
}
