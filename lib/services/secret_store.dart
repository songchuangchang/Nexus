/// build146（密钥入 Keystore）：**全应用唯一**一个「密钥跨越持久化边界」的地方。
///
/// 一、治的是什么
/// 改这一批之前，用户自己掏钱买的 LLM Key 是**明文躺在 SQLite 里**的
/// （`api_configs.apiKey` / `api_accounts.apiKey` / `web_search_configs` 的六个
/// provider Key），而 `flutter_secure_storage`（Android Keystore 背书）在整个仓库
/// 里只服务于一个第三方令牌（github_device_flow.dart）。也就是：别人的令牌有硬件
/// 保护，用户自己的 Key 没有。应用锁只是个 UI 闸门，对落库的字节**零加密作用**。
/// 对标 OWASP MSTG-STORAGE-1 / Android 官方「App data」指引：凭据必须走 Keystore。
///
/// 二、存储形状（为什么是「列留空串 + 保险库条目本身当 sidecar 标记」）
/// 不动 schema、不删列、不加列、不建新表、DB 版本号保持 39 —— 本仓库的迁移只能以
/// 纯函数 + 源码锚点的形式被验证（测试环境没有 sqflite_common_ffi），任何
/// schema 破坏性变更在这里都是**不可验证**的，而不可验证的 schema 变更正是本项目
/// 「三路同步」踩坑史的重灾区。可选的两条路里：
///   · 哨兵字符串（列里写 `secret:v1`）：**被否**。列里留一个非空串会毒化所有
///     「没走 hydrate 的读路径」和所有 `isNotEmpty` 判据 —— 最要命的是
///     `AccountGrouping` 拿 apiKey 当归组键、`fillFromAccount` 只补空不覆盖，
///     哨兵会被当成一把**真实的 Key** 复制进账号、进而复制进别的条目。
///   · 空串 + sidecar 标记：**采用**。而且不需要新表新列 —— 保险库里存在
///     `v1.<scope>.<rowId>.<field>` 这个键，本身就是「这一列已经迁过去了」的标记
///     （见 [contains]）。标记与值同源，永远不会出现「标记说有、值其实没有」。
/// 空串在**每一条现存读路径**上都是合法值（`apiKey.isEmpty ⇒ 本地服务/用账号补值`），
/// 所以「保险库读不到」的最坏结果是回到今天已经存在的一种状态，而不是新增崩溃面。
///
/// 三、键命名（前缀 v1 = 可前滚）
/// `v1.<scope>.<rowId>.<field>`，scope ∈ {api_config, api_account, web_search}。
/// 带版本号是为了将来换加密后端 / 换主密钥时能双读旧键、而不是撞上无法区分的脏键。
/// 本类**不**使用平台级 `aOptions/iOptions`（含 `synchronousKey`）：那套选项在部分
/// 机型上会让**同进程并发读写同一键**直接抛 IllegalArgumentException，而本类的写
/// 路径是会被并发触达的（`saveApiConfig` 一次写 1~N 个键）。
///
/// 四、失败姿态：**降级，绝不上抛**
/// [read] 失败给空串、[writeVerified] 失败给 [SecretWriteResult.failed]（调用方因此把明文留在原来那一列
/// 里，等于回到修复前的形态 —— 可用，只是没加密）、[deleteKey]/[deleteWhere] 失败
/// 只记一条 WARN。理由写在 [writeVerified] 的文档里：宁可明文可用，不可密钥凭空消失。
library secret_store;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'logger_service.dart';

/// 一次密钥读取的结果形态。**三态而不是两态**是本批最贵的一条教训（见
/// [SecretStore.readOutcome] 的头注：把"读不出来"压成"没有值"会让下一次保存
/// 把保险库条目连同列里的明文一起清掉）。
enum SecretReadResult {
  /// 保险库里确实没有这个键（用户没填 / 真清空了）。
  absent,

  /// 读到值。
  found,

  /// 读操作抛异常 ⇒ **值未知**。既不是"没填"也不是"空"：调用方必须保留列里现状，
  /// 且**不得**据此删除任何东西。
  failed,
}

/// [SecretStore.readOutcome] 的返回值。
@immutable
class SecretReadOutcome {
  const SecretReadOutcome(this.status, this.value);

