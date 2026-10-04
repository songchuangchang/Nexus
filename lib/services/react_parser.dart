import 'dart:convert';

// build164（#82）：阶段小结要产出 `ReasoningStep`（见 [buildProgressNoteStep]），
// 该类型住在 models 层——解析器本来就负责「片段 → 结构」这一层，不引入反向依赖
// （chat_message.dart 不认识本文件）。
import '../models/chat_message.dart';

/// ReAct 协议全部标签名（parseReActOutput 支持的全集，含 think 别名）。
/// v1.7.40 build93 (N7)：非流式 completeChat 的「content 是否含 ReAct 标签」
/// 检测必须引用本常量，与解析器同源，防止两处手写集合不同步再漏标签
/// （曾漏 suggest/todo/memory_write/install_mcp/card，被外包 <answer> 吞掉）。
const List<String> kReActTagNames = [
  'thinking',
  'think', // <thinking> 的历史别名
  'search',
  'download',
  'self_check',
  'answer',
  'ask_user',
  'suggest',
  'todo',
  'memory_write',
  'memory_delete', // N8（build94）：记忆删除，双通道对齐
  'get_location', // build106：设备 GPS 精确定位（双通道）
  'ip_locate', // build104（U3）：IP 城市级定位（build106 补接线）
  'query_quota', // build108（Q1）：API 余额/用量查询（双通道）
  'log_query', // build104（M2c）：日志查询（build109 补解析接线，#56 第三次）
  'mcp_call',
  'skill_call',
  'plugin_detail',
  'mcp_detail',
  'skill_detail',
  'install_skill',
  'install_mcp',
  // build114（元测试抓出的第 5 例漏网）：connector_guide 教模型输出
  // <connector_guide />（声明已引用指南、可见化），却从未入表——标签一直
  // 被当纯文本吞掉、插件 handle 从未被 dispatch。
  'connector_guide',
  // build122：图片/视频生成（生成类动作标签）
  'image_gen',
  'video_gen',
  // build114（补充单02 W1）：AI 文件工作区 6 动作——build113 起四张表漏登记，
  // 标签通道第一关即断（hasReActTag=false → 整段当答案定稿、标签泄漏进气泡）。
  // 第 4 次同型复发（N7 漏 suggest/todo / U9 漏 kBuiltinRoutableTriggers /
  // #56 log_query 第三次 / 本次 ws），已加「根治元测试」强制对表。
  'ws_list',
  'ws_read',
  'ws_write',
  'ws_delete',
  'ws_download',
  'ws_export',
  // build136（G66/G67）：工作区新增「精准改文件 + 检索」两动作——同表纪律，
  // 四张表必须同时登记（元测试 react_tag_detect_test 强制对表）。
  'ws_patch',
  'ws_grep',
  // build138（G61-G64）：ws_make_file 生成真 xlsx/docx/pdf（四表同步登记）
  'ws_make_file',
  'card',
  // G37（build124）：ChatML 归一化产出的「不可识别工具块」标记。它必须入表，
  // 否则归一化后的标记又变成纯文本（同型复发第 5 次）。语义＝显式失败：
  // 宿主回灌教学 toolresult，绝不假装成功。
  'unknown_tool_call',
  // build164（#82）：阶段小结标签。用户拿别的 App 的截图当理想形态——多轮工具
  // 调用中间要有一句**给人看**的进展（「我再深入查一下三款产品的具体责任和44岁的费率。」），
  // 而不是全埋在折叠 thinking 里。漏登记的后果照旧是第 8 次同型复发（标签被当纯文本吞掉）。
  // 刻意**不**进 [kNonToolTagNames] ⇒ 自动属于 [kToolTagNames]：typed 内核会把它的
  // 正文按「工具件」暂扣，既不会流进答案气泡、也不会流进思考气泡（详见该内核 G33 段）。
  // 已知代价：`<progress>` 同名单签也在 [kReActControlTagNames] 里，所以答案正文里
  // **行内 HTML** 的 `<progress value="…">` 会被净化链剥掉（代码围栏内不受影响，
  // `stripControlTags` 按 ``` 分段）。取这个名字是为了让模型写得自然（协议可读性优先）；
  // 若真机出现「用户要 HTML 进度条却被剥」，改名只需动本表 + 两处协议文案（解析分支认
  // [kProgressTagName]，不再有第二份正则）。
  'progress',
  // build180（刀二）：内置浏览器四个动作（总闸 browser_feature_flag 默认关）。
  // 漏登记的后果照旧是「标签被当纯文本吞掉、插件从不被 dispatch」——
  // 跨表一致性由 test/build176_browser_wiring_lock_test.dart 钉住（①–⑩ 十张表）。
  'web_navigate', // <web_navigate url="https://…" /> 打开页面（过域名闸）
  'web_read', // <web_read /> 序列化当前页（12k 上限 + 视口优先）
  'web_act', // <web_act idx="7" action="click|input|clear" value="…" />
  'web_back', // <web_back /> history back
];

/// 由 [kReActTagNames] 构建的标签检测正则：`<标签名` 后必须紧跟空白 / `>` / `/>`，
/// 避免 <thinking_revised> 等变体误判（保持 M13 fix 的严格匹配语义）。
final RegExp kReActTagPattern = RegExp(
  '<(${kReActTagNames.join('|')})(\\s|>|/>)',
  caseSensitive: false,
);

/// 生成类标签（`<image_gen>` / `<video_gen>`）解析器**留存**的属性白名单。
///
/// build131：此前这段白名单是函数体内的匿名 `const`，且**漏了 `image`** ——
/// 而两个插件的 promptProtocol 都明确要求模型「带多张图时必须显式写
/// `image="文件名"` 或 `image="1"`」。于是 build129 上线的图生图 / 图生视频，
/// 其参考图字段**从上线起就被解析阶段静默丢弃**：
///   - 附了 ≥2 张图却指定 `image="1"` → 属性丢失 → 宿主不知道指哪张 →
///     静默回落「文生图」，用户要改图却拿到一张全新的图；
///   - 指代历史图（"把刚才那张改成油画风"）同理无声失效。
/// 提为公开常量是为了让 `test/build131_gen_ref_test.dart` 能把它和
/// 「协议里写给模型的属性」做**契约对表** —— 今后协议加属性而解析器漏登记，
/// 单测直接红，不再靠真机踩。
const List<String> kGenActionAttrs = [
  'prompt',
  'size',
  'n',
  'quality',
  'seconds',
  'mode',
  // build131：参考图（图生图 / 图生视频）。取值：1 基序号 "1" / 附件文件名 / "last"
  'image',
  // 别名：模型可能直接照抄 API 侧参数名（/v1/images/edits、/v1/videos 同名字段），
  // 解析后归一为 `image`，宿主只认 `image` 一个键。
  'input_reference',
];

/// content 是否含 ReAct 协议标签。
/// 非流式（completeChat）+ 推理模型路径：reasoning_content 非空且 content
/// 含 ReAct 标签时，content 原样保留、不再外包 <answer>，交解析器分段处理。
///
/// G37（build124）：**两种工具语法都算**——XML 标签（[kReActTagPattern]）与
/// ChatML（[kChatMlToolPattern]）。漏掉后者会让「第一关」直接判 false，
/// 整段走非标签分支，工具静默不执行。
/// build156（真机 P1）：再加**第三关**——DSML 方言（全角竖线 `｜` U+FF5C +
/// 命名空间段 `｜｜DSML｜｜`）。同一道理：这里判 false，后面整条链都不会启动。
bool hasReActTag(String content) =>
    kReActTagPattern.hasMatch(content) ||
    kChatMlToolPattern.hasMatch(content) ||
    hasToolDialectTag(content);

// ============================================================================
// O7（build96）：属性引号归一化 + 答案控制标签净化
// ============================================================================

/// 内部控制标签（用户不可见，误入 answer 正文必须剥掉）。
/// 注意：<card> 是 answer 内合法的富交互卡片，<suggest> 由独立通道处理，均不在此列。
/// build115（typed 内核）：**非工具类**标签——文本块与答案内合法件。
/// - thinking / think / answer：内核状态机直接处理，不是工具调用；
/// - card：答案内合法的富交互件，必须**保留在正文**交给渲染层；
/// - suggest：推荐问题，由宿主后处理通道从原始响应提取，保留在正文由
///   AnswerFinalizer.stripTags 统一剥离。
const Set<String> kNonToolTagNames = {
  'thinking',
  'think',
  'answer',
  'card',
  'suggest',
};

/// 工具类标签名集合——**由 [kReActTagNames] 派生，绝不手写**。
///
/// build113 的教训（W1，第 4 次同型复发）：新增内置动作时漏登记某张手写表，
/// 功能就整条链路失效（ws_* 六动作漏了四张表 → 标签通道第一关即断）。
/// 这里改成派生：任何人往 kReActTagNames 加新动作，本集合自动包含它，
/// 不存在「漏登记」的可能。
final Set<String> kToolTagNames = kReActTagNames
    .where((t) => !kNonToolTagNames.contains(t))
    .toSet();

const List<String> kReActControlTagNames = [
  'self_check',
  'todo',
  'memory_write',
  'memory_delete',
  'get_location',
  'ip_locate',
  'query_quota',
  'log_query',
  'install_skill',
  'install_mcp',
  'mcp_call',
  'skill_call',
  'plugin_detail',
  'mcp_detail',
  'skill_detail',
  'search',
  'download',
  // build114：connector_guide 同属内部控制标签（其语义由插件 reasoning 呈现）
  'connector_guide',
  // build122：生成类标签同属内部控制标签（误入 answer 必须剥掉）
  'image_gen',
  'video_gen',
  // build114（W1）：工作区标签同属内部控制标签，误入 answer 必须剥掉
  'ws_list',
  'ws_read',
  'ws_write',
  'ws_delete',
  'ws_download',
  'ws_export',
  // build136：ws_patch / ws_grep 同属内部控制标签，误入 answer 必须剥掉
  'ws_patch',
  'ws_grep',
  // build138：ws_make_file 同属内部控制标签，误入 answer 必须剥掉
  'ws_make_file',
  // G37（build124）：ChatML 归一化产出的不可识别工具标记（用户不可见，
  // 误入 answer 必须剥掉——与 kReActTagNames 同步登记，两张表都要有）
  'unknown_tool_call',
  // build164（#82）：阶段小结。它是**协议顶层元素**、不是正文的一部分——
  // 模型把 <progress> 写进 <answer> 里时，answer 必须只剩给用户看的结论
  // （那句话已经由 reasoningSteps 通道单独呈现，见 kProgressNoteStepKind）。
  'progress',
  // build180（刀二）：浏览器四动作同属内部控制标签，误入 answer 必须剥掉
  // （与 [kReActTagNames] 同步登记，两张表都要有——漏一张就是第 9 次同型复发）。
  'web_navigate',
  'web_read',
  'web_act',
  'web_back',
];

final RegExp _anyTagOpen = RegExp(
  '<(${kReActTagNames.join('|')})\\b[^>]*>',
  caseSensitive: false,
);

/// O7-1：属性引号归一化——只在「<标签 …>」属性段内把中文弯引号 “”‘’→""。
/// 单引号也归一为双引号：解析器全部属性抓取正则只认双引号，
/// 弯单引号若只归一为直单引号仍抓不到属性（O7 实测踩坑）。
/// 不做全局替换，正文里合法的中文引号不受影响。
///
/// build97（P1-2 修复）：只归一「弯引号充当分隔符」的形态 key=“value”，
/// 不动已用直引号包裹的值内出现的弯引号——无差别替换会把
/// `<suggest items="What’s new||x" />` 截成 `What`（值被提前闭合）。
final RegExp _curlyQuotedAttr = RegExp(r'=\s*[“‘]([^“”‘’]*)[”’]');

String normalizeTagQuotes(String s) {
  return s.replaceAllMapped(_anyTagOpen, (m) {
    return m.group(0)!.replaceAllMapped(
      _curlyQuotedAttr,
      (mm) => '="${mm.group(1)}"',
    );
  });
}

final String _ctrl = kReActControlTagNames.join('|');

/// 配对块：<mcp_call ...>...</mcp_call>（含 body，非贪婪、跨行）
final RegExp _ctrlPaired = RegExp(
  '<($_ctrl)\\b[^>]*>.*?</\\1\\s*>',
  caseSensitive: false,
  dotAll: true,
);

/// 自闭合 / 裸开标签：<self_check ... />、<todo ...>（正文另由闭合标签清理）
final RegExp _ctrlOpen = RegExp(
  '<($_ctrl)\\b[^>]*/?>',
  caseSensitive: false,
);

/// 多余闭合标签：</self_check> 等
final RegExp _ctrlClose = RegExp('</($_ctrl)\\s*>', caseSensitive: false);

/// O7-2：答案净化——剥掉 answer 正文里混入的全部内部控制标签及其残片
/// （自闭合、配对、多余闭合三种形态），只留用户可见文字。
/// 纯函数：气泡显示 / DB 落库 / suggest【回答】三处必须共用本函数（O7-3 三处同源）。
///
/// build97（P1-3 修复）：代码围栏感知——按 ``` 切分，围栏内（奇数段）
/// 原样保留。用户问「标签协议长啥样 / 写个 XML 例子」时，示例代码
/// 不会被当控制标签整块删掉（三处同源调用，删了会不可逆落库丢失）。
String stripControlTags(String text) {
  final parts = text.split('```');
  for (var i = 0; i < parts.length; i += 2) {
    parts[i] = _stripControlTagsPlain(parts[i]);
  }
  return parts.join('```').trim();
}

/// 非代码片段的净化（不做 trim——段内空白要保留，整体 trim 由调用方完成）。
String _stripControlTagsPlain(String t) {
  // 先归一弯引号，保证标签形态识别一致
  t = normalizeTagQuotes(t);
  // build156（真机 P1）：再归一 DSML 工具方言——方言残片**必须**在这里消失，
  // 因为 stripControlTags 是「气泡显示 / DB 落库 / suggest【回答】」三处共用的
  // 唯一净化函数（O7-3 三处同源）。归一化产物是扁平控制标签，下面的 _ctrlOpen /
  // _ctrlPaired 直接就能剥掉，不需要在本函数再手写一条方言正则（写第二遍必漏）。
  // 代码围栏由 [stripControlTags] 分段保证，围栏内的示例不受影响。
  t = normalizeToolDialect(t);
  // 配对块先整体删（含 body），再删自闭合/裸开，最后删多余闭合
  var prev = '';
  while (prev != t) {
    prev = t;
    t = t.replaceAll(_ctrlPaired, '');
  }
  t = t.replaceAll(_ctrlOpen, '');
  t = t.replaceAll(_ctrlClose, '');
  // 标签删除后留下的多余空行收敛（>2 连续换行 → 2）
  t = t.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return t;
}

// ============================================================================
// O9（build96）：零产出空转守卫（纯函数，可单测）
// ============================================================================

/// 判定本轮是否「零产出」：既无 answer（无 answer piece 且 [answerStreamLen]==0），
/// 也无「真实执行并带回新信息的主动作」（search/download/mcp_call/skill_call/
/// install_skill/install_mcp）。ask_user 是面向用户的交互件，等待用户输入，
/// 不算空转。thinking/self_check/suggest/todo/memory_* 只产内部状态、不带回
/// 新信息，均不视为产出（O9 实测：连续 5 轮只有 thinking 措辞各异，指纹与
/// 轮末双兜底全部落空，用户只能手动停止）。
bool isZeroOutputRound(
  List<Map<String, String>> pieces, {
  required int answerStreamLen,
}) {
  const productive = {
    // build122：生成类动作会带回新信息（产出文件），不算空转
    'image_gen',
    'video_gen',
    'answer',
    'search',
    'download',
    'mcp_call',
    'skill_call',
    'install_skill',
    'install_mcp',
    'ask_user',
    // build106：定位类动作带回坐标 toolresult，属「真实执行并带回新信息」，
    // 不计入零产出空转（否则定位轮会被 O9 误判为空转并注入约束噪音）
    'get_location',
    'ip_locate',
    // build108（Q1）：余额查询带回 toolresult，同理
    'query_quota',
    // build109：日志查询带回 toolresult，同理
    'log_query',
    // build114（W1）：工作区动作真实执行并带回 toolresult，不算零产出空转
    'ws_list',
    'ws_read',
    'ws_write',
    'ws_delete',
    'ws_download',
    'ws_export',
    // build136：ws_patch / ws_grep 真实执行并带回 toolresult，不算零产出空转
    'ws_patch',
    'ws_grep',
    // build138：ws_make_file 真实执行并带回 toolresult，不算零产出空转
    'ws_make_file',
    // G37（build124）：不可识别工具块会回灌教学 toolresult（模型据此改语法），
    // 属「有反馈的轮」——不得计入 O9 零产出空转（否则 4 轮后被强制收尾，
    // 把 thinking 原文当答案发出）。
    'unknown_tool_call',
    // build180（刀二）：浏览器四个动作每次都带回页面标题/URL/序列化正文，
    // 属「真实执行并带回新信息」，不算空转（漏了会被 O9 误判并注入约束噪音）。
    'web_navigate',
    'web_read',
    'web_act',
    'web_back',
  };
  if (answerStreamLen > 0) return false;
  return !pieces.any((p) => productive.contains(p['type']));
}

