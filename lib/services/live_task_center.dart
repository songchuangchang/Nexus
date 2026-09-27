import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../constants.dart';
import '../ui/tokens.dart';
import '../utils/background_run_guide.dart';
import '../utils/bg_forensics.dart';
import '../utils/round_exit.dart';
import 'logger_service.dart';

/// build142（灵动岛）：把「进行中的长任务」投影成应用外可见的一条常驻通知。
///
/// 本文件是这条能力的**唯一真源**（教训 #62）：原生侧 [LiveNotification] 只是一个
/// 幂等渲染器，不持有任务状态。所以「任务结束了通知还挂着」这类最难查的缺陷，
/// 只可能出在这里，不会两头各有一半。
///
/// 四条口径：
/// 1. **一次只跑一个前台服务**。两类任务同时进行时由 `dataSync` 承载 —— 进程已经被它
///    保住了，长轮跟着活；再起第二个服务只会多出一条几乎一样的常驻通知（通知噪音红线）。
/// 2. **摘要取最大进度**，不取均值：用户关心「有没有快好了」。
/// 3. **节流**：进度更新 ≥1 秒 或 最大进度变化 ≥2% 才下发；集合增删/结束一律立刻下发
///    （否则「完成」会被自己节流掉，那是最难受的一种：下载完了通知还停在 97%）。
/// 4. **不许把「进行中」报成「已完成」**（build122 定过的口径），失败必须带原因。
enum LiveTaskKind { download, backup, dataPack, video, research, askUser }

/// build152（岛上分段进度）：长任务里的一个**阶段**（编排的「路由 / 取证 / 合成」）。
///
/// 为什么只有「完成 / 未完成」两态、不带"当前在做哪一段"：Android 16 的
/// `ProgressStyle.Segment` 能表达的**只有**「每段一个相对长度 + 每段一个颜色」
/// （javap 实测 1.18.0：`Segment(int length)` + `setId(int)` + `setColor(int)`，
/// 没有"高亮当前段"这种入口）。多承诺一个渲染不出来的状态，得到的就是
/// 「注释写着有、屏幕上没有」——本仓库在 `done` 字段上已经栽过一次
/// （见 [LiveTask.done] 那段：原生注释承诺了 Dart 没实现的东西）。
class LiveStage {
  const LiveStage(this.label, {this.done = false});

  /// 一行人话（例：`取证`）。分段条本身不画文字，留着它是为了让日志与
  /// 将来的「点进去看第几步」有东西可指，而不是再靠段序猜。
  final String label;
  final bool done;
}

/// 上不上前台服务、上哪个，由 kind 决定（[serviceFor]）；[askUser] 永远是提醒，不发服务。
class LiveTask {
  const LiveTask({
    required this.id,
    required this.kind,
    required this.title,
    this.progress,
    this.indeterminate = false,
    this.route = '',
    this.detail = '',
    this.done = false,
    this.ok = true,
    this.waitingUser = false,
    this.stages = const [],
  });

  final String id;
  final LiveTaskKind kind;

  /// 一行人话，直接进通知标题（例：`正在下载更新包 12.4 MB / 26.1 MB`）。
  final String title;

  /// 0.0–1.0；null 表示未知（不确定态，**不许画假百分比**）。
  final double? progress;
  final bool indeterminate;

  /// 点通知要落到哪个页面，见 [kLiveRoute*]。
  final String route;
  final String detail;

  /// build148：这一行是不是**终态**（已完成 / 已失败）。
  ///
  /// `LiveNotification.kt:102` 的契约注释从 build142 起就写着快照每任务带 `"done"`，
  /// 但两边都没实现过：Dart 不填、原生不读。现在补上这个字段并真的下发 ——
  /// 原生渲染器目前仍只按 title/detail 画（✅/✗ 在标题里，见 [terminalTitle]），
  /// 留着这个字段是为了让"这是一条结果"成为**数据**而不是文案巧合：
  /// 将来要换 ProgressStyle 的状态图标族（TrackerIcon / Segments，javap 实测可用）
  /// 时，判定条件不用再靠猜标题前缀。
  final bool done;

  /// 终态是成功还是失败（仅 [done] 为真时有意义）。
  final bool ok;

  /// build168 ①：这一行停在「AI 问了一句、等人答」上。
  ///
  /// 为什么不是一个新 `done`/`ok` 组合而是**第三个标志**：
  ///  · `ok=true` 会让渲染层挂 `√`（`ic_live_done`）并写「· 已完成」——
  ///    这正是本次要修的谎话：那一轮根本没跑完，也不会自己往下走；
  ///  · `ok=false` 会挂 `×`（`ic_live_fail`）并写「· 失败」——那是吓人的假故障，
  ///    build150/165 为同一件事立过红线（机主原话见 `drop_continue.dart` 文件头）；
  ///  · 两者都不成立 ⇒ 只能多一个真源位。**Dart 侧的标题读它**（拼出「· 等你回答」），
  ///    不靠文案前缀反推。
  /// ✅ **接线状态（build170 / #97）**：原生侧现在真的读它了 ——
  ///    `LiveNotification.kt` 的端点图标那一格从二分改成三态
  ///    （`waitingUser` 排在最前 → `ic_live_action` 琥珀三角，缺键退回旧二分），
  ///    `renderOngoing` 还用它决定低版本的标题前缀 `！` 与"已结束 N 项"的计数；
  ///    快照里 `prio` 那一格也被原生读走选标题（见 [liveDisplayPriority]）。
  ///    钉住这两个 key 逐字相同的是 `test/build170_island_waiting_user_test.dart`。
  /// `done` 在这一档**照旧为真**：此刻确实没有任何东西在跑，进度条不许再转。
  final bool waitingUser;

  /// build152：这个任务内部**走过的阶段**（空 = 这类任务没有阶段可报，画连续条）。
  ///
  /// 为什么现在要把它做成数据：用户长期的原话是「一直是准备中，下面一条线有什么用」
  /// —— 编排/研究这类任务**根本没有字节级进度**，一根不确定条就是它全部能说的，
  /// 于是跑十分钟与刚起步在屏幕上长得一样。能说的其实是「第几段做完了」，
  /// 而 ProgressStyle 的分段正是表达这个的那族控件（见 [liveStageSegments]）。
  final List<LiveStage> stages;

  bool get isTerminal => done;

  /// 这一行是不是「等人」那一档（两种来源共用一个判据，别再各写一份 `||`）：
  ///  · `kind == askUser` 是**反问进行中**那一行（提醒族，本来就不进快照）；
  ///  · [waitingUser] 是**一轮结束在反问上**那一行（终态族，进快照）。
  /// 优先级表（[liveDisplayPriority]）读的就是这一格。
  bool get isWaitingForUser => waitingUser || kind == LiveTaskKind.askUser;

  /// build153（用户批准「可以」）：岛 / 状态栏**胶囊**那一格的短名，随快照下发给原生侧。
  ///
  /// 出处是官方文档、不是我们的审美：OPPO《流体云模板 2.0》胶囊态规定
  /// 左 `[A]` 服务图标 + 右 `[B]` 文本，且「过长的文本信息须精简至范围内
  /// （**最多 5 个字符**），若未精简的文本信息直接兼容至 2.0 时，胶囊拉伸变长…
  /// **若达到胶囊最大宽度后，以"…"形式显示**」
  /// （一手来源 `Z:\日志与计划\OPPO 开放平台-OPPO开发者服务中心.mht`，
  /// 抽取纯文本行 228/232/234，见 `docs/OPPO_FLUID_CLOUD_PUSH_接入清单.md` §五）。
  /// 用户 09-23 12:37 那张截图里的「进行中 2 项 · T…」就是这条规则的产物 ——
  /// 我们的标题动辄 7 字以上（「正在从网盘取备份」「视频生成失败」），注定被截成半句。
  ///
  /// 三条刻意的边界：
  /// · **按 `kind` 推**，不解析长标题的字面（`track()` 那条的标题是调用方给的一句话，
  ///   从里面抠不出稳定的短名）；
  /// · **不做"截前 5 个字"那种自动缩短** —— 「正在从网盘取备份」截成「正在从网盘」
  ///   是一句读不通的假文案（本仓库口径：宁可少说，也不把"我不知道"压成一个值）；
  ///   所以表里没有的 kind 只会走 `default`，而 `LiveTaskKind` 是穷举的 ⇒ 新增 kind
  ///   时编译器会逼着这里补一条；
  /// · 深度研究与普通思考在岛上是**两件事**（用户要能看出跑的是哪种），
  ///   但 `deep` 不是一个新状态 —— 它一直写在标题里，这里读回来即可
  ///   （`onResearchStart` 的 `title: deep ? '深度研究中' : 'AI 思考中'`）。
  ///
  /// `askUser` 提前返回：它是**提醒**不是进度，「待回答中」不成话；
  /// 下面 switch 里那条 `askUser` 分支只为穷举完整性存在（永不执行）。
  String get pill {
    if (kind == LiveTaskKind.askUser) return '待回答';
    final stem = switch (kind) {
      LiveTaskKind.download => '下载',
      LiveTaskKind.backup => '备份',
      LiveTaskKind.dataPack => '更新',
      LiveTaskKind.video => '生成',
      LiveTaskKind.research => title.contains('深度') ? '研究' : '思考',
      LiveTaskKind.askUser => '待回答',
    };
    // build168 ①：等人那一档既不是「…中」（没有任何东西在跑）也不是「完成」。
    if (waitingUser) return '待回答';
    if (!done) return '$stem中';
    return ok ? '$stem完成' : '$stem失败';
  }

