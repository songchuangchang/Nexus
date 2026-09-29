/// build173 内置浏览器 P0 第一刀：AI「看」页面的那一层——**纯函数 + 判据**。
///
/// 这一片不起 WebView、不做 UI（研究文档 `docs/RESEARCH_内置浏览器可行性_AI操控与人类接管_
/// 20260928.md` §八 P0 的第一刀），只交付两样东西：
///   ① [kWebDomSerializeScript]：一段一次性只读 JS，第二刀用
///      `runJavaScriptReturningResult` 注进 WebView，产出紧凑 JSON 字符串；
///   ② Dart 侧的**解析 + 剥离 + 截断**纯函数：把那段 JSON 变成可回灌的正文。
///
/// 为什么 Dart 侧还要再剥一层（JS 已经剥过了）：
///  · 这条通道进来的文本**全部来自第三方页面**，是比对话更 hostile 的注入源（研究文档 §六.1）；
///    「页面内容进模型上下文」的路上，任何一道只写在另一端的剥离都不是闸，只是约定；
///  · 更重要的是**可测**：真 WebView 在 flutter_test 里构造不出来（口径见
///    `test/build162_html_preview_test.dart` 文件头），fixture 驱动的判据层是这次唯一
///    能对这个行为做断言的地方。剥离写在 JS 里 = 这次一条都测不到。
///  所以三件套（密码值 / script-style-meta 内容 / 隐藏元素）在 JS 与 Dart **各有一道**，
///  Dart 这道是 fail-closed 的下界，JS 那道是省流量的上界。
///
/// 回灌出口不在这里：产出的是**待回灌正文**，第二刀必须整条交给
/// `builtin_plugins.dart` 的 `toolResultTag(...)`（唯一出口：转义 → 结构锁 →
/// `encoding="escaped" trust="untrusted"`）。本文件**不拼** `<toolresult>` 外壳——
/// 那正是 build173 第一刀（提交 ab91654）刚收口掉的那 7 处裸通道的同款写法。
library;

import 'dart:convert';

// ============================================================================
// 上限：只有一个数，且不是新造的
// ============================================================================

/// DOM 序列化回灌的**硬上限**（字符）。
///
/// 为什么是 12000 而不是 30000（本仓现成的另一把尺子）：
///  · `WorkspaceService.readBackLimit`（workspace_service.dart:75）= 30000，那条管的是
///    「一次读一个工作区文本文件」——**一次性、用户主动、单一正文**，且它切完就落盘在文件里，
///    随时可以再读；
///  · 浏览器这条是**每一步都发一次**：`web_read` 之后还有 `web_act`、再读、再动，
///    一轮 ReAct 里同一段页面正文会以 toolresult 的形式重复占上下文（研究文档 §八 P1
///    的多步流程「搜索→进结果页→读详情」就是三次）；
///  · 研究文档 §4.2 给这一条通道写的就是「体积上限：默认约 12k 字符（可按深度档缩放），
///    **超出只给视口附近元素**」——12k 与「视口优先」是配对设计：上限越小，
///    「只给视口附近」这件事越早发生、越有意义；把它拉到 30000 等于让视口优先变成摆设。
///  ⇒ 取 12000，并且**不在这里造第三个数**（同一口径见 §4.2 与下面的 [kWebDomTruncationMark]）。
const int kWebDomReadBackLimit = 12000;

/// 截断标注的**指纹**（研究文档 §4.2「超长截断并标注」）。
///
/// 这串是照抄现成口径的：`workspace_service.dart:258` 拼的
/// `…[已截断，全文 N 字符]`，而 `html_preview_screen.dart:426 truncationMarkPresent`
/// 认的前缀 `[已截断，全文` 就在里面。三条通道（工作区回灌 / HTML 预览页 / 浏览器回灌）
/// 共用同一句标注 ⇒ 用户与日志在任何一处看到它都是同一件事，不需要第二套判据。
/// 这条**跨文件等式**由 `test/build173_web_dom_serializer_test.dart` 钉住
/// （它直接调 `truncationMarkPresent`）——改了这里那句，那条测试立刻红。
const String kWebDomTruncationMark = '[已截断，全文';

