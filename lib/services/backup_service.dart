import 'dart:convert';
import 'dart:io';
import 'live_task_center.dart';
import 'live_task_wiring.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../constants.dart';
import '../models/api_account.dart';
import '../models/api_config.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../models/memory_models.dart';
import '../models/web_search_config.dart';
import '../models/mcp_market_models.dart';
import '../plugins/plugin_interface.dart';
import '../utils/redact.dart';
import 'logger_service.dart';
import 'storage_service.dart';
import 'package:flutter/foundation.dart';

/// v1.3.8：导出/导入服务
///
/// 用户需求："能加入一个导出和导入功能，可以选择导出了什么，是否需要导出 API 等"
///
/// 已和用户对齐：
///   ① 导出范围：全量数据（API 配置 + 聊天记录 + 搜索设置）
///   ② API key 等敏感信息：导出时让用户勾选是否包含（默认不含）
///   ③ 文件格式：单个 JSON 文件
///   ④ 导入策略：让用户选「合并到现有数据」或「清空后覆盖」
///
/// JSON schema（schemaVersion=2）：
/// ```json
/// {
///   "schemaVersion": 2,
///   "exportedAt": "2026-08-19T...",
///   "appVersion": "1.3.7",
///   "includeKeys": true,
///   "data": {
///     "apiConfigs":     [ {ApiConfig.toMap}, ... ],
///     "conversations":  [ {Conversation.toMap}, ... ],
///     "messages":       [ {ChatMessage.toMap}, ... ],
///     "webSearchConfig": {WebSearchConfig.toMap},
///     "plugins":        [ {plugins 表行}, ... ],
///     // schemaVersion 2 新增（build91 T1：换机丢数据修复）
///     "globalMemories":  [ {GlobalMemory.toMap}, ... ],
///     "projects":        [ {Project.toMap}, ... ],
///     "projectMemories": [ {ProjectMemory.toMap}, ... ],
///     "slashCommands":   [ {SlashCommand.toMap}, ... ],
///     "messageVersions": [ {message_versions 表行}, ... ],
///     "contextCompactionSegments": [ {context_compaction_segments 表行}, ... ]
///   }
/// }
/// ```

/// 导入一行 plugins 时对 `metadataJson` 的解析结果（build133 ① 抽出为纯函数，便于单测）。
class PluginMetadataImportResult {
  /// 解析后的 metadata（`id` 已用行内主键兜底，必定非空）
  final Map<String, dynamic> decoded;

  /// 备份里是否真的带了非空 metadata
  final bool hadMetadata;

  const PluginMetadataImportResult(this.decoded, this.hadMetadata);
}

/// 解析备份行里的 `metadataJson`。
///
/// build133（①）：**"缺失"不再等于"坏行"**。系统插件行（search/download/ask_user/
/// self_check/answer）历史上就是 NULL —— `savePluginState` 的兜底 INSERT 曾是
/// `if (metadataJson != null)` 条件写入。旧逻辑对缺失/空直接抛，异常被逐行 catch 吞掉
/// ⇒ 整行丢弃 ⇒ 系统插件的禁用状态「导出→导入」后静默丢失。
///
/// 现在：缺失/空/`'{}'` ⇒ 返回空对象 + `hadMetadata=false`，由调用方按 kind 决策
/// （本地/内置照常入库，远程插件仍然拒绝 —— 它的 client 无法凭空配置重建）。
/// 真正的坏数据（JSON 语法错、非对象）照旧抛 [FormatException]，不放过。
PluginMetadataImportResult decodePluginMetadataForImport(
    dynamic raw, Object? rowId) {
  var decoded = <String, dynamic>{};
  var hadMetadata = false;
  if (raw is String && raw.trim().isNotEmpty) {
    final json = jsonDecode(raw);
    if (json is! Map) {
      throw const FormatException('Plugin metadata is invalid');
    }
    decoded = Map<String, dynamic>.from(json);
    hadMetadata = decoded.isNotEmpty;
  }
  // PluginMetadata.fromMap 要求 id 非空 ⇒ 用行内主键兜底（空对象也能解析成功）
  decoded.putIfAbsent('id', () => '$rowId');
  return PluginMetadataImportResult(decoded, hadMetadata);
}

// ============================================================================
// build146（行业分歧安全批 ②）：MCP 凭据的**导出侧脱敏 + 导入侧禁用标记**
//
// 漏的到底是什么（不是假想，是三条实路径）：
//   `mcp_catalog_screen.dart:386-390` 在 `auth == 'key-query'` 时把密钥
//   **折进 endpoint 字符串**（`...?key=<secret>`）；`plugin_registry.dart:248-256`
//   把这个 endpoint 原样写进 `metadataJson.extra`；而备份导出
//   （本文件 build146 前的 :233-252）**只按字段名剥 `extra.customHeaders`**。
//   ⇒ 用户勾了"不含密钥"，Key 照样随 `plugins[].metadataJson` 上网盘。
//
// 为什么"按字段名剥敏"这个原语本身就是错的：
//   它只能命中**写代码那天想到的名字**。同一个缺陷在本仓库已复发三次——
//   v1.4.3 Bug#5（4 个 *ApiKey 只处理了 tavilyApiKey）、build138 P1-1
//   （virusTotalApiKey / mobsfApiKey 又漏两个）、本轮（密钥根本不在字段里，
//   而在 endpoint 这个 URL 字符串里，名字层面看不见）。凭据的位置在变，
//   名字白名单永远在追。
//
// 因此这里改成**按位置剥**：MCP 的 `extra.endpoint` 只要是 URL，就把它的
// 凭据承载位（query 参数、`user:pass@` userinfo）整段清掉。
// 声明式信息为什么用不上：`InstalledMcpConfig`（models/mcp_market_models.dart
// :381-443）的字段里**没有** `auth` / `queryParam`——目录条目的鉴权方式
// （models/mcp_catalog.dart 的 `auth` / `queryParam`）在安装完就没落库，
// 导出侧拿不到"哪个参数是密钥"。既然拿不到名字，退化成"凡有 query 就全剥"
// 比"猜一批密钥参数名"更强（后者正是上面那三次复发的成因）。
// 代价可控且已核：key-query 服务器少了一个 query 参数本来就跑不通 ⇒
// 导入侧强制**禁用 + 写明原因**（见 kMcpAuthRedactedReason），不静默半坏。
// ============================================================================

/// 导出侧写在 `metadata.extra` 里的标记键（导入侧据此判定"这份配置缺凭据"）
const String kMcpAuthRedactedFlag = 'authSecretRedacted';

/// 被剥掉的凭据承载位清单（参数名 / `userinfo`），**只记名字不记值**
const String kMcpAuthRedactedItems = 'authSecretRedactedItems';

/// 恢复后必须让用户看见的原因（写进 metadata.description，插件卡片 subtitle 读它）
const String kMcpAuthRedactedReason = '密钥未包含，请重新填入';

/// 纯函数：剥掉 MCP endpoint 里可能携带的凭据（query 参数 + `user:pass@`）。
///
/// 不做的事：不改 scheme/host/path —— 重建 client 需要的定位信息全部保留，
/// 只有凭据承载位被清空。顺手把 fragment 也去掉（`isSafeMcpHttpsUri` 本来就
/// 禁止 fragment，留着会让导入端整行判坏）。
///
/// 解析不了的字符串原样返回（宁可少剥一处，也不要把一个非 URL 的
/// 端点配置改坏；这类行导入端另有校验）。
({String endpoint, List<String> droppedItems, bool changed})
    redactMcpEndpointCredentials(String rawEndpoint) {
  final none = (endpoint: rawEndpoint, droppedItems: const <String>[], changed: false);
  final uri = Uri.tryParse(rawEndpoint);
  if (uri == null) return none;
  final dropped = <String>[
    ...uri.queryParameters.keys.map((k) => 'query:$k'),
    if (uri.userInfo.isNotEmpty) 'userinfo',
  ];
  if (dropped.isEmpty && !uri.hasFragment) return none;
  // 字符串手术而非 Uri(...) 重建：Uri.path 是解码后的，回编码会动到
  // `%2F` 这类租户/路径转义，端点可能被改得连不上（与"只剥凭据"的口径不符）。
  var out = rawEndpoint;
  final cut = _firstIndexOfAny(out, const ['?', '#']);
  if (cut >= 0) out = out.substring(0, cut);
  final schemeEnd = out.indexOf('://');
  if (schemeEnd >= 0) {
    final authorityStart = schemeEnd + 3;
    final pathStart = _firstIndexOfAnyFrom(out, const ['/', '?', '#'], authorityStart) ??
        out.length;
    final authority = out.substring(authorityStart, pathStart);
    // userinfo 内的 '@' 必须百分号编码（RFC 3986），所以最后一个 '@' 就是分隔符
    final at = authority.lastIndexOf('@');
    if (at >= 0) {
      out = '${out.substring(0, authorityStart)}'
          '${authority.substring(at + 1)}'
          '${out.substring(pathStart)}';
    }
  }
  return (endpoint: out, droppedItems: dropped, changed: out != rawEndpoint);
}

