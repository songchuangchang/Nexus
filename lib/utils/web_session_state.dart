/// build173 内置浏览器 P0 第一刀：控制回路与会话闸的**判据层**（纯函数，零 widget）。
///
/// 三件事，都只对数字与字符串做判断，不起 WebView、不碰 BuildContext：
///   ① 「AI 控制中 / 人类接管中 / 恢复」这一对状态的**转移与读法**（研究文档 §五，
///      即 `aiControlPaused` 那对状态机的判据）；
///   ② 域名闸：https-only + 复用本仓唯一的 SSRF 闸 + 「首次访问某域名要确认」的纯谓词
///      （研究文档 §六.2）；
///   ③ 步数/时长熔断：只收**数字秒/步数**的纯函数（研究文档 §4.1 对齐 ReAct 的 E5 熔断思路）。
///
/// 关于 ③ 为什么这里没有 `AppWait`、也没有任何字面时长：本仓 D1 闸要求时长档位
/// 集中在 token 层（`lib/ui/tokens.dart`），纯函数层要 `Duration` 就等于绕开那把尺子。
/// 调用点（第二刀）把自己那把表读成的**秒数**交进来，这里只比较数字。
///
/// 关于②为什么不用 `SecurityGate.isPrivateHost`：那条是旧的**句法**闸，域名一律当公网
/// 放行（`ssrf_guard.dart` 文件头写明了为什么换口径）。这里必须走 `ssrfRejectionReason`
/// 那条「DNS 解析后按 IP 判、解析不了就拒」的实现。
///
/// 关于①的"接管"语义：真平台视图下用户的触摸**任何时刻都不曾被夺走**（§五.2），
/// 所以这里的 `paused` 不是"锁住输入"，而是"AI 自己停手 + 回灌一句等待"。
library;

import 'package:aichat/services/launch_uri_normalizer.dart';
import 'package:aichat/utils/ssrf_guard.dart';

// ============================================================================
// ① 控制态：AI 控制中 / 人类接管中 / 恢复
// ============================================================================

/// 浏览器会话的控制态（不可变；每次转移返回新实例）。
class WebControlState {
  /// true = 人类接管中，AI 停手（研究文档 §五.2 里的那个标记）。
  final bool aiControlPaused;

  /// true = 该重读页面了：接管发生过、或刚从接管交还回来。
  /// §五.3「AI 恢复时先 `web_read` 重新序列化，从不假设自己记得页面状态」。
  final bool awaitingPageRead;

  /// 本会话累计接管次数（>0 就说明人碰过，排查与思考面板都用得上）。
  final int takeoverCount;

  /// 接管期间由 `onUrlChange` 记下的最新地址（§五.3 的状态回读凭据）。
  final String? observedUrl;

  const WebControlState({
    this.aiControlPaused = false,
    this.awaitingPageRead = false,
    this.takeoverCount = 0,
    this.observedUrl,
  });

  WebControlState copyWith({
    bool? aiControlPaused,
    bool? awaitingPageRead,
    int? takeoverCount,
    String? observedUrl,
  }) =>
      WebControlState(
        aiControlPaused: aiControlPaused ?? this.aiControlPaused,
        awaitingPageRead: awaitingPageRead ?? this.awaitingPageRead,
        takeoverCount: takeoverCount ?? this.takeoverCount,
        // observedUrl 只写不清（接管记录不覆盖成空），所以这里允许直接沿用旧值。
        observedUrl: observedUrl ?? this.observedUrl,
      );
}

/// 初始态：AI 控制、页面状态未知（第一次动手前同样必须先读）。
WebControlState webInitialControlState() =>
    const WebControlState(aiControlPaused: false, awaitingPageRead: true);

/// 用户按下「让我来」/ 或宿主判定用户在操作 → 进入人类接管。
WebControlState webHandToHuman(WebControlState state, {String? url}) => state.copyWith(
      aiControlPaused: true,
      awaitingPageRead: true,
      takeoverCount: state.takeoverCount + 1,
      observedUrl: url,
    );