/// 拼尾部标注（数字 = **截断前**的全文长度，与工作区那条同一语义）。
String webDomTruncationNote(int fullLength, {bool zh = true}) => zh
    ? '…$kWebDomTruncationMark $fullLength 字符]'
    : '…$kWebDomTruncationMark $fullLength chars]';

/// 正文里是否已带截断标注（与 `truncationMarkPresent` 同判据，这里给不便 import
/// 预览页的调用点用；两者由测试钉死等价）。
bool webDomTruncationMarkPresent(String content) =>
    content.contains(kWebDomTruncationMark);

// ============================================================================
// ① JS 侧：一次性只读脚本
// ============================================================================

/// 注入给 `runJavaScriptReturningResult` 的**一次性只读脚本**，返回 JSON 字符串。
///
/// 契约（Dart 侧 [parseWebDomPayload] 按这个形状解）：
/// ```json
/// {"url":"…","title":"…",
///  "viewport":{"top":0,"height":800,"scrollHeight":4000},
///  "skipped":{"hidden":3,"strippedTags":2,"passwordValues":1},
///  "blocks":[{"text":"…","tag":"p","top":120,"inViewport":true}],
///  "elements":[{"idx":1,"tag":"a","type":"","label":"…","href":"…",
///               "needsHuman":false,"inViewport":true,"top":300}]}
/// ```
/// 四条红线（都在研究文档 §六，逐条对着实现）：
///  · **不读** `document.cookie` / `localStorage` / `sessionStorage`（§六.3）——全文没有这三个词；
///  · `input[type=password]` 的**值一律不取**，只标 `needsHuman: true`（§4.3：AI 不许代填）；
///  · `script/style/meta/noscript/template/link/title` 的内容**整棵跳过**（§4.2）；
///  · 隐藏元素（`display:none`/`visibility:hidden`/`hidden`/`aria-hidden`/零尺寸/`type=hidden`）
///    不进产出，只进 `skipped.hidden` 计数（§4.2）。
/// 另外它**只读不写**：不派发事件、不改表单值、不发请求；唯一写到页面上的是
/// `data-nx-idx` 索引属性——那是第二刀 `web_act idx=` 的定位锚，必须落在 DOM 上才用得了。
const String kWebDomSerializeScript = r'''
(function () {
  var IDX_ATTR = 'data-nx-idx';
  var LABEL_CAP = 120;
  var HREF_CAP = 400;
  var STRIPPED_TAGS = {SCRIPT:1,STYLE:1,META:1,NOSCRIPT:1,TEMPLATE:1,LINK:1,TITLE:1,HEAD:1};
  var INTERACTIVE = 'a,button,input,textarea,select,[role="button"],[contenteditable="true"]';
  function norm(s) { return (s === null || s === undefined) ? '' : String(s).replace(/\s+/g, ' ').trim(); }
  function clip(s, n) { s = norm(s); return s.length > n ? s.slice(0, n) : s; }
  function attr(el, name) { try { return el.getAttribute(name) || ''; } catch (e) { return ''; } }
  function isHidden(el) {
    if (!el || el.nodeType !== 1) return true;
    if (el.hasAttribute('hidden')) return true;
    if (attr(el, 'aria-hidden') === 'true') return true;
    if (attr(el, 'type').toLowerCase() === 'hidden') return true;
    var cs = window.getComputedStyle ? window.getComputedStyle(el) : null;
    if (cs && (cs.display === 'none' || cs.visibility === 'hidden' ||
               cs.visibility === 'collapse')) return true;
    var r = el.getBoundingClientRect();
    return r.width <= 0 && r.height <= 0;
  }
  function underHiddenAncestor(el) {
    var n = el;
    while (n && n.nodeType === 1) { if (isHidden(n)) return true; n = n.parentElement; }
    return false;
  }
  function inViewport(r) { return r.bottom > 0 && r.top < window.innerHeight; }
  function ownText(el) {
    var t = '';
    for (var n = el.firstChild; n; n = n.nextSibling) { if (n.nodeType === 3) t += n.nodeValue; }
    return norm(t);
  }
  function inputTypeOf(el) {
    var t = attr(el, 'type') || (typeof el.type === 'string' ? el.type : '');
    return norm(t).toLowerCase() || 'text';
  }
  function labelFor(el, isPassword) {
    var cands = [ownText(el), attr(el, 'aria-label'), attr(el, 'placeholder'),
                 attr(el, 'name'), attr(el, 'title')];
    // 密码框：value 连候选都不进（下面的 Dart 侧还有第二道，两道不是重复而是下界/上界）
    if (!isPassword && el.tagName === 'INPUT') {
      var t = inputTypeOf(el);
      if (t !== 'checkbox' && t !== 'radio' && t !== 'file') {
        try { cands.push(el.value); } catch (e) {}
      }
    }
    for (var i = 0; i < cands.length; i++) { var v = clip(cands[i], LABEL_CAP); if (v) return v; }
    return '';
  }
  function hrefFor(el) {
    if (el.tagName !== 'A' && el.tagName !== 'AREA') return '';
    return clip(attr(el, 'href'), HREF_CAP);
  }
  var skipped = {hidden: 0, strippedTags: 0, passwordValues: 0};
  var blocks = [];
  function walk(el) {
    if (!el || el.nodeType !== 1) return;
    if (STRIPPED_TAGS[el.tagName]) { skipped.strippedTags++; return; }
    if (isHidden(el)) { skipped.hidden++; return; }
    var direct = ownText(el);
    if (direct) {
      var r = el.getBoundingClientRect();
      blocks.push({text: clip(direct, LABEL_CAP * 8), tag: el.tagName.toLowerCase(),
                   top: Math.round(r.top + window.pageYOffset), inViewport: inViewport(r)});
    }
    for (var c = el.firstChild; c; c = c.nextSibling) walk(c);
  }
  if (document.documentElement) walk(document.documentElement);
  var elements = [];
  var nodes = document.querySelectorAll(INTERACTIVE);
  for (var i = 0; i < nodes.length; i++) {
    var el = nodes[i];
    if (STRIPPED_TAGS[el.tagName]) { skipped.strippedTags++; continue; }
    if (underHiddenAncestor(el) || isHidden(el)) { skipped.hidden++; continue; }
    var tag = el.tagName.toLowerCase();
    var type = el.tagName === 'INPUT' ? inputTypeOf(el) : norm(attr(el, 'type')).toLowerCase();
    var isPassword = (el.tagName === 'INPUT' && type === 'password');
    if (isPassword) skipped.passwordValues++;
    var idx = elements.length + 1;
    try { el.setAttribute(IDX_ATTR, String(idx)); } catch (e) {}
    var r2 = el.getBoundingClientRect();
    elements.push({idx: idx, tag: tag, type: type, label: labelFor(el, isPassword),
                   href: hrefFor(el), needsHuman: isPassword,
                   inViewport: inViewport(r2), top: Math.round(r2.top + window.pageYOffset)});
  }
  var body = document.body;
  return JSON.stringify({
    url: location.href,
    title: clip(document.title, LABEL_CAP),
    viewport: {top: Math.round(window.pageYOffset), height: window.innerHeight,
               scrollHeight: body ? body.scrollHeight : 0},
    skipped: skipped, blocks: blocks, elements: elements
  });
})()
''';

