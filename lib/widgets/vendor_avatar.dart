import 'package:flutter/material.dart';

import '../models/api_provider_template.dart';
import '../services/vendor_icon_cache.dart';
import '../ui/image_decode.dart';

/// 厂商图标（build98 重构）：
/// - 内置保底：品牌色圆角方块 + 模板 IconData（离线渲染，永无白块）；
/// - 远程更新：模板 JSON 下发 iconUrl 时，经 VendorIconCache 下载并磁盘
///   缓存后显示真实图标；
/// - 底色随主题（build97 实测硬编码 Colors.white 在深色模式突兀）；
///
/// build100（中1）深色模式适配：lobe-icons CDN 同时提供 light/ 与 dark/ 两套
/// （light = 黑色线条 logo 用于浅色底；dark = 白色线条 logo 用于深色底），
/// 按 Theme.of(context).brightness 自动切换；以前写死 light/ 在深色模式
/// 下纯黑线条 logo 贴深灰底看不清（OpenAI/Claude/LM Studio 类尤甚）。
///
/// 废弃 google.com/s2/favicons：国内返回空白占位图（HTTP 200 但内容空白），
/// 是 API 配置页「纯白方块」的根因。
class VendorAvatar extends StatelessWidget {
  final String templateId;
  final double size;
  final double borderRadius;

  const VendorAvatar({
    super.key,
    required this.templateId,
    this.size = 24,
    this.borderRadius = 6,
  });

  static ApiProviderTemplate? _findTemplate(String id) {
    final list = ApiProviderTemplateCatalog.instance.hasRemote
        ? ApiProviderTemplateCatalog.instance.all
        : ApiProviderTemplate.all;
    for (final t in list) {
      if (t.id == id) return t;
    }
    return null;
  }

  Widget _fallback(ColorScheme cs) {
    if (templateId == ApiProviderTemplate.customId) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: cs.tertiary.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(borderRadius),
        ),
        child: Icon(Icons.build, size: size * 0.62, color: cs.tertiary),
      );
    }
    final t = _findTemplate(templateId);
    if (t == null) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: cs.outlineVariant.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(borderRadius),
        ),
        child: Icon(Icons.build, size: size * 0.62, color: cs.onSurfaceVariant),
      );
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: t.color,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      child: Icon(t.icon, size: size * 0.62, color: Colors.white),
    );
  }

  /// build100（中1）：按主题深浅切换 lobe-icons 的 light/ 与 dark/ 路径。
  /// 路径里含 /light/ 时替换为 /dark/，否则原样返回（兼容未来用户自配 URL）。
  /// 校验：仅在 path 里精确替换一处，避免把 host 段或 query 误改。
  static String _iconUrlForBrightness(String url, Brightness brightness) {
    if (brightness != Brightness.dark) return url;
    if (!url.contains('/light/')) return url;
    return url.replaceFirst('/light/', '/dark/');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fb = _fallback(cs);
    final rawUrl = _findTemplate(templateId)?.iconUrl ?? '';
    // 无远程图标 → 内置品牌块保底（离线/未下发时永远有图案）
    if (rawUrl.isEmpty) return fb;
    final iconUrl = _iconUrlForBrightness(rawUrl, Theme.of(context).brightness);
    return FutureBuilder(
      future: VendorIconCache.instance.resolve(iconUrl),
      builder: (context, snap) {
        final file = snap.data;
        if (file == null) return fb;
        return ClipRRect(
          borderRadius: BorderRadius.circular(borderRadius),
          child: Container(
            width: size,
            height: size,
            // 底色随主题：深色模式不再是硬编码白块；
            // light/ 图标是黑色线条 → 浅底（cs.surface 浅）；dark/ 图标是
            // 白色线条 → 深底（cs.surface 深）；色块自身已提供足够对比。
            color: cs.surface,
            child: Image.file(
              file,
              width: size,
              height: size,
              // build138（扫描 P2-4）：厂商图标缓存文件按 size×DPR 限宽
              cacheWidth: decodeCacheWidth(context, size),
              fit: BoxFit.contain,
              errorBuilder: (context, error, stack) => fb,
            ),
          ),
        );
      },
    );
  }
}
