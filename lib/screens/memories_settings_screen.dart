// v1.7.38 build90（待办⑧⑨）：记忆设置子页 —— 全局记忆 + 项目（含项目记忆与项目斜杠命令）。
// 数据走 StorageService v27 新表 CRUD；UI 遵循 AppSectionCard + AppPad/AppGap 朴素风。

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../l10n/app_localizations.dart';
import '../models/memory_models.dart';
import '../services/storage_service.dart';
import '../ui/tokens.dart';
import '../utils/app_snackbar.dart';

/// build173（方案 C）：**这条是谁写的**要在这一页上看得见。
///
/// 为什么放在这里而不是弹窗里：用户批准的是"自动写不弹窗、给总闸 + 这页能看清
/// 哪条是 AI 写的"（总闸在「通用设置」，判据与拦截都在
/// `StorageService._autoMemoryGateAllows`，本页只负责显示）。
/// 判据只认 `source == 'auto'` 这一个值 —— 与全仓另外三处同一口径
/// （`MemoryWritePlugin.autoOverwriteAllowed` / `memory_block_builder._isAuto` /
/// `StorageService.excessMemoryIdsToDelete`），不新造第四份判断。
/// 其余值一律按手动对待：`GlobalMemory.source` 目前全仓只会落 'auto' 与 'manual'，
/// 而 `fromMap` 缺省就是 'manual'。
///
/// 形状纪律：标签走 ListTile 现成的 subtitle 槽（同文件项目列表那行就是这么用的，
/// fontSize 也沿用本页既有的 12），不新造组件、不加尺寸、不加动画。
String memorySourceLabel(String source, {required bool zh}) =>
    source == 'auto' ? (zh ? '自动生成' : 'Auto') : (zh ? '手动' : 'Manual');

class MemoriesSettingsScreen extends StatefulWidget {
  const MemoriesSettingsScreen({super.key});

  @override
  State<MemoriesSettingsScreen> createState() => _MemoriesSettingsScreenState();
}

