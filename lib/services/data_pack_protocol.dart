// build138 / G54–G56：数据/资源包热更 —— 纯逻辑层（零 Flutter、零 IO，可单测）。
//
// 为什么单独一个文件：判定逻辑（源列表解析、版本比较、防污染闸门、状态文案）
// 必须能在不启动 App、不碰网络的前提下被单测钉死；服务层只做编排与 IO。
//
// 数据包（DataPack）统一信封（JSON 对象）：
//   {
//     "dataVersion": "2026.09.21",   // 单调递增；缺失回落读旧字段 "version"
//     "minAppVersion": "1.7.80",     // 可选：低于该 App 版本不应用
//     "sha256": "<hex>",             // 可选：对「去掉 sha256 字段后的规范化 JSON」取摘要
//     ...各包自有内容（templates / prompts+formats / entries）
//   }
//
// sha256 自指问题的处置：摘要字段本身不参与摘要（dropKey='sha256'），
// 且规范化=键排序 + 无空白，保证服务端脚本与客户端算法可对齐。
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

/// 用户可见的包状态（任务书要求三态：内置 / 已更新 / 失败）。
enum DataPackStatus { builtin, updated, failed }

/// 未应用的原因（日志与 UI 都要能给出人话）。
enum DataPackReject {
  none,
  noSources,
  fetchFailed,
  invalidJson,
  missingVersion,
  notNewer,
  minAppVersionTooHigh,
  sha256Mismatch,
  emptyPayload,
}

/// 自动刷新节奏：维持既有 7 天后台刷新。
const Duration kDataPackRefreshInterval = Duration(days: 7);

/// 缓存「陈旧到不可信」的上界（build131 既有语义，收敛到这一处）。
const Duration kDataPackCacheStaleAfter = Duration(days: 30);

/// 纯判定：缓存是否已陈旧到不可信（null＝老版本没写时间戳，同样算陈旧）。
bool isDataPackCacheStale(
  DateTime? updatedAt,
  DateTime now, {
  Duration staleAfter = kDataPackCacheStaleAfter,
}) =>
    updatedAt == null || now.difference(updatedAt) > staleAfter;

/// 是否需要刷新的纯判定（首次、无时间戳、或已到 7 天）。
bool isDataPackRefreshDue(DateTime? updatedAt, DateTime now,
        {Duration interval = kDataPackRefreshInterval}) =>
    updatedAt == null || now.difference(updatedAt) >= interval;

/// build145：一次「全源失败」的现场（时间 + 连续失败次数）。
///
/// 为什么两个数挤在同一个 prefs 键里：再加一个键就要动 spec、动 pref keys、动三处构造，
/// 而这两个值**永远同生同死**（记时间就必须记次数）⇒ 分开存只会多一个能写歪的地方。
class DataPackRetryStamp {
  const DataPackRetryStamp({this.at, this.failures = 0});
  final DateTime? at;
  final int failures;
}

String encodeDataPackRetryStamp(DateTime at, int failures) =>
    '${at.millisecondsSinceEpoch}|${failures < 1 ? 1 : failures}';

/// 解不开（缺字段 / 非法数字 / 老版本没写过）一律回「没有现场」⇒ 调用方按首次失败处理，
/// 不会因为读不懂就把刷新**永久关掉**（退避不许变成新的静默故障）。
DataPackRetryStamp decodeDataPackRetryStamp(String? raw) {
  if (raw == null || raw.isEmpty) return const DataPackRetryStamp();
  final i = raw.indexOf('|');
  if (i <= 0) return const DataPackRetryStamp();
  final ms = int.tryParse(raw.substring(0, i));
  final n = int.tryParse(raw.substring(i + 1));
  if (ms == null || n == null || n < 1) return const DataPackRetryStamp();
  return DataPackRetryStamp(
      at: DateTime.fromMillisecondsSinceEpoch(ms), failures: n);
}

/// 第 N 次连续全源失败之后要等多久：6 小时起、每次翻倍、封顶 7 天。
Duration dataPackRetryBackoff(int failures,
    {Duration base = const Duration(hours: 6),
    Duration cap = const Duration(days: 7)}) {
  final n = failures < 1 ? 1 : failures;
  var d = base;
  for (var i = 1; i < n; i++) {
    if (d >= cap) return cap;
    d = d * 2;
  }
  return d > cap ? cap : d;
}

