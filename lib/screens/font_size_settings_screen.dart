// v1.7.26：字体大小设置独立页。
// 用户反馈：字体调整嵌在通用设置里，缩放滑块+预览会挤压其他设置项。
// 拆成独立「字体」sub-screen，通用设置只留导航/远程更新等，布局不再挤压。
// 复用 FontSizeProvider（全局字体缩放），UI 从原 general_settings 的
// _buildFontSizeSection 原样迁移，行为不变。

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/font_size_provider.dart';
import '../ui/tokens.dart';

class FontSizeSettingsScreen extends StatelessWidget {
  const FontSizeSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final zh = l.locale.languageCode == 'zh';
    return Scaffold(
      appBar: AppBar(title: Text(zh ? '字体设置' : 'Font Settings')),
      // v1.7.29: 字体设置页预览必须真实反映滑块值（0.8~2.0），不能 clamp，否则拖过 1.2 后预览无变化
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: Consumer<FontSizeProvider>(
          builder: (context, fsp, _) {
            return Container(
              decoration: BoxDecoration(
                color: colorScheme.appPanelLight,
                borderRadius: BorderRadius.circular(AppRadius.card),
                border: Border.all(color: colorScheme.appBorder),
              ),
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
                    child: Row(
                      children: [
                        Icon(Icons.text_fields, color: colorScheme.appTextSub),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(l.tr('fontSize'),
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 15)),
                              const SizedBox(height: 2),
                              Text(l.tr('fontSizeSubtitle'),
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: colorScheme.onSurfaceVariant)),
                            ],
                          ),
                        ),
                        Text(
                          '${fsp.scale.toStringAsFixed(1)}x',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: colorScheme.appTextSub,
                          ),
                        ),
                        TextButton(
                          onPressed: fsp.scale == FontSizeProvider.defaultScale
                              ? null
                              : () =>
                                  fsp.setScale(FontSizeProvider.defaultScale),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            // build177：原来这两行（`Size.zero` ＋ `shrinkWrap`）＝**手写把
                            // Material 的 48dp 命中区撤掉**，平板量到 54.1×11.0（登记表 #128 的
                            // 漏网两处之一，用户 10-01 明确要"自行修复"）。48 由 minimumSize 给，
                            // 不塞进字号里——命中区与视觉大小是两件事。
                            minimumSize: const Size(48, 48),
                            tapTargetSize: MaterialTapTargetSize.padded,
                          ),
                          child: Text(l.tr('fontSizeReset'),
                              style: TextStyle(
                                fontSize: 12,
                                color:
                                    fsp.scale == FontSizeProvider.defaultScale
                                        ? colorScheme.onSurfaceVariant
                                            .withValues(alpha: 0.4)
                                        : colorScheme.primary,
                              )),
                        ),
                      ],
                    ),
                  ),
                  Slider(
                    value: fsp.scale,
                    min: FontSizeProvider.minScale,
                    max: FontSizeProvider.maxScale,
                    divisions: 12,
                    label: '${fsp.scale.toStringAsFixed(1)}x',
                    onChanged: (v) => fsp.setScale(v),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(l.tr('fontSizeSmall'),
                            style: TextStyle(
                                fontSize: 11,
                                color: colorScheme.onSurfaceVariant)),
                        Text(l.tr('fontSizeLarge'),
                            style: TextStyle(
                                fontSize: 11,
                                color: colorScheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: colorScheme.outlineVariant
                              .withValues(alpha: 0.5)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l.tr('fontSizePreview'),
                            style: TextStyle(
                                fontSize: 11,
                                color: colorScheme.onSurfaceVariant)),
                        const SizedBox(height: 8),
                        Text(
                          zh ? '标题文字示例' : 'Title Text Sample',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          zh
                              ? '正文内容示例 — 这是聊天消息中的标准文字大小。'
                              : 'Body text sample — this is the standard text size in chat messages.',
                          style: TextStyle(
                            fontSize: 13,
                            color: colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          zh
                              ? '辅助说明文字 — 脚注、时间戳等辅助信息的大小。'
                              : 'Caption text sample — for footnotes, timestamps, and auxiliary info.',
                          style: TextStyle(
                            fontSize: 11,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