class _MemoriesSettingsScreenState extends State<MemoriesSettingsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final _uuid = const Uuid();

  List<GlobalMemory> _globalMemories = [];
  List<Project> _projects = [];
  Map<String, int> _projectMemoryCounts = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _reload();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final storage = StorageService.instance;
    final memories = await storage.loadGlobalMemories();
    final projects = await storage.loadProjects();
    final counts = <String, int>{};
    for (final p in projects) {
      counts[p.id] = (await storage.loadProjectMemories(p.id)).length;
    }
    if (!mounted) return;
    setState(() {
      _globalMemories = memories;
      _projects = projects;
      _projectMemoryCounts = counts;
      _loading = false;
    });
  }

  bool get _zh => AppLocalizations.of(context).locale.languageCode == 'zh';

  // ---------- 全局记忆 ----------

  Future<void> _editGlobalMemory([GlobalMemory? existing]) async {
    final zh = _zh;
    final controller = TextEditingController(text: existing?.content ?? '');
    bool pinned = existing?.pinned ?? false;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: Text(existing == null
              ? (zh ? '新增全局记忆' : 'New Global Memory')
              : (zh ? '编辑全局记忆' : 'Edit Global Memory')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                maxLines: 4,
                minLines: 2,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: zh
                      ? '一句话一条，如：回答默认用中文'
                      : 'One line per fact, e.g.: reply in Chinese by default',
                  border: const OutlineInputBorder(),
                ),
              ),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: pinned,
                onChanged: (v) => setSt(() => pinned = v),
                title: Text(zh ? '钉住（永不自动清理）' : 'Pin (never auto-cleaned)'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(AppLocalizations.of(ctx).tr('cancel')),
            ),
            FilledButton(
              onPressed: () {
                if (controller.text.trim().isEmpty) return;
                Navigator.pop(ctx, true);
              },
              child: Text(zh ? '保存' : 'Save'),
            ),
          ],
        ),
      ),
    );
    if (saved != true) {
      // B-009：取消路径补齐释放（原实现只在保存路径 dispose）
      controller.dispose();
      return;
    }
    final memory = existing ?? GlobalMemory(id: _uuid.v4(), content: '');
    memory
      ..content = controller.text.trim()
      ..pinned = pinned
      ..updatedAt = DateTime.now().millisecondsSinceEpoch;
    await StorageService.instance.saveGlobalMemory(memory);
    controller.dispose();
    await _reload();
  }

  Future<void> _addGlobalMemory() async {
    final zh = _zh;
    if (_globalMemories.length >= StorageService.maxGlobalMemories) {
      AppSnackBar.showSnackBar(context, 
        SnackBar(
          content: Text(zh
              ? '全局记忆已达上限 ${StorageService.maxGlobalMemories} 条，请先清理'
              : 'Global memories reached the limit of ${StorageService.maxGlobalMemories}; please clean up first'),
        ),
      );
      return;
    }
    await _editGlobalMemory();
  }

  Future<void> _deleteGlobalMemory(GlobalMemory m) async {
    // build97 (P2-14 铁律#11)：左滑/长按删除都先二次确认
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_zh ? '删除记忆？' : 'Delete memory?'),
        content: Text(_zh
            ? '确认删除这条全局记忆？'
            : 'Delete this global memory?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(_zh ? '取消' : 'Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(_zh ? '删除' : 'Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await StorageService.instance.deleteGlobalMemory(m.id);
    await _reload();
  }

  // ---------- 项目 ----------

  Future<void> _addProject() async {
    final zh = _zh;
    final controller = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(zh ? '新增项目' : 'New Project'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 30,
          decoration: InputDecoration(
            hintText: zh ? '项目名称' : 'Project name',
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppLocalizations.of(ctx).tr('cancel')),
          ),
          FilledButton(
            onPressed: () {
              if (controller.text.trim().isEmpty) return;
              Navigator.pop(ctx, true);
            },
            child: Text(zh ? '创建' : 'Create'),
          ),
        ],
      ),
    );
    // B2（N-7）：读值后立即释放——原实现把 dispose 放在「取消即提前返回」
    // 那行之后，于是取消弹窗（最常见的路径）直接跳过释放，
    // 每次取消泄漏一个 TextEditingController。
    final name = controller.text.trim();
    controller.dispose();
    if (saved != true) return;
    await StorageService.instance
        .saveProject(Project(id: _uuid.v4(), name: name));
    await _reload();
  }

  Future<void> _deleteProject(Project p) async {
    final zh = _zh;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(zh ? '删除项目' : 'Delete Project'),
        content: Text(zh
            ? '删除项目「${p.name}」将同时删除其全部记忆与斜杠命令，并解绑归属该项目的对话。确定删除？'
            : 'Deleting project "${p.name}" will also delete all its memories and slash commands, and unbind its conversations. Continue?'),
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
    await StorageService.instance.deleteProject(p.id);
    await _reload();
  }

  // ---------- build ----------

  @override
  Widget build(BuildContext context) {
    final zh = _zh;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(zh ? '记忆' : 'Memories'),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: zh ? '全局记忆' : 'Global'),
            Tab(text: zh ? '项目' : 'Projects'),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                _buildGlobalTab(cs, zh),
                _buildProjectsTab(cs, zh),
              ],
            ),
    );
  }

  Widget _buildGlobalTab(ColorScheme cs, bool zh) {
    return ListView(
      padding: AppPad.page,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: AppGap.sm),
          child: Text(
            zh
                ? '全局记忆会在所有新对话中自动注入'
                : 'Global memories are auto-injected into every new conversation',
            style: TextStyle(fontSize: 12, color: cs.appTextSub),
          ),
        ),
        AppSectionCard(
          title: zh
              ? '全局记忆（${_globalMemories.length}/${StorageService.maxGlobalMemories}）'
              : 'Global Memories (${_globalMemories.length}/${StorageService.maxGlobalMemories})',
          children: [
            if (_globalMemories.isEmpty)
              Padding(
                padding: AppPad.card,
                child: Text(
                  zh ? '暂无记忆，点右上角 + 新增' : 'No memories yet. Tap + to add one.',
                  style: TextStyle(fontSize: 12, color: cs.appTextSub),
                ),
              )
            else
              for (final m in _globalMemories)
                Dismissible(
                  key: ValueKey(m.id),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: AppGap.lg),
                    color: cs.errorContainer,
                    child:
                        Icon(Icons.delete_outline, color: cs.onErrorContainer),
                  ),
                  // B-012：改用 confirmDismiss（与下方项目记忆一致）——旧实现用
                  // onDismissed 在「滑除动画完成后」才弹确认，用户点取消时条目已被
                  // 移出 widget 树且不 _reload，出现「界面没了、数据还在」的错位
                  //（重进页面又复活）。confirmDismiss 返回 false 时 Dismissible 自动回弹。
                  confirmDismiss: (_) async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: Text(_zh ? '删除记忆？' : 'Delete memory?'),
                        content: Text(_zh
                            ? '确认删除这条全局记忆？'
                            : 'Delete this global memory?'),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: Text(_zh ? '取消' : 'Cancel')),
                          FilledButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: Text(_zh ? '删除' : 'Delete')),
                        ],
                      ),
                    );
                    return ok ?? false;
                  },
                  onDismissed: (_) async {
                    await StorageService.instance.deleteGlobalMemory(m.id);
                    await _reload();
                  },
                  child: ListTile(
                    dense: true,
                    leading: m.pinned
                        ? Icon(Icons.push_pin, size: 18, color: cs.appTextSub)
                        : Icon(Icons.notes, size: 18, color: cs.appTextSub),
                    title: Text(
                      m.content,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                    // build173（方案 C）：这条是 AI 自动写的还是我写的 —— 一眼分清，
                    // 因为总闸只管 auto 那一档，而"关掉之后还能逐条删"要能核对到。
                    subtitle: Text(
                      memorySourceLabel(m.source, zh: zh),
                      style: const TextStyle(fontSize: 12),
                    ),
                    onTap: () => _editGlobalMemory(m),
                    onLongPress: () => _deleteGlobalMemory(m),
                  ),
                ),
          ],
        ),
        Align(
          alignment: Alignment.centerRight,
          child: IconButton(
            icon: const Icon(Icons.add_circle_outline),
            tooltip: zh ? '新增' : 'Add',
            onPressed: _addGlobalMemory,
          ),
        ),
      ],
    );
  }

  Widget _buildProjectsTab(ColorScheme cs, bool zh) {
    return ListView(
      padding: AppPad.page,
      children: [
        AppSectionCard(
          title: zh ? '项目' : 'Projects',
          children: [
            if (_projects.isEmpty)
              Padding(
                padding: AppPad.card,
                child: Text(
                  zh
                      ? '暂无项目。项目用于按话题沉淀上下文记忆与斜杠命令'
                      : 'No projects yet. Projects group context memories and slash commands by topic',
                  style: TextStyle(fontSize: 12, color: cs.appTextSub),
                ),
              )
            else
              for (final p in _projects)
                ListTile(
                  dense: true,
                  leading: Icon(Icons.folder_outlined,
                      size: 20, color: cs.appTextSub),
                  title: Text(p.name),
                  subtitle: Text(
                    zh
                        ? '${_projectMemoryCounts[p.id] ?? 0} 条记忆'
                        : '${_projectMemoryCounts[p.id] ?? 0} memories',
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: IconButton(
                    icon: Icon(Icons.delete_outline,
                        size: 20, color: cs.appTextSub),
                    tooltip: zh ? '删除项目' : 'Delete project',
                    onPressed: () => _deleteProject(p),
                  ),
                  onTap: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ProjectDetailScreen(project: p),
                      ),
                    );
                    await _reload();
                  },
                ),
          ],
        ),
        Align(
          alignment: Alignment.centerRight,
          child: IconButton(
            icon: const Icon(Icons.add_circle_outline),
            tooltip: zh ? '新增项目' : 'New project',
            onPressed: _addProject,
          ),
        ),
      ],
    );
  }
}

