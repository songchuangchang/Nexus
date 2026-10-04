import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:path_provider/path_provider.dart';
import '../services/workspace_service.dart';
import '../ui/app_sheet.dart';
import '../utils/app_snackbar.dart';
import '../utils/launcher_utils.dart';
import '../utils/office_writer.dart';

/// #25：本 App **唯一**的 markdown 扩展集，所有 `MarkdownBody` 调用点都必须显式传它。
///
/// 与上游 `ExtensionSet.gitHubFlavored` 的唯一差别：**摘掉 `FootnoteDefSyntax`**。
/// 实测（`test/build187_25_footnote_def_visible_test.dart`）：`[^1]: 这是脚注内容` 这样
/// **没有被引用**的定义行，走上游默认时屏上一个字都不剩——定义被解析成游离的 `li`，
/// 而 `flutter_markdown-0.7.7+1/lib/` 全库没有脚注渲染区（`footnote` 只命中 `style_sheet.dart:711`
/// 的一句注释），摘出去的那些字没人画。本仓通则：**显示侧不许偷偷删模型内容**
/// （`lib/constants.dart` build182 那条已定调：只剥语法标记，不剥内容）。
///
/// 摘掉之后 `[^1]: 文字` 退化成普通段落——那对标记会露出来，但内容一定在屏上。
/// 为什么不用"把脚注区补出来"那条路：那是给渲染层加一个没有所有者的新区域，
/// 而 #25 要的只是"不许丢字"。
/// 默认值住在包里（`widget.dart:398` 的 `?? gitHubFlavored`）⇒ 不显式传＝把这件事交给上游升级决定，
/// 所以调用点是否显式传本集由判据逐处扫 `lib/` 钉住。
final md.ExtensionSet nexusMarkdownExtensions = md.ExtensionSet(
  List<md.BlockSyntax>.unmodifiable(<md.BlockSyntax>[
    for (final s in md.ExtensionSet.gitHubFlavored.blockSyntaxes)
      if (s is! md.FootnoteDefSyntax) s,
  ]),
  List<md.InlineSyntax>.unmodifiable(
      List<md.InlineSyntax>.from(md.ExtensionSet.gitHubFlavored.inlineSyntaxes)),
);

/// #25：把 `[^1]: 文字` 这类脚注定义**原样**画成一个段落，一个字都不删。
///
/// 只摘掉上游的 `FootnoteDefSyntax`（见 [nexusMarkdownExtensions]）不够——实测：
/// 那种形状同时长得像**链接引用定义** `[label]: destination`，而 `BlockParser`
/// （`markdown-7.3.1/lib/src/block_parser.dart:188-195`）对 `LinkReferenceDefinitionSyntax`
/// 特判成"即使没产出节点也 break 掉这一行"，于是字还是没了。
/// 自定义语法排在 `document.blockSyntaxes` 前面（`BlockParser` 构造 79-83 行先加 custom
/// 再加 standard）⇒ 这一条会先命中，链接引用那条拿不到这一行。
///
/// 为什么不"把脚注区补出来"：#25 要的只是"不许丢字"，补区域是给渲染层加一个没有所有者的新职责。
class NexusFootnoteDefSyntax extends md.BlockSyntax {
  NexusFootnoteDefSyntax();

  @override
  RegExp get pattern => RegExp(r'^ {0,3}\[\^[^\]\n]{1,60}\]:');

  @override
  md.Node? parse(md.BlockParser parser) {
    final lines = <String>[];
    while (!parser.isDone) {
      final content = parser.current.content;
      if (lines.isNotEmpty &&
          (content.trim().isEmpty ||
              pattern.hasMatch(content) ||
              !content.startsWith('    '))) {
        break; // 只吃这一行，外加缩进续行；空行或下一条定义交还给解析器
      }
      // 只有真的缩进满 4 格的续行才剥掉那 4 格；不缩进的行（今天会被上面的 break 挡住）
      // 一律原样留着——否则一改 break 条件就会像 10-04 那把刀演示的那样，
      // 把第二条定义的 `[^2]:` 前缀当缩进给削掉（削掉的不是标记，是内容）。
      lines.add(lines.isEmpty || !content.startsWith('    ')
          ? content
          : content.substring(4));
      parser.advance();
    }
    return md.Element('p', [md.Text(lines.join('\n'))]);
  }
}