/// 用户按下「继续 AI」→ 交还控制权。
///
/// 注意 `awaitingPageRead` 这里**强制置 true**：交还的那一刻 AI 手上的页面快照
/// 已经不可信（接管期间人可能已经导航到别处），必须重读才许动作（§五.3）。
WebControlState webResumeAiControl(WebControlState state) => state.copyWith(
      aiControlPaused: false,
      awaitingPageRead: true,
    );

/// AI 完成一次页面读取（`web_read` 成功回灌后由调用点打）→ 快照重新可信。
WebControlState webNoteAiPageRead(WebControlState state) =>
    state.copyWith(awaitingPageRead: false);

/// 该不该先重读页面（§五.3 的读法；调用点不许直接摸字段比对，判据只在这一处）。
bool webMustReRead(WebControlState state) => state.awaitingPageRead;

/// 接管期间页面导航了（`onUrlChange`）：记下新地址，并保持"必须重读"。
///
/// 未接管时收到这个事件**等于用户上手了** ⇒ 按 §五.2 直接转人工，
/// 不是"忽略并继续"（AI 抢用户的点击是本功能最容易做出来的事故）。
WebControlState webNoteUserUrlChange(WebControlState state, String url) {
  final normalized = url.trim();
  if (normalized.isEmpty) return state;
  if (!state.aiControlPaused) return webHandToHuman(state, url: normalized);
  return state.copyWith(observedUrl: normalized, awaitingPageRead: true);
}

/// AI 此刻能不能动手（唯一的许可判据；调用点不许自己写 `!paused` 的变体）。
bool webAiActionAllowed(WebControlState state) =>
    !state.aiControlPaused && !state.awaitingPageRead;

/// 「这一页算不算坏了」——navigate 与 read **共用**这一条判据（第七轮·会话面第 4 条）。
///
/// 过去两处各写各的：navigate 只看 `failure != null`，read 还额外要求
/// 「一个可交互元素都没有」。于是同一条轨迹里能同时出现「这一页打不开」与
/// 「这一页有 20 个可点元素」两条互斥事实——模型要么重试同一地址（三次后被宿主停机），
/// 要么把坏页当真。本层文件头那句「文案统一了、判据没统一」说的就是这一格。
///
/// `interactiveCount == null` 表示**还没读过这一页**（navigate 那一刻正是这种）：
/// 那时没有第二个读数，只能按失败本身判。给了读数就要求它也是 0——
/// 一页真读得出东西时不该吓唬模型说它没加载（那是 read 原来那条 reason 的正当内核）。
bool webPageIsBroken({
  required String? mainFrameFailure,
  required int? interactiveCount,
}) {
  if (mainFrameFailure == null) return false;
  if (interactiveCount == null) return true;
  return interactiveCount == 0;
}

/// 「web_read 这一跳该不该让位给人工」（第七轮·会话面第 8 条）。
///
/// 会话层原来手拼 `!aiActionAllowed && _control.aiControlPaused`：既摸了字段（本层口径
/// 是「判断住这里」），又把两条判据焊成一个与式——`webAiActionAllowed` 的语义将来一变
/// （例如再纳入一档"域名待确认"），那个与式会静默退化成"只拒接管"，而插件向模型承诺的
/// 是「接管期间任何动作都会被退回」。判据搬进来，调用点只传自己已经算好的两个布尔。
bool webReadYieldToHuman({required bool allowed, required bool paused}) =>
    !allowed && paused;

/// 不许动时回灌给模型的话（研究文档 §五.2 的「用户正在手动操作，请等待」）。
///
/// 返回 null = 许可。**两种拒因分开说**，因为模型要做的事不同：
///  · 接管中 → 等着，别猜页面；
///  · 页面状态不可信 → 先 `web_read` 再说（不重读就动手 = 基于过期 DOM 点击）。
String? webAiActionRejectNotice(WebControlState state, {required bool zh}) {
  if (state.aiControlPaused) {
    return zh
        ? '用户正在手动操作内置浏览器，请等待；需要页面信息时等交还后再用 web_read 读取。'
        : 'The user is operating the built-in browser manually. Wait; '
            'read the page with web_read after control is handed back.';
  }
  if (state.awaitingPageRead) {
    return zh
        ? '页面状态未知或已过期，请先调用 web_read 重新序列化当前页面，再决定动作。'
        : 'Page state is unknown or stale — call web_read to re-serialize the '
            'current page before acting.';
  }
  return null;
}

