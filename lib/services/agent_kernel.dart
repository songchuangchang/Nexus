/// build115（typed 内核最小切片 R2-min）：把「模型输出 → 有类型的块」这一步做掉。
///
/// ## 为什么要做（实证根因）
///
/// 宿主现有链路把**两个本来独立的 SSE 字段压成一条无类型字符串**：
///
/// ```
/// delta.reasoning_content（真思考）─┐
///                                  ├─ yield 混流 → Stream<String>
/// delta.content（真答案）──────────┘
///          ↓
/// parseReActOutput → 无标签时全判 thinking → bare = 思考 + 答案拼接
///          ↓
/// looksLikeMonologue 不命中 → **整段当答案定稿**  ← 用户所见「结论混着思考」
/// ```
///
/// 实测数据：28 批发版中 26 批涉及结论问题；净化链已累积 27 个环节；
/// 8 张手工同步表已因漏登记复发 5 次。**根因不是净化不够，是「信息在源头就
/// 被降格成文本、下游只能猜」**。
///
/// ## 本内核的边界（最小切片，不做全量 R1~R5）
///
/// - 只做「模型输出 → 类型化块」这一段：thinking / answer / tool 三类；
/// - UI、存储、插件体系、FC/标签双通道语义**全部不动**；
/// - 出口仍是既有 `AnswerFinalizer`（只是输入从混合文本变成「已分类的块」）；
/// - 旧链路保留（[kUseTypedKernel] 一键回退），出问题可立即切回。
///
/// ## 三类块的来源（零猜测优先）
///
/// | 来源 | 目标块 | 是否需要猜 |
/// |---|---|---|
/// | `delta.reasoning_content` | thinking | **不猜**（字段语义明确） |
/// | `delta.content` 内的 `<thinking>…</thinking>` | thinking | 不猜（标签明确） |
/// | `delta.content` 内的 `<answer>…</answer>` | answer | 不猜（标签明确） |
/// | `delta.content` 内的工具标签 | tool | 不猜（标签明确） |
/// | `delta.content` 的裸文本 | answer | **不猜**（content 字段语义＝给用户的正文） |
/// | `tool_calls`（FC 通道） | tool | 不猜（结构化 JSON） |
///
/// ## G33（build124）：正文归属由**标签**决定，不由 chunk 切分决定
///
/// 真机泄漏（nexus_export_2026-09-17T15-26）：配对工具标签的开标签 / JSON 参数 /
/// 闭合标签被 SSE **切成三个 chunk**。旧实现只在「开标签与闭合标签同 chunk」时
/// 才消费正文，切开的参数文本于是落进裸文本通道 → answer 件 → 轮末兜底把
/// JSON 参数当结论定稿（`No <answer> piece parsed but stream buffer has 68 chars`）。
/// 现实现：开标签已见而闭合未到 → 进入 'tool' 块暂扣正文，直到闭合或流末。
///
/// 对比旧链路：旧链路把上面**全部**先拼成一段字符串，再用正则+词表猜哪段是
/// 思考（27 个环节）。本内核把「猜」的环节从 27 个降到 0 ——
/// 只剩「content 段是否被弱模型塞了思考」这一种残存情况（见 [ChannelDecision]）。
library;

import 'dart:convert';

/// 块类型（只有三种——刻意不扩，扩一类就多一处要同步的表）。
enum AgentItemType {
  /// 思考：只进思考面板，**永不进答案**
  thinking,

  /// 正文：面向用户的结论
  answer,

  /// 工具调用：走既有 dispatch
  tool,
}

/// 类型化块：出生即带类型，下游不需要再判断「这是什么」。
class AgentItem {
  final AgentItemType type;

  /// thinking / answer 的文本（tool 时为摘要）
  final String content;

  /// tool：标签名或 FC 函数名（与既有 triggerType / tool name 同名，零翻译）
  final String? toolName;

  /// tool：属性或 arguments（与既有 label piece / FC args 同构，零翻译）
  final Map<String, String>? toolArgs;

