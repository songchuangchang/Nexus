import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/browser_session.dart';
import '../services/logger_service.dart';
import '../utils/web_session_state.dart';

/// build180（刀二）：内置浏览器全屏页——**AI 与用户共用同一个 WebView**。
///
/// ## 为什么是新建页面而不是演进 `HtmlPreviewScreen`
/// 施工单 §四写死了不能演进：那一页的构造器吃 html 不吃 URL、导航闸是**单向闩锁**
/// （第一帧之后一律 prevent）、大半篇幅是落盘逻辑。浏览器要的正好相反：
/// 持续导航、由 URL 打开、把 controller 交给会话层。可抄的只有**判据层**——
/// 本页的错误可见性照抄它 `:426 truncationMarkPresent` / `:438 htmlPreviewIssueNotice`
/// 那两条口径（失败要数得出来、要说人话、画在页面**下面**而不是盖在上面）。
///
/// ## 这一页在架构里的位置
///  · 它是 WebView 的**拥有者**：initState 建 controller 并 `bindController` 交给
///    [BrowserSession]，dispose 里 `unbindController`（研究文档 §九.2：WebView
///    常驻 100~200MB，用完即释放，绝不让它在聊天页常驻）；
///  · 它是**判据的执行端而不是定义端**：接管/交还全部调 `webHandToHuman` /
///    `webResumeAiControl`（住 `utils/web_session_state.dart`，刀一交付），
///    本页不另写一份状态机；
///  · 它是**用户随时能夺回控制权的证据**：控制条三枚按钮常驻，
///    AI 动的每一步都在页面上看得见（研究文档 §五.1）。
///
/// ## 刻意不做
///  · 不加动画、不加进度条组件（本仓硬约束：不确定态的 `LinearProgressIndicator`
///    自己在动）——进度只决定下面那一行**写什么**；
///  · 不做截图、不做多标签、不做前进/后退的历史列表（P2 另批，施工单 §八）。
class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key});

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  static final LoggerService _log = LoggerService.instance;

  /// 日志 tag：与 `HtmlPreview` 同一条取证口径（grep 它就能还原这一页发生了什么）。
  static const String _logTag = 'BrowserScreen';

  late final WebViewController _controller;
  final BrowserSession _session = BrowserSession.instance;

  String _url = '';
  String _title = '';
  int _progress = 0;
  bool _finished = false;

  /// 没能加载的资源条数（同一坏地址重复报时并条，照抄预览页的做法）。
  int _failedResources = 0;
  String? _lastFailure;
  String? _lastFailureKey;
  bool _mainFrameFailed = false;
  bool _noticeDismissed = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _onNavigationRequest,
          onProgress: _onProgress,
          onPageStarted: _onPageStarted,
          onPageFinished: _onPageFinished,
          onWebResourceError: _onWebResourceError,
        ),
      );
    // 绑定会话层：AI 的四个动作从这一刻起才有可作用的实例。
    _session.bindController(_controller);
    // 域名确认弹窗只有页面这一侧有 BuildContext，所以把确认器交给会话层。
    _session.domainConfirmer = _askDomain;
    // 会话层是 `ChangeNotifier`，控制条必须**订阅**它，不能只在自家回调里读一次
    // （第七轮·入口面第 7 条：过去 `addListener` 全文 0 处）。会动 `_control` 而不产生
    // 任何页面事件的有两条路——`web_read` 成功（把 `awaitingPageRead` 翻回 false）与
    // `web_act` 的 input/clear（翻成 true），本页当时都不重建 ⇒ 屏幕上那行
    // 「AI 控制中，需要先读页面」要等到下一次 `onPageStarted` 才纠正，
    // 而本层文件头承诺的「AI 动的每一步都在页面上看得见」正好差了一步。
    _session.addListener(_onSessionChanged);
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    // 顺序要紧：先摘自己的监听，再释放会话（`unbindController` 里会 notifyListeners，
    // 那时本 State 已经不该再碰 setState）。
    _session.removeListener(_onSessionChanged);
    _session.unbindController();
    super.dispose();
  }

  /// 用户/页面发起的导航也过**同一道**同步闸（https-only + SSRF，判据住刀一）。
  ///
  /// 这里用同步那一条而不是 DNS 那条：`onNavigationRequest` 必须同步返回决策，
  /// 异步解析来不及；语法层已经是 fail-closed（认不出/内网/非 https 一律拒），
  /// DNS 层留给 AI 的 `web_navigate` 走全量闸。
  NavigationDecision _onNavigationRequest(NavigationRequest request) {
    final blocked = webNavigateSyntaxRejection(request.url);
    if (blocked != null) {
      // 日志只记收敛后的地址（`_logUrl` 那一头的注释写了为什么）：拒因原文里带着
      // 完整地址（判据层那句「地址无法解析或缺少 scheme（内置浏览器只走 https）：…」），
      // 所以它不进日志。回灌给模型的那一份照旧是原文——那是模型自己给的地址，
      // 屏幕上的 `_lastFailure` 也照旧是原文，那两处都不是泄漏面。
      final target = request.url;
      _log.warn('内置浏览器拦下这条导航：${_logUrl(target)}', tag: _logTag);
      _lastFailure = target;
      _failedResources++;
      if (mounted) setState(() {});
      return NavigationDecision.prevent;
    }
    return NavigationDecision.navigate;
  }

  void _onProgress(int progress) {
    if (progress == _progress) return;
    _progress = progress;
    if (mounted) setState(() {});
  }

  void _onPageStarted(String url) {
    _finished = false;
    // 新的一页＝这一页的失败账要从零开始（第五轮浏览器扫描第 4 条）：
    // 这四个旗标过去**全文没有一处复位**，所以一次主帧失败之后，在同一页导航到任何好站，
    // 屏幕上那条警示会一直挂着——对用户谎称「这一页是空的」，而会话层每次导航都清自己那份
    // （`_mainFrameFailure`），两份真源就此打架。
    _mainFrameFailed = false;
    _failedResources = 0;
    _lastFailureKey = null;
    _lastFailure = null;
    _noticeDismissed = false;
    // 同一次导航里「这一页走到哪了／这一页叫什么」也必须归零（第七轮·入口面第 8 条，
    // 上面那五个旗标的同族成员）：`_progress` 只在 `onPageFinished` 里被写成 100，
    // 不清 ⇒ 长连接那一形（SSE／长轮询：`onPageFinished` 到了但页面一直在动，或主帧
    // 永远不报完成）屏幕上就常驻「正在加载… 100%」这句自相矛盾的话；
    // `_title` 只在 `onPageFinished` 之后回读 ⇒ 加载期间标题栏挂着**上一页**的名字，
    // 而下面那行地址已经是新页，用户据此判断"AI 这一跳去了哪儿"会读错。
    _progress = 0;
    _title = '';
    _session.onPageStarted(url);
    if (mounted) {
      setState(() {
        _url = url;
      });
    }
  }

  void _onPageFinished(String url) {
    _finished = true;
    _progress = 100;
    _session.onPageFinished(url);
    _readBackPageFacts();
    if (mounted) {
      setState(() {
        if (url.trim().isNotEmpty) _url = url;
      });
    }
  }

  /// 标题与地址异步读回来（`onPageFinished` 是同步回调，所以单独一跳）。
  void _readBackPageFacts() {
    _controller.getTitle().then((t) {
      if (mounted) setState(() => _title = t ?? '');
    }).catchError((Object e) {
      _log.warn('读取页面标题失败：$e', tag: _logTag);
    });
    _controller.currentUrl().then((u) {
      if (mounted && (u ?? '').isNotEmpty) setState(() => _url = u!);
    }).catchError((Object e) {
      _log.warn('读取当前地址失败：$e', tag: _logTag);
    });
  }

  void _onWebResourceError(WebResourceError error) {
    final url = error.url ?? '';
    final main = error.isForMainFrame == true;
    final key = '${error.errorCode}|$url';
    final reason = 'code=${error.errorCode} ${error.description}';
    _log.warn(
        '内置浏览器资源加载失败：code=${error.errorCode} 主帧=$main '
        '${error.description}${url.isEmpty ? '' : ' url=${_logUrl(url)}'}',
        tag: _logTag);
    if (main) {
      _mainFrameFailed = true;
      // 会话层也要知道这一条：只有 started/finished 两个入口的它会把主帧失败塌成
      // 「已打开页面」＋0 块正文（缺陷三）。这一句排在下面那条去重 **之前**——
      // 屏幕侧「同一坏地址连报只算一条」是为了让计数可信，
      // 而会话层那条标志位每次导航都清零，第二次、第三次失败都得重新递进去。
      _session.onMainFrameFailed(reason);
    }
    if (key == _lastFailureKey) return; // 同一坏地址连报只算一条（数字才可信）
    _lastFailureKey = key;
    _lastFailure = '${error.description}${url.isEmpty ? '' : '（$url）'}';
    _failedResources++;
    if (mounted) setState(() {});
  }

  /// 域名确认弹窗（研究文档 §六.2：默认白名单为空 ⇒ 每个新域名都要问一次）。
  ///
  /// 第七轮·入口面第 1 条：这一格原来还挂着「本次会话记住」那枚 `CheckboxListTile`，
  /// 而 `remembered` 只被它自己读写——返回值 `decision` 完全由下面三枚按钮硬定，
  /// 勾与不勾**一个字节都不影响结果**：用户勾上「记住」再按「只允许这一次」＝没记住，
  /// 不勾按「允许并记住」＝记住了。授权面上的认知与实际反向，比少一个功能更糟。
  /// 三枚按钮本身已经把这三种答案表达完了（不允许／只这一次／允许并记住），
  /// 所以删掉那枚死控件，而不是"让它生效"——让它生效要再造一个第四种状态
  /// （"勾了但只这一次"），那是把同一件事说两遍。
  /// 下面那句"本次会话"的作用域现在是真的：`unbindController` 会收回名单
  /// （`webForgetConfirmedDomains`，第七轮·入口面第 2 条）。
  Future<WebDomainDecision> _askDomain(String host) async {
    if (!mounted) return WebDomainDecision.deny;
    final isZh = _isZh(context);
    final decision = await showDialog<WebDomainDecision>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(isZh ? '允许访问这个网站？' : 'Allow this site?'),
        content: Text(isZh
            ? 'AI 想打开：$host\n「允许并记住」只在这一个浏览器页打开期间有效，关掉页面就收回。'
            : 'The assistant wants to open: $host\n'
                '"Allow & remember" lasts only while this browser page is open.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, WebDomainDecision.deny),
            child: Text(isZh ? '不允许' : 'Deny'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(dialogContext, WebDomainDecision.allowOnce),
            child: Text(isZh ? '只允许这一次' : 'Allow once'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, WebDomainDecision.remember),
            child: Text(isZh ? '允许并记住' : 'Allow & remember'),
          ),
        ],
      ),
    );
    return decision ?? WebDomainDecision.deny;
  }

  bool _isZh(BuildContext context) =>
      Localizations.localeOf(context).languageCode == 'zh';

  /// 页面上那一条**看得见**的说明（null = 没问题可说，整条不渲染）。
  ///
  /// 顺序照抄预览页：主帧失败 > 资源失败 > 还在加载。这一页没有「截断」那一档——
  /// 截断发生在回灌给模型的那份正文里（`web_dom_serializer` 的标注），
  /// 屏幕上看到的是完整页面，把两件事混成一谈反而误导。
  String? _issueLine(bool isZh) {
    final parts = <String>[];
    if (_mainFrameFailed) {
      parts.add(isZh ? '页面主体没能加载，所以这一页是空的' : 'The page itself failed to load');
    } else if (_failedResources > 0) {
      parts.add(isZh
          ? '这一页有 $_failedResources 项资源没能加载'
          : '$_failedResources resource(s) failed to load');
    }
    if (_lastFailure != null && _lastFailure!.trim().isNotEmpty) {
      parts.add('${isZh ? '最近一条' : 'last'}: ${_lastFailure!.trim()}');
    }
    if (parts.isEmpty && !_finished) {
      parts.add(isZh ? '正在加载… $_progress%' : 'Loading… $_progress%');
    }
    if (parts.isEmpty) return null;
    return parts.join(isZh ? '；' : '; ');
  }

  @override
  Widget build(BuildContext context) {
    final isZh = _isZh(context);
    final cs = Theme.of(context).colorScheme;
    final issue = _noticeDismissed ? null : _issueLine(isZh);
    final controlLabel = webControlLabel(_session.control, zh: isZh);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _title.isNotEmpty
              ? _title
              : (isZh ? '内置浏览器' : 'Built-in browser'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: Column(
        children: [
          _addressLine(cs, isZh),
          Expanded(child: WebViewWidget(controller: _controller)),
          if (issue != null) _issueBar(cs, issue, isZh),
          _controlBar(isZh, controlLabel),
        ],
      ),
    );
  }

  /// 地址只读显示（§五.1：控制条「外加当前 URL 只读显示」）。
  Widget _addressLine(ColorScheme cs, bool isZh) {
    return Container(
      width: double.infinity,
      color: cs.surfaceContainerHighest,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Text(
        _url.isEmpty ? (isZh ? '还没有打开任何页面' : 'No page open yet') : _url,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: cs.onSurfaceVariant),
      ),
    );
  }

  Widget _issueBar(ColorScheme cs, String issue, bool isZh) {
    return Container(
      width: double.infinity,
      color: cs.surfaceContainerHighest,
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              issue,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: cs.onSurface),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            tooltip: isZh ? '收起提示' : 'Dismiss',
            onPressed: () => setState(() => _noticeDismissed = true),
          ),
        ],
      ),
    );
  }

  /// 控制条：`让我来 / 继续 AI / 结束`（研究文档 §五.1 的三枚按钮）。
  ///
  /// 「让我来」不是禁用触摸——真平台视图下用户的触摸**任何时刻都不曾被夺走**
  /// （§五.2），这一枚改的是 AI 那一侧的行为：停手 + 回灌一句等待。
  Widget _controlBar(bool isZh, String controlLabel) {
    final paused = _session.control.aiControlPaused;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  controlLabel,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: TextButton.icon(
                    onPressed: paused
                        ? null
                        : () => setState(() => _session.handToHuman()),
                    icon: const Icon(Icons.pan_tool_outlined, size: 18),
                    label: Text(isZh ? '让我来' : "I'll take over"),
                  ),
                ),
                Expanded(
                  child: TextButton.icon(
                    // 「继续 AI」在 AI 的导航窗口开着时**先按不住**（第七轮·会话面第 2 条）：
                    // 这两个入口过去只改 `_control` 那一位，一条都不碰 `_aiNavInFlight`，
                    // 于是"用户在窗口开着的时候点了自己那条链接"这一形里，那次导航
                    // 落进 `_aiNavInFlight != 0` 里被记到 AI 名下，窗口收掉之后回灌的却是
                    // 「已打开页面：用户刚点进去的那一页」⇒ AI 接着在用户正操作的页面上动手。
                    // 彻底解法是给状态层记「最近一次人工派发」的时间戳（已登 182·#145），
                    // 这一格先给页面一个不会说谎的闸门：窗口开着就别交还。
                    // 上面那枚「让我来」**照旧随时能按**——紧急停手的路不许为了修一个洞
                    // 再堵上另一条（那是把一种风险换成更坏的一种）。
                    onPressed: paused && !_session.aiNavWindowOpen
                        ? () => setState(() => _session.resumeAiControl())
                        : null,
                    icon: const Icon(Icons.play_arrow_outlined, size: 18),
                    label: Text(isZh ? '继续 AI' : 'Hand back to AI'),
                  ),
                ),
                Expanded(
                  child: TextButton.icon(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, size: 18),
                    label: Text(isZh ? '结束' : 'Close'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 日志专用的地址收敛：**协议＋主机＋路径**，query 与 fragment 一律丢掉。
///
/// 为什么要收敛（这是本仓唯一一句关于日志里地址的口径）：这一页的日志会落盘到
/// `app_logs/`，而 App 自己有 `log_query` 工具能把日志**读回模型**——query 里常带着
/// token／会话 id／手机号（搜索词、`?key=` 的分享链接、带签名参数的图片地址）。
/// `browser_session.dart` 与 `web_browser_plugins.dart` 的文件头都承诺过
/// 「页面正文、元素文字、URL 一个字都不进日志」，这一条就是那句话说出口的唯一兑现点。
///
/// 只管日志字符串：回灌给模型的工具结果正文不动（那个地址是模型自己报出来的，
/// 它当然知道），屏幕上显示的 `_lastFailure` 也不动（那是给人看的，不落盘、不进上下文）。
///
/// 解不出主机名（`about:blank`、`data:`、畸形串）时只给协议，不给尾巴——
/// 宁可少给一行有用的日志，也不能多给一条带 token 的。
String _logUrl(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null) return '（地址无法解析）';
  final scheme = uri.scheme.isEmpty ? '?' : uri.scheme;
  // userInfo 与 port 一起排在外面：`https://user:pass@host` 里那一段正是最容易是凭据的。
  final host = uri.host;
  if (host.isEmpty) return scheme;
  final path = uri.path;
  return '$scheme://$host${path.isEmpty ? '' : path}';
}

/// 接管状态的一句话（**判据住刀一**，这里只是把三态翻成人话）。
///
/// 为什么在本页而不是 `web_session_state.dart`：那一层是纯函数层，不许出现
/// 用户可见文案；这一层的文案又只有这一处调用点（控制条），放页面里读得到。
String webControlLabel(WebControlState state, {required bool zh}) {
  if (state.aiControlPaused) {
    return zh ? '用户正在操作页面，AI 已停手' : 'The user is driving; AI is paused';
  }
  if (webMustReRead(state)) {
    return zh ? 'AI 控制中，需要先读页面' : 'AI drives, needs a page read';
  }
  return zh ? 'AI 控制中' : 'AI in control';
}
