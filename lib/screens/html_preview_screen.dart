import 'dart:io';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../l10n/app_localizations.dart';
import '../services/logger_service.dart';
import '../services/workspace_service.dart';
// build167：这里**不再 import** `app_container_transform.dart` ——
// 本页不参与容器转场（165 接过一版，机主 19:02 报闪屏，见文件头）。
import '../utils/app_snackbar.dart';

/// build162：模型产出的 HTML 在 App 内预览（本仓第一个 WebView）。
///
/// 为什么"以前做过"却仍然预览不了：build138 那条「预览」是
/// **交给系统浏览器**（`WorkspaceService.openExternal`），手机上没装能渲染 html 的
/// 应用时它自动回落到分享面板 —— 也就是说全仓从来没有 WebView，用户点了等于没预览。
/// 本轮把 `webview_flutter` 引进来，那条能力不作废，降级成本页的「用浏览器打开」。
///
/// 安全模型（内容来自模型输出，一律按不可信输入处理）：
///  · [WebViewController.loadHtmlString] **不给 baseUrl**：给了就等于允许页面按那个
///    基址回头读同源资源，本地路径/工作区文件不该是模型产出的内容能达到的面；
///  · **只放行第一帧导航**，其余导航/新窗口一律拦掉并留日志（见 [_onNavigationRequest]）；
///  · JS 是开的 —— 模型常产出带 chart/mermaid 的页面，禁 JS 等于白屏；
///    开了 JS 的代价就是上面那道导航闸门必须守住。
///
/// build164（#83）补的**错误可见性**（真机取证：整份导出里 `HtmlPreview` 这个 tag
/// 0 命中，白屏时页面上一个字都没有、日志里也没有一行）：
///  · `onWebResourceError` 逐项写日志（tag 仍是 `HtmlPreview`，保持可 grep）
///    并在页面上落一行**看得见**的人话 —— 上面那条「不给 baseUrl ⇒ 落 `about:blank`」
///    是**有意**的安全选择，它的代价就是带 CDN / ESM / 相对路径的页面会静默失败；
///    安全模型一个字不动，但代价必须说出来，不能让用户对着白页猜；
///  · 内容被截断时（`WorkspaceService.readText` 那条通道会带截断标注）在页内写明
///    「这是截断后的内容」，不让人以为文件本来就这样；
///  · `onProgress` / `onPageFinished` 只用来决定那一行**写什么**，不驱动任何转场。
///
/// 刻意不做的事：本页自己不动画（进度/错误都只是**静态文本条**，不加动画、
/// 不加进度条组件），**也不接受外面套进来的容器转场**。
/// 后者在 build165（#89）试过一版：产物卡片入口把整块 body 交给 `AppContainerHero`
/// 当"落位端"。机主 26 日 19:02 报「会闪屏，不到一秒就好」并附截图 —— 那个 shuttle
/// 的形状是"正文留在原位、容器从它上面盖过去"，而本页主体是**平台视图 WebView**、
/// 进页第一帧就把内容画出来了 ⇒ 那 450ms 里是一块**近黑的不透明容器**在长大，
/// 盖在已经看得见的表格上面。build167 撤掉这条接线（取证见
/// `docs/BUGSCAN_build166_20260926.md` ④）；本页从此**不参与任何飞行**，
/// 有一条源码契约闸钉着（`test/build165_motion_tokens_test.dart` 的 ⑥ 组）。
class HtmlPreviewScreen extends StatefulWidget {
  const HtmlPreviewScreen({
    super.key,
    required this.html,
    this.fileName,
    this.workspaceRel,
    this.truncated = false,
  });

  /// 要渲染的 HTML 正文（单一真源：WebView 吃它，「用浏览器打开 / 分享」也落它）。
  final String html;

  /// AppBar 标题（文件名）；为空时显示「HTML 预览」。
  final String? fileName;

  /// 内容本来就是工作区里某个文件时把相对路径带进来 —— 导出那一跳不再落一份副本。
  final String? workspaceRel;

  /// build164：内容是不是**截断后的**那一份（`WorkspaceService.readText` 有 30000 字符
  /// 回灌上限）。传 true 时页内会写明这件事。默认 false = 调用方没报截断，
  /// 但 [_truncationMarkPresent] 仍会认正文尾部那句既有标注（两条入口口径一致，
  /// 不因某个调用点没传就漏提示）。
  final bool truncated;

