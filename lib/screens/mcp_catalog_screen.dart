import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/mcp_catalog.dart';
import '../models/mcp_market_models.dart';
import '../plugins/plugin_registry.dart';
import '../services/data_pack_service.dart';
import '../services/github_device_flow.dart';
import '../services/security_gate.dart';
import '../services/storage_service.dart';
import '../l10n/app_localizations.dart';
import '../utils/launcher_utils.dart';
import '../utils/app_snackbar.dart';

/// build104（M1）：MCP 推荐连接器目录页。
///
/// 数据源 = 远程 mcp_catalog.json + 编译期内置兜底（McpCatalog.load）。
/// 安装链路与市场一致：SecurityGate 统一审查（不豁免）→ installRemoteMcp。
/// GitHub 条目额外提供 Device Flow 登录（M3）：输码授权拿 token 自动填鉴权头。
class McpCatalogScreen extends StatefulWidget {
  const McpCatalogScreen({super.key});

  @override
  State<McpCatalogScreen> createState() => _McpCatalogScreenState();
}

class _McpCatalogScreenState extends State<McpCatalogScreen> {
  List<McpCatalogEntry> _entries = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load(refresh: true);
  }

  Future<void> _load({bool refresh = false}) async {
    setState(() {
      _loading = _entries.isEmpty;
      _error = null;
    });
    try {
      // build138（G54）：刷新统一走 DataPackService（多源有序 + 版本/sha256 闸门），
      // McpCatalog.load 只负责「已校验的远程条目 + 内置」合并，不再自己连网。
      if (refresh) {
        await DataPackService.instance
            .refreshPack(DataPackService.packMcpCatalog);
      }
      final entries = await McpCatalog.load();
      if (!mounted) return;
      setState(() => _entries = entries);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    return Scaffold(
      appBar: AppBar(
        title: Text(isZh ? '推荐连接器' : 'Recommended connectors'),
        actions: [
          IconButton(
            tooltip: isZh ? '刷新目录' : 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : () => _load(refresh: true),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _entries.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: () => _load(refresh: true),
                        child: Text(isZh ? '重试' : 'Retry'),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: () => _load(refresh: true),
                  child: ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: _entries.length,
                    itemBuilder: (ctx, i) {
                      final e = _entries[i];
                      // build140（反馈①同源）：itemBuilder 的 context 是 SliverList 共享元素，
                      // 在它上面读 Theme ⇒ 主题切换后已画出来的条目不重建。颜色取值挪进
                      // 每项自己的 Builder 元素里（详见 conversation_list_screen 的同名注释）。
                      return Builder(builder: (ctx) {
                        final cs = Theme.of(ctx).colorScheme;
                        return Card(
                          margin: const EdgeInsets.only(bottom: 10),
                          child: ListTile(
                            title: Text('${e.nameZh}  ·  ${e.name}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                            subtitle: Text(
                              '${e.description}\n'
                              '${e.category} · 端点核实 ${e.verifiedAt} · '
                              '${e.needsSecret ? (isZh ? "需填密钥" : "needs key") : (isZh ? "免鉴权" : "no auth")}',
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12, color: cs.onSurfaceVariant),
                            ),
                            isThreeLine: true,
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => _showInstallSheet(e, isZh),
                          ),
                        );
                      });
                    },
                  ),
                ),
    );
  }

  Future<void> _showInstallSheet(McpCatalogEntry e, bool isZh) async {
    final registry = context.watch<PluginRegistry>();
    final secretCtrl = TextEditingController();
    // SB-3：同类弹层防叠——快速连点安装不再叠多层
    if (!GuardedOverlay.tryEnter('mcp_install_sheet')) {
      // B2（N-7）：防叠早退路径也必须释放 controller（原实现此路径泄漏）。
      secretCtrl.dispose();
      return;
    }
    try {
      return await _showInstallSheetInner(e, isZh, registry, secretCtrl);
    } finally {
      // B2（N-7）：弹窗关闭后释放——原实现全文件零 dispose，每次开合泄漏一个。
      secretCtrl.dispose();
      GuardedOverlay.exit('mcp_install_sheet');
    }
  }

  Future<void> _showInstallSheetInner(McpCatalogEntry e, bool isZh,
      PluginRegistry registry, TextEditingController secretCtrl) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetCtx) {
        var busy = false;
        var flowBusy = false;
        return StatefulBuilder(
          builder: (sheetCtx, setSheet) => SafeArea(
            // L2：底部避让只留一份。键盘弹起时 MediaQuery.viewInsets.bottom
            // 在 Android 上本身含导航条那一截，再叠加 SafeArea 的 bottom
            // 就是双算（内容被额外顶高一个导航条）。这里关掉 bottom，
            // 安全区由 showModalBottomSheet 的 useSafeArea 与 viewInsets 负责。
            bottom: false,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                  20, 8, 20, 20 + MediaQuery.of(sheetCtx).viewInsets.bottom),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // L2：内容区可滚动 —— 外层 Column 是 min，故必须用 Flexible
                  // 收缩后再交给 SingleChildScrollView 兜住；主操作（安装）留在
                  // 滚动区之外，键盘弹起时不会被卷进滚动内容里点不到。
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${e.nameZh} · ${e.name}',
                              style: Theme.of(sheetCtx)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 6),
                          Text(e.description,
                              style: Theme.of(sheetCtx).textTheme.bodySmall),
                          const SizedBox(height: 8),
                          SelectableText(e.endpoint,
                              style: Theme.of(sheetCtx)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                      color: Theme.of(sheetCtx)
                                          .colorScheme
                                          .outline)),
                          if (e.docsUrl.isNotEmpty)
                            TextButton.icon(
                              // B-003：外链跳转统一走 LauncherUtils（内含 guard + 120s 兜底）
                              onPressed: () =>
                                  LauncherUtils.openExternalUrl(e.docsUrl),
                              icon: const Icon(Icons.open_in_new, size: 16),
                              label: Text(isZh ? '接入文档' : 'Docs',
                                  style: const TextStyle(fontSize: 12)),
                            ),
                          if (e.needsSecret) ...[
                            const SizedBox(height: 4),
                            TextField(
                              controller: secretCtrl,
                              obscureText: true,
                              decoration: InputDecoration(
                                labelText: e.auth == 'key-query'
                                    ? (isZh ? 'API Key' : 'API key')
                                    : (e.headerName ?? 'Authorization'),
                                helperText: e.secretHint,
                                helperMaxLines: 3,
                                border: const OutlineInputBorder(),
                              ),
                            ),
                            // M3：GitHub 条目提供 Device Flow 登录（替代手填 PAT）
                            if (e.id == 'github') ...[
                              const SizedBox(height: 8),
                              // B-004：未注入 OAuth App Client ID 时不再显示必然失败的按钮，
                              // 改为一行说明（引导直接填 PAT），避免用户点进去只看到报错。
                              if (!GitHubDeviceFlow.isConfigured)
                                Text(
                                  isZh
                                      ? '未配置 GitHub OAuth App Client ID（构建期 --dart-define 注入），请直接填写 Personal Access Token'
                                      : 'GitHub OAuth App Client ID not configured '
                                          '(inject via --dart-define); please fill a Personal Access Token',
                                  style: Theme.of(sheetCtx).textTheme.bodySmall,
                                )
                              else
                                OutlinedButton.icon(
                                  onPressed: flowBusy
                                      ? null
                                      : () async {
                                          setSheet(() => flowBusy = true);
                                          try {
                                            final token = await _runDeviceFlow(
                                                sheetCtx, isZh);
                                            if (token != null) {
                                              secretCtrl.text = token;
                                            }
                                          } finally {
                                            setSheet(() => flowBusy = false);
                                          }
                                        },
                                  icon: const Icon(Icons.login, size: 18),
                                  label: Text(isZh
                                      ? 'GitHub 登录（输码授权）'
                                      : 'Sign in to GitHub'),
                                ),
                            ],
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: busy
                          ? null
                          : () async {
                              final secret =
                                  e.needsSecret ? secretCtrl.text.trim() : '';
                              if (e.needsSecret && secret.isEmpty) {
                                AppSnackBar.showSnackBar(
                                    sheetCtx,
                                    SnackBar(
                                        content: Text(isZh
                                            ? '请先填写密钥'
                                            : 'Please enter the key')));
                                return;
                              }
                              setSheet(() => busy = true);
                              try {
                                final ok =
                                    await _install(registry, e, secret, isZh);
                                if (!sheetCtx.mounted) return;
                                Navigator.pop(sheetCtx);
                                if (ok) {
                                  if (!mounted) return;
                                  AppSnackBar.showSnackBar(
                                      context,
                                      SnackBar(
                                          content: Text(isZh
                                              ? '✅ ${e.nameZh} 安装成功，可在对话中使用了'
                                              : '✅ ${e.nameZh} installed')));
                                }
                              } catch (err) {
                                if (!sheetCtx.mounted) return;
                                AppSnackBar.showSnackBar(
                                    sheetCtx,
                                    SnackBar(
                                        content: Text(
                                            '${isZh ? "安装失败" : "Install failed"}: $err'),
                                        behavior: SnackBarBehavior.floating));
                              } finally {
                                if (sheetCtx.mounted) {
                                  setSheet(() => busy = false);
                                }
                              }
                            },
                      icon: busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.download_done),
                      label: Text(
                          isZh ? '安装（含安全审查）' : 'Install (with security scan)'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// M3：Device Flow 弹窗——显示 user code → 打开授权页 → 轮询 → 返回 token。
  Future<String?> _runDeviceFlow(BuildContext sheetCtx, bool isZh) async {
    String? result;
    var cancelled = false;
    await showDialog<void>(
      context: sheetCtx,
      barrierDismissible: false,
      builder: (dctx) => FutureBuilder<
          ({
            String userCode,
            String verificationUri,
            int interval,
            String deviceCode
          })>(
        future: GitHubDeviceFlow.start(),
        builder: (ctx, snap) {
          if (snap.hasError) {
            return AlertDialog(
              title: Text(isZh ? 'GitHub 登录' : 'GitHub sign-in'),
              content: Text('${snap.error}'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dctx),
                    child: Text(isZh ? '关闭' : 'Close')),
              ],
            );
          }
          if (!snap.hasData) {
            return const AlertDialog(
                content: Center(child: CircularProgressIndicator()));
          }
          final info = snap.data!;
          // 启动轮询（只启动一次）
          // B-011：轮询必须用 device_code（长串），不是展示给用户输的 user_code
          Future<String>.sync(() => GitHubDeviceFlow.pollForToken(
                deviceCode: info.deviceCode,
                intervalSeconds: info.interval,
                isCancelled: () => cancelled,
              )).then((token) {
            result = token;
            if (dctx.mounted) Navigator.pop(dctx, token);
          }).catchError((Object e) {
            result = null;
            if (dctx.mounted) Navigator.pop(dctx, e);
          });
          return AlertDialog(
            title: Text(isZh ? 'GitHub 登录' : 'GitHub sign-in'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(isZh
                    ? '1. 打开下面的授权页\n2. 输入代码并授权\n（App 会自动继续）'
                    : '1. Open the activation page\n2. Enter the code and authorize'),
                const SizedBox(height: 12),
                SelectableText(info.userCode,
                    style: Theme.of(dctx)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                FilledButton.tonal(
                  onPressed: () =>
                      LauncherUtils.openExternalUrl(info.verificationUri),
                  child: Text(isZh
                      ? '打开 github.com/login/device'
                      : 'Open github.com/login/device'),
                ),
                const SizedBox(height: 8),
                const LinearProgressIndicator(minHeight: 3),
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () {
                    cancelled = true;
                    Navigator.pop(dctx);
                  },
                  child: Text(isZh ? '取消' : 'Cancel')),
            ],
          );
        },
      ),
    );
    if (result is String) return result as String;
    if (result is DeviceFlowException) {
      if (sheetCtx.mounted) {
        AppSnackBar.showSnackBar(
            sheetCtx,
            SnackBar(
                content: Text((result as DeviceFlowException).message),
                behavior: SnackBarBehavior.floating));
      }
    }
    return null;
  }

  /// 安装：目录端点 + 密钥 → SecurityGate 统一审查 → installRemoteMcp。
  /// 与 install_mcp 代装同一条 fail-closed 语义（引擎失败/unsafe 一律拒绝）。
  Future<bool> _install(PluginRegistry registry, McpCatalogEntry e,
      String secret, bool isZh) async {
    final storage = context.read<StorageService>();
    final cfg = await storage.getWebSearchConfig();
    // ① 端点组装：key-query 拼参数；key-header 组鉴权头
    var endpoint = e.endpoint;
    Map<String, String> headers = {};
    if (e.auth == 'key-query' && e.queryParam != null && secret.isNotEmpty) {
      endpoint =
          '$endpoint${endpoint.contains('?') ? '&' : '?'}${e.queryParam}=${Uri.encodeQueryComponent(secret)}';
    }
    if (e.auth == 'key-header' && e.headerName != null && secret.isNotEmpty) {
      headers = {e.headerName!: '${e.headerPrefix ?? ''}$secret'};
    }
    // ② SecurityGate 统一审查（AI 代装同款 fail-closed；目录条目不豁免）
    final toolsJson = jsonEncode({
      'server_name': e.id,
      'endpoint': endpoint,
      'transport': 'streamable-http',
      'description': e.description,
    });
    final report = await SecurityGate.scanMcp(
      serverName: e.id,
      endpoint: endpoint,
      toolsJson: toolsJson,
      cfg: cfg,
      envKeys: e.headerName != null ? [e.headerName!] : const [],
      forceLocalScan: true, // 目录推荐也是代装性质：本地规则强制必跑
    );
    if (report.anyEngineFailed) {
      throw Exception(isZh
          ? '安全扫描服务不可用（${report.engineError}），已拒绝安装'
          : 'Scan engine unavailable (${report.engineError})');
    }
    if (report.blocked || report.unsafe) {
      final reason = report.blocked
          ? report.blockReason
          : report.findings.map((f) => f.title).join('；');
      throw Exception(
          isZh ? '安全审查不通过：$reason' : 'Blocked by security scan: $reason');
    }
    // ③ 注册（installRemoteMcp 内部做 discoverTools + 落库 + 强确认标记）
    final server = McpRegistryServer(
      name: e.id,
      title: e.nameZh,
      description: e.description,
      version: '1.0.0',
      status: 'active',
      endpoint: Uri.parse(endpoint),
      transportType: 'streamableHttp',
      headerSpecs: e.headerName != null
          ? [
              McpHeaderSpec(
                  name: e.headerName!,
                  description: e.secretHint,
                  isSecret: true)
            ]
          : const [],
    );
    // build155（第 13 轮 P1-1）：目录页点「安装」是显式安装 → 显式启用。
    await registry.installRemoteMcp(
      server,
      customHeaders: headers.isNotEmpty ? headers : null,
      forceConfirmEveryCall: report.forceConfirmEveryCall,
      enable: true,
    );
    return true;
  }
}