  final SecretReadResult status;

  /// 只有 [SecretReadResult.found] 时非空。
  final String value;

  bool get isFound => status == SecretReadResult.found;
  bool get isUnknown => status == SecretReadResult.failed;
}

/// 一次密钥操作的成功/失败结果 —— 用于把「没验过」和「验证不通过」区分开，
/// 也让单测能注入失败而不必碰平台通道。
enum SecretWriteResult {
  /// 写入并读回比对成功：调用方可以把列里的明文抹掉。
  stored,

  /// 值为空 ⇒ 不需要保险库条目（等价于「用户清空的 Key」）。
  empty,

  /// 写入或读回比对失败：调用方**必须**保留列里的原值。
  failed,
}

/// 保险库后端：把平台通道抽走，使本类的四条失败路径（读不到 / 读抛 / 写抛 / 删不存在）
/// 在无插件环境的单测里可被真实驱动。
abstract class SecureVaultBackend {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);

  /// 全部现存键名；后端不可用时抛（调用方按「未知」处理，不得当作「空」）。
  Future<List<String>> keys();
}

/// 生产后端：`flutter_secure_storage`（Android EncryptedSharedPreferences + Keystore）。
class FlutterSecureVaultBackend implements SecureVaultBackend {
  const FlutterSecureVaultBackend();

  static const _storage = FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<List<String>> keys() async => (await _storage.readAll()).keys.toList();
}

/// 内存后端：单测与未来桌面端口用；**生产不走它**。
///
/// 三个 error 字段是**粘的**（设了就每次都抛，直到清空），这样「Keystore 整个不可用」
/// 这种持续性故障才能被真实驱动；一次性故障请用 [unreadableKeys]。
class InMemoryVaultBackend implements SecureVaultBackend {
  InMemoryVaultBackend([Map<String, String>? seed])
      : _map = <String, String>{...?seed};

  final Map<String, String> _map;

  /// 让 [write] 抛（覆盖写失败路径）。
  Object? writeError;

  /// 让 [read] 抛（覆盖读失败路径）。
  Object? readError;

  /// 让 [delete] 抛。
  Object? deleteError;

  /// 让 [keys] 抛（覆盖「列举失败 ⇒ 清扫必须不下刀」这条路径）。
  Object? keysError;

  /// 让指定键的 [read] 返回 null（键名还列得出来，但值解不出来 = Keystore
  /// 半死的样子）。孤儿清扫的「读不回值就不许删」自证走这条。
  final Set<String> unreadableKeys = <String>{};

  /// 只读快照，断言用。
  Map<String, String> get snapshot => Map<String, String>.unmodifiable(_map);

  /// 清掉全部注入的故障。
  void clearErrors() {
    writeError = null;
    readError = null;
    deleteError = null;
    keysError = null;
  }

  @override
  Future<String?> read(String key) async {
    final err = readError;
    if (err != null) throw err;
    if (unreadableKeys.contains(key)) return null;
    return _map[key];
  }

  @override
  Future<void> write(String key, String value) async {
    final err = writeError;
    if (err != null) throw err;
    _map[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    final err = deleteError;
    if (err != null) throw err;
    _map.remove(key);
  }

  @override
  Future<List<String>> keys() async {
    final err = keysError;
    if (err != null) throw err;
    return _map.keys.toList();
  }
}

/// 单条密钥的落库坐标：哪张表、哪一列、哪一行、值是什么。
@immutable
class SecretLocation {
  const SecretLocation({
    required this.scope,
    required this.rowId,
    required this.table,
    required this.column,
  });

  /// 键名的格式版本（本类全部键的唯一前缀）。
  static const String keyFormatVersion = 'v1';

  /// 表名（仅用于把「清列」这件事写成一条可测的语句，见 [SecretMigrationOp]）。
  final String table;

  /// 存密钥的那一列（`apiKey` / `tavilyApiKey` / …）。
  final String column;

  /// 归属域：[SecretStore.apiConfigScope] / [SecretStore.apiAccountScope] /
  /// [SecretStore.webSearchScope]。
  final String scope;

  /// 行主键（web_search 是单例行 ⇒ 固定 'singleton'）。
  final String rowId;

  String get fieldKey => '$scope.$rowId.$column';

