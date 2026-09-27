/// B1 只读查看器：定高行 + ListView.builder 惰性构建，语法高亮按 token 上色。
/// 横向滚动范围用「单元格」估算（ASCII 1 格、其余 2 格），不做真实排版。
/// 每行 = 一个 Text.rich（行号 span 并入段落），行号底色由底层通栏绘制，
/// 不在每行单独开 Container——行构件越少，滚动帧的 build/raster 越低。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'syntax_highlight.dart';
import 'workbench_theme.dart';

class FileDocument {
  FileDocument._({
    required this.path,
    required this.lines,
    required this.tokens,
    required this.byteCount,
    required this.loadMs,
    required this.tokenizeMs,
    required this.maxLineCells,
  });

  final String path;
  final List<String> lines;

  /// 逐行 token；非 .dart 文件为 null（纯文本渲染）。
  final List<LineTokens>? tokens;
  final int byteCount;

  /// 读盘+解码耗时 / 高亮扫描耗时（bench 直出这两个数）。
  final int loadMs;
  final int tokenizeMs;

  /// 全文件最大行宽（单元格），横向滚动范围估算用。
  final int maxLineCells;

  static Future<FileDocument> load(String path) async {
    final sw = Stopwatch()..start();
    final bytes = await File(path).readAsBytes();
    var text = utf8.decode(bytes, allowMalformed: true);
    // UTF-8 BOM 剥掉再显示（用 codeUnit 比较，源码里不放不可见字符）。
    if (text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF) {
      text = text.substring(1);
    }
    final lines = text.split('\n');
    final loadMs = sw.elapsedMilliseconds;

    sw.reset();
    final isDart = path.toLowerCase().endsWith('.dart');
    final tokens = isDart ? tokenizeDart(text) : null;
    var maxCells = 0;
    for (final line in lines) {
      final c = displayCells(line);
      if (c > maxCells) maxCells = c;
    }
    final tokenizeMs = sw.elapsedMilliseconds;

    return FileDocument._(
      path: path,
      lines: lines,
      tokens: tokens,
      byteCount: bytes.length,
      loadMs: loadMs,
      tokenizeMs: tokenizeMs,
      maxLineCells: maxCells,
    );
  }
}

/// token → 颜色。按主题明暗两套，别硬编 Material 调色板对象。
class CodePalette {
  const CodePalette({
    required this.keyword,
    required this.string,
    required this.comment,
    required this.number,
    required this.ident,
    required this.punct,
    required this.gutter,
    required this.lineNo,
  });

  final Color keyword;
  final Color string;
  final Color comment;
  final Color number;
  final Color ident;
  final Color punct;
  final Color gutter;
  final Color lineNo;

  static CodePalette of(Brightness b) => b == Brightness.dark
      ? const CodePalette(
          keyword: WbSyntax.darkKeyword,
          string: WbSyntax.darkString,
          comment: WbSyntax.darkComment,
          number: WbSyntax.darkNumber,
          ident: WbSyntax.darkIdent,
          punct: WbSyntax.darkPunct,
          gutter: WbSyntax.darkGutter,
          lineNo: WbSyntax.darkLineNo,
        )
      : const CodePalette(
          keyword: WbSyntax.lightKeyword,
          string: WbSyntax.lightString,
          comment: WbSyntax.lightComment,
          number: WbSyntax.lightNumber,
          ident: WbSyntax.lightIdent,
          punct: WbSyntax.lightPunct,
          gutter: WbSyntax.lightGutter,
          lineNo: WbSyntax.lightLineNo,
        );

  Color colorOf(TokType t) => switch (t) {
        TokType.keyword => keyword,
        TokType.string => string,
        TokType.comment => comment,
        TokType.number => number,
        TokType.ident => ident,
        TokType.punct => punct,
      };
}

