import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../models/api_config.dart';
import '../services/api_service.dart';
import '../services/model_comparison_service.dart';
import '../services/storage_service.dart';
import '../utils/app_snackbar.dart';

/// build101（E5 多模型对比）：选 2~4 个模型，同一问题并排看回答。
///
/// 使用场景：
/// - 选型：同一个 prompt 在不同模型上的表现差异
/// - 验证：怀疑某模型答错时，交叉验证
/// - 比价：贵的模型是否真的明显更好
class ModelCompareScreen extends StatefulWidget {
  /// 可选的初始问题（从聊天页「用多模型对比」入口带过来）
  final String initialQuestion;

  const ModelCompareScreen({super.key, this.initialQuestion = ''});

  @override
  State<ModelCompareScreen> createState() => _ModelCompareScreenState();
}

class _ModelCompareScreenState extends State<ModelCompareScreen> {
  List<ApiConfig> _configs = const [];
  final Set<String> _selected = {};
  final TextEditingController _questionCtrl = TextEditingController();
  final TextEditingController _promptCtrl = TextEditingController();

  bool _loading = true;
  bool _running = false;
  List<ComparisonResult> _results = const [];

  @override
  void initState() {
    super.initState();
    _questionCtrl.text = widget.initialQuestion;
    _load();
  }

  @override
  void dispose() {
    _questionCtrl.dispose();
    _promptCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final storage = context.read<StorageService>();
    final list = await storage.getApiConfigs();
    if (!mounted) return;
    setState(() {
      _configs = list;
      // 默认勾选前两个（多数场景就是对比两个）
      _selected
        ..clear()
        ..addAll(list.take(2).map((c) => c.id));
      _loading = false;
    });
  }

  Future<void> _run() async {
    final l = AppLocalizations.of(context);
    final zh = l.locale.languageCode == 'zh';
    final q = _questionCtrl.text.trim();
    if (q.isEmpty) {
      _snack(zh ? '请输入问题' : 'Enter a question');
      return;
    }
    if (_selected.length < 2) {
      _snack(zh ? '至少选择 2 个模型' : 'Select at least 2 models');
      return;
    }
    if (_selected.length > 4) {
      _snack(zh ? '最多选择 4 个模型' : 'At most 4 models');
      return;
    }
    final targets =
        _configs.where((c) => _selected.contains(c.id)).toList();

    setState(() {
      _running = true;
      _results = const [];
    });
    final api = context.read<ApiService>();
    final results = await ModelComparisonService.compare(
      api: api,
      configs: targets,
      question: q,
      systemPrompt: _promptCtrl.text,
    );
    if (!mounted) return;
    setState(() {
      _running = false;
      _results = results;
    });
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final zh = l.locale.languageCode == 'zh';

    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(zh ? '多模型对比' : 'Compare Models')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_configs.length < 2) {
      return Scaffold(
        appBar: AppBar(title: Text(zh ? '多模型对比' : 'Compare Models')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              zh
                  ? '需要至少 2 个 API 配置才能对比。请先到「API 设置」添加。'
                  : 'Need at least 2 API configs. Add them in API settings.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(zh ? '多模型对比' : 'Compare Models')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _questionCtrl,
                  minLines: 2,
                  maxLines: 4,
                  decoration: InputDecoration(
                    labelText: zh ? '问题' : 'Question',
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(
                    zh ? '系统提示词（可选）' : 'System prompt (optional)',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  children: [
                    TextField(
                      controller: _promptCtrl,
                      minLines: 3,
                      maxLines: 6,
                      decoration: InputDecoration(
                        border: const OutlineInputBorder(),
                        hintText: zh
                            ? '留空则不注入系统提示词'
                            : 'Leave empty for no system prompt',
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  zh ? '选择模型（2~4 个）：' : 'Models (2-4):',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final c in _configs)
                      FilterChip(
                        label: Text(
                          '${c.name}${c.model.isNotEmpty ? ' · ${c.model}' : ''}',
                          style: const TextStyle(fontSize: 11),
                        ),
                        selected: _selected.contains(c.id),
                        onSelected: (v) => setState(() {
                          if (v) {
                            _selected.add(c.id);
                          } else {
                            _selected.remove(c.id);
                          }
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _running ? null : _run,
                    icon: _running
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.compare_arrows),
                    label: Text(_running
                        ? (zh ? '生成中…' : 'Generating…')
                        : (zh ? '开始对比' : 'Compare')),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _results.isEmpty
                ? Center(
                    child: Text(
                      _running
                          ? (zh
                              ? '正在等待 ${_selected.length} 个模型返回…'
                              : 'Waiting for ${_selected.length} models…')
                          : (zh
                              ? '输入问题后点「开始对比」'
                              : 'Enter a question and tap Compare'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  )
                : _resultsView(zh),
          ),
        ],
      ),
    );
  }

  Widget _resultsView(bool zh) {
    // 横向滚动并排卡片；每张卡固定宽度，窄屏下自动变成横向滑动
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final r in _results)
            SizedBox(
              width: 320,
              child: _resultCard(r, zh),
            ),
        ],
      ),
    );
  }

  Widget _resultCard(ComparisonResult r, bool zh) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(right: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        r.configName,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 13),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        r.model,
                        style: const TextStyle(fontSize: 11),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (r.ok)
                  IconButton(
                    icon: const Icon(Icons.copy_outlined, size: 16),
                    tooltip: zh ? '复制' : 'Copy',
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: r.answer));
                      AppSnackBar.showSnackBar(context, 
                        SnackBar(
                            content: Text(zh ? '已复制' : 'Copied'),
                            duration: const Duration(seconds: 1)),
                      );
                    },
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                _chip(
                  r.ok
                      ? '${(r.latencyMs / 1000).toStringAsFixed(1)}s'
                      : (zh ? '失败' : 'Failed'),
                  r.ok ? cs.secondaryContainer : cs.errorContainer,
                ),
                const SizedBox(width: 6),
                if (r.ok)
                  _chip(
                    '${r.charsPerSecond.toStringAsFixed(0)} 字/秒',
                    cs.surfaceContainerHighest,
                  ),
              ],
            ),
            const Divider(height: 16),
            if (r.error != null)
              Text(
                r.error!,
                style: TextStyle(fontSize: 12, color: cs.error),
              )
            else
              SelectableText(
                r.answer,
                style: const TextStyle(fontSize: 12.5, height: 1.5),
              ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String text, Color bg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(text, style: const TextStyle(fontSize: 10.5)),
      );
}
