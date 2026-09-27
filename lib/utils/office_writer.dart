import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:archive/archive.dart';
import 'package:aichat/services/attachment_service.dart';
import 'package:flutter/foundation.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

/// build138（G61/G62/G64）：工作区「真文件」生成器 —— xlsx / docx / pdf。
///
/// 为什么自己写而不是引 `excel`/`docx` 包：本沙箱只通 api.github.com，
/// pub.dev 不可达 ⇒ 无法新增依赖。而 [archive]（ZIP 编解码）与
/// [syncfusion_flutter_pdf]（PDF 读写）本来就是既有依赖，OOXML 又只是
/// 「一个 ZIP + 若干 XML」，所以这里直接产出**符合 ECMA-376 最小集**的包，
/// 文件头为 `PK`，解压即得 `xl/worksheets/sheet1.xml` / `word/document.xml`。
///
/// 三条硬约束（对应任务书红线）：
/// 1. **载荷只有文本**。schema 里没有 base64 / 二进制字段（G64），
///    因此本文件所有入口接收的都是字符串，由 [_checkPayload] 把关；
///    3000 字符的 base64 串会被结构性拒绝，而不是被当作文本塞进单元格。
/// 2. **不做 HTML 伪装**。没有 `.xls`/`.doc` 分支，也没有任何
///    `<html>`/`<table>` 拼串路径 —— 兜底格式只允许 `.csv`（见
///    [OfficeWriter.supportedExtensions]）。
/// 3. **失败要可见**。所有入口返回 `(bytes, error)`，超限/非法名/无字体
///    都给可读原因；调用方（ws_make_file）拿到 error 必须回灌给模型，
///    不许「静默写成文本文件」。
class OfficeWriter {
  OfficeWriter._();

  /// 生成类扩展名白名单（G64：兜底只允许 csv，这里连 html 都不收）
  static const Set<String> supportedExtensions = {
    'xlsx', 'docx', 'pdf', 'csv', 'md', 'txt',
  };

  // ===== 载荷上限（内存与手机上的一致性优先于「大而全」） =====
  static const int maxPayloadChars = 16000;
  static const int maxSheets = 12;
  static const int maxRowsPerSheet = 5000;
  static const int maxColsPerRow = 100;
  static const int maxTotalCells = 50000;
  static const int maxBlocks = 2000;
  static const int maxCellChars = 2000;
  static const int maxBinaryBytes = 10 * 1024 * 1024;

  /// base64 红线的判定长度：单元格/段落里出现这么长的一段
  /// 「纯 base64 字符集、无空格」的串，即判为「模型想把二进制塞进文本通道」。
  static const int maxBase64TokenChars = 512;

  static final RegExp _b64Token =
      RegExp(r'^[A-Za-z0-9+/]{512,}={0,2}$', multiLine: false);

  /// 生成目标解析（纯函数，可单测）：kind 与 path 归一 + G64 红线校验。
  ///
  /// 规则：
  /// - `kind` 与 `path` 的扩展名必须一致（都给了却不一样 ⇒ 拒绝，避免出现
  ///   「kind=xlsx 但文件名 .xls」这种必然打不开的产物）；
  /// - 老格式 / 压缩包（xls/doc/ppt/zip/html…）一律拒绝，**兜底只有 csv**；
  /// - 二进制产物统一落到 `exports/` 下（真机回归要看的就是这个目录里的文件
  ///   杀进程后仍可分享）；
  /// - 没给文件名时按类型生成默认名。
  static ({String kind, String rel, String? error}) resolveTarget({
    String path = '',
    String kind = '',
  }) {
    final k0 = kind.trim().toLowerCase();
    final e0 = _extOfName(path);
    var k = k0.isNotEmpty ? k0 : e0;
    if (k.isEmpty) {
      return (kind: '', rel: path, error: '必须给出 kind（xlsx/docx/pdf/csv/md/txt）'
          '或带扩展名的 path。');
    }
    if (e0.isNotEmpty && k0.isNotEmpty && e0 != k) {
      return (
        kind: k,
        rel: path,
        error: 'kind=$k 与文件名扩展名 .$e0 不一致，已拒绝。'
      );
    }
    if (_fakeExtensions.contains(k)) {
      return (
        kind: k,
        rel: path,
        error: '不支持生成 .$k（App 里没有该格式的生成器，硬写只会产出'
            '打不开的假文件）。表格用 .xlsx，纯数据兜底用 .csv，'
            '文档用 .docx / .md / .pdf。'
      );
    }
    if (!supportedExtensions.contains(k)) {
      return (kind: k, rel: path, error: '不支持的生成类型 .$k');
    }
    var rel = path.trim();
    if (rel.isEmpty) {
      rel = 'exports/生成文件.$k';
    } else {
      if (e0.isEmpty) rel = '$rel.$k';
      if (_binaryKinds.contains(k) && !rel.contains('/')) {
        rel = 'exports/$rel';
      }
    }
    return (kind: k, rel: rel, error: null);
  }

