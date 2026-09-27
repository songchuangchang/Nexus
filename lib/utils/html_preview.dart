/// build162：「这条助手消息整体就是一份 HTML 文档」判据（纯函数，零 Flutter 依赖）。
///
/// 为什么单独成文件、为什么写成纯函数：
///  · 真 WebView 在 flutter_test 里渲染不出来，判据层是这次唯一能做**行为断言**的地方
///    （预览页本体只做源码级断言，这条界限写在 test/build162_html_preview_test.dart）；
///  · 判据只准有一处：气泡按钮与文件入口各写一遍，早晚变成"气泡认、文件不认"
///    （本仓教训 #62「两份真源」同族）。
///
/// 为什么判据这么严，而不是 `contains('<html')` 就完事：
///  内容来自模型输出，「这段话里提到了 html」和「这条消息整体就是一张能独立渲染的网页」
///  是两件事 —— 只有后者值得占操作行一个按钮位。前者给他「复制」更合适：混排着说明文字
///  的东西塞进 WebView，用户看到的是半截正文加一段没头没尾的标签，比没有按钮更糟。
///  （`test/build162_html_preview_test.dart` 里那条证伪探针就是钉这个的。）
library;

/// 能在 App 内预览的 HTML 后缀（文件入口的判据）。
const Set<String> _htmlExts = {'html', 'htm'};

const String _doctypePrefix = '<!doctype html';
const String _htmlTagPrefix = '<html';
const String _htmlCloseTag = '</html';

/// [text] 是否**整条就是一份** HTML 文档（开头是文档标签、有闭合 `</html>`、
/// 并且除这段文档之外没有别的实质内容）。
bool looksLikeHtmlDocument(String text) => extractHtmlDocument(text) != null;

/// 判据成立时返回**剥掉 ``` 围栏后的 HTML 正文**（直接喂 WebView），否则 null。
///
/// 为什么返回正文而不是 bool：两个调用点（判"要不要出按钮" / 取"渲染什么"）
/// 各剥一遍围栏就等于写两份围栏口径，必然漂移。
String? extractHtmlDocument(String text) {
  final body = _fenceStrippedBody(text);
  if (body == null) return null;
  // 大小写不敏感自己走 toLowerCase（本仓禁内联标志 `(?i)`）。
  // 只在 lower 上做判断与取值：非 ASCII 字符折叠后**长度会变**，
  // 所以绝不拿 lower 算出来的下标回头切 body。
  final lower = body.toLowerCase();
  if (!_opensAsDocument(lower)) return null;
  final closeEnd = _closingTagEnd(lower);
  if (closeEnd < 0) return null;
  // `</html>` 之后不许再有实质内容：两份文档拼在一起、尾巴上带一句"以上就是…"都不算
  if (lower.substring(closeEnd).trim().isNotEmpty) return null;
  return body;
}

/// 文件名是否 HTML（工作区/附件分派用）。
///
/// 用 endsWith 而不是包含：`a.html.bak`、`photo.htm备份` 都不该算。
/// 不去 import `WorkspaceService.extOf` 拆扩展名 —— 那会把 dart:io/path_provider
/// 整条依赖链拖进这个纯函数文件，测试也就没法只测判据。
bool isHtmlPreviewFile(String name) {
  final lower = name.trim().toLowerCase();
  return _htmlExts.any((e) => lower.endsWith('.$e'));
}

/// 剥 ``` 围栏后的正文；**围栏外还有实质内容就返回 null**（混排讲解不算文档）。
///
/// 口径与本仓 markdown 渲染侧**同一形状**：`split('```')` 之后偶数段是围栏外正文、
/// 奇数段是围栏内代码（react_parser.dart 的 stripControlTags、
/// deep_link_markdown.dart 的 linkifyDeepUris、answer_finalizer.dart 的
/// _unwrapAnswerWrapper 三处都是这一套，不另写第四份）。
String? _fenceStrippedBody(String text) {
  final parts = text.split('```');
  // 一个围栏都没有：整条正文本身就是候选
  if (parts.length == 1) return text.trim().isEmpty ? null : text.trim();
  final blocks = <String>[];
  for (var i = 0; i < parts.length; i++) {
    if (i.isEven) {
      // 围栏外有话要说 ⇒ 这是"讲解"不是"网页"
      if (parts[i].trim().isNotEmpty) return null;
      continue;
    }
    final code = _dropInfoLine(parts[i]);
    if (code.trim().isNotEmpty) blocks.add(code.trim());
  }
  if (blocks.isEmpty) return null;
  return blocks.join('\n').trim();
}

/// 围栏第一行的语言标记（```html 的那个 `html`）不是内容：markdown 解析器也不会
/// 把它当正文渲染。不剥掉它就永远"不以 <!doctype 开头"，围栏包住的文档全部判假。
String _dropInfoLine(String fenced) {
  final nl = fenced.indexOf('\n');
  if (nl < 0) return ''; // 一整段只有语言标记，没有代码
  final info = fenced.substring(0, nl).trim();
  // 只把「一个词」当语言标记：带尖括号/空白的第一行是代码本身
  // （有人把 `<!doctype html>` 直接写在 ``` 后面同一行），那种原样留着。
  if (info.isEmpty) return fenced.substring(nl + 1);
  if (info.contains(' ') || info.contains('<') || info.contains('>')) {
    return fenced;
  }
  return fenced.substring(nl + 1);
}

/// 开头必须是 `<!doctype html…` 或 `<html…`，且标签名后面紧跟边界字符。
/// 边界那道判断是防「`<html` 后面粘着别的词」（如 `<htmlkit 是个工具`）被当成文档开头。
bool _opensAsDocument(String lower) {
  final String rest;
  if (lower.startsWith(_doctypePrefix)) {
    rest = lower.substring(_doctypePrefix.length);
  } else if (lower.startsWith(_htmlTagPrefix)) {
    rest = lower.substring(_htmlTagPrefix.length);
  } else {
    return false;
  }
  if (rest.isEmpty) return false;
  return rest[0] == '>' || rest[0] == '/' || _isSpace(rest[0]);
}

/// 最后一个 `</html>` 的右边界**之后**的下标；没有合法闭合标签返回 -1。
int _closingTagEnd(String lower) {
  final i = lower.lastIndexOf(_htmlCloseTag);
  if (i < 0) return -1;
  var j = i + _htmlCloseTag.length;
  while (j < lower.length && _isSpace(lower[j])) {
    j++;
  }
  // `</htmlx>` 这种不算闭合（模型偶尔会写出多个闭合标签，取最后一个从严判）
  if (j >= lower.length || lower[j] != '>') return -1;
  return j + 1;
}

bool _isSpace(String c) => c == ' ' || c == '\t' || c == '\n' || c == '\r';
