import '../models/chat_message.dart';

/// 一轮**流式段**的两个时刻（第一次收到 chunk / 最后一次收到 chunk）+ 计数。
///
/// ## 为什么单独立一个类型（build164 #84 · 真机 1.7.106+163 两行日志）
///
/// 真机打出来的那两行是这样的：
/// `[ReAct] [Timing] 本轮 2 步 / 总 0 秒 / 最长间隔 0 秒（第 0 步 思考(thinking) →
///  第 1 步 思考(thinking)） / 测不出耗时 2 处`
/// 可同一轮在流上实际跑了 **30 秒**（后台分别收了 **717** 与 **1077** 个 chunk，
/// 见 `docs/BUGSCAN_build164_20260925.md` ①）。两边对不上不是算错，是**口径瞎**：
/// `totalSeconds` 取的是 `steps` 里最晚 ts − 最早 ts，而那 2 个 step 都是
/// **建消息时同一毫秒**打的 thinking 占位（差 ~50ms）⇒ 舍成 0；
/// chunk 到达时只往 `step.content` 追加字符串，**既不改动 ts、也不新增 step**
/// ⇒ 流上那 30 秒在这一行日志里根本不存在。
///
/// 所以补这一对时间戳。它们**只能由收流处喂进来**（`round_timing.dart` 这层看不见流），
/// 接线在 `chat_screen_react.dart` / `chat_screen_orchestrator.dart` 的收尾处做。
///
/// 三态纪律（本仓口径：不许把「我不知道」压成假事实）：
/// - `unknown` —— 调用方没接线 / 这条路径压根没有流式段 ⇒ 画像里明写「测不出（…原因）」，
///   **绝不塌成 0 秒**；
/// - 只有单侧时间戳、或末早于首（时钟回拨）⇒ 同样算测不出，原因照写；
/// - 两侧都有 ⇒ 打出秒数与 chunk 数。
class RoundStreamSpan {
  final DateTime? firstChunkAt;
  final DateTime? lastChunkAt;

  /// 收到的 chunk 数。`null` = 不知道（调用方没计数）；`0` 且两侧时刻都空 =
  /// 确实一个 chunk 都没收到 —— 这两件事必须能在日志里分开。
  final int? chunkCount;

  const RoundStreamSpan({this.firstChunkAt, this.lastChunkAt, this.chunkCount});

  /// 「这条路没告诉我」——未接线时的默认值，画像里会显式写成测不出。
  static const RoundStreamSpan unknown = RoundStreamSpan();

  /// 首末都齐且没倒挂才算测得出。
  bool get measured =>
      firstChunkAt != null &&
      lastChunkAt != null &&
      !lastChunkAt!.isBefore(firstChunkAt!);

  /// 末早于首：只有接线接错或时钟被回调才会出现，单独留一行原因而不是吞掉。
  bool get clockReversed =>
      firstChunkAt != null &&
      lastChunkAt != null &&
      lastChunkAt!.isBefore(firstChunkAt!);

  /// 首→末的秒数；**测不出时是 null，不是 0**。
  int? get seconds =>
      measured ? (lastChunkAt!.difference(firstChunkAt!).inMilliseconds / 1000).round() : null;

  /// 测不出的**原因**（人话）。分支顺序＝先看"两个时刻都没有"（没接线 / 0 帧），
  /// 再看"只有单侧"，最后才是倒挂 —— 顺序反了会把"根本没接线"说成"只拿到一侧"。
  String get unmeasuredReason {
    if (clockReversed) {
      return '测不出（末 chunk 早于首 chunk：时钟回拨或接线错）';
    }
    if (firstChunkAt == null && lastChunkAt == null) {
      if (chunkCount == null) return '测不出（调用方未喂流式段时间戳）';
      if (chunkCount == 0) return '测不出（本轮一个 chunk 都没收到）';
      return '测不出（记到 $chunkCount 帧但没喂时间戳）';
    }
    return '测不出（只拿到首/末一侧时间戳）';
  }
}

