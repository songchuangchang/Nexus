/// build146（prompt cache ①/②）：**注入块的前缀稳定排序**——纯函数、零 Flutter 依赖、可单测。
///
/// 立项依据（第三方审计 + 本次逐条读码复核）：
/// Anthropic 的 prompt caching 是**逐字节前缀匹配**（官方 Messages 文档；AWS Bedrock
/// `model-parameters-anthropic-claude-messages-prompt-caching.html` 同口径），
/// 缓存命中的充要条件是「本次请求的开头一段与已缓存那段**完全一样**」。
/// 而本 App 的注入顺序是**按"离用户消息越近权重越高"排的，不是按变化频率排的**
/// （见 chat_screen_message.dart:398-400 与 chat_screen_react.dart:387-389 的原注释），
/// 结果是把**每轮都变**的知识库检索块放在了**每几轮才变**的助手人设之前：
/// chat_screen_message.dart:394（kb）→ 396 之后才是 400（systemPrompt）/ 411（助手人设）。
/// 于是从 kb 块开始往后整段前缀每轮都不同 ⇒ 自动前缀缓存**永远命中不了**，
/// 手工断点也打不到任何有意义的位置（断点只能打在变化段之前，那段就只剩协议本身）。
///
/// 本文件只做一件事：**把"变得最少的"放到最前面**，并保证这件事是可证明的：
///  ① 确定性：同一批输入，无论以什么迭代顺序进来（Map/Set 顺序、await 完成顺序、
///     重试路径），产出的字节序列**完全一致**（见 [planPromptPrefix] 的全序比较器）；
///  ② 跨轮稳定：只要某几块的内容没变，它们在输出里的**相对位置与前缀字节**也不变，
///     所以第 N+1 轮与第 N 轮的公共前缀只会**变长**，不会因为插入而**断裂**；
///  ③ 角色契约：只改**顺序**，不改**身份**——进来的每条块带着自己的 [PromptBlockKind]
///     原样出去，system 仍是 system，user 仍是 user。本文件不构造消息、不合并文本、
///     不删内容（除了 trim 后为空的块），因此不可能把一条工具结果排进系统段。
///
/// **明确不承诺的事**（别把这个函数当缓存开关）：
///  - 它**不保证任何厂商真的缓存**。DeepSeek / 通义这类"自动隐式前缀缓存"是否命中
///    还取决于上游的最小长度与存活窗口；Anthropic 还必须**显式**打 `cache_control`
///    断点（见 services/protocol/anthropic_protocol.dart 的
///    [buildCachedAnthropicSystem]，那里用全项目唯一口径 TokenEstimator 做长度门槛）。
///    本函数只把**命中可能性**从"结构上为 0"变成"结构上可行"。
///  - 它**不保证语义等价**。重排会改变模型读到的顺序，而仓库现有提示词是按
///    "人设贴近用户消息"写的（chat_screen_message.dart:398-400）。档位表把这一条
///    让位给缓存稳定性，理由与风险见 [PromptBlockKind.assistantPersona] 的注释。
///  - 它**不算 token、不读偏好、不碰 IO**，因此也不判断"该不该注入某块"——
///    那些仍是各调用点的事。
library;

/// 变化频率档位。**只有三档**，且判据是"什么事会让它变"，不是"它属于哪类内容"。
enum PromptTier {
  /// 会话期间不变：只有用户去改配置/换绑定才会变（用户 system prompt、助手人设、
  /// ReAct 协议骨架、插件目录与档位、深研档协议）。
  conversationStable,

  /// 慢变：用户动作或后台写入才会变，同一会话内**可能**跨轮变一次
  /// （长期记忆块、跨对话摘要、历史压缩摘要）。
  userActionDependent,

  /// 每轮都变：本轮问题决定的内容（知识库检索、联网搜索结果、附件/OCR 文本、
  /// 待办/反问状态、时间戳）。**必须排在最后**。
  perTurnVolatile,
}

