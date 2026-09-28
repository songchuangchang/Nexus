/// build165（任务 #86）：把「这一轮流式回答为什么停」分开的**读数层**（纯函数）。
///
/// ## 这一份是用来分清哪三种可能的（都已取证，别重查）
/// 用户的 App（`com.example.aichat`，OPPO / ColorOS 16 / Android 16、`targetSdk 36`）
/// 一进后台这一轮就停摆。今早真机：带后台的 7 轮里 **5 轮只收到 0 或 1 个 chunk**，
/// 08:03 那轮探针写「离开 46s，一个 chunk 都没收到」，8 次掉线全落在 `resumed`
/// 之前 0.10~0.19 秒。上游/端点已排除（官方与中转站同一种失败形状），
/// AOSP 的 Doze / App Standby / cached-apps freezer 三条也已用官方原文排除
/// （当时 `id=1001 ongoing=true` 的前台服务在跑、系统回读 `promotedFlag=true`）。
/// **剩下的三种可能修法互斥，而现有读数分不开**：
///  1. **进程被冻结/挂起** —— 任何 Dart/原生逻辑这段时间都没在跑，只能先解决保活；
///  2. **被系统按内存上限杀掉** —— Android 17 起那条按设备总 RAM 的上限**对所有应用生效**
///     （与 targetSdk 无关），超了直接杀，`ApplicationExitInfo.description` 里带
///     `MemoryLimiter` 字样；
///  3. **上游或网络把连接关了** —— 进程一直活着，只有 socket 死了。
///
/// ## 为什么这条读数与流无关（与 `stream_probe.dart` 的分工）
/// chunk 计数那条探针只能回答"有没有数据到过"，而"没到"有两种成因（当时没流 / 流被冻），
/// build158 就为这个吃过一次假阳性。本文件用的是**另一个轴**的数：
/// 原生前台服务每秒 `ticks++`（`LiveTaskService.kt` 的 `BgHeartbeat`），
/// 它是"我这具身体这段时间有没有被调度"的直接凭据，不需要当时有流在跑。
///
/// ## 三条纪律
///  · **读数文案只住这一处**（教训 #62）：`chat_screen_react.dart` 与 `LiveTaskCenter`
///    都只调用本文件的函数，不自己抄字符串 —— 两处各写一套就会漂成两种口径；
///  · **只加读数，不改任何判据**：`decideDropContinue` / `DropContinueScheduler` /
///    `hasNetworkDropNote` / `AnswerFinalizer` 一个字都没动，本文件也不 import 它们；
///  · **测不出就说测不出**：原生没回、旧包、非 Android、`paused` 那次没记到基线，
///    一律走 [BgHeartbeatGap.unreadable] 那一句，不许塌成一个看起来很具体的结论。
///
/// ## 不许复现的那句旧话
/// 旧探针在"后台还收到过 chunk"时写的是「甲：进程活着、流在收」——那是**过度声称**：
/// 收到过 chunk 只说明数据到过，不等于整段后台都在跑。本文件的措辞只说
/// "心跳在跳 ⇒ 进程活着 ⇒ 出问题的是连接"，不写"流在收"（②那组用例里钉着反词探针）。
library;

/// 通道方法名①（Dart 与 Kotlin 引同一个字符串，只在这里定义一次）。
/// Kotlin 那份在 `LiveTaskPlugin.kt` 的分发处：`"heartbeatDiag" ->`。
const String kHeartbeatMethod = 'heartbeatDiag';

/// 通道方法名②：读最近几条进程退出原因。
/// **只许在回到前台时问一次**（那是一次 system_server 的 IPC，不进每秒心跳）。
const String kExitReasonsMethod = 'exitReasonsDiag';

/// 日志 tag（可 grep）：取证时 `grep BgForensics` 一次拿到并列的两半读数。
const String kBgForensicsLogTag = 'BgForensics';

/// 那一行里两个固定的键名（格式固定 = 下次拿同一句命令就能对上）。
const String kBgForensicsHeartbeatKey = '心跳断档=';
const String kBgForensicsExitsKey = '上次退出=';

/// 判**断档**要的最小后台时长（秒）。
///
/// 取值与 `stream_probe.dart` 那条 `minSampleSeconds` 对齐：十几秒以内的后台里
/// "没跳几次"也可能只是那一瞬本来就没轮到，说明不了被冻。
const int kBgForensicsMinSampleSeconds = 10;