  /// 终态标题的唯一口径（成功 / 失败 / 等你回答 + 原因位）。
  ///
  /// build148（真机反馈「灵动岛不合理」）：进行中的标题一律是「正在更新资源包」这种
  /// 现在进行式，直接拼上去会得到 **「正在更新资源包 · 已完成」** —— 同一行大字里
  /// 前半句说"正在"、后半句说"已完成"，自相矛盾（岛只有两行，第二行还把这句原样
  /// 重复了一遍，见 `LiveNotification.kt` 同批修复）。终态先把进行式前缀摘掉：
  /// 「正在更新资源包」→「更新资源包 · 已完成」。没有该前缀的标题（「深度研究中」
  /// 「AI 思考中」）原样保留，不做第二套改写。
  static String terminalTitle(String base,
      {required bool ok, bool waitingUser = false}) {
    final stem = base.startsWith(_progressivePrefix) &&
            base.length > _progressivePrefix.length
        ? base.substring(_progressivePrefix.length)
        : base;
    // build168 ①：等人那一档**两个都不写**。写「· 已完成」是谎（这一轮没跑完、
    // 也不会自己往下走），写「· 失败」是吓人的假故障（什么都没坏）。
    // 这一格的话**住在这里**，不住 `round_exit.dart`：它与上面两个兄弟
    //（「已完成」「失败」）是同一格、同一套拼法，三个词必须同处（build168 那版补丁
    // 在 `round_exit.dart` 里另放了一份 `askUserWaitingIslandState(isZh:)`，
    // 生产里零调用点 ⇒ 27 日收口时删掉了它，理由写在那文件头上）。
    if (waitingUser) return '$stem · 等你回答';
    return ok ? '$stem · 已完成' : '$stem · 失败';
  }

  ///
  /// **为什么这里不放 ✅/❌ 图形**：本仓库的 V2 视觉规范 R1 是"用户可见字符串禁 emoji，
  /// 改用图标组件或纯文字"，`test/v2_ui_guard_test.dart` 每次全量都按基线卡着
  /// （我第一版写的是 ✅/❌，当场被这条棘轮拦下 —— 这不是工具碍事，是它替我把
  /// "在通知里塞 emoji"这个跨厂商渲染不可控的做法挡回去了：同一条通知在
  /// ColorOS / MIUI / 原生上字形与颜色都不一样，失败态还可能被渲染成绿色对勾的兄弟）。
  /// 图形要放，但放在**原生状态图标**上（`LiveNotification.kt` 的 ProgressStyle
  /// end 图标族）。✅ **接线状态（build170 / #97）**：end 位现在挂**三枚**——
  /// `ic_live_done`（√ 勾）/ `ic_live_fail`（× 叉）/ `ic_live_action`（琥珀三角 + ！，
  /// 本轮新增的 drawable 文件），分别由 `ok` / `!ok` / `waitingUser` 选中，
  /// `waitingUser` 排在最前（见 [LiveTask.waitingUser] 那段"两个布尔编不出它"）。
  /// 不支持端点图标的机型（API < 36）退回**标题前缀**，用的正是下面那四个不在
  /// R1 码段里的字符（√ / × / ！/ …，进行中那一档不加前缀）。折叠态那句短状态仍由
  /// `subText` 承担。先保证"看得懂成败/等人"，图形不替文字编第二套说法。
  static const String _progressivePrefix = '正在';

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind.name,
        'title': title,
        'progress': progress,
        'indeterminate': indeterminate || progress == null,
        'route': route,
        'detail': detail,
        'done': done,
        'ok': ok,
        // build168 ①：等人那一档**只有为真时才输出这个键**（与 `stages` 同一条纪律：
        // 快照形状对没用到它的行逐字节不变，省得原生侧多一格永远为 false 的读位）。
        if (waitingUser) 'waitingUser': true,
        // build168 ③：这一行该不该当标题，是**数据**不是文案巧合。
        // ✅ **接线状态（build170 / #97）**：原生侧 `LiveNotification.kt` 的 `ordered`
        // 现在按这一格分桶选标题，不再按"插入序 + done 二分"猜 ⇒ 刚跑完的下载
        // 不会再盖掉等他回答的那一轮（`running`/`finished` 那两列留着，但只管"共几项"
        // 那个计数）。读不到 `prio` 时按同一张表从 done/ok 现推，缺字段 = 退回旧行为。
        // 档位表只有 [liveDisplayPriority] 这一份；跨语言钉住的是**键名与数字**，
        // 见 `test/build170_island_waiting_user_test.dart` 那一组锚点。
        'prio': liveDisplayPriority(this),
        // build153：短名总是推得出来（`kind` 是必填 + switch 穷举），所以无条件带上。
        // 原生侧只在**标题那一格**用它，长标题仍走 `title`（通知栏那行有足够宽度，
        // 把「正在从网盘取备份」在通知栏里也缩成「备份中」是丢信息，不是省地方）。
        'pill': pill,
        // build152：**空就不输出这个键**。快照形状因此与改前逐字节一致，
        // 只有真的填了阶段的任务才多一个键 —— 本仓库对「加了字段但没人用」的
        // 既有纪律（`done` 那次就是注释先于实现，两边各有一半，见上面那段）。
        if (stages.isNotEmpty)
          'stages':
              stages.map((s) => {'label': s.label, 'done': s.done}).toList(),
      };
}

/// 设置页与启动读**同一把** key（只在这里定义一次，别散到各屏幕）。
/// 默认开：这次用户口径是「应用外可见」，但总开关必须给，
/// 因为「四类任务同时上 ⇒ 通知噪音」是审核与体验的双红线（PLAN §五已定）。
const String kLiveNotificationsEnabled = 'live_notifications_enabled';

/// build145（第 9 轮）：「AI 在等你回答」那条常驻提醒的通知 id。
/// 放在中枢而不是接线层，是因为**关开关的人也要能撤它**（`setUserEnabled`），
/// 而接线层反过来依赖中枢 —— 常量放下面会成环。值不许改：改了等于给用户留旧通知。
const int kAskUserAlertId = 2001;

const String kLiveRouteBackup = 'nexus://live/backup';
const String kLiveRouteVideo = 'nexus://live/video';
const String kLiveRouteChat = 'nexus://live/chat';
const String kLiveRouteDataPacks = 'nexus://live/datapacks';

/// 该任务是否需要（以及允许）把进程保在后台。
///
/// 返回 null = 这类任务**不启服务**：只发提醒。刻意不把 `askUser` 算进去 ——
/// 它是「等你回来答」，不是「替你继续跑」，为它常驻既耗电也不过审。
String? serviceFor(Iterable<LiveTaskKind> kinds) {
  final set = kinds.toSet();
  bool has(Iterable<LiveTaskKind> g) => set.any(g.contains);
  if (has(const {LiveTaskKind.download, LiveTaskKind.backup, LiveTaskKind.dataPack})) {
    return 'dataSync';
  }
  if (has(const {LiveTaskKind.video, LiveTaskKind.research})) return 'specialUse';
  return null;
}

// ═══════════════ build156（用户：「那个更新的灵动岛要给他限时，如果失败了的话，就及时给他收回来」）═══════════════

/// 每类任务在岛上的**最长寿命**（纯函数，好测）。返回 null = 这类**不限时**。
///
/// 为什么必须有（这是机制漏洞，不是"再加一层保险"）：本文件里唯一会把一行撤掉的
/// 地方是 [_expire]，而它只由 [finish] 起的那条 [terminalHold] 延时触发 ⇒
/// 一条**永远走不到终态**的进行中行（下载挂在死流上、备份那个 future 再也没返回、
/// 研究那一轮 await 不回来）在屏幕上就是"永远"。登记时没有时限、结束时没人撤，
/// 两头都没人管 —— 用户看到的"那个岛一直挂着"就是这条路。
///
/// 取值口径：都取"这类任务正常跑完"的**一个量级之上**，宁可收得晚也不误杀在跑的活。
/// 判据是"收错的代价 = 用户重按一次"，"不收的代价 = 屏幕上永远挂着一条假状态"。
///
/// **`askUser` 返回 null 是刻意的**：那一行是「AI 在等你回答」，它不到终态**是设计如此**
/// （等的是人，不是网络）。给它挂时限等于到点自动把用户一条真消息吞掉 ——
/// 那不是"收回一条僵尸通知"，那是**丢消息**。宁可这一行多挂一会儿。
Duration? deadlineFor(LiveTaskKind kind) {
  return switch (kind) {
    LiveTaskKind.download => const Duration(minutes: 15),
    LiveTaskKind.backup => const Duration(minutes: 10),
    LiveTaskKind.dataPack => const Duration(minutes: 10),
    LiveTaskKind.video => const Duration(minutes: 30),
    LiveTaskKind.research => const Duration(minutes: 20),
    LiveTaskKind.askUser => null,
  };
}

/// 到点该收哪些（纯函数，好测）。
///
/// 为什么这条判定要能**脱离 Timer 单独问**（也是"及时"这两个字的真凭据）：
/// Dart 的 `Timer` 在进程被 Android 冻结/挂起时**根本不跑**（今天刚为"切后台岛卡住"
/// 装了 `stream_probe.dart` 探针，两种成因之一正是这个）。只挂一条延时的"限时"
/// 在后台等于没有限时 ⇒ 中枢**每次下发前**都拿这个函数现问一遍（见
/// [LiveTaskCenter] 的 `_reclaimExpired`），于是回前台或下一次动作会立刻收回。
///
/// 只报"在真源里 + 仍非终态 + 有 start 时刻 + 该类限时且已到点"的 id：
/// 终态行有自己的 [terminalHold] 延时，不归这里管；不认识的 id 一律跳过。
List<String> expiredIds({
  required Map<String, LiveTask> tasks,
  required Map<String, DateTime> startedAt,
  required Duration? Function(LiveTaskKind) deadlineFor,
  required DateTime now,
}) {
  final out = <String>[];
  for (final e in startedAt.entries) {
    final t = tasks[e.key];
    if (t == null || t.isTerminal) continue;
    final limit = deadlineFor(t.kind);
    if (limit == null) continue;
    if (!now.isBefore(e.value.add(limit))) out.add(e.key);
  }
  return out..sort();
}

