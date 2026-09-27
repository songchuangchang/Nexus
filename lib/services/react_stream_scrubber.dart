import 'react_parser.dart';

/// build114（补充单03 W5）：ReAct 流式标签剥离的**纯函数**化。
///
/// 从 `_ChatScreenState._stripReActTagsForStream` 抽出，使跨 chunk 切片问题
/// （孤立 `<`、`</`、半截标签名跨块、`< thinking>` 畸形空格）可单测——
/// 这类问题此前是 `_ChatScreenState` 私有方法，745 条测试一条都挡不住。
///
/// 状态（pendingTag / inAnswer）由调用方持有并在 chunk 间传递；
/// answerSink 输出改为返回值 `answerOut` 由调用方写入。
///
/// build156（真机 P1）：DSML 工具方言（全角竖线 `｜` + 命名空间段 `｜｜DSML｜｜`）
/// 的**展示侧**接线。归一化本身**不在这里实现**——直接复用解析入口那一处
/// [normalizeToolDialect]（react_parser，理由见该函数头注），本文件只做两件
/// 它自己才有的事：① 跨 chunk 的半截方言标签**暂存**（等下一片）；
/// ② 归一化后仍残留的命名空间头**残片**兜底删除。
class ReactStreamScrubber {
  ReactStreamScrubber._();

  /// 跨分片暂存的方言标签上限：真机一条 invoke 的 content 属性可以到几 KB，
  /// 但超过本值说明它根本不是待闭合的标签（或流已坏）——照旧放行，不吞正文。
  static const int _maxDialectPending = 4000;