/// O9 强约束文案（注入 workingMessages，user 角色，与系统自检同构）。
String buildZeroOutputConstraintMessage(int streak, {required bool isZh}) {
  return isZh
      ? '[系统强约束] 你已连续 $streak 轮只思考未作答。请立即把最终结论写进 '
          '<answer>...</answer>，不要再输出 thinking；若信息不足，基于已有信息给出最佳答案。'
      : '[System constraint] You have only been thinking for $streak consecutive '
          'rounds without answering. Write your final conclusion into '
          '<answer>...</answer> now; do not output more thinking.';
}

// ============================================================================
// G39（build129）：连续「无结论轮」收敛闸门（纯函数 + 常量，可单测）
// ============================================================================

/// G39：连续无结论轮达到该值 → 注入收口指令（仍给模型一次机会自己作答）。
const int kInconclusiveHintStreak = 2;

/// G39：连续无结论轮达到该值 → **强制收敛**（停搜 + 落地结论/可行动报错）。
///
/// build164（#82）：5 → **8**。判据来自真机 1.7.106+163 那份日志
/// （`23:17:02 G39 inconclusive round 1: streak=1 (lastAction=ws_list)` →
/// `23:17:58 streak=2 → wrap-up constraint injected` → 到 5 那一支直接把整条正文
/// 覆盖成模板报错），用户原话：**「五轮是不是有点太短了？」**。
/// 合法的多步任务（深度研究、多轮检索后对比、检索+落盘+核对）会连开 5~7 轮工具，
/// 深研档 maxRounds 本就是 80 —— 5 轮就判死刑等于把有用的研究拦腰砍断。
/// 抬到 8 的前提是 4 那一档先要一句**阶段小结**（[kInconclusiveProgressStreak]），
/// 用户不再"等到结束才看到第一句人话"，就不必靠早收来止损。
/// 可达性（诚实记一笔）：轮次上限由思考强度决定（`ApiService.reasoningRoundsForValue`：
/// 0.7→9 轮、0.9→11 轮、1.0→深研 80 轮），**低强度档本来就跑不到 8 轮** —— 那时
/// 循环由 maxRounds 自然结束、走 `stopNote` 那条兜底，不会甩这段放弃报错；
/// 也就是说空转预算小的场景本就不需要第 8 轮的强制收敛（单测钉住 8 ≤ 0.9 档轮数）。
const int kInconclusiveForceStreak = 8;

/// build164（#82 核心）：连续无结论轮达到该值 → 注入**强制小结轮**（要一句
/// 给人看的进展，然后允许继续查），而不是继续闷头空转。
///
/// 为什么取 4 而不是 3：[kInconclusiveHintStreak]（=2）那一档已经在喊"收口"，
/// 模型若选择继续查，说明它确实还缺信息——那就先让它把"缺什么"说出来（用户看得见
/// 进展），再给到 [kInconclusiveForceStreak] 的预算。三档各管一段，互不重复。
const int kInconclusiveProgressStreak = 4;

/// G39：判定本轮「无结论」——比 [isZeroOutputRound] **更宽**：工具轮同样算。
///
/// 为什么必须另立判据（真机实证 nexus_export_2026-09-19T10-05）：Round 4 起模型
/// 连续检索同一问题（「怎么传 model 参数」），日志却只有
/// `O9 zero-output round 4: streak=1`——O9 的口径是「无 answer **且** 无动作」，
/// 而检索轮带回 toolresult 属「有产出」⇒ streak 每轮从 1 重来、约束永不注入，
/// 一路空转到 maxRounds，最后用户在 10:05:14 手动停止。
/// 结论：**收敛闸门必须按「有没有结论」计数，而不是「有没有动作」。**
///
/// 例外：`ask_user` 轮在等用户输入，是有效交互，不算空转。
///
/// build164（#82）刻意**不**把 `<progress>` 阶段小结算作"有结论"：它是进展播报、
/// 不是答案。若认它清账，模型每轮写一句"还在查"就能把 streak 永远清零、
/// 绕开整条收敛闸门（这正是用户要避免的"空转到 maxRounds"）。
bool isInconclusiveRound(
  List<Map<String, String>> pieces, {
  required bool answered,
  required int answerStreamLen,
}) {
  if (answered) return false;
  if (answerStreamLen > 0) return false;
  if (pieces.any((p) => p['type'] == 'ask_user')) return false;
  // 有 answer 片段即为有结论（工具轮同时给结论也允许落地）
  return !pieces.any((p) => p['type'] == 'answer');
}

/// G39 收口指令（连续 [kInconclusiveHintStreak] 轮无结论时注入）。
///
/// 与 O9 文案的分工：O9 管「只思考不动作」，本函数管「只动作不结论」。
String buildInconclusiveConstraintMessage(
  int streak, {
  required bool isZh,
  String? lastAction,
}) {
  final action = (lastAction ?? '').trim();
  final what = action.isEmpty ? '工具' : '「$action」';
  return isZh
      ? '[系统强约束] 你已连续 $streak 轮调用$what但没有给出任何结论。'
          '现在必须收口：① 如果已有信息足够回答用户，立即把结论写进 <answer>...</answer>；'
          '② 如果确实缺信息，**不要再重复同样的调用**，直接说明缺什么、给出你能给的最佳答案。'
      : '[System constraint] You have called tools${action.isEmpty ? '' : ' ($action)'} '
          'for $streak consecutive rounds without any conclusion. Wrap up now: put the '
          'answer in <answer>...</answer>, or state what is missing instead of repeating '
          'the same call.';
}

/// build164（#82）强制小结指令（连续 [kInconclusiveProgressStreak] 轮无结论时注入）。
///
/// 与 [buildInconclusiveConstraintMessage] 的分工：后者要「现在收口」，本条要
/// 「先说一句人话、然后可以继续查」。用户的原话就是这条的形态：
/// **「这是其他软件的思考过程的小结，这个大概就是我的理想，可以的话就直接做吧」**——
/// 多轮工具中间要有一句给用户看的阶段进展，而不是等到放弃才看到一段模板报错。
String buildInconclusiveProgressMessage(
  int streak, {
  required bool isZh,
  String? lastAction,
}) {
  final action = (lastAction ?? '').trim();
  final what = action.isEmpty ? '工具' : '「$action」';
  return isZh
      ? '[系统要求] 你已连续 $streak 轮调用$what，用户到现在一句人话都没看到。'
          '现在**先**输出一句阶段小结：\n'
          '<progress>……</progress>\n'
          '要求：只有一句话、不超过 $kProgressNoteMaxChars 字、写给用户看，'
          '说清**已经掌握了什么**＋**还缺什么／接下来查什么**。'
          '不要重复 <thinking> 的内容，不要写协议词、工具名、JSON。'
          '写完这一句可以继续沿你需要查的方向查下去，不必现在收口。'
      : '[System requirement] You have called tools${action.isEmpty ? '' : ' ($action)'} '
          'for $streak consecutive rounds and the user has not seen a single human-readable '
          'sentence. Output ONE progress line first:\n'
          '<progress>...</progress>\n'
          'Rules: a single sentence, $kProgressNoteMaxChars characters or fewer, written for '
          'the user, stating what you already know and what is still missing / what you will '
          'check next. Do not repeat your thinking, no protocol words, no tool names, no JSON. '
          'After that line you may keep researching — you do not have to wrap up now.';
}

/// G39 强制收敛文案（连续 [kInconclusiveForceStreak] 轮无结论时落地）。
///
/// 为什么给「明确报错 + 可行动项」而不是现编一段结论：到了这一步**没有任何
/// 可信的答案文本**可用，硬凑一段比诚实报错更糟（用户无从分辨那是不是编的）。
/// 真机场景正是「模型反复追问怎么传 model 参数」——可行动项要落到**具体设置页**。
///
/// build164（#82）：删掉旧文案里「① 中转站返回空流 / 502」这类猜测。用户用的是
/// **官方端点**（api.deepseek.com），那句把责任指向中转站，直接把他带偏过一轮排查
/// （原话：**「我用的是官方的，不是中转站的」**）。而且这些猜测**没有一份真机数据支撑**：
/// 能走到这一支的前提是这几轮请求正常返回并执行了动作——空流/502 在传输层就抛错了。
/// 现在改成按**本轮事实**说话：把这几轮的动作序列与最后一次动作摆出来（[recentActions]
/// 由宿主按轮次累积），缺的就是「把结果写进 <answer> 的那一步」，这话有日志凭据。
String buildInconclusiveGiveUpMessage(
  int streak, {
  required bool isZh,
  String? lastAction,
  List<String> recentActions = const [],
}) {
  final action = (lastAction ?? '').trim();
  final genHint = (action == 'video_gen' || action == 'image_gen');
  // 事实行：只报宿主**真的记到**的动作，一个都没记到时说"没记到"，不编原因
  final acts = recentActions.map((a) => a.trim()).where((a) => a.isNotEmpty).toList();
  final factZh = acts.isEmpty
      ? '这几轮里没有任何一次真实的工具动作被记到（多为只输出思考后就没有下文）。'
      : '这几轮的动作依次是：${acts.join(' → ')}，最后一次是「${action.isEmpty ? acts.last : action}」。'
          '请求都正常返回并执行了，缺的是把结果写进 <answer> 的那一步。';
  final factEn = acts.isEmpty
      ? 'None of those rounds recorded a real tool action (thinking only, then nothing).'
      : 'Actions recorded across those rounds: ${acts.join(' -> ')}, the last one was '
          '"${action.isEmpty ? acts.last : action}". The requests came back and executed fine; '
          'what is missing is the step that writes the result into <answer>.';
  if (isZh) {
    return '已连续 $streak 轮调用工具却始终没有给出结论，为避免无限空转已停止继续调用。\n\n'
        '$factZh\n\n'
        '${genHint ? '本次一直在尝试**生成视频/图片**：请到「设置 → API 配置 → 编辑该配置 → 生成能力」，'
            '勾选对应能力位并填写**视频/生图专用模型**（留空回落对话模型，常因此稳定报错）。\n\n' : ''}'
        '可行动作：点本条消息下方的 ↻ 重试，或把问题拆小一点再问；'
        '若反复出现，请在「设置 → API 配置」更换/新增一个可用配置。';
  }
  return 'Stopped after $streak consecutive tool rounds without a conclusion.\n\n'
      '$factEn\n\n'
      '${genHint ? 'You kept trying to GENERATE media: check Settings → API Config → '
          'Edit this config → capabilities, enable it and set a dedicated video/image model.\n\n' : ''}'
      'Actions: tap ↻ below this message to retry, split the question into smaller ones, '
      'or switch/add an API config in Settings → API Config.';
}

/// build164（#82）：放弃说明的落地口径——**追加**，绝不整条覆盖已有正文。
///
/// 真机事实（1.7.106+163，23:17 那份）：`inconclusiveStreak >= 5` 那一支写的是
/// 「content 整条等于放弃文案」，本轮模型已经产出、用户已经看到的可见内容
/// （半截结论、已答的答复）被一段模板报错**原地抹掉**。
/// 新口径：有可见内容就在其后追加，什么都没有才只落放弃说明
/// （宿主那一行见 chat_screen_react 的 G39 分支；单测把"不许覆盖"钉死）。
String composeGiveUpContent(String existing, String notice) {
  final prev = existing.trim();
  if (prev.isEmpty) return notice;
  return '$prev\n\n$notice';
}

// ============================================================================
// build164（#82）：阶段小结 <progress> —— 面向用户的一句话进展
// ============================================================================
//
// 真机/截图事实（用户提供的另一款 App 截图，作为理想形态）：那条回答在**正文位置**
// 有一句给人看的话「我再深入查一下三款产品的具体责任和44岁的费率。」，下面才接着挂
// 工具步骤行。本仓的现状是：多轮工具中间用户只能看到折叠的 thinking 与工具行，
// 阶段进展要么没有、要么在 streak 攒满后直接变成一段模板报错。
//
// **落地形态刻意不进 assistantMsg.content**：那条通道是复制/朗读/上下文回灌的源，
// 也要过 AnswerFinalizer / O7 的定稿链（`answer_finalizer.dart` 文件头自称"定稿唯一
// 出口、容错只写一遍"）——把阶段小结塞进去等于塞进第二轮加工，还会被读给用户。
// 改为一种新的 reasoning step kind（[kProgressNoteStepKind]）：`reasoningSteps` 本来
// 就随 `ChatMessage.toMap` 整体落库（builtin_plugins 663 行同款做法）⇒ **零 DB 迁移**
// （v39 不许加列）。气泡渲染由另一位同事负责，本文件只保证「解析出来 + 按序成 step」。

/// 协议标签名（顶层元素，与 thinking/answer 平级）。
const String kProgressTagName = 'progress';

/// [kProgressTagName] 落进 `ReasoningStep.kind` 的名字。
/// 与标签名不同是有意的：step kind 是**渲染层**的口径（气泡里那位同事按它分支），
/// 标签名是**协议层**的口径（四张派生表都由它认）。
const String kProgressNoteStepKind = 'progressNote';

/// 写给模型的那句长度约束（宿主**不裁剪**——截断中文句子比超长更难看，
/// 超长只是不符合协议，交给协议文本自身去约束；这里做唯一真相源供协议文案引用）。
const int kProgressNoteMaxChars = 40;

/// 阶段小结正文 → 一条 reasoning step。**唯一构造点**（教训 #62：screen 里不要再
/// new 一个同语义的 ReasoningStep，否则 kind 字符串以后改两处）。
ReasoningStep buildProgressNoteStep(String text,
    {required int round, String phase = ''}) {
  return ReasoningStep(
    kProgressNoteStepKind,
    text.trim(),
    phase: phase,
    round: round,
  );
}

/// 阶段小结的日志行（用户点名要能在日志里数出第几条）：
/// `[ReAct] 阶段小结 #N：<原文>`。抽成纯函数是为了让单测钉住形状——
/// 日志形状散在调用点手写，下次改文案就没人知道（本仓 #62 的老账）。
String formatProgressNoteLog(int seq, String text) =>
    '[ReAct] 阶段小结 #$seq：${text.trim()}';

// ============================================================================
// build164（#82 取证 ③）：被 maxTokens 打满而收口，必须**看得见**
// ============================================================================

/// [applyTruncationNotice] 幂等键：两条语言的文案里都带 `maxTokens=`，
/// 按它认"已经标过了"，避免续写/多轮重复贴同一条警告。
const String kTruncationNoticeMarker = 'maxTokens=';

