/// build164（#83）：助手消息下方那张「本轮真的写进了工作区、App 内还能渲染」的产物卡片——
/// **判据层**（纯函数，可在没有 WebView、没有真工作区文件的环境下做行为断言）。
///
/// 为什么单独成文件（与 [html_preview] / `attachment_tap.dart` 同一个理由）：
///  · 真 WebView 与真文件在 flutter_test 里都拿不到 ⇒ 判据层是这次唯一能对
///    「哪些步骤该长出卡片、卡片上有哪些字」做**行为断言**的地方（预览页本体只做源码级断言）；
///  · 判据只准住一处：气泡"画不画"与"点开读什么"各写一遍，早晚漂移成
///    163 那条已经写进代码的判据所说的形状 ——「画了就是假入口」。
///
/// 为什么要这第三条入口（真机 1.7.106+163 取证，四条入口逐条对过）：
///  · 气泡「预览」按钮读的是**消息正文**（`message_bubble_v2.dart` 调 `extractHtmlDocument`），
///    而模型写文件用的是 `<ws_write content="…整页 HTML…">`，那一整块会被
///    `react_parser.dart` 的 `_ctrlPaired` 从正文里**整段剥掉** ⇒ 正文判不出文档 ⇒ 按钮不出现；
///  · 聊天附件卡片只画在 `m.attachments` 上，而 `attachments` 全库只挂在**用户**消息；
///  · `generatedFiles` 那一族只认 mp4/mov，html 会掉进 `Image.file` 的 errorBuilder
///    显示「图片已丢失」；
///  · 于是当时唯一真入口只剩文件管理页（`file_management_screen.dart` 走 readText 读盘）。
///    真机日志佐证：整份导出里 `HtmlPreview` 这个 tag **0 命中**（机主从未进过预览页）。
///
/// 数据源为什么只有 `reasoningSteps`：工作区动作的内置插件（`builtin_plugins.dart`）
/// 在每一步里就留着「正在写入 exports/xxx.html / 已保存」这类正文与结果摘要
/// （ws_download 是 `已保存到工作区「rel」（N 字节）`、ws_make_file 是
/// `xlsx 已生成（2.8 KB）`），这些随 `reasoningSteps` 一起落库 ⇒
/// **零 DB 迁移（v39 不许加列）、零 ReAct 改动、渲染时不读盘**。
///
/// 一条如实写在这里的缺口：`ws_write` 的成功文案（`已保存到工作区「$rel」。`，
/// 见 builtin_plugins.dart 的 `_WsWritePlugin.handle`）**没有字节数**，
/// 只有 `ws_download`（`（N 字节）`）与 `ws_make_file`（`（N.N KB）`）带。
/// 补那一列要改 builtin_plugins.dart（本批禁区）⇒ 本判据交回 `bytes == null`，
/// 卡片那一列显示「字节数未知」而不是省掉这一列、也不是报一个假数。
library;

import '../models/chat_message.dart' show ReasoningStep;
import '../services/react_parser.dart' show kProgressNoteStepKind;
import 'html_preview.dart' show isHtmlPreviewFile;

/// 一张产物卡片要画的**全部**展示数据（渲染层不再自己判任何东西）。
class AgentArtifactCard {
  const AgentArtifactCard({
    required this.rel,
    required this.fileName,
    required this.bytes,
    required this.approxBytes,
    required this.tool,
    required this.writes,
  });

  /// 工作区相对路径 —— 点开时**原样**交给 `WorkspaceService.readText`（唯一读盘通道）。
  final String rel;

  /// 路径末段名（卡片标题）。故意不在判据层做任何截断：截不截断是渲染的事，
  /// 而"截到看不清"是这次要修的缺陷，不是数据的属性。
  final String fileName;

  /// 字节数；`null` = 本轮步骤文本里确实没有这一项（见文件头那条缺口）。
  final int? bytes;

  /// true ⇒ 这个数是从 `KB` 口径换算来的，展示必须带「约」，不许报成精确值。
  final bool approxBytes;

  /// 证据出自哪个动作（`ws_write` / `ws_make_file` / `ws_download` / `ws_patch` …），日志用。
  final String tool;

  /// 这个路径在本轮被成功写入几次。真机 23:17:58 同一秒内 `exports/四格式展示.html`
  /// 先写 3 字节、后写 2004 字节 ⇒ 盘上只剩最后一份，卡片也必须是**最后一份**那一张。
  final int writes;

