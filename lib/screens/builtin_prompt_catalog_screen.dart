import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../plugins/plugin_interface.dart';
import '../plugins/plugin_registry.dart';
import '../services/builtin_prompt_catalog.dart';
import '../ui/tokens.dart';
import '../utils/app_snackbar.dart';
import 'data_pack_update_screen.dart';

/// build140（P0 缺口⑤）：内置提示词 / ReAct 协议目录浏览页。
///
/// 这条能力从 build93 起就在（`BuiltinPromptCatalog` 被 `api_service`、
/// `plugin_registry`、`data_pack_service` 三方消费），但**没有任何界面看得到它**：
/// 远程 JSON 到底覆盖了哪几条、生效的到底是远程文本还是编译期内置、
/// 模型这一轮实际收到的协议长什么样——以前只能连日志翻或改代码验证。
/// `docs/GAPVSCOMPETITORS` 里记的「死能力」之一就是它。
///
/// 口径（这点很重要）：本页列的是**每个内置插件当前生效的协议正文**，
/// 即 `BuiltinPromptCatalog.resolve(id, 内置默认)` 的返回值，与 `api_service`
/// 注入给模型的是同一个函数、同一个结果。不是"我们把配置抄了一份"，
/// 所以不会出现"页面显示 A、模型收到 B"。
class BuiltinPromptCatalogScreen extends StatefulWidget {
  const BuiltinPromptCatalogScreen({super.key});

  @override
  State<BuiltinPromptCatalogScreen> createState() =>
      _BuiltinPromptCatalogScreenState();
}

class _Entry {
  const _Entry({
    required this.pluginId,
    required this.name,
    required this.triggerType,
    required this.effective,
    required this.overridden,
  });

  final String pluginId;
  final String name;
  final String triggerType;

  /// 生效正文（远程覆盖优先，否则内置默认）
  final String effective;
  final bool overridden;
}

class _BuiltinPromptCatalogScreenState
    extends State<BuiltinPromptCatalogScreen> {
  String _query = '';

  /// 数据源是注册表 + 目录单例，两者都是进程内既有状态 ⇒ 不额外加载。
  /// 唯一会"变"的是远程覆盖：所以每次 build 都重算（条目数 = 内置插件数，几十条，
  /// 代价可忽略），免得"数据包刚更新完，这页还显示旧协议"。
  List<_Entry> _entries(BuildContext context) {
    final registry = context.read<PluginRegistry>();
    final catalog = BuiltinPromptCatalog.instance;
    final out = <_Entry>[];
    for (final ReActPlugin p in registry.plugins) {
      if (p.source != PluginSource.system) continue;
      final builtin = p.metadata.promptProtocol;
      if (builtin.trim().isEmpty) continue;
      out.add(_Entry(
        pluginId: p.metadata.id,
        name: p.metadata.name,
        triggerType: p.triggerType,
        effective: catalog.resolve(p.metadata.id, builtin),
        overridden: catalog.isPromptOverridden(p.metadata.id),
      ));
    }
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final zh = l.locale.languageCode == 'zh';
    final cs = Theme.of(context).colorScheme;
    final all = _entries(context);
    final q = _query.trim().toLowerCase();
    final shown = q.isEmpty
        ? all
        : all
            .where((e) =>
                e.name.toLowerCase().contains(q) ||
                e.pluginId.toLowerCase().contains(q) ||
                e.triggerType.toLowerCase().contains(q) ||
                e.effective.toLowerCase().contains(q))
            .toList();
    final overriddenCount = all.where((e) => e.overridden).length;
    final catalog = BuiltinPromptCatalog.instance;

    return Scaffold(
      appBar: AppBar(
        title: Text(zh ? '内置提示词与协议' : 'Built-in prompts'),
        actions: [
          IconButton(
            tooltip: zh ? '数据包更新' : 'Data packs',
            icon: const Icon(Icons.cloud_download_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const DataPackUpdateScreen()),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppGap.lg, AppGap.sm, AppGap.lg, AppGap.xs),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 状态那一行必须说**生效值**，不是"有没有下载过远程包"：
                // 陈旧自愈（build131）之后远程可能被丢弃，这时说"已覆盖"就是假话。
                Text(
                  zh
                      ? '共 ${all.length} 条内置协议 · 其中 $overriddenCount 条被远程数据包覆盖'
                          '${catalog.lastUpdatedAt == null ? '' : '（更新于 ${_fmtDate(catalog.lastUpdatedAt!)}）'}'
                      : '${all.length} built-in protocols · $overriddenCount overridden by the remote pack'
                          '${catalog.lastUpdatedAt == null ? '' : ' (updated ${_fmtDate(catalog.lastUpdatedAt!)})'}',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: cs.appTextSub),
                ),
                if (catalog.lastMessage.isNotEmpty) ...[
                  const SizedBox(height: AppGap.xs),
                  Text(
                    catalog.lastMessage,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: cs.appTextFaint),
                  ),
                ],
                const SizedBox(height: AppGap.sm),
                TextField(
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 18),
                    hintText: zh ? '搜插件名 / 协议内容' : 'Search by name or content',
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: AppGap.md, vertical: AppGap.sm),
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: shown.isEmpty
                ? Center(
                    child: Text(
                      zh ? '没有匹配的协议' : 'No matching protocol',
                      style: TextStyle(color: cs.appTextFaint),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(
                        AppGap.lg, AppGap.sm, AppGap.lg, AppGap.xl),
                    // build140（反馈①同源）：itemBuilder 的 context 是 SliverList 的
                    // **共享元素**，主题/语言切换时已画出的行不会刷新 ⇒ 取值下移到
                    // 每行自己的元素（见 _EntryTile）。
                    itemCount: shown.length,
                    itemBuilder: (context, i) => _EntryTile(entry: shown[i]),
                  ),
          ),
        ],
      ),
    );
  }

  static String _fmtDate(DateTime d) {
    final local = d.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry});

  final _Entry entry;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final l = AppLocalizations.of(context);
    final zh = l.locale.languageCode == 'zh';
    return Card(
      margin: const EdgeInsets.only(bottom: AppGap.sm),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: AppGap.md),
        shape: const Border(),
        leading: Icon(
          entry.overridden ? Icons.bolt : Icons.description_outlined,
          color: entry.overridden ? cs.primary : cs.appTextSub,
        ),
        title: Text(entry.name, style: tt.bodyMedium),
        subtitle: Text(
          zh
              ? '${entry.pluginId} · 标签 <${entry.triggerType}> · '
                  '${entry.effective.length} 字 · '
                  '${entry.overridden ? '远程覆盖' : '内置默认'}'
              : '${entry.pluginId} · tag <${entry.triggerType}> · '
                  '${entry.effective.length} chars · '
                  '${entry.overridden ? 'remote override' : 'built-in'}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: tt.bodySmall?.copyWith(color: cs.appTextSub),
        ),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppGap.md, 0, AppGap.md, AppGap.sm),
              child: SelectableText(
                entry.effective,
                style: tt.bodySmall?.copyWith(height: 1.45),
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 0, AppGap.md, AppGap.sm),
              child: TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(
                      ClipboardData(text: entry.effective));
                  if (!context.mounted) return;
                  AppSnackBar.showSnackBar(
                    context,
                    SnackBar(
                      content: Text(
                          zh ? '协议全文已复制' : 'Protocol text copied'),
                      duration: const Duration(seconds: 1),
                    ),
                  );
                },
                icon: const Icon(Icons.copy, size: 16),
                label: Text(zh ? '复制全文' : 'Copy'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