/// 把「本轮输出被长度上限截断」这件事写进正文尾部（幂等；空正文不标）。
///
/// 为什么要专门做这一个函数（真机 1.7.106+163 + build164 队列里那条
/// 「老是中断」的取证）：maxTokens 打满时模型给的是**半截话**，而旧链只在
/// 「流式兜底①」那一支贴了一句硬编码中文「输出可能被截断，内容不完整」——
/// 英文界面同样贴中文，且经插件 dispatch 正常定稿那一支**完全不贴**，
/// 于是半截话冒充结论落库，用户以为这就是答案（用户读到的就是这种形状）。
String applyTruncationNotice(String content,
    {required int maxTokens, required bool isZh}) {
  final prev = content.trim();
  if (prev.isEmpty) return content;
  if (prev.contains(kTruncationNoticeMarker)) return prev;
  // build167：`0` = 本应用**没发** `max_tokens`（上限交回上游默认，见
  // `api_service.requestMaxTokens`）。这时候编一个数字写进用户看到的正文，
  // 就是"把没发生过的事说成发生过"——打的是"未传(上游默认)"。
  // 两条文案都仍含 `maxTokens=`，所以 [kTruncationNoticeMarker] 的幂等判据不变。
  final label = maxTokens > 0 ? '$maxTokens' : '未传(上游默认)';
  return isZh
      ? '$prev\n\n> 注意：输出被长度上限截断（maxTokens=$label），'
          '这一条不是完整结论；需要更长的回答请调大「设置 → API 配置 → 最大 Token」。'
      : '$prev\n\n> Note: output was truncated by the length limit (maxTokens=$label) — '
          'this is not a complete conclusion; raise "Settings → API Config → Max tokens" '
          'for a longer answer.';
}

/// 本轮是否「答案通道被打满」——[applyTruncationNotice] 的触发判据。
///
/// 刻意**不**用「流末还有未闭合标签」那条更宽的口径：那种形态可能只是思考尾巴
/// 被切开（正文已经正常闭合），给一条完整答案贴"被截断"等于说谎。
/// 只有 `<answer>` 开到流末都没闭合，才说得上"结论被长度上限拦腰截断"。
bool isAnswerTruncated({required bool inAnswerBlock, required String rawResp}) =>
    inAnswerBlock && !rawResp.toLowerCase().contains('</answer>');


// ============================================================================
// G37（build124）：ChatML 工具调用语法归一化
// ============================================================================

/// ChatML 工具块是否在场（第一关检测用）。
///
/// 与 [kReActTagPattern]（XML 语法）并列：两种语法都必须能进入解析链，
/// 否则 `hasReActTag` 为 false → 整段走「非标签」分支 → 工具不执行。
final RegExp kChatMlToolPattern = RegExp(
  r'<\s*\|\s*/?\s*(tool_calls|invoke|parameter)\b',
  caseSensitive: false,
);

bool hasChatMlToolCall(String content) => kChatMlToolPattern.hasMatch(content);

/// `<|invoke name="x">`（容忍 `<| invoke name="x" |>` 之类空白变体）
final RegExp _chatmlInvokeOpen = RegExp(
  r'<\|?\s*invoke\s+name\s*=\s*"([^"]*)"\s*\|?>',
  caseSensitive: false,
);

/// invoke 闭合：`<|/invoke|>` / `</|invoke|>` / `</invoke>` 三种写法
final RegExp _chatmlInvokeClose = RegExp(
  r'(?:<\|?/\s*invoke\s*\|?>|</\|?\s*invoke\s*\|?>)',
  caseSensitive: false,
);

/// `<|parameter name="k">v</|parameter>`（值跨行；闭合写法同 invoke 三种）
final RegExp _chatmlParam = RegExp(
  r'<\|?\s*parameter\s+name\s*=\s*"([^"]*)"\s*\|?>([\s\S]*?)'
  r'(?:<\|?/\s*parameter\s*\|?>|</\|?\s*parameter\s*\|?>)',
  caseSensitive: false,
);

/// `<|tool_calls|>` / `<|/tool_calls|>` 包装层（只作壳，直接剥掉）
final RegExp _chatmlWrap = RegExp(
  r'<\|?\s*/?\s*tool_calls\s*\|?>',
  caseSensitive: false,
);

/// 属性值转义：属性抓取正则只认 `k="v"`，值内的 `"` / 换行必须编码，
/// 否则会把属性提前闭合（O7 同款坑）。
///
/// build156（真机 P1）：**已是实体的 `&` 不再二次转义**。方言归一化会把模型
/// 原样写的 `&quot;` / `&lt;` 整段搬进新标签的属性值，若把它们的 `&` 再转成
/// `&amp;`，下游 `_wsAttrValue`（先解 `&quot;` 后解 `&amp;`）会解出
/// `&amp;"` 这类脏字符——content 里带真 HTML 的表格载荷首当其冲。
String _xmlAttrEscape(String v) => v
    .replaceAllMapped(
        RegExp(r'&(?![a-zA-Z]+;|#[0-9]{1,7};|#[xX][0-9a-fA-F]{1,6};)'),
        (m) => '&amp;')
    .replaceAll('"', '&quot;')
    .replaceAll('\n', '&#10;')
    .replaceAll('\r', '')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

/// [_xmlAttrEscape] 的逆：工作区标签属性值的还原口径（build138）。
///
/// 只做「文本载荷」需要的四个实体 + 数字引用（`&#10;` 是换行——表格载荷
/// content="姓名,成绩&#10;张三,90" 在真机上是模型的主流写法，不还原就等于
/// 把换行丢了，生成的 xlsx 只有一行）。`&amp;` 放最后解，避免
/// `&amp;lt;` 被二次解成 `<`。
String _wsAttrValue(String raw) {
  var t = raw.trim();
  if (!t.contains('&')) return t;
  t = t
      .replaceAll('&quot;', '"')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]{1,6});'),
          (m) => _runeOf(int.parse(m.group(1)!, radix: 16)))
      .replaceAllMapped(
          RegExp(r'&#([0-9]{1,7});'), (m) => _runeOf(int.parse(m.group(1)!)))
      .replaceAll('&amp;', '&');
  return t;
}

String _runeOf(int cp) {
  if (cp <= 0 || cp > 0x10FFFF) return '';
  try {
    return String.fromCharCode(cp);
  } catch (_) {
    return '';
  }
}

dynamic _chatmlTryJson(String v) {
  final t = v.trim();
  if (t.isEmpty) return null;
  if (!t.startsWith('{') && !t.startsWith('[')) return null;
  try {
    return jsonDecode(t);
  } catch (_) {
    return null;
  }
}

/// 单个 invoke 块 → 等价 XML 标签。
///
/// - `mcp_call` / `skill_call`：JSON 入参参数（`arguments`/`json`/任意合法 JSON
///   值）作**标签正文**（这两个标签的既有约定就是正文 JSON，插件按 jsonDecode
///   读）；其余参数作属性。无 JSON 入参时补 `{}` 正文——**不能**输出自闭合：
///   mcp_call 分支要求 `decoded is Map`，自闭合会让整段响应退化成 thinking。
/// - `answer` / `thinking` / `think`：参数值作正文。
/// - 其余已知标签：参数一律作属性、输出自闭合（`<search query="x" />` 等
///   自闭合分支的正则要求 `/>`，配对写法反而抓不到）。
/// - **不可识别的 invoke 名**：输出 `<unknown_tool_call name="..." />` 显式标记
///   （由宿主回灌教学 toolresult），绝不静默降级为普通文本。
String _chatmlInvokeToXml(String name, String inner) {
  final lower = name.toLowerCase();
  final isJsonBodyTag = lower == 'mcp_call' || lower == 'skill_call';
  final isTextTag = lower == 'answer' ||
      lower == 'thinking' ||
      lower == 'think' ||
      // build164（#82）：阶段小结同样是**正文型**标签（内容是给人看的一句话），
      // 与 answer/thinking 同构。少了这一条，ChatML/DSML 通道产出的
      // `<|parameter name="content">那句话</…>` 会被当属性塞进自闭合标签，
      // 而那句话正是本标签唯一的有效负载——等于在归一化阶段就丢掉。
      lower == kProgressTagName;
  final known = kReActTagNames.contains(lower) || isTextTag;
  final attrs = <String, String>{};
  final body = StringBuffer();

  for (final pm in _chatmlParam.allMatches(inner)) {
    final k = (pm.group(1) ?? '').trim();
    final v = (pm.group(2) ?? '').trim();
    if (k.isEmpty) continue;
    if (isJsonBodyTag) {
      if (body.isEmpty && _chatmlTryJson(v) != null) {
        body.write(v);
        continue;
      }
      attrs[k] = v;
      continue;
    }
    if (isTextTag) {
      if (body.isNotEmpty) body.write('\n');
      body.write(v);
      continue;
    }
    attrs[k] = v;
  }

  if (!known) {
    final extra = attrs.entries
        .map((e) => ' ${e.key}="${_xmlAttrEscape(e.value)}"')
        .join();
    return '<unknown_tool_call name="${_xmlAttrEscape(name)}"$extra />';
  }

  final attrText =
      attrs.entries.map((e) => ' ${e.key}="${_xmlAttrEscape(e.value)}"').join();
  if (isJsonBodyTag) {
    final b = body.isEmpty ? '{}' : body.toString();
    return '<$lower$attrText>$b</$lower>';
  }
  if (isTextTag) {
    final b = body.toString();
    if (b.isEmpty) return '<$lower />';
    // 正文原样透传（不转义：解析器取回的正文直接进气泡/落库，转义会露 &lt;）
    return '<$lower>$b</$lower>';
  }
  return '<$lower$attrText />';
}

/// ChatML → XML 归一化（纯函数，幂等：无 ChatML 时原样返回）。
///
/// 真机病灶（nexus 中转 + 弱模型，export 2026-09-17T15-26）：模型不发
/// `<mcp_call plugin_id=".." tool="..">{".."}</mcp_call>`，而是发
/// ```
/// <|tool_calls|>
/// <|invoke name="mcp_call">
/// <|parameter name="plugin_id">amap</|parameter>
/// <|parameter name="tool">maps_around_search</|parameter>
/// <|parameter name="arguments">{"keywords":"地铁站"}</|parameter>
/// </|invoke>
/// </|tool_calls|>
/// ```
/// 旧实现只认 XML → 整段被当普通文本：工具不执行、模型以为已调用、
/// 用户看到一坨 JSON（本轮 G33 泄漏的同源另一半）。归一化后，
/// 下游解析 / 分发 / 插件**零改动**复用既有链路。
String normalizeChatMLToolCalls(String raw) {
  if (!hasChatMlToolCall(raw)) return raw;
  final sb = StringBuffer();
  var cursor = 0;
  while (true) {
    final m = _chatmlInvokeOpen.firstMatch(raw.substring(cursor));
    if (m == null) break;
    final absStart = cursor + m.start;
    final name = (m.group(1) ?? '').trim();
    final bodyStart = cursor + m.end;
    final close = _chatmlInvokeClose.firstMatch(raw.substring(bodyStart));
    final innerEnd = close == null ? raw.length : bodyStart + close.start;
    sb.write(raw.substring(cursor, absStart).replaceAll(_chatmlWrap, ''));
    if (name.isNotEmpty) {
      sb.write(_chatmlInvokeToXml(name, raw.substring(bodyStart, innerEnd)));
    }
    cursor = close == null ? raw.length : bodyStart + close.end;
  }
  sb.write(raw.substring(cursor).replaceAll(_chatmlWrap, ''));
  return sb.toString();
}

// ============================================================================
// build156（真机 P1）：DSML「全角竖线 + 命名空间段」工具方言归一化
// ============================================================================
//
// **接在哪一层、为什么是这一层**：模型文本进入宿主的唯一解析入口是
// [parseReActOutput]，它开头就挂着 G37（build124）为 ChatML 建的同一条归一化链
// （`normalizeChatMLToolCalls`）。本方言接在同一条链、同一个函数
// （[normalizeToolDialect]），产物是既有的扁平 XML 控制标签 ⇒ 下游
// 分发（chat_screen_react 的 trigger 循环）、插件（builtin_plugins 的
// triggerType='ws_write' 等）、定稿（AnswerFinalizer）**零改动**复用。
// 若接在插件分发处或答案出口，就要在 4 个定稿出口各写一遍——本仓为
// 「同一个容错写 N 遍必漏一处」已经吃过 O7-3 / B-030 / G37 三次亏。
//
// **真机原文**（用户从 App 气泡里复制，竖线是**全角 ｜ U+FF5C**、成对出现）：
//   <｜｜DSML｜｜ calls>
//   <｜｜DSML｜｜ invoke name="todo" action="done" items="获取坐标||解析终点||规划路线" />
//   <｜｜DSML｜｜ invoke name="ws_make_file" path="exports/路线.xlsx"
//        content="方案,距离\n方案A,1281 米…" overwrite="true" />
//   </｜｜DSML｜｜ calls>
// 旧链三处全断：① G37 的 ChatML 正则只认半角 `|`；② AnswerFinalizer 兜底
// 复用同一条半角正则；③ 通用剥标签 `<[^>]+/>` 在 content 里真 HTML 的**第一个
// `>`** 处截半 → 剥不干净。结果：文件没写、整坨 XML 当正文显示。
//
// **两条硬口径**：
//   - 属性段按**引号配对**吃（`k="值"`，值内允许 `<` / `>` / 换行 / `&quot;`），
//     绝不用「第一个 `>` 结束」的朴素匹配；
//   - 认不出的 name 走 `_chatmlInvokeToXml` 的既有出口产出
//     `<unknown_tool_call name="…" />`（G37 已接线：轮次回灌教学 toolresult +
//     思考面板「未知工具调用」），**绝不静默吞掉**——静默等于让用户以为文件写好了。

/// 方言命名空间头的源码（如 `｜｜DSML｜｜` / `||DSML||` / 单根全角 `｜`）。
/// 半角单竖线**刻意不算方言**：那是 G37 ChatML 的既有口径
/// （`<|invoke name="…">`），两条链各管各的形态，互不打架。
///
/// build157（第 15 轮扫描 P1）：**尾部那一串不许再写成 `(?:[|｜]+[ \t]*)*`**。
/// 那是教科书级的 `(a+)+` 形状：irregexp 在"匹配到最后一步却整体失败"时会按
/// 竖线 run 的切分方式指数展开。实测 `<` + 26 根竖线 + ` z`（没有 `>`）
/// 单次要 2.5 秒，而这段是在 `normalizeToolDialect` 里**每个 SSE 分片都跑一遍**
/// （`react_stream_scrubber` 那条流式路径），模型只要吐出 20 多根连续竖线
/// （DSML 打错的形态、或 ASCII 表格）就把 UI isolate 钉死。
/// 现在收成 `[|｜]*`（一个 run）：接受的语言只差"竖线之间夹空白"这种畸形写法，
/// 代价是把指数换成常数。
const String _dialectHeadSrc =
    r'(?:[|｜]{2,}|｜)[ \t]*(?:[A-Za-z][A-Za-z0-9_]*)?[ \t]*[|｜]*';

/// 方言属性段源码：`key="value"`，值内允许 `<` / `>` / 换行（引号配对）。
const String _dialectAttrsSrc =
    r'((?:[ \t]+[A-Za-z_][A-Za-z0-9_.-]*[ \t]*=[ \t]*"[^"]*")*)';

/// 完整方言标签：`<｜｜DSML｜｜ invoke name="x" a="1" />` / `<｜｜DSML｜｜ calls>` /
/// `</｜｜DSML｜｜ calls>`。捕获组：1=`/`（闭合）2=本地名 3=属性段 4=`/`（自闭合）。
final RegExp kDialectTag = RegExp(
  '<[ \t]*(/?)[ \t]*(?:$_dialectHeadSrc)[ \t]*'
  '([A-Za-z_][A-Za-z0-9_]*)$_dialectAttrsSrc[ \t]*(/)?[ \t]*>',
  caseSensitive: false,
);

/// 只有命名空间头、没有本地名的壳标签（`<｜｜DSML｜｜>` / `</｜｜DSML｜｜>`）。
final RegExp kDialectBareTag = RegExp(
  '<[ \t]*(/?)[ \t]*(?:$_dialectHeadSrc)[ \t]*(/)?[ \t]*>',
  caseSensitive: false,
);

/// 方言 invoke / 工具的**闭合**标签：`</｜｜DSML｜｜ invoke>`、`</invoke>`、`</|invoke|>`。
final RegExp kDialectInvokeClose = RegExp(
  '<[ \t]*/[ \t]*(?:$_dialectHeadSrc)?[ \t]*'
  r'(invoke|function)[ \t]*(?:[|｜]+)?[ \t]*>',
  caseSensitive: false,
);