  /// 「字节数」那一列（取证点名的就是这一列）。它**永远有值**：
  /// 拿不到确切数字时不许整列省掉（省掉就又回到"分不清点开的是哪一份"），
  /// 而是如实写未知 —— 本仓口径：测不出来的数不假装成 0（见 build140 反馈②）。
  String sizeLabel({bool zh = true}) {
    final b = bytes;
    if (b == null) return zh ? '字节数未知' : 'size unknown';
    final grouped = _groupThousands(b);
    return approxBytes ? (zh ? '约 $grouped B' : '~$grouped B') : '$grouped B';
  }

  @override
  String toString() => 'AgentArtifactCard($rel, ${sizeLabel(zh: true)}, $tool)';
}

/// 一期 App 内**真能渲染**的产物类型判据。
///
/// 后缀名单不在这里重抄：复用 build162 为「工作区/附件分派」写的 [isHtmlPreviewFile]
/// （教训 #62）。为什么一期只到 html/htm：预览页只有 `HtmlPreviewScreen` 这一面，
/// xlsx/docx/pdf 在 App 里没有能展示它们的页 ⇒ 画出来就是假入口（163 那条判据照抄口径）。
bool isRenderableArtifact(AgentArtifactCard card) =>
    card.rel.isNotEmpty && isHtmlPreviewFile(card.fileName);

/// 点开的去向（2026-09-26 02:40 机主把三层并成一条：**「1 把常见的可以打开，
/// 2 全部都支持展示，3 不支持的什么都不说，就直接弹一个分享/默认应用打开」**）。
///
/// 三层落到代码里只有两个去向，因为"全部都支持展示"这件事由**卡片本身**承担
/// （非 html 也画卡、也带文件名与字节数），差别只在点下去给什么、以及卡片上
/// 那枚「预览 ›」画不画：
///  · [AgentArtifactTap.inAppPreview] —— App 内真能渲染（一期只有 html/htm，走 `HtmlPreviewScreen`），
///    卡片上画「预览 ›」；
///  · [AgentArtifactTap.externalOnly] —— App 内没有能渲染它的页 ⇒ **不写「预览」两个字**
///    （写了就是承诺一件我们做不到的事），点开交给系统：`WorkspaceService.openExternal`
///    那条既有通道，它在本机没有合适应用时会如实回落分享面板（build138 G63 的契约）。
///
/// 等 xlsx/csv/md/txt 的「抽取预览页」落地（165 的 ①），只是把这些卡从这一档挪到上一档，
/// 判据与卡片渲染都不用再动。
enum AgentArtifactTap { inAppPreview, externalOnly }

/// 这张卡片点开给什么（唯一判据，渲染层不再自己看后缀）。
AgentArtifactTap agentArtifactTapFor(AgentArtifactCard card) =>
    isRenderableArtifact(card)
        ? AgentArtifactTap.inAppPreview
        : AgentArtifactTap.externalOnly;

/// 卡片上要不要画那枚「预览 ›」。
bool artifactShowsPreviewLabel(AgentArtifactCard card) =>
    agentArtifactTapFor(card) == AgentArtifactTap.inAppPreview;

/// 主入口（App 内能渲染的那些）：一条助手消息的 `reasoningSteps` → 该画出来的卡片。
///
/// 顺序 = 首次出现的顺序；同一路径多次成功写入**合成一张**卡（取最后一次写入的字节数，
/// 并把次数记进 [AgentArtifactCard.writes]）。
List<AgentArtifactCard> collectArtifactCards(List<ReasoningStep> steps) =>
    _collectArtifactCards(steps, inApp: true);

/// App 内**渲染不了**的落盘产物（xlsx / docx / pdf / 图片 / 任意其它后缀）。
///
/// 与 [collectArtifactCards] 共用同一个私有收集器，只把类型闸反过来 ⇒
/// 两条合起来才是机主要的那句"全部都支持展示"，而"能不能 App 内开"只由
/// [agentArtifactTapFor] 一处回答（教训 #62：一个语义一份实现）。
List<AgentArtifactCard> collectExternalArtifactCards(List<ReasoningStep> steps) =>
    _collectArtifactCards(steps, inApp: false);

List<AgentArtifactCard> _collectArtifactCards(List<ReasoningStep> steps,
    {required bool inApp}) {
  final byRel = <String, AgentArtifactCard>{};
  for (final s in steps) {
    final card = parseArtifactFromStep(s);
    if (card == null) continue;
    if (isRenderableArtifact(card) != inApp) continue;
    final prev = byRel[card.rel];
    byRel[card.rel] = prev == null
        ? card
        : AgentArtifactCard(
            rel: card.rel,
            fileName: card.fileName,
            bytes: card.bytes,
            approxBytes: card.approxBytes,
            tool: card.tool,
            writes: prev.writes + 1,
          );
  }
  return byRel.values.toList(growable: false);
}