/// 元素是否需要人工（`input[type=password]`，研究文档 §4.3「一律不代填」）。
///
/// [targetNeedsHuman] 由第二刀从序列化产出里查（`WebDomElement.needsHuman == true`
/// 对应的那个 `idx`），这里只做「模型想动的这个元素是不是需要人工」的判断 + 拒绝文案。
/// 判据不认 widget、不认 DOM 节点。
String? webActNeedsHumanNotice({
  required bool targetNeedsHuman,
  required int idx,
  required bool zh,
}) {
  if (!targetNeedsHuman) return null;
  return zh
      ? '元素 [$idx] 是密码框，AI 不代填也不读取其内容，请提示用户自己输入后再继续。'
      : 'Element [$idx] is a password field: the AI must neither fill nor read it. '
          'Ask the user to type it in, then continue.';
}

// ============================================================================
// ② 域名闸
// ============================================================================

/// 浏览器闸**刻意放宽的只有一条**：允许 URL 带 fragment。
///
/// `ssrfEndpointSyntaxRejection` 是给「API 端点 / MCP 连接器」写的，那里 fragment 是
/// 噪声所以一并拒；但 `https://site/#/cart` 是正常网页（SPA 路由整站在 # 后面），
/// 拿端点口径去拒 fragment 会把浏览器废掉。安全判定本身与 fragment 无关
/// （scheme/host/userInfo/内网域名/IP 分类都在 # 之前），所以这里把 # 之后的部分
/// 摘掉再交给那道闸，**摘的对象是送去判定的副本**，导航仍用原串。
Uri _guardLayerUri(Uri uri) {
  if (!uri.hasFragment) return uri;
  final text = uri.toString();
  final hash = text.indexOf('#'); // 序列化形态里第一个字面 `#` 必然是 fragment 的起点
  if (hash <= 0) return uri;
  final stripped = Uri.tryParse(text.substring(0, hash));
  return stripped ?? uri; // 万一解不出来：交回原串，让那道闸按它自己的口径判（不自己放行）
}

/// 归一 + 摘 fragment，产出「送去安全闸的那份 URI」。
///
/// 返回 `(判定用 URI, 拒绝原因)`：原因非 null 时第一元为 null（不继续判）。
/// 两条公开入口共用这一份口径，避免"同步层放行了、异步层换了个写法"。
(Uri?, String?) _gateUriOf(String rawUrl) {
  final normalized = normalizeLaunchUri(rawUrl);
  final uri = normalized.uri;
  if (normalized.isInvalid || uri == null) {
    return (null, '地址无法解析或缺少 scheme（内置浏览器只走 https）：$rawUrl');
  }
  return (_guardLayerUri(uri), null);
}

/// 归一 + 同步层（scheme/host/userInfo/内网域名/字面内网 IP）。
///
/// 返回 null = 这一层放行；非 null = 拒绝原因（原样可回灌、可 grep）。
/// https-only 就藏在这里：`ssrf_guard.dart` 的语法层已是「仅允许 https」，
/// 本仓**不再写第二份 scheme 白名单**（教训 #62：两份真源早晚漂移成"这条放那条不放"）。
String? webNavigateSyntaxRejection(String rawUrl) {
  final (guard, rejection) = _gateUriOf(rawUrl);
  if (rejection != null) return rejection;
  return ssrfEndpointSyntaxRejection(guard!);
}

/// 完整域名闸（含 DNS 层）：返回 null = 放行，否则拒绝原因。
///
/// [lookup] 注入用（同 `ssrfRejectionReason` 的口径）：单测里给假解析器，
/// 真机上不给就走系统 DNS。解析失败/结果为空一律拒（fail-closed）。
Future<String?> webNavigateRejection(
  String rawUrl, {
  SsrfIpLookup? lookup,
}) async {
  final (guard, rejection) = _gateUriOf(rawUrl);
  if (rejection != null) return rejection;
  return ssrfRejectionReason(guard!, lookup: lookup);
}