/// 方言参数：`<｜｜DSML｜｜ parameter name="k">值</｜｜DSML｜｜ parameter>`（值跨行）。
/// 捕获组：1=属性段 2=值。
final RegExp kDialectParam = RegExp(
  '<[ \t]*(?:$_dialectHeadSrc)[ \t]*parameter$_dialectAttrsSrc[ \t]*>[ \t]*'
  r'([\s\S]*?)'
  '<[ \t]*/[ \t]*(?:$_dialectHeadSrc)?[ \t]*parameter[ \t]*(?:[|｜]+)?[ \t]*>',
  caseSensitive: false,
);

/// 单个属性 `key="value"`（值内可含 `<` / `>` / 换行）。
final RegExp kDialectAttr = RegExp(
  r'([A-Za-z_][A-Za-z0-9_.-]*)[ \t]*=[ \t]*"([^"]*)"',
  caseSensitive: false,
);

/// 方言标签**起始**（不要求完整）——跨 SSE 分片时半截 `<｜｜DSML｜｜ inv` 也要能认出。
/// 竖线之后必须紧跟字母或 `>`：`<｜满分` 这类正文里的「小于号 + 全角竖线」不算方言，
/// 否则流式暂存会被普通文本骗到（扣住一段正文等永远不会来的「闭合」）。
final RegExp kDialectTagStart = RegExp(
  r'<[ \t]*/?[ \t]*(?:[|｜]{2,}|｜)[ \t]*(?:[A-Za-z_]|>)',
  caseSensitive: false,
);

/// 命名空间头**残片**（没有 `<` 的 `｜｜DSML｜｜`）。只认全角竖线：半角 `||` 是
/// 本仓 items / suggest 的合法分隔符（`items="A||B"`），认它会误杀正常答案。
final RegExp kDialectNsResidue = RegExp(
  r'｜{2}[ \t]*[A-Za-z]{2,}[ \t]*｜{2}',
  caseSensitive: false,
);

/// 文本里是否存在 DSML 方言（含跨分片残片）。供 hasReActTag / 兜底判定 / 流式剥离共用。
bool hasToolDialectTag(String s) =>
    kDialectTagStart.hasMatch(s) || kDialectNsResidue.hasMatch(s);

Map<String, String> _dialectAttrs(String attrText) {
  final out = <String, String>{};
  for (final m in kDialectAttr.allMatches(attrText)) {
    final k = (m.group(1) ?? '').trim();
    if (k.isEmpty) continue;
    out[k] = m.group(2) ?? '';
  }
  return out;
}

/// 参数表 → G37 既有口径的 `<|parameter name="k">v</|parameter>` 正文。
///
/// 这么绕一手是为了**不重写已知/未知判定**：[_chatmlInvokeToXml] 已经是
/// 「已知标签 → 属性/正文、mcp_call/skill_call → JSON 正文、未知 name →
/// `<unknown_tool_call>`」的唯一一份实现（并统一做 _xmlAttrEscape）。
/// 方言只负责把「形态」翻过来，语义判定全仓仍只此一处。
String _dialectParamInner(Map<String, String> params) {
  final sb = StringBuffer();
  params.forEach((k, v) {
    sb.write('<|parameter name="$k">$v</|parameter>');
  });
  return sb.toString();
}

/// DSML 方言 → 既有扁平 XML 控制标签（纯函数，幂等：无方言时原样返回）。
///
/// 规则：
/// - `<｜｜NS｜｜ invoke name="X" a="1" b="2" />` → `<X a="1" b="2" />`
///   （X 不在 [kReActTagNames] 里 → `<unknown_tool_call name="X" … />`，不静默）；
/// - `<｜｜NS｜｜ invoke name="X">` + `<｜｜NS｜｜ parameter name="k">v</…>` 子件
///   → 同样翻成参数表（与 ChatML 同构）；
/// - `<｜｜NS｜｜ X …>`（X 直接是已注册 trigger 名，无 invoke 壳）→ `<X … />`；
/// - 容器壳（calls / tool_calls / parameters / thinking / answer …）→ **只剥标签**，
///   正文照旧留给下游（`answer`/`thinking` 的配对正文因此不会被吞）。
String normalizeToolDialect(String raw) {
  if (!hasToolDialectTag(raw)) return raw;
  // 1) 无本地名的壳先整体删（否则它会挡住后面的配对扫描）
  final text = raw.replaceAll(kDialectBareTag, '');
  final sb = StringBuffer();
  var i = 0;
  while (i < text.length) {
    final lt = text.indexOf('<', i);
    if (lt < 0) {
      sb.write(text.substring(i));
      break;
    }
    sb.write(text.substring(i, lt));
    final m = kDialectTag.matchAsPrefix(text, lt);
    if (m == null) {
      // 不是方言标签（普通 `<`、Markdown 表格里的 `<`）——原样写回，逐字符前进
      sb.write('<');
      i = lt + 1;
      continue;
    }
    final isClose = m.group(1) == '/';
    final local = (m.group(2) ?? '').toLowerCase();
    final attrText = m.group(3) ?? '';
    final selfClosed = m.group(4) == '/';
    final afterTag = m.end;
    if (isClose) {
      // 游离闭合标签（配对形态的闭合已由下面消费）
      i = afterTag;
      continue;
    }
    final isInvoke = local == 'invoke' || local == 'function';
    final knownTool = kToolTagNames.contains(local);
    if (!isInvoke && !knownTool) {
      // 容器 / 非工具壳：删标签本身，正文与子标签继续走循环
      i = afterTag;
      continue;
    }
    final params = <String, String>{};
    final own = _dialectAttrs(attrText);
    var toolName = isInvoke ? (own['name'] ?? '').trim() : local;
    for (final e in own.entries) {
      if (isInvoke && e.key.toLowerCase() == 'name') continue;
      params[e.key] = e.value;
    }
    var end = afterTag;
    if (!selfClosed) {
      final close = kDialectInvokeClose.firstMatch(text.substring(afterTag));
      final bodyEnd = close == null ? text.length : afterTag + close.start;
      final body = text.substring(afterTag, bodyEnd);
      var hasParam = false;
      for (final pm in kDialectParam.allMatches(body)) {
        final pname = (_dialectAttrs(pm.group(1) ?? '')['name'] ?? '').trim();
        if (pname.isEmpty) continue;
        hasParam = true;
        params[pname] = pm.group(2) ?? '';
      }
      if (!hasParam && body.trim().isNotEmpty) {
        // 无参数子件而有正文：`<｜｜NS｜｜ mcp_call …>{...}</…>` —— 正文按
        // mcp_call/skill_call 的既有约定当 JSON 入参（_chatmlInvokeToXml 里判）
        params['arguments'] = body.trim();
      }
      end = close == null ? text.length : afterTag + close.end;
    }
    if (toolName.isEmpty) toolName = '(unnamed)';
    sb.write(_chatmlInvokeToXml(toolName, _dialectParamInner(params)));
    i = end;
  }
  // 2) 归一化后仍残留的命名空间头（模型自己写坏的壳、没有 `<` 的散残片）也要清掉，
  //    绝不让 `｜｜DSML｜｜` 出现在用户正文里（全角双竖线 + 字母段不可能是散文）。
  //    **但**产物里若还有「未闭合的方言标签起始」就不能清——半截标签要原样留给
  //    下一片（ReactStreamScrubber 的跨分片暂存靠这对竖线认它是方言，吃掉后
  //    `< invoke …` 再也认不出来，未闭合标签会带着属性直接流进气泡）。
  final out = sb.toString();
  if (kDialectTagStart.hasMatch(out)) return out;
  return out.replaceAll(kDialectNsResidue, '');
}

/// G32/G34（build124）：**轮次终态判定**用的动作集合——「执行后必有 toolresult
/// 回灌、模型还需再给一轮答案」的动作。
///
/// 用途：判断本轮是「工具轮」（答案在工具回灌之后）还是「终态轮」。真机病灶：
/// 弱模型把过渡语写进 `<answer>`、同轮再发 `mcp_call` → 过渡语被当结论定稿。
///
/// 刻意**不含**被动件：`todo` / `memory_write` / `memory_delete` / `suggest` /
/// `card` / `ask_user`。模型常写 `<answer>结论</answer><todo .../>`，若把 todo
/// 算作动作，轮级判定会把这条**真结论**误降级并回滚（内容丢失、需模型重答）。
/// 也不含 `self_check`（自评件，非执行动作；动作后出现时旧链本就丢弃）。
const Set<String> kRoundActionTypes = {
  'search',
  'download',
  'mcp_call',
  'skill_call',
  'install_skill',
  'install_mcp',
  'connector_guide',
  'plugin_detail',
  'mcp_detail',
  'skill_detail',
  'get_location',
  'ip_locate',
  'query_quota',
  'log_query',
  'image_gen',
  'video_gen',
  'ws_list',
  'ws_read',
  'ws_write',
  'ws_delete',
  'ws_download',
  'ws_export',
  // build136：ws_patch / ws_grep 同样会回灌 toolresult，模型必须再给一轮答案
  'ws_patch',
  'ws_grep',
  // build138：ws_make_file 会回灌 toolresult，模型必须再给一轮答案
  'ws_make_file',
  // G37：不可识别工具块同样会回灌教学 toolresult，模型必须再给一轮答案
  'unknown_tool_call',
  // build180（刀二）：浏览器四动作都回灌 toolresult（页面序列化正文/动作结果），
  // 模型必须再给一轮答案。漏登记的病灶正是 build124 真机那一类：
  // `<answer>过渡语</answer><web_navigate/>` 会把过渡语当结论定稿。
  'web_navigate',
  'web_read',
  'web_act',
  'web_back',
  // build164（#82）**刻意不含** `progress`：阶段小结不回灌 toolresult、也不改变
  // 轮次终态。若把它算作动作，`<answer>结论</answer><progress>…</progress>` 这种
  // 正常写法就会触发 judgeRoundTerminal 的"动作之前的 answer 是过渡语"规则，
  // 把**真结论**降级成 thinking（该函数注释里写过的同类事故）。
};

/// G32/G34（build124）：轮次终态判定结果（见 [judgeRoundTerminal]）。
class RoundTerminalVerdict {
  /// 降级后的片段列表（过渡语 answer → thinking）
  final List<Map<String, String>> pieces;

  /// 被降级的片段数
  final int downgradedCount;

  /// 被降级的字符数（诊断用）
  final int downgradedChars;

  /// 最后一个执行类动作的下标（-1 = 本轮无动作）
  final int lastActionIndex;

  /// 工具轮：本轮有执行类动作，且动作之后没有任何 answer
  /// → 本轮**没有终态答案**，宿主必须禁止一切 finalize（答案在下一轮）。
  final bool isToolRound;

  const RoundTerminalVerdict({
    required this.pieces,
    required this.downgradedCount,
    required this.downgradedChars,
    required this.lastActionIndex,
    required this.isToolRound,
  });
}

/// G32/G34（build124）：轮次终态判定（纯函数，可单测）。
///
/// 判据必须是**轮级的**——单看片段类型永远判不出「后面还有动作」。真机病灶
/// （nexus_export_2026-09-17T15-26）：弱模型把过渡语「我帮你查一下附近的…」
/// 写进 `<answer>`、**同轮**再发 `mcp_call` → 旧实现按片段顺序 dispatch，
/// answer 件先落地定稿（306 字符）→ 工具轮当场结束 → N14 suggest 拿这段
/// 过渡语当【回答】补出 3 条无关追问。
///
/// 规则：
/// - 本轮存在执行类动作（[kRoundActionTypes]）→ 动作**之前**的 answer 全是
///   过渡语 → 降级 thinking；
/// - 降级后动作之后仍无 answer → [RoundTerminalVerdict.isToolRound] 为 true；
/// - 动作之后的 answer（`<mcp_call/><answer>结论</answer>`）原样保留 → 终态轮。
RoundTerminalVerdict judgeRoundTerminal(List<Map<String, String>> pieces) {
  final lastActionIdx = pieces.lastIndexWhere(
      (p) => kRoundActionTypes.contains(p['type']));
  if (lastActionIdx < 0) {
    return RoundTerminalVerdict(
      pieces: pieces,
      downgradedCount: 0,
      downgradedChars: 0,
      lastActionIndex: -1,
      isToolRound: false,
    );
  }
  final out = <Map<String, String>>[];
  var count = 0;
  var chars = 0;
  for (var i = 0; i < pieces.length; i++) {
    final p = Map<String, String>.from(pieces[i]);
    if (i < lastActionIdx && p['type'] == 'answer') {
      count++;
      chars += (p['content'] ?? '').length;
      p['type'] = 'thinking';
    }
    out.add(p);
  }
  final hasTerminalAnswer = out.any((p) => p['type'] == 'answer');
  return RoundTerminalVerdict(
    pieces: out,
    downgradedCount: count,
    downgradedChars: chars,
    lastActionIndex: lastActionIdx,
    isToolRound: !hasTerminalAnswer,
  );
}

