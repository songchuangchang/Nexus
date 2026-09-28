/// build168：**一轮结束时"到底是谁把这一轮收掉的"**，以及由此分岔出的三处口径。
///
/// 为什么单独一个文件（而不是继续往 `chat_screen_react.dart` 的 finally 里加三元）：
/// 那个 finally 现在已经同时读 `endedEarly` / `bgAborted` / `reactLoopError` /
/// `dropArmed` 四件事，而"AI 这一轮是在问用户"这一格此前**根本没有被读** ——
/// 于是提问轮和成功轮在岛上长成同一句话（`· 已完成` + `ic_live_done`），
/// 而真实情况是任务停在他面前、不会自己往下走。把分岔收成一张表是这个文件唯一的存在理由
/// （教训 #62：判据只住一处，逐页补迟早漂成两种口径）。
///
/// 三条本仓已钉死的红线，这里的优先级就是照着它们排的：
///  · **提前结束既不写「已完成」也不写「失败」**（build150）——`quiet` 排在最前，
///    任何新状态都不许把它挤下去；
///  · **崩溃才写「失败 + 原因」**，而且原因必须是读到的，不许编；
///  · **没在跑的东西不许写"正在"**（build162）——所以「等你回答」这一档
///    不带进行式、也不画还在转的不确定条。
library;

/// 一轮的终态形状。
enum RoundExitKind {
  /// 正常定稿：岛写 `· 已完成` + `√` 端点图标。
  completed,

  /// 这一轮结束在「AI 问了一句、等人答」上：不是成功，也不是故障。
  waitingUser,

  /// 报错出口：`· 失败` + 原因 + `×`。
  failed,

  /// 本轮没正常跑完（用户停止 / 退页 / MCP 触顶 / E5 熔断 / 离开 App 被收起）：
  /// 连结果行都不留，走 `quiet` 撤条。
  quiet,
}

/// 终态分岔（纯函数，好测）。
///
/// 优先级即本文件的全部主张：**先问"是不是根本没跑完"，再问"是不是坏了"，
/// 最后才问"是不是在等人"**。倒过来排（先 `askUserPending`）会让用户按停止那一瞬
/// 恰好停在反问上的轮次得到一句「等你回答」——那既是假承诺（什么都不会重发），
/// 又把 build150 钉过的"提前结束两个都不写"改掉了。
RoundExitKind judgeRoundExitKind({
  required bool endedEarly,
  required bool bgAborted,
  required String? error,
  required bool askUserPending,
}) {
  if (endedEarly || bgAborted) return RoundExitKind.quiet;
  if (error != null) return RoundExitKind.failed;
  if (askUserPending) return RoundExitKind.waitingUser;
  return RoundExitKind.completed;
}

/// 岛上那一格的**状态词不住在这里**（build170 收口时删掉了这个函数）：
/// 「等你回答」与它的两个兄弟「已完成」「失败」是同一格、同一套拼法，
/// 三个词必须住同一个地方 —— 那里是 `LiveTask.terminalTitle()`。
/// 留一份在这里就是"同一条规则住在两个文件"的第 3 次复发（教训 #62），
/// 而本仓的下场从来是两处各自漂：胶囊那一格已经漂成了「待回答」（≤5 字的另一格，
/// 由 `test/build170_island_waiting_user_test.dart` 钉着它是**故意的**，不是巧合）。
///
/// 本文件只管两样：① 一轮结束的分岔（上面的 [judgeRoundExitKind]）；
/// ② **提醒被总闸压掉时**气泡要补的那两句（下面两个 `*BubbleNote`）
/// 与正文那一行（[askUserWaitingIslandBody]）—— 后三者都带 `isZh`，
/// 因为它们是**成句的话**，不是拼在标题尾巴上的状态词。
String askUserWaitingIslandBody({required bool isZh}) => isZh
    ? '模型问了一句，任务停在这里——不是失败，也不是跑完了'
    : 'The model asked a question and the round is parked here — '
        'not a failure, not finished';

