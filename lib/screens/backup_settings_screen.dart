// v1.7.15：拆分自 settings_screen.dart 的 _buildBackupSection（原 L403-L461）+
// _onExportTap（原 L464-L567）+ _onImportTap（原 L570-L656）+ _ImportMode enum（原 L1838）
//
// 目的：把数据备份/导出/导入从主 SettingsScreen 拆到独立 sub-screen。
// 不依赖 _searchCfg（直接用 BackupService 操作）。

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../services/backup_service.dart';
import '../services/biometric_service.dart';
import '../services/file_open_service.dart';
import '../services/logger_service.dart';
import '../services/storage_service.dart';
import '../ui/tokens.dart';
import '../utils/app_snackbar.dart';

class BackupSettingsScreen extends StatefulWidget {
  const BackupSettingsScreen({super.key});

  @override
  State<BackupSettingsScreen> createState() => _BackupSettingsScreenState();
}

class _BackupSettingsScreenState extends State<BackupSettingsScreen> {
  // 自有 _exporting 状态字段（与主 SettingsScreen 的 _exporting 用于日志导出独立）
  bool _exporting = false;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final zh = l.locale.languageCode == 'zh';
    return Scaffold(
      appBar: AppBar(title: Text(zh ? '数据备份' : 'Data Backup')),
      body: ListView(
        padding: AppPad.page,
        children: [
          AppSectionCard(
            title: zh ? '数据备份' : 'Data Backup',
            children: [
              ListTile(
                dense: true,
                leading: _exporting
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.file_upload_outlined),
                title: Text(zh ? '导出数据' : 'Export Data'),
                subtitle: Text(
                  zh
                      ? '导出所有对话、API 配置、搜索设置为 JSON 文件'
                      : 'Export all conversations, API configs and settings to a JSON file',
                  style: const TextStyle(fontSize: 12),
                ),
                onTap: _exporting ? null : _onExportTap,
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.file_download_outlined),
                title: Text(zh ? '导入数据' : 'Import Data'),
                subtitle: Text(
                  zh
                      ? '从 JSON 文件导入数据（合并到现有或覆盖）'
                      : 'Import from JSON file (merge or overwrite)',
                  style: const TextStyle(fontSize: 12),
                ),
                onTap: _onImportTap,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 导出：弹窗问是否包含 API key → 选保存目录 → 写文件 → SnackBar 显示路径
  Future<void> _onExportTap() async {
    final l = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final zh = l.locale.languageCode == 'zh';

    bool includeKeys = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: Text(zh ? '导出选项' : 'Export Options'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(zh ? '将导出：' : 'Will export:',
                  style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 4),
              Text(zh
                  ? '• 所有 API 配置（endpoint / 模型 / 参数）\n'
                      '• 所有对话和消息（含附件元数据）\n'
                      '• 联网搜索 / ReAct 设置'
                  : '• All API configs (endpoint / model / params)\n'
                      '• All conversations & messages (with attachment metadata)\n'
                      '• Web search / ReAct settings'),
              const SizedBox(height: 12),
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: includeKeys,
                onChanged: (v) => setSt(() => includeKeys = v ?? false),
                title: Text(zh ? '包含 API Key 等敏感信息' : 'Include API keys'),
                subtitle: Text(
                  zh
                      ? '⚠️ 勾选后 apiKey / tavilyApiKey 会以明文写入 JSON 文件，'
                          '请妥善保管导出文件'
                      : '⚠️ apiKey / tavilyApiKey will be written in plaintext. '
                          'Keep the exported file safe',
                  style: TextStyle(
                    fontSize: 11,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                ),
                activeColor: cs.primary,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l.tr('cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(zh ? '导出' : 'Export'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;

    if (!mounted) return;
    setState(() => _exporting = true);

    try {
      final storage = context.read<StorageService>();
      final backup = BackupService(storage);
      final json = await backup.exportAll(includeKeys: includeKeys);

      // 选保存目录（file_picker 的 pickDirectory 在 Android 上是 SAF，返回的是 tree URI，
      // 不便写文件；改用 getDownloadsDirectory 自动落盘 + 弹路径给用户）
      final outPath = await backup.writeExportToFile(json);

      // 用系统打开（不直接打开文件，让用户知道位置）；
      // 桌面的降级在 FileOpenService 里（M2）：Windows 走 explorer.exe。
      if (mounted) {
        AppSnackBar.showSnackBar(context, 
          SnackBar(
            content: Text(zh ? '已导出到：$outPath' : 'Exported to: $outPath'),
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: zh ? '打开' : 'Open',
              onPressed: () async {
                try {
                  await BiometricService.guardActivityTransition(
                    () => FileOpenService.open(outPath),
                    fallbackDuration: const Duration(seconds: 120),
                  );
                } catch (e) { debugPrint('catch 静默异常: $e'); }
              },
            ),
          ),
        );
      }
    } catch (e, st) {
      LoggerService.instance.error('Export failed', error: e, stack: st);
      if (mounted) {
        AppSnackBar.showSnackBar(context, 
          SnackBar(
            content: Text(zh ? '导出失败：$e' : 'Export failed: $e'),
            backgroundColor: cs.errorContainer,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// 导入：选 JSON 文件 → 弹窗问合并/覆盖 → 执行 → SnackBar 显示统计
  Future<void> _onImportTap() async {
    final l = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final zh = l.locale.languageCode == 'zh';

    BiometricService.beginActivityTransition();
    FilePickerResult? picked;
    try {
      picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: false,
      );
    } finally {
      Future.delayed(const Duration(seconds: 2), () {
        BiometricService.endActivityTransition();
      });
    }
    if (picked == null || picked.files.isEmpty) return;
    final filePath = picked.files.first.path;
    if (filePath == null) {
      if (mounted) {
        AppSnackBar.showSnackBar(context, 
          SnackBar(content: Text(zh ? '无法获取文件路径' : 'Cannot get file path')),
        );
      }
      return;
    }

    // 弹窗：合并 / 覆盖 / 取消
    if (!mounted) return;
    final mode = await showDialog<_ImportMode>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(zh ? '导入策略' : 'Import Strategy'),
        content: Text(zh
            ? '合并：保留现有数据，追加导入的对话和 API（冲突时生成新 ID）\n\n覆盖：清空当前所有数据后导入'
            : 'Merge: keep existing data, append imported items (new IDs on conflict)\n\nOverwrite: clear all current data, then import'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: Text(l.tr('cancel')),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(ctx, _ImportMode.merge),
            child: Text(zh ? '合并' : 'Merge'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, _ImportMode.overwrite),
            style: FilledButton.styleFrom(
              backgroundColor: cs.errorContainer,
              foregroundColor: cs.onErrorContainer,
            ),
            child: Text(zh ? '覆盖' : 'Overwrite'),
          ),
        ],
      ),
    );
    if (mode == null) return;
    if (!mounted) return;

    try {
      final storage = context.read<StorageService>();
      final backup = BackupService(storage);
      final stats = await backup.importFromFile(
        filePath,
        merge: mode == _ImportMode.merge,
      );
      if (mounted) {
        AppSnackBar.showSnackBar(context, 
          SnackBar(
            content: Text(zh
                ? '✅ 导入完成（${mode == _ImportMode.merge ? "合并" : "覆盖"}模式）：'
                    '${stats.apiConfigs} 个 API / '
                    '${stats.conversations} 个对话 / '
                    '${stats.messages} 条消息'
                : '✅ Imported (${mode == _ImportMode.merge ? "merge" : "overwrite"}): '
                    '${stats.apiConfigs} APIs / '
                    '${stats.conversations} conversations / '
                    '${stats.messages} messages'),
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } catch (e, st) {
      LoggerService.instance.error('Import failed', error: e, stack: st);
      if (mounted) {
        AppSnackBar.showSnackBar(context, 
          SnackBar(
            content: Text(zh ? '导入失败：$e' : 'Import failed: $e'),
            backgroundColor: cs.errorContainer,
            duration: const Duration(seconds: 8),
          ),
        );
      }
    }
  }
}

/// v1.3.8：导入策略选项（BackupSettingsScreen _onImportTap 内部使用）
enum _ImportMode { merge, overwrite }