/// 从左到右第一个命中的 needle 下标（无正则、无内联标志）
int? _firstIndexOfAnyFrom(String s, List<String> needles, int from) {
  int? best;
  for (final n in needles) {
    final i = s.indexOf(n, from);
    if (i >= 0 && (best == null || i < best)) best = i;
  }
  return best;
}

int _firstIndexOfAny(String s, List<String> needles) =>
    _firstIndexOfAnyFrom(s, needles, 0) ?? -1;

/// build157（P2 安全）：`metadataJson` **解析失败 / 结构不是可剥的形状**时
/// 写进备份的「整块丢弃」占位。
///
/// 为什么旧口径（解析失败 ⇒ 原样返回）不能留：导出这份文件是要上网盘的。
/// jsonDecode 一抛就透传，等于「越畸形、越是被人为构造的 metadata，
/// 越能绕过本函数全部剥敏分支」—— 而畸形正是最省事的绕法：`extra` 不是对象
/// （`{"extra":"Bearer sk-..."}`）时，本函数认得的两个凭据位一个都定位不到。
/// 更要紧的是：当时「没有需要脱敏的东西」和「脱敏被跳过」在文件里**长得一模一样**，
/// 事后翻备份也分辨不出来（build157 要修的就是这个「静默」）。
///
/// 取舍写在明处：**站在丢数据这一边**。丢的只有插件 metadata（恢复后该插件要
/// 重新配置），同行的 `id` / `enabled` / `installedAt` 等列照常导出；
/// 而漏出去的是凭据，不可回收。
/// 另外这几乎不是「新增的数据损失」：这种行在旧行为下同样进不了库 ——
/// 导入端 [decodePluginMetadataForImport] 对同一串照旧抛 FormatException，
/// 整行被调用点的 try/catch 丢掉（只留一行日志）。旧行为多出来的那一件事
/// 只是先把凭据传上了网盘。
const String kPluginMetadataOmittedFlag = 'metadataOmittedUnparseable';
const String kPluginMetadataOmittedJson =
    '{"$kPluginMetadataOmittedFlag":true}';

/// 纯函数：一份导出的 `metadataJson` 是否正是上面那个「整块丢弃」占位。
/// 精确等值而非 `contains`：正常 metadata 里也可能出现同名键（用户自己的字段），
/// 那种行是走了剥敏路径的，不该计入「本次备份丢了 N 条 metadata」。
bool isPluginMetadataOmittedForExport(String metadataJson) =>
    metadataJson == kPluginMetadataOmittedJson;

/// 纯函数：把一行 plugins 的 `metadataJson` 落成"不含凭据"版本。
///
/// 覆盖两处：① `extra.customHeaders`（build97 已有，按字段名整块清空）；
/// ② `extra.endpoint` 的 query / userinfo（build146 ② 新增，按位置剥）。
/// 任一生效就写标记，导入端据此把服务器置为禁用并给出原因。
///
/// build157 把口径从「解析失败 / 无需改动 ⇒ 原样返回」拆成两半：
/// **无需改动才原样返回**（不打标记，和旧行为一致，见 build146 的免鉴权用例）；
/// **解析不了 / 认不出形状 ⇒ 返回 [kPluginMetadataOmittedJson]**，
/// 绝不再把未经剥敏的原文写进备份。
String redactPluginMetadataJsonForExport(String metadataJson) {
  dynamic decoded;
  try {
    decoded = jsonDecode(metadataJson);
  } catch (e) {
    debugPrint('catch 静默异常: $e');
    return kPluginMetadataOmittedJson;
  }
  // 合法 JSON 但不是对象（裸串/数组/数字）同样认不出凭据位 ⇒ 同一口径处理，
  // 否则"能解析"就被当成"能剥敏"，透传口子只是换了个位置。
  if (decoded is! Map) return kPluginMetadataOmittedJson;
  final meta = Map<String, dynamic>.from(decoded);
  final extra = meta['extra'];
  // 没有 extra：本函数认得的凭据位都不存在（行内其它字段的值另有 build153
  // 的 redactSecretsDeep 按形态兜底），保持一字不改 ⇒ 不制造"缺密钥"假象。
  if (extra == null) return metadataJson;
  // extra 是凭据的容器，却不是对象 ⇒ 无从定位。写入端 PluginMetadata.toMap
  // 只会写出对象，非对象只可能来自损坏或构造的行，因此这里整块丢弃没有
  // 误伤正常数据的代价。
  if (extra is! Map) return kPluginMetadataOmittedJson;
  final nextExtra = Map<String, dynamic>.from(extra);
  var dropped = <String>[];
  // ① 鉴权头（原逻辑，语义不动）
  final headers = nextExtra['customHeaders'];
  if (headers is Map && headers.isNotEmpty) {
    nextExtra['customHeaders'] = <String, dynamic>{};
    dropped.add('customHeaders');
  }
  // ② 端点里的凭据承载位
  final rawEndpoint = nextExtra['endpoint'];
  if (rawEndpoint is String && rawEndpoint.isNotEmpty) {
    final r = redactMcpEndpointCredentials(rawEndpoint);
    if (r.changed) {
      nextExtra['endpoint'] = r.endpoint;
      dropped.addAll(r.droppedItems);
    }
  }
  if (dropped.isEmpty) return metadataJson;
  nextExtra[kMcpAuthRedactedFlag] = true;
  nextExtra[kMcpAuthRedactedItems] = dropped;
  meta['extra'] = nextExtra;
  return jsonEncode(meta);
}

/// 纯函数：导入一行 plugins 时，把"导出侧剥过凭据"的行落成
/// **禁用 + 带原因**，而不是启用且半坏。
///
/// 没有标记的行原样返回。metadataJson 解析失败也原样返回（坏行由调用点的
/// try/catch 处置，与 build133 的容错口径一致）。
///
/// 待办（本轮未做，写入点不在改动面内）：用户在插件管理里**重新填好凭据**时，
/// 应顺手把 `extra[kMcpAuthRedactedFlag]` 清掉——否则这台服务器再导出时
/// 仍带着"凭据已剥离"的标记（下一份备份导入会再次把它禁用）。
/// 写 extra 的入口在 plugin_registry / mcp_catalog，不在本文件。
Map<String, dynamic> applyMcpAuthRedactedImportState(Map<String, dynamic> row) {
  final raw = row['metadataJson'];
  if (raw is! String || raw.trim().isEmpty) return row;
  dynamic decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (e) {
    debugPrint('catch 静默异常: $e');
    return row;
  }
  if (decoded is! Map) return row;
  final meta = Map<String, dynamic>.from(decoded);
  final extra = meta['extra'];
  if (extra is! Map || extra[kMcpAuthRedactedFlag] != true) return row;
  // 原因写进 description：插件卡片 subtitle 读的是 metadata.description
  // （plugin_management_screen.dart 的 displayDescription），用户回到
  // 插件管理就能看见"为什么这台服务器是关着的"。
  final original = meta['description']?.toString().trim() ?? '';
  final nextDescription = original.isEmpty
      ? kMcpAuthRedactedReason
      : original.contains(kMcpAuthRedactedReason)
          ? original
          : '$kMcpAuthRedactedReason：$original';
  meta['description'] = nextDescription;
  return {
    ...row,
    // 0 = 禁用。注意导入端原本就对所有 isRemote 行置 0，这里**不依赖**那个
    // 事实：标记行无论 kind 都必须禁用（半坏的 key-query 服务器一旦启用就是
    // 连环 401，模型侧还会被熔断文案带着绕圈）。
    'enabled': 0,
    'description': nextDescription,
    'metadataJson': jsonEncode(meta),
  };
}

class BackupService {
  // v1.7.39 (T1)：1→2，新增 6 张表的导出/导入；导入端对缺字段空列表兜底
  // build101：2→3，新增 knowledgeBases / knowledgeChunks / assistants 三张表
  // build138（G52）：3→4，新增 api_accounts（账号层）。导入端对**缺该字段**
  // 的 v2/v3 备份按「同厂商+同 host+同 Key」现场归组补建账号，
  // 所以老备份文件照常能恢复两级结构（任务书 §三.6）。
  static const int kSchemaVersion = 4;
  // v1.4.3：appVersion 集中管理；v1.6.4 迁移到 ../constants.dart 避免循环依赖
  static const String kAppVersion = kAppVersionConst;

  final StorageService _storage;
  final LoggerService _logger = LoggerService.instance;
  final _uuid = const Uuid();
  // v1.7.39 (T1)：合并模式下 project id 重映射（project → projectMemories/slashCommands 重挂）
  final _projectIdMap = <String, String>{};

  BackupService(this._storage);

  // ===========================================================================
  // 导出
  // ===========================================================================