  /// 保险库里的实际键名。格式版本号写在 [keyFormatVersion] 一处，
  /// 将来换加密后端要双读旧键时只改那一处。
  String get vaultKey => '$keyFormatVersion.$fieldKey';

  @override
  String toString() => 'SecretLocation($fieldKey)';

  @override
  bool operator ==(Object other) =>
      other is SecretLocation && other.fieldKey == fieldKey;

  @override
  int get hashCode => fieldKey.hashCode;
}

/// 「这个对象身上带着密钥」的最小契约 —— 让 StorageService 用**一份**代码处理
/// 条目 / 账号 / 搜索配置三类对象，而不是把搬运逻辑抄三遍
/// （抄三遍 = 将来加第四类时漏一类，那是本仓库最高频的故障形）。
///
/// 实现者：`ApiConfig` / `ApiAccount` / `WebSearchConfig`。
abstract interface class SecretBearing {
  /// 本对象携带的密钥坐标（可以不止一把）。
  List<SecretLocation> secretLocations();

  /// [loc] 这个坐标上当前存着什么值（内存里的真值）。
  String secretValueAt(SecretLocation loc);

  /// 读路径：把保险库里的值回填进本对象。
  void applySecret(SecretLocation loc, String value);

  /// 本次读取里**值未知**的字段名（[SecretReadResult.failed] 的那些）。
  ///
  /// 为什么挂在对象上而不是函数的返回值里：这个事实必须在**整个对象生命周期**里
  /// 成立 —— 读出来（未知）→ 递给 UI → UI 拨了个不相干的开关 → 原样写回，
  /// 这条写回路径必须看得见"那把 Key 我其实没读到"，否则就会把未知当清空去删（P0）。
  /// 不落库、不参与 `toMap`/`fromMap` 往返，纯内存标记。
  Set<String> get unreadableSecrets;

  /// 完整语义的 map：密钥列带真值。备份导出（勾选含密钥）与
  /// 「保险库写不进去时退回明文落库」两条路用它。
  Map<String, dynamic> toMap();

  /// 落库形状的 map：密钥列抹成空串。只有保险库写入校验通过后才允许用它。
  Map<String, dynamic> toRowMap();
}

/// 迁移的一条操作：把 [plaintext] 搬进 [location] 指向的保险库键。
@immutable
class SecretMigrationOp {
  const SecretMigrationOp({
    required this.location,
    required this.plaintext,
    required this.vaultAlreadyMatched,
  });

  final SecretLocation location;

  /// 列里现存的明文（保证非空 —— 空的列不进计划）。
  final String plaintext;

  /// 保险库里已经存着**逐字相同**的值：复制阶段可跳过，但**清列仍然要做**。
  /// 这正是幂等性的来源：第一次跑完列被清空 ⇒ 第二次连计划都没有；
  /// 中途崩在「已复制、未清列」之间 ⇒ 第二次命中这个标记、只补清列。
  final bool vaultAlreadyMatched;

  @override
  String toString() =>
      'SecretMigrationOp(${location.fieldKey}${vaultAlreadyMatched ? ' verify-only' : ''})';
}

/// 一次迁移的产出统计（**不**含任何密钥内容，可安全进日志）。
@immutable
class SecretMigrationReport {
  const SecretMigrationReport({
    this.planned = 0,
    this.copied = 0,
    this.cleared = 0,
    this.failed = 0,
    this.keysWithoutValue = const [],
  });

  final int planned;

  /// 实际往保险库写了几条（[SecretMigrationOp.vaultAlreadyMatched] 的算没写）。
  final int copied;

  /// 实际抹掉了几条列内明文。
  final int cleared;

  /// 复制/校验/清列任一环节失败几条（这些行**保留明文**，功能不受影响）。
  final int failed;

  /// 保险库里有值、但库里已无对应行的**键名**（孤儿残留候选，不含值）。
  final List<String> keysWithoutValue;

  bool get hasWork => planned > 0;

