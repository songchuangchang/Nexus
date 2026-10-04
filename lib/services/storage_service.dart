import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
// sqflite_common_ffi 导出 sqflite 的全部公共类型（Database/openDatabase/…），
// 所以这里只引 ffi 一个包；手机路径走的仍是 sqflite 的默认 factory，
// 只有 init() 的桌面分支才会把全局 factory 换成 ffi 版。
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import '../models/api_account.dart';
import '../models/api_config.dart';
import '../models/api_provider_template.dart';
import '../models/conversation.dart';
import '../models/chat_message.dart';
import '../models/context_compaction_segment.dart';
import '../models/video_task.dart';
import '../models/web_search_config.dart';
import '../models/memory_models.dart';
import '../models/knowledge_base.dart';
import '../models/usage_stat.dart';
import '../models/assistant.dart';
import '../utils/context_compaction_drop.dart';
import 'live_task_wiring.dart';
import 'logger_service.dart';
import 'repo_endpoints.dart';
import 'secret_store.dart';

/// build173（用户批准的方案 C）：AI 自动写长期记忆的**总闸** —— SharedPreferences 的键，
/// **只在这里定义一次**（与 `kBackgroundRunAllowedKey` / `kLiveNotificationsEnabled`
/// 「设置页与落库点读同一把 key」是同一条规矩）。
///
/// ## 默认值是 `true`，理由写在这里免得下一次有人"顺手改成 false"
/// 三家的消费档都是默认开（Claude `on by default for Free, Pro, Max`、
/// Copilot `Saving memories is On by default`；只有企业/医疗这类受监管档才默认关）。
/// 我们这条能力从 build92 起就一直在跑，所以**关着会静默削掉既有功能** ——
/// 默认值的判据是"不改变既有行为"：这道闸的意义是把控制权交给他，不是替他改行为。
///
/// ## 这一位只管"AI 自己伸手写"，不碰用户自己写的
/// 语义是**停写不删**（对齐 Claude 的 `Pause memory` 与 OpenAI 的
/// `关闭记忆不会删除以往的聊天`）：关掉之后已入库的记忆原样还在、照样读得到，
/// 手动那条路（`source` 非 `auto`）一个字都不受影响。
const String kAutoMemoryEnabledKey = 'auto_memory_enabled';

class StorageService extends ChangeNotifier {
  StorageService._internal();

  static final StorageService instance = StorageService._internal();

  final _logger = LoggerService.instance;
  Database? _db;
  bool _initialized = false;

  /// build146（密钥入 Keystore）：全应用唯一的密钥落库出口。
  ///
  /// 本类之下再没有第二条路径能把 apiKey / tavilyApiKey 之类的值写进行里
  /// （写：[_rowOfSecrets]；读：[_hydrateSecrets]；删：[_dropVaultEntries]；
  ///  存量：[_migratePlaintextSecrets]），单测按这条口径钉源码锚点。
  final SecretStore _secrets = SecretStore.instance;

  bool get isInitialized => _initialized;

  // ==================== build146：密钥过持久化边界的四条通道 ====================

  /// 读路径：把保险库里的密钥回填进刚从库里解析出来的对象。
  ///
  /// 列里已有非空值时**不覆盖**（那是保险库写失败时留在原地的明文，
  /// 是「这一行当前唯一可信的值」）。回填是就地改对象——这些都是每次查询新
  /// 解析出来的实例，不是缓存里的共享实例。
  ///
  /// 为什么必须在这里补、而不是把 `apiKey` 改成 `Future<String>`：全仓十几处
  /// 请求路径（api_service / image_gen / video_gen / balance / rag / anthropic
  /// 协议 / 各生成页）读的都是普通字段，改签名会炸穿半个 lib。本类所有
  /// `getXxx` 本来就是 async 的，异步边界收在这里，调用点一行不用改。
  Future<List<T>> _hydrateSecrets<T extends SecretBearing>(List<T> items) async {
    for (final item in items) {
      for (final loc in item.secretLocations()) {
        // 列里已有非空值 ⇒ 列赢，且不去惊动 Keystore（那可能正是写失败留下的明文）。
        if (item.secretValueAt(loc).trim().isNotEmpty) continue;
        final got = await _secrets.readOutcome(loc);
        if (got.isUnknown) {
          // build147 第 11 轮（P0）：读抛 ⇒ **值未知**，必须标记出来。
          // 不标的后果：这个对象的该字段停在空串上，而空串在写路径上的语义是
          // 「用户清空了这把 Key」⇒ 下一次毫不相干的保存（拨联网搜索开关、
          // 改应用锁、调日志设置，全是"读整份单例→改一个字段→写回"）会把
          // 保险库条目删掉，而列里落的也是空串 ⇒ **两把副本同时消失**。
          item.unreadableSecrets.add(loc.column);
          _logger.dbWarn('[DB] 密钥读取失败（值未知，暂按现状保留）：'
              '${loc.table}#${loc.rowId}.${loc.column}');
          continue;
        }
        if (got.value.isEmpty) continue; // absent：真的没填
        item.applySecret(loc, got.value);
      }
    }
    return items;
  }

  /// 写路径：把对象的密钥搬进保险库，返回**可以落库的那一行**。
  ///
  /// 只有全部密钥都「写入并读回逐字校验通过」才抹空列（[SecretBearing.toRowMap]）；
  /// 任一条失败就退回带明文的 [SecretBearing.toMap]，只记一条 WARN。
  /// 这是本批最重要的一条取舍：**明文可用**严格优于**密钥凭空消失**。
  ///
  /// ⚠️ 入参必须是**已回填**的对象（读路径来自 [_hydrateSecrets]，或来自 UI 现填）。
  /// 拿一个密钥列为空的裸行对象过来会把保险库里的对应条目当成「用户清空了这把 Key」
  /// 删掉 —— 所以本方法的所有调用点都在本文件内，且都过一遍读路径。
  Future<Map<String, dynamic>> _rowOfSecrets(SecretBearing item) async {
    var allStored = true;
    final skippedUnknown = <String>[];
    for (final loc in item.secretLocations()) {
      final value = item.secretValueAt(loc);
      // build147 第 11 轮（P0）：这一格的值**没读到过**（保险库读抛）而内存里是空串 ⇒
      // 既不能写（拿空覆盖真值）也不能删（`writeVerified` 的空值分支会删条目）。
      // 用户真的清了 Key 时不在这儿：那时读路径会拿到 absent（不是 failed），
      // 标记不会被加上，删除照常执行。
      if (value.trim().isEmpty && item.unreadableSecrets.contains(loc.column)) {
        skippedUnknown.add(loc.column);
        continue;
      }
      final r = await _secrets.writeVerified(loc, value);
      if (r == SecretWriteResult.failed) {
        allStored = false;
      } else {
        // 写过一次成功就把标记摘掉：否则这个对象后续保存会永远跳过这一格，
        // 用户新填的 Key 反而进不去。
        item.unreadableSecrets.remove(loc.column);
      }
    }
    if (skippedUnknown.isNotEmpty) {
      _logger.dbWarn('[DB] 有密钥本次读不到值，已跳过写入与删除（保留保险库现状）：'
          '${skippedUnknown.join(', ')} —— 若反复出现，说明这台机器的 Keystore 不稳定');
      allStored = false;
    }
    if (allStored) return item.toRowMap();
    _logger.dbWarn('[DB] 保险库写入未通过校验，本次仍以明文落库（功能正常，未加密）：'
        '${item.secretLocations().map((l) => l.fieldKey).join(', ')}');
    return item.toMap();
  }

  /// 删路径的登记：把「提交后要清掉的保险库条目」攒起来，事务成功后再真删。
  ///
  /// 顺序不能反：先删保险库、后删行 ⇒ 万一事务回滚，行还在而 Key 已经没了，
  /// 用户看到的是「配置还在、突然 401」。反过来最坏只是残留一条没人引用的条目
  /// （由 [sweepOrphanSecrets] 兜底收掉）。
  void _queueVaultDelete(
      List<({String scope, String rowId})>? sink, String scope, String rowId) {
    if (sink == null || rowId.isEmpty) return;
    sink.add((scope: scope, rowId: rowId));
  }

  /// 事务提交后统一删保险库条目。
  Future<void> _dropVaultEntries(
      List<({String scope, String rowId})> entries) async {
    for (final e in entries) {
      final n = await _secrets.deleteWhere(scope: e.scope, rowId: e.rowId);
      if (n > 0) _logger.db('密钥条目已从保险库移除：${e.scope}/${e.rowId}（$n 条）');
    }
  }

  /// 逐条解析数据库行：**单条损坏只丢该条**，不让整表加载失败。
  ///
  /// 全量缺陷扫描修复：此前各 `getXxx()` 统一写成
  /// `rows.map(Xxx.fromMap).toList()` —— 只要**任一行**字段缺失或类型不符，
  /// `fromMap` 抛出的异常就会穿透整个 `.map()`，导致「整张表都读不出来」。
  /// 用户侧表现为**全部对话 / 全部 API 配置凭空消失**，而数据其实还在库里。
  /// 这里改为逐条 try：坏行记一条带表名与行号的 warn 后跳过，其余照常返回。
  List<T> _parseRows<T>(
    List<Map<String, Object?>> rows,
    T Function(Map<String, dynamic>) fromMap,
    String label,
  ) {
    final out = <T>[];
    for (var i = 0; i < rows.length; i++) {
      try {
        out.add(fromMap(rows[i]));
      } catch (e) {
        _logger.dbWarn('[DB] $label 第 $i 行解析失败，已跳过：$e');
      }
    }
    return out;
  }