/// ReAct 协议输出解析器（v1.4.2 从 chat_screen 抽出为独立纯函数）
///
/// 解析 AI 在「自主联网思考循环 (ReAct)」模式下的协议输出，按出现顺序拆成
/// 若干片段，每个片段带 `type` 标记：
///   - thinking  : 思考过程（<thinking>...</thinking> 或标签外的自由文本）
///   - search    : <search query="..." depth="basic|advanced" />
///   - download  : <download intent=... canonical=... url=... type=... query=... />
///   - self_check: <self_check continue="true|false" reason="..." />
///   - answer    : <answer>...</answer>
///   - ask_user  : <ask_user>...</ask_user>
///   - mcp_call  : <mcp_call plugin_id="..." tool="...">{...}</mcp_call>
///   - skill_call: <skill_call name="skill.xxx">{optional JSON}</skill_call>  (v1.7.12 新增)
///   - plugin_detail: <plugin_detail name="..." />  (v1.7.17 新增，只读加载插件详情)
///   - mcp_detail  : <mcp_detail plugin_id="..." tool="..." />  (v1.7.17 新增)
///   - skill_detail: <skill_detail name="..." />  (v1.7.17 新增)
///   - suggest   : <suggest>问题1||问题2||问题3</suggest>  (v1.7.39 新增，推荐后续问题)
///   - progress  : <progress>一句话阶段小结</progress>  (build164 #82 新增，面向用户的
///                 阶段进展；**只**成 reasoning step（kind=[kProgressNoteStepKind]），
///                 不进 answer 正文)
///   - todo      : <todo action="add|done|list|clear" items="事项1||事项2" />  (v1.7.39 新增)
///   - memory_write: <memory_write scope="global|project" key="..." value="..." />  (v1.7.39 新增)
///   - memory_delete: <memory_delete scope="global|project" key="..." />  (N8 build94 新增)
///   - get_location: <get_location />  (build106 新增，设备 GPS 精确定位，无属性)
///   - ip_locate: <ip_locate />  (build104 U3 新增，IP 城市级定位，无属性；build106 补解析接线)
///   - web_navigate: <web_navigate url="https://…" />  (build180 刀二，内置浏览器开页)
///   - web_read  : <web_read />  (build180 刀二，序列化当前页，无属性)
///   - web_act   : <web_act idx="7" action="click|input|clear" value="…" />  (build180 刀二)
///   - web_back  : <web_back />  (build180 刀二，history back)
///
/// N9（build94）：memory_write / memory_delete / todo 兼容「配对写法」——
/// 自闭合 `<tag ... />` 之外，也接受成对 `<tag ...></tag>` 与裸开标签 `<tag ...>`
/// （属性协议不变，正文忽略并消费紧邻的闭合标签）；suggest 反向兼容自闭合
/// `<suggest items="问题1||问题2" />`（标准写法为配对 `<suggest>...</suggest>`）。
///
/// 纯函数、无副作用，可被聊天页和自检服务复用同一套真实逻辑。
List<Map<String, String>> parseReActOutput(String raw) {
  // build156（真机 P1）：先把 DSML 工具方言（全角竖线 + 命名空间段）翻成
  // 既有扁平控制标签——接在 G37 同一条归一化链上，理由见 [normalizeToolDialect]
  // 头注（唯一入口，绝不在分发/定稿出口各写一遍）。幂等：无方言时原样返回。
  final dialect = normalizeToolDialect(raw);
  // G37（build124）：再把 ChatML 工具语法归一化为等价 XML——两种语法共用
  // 下游全部解析/分发逻辑（中转站把模型输出转成 ChatML 时旧实现整段丢失）。
  // 幂等：无 ChatML 时原样返回，零开销（一次正则 contains 判断）。
  final chatml = normalizeChatMLToolCalls(dialect);
  // O7-1（build96）：先把标签属性段内的中文弯引号归一为英文直引号，
  // 否则 `continue=“false”` 这类写法抓不到属性（归一在标签段内做，正文不受影响；
  // 弯引号与直引号同为单 code unit，长度不变，后续索引安全）。
  final s = normalizeTagQuotes(chatml);
  final out = <Map<String, String>>[];
  final buf = StringBuffer();
  int i = 0;
  while (i < s.length) {
    // <search query="x" depth="basic|advanced" /> 自闭合（v1.3.4：depth 可选）
    final searchMatch = RegExp(
      r'<search\s+([^>]*?)\s*/>',
      caseSensitive: false,
    ).matchAsPrefix(s, i);
    if (searchMatch != null) {
      final attrs = searchMatch.group(1)!;
      final qMatch = RegExp(r'query="([^"]+)"').firstMatch(attrs);
      if (qMatch != null) {
        if (buf.isNotEmpty) {
          final t = buf.toString().trim();
          if (t.isNotEmpty) out.add({'type': 'thinking', 'content': t});
          buf.clear();
        }
        final piece = <String, String>{
          'type': 'search',
          'content': qMatch.group(1)!.trim(),
        };
        final dMatch = RegExp(r'depth="(basic|advanced)"').firstMatch(attrs);
        if (dMatch != null) piece['depth'] = dMatch.group(1)!;
        out.add(piece);
        i = searchMatch.end;
        continue;
      }
      // v1.7.16 修复：畸形 <search>（命中标签但缺 query）原来会落到逐字符消费，
      // 把 `<` 写回导致标签被吞成乱码；这里显式跳过整个标签。
      i = searchMatch.end;
      continue;
    }

    // <download ... /> 自闭合（v1.4.2：新增 url / type / query 属性）
    final dlMatch = RegExp(
      r'<download\s+([^>]*?)\s*/>',
      caseSensitive: false,
    ).matchAsPrefix(s, i);
    if (dlMatch != null) {
      if (buf.isNotEmpty) {
        final t = buf.toString().trim();
        if (t.isNotEmpty) out.add({'type': 'thinking', 'content': t});
        buf.clear();
      }
      final attrs = dlMatch.group(1) ?? '';
      String grab(String k) {
        final m =
            RegExp('$k="([^"]*)"', caseSensitive: false).firstMatch(attrs);
        return (m?.group(1) ?? '').trim();
      }

      out.add({
        'type': 'download',
        'content': grab('canonical'),
        'keywords': grab('keywords'),
        'domains': grab('domains'),
        'intent': grab('intent'),
        'platform': grab('platform'),
        'url': grab('url'),
        'type_attr': grab('type'),
        'query': grab('query'),
      });
      i = dlMatch.end;
      continue;
    }

    // <self_check continue="true|false" reason="..." /> 自闭合（v1.3.4）
    final scMatch = RegExp(
      r'<self_check\s+([^>]*?)\s*/>',
      caseSensitive: false,
    ).matchAsPrefix(s, i);
    if (scMatch != null) {
      final attrs = scMatch.group(1) ?? '';
      String grab(String k) {
        final m =
            RegExp('$k="([^"]*)"', caseSensitive: false).firstMatch(attrs);
        return (m?.group(1) ?? '').trim();
      }

      if (buf.isNotEmpty) {
        final t = buf.toString().trim();
        if (t.isNotEmpty) out.add({'type': 'thinking', 'content': t});
        buf.clear();
      }
      out.add({
        'type': 'self_check',
        'content': grab('reason'),
        'continue': grab('continue'),
      });
      i = scMatch.end;
      continue;
    }

    // <todo action="add|done|list|clear" items="事项1||事项2" /> 自闭合（v1.7.39 build92）
    // N9：兼容配对写法 <todo ...></todo> 与裸开标签 <todo ...>（正文忽略）
    final tdMatch = RegExp(
      r'<todo\s+([^>]*?)\s*/?>',
      caseSensitive: false,
    ).matchAsPrefix(s, i);
    if (tdMatch != null) {
      final attrs = tdMatch.group(1) ?? '';
      String grab(String k) {
        final m =
            RegExp('$k="([^"]*)"', caseSensitive: false).firstMatch(attrs);
        return (m?.group(1) ?? '').trim();
      }

      if (buf.isNotEmpty) {
        final t = buf.toString().trim();
        if (t.isNotEmpty) out.add({'type': 'thinking', 'content': t});
        buf.clear();
      }
      out.add({
        'type': 'todo',
        'action': grab('action'),
        'items': grab('items'),
      });
      i = tdMatch.end;
      // 非自闭合（配对/裸开）：跳过正文直到 </todo>（若有），正文不进 thinking
      if (!s.substring(tdMatch.start, tdMatch.end).endsWith('/>')) {
        final close = RegExp(r'</todo\s*>', caseSensitive: false)
            .firstMatch(s.substring(i));
        if (close != null) i += close.end;
      }
      continue;
    }

    // <memory_write scope="global|project" key="..." value="..." /> 自闭合（v1.7.39 build92）
    // N9：兼容配对写法 <memory_write ...></memory_write> 与裸开标签（正文忽略）
    final mwMatch = RegExp(
      r'<memory_write\s+([^>]*?)\s*/?>',
      caseSensitive: false,
    ).matchAsPrefix(s, i);
    if (mwMatch != null) {
      final attrs = mwMatch.group(1) ?? '';
      String grab(String k) {
        final m =
            RegExp('$k="([^"]*)"', caseSensitive: false).firstMatch(attrs);
        return (m?.group(1) ?? '').trim();
      }

      if (buf.isNotEmpty) {
        final t = buf.toString().trim();
        if (t.isNotEmpty) out.add({'type': 'thinking', 'content': t});
        buf.clear();
      }
      out.add({
        'type': 'memory_write',
        'scope': grab('scope'),
        'key': grab('key'),
        'value': grab('value'),
      });
      i = mwMatch.end;
      // 非自闭合（配对/裸开）：跳过正文直到 </memory_write>（若有）
      if (!s.substring(mwMatch.start, mwMatch.end).endsWith('/>')) {
        final close = RegExp(r'</memory_write\s*>', caseSensitive: false)
            .firstMatch(s.substring(i));
        if (close != null) i += close.end;
      }
      continue;
    }

    // build104（U4 容错）：弱模型畸形写法——<memory_write">entries:[{...}]
    // （标签名后粘引号 + JSON 数组负载）。标准正则匹配不到（引号后无空白），
    // 模型"以为写了"实际没执行（实机思考面板实锤）。这里兜住并归一化为
    // 标准 entry，只取首个条目；宿主侧 step 会标注「容错解析」。
    if (i + 1 < s.length && s[i + 1] == '"') {
      final mwGlued = RegExp(
        r'<memory_write"?>\s*(?:entries\s*:\s*)?(\[[\s\S]*?\]|\{[\s\S]*?\})',
        caseSensitive: false,
      ).matchAsPrefix(s, i);
      if (mwGlued != null) {
        final payload = mwGlued.group(1) ?? '';
        String grabJson(String k) {
          final m =
              RegExp('"$k"\\s*:\\s*"([^"]*)"').firstMatch(payload);
          return (m?.group(1) ?? '').trim();
        }

        if (buf.isNotEmpty) {
          final t = buf.toString().trim();
          if (t.isNotEmpty) out.add({'type': 'thinking', 'content': t});
          buf.clear();
        }
        out.add({
          'type': 'memory_write',
          'scope': grabJson('scope').isEmpty ? 'global' : grabJson('scope'),
          'key': grabJson('key'),
          'value': grabJson('value'),
          'tolerant': 'true',
        });
        i += mwGlued.end;
        continue;
      }
    }

    // <memory_delete scope="global|project" key="..." /> 自闭合（N8 build94：记忆删除）
    // N9：同样兼容配对写法 <memory_delete ...></memory_delete> 与裸开标签
    final mdwMatch = RegExp(
      r'<memory_delete\s+([^>]*?)\s*/?>',
      caseSensitive: false,
    ).matchAsPrefix(s, i);
    if (mdwMatch != null) {
      final attrs = mdwMatch.group(1) ?? '';
      String grab(String k) {
        final m =
            RegExp('$k="([^"]*)"', caseSensitive: false).firstMatch(attrs);
        return (m?.group(1) ?? '').trim();
      }

      if (buf.isNotEmpty) {
        final t = buf.toString().trim();
        if (t.isNotEmpty) out.add({'type': 'thinking', 'content': t});
        buf.clear();
      }
      out.add({
        'type': 'memory_delete',
        'scope': grab('scope'),
        'key': grab('key'),
      });
      i = mdwMatch.end;
      // 非自闭合（配对/裸开）：跳过正文直到 </memory_delete>（若有）
      if (!s.substring(mdwMatch.start, mdwMatch.end).endsWith('/>')) {
        final close = RegExp(r'</memory_delete\s*>', caseSensitive: false)
            .firstMatch(s.substring(i));
        if (close != null) i += close.end;
      }
      continue;
    }

    // <get_location /> / <ip_locate /> / <query_quota [refresh="true"] /> /
    // <log_query [category] [keyword] [tail] /> 自闭合
    // （build106：设备定位 + IP 城市级定位；build108 Q1：余额查询；
    //   build109：log_query 补解析接线——build104 起漏登记，模型照骨架输出
    //   也只被当纯文本吞掉，#56 第三次）
    // N9 同思路兼容配对写法与裸开标签。
    final locMatch = RegExp(
      r'<(get_location|ip_locate|query_quota|log_query|connector_guide)\b([^>]*)>',
      caseSensitive: false,
    ).matchAsPrefix(s, i);
    if (locMatch != null) {
      if (buf.isNotEmpty) {
        final t = buf.toString().trim();
        if (t.isNotEmpty) out.add({'type': 'thinking', 'content': t});
        buf.clear();
      }
      final piece = <String, String>{'type': locMatch.group(1)!.toLowerCase()};
      final attrsRaw = locMatch.group(2) ?? '';
      for (final key in const ['refresh', 'category', 'keyword', 'tail']) {
        final m = RegExp('$key="([^"]*)"', caseSensitive: false)
            .firstMatch(attrsRaw);
        if (m != null) piece[key] = m.group(1)!.trim();
      }
      out.add(piece);
      i = locMatch.end;
      // 非自闭合（配对/裸开）：跳过正文直到对应闭合标签（若有）
      if (!s.substring(locMatch.start, locMatch.end).endsWith('/>')) {
        final close = RegExp('</${locMatch.group(1)!}\\s*>', caseSensitive: false)
            .firstMatch(s.substring(i));
        if (close != null) i += close.end;
      }
      continue;
    }

    // build122：<image_gen prompt=".." size=".." n=".." quality=".." />
    // <video_gen prompt=".." seconds=".." size=".." mode=".." />
    // 与 ws_* 同形态（自闭合 + 属性）。build115~121 无这两个标签——不加这一段，
    // 模型照 promptProtocol 输出也只会落进 thinking（#56 检查单的经典漏登记）。
    final genMatch = RegExp(
      r'<(image_gen|video_gen)\b([^>]*?)(/?)>',
      caseSensitive: false,
    ).matchAsPrefix(s, i);
    if (genMatch != null) {
      if (buf.isNotEmpty) {
        final t = buf.toString().trim();
        if (t.isNotEmpty) out.add({'type': 'thinking', 'content': t});
        buf.clear();
      }
      final piece = <String, String>{'type': genMatch.group(1)!.toLowerCase()};
      final genAttrsRaw = genMatch.group(2) ?? '';
      // build131：走 [kGenActionAttrs] 公开白名单（含 image / input_reference）。
      // 漏登记的后果见该常量注释：属性静默丢失 → 图生图无声退化成文生图。
      for (final key in kGenActionAttrs) {
        final m = RegExp('$key="([^"]*)"', caseSensitive: false)
            .firstMatch(genAttrsRaw);
        if (m != null) piece[key] = m.group(1)!.trim();
      }
      // 别名归一：input_reference → image（宿主两侧只读 `image`）
      if (piece['image'] == null && piece['input_reference'] != null) {
        piece['image'] = piece['input_reference']!;
      }
      piece.remove('input_reference');
      out.add(piece);
      i += genMatch.group(0)!.length;
      continue;
    }

    // <ws_list /> / <ws_read path=".." /> / <ws_write path=".." content=".."
    // overwrite="false" /> / <ws_delete path=".." /> / <ws_download url=".."
    // [filename=".."] /> / <ws_export path=".." mode="share|open" />
    // （build114 补充单02 W1：build113 四张表漏登记——模型照 promptProtocol
    // 输出标签，宿主不解析、不执行、不回 toolresult，标签泄漏进答案）
    // build138（G61-G64 扫描顺手修）：两处同型缺陷一并补上——
    //  ① 分支里没有 ws_make_file ⇒ 标签通道根本不解析它（第 6 次「表登记了、
    //     解析分支漏了」，真机表现为标签泄漏进答案、插件从不被 dispatch）；
    //  ② 属性白名单缺 find/replace/all/pattern/glob/ignore_case/kind/title ⇒
    //     ws_patch 拿到空 find、ws_grep 拿到空 pattern、ws_make_file 拿到空 kind，
    //     即 build136 的「补丁必须带 find/replace」在标签通道下是断的。
    //  另外属性段原来用 `[^>]*?`，正文里出现 `>`（如 find="if (a > b)"）就把标签
    //     截断——FC 通道无此限制，两通道结果必然不一致（G64 验收点）。
    final wsMatch = RegExp(
      r'<(ws_list|ws_read|ws_grep|ws_write|ws_patch|ws_delete|ws_download|ws_export|ws_make_file)'
      r'\b((?:[^>"]|"[^"]*")*)(/?)>',
      caseSensitive: false,
    ).matchAsPrefix(s, i);
    if (wsMatch != null) {
      if (buf.isNotEmpty) {
        final t = buf.toString().trim();
        if (t.isNotEmpty) out.add({'type': 'thinking', 'content': t});
        buf.clear();
      }
      final piece = <String, String>{'type': wsMatch.group(1)!.toLowerCase()};
      final attrsRaw = wsMatch.group(2) ?? '';
      for (final key in const [
        'path',
        'content',
        'overwrite',
        'mode',
        'url',
        'filename',
        'find',
        'replace',
        'all',
        'pattern',
        'glob',
        'ignore_case',
        'kind',
        'title',
      ]) {
        final m = RegExp('$key="([^"]*)"', caseSensitive: false)
            .firstMatch(attrsRaw);
        if (m != null) piece[key] = _wsAttrValue(m.group(1)!);
      }
      i = wsMatch.end;
      // N9 兼容：非自闭合（配对/裸开）
      final selfClosed = wsMatch.group(3) == '/';
      if (!selfClosed) {
        final close = RegExp('</${wsMatch.group(1)!}\\s*>', caseSensitive: false)
            .firstMatch(s.substring(i));
        if (close != null) {
          if ((piece['type'] == 'ws_write' ||
                  piece['type'] == 'ws_make_file') &&
              (piece['content']?.isEmpty ?? true)) {
            // 配对写法 <ws_write path="..">正文</ws_write>：正文当 content
            final body = s.substring(i, i + close.start).trim();
            if (body.isNotEmpty) piece['content'] = body;
          }
          i += close.end;
        }
      }
      out.add(piece);
      continue;
    }

    // build180（刀二）：<web_navigate url="https://…" /> / <web_read /> /
    // <web_act idx="7" action="click|input|clear" value="要填的文字" /> /
    // <web_back />（属性协议见 docs/RESEARCH_内置浏览器可行性…§4.1）。
    // 形状照抄上面的 wsMatch 分支：属性段必须允许引号内出现 `>`
    // （`url="https://x/a>b"`、`value="if (a > b)"` 都是真实页面文案），
    // 否则两通道（标签 / FC）解析出的字段必然不一致（G64 验收点同款）。
    final webMatch = RegExp(
      r'<(web_navigate|web_read|web_act|web_back)'
      r'\b((?:[^>"]|"[^"]*")*)(/?)>',
      caseSensitive: false,
    ).matchAsPrefix(s, i);
    if (webMatch != null) {
      if (buf.isNotEmpty) {
        final t = buf.toString().trim();
        if (t.isNotEmpty) out.add({'type': 'thinking', 'content': t});
        buf.clear();
      }
      final piece = <String, String>{'type': webMatch.group(1)!.toLowerCase()};
      final webAttrsRaw = webMatch.group(2) ?? '';
      for (final key in const ['url', 'idx', 'action', 'value']) {
        final m = RegExp('$key="([^"]*)"', caseSensitive: false)
            .firstMatch(webAttrsRaw);
        if (m != null) piece[key] = _wsAttrValue(m.group(1)!);
      }
      i = webMatch.end;
      // N9 兼容：配对/裸开写法（<web_act …>…</web_act>）正文一律忽略
      if (webMatch.group(3) != '/') {
        final close = RegExp('</${webMatch.group(1)!}\\s*>', caseSensitive: false)
            .firstMatch(s.substring(i));
        if (close != null) i += close.end;
      }
      out.add(piece);
      continue;
    }

    // <plugin_detail name="..." /> 自闭合（v1.7.17：只读加载插件完整协议）
    final pdMatch = RegExp(
      r'<plugin_detail\s+([^>]*?)\s*/>',
      caseSensitive: false,
    ).matchAsPrefix(s, i);
    if (pdMatch != null) {
      final attrs = pdMatch.group(1) ?? '';
      final nameMatch =
          RegExp(r'name="([^"]*)"', caseSensitive: false).firstMatch(attrs);
      final name = (nameMatch?.group(1) ?? '').trim();
      if (buf.isNotEmpty) {
        final t = buf.toString().trim();
        if (t.isNotEmpty) out.add({'type': 'thinking', 'content': t});
        buf.clear();
      }
      if (name.isNotEmpty) {
        out.add({'type': 'plugin_detail', 'name': name});
      }
      i = pdMatch.end;
      continue;
    }

    // <mcp_detail plugin_id="..." tool="..." /> 自闭合（v1.7.17）
    final mdMatch = RegExp(
      r'<mcp_detail\s+([^>]*?)\s*/>',
      caseSensitive: false,
    ).matchAsPrefix(s, i);
    if (mdMatch != null) {
      final attrs = mdMatch.group(1) ?? '';
      String grab(String k) {
        final m =
            RegExp('$k="([^"]*)"', caseSensitive: false).firstMatch(attrs);
        return (m?.group(1) ?? '').trim();
      }

      final pluginId = grab('plugin_id');
      final tool = grab('tool');
      if (buf.isNotEmpty) {
        final t = buf.toString().trim();
        if (t.isNotEmpty) out.add({'type': 'thinking', 'content': t});
        buf.clear();
      }
      if (pluginId.isNotEmpty && tool.isNotEmpty) {
        out.add({'type': 'mcp_detail', 'pluginId': pluginId, 'tool': tool});
      }
      i = mdMatch.end;
      continue;
    }

    // <skill_detail name="..." /> 自闭合（v1.7.17：只读加载 Skill 完整规则）
    final sdMatch = RegExp(
      r'<skill_detail\s+([^>]*?)\s*/>',
      caseSensitive: false,
    ).matchAsPrefix(s, i);
    if (sdMatch != null) {
      final attrs = sdMatch.group(1) ?? '';
      final nameMatch =
          RegExp(r'name="([^"]*)"', caseSensitive: false).firstMatch(attrs);
      final name = (nameMatch?.group(1) ?? '').trim();
      if (buf.isNotEmpty) {
        final t = buf.toString().trim();
        if (t.isNotEmpty) out.add({'type': 'thinking', 'content': t});
        buf.clear();
      }
      if (name.isNotEmpty) {
        out.add({'type': 'skill_detail', 'name': name});
      }
      i = sdMatch.end;
      continue;
    }

    // <install_skill url="..." query="..." name="..." /> 自闭合（v1.7.38：AI 代装 Skill）
    final insMatch = RegExp(
      r'<install_skill\s+([^>]*?)\s*/>',
      caseSensitive: false,
    ).matchAsPrefix(s, i);
    if (insMatch != null) {
      final attrs = insMatch.group(1) ?? '';
      String grab(String k) {
        final m =
            RegExp('$k="([^"]*)"', caseSensitive: false).firstMatch(attrs);
        return (m?.group(1) ?? '').trim();
      }

      if (buf.isNotEmpty) {
        final t = buf.toString().trim();
        if (t.isNotEmpty) out.add({'type': 'thinking', 'content': t});
        buf.clear();
      }
      out.add({
        'type': 'install_skill',
        'url': grab('url'),
        'query': grab('query'),
        'name': grab('name'),
      });
      i = insMatch.end;
      continue;
    }

    // <install_mcp endpoint="..." query="..." name="..." /> 自闭合（v1.7.38：AI 代装 MCP）
    final insMcpMatch = RegExp(
      r'<install_mcp\s+([^>]*?)\s*/>',
      caseSensitive: false,
    ).matchAsPrefix(s, i);
    if (insMcpMatch != null) {
      final attrs = insMcpMatch.group(1) ?? '';
      String grab(String k) {
        final m =
            RegExp('$k="([^"]*)"', caseSensitive: false).firstMatch(attrs);
        return (m?.group(1) ?? '').trim();
      }

      if (buf.isNotEmpty) {
        final t = buf.toString().trim();
        if (t.isNotEmpty) out.add({'type': 'thinking', 'content': t});
        buf.clear();
      }
      out.add({
        'type': 'install_mcp',
        'endpoint': grab('endpoint'),
        'query': grab('query'),
        'name': grab('name'),
      });
      i = insMcpMatch.end;
      continue;
    }

    // <unknown_tool_call name="..." /> 自闭合（G37/build124：ChatML 里出现了
    // 宿主不认识的 invoke 名）。语义是**显式失败**：宿主据此回灌教学
    // toolresult 引导模型改用正确语法，绝不静默当文本、更不假装成功。
    final utcMatch = RegExp(
      r'<unknown_tool_call\s+([^>]*?)\s*/>',
      caseSensitive: false,
    ).matchAsPrefix(s, i);
    if (utcMatch != null) {
      final attrs = utcMatch.group(1) ?? '';
      final nameMatch =
          RegExp(r'name="([^"]*)"', caseSensitive: false).firstMatch(attrs);
      final name = (nameMatch?.group(1) ?? '').trim();
      if (buf.isNotEmpty) {
        final t = buf.toString().trim();
        if (t.isNotEmpty) out.add({'type': 'thinking', 'content': t});
        buf.clear();
      }
      if (name.isNotEmpty) {
        out.add({'type': 'unknown_tool_call', 'name': name});
      }
      i = utcMatch.end;
      continue;
    }

    // <card type="..." title="...">JSON</card> 配对（v1.7.38：富交互卡片）
    // 正常用法在 <answer> 内（气泡端渲染，不走本分支）；本分支只兜住
    // 误放到 answer 外的卡片，交 CardPlugin 留"位置错误"提醒节点
    final cardOpen =
        RegExp(r'<card\b([^>]*)>', caseSensitive: false).matchAsPrefix(s, i);
    if (cardOpen != null) {
      final close = RegExp(r'</card\s*>', caseSensitive: false)
          .firstMatch(s.substring(cardOpen.end));
      if (close != null) {
        final attrs = cardOpen.group(1) ?? '';
        String grab(String k) {
          final m =
              RegExp('$k="([^"]*)"', caseSensitive: false).firstMatch(attrs);
          return (m?.group(1) ?? '').trim();
        }

        if (buf.isNotEmpty) {
          final t = buf.toString().trim();
          if (t.isNotEmpty) out.add({'type': 'thinking', 'content': t});
          buf.clear();
        }
        out.add({
          'type': 'card',
          'cardType': grab('type'),
          'title': grab('title'),
          'content':
              s.substring(cardOpen.end, cardOpen.end + close.start).trim(),
        });
        i = cardOpen.end + close.end;
        continue;
      }
    }

    // N9：<suggest items="问题1||问题2" /> 自闭合容错（标准写法是配对 <suggest>...</suggest>，
    // 弱模型写成自闭合带 items 属性时也能解析出推荐问题）
    final sgMatch = RegExp(
      r'<suggest\s+([^>]*?)\s*/>',
      caseSensitive: false,
    ).matchAsPrefix(s, i);
    if (sgMatch != null) {
      final attrs = sgMatch.group(1) ?? '';
      final itemsMatch =
          RegExp(r'items="([^"]*)"', caseSensitive: false).firstMatch(attrs);
      final items = (itemsMatch?.group(1) ?? '').trim();
      if (items.isNotEmpty) {
        if (buf.isNotEmpty) {
          final t = buf.toString().trim();
          if (t.isNotEmpty) out.add({'type': 'thinking', 'content': t});
          buf.clear();
        }
        out.add({'type': 'suggest', 'content': items});
      }
      i = sgMatch.end;
      continue;
    }

    // build164（#82）：<progress>一句话</progress> —— 面向用户的阶段小结。
    // 配对截取的口径照教训 #58（前向吞噬）保守：
    //  - **真的见到 </progress> 才产片段**；未闭合时只跳过开标签本身，尾部文本
    //    留给后面的循环按既有规则归位（thinking / answer），既不整段吞进小结
    //    （那是 #58 那种"把后半个响应吃掉"的事故形状），也不把半截小结当正文吐出去；
    //  - 自闭合 <progress text="…" /> 是弱模型容错形态，只认 text 属性；
    //  - 正文为空不产片段（模型偶尔只写个空标签占位，产出来是一条空行噪音）。
    final pgMatch = RegExp(
      r'<progress\b([^>]*?)(/?)>',
      caseSensitive: false,
    ).matchAsPrefix(s, i);
    if (pgMatch != null) {
      final selfClosed = pgMatch.group(2) == '/';
      var body = '';
      var next = pgMatch.end;
      if (selfClosed) {
        final tm = RegExp(r'text="([^"]*)"', caseSensitive: false)
            .firstMatch(pgMatch.group(1) ?? '');
        body = (tm?.group(1) ?? '').trim();
      } else {
        final close = RegExp(r'</progress\s*>', caseSensitive: false)
            .firstMatch(s.substring(pgMatch.end));
        if (close == null) {
          // 未闭合：只吃掉开标签（见上），尾部按原规则继续解析
          i = pgMatch.end;
          continue;
        }
        body = s.substring(pgMatch.end, pgMatch.end + close.start).trim();
        next = pgMatch.end + close.end;
      }
      if (body.isNotEmpty) {
        if (buf.isNotEmpty) {
          final t = buf.toString().trim();
          if (t.isNotEmpty) out.add({'type': 'thinking', 'content': t});
          buf.clear();
        }
        out.add({'type': kProgressTagName, 'content': body});
      }
      i = next;
      continue;
    }

    // <thinking> / <answer> / <ask_user> / <mcp_call> 配对标签
    final mcpOpen = RegExp(
      r'<mcp_call\s+([^>]*?)>',
      caseSensitive: false,
    ).matchAsPrefix(s, i);
    if (mcpOpen != null) {
      String grab(String key) {
        final match = RegExp('$key="([^"]*)"', caseSensitive: false)
            .firstMatch(mcpOpen.group(1) ?? '');
        return (match?.group(1) ?? '').trim();
      }

      final pluginId = grab('plugin_id');
      final tool = grab('tool');
      final close = RegExp(r'</mcp_call\s*>', caseSensitive: false)
          .firstMatch(s.substring(mcpOpen.end));
      final bodyEnd = close == null ? s.length : mcpOpen.end + close.start;
      final arguments = s.substring(mcpOpen.end, bodyEnd).trim();
      dynamic decoded;
      try {
        decoded = jsonDecode(arguments);
      } catch (_) {
        decoded = null;
      }
      if (pluginId.isNotEmpty && tool.isNotEmpty && decoded is Map) {
        if (buf.isNotEmpty) {
          final t = buf.toString().trim();
          if (t.isNotEmpty) out.add({'type': 'thinking', 'content': t});
          buf.clear();
        }
        out.add({
          'type': 'mcp_call',
          'pluginId': pluginId,
          'tool': tool,
          'arguments': jsonEncode(Map<String, dynamic>.from(decoded)),
        });
      } else {
        buf.write(s.substring(i, bodyEnd));
        if (close != null) {
          i = mcpOpen.end + close.end;
          continue;
        }
      }
      if (close == null) {
        i = s.length;
        break;
      }
      i = mcpOpen.end + close.end;
      continue;
    }
    // v1.7.12：<skill_call name="skill.xxx">{optional JSON body}</skill_call>
    // 模仿 mcp_call：配对标签 + 可选 JSON body（body 为空/非法 JSON 也接受，
    // 因为 Skill 本质是 prompt 注入，不需要严格的入参 schema）
    final skillOpen = RegExp(
      r'<skill_call\s+([^>]*?)>',
      caseSensitive: false,
    ).matchAsPrefix(s, i);
    if (skillOpen != null) {
      String grab(String key) {
        final match = RegExp('$key="([^"]*)"', caseSensitive: false)
            .firstMatch(skillOpen.group(1) ?? '');
        return (match?.group(1) ?? '').trim();
      }

      final skillName = grab('name');
      final close = RegExp(r'</skill_call\s*>', caseSensitive: false)
          .firstMatch(s.substring(skillOpen.end));
      final bodyEnd = close == null ? s.length : skillOpen.end + close.start;
      final rawBody = s.substring(skillOpen.end, bodyEnd).trim();
      dynamic decoded;
      try {
        decoded = rawBody.isNotEmpty ? jsonDecode(rawBody) : null;
      } catch (_) {
        decoded = null;
      }
      if (skillName.isNotEmpty) {
        if (buf.isNotEmpty) {
          final t = buf.toString().trim();
          if (t.isNotEmpty) out.add({'type': 'thinking', 'content': t});
          buf.clear();
        }
        out.add({
          'type': 'skill_call',
          'name': skillName,
          if (decoded is Map)
            'arguments': jsonEncode(Map<String, dynamic>.from(decoded)),
          if (decoded is! Map && rawBody.isNotEmpty) 'content': rawBody,
        });
      } else {
        buf.write(s.substring(i, bodyEnd));
        if (close != null) {
          i = skillOpen.end + close.end;
          continue;
        }
      }
      if (close == null) {
        i = s.length;
        break;
      }
      i = skillOpen.end + close.end;
      continue;
    }
    final thinkMatch = RegExp(r'<(thinking|think)>', caseSensitive: false)
        .firstMatch(s.substring(i));
    final answerMatch =
        RegExp(r'<answer>', caseSensitive: false).firstMatch(s.substring(i));
    final askMatch =
        RegExp(r'<ask_user>', caseSensitive: false).firstMatch(s.substring(i));
    final suggestMatch =
        RegExp(r'<suggest>', caseSensitive: false).firstMatch(s.substring(i));
    int earliest = 1 << 30;
    String earliestTag = '';
    String openTag = '';
    if (thinkMatch != null && i + thinkMatch.start < earliest) {
      earliest = i + thinkMatch.start;
      earliestTag = 'thinking';
      openTag = thinkMatch.group(0)!;
    }
    if (answerMatch != null && i + answerMatch.start < earliest) {
      earliest = i + answerMatch.start;
      earliestTag = 'answer';
      openTag = answerMatch.group(0)!;
    }
    if (askMatch != null && i + askMatch.start < earliest) {
      earliest = i + askMatch.start;
      earliestTag = 'ask_user';
      openTag = askMatch.group(0)!;
    }
    if (suggestMatch != null && i + suggestMatch.start < earliest) {
      earliest = i + suggestMatch.start;
      earliestTag = 'suggest';
      openTag = suggestMatch.group(0)!;
    }
    if (earliestTag.isNotEmpty) {
      final open = earliest;
      final isThink = earliestTag == 'thinking';
      final isAnswer = earliestTag == 'answer';
      final closeTag = isThink
          ? (openTag.toLowerCase() == '<think>' ? '</think>' : '</thinking>')
          : isAnswer
              ? '</answer>'
              : earliestTag == 'suggest'
                  ? '</suggest>'
                  : '</ask_user>';
      if (open > i) {
        // build109（U8）修复：这段中间文本可能含有自闭合工具标签（search/
        // query_quota/get_location/log_query…）——原实现直接整段当 thinking
        // 吞掉，导致模型在裸思考文本（后面跟 <answer> 等）里输出的工具标签
        // 永不执行（装机日志实锤：query_quota 写在 <answer> 前被吞，用户
        // 「看不到插件被使用」）。跨度内按定义不含 thinking/answer/ask_user/
        // suggest 开标签（earliest 即第一个），递归解析一层即安全、深度恒为 1。
        final mid = parseReActOutput(s.substring(i, open));
        if (mid.isEmpty) {
          buf.write(s.substring(i, open));
        } else {
          for (final p in mid) {
            if (p['type'] == 'thinking') {
              buf.write(p['content'] ?? '');
              buf.write('\n');
            } else {
              if (buf.isNotEmpty) {
                final t = buf.toString().trim();
                if (t.isNotEmpty) out.add({'type': 'thinking', 'content': t});
                buf.clear();
              }
              out.add(p);
            }
          }
        }
      }
      if (buf.isNotEmpty) {
        final t = buf.toString().trim();
        if (t.isNotEmpty) out.add({'type': 'thinking', 'content': t});
        buf.clear();
      }
      final closeMatch = RegExp(
        RegExp.escape(closeTag),
        caseSensitive: false,
      ).firstMatch(s.substring(open));
      final tagLen = openTag.length;
      if (closeMatch == null) {
        final body = s.substring(open + tagLen);
        out.add({'type': earliestTag, 'content': body.trim()});
        i = s.length;
        break;
      }
      final close = open + closeMatch.start;
      final body = s.substring(open + tagLen, close);
      out.add({'type': earliestTag, 'content': body.trim()});
      i = close + closeMatch.group(0)!.length;
      continue;
    }
    buf.writeCharCode(s.codeUnitAt(i));
    i++;
  }
  if (buf.isNotEmpty) {
    final rest = buf.toString().trim();
    if (rest.isNotEmpty) out.add({'type': 'thinking', 'content': rest});
  }
  return out;
}

