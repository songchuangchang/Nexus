// v1.7.15 第二轮拆分：原 settings_screen.dart 的"自检与 QA 工具" Section +
// _runSelfCheck（L97-L259）+ _aiBehaviorTestEnabled 字段 + manual items dialog
//
// 目的：把 AI 行为测试的 SwitchListTile 从主列表迁出，避免开关切换时
// 主 ListView 高度突变（白窗口根因）。同时把自检逻辑一并搬到本页。

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../plugins/plugin_registry.dart';
import '../services/self_check_service.dart';
import '../ui/tokens.dart';
import 'regression_test_screen.dart';

class QaSettingsScreen extends StatefulWidget {
  const QaSettingsScreen({super.key});

  @override
  State<QaSettingsScreen> createState() => _QaSettingsScreenState();
}

class _QaSettingsScreenState extends State<QaSettingsScreen> {
  bool _selfChecking = false;

  /// v1.4.2 新增：一键自检，把「手动测试 checklist」可自动化部分内置化
  Future<void> _runSelfCheck() async {
    if (_selfChecking) return;
    setState(() => _selfChecking = true);
    // v1.4.6：对话测试已合并到「AI 行为测试」开关的 RegressionTestScreen，
    // 自检不再跑消耗 token 的真实对话测试，只做离线 + 网络连通检查
    final zh = AppLocalizations.of(context).locale.languageCode == 'zh';
    final results = await SelfCheckService.runAll(
        runDialogTest: false,
        isZh: zh,
        pluginRegistry: context.read<PluginRegistry>());
    if (!mounted) return;
    setState(() => _selfChecking = false);

    final manualItems = SelfCheckService.manualCheckItems(isZh: zh);
    final passCount = results.where((r) => r.pass).length;
    final allPass = passCount == results.length;
    final colorScheme = Theme.of(context).colorScheme;
    final manualResults = List<bool?>.filled(manualItems.length, null);

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          final doneCount = manualResults.where((r) => r != null).length;
          final okCount = manualResults.where((r) => r == true).length;
          return AlertDialog(
            title: Row(children: [
              Icon(
                allPass ? Icons.check_circle : Icons.warning_amber_rounded,
                color: allPass ? colorScheme.primary : colorScheme.tertiary,
              ),
              const SizedBox(width: 8),
              Text(zh
                  ? '自检结果：$passCount/${results.length} 通过'
                  : 'Self-check: $passCount/${results.length} passed'),
            ]),
            content: SizedBox(
              width: double.maxFinite,
              child: ListView(
                shrinkWrap: true,
                children: [
                  // ===== 自动检查结果 =====
                  for (final r in results)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            r.pass ? Icons.check_circle : Icons.cancel,
                            color: r.pass
                                ? colorScheme.primary
                                : colorScheme.error,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(r.name,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600)),
                                if (r.detail.isNotEmpty)
                                  Text(r.detail,
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: colorScheme.onSurfaceVariant)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  const Divider(),
                  // ===== 人工确认项 =====
                  Text(
                      zh
                          ? '人工确认（$doneCount/${manualItems.length} 已确认，$okCount 正常）'
                          : 'Manual checks ($doneCount/${manualItems.length} done, $okCount OK)',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  for (int i = 0; i < manualItems.length; i++)
                    Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: colorScheme.appPanelLight,
                        borderRadius: BorderRadius.circular(AppRadius.panel),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(manualItems[i].title,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600)),
                              ),
                              if (manualResults[i] != null)
                                Icon(
                                  manualResults[i] == true
                                      ? Icons.check_circle
                                      : Icons.cancel,
                                  color: manualResults[i] == true
                                      ? colorScheme.primary
                                      : colorScheme.error,
                                  size: 18,
                                ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(manualItems[i].description,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: colorScheme.onSurfaceVariant)),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              OutlinedButton(
                                onPressed: () => setDialogState(
                                    () => manualResults[i] = true),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: colorScheme.primary,
                                  minimumSize: const Size(0, 32),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12),
                                ),
                                child: Text(zh ? '正常' : 'OK',
                                    style: const TextStyle(fontSize: 12)),
                              ),
                              const SizedBox(width: 8),
                              OutlinedButton(
                                onPressed: () => setDialogState(
                                    () => manualResults[i] = false),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: colorScheme.error,
                                  minimumSize: const Size(0, 32),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12),
                                ),
                                child: Text(zh ? '异常' : 'Issue',
                                    style: const TextStyle(fontSize: 12)),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(zh ? '关闭' : 'Close')),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final zh = l.locale.languageCode == 'zh';
    return Scaffold(
      appBar: AppBar(title: Text(zh ? '自检与 QA 工具' : 'Self-check & QA Tools')),
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
                    Icon(Icons.fact_check_outlined,
                        color: colorScheme.appTextSub),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(zh ? '自检与 QA 工具' : 'Self-check & QA Tools',
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 15)),
                          const SizedBox(height: 2),
                          Text(
                            zh
                                ? '运行一键自检或 AI 行为回归测试'
                                : 'Run self-check or AI behavior regression tests',
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
                leading: _selfChecking
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.verified_user_outlined),
                title: Text(zh ? '运行自检' : 'Run Self-Check'),
                subtitle: Text(
                  zh
                      ? '检查数据库结构、日志脱敏等基础功能'
                      : 'Check DB schema, log scrubbing and other basics',
                  style: const TextStyle(fontSize: 12),
                ),
                onTap: _selfChecking ? null : _runSelfCheck,
              ),
              const SizedBox(height: 4),
              // v1.7.36：移除「AI 行为测试」开关，入口改为常显 ListTile（UI 冗余清理）
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: const Icon(Icons.science_outlined),
                  title: Text(zh
                      ? 'AI 行为测试页（消耗 token）'
                      : 'AI Behavior Test Page (consumes tokens)'),
                  subtitle: Text(
                    zh
                        ? '将发送 4 条真实消息验证 AI 行为，建议仅在回归验证时使用'
                        : 'Sends 4 real messages to verify AI behavior; for regression use only',
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const RegressionTestScreen(),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