/// 一行 → 行号 span + 代码 span 列表（行号右对齐用空格补齐，等宽字体下宽度恒定）。
/// tokenizer 不给空白出 token，token 间隙必须由这里按原文补回——
/// 否则渲染出来的行会丢掉缩进与空格（拼接结果必须恒等于 行号+间隙+原文）。
List<InlineSpan> buildLineSpans({
  required String line,
  required LineTokens? toks,
  required CodePalette palette,
  required int lineNumber,
  required int gutterDigits,
}) {
  final spans = <InlineSpan>[
    TextSpan(
      text: '${'$lineNumber'.padLeft(gutterDigits)}  ',
      style: TextStyle(color: palette.lineNo),
    ),
  ];
  if (toks == null || line.isEmpty) {
    spans.add(TextSpan(text: line, style: TextStyle(color: palette.ident)));
    return spans;
  }
  var pos = 0;
  for (final t in toks.toks) {
    final end = t.end > line.length ? line.length : t.end;
    if (t.start >= end) continue;
    if (t.start > pos) {
      spans.add(TextSpan(
          text: line.substring(pos, t.start),
          style: TextStyle(color: palette.ident)));
    }
    spans.add(TextSpan(
        text: line.substring(t.start, end),
        style: TextStyle(color: palette.colorOf(t.type))));
    pos = end;
  }
  if (pos < line.length) {
    spans.add(TextSpan(
        text: line.substring(pos), style: TextStyle(color: palette.ident)));
  }
  return spans;
}

class FileViewer extends StatefulWidget {
  const FileViewer({super.key, required this.document, this.scrollController});

  final FileDocument document;
  final ScrollController? scrollController;

  @override
  State<FileViewer> createState() => _FileViewerState();
}

class _FileViewerState extends State<FileViewer> {
  static const _codeStyle = WbText.code13;

  double _cellWidth = 7.0;
  double _lineHeight = 18.0;

  /// 行 span 缓存：来回滚动时同一行不重切 substring。
  /// 上限防 67k 行整卷到底后缓存无限胀；清空了只是重算，不影响正确性。
  static const int _spanCacheCap = 20000;
  final Map<int, List<InlineSpan>> _spanCache = {};
  CodePalette? _cachePalette;
  int _cacheGutterDigits = 0;

  @override
  void didUpdateWidget(FileViewer old) {
    super.didUpdateWidget(old);
    if (!identical(old.document, widget.document)) _spanCache.clear();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 等宽字体的真实单格宽度与行高，按当前 textScaler 实测。
    final tp = TextPainter(
      text: const TextSpan(text: '0', style: _codeStyle),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    _cellWidth = tp.width;
    _lineHeight = tp.height > 0 ? tp.height : 18.0;
    tp.dispose();
  }

  List<InlineSpan> _spansForLine(int i, CodePalette palette, int gutterDigits) {
    if (!identical(palette, _cachePalette) ||
        gutterDigits != _cacheGutterDigits) {
      _spanCache.clear();
      _cachePalette = palette;
      _cacheGutterDigits = gutterDigits;
    }
    return _spanCache.putIfAbsent(i, () {
      if (_spanCache.length >= _spanCacheCap) _spanCache.clear();
      return buildLineSpans(
        line: widget.document.lines[i],
        toks: widget.document.tokens?[i],
        palette: palette,
        lineNumber: i + 1,
        gutterDigits: gutterDigits,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final doc = widget.document;
    final palette = CodePalette.of(Theme.of(context).brightness);
    final gutterDigits = doc.lines.length.toString().length;
    // 代码起点 x = 8 左垫 + (行号位数+2) 格；行号底色通栏与之同宽，右缘正好相接。
    final gutterWidth = 8 + (gutterDigits + 2) * _cellWidth;
    final contentWidth = gutterWidth + doc.maxLineCells * _cellWidth + 40;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: contentWidth,
        child: Stack(
          children: [
            // 行号底色通栏：横向随内容滚（与旧版逐行 Container 行为一致），
            // 纵向不动，只画一条而不是每行一个 Container。
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: gutterWidth,
              child: ColoredBox(color: palette.gutter),
            ),
            ListView.builder(
              controller: widget.scrollController,
              itemCount: doc.lines.length,
              itemExtent: _lineHeight,
              itemBuilder: (context, i) {
                return Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text.rich(
                    TextSpan(
                      style: _codeStyle,
                      children: _spansForLine(i, palette, gutterDigits),
                    ),
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.clip,
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
