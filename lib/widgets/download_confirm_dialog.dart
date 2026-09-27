import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../services/app_download_service.dart';
import '../ui/tokens.dart';

class DownloadConfirmDialog extends StatefulWidget {
  final String appName;
  final AppDownloadSource source;

  /// v1.3.1 新：true 时在底部额外显示"目录外/非官方/第三方来源"的明确风险提示
  final bool highlightOutOfCatalog;

  const DownloadConfirmDialog({
    super.key,
    required this.appName,
    required this.source,
    this.highlightOutOfCatalog = false,
  });

  @override
  State<DownloadConfirmDialog> createState() => _DownloadConfirmDialogState();
}

class _DownloadConfirmDialogState extends State<DownloadConfirmDialog> {
  String _saveDir = '';
  String _fileName = '';

  @override
  void initState() {
    super.initState();
    _computePaths();
  }

  Future<void> _computePaths() async {
    final svc = context.read<AppDownloadService>();
    final dir = await svc.getSaveDirectory(widget.appName);
    // build98：文件名推断统一走 AppDownloadService.guessFileNameFromUrl
    // （兜底名语义不变：appName_v版本.apk）
    final fallback =
        '${widget.appName.replaceAll(RegExp(r'[\\/:*?"<>|\s]'), '_')}_v${widget.source.version.replaceAll('.', '_')}.apk';
    _fileName = AppDownloadService.guessFileNameFromUrl(
      widget.source.downloadUrl,
      preferredExt: '.apk',
      fallbackName: fallback,
    );
    if (mounted) {
      setState(() => _saveDir = dir);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';

    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Row(
        children: [
          Icon(Icons.security_rounded, color: colorScheme.appTextSub),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              isZh ? '确认下载' : 'Confirm Download',
              maxLines: 1,
              overflow: TextOverflow.fade,
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: SizedBox(
          width: double.maxFinite,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(isZh ? '即将下载以下文件：' : 'About to download:',
                  style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 14),
              // v1.7.18（需求3）：信任徽章抽为独立 TrustBadge widget（三态）
              TrustBadge(
                level: widget.source.trustLevel,
                isZh: isZh,
              ),
              const SizedBox(height: 14),
              // v1.7.19（P2）：9 个 _InfoRow 改为数据驱动列表构建，降低 build CC
              ..._buildInfoRows(isZh),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: colorScheme.appPanelLight,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: colorScheme.appBorder),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline_rounded,
                        size: 18, color: colorScheme.appTextSub),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        isZh
                            ? '文件仅保存到上述目录，不会写入其他位置。'
                            : 'File will only be saved to the folder above.',
                        style: TextStyle(
                            fontSize: 12,
                            color: colorScheme.appTextSub,
                            fontWeight: FontWeight.w500),
                      ),
                    ),
                  ],
                ),
              ),
              // ===== v1.3.1 二合一关键模块：目录外 / 非官方 确定提示 =====
              // v1.7.18（需求3）：抽为独立方法降 CC
              if (widget.highlightOutOfCatalog) _buildOutOfCatalogWarning(isZh),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(isZh ? '取消' : 'Cancel'),
        ),
        FilledButton.icon(
          onPressed:
              _saveDir.isEmpty ? null : () => Navigator.pop(context, true),
          icon: Icon(
            widget.highlightOutOfCatalog
                ? Icons.warning_amber_rounded
                : Icons.verified_user_rounded,
          ),
          label: Text(
            isZh
                ? (widget.highlightOutOfCatalog ? '我已知风险，允许下载' : '允许下载')
                : 'Allow',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  /// v1.7.18（需求3）：目录外/非官方来源风险提示（抽自 build 降 CC）
  Widget _buildOutOfCatalogWarning(bool isZh) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: colorScheme.errorContainer.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: colorScheme.error.withValues(alpha: 0.35)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.gpp_bad_outlined, size: 18, color: colorScheme.error),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                isZh
                    ? '⚠️ 此来源不在内置官方目录中，属于第三方/联网搜索到的链接。\n'
                        '请确认：你知道自己在下载什么、来源域名可信、文件 SHA256（如有）与官方一致，再继续。'
                    : '⚠️ This source is OUT OF the built-in catalog (3rd-party / online-only).\n'
                        'Continue only if you fully trust this URL and the SHA256 (if any) matches the official one!',
                style: TextStyle(
                    fontSize: 12, color: colorScheme.error, height: 1.35),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildInfoRows(bool isZh) {
    final rows = <Widget>[
      _InfoRow(
        label: isZh ? '应用' : 'App',
        value: '${widget.appName} v${widget.source.version}',
      ),
      _InfoRow(
        label: isZh ? '来源' : 'Source',
        value: widget.source.sourceName,
      ),
      _InfoRow(
        label: isZh ? '域名' : 'Domain',
        value: widget.source.sourceDomain,
      ),
      _InfoRow(
        label: isZh ? '大小' : 'Size',
        value: widget.source.size,
      ),
      _InfoRow(
        label: isZh ? '架构' : 'Arch',
        value: widget.source.arch,
      ),
      _InfoRow(
        label: isZh ? '下载地址' : 'URL',
        value: widget.source.downloadUrl,
        isPath: true,
      ),
      _InfoRow(
        label: isZh ? '文件名' : 'Filename',
        value: _fileName.isEmpty ? '...' : _fileName,
      ),
      _InfoRow(
        label: isZh ? '保存到' : 'Save to',
        value: _saveDir.isEmpty ? '...' : _saveDir,
        isPath: true,
      ),
    ];
    if (widget.source.sha256 != null) {
      rows.add(_InfoRow(
        label: 'SHA256',
        value: widget.source.sha256!,
        isHash: true,
      ));
    }
    return rows;
  }
}