/// 每秒心跳"涨到墙钟秒数的一半以上"才算**在跳**。
///
/// 为什么不取 1.0：主线程被一次渲染或日志 IO 占住就会少跳几回，取满一才会把
/// "活着但偶尔被压"误判成冻结；为什么不取 0.1：用户那 46 秒只跳了几次的形状
/// 必须落在"断档"这一侧（正是 ② 那组用例要证伪的东西）。
const double kBgForensicsAliveRatio = 0.5;

/// 一行里最多列几条退出记录（原生侧取 5 条，这里默认只展开最近 3 条：
/// 再多这一行就不可读了，而最该看的那一条几乎总是最近的一条）。
const int kBgForensicsMaxExitLines = 3;

// ═══════════════ ① 心跳快照（原生 `heartbeatDiag` 那张表的投影）═══════════════

/// **不含任何判据**，只回答"读没读到 + 读到什么"。判定在 [classifyBgHeartbeatGap]。
class BgHeartbeat {
  const BgHeartbeat({
    required this.readable,
    this.ticks = 0,
    this.ageMs = -1,
    this.ticking = false,
    this.services = 0,
    this.everStarted = false,
    this.intervalMs = 1000,
    this.note = '',
  });

  /// false = 压根没读到（旧包 / 非 Android / 通道抛错 / 原生回了 available=false）。
  final bool readable;

  /// 进程内累计跳了几次（单调增；进程重启会归零 —— 那本身就是个信息）。
  final int ticks;

  /// 距**上一次跳**过了多少毫秒；-1 = 一次都没跳过。
  /// 注意：它只回答"问这一刻主线程是不是刚跳过"，**不能**拿来判整段后台有没有被冻
  /// （解冻后第一跳立刻把它洗成 0）。判断档用的是两次 [ticks] 的差。
  final int ageMs;

  /// 原生自己给的"这一秒还在跳"（[ageMs] 在宽限期内）。
  final bool ticking;

  /// 读这一刻活着的前台服务实例数（0 = 表已经停了）。
  final int services;

  /// 这个进程里心跳服务**有没有起过**（false = 连服务都没起，谈不上冻结还是断网）。
  final bool everStarted;

  /// 原生侧的间隔（毫秒），只用来把"本来应该跳几次"这个参照说出来。
  final int intervalMs;

  /// 读不到时原生/通道给的原因（原样带出来，不许压成空串）。
  final String note;

  static BgHeartbeat unreadable([String note = '原生没有回执']) =>
      BgHeartbeat(readable: false, note: note);

  /// 那一秒到底还在不在跳：**没读到**这一态必须留在字符串里，
  /// 不许塌成"没在跳"（那会被读成"进程死了"）。
  String get tickingLabel =>
      !readable ? '读不到' : (ticking ? '在跳' : '没在跳');

  /// 解析原生那张表。任何形状不对都回 [unreadable] 并带上**为什么** ——
  /// "读不到"本身就是这次取证要区分的一种结果。
  factory BgHeartbeat.fromMap(Object? raw) {
    if (raw is! Map) {
      return BgHeartbeat.unreadable(
          '原生回的不是 Map（旧包或 $kHeartbeatMethod 没实现）');
    }
    if (raw['available'] != true) {
      final n = raw['note'];
      return BgHeartbeat.unreadable((n is String && n.trim().isNotEmpty)
          ? n
          : '原生回了 available=false 且没给原因');
    }
    int i(Object? v, int fallback) => v is num ? v.toInt() : fallback;
    return BgHeartbeat(
      readable: true,
      ticks: i(raw['ticks'], 0),
      ageMs: i(raw['ageMs'], -1),
      ticking: raw['ticking'] == true,
      services: i(raw['services'], 0),
      everStarted: raw['everStarted'] == true,
      intervalMs: i(raw['intervalMs'], 1000),
    );
  }
}

/// 一次"离开→回来"的心跳结论（五态，各自一句不同的话）。
enum BgHeartbeatGap {
  /// 读不到原生读数 ⇒ 不定性。
  unreadable,

  /// 压根没有 ticks（前台服务从没起过）。
  noService,

