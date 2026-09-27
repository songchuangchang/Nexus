import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/logger_service.dart';
import '../services/security_gate.dart';
import '../services/widget_plugin_service.dart';
import '../utils/app_snackbar.dart';

/// build108（Q2 一期）：声明式小部件插件管理页。
///
/// 安装方式：粘贴 manifest JSON / 从 https URL 下载。安装过 SecurityGate
/// URL 审查（WidgetPluginService.add 内做 sourceUrl 审查；下载 URL 在本页
/// 也过审查）。一期不跑任何第三方代码，格式详见 WidgetPluginService 头注释。
class WidgetPluginScreen extends StatefulWidget {
  const WidgetPluginScreen({super.key});

  @override
  State<WidgetPluginScreen> createState() => _WidgetPluginScreenState();
}

class _WidgetPluginScreenState extends State<WidgetPluginScreen> {
  List<WidgetPluginManifest> _plugins = [];
  bool _isLoading = true;
  bool _busy = false;

  static final LoggerService _logger = LoggerService.instance;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final list = await WidgetPluginService.load();
    if (mounted) {
      setState(() {
        _plugins = list;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    return Scaffold(
      appBar: AppBar(
        title: Text(isZh ? '小部件插件' : 'Widget plugins'),
        actions: [
          IconButton(
            tooltip: isZh ? '格式说明' : 'Format help',
            icon: const Icon(Icons.help_outline),
            onPressed: () => _showFormatHelp(isZh),
          ),
          if (_plugins.isNotEmpty)
            IconButton(
              tooltip: isZh ? '全部刷新' : 'Refresh all',
              icon: const Icon(Icons.refresh),
              onPressed:
                  _busy ? null : () => _refreshAll(isZh),
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _plugins.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.widgets_outlined,
                          size: 64,
                          color: Theme.of(context).colorScheme.outline),
                      const SizedBox(height: 16),
                      Text(isZh ? '还没有安装小部件' : 'No widget plugins',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Text(
                          isZh
                              ? '声明式小部件 = JSON 描述的数据卡（HTTP 数据源 + 白名单域名 + 字段映射），不执行第三方代码。点右下角 + 安装，右上角 ？ 看格式。'
                              : 'Declarative widget = a JSON-described data card (HTTP source + domain whitelist + field mapping). No third-party code runs.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 12.5,
                              color: Theme.of(context).colorScheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: _plugins.length,
                  itemBuilder: (context, index) {
                    final p = _plugins[index];
                    // build140（反馈①同源）：主题取值必须在**每项自己的元素**上读，
                    // itemBuilder 的 context 是 SliverList 共享元素（详见
                    // conversation_list_screen 同名注释）。
                    return Builder(builder: (context) => Card(
                      margin:
                          const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      child: ListTile(
                        leading: const Icon(Icons.widgets_outlined),
                        title: Text(p.name),
                        subtitle: Text(
                          '${p.id} · ${isZh ? "每" : "every "}${p.refreshMinutes}${isZh ? " 分钟" : " min"}\n${Uri.tryParse(p.sourceUrl)?.host ?? p.sourceUrl}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        isThreeLine: true,
                        trailing: IconButton(
                          tooltip: isZh ? '删除' : 'Delete',
                          icon: Icon(Icons.delete_outline,
                              color: Theme.of(context).colorScheme.error),
                          onPressed: () => _remove(p, isZh),
                        ),
                      ),
                    ));
                  },
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: _busy ? null : () => _showAddSheet(isZh),
        child: const Icon(Icons.add),
      ),
    );
  }

  Future<void> _refreshAll(bool isZh) async {
    setState(() => _busy = true);
    var ok = 0;
    for (final p in _plugins) {
      final (payload, _) = await WidgetPluginService.fetchLatest(p, force: true);
      if (payload != null) ok++;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    AppSnackBar.showSnackBar(context, SnackBar(
      content: Text(isZh ? '刷新完成：$ok/${_plugins.length} 成功' : 'Refreshed: $ok/${_plugins.length}'),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
  }

  Future<void> _remove(WidgetPluginManifest p, bool isZh) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isZh ? '删除小部件？' : 'Delete widget?'),
        content: Text(isZh
            ? '将删除「${p.name}」及其缓存数据。'
            : 'Delete "${p.name}" and its cached data?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    await WidgetPluginService.remove(p.id);
    _loadData();
  }

  void _showAddSheet(bool isZh) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.paste),
              title: Text(isZh ? '粘贴 manifest JSON' : 'Paste manifest JSON'),
              onTap: () {
                Navigator.pop(ctx);
                _addByPaste(isZh);
              },
            ),
            ListTile(
              leading: const Icon(Icons.download),
              title: Text(isZh ? '从 https URL 下载' : 'Download from https URL'),
              onTap: () {
                Navigator.pop(ctx);
                _addByUrl(isZh);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addByPaste(bool isZh) async {
    final textCtrl = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isZh ? '粘贴 manifest JSON' : 'Paste manifest JSON'),
        content: SizedBox(
          width: 400,
          child: TextField(
            controller: textCtrl,
            maxLines: 10,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: InputDecoration(
              hintText: isZh ? '{"id": "community.weather_card", ...}' : '{"id": ...}',
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(isZh ? '取消' : 'Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, textCtrl.text),
              child: Text(isZh ? '安装' : 'Install')),
        ],
      ),
    );
    // B-009：取消/空值路径也要释放 controller（弹窗内创建，方法内局部）
    textCtrl.dispose();
    if (raw == null || raw.trim().isEmpty) return;
    await _install(raw.trim(), isZh);
  }

  Future<void> _addByUrl(bool isZh) async {
    final urlCtrl = TextEditingController();
    final rawUrl = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isZh ? '从 https URL 下载 manifest' : 'Download manifest'),
        content: TextField(
          controller: urlCtrl,
          decoration: const InputDecoration(
            hintText: 'https://example.com/my-widget.json',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(isZh ? '取消' : 'Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, urlCtrl.text.trim()),
              child: Text(isZh ? '下载' : 'Download')),
        ],
      ),
    );
    // B2（N-7）：与 _addByPaste 同款——弹窗内创建的 controller 必须在方法内
    // 释放，取消/空值路径同样要走到（原实现只有 _addByPaste 有 dispose，
    // 本方法每次开合弹窗泄漏一个 TextEditingController）。
    urlCtrl.dispose();
    if (rawUrl == null || rawUrl.isEmpty) return;
    final uri = Uri.tryParse(rawUrl);
    if (uri == null || uri.scheme != 'https') {
      _toast(isZh ? '仅支持 https 下载地址' : 'Only https download URLs are supported');
      return;
    }
    setState(() => _busy = true);
    try {
      final findings = await SecurityGate.auditUrl(rawUrl);
      if (findings.isNotEmpty) {
        _toast('${isZh ? "安全审查未通过" : "Blocked"}: ${findings.map((f) => f.title).join("；")}');
        return;
      }
      final resp = await http.get(uri).timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200 || resp.bodyBytes.length > WidgetPluginManifest.maxManifestChars) {
        _toast(isZh ? '下载失败或内容超限（≤16KB）' : 'Download failed or too large (≤16KB)');
        return;
      }
      await _install(utf8.decode(resp.bodyBytes, allowMalformed: true), isZh);
    } catch (e) {
      _logger.warn('widget manifest download failed: $e', tag: 'Widget');
      _toast('${isZh ? "下载失败" : "Download failed"}: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _install(String raw, bool isZh) async {
    if (raw.length > WidgetPluginManifest.maxManifestChars) {
      _toast(isZh ? 'manifest 超过 16KB 上限' : 'Manifest exceeds 16KB');
      return;
    }
    WidgetPluginManifest manifest;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        _toast(isZh ? 'manifest 顶层必须是 JSON 对象' : 'Manifest must be a JSON object');
        return;
      }
      manifest = WidgetPluginManifest.fromJson(
          Map<String, dynamic>.from(decoded));
    } catch (e) {
      _toast('${isZh ? "格式不合法" : "Invalid format"}: $e');
      return;
    }
    final err = await WidgetPluginService.add(manifest);
    if (!mounted) return;
    if (err != null) {
      _toast(err);
      return;
    }
    _toast(isZh ? '已安装「${manifest.name}」' : 'Installed "${manifest.name}"');
    _loadData();
  }

  void _toast(String msg) {
    if (!mounted) return;
    AppSnackBar.showSnackBar(context, SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 3),
    ));
  }

  void _showFormatHelp(bool isZh) {
    const sample = '''
{
  "id": "community.weather_card",
  "name": "天气卡",
  "version": "1.0.0",
  "author": "someone",
  "description": "主页天气卡片",
  "placement": "home_top",
  "source": {
    "url": "https://api.example.com/weather",
    "method": "GET"
  },
  "allowDomains": ["api.example.com"],
  "refreshMinutes": 30,
  "fields": [
    {"path": "data.temp", "label": "温度", "suffix": "°C"},
    {"path": "data.city", "label": "城市"}
  ]
}''';
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isZh ? 'manifest 格式说明' : 'Manifest format'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(isZh
                  ? '· 仅 https 数据源；域名必须在 allowDomains 白名单内\n· fields 用 JSON 点路径取值（支持数组下标，如 data.list.0.temp）\n· refreshMinutes 限频 5~1440；按刷新间隔自动拉取\n· 安装过 SecurityGate URL 审查；不执行任何第三方代码\n· manifest ≤ 16KB，fields ≤ 6 个'
                  : '· https sources only; host must be in allowDomains\n· fields use dotted JSON paths (array index supported)\n· refreshMinutes 5~1440\n· SecurityGate URL audit on install; no third-party code runs\n· manifest ≤ 16KB, ≤ 6 fields'),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const SelectableText(sample,
                    style: TextStyle(fontFamily: 'monospace', fontSize: 11)),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(isZh ? '知道了' : 'Got it')),
        ],
      ),
    );
  }
}