/// 一个注入块的身份。rank 值刻意留了间隔（10/20/30…），后续插入新块不必重编号。
enum PromptBlockKind {
  /// 用户自定义 system prompt（连接级）。
  /// 现状：chat_screen_message.dart:400-406 排在**最后**；但同一轮里
  /// chat_screen_message.dart:509-517 会把它从 stablePrefix 里**剥掉**，
  /// 而 api_service.dart:497-499 又在 payload 开头补回来 ⇒ **实际上线时它本来就在
  /// 第 0 位**。所以把它归到 rank 10 与线上现状一致，不是新的行为改变。
  userSystemPrompt,

  /// 会话绑定的自定义助手人设。现状：chat_screen_message.dart:411、
  /// chat_screen_react.dart:391（**排在 kb 块之后**，是本文件要修的主要错位）。
  /// 让位说明：它的 rank(20) 在协议块之前、kb 块之前，等于把"人设"从"最贴近用户"
  /// 挪到"最靠前"。Anthropic/OpenAI 对 system 段的权重并不随段内位置显著衰减
  /// （真正衰减的是超长上下文里的中间段），而挪动的收益是：助手人设从"每轮都被
  /// kb 块带着失效"变成"永久可缓存"。回归风险与验证方式见批次报告。
  assistantPersona,

  /// ReAct 协议正文（`buildReactSystemPromptFromPlugins`，api_service.dart:37-208）。
  /// 纯函数，输入只有启用插件集合 + hint 配置 ⇒ 与用户模型输出无关，稳定。
  reactProtocol,

  /// 插件目录层/档位提示（chat_screen.dart:1107 `_buildNormalChatPluginHint`、
  /// chat_screen_react.dart:143 `pluginHintBlock`）。启用的插件集合变了才变。
  pluginCatalog,

  /// 深度研究档协议段（chat_screen_react.dart:192 `kDeepResearchProtocol`）。
  /// 跟着"思考强度=1.0"这个会话级开关走 ⇒ 会话内不变。
  deepResearchProtocol,

  /// 全局/项目长期记忆块（memory_block_builder.dart:17）。
  /// **不是**每轮变：只有模型落了 `<memory_write>` 或用户手动存/删记忆才变。
  /// 但它是 ReAct 路径里唯一的"中途会自己改写"的稳定块
  /// （chat_screen_react.dart:365-376 的 memDirty 重建），所以必须和协议段
  /// **分成两块**，否则一次记忆写入会把整段协议 + 目录一起刷出缓存。
  longTermMemory,

  /// 跨对话摘要（storage.getRecentSummaries(3)，
  /// chat_screen_message.dart:356-380 / chat_screen_react.dart:149-168）。
  /// 变化时机是"**别的**会话被摘要了"或本会话被排除集变化 ⇒ 与本轮问题无关，
  /// 比记忆块更低频（一轮对话里通常不动）。
  crossChatSummary,

  /// 历史压缩摘要段（context_budget_service.dart:174-182 造的
  /// `[Context summary]` system 消息）。自动压缩跑过一次就会变，长会话里比
  /// 知识库块低频、比人设高频 ⇒ 卡在稳定段末尾、易变段之前。
  contextSummary,

  /// 知识库 RAG 检索块（chat_screen_message.dart:1615-1745 → rag_service.dart:315
  /// `buildContextBlock`）。**本轮问题向量决定内容** ⇒ 每轮都变，是审计点名的
  /// 头号前缀破坏者。
  knowledgeRetrieval,

  /// 本轮联网搜索结果（chat_screen_message.dart:257-303，现拼进 user 消息
  /// chat_screen_message.dart:414-421）。
  webSearchResult,

  /// 本轮附件正文 / 本机 OCR 文本（api_service.dart:504-532）。
  attachmentText,

  /// 待办清单与反问/约束状态（ReAct 每轮回灌：chat_screen_react.dart:789/924/958/
  /// 1768/1839/2403，以及 builtin_plugins.dart:1067 的「当前待办清单」）。
  /// 随进度变化 ⇒ 每轮变。
  todoAskState,

  /// 时间戳类内容。**当前请求路径里没有**（全仓唯一的日期开关
  /// chat_appearance_settings_screen.dart:135 `injectMetadata` 只有 provider
  /// 存值、chat_skin_provider.dart:91 有 getter，**没有任何消费点**）。
  /// 这里预留 rank 240 并归到易变档末尾，是为了将来接上时不可能把前缀打挂。
  timestamp,