/// v1.7.37：AI 输出多功能化 —— 代码块一键复制 + 表格复制/下载。
///
/// 注意（踩坑）：flutter_markdown 0.7.7+1 的 builder.dart 在 visitElementAfter
/// 中对 'table' 标签会用 `_buildTable()` 无条件覆盖自定义 builder 的返回值，
/// 因此不能直接对 'table' 注册 builder。这里用自定义 [NexusTableSyntax]
/// 把 GFM 表格改写成 'nx_table' 标签（整表原始文本塞进单个 md.Text 子节点），
/// 再由 [TableBuilder] 自行解析渲染。
class NexusTableSyntax extends md.BlockSyntax {
  NexusTableSyntax();

  /// 分隔行：`| --- | :---: | ---: |` 形式（至少两列）
  static final RegExp _separatorPattern = RegExp(
    r'^\s*\|?(\s*:?-+:?\s*\|)+\s*:?-+:?\s*\|?\s*$',
  );

  @override
  RegExp get pattern => RegExp(r'.*'); // 不会被用到（canParse 已重写）

  @override
  bool canEndBlock(md.BlockParser parser) => true;

  @override
  bool canParse(md.BlockParser parser) {
    // 当前行需含 '|'（表头），下一行是分隔行
    return parser.current.content.contains('|') &&
        parser.matchesNext(_separatorPattern);
  }

  @override
  md.Node? parse(md.BlockParser parser) {
    final sb = StringBuffer();
    sb.writeln(parser.current.content); // 表头行
    parser.advance();
    sb.writeln(parser.current.content); // 分隔行
    parser.advance();
    while (!parser.isDone && !md.BlockSyntax.isAtBlockEnd(parser)) {
      sb.writeln(parser.current.content);
      parser.advance();
    }
    return md.Element('nx_table', [md.Text(sb.toString().trimRight())]);
  }
}

/// 从元素树提取纯文本（含嵌套 code 元素）
String _extractText(md.Node node) {
  if (node is md.Text) return node.text;
  if (node is md.Element) {
    return (node.children ?? []).map(_extractText).join();
  }
  return '';
}

// ============================================================================
// build117：表格可视化的**纯函数层**（可单测，无 Flutter 依赖）
//
// 规格取自 Chatbox 源码级实证（src/renderer/static/index.css）+ 移动端惯例：
// 宽表横向滚动、表头加粗浅底、斑马纹、1px 全网格 + 圆角、GFM 对齐标记映射
// （无标记默认居中）、宽松横向/紧凑纵向密度。全部自绘，零新依赖。
// ============================================================================

/// 切分一行 GFM 表格行。
///
/// 要点：先把转义的 `\|` 换成占位符再按 `|` 切（否则 `a \| b` 会被切成两格），
/// 切完还原；剥掉行首/行尾的管道符（转义形式已被占位符替换，不会误剥）。
List<String> splitTableRow(String line) {
  const placeholder = '\u0000';
  var s = line.replaceAll(r'\|', placeholder).trim();
  if (s.startsWith('|')) s = s.substring(1);
  if (s.endsWith('|')) s = s.substring(0, s.length - 1);
  return s
      .split('|')
      .map((c) => c.replaceAll(placeholder, '|').trim())
      .toList();
}

/// 解析分隔行的对齐标记 → 每列 TextAlign。
///
/// `:---` → left、`:---:` → center、`---:` → right、无冒号 → **center**
/// （Chatbox 的 `th,td{text-align:center}` 是默认值）。列数不足按 center 补齐。
List<TextAlign> parseColumnAlignments(String separatorLine, int columnCount) {
  final cells = splitTableRow(separatorLine);
  final result = <TextAlign>[];
  for (var i = 0; i < columnCount; i++) {
    if (i >= cells.length) {
      result.add(TextAlign.center);
      continue;
    }
    final c = cells[i];
    final left = c.startsWith(':');
    final right = c.endsWith(':');
    if (left && right) {
      result.add(TextAlign.center);
    } else if (right) {
      result.add(TextAlign.right);
    } else if (left) {
      result.add(TextAlign.left);
    } else {
      result.add(TextAlign.center);
    }
  }
  return result;
}

