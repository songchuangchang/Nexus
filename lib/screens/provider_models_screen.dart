import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/api_account.dart';
import '../models/api_config.dart';
import '../models/api_provider_template.dart';
import '../services/storage_service.dart';
import '../ui/tokens.dart';
import '../utils/app_snackbar.dart';
import '../utils/provider_config_flow.dart';
import '../widgets/vendor_avatar.dart';
import 'api_config_edit_screen.dart';

/// build138 · B 批（交接单 §7.2 之 B）：**二级页 = 一个厂商下的模型列表**。
///
/// 立项原因（用户原话）：「先点到模型，再切配置那种从大到小」。
/// 改动前的路径是反的：设置 → API 配置 → 一屏平铺的「我的配置」→ 点进某条配置
/// → 在 1300 行的编辑页里再挑厂商、再挑模型。用户想用的是**模型**，
/// 但入口给的是**连接**。
///
/// 现在的层级：厂商（一级，`ApiConfigScreen`）→ **本页：模型** → 编辑页（详情：
/// 地址 / Key / 参数）。9 个 push `ApiConfigScreen` 的调用点因此全部不用改。
///
/// ⚠️ 本页**不直接写库**。点模型 = 生成一份预填好的草稿配置（复用该厂商已存的 Key
/// 与地址）并交给编辑页；用户在编辑页点「保存」才落库。理由见
/// [draftConfigForModel] 的设计说明 ①：静默建一条没 Key 的配置会被
/// ModelSwitcher 列出来，用户选中它就是 401，比原来更糟。
class ProviderModelsScreen extends StatefulWidget {
  const ProviderModelsScreen({super.key, required this.templateId});

  /// 传 id 而不是对象：模板表会被远程 JSON 覆盖（G46 字段级合并），
  /// 传 id 让本页每次都用**生效表**里的那一条，不会拿着一份过期副本。
  final String templateId;

  @override
  State<ProviderModelsScreen> createState() => _ProviderModelsScreenState();
}

class _ProviderModelsScreenState extends State<ProviderModelsScreen> {
  List<ApiConfig> _configs = const [];