// ============================================================================
// O4（build95）：裸文本答案的「异语言内心独白」剥离
// ============================================================================

final RegExp _cjkRun = RegExp(r'[一-鿿]');

int _cjkCount(String s) => _cjkRun.allMatches(s).length;

/// 一行是否算「成段的用户语言文字」。
/// 中文：一行 ≥2 个汉字；英文：一行 ≥4 个拉丁字母单词。
bool _isUserLangLine(String line, bool isZh) {
  if (isZh) return _cjkCount(line) >= 2;
  return RegExp(r'[A-Za-z]+([^A-Za-z]+[A-Za-z]+){3,}').hasMatch(line);
}

/// O4（build95）：剥离裸文本答案中的「异语言内心独白」前缀。
///
/// 背景：弱模型不打 `<thinking>/<answer>` 标签时，会用英文写一段推理再输出
/// 中文正文；轮末裸文本兜底把整段当答案落库，用户在答案气泡前看到一串英文
/// 内心独白（脏答案还会回填历史、喂给 N14 suggest）。
///
/// 规则（以会话语言为锚）：
/// - 从首行起找到第一行「成段的用户语言文字」作为正文起点，起点之前的
///   异语言推理段剥离（调用方负责归入 reasoningStep）；
/// - 起点之后的内容全部保留（中英对照正文不误剥）；
/// - 前缀本身含成段用户语言文字 → 不是独白（正常混排），返回原文；
/// - 全文无用户语言文字（纯外语提问/回答）→ 不剥，返回原文；
/// - 剥离结果过短（切错风险）→ 返回原文，不硬切。
String stripForeignMonologue(String text, {required bool isZh}) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return text;
  final lines = trimmed.split('\n');
  var firstUserLang = -1;
  for (var i = 0; i < lines.length; i++) {
    if (_isUserLangLine(lines[i], isZh)) {
      firstUserLang = i;
      break;
    }
  }
  // 无正文锚点（纯外语）或首行即正文 → 不剥
  if (firstUserLang <= 0) return text;
  final prefix = lines.sublist(0, firstUserLang).join('\n');
  // 前缀里若也夹带了不少用户语言文字 → 正常混排正文而非独白前缀，不剥
  final prefixUserChars = isZh
      ? _cjkCount(prefix)
      : RegExp(r'[A-Za-z]').allMatches(prefix).length;
  final userCharThreshold = isZh ? 2 : 20;
  if (prefixUserChars > userCharThreshold) return text;
  final stripped = lines.sublist(firstUserLang).join('\n').trim();
  // 剥完太短（<10 字）说明切错了，保留原文
  if (stripped.length < 10) return text;
  return stripped;
}

