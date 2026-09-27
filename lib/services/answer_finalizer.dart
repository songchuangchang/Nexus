import 'dart:convert';

import 'react_parser.dart';

/// 答案定稿的**唯一出口**（对标业界「唯一归一层 + 单一答案出口 + 默认不吞」）。
///
/// **为什么必须收口**：本项目曾有四个「把模型流定稿成消息」的出口——
/// ① 主流式（`_sendMessage` 流末）
/// ② ReAct 循环主出口
/// ③ ReAct 流式兜底 / 裸文本兜底
/// ④ 续写（`_continueFromMessage`）
///
/// 每轮修复都会漏掉第 N 个：build101 F4 漏了续写、build103 I4 漏了兜底分支、
/// build111 B-030 才补上续写的标签净化。收口前的实测缺口是——`stripControlTags`
/// 四口都有（B-030 补齐后），但**头部过程话术剥离 `stripLeadingMetaTalk` 只接了
/// ReAct 三处，主流式与续写这两口一直在漏**（即 L1 问题在直聊场景根本没人管）。
/// 这正是「同一个容错写 N 遍、必漏一处」的结构性表现。
///
/// 业界三家范式（Chatbox 的 API 字段硬分离 / Codex 的类型化事件块 / ChatGPT 的
/// 服务端分通道）共同骨架是同一件事：**容错只写一遍，出口只有一个**。本类即该
/// 出口的最小可用形态——纯函数、可单测、无副作用。
///
/// 边界说明：**动作副作用**（memory_write 落库 / todo 合并 / suggest 收编 / card
/// 渲染）语义因出口而异（续写明确不执行副作用动作），仍由调用方在解析阶段处理；
/// 本类只负责「正文净化」这一确定性部分。
class AnswerFinalizer {
  AnswerFinalizer._();

  /// G38（build129）：**英文占位/拒答套话**模板开头（前 200 字符内匹配即算命中）。
  ///
  /// 词表刻意收窄到「明确的道歉/拒答开场」，不含 may/might 之类模糊措辞——
  /// 误判的代价是用户看不到本该看到的答案，必须比漏判更保守。
  static final RegExp _placeholderOpen = RegExp(
    r"^(i'?m sorry\b|i am sorry\b|sorry\s*,|i apologi[sz]e\b|i'?m unable to\b|"
    r"i am unable to\b|i'?m not able to\b|i cannot (assist|help|complete|generate|provide)\b|"
    r"i can'?t (assist|help|complete|generate|provide)\b|as an ai\b)",
    caseSensitive: false,
  );

  /// G38（build129）：判定一段文本是否是**上游占位/拒答套话**。
  ///
  /// 真机实证（nexus_export_2026-09-19T10-05 / Round 4）：未闭合的 `<answer>` 段里
  /// 只有中文思考 + 英文套话「I'm sorry, but the video generation tool …」；
  /// 内核流末 flush 把它当 answer 件放出后，**这句英文道歉成了用户可见的结论**，
  /// 而真正该说的话（本机缺视频模型 → 去设置里填）没人说。
  ///
  /// 三条判据**同时**满足才算命中（过窄好过误杀）：
  ///  ① 整段不含 CJK —— 中文用户的中文回答/中文拒答（如「抱歉，我无法…」）永不误中；
  ///  ② 开头命中 [_placeholderOpen]（允许前导 markdown 噪声：引用符/星号/井号等）；
  ///  ③ 长度 < 400 —— 长回答里引用这句式属正常表达，不算套话。
  static bool isPlaceholderTemplate(String text) {
    final t = text.trim();
    if (t.isEmpty || t.length >= 400) return false;
    // ① 无 CJK
    if (RegExp(r'[\u4e00-\u9fff\u3400-\u4dbf]').hasMatch(t)) return false;
    // ② 剥前导 markdown 噪声后再看开头（长度按 head 自身夹取，避免 substring 越界）
    final head = t.replaceFirst(RegExp(r'^[\s>*#\-•·"\x27`]+'), '');
    final probe = head.length < 200 ? head : head.substring(0, 200);
    return _placeholderOpen.hasMatch(probe);
  }

