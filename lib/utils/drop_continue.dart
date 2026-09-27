// build161（机主原话「后台还是不行」「修了他妈十几次了」）的判据层。
//
// 真机日志已经把病灶钉死了：切后台之后进程**没冻**、chunk 一直在进
// （11:48:43 切后台 → 21 秒收了 997 个 chunk → `Connection closed while
// receiving data`）。缺的不是"让流别断"，是**断了之后这一轮没人跑完**：
// build158/159/160 把岛和气泡的"说法"修对了（✗、掉线文案、↻ 重试），
// 但那半截正文还停在那里 —— 重试 = 整轮重跑（重发提问、重烧检索轮），
// 没人拿着已收内容"接着写"。本轮补两件事，判据全在这个文件里（纯函数、可单测）：
//  ① 掉线自动续一轮 —— [decideDropContinue] 是唯一裁判（额度/停止接管/空正文）；
//  ③ 气泡常驻「接着写」—— 161 那年它的出现判据是 [hasNetworkDropNote]
//     （build165 起换成 [continueEntryKindFor]，见下面第 ③ 条）。
//
// build162（同一位病灶的下半段）：① 的**时机**改到"回到前台那一刻"，判据与额度不变
// —— 见本文件末尾 [DropContinuePlan] / [DropContinueScheduler] 那一段的真机日志结论。
//
// build165（#87，机主 08:04 那份导出 + 原话「我给他终止了」「回去之后他又重新开始搞」）：
// ① 退到后台时**本端主动**收起这条流（[shouldAbortStreamOnLeaveApp] / [LeftAppAbortSignal]），
//    这一态既不是用户停止也不是网络故障，判据与文案都在本文件（[leftAppAbortCarried]、
//    [bgPauseNote]、[bgPauseIslandLabel]）；
// ② 回到 App 为它重发一次（[DropContinueScheduler.armAtLeaveAppAbort] +
//    [bgRestartRunningIslandLabel]），账单不静默（[bgRestartBillingLine]）；
// ③ "0 正文也给按钮"：按钮的出现判据从 [hasNetworkDropNote] 换成
//    [continueEntryKindFor]，**按钮写什么由那个判据一并给**（[continueEntryLabel]）——
//    整轮重跑的那种一律写「重新发起这一轮」，不许再写"接着写"。
//
// build167（机主 26 日 18:4x 装完 166 那句「第一个问题我开了后台，退出来又给我暂停」，
// 取证见 `docs/BUGSCAN_build166_20260926.md` ③）：① 的那道主动收流**从此挂在一道总闸上**
// （设置里那一项「愿意后台化」，持久化位住在 `lib/utils/background_run_switch.dart`）——
// 165 那句前提"进程反正会被厂商冻结、等它断只会得到一句假'网络中断'"只对**没给后台放行**
// 的设备成立；他给了放行之后我们再自己掐线，就是"一边让他开后台、一边假装后台不可能"。
// 判据因此多一个入参（[shouldAbortStreamOnLeaveApp] 的 `backgroundRunAllowed`）：
//  总闸开 ⇒ false，不收流；总闸关 ⇒ 与 166 逐字节同行为。**判断本身仍然只在这一个函数里**
// （`_onAppLeftForeground` 只负责把那个持久化位读出来传进来，教训 #62）。
// 同一轮补的还有 164 那条老洞：可续的内容从"只认正文"改成"**正文或思考落点**"
// （[decideDropContinue] 的 `hasReceivedThinking`）—— 不再掐线之后，纯 thinking 的轮
// 一旦在后台断了就会以"塌成报错"这个更难看的形状出现。最坏多付一轮 token（他 164 认过）。
//
// 为什么判据必须离开 `chat_screen_react.dart`：那个 catch 坐在异步洪水里，
// 上一轮就因为它和 `_reactLoopStopRequested` 的复位顺序隔着三个 await，
// 把掉线认成了用户停止（见 stop_round.dart 的 build158 注释）。
// 把"还要不要自动续"做成输入输出的纯状态机，上限才是能被测试钉住的上限。
import 'stop_round.dart';

/// 一条用户消息引发的这一轮，最多自动续几次。
///
/// 这不是配置项，是**成本承诺**：机主批准 ① 的原话条件是"最坏多付一轮 token"，
/// 多付几次他没批过。测试里用字面量 `1` 走一遍连续掉线（见
/// test/build161_bg_continue_test.dart 的证伪探针）：把这里改成 2，那条必红。
const int kMaxAutoContinuesPerUserRound = 1;

/// [decideDropContinue] 的输出：这次掉线之后怎么办。
enum DropContinueChoice {
  /// 带着已收正文自动续一轮（额度内、有正文、没人接管）。
  autoContinue,

  /// 落成失败态：气泡写「网络中断」那一句，常驻「接着写」按钮交给用户点。
  giveUpWithButton,
}