/// 收流处用的**可变**计数器：每个 chunk 到一次 `noteChunk()`，轮收尾 `toSpan()`。
///
/// 单独一个类，是为了让 ReAct 的接线只有一行调用、也不必自己维护两个 DateTime
/// （"第一次赋值"这种判据在流式循环里最容易写错——写成 `if (buf.isEmpty)`
/// 之类就会把"首帧是空帧"这种情况判成没开始）。
///
/// 时间戳默认取 `DateTime.now()`；调用方如果手上已经有帧自带的时间，
/// 用 `noteChunk(at: ...)` 传进来（两边必须是同一时钟源，否则 [RoundStreamSpan]
/// 的倒挂检测会把这一轮判成测不出）。
class RoundStreamTracker {
  DateTime? _first;
  DateTime? _last;
  int _n = 0;

  /// 已收到的 chunk 数（收流中途想打点进度就用它）。
  int get chunkCount => _n;

  /// 是否已经收到过至少一帧（比 `chunkCount > 0` 罗嗦，但读起来像人话）。
  bool get gotAnyChunk => _n > 0;

  void noteChunk({DateTime? at}) {
    final t = at ?? DateTime.now();
    _first ??= t;
    _last = t;
    _n++;
  }

  /// 一次都没记过 ⇒ 返回 [RoundStreamSpan.unknown]（"没接线"与"接了但 0 帧"
  /// 的区别就在 `_first` 是否为 null，见 [RoundStreamSpan.unmeasuredReason]）。
  ///
  /// 反过来说：本记录器**没法**自己区分"没接"与"流建立了但一帧没到"（没帧就不会
  /// 调 `noteChunk`）。调用方如果确知"流通了、0 帧"，直接手写
  /// `const RoundStreamSpan(chunkCount: 0)` 传进来，画像就会写
  /// 「测不出（本轮一个 chunk 都没收到）」而不是甩锅给接线。
  RoundStreamSpan toSpan() => _first == null && _n == 0
      ? RoundStreamSpan.unknown
      : RoundStreamSpan(firstChunkAt: _first, lastChunkAt: _last, chunkCount: _n);
}

/// kind → 人话短标签（日志里两种都留：括号外给人看，原 kind 给机器查）。
String reasoningKindLabel(String kind) => switch (kind) {
      'thinking' => '思考',
      'search' => '联网查找',
      'search_result' => '搜索结果',
      'ask_user' => 'AI 提问',
      'final_answer' => '已生成回答',
      'synthesis' => '多源合成',
      'route' => '路由判断',
      'context' => '上下文注入',
      'mcp_call' => 'MCP 调用',
      'skill_call' => 'Skill 调用',
      'workspace' => '工作区',
      _ => kind,
    };

/// 一轮思考步骤的**耗时画像**（纯函数，可单测）。
///
/// ## 为什么需要（build141 · 真机截图「思考过程 910 秒 / 末节点 906 秒」）
///
/// 用户 2026-09-21 深夜报「计时器问题（多次）超时计录」。截图那一轮：
/// 头部 910 秒，五个子节点前四个是 0.1/1.5/0.5/1.7 秒，最后一个 906 秒，
/// 而那一行已经写着「已生成回答（528 字）」——**答案早就出来了，表还在涨**。
///
/// 计时器本身没算错（`AppElapsed` 有 30 分钟上界，910 秒在界内），
/// 真正的问题是**这一轮的时间花在哪了，日志里一个字都没有**：
/// SSE 空闲闸（30s）只在「流已建立后断粮」时说话，
/// 而「上游 200 之后迟迟不吐字」「编排三步各等了多久」全是静默的。
/// ⇒ 用户只看见一个大数字，AI 只能猜。
///
/// 本类型把一轮的 `reasoningSteps`（每步自带 `ts`）压成一行画像：
/// 总耗时、步数、**最长的那段间隔发生在哪两种步骤之间**、以及「测不出耗时」的节点数。
/// 调用方在轮收尾时打这一行；超过 [RoundTiming.kRoundSlowGapSeconds] 按 warn 级打。
///
/// build164 #84 起还要带上 [RoundTiming.stream]（首/末 chunk 这一对时刻，由收流处喂进来）
/// 与 [RoundTiming.hitMaxTokens]（本轮是不是被 maxTokens 打满才收的口）：
/// 真机那两轮「总 0 秒 / 实际在流上跑了 30 秒」就是缺这两项。见 [RoundStreamSpan]。
class RoundTiming {
  /// 判「这一步等得离谱」的阈值（秒）。
  ///
  /// 取值理由：SSE 空闲闸是 30s，一次正常工具调用（MCP 路径规划 / 联网搜索）
  /// 实测 1–5s；连续多轮 ReAct 里单步 >2 分钟才值得单独点名，否则每轮都刷 warn。
  static const int kRoundSlowGapSeconds = 120;