/// 气泡上那一句「等你回答」（build168 ②：**没弹提醒时这份损失不许是静默的**）。
///
/// 背景总闸关着（默认档）时 `LiveTaskCenter.alert()` 直接 early-return —— 这是
/// build167 有意留的行为（关着的时候不许向系统要权限、也不许投影），**不改**。
/// 改的是"他什么都读不到"这一半：这一轮结束在反问上、岛与提醒都没出现时，
/// 气泡自己必须把这一格说清楚。与 `drop_continue.dart` 的 `bgPauseNote` 同一族
/// （写进 `assistantMsg.content` 尾部那一行），所以口径也必须同族：
/// 不写"正在重发"、不写"网络中断"、也不写"已完成"。
String askUserWaitingBubbleNote({required bool isZh}) => isZh
    ? '等你回答：模型问了一句，这一轮停在这里，不会自己往下走。'
    : 'Waiting for you: the model asked a question and this round '
        'stops here — it will not continue on its own.';

/// 提问轮在**没被定稿成答案**的那条出口上的气泡尾部行（同一条红线，两个形状）。
///
/// 为什么不复用上面那句：调用点还知道"本轮一个字答案都没有"和"模型问完就没下一轮"
/// 是同一件事，所以这里只保留一行，不写两遍（用户 26 日「废话太多了给我砍一刀」）。
String askUserUnansweredBubbleNote({required bool isZh}) => isZh
    ? '模型在这一轮问了你一句，循环到此结束——没有最终答案，也不是失败。'
    : 'The model asked you something in this round and the loop ended there — '
        'no final answer, and no failure.';

/// 收尾处**要不要**在气泡上补那一格、补哪一句（纯函数，本文件唯一被界面调的那一位）。
///
/// 返回 `null` = 正文一个字都不许动；返回字符串 = 用它替换 `assistantMsg.content`。
/// 形状照 `drop_continue.dart` 里那一族（有正文 ⇒ 原正文 + 空行 + 那一句；
/// 没正文 ⇒ 就那一句），差别只在这里连"要不要写"都判掉了：
///  · [projectionBlocked] 为假（总闸开着、通道就绪）⇒ 岛已经替他说过这一格，
///    屏上出现两遍同样的话读起来像这 App 在凑字数 ⇒ null；
///  · 为真（**默认档就是这样**：build167 有意让总闸关着时什么都不投影）
///    ⇒ 这一格不许是静默的，必须补。
/// 为什么不写成界面里的一段三元：那样这条判据就没有测试能打到，
/// 而"岛出没出"这件事在单测里只能靠这一个入口喂进去。
String? waitingUserBubbleNoteFor({
  required bool projectionBlocked,
  required String content,
  required bool isZh,
}) {
  if (!projectionBlocked) return null;
  final body = content.trim();
  if (body.isEmpty) return askUserUnansweredBubbleNote(isZh: isZh);
  return '$body\n\n${askUserWaitingBubbleNote(isZh: isZh)}';
}

/// 收尾处唯一要调的那一位：把"这一轮怎么收的"与"岛出没出"合成"正文改不改"。
///
/// 为什么还要这一层薄壳（上面那位已经判了两件事）：界面里那一行如果写成
/// `if (islandExit == …) content = waitingUserBubbleNoteFor(…)`，那么
/// **(哪一档) × (岛在不在) × (有没有正文)** 这张表就没有一条测试能打到了——
/// 测试只能直接调纯函数，而那半个判断住在界面文件里、只有锚点看着。
/// 合成到这里之后，界面只剩一次赋值，整张表可以在单测里逐格打。
/// `null` = 正文一个字都不许动（既包含"不是等人这一档"，也包含"岛已经说过"）。
/// [exit] 允许 null：那是"本轮还没收尾"（续写进行中，走 `onResearchUpdate` 不换终态），
/// 那一刻抢着写「等你回答」就是**在结果之前宣布结果**——build150/162 反复修的同一族假话。
String? waitingUserBubbleForRound({
  required RoundExitKind? exit,
  required bool projectionBlocked,
  required String content,
  required bool isZh,
}) {
  if (exit != RoundExitKind.waitingUser) return null;
  return waitingUserBubbleNoteFor(
    projectionBlocked: projectionBlocked,
    content: content,
    isZh: isZh,
  );
}

/// 「提醒被总闸压掉」那行日志（build168 ②：损失必须有痕）。
///
/// 不带 emoji（R1 的 U+2600–U+27BF 那一段），并且把"该去哪儿看"写进同一行：
/// 只说"被压掉"的话，读日志的人还是会去查通知栏；这一句要他一眼落到气泡那一行。
String masterSwitchSuppressedAlertLog({required String title}) =>
    '提醒被后台总闸压掉（未贴通知、未起岛）：$title —— 改由气泡那一行「等你回答」承担';
