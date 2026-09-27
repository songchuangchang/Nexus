import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../services/secret_store.dart';
import 'api_config.dart';
import 'api_provider_template.dart';

/// build138 · G44/G45（任务书 §三）：**账号层**的数据模型与归组逻辑。
///
/// 一、为什么要这一层（不是「重构瘾」）
/// 改动前「一条 [ApiConfig] = 一个模型」，同厂商两个模型就得建两条配置、
/// **抄两遍 Key**。三个直接后果，全是本项目的老病根：
/// ① 改 Key 要逐条改，漏一条就是 401（用户实测重复建配置的起因）；
/// ② 余额按 config.id 缓存 ⇒ 同账号 N 个模型就发 N 次余额请求；
/// ③ 在线拉取的模型列表（cachedModels）只挂在其中一条上，另几条看不见。
/// 任务书 §二 要的「一级厂商、二级模型、一把 Key 多模型」在没有账号层的前提下
/// 只能做成 UI 分组、Key 仍然冗余 —— 所以这一层是**数据层**的，不是视图层的。
///
/// 二、刻意**不动**会话引用链（§三 的推荐方案，原样采纳）
/// `conversations.apiConfigId` / `video_tasks.apiConfigId` 继续指向
/// [ApiConfig.id]：会话仍然引用「模型条目」。账号层只承载「连接身份」
/// （地址 / Key / 在线模型列表），条目上那几列**保留做回退冗余**、不删列 ——
/// 删列等于把老库和历史备份文件一起废掉，收益只是「看起来干净」。
///
/// 三、归并键（§三.2）与安全红线，见下面 [AccountGrouping.bucketOf]。
class ApiAccount implements SecretBearing {
  ApiAccount({
    required this.id,
    required this.templateId,
    required this.name,
    this.baseUrl = '',
    this.apiKey = '',
    this.cachedModels = '',
    this.createdAt = '',
  });

  factory ApiAccount.create({
    String templateId = ApiProviderTemplate.customId,
    String name = '',
    String baseUrl = '',
    String apiKey = '',
    List<String> cachedModels = const [],
  }) {
    return ApiAccount(
      id: const Uuid().v4(),
      templateId: templateId,
      name: name,
      baseUrl: baseUrl,
      apiKey: apiKey,
      cachedModels: cachedModels.isEmpty ? '' : jsonEncode(cachedModels),
      createdAt: DateTime.now().toIso8601String(),
    );
  }

  /// 空账号：新建账号时给同步函数当「旧值」用（旧值全空 ⇒ 子条目全部跟随新值）。
  static ApiAccount empty() => ApiAccount(id: '', templateId: '', name: '');

  final String id;
  String templateId;
  String name;
  String baseUrl;

  /// 连接密钥。build146 起落库时不进 `api_accounts.apiKey` 列（列抹成空串），
  /// 真值在 [secretLocations] 指向的保险库键里；内存里仍是真值，
  /// 因此 `AccountGrouping` 的归组判据、`usable`、请求头拼装的口径**一个都没变**。
  String apiKey;

  /// 在线 `GET /v1/models` 拉到的模型 id 列表（JSON 字符串，与
  /// [ApiConfig.cachedModels] 同一格式）。归账号不归条目：它是**端点**的属性。
  String cachedModels;
  String createdAt;

  bool get isCustom =>
      templateId.isEmpty || templateId == ApiProviderTemplate.customId;

  /// 这条账号是否至少像个连接（本地厂商不需要 Key，其余通常有地址）。
  bool get usable => baseUrl.trim().isNotEmpty || apiKey.trim().isNotEmpty;

