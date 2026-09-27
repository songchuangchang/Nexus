// v1.7.38 build90（待办⑧⑨）：全局斜杠命令设置子页。
// 命令名同 scope 查重走 StorageService.slashCommandNameExists；模板上限 4000 字。

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../l10n/app_localizations.dart';
import '../models/memory_models.dart';
import '../services/storage_service.dart';
import '../ui/tokens.dart';
import '../utils/app_snackbar.dart';

class SlashCommandsSettingsScreen extends StatefulWidget {
  const SlashCommandsSettingsScreen({super.key});

  @override
  State<SlashCommandsSettingsScreen> createState() =>
      _SlashCommandsSettingsScreenState();
}

class _SlashCommandsSettingsScreenState
    extends State<SlashCommandsSettingsScreen> {
  final _uuid = const Uuid();
  List<SlashCommand> _commands = [];
  bool _loading = true;

  bool get _zh => AppLocalizations.of(context).locale.languageCode == 'zh';

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final commands =
        await StorageService.instance.loadSlashCommands(scope: 'global');
    if (!mounted) return;
    setState(() {
      _commands = commands;
      _loading = false;
    });
  }

  Future<void> _editCommand([SlashCommand? existing]) async {
    final zh = _zh;
    final nameController = TextEditingController(text: existing?.name ?? '');
    final templateController =
        TextEditingController(text: existing?.promptTemplate ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null
            ? (zh ? '新增斜杠命令' : 'New Slash Command')
            : (zh ? '编辑斜杠命令' : 'Edit Slash Command')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: nameController,
                autofocus: existing == null,
                decoration: InputDecoration(
                  prefixText: '/',
                  hintText: zh ? '命令名' : 'Command name',
                  helperText: zh
                      ? '只允许字母、数字、下划线、连字符'
                      : 'Letters, digits, underscore and hyphen only',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: AppGap.md),
              TextField(
                controller: templateController,
                maxLines: 6,
                minLines: 3,
                maxLength: SlashCommand.maxTemplateLength,
                decoration: InputDecoration(
                  hintText: zh ? '提示词模板' : 'Prompt template',
                  helperText: zh
                      ? '模板支持 {{input}} 占位符，唤起时替换为你输入的内容'
                      : 'Template supports the {{input}} placeholder, replaced with your input when invoked',
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppLocalizations.of(ctx).tr('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(zh ? '保存' : 'Save'),
          ),
        ],
      ),
    );
    if (saved != true) {
      nameController.dispose();
      templateController.dispose();
      return;
    }

    final name = nameController.text.trim();
    final template = templateController.text.trim();
    nameController.dispose();
    templateController.dispose();

    final nameValid = RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(name);
    if (!nameValid || template.isEmpty) {
      if (!mounted) return;
      AppSnackBar.showSnackBar(context, 
        SnackBar(
          content: Text(zh
              ? '命令名只允许字母、数字、下划线、连字符，且模板不能为空'
              : 'Name may only contain letters, digits, underscore, hyphen; template must not be empty'),
        ),
      );
      return;
    }
    if (template.length > SlashCommand.maxTemplateLength) {
      if (!mounted) return;
      AppSnackBar.showSnackBar(context, 
        SnackBar(
          content: Text(zh
              ? '模板超过 ${SlashCommand.maxTemplateLength} 字上限'
              : 'Template exceeds the ${SlashCommand.maxTemplateLength}-char limit'),
        ),
      );
      return;
    }
    final exists = await StorageService.instance.slashCommandNameExists(
      name,
      'global',
      excludeId: existing?.id,
    );
    if (exists) {
      if (!mounted) return;
      AppSnackBar.showSnackBar(context, 
        SnackBar(
          content: Text(zh
              ? '已存在同名命令 /$name，请换一个名字'
              : 'A command named /$name already exists; pick another name'),
        ),
      );
      return;
    }

    final command =
        existing ?? SlashCommand(id: _uuid.v4(), name: '', promptTemplate: '');
    command
      ..name = name
      ..promptTemplate = template
      ..scope = 'global'
      ..updatedAt = DateTime.now().millisecondsSinceEpoch;
    await StorageService.instance.saveSlashCommand(command);
    await _reload();
  }

  Future<void> _deleteCommand(SlashCommand c) async {
    final zh = _zh;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(zh ? '删除命令' : 'Delete Command'),
        content: Text(
          zh ? '确定删除命令 /${c.name}？' : 'Delete command /${c.name}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppLocalizations.of(ctx).tr('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.errorContainer,
              foregroundColor: Theme.of(ctx).colorScheme.onErrorContainer,
            ),
            child: Text(zh ? '删除' : 'Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await StorageService.instance.deleteSlashCommand(c.id);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final zh = _zh;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(zh ? '斜杠命令' : 'Slash Commands')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: AppPad.page,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: AppGap.sm),
                  child: Text(
                    zh
                        ? '在聊天输入 / 唤起命令模板'
                        : 'Type / in chat to invoke command templates',
                    style: TextStyle(fontSize: 12, color: cs.appTextSub),
                  ),
                ),
                AppSectionCard(
                  title: zh ? '全局命令' : 'Global Commands',
                  children: [
                    if (_commands.isEmpty)
                      Padding(
                        padding: AppPad.card,
                        child: Text(
                          zh
                              ? '暂无命令，点下方 + 新增'
                              : 'No commands yet. Tap + below to add one.',
                          style: TextStyle(fontSize: 12, color: cs.appTextSub),
                        ),
                      )
                    else
                      for (final c in _commands)
                        ListTile(
                          dense: true,
                          leading: Icon(Icons.terminal,
                              size: 18, color: cs.appTextSub),
                          title: Text('/${c.name}'),
                          subtitle: Text(
                            c.promptTemplate.split('\n').first,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: IconButton(
                            icon: Icon(Icons.delete_outline,
                                size: 20, color: cs.appTextSub),
                            tooltip: zh ? '删除' : 'Delete',
                            onPressed: () => _deleteCommand(c),
                          ),
                          onTap: () => _editCommand(c),
                        ),
                  ],
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    tooltip: zh ? '新增命令' : 'New command',
                    onPressed: () => _editCommand(),
                  ),
                ),
              ],
            ),
    );
  }
}