/// 行内格数归一：不足 [columnCount] 补空串、超出截断（流式/弱模型常输出不齐行）。
List<List<String>> normalizeTableRows(
    List<List<String>> rows, int columnCount) {
  return rows.map((r) {
    if (r.length == columnCount) return r;
    if (r.length > columnCount) return r.sublist(0, columnCount);
    return <String>[...r, ...List.filled(columnCount - r.length, '')];
  }).toList();
}

/// 表格 → CSV（含引号/逗号/换行转义）。
String tableToCsv(List<String> header, List<List<String>> rows) {
  String cell(String v) {
    if (v.contains(',') || v.contains('"') || v.contains('\n')) {
      return '"${v.replaceAll('"', '""')}"';
    }
    return v;
  }

  final sb = StringBuffer();
  sb.writeln(header.map(cell).join(','));
  for (final r in rows) {
    sb.writeln(r.map(cell).join(','));
  }
  return sb.toString();
}

/// 表格 → Markdown（保留表头与分隔行）。
String tableToMarkdown(List<String> header, List<List<String>> rows) {
  String row(List<String> cells) => '| ${cells.join(' | ')} |';
  final sb = StringBuffer();
  sb.writeln(row(header));
  sb.writeln('| ${List.filled(header.length, '---').join(' | ')} |');
  for (final r in rows) {
    sb.writeln(row(r));
  }
  return sb.toString();
}

/// 单元格行内标记 → 纯文本（**与表格渲染器同一套解析**：[parseCellRuns]）。
///
/// 导出给 Excel 的内容不能带 `**粗**` / `` `code` `` 这些 Markdown 记号，
/// 否则单元格里就是一串噪声；链接写成「文字（url）」，URL 不丢。
String flattenCellMarks(String raw) {
  final sb = StringBuffer();
  for (final run in parseCellRuns(raw)) {
    sb.write(run.text);
    final url = run.linkUrl;
    if (url != null && url.isNotEmpty) sb.write('（$url）');
  }
  return sb.toString().trim();
}

/// 表格（表头 + 数据行）→ **导出用** CSV 载荷文本。
///
/// 这是「Markdown 表格 → OfficeWriter.parseSheets 入参」的唯一口径，纯函数、
/// 不依赖 widget 渲染，单测直接喂数据断言。与 [tableToCsv]（剪贴板用，保留
/// 行内记号）的区别只在先过一遍 [flattenCellMarks]。
String tableToCsvPayload(List<String> header, List<List<String>> rows) =>
    tableToCsv(
      header.map(flattenCellMarks).toList(),
      rows.map((r) => r.map(flattenCellMarks).toList()).toList(),
    );

/// 导出前置检查：整表空内容要给出**具体原因**，不得静默产出空 xlsx。
String? tableExportError(List<String> header, List<List<String>> rows) {
  final hasHeader = header.any((h) => flattenCellMarks(h).isNotEmpty);
  final hasRow = rows.any((r) => r.any((c) => flattenCellMarks(c).isNotEmpty));
  if (!hasHeader && !hasRow) {
    return '该表格没有可导出的内容（表头与数据行都是空的）';
  }
  return null;
}

/// 任意字符串 → 工作区合法段名（[WorkspaceService.isValidSegment] 白名单）。
///
/// 白名单只放：ASCII 字母数字、下划线、中划线、中文、空格（收成 `_`）。
/// 关键点：**点号一律剔除**——`a..b` 过不了 resolve 的穿越检查，而文件名里的
/// 点会让扩展名判定变复杂；`/\:*?"<>|` 这些更是在白名单外。
String sanitizeWorkspaceNameSegment(String raw) {
  final allowed = RegExp(r'[A-Za-z0-9_\-\u4e00-\u9fff]');
  final sb = StringBuffer();
  var pendingSpace = false;
  for (final cu in flattenCellMarks(raw).runes) {
    final ch = String.fromCharCode(cu);
    if (allowed.hasMatch(ch)) {
      if (pendingSpace && sb.isNotEmpty) sb.write('_');
      pendingSpace = false;
      sb.write(ch);
    } else if (ch == ' ' || ch == '.' || ch == '(' || ch == ')') {
      pendingSpace = true;
    }
    // 其它字符（emoji、全角符号、引号…）直接丢弃
  }
  var out = sb.toString();
  if (out.length > 40) out = out.substring(0, 40);
  return out;
}

