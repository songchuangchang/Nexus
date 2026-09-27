import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../plugins/plugin_interface.dart';
import '../plugins/plugin_registry.dart';
import '../services/mcp_registry_service.dart';
import '../services/widget_plugin_service.dart';
import '../services/skill_registry_service.dart';
import '../services/skill_install_service.dart';
import '../services/skill_parser.dart';
import '../services/security_scan_service.dart';
import '../services/security_audit_log.dart';
import '../services/security_gate.dart';
import '../services/biometric_service.dart';
import '../services/storage_service.dart';
import '../widgets/mcp_headers_dialog.dart';
import '../models/mcp_market_models.dart';
import 'mcp_catalog_screen.dart';
import '../models/skill_models.dart';
import '../ui/tokens.dart';
import '../ui/app_skeleton.dart';
import '../utils/app_snackbar.dart';

/// build130：打开插件市场时**随机**落点的候选 Tab —— 公开 MCP(1) / Skill 市场(2)。
///
/// 用户要求这两个页面「保持随机性，不要一直在同一个页面」。候选集刻意**不含**
/// 内置推荐(0) 与 小部件(3)：前者是目录首页（每次都能看到会把"随机"抵消掉）、
/// 后者是本地清单，都不属于"市场"页；想回去点一下 Tab 即可。
const List<int> kMarketRandomInitialTabs = <int>[1, 2];

/// 从 [kMarketRandomInitialTabs] 里随机挑一个初始 Tab，**排除上次落点**。
///
/// 为什么不是"纯随机"：只有两个候选时，纯随机有 50% 概率连着两次落在同一页，
/// 用户观感就是"怎么又是这页、根本没生效"。传 [lastPicked] 即换另一个，
/// 既不连续重复、又保留随机性（候选变多时依然随机）。
///
/// 抽成**纯函数**而不是写在 State 里：随机的行为不该逼着测试去 pump 整个页面
/// （那样断言就变成掷骰子），这里注入 [rng] / [lastPicked] 即可确定性验证。
int pickInitialMarketTab([Random? rng, int? lastPicked]) {
  final r = rng ?? Random();
  final pool = kMarketRandomInitialTabs
      .where((t) => t != lastPicked)
      .toList(growable: false);
  // 防御：候选只剩 1 个（或 lastPicked 不在候选内导致 pool 与全集相同）时不能空转
  final candidates = pool.isEmpty ? kMarketRandomInitialTabs : pool;
  if (candidates.length == 1) return candidates.first;
  return candidates[r.nextInt(candidates.length)];
}

class PluginMarketScreen extends StatefulWidget {
  /// 打开时是否**随机**落在市场类 Tab（公开 MCP / Skill 市场）。
  ///
  /// build130（用户要求）：这两个页面「保持随机性，不要一直在同一个页面」。
  /// 默认 `true`（所有真实入口都随机）；widget 测试可传 `false` 固定在内置推荐页，
  /// 避免断言变成掷骰子（见 `test/plugin_market_screen_test.dart`）。
  final bool randomizeInitialTab;

  const PluginMarketScreen({super.key, this.randomizeInitialTab = true});

  @override
  State<PluginMarketScreen> createState() => _PluginMarketScreenState();
}

class _MarketPluginItem {
  final String id;
  final String name;
  final String version;
  final String author;
  final String description;
  final List<String> tags;
  final String homepage;
  final String promptProtocol;
  final String iconEmoji;

  const _MarketPluginItem({
    required this.id,
    required this.name,
    required this.version,
    required this.author,
    required this.description,
    required this.tags,
    required this.homepage,
    required this.promptProtocol,
    this.iconEmoji = '',
  });
}

class _PluginMarketScreenState extends State<PluginMarketScreen> {
  static const _catalog = [
    _MarketPluginItem(
      id: 'nexus.market.translator',
      name: 'AI 实时翻译助手',
      version: '1.0.1',
      author: 'Nexus Team',
      description: '聊天中输入"翻译：XXX"或"translate: XXX"时，AI 直接输出译文，支持 20+ 语言互译。',
      iconEmoji: '',
      tags: ['官方', '翻译', '多语言'],
      homepage: 'https://nexus.local/plugins/translator',
      promptProtocol: '【翻译工具】当用户请求翻译内容时，直接用 <answer> 标签输出翻译结果。',
    ),
    _MarketPluginItem(
      id: 'nexus.market.calculator',
      name: '超级计算器',
      version: '1.0.2',
      author: 'Nexus Team',
      description: '遇到数学/金融/统计/单位换算问题时，AI 直接心算给出结果。',
      iconEmoji: '🧮',
      tags: ['官方', '工具', '数学'],
      homepage: 'https://nexus.local/plugins/calc',
      promptProtocol: '【计算器工具】当用户需要计算时，用 <answer> 标签输出结果和简要过程。',
    ),
    _MarketPluginItem(
      id: 'nexus.market.weather',
      name: '实时天气查询',
      version: '1.0.3',
      author: 'Community',
      description: '当用户问天气时，AI 自动联网搜索实时天气并整理回复。',
      iconEmoji: '🌤️',
      tags: ['社区', '天气', 'LBS'],
      homepage: 'https://nexus.local/plugins/weather',
      promptProtocol: '【天气工具】当用户询问天气时，使用 <search> 查找最新天气信息。',
    ),
  ];

  final _searchCtrl = TextEditingController();
  final _registryService = McpRegistryService();
  String _query = '';
  // build130：初始 Tab 由 widget 决定（默认随机落在公开 MCP / Skill 市场，
  // 见 [pickInitialMarketTab]）；0 只是占位，initState 里会按需覆盖。
  int _tab = 0;

  /// 上一次随机落点（进程内记忆，跨实例共享）——保证下次不落在同一页，
  /// 否则"随机"会表现为连续两次同一页，看起来像没生效。
  static int? _lastRandomTab;
  McpRegistryPage? _mcpPage;
  Object? _mcpError;
  bool _loading = false;
  bool _loadingMore = false;

  // Skill 市场状态
  List<SkillMarketItem> _skills = [];
  Object? _skillError;
  bool _loadingSkills = false;
  // ===== build113（WP-1）：小部件 Tab 状态 =====
  List<WidgetPluginManifest> _widgets = [];
  bool _loadingWidgets = false;

  // 搜索防抖与请求序列号，防止旧响应覆盖新结果
  Timer? _searchDebounce;
  int _searchSeq = 0;

  /// B-019：公开 MCP 列表请求在途时又被触发搜索时置位——finally 里按最新
  /// query 再拉一次。旧实现直接 `if (_loading) return;` 把新关键词的请求丢掉，
  /// 而旧响应又被 seq 守卫丢弃，列表就停在前一个关键词的结果上。
  bool _mcpReloadPending = false;

  @override
  void initState() {
    // build130：随机初始页（用户要求「不要一直在同一个页面」），且不与上次重复。
    // 放在 super.initState 之前/之后都无副作用，这里保持与原顺序一致。
    if (widget.randomizeInitialTab) {
      _tab = pickInitialMarketTab(null, _lastRandomTab);
      _lastRandomTab = _tab;
    }
    _loadWidgets();
    super.initState();
    _loadMcp();
    _loadSkills();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    _registryService.close();
    super.dispose();
  }