// ============================================================================
// ② Dart 侧：数据结构
// ============================================================================

/// 这些标签的内容**即使在 payload 里出现了也不进产出**（Dart 侧第二道，§4.2）。
/// 与 JS 的 `STRIPPED_TAGS` 同一集合；两处都由测试盯着，改一处即红。
const Set<String> kWebDomStrippedTags = {
  'script', 'style', 'meta', 'noscript', 'template', 'link', 'title', 'head',
};

/// `input[type=password]` 的档名判定（Dart 侧独立再算一遍，不信 JS 的 `needsHuman`）。
bool webDomIsPasswordField(String tag, String type) =>
    tag == 'input' && type == 'password';

/// 一段可见文本块（DOM 顺序）。
class WebDomTextBlock {
  final String text;
  final String tag;

  /// 文档绝对纵坐标（px），用于"视口优先"排序与排查。
  final int top;
  final bool inViewport;

  const WebDomTextBlock({
    required this.text,
    required this.tag,
    required this.top,
    required this.inViewport,
  });
}

/// 一个可交互元素（`idx` 是 JS 打进 DOM 的 `data-nx-idx`，第二刀 `web_act idx=` 用它定位）。
class WebDomElement {
  final int idx;
  final String tag;
  final String type;

  /// 元素上的可见文字（placeholder/aria-label/name/value 取第一个非空）。
  /// **密码框恒为空串**——值不许进模型上下文（§4.3）。
  final String label;
  final String href;