  /// 导出全部数据为 JSON 字符串
  ///
  /// [includeKeys]：true 时保留 apiKey / tavilyApiKey 原值；false 时置空字符串
  /// build142（灵动岛）：备份打包是**整库读**，大账号下要几十秒，切后台必须能看见。
  Future<String> exportAll({required bool includeKeys}) async =>
      LiveTaskWiring.track(
        id: 'export',
        title: '正在打包备份数据',
        kind: LiveTaskKind.backup,
        okBody: '备份文件已生成',
        body: () => _exportAllInner(includeKeys: includeKeys),
      );

    Future<String> _exportAllInner({required bool includeKeys}) async {
    final apiConfigs = await _storage.getApiConfigs();
    // build138（G52）：账号层入备份。缺这张表的话，卸载重装后
    // 「一个 Key 挂多个模型」会退化成 N 条各自带 Key 的独立配置。
    final apiAccounts = await _storage.getApiAccounts();
    final conversations = await _storage.getConversations();
    final webSearchCfg = await _storage.getWebSearchConfig();
    // ✅ NEW-BUG-01 修复：导出 plugins 表全量数据（包含市场安装的第三方插件 + 系统插件 enabled 状态）
    final allPlugins = await _storage.loadAllPlugins();

    // v1.7.39 (T1)：补 6 张表导出（build90 新增 4 表 + 既有 2 表遗漏）
    final globalMemories = await _storage.loadGlobalMemories();
    final projects = await _storage.loadProjects();
    final projectMemories = <ProjectMemory>[];
    for (final p in projects) {
      projectMemories.addAll(await _storage.loadProjectMemories(p.id));
    }
    final slashCommands = await _storage.loadSlashCommands();
    final messageVersions = await _storage.loadMessageVersions();
    final db = await _storage.db;
    final compactionRows =
        await db.query('context_compaction_segments', orderBy: 'createdAt ASC');
    // build101：新增表纳入备份
    //   knowledgeBases / knowledgeChunks —— C1 知识库（切片含向量，体积可能较大）
    //   assistants                        —— E8 自定义助手
    final knowledgeBases = await db.query('knowledge_bases');
    final knowledgeChunks = await db.query('knowledge_chunks');
    final assistants = await db.query('assistants');

    // 拉所有对话的消息（每个对话一组）
    final allMessages = <Map<String, dynamic>>[];
    for (final conv in conversations) {
      final msgs = await _storage.getMessages(conv.id);
      allMessages.addAll(msgs.map((m) => m.toMap()));
    }

    // 处理敏感字段
    // build97 (P0-2 修复)：「不含密钥」改为字段名后缀白名单反转——
    // 凡以 apiKey/token/secret 结尾的字符串字段一律置空，避免新增加密字段再漏
    // （build96 实测：virusTotalApiKey/mobsfApiKey 漏网，明文写进导出文件）。
    bool isSecretKey(String k) =>
        RegExp(r'(apikey|token|secret)$', caseSensitive: false)
            .hasMatch(k);
    final apiConfigsMap = apiConfigs.map((c) {
      final m = c.toMap();
      if (!includeKeys) {
        m.removeWhere((k, v) => v is String && v.isNotEmpty && isSecretKey(k));
        // removeWhere 会删键，fromMap 端按缺键 → '' 兜底；保险起见补空字符串
        m['apiKey'] = '';
      }
      return m;
    }).toList();

    final apiAccountsMap = apiAccounts.map((a) {
      final m = a.toMap();
      if (!includeKeys) {
        m.removeWhere((k, v) => v is String && v.isNotEmpty && isSecretKey(k));
        m['apiKey'] = '';
      }
      return m;
    }).toList();

    final webSearchMap = webSearchCfg.toMap();
    if (!includeKeys) {
      webSearchMap.removeWhere(
          (k, v) => v is String && v.isNotEmpty && isSecretKey(k));
    }

    // messageVersions 内存结构是 Map<retryOfId, List<RetryVersion>>，导出前拍平成表行
    // （retryOfId 和 versionIndex 补回每行，保证导入能原样重建）
    final messageVersionRows = <Map<String, dynamic>>[];
    messageVersions.forEach((retryOfId, versions) {
      for (var i = 0; i < versions.length; i++) {
        final v = versions[i];
        messageVersionRows.add({
          // build97 (P0-1 修复)：补 savedAt 列——建表是 NOT NULL 无默认值，
          // 漏列在 build95 事务化导入下必触发 NOT NULL constraint failed，
          // 导致整个备份导入回滚（含任何一条重试快照即全输）。
          'savedAt': DateTime.now().toIso8601String(),
          'retryOfId': retryOfId,
          'versionIndex': i + 1,
          'content': v.content,
          'reasoningSteps':
              jsonEncode(v.reasoningSteps.map((s) => s.toMap()).toList()),
          'promptTokens': v.promptTokens,
          'completionTokens': v.completionTokens,
          'totalTokens': v.totalTokens,
          'cacheReadTokens': v.cacheReadTokens,
          'cacheWriteTokens': v.cacheWriteTokens,
          'cacheHitTokens': v.cacheHitTokens,
          'cacheMissTokens': v.cacheMissTokens,
          'injectedWebSearchCount': v.injectedWebSearchCount,
          'showStaleFootnote': v.showStaleFootnote ? 1 : 0,
          'modelName': v.modelName,
          'searchSources':
              jsonEncode(v.searchSources.map((s) => s.toMap()).toList()),
        });
      }
    });

    // build97 (P0-2 延伸)：不含密钥时，MCP 插件的自定义鉴权头（customHeaders）
    // 同样是明文凭据，藏在 metadataJson 里，必须一并清空，否则「不含密钥」承诺
    // 依然漏凭据。
    // build146（行业分歧安全批 ②）：**不再只处理 customHeaders** —— 同一份
    // metadataJson 里 `extra.endpoint` 也带着密钥（key-query 安装把密钥折进了
    // URL query），按字段名剥敏看不到它。整段脱敏逻辑收进纯函数
    // [redactPluginMetadataJsonForExport]（含"剥了什么"的标记，导入端置禁用）。
    final sanitizedPlugins = <Map<String, dynamic>>[];
    // build157（P2 安全）：本次导出里 metadata **被整块丢弃**的插件行 id。
    // 只记 id 不记内容 —— 内容正是"没能剥干净"的那一列，日志里写它就是
    // 第二次泄露（口径同导入侧插件循环的 catch：日志只写插件 id，不写 metadataJson）。
    final omittedMetadataIds = <String>[];
    for (final row in allPlugins) {
      if (!includeKeys) {
        final r = Map<String, dynamic>.from(row);
        final raw = r['metadataJson'];
        if (raw is String && raw.isNotEmpty) {
          r['metadataJson'] = redactPluginMetadataJsonForExport(raw);
          if (isPluginMetadataOmittedForExport(r['metadataJson'] as String)) {
            omittedMetadataIds.add('${row['id']}');
          }
        } else {
          // build133（①）：历史行 metadataJson 可能是 NULL（savePluginState 旧逻辑
          // 是条件写入，系统插件行首建时即为 NULL）⇒ 导出时统一落成 '{}'，
          // 不再把 null 透传给导入端（导入端此前 `is! String` 会整行丢弃）。
          r['metadataJson'] = '{}';
        }
        sanitizedPlugins.add(r);
      } else {
        sanitizedPlugins.add(Map<String, dynamic>.from(row));
      }
    }

    // build157（P2 安全）：把"这份备份里有哪些插件 metadata 没导出"说出来。
    // 没有这一行，整块丢弃和「本来就没有需要脱敏的东西」在文件里同样看不出来，
    // 用户/排查者只能逐行比对占位标记。级别 warn：它不致命（备份仍可用），
    // 但意味着恢复后这些插件要重新配置。
    if (omittedMetadataIds.isNotEmpty) {
      _logger.warn(
          '[Backup] ${omittedMetadataIds.length} plugin row(s) had unparseable '
          'metadataJson: 整块丢弃，未写入备份（这些插件恢复后需重新配置） '
          'ids=${omittedMetadataIds.join(",")}',
          cat: LogCat.backup, tag: 'Backup');
    }

    final export = <String, dynamic>{
      'schemaVersion': kSchemaVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'appVersion': kAppVersion,
      'includeKeys': includeKeys,
      'data': {
        'apiConfigs': apiConfigsMap,
        // build138（G52，schemaVersion 4）：账号层
        'apiAccounts': apiAccountsMap,
        'conversations': conversations.map((c) => c.toMap()).toList(),
        'messages': allMessages,
        'webSearchConfig': webSearchMap,
        // ✅ NEW-BUG-01：plugins 数组加入导出（build97：含凭据脱敏副本）
        'plugins': sanitizedPlugins,
        // v1.7.39 (T1)
        'globalMemories': globalMemories.map((m) => m.toMap()).toList(),
        'projects': projects.map((p) => p.toMap()).toList(),
        'projectMemories': projectMemories.map((m) => m.toMap()).toList(),
        'slashCommands': slashCommands.map((c) => c.toMap()).toList(),
        'messageVersions': messageVersionRows,
        'contextCompactionSegments': compactionRows,
        // build101（C1/E8）
        'knowledgeBases': knowledgeBases,
        'knowledgeChunks': knowledgeChunks,
        'assistants': assistants,
      },
    };

    // build153：**按值/按形态的最后一道兜底**。上面的 isSecretKey 后缀白名单
    // 与 build146 的按位置剥敏都只能命中"写代码那天想到的名字/位置"——密钥一旦
    // 塞进非常规字段名或嵌套更深处（messages、metadataJson 字符串、未来新表……）
    // 就会随「不含密钥」的备份上网盘。redactSecretsDeep 遍历整棵导出树：
    // 认形态（sk-/Bearer 段/长 base64ish/?key= 位）即替换成 __REDACTED__，
    // **不认长度、不动键名/类型/结构**，canonical UUID 主键放行 ⇒ 恢复路径照旧能读。
    final exportForWrite = includeKeys
        ? export
        : Map<String, dynamic>.from(redactSecretsDeep(export) as Map);

    final json = const JsonEncoder.withIndent('  ').convert(exportForWrite);
    _logger.info(
        '[Backup] Exported: ${apiConfigsMap.length} configs, '
        '${apiAccountsMap.length} accounts, '
        '${conversations.length} conversations, '
        '${allMessages.length} messages, '
        '${allPlugins.length} plugins, '
        '${globalMemories.length} globalMemories, '
        '${projects.length} projects, '
        '${projectMemories.length} projectMemories, '
        '${slashCommands.length} slashCommands, '
        '${messageVersionRows.length} messageVersions, '
        '${compactionRows.length} compactionSegments, '
        '${knowledgeBases.length} knowledgeBases, '
        '${knowledgeChunks.length} knowledgeChunks, '
        '${assistants.length} assistants, '
        'includeKeys=$includeKeys',
        tag: 'Backup');
    return json;
  }