/// 「现在能不能再试」：没记过时间戳（老数据）⇒ 允许一次并顺手补记，不静默压死刷新。
bool dataPackRetryAllowed(
    {required DateTime? lastFailureAt,
    required int failures,
    required DateTime now,
    Duration base = const Duration(hours: 6),
    Duration cap = const Duration(days: 7)}) {
  if (lastFailureAt == null) return true;
  // build145（第 9 轮 P2-8）：**时间戳在未来必须先放行**。
  // 设备时钟被网络校时往回拨（或记时间戳那一刻时钟偏快）之后，
  // `now.difference(lastFailureAt)` 是**负数**，而负数永远小于任何正退避时长 ⇒
  // 自动刷新被一条坏数据锁死几个月，日志里还写着「约 N 分钟后再试」（N 是负的）。
  // 判据：这份状态是"上次失败的证据"，它自己不可信时只能当没有，
  // 不许把不可信读成"还要再等"（同 #62 家族：别把「我不知道」压成一个假事实）。
  // 容忍 2 分钟以内的抖动，免得轻微不同步就反复放行。
  final elapsed = now.difference(lastFailureAt);
  if (elapsed < const Duration(minutes: -2)) return true;
  return elapsed >= dataPackRetryBackoff(failures, base: base, cap: cap);
}

// ==================================================================
// build161：失败按「重试会不会变好」分类 —— 退避计数只吃这里的结论。
//
// 为什么要有这一层：本仓库远端是**私有仓库**（有意为之），公共镜像/直链对它
// 永远回 401/403/404 —— 这是服务器对「这个资源」的确定性回答，重试一百次还是
// 同一答案。旧口径把它和断网混在一起计"全源失败"，真机日志实证连续 4 次就把
// 更新退避到 ~2061 分钟（34 小时+）：永久态被当成"再等等"，事实上把更新锁死
// 一天多。退避是给暂时性故障（超时/5xx/连接中断）准备的；永久性失败记一行
// 原因就该走开，不欠它任何等待。
// ==================================================================

/// 一次拉取失败的一级类别：重试不可能变好 vs 值得再等等。
enum DataPackFailureKind { permanent, transient }

/// 纯判定：HTTP 状态码 → 失败类别（不碰网络、不碰 DB，单测直接钉）。
/// 401/403=鉴权/授权被拒、404=资源不存在 ⇒ permanent；
/// 其余（5xx/429/408…）服务器只是暂时答不上来 ⇒ transient。
DataPackFailureKind dataPackFailureKindOfStatus(int statusCode) =>
    statusCode == 401 || statusCode == 403 || statusCode == 404
        ? DataPackFailureKind.permanent
        : DataPackFailureKind.transient;

/// GitHubContentFetcher 把各候选的失败拼成一条消息（`全部 6 个候选失败 —
/// direct: Exception: HTTP 404 | mirror:…: HTTP 403 | jsdelivr: TimeoutException`），
/// 状态码不在异常类型里、只在文本里，所以这里扫 `HTTP <code>`。
final RegExp _dataPackHttpStatus = RegExp(r'HTTP\s*(\d{3})');

/// 拉取异常 → 失败类别（纯判定）。
///
/// 单源口径：**连上了的候选的结论压过没连上的**。聚合消息里只要出现过
/// 401/403/404，这个源已经拿到服务器的确定性回答（"没有 / 不让进"）；
/// 同一条里偶发的镜像超时只是"没问到"，不能否决已问到的答案。
/// 一个状态码都没有（纯超时/断网/DNS 挂）⇒ transient，build145 的退避语义原样。
DataPackFailureKind classifyDataPackFailureKind(Object error) {
  for (final m in _dataPackHttpStatus.allMatches(error.toString())) {
    final code = int.tryParse(m.group(1)!);
    if (code != null &&
        dataPackFailureKindOfStatus(code) == DataPackFailureKind.permanent) {
      return DataPackFailureKind.permanent;
    }
  }
  return DataPackFailureKind.transient;
}

/// 一轮「全源失败」要不要计入连续暂时性失败计数。
///
/// 口径（可辩护性写在这里）：只要**有任何一个源**没拿到回答（纯暂时性失败），
/// 这一轮的结局就可能被网络状态决定——网络好转后该源下次也许就能成功 ⇒ 计入，
/// 按 build145 退避；只有**所有源都各自拿到了**确定性拒绝，这一轮才与网络无关
/// ——下次重来还是同样的答案 ⇒ 不计数、不退避。注意与单源口径的次序关系：
/// 同一条消息里 404 与 Timeout 并排 ⇒ 该源算 permanent（已连上的先说话）。
bool dataPackRoundCountsTowardBackoff(List<DataPackFailureKind> kinds) =>
    kinds.any((k) => k == DataPackFailureKind.transient);

