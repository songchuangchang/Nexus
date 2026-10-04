/// build180（刀二）：内置浏览器那一页的**会话层**——AI 四个动作与用户接管共用的那一个实例。
///
/// ## 为什么要有这一层（而不是把 WebView 留在页面里）
/// 研究文档 §五的关键架构事实：WebView 是**真平台视图**，用户的触摸与 AI 的 JS 注入
/// 作用在**同一个实例**上。所以「AI 在动」与「人在动」不是两套渲染，而是同一个对象的
/// 两个使用者——必须有一个地方持有那个对象＋那份控制态，页面与插件都只经由它说话。
/// 这一层就是那个地方：`BrowserSession.instance`（对齐本仓 `WorkspaceService` 的形状：
/// 静态入口、不认 BuildContext、页面负责创建 WebView 并把 controller 交进来）。
///
/// ## 这一层**不**做的事
///  · 不写判据：接管/重读/域名闸/密码闸/熔断的**判断**全在 `utils/web_session_state.dart`
///    （刀一交付的纯函数），这里只把它们按顺序串起来；
///  · 不做正文渲染：DOM 解析与截断全在 `utils/web_dom_serializer.dart`（刀一）；
///  · **不拼信封**：产出的是「待回灌正文」，出口只有 `builtin_plugins.dart` 的
///    `toolResultTag(...)` 那一处（跨表锁 `test/build176_browser_wiring_lock_test.dart`
///    的 D 组按「处＝行」数着浏览器层这一族文件，这里出现一行开壳字面量就会红）；
///  · **不写第三个上限数**：步数/秒数由宿主交进来（[BrowserSession.noteRunLimits]），
///    对齐 `conversation.reactMaxRounds` 与 `maxMcpCallsPerMessage`（刀一文件头那条纪律）。
///
/// ## 日志＝刀二唯一的机械验收通道
/// WebView 渲染的内容不进 uiautomator 语义树（10-01 真机取证），所以每次动作落一行
/// `browser_action_log.dart` 的结构化日志（线格式即契约，字段名与顺序由
/// `test/build180_browser_action_log_test.dart` 钉死）。这一层只报**数量与状态**：
/// 页面正文、元素文字、URL 一个字都不进日志。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../ui/tokens.dart';
import '../utils/web_dom_serializer.dart';
import '../utils/web_session_state.dart';
import 'browser_action_log.dart';
import 'logger_service.dart';

/// `web_act` 的结果词表住在 `browser_action_log.dart`（[kWebActOutcomes]，闭集）；
/// 执行体只填表里的词，表外值由日志层退成 `unknown`——这里不再造第二套说法。
enum WebActKind { click, input, clear }

/// 域名确认的三种答案：允许一次 / 本次会话记住 / 拒绝。
enum WebDomainDecision { allowOnce, remember, deny }

/// 一次动作的返回值。[body] 是**待回灌正文**（不含信封，信封由插件层唯一出口拼），
/// [isError] 决定是否给信封标 `is_error="true"`。
class WebActionResult {
  const WebActionResult({required this.body, this.isError = false});

  final String body;
  final bool isError;
}

/// 会话层本体（进程内单例；一条浏览器会话 = 一个未关闭的浏览器页）。
class BrowserSession extends ChangeNotifier {
  BrowserSession._();

  static final BrowserSession instance = BrowserSession._();

  /// 日志 tag：grep 它就能还原整条浏览器会话（对齐 `HtmlPreview` 那条取证口径）。
  static const String logTag = 'BrowserSession';

  /// 宿主还没交熔断数时的兜底步数。**刻意不新造数**：它与非深度档的
  /// `maxMcpCallsPerMessage`（chat_screen_react.dart 同一个循环里的现成尺子）同值，
  /// 只防「宿主忘了调 [noteRunLimits] ⇒ 熔断判据拿到 0 就立刻拆栈」这一种装配缺漏
  /// （`webCircuitBreakReason` 对 `maxSteps<=0` 的口径是 fail-closed＝立刻停）。
  static const int kFallbackMaxSteps = 8;

  /// 每一步的预算秒数（时长闸用）。宿主没有「一步多久」那张表，这一层也不造
  /// `Duration` 对象（D1 闸）——这里只算**数字秒**，交给 [webCircuitBreakReason] 比较。
  static const int kSecondsPerStep = 60;

  /// 一次导航愿意等多久算「页面稳定」。超时**不抛**：回灌一句「页面还没稳定」
  /// 比把 ReAct 循环挂死有用（研究文档 §五.4 的取证口径：异常必须可见）。
  static const Duration settleTimeout = Duration(seconds: 20);

  /// click 派发之后，给多长时间观察"这一跳到底起没起导航"。
  ///
  /// 为什么要有这一条（181 自查发现的回归）：`act` 现在无条件 `await waitUntilSettled()`，
  /// 而**点了没换页**（展开菜单、勾框、翻页控件用 JS 自己改 DOM）时不会有 `onPageFinished`
  /// ⇒ 每一次这样的点击都要白等满 [settleTimeout] ＝ **20 秒**，ReAct 的步数预算
  /// 就是这么烧光的；填一个输入框（`kind == input`）过去也照等不误。
  ///
  /// 取舍（记着，别当已修）：真起导航的那一跳，`onPageStarted` 绝大多数在几十到几百毫秒内
  /// 落到平台通道；700 ms 之后才来的那一次会掉在 AI 导航窗口之外，被 `onPageStarted` 里
  /// 那句 `webNoteUserUrlChange` 记成「用户上手」⇒ AI 停手。**方向是 fail-closed**
  /// （停手＋用户看得见那一页），不是谎报成功。要彻底消掉这一格，得给
  /// `web_session_state.dart` 加"最近一次 AI 派发"的时间戳，让 URL 变化按"是谁引起的"归因，
  /// 那要把状态层的判据一起改（它有自己的锁）⇒ 记进 182，不在这包里顺手做。
  static const Duration navGrace = AppWait.navObserveGrace;

  /// 派发之后有没有观察到一次真导航（`onPageStarted`／`onPageFinished` 落进窗口）。
  bool _navSignalSeen = false;

  WebViewController? _controller;

  /// 页面是否已经加载完成过至少一帧（`onPageFinished` 置真，导航开始置假）。
  bool _settled = false;

  /// **这一次**加载的主帧失败原因（null = 没失败）。
  ///
  /// 为什么要有这一条：`onWebResourceError` 只有页面侧的 `NavigationDelegate` 拿得到，
  /// 而会话层过去只接 started/finished 两个入口 ⇒ 主帧挂了、`onPageFinished` 照样来一发，
  /// [navigate] 就无条件报「已打开页面」＋0 块正文（AI 拿空白页继续答题，用户看到白屏）。
  /// 起点清零、失败时由 [onMainFrameFailed] 置位，所以它讲的永远是**这一次**加载，
  /// 上一轮的失败不许算到这一轮头上。
  String? _mainFrameFailure;

  WebControlState _control = webInitialControlState();
  Set<String> _confirmedHosts = <String>{};
  WebDomSnapshot? _lastSnapshot;

  int _seq = 0;
  int _stepsDone = 0;
  int? _maxSteps;
  int? _maxSeconds;
  DateTime? _runStartedAt;

  /// AI 正在驱动导航的窗口期。这段时间里收到的 `onPageStarted/onPageFinished`
  /// **不算**「用户上手」（§五.2 判的是人的动作，不是 AI 自己那一次 loadRequest）。
  /// 用计数而不是布尔：连点后退 + 页面自身重定向会交叠。
  int _aiNavInFlight = 0;

  /// 会话代际：`bindController`／`unbindController` 各自加一（第五轮扫描第 1、2 条）。
  ///
  /// 这一格是**唯一**能把"迟到的那一下"与"下一个会话"分开的东西。三个动作都在派发前
  /// `_aiNavInFlight++`、在 `finally` 里 `--`，而 `finally` 只在 Future 有结果时才跑：
  /// 元素 `onclick` 里挂着 `window.confirm(...)` 是常态写法，Android 的
  /// `evaluateJavascript` 回调排在被弹框挡住的 JS 线程之后 ⇒ 那个 Future 永不完成 ⇒
  /// `finally` 永不执行 ⇒ 计数停在 ≥1。而这个位过去**没有任何复位点**
  /// （`bind`／`unbind`／`noteRunLimits` 三处都不动它，`BrowserSession` 又是进程级单例）⇒
  /// `_aiNavInFlight == 0` 那条归因判据从此恒假（用户真上手也判不出来），
  /// [aiNavWindowOpen] 恒真 ⇒ 页面上「继续 AI」那枚按钮的 `onPressed` 恒 null——
  /// 用户按了「让我来」再也按不回来，唯一出路是关页重开，而**重开也不清这个计数**。
  ///
  /// 用法：动作在 `_aiNavInFlight++` **之前**记下当代，`finally` 里只在代际没变时递减
  /// （变了＝这一次的观察对象早就不是这一页，减它会把**新会话**刚挂上的窗口误关掉）；
  /// `unbindController` 里连同 `_navChainHops`／`_navEventSeq` 一起归零——"用完即释放"
  /// 那句写的就是这个对象，不是只指 WebView 那 100~200MB。
  int _sessionGeneration = 0;

  Completer<void>? _settleWaiter;
  Timer? _settleTimer;
  Completer<void>? _bindingWaiter;