  /// [databaseDirOverride]：仅测试用——指定数据库文件所在目录。
  /// 生产代码永远不传；传了就跳过平台默认目录解析（桌面版迁移测试靠它
  /// 把临时目录里的真机导出库挂进真实的 init() 全链路）。
  Future<void> init({String? databaseDirOverride}) async {
    if (_initialized) return;
    // 桌面版（windows/）：sqflite 没有 Windows 实现，这里把全局
    // databaseFactory 换成 ffi 版（sqlite3 走 dart:ffi，行为与移动端一致）。
    // 注意两点：
    // ① ffi 的 getDatabasesPath() 默认返回**相对 cwd** 的
    //    `.dart_tool/sqflite_common_ffi/databases` —— 免安装包解压到哪、
    //    从哪启动，库就跟着漂移，发布版绝对不能用，必须显式落到
    //    getApplicationSupportDirectory()（Windows 上即
    //    %APPDATA%\<company>\<app>，随用户漫游、与可执行文件位置解耦）。
    // ② `databaseFactory = databaseFactoryFfi` 是**进程级全局**赋值，
    //    手机分支绝不执行它，Android 行为因此逐字节不变。
    final String dbPath;
    if (databaseDirOverride != null) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      dbPath = databaseDirOverride;
    } else if (!kIsWeb && Platform.isWindows) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      dbPath = (await getApplicationSupportDirectory()).path;
    } else {
      dbPath = await getDatabasesPath();
    }
    final path = p.join(dbPath, 'aichat.db');
    _db = await openDatabase(
      path,
      version: 39,
      onCreate: (db, version) async {
        await _createV1Tables(db);
        await _createV2Tables(db);
        await _createContextCompactionSegmentsTable(db);
        await _createMemoryTables(db);
        await _createSearchIndexes(db);
        await _createKnowledgeTables(db);
        await _createAssistantTable(db);
        await _createVideoTasksTable(db);
        // build138（G44）：账号层表。与 _createApiAccountsTable 在 onUpgrade /
        // 启动自检里的两处调用构成「三路同步」铁律的三份拷贝（漏一路 =
        // 新装缺表或老库缺表，两者都是 INSERT 静默失败）。
        await _createApiAccountsTable(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // build152（数据层扫描 D3）：这 9 步全部改走 `_migration(...)` ——
        // 原来它们是裸 `await _migrateVXxx(db)`，任何一条 DDL 抛错就把整库关在门外。
        if (oldVersion < 2) {
          await _migration('v2 建表', () => _createV2Tables(db));
        }
        if (oldVersion < 3) {
          // v1.3.4：为已存在的 web_search_configs 表补 v1.3.1~v1.3.4 新增的列
          // 这些列在原始 _createV2Tables 的 CREATE TABLE 中遗漏，导致保存失败
          await _migration('v3 web_search 补列',
              () => _migrateV3WebSearchColumns(db));
        }
        if (oldVersion < 4) {
          // v1.3.6：messages 表补 attachments 列（存附件 JSON 数组）
          await _migration('v4 messages.attachments',
              () => _migrateV4MessagesAttachments(db));
        }
        if (oldVersion < 5) {
          await _migration('v5 web_search 补列',
              () => _migrateV5WebSearchColumns(db));
        }
        if (oldVersion < 6) {
          await _migration('v6 会话设置补列',
              () => _migrateV6ConversationSettings(db));
        }
        if (oldVersion < 7) {
          // v1.4.1：conversations 补 contextAuto（上下文自动/细化）+ autoCompress（自动压缩）
          await _migration('v7 上下文列', () => _migrateV7ContextColumns(db));
        }
        if (oldVersion < 8) {
          // v1.5.0：api_configs 补 cachedModels 列（缓存 GET /v1/models 拉取的模型列表 JSON）
          await _migration('v8 cachedModels', () => _migrateV8CachedModels(db));
        }
        if (oldVersion < 9) {
          await _migration('v9 plugins 建表', () => _migrateV9Plugins(db));
        }
        if (oldVersion < 10) {
          await _migration('v10 安全扫描列', () => _migrateV10SecurityScan(db));
        }
        if (oldVersion < 11) {
          // v1.7.10：本地安全扫描（enableLocalScan 默认开 + 远程规则源 URL）
          await _ensureColumn(
              db, 'web_search_configs', 'enableLocalScan', 'INTEGER DEFAULT 1');
          await _ensureColumn(
              db, 'web_search_configs', 'localScanRulesUrl', "TEXT DEFAULT ''");
        }
        if (oldVersion < 12) {
          // v1.7.11：VirusTotal 云端查毒 + MobSF API Key
          await _ensureColumn(
              db, 'web_search_configs', 'virusTotalApiKey', "TEXT DEFAULT ''");
          await _ensureColumn(db, 'web_search_configs', 'enableVirusTotalScan',
              'INTEGER DEFAULT 0');
          await _ensureColumn(
              db, 'web_search_configs', 'mobsfApiKey', "TEXT DEFAULT ''");
        }
        if (oldVersion < 13) {
          await _ensureColumn(db, 'messages', 'modelName', "TEXT DEFAULT ''");
          await _ensureColumn(
              db, 'conversations', 'isPinned', 'INTEGER DEFAULT 0');
        }
        if (oldVersion < 14) {
          await _ensureColumn(
              db, 'api_configs', 'templateId', "TEXT DEFAULT 'custom'");
        }
        if (oldVersion < 15) {
          await _ensureColumn(db, 'messages', 'retryOf', "TEXT DEFAULT ''");
          await _ensureColumn(
              db, 'messages', 'retryIndex', 'INTEGER DEFAULT 0');
        }
        if (oldVersion < 16) {
          await _ensureColumn(
              db, 'messages', 'reasoningSteps', "TEXT DEFAULT '[]'");
        }
        if (oldVersion < 17) {
          _logger.db('DB migrated to v17 (reasoningSteps phase/round support)');
        }
        if (oldVersion < 18) {
          await _ensureColumn(db, 'web_search_configs', 'biometricLockEnabled',
              'INTEGER DEFAULT 0');
          await _ensureColumn(
              db, 'web_search_configs', 'verboseLogging', 'INTEGER DEFAULT 0');
          _logger.db('DB migrated to v18 (biometric lock)');
        }
        if (oldVersion < 19) {
          // v1.7.25：思考相关改为每对话独有 → conversations 补 3 列
          await _ensureColumn(
              db, 'conversations', 'reactEnabled', 'INTEGER DEFAULT 1');
          await _ensureColumn(
              db, 'conversations', 'reasoningEffort', 'INTEGER DEFAULT 0');
          await _ensureColumn(
              db, 'conversations', 'reactAutoMode', 'INTEGER DEFAULT 1');
          await _ensureColumn(
              db, 'conversations', 'reactMaxRounds', 'INTEGER DEFAULT 30');
          _logger.db('DB migrated to v19 (per-conversation reasoning effort)');
        }
        if (oldVersion < 20) {
          // v1.7.26 (C2)：messages 补 token 用量 3 列（此前仅内存，重启后丢失）
          await _ensureColumn(db, 'messages', 'promptTokens', 'INTEGER');
          await _ensureColumn(db, 'messages', 'completionTokens', 'INTEGER');
          await _ensureColumn(db, 'messages', 'totalTokens', 'INTEGER');
          _logger.db('DB migrated to v20 (token usage persistence)');
        }
        if (oldVersion < 21) {
          // v1.7.26 (E3)：重试版本快照持久化——新建 message_versions 表
          // （此前版本快照仅存进程内存，重启后版本切换功能丢失）
          // build154（第 12 轮 数据层）：这条 `db.execute` 曾是整段 onUpgrade 里
          // 唯一**既不走 `_migration` 也不走 `_ensureColumn`** 的裸 DDL——那两个才会
          // 吞异常（`_ensureColumn` 自带 try/catch，其余 16 步过 `_migration`）。裸 execute
          // 一旦抛（磁盘满 / 只读 / 迁移中途被杀），异常直接穿透 openDatabase ⇒
          // user_version 不 bump、下次开机重跑同一条又抛 ⇒ **整库永久打不开**，连
          // init() 末尾那段"补建 message_versions 表"的启动自检（在 openDatabase **之后**）
          // 都没机会跑。包一层 `_migration` 后：跳过 + 记 WARN → 库照常开门 →
          // 启动自检的 CREATE TABLE IF NOT EXISTS 把这张表补出来（幂等）。
          await _migration('v21 message_versions 建表', () async {
            await db.execute('''
              CREATE TABLE IF NOT EXISTS message_versions (
                retryOfId TEXT NOT NULL,
                versionIndex INTEGER NOT NULL,
                content TEXT NOT NULL,
                reasoningSteps TEXT DEFAULT '[]',
                promptTokens INTEGER,
                completionTokens INTEGER,
                totalTokens INTEGER,
                injectedWebSearchCount INTEGER DEFAULT 0,
                showStaleFootnote INTEGER DEFAULT 0,
                modelName TEXT DEFAULT '',
                searchSources TEXT DEFAULT '[]',
                savedAt TEXT NOT NULL,
                PRIMARY KEY (retryOfId, versionIndex)
              )
            ''');
            _logger.db('DB migrated to v21 (retry version snapshot persistence)');
          });
        }
        if (oldVersion < 22) {
          // v1.7.33：api_configs 补 supportVision（视觉支持开关）——此前该字段只在
          // 模型类里存在，CREATE TABLE 漏列 + onUpgrade 未补，落库时 INSERT 静默失败
          // （与 v1.3.4 web_search_configs 同型踩坑）
          await _ensureColumn(
              db, 'api_configs', 'supportVision', 'INTEGER DEFAULT 0');
          _logger.db('DB migrated to v22 (per-config vision support toggle)');
        }
        if (oldVersion < 23) {
          // v1.7.34：跨对话记忆 + 深度研究 + 子代理编排
          //   summary         —— 后台 completeChat 生成的对话摘要（≤500 字）
          //   memoryEnabled   —— 跨对话记忆总开关（默认开，可在对话设置里关）
          //   deepResearchMode—— 深度研究模式（打开时强制多专家混合 + 更高轮数 + 关闭 20s 自检）
          //   subagentMode    —— 子代理路由模式：auto/main_only/force_search/force_synthesis/force_plugin
          await _ensureColumn(
              db, 'conversations', 'summary', "TEXT DEFAULT ''");
          await _ensureColumn(
              db, 'conversations', 'memoryEnabled', 'INTEGER DEFAULT 1');
          await _ensureColumn(
              db, 'conversations', 'deepResearchMode', 'INTEGER DEFAULT 0');
          await _ensureColumn(
              db, 'conversations', 'subagentMode', "TEXT DEFAULT 'auto'");
          _logger.db(
              'DB migrated to v23 (cross-conversation memory + subagent orchestration)');
        }
        if (oldVersion < 24) {
          await _ensureColumn(db, 'messages', 'cacheReadTokens', 'INTEGER');
          await _ensureColumn(db, 'messages', 'cacheWriteTokens', 'INTEGER');
          await _ensureColumn(db, 'messages', 'cacheHitTokens', 'INTEGER');
          await _ensureColumn(db, 'messages', 'cacheMissTokens', 'INTEGER');
          await _ensureColumn(
              db, 'message_versions', 'cacheReadTokens', 'INTEGER');
          await _ensureColumn(
              db, 'message_versions', 'cacheWriteTokens', 'INTEGER');
          await _ensureColumn(
              db, 'message_versions', 'cacheHitTokens', 'INTEGER');
          await _ensureColumn(
              db, 'message_versions', 'cacheMissTokens', 'INTEGER');
          await _ensureColumn(
              db, 'api_configs', 'contextWindowTokens', 'INTEGER');
          await _ensureColumn(
              db, 'conversations', 'largeContextMax', 'INTEGER DEFAULT 0');
          _logger.db(
              'DB migrated to v24 (cache usage and context window settings)');
        }
        if (oldVersion < 25) {
          await _migration('压缩段建表', () => _createContextCompactionSegmentsTable(db));
          _logger.db('DB migrated to v25 (context compaction segments)');
        }
        if (oldVersion < 26) {
          // v1.7.38：搜索来源引用卡片——messages 与 message_versions 各补
          // searchSources 列（JSON 数组字符串 [{title,url}]）
          await _ensureColumn(
              db, 'messages', 'searchSources', "TEXT DEFAULT '[]'");
          await _ensureColumn(
              db, 'message_versions', 'searchSources', "TEXT DEFAULT '[]'");
          _logger.db('DB migrated to v26 (search source citations)');
        }
        if (oldVersion < 27) {
          // v1.7.38 build90（待办⑧⑨）：全局/项目记忆 + 斜杠命令 4 张新表
          // + conversations 补 projectId（所属项目，nullable）
          await _migration('记忆与项目建表', () => _createMemoryTables(db));
          await _ensureColumn(
              db, 'conversations', 'projectId', "TEXT DEFAULT ''");
          _logger.db(
              'DB migrated to v27 (global/project memories + slash commands)');
        }
        if (oldVersion < 28) {
          // build93 (T1)：api_configs 补 supportToolCalls（function calling 能力开关，
          // 默认开；带 tools 请求 400/422 探测失败后自动置 false 并记住）
          await _ensureColumn(
              db, 'api_configs', 'supportToolCalls', 'INTEGER DEFAULT 1');
          _logger.db('DB migrated to v28 (per-config tool calls support toggle)');
        }
        if (oldVersion < 29) {
          // build94 (D3)：conversations 补 longTermMemoryEnabled——长期记忆
          // （全局/项目记忆注入）独立开关，与 memoryEnabled（跨对话摘要）拆分
          await _ensureColumn(
              db, 'conversations', 'longTermMemoryEnabled', 'INTEGER DEFAULT 1');
          _logger.db('DB migrated to v29 (long-term memory toggle split)');
        }
        if (oldVersion < 30) {
          // build98：web_search_configs 补 tavilyAutoMaxResults——结果数「自动」档
          // 开关：true 时执行侧忽略 tavilyMaxResults，由 AI 自行决定条数
          await _ensureColumn(db, 'web_search_configs', 'tavilyAutoMaxResults',
              'INTEGER DEFAULT 0');
          _logger.db('DB migrated to v30 (tavily auto max-results tier)');
        }
        if (oldVersion < 31) {
          // build101（B5 会话归档 / B4 消息引用）：conversations 补两列
          //   isArchived       —— 归档标记，归档会话不在主列表显示
          //   starredMessageIds—— 本会话被**收藏（星标）**的消息 id（JSON 数组字符串）
          //   build133（⑦）：注释原写"被引用/置顶"属误导——实现与 UI 都是星标收藏，
          //   "引用"（把原消息插进输入框）从来不存在。
          // 另建 messages 全文搜索索引（B2 全局会话搜索加速）
          await _ensureColumn(
              db, 'conversations', 'isArchived', 'INTEGER DEFAULT 0');
          await _ensureColumn(
              db, 'conversations', 'starredMessageIds', "TEXT DEFAULT ''");
          await _migration('检索索引', () => _createSearchIndexes(db));
          _logger.db(
              'DB migrated to v31 (conversation archive + starred messages + search index)');
        }
        if (oldVersion < 32) {
          // build101（C1 知识库 RAG）：两张新表
          //   knowledge_bases  —— 知识库元信息（名称/描述/embedding 配置/分片参数）
          //   knowledge_chunks —— 切片 + 向量（embedding 存 JSON 数组字符串）
          // 向量用 JSON TEXT 存而非 sqlite-vec：不引原生扩展，兼容性优先；
          // 检索在 Dart 侧算余弦相似度，万级切片实测够用。
          await _migration('知识库建表', () => _createKnowledgeTables(db));
          _logger.db('DB migrated to v32 (knowledge base RAG)');
        }
        if (oldVersion < 33) {
          // build101（C1 知识库 RAG）：conversations 补 knowledgeBaseId
          // （绑定知识库 → 该会话回答时自动检索引用）
          await _ensureColumn(
              db, 'conversations', 'knowledgeBaseId', "TEXT DEFAULT ''");
          _logger.db('DB migrated to v33 (per-conversation knowledge base)');
        }
        if (oldVersion < 34) {
          // build101（E8 自定义助手）：assistants 表 + conversations.assistantId
          await _migration('助手建表', () => _createAssistantTable(db));
          await _ensureColumn(
              db, 'conversations', 'assistantId', "TEXT DEFAULT ''");
          _logger.db('DB migrated to v34 (custom assistants)');
        }
        if (oldVersion < 35) {
          // build102（E）：knowledge_bases 补 isPublic ——「全局可用」开关，
          // 开启后所有会话自动检索注入该库（不要求逐会话绑定）
          await _ensureColumn(
              db, 'knowledge_bases', 'isPublic', 'INTEGER DEFAULT 0');
          _logger.db('DB migrated to v35 (knowledge base isPublic)');
        }
        if (oldVersion < 36) {
          // build122（图片/视频生成）：
          // ① api_configs 补两个**生成类**能力位（与 supportVision 的「输入」轴分开）；
          // ② 新建 video_tasks —— 视频是异步任务制（1~5 分钟出结果、上游 URL 仅 24h），
          //    任务必须落库才能在切后台/杀进程后继续查（否则钱花了拿不到成品）。
          await _ensureColumn(
              db, 'api_configs', 'supportImageGen', 'INTEGER DEFAULT 0');
          await _ensureColumn(
              db, 'api_configs', 'supportVideoGen', 'INTEGER DEFAULT 0');
          // ③ messages 补 generatedFiles —— AI 生成产物（图片/视频）的本地路径。
          //    刻意**不**复用 attachments：后者会被 _buildMessagesPayload 当多模态
          //    输入回灌（见 chat_message.dart 该字段注释）。
          await _ensureColumn(
              db, 'messages', 'generatedFiles', "TEXT DEFAULT '[]'");
          await _migration('视频任务建表', () => _createVideoTasksTable(db));
          _logger.db(
              'DB migrated to v36 (gen capability bits + generatedFiles + video_tasks)');
        }
        if (oldVersion < 37) {
          // build125：api_configs 补 imageModel —— 文生图**专用**模型名。
          // 真机日志（nexus_export_2026-09-17T22-09）实锤：拿对话模型 grok-4.6
          // 打 /v1/images/generations 稳定 400（同一 key 的 chat 端点是 200），
          // 此前无处可填生图模型（modelOverride 参数无调用方），只能硬改对话模型。
          await _ensureColumn(
              db, 'api_configs', 'imageModel', "TEXT DEFAULT ''");
          _logger.db('DB migrated to v37 (api_configs.imageModel)');
        }
        if (oldVersion < 38) {
          // build129：api_configs 补 videoModel —— 文生视频**专用**模型名。
          // 与 imageModel 是同一个坑的两半，build125 只补了图片那一半。真机日志
          // （nexus_export_2026-09-19T10-05）实锤：拿对话模型 grok-4.6 打 /v1/videos
          // 稳定 400，上游原文 `... Use grok-imagine-video.`；而同一 key 把生图模型
          // 填成 grok-imagine-image-2.0 后立刻 200 出图 —— 视频缺的就是这同一个入口。
          await _ensureColumn(
              db, 'api_configs', 'videoModel', "TEXT DEFAULT ''");
          _logger.db('DB migrated to v38 (api_configs.videoModel)');
        }
        if (oldVersion < 39) {
          // build138（G44/G45，任务书 §三）：加**账号层**。
          // 只建表 + 补一列 + 回填 accountId，**不动 conversations / messages**：
          // 会话继续引用模型条目（config.id），所以历史对话不会因为归组而悬空。
          await _migration('v39 账号层', () => _migrateV39ApiAccounts(db));
          _logger.db('DB migrated to v39 (api_accounts + api_configs.accountId)');
        }
      },
    );
    // 启动时 PRAGMA 自检：对 conversations / messages / web_search_configs / api_configs / plugins
    // 查 PRAGMA table_info 补缺失列 → 防御"CREATE TABLE 漏列 + onUpgrade 走不到"双向漏写问题
    // （踩坑 #43：新用户重装 onCreate schema 漏 contextAuto/autoCompress 导致 INSERT 失败）
    // v1.7.1 fix m6: 补充 plugins 表自检
    final db = _db!;
    await _ensureColumn(
        db, 'conversations', 'contextAuto', 'INTEGER DEFAULT 1');
    await _ensureColumn(
        db, 'conversations', 'autoCompress', 'INTEGER DEFAULT 0');
    await _ensureColumn(db, 'messages', 'attachments', "TEXT DEFAULT '[]'");
    await _ensureColumn(db, 'api_configs', 'cachedModels', "TEXT DEFAULT ''");
    // build122：生成类能力位 + 生成产物路径列（onCreate 漏列 / onUpgrade 走不到 双向兜底）
    await _ensureColumn(
        db, 'api_configs', 'supportImageGen', 'INTEGER DEFAULT 0');
    await _ensureColumn(
        db, 'api_configs', 'supportVideoGen', 'INTEGER DEFAULT 0');
    await _ensureColumn(db, 'messages', 'generatedFiles', "TEXT DEFAULT '[]'");
    // build125：文生图专用模型列（onCreate 漏列 / onUpgrade 走不到 双向兜底）
    await _ensureColumn(db, 'api_configs', 'imageModel', "TEXT DEFAULT ''");
    // build129：文生视频专用模型列（同上，与 imageModel 成对出现）
    await _ensureColumn(db, 'api_configs', 'videoModel', "TEXT DEFAULT ''");
    // build138（G44）：账号层三路同步的第三路。
    // 为什么三路都要：本项目反复出现「onUpgrade 走不到」（version 已被人手工
    // 抬高 / 崩溃在迁移中途 / 从别的设备拷库文件），此时若无启动自检，
    // saveApiConfig 会因缺列整条 INSERT 静默失败 —— 用户表现为「保存了但没保存」。
    await _createApiAccountsTable(db);
    await _ensureColumn(db, 'api_configs', 'accountId', "TEXT DEFAULT ''");
    // 归组回填的幂等兜底：已在 onUpgrade 里做过一遍，这里只处理
    // 「有条目没有 accountId」的残留（老 onUpgrade 没跑到、或备份直接插条目）。
    // 绝大多数启动是一条 LIMIT 1 查询就返回，不产生额外开销。
    await _backfillAccountIds(db);
    // build122：video_tasks 兜底（老库升级 + 新装都走一遍，幂等）
    await _createVideoTasksTable(db);
    // plugins 表在 v9 新增，确保关键字段存在
    // build138（扫描 P2-5）：删掉 `id TEXT PRIMARY KEY` 这行调用——SQLite 不支持
    // ALTER TABLE 增主键列，_ensureColumn 对已存在的 id 是**无条件空转**，
    // 与 _ensurePluginColumns 里「id 必须在 CREATE TABLE 时定义」的注释互相矛盾，
    // 读代码的人会以为这里补过主键。列的存在性由下面 enabled 与 CREATE TABLE 保证。
    await _ensureColumn(db, 'plugins', 'enabled', 'INTEGER DEFAULT 1');
    // v1.7.9 (C1 修复)：web_search_configs 补 v10 安全审查 5 列
    // （此前 version 停在 9 → v10 迁移从未触发，新装/老用户都缺列 → 保存报
    //  "no column named skillspectorEndpoint" 静默失败；此处 ensureColumn 兜底）
    await _ensureColumn(
        db, 'web_search_configs', 'skillspectorEndpoint', "TEXT DEFAULT ''");
    await _ensureColumn(db, 'web_search_configs', 'enableSkillSecurityScan',
        'INTEGER DEFAULT 0');
    await _ensureColumn(
        db, 'web_search_configs', 'enableMcpSecurityScan', 'INTEGER DEFAULT 0');
    await _ensureColumn(
        db, 'web_search_configs', 'mobsfEndpoint', "TEXT DEFAULT ''");
    await _ensureColumn(
        db, 'web_search_configs', 'enableApkSecurityScan', 'INTEGER DEFAULT 0');
    // v1.7.10：本地安全扫描 2 列
    await _ensureColumn(
        db, 'web_search_configs', 'enableLocalScan', 'INTEGER DEFAULT 1');
    await _ensureColumn(
        db, 'web_search_configs', 'localScanRulesUrl', "TEXT DEFAULT ''");
    // v1.7.11：VirusTotal + MobSF API Key
    await _ensureColumn(
        db, 'web_search_configs', 'virusTotalApiKey', "TEXT DEFAULT ''");
    await _ensureColumn(
        db, 'web_search_configs', 'enableVirusTotalScan', 'INTEGER DEFAULT 0');
    await _ensureColumn(
        db, 'web_search_configs', 'mobsfApiKey', "TEXT DEFAULT ''");
    await _ensureColumn(db, 'messages', 'modelName', "TEXT DEFAULT ''");
    await _ensureColumn(db, 'conversations', 'isPinned', 'INTEGER DEFAULT 0');
    // v1.7.25：per-conversation 思考字段（reasoningEffort/reactAutoMode/reactMaxRounds）
    await _ensureColumn(
        db, 'conversations', 'reactEnabled', 'INTEGER DEFAULT 1');
    await _ensureColumn(
        db, 'conversations', 'reasoningEffort', 'INTEGER DEFAULT 0');
    await _ensureColumn(
        db, 'conversations', 'reactAutoMode', 'INTEGER DEFAULT 1');
    await _ensureColumn(
        db, 'conversations', 'reactMaxRounds', 'INTEGER DEFAULT 30');
    await _ensureColumn(
        db, 'api_configs', 'templateId', "TEXT DEFAULT 'custom'");
    // v1.7.33：api_configs 补 supportVision（视觉支持开关；关闭时图片附件走本机 OCR 降级）
    await _ensureColumn(
        db, 'api_configs', 'supportVision', 'INTEGER DEFAULT 0');
    // build93 (T1)：启动兜底 supportToolCalls（默认开）
    await _ensureColumn(
        db, 'api_configs', 'supportToolCalls', 'INTEGER DEFAULT 1');
    // v1.7.34：conversations 补跨对话记忆 + 深度研究 + 子代理编排字段（双保险：onUpgrade + 启动自检）
    await _ensureColumn(db, 'conversations', 'summary', "TEXT DEFAULT ''");
    await _ensureColumn(
        db, 'conversations', 'memoryEnabled', 'INTEGER DEFAULT 1');
    // build94 (D3)：长期记忆独立开关（启动兜底）
    await _ensureColumn(
        db, 'conversations', 'longTermMemoryEnabled', 'INTEGER DEFAULT 1');
    await _ensureColumn(
        db, 'conversations', 'deepResearchMode', 'INTEGER DEFAULT 0');
    await _ensureColumn(
        db, 'conversations', 'subagentMode', "TEXT DEFAULT 'auto'");
    await _ensureColumn(db, 'messages', 'retryOf', "TEXT DEFAULT ''");
    await _ensureColumn(db, 'messages', 'retryIndex', 'INTEGER DEFAULT 0');
    await _ensureColumn(db, 'messages', 'reasoningSteps', "TEXT DEFAULT '[]'");
    await _ensureColumn(
        db, 'web_search_configs', 'biometricLockEnabled', 'INTEGER DEFAULT 0');
    // build98：启动兜底 tavilyAutoMaxResults（结果数「自动」档）
    await _ensureColumn(db, 'web_search_configs', 'tavilyAutoMaxResults',
        'INTEGER DEFAULT 0');
    // v1.7.26 (C2)：启动自检补 messages token 用量 3 列（双保险：onCreate schema + onUpgrade 链路）
    await _ensureColumn(db, 'messages', 'promptTokens', 'INTEGER');
    await _ensureColumn(db, 'messages', 'completionTokens', 'INTEGER');
    await _ensureColumn(db, 'messages', 'totalTokens', 'INTEGER');
    await _ensureColumn(db, 'messages', 'cacheReadTokens', 'INTEGER');
    await _ensureColumn(db, 'messages', 'cacheWriteTokens', 'INTEGER');
    await _ensureColumn(db, 'messages', 'cacheHitTokens', 'INTEGER');
    await _ensureColumn(db, 'messages', 'cacheMissTokens', 'INTEGER');
    await _ensureColumn(db, 'api_configs', 'contextWindowTokens', 'INTEGER');
    await _ensureColumn(
        db, 'conversations', 'largeContextMax', 'INTEGER DEFAULT 0');
    await _ensureColumn(db, 'message_versions', 'cacheReadTokens', 'INTEGER');
    await _ensureColumn(db, 'message_versions', 'cacheWriteTokens', 'INTEGER');
    await _ensureColumn(db, 'message_versions', 'cacheHitTokens', 'INTEGER');
    await _ensureColumn(db, 'message_versions', 'cacheMissTokens', 'INTEGER');
    // v1.7.38：启动自检补搜索来源引用列（双保险：onCreate schema + onUpgrade 链路）
    await _ensureColumn(db, 'messages', 'searchSources', "TEXT DEFAULT '[]'");
    await _ensureColumn(
        db, 'message_versions', 'searchSources', "TEXT DEFAULT '[]'");
    // v1.7.26 (E3)：启动自检补 message_versions 表（幂等，防 onCreate/onUpgrade 漏建）
    await db.execute('''
      CREATE TABLE IF NOT EXISTS message_versions (
        retryOfId TEXT NOT NULL,
        versionIndex INTEGER NOT NULL,
        content TEXT NOT NULL,
        reasoningSteps TEXT DEFAULT '[]',
        promptTokens INTEGER,
        completionTokens INTEGER,
        totalTokens INTEGER,
        cacheReadTokens INTEGER,
        cacheWriteTokens INTEGER,
        cacheHitTokens INTEGER,
        cacheMissTokens INTEGER,
        injectedWebSearchCount INTEGER DEFAULT 0,
        showStaleFootnote INTEGER DEFAULT 0,
        modelName TEXT DEFAULT '',
        searchSources TEXT DEFAULT '[]',
        savedAt TEXT NOT NULL,
        PRIMARY KEY (retryOfId, versionIndex)
      )
    ''');
    // v1.7.35：启动兜底创建上下文压缩片段表及索引
    await _createContextCompactionSegmentsTable(db);
    // v1.7.38 build90（⑧⑨）：启动兜底创建记忆/命令 4 表 + conversations.projectId
    await _createMemoryTables(db);
    await _ensureColumn(db, 'conversations', 'projectId', "TEXT DEFAULT ''");
    // build101（B2/B5）：启动兜底补归档列 + 搜索索引（与 onUpgrade 链路互为双保险）
    await _ensureColumn(
        db, 'conversations', 'isArchived', 'INTEGER DEFAULT 0');
    await _ensureColumn(
        db, 'conversations', 'starredMessageIds', "TEXT DEFAULT ''");
    await _createSearchIndexes(db);
    // build101（C1）：启动兜底创建知识库 2 表（与 onCreate/onUpgrade 三路同步）
    await _createKnowledgeTables(db);
    await _ensureColumn(
        db, 'conversations', 'knowledgeBaseId', "TEXT DEFAULT ''");
    // build102（E）：isPublic 启动兜底（防 onUpgrade 链路漏写）
    await _ensureColumn(db, 'knowledge_bases', 'isPublic', 'INTEGER DEFAULT 0');
    await _createAssistantTable(db);
    await _ensureColumn(db, 'conversations', 'assistantId', "TEXT DEFAULT ''");
    _initialized = true;
    // build146（密钥入 Keystore）：存量明文 Key 搬家 + 孤儿条目清扫。
    // 两个函数**自己吞掉所有异常**（只记 WARN），所以放在 _initialized 之后也不会
    // 让启动卡住或失败 —— 搬家失败的后果是那一行继续留明文（可用），
    // 绝不是「Key 没了」。
    await _migratePlaintextSecrets(db);
    await sweepOrphanSecrets(db);
    // build138（扫描 P2-6）：这里从 build1xx 起一直硬写 `(v35)`，而 openDatabase
    // 早已是 version: 38 —— 真机日志里的 DB 版本号是假的，排查迁移问题时直接误导。
    // 改为向数据库要**真实** user_version，之后再 bump 也不会说谎。
    final actualVersion = await db.getVersion();
    _logger.db('DB initialized at $path (v$actualVersion)');
  }

  /// 密钥列的落库位置清单（**表名/列名的唯一来源**，迁移与清扫都从它派生）。
  ///
  /// 列名来自模型侧的同一套常量（[WebSearchConfig.secretColumns]），
  /// 这里只是把它们对回「哪张表」。表名/列名全部是本文件里的字面量常量，
  /// **不来自任何用户输入**，因此下面拼进 SQL 的标识符不构成注入面。
  static const List<({String table, String scope, List<String> columns})>
      _secretColumnSpecs = [
    (
      table: 'api_configs',
      scope: SecretStore.apiConfigScope,
      columns: ['apiKey'],
    ),
    (
      table: 'api_accounts',
      scope: SecretStore.apiAccountScope,
      columns: ['apiKey'],
    ),
    (
      table: 'web_search_configs',
      scope: SecretStore.webSearchScope,
      columns: WebSearchConfig.secretColumns,
    ),
  ];

  /// 某表某行的密钥坐标。
  static SecretLocation _secretLocation(
          ({String table, String scope, List<String> columns}) spec,
          String rowId,
          String column) =>
      SecretLocation(
        scope: spec.scope,
        rowId: rowId,
        table: spec.table,
        column: column,
      );

  /// 全部「表 × 行 × 密钥列」坐标 + 列里现存的值 + 保险库里现存的值。
  ///
  /// 单独成函数是为了让 [_migratePlaintextSecrets] 只剩「决策 + 执行」两步，
  /// 也让备份导入能复用同一份坐标派生（不许出现第二套键名拼法）。
  Future<({List<SecretLocation> locations, Map<String, String> inColumn, Map<String, String> inVault})>
      _readSecretFacts(Database database) async {
    final locations = <SecretLocation>[];
    final inColumn = <String, String>{};
    final inVault = <String, String>{};
    for (final spec in _secretColumnSpecs) {
      final rows = await database.query(spec.table,
          columns: ['id', ...spec.columns]);
      for (final row in rows) {
        final rawId = row['id'];
        final rowId = (rawId is String && rawId.isNotEmpty)
            ? rawId
            : SecretStore.webSearchRowId;
        for (final col in spec.columns) {
          final loc = _secretLocation(spec, rowId, col);
          if (inColumn.containsKey(loc.fieldKey)) continue;
          // 保险库里现存的值。build147 第 11 轮（P2）：读不出来时**这一条本轮不搬**，
          // 而不是拿空串进计划器 —— 空串在计划器里等于"保险库里没有"，
          // 于是"读抛 + 列里有明文"会被判成"该覆盖过去"：万一保险库里那把才是新的
          // （上一次写验不过、后来别的路径写成功了），这一搬就把用户后写的 Key 反推没了。
          // 跳过 = 列里明文照旧可用，下次开机再搬，两把都不动。
          final got = await _secrets.readOutcome(loc);
          if (got.isUnknown) {
            _logger.dbWarn('[DB] 密钥现状读不到，本轮迁移跳过这一条（下次开机再试）：'
                '${loc.table}#${loc.rowId}.${loc.column}');
            continue;
          }
          locations.add(loc);
          inColumn[loc.fieldKey] = (row[col] as String?) ?? '';
          inVault[loc.fieldKey] = got.value;
        }
      }
    }
    return (
      locations: locations,
      inColumn: inColumn,
      inVault: inVault,
    );
  }

  /// build146：把**存量**明文密钥搬进保险库。复制 → 读回校验 → 才清列。
  ///
  /// 四条不变量（全部由 [planSecretMigration] / [runSecretMigration] 两个纯函数
  /// 保证，本函数只负责把它们接到真库上）：
  /// ① **幂等**：计划只对「列里非空」的行出活 ⇒ 跑成功后列全空，第二次是空计划；
  ///    中途崩在「已复制、未清列」之间，第二次命中 `vaultAlreadyMatched` 只补清列。
  /// ② **永不丢失**：清列 UPDATE 只在该行读回逐字校验通过之后才发（执行器写死），
  ///    任何一步不过 ⇒ 该行原样留明文，读路径优先信列里的非空值 ⇒ 功能不受损。
  /// ③ **不阻塞启动**：整段 try/catch，失败只记一条 WARN。
  /// ④ **不动 schema**：列还在、类型不变、DB 版本号仍是 39 —— 降级装回旧版本时
  ///    读到的只是「apiKey 为空的配置」（可重新填），而不是打不开的库。
  Future<void> _migratePlaintextSecrets(Database database) async {
    try {
      final facts = await _readSecretFacts(database);
      final plan = planSecretMigration(
        locations: facts.locations,
        columnValueOf: (loc) => facts.inColumn[loc.fieldKey],
        vaultValueOf: (loc) => facts.inVault[loc.fieldKey],
      );
      if (plan.isEmpty) return;
      final report = await runSecretMigration(
        ops: plan,
        copyToVault: (op) async =>
            (await _secrets.writeVerified(op.location, op.plaintext)) ==
            SecretWriteResult.stored,
        readBackFromVault: (op) => _secrets.read(op.location),
        clearColumn: (op) async {
          final loc = op.location;
          await database.rawUpdate(
            'UPDATE ${loc.table} SET ${loc.column} = ? WHERE id = ?',
            <Object?>['', loc.rowId],
          );
        },
        onFailure: (op, e) => _logger.dbWarn(
            '[DB] 密钥迁移未完成，该行继续以明文存储（可用，未加密）：'
            '${op.location.table}#${op.location.rowId}.${op.location.column}: $e'),
      );
      _logger.db('密钥入 Keystore 迁移完成：$report');
    } catch (e, st) {
      _logger.dbWarn('[DB] 密钥迁移整体失败（保持原状，不阻塞启动）: $e\n$st');
    }
  }

  /// 清掉「行已经没了、保险库里还留着 Key」的孤儿条目（本仓库的孤儿残留病族）。
  ///
  /// 为什么需要它而不只在删除路径里顺手清：删 api_configs / api_accounts 行的
  /// 出口不止本类 —— 备份覆盖导入在事务里手写整表删除，WebDAV 恢复也直接
  /// 逐表清（那个文件不在本批可改范围）。所以本批的口径是
  /// 「显式删除路径各自登记 + 这里做最后一道全表对账」。
  ///
  /// 安全阀（宁可留残留，绝不误删好 Key）：
  /// · 只处理 `v1.` 前缀的键（github_device_flow 的令牌永远不碰）；
  /// · 列举失败 ⇒ 直接返回（「未知」不等于「都是孤儿」）；
  /// · 逐条**重新读回有值**才删（见 [SecretStore.deleteKeys]）—— 快照与现状不一致
  ///   时（Keystore 半死、并发写入）该条跳过。
  Future<void> sweepOrphanSecrets(Database database) async {
    try {
      final live = <String>{};
      for (final spec in _secretColumnSpecs) {
        final rows = await database.query(spec.table, columns: ['id']);
        for (final row in rows) {
          final rawId = row['id'];
          final rowId = (rawId is String && rawId.isNotEmpty)
              ? rawId
              : SecretStore.webSearchRowId;
          for (final col in spec.columns) {
            live.add('${spec.scope}.$rowId.$col');
          }
        }
      }
      final candidates = await _secrets.findOrphanKeys(isOrphan: (key) {
        final parsed = SecretStore.parseKey(key);
        if (parsed == null) return false;
        return !live.contains('${parsed.scope}.${parsed.rowId}.${parsed.field}');
      });
      if (candidates.isEmpty) return;
      // build147 第 11 轮（P1）：**逐条再查一次行在不在**才下刀。
      // 上面那份 `live` 是函数开头的快照，而 `findOrphanKeys` 要走一次昂贵的
      // `readAll`；这个窗口里用户保存/新建一条连接（`init` 之后 UI 就能写），
      // 新键不在旧快照里 ⇒ 被判孤儿，而"读得回值"那道阀只会**确认**它是刚写的真 Key
      // ⇒ 删掉 ⇒ 行在、Key 没了（"配置还在、突然 401"，与本函数注释的承诺正好相反）。
      // 值只能证明"这条键有内容"，证明不了"这行不存在"—— 必须回库问一次。
      final stillOrphan = <String>[];
      var revived = 0;
      for (final key in candidates) {
        final parsed = SecretStore.parseKey(key);
        if (parsed == null) continue;
        final spec = _secretColumnSpecs
            .where((s) => s.scope == parsed.scope)
            .firstOrNull;
        if (spec == null || !spec.columns.contains(parsed.field)) continue;
        final rows = await database.query(spec.table,
            columns: ['id'], where: 'id = ?', whereArgs: [parsed.rowId], limit: 1);
        if (rows.isNotEmpty) {
          revived++;
          continue;
        }
        stillOrphan.add(key);
      }
      if (revived > 0) {
        _logger.dbWarn('[DB] 清扫候选里有 $revived 条的对应行已存在（快照之后新建/导入），'
            '跳过这些条');
      }
      if (stillOrphan.isEmpty) return;
      final removed = await _secrets.deleteKeys(stillOrphan);
      _logger.dbWarn(
          '[DB] 清掉 $removed 条无主密钥条目（对应行已不存在，共候选 ${stillOrphan.length}）');
    } catch (e) {
      _logger.dbWarn('[DB] 密钥孤儿清扫跳过（不删除任何东西）: $e');
    }
  }

  /// build146：备份导入专用的落库行。与 [_rowOfSecrets] 只差**一条**语义，
  /// 而那条语义正是本批的第一优先级（绝不让能用的 Key 变空）：
  ///
  /// · 这里**只写不删**。[_rowOfSecrets] 把「值为空」读成「用户清掉了这把 Key」
  ///   并顺手删除条目 —— 在保存路径上是对的，在导入路径上是错的：
  ///   `includeKeys=false` 的备份里根本没有 Key，照那个语义走一遍就把本机已有的
  ///   Key 全清了（v1.4.3 Bug#5 / build138 P1-1 为 webSearch 的 pickKey 修过的
  ///   正是同一类缺陷）。而且导入整段是**可回滚的事务**：事务里删掉的保险库条目
  ///   回滚不回来，症状是「导入失败之后所有 Key 都没了」。
  /// · 所以：文件里有非空值 ⇒ 种进保险库；文件里没值 ⇒ 本机那一行现状一律不碰。
  ///   种失败（Keystore 不可用）⇒ 整行退回带明文的 toMap()，宁可明文也别丢 Key。
  ///
  /// 回滚时留下的无主条目由下次启动的 [sweepOrphanSecrets] 收掉。
  Future<Map<String, dynamic>> rowForImportedSecrets(SecretBearing item) async {
    var allStored = true;
    for (final loc in item.secretLocations()) {
      final value = item.secretValueAt(loc).trim();
      if (value.isEmpty) continue;
      final r = await _secrets.writeVerified(loc, value);
      if (r != SecretWriteResult.stored) allStored = false;
    }
    if (allStored) return item.toRowMap();
    _logger.dbWarn('[Backup] 有密钥未能写入保险库，该行按明文原样落库（可用，未加密）');
    return item.toMap();
  }

  /// build101（E8 自定义助手）：assistants 表（幂等）
  ///
  /// 与 ApiConfig.systemPrompt 的区别：助手是可跨连接复用的角色实体，
  /// 一个 API 配置能配多个助手；会话通过 conversations.assistantId 绑定。
  /// build122：视频生成任务表。
  ///
  /// 为什么单独建表而不是塞进 messages：视频任务是**跨会话的异步作业**
  /// （提交后 1~5 分钟出结果，用户可能已经切走/杀掉进程），它的生命周期与
  /// 消息解耦；且需要按状态续查（state 索引）。
  Future<void> _createVideoTasksTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS video_tasks (
        id TEXT PRIMARY KEY,
        apiConfigId TEXT DEFAULT '',
        remoteTaskId TEXT DEFAULT '',
        prompt TEXT DEFAULT '',
        model TEXT DEFAULT '',
        seconds INTEGER DEFAULT 5,
        size TEXT DEFAULT '1280x720',
        mode TEXT DEFAULT 'std',
        state TEXT DEFAULT 'queued',
        resultUrl TEXT DEFAULT '',
        localPath TEXT DEFAULT '',
        errorMessage TEXT DEFAULT '',
        createdAt TEXT DEFAULT '',
        updatedAt TEXT DEFAULT ''
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_video_tasks_state
      ON video_tasks (state, createdAt)
    ''');
  }

  Future<void> _createAssistantTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS assistants (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        emoji TEXT DEFAULT '🤖',
        systemPrompt TEXT DEFAULT '',
        greeting TEXT DEFAULT '',
        isBuiltin INTEGER DEFAULT 0,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL
      )
    ''');
  }

  /// build101（C1 知识库 RAG）：知识库 2 表 + 索引（幂等）  ///
  /// **为什么向量不用 sqlite-vec**：需要原生扩展，三端（Android/iOS/桌面）
  /// 打包成本高、升级易踩坑。这里把 embedding 以 JSON 数组字符串存 TEXT，
  /// 检索时在 Dart 侧算余弦相似度。1 万条 1536 维切片 ≈ 15MB JSON，
  /// 移动端全量加载 + 打分 < 200ms，按会话检索规模完全够用。
  Future<void> _createKnowledgeTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS knowledge_bases (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        description TEXT DEFAULT '',
        embeddingConfigId TEXT DEFAULT '',
        embeddingModel TEXT DEFAULT '',
        chunkSize INTEGER DEFAULT 800,
        chunkOverlap INTEGER DEFAULT 120,
        topK INTEGER DEFAULT 5,
        isPublic INTEGER DEFAULT 0,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS knowledge_chunks (
        id TEXT PRIMARY KEY,
        kbId TEXT NOT NULL,
        docName TEXT DEFAULT '',
        chunkIndex INTEGER DEFAULT 0,
        content TEXT NOT NULL,
        embedding TEXT DEFAULT '[]',
        dim INTEGER DEFAULT 0,
        createdAt INTEGER NOT NULL
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_kbchunks_kbId ON knowledge_chunks (kbId)');
  }

  /// build101（B2 全局会话搜索 / B5 归档）：搜索相关索引（幂等）
  ///
  /// - `idx_messages_conversationId`：按会话取消息（列表预览、导出、搜索定位）
  /// - `idx_messages_content`：按内容关键字 LIKE 扫描加速
  /// - `idx_conversations_isArchived`：主列表过滤归档会话
  ///
  /// 注：SQLite 的 `LIKE '%kw%'` **无法**走普通 B-Tree 索引，
  /// 这里建索引主要加速「按会话取全部消息」与「归档过滤」这两条高频查询；
  /// 全文检索用 LIKE 在移动端万级消息量下实测够用（不引入 FTS5 以免踩迁移坑）。
  Future<void> _createSearchIndexes(Database db) async {
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_messages_conversationId ON messages (conversationId)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_messages_content ON messages (content)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_conversations_isArchived ON conversations (isArchived)');
  }

  /// v1.7.38 build90（待办⑧⑨）：全局/项目记忆 + 斜杠命令 4 张表（幂等）
  Future<void> _createMemoryTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS global_memories (
        id TEXT PRIMARY KEY,
        content TEXT NOT NULL,
        source TEXT DEFAULT 'manual',
        pinned INTEGER DEFAULT 0,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS projects (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        createdAt INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS project_memories (
        id TEXT PRIMARY KEY,
        projectId TEXT NOT NULL,
        content TEXT NOT NULL,
        source TEXT DEFAULT 'manual',
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS slash_commands (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        promptTemplate TEXT NOT NULL,
        scope TEXT DEFAULT 'global',
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL
      )
    ''');
  }

  /// 单条迁移步骤的守卫（build152 数据层扫描 D3）。
  ///
  /// 为什么必须包这一层：`onUpgrade` 里任何一条 DDL 抛错都会**穿透 `openDatabase`**，
  /// 于是 `user_version` 没 bump、下次启动重跑同一条语句 ⇒ 数据还在库里，但用户
  /// 永远打不开、连导出都做不到。触发条件很日常：磁盘满、存储只读、进程被杀在迁移中途。
  /// 而 `init()` 末尾那段启动自检（62 个 `_ensureColumn` + 建表兜底）本来就是为
  /// 「CREATE TABLE 漏列 + onUpgrade 走不到」这种双向漏写准备的第四保险 ——
  /// 它跑在 `openDatabase` **之后**，所以只有先让库开得了门，那道保险才有机会生效。
  /// 因此这里跳过并留 WARN，而不是让整库砖掉；缺表/缺列的真实后果会由后续那条
  /// INSERT 失败的 dbWarn 自己暴露出来（静默 = 不可排查，但"打不开"比"少一列"严重一级）。
  Future<void> _migration(String label, Future<void> Function() step) async {
    try {
      await step();
    } catch (e) {
      _logger.dbWarn('迁移步骤失败，已跳过（启动自检会补列）：$label → $e');
    }
  }

  /// PRAGMA 自检并补齐缺失列（SQLite 安全 ADD COLUMN）。
  /// 解决 onCreate / onUpgrade 任一链路漏写列时的 INSERT 崩溃。
  Future<void> _ensureColumn(
      Database db, String table, String column, String definition) async {
    try {
      final rows = await db.rawQuery('PRAGMA table_info($table)');
      final names = rows.map((r) => r['name'] as String).toSet();
      if (!names.contains(column)) {
        await db.execute('ALTER TABLE $table ADD COLUMN $column $definition');
        _logger.db('ALTER TABLE $table ADD $column $definition');
      }
    } catch (e) {
      _logger.dbWarn('ensureColumn $table.$column failed: $e');
    }
  }

  Future<void> _createV1Tables(Database db) async {
    await db.execute('''
      CREATE TABLE api_configs (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        baseUrl TEXT NOT NULL,
        apiKey TEXT NOT NULL,
        model TEXT NOT NULL,
        imageModel TEXT DEFAULT '',
        videoModel TEXT DEFAULT '',
        systemPrompt TEXT DEFAULT '',
        temperature REAL DEFAULT 0.7,
        topP REAL DEFAULT 1.0,
        maxTokens INTEGER DEFAULT 2048,
        contextWindowTokens INTEGER,
        templateId TEXT DEFAULT 'custom',
        -- build138（G44）：账号层外键（不加 FOREIGN KEY 约束：老库无法 ALTER 加约束，
        -- 且删账号的级联由 deleteApiAccount 显式做，与 conversations.apiConfigId
        -- 的既有处理方式一致 —— 那里建了 FK 但 sqflite 默认不开
        -- PRAGMA foreign_keys，形同注释，实际全靠手动 delete）。
        accountId TEXT DEFAULT '',
        cachedModels TEXT DEFAULT '',
        supportVision INTEGER DEFAULT 0,
        supportToolCalls INTEGER DEFAULT 1,
        supportImageGen INTEGER DEFAULT 0,
        supportVideoGen INTEGER DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE conversations (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        apiConfigId TEXT NOT NULL,
        lastMessage TEXT,
        contextLimit INTEGER DEFAULT 20,
        temperature REAL DEFAULT 0.7,
        topP REAL DEFAULT 1.0,
        enable20sCheck INTEGER DEFAULT 1,
        contextAuto INTEGER DEFAULT 1,
        autoCompress INTEGER DEFAULT 0,
        largeContextMax INTEGER DEFAULT 0,
        isPinned INTEGER DEFAULT 0,
        projectId TEXT DEFAULT '',
        isArchived INTEGER DEFAULT 0,
        starredMessageIds TEXT DEFAULT '',
        knowledgeBaseId TEXT DEFAULT '',
        assistantId TEXT DEFAULT '',
        -- build133（④）：以下 9 列此前**只靠 _ensureColumn + onUpgrade 补**，
        -- 违反「CREATE TABLE 三路同步」铁律（onCreate 漏列 + onUpgrade 走不到 =
        -- 双向漏写，模型类里有、建表没有 ⇒ 落库时 INSERT 静默失败）。
        -- 当前靠启动自检兜住才没崩，补齐后 onCreate 与另两路一致。
        reactEnabled INTEGER DEFAULT 1,
        reasoningEffort INTEGER DEFAULT 0,
        reactAutoMode INTEGER DEFAULT 1,
        reactMaxRounds INTEGER DEFAULT 30,
        summary TEXT DEFAULT '',
        memoryEnabled INTEGER DEFAULT 1,
        longTermMemoryEnabled INTEGER DEFAULT 1,
        deepResearchMode INTEGER DEFAULT 0,
        subagentMode TEXT DEFAULT 'auto',
        updatedAt TEXT NOT NULL,
        createdAt TEXT NOT NULL,
        FOREIGN KEY (apiConfigId) REFERENCES api_configs (id)
      )
    ''');
    await db.execute('''
      CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        conversationId TEXT NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        createdAt TEXT NOT NULL,
        attachments TEXT DEFAULT '[]',
        generatedFiles TEXT DEFAULT '[]',
        modelName TEXT DEFAULT '',
        retryOf TEXT DEFAULT '',
        retryIndex INTEGER DEFAULT 0,
        reasoningSteps TEXT DEFAULT '[]',
        promptTokens INTEGER,
        completionTokens INTEGER,
        totalTokens INTEGER,
        cacheReadTokens INTEGER,
        cacheWriteTokens INTEGER,
        cacheHitTokens INTEGER,
        cacheMissTokens INTEGER,
        searchSources TEXT DEFAULT '[]',
        FOREIGN KEY (conversationId) REFERENCES conversations (id) ON DELETE CASCADE
      )
    ''');
  }

  /// v1.3.6：为旧库 messages 表补 attachments 列
  /// 不加这列 → 带附件的消息保存时 SQLite 报 "no column named attachments"，
  /// 附件静默丢失（同 v1.3.4 web_search_configs 那次踩的坑）
  Future<void> _migrateV4MessagesAttachments(Database db) async {
    final cols = await db.rawQuery('PRAGMA table_info(messages)');
    final names = cols.map((c) => c['name'] as String).toSet();
    if (!names.contains('attachments')) {
      await db.execute(
          "ALTER TABLE messages ADD COLUMN attachments TEXT DEFAULT '[]'");
      _logger.db('ALTER TABLE messages ADD attachments');
    }
  }

  /// v1.3.9：为旧库 web_search_configs 补 5 个新搜索服务商字段
  /// 不加 → 选 SerpAPI/Brave/Google CSE/DuckDuckGo(无须 key 但 enum 新增) 后
  /// 保存报 "no column named serpApiKey" → 🌐 按钮/设置保存全部静默失败
  /// （铁律 #7：新增字段必须同步 CREATE TABLE + ALTER TABLE + bump version）
  Future<void> _migrateV5WebSearchColumns(Database db) async {
    final rows = await db.rawQuery('PRAGMA table_info(web_search_configs)');
    final existingCols = rows.map((r) => r['name'] as String).toSet();
    const defs = <String, String>{
      'serpApiKey': "TEXT DEFAULT ''",
      'serpapiEngine': "TEXT DEFAULT 'google'",
      'braveApiKey': "TEXT DEFAULT ''",
      'googleCseApiKey': "TEXT DEFAULT ''",
      'googleCseId': "TEXT DEFAULT ''",
    };
    for (final entry in defs.entries) {
      if (!existingCols.contains(entry.key)) {
        await db.execute(
            'ALTER TABLE web_search_configs ADD COLUMN ${entry.key} ${entry.value}');
        _logger.db('ALTER TABLE web_search_configs ADD ${entry.key}');
      }
    }
  }

  Future<void> _createV2Tables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS web_search_configs (
        id TEXT PRIMARY KEY,
        webSearchEnabled INTEGER DEFAULT 1,
        provider TEXT DEFAULT 'bing',
        tavilyApiKey TEXT DEFAULT '',
        tavilySearchDepth TEXT DEFAULT 'basic',
        tavilyMaxResults INTEGER DEFAULT 5,
        tavilyAutoMaxResults INTEGER DEFAULT 0,
        searxngInstanceUrl TEXT DEFAULT '',
        maxSnippetCharsPerResult INTEGER DEFAULT 400,
        maxResultsInject INTEGER DEFAULT 5,
        persistentWebSearchToggle INTEGER DEFAULT 1,
        reactEnabled INTEGER DEFAULT 1,
        reactMaxRounds INTEGER DEFAULT 3,
        reactAutoMode INTEGER DEFAULT 0,
        githubProxyUrl TEXT DEFAULT '',
        verboseLogging INTEGER DEFAULT 0,
        serpApiKey TEXT DEFAULT '',
        serpapiEngine TEXT DEFAULT 'google',
        braveApiKey TEXT DEFAULT '',
        googleCseApiKey TEXT DEFAULT '',
        googleCseId TEXT DEFAULT '',
        skillspectorEndpoint TEXT DEFAULT '',
        enableSkillSecurityScan INTEGER DEFAULT 0,
        enableMcpSecurityScan INTEGER DEFAULT 0,
        mobsfEndpoint TEXT DEFAULT '',
        enableApkSecurityScan INTEGER DEFAULT 0,
        enableLocalScan INTEGER DEFAULT 1,
        localScanRulesUrl TEXT DEFAULT '',
        virusTotalApiKey TEXT DEFAULT '',
        enableVirusTotalScan INTEGER DEFAULT 0,
        mobsfApiKey TEXT DEFAULT '',
        biometricLockEnabled INTEGER DEFAULT 0
      )
    ''');
    final existing = await db
        .query('web_search_configs', where: 'id = ?', whereArgs: ['singleton']);
    if (existing.isEmpty) {
      // build146：这里插的是**全默认**单例行，六个密钥列本来就是空串，
      // 没有可搬的东西 —— 仍走 _rowOfSecrets 而不是 toMap，是为了让「新装库的
      // web_search_configs 行不含任何密钥」这条不变量有唯一一个出口：
      // 将来若给 WebSearchConfig 加了带默认值的密钥字段，这里不会漏。
      final defaults = WebSearchConfig();
      await db.insert('web_search_configs', await _rowOfSecrets(defaults),
          conflictAlgorithm: ConflictAlgorithm.replace);
      _logger.db('Default web_search_config inserted');
    }
    await db.execute('''
      CREATE TABLE IF NOT EXISTS plugins (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        version TEXT NOT NULL,
        source TEXT NOT NULL,
        author TEXT,
        description TEXT,
        enabled INTEGER NOT NULL DEFAULT 1,
        installedAt INTEGER NOT NULL,
        metadataJson TEXT DEFAULT '{}'
      )
    ''');
    // v1.7.26 (E3)：重试版本快照持久化表（onCreate 路径——与 onUpgrade v21、
    // 启动自检三路同步，遵循"CREATE TABLE 三路同步"铁律）
    await db.execute('''
      CREATE TABLE IF NOT EXISTS message_versions (
        retryOfId TEXT NOT NULL,
        versionIndex INTEGER NOT NULL,
        content TEXT NOT NULL,
        reasoningSteps TEXT DEFAULT '[]',
        promptTokens INTEGER,
        completionTokens INTEGER,
        totalTokens INTEGER,
        cacheReadTokens INTEGER,
        cacheWriteTokens INTEGER,
        cacheHitTokens INTEGER,
        cacheMissTokens INTEGER,
        injectedWebSearchCount INTEGER DEFAULT 0,
        showStaleFootnote INTEGER DEFAULT 0,
        modelName TEXT DEFAULT '',
        searchSources TEXT DEFAULT '[]',
        savedAt TEXT NOT NULL,
        PRIMARY KEY (retryOfId, versionIndex)
      )
    ''');
  }

  Future<void> _createContextCompactionSegmentsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS context_compaction_segments (
        id TEXT PRIMARY KEY,
        conversationId TEXT NOT NULL,
        summary TEXT NOT NULL,
        startMessageId TEXT NOT NULL,
        endMessageId TEXT NOT NULL,
        sourceTokenEstimate INTEGER NOT NULL DEFAULT 0,
        createdAt TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_context_compaction_segments_conversation
      ON context_compaction_segments (conversationId, createdAt)
    ''');
  }

  /// v1.3.4：为已有数据库（v2 升级到 v3）补 web_search_configs 表缺失的列
  /// 原始 CREATE TABLE 遗漏了 v1.3.1~v1.3.4 新增的字段，导致保存时 SQLite 报
  /// "table has no column named XXX" → 🌐/🧠 按钮、设置保存、详细日志全部失效
  Future<void> _migrateV3WebSearchColumns(Database db) async {
    final columns = <String>[
      'persistentWebSearchToggle',
      'reactEnabled',
      'reactMaxRounds',
      'reactAutoMode',
      'githubProxyUrl',
      'verboseLogging'
    ];
    // PRAGMA table_info 返回已有列名，避免 ALTER TABLE 添加已存在的列报错
    final rows = await db.rawQuery('PRAGMA table_info(web_search_configs)');
    final existingCols = rows.map((r) => r['name'] as String).toSet();
    final defs = <String, String>{
      'persistentWebSearchToggle': 'INTEGER DEFAULT 1',
      'reactEnabled': 'INTEGER DEFAULT 1',
      'reactMaxRounds': 'INTEGER DEFAULT 3',
      'reactAutoMode': 'INTEGER DEFAULT 0',
      'githubProxyUrl': "TEXT DEFAULT ''",
      'verboseLogging': 'INTEGER DEFAULT 0',
    };
    for (final col in columns) {
      if (!existingCols.contains(col)) {
        await db.execute(
            'ALTER TABLE web_search_configs ADD COLUMN $col ${defs[col]}');
        _logger.db('ALTER TABLE web_search_configs ADD $col (v3 migration)');
      }
    }
  }

  Future<void> _migrateV6ConversationSettings(Database db) async {
    final apiRows = await db.rawQuery('PRAGMA table_info(api_configs)');
    final apiCols = apiRows.map((r) => r['name'] as String).toSet();
    if (!apiCols.contains('topP')) {
      await db
          .execute('ALTER TABLE api_configs ADD COLUMN topP REAL DEFAULT 1.0');
    }

    final conversationRows =
        await db.rawQuery('PRAGMA table_info(conversations)');
    final conversationCols =
        conversationRows.map((r) => r['name'] as String).toSet();
    const defs = <String, String>{
      'contextLimit': 'INTEGER DEFAULT 20',
      'temperature': 'REAL DEFAULT 0.7',
      'topP': 'REAL DEFAULT 1.0',
      'enable20sCheck': 'INTEGER DEFAULT 1',
    };
    for (final entry in defs.entries) {
      if (!conversationCols.contains(entry.key)) {
        await db.execute(
            'ALTER TABLE conversations ADD COLUMN ${entry.key} ${entry.value}');
      }
    }
  }

  /// v1.4.1：为旧库 conversations 补 contextAuto / autoCompress 两列
  /// contextAuto=1（默认）→ 上下文"自动"模式（不截断）；=0 → 细化手动上限
  /// autoCompress=1 → 上下文过长时自动把旧消息压成摘要
  Future<void> _migrateV7ContextColumns(Database db) async {
    final rows = await db.rawQuery('PRAGMA table_info(conversations)');
    final cols = rows.map((r) => r['name'] as String).toSet();
    const defs = <String, String>{
      'contextAuto': 'INTEGER DEFAULT 1',
      'autoCompress': 'INTEGER DEFAULT 0',
    };
    for (final entry in defs.entries) {
      if (!cols.contains(entry.key)) {
        await db.execute(
            'ALTER TABLE conversations ADD COLUMN ${entry.key} ${entry.value}');
        _logger.db('ALTER TABLE conversations ADD ${entry.key} (v6 migration)');
      }
    }
  }

  /// build138（G44/G45，任务书 §三.1）：账号表。
  ///
  /// 字段就是任务书点名的 7 个，不加「顺手觉得有用」的列：每多一列就多一处
  /// 三路同步的拷贝。cachedModels 与 api_configs 同义（在线 /v1/models 的结果），
  /// 归到账号是因为它本来就是**端点**的属性。
  Future<void> _createApiAccountsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS api_accounts (
        id TEXT PRIMARY KEY,
        templateId TEXT DEFAULT 'custom',
        name TEXT DEFAULT '',
        baseUrl TEXT DEFAULT '',
        apiKey TEXT DEFAULT '',
        cachedModels TEXT DEFAULT '',
        createdAt TEXT DEFAULT ''
      )
    ''');
    // 一级页按厂商取账号、删除与备份按 id 查，都走这个索引
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_api_accounts_template
      ON api_accounts (templateId)
    ''');
    // 老库（v39 之前建的表）补列的兜底：列缺失会让 ApiAccount.toMap 的
    // INSERT 整条失败，且失败点在保存路径上、用户只看得到「没保存」。
    for (final col in const ['name', 'baseUrl', 'apiKey', 'cachedModels', 'createdAt']) {
      await _ensureColumn(db, 'api_accounts', col, "TEXT DEFAULT ''");
    }
  }

  /// v38 → v39：建表 + 补列 + 把存量条目归组成账号。
  ///
  /// 三条硬约束（G44 验收闸门逐条对应）：
  /// ① **Key 不丢**：归组判据写在 [AccountGrouping.plan]（桶 = 连接身份，桶内按
  ///    apiKey 分组，Key 取组内第一条非空），填了不同 Key 天然不同组，
  ///    不存在「合并时选一条 Key 顶掉另一条」；
  /// ② **不合并不同 Key**：同上，写在纯函数里而不是这里，UI 与迁移共用一个判据；
  /// ③ **历史会话引用仍然解析得通**：本函数对 api_configs 只做
  ///    `UPDATE ... SET accountId = ?`，**不重写任何条目行**、不换 id、
  ///    不碰 conversations —— 会话引用的 id 一个都没变。
  Future<void> _migrateV39ApiAccounts(Database db) async {
    await _createApiAccountsTable(db);
    await _ensureColumn(db, 'api_configs', 'accountId', "TEXT DEFAULT ''");
    await _backfillAccountIds(db, force: true);
  }

  /// 把「还没有账号」的模型条目归组成账号并回填 accountId（幂等，可重复调用）。
  ///
  /// 为什么只处理 accountId 为空的条目：已经在账号名下的条目**绝不重新归组**——
  /// 否则用户把某条 Key 改得跟账号不同之后再启动，会被静默搬去另一个账号
  /// （「条目凭空换爹」是数据事故）。
  ///
  /// [force] 只为 onUpgrade 保留：跳过「有没有空 accountId」的快速探测，
  /// 直接做一次全表查询。
  Future<void> _backfillAccountIds(Database db, {bool force = false}) async {
    try {
      if (!force) {
        final pending = await db.query('api_configs',
            columns: ['id'], where: "accountId = '' OR accountId IS NULL", limit: 1);
        if (pending.isEmpty) return;
      }
      final rows = await db.query('api_configs',
          where: "accountId = '' OR accountId IS NULL", orderBy: 'name');
      if (rows.isEmpty) return;
      final configs = <ApiConfig>[];
      for (final r in rows) {
        try {
          configs.add(ApiConfig.fromMap(r));
        } catch (e) {
          _logger.dbWarn(
              '[DB] v39 归组：单条 api_configs 行解析失败，该条留在无账号状态：$e');
        }
      }
      if (configs.isEmpty) return;
      // build146：归组之前必须先回填保险库里的 Key —— AccountGrouping 的**两级
      // 归并键第二级就是 apiKey**（不同 Key 必分两账号）。列里现在是空串，
      // 不回填的话两条各有其 Key 的条目会被并成一个账号、账号 Key 取成空，
      // 于是「归组」变成「合并了两把不同的 Key」—— 正是 G44 的安全红线。
      await _hydrateSecrets(configs);
      final plans = AccountGrouping.plan(configs, nameOf: _defaultAccountName);
      var accounts = 0;
      var bound = 0;
      for (final plan in plans) {
        await db.insert('api_accounts', await _rowOfSecrets(plan.account),
            conflictAlgorithm: ConflictAlgorithm.ignore);
        accounts++;
        if (plan.configIds.isEmpty) continue;
        final marks = List.filled(plan.configIds.length, '?').join(',');
        // 只更新 accountId 这一列：见 _migrateV39ApiAccounts 的约束 ③。
        final changed = await db.rawUpdate(
          'UPDATE api_configs SET accountId = ? WHERE id IN ($marks)',
          [plan.account.id, ...plan.configIds],
        );
        bound += changed;
      }
      _logger.db(
          'v39 账号层归组完成：$accounts 个账号 / 回填 $bound 条模型条目'
          '（conversations 未改动，引用继续指向原 config.id）');
    } catch (e, st) {
      // 归组失败**不能**让启动失败：账号层是增量，缺它只是回到升级前的
      // 「每条配置自带 Key」形态，功能完全可用。但必须留错误日志。
      _logger.dbWarn('v39 账号层归组失败（保持原状，不阻塞启动）: $e\n$st');
    }
  }

  /// 账号名：能对上预设厂商就用厂商名，否则沿用用户给条目起的名字。
  ///
  /// 为什么同组多条时不加计数后缀：一个厂商下的两个模型本来就是**同一个连接**，
  /// 一级页要的是「DeepSeek」这张卡，不是「DeepSeek 2」。
  static String _defaultAccountName(ApiConfig member, int memberCount) {
    // 不给 catalog 加 byId：本批只在这一处需要按 id 查，加方法等于给
    // 正在被另一条改动线编辑的文件（api_provider_template.dart）塞冲突。
    final tpl =
        ApiProviderTemplateCatalog.instance.all
            .where((t) => t.id == member.templateId)
            .firstOrNull;
    final en = (tpl?.nameEn ?? '').trim();
    if (en.isNotEmpty) return en;
    final zh = (tpl?.nameZh ?? '').trim();
    if (zh.isNotEmpty) return zh;
    return member.name.trim();
  }

  /// v1.5.0：api_configs 补 cachedModels TEXT 列（缓存 GET /v1/models 返回的模型 id 列表）
  ///
  /// 老用户升级走这里；新用户走 _createV1Tables 的 CREATE TABLE。
  /// 教训#43：CREATE TABLE 和 ALTER TABLE 两路必须同步写。
  /// 启动时还有 _ensureColumn 兜底（防 onUpgrade 链路漏写）。
  Future<void> _migrateV8CachedModels(Database db) async {
    final rows = await db.rawQuery('PRAGMA table_info(api_configs)');
    final cols = rows.map((r) => r['name'] as String).toSet();
    if (!cols.contains('cachedModels')) {
      await db.execute(
          "ALTER TABLE api_configs ADD COLUMN cachedModels TEXT DEFAULT ''");
      _logger.db('ALTER TABLE api_configs ADD cachedModels (v8 migration)');
    }
  }

  Future<void> _migrateV9Plugins(Database db) async {
    final rows = await db.rawQuery('PRAGMA table_info(plugins)');
    if (rows.isEmpty) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS plugins (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          version TEXT NOT NULL,
          source TEXT NOT NULL,
          author TEXT,
          description TEXT,
          enabled INTEGER NOT NULL DEFAULT 1,
          installedAt INTEGER NOT NULL,
          metadataJson TEXT DEFAULT '{}'
        )
      ''');
      _logger.db('CREATE TABLE plugins (v9 migration)');
    } else {
      final cols = rows.map((r) => r['name'] as String).toSet();
      // v1.7.1 fix C5: SQLite 不支持 ALTER TABLE 添加 PRIMARY KEY 列
      // id 列必须在 CREATE TABLE 时定义，不能通过 ALTER TABLE 添加
      const defs = <String, String>{
        'name': 'TEXT NOT NULL',
        'version': 'TEXT NOT NULL',
        'source': 'TEXT NOT NULL',
        'author': 'TEXT',
        'description': 'TEXT',
        'enabled': 'INTEGER NOT NULL DEFAULT 1',
        'installedAt': 'INTEGER NOT NULL',
        'metadataJson': "TEXT DEFAULT '{}'",
      };
      for (final entry in defs.entries) {
        if (!cols.contains(entry.key)) {
          try {
            await db.execute(
                'ALTER TABLE plugins ADD COLUMN ${entry.key} ${entry.value}');
            _logger.db('ALTER TABLE plugins ADD ${entry.key} (v9 migration)');
          } catch (e) { debugPrint('catch 静默异常: $e'); }
        }
      }
    }
  }

  /// v1.7.5：web_search_configs 补安全审查相关字段
  Future<void> _migrateV10SecurityScan(Database db) async {
    final rows = await db.rawQuery('PRAGMA table_info(web_search_configs)');
    final existingCols = rows.map((r) => r['name'] as String).toSet();
    const defs = <String, String>{
      'skillspectorEndpoint': "TEXT DEFAULT ''",
      'enableSkillSecurityScan': 'INTEGER DEFAULT 0',
      'enableMcpSecurityScan': 'INTEGER DEFAULT 0',
      'mobsfEndpoint': "TEXT DEFAULT ''",
      'enableApkSecurityScan': 'INTEGER DEFAULT 0',
    };
    for (final entry in defs.entries) {
      if (!existingCols.contains(entry.key)) {
        await db.execute(
            'ALTER TABLE web_search_configs ADD COLUMN ${entry.key} ${entry.value}');
        _logger.db(
            'ALTER TABLE web_search_configs ADD ${entry.key} (v10 migration)');
      }
    }
  }

  Future<Database> get db async {
    if (_db == null) await init();
    return _db!;
  }

  /// 仅测试用：关掉当前库并允许再次 init()。
  /// 桌面版迁移测试（desktop_db_migration_test.dart）需要同一个单例
  /// 先后挂多个临时目录里的库文件；生产代码永远不调用它。
  @visibleForTesting
  Future<void> resetForTesting() async {
    await _db?.close();
    _db = null;
    _initialized = false;
  }

  // --- API Configs ---
  //
  // build138（G44/G45）之后的读法：**条目 + 账号一起出**。
  // 调用方（聊天页 / ModelSwitcher / 生成页）拿到的仍然是 [ApiConfig]，
  // 签名一个都没改 —— 账号层只在「条目自己的字段是空的」时补值
  // （AccountGrouping.fillFromAccount 只补空不覆盖，理由写在那儿）。
  //
  // build146 追加的一层（同一处收口，不在任何调用点补）：解析完先 [_hydrateSecrets]
  // 把保险库里的 Key 回填进对象，**再**做账号补值 —— 顺序反了的话
  // `fillFromAccount` 会看到「账号的 Key 是空串」而把子条目的 Key 判成缺失。
  Future<List<ApiConfig>> getApiConfigs() async {
    final database = await db;
    final maps = await database.query('api_configs', orderBy: 'name');
    return _withAccounts(
      database,
      await _hydrateSecrets(
          _parseRows(maps, ApiConfig.fromMap, 'api_configs')),
    );
  }

  Future<ApiConfig?> getApiConfig(String id) async {
    final database = await db;
    final maps =
        await database.query('api_configs', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;
    final parsed = await _hydrateSecrets(
        _parseRows(maps, ApiConfig.fromMap, 'api_configs'));
    if (parsed.isEmpty) return null;
    return (await _withAccounts(database, parsed)).first;
  }

  /// 把账号值补进条目（无账号 / 账号已被删时原样返回）。
  Future<List<ApiConfig>> _withAccounts(
      Database database, List<ApiConfig> configs) async {
    if (!configs.any((c) => c.accountId.trim().isNotEmpty)) return configs;
    final accounts = await _readAccounts(database);
    if (accounts.isEmpty) return configs;
    final byId = {for (final a in accounts) a.id: a};
    return [
      for (final c in configs)
        AccountGrouping.fillFromAccount(c, byId[c.accountId.trim()]),
    ];
  }

  /// 保存模型条目。
  ///
  /// 保持向后兼容的关键是**懒绑定**：库里仍有老调用点（导入、分享冷启动、
  /// 生成页另存配置）直接 new 一条不带 accountId 的 ApiConfig 过来。
  /// 与其要求全库每个调用点都改（漏一个就永远游离在账号层外，且没人会发现），
  /// 不如在这里收口：能对上已有账号就挂上去，对不上就按同一套纯函数建一个。
  Future<String> saveApiConfig(ApiConfig config) async {
    final database = await db;
    // build145（第 7 轮 P1）：整段收进单事务。原来 `_bindOrCreateAccount` 是
    // 「读全部账号 → 插一条账号 → 插本条配置」三步裸奔，中途 DB 锁/磁盘满就留下
    // 「账号已建、配置没落」或反过来的一半状态 —— 而删侧早就写了为什么必须原子
    // （见 deleteApiConfig 里 B-007 的注释：sqflite 默认不开 foreign_keys，
    //  一致性全靠手写语句的顺序，所以顺序必须整段成立或整段不成立）。
    late final ApiConfig toSave;
    await database.transaction((txn) async {
      var next = config;
      if (next.accountId.trim().isEmpty) {
        final bound = await _bindOrCreateAccount(txn, next);
        if (bound != null) next = next.copyWith(accountId: bound);
      }
      // build146：密钥改道保险库，行里那列落空串（写失败则原样带明文，见 _rowOfSecrets）。
      await txn.insert('api_configs', await _rowOfSecrets(next),
          conflictAlgorithm: ConflictAlgorithm.replace);
      toSave = next;
    });
    _logger.db(
        'API config saved: ${toSave.id} (${toSave.name}) account=${toSave.accountId.isEmpty ? '-' : toSave.accountId}');
    notifyListeners();
    return toSave.id;
  }

  /// 懒绑定：返回该条目应归属的账号 id；不适合建账号时返回 null。
  ///
  /// 参数是 [DatabaseExecutor] 而不是 [Database]：它只在上面那个事务里被调用，
  /// 事务内如果再走 `database.query` 就是**另一条连接上的另一个事务**，
  /// 读不到本事务未提交的写入，还会跟着锁打架。
  Future<String?> _bindOrCreateAccount(
      DatabaseExecutor txn, ApiConfig config) async {
    // 地址与 Key 全空的条目不值得一个账号（那是「还没填完的草稿」，
    // 给它建账号会让一级页凭空多一张空卡 —— G53 刚清掉过同类假数据）。
    if (config.baseUrl.trim().isEmpty && config.apiKey.trim().isEmpty) {
      return null;
    }
    final accounts = await _readAccounts(txn);
    final hit = AccountGrouping.resolveExisting(accounts, config);
    if (hit != null) return hit.id;
    final plan = AccountGrouping.plan([config],
        nameOf: _defaultAccountName).firstOrNull;
    if (plan == null) return null;
    // build146：新建账号也走 _rowOfSecrets（Key 进保险库、列里留空串）。
    // plan.account 的 Key 来自**已回填**的 config（saveApiConfig 的入参是
    // UI 现填或读路径产物），所以这里不存在「拿空值把已有条目删掉」的窗口。
    await txn.insert('api_accounts', await _rowOfSecrets(plan.account),
        conflictAlgorithm: ConflictAlgorithm.ignore);
    _logger.db(
        'API account created on save: ${plan.account.id} (${plan.account.name})');
    return plan.account.id;
  }

  Future<void> deleteApiConfig(String id) async {
    final database = await db;
    // B-007：整段（含 query）收进单事务——中途遇到 DB 锁/磁盘满/进程被杀时
    // 整体回滚，不留「部分会话已删、api_config 还在」的不一致。
    // 注意：sqflite 默认不执行 PRAGMA foreign_keys=ON，建表里的 ON DELETE CASCADE
    // 实际不生效，全靠这几条手动 delete，因此必须原子。
    // build146：保险库条目的删除**登记在事务里、执行在提交之后**（理由见
    // _queueVaultDelete 的注释：反过来做会在回滚时把还在用的 Key 删没）。
    final vaultDeletes = <({String scope, String rowId})>[];
    await database.transaction((txn) async {
      await _deleteApiConfigIn(txn, id, vaultDeletes: vaultDeletes);
    });
    await _dropVaultEntries(vaultDeletes);
    _logger.db('API config deleted: $id (cascaded messages/conversations)');
    notifyListeners();
  }

  /// 删条目（事务内），并顺手收掉**最后一个成员走了的空账号**。
  ///
  /// 为什么必须收：G44 的验收词是「无悬空」。空账号在一级页会渲染成一张
  /// 「已配置 0 个模型」的卡，点进去既不能对话也没有 Key 可改，
  /// 而余额缓存里它还占着一份。
  ///
  /// [vaultDeletes] 非空时把「要连带清掉的保险库条目」追加进去（本函数在事务内，
  /// 不能自己动手删 —— 见 [SecretStore.deleteWhere] 的顺序约定）。
  Future<void> _deleteApiConfigIn(
      DatabaseExecutor txn, String id,
      {bool clearAccount = true,
      List<({String scope, String rowId})>? vaultDeletes}) async {
    final rows =
        await txn.query('api_configs', where: 'id = ?', whereArgs: [id]);
    final accountId = clearAccount
        ? ((rows.firstOrNull?['accountId'] as String?)?.trim() ?? '')
        : '';
    _queueVaultDelete(vaultDeletes, SecretStore.apiConfigScope, id);
    final convs =
        await txn.query('conversations', where: 'apiConfigId = ?', whereArgs: [id]);
    for (final conv in convs) {
      final conversationId = conv['id'] as String;
      // build97 (P2-1)：级联补删 message_versions（先于 messages）
      await txn.delete('message_versions',
          where:
              'retryOfId IN (SELECT id FROM messages WHERE conversationId = ?)',
          whereArgs: [conversationId]);
      await txn.delete('messages',
          where: 'conversationId = ?', whereArgs: [conversationId]);
      await txn.delete('context_compaction_segments',
          where: 'conversationId = ?', whereArgs: [conversationId]);
    }
    await txn
        .delete('conversations', where: 'apiConfigId = ?', whereArgs: [id]);
    await txn.delete('api_configs', where: 'id = ?', whereArgs: [id]);
    if (accountId.isEmpty) return;
    final left = await txn.query('api_configs',
        columns: ['id'], where: 'accountId = ?', whereArgs: [accountId], limit: 1);
    if (left.isEmpty) {
      await txn.delete('api_accounts', where: 'id = ?', whereArgs: [accountId]);
      // 账号行被连带删掉了 ⇒ 它的 Key 也必须跟着走，否则保险库里留一条没人引用的
      // 明文（build146 要求 5：删除不许遗留）。
      _queueVaultDelete(vaultDeletes, SecretStore.apiAccountScope, accountId);
      _logger.db('API account removed with last model: $accountId');
    }
  }

  // --- API Accounts（build138 · G44/G45/G52）---------------------------------

  Future<List<ApiAccount>> getApiAccounts() async {
    final database = await db;
    return _readAccounts(database);
  }

  /// 账号读取的**唯一**出口：解析 + 回填保险库里的 Key。
  ///
  /// 为什么回填收在这里而不是各调用点：`_withAccounts`（读路径补空值）、
  /// `_bindOrCreateAccount`（懒绑定的同 Key 判据）、`saveApiAccount`（旧 Key 比对）
  /// 三处都**必须**看到真 Key —— 任何一处漏了，症状分别是「子条目被同步成空 Key」
  /// 「同 Key 的条目又新建了一个账号」「改 Key 时判定为『条目不跟随』」。
  /// 参数是 DatabaseExecutor：事务内也走它（回填只碰保险库，不碰数据库连接）。
  Future<List<ApiAccount>> _readAccounts(DatabaseExecutor database) async {
    final maps = await database.query('api_accounts', orderBy: 'name');
    return _hydrateSecrets(
        _parseRows(maps, ApiAccount.fromMap, 'api_accounts'));
  }

  Future<ApiAccount?> getApiAccount(String id) async {
    if (id.trim().isEmpty) return null;
    final database = await db;
    final maps = await database
        .query('api_accounts', where: 'id = ?', whereArgs: [id], limit: 1);
    final parsed = await _hydrateSecrets(
        _parseRows(maps, ApiAccount.fromMap, 'api_accounts'));
    return parsed.firstOrNull;
  }

  /// 该账号下的模型条目（**不**经过 [getApiConfigs] 的账号补值，
  /// 因为同步函数要看到的是条目自己真实存着的值，判据才是「本来跟不跟着」）。
  ///
  /// build146：仍然回填**本条自己**的保险库 Key —— 「raw」指的是不做账号补值，
  /// 不是「不还原密钥」；不回填的话这里出来的每条配置都是 401。
  Future<List<ApiConfig>> getRawConfigsForAccount(String accountId) async {
    if (accountId.trim().isEmpty) return const [];
    final database = await db;
    final maps = await database.query('api_configs',
        where: 'accountId = ?', whereArgs: [accountId], orderBy: 'name');
    return _hydrateSecrets(
        _parseRows(maps, ApiConfig.fromMap, 'api_configs'));
  }

  Future<List<ApiConfig>> getConfigsForAccount(String accountId) async {
    final database = await db;
    return _withAccounts(database, await getRawConfigsForAccount(accountId));
  }

  /// 保存账号，并把连接字段同步到它名下的模型条目（任务书 §三.3「请求时以账号为准」
  /// 的落库那一半）。
  Future<String> saveApiAccount(ApiAccount account) async {
    final database = await db;
    var childCount = 0;
    // build145（第 7 轮 P1）：同样是收进单事务。这一步写的是「账号 + 它名下所有
    // 模型条目的连接字段」，中途失败就会留下账号是新 Key、条目还是旧 Key 的半套状态
    // —— 而请求时以账号为准（任务书 §三.3），半套状态意味着**同一账号的模型
    // 打到两个不同的上游**，这类不一致是排查不出来的那种。
    // 事务内一律用 txn 读（`getRawConfigsForAccount` 走的是 database，另一条连接，
    // 读不到本事务未提交的写入），所以这里手写等价查询。
    await database.transaction((txn) async {
      // build146：previous 必须先回填再写新值 —— syncChildren 的同步判据是
      // 「条目 Key 与账号**旧** Key 相同才跟随」。旧 Key 若是空串（列已抹空、
      // 值在保险库），每一次保存账号都会被判成「条目自己改过 Key，不跟随」，
      // 用户改一次 Key 就得逐条改。读新值之前读旧值是硬顺序：写完之后保险库里
      // 只剩新 Key，旧值再也问不回来。
      final previous = (await _hydrateSecrets(_parseRows(
              await txn.query('api_accounts',
                  where: 'id = ?', whereArgs: [account.id], limit: 1),
              ApiAccount.fromMap,
              'api_accounts')))
          .firstOrNull ??
          ApiAccount.empty();
      await txn.insert('api_accounts', await _rowOfSecrets(account),
          conflictAlgorithm: ConflictAlgorithm.replace);
      final children = await _hydrateSecrets(_parseRows(
          await txn.query('api_configs',
              where: 'accountId = ?', whereArgs: [account.id], orderBy: 'name'),
          ApiConfig.fromMap,
          'api_configs'));
      childCount = children.length;
      if (children.isNotEmpty) {
        final synced = AccountGrouping.syncChildren(
            previous: previous, account: account, children: children);
        for (final c in synced) {
          await txn.insert('api_configs', await _rowOfSecrets(c),
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
    });
    _logger.db(
        'API account saved: ${account.id} (${account.name}) '
        'models=$childCount key=${account.apiKey.isEmpty ? 'empty' : '***'}');
    notifyListeners();
    return account.id;
  }

  /// 删账号 = 删它名下**全部**模型条目（任务书 §三.4）。
  ///
  /// 会话处理沿用现有删配置语义（连消息/压缩段一起级联），因此删完不会留下
  /// 指向已消失条目的会话 —— 「无悬空」是 G45 的原话。
  Future<void> deleteApiAccount(String accountId) async {
    if (accountId.trim().isEmpty) return;
    final database = await db;
    final vaultDeletes = <({String scope, String rowId})>[];
    await database.transaction((txn) async {
      final children = await txn
          .query('api_configs', where: 'accountId = ?', whereArgs: [accountId]);
      for (final row in children) {
        final id = row['id'];
        if (id is String) {
          await _deleteApiConfigIn(txn, id,
              clearAccount: false, vaultDeletes: vaultDeletes);
        }
      }
      await txn.delete('api_accounts', where: 'id = ?', whereArgs: [accountId]);
      // 账号自己的 Key：clearAccount: false 的那条路不会连带登记，这里补上。
      _queueVaultDelete(vaultDeletes, SecretStore.apiAccountScope, accountId);
    });
    await _dropVaultEntries(vaultDeletes);
    _logger.db('API account deleted: $accountId (cascaded its model configs)');
    notifyListeners();
  }

  /// 该厂商（模板）下的账号，一级页与二级页共用。
  Future<List<ApiAccount>> getApiAccountsForTemplate(String templateId) async {
    final all = await getApiAccounts();
    final id = templateId.trim();
    return all.where((a) => a.templateId.trim() == id).toList(growable: false);
  }

  // --- Web Search Config (singleton) ---
  //
  // build146：六个 provider Key（tavily / serp / brave / googleCse / virusTotal /
  // mobsf）同样只以空串落库，读取时回填。`googleCseId` 是搜索实例 id（cx）不是
  // 凭据，按本仓库既有剥敏白名单（apikey|token|secret 结尾）的口径继续留在列里。
  /// #129 的一次性留痕开关：迁移不许变成新的静默。
  ///
  /// 整进程只喊一次——`getWebSearchConfig` 每次开设置页、每次安全闸都会走，
  /// 每读一次写一行会把真问题淹掉（build145 那条"过度上报与静默是同一枚硬币的两面"）。
  static bool _legacyRulesUrlNoted = false;

  /// 测试用：把一次性留痕放开，好让"只喊一次"这条本身可被复验。
  @visibleForTesting
  static void resetLegacyRulesUrlNote() => _legacyRulesUrlNoted = false;

  Future<WebSearchConfig> getWebSearchConfig() async {
    final database = await db;
    final maps = await database
        .query('web_search_configs', where: 'id = ?', whereArgs: ['singleton']);
    if (maps.isEmpty) return WebSearchConfig();
    // build176（#129）：`WebSearchConfig.fromMap` 会把指旧私有仓的规则源退回默认，
    // 但**退回**这件事发生在模型层（模型不 import LoggerService，见 main.dart 里
    // `ChatMessage.corruptReporter` 那条口径），所以留痕落在这里、读原始列自己判一次。
    final rawRulesUrl = maps.first['localScanRulesUrl'];
    if (!_legacyRulesUrlNoted &&
        rawRulesUrl is String &&
        isLegacyPrivateRepoSource(rawRulesUrl)) {
      _legacyRulesUrlNoted = true;
      _logger.info('[DB] 规则源持久值仍指向已迁走的私有仓，本次读取已退回公开仓默认：'
          '$rawRulesUrl', tag: 'DB');
    }
    final cfg = WebSearchConfig.fromMap(maps.first);
    return (await _hydrateSecrets(<WebSearchConfig>[cfg])).first;
  }

  Future<void> saveWebSearchConfig(WebSearchConfig cfg) async {
    final database = await db;
    final map = await _rowOfSecrets(cfg)..['id'] = 'singleton';
    await database.insert('web_search_configs', map,
        conflictAlgorithm: ConflictAlgorithm.replace);
    _logger.db(
      'WebSearch config saved: provider=${cfg.provider.name}, '
      'enabled=${cfg.webSearchEnabled}, '
      'tavilyKey=${cfg.tavilyApiKey.isEmpty ? 'empty' : '***'}',
    );
    notifyListeners();
  }

  Future<bool> getBiometricLockEnabled() async {
    final cfg = await getWebSearchConfig();
    return cfg.biometricLockEnabled;
  }

  Future<void> setBiometricLockEnabled(bool enabled) async {
    final cfg = await getWebSearchConfig();
    cfg.biometricLockEnabled = enabled;
    await saveWebSearchConfig(cfg);
    _logger.app('Biometric lock ${enabled ? "enabled" : "disabled"}');
  }

  // --- Conversations ---
  Future<List<Conversation>> getConversations() async {
    final database = await db;
    final maps = await database.query('conversations',
        orderBy: 'isPinned DESC, updatedAt DESC');
    return _parseRows(maps, Conversation.fromMap, 'conversations');
  }

  Future<Conversation?> getConversation(String id) async {
    final database = await db;
    final maps =
        await database.query('conversations', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;
    return Conversation.fromMap(maps.first);
  }

  /// build123：最近一次活跃的会话（「分享到 Nexus」的落点）。
  ///
  /// 与 [getConversations] 的差别：那个按 `isPinned DESC, updatedAt DESC` 排，
  /// 置顶会话会盖住真正最近聊过的那个；分享要的是「最近聊天页面」，
  /// 所以这里**只按 updatedAt** 排。
  Future<Conversation?> getMostRecentConversation() async {
    final database = await db;
    final maps = await database.query('conversations',
        orderBy: 'updatedAt DESC', limit: 1);
    if (maps.isEmpty) return null;
    return Conversation.fromMap(maps.first);
  }

  Future<String> saveConversation(Conversation conv) async {
    final database = await db;
    await database.insert('conversations', conv.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    notifyListeners();
    return conv.id;
  }

  Future<void> updateConversationTitle(String id, String title) async {
    final database = await db;
    await database.update('conversations',
        {'title': title, 'updatedAt': DateTime.now().toIso8601String()},
        where: 'id = ?', whereArgs: [id]);
    notifyListeners();
  }

  // ==================== build101（B2/B5）新增 ====================

  /// build101（B5）：切换会话归档状态（归档后不在主列表显示）
  Future<void> toggleArchiveConversation(String id, bool isArchived) async {
    final database = await db;
    await database.update('conversations',
        {'isArchived': isArchived ? 1 : 0},
        where: 'id = ?', whereArgs: [id]);
    notifyListeners();
  }

  /// build101（B4）：切换消息**收藏（星标）**状态，写回会话的 starredMessageIds
  ///
  /// build157（P2 数据丢失）：原来「query 读出整串 → await → 改集合 → update 写回
  /// 整串」三步都在**事务外**。这个列是"一个字符串装下全部收藏"，所以交错一次
  /// 不是丢一条边、是丢一整串：连点两次星标（或同一会话里两条消息几乎同时点），
  /// 后一次 query 在前一次的 update 落地之前跑完 ⇒ 它拿到的还是旧串，
  /// 写回时把前一次刚加上的那个 id 覆盖掉（lost update）。
  /// UI 侧确实是裸 await、没有防抖（chat_screen_message.dart 的点星分支），
  /// 所以这不是假想路径。
  ///
  /// 修法与本文件既有口径一致（见 [saveMessage] 的 v1.7.16 修复、
  /// saveApiConfig 的 build145 注释）：读写对收进**同一个** transaction ——
  /// sqflite 对同一 Database 的事务是串行的，第二条必须等第一条提交完才开跑，
  /// 于是它读到的是已含前一次改动的串。**事务内一律用 txn 读**：走 database /
  /// 自己的普通方法等于另一条连接，既读不到本事务未提交的写入，又会互相排队。
  ///
  /// 纯并发修复：不动 schema、不加列、不碰 onUpgrade（v39 迁移约定）。
  Future<void> toggleStarMessage(String conversationId, String messageId) async {
    final database = await db;
    // 会话行不存在时原实现是直接 return 且不 notify，这里保持同一外部可见行为
    var wrote = false;
    await database.transaction((txn) async {
      final rows = await txn.query('conversations',
          columns: ['starredMessageIds'],
          where: 'id = ?',
          whereArgs: [conversationId],
          limit: 1);
      if (rows.isEmpty) return;
      final conv = Conversation.fromMap({
        // fromMap 需要完整字段，这里只借用 starredIds 解析逻辑 → 直接解析更轻
        'id': conversationId,
        'title': '',
        'apiConfigId': '',
        'updatedAt': DateTime.now().toIso8601String(),
        'createdAt': DateTime.now().toIso8601String(),
        ...rows.first,
      });
      final ids = conv.starredIds.toSet();
      if (ids.contains(messageId)) {
        ids.remove(messageId);
      } else {
        ids.add(messageId);
      }
      await txn.update('conversations',
          {'starredMessageIds': ids.isEmpty ? '' : json.encode(ids.toList())},
          where: 'id = ?', whereArgs: [conversationId]);
      wrote = true;
    });
    if (wrote) notifyListeners();
  }

  /// build101（B3）：删除某条消息之后的所有消息（编辑用户消息后重发的截断）
  ///
  /// 按 createdAt 顺序删除所有 `createdAt > 该消息 createdAt` 的消息，
  /// 并把该消息自身的内容替换为新的编辑内容。
  /// 同时清理该会话的上下文压缩片段（内容已变，旧片段失效）。
  Future<void> truncateMessagesAfter(
      String conversationId, String messageId) async {
    final database = await db;
    final rows = await database.query('messages',
        columns: ['createdAt'],
        where: 'id = ?',
        whereArgs: [messageId],
        limit: 1);
    if (rows.isEmpty) return;
    final ts = rows.first['createdAt'] as String;
    await database.transaction((txn) async {
      // B-008：先按「将被截断的消息」补删 message_versions（必须在删 messages 前
      // 执行子查询，否则子查询已查不到目标 id）。
      await txn.delete('message_versions',
          where: 'retryOfId IN (SELECT id FROM messages '
              'WHERE conversationId = ? AND createdAt > ?)',
          whereArgs: [conversationId, ts]);
      await txn.delete('messages',
          where: 'conversationId = ? AND createdAt > ?',
          whereArgs: [conversationId, ts]);
      await txn.delete('context_compaction_segments',
          where: 'conversationId = ?', whereArgs: [conversationId]);
      // 列表预览回退到被编辑的那条（其内容随后由调用方 updateMessageContent 覆盖）
      await txn.update('conversations',
          {'updatedAt': DateTime.now().toIso8601String()},
          where: 'id = ?', whereArgs: [conversationId]);
    });
    notifyListeners();
  }

  /// build101（B2）：全局搜索——在会话标题与消息内容中按关键字查找
  ///
  /// 返回 `ConversationSearchHit` 列表，按更新时间倒序。
  /// 每个会话只返回**第一条**命中的消息作为上下文片段（可高亮）。
  ///
  /// 实现说明：SQLite 的 LIKE 对大小写不敏感仅限 ASCII，中文按字面匹配；
  /// 关键字先做 `%`/`_` 转义，避免用户输入 `%` 时全表命中。
  Future<List<ConversationSearchHit>> searchConversations(String keyword,
      {int limit = 50}) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return const [];
    final database = await db;
    final escaped = kw.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');
    final like = '%$escaped%';
    // 先按标题命中
    final titleRows = await database.query(
      'conversations',
      where: "title LIKE ? ESCAPE '\\'",
      whereArgs: [like],
      orderBy: 'updatedAt DESC',
      limit: limit,
    );
    // build138（扫描 P2-1）：搜索路径此前对每行直接强解（无逐行 try），
    // 一行脏数据就让整个搜索页抛异常（列表路径早已走 _parseRows，唯独搜索漏了）。
    final parsedTitleRows =
        _parseRows<Conversation>(titleRows, Conversation.fromMap, 'conversations(标题搜索)');
    final hits = <String, ConversationSearchHit>{};
    for (final c in parsedTitleRows) {
      hits[c.id] = ConversationSearchHit(
        conversation: c,
        matchedInTitle: true,
        snippet: c.lastMessage ?? '',
      );
    }
    // 再按消息内容命中（补足剩余额度）
    if (hits.length < limit) {
      final msgRows = await database.rawQuery('''
        SELECT m.conversationId AS cid, m.content AS content
        FROM messages m
        INNER JOIN conversations c ON c.id = m.conversationId
        WHERE m.content LIKE ? ESCAPE '\\'
        ORDER BY c.updatedAt DESC, m.createdAt ASC
        LIMIT ?
      ''', [like, limit * 5]);
      // build138（扫描 P2-2）：此前对**每一条**消息行单独 query 一次 conversations
      // （上限 limit*5 = 250 次往返，搜索时主线程等待明显）。改成先把候选 cid 去重，
      // 一次 `id IN (...)` 批量取回再建索引，语义不变。
      final pendingCids = <String>[];
      for (final r in msgRows) {
        final cid = r['cid'] as String?;
        if (cid == null || cid.isEmpty) continue;
        if (hits.containsKey(cid) || pendingCids.contains(cid)) continue;
        pendingCids.add(cid);
      }
      if (pendingCids.isNotEmpty) {
        final convRows = await database.query('conversations',
            where:
                'id IN (${List.filled(pendingCids.length, '?').join(',')})',
            whereArgs: pendingCids);
        final convById = <String, Conversation>{};
        for (final c in _parseRows<Conversation>(
            convRows, Conversation.fromMap, 'conversations(内容搜索)')) {
          convById[c.id] = c;
        }
        for (final r in msgRows) {
          final cid = r['cid'] as String?;
          if (cid == null || hits.containsKey(cid)) continue;
          final conv = convById[cid];
          if (conv == null) continue;
          hits[cid] = ConversationSearchHit(
            conversation: conv,
            matchedInTitle: false,
            snippet: r['content'] as String? ?? '',
          );
          if (hits.length >= limit) break;
        }
      }
    }
    final list = hits.values.toList()
      ..sort((a, b) =>
          b.conversation.updatedAt.compareTo(a.conversation.updatedAt));
    return list;
  }

  /// build101（F1）：会话内全文查找——只在指定会话的消息里找关键字。
  ///
  /// 与 [searchConversations] 的差异：
  /// 1. 锁定单个 conversationId，不跨会话；
  /// 2. 返回**消息在列表中的下标** `indexInConversation`，用于滚动定位；
  /// 3. 每条命中带上下文窗口 snippet（前置 [contextBefore] / 后置 [contextAfter] 字符）。
  ///
  /// 结果按消息时间正序（与聊天列表一致），便于「上一个 / 下一个」跳转。
  ///
  /// 中文匹配：SQLite LIKE 对中文按字面精确匹配，对 ASCII 大小写不敏感；
  /// 关键字中的 % / _ / \ 已转义，避免误命中。
  Future<List<MessageSearchHit>> searchMessagesInConversation(
    String conversationId,
    String keyword, {
    int limit = 200,
    int contextBefore = 30,
    int contextAfter = 70,
  }) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return const [];
    final database = await db;
    final escaped = kw
        .replaceAll('\\', '\\\\')
        .replaceAll('%', '\\%')
        .replaceAll('_', '\\_');
    final like = '%$escaped%';

    // 命中行（按内容过滤，行号不连续，故下面另算下标）
    final rows = await database.query(
      'messages',
      where: "conversationId = ? AND content LIKE ? ESCAPE '\\'",
      whereArgs: [conversationId, like],
      orderBy: 'createdAt ASC',
      limit: limit,
    );
    if (rows.isEmpty) return const [];

    // 消息在会话中的真实下标：拉全量 id 有序表，再做位置映射
    final allRows = await database.query(
      'messages',
      columns: ['id'],
      where: 'conversationId = ?',
      whereArgs: [conversationId],
      orderBy: 'createdAt ASC',
    );
    final indexById = <String, int>{};
    for (var i = 0; i < allRows.length; i++) {
      final id = allRows[i]['id'] as String?;
      if (id != null) indexById[id] = i;
    }

    final hits = <MessageSearchHit>[];
    final lowerKw = kw.toLowerCase();
    for (final r in rows) {
      final content = (r['content'] as String?) ?? '';
      if (content.isEmpty) continue;
      final id = r['id'] as String?;
      if (id == null) continue;
      final idx = indexById[id];
      if (idx == null) continue;

      final lowerContent = content.toLowerCase();
      final pos = lowerContent.indexOf(lowerKw);
      if (pos < 0) continue;
      final start = (pos - contextBefore).clamp(0, content.length);
      final end = (pos + kw.length + contextAfter).clamp(0, content.length);
      var snippet = content.substring(start, end);
      if (start > 0) snippet = '…$snippet';
      if (end < content.length) snippet = '$snippet…';
      final matchStart = (start > 0) ? pos - start + 1 : pos - start;

      var count = 0;
      var scan = 0;
      while (true) {
        final p = lowerContent.indexOf(lowerKw, scan);
        if (p < 0) break;
        count++;
        scan = p + kw.length;
      }

      // build138（扫描 P2-1）：搜索结果里的消息同样可能撞上脏行。
      // 单条解析失败只跳过这一条命中，不让整个搜索抛异常。
      late final ChatMessage msg;
      try {
        msg = ChatMessage.fromMap(r);
      } catch (e) {
        _logger.dbWarn('[DB] 消息搜索命中解析失败，已跳过：$e');
        continue;
      }
      hits.add(MessageSearchHit(
        message: msg,
        indexInConversation: idx,
        snippet: snippet,
        matchStartInSnippet: matchStart,
        matchCount: count,
      ));
    }
    return hits;
  }

  /// v1.7.34：更新对话摘要（跨对话记忆；后台 completeChat 生成后写回，不刷 updatedAt 以免污染排序）
  Future<void> updateConversationSummary(String id, String summary) async {
    final database = await db;
    await database.update('conversations', {'summary': summary},
        where: 'id = ?', whereArgs: [id]);
  }

  /// v1.7.34：取最近 N 个有摘要的对话（不含当前对话 id）
  /// 用于消息发送前拼跨对话记忆 system prompt。
  /// 返回字段：id / title / summary / updatedAt（已按 updatedAt 倒序）
  Future<List<Map<String, dynamic>>> getRecentSummaries(int limit,
      {String? excludeId}) async {
    final database = await db;
    final whereArgs = excludeId == null ? <Object?>[] : <Object?>[excludeId];
    // build98（P2）：excludeId==null 时 SQL 层也要滤空 summary，
    // 否则空摘要行占用 limit，实际返回数少于请求数
    final where = excludeId == null
        ? "summary != ''"
        : 'id != ? AND summary != \'\'';
    final maps = await database.query(
      'conversations',
      where: where,
      whereArgs: whereArgs,
      columns: ['id', 'title', 'summary', 'updatedAt'],
      orderBy: 'updatedAt DESC',
      limit: excludeId == null ? limit : limit + 1,
    );
    return maps
        .where((m) => ((m['summary'] as String?) ?? '').isNotEmpty)
        .take(limit)
        .toList();
  }

  // ── v1.7.38 build90（待办⑧⑨）：全局/项目记忆 + 斜杠命令 CRUD ──

  /// build173（方案 C）：读自动记忆总闸，**全仓只有这一处读**（形状照
  /// `lib/utils/background_run_switch.dart:36` —— 一个键 + 一处读，页面与落库点
  /// 读同一把 key，不许各自 `getBool` 一遍再漂成两种口径）。
  ///
  /// 缺省即 `true`：这道闸没被拨过 = 与 build92 以来逐字节同行为（AI 照旧会记），
  /// 理由见 [kAutoMemoryEnabledKey]。读不到 prefs 时调用方按 `true` 处理才对，
  /// 但这里不吞异常 —— 异常说明的是环境坏了，不是"用户想关"。
  static Future<bool> autoMemoryEnabled({SharedPreferences? prefs}) async {
    final p = prefs ?? await SharedPreferences.getInstance();
    return p.getBool(kAutoMemoryEnabledKey) ?? true;
  }

  /// 落盘总闸（只有设置页那一行由用户亲手拨时才调）。
  static Future<void> setAutoMemoryEnabled(bool enabled,
      {SharedPreferences? prefs}) async {
    final p = prefs ?? await SharedPreferences.getInstance();
    await p.setBool(kAutoMemoryEnabledKey, enabled);
  }

  /// **总闸的唯一拦截点**：AI 自动写记忆这一类（`source == 'auto'`）在总闸关掉时
  /// 不写库；用户自己写的（`manual` / `conversation:<id>`）一律照旧落库（反向闸）。
  ///
  /// 为什么只在这里拦、四个调用点一个都不加 `if`：自动写记忆的落点是 4 处 / 2 文件
  /// （`lib/plugins/builtin_plugins.dart:1193`、`:1229`，直聊路径
  /// `lib/screens/chat_screen_message.dart:946`、`:964`），四条路最后都汇进
  /// [saveProjectMemory] / [saveGlobalMemory] 这两个函数。在调用点各写一遍就是
  /// "同一事实住四个文件"，下一次加第五条路必然漏（教训 #62 同族）。
  ///
  /// 语义是**停写不删**：关掉之后库里的条目一条都不动、仍读得到（对齐 Claude
  /// `Pause memory` 与 OpenAI `关闭记忆不会删除以往的聊天`）。
  ///
  /// 日志走 [LoggerService]（不是 `debugPrint` —— release 包里它是 no-op，
  /// 那条"为什么这条没进来"就永远取不到证）。只打表名与 id，不打正文：
  /// 记忆内容本身就是要交给用户保管的东西。
  Future<bool> _autoMemoryGateAllows(
      String source, String table, String id) async {
    if (source != 'auto') return true;
    if (await autoMemoryEnabled()) return true;
    _logger.warn('自动记忆总闸=关，这条 auto 未入库：$table id=$id',
        cat: LogCat.db, tag: 'AutoMemory');
    return false;
  }

  // —— 全局记忆 ——
  static const int maxGlobalMemories = 50;
  static const int maxProjectMemoriesPerProject = 50;

  /// N5：计算记忆超限时应删除的 id（纯函数，不碰 DB，可直接单测）。
  /// 规则：超出 [cap] 的条数只从 source='auto' 且未 pinned 的最旧条里出
  /// （updatedAt 升序）；manual / pinned / 其它 source（如 conversation:xxx）
  /// 绝不因超限被删，可删条不足时保持超限。
  /// 行来自 SELECT *：global_memories 有 pinned 列、project_memories 没有，
  /// 缺 pinned 键按"未置顶"处理。
  static List<String> excessMemoryIdsToDelete(
      List<Map<String, dynamic>> rows, int cap) {
    if (rows.length <= cap) return const [];
    final excess = rows.length - cap;
    final deletable = rows
        .where((r) =>
            (r['source'] as String?) == 'auto' &&
            ((r['pinned'] as int?) ?? 0) == 0)
        .toList()
      ..sort((a, b) => ((a['updatedAt'] as int?) ?? 0)
          .compareTo((b['updatedAt'] as int?) ?? 0));
    return deletable.take(excess).map((r) => r['id'] as String).toList();
  }

  /// N5：insert 后把记忆表裁剪到上限内（global/project 两条保存路径共用收口）。
  /// [where]/[whereArgs]：project_memories 按 projectId 圈定范围（每项目独立上限）；
  /// global 传 null（全表计数）。
  Future<void> _trimMemoriesToCap(DatabaseExecutor executor, String table,
      int cap, {String? where, List<Object?>? whereArgs}) async {
    final rows = await executor.query(table, where: where, whereArgs: whereArgs);
    final ids = excessMemoryIdsToDelete(rows, cap);
    if (ids.isEmpty) return;
    await executor.delete(
      table,
      where: 'id IN (${List.filled(ids.length, '?').join(',')})',
      whereArgs: ids,
    );
  }

  Future<List<GlobalMemory>> loadGlobalMemories() async {
    final database = await db;
    final rows = await database.query('global_memories',
        orderBy: 'pinned DESC, updatedAt DESC');
    return _parseRows(rows, GlobalMemory.fromMap, 'global_memories');
  }

  Future<void> saveGlobalMemory(GlobalMemory m) async {
    // build173（方案 C）：总闸拦在落库前最后一步 —— 一处拦住四个 auto 写入点，
    // 四个调用点各自一个 `if` 都不加（判据只住这一处，见 [_autoMemoryGateAllows]）。
    if (!await _autoMemoryGateAllows(m.source, 'global_memories', m.id)) {
      return;
    }
    final database = await db;
    // N5：insert + 裁剪同事务（原子）。超限时只删 source=auto 且未 pinned 的最旧条
    await database.transaction((txn) async {
      await txn.insert('global_memories', m.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace);
      await _trimMemoriesToCap(txn, 'global_memories', maxGlobalMemories);
    });
  }

  Future<void> deleteGlobalMemory(String id) async {
    final database = await db;
    await database.delete('global_memories', where: 'id = ?', whereArgs: [id]);
  }

  // —— 项目 ——
  Future<List<Project>> loadProjects() async {
    final database = await db;
    final rows = await database.query('projects', orderBy: 'createdAt ASC');
    return _parseRows(rows, Project.fromMap, 'projects');
  }

  Future<void> saveProject(Project p) async {
    final database = await db;
    await database.insert('projects', p.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 删项目：级联删项目记忆/项目命令，并把归属该项目的对话解绑
  Future<void> deleteProject(String id) async {
    final database = await db;
    await database.transaction((txn) async {
      await txn.delete('projects', where: 'id = ?', whereArgs: [id]);
      await txn
          .delete('project_memories', where: 'projectId = ?', whereArgs: [id]);
      await txn.delete('slash_commands',
          where: 'scope = ?', whereArgs: ['project:$id']);
      await txn.update('conversations', {'projectId': ''},
          where: 'projectId = ?', whereArgs: [id]);
    });
  }

  // —— 项目记忆 ——
  Future<List<ProjectMemory>> loadProjectMemories(String projectId) async {
    final database = await db;
    final rows = await database.query('project_memories',
        where: 'projectId = ?',
        whereArgs: [projectId],
        orderBy: 'updatedAt DESC');
    return _parseRows(rows, ProjectMemory.fromMap, 'project_memories');
  }

  Future<void> saveProjectMemory(ProjectMemory m) async {
    // build173（方案 C）：与 [saveGlobalMemory] 同一道闸、同一个判据
    // （[_autoMemoryGateAllows]），project 这一路也在库里 —— 两条 save 路径就是
    // 四个 auto 落点的共同咽喉，所以闸只需要一处。
    if (!await _autoMemoryGateAllows(
        m.source, 'project_memories', m.id)) {
      return;
    }
    final database = await db;
    // N5：insert + 裁剪同事务（原子）。每项目独立上限，只删 source=auto 最旧条
    await database.transaction((txn) async {
      await txn.insert('project_memories', m.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace);
      await _trimMemoriesToCap(txn, 'project_memories',
          maxProjectMemoriesPerProject,
          where: 'projectId = ?', whereArgs: [m.projectId]);
    });
  }

  Future<void> deleteProjectMemory(String id) async {
    final database = await db;
    await database.delete('project_memories', where: 'id = ?', whereArgs: [id]);
  }

  // —— 斜杠命令 ——
  /// scope 过滤：'global' 或 'project:<id>'
  Future<List<SlashCommand>> loadSlashCommands({String? scope}) async {
    final database = await db;
    final rows = await database.query(
      'slash_commands',
      where: scope == null ? null : 'scope = ?',
      whereArgs: scope == null ? null : [scope],
      orderBy: 'updatedAt DESC',
    );
    return _parseRows(rows, SlashCommand.fromMap, 'slash_commands');
  }

  Future<void> saveSlashCommand(SlashCommand c) async {
    final database = await db;
    await database.insert('slash_commands', c.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteSlashCommand(String id) async {
    final database = await db;
    await database.delete('slash_commands', where: 'id = ?', whereArgs: [id]);
  }

  /// 同 scope 下命令名唯一性校验（排除自身 id）
  Future<bool> slashCommandNameExists(String name, String scope,
      {String? excludeId}) async {
    final database = await db;
    final rows = await database.query('slash_commands',
        where: 'name = ? AND scope = ? AND id != ?',
        whereArgs: [name, scope, excludeId ?? '']);
    return rows.isNotEmpty;
  }

  Future<void> togglePinConversation(String id, bool isPinned) async {
    final database = await db;
    await database.update(
        'conversations',
        {
          'isPinned': isPinned ? 1 : 0,
          'updatedAt': DateTime.now().toIso8601String()
        },
        where: 'id = ?',
        whereArgs: [id]);
    notifyListeners();
  }

  Future<void> deleteConversation(String id) async {
    final database = await db;
    // B-007：四条级联删除收进单事务——中途失败不再留半删状态
    //（messages 删一半 / 会话行残留空会话 / versions 已删 messages 还在）。
    await database.transaction((txn) async {
      // build97 (P2-1)：级联补删 message_versions——重试快照按消息 id 挂着，
      // 漏删会留孤儿数据无限累积。必须在删 messages 之前按子查询删。
      await txn.delete('message_versions',
          where:
              'retryOfId IN (SELECT id FROM messages WHERE conversationId = ?)',
          whereArgs: [id]);
      await txn.delete('messages',
          where: 'conversationId = ?', whereArgs: [id]);
      await txn.delete('context_compaction_segments',
          where: 'conversationId = ?', whereArgs: [id]);
      await txn.delete('conversations', where: 'id = ?', whereArgs: [id]);
    });
    notifyListeners();
  }

  // --- Context compaction segments ---
  Future<List<ContextCompactionSegment>> getContextCompactionSegments(
      String conversationId) async {
    final database = await db;
    final maps = await database.query(
      'context_compaction_segments',
      where: 'conversationId = ?',
      whereArgs: [conversationId],
      orderBy: 'createdAt ASC',
    );
    return _parseRows(maps, ContextCompactionSegment.fromMap, 'context_compaction_segments');
  }

  Future<void> saveContextCompactionSegment(
      ContextCompactionSegment segment) async {
    final database = await db;
    await database.insert(
      'context_compaction_segments',
      segment.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteContextCompactionSegments(String conversationId) async {
    final database = await db;
    await database.delete(
      'context_compaction_segments',
      where: 'conversationId = ?',
      whereArgs: [conversationId],
    );
  }

  // --- Video tasks（build122）---
  //
  // 口径说明：这些方法**不**清空对话级数据（与上面压缩段那组相反）——
  // 视频任务是独立作业，删会话不该顺手把用户花钱生成的任务记录抹掉。

  Future<void> saveVideoTask(VideoTask task) async {
    final database = await db;
    await database.insert('video_tasks', task.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    notifyListeners();
  }

  /// 最近的任务在前（列表页与续查都按这个顺序）
  Future<List<VideoTask>> getVideoTasks({int limit = 100}) async {
    final database = await db;
    final maps = await database.query(
      'video_tasks',
      orderBy: 'createdAt DESC',
      limit: limit,
    );
    return _parseRows(maps, VideoTask.fromMap, 'video_tasks');
  }

  /// 仍需继续轮询的任务（未到终态）——App 启动时用它恢复轮询
  Future<List<VideoTask>> getPendingVideoTasks() async {
    final database = await db;
    final maps = await database.query(
      'video_tasks',
      where: "state NOT IN ('completed','failed')",
      orderBy: 'createdAt ASC',
    );
    return _parseRows(maps, VideoTask.fromMap, 'video_tasks');
  }

  Future<void> updateVideoTask(VideoTask task) async {
    final database = await db;
    await database.update('video_tasks', task.toMap(),
        where: 'id = ?', whereArgs: [task.id]);
    notifyListeners();
    // build142（灵动岛）：状态写库 = 唯一可靠出口，在这里递原语给通知层。
    // 刻意**不**用 addListener 订阅 StorageService：它的 notifyListeners 覆盖所有表，
    // 挂在上面等于每存一条消息就白扫一遍视频表。
    unawaited(LiveTaskWiring.onVideoTask(
      id: task.id,
      state: task.state,
      label: task.errorMessage.isEmpty ? task.prompt : task.errorMessage,
    ));
  }

  Future<void> deleteVideoTask(String id) async {
    final database = await db;
    await database.delete('video_tasks', where: 'id = ?', whereArgs: [id]);
    notifyListeners();
  }

  // --- Messages ---
  Future<List<ChatMessage>> getMessages(String conversationId) async {
    final database = await db;
    final maps = await database.query('messages',
        where: 'conversationId = ?',
        whereArgs: [conversationId],
        orderBy: 'createdAt ASC');
    return _parseRows(maps, ChatMessage.fromMap, 'chat_messages');
  }

  Future<String> saveMessage(ChatMessage msg) async {
    final database = await db;
    // v1.7.16 修复：INSERT 消息 + UPDATE 会话列表分两步无事务，进程被杀会留下
    // "消息已存但 lastMessage/updatedAt 未更新"的不一致；用事务包裹保证原子性。
    await database.transaction((txn) async {
      await txn.insert('messages', msg.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace);
      // Update conversation's lastMessage and updatedAt
      await txn.update(
          'conversations',
          {
            'lastMessage': msg.content.length > 50
                ? '${msg.content.substring(0, 50)}...'
                : msg.content,
            'updatedAt': DateTime.now().toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: [msg.conversationId]);
    });
    notifyListeners();
    return msg.id;
  }

  Future<void> updateMessageContent(String id, String content) async {
    final database = await db;
    await database.update('messages', {'content': content},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteMessage(String id) async {
    final database = await db;
    final rows = await database.query(
      'messages',
      columns: ['conversationId'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    await database.transaction((txn) async {
      // build145（第 7 轮 P0-3）：先按区间算出该连带删掉的压缩段，**再**删消息行
      // （判定要看被删消息的 createdAt，行删掉就查不到了）。
      await _dropCompactionSegmentsCovering(txn,
          conversationIds: {
            for (final r in rows)
              if (r['conversationId'] is String) r['conversationId'] as String,
          },
          deletedIds: {id});
      // B-008：该消息若作为 retryOfId 挂着重试版本快照，一并删除（防孤儿累积）
      await txn.delete('message_versions',
          where: 'retryOfId = ?', whereArgs: [id]);
      await txn.delete('messages', where: 'id = ?', whereArgs: [id]);
    });
    notifyListeners();
  }

  /// 删消息时连带清理压缩段：只删**区间被影响**的那些（口径见
  /// [segmentsToDropForDeletedMessages]）。必须在删除 messages 行之前调用。
  Future<void> _dropCompactionSegmentsCovering(DatabaseExecutor txn,
      {required Set<String> conversationIds,
      required Set<String> deletedIds}) async {
    if (conversationIds.isEmpty || deletedIds.isEmpty) return;
    final createdAtOf = await _createdAtByIds(txn, deletedIds);
    for (final cid in conversationIds) {
      final segs = await txn.query(
        'context_compaction_segments',
        columns: ['id', 'startMessageId', 'endMessageId'],
        where: 'conversationId = ?',
        whereArgs: [cid],
      );
      if (segs.isEmpty) continue;
      // 段的两个端点消息正常一定还在（压缩只从 prompt 里过滤、不删表行），
      // 一次把本片会话用到的端点时间查出来给判定函数用。
      final boundaryIds = <String>{
        for (final s in segs) ...[
          s['startMessageId'] as String? ?? '',
          s['endMessageId'] as String? ?? '',
        ]
      }..remove('');
      if (boundaryIds.isNotEmpty) {
        createdAtOf.addAll(await _createdAtByIds(txn, boundaryIds));
      }
      final drop = segmentsToDropForDeletedMessages(
          segments: segs, createdAtOf: createdAtOf, deletedIds: deletedIds);
      if (drop.isEmpty) continue;
      final ph = List.filled(drop.length, '?').join(',');
      await txn.delete('context_compaction_segments',
          where: 'id IN ($ph)', whereArgs: drop);
      _logger.db('删消息连带删压缩段 $drop（会话 $cid，按区间判定）');
    }
  }

  /// 一批消息 id 的 `createdAt`（删压缩段要用它判区间）。
  ///
  /// 为什么要分片：`IN (?,?,…)` 是**一条语句吃一批参数**，而 SQLite 对单条语句的
  /// 绑定变量数有上限（旧编译期默认 999）。会话里一次撤回几百条、
  /// 或压缩段攒了很多时，拼出一条超限的语句会**直接抛**，
  /// 而这里的调用点在事务里 ⇒ 抛出来就是"删除整个失败"，
  /// 比慢一点糟得多。400 一片留足余量（同一条语句还要放表名等其它参数）。
  Future<Map<String, String>> _createdAtByIds(
      DatabaseExecutor txn, Set<String> ids) async {
    final out = <String, String>{};
    const chunk = 400;
    final all = ids.toList();
    for (var i = 0; i < all.length; i += chunk) {
      final part = all.sublist(i, i + chunk > all.length ? all.length : i + chunk);
      final ph = List.filled(part.length, '?').join(',');
      for (final r in await txn.query('messages',
          columns: ['id', 'createdAt'], where: 'id IN ($ph)', whereArgs: part)) {
        if (r['id'] is String && r['createdAt'] is String) {
          out[r['id'] as String] = r['createdAt'] as String;
        }
      }
    }
    return out;
  }

  // v1.7.26 (E5)：批量删除消息用单事务包裹（撤回级联删除一批消息时保证原子性）
  Future<void> deleteMessagesByIds(List<String> ids) async {
    if (ids.isEmpty) return;
    final database = await db;
    await database.transaction((txn) async {
      final ph = List.filled(ids.length, '?').join(',');
      final rows = await txn.query(
        'messages',
        columns: ['conversationId'],
        where: 'id IN ($ph)',
        whereArgs: ids,
      );
      final conversationIds =
          rows.map((row) => row['conversationId']).whereType<String>().toSet();
      // build145（第 7 轮 P0-3 的同族）：这里原本对**每个受影响会话**执行
      // `WHERE conversationId = ?` 全删压缩段 —— 撤回一批消息 = 整个会话的
      // 历史摘要一起没。改为与 deleteMessage 同一套区间判定（一个语义一处实现）。
      await _dropCompactionSegmentsCovering(txn,
          conversationIds: conversationIds, deletedIds: ids.toSet());
      // B-008：批量删除同样补删挂在这些消息上的重试版本快照
      // build145：分片同 `_createdAtByIds` 的理由（IN 的绑定变量数有上限，
      // 撤回大批量时拼出超限语句会在事务里抛 ⇒ 整批删除失败）。
      for (var i = 0; i < ids.length; i += 400) {
        final part =
            ids.sublist(i, i + 400 > ids.length ? ids.length : i + 400);
        final pp = List.filled(part.length, '?').join(',');
        await txn.delete('message_versions',
            where: 'retryOfId IN ($pp)', whereArgs: part);
      }
      for (final id in ids) {
        await txn.delete('messages', where: 'id = ?', whereArgs: [id]);
      }
    });
    notifyListeners();
  }

  // v1.7.26 (E7)：清空会话消息时同步重置会话摘要与更新时间，
  // 避免"消息已删但会话列表仍显示旧 lastMessage/updatedAt"的不一致。
  Future<void> deleteMessagesByConversation(String conversationId) async {
    final database = await db;
    await database.transaction((txn) async {
      // B-008：清空会话消息时同步清掉该会话全部重试版本快照（会话行保留，
      // 否则 message_versions 成孤儿永久残留、且 _loadData 会把孤儿版本重装回内存）。
      await txn.delete('message_versions',
          where:
              'retryOfId IN (SELECT id FROM messages WHERE conversationId = ?)',
          whereArgs: [conversationId]);
      await txn.delete('messages',
          where: 'conversationId = ?', whereArgs: [conversationId]);
      await txn.delete('context_compaction_segments',
          where: 'conversationId = ?', whereArgs: [conversationId]);
      await txn.update('conversations',
          {'lastMessage': '', 'updatedAt': DateTime.now().toIso8601String()},
          where: 'id = ?', whereArgs: [conversationId]);
    });
    notifyListeners();
  }

  // ===== v1.7.26 (E3)：重试版本快照持久化（message_versions 表） =====

  /// 保存/覆盖一条重试版本快照（versionIndex 与内存 store 一致，1-based；
  /// 同 retryOfId+versionIndex 幂等覆盖）
  Future<void> saveMessageVersion(
      String retryOfId, int versionIndex, RetryVersion v) async {
    final database = await db;
    await database.insert(
      'message_versions',
      {
        'retryOfId': retryOfId,
        'versionIndex': versionIndex,
        'content': v.content,
        'reasoningSteps':
            json.encode(v.reasoningSteps.map((s) => s.toMap()).toList()),
        if (v.promptTokens != null) 'promptTokens': v.promptTokens,
        if (v.completionTokens != null) 'completionTokens': v.completionTokens,
        if (v.totalTokens != null) 'totalTokens': v.totalTokens,
        if (v.cacheReadTokens != null) 'cacheReadTokens': v.cacheReadTokens,
        if (v.cacheWriteTokens != null) 'cacheWriteTokens': v.cacheWriteTokens,
        if (v.cacheHitTokens != null) 'cacheHitTokens': v.cacheHitTokens,
        if (v.cacheMissTokens != null) 'cacheMissTokens': v.cacheMissTokens,
        'injectedWebSearchCount': v.injectedWebSearchCount,
        'showStaleFootnote': v.showStaleFootnote ? 1 : 0,
        'modelName': v.modelName,
        'searchSources':
            json.encode(v.searchSources.map((s) => s.toMap()).toList()),
        'savedAt': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 加载全部重试版本快照（按 retryOfId 分组、versionIndex 升序，
  /// 与进程内 _retryVersionStore 结构一致）
  Future<Map<String, List<RetryVersion>>> loadMessageVersions() async {
    final database = await db;
    final maps =
        await database.query('message_versions', orderBy: 'versionIndex ASC');
    final result = <String, List<RetryVersion>>{};
    for (final m in maps) {
      final retryOfId = m['retryOfId'] as String;
      final list = result.putIfAbsent(retryOfId, () => []);
      final reasoning = <ReasoningStep>[];
      final raw = m['reasoningSteps'] as String?;
      if (raw != null && raw.isNotEmpty && raw != '[]') {
        try {
          final decoded = json.decode(raw) as List;
          for (final item in decoded) {
            reasoning.add(ReasoningStep.fromMap(item as Map<String, dynamic>));
          }
        } catch (e) { debugPrint('catch 静默异常: $e'); }
      }
      final sourcesRaw = m['searchSources'] as String?;
      final sources = <SearchSource>[];
      if (sourcesRaw != null && sourcesRaw.isNotEmpty && sourcesRaw != '[]') {
        try {
          final decoded = json.decode(sourcesRaw) as List;
          for (final item in decoded) {
            sources.add(SearchSource.fromMap(item as Map<String, dynamic>));
          }
        } catch (e) { debugPrint('catch 静默异常: $e'); }
      }
      list.add(RetryVersion(
        content: m['content'] as String,
        reasoningSteps: reasoning,
        promptTokens: m['promptTokens'] as int?,
        completionTokens: m['completionTokens'] as int?,
        totalTokens: m['totalTokens'] as int?,
        cacheReadTokens: m['cacheReadTokens'] as int?,
        cacheWriteTokens: m['cacheWriteTokens'] as int?,
        cacheHitTokens: m['cacheHitTokens'] as int?,
        cacheMissTokens: m['cacheMissTokens'] as int?,
        injectedWebSearchCount: (m['injectedWebSearchCount'] as int?) ?? 0,
        showStaleFootnote: ((m['showStaleFootnote'] as int?) ?? 0) != 0,
        modelName: (m['modelName'] as String?) ?? '',
        searchSources: sources,
      ));
    }
    return result;
  }

  /// 撤回某条提问时清理其重试版本快照
  Future<void> deleteMessageVersions(String retryOfId) async {
    final database = await db;
    await database.delete('message_versions',
        where: 'retryOfId = ?', whereArgs: [retryOfId]);
  }

  Future<List<Map<String, dynamic>>> loadAllPlugins() async {
    final database = await db;
    return await database.query('plugins', orderBy: 'installedAt DESC');
  }

  Future<void> savePluginState(String id,
      {bool? enabled, String? metadataJson}) async {
    final database = await db;
    final values = <String, dynamic>{};
    if (enabled != null) {
      values['enabled'] = enabled ? 1 : 0;
    }
    if (metadataJson != null) {
      values['metadataJson'] = metadataJson;
    }
    if (values.isNotEmpty) {
      // v1.7.9 (M13 修复)：UPDATE 影响 0 行时兜底 INSERT
      // 系统插件（search/download/ask_user/self_check/answer）由 createBuiltinPluginRegistry
      // 只注册进内存、不写 plugins 表 → 旧逻辑 UPDATE 0 行 → 禁用状态重启后静默丢失
      final affected = await database
          .update('plugins', values, where: 'id = ?', whereArgs: [id]);
      if (affected == 0) {
        await database.insert(
          'plugins',
          {
            'id': id,
            'name': id,
            'version': '1.0.0',
            'source': 'system',
            'author': 'system',
            'description': 'built-in plugin state row',
            'enabled': values['enabled'] ?? 1,
            // build133（①）：**无条件**写入合法 JSON。
            // 此前是 `if (metadataJson != null)` 条件写入 ⇒ 系统插件（search/download/
            // ask_user/self_check/answer）首次 toggle 走的正是这条兜底 INSERT，
            // 该行 metadataJson 落成 NULL ⇒ 导出备份后导入端 `is! String` 判为坏数据、
            // 整行被 catch 丢掉 ⇒ 系统插件的禁用状态「导出→导入」后静默丢失。
            'metadataJson': metadataJson ?? '{}',
            'installedAt': DateTime.now().millisecondsSinceEpoch,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      notifyListeners();
    }
  }

  Future<Map<String, bool>> loadPluginStates() async {
    final database = await db;
    final maps = await database.query('plugins', columns: ['id', 'enabled']);
    final result = <String, bool>{};
    for (final m in maps) {
      // v1.7.16 修复：未来 schema 变动导致列值为 null 时，非空强转会抛 CastError
      // 使插件启用状态全丢；改为带默认值的宽松读取。
      final id = m['id'] as String? ?? '';
      final enabled = (m['enabled'] as int? ?? 1) == 1;
      if (id.isNotEmpty) result[id] = enabled;
    }
    return result;
  }

  Future<void> upsertPlugin(Map<String, dynamic> row) async {
    final database = await db;
    await database.insert('plugins', row,
        conflictAlgorithm: ConflictAlgorithm.replace);
    notifyListeners();
  }

  Future<void> deletePlugin(String id) async {
    final database = await db;
    await database.delete('plugins', where: 'id = ?', whereArgs: [id]);
    notifyListeners();
  }

  // ==================================================================
  // build101（C1 知识库 RAG）：知识库 / 切片 CRUD
  // ==================================================================

  Future<List<KnowledgeBase>> listKnowledgeBases() async {
    final database = await db;
    final rows = await database.query('knowledge_bases',
        orderBy: 'updatedAt DESC');
    return rows.map((r) => KnowledgeBase.fromMap(r)).toList();
  }

  Future<KnowledgeBase?> getKnowledgeBase(String id) async {
    final database = await db;
    final rows = await database.query('knowledge_bases',
        where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return KnowledgeBase.fromMap(rows.first);
  }

  /// build102（E）：全部「全局可用」（isPublic=1）的知识库。
  /// 发送链路 _buildKnowledgeContext 在会话绑定库之外追加这些库一起检索。
  Future<List<KnowledgeBase>> getPublicKnowledgeBases() async {
    final database = await db;
    final rows = await database.query('knowledge_bases',
        where: 'isPublic = 1', orderBy: 'updatedAt DESC');
    return rows.map((r) => KnowledgeBase.fromMap(r)).toList();
  }

  Future<void> upsertKnowledgeBase(KnowledgeBase kb) async {
    final database = await db;
    await database.insert('knowledge_bases', kb.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    notifyListeners();
  }

  /// 删除知识库并级联删除其全部切片。
  Future<void> deleteKnowledgeBase(String id) async {
    final database = await db;
    // build104（S7）：删库+切片+解绑会话引用包单事务——原实现不清
    // conversations.knowledgeBaseId，悬空绑定让 RAG 静默失效、设置页显示陈旧绑定
    //（deleteAssistant 早有解绑，本方法对齐其行为）
    await database.transaction((txn) async {
      await txn.delete('knowledge_chunks', where: 'kbId = ?', whereArgs: [id]);
      await txn.delete('knowledge_bases', where: 'id = ?', whereArgs: [id]);
      await txn.update('conversations', {'knowledgeBaseId': ''},
          where: 'knowledgeBaseId = ?', whereArgs: [id]);
    });
    notifyListeners();
  }

  /// 批量写入切片（单事务，避免逐条 insert 慢）。
  Future<void> insertKnowledgeChunks(List<KnowledgeChunk> chunks) async {
    if (chunks.isEmpty) return;
    final database = await db;
    await database.transaction((txn) async {
      final batch = txn.batch();
      for (final c in chunks) {
        batch.insert('knowledge_chunks', c.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
    notifyListeners();
  }

  Future<void> deleteChunksByDoc(String kbId, String docName) async {
    final database = await db;
    await database.delete('knowledge_chunks',
        where: 'kbId = ? AND docName = ?', whereArgs: [kbId, docName]);
    notifyListeners();
  }

  Future<int> countChunks(String kbId) async {
    final database = await db;
    final r = await database.rawQuery(
        'SELECT COUNT(*) AS c FROM knowledge_chunks WHERE kbId = ?', [kbId]);
    return (r.first['c'] as int?) ?? 0;
  }

  /// 列出某知识库的切片（用于管理页查看）。
  Future<List<KnowledgeChunk>> listChunks(String kbId, {int limit = 200}) async {
    final database = await db;
    final rows = await database.query('knowledge_chunks',
        where: 'kbId = ?',
        whereArgs: [kbId],
        orderBy: 'docName ASC, chunkIndex ASC',
        limit: limit);
    return rows.map((r) => KnowledgeChunk.fromMap(r)).toList();
  }

  /// 列出某知识库的文档名去重清单（带条数）。
  Future<List<({String docName, int count})>> listDocs(String kbId) async {
    final database = await db;
    final rows = await database.rawQuery(
      'SELECT docName, COUNT(*) AS c FROM knowledge_chunks WHERE kbId = ? '
      'GROUP BY docName ORDER BY docName ASC',
      [kbId],
    );
    return rows
        .map((r) => (
              docName: (r['docName'] as String?) ?? '',
              count: (r['c'] as int?) ?? 0,
            ))
        .toList();
  }

  /// 全量拉取某知识库切片向量（检索用；Dart 侧算余弦）。
  Future<List<KnowledgeChunk>> loadChunksForSearch(String kbId) async {
    final database = await db;
    final rows = await database.query('knowledge_chunks',
        where: 'kbId = ?', whereArgs: [kbId]);
    return rows.map((r) => KnowledgeChunk.fromMap(r)).toList();
  }

  // ==================================================================
  // build101（E10 用量统计）：按天聚合 token 消耗
  // ==================================================================

  /// 按「日期 × 模型」聚合 token 用量。
  ///
  /// 数据源是 messages 表已落库的 token 列（v1.7.26 C2 起持久化），
  /// 所以这里**不需要新表**——直接 SQL 聚合即可，历史数据自动覆盖。
  ///
  /// 按 `date(createdAt)` 分组而非在 Dart 里遍历，是因为消息可能上万条；
  /// SQLite 的日期函数够用且省一次全量加载。
  Future<List<UsageStat>> queryUsageStats({
    int days = 30,
  }) async {
    final database = await db;
    final since = DateTime.now()
        .subtract(Duration(days: days))
        .toIso8601String();
    final rows = await database.rawQuery('''
      SELECT
        substr(createdAt, 1, 10)              AS day,
        CASE WHEN modelName IS NULL OR modelName = '' THEN '(unknown)' ELSE modelName END AS model,
        COUNT(*)                              AS msgCount,
        SUM(COALESCE(promptTokens, 0))        AS promptTokens,
        SUM(COALESCE(completionTokens, 0))    AS completionTokens,
        SUM(COALESCE(totalTokens, 0))         AS totalTokens,
        SUM(COALESCE(cacheReadTokens, 0))     AS cacheReadTokens,
        SUM(COALESCE(cacheHitTokens, 0))      AS cacheHitTokens
      FROM messages
      WHERE role = 'assistant' AND createdAt >= ?
      GROUP BY day, model
      ORDER BY day DESC, totalTokens DESC
    ''', [since]);
    return rows
        .map((r) => UsageStat(
              day: (r['day'] as String?) ?? '',
              model: (r['model'] as String?) ?? '(unknown)',
              msgCount: (r['msgCount'] as int?) ?? 0,
              promptTokens: (r['promptTokens'] as int?) ?? 0,
              completionTokens: (r['completionTokens'] as int?) ?? 0,
              totalTokens: (r['totalTokens'] as int?) ?? 0,
              cacheReadTokens: (r['cacheReadTokens'] as int?) ?? 0,
              cacheHitTokens: (r['cacheHitTokens'] as int?) ?? 0,
            ))
        .toList();
  }

  /// 全时段总览（不按天分组）。
  Future<UsageStat> queryUsageTotal() async {
    final database = await db;
    final rows = await database.rawQuery('''
      SELECT
        COUNT(*)                           AS msgCount,
        SUM(COALESCE(promptTokens, 0))     AS promptTokens,
        SUM(COALESCE(completionTokens, 0)) AS completionTokens,
        SUM(COALESCE(totalTokens, 0))      AS totalTokens,
        SUM(COALESCE(cacheReadTokens, 0))  AS cacheReadTokens,
        SUM(COALESCE(cacheHitTokens, 0))   AS cacheHitTokens
      FROM messages
      WHERE role = 'assistant'
    ''');
    if (rows.isEmpty) return const UsageStat(day: '', model: '');
    final r = rows.first;
    return UsageStat(
      day: '',
      model: '',
      msgCount: (r['msgCount'] as int?) ?? 0,
      promptTokens: (r['promptTokens'] as int?) ?? 0,
      completionTokens: (r['completionTokens'] as int?) ?? 0,
      totalTokens: (r['totalTokens'] as int?) ?? 0,
      cacheReadTokens: (r['cacheReadTokens'] as int?) ?? 0,
      cacheHitTokens: (r['cacheHitTokens'] as int?) ?? 0,
    );
  }

  /// 按模型聚合（全时段）——「小模型省钱」这类判断的直接依据。
  Future<List<UsageStat>> queryUsageByModel() async {    final database = await db;
    final rows = await database.rawQuery('''
      SELECT
        CASE WHEN modelName IS NULL OR modelName = '' THEN '(unknown)' ELSE modelName END AS model,
        COUNT(*)                           AS msgCount,
        SUM(COALESCE(promptTokens, 0))     AS promptTokens,
        SUM(COALESCE(completionTokens, 0)) AS completionTokens,
        SUM(COALESCE(totalTokens, 0))      AS totalTokens,
        SUM(COALESCE(cacheReadTokens, 0))  AS cacheReadTokens,
        SUM(COALESCE(cacheHitTokens, 0))   AS cacheHitTokens
      FROM messages
      WHERE role = 'assistant'
      GROUP BY model
      ORDER BY totalTokens DESC
    ''');
    return rows
        .map((r) => UsageStat(
              day: '',
              model: (r['model'] as String?) ?? '(unknown)',
              msgCount: (r['msgCount'] as int?) ?? 0,
              promptTokens: (r['promptTokens'] as int?) ?? 0,
              completionTokens: (r['completionTokens'] as int?) ?? 0,
              totalTokens: (r['totalTokens'] as int?) ?? 0,
              cacheReadTokens: (r['cacheReadTokens'] as int?) ?? 0,
              cacheHitTokens: (r['cacheHitTokens'] as int?) ?? 0,
            ))
        .toList();
  }

  // ==================================================================
  // build101（E8 自定义助手）：assistants CRUD
  // ==================================================================

  Future<List<Assistant>> listAssistants() async {
    final database = await db;
    final rows =
        await database.query('assistants', orderBy: 'isBuiltin DESC, updatedAt DESC');
    return rows.map((r) => Assistant.fromMap(r)).toList();
  }

  Future<Assistant?> getAssistant(String id) async {
    if (id.isEmpty) return null;
    final database = await db;
    final rows = await database
        .query('assistants', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return Assistant.fromMap(rows.first);
  }

  Future<void> upsertAssistant(Assistant a) async {
    final database = await db;
    await database.insert('assistants', a.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    notifyListeners();
  }

  Future<void> deleteAssistant(String id) async {
    final database = await db;
    // build104（S10）：包单事务——原实现删除/解绑两条语句各自提交，
    // 中途失败会留半删状态（教训 #23 通则）
    await database.transaction((txn) async {
      await txn.delete('assistants', where: 'id = ?', whereArgs: [id]);
      // 解绑引用了该助手的会话，避免悬空 id
      await txn.update('conversations', {'assistantId': ''},
          where: 'assistantId = ?', whereArgs: [id]);
    });
    notifyListeners();
  }

  /// 首次使用时把内置预设落库。已存在任一 assistant 则跳过
  /// （用户删掉预设后不该被复活，所以判据是「表非空」而非「预设不存在」）。
  Future<void> ensureBuiltinAssistants({required bool zh}) async {
    final database = await db;
    final r = await database.rawQuery('SELECT COUNT(*) AS c FROM assistants');
    final count = (r.first['c'] as int?) ?? 0;
    if (count > 0) return;
    await database.transaction((txn) async {
      final batch = txn.batch();
      for (final a in Assistant.builtins(zh: zh)) {
        batch.insert('assistants', a.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
    notifyListeners();
  }
}