  final int totalSeconds;
  final int stepCount;

  /// 最长的一段「上一步 → 这一步」间隔（秒）；不足两步时为 0。
  final int slowestSeconds;

  /// 最长间隔的**后一步**下标（0 基）；不足两步时为 -1。
  final int slowestIndex;

  /// 最长间隔两端是哪两种步骤（用于回答「卡在等什么」）。
  final String slowestFromKind;
  final String slowestToKind;

  /// 单步耗时**测不出**的节点数（build140 反馈② 的口径：测不出 ≠ 0 秒）。
  ///
  /// 专门用来对账「头部 910 秒、子节点加起来只有 3.8 秒」：
  /// 差值就是这些测不出的节点吃掉的，留个数，排查时不必再猜。
  final int unmeasuredCount;

  /// 步骤时间戳是否**单调不减**（按列表顺序）。
  ///
  /// 为什么单独记这一项：总时长取的是 max−min（与顺序无关），
  /// 而一旦系统时间被改过（NTP 校时 / 用户手动调表），max−min 会算出一个
  /// **巨大但无意义**的正数 —— 那正是当年「思考过程 58225 秒」那一族。
  /// 与其悄悄印一个假数，不如在画像里明说「时间戳非单调，别信总时长」。
  final bool monotonic;

  // ===== build164 #84：流式段 + maxTokens 事实位（只加口径，不改任何判据） =====

  /// 一轮的**流式段**（首 chunk → 末 chunk）。默认 [RoundStreamSpan.unknown]：
  /// 没接线的路径（例如编排轮）会在画像里显式写「测不出」，不会塌成 0 秒。
  final RoundStreamSpan stream;

  /// 本轮是否被 **maxTokens 打满**而收口。三态：
  /// `true` = 是（结论很可能是半截，见 `docs/BUGSCAN_build164_20260925.md` ③④：
  /// 23:17:18 那条定稿只有 147 字，而 `N11 truncated output` 就在前两秒）；
  /// `false` = 明确没打满；`null` = 这条路没告诉我。
  ///
  /// 注意：这只是**打印出来的事实位**，`isSlow` 的阈值判据一个字没动
  /// （本批口径：不顺手改行为判据）。
  final bool? hitMaxTokens;

  /// 这一轮**最早**的步时间戳（无步则 null）；与 [stepMaxAt] 一起只为算
  /// [roundSpanSeconds]，不参与任何判据。
  final DateTime? stepMinAt;

  /// 这一轮**最晚**的步时间戳（无步则 null）。
  final DateTime? stepMaxAt;

  const RoundTiming({
    required this.totalSeconds,
    required this.stepCount,
    required this.slowestSeconds,
    required this.slowestIndex,
    required this.slowestFromKind,
    required this.slowestToKind,
    required this.unmeasuredCount,
    this.monotonic = true,
    this.stream = RoundStreamSpan.unknown,
    this.hitMaxTokens,
    this.stepMinAt,
    this.stepMaxAt,
  });

  /// 是否值得按 warn 级记录。
  bool get isSlow => slowestSeconds >= kRoundSlowGapSeconds;