  /// 把 JSON 写到用户可见的下载目录，返回文件路径
  ///
  /// v1.4.3 修复 Bug #7：文件名后缀从 .json 改 .txt（Android 对 .json 识别不友好，教训#29）
  /// v1.4.3 修复 Bug #8：异常包装 + 日志，避免直接抛 FileSystemException 让 UI 难处理
  /// 文件名格式：aichat_backup_YYYYMMDD_HHMMSS.txt
  Future<String> writeExportToFile(String json, {String? customPath}) async {
    final now = DateTime.now();
    final stamp =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}'
        '_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
    final fileName = 'aichat_backup_$stamp.txt';

    String outPath = '';
    try {
      if (customPath != null && customPath.isNotEmpty) {
        outPath = p.join(customPath, fileName);
      } else {
        // 默认放到下载目录下的 AIChat_Downloads/
        Directory? baseDir;
        try {
          baseDir = await getDownloadsDirectory();
        } catch (e) { debugPrint('catch 静默异常: $e'); }
        if (baseDir == null) {
          // 回退：app documents 目录
          final appDir = await getApplicationDocumentsDirectory();
          baseDir = appDir;
        }
        final dir = Directory(p.join(baseDir.path, 'Nexus_Downloads'));
        if (!dir.existsSync()) {
          await dir.create(recursive: true);
        }
        outPath = p.join(dir.path, fileName);
      }

      final file = File(outPath);
      await file.writeAsString(json, flush: true);
      _logger.info('[Backup] Export file written: $outPath', tag: 'Backup');
      return outPath;
    } catch (e, st) {
      _logger.error('[Backup] writeExportToFile failed: $outPath',
          error: e, stack: st, tag: 'Backup');
      throw _BackupIOException('写入导出文件失败: $e\n目标路径: $outPath');
    }
  }

  // ===========================================================================
  // 导入
  // ===========================================================================

  /// 从 JSON 字符串导入数据
  ///
  /// [merge]：true = 追加到现有数据（UUID 冲突时给导入项生成新 UUID 并更新引用）
  ///          false = 清空所有表后重新插入
  ///
  /// 返回统计：导入的 apiConfigs / conversations / messages 数量
  /// build142（灵动岛）：恢复是整库写 + 事务，用户最关心「到底完没完」。
  Future<ImportStats> importFromString(String jsonStr,
          {required bool merge}) async =>
      LiveTaskWiring.track(
        id: 'import',
        title: '正在恢复数据',
        kind: LiveTaskKind.backup,
        okBody: '会话与设置已恢复',
        body: () => _importFromStringInner(jsonStr, merge: merge),
      );

    Future<ImportStats> _importFromStringInner(String jsonStr,
      {required bool merge}) async {
    final dynamic decoded = json.decode(jsonStr);
    if (decoded is! Map) {
      throw const _BackupFormatException('JSON 根节点必须是对象');
    }
    final root = decoded.cast<String, dynamic>();
    final schemaVersion = (root['schemaVersion'] as int?) ?? 1;
    if (schemaVersion > kSchemaVersion) {
      throw _BackupFormatException(
          '文件 schemaVersion=$schemaVersion 比当前支持版本($kSchemaVersion)新，请升级 App 后再导入');
    }
    final data = root['data'] as Map?;
    if (data == null) {
      throw const _BackupFormatException('JSON 缺少 data 字段');
    }

    final apiConfigsRaw = (data['apiConfigs'] as List?) ?? [];
    final conversationsRaw = (data['conversations'] as List?) ?? [];
    final messagesRaw = (data['messages'] as List?) ?? [];
    final webSearchRaw = data['webSearchConfig'] as Map?;
    // ✅ NEW-BUG-01 修复：读取 plugins 数组（老版本备份没有 plugins 字段时用空列表兜底）
    final pluginsRaw = (data['plugins'] as List?) ?? [];
    // v1.7.39 (T1)：schemaVersion 2 新增 6 张表，老备份缺字段时全部空列表兜底
    final globalMemoriesRaw = (data['globalMemories'] as List?) ?? [];
    final projectsRaw = (data['projects'] as List?) ?? [];
    final projectMemoriesRaw = (data['projectMemories'] as List?) ?? [];
    final slashCommandsRaw = (data['slashCommands'] as List?) ?? [];
    final messageVersionsRaw = (data['messageVersions'] as List?) ?? [];
    final compactionRaw = (data['contextCompactionSegments'] as List?) ?? [];
    // build101 三表——导出有、导入此前漏实现（build103 契约测试红灯暴露后补齐）
    final knowledgeBasesRaw = (data['knowledgeBases'] as List?) ?? [];
    final knowledgeChunksRaw = (data['knowledgeChunks'] as List?) ?? [];
    final assistantsRaw = (data['assistants'] as List?) ?? [];

    final apiConfigs = apiConfigsRaw
        .map((m) => ApiConfig.fromMap(Map<String, dynamic>.from(m as Map)))
        .toList();
    // build138（G52）：v4 起备份带 api_accounts；v2/v3 老文件没有这一项 ⇒
    // 用与 v39 迁移**同一个**纯函数按「厂商 + host + Key」现场归组补建。
    // 不这么办的后果很具体：从老备份恢复后两级结构散架，用户得重新填 Key。
    final apiAccountsRaw = (data['apiAccounts'] as List?) ?? [];
    var apiAccounts = apiAccountsRaw
        .map((m) => ApiAccount.fromMap(Map<String, dynamic>.from(m as Map)))
        .toList();
    if (apiAccounts.isEmpty && apiConfigs.isNotEmpty) {
      // 只 plan 一次：plan 每次都会生成新 UUID，调两遍会得到「账号列表」和
      // 「条目引用」两套对不上的 id —— 那正是「恢复后账号是空的」的成因。
      final plans = AccountGrouping.plan(apiConfigs);
      apiAccounts = plans.map((p) => p.account).toList();
      final idsByConfig = <String, String>{};
      for (final p in plans) {
        for (final cid in p.configIds) {
          idsByConfig[cid] = p.account.id;
        }
      }
      for (var i = 0; i < apiConfigs.length; i++) {
        final bound = idsByConfig[apiConfigs[i].id];
        if (bound != null && apiConfigs[i].accountId.trim().isEmpty) {
          apiConfigs[i] = apiConfigs[i].copyWith(accountId: bound);
        }
      }
    }
    final conversations = conversationsRaw
        .map((m) => Conversation.fromMap(Map<String, dynamic>.from(m as Map)))
        .toList();
    final messages = messagesRaw
        .map((m) => ChatMessage.fromMap(Map<String, dynamic>.from(m as Map)))
        .toList();
    // plugins 就是 Map<String,dynamic>，不需要 fromMap，后面直接 upsertPlugin 到 DB
    final plugins =
        pluginsRaw.map((m) => Map<String, dynamic>.from(m as Map)).toList();
    // v1.7.39 (T1)：6 张新表模型解析
    final globalMemories = globalMemoriesRaw
        .map((m) => GlobalMemory.fromMap(Map<String, dynamic>.from(m as Map)))
        .toList();
    final projects = projectsRaw
        .map((m) => Project.fromMap(Map<String, dynamic>.from(m as Map)))
        .toList();
    final projectMemories = projectMemoriesRaw
        .map((m) => ProjectMemory.fromMap(Map<String, dynamic>.from(m as Map)))
        .toList();
    final slashCommands = slashCommandsRaw
        .map((m) => SlashCommand.fromMap(Map<String, dynamic>.from(m as Map)))
        .toList();
    final messageVersionRows = messageVersionsRaw
        .map((m) => Map<String, dynamic>.from(m as Map))
        .toList();
    final compactionRows =
        compactionRaw.map((m) => Map<String, dynamic>.from(m as Map)).toList();
    final knowledgeBaseRows = knowledgeBasesRaw
        .map((m) => Map<String, dynamic>.from(m as Map))
        .toList();
    final knowledgeChunkRows = knowledgeChunksRaw
        .map((m) => Map<String, dynamic>.from(m as Map))
        .toList();
    final assistantRows = assistantsRaw
        .map((m) => Map<String, dynamic>.from(m as Map))
        .toList();
    WebSearchConfig? webSearchCfg;
    if (webSearchRaw != null) {
      webSearchCfg =
          WebSearchConfig.fromMap(Map<String, dynamic>.from(webSearchRaw));
    }

    // v1.7.41 build95（安全审查致命项修复）：覆盖模式原先「_clearAllTables 逐表
    // delete 各自自动提交 + 后续逐条 saveXxx 各自提交」全程无外层事务——中途失败
    // （磁盘满/DB 锁/序列化异常）= 原数据已物理删除、新数据只写了一半，不可逆全损。
    // 现修复为：清空 + 全部插入包在同一个 database.transaction 里，任一步失败
    // 整体回滚，原有数据分毫不动。
    // 注意：sqflite 事务内必须用 txn 对象读写——走 _storage 的普通方法（内部用 db）
    // 会在事务外排队造成死锁，故下面所有读写统一走 txn。
    final db = await _storage.db;
    // WebSearchConfig「导入文件不含 key 时保留当前 key」需要读当前库——事务外先读好
    final currentCfg =
        webSearchCfg != null ? await _storage.getWebSearchConfig() : null;

    int apiConfigCount = 0;
    int apiAccountCount = 0;
    int conversationCount = 0;
    int messageCount = 0;
    // ✅ NEW-BUG-01：插件导入计数
    int pluginCount = 0;
    int globalMemoryCount = 0;
    int projectCount = 0;
    int projectMemoryCount = 0;
    int slashCommandCount = 0;
    int messageVersionCount = 0;
    int compactionCount = 0;
    // build101：新表导入计数
    int knowledgeBaseCount = 0;
    int knowledgeChunkCount = 0;
    int assistantCount = 0;
    // build103：KB id 重挂映射（合并模式撞 id 时 chunks.kbId 跟随）
    final kbIdMap = <String, String>{};
    // build104（S2）：助手 id 重挂映射（conversations.assistantId 跟随）
    final assistantIdMap = <String, String>{};
    // build145（第 7 轮 P1）：本次导入的会话（最终 id + 原样带进来的收藏串）。
    // 收藏要等**消息循环**跑完才重映射得动（`messageIdMap` 在那时才齐），
    // 而会话循环在消息循环之前 —— 所以先记账，后面补一刀。
    final starredFixups = <({String convId, String starred})>[];
    // build171（D13）：本次导入**真正写过的表名**，由 put 的调用点累积。
    // 这里不写死名单：权威清单住在 StorageService._createV2Tables 的那几条 CREATE，
    // 要核查什么表，取决于导入这条路真的动过什么表（用例从源码枚举那几条 CREATE）。
    final writtenTables = <String>{};

    await db.transaction((txn) async {
      // 事务内统一入口：replace 语义与各 StorageService.saveXxx 一致；
      // 恢复导入不做条数裁剪（保持备份原样），故不调用带 trim 的 saveGlobalMemory/saveProjectMemory
      // 先记表名再写：INSERT 抛了也要留下这一笔 —— 收尾那次 sqlite_master 核查靠它认出
      // 「这一表的写入全失败过」，不让它躲在插件循环那个只 warn 的 catch 里。
      Future<void> put(String table, Map<String, dynamic> row) {
        writtenTables.add(table);
        return txn.insert(table, row,
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      Future<bool> exists(String table, String id) async =>
          (await txn.query(table, where: 'id = ?', whereArgs: [id], limit: 1))
              .isNotEmpty;

      if (!merge) {
        // 覆盖模式：清空所有表（web_search_configs 是 singleton 保留行，事务后覆盖）
        // 删除顺序：先子表后父表
        for (final table in const [
          'message_versions',
          'context_compaction_segments',
          'messages',
          'project_memories',
          'slash_commands',
          'conversations',
          'projects',
          'global_memories',
          'api_configs',
          // build138（G52）：账号表紧随其后（覆盖模式下必须先清子表 api_configs
          // 再清父表 api_accounts，顺序与上面 conversations 的写法一致）
          'api_accounts',
          // ✅ NEW-BUG-01：覆盖模式同样清空 plugins 表，否则旧插件 + 老导入的插件会混在一起
          'plugins',
          // build103：知识库/切片/助手三表同入清表清单（否则覆盖导入后旧行残留）
          'knowledge_bases',
          'knowledge_chunks',
          'assistants',
        ]) {
          await txn.delete(table);
        }
        _projectIdMap.clear();
        _logger.info(
            '[Backup] All tables cleared (overwrite mode, in transaction)',
            tag: 'Backup');
      }

      // 合并模式：UUID 冲突时给导入项生成新 UUID，并维护 ID 映射
      // 覆盖模式：原样插入（库已清空，理论上不会有冲突）
      final apiConfigIdMap = <String, String>{}; // oldId -> newId
      final conversationIdMap = <String, String>{};
      // build138（G52）：账号 id 重挂映射（合并模式撞 id 时条目引用跟随）
      final accountIdMap = <String, String>{};

      // 账号先于条目入库：条目行里的 accountId 必须在这之前就已经确定新 id。
      for (final acct in apiAccounts) {
        var newId = acct.id;
        if (await exists('api_accounts', acct.id)) {
          if (merge) {
            newId = _uuid.v4();
            accountIdMap[acct.id] = newId;
          }
          // 覆盖模式上面已清表，理论上不会走到这里；真撞上了（同名 id 被别的
          // 表占用等异常）就用 replace 原样覆盖，不静默丢条目引用。
        }
        final toSave = newId == acct.id
            ? acct
            : ApiAccount.fromMap(acct.toMap()..['id'] = newId);
        // build146（密钥入 Keystore）：导入也过一道保险库。这里**不能**用
        // toMap() 直写 —— 那等于把备份文件里的明文 Key 原样搬进 SQLite 列，
        // 绕开了本批唯一的落库出口。rowForImportedSecrets 只种非空值、
        // 不删既有键（导入整段是可回滚事务，事务里删 Key 删得回来才敢删）。
        await put('api_accounts', await _storage.rowForImportedSecrets(toSave));
        apiAccountCount++;
      }

      for (final cfg in apiConfigs) {
        String newId = cfg.id;
        if (merge) {
          if (await exists('api_configs', cfg.id)) {
            // ID 冲突，生成新 UUID
            newId = _uuid.v4();
            apiConfigIdMap[cfg.id] = newId;
          }
        }
        // build97 (P1-2 修复)：不再手工枚举字段重建（v1.4.3 漏 topP、
        // v1.7.9 漏 cachedModels、本轮又漏 contextWindowTokens/supportVision/
        // supportToolCalls 三个——枚举法必然随新字段继续漏）。改 toMap→
        // fromMap 往返（模型 toMap/fromMap 往返对称性已核验），只覆盖 id。
        // build138（G52）：同理，账号引用也走 map 往返，只额外覆盖 accountId。
        final remappedAccount = accountIdMap[cfg.accountId];
        final row = cfg.toMap()
          ..['id'] = newId
          ..['accountId'] = remappedAccount ?? cfg.accountId;
        final toSave = ApiConfig.fromMap(row);
        // build146：同账号那一跳，密钥改走保险库、列里落空串。
        await put('api_configs', await _storage.rowForImportedSecrets(toSave));
        apiConfigCount++;
      }

      // build104（S2）：知识库/切片/助手三表导入**前置到 conversations 之前**——
      // 会话行携带 knowledgeBaseId/assistantId 引用，必须先确定重映射再写会话。
      // build103 版把三表放在会话之后且不回写，合并撞 id 时会话引用挂空（扫描 S2）。
      // 切片含 embedding JSON 字符串，原样回插（向量不重算，与 C1 检索口径兼容）。
      for (final row in knowledgeBaseRows) {
        final oldId = row['id'];
        if (merge && oldId is String && await exists('knowledge_bases', oldId)) {
          final newId = _uuid.v4();
          kbIdMap[oldId] = newId;
          row['id'] = newId;
        }
        await put('knowledge_bases', row);
        knowledgeBaseCount++;
      }
      for (final row in knowledgeChunkRows) {
        if (merge) {
          final kid = row['kbId'];
          if (kid is String) {
            final mapped = kbIdMap[kid];
            if (mapped != null) row['kbId'] = mapped;
          }
        }
        await put('knowledge_chunks', row);
        knowledgeChunkCount++;
      }
      for (final row in assistantRows) {
        final aid = row['id'];
        if (merge && aid is String && await exists('assistants', aid)) {
          final newId = _uuid.v4();
          assistantIdMap[aid] = newId;
          row['id'] = newId;
        }
        await put('assistants', row);
        assistantCount++;
      }

      for (final conv in conversations) {
        String newId = conv.id;
        String? newApiConfigId;
        // build104（S2）：KB/助手引用跟随重映射——build103 版把三表放在
        // conversations 之后且不回写，合并撞 id 时会话引用挂空
        var newKbId = conv.knowledgeBaseId;
        var newAssistantId = conv.assistantId;
        if (merge) {
          if (await exists('conversations', conv.id)) {
            newId = _uuid.v4();
            conversationIdMap[conv.id] = newId;
          }
          // 如果 API 配置被换了新 ID，对话的 apiConfigId 也要跟着换
          newApiConfigId = apiConfigIdMap[conv.apiConfigId] ?? conv.apiConfigId;
          newKbId = kbIdMap[conv.knowledgeBaseId] ?? conv.knowledgeBaseId;
          newAssistantId =
              assistantIdMap[conv.assistantId] ?? conv.assistantId;
        } else {
          newApiConfigId = conv.apiConfigId;
        }
        // build97 (P1-3 修复)：手工枚举又漏 projectId（项目归属丢失→
        // 项目记忆不再注入）。同样改 toMap→fromMap 往返，覆盖 id/apiConfigId，
        // 以后 Conversation 新增字段不会再漏。
        final changed = newId != conv.id ||
            newApiConfigId != conv.apiConfigId ||
            newKbId != conv.knowledgeBaseId ||
            newAssistantId != conv.assistantId;
        final toSave = !changed
            ? conv
            : Conversation.fromMap(conv.toMap()
              ..['id'] = newId
              ..['apiConfigId'] = newApiConfigId
              ..['knowledgeBaseId'] = newKbId
              ..['assistantId'] = newAssistantId);
        // 直接写库，绕过 saveConversation 的"更新 lastMessage/updatedAt"逻辑
        await put('conversations', toSave.toMap());
        if (merge) {
          starredFixups
              .add((convId: newId, starred: toSave.starredMessageIds));
        }
        conversationCount++;
      }

      // build97 (P1-1 修复)：合并模式下消息主键撞车时必须重分配 id——
      // 旧逻辑沿用 msg.id + 换 conversationId，INSERT OR REPLACE 会把
      // 原会话的消息行「搬」到新会话（原会话被搬空 + 冒出重复会话）。
      // 重映射引用链：messageIdMap 同步改 messages.retryOf、
      // message_versions.retryOfId、context_compaction_segments.start/endMessageId。
      final messageIdMap = <String, String>{};
      for (final msg in messages) {
        String newConvId = msg.conversationId;
        if (merge) {
          newConvId =
              conversationIdMap[msg.conversationId] ?? msg.conversationId;
        }
        String? newMsgId;
        if (merge && await exists('messages', msg.id)) {
          newMsgId = _uuid.v4();
          messageIdMap[msg.id] = newMsgId;
        }
        final ChatMessage toSave;
        if (newConvId == msg.conversationId && newMsgId == null) {
          toSave = msg;
        } else {
          // toMap→fromMap 往返重建（附件/思考步骤/来源/token 8 列等
          // 全字段保留，手工枚举漏字段的坑一并根治），只覆盖 id/会话/重试引用
          final row = msg.toMap();
          if (newMsgId != null) row['id'] = newMsgId;
          row['conversationId'] = newConvId;
          final retryOf = row['retryOf'];
          if (retryOf is String && retryOf.isNotEmpty) {
            final mapped = messageIdMap[retryOf];
            if (mapped != null) row['retryOf'] = mapped;
          }
          toSave = ChatMessage.fromMap(row);
        }
        // v1.4.3 修复 Bug #1（教训#30）：绕过 saveMessage 直接 insert
        // saveMessage 会更新 conversation.updatedAt 为 NOW → 导入后对话排序错乱
        await put('messages', toSave.toMap());
        messageCount++;
      }

      // build145（第 7 轮 P1）：收藏的消息 id 跟着 `messageIdMap` 换址。
      // build97 P1-1 当时把引用链一路改到 retryOf / message_versions / 压缩段起止，
      // 唯独漏了这一串 —— 而 `Conversation.starredIds` 对引用不到的 id 是
      // **静默返回空集**（conversation.dart:130-132），所以后果长成"换机后收藏没了"，
      // 日志里一行都没有。判定与序列化都走 remapStarredMessageIds（同一套编解码口径）。
      if (merge && messageIdMap.isNotEmpty) {
        for (final fix in starredFixups) {
          final next = remapStarredMessageIds(fix.starred, messageIdMap);
          if (next == fix.starred) continue;
          await txn.update('conversations', {'starredMessageIds': next},
              where: 'id = ?', whereArgs: [fix.convId]);
          _logger.db(
              'Backup import: remapped starred refs for ${fix.convId}');
        }
      }

      // ✅ NEW-BUG-01 修复：导入 plugins 数组 → DB plugins 表
      //   - 覆盖模式：_clearAllTables 已经删 plugins 表全部行，直接 replace 写即可
      //   - 合并模式：以 DB 现有 id 为准，冲突时 replace（导入备份的插件设置覆盖当前同 id 设置；若当前已有设置用户不想被覆盖，则应先手动卸载再 merge）
      for (final row in plugins) {
        try {
          // row 结构和 loadAllPlugins 返回一致：{id, name, version, source, author, description, enabled, installedAt, metadataJson}
          // build146（行业分歧安全批 ②）：导出侧剥过凭据的行（extra.authSecretRedacted）
          // 在这里落成"禁用 + 原因可见"，而不是照原样写回一个跑不通的服务器。
          final sanitized = applyMcpAuthRedactedImportState(
              Map<String, dynamic>.from(row));
          final metadataRaw = sanitized['metadataJson'];
          // build133（①）：metadataJson **不再"缺失即判坏行"**。
          // 系统插件行历史上就是 NULL（见 savePluginState 兜底 INSERT 的条件写入），
          // 旧逻辑 `is! String → throw` 会被下面的 catch 吞掉整行 ⇒ 系统插件的
          // 禁用状态「导出→导入」后丢失。现在：缺失/空 ⇒ 空对象兜底（id 取行内主键），
          // **只有远程插件（MCP）才强制要求完整 metadata** —— 远程配置丢了无法重建 client，
          // 且必须保持禁用，不能静默降级成"本地插件"。
          final meta = decodePluginMetadataForImport(metadataRaw, sanitized['id']);
          final metadata = PluginMetadata.fromMap(meta.decoded);
          if (metadata.kind.isRemote) {
            if (!meta.hadMetadata) {
              throw const FormatException('Remote plugin metadata is missing');
            }
            InstalledMcpConfig.fromJson(metadata.extra);
            sanitized['enabled'] = 0;
          } else if (!meta.hadMetadata) {
            // 本地/内置：落成合法空对象，避免再写出 null（往返稳定）
            sanitized['metadataJson'] = '{}';
          }
          // 强制重新计算 enabled/int 转换（容错：enabled 可能是 bool 或 int 或 String）
          final dynEnabled = sanitized['enabled'];
          if (dynEnabled is bool) {
            sanitized['enabled'] = dynEnabled ? 1 : 0;
          } else if (dynEnabled is int) {
            sanitized['enabled'] = dynEnabled == 0 ? 0 : 1;
          } else if (dynEnabled is String) {
            final s = dynEnabled.trim().toLowerCase();
            sanitized['enabled'] =
                (s == '1' || s == 'true' || s == 'yes' || s == 'on') ? 1 : 0;
          } else if (!metadata.kind.isRemote) {
            sanitized['enabled'] = 1; // 兜底：默认启用，避免导入后全是 0 导致插件全禁用
          }
          // installedAt 容错：确保 int（毫秒）
          final dInstalledAt = sanitized['installedAt'];
          if (dInstalledAt is! int) {
            sanitized['installedAt'] = DateTime.now().millisecondsSinceEpoch;
          }
          await put('plugins', sanitized);
          pluginCount++;
        } catch (e, st) {
          // 单条插件失败不阻塞整体导入，记日志继续
          //   ↑ 这个"继续"只兜**坏行**：表整体不在时逐行都会走到这里，坏行容错就变成
          //   永久丢配置了 —— 那一路由本函数收尾的 sqlite_master 核查判成失败并回滚
          //   （build171 D13；把它改成这里 rethrow 会把 build133 修的"缺失 metadata
          //   不等于坏数据"那套容错一起废掉，所以收口放在收尾，不在这里）。
          // v1.7.37（待办⑬）：日志只写插件 id——row.metadataJson 可能含 MCP 鉴权头明文，
          // 整行打印会泄露凭据（铁律：日志不写 Key 明文）。
          _logger.warn('[Backup] import plugin row failed: id=${row['id']}',
              cat: LogCat.backup, tag: 'Backup');
          _logger.error('[Backup] import plugin row error detail:',
              error: e, stack: st, cat: LogCat.backup, tag: 'Backup');
        }
      }

      // v1.7.39 (T1)：写入 6 张新表
      // 顺序：projects → globalMemories/projectMemories/slashCommands（依赖 projects）
      //       → messageVersions（依赖 conversations）→ compactionSegments（依赖 conversations）
      // 计数器 globalMemoryCount/projectCount/projectMemoryCount/slashCommandCount/
      // messageVersionCount/compactionCount 已在事务外（解析段之后）统一声明。
      for (final p in projects) {
        String newId = p.id;
        if (merge) {
          if (await exists('projects', p.id)) {
            newId = _uuid.v4();
          }
        }
        final toSave = newId == p.id
            ? p
            : Project(id: newId, name: p.name, createdAt: p.createdAt);
        await put('projects', toSave.toMap());
        projectCount++;
        // 记录 id 映射，供 projectMemories/slashCommands 重挂
        if (newId != p.id) {
          _projectIdMap[p.id] = newId;
        }
      }

      for (final m in globalMemories) {
        String newId = m.id;
        if (merge) {
          if (await exists('global_memories', m.id)) {
            newId = _uuid.v4();
          }
        }
        final toSave = newId == m.id
            ? m
            : GlobalMemory(
                id: newId,
                content: m.content,
                source: m.source,
                pinned: m.pinned,
                createdAt: m.createdAt,
                updatedAt: m.updatedAt);
        await put('global_memories', toSave.toMap());
        globalMemoryCount++;
      }

      for (final m in projectMemories) {
        String newId = m.id;
        String newProjectId = _projectIdMap[m.projectId] ?? m.projectId;
        if (merge) {
          if (await exists('project_memories', m.id)) {
            newId = _uuid.v4();
          }
        }
        final toSave = (newId == m.id && newProjectId == m.projectId)
            ? m
            : ProjectMemory(
                id: newId,
                projectId: newProjectId,
                content: m.content,
                source: m.source,
                createdAt: m.createdAt,
                updatedAt: m.updatedAt);
        await put('project_memories', toSave.toMap());
        projectMemoryCount++;
      }

      for (final c in slashCommands) {
        String newId = c.id;
        String newScope = c.scope;
        // 项目作用域命令：projectId 可能已重映射
        if (newScope.startsWith('project:')) {
          final pid = newScope.substring('project:'.length);
          final mapped = _projectIdMap[pid];
          if (mapped != null) newScope = 'project:$mapped';
        }
        if (merge) {
          if (await exists('slash_commands', c.id)) {
            newId = _uuid.v4();
          }
        }
        final toSave = (newId == c.id && newScope == c.scope)
            ? c
            : SlashCommand(
                id: newId,
                name: c.name,
                promptTemplate: c.promptTemplate,
                scope: newScope,
                createdAt: c.createdAt,
                updatedAt: c.updatedAt);
        await put('slash_commands', toSave.toMap());
        slashCommandCount++;
      }

      // messageVersions：retryOfId 是消息 id。build97 (P1-1)：
      // 消息撞 id 重分配后，这里必须跟着重映射，否则重试快照挂空。
      for (final row in messageVersionRows) {
        // build97 (P0-1)：build97 以前导出的备份没有 savedAt 列，
        // 建表 NOT NULL，导入时补空串兜底，否则旧备份同样导入必回滚。
        if (row['savedAt'] is! String) {
          row['savedAt'] = '';
        }
        if (merge) {
          final r = row['retryOfId'];
          if (r is String) {
            final mapped = messageIdMap[r];
            if (mapped != null) row['retryOfId'] = mapped;
          }
        }
        await put('message_versions', row);
        messageVersionCount++;
      }

      for (final row in compactionRows) {
        // 合并模式下 conversationId 需重映射
        if (merge) {
          final cid = row['conversationId'] as String?;
          if (cid != null) {
            final mapped = conversationIdMap[cid];
            if (mapped != null) row['conversationId'] = mapped;
          }
          // build97 (P1-1)：段起止消息 id 同样跟随重映射，避免挂空引用
          for (final k in const ['startMessageId', 'endMessageId']) {
            final mid = row[k];
            if (mid is String) {
              final mapped = messageIdMap[mid];
              if (mapped != null) row[k] = mapped;
            }
          }
        }
        await put('context_compaction_segments', row);
        compactionCount++;
      }

      // build171（D13）：表存在性核查——这一段是「界面报完成、插件配置永久丢失」唯一的收口。
      // 上面插件循环的 catch 只写日志、不 rethrow：`plugins` 表不在时（建表只跑
      // onCreate/onUpgrade，启动自检不补 ⇒ 老库可能压根没有它）每条 INSERT 都失败却被
      // 逐行咽下，pluginCount 归零但没人读它，事务照常 commit。
      // 口径：本次真的写过的表（writtenTables）必须在 sqlite_master 里都在；
      // 缺任何一张就抛 ⇒ 上面 `}); // end transaction` 之前的一切整体回滚、原数据分毫不动，
      // 错误沿 importFromString 冒到界面（backup_settings_screen 那个 catch 会念出原因）。
      // 这里不许退化成 warn 一下继续：warn 的那一次，用户的 MCP 配置（含鉴权头）就真没了。
      final existingTables = <String>{
        for (final r in await txn.rawQuery(
            "SELECT name FROM sqlite_master WHERE type = 'table'"))
          (r['name'] as String).toLowerCase(),
      };
      final missingTables = <String>[
        for (final t in writtenTables)
          if (!existingTables.contains(t.toLowerCase())) t,
      ]..sort();
      if (missingTables.isNotEmpty) {
        throw _BackupFormatException(
            '备份导入缺少数据表（${missingTables.join('、')}），本次导入已回滚，原数据未改动');
      }
    }); // end transaction —— 此处之前任何异常都会整体回滚，原数据不动

    // WebSearchConfig 是 singleton，合并/覆盖都直接覆盖（v1.3.8 决定不合并 KV 级字段）
    // 该行从未被清空（清表保留 singleton），单条 replace 无数据丢失风险，
    // 故放在事务外执行（顺带触发 notifyListeners 刷新 UI）。
    if (webSearchCfg != null && currentCfg != null) {
      // 如果导入的文件不含 key（includeKeys=false），保留当前库的 key 不覆盖
      final importedIncludeKeys = (root['includeKeys'] as bool?) ?? true;
      // v1.4.3 修复 Bug #5：所有 4 个 API Key 字段统一应用"保留当前"逻辑
      // 之前只 tavilyApiKey 享受，serpApiKey/braveApiKey/googleCseApiKey 会被空字符串直接覆盖
      // → 用户在 A 设备填好的 SerpAPI/Brave/Google CSE Key 导入不含 Key 的备份到 B 设备后被清空
      String pickKey(String imported, String current) {
        if (importedIncludeKeys) {
          // build152（数据层扫描 D2）：merge 的语义是"导入的补进来、本机的不丢"，
          // 所以**文件里这一格是空的**就不许覆盖本机 —— 一份当年没配过 Tavily/Brave 的旧备份
          // 做合并恢复，以前会无条件把用户后来填进去的 Key 清掉（includeKeys=true 时
          // 完全跟随文件，空串也算值）。只有覆盖导入（换机还原整份状态）才允许用空值清本机，
          // 那本来就是"以文件为准"的意思。与同段 `biometricLockEnabled` 的口径对齐。
          if (merge && imported.trim().isEmpty) return current;
          return imported;
        }
        return current.isNotEmpty ? current : '';
      }

      // v1.4.3 修复 Bug #4：WebSearchConfig 重建补齐 5 个 v1.3.9 新增字段
      // 之前漏 serpApiKey/serpapiEngine/braveApiKey/googleCseApiKey/googleCseId
      // → 导入后 SerpAPI/Brave/Google CSE 三服务商配置全部丢失
      final merged = WebSearchConfig(
        webSearchEnabled: webSearchCfg.webSearchEnabled,
        provider: webSearchCfg.provider,
        tavilyApiKey:
            pickKey(webSearchCfg.tavilyApiKey, currentCfg.tavilyApiKey),
        tavilySearchDepth: webSearchCfg.tavilySearchDepth,
        tavilyMaxResults: webSearchCfg.tavilyMaxResults,
        tavilyAutoMaxResults: webSearchCfg.tavilyAutoMaxResults,
        searxngInstanceUrl: webSearchCfg.searxngInstanceUrl,
        serpApiKey: pickKey(webSearchCfg.serpApiKey, currentCfg.serpApiKey),
        serpapiEngine: webSearchCfg.serpapiEngine,
        braveApiKey: pickKey(webSearchCfg.braveApiKey, currentCfg.braveApiKey),
        googleCseApiKey:
            pickKey(webSearchCfg.googleCseApiKey, currentCfg.googleCseApiKey),
        googleCseId: webSearchCfg.googleCseId,
        maxSnippetCharsPerResult: webSearchCfg.maxSnippetCharsPerResult,
        maxResultsInject: webSearchCfg.maxResultsInject,
        persistentWebSearchToggle: webSearchCfg.persistentWebSearchToggle,
        reactEnabled: webSearchCfg.reactEnabled,
        reactMaxRounds: webSearchCfg.reactMaxRounds,
        reactAutoMode: webSearchCfg.reactAutoMode,
        githubProxyUrl: webSearchCfg.githubProxyUrl,
        verboseLogging: webSearchCfg.verboseLogging,
        // v1.7.9 (M3 修复)：补齐 v1.7.5 安全审查 5 字段，
        // 之前漏掉 → 导入备份会把 SkillSpector/MobSF 端点和 3 个开关静默重置为空/关
        skillspectorEndpoint: webSearchCfg.skillspectorEndpoint,
        enableSkillSecurityScan: webSearchCfg.enableSkillSecurityScan,
        enableMcpSecurityScan: webSearchCfg.enableMcpSecurityScan,
        mobsfEndpoint: webSearchCfg.mobsfEndpoint,
        enableApkSecurityScan: webSearchCfg.enableApkSecurityScan,
        // v1.7.10：本地扫描 2 字段（同 M3 教训：导入别静默重置）
        enableLocalScan: webSearchCfg.enableLocalScan,
        localScanRulesUrl: webSearchCfg.localScanRulesUrl,
        // v1.7.11：VirusTotal + MobSF API Key（同 M3 教训）
        // build138（P1-1）：这两列漏走 pickKey —— 导出侧 isSecretKey 后缀白名单
        // （:150-166）会把所有 *ApiKey 从「不含 Key」的备份里剥掉，fromMap 兜底成 ''，
        // 于是导入一次安全备份就把本地已填的 VirusTotal/MobSF Key 静默清零（且立刻落库）。
        // 这正是 v1.4.3 Bug#5 为上面 4 个 Key 修过的同一类缺陷。
        virusTotalApiKey:
            pickKey(webSearchCfg.virusTotalApiKey, currentCfg.virusTotalApiKey),
        enableVirusTotalScan: webSearchCfg.enableVirusTotalScan,
        mobsfApiKey: pickKey(webSearchCfg.mobsfApiKey, currentCfg.mobsfApiKey),
        // build145（循环审查第 7 轮 P1）：应用锁**不许被合并导入改掉**。
        // 这一段本来就有 `pickKey`（v1.4.3 Bug#5）在守"备份不含敏感字段就别静默重置本地设置"，
        // 但安全开关整个漏在了这套逻辑之外：从旧手机导一份没开锁的备份过来，
        // 这台设备的应用锁就悄悄关了 —— 这是**放松**，比丢一个 Key 更值得保守。
        // 口径：合并＝保留本机现状（要在本机开锁，请在本机设置里打开）；
        // 覆盖导入（换机还原整份状态）才跟随文件。
        // 同一段里的扫描类开关（enableSkillSecurityScan 等）本轮**故意不动**：
        // 它们只影响"要不要送外部扫"，不 gates 本机数据访问，且改它们会连带影响
        // 已经配好的端点语义 —— 记在第 7 轮的待核清单里，不当场扩大面。
        biometricLockEnabled: merge
            ? currentCfg.biometricLockEnabled
            : webSearchCfg.biometricLockEnabled,
      );
      // build152（数据层扫描 D2）：`merged` 是全新对象，`unreadableSecrets` 天生为空 ⇒
      // 本次开机"读不到的那格"标记在这里丢失，随后 `saveWebSearchConfig` 就会拿空值
      // 去覆盖并**删掉保险库条目** —— 与 build147 修掉的那条 P0 同形。
      // 标记必须跟着"本机现状"走，不是跟着文件走。
      merged.unreadableSecrets.addAll(currentCfg.unreadableSecrets);
      await _storage.saveWebSearchConfig(merged);
    }

    // build146：清掉「行已被覆盖导入删掉、保险库里还留着 Key」的孤儿条目。
    // 覆盖模式清空了 api_configs / api_accounts 整表，但保险库不在 SQLite 里，
    // 事务清空不到它 —— 不等在这儿扫一次，用户就永久残留一批无主密钥。
    // （导入事务里种下的、最终没落库的键同样在这里被收掉。）
    await _storage.sweepOrphanSecrets(db);

    _logger.info(
        '[Backup] Import ${merge ? "merge" : "overwrite"} done: '
        '$apiConfigCount configs, $apiAccountCount accounts, '
        '$conversationCount conversations, $messageCount messages, '
        '$pluginCount plugins, $globalMemoryCount globalMemories, '
        '$projectCount projects, $projectMemoryCount projectMemories, '
        '$slashCommandCount slashCommands, $messageVersionCount messageVersions, '
        '$compactionCount compactionSegments, '
        '$knowledgeBaseCount knowledgeBases, $knowledgeChunkCount knowledgeChunks, '
        '$assistantCount assistants',
        tag: 'Backup');

    return ImportStats(
      apiConfigs: apiConfigCount,
      apiAccounts: apiAccountCount,
      conversations: conversationCount,
      messages: messageCount,
      plugins: pluginCount,
      globalMemories: globalMemoryCount,
      projects: projectCount,
      projectMemories: projectMemoryCount,
      slashCommands: slashCommandCount,
      messageVersions: messageVersionCount,
      compactionSegments: compactionCount,
      knowledgeBases: knowledgeBaseCount,
      knowledgeChunks: knowledgeChunkCount,
      assistants: assistantCount,
    );
  }

  /// 从文件路径导入
  Future<ImportStats> importFromFile(String filePath,
      {required bool merge}) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw _BackupFileNotFoundException(filePath);
    }
    final jsonStr = await file.readAsString();
    return importFromString(jsonStr, merge: merge);
  }
}

