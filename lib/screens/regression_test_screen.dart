import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/regression_test_service.dart';
import '../ui/tokens.dart';
import '../utils/app_snackbar.dart';

/// AI 回归测试页（v1.4.4 新增）
///
/// 与设置页"运行自检"互补：
///   - 自检：检查 App 自身基础设施（DB / 日志 / API 连通性等）
///   - 回归测试：发送固定输入，验证 AI 模型行为是否符合预期
///
/// 三个用例 + 自动判定 + 人工二次确认：
///   1. 反问对话框检测（关键词触发 → AI 输出 <ask_user>）
///   2. TXT 附件内容识别（"12345678"）
///   3. 图片附件内容识别（Canvas 绘"12345678"）
class RegressionTestScreen extends StatefulWidget {
  const RegressionTestScreen({super.key});

  @override
  State<RegressionTestScreen> createState() => _RegressionTestScreenState();
}

class _RegressionTestScreenState extends State<RegressionTestScreen> {
  bool _running = false;
  final List<RegressionTestResult> _results = [];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    // build97 (P1-6)：跳过项不计入自动通过数
    final autoPassed =
        _results.where((r) => !r.skipped && r.autoPassed).length;
    final skippedCount = _results.where((r) => r.skipped).length;
    final userConfirmed = _results.where((r) => r.userVerdict == true).length;
    final userMarkedAbnormal =
        _results.where((r) => r.userVerdict == false).length;

