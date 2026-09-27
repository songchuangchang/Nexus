import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../plugins/plugin_registry.dart';
import '../services/self_check_service.dart';

class QuickSelfCheckScreen extends StatefulWidget {
  const QuickSelfCheckScreen({super.key});

  @override
  State<QuickSelfCheckScreen> createState() => _QuickSelfCheckScreenState();
}

class _QuickSelfCheckScreenState extends State<QuickSelfCheckScreen> {
  bool _checking = false;
  List<SelfCheckResult> _results = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _runCheck());
  }

  Future<void> _runCheck() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _results = [];
    });
    final zh = AppLocalizations.of(context).locale.languageCode == 'zh';
    final results = await SelfCheckService.runAll(
      isZh: zh,
      runDialogTest: false,
      pluginRegistry: context.read<PluginRegistry>(),
    );
    if (mounted) {
      setState(() {
        _results = results;
        _checking = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final zh = l.locale.languageCode == 'zh';
    final cs = Theme.of(context).colorScheme;
    final passCount = _results.where((r) => r.pass).length;
    final allPass = passCount == _results.length && _results.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(zh ? '快速自检' : 'Quick Self-Check'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: zh ? '重新检测' : 'Re-run',
            onPressed: _checking ? null : _runCheck,
          ),
        ],
      ),
      body: _checking
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(
                    width: 48,
                    height: 48,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    zh ? '正在检测中…' : 'Checking…',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    zh
                        ? '检查 AI API / 联网 / 基础功能'
                        : 'Checking AI API / Web search / Basics',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            )
          : _results.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.search_off_rounded,
                          size: 48, color: cs.onSurfaceVariant),
                      const SizedBox(height: 12),
                      Text(
                        zh ? '尚未运行检测' : 'No check results yet',
                        style:
                            TextStyle(fontSize: 15, color: cs.onSurfaceVariant),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _runCheck,
                        icon: const Icon(Icons.play_arrow),
                        label: Text(zh ? '开始检测' : 'Start Check'),
                      ),
                    ],
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildSummary(zh, cs, passCount, allPass),
                      const SizedBox(height: 12),
                      ..._results.map((r) => _buildResultItem(r, zh, cs)),
                      const SizedBox(height: 16),
                      Center(
                        child: OutlinedButton.icon(
                          onPressed: _runCheck,
                          icon: const Icon(Icons.refresh, size: 18),
                          label: Text(zh ? '重新检测' : 'Re-run'),
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }

  Widget _buildSummary(bool zh, ColorScheme cs, int passCount, bool allPass) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: allPass
            ? cs.primary.withValues(alpha: 0.12)
            : cs.tertiary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: allPass
              ? cs.primary.withValues(alpha: 0.4)
              : cs.tertiary.withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        children: [
          Icon(
            allPass ? Icons.check_circle : Icons.warning_amber_rounded,
            color: allPass ? cs.primary : cs.tertiary,
            size: 32,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  allPass
                      ? (zh ? '全部通过' : 'All Passed')
                      : (zh
                          ? '${_results.length - passCount} 项未通过'
                          : '${_results.length - passCount} failed'),
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: allPass ? cs.primary : cs.tertiary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  zh
                      ? '$passCount / ${_results.length} 项通过'
                      : '$passCount / ${_results.length} passed',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultItem(SelfCheckResult result, bool zh, ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(
              result.pass ? Icons.check_circle_outline : Icons.error_outline,
              size: 20,
              color: result.pass ? cs.primary : cs.error,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    result.name,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    result.detail,
                    style: TextStyle(
                      fontSize: 11,
                      color: result.pass ? cs.onSurfaceVariant : cs.error,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