  /// 本轮**墙上时钟跨度**（步时间戳 ∪ 流式段两端），单位秒；一个时刻都取不到时 null。
  ///
  /// 为什么要单独有它：[totalSeconds] 的口径是「step 之间」，而真机那一轮 2 个 step
  /// 是同毫秒打的占位 ⇒ 总 0 秒。跨度把流上那 30 秒算进来，就是给这一行补的那个
  /// **能对上后台 chunk 探针**的数（717 / 1077 帧那两轮）。
  /// 两个数都留着：谁也不冒充谁。
  int? get roundSpanSeconds {
    DateTime? lo;
    DateTime? hi;
    for (final t in [
      stepMinAt,
      stepMaxAt,
      stream.firstChunkAt,
      stream.lastChunkAt
    ]) {
      if (t == null) continue;
      if (lo == null || t.isBefore(lo)) lo = t;
      if (hi == null || t.isAfter(hi)) hi = t;
    }
    if (lo == null || hi == null) return null;
    return (hi.difference(lo).inMicroseconds / 1000000).round();
  }

  String get _streamNote {
    final secs = stream.seconds;
    if (secs != null) {
      final cnt = stream.chunkCount;
      return ' / 流式段 首chunk→末chunk $secs 秒'
          '${cnt == null ? '（chunk 数未知）' : ' / $cnt chunk'}';
    }
    return ' / 流式段 ${stream.unmeasuredReason}';
  }

  /// maxTokens 那一位的三种写法。`未知` 必须自己占一行字面量 ——
  /// 把 null 省掉不印，就等于把「这条路没告诉我」压成了「没事」。
  String get _maxTokensNote => switch (hitMaxTokens) {
        true => ' / maxTokens 打满：是（本轮结论可能被截断收口）',
        false => ' / maxTokens 打满：否',
        null => ' / maxTokens 打满：未知（该路径未告知）',
      };

  /// 一行中文画像（日志用）。
  ///
  /// 两种名字都要有：人话给排查的人看，原 kind 给 grep / 对账用
  /// （只留人话就没法拿它去比对代码里的分支；只留 kind 就是回到「四行同名思考」）。
  String get line => stepCount < 2
      ? '本轮 $stepCount 步 / 总 $totalSeconds 秒（不足两步，无间隔可测）'
          '$_roundSpanNote$_streamNote$_maxTokensNote'
      : '本轮 $stepCount 步 / 总 $totalSeconds 秒 / 最长间隔 $slowestSeconds 秒'
          '（第 ${slowestIndex - 1} 步 ${_both(slowestFromKind)} → '
          '第 $slowestIndex 步 ${_both(slowestToKind)}）'
          '$unmeasuredNote$_roundSpanNote$_streamNote$_maxTokensNote'
          '$monotonicNote';

  /// 有流式段可算时才补「本轮跨度」——没有流式段时它和 [totalSeconds] 是同一个数，
  /// 印两遍只会让人以为这两个口径有出入。
  String get _roundSpanNote {
    final s = roundSpanSeconds;
    if (s == null || !stream.measured) return '';
    return ' / 本轮跨度（含流式段） $s 秒';
  }

  static String _both(String kind) =>
      kind.isEmpty ? '-' : '${reasoningKindLabel(kind)}($kind)';

  String get unmeasuredNote => unmeasuredCount == 0
      ? ''
      : ' / 测不出耗时 $unmeasuredCount 处';

  /// 时间戳不单调时的免责说明。
  ///
  /// 不带 emoji：`test/v2_ui_guard_test.dart` 的 R1 棘轮管的是源码里的字符串
  /// （教训 #173），日志文案同样不该新开一处 emoji。
  String get monotonicNote => monotonic
      ? ''
      : ' / 注意：步骤时间戳非单调（系统时间被改过或乱序读回），'
          '总时长与间隔仅供参考';

  @override
  String toString() => line;
}