/// "还要不要自动续一轮"的唯一判据（纯函数，输入→输出，没有第三个状态）。
///
/// 三个输入各自钉一件事，缺一个都会回到"修了十几次"的形态：
///  · `autoContinued`：本轮已用掉的自动续次数。归属轮次由调用方按
///    `_reactRound` 记账（新一轮号一对不上，旧计数自动作废，不需要谁记得清零 ——
///    与 build155 `reactStopCarried` 同一配方）；
///  · `hasReceivedContent` / `hasReceivedThinking`：**这一轮有没有可续的内容**。
///    build161~166 只认正文（0 字掉线没有落点，`_continueFromMessage` 对空正文直接
///    return，自动续反而会在岛上留一条永远不增长的假「进行中」）。
///    **build167 改成"正文或思考落点"任一成立即可续**，改判据的是机主 26 日 18:4x
///    那条真机反馈（`docs/BUGSCAN_build166_20260926.md` ③-1，164 的取证原话是
///    「纯 thinking 轮在后台断了会塌成报错」）：总闸开着不再掐线之后，这条会以
///    更难看的形状出现 —— 一轮只有思考在飞的请求被断掉，屏幕上是 ❌ + 「网络中断」，
///    而不是"我们替他把这一轮跑完"。成本口径他 164 就认过：**最坏多付一轮 token**。
///    没有正文时这一笔欠的是**整轮重发**（[dropContinueEntryKindForDropped] 给答案，
///    兑现处与气泡上那枚按钮共用同一判据），不是"假装能接上断点"；
///    **反向锁**：正文与思考都没有时仍然只许 `giveUpWithButton` —— 一个字都没收到
///    的轮次没有可续的东西，替他再花一轮 token 就是无凭据的猜测。
///    `hasReceivedThinking` 刻意给默认值 `false`：那是 166 的行为，任何没接上这一格的
///    调用点都退回现状，不会凭空多花钱；
///  · `stoppedOrSuperseded`：用户在掉线前后按了停止 / 又发了新消息 ⇒ **不续**。
///    调用方用现成的 `_reactLoopStopRequested` / `_sendSeq` / 插话队列算好传进来，
///    本文件不新造任何标志。
DropContinueChoice decideDropContinue({
  required int autoContinued,
  required bool hasReceivedContent,
  required bool stoppedOrSuperseded,
  bool hasReceivedThinking = false,
}) {
  if (stoppedOrSuperseded) return DropContinueChoice.giveUpWithButton;
  if (!hasReceivedContent && !hasReceivedThinking) {
    return DropContinueChoice.giveUpWithButton;
  }
  if (autoContinued >= kMaxAutoContinuesPerUserRound) {
    return DropContinueChoice.giveUpWithButton;
  }
  return DropContinueChoice.autoContinue;
}

/// 掉线攒下的那一笔**能不能接断点**（build167，与气泡上那枚按钮同一份判据）。
///
/// 为什么必须存在而不是让兑现处回头看气泡：`_continueFromMessage` 只能从**正文**的
/// 断点往下接，一轮只有思考落点的（真机 7 轮里 5 轮如此，见本文件顶部 165 那段取证）
/// 点下去什么都不会发生 —— 那时发生的是整轮重跑，文案就必须写「重新发起这一轮」。
/// 「写着重新发起、点的却是接断点」与「写着接着写、点下去整轮重跑」是同一个谎的两面，
/// 所以这一格的答案与 [continueEntryKindFor] / [continueEntryLabel] 同源。
ContinueEntryKind dropContinueEntryKindForDropped(
        {required bool hasReceivedContent}) =>
    hasReceivedContent
        ? ContinueEntryKind.resumeFromBreakpoint
        : ContinueEntryKind.restartWholeRound;

/// 续写那一腿到底算不算跑完 —— ① 与 ③ 共用的**唯一**判据（教训 #62：一处语义一个实现）。
///
/// 两个条件缺一不可：
///  · [streamError] 必须是 null：`_continueFromMessage` 以前把流异常只 warn 就吞掉，
///    外面只拿得到"正文长没长"，于是**续写中途再掉线**会被判成成功 ——
///    岛写「· 已完成」、气泡不挂「网络中断」⇒ ③ 的按钮也不出现，
///    用户读到的是"答完了"，而那一轮根本没跑完。这正是 build150/158 清过的那一类假话，
///    所以这里不收窄成"只要能拿到异常就算失败"，而是**异常优先、再要求有增量**。
///  · [grew] 必须为真：连接活着但一个字没吐（上游空转/配额）不是掉线，
///    拿它去写「网络中断」就是把别的失败说成断线。
bool continueRoundSettledOk({
  required String? streamError,
  required bool grew,
}) =>
    streamError == null && grew;

/// 「网络中断」那一句挂在正文尾部的完整形态（含分隔空行）。
String _dropNoteSuffix(bool isZh) =>
    '\n\n${networkDropNote(hasContent: true, isZh: isZh)}';