/// 耗时的人话（进终态行的 detail：`已等 15 分` / `已等 40 秒`）。
String liveElapsedLabel(Duration d) {
  final s = d.isNegative ? Duration.zero : d;
  if (s.inMinutes < 1) return '${s.inSeconds} 秒';
  final rest = s.inSeconds % 60;
  return rest == 0 ? '${s.inMinutes} 分' : '${s.inMinutes} 分 $rest 秒';
}

/// 节流判定（纯函数，好测）。
///
/// [setChanged] 为真（任务增删/全部结束）时无条件放行 —— 这条**优先级高于时间间隔**，
/// 理由见类注释第 3 点。
bool shouldPostSnapshot({
  required DateTime now,
  required DateTime? lastPost,
  required bool setChanged,
  required int lastMaxPercent,
  required int newMaxPercent,
  Duration minInterval = const Duration(seconds: 1),
  int minPercentStep = 2,
}) {
  if (setChanged) return true;
  if (lastPost == null) return true;
  // 完成那一步永远放行：否则「下载完了」会停在 97% 不动，是最难查的一类假状态。
  if (newMaxPercent >= 100 && lastMaxPercent < 100) return true;
  final elapsed = now.difference(lastPost);
  if (elapsed < minInterval) return false;
  // 有不确定态任务时只能按时间放行 —— 它没有百分比可比，
  // 而「第 3/8 轮」这类 detail 更新正是靠这条才不会被永久压掉。
  if (lastMaxPercent < 0 || newMaxPercent < 0) return true;
  return (newMaxPercent - lastMaxPercent).abs() >= minPercentStep;
}

/// 摘要文案（纯函数）。超过 3 项只列前 3 项 + 「等 N 项」。
String liveSummaryLine(List<LiveTask> tasks) {
  if (tasks.isEmpty) return 'Nexus 后台任务';
  final head = tasks.first.title;
  if (tasks.length == 1) return head;
  final shown = tasks.take(3).map((t) => t.title).join(' · ');
  final tail = tasks.length > 3 ? ' · 等 ${tasks.length} 项' : '';
  return '进行中 ${tasks.length} 项 · $head\n$shown$tail';
}

/// 通知里显示的百分比（取最大；全不确定时返回 -1 让渲染层画不确定条）。
int liveMaxPercent(List<LiveTask> tasks) {
  var max = -1;
  for (final t in tasks) {
    final p = t.progress;
    if (p == null) continue;
    final v = (p.clamp(0.0, 1.0) * 100).round();
    if (v > max) max = v;
  }
  return max;
}

/// 分段条的段数上限。
///
/// 为什么必须有上限：岛/通知里那条带很窄（宽度按 dp 算几十、高度按像素算几个），
/// 段数一多每段就细到看不出色差 —— 看不出的分段**等于没有**，还会把
/// 「哪几段做完了」这件事从"能读"变成"要盯着看半天"。宁可合并也不铺满。
const int kLiveStageSegmentCap = 5;

/// 阶段 → 分段条的段表（纯函数，好测）。
///
/// 每条是 `{'id','length','color'}`，颜色传的是 **ARGB int**：
/// · **少于 2 段返回空** —— 一段满格的"分段"不比分段条多任何信息，
///   交给宿主画原来的连续条更好看（原生侧据此**根本不调** `setProgressSegments`）。
/// · 段长用**整数相对权重**（`ProgressStyle.Segment(int length)` 吃的是权重不是像素，
///   javap 实测只有这一个参数），所以等长就一律给 1。
/// · 超过 [kLiveStageSegmentCap] 时取前 4 段 + 把余下的**合并成最后一段**
///   （段长 = 余下阶段数），且合并段**全部完成才算完成** —— 与 [LiveTask.terminalTitle]
///   那句「不许把进行中转成已完成」是同一条口径：宁可少报，也不虚报。
/// · 任何输入都不抛异常：空列表、单阶段、超上限都只是走上面三条分支，
///   没有下标越界与除零（合并段那一步用 `skip/take`，不自己算偏移）。
///
/// 原生侧 `LiveNotification.kt` 的 `stageSegments()` 按**同一套规则**把
/// `stages` 落成 `ProgressStyle.Segment`（跨语言没法共用这段代码，所以由
/// `test/build142_live_task_test.dart` 的双侧锚点钉住，不许两边各算一套）。
List<Map<String, Object?>> liveStageSegments(List<LiveStage> stages,
    {required int accentArgb, required int dimArgb}) {
  if (stages.length < 2) return const [];
  final head = stages.take(kLiveStageSegmentCap - 1).toList();
  final merged = stages.length - head.length;
  var id = 1;
  final out = <Map<String, Object?>>[
    for (final s in head)
      {
        'id': id++,
        'length': 1,
        'color': s.done ? accentArgb : dimArgb,
      },
  ];
  if (merged > 0) {
    // 合并段：全部完成才算完成（宁可少报也不虚报，见函数头那条口径）
    final allDone = stages.skip(head.length).every((s) => s.done);
    out.add({
      'id': id,
      'length': merged,
      'color': allDone ? accentArgb : dimArgb,
    });
  }
  return out;
}

/// build168 ③：**多任务同时在场时哪一行当标题**的唯一优先级表。
///
/// 病灶（机主口径，不是猜的）：原生侧一直用 `ordered.firstOrNull()` 挑标题，
/// 而 `ordered` 是「进行中在前、终态在后」的二分 + **Dart 传来的插入序**。
/// 于是「下载刚跑完 + 一轮停在反问上」同时在场时，屏幕上说的是那件**已经结束**的事，
/// 真正等他答的那一行既没标题也没人念——`· 已完成` 挂在一个根本没交付的轮次上。
///
/// 四档（数字越小越靠前）：
///  · `0` **等人答**——它不会自己往下走，是四档里唯一"越晚看见代价越大"的；
///  · `1` **失败**——要原因，第二优先；
///  · `2` **进行中**——它自己会走完，晚一点不丢东西；
///  · `3` **已完成**——已经交付完了，最不需要占屏幕。
///
/// 为什么是"显式整数"而不是"再排一次 done/ok"：`waitingUser` 这一档在
/// `done`/`ok` 两个布尔上**没有唯一编码**（见 [LiveTask.waitingUser] 那段），
/// 原生侧再自己组合那两个布尔就等于把判据抄第二份（教训 #62）。
int liveDisplayPriority(LiveTask t) {
  if (t.isWaitingForUser) return 0;
  if (t.done) return t.ok ? 3 : 1;
  return 2;
}

/// 按 [liveDisplayPriority] 排好的显示序（**稳定**：同优先级保持原序）。
///
/// 为什么必须显式做稳定：`List.sort` 在 Dart 里不保证稳定，而"同档内按登记序"
/// 是原生侧现在的行为；直接 `sort` 会让两条同为「进行中」的下载每次渲染换人当标题，
/// 用户读成"通知在乱跳"。所以带下标排。
List<LiveTask> liveDisplayOrder(Iterable<LiveTask> tasks) {
  final src = tasks.toList();
  final idx = List.generate(src.length, (i) => i)
    ..sort((a, b) {
      final p = liveDisplayPriority(src[a]) - liveDisplayPriority(src[b]);
      return p != 0 ? p : a - b;
    });
  return [for (final i in idx) src[i]];
}

String liveSnapshotJson(List<LiveTask> tasks) {
  return jsonEncode({
    'promoted': true,
    // build168 ③：**唯一的显示序出口**。原生侧只信 `prio`，不再按收到的顺序猜。
    'tasks': liveDisplayOrder(tasks).map((t) => t.toJson()).toList(),
  });
}

/// 快照里按「该不该启服务」分好类（提醒类不进快照）。
List<LiveTask> serviceEligible(Iterable<LiveTask> tasks) =>
    tasks.where((t) => t.kind != LiveTaskKind.askUser).toList();

List<LiveTask> askUserTasks(Iterable<LiveTask> tasks) =>
    tasks.where((t) => t.kind == LiveTaskKind.askUser).toList();

/// 这一次「点通知回 App」该不该真的去导航（纯函数，好测）。
///
/// 三条放行/拦下规则：
/// · [inFlight] 为真（上一次导航还没跑完 —— 等 Navigator 最长 3 秒）⇒ 拦下，
///   否则两次快速点击会并发各推一个页面；
/// · **同一条路由**在 [dedupe] 窗口内再来一次 ⇒ 拦下（下拉通知栏手滑双击就是这一条）；
/// · 不同路由、或同一条路由隔在窗口之外（用户返回后又点了一次）⇒ 放行。
/// 空路由原样放行：由导航端决定"什么都不做"（`main.dart` 的 `_openLiveRoute`），
/// 这里不替它判断，免得两处各有一套"什么算无效路由"。
bool shouldEmitOpenRoute({
  required String route,
  required DateTime now,
  required bool inFlight,
  String? lastRoute,
  DateTime? lastAt,
  Duration dedupe = const Duration(milliseconds: 1500),
}) {
  if (inFlight) return false;
  if (lastRoute != null &&
      lastRoute == route &&
      lastAt != null &&
      now.difference(lastAt) < dedupe) {
    return false;
  }
  return true;
}