  /// 来源（诊断用，不参与语义）
  final String source;

  const AgentItem.thinking(this.content, {this.source = 'reasoning'})
      : type = AgentItemType.thinking,
        toolName = null,
        toolArgs = null;

  const AgentItem.answer(this.content, {this.source = 'content'})
      : type = AgentItemType.answer,
        toolName = null,
        toolArgs = null;

  const AgentItem.tool(this.toolName, this.toolArgs,
      {this.content = '', this.source = 'tag'})
      : type = AgentItemType.tool;

  bool get isThinking => type == AgentItemType.thinking;
  bool get isAnswer => type == AgentItemType.answer;
  bool get isTool => type == AgentItemType.tool;

  @override
  String toString() => 'AgentItem(${type.name}, ${content.length} chars'
      '${toolName != null ? ', tool=$toolName' : ''})';
}

/// 通道选择结论：本次响应里「content 段是否可信为答案」。
enum ChannelDecision {
  /// 模型提供了 reasoning_content → content 段可信为答案（零猜测）
  separated,

  /// 无 reasoning_content 且 content 段有标签 → 标签已给出结构（零猜测）
  tagged,

  /// 无 reasoning_content、无标签 → content 段需按「语用特征」判定，
  /// 这是唯一残存需要判定的情况（W4 场景，罕见路径）
  bareNeedsJudgment,
}

/// 工具标签名（与既有 triggerType 同名，**不新增表**——直接复用
/// react_parser 的 kReActTagNames 里「非 thinking/answer」的部分，
/// 由调用方注入，避免又一次「多张表要同步」的老病）。
typedef ToolTagMatcher = bool Function(String tagName);

/// G3（build121，计划书 C-05/R2 子项 0）：**未闭合 `<answer>` 块的字面提及判别式**。
///
/// **只**用于「`<answer>` 开标签后无闭合」这一窄上下文的**字面提及判别**
/// （模型在正文里提到 `<answer>` 这个词、而不是真的开块），不做通用正文净化——
/// 通用净化仍在旧链（冻结令），本表只服务内核的状态机判定。
///
/// 业界口径（DeepSeek/vLLM/Cherry Studio 一致，见
/// bug_reports/RESEARCH_结论思考分离_业界处理方法.md）：
/// 无闭合标签 ≠「到流末全是答案」；把到流末的文本当答案就是把推理泄漏给用户。
///
/// 名字为什么不带 cue（build170，#94 结构锁 168-5 柱⑤ 逼出来的一个决定）：
/// 它与 `react_parser.dart` 的 `_enPlanningCue` / `_zhMetaProcessCue` /
/// `_monologueCue` **长得像但不是同一张表**——那三张是「这行是模型自语吗」的
/// 正文净化线索，本表是「这段未闭合文本是在**字面提及**协议词吗」的状态机判别，
/// 消费方、判据方向、命中后果都不同（例：本表收 `不需要再搜索`、
/// `let me draft`；净化表收 `let me\b`，会把本表的窄式判成整行计划语）。
/// 结构锁按**声明名**扫「仓库里除了家文件还有没有第二张线索表」，本表原名
/// `_planningCue` 会被扫成抄了第二份（重合短语 `let me`）。合并任一侧都会改掉
/// build121 G3 或 168 的口径 ⇒ **不合并，改名说清它不是那张表**。
/// 若日后要往本表加条目，先问「这条是要净化正文，还是要判字面提及」，
/// 前者进 `react_parser.dart`，后者才进这里。
final RegExp _literalMentionProbe = RegExp(
  r'不需要再搜索|无需再搜索|不需要搜索了|不用再搜索|不用联网了|'
  r'直接给最终答复|直接给答案|直接输出答案|直接给出结论|'
  r'现在可以给用户|接下来给用户|'
  r'用 emoji|我用排版|'
  r"let me (?:now )?(?:draft|write|compose|finali[sz]e)|"
  r"i'll (?:draft|write|compose|finali[sz]e)|"
  r'(?:final answer|final response)\s*[:：]',
  caseSensitive: false,
);