/// 导入统计
class ImportStats {
  final int apiConfigs;
  final int conversations;
  final int messages;
  // ✅ NEW-BUG-01：新增 plugins 导入数量字段（给 UI 展示导入统计用）
  final int plugins;
  // v1.7.39 (T1)：6 张新表导入数量
  final int globalMemories;
  final int projects;
  final int projectMemories;
  final int slashCommands;
  final int messageVersions;
  final int compactionSegments;
  // build101（C1/E8）：知识库与助手
  final int knowledgeBases;
  final int knowledgeChunks;
  final int assistants;

  /// build138（G52）：账号层导入条数（可选字段，老调用点不传也能编译）
  final int apiAccounts;
  const ImportStats({
    required this.apiConfigs,
    required this.conversations,
    required this.messages,
    this.apiAccounts = 0,
    this.plugins = 0,
    this.globalMemories = 0,
    this.projects = 0,
    this.projectMemories = 0,
    this.slashCommands = 0,
    this.messageVersions = 0,
    this.compactionSegments = 0,
    this.knowledgeBases = 0,
    this.knowledgeChunks = 0,
    this.assistants = 0,
  });

  @override
  String toString() =>
      'ImportStats(configs=$apiConfigs, accounts=$apiAccounts, '
      'conversations=$conversations, messages=$messages, plugins=$plugins, '
      'globalMemories=$globalMemories, projects=$projects, projectMemories=$projectMemories, '
      'slashCommands=$slashCommands, messageVersions=$messageVersions, compactionSegments=$compactionSegments)';
}

class _BackupFormatException implements Exception {
  final String message;
  const _BackupFormatException(this.message);
  @override
  String toString() => 'BackupFormatException: $message';
}

class _BackupFileNotFoundException implements Exception {
  final String path;
  const _BackupFileNotFoundException(this.path);
  @override
  String toString() => 'BackupFileNotFoundException: $path';
}

/// v1.4.3 修复 Bug #8：导出文件写入失败的自定义异常
class _BackupIOException implements Exception {
  final String message;
  const _BackupIOException(this.message);
  @override
  String toString() => 'BackupIOException: $message';
}