/// 单例：全 App 只有这一个登记处。
class LiveTaskCenter {
  LiveTaskCenter._();
  static final LiveTaskCenter instance = LiveTaskCenter._();

  static const MethodChannel _ch = MethodChannel('nexus/live_task');
  static const int idOngoing = 1001;

  final Map<String, LiveTask> _tasks = <String, LiveTask>{};
  final LoggerService _log = LoggerService.instance;

  bool _ready = false;
  bool _userEnabled = true;
  bool _lastSetWasEmpty = true;
  int _lastMaxPercent = -1;
  DateTime? _lastPost;
  String? _serviceInUse;
  String _lastDiag = '';
  int _alertSeq = 3000;

  /// 供设置页显示：权限/开关状态。null = 还没问到。
  bool? notificationsEnabled;
  bool? permissionGranted;
  bool? liveUpdatesSupported;
  int sdkInt = 0;

  bool get userEnabled => _userEnabled;
  List<LiveTask> get current => List.unmodifiable(_tasks.values);
  String? get serviceKind => _serviceInUse;

  /// 原生最近一次带回的「系统怎么判这条通知」的诊断串（见 `_push`）。
  String get lastDiag => _lastDiag;

  /// 系统允不允许本应用发布「提升通知」（Android 16 Live Updates 的门）。
  /// null = 还没拿到诊断（非 16 或未下发过任务）。
  bool? get promotedAllowed {
    if (_lastDiag.isEmpty) return null;
    final m = RegExp(r'canPost=(\w+)').firstMatch(_lastDiag);
    if (m == null) return null;
    return m.group(1) == 'true';
  }

  /// **系统实际**有没有把那条常驻通知提升成 Live Update（build155）。
  ///
  /// 与 [promotedAllowed] 的分工：那个是"允不允许"（用户/厂商开关），
  /// 这个是"这一条到底升上去没有"。以前只有前者可读，后者无处可查 ——
  /// 于是「岛为什么没有」永远停在猜。null = 原生还没回过这一半（老包 / 非 16）。
  bool? get systemPromoted {
    if (_lastDiag.isEmpty) return null;
    // 键名区分靠大小写就够：原生那一半现在写 `localPromotedFlag=`（大写 P），
    // 这里要读的 `promotedFlag=` 只可能来自系统侧回读。仓库口径禁用内联标志，
    // 而 Dart 的正向后顾也不保证支持 —— 不拿引擎特性当依据。
    final m = RegExp(r'promotedFlag=(\w+)').firstMatch(_lastDiag);
    if (m == null) return null;
    return m.group(1) == 'true';
  }

  /// 只读地问一次原生诊断并**无条件**写日志（`why` 进日志好分辨是哪一次问的）。
  ///
  /// 为什么要绕开 `_push` 里那个"变化才写"的节流：真机导出里 `[Live] 渲染诊断`
  /// 全篇只有一行（17:42:50），而后面有四次 `Lifecycle: paused` —— 分不出
  /// 「系统判定没变」与「我们压根没再问」。切后台正是用户投诉「回去就没岛」的那个时刻。
  ///
  /// 任何失败都不许抛出：这条路是在 `didChangeAppLifecycleState` 里跑的，
  /// 为一条日志把生命周期回调打断，代价比少一行日志大得多。
  Future<void> logDiagnostics(String why) async {
    if (!_ready) return;
    try {
      final d = await _ch.invokeMethod<String>('liveDiag');
      if (d == null || d.isEmpty) {
        _log.info('渲染诊断[$why] 原生没回（旧包或未注册）', tag: 'Live');
        return;
      }
      if (d != _lastDiag) _log.info('渲染诊断[$why] $d', tag: 'Live');
      // 即使文本没变也要记账：`systemPromoted` 读的是这个字段，
      // 而"没变"不等于"没发生过"。
      _lastDiag = d;
    } catch (e) {
      _log.debug('渲染诊断[$why] 问不到：$e', tag: 'Live');
    }
  }

  // ═══════════════ build165（任务 #86）：两把"分清三种可能"的读数 ═══════════════
  //
  // 这一节**只读不判**：判定与文案全部住在 `lib/utils/bg_forensics.dart`（教训 #62）。
  // 三种要分开的可能是：① 进程被冻结/挂起；② 被系统按内存上限杀掉
  // （Android 17 起那条按设备总 RAM 的上限对所有应用生效，`MemoryLimiter` 字样在
  // `ApplicationExitInfo.description` 里）；③ 上游或网络把连接关了。
  // ① 与 ③ 靠原生每秒心跳的**增量**分开，② 靠退出记录分开 —— 三条都不改任何行为判据。

  /// 心跳那一次问的超时上限。
  ///
  /// 为什么必须给超时而不是裸 await：这条路现在坐在两个关键时点上 ——
  /// 一轮流**掉线那一刻**（`chat_screen_react.dart` 的收尾）与**回到前台**那一下。
  /// 裸 await 一旦撞上原生主线程被占住，就会把这一轮的收尾与落库一起拖住，
  /// 那是"为一条读数把正事变成新故障"。超时回的是"读不到"那一句，
  /// **不是**"没在跳"—— 这两个态在 `bg_forensics.dart` 里是分开的两行话。
  static const Duration _heartbeatTimeout = AppWait.heartbeatDiag;

  /// 读退出原因的超时（那是一次 system_server 的 IPC，比读静态量慢，给到 3 秒）。
  static const Duration _exitReasonsTimeout = AppWait.exitReasonsIpc;

  /// `paused` 那一刻记下的心跳基线（null = 那一次没读到，宁可不定性也不拿旧基线算差）。
  BgHeartbeat? _hbAtPause;

  /// 与 [_hbAtPause] 配对的墙钟时刻（**取的是发起那一次的时刻**，不是回执时刻）。
  DateTime? _hbPausedAt;

  /// 问一次原生心跳（纯进程内静态量，一次通道往返，不碰 system_server）。
  ///
  /// [why] 只进"读不到"那句原因里，好分辨是 `paused` / `resumed` / `drop` 哪一次问的。
  /// 任何失败都回 [BgHeartbeat.unreadable]，**绝不抛**：调用点在掉线收尾与生命周期回调里。
  Future<BgHeartbeat> heartbeatSnapshot(String why) async {
    if (!_ready) return BgHeartbeat.unreadable('$why 这一次：Dart 侧通道未就绪（非 Android 或旧包）');
    try {
      final r = await _ch
          .invokeMethod<Map<Object?, Object?>>(kHeartbeatMethod)
          .timeout(_heartbeatTimeout);
      return BgHeartbeat.fromMap(r);
    } on TimeoutException {
      return BgHeartbeat.unreadable(
          '$why 这一次：原生 ${_heartbeatTimeout.inMilliseconds}ms 没回话（主线程被占住）');
    } catch (e) {
      return BgHeartbeat.unreadable('$why 这一次：问心跳抛错 $e');
    }
  }

  /// 全仓**唯一**一处读 `exitReasonsDiag`（一次 system_server 的 IPC）。
  ///
  /// 只由 [logResumeForensics] 调，而它只挂在 `main.dart` 的 `resumed` 那一个分支上 ——
  /// 这条纪律由 `test/build165_heartbeat_test.dart` 的源码锚点钉住（不许进每秒心跳）。
  Future<BgExitReasons> _exitReasonsOnce() async {
    if (!_ready) {
      return BgExitReasons.unreadable('Dart 侧通道未就绪（非 Android 或旧包）');
    }
    try {
      final r = await _ch
          .invokeMethod<Map<Object?, Object?>>(kExitReasonsMethod)
          .timeout(_exitReasonsTimeout);
      return BgExitReasons.fromMap(r);
    } on TimeoutException {
      return BgExitReasons.unreadable(
          '原生 ${_exitReasonsTimeout.inSeconds} 秒没回话（system_server 那条 IPC 太慢）');
    } catch (e) {
      return BgExitReasons.unreadable('读退出原因抛错：$e');
    }
  }

  /// `paused` 那一次记心跳基线（由 [resyncForBackground] 调，那里只认 `paused`）。
  ///
  /// 为什么基线要在**出去之前**取：被冻之后没人替我们跑代码，那一刻再问就已经晚了；
  /// 而这一次问的是进程内的静态量，代价是一次通道往返，不新增 system_server 的 IPC。
  Future<void> noteHeartbeatBaseline() async {
    final at = DateTime.now();
    final hb = await heartbeatSnapshot('paused');
    if (!hb.readable) {
      _hbAtPause = null;
      _hbPausedAt = null;
      _log.debug('心跳基线没记到：${hb.note}', tag: kBgForensicsLogTag);
      return;
    }
    _hbAtPause = hb;
    _hbPausedAt = at;
  }

  /// **回到前台**那一次的并列读数：一行里同时给「心跳断档」与「上一次进程是怎么没的」。
  ///
  /// 为什么这一行值得存在（真机凭据）：带后台的 7 轮里 5 轮只收到 0~1 个 chunk，
  /// 而"没收到"既可能是没被调度、也可能是被杀、也可能是网络关线 —— 三种修法互斥。
  /// chunk 那条探针（`stream_probe.dart`）还要求"当时有流"，本行不要求：
  /// 心跳数与流在不在毫不相干，所以它不会再产出 build158 那种假阳性。
  ///
  /// 任何一步失败都只少一半读数，**不许抛**：调用点在 `didChangeAppLifecycleState` 里。
  Future<void> logResumeForensics() async {
    if (!_ready) return;
    final base = _hbAtPause;
    final pauseAt = _hbPausedAt;
    // 基线一次一用：留着的下一次（没经过 paused 的假 resumed）会拿旧数算出差。
    _hbAtPause = null;
    _hbPausedAt = null;
    try {
      final secs =
          pauseAt == null ? 0 : DateTime.now().difference(pauseAt).inSeconds;
      final hb = await heartbeatSnapshot('resumed');
      final delta = (base == null || !hb.readable) ? null : hb.ticks - base.ticks;
      final exits = await _exitReasonsOnce();
      _log.info(
        bgForensicsResumeLine(
          heartbeat: hb,
          ticksDelta: delta,
          wallClockSeconds: secs,
          exits: exits,
        ),
        cat: LogCat.app,
        tag: kBgForensicsLogTag,
      );
    } catch (e) {
      _log.debug('回前台并列读数没打出来：$e', tag: kBgForensicsLogTag);
    }
  }