  /// 调用方归类不了的块。**必须存在**：漏分类的块要落到易变段末尾，
  /// 而不是靠异常把请求打挂，也不能挤进稳定段。
  unknown;

  /// 排序主键。数值即"变得最少 → 变得最多"的次序，间隔留白见枚举头注。
  int get rank => switch (this) {
        PromptBlockKind.userSystemPrompt => 10,
        PromptBlockKind.assistantPersona => 20,
        PromptBlockKind.reactProtocol => 30,
        PromptBlockKind.pluginCatalog => 40,
        PromptBlockKind.deepResearchProtocol => 50,
        PromptBlockKind.longTermMemory => 100,
        PromptBlockKind.crossChatSummary => 110,
        PromptBlockKind.contextSummary => 120,
        PromptBlockKind.knowledgeRetrieval => 200,
        PromptBlockKind.webSearchResult => 210,
        PromptBlockKind.attachmentText => 220,
        PromptBlockKind.todoAskState => 230,
        PromptBlockKind.timestamp => 240,
        PromptBlockKind.unknown => 900,
      };

  PromptTier get tier => switch (this) {
        PromptBlockKind.userSystemPrompt ||
        PromptBlockKind.assistantPersona ||
        PromptBlockKind.reactProtocol ||
        PromptBlockKind.pluginCatalog ||
        PromptBlockKind.deepResearchProtocol =>
          PromptTier.conversationStable,
        PromptBlockKind.longTermMemory ||
        PromptBlockKind.crossChatSummary ||
        PromptBlockKind.contextSummary =>
          PromptTier.userActionDependent,
        PromptBlockKind.knowledgeRetrieval ||
        PromptBlockKind.webSearchResult ||
        PromptBlockKind.attachmentText ||
        PromptBlockKind.todoAskState ||
        PromptBlockKind.timestamp ||
        PromptBlockKind.unknown =>
          PromptTier.perTurnVolatile,
      };

  /// 该档是否"每轮都可能变"（= 缓存断点**不允许**落在它身上）。
  bool get isVolatile => tier == PromptTier.perTurnVolatile;
}

/// 一个待注入的块。`name` 只用于**同档内的确定性 tie-break**（如 kb id、插件 id、
/// 附件文件名），不进请求体；不传就是空串。
class PromptBlock {
  final PromptBlockKind kind;

  /// 进请求体的正文（本函数不改写它，只决定它站在哪）。
  final String text;
  final String name;

  const PromptBlock(this.kind, {required this.text, this.name = ''});

  bool get isVolatile => kind.isVolatile;

  @override
  String toString() => 'PromptBlock(${kind.name}, name=$name, ${text.length}ch)';
}

/// 排序结果：一个有序块列表 + 断点所需的两个派生量。
class PromptPrefixPlan {
  /// 已按 [planPromptPrefix] 的规则排好序的块（不可变视图）。
  final List<PromptBlock> blocks;

  const PromptPrefixPlan(this.blocks);

  /// 从头部起的**连续稳定段**（缓存可覆盖的最大跨度）。
  ///
  /// 为什么是"连续前缀"而不是"所有稳定块"：稳定段之后一旦出现易变块，
  /// 再往后的任何块都不可能在缓存里被读到（前缀匹配是位置的函数）。
  List<PromptBlock> get stableBlocks {
    final out = <PromptBlock>[];
    for (final b in blocks) {
      if (b.isVolatile) break;
      out.add(b);
    }
    return out;
  }

  List<PromptBlock> get volatileBlocks => blocks.length == stableBlocks.length
      ? const []
      : blocks.sublist(stableBlocks.length);

  /// **Anthropic 断点块数**（0 = 没有稳定段）。
  ///
  /// 注意：**别把它当参数传给协议层**。断点位置要按内容认（[stableTexts]），
  /// 按"第几块"认会在三个地方失真：协议层会丢掉空白块、`api_service` 会在开头
  /// 补回 config.systemPrompt、上下文预算会在发送前丢掉若干条稳定前缀。
  /// 留这个量是因为"稳定段有几块"本身是测试与日志要问的问题。
  int get stableBlockCount => stableBlocks.length;