/// 导出落点（工作区相对路径）：`exports/<可读名>_<时间戳>.xlsx`。
///
/// 带时间戳是为了「同一会话里连导两张表」不互相覆盖（overwrite 只是兜底）；
/// 表头首格取不到合法字符时回落到「表格」。
String tableExportRelPath(List<String> header, {required int stamp}) {
  final raw = header.isEmpty ? '' : header.first;
  final stem = sanitizeWorkspaceNameSegment(raw);
  return 'exports/${stem.isEmpty ? '表格' : stem}_$stamp.xlsx';
}

/// 单元格行内标记的一段（纯数据，便于单测断言文本顺序与样式标志）。
class CellRun {
  const CellRun(
    this.text, {
    this.isCode = false,
    this.isBold = false,
    this.isItalic = false,
    this.isStrike = false,
    this.linkUrl,
  });

  final String text;
  final bool isCode;
  final bool isBold;
  final bool isItalic;
  final bool isStrike;
  final String? linkUrl;
}

/// 解析单元格内的行内 Markdown → 段列表。
///
/// 支持：`` `code` ``、`[text](url)`、`**粗**`/`__粗__`、`*斜*`/`_斜_`、
/// `~~删除线~~`。**code 段内部不再解析其它标记**（与 CommonMark 一致）。
/// `_x_` 要求前一个字符不是字母/数字/下划线，避免把 `snake_case` 吃掉。
List<CellRun> parseCellRuns(String raw) {
  final runs = <CellRun>[];
  final buf = StringBuffer();
  void flush() {
    if (buf.isNotEmpty) {
      runs.add(CellRun(buf.toString()));
      buf.clear();
    }
  }

  final alnum = RegExp(r'[A-Za-z0-9_]');
  var i = 0;
  while (i < raw.length) {
    // `code`
    if (raw[i] == '`') {
      final end = raw.indexOf('`', i + 1);
      if (end > i + 1) {
        flush();
        runs.add(CellRun(raw.substring(i + 1, end), isCode: true));
        i = end + 1;
        continue;
      }
    }
    // [text](url)
    if (raw[i] == '[') {
      final close = raw.indexOf(']', i + 1);
      if (close > i + 1 && close + 1 < raw.length && raw[close + 1] == '(') {
        final paren = raw.indexOf(')', close + 2);
        if (paren > close + 1) {
          flush();
          runs.add(CellRun(
            raw.substring(i + 1, close),
            linkUrl: raw.substring(close + 2, paren).trim(),
          ));
          i = paren + 1;
          continue;
        }
      }
    }
    // **粗** / __粗__
    if (i + 1 < raw.length &&
        ((raw[i] == '*' && raw[i + 1] == '*') ||
            (raw[i] == '_' && raw[i + 1] == '_'))) {
      final marker = raw.substring(i, i + 2);
      final end = raw.indexOf(marker, i + 2);
      if (end > i + 2) {
        flush();
        runs.add(CellRun(raw.substring(i + 2, end), isBold: true));
        i = end + 2;
        continue;
      }
    }
    // ~~删除线~~
    if (i + 1 < raw.length && raw[i] == '~' && raw[i + 1] == '~') {
      final end = raw.indexOf('~~', i + 2);
      if (end > i + 2) {
        flush();
        runs.add(CellRun(raw.substring(i + 2, end), isStrike: true));
        i = end + 2;
        continue;
      }
    }
    // *斜* / _斜_
    if (raw[i] == '*' || raw[i] == '_') {
      final ch = raw[i];
      final prevOk =
          ch == '*' || i == 0 || !alnum.hasMatch(raw[i - 1]);
      if (prevOk) {
        final end = raw.indexOf(ch, i + 1);
        if (end > i + 1) {
          flush();
          runs.add(CellRun(raw.substring(i + 1, end), isItalic: true));
          i = end + 1;
          continue;
        }
      }
    }
    buf.write(raw[i]);
    i++;
  }
  flush();
  return runs;
}

/// 表格单元格富文本：行内 code/链接/粗斜/删除线。
///
/// 链接可点（走 [LauncherUtils.openExternalUrl]，内部含 URL 归一与生物锁守卫）；
/// 每次 build 重建 recognizer，旧的立即释放，dispose 时兜底清空——防
/// TapGestureRecognizer 泄漏（本项目 B2 教训：controller/recognizer 必须配对释放）。
class RichTableCell extends StatefulWidget {
  const RichTableCell({
    super.key,
    required this.text,
    required this.baseStyle,
    this.textAlign = TextAlign.center,
    this.linkColor,
    this.codeBackground,
  });

