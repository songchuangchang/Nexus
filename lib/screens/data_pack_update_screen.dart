import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/data_pack_service.dart';
import '../ui/tokens.dart';
import '../utils/app_snackbar.dart';

/// build138 / G54–G56：设置 →「数据包更新」页。
///
/// 立项原因：默认源指向的 GitHub 仓库是**私有**的，raw / ghproxy 镜像 / jsdelivr
/// 对私有仓库一律 404/403 ⇒ 远程数据包永远拉不到，用户端只剩 APK 内置数据，
/// 而界面上一句原因都不给（交接单称之为「静默失效」）。
///
/// 这一页只做三件事，判定逻辑全在 [DataPackService] + data_pack_protocol 纯函数里：
///   ① 逐包显示 内置版本 / 当前版本 / 更新时间 / 状态（含失败原因）
///   ②「检查更新」手动拉全部，一次提示结果（已是最新 / 更新条数 / 失败原因）
///   ③ 自定义源（每行一个，按序回退）填入后立即生效
///
/// 断网与 404 的文案在 [describeDataPackReject]，中英内联，不进 arb。
class DataPackUpdateScreen extends StatefulWidget {
  const DataPackUpdateScreen({super.key});

  @override
  State<DataPackUpdateScreen> createState() => _DataPackUpdateScreenState();
}

class _DataPackUpdateScreenState extends State<DataPackUpdateScreen> {
  final DataPackService _svc = DataPackService.instance;
  bool _busy = false;

  /// 「自定义源」弹层的输入控制器：**随页面创建、随页面释放**。
  /// 弹层关闭后还要读 .text（保存分支），而对话框退场动画期间子树会逐帧重建，
  /// 在 await 之后立刻 dispose() 会让 TextField 撞上「控制器已释放」断言
  /// （本仓库 P3 释放约定里「关闭后仍要读 .text ⇒ 延后释放」的同一类）。
  TextEditingController? _sourcesCtrl;

  @override
  void dispose() {
    _sourcesCtrl?.dispose();
    super.dispose();
  }

  Future<void> _checkAll() async {
    final zh = _isZh;
    setState(() => _busy = true);
    final states = await _svc.checkAll();
    if (!mounted) return;
    setState(() => _busy = false);
    AppSnackBar.showSnackBar(
        context, SnackBar(content: Text(summarizeCheckResults(states, zh))));
  }

  Future<void> _refreshOne(String id) async {
    setState(() => _busy = true);
    final state = await _svc.refreshPack(id);
    if (!mounted) return;
    setState(() => _busy = false);
    if (state == null) return;
    AppSnackBar.showSnackBar(
        context, SnackBar(content: Text('${state.name(_isZh)}：${state.describe(_isZh)}')));
  }

  /// S1（build172）：用户对挂起的「baseUrl 改写」载荷点「确认应用」。
  Future<void> _confirmPending(String id) async {
    setState(() => _busy = true);
    final state = await _svc.confirmPending(id);
    if (!mounted) return;
    setState(() => _busy = false);
    if (state == null) return;
    AppSnackBar.showSnackBar(
        context, SnackBar(content: Text('${state.name(_isZh)}：${state.describe(_isZh)}')));
  }

  /// S1：用户点「放弃」——只清挂起，基线不动（下次拉取同载荷仍会再挂起）。
  Future<void> _discardPending(String id) async {
    final zh = _isZh;
    setState(() => _busy = true);
    final state = await _svc.discardPending(id);
    if (!mounted) return;
    setState(() => _busy = false);
    if (state == null) return;
    AppSnackBar.showSnackBar(
        context,
        SnackBar(
            content: Text(zh
                ? '${state.name(zh)}：已放弃待确认载荷，继续使用当前生效数据'
                : '${state.name(zh)}: pending payload discarded')));
  }

  bool get _isZh =>
      AppLocalizations.of(context).locale.languageCode == 'zh';

