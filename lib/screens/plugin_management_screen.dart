import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/mcp_market_models.dart';
import '../plugins/builtin_plugin_i18n.dart';
import '../plugins/plugin_interface.dart';
import '../plugins/plugin_registry.dart';
import '../services/mcp_client_service.dart';
import '../utils/ssrf_guard.dart';
import '../services/plugin_update_service.dart';
import '../ui/tokens.dart';
import '../widgets/mcp_headers_dialog.dart';
import 'mcp_catalog_screen.dart';
import 'plugin_market_screen.dart';
import 'widget_plugin_screen.dart';
import '../utils/app_snackbar.dart';

class PluginManagementScreen extends StatefulWidget {
  const PluginManagementScreen({super.key});

  @override
  State<PluginManagementScreen> createState() => _PluginManagementScreenState();
}

class _PluginManagementScreenState extends State<PluginManagementScreen> {
  List<PluginUpdateInfo> _updates = [];
  bool _checkingUpdates = false;
  // build104（M2a）：正在体检的插件 id（按钮转圈 + 防重复点）
  String? _healthChecking;

  @override
  void initState() {
    super.initState();
    _checkUpdates();
  }

  Future<void> _checkUpdates() async {
    if (_checkingUpdates) return;
    setState(() => _checkingUpdates = true);
    try {
      final registry = context.read<PluginRegistry>();
      final updates = await PluginUpdateService.checkAllUpdates(registry);
      if (mounted) {
        setState(() {
          _updates = updates;
          _checkingUpdates = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _checkingUpdates = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final registry = context.watch<PluginRegistry>();
    final allPlugins = registry.plugins;
    // v1.7.36：联网搜索已内置为默认能力（不可关），不再出现在插件管理页
    final systemPlugins = allPlugins
        .where((p) =>
            p.source == PluginSource.system &&
            p.metadata.id != PluginRegistry.kSearchPluginId)
        .toList();
    final installedPlugins =
        allPlugins.where((p) => p.source == PluginSource.installed).toList();
    final isEmpty = allPlugins.isEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(isZh ? '插件管理 / Plugin Manager' : 'Plugin Manager / 插件管理'),
        // build104（M1）：推荐连接器目录入口
        actions: [
          IconButton(
            tooltip: isZh ? '推荐连接器' : 'Recommended connectors',
            icon: const Icon(Icons.extension_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const McpCatalogScreen()),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const PluginMarketScreen()),
          );
        },
        icon: const Icon(Icons.storefront),
        label: Text(isZh ? '插件市场' : 'Market'),
      ),
      body: isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.extension_off,
                    size: 64,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    isZh ? '暂无插件' : 'No plugins yet',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              children: [
                // build138（扫描 P1-7）：开关状态读/写失败必须在这里显形。
                // 旧实现把 DB 异常吞成空 map ⇒ 用户关掉的插件下一次冷启动被
                // 出厂默认悄悄打开，而本页一切显示正常（「看起来已经接好了」族）。
                if (registry.pluginStatesLoadFailed ||
                    registry.pluginStatesPersistFailures > 0)
                  Card(
                    elevation: 0,
                    color: Theme.of(context).colorScheme.errorContainer,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.panel),
                      side:
                          BorderSide(color: Theme.of(context).colorScheme.error),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Icon(Icons.error_outline,
                              size: 18,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onErrorContainer),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              registry.pluginStatesLoadFailed
                                  ? (isZh
                                      ? '插件开关状态读取失败：当前显示的是出厂默认，你之前关掉的插件可能已重新开启'
                                      : 'Failed to load plugin switch states: showing factory defaults — plugins you disabled may be enabled again')
                                  : (isZh
                                      ? '有 ${registry.pluginStatesPersistFailures} 个插件开关未能保存'
                                      : '${registry.pluginStatesPersistFailures} plugin switch(es) could not be saved'),
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onErrorContainer),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                // build108（Q2 一期）：声明式小部件插件管理入口
                Card(
                  elevation: 0,
                  color: Theme.of(context).colorScheme.appPanelLight,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.card),
                    side: BorderSide(
                        color: Theme.of(context).colorScheme.appBorder),
                  ),
                  child: ListTile(
                    leading: const Icon(Icons.widgets_outlined),
                    title: Text(isZh ? '小部件插件' : 'Widget plugins'),
                    subtitle: Text(isZh
                        ? '声明式数据卡（余额/状态/资讯）：JSON manifest，不执行第三方代码'
                        : 'Declarative data cards. No third-party code runs.'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const WidgetPluginScreen()),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 8),
                if (systemPlugins.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
                    child: Text(
                      isZh ? '系统内置' : 'System Built-in',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            color: Theme.of(context).colorScheme.appTextSub,
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ),
                  Card(
                    elevation: 0,
                    color: Theme.of(context).colorScheme.appPanelLight,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.card),
                      side: BorderSide(
                          color: Theme.of(context).colorScheme.appBorder),
                    ),
                    child: Column(
                      children: systemPlugins
                          .map((p) => _buildPluginTile(p, registry, isZh))
                          .toList(),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                if (installedPlugins.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
                    child: Text(
                      isZh ? '已安装第三方' : 'Installed Third-party',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            color: Theme.of(context).colorScheme.appTextSub,
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ),
                  Card(
                    elevation: 0,
                    color: Theme.of(context).colorScheme.appPanelLight,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.card),
                      side: BorderSide(
                          color: Theme.of(context).colorScheme.appBorder),
                    ),
                    child: Column(
                      children: installedPlugins
                          .map((p) => _buildPluginTile(p, registry, isZh))
                          .toList(),
                    ),
                  ),
                ],
              ],
            ),
    );
  }

  Widget _buildPluginTile(
      ReActPlugin plugin, PluginRegistry registry, bool isZh) {
    final colorScheme = Theme.of(context).colorScheme;
    final icon = switch (plugin.source) {
      PluginSource.system => Icons.extension,
      PluginSource.installed => Icons.install_desktop,
      PluginSource.market => Icons.shop,
    };
    final enabled = registry.isEnabled(plugin.metadata.id);
    // v1.6.10 build44：第三方插件可卸载（系统内置插件不可卸载，只能禁用）
    final canUninstall = plugin.source != PluginSource.system;

    // v1.7.5: 检查是否有更新
    final updateInfo =
        _updates.where((u) => u.pluginId == plugin.metadata.id).firstOrNull;
    final hasUpdate = updateInfo != null && updateInfo.hasUpdate;

    return InkWell(
      onLongPress: () => _showPluginDetails(plugin, isZh),
      child: ListTile(
        leading: Icon(icon, color: colorScheme.appTextSub),
        title: Row(
          children: [
            Expanded(
              child: Text(
                // build133（⑤）：内置插件文案走 i18n 字典（中文原名 / 英文译名），
                // 第三方与市场插件字典未命中 ⇒ 原样显示，不出现空白。
                '${plugin.metadata.displayName(isZh)}  v${plugin.metadata.version}',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
            if (hasUpdate)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: colorScheme.appPanel,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: colorScheme.appBorder),
                ),
                child: Text(
                  'v${updateInfo.latestVersion}',
                  style: TextStyle(
                    fontSize: 10,
                    color: colorScheme.appTextSub,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
        subtitle: Text(
          plugin.metadata.displayDescription(isZh),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // v1.7.37（待办⑬）：MCP 插件「请求头（鉴权）」编辑入口
            if (plugin.metadata.kind.isRemote)
              IconButton(
                icon: _healthChecking == plugin.metadata.id
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.health_and_safety_outlined, size: 20),
                tooltip: isZh ? '体检' : 'Health check',
                onPressed: _healthChecking == plugin.metadata.id
                    ? null
                    : () => _healthCheck(plugin, isZh),
              ),
            if (plugin.metadata.kind.isRemote)
              IconButton(
                icon: const Icon(Icons.key, size: 20),
                tooltip: isZh ? '请求头（鉴权）' : 'Headers (Auth)',
                onPressed: () => _editMcpHeaders(plugin, registry, isZh),
              ),
            if (hasUpdate)
              IconButton(
                icon: const Icon(Icons.system_update, size: 20),
                color: colorScheme.appTextSub,
                tooltip: isZh ? '更新' : 'Update',
                onPressed: () =>
                    _updatePlugin(plugin, updateInfo, registry, isZh),
              ),
            if (canUninstall)
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                color: colorScheme.error,
                tooltip: isZh ? '卸载' : 'Uninstall',
                onPressed: () => _confirmUninstall(plugin, registry, isZh),
              ),
            Switch(
                value: enabled,
                onChanged: (v) => registry.setEnabled(plugin.metadata.id, v)),
          ],
        ),
      ),
    );
  }

  /// build104（M2a）：MCP 连接器体检——可达性 / 鉴权 / 工具数对比，一页报告卡。
  /// 修复"连不上不知道为什么"：401→密钥失效、超时→网络、工具数 0→端点错。
  Future<void> _healthCheck(ReActPlugin plugin, bool isZh) async {
    final id = plugin.metadata.id;
    setState(() => _healthChecking = id);
    String? problem;
    var toolCount = -1;
    var storedCount = 0;
    var lastVerified = '';
    var trialTool = '';
    var trialOk = false;
    var trialDetail = '';
    try {
      lastVerified =
          plugin.metadata.extra['lastVerifiedAt']?.toString() ?? '';
      final rawStored = plugin.metadata.extra['tools'];
      if (rawStored is List) storedCount = rawStored.length;
      final endpoint = plugin.metadata.extra['endpoint']?.toString() ?? '';
      final headers =
          sanitizeCustomHeaders(plugin.metadata.extra['customHeaders']);
      // build153（SSRF）：这条是「测试连接」按钮的出口 —— 正是必须做 DNS→IP 判定
      // 的那一处（理由见 `installed_mcp_plugin.dart:20`）。
      final client = McpClientService(
          customHeaders: headers, ipLookup: defaultSsrfIpLookup);
      try {
        final raw = await client
            .discoverTools(endpoint)
            .timeout(const Duration(seconds: 15));
        toolCount = raw.length;
        // build107（M2a 体检增强 / U1 盲区实锤）：高德 MCP 的 tools/list 不校验
        // Key 平台，只有 tools/call 才校验——补一步「试调一个只读工具」，
        // 只验发现不验调用不算通过。
        final probe = _pickReadOnlyHealthProbeTool(raw);
        if (probe.isNotEmpty) {
          trialTool = probe;
          try {
            await client
                .toolsCall(endpoint, probe, const {})
                .timeout(const Duration(seconds: 15));
            trialOk = true;
          } catch (e) {
            trialDetail = _firstLine(e.toString());
          }
        }
      } finally {
        client.close();
      }
    } catch (e) {
      final s = e.toString();
      if (s.contains('401') || s.contains('403')) {
        problem = isZh
            ? '鉴权失效（401/403）——密钥过期或填错，点钥匙图标更新鉴权头'
            : 'Auth failed (401/403) — update the key via the key icon';
      } else if (s.contains('TimeoutException') ||
          s.contains('Connection refused') ||
          s.contains('Failed host lookup') ||
          s.contains('Connection reset') ||
          s.contains('SocketException')) {
        problem = isZh
            ? '端点不可达——当前网络到不了该服务（网络/服务端问题）'
            : 'Endpoint unreachable — network or server issue';
      } else {
        problem = isZh ? '异常：${_firstLine(s)}' : 'Error: ${_firstLine(s)}';
      }
    }
    if (!mounted) return;
    setState(() => _healthChecking = null);
    final cs = Theme.of(context).colorScheme;
    Widget row(IconData icon, Color color, String text) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 8),
            Expanded(child: Text(text)),
          ]),
        );
    await showDialog<void>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text(
            '${plugin.metadata.displayName(isZh)} · ${isZh ? "体检报告" : "Health"}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            row(
                problem == null ? Icons.check_circle : Icons.cancel,
                problem == null ? cs.primary : cs.error,
                problem ??
                    (isZh ? '可达，鉴权有效' : 'Reachable, auth valid')),
            row(
                Icons.list_alt,
                cs.onSurfaceVariant,
                isZh
                    ? '工具数：$toolCount（上次保存 $storedCount）'
                    : 'Tools: $toolCount (saved $storedCount)'),
            // build107（M2a 体检增强）：调用层试调结果——tools/list 不验 Key
            // 平台，只有 tools/call 才验；USERKEY_PLAT_NOMATCH = Key 类型不对
            if (problem == null && trialTool.isNotEmpty)
              row(
                  trialOk ? Icons.check_circle : Icons.warning_amber_rounded,
                  trialOk ? cs.primary : cs.error,
                  isZh
                      ? (trialOk
                          ? '试调只读工具「$trialTool」：有响应（调用层验证通过）'
                          : '试调只读工具「$trialTool」失败：$trialDetail'
                              '${trialDetail.contains("USERKEY_PLAT_NOMATCH") ? "——Key 服务平台类型不对，需重建「Web 服务」类型 Key" : ""}')
                      : 'Trial call "$trialTool": ${trialOk ? "ok" : "failed: $trialDetail"}'),
            if (problem == null && toolCount == 0 && storedCount > 0)
              row(Icons.warning_amber_rounded, cs.error,
                  isZh ? '工具数为 0——端点或协议可能不兼容' : '0 tools — endpoint may be wrong'),
            if (lastVerified.isNotEmpty)
              row(Icons.schedule, cs.onSurfaceVariant,
                  '${isZh ? "上次验证" : "Last verified"}: ${lastVerified.substring(0, lastVerified.length > 19 ? 19 : lastVerified.length)}'),
          ],
        ),
        actions: [
          if (problem != null && problem.contains('401'))
            TextButton(
              onPressed: () {
                Navigator.pop(dctx);
                _editMcpHeaders(plugin, context.read<PluginRegistry>(), isZh);
              },
              child: Text(isZh ? '去更新鉴权头' : 'Update key'),
            ),
          TextButton(
              onPressed: () => Navigator.pop(dctx),
              child: Text(isZh ? '关闭' : 'Close')),
        ],
      ),
    );
  }

  static String _firstLine(String s) {
    final nl = s.indexOf('\n');
    final line = (nl > 0 ? s.substring(0, nl) : s).trim();
    return line.length > 160 ? '${line.substring(0, 160)}…' : line;
  }

  /// build107（M2a 体检增强）：从 tools/list 结果里挑一个「只读、空参可调」
  /// 的工具做试调探针。排除写操作类工具；优先含只读关键词的名字，其次无
  /// required 字段的。挑不出返回空串（跳过试调，报告不含该行）。
  static String _pickReadOnlyHealthProbeTool(List<Map<String, dynamic>> tools) {
    const preferred = [
      'ip_location', 'regeocode', 'weather', 'distance', 'geo',
      'list', 'query', 'search', 'status', 'ping', 'health', 'get', 'read',
    ];
    final blocked = RegExp(
        r'create|submit|order|cancel|write|delete|send|install|pay|confirm|update|add');
    String? best;
    var bestRank = 1 << 30;
    for (final t in tools) {
      final name = (t['name']?.toString() ?? '').toLowerCase();
      if (name.isEmpty || blocked.hasMatch(name)) continue;
      var rank = 1 << 30;
      for (var i = 0; i < preferred.length; i++) {
        if (name.contains(preferred[i])) {
          rank = i;
          break;
        }
      }
      final schema = t['inputSchema'] ?? t['input_schema'];
      final required = schema is Map ? (schema['required'] as List?) : null;
      final total = rank + ((required == null || required.isEmpty) ? 0 : 100);
      if (total < bestRank) {
        bestRank = total;
        best = t['name']?.toString() ?? '';
      }
    }
    return best ?? '';
  }

  /// v1.7.37（待办⑬）：编辑 MCP 插件鉴权请求头（凭据敏感，不写日志）
  Future<void> _editMcpHeaders(
      ReActPlugin plugin, PluginRegistry registry, bool isZh) async {
    final initial =
        sanitizeCustomHeaders(plugin.metadata.extra['customHeaders']);
    final headers = await showMcpHeadersEditorDialog(context, initial: initial);
    if (headers == null || !mounted) return;
    try {
      await registry.updateMcpCustomHeaders(plugin.metadata.id, headers);
      if (!mounted) return;
      AppSnackBar.showSnackBar(context, SnackBar(
        content: Text(isZh ? '鉴权请求头已保存' : 'Auth headers saved'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ));
    } catch (e) {
      if (!mounted) return;
      AppSnackBar.showSnackBar(context, SnackBar(
        content: Text(isZh ? '保存失败：$e' : 'Save failed: $e'),
        backgroundColor: Theme.of(context).colorScheme.error,
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  Future<void> _updatePlugin(
    ReActPlugin plugin,
    PluginUpdateInfo updateInfo,
    PluginRegistry registry,
    bool isZh,
  ) async {
    final colorScheme = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isZh
            ? '更新「${plugin.metadata.name}」？'
            : 'Update "${plugin.metadata.name}"?'),
        content: Text(isZh
            ? '当前版本：v${updateInfo.currentVersion}\n最新版本：v${updateInfo.latestVersion}\n\n更新后将自动启用新版本。'
            : 'Current: v${updateInfo.currentVersion}\nLatest: v${updateInfo.latestVersion}\n\nThe new version will be enabled automatically after update.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(isZh ? '取消' : 'Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(isZh ? '更新' : 'Update'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    // v1.7.14：接入 PluginUpdateService.updatePlugin（service 在 v1.7.12 已实现，
    // 但 plugin_management_screen 一直留着 v1.7.5 的 TODO 占位，导致点"更新"按钮
    // 永远只显示开发中提示而不真正执行更新。本行把 UI 接入 service，让 Skill 重新
    // 下载 SKILL.md 覆盖安装、MCP 重新 fetch registry + installRemoteMcp 真正生效。
    try {
      final (success, message) =
          await PluginUpdateService.updatePlugin(updateInfo, registry);
      if (!mounted) return;
      AppSnackBar.showSnackBar(context, SnackBar(
        content: Text(success
            ? (isZh ? '更新成功: $message' : 'Update successful: $message')
            : (isZh ? '更新失败: $message' : 'Update failed: $message')),
        backgroundColor: success ? null : colorScheme.error,
        behavior: SnackBarBehavior.floating,
      ));
      // 更新成功 → 移除 _updates 里对应条目，更新按钮自动消失（registry.plugins 已
      // 被 installDeclarative / installRemoteMcp 内部 notifyListeners 触发 rebuild，
      // 新版本号会从 plugin.metadata.version 反映出来）
      if (success) {
        setState(() {
          _updates =
              _updates.where((u) => u.pluginId != updateInfo.pluginId).toList();
        });
      }
    } catch (e) {
      // PluginUpdateService.updatePlugin 内部已 try-catch 返回 (false, msg)，
      // 这里是双保险（理论上不应到达）
      if (!mounted) return;
      AppSnackBar.showSnackBar(context, SnackBar(
        content: Text(isZh ? '更新失败：$e' : 'Update failed: $e'),
        backgroundColor: colorScheme.error,
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  Future<void> _confirmUninstall(
      ReActPlugin plugin, PluginRegistry registry, bool isZh) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isZh
            ? '卸载「${plugin.metadata.name}」？'
            : 'Uninstall "${plugin.metadata.name}"?'),
        content: Text(isZh
            ? '卸载后将移除该插件及其配置，需要重新安装才能恢复。'
            : 'This will remove the plugin and its config. Reinstall to restore.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(isZh ? '取消' : 'Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(isZh ? '卸载' : 'Uninstall'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await registry.uninstall(plugin.metadata.id);
    if (mounted) {
      AppSnackBar.showSnackBar(context, SnackBar(
        content: Text(isZh
            ? '已卸载 ${plugin.metadata.name}'
            : '${plugin.metadata.name} uninstalled'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ));
    }
  }

  void _showPluginDetails(ReActPlugin plugin, bool isZh) {
    final m = plugin.metadata;
    showDialog(
      context: context,
      builder: (_) => AboutDialog(
        applicationName: '${m.displayName(isZh)} v${m.version}',
        applicationIcon: Icon(
          Icons.extension,
          size: 48,
          color: Theme.of(context).colorScheme.appTextSub,
        ),
        children: [
          ListTile(
            leading: const Icon(Icons.person),
            title: Text(isZh ? '作者' : 'Author'),
            subtitle: Text(m.author.isEmpty ? '-' : m.author),
          ),
          ListTile(
            leading: const Icon(Icons.tag),
            title: Text(isZh ? '版本' : 'Version'),
            subtitle: Text(m.version),
          ),
          if (m.homepage.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.link),
              title: Text(isZh ? '主页' : 'Homepage'),
              subtitle: Text(m.homepage),
            ),
          ListTile(
            leading: const Icon(Icons.system_update),
            title: Text(isZh ? '最小 App 版本' : 'Min App Version'),
            subtitle: Text(m.minAppVersion),
          ),
          if (m.tags.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: m.displayTags(isZh)
                    .map((t) => Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.appPanelLight,
                            borderRadius:
                                BorderRadius.circular(AppRadius.inline),
                            border: Border.all(
                                color: Theme.of(context).colorScheme.appBorder),
                          ),
                          child: Text(t,
                              style: TextStyle(
                                  fontSize: 11,
                                  color:
                                      Theme.of(context).colorScheme.appTextSub,
                                  fontWeight: FontWeight.w500)),
                        ))
                    .toList(),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              m.description,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}