  /// 域名确认弹窗由**页面**递进来（会话层不认 widget，也不造第二套状态模型）。
  ///
  /// 页面没打开 ⇒ 这里是 null ⇒ [navigate] 按「用户没允许」处理（fail-closed：
  /// 判不出就不放行，而不是默认允许——研究文档 §六.2 的默认白名单本来就是空集）。
  Future<WebDomainDecision> Function(String host)? domainConfirmer;

  // ===== 读法（插件与页面唯一的入口；调用点不许自己摸字段比对） =====

  bool get hasWebView => _controller != null;

  /// AI 的导航窗口此刻开着吗（`_aiNavInFlight > 0` 的**只读**出口）。
  ///
  /// 为什么要露给页面（第七轮·会话面第 2 条）：`handToHuman()`／`resumeAiControl()`
  /// 过去只改 `_control` 那一个位，一条都不碰窗口——于是「AI 正在等这一跳」与
  /// 「用户说我接管了」之间没有任何交接：用户在窗口开着的时候点自己那条链接，
  /// `onPageStarted` 落在 `_aiNavInFlight != 0` 里，**一个字都不记**，只把事件算到 AI 名下，
  /// 窗口收掉之后回灌的却是「已打开页面：用户点进去的那一页」⇒ AI 接着在用户正操作的
  /// 页面上 read／act。彻底的解法是给状态层记"最近一次人工派发"的时间戳（已登 182，
  /// #145）；这一格先给页面一个**看得见**的办法：窗口开着时那两枚按钮先别按。
  bool get aiNavWindowOpen => _aiNavInFlight > 0;
  bool get pageSettled => _settled;
  WebControlState get control => _control;
  WebDomSnapshot? get lastSnapshot => _lastSnapshot;
  Set<String> get confirmedHosts => Set<String>.unmodifiable(_confirmedHosts);
  int get stepsDone => _stepsDone;
  int get takeoverCount => _control.takeoverCount;

  /// 下一个动作序号（一次动作一行日志，序号在本会话内单调递增）。
  int nextSeq() => ++_seq;

  // ===== 生命周期：页面创建/销毁 WebView，这里只持有句柄 =====

  /// 浏览器页 `initState` 调用：把刚建好的 controller 交给会话层持有。
  void bindController(WebViewController controller) {
    // 换页＝换一个会话：代际先加一，上一页留下的迟到 `finally` 从此动不到这一页的计数。
    _sessionGeneration++;
    _aiNavInFlight = 0;
    _navChainHops = 0;
    _navEventSeq = 0;
    _controller = controller;
    _settled = false;
    _navSignalSeen = false;
    _mainFrameFailure = null;
    _lastSnapshot = null;
    _runStartedAt ??= DateTime.now();
    LoggerService.instance.info('浏览器会话：绑定 WebView，等待页面就绪',
        cat: LogCat.react, tag: logTag);
    final waiter = _bindingWaiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
    notifyListeners();
  }

  /// 浏览器页 `dispose` 调用：**用完即释放**（研究文档 §九.2：WebView 常驻 100~200MB）。
  void unbindController() {
    _controller = null;
    _settled = false;
    _navSignalSeen = false;
    _mainFrameFailure = null;
    _lastSnapshot = null;
    // 「本次会话记住」的域名在这一步真的收回（第七轮·入口面第 2 条）：过去这个函数
    // 清 controller／快照／失败位，**唯独不动那份名单**，而它挂在单例上 ⇒
    // 用户按「结束」之后再让 AI 开同一个站不再被问，授权实际是进程级的，
    // 与下面 [domainAllowed] 那一段自己写的「作用域是这一条浏览器会话」相反。
    _confirmedHosts = webForgetConfirmedDomains();
    // 三个计数是**会话级**的：过去它们只在动作的 finally 里动，而 finally 有可能永远不来
    // （见 [_sessionGeneration] 那一段）。按「结束」之后重开页面并不清这些位 ⇒
    // 归因判据与那两枚接管按钮一起死透（第五轮扫描第 2 条）。
    _sessionGeneration++;
    _aiNavInFlight = 0;
    _navChainHops = 0;
    _navEventSeq = 0;
    domainConfirmer = null;
    _releaseSettleWaiter();
    final waiter = _bindingWaiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
    LoggerService.instance.info('浏览器会话：页面关闭，释放 WebView',
        cat: LogCat.react, tag: logTag);
    notifyListeners();
  }

  /// 等页面把 controller 绑上来（`web_navigate` 发现「页面还没开」时用它）。
  ///
  /// 超时**不抛**：拿一句「浏览器页没能打开」回灌，比把 ReAct 循环挂死有用；
  /// 用户在推上去的那一帧就把它关掉，也是一种如实的失败。
  Future<void> waitForBinding({Duration timeout = settleTimeout}) async {
    if (_controller != null) return;
    final waiter = _bindingWaiter ??= Completer<void>();
    await waiter.future.timeout(timeout, onTimeout: () {});
    if (_bindingWaiter == waiter) _bindingWaiter = null;
  }

  /// 一次 ReAct 运行开始时由宿主调用（chat_screen_react 的循环入口）。
  ///
  /// 上限数**由调用点交进来**：这一层不写第三个数（刀一文件头那条纪律）。
  /// 交进来 0 或负数按「就用兜底档」处理，而不是按「立刻熔断」——
  /// 那会把一个装配缺漏伪装成页面故障。
  ///
  /// 一并**复位控制态**：一条用户消息 = 一次新的运行，AI 默认回到「控制中但页面
  /// 状态未知」（[webInitialControlState] 的 `awaitingPageRead: true`），
  /// 所以每一步动手前都必须先 `web_read`（§五.3）。**不动**已确认域名——
  /// 「本次会话记住」的作用域是这一条浏览器会话（用户没关页面就一直有效）。
  void noteRunLimits({required int maxSteps, required int maxElapsedSeconds}) {
    _maxSteps = maxSteps <= 0 ? kFallbackMaxSteps : maxSteps;
    _maxSeconds = maxElapsedSeconds <= 0
        ? _maxSteps! * kSecondsPerStep
        : maxElapsedSeconds;
    _stepsDone = 0;
    _seq = 0;
    _runStartedAt = DateTime.now();
    _control = webInitialControlState();
    _lastSnapshot = null;
    notifyListeners();
  }

  // ===== 熔断 =====

  /// 该不该停（null = 还能走）。数字全部来自 [noteRunLimits] 交进来的上限。
  String? circuitBreakReason() {
    final steps = _maxSteps ?? kFallbackMaxSteps;
    final seconds = _maxSeconds ?? steps * kSecondsPerStep;
    final started = _runStartedAt;
    return webCircuitBreakReason(
      stepsDone: _stepsDone,
      maxSteps: steps,
      elapsedSeconds:
          started == null ? 0 : DateTime.now().difference(started).inSeconds,
      maxElapsedSeconds: seconds,
    );
  }

  /// 每个动作**先**过这一条（研究文档 §4.1「防在坏页面上无限循环」）。
  WebActionResult? circuitBreakResult({required bool zh}) {
    final reason = circuitBreakReason();
    if (reason == null) return null;
    return WebActionResult(
      body: webCircuitBreakNotice(reason, zh: zh),
      isError: true,
    );
  }

  // ===== 接管 / 交还（§五.2 §五.3） =====

  /// 用户按下「让我来」⇒ 转人工（AI 停手，不是夺走输入）。
  void handToHuman({String? url}) {
    _control = webHandToHuman(_control, url: url);
    LoggerService.instance.info(
        '浏览器接管：转入人工，累计接管 ${_control.takeoverCount} 次',
        cat: LogCat.react,
        tag: logTag);
    notifyListeners();
  }

  /// 用户按下「继续 AI」⇒ 交还控制权；快照立刻不可信，AI 必须先 `web_read`。
  void resumeAiControl() {
    _control = webResumeAiControl(_control);
    LoggerService.instance.info('浏览器交还：AI 恢复控制，等待重新 web_read',
        cat: LogCat.react, tag: logTag);
    notifyListeners();
  }

  /// 唯一许可判据（调用点不许自己写 `!paused` 的变体）。
  bool get aiActionAllowed => webAiActionAllowed(_control);

  /// 不许动时回灌给模型的话；许可时返回 null。
  ///
  /// **按调用点的 `zh` 走**（第五轮浏览器扫描第 5 条）：过去这是一条恒给中文的快捷 getter，
  /// 而 `navigate`／`read`／`back` 三处都直接用它 ⇒ 英文会话里被闸挡下的模型收到一句中文拒因，
  /// 与 `act` 那句「按调用点的 zh 走」自相矛盾——同一件事在一条轨迹里出现两种语言，
  /// 模型要么忽略它，要么把中文原样转给用户（那就是我们给用户发错语言）。
  String? aiActionRejectNoticeFor(bool zh) =>
      webAiActionRejectNotice(_control, zh: zh);

  // ===== 域名闸（判据住刀一，这里只持有「本次会话记住」那个集合） =====

  bool domainNeedsConfirm(String host) =>
      webDomainNeedsConfirm(host: host, confirmedHosts: _confirmedHosts);

  void rememberDomain(String host) {
    _confirmedHosts = webRememberDomain(
        confirmedHosts: _confirmedHosts, host: host);
  }

  // ===== 四个动作的执行体 =====