  /// true = 这是密码框：AI 不许代填，必须转人工。
  final bool needsHuman;
  final bool inViewport;
  final int top;

  const WebDomElement({
    required this.idx,
    required this.tag,
    required this.type,
    required this.label,
    required this.href,
    required this.needsHuman,
    required this.inViewport,
    required this.top,
  });
}

/// 一次序列化的结果（已经过 Dart 侧剥离与归一）。
class WebDomSnapshot {
  final String title;
  final String url;
  final List<WebDomTextBlock> blocks;
  final List<WebDomElement> elements;
  final int viewportTop;
  final int viewportHeight;
  final int scrollHeight;

  /// JS 侧的剥离计数（**默认不吞、异常可见**：省略了多少要在产出里说一句）。
  final int skippedHidden;
  final int skippedStrippedTags;
  final int skippedPasswordValues;

  const WebDomSnapshot({
    required this.title,
    required this.url,
    required this.blocks,
    required this.elements,
    required this.viewportTop,
    required this.viewportHeight,
    required this.scrollHeight,
    required this.skippedHidden,
    required this.skippedStrippedTags,
    required this.skippedPasswordValues,
  });

  int get interactiveCount => elements.length;
}

/// 解析结果：`error != null` 时 `snapshot` 为 null，且 error 是要回灌给模型的**人话**。
///
/// 为什么不用异常：这条通道的输入是第三方页面的脚本输出，"脚本没跑成/被 CSP 拦了/
/// 返回了 HTML 而不是 JSON"都是常态，判据层必须能把原因原样带出去（研究文档 §五.4 的
/// 取证口径），而不是让调用点写 try/catch 猜。
class WebDomParseResult {
  final WebDomSnapshot? snapshot;
  final String? error;

  /// 解析成功（等价于 `error == null`，写出来是给调用点读的）。
  bool get isOk => error == null;

  const WebDomParseResult._(this.snapshot, this.error);

  /// 参数名刻意不叫 `snapshot`、不写成 `this.snapshot`：那样会把这一个入口的
  /// 类型放宽成 `WebDomSnapshot?`，于是"成功但没有快照"这种自相矛盾的结果能构造出来。
  const WebDomParseResult.ok(WebDomSnapshot parsed) : this._(parsed, null);

  const WebDomParseResult.fail(String reason) : this._(null, reason);
}

// ============================================================================
// ③ 解析
// ============================================================================

String _str(Object? v) => v == null ? '' : '$v';

int _int(Object? v, {int fallback = 0}) {
  if (v is int) return v;
  if (v is num) return v.round();
  return int.tryParse(_str(v).trim()) ?? fallback;
}

bool _bool(Object? v) => v == true || _str(v).toLowerCase() == 'true';