  static const Set<String> _binaryKinds = {'xlsx', 'docx', 'pdf'};

  /// 明确拒绝的「伪装/旧格式」名单（G64：HTML 伪装 .xls 的老路）。
  static const Set<String> _fakeExtensions = {
    'xls', 'doc', 'ppt', 'pptx', 'html', 'htm', 'zip', 'rar', '7z',
    'exe', 'dll', 'bin', 'dat', 'scr',
  };

  static String _extOfName(String name) {
    final base = name.split(RegExp(r'[/\\]')).last;
    final i = base.lastIndexOf('.');
    if (i <= 0 || i == base.length - 1) return '';
    return base.substring(i + 1).toLowerCase();
  }

  // -------------------------------------------------------------------------
  // 载荷解析（文本 → 结构）
  // -------------------------------------------------------------------------

  /// 校验载荷本身（体积 + base64 红线）。返回 null 表示通过。
  static String? checkPayload(String content) {
    if (content.trim().isEmpty) return '内容为空，没有可写入的数据。';
    if (content.length > maxPayloadChars) {
      return '内容超限（${content.length} 字符 > $maxPayloadChars）。'
          '请分批生成，或先 ws_write 写 csv 再本地转换。';
    }
    return rejectBinaryPayload(content);
  }

  /// G64 红线：文本通道里不接受 base64 / 十六进制大块。
  ///
  /// 只对「无空白」的长串生效：中文表头、英文句子、带空格的段落都不会误伤，
  /// 而模型把图片/base64 直接塞进单元格的那一类误用一定会命中（它的特征就是
  /// 一整串无空白的 [A-Za-z0-9+/] 且长度为 4 的倍数）。
  static String? rejectBinaryPayload(String content) {
    for (final token in content.split(RegExp(r'[\s,;\t]+'))) {
      if (token.length < maxBase64TokenChars) continue;
      if (_b64Token.hasMatch(token)) {
        return '拒绝疑似 base64/二进制大块（$maxBase64TokenChars 字符以上的连续 '
            'base64 串）。本工具只接受文本数据；图片等二进制请走附件上传，'
            '不要塞进单元格或段落。';
      }
    }
    return null;
  }

  /// 表格载荷 → 多 sheet。
  ///
  /// 语法：一行一条记录；列用制表符或逗号分隔（带引号的 CSV 字段可含逗号）。
  /// 以 `## sheet: 名称` 开头的行切换工作表（可省，缺省单表）。
  static ({List<OfficeSheet> sheets, String? error}) parseSheets(
    String content, {
    String defaultName = 'Sheet1',
  }) {
    final err = checkPayload(content);
    if (err != null) return (sheets: const [], error: err);
    final sheets = <OfficeSheet>[];
    var name = defaultName;
    final chunk = <String>[];
    var cells = 0;

    ({bool ok, String? error}) flush() {
      if (chunk.isEmpty) return (ok: true, error: null);
      // 与工作区 .csv 兜底**同源**：一律用 App 现成的 CSV 解析器
      //（分隔符自动判定、双引号转义、BOM、\r\n 都在这一个实现里）。
      // 这样「生成 xlsx」与「同样内容落成 csv」得到的是同一张表，
      // 不会出现 xlsx 正常、兜底 csv 串列的分裂口径。
      final rows = AttachmentService.parseCsv(chunk.join('\n'));
      chunk.clear();
      if (rows.isEmpty) return (ok: true, error: null);
      for (final r in rows) {
        if (r.length > maxColsPerRow) {
          return (
            ok: false,
            error: '单行列数超限（${r.length} > $maxColsPerRow）',
          );
        }
        for (final c in r) {
          if (c.length > maxCellChars) {
            return (
              ok: false,
              error: '单元格内容超限（${c.length} > $maxCellChars 字符）',
            );
          }
          if (++cells > maxTotalCells) {
            return (ok: false, error: '单元格总数超限（≤$maxTotalCells）');
          }
        }
      }
      if (rows.length > maxRowsPerSheet) {
        return (ok: false, error: '单表行数超限（≤$maxRowsPerSheet）');
      }
      sheets.add(OfficeSheet(name: name, rows: rows));
      return (ok: true, error: null);
    }

    for (final raw in const LineSplitter().convert(content)) {
      final t = raw.trim();
      if (t.isEmpty) continue;
      final sm = _sheetMarker.firstMatch(t);
      if (sm != null) {
        final (:ok, :error) = flush();
        if (!ok) return (sheets: const [], error: error);
        name = sm.group(1)!.trim();
        if (sheets.length + 1 > maxSheets) {
          return (sheets: const [], error: '工作表数量超限（≤$maxSheets）');
        }
        continue;
      }
      chunk.add(raw.trimRight());
    }
    final (:ok, :error) = flush();
    if (!ok) return (sheets: const [], error: error);
    if (sheets.isEmpty) {
      return (sheets: const [], error: '未解析出任何数据行。');
    }
    return (sheets: sheets, error: null);
  }

