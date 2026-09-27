import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/assistant.dart';
import '../services/github_content_fetcher.dart';
import '../services/storage_service.dart';
import '../utils/app_snackbar.dart';

/// build104（M4）：prompts.chat 角色预设库（方案 B——远程预设库，不污染内置表）。
///
/// 数据源：f/awesome-chatgpt-prompts（prompts.chat）的 prompts.csv，
/// **内容许可 CC0 1.0（公有领域）**，可自由导入分发。走 GitHubContentFetcher
/// 自适应代理链拉取；解析 act/prompt 两列；点选后可编辑并存为本地助手
///（id 前缀 `promptschat.`，与用户自建助手互不干扰）。
class PresetLibraryScreen extends StatefulWidget {
  const PresetLibraryScreen({super.key});

  @override
  State<PresetLibraryScreen> createState() => _PresetLibraryScreenState();
}

class _PresetRow {
  final String act;
  final String prompt;
  const _PresetRow(this.act, this.prompt);
}

class _PresetLibraryScreenState extends State<PresetLibraryScreen> {
  List<_PresetRow> _all = const [];
  bool _loading = true;
  String? _error;
  String _query = '';

  /// prompts.chat 内容老化且英文为主——按实用度人工精选的默认排序白名单，
  /// 命中白名单的排前面，其余按字母序跟在后面（全量仍可搜索浏览）。
  static const Set<String> _featured = {
    'English Translator and Improver',
    'Travel Guide',
    'Interviewer',
    'Essay Writer',
    'Storyteller',
    'Screenwriter',
    'Novelist',
    'Journalist',
    'Poet',
    'Motivational Coach',
    'Debater',
    'Teacher',
    'Math Teacher',
    'Philosopher',
    'Life Coach',
    'Career Counselor',
    'Accountant',
    'Legal Advisor',
    'Dietitian',
    'Doctor',
    'Psychologist',
    'Chef',
    'Home Cook',
    'Personal Trainer',
    'Real Estate Agent',
    'Financial Analyst',
    'Investment Manager',
    'Software Quality Assurance Tester',
    'Developer Relations consultant',
    'IT Expert',
    'Tech Reviewer',
    'Web Design Consultant',
    'UX/UI Developer',
    'Social Media Manager',
    'Advertising Consultant',
    'Marketing Campaign Manager',
    'Salesperson',
    'Customer Support',
    'Product Manager',
    'Project Manager',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _all.isEmpty;
      _error = null;
    });
    try {
      final csv = await GitHubContentFetcher.fetchText(
        'https://raw.githubusercontent.com/f/awesome-chatgpt-prompts/main/prompts.csv',
        totalTimeout: const Duration(seconds: 40),
        tag: 'PromptsChat',
      );
      final rows = _parsePromptsCsv(csv);
      rows.sort((a, b) {
        final fa = _featured.contains(a.act) ? 0 : 1;
        final fb = _featured.contains(b.act) ? 0 : 1;
        if (fa != fb) return fa - fb;
        return a.act.toLowerCase().compareTo(b.act.toLowerCase());
      });
      if (!mounted) return;
      setState(() {
        _all = rows;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  List<_PresetRow> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _all;
    return _all
        .where((r) =>
            r.act.toLowerCase().contains(q) ||
            r.prompt.toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    return Scaffold(
      appBar: AppBar(
        title: Text(isZh ? '角色预设库' : 'Prompt library'),
        actions: [
          IconButton(
            tooltip: isZh ? '重新拉取' : 'Reload',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 20),
                hintText: isZh ? '搜索角色或关键词' : 'Search prompts',
                border: const OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                isZh
                    ? '来源 prompts.chat（CC0 公有领域）· 共 ${_all.length} 个角色'
                    : 'Source prompts.chat (CC0) · ${_all.length} presets',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.outline),
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(isZh ? '拉取失败' : 'Fetch failed'),
                            const SizedBox(height: 4),
                            Text(_error!,
                                maxLines: 3,
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.bodySmall),
                            const SizedBox(height: 12),
                            FilledButton(
                                onPressed: _load,
                                child: Text(isZh ? '重试' : 'Retry')),
                          ],
                        ),
                      )
                    : _filtered.isEmpty
                        ? Center(
                            child: Text(isZh ? '没有匹配的角色' : 'No matches'))
                        : RefreshIndicator(
                            onRefresh: _load,
                            child: ListView.builder(
                              itemCount: _filtered.length,
                              itemBuilder: (ctx, i) =>
                                  _tile(ctx, _filtered[i], isZh),
                            ),
                          ),
          ),
        ],
      ),
    );
  }

  /// B-010：副标题预览——取前 90 字 + 省略号。
  ///
  /// 旧实现 `replaceRange(0, len>90?90:len, len>90?'…':'')` 完全写反：
  /// ① 短文本（≤90）start=0/end=全长/replacement='' → 整串被删成**空字符串**
  ///    （副标题完全空白）；
  /// ② 长文本把**前** 90 字删掉再拼省略号 → 只剩「…+尾巴」，开头预览丢失。
  /// 与「取前 90 字 + 省略号」的本意正好头尾颠倒。
  static String _preview(String raw, {int max = 90}) {
    final s = raw.replaceAll('\n', ' ');
    return s.length > max ? '${s.substring(0, max)}…' : s;
  }

  Widget _tile(BuildContext ctx, _PresetRow row, bool isZh) {
    final featured = _featured.contains(row.act);
    return ListTile(
      leading: Text(featured ? '⭐' : '🎭',
          style: const TextStyle(fontSize: 20)),
      title: Text(row.act,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(_preview(row.prompt)),
      isThreeLine: true,
      onTap: () => _saveDialog(ctx, row, isZh),
    );
  }

  /// 预览全文（可改写）→ 存为本地助手。ReAct 标签字面量给出冲突提示（不禁止）。
  Future<void> _saveDialog(BuildContext ctx, _PresetRow row, bool isZh) async {
    final ctrl = TextEditingController(text: row.prompt);
    final nameCtrl = TextEditingController(text: row.act);
    // 教训 #46 通则：ctx（builder/弹层 ctx）跨 await 视为已死——
    // Provider 捕获必须在第一个 await 之前
    final storage = ctx.read<StorageService>();
    final conflicts = RegExp(r'<(/?)(thinking|think|answer|search|ask_user|mcp_call|skill_call|download|todo|suggest)\b',
            caseSensitive: false)
        .hasMatch(row.prompt);
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (dctx) => AlertDialog(
        title: Text(isZh ? '存为我的助手' : 'Save as assistant'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration:
                    InputDecoration(labelText: isZh ? '助手名称' : 'Name'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: ctrl,
                maxLines: 10,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  helperText: conflicts
                      ? (isZh
                          ? '⚠️ 内容含思考模式协议标签字面量，可能与自主思考循环冲突（已标记）'
                          : '⚠️ Contains ReAct tag literals — may conflict')
                      : (isZh ? '可按需修改后再保存' : 'Edit before saving'),
                  helperMaxLines: 3,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: Text(isZh ? '取消' : 'Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dctx, true),
              child: Text(isZh ? '保存' : 'Save')),
        ],
      ),
    );
    // B-009：同样快照后无条件释放（取消 / 空值 / 保存三路径）
    final name = nameCtrl.text.trim();
    final prompt = ctrl.text.trim();
    nameCtrl.dispose();
    ctrl.dispose();
    if (ok != true || !mounted) return;
    if (name.isEmpty || prompt.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final slug =
        row.act.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    await storage.upsertAssistant(Assistant(
          id: 'promptschat.$slug.${now % 100000}',
          name: name,
          emoji: '🎭',
          systemPrompt: prompt,
          greeting: '',
          createdAt: now,
          updatedAt: now,
        ));
    if (!mounted) return;
    AppSnackBar.showSnackBar(context, SnackBar(
        content: Text(isZh
            ? '✅ 已存为助手「$name」——可在对话设置里绑定'
            : '✅ Saved as "$name"'),
        behavior: SnackBarBehavior.floating));
  }
}

/// 极简 RFC4180 解析（prompts.csv：双引号字段含逗号/换行，"" 转义）。
/// 依赖外部库不值得（附件的 CSV 解析面向"喂模型"格式化，不返回原始行）。
List<_PresetRow> _parsePromptsCsv(String csv) {
  final clean = csv.replaceAll('\r\n', '\n');
  final rows = <List<String>>[];
  var field = StringBuffer();
  var row = <String>[];
  var inQuotes = false;
  for (var i = 0; i < clean.length; i++) {
    final ch = clean[i];
    if (inQuotes) {
      if (ch == '"') {
        if (i + 1 < clean.length && clean[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field.write(ch);
      }
      continue;
    }
    if (ch == '"') {
      inQuotes = true;
    } else if (ch == ',') {
      row.add(field.toString());
      field = StringBuffer();
    } else if (ch == '\n') {
      row.add(field.toString());
      field = StringBuffer();
      if (row.any((c) => c.trim().isNotEmpty)) rows.add(row);
      row = <String>[];
    } else {
      field.write(ch);
    }
  }
  row.add(field.toString());
  if (row.any((c) => c.trim().isNotEmpty)) rows.add(row);
  if (rows.isEmpty) return const [];
  // 表头识别：act,prompt（老版本无表头时按位置兜底）
  var actIdx = 0;
  var promptIdx = 1;
  final header = rows.first.map((h) => h.trim().toLowerCase()).toList();
  final dataRows = rows;
  if (header.contains('act') && header.contains('prompt')) {
    actIdx = header.indexOf('act');
    promptIdx = header.indexOf('prompt');
    dataRows.removeAt(0);
  }
  final out = <_PresetRow>[];
  for (final r in dataRows) {
    if (r.length <= promptIdx) continue;
    final act = r[actIdx].trim();
    final prompt = r[promptIdx].trim();
    if (act.isEmpty || prompt.isEmpty) continue;
    out.add(_PresetRow(act, prompt));
  }
  return out;
}
