// v1.7.15 第二轮拆分：原 settings_screen.dart 的"日志与调试" Section +
// _exportLogs（L33-L71）+ _clearLogs（L73-L94）+ _toggleVerboseLogging（L264-L315）
//
// 目的：把 verboseLogging 的 SwitchListTile 从主列表迁出，避免开关切换时
// 主 ListView 高度突变（白窗口根因）。同时把日志查看/导出/清空一并搬到本页，
// 主 settings 只剩导航 ListTile，行数从 1077 → <500。
//
// 数据流：本页持有自己的 _searchCfg（只关心 verboseLogging 字段），
// 通过 Provider<StorageService> 直接读写 web_search_configs 表。

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_localizations.dart';
import '../services/biometric_service.dart';
import '../models/web_search_config.dart';
import '../services/file_open_service.dart';
import '../services/logger_service.dart';
import '../services/storage_service.dart';
import '../ui/tokens.dart';
import 'log_viewer_screen.dart';
import '../utils/app_snackbar.dart';

class LogsDebugSettingsScreen extends StatefulWidget {
  const LogsDebugSettingsScreen({super.key});

  @override
  State<LogsDebugSettingsScreen> createState() =>
      _LogsDebugSettingsScreenState();
}

class _LogsDebugSettingsScreenState extends State<LogsDebugSettingsScreen> {
  bool _exporting = false;
  WebSearchConfig? _searchCfg;
  bool _logThinking = false;
  // build104（M2c）：允许 AI 读取日志（log_query 工具的隐私总开关，默认关）
  bool _aiLogRead = false;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final storage = context.read<StorageService>();
    final cfg = await storage.getWebSearchConfig();
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _searchCfg = cfg;
      _logThinking = prefs.getBool('log_thinking_process') ?? false;
      _aiLogRead = prefs.getBool('aiLogReadEnabled') ?? false;
    });
  }

  Future<void> _saveConfig(WebSearchConfig cfg) async {
    setState(() => _searchCfg = cfg);
    await context.read<StorageService>().saveWebSearchConfig(cfg);
  }

  Future<void> _exportLogs() async {
    final l = AppLocalizations.of(context);
    final logger = context.read<LoggerService>();
    setState(() => _exporting = true);
    try {
      final path = await logger.exportToSingleFile();
      if (mounted) {
        AppSnackBar.showSnackBar(context, 
          SnackBar(
            content: Text('${l.tr('logExportedTo')}:\n$path'),
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: l.tr('open'),
              onPressed: () async {
                try {
                  await BiometricService.guardActivityTransition(
                    () => FileOpenService.open(path),
                    fallbackDuration: const Duration(seconds: 120),
                  );
                } catch (e) {
                  if (mounted) {
                    AppSnackBar.showSnackBar(context, 
                      SnackBar(content: Text('${l.tr('openFailed')}: $e')),
                    );
                  }
                }
              },
            ),
          ),
        );
      }
    } catch (e, st) {
      logger.error('Export logs failed', error: e, stack: st, tag: 'LoggerUI');
      if (mounted) {
        AppSnackBar.showSnackBar(context, 
          SnackBar(content: Text('${l.tr('exportFailed')}: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _clearLogs() async {
    final l = AppLocalizations.of(context);
    final logger = context.read<LoggerService>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.tr('clearLogs')),
        content: Text(l.tr('clearLogsConfirm')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l.tr('cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l.tr('clear'))),
        ],
      ),
    );
    if (confirmed != true) return;
    await logger.clearAll();
    if (mounted) {
      AppSnackBar.showSnackBar(context, 
        SnackBar(content: Text(l.tr('logsCleared'))),
      );
    }
  }

  /// v1.3.4：切换详细日志模式
  /// 开启时弹隐私警告对话框（聊天内容/搜索结果会被记录），确认后才真正开启
  /// 关闭时直接关。API Key 明文永远不记（由调用方 mask）
  Future<void> _toggleVerboseLogging(bool value) async {
    final l = AppLocalizations.of(context);
    final logger = context.read<LoggerService>();
    final cfg = _searchCfg;
    if (cfg == null) return;
    if (!value) {
      // 关闭：直接关，无需警告
      final newCfg = cfg.copyWith(verboseLogging: false);
      await _saveConfig(newCfg);
      logger.verboseEnabled = false;
      // build97 (P1-5 修复)：单向联动——开思考会自动开详细日志，
      // 关详细日志时必须一起关掉「记录思考过程」，否则开关显示开着但一个字节都不写，
      // 用户误以为在记录。
      final prefs = await SharedPreferences.getInstance();
      final wasLogThinking = prefs.getBool('log_thinking_process') ?? false;
      if (wasLogThinking) {
        await prefs.setBool('log_thinking_process', false);
        if (mounted) setState(() => _logThinking = false);
      }
      if (mounted && wasLogThinking) {
        AppSnackBar.showSnackBar(context, 
          SnackBar(
            content: Text(l.locale.languageCode == 'zh'
                ? '详细日志已关闭，「记录 AI 思考过程」已一并关闭'
                : 'Verbose logging off; "Log AI thinking" was also turned off'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
      return;
    }
    // 开启：先弹隐私警告
    final zh = l.locale.languageCode == 'zh';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          Icon(Icons.warning_amber_rounded,
              color: Theme.of(context).colorScheme.tertiary),
          const SizedBox(width: 8),
          Text(zh ? '开启详细日志？' : 'Enable verbose logging?'),
        ]),
        content: Text(zh
            ? '开启后将记录以下敏感信息到日志文件，仅用于调试找问题：\n\n'
                '• 聊天消息全文\n'
                '• AI 思考步骤详情\n'
                '• 联网搜索结果全文\n'
                '• 下载 URL 详情\n\n'
                '⚠️ API Key 明文不会被记录。\n\n'
                '请勿在公共场合导出/分享日志，可能包含你的对话内容。\n确认开启？'
            : 'The following sensitive info will be written to log files, for debugging only:\n\n'
                '• Full chat messages\n'
                '• AI reasoning step details\n'
                '• Full web search results\n'
                '• Download URL details\n\n'
                '⚠️ API keys are never logged in plain text.\n\n'
                'Do not export/share logs in public - they may contain your conversations.\nConfirm?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l.tr('cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(zh ? '确认开启' : 'Enable')),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    final newCfg = cfg.copyWith(verboseLogging: true);
    await _saveConfig(newCfg);
    logger.verboseEnabled = true;
  }

  /// v1.7.31：记录 AI 思考过程开关
  /// 开启时自动开启 verbose 日志（确保能写入文件），并弹隐私提示
  Future<void> _toggleLogThinking(bool value) async {
    final l = AppLocalizations.of(context);
    final logger = context.read<LoggerService>();
    final zh = l.locale.languageCode == 'zh';
    final themeData = Theme.of(context);
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;

    if (value) {
      // 开启：弹隐私提示
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Row(children: [
            Icon(Icons.psychology, color: themeData.colorScheme.tertiary),
            const SizedBox(width: 8),
            Text(zh ? '记录 AI 思考过程？' : 'Log AI thinking?'),
          ]),
          content: Text(zh
              ? '开启后，AI 每轮的 <thinking> 思考内容将被完整写入日志文件。\n\n'
                  '⚠️ 可能包含 AI 的内部推理，请勿在公共场合导出/分享。\n\n'
                  '此功能会自动开启详细日志。确认开启？'
              : 'When enabled, AI\'s <thinking> content will be fully written to log files.\n\n'
                  '⚠️ May contain AI internal reasoning. Do not export/share in public.\n\n'
                  'This will also enable verbose logging. Confirm?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(l.tr('cancel'))),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(zh ? '确认开启' : 'Enable')),
          ],
        ),
      );
      if (confirmed != true) return;

      await prefs.setBool('log_thinking_process', true);
      // 自动开启 verbose
      final cfg = _searchCfg;
      if (cfg != null && !cfg.verboseLogging) {
        await _saveConfig(cfg.copyWith(verboseLogging: true));
      }
      logger.verboseEnabled = true;
    } else {
      await prefs.setBool('log_thinking_process', false);
    }

    if (!mounted) return;
    setState(() => _logThinking = value);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final zh = l.locale.languageCode == 'zh';
    final verbose = _searchCfg?.verboseLogging ?? false;
    return Scaffold(
      appBar: AppBar(title: Text(zh ? '日志与调试' : 'Logs & Debug')),
      body: SingleChildScrollView(
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
                    Icon(Icons.article_outlined, color: colorScheme.appTextSub),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(zh ? '日志与调试' : 'Logs & Debug',
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 15)),
                          const SizedBox(height: 2),
                          Text(
                            zh
                                ? '查看/导出日志，开启详细调试模式'
                                : 'View/export logs and enable verbose debug mode',
                            style: TextStyle(
                                fontSize: 12,
                                color: colorScheme.onSurfaceVariant),
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
                leading: const Icon(Icons.list_alt_outlined),
                title: Text(l.tr('viewLogs')),
                subtitle: Text(l.tr('viewLogsSubtitle'),
                    style: const TextStyle(fontSize: 12)),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const LogViewerScreen()),
                  );
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: _exporting
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.file_upload_outlined),
                title: Text(l.tr('exportLogs')),
                subtitle: Text(l.tr('exportLogsSubtitle'),
                    style: const TextStyle(fontSize: 12)),
                onTap: _exporting ? null : _exportLogs,
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: const Icon(Icons.delete_sweep_outlined),
                title: Text(l.tr('clearLogs')),
                subtitle: Text(l.tr('clearLogsSubtitle'),
                    style: const TextStyle(fontSize: 12)),
                onTap: _clearLogs,
              ),
              const SizedBox(height: 4),
              // v1.3.4：详细日志开关（已迁到本页，避免主列表高度突变）
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(zh ? '详细日志（调试用）' : 'Verbose logging (debug)'),
                subtitle: Text(
                  zh
                      ? '开启后记录聊天内容/搜索结果全文（API Key 不记）。仅用于找问题，请勿随意导出/分享'
                      : 'Logs full chat/search content (never API keys). Debugging only - do not export/share',
                  style: const TextStyle(fontSize: 12),
                ),
                value: verbose,
                onChanged: _toggleVerboseLogging,
                secondary: verbose
                    ? Icon(Icons.bug_report_outlined,
                        color: colorScheme.tertiary)
                    : Icon(Icons.bug_report_outlined,
                        color: colorScheme.onSurfaceVariant),
              ),
              // v1.7.31：记录 AI 思考过程开关
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(zh ? '记录 AI 思考过程' : 'Log AI thinking process'),
                subtitle: Text(
                  zh
                      ? '开启后 AI 每轮 <thinking> 内容将完整写入日志。会自动开启详细日志。'
                      : 'AI <thinking> content will be fully logged. Auto-enables verbose logging.',
                  style: const TextStyle(fontSize: 12),
                ),
                value: _logThinking,
                onChanged: _toggleLogThinking,
                secondary: _logThinking
                    ? Icon(Icons.psychology, color: colorScheme.tertiary)
                    : Icon(Icons.psychology_outlined,
                        color: colorScheme.onSurfaceVariant),
              ),
              // build104（M2c）：允许 AI 读取日志（log_query 工具的隐私总开关）
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(zh ? '允许 AI 读取日志' : 'Allow AI to read logs'),
                subtitle: Text(
                  zh
                      ? '开启后对话里说"看看日志"，AI 会查询运行日志辅助排障。逐次需你确认，自动剔除聊天内容，默认关。'
                      : 'Let the in-chat AI query log excerpts for troubleshooting. Confirmed per read; chat content excluded. Off by default.',
                  style: const TextStyle(fontSize: 12),
                ),
                value: _aiLogRead,
                onChanged: (v) async {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setBool('aiLogReadEnabled', v);
                  if (!mounted) return;
                  setState(() => _aiLogRead = v);
                },
                secondary: _aiLogRead
                    ? Icon(Icons.manage_search, color: colorScheme.tertiary)
                    : Icon(Icons.manage_search,
                        color: colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