/// 暂扣上限：超过即按真包裹放行（保持流式体验）。真实答案极少在开头
/// 600 字内出现 planning 自述；而字面提及的 cue 几乎总在最初几十字内。
const int _kAnswerHoldLimit = 600;

/// typed 流适配器：feed 进去的是 raw chunk，出来的是**有类型的块**。
///
/// 使用（流式）：
/// ```dart
/// final adapter = TypedStreamAdapter(isToolTag: (t) => kToolTags.contains(t));
/// for each SSE delta:
///   if (reasoning_content) adapter.feedReasoning(rc).forEach(emit);
///   if (content)           adapter.feedContent(c).forEach(emit);
///   if (tool_calls)        adapter.feedToolCalls(calls).forEach(emit);
/// adapter.flush().forEach(emit);   // 流末
/// ```
class TypedStreamAdapter {
  /// 判断某标签名是否是「工具类」标签（非 thinking/answer 的协议标签）。
  final ToolTagMatcher isToolTag;

  /// content 段当前所处块（裸文本 / thinking 块内 / answer 块内）
  String _mode = 'bare';

  /// 跨 chunk 残片缓冲（W5 的解法，逻辑与 ReactStreamScrubber 同源但更宽：
  /// 这里允许缓冲到能判定「是标签」还是「是正文」为止）
  String _pending = '';

  /// 裸文本累积（用于 [ChannelDecision.bareNeedsJudgment] 的判定）
  final StringBuffer bareWindow = StringBuffer();

  /// G3（build121）：`<answer>` 开标签后的**暂扣缓冲**。
  ///
  /// 旧行为（build115~120，实测 round7 真机帧误切）：见 `<answer>` 开标签即把
  /// 其后到流末全文当 answer——模型在正文里**字面提及** `<answer>`（如
  /// 「…给用户 `<answer>`。」后接 planning 自语）时，planning 被整段当结论。
  /// 现改为：见开标签先暂扣，见到闭合 → 真包裹放行；暂扣期内出现 planning
  /// cue → 判字面提及（cue 行归 thinking、其余归 answer）；超阈值无 cue →
  /// 按真包裹放行。
  final StringBuffer _answerHold = StringBuffer();
  bool _answerHoldActive = false;

  /// G33（build124）：**工具正文暂扣**——跨 chunk 切开的配对工具标签。
  ///
  /// 实测泄漏（nexus_export_2026-09-17T15-26 真机）：
  /// ```
  /// chunk A: <mcp_call plugin_id="amap" tool="maps_around_search">
  /// chunk B: {"keywords":"地铁站","location":"113.68,23.29","radius":"3000"}
  /// chunk C: </mcp_call>
  /// ```
  /// 旧实现在开标签处找不到闭合标签 → 正文未被消费 → chunk B 落到
  /// `_mode=='bare'` → **answer 件**（真机：typed 答案缓冲 68 字符 JSON，
  /// 轮末被兜底①当结论定稿、N14 suggest 拿它当【回答】）。
  ///
  /// 修法：开标签已见、闭合未到 → 进入 'tool' 块，其后文本一律进本缓冲，
  /// 直到 `</tag>` 或流末才产出 tool 件（参数进 `args['content']`，
  /// 与标签插件既有约定同构）。**正文归属由标签决定，不由 chunk 切分决定。**
  String? _toolBodyTag;
  String _toolBodyRawInner = '';
  Map<String, String>? _toolBodyAttrs;
  final StringBuffer _toolBody = StringBuffer();

  /// 是否收到过 reasoning_content（决定通道选择）
  bool gotReasoning = false;

  /// 是否收到过 content 段内的标签
  bool gotContentTag = false;