/// 取闸用的主机名（小写、去 IPv6 方括号、去尾点）；解析不出来返回 null。
String? webNavigateHost(String rawUrl) {
  final uri = normalizeLaunchUri(rawUrl).uri;
  if (uri == null) return null;
  final host = webHostKey(uri.host);
  return host.isEmpty ? null : host;
}

/// 主机名归一（比较用的**唯一**一处形态变换，白名单读写两侧都过它）。
String webHostKey(String host) {
  var h = bareHost(host).trim().toLowerCase();
  while (h.endsWith('.')) {
    h = h.substring(0, h.length - 1); // `example.com.` 与 `example.com` 同一个站
  }
  return h;
}

/// 首次访问某域名要不要用户确认（研究文档 §六.2：默认白名单为空 = 每次都要确认）。
///
/// 纯谓词：只问「这个 host 在不在已确认集合里」，集合由调用点持有（会话级 `Set`），
/// 「本次会话记住」就是往集合里折一次 [webRememberDomain]。
/// 认不出主机名（空串）时**要确认**——判不出来就放行不是效率，是漏。
bool webDomainNeedsConfirm({
  required String host,
  required Set<String> confirmedHosts,
}) {
  final key = webHostKey(host);
  if (key.isEmpty) return true;
  return !confirmedHosts.map(webHostKey).contains(key);
}

/// 「这一条浏览器会话」的收回（第七轮·入口面第 2 条）。
///
/// 弹窗那格写的是"本次会话记住"，而那份名单挂在 `BrowserSession.instance` 单例上，
/// 过去**全仓没有任何清空入口**：用户按「结束」关掉浏览器页、再让 AI 打开同一个站，
/// 不再被问一次——一次点击的授权覆盖此后所有对话，且无处查看、无处撤销
/// （口径「能关就能看」在这一格没兑现）。会话层文件头本来就写着
/// 「作用域是这一条浏览器会话（用户没关页面就一直有效）」，那句话当时是**旧的**。
/// 收回点选在页面关掉那一刻（`unbindController`）。改成"直到退出 App"是另一种选择，
/// 那要文案与授权面一起放宽、由用户点头，不在这一格。
Set<String> webForgetConfirmedDomains() => <String>{};

/// 「本次会话记住」：折叠出新集合（不可变，调用点替换自己的字段）。
Set<String> webRememberDomain({
  required Set<String> confirmedHosts,
  required String host,
}) {
  final key = webHostKey(host);
  if (key.isEmpty) return Set<String>.unmodifiable(confirmedHosts);
  return {...confirmedHosts.map(webHostKey), key};
}

/// 域名待确认时回灌给模型的话（不是错误，是「等人工」）。
String webDomainConfirmPendingNotice({required String host, required bool zh}) {
  final h = webHostKey(host);
  return zh
      ? '首次访问 $h 需要用户确认，本次导航已挂起；等用户选择后再继续，不要重试同一个地址。'
      : 'First visit to ${h.isEmpty ? 'this host' : h} needs the user to confirm. '
          'This navigation is parked — wait for the user, do not retry it.';
}

// ============================================================================
// ③ 步数/时长熔断
// ============================================================================

/// 熔断原因：**步数**触顶。可 grep（与 [kWebCircuitBreakTime] 一起写进日志与产出）。
const String kWebCircuitBreakSteps = 'steps';

/// 熔断原因：**时长**触顶。
const String kWebCircuitBreakTime = 'time';