  /// 启动时调一次。失败（非 Android、channel 未注册）只记日志，不影响任何功能。
  Future<void> initialize({bool userEnabled = true}) async {
    _userEnabled = userEnabled;
    if (_ready) return;
    // 处理器**必须先注册**再问原生：原生在 `initialize` 返回时就把自己标成
    // flutterReady，之后热启动点通知会立刻 invokeMethod('onOpenTask')。
    // 晚注册一帧，那条路由就永久丢了（通知点了没反应，且日志里什么都没有）。
    _ch.setMethodCallHandler(_onCall);
    try {
      final r = await _ch.invokeMethod<Map<Object?, Object?>>('initialize');
      if (r == null) return;
      notificationsEnabled = r['notificationsEnabled'] as bool?;
      permissionGranted = r['permissionGranted'] as bool?;
      liveUpdatesSupported = r['liveUpdatesSupported'] as bool?;
      sdkInt = (r['sdkInt'] as num?)?.toInt() ?? 0;
      _ready = true;
      _log.info(
        'LiveTask 就绪 sdk=$sdkInt 通知=${notificationsEnabled == true ? '开' : '关'} '
        '权限=${permissionGranted == true ? '已给' : '未给'} '
        'LiveUpdates=${liveUpdatesSupported == true ? '支持' : '不支持（< Android 16）'}',
        tag: 'Live',
      );
      // build155（第 13 轮 · 撤销完备性）：冷启动先把**上一世**留下的常驻条收掉。
      // 为什么此刻任何常驻条都是孤儿：Dart 这边是进程内的单例，进程死了任务列表就没了，
      // 而通知不是 —— `setOngoing(true)` 的 1001/1002 与「待回答」那条 2001 都由系统持有，
      // 用户从最近任务划掉 App（不是 force-stop）时它们**全部留着且划不掉**。
      // 于是重启后会出现最难受的那种形状：屏幕上说"正在下载"，真源里一条任务都没有，
      // 而且没有任何人会再走一次 `_stopAll()`（没有变化就没有下发）。
      // 判据是 [_tasks] 本身而不是"上次有没有推过"：冷启动时真源必然为空 ⇒ 清扫是幂等的，
      // 也不会误伤（服务与进程同生共死，重启后不可能还有活着的合法前台服务）。
      // 只在对应集合为空时才收，`_push` 撞上 MissingPluginException 重跑 initialize 时
      // 才不会把正在跑的那一条撤掉。
      if (serviceEligible(_tasks.values).isEmpty) {
        await _stopAll();
        _lastSetWasEmpty = true;
      }
      if (!hasAskUserTasks) {
        // 高打扰 alert 的一次性提醒（3000+ 那批）autoCancel=true，用户划得掉，不归这里管；
        // 只有 id 固定的「待回答」那条是 ongoing、划不掉，必须由主人撤 —— 主人就是这里。
        try {
          await _ch.invokeMethod<void>('cancelAlert', {'id': kAskUserAlertId});
        } catch (e) {
          _log.warn('冷启动撤孤儿「待回答」失败：$e', tag: 'Live');
        }
      }
      // 冷启动点通知进来：取走路由，交给 Dart 侧的导航回调
      final route = await _ch.invokeMethod<String>('getInitialRoute');
      if (route != null && route.isNotEmpty) {
        _pendingRoute = route;
        unawaited(_emitOpen(route));
      }
    } on MissingPluginException {
      _log.info('LiveTask 未注册（非 Android 或旧引擎），通知能力静默关闭', tag: 'Live');
    } catch (e) {
      _log.warn('LiveTask 初始化失败：$e', tag: 'Live');
    }
  }

  String? _pendingRoute;
  String? get pendingRoute => _pendingRoute;
  void clearPendingRoute() => _pendingRoute = null;

  Future<void> Function(String route)? onOpen;

  /// 同一条通知被连点时的幂等窗口。
  ///
  /// 为什么必须有（build155 第 13 轮 · 深链那一半）：常驻/提醒通知的 contentIntent 都带
  /// `FLAG_ACTIVITY_NEW_TASK | SINGLE_TOP` + `launchMode="singleTask"` ⇒ 第二次点**不会**
  /// 重建 Activity，而是走 `onNewIntent` → `onOpenTask` → `_openLiveRoute` →
  /// `Navigator.push`。而 `_openLiveRoute` 每次都推一个**新页面**，于是
  /// 「下拉通知栏手滑点了两下」= 备份设置页在栈里叠两层，返回键要按两次，
  /// 而第二层还开着的时候用户以为已经退干净了（本项目反复出现的"两张皮"形状）。
  /// 冷启动那一路同理：`getInitialRoute` 取走一次 + 系统稍后又投一次 `onOpenTask`
  /// 时，同一份路由会被消费两次。
  static const Duration _openDedupe = Duration(milliseconds: 1500);
  bool _openInFlight = false;
  String? _lastOpenRoute;
  DateTime? _lastOpenAt;

  Future<void> _emitOpen(String route) async {
    final cb = onOpen;
    if (cb == null) return;
    final now = DateTime.now();
    if (!shouldEmitOpenRoute(
      route: route,
      now: now,
      inFlight: _openInFlight,
      lastRoute: _lastOpenRoute,
      lastAt: _lastOpenAt,
      dedupe: _openDedupe,
    )) {
      _log.debug('点通知回 App：重复路由已忽略 route=$route', tag: 'Live');
      return;
    }
    _lastOpenRoute = route;
    _lastOpenAt = now;
    _openInFlight = true;
    try {
      await cb(route);
    } finally {
      _openInFlight = false;
    }
  }

  Future<dynamic> _onCall(MethodCall call) async {
    if (call.method == 'onOpenTask') {
      final args = call.arguments;
      final route = args is Map ? (args['route'] as String? ?? '') : '';
      _pendingRoute = route.isEmpty ? null : route;
      await _emitOpen(route);
    }
    return null;
  }

  /// 当前是否还有「等用户回答」的任务在挂着（撤系统提醒前的判据，见 wiring 的 onAskUserEnd）。
  bool get hasAskUserTasks =>
      _tasks.values.any((t) => t.kind == LiveTaskKind.askUser);

  /// 用户开关（设置页）。关掉时立刻把常驻通知撤掉，不然「关了还在」最伤信任。
  Future<void> setUserEnabled(bool v) async {
    _userEnabled = v;
    if (!v) {
      // build145（第 9 轮 P2-4）：**开关不该改真源**。原来的写法是
      // `_tasks.removeWhere(≠askUser)` —— 把还在跑的任务从内存里删了。
      // 后果有两层：① 再打开时它们**永远回不来**（下载/备份/研究都是"注册一次"的
      // 事件式挂载，中途被删就没人再报），一次误开关就把正在导出的备份从通知里抹掉；
      // ② 恰恰漏了它声称要处理的那个：askUser 的常驻提醒被**特意保留**，
      // 于是"关了还在"这件事还是会发生。
      // 现在只停投影（服务 + 通知），任务列表原样留着；开回来时 _push(force) 会重绘。
      // build155（第 13 轮 · 撤销完备性）：上面那条口径**不适用于终态行** ——
      // 「已完成 / 已失败」那一行不是"还在跑的事"，它存在的唯一理由是停留 8 秒给
      // 人看一眼结果，而那个 8 秒靠 [_terminalTimers] 里的一条延时。关开关时
      // 只撤通知、不清这些行也不撤延时，就会留下两种最难看的残留：
      //   · 8 秒内再打开开关 → `_push(force)` 把那条「✓ 已完成」原样重绘（用户已经
      //     明确说过"别显示"，我们却把它当"进行中"重新贴回去）；
      //   · 更糟的是以后有人在这里补 `cancelAllTerminalHolds()`（旧实现只撤延时、
      //     不删行）⇒ 那条终态行**再也没有人撤**，成为一条永不消失的「✓ 已完成」。
      // 所以关掉时：撤掉全部延时 + 把终态行从真源里删掉（进行中的行一条都不动）。
      await cancelAllTerminalHolds();
      await _stopAll();
      try {
        await _ch.invokeMethod<void>('cancelAlert', {'id': kAskUserAlertId});
      } catch (e) {
        _log.warn('关闭时撤「待回答」提醒失败：$e', tag: 'Live');
      }
      _lastSetWasEmpty = true;
      return;
    }
    // 重新打开：如果此刻确实还有进行中的任务，立刻补一次下发（不节流），
    // 否则用户会看到"打开了但通知没回来"。
    // build156：补推之前先按同一套时限收一遍 —— 关掉开关的那段时间里延时同样
    // 可能没跑（进程被冻结），不先收就会把一条早就该收回的行重新贴回去。
    _trackDeadlines();
    await _reclaimExpired();
    if (serviceEligible(_tasks.values).isNotEmpty) await _push(force: true);
  }

  Future<void> upsert(LiveTask task) => _apply(() => _tasks[task.id] = task);

  Future<void> upsertAll(Iterable<LiveTask> tasks) => _apply(() {
        for (final t in tasks) {
          _tasks[t.id] = t;
        }
      });