  /// G38（build129）：answer 件是否**来自未闭合答案段的 flush**。
  ///
  /// 语义：这段 answer 文本是「模型写到一半被打断 / 漏写 `</answer>`」的产物，
  /// **不构成结论**。真机实证（nexus_export_2026-09-19T10-05 / Round 4）：
  /// 轮末打点是 `typedAnswerBuf=0 / typedThinkingBuf=312`，模型只写了中文思考 +
  /// 英文套话「I'm sorry, but the video generation tool …」且未闭合 `<answer>`；
  /// 流末 flush 把这段思考态文本当 answer 件放出 → 下游流式兜底把它定稿成
  /// 用户可见的结论（打点里的 0 chars 正是 flush 之前的状态，故当时看不出异常）。
  ///
  /// 下游兜底据此拒绝定稿（文本回思考块，不静默丢弃）。
  bool answerFromUnclosedFlush = false;

  TypedStreamAdapter({required this.isToolTag});

  /// 通道选择：把「这次响应属于哪种情况」显式化，而不是让下游猜。
  ChannelDecision get decision {
    if (gotReasoning) return ChannelDecision.separated;
    if (gotContentTag) return ChannelDecision.tagged;
    return ChannelDecision.bareNeedsJudgment;
  }

  // ---------------------------------------------------------------------------
  // 入口一：reasoning_content —— 零猜测，直接 thinking
  // ---------------------------------------------------------------------------

  List<AgentItem> feedReasoning(String chunk) {
    if (chunk.isEmpty) return const [];
    gotReasoning = true;
    return [AgentItem.thinking(chunk, source: 'reasoning')];
  }

  // ---------------------------------------------------------------------------
  // 入口二：content —— 标签状态机切分（跨 chunk 容错）
  // ---------------------------------------------------------------------------

