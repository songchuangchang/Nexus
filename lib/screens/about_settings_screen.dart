// v1.7.25：从「通用设置」拆出信息类（关于/API配置/存储/支持服务商/GitHub仓库）
// 目的：通用设置页只留真正"通用"的开关与滑块；信息类归入「关于」页，
//       消除用户反馈的"通用设置里混了一堆信息，离谱"的问题。
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../services/repo_endpoints.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:io';

import '../constants.dart' show kAppVersionConst;
import '../l10n/app_localizations.dart';
import '../services/biometric_service.dart';
import '../ui/tokens.dart';
import 'api_config_screen.dart';

class AboutSettingsScreen extends StatelessWidget {
  const AboutSettingsScreen({super.key});

  static String get _appVersionFull => kAppVersionConst;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final zh = l.locale.languageCode == 'zh';
    return Scaffold(
      appBar: AppBar(title: Text(zh ? '关于' : 'About')),
      // v1.7.25：设置页固定缩放，避免全局字体缩放挤压布局
      body: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.2,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Container(
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
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, color: colorScheme.appTextSub),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(zh ? '关于 Nexus' : 'About Nexus',
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold, fontSize: 15)),
                            const SizedBox(height: 2),
                            Text(
                              'Version $_appVersionFull',
                              style: TextStyle(
                                fontSize: 12,
                                color: colorScheme.onSurfaceVariant,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: const Icon(Icons.info_outline),
                  title: Text(l.tr('about')),
                  subtitle: Text(l.tr('aboutSubtitle'),
                      style: const TextStyle(fontSize: 12)),
                  onTap: () {
                    showAboutDialog(
                      context: context,
                      applicationName: 'Nexus',
                      applicationVersion: _appVersionFull,
                      applicationIcon: const FlutterLogo(),
                      applicationLegalese: '© 2026 Nexus',
                    );
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: const Icon(Icons.cloud_outlined),
                  title: Text(l.tr('apiConfigs')),
                  subtitle: Text(l.tr('apiConfigsSubtitle'),
                      style: const TextStyle(fontSize: 12)),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const ApiConfigScreen()),
                  ),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: const Icon(Icons.storage),
                  title: Text(l.tr('storage')),
                  subtitle: Text(l.tr('storageSubtitle'),
                      style: const TextStyle(fontSize: 12)),
                  // build98（P2）：补上缺失的 onTap（此前点了没反应）
                  onTap: () => _showStorageInfoDialog(context, zh),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: const Icon(Icons.code),
                  title: Text(l.tr('supportedApis')),
                  subtitle: Text(l.tr('supportedApisSubtitle'),
                      style: const TextStyle(fontSize: 12)),
                  onTap: () => _showSupportedApisDialog(context, l, zh),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: const Icon(Icons.hub_outlined),
                  title: Text(zh ? 'GitHub 仓库' : 'GitHub Repository'),
                  subtitle: const Text(kRepoDisplayUrl,
                      style: TextStyle(fontSize: 12)),
                  onTap: () async {
                    final uri = Uri.parse(kRepoHtmlUrl);
                    if (await canLaunchUrl(uri)) {
                      await BiometricService.guardActivityTransition(
                        () => launchUrl(uri,
                            mode: LaunchMode.externalApplication),
                        fallbackDuration: const Duration(seconds: 120),
                      );
                    }
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: const Icon(Icons.balance),
                  title: Text(zh ? '第三方许可' : 'Third-party Licenses'),
                  subtitle: Text(
                      zh ? '开源与授权声明' : 'Open-source & license notice',
                      style: const TextStyle(fontSize: 12)),
                  onTap: () => _showThirdPartyLicensesDialog(context, zh),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// build98（P2）：存储信息弹窗（DB 路径/大小/缓存目录大小）
  Future<void> _showStorageInfoDialog(BuildContext context, bool zh) async {
    String fmt(int bytes) {
      if (bytes < 1024) return '$bytes B';
      if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
      return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
    }

    Future<int> dirSize(Directory dir) async {
      var total = 0;
      try {
        await for (final e in dir.list(recursive: true, followLinks: false)) {
          if (e is File) total += await e.length();
        }
      } catch (e) {
        // 遍历中断就返回已统计部分
        debugPrint('catch 静默异常: $e');
      }
      return total;
    }

    String dbInfo = zh ? '统计中…' : 'Calculating…';
    String cacheInfo = dbInfo;
    String docsInfo = dbInfo;
    try {
      final dbDir = await getDatabasesPath();
      final dbFile = File(p.join(dbDir, 'aichat.db'));
      dbInfo = await dbFile.exists()
          ? '${fmt(await dbFile.length())}\n${dbFile.path}'
          : (zh ? '数据库尚未创建' : 'Database not created yet');
    } catch (e) {
      dbInfo = '$e';
    }
    try {
      final cacheDir = await getApplicationCacheDirectory();
      cacheInfo = '${fmt(await dirSize(cacheDir))}\n${cacheDir.path}';
    } catch (e) {
      cacheInfo = '$e';
    }
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      docsInfo = '${fmt(await dirSize(docsDir))}\n${docsDir.path}';
    } catch (e) {
      docsInfo = '$e';
    }
    if (!context.mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(zh ? '存储占用' : 'Storage Usage'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(zh ? '数据库' : 'Database',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              SelectableText(dbInfo, style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 10),
              Text(zh ? '缓存目录' : 'Cache',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              SelectableText(cacheInfo, style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 10),
              Text(zh ? '文档目录' : 'Documents',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              SelectableText(docsInfo, style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(zh ? '知道了' : 'OK'),
          ),
        ],
      ),
    );
  }

  void _showThirdPartyLicensesDialog(BuildContext context, bool zh) {
    final text = zh
        ? '''• Flutter / Flutter SDK / Sky Engine：Apache-2.0\n• archive 4.2.0：MIT，并保留 zlib.js、JZLib、bzip2、pointycastle 的上游归属\n• flutter_slidable 4.0.3：MIT\n• syncfusion_flutter_pdf 34.2.5：Syncfusion 许可\n• google_mlkit_text_recognition 0.16.0（含 com.google.mlkit:text-recognition-chinese 16.0.1 原生库）：Apache-2.0，本机 OCR 识别图片文字\n\n完整清单见仓库 docs/THIRD_PARTY_LICENSES.md。'''
        : '''• Flutter / Flutter SDK / Sky Engine: Apache-2.0\n• archive 4.2.0: MIT, with upstream attribution for zlib.js, JZLib, bzip2, and pointycastle\n• flutter_slidable 4.0.3: MIT\n• syncfusion_flutter_pdf 34.2.5: Syncfusion license\n• google_mlkit_text_recognition 0.16.0 (incl. native com.google.mlkit:text-recognition-chinese 16.0.1): Apache-2.0, on-device OCR for image text\n\nFull details are in docs/THIRD_PARTY_LICENSES.md.''';
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(zh ? '第三方许可' : 'Third-party Licenses'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              SelectableText(
                text,
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(zh ? '知道了' : 'OK'),
          ),
        ],
      ),
    );
  }

  void _showSupportedApisDialog(
      BuildContext context, AppLocalizations l, bool zh) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.tr('supportedApiProviders')),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('• OpenAI: api.openai.com'),
              const Text('• DeepSeek: api.deepseek.com'),
              const Text('• Kimi: api.moonshot.cn'),
              const Text('• Qwen: dashscope.aliyuncs.com'),
              const Text('• Local Ollama: localhost:11434'),
              Text('\n${l.tr('supportedApisSubtitle')}'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(zh ? '知道了' : 'OK'),
          ),
        ],
      ),
    );
  }
}
