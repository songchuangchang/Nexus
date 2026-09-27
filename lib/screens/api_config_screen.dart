import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../l10n/app_localizations.dart';
import '../models/api_config.dart';
import '../services/balance_service.dart';
import '../services/biometric_service.dart';
import '../services/logger_service.dart';
import '../services/storage_service.dart';
import '../ui/tokens.dart';
import 'api_config_edit_screen.dart';
import '../widgets/vendor_avatar.dart';
import '../utils/app_snackbar.dart';

// build138（B 批）：`ApiConfigScreen` 这个名字现在属于新的一级页
// （provider_home_screen.dart，厂商列表）。这里用 export 把它转出去，
// 9 个 push 点（main / model_switcher / about_settings / quick_access_menu /
// chat_screen_react / conversation_list / image_gen / video_gen …）
// 一行都不用改 —— 改的是页面结构，不该顺手改路由入口的名字。
export 'provider_home_screen.dart' show ApiConfigScreen;

/// build138（B 批）：这里原本是用户口里的「API 配置」页，即**已连接配置**的列表。
/// B 批把入口结构反转成「厂商 → 模型 → 详情」之后，这张列表整体降级为
/// 一级页里的一个入口（`ApiConfigScreen` → 本页），功能一条不减：
/// 滑动删除（带二次确认）、单项导出、余额行、点进去编辑。
///
/// 9 个外部 push 点仍然 push `ApiConfigScreen`（一级页），无需改动 —— 这正是
/// 交接单 §7.2 说的「只动 lib/screens/api_config_screen.dart」。
class ConnectedConfigsScreen extends StatefulWidget {
  const ConnectedConfigsScreen({super.key});

  @override
  State<ConnectedConfigsScreen> createState() => _ConnectedConfigsScreenState();
}