  static final RegExp _sheetMarker =
      RegExp(r'^#{1,3}\s*sheet\s*[:：]\s*(.+)$', caseSensitive: false);

  /// 文档载荷（markdown 风格）→ 块序列。
  ///
  /// `#`/`##`/`###` 为标题，`|a|b|` 连续行为表格（`|---|---|` 分隔行丢弃），
  /// 其余为段落。
  static ({List<DocBlock> blocks, String? error}) parseBlocks(String content) {
    final err = checkPayload(content);
    if (err != null) return (blocks: const [], error: err);
    final blocks = <DocBlock>[];
    final tableBuf = <List<String>>[];
    void flushTable() {
      if (tableBuf.isEmpty) return;
      blocks.add(DocBlock.table(tableBuf.map((r) => List.of(r)).toList()));
      tableBuf.clear();
    }

    for (final raw in const LineSplitter().convert(content)) {
      final line = raw.trimRight();
      final t = line.trim();
      if (t.isEmpty) {
        flushTable();
        continue;
      }
      if (t.startsWith('|')) {
        if (_isTableSeparator(t)) continue;
        final row = splitTableRow(t);
        if (row.length > maxColsPerRow) {
          return (
            blocks: const [],
            error: '表格列数超限（${row.length} > $maxColsPerRow）',
          );
        }
        tableBuf.add(row);
        continue;
      }
      flushTable();
      final hm = RegExp(r'^(#{1,3})\s+(.*)$').firstMatch(t);
      if (hm != null) {
        final level = hm.group(1)!.length;
        final text = hm.group(2)!.trim();
        blocks.add(level == 1
            ? DocBlock.h1(text)
            : level == 2
                ? DocBlock.h2(text)
                : DocBlock.h3(text));
        continue;
      }
      blocks.add(DocBlock.para(t));
      if (blocks.length > maxBlocks) {
        return (blocks: const [], error: '段落数超限（≤$maxBlocks）');
      }
    }
    flushTable();
    if (blocks.isEmpty) return (blocks: const [], error: '未解析出任何内容。');
    return (blocks: blocks, error: null);
  }

  static bool _isTableSeparator(String trimmed) =>
      RegExp(r'^\|[\s\-:|]+\|?$').hasMatch(trimmed) && trimmed.contains('-');

  static List<String> splitTableRow(String line) {
    var s = line;
    if (s.startsWith('|')) s = s.substring(1);
    if (s.endsWith('|')) s = s.substring(0, s.length - 1);
    return s
        .split('|')
        .map((c) => c.trim())
        .toList(growable: false);
  }

  // -------------------------------------------------------------------------
  // xlsx
  // -------------------------------------------------------------------------