/// 这条气泡是不是"收到过正文、被对端断掉"的失败气泡。
///
/// 中英两份都认：那句文案是**生成时**的语种写进正文并落库的，用户中途切换
/// 语言后气泡还在，判据必须照样认得它。
///
/// build165 起它**不再**是气泡上那枚按钮的出现判据（那条改成 [continueEntryKindFor]）：
/// 这里保持"只认有正文那一句、且要求前面有空行"的原语义，供收尾处判断
/// "正文是不是已经挂过掉线提示"，以及 `_settleFailedDropContinue` 的幂等闸
/// （build161 那批测试钉着它，一字未动）。
bool hasNetworkDropNote(String content) =>
    content.endsWith(_dropNoteSuffix(true)) ||
    content.endsWith(_dropNoteSuffix(false));

/// 这条气泡挂的是"因离开 App 被收起"那一句吗（build165 ①）。
///
/// 给收尾处用：那一轮已经挂着这一句时，不许再往上叠一句「网络中断」（两条互相矛盾的
/// 原因同一口气泡里读起来就是"这 App 在编"）。
bool hasBgPauseNote(String content) => [
      for (final isZh in const [true, false])
        bgPauseNote(hasContent: true, isZh: isZh),
      for (final isZh in const [true, false])
        bgPauseNote(hasContent: false, isZh: isZh),
    ].any(content.endsWith);

/// 气泡尾部那枚按钮**点下去会发生什么**（build165 ③，唯一判据）。
enum ContinueEntryKind {
  /// 真的能从已收的半截往下接 ⇒ 按钮写「接着写」。
  resumeFromBreakpoint,

  /// 没有可接的落点（一个字正文都没收到 / 被本端收起）⇒ 点下去是**整轮重跑**，
  /// 按钮必须写「重新发起这一轮」。
  restartWholeRound,
}

/// 三建成因 × 有没有正文 × 中英 —— 一张表生成全部形状。
///
/// 为什么做成表：按钮"出不出现""写什么""摘不摘得掉"以前各自认字符串，
/// 多一种形状就要在四处各改一遍（教训 #62 的另一种犯法形态）。
///
/// 表里存的是**裸句子**（不带分隔空行）：0 正文的那两种气泡里，那句提示**就是**
/// 整条正文（catch 写的是 `content = bgPauseNote(hasContent: false)` /
/// `networkDropNote(hasContent: false)`），拿"空行 + 句子"去 endsWith 会一个都认不出 ——
/// 那正是本轮要修的"屏幕上只剩一句话、什么都点不了"。摘句时仍优先连空行一起摘。
List<(String, ContinueEntryKind)> get _entryTails => [
      for (final isZh in const [true, false]) ...[
        (networkDropNote(hasContent: true, isZh: isZh),
            ContinueEntryKind.resumeFromBreakpoint),
        (networkDropNote(hasContent: false, isZh: isZh),
            ContinueEntryKind.restartWholeRound),
        (bgPauseNote(hasContent: true, isZh: isZh),
            ContinueEntryKind.restartWholeRound),
        (bgPauseNote(hasContent: false, isZh: isZh),
            ContinueEntryKind.restartWholeRound),
      ],
    ];

/// 尾部挂着上面任何一句 ⇒ 这一轮有可点的入口；否则 null（不给按钮）。
///
/// build165 ③ 要修的就是这里：旧判据（[hasNetworkDropNote]）**刻意不认**"0 正文"
/// 那一句，于是纯 thinking 的一轮（真机 7 轮里 5 轮如此）既不自动续、也不给按钮，
/// 屏幕上只剩一句"本轮没有结果" —— 机主看到的"从头开始搞，又什么都点不了"。
/// 现在照样给按钮，但按钮说的是真话（见 [continueEntryLabel]）。
ContinueEntryKind? continueEntryKindFor(String content) {
  for (final (tail, kind) in _entryTails) {
    if (content.endsWith(tail)) return kind;
  }
  return null;
}

/// 这枚按钮的文字：只有**真的能接上断点**的那一种才配「接着写」。
///
/// 为什么这是硬性要求而不是文案偏好：机主原话「回去之后他又重新开始搞」——
/// 那一轮只有 thinking，一个字正文都没收到，`_continueFromMessage` 无处可接，
/// 实际发生的是整轮重跑（重发提问、重烧检索轮）。按钮写"接着写"就是谎报，
/// 而谎报的代价他已经付过一次（build158 那一族）。
String continueEntryLabel(ContinueEntryKind kind, {required bool isZh}) =>
    kind == ContinueEntryKind.resumeFromBreakpoint
        ? (isZh ? '接着写' : 'Continue')
        : (isZh ? '重新发起这一轮' : 'Restart this round');

/// 摘掉尾部那句"这一轮没跑完"的提示，还回"已收到的正文"。
///
/// 三条入口（① 自动续、② 退后台重发、③ 用户点按钮）共用这一步：不摘的话，
/// `_continueFromMessage` 会把这半句提示当成模型已写的内容拼进历史、再往它后面接正文，
/// 越续越脏。没挂句子的原样返回（幂等）。
///
/// 先摘"空行 + 句子"（半截正文那一族，摘完一个字都不剩分隔符），再摘裸句子
/// （0 正文那一族：那句提示就是整条正文，摘完是空串 —— 正是"没有落点"的事实）。
String stripRoundAbortNote(String content) {
  for (final (note, _) in _entryTails) {
    for (final tail in ['\n\n$note', note]) {
      if (content.endsWith(tail)) {
        return content.substring(0, content.length - tail.length);
      }
    }
  }
  return content;
}