/// 浏览器会话是否该停了。返回 null = 还没到点（**反向闸钉这条**：没到点偏报熔断，
/// 等于把一个还能走的流程掐了，还让人以为页面坏了）。
///
/// 为什么这里**不写默认上限**：上限的现成尺子是宿主已有的那几个数
/// （`conversation.reactMaxRounds`、`chat_screen_react.dart` 的
/// `maxMcpCallsPerMessage`），在这里再写一份就是造第三个数（教训 #62 同型），
/// 而且第二刀的「深度档/快速档」本来就要跟着 ReAct 档位走。
/// ⇒ 由调用点把数交进来，本文件只对数字做判断。
///
/// [elapsedSeconds] 是**数字秒**：调用点自己读表（`stopwatch.elapsed.inSeconds`
/// 或 `DateTime` 差值的秒数）再传进来，本层不制造时长对象（D1 闸）。
/// 上限给成 0 或负数按「立刻停」处理（fail-closed，不当成"没设上限"）。
String? webCircuitBreakReason({
  required int stepsDone,
  required int maxSteps,
  required int elapsedSeconds,
  required int maxElapsedSeconds,
}) {
  if (maxSteps <= 0) return kWebCircuitBreakSteps;
  if (stepsDone >= maxSteps) return kWebCircuitBreakSteps;
  if (maxElapsedSeconds <= 0) return kWebCircuitBreakTime;
  if (elapsedSeconds >= maxElapsedSeconds) return kWebCircuitBreakTime;
  return null;
}

/// [webCircuitBreakReason] 的布尔形态（true = 该停）。
bool webCircuitBreakTripped({
  required int stepsDone,
  required int maxSteps,
  required int elapsedSeconds,
  required int maxElapsedSeconds,
}) =>
    webCircuitBreakReason(
      stepsDone: stepsDone,
      maxSteps: maxSteps,
      elapsedSeconds: elapsedSeconds,
      maxElapsedSeconds: maxElapsedSeconds,
    ) !=
    null;

/// 熔断后回灌给模型的话（§4.1「防在坏页面上无限循环」）。
///
/// 说清楚**是哪一种**到点：步数到点 ⇒ 基于已有信息收尾；时长到点 ⇒ 同样收尾，
/// 但补一句"慢站/坏页"的可能，让用户看得见为什么停（研究文档 §五.4 取证口径）。
String webCircuitBreakNotice(String reason, {required bool zh}) {
  final stepsTripped = reason == kWebCircuitBreakSteps;
  final head = stepsTripped
      ? (zh ? '宿主熔断：本浏览器会话的动作步数已触顶。' : 'Circuit breaker: this browser session hit its step cap.')
      : (zh ? '宿主熔断：本浏览器会话的总时长已触顶。' : 'Circuit breaker: this browser session hit its time cap.');
  final tail = stepsTripped
      ? (zh
          ? '不要再发起 web_navigate/web_act/web_read，请基于已读到的内容直接答复用户。'
          : 'Do not call web_navigate/web_act/web_read again — answer from what has already been read.')
      : (zh
          ? '页面可能很慢或卡住了，不要再继续操作浏览器；请基于已读到的内容答复用户，并如实说明还有几步没走完。'
          : 'The page may be slow or stuck — stop driving the browser, answer from what has already been read, and say plainly which steps were left undone.');
  return '$head $tail';
}

/// AI 派发之后，这一串导航要不要**继续跟**（浏览器会话的链路判据，第五轮浏览器扫描第 1 条）。
///
/// 住在刀一而不是会话层：`browser_session.dart` 文件头那条口径写的是"接管/重读/域名/
/// 密码/熔断的**判断**全在 `utils/web_session_state.dart`，这里只把它们按顺序串起来"。
/// 上一版我把这个判断写成了会话层的 `static` 成员＝自己打了自己的口径（第六轮第 4 条）。
///
/// 三个入参各挡一件真事：
///  · `movedWhileWaiting`——等"这一跳完成"的那段时间里又起了新导航（短链、meta refresh、
///    onload 里 `location.replace`）。旧写法只在完成**之后**才开始取样，这一段整个看不见；
///  · `movedInQuiet`——完成之后的安静窗里又起了新导航；
///  · `hops < maxHops`——**必须有上限**：没有它，一个每 800 毫秒自刷新的页面会把 AI
///    窗口永远钉着，用户真上手也判不出来，那是把一种死锁换成另一种死锁。
///
/// 已知边界（没在这一版收掉，记 182）：`waitUntilSettled` 是**超时不抛**的，所以
/// 20 秒都没报"完成"的那一形里，本函数仍会跟着"没动"收窗——要彻底判"是谁引起的这次
/// URL 变化"，得给状态层加"最近一次 AI 派发"的时间戳，而不是靠窗口开合。
bool webNavChainContinues({
  required bool movedWhileWaiting,
  required bool movedInQuiet,
  required int hops,
  required int maxHops,
}) {
  if (hops >= maxHops) return false;
  return movedWhileWaiting || movedInQuiet;
}