  /// 生成真 xlsx（OOXML SpreadsheetML 最小集：ZIP + 4 类部件，字符串走
  /// `inlineStr`，数字走 `<v>`；不含 styles.xml，Excel/WPS 均按默认样式打开）。
  static (List<int>?, String?) buildXlsx(List<OfficeSheet> sheets) {
    if (sheets.isEmpty) return (null, '没有可写入的工作表。');
    final names = <String>[];
    final sanitized = <OfficeSheet>[];
    for (final s in sheets) {
      final n = sanitizeSheetName(s.name, names);
      names.add(n.toLowerCase());
      sanitized.add(OfficeSheet(name: n, rows: s.rows));
    }

    final arch = Archive();
    void add(String name, String xml) {
      final b = utf8.encode(xml);
      arch.addFile(ArchiveFile(name, b.length, b));
    }

    final ct = StringBuffer()
      ..write(_xmlDecl)
      ..write('<Types xmlns="http://schemas.openxmlformats.org/'
          'package/2006/content-types">')
      ..write('<Default Extension="rels" ContentType="application/'
          'vnd.openxmlformats-package.relationships+xml"/>')
      ..write('<Default Extension="xml" ContentType="application/xml"/>')
      ..write('<Override PartName="/xl/workbook.xml" ContentType='
          '"application/vnd.openxmlformats-officedocument.'
          'spreadsheetml.sheet.main+xml"/>');
    for (var i = 1; i <= sanitized.length; i++) {
      ct.write('<Override PartName="/xl/worksheets/sheet$i.xml" ContentType='
          '"application/vnd.openxmlformats-officedocument.'
          'spreadsheetml.worksheet+xml"/>');
    }
    ct.write('</Types>');
    add('[Content_Types].xml', ct.toString());

    add(
        '_rels/.rels',
        '$_xmlDecl<Relationships xmlns="http://schemas.openxmlformats.org/'
            'package/2006/relationships"><Relationship Id="rId1" Type='
            '"http://schemas.openxmlformats.org/officeDocument/2006/'
            'relationships/officeDocument" Target="xl/workbook.xml"/>'
            '</Relationships>');

    final wb = StringBuffer()
      ..write(_xmlDecl)
      ..write('<workbook xmlns="http://schemas.openxmlformats.org/'
          'spreadsheetml/2006/main" xmlns:r="http://schemas.'
          'openxmlformats.org/officeDocument/2006/relationships">')
      ..write('<sheets>');
    for (var i = 1; i <= sanitized.length; i++) {
      wb.write('<sheet name="${escAttr(sanitized[i - 1].name)}" sheetId="$i" '
          'r:id="rId$i"/>');
    }
    wb.write('</sheets></workbook>');
    add('xl/workbook.xml', wb.toString());

    final wbRels = StringBuffer()
      ..write(_xmlDecl)
      ..write('<Relationships xmlns="http://schemas.openxmlformats.org/'
          'package/2006/relationships">');
    for (var i = 1; i <= sanitized.length; i++) {
      wbRels.write('<Relationship Id="rId$i" Type="http://schemas.'
          'openxmlformats.org/officeDocument/2006/relationships/worksheet" '
          'Target="worksheets/sheet$i.xml"/>');
    }
    wbRels.write('</Relationships>');
    add('xl/_rels/workbook.xml.rels', wbRels.toString());

    for (var i = 1; i <= sanitized.length; i++) {
      add('xl/worksheets/sheet$i.xml', _sheetXml(sanitized[i - 1]));
    }

    return _zip(arch, 'xlsx');
  }

  static String _sheetXml(OfficeSheet sheet) {
    final buf = StringBuffer()
      ..write(_xmlDecl)
      ..write('<worksheet xmlns="http://schemas.openxmlformats.org/'
          'spreadsheetml/2006/main">');
    // 列宽：按该列最长内容给一个可读宽度（中文按 2 字宽估算）。
    var maxCols = 0;
    for (final r in sheet.rows) {
      if (r.length > maxCols) maxCols = r.length;
    }
    if (maxCols > 0) {
      final widths = List<int>.filled(maxCols, 8);
      for (final r in sheet.rows) {
        for (var c = 0; c < r.length; c++) {
          final w = _displayWidth(r[c]);
          if (w + 2 > widths[c]) widths[c] = _clamp(w + 2, 8, 60);
        }
      }
      buf.write('<cols>');
      for (var c = 0; c < maxCols; c++) {
        buf.write('<col min="${c + 1}" max="${c + 1}" width="${widths[c]}" '
            'customWidth="1"/>');
      }
      buf.write('</cols>');
    }
    buf.write('<sheetData>');
    for (var r = 0; r < sheet.rows.length; r++) {
      final row = sheet.rows[r];
      buf.write('<row r="${r + 1}">');
      for (var c = 0; c < row.length; c++) {
        buf.write(_cellXml('${_colRef(c)}${r + 1}', row[c]));
      }
      buf.write('</row>');
    }
    buf.write('</sheetData></worksheet>');
    return buf.toString();
  }

  static String _cellXml(String ref, String value) {
    final v = sanitizeText(value);
    if (v.isEmpty) return '<c r="$ref"/>';
    final asNum = double.tryParse(v);
    if (asNum != null && asNum.isFinite) {
      return '<c r="$ref"><v>$v</v></c>';
    }
    return '<c r="$ref" t="inlineStr"><is>'
        '<t xml:space="preserve">${escText(v)}</t></is></c>';
  }