/// 版本号解析：`1.7.80+137` → [1,7,80,137]；`v` 前缀与空白容忍。
List<int> parseDataPackVersion(String raw) {
  var s = raw.trim();
  if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
  final plus = s.indexOf('+');
  final mainPart = plus >= 0 ? s.substring(0, plus) : s;
  final buildPart = plus >= 0 ? s.substring(plus + 1) : '';
  final parts =
      mainPart.split('.').map((e) => int.tryParse(e.trim()) ?? 0).toList();
  if (buildPart.isNotEmpty) {
    final buildNum = int.tryParse(buildPart.trim());
    if (buildNum != null) parts.add(buildNum);
  }
  return parts;
}

/// 版本比较：>0 表示 a>b。缺段按 0 补（`1.7.8` < `1.7.80`）。
int compareDataPackVersion(String a, String b) {
  final p1 = parseDataPackVersion(a);
  final p2 = parseDataPackVersion(b);
  final maxLen = p1.length > p2.length ? p1.length : p2.length;
  for (var i = 0; i < maxLen; i++) {
    final x = i < p1.length ? p1[i] : 0;
    final y = i < p2.length ? p2[i] : 0;
    if (x != y) return x > y ? 1 : -1;
  }
  return 0;
}

/// 源列表持久化编码：**向后兼容单 URL**（老值没有分隔符 → 解析成长度 1 的列表）。
List<String> parseDataPackSources(String? raw) {
  if (raw == null) return const [];
  final out = <String>[];
  for (final piece in raw.split(RegExp(r'[\n\r,\s]+'))) {
    final t = piece.trim();
    if (t.isNotEmpty && !out.contains(t)) out.add(t);
  }
  return out;
}

/// 有序列表 → SP 字符串（换行分隔；单元素即老格式，无需迁移）。
String encodeDataPackSources(List<String> urls) =>
    parseDataPackSources(urls.join('\n')).join('\n');

/// 规范化 JSON：递归按键排序、无空白。[dropKey] 用于剥掉自指摘要字段。
String canonicalDataPackJsonForHash(Object? value, {String dropKey = 'sha256'}) {
  Object? norm(Object? v) {
    if (v is Map) {
      final keys = v.keys.map((e) => e.toString()).toList()..sort();
      final out = <String, Object?>{};
      for (final k in keys) {
        if (k == dropKey) continue;
        out[k] = norm(v[k]);
      }
      return out;
    }
    if (v is List) return v.map(norm).toList();
    return v;
  }

  return jsonEncode(norm(value));
}

/// UTF-8 文本的 sha256 十六进制小写。
String sha256HexOf(String text) =>
    crypto.sha256.convert(utf8.encode(text)).toString().toLowerCase();

/// 一次载荷校验的结果。
class DataPackCheckResult {
  const DataPackCheckResult({
    required this.accepted,
    required this.reject,
    this.dataVersion,
    this.itemCount = 0,
    this.detail = '',
  });

  final bool accepted;
  final DataPackReject reject;
  final String? dataVersion;
  final int itemCount;
  final String detail;

  static DataPackCheckResult rejected(DataPackReject r, {String detail = ''}) =>
      DataPackCheckResult(accepted: false, reject: r, detail: detail);
}