  @override
  String toString() =>
      'SecretMigrationReport(planned=$planned copied=$copied '
      'cleared=$cleared failed=$failed orphans=${keysWithoutValue.length})';
}

/// 迁移计划器：纯函数，输入是「列里现存的值」+「保险库里现存的值」两份事实。
///
/// 三条不变量，逐条对应 build146 的验收：
/// ① **幂等**：只给「列里非空」的行出计划。跑成功一次后列变空 ⇒ 第二次计划为空。
/// ② **跳过已迁标记**：列里已是空串的永不进计划；保险库里已有同值的行打上
///    [SecretMigrationOp.vaultAlreadyMatched]，执行器据此跳过重复写入。
/// ③ **计划阶段永不含「未校验就清列」**：这里只产出「要搬哪条」，清列权在
///    [runSecretMigration]，而它只在校验通过后清。
List<SecretMigrationOp> planSecretMigration({
  required Iterable<SecretLocation> locations,
  required String? Function(SecretLocation loc) columnValueOf,
  required String? Function(SecretLocation loc) vaultValueOf,
}) {
  final ops = <SecretMigrationOp>[];
  final seen = <String>{};
  for (final loc in locations) {
    // 同一坐标在输入里出现多次（理论上不该，防一手）：只处理第一次，
    // 否则第二次会拿着已被改成的空值再算一遍。
    if (!seen.add(loc.fieldKey)) continue;
    final plain = columnValueOf(loc)?.trim() ?? '';
    if (plain.isEmpty) continue; // 已迁过 / 本来就没填 —— 什么都不做
    final inVault = vaultValueOf(loc)?.trim() ?? '';
    ops.add(SecretMigrationOp(
      location: loc,
      plaintext: plain,
      vaultAlreadyMatched: inVault == plain,
    ));
  }
  // 稳定序：计划的可重复性不该依赖 Map 的遍历顺序。
  ops.sort((a, b) =>
      a.location.fieldKey.compareTo(b.location.fieldKey));
  return ops;
}

/// 迁移执行器：**复制 → 读回校验 → 才清列**，任何一步不过就把该行原样留在明文里。
///
/// 为什么单独做成函数（而不是在 [StorageService] 里内联三行）：
/// 「永不为未校验的行发清列」是本批最值钱的一条不变量 —— 违反它的后果是用户的 Key
/// 直接没了（比明文存储严重得多）。做成可注入 copy/verify/clear 三个回调之后，
/// 这条不变量就能在单测里被**真行为**钉死（喂一个必失败的 copy，断言 clear 一次没调）。
Future<SecretMigrationReport> runSecretMigration({
  required List<SecretMigrationOp> ops,
  required Future<bool> Function(SecretMigrationOp op) copyToVault,
  required Future<String?> Function(SecretMigrationOp op) readBackFromVault,
  required Future<void> Function(SecretMigrationOp op) clearColumn,
  FutureOr<void> Function(SecretMigrationOp op, Object error)? onFailure,
}) async {
  var copied = 0;
  var cleared = 0;
  var failed = 0;
  for (final op in ops) {
    try {
      if (!op.vaultAlreadyMatched) {
        final ok = await copyToVault(op);
        if (!ok) {
          failed++;
          await _notify(onFailure, op, const _VaultWriteRejected());
          continue;
        }
        copied++;
      }
      final back = (await readBackFromVault(op))?.trim() ?? '';
      if (back != op.plaintext) {
        // 校验不过 ⇒ 绝不抹列。宁可明文继续存着。
        failed++;
        await _notify(onFailure, op, const _VerifyMismatch());
        continue;
      }
      await clearColumn(op);
      cleared++;
    } catch (e) {
      failed++;
      await _notify(onFailure, op, e);
    }
  }
  return SecretMigrationReport(
    planned: ops.length,
    copied: copied,
    cleared: cleared,
    failed: failed,
  );
}

Future<void> _notify(
    FutureOr<void> Function(SecretMigrationOp, Object)? onFailure,
    SecretMigrationOp op,
    Object error) async {
  final cb = onFailure;
  if (cb == null) return;
  try {
    await cb(op, error);
  } catch (e) {
    debugPrint('[SecretStore] onFailure 回调自身抛了（已忽略）: $e');
  }
}

class _VaultWriteRejected implements Exception {
  const _VaultWriteRejected();
}

class _VerifyMismatch implements Exception {
  const _VerifyMismatch();
}

/// 保险库本体。生产走 [SecretStore.instance]；单测自己 `new` 一个换后端。
class SecretStore {
  SecretStore({SecureVaultBackend? backend, void Function(String warn)? warn})
      : _backend = backend ?? const FlutterSecureVaultBackend(),
        _warn = warn ?? _defaultWarn;