/// 旧名保留（同一实现）：只被"网络中断那一句"的调用方与既有测试用着。
String stripNetworkDropNote(String content) => stripRoundAbortNote(content);

/// 自动续写期间岛上那一行（要求：此刻必须还是"进行中"，且说的是事实）。
///
/// 为什么不能先 `onResearchEnd(error:)` 再悄悄复活：build150/158 修的就是
/// 岛的出口要分得清 —— ✗ 挂上去又撤下来，用户读到的仍是"失败了"。
/// `第 1/1 次` 就是把 [kMaxAutoContinuesPerUserRound] 这个额度摊开给人看：
/// 这是最后一次自动尝试，再断就要他自己点了。
String dropContinueIslandLabel({required int used, required bool isZh}) => isZh
    ? '网络中断，正在接着写（第 $used/$kMaxAutoContinuesPerUserRound 次）'
    : 'Connection dropped — continuing now (attempt $used/'
        '$kMaxAutoContinuesPerUserRound)';

/// 挂起待前台期间岛上那一行（build162）。
///
/// 刻意**不**复用上面那句"正在接着写"：这一刻没有任何流在跑，写"正在"就是
/// 本仓反复清掉的那类假话（build150/158/161 同族）。它说的是一件还没发生、
/// 但确定会发生的事：回到 App 就接着写。用户据此知道该回 App，而不是盯着
/// 一条永远不动的"正在"。
String dropContinuePendingIslandLabel({required int used, required bool isZh}) =>
    isZh
        ? '网络中断，回到 App 后自动接着写（第 $used/$kMaxAutoContinuesPerUserRound 次）'
        : 'Connection dropped — continues when you return (attempt $used/'
            '$kMaxAutoContinuesPerUserRound)';

/// 整轮重发那一笔**挂起待前台**时岛上那一行（build167）。
///
/// 为什么不是复用上面那句：那一行写的是"接着写"，而这种轮次一个字正文都没有，
/// 兑现时做的是整轮重跑（见 [dropContinueEntryKindForDropped]）。机主为这件事付过
/// 一次谎的代价（165「回去之后他又重新开始搞」），所以**能不能接断点决定文案**这条
/// 规矩现在要管到掉线这一族，不只是"被本端收起"那一族。
/// 与 [dropContinuePendingIslandLabel] 同一条红线：此刻没有流在跑，不许写"正在"。
String dropContinueWholeRoundPendingIslandLabel(
        {required int used, required bool isZh}) =>
    isZh
        ? '网络中断，回到 App 后自动重新发起这一轮'
            '（第 $used/$kMaxAutoContinuesPerUserRound 次）'
        : 'Connection dropped — this round restarts when you return '
            '(attempt $used/$kMaxAutoContinuesPerUserRound)';

/// 整轮重发那一笔**真的起飞了**时岛上那一行（build167，前台掉线当场起的那一支）。
///
/// 说"正在"是有凭据的：这一刻确实开始重跑这一轮了。它说的仍然是"重新发起这一轮"，
/// 不是"接着写" —— 那一轮没有断点可接。
String dropContinueWholeRoundRunningIslandLabel(
        {required int used, required bool isZh}) =>
    isZh
        ? '网络中断，正在重新发起这一轮（第 $used/$kMaxAutoContinuesPerUserRound 次）'
        : 'Connection dropped — restarting this round now (attempt $used/'
            '$kMaxAutoContinuesPerUserRound)';

/// 掉线自动续写期间岛上那一行的**唯一分岔**（build167：四个形状一张表）。
///
/// 两个轴都是现成的事实，不是新造的标志：
///  · [wholeRound] = 这一轮有没有可接的断点（[dropContinueEntryKindForDropped] 给的答案，
///    与气泡上那枚按钮的文案同源）；
///  · [startsNow] = 现在起（人在前台）还是攒着等回前台（[DropContinuePlan.startNow]）。
/// 为什么收成函数而不是让 `chat_screen_react.dart` 自己写那串三元：那里已经有一串
/// `bgAborted && dropArmed` 的分岔，把"哪种形状说哪句话"复制第二份到页面里，
/// 下一次加形状就一定只改一处（教训 #62 的犯法形态就是"逐页补"）。
String dropContinueIslandLabelFor({
  required bool wholeRound,
  required bool startsNow,
  required int used,
  required bool isZh,
}) {
  if (wholeRound) {
    return startsNow
        ? dropContinueWholeRoundRunningIslandLabel(used: used, isZh: isZh)
        : dropContinueWholeRoundPendingIslandLabel(used: used, isZh: isZh);
  }
  return startsNow
      ? dropContinueIslandLabel(used: used, isZh: isZh)
      : dropContinuePendingIslandLabel(used: used, isZh: isZh);
}