/// 从一轮的 `reasoningSteps` 算出耗时画像。
///
/// 空列表 / 单步都安全返回（**不抛**）——调用点在 `finally` 里，
/// 收尾日志绝不能自己再把一轮搞崩。
///
/// ## build164 #84 新增的两个入参（接线用，两处调用点各喂一次）
///
/// - [stream]：本轮的**流式段**（首 chunk / 末 chunk + 计数）。收流处用
///   [RoundStreamTracker]，轮收尾 `stream: _roundStream.toSpan()`。
///   不传＝[RoundStreamSpan.unknown] ⇒ 画像里明写「流式段 测不出（调用方未喂…）」，
///   **不会**塌成 0 秒。
/// - [hitMaxTokens]：本轮是否被 maxTokens 打满而收口。三态 `bool?`
///   （`null` = 这条路没告诉我）。例：ReAct 收尾处
///   `hitMaxTokens: streamTruncated || n11Truncated`，取不到事实就留 null。
///
/// 两个入参都**只影响这一行日志的内容**，不影响 [RoundTiming.isSlow] 那类判据。
RoundTiming describeRoundTiming(
  List<ReasoningStep> steps, {
  RoundStreamSpan stream = RoundStreamSpan.unknown,
  bool? hitMaxTokens,
}) {
  // 步时间戳的 min/max 先统一算一遍：三个 return 都要带上它，
  // 否则「本轮跨度」会在最常见的两条早退路径上凭空消失。
  DateTime? stepMinAt;
  DateTime? stepMaxAt;
  for (final s in steps) {
    if (stepMinAt == null || s.ts.isBefore(stepMinAt)) stepMinAt = s.ts;
    if (stepMaxAt == null || s.ts.isAfter(stepMaxAt)) stepMaxAt = s.ts;
  }
  if (steps.isEmpty) {
    // 这里**不能**回一个丢掉入参的常量空像：0 步却收了 700 帧是真会发生的形状
    // （占位 step 没落进列表 / 编排回退那一刻），丢了流式段与 maxTokens 位
    // 就又回到「日志里什么都没发生」。
    return RoundTiming(
      totalSeconds: 0,
      stepCount: 0,
      slowestSeconds: 0,
      slowestIndex: -1,
      slowestFromKind: '',
      slowestToKind: '',
      unmeasuredCount: 0,
      stream: stream,
      hitMaxTokens: hitMaxTokens,
    );
  }
  final unmeasured = steps.where((s) => s.latencyMs == null).length;
  if (steps.length == 1) {
    return RoundTiming(
        totalSeconds: 0,
        stepCount: 1,
        slowestSeconds: 0,
        slowestIndex: -1,
        slowestFromKind: '',
        slowestToKind: '',
        unmeasuredCount: unmeasured,
        stream: stream,
        hitMaxTokens: hitMaxTokens,
        stepMinAt: stepMinAt,
        stepMaxAt: stepMaxAt);
  }
  var slowestMs = 0;
  var slowestIndex = 1;
  var monotonic = true;
  for (var i = 1; i < steps.length; i++) {
    // 时钟回拨（NTP 校时 / 用户改系统时间）会给出负间隔：按 0 计，不污染 max，
    // 但**必须记下来**——见 [RoundTiming.monotonic]，否则会印出一个巨大但无意义的总时长。
    final gap = steps[i].ts.difference(steps[i - 1].ts).inMilliseconds;
    if (gap < 0) monotonic = false;
    if (gap > slowestMs) {
      slowestMs = gap;
      slowestIndex = i;
    }
  }
  // 总时长取 **max − min**，不取「末步 − 首步」：`reasoningSteps` 正常是按时间追加的，
  // 但这一列要能扛住乱序（历史消息从库里读回来、flush 顺序与 ts 不一致等）。
  // 取末-首在乱序时可能算出负数或明显偏小，而 max−min 与顺序无关。
  var minMs = steps.first.ts.microsecondsSinceEpoch;
  var maxMs = minMs;
  for (final s in steps) {
    final t = s.ts.microsecondsSinceEpoch;
    if (t < minMs) minMs = t;
    if (t > maxMs) maxMs = t;
  }
  final totalMs = (maxMs - minMs) ~/ 1000;
  return RoundTiming(
    totalSeconds: (totalMs / 1000).round(),
    stepCount: steps.length,
    slowestSeconds: slowestMs ~/ 1000,
    slowestIndex: slowestIndex,
    slowestFromKind: steps[slowestIndex - 1].kind,
    slowestToKind: steps[slowestIndex].kind,
    unmeasuredCount: unmeasured,
    monotonic: monotonic,
    stream: stream,
    hitMaxTokens: hitMaxTokens,
    stepMinAt: stepMinAt,
    stepMaxAt: stepMaxAt,
  );
}