  // ── scope 常量：跨文件引用时只允许用这三个名字 ──
  static const String apiConfigScope = 'api_config';
  static const String apiAccountScope = 'api_account';
  static const String webSearchScope = 'web_search';

  /// [webSearchScope] 的行主键是单例固定值。
  static const String webSearchRowId = 'singleton';

  /// 键名前缀（第 3 位是格式版本号，换加密后端时递增并可双读）。
  static const String keyPrefix = '${SecretLocation.keyFormatVersion}.';

  /// 与本类无关的、已知的历史键（GitHub Device Flow 令牌）。
  /// 孤儿清扫必须**跳过**非 [keyPrefix] 的键，故这里不需要列出来；
  /// 留在测试里当「不许越界删除」的锚点。
  static const String foreignGithubTokenKey = 'github_device_flow_token';

  static final SecretStore instance = SecretStore();

  SecureVaultBackend _backend;
  final void Function(String warn) _warn;

  /// 测试注入点：换掉平台通道后端，让四条失败路径（读不到 / 读抛 / 写抛 / 删不存在）
  /// 在无插件、无 Android 环境的单测里被**真行为**驱动。生产代码不得调用 ——
  /// build146 的源码锚点用例钉住「除本文件外无人调用它」。
  @visibleForTesting
  void useBackendForTesting(SecureVaultBackend backend) {
    _backend = backend;
    _failureEpoch = 0;
  }

  /// 测试注入点：清掉失败计数纪元（每次 setUp 用一次，断言才不被上一条用例污染）。
  @visibleForTesting
  void resetFailuresForTesting() => _failureEpoch = 0;

  /// 上一次任何操作失败的纪元。孤儿清扫据此拒绝在「保险库不可信」时下刀。
  int _failureEpoch = 0;

  /// 供外部（StorageService）读取的失败计数纪元；只增不减。
  int get failureEpoch => _failureEpoch;


  /// 生产默认告警出口：**必须进 LoggerService**，不许只 `debugPrint`。
  ///
  /// build147 第 11 轮审查（P2）：这一行原来是 `debugPrint` ⇒ release 包里四条失败路径
  /// （读抛 / 写抛 / 回读不一致 / 删抛）**在用户导出的日志里一行都没有**，
  /// 而我给用户的验收说明写的恰恰是"导出日志搜那一句"。降级可以接受，
  /// 不可见的降级不行（本仓库病族：「静默 = 不可排查」）。
  /// 注入的 `_warn`（单测用）优先；这里只在未被注入时兜到真日志。
  static void _defaultWarn(String m) {
    debugPrint('[SecretStore] WARN $m');
    LoggerService.instance.warn('[SecretStore] $m', cat: LogCat.db, tag: 'KSec');
  }

  /// 键名派生：`v1.<scope>.<rowId>.<field>`。值为空串时不要调用写入（见 [writeVerified]）。
  String keyFor(SecretLocation loc) => loc.vaultKey;

  /// 按 scope + rowId 拼删除前缀（删一行 = 删它这个 scope 下的所有字段键）。
  String prefixFor({required String scope, required String rowId}) =>
      '$keyPrefix$scope.$rowId.';

  bool _isVaultKey(String key) => key.startsWith(keyPrefix);