/// 项目详情页：项目记忆 CRUD（上限 50）+ 项目斜杠命令列表。
class ProjectDetailScreen extends StatefulWidget {
  const ProjectDetailScreen({super.key, required this.project});

  final Project project;

  @override
  State<ProjectDetailScreen> createState() => _ProjectDetailScreenState();
}

class _ProjectDetailScreenState extends State<ProjectDetailScreen> {
  final _uuid = const Uuid();
  List<ProjectMemory> _memories = [];
  List<SlashCommand> _commands = [];
  bool _loading = true;

  String get _scope => 'project:${widget.project.id}';

  bool get _zh => AppLocalizations.of(context).locale.languageCode == 'zh';

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final storage = StorageService.instance;
    final memories = await storage.loadProjectMemories(widget.project.id);
    final commands = await storage.loadSlashCommands(scope: _scope);
    if (!mounted) return;
    setState(() {
      _memories = memories;
      _commands = commands;
      _loading = false;
    });
  }

  Future<void> _editMemory([ProjectMemory? existing]) async {
    final zh = _zh;
    final controller = TextEditingController(text: existing?.content ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null
            ? (zh ? '新增项目记忆' : 'New Project Memory')
            : (zh ? '编辑项目记忆' : 'Edit Project Memory')),
        content: TextField(
          controller: controller,
          maxLines: 4,
          minLines: 2,
          autofocus: true,
          decoration: InputDecoration(
            hintText: zh
                ? '该项目下对话自动携带的上下文'
                : 'Context auto-injected in this project\'s conversations',
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppLocalizations.of(ctx).tr('cancel')),
          ),
          FilledButton(
            onPressed: () {
              if (controller.text.trim().isEmpty) return;
              Navigator.pop(ctx, true);
            },
            child: Text(zh ? '保存' : 'Save'),
          ),
        ],
      ),
    );
    if (saved != true) return;
    final memory = existing ??
        ProjectMemory(
            id: _uuid.v4(), projectId: widget.project.id, content: '');
    memory
      ..content = controller.text.trim()
      ..updatedAt = DateTime.now().millisecondsSinceEpoch;
    await StorageService.instance.saveProjectMemory(memory);
    controller.dispose();
    await _reload();
  }

  Future<void> _addMemory() async {
    final zh = _zh;
    if (_memories.length >= StorageService.maxProjectMemoriesPerProject) {
      AppSnackBar.showSnackBar(context, 
        SnackBar(
          content: Text(zh
              ? '项目记忆已达上限 ${StorageService.maxProjectMemoriesPerProject} 条，请先清理'
              : 'Project memories reached the limit of ${StorageService.maxProjectMemoriesPerProject}; please clean up first'),
        ),
      );
      return;
    }
    await _editMemory();
  }

  @override
  Widget build(BuildContext context) {
    final zh = _zh;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.project.name)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: AppPad.page,
              children: [
                AppSectionCard(
                  title: zh
                      ? '项目记忆（${_memories.length}/${StorageService.maxProjectMemoriesPerProject}）'
                      : 'Project Memories (${_memories.length}/${StorageService.maxProjectMemoriesPerProject})',
                  children: [
                    if (_memories.isEmpty)
                      Padding(
                        padding: AppPad.card,
                        child: Text(
                          zh ? '暂无记忆' : 'No memories yet',
                          style: TextStyle(fontSize: 12, color: cs.appTextSub),
                        ),
                      )
                    else
                      for (final m in _memories)
                        Dismissible(
                          key: ValueKey(m.id),
                          direction: DismissDirection.endToStart,
                          // build97 (P2-14 铁律#11)：左滑删除先二次确认
                          confirmDismiss: (_) async {
                            final ok = await showDialog<bool>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: Text(
                                    zh ? '删除记忆？' : 'Delete memory?'),
                                content: Text(zh
                                    ? '确认删除这条项目记忆？'
                                    : 'Delete this project memory?'),
                                actions: [
                                  TextButton(
                                      onPressed: () =>
                                          Navigator.pop(ctx, false),
                                      child: Text(zh ? '取消' : 'Cancel')),
                                  FilledButton(
                                      onPressed: () =>
                                          Navigator.pop(ctx, true),
                                      child: Text(zh ? '删除' : 'Delete')),
                                ],
                              ),
                            );
                            return ok ?? false;
                          },
                          background: Container(
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: AppGap.lg),
                            color: cs.errorContainer,
                            child: Icon(Icons.delete_outline,
                                color: cs.onErrorContainer),
                          ),
                          onDismissed: (_) async {
                            await StorageService.instance
                                .deleteProjectMemory(m.id);
                            await _reload();
                          },
                          child: ListTile(
                            dense: true,
                            title: Text(
                              m.content,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13),
                            ),
                            // 与全局那一列同一个标签、同一个 subtitle 槽
                            // （总闸同样管着项目记忆那条路，见 saveProjectMemory）
                            subtitle: Text(
                              memorySourceLabel(m.source, zh: zh),
                              style: const TextStyle(fontSize: 12),
                            ),
                            onTap: () => _editMemory(m),
                          ),
                        ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: IconButton(
                        icon: const Icon(Icons.add_circle_outline),
                        tooltip: zh ? '新增记忆' : 'Add memory',
                        onPressed: _addMemory,
                      ),
                    ),
                  ],
                ),
                AppSectionCard(
                  title: zh ? '项目斜杠命令' : 'Project Slash Commands',
                  children: [
                    if (_commands.isEmpty)
                      Padding(
                        padding: AppPad.card,
                        child: Text(
                          zh
                              ? '暂无命令。项目命令仅在该项目对话中可用'
                              : 'No commands. Project commands are only available in this project\'s conversations',
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
                        ),
                  ],
                ),
              ],
            ),
    );
  }
}
