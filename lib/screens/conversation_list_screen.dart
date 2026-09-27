import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:io';
import '../l10n/app_localizations.dart';
import '../models/api_config.dart';
import '../models/conversation.dart';
import '../services/storage_service.dart';
import '../services/logger_service.dart';
import '../services/conversation_export_service.dart';
import '../services/file_open_service.dart';
import '../services/widget_plugin_service.dart';
import '../widgets/home_widget_strip.dart';
import 'chat_screen.dart';
import 'api_config_screen.dart';
import 'conversation_search_screen.dart';
import '../widgets/quick_access_drawer.dart';
import '../services/biometric_service.dart';
import '../ui/app_skeleton.dart';
import '../utils/app_snackbar.dart';

class ConversationListScreen extends StatefulWidget {
  const ConversationListScreen({super.key, this.showArchivedOnly = false});

  /// build102（C）：true = 归档专用页（从左滑抽屉「归档会话」进入，只显示已归档）。
  /// build101 的主页 AppBar「查看归档」图标按用户拍板移除，归档入口收进抽屉。
  final bool showArchivedOnly;

  @override
  State<ConversationListScreen> createState() => _ConversationListScreenState();
}

class _ConversationListScreenState extends State<ConversationListScreen> {
  List<Conversation> _conversations = [];
  List<ApiConfig> _apiConfigs = [];
  bool _isLoading = true;
  // v1.7.31：草稿缓存（conversation.id → 草稿文本）
  Map<String, String> _drafts = {};
  // build108（Q2 一期）：主页顶声明式小部件（home_top 位置）
  List<WidgetPluginManifest> _widgetPlugins = [];
  // build101（B5）：是否显示归档会话（false=只看活跃，true=只看归档）
  // build102（C）：initState 从 widget.showArchivedOnly 取初值
  bool _showArchived = false;
  // build101（B8）：多选批量操作模式
  bool _selectionMode = false;
  final Set<String> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    _showArchived = widget.showArchivedOnly;
    // WP-3：市场装/卸小部件后即时刷新主页条
    WidgetPluginService.revision.addListener(_reloadWidgetPlugins);
    _initData();
  }

  @override
  void dispose() {
    WidgetPluginService.revision.removeListener(_reloadWidgetPlugins);
    super.dispose();
  }

  /// 仅重拉小部件清单（轻量，不动会话/配置加载）
  Future<void> _reloadWidgetPlugins() async {
    if (!mounted) return;
    final plugins = _showArchived
        ? const <WidgetPluginManifest>[]
        : (await WidgetPluginService.load())
            .where((w) => w.placement == 'home_top')
            .toList();
    if (!mounted) return;
    setState(() => _widgetPlugins = plugins);
  }

  Future<void> _initData() async {
    final storage = context.read<StorageService>();
    await storage.init();
    await _loadData();
  }

  Future<void> _loadData() async {
    final storage = context.read<StorageService>();
    final allConvs = await storage.getConversations();
    // build101（B5）：按归档状态分流
    final convs =
        allConvs.where((c) => c.isArchived == _showArchived).toList();
    final configs = await storage.getApiConfigs();
    // v1.7.31：加载草稿
    final prefs = await SharedPreferences.getInstance();
    final drafts = <String, String>{};
    for (final c in convs) {
      final d = prefs.getString('chat_draft_${c.id}');
      if (d != null && d.isNotEmpty) drafts[c.id] = d;
    }
    // build108（Q2 一期）：主页顶声明式小部件（仅未归档视图显示）
    final widgetPlugins = _showArchived
        ? const <WidgetPluginManifest>[]
        : (await WidgetPluginService.load())
            .where((w) => w.placement == 'home_top')
            .toList();
    if (mounted) {
      setState(() {
        _conversations = convs;
        _apiConfigs = configs;
        _drafts = drafts;
        _widgetPlugins = widgetPlugins;
        _isLoading = false;
      });
    }
  }

  /// build101（B1）：重命名会话
  Future<void> _renameConversation(
      BuildContext ctx, Conversation conv) async {
    final isZh = AppLocalizations.of(ctx).locale.languageCode == 'zh';
    // build101：storage 在 await 前取出，避免跨异步 gap 用 context
    final storage = context.read<StorageService>();
    final controller = TextEditingController(text: conv.title);
    // 全量缺陷扫描 §3（P3）：弹层内 TextEditingController 此前未释放。
    // 它不是内存泄漏（弹层关闭后 TextField 解除订阅，控制器可被 GC 回收），
    // 但会被 Flutter leak tracker 标记 —— 将来在 test/ 启用 LeakTesting
    // 会直接判红，故在「弹层关闭」这一刻释放。
    final result = await showDialog<String>(
      context: ctx,
      builder: (dctx) => AlertDialog(
        title: Text(isZh ? '重命名对话' : 'Rename chat'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 100,
          decoration: InputDecoration(
            labelText: isZh ? '标题' : 'Title',
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(dctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx),
            child: Text(isZh ? '取消' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, controller.text),
            child: Text(isZh ? '保存' : 'Save'),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
    if (result == null) return;
    final title = result.trim();
    if (title.isEmpty || title == conv.title) return;
    await storage.updateConversationTitle(conv.id, title);
    if (!mounted) return;
    await _loadData();
  }

  /// build101（B5）：切换归档状态
  Future<void> _toggleArchive(BuildContext ctx, Conversation conv) async {
    final isZh = AppLocalizations.of(ctx).locale.languageCode == 'zh';
    // build101：storage 在 await 前取出，避免跨异步 gap 用 context
    final storage = context.read<StorageService>();
    final wasArchived = conv.isArchived;
    await storage.toggleArchiveConversation(conv.id, !wasArchived);
    if (!mounted) return;
    AppSnackBar.showSnackBar(context, 
      SnackBar(
        content: Text(wasArchived
            ? (isZh ? '已移出归档' : 'Unarchived')
            : (isZh ? '已归档' : 'Archived')),
        duration: const Duration(seconds: 2),
      ),
    );
    await _loadData();
  }

  /// build101（B6）：导出整段对话（Markdown / JSON）
  Future<void> _exportConversation(BuildContext ctx, Conversation conv) async {
    final isZh = AppLocalizations.of(ctx).locale.languageCode == 'zh';
    // build101：storage 在 await 之前取出，避免跨异步 gap 用 context
    final storage = context.read<StorageService>();
    final format = await showDialog<String>(
      context: ctx,
      builder: (dctx) => SimpleDialog(
        title: Text(isZh ? '导出对话' : 'Export chat'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dctx, 'md'),
            child: Text(isZh ? 'Markdown (.md)' : 'Markdown (.md)'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dctx, 'json'),
            child: Text(isZh ? 'JSON (.json)' : 'JSON (.json)'),
          ),
        ],
      ),
    );
    if (format == null) return;
    final messages = await storage.getMessages(conv.id);
    final service = ConversationExportService();
    // build120：写文件包 try-catch —— 此前写盘异常会直接冒泡进 runZonedGuarded
    // （红字错误），用户只看到「跳转了一下、文件没保存」，无从判断原因。
    final File file;
    try {
      file = format == 'md'
          ? await service.exportMarkdown(conv, messages)
          : await service.exportJson(conv, messages);
    } on ExportBusyException {
      if (!mounted) return;
      AppSnackBar.show(context, isZh ? '上一次导出还没结束，请稍后重试' : 'Previous export still running',
          action: null);
      return;
    } catch (e) {
      if (!mounted) return;
      LoggerService.instance.error('导出对话失败：$e', tag: 'Export');
      AppSnackBar.show(context,
          isZh ? '导出失败：$e' : 'Export failed: $e');
      return;
    }
    if (!mounted) return;
    AppSnackBar.showSnackBar(context, 
      SnackBar(
        content: Text(isZh
            ? '已导出：${file.path.split(Platform.pathSeparator).last}'
            : 'Exported: ${file.path.split(Platform.pathSeparator).last}'),
        action: SnackBarAction(
          label: isZh ? '打开' : 'Open',
          // B-003：交给外部应用打开也是原生跳转，走 guard 防止返回时误弹生物锁
          onPressed: () => BiometricService.guardActivityTransition(
              () => FileOpenService.open(file.path),
              fallbackDuration: const Duration(seconds: 120)),
        ),
        duration: const Duration(seconds: 5),
      ),
    );
    // build120：分享面板延后到 SnackBar 真正可见之后再拉起。
    // 此前是「写盘 → 立刻 share」两连发，用户在前一次分享面板还没走完时再点导出，
    // 第二次的 SnackBar 会被 clearSnackBars 顶掉、share 又被打断，
    // 于是「文件写了但没有任何反馈」= 用户体感的「没保存」。
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;
    try {
      // B-003：系统分享面板同样会切走前台，走 guard 防误锁
      await BiometricService.guardActivityTransition(
        () => Share.shareXFiles(
          [XFile(file.path)],
          subject: conv.title,
          text: conv.title,
        ),
        fallbackDuration: const Duration(seconds: 120),
      );
    } catch (e) {
      // 分享失败不阻断导出（部分 ROM 无分享目标会抛异常）
      LoggerService.instance.warn('分享导出文件失败：$e', tag: 'Export');
    }
  }

  Future<void> _createConversation() async {
    final logger = LoggerService.instance;
    logger.info('点击 新建聊天（FAB 或空态按钮）', cat: LogCat.ui, tag: 'conversation_list');
    try {
      final storage = context.read<StorageService>();
      if (!storage.isInitialized) {
        logger.info('Storage 未初始化，_createConversation 补 init()',
            cat: LogCat.db, tag: 'fallback');
        await storage.init();
      }
      List<ApiConfig> configs = List.from(_apiConfigs);
      if (configs.isEmpty) {
        // G53（build136）：这里原先落一条 **openai 假配置**
        // （ApiConfig.create() 的默认值 name='New API' /
        // baseUrl='https://api.openai.com' / model='gpt-4o-mini'）。
        // 用户从没填过 Key，却会凭空多出一个「看起来能用」的模型条目，
        // 第一条消息必然 401。改为引导去配置页选厂商；配好回来再点一次即可。
        logger.info('API configs 为空，引导去配置页', cat: LogCat.ui, tag: 'fallback');
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const ApiConfigScreen()),
        );
        if (!mounted) return;
        await _loadData();
        return;
      }
      if (configs.isEmpty) {
        throw StateError('无法创建默认 API 配置');
      }
      final conv = Conversation.create(apiConfigId: configs.first.id);
      logger.info('创建新会话 id=${conv.id} apiConfigId=${conv.apiConfigId}',
          cat: LogCat.chat, tag: 'new');
      await storage.saveConversation(conv);
      logger.info('saveConversation 成功 id=${conv.id}',
          cat: LogCat.db, tag: 'insert');
      if (mounted) await _loadData();
      if (mounted) {
        logger.nav('push → ChatScreen conv=${conv.id}');
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ChatScreen(conversation: conv),
          ),
        );
        if (mounted) await _loadData();
      }
    } catch (e, st) {
      logger.error(
        '_createConversation 失败: $e',
        error: e,
        stack: st,
        cat: LogCat.error,
        tag: 'conversation_list',
      );
      if (mounted) {
        final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
        AppSnackBar.showSnackBar(context, 
          SnackBar(
              content: Text(isZh
                  ? '新建聊天失败：${e.runtimeType} $e'
                  : 'Failed to create chat: ${e.runtimeType} $e')),
        );
      }
    }
  }

  /// v1.7.32：删除对话（带确认对话框，SlidableAction 点击触发）
  Future<void> _deleteConversation(BuildContext ctx, Conversation conv) async {
    // build86 修复：SlidableAction autoClose 会在确认弹窗期间关闭并卸载
    // action 子树，await 弹窗返回后 ctx.mounted=false → 删除被静默跳过。
    // 必须在弹窗前捕获 StorageService，弹窗改用 State 的常驻 context。
    final storage = ctx.read<StorageService>();
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(isZh ? '删除对话' : 'Delete conversation'),
        content: Text(isZh
            ? '确定要删除「${conv.title}」吗？此操作不可撤销。'
            : 'Delete "${conv.title}"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: Text(isZh ? '取消' : 'Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogCtx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: Text(isZh ? '删除' : 'Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return; // v1.7.32：await 后 context 失效保护
    final logger = LoggerService.instance;
    try {
      logger.info('删除对话开始 id=${conv.id} title=${conv.title}',
          cat: LogCat.db, tag: 'conversation_list');
      await storage.deleteConversation(conv.id);
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('chat_draft_${conv.id}');
      await _loadData();
      logger.info('删除对话完成 id=${conv.id}',
          cat: LogCat.db, tag: 'conversation_list');
    } catch (e, st) {
      logger.error('删除对话失败 id=${conv.id}: $e\n$st',
          cat: LogCat.db, tag: 'conversation_list');
      if (mounted) {
        AppSnackBar.showSnackBar(context, 
          SnackBar(content: Text(isZh ? '删除失败：$e' : 'Delete failed: $e')),
        );
      }
    }
  }

  /// v1.3.6：打开系统下载文件夹（多策略回退）
  /// build103（I3）：主页图标已删，本方法迁移至 file_management_screen（I2 复用），此处删除。

  /// build101（B1/B5/B6）：会话长按操作菜单
  Future<void> _showConvMenu(BuildContext ctx, Conversation conv) async {
    final isZh = AppLocalizations.of(ctx).locale.languageCode == 'zh';
    final action = await showModalBottomSheet<String>(
      context: ctx,
      builder: (bctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                conv.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(bctx).textTheme.titleSmall,
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: Text(isZh ? '重命名' : 'Rename'),
              onTap: () => Navigator.pop(bctx, 'rename'),
            ),
            ListTile(
              leading: Icon(conv.isPinned
                  ? Icons.push_pin_outlined
                  : Icons.push_pin),
              title: Text(conv.isPinned
                  ? (isZh ? '取消置顶' : 'Unpin')
                  : (isZh ? '置顶' : 'Pin')),
              onTap: () => Navigator.pop(bctx, 'pin'),
            ),
            ListTile(
              leading: const Icon(Icons.ios_share),
              title: Text(isZh ? '导出对话' : 'Export chat'),
              onTap: () => Navigator.pop(bctx, 'export'),
            ),
            ListTile(
              leading: Icon(conv.isArchived
                  ? Icons.unarchive_outlined
                  : Icons.archive_outlined),
              title: Text(conv.isArchived
                  ? (isZh ? '移出归档' : 'Unarchive')
                  : (isZh ? '归档' : 'Archive')),
              onTap: () => Navigator.pop(bctx, 'archive'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline,
                  color: Theme.of(bctx).colorScheme.error),
              title: Text(isZh ? '删除' : 'Delete',
                  style: TextStyle(color: Theme.of(bctx).colorScheme.error)),
              onTap: () => Navigator.pop(bctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    // build101：storage 在 await 前取出，避免跨异步 gap 用 context
    final storage = context.read<StorageService>();
    switch (action) {
      case 'rename':
        await _renameConversation(context, conv);
        break;
      case 'pin':
        await storage.togglePinConversation(conv.id, !conv.isPinned);
        await _loadData();
        break;
      case 'export':
        await _exportConversation(context, conv);
        break;
      case 'archive':
        await _toggleArchive(context, conv);
        break;
      case 'delete':
        if (mounted) await _deleteConversation(context, conv);
        break;
    }
  }

  /// build101（B8）：批量删除选中会话
  Future<void> _batchDelete() async {
    if (_selectedIds.isEmpty) return;
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    final n = _selectedIds.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text(isZh ? '删除 $n 个对话？' : 'Delete $n chat(s)?'),
        content: Text(isZh
            ? '所选对话及其全部消息将被永久删除，无法恢复。'
            : 'Selected chats and all their messages will be permanently deleted.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: Text(isZh ? '取消' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, true),
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(dctx).colorScheme.error),
            child: Text(isZh ? '删除' : 'Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final storage = context.read<StorageService>();
    for (final id in _selectedIds.toList()) {
      await storage.deleteConversation(id);
    }
    if (!mounted) return;
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
    await _loadData();
  }

  /// build101（B8）：批量归档选中会话
  Future<void> _batchArchive() async {
    if (_selectedIds.isEmpty) return;
    final storage = context.read<StorageService>();
    final target = !_showArchived;
    for (final id in _selectedIds.toList()) {
      await storage.toggleArchiveConversation(id, target);
    }
    if (!mounted) return;
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
    await _loadData();
  }

  /// build101（B8）：切换单个会话的选中状态
  void _toggleSelection(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  /// build101（B9）：取该会话所用模型的展示名（清洗后的短名）
  String _modelLabelFor(Conversation conv) {
    final cfg = _apiConfigs.where((c) => c.id == conv.apiConfigId).firstOrNull;
    if (cfg == null || cfg.model.trim().isEmpty) return '';
    return cfg.model.trim();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final isZh = l.locale.languageCode == 'zh';
    return Scaffold(
      // v1.7.18（需求6）：左滑快速抽屉
      // drawerEdgeDragWidth 扩大边缘识别区；drawerEnableOpenDragGesture 显式开启
      drawer: QuickAccessDrawer(isZh: isZh),
      // v1.7.32：边缘识别区从 20 加大到 60，手指从左缘右滑更容易打开抽屉
      drawerEdgeDragWidth: 60.0,
      drawerEnableOpenDragGesture: true,
      appBar: AppBar(
        // build101（B8）：选择模式下切换为批量操作栏
        // build102（C）：归档专用页用返回键（不再是主页，不给抽屉汉堡）
        leading: _selectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                tooltip: isZh ? '退出选择' : 'Exit selection',
                onPressed: () => setState(() {
                  _selectionMode = false;
                  _selectedIds.clear();
                }),
              )
            : (widget.showArchivedOnly
                ? const BackButton()
                : Builder(
                    builder: (ctx) => IconButton(
                      icon: const Icon(Icons.menu),
                      tooltip: isZh ? '快速菜单' : 'Quick menu',
                      onPressed: () => Scaffold.of(ctx).openDrawer(),
                    ),
                  )),
        title: Text(_selectionMode
            ? (isZh ? '已选 ${_selectedIds.length} 项' : '${_selectedIds.length} selected')
            : (_showArchived ? (isZh ? '已归档' : 'Archived') : l.tr('appTitle'))),
        // v1.7.18（决策Q1）：actions 仅留「下载文件夹」，cloud/settings 已进抽屉
        // build101：新增搜索（B2）；选择模式显示批量操作
        // build102（C）：主页「查看归档」图标移除（归档入口收进左滑抽屉「归档会话」）
        actions: _selectionMode
            ? [
                IconButton(
                  icon: const Icon(Icons.select_all),
                  tooltip: isZh ? '全选' : 'Select all',
                  onPressed: () => setState(() {
                    if (_selectedIds.length == _conversations.length) {
                      _selectedIds.clear();
                    } else {
                      _selectedIds
                        ..clear()
                        ..addAll(_conversations.map((c) => c.id));
                    }
                  }),
                ),
                IconButton(
                  icon: Icon(_showArchived
                      ? Icons.unarchive_outlined
                      : Icons.archive_outlined),
                  tooltip: _showArchived
                      ? (isZh ? '移出归档' : 'Unarchive')
                      : (isZh ? '归档' : 'Archive'),
                  onPressed: _selectedIds.isEmpty ? null : _batchArchive,
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: isZh ? '删除' : 'Delete',
                  onPressed: _selectedIds.isEmpty ? null : _batchDelete,
                ),
                IconButton(
                  icon: const Icon(Icons.checklist),
                  tooltip: isZh ? '退出选择' : 'Exit selection',
                  onPressed: () => setState(() => _selectionMode = false),
                ),
              ]
            : [
                IconButton(
                  icon: const Icon(Icons.search),
                  tooltip: isZh ? '搜索对话' : 'Search chats',
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const ConversationSearchScreen(),
                      ),
                    ).then((_) => _loadData());
                  },
                ),
                // build103（I3）：「查看归档」图标移除——归档入口统一走左滑抽屉
                // 「归档会话」（build102 C 已加 showArchivedOnly 路由），主页 actions 只留搜索/多选
                IconButton(
                  icon: const Icon(Icons.checklist),
                  tooltip: isZh ? '多选' : 'Select',
                  onPressed: () => setState(() => _selectionMode = true),
                ),
              ],
      ),
      body: _isLoading
          // build133：列表加载态改用骨架屏 —— 给出「这里将出现 N 行会话」的版式预期。
          // 转圈只说明「在转」，而且与列表内容的视觉重量差太大，切换瞬间会「跳」。
          ? const Padding(
              padding: EdgeInsets.all(12),
              child: AppSkeleton.list(count: 6),
            )
          : _conversations.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.chat_bubble_outline,
                          size: 64,
                          color: Theme.of(context).colorScheme.outline),
                      const SizedBox(height: 16),
                      Text(l.tr('noConversations'),
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      FilledButton.icon(
                        onPressed: _createConversation,
                        icon: const Icon(Icons.add),
                        label: Text(l.tr('newChat')),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _loadData,
                  child: Builder(builder: (context) {
                    // build108（Q2 一期）：主页顶小部件条作为列表第 0 项插入
                    //（不改既有 item 语义，仅加 header 偏移）
                    final widgetOffset = _widgetPlugins.isEmpty ? 0 : 1;
                    return ListView.builder(
                      itemCount: _conversations.length + widgetOffset,
                      itemBuilder: (context, index) {
                        if (widgetOffset == 1 && index == 0) {
                          return HomeWidgetStrip(plugins: _widgetPlugins);
                        }
                        // build140（反馈①）：整项再套一层 Builder，主题/语言才会跟着刷新。
                        // 实测（test/build140_lazy_list_theme_test.dart 探针 A–F）：
                        // `ListView.builder` 的 itemBuilder 收到的 context 是 SliverList
                        // **共享的那一个 element**，在这里读 Theme.of / MediaQuery.of 等于把
                        // 依赖记到共享元素上——InheritedWidget 变化时 Flutter 只把列表标脏，
                        // **已经画出来的子项不会重新 build**（只有新滚进来的才用新值）。
                        // 真机表现就是「切换颜色之后，要先点一下对话（整页重建）才把那个图标
                        // 变回应有的颜色」。套一层 Builder ⇒ 每项有自己的元素，依赖落在项上。
                        return Builder(builder: (context) {
                        final conv = _conversations[index - widgetOffset];
                      final selected = _selectedIds.contains(conv.id);
                      // v1.7.32：用 flutter_slidable 替代内置 Dismissible。
                      // 原因：Dismissible 的 onHorizontalDrag* 与 Scaffold DrawerController
                      // 边缘水平拖拽在手势竞技场互相干扰，导致右→左滑动删除经常无反应。
                      // Slidable 的 endActionPane 仅识别从右缘开始的拖拽，语义更清晰。
                      // build101（B8）：选择模式下禁用左滑（避免手势与多选冲突）
                      final tile = Card(
                        margin: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 4),
                        color: selected
                            ? Theme.of(context)
                                .colorScheme
                                .primaryContainer
                                .withValues(alpha: 0.5)
                            : null,
                        child: ListTile(
                            leading: _selectionMode
                                ? Checkbox(
                                    value: selected,
                                    onChanged: (_) => _toggleSelection(conv.id),
                                  )
                                : CircleAvatar(
                                    backgroundColor: conv.isPinned
                                        ? Theme.of(context).colorScheme.primary
                                        : Theme.of(context)
                                            .colorScheme
                                            .surfaceContainerHighest,
                                    child: Icon(
                                      conv.isPinned
                                          ? Icons.push_pin
                                          : Icons.chat_bubble_outline,
                                      color: conv.isPinned
                                          ? Theme.of(context)
                                              .colorScheme
                                              .onPrimary
                                          : Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant,
                                    ),
                                  ),
                            title: Row(
                              children: [
                                if (conv.isPinned)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 4),
                                    child: Icon(Icons.push_pin,
                                        size: 14,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary),
                                  ),
                                Expanded(
                                  child: Text(conv.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis),
                                ),
                              ],
                            ),
                            // v1.7.31：有草稿时显示草稿预览（带图标提示）
                            // build101（B9）：无草稿时，副标题右侧挂模型标签
                            subtitle: _drafts[conv.id] != null
                                ? Row(
                                    children: [
                                      Icon(Icons.edit_note,
                                          size: 14,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .tertiary),
                                      const SizedBox(width: 4),
                                      Expanded(
                                        child: Text(
                                          '${_drafts[conv.id]}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .tertiary,
                                            fontStyle: FontStyle.italic,
                                          ),
                                        ),
                                      ),
                                    ],
                                  )
                                : Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          conv.lastMessage ??
                                              l.tr('noConversations'),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      if (_modelLabelFor(conv).isNotEmpty) ...[
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets
                                              .symmetric(
                                              horizontal: 5, vertical: 1),
                                          decoration: BoxDecoration(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .surfaceContainerHighest,
                                            borderRadius:
                                                BorderRadius.circular(4),
                                          ),
                                          child: Text(
                                            _modelLabelFor(conv),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 10,
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                            // v1.7.31：置顶从左滑改为 trailing 图标按钮（避免与抽屉手势冲突）
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: Icon(
                                    conv.isPinned
                                        ? Icons.push_pin
                                        : Icons.push_pin_outlined,
                                    size: 18,
                                    color: conv.isPinned
                                        ? Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant
                                        : Theme.of(context).colorScheme.outline,
                                  ),
                                  tooltip: isZh
                                      ? (conv.isPinned ? '取消置顶' : '置顶')
                                      : (conv.isPinned ? 'Unpin' : 'Pin'),
                                  onPressed: () async {
                                    await context
                                        .read<StorageService>()
                                        .togglePinConversation(
                                            conv.id, !conv.isPinned);
                                    _loadData();
                                  },
                                ),
                                Text(
                                  '${conv.updatedAt.hour}:${conv.updatedAt.minute.toString().padLeft(2, '0')}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                            onTap: () {
                              // build101（B8）：选择模式下点按 = 切换选中
                              if (_selectionMode) {
                                _toggleSelection(conv.id);
                                return;
                              }
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) =>
                                      ChatScreen(conversation: conv),
                                ),
                              ).then((_) => _loadData());
                            },
                            // build101（B1/B5/B6）：长按弹操作菜单
                            // 选择模式下长按 = 切换选中（避免误开菜单）
                            onLongPress: () => _selectionMode
                                ? _toggleSelection(conv.id)
                                : _showConvMenu(context, conv),
                          ),
                        );
                      // build101（B8）：选择模式下不挂 Slidable（手势会与多选冲突）
                      if (_selectionMode) return tile;
                      return Slidable(
                        key: Key(conv.id),
                        // 右侧（end）操作面板：右→左滑动露出红色"删除"按钮，点击弹确认框
                        endActionPane: ActionPane(
                          motion: const ScrollMotion(),
                          extentRatio: 0.25,
                          children: [
                            SlidableAction(
                              onPressed: (ctx) =>
                                  _deleteConversation(ctx, conv),
                              backgroundColor:
                                  Theme.of(context).colorScheme.error,
                              foregroundColor:
                                  Theme.of(context).colorScheme.onError,
                              icon: Icons.delete,
                              label: isZh ? '删除' : 'Delete',
                            ),
                          ],
                        ),
                        child: tile,
                      );
                        });
                      },
                    );
                  }),
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: _createConversation,
        child: const Icon(Icons.add),
      ),
    );
  }
}