  /// 自定义源：每行一个 URL，按「主 → 备」顺序尝试；清空则回到内置默认源。
  Future<void> _editSources(DataPackState state) async {
    final zh = _isZh;
    final controller = _sourcesCtrl ??= TextEditingController();
    controller.text = encodeDataPackSources(state.sourceUrls);
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(zh ? '自定义数据源' : 'Custom sources'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              zh
                  ? '${state.nameZh}\n每行一个 JSON 地址，按顺序尝试：主源失败（网络中断 / 404 / 403）才切下一个。全部留空则使用内置默认源。'
                  : '${state.nameEn}\nOne URL per line, tried in order: the next one is only used when the previous fails (offline / 404 / 403). Leave empty for the built-in defaults.',
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: AppGap.sm),
            TextField(
              controller: controller,
              maxLines: 5,
              decoration: InputDecoration(
                labelText: zh ? '源地址列表' : 'Source URLs',
                hintText: 'https://example.com/packs/${state.id}.json',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(zh ? '取消' : 'Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(zh ? '保存并立即检查' : 'Save & check')),
        ],
      ),
    );
    if (!mounted) return;
    if (saved == true) {
      await _svc.setCustomSources(
          state.id, parseDataPackSources(controller.text));
      if (mounted) await _refreshOne(state.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final zh = _isZh;
    return Scaffold(
      appBar: AppBar(
        title: Text(zh ? '数据包更新' : 'Data packs'),
        actions: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(AppGap.lg),
              child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else
            IconButton(
              tooltip: zh ? '检查更新' : 'Check for updates',
              icon: const Icon(Icons.refresh),
              onPressed: _checkAll,
            ),
        ],
      ),
      body: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.2,
        child: ListenableBuilder(
          listenable: _svc,
          builder: (context, _) {
            final states = _svc.states;
            return ListView(
              padding: AppPad.page,
              children: [
                Text(
                  zh
                      ? '这些数据包离线也能用（APK 内置兜底）。联网后按 7 天节奏后台刷新；'
                          '远程包必须比内置版本更新、且通过 sha256 校验才会被应用，'
                          '任何失败都保留内置与上次成功的缓存。'
                      : 'These packs work offline (built into the APK). '
                          'They refresh in the background every 7 days. '
                          'A remote pack is applied only if it is newer and passes '
                          'sha256 verification; on any failure the built-in data '
                          'and the last good cache are kept.',
                  style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: AppGap.lg),
                for (final s in states) _packCard(s, zh),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _packCard(DataPackState s, bool zh) {
    final cs = Theme.of(context).colorScheme;
    // S1（build172）：该包有挂起的「baseUrl 改写」载荷 ⇒ 卡片内加确认条。
    final pending = _svc.pendingOf(s.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppGap.md),
      child: AppSectionCard(
        title: '${s.name(zh)} · ${s.statusLabel(zh)}',
        children: [
          Padding(
            // build163：水平留白归 `AppSectionCard` 给（这里再写 12 就成 24）
            padding: const EdgeInsets.fromLTRB(0, 0, 0, AppGap.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  zh
                      ? '当前版本 ${s.remoteDataVersion ?? '—'}'
                      : 'Current ${s.remoteDataVersion ?? '-'}',
                  style: const TextStyle(fontSize: 12),
                ),
                Text(
                  zh
                      ? '更新时间 ${formatDataPackTime(s.lastUpdatedAt, true)}'
                      : 'Updated ${formatDataPackTime(s.lastUpdatedAt, false)}',
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(height: AppGap.xs),
                Text(
                  s.describe(zh),
                  style: TextStyle(
                    fontSize: 12,
                    color: s.status == DataPackStatus.failed
                        ? cs.error
                        : cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppGap.sm),
                for (var i = 0; i < s.sourceUrls.length; i++)
                  Text(
                    '${zh ? '源' : 'Source'} ${i + 1} · ${s.sourceUrls[i]}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: cs.appTextSub),
                  ),
                const SizedBox(height: AppGap.sm),
                Wrap(
                  spacing: AppGap.sm,
                  children: [
                    OutlinedButton(
                      onPressed: _busy ? null : () => _refreshOne(s.id),
                      child: Text(zh ? '检查此包' : 'Check this pack'),
                    ),
                    OutlinedButton(
                      onPressed: () => _editSources(s),
                      child: Text(zh ? '自定义源' : 'Edit sources'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (pending != null) _pendingBanner(pending, zh, cs),
        ],
      ),
    );
  }

  /// S1（build172）：apiTemplates 包检出「远程改写内置厂商 baseUrl」时的
  /// 二次确认条。逐条列出 id / 显示名与新旧地址；确认才应用，放弃则本轮不用
  /// （下次拉到同一份载荷仍会再挂起，直到用户处理——有意为之）。
  Widget _pendingBanner(
      DataPackPendingConfirmation pending, bool zh, ColorScheme cs) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppGap.sm),
      decoration: BoxDecoration(
        color: cs.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            zh
                ? '需要确认：远程包要把 ${pending.overrides.length} 个内置厂商的'
                    '请求地址改成下列地址。逐条核对后才会应用；不确认则继续用现地址。'
                : 'Confirmation required: the remote pack wants to change the '
                    'request URLs of ${pending.overrides.length} built-in '
                    'providers to the addresses below. Nothing is applied '
                    'until you verify and confirm.',
            style: TextStyle(fontSize: 12, color: cs.onErrorContainer),
          ),
          for (final o in pending.overrides)
            Padding(
              padding: const EdgeInsets.only(top: AppGap.xs),
              child: Text(
                '${o.id} · ${o.nameZh}\n'
                '${zh ? '现地址' : 'current'} ${o.builtinBaseUrl}\n'
                '${zh ? '改为' : 'new'} ${o.remoteBaseUrl}',
                style: TextStyle(fontSize: 11, color: cs.onErrorContainer),
              ),
            ),
          const SizedBox(height: AppGap.sm),
          Wrap(
            spacing: AppGap.sm,
            runSpacing: AppGap.sm,
            children: [
              FilledButton(
                onPressed: _busy ? null : () => _confirmPending(pending.packId),
                child: Text(zh
                    ? '确认应用（我已核对这些地址）'
                    : 'Apply (I verified these URLs)'),
              ),
              OutlinedButton(
                onPressed: _busy ? null : () => _discardPending(pending.packId),
                child: Text(zh ? '放弃' : 'Discard'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