  List<String> get cachedModelsList {
    if (cachedModels.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(cachedModels);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).toList(growable: false);
      }
    } catch (e) {
      _logBrokenJson(e);
    }
    return const [];
  }

  /// 坏 JSON 只可能来自旧版本写坏的缓存：不抛（否则设置页整页白屏），
  /// 但必须留痕 —— 本项目的教训是「catch 里静默」会让人查不到现场。
  static void _logBrokenJson(Object e) {
    debugPrint('[ApiAccount] cachedModels 不是合法 JSON，已按空列表处理: $e');
  }

  void setCachedModels(List<String> models) {
    cachedModels = models.isEmpty ? '' : jsonEncode(models);
  }

  @override
  Map<String, dynamic> toMap() => {
        'id': id,
        'templateId': templateId,
        'name': name,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'cachedModels': cachedModels,
        'createdAt': createdAt,
      };

  // ==========================================================================
  // build146（密钥入 Keystore）：与 [ApiConfig] 同一套分工 —— toMap 带真值（备份 /
  // 分享 / 重建用），[toRowMap] 抹空密钥列（落库用），[applySecret] 读路径回填。
  // 判据「这把 Key 是不是我的」全部读的是内存里的 [apiKey]，所以保险库化对
  // 归组逻辑（[AccountGrouping.plan] / [AccountGrouping.resolveExisting]）
  // 完全透明 —— 前提是**调用方喂进来的是已 hydrate 的账号**（StorageService 负责）。
  // ==========================================================================

  /// 本账号携带的密钥坐标（当前只有 `apiKey` 一把）。
  @override
  List<SecretLocation> secretLocations() => [
        SecretLocation(
          scope: SecretStore.apiAccountScope,
          rowId: id,
          table: 'api_accounts',
          column: 'apiKey',
        ),
      ];

  /// [loc] 这个坐标上当前存着什么值。
  @override
  String secretValueAt(SecretLocation loc) => apiKey;

  /// 本次生命周期里**保险库没读到值**的字段名（区别于「用户清空」，
  /// 见 [SecretReadResult.failed]）。纯内存标记，不进 `toMap` / 不落库。
  @override
  final Set<String> unreadableSecrets = <String>{};

  /// 把保险库读到的值回填进本账号（[loc] 不属于本账号 / 值为空时不动）。
  @override
  void applySecret(SecretLocation loc, String value) {
    if (loc.rowId != id) return;
    if (loc.column == 'apiKey' &&
        loc.scope == SecretStore.apiAccountScope &&
        value.trim().isNotEmpty) {
      apiKey = value;
    }
  }

  /// 落库用的一行：密钥列抹成空串。
  @override
  Map<String, dynamic> toRowMap() => toMap()..['apiKey'] = '';

  factory ApiAccount.fromMap(Map<String, dynamic> map) => ApiAccount(
        id: (map['id'] as String?) ?? const Uuid().v4(),
        templateId:
            (map['templateId'] as String?) ?? ApiProviderTemplate.customId,
        name: (map['name'] as String?) ?? '',
        baseUrl: (map['baseUrl'] as String?) ?? '',
        apiKey: (map['apiKey'] as String?) ?? '',
        cachedModels: (map['cachedModels'] as String?) ?? '',
        createdAt: (map['createdAt'] as String?) ?? '',
      );

  ApiAccount copyWith({
    String? id,
    String? templateId,
    String? name,
    String? baseUrl,
    String? apiKey,
    String? cachedModels,
    String? createdAt,
  }) =>
      ApiAccount(
        id: id ?? this.id,
        templateId: templateId ?? this.templateId,
        name: name ?? this.name,
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
        cachedModels: cachedModels ?? this.cachedModels,
        createdAt: createdAt ?? this.createdAt,
      )
      // build152（D1，P0）：同 `web_search_config.dart` 的注释。
      // 本文件这条走的是 `AccountGrouping.syncChildren` —— 归组/改连接身份时
      // 子条目全部由 copyWith 重建，标记一丢，下一次落库就把"读不到的那格"当真清空。
      ..unreadableSecrets.addAll(unreadableSecrets);

  /// 展示用的一行摘要（一级/二级页共用，避免两处各写一遍判空）。
  String get subtitleText {
    final url = baseUrl.trim();
    return url.isEmpty ? '(local / no URL)' : url;
  }
}

/// 一个账号 + 归到它名下的模型条目 id。
@immutable
class AccountPlan {
  const AccountPlan({required this.account, required this.configIds});

  final ApiAccount account;
  final List<String> configIds;

  @override
  String toString() =>
      'AccountPlan(${account.id}, tpl=${account.templateId}, '
      'models=${configIds.length})';
}