// ============================================================================
// build162：**时机**层。判据（[decideDropContinue]）管"该不该续"，这里只管"什么时候起"。
//
// 病灶（机主 16:45 那份真机日志，包 1.7.104+161，这条已定为前提，不再调查）：
//   16:40:30.952 Lifecycle: inactive        ← 他切后台
//   16:40:37.011 [Api] ClientException during streamChat（非本端关闭）
//   16:40:37.016 [CHAT] continue-from failed: Connection closed while receiving data
//   ⇒ 161 在后台里起的那条新流，5 秒内被同样掐掉。
// 结论：**只要人在后台，新起的流必然在几秒内被对端关闭** —— 所以"掉线当时立刻续"
// 这件事在后台里注定失败，161 把续写放在了错误的时刻。他报的"后台还是不行"就是这个。
//
// 本轮只改时机：arm 的判定、额度（[kMaxAutoContinuesPerUserRound]）、气泡形状、
// 岛的认领全部不动；前台掉线仍然立刻续（人在屏幕前，那条流活得下来）。
// 之所以做成输入→输出的纯状态机（而不是在 `chat_screen_react.dart` 里加一个 bool）：
// 那个 catch 坐在异步洪水里，上一轮就因为标志位的复位顺序隔着三个 await 把掉线
// 认成了用户停止（见本文件顶部注释与 stop_round.dart 的 build158 段）。
// ============================================================================

/// 一次掉线之后，自动续写**什么时候起**。
enum DropContinuePlan {
  /// 立刻起：人在前台（= 161 的行为，未改动）。
  startNow,

  /// 攒着，等回到前台那一刻起（build162 新增）。
  pendUntilForeground,

  /// 没有自动续这回事：气泡挂「网络中断」，③ 的「接着写」按钮交回用户。
  giveUpWithButton,
}

/// 攒下的那一笔"待前台续"。
///
/// 只带 **id** 不带消息对象：挂起期是几十秒到几天，中间用户可能删掉/撤回这两条
/// （删除/撤回**不**递增 `_reactGeneration`，任何代次守卫都认不出来），所以兑现时
/// 必须按 id 重新在消息表里找一遍、确认还活着 —— 拿旧对象去续就是 build148 那族
/// "给已删除的消息写库"的形状。
class PendingDropContinue {
  const PendingDropContinue({
    required this.assistantMsgId,
    required this.userMsgId,
    required this.isZh,
    required this.deep,
    required this.armedSeq,
    this.wholeRound = false,
  });

  /// 要续的那条 assistant 气泡。
  final String assistantMsgId;

  /// 岛上那一行挂在谁名下（`LiveTaskWiring` 全按用户消息 id 认，与 161 同口径）。
  final String userMsgId;

  /// 掉线那一刻的语种快照：文案是**生成时**的语种写进正文的（与
  /// [hasNetworkDropNote] 认中英两份同一条理由），用户中途切语言不该改这一句。
  final bool isZh;

  final bool deep;

  /// arm 那一刻的 `_sendSeq`：兑现时它变了 ⇒ 用户已用新一轮接管，作废（判据现成）。
  final int armedSeq;

  /// build165 ②：这一笔欠的是**整轮重发**（回到 App 重新发起这一轮），不是"从断点接上"。
  ///
  /// 必须带在挂起记录上而不是让兑现处去猜气泡：真机上被收起的那些轮 5/7 次一个字正文
  /// 都没收到（只有 thinking 在飞），兑现时按气泡判"有没有落点"会把它读成续写，
  /// 而 `_continueFromMessage` 对空正文直接 return ⇒ 用户等到的是"什么都不发生"。
  /// 这一位同时决定兑现时的**文案**（[bgRestartRunningIslandLabel] vs
  /// [dropContinueIslandLabel]）—— 整轮重跑写"接着写"就是谎报。
  ///
  /// build167 起它有了**第二个生产方**：掉线自动续写那一族里"只有思考落点、没有正文"
  /// 的那一笔也置 true（取值由 [dropContinueEntryKindForDropped] 给，不在调用点重写），
  /// 所以"这一笔是整轮重发"这件事从此与气泡上那枚按钮同源，兑现处认的还是同一位。
  final bool wholeRound;
}

/// 掉线续写的记账：额度用在哪一轮、有没有攒下待前台的那一笔。
///
/// 它是 build162 之后**唯一**持有这两件事的地方（161 的两个裸字段 `_dropContRound`
/// / `_dropContUsed` 搬进来，语义一行都没改）。放这里而不是放 State 里的理由与本文件
/// 顶部同一条：可被测试钉住的上限才是上限。
class DropContinueScheduler {
  int _quotaRound = 0;
  int _used = 0;
  PendingDropContinue? _pending;

  /// 已用掉的自动续次数（arm 之后读它，用于岛上的「第 N/1 次」）。
  int get used => _used;

  /// 攒着待前台的那一笔；没有则 null。
  PendingDropContinue? get pending => _pending;

  /// 本轮用掉的次数 —— 161 那句 `_dropContRound == _reactRound ? _dropContUsed : 0`
  /// 的原文：新一轮轮号对不上，旧计数自动作废，不需要谁记得清零。
  int usedIn(int round) => _quotaRound == round ? _used : 0;