/// 把 `runJavaScriptReturningResult` 的返回值解成 [WebDomParseResult]。
///
/// 三种进得来的形态都要能吃（平台差异，不是猜测）：
///  · 直接是 JSON 对象文本；
///  · 被再包了一层引号的 JSON 字符串（Android `evaluateJavascript` 对 string 结果
///    给的是 JSON 编码后的字面量，即 `"{\"a\":1}"` 这种）；
///  · 空串 / `null` / `undefined`（脚本没跑成）。
WebDomParseResult parseWebDomPayload(String raw) {
  final payload = _unwrapJsResult(raw);
  if (payload == null) {
    return const WebDomParseResult.fail('页面脚本没有返回内容（可能被 CSP 拦下或页面还没就绪）');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(payload);
  } catch (e) {
    return WebDomParseResult.fail('页面脚本返回的不是 JSON：${_clip(_str(e), 160)}');
  }
  if (decoded is! Map) {
    return const WebDomParseResult.fail('页面脚本返回的不是对象，无法序列化');
  }
  final blocks = <WebDomTextBlock>[];
  final elements = <WebDomElement>[];
  final seenIdx = <int>{};

  for (final item in _listOf(decoded['blocks'])) {
    final tag = _str(item['tag']).toLowerCase();
    // 剥离第二道①：script/style/meta 家族的内容不进产出（§4.2）。
    if (kWebDomStrippedTags.contains(tag)) continue;
    // 剥离第二道③：隐藏元素不进产出（§4.2）。blocks 的 tag 是容器名，
    // 隐藏的容器在 JS 侧已经跳过，这里再认一次 payload 上的标记。
    if (_bool(item['hidden'])) continue;
    final text = _str(item['text']).trim();
    if (text.isEmpty) continue;
    blocks.add(WebDomTextBlock(
      text: text,
      tag: tag,
      top: _int(item['top']),
      inViewport: _bool(item['inViewport']),
    ));
  }

  for (final item in _listOf(decoded['elements'])) {
    final tag = _str(item['tag']).toLowerCase();
    final type = _str(item['type']).toLowerCase();
    if (kWebDomStrippedTags.contains(tag)) continue;
    if (_bool(item['hidden'])) continue;
    final idx = _int(item['idx'], fallback: -1);
    if (idx < 0 || !seenIdx.add(idx)) continue; // 索引缺失或重复：丢掉，不猜
    final needsHuman = _bool(item['needsHuman']) || webDomIsPasswordField(tag, type);
    // 剥离第二道②（**这一行就是密码值的那道闸**，证伪探针注释掉的正是它）：
    // 密码框的 label 连"疑似值"都不留 —— JS 万一漏了（或被改写过的脚本送回来），
    // 这里也不让 `hunter2` 这种字符串进模型上下文。
    final label = needsHuman ? '' : _str(item['label']).trim();
    elements.add(WebDomElement(
      idx: idx,
      tag: tag,
      type: type,
      label: label,
      href: needsHuman ? '' : _str(item['href']).trim(),
      needsHuman: needsHuman,
      inViewport: _bool(item['inViewport']),
      top: _int(item['top']),
    ));
  }

  // 顺序归一：索引升序 + 去重（JS 按 DOM 序打索引，但 payload 可能被中间层重排）。
  elements.sort((a, b) => a.idx.compareTo(b.idx));

  final skipped = decoded['skipped'];
  return WebDomParseResult.ok(WebDomSnapshot(
    title: _str(decoded['title']).trim(),
    url: _str(decoded['url']).trim(),
    blocks: List<WebDomTextBlock>.unmodifiable(blocks),
    elements: List<WebDomElement>.unmodifiable(elements),
    viewportTop: _int((decoded['viewport'] as Map?)?['top']),
    viewportHeight: _int((decoded['viewport'] as Map?)?['height']),
    scrollHeight: _int((decoded['viewport'] as Map?)?['scrollHeight']),
    skippedHidden: _int((skipped as Map?)?['hidden']),
    skippedStrippedTags: _int(skipped is Map ? skipped['strippedTags'] : null),
    skippedPasswordValues: _int(skipped is Map ? skipped['passwordValues'] : null),
  ));
}