class _ConnectedConfigsScreenState extends State<ConnectedConfigsScreen> {
  List<ApiConfig> _configs = [];
  bool _isLoading = true;
  bool _busy = false;
  // build108（Q1）：余额缓存展示与刷新状态（按 config.id）
  final Map<String, BalanceInfo> _balances = {};
  final Set<String> _balanceLoading = {};

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final storage = context.read<StorageService>();
    await storage.init();
    final configs = await storage.getApiConfigs();
    if (mounted) {
      setState(() {
        _configs = configs;
        _isLoading = false;
      });
      // build108（Q1）：先用水久缓存即时展示（过期不显示，等用户手动刷新）
      for (final c in configs) {
        // build145（第 7 轮 P2）：读键必须和写键同一个口径。写侧 build138（G52）
        // 已换成 `balanceCacheKey`（= 账号 id，见 api_config.dart:149），这里当时漏改
        // 还在按 `c.id` 查 ⇒ 凡是挂在账号下的条目，首屏预填**恒不命中**，
        // 缓存等于只对"没有账号的老条目"生效 —— 换键只换一半比不换更坏，
        // 因为它让"我们已经有缓存了"这件事在代码里看着成立。
        final hit = BalanceService.cachedFor(c.balanceCacheKey);
        if (hit != null) {
          _balances[c.balanceCacheKey] = hit;
        }
      }
      if (mounted) setState(() {});
    }
  }

  /// build108（Q1）：手动刷新单个配置的余额（强制绕缓存）
  Future<void> _refreshBalance(ApiConfig config, bool isZh) async {
    if (_balanceLoading.contains(config.balanceCacheKey)) return;
    setState(() => _balanceLoading.add(config.balanceCacheKey));
    final info = await BalanceService.fetchFor(config, force: true);
    if (!mounted) return;
    setState(() {
      _balanceLoading.remove(config.balanceCacheKey);
      if (info != null) {
        _balances[config.balanceCacheKey] = info;
      }
    });
    if (info == null) {
      AppSnackBar.showSnackBar(context, SnackBar(
        content: Text(isZh
            ? '该服务未提供余额接口（或查询失败）'
            : 'No balance endpoint for this service'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ));
    }
  }

  /// build108（Q1）：卡片余额行——缓存即时显示，点刷新强制查询
  Widget _buildBalanceRow(ApiConfig config, bool isZh) {
    final loading = _balanceLoading.contains(config.balanceCacheKey);
    final info = _balances[config.balanceCacheKey];
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 10),
      child: Row(children: [
        Icon(Icons.account_balance_wallet_outlined,
            size: 16, color: cs.onSurfaceVariant),
        const SizedBox(width: 6),
        Expanded(
          child: loading
              ? Text(isZh ? '查询中…' : 'Querying…',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant))
              : Text(
                  info?.display ??
                      (isZh ? '点右侧查询余额' : 'Tap refresh to query balance'),
                  style: TextStyle(
                      fontSize: 12,
                      color:
                          info != null ? cs.primary : cs.onSurfaceVariant),
                ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: isZh ? '刷新余额' : 'Refresh balance',
          icon: loading
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.refresh, size: 18),
          onPressed:
              loading ? null : () => _refreshBalance(config, isZh),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final isZh = l.locale.languageCode == 'zh';
    return Scaffold(
      appBar: AppBar(
        title: Text(l.tr('apiConfigs')),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              if (value == 'import') _importConfigs();
              if (value == 'exportAll') _exportConfigs();
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'import',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.file_download_outlined),
                  title: Text(isZh ? '导入 JSON' : 'Import JSON'),
                ),
              ),
              PopupMenuItem(
                value: 'exportAll',
                enabled: _configs.isNotEmpty,
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.file_upload_outlined),
                  title: Text(isZh ? '导出全部' : 'Export All'),
                ),
              ),
            ],
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _configs.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.cloud_off,
                          size: 64,
                          color: Theme.of(context).colorScheme.outline),
                      const SizedBox(height: 16),
                      Text(l.tr('apiConfigs'),
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Text(l.tr('supportedApisSubtitle')),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: _configs.length,
                  itemBuilder: (context, index) {
                    final config = _configs[index];
                    // build140（反馈①同源）：每项包一层 Builder，配色/语言才会在**该项的元素**
                    // 上登记依赖（itemBuilder 的 context 是 SliverList 共享元素，主题切换时
                    // 已画出来的条目不会重建；详见 conversation_list_screen 同名注释）。
                    return Builder(builder: (context) => Dismissible(
                      key: Key(config.id),
                      // build97 (P2-14 铁律#11)：破坏性操作必须二次确认
                      confirmDismiss: (_) async {
                        final zh = isZh;
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: Text(
                                zh ? '删除 API 配置？' : 'Delete API config?'),
                            content: Text(zh
                                ? '将同时删除使用该配置的全部会话与消息，不可恢复。确认删除「${config.name}」？'
                                : 'This also deletes ALL conversations and messages using this config. Delete "${config.name}"?'),
                            actions: [
                              TextButton(
                                  onPressed: () =>
                                      Navigator.pop(ctx, false),
                                  child: Text(l.tr('cancel'))),
                              FilledButton(
                                  onPressed: () =>
                                      Navigator.pop(ctx, true),
                                  child: Text(l.tr('delete'))),
                            ],
                          ),
                        );
                        return ok ?? false;
                      },
                      background: Container(
                        color: Theme.of(context).colorScheme.error,
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        child: Icon(Icons.delete,
                            color: Theme.of(context).colorScheme.onError),
                      ),
                      direction: DismissDirection.endToStart,
                      onDismissed: (_) async {
                        await context
                            .read<StorageService>()
                            .deleteApiConfig(config.id);
                        _loadData();
                      },
                      child: AppSectionCard(
                        children: [
                          ListTile(
                            leading: CircleAvatar(
                              backgroundColor: Colors.transparent,
                              child: VendorAvatar(
                                  templateId: config.templateId, size: 28),
                            ),
                            title: Text(config.name),
                            subtitle:
                                Text('${config.baseUrl} • ${config.model}'),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: isZh ? '导出此项' : 'Export',
                                  icon: Icon(Icons.ios_share,
                                      size: 20,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant),
                                  onPressed: () =>
                                      _exportConfigs(single: config),
                                ),
                                Icon(Icons.chevron_right,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant),
                              ],
                            ),
                            onTap: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) =>
                                      ApiConfigEditScreen(config: config),
                                ),
                              ).then((_) => _loadData());
                            },
                          ),
                          // build108（Q1）：余额行（缓存即时显示 + 手动刷新）
                          _buildBalanceRow(config, isZh),
                        ],
                      ),
                    ));
                  },
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => const ApiConfigEditScreen(config: null),
            ),
          ).then((_) => _loadData());
        },
        child: const Icon(Icons.add),
      ),
    );
  }

  // ==========================================================================
  // JSON 导入导出（Chatbox 同款）
  // 导出：全字段（含 apiKey 明文）→ 弹窗提示敏感 → 写 Downloads/Nexus_Downloads/
  // 导入：重复 id 生成新 UUID（新增而非覆盖）；日志不落 Key 明文
  // ==========================================================================

  Future<void> _exportConfigs({ApiConfig? single}) async {
    final l = AppLocalizations.of(context);
    final isZh = l.locale.languageCode == 'zh';
    final list = single != null ? [single] : _configs;
    if (list.isEmpty) return;

    // 敏感数据提示：导出文件含 API Key 明文
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isZh ? '导出 API 配置' : 'Export API Configs'),
        content: Text(isZh
            ? '将导出 ${list.length} 个配置的全部字段（供应商 / Base URL / 模型 / 参数）。\n\n⚠️ 导出的 JSON 包含 API Key 明文，属于敏感数据，请妥善保管导出文件，不要分享给他人。'
            : 'Will export all fields of ${list.length} config(s) (provider / Base URL / model / params).\n\n⚠️ The exported JSON contains plaintext API keys. Keep the file safe and do not share it.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.tr('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(isZh ? '导出' : 'Export'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      final payload = <String, dynamic>{
        'type': 'nexus-api-configs',
        // G51（build136）：1 → 2。
        // v1 的字段集从没写进过文件（导出用 toMap 是全字段，但**导入**那条
        // 「重复 id 重建」路径手工枚举字段，漏了 imageModel / videoModel /
        // supportToolCalls / supportImageGen / supportVideoGen）。
        // v2 = 明确承诺「生成模型名 + 三个能力位随文件走」；
        // 导入侧对 v1 老文件保持兼容（缺字段走 fromMap 兜底）。
        'schemaVersion': 2,
        'exportedAt': DateTime.now().toIso8601String(),
        'configs': list.map((c) => c.toMap()).toList(),
      };
      final jsonStr = const JsonEncoder.withIndent('  ').convert(payload);

      Directory? baseDir;
      try {
        baseDir = await getDownloadsDirectory();
      } catch (e) { debugPrint('catch 静默异常: $e'); }
      baseDir ??= await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(baseDir.path, 'Nexus_Downloads'));
      if (!dir.existsSync()) await dir.create(recursive: true);

      final now = DateTime.now();
      final stamp =
          '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}'
          '_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
      final fileName = single != null
          ? 'nexus_api_config_$stamp.json'
          : 'nexus_api_configs_$stamp.json';
      final outFile = File(p.join(dir.path, fileName));
      await outFile.writeAsString(jsonStr, flush: true);

      // 日志只记数量与路径，不落 Key 明文
      LoggerService.instance.info(
          '[ApiConfig] Exported ${list.length} config(s) to ${outFile.path}',
          tag: 'ApiConfig');
      if (mounted) {
        AppSnackBar.showSnackBar(context, SnackBar(
          content: Text(
              isZh ? '已导出到：${outFile.path}' : 'Exported to: ${outFile.path}'),
          duration: const Duration(seconds: 5),
        ));
      }
    } catch (e, st) {
      LoggerService.instance.error('[ApiConfig] Export failed',
          error: e, stack: st, tag: 'ApiConfig');
      if (mounted) {
        AppSnackBar.showSnackBar(context, SnackBar(
          content: Text(isZh ? '导出失败：$e' : 'Export failed: $e'),
          backgroundColor: Theme.of(context).colorScheme.errorContainer,
        ));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importConfigs() async {
    if (_busy) return;
    final l = AppLocalizations.of(context);
    final isZh = l.locale.languageCode == 'zh';

    BiometricService.beginActivityTransition();
    FilePickerResult? picked;
    try {
      picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json'],
        withData: false,
      );
    } finally {
      Future.delayed(const Duration(seconds: 2), () {
        BiometricService.endActivityTransition();
      });
    }
    if (picked == null || picked.files.isEmpty) return;
    final filePath = picked.files.first.path;
    if (filePath == null) {
      if (mounted) {
        AppSnackBar.showSnackBar(context, SnackBar(
            content: Text(isZh ? '无法获取文件路径' : 'Cannot get file path')));
      }
      return;
    }
    if (!mounted) return;
    final storage = context.read<StorageService>();
    setState(() => _busy = true);

    try {
      final jsonStr = await File(filePath).readAsString();
      final decoded = json.decode(jsonStr);
      // 兼容三种结构：{configs:[...]} / {apiConfigs:[...]}（含备份文件 data 包裹）/ 裸数组 / 单个对象
      List<dynamic> rawList;
      if (decoded is Map) {
        final map = Map<String, dynamic>.from(decoded);
        final data = map['data'];
        if (map['configs'] is List) {
          rawList = map['configs'] as List;
        } else if (map['apiConfigs'] is List) {
          rawList = map['apiConfigs'] as List;
        } else if (data is Map && data['apiConfigs'] is List) {
          rawList = data['apiConfigs'] as List;
        } else if (map.containsKey('baseUrl') || map.containsKey('model')) {
          rawList = [map];
        } else {
          throw const FormatException('无法识别的 JSON 结构');
        }
      } else if (decoded is List) {
        rawList = decoded;
      } else {
        throw const FormatException('无法识别的 JSON 结构');
      }

      var imported = 0;
      var skipped = 0;
      for (final item in rawList) {
        if (item is! Map) {
          skipped++;
          continue;
        }
        try {
          var cfg = ApiConfig.fromMap(Map<String, dynamic>.from(item));
          // 重复 id：生成新 UUID 新增，绝不覆盖现有配置
          final existing = await storage.getApiConfig(cfg.id);
          if (existing != null) {
            // G51（build136）：这里原先**手工枚举字段重建**，漏传了
            // imageModel / videoModel / supportToolCalls / supportImageGen /
            // supportVideoGen —— 导入一份带生成模型与工具通道的配置后，
            // 生成模型被清空、能力位被重置成默认值（真机表现为「导入后图/视频生不出来」）。
            // 改为只换 id、其余字段整份带走；backup_service 在 v1.4.3 踩过同一个坑
            // （那边已改成不手工枚举，这边一直没跟上）。
            cfg = cfg.copyWith(id: const Uuid().v4());
          }
          await storage.saveApiConfig(cfg);
          imported++;
        } catch (_) {
          skipped++;
        }
      }
      // 日志只记数量，不落 Key 明文
      LoggerService.instance.info(
          '[ApiConfig] Imported $imported config(s), skipped $skipped',
          tag: 'ApiConfig');
      if (mounted) {
        AppSnackBar.showSnackBar(context, SnackBar(
          content: Text(isZh
              ? '✅ 导入完成：新增 $imported 个配置${skipped > 0 ? '，跳过 $skipped 条无效项' : ''}（重复 id 已生成新 id 新增，未覆盖现有配置）'
              : '✅ Imported $imported config(s)${skipped > 0 ? ', skipped $skipped invalid' : ''} (duplicate IDs added as new, nothing overwritten)'),
          duration: const Duration(seconds: 6),
        ));
      }
      await _loadData();
    } catch (e, st) {
      LoggerService.instance.error('[ApiConfig] Import failed',
          error: e, stack: st, tag: 'ApiConfig');
      if (mounted) {
        AppSnackBar.showSnackBar(context, SnackBar(
          content: Text(isZh ? '导入失败：$e' : 'Import failed: $e'),
          backgroundColor: Theme.of(context).colorScheme.errorContainer,
          duration: const Duration(seconds: 8),
        ));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