  /// 读一条密钥并把**三种"没有值"区分开**。
  ///
  /// build147 第 11 轮审查（P0）：本类原来只有一个 [read]，"读不到"与"读抛"都塌成
  /// 空串 —— 而空串在保存路径上的语义是**「用户清空了这把 Key」**，会顺手把保险库
  /// 条目删掉（见 [writeVerified] 的空值分支）。于是这条链成立：
  ///   Keystore 抖一次（同进程并发读同键在部分机型会抛，见文件头注）
  ///   ⇒ 某条配置的 Key 在内存里成了空串
  ///   ⇒ 用户做了一件**毫不相干**的保存（拨一下联网搜索开关 / 改应用锁 / 调日志设置，
  ///     这些都是"读整份单例→改一个字段→写回"）
  ///   ⇒ 保险库条目被删 **且** 列里落的也是空串 ⇒ **两把副本同时消失**。
  /// 那是"Key 凭空消失"，正是本批存在的理由所要防的事，所以必须把"我不知道"
  /// 单独成一个态，而不是压成"没有"。调用方见 `StorageService._hydrateSecrets`。
  Future<SecretReadOutcome> readOutcome(SecretLocation loc) async {
    final key = keyFor(loc);
    try {
      final v = await _backend.read(key);
      final s = (v ?? '').trim();
      return s.isEmpty
          ? const SecretReadOutcome(SecretReadResult.absent, '')
          : SecretReadOutcome(SecretReadResult.found, s);
    } catch (e) {
      _failureEpoch++;
      _warn('读取 $key 抛错 ⇒ 值未知（不得当成"没填"，也不得据此删除）: $e');
      return const SecretReadOutcome(SecretReadResult.failed, '');
    }
  }

  /// 读一条密钥。读不到 / 抛异常 ⇒ 一律空串，**绝不上抛**。
  ///
  /// 这是聊天主链路每轮都会经过的方法：Keystore 坏了的表现只能是「这把 Key 没了」
  /// （调用方据此回退列里的明文或报未配置），不能是崩一轮对话。
  Future<String> read(SecretLocation loc) async {
    final key = keyFor(loc);
    try {
      final v = await _backend.read(key);
      return v ?? '';
    } catch (e) {
      _failureEpoch++;
      _warn('读取 $key 失败，按空处理: $e');
      return '';
    }
  }

  /// 保险库里是否存在该键（「已迁标记」的判据）。
  ///
  /// 与 [read] 的区别只在语义：这里要的是存在性。后端不可用时返回 false 并计一次
  /// 失败 —— 调用方**不得**据此删任何东西（见 [findOrphanKeys] 的自证逻辑）。
  Future<bool> contains(SecretLocation loc) async {
    final key = keyFor(loc);
    try {
      return (await _backend.read(key)) != null;
    } catch (e) {
      _failureEpoch++;
      _warn('存在性探测 $key 失败，按不存在处理: $e');
      return false;
    }
  }

  /// 写入并**读回逐字比对**。返回 true 才允许调用方抹掉列里的明文。
  ///
  /// 为什么把校验做进写入而不是留给迁移阶段：保存路径同样必须「验过再抹」——
  /// 用户改 Key 时如果 Keystore 正在坏，写失败而不回读比对的话，列已经被抹成空串，
  /// 新 Key 就地丢失。返回 false ⇒ 调用方保留明文（降级为旧行为）。
  Future<SecretWriteResult> writeVerified(
      SecretLocation loc, String? valueRaw) async {
    // 落库前统一 trim：UI 侧本来就是 trim 之后才传进来的，这里再兜一道是为了
    // 「只有全空白才算没填」这条判据在保存/迁移/导入三路上完全一致 ——
    // 否则 '   ' 会被当成一把真 Key 存进保险库，而列里被抹成空串。
    final value = (valueRaw ?? '').trim();
    if (value.isEmpty) {
      // 空值不进保险库：把它当「用户清了这个 Key」，顺手删掉旧条目。
      await deleteKey(loc);
      return SecretWriteResult.empty;
    }
    final key = keyFor(loc);
    try {
      await _backend.write(key, value);
    } catch (e) {
      _failureEpoch++;
      _warn('写入 $key 失败，保留列内原值: $e');
      return SecretWriteResult.failed;
    }
    try {
      final back = await _backend.read(key);
      if (back == value) return SecretWriteResult.stored;
      _failureEpoch++;
      _warn('回读比对不一致（$key），保留列内原值；不删除保险库条目以免误伤并发写入');
      return SecretWriteResult.failed;
    } catch (e) {
      _failureEpoch++;
      _warn('回读 $key 抛错，保留列内原值: $e');
      return SecretWriteResult.failed;
    }
  }

  /// 删一条密钥。键不存在 = 成功（幂等），不记 WARN、不计失败。
  Future<void> deleteKey(SecretLocation loc) async {
    final key = keyFor(loc);
    try {
      await _backend.delete(key);
    } catch (e) {
      _failureEpoch++;
      _warn('删除 $key 失败（不影响功能，最多残留一条读不到的条目）: $e');
    }
  }