/// 一步工具记录 → 一张卡片；判不出（不是落盘动作 / 没落盘 / 路径缺失 / 空文件）返回 null。
///
/// **不读盘、不看类型**（类型闸在 [isRenderableArtifact]）：这一层只回答
/// "这一步是不是真的往工作区落了一个文件、落的是哪个、多大"。
AgentArtifactCard? parseArtifactFromStep(ReasoningStep step) {
  // progressNote 是**给人看的一句话**，不是落盘证据（#82）。
  if (isProgressNoteStep(step)) return null;
  final status = step.status;
  if (_notLandedStatuses.contains(status)) return null;
  // 只看步骤自己的文本。为什么不看 `arguments`：ws_* 步骤根本不写这个字段
  // （只有 mcp_call/skill_call 写，见 plugin_registry.dart），而**工具结果原文**
  // 那一条是宿主回灌给模型的 `role=user` 消息（`_wsToolResult`），不属于这条助手消息；
  // 更要紧的是：万一 arguments 里带着整页 HTML，一句 `<ws_write path="…">` 的示例文本
  // 就能被解成一张卡（假入口）。宁可少画，不多画。
  final blobs = <String>[
    for (final t in <String?>[step.content, step.resultSummary])
      if (t != null && t.trim().isNotEmpty) _unescape(t.trim()),
  ];
  if (blobs.isEmpty) return null;

  String? rel;
  String tool = '';
  for (var i = 0; i < blobs.length && rel == null; i++) {
    final hit = _matchRel(blobs[i], status: status);
    if (hit != null) {
      rel = hit.rel;
      tool = hit.tool;
    }
  }
  if (rel == null) return null;

  final size = _matchBytes(blobs);
  // 「文件为空」不画：0 字节的 html 点开就是一张白页，那是假入口的另一种形状。
  if (size != null && size.exact && size.value == 0) return null;

  return AgentArtifactCard(
    rel: rel,
    fileName: rel.split('/').last,
    bytes: size?.value,
    approxBytes: size != null && !size.exact,
    tool: tool,
    writes: 1,
  );
}

/// 一段**已经落进工作区**的原文（工具结果文本、或工作区日志行）→ 卡片；判不出返回 null。
///
/// 独立出来是为了让单测能直接喂真机文案，不必先造一个 ReasoningStep
/// （`parseArtifactFromStep` 就是它的包装）。
AgentArtifactCard? parseArtifactText(String text, {String status = ''}) {
  final t = _unescape(text.trim());
  if (t.isEmpty || _notLandedStatuses.contains(status)) return null;
  final hit = _matchRel(t, status: status);
  if (hit == null) return null;
  final size = _matchBytes([t]);
  if (size != null && size.exact && size.value == 0) return null;
  return AgentArtifactCard(
    rel: hit.rel,
    fileName: hit.rel.split('/').last,
    bytes: size?.value,
    approxBytes: size != null && !size.exact,
    tool: hit.tool,
    writes: 1,
  );
}

// ============================================================================
// progressNote（#82 新增的 step kind）——**可见行**的判据也住这个文件
// ============================================================================
//
/// 这一步是不是「面向用户的一句话阶段进展」。
///
/// kind 字符串**引自 react_parser.dart 的 `kProgressNoteStepKind`**，不在这里重抄一份：
/// 那是协议层唯一的真源（#62）。找不到该 kind（同事那边还没落地）⇒ 下列函数全部
/// 返回空/原样，气泡一切照旧，这条新通道**不是崩溃面**。
bool isProgressNoteStep(ReasoningStep step) =>
    step.kind == kProgressNoteStepKind;

/// 折叠面板该吃的步骤（progressNote 除外：它是正文，不是思考过程）。
List<ReasoningStep> thinkingPanelSteps(List<ReasoningStep> steps) => steps
    .where((s) => !isProgressNoteStep(s))
    .toList(growable: false);

/// 本轮有没有可折叠的内容（气泡用它替代 `ChatMessage.hasReasoning` 那道闸）。
///
/// 为什么要替代：`hasReasoning` 认「任何一条不是纯进度占位的步骤」，而 progressNote
/// 恰好不是占位 ⇒ 整轮只有一句阶段小结时它会返回 true，折叠面板就会出现一个
/// 「展开后什么都没有」的空壳（build133 明确按缺陷处理过那个形状）。
bool hasThinkingPanelSteps(List<ReasoningStep> steps) =>
    steps.any((s) => !isProgressNoteStep(s));