  /// 后台太短，样本不够 ⇒ 不定性。
  tooShort,

  /// 墙钟走了 N 秒、心跳只跳了几次 ⇒ **疑似进程被挂起/冻结**。
  suspended,

  /// 心跳按秒在涨而流死了 ⇒ 进程活着，问题在**网络/上游把连接关了**那一侧。
  processAliveStreamDead,
}

/// 判"这一段时间进程到底有没有在被调度"（纯函数，好测）。
///
/// [ticksDelta] 传 null = `paused` 那一次没记到基线（进程没记性可言）⇒ 只能不定性。
/// 负数也归进不定性：那意味着计数在两次读之间**归零过**（进程重启），
/// 那不是"断档"，拿它报被冻会把一件不需要修的事说成需要修。
BgHeartbeatGap classifyBgHeartbeatGap({
  required bool readable,
  required bool everStarted,
  required int ticks,
  required int? ticksDelta,
  required int wallClockSeconds,
  int minSampleSeconds = kBgForensicsMinSampleSeconds,
  double aliveRatio = kBgForensicsAliveRatio,
}) {
  if (!readable) return BgHeartbeatGap.unreadable;
  if (ticksDelta == null || ticksDelta < 0) return BgHeartbeatGap.unreadable;
  // 「压根没有 ticks」这一态优先于"太短"：服务没起时多少秒都判不出别的。
  if (!everStarted || ticks <= 0) return BgHeartbeatGap.noService;
  if (wallClockSeconds < minSampleSeconds) return BgHeartbeatGap.tooShort;
  if (wallClockSeconds <= 0) return BgHeartbeatGap.tooShort;
  return (ticksDelta / wallClockSeconds) >= aliveRatio
      ? BgHeartbeatGap.processAliveStreamDead
      : BgHeartbeatGap.suspended;
}

/// 五种情况各一句话术（互不相同、且都带上可对账的两个数）。
///
/// 措辞纪律：
///  · [BgHeartbeatGap.suspended] 只写**疑似**，因为"心跳没跳"也可能只是主线程被
///    一次长任务占住 —— 那一半要靠 [BgExitRecord.importance] 与原生那条日志再对；
///  · [BgHeartbeatGap.processAliveStreamDead] 不许写"流在收"（见文件头那条）。
String bgHeartbeatGapLabel(
  BgHeartbeatGap gap, {
  required int wallClockSeconds,
  required int? ticksDelta,
  String note = '',
}) {
  final d = ticksDelta;
  switch (gap) {
    case BgHeartbeatGap.unreadable:
      return '读不到原生心跳（${note.isEmpty ? '未知原因' : note}）⇒ 不定性：'
          '旧包 / 非 Android / 离开时没记到基线，三种都会落在这儿';
    case BgHeartbeatGap.noService:
      return '压根没有 ticks（前台服务从没起过）⇒ 这条判不了"被冻还是断网"，'
          '先确认常驻服务有没有起来，再回来读这一行';
    case BgHeartbeatGap.tooShort:
      return '离开 ${wallClockSeconds}s、心跳涨了 ${d ?? 0} 次，'
          '不足 $kBgForensicsMinSampleSeconds 秒不定性（太短的后台里少跳几次说明不了被冻）';
    case BgHeartbeatGap.suspended:
      return '墙钟走了 ${wallClockSeconds}s、原生每秒心跳只涨了 ${d ?? 0} 次'
          '（按 1 次/秒应约 $wallClockSeconds 次）⇒ **疑似进程被挂起/冻结**：'
          '这段时间压根没代码在跑，给岛或给流加原生逻辑都救不了，先解决保活';
    case BgHeartbeatGap.processAliveStreamDead:
      return '墙钟走了 ${wallClockSeconds}s、原生每秒心跳涨了 ${d ?? 0} 次'
          '（与墙钟同量级）⇒ **进程这具身体一直在跑**，所以这一路不是被冻：'
          '停在的是那条连接（网络/上游把线关了）';
  }
}

// ═══════════════ ② 上一次进程是怎么没的（原生 `exitReasonsDiag` 的投影）═══════════════