  /// 剥离控制标签与 suggest 标签（纯函数）。
  ///
  /// - `stripControlTags` 剥内部控制标签（memory_write / todo / search /
  ///   download / mcp_call 等），**代码围栏内不动**；
  /// - `<answer>` 包装**解壳保留正文**（build116 检测批：不能把 answer 加进
  ///   控制标签集——stripControlTags 对配对块是「连体删除」，会把答案正文一起
  ///   吞掉；解壳必须单独做）；
  /// - `suggest` 不在控制集，单独剥三种写法：自闭合 `<suggest ... />`、
  ///   配对 `<suggest>…</suggest>`、裸 `<suggest>` / `</suggest>`。
  ///
  /// AF-2（B4）：带属性的**未闭合开标签**（真机样本 `<suggest foo="bar">`
  /// 后无 `</suggest>`）三种写法都不命中，标签原文残留在答案里。此处补
  /// 「带属性的开/闭标签」剥离，与既有的无属性写法兼容。
  static String stripTags(String raw) {
    if (raw.isEmpty) return raw;
    final unwrapped = _unwrapAnswerWrapper(raw);
    return stripControlTags(unwrapped)
        .replaceAll(RegExp(r'<suggest\b[^>]*/>', caseSensitive: false), '')
        .replaceAll(
            RegExp(r'<suggest>[\s\S]*?</suggest>', caseSensitive: false), '')
        // AF-2：配对标签（开标签允许带属性）——须排在「裸开标签」之前，
        // 否则 `<suggest a="1">正文</suggest>` 会先被裸标签规则切碎。
        .replaceAll(
            RegExp(r'<suggest\b[^>]*>[\s\S]*?</suggest\s*>',
                caseSensitive: false),
            '')
        // AF-2：残留的裸开/闭标签（允许带属性），含未闭合形态
        .replaceAll(RegExp(r'</?suggest\b[^>]*>', caseSensitive: false), '')
        .trim();
  }

  /// `<answer>正文</answer>` → 正文（代码围栏内不动）；游离的开/闭标签单独删除。
  static String _unwrapAnswerWrapper(String text) {
    final parts = text.split('```');
    for (var i = 0; i < parts.length; i += 2) {
      var t = parts[i];
      var prev = '';
      while (prev != t) {
        prev = t;
        t = t.replaceAllMapped(
          RegExp(r'<answer>([\s\S]*?)</answer>', caseSensitive: false),
          (m) => m.group(1) ?? '',
        );
      }
      t = t.replaceAll(RegExp(r'</?answer\s*>', caseSensitive: false), '');
      parts[i] = t;
    }
    return parts.join('```');
  }

  /// 定稿净化：标签剥离 + 头部过程话术剥离（L1）+ 占位 URL 剥除（W2b）。
  ///
  /// 返回记录：
  /// - `clean`：可落库/展示的正文；
  /// - `stripped`：被剥掉的过程话术/占位链接原文。**非空时调用方必须记日志
  ///   （或回思考面板），不得静默丢弃**——这是「默认不吞、异常可见」原则的落地。
  static ({String clean, String stripped}) finalize(String raw) {
    final noTags = stripTags(raw);
    final (talk, stripped) = stripLeadingMetaTalk(noTags);
    // build114（补充单03 W4-2）：中文元过程自语剥离——与 O4/L1 同链唯一出口，
    // 被剥内容由调用方统一回思考面板（默认不吞、异常可见）。
    final (talk2, zhProcess) = stripChineseMetaProcess(talk);
    final (clean, fakeUrls) = scrubPlaceholderUrls(talk2);
    final parts = <String>[
      if (stripped.isNotEmpty) stripped,
      if (zhProcess.isNotEmpty) '（剥除中文过程自语）\n$zhProcess',
      if (fakeUrls.isNotEmpty) '（剥除占位链接）\n$fakeUrls',
    ];
    return (
      clean: clean.trim(),
      stripped: parts.isEmpty ? '' : parts.join('\n'),
    );
  }

  // ==========================================================================
  // W2b（补充单02）：占位 URL 硬规则
  // ==========================================================================

  /// 含占位符的 URL：`xxxx` 占位坐标（真机样本：打车结论
  /// `dest=113.xxxx,23.xxxx`，点开地图终点错误）、`{{...}}` 模板占位、
  /// 尖括号未填参数。工具失败后编造这类链接当结论，比不给链接更糟。
  static final RegExp _placeholderUrlPattern = RegExp(
    r'https?://[^\s<>)\]】」」]*'
    r'(?:xxxx|XXXX|XXXXXX|\{\{[^}\s]*\}\}|<[a-zA-Z_][a-zA-Z0-9_]*>)'
    r'[^\s<>)\]】」]*',
    caseSensitive: false,
  );

