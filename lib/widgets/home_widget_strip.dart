import 'package:flutter/material.dart';

import '../services/widget_plugin_service.dart';
import '../utils/launcher_utils.dart';
import '../utils/app_snackbar.dart';

/// build108（Q2 一期）：主页顶部的声明式小部件卡片条。
///
/// 每个启用的小部件渲染为一张紧凑卡片：标题 + 字段行（JSON 路径取值）+
/// 更新时间 + 手动刷新。数据来自 WidgetPluginService（缓存优先、按
/// refreshMinutes 限频），拉取失败显示缓存并标「更新失败」。
class HomeWidgetStrip extends StatefulWidget {
  final List<WidgetPluginManifest> plugins;

  const HomeWidgetStrip({super.key, required this.plugins});

  @override
  State<HomeWidgetStrip> createState() => _HomeWidgetStripState();
}

class _HomeWidgetStripState extends State<HomeWidgetStrip> {
  final Map<String, Map<String, dynamic>?> _payloads = {};
  final Map<String, String?> _updated = {};
  final Set<String> _loading = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshAll());
  }

  @override
  void didUpdateWidget(covariant HomeWidgetStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    // WP-3：清单变化（装/卸/更新）时清理失效缓存并整体重拉（force 绕过限频）
    final oldIds = oldWidget.plugins.map((p) => p.id).toSet();
    final newIds = widget.plugins.map((p) => p.id).toSet();
    if (oldIds != newIds) {
      _payloads.removeWhere((k, _) => !newIds.contains(k));
      _updated.removeWhere((k, _) => !newIds.contains(k));
      _loading.removeWhere((k) => !newIds.contains(k));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _refreshAll();
      });
    }
  }

  Future<void> _refreshAll() async {
    // SB-2：批量刷新失败汇总为一条（N 项失败），不再逐条连弹
    int failCount = 0;
    final failedNames = <String>[];
    for (final p in widget.plugins) {
      if (!mounted) return;
      setState(() => _loading.add(p.id));
      final (payload, _) = await WidgetPluginService.fetchLatest(p);
      if (!mounted) return;
      setState(() {
        _loading.remove(p.id);
        _payloads[p.id] = payload;
        if (payload != null) {
          final now = DateTime.now();
          _updated[p.id] =
              '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
        }
      });
      if (payload == null) {
        failCount++;
        failedNames.add(p.name);
      }
    }
    if (mounted && failCount > 0) {
      AppSnackBar.showSnackBar(context, SnackBar(
        content: Text(failCount == 1
            ? '「${failedNames.first}」数据拉取失败（稍后可重试）'
            : '$failCount 个小部件数据拉取失败（稍后可重试）'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ));
    }
  }

  Future<void> _refreshOne(WidgetPluginManifest p) async {
    if (_loading.contains(p.id)) return;
    setState(() => _loading.add(p.id));
    final (payload, _) = await WidgetPluginService.fetchLatest(p, force: true);
    if (!mounted) return;
    setState(() {
      _loading.remove(p.id);
      _payloads[p.id] = payload;
      if (payload != null) {
        final now = DateTime.now();
        _updated[p.id] =
            '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
      }
    });
    if (payload == null && mounted) {
      AppSnackBar.showSnackBar(context, SnackBar(
        content: Text('「${p.name}」数据拉取失败（稍后可重试）'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 168,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        itemCount: widget.plugins.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final p = widget.plugins[i];
          final payload = _payloads[p.id];
          final loading = _loading.contains(p.id);
          // build140（反馈①同源）：配色必须在**每项自己的元素**上读。
          // 原先 `cs` 取自本 State 的 build()：主题切换时本组件确实会重建，
          // 但 itemBuilder 的 context 是 SliverList 的共享元素，**已画出来的
          // 卡片不会跟着重新 build**，于是它们把旧主题的 `cs` 一直带着
          //（详见 conversation_list_screen 的同名注释）。
          return Builder(builder: (context) {
          final cs = Theme.of(context).colorScheme;
          return SizedBox(
            width: 248,
            child: Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(
                        child: Text(
                          p.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      if (_updated[p.id] != null)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: Text(_updated[p.id]!,
                              style: TextStyle(
                                  fontSize: 10, color: cs.onSurfaceVariant)),
                        ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: '刷新',
                        icon: loading
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.refresh, size: 18),
                        onPressed: () => _refreshOne(p),
                      ),
                    ]),
                    ...p.fields.take(4).map((f) {
                      final value = payload == null
                          ? null
                          : resolveJsonPath(payload, f.path);
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1),
                        child: Text(
                          '${f.label}：${value ?? '—'}${f.suffix}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12.5, color: cs.onSurface),
                        ),
                      );
                    }),
                    if (p.fields.length > 4)
                      Text('…共 ${p.fields.length} 项',
                          style: TextStyle(
                              fontSize: 10.5, color: cs.onSurfaceVariant)),
                    const Spacer(),
                    if (p.linkOnTap.isNotEmpty)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 6)),
                          onPressed: () => _openLink(p.linkOnTap),
                          icon: const Icon(Icons.open_in_new, size: 14),
                          label: const Text('查看',
                              style: TextStyle(fontSize: 12)),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
          });
        },
      ),
    );
  }

  Future<void> _openLink(String url) async {
    // B-003：统一走 LauncherUtils（内部含 guardActivityTransition + 120s 兜底），
    // 避免从浏览器返回时被误判为「后台返回」而误弹生物锁。
    final ok = await LauncherUtils.openExternalUrl(url);
    if (mounted && !ok) {
      AppSnackBar.showSnackBar(context, const SnackBar(
        content: Text('未能打开链接（可能未安装目标应用）'),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 2),
      ));
    }
  }
}