/// `web back` 这一跳收尾时该做哪四件事——**一张表说了算**（第八轮扫描第 3 条）。
///
/// 为什么要把判断搬进来：这四件事原来散在 `back()` 的四处**不同**写法上
/// （`failed` 那位挂了代际、两条**写**没挂、`reread` 恒真、回话按 `can` 分岔），
/// 散着写迟早漂成互相打脸——盘上当时就是那一形：
/// 日志写 `reread=1`（"必须重读"）而回话写「当前仍是这一页」，
/// 模型照回话直接动手就吃 `reject_reread`，照日志重读就白烧一步。
/// 搬成一张表之后，四种组合各有一格判据，改任何一位都要红一次。
///
///  · `ok`＝落进日志的"退成了没有"（派发有没有发生）；
///  · `reread`＝日志那一位"下一步必须重读"；
///  · `invalidateSnapshot`＝**真的**去作废 `_lastSnapshot` 与 `awaitingPageRead`；
///  · `failureCounts`＝`_mainFrameFailure` 讲的是不是**这一跳**的事；
///  · `lostTrack`＝回话要不要明说"观察断了"（会话换了，屏幕上是哪一页我不知道）。
///
/// `can=false` 那一行页面根本没动 ⇒ 不作废旧快照、也不要求重读（旧快照仍是这一页的，
/// 模型可以直接换别的动作）；`sameGeneration=false` 那一行**只停写**：
/// 迟到的这一跳不许作废**新会话**那份可信快照，否则 AI 会"重读再动手"，
/// 动在用户正在操作的那一页上。
({bool ok, bool reread, bool invalidateSnapshot, bool failureCounts, bool lostTrack})
    webBackOutcome({
  required bool can,
  required bool sameGeneration,
}) {
  return (
    ok: can,
    reread: can,
    invalidateSnapshot: can && sameGeneration,
    failureCounts: can && sameGeneration,
    lostTrack: !sameGeneration,
  );
}

/// 一次导航的"目标"归一化键：主机（小写、去 IPv6 方括号、去尾点）＋**端口**＋
/// 路径（空路径算 `/`，只差一个尾斜杠算同一条）＋查询串＋片段（`#`）。
///
/// 判"这一跳是不是落到了别处"用它，不用字符串相等：平台读回来的那串常带尾斜杠，
/// 而模型写的是裸域名（第八轮扫描第 7 条）。也不许把端口与片段省掉——
/// `https://x:8443` 与 `https://x` 是两个站点，`#/cart` → `#/login` 是 SPA 里
/// 最常见的"把你弹去登录"，省了就是**该报没报**。
/// 空 query（`?`）与无 query 算同一条，否则每次都会谎报一次转走。
/// 解析不出来（`normalizeLaunchUri` 给 null）返回空串：空串与空串相等＝"没转走"，
/// 这一形调用点会另外按"读不回地址"处理，不靠这个键。
String webLaunchTargetKey(String raw) {
  final uri = normalizeLaunchUri(raw).uri;
  if (uri == null) return '';
  var path = uri.path;
  if (path.isEmpty) {
    path = '/';
  } else if (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  final query = (uri.hasQuery && uri.query.isNotEmpty) ? '?${uri.query}' : '';
  final fragment =
      uri.hasFragment && uri.fragment.isNotEmpty ? '#${uri.fragment}' : '';
  return '${webHostKey(uri.host)}:${uri.port}$path$query$fragment';
}

/// 只取"主机＋端口"那一截：域名许可是按主机点的（`webHostKey` 自己不含端口），
/// 而"落到别的站点"要连端口一起看，所以这里比许可那一层多一位。
String webLaunchHostKey(String raw) {
  final uri = normalizeLaunchUri(raw).uri;
  if (uri == null) return '';
  return '${webHostKey(uri.host)}:${uri.port}';
}