  /// 处理一个 chunk。
  ///
  /// - [s]：本 chunk 原文；
  /// - [pendingTag]：上一 chunk 扣留的残片（无则传空串）；
  /// - [inAnswer]：上一 chunk 结束时是否已进入 answer 块；
  /// - [askUserSeen]：上一 chunk 结束时是否已见过 `<ask_user>` 开标签
  ///   （A1/W6 提问轮止血用，调用方原样回传）。
  ///
  /// 返回：
  /// - `display`：本 chunk 可展示正文（标签已剥、trim）；
  /// - `pendingTag`：新的残片（无则空串），调用方原样传回下一 chunk；
  /// - `inAnswer`：新的 answer 块状态；
  /// - `answerOut`：应追加到 answerSink 的内容（可为空串）；
  /// - `askUserSeen`：本 chunk 起是否已出现 ask_user 开标签（跨 chunk 累加）。
  static ({
    String display,
    String pendingTag,
    bool inAnswer,
    String answerOut,
    bool askUserSeen,
  }) scrub(String s,
      {required String pendingTag,
      required bool inAnswer,
      bool askUserSeen = false}) {
    var working = pendingTag.isNotEmpty ? pendingTag + s : s;
    var newPending = '';

    // build156（真机 P1）：DSML 方言**先归一化再剥离**——归一化用的是解析入口
    // 那唯一一处实现 [normalizeToolDialect]（react_parser），本文件不重写规则。
    // 完整标签 → 扁平 `<ws_write … />`（属性经 _xmlAttrEscape，值内不再有裸 `>`）
    // → 交给下面的既有剥离规则；未闭合的半截标签匹配不到，原样留在 working，
    // 由下面的「末尾残片暂存」扣到下一 chunk。
    working = normalizeToolDialect(working);

    // A1（W6）：提问轮止血——一旦本轮出现 <ask_user> 开标签，其后流出的
    // answer 块内容不得再写进答案气泡（否则反问卡片与结论同屏）。
    // 判定放在 pendingTag 拼接之后，跨 chunk 切开的标签名也能命中。
    final sawAskUser =
        askUserSeen || RegExp(r'<ask_user\b', caseSensitive: false).hasMatch(working);

    // W5-1：末尾残片暂存判定**放宽**——旧实现要求 `<` 后已紧跟字母或 `/`
    // （`^<[a-zA-Z/]`），chunk 恰好以孤立 `<`（或 `<` 后跟空白）结尾时不暂存，
    // 字面 `<thinking>` / `/thinking>` 残片因此流进思考面板。
    // 新判定：`<` 后（忽略空白）只出现字母 / `/` / 空白（**允许为空**）即暂存；
    // 数字/中文/其它符号（如 `a <b 的结果` 的 ` 的结果`）不匹配 → 放回正文，
    // 保证比较运算符等正文不被吞。
    // 末尾残片暂存的起点候选：
    //   ① 既有的「最后一个孤立 `<`」（半截普通标签）；
    //   ② build156（真机 P1）：最后一个**未闭合的方言标签起始**——起点必须取
    //      `<｜｜` 那一处，而不是最后一个 `<`：一条 invoke 的 content 属性值里
    //      常含真 HTML（`content="<html><b>x</b>"`），最后一个 `<` 落在值内部，
    //      那段文本看着像「已闭合标签」，于是半截方言会带着属性流进气泡。
    var holdFrom = -1;
    final lastLt = working.lastIndexOf('<');
    if (lastLt >= 0) {
      final tail = working.substring(lastLt);
      if (!tail.contains('>') && RegExp(r'^</?[a-zA-Z/\s]{0,80}$').hasMatch(tail)) {
        holdFrom = lastLt;
      }
    }
    int? dialectStart;
    for (final m in kDialectTagStart.allMatches(working)) {
      dialectStart = m.start;
    }
    if (dialectStart != null &&
        kDialectTag.matchAsPrefix(working, dialectStart) == null &&
        working.length - dialectStart <= _maxDialectPending) {
      if (holdFrom < 0 || dialectStart < holdFrom) holdFrom = dialectStart;
    }
    if (holdFrom >= 0) {
      newPending = working.substring(holdFrom);
      working = working.substring(0, holdFrom);
    }

    final sink = StringBuffer();
    var ans = inAnswer;

    // 上一 chunk 已进入 answer 块：内容流入 sink，直到 </answer> 为止
    if (ans) {
      // W5-2：answer 块内模型又输出半截/完整 <thinking> 开标签（真机复现）——
      // 只剥标签本身（标签内语义归宿主剥离链），防字面标签进 answerSink
      working = working.replaceAll(
          RegExp(r'</?thinking\b[^>]*>', caseSensitive: false), '');
      final closeIdx = working.toLowerCase().indexOf('</answer>');
      if (closeIdx < 0) {
        // W5-2：块内半截开标签不再直接进 sink——残片已被上面暂存判定拦下
        //（`<think` 这类字母残片符合放宽后的暂存条件）；
        // 拼不成标签的（含中文/数字）同样被暂存判定放回正文，不会吞正文。
        sink.write(working);
        return (
          display: '',
          pendingTag: newPending,
          inAnswer: true,
          answerOut: sink.toString(),
          askUserSeen: sawAskUser,
        );
      }
      sink.write(working.substring(0, closeIdx));
      ans = false;
      working = working.substring(closeIdx + '</answer>'.length);
    }

    // 本 chunk 出现 <answer>（后随 > 或空白才认，避免吞 <answer_format> 等文本）
    final ansMatch =
        RegExp(r'<answer(?=[\s>])', caseSensitive: false).firstMatch(working);
    if (ansMatch != null) {
      final ansStart = ansMatch.start;
      final tagEnd = working.indexOf('>', ansStart);
      if (tagEnd >= 0) {
        final closeIdx = working.toLowerCase().indexOf('</answer>', tagEnd);
        if (closeIdx >= 0) {
          sink.write(working.substring(tagEnd + 1, closeIdx));
          working = working.substring(0, ansStart) +
              working.substring(closeIdx + '</answer>'.length);
        } else {
          sink.write(working.substring(tagEnd + 1));
          working = working.substring(0, ansStart);
          ans = true;
        }
      } else {
        // 极少见：<answer 的 '>' 还没到——残片存回 pendingTag 等下一 chunk
        newPending = working.substring(ansStart) + newPending;
        working = working.substring(0, ansStart);
      }
    }

    // 其余标签剥离（自闭合 <search/> / mcp_call / 配对 <thinking> 等；
    // W5-1 附带：畸形空格标签 `< thinking>` 同样被 `</?[^>]+>` 覆盖剥除）
    final display = working
        .replaceAll(
          RegExp(r'<mcp_call\b[^>]*>[\s\S]*?</mcp_call\s*>',
              caseSensitive: false),
          '',
        )
        .replaceAll(
          RegExp(r'<(plugin_detail|mcp_detail|skill_detail)\b[^>]*?/>',
              caseSensitive: false),
          '',
        )
        .replaceAll(RegExp(r'<[^>]+/>'), '')
        .replaceAll(RegExp(r'</?[^>]+>'), '')
        .trim();
    return (
      display: display,
      pendingTag: newPending,
      inAnswer: ans,
      answerOut: sink.toString(),
      askUserSeen: sawAskUser,
    );
  }
}