  /// 稳定段的**内容集合** —— 这才是交给协议层认断点的东西。
  ///
  /// 按内容认而不是按下标认，天生活该对上面那三处失真免疫：无论中间谁多一块少一块，
  /// 「这一块是不是不变的那几块之一」都有唯一答案。
  /// 万一某条易变块的文本与某条稳定块**逐字相同**，它被算进稳定段也无害 ——
  /// 逐字相同意味着缓存它必然命中（内容变了才会 miss，而内容变了对称地也变）。
  Set<String> get stableTexts => {for (final b in stableBlocks) b.text};

  /// 按给定分隔符拼成一段文本（通常就是一个 system 块）。
  ///
  /// 注意：把多块**拼成一个字符串**会牺牲"块级失效边界"——任何一块变了，
  /// 整段就变了。所以只有协议要求单字符串（OpenAI 兼容路径的自动缓存）时用它；
  /// Anthropic 路径应保留分块 + 断点（见 stableBlockCount）。
  String render({String separator = '\n\n'}) =>
      blocks.map((b) => b.text).join(separator);

  /// 稳定段单独渲染（OpenAI 兼容/DeepSeek 隐式缓存路径可直接用它当 system 内容）。
  String renderStable({String separator = '\n\n'}) =>
      stableBlocks.map((b) => b.text).join(separator);

  /// **规范序列化**：把档位/名字/正文都编进去，供测试钉"字节稳定"。
  /// 不进请求体，只是同一个 plan 的指纹。
  String cacheKey() => blocks
      .map((b) => '${b.kind.rank}\u0000${b.name}\u0000${b.text}')
      .join('\u0001');
}

/// 全序比较器：rank → name → text，逐级 code-unit 字典序。
///
/// 为什么必须**全**序：Dart 的 `List.sort` 不保证稳定排序，同 rank 的两块
/// 顺序会随输入顺序变化 ⇒ 字节前缀断裂（正是本文件要修的东西）。
/// 用 text 兜底后，任何两块都有确定的先后；两块 rank 与 name 与 text 全等时
/// 它们本来就无法区分，交换与否产出的字节完全一致。
int _compareBlocks(PromptBlock a, PromptBlock b) {
  final byRank = a.kind.rank.compareTo(b.kind.rank);
  if (byRank != 0) return byRank;
  final byName = a.name.compareTo(b.name);
  if (byName != 0) return byName;
  // String.compareTo 在 Dart 里就是 UTF-16 code unit 逐位比较，与 locale 无关，
  // 因此**不会**因为设备语言环境不同而给出不同顺序（这是字节稳定的前提）。
  return a.text.compareTo(b.text);
}

/// 主入口：把这一轮想注入的所有块排成**字节稳定的前缀**。
///
/// 用法（迁移后的调用点应长这样，顺序不再由代码书写顺序决定）：
/// ```dart
/// final plan = planPromptPrefix([
///   PromptBlock(PromptBlockKind.userSystemPrompt, text: cfg.systemPrompt),
///   PromptBlock(PromptBlockKind.reactProtocol, text: reactProtocolPrompt),
///   PromptBlock(PromptBlockKind.pluginCatalog, text: pluginHintBlock),
///   PromptBlock(PromptBlockKind.longTermMemory, text: memBlockText),
///   PromptBlock(PromptBlockKind.crossChatSummary, text: memoryBlock),
///   PromptBlock(PromptBlockKind.assistantPersona, text: persona),
///   PromptBlock(PromptBlockKind.knowledgeRetrieval, text: kbBlock),
/// ]);
/// final stableCount = plan.stableBlockCount; // → 传给 Anthropic 断点
/// ```
///
/// 保证：
///  - 输入是 `Iterable`，**不要求**调用方给什么顺序；输出只取决于输入**多重集**。
///  - 空/纯空白 text 的块被丢弃（等价于现有各处 `if (x.isNotEmpty) add(...)`
///    的门控，但集中在一处，不再靠调用点各自记得判空）。
///  - 不修改入参列表。
PromptPrefixPlan planPromptPrefix(Iterable<PromptBlock> blocks) {
  final kept = blocks.where((b) => b.text.trim().isNotEmpty).toList();
  kept.sort(_compareBlocks);
  return PromptPrefixPlan(List<PromptBlock>.unmodifiable(kept));
}

