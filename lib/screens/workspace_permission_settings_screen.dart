import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../ui/tokens.dart';
import '../utils/app_snackbar.dart';
import '../utils/workspace_permission.dart';

/// build138（甲1）：AI 文件工作区「权限档位」设置页。
///
/// 立项原因（缺失 UI 预览评审）：`_wsConfirm()` 此前硬编码「每次必弹」，
/// 全库没有任何档位字段 ⇒ 用户无法在「反复迭代同一个文件」时少按几次确认。
/// 交接单红线：权限档位**必须与 UI 同批**——只做服务没有入口＝用户够不着＝等于不存在。
///
/// 消费点在 lib/plugins/builtin_plugins.dart 的 `_wsConfirm()`，
/// 判定逻辑是 lib/utils/workspace_permission.dart 的纯函数 [wsNeedsConfirm]
/// （三档矩阵有单测锁）。删除操作任何档位都必弹，这一层界面也不给关。
class WorkspacePermissionSettingsScreen extends StatefulWidget {
  const WorkspacePermissionSettingsScreen({super.key});

  @override
  State<WorkspacePermissionSettingsScreen> createState() =>
      _WorkspacePermissionSettingsScreenState();
}

class _WorkspacePermissionSettingsScreenState
    extends State<WorkspacePermissionSettingsScreen> {
  WsPermissionTier _tier = WsPermissionTier.alwaysAsk;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    WorkspacePermissionStore.load().then((t) {
      if (!mounted) return;
      setState(() {
        _tier = t;
        _loaded = true;
      });
    });
  }

  Future<void> _setTier(WsPermissionTier next) async {
    final zh = AppLocalizations.of(context).locale.languageCode == 'zh';
    if (next == _tier) return;
    // 破坏性方向（放宽权限）必须二次确认；收紧权限（往「每次确认」退）不需要。
    if (next != WsPermissionTier.alwaysAsk) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(next == WsPermissionTier.autoAll
              ? (zh ? '切到「全自动」？' : 'Switch to Full auto?')
              : (zh ? '切到「自动改文件」？' : 'Switch to Auto-edit files?')),
          content: Text(next == WsPermissionTier.autoAll
              ? (zh
                  ? 'AI 新建、修改、覆盖文件将不再询问你，直接落盘。\n删除文件仍会弹确认 —— 这一层不给关掉。'
                  : 'AI will create, edit and overwrite files without asking.\nDelete still confirms — that layer cannot be turned off.')
              : (zh
                  ? 'AI 新建与修改文件不再询问你。\n删除文件、覆盖已有文件仍会弹确认。'
                  : 'AI creates and patches files without asking.\nDelete and overwrite still confirm.')),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(zh ? '取消' : 'Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(zh ? '我已了解，切换' : 'I understand')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    await WorkspacePermissionStore.save(next);
    if (!mounted) return;
    setState(() => _tier = next);
    AppSnackBar.showSnackBar(
        context,
        SnackBar(
            content: Text(zh
                ? '已切换：${wsPermissionTierLabel(next, true).title}'
                : 'Switched: ${wsPermissionTierLabel(next, false).title}')));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final zh = l.locale.languageCode == 'zh';
    return Scaffold(
      appBar: AppBar(
          title: Text(zh ? 'AI 文件工作区' : 'AI file workspace')),
      body: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.2,
        child: ListView(
          padding: AppPad.page,
          children: [
            Text(
              zh
                  ? 'AI 可以读、写、改、删你手机上的工作区文件（沙箱目录，路径逃不出工作区）。选一个许可档位。'
                  : 'AI can read, write, edit and delete files in your workspace (sandboxed: paths cannot escape it). Pick a permission tier.',
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: AppGap.lg),
            AppSectionCard(
              title: zh ? '许可档位' : 'Permission tier',
              children: [
                if (!_loaded)
                  const Padding(
                      padding: EdgeInsets.all(AppGap.md),
                      child: Center(
                          child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2))))
                else
                  for (final tier in WsPermissionTier.values)
                    _tierTile(context, tier, zh),
              ],
            ),
            const SizedBox(height: AppGap.lg),
            AppSectionCard(
              title: zh ? '危险操作（任何档位都强制确认）' : 'Always confirmed',
              children: [
                _lockedRow(zh
                    ? '删除文件 ws_delete —— 始终弹确认，不可关闭'
                    : 'ws_delete — always confirms, cannot be disabled'),
                _lockedRow(zh
                    ? '覆盖已有文件 ws_write overwrite=true —— 「自动改文件」档仍弹'
                    : 'ws_write overwrite=true — still confirms on Auto-edit files'),
                _lockedRow(zh
                    ? '单次补丁超出上限整体拒绝 —— ws_patch 事务式，失败时文件一个字节都不动'
                    : 'Oversized ws_patch is rejected as a whole — transactional, file untouched'),
              ],
            ),
            const SizedBox(height: AppGap.lg),
            Text(
              zh
                  ? '当前：${wsPermissionTierLabel(_tier, true).title}'
                  : 'Current: ${wsPermissionTierLabel(_tier, false).title}',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tierTile(BuildContext context, WsPermissionTier tier, bool zh) {
    final cs = Theme.of(context).colorScheme;
    final label = wsPermissionTierLabel(tier, zh);
    final selected = _tier == tier;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(
          horizontal: AppGap.md, vertical: AppGap.xs),
      // 单选态用 Material 单选图标本体（不用 Radio 组件：Flutter 3.47 已把
      // Radio.groupValue 那套 API 标deprecated，棘轮分析要求零 issue）。
      leading: Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_off,
          color: selected ? cs.primary : cs.onSurfaceVariant),
      title: Text(label.title),
      subtitle: Text(label.desc, style: const TextStyle(fontSize: 12)),
      selected: selected,
      onTap: () => _setTier(tier),
    );
  }

  Widget _lockedRow(String text) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppGap.md, vertical: AppGap.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lock_outline, size: 15, color: cs.onSurfaceVariant),
          const SizedBox(width: AppGap.sm),
          Expanded(
              child: Text(text,
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant))),
        ],
      ),
    );
  }
}
