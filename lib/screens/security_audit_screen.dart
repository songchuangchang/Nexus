/// 安全审计时间线页（build98 安全审查本地加强⑦）
///
/// 展示 SecurityAuditLog 记录（安装/扫描/拒绝/黑名单命中），最新在前。
library security_audit_screen;

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/security_audit_log.dart';

class SecurityAuditScreen extends StatefulWidget {
  const SecurityAuditScreen({super.key});

  @override
  State<SecurityAuditScreen> createState() => _SecurityAuditScreenState();
}

class _SecurityAuditScreenState extends State<SecurityAuditScreen> {
  List<AuditEvent>? _events;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final events = await SecurityAuditLog.readAll();
    if (mounted) setState(() => _events = events);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final zh = l.locale.languageCode == 'zh';
    final cs = Theme.of(context).colorScheme;
    final events = _events;
    return Scaffold(
      appBar: AppBar(
        title: Text(zh ? '安全审计时间线' : 'Security Audit Timeline'),
        actions: [
          if (events != null && events.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: zh ? '清空记录' : 'Clear',
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: Text(zh ? '清空审计记录？' : 'Clear audit log?'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: Text(zh ? '取消' : 'Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: Text(zh ? '清空' : 'Clear')),
                    ],
                  ),
                );
                if (ok == true) {
                  await SecurityAuditLog.clear();
                  await _load();
                }
              },
            ),
        ],
      ),
      body: events == null
          ? const Center(child: CircularProgressIndicator())
          : events.isEmpty
              ? Center(
                  child: Text(
                    zh ? '暂无审计记录' : 'No audit records yet',
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: events.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final e = events[i];
                    // build140（反馈①同源）：懒加载行拿的是 SliverList 的**共享元素**，
                    // 主题切换后已画出来的行不重建，会把外层 build 捕获的 `cs` 一直带着
                    //（表现：改了配色，这里的图标颜色不刷新）。包 Builder 取值。
                    return Builder(builder: (context) {
                    final cs = Theme.of(context).colorScheme;
                    final bool zh = AppLocalizations.of(context)
                            .locale
                            .languageCode ==
                        'zh';
                    final (icon, color) = switch (e.outcome) {
                      'blocked' => (Icons.block, cs.error),
                      'warn' => (Icons.warning_amber_rounded, cs.tertiary),
                      'failed' => (Icons.error_outline, cs.error),
                      _ => (Icons.check_circle_outline, cs.primary),
                    };
                    return ListTile(
                      dense: true,
                      leading: Icon(icon, color: color, size: 20),
                      title: Text(
                        '${_typeLabel(e.type, zh)} · ${e.target}',
                        style: const TextStyle(fontSize: 13),
                      ),
                      subtitle: e.detail.isEmpty
                          ? null
                          : Text(e.detail,
                              style: const TextStyle(fontSize: 11),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis),
                      trailing: Text(
                        _fmt(e.time),
                        style: TextStyle(
                            fontSize: 10, color: cs.onSurfaceVariant),
                      ),
                    );
                    });
                  },
                ),
    );
  }

  String _typeLabel(String type, bool zh) => switch (type) {
        'scan' => zh ? '扫描' : 'Scan',
        'install' => zh ? '安装' : 'Install',
        'reject' => zh ? '拒绝' : 'Reject',
        'blacklist_hit' => zh ? '黑名单命中' : 'Blacklist hit',
        _ => type,
      };

  String _fmt(DateTime dt) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.month}/${dt.day} ${two(dt.hour)}:${two(dt.minute)}';
  }
}
