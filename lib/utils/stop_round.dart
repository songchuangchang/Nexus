/// build155（真机反馈「岛上写已完成，回去 App 写我已手动停止」）：
/// 「用户按了停止」这个标记该不该在新一轮开始时被清掉 —— 唯一判据。
///
/// 为什么需要一个纯函数：这个布尔在**三个地方**被写（发送入口清、停止入口置、
/// ReAct 循环入口又清），而其中两次清的**时刻不同**：发送入口那次在任何 await 之前，
/// 循环入口那次在"连接测试 / 知识库 / RAG 向量化 / 人设装配"这一串 await **之后**。
/// 真机上那串装配要几十秒，用户就在这几十秒里按了停止 ⇒
/// 停止置的 true 被循环入口清成 false ⇒ 循环跑完、按"正常完成"收尾，
/// 于是灵动岛写「· 已完成」，而 App 里那条消息写的是"已手动停止" —— 两端各说一套。
///
/// build152 加循环入口那次清理，是为了治另一个真 bug：「点过一次停止后该会话永久失效」
/// （那时只有循环入口会清，直聊路径压根不走这条循环 ⇒ 标记永挂 true）。
/// 所以**不能简单删掉那次清理**：那会把 152 的修复一起删了。
/// 正确形状是给停止请求带上"它是哪一轮的"：
///   · 新一轮开始：`round` 自增；
///   · 用户按停止：记下 `_stopRound = 当前 round`；
///   · 循环入口：**不是清 false，而是问"这一轮被停过吗"**。
/// 于是 152 的语义仍在（每一轮开始时旧轮的停止不再影响新轮），
/// 155 的症状也没了（本轮内、循环开始之前到达的停止被保留）。
///
/// 纯函数、无副作用，因此可单测（真机时序在测试里没法复现，但这条判据可以）。
bool reactStopCarried({required int stopRound, required int round}) =>
    // round <= 0 是第一轮之前的哨兵值（字段初值 -1/0），此时一律不认停止。
    round > 0 && stopRound >= round;

/// 循环提前结束时，追加在回答末尾那一句**该说成谁干的**（build155）。
///
/// 为什么单独一个纯函数：`_reactLoopStopRequested` 这个布尔有四个写入方 ——
///   ① 用户在停止键上按（`_stopGeneration`）；
///   ② 退页 `dispose()`；
///   ③ 单条消息里 MCP 调用数触顶（`chat_screen_react.dart` 的 `maxMcpCallsPerMessage`）；
///   ④ E5 重复调用熔断（同一指纹重复 N 次，"keep produced content"）。
/// ②③④ 都不是用户的动作，可收尾文案过去一律写成 `_(用户已终止思考，输出当前进度)_`
/// 并**落进会话库** —— 深度研究跑满调用上限是很常见的一条路，于是用户在自己的
/// 聊天记录里看到一句他没做过的操作。这是往记录里写假话，不是"文案不够好"。
///
/// 控制流照旧用"要不要停"那个布尔（②③④ 本来就该停），**只有这句话**分得清是谁。
/// 岛的收尾也不跟着改：提前结束的那一轮既不写「已完成」（把截断说成完成是另一个
/// 方向的假话）也不写「失败」，仍旧安静撤条。
String stopNote({
  required bool userStopped,
  required bool hasContent,
  required bool isZh,
  String activityZh = '思考',
  String activityEn = 'thinking',
}) {
  if (userStopped) {
    return hasContent
        ? (isZh
            ? '_(用户已终止$activityZh，输出当前进度)_'
            : '_(User stopped $activityEn, showing current progress)_')
        : (isZh
            ? '_(用户已终止$activityZh，未生成有效回答)_'
            : '_(User stopped $activityEn, no valid answer generated)_');
  }
  // 「系统提前结束」而不是「已达上限」：这一句要同时覆盖触顶、熔断、退页三种原因，
  // 而具体原因已经在日志里各有一行（`MCP call limit reached` / `E5 circuit break`）。
  return hasContent
      ? (isZh
          ? '_(本轮由系统提前结束$activityZh，输出当前进度)_'
          : '_(Ended early by the system, showing current progress)_')
      : (isZh
          ? '_(本轮由系统提前结束$activityZh，未生成有效回答)_'
          : '_(Ended early by the system, no valid answer generated)_');
}

/// 一条流被关掉时，**到底是谁干的**（build158，用户 2026-09-25 那份导出的直接后果）。
///
/// build165（#87）加 `leftAppAborted` 这一格：那一类关闭既不是用户按的、也不是网络故障，
/// 而是**我们自己在 `paused`/`hidden` 那一刻把连接收起来的**。旧形状下它没有自己的格子，
/// 只能被读成 `userStopped`（复用 `_reactLoopStopRequested`）或 `networkDropped`
/// （对端关线的错误形状），两者都是谎报。真机依据（nexus_export_2026-09-26T08-04-13，
/// 包 1.7.107+164）：带后台的 7 轮里 5 轮只收到 0~1 个 chunk，08:03 那轮探针明写
/// 「离开 46s，一个 chunk 都没收到 ⇒ 乙：整条流在后台停摆」，而 8 次报错**全部落在
/// `Lifecycle: resumed` 之前 0.10~0.19 秒** —— 那是"进程被冻 ⇒ 没人读 socket ⇒
/// 缓冲填满 ⇒ 上游关线，解冻的一瞬 read 才报错"的形状，读成"网络坏了"就永远修不到点上。
/// 所以本端在冻结**之前**自己收线，而这件事必须有第三态：`_reactLoopStopRequested`
/// 一格都不许再蹭（build158 修的就是"掉线谎报成用户停止"，把本端收起说成用户停止
/// 是同一个谎的另一个方向）。状态的判据与文案住在 `drop_continue.dart`（教训 #62）。
enum StreamEndKind {
  userStopped,
  systemEnded,
  networkDropped,

