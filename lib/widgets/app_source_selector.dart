import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../services/app_download_service.dart';
import '../services/logger_service.dart';
import '../ui/tokens.dart';
import '../utils/app_snackbar.dart';
import 'download_confirm_dialog.dart';
import 'download_progress_widget.dart';

class AppSourceSelectorBottomSheet extends StatefulWidget {
  final String appName;
  final List<AppDownloadSource> sources;

  const AppSourceSelectorBottomSheet({
    super.key,
    required this.appName,
    required this.sources,
  });

  static Future<void> show(
    BuildContext context, {
    required String appName,
    required List<AppDownloadSource> sources,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        // build154：原来是散写的 20，既不在 {6,8,12,14} 档位里，也是 R3 的漏检形
        // （棘轮只扫 `BorderRadius.circular(`，`BorderRadius.vertical(top: Radius.circular(20))`
        // 看不见）。这个弹层顶部圆角与全 App 的分组卡片（14）不一致，真机上
        // 表现为"唯一一个更圆的底部弹层"。
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(AppRadius.card)),
      ),
      builder: (_) => AppSourceSelectorBottomSheet(
        appName: appName,
        sources: sources,
      ),
    );
  }

  @override
  State<AppSourceSelectorBottomSheet> createState() =>
      _AppSourceSelectorBottomSheetState();
}

class _AppSourceSelectorBottomSheetState
    extends State<AppSourceSelectorBottomSheet> {
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    final downloadSvc = context.watch<AppDownloadService>();

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: colorScheme.appPanelLight,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: colorScheme.appBorder),
                    ),
                    child: Icon(Icons.download_rounded,
                        color: colorScheme.appTextSub),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${widget.appName} APK',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context)
                                .textTheme
                                .titleLarge
                                ?.copyWith(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 2),
                        Text(
                            isZh
                                ? '找到 ${widget.sources.length} 个来源'
                                : 'Found ${widget.sources.length} source(s)',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Divider(height: 1),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.separated(
                  controller: scrollController,
                  itemCount: widget.sources.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final s = widget.sources[index];
                    return _SourceCard(
                      source: s,
                      onChoose: () async {
                        // 【v1.3.1 二合一】：点"选这个源"直接弹出 DownloadConfirmDialog（含来源详情+风险警告+目录外提示）
                        // 不再多弹一个"前置确认"窗口。
                        if (!context.mounted) return;
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (_) => DownloadConfirmDialog(
                            appName: widget.appName,
                            source: s,
                            // 如果 source 非官方级（即非 🟢 official），提示用户"这是目录外/第三方/未知来源，风险自担"
                            highlightOutOfCatalog:
                                s.trustLevel != SourceTrustLevel.official,
                          ),
                        );
                        if (confirmed == true && context.mounted) {
                          Navigator.pop(context);
                          showDialog(
                            context: context,
                            barrierDismissible: false,
                            builder: (ctx) => DownloadProgressDialog(
                              appName: widget.appName,
                              source: s,
                            ),
                          );
                          try {
                            await downloadSvc.startDownload(
                              appName: widget.appName,
                              source: s,
                            );
                          } catch (e, st) {
                            // build138（P1-2）：这里原来是 `catch (_)` —— 既不留日志
                            // 也不提示用户，还顺手 pop 掉本会渲染 task.error 的进度弹窗，
                            // 于是「互斥锁被上一次失败下载占死」这类问题在真机上表现为
                            // 「点了没反应」，且日志里一个字都没有。改成记日志 + 明示用户。
                            LoggerService.instance.error(
                                '[Download] startDownload failed: '
                                '${widget.appName} via ${s.sourceName}',
                                error: e,
                                stack: st,
                                tag: 'DL');
                            if (context.mounted) {
                              AppSnackBar.showSnackBar(
                                  context,
                                  SnackBar(
                                    content: Text(isZh
                                        ? '下载失败：$e'
                                        : 'Download failed: $e'),
                                    duration: const Duration(seconds: 5),
                                  ));
                            }
                            // M19 修复：startDownload 失败（如目录创建失败）时
                            // 必须关闭已弹出的 DownloadProgressDialog，否则
                            // 对话框无关闭按钮会卡死 UI。
                            if (context.mounted) {
                              Navigator.of(context, rootNavigator: true).pop();
                            }
                          }
                        }
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SourceCard extends StatelessWidget {
  final AppDownloadSource source;
  final VoidCallback onChoose;

  const _SourceCard({required this.source, required this.onChoose});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';

    late final String badgeLabel;
    late final BoxDecoration badge;
    late final Color badgeColor;

    switch (source.trustLevel) {
      case SourceTrustLevel.official:
        badgeLabel = isZh ? '官方' : 'Official';
        badge = BoxDecoration(
          color: colorScheme.appPanelLight,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colorScheme.appBorder),
        );
        badgeColor = colorScheme.appTextSub;
      case SourceTrustLevel.trustedThirdParty:
        badgeLabel = isZh ? '可信第三方' : 'Trusted';
        badge = BoxDecoration(
          color: colorScheme.appPanel,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colorScheme.appBorder),
        );
        badgeColor = colorScheme.appTextSub;
      case SourceTrustLevel.unknown:
        badgeLabel = isZh ? '未知' : 'Unknown';
        badge = BoxDecoration(
          color: colorScheme.errorContainer.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colorScheme.error.withValues(alpha: 0.35)),
        );
        badgeColor = colorScheme.error;
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colorScheme.appPanelLight,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: colorScheme.appBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(source.sourceName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: badge,
                constraints: const BoxConstraints(maxWidth: 170),
                child: Text(badgeLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: badgeColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(source.sourceDomain,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontFamily: 'monospace',
                  )),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _InfoChip(label: 'v${source.version}', icon: Icons.tag),
              _InfoChip(label: source.size, icon: Icons.save_rounded),
              _InfoChip(label: source.arch, icon: Icons.memory_rounded),
            ],
          ),
          // v1.5.0：releaseDate 距今 >90 天 → 显示黄色"数据较旧"警告徽章
          if (source.daysSinceRelease > 90) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: colorScheme.appPanelLight,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: colorScheme.appBorder),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded,
                      size: 16, color: colorScheme.appTextSub),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      // build154：去掉 emoji。左侧已经有 Icons.warning_amber_rounded
                      // 承担"警告"语义，⚠️ 属于同一信息重复渲染，且 R1 明令
                      // 用户可见串不放 emoji（部分 OEM 字体会把它渲成方块/双色图标，
                      // 与全 App 的 Material 图标风格打架）。
                      isZh
                          ? '数据较旧（已 ${source.daysSinceRelease} 天未核对）'
                          : 'Stale data (unchecked for ${source.daysSinceRelease} days)',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: colorScheme.appTextSub,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (source.changelog?.isNotEmpty ?? false) ...[
            const SizedBox(height: 10),
            Text(source.changelog!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      height: 1.3,
                    )),
          ],
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 44,
            child: FilledButton.icon(
              onPressed: onChoose,
              icon: const Icon(Icons.arrow_downward_rounded, size: 18),
              label: Text(isZh ? '选择此源下载' : 'Choose source',
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final String label;
  final IconData icon;
  const _InfoChip({required this.label, required this.icon});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Flexible(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurface,
                    fontWeight: FontWeight.w500)),
          ),
        ],
      ),
    );
  }
}