  /// 删一整行的所有字段键（删除配置/账号时调用）。
  ///
  /// 顺序约定（**必须**在 DB 行删除成功之后调）：反过来做的话，一旦行删除回滚，
  /// Key 已经从保险库消失而行还在 ⇒ 用户的 Key 凭空失效。
  Future<int> deleteWhere({
    required String scope,
    required String rowId,
  }) async {
    final prefix = prefixFor(scope: scope, rowId: rowId);
    List<String> keys;
    try {
      keys = await _backend.keys();
    } catch (e) {
      _failureEpoch++;
      _warn('列举键失败，$prefix* 未清理: $e');
      return 0;
    }
    var n = 0;
    for (final key in keys) {
      if (!_isVaultKey(key) || !key.startsWith(prefix)) continue;
      try {
        await _backend.delete(key);
        n++;
      } catch (e) {
        _failureEpoch++;
        _warn('删除 $key 失败: $e');
      }
    }
    return n;
  }

  /// 保险库里的全部本类键名（不含值）。失败返回 null（= 未知，不是空）。
  Future<List<String>?> listKeys() async {
    try {
      return (await _backend.keys())
          .where(_isVaultKey)
          .toList(growable: false);
    } catch (e) {
      _failureEpoch++;
      _warn('列举键失败: $e');
      return null;
    }
  }

  /// 读一条键的原始值（孤儿清扫的「值还在不在」自证用）。
  Future<String?> readRaw(String key) async {
    try {
      return await _backend.read(key);
    } catch (e) {
      _failureEpoch++;
      _warn('读取 $key 失败（孤儿清扫按不可信处理）: $e');
      return null;
    }
  }

  /// 孤儿候选：键名指向的行已经不在了。
  ///
  /// 返回的是**候选**而不是结论 —— 只有 [sweepOrphans] 里逐条重新读取到值
  /// （证明该键此刻确实可被本 keystore 解密）之后才会真删。
  /// 这一条是「孤儿清理」与「批量删 Key」之间的分界线：宁可留一条无主条目
  /// （无害，占几十字节），也不能在快照不可信时把好 Key 删掉。
  Future<List<String>> findOrphanKeys(
      {required bool Function(String key) isOrphan}) async {
    final all = await listKeys();
    if (all == null) return const [];
    return [for (final k in all) if (isOrphan(k)) k];
  }

  /// 删一批键（孤儿清扫 / 导入回滚共用）。
  ///
  /// [requireReadable] 为真时，只删「刚刚独立读回过值」的键：任何一条读不出来
  /// （Keystore 半死、快照与现状不一致）就跳过删除。返回实删条数。
  Future<int> deleteKeys(List<String> keys,
      {bool requireReadable = true}) async {
    if (keys.isEmpty) return 0;
    var removed = 0;
    for (final key in keys) {
      if (!_isVaultKey(key)) {
        // 越界保护：github_device_flow 的令牌不归本类管，任何路径都不许顺手删。
        _warn('拒绝删除非本类键 $key');
        continue;
      }
      if (requireReadable) {
        final v = await readRaw(key);
        if (v == null) {
          _warn('孤儿键 $key 读不回值，跳过删除（保险库快照不可信）');
          continue;
        }
      }
      try {
        await _backend.delete(key);
        removed++;
      } catch (e) {
        _failureEpoch++;
        _warn('删除 $key 失败: $e');
      }
    }
    return removed;
  }

  /// 把 `v1.<scope>.<rowId>.<field>` 拆回 (scope, rowId, field)；不是本类格式返回 null。
  static ({String scope, String rowId, String field})? parseKey(String key) {
    if (!key.startsWith(keyPrefix)) return null;
    final body = key.substring(keyPrefix.length);
    final first = body.indexOf('.');
    final last = body.lastIndexOf('.');
    if (first <= 0 || last <= first) return null;
    final scope = body.substring(0, first);
    final rowId = body.substring(first + 1, last);
    final field = body.substring(last + 1);
    if (scope.isEmpty || rowId.isEmpty || field.isEmpty) return null;
    return (scope: scope, rowId: rowId, field: field);
  }
}