/// 防污染闸门（G55 唯一实现）。顺序：JSON 完整性 → 校验和 → 版本 → 门槛 → 非空。
///
/// [itemCountOf] 由每个包自己解释「有多少条有效条目」；返回 0 视为空包拒绝，
/// 远程永远不能把客户端拉成空数据（G55）。
///
/// X11（build172）：版本基准从 `appVersion` 改为**上次已应用的 dataVersion**
/// （[baselineVersion]，由 `data_pack_baseline.dart` 每包持久化）。
/// 原基准下四份载荷全部低于 App 版本 ⇒ 热更对每个用户恒判旧、从未生效。
/// 新语义：
///  - [baselineVersion] 为空（从未应用）→ 跳过新旧比较，其余闸照过；
///  - 载荷 dataVersion **严格更旧**才拒绝（防降级重放）；
///  - **同版本视为幂等重放，照常接受**——规则/模板每轮扫描都会重放拉取，
///    若同版本也拒，"仍然有效的当前载荷"会从生效集合里凭空消失。
/// [appVersion] 仍保留，只用于 [minAppVersion] 闸。
DataPackCheckResult evaluateDataPackPayload({
  required String rawJson,
  required String baselineVersion,
  required String appVersion,
  required int Function(Object? decoded) itemCountOf,
}) {
  Object? decoded;
  try {
    decoded = jsonDecode(rawJson);
  } catch (e) {
    return DataPackCheckResult.rejected(DataPackReject.invalidJson,
        detail: 'JSON 解析失败: $e');
  }

  final env = decoded is Map
      ? Map<String, dynamic>.from(decoded)
      : <String, dynamic>{};

  final sha = (env['sha256']?.toString() ?? '').trim().toLowerCase();
  if (sha.isNotEmpty) {
    final expected = sha256HexOf(canonicalDataPackJsonForHash(env));
    if (expected != sha) {
      return DataPackCheckResult.rejected(DataPackReject.sha256Mismatch,
          detail: '期望 $expected，实际 $sha');
    }
  }

  final remote = (env['dataVersion']?.toString().trim().isNotEmpty ?? false)
      ? env['dataVersion'].toString().trim()
      : (env['version']?.toString().trim() ?? '');
  if (remote.isEmpty) {
    return DataPackCheckResult.rejected(DataPackReject.missingVersion,
        detail: '该包没有 dataVersion/version 字段，无法判断新旧');
  }
  // X11：基线为空 = 从未应用（新装/清除后），跳过新旧比较直接放行；
  // 非空时只在载荷**严格更旧**才拒（同版本 = 幂等重放，接受）。
  if (baselineVersion.trim().isNotEmpty) {
    final cmp = compareDataPackVersion(remote, baselineVersion);
    if (cmp < 0) {
      return DataPackCheckResult.rejected(DataPackReject.notNewer,
          detail: '远程 $remote 已应用过更新的基线 $baselineVersion，拒绝降级');
    }
  }
  final minApp = (env['minAppVersion']?.toString() ?? '').trim();
  if (minApp.isNotEmpty && compareDataPackVersion(appVersion, minApp) < 0) {
    return DataPackCheckResult.rejected(DataPackReject.minAppVersionTooHigh,
        detail: '需要 App ≥ $minApp，当前 $appVersion');
  }

  final n = itemCountOf(decoded);
  if (n <= 0) {
    return DataPackCheckResult.rejected(DataPackReject.emptyPayload,
        detail: 'dataVersion $remote 内无有效条目');
  }
  return DataPackCheckResult(
      accepted: true,
      reject: DataPackReject.none,
      dataVersion: remote,
      itemCount: n);
}

/// 拉取异常归类：404/403 与断网都属「源不可达」这一类。
/// 状态码/超时等细节留在 [DataPackState.detail] 原文里，UI 与日志都能看到。
DataPackReject classifyDataPackFailure(Object error) =>
    DataPackReject.fetchFailed;

/// 拒绝原因 → 人话（zh/en 内联，不进 arb）。
String describeDataPackReject(DataPackReject reject,
    {String detail = '', bool isZh = true}) {
  final label = switch (reject) {
    DataPackReject.none => isZh ? '无' : 'OK',
    DataPackReject.noSources =>
      isZh ? '未配置数据源' : 'No source configured',
    DataPackReject.fetchFailed => isZh
        ? '所有源均拉取失败（网络中断，或源返回 404/403 私有仓库）'
        : 'All sources failed (offline, or 404/403 private repo)',
    DataPackReject.invalidJson =>
      isZh ? 'JSON 已损坏，无法解析' : 'Malformed JSON',
    DataPackReject.missingVersion => isZh
        ? '数据包缺少 dataVersion 字段，无法判断新旧'
        : 'Missing dataVersion, cannot tell freshness',
    DataPackReject.notNewer => isZh
        ? '远程不比内置新，仍用内置'
        : 'Remote is not newer than built-in; kept built-in',
    DataPackReject.minAppVersionTooHigh => isZh
        ? '该数据包要求的 App 版本更高'
        : 'Package requires a newer app version',
    DataPackReject.sha256Mismatch => isZh
        ? 'sha256 校验不匹配（内容被篡改或截断）'
        : 'sha256 mismatch (tampered or truncated)',
    DataPackReject.emptyPayload => isZh
        ? '数据包内无有效条目，已拒绝用空数据覆盖内置'
        : 'No valid items, refused to overwrite built-in with empty data',
  };
  final d = detail.trim();
  if (d.isEmpty) return label;
  return '$label（$d）';
}