  Future<void> remove(String id) => _apply(() {
        _tasks.remove(id);
        _terminalAt.remove(id);
      });

  // ═══════════════ build148（真机反馈④）：终态要让人看见，不许"直接消失" ═══════════════

  /// 完成/失败那一行在通知上停留多久再撤。
  ///
  /// 为什么必须有这个东西（用户原话「报错提示X，完成✅，不要直接消失」）：
  /// 本批之前任务一结束就是 `remove` → 通知**整条撤掉**，岛上从来没有"结果"这一态
  /// （`LiveNotification.kt:102` 的契约注释里写着每任务带 `done`，
  /// 而 Dart 侧 `LiveTask` 没有这个字段、原生也从没读过它 —— 注释承诺了一个
  /// 双方都没实现的东西）。用户看到的"跑着跑着没了"就是这条路径的必然结果。
  /// 停留时长不是发明：vivo 原子岛的 `keepDuration`（结束态可保留，上限 1 小时）、
  /// OPPO 流体云"无新推送即销卡、胶囊最长 5 分钟"都是厂商明文支持的做法；
  /// Google 的实时活动规范反过来要求**结束后及时移除**（长期滞留会被撤权），
  /// 所以这里取"看得见结果"与"不占地方"之间的秒级值，而不是学厂商挂几分钟。
  static const Duration terminalHold = Duration(seconds: 8);

  final Map<String, Timer> _terminalTimers = <String, Timer>{};

  /// build157（第 15 轮扫描 P2）：终态行**进入终态的时刻**，给同步兜底扫。
  ///
  /// 为什么光有上面那个 8 秒 Timer 不够：Dart 的 Timer 在进程被冻结时不会跑
  /// （这个前提就是本文件自己写的），而终态行**故意不进** [_startedAt]
  /// （[_trackDeadlines] 里 `t.isTerminal` 被排除），于是[_reclaimExpired] 那道
  /// 同步兜底也看不见它。两条路一起漏的形状是：
  /// 任务刚完成 → 用户 8 秒内锁屏 → isolate 冻住 → 「✓ 已完成」永远挂在通知栏/岛上，
  /// 而且 `serviceEligible()` 把终态行算作需要前台服务 ⇒ 那个服务也跟着白挂着。
  /// 现在快路径仍是 Timer（秒级、不占 CPU），慢路径是这张表（回前台 / 下一次
  /// upsert / 退后台补推时立刻收），两条都指同一个判据 [terminalHold]。
  final Map<String, DateTime> _terminalAt = <String, DateTime>{};

  /// 把任务换成一条**终态**行（✅/✗ 在标题里），停留 [terminalHold] 后再撤。
  ///
  /// 只改标题与 detail、不改 id/kind/route ⇒ 通知还是同一条，不会"撤了又冒一条新的"。
  /// 同一 id 再次 [finish]/[remove]/[upsert] 时旧的定时器一律先取消：
  /// 否则用户连点两次，第一次那条 8 秒后的延时撤条会把第二次**正在跑**的通知撤掉。
  ///
  /// build168 ①/#97（真机反馈缺陷 97）：**「等你回答」那一档不进这条撤销队列**。
  /// 出处是 `docs/UI_MOCK_island_states_20260926.html` 那张表的最后一列：
  /// 完成 / 出错两态是"停 8 秒后撤"，而"需要你处理"写的是**不撤，一直挂着**。
  /// 道理与 [deadlineFor] 里 `askUser => null` 同一条：那一行等的是**人**，不是网络，
  /// 8 秒到点把它收走 = 机主 27 日那句原话「任务停在他面前却没有任何一处告诉他人」。
  /// 这里**只做"不排队"这一件事**：[terminalHold] 那张 8 秒表一个数字都没动，
  /// 备份 / 视频 / 资源包那几类任务的停留时长与本次改动逐字节无关
  /// （按态把那张表整个重排会牵动它们，属另一片，见 #97 报告）。
  /// 为什么连 `_terminalAt` 也要摘干净：那一格是 [terminalHold] 的**慢路径**
  /// （进程被冻结时 Timer 不跑，靠 [_reclaimExpired] 现问），只撤快路径等于
  /// 回前台那一下又被收掉 —— 两条路必须一起绕开，判据只住 [_holdsUntilAnswered] 这一处。
  Future<void> finish(LiveTask terminal) async {
    _terminalTimers.remove(terminal.id)?.cancel();
    _terminalAt.remove(terminal.id);
    if (_holdsUntilAnswered(terminal)) {
      await upsert(terminal);
      return;
    }
    _terminalAt[terminal.id] = _now;
    await upsert(terminal);
    _terminalTimers[terminal.id] =
        Timer(terminalHold, () => unawaited(_expire(terminal.id)));
  }

  /// build168 ①：这一行该不该**挂着直到人来**（快慢两条撤除路径共用的唯一判据）。
  ///
  /// 只认 [LiveTask.waitingUser]，不认 [LiveTaskKind.askUser]：后者是**提醒族**，
  /// 走 [upsert]/[remove] 从来不经过 [finish]，在这里把它算进来等于给一条不会
  /// 经过这条路的东西再写一遍判据（教训 #62）。
  static bool _holdsUntilAnswered(LiveTask t) => t.waitingUser;

  Future<void> _expire(String id) async {
    // 只撤"还是那条终态行"的：中途同 id 又开了新任务就不能误撤。
    final t = _tasks[id];
    if (t == null || !t.isTerminal) return;
    // 「等你回答」不撤（见 [finish] 那段）：这条是慢路径与历史遗留延时的共同闸口，
    // 少写这一句，`_terminalAt` 里被摘掉之前已经排上的那条旧延时仍会到点收人。
    if (_holdsUntilAnswered(t)) return;
    await remove(id);
  }

  /// 撤掉全部终态延时，并把这些**已经结束的**行一并从真源里删掉。
  ///
  /// build155（第 13 轮）：旧实现只 `cancel()` 那些 8 秒延时、**不删行**，于是它自己
  /// 就是那句注释承诺要避免的东西 —— 撤了延时之后，留在 `_tasks` 里的那条
  /// 「✓ 已完成」再也没有人撤（[_expire] 是唯一会删它的地方），下一次
  /// `_push(force)`（重开开关 / 退到后台补推）会把它重新贴回通知栏，**永远挂着**。
  /// 现在两件事一起做：延时要撤、行也要删。
  ///
  /// 只删 `isTerminal` 的行：进行中的行不归这里管（见 [setUserEnabled] 里 build145
  /// 那条「开关不该改真源」）。这里**故意不逐条走 [_apply]** —— 调用方紧接着就
  /// `_stopAll()` 把投影清空了，中间插 N 次下发只会平白多 N 次服务启停。
  Future<void> cancelAllTerminalHolds() async {
    for (final t in _terminalTimers.values) {
      t.cancel();
    }
    _terminalTimers.clear();
    _terminalAt.clear();
    _tasks.removeWhere((id, task) => task.isTerminal);
  }

  // ═══════════════ build156：时限（"失败了就及时给他收回来"）═══════════════

  /// 每条任务**第一次登记为进行中**的时刻（key = 任务 id）。
  ///
  /// 为什么不放进 [LiveTask]：`toJson()` 与原生契约、`liveDiag` 那套字符串解析都依赖
  /// `LiveTask` 现在的形状 —— 加一个时间字段等于改跨语言契约，本批只动时限这一件事。
  final Map<String, DateTime> _startedAt = <String, DateTime>{};

  /// 到点延时（与 [_terminalTimers] 同族：那条管"结果停留 8 秒"，这条管"最多跑多久"）。
  final Map<String, Timer> _deadlineTimers = <String, Timer>{};

  /// 时钟注入点，**只给测试用**（生产为 null ⇒ 真实时间）。
  ///
  /// 为什么必须有这个口子：`fake_async` 能冻结 `Timer`，**冻结不了 `DateTime.now()`**。
  /// 而这条修复要验的恰恰是"到点前不收 / 到点后收"，没有它就只能真的等 15 分钟，
  /// 或者退化成只测纯函数 —— 那测出来的红绿都不作数。
  DateTime Function()? clockForTest;

  DateTime get _now => (clockForTest ?? DateTime.now)();

  /// 到点之后顺手把**底层那件事**也停掉（由接线层挂，见 `live_task_wiring.dart`）。
  ///
  /// 中枢不许 import 下载/备份服务（分层），所以这里只有一个回调位；
  /// 接不接得上由接线层判断，**接不上只许写日志说不接得上，不许伪造"已取消"**。
  Future<void> Function(LiveTask task)? onDeadlineExceeded;

  bool _reclaiming = false;

  /// 时限账本：给新的非终态行登记 `startedAt` + 挂一条到点延时，并清掉不该再有的。
  ///
  /// 三条规则各有理由：
  /// · **同 id 再次 upsert 不重置 `startedAt`** —— 心跳式刷进度（下载每 2% 一次、
  ///   研究每轮一次）会把时限永远续下去，那还是"没限时"，只是换了个更隐蔽的写法；
  /// · **终态行与已从真源消失的行删账 + 撤延时** —— 同一 id 之后重开一次（用户重试）
  ///   是一次新动作，拿旧时刻判会一上来就被误收；
  /// · [deadlineFor] 为 null 的（askUser）不登记：它不该被收，也不该有空转的延时。
  void _trackDeadlines() {
    for (final id in _startedAt.keys.toList()) {
      final t = _tasks[id];
      if (t == null || t.isTerminal) {
        _startedAt.remove(id);
        _deadlineTimers.remove(id)?.cancel();
      }
    }
    final now = _now;
    for (final t in _tasks.values) {
      if (t.isTerminal || _startedAt.containsKey(t.id)) continue;
      final limit = deadlineFor(t.kind);
      if (limit == null) continue;
      _startedAt[t.id] = now;
      _armDeadline(t.id, now, limit);
    }
  }