/// 便捷量：一批块里稳定段的块数（等价 `planPromptPrefix(b).stableBlockCount`，
/// 但调用点已经排过序、只想再问一次断点位置时用）。
int stablePrefixBlockCount(Iterable<PromptBlock> ordered) {
  var n = 0;
  for (final b in ordered) {
    if (b.isVolatile) break;
    n++;
  }
  return n;
}

// ─────────────────────────────────────────────────────────────────────────────
// build153：**按 model 查表的"最小可缓存 token 数"**（纯函数、零 Flutter 依赖，
// 与本文件的分档同源；协议层 anthropic_protocol.dart 消费它）。
//
// 出处与核实状态（2026-09-25 在本环境现查，先说结论：**官方口径＝未查到**）：
//  - https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching
//    301 → https://platform.claude.com/docs/en/docs/build-with-claude/prompt-caching，
//    在本环境再 307 → `www.anthropic.com/app-unavailable-in-region`（出口区域被挡），
//    官方原文读不到 ⇒「哪些模型对应哪个最小值」「ephemeral 是否有 1h 档、ttl 字段
//    官方怎么写」**本次未能对照官方文档复核**（pricing 页同域名、同被挡）。
//  - 表内数值沿用仓库既有登记口径（build146 写入 anthropic_protocol.dart:120-122 的
//    原注释，当时声称取自官方文档）：「**最小可缓存长度**：Sonnet / Opus 档 1024
//    token，Haiku 档 2048 token」。
//  - 第三方旁证（**不是官方**，只用于证明「官方最小值确实按模型分档、已知区间到
//    4096 为止」）：https://hidekazu-konishi.com/entry/llm_api_parameter_compatibility_reference.html
//    原文 "Model-dependent minimum prefix (from 512 to 4,096 tokens depending on
//    the model)"；同页并列 `ttl`: "5m" (default) or "1h"。
//
// **1h TTL 的处置**：`ttl` 字段与「5 分钟 / 1 小时两档不同写入价」只拿到第三方
// 转述、没拿到官方出处 ⇒ 本次**不在请求体里新增 `ttl` 字段**（不编字段名），
// 断点继续只发 `{type:'ephemeral'}`（即缺省 5 分钟档）；待官方文档可达后再立项。
// ─────────────────────────────────────────────────────────────────────────────

/// 表内值：Sonnet / Opus 档。出处见文件内 build153 段注释（build146 既有口径，
/// 本环境未复核到官方原文）。
const int kAnthropicMinCacheTokensSonnetOpus = 1024;

/// 表内值：Haiku 档。出处同上。
const int kAnthropicMinCacheTokensHaiku = 2048;

/// **表外模型的保守值** = 4096，取上面第三方区间（512–4096）的上界。
/// 方向是「宁可不缓存也不误打点」：门槛偏高只损失一次缓存机会（请求体回落
/// 字符串形状、原价计费，零风险）；门槛偏低则可能给上游认为不够长的跨度发
/// 无效断点。表外模型（含将来新模型家族）一律走这里，直到官方清单核实。
const int kAnthropicMinCacheTokensUnknown = 4096;

/// 纯函数：模型名（大小写不敏感、子串匹配）→ 该模型的最小可缓存 token 数。
///
///  - 含 `haiku` → 2048；含 `sonnet` / `opus` → 1024（表内，build146 口径）；
///  - 非空但都不含 ⇒ [kAnthropicMinCacheTokensUnknown]（**表外走保守值**）；
///  - 空串 ⇒ [kAnthropicMinCacheTokensSonnetOpus]：维持 build146 回归锁的
///    「未上报 model」旧口径（真实接线 `buildAnthropicRequest` 一律传 model，
///    该分支只出现在旧测试与未接线调用点上）。
int anthropicMinCacheTokensFor(String model) {
  final m = model.toLowerCase();
  if (m.isEmpty) return kAnthropicMinCacheTokensSonnetOpus;
  if (m.contains('haiku')) return kAnthropicMinCacheTokensHaiku;
  if (m.contains('sonnet') || m.contains('opus')) {
    return kAnthropicMinCacheTokensSonnetOpus;
  }
  return kAnthropicMinCacheTokensUnknown;
}