/// 归组纯函数（G44 的门禁全打在这里，不碰数据库）。
///
/// 为什么做成纯函数：本仓库测试环境没有 `sqflite_common_ffi`
/// （见 `test/memory_matrix_test.dart` 开头的环境约束说明），真 SQL 迁移在单测里
/// 跑不起来。把「谁和谁归为一个账号、Key 取哪一条」抽出来之后，G44 的三条断言里
/// 前两条能在这里钉死；第三条（会话引用不悬空）靠迁移函数只
/// `UPDATE api_configs SET accountId`、不碰 conversations 的源码锚点钉住。
class AccountGrouping {
  AccountGrouping._();

  /// 连接身份里的「host 段」：小写、含端口、去路径。
  ///
  /// 为什么含端口：`localhost:11434`（Ollama）与 `localhost:1234`（LM Studio）
  /// 是两台服务，只取 host 会把它们合成一个账号、其中一台 Key 被另一台顶掉。
  /// 为什么去路径：`.../api/paas/v4` 与 `.../api/paas/v4/` 是同一条连接，
  /// 带路径归组会因为用户多打一个斜杠就多一张卡。
  static String hostKey(String baseUrl) {
    final raw = baseUrl.trim();
    if (raw.isEmpty) return '';
    final uri = Uri.tryParse(raw);
    final host = (uri?.host ?? '').toLowerCase();
    if (host.isEmpty) {
      // 不是合法 URL（手填片段 / 裸 host）：退化成去尾斜杠的原文小写，
      // 保证「同样的输入 ⇒ 同样的键」，归组幂等比键好不好看重要。
      return raw.replaceAll(RegExp(r'/+$'), '').toLowerCase();
    }
    // Uri.port 是 int：没写端口时返回该 scheme 的默认端口（未知 scheme 为 0）。
    // 所以 `https://x` 与 `https://x:443` 会归到同一个键，而
    // `localhost:11434` 与 `localhost:1234` 必然分开（这是端口进键的全部理由）。
    final port = uri!.port;
    return port == 0 ? host : '$host:$port';
  }

  /// 归并桶（**不含 Key**）：任务书 §三.2 的归并键 + 施工时收紧的 host 段。
  static String bucketOf({required String templateId, required String baseUrl}) {
    final t = templateId.trim();
    final host = hostKey(baseUrl);
    if (t.isEmpty || t == ApiProviderTemplate.customId) return 'h:$host';
    return 't:$t#h:$host';
  }