  /// 本端因"人离开 App"主动收起这条流（build165 ①）。
  leftAppAborted,
  other
}

/// 上面那个枚举的判据（纯函数，可单测）。
///
/// 为什么必须有：真机日志里同一毫秒有两行互相矛盾的话 ——
/// ```
/// 07:19:55.395 [ERROR] [Api] ClientException during streamChat（非本端关闭）
/// 07:19:55.396 [REACT] Loop stopped by user (stream closed): Network error: Connection closed…
/// ```
/// 下面那行来自 `isUserStop = _reactLoopStopRequested ||
/// e.contains('Connection closed') || e.contains('closed while receiving')`
/// —— **把"网络断了"当成"用户按了停止"**。代价不是文案不准而已：
/// 走进那一支就不会设 `reactLoopError`，于是 finally 那次
/// `onResearchEnd(error: null, quiet: endedEarly=false)` 在灵动岛上写成
/// **「AI 思考 · 已完成」**，而那一轮其实一个字的答案都没交付完
/// （49 秒里收了 747 个 chunk，然后连接被对端关闭）。
/// 用户报的「后台还是不行」与此同一条：岛说完成了，App 里只有一句
/// 「_(本轮由系统提前结束思考，输出当前进度)_」，没有重试入口、也没有网络原因。
///
/// 判据顺序（**先问人，再问是不是我们自己关的，最后才问网**）：
///  · 用户真按过停止（`userStopped`）⇒ `userStopped` —— 这条优先，
///    即使同一轮里网络也断了，用户看到的仍是"我停的"，不会多出一条假故障；
///  · `leftAppAborted`（build165 新增）⇒ 本端在离开 App 时收的线。这一格**必须排在
///    错误串匹配之前**：我们自己 `client.close()` 之后 dart:io 抛回来的正是
///    `Connection closed while receiving data` / `Software caused connection abort`
///    那两条（用户日志里 8 次报错全是这两个形状），先匹配串就会把本端行为说成网络故障；
///  · 有停止请求但不是用户（退页 / MCP 触顶 / 熔断）⇒ `systemEnded`，
///    保持 build155 那条"既不写已完成也不写失败"的口径；
///  · 没人请求停止，而对端把连接关了 ⇒ `networkDropped`；
///  · 其余 ⇒ `other`，调用方按原来的崩溃路径处理，不强行归类。
///
/// [leftAppAborted] 由调用方用 `leftAppAbortCarried`（`drop_continue.dart`，
/// 那个状态的判据只住在那里）算好后传进来；默认 false ⇒ build158/161/162 的
/// 三条既有路径与既有测试一字不改地成立。
StreamEndKind classifyStreamEnd({
  required bool stopRequested,
  required bool userStopped,
  required String errorText,
  bool leftAppAborted = false,
}) {
  if (userStopped) return StreamEndKind.userStopped;
  if (leftAppAborted) return StreamEndKind.leftAppAborted;
  if (stopRequested) return StreamEndKind.systemEnded;
  // 只有 dart:io / http 那几种"传输中途对端收线"的形态才算网络中断。
  // 刻意不用 `SocketException` 这类名字匹配：`ClientException` 已经把原因写成人话，
  // 而超时那一类有自己的去处（SSE 空闲闸 / 自动重试），混进来会把可重试说成断线。
  final lower = errorText.toLowerCase();
  const markers = [
    'connection closed',
    'closed while receiving',
    'connection reset',
    'broken pipe',
    'connection abort',
  ];
  if (markers.any(lower.contains)) return StreamEndKind.networkDropped;
  return StreamEndKind.other;
}

/// 网络中断时追加在回答末尾那一句（build158）。
///
/// 与 [stopNote] 的分工：那条说"是谁停的"，这条说"是网断的"。
/// 文案必须给得出**下一步做什么**，否则只是把"出错"换了个说法。
/// 不用 ⚠️ 之类的 emoji 开头：`test/v2_ui_guard_test.dart` 的 R1 就是这个口径
/// （本轮基线跑红过一次，正是这四条新字符串 +4 ⇒ 改回纯文字，而不是抬基线）。
String networkDropNote({
  required bool hasContent,
  required bool isZh,
}) =>
    hasContent
        ? (isZh
            ? '网络中断：回答收到一半连接被关掉，上面是已收到的部分。点 ↻ 重试可接着要全文。'
            : 'Connection dropped mid-answer; the text above is what arrived. Tap ↻ to retry.')
        : (isZh
            ? '网络中断：连接在收到答案之前被关掉，本轮没有结果。点 ↻ 重试。'
            : 'Connection dropped before any answer arrived. Tap ↻ to retry.');