  /// 掉线那一刻问一次：判据说"该续"（[DropContinueChoice.autoContinue]）之后，
  /// 现在起还是攒着。**额度在这里记，且与 161 完全一致：判定一通过就占 1 次**，
  /// 不论什么时候真正起飞 —— 挂起不等于"还没花钱"，它欠的就是那一次续写。
  DropContinuePlan armAtDrop({
    required int round,
    required DropContinueChoice choice,
    required bool inForeground,
    required PendingDropContinue pending,
  }) {
    if (choice != DropContinueChoice.autoContinue) {
      return DropContinuePlan.giveUpWithButton;
    }
    final usedBefore = usedIn(round);
    _quotaRound = round;
    _used = usedBefore + 1;
    if (inForeground) {
      _pending = null;
      return DropContinuePlan.startNow;
    }
    _pending = pending;
    return DropContinuePlan.pendUntilForeground;
  }

  /// 回到前台那一刻问一次：把攒下的那一笔**取走**并给结论。
  ///
  /// 先摘再决定 ⇒ 记账上"连续两次恢复前台"物理上不可能起两次（第二次没有可取的了）。
  /// [stale] 由调用方现算（新鲜度复核的实现全仓只有 `_dropContinueStale` 那一份）。
  /// 没攒过也返回 [DropContinuePlan.giveUpWithButton]：本来就不欠他一次自动续。
  DropContinuePlan takeOnResume({required bool stale}) {
    if (_pending == null) return DropContinuePlan.giveUpWithButton;
    _pending = null;
    return stale ? DropContinuePlan.giveUpWithButton : DropContinuePlan.startNow;
  }

  /// build165 ①②：退后台把这条流收起来之后，记一笔"回到 App 重新发起这一轮"。
  ///
  /// 与 [armAtDrop] 共用**同一本额度**（`_used` / `_quotaRound`）：机主批的是
  /// "最坏多付一轮 token"，不是"每种失败各多付一轮"。两处刻意不同：
  ///  · **不看收到几个字**（`decideDropContinue` 那条"**正文与思考落点都没有**才不给续"
  ///    的判据在这里不成立，build167 之后那条判据自己已经认思考落点了）：
  ///    真机 7 轮里 5 轮是 0~1 个 chunk、纯 thinking 的一轮根本没有可接的断点，
  ///    要的就是一次整轮重发，而不是"因为没落点所以什么都不做"（那正是他看到的塌法）；
  ///  · 永远 `pendUntilForeground`，不 `startNow`：人在后台时起的那条流就是本轮要被收起
  ///    的那一条（build162 的结论），当场重发等于把这条流再杀一次。
  /// [pending] 必须带 `wholeRound: true`（assert 钉住）—— 兑现时靠它区分
  /// "重新发起这一轮" vs "接着写"，写错就是谎报。
  DropContinuePlan armAtLeaveAppAbort({
    required int round,
    required bool stoppedOrSuperseded,
    required PendingDropContinue pending,
  }) {
    assert(pending.wholeRound,
        '退后台这一笔欠的是整轮重发，PendingDropContinue.wholeRound 必须为 true');
    if (stoppedOrSuperseded) return DropContinuePlan.giveUpWithButton;
    if (usedIn(round) >= kMaxAutoContinuesPerUserRound) {
      return DropContinuePlan.giveUpWithButton;
    }
    _quotaRound = round;
    _used = usedIn(round) + 1;
    _pending = pending;
    return DropContinuePlan.pendUntilForeground;
  }

  /// build165 ②：整轮重发会开一个新的轮号（`_reactRound` 跟着 `_sendSeq` 走），
  /// 把额度的**归属**搬到那个新轮号上。
  ///
  /// 不搬的后果不是抽象的：重发那一轮自己在后台又被收起时，`usedIn(新轮号)` 读到 0
  /// ⇒ 又攒一笔 ⇒ 用户每次进出 App 都白付一轮（他批的"最多一次"当场失效）。
  /// 只在"这一次发送是我们替用户发起的重发"时调用（`_sendMessage` 里那个一次性交接），
  /// 用户自己敲一条新消息走的是另一条路：那时 `_quotaRound` 与新轮号对不上，
  /// `usedIn` 自然回到 0，额度重新给满。
  void adoptRound(int round) {
    if (_used > 0) _quotaRound = round;
  }

  /// 只清记账、不做任何收尾（退页这一族用：岛的最后一句话由调用方自己给）。
  void clearPending() => _pending = null;
}