  void _armDeadline(String id, DateTime startedAt, Duration limit) {
    _deadlineTimers.remove(id)?.cancel();
    final left = startedAt.add(limit).difference(_now);
    _deadlineTimers[id] = Timer(
      left.isNegative ? Duration.zero : left,
      () => unawaited(_expireDeadline(id)),
    );
  }

  /// **下发前**的同步兜底：把已过期的先收掉。
  ///
  /// 这是"及时"的那一半：延时被冻结时它是唯一会跑的东西（回前台 / 下一次 upsert
  /// 撞上来的时候立刻收，而不是等那个可能永远不来的下一次心跳）。
  /// `_reclaiming` 那个闩是必需的：回收会走 [finish] → [upsert] → [_apply]，
  /// 不设闩就是无限递归。
  Future<void> _reclaimExpired() async {
    if (_reclaiming) return;
    _reclaiming = true;
    try {
      // build157：先扫终态行。原来这里开头是 `|| _startedAt.isEmpty` 直接 return，
      // 而"任务全部跑完、只剩几条 ✓"恰好是 `_startedAt` 为空的那一种 ——
      // 也就是这条兜底**永远不会**在被需要的那一刻跑到。
      final nowT = _now;
      for (final e in _terminalAt.entries.toList()) {
        final t = _tasks[e.key];
        if (t == null || !t.isTerminal) {
          // 同 id 中途又开了一次（用户重试）：这张表里的旧时刻归 [_trackDeadlines] 管，
          // 这里只负责把它清掉，不许拿旧时刻判收。
          _terminalAt.remove(e.key);
          continue;
        }
        if (nowT.difference(e.value) < terminalHold) continue;
        await remove(e.key); // remove 自己会连带清 _terminalAt
      }
      if (_startedAt.isEmpty) return;
      final ids = expiredIds(
        tasks: _tasks,
        startedAt: _startedAt,
        deadlineFor: deadlineFor,
        now: _now,
      );
      for (final id in ids) {
        await _expireDeadline(id);
      }
    } finally {
      _reclaiming = false;
    }
  }

  /// 到点动作：把这一行换成一条**人话的终态行**（`… · 失败` + 「无响应，已收回 · 已等 N 分」），
  /// 走既有的 [finish] 从而享受同样的 [terminalHold] 可见期。
  ///
  /// **不直接 `remove`**：build148 定的规格是"用户要看得见结果"，
  /// "跑着跑着没了"正是这一批要修的形状，收回来也不能重蹈。
  /// 只动仍在真源里且仍非终态的那一条（[_expire] 那条口径同理：已经是结果的行不许改写成"无响应"）。
  Future<void> _expireDeadline(String id) async {
    _deadlineTimers.remove(id)?.cancel();
    final started = _startedAt.remove(id);
    final t = _tasks[id];
    if (t == null || t.isTerminal) return;
    final spent = started == null ? Duration.zero : _now.difference(started);
    _log.warn(
      '到期收回：${t.kind.name} id=$id 已等 ${liveElapsedLabel(spent)} 仍无终态',
      tag: 'Live',
    );
    final cb = onDeadlineExceeded;
    if (cb != null) {
      try {
        await cb(t);
      } catch (e) {
        // 取消入口自己炸了也不许影响收回这一步（岛还是得收）
        _log.warn('到期收回：取消入口失败 id=$id：$e', tag: 'Live');
      }
    }
    await finish(LiveTask(
      id: t.id,
      kind: t.kind,
      title: LiveTask.terminalTitle(t.title, ok: false),
      detail: '无响应，已收回 · 已等 ${liveElapsedLabel(spent)}',
      route: t.route,
      // 与 onResearchEnd/track 同口径：终态不留还在转的不确定条；
      // 停在最后一次真实进度（没有就从 0 起），**不假报 100%**。
      progress: t.progress ?? 0.0,
      indeterminate: false,
      done: true,
      ok: false,
      stages: t.stages,
    ));
  }

  /// 测试/复位用：把时限账本与延时清干净（不碰任务本身）。
  void clearDeadlineState() {
    for (final t in _deadlineTimers.values) {
      t.cancel();
    }
    _deadlineTimers.clear();
    _startedAt.clear();
    _terminalAt.clear();
  }

  /// 一次性结束：把该前缀的进行中任务全清掉（下载/备份收尾用）。
  Future<void> removeWhere(bool Function(LiveTask) test) =>
      _apply(() => _tasks.removeWhere((_, t) => test(t)));

  /// 整组替换：把 `[prefix]` 开头的进行中任务换成 [tasks]。
  ///
  /// 存在的理由是**通知侧的原子性**：一组来源（比如下载）若拆成「先 upsert 新的、
  /// 再 remove 旧的」两次 [_apply]，中间那次下发会同时显示新旧两条 —— 用户会在
  /// 一秒里看到「下载中 ×2」。这里一次变更、一次下发。
  Future<void> syncGroup(String prefix, List<LiveTask> tasks) => _apply(() {
        _tasks.removeWhere((id, _) => id.startsWith(prefix));
        for (final t in tasks) {
          _tasks[t.id] = t;
        }
      });

  Future<void> _apply(void Function() mutate) async {
    if (!_ready) return;
    final beforeSig = _structureSignature();
    final beforeMax = _lastMaxPercent;
    mutate();
    // build156：变更之后、下发之前 —— 先给新行登记时限，再把已过期的收掉。
    // 放在 mutate 之后：这一次 upsert 的新行也必须当场有 `startedAt`，
    // 否则一条"之后再没有第二次变更"的任务永远不计时（正是本次要修的那条路）。
    _trackDeadlines();
    await _reclaimExpired();
    final afterSig = _structureSignature();
    await _push(
      force: afterSig != beforeSig || _tasks.isEmpty,
      newMaxPercent: _computeMax(),
      lastMaxPercent: beforeMax,
    );
  }

  int _computeMax() => liveMaxPercent(serviceEligible(_tasks.values));

  /// build149（真机反馈「在这些地方退出没有灵动岛」）：退到后台那一刻**强制重推一次快照**。
  ///
  /// 为什么这一推有意义：Android 16 的 promoted ongoing（岛那张卡）是系统在
  /// **贴通知那一刻**判定的。我们的快照过去只在任务变化时下发 ⇒ 最后一次下发往往发生在
  /// **还在应用里**的时候，等于把判定时刻全部让给了"在前台"这一档。
  ///
  /// build155 订正：这一段原来的理由里写着"真机日志出现过 `canPost=true promotable=true`
  /// 但 `promotedFlag=false` 的组合（09-23 00:02:41）"。**那条证据不成立** ——
  /// 原生那半是把 `FLAG_PROMOTED_ONGOING` 从我们自己 `build()` 出来的副本上读的，
  /// 恒为 false（详见 `LiveNotification.postedDiag` 的注释）。重推这件事照做，
  /// 但它是按平台语义做的，不是按那行日志做的。
  ///
  /// 刻意**不在没有任务时推**：`_push` 对空集合会走 `_stopAll()`，
  /// 为了"顺手同步一下"把前台服务停掉/拉起都是多余的副作用。
  /// build157（第 15 轮扫描 P2）：回前台时只问一句"有没有该收的"，不做任何补推。
  ///
  /// 与 [resyncForBackground] 的区别是故意的：那个会**强制重贴**快照（出去那一刻
  /// 需要它抢 promoted 标记），而人在前台时重贴只是白打扰。这里纯粹跑一次
  /// [_reclaimExpired]（进行中时限 + 终态停留期两道清扫），空表时几乎零成本。
  Future<void> reclaimStaleRows() => _reclaimExpired();

  Future<void> resyncForBackground() async {
    if (!_ready) return;
    // build165（任务 #86）①：**第一件事**就是记心跳基线。
    // 为什么排在回收与补推之前：下面那几步都会往主线程与通道上排队，而进程可能
    // 就在这中间被冻住 —— 基线一旦没取到，回前台那一行就只剩"不定性"，
    // 这一整轮取证就白跑了（这正是本批要拿到的那个数）。
    await noteHeartbeatBaseline();
    // build156：`paused` 这一刻正是**延时最可能再也不跑**的时刻（进程马上要被冻结），
    // 所以先做一次同步回收：到点的行当场换成"无响应，已收回"，而不是挂到明天。
    _trackDeadlines();
    await _reclaimExpired();
    // 先问一次只读诊断，再决定推不推：`paused` 这一刻正是用户投诉的现场
    // （「回去就没岛」），而 `_push` 里那行日志有"变化才写"的节流 ⇒
    // 没任务可推的退出在旧日志里**一行都没有**，分不出"系统没提升"与"我们没问过"。
    await logDiagnostics('paused');
    if (serviceEligible(_tasks.values).isEmpty) return;
    await _push(
      force: true,
      newMaxPercent: _computeMax(),
      lastMaxPercent: _lastMaxPercent,
    );
  }


  /// 任务**集合**的结构指纹（不含 detail / 进度值）。
  ///
  /// 为什么不能只看数量：把「A 的下载」换成「B 的下载」数量不变，
  /// 旧实现据此判成「集合没变」⇒ 通知一直显示那条已经结束的 A（本轮用例抓到的真缺陷）。
  String _structureSignature() {
    final ids = serviceEligible(_tasks.values)
        .map((t) => '${t.id}|${t.title}|${t.progress == null ? '?' : '%'}')
        .toList()
      ..sort();
    return ids.join(';');
  }