/// 信任徽章（v1.7.18 需求3）—— 🟢官方 / 🟡可信第三方 / 🔴未知来源 三态。
/// 抽自 DownloadConfirmDialog.build 的内联 Container+record，降低 build CC。
class TrustBadge extends StatelessWidget {
  final SourceTrustLevel level;
  final bool isZh;

  const TrustBadge({
    super.key,
    required this.level,
    required this.isZh,
  });

  ({String label, Color color, Color bg}) _resolve(ColorScheme cs) {
    return switch (level) {
      SourceTrustLevel.official => (
          label: isZh ? '🟢 官方' : '🟢 Official',
          color: cs.appTextSub,
          bg: cs.appPanelLight,
        ),
      SourceTrustLevel.trustedThirdParty => (
          label: isZh ? '🟡 可信第三方' : '🟡 Trusted 3rd-party',
          color: cs.appTextSub,
          bg: cs.appPanel,
        ),
      SourceTrustLevel.unknown => (
          label: isZh ? '🔴 未知来源' : '🔴 Unknown',
          color: cs.error,
          bg: cs.errorContainer.withValues(alpha: 0.18),
        ),
    };
  }

  IconData _icon() {
    return switch (level) {
      SourceTrustLevel.official => Icons.verified_user_rounded,
      SourceTrustLevel.trustedThirdParty => Icons.shield_outlined,
      SourceTrustLevel.unknown => Icons.warning_amber_rounded,
    };
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final b = _resolve(cs);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: b.bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: b.color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(_icon(), size: 16, color: b.color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(b.label,
                style: TextStyle(
                    fontSize: 12.5,
                    color: b.color,
                    fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final bool isPath;
  final bool isHash;

  const _InfoRow({
    required this.label,
    required this.value,
    this.isPath = false,
    this.isHash = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      // L6：标签列宽度跟着弹窗宽度走。原先是钉死的 SizedBox(width: 88) ——
      // 与窗宽、字号都无关：横屏弹窗宽到 560 时标签列仍只占 88，
      // 1.5 倍字号下 "Filename" 被裁成 "Fi…"，右侧的值失去主语，
      // 而这一行正是"要不要允许这个来源"要读的那一行；同时值列白得一堆空位。
      // 取行宽的 34% 给标签、其余给值：宽窗下标签够长，窄窗（竖屏）下
      // 也不会反过来挤掉值列（URL/路径才是主角），两档都保持 值列 > 标签列。
      child: LayoutBuilder(
        builder: (context, constraints) {
          final double rowWidth = constraints.maxWidth;
          final double labelWidth = rowWidth.isFinite ? rowWidth * 0.34 : 88.0;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: labelWidth,
                child: Text(label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        )),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  value,
                  maxLines: isPath || isHash ? 3 : 2,
                  overflow: TextOverflow.ellipsis,
                  softWrap: true,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: colorScheme.onSurface,
                    fontFamily: isPath || isHash ? 'monospace' : null,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