/// 展示用时间（本地时区，分钟精度）。null → 「—」。
String formatDataPackTime(DateTime? t, bool isZh) {
  if (t == null) return isZh ? '—' : '-';
  final local = t.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

/// 一个数据包的可展示状态快照（G56：页面只消费它，不碰各 catalog）。
///
/// X11（build172）：删去 `builtinDataVersion` —— 版本闸门基准改为每包
/// 持久化的「上次已应用的 dataVersion」（见 data_pack_baseline.dart）之后，
/// 「内置版本」不再参与任何判定，展示层面一并移除。
class DataPackState {
  const DataPackState({
    required this.id,
    required this.nameZh,
    required this.nameEn,
    required this.sourceUrls,
    required this.status,
    required this.reject,
    required this.detail,
    this.remoteDataVersion,
    this.lastUpdatedAt,
    this.appliedCount = 0,
    this.hasRemoteData = false,
  });

  final String id;
  final String nameZh;
  final String nameEn;
  final List<String> sourceUrls;
  final DataPackStatus status;
  final DataPackReject reject;
  final String detail;
  final String? remoteDataVersion;
  final DateTime? lastUpdatedAt;
  final int appliedCount;
  final bool hasRemoteData;

  String name(bool isZh) => isZh ? nameZh : nameEn;

  String statusLabel(bool isZh) => switch (status) {
        DataPackStatus.builtin => isZh ? '内置数据' : 'Built-in',
        DataPackStatus.updated => isZh ? '已更新' : 'Updated',
        DataPackStatus.failed => isZh ? '更新失败' : 'Failed',
      };

  /// 一行完整文案（列表副标题 / SnackBar 都用它）。
  String describe(bool isZh) {
    switch (status) {
      case DataPackStatus.updated:
        return isZh
            ? '已更新 · 版本 ${remoteDataVersion ?? ''} · '
                '$appliedCount 条 · 更新于 ${formatDataPackTime(lastUpdatedAt, true)}'
            : 'Updated · version ${remoteDataVersion ?? ''} · '
                '$appliedCount items · at ${formatDataPackTime(lastUpdatedAt, false)}';
      case DataPackStatus.failed:
        final keep = hasRemoteData
            ? (isZh ? '，已沿用上次成功的缓存' : ', keeping last good cache')
            : (isZh ? '，继续使用内置数据' : ', built-in data still in use');
        return isZh
            ? '更新失败 · ${describeDataPackReject(reject, detail: detail, isZh: true)}$keep'
            : 'Failed · ${describeDataPackReject(reject, detail: detail, isZh: false)}$keep';
      case DataPackStatus.builtin:
        return isZh
            ? '内置数据 · 尚未拉取远程包'
            : 'Built-in · not fetched yet';
    }
  }
}

/// 「检查更新」的结果汇总（一次提示，不刷屏）。
String summarizeCheckResults(List<DataPackState> states, bool isZh) {
  final changed = states.where((s) => s.status == DataPackStatus.updated);
  final failed = states.where((s) => s.status == DataPackStatus.failed);
  if (isZh) {
    if (states.every((s) => s.status == DataPackStatus.updated)) {
      return '数据包已全部更新（${changed.map((s) => s.appliedCount).join(' + ')} 条）';
    }
    if (failed.isEmpty) return '数据包检查完成';
    if (changed.isEmpty) {
      return '全部 ${states.length} 个数据包更新失败：'
          '${failed.map((s) => '${s.nameZh}·${describeDataPackReject(s.reject, detail: s.detail, isZh: true)}').join('；')}';
    }
    return '已更新 ${changed.length} 个，失败 ${failed.length} 个：'
        '${failed.map((s) => s.nameZh).join('、')}';
  }
  if (states.every((s) => s.status == DataPackStatus.updated)) {
    return 'All data packs updated';
  }
  if (failed.isEmpty) return 'Data pack check finished';
  if (changed.isEmpty) return 'All ${states.length} data packs failed to update';
  return 'Updated ${changed.length}, failed ${failed.length}: '
      '${failed.map((s) => s.nameEn).join(', ')}';
}