  /// `web_navigate`：https-only + SSRF/DNS 闸 → 域名确认 → loadRequest → 等页面稳定。
  ///
  /// 被闸拒掉**不是异常**：拒绝原因原样回灌，模型才知道「是闸拦的，不是页面坏了」，
  /// 也不会拿同一个地址重试（研究文档 §六.2）。
  ///
  /// 「页面确实坏了」那一种另说：主帧加载失败由页面侧的 [onMainFrameFailed] 递进来，
  /// 这时回话是 `isError: true` ＋那一句「这一页主体没能加载」，不是「已打开页面」——
  /// 空白页塌成成功＝AI 拿 0 块正文继续答题，而用户看到的是一片白（缺陷三）。
  Future<WebActionResult> navigate(
    String url, {
    required bool zh,
    Future<WebDomainDecision> Function(String host)? askUserConfirm,
  }) async {
    // **每一次调用恰好落一行**（第七轮·入口面第 3 条）：这一条线过去整个方法一行都不落，
    // 四个动作里唯一会开窗口、唯一会弹授权框的那一个在真机上无影——而
    // `web_browser_plugins.dart` 向模型承诺的是"每次执行恰好落一行结构化日志"。
    // `gated` 覆盖派发之前的全部退回（页面没开／熔断／许可／地址／域名），
    // 机械侧由此分得开「AI 没提这个动作」与「提了但被拦」，也第一次能数出域名拒了多少次。
    final seq = nextSeq();
    final controller = _controller;
    if (controller == null) {
      logWebNavigate(seq: seq, ok: false, gated: true, why: 'page_not_open',
          mainFrameFailure: false);
      return WebActionResult(
        body: zh
            ? '内置浏览器页面没有打开，无法导航。'
            : 'The built-in browser page is not open, so nothing can be navigated.',
        isError: true,
      );
    }
    final breaker = circuitBreakResult(zh: zh);
    if (breaker != null) {
      logWebNavigate(seq: seq, ok: false, gated: true, why: 'circuit_break',
          mainFrameFailure: false);
      return breaker;
    }
    // 许可闸（四个动作同一条、同一个顺序：**判空 → 熔断 → 许可 → 域名 → 派发**）。
    // 为什么许可必须在域名闸之前：域名闸会弹模态框问用户「允许访问这个网站吗」，
    // 而接管期间问这个问题本身就是抢用户的话筒——人正在这页上操作，AI 却递一个弹窗
    // 要他授权一个他刚亲手打开过的域名。放在前面还省掉一次 DNS 解析（webNavigateRejection
    // 那条是异步的，拒了也白跑）。
    if (!aiActionAllowed) {
      logWebNavigate(seq: seq, ok: false, gated: true, why: 'permit',
          mainFrameFailure: false);
      return WebActionResult(
          body: aiActionRejectNoticeFor(zh) ??
              (zh
                  ? 'AI 当前不能操作浏览器。'
                  : 'The app is not letting the AI use the browser right now.'),
          isError: true);
    }
    final blocked = await webNavigateRejection(url);
    if (blocked != null) {
      logWebNavigate(seq: seq, ok: false, gated: true, why: 'address',
          mainFrameFailure: false);
      return WebActionResult(body: blocked, isError: true);
    }
    final host = webNavigateHost(url) ?? '';
    if (domainNeedsConfirm(host)) {
      final decided =
          askUserConfirm == null ? null : await askUserConfirm(host);
      if (decided != WebDomainDecision.allowOnce &&
          decided != WebDomainDecision.remember) {
        logWebNavigate(seq: seq, ok: false, gated: true, why: 'domain',
            mainFrameFailure: false);
        return WebActionResult(
          body: zh
              ? '用户没有允许访问 ${host.isEmpty ? '这个地址' : host}，本次导航已取消。'
                  '不要重试同一个地址，请换一种方式回答用户。'
              : 'The user did not allow visiting '
                  '${host.isEmpty ? 'this address' : host}; this navigation is cancelled. '
                  'Do not retry it.',
          isError: true,
        );
      }
      if (decided == WebDomainDecision.remember) rememberDomain(host);
    }
    _stepsDone++;
    // 派发之前记下当代：会话换了之后，finally 那一下不许减新会话的计数，
    // 回灌也不许替**没观察到的那一页**签字（第五轮扫描第 1 条）。
    final generation = _sessionGeneration;
    // 起点就把「这一次加载」的两条状态归零，两条都是缺陷二/缺陷三的一半：
    //  · `_settled` 是**上一页**的稳定标记。留着 true ⇒ 下面的 waitUntilSettled 即刻返回
    //    ⇒ `_aiNavInFlight--` 抢在新页的 `onPageStarted` 之前 ⇒ 那次事件被
    //    `webNoteUserUrlChange` 判成「用户上手」⇒ 转人工死锁（AI 自己导航，用户没碰）；
    //    顺带还回灌了上一页的标题＋「已打开页面」。
    //  · `_mainFrameFailure` 不留：上一轮的失败不该算到这一轮头上。
    // 置 false 必须紧挨在 `_aiNavInFlight++` 之前（判据锁 test/build181_*
    // 钉的就是「三行以内」）：先挂窗口再派发，晚一步平台事件就落到窗口外了。
    // 清之前先把当代记下来：`loadRequest` 那一下抛了（或链路里换了会话）而这一页
    // 根本没起导航 ⇒ 这三条**还是上一页的事实**，不许留着 null/false 走掉
    // （第八轮扫描第 2 条：act 在第七轮已经还了，navigate／back 两条还没还）。
    final settledBeforeDispatch = _settled;
    final failureBeforeDispatch = _mainFrameFailure;
    final signalBeforeDispatch = _navSignalSeen;
    _mainFrameFailure = null;
    _navSignalSeen = false;
    _settled = false;
    _aiNavInFlight++;
    try {
      await controller.loadRequest(Uri.parse(url.trim()));
      await waitUntilSettledChain();
    } catch (e) {
      // 派发了但没成＝`ok=0 gated=0`（不是被闸拦的）。这一形过去一个字都不落，
      // 于是机械侧读到的是「这一跳压根没发生」，而屏幕上其实转了一圈。
      logWebNavigate(seq: seq, ok: false, gated: false, why: 'none',
          mainFrameFailure: false);
      return WebActionResult(
        body: zh ? '导航失败：$e' : 'Navigation failed: $e',
        isError: true,
      );
    } finally {
      if (_sessionGeneration == generation) {
        _aiNavInFlight--;
        // 没观察到任何导航 ⇒ 这一页没换 ⇒ 三条一起还（与 [act] 的 finally 同一条纪律）。
        // 不还的后果：坏页的 `code=-105` 被抹成 null ⇒ 下一次 `read` 的坏页判据不再触发，
        // 一片白被标成 `isError=false`，AI 拿空白页继续答题。
        if (!_navSignalSeen) {
          _settled = settledBeforeDispatch;
          _mainFrameFailure = failureBeforeDispatch;
          _navSignalSeen = signalBeforeDispatch;
        }
        // 见 [back] 里同一处那句：关掉窗口要 notify，界面那两枚按钮读的就是这个位。
        notifyListeners();
      }
    }
    if (_sessionGeneration != generation || !identical(_controller, controller)) {
      // 这一串导航的观察对象已经不在这儿了：用户在窗口开着的时候关了页、又自己开了别的站。
      // `unbindController` 把 `_settled` 置回 false 又叫醒在飞的等待，而链路过去只认
      // "`_navEventSeq` 变了没有" ⇒ 它当成"这一串还没完"跟着**新页**继续跳，
      // 那一串 `onPageStarted` 全落在 `_aiNavInFlight != 0` 里一个字都不记，
      // 收窗之后这里却要给"已打开页面：`$url`"签字——那个 `$url` 是本次调用的**形参**，
      // 讲的是 AI 要过的那一页，不是屏幕上这一页（第五轮扫描第 1 条）。
      // 日志这一行是 `ok=0 gated=0`：动了手、不是被闸拦的、也没成——三个字段合起来才说得清。
      logWebNavigate(
          seq: seq, ok: false, gated: false, why: 'none', mainFrameFailure: false);
      return WebActionResult(
        body: zh
            ? '这一跳的观察在浏览器页关闭或换页时中断了，现在屏幕上是哪一页我不知道。'
              '请重新 web_navigate 到需要的地址，不要沿用刚才那个。'
            : 'This navigation lost track of the page (it was closed or switched over). '
              'The page now on screen is unknown to me — navigate again instead of '
              'reusing the address from the previous call.',
        isError: true,
      );
    }
    // 导航成功＝页面换了：之前那份快照作废，不重读就动手＝基于过期 DOM 点击。
    _control = _control.copyWith(awaitingPageRead: true);
    _lastSnapshot = null;
    // 改了 `_control`／`_lastSnapshot` 必须当场 notify（第五轮扫描第 4 条）：这一层另外九处
    // 都发了，唯独这里与 act 的异常出口没发 ⇒ 屏幕上那行「AI 控制中·快照可信」要等到
    // 下一次页面事件才纠正，而回灌已经在命令模型"先 web_read"了。
    notifyListeners();
    final failure = _mainFrameFailure;
    // `failure!` 不是随手写的：`webPageIsBroken` 的第一条就是"失败为空 ⇒ false"，
    // 那一格由 `test/build181_browser_session_gates_test.dart` 的纯函数表钉着
    // ——判据先红，这里才可能炸。
    if (webPageIsBroken(mainFrameFailure: failure, interactiveCount: null)) {
      // 主帧挂了但 `onPageFinished` 照样来一发 ⇒ 这一条不报失败，模型收到的就是
      // 「已打开页面」＋一份空 DOM，它会拿空白页继续答题（缺陷三）。
      // 快照照常作废、照常要求重读：这一页确实换了，只是新页是坏的。
      // `interactiveCount: null`＝"这一页还没读过"，判据与 read 那一路共用同一条函数
      // （第七轮·会话面第 4 条：过去 navigate 只看 failure、read 还要额外看元素数，
      //  同一条轨迹里能给出两条互斥事实）。
      logWebNavigate(seq: seq, ok: true, gated: false, why: 'none',
          mainFrameFailure: true);
      return WebActionResult(
        body: _mainFrameFailureNotice(failure!, zh: zh),
        isError: true,
      );
    }
    logWebNavigate(seq: seq, ok: true, gated: false, why: 'none',
        mainFrameFailure: false);
    final back = await _readBack(controller);
    final title = back.$1;
    // 地址那一格吃的是**读回来的**当前地址，不是本次调用的形参（第六轮扫描第 4 条）：
    // 短链、`meta refresh`、https 升级都会让"我要去 X"与"现在在 Y"是两个事实，
    // 而旧写法永远打印 X——AI 于是拿一个屏幕上没有的地址继续答题。
    // 读回来是空串（页面被关掉那一形，`_readBack` 的同一性核对交回空值）才退回形参。
    final requested = url.trim();
    final landed = back.$2.trim();
    final shownUrl = landed.isEmpty ? requested : landed;
    // 比较走**归一化之后的目标**，不走字符串相等（第七轮扫描第 4 条）：
    // 平台读回来的 `https://example.com/` 与模型写的 `https://example.com` 是同一条地址，
    // 拿 `!=` 比会让每一次裸域名导航都多印一句"被页面自己转走了"——假读数比没读数更坏。
    final requestedKey = webLaunchTargetKey(requested);
    final landedKey = webLaunchTargetKey(landed);
    final redirected = landedKey.isNotEmpty && landedKey != requestedKey;
    final landedHost = webLaunchHostKey(landed);
    final hostChanged = landedKey.isNotEmpty && landedHost != webLaunchHostKey(requested);
    final settled = _settled;
    return WebActionResult(
      body: zh
          ? '已打开页面：\n标题：${title.isEmpty ? '（无标题）' : title}\n'
              '地址：$shownUrl\n'
              '${redirected ? '注意：这一跳被页面自己转到了别的地址，不是刚才请求的那个。'
                  '${hostChanged ? '而且那个域名用户没有为这一跳点过头——不要在上面继续动手，'
                      '要先 web_navigate 到需要的地址。' : ''}\n' : ''}'
              '${settled ? '' : '注意：页面在 '
                  '${settleTimeout.inSeconds} 秒内没有报「加载完成」，内容可能还没稳定。'}\n'
              '请接着用 web_read 序列化这一页，再决定下一个动作。'
          : 'Page opened:\ntitle: ${title.isEmpty ? '(no title)' : title}\n'
              'url: $shownUrl\n'
              '${redirected ? 'Note: the page redirected itself to a different address. '
                  '${hostChanged ? 'The user never approved that host for this hop — do not act on it; '
                      'call web_navigate first.' : ''}\n' : ''}'
              '${settled ? '' : 'Note: no page-finished event within '
                  '${settleTimeout.inSeconds}s — the content may still be settling.'}\n'
              'Call web_read before acting.',
    );
  }

  /// `web_read`：注入刀一那段一次性只读脚本 → 解析 → 渲染成待回灌正文。
  ///
  /// 成功与失败都必须落**一行** `web read`（机械侧靠它数次数），所以失败也带字段：
  /// 拿 0 落一行再把原因回灌，绝不静默。
  ///
  /// 闸的顺序与 [navigate] 一致（判空 → 熔断 → 许可），差别只在许可闸取的是**一半**，
  /// 理由见下面那道闸的注释。
  Future<WebActionResult> read({required bool zh}) async {
    // 序号提到最前（第五轮扫描第 6 条，与入口面 B#1 同一条）：下面那两条早退过去既没序号
    // 也没日志行，机械侧读到的是"模型一次都没试"——而 [navigate] 那一形两件事都做了。
    final seq = nextSeq();
    final controller = _controller;
    if (controller == null) {
      _logEmptyRead(seq);
      return WebActionResult(
        body: zh
            ? '内置浏览器页面没有打开，没有可读取的页面。'
              '请先用 <web_navigate url="https://…" /> 打开一页。'
            : 'The built-in browser page is not open, so there is nothing to read. '
              'Open one first with <web_navigate url="https://..." />.',
        isError: true,
      );
    }
    final breaker = circuitBreakResult(zh: zh);
    if (breaker != null) {
      _logEmptyRead(seq);
      return breaker;
    }
    // 许可闸：`web_browser_plugins.dart` 给模型的 promptProtocol 明写了「接管期间任何
    // 动作都会被退回」，read 不在例外里——人正在页面上点链接，AI 读到的就是半张这一页
    // 半张那一页，那份快照当场就不可信（§五.2）。
    // 但这道闸只取「用户接管」那一半，不取整条 [aiActionAllowed]：`aiActionAllowed` 还
    // 含着「快照可信」，而 web_read 正是把 `awaitingPageRead` 置回 false 的**唯一**出路
    // （[noteRunLimits] 之后第一次读时它就是 true）。拿整条去闸 read 就是死锁：
    // 要读先有许可、有许可先要读。read 不欠那份快照，它自己就是还快照的那一步。
    // 回话仍复用 navigate 那一句 [aiActionRejectNotice]，不另写一套中文。
    if (webReadYieldToHuman(
        allowed: aiActionAllowed, paused: _control.aiControlPaused)) {
      // 被闸拒掉的这一次也落一行（本层文件头那条口径：机械侧要分得开「没动手」与
      // 「动手了被拦」），字段全 0 但这一行必须有。
      _logEmptyRead(seq);
      return WebActionResult(
          body: aiActionRejectNoticeFor(zh) ??
              (zh
                  ? 'AI 当前不能操作浏览器。'
                  : 'The app is not letting the AI use the browser right now.'),
          isError: true);
    }
    // 序列化之前先给这一页**一个短档**的稳定时间（第七轮·会话面第 4 条的另一半）：
    // `waitUntilSettled` 过去的唯一调用者是链路本身，三个派发点等、`read` 不等——而本层
    // 那句注释写的「没有这条等待，插件会在半加载的 DOM 上跑脚本」说的就是 `read` 这个插件。
    // navigate 超时那一形尤其明显：同一条回话里既写「20 秒内没报加载完成，内容可能还没稳定」
    // 又命令模型接着 web_read ⇒ 它照做就是在还在写的 DOM 上序列化，读回 0 个元素那一格
    // 又被上面那条坏页判据当成正经失败。
    // 只等 [AppWait.navChainQuiet] 这一档（900ms），**不等满 settleTimeout**：
    // 读一次就把模型的一步钉住 20 秒，是拿另一种浪费换这一种。
    await waitUntilSettled(timeout: AppWait.navChainQuiet);
    // 步数只在**真正碰到平台**之前扣（第五轮扫描第 3 条）：过去它排在让位闸上面，于是
    // "用户按了「让我来」、模型照 promptProtocol 每轮试一次 web_read"这一族能把整条会话的
    // 预算烧穿——烧穿之后四个动作只剩熔断那一句（那句还命令模型别再发起任何 web 动作），
    // 而日志里全是 `gated=1`、一次真派发都没有。位次口径与 navigate／back 一致。
    _stepsDone++;
    final Object raw;
    try {
      raw = await controller
          .runJavaScriptReturningResult(kWebDomSerializeScript);
    } catch (e) {
      _logEmptyRead(seq);
      return WebActionResult(
        body: zh
            ? '页面脚本没能跑起来（可能被 CSP 拦下，或页面还没就绪）：$e'
            : 'The page script did not run (blocked by CSP, or the page is not ready): $e',
        isError: true,
      );
    }
    final parsed = parseWebDomPayload(raw.toString());
    final snapshot = parsed.snapshot;
    if (snapshot == null || !parsed.isOk) {
      _logEmptyRead(seq);
      return WebActionResult(
          body: parsed.error ?? '页面序列化失败。', isError: true);
    }
    final render = renderWebDomForModel(snapshot, zh: zh);
    logWebRead(
      seq: seq,
      chars: render.text.length,
      fullChars: render.fullLength,
      truncated: render.truncated,
      interactive: snapshot.interactiveCount,
      omitted: render.omittedBlocks + render.omittedElements,
    );
    if (!identical(_controller, controller)) {
      // 序列化跑完了，但这一层已经不再持有那个 controller ⇒ 这份 DOM 属于**上一页**。
      // 写进 `_lastSnapshot` 就是让下一个动作拿旧 DOM 去点新页，而 `webNoteAiPageRead`
      // 还会把"快照可信"盖上去（第六轮扫描第 5 条前半）。日志那行照落：它讲的是
      // "这一次脚本调用吐了多少字"，那个事实成立，不成立的只是"它属于现在这一页"。
      return WebActionResult(
        body: zh
            ? '读取期间浏览器页被换掉或关闭，这份 DOM 不属于现在这一页，已丢弃。'
              '请重新 web_read。'
            : 'The page was switched or closed while reading; that DOM belongs to another '
              'page and was discarded. Call web_read again.',
        isError: true,
      );
    }
    _lastSnapshot = snapshot;
    // 读成功＝快照重新可信（§五.3 那一句「先读再动」的落点）。
    _control = webNoteAiPageRead(_control);
    notifyListeners();
    final failure = _mainFrameFailure;
    if (webPageIsBroken(
        mainFrameFailure: failure,
        interactiveCount: snapshot.interactiveCount)) {
      // 缺陷三的另一半：AI 未必先 navigate——直接 read 已经开着的那一页那条路不过
      // navigate 的闸，所以这里也要说同一句。判据取「一个可交互元素都没有」：
      // 这一页真读得出东西时不该吓唬模型说它没加载。
      // isError 也一并置真——正文里 0 块可点的元素＋一句「页面坏了」，
      // 标成 success 就等于默许模型把这份空 DOM 当成「这一页就是这么空」。
      return WebActionResult(
        body: '${render.text}\n${_mainFrameFailureNotice(failure!, zh: zh)}',
        isError: true,
      );
    }
    return WebActionResult(body: render.text);
  }

  /// `web_act`：许可闸 → 重读闸 → 序号闸 → 密码闸 → 派发 → 一行 `web act`。
  ///
  /// 每一道闸的拒绝都落**一行**日志（outcome 取闭集里那九个词之一，见 [kWebActOutcomes]），
  /// 机械侧才分得开「AI 没动手」与「AI 动手了但被闸拦下」。
  Future<WebActionResult> act({
    required String idxRaw,
    required String actionRaw,
    required String value,
    required bool zh,
  }) async {
    final seq = nextSeq();
    final controller = _controller;
    if (controller == null) {
      // 两条早退也各落一行（结果词用 `kWebActOutcomes` 里那两个同名词，
      // 与 `web navigate` 的 `why` 是同一套说法，机械侧不用记两套词表）。
      logWebAct(seq: seq, idx: 0, tag: 'none', outcome: 'page_not_open');
      return WebActionResult(
        body: zh
            ? '内置浏览器页面没有打开，没有可点击的元素。'
            : 'The built-in browser page is not open, so there is no element to act on.',
        isError: true,
      );
    }
    final breaker = circuitBreakResult(zh: zh);
    if (breaker != null) {
      logWebAct(seq: seq, idx: 0, tag: 'none', outcome: 'circuit_break');
      return breaker;
    }
    final idx = int.tryParse(idxRaw.trim());
    final kind = _actKind(actionRaw);
    if (idx == null || idx <= 0 || kind == null) {
      logWebAct(
          seq: seq,
          idx: idx ?? 0,
          tag: 'unknown',
          outcome: kWebActOutcomeUnknown);
      return WebActionResult(
        body: zh
            ? '动作参数不合法：idx 必须取 web_read 给出的正整数序号，'
                'action 只能是 click / input / clear。'
            : 'Bad arguments: idx must be a positive serial from web_read, '
                'and action is one of click / input / clear.',
        isError: true,
      );
    }
    // 闸①：接管中 / 快照过期。判据只住 `webAiActionAllowed` 那一个函数——过去这里写的
    // 是 `_control.aiControlPaused || webMustReRead(_control)`（与它等价的两半拼起来），
    // 四个动作于是各有各的写法：navigate 用许可、这里自己拼，早晚漂成两种口径。
    // 顺序也与其余三个统一：判空 → 熔断 → 许可 → 序号 → 密码 → 派发（许可在派发之前，
    // 派发那一下才是真正碰到用户屏幕的动作）。
    if (!aiActionAllowed) {
      final outcome =
          _control.aiControlPaused ? 'reject_paused' : 'reject_reread';
      logWebAct(seq: seq, idx: idx, tag: 'blocked', outcome: outcome);
      return WebActionResult(
        // 这一句照旧按调用点的 zh 走（act 的 zh 是从插件一路传下来的真值，
        // [aiActionRejectNotice] 那条快捷 getter 恒给中文，这里不许跟着它退化成中文）。
        body: webAiActionRejectNotice(_control, zh: zh) ??
            (zh ? '这一跳被浏览器状态闸拦下。' : 'Blocked by the browser state guard.'),
        isError: true,
      );
    }
    final snapshot = _lastSnapshot;
    final matches = (snapshot?.elements ?? const <WebDomElement>[])
        .where((e) => e.idx == idx)
        .toList(growable: false);
    if (matches.isEmpty) {
      logWebAct(
          seq: seq, idx: idx, tag: 'missing', outcome: 'not_found');
      return WebActionResult(
        body: zh
            ? '这一次页面快照里没有序号 $idx 的元素（页面变了，或序号超出范围）。'
                '请重新 web_read 再决定动作。'
            : 'Serial $idx is not in this snapshot (the page changed, or it is '
                'out of range). Call web_read again before acting.',
        isError: true,
      );
    }
    final element = matches.single;
    // 闸②：密码框一律不代填（§4.3）。
    final human = webActNeedsHumanNotice(
        targetNeedsHuman: element.needsHuman, idx: idx, zh: zh);
    if (human != null) {
      logWebAct(
          seq: seq,
          idx: idx,
          tag: element.tag,
          outcome: 'reject_password');
      return WebActionResult(body: human, isError: true);
    }

    // AI 导航窗口在**派发之前**挂上，并把「这一次加载」的两条状态归零（缺陷二的主案发现场）：
    //  · 原来这里是「先派发、后 `_aiNavInFlight++`」，而 `el.click()` 起的那次导航，它的
    //    `onPageStarted` 就在 JS 返回前后落到平台通道——晚一步挂窗口，那个事件就掉在
    //    `_aiNavInFlight == 0` 的窗户外面，被 `webNoteUserUrlChange` 判成「用户上手」⇒ 转人工；
    //  · `_settled` 留着上一页的 true ⇒ `waitUntilSettled` 即刻返回、`--` 更是抢跑，
    //    于是此后每一个动作都被许可闸拒掉，而用户一个字没碰这一页。
    // 三个 kind **都要观察**有没有起导航（第七轮·会话面第 1 条）：`input` 派发之后，
    // 页面自己的 `oninput`／`change` 监听里执行 `location.href=…` 是"输入即搜"那一族
    // 的正常写法，它起的导航落在 JS 返回之后几十毫秒——原来只有 click 复位信号、
    // 只有 click 观察，于是那一跳被 `webNoteUserUrlChange` 记成「用户上手」⇒ 四个动作
    // 全被拒，死锁到用户亲手按「继续 AI」（＝缺陷①那一族换了个入口复发）。
    // "不白等"不靠跳过观察来解决：观察窗 [navGrace] 只等 700ms，没信号立刻回。
    // 旧注释给的两条理由里，第二条（抹掉「这一页主帧已经失败」）由下面那一段解决——
    // 派发前把**三条**状态读成快照，finally 一起还原（第七轮第 5 条：过去只还 `_settled`
    // 一条，等于"投机清空不许留赃"这条纪律只兑现了三分之一）。
    // 步数排在全部页面闸之后、派发之前（位次口径见 [read] 里那条同位的注释）。
    _stepsDone++;
    final generation = _sessionGeneration;
    final settledBeforeDispatch = _settled;
    final failureBeforeDispatch = _mainFrameFailure;
    final signalBeforeDispatch = _navSignalSeen;
    _mainFrameFailure = null;
    _navSignalSeen = false;
    _settled = false;
    var navObserved = false;
    _aiNavInFlight++;
    try {
      final out = await controller.runJavaScriptReturningResult(
          _actScript(idx: idx, kind: kind, value: value));
      final replied = out.toString().replaceAll('"', '').trim();
      // JS 回的三个短码就是三道**页面侧**的闸：元素没了 / 密码 / 不自动触发下载。
      if (replied == 'nf') {
        logWebAct(
            seq: seq, idx: idx, tag: element.tag, outcome: 'not_found');
        return WebActionResult(
          body: zh
              ? '元素 [$idx] 已经不在页面上了（DOM 被脚本改过）。请重新 web_read。'
              : 'Element [$idx] is no longer in the DOM. Call web_read again.',
          isError: true,
        );
      }
      if (replied == 'pw' || replied == 'dl') {
        // 两个词分开记（第七轮·入口面第 5 条）：旧表把 `dl` 也写成 `reject_domain`，
        // 而真正的域名拒绝**一次都不落行** ⇒ 拿日志统计"域名闸拦了多少"得出的数
        // 只可能来自下载拦截，与事实完全反向。
        final outcome = replied == 'pw' ? 'reject_password' : 'reject_download';
        logWebAct(
            seq: seq, idx: idx, tag: element.tag, outcome: outcome);
        return WebActionResult(
          body: replied == 'pw'
              ? (zh
                  ? '元素 [$idx] 所在表单含密码框，提交那一步必须用户亲手做。'
                  : 'Element [$idx] belongs to a form with a password field; the user must submit it.')
              : (zh
                  ? '元素 [$idx] 指向 blob/data 链接，App 不自动触发下载。'
                  : 'Element [$idx] points at a blob/data link; the app does not trigger downloads.'),
          isError: true,
        );
      }
      logWebAct(seq: seq, idx: idx, tag: element.tag, outcome: 'ok');
      // 动手之后快照作废：下一步必须重读（§五.3「从不假设自己记得页面状态」）。
      _control = _control.copyWith(awaitingPageRead: true);
      _lastSnapshot = null;
      // 派发之后先看这一跳有没有真的起导航（三个 kind 一律观察，理由在上面那段）。
      // 没信号就立刻回——"点了没换页不白等"靠的是这道观察窗，不是靠跳过观察。
      await waitForNavigationSignal();
      // 代际变了 ⇒ `_navSignalSeen` 是**新会话**的 `onPageStarted` 设的（第六轮扫描第 5 条中段）：
      // 拿它回答"我这一跳有没有发生"，就是让 AI 相信它点了一下而跳到了别的页。
      // 这里也不当它没发生（那会把三条投机清掉的状态还原到一个已经换了的页面上），
      // 而是照 navigate 那一形的办法明说"观察中断"。
      if (_sessionGeneration != generation) return _lostTrackResult(zh: zh);
      navObserved = _navSignalSeen;
      if (navObserved) await waitUntilSettledChain();
      // 链路这一跑最长 `navChainMaxHops × settleTimeout`（第五轮量到 20 秒量级）：
      // 上面那道代际复检排在它**之前**，所以这一跑里用户关页又重开，回来时没人再认。
      // 后果是两条都错：`_mainFrameFailure` 讲的是**新会话**那一页的失败（把它算成
      // 我这一跳的），而 885 那一条无条件 `isError=false` 会替一页我根本没观察过的
      // 页面签成功（第八轮扫描第 1 条）。
      if (_sessionGeneration != generation) return _lostTrackResult(zh: zh);
    } catch (e) {
      // 通道故障不许记成"序号不存在"（第七轮·会话面第 6 条）：旧写法两处都填 `not_found`，
      // 于是机械侧唯一那条"模型给错序号"的读数与"JS 抛了"混成一样。
      // 这一路还**必须**把"动手之后快照作废"补上：JS 抛出来之前可能已经点下去了，
      // 那份快照还是不是这一页的我们不知道——不知道就重读，这才是 §五.3 那条纪律的正解。
      logWebAct(
          seq: seq, idx: idx, tag: element.tag, outcome: 'dispatch_error');
      _control = _control.copyWith(awaitingPageRead: true);
      _lastSnapshot = null;
      // 同一条方法里两种口径不许留（第五轮扫描第 4 条）：正常出口 735 行发，异常出口不发。
      notifyListeners();
      return WebActionResult(
        body: zh ? '动作派发失败：$e' : 'The action could not be dispatched: $e',
        isError: true,
      );
    } finally {
      // 递减只在 finally 里：上面任何一条 return（含 catch 里那条）都不许把窗口留在
      // 打开状态——`_aiNavInFlight` 一旦回不到 0，之后用户真的上手也判不出来了。
      // 再配一道代际：会话已经换了（用户关页又重开），这一趟迟到的 finally 要是跑回来，
      // 减的就是**新会话**刚挂上的窗口，那比不减更糟（第五轮扫描第 2 条的另一半）。
      // 整段 finally 都要挂代际（第七轮扫描第 1 条）：第六轮只把**递减**挂了代际，
      // 那三条"投机清空"的还原没挂 ⇒ 迟到的一趟会把**旧页**的三个事实写进**新会话**的字段：
      //  · `_settled=true` ⇒ 下一次 `read` 的 `waitUntilSettled` 即刻返回，在还在写的 DOM 上序列化；
      //  · `_mainFrameFailure=上一跳的 code=-105` ⇒ 好页被说成坏页（正是本轮开头说要修那一形）；
      //  · `_navSignalSeen=true` ⇒ `waitForNavigationSignal` 短路，"点了没换页"被报成换了页。
      // 换了代际就什么都不写：新会话的三位由 `bindController` 自己摆，notify 也已由它发过。
      // notify 排在改动之后（同一条锁的另一半）；这里不能用裸 `return`——方法的返回类型是
      // `Future<WebActionResult>`，而 `finally` 里任何 return 都会吞掉 catch 那条已决定的回话。
      if (_sessionGeneration == generation) {
        _aiNavInFlight--;
        if (!navObserved) {
          _settled = settledBeforeDispatch;
          _mainFrameFailure = failureBeforeDispatch;
          _navSignalSeen = signalBeforeDispatch;
        }
        // 窗口关掉＝"AI 不在动了"这件事要告诉界面（第六轮扫描第 2 条）：那枚「继续 AI」
        // 的 `onPressed` 读的就是 `aiNavWindowOpen`。
        notifyListeners();
      }
    }
    final failure = _mainFrameFailure;
    if (navObserved &&
        webPageIsBroken(mainFrameFailure: failure, interactiveCount: null)) {
      // 这一跳真的起了导航、而主帧报了失败：这里不认，回灌就是「已对元素执行 click」
      // ＋成功状态，而屏幕上是一片白（缺陷三的第四条路径，第五轮浏览器扫描第 3 条）。
      // 判据从 `kind == click` 换成 `navObserved`：三个 kind 现在都可能起跳，而没有导航时
      // `_mainFrameFailure` **已被还原**——那时它讲的是上一跳的旧事实，拿来答这一跳
      // 就是第七轮第 5 条要防的那一形。
      return WebActionResult(
        body: _mainFrameFailureNotice(failure!, zh: zh),
        isError: true,
      );
    }
    // 从派发点到现在的整段时间里没有任何导航事件 ⇒ 这一页没换。这句话必须说出来：
    // 页面把 `<a>` 拦下（我们自己的 prevent 就是这种）、`target=_blank`、下载链、
    // 只改 pushState 的 SPA，四种都长同一个样子——一个成功状态加**旧地址**，
    // 模型会当"跳转已完成"继续答，而它手里那份快照还是上一张页面。
    final noNavObserved = !navObserved;
    final (title, url) = await _readBack(controller);
    notifyListeners();
    return WebActionResult(
      body: zh
          ? '已对元素 [$idx]（${element.tag}）执行 ${kind.name}。\n'
              '当前标题：${title.isEmpty ? '（无标题）' : title}\n'
              '当前地址：${url.isEmpty ? '（未知）' : url}\n'
              '${noNavObserved ? '这一跳没看到页面导航（可能只是页面内行为，也可能被这一页拦下了）。\n' : ''}'
              '序号已作废，请重新 web_read 再继续。'
          : 'Applied ${kind.name} to element [$idx] (${element.tag}).\n'
              'title: ${title.isEmpty ? '(no title)' : title}\n'
              'url: ${url.isEmpty ? '(unknown)' : url}\n'
              '${noNavObserved ? 'No navigation was observed for this click — it may be in-page, or the page intercepted it.\n' : ''}'
              'The serials are stale now — call web_read again.',
    );
  }

  /// `web_back`：history back。无论退没退成都落一行 `web back`，
  /// `reread=1` 是必须的下一步提醒（退完之后页面快照一律作废，§五.3）。
  Future<WebActionResult> back({required bool zh}) async {
    final seq = nextSeq();
    final controller = _controller;
    if (controller == null) {
      logWebBack(seq: seq, ok: false, reread: false, failed: false);
      return WebActionResult(
        body: zh
            ? '内置浏览器页面没有打开，没有可后退的历史。'
            : 'The built-in browser page is not open, so there is no history to go back through.',
        isError: true,
      );
    }
    final breaker = circuitBreakResult(zh: zh);
    if (breaker != null) {
      logWebBack(seq: seq, ok: false, reread: false, failed: false);
      return breaker;
    }
    // 许可闸（与 [navigate] 同一道、同一句回话；顺序仍是 判空 → 熔断 → 许可）：
    // `web_browser_plugins.dart` 对模型承诺的是「接管期间任何动作都会被退回」，
    // back 也是动作。而且这一条必须排在 `canGoBack()`/`goBack()` 之前——后退是把
    // 用户正在看的那一页直接撤掉，判不出许可就不该碰平台（fail-closed，同 §六.2 的空名单口径）。
    if (!aiActionAllowed) {
      // 这一条形过去一个字都不落（第五轮那批只补了"页面没开"与"宿主熔断"），于是
      // 「用户按了让我来 → 模型试一次后退」在机械侧等于"没试"（第六轮扫描第 1 条）。
      // `back` 这条线没有 outcome 位，能给的读数就是 `ok=0 reread=0 failed=0`。
      logWebBack(seq: seq, ok: false, reread: false, failed: false);
      return WebActionResult(
          body: aiActionRejectNoticeFor(zh) ??
              (zh
                  ? 'AI 当前不能操作浏览器。'
                  : 'The app is not letting the AI use the browser right now.'),
          isError: true);
    }
    _stepsDone++;
    bool can;
    try {
      can = await controller.canGoBack();
    } catch (e) {
      // 读历史状态那一下也会抛（同一族的第二条：`back` 是四个动作里唯一没有 catch 的，
      // 第六轮扫描第 3 条）。抛出去就冒到插件层的通用 catch ⇒ 模型只收到「插件执行失败」，
      // 而这一步的步数已经扣了、一行 `web back` 都没有——本方法文档那句
      // "无论退没退成都落一行"当场作废。
      logWebBack(seq: seq, ok: false, reread: false, failed: false);
      return WebActionResult(
        body: zh
            ? '后退的历史状态读不出来：$e'
            : 'The browser history state could not be read: $e',
        isError: true,
      );
    }
    // 代际在**进平台之前**就记下来：后面那条 `backFailure` 判的是"这一跳还在不在这一个会话里"，
    // 而它排在 `if (can)` 那一段之外（`can=false` 时也要有这个读数）。
    final generation = _sessionGeneration;
    if (can) {
      // 后退同样是一次导航：起点清状态（见 [navigate] 里那一段同名的注释），
      // 窗口在 `goBack()` 之前挂上，递减只在 finally 里。
      // 见 [navigate] 里那三条同名的记录：清了就要能还（第八轮扫描第 2 条的另一半）。
      final settledBeforeDispatch = _settled;
      final failureBeforeDispatch = _mainFrameFailure;
      final signalBeforeDispatch = _navSignalSeen;
      _mainFrameFailure = null;
      _navSignalSeen = false;
      _settled = false;
      _aiNavInFlight++;
      try {
        await controller.goBack();
        await waitUntilSettledChain();
      } catch (e) {
        // 见上一格：派发那一下抛了也要落一行（`reread=1`：这一跳可能退了一半，
        // 快照无论如何都不能再信）。
        logWebBack(seq: seq, ok: false, reread: true, failed: false);
        // `reread=1` 说了"必须重读"，状态就得真的作废（第七轮扫描第 2 条）：
        // 旧写法在这一条形里直接 return，`_lastSnapshot` 与 `awaitingPageRead` 原样留着 ⇒
        // 下一次 `act` 照样过重读闸，拿**后退之前那一页**的序号去点**现在这一页**。
        // 三条出口里只有这一条是反的（成功那条与 `can=false` 那条都作废旧快照）。
        // 这两条写同样要挂代际（第八轮补，判据自审之后本席回读调用点发现的）：
        // 会话换了的时候这条迟到的 catch 不许作废**新会话**那份可信快照。
        // 回话那一头保持原样——"派发没成功"这件事与代际无关，是真的失败了。
        if (_sessionGeneration == generation) {
          _control = _control.copyWith(awaitingPageRead: true);
          _lastSnapshot = null;
          notifyListeners();
        }
        return WebActionResult(
          body: zh
              ? '后退没能派发：$e'
              : 'Going back could not be dispatched: $e',
          isError: true,
        );
      } finally {
        // 递减只在 finally 里；代际变了就不许减**新会话**刚挂上的窗口（第五轮第 2 条）。
        if (_sessionGeneration == generation) {
          _aiNavInFlight--;
          // 没起导航 ⇒ 这一页没换 ⇒ 三条一起还（见 [navigate] 里同一段）。
          if (!_navSignalSeen) {
            _settled = settledBeforeDispatch;
            _mainFrameFailure = failureBeforeDispatch;
            _navSignalSeen = signalBeforeDispatch;
          }
          // 窗口关掉＝"AI 不在动了"这件事本身要告诉界面（第六轮扫描第 2 条）：
          // 那枚「继续 AI」的 `onPressed` 读的就是 `aiNavWindowOpen`，而这一形之后
          // AI 被许可闸拒在外面、不再产生任何页面事件 ⇒ 没有 notify 就永远点不亮。
          notifyListeners();
        }
      }
    }
    // 后退也是一次导航：真退了而这一跳的主帧报了失败 ⇒ 不许回灌「已后退一页」＋isError:false
    // （navigate／act 都认这一条，back 一条都不认＝第五轮扫描第 5 条）。
    // 日志里 `ok` 讲的是"退成了没有"、`failed` 讲的是"退到的那一页是坏的"，两个字段分得开。
    // 只有"这一跳还在自己的会话里"时，`_mainFrameFailure` 讲的才是这一跳的事
    // （第六轮扫描第 5 条后半：bind→unbind→bind 之后那个位是**新页**的失败，
    //  拿它回答 back 就是替没观察过的页面报坏页）。
    // 四位一起由 [webBackOutcome] 那张表决定（第八轮扫描第 3 条）：这里只按表落子，
    // 不再就地重抄一遍条件——原先这四个决定散在四处**不同**的写法上，才会漂成
    // "日志说必须重读、回话说当前仍是这一页"那种互相打脸的形状。
    final outcome = webBackOutcome(
        can: can, sameGeneration: _sessionGeneration == generation);
    final backFailure = outcome.failureCounts ? _mainFrameFailure : null;
    logWebBack(
        seq: seq,
        ok: outcome.ok,
        reread: outcome.reread,
        failed: backFailure != null);
    if (outcome.invalidateSnapshot) {
      // 快照作废排在判坏页**之前**：退到的那一页无论好坏都不是刚才那一页，
      // 少这一步就是让模型拿着旧 DOM 去点新页（§五.3）。
      // 两条**写**也都要挂代际（第八轮扫描第 3 条前半）：会话换了之后这里作废的是
      // **新会话**那份可信快照，还把 `awaitingPageRead` 置真——AI 于是"重读再动手"，
      // 动在用户正操作的那一页上。
      _control = _control.copyWith(awaitingPageRead: true);
      _lastSnapshot = null;
      notifyListeners();
    }
    if (outcome.lostTrack) return _lostTrackResult(zh: zh);
    if (backFailure != null &&
        webPageIsBroken(
            mainFrameFailure: backFailure, interactiveCount: null)) {
      return WebActionResult(
        body: _mainFrameFailureNotice(backFailure, zh: zh),
        isError: true,
      );
    }
    final (title, url) = can ? await _readBack(controller) : ('', '');
    notifyListeners();
    return WebActionResult(
      body: can
          ? (zh
              ? '已后退一页。\n标题：${title.isEmpty ? '（无标题）' : title}\n'
                  '地址：${url.isEmpty ? '（未知）' : url}\n'
                  '页面已变，请用 web_read 重新读取。'
              : 'Went back one page.\ntitle: ${title.isEmpty ? '(no title)' : title}\n'
                  'url: ${url.isEmpty ? '(unknown)' : url}\nCall web_read again.')
          : (zh ? '没有可后退的历史记录，当前仍是这一页。' : 'Nothing to go back to.'),
      isError: !can,
    );
  }

  /// 读取失败那一行：字段全 0，但**这一行必须有**（机械侧要数得出「试过一次」）。
  void _logEmptyRead(int seq) {
    logWebRead(
        seq: seq,
        chars: 0,
        fullChars: 0,
        truncated: false,
        interactive: 0,
        omitted: 0);
  }

  // ===== 页面事件（浏览器页把 NavigationDelegate 的事件原样递进来） =====

  /// 导航开始。**非 AI 发起**的那一次＝用户上手了 ⇒ 按 §五.2 直接转人工，
  /// 不是「忽略并继续」（AI 抢用户的点击是本功能最容易做出来的事故）。
  void onPageStarted(String url) {
    _settled = false;
    _navSignalSeen = true;
    _navEventSeq++;
    // **任何人**发起的导航都算"这一次加载重新开始"（第六轮浏览器扫描第 2 条）：
    // 这个位过去只在三个 AI 派发点清，于是"AI 导航失败 → 用户自己打开一个好页 →
    // 交还 AI → web_read"那一条路上，回灌说的还是上一跳的 code=-105，
    // 一个好页被当成坏页退回模型。文件头与本层注释都写着"讲的永远是这一次加载"，
    // 那就得每次 started 都清，不能只清 AI 自己那三次。
    _mainFrameFailure = null;
    if (_aiNavInFlight == 0) {
      _control = webNoteUserUrlChange(_control, url);
      LoggerService.instance.info(
          '浏览器收到用户发起的导航，转人工：累计接管 ${_control.takeoverCount} 次',
          cat: LogCat.react,
          tag: logTag);
    }
    notifyListeners();
  }

  /// 导航结束：置「已稳定」并唤醒 [waitUntilSettled] 的等待者。
  void onPageFinished(String url) {
    _settled = true;
    _navSignalSeen = true;
    if (_aiNavInFlight == 0 && url.trim().isNotEmpty) {
      _control = webNoteUserUrlChange(_control, url);
    }
    _releaseSettleWaiter();
    notifyListeners();
  }

  // ===== 等页面稳定（没有这条，插件会在半加载的 DOM 上跑脚本） =====

  /// 等 [onPageFinished]；超时不抛（见 [settleTimeout] 的注释）。
  Future<void> waitUntilSettled({Duration timeout = settleTimeout}) {
    if (_settled) return Future<void>.value();
    final waiter = _settleWaiter ??= Completer<void>();
    _settleTimer?.cancel();
    _settleTimer = Timer(timeout, () {
      if (!waiter.isCompleted) waiter.complete();
    });
    return waiter.future.whenComplete(() {
      _settleTimer?.cancel();
      _settleTimer = null;
      if (_settleWaiter == waiter) _settleWaiter = null;
    });
  }

  void _releaseSettleWaiter() {
    final waiter = _settleWaiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  /// 派发之后观察最多 [navGrace]：**这一跳到底有没有起导航**。
  ///
  /// 有（`onPageStarted`／`onPageFinished` 任一发落进窗口）⇒ 调用方接着 [waitUntilSettled]，
  /// 窗口仍然开着，归因照旧算 AI 的；没有 ⇒ 立刻返回，让调用方把派发前那个 `_settled`
  /// 还回去。这一格存在的理由是"点了没换页"那一形：过去它要白等满 [settleTimeout]＝20 秒，
  /// 而一个 ReAct 轮里这种点击比换页常见得多（展开菜单、勾框、切 tab）。
  ///
  /// 用轮询而不是 Completer：这里等的不是"某个异步结果"，而是"一小段窗口里有没有事件落地"，
  /// 50 ms 一档的粒度足够（真导航在几十毫秒内就到），而且不会多造一个跨帧的挂起句柄。
  Future<void> waitForNavigationSignal({Duration grace = navGrace}) async {
    if (_navSignalSeen) return;
    const step = AppWait.navObserveStep;
    for (var waited = Duration.zero; waited < grace; waited += step) {
      await Future<void>.delayed(step);
      if (_navSignalSeen) return;
    }
  }

  /// 这一轮派发有没有观察到导航（[waitForNavigationSignal] 的读数，判据读它）。
  @visibleForTesting
  bool get navigationSignalSeen => _navSignalSeen;

  /// 导航链路的安静窗，与最多跟几跳（见 [waitUntilSettledChain]）。
  static const Duration navChainQuiet = AppWait.navChainQuiet;
  static const int navChainMaxHops = 5;

  /// 落进会话层的导航事件计数（`onPageStarted` 每跳加一）。[waitUntilSettledChain]
  /// 用它判「安静窗里到底有没有新导航」——比记时间戳少一个时钟依赖，测试也好喂。
  int _navEventSeq = 0;

  /// 这一串导航跟到第几跳了（判据读它，也读那条上限的反向闸）。
  @visibleForTesting
  int get navChainHops => _navChainHops;

  int _navChainHops = 0;

  /// 等这一串导航安静下来，**全程留在 AI 窗口之内**（在 `finally` 里那句递减之前调用）。
  ///
  /// 为什么不能只等第一跳的 `onPageFinished`：短链、`<meta http-equiv=refresh>`、
  /// onload 里 `location.replace` 的验证页，都是「第一跳一完成就自己跳第二跳」，
  /// 而第二跳的 `onPageStarted` 落在窗口外就被记成用户上手 ⇒ 四个动作全被拒、
  /// 死锁到用户亲手按「继续 AI」（第五轮浏览器扫描第 1 条：上一版只修了第一跳）。
  /// 代价写清楚：每一次 AI 导航至少多花一个 [navChainQuiet]＝900 毫秒，最多跟
  /// [navChainMaxHops] 跳；换掉的是整条会话被误判成人工。
  Future<void> waitUntilSettledChain() async {
    // 进来先把当代记下：这条链路等的是"**我**这一跳串起来的导航"，不是"此后任何导航"。
    // `unbindController` 会叫醒在飞的等待，而它把 `_settled` 一起置回了 false ⇒
    // 旧写法在这里只看"`_navEventSeq` 变了没有"，于是当成"还没完"回到循环顶部再挂一档，
    // 从此跟着**下一个会话**（很可能是用户亲手点开的页）跳，最多 5 跳
    // （第五轮扫描第 1 条；签名就是回灌里那句"已打开页面"配着屏幕上的另一页）。
    final generation = _sessionGeneration;
    _navChainHops = 0;
    while (true) {
      if (_sessionGeneration != generation) return;
      // 取样必须排在**等之前**：第一跳是在这一次等待里完成的，
      // 期间又起导航（短链那一族）只有这么量才看得见（第六轮浏览器扫描第 1 条前半）。
      final beforeWait = _navEventSeq;
      await waitUntilSettled();
      if (_sessionGeneration != generation) return;
      final movedWhileWaiting = _navEventSeq != beforeWait;
      final beforeQuiet = _navEventSeq;
      await Future<void>.delayed(navChainQuiet);
      // 静默窗之后、`_navChainHops++` 之前再认一次代际（第八轮扫描第 6 条）：
      // 这 900 毫秒里换了会话，那一跳是**新会话**起的，记到老链路上会把
      // 新会话自己的 5 跳预算提前吃掉（第二跳落到窗口外就被判成"用户上手"）。
      if (_sessionGeneration != generation) return;
      if (!webNavChainContinues(
          movedWhileWaiting: movedWhileWaiting,
          movedInQuiet: _navEventSeq != beforeQuiet,
          hops: _navChainHops,
          maxHops: navChainMaxHops)) {
        return;
      }
      _navChainHops++;
    }
  }

  // ===== 主帧失败（缺陷三的那条入口） =====

  /// 页面侧 `onWebResourceError` 里 `isForMainFrame == true` 的那一条递进来。
  ///
  /// 为什么由页面递而不是这一层自己判：错误事件只有 `NavigationDelegate` 拿得到，
  /// 而那个 delegate 住在 `browser_screen.dart`；这一层不认 widget，只认这一个入口
  /// （与 [domainConfirmer] 同一形状：页面是执行端，会话层是状态的所有者）。
  /// 只有 started/finished 两个入口时，主帧挂了也照样会来一发 `onPageFinished`，
  /// [navigate] 就无条件报成功 ⇒ AI 拿 0 块正文继续答题，用户看到的是空白页。
  /// 日志只报「失败了」这个状态，不带原因原文（WebView 的描述里可能含完整地址）。
  void onMainFrameFailed(String reason) {
    final text = reason.trim();
    _mainFrameFailure = text.isEmpty ? '未知原因' : text;
    LoggerService.instance.info(
        '浏览器会话：主帧加载失败，这一次导航的回话将标为失败',
        cat: LogCat.react,
        tag: logTag);
    notifyListeners();
  }

  /// 主帧失败时回灌给模型的那一句（[navigate] 与 [read] 共用一个所有者）。
  ///
  /// 为什么抽成函数而不是两处各写一遍：同一件事在两个动作里给出两种说法，
  /// 模型就会在「这一页坏了」和「这一页本来就是空的」之间猜（教训 #62 同型）。
  /// 读回"现在这一页"的标题与地址——**必须**包起来，且先核对 controller 同一性。
  ///
  /// 第七轮·会话面第 7 条：三个动作收尾各有一次 `await controller.getTitle()`，
  /// 它们排在 `finally`（窗口已关）之后、任何 `try` 之外。而 `dispose → unbindController`
  /// 会把 controller 丢掉（用户按系统返回关掉浏览器页是常态路径，`unbindController`
  /// 还会主动叫醒在飞的等待），此时平台调用要么抛——冒到 `plugin_registry.dart` 那个
  /// 通用 catch ⇒ 模型只收到「插件执行失败: …」，而 `logWebAct` 早就落过 `outcome=ok`
  /// ＝两条通道就此分叉，且插件里那句 `updateReasoningStep` 永不执行（思考面板那一格
  /// 停在 running）；要么给陈旧值——那就是替用户点开的**另一页**签字。
  /// 两种都不能当"这一页现在长这样"。读不到就交回两个空串：回灌正文里
  /// 「（无标题）／（未知）」那两句本来就是给空值准备的。
  Future<(String, String)> _readBack(WebViewController controller) async {
    if (!identical(_controller, controller)) return ('', '');
    try {
      final title = await controller.getTitle() ?? '';
      final url = await controller.currentUrl() ?? '';
      return (title, url);
    } catch (_) {
      return ('', '');
    }
  }

  /// "这一跳的观察断了"那一句的**唯一**出处：`act` 的派发后复检与链路后的复检都用它。
  /// 同一个意思在两处各写一遍＝改一处漏一处（本仓那条"同源双写"的账）。
  WebActionResult _lostTrackResult({required bool zh}) => WebActionResult(
        body: zh
            ? '这一跳的观察在浏览器页关闭或换页时中断了，屏幕上是哪一页我不知道。'
              '序号已作废，请重新 web_read 再继续。'
            : 'This action lost track of the page (it was closed or switched over). '
              'The serials are stale — call web_read again.',
        isError: true,
      );

  String _mainFrameFailureNotice(String reason, {required bool zh}) => zh
      ? '这一页主体没能加载：$reason\n'
          '不要把它当空白页继续：这里没有可读出的正文，也没有可点的元素。'
          '请如实告诉用户这一页打不开，或换一个来源。'
      : 'The main document of this page failed to load: $reason\n'
          'Do not treat it as a blank page and keep answering: there is neither '
          'text nor clickable content here. Tell the user the page could not be '
          'loaded, or use another source.';

  // ===== JS 派发 =====

  static WebActKind? _actKind(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'click':
        return WebActKind.click;
      case 'input':
        return WebActKind.input;
      case 'clear':
        return WebActKind.clear;
      default:
        return null;
    }
  }

  /// 拼一段**只碰一个元素**的 JS。
  ///
  /// 三条红线（研究文档 §4.3）：
  ///  · 密码框在这里**再拒一次**（Dart 侧那道是主闸，这一道防的是快照过期之后元素
  ///    类型已经变了——两道不是重复，是下界/上界，与刀一的双道剥离同思路）；
  ///  · 含密码框的表单，`type=submit` 那一下不代点（转人工）；
  ///  · `blob:` / `data:` 链接不自动触发下载。
  /// 值一律走 `jsonEncode` 成 JSON 字面量再替换进模板，**不做字符串拼接注入**
  /// （模型给的 value 里带引号/换行是常态，拼进 JS 就是一个脚本注入面）。
  @visibleForTesting
  static String actScript({
    required int idx,
    required WebActKind kind,
    required String value,
  }) {
    const template = r'''
(function () {
  var IDX = __NXI__;
  var KIND = __NXK__;
  var VALUE = __NXV__;
  var el = document.querySelector('[data-nx-idx="' + IDX + '"]');
  if (!el) return 'nf';
  var type = (el.getAttribute('type') || '').toLowerCase();
  if (type === 'password') return 'pw';
  if (el.tagName === 'A') {
    var href = (el.getAttribute('href') || '').toLowerCase();
    if (href.indexOf('blob:') === 0 || href.indexOf('data:') === 0) return 'dl';
  }
  var form = el.form || el.closest('form');
  if (form && form.querySelector('input[type=password]') &&
      (el.type === 'submit' || (el.getAttribute('type') || '') === 'submit')) {
    return 'pw';
  }
  if (KIND === 'input') {
    el.focus();
    el.value = VALUE;
    el.dispatchEvent(new Event('input', {bubbles: true}));
    el.dispatchEvent(new Event('change', {bubbles: true}));
    return 'ok';
  }
  if (KIND === 'clear') {
    el.value = '';
    el.dispatchEvent(new Event('input', {bubbles: true}));
    return 'ok';
  }
  el.click();
  return 'ok';
})()''';
    return template
        .replaceAll('__NXI__', '$idx')
        .replaceAll('__NXK__', jsonEncode(kind.name))
        .replaceAll('__NXV__', jsonEncode(value));
  }

  String _actScript({
    required int idx,
    required WebActKind kind,
    required String value,
  }) =>
      actScript(idx: idx, kind: kind, value: value);
}