/// 按正文样式画成可见行的阶段小结（按步骤顺序；空白丢掉）。
List<String> progressNoteTexts(List<ReasoningStep> steps) => [
      for (final s in steps)
        if (isProgressNoteStep(s) && s.content.trim().isNotEmpty)
          s.content.trim(),
    ];

// ============================================================================
// 内部：文案形状
// ============================================================================

/// 这些状态都意味着**盘上什么都没有**（取消/失败/还没结束/被熔断…）⇒ 不画卡片。
/// 口径抄 `builtin_plugins.dart` 的 `_wsToolResult` 与 `updateReasoningStep` 那批状态串。
const Set<String> _notLandedStatuses = {
  'running',
  'failed',
  'blocked',
  'rejected',
  'cancelled',
  'not_found',
  'invalid',
  'circuit_open',
  'skipped',
  'disabled',
  'error',
};

/// 一条「路径 + 是哪个动作」的命中。
class _RelHit {
  const _RelHit(this.rel, this.tool);
  final String rel;
  final String tool;
}

/// 一条「字节数」命中。`exact=false` ⇒ 来源只有 KB 口径，是换算值。
class _SizeHit {
  const _SizeHit(this.value, this.exact);
  final int value;
  final bool exact;
}

/// 自证式文案（这句话本身就写着"已经落盘了"）——路径都在「」里，可能带空格/CJK。
final List<RegExp> _selfAsserting = [
  // ws_write / ws_download：已保存到工作区「exports/xxx.html」（N 字节）。
  RegExp(r'已保存到工作区「([^」]+)」'),
  // ws_make_file：已生成真 xlsx 文件「exports/xxx.xlsx」（2.8 KB，…）。
  RegExp(r'已生成真\s+\S+\s*文件「([^」]+)」'),
  // 英文同族（`Created a real xlsx file "x" (1.2 KB…)`）——同一插件的另一条文案分支。
  RegExp(r'Created a real\s+\S+\s*file "([^"]+)"'),
];

/// 步骤标签（`正在写入 <rel>` / `Writing <rel>`）：写的时候还没落盘，
/// 所以**必须** `status == 'success'` 才算证据（半截就停的那步不算）。
final RegExp _labelZh = RegExp(r'^正在(?:写入|生成|修改)\s+(.+)$');
final RegExp _labelEn = RegExp(r'^(?:Writing|Generating|Patching)\s+(.+)$');

/// 工具参数原文（标签/参数通道：`path="exports/xxx.html"`）。
final RegExp _pathAttr = RegExp(r'path="([^"]+)"');
final RegExp _pathJson = RegExp(r'"path"\s*:\s*"([^"]+)"');

/// 工作区落盘日志行（`WorkspaceService.writeText/writeBinary` 打的那一条，
/// 取证用的 2004 字节就出在这个形状里；将来若被接进步骤文本，这里已经认）。
final RegExp _writeLog = RegExp(r'workspace write(?:\(binary\))?:\s*(\S+)');

/// 字节数：`（2004 字节）` / `(2004 bytes)` / `（2.8 KB`（精确 vs 换算）。
///
/// 数字**必须跟在开括号后面**：生产那三条文案都是这个形状
/// （`已保存到工作区「rel」（N 字节）`、`已生成真 kind 文件「rel」（N.N KB，…）`、
/// 日志行 `workspace write: rel (2004 bytes)`）。不带括号就匹配的话，
/// 一个名叫 `10KB.html` 的文件会被凭空报出 10240 字节 —— 宁缺勿错。
final RegExp _bytesExact =
    RegExp(r'[\(（]\s*([\d,]+)\s*(?:字节|bytes)', caseSensitive: false);
final RegExp _kbApprox =
    RegExp(r'[\(（]\s*([\d]+(?:[.,]\d+)?)\s*(?:KB|kb)', caseSensitive: false);

