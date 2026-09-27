/// build153：插件供给文本拼进 prompt 块前的**结构锁归一化通道**（纯函数，零依赖）。
///
/// 背景：目录层/详情层里有一部分文本来自插件（MCP description/inputSchema、
/// Skill 的 name/description/promptProtocol），会被拼进宿主用
/// `=== … ===` 分隔、用 `<toolresult>` 包裹、块间以 `\n\n` 划缓存边界的
/// system/user 块。此前锁只按**字面字符串**扫，结构类绕过（全角变体、大小写、
/// 把分隔符拆开中间夹空白/零宽字符）扫不出来。
///
/// 本文件把全部锁收进**同一条归一化通道**：先去噪归一（case fold / 全角→半角 /
/// 剥零宽与软连字符 / 去 markdown 反斜杠转义），再判；换行按字面判（无变体）。
/// 判定 fail-closed：归一后仍命中的，一律**降级为纯文本**（剥掉结构字符 /
/// 丢弃分隔行），并保证清洗后复检必干净（二次命中则整段去结构字符）。
library;

/// 清洗结论：[text] 为可安全拼进 prompt 的文本；[breached] 表示原文命中过锁。
class PromptStructureVerdict {
  final String text;
  final bool breached;
  final List<String> hits;

  const PromptStructureVerdict(this.text, this.breached, this.hits);
}

/// 归一化（扫描口径，非输出）：小写、全角 ASCII(U+FF01..FF5E)→半角、
/// 表意空格 U+3000→半角空格、剥零宽/软连字符/markdown 反斜杠。
String normalizePromptForStructureScan(String raw) {
  final sb = StringBuffer();
  for (final r in raw.toLowerCase().runes) {
    if (r >= 0xFF01 && r <= 0xFF5E) {
      sb.writeCharCode(r - 0xFEE0);
    } else if (r == 0x3000) {
      sb.writeCharCode(0x20);
    } else {
      sb.writeCharCode(r);
    }
  }
  return sb
      .toString()
      // \u200b \u200c \u200d \u2060 零宽族、\u00ad 软连字符、\ markdown 转义
      .replaceAll(RegExp('[\\u200b\\u200c\\u200d\\u2060\\u00ad\\\\\x08-\x1f\x7f]'), '');
}

/// 归一后再去掉所有空白——用于抓「把分隔符拆成几段中间夹空白」的形态。
/// 只作判定用，不作输出。
String compactPromptForStructureScan(String raw) =>
    normalizePromptForStructureScan(raw).replaceAll(RegExp(r'\s+'), '');

/// 命中的锁清单（空 = 干净）。[singleLineField]=true 时额外锁标题层级
/// （目录字段的 `#` 标题伪造）；详情多行文本里 `##` 是合法 markdown，不锁。
List<String> findPromptStructureBreaches(String raw,
    {bool singleLineField = false}) {
  final hits = <String>[];
  final compact = compactPromptForStructureScan(raw);
  final norm = normalizePromptForStructureScan(raw);
  // L1 换行/块边界锁（仅单行目录字段，详情多行合法带 \n 不锁）：
  // 一行目录字段含 \n＝在 \n\n 缓存块边界处伪造新块；字面判（换行无变体）
  if (singleLineField && raw.contains('\n')) hits.add('newline');
  // L2 分隔符锁：`===`（section 头柱）与整行 `---`/`***`/`___`（水平分隔行），
  // 在 compact 上判 ⇒ 全角＝、拆段夹空白、零宽、大小写变体同一条通道收进
  if (compact.contains('===') ||
      norm.split('\n').any((ln) => RegExp(r'^\s*[-*_]{3,}\s*$').hasMatch(ln))) {
    hits.add('section-sep');
  }
  // L3 包裹标签锁：`<toolresult>` 开/闭标签（详情注入走 <toolresult> 包裹，
  // 内容里再出现该标签＝逃出宿主包裹边界）；compact 判 ⇒ `<tool result>`、
  // `</TOOLRESULT>`、`＜/toolresult＞` 都命中
  if (compact.contains('<toolresult') || compact.contains('</toolresult')) {
    hits.add('wrapper-tag');
  }
  // L4 标题层级锁（仅单行目录字段）：归一后行首 `#{1,6}+空格`
  if (singleLineField &&
      norm.split('\n').any((ln) => RegExp(r'^\s{0,3}#{1,6}\s').hasMatch(ln))) {
    hits.add('heading');
  }
  return hits;
}

/// 把命中过锁的文本降级为纯文本（不依赖复检通过的第一次清洗）。
/// 先归一再剥：**全角＃/＝、大小写、拆段形态在归一后一律落进被剥字符集**，
/// 保证输出对四条锁的扫描口径天然干净（fail-closed 的构造性证明）。
String _defangPlain(String s) => normalizePromptForStructureScan(s)
    .replaceAll(RegExp('[<>=#]'), '')
    .split('\n')
    .where((ln) => !RegExp(r'^\s*[-*_]{3,}\s*$').hasMatch(ln))
    .join(' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// 归一判定 + fail-closed 清洗。[singleLine]=true＝目录单行字段（name/summary/
/// notWhen/callHint）；false＝详情多行文本（保留合法 markdown，只剥结构越界行）。
PromptStructureVerdict guardPromptStructure(String raw,
    {bool singleLine = true}) {
  final hits = findPromptStructureBreaches(raw, singleLineField: singleLine);
  if (hits.isEmpty) {
    return PromptStructureVerdict(raw, false, const []);
  }
  var text = raw;
  if (!singleLine) {
    // 逐行降级：越界行（伪造 section 头 / 逃出包裹标签）剥掉触发字符后保留正文，
    // 纯分隔行整行丢弃；`<toolresult>` 标签替换为裸词（纯文本）。
    text = text.split('\n').map((ln) {
      final c = compactPromptForStructureScan(ln);
      if (RegExp(r'^\s*[-*_]{3,}\s*$')
          .hasMatch(normalizePromptForStructureScan(ln))) {
        return '';
      }
      var out = ln;
      if (c.contains('<toolresult') || c.contains('</toolresult')) {
        out = out.replaceAll(
            RegExp(
                r'[<\uFF1C]\s*/?\s*tool\s*result\s*[>\uFF1E]',
                caseSensitive: false),
            'toolresult');
      }
      if (compactPromptForStructureScan(out).contains('===')) {
        out = out.replaceAll(RegExp('[=＝]'), '');
      }
      return out;
    }).join('\n');
  }
  // fail-closed 复检：清洗后仍命中（例如同行拆段夹非空白杂字符）⇒ 整段降纯文本
  if (findPromptStructureBreaches(text, singleLineField: singleLine)
      .isNotEmpty) {
    text = _defangPlain(text);
  }
  return PromptStructureVerdict(text, true, hits);
}