    return Scaffold(
      appBar: AppBar(title: Text(isZh ? 'AI 回归测试' : 'AI Regression Test')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ===== 顶部说明卡 =====
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: cs.appPanelLight,
              borderRadius: BorderRadius.circular(AppRadius.card),
              border: Border.all(color: cs.appBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(Icons.science_outlined, color: cs.appTextSub, size: 22),
                  const SizedBox(width: 8),
                  Text(isZh ? '说明' : 'Notes',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, color: cs.appTextSub)),
                ]),
                const SizedBox(height: 6),
                Text(
                  isZh
                      ? '本页发送固定输入到当前 API 配置，验证 AI 模型行为是否符合预期。\n'
                          '• 自动判定通过后，仍可在结果卡片上点「正确」二次确认或「异常」覆盖\n'
                          '• 所有用例都会消耗 token，建议仅在需要回归测试时点击运行'
                      : 'Sends fixed inputs to the current API config to verify AI model behavior.\n'
                          '• After auto-pass you can still tap "Correct"/"Wrong" on each card to confirm or override\n'
                          '• Every case consumes tokens - run only when regression testing is needed',
                  style: TextStyle(fontSize: 13, color: cs.appTextSub),
                ),
                const SizedBox(height: 8),
                if (_results.isEmpty)
                  Text(
                      isZh
                          ? '触发反问的关键词：${RegressionTestService.kRebuttalTriggers.join(" / ")}'
                          : 'Ask-back trigger keywords: ${RegressionTestService.kRebuttalTriggers.join(" / ")}',
                      style: TextStyle(
                          fontSize: 12,
                          color: cs.appTextFaint,
                          fontStyle: FontStyle.italic)),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // ===== 运行按钮 =====
          FilledButton.icon(
            onPressed: _running ? null : _runAll,
            icon: _running
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: cs.onPrimary))
                : const Icon(Icons.play_arrow),
            label: Text(_running
                ? (isZh ? '测试中…' : 'Testing...')
                : (isZh ? '运行所有测试' : 'Run all tests')),
          ),
          if (_results.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              isZh
                  ? '自动判定：$autoPassed/${_results.length} 通过 ｜ '
                      '跳过：$skippedCount ｜ '
                      '用户确认正确：$userConfirmed ｜ 用户标记异常：$userMarkedAbnormal'
                  : 'Auto: $autoPassed/${_results.length} passed | '
                      'skipped: $skippedCount | '
                      'user-confirmed correct: $userConfirmed | user-marked wrong: $userMarkedAbnormal',
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 16),

          // ===== 结果列表 =====
          for (final r in _results)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _ResultCard(
                result: r,
                onVerdict: (verdict) => setState(() => r.userVerdict = verdict),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _runAll() async {
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    setState(() {
      _running = true;
      _results.clear();
    });
    try {
      final results = await RegressionTestService.runAll(isZh: isZh);
      if (!mounted) return;
      setState(() {
        _results
          ..clear()
          ..addAll(results);
        _running = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _running = false);
      if (mounted) {
        AppSnackBar.showSnackBar(context, 
          SnackBar(content: Text(isZh ? '测试异常：$e' : 'Test error: $e')),
        );
      }
    }
  }
}

/// 单个测试结果卡片
///
/// 显示：标题 + 描述 + 自动判定徽章 + 详情 + AI 原始回复（折叠）+ 人工确认按钮
class _ResultCard extends StatelessWidget {
  final RegressionTestResult result;
  final void Function(bool? verdict) onVerdict; // true=正确, false=异常, null=取消

  const _ResultCard({required this.result, required this.onVerdict});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    final autoColor = result.skipped
        ? cs.onSurfaceVariant
        : (result.autoPassed ? cs.primary : cs.error);
    final verdictColor = result.userVerdict == null
        ? null
        : (result.userVerdict == true ? cs.primary : cs.error);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题 + 徽章
            Row(children: [
              Expanded(
                child: Text(result.name,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold)),
              ),
              // 自动判定徽章
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: autoColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: autoColor.withValues(alpha: 0.5)),
                ),
                child: Text(
                  result.skipped
                      ? (isZh ? '跳过' : 'SKIPPED')
                      : result.autoPassed
                          ? (isZh ? '自动通过' : 'AUTO PASS')
                          : (isZh ? '自动失败' : 'AUTO FAIL'),
                  style: TextStyle(
                      fontSize: 11,
                      color: autoColor,
                      fontWeight: FontWeight.w600),
                ),
              ),
              // 人工确认徽章
              if (result.userVerdict != null) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: verdictColor!.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                    border:
                        Border.all(color: verdictColor.withValues(alpha: 0.5)),
                  ),
                  child: Text(
                    result.userVerdict == true
                        ? (isZh ? '用户：正确' : 'USER: OK')
                        : (isZh ? '用户：异常' : 'USER: WRONG'),
                    style: TextStyle(
                        fontSize: 11,
                        color: verdictColor,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ]),
            const SizedBox(height: 4),
            Text(result.description,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            const SizedBox(height: 8),
            // 详情
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(result.detail, style: const TextStyle(fontSize: 13)),
            ),

            // AI 原始回复（折叠）
            if (result.rawResponse.isNotEmpty) ...[
              const SizedBox(height: 8),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(
                    isZh
                        ? 'AI 原始回复（${result.rawResponse.length} 字符）'
                        : 'AI raw reply (${result.rawResponse.length} chars)',
                    style: const TextStyle(fontSize: 13)),
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    constraints: const BoxConstraints(maxHeight: 240),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        result.rawResponse,
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 12),
                      ),
                    ),
                  ),
                ],
              ),
            ],

            // 人工确认按钮
            const SizedBox(height: 8),
            Row(children: [
              OutlinedButton.icon(
                onPressed: () => onVerdict(true),
                style: OutlinedButton.styleFrom(
                  foregroundColor: cs.primary,
                  minimumSize: const Size(0, 36),
                ),
                icon: const Icon(Icons.check, size: 18),
                label: Text(isZh ? '正确' : 'Correct'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () => onVerdict(false),
                style: OutlinedButton.styleFrom(
                  foregroundColor: cs.error,
                  minimumSize: const Size(0, 36),
                ),
                icon: const Icon(Icons.close, size: 18),
                label: Text(isZh ? '异常' : 'Wrong'),
              ),
              if (result.userVerdict != null) ...[
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => onVerdict(null),
                  child: Text(isZh ? '清除' : 'Clear',
                      style: const TextStyle(fontSize: 12)),
                ),
              ],
            ]),
          ],
        ),
      ),
    );
  }
}
