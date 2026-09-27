import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../l10n/app_localizations.dart';
import '../models/assistant.dart';
import '../services/storage_service.dart';
import 'preset_library_screen.dart';
import '../ui/app_skeleton.dart';
import '../utils/app_snackbar.dart';

/// build101（E8 自定义助手）：助手管理与编辑。
///
/// 助手 = 可复用的「角色预设」（名称 + emoji + system prompt + 开场白）。
/// 会话设置里绑定后，该会话每次请求都会把助手的 systemPrompt 拼在
/// 用户自定义提示词之前（助手作为「基底人设」，用户提示词仍可覆盖细节）。
class AssistantsScreen extends StatefulWidget {
  const AssistantsScreen({super.key});

  @override
  State<AssistantsScreen> createState() => _AssistantsScreenState();
}

class _AssistantsScreenState extends State<AssistantsScreen> {
  List<Assistant> _list = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final l = AppLocalizations.of(context);
    final zh = l.locale.languageCode == 'zh';
    final storage = context.read<StorageService>();
    // 首次打开把内置预设落库（表非空则跳过）
    await storage.ensureBuiltinAssistants(zh: zh);
    final list = await storage.listAssistants();
    if (!mounted) return;
    setState(() {
      _list = list;
      _loading = false;
    });
  }

  Future<void> _edit([Assistant? existing]) async {
    final l = AppLocalizations.of(context);
    final zh = l.locale.languageCode == 'zh';
    final emojiCtrl = TextEditingController(text: existing?.emoji ?? '🤖');
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final promptCtrl = TextEditingController(text: existing?.systemPrompt ?? '');
    final greetCtrl = TextEditingController(text: existing?.greeting ?? '');

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null
            ? (zh ? '新建助手' : 'New assistant')
            : (zh ? '编辑助手' : 'Edit assistant')),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 68,
                      child: TextField(
                        controller: emojiCtrl,
                        textAlign: TextAlign.center,
                        decoration: InputDecoration(
                          labelText: zh ? '图标' : 'Icon',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: nameCtrl,
                        autofocus: true,
                        decoration: InputDecoration(
                          labelText: zh ? '名称' : 'Name',
                          hintText: zh ? '例如：法律顾问' : 'e.g. Legal advisor',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: promptCtrl,
                  maxLines: 8,
                  minLines: 4,
                  decoration: InputDecoration(
                    labelText: zh ? '系统提示词（人设）' : 'System prompt',
                    alignLabelWithHint: true,
                    helperText: zh
                        ? '写得越具体越有效：明确规则、输出格式、禁止行为'
                        : 'Be specific: rules, output format, prohibitions',
                    helperMaxLines: 2,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: greetCtrl,
                  maxLines: 3,
                  minLines: 1,
                  decoration: InputDecoration(
                    labelText: zh ? '开场白（可选）' : 'Greeting (optional)',
                    alignLabelWithHint: true,
                    helperText: zh
                        ? '绑定该助手后新建会话时，AI 主动发的第一句'
                        : 'First AI message in a new chat bound to this assistant',
                    helperMaxLines: 2,
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(zh ? '取消' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(zh ? '保存' : 'Save'),
          ),
        ],
      ),
    );
    // B-009：弹窗返回后先快照取值，再无条件下方释放 4 个 controller
    //（取消 / 名称为空 / 正常保存三条路径全覆盖）。
    final nameText = nameCtrl.text.trim();
    final emojiText = emojiCtrl.text.trim();
    final promptText = promptCtrl.text.trim();
    final greetText = greetCtrl.text.trim();
    emojiCtrl.dispose();
    nameCtrl.dispose();
    promptCtrl.dispose();
    greetCtrl.dispose();
    if (ok != true || !mounted) return;

    final name = nameText;
    if (name.isEmpty) {
      AppSnackBar.showSnackBar(context, 
        SnackBar(content: Text(zh ? '名称不能为空' : 'Name is required')),
      );
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final storage = context.read<StorageService>();
    if (existing == null) {
      await storage.upsertAssistant(Assistant(
        id: const Uuid().v4(),
        name: name,
        emoji: emojiText.isEmpty ? '🤖' : emojiText,
        systemPrompt: promptText,
        greeting: greetText,
        createdAt: now,
        updatedAt: now,
      ));
    } else {
      await storage.upsertAssistant(existing.copyWith(
        name: name,
        emoji: emojiText.isEmpty ? '🤖' : emojiText,
        systemPrompt: promptText,
        greeting: greetText,
      ));
    }
    await _load();
  }

  Future<void> _delete(Assistant a) async {
    final l = AppLocalizations.of(context);
    final zh = l.locale.languageCode == 'zh';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(zh ? '删除助手' : 'Delete assistant'),
        content: Text(zh
            ? '删除「${a.name}」后，绑定它的会话将不再使用该人设。'
            : 'Sessions bound to "${a.name}" will stop using this persona.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(zh ? '取消' : 'Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(zh ? '删除' : 'Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await context.read<StorageService>().deleteAssistant(a.id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final zh = l.locale.languageCode == 'zh';
    final builtins = _list.where((a) => a.isBuiltin).toList();
    final customs = _list.where((a) => !a.isBuiltin).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(zh ? '自定义助手' : 'Custom Assistants'),
        // build104（M4）：prompts.chat 角色预设库入口
        actions: [
          IconButton(
            tooltip: zh ? '角色预设库' : 'Prompt library',
            icon: const Icon(Icons.auto_awesome_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const PresetLibraryScreen()),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add),
        label: Text(zh ? '新建' : 'New'),
      ),
      body: _loading
          // build133：列表加载态改用骨架屏（理由同会话列表）。
          ? const Padding(
              padding: EdgeInsets.all(12),
              child: AppSkeleton.list(count: 5),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
              children: [
                if (customs.isNotEmpty) ...[
                  _groupLabel(zh ? '我的助手' : 'My assistants'),
                  for (final a in customs) _tile(a, zh),
                  const SizedBox(height: 12),
                ],
                if (builtins.isNotEmpty) ...[
                  _groupLabel(zh ? '内置预设' : 'Built-in presets'),
                  for (final a in builtins) _tile(a, zh),
                ],
              ],
            ),
    );
  }

  Widget _groupLabel(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
        child: Text(
          text,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      );

  Widget _tile(Assistant a, bool zh) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor:
              Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
          child: Text(a.emoji, style: const TextStyle(fontSize: 18)),
        ),
        title: Text(a.name),
        subtitle: Text(
          a.systemPrompt.replaceAll('\n', ' '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (v) {
            if (v == 'edit') {
              _edit(a);
            } else if (v == 'delete') {
              _delete(a);
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(
                value: 'edit', child: Text(zh ? '编辑' : 'Edit')),
            PopupMenuItem(
              value: 'delete',
              child: Text(zh ? '删除' : 'Delete',
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          ],
        ),
        onTap: () => _edit(a),
      ),
    );
  }
}