  /// 0 → A，25 → Z，26 → AA（Excel 是双射 26 进制：没有「0 位」）
  @visibleForTesting
  static String colRef(int index) {
    if (index < 0) return 'A';
    var n = index + 1;
    final rev = StringBuffer();
    while (n > 0) {
      final rem = (n - 1) % 26;
      rev.write(String.fromCharCode(65 + rem));
      n = (n - 1) ~/ 26;
    }
    // 先算出的是低位，倒过来才是列名
    return String.fromCharCodes(rev.toString().runes.toList().reversed);
  }

  static String _colRef(int index) => colRef(index);

  /// sheet 名合规化：去 `[]:*?/\`、裁到 31 字、重名追加 `(2)`。
  @visibleForTesting
  static String sanitizeSheetName(String raw, List<String> taken) {
    var n = sanitizeText(raw).replaceAll(RegExp(r'[\[\]:*?/\\]'), '').trim();
    if (n.startsWith("'") || n.endsWith("'")) {
      n = n.replaceAll("'", '').trim();
    }
    if (n.isEmpty) n = 'Sheet';
    if (n.length > 31) n = n.substring(0, 31);
    final base = n;
    var i = 2;
    while (taken.contains(n.toLowerCase())) {
      final suffix = '($i)';
      final cut = _clamp(31 - suffix.length, 0, base.length);
      n = '${base.substring(0, cut)}$suffix';
      i++;
      if (i > 999) {
        final tail = '-${DateTime.now().microsecondsSinceEpoch % 100000}';
        n = '${base.substring(0, _clamp(31 - tail.length, 0, base.length))}'
            '$tail';
        break;
      }
    }
    return n;
  }

  // -------------------------------------------------------------------------
  // docx
  // -------------------------------------------------------------------------

  /// 生成真 docx（WordprocessingML 最小集：`word/document.xml` + 一个只含
  /// Normal/Heading1-3/TableGrid 的 `word/styles.xml`）。
  static (List<int>?, String?) buildDocx(List<DocBlock> blocks,
      {String? title}) {
    if (blocks.isEmpty) return (null, '没有可写入的内容。');
    final arch = Archive();
    void add(String name, String xml) {
      final b = utf8.encode(xml);
      arch.addFile(ArchiveFile(name, b.length, b));
    }

    add(
        '[Content_Types].xml',
        '$_xmlDecl<Types xmlns="http://schemas.openxmlformats.org/package/'
            '2006/content-types"><Default Extension="rels" ContentType='
            '"application/vnd.openxmlformats-package.relationships+xml"/>'
            '<Default Extension="xml" ContentType="application/xml"/>'
            '<Override PartName="/word/document.xml" ContentType="application/'
            'vnd.openxmlformats-officedocument.wordprocessingml.document.'
            'main+xml"/><Override PartName="/word/styles.xml" ContentType='
            '"application/vnd.openxmlformats-officedocument.wordprocessingml.'
            'styles+xml"/></Types>');
    add(
        '_rels/.rels',
        '$_xmlDecl<Relationships xmlns="http://schemas.openxmlformats.org/'
            'package/2006/relationships"><Relationship Id="rId1" Type="http://'
            'schemas.openxmlformats.org/officeDocument/2006/relationships/'
            'officeDocument" Target="word/document.xml"/></Relationships>');
    add(
        'word/_rels/document.xml.rels',
        '$_xmlDecl<Relationships xmlns="http://schemas.openxmlformats.org/'
            'package/2006/relationships"><Relationship Id="rId1" Type="http://'
            'schemas.openxmlformats.org/officeDocument/2006/relationships/'
            'styles" Target="styles.xml"/></Relationships>');
    add('word/styles.xml', _docxStylesXml);

    final body = StringBuffer();
    if (title != null && title.trim().isNotEmpty) {
      body.write(_docxPara(sanitizeText(title), style: 'Title'));
    }
    for (final b in blocks) {
      switch (b.kind) {
        case DocBlockKind.h1:
          body.write(_docxPara(sanitizeText(b.text), style: 'Heading1'));
          break;
        case DocBlockKind.h2:
          body.write(_docxPara(sanitizeText(b.text), style: 'Heading2'));
          break;
        case DocBlockKind.h3:
          body.write(_docxPara(sanitizeText(b.text), style: 'Heading3'));
          break;
        case DocBlockKind.para:
          body.write(_docxPara(sanitizeText(b.text)));
          break;
        case DocBlockKind.table:
          body.write(_docxTable(b.rows));
          break;
      }
    }
    // Word 规定文档体不能以表格收尾，补一个空段。
    body.write('<w:p/>');
    add(
        'word/document.xml',
        '$_xmlDecl<w:document xmlns:w="http://schemas.openxmlformats.org/'
            'wordprocessingml/2006/main"><w:body>$body</w:body>'
            '</w:document>');

    return _zip(arch, 'docx');
  }