  @override
  State<HtmlPreviewScreen> createState() => _HtmlPreviewScreenState();
}

class _HtmlPreviewScreenState extends State<HtmlPreviewScreen> {
  static final LoggerService _log = LoggerService.instance;

  /// 日志 tag：build162 起就是 `HtmlPreview`，真机取证靠 grep 它。
  /// 这次新增的每一行失败也必须落在这个 tag 上（改成别的名字 = 那条"0 命中"的
  /// 取证方法立刻失效），所以把它收成一个常量而不是各处写字面量。
  static const String _logTag = 'HtmlPreview';

  late final WebViewController _controller;

  /// 第一帧是否已经放行。它同时是「拦下第 2 帧」那条日志的开关键。
  bool _firstFrameSeen = false;

  // ===== build164（#83）：错误可见性的四个状态 =====
  // 这四个变量**只**用来决定页面上那一行人话写什么，不驱动任何转场/动画。
  /// 没能加载的资源条数（同一坏地址重复报时并条，见 [_onWebResourceError]）。
  int _failedResources = 0;
  /// 最近一条失败的人话摘要（进那一行文案）。
  String? _lastFailure;
  /// 上一条失败的**去重键**（`code|url`）——只用于并条，不参与文案。
  String? _lastFailureKey;
  /// 主帧是否失败 —— 主帧失败＝整页必然空白，与"少一张图"是两件事，文案要分开。
  bool _mainFrameFailed = false;
  /// 加载进度（0~100）；`onPageFinished` 之后为 100。
  int _progress = 0;
  /// 那一行被用户手动收掉（收掉不等于没问题，所以日志照写）。
  bool _noticeDismissed = false;

  /// 已经落进工作区的相对路径。缓存它是为了：一次页面会话最多写一份文件，
  /// 否则用户多点两下「分享」就往工作区堆三个副本。
  String? _writtenRel;