// ============================================================================
// O11（build98）：裸文本「纯独白」检测——无用户语言锚点时的二次拦截
// ============================================================================

/// 独白线索：弱模型（如 glm-flash 系）不打标签时的典型英文内心独白开头。
/// 注意：Dart RegExp 不支持 lookbehind，统一用 ^/换行/句读空格锚定；
/// 禁内联 (?i)，用 caseSensitive: false。
/// build99（验收 N1）：剔除 first/step/hmm/wait 等「正文结构词」——它们同样
/// 是英文教程式答案的标准写法（"First, install nginx. Step 1: ..."），
/// 曾把正常英文答案整段误判为独白，只保留强独白信号词。
/// build103（I5）：补 `Answer content:` / `Then explain:` / `Then offer to`
/// 等「输出规划话术」（build102 实机日志：这类元话语整段漏进答案正文）。
final RegExp _monologueCue = RegExp(
  r"(?:^|[\n.!?]\s*)(okay|alright|let me|let's|let us|i'm going to|"
  r'i (?:need|should|will|must|want) to|we (?:need|should|will) to|'
  r'the user (?:wants|asked|is asking|said|needs)|'
  r'my (?:plan|approach|task|goal) is|'
  r'to (?:answer|respond|address|tackle) this|'
  r'answer content\s*[:]|'
  r'then (?:explain|offer|provide|summarize)\b)',
  caseSensitive: false,
);

/// build99（验收 N1）：答案结构特征——代码围栏/标题/多行列表是「正文答案」
/// 的强信号，命中即不判独白（教程式英文答案自救通道）。
/// build99（F1）：标题豁免从 `#{1,3}` 扩到 `#{1,6}`——h4~h6 同样是标题结构，
/// 只用 h4 的英文教程答案此前仍会被判独白（探针实测 true）。
final RegExp _monologueHeadingLine = RegExp(r'^#{1,6} \S', multiLine: true);
final RegExp _monologueListLine =
    RegExp(r'^\s*(?:[-*+]|\d+[.)])\s+\S', multiLine: true);

bool _hasAnswerStructure(String text) {
  // build100（中3）围栏豁免重写：原版「成对围栏（≥2 个 ```）且 cue<3」被
  // 反馈误杀英文教程答案——原因有三：
  //   a) cue 是对**全文**计数（含代码块内的 let me / I need to 等注释），
  //      英文教程里这些词出现 3 次以上很常见；
  //   b) 弱模型漏写闭合 ```，只输出 1 个围栏就被判独白；
  //   c) 标题豁免没有 cue 上限，独白里插一行 # 就能逃（与围栏尺度不一致）。
  //
  // 新规则：
  //   1) cue 计数只针对**围栏外文本**（剔除成对代码块内容，未闭合的尾部
  //      剩余部分也剔除）—— 代码注释里的 let me 不再污染 cue 计数；
  //   2) 围栏豁免放宽到**任一成对围栏（含 ```python 等带语言标记）即
  //      算答案结构信号**，cue 必须 <3（仍允许 1 个弱独白线索）；
  //   3) 标题豁免加 cue<5 上限（标题是强答案信号，阈值比围栏更宽）；
  //   4) 单 ```（弱模型漏闭合）也算豁免信号，但 cue 必须 <2（更严）；
  //   5) 列表 ≥2 行豁免维持 build99 行为（不设 cue 上限）—— 多行列表
  //      本身就是「按条回答」结构，强行加 cue 上限会让 build99 既有 r8
  //      用例（列表 3 项 + 4 个 cue 词）误判回归。
  final outsideText = _textOutsideFences(text);
  final cueInText = _monologueCue.allMatches(outsideText).length;

  final fenceMatches = '```'.allMatches(text);
  // 配对围栏数 = floor(总数 / 2)；剩 1 个视为「漏闭合」单围栏
  final pairedFences = fenceMatches.length ~/ 2;
  final hasUnclosedFence = fenceMatches.length.isOdd;

  if (pairedFences >= 1 && cueInText < 3) return true;
  if (hasUnclosedFence && cueInText < 2) return true;
  if (_monologueHeadingLine.hasMatch(text) && cueInText < 5) return true;
  // 列表需 ≥2 行才豁免——独白里偶尔出现单行编号不构成结构
  return _monologueListLine.allMatches(text).length >= 2;
}

/// build100（中3）：剔除成对代码围栏内的文本。
/// 配对规则：第 1 个 ``` 起到下一个 ``` 之间的内容全部删除；尾部若还有
/// 未闭合的 ```（弱模型漏写闭合），从该 ``` 到字符串末尾也删除。
/// 用于在 cue 计数时排除代码块内「let me / I need to」等注释常见词。
String _textOutsideFences(String text) {
  var result = text;
  // 反复剥除「```...```」成对段
  final re = RegExp(r'```[\s\S]*?```');
  while (true) {
    final next = result.replaceAll(re, '');
    if (next.length == result.length) break;
    result = next;
  }
  // 剩余未闭合的尾部 ```…end：弱模型漏闭合，删尾部
  final tailStart = result.lastIndexOf('```');
  if (tailStart >= 0) {
    result = result.substring(0, tailStart);
  }
  return result;
}

/// build168（BUGSCAN_build166 ①-1 修法②）：**英文**计划语线索表。
///
/// 旧状况：整段一票制的 `looksLikeMonologue` 里，中文走 `_zhMetaProcessCue`
/// （元过程语用特征），英文只有 build98 的 `_monologueCue` 那一小撮**句首**
/// 线索，且必须靠 `[\n.!?]` 锚定 —— 于是 `I'll include a link button.`、
/// `Now I need to check the file.` 这类「第一人称未来意图 + 工具/步骤叙述」
/// 一条都不认（166 真机截图 ①-1 的七个漏网行就是这个形状）。
///
/// 刻意**不收**（假阳性，见 test/build168_monologue_gate_test.dart）：
/// - `I think / I believe / I suggest / I recommend / In my opinion`——
///   立场句是**给用户看的判断**，不是计划（与中文「我认为…」同口径）；
/// - `I must / have to point out|note|say`——同上，是结论的语气；
/// - 第二/三人称（`you need to` / `we should`）——那是正文里的指令，
///   模型对自己说话才叫计划语。
/// 本表**不带 `^` 锚**：是否「行首起手」由 [_leadFiller] + [_planningCueAll]
/// 统一判，这样同一张表既能逐行用、也能在整段里数线索。
final RegExp _enPlanningCue = RegExp(
  r"let(?:'|’)?s\b|let me\b|"
  r"i(?:'|’)?m (?:going|about|planning|required|supposed|trying) to|"
  r"i am (?:going|about|planning|required|supposed|trying) to|"
  r"i(?:'|’)?ll\b|i will\b|i shall\b|i(?:'|’)?d better\b|i had better\b|"
  r"i need to|i(?:'|’)?ve got to|i have got to|i gotta\b|"
  r"i should\b|i must\b|i have to|i want to|i plan to|i intend to|"
  r"i propose to|i(?:'|’)?m to\b|"
  r"i (?:will|shall|should|must|need to|want to|plan to|’ll|'ll) "
  r"(?:first\b|then\b|next\b|now\b|immediately\b|go on to\b|"
  r"(?:also |just |again )?(?:search|look up|call|invoke|use|check|fetch|query|"
  r"read|write|run|create|generate|include|add|make|open|try|summarize|gather|pull|compose))|"
  r"my (?:plan|approach|task|goal|next step|to-?do list)\b|"
  r"the user (?:wants|asked|needs|is asking|said|wishes)|"
  r"to (?:answer|respond|address|tackle|finish|complete) (?:this|that|it|the|your|their)|"
  r"before (?:answering|responding|writing|generating|finalizing)\b|"
  r"answer content\s*[:：]|"
  r"then (?:explain|offer|provide|summarize|write|add|include|compose)\b|"
  r"for the (?:final|actual) answer",
  caseSensitive: false,
);

/// build168：反向闸——**说给用户听的话**不是计划句（中英双语）。命中即整行保留，
/// 优先级高于线索表（`I have to point out …` / `我必须指出…` 含第一人称
/// 未来式语气，但它是给用户的结论，不是下一步安排）。
///
/// 两类，缺一不可：
/// - **立场/评价句**：我认为 / I think / my advice…；
/// - **面向用户的收尾句**：`let me know (if …)`。它字面上也是 `let me` 起手，
///   但内容是把话头交回用户，不是模型的下一步安排——166 那轮之后正常答案的
///   最后一行被整条剥进思考面板，用户看不到客套收尾（本表第 ② 类存在的全部理由，
///   见 test/build168_monologue_gate_test.dart 柱③ 最后一条）。
final RegExp _conclusionStanceCue = RegExp(
  r'我(?:认为|觉得|建议|判断|估计|倾向于|看法|建议是|的建议|的结论|的答案)|'
  r'依我看|按我的经验|我的判断|我认为|我必须指出|我需要指出|我要提醒|'
  r"\bi (?:think|believe|reckon|suggest|recommend|advise|feel|notice|found|see|"
  r"doubt|disagree|tend|suspect|am convinced)\b|"
  r"\bi'?d say\b|\bin my (?:opinion|view|experience|judgement|judgment)\b|"
  r"\bmy (?:advice|recommendation|view|take|verdict|conclusion|opinion|guess)\b|"
  r"\bi (?:must|have to|had to|should|can) (?:point out|note|notice|emphasi[sz]e|"
  r'stress|mention|clarify|say|add)\b|'
  r"\blet me know\b",
  caseSensitive: false,
);

/// build168：行首填充词（Okay,/ So, Now, First, 那/所以/首先…）——跳过它们之后
/// 才算「行首起手」。刻意不含 `let me`、`i will` 这类真线索。
final RegExp _leadFiller = RegExp(
  r"^(?:(?:okay|ok|alright|so|now|then|next|first|second|finally|well|right|"
  r"anyway|anyhow|好|好的|那|那么|所以|于是|首先|然后|接下来|嗯+)"
  r"[，,、。.:;；!！?？\s]*)*",
  caseSensitive: false,
);

/// build168：**逐行判据用的合并线索表**（中文元过程 ∪ 英文计划语 ∪ build98
/// 旧句首线索）。三张表各自单独维护、这里只做组合，绝不把线索抄第二份——
/// 「同一条规则住在两个文件」在本仓已经犯过两次（BUGSCAN_build166 开头）。
final RegExp _planningCueAll = RegExp(
  '(?:${_zhMetaProcessCue.pattern})|(?:${_enPlanningCue.pattern})'
  '|(?:${_monologueCue.pattern})',
  caseSensitive: false,
);

/// build168（BUGSCAN_build166 ①-1 修法①）：**唯一的逐行独白判据**。
///
/// 一行算计划语，当且仅当：
/// ①先过反向闸：命中 [_conclusionStanceCue]（我认为 / I think…）→ 一律不是；
/// ②线索在**行首起手**（可先跳过 [_leadFiller] 里的填充词）——
///   `Let me write.` / `I'll include a link button.` / `接下来我调用工具。`；
/// ③或整行线索密集（≥2 处，沿用 build98「单次命中可能是巧合」的口径）。
///
/// 中英两张表**同时**参与判定、不看会话语言：这里看到的是模型原始输出，
/// 会话语言只用来决定「什么算成段的用户语言正文」（[_isUserLangLine]）。
bool isMonologueLine(String line) {
  final t = line.trim();
  if (t.isEmpty) return false;
  if (_conclusionStanceCue.hasMatch(t)) return false;
  final first = _planningCueAll.firstMatch(t);
  if (first == null) return false;
  final lead = _leadFiller.firstMatch(t)?.end ?? 0;
  if (first.start <= lead) return true;
  return _planningCueAll.allMatches(t).length >= 2;
}