  /// 剥掉含占位符的 URL（保留其余文字——「降级为纯文字方案」），返回
  /// `(clean, removed)`；removed 为被剥 URL 原文（空格连接），空串表示无占位。
  static (String, String) scrubPlaceholderUrls(String text) {
    final matches = _placeholderUrlPattern.allMatches(text).toList();
    if (matches.isEmpty) return (text, '');
    final removed = matches.map((m) => m.group(0)!).join('  ');
    final clean = text
        .replaceAll(_placeholderUrlPattern, '')
        .replaceAll(RegExp(r'[ \t]+\n'), '\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
    return (clean, removed);
  }

  // ==========================================================================
  // G35（build124）：控制片段判定——「这根本不是给用户的话」
  // ==========================================================================

  /// 工具调用协议片段（`<mcp_call ...>{"k":"v"}</mcp_call>`、`{"keywords":...}`、
  /// `</|invoke|>` 残片…）：**不是给用户看的文字**。
  ///
  /// 为什么需要它（真机 nexus_export_2026-09-17T15-26）：mcp 参数 JSON 因跨
  /// chunk 切开而漏进答案缓冲 → 轮末兜底①把它当结论定稿 → N14 suggest 拿这段
  /// JSON 当【回答】补出 3 条无关追问。G33 已在源头修掉泄漏，本函数是**第二道
  /// 确定性闸门**：任何出口在把文本当「给用户的答案」前，先过这一关。
  ///
  /// 判据刻意保守（只认结构，不做词表猜写）：
  /// - 整段（去空白后）就是一个 JSON 对象/数组 —— 参数体；
  /// - 整段只由 ReAct 控制标签 + 空白组成 —— 标签残片；
  /// - 含 `<|invoke|>` / `<|parameter|>` / `<|tool_calls|>` 的 ChatML 片段；
  /// - build156（真机 P1）：含 **DSML 方言**（全角 `｜` U+FF5C 成对 +
  ///   `DSML` 这类命名空间段）的片段——`<｜｜DSML｜｜ calls>` / `</｜｜DSML｜｜ invoke`。
  ///   原实现的兜底正则只认 ASCII 竖线 `\|`，全角一字之差 ⇒ 整坨方言被当正文
  ///   定稿显示。判据现与解析入口**同源**（react_parser 的 hasChatMlToolCall /
  ///   hasToolDialectTag，两条正则都带 caseSensitive:false），不再在此手写，
  ///   免得两处规则漂移（本仓「同一个容错写 N 遍必漏一处」的老账）。
  /// 只要句子里有**人类可读的其它内容**（中文/英文词），一律判 false——
  /// 宁可不拦，不可误杀真答案。
  static bool isControlFragment(String text) {
    final t = text.trim();
    if (t.isEmpty) return false;
    if (t.length < 2) return false;
    // ① 整段就是一个 JSON 对象/数组（工具入参）
    if ((t.startsWith('{') && t.endsWith('}')) ||
        (t.startsWith('[') && t.endsWith(']'))) {
      try {
        final d = jsonDecode(t);
        if (d is Map || d is List) return true;
      } catch (_) {
        // 不是合法 JSON → 交给下面的判据（可能是含标签的残段）
      }
    }
    // ② ChatML 残留 / DSML 方言残留（含跨分片的半截 `<｜｜DSML｜｜ inv`）
    if (hasChatMlToolCall(t) || hasToolDialectTag(t)) {
      return true;
    }
    // ③ 整段只由控制标签 + 空白组成（`<mcp_call ...>{"a":1}</mcp_call>` 之类）
    final stripped = stripControlTags(t)
        .replaceAll(RegExp(r'\s+'), '')
        .trim();
    if (stripped.isEmpty) return true;
    // 剥掉标签后只剩 JSON 参数体 → 仍是控制片段
    if ((stripped.startsWith('{') && stripped.endsWith('}')) ||
        (stripped.startsWith('[') && stripped.endsWith(']'))) {
      try {
        final d = jsonDecode(stripped);
        if (d is Map || d is List) return true;
      } catch (_) {
        return false;
      }
    }
    return false;
  }
}