  /// 处理 content 段的 chunk，返回本次可确定的块。
  /// 不完整的内容（半截标签、块内未闭合）会被缓冲，由后续 chunk 或 [flush] 收尾。
  List<AgentItem> feedContent(String chunk) {
    if (chunk.isEmpty) return const [];
    var working = _pending.isNotEmpty ? _pending + chunk : chunk;
    _pending = '';
    final out = <AgentItem>[];

    while (working.isNotEmpty) {
      // 1) 结尾残片：可能是半截标签（跨 chunk 切开的 <thinking / < / <thin）
      final lastLt = working.lastIndexOf('<');
      if (lastLt >= 0) {
        final tail = working.substring(lastLt);
        if (!tail.contains('>') && _looksLikeTagPrefix(tail)) {
          _pending = tail;
          working = working.substring(0, lastLt);
          if (working.isEmpty) break;
        }
      }

      final lt = working.indexOf('<');
      if (lt < 0) {
        // 纯文本：按当前块类型归类
        _consumeText(out, working);
        break;
      }
      // 标签前的文本
      if (lt > 0) {
        _consumeText(out, working.substring(0, lt));
        working = working.substring(lt);
        continue;
      }
      // 以 '<' 开头：找标签闭合
      final gt = working.indexOf('>');
      if (gt < 0) {
        // 不该到这里（残片已在上面处理）；保守缓冲
        _pending = working;
        break;
      }
      final rawInner = working.substring(1, gt); // 例：'thinking' / '/thinking' / 'ws_write path="a" /'
      final selfClosed = rawInner.trimRight().endsWith('/');
      final isClose = rawInner.trimLeft().startsWith('/');
      final tagName = _tagNameOf(rawInner);
      working = working.substring(gt + 1);

      if (tagName.isEmpty) {
        // `<` 后不是合法标签名（如比较符 `a <b>` 的 `<b>`）→ 当正文
        _consumeText(out, '<$rawInner>');
        continue;
      }
      if (tagName == 'thinking' || tagName == 'think') {
        gotContentTag = true;
        // G33：块互斥——工具正文暂扣中又出现块标签 → 先结算工具件
        // （否则 `_mode` 被改写成 thinking，其后的参数文本会走错通道）
        if (!isClose && _toolBodyTag != null) out.add(_flushToolBody());
        if (_mode == 'answer') {
          // W5-2（真机复现）：answer 块内又输出 thinking 标签 → 只剥标签本身，
          // 不切换模式（暂扣中的 answer 内容不受影响）
          continue;
        }
        _mode = isClose ? 'bare' : 'thinking';
        continue;
      }
      if (tagName == 'answer') {
        gotContentTag = true;
        // G33：块互斥（同上）——工具正文暂扣中见到 <answer> 开标签
        if (!isClose && _toolBodyTag != null) out.add(_flushToolBody());
        if (isClose) {
          // 闭合 → 真包裹：暂扣内容整段放行为 answer
          if (_answerHoldActive) out.addAll(_flushAnswerHold());
          _mode = 'bare';
          continue;
        }
        if (_answerHoldActive) {
          // 上一个开标签还没等到闭合又来一个 → 先按无 cue 结算（不吞内容），
          // 再开始新的暂扣
          out.addAll(_flushAnswerHold());
        }
        _mode = 'answer';
        _answerHoldActive = true;
        _answerHold.clear();
        continue;
      }
      if (isToolTag(tagName)) {
        gotContentTag = true;
        // G33：闭合标签到达 → 结算先前暂扣的工具正文（跨 chunk 切开的配对标签）
        if (isClose) {
          if (_toolBodyTag == tagName) out.add(_flushToolBody());
          // 无对应开标签的游离闭合标签：丢弃（旧实现会产出一个无参 tool 件，
          // 下游按「插件未找到」报错，纯噪声）
          continue;
        }
        final args = _parseTagAttrs(rawInner);
        if (selfClosed) {
          out.add(AgentItem.tool(tagName, args,
              content: rawInner, source: 'tag'));
          continue;
        }
        // 配对写法的正文（如 <ws_write>正文</ws_write>）：读直到闭合标签，
        // 正文放进 args['content']（与标签插件的既有约定同构）
        final closeTag = '</$tagName>';
        final ci = working.toLowerCase().indexOf(closeTag.toLowerCase());
        if (ci >= 0) {
          final body = working.substring(0, ci).trim();
          if (body.isNotEmpty && !args.containsKey('content')) {
            args['content'] = body;
          }
          working = working.substring(ci + closeTag.length);
          out.add(AgentItem.tool(tagName, args,
              content: rawInner, source: 'tag'));
          continue;
        }
        // G33：闭合未到（跨 chunk）→ **暂扣正文**，后续文本一律归工具参数，
        // 绝不落入 bare→answer
        if (_toolBodyTag != null) out.add(_flushToolBody());
        _toolBodyTag = tagName;
        _toolBodyRawInner = rawInner;
        _toolBodyAttrs = args;
        _mode = 'tool';
        continue;
      }
      // 未知标签：**默认不吞**——原样当正文（宁可多显示，也不丢内容）
      _consumeText(out, '<$rawInner>');
    }
    return out;
  }

  void _consumeText(List<AgentItem> out, String text) {
    if (text.isEmpty) return;
    switch (_mode) {
      case 'thinking':
        out.add(AgentItem.thinking(text, source: 'content-tag'));
        break;
      case 'answer':
        if (_answerHoldActive) {
          // G3：暂扣期内不直接产出，先攒着等「闭合 / cue / 超阈值」三选一
          _answerHold.write(text);
          if (_answerHold.length > _kAnswerHoldLimit) {
            out.addAll(_flushAnswerHold());
          }
          break;
        }
        out.add(AgentItem.answer(text, source: 'content-tag'));
        break;
      case 'tool':
        // G33：工具正文（配对工具标签的开闭被 chunk 切开）——参数文本
        // **只进工具缓冲**，不产 answer 件、不进 bareWindow（否则轮末兜底
        // 会把 JSON 参数当结论定稿）。落点：`</tag>` 或流末结算。
        _toolBody.write(text);
        break;
      default:
        // 裸文本：content 字段语义＝给用户的正文 → 默认 answer（零猜测）
        bareWindow.write(text);
        out.add(AgentItem.answer(text, source: 'content-bare'));
    }
  }