  Future<void> _push({
    bool force = false,
    int? newMaxPercent,
    int? lastMaxPercent,
  }) async {
    if (!_ready) return;
    final eligible = serviceEligible(_tasks.values);
    final max = newMaxPercent ?? _computeMax();
    final now = DateTime.now();
    if (!_userEnabled && eligible.isNotEmpty) {
      // 开关关了：不推快照，顺手确保服务与通知都停了（幂等，代价一次 stop）
      if (!_lastSetWasEmpty) await _stopAll();
      return;
    }
    if (!shouldPostSnapshot(
      now: now,
      lastPost: _lastPost,
      setChanged: force,
      lastMaxPercent: lastMaxPercent ?? _lastMaxPercent,
      newMaxPercent: max,
    )) {
      return;
    }
    try {
      if (eligible.isEmpty) {
        await _stopAll();
        _lastSetWasEmpty = true;
        _lastPost = now;
        _lastMaxPercent = -1;
        return;
      }
      final kind = serviceFor(eligible.map((t) => t.kind)) ?? 'dataSync';
      // 记账**在发之前**：两个来源同时变更时，等回执再记账会让两边都按旧值判节流，
      // 结果是同一份快照被下发两次（或漏掉中间那一帧）。
      _lastPost = now;
      _lastMaxPercent = max;
      final diag = await _ch.invokeMethod<String>('syncTasks', {
        'snapshot': liveSnapshotJson(eligible),
        'specialUse': kind == 'specialUse',
      });
      // 原生每次渲染都带回两半：`|` 前是**我们这条通知合不合条件**
      // （canPost / promotable / localPromotedFlag / template / channel / notifEnabled），
      // 后是**系统侧回读**（active / id / promotedFlag / ongoing / summary / template）。
      // 只在**变化时**写日志：「为什么没有岛」必须有数可看，不能再靠猜（键盘判据塌过三次
      // 就是这么来的）；不变也要留痕的那条路走 [logDiagnostics]。
      if (diag != null && diag.isNotEmpty && diag != _lastDiag) {
        _lastDiag = diag;
        _log.info('渲染诊断 $diag', tag: 'Live');
      }
      _serviceInUse = kind;
      _lastSetWasEmpty = false;
    } on MissingPluginException {
      // build145（第 9 轮 P2-12）：**不许永久放弃**。原来这里一句 `_ready = false`
      // 就把中枢关掉了，而没有任何路径会再跑 `initialize()` ⇒ 一旦在会话中途撞上
      // （热重载 / channel 抢注），后面所有 upsert/remove 全在 `_apply` 开头静默 no-op，
      // 最后那份快照就**永远钉在通知栏**上——正是"关了还在"那一族最坏的表现。
      // 现在记一条 warn 并当场重试一次初始化：成功就恢复，失败也只是多一行日志。
      _ready = false;
      _log.warn('LiveTask channel 未就绪，重试初始化', tag: 'Live');
      await initialize(userEnabled: _userEnabled);
    } catch (e) {
      // 通知层出错**不许**影响任务本身（下载还在跑、用户还在等结果）
      _log.warn('LiveTask 下发失败：$e', tag: 'Live');
    }
  }

  Future<void> _stopAll() async {
    try {
      await _ch.invokeMethod<void>('stopTasks');
    } catch (e) {
      _log.warn('LiveTask 停止服务失败：$e', tag: 'Live');
    }
    _serviceInUse = null;
  }

  /// build168 ②：这一次提醒**会不会被总闸压掉**（同步问，不等通道）。
  ///
  /// 为什么要把这一格暴露出去而不是让调用方去猜：默认档（总闸关）下 [alert] 直接
  /// early-return，调用方拿到的是一个 `void`、日志里一行都没有 ⇒ 损失是**静默**的。
  /// 现在调用方可以在贴之前就知道"这条不会上屏"，并据此在气泡里补那一格状态。
  /// 注意它**不是**一个新的用户开关：读的就是 build167 那一道总闸 + 通道就绪位。
  bool get alertBlocked => !_ready || !_userEnabled;

  /// 完成 / 失败 / 待回答提醒。[ongoing] 为真表示「挂着别消失」（ask_user 用）。
  ///
  /// 返回值 = 这一次**到底贴出去没有**（build168 ②）。[alert] 原来返回 `void`，
  /// 而"没贴"的两种原因（通道没就绪 / 总闸关着）都不留痕，于是「AI 想问你一个问题」
  /// 在默认档下凭空消失，读日志的人只能看到一片安静。
  /// 压掉时**必须记一行**（本仓口径：静默 = 不可排查），文案只住
  /// `utils/round_exit.dart` 那一份（[masterSwitchSuppressedAlertLog]）。
  Future<bool> alert({
    required String title,
    required String body,
    String route = '',
    bool ongoing = false,
    int? id,
  }) async {
    if (alertBlocked) {
      // 两种"没贴出去"分开写：`_ready=false` 是包/通道的问题，
      // 总闸关着是**机主自己的选择**（build167 有意保留），两句话不能混成一句。
      _log.info(
          _ready
              ? masterSwitchSuppressedAlertLog(title: title)
              : '提醒未下发（通道未就绪，非 Android 或旧包）：$title',
          tag: 'Live');
      return false;
    }
    final nid = id ?? (_alertSeq++);
    try {
      await _ch.invokeMethod<bool>('postAlert', {
        'id': nid,
        'title': title,
        'body': body,
        'route': route,
        'ongoing': ongoing,
      });
      return true;
    } catch (e) {
      _log.warn('LiveTask 提醒下发失败：$e', tag: 'Live');
      return false;
    }
  }

  Future<void> cancelAlert(int id) async {
    if (!_ready) return;
    try {
      await _ch.invokeMethod<void>('cancelAlert', {'id': id});
    } catch (e) {
      _log.warn('LiveTask 撤销提醒失败：$e', tag: 'Live');
    }
  }

  /// Android 13+ 的运行时授权。返回 null = 该设备不需要问（13 以下或已在系统设置里决定过）。
  Future<bool?> requestPermission() async {
    if (!_ready) return null;
    try {
      final r = await _ch.invokeMethod<bool>('requestPermission');
      permissionGranted = r;
      return r;
    } catch (e) {
      _log.warn('LiveTask 申请通知权限失败：$e', tag: 'Live');
      return null;
    }
  }

  Future<void> openNotificationSettings() async {
    if (!_ready) return;
    try {
      await _ch.invokeMethod<bool>('openNotificationSettings');
    } catch (e) {
      _log.warn('LiveTask 打不开通知设置：$e', tag: 'Live');
    }
  }

  /// build165（任务 #88）：跳系统里的设置页（目标见 [kBgGuideTargetAppDetails] /
  /// [kBgGuideTargetBatteryOpt]）。返回 **null = 原生确认 Intent 已发出**，
  /// 非 null = 一句人话的失败原因（调用方必须显示出来，不许吞）。
  ///
  /// 为什么回原因而不是回 bool：这一条能力的全部价值是"如实"——
  /// 真机取证（docs/BUGSCAN_build164_20260925.md ⑬）已经确认厂商那个后台活动开关
  /// **三方 App 读不到状态**，所以我们连"你拨了没有"都不能报，只能报"这一跳成没成"。
  /// 失败原因字符串**只由原生侧产出**（教训 #62），这里只补原生不可能知道的三种
  /// 通道级情形（没就绪 / 没回执 / 调用抛错）。
  ///
  /// 四个失败出口各打一行 [kBgGuideLogTag] 日志：下一次取证要回答的正是
  /// 「他到底进过那个页面没有」，没有这一行就只能靠他回忆。
  Future<String?> openSystemSettingsPage(String target) async {
    if (!_ready) {
      const why = '原生通道还没就绪（这个包没注册 LiveTaskPlugin，或不在 Android 上），跳转没有发生';
      _log.warn(bgGuideLogLine(target: target, ok: false, nativeReason: why),
          tag: kBgGuideLogTag);
      return why;
    }
    String? r;
    try {
      r = await _ch.invokeMethod<String>(kBgGuideMethod, {'target': target});
    } on MissingPluginException catch (e) {
      final why = '这台设备上没有 $kBgGuideMethod 这个原生方法（旧包或未注册）：$e';
      _log.warn(bgGuideLogLine(target: target, ok: false, nativeReason: why),
          tag: kBgGuideLogTag);
      return why;
    } catch (e) {
      final why = '跳转调用抛错：$e';
      _log.warn(bgGuideLogLine(target: target, ok: false, nativeReason: why),
          tag: kBgGuideLogTag);
      return why;
    }
    // 回执缺失 ≠ 成功：`invokeMethod` 在原生没回话时给 null，而 null 恰恰是"不知道"。
    if (r == null) {
      const why = '原生没有回执（跳转结果未知，不能当成已经打开）';
      _log.warn(bgGuideLogLine(target: target, ok: false, nativeReason: why),
          tag: kBgGuideLogTag);
      return why;
    }
    if (r == kBgGuideStatusOpened) {
      _log.info(bgGuideLogLine(target: target, ok: true), tag: kBgGuideLogTag);
      return null;
    }
    _log.warn(bgGuideLogLine(target: target, ok: false, nativeReason: r),
        tag: kBgGuideLogTag);
    return r;
  }

  /// 给设置页与日志用的一行画像。
  String describe() =>
      '服务=${_serviceInUse ?? '无'} 进行中=${serviceEligible(_tasks.values).length} '
      '待答=${askUserTasks(_tasks.values).length} 最大进度=${liveMaxPercent(serviceEligible(_tasks.values))}% '
      '开关=$_userEnabled 版本=$kAppVersionConst';
}