  /// 一批旧配置 → 若干账号计划（v39 迁移与备份导入都调它，口径只有一处）。
  ///
  /// 归组判据（两级，全仓库只有这一处实现）：先按 [bucketOf] 分「哪台服务」，
  /// 桶内再按 apiKey 分组 —— **填了不同 Key 必然分属两个账号**（安全红线）；
  /// 空 Key 不算「另一把 Key」，算「用户还没填」，会被并进同桶里有 Key 的那一组。
  /// 不这么做的话，「先建了条目、后来才填 Key」这种正常数据会被拆成两个账号，
  /// 直接违反 G44 的「同 templateId+baseUrl 归到同一 accountId」。
  ///
  /// 取哪条当 Key：G44 原话「Key 取该组第一条非空」。同组内非空 Key 必然全等
  /// （不同 Key 不会同组），所以「第一条非空」兜住的正是「组里有条目 Key 是空的」
  /// 这种情况 —— 既不能因为第一条是空串就把账号的 Key 弄丢，也不能反过来
  /// 让那条空 Key 条目自己单立成一个没用的账号。
  ///
  /// [nameOf] 由调用方给（一级页要按当前语言取厂商名），不给就用第一条的名字。
  /// [now] 只为可测性存在：不传才用真实时间。
  static List<AccountPlan> plan(
    List<ApiConfig> configs, {
    String Function(ApiConfig member, int memberCount)? nameOf,
    DateTime? now,
  }) {
    // 两级分组：桶（连接身份）→ Key。Dart 的 Map 字面量是 LinkedHashMap，
    // 保持插入序 ⇒ 同一份输入必然得到同一份账号划分（幂等，可反复跑）。
    final buckets = <String, Map<String, List<ApiConfig>>>{};
    for (final c in configs) {
      final bucket = bucketOf(templateId: c.templateId, baseUrl: c.baseUrl);
      final groups = buckets[bucket] ??= <String, List<ApiConfig>>{};
      final strictKey = c.apiKey.trim();
      (groups[strictKey] ??= <ApiConfig>[]).add(c);
    }
    // 并回原顺序用：条目在输入列表里的下标（ApiConfig 不重写 ==，按身份记）。
    final position = <ApiConfig, int>{};
    for (var i = 0; i < configs.length; i++) {
      position[configs[i]] = i;
    }
    final stamp = (now ?? DateTime.now()).toIso8601String();
    final plans = <AccountPlan>[];

    AccountPlan buildPlan(List<ApiConfig> group) {
      group.sort((a, b) => (position[a] ?? 0).compareTo(position[b] ?? 0));
      final first = group.first;
      String pickNonEmpty(String Function(ApiConfig c) read) {
        for (final c in group) {
          final v = read(c).trim();
          if (v.isNotEmpty) return v;
        }
        return '';
      }

      final models = <String>[];
      for (final c in group) {
        for (final id in c.cachedModelsList) {
          if (id.trim().isEmpty) continue;
          if (!models.contains(id)) models.add(id);
        }
      }
      return AccountPlan(
        account: ApiAccount(
          id: const Uuid().v4(),
          templateId: first.templateId.trim().isEmpty
              ? ApiProviderTemplate.customId
              : first.templateId.trim(),
          name: nameOf?.call(first, group.length) ?? first.name.trim(),
          baseUrl: pickNonEmpty((c) => c.baseUrl),
          apiKey: pickNonEmpty((c) => c.apiKey),
          cachedModels: models.isEmpty ? '' : jsonEncode(models),
          createdAt: stamp,
        ),
        configIds: [for (final c in group) c.id],
      );
    }

    for (final groups in buckets.values) {
      final keyed = groups.entries.where((g) => g.key.isNotEmpty).toList();
      final keyless = groups[''] ?? const <ApiConfig>[];
      if (keyed.isEmpty) {
        // 整桶都没 Key（本地服务就是这样）：全部成员一个账号。
        plans.add(buildPlan(groups.values.expand((v) => v).toList()));
        continue;
      }
      // 一个桶里可以有**多个**账号：填了不同 Key 的组各自成一个（安全红线 ——
      // 把 A 的 Key 用到 B 的条目上，等于把用户的 Key 发给别的连接）。
      // 「还没填 Key」的条目并进第一个有 Key 的账号，不单立成一个空账号。
      for (var i = 0; i < keyed.length; i++) {
        plans.add(buildPlan(i == 0
            ? <ApiConfig>[...keyed.first.value, ...keyless]
            : keyed[i].value));
      }
    }
    return plans;
  }

  /// 在已有账号里找这条配置该挂的那一个（同桶 + 同 Key）。
  ///
  /// 用途有两处，都是「不能凭空再建一个账号」的地方：
  /// ① `saveApiConfig` 的懒绑定（老调用点没传 accountId）；
  /// ② 备份导入时把条目接回导入进来的账号。
  static ApiAccount? resolveExisting(
          List<ApiAccount> accounts, ApiConfig c) =>
      _matchExisting(accounts,
          templateId: c.templateId, baseUrl: c.baseUrl, apiKey: c.apiKey);

  /// [resolveExisting] 的实现，参数拆开是为了让迁移/导入也能按「模板 + 地址 + Key」
  /// 找账号，而不必先伪造一条 ApiConfig。
  static ApiAccount? matchExisting({
    required List<ApiAccount> accounts,
    required String templateId,
    required String baseUrl,
    required String apiKey,
  }) =>
      _matchExisting(accounts,
          templateId: templateId, baseUrl: baseUrl, apiKey: apiKey);

  static ApiAccount? _matchExisting(List<ApiAccount> accounts,
      {required String templateId,
      required String baseUrl,
      required String apiKey}) {
    final bucket = bucketOf(templateId: templateId, baseUrl: baseUrl);
    final strictKey = apiKey.trim();
    ApiAccount? anyInBucket;
    for (final a in accounts) {
      if (bucketOf(templateId: a.templateId, baseUrl: a.baseUrl) != bucket) {
        continue;
      }
      // 同一桶内 Key 必须逐字相等（两条无 Key 的本地配置归到同一个本地账号，
      // 两把不同的 Key 永远是两个账号）。
      if (a.apiKey.trim() == strictKey) return a;
      anyInBucket ??= a;
    }
    // 空 Key 的兜底：和 plan 同一口径 —— 「没填」不是「另一把 Key」，
    // 宁可挂到同桶的账号上（读路径会把 Key 补进来），也不要凭空多建一个账号。
    return strictKey.isEmpty ? anyInBucket : null;
  }