/// 从一段文本里取工作区相对路径；判不出返回 null。
_RelHit? _matchRel(String text, {String status = ''}) {
  for (final re in _selfAsserting) {
    final m = re.firstMatch(text);
    final rel = _saneRel(m?.group(1));
    if (rel != null) return _RelHit(rel, _toolOf(text));
  }
  // 日志形状自带落盘事实（"write:" 就是写成功了那一行），不看 status
  final lm = _writeLog.firstMatch(text);
  final logRel = _saneRel(lm?.group(1));
  if (logRel != null) return _RelHit(logRel, 'ws_write');

  // 以下两支都要求「这一步已报成功」
  if (status != 'success') return null;
  for (final line in text.split('\n')) {
    final t = line.trim();
    final zh = _labelZh.firstMatch(t);
    final en = _labelEn.firstMatch(t);
    final rel = _saneRel(zh?.group(1) ?? en?.group(1));
    if (rel != null) return _RelHit(rel, _toolOf(text));
  }
  final am = _pathAttr.firstMatch(text) ?? _pathJson.firstMatch(text);
  final arel = _saneRel(am?.group(1));
  return arel == null ? null : _RelHit(arel, _toolOf(text));
}

/// 路径形状闸：缺路径、绝对路径、`..` 穿越、URL、带控制字符 ⇒ 判不出（null）。
///
/// 这里**只**做形状检查，不做白名单/深度/段名合法性检查：那些的权威在
/// `WorkspaceService.resolve`（点开时它自然会拒），在判据层重抄一遍就是第二真源。
String? _saneRel(String? raw) {
  final t = (raw ?? '').trim();
  if (t.isEmpty) return null;
  if (t.length > 200) return null;
  if (t.contains('://')) return null; // ws_download 的步骤正文是 URL，不是工作区路径
  final s = t.replaceAll('\\', '/');
  if (s.startsWith('/')) return null;
  if (RegExp(r'[A-Za-z]:').hasMatch(s.substring(0, s.length >= 2 ? 2 : s.length))) {
    return null; // 盘符
  }
  for (final seg in s.split('/')) {
    if (seg == '..' || seg == '.') return null;
  }
  if (s.contains('\n') || s.contains('\r')) return null;
  return s;
}

/// 是哪个动作落的盘（只为日志可读，认不出就留空，不猜）。
String _toolOf(String text) {
  if (text.contains('已生成真') || text.contains('Created a real')) return 'ws_make_file';
  if (text.contains('正在修改') || text.contains('Patching')) return 'ws_patch';
  if (text.contains('正在下载') || text.contains('Downloading')) return 'ws_download';
  if (text.contains('workspace write')) return 'ws_write';
  if (text.contains('已保存到工作区') || text.contains('正在写入') ||
      text.contains('正在生成') || text.contains('Writing') ||
      text.contains('Generating')) {
    return 'ws_write';
  }
  return '';
}

/// 从若干段文本里取字节数（先试每条文本的**精确**形状，全都没有再试 KB 口径）。
_SizeHit? _matchBytes(List<String> texts) {
  for (final t in texts) {
    final v = _parseInt(_bytesExact.firstMatch(t)?.group(1));
    if (v != null) return _SizeHit(v, true);
  }
  for (final t in texts) {
    final v = _parseKb(_kbApprox.firstMatch(t)?.group(1));
    if (v != null) return _SizeHit(v, false);
  }
  return null;
}

int? _parseInt(String? raw) {
  final s = (raw ?? '').replaceAll(',', '').trim();
  if (s.isEmpty) return null;
  final v = int.tryParse(s);
  return (v == null || v < 0) ? null : v;
}

/// `2.8 KB` → 2867 字节（1024 进制）。取整是为了**不谎称精确**：调用方拿到
/// `exact == false`，展示层因此写「约 2,867 B」。
int? _parseKb(String? raw) {
  final s = (raw ?? '').replaceAll(',', '').trim();
  if (s.isEmpty) return null;
  final d = double.tryParse(s);
  if (d == null || d < 0) return null;
  return (d * 1024).round();
}

/// toolresult 外壳把 `& < > "` 都转义过（`escapeToolResultContent` / `escapeToolResultAttr`，
/// 见 builtin_plugins.dart）；不还原的话「」里的路径与 `path="…"` 属性都可能带着实体。
/// `&amp;` 放最后替，否则会把先替出来的 `&lt;` 二次解错。
String _unescape(String s) => s
    .replaceAll('&quot;', '"')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&#10;', '\n')
    .replaceAll('&amp;', '&');

/// 千位分隔（`2004` → `2,004`）。自己写而不是 `intl` 的 `NumberFormat`：
/// 那个按 locale 出结果（德语是 `2.004`），而这一列是取证要按字节数比对的那一列，
/// 必须与语言设置无关。
String _groupThousands(int n) {
  final s = n.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return buf.toString();
}