/// 一条 `ApplicationExitInfo` 的投影（只留取证要看的几项）。
class BgExitRecord {
  const BgExitRecord({
    required this.time,
    required this.timestampMs,
    required this.pid,
    required this.processName,
    required this.reason,
    required this.importance,
    required this.status,
    required this.description,
    required this.memoryLimiterHit,
    required this.pssBytes,
    required this.rssBytes,
  });

  final String time;
  final int timestampMs;
  final int pid;
  final String processName;

  /// AOSP 的常量号。**故意不翻译成中文**：这些值每加一个 Android 版本就补几个新项，
  /// 猜错一个就是把假话写进取证日志（宁可留数字，也不编一个看着像的说法）。
  final int reason;

  /// 这里**本来还有一格 `subReason`**，已删：`ApplicationExitInfo.getSubReason()` 是
  /// `@TestApi`，用 `javap` 查本机 `platforms/android-36/android.jar` 确认公开 SDK 里根本没有这个
  /// getter（`javap` 输出的成员里没有它）—— 原生侧编不过，Dart 侧留一个恒 0 的字段
  /// 等于把"读不到"伪装成"读到 0"。内存上限那条嫌疑改用真读得到的两格判：
  /// `description` 里的 `MemoryLimiter` 字样 + `importance`/`pss`/`rss`。

  /// 退出那一刻的进程优先级（原数：900 那一档才是"当时已经是个缓存进程"，
  /// 而 freezer 只 stop cached processes —— 这一格就是拿来对这条的）。
  final int importance;
  final int status;

  /// 框架给的原文（`MemoryLimiter` 这类字样就在这一格里）。
  final String description;

  /// Android 17 那条按设备总 RAM 的内存上限的答案位。
  final bool memoryLimiterHit;
  final int pssBytes;
  final int rssBytes;
}

/// `exitReasonsDiag` 那张表的投影。
class BgExitReasons {
  const BgExitReasons({
    required this.readable,
    this.sdkInt = 0,
    this.note = '',
    this.records = const [],
  });

  final bool readable;
  final int sdkInt;
  final String note;
  final List<BgExitRecord> records;

  static BgExitReasons unreadable([String note = '原生没有回执']) =>
      BgExitReasons(readable: false, note: note);

  /// 低版本（minSdk 24 < API 29）走这一条：`available=false` + 原因，不是崩。
  factory BgExitReasons.fromMap(Object? raw) {
    if (raw is! Map) {
      return BgExitReasons.unreadable(
          '原生回的不是 Map（旧包或 $kExitReasonsMethod 没实现）');
    }
    int i(Object? v) => v is num ? v.toInt() : 0;
    if (raw['available'] != true) {
      final n = raw['note'];
      return BgExitReasons.unreadable(
          (n is String && n.trim().isNotEmpty) ? n : '原生回了 available=false 且没给原因',
          );
    }
    final list = raw['exits'];
    final records = <BgExitRecord>[];
    if (list is List) {
      for (final e in list) {
        if (e is! Map) continue; // 一条坏记录不许把整张表判成读不到
        final desc = e['description'];
        final t = e['time'];
        records.add(BgExitRecord(
          time: (t is String && t.trim().isNotEmpty) ? t : '时间未给',
          timestampMs: i(e['timestampMs']),
          pid: i(e['pid']),
          processName: (e['processName'] is String) ? e['processName'] as String : '',
          reason: i(e['reason']),
          importance: i(e['importance']),
          status: i(e['status']),
          description: (desc is String) ? desc : '',
          memoryLimiterHit: e['memoryLimiterHit'] == true,
          pssBytes: i(e['pssBytes']),
          rssBytes: i(e['rssBytes']),
        ));
      }
    }
    return BgExitReasons(
      readable: true,
      sdkInt: i(raw['sdkInt']),
      note: (raw['note'] is String) ? raw['note'] as String : '',
      records: records,
    );
  }
}