  static String _docxPara(String text, {String? style}) {
    final pr = style == null ? '' : '<w:pPr><w:pStyle w:val="$style"/></w:pPr>';
    return '<w:p>$pr<w:r><w:t xml:space="preserve">${escText(text)}</w:t>'
        '</w:r></w:p>';
  }

  static String _docxTable(List<List<String>> rows) {
    if (rows.isEmpty) return '';
    final cols = rows.fold<int>(0, (m, r) => r.length > m ? r.length : m);
    final cellW = (9360 ~/ (cols == 0 ? 1 : cols)).toString();
    final buf = StringBuffer('<w:tbl><w:tblPr><w:tblStyle w:val="TableGrid"/>'
        '<w:tblW w:w="0" w:type="auto"/><w:tblBorders>');
    for (final side in ['top', 'left', 'bottom', 'right', 'insideH', 'insideV']) {
      buf.write('<w:$side w:val="single" w:sz="4" w:space="0" w:color="999999"/>');
    }
    buf.write('</w:tblBorders><w:tblLayout w:type="fixed"/></w:tblPr>'
        '<w:tblGrid>');
    for (var c = 0; c < cols; c++) {
      buf.write('<w:gridCol w:w="$cellW"/>');
    }
    buf.write('</w:tblGrid>');
    for (var r = 0; r < rows.length; r++) {
      buf.write('<w:tr>');
      for (var c = 0; c < cols; c++) {
        final v = c < rows[r].length ? sanitizeText(rows[r][c]) : '';
        final bold = r == 0 ? '<w:rPr><w:b/></w:rPr>' : '';
        buf.write('<w:tc><w:tcPr><w:tcW w:w="$cellW" w:type="dxa"/></w:tcPr>'
            '<w:p><w:r>$bold<w:t xml:space="preserve">${escText(v)}</w:t>'
            '</w:r></w:p></w:tc>');
      }
      buf.write('</w:tr>');
    }
    buf.write('</w:tbl>');
    return buf.toString();
  }

  static String get _docxStylesXml =>
      '$_xmlDecl<w:styles xmlns:w="http://schemas.openxmlformats.org/'
      'wordprocessingml/2006/main">'
      '<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" '
      'w:eastAsia="宋体" w:hAnsi="Calibri"/><w:sz w:val="21"/></w:rPr>'
      '</w:rPrDefault></w:docDefaults>'
      '${_docxStyle("Normal", "Normal", null)}'
      '${_docxStyle("Heading1", "heading 1", "28")}'
      '${_docxStyle("Heading2", "heading 2", "24")}'
      '${_docxStyle("Heading3", "heading 3", "22")}'
      '${_docxStyle("Title", "Title", "36")}'
      '<w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table '
      'Grid"/><w:tblPr><w:tblBorders><w:top w:val="single" w:sz="4" '
      'w:space="0" w:color="999999"/></w:tblBorders></w:tblPr></w:style>'
      '</w:styles>';

  static String _docxStyle(String id, String name, String? halfPoints) {
    final sz = halfPoints == null ? '' : '<w:sz w:val="$halfPoints"/>';
    final bold = id == 'Normal' ? '' : '<w:b/>';
    return '<w:style w:type="paragraph" w:styleId="$id"><w:name w:val="$name"/>'
        '<w:rPr>$bold$sz</w:rPr></w:style>';
  }

  // -------------------------------------------------------------------------
  // pdf
  // -------------------------------------------------------------------------