/// 自动续写**起飞之前**的新鲜度复核（纯判据：输入全是现成标志的快照，不新造标志）。
///
/// 161 把这份判据写成 `_runDropContinueRound` 开头那个 `stale` 局部 bool；162 多了
/// 一个起飞时刻（回到前台），两处查的是同一件事 ⇒ 判据抽到这里，宿主
/// `_dropContinueStale` 是**唯一**取这些标志的地方，两个时刻共用它
/// （教训 #62：一处语义一个实现，复制第二份就是给它一个自由漂移的机会）。
/// 六项的来历，一项都不许丢：
///  · [noAssistantMessage]：那条气泡已经不在了（按 id 找不到 / 已删已撤）⇒ 没有落点；
///  · [notMounted]：页面已销毁，续给谁看都是问题；
///  · [streaming]：已经有另一条流在跑（含用户手动点的「接着写」）；
///  · [stopRequested]：用户按了停止 ⇒ 他不要这一轮了（build155 那一族假话的源头）；
///  · [supersededByNewerRound]：`_sendSeq` 与 arm 那一刻对不上 ⇒ 新一轮已接管；
///  · [hasQueuedFollowup]：插话队列非空 ⇒ 用户在等自己那条新消息，别插队烧 token。
bool dropContinueStale({
  required bool noAssistantMessage,
  required bool notMounted,
  required bool streaming,
  required bool stopRequested,
  required bool supersededByNewerRound,
  required bool hasQueuedFollowup,
}) =>
    noAssistantMessage ||
    notMounted ||
    streaming ||
    stopRequested ||
    supersededByNewerRound ||
    hasQueuedFollowup;

// ============================================================================
// build165（#87）：**「因离开 App 而中止」这一态**。判据、状态机与文案全在这一段。
//
// 真机取证（nexus_export_2026-09-26T08-04-13-203835.txt，包 1.7.107+164，
// OPPO / ColorOS / Android 16 / targetSdk 36）—— 这是本轮改判据的**唯一**依据：
//   · 带后台的 7 轮里 **5 轮是 0 个或 1 个 chunk**；
//   · 08:03 那轮探针：「离开 46s，一个 chunk 都没收到 ⇒ 乙：整条流在后台停摆」；
//   · 错误形状两种（`ClientException: Software caused connection abort` 4 次、
//     `Connection closed while receiving data` 3 次），**8/8 次都落在
//     `Lifecycle: resumed` 之前 0.10~0.19 秒**；
//   · 前台服务当时在跑（`id=1001 ongoing=true`、`promotedFlag=true`、`canPost=true`）；
//   · 机主确认官方端点与中转站是**同一种失败形状** ⇒ 上游这条排除。
// 最自洽的机制：进程被厂商侧冻结 ⇒ 没人读 socket ⇒ 缓冲填满 ⇒ 上游关线 ⇒
// 解冻那一瞬 read 立刻报错（同时解释"时长随机"与"断口总在 resumed 之前"）。
// AOSP 那一层已用官方原文排除（Doze 要"未接电源+静止+灭屏一段时间"；带前台服务时
// 资源表写 "Network: No restrictions"；freezer 只 stop cached processes），
// 厂商侧**没有任何可申请免冻结的 API** ⇒ 能做的只剩一件事：**在被冻之前自己收线**，
// 把"未知的网络故障"换成"我们主动收起、并且欠他一次重发"。
//
// 为什么这一态必须独立、绝不能蹭 `_reactLoopStopRequested`：那个布尔在 catch 里
// 被读成"用户按了停止"（build158 修的就是这件事的另一个方向）。蹭它的后果是气泡写
// 「_(用户已终止思考)_」并**落库** —— 用户没按过停止，记录里却说他按了；而岛走 quiet
// 撤条，回到 App 什么都看不见。机主原话「我给他终止了」说的正是他**手动**终止这件事
// 不该由我们在背后替他做。
// ============================================================================

/// 「离开 App 时本端收起了这条流」这件事的记号。
///
/// 为什么要有这么个异常类：`stopGeneration` 会置 api 层的停止标志，那条流于是
/// **正常结束、不抛异常**（`api_service.dart` 的 `if (stopFlag[0]) return;`，
/// build141 为了"自我取消不许伪装成网络故障"特意写的）。所以流跑完之后的那一行必须
/// 主动把这次中止**交给外层 catch 的收口路径**，否则循环会照着"这一轮答完了"往下走，
/// 或在后台里开下一条流 —— 那正是探针抓到的"整条流在后台停摆"。
/// 走同一条 catch 路径而不是另写一处收尾，是为了守住
/// `lib/services/answer_finalizer.dart` 那条"定稿只有一个出口"的规矩。
class LeftAppAbortSignal implements Exception {
  const LeftAppAbortSignal();

  @override
  String toString() =>
      'LeftAppAbort: 本端在离开 App（paused/hidden）时收起了这条连接';
}

/// 「这一轮流是被『离开 App』收起来的吗」—— 这个第三态的**唯一**判据。
///
/// 配方与 build155 的 `reactStopCarried` 同一条：记"是哪一轮"而不是记一个 bool。
/// 刻意用 `==` 而不是 `>=`：收起连接这件事只属于当时在飞的那一轮，
/// 用户已经发了新消息（新轮号）之后再拿它去改口，就是把上一轮的说法安到这一轮头上。
bool leftAppAbortCarried({required int abortedRound, required int round}) =>
    round > 0 && abortedRound == round;

