/// B1 自写最小语法高亮（Dart 专用）。§13 闸门前置：不引三方高亮包。
/// 纯 Dart 零 Flutter 依赖，扫描一次产出逐行 token，供查看器按需上色。
///
/// 能力边界（诚实口径，别当全量解析器用）：
///   · 关键字 / 单行与**嵌套**块注释 / 普通·raw·三引号字符串（含跨行）/ 数字。
///   · 字符串插值内部不再二次分词（整段按字符串上色）。
///   · 非 .dart 文件不走这里，查看器直接按纯文本渲染。
library;

enum TokType { keyword, string, comment, number, ident, punct }

class Tok {
  const Tok(this.start, this.end, this.type);

  /// 行内偏移（含起、不含止）。
  final int start;
  final int end;
  final TokType type;
}

class LineTokens {
  const LineTokens(this.toks, this.endState);

  final List<Tok> toks;

  /// 行末词法状态，下一行从这里续扫。
  final LexState endState;
}

/// 跨行词法状态：块注释嵌套深度 + 未闭合字符串（终止符与是否 raw）。
class LexState {
  const LexState({
    this.blockDepth = 0,
    this.stringTerminator,
    this.stringRaw = false,
  });

  final int blockDepth;

  /// 未闭合字符串的终止符（"'" / '"' / "'''" / '"""'），null = 无悬挂。
  final String? stringTerminator;
  final bool stringRaw;
}

const Set<String> kDartKeywords = {
  'abstract', 'as', 'assert', 'async', 'await', 'base', 'break', 'case',
  'catch', 'class', 'const', 'continue', 'covariant', 'default', 'deferred',
  'do', 'dynamic', 'else', 'enum', 'export', 'extends', 'extension',
  'external', 'factory', 'false', 'final', 'finally', 'for', 'get', 'if',
  'implements', 'import', 'in', 'interface', 'is', 'late', 'library', 'mixin',
  'new', 'null', 'on', 'operator', 'part', 'required', 'rethrow', 'return',
  'sealed', 'set', 'show', 'static', 'super', 'switch', 'sync', 'this',
  'throw', 'true', 'try', 'typedef', 'var', 'void', 'when', 'while', 'with',
  'yield',
};

bool _isIdentStart(int c) =>
    c == 0x5F || // _
    c == 0x24 || // $
    (c >= 0x41 && c <= 0x5A) ||
    (c >= 0x61 && c <= 0x7A);

bool _isIdentPart(int c) => _isIdentStart(c) || (c >= 0x30 && c <= 0x39);

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

/// 逐行扫描整份文本。O(字符数)，数万行级别一次性扫描在毫秒量级。
List<LineTokens> tokenizeDart(String text) {
  final lines = text.split('\n');
  final out = <LineTokens>[];
  var state = const LexState();
  for (final line in lines) {
    final r = _scanLine(line, state);
    out.add(LineTokens(r.$1, r.$2));
    state = r.$2;
  }
  return out;
}

(List<Tok>, LexState) _scanLine(String line, LexState state) {
  final toks = <Tok>[];
  final n = line.length;
  var i = 0;
  var blockDepth = state.blockDepth;
  // 注释/字符串段起点：从上一行续进来的段，起点按 0 算。
  var commentStart = blockDepth > 0 ? 0 : -1;
  var strTerm = state.stringTerminator;
  var strRaw = state.stringRaw;
  var strStart = strTerm != null ? 0 : -1;

  while (i < n) {
    if (strTerm != null) {
      // 字符串内找终止符；raw 不认反斜杠转义。
      final termLen = strTerm.length;
      var closed = false;
      while (i < n) {
        if (!strRaw && line.codeUnitAt(i) == 0x5C) {
          i += 2;
          continue;
        }
        if (i + termLen <= n && line.substring(i, i + termLen) == strTerm) {
          i += termLen;
          toks.add(Tok(strStart, i, TokType.string));
          strTerm = null;
          strStart = -1;
          closed = true;
          break;
        }
        i++;
      }
      if (!closed) {
        // 整行都埋在字符串里：token 拉到行尾，状态留给下行续扫。
        toks.add(Tok(strStart, n, TokType.string));
        strStart = 0;
      }
      continue;
    }
    if (blockDepth > 0) {
      // 块注释内找 */；Dart 块注释可嵌套，/* 要加深。
      final c = line.codeUnitAt(i);
      if (c == 0x2F && i + 1 < n && line.codeUnitAt(i + 1) == 0x2A) {
        blockDepth++;
        i += 2;
        continue;
      }
      if (c == 0x2A && i + 1 < n && line.codeUnitAt(i + 1) == 0x2F) {
        blockDepth--;
        i += 2;
        if (blockDepth == 0) {
          toks.add(Tok(commentStart, i, TokType.comment));
          commentStart = -1;
        }
        continue;
      }
      i++;
      continue;
    }
    final c = line.codeUnitAt(i);
    if (c == 0x20 || c == 0x09 || c == 0x0D) {
      i++;
      continue;
    }
    if (c == 0x2F && i + 1 < n && line.codeUnitAt(i + 1) == 0x2F) {
      toks.add(Tok(i, n, TokType.comment));
      break;
    }
    if (c == 0x2F && i + 1 < n && line.codeUnitAt(i + 1) == 0x2A) {
      blockDepth = 1;
      commentStart = i;
      i += 2;
      continue;
    }
    // 字符串（raw / 普通 / 三引号）。
    var raw = false;
    var q = i;
    if ((c == 0x72 || c == 0x52) && // r / R
        i + 1 < n &&
        (line.codeUnitAt(i + 1) == 0x27 || line.codeUnitAt(i + 1) == 0x22)) {
      raw = true;
      q = i + 1;
    }
    if (q < n && (line.codeUnitAt(q) == 0x27 || line.codeUnitAt(q) == 0x22)) {
      final quote = line[q];
      var term = quote;
      if (q + 2 < n &&
          line.codeUnitAt(q + 1) == line.codeUnitAt(q) &&
          line.codeUnitAt(q + 2) == line.codeUnitAt(q)) {
        term = quote * 3;
      }
      strTerm = term;
      strRaw = raw;
      strStart = i;
      i = q + term.length;
      continue;
    }
    if (_isDigit(c)) {
      final s = i;
      i++;
      while (i < n &&
          (_isIdentPart(line.codeUnitAt(i)) || line.codeUnitAt(i) == 0x2E)) {
        i++;
      }
      toks.add(Tok(s, i, TokType.number));
      continue;
    }
    if (_isIdentStart(c)) {
      final s = i;
      i++;
      while (i < n && _isIdentPart(line.codeUnitAt(i))) {
        i++;
      }
      final word = line.substring(s, i);
      toks.add(Tok(s, i,
          kDartKeywords.contains(word) ? TokType.keyword : TokType.ident));
      continue;
    }
    toks.add(Tok(i, i + 1, TokType.punct));
    i++;
  }
  // 行尾仍埋在块注释里：段拉到行尾，深度留给下行续扫。
  if (blockDepth > 0 && commentStart >= 0) {
    toks.add(Tok(commentStart, n, TokType.comment));
  }
  return (
    toks,
    LexState(
      blockDepth: blockDepth,
      stringTerminator: strTerm,
      stringRaw: strTerm != null && strRaw,
    ),
  );
}

/// 等宽布局的「单元格」宽度估算：ASCII 1 格，其余（含中文全角）2 格。
/// 只做横向滚动范围估算，不做真实排版。
int displayCells(String line) {
  var cells = 0;
  for (final r in line.runes) {
    cells += r < 128 ? 1 : 2;
  }
  return cells;
}