  /// 生成真 pdf（文件头 `%PDF`）。中文必须嵌入 TrueType 子集：
  /// PDF 的标准 14 字体只有拉丁字形，直接用会乱码 —— 所以找不到中文字体时
  /// **明确失败**，由调用方提示改用 csv/md，绝不静默输出乱码。
  static Future<(List<int>?, String?)> buildPdf(List<DocBlock> blocks,
      {List<int>? fontData, String? title}) async {
    if (blocks.isEmpty) return (null, '没有可写入的内容。');
    if (fontData == null || fontData.isEmpty) {
      return (null, '未找到可用的中文字体（TTF），无法生成含中文的 PDF；'
          '可改用 csv / md 兜底。');
    }
    PdfDocument? doc;
    try {
      doc = PdfDocument();
      final regular = PdfTrueTypeFont(fontData, 11);
      var page = doc.pages.add();
      var y = _pageTop(page);
      const left = 48.0;
      void newPage() {
        page = doc!.pages.add();
        y = _pageTop(page);
      }

      void line(String text, PdfFont font, double lh, {bool skip = false}) {
        if (y < left + lh) newPage();
        final w = _pageWidth(page) - left * 2;
        for (final seg in wrapToWidth(text, font, w)) {
          if (y < left + lh) newPage();
          page.graphics.drawString(seg, font,
              brush: PdfBrushes.black,
              bounds: Rect.fromLTWH(left, y, w, lh));
          y += lh;
        }
        if (skip) y += lh * 0.4;
      }

      if (title != null && title.trim().isNotEmpty) {
        line(sanitizeText(title), PdfTrueTypeFont(fontData, 18), 24,
            skip: true);
      }
      for (final b in blocks) {
        switch (b.kind) {
          case DocBlockKind.h1:
            line(sanitizeText(b.text), PdfTrueTypeFont(fontData, 16), 22,
                skip: true);
            break;
          case DocBlockKind.h2:
            line(sanitizeText(b.text), PdfTrueTypeFont(fontData, 13), 18,
                skip: true);
            break;
          case DocBlockKind.h3:
            line(sanitizeText(b.text), PdfTrueTypeFont(fontData, 12), 16);
            break;
          case DocBlockKind.para:
            line(sanitizeText(b.text), regular, 16);
            break;
          case DocBlockKind.table:
            // 表格按「列对齐文本行」绘制：不画网格线（画了网格而文字换行时
            // 网格与行对不齐，比没有网格更糟），但列宽按内容计算、单元格
            // 逐列排布，抽取文本能保持「行 = 一行、列 = 顺序」的结构。
            for (final r in b.rows) {
              line(formatTableRow(r.map(sanitizeText).toList()), regular, 15);
            }
            y += 6;
            break;
        }
      }
      final bytes = await doc.save();
      if (bytes.isEmpty) return (null, 'PDF 生成失败：输出为空。');
      if (bytes.length > maxBinaryBytes) {
        return (null, 'PDF 超限（${bytes.length} 字节 > $maxBinaryBytes）');
      }
      return (bytes, null);
    } catch (e) {
      return (null, 'PDF 生成失败：$e');
    } finally {
      doc?.dispose();
    }
  }

  /// 一行表格 → 定宽文本行（列间用两个空格分隔，空列补位）。
  @visibleForTesting
  static String formatTableRow(List<String> cells) =>
      cells.map((c) => c.isEmpty ? '-' : c).join('  |  ');

  static double _pageWidth(PdfPage page) {
    try {
      return page.size.width.toDouble();
    } catch (_) {
      return 595.0; // A4 纵
    }
  }

  static double _pageTop(PdfPage page) => 48.0;

  /// 按像素宽度折行（中文逐字可断，拉丁按空格断，避免把单词劈开）。
  @visibleForTesting
  static List<String> wrapToWidth(String text, PdfFont font, double maxWidth) {
    if (text.isEmpty) return [''];
    final out = <String>[];
    final cur = StringBuffer();
    double w = 0;
    void flush() {
      out.add(cur.toString());
      cur.clear();
      w = 0;
    }

    for (final rune in text.runes.map((r) => String.fromCharCode(r))) {
      final cw = _measure(font, rune);
      if (w + cw > maxWidth && cur.isNotEmpty) {
        // 拉丁词尽量整词换行：断点前找最近一个空格，把空格后的部分留到下行。
        final s = cur.toString();
        final isLatinWordChar = !RegExp(r'[\s.,;:!?、。，；：！？]').hasMatch(rune);
        final cjkPrev =
            RegExp(r'[\u4e00-\u9fff]').hasMatch(s.substring(s.length - 1));
        if (isLatinWordChar && !cjkPrev) {
          final sp = s.lastIndexOf(' ');
          if (sp > 0) {
            final tail = s.substring(sp + 1);
            out.add(s.substring(0, sp));
            cur.clear();
            cur.write('$tail$rune');
            w = _measure(font, cur.toString());
            continue;
          }
        }
        flush();
      }
      cur.write(rune);
      w += cw;
    }
    if (cur.isNotEmpty) out.add(cur.toString());
    return out.isEmpty ? [''] : out;
  }

  static double _measure(PdfFont font, String text) {
    try {
      final s = font.measureString(text);
      final w = s.width;
      return w.isFinite && w > 0 ? w : (text.codeUnitAt(0) > 255 ? 11.0 : 6.0);
    } catch (_) {
      return text.codeUnitAt(0) > 255 ? 11.0 : 6.0;
    }
  }

  // -------------------------------------------------------------------------
  // 公共小工具
  // -------------------------------------------------------------------------

  static const String _xmlDecl =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n';