/// 生命周期变化那一刻，要不要动手收起这条流（唯一判据）。
///
/// 四个条件各挡一类具体的事故：
///  · [backgroundRunAllowed]（build167 新增）：设置里那道「愿意后台化」总闸。
///    **开 ⇒ 一律不收**：机主 26 日 18:4x 那句「第一个问题我开了后台，退出来又给我暂停」
///    说的就是这道闸还没存在时的自相矛盾 —— 我们一边让他去系统里给放行、一边自己掐线。
///    165 那套"等它断只会得到一句假『网络中断』"的推理，前提是**进程会被冻结**，
///    而那前提只对没给放行的设备成立。默认值 `false` 是刻意的：没拨过这一位的用户
///    走的还是 166 那条路，一行行为都没变（调用方从 `loadBackgroundRunAllowed` 读）；
///  · [leavingApp]：只认 `paused`/`hidden`（调用方由 `AppLifecycleState` 算好传进来）。
///    `inactive` 不算 —— 下拉通知栏、分屏、小窗都会报 inactive，那种时候收线等于
///    把人正在看的屏幕挖掉一块（与 `AppResumeSignal.inForeground` 同一口径）；
///  · [roundInFlight]：本轮**真有连接在飞**才收。装配阶段/两轮之间没有 socket，
///    那时收不到任何东西，硬记这一态就会在流**正常答完**之后把它误判成中止
///    （把一份好答案扔掉，比不停摆更糟）；
///  · [alreadyAborted]：同一条流不重复收（`hidden`→`paused` 会连着来两次）。
///
/// 总闸这一格**不许被复制到调用点**（教训 #62）：`_onAppLeftForeground` 只做
/// "读那个持久化位 → 传进来"，`if (backgroundRunAllowed) return;` 这种第二份判断
/// 一旦出现，两处就会各自漂移，而这一条判据的全部价值就是"下次能分清是系统冻了
/// 还是我们掐的"。
bool shouldAbortStreamOnLeaveApp({
  required bool leavingApp,
  required bool roundInFlight,
  required bool alreadyAborted,
  bool backgroundRunAllowed = false,
}) =>
    !backgroundRunAllowed && leavingApp && roundInFlight && !alreadyAborted;

/// 这一轮因离开 App 被收起时，挂在气泡尾部那一句（build165 ①，要说真话）。
///
/// 三条红线：不写"用户已终止"（他没按）、不写"网络中断"（是我们关的）、
/// 也不写"接着写"（这一轮多半一个字正文都没有，点下去是整轮重跑）。
String bgPauseNote({required bool hasContent, required bool isZh}) => isZh
    ? (hasContent
        ? '已暂停：离开 App 时收起了这条连接。上面是离开前收到的部分，回到 App 后重新发起这一轮。'
        : '已暂停：离开 App 时收起了这条连接，本轮还没有结果。回到 App 后重新发起这一轮。')
    : (hasContent
        ? 'Paused: this connection was closed when the app left the foreground. '
            'The text above is what arrived; it restarts the whole round when you return.'
        : 'Paused: this connection was closed when the app left the foreground, '
            'before any answer arrived. It restarts the whole round when you return.');

/// 收起那一刻岛上的那一行（人已经不在 App 前，这一行就是他回来前看到的最后一句话）。
String bgPauseIslandLabel({required bool isZh}) => isZh
    ? '已暂停：离开 App 时收起了这条连接'
    : 'Paused: connection closed when the app left the foreground';

/// 已攒下"回前台重发"时岛上的那一行：说的是"回去会重发"，不是"正在重发"。
String bgRestartPendingIslandLabel({required int used, required bool isZh}) => isZh
    ? '已暂停：回到 App 后重新发起这一轮（第 $used/$kMaxAutoContinuesPerUserRound 次）'
    : 'Paused: restarts this round when you return (attempt $used/'
        '$kMaxAutoContinuesPerUserRound)';

/// 真的重发那一刻岛上的那一行。
///
/// 与 [dropContinueIslandLabel]（「正在接着写」）的区别就是本轮的全部要点：
/// 这一轮**没有断点可接**，发生的是整轮重跑，所以这句必须写「重新发起这一轮」。
String bgRestartRunningIslandLabel({required int used, required bool isZh}) => isZh
    ? '回到 App，重新发起这一轮（第 $used/$kMaxAutoContinuesPerUserRound 次）'
    : 'Back in the app — restarting this round (attempt $used/'
        '$kMaxAutoContinuesPerUserRound)';

/// 重发那一次的账单行（build165 ④：**不许静默**）。
///
/// 数字来自重发那一轮落成的那条助手消息：整轮重发走的是既有的发送路径
/// （`_retryMessage` → `_sendMessage` → ReAct 的 `reactUsage.merge` / 编排的
/// `applyOrchUsage`），token 天然并进这一轮的账单，这一行只是把这件事**说出来**，
/// 让日志里能对上一次进出 App 多付了多少。
String bgRestartBillingLine({
  required int times,
  required int promptTokens,
  required int completionTokens,
  required int totalTokens,
}) =>
    '这一轮因退后台重发 $times 次，累计 token 已并入本轮账单'
    '（prompt=$promptTokens completion=$completionTokens total=$totalTokens）';