/// JSON 数组 → `List<Map>`；不是数组 / 元素不是对象的一律跳过（不抛）。
List<Map<String, dynamic>> _listOf(Object? v) {
  if (v is! List) return const [];
  final out = <Map<String, dynamic>>[];
  for (final e in v) {
    if (e is Map) out.add(e.map((k, val) => MapEntry('$k', val)));
  }
  return out;
}

String? _unwrapJsResult(String raw) {
  var s = raw.trim();
  if (s.isEmpty || s == 'null' || s == 'undefined' || s == '""') return null;
  // 被再包一层的那一种：先解掉外层字符串，再解对象。
  if (s.startsWith('"') && s.endsWith('"') && s.length > 1) {
    try {
      final inner = jsonDecode(s);
      if (inner is String) s = inner.trim();
    } catch (_) {
      return null;
    }
  }
  if (s.isEmpty || s == 'null' || s == 'undefined') return null;
  return s;
}

String _clip(String s, int max) => s.length <= max ? s : s.substring(0, max);

// ============================================================================
// ④ 渲染 + 截断（硬上限 + 视口优先）
// ============================================================================

/// 渲染结果。[text] 是**待回灌正文**：第二刀把它整条交给 `toolResultTag(body: …)`，
/// 不在这里拼外壳。
class WebDomRender {
  final String text;

  /// 是否发生了截断（调用点可以直接传给预览/日志，不必再 `contains` 一次）。
  final bool truncated;

  /// 截断**前**的全文长度（不截断时等于 `text.length`）。
  final int fullLength;

  /// 因"视口优先"被省略的正文块数 / 元素数（0 = 没省略）。
  final int omittedBlocks;
  final int omittedElements;

  const WebDomRender({
    required this.text,
    required this.truncated,
    required this.fullLength,
    required this.omittedBlocks,
    required this.omittedElements,
  });
}

/// 序列化快照 → 可回灌正文（纯函数）。
///
/// 截断策略两档，顺序与 [kWebDomReadBackLimit] 的注释绑定（研究文档 §4.2）：
///  1. 全文不超上限 → 原样给，**不带任何标注**（反向闸钉这条：没截断却说截断了，
///     比不报更糟——用户会去翻一个不完整的页面）；
///  2. 超上限 → 先只留**视口内**的正文块与元素（§4.2「超出只给视口附近元素」），
///     并在产出里写明省略了多少；
///  3. 视口那一档还超 → 按上限从尾部硬切。
/// 两档都在**末尾追加** [webDomTruncationNote]：少了内容就必须说"少了"，
/// 标注自己不参与裁剪（宁可产出比上限长那几个字，也不能把"截断了"这件事截掉——
/// 与 `workspace_service.dart:258` 那一句同一取舍）。
WebDomRender renderWebDomForModel(
  WebDomSnapshot snapshot, {
  int limit = kWebDomReadBackLimit,
  bool zh = true,
}) {
  final fullLines = _renderLines(snapshot, onlyViewport: false, zh: zh);
  final full = fullLines.join('\n');
  if (full.length <= limit) {
    return WebDomRender(
      text: full,
      truncated: false,
      fullLength: full.length,
      omittedBlocks: 0,
      omittedElements: 0,
    );
  }

  final omittedBlocks =
      snapshot.blocks.where((b) => !b.inViewport).length;
  final omittedElements =
      snapshot.elements.where((e) => !e.inViewport).length;
  final viewportLines = _renderLines(
    snapshot,
    onlyViewport: true,
    zh: zh,
    omittedBlocks: omittedBlocks,
    omittedElements: omittedElements,
  );
  final viewport = viewportLines.join('\n');
  // 两条截断档**都**留标注：只留视口内容的那一档同样是"少给了"，
  // 少给了却不吭声 = 模型以为自己看到的是整页（反向闸只管"没少给"那一档）。
  final note = webDomTruncationNote(full.length, zh: zh);
  final budget = limit - note.length - 1; // 1 = 中间那个换行；标注本身不裁剪
  final body = budget >= viewport.length
      ? viewport
      : viewport.substring(0, budget > 0 ? budget : 0);
  return WebDomRender(
    text: '$body\n$note',
    truncated: true,
    fullLength: full.length,
    omittedBlocks: omittedBlocks,
    omittedElements: omittedElements,
  );
}