  Future<void> _loadMcp({bool refresh = false}) async {
    final seq = _searchSeq;
    if (_loading || _loadingMore) {
      // B-019：飞行中不丢弃请求——标记 pending，本次结束后按最新 _query 重拉，
      // 保证「最后一次用户输入一定对应一次请求」（与 _loadSkills 行为对齐）。
      _mcpReloadPending = true;
      return;
    }
    setState(() {
      _loading = true;
      if (refresh) _mcpError = null;
    });
    try {
      final page = await _registryService.fetchPage(
        search: _query,
        allowCacheFallback: true,
      );
      if (!mounted || _searchSeq != seq) return;
      setState(() {
        _mcpPage = page;
        _mcpError = null;
      });
    } catch (error) {
      if (!mounted || _searchSeq != seq) return;
      setState(() => _mcpError = error);
    } finally {
      if (mounted) setState(() => _loading = false);
      // B-019：补拉在途期间被丢弃的那次搜索
      if (_mcpReloadPending) {
        _mcpReloadPending = false;
        if (mounted) unawaited(_loadMcp());
      }
    }
  }

  Future<void> _loadMore() async {
    final page = _mcpPage;
    if (_loadingMore || page?.nextCursor == null) return;
    setState(() => _loadingMore = true);
    try {
      final next = await _registryService.fetchPage(
        cursor: page!.nextCursor,
        search: _query,
        allowCacheFallback: false,
      );
      if (mounted) {
        setState(() => _mcpPage = McpRegistryPage(
              servers: [...page.servers, ...next.servers],
              nextCursor: next.nextCursor,
              fromCache: page.fromCache,
              cachedAt: page.cachedAt,
            ));
      }
    } catch (error) {
      if (mounted) {
        final isZh = Localizations.localeOf(context).languageCode == 'zh';
        _showMessage(
            isZh ? '加载下一页失败：$error' : 'Failed to load next page: $error',
            error: true);
      }
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _loadSkills() async {
    final seq = _searchSeq;
    setState(() {
      _loadingSkills = true;
      _skillError = null;
    });
    try {
      final skills = await SkillRegistryService.fetchSkills(search: _query);
      if (!mounted || _searchSeq != seq) return;
      setState(() {
        _skills = skills;
        _skillError = null;
      });
    } catch (error) {
      if (!mounted || _searchSeq != seq) return;
      setState(() => _skillError = error);
    } finally {
      if (mounted && _searchSeq == seq) setState(() => _loadingSkills = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final registry = context.watch<PluginRegistry>();
    return DefaultTabController(
      length: 4,
      initialIndex: _tab,
      child: Scaffold(
        appBar: AppBar(
          title: Text(isZh ? '插件市场 / Plugin Market' : 'Plugin Market / 插件市场'),
          actions: [
            // build104（M1）：推荐连接器目录
            IconButton(
              tooltip: isZh ? '推荐连接器' : 'Recommended connectors',
              icon: const Icon(Icons.extension_outlined),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const McpCatalogScreen()),
              ),
            ),
            IconButton(
              tooltip: isZh ? '本地导入' : 'Local Import',
              icon: const Icon(Icons.upload_file_outlined),
              onPressed: () => _importLocalPlugin(registry, isZh),
            ),
          ],
          bottom: TabBar(
            isScrollable: true,
            onTap: (value) => setState(() => _tab = value),
            tabs: [
              Tab(text: isZh ? '内置推荐' : 'Built-in'),
              Tab(text: isZh ? '公开 MCP' : 'Public MCP'),
              Tab(text: isZh ? 'Skill 市场' : 'Skill Market'),
              Tab(text: isZh ? '小部件' : 'Widgets'),
            ],
          ),
        ),
        body: _tab == 0
            ? _buildBuiltin(context, registry, isZh)
            : _tab == 1
                ? _buildMcp(context, registry, isZh)
                : _tab == 2
                    ? _buildSkills(context, registry, isZh)
                    : _buildWidgets(context, isZh),
      ),
    );
  }

  // ===== build113（WP-1~4）：小部件 Tab =====
  // E-4（远程目录）暂未拍板，先展示「已装清单 + 本地导入」；
  // 安装链与粘贴入口同源：全部走 WidgetPluginService.add（内含
  // SecurityGate.auditUrl + Manifest 全约束），UI 层不绕过。
  Future<void> _loadWidgets() async {
    if (_loadingWidgets) return;
    _loadingWidgets = true;
    final list = await WidgetPluginService.load();
    if (mounted) setState(() => _widgets = list);
    _loadingWidgets = false;
  }

  Widget _buildWidgets(BuildContext context, bool isZh) {
    return _withSearch(
      context,
      isZh,
      Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    isZh
                        ? '已装 ${_widgets.length} 个 · 与主页顶部小部件条共用同一安装链'
                        : '${_widgets.length} installed · same pipeline as home strip',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => _importWidgetJson(isZh),
                  icon: const Icon(Icons.paste, size: 16),
                  label: Text(isZh ? '粘贴 manifest 安装' : 'Paste manifest'),
                ),
              ],
            ),
          ),
          Expanded(
            child: _widgets.isEmpty
                ? ListView(children: [
                    const SizedBox(height: 200),
                    Center(
                      child: Text(
                        isZh
                            ? '尚未安装任何小部件\n点上方「粘贴 manifest 安装」或到小部件页导入'
                            : 'No widgets installed\nPaste a manifest to install',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ])
                : RefreshIndicator(
                    onRefresh: _loadWidgets,
                    child: ListView.separated(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                      itemCount: _widgets.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (_, i) => _widgetCard(_widgets[i], isZh),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _widgetCard(WidgetPluginManifest p, bool isZh) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.dashboard_outlined, size: 18, color: cs.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('${p.name}  v${p.version}',
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600)),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: cs.primaryContainer.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(isZh ? '已安装' : 'Installed',
                      style: TextStyle(fontSize: 11, color: cs.onSurface)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(p.description,
                style: Theme.of(context).textTheme.bodySmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
            const SizedBox(height: 4),
            Text(
              '${p.sourceUrl}\n'
              '${isZh ? '刷新' : 'Refresh'}: ${p.refreshMinutes}min · '
              '${isZh ? '字段' : 'Fields'}: ${p.fields.length}',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: cs.onSurfaceVariant, fontFamily: 'monospace'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: Text(isZh
                            ? '卸载「${p.name}」？'
                            : 'Uninstall "${p.name}"?'),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: Text(isZh ? '取消' : 'Cancel')),
                          FilledButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: Text(isZh ? '卸载' : 'Uninstall')),
                        ],
                      ),
                    );
                    if (ok != true) return;
                    await WidgetPluginService.remove(p.id);
                    if (mounted) {
                      AppSnackBar.showSnackBar(
                        context,
                        SnackBar(
                          content: Text(isZh
                              ? '已卸载「${p.name}」'
                              : 'Uninstalled "${p.name}"'),
                          behavior: SnackBarBehavior.floating,
                          duration: const Duration(seconds: 2),
                        ),
                      );
                      _loadWidgets();
                    }
                  },
                  child: Text(isZh ? '卸载' : 'Uninstall',
                      style: TextStyle(color: cs.error)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// WP-2：市场安装入口收敛——与 widget_plugin_screen 粘贴导入同链路
  /// （解析 → WidgetPluginService.add 审查落盘），重复 id = 覆盖安装。
  Future<void> _importWidgetJson(bool isZh) async {
    final ctrl = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isZh ? '粘贴小部件 manifest' : 'Paste widget manifest'),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: ctrl,
            maxLines: 10,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: InputDecoration(
              hintText: '{"id": "community.weather_card", ...}',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: const Icon(Icons.paste),
                tooltip: isZh ? '从剪贴板粘贴' : 'Paste from clipboard',
                onPressed: () async {
                  final data = await Clipboard.getData('text/plain');
                  if (data?.text != null) ctrl.text = data!.text!;
                },
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(isZh ? '取消' : 'Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: Text(isZh ? '安装' : 'Install')),
        ],
      ),
    );
    ctrl.dispose();
    if (raw == null || raw.isEmpty || !mounted) return;

    if (raw.length > WidgetPluginManifest.maxManifestChars) {
      AppSnackBar.showSnackBar(
          context,
          SnackBar(
              content:
                  Text(isZh ? 'manifest 超过 16KB 上限' : 'Manifest exceeds 16KB'),
              behavior: SnackBarBehavior.floating));
      return;
    }
    WidgetPluginManifest manifest;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        AppSnackBar.showSnackBar(
            context,
            SnackBar(
                content: Text(isZh
                    ? 'manifest 顶层必须是 JSON 对象'
                    : 'Manifest must be a JSON object'),
                behavior: SnackBarBehavior.floating));
        return;
      }
      manifest =
          WidgetPluginManifest.fromJson(Map<String, dynamic>.from(decoded));
    } catch (e) {
      AppSnackBar.showSnackBar(
          context,
          SnackBar(
              content: Text('${isZh ? "格式不合法" : "Invalid format"}: $e'),
              behavior: SnackBarBehavior.floating));
      return;
    }
    final err = await WidgetPluginService.add(manifest);
    if (!mounted) return;
    if (err != null) {
      // WP-2：非法 manifest 拒绝且给可见提示
      AppSnackBar.showSnackBar(
          context,
          SnackBar(
              content: Text(err), behavior: SnackBarBehavior.floating));
      return;
    }
    AppSnackBar.showSnackBar(
        context,
        SnackBar(
            content: Text(isZh
                ? '已安装「${manifest.name}」'
                : 'Installed "${manifest.name}"'),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2)));
    _loadWidgets();
  }


  Widget _buildBuiltin(
      BuildContext context, PluginRegistry registry, bool isZh) {
    final query = _query.toLowerCase().trim();
    final shown = _catalog
        .where((item) =>
            query.isEmpty ||
            item.name.toLowerCase().contains(query) ||
            item.description.toLowerCase().contains(query) ||
            item.tags.any((tag) => tag.toLowerCase().contains(query)))
        .toList();
    return _withSearch(
      context,
      isZh,
      ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 96),
        itemCount: shown.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, index) =>
            _builtinCard(context, shown[index], registry, isZh),
      ),
    );
  }

  Widget _buildMcp(BuildContext context, PluginRegistry registry, bool isZh) {
    final page = _mcpPage;
    final content = _loading && page == null
        // build133：市场列表首屏加载用骨架（MCP 服务器行的形状可预知）。
        ? const Padding(
            padding: EdgeInsets.all(12),
            child: AppSkeleton.list(count: 5),
          )
        : _mcpError != null && page == null
            ? _errorView(isZh)
            : RefreshIndicator(
                onRefresh: () => _loadMcp(refresh: true),
                child: page == null || page.servers.isEmpty
                    ? ListView(children: [
                        const SizedBox(height: 220),
                        Center(
                            child: Text(isZh
                                ? '没有可用的公开 MCP 服务'
                                : 'No compatible public MCP servers'))
                      ])
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(12, 6, 12, 96),
                        itemCount: page.servers.length +
                            (page.nextCursor == null ? 0 : 1),
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (_, index) {
                          if (index == page.servers.length) {
                            return Center(
                                child: _loadingMore
                                    ? const CircularProgressIndicator()
                                    : OutlinedButton.icon(
                                        onPressed: _loadMore,
                                        icon: const Icon(Icons.expand_more),
                                        label: Text(
                                            isZh ? '加载下一页' : 'Load More')));
                          }
                          return _mcpCard(
                              context, page.servers[index], registry, isZh);
                        },
                      ),
              );
    return _withSearch(
        context,
        isZh,
        Column(children: [
          if (page?.fromCache == true) _cacheBanner(page!, isZh),
          Expanded(child: content)
        ]));
  }

  Widget _buildSkills(
      BuildContext context, PluginRegistry registry, bool isZh) {
    final content = _loadingSkills
        ? const Center(child: CircularProgressIndicator())
        : _skillError != null
            ? _skillErrorView(isZh)
            : RefreshIndicator(
                onRefresh: _loadSkills,
                child: _skills.isEmpty
                    ? ListView(children: [
                        const SizedBox(height: 220),
                        Center(
                            child: Text(
                                isZh ? '没有可用的 Skill' : 'No skills available'))
                      ])
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(12, 6, 12, 96),
                        itemCount: _skills.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (_, index) =>
                            _skillCard(context, _skills[index], registry, isZh),
                      ),
              );
    return _withSearch(context, isZh, Expanded(child: content));
  }

  Widget _withSearch(BuildContext context, bool isZh, Widget child) =>
      Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText:
                    isZh ? '搜索名称 / 标签 / 描述' : 'Search name / tag / description',
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                contentPadding: const EdgeInsets.symmetric(vertical: 0)),
            onChanged: (value) {
              setState(() => _query = value);
              _searchDebounce?.cancel();
              _searchDebounce = Timer(const Duration(milliseconds: 300), () {
                _searchSeq++;
                if (_tab == 1) _loadMcp();
                if (_tab == 2) _loadSkills();
              });
            },
          ),
        ),
        if (child is Expanded) child else Expanded(child: child),
      ]);

  Widget _cacheBanner(McpRegistryPage page, bool isZh) {
    final cs = Theme.of(context).colorScheme;
    return Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: cs.appPanelLight,
          border: Border(bottom: BorderSide(color: cs.appBorder)),
        ),
        padding: const EdgeInsets.all(8),
        child: Text(
            isZh
                ? '当前显示缓存（${page.cachedAt?.toLocal()}），下拉可刷新'
                : 'Showing cached results (${page.cachedAt?.toLocal()}); pull to refresh',
            style: const TextStyle(fontSize: 12)));
  }

  Widget _errorView(bool isZh) => Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.cloud_off,
            size: 48, color: Theme.of(context).colorScheme.appTextSub),
        const SizedBox(height: 8),
        Text(isZh ? '公开 MCP 加载失败' : 'Public MCP loading failed'),
        const SizedBox(height: 8),
        FilledButton.icon(
            onPressed: _loadMcp,
            icon: const Icon(Icons.refresh),
            label: Text(isZh ? '重试' : 'Retry'))
      ]));

  Widget _skillErrorView(bool isZh) => Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.cloud_off,
            size: 48, color: Theme.of(context).colorScheme.appTextSub),
        const SizedBox(height: 8),
        Text(isZh ? 'Skill 市场加载失败' : 'Skill market loading failed'),
        const SizedBox(height: 8),
        FilledButton.icon(
            onPressed: _loadSkills,
            icon: const Icon(Icons.refresh),
            label: Text(isZh ? '重试' : 'Retry'))
      ]));

  Widget _builtinCard(BuildContext context, _MarketPluginItem item,
      PluginRegistry registry, bool isZh) {
    final cs = Theme.of(context).colorScheme;
    final installed =
        registry.plugins.any((plugin) => plugin.metadata.id == item.id);
    return Card(
        elevation: 0,
        color: cs.appPanelLight,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
          side: BorderSide(color: cs.appBorder),
        ),
        child: Padding(
            padding: const EdgeInsets.all(12),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading:
                      Icon(Icons.extension, size: 28, color: cs.appTextSub),
                  title: Text(item.name),
                  subtitle: Text('v${item.version} · ${item.author}')),
              Text(item.description,
                  maxLines: 3, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 8),
              Wrap(
                  spacing: 4,
                  children: item.tags
                      .map((tag) => Chip(
                          label: Text(tag),
                          visualDensity: VisualDensity.compact))
                      .toList()),
              Row(children: [
                OutlinedButton.icon(
                    onPressed: () => _showBuiltinDetails(context, item, isZh),
                    icon: const Icon(Icons.info_outline),
                    label: Text(isZh ? '详情' : 'Details')),
                const Spacer(),
                FilledButton.icon(
                    onPressed: installed
                        ? null
                        : () => _installBuiltin(item, registry, isZh),
                    icon: Icon(installed ? Icons.check : Icons.install_mobile),
                    label: Text(installed ? '已安装' : '安装'))
              ]),
            ])));
  }

  Widget _mcpCard(BuildContext context, McpRegistryServer server,
      PluginRegistry registry, bool isZh) {
    final cs = Theme.of(context).colorScheme;
    final installed =
        registry.plugins.any((plugin) => plugin.metadata.id == server.name);
    return Card(
        elevation: 0,
        color: cs.appPanelLight,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
          side: BorderSide(color: cs.appBorder),
        ),
        child: ListTile(
            contentPadding: const EdgeInsets.all(12),
            leading: CircleAvatar(
                backgroundColor: cs.appPanel,
                child: Icon(Icons.hub_outlined, color: cs.appTextSub)),
            title: Text(server.title),
            subtitle: Text(
                '${server.name}\nv${server.version} · ${server.transportType} · ${server.endpoint.host}\n${server.description}',
                maxLines: 4,
                overflow: TextOverflow.ellipsis),
            isThreeLine: true,
            trailing: FilledButton(
                onPressed: installed
                    ? null
                    : () => _installMcp(server, registry, isZh),
                child: Text(installed ? '已安装' : '安装')),
            onTap: () => _showMcpDetails(context, server, registry, isZh)));
  }

  Widget _skillCard(BuildContext context, SkillMarketItem skill,
      PluginRegistry registry, bool isZh) {
    // v1.7.9 (M12 修复)：与安装流程用同一 ID 算法（ParsedSkill.pluginIdFor）
    // 之前卡片本地拼 ID、安装用 SKILL.md 解析的 name 拼 → 不一致时装完仍显示可安装
    final pluginId = ParsedSkill.pluginIdFor(skill.name);
    final installed =
        registry.plugins.any((plugin) => plugin.metadata.id == pluginId);
    // build138（甲4）：`SkillMarketItem.installCount`（skill_models.dart:90，
    // skills.sh 返回的安装量）此前**只解析不渲染** ⇒ 市场里所有 Skill 看起来一样
    // 「没人用」，用户没法按热度判断。为 0 / 缺失时整段不出现（不写「0 人安装」）。
    final installs = (skill.installCount ?? 0) > 0
        ? (isZh ? ' · ${skill.installCount} 人在用' : ' · ${skill.installCount} installs')
        : '';
    final cs = Theme.of(context).colorScheme;
    return Card(
        elevation: 0,
        color: cs.appPanelLight,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
          side: BorderSide(color: cs.appBorder),
        ),
        child: ListTile(
            contentPadding: const EdgeInsets.all(12),
            leading: CircleAvatar(
                backgroundColor: cs.appPanel,
                child: Icon(Icons.auto_awesome, color: cs.appTextSub)),
            title: Text(skill.name),
            subtitle: Text(
                '${skill.description}\n\n${skill.author ?? "Unknown"}${skill.version != null ? " · v${skill.version}" : ""}$installs',
                maxLines: 3,
                overflow: TextOverflow.ellipsis),
            isThreeLine: true,
            trailing: FilledButton(
                onPressed: installed
                    ? null
                    : () => _installSkill(skill, registry, isZh),
                child: Text(installed ? '已安装' : '安装')),
            onTap: () => _showSkillDetails(context, skill, registry, isZh)));
  }

  void _showBuiltinDetails(
          BuildContext context, _MarketPluginItem item, bool isZh) =>
      showDialog(
          context: context,
          builder: (_) => AlertDialog(
                  title: Text('${item.iconEmoji} ${item.name}'),
                  content: Text(isZh
                      ? '${item.description}\n\n${item.promptProtocol}\n\n版本：${item.version}\n作者：${item.author}'
                      : '${item.description}\n\n${item.promptProtocol}\n\nVersion: ${item.version}\nAuthor: ${item.author}'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(isZh ? '关闭' : 'Close'))
                  ]));

  void _showMcpDetails(BuildContext context, McpRegistryServer server,
      PluginRegistry registry, bool isZh) {
    // v1.7.2 安全改进：增强安装警告，显示源码仓库和维护者信息
    final hasHomepage = server.homepage != null;
    final homepageInfo = hasHomepage
        ? (isZh ? '源码仓库：${server.homepage}\n' : 'Source: ${server.homepage}\n')
        : (isZh
            ? '源码仓库：未知（无法审查代码）\n'
            : 'Source: Unknown (cannot audit code)\n');

    showDialog(
        context: context,
        builder: (_) => AlertDialog(
                title: Text(server.title),
                content: SingleChildScrollView(
                    child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(isZh
                        ? 'Registry 状态：${server.status}\n版本：${server.version}\n传输：${server.transportType}\nEndpoint：${server.endpoint.host}\n\n$homepageInfo\n${server.description}\n\n⚠️ 安全提示：\n• 仅支持公开 HTTPS 远程服务\n• 安装时会连接服务并读取工具清单\n• 不会下载或执行第三方代码\n• 请确认你信任此服务及其返回的数据'
                        : 'Registry Status: ${server.status}\nVersion: ${server.version}\nTransport: ${server.transportType}\nEndpoint: ${server.endpoint.host}\n\n$homepageInfo\n${server.description}\n\n⚠️ Security Notice:\n• Only public HTTPS remote services are supported\n• Installation connects to the service and reads the tool list\n• No third-party code is downloaded or executed\n• Only continue if you trust this service and its data'),
                  ],
                )),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(isZh ? '关闭' : 'Close')),
                  FilledButton(
                      onPressed: registry.plugins
                              .any((p) => p.metadata.id == server.name)
                          ? null
                          : () {
                              Navigator.pop(context);
                              _installMcp(server, registry, isZh);
                            },
                      child: Text(isZh ? '安装' : 'Install'))
                ]));
  }

  void _showSkillDetails(BuildContext context, SkillMarketItem skill,
      PluginRegistry registry, bool isZh) {
    final hasHomepage = skill.homepage != null && skill.homepage!.isNotEmpty;
    // build138（甲4）：详情里同样带上安装量（缺失/0 时不出现）
    final installsSuffix = (skill.installCount ?? 0) > 0
        ? (isZh
            ? ' · ${skill.installCount} 人在用'
            : ' · ${skill.installCount} installs')
        : '';
    final homepageInfo = hasHomepage
        ? (isZh ? '源码仓库：${skill.homepage}\n' : 'Source: ${skill.homepage}\n')
        : (isZh
            ? '源码仓库：未知（无法审查代码）\n'
            : 'Source: Unknown (cannot audit code)\n');

    showDialog(
        context: context,
        builder: (_) => AlertDialog(
                title: Text(skill.name),
                content: SingleChildScrollView(
                    child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(isZh
                        ? '版本：${skill.version ?? "Unknown"}\n作者：${skill.author ?? "Unknown"}$installsSuffix\n\n$homepageInfo\n${skill.description}\n\n⚠️ 安全提示：\n• Skill 是 Markdown 格式的指令文件\n• 安装后会作为 AI 的提示词协议\n• 不会下载或执行第三方代码\n• 请确认你信任此 Skill 的内容'
                        : 'Version: ${skill.version ?? "Unknown"}\nAuthor: ${skill.author ?? "Unknown"}$installsSuffix\n\n$homepageInfo\n${skill.description}\n\n⚠️ Security Notice:\n• Skills are Markdown-format instruction files\n• After installation, they serve as AI prompt protocols\n• No third-party code is downloaded or executed\n• Only continue if you trust this skill\'s content'),
                  ],
                )),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(isZh ? '关闭' : 'Close')),
                  FilledButton(
                      onPressed: () {
                        Navigator.pop(context);
                        _installSkill(skill, registry, isZh);
                      },
                      child: Text(isZh ? '安装' : 'Install'))
                ]));
  }

  Future<void> _installMcp(
      McpRegistryServer server, PluginRegistry registry, bool isZh,
      {bool strictReject = false,
      Map<String, String>? presetHeaders}) async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
                title: Text(isZh ? '确认连接并安装？' : 'Connect and install?'),
                content: Text(isZh
                    ? '将连接 ${server.endpoint.host}，发现工具并保存远程配置。请确认你信任此服务及其返回的数据。'
                    : 'Nexus will connect to ${server.endpoint.host}, discover tools, and save the remote configuration. Only continue if you trust this service.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: Text(isZh ? '取消' : 'Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: Text(isZh ? '确认' : 'Confirm'))
                ]));
    if (confirmed != true || !mounted) return;

    // v1.7.37（待办⑬）：registry JSON 声明了鉴权 header 时，安装前引导用户填真实凭据。
    // 最小 hook：仅弹共享编辑对话框并把结果传给 installRemoteMcp，不动其余安装流程。
    Map<String, String>? customHeaders;
    if (server.headerSpecs.isNotEmpty) {
      final headers = await showMcpHeadersEditorDialog(
        context,
        // B-029：本地 mcp.json 里已写的明文凭据作为初始值带进编辑框，
        // 用户确认即可（此前本地导入路径连框都不弹，凭据被整段丢弃）。
        initial: presetHeaders ?? const {},
        specs: server.headerSpecs,
        isInstall: true,
      );
      if (!mounted) return;
      if (headers == null) {
        _showMessage(isZh ? '已取消安装' : 'Installation cancelled', error: true);
        return;
      }
      customHeaders = headers;
    } else if (presetHeaders != null && presetHeaders.isNotEmpty) {
      // B-029：目录未声明 headerSpecs 但本地文件带了凭据时，直接采用
      customHeaders = presetHeaders;
    }

    // build98：安全审查统一入口 SecurityGate——URL/域名审查（http/黑名单硬拒，
    // 不允许跳过）→ 本地规则扫描 → 可选 SkillSpector 深扫，合并一份报告
    var forceConfirmEveryCall = false;
    try {
      final storage = context.read<StorageService>();
      final cfg = await storage.getWebSearchConfig();
      if (!mounted) return;

      final report = await SecurityGate.scanMcp(
        serverName: server.name,
        endpoint: server.endpoint.toString(),
        toolsJson: jsonEncode({
          'server_name': server.name,
          'endpoint': server.endpoint.toString(),
          'transport': server.transportType,
          'description': server.description,
        }),
        cfg: cfg,
        envKeys: server.headerSpecs.map((h) => h.name).toList(),
      );
      if (!mounted) return;

      // URL/黑名单硬拦截：无确认通道
      if (report.blocked) {
        await SecurityAuditLog.record(
            type: 'reject',
            target: server.name,
            outcome: 'blocked',
            detail: report.blockReason);
        _showMessage(
            isZh
                ? '已拒绝安装：${report.blockReason}'
                : 'Installation rejected: ${report.blockReason}',
            error: true);
        return;
      }

      if (report.unsafe) {
        final merged = SecurityScanResult(
          success: true,
          riskScore: report.riskScore,
          severity: report.severity,
          safeToInstall: false,
          findings: report.findings,
        );
        final scanConfirmed = await _showSecurityScanDialog(
            merged, server.name, isZh,
            isLocal: true);
        // 本地导入（strictReject）：扫描不过直接拒绝，不允许用户跳过
        if (strictReject || !scanConfirmed) {
          _showMessage(
              strictReject
                  ? (isZh
                      ? '安全扫描未通过，已拒绝安装'
                      : 'Security scan failed; installation rejected')
                  : (isZh ? '已取消安装' : 'Installation cancelled'),
              error: true);
          return;
        }
      }

      // build98（本地加强④）：凭据类字段明文存储提示
      if (report.sensitiveKeys.isNotEmpty) {
        _showMessage(
            isZh
                ? '🔑 凭据字段（${report.sensitiveKeys.join(', ')}）将以明文存储在本机'
                : '🔑 Credential fields (${report.sensitiveKeys.join(', ')}) will be stored in plaintext locally');
      }
      forceConfirmEveryCall = report.forceConfirmEveryCall;
    } catch (e) {
      // 审查失败不阻止安装，只记录日志
      debugPrint('MCP security scan failed: $e');
    }

    _showMessage(isZh ? '正在连接并发现工具…' : 'Connecting and discovering tools…');
    try {
      // build155（第 13 轮 P1-1）：显式安装动作 → 显式启用；
      // installRemoteMcp 现在默认「沿用该 id 已有开关」（更新场景），不传就会保留停用态。
      await registry.installRemoteMcp(server,
          customHeaders: customHeaders,
          forceConfirmEveryCall: forceConfirmEveryCall,
          enable: true);
      await SecurityAuditLog.record(
          type: 'install',
          target: server.name,
          outcome: 'pass',
          detail: 'endpoint=${server.endpoint.host}');
      _showMessage(isZh ? '安装成功，已启用。' : 'Installed and enabled.');
    } catch (error) {
      _showMessage(isZh ? '安装失败：$error' : 'Installation failed: $error',
          error: true);
    }
  }

  Future<void> _installBuiltin(
      _MarketPluginItem item, PluginRegistry registry, bool isZh) async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
                title:
                    Text(isZh ? '确认安装 ${item.name}？' : 'Install ${item.name}?'),
                content: Text(item.promptProtocol),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: Text(isZh ? '取消' : 'Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: Text(isZh ? '安装' : 'Install'))
                ]));
    if (confirmed != true) return;
    final metadata = PluginMetadata(
        id: item.id,
        name: item.name,
        version: item.version,
        author: item.author,
        description: item.description,
        homepage: item.homepage,
        promptProtocol: item.promptProtocol,
        tags: item.tags);
    await registry.installDeclarative(metadata, enable: true);
    if (mounted) _showMessage(isZh ? '安装成功，已启用。' : 'Installed and enabled.');
  }

  Future<void> _installSkill(
      SkillMarketItem skill, PluginRegistry registry, bool isZh) async {
    // v1.7.36：安装过程改为带阶段 + 百分比的进度对话框（替代底部一闪而过的提示）
    final progress = ValueNotifier<double>(0.05);
    final stage =
        ValueNotifier<String>(isZh ? '正在下载 Skill...' : 'Downloading skill...');
    var dialogOpen = true;
    // B-021：记录弹窗自己的 context，供 closeDialog 使用（不再依赖 State.mounted）。
    BuildContext? dialogCtxRef;
    // ignore: unawaited_futures
    showDialog(
      context: context,
      // B-021：显式挂到**页面自己的** Navigator 上（默认 useRootNavigator:true 会挂
      // 到根导航器）——否则安装途中退出市场页时，弹窗不随路由销毁，而 closeDialog
      // 又被 `mounted` 挡住永不 pop，配合 barrierDismissible:false + PopScope 双锁
      // 形成永久挡屏的死弹窗，只能杀 App。
      useRootNavigator: false,
      barrierDismissible: false,
      builder: (dialogCtx) {
        dialogCtxRef = dialogCtx;
        return PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text(isZh ? '安装 Skill' : 'Installing Skill'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ValueListenableBuilder<double>(
                valueListenable: progress,
                builder: (_, v, __) => LinearProgressIndicator(value: v),
              ),
              const SizedBox(height: 12),
              ValueListenableBuilder<double>(
                valueListenable: progress,
                builder: (_, v, __) => Text('${(v * 100).round()}%'),
              ),
              const SizedBox(height: 4),
              ValueListenableBuilder<String>(
                valueListenable: stage,
                builder: (_, s, __) =>
                    Text(s, style: const TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
      );
      },
    ).then((_) => dialogOpen = false);
    void closeDialog() {
      if (!dialogOpen) return;
      // B-021：用弹窗自身的 context 关闭，不看 State.mounted（页面退出后
      // mounted=false 会让弹窗永远关不掉）。
      final ctx = dialogCtxRef;
      if (ctx != null && ctx.mounted) {
        Navigator.of(ctx).pop();
      }
      dialogOpen = false;
    }

    try {
      // v1.7.9 (M10 修复)：下载前缓存 storage（await 后 context.read 会因页面退出崩溃）
      final storage = context.read<StorageService>();

      // v1.7.18（需求1）：下载前读 WebSearchConfig，取 githubProxyUrl 传给下载咽喉
      // （与 APP 下载同源；此处读到后整方法复用，避免 L701 重复读取）
      final cfg = await storage.getWebSearchConfig();
      if (!mounted) {
        closeDialog();
        return;
      }

      // 下载 SKILL.md 内容（v1.7.18：接代理 + 30s + 代理失败回退直连）
      final content = await SkillRegistryService.downloadSkillContent(
        skill.downloadUrl,
        proxyUrl: cfg.githubProxyUrl,
      );
      if (!mounted) {
        closeDialog();
        return;
      }
      progress.value = 0.4;
      stage.value = isZh ? '解析 SKILL.md...' : 'Parsing SKILL.md...';

      // 解析 SKILL.md
      final parsedSkill = SkillParser.parse(content);

      // 生成 plugin id
      final pluginId = parsedSkill.pluginId;

      // 检查是否已安装
      if (registry.plugins.any((p) => p.metadata.id == pluginId)) {
        closeDialog();
        _showMessage(isZh ? '此 Skill 已安装' : 'This skill is already installed',
            error: true);
        return;
      }
      progress.value = 0.55;
      stage.value = isZh ? '本地安全扫描...' : 'Local security scan...';

      // build98：安全审查统一入口 SecurityGate（URL 硬拒 → 本地规则 → 可选远程深扫）
      progress.value = 0.7;
      stage.value = isZh ? '远程安全审查...' : 'Remote security scan...';
      final gateReport = await SecurityGate.scanSkill(
        skillContent: content,
        skillName: skill.name,
        sourceUrl: skill.downloadUrl,
        cfg: cfg,
      );
      if (!mounted) {
        closeDialog();
        return;
      }

      // URL/黑名单硬拦截：无确认通道
      if (gateReport.blocked) {
        closeDialog();
        await SecurityAuditLog.record(
            type: 'reject',
            target: skill.name,
            outcome: 'blocked',
            detail: gateReport.blockReason);
        _showMessage(
            isZh
                ? '已拒绝安装：${gateReport.blockReason}'
                : 'Installation rejected: ${gateReport.blockReason}',
            error: true);
        return;
      }

      if (gateReport.unsafe) {
        closeDialog(); // 进度框先关，避免盖住安全确认框
        final merged = SecurityScanResult(
          success: true,
          riskScore: gateReport.riskScore,
          severity: gateReport.severity,
          safeToInstall: false,
          findings: gateReport.findings,
        );
        final confirmedLocal = await _showSecurityScanDialog(
            merged, skill.name, isZh,
            isLocal: true);
        if (!confirmedLocal) {
          _showMessage(isZh ? '已取消安装' : 'Installation cancelled',
              error: true);
          return;
        }
      }

      // v1.7.12：triggerType 不再硬编码 'answer'（此前所有 Skill 都抢 answer 触发器，
      // PluginRegistry._fallbacks 是单值 Map，后装的覆盖先装的，导致 dispatch 路由失效）。
      // 优先级：SKILL.md frontmatter 的 trigger 字段 → 基于 name/description/正文内容关键词猜测
      final guessedTrigger = SkillInstallService.guessSkillTriggerType(
        parsedSkill.metadata.trigger,
        parsedSkill.metadata.name,
        parsedSkill.metadata.description,
        parsedSkill.instruction,
      );

      // 创建 PluginMetadata
      final metadata = PluginMetadata(
        id: pluginId,
        name: parsedSkill.metadata.name,
        version: parsedSkill.metadata.version ?? '1.0.0',
        author: parsedSkill.metadata.author ?? 'Unknown',
        description: parsedSkill.metadata.description,
        homepage: parsedSkill.metadata.homepage ?? skill.homepage ?? '',
        promptProtocol: parsedSkill.instruction,
        tags: parsedSkill.metadata.tags,
        kind: PluginKind.declarative,
        triggerType: guessedTrigger,
        // v1.7.8：保存 SKILL.md 直链，供插件更新检查使用（homepage 可能是市场页面）
        // v1.7.12：extra 增加 skillSummary 字段，供 system prompt 的 Skill 清单拼接使用
        extra: {
          'downloadUrl': skill.downloadUrl,
          'skillSummary': SkillInstallService.buildSkillSummary(
            name: parsedSkill.metadata.name,
            description: parsedSkill.metadata.description,
            triggerDesc: parsedSkill.metadata.trigger,
            triggerType: guessedTrigger,
          ),
        },
      );

      // 安装
      progress.value = 0.9;
      stage.value = isZh ? '写入插件注册表…' : 'Registering plugin…';
      await registry.installDeclarative(metadata, enable: true);
      await SecurityAuditLog.record(
          type: 'install', target: skill.name, outcome: 'pass', detail: pluginId);

      progress.value = 1.0;
      stage.value = isZh ? '安装完成' : 'Done';
      await Future.delayed(const Duration(milliseconds: 300));
      closeDialog();

      if (mounted) {
        _showMessage(isZh ? '安装成功，已启用。' : 'Installed and enabled.');
      }
    } catch (error) {
      closeDialog();
      _showMessage(isZh ? '安装失败：$error' : 'Installation failed: $error',
          error: true);
    } finally {
      // B-020：两个 ValueNotifier 在成功/失败/各 `!mounted` 早退出口统一释放，
      // 避免反复安装累积未 dispose 的 ChangeNotifier。
      progress.dispose();
      stage.dispose();
    }
  }

  // ==========================================================================
  // 本地导入（zip / SKILL.md / mcp.json）
  // 走与在线安装相同的安全扫描（LocalScanService）→ 注册流程；
  // 与在线不同的是：扫描不过一律拒绝安装并展示原因，不允许用户跳过。
  // ==========================================================================

  Future<void> _importLocalPlugin(PluginRegistry registry, bool isZh) async {
    BiometricService.beginActivityTransition();
    FilePickerResult? picked;
    try {
      picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['zip', 'md', 'markdown', 'json'],
        withData: false,
      );
    } finally {
      Future.delayed(const Duration(seconds: 2), () {
        BiometricService.endActivityTransition();
      });
    }
    if (picked == null || picked.files.isEmpty) return;
    final file = picked.files.first;
    try {
      List<int>? bytes;
      final path = file.path;
      if (path != null) {
        bytes = await File(path).readAsBytes();
      } else {
        bytes = file.bytes;
      }
      if (bytes == null) {
        _showMessage(isZh ? '无法读取文件内容' : 'Cannot read file content',
            error: true);
        return;
      }
      final ext = (file.extension ?? '').toLowerCase();
      if (ext == 'zip') {
        await _importLocalZip(bytes, registry, isZh);
        return;
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      if (ext == 'json') {
        await _installLocalMcp(text, registry, isZh);
      } else {
        await _installLocalSkill(text, registry, isZh);
      }
    } catch (e) {
      _showMessage(isZh ? '导入失败：$e' : 'Import failed: $e', error: true);
    }
  }

  /// zip 包：解出里面的 SKILL.md（优先）或 mcp.json 后走对应导入流程
  Future<void> _importLocalZip(
      List<int> bytes, PluginRegistry registry, bool isZh) async {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      _showMessage(
          isZh
              ? 'zip 解压失败：文件损坏或不是 zip 格式'
              : 'Failed to unzip: corrupted or not a zip file',
          error: true);
      return;
    }
    String? skillContent;
    String? mcpContent;
    for (final entry in archive.files) {
      if (!entry.isFile) continue;
      final name = entry.name.toLowerCase();
      final data = entry.content;
      if (name.endsWith('skill.md')) {
        skillContent ??= utf8.decode(data, allowMalformed: true);
      } else if (name.endsWith('mcp.json')) {
        mcpContent ??= utf8.decode(data, allowMalformed: true);
      }
    }
    if (skillContent != null) {
      await _installLocalSkill(skillContent, registry, isZh);
      return;
    }
    if (mcpContent != null) {
      await _installLocalMcp(mcpContent, registry, isZh);
      return;
    }
    _showMessage(
        isZh
            ? '压缩包内未找到 SKILL.md 或 mcp.json'
            : 'No SKILL.md or mcp.json found in the zip',
        error: true);
  }

  /// 本地 SKILL.md：解析 → 本地安全扫描（不过则拒绝）→ 可选远程审查 → 注册
  Future<void> _installLocalSkill(
      String content, PluginRegistry registry, bool isZh) async {
    final ParsedSkill parsedSkill;
    try {
      parsedSkill = SkillParser.parse(content);
    } catch (e) {
      _showMessage(isZh ? 'SKILL.md 解析失败：$e' : 'Failed to parse SKILL.md: $e',
          error: true);
      return;
    }
    final pluginId = parsedSkill.pluginId;
    if (registry.plugins.any((p) => p.metadata.id == pluginId)) {
      _showMessage(isZh ? '此 Skill 已安装' : 'This skill is already installed',
          error: true);
      return;
    }

    final storage = context.read<StorageService>();
    final cfg = await storage.getWebSearchConfig();
    if (!mounted) return;

    // build98：统一入口 SecurityGate；本地导入扫描不过 → 拒绝并展示原因（不允许跳过）
    final localGate = await SecurityGate.scanSkill(
      skillContent: content,
      skillName: parsedSkill.metadata.name,
      cfg: cfg,
    );
    if (!mounted) return;
    if (localGate.blocked || localGate.unsafe) {
      final merged = SecurityScanResult(
        success: true,
        riskScore: localGate.riskScore,
        severity: localGate.severity,
        safeToInstall: false,
        findings: localGate.findings,
      );
      await _showSecurityScanDialog(
          merged, parsedSkill.metadata.name, isZh,
          isLocal: true);
      await SecurityAuditLog.record(
          type: 'reject',
          target: parsedSkill.metadata.name,
          outcome: 'blocked',
          detail: localGate.blocked
              ? localGate.blockReason
              : 'risk=${localGate.riskScore}');
      _showMessage(
          isZh
              ? '安全扫描未通过，已拒绝安装'
              : 'Security scan failed; installation rejected',
          error: true);
      return;
    }

    final guessedTrigger = SkillInstallService.guessSkillTriggerType(
      parsedSkill.metadata.trigger,
      parsedSkill.metadata.name,
      parsedSkill.metadata.description,
      parsedSkill.instruction,
    );
    final metadata = PluginMetadata(
      id: pluginId,
      name: parsedSkill.metadata.name,
      version: parsedSkill.metadata.version ?? '1.0.0',
      author: parsedSkill.metadata.author ?? 'Local Import',
      description: parsedSkill.metadata.description,
      homepage: parsedSkill.metadata.homepage ?? '',
      promptProtocol: parsedSkill.instruction,
      tags: parsedSkill.metadata.tags,
      kind: PluginKind.declarative,
      triggerType: guessedTrigger,
      extra: {
        'source': 'local_import',
        'skillSummary': SkillInstallService.buildSkillSummary(
          name: parsedSkill.metadata.name,
          description: parsedSkill.metadata.description,
          triggerDesc: parsedSkill.metadata.trigger,
          triggerType: guessedTrigger,
        ),
      },
    );
    await registry.installDeclarative(metadata, enable: true);
    if (mounted) _showMessage(isZh ? '安装成功，已启用。' : 'Installed and enabled.');
  }

  /// 本地 mcp.json：解析为 McpRegistryServer 后走与在线安装相同的扫描→连接→注册流程。
  /// 支持两种格式：{"mcpServers": {"name": {...}}} 或扁平 {"name":..., "url"/"endpoint":...}
  Future<void> _installLocalMcp(
      String jsonStr, PluginRegistry registry, bool isZh) async {
    Map<String, dynamic>? serverMap;
    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is Map) {
        final servers = decoded['mcpServers'];
        if (servers is Map && servers.isNotEmpty) {
          final entry = servers.entries.first;
          final value = entry.value;
          serverMap = value is Map
              ? Map<String, dynamic>.from(value)
              : <String, dynamic>{};
          serverMap['name'] ??= entry.key.toString();
        } else {
          serverMap = Map<String, dynamic>.from(decoded);
        }
      }
    } catch (_) {
      serverMap = null;
    }
    if (serverMap == null) {
      _showMessage(isZh ? '不是有效的 MCP 配置 JSON' : 'Not a valid MCP config JSON',
          error: true);
      return;
    }
    final name = (serverMap['name'] ?? '').toString().trim();
    final url =
        (serverMap['url'] ?? serverMap['endpoint'] ?? '').toString().trim();
    if (name.isEmpty || url.isEmpty) {
      _showMessage(
          isZh
              ? 'MCP 配置缺少 name 或 url/endpoint 字段'
              : 'MCP config missing name or url/endpoint',
          error: true);
      return;
    }
    final endpoint = Uri.tryParse(url);
    if (endpoint == null ||
        endpoint.scheme != 'https' ||
        endpoint.host.isEmpty) {
      _showMessage(
          isZh
              ? '仅支持 HTTPS 远程端点：$url'
              : 'Only HTTPS remote endpoints are supported: $url',
          error: true);
      return;
    }
    // B-029：解析本地 mcp.json 的 headers / auth 字段——旧实现完全丢弃，
    // 使 headerSpecs 恒空 → 既不弹凭据框也不带鉴权头 → 需鉴权的远程 MCP
    // discoverTools 必 401/403，且用户没有任何补填入口。
    final specs = <McpHeaderSpec>[];
    final presetHeaders = <String, String>{};
    final rawHeaders = serverMap['headers'] ?? serverMap['auth'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((k, v) {
        final key = k.toString().trim();
        if (key.isEmpty) return;
        final value = v?.toString() ?? '';
        final lower = key.toLowerCase();
        specs.add(McpHeaderSpec(
          name: key,
          description: lower == 'authorization'
              ? 'Authorization 头（如 "Bearer <token>"）'
              : '自定义请求头 $key',
          isRequired: value.isEmpty,
          isSecret: lower == 'authorization' ||
              lower.contains('key') ||
              lower.contains('token') ||
              lower.contains('secret'),
        ));
        if (value.isNotEmpty) presetHeaders[key] = value;
      });
    }
    final server = McpRegistryServer(
      name: name,
      title: (serverMap['title'] ?? name).toString(),
      description: (serverMap['description'] ?? '').toString(),
      version: (serverMap['version'] ?? '1.0.0').toString(),
      status: 'active',
      endpoint: endpoint,
      transportType: (serverMap['transport'] ??
              serverMap['transportType'] ??
              'streamableHttp')
          .toString(),
      headerSpecs: specs,
    );
    await _installMcp(server, registry, isZh,
        strictReject: true, presetHeaders: presetHeaders);
  }

  /// v1.7.5: 显示安全审查结果对话框
  Future<bool> _showSecurityScanDialog(
    SecurityScanResult result,
    String pluginName,
    bool isZh, {
    bool isLocal = false,
  }) async {
    // v1.7.9 (M10 修复)：本方法在多个 await 之后被调用，context 可能已失效
    if (!mounted) return false;
    final colorScheme = Theme.of(context).colorScheme;
    final riskColor = result.riskScore <= 20
        ? colorScheme.appTextSub
        : result.riskScore <= 50
            ? colorScheme.appTextSub
            : colorScheme.error;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Row(
          children: [
            Icon(
              result.safeToInstall
                  ? Icons.check_circle
                  : Icons.warning_amber_rounded,
              color: result.safeToInstall ? colorScheme.appTextSub : riskColor,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                isLocal
                    ? (isZh ? '本地安全扫描结果' : 'Local Scan Result')
                    : (isZh ? '安全审查结果' : 'Security Scan Result'),
                style: const TextStyle(fontSize: 18),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                isZh ? '插件：$pluginName' : 'Plugin: $pluginName',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Text(
                    isZh ? '风险评分：' : 'Risk Score: ',
                    style: const TextStyle(fontSize: 14),
                  ),
                  Text(
                    '${result.riskScore}/100',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: riskColor,
                    ),
                  ),
                  const Spacer(),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: riskColor.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      isZh ? result.riskLabelZh : result.riskLabelEn,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: riskColor,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (result.findings.isNotEmpty) ...[
                Text(
                  isZh ? '发现的问题：' : 'Findings:',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 14),
                ),
                const SizedBox(height: 8),
                ...result.findings.map((finding) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            finding.severity == SecuritySeverity.critical ||
                                    finding.severity == SecuritySeverity.high
                                ? Icons.error
                                : finding.severity == SecuritySeverity.medium
                                    ? Icons.warning
                                    : Icons.info,
                            size: 16,
                            color: finding.severity == SecuritySeverity.critical
                                ? colorScheme.error
                                : finding.severity == SecuritySeverity.high
                                    ? colorScheme.error
                                    : colorScheme.appTextSub,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  finding.title,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13,
                                  ),
                                ),
                                if (finding.description.isNotEmpty)
                                  Text(
                                    finding.description,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    )),
              ],
              const SizedBox(height: 12),
              if (isLocal)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    isZh
                        ? '⚠️ 本地规则扫描仅供参考，不能保证查出所有问题。请结合插件来源和声誉综合判断。'
                        : '⚠️ Local rule-based scan is for reference only and cannot guarantee detection of all issues. Judge with the plugin source and reputation.',
                    style: TextStyle(
                      fontSize: 11,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              if (!result.safeToInstall)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colorScheme.errorContainer.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color:
                            colorScheme.errorContainer.withValues(alpha: 0.5)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.warning, color: colorScheme.error, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          isZh
                              ? '此插件存在安全风险，建议谨慎安装'
                              : 'This plugin has security risks, install with caution',
                          style: TextStyle(
                            fontSize: 13,
                            color: colorScheme.error,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(isZh ? '取消' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(isZh ? '继续安装' : 'Continue'),
          ),
        ],
      ),
    );

    return confirmed ?? false;
  }

  void _showMessage(String message, {bool error = false}) {
    if (!mounted) return;
    final colorScheme = Theme.of(context).colorScheme;
    AppSnackBar.showSnackBar(context, SnackBar(
        content: Text(message),
        backgroundColor: error ? colorScheme.error : null));
  }
}