/// 退出记录那一半的话术（进同一行日志，与心跳断档并列）。
///
/// 三条不许：
///  · 读不到时不许留空串（空串在日志里就是"没发生过"）；
///  · 没有记录时**只许说"没有退出记录"**，不许顺势说"所以进程没死过、是被冻"——
///    冻结确实不留退出记录，但"没有记录"也涵盖"系统没记全"这一半，
///    这一格只交数，结论由读日志的人拿两半对出来；
///  · 不许自己给 reason 编中文名字（见 [BgExitRecord.reason] 那段）。
String bgExitReasonsLabel(BgExitReasons r, {int max = kBgForensicsMaxExitLines}) {
  if (!r.readable) {
    return '读不到（${r.note.isEmpty ? '原生没给原因' : r.note}）⇒ 这一半等于没有凭据';
  }
  if (r.records.isEmpty) {
    return '最近没有退出记录（sdk=${r.sdkInt}）⇒ 只能说"系统没记到"，'
        '不等于"这一世之前进程没死过"，也不等于"是被冻结"';
  }
  final shown = r.records.take(max).map(_oneExit).join(' ; ');
  final more = r.records.length > max ? '（另有 ${r.records.length - max} 条未展开）' : '';
  final limiter = r.records.any((e) => e.memoryLimiterHit)
      ? ' 命中 MemoryLimiter（按设备总 RAM 的内存上限，对所有应用生效）'
      : '';
  return '${r.records.length} 条: [$shown]$more$limiter';
}

String _oneExit(BgExitRecord e) {
  final desc = e.description.replaceAll('\n', ' ').trim();
  return '${e.time} pid=${e.pid} 进程名=${e.processName.isEmpty ? '-' : e.processName} '
      'reason=${e.reason} importance=${e.importance} '
      'status=${e.status} MemoryLimiter=${e.memoryLimiterHit ? '命中' : '否'} '
      'pss=${_mb(e.pssBytes)} rss=${_mb(e.rssBytes)} '
      '描述=${desc.isEmpty ? '（框架没给描述）' : desc}';
}

/// 字节 → MB（0 与读不到都写 `-`，不写成 `0MB` 冒充"内存很省"）。
String _mb(int b) => b > 0 ? '${(b / 1048576).round()}MB' : '-';

// ═══════════════ ③ 两处打点用的那一行（格式固定、可 grep）═══════════════

/// **掉线那一刻**的那一行（由 `chat_screen_react.dart` 的收尾处打，紧挨
/// `[ReAct] [Timing]` 与 `流被对端关闭` 那两行，同一帧并列、只这一处）。
///
/// 这里只回答"**问这一刻**主线程在不在跑"（[BgHeartbeat.tickingLabel]）+ 当时的
/// ticks 与距今多久。为什么不在这里下断档结论：断档要拿两次读数的差，
/// 那一次归回到前台那一行（[bgForensicsResumeLine]），两个数才配成一对。
String bgHeartbeatDropLine(BgHeartbeat hb, {required String endKind}) {
  if (!hb.readable) {
    return '流关闭时心跳读数：读不到（${hb.note.isEmpty ? '原生没给原因' : hb.note}）'
        '⇒ 这一轮没有任何原生心跳凭据 endKind=$endKind';
  }
  final age = hb.ageMs < 0 ? '从未跳过' : '${hb.ageMs}ms';
  return '流关闭时心跳读数：ticks=${hb.ticks} 距今=$age 这一秒=${hb.tickingLabel} '
      '服务实例=${hb.services} 间隔=${hb.intervalMs}ms endKind=$endKind'
      '（只说这一刻主线程在不在跑，不断定成因；断档看回前台那行 $kBgForensicsLogTag）';
}

/// **回到前台**那一行：心跳断档与上次退出原因**并排**写。
///
/// 格式（固定，可 grep `BgForensics`）：
/// `回到前台并列读数(离开 Ns) 心跳断档=<五种之一> || 上次退出=<N 条: […]>`
String bgForensicsResumeLine({
  required BgHeartbeat heartbeat,
  required int? ticksDelta,
  required int wallClockSeconds,
  required BgExitReasons exits,
}) {
  final gap = classifyBgHeartbeatGap(
    readable: heartbeat.readable,
    everStarted: heartbeat.everStarted,
    ticks: heartbeat.ticks,
    ticksDelta: ticksDelta,
    wallClockSeconds: wallClockSeconds,
  );
  return '回到前台并列读数(离开 ${wallClockSeconds}s) '
      '$kBgForensicsHeartbeatKey${bgHeartbeatGapLabel(gap, wallClockSeconds: wallClockSeconds, ticksDelta: ticksDelta, note: heartbeat.note)} '
      '|| '
      '$kBgForensicsExitsKey${bgExitReasonsLabel(exits)}';
}