List<String> _renderLines(
  WebDomSnapshot s, {
  required bool onlyViewport,
  required bool zh,
  int omittedBlocks = 0,
  int omittedElements = 0,
}) {
  final lines = <String>[];
  lines.add('${zh ? '标题' : 'TITLE'}: ${s.title.isEmpty ? (zh ? '（无标题）' : '(no title)') : s.title}');
  lines.add('${zh ? '地址' : 'URL'}: ${s.url.isEmpty ? (zh ? '（未知）' : '(unknown)') : s.url}');

  final blocks = onlyViewport ? s.blocks.where((b) => b.inViewport) : s.blocks;
  final elements = onlyViewport ? s.elements.where((e) => e.inViewport) : s.elements;

  lines.add(zh ? '正文（${blocks.length} 块）：' : 'TEXT (${blocks.length} block(s)):');
  for (final b in blocks) {
    lines.add('· ${b.text}');
  }

  lines.add(zh ? '可交互元素（${elements.length} 个，用 idx 定位）：'
               : 'INTERACTIVE (${elements.length} item(s), address by idx):');
  for (final e in elements) {
    lines.add(_elementLine(e, zh: zh));
  }

  if (onlyViewport && (omittedBlocks > 0 || omittedElements > 0)) {
    lines.add(zh
        ? '（视口外已省略：正文 $omittedBlocks 块 / 元素 $omittedElements 个；'
            '需要就滚动后再读一次）'
        : '(out of viewport: $omittedBlocks text block(s), $omittedElements item(s); '
            'scroll and read again if needed)');
  }

  // 剥离计数：**默认不吞**——省掉的东西要在同一份产出里能数出来（研究文档 §五.4）。
  final counts = <String>[];
  if (s.skippedHidden > 0) {
    counts.add(zh ? '隐藏元素 ${s.skippedHidden} 处' : 'hidden ${s.skippedHidden}');
  }
  if (s.skippedStrippedTags > 0) {
    counts.add(zh
        ? 'script/style/meta 内容 ${s.skippedStrippedTags} 处'
        : 'script/style/meta ${s.skippedStrippedTags}');
  }
  if (s.skippedPasswordValues > 0) {
    counts.add(zh
        ? '密码框 ${s.skippedPasswordValues} 个（值未读取）'
        : 'password field(s) ${s.skippedPasswordValues} (values not read)');
  }
  if (counts.isNotEmpty) {
    lines.add('${zh ? '已剥离' : 'STRIPPED'}: ${counts.join(zh ? ' / ' : ', ')}');
  }
  return lines;
}

String _elementLine(WebDomElement e, {required bool zh}) {
  final kind = e.type.isEmpty ? e.tag : '${e.tag}[${e.type}]';
  final bits = <String>['[${e.idx}] $kind'];
  if (e.label.isNotEmpty) {
    bits.add(e.label);
  } else if (e.needsHuman) {
    bits.add(zh ? '需要人工输入，AI 不代填' : 'needs human input, AI must not fill');
  }
  if (e.href.isNotEmpty) {
    bits.add('${zh ? '指向' : 'href'}=${e.href}');
  }
  if (!e.inViewport) {
    bits.add(zh ? '（视口外）' : '(off-screen)');
  }
  return bits.join(' · ');
}