  /// 读路径：条目上为空的连接字段用账号值**补上**（只补空，不覆盖非空）。
  ///
  /// 为什么不反过来「以账号为准强行覆盖」：`ApiConfig.baseUrl` 里可能存着用户
  /// 手改过的路径（`.../api/paas/v4` vs `.../v1`，host 相同、路径不同 ⇒ 同桶）。
  /// 覆盖 = 读一次库就把他的地址改了，且无日志可查；补空 = 老数据缺值时仍然能用，
  /// 其余情况行为与升级前逐字一致。账号真正的同步写在 [syncChildren]（显式保存时）。
  static ApiConfig fillFromAccount(ApiConfig c, ApiAccount? a) {
    if (a == null || a.id != c.accountId) return c;
    final needsUrl = c.baseUrl.trim().isEmpty && a.baseUrl.trim().isNotEmpty;
    final needsKey = c.apiKey.trim().isEmpty && a.apiKey.trim().isNotEmpty;
    final cached = _mergeModels(c.cachedModelsList, a.cachedModelsList);
    final cachedJson =
        cached.isEmpty ? '' : jsonEncode(cached);
    if (!needsUrl && !needsKey && cachedJson == _normJson(c.cachedModels)) {
      return c;
    }
    return c.copyWith(
      baseUrl: needsUrl ? a.baseUrl : c.baseUrl,
      apiKey: needsKey ? a.apiKey : c.apiKey,
      cachedModels: cachedJson,
    );
  }

  /// 写路径：账号保存时把连接字段同步给它名下的模型条目（G45 的「共享」）。
  ///
  /// 同步判据是「**本来跟着账号的就继续跟着**」：
  /// - Key：条目 Key 与账号旧 Key 相同（含都为空）⇒ 换成新 Key；不同说明用户
  ///   单独改过这一条，不覆盖（宁可留冗余，也不静默改掉用户的显式选择）。
  /// - baseUrl：条目为空或等于账号旧值 ⇒ 跟随；否则保留（同 [fillFromAccount] 的理由）。
  /// - cachedModels：在线模型列表**本来就是端点属性**，直接跟账号，去重合并。
  /// - accountId：一律补上（这是本批要建立的引用）。
  static List<ApiConfig> syncChildren({
    required ApiAccount previous,
    required ApiAccount account,
    required List<ApiConfig> children,
  }) {
    final oldKey = previous.apiKey.trim();
    final oldUrl = previous.baseUrl.trim();
    final acctUrl = account.baseUrl.trim();
    final acctModels = account.cachedModelsList;
    return [
      for (final c in children)
        c.copyWith(
          accountId: account.id,
          apiKey: c.apiKey.trim() == oldKey ? account.apiKey : c.apiKey,
          baseUrl: (c.baseUrl.trim().isEmpty || c.baseUrl.trim() == oldUrl)
              ? (acctUrl.isEmpty ? c.baseUrl : account.baseUrl)
              : c.baseUrl,
          cachedModels: acctModels.isEmpty
              ? c.cachedModels
              : jsonEncode(
                  _mergeModels(c.cachedModelsList, acctModels),
                ),
        ),
    ];
  }

  static List<String> _mergeModels(List<String> a, List<String> b) {
    final out = <String>[];
    for (final list in [a, b]) {
      for (final id in list) {
        final t = id.trim();
        if (t.isEmpty || out.contains(t)) continue;
        out.add(t);
      }
    }
    return out;
  }

  /// 空串与 `[]` 视为同一种「没有缓存模型」，避免 fillFromAccount 白拷贝一次。
  static String _normJson(String raw) {
    final t = raw.trim();
    if (t.isEmpty || t == '[]') return '';
    return t;
  }
}