  final String text;
  final TextStyle baseStyle;
  final TextAlign textAlign;
  final Color? linkColor;
  final Color? codeBackground;

  @override
  State<RichTableCell> createState() => _RichTableCellState();
}

class _RichTableCellState extends State<RichTableCell> {
  final List<TapGestureRecognizer> _recognizers = <TapGestureRecognizer>[];

  void _releaseRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _releaseRecognizers();
    super.dispose();
  }

  Future<void> _openLink(String url) async {
    try {
      await LauncherUtils.openExternalUrl(url);
    } catch (e) {
      debugPrint('表格链接打开失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    _releaseRecognizers();
    final runs = parseCellRuns(widget.text);
    final spans = <InlineSpan>[];
    for (final run in runs) {
      var style = widget.baseStyle;
      if (run.isCode) {
        style = style.copyWith(
          fontFamily: 'monospace',
          backgroundColor: widget.codeBackground,
          fontSize: (style.fontSize ?? 12) - 1,
        );
      }
      if (run.isBold) style = style.copyWith(fontWeight: FontWeight.w600);
      if (run.isItalic) style = style.copyWith(fontStyle: FontStyle.italic);
      if (run.isStrike) {
        style = style.copyWith(decoration: TextDecoration.lineThrough);
      }
      if (run.linkUrl != null && run.linkUrl!.isNotEmpty) {
        final url = run.linkUrl!;
        final recognizer = TapGestureRecognizer()..onTap = () => _openLink(url);
        _recognizers.add(recognizer);
        spans.add(TextSpan(
          text: run.text,
          style: style.copyWith(
            color: widget.linkColor,
            decoration: TextDecoration.underline,
          ),
          recognizer: recognizer,
        ));
      } else {
        spans.add(TextSpan(text: run.text, style: style));
      }
    }
    if (spans.isEmpty) {
      spans.add(TextSpan(text: '', style: widget.baseStyle));
    }
    return Text.rich(
      TextSpan(children: spans),
      textAlign: widget.textAlign,
    );
  }
}

/// 代码块 builder：顶部 header（语言名 + 复制按钮），下方横向滚动代码区。
class CodeBlockBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => true;

  // 踩坑（v1.7.36 红屏/灰屏根因）：flutter_markdown 0.7.7+1 的 builder.dart
  // 在 visitText 中会无条件为当前块创建 _InlineElement，而 _inlines.clear()
  // 只在 children 非空时执行（line 840）。此处若返回 null → 空内联残留 →
  // build() 结尾 assert(_inlines.isEmpty) 崩溃（debug 红屏 / release 坏树）。
  // 返回零尺寸组件让清理路径正常执行。
  @override
  Widget? visitText(md.Text text, TextStyle? preferredStyle) =>
      const SizedBox.shrink();

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final code = _extractText(element);
    var language = '';
    if (element.children != null && element.children!.isNotEmpty) {
      final first = element.children!.first;
      if (first is md.Element && first.tag == 'code') {
        final cls = first.attributes['class'] ?? '';
        if (cls.startsWith('language-')) {
          language = cls.substring('language-'.length);
        }
      }
    }
    final zh = Localizations.localeOf(context).languageCode == 'zh';

    // 代码块统一深色底（Chatbox 朴素风）：亮/暗主题下都用同一套深色调，
    // 顶栏 = 语言名 + 复制按钮，下方横向滚动代码区。
    const codeBg = Color(0xFF1E1E1E);
    const codeHeaderBg = Color(0xFF2A2A2A);
    const codeFg = Color(0xFFD4D4D4);
    const codeSubFg = Color(0xFF9A9A9A);

    // build104（M5 一期）：文本类代码块可一键「存为文件」到 Nexus_Downloads
    //（文件管理页可见）。二进制类语言不给（只放文本产物）。
    const savableExts = {
      'csv': 'csv', 'md': 'md', 'markdown': 'md', 'html': 'html',
      'txt': 'txt', 'text': 'txt', 'json': 'json', 'xml': 'xml',
      'yaml': 'yaml', 'yml': 'yaml', 'sql': 'sql',
    };
    final ext = savableExts[language.toLowerCase()];

    Future<void> saveAsFile() async {
      try {
        Directory? dir;
        try {
          dir = await getDownloadsDirectory();
        } catch (_) {
          dir = null;
        }
        dir ??= await getApplicationDocumentsDirectory();
        final sub = Directory(
            '${dir.path}${Platform.pathSeparator}Nexus_Downloads');
        if (!await sub.exists()) await sub.create(recursive: true);
        final stamp = DateTime.now().millisecondsSinceEpoch;
        final file = File(
            '${sub.path}${Platform.pathSeparator}nexus_${language.isEmpty ? 'code' : language}_$stamp.$ext');
        await file.writeAsString(code);
        if (!context.mounted) return;
        AppSnackBar.showSnackBar(context, SnackBar(
          content: Text(zh
              ? '已存为文件：${file.path}'
              : 'Saved: ${file.path}'),
          duration: const Duration(seconds: 4),
        ));
      } catch (e) {
        if (!context.mounted) return;
        AppSnackBar.showSnackBar(context, 
          SnackBar(content: Text(zh ? '保存失败：$e' : 'Save failed: $e')),
        );
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: const BoxDecoration(
            color: codeHeaderBg,
            borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  language.isEmpty ? (zh ? '代码' : 'Code') : language,
                  style: const TextStyle(fontSize: 11, color: codeSubFg),
                ),
              ),
              // build157（⑫ 真 P2）：这两键原本只有 `vertical: 4` → 实测约 21-23dp 高，
              // 横向又只隔 3~6dp，误触「存为文件」会在 Nexus_Downloads 真落下一个文件
              // （不是"看错了"，是"改动了磁盘"）。
              // 命中区**只补高度**（`ConstrainedBox(minHeight: 40)`，与
              // `message_action_button` 同一套已验证写法）：横向一个字都没加宽 ⇒
              // 顶栏那条 Row 不会 RENDER OVERFLOWED（横向撑宽的那版已被回退，
              // 见 docs/BUGSCAN_build156_真机反馈.md ⑦「我差点制造的回归」）。
              // 两键之间插 8dp 纯间隔：它只吃上面 Expanded(语言名) 的富余宽度，
              // Expanded 是弹性子节点、吃掉的是剩余空间，主轴自由空间恒 ≥ 0，
              // 所以加这 8dp 不可能把行顶出去（语言名那里最多少出两个字，会换行不会溢出）。
              if (ext != null) ...[
                InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: saveAsFile,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 40),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.save_alt,
                              size: 13, color: codeSubFg),
                          const SizedBox(width: 3),
                          Text(
                            zh ? '存为文件' : 'Save',
                            style: const TextStyle(
                                fontSize: 11, color: codeSubFg),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: code));
                  AppSnackBar.showSnackBar(context, 
                    SnackBar(
                      content: Text(zh ? '已复制代码' : 'Code copied'),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                },
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 40),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.content_copy,
                            size: 13, color: codeSubFg),
                        const SizedBox(width: 3),
                        Text(
                          zh ? '复制' : 'Copy',
                          style: const TextStyle(
                              fontSize: 11, color: codeSubFg),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: const BoxDecoration(
            color: codeBg,
            borderRadius: BorderRadius.vertical(bottom: Radius.circular(8)),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Text(
              code,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: codeFg,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 表格 builder：渲染表格 + 「复制 CSV / 复制 Markdown / 下载 CSV」操作行。
class TableBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => true;

  // 同 CodeBlockBuilder 的踩坑说明：visitText 不能返回 null
  @override
  Widget? visitText(md.Text text, TextStyle? preferredStyle) =>
      const SizedBox.shrink();

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final raw = _extractText(element);
    final lines = raw
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.length < 2) return null;

    final header = splitTableRow(lines[0]);
    // lines[1] 是分隔行，跳过
    final rows = normalizeTableRows(
        lines.skip(2).map(splitTableRow).toList(), header.length);
    final columnCount = header.length;
    final aligns = parseColumnAlignments(lines[1], columnCount);

    final zh = Localizations.localeOf(context).languageCode == 'zh';
    final cs = Theme.of(context).colorScheme;
    final bodyStyle = TextStyle(fontSize: 12, color: cs.onSurface, height: 1.35);
    final headStyle = bodyStyle.copyWith(fontWeight: FontWeight.w600);

    // build117：表头浅底 + 斑马纹 + 1px 全网格 + 圆角（全部走主题派生色，
    // 明暗两套自动成立；规格参考 Chatbox 源码 index.css 的 th/tr:nth-child）。
    final headerBg = cs.surfaceContainerHigh;
    final zebraBg = cs.surfaceContainerHigh.withValues(alpha: 0.45);

    Widget cell(String text,
            {required bool isHeader, TextAlign align = TextAlign.center}) =>
        Container(
          color: isHeader ? headerBg : null,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: RichTableCell(
            text: text,
            baseStyle: isHeader ? headStyle : bodyStyle,
            textAlign: align,
            linkColor: cs.primary,
            codeBackground: cs.surfaceContainerHighest,
          ),
        );

    final btnStyle = TextButton.styleFrom(
      minimumSize: Size.zero,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textStyle: const TextStyle(fontSize: 11),
    );

    void copy(String text, String msg) {
      Clipboard.setData(ClipboardData(text: text));
      AppSnackBar.showSnackBar(context, 
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
      );
    }

    Future<void> downloadCsv() async {
      try {
        // build104 优化：落 Nexus_Downloads（文件管理页「下载与备份」区可见）——
        // 原实现写应用文档根目录，文件管理页三个区块都看不到
        Directory? base;
        try {
          base = await getDownloadsDirectory();
        } catch (_) {
          base = null;
        }
        base ??= await getApplicationDocumentsDirectory();
        final sub = Directory(
            '${base.path}${Platform.pathSeparator}Nexus_Downloads');
        if (!await sub.exists()) await sub.create(recursive: true);
        final file = File(
            '${sub.path}${Platform.pathSeparator}nexus_table_${DateTime.now().millisecondsSinceEpoch}.csv');
        await file.writeAsString(tableToCsv(header, rows));
        if (!context.mounted) return;
        AppSnackBar.showSnackBar(context, 
          SnackBar(
            content: Text(zh ? '已保存：${file.path}' : 'Saved: ${file.path}'),
            duration: const Duration(seconds: 4),
          ),
        );
      } catch (e) {
        if (!context.mounted) return;
        AppSnackBar.showSnackBar(context, 
          SnackBar(content: Text(zh ? '保存失败：$e' : 'Save failed: $e')),
        );
      }
    }

    // ---- build138（§八-4）：长按 → 导出为 Excel（真 xlsx 落工作区 + 分享）----
    //
    // 失败可见化（本项目验收红线）：空表 / 载荷超限 / 生成失败 / 写入失败 /
    // 分享失败**每一条**都走 failExport，SnackBar 带具体原因，绝不静默 return。
    void failExport(String reason) {
      if (!context.mounted) return;
      AppSnackBar.showSnackBar(
        context,
        SnackBar(
          content: Text(zh ? '导出失败：$reason' : 'Export failed: $reason'),
          duration: const Duration(seconds: 5),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }

    Future<void> exportExcel() async {
      try {
        final emptyErr = tableExportError(header, rows);
        if (emptyErr != null) return failExport(emptyErr);
        final parsed = OfficeWriter.parseSheets(
            tableToCsvPayload(header, rows),
            defaultName: '导出表格');
        if (parsed.error != null) return failExport(parsed.error!);
        final (bytes, buildErr) = OfficeWriter.buildXlsx(parsed.sheets);
        if (buildErr != null || bytes == null) {
          return failExport(buildErr ?? 'xlsx 生成失败（未给原因）');
        }
        final rel = tableExportRelPath(header,
            stamp: DateTime.now().millisecondsSinceEpoch);
        final (abs, writeErr) =
            await WorkspaceService.writeBinary(rel, bytes, overwrite: true);
        if (writeErr != null || abs == null) {
          return failExport(writeErr ?? '写入工作区失败（未给原因）');
        }
        // 手动长按是**用户主动动作**：成功后直接拉起系统分享，
        // 不再弹 AI 那条写文件确认框（那是给模型驱动写入兜底的）。
        final shareErr = await WorkspaceService.share(rel);
        if (!context.mounted) return;
        AppSnackBar.showSnackBar(
          context,
          SnackBar(
            content: Text(shareErr == null
                ? (zh
                    ? '已导出 $rel，正在分享'
                    : 'Exported $rel, opening share sheet')
                : (zh
                    ? '已导出 $rel，但系统分享没起来：$shareErr\n可在「文件管理 → AI 工作区」里打开它'
                    : 'Exported $rel, but sharing failed: $shareErr\n'
                        'Find it under Files → AI workspace')),
            duration: const Duration(seconds: 5),
            behavior: SnackBarBehavior.floating,
          ),
        );
      } catch (e) {
        failExport('导出异常：$e');
      }
    }

    Future<void> showTableMenu() async {
      // SB-3：同类弹层防叠（长按连点只开一层）
      if (!GuardedOverlay.tryEnter('table_sheet')) return;
      try {
        final action = await showAppSheet<String>(
          context: context,
          scrollable: true,
          builder: (sctx) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppSheetHeader(
                  title: zh ? '表格操作' : 'Table actions',
                  subtitle: zh
                      ? '「导出为 Excel」生成真 .xlsx 文件放进 AI 工作区并拉起分享'
                      : 'Export as Excel writes a real .xlsx into the AI workspace'),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ListTile(
                        leading:
                            Icon(Icons.grid_on_outlined, color: cs.primary),
                        title: Text(zh ? '导出为 Excel' : 'Export as Excel'),
                        onTap: () => Navigator.pop(sctx, 'excel'),
                      ),
                      ListTile(
                        leading: const Icon(Icons.copy_outlined),
                        title: Text(zh ? '复制 CSV' : 'Copy CSV'),
                        onTap: () => Navigator.pop(sctx, 'copy_csv'),
                      ),
                      ListTile(
                        leading: Icon(Icons.close, color: cs.onSurfaceVariant),
                        title: Text(zh ? '取消' : 'Cancel'),
                        onTap: () => Navigator.pop(sctx),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
        switch (action) {
          case 'excel':
            await exportExcel();
            break;
          case 'copy_csv':
            copy(tableToCsv(header, rows), zh ? '已复制 CSV' : 'CSV copied');
            break;
        }
      } finally {
        GuardedOverlay.exit('table_sheet');
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 宽表横向滚动（移动端事实标准：压缩列宽会导致文字竖排换行）。
        // IntrinsicColumnWidth 让列按内容撑开，**不用** FlexColumnWidth 压扁。
        // build138（§八-4）：长按整张表 → 操作菜单（首项「导出为 Excel」）。
        GestureDetector(
          behavior: HitTestBehavior.deferToChild,
          onLongPress: showTableMenu,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Table(
              defaultColumnWidth: const IntrinsicColumnWidth(),
              border: TableBorder.all(
                color: cs.outlineVariant,
                width: 1.0,
                borderRadius: BorderRadius.circular(10),
              ),
              children: [
                TableRow(
                  children: [
                    for (var i = 0; i < columnCount; i++)
                      cell(header[i], isHeader: true, align: aligns[i]),
                  ],
                ),
                for (var r = 0; r < rows.length; r++)
                  TableRow(
                    decoration: r.isOdd
                        ? BoxDecoration(color: zebraBg)
                        : null,
                    children: [
                      for (var i = 0; i < columnCount; i++)
                        cell(rows[r][i], isHeader: false, align: aligns[i]),
                    ],
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 2),
        // 长按菜单的**可见等价入口**：气泡 selectable 为真时长按会被文本选择
        // 抢走手势，只靠长按等于没有入口（本项目反复踩过「能力有、触发点无」）。
        // 用 Wrap 而非 Row：四个按钮在小屏气泡里必须能换行，否则溢出成花屏。
        Wrap(
          children: [
            TextButton(
              style: btnStyle,
              onPressed: exportExcel,
              child: Text(zh ? '导出 Excel' : 'Export Excel'),
            ),
            TextButton(
              style: btnStyle,
              onPressed: () => copy(
                  tableToCsv(header, rows), zh ? '已复制 CSV' : 'CSV copied'),
              child: Text(zh ? '复制 CSV' : 'Copy CSV'),
            ),
            TextButton(
              style: btnStyle,
              onPressed: () => copy(tableToMarkdown(header, rows),
                  zh ? '已复制 Markdown' : 'Markdown copied'),
              child: Text(zh ? '复制 Markdown' : 'Copy Markdown'),
            ),
            TextButton(
              style: btnStyle,
              onPressed: downloadCsv,
              child: Text(zh ? '下载 CSV' : 'Download CSV'),
            ),
          ],
        ),
      ],
    );
  }
}