  /// 重名追加到第几档（`-1`、`-2`…），封顶 [_maxNameTries] 次后如实报错。
  static const int _maxNameTries = 30;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _onNavigationRequest,
          // build164（#83）：这三条是"错误可见性"的最小集。
          // 为什么必须挂 onWebResourceError：`loadHtmlString` 有意不给基址
          // （落 `about:blank`），于是页面里的 CDN 脚本 / ESM import / 相对路径资源
          // **全部**按跨源或坏 URL 失败，而失败本身此前一处都不落字 ——
          // 用户看到的就是一片白，日志里也一片空白（真机 `HtmlPreview` 0 命中）。
          onWebResourceError: _onWebResourceError,
          onProgress: _onProgress,
          onPageFinished: _onPageFinished,
        ),
      )
      // 不传 baseUrl：见类注释的安全模型。Android 侧 loadHtmlString 落在
      // `about:blank` 上，第一帧因此也是它，之后的任何跳转都不是用户要的。
      ..loadHtmlString(widget.html);
  }

  /// 导航闸门：**只放行第一帧**，其余一律拦掉并写一行日志。
  ///
  /// 为什么：内容来自模型输出。第一帧就是 [WebViewController.loadHtmlString]
  /// 自己那一次，是用户点开这页真正要看的东西；之后的「点链接跳外站」
  /// 「脚本里 `location = 'file:///…'` 试本地路径」「`target=_blank` 新窗口被
  /// Android WebView 折叠成一次主帧导航」都不是用户在这页上想做的事 ——
  /// 放出去等于把 App 变成一个没有地址栏、没有回头键的浏览器。
  NavigationDecision _onNavigationRequest(NavigationRequest request) {
    if (!_firstFrameSeen) {
      _firstFrameSeen = true;
      return NavigationDecision.navigate;
    }
    _log.warn('HTML 预览拦下第 2 帧导航：${request.url}', tag: _logTag);
    return NavigationDecision.prevent;
  }

  /// 一条资源加载失败：① 写日志（tag 仍是 `HtmlPreview`，保持可 grep）
  /// ② 让页面上那一行人话把它数出来。绝不许静默。
  void _onWebResourceError(WebResourceError error) {
    final url = error.url ?? '';
    final main = error.isForMainFrame == true;
    // 同一个坏地址会一次报多条（带 `crossorigin` / 重试的页面尤其明显），
    // 连报会把真正有用的数字（条数）淹掉 ⇒ 同键只并一次。
    final key = '${error.errorCode}|$url';
    _log.warn(
        'HTML 预览资源加载失败：code=${error.errorCode} 主帧=$main '
        '${error.description}${url.isEmpty ? '' : ' url=$url'}',
        tag: _logTag);
    if (key == _lastFailureKey) {
      _log.warn('HTML 预览同一资源重复报错（已并条，不计入条数）：$key',
          tag: _logTag);
      if (main) _mainFrameFailed = true;
      return;
    }
    _lastFailureKey = key;
    _lastFailure = '${error.description}${url.isEmpty ? '' : '（$url）'}';
    _failedResources++;
    if (main) _mainFrameFailed = true;
    if (mounted) setState(() {});
  }

  void _onProgress(int progress) {
    if (progress == _progress) return;
    _progress = progress;
    // 进度只喂那一行文案，不加进度条组件（本仓硬约束：不许新增动画——
    // 不确定态的 LinearProgressIndicator 自己就在动）。
    if (mounted) setState(() {});
  }

  void _onPageFinished(String url) {
    _progress = 100;
    _log.info(
        'HTML 预览加载结束：失败资源 $_failedResources 项，主帧失败=$_mainFrameFailed'
        '${url.isEmpty ? '' : ' url=$url'}',
        tag: _logTag);
    if (mounted) setState(() {});
  }

  /// 页面上那一条**看得见**的说明（null = 没问题可说，整条不渲染）。
  ///
  /// 为什么画在 WebView **下面**而不是盖在上面：这一页的主体是页面本身，
  /// 遮一层就挡住了用户要核对的内容；也避免"提示条自己变成又一个要关的弹窗"。
  String? _issueLine(bool zh) {
    return htmlPreviewIssueNotice(
      zh: zh,
      failedResources: _failedResources,
      mainFrameFailed: _mainFrameFailed,
      truncated: widget.truncated || truncationMarkPresent(widget.html),
      finished: _progress >= 100,
      progress: _progress,
      failure: _lastFailure,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    final name = widget.fileName?.trim();
    final issue = _noticeDismissed ? null : _issueLine(isZh);
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          (name == null || name.isEmpty)
              ? (isZh ? 'HTML 预览' : 'HTML preview')
              : name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.open_in_new),
            tooltip: isZh ? '用浏览器打开' : 'Open in browser',
            onPressed: _openInBrowser,
          ),
          IconButton(
            icon: const Icon(Icons.ios_share),
            tooltip: isZh ? '分享' : 'Share',
            onPressed: _share,
          ),
        ],
      ),
      // build164（#83）：body 从"光一块 WebView"改成 Column —— 白屏时下面那一行
      // 是用户唯一看得见的信息。没有可说的（加载完、零失败、没截断）时
      // `_issueLine` 返回 null ⇒ 仍然只有一块 WebView，形状与改前逐像素一致。
      // build167：这里**不再有任何 hero 包法**（165 那版会把近黑容器盖在已画好的
      // 内容上 450ms，机主报"闪屏"；见文件头与 BUGSCAN ④）。
      body: _pageBody(context, cs, issue, isZh),
    );
  }

  /// 页面本体（WebView + 可选的一行说明）。
  /// build167 起它是本页**唯一**的画法（#89 那两种包法之一已撤）；
  /// 抽成方法保留着，是为了让"body 只有一棵子树"这件事在结构上一眼可见。
  Widget _pageBody(
      BuildContext context, ColorScheme cs, String? issue, bool isZh) {
    return Column(
      children: [
        Expanded(child: WebViewWidget(controller: _controller)),
        if (issue != null)
          Container(
            width: double.infinity,
            color: cs.surfaceContainerHighest,
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    issue,
                    // 3 行封顶：这一条是**说明**不是日志窗口，整页的错误原文在
                    // 日志里（tag `HtmlPreview`），这里只给人一眼能读完的那一句。
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
          ),
      ],
    );
  }

  /// 用浏览器打开 = 落成工作区文件后走 [WorkspaceService.openExternal]。
  ///
  /// 不自己调 open_filex：那条既有通道 ① 先过沙箱路径校验，② 在"本机没有能打开
  /// 这个类型的应用"时自动回退分享面板并把回退这件事如实回报（build138 G63 契约）。
  Future<void> _openInBrowser() async {
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    final (rel, merr) = await _materialize();
    if (rel == null) {
      _show(isZh ? '无法交给浏览器：$merr' : 'Cannot open in browser: $merr');
      return;
    }
    try {
      final (err, fellBackToShare) = await WorkspaceService.openExternal(rel);
      if (!mounted) return;
      if (err != null) {
        _show(isZh ? '交给浏览器失败：$err' : 'Browser open failed: $err');
        return;
      }
      if (fellBackToShare) {
        _show(isZh
            ? '本机没有能直接打开它的应用，已改为分享面板'
            : 'No app can open it directly — showed the share sheet instead');
      }
    } catch (e) {
      // 平台通道抛异常（无 Activity/权限）也要说清楚，不许点一下没反应
      _show(isZh ? '交给浏览器失败：无法调起系统应用（$e）' : 'Browser open failed: $e');
    }
  }

  /// 分享 = 走 [WorkspaceService.share]（share_plus 那条既有通道）。
  Future<void> _share() async {
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    final (rel, merr) = await _materialize();
    if (rel == null) {
      _show(isZh ? '无法分享：$merr' : 'Cannot share: $merr');
      return;
    }
    try {
      final err = await WorkspaceService.share(rel);
      if (err != null) {
        _show(isZh ? '分享失败：$err' : 'Share failed: $err');
      }
    } catch (e) {
      // 部分 ROM 没有分享目标会抛异常，这里兜住，不让它冒到框架
      _show(isZh ? '分享失败：$e' : 'Share failed: $e');
    }
  }

  /// 把预览内容落成工作区里的一个 `.html`，返回（相对路径, 错误）。
  ///
  /// 只走 [WorkspaceService.writeText] 这一条既有通道（路径校验、体积限额、
  /// 原子写都在它里面），不自己 `File.writeAsString` —— 那等于给模型产出的内容
  /// 开一条不受沙箱约束的写盘路径。
  /// 内容本来就来自工作区文件（[HtmlPreviewScreen.workspaceRel]）时直接用它。
  Future<(String?, String?)> _materialize() async {
    final rel = widget.workspaceRel;
    if (rel != null) return (rel, null);
    final cached = _writtenRel;
    if (cached != null) return (cached, null);

    final base = _workspaceName();
    var name = base;
    var free = false;
    for (var i = 1; i <= _maxNameTries; i++) {
      final (abs, rerr) = await WorkspaceService.resolve(name);
      if (rerr != null) return (null, rerr);
      if (abs == null) return (null, '工作区路径解析失败');
      if (!File(abs).existsSync()) {
        free = true;
        break;
      }
      // 重名追加 `-1`、`-2`。**不照抄**工作区里 downloadFromUrl 那套 `(1)` 后缀：
      // 括号过不了 [WorkspaceService.isValidSegment] 的段名白名单，
      // 抄过来会得到一个永远写不进去的文件名。
      final dot = base.lastIndexOf('.');
      name = dot <= 0
          ? '$base-$i'
          : '${base.substring(0, dot)}-$i${base.substring(dot)}';
    }
    if (!free) {
      return (null, '工作区重名过多（已试 $_maxNameTries 档）');
    }
    final (abs, werr) = await WorkspaceService.writeText(name, widget.html);
    if (abs == null) return (null, werr ?? '写入工作区失败');
    _writtenRel = name;
    return (name, null);
  }

  /// 落盘用的段名：优先用来源文件名，没有就用固定名。
  String _workspaceName() {
    final raw = (widget.fileName?.trim().isNotEmpty ?? false)
        ? widget.fileName!.trim()
        : 'nexus_html_preview.html';
    final base = raw.split(RegExp(r'[/\\]')).last;
    final cleaned = String.fromCharCodes(base.runes.map(_keepForWorkspace));
    final stem = cleaned.trim().isEmpty ? 'nexus_html_preview' : cleaned.trim();
    final lower = stem.toLowerCase();
    final withExt = (lower.endsWith('.html') || lower.endsWith('.htm'))
        ? stem
        : '$stem.html';
    // 段名白名单上限 120，留足重名追加 `-29` 的余量
    return withExt.length <= 110 ? withExt : withExt.substring(0, 110);
  }

  /// 清洗到工作区段名白名单内（[WorkspaceService.isValidSegment] 只收
  /// 中英文/数字/下划线/中划线/点/空格）。标题里什么都有（emoji、括号、斜杠），
  /// 不清洗的话 writeText 报回来的是「文件名不合法」这种没人看得懂的错。
  static int _keepForWorkspace(int u) {
    final ok = (u >= 0x41 && u <= 0x5a) || // A-Z
        (u >= 0x61 && u <= 0x7a) || // a-z
        (u >= 0x30 && u <= 0x39) || // 0-9
        u == 0x5f || // _
        u == 0x2e || // .
        u == 0x2d || // -
        u == 0x20 || // 空格
        (u >= 0x4e00 && u <= 0x9fff); // CJK 基本区
    return ok ? u : 0x5f;
  }

  void _show(String msg) {
    if (!mounted) return;
    AppSnackBar.showSnackBar(
      context,
      SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 5),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

/// [WorkspaceService.readText] 截断时写进正文尾巴的那句标注的**指纹**
/// （出处：workspace_service.dart 里拼的 `…[已截断，全文 N 字符]`）。
const String _truncationMark = '[已截断，全文';

/// 正文里是否已经带着那条截断标注。
///
/// 为什么要有这一支而不是只信调用点传的 `truncated`：文件管理页那条入口
/// （`file_management_screen.dart::_previewHtmlWorkspaceFile`）**已经**在用同一把尺子量内容，
/// 但它在 build164 是禁区文件、传不出这个 bool。标注本身就在内容里 ⇒
/// 页面上这一行必须照样出现，不能因为"调用点没传"就漏掉（静默降级按缺陷处理）。
bool truncationMarkPresent(String content) => content.contains(_truncationMark);

/// 预览页底部那一行**看得见的人话**（纯函数，可脱 WebView 单测）。
///
/// 为什么抽成函数：真 WebView 在 flutter_test 里构造不出来（口径见
/// `test/build162_html_preview_test.dart` 文件头），"白屏时页面上有没有字"这件事
/// 只能在这一层被测到 —— 渲染层因此只剩"把这段文字画出来"一件没有判断的事。
///
/// 返回 null = 没有可说的（加载完成、零失败、没截断）⇒ 调用点整条不渲染。
/// 顺序是有意的：**主帧失败 > 资源失败 > 还在加载 > 截断**。
/// 前两条是"为什么是白的"，最后一条是"为什么少一截"，同屏只报最要紧的那件，
/// 但都拼进同一行、用「；」连，不弹两个条。
String? htmlPreviewIssueNotice({
  required bool zh,
  required int failedResources,
  required bool mainFrameFailed,
  required bool truncated,
  required bool finished,
  required int progress,
  String? failure,
}) {
  final parts = <String>[];
  if (mainFrameFailed) {
    parts.add(zh
        ? '页面主体没能加载，所以这一页是空的'
        : 'The page itself failed to load — that is why it is blank');
  } else if (failedResources > 0) {
    parts.add(zh
        ? '页面有 $failedResources 项资源没能加载，可能是空白的原因'
        : '$failedResources resource(s) failed to load — that may be why it is blank');
  }
  if (failure != null && failure.trim().isNotEmpty) {
    // 只交最近一条原文：整串错误清单在日志里（tag `HtmlPreview`），这一行是入口不是面板
    parts.add('${zh ? '最近一条' : 'last'}: ${failure.trim()}');
  }
  if (parts.isEmpty && !finished) {
    parts.add(zh ? '正在加载… $progress%' : 'Loading… $progress%');
  }
  if (truncated) {
    // 上限数字**不写死**：它来自 WorkspaceService.readText 的 readBackLimit
    // （教训 #62：写死之后改了限额、提示还在说 30000）。
    const limit = WorkspaceService.readBackLimit;
    parts.add(zh
        ? '这是截断后的内容（工作区读取上限 $limit 字符），完整文件请用「用浏览器打开」'
        : 'This is truncated content (workspace read limit $limit chars); '
            'use "Open in browser" for the full file');
  }
  if (parts.isEmpty) return null;
  return parts.join(zh ? '；' : '; ');
}