/// build168：逐行独白判定的结果（[scanMonologue] 的产物、唯一判定出口）。
class MonologueScan {
  const MonologueScan({
    required this.kept,
    required this.dropped,
    required this.structureKept,
    required this.userLangKept,
    required this.cueHits,
    required this.shortForeignBlob,
  });

  /// 保留行（结论 / 结构豁免 / 无线索），顺序与原文一致
  final List<String> kept;

  /// 判为计划语、应当剥回思考面板的行
  final List<String> dropped;

  /// [kept] 里靠「代码围栏 / 标题 / ≥2 行列表」结构豁免留下的行数（build99 N1）
  final int structureKept;

  /// [kept] 里是否存在「成段的用户语言」行
  final bool userLangKept;

  /// 整段命中的线索总数（build98 口径：旧中/英文两张表，不含行首表，
  /// 免得同一短语被数两遍）
  final int cueHits;

  /// build98 的短文本放行护栏：**非中文会话 + 整段 <80 字 + 整段确实是拉丁文**。
  /// 名字里的 foreign 说的是**文本**是外语，不是会话是外语——旧算法只看 `!isZh`，
  /// 于是英文会话里一句中文元过程自语（`让我整理一下。`）也算"短外语段"被护住，
  /// 与 [isMonologueLine] 的口径打对台（168-2 柱②锁的正是它必须被剥）。
  final bool shortForeignBlob;

  /// 剥掉计划语之后剩下的正文
  String get keptText => kept.join('\n').trim();

  /// 被剥掉的计划语（调用方回思考面板，不丢信息）
  String get droppedText => dropped.join('\n').trim();

  bool get hasMonologue => dropped.isNotEmpty;

  /// 有没有「配当结论」的行：成段用户语言，或结构豁免行
  bool get hasAnswerContent => userLangKept || structureKept > 0;

  /// 整段除了计划语什么都不剩——旧 [looksLikeMonologue] 的语义。
  /// 注意是「按行判完之后什么都不剩」，不是「整段一票否决」。
  bool get looksPurelyLikeMonologue =>
      !shortForeignBlob &&
      dropped.isNotEmpty &&
      cueHits >= 2 &&
      !hasAnswerContent;
}

/// build168：**逐行**扫描裸文本，标出计划语行。整段一票制的老洞（166 ①-1）：
/// 「任何一行像给用户看的文字 ⇒ 整段放行」让 166 那轮 7 行英文计划跟着一条
/// 中文标题一起落地成结论；反方向「一处线索 ⇒ 整段判独白」又会把含一句计划
/// 的长答案整段丢掉。两者都因为「票投在整段」而非「投在每一行」。
///
/// 保守闸门（沿用 build99 N1 / build114 W4-3，只是尺度从段改到行）：
/// - 代码围栏内、标题行、≥2 行列表的列表行 → **结构豁免**（教程式答案自救通道）；
/// - 立场句（[isMonologueLine] 的反向闸）永不剥；
/// - 「整段是不是纯独白」仍要求线索总数 ≥2（单次命中当巧合），非中文会话
///   另留 build98 的 <80 字护栏——**并且这条护栏管到剥行本身**：短拉丁文段
///   不许被剥成空（[MonologueScan.shortForeignBlob] 的字段注释记着为什么）。
MonologueScan scanMonologue(String text, {required bool isZh}) {
  final trimmed = text.trim();
  final shortForeignBlob =
      !isZh && trimmed.length < 80 && _cjkCount(trimmed) == 0;
  final kept = <String>[];
  final dropped = <String>[];
  if (trimmed.isEmpty) {
    return MonologueScan(
      kept: kept,
      dropped: dropped,
      structureKept: 0,
      userLangKept: false,
      cueHits: 0,
      shortForeignBlob: shortForeignBlob,
    );
  }
  final lines = trimmed.split('\n');
  // 列表豁免沿 build99 口径：整段 ≥2 行列表才算「按条回答」结构
  final listLines =
      lines.where((l) => _monologueListLine.hasMatch(l)).length;
  var inFence = false;
  var structureKept = 0;
  var userLangKept = false;
  for (final line in lines) {
    if ('```'.allMatches(line).length.isOdd) {
      // 围栏标记行本身（开/闭都算结构），并翻转围栏态
      inFence = !inFence;
      kept.add(line);
      structureKept++;
      continue;
    }
    if (inFence ||
        _monologueHeadingLine.hasMatch(line) ||
        (listLines >= 2 && _monologueListLine.hasMatch(line))) {
      kept.add(line);
      structureKept++;
      continue;
    }
    if (isMonologueLine(line)) {
      dropped.add(line);
      continue;
    }
    kept.add(line);
    if (!userLangKept && _isUserLangLine(line, isZh)) userLangKept = true;
  }
  final cueHits = _monologueCue.allMatches(trimmed).length +
      _zhMetaProcessCue.allMatches(trimmed).length;
  // build98 护栏要真的护栏（168-4 柱④那条红）：整段又短又是拉丁文时，
  // 「逐行剥完什么都不剩」不许落地成空答案——调用方 chat_screen_react 把
  // `keptText` 为空当成与 `looksPurelyLikeMonologue` 并列的独立不落地条件，
  // 护栏只管后者的话，它在生产路径上是空转的（剥剩空 → 整段不落地 → 他什么也看不到）。
  // 与 [stripChineseMetaProcess] 闸门③「剥完剩余正文 <40 字不剥」同一保守口径：
  // 证据不足以证明这是纯独白，就宁可原样当答案留下。kept/dropped 是划分关系，
  // 所以回灌时把 dropped 清空，同一行不许既算正文又算计划语。
  if (shortForeignBlob && kept.isEmpty && dropped.isNotEmpty) {
    kept.addAll(dropped);
    dropped.clear();
  }
  return MonologueScan(
    kept: kept,
    dropped: dropped,
    structureKept: structureKept,
    userLangKept: userLangKept,
    cueHits: cueHits,
    shortForeignBlob: shortForeignBlob,
  );
}

/// O11（build98）：判断裸文本是否「纯内心独白」而非答案。
///
/// 背景：O4 依赖「用户语言正文锚点」剥离独白前缀；但弱模型有时整段输出
/// 都是英文独白（615 字无一字中文），锚点不存在 → O4 原样返回 → 裸文本
/// 兜底把独白整段落成答案。
///
/// build168：**这层只剩兼容封装**——判据全在 [scanMonologue] / [isMonologueLine]
/// 一处，本函数等价于「逐行判完什么都不剩」。调用方要的是「哪些行是计划语」，
/// 请用 [scanMonologue]（裸文本兜底口 chat_screen_react 已改）。
bool looksLikeMonologue(String text, {required bool isZh}) =>
    scanMonologue(text, isZh: isZh).looksPurelyLikeMonologue;

// ============================================================================
// build114（补充单03 W4）：中文「元过程自语」剥离（纯函数，可单测）
// ============================================================================

/// 中文元过程 cue——工具/协议层与第一人称决策自语。
/// **刻意不含**知识/数学推导词（代入/计算/顶点/对称轴/方程/公式）：
/// 中文思考本身就是成段通顺中文，不能用「是否成段」区分；讲题式答案
/// 含这些词是面向用户的内容，误杀代价高。只剥「绝不可能是给用户看的」
/// 工具/协议自语与第一人称过程决策。
final RegExp _zhMetaProcessCue = RegExp(
  r'<thinking|</thinking|<answer|</answer|'
  r'按协议|协议标签|重新格式|格式写错|格式多了|标签格式|'
  r'toolresult|mcp_detail|mcp_call|tool_call|schema|'
  r'宿主|被拦截|已拦截|重试|换参数|换个参数|重新调用|'
  r'让我整理|让我重新|让我先|让我确认|让我看看|让我检查|'
  r'我已经有了|我已经拿到|我已经获取|其实我可以|其实我应该|'
  r'接下来我|我索取|我输出|我改调|我需要调用|我先调用|我直接给出|'
  r'我需要指出错误|工具失败|这个工具|该工具|'
  r'用户问第|图片OCR|OCR内容',
  caseSensitive: false,
);

/// W4：剥离**结论段之前**的中文元过程自语（增量兜底，保守、不丢信息）。
///
/// 返回 `(clean, stripped)`：stripped 为被剥过程段原文（换行连接），空串 =
/// 无剥离。调用方（AnswerFinalizer.finalize）负责把 stripped 回思考面板。
///
/// 保守闸门（防误杀，缺一不可）：
/// ① `_hasAnswerStructure`（代码围栏/标题/多行列表密集的教程式答案）整体豁免；
/// ② 连续 2 个非 cue 行即认定「结论开始」，之后一律不动（只剥头部）；
/// ③ 剥完剩余正文 < 40 字不剥、原样返回（切错风险 > 收益）；
/// ④ cue 表不含数学/知识推导词（见 _zhMetaProcessCue 注释）。
(String, String) stripChineseMetaProcess(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return (text, '');
  if (!_zhMetaProcessCue.hasMatch(trimmed)) return (text, '');
  // 闸门①：教程式结构整体豁免
  if (_hasAnswerStructure(trimmed)) return (text, '');

  // 句级切分（保留分隔符）：真机日志的中文思考常整段无换行（1189 字样本），
  // 行级扫描对单行混合全文失效——按句读（。！？；\n）切分后逐句判定。
  final sentences = <String>[];
  final buf = StringBuffer();
  for (final ch in trimmed.runes) {
    final c = String.fromCharCode(ch);
    buf.write(c);
    if (c == '\n' || '。！？；'.contains(c)) {
      sentences.add(buf.toString());
      buf.clear();
    }
  }
  if (buf.isNotEmpty) sentences.add(buf.toString());

  final kept = <String>[];
  final removed = <String>[];
  final pending = <String>[]; // 尚未定性的非 cue 句（凑满 2 连续才认定结论开始）
  for (var i = 0; i < sentences.length; i++) {
    final sent = sentences[i];
    final t = sent.trim();
    if (_zhMetaProcessCue.hasMatch(t)) {
      if (pending.isNotEmpty) {
        removed.addAll(pending);
        pending.clear();
      }
      removed.add(sent);
      continue;
    }
    pending.add(sent);
    if (pending.length >= 2) {
      // 闸门②：连续 2 句非 cue → 结论开始，其后全部保留
      kept.addAll(pending);
      pending.clear();
      if (i + 1 < sentences.length) {
        kept.addAll(sentences.sublist(i + 1));
      }
      break;
    }
  }
  // 尾部不足 2 句的非 cue 句：还给正文（不确定则不剥——保守优先）
  if (pending.isNotEmpty) {
    kept.addAll(pending);
  }
  if (removed.isEmpty) return (text, '');
  final clean = kept.join().trim();
  // 闸门③：剥完为空 → 原样返回（整段都是过程自语时交给 O9 零产出守卫，
  // 不在这里把答案清空）。build116（检测批修复）：原阈值 `clean.length < 20`
  // 过严——「让我整理一下已知条件。答案是 42。」这类**短结论 + 前导自语**
  // 是真机高频形态，短不等于错，一律放行等于 L1 在短答案场景失效。
  // 改按「剥除占比」判定：被剥远多于保留（>4 倍）才认为可能切错而放弃。
  if (clean.isEmpty) return (text, '');
  final removedLen = removed.join().trim().length;
  if (removedLen > clean.length * 4) return (text, '');
  return (clean, removed.join().trim());
}

// ============================================================================
// L1（build107）：answer 头部过程话术剥离（纯函数，可单测）
// ============================================================================

/// 强元话术线索——只收「决策/自我指令/协议元描述」级短语，正常答案正文几乎
/// 不会以它们开头（样本全部来自 build106 实机漏网原文）。刻意不收「用户问」
/// 「结论：」「先说结论」这类可能出现在正经答案里的词，防误杀。
final RegExp _answerMetaTalkCue = RegExp(
  r'(如实告知|如实回答|如实说明|不需要搜索|无需搜索|不用联网|'
  r'停止重试|不要重试|不重试|换参数再试|'
  r'回答[:：]|回复[:：]|'
  r'要简洁|保持简洁|简洁一点|'
  r'结论先行[:：]|先给结论[:：]|'
  r'不要再写|不要写思考|思考过程进答案|'
  r'铁律|宿主熔断|按协议|协议要求|'
  r'answer 里|<answer>|</answer>|'
  r"let me|i should|i need to|i'm going to|"
  r"the user (?:wants|asked|is asking|said)|answer content\s*[:]|"
  r"then (?:explain|offer|provide|summarize)\b"
    r')',
  caseSensitive: false,
);

/// 判定单行是否「过程话术行」：命中强元话术线索，且行内没有答案结构
/// （代码围栏 / 标题 / 列表行）。命中即整行剥回 thinking。
bool _isMetaTalkLine(String line) {
  final t = line.trim();
  if (t.isEmpty) return false;
  if (_monologueHeadingLine.hasMatch(t)) return false;
  if (_monologueListLine.hasMatch(t)) return false;
  if (t.contains('```')) return false;
  return _answerMetaTalkCue.allMatches(t).isNotEmpty;
}

/// 剥掉 answer 开头连续的过程话术行（最多 8 行），返回 `(clean, stripped)`。
///
/// 背景（L1 三连样本）：弱模型把「我应该如实告知 / 要简洁：结论先行 /
/// 不要再写思考过程进答案」这类 deliberation 写进 <answer> 或裸文本，
/// 提示词防不住 → 宿主在落库/展示前兜底。防误杀三闸门：
/// ①只剥开头连续行（中后部正文不碰）；②行内无答案结构才剥（教程/列表/代码
/// 答案整段放行，F2 教训）；③剥后必须剩内容（纯元话术答案原样保留，交给
/// O9 零产出守卫处理）。不设比例护栏：实机样本普遍是「大段话术 + 短结论」，
/// 比例护栏反而放过最严重的泄漏；误剥代价低（剥掉的行仍可在思考面板看到）。
(String, String) stripLeadingMetaTalk(String answer) {
  final text = answer.trim();
  if (text.isEmpty) return (text, '');
  final lines = text.split('\n');
  final stripped = <String>[];
  var idx = 0;
  while (idx < lines.length && idx < 8) {
    final line = lines[idx];
    if (line.trim().isEmpty) {
      idx++;
      continue;
    }
    final rest = lines.skip(idx + 1).join('\n').trim();
    if (rest.isEmpty) break; // 闸门③
    if (!_isMetaTalkLine(line)) break;
    stripped.add(line.trim());
    idx++;
  }
  final clean = lines.skip(idx).join('\n').trim();
  if (stripped.isEmpty || clean.isEmpty) {
    return (text, ''); // 闸门③
  }
  return (clean, stripped.join('\n'));
}

// ============================================================================
// O1（build95）：ask_user「同一信息缺口」跨轮指纹判定
// ============================================================================

final RegExp _askFpNoise = RegExp(r'[\s\p{P}\p{S}]+', unicode: true);

/// ask_user 问题指纹归一化：小写、去全部空白/标点/符号。
String normalizeAskUserQuestion(String q) =>
    q.toLowerCase().replaceAll(_askFpNoise, '');

/// 两个已归一化指纹是否指向同一信息缺口：
/// 相等 / 互相包含（较短者 ≥6 字符）/ 字符 bigram Jaccard ≥ 0.5。
bool isSameAskUserGap(String fpA, String fpB) {
  if (fpA.isEmpty || fpB.isEmpty) return false;
  if (fpA == fpB) return true;
  final shorter = fpA.length <= fpB.length ? fpA : fpB;
  final longer = fpA.length <= fpB.length ? fpB : fpA;
  if (shorter.length >= 6 && longer.contains(shorter)) return true;
  Set<String> bigrams(String s) {
    final r = <String>{};
    for (var i = 0; i + 1 < s.length; i++) {
      r.add(s.substring(i, i + 2));
    }
    if (s.length == 1) r.add(s);
    return r;
  }

  final a = bigrams(fpA);
  final b = bigrams(fpB);
  if (a.isEmpty || b.isEmpty) return false;
  final inter = a.where(b.contains).length;
  final union = a.length + b.length - inter;
  return union > 0 && inter / union >= 0.5;
}