  /// G3：结算暂扣的 `<answer>` 后内容。
  ///
  /// - 含 planning cue → **字面提及**：cue 所在行起的连续 cue 行归 thinking
  ///   （最多 8 行，与旧链 L1 的「开头连续行」语义一致但位置在内核），
  ///   其余归 answer；
  /// - 不含 cue → 按真包裹放行（整段 answer）。
  List<AgentItem> _flushAnswerHold() {
    _answerHoldActive = false;
    final held = _answerHold.toString();
    _answerHold.clear();
    final out = <AgentItem>[];
    final cueMatch = _literalMentionProbe.firstMatch(held);
    if (cueMatch == null) {
      out.add(AgentItem.answer(held, source: 'content-answer'));
      return out;
    }
    // 字面提及：从 cue 所在行起，连续 cue 行归 thinking
    final lineStart = held.lastIndexOf('\n', cueMatch.start) + 1;
    var idx = lineStart;
    var cueEnd = lineStart;
    var cueLines = 0;
    while (idx < held.length && cueLines < 8) {
      final nl = held.indexOf('\n', idx);
      final line =
          (nl < 0 ? held.substring(idx) : held.substring(idx, nl)).trim();
      if (line.isEmpty) {
        idx = nl < 0 ? held.length : nl + 1;
        continue;
      }
      if (!_literalMentionProbe.hasMatch(line)) break;
      cueEnd = nl < 0 ? held.length : nl + 1;
      cueLines++;
      idx = cueEnd;
    }
    if (cueLines == 0) {
      // cue 只出现在行中（该行整体是正文）→ 不拆行，整段归 answer
      out.add(AgentItem.answer(held, source: 'content-answer'));
      return out;
    }
    final before = held.substring(0, lineStart);
    if (before.trim().isNotEmpty) {
      // cue 行之前的残句（如「…给用户 `<answer>`」的尾巴）——仍归 answer，
      // 字面标签残片由 finalize 的 stripTags 确定性剥除
      out.add(AgentItem.answer(before, source: 'content-answer'));
    }
    out.add(AgentItem.thinking(held.substring(lineStart, cueEnd),
        source: 'content-planning-cue'));
    final rest = held.substring(cueEnd);
    if (rest.trim().isNotEmpty) {
      out.add(AgentItem.answer(rest, source: 'content-answer'));
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // 入口三：tool_calls（FC 通道）—— 结构化，零猜测
  // ---------------------------------------------------------------------------

  List<AgentItem> feedToolCalls(List<Map<String, dynamic>> calls) {
    final out = <AgentItem>[];
    for (final c in calls) {
      final name = c['name']?.toString() ?? '';
      if (name.isEmpty) continue;
      final args = <String, String>{};
      final rawArgs = c['arguments'];
      if (rawArgs is Map) {
        rawArgs.forEach((k, v) => args[k.toString()] = v.toString());
      }
      out.add(AgentItem.tool(name, args, source: 'fc'));
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // 流末：把缓冲与未闭合块收尾（**默认不吞**）
  // ---------------------------------------------------------------------------

  List<AgentItem> flush() {
    final out = <AgentItem>[];
    if (_pending.isNotEmpty) {
      // 残留的半截标签：按当前块类型归位（不丢内容）
      // G33：若正处于工具正文模式，这里会写进工具正文缓冲（而不是答案）
      _consumeText(out, _pending);
      _pending = '';
    }
    if (_toolBodyTag != null) {
      // G33：工具正文暂扣到流末仍未闭合（模型漏写闭合标签/流被截断）
      // → 用已收正文结算 tool 件（参数不丢、也不许落进答案）
      out.add(_flushToolBody());
    }
    if (_answerHoldActive) {
      // G3：流末仍无闭合 → 按「字面提及 vs 真包裹」判别结算（默认不吞）
      out.addAll(_flushAnswerHold());
      // G38（build129）：这次 answer 件的来源是「未闭合的答案段」——
      // 它不是一句写完的结论，下游兜底不得据此定稿（见 answerFromUnclosedFlush）。
      answerFromUnclosedFlush = true;
      _mode = 'bare';
    }
    if (_mode != 'bare') {
      // 未闭合块（模型中途停止/出错）：把「块类型」信息交给下游（不静默改类）
      if (_mode == 'answer') {
        out.add(const AgentItem.answer('', source: 'unclosed'));
        // G38：同上——未闭合的 answer 段不算结论
        answerFromUnclosedFlush = true;
      } else {
        out.add(const AgentItem.thinking('', source: 'unclosed'));
      }
      _mode = 'bare';
    }
    return out;
  }

  /// G33：结算暂扣的工具正文 → tool 件（正文进 `args['content']`）。
  AgentItem _flushToolBody() {
    final tag = _toolBodyTag!;
    final args = Map<String, String>.from(_toolBodyAttrs ?? const {});
    final body = _toolBody.toString().trim();
    if (body.isNotEmpty && !args.containsKey('content')) {
      args['content'] = body;
    }
    final rawInner = _toolBodyRawInner;
    _toolBodyTag = null;
    _toolBodyAttrs = null;
    _toolBodyRawInner = '';
    _toolBody.clear();
    _mode = 'bare';
    return AgentItem.tool(tag, args, content: rawInner, source: 'tag-deferred');
  }

  /// 未闭合块的类型（flush 后调用；null 表示没有未闭合块）。
  /// 流中可能返回 'tool'（G33：配对工具标签跨 chunk 切开、正文暂扣中）。
  String? get openBlock => _mode == 'bare' ? null : _mode;

  // ---------------------------------------------------------------------------
  // 内部工具
  // ---------------------------------------------------------------------------

  /// `tail` 是否「像标签开头」：`<` 后只出现字母 / `/` / 空白（允许为空）。
  /// 含数字/中文/其它符号 → 不是标签（如 `a <b` 后的中文比较场景），放回正文。
  static bool _looksLikeTagPrefix(String tail) {
    if (tail.isEmpty || tail[0] != '<') return false;
    if (tail.length > 64) return false; // 标签名不可能这么长 → 判定为正文
    for (var i = 1; i < tail.length; i++) {
      final c = tail[i];
      final isLetter = RegExp(r'[a-zA-Z]').hasMatch(c);
      if (!isLetter && c != '/' && c != '_' && c != ' ') return false;
    }
    return true;
  }

  static String _tagNameOf(String rawInner) {
    var t = rawInner.trim();
    if (t.startsWith('/')) t = t.substring(1);
    t = t.trim();
    if (t.endsWith('/')) t = t.substring(0, t.length - 1).trim();
    final sp = t.indexOf(RegExp(r'\s'));
    if (sp > 0) t = t.substring(0, sp);
    if (t.isEmpty) return '';
    if (!RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$').hasMatch(t)) return '';
    return t.toLowerCase();
  }

  static Map<String, String> _parseTagAttrs(String rawInner) {
    final out = <String, String>{};
    final sp = rawInner.indexOf(RegExp(r'\s'));
    if (sp <= 0) return out;
    final attrsRaw = rawInner.substring(sp);
    for (final m in RegExp(r'([a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*"([^"]*)"')
        .allMatches(attrsRaw)) {
      out[m.group(1)!] = m.group(2)!;
    }
    return out;
  }

  /// FC 通道 arguments 的 JSON 串 → Map（供既有 dispatch 复用）
  static Map<String, String> argsFromJson(String raw) {
    try {
      final d = jsonDecode(raw);
      if (d is Map) {
        return d.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
    } catch (_) {}
    return <String, String>{};
  }
}
