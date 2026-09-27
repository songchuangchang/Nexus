import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/api_account.dart';
import '../models/api_config.dart';
import '../models/api_provider_template.dart';
import '../services/storage_service.dart';
import '../ui/tokens.dart';
import '../utils/provider_config_flow.dart';
import '../widgets/vendor_avatar.dart';
import 'api_config_edit_screen.dart';
import 'api_config_screen.dart';
import 'provider_models_screen.dart';

/// build138 · B 批（交接单 §7.2 之 B）：**一级页 = 选厂商**（从大到小：厂商 → 模型 → 详情）。
///
/// 用户原话：「先点到模型，再切配置那种从大到小」。改动前的路径是反的——
/// 设置里点「API 配置」直接落到一屏平铺的「我的配置」，要点进某条配置、
/// 在 1300 多行的编辑页里再挑厂商、再挑模型。用户想用的是**模型**，
/// 而入口给的是**连接**。
///
/// 现在：本页（厂商，带「已配置 / 未配置」徽标）→ [ProviderModelsScreen]（模型）
/// → [ApiConfigEditScreen]（地址 / Key / 参数）。
/// 原来的整表列表整体降级为顶部一行入口 [ConnectedConfigsScreen]，功能一条不减
/// （滑动删除带二次确认、单项导出、余额行、点进去编辑）。
///
/// 类名之所以还叫 `ApiConfigScreen`：全库有 9 处 push 它
/// （main.dart / model_switcher / about_settings / quick_access_menu / chat_screen_react /
/// conversation_list / image_gen / video_gen 等）。改结构不该顺手改路由入口，
/// 所以由 `api_config_screen.dart` 用 `export` 把这个名字转出去，
/// 9 个调用点一行都不用动。
class ApiConfigScreen extends StatefulWidget {
  const ApiConfigScreen({super.key});

  @override
  State<ApiConfigScreen> createState() => _ProviderHomeState();
}

class _ProviderHomeState extends State<ApiConfigScreen> {
  List<ApiConfig> _configs = const [];

  /// build138（G45）：账号列表，只用于一级页的「N 个模型」这一行摘要。
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

  static String _groupName(ApiProviderGroup g, bool isZh) {
    switch (g) {
      case ApiProviderGroup.domestic:
        return isZh ? '国内服务商' : 'Domestic providers';
      case ApiProviderGroup.international:
        return isZh ? '国际服务商' : 'International providers';
      case ApiProviderGroup.local:
        return isZh ? '本地模型' : 'Local models';
    }
  }

  Future<void> _push(Widget page) async {
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => page));
    if (!mounted) return;
    await _load();
  }

  /// 「已配置」徽标的口径只有一个来源：[templateIsConfigured]。
  /// 一级页与二级页必须同一判据，否则会出现一级说「已配置」、二级说「未配置」。
  Widget _providerTile(ApiProviderTemplate t, bool isZh) {
    final cs = Theme.of(context).colorScheme;
    final mine = configsForTemplate(_configs, t);
    final configured = templateIsConfigured(mine, t);
    final fg = configured ? cs.primary : cs.outline;
    // build138（G45 / 任务书 §二）：徽标之外再报「几个账号 · 几个模型」——
    // 一级页要能一眼看出「一个 Key 挂了多个模型」，只显示条数会让人以为
    // 每个模型都是一次独立配置。
    final acctCount =
        accountsForTemplate(_accounts, t).length;
    final detail = !configured || mine.isEmpty
        ? ''
        : (isZh
            ? (acctCount > 1
                ? ' · 账号 $acctCount 个 · 模型 ${mine.length} 个'
                : ' · ${mine.length} 个模型')
            : (acctCount > 1
                ? ' · $acctCount accounts · ${mine.length} models'
                : ' · ${mine.length} model(s)'));
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: VendorAvatar(templateId: t.id, size: 28),
      title: Text(isZh ? t.nameZh : t.nameEn),
      subtitle: Text(
        ((isZh ? t.descZh : t.descEn).trim().isEmpty
            ? (t.baseUrl.isEmpty ? (isZh ? '本地服务' : 'Local') : t.baseUrl)
            : (isZh ? t.descZh : t.descEn)) +
            detail,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.inline),
              border: Border.all(color: fg.withValues(alpha: 0.5)),
            ),
            child: Text(
              configured ? (isZh ? '已配置' : 'Configured') : (isZh ? '未配置' : 'Set up'),
              style:
                  Theme.of(context).textTheme.labelSmall?.copyWith(color: fg),
            ),
          ),
          Icon(Icons.chevron_right, size: 18, color: cs.onSurfaceVariant),
        ],
      ),
      onTap: () => _push(ProviderModelsScreen(templateId: t.id)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    final cs = Theme.of(context).colorScheme;
    final templates = ApiProviderTemplateCatalog.instance.all;
    final buckets = <ApiProviderGroup, List<ApiProviderTemplate>>{
      for (final g in ApiProviderGroup.values) g: <ApiProviderTemplate>[],
    };
    for (final t in templates) {
      buckets[t.group]!.add(t);
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(isZh ? '模型与服务商' : 'Models & providers'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding:
                  const EdgeInsets.fromLTRB(AppGap.lg, AppGap.md, AppGap.lg, 96),
              children: [
                AppSectionCard(
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.link, color: cs.primary),
                      title: Text(isZh
                          ? '已连接的配置（${_configs.length}）'
                          : 'Connected configs (${_configs.length})'),
                      subtitle: Text(
                        isZh
                            ? '删除、看余额、改地址与参数都在这里'
                            : 'Delete, balance, base URL and parameters',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Icon(Icons.chevron_right,
                          size: 18, color: cs.onSurfaceVariant),
                      onTap: () => _push(const ConnectedConfigsScreen()),
                    ),
                  ],
                ),
                if (_configs.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppGap.md),
                    child: Text(
                      isZh
                          ? '还没有任何连接：在下面挑一个服务商，再挑一个模型即可。'
                          : 'No connections yet — pick a provider below, then a model.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                for (final g in ApiProviderGroup.values)
                  if (buckets[g]!.isNotEmpty)
                    AppSectionCard(
                      title: _groupName(g, isZh),
                      children: [for (final t in buckets[g]!) _providerTile(t, isZh)],
                    ),
                // 老路径不删：自建中转 / 私有部署 / 不在预设表里的服务商用它
                AppSectionCard(
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.hub_outlined, color: cs.primary),
                      title: Text(isZh
                          ? '自定义地址（中转站 / 私有部署）'
                          : 'Custom endpoint'),
                      subtitle: Text(isZh
                          ? '手填 Base URL 与模型名'
                          : 'Type base URL and model name yourself'),
                      trailing: Icon(Icons.chevron_right,
                          size: 18, color: cs.onSurfaceVariant),
                      onTap: () =>
                          _push(const ApiConfigEditScreen(config: null)),
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}