  /// build138（G45）：该厂商的**账号**。二级页的「连接概览」与新建草稿都以它为准，
  /// 不再从多条配置里猜 Key（那是「同厂商两个模型改 Key 要改两遍」的老路）。
  List<ApiAccount> _accounts = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final storage = context.read<StorageService>();
    await storage.init();
    final all = await storage.getApiConfigs();
    final accounts = await storage.getApiAccounts();
    if (!mounted) return;
    setState(() {
      _configs = all;
      _accounts = accounts;
      _loading = false;
    });
  }

  ApiProviderTemplate? get _template => ApiProviderTemplateCatalog
      .instance.all
      .where((t) => t.id == widget.templateId)
      .firstOrNull;

  /// 该厂商已有的配置（Key / 使用中判定 / 在线模型缓存都从这里取）
  List<ApiConfig> get _mine =>
      _template == null ? const [] : configsForTemplate(_configs, _template!);

  /// 该厂商的账号（G45）；[donor] 是「新模型该挂在哪个连接下」的答案。
  List<ApiAccount> get _myAccounts =>
      _template == null ? const [] : accountsForTemplate(_accounts, _template!);

  ApiAccount? get _donor =>
      _template == null ? null : donorAccountFor(_accounts, _template!);

  /// 概览行显示的连接地址：**账号里真实存着的**优先，其次才是模板预设。
  /// 用户填过自建中转时，这里必须显示他的地址，否则「已配置」三个字是假的。
  String get _effectiveBaseUrl {
    final t = _template;
    if (t == null) return '';
    final fromAccount = _donor?.baseUrl.trim() ?? '';
    if (fromAccount.isNotEmpty) return fromAccount;
    for (final c in _mine) {
      final u = c.baseUrl.trim();
      if (u.isNotEmpty) return u;
    }
    return t.baseUrl;
  }

  /// 在线拉过并缓存下来的模型（编辑页「刷新模型列表」的产物）。
  /// 与内置预设去重后合并：预设是本项目的权威表，缓存代表用户账号里真实可用的。
  ///
  /// build138（G45）：**账号的 cachedModels 也要读**。在线列表是端点属性，
  /// 归账号之后它只存在 api_accounts 上；只扫条目的话，新建的第二、第三个模型
  /// 名下是空的，这一栏会凭空少一半（「能力在、读错地方」正是本项目的高频 bug）。
  List<String> get _liveOnly {
    final t = _template;
    if (t == null) return const [];
    final preset = t.models.map((m) => m.id).toSet();
    final out = <String>[];
    for (final source in <List<String>>[
      for (final a in _myAccounts) a.cachedModelsList,
      for (final c in _mine) c.cachedModelsList,
    ]) {
      for (final id in source) {
        if (id.trim().isEmpty) continue;
        if (preset.contains(id)) continue;
        if (out.contains(id)) continue;
        out.add(id);
      }
    }
    return out;
  }

  Future<void> _openModel(String modelId) async {
    final t = _template;
    if (t == null) return;
    final draft = draftConfigForModel(
        template: t, modelId: modelId, all: _configs, accounts: _accounts);
    if (isModelInUse(_mine, modelId)) {
      // 已有配置在跑这个模型：不再新建，只告诉用户它在哪，避免同厂商堆重复配置。
      final holder = _mine.firstWhere((c) => c.model.trim() == modelId.trim());
      if (!mounted) return;
      final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
      AppSnackBar.showSnackBar(
        context,
        SnackBar(
          content: Text(isZh
              ? '「${holder.name}」已在用 ${holder.model}，点它可以改参数'
              : '"${holder.name}" already uses ${holder.model} - tap it to edit'),
          duration: AppDur.toast,
          behavior: SnackBarBehavior.floating,
          width: 320,
        ),
      );
      return;
    }
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ApiConfigEditScreen(config: draft),
      ),
    );
    if (!mounted) return;
    await _load();
  }

  /// 删账号前的确认：把「会带走几个模型、几条对话」说清楚再动手。
  ///
  /// 为什么必须弹确认（任务书红线「破坏性操作必须弹确认」）：删账号是
  /// 级联删除 —— 沿用现有删配置语义，连对话与消息一起走（storage 侧同事务），
  /// 点错一下就不可撤销。
  Future<void> _confirmDeleteAccounts(
      List<ApiAccount> accounts, bool isZh) async {
    final storage = context.read<StorageService>();
    final ids = accounts.map((a) => a.id).toSet();
    final children =
        _configs.where((c) => ids.contains(c.accountId)).toList(growable: false);
    final convCount = (await storage.getConversations())
        .where((cv) => children.any((c) => c.id == cv.apiConfigId))
        .length;
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isZh ? '删除账号？' : 'Delete account?'),
        content: Text(isZh
            ? '将删除 ${accounts.length} 个连接、${children.length} 个模型条目'
                '${convCount > 0 ? '，以及它们的 $convCount 条对话（含消息）' : ''}。此操作不可撤销。'
            : 'Removes ${accounts.length} connection(s) and ${children.length} '
                'model(s)${convCount > 0 ? ' plus $convCount conversation(s)' : ''}. '
                'This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(isZh ? '取消' : 'Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(isZh ? '删除' : 'Delete')),
        ],
      ),
    );
    if (ok != true) return;
    for (final a in accounts) {
      await storage.deleteApiAccount(a.id);
    }
    if (!mounted) return;
    AppSnackBar.showSnackBar(
      context,
      SnackBar(
        content: Text(isZh ? '已删除账号与其下的模型' : 'Account and its models deleted'),
        duration: AppDur.toast,
        behavior: SnackBarBehavior.floating,
        width: 320,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final isZh = l.locale.languageCode == 'zh';
    final cs = Theme.of(context).colorScheme;
    final t = _template;
    if (t == null) {
      // 模板被远程表移除（理论上不会发生，但这里必须如实说，而不是白屏）
      return Scaffold(
        appBar: AppBar(title: Text(isZh ? '模型' : 'Models')),
        body: Center(
          child: Text(isZh ? '这个服务商已不在预设列表里' : 'Provider no longer available'),
        ),
      );
    }
    final mine = _mine;
    final accounts = _myAccounts;
    final live = _liveOnly;
    return Scaffold(
      appBar: AppBar(
        title: Text(isZh ? t.nameZh : t.nameEn),
        actions: [
          if (accounts.isNotEmpty)
            IconButton(
              // G45「删账号」：删的是**连接**（连同它名下全部模型条目），
              // 不是某一条模型 —— 所以放在账号级入口，与右上角的
              // 「配置详情」（也是账号级）成对。
              tooltip: isZh ? '删除该厂商的账号（含其下全部模型）' : 'Delete account (and its models)',
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                await _confirmDeleteAccounts(accounts, isZh);
                if (!mounted) return;
                await _load();
              },
            ),
          IconButton(
            tooltip: isZh ? '配置详情（地址 / Key）' : 'Connection details',
            icon: const Icon(Icons.tune),
            onPressed: () async {
              final draft = draftConfigForModel(
                  template: t,
                  modelId: t.defaultModel,
                  all: _configs,
                  accounts: _accounts);
              await Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) =>
                        ApiConfigEditScreen(config: mine.isEmpty ? draft : mine.first)),
              );
              if (!mounted) return;
              await _load();
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(AppGap.md, AppGap.md, AppGap.md, 96),
              children: [
                // ── 连接概览：一眼看清「有没有 Key / 用哪个地址」，
                //    这是从一级页带进来的上下文，缺了它用户就得再点回编辑页才知道。
                AppSectionCard(
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: VendorAvatar(templateId: t.id, size: 28),
                      title: Text((isZh ? t.descZh : t.descEn).isEmpty
                          ? (isZh ? t.nameZh : t.nameEn)
                          : (isZh ? t.descZh : t.descEn)),
                      subtitle: Text(
                        // G45：显示**账号里存的**地址（用户自建中转不会被模板地址顶掉）
                        _effectiveBaseUrl.isEmpty
                            ? (isZh ? '本地服务（无需地址）' : 'Local server (no URL needed)')
                            : _effectiveBaseUrl,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Row(
                      children: [
                        _Badge(
                          label: templateIsConfigured(mine, t)
                              ? (isZh ? '已配置' : 'Configured')
                              : (isZh ? '未配置' : 'Not configured'),
                          positive: templateIsConfigured(mine, t),
                        ),
                        const SizedBox(width: 6),
                        _Badge(
                          // G45 的「一把 Key 多模型」要在 UI 上看得境：账号数与模型数
                          // 分开报，用户才能一眼看出「加第二个模型不用再填 Key」。
                          label: isZh
                              ? (accounts.isEmpty
                                  ? '尚无账号'
                                  : '账号 ${accounts.length} 个 · 模型 ${mine.length} 条')
                              : (accounts.isEmpty
                                  ? 'No account yet'
                                  : '${accounts.length} account(s) · ${mine.length} model(s)'),
                          positive: accounts.isNotEmpty || mine.isNotEmpty,
                        ),
                      ],
                    ),
                  ],
                ),

                // ── 模型（本批的主角）：预设表在前，账号里真实可用的补在后面
                AppSectionCard(
                  title: isZh ? '模型' : 'Models',
                  children: [
                    for (final m in t.models)
                      _modelTile(
                        isZh: isZh,
                        modelId: m.id,
                        title: m.displayName(isZh),
                        subtitle: m.note(isZh) ?? '',
                        recommended: m.recommended,
                        mine: mine,
                      ),
                    if (t.models.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          isZh
                              ? '这个服务商没有预设模型，请在右上角「配置详情」里手填模型名'
                              : 'No preset models - type the model name in connection details',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                  ],
                ),
                if (live.isNotEmpty)
                  AppSectionCard(
                    // build177：原来 zh 支写的是 `（$live.length）`——`$live` 只吃变量本身，
                    // `.length）` 是字面文本，于是屏上真印出「…其它模型（[a, b, …].length）」
                    // （平板 J30 的 `absent` 新闸命中 `'.length）'` 抓到的）。en 支一直是对的。
                    title: isZh
                        ? '账号里拉到的其它模型（${live.length}）'
                        : 'Other models from your account (${live.length})',
                    children: [
                      for (final id in live)
                        _modelTile(
                          isZh: isZh,
                          modelId: id,
                          title: id,
                          subtitle: isZh ? '来自在线模型缓存' : 'From cached model list',
                          recommended: false,
                          mine: mine,
                        ),
                    ],
                  ),

                // ── 该厂商已有连接：要改 Key / 地址 / 参数从这儿进（三级 = 编辑页）
                if (mine.isNotEmpty)
                  AppSectionCard(
                    title: isZh ? '这个服务商的连接' : 'Connections for this provider',
                    children: [
                      for (final c in mine)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(c.name),
                          subtitle: Text(
                            '${c.model} • ${c.baseUrl.isEmpty ? (isZh ? '本地' : 'local') : c.baseUrl}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Icon(Icons.chevron_right,
                              size: 18, color: cs.onSurfaceVariant),
                          onTap: () async {
                            await Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => ApiConfigEditScreen(config: c)),
                            );
                            if (!mounted) return;
                            await _load();
                          },
                        ),
                    ],
                  ),
              ],
            ),
    );
  }

  Widget _modelTile({
    required bool isZh,
    required String modelId,
    required String title,
    required String subtitle,
    required bool recommended,
    required List<ApiConfig> mine,
  }) {
    final inUse = isModelInUse(mine, modelId);
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: subtitle.isEmpty
          ? null
          : Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: recommended && !inUse
          ? Icon(Icons.star_border, size: 18, color: cs.onSurfaceVariant)
          : inUse
              ? Icon(Icons.check_circle_outline, size: 18, color: cs.primary)
              : Icon(Icons.add, size: 18, color: cs.onSurfaceVariant),
      onTap: () => _openModel(modelId),
    );
  }
}

/// 小徽标（B 批复用）：一级页与二级页共用同一套观感，避免两处各写一遍样式。
class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.positive});

  final String label;
  final bool positive;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fg = positive ? cs.primary : cs.outline;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.inline),
        border: Border.all(color: fg.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: fg),
      ),
    );
  }
}