  static (List<int>?, String?) _zip(Archive arch, String what) {
    try {
      final bytes = ZipEncoder().encode(arch);
      if (bytes.isEmpty) {
        return (null, '$what 打包失败：ZIP 输出为空。');
      }
      if (bytes.length > maxBinaryBytes) {
        return (null, '$what 超限（${bytes.length} 字节 > $maxBinaryBytes）');
      }
      return (bytes, null);
    } catch (e) {
      return (null, '$what 打包失败：$e');
    }
  }

  /// XML 文本转义（配合 [_controlRe] 先清掉 XML 1.0 不允许的控制字符）。
  @visibleForTesting
  static String escText(String s) => sanitizeText(s)
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  static String escAttr(String s) => escText(s).replaceAll('"', '&quot;');

  static final RegExp _controlRe = RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f]');

  /// 清掉 XML 1.0 非法控制字符（模型偶发吐出的 \0 / \x1b 会让整个包打不开）。
  @visibleForTesting
  static String sanitizeText(String s) => s.replaceAll(_controlRe, '');

  static int _displayWidth(String s) {
    var w = 0;
    for (final r in s.runes) {
      w += r > 0x2e80 ? 2 : 1;
    }
    return w;
  }

  static int _clamp(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);
}

/// 一个工作表（G61：多 sheet + 中文表头）。
@immutable
class OfficeSheet {
  final String name;
  final List<List<String>> rows;
  const OfficeSheet({required this.name, required this.rows});
}

enum DocBlockKind { h1, h2, h3, para, table }

/// 文档块（docx / pdf 共用一套中间表示）。
@immutable
class DocBlock {
  final DocBlockKind kind;
  final String text;
  final List<List<String>> rows;

  const DocBlock._(this.kind, this.text, this.rows);
  factory DocBlock.h1(String t) => DocBlock._(DocBlockKind.h1, t, const []);
  factory DocBlock.h2(String t) => DocBlock._(DocBlockKind.h2, t, const []);
  factory DocBlock.h3(String t) => DocBlock._(DocBlockKind.h3, t, const []);
  factory DocBlock.para(String t) => DocBlock._(DocBlockKind.para, t, const []);
  factory DocBlock.table(List<List<String>> r) =>
      DocBlock._(DocBlockKind.table, '', r);
}

/// build138（G62）：PDF 中文字体定位。
///
/// PDF 必须内嵌字形，否则中文在别的阅读器里是豆腐块。App 不能带几十 MB 字体
/// 资源（包体红线），所以按「系统里一定有的 TTF」找：
/// Android → DroidSansFallback / NotoSansSC；Windows/Linux/macOS（开发机与
/// 桌面端）→ 常见中文 TTF。只收 `.ttf`，`.ttc`（字体集合）Syncfusion 不认。
/// 找不到就返回 null，由调用方明确报错 —— 不静默出乱码。
class PdfFontLocator {
  PdfFontLocator._();

  @visibleForTesting
  static String? overrideFontPath;

  static const List<String> _candidates = [
    // Android（AOSP / 多数国产 ROM）
    '/system/fonts/DroidSansFallback.ttf',
    '/system/fonts/NotoSansSC-Regular.ttf',
    '/system/fonts/NotoSansCJK-Regular.ttf',
    '/system/fonts/SourceHanSans-Regular.ttf',
    // 桌面（开发与单测环境）
    r'C:/Windows/Fonts/simhei.ttf',
    r'C:/Windows/Fonts/Deng.ttf',
    r'C:/Windows/Fonts/SimsunExtG.ttf',
    r'C:/Windows/Fonts/STXIHEI.TTF',
    '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
    '/usr/share/fonts/truetype/wqy/wqy-microhei.ttc',
    '/usr/share/fonts/truetype/arphic/uming.ttc',
    '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
  ];

  static String? locate() {
    if (overrideFontPath != null) return overrideFontPath;
    for (final c in _candidates) {
      if (!c.toLowerCase().endsWith('.ttf')) continue;
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  /// 读字体字节（带体积上限：字体本身可能几十 MB，不能整个吞进内存）。
  static const int maxFontBytes = 40 * 1024 * 1024;

  static Future<(List<int>?, String?)> loadFont() async {
    final path = locate();
    if (path == null) return (null, '未找到可用的中文 TTF 字体');
    try {
      final f = File(path);
      final len = await f.length();
      if (len <= 0 || len > maxFontBytes) {
        return (null, '字体文件体积异常（$len 字节）：$path');
      }
      return (await f.readAsBytes(), null);
    } catch (e) {
      return (null, '字体读取失败：$e');
    }
  }
}
