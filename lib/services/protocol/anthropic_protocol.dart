import 'dart:convert';

import '../../models/api_config.dart';
import '../../models/chat_message.dart';
import '../../utils/prompt_prefix.dart';
import '../token_estimator.dart';

/// build138 · A 批（交接单 §7.2 之 A）：真协议适配器 —— 本文件是**纯函数协议层**。
///
/// 立项依据：用户要「支持更多的协议，就不止 open AI 这种」。改动前**所有厂商**
/// 都被塞进同一套 OpenAI 形状的请求（`ApiConfig.chatEndpoint` 永远拼
/// `/chat/completions`，响应永远读 `choices[].message/content`）。
/// 内置 `claude` 行的地址是 `https://api.anthropic.com/v1` ——
/// 本次联网核查中**每一个**能打开的官方/云商页面（AWS Bedrock 的
/// model-parameters-anthropic-claude-messages 两页、Azure AI Foundry 的
/// use-foundry-models-claude、阿里云百炼的 Anthropic 兼容实现）写的都是
/// `POST /v1/messages`，**没有一处**出现 Anthropic 的 `/chat/completions`。
/// 也就是说这不是"少传一个参数"，而是**端点、鉴权头、消息形状、流式事件、
/// usage 字段名**五件事全都不同 —— 靠给 OpenAI 请求打补丁修不好。
///
/// 三条刻意划出的边界（都写进 A 批报告，不是遗漏）：
///  ① 判定只看 `templateId`：自建中转 / 私有部署（custom）一律继续走 OpenAI 兼容。
///     按 baseUrl 猜协议会把「地址里带 anthropic 但其实转发成 OpenAI」的中转站打挂。
///  ② **Gemini 原生适配器本批不做**：Google 全部域名本次不可达
///     （ai.google.dev / cloud.google.com / generativelanguage.googleapis.com
///     均 fetch failed），响应体与流式增量语义（**是累积还是增量**）拿不到官方原文，
///     而两轮独立核查都确认「Azure Foundry 与 AWS Bedrock 都不托管 Gemini」
///     ⇒ 没有可引用的第三方镜像。凭记忆写这套解析＝把幻觉固化进请求路径
///     （交接单 §7.2 的硬约束）。Gemini 现有 `/v1beta/openai` 兼容端点可用且已验证，
///     保持原样。判定表里预留了 `geminiNative` 枚举值但**没有任何调用点**，
///     拿到官方 schema 后只需填两个函数即可接上。
///  ③ 不发 Anthropic 原生 `tools`：本 App 的 ReAct 工具走 `<action>` XML 文本，
///     不依赖 function calling；OpenAI 的 `tools[]` 与 Anthropic 的
///     `tool_use`/`tool_result` 块是两套东西，翻错的代价是**静默丢工具调用**
///     （同型事故已发生 5 次），所以宁可不开，并在代码里写明原因。

/// 会话协议。判定见 [resolveChatProtocol]。
enum ChatProtocol { openaiCompat, anthropicMessages, geminiNative }

/// 内置厂商模板 id → 原生协议。**只有这张表里的行会被改道。**
const Map<String, ChatProtocol> kNativeProtocols = {
  'claude': ChatProtocol.anthropicMessages,
  // Anthropic 的 API 厂商名；远程模板可能用这个 id 下发
  'anthropic': ChatProtocol.anthropicMessages,
};

/// 判定口径：命中 [kNativeProtocols] 才换协议，其余（含 `custom`/中转）＝ OpenAI 兼容。
///
/// 不看 baseUrl、不看模型名前缀 —— 那两件事用户都能自己改，
/// 而「猜错协议」的代价是整条连接不可用。
ChatProtocol resolveChatProtocol(ApiConfig config) =>
    kNativeProtocols[config.templateId.trim()] ?? ChatProtocol.openaiCompat;

/// `anthropic-version` 是**必填**头（缺了官方直接 400）。
/// 这是官方与两家云商镜像逐字一致的**字面量**，不是日期计算结果。
const String kAnthropicVersion = '2023-06-01';

/// Messages 端点归一：地址里已带版本段就不再补 `/v1`
/// （与 `ApiConfig.chatEndpoint` 同一口径；Azure/Bedrock 的挂载点也走这条）。
String anthropicMessagesEndpoint(String baseUrl) {
  var url = baseUrl.trim();
  while (url.endsWith('/')) {
    url = url.substring(0, url.length - 1);
  }
  final lower = url.toLowerCase();
  final versioned = lower.endsWith('/v1') ||
      lower.endsWith('/v1/messages') ||
      lower.endsWith('/anthropic') ||
      lower.endsWith('/messages');
  if (lower.endsWith('/messages')) return url;
  return versioned ? '$url/messages' : '$url/v1/messages';
}

/// 请求头：`x-api-key` + `anthropic-version`。
///
/// 官方页写的是「x-api-key 或 Authorization 二选一」，但本次**逐字验证过**的
/// 只有 `x-api-key` ⇒ 只发它（少一处可能写歪的地方）。
Map<String, String> anthropicHeaders(ApiConfig config) => {
      'Content-Type': 'application/json',
      'anthropic-version': kAnthropicVersion,
      if (config.apiKey.trim().isNotEmpty) 'x-api-key': config.apiKey.trim(),
    };

/// 一次解析的产出：文本 / 思考 / usage / stopReason / 流结束 / 流内错误。
class AnthropicDelta {
  const AnthropicDelta({
    this.text = '',
    this.thinking = '',
    this.usage,
    this.stopReason,
    this.done = false,
    this.error,
  });

  final String text;
  final String thinking;

  /// usage 只在这一条非空时参与归账。
  ///
  /// ⚠️ Anthropic 把 usage **拆在两处**：`message_start` 给 input_tokens，
  /// `message_delta` 才给 output_tokens 与两个缓存计数 ⇒ 两处都必须读，
  /// 只读一处会把输出 token 或缓存命中记成 0（G65 刚修过的那类口径错）。
  final TokenUsage? usage;
  final String? stopReason;
  final bool done;
  final String? error;

  bool get isEmpty =>
      text.isEmpty && thinking.isEmpty && usage == null && stopReason == null;
}

/// build146（prompt cache ③）：**Anthropic 显式缓存断点**。
///
/// 与 OpenAI 兼容路径的根本差别：DeepSeek/通义那类是**隐式自动前缀缓存**
/// （上游自己判，客户端只能把不变的东西放前面 ⇒ 见 utils/prompt_prefix.dart），
/// Anthropic 是**显式断点**：不带 `cache_control: {type:'ephemeral'}` 就完全不建缓存，
/// 带了才能拿到「读取 90% 折扣 / 写入 125% 加价」。官方 Messages 文档与
/// AWS Bedrock `model-parameters-anthropic-claude-messages-prompt-caching.html` 同口径。
///
/// **最小可缓存长度（build153 起按 model 分档查表）**：真身是
/// utils/prompt_prefix.dart 的 [anthropicMinCacheTokensFor] —— Sonnet/Opus 档
/// 1024 token、Haiku 档 2048 token（build146 既有口径），**表外模型走 4096 保守值**
/// （宁可不缓存也不误打点）。官方 prompt-caching 文档 2026-09-25 在本环境
/// 301/307 到 app-unavailable-in-region、未复核到原文 ⇒ 结论与出处的完整记录
/// 写在 prompt_prefix.dart 的 build153 段注释。
/// 短于门槛的跨度上游**不会**建缓存条目。这里只在**稳定段**上量这个长度。
///
/// **TTL 档位**：官方只核实到 `cache_control:{type:'ephemeral'}`（缺省 5 分钟档）；
/// 1 小时档的 `ttl` 字段只拿到第三方转述、无官方出处 ⇒ 本文件**不发** `ttl`，
/// 见 [kAnthropicEphemeralBreakpoint] 注释。
///
/// **为什么"断点打在易变块上"比"根本没有断点"更糟**（这是本函数存在的理由）：
///  ① 断点语义是「缓存从这里往**前**的一切」。打在易变块上 ⇒ 被缓存的跨度每轮
///     字节都在变 ⇒ 每一次请求都是一次**新的写入**（125% 加价），**零次读取**（90% 折扣）。
///     净效果是稳定地多付 25%，而收益恒为 0；不打断点反而是原价。
///  ② 更糟的是它还会**伪装成已优化**：usage 里 `cache_creation_input_tokens` 每轮都非零，
///     面板上看着"缓存在工作"，实际命中率永远是 0（本项目第 5 次同型事故就是
///     「指标非零但语义为空」）。
///  ③ 所以长度不够时的正确动作是**一个标记都不发**，让 `system` 回到今天这种
///     纯字符串形状（逐字节与改动前一致），而不是为了"凑长度"把断点往后挪到
///     易变块上、也不是把稳定段截断到某个奇怪字符数。
///
/// 长度口径：用全项目**唯一**的估算实现 [TokenEstimator.text]（见
/// services/token_estimator.dart 头注；utils 层不得再造第二个估算器），
/// 对稳定段的**每一块分别估算再求和**。求和比"拼接后一次估算"略保守
/// （少算了分隔符的几个 token），保守方向是对的：宁可漏打一次断点，
/// 也不要拿一个上游认为不够长的跨度去付写入费。
///
/// build146 回归锁常量：等价于「未上报 model」时的旧写死口径（Sonnet/Opus 档）。
/// 新代码请改用 [anthropicMinCacheTokensFor]（见上方分档说明）。
const int kAnthropicMinCacheTokens = kAnthropicMinCacheTokensSonnetOpus;

/// `cache_control` 断点值。官方只核实到 `ephemeral` 这一种，写成常量避免各调用点手打。
/// build153：1h 档的 `ttl` 字段没拿到官方出处（见 prompt_prefix.dart build153 段），
/// 因此**刻意不加** `ttl`，即缺省 5 分钟档。
const Map<String, dynamic> kAnthropicEphemeralBreakpoint = {
  'type': 'ephemeral',
};

/// 把 system 文本块编成 Anthropic 的 `system` **数组**形状，并在
/// **稳定前缀的最后一条**上打唯一的缓存断点。
///
/// 返回 `null` ＝ 不打断点。调用方必须回落到今天的**字符串**形状
/// （`system: parts.join('\n\n')`），这样"未接线"与"接线但不够长"两种情况
/// 产出的请求体**逐字节相同**，回归面为零。
///
/// ## 为什么断点位置由「稳定文本集合」推出来，而不是由「前 N 块」这个数给出
///
/// 上一版收的是 `int stablePartCount`，第 10 轮审查指出它有三条会让断点
/// **整体前移落到易变块上**的路径，而那比"没有断点"更糟（每轮 125% 写入、
/// 零次读取，而 `cache_creation_input_tokens` 非零看起来像缓存在工作）：
///  ① 本函数会丢掉 `trim()` 为空的块 ⇒ `parts` 可能比调用方计数时短；
///  ② `ApiService._buildMessagesPayload` 会在 system 段**开头补回** config.systemPrompt
///     ⇒ 调用点数出来的块数与这里看到的块数天生可能差一；
///  ③ 上下文预算（`ContextBudgetService`）会在发送前**丢掉若干条**稳定前缀
///     ⇒ 数出来的 N 到了线上已经对不上任何一块。
/// 集合口径对这三条都免疫：稳定与否**跟着内容走**，不跟着位置走。
/// 夹在头部的连续一段（leading run）才是可缓存跨度 —— 一旦碰上不属于集合的
/// 那块就停，所以**永远不会**把易变块圈进缓存；顺序被调用方弄乱了也只会
/// 得到"可缓存跨度为 0 ⇒ 不打断点"，得到一个保守结果而不是一个假象。
///
/// [parts] 必须**已按变化频率升序排好**（[planPromptPrefix] 的产物）。
///
/// [model]（build153）：本次请求实际使用的模型名，用于查
/// [anthropicMinCacheTokensFor] 的分档门槛；不传＝沿用 build146 口径（1024）。
List<Map<String, dynamic>>? buildCachedAnthropicSystem(
  List<String> parts, {
  Set<String> stableTexts = const {},
  String model = '',
}) {
  if (parts.isEmpty || stableTexts.isEmpty) return null;
  var run = 0;
  while (run < parts.length && stableTexts.contains(parts[run])) {
    run++;
  }
  if (run == 0) return null;
  var stableTokens = 0;
  for (var i = 0; i < run; i++) {
    stableTokens += TokenEstimator.text(parts[i]);
  }
  if (stableTokens < anthropicMinCacheTokensFor(model)) return null;
  return <Map<String, dynamic>>[
    for (var i = 0; i < parts.length; i++)
      <String, dynamic>{
        'type': 'text',
        'text': parts[i],
        if (i == run - 1) 'cache_control': kAnthropicEphemeralBreakpoint,
      },
  ];
}

/// [planPromptPrefix] 产物的**一行接线**：把排好序的块列表直接变成
/// 带断点的 `system` 数组（长度不够 / 没有稳定段 ⇒ null，调用方回落字符串）。
/// 之所以放这儿而不是 prompt_prefix.dart：稳定性分档是**协议无关**的，
/// 而 `cache_control` 是 Anthropic 专属，两边不能互相污染。
List<Map<String, dynamic>>? buildCachedAnthropicSystemForPlan(
        PromptPrefixPlan plan) =>
    buildCachedAnthropicSystem(
      plan.blocks.map((b) => b.text).toList(),
      stableTexts: plan.stableTexts,
    );

/// OpenAI 形状的 messages（`ApiService._buildMessagesPayload` 的产物）
/// → Anthropic 请求体。
///
/// 四处必须转对，逐条有测试钉住：
///  ① `role:'system'` 在 messages 数组里**不合法**（官方只收 user/assistant）
///     ⇒ 摘出来按顺序拼进顶层 `system`；
///  ② 图片是 `{'type':'image','source':{'type':'base64','media_type':…,'data':…}}`
///     —— 字段名 `media_type` 是下划线，且没有 `image_url` 这个 type；
///  ③ `max_tokens` **必填**（OpenAI 侧可选），缺了直接 400；
///  ④ 官方要求 user/assistant 严格交替 ⇒ 连续同角色合并，
///     并保证首条是 user（历史压缩/重试回写会造出 assistant 开头）；
///  ⑤ build146：`system` 默认仍是**单个字符串**（与改动前逐字节一致）；只有调用点
///     显式报了"哪些 system 块是本会话不变的"（[stableSystemTexts]，来自
///     utils/prompt_prefix.dart 的 `PromptPrefixPlan.stableTexts`）并且那段头部连续
///     跨度长度过 [kAnthropicMinCacheTokens] 时，才改成**块数组 + 一个 cache_control 断点**。
/// 采样参数沿用 [ApiConfig.samplingParams] 的 G50 口径：非默认才发。
Map<String, dynamic> buildAnthropicRequest({
  required ApiConfig config,
  required List<Map<String, dynamic>> openaiMessages,
  required bool stream,
  int? maxTokensOverride,
  Set<String> stableSystemTexts = const {},
}) {
  final systemParts = <String>[];
  final converted = <Map<String, dynamic>>[];

  for (final raw in openaiMessages) {
    final role = (raw['role'] ?? 'user').toString();
    if (role == 'system') {
      final t = _flattenToText(raw['content']);
      if (t.trim().isNotEmpty) systemParts.add(t);
      continue;
    }
    // ReAct 回灌的工具结果在 OpenAI 侧是 role='tool'；Anthropic 语义里
    // 「由用户侧送回的内容」属于 user 轮的内容块 ⇒ 统一并到 user。
    converted.add({
      'role': role == 'assistant' ? 'assistant' : 'user',
      'content': _convertContent(raw['content']),
    });
  }

  // 没报稳定块、或头部连续跨度不够长 ⇒ null ⇒ 回落字符串形状（见函数头注③）。
  // 这里丢过空白块（上面 `t.trim().isNotEmpty`）也不影响断点位置：
  // 稳定与否按**内容**认，不按"第几块"认。
  // build153：门槛按 config.model 查分档表（表外模型走 4096 保守值）。
  final systemForBody = buildCachedAnthropicSystem(systemParts,
      stableTexts: stableSystemTexts, model: config.model);

  return <String, dynamic>{
    'model': config.model,
    'messages': _mergeConsecutiveSameRole(converted),
    'max_tokens': maxTokensOverride ?? config.maxTokens,
    if (systemParts.isNotEmpty)
      'system': systemForBody ?? systemParts.join('\n\n'),
    if (stream) 'stream': true,
    ...config.samplingParams,
  };
}

List<Map<String, dynamic>> _convertContent(Object? content) {
  if (content is! List) {
    return [
      {'type': 'text', 'text': content?.toString() ?? ''}
    ];
  }
  final out = <Map<String, dynamic>>[];
  for (final part in content) {
    if (part is! Map) continue;
    final type = (part['type'] ?? '').toString();
    if (type == 'text') {
      final t = (part['text'] ?? '').toString();
      if (t.isNotEmpty) out.add({'type': 'text', 'text': t});
      continue;
    }
    if (type == 'image_url') {
      final url = part['image_url'] is Map
          ? ((part['image_url'] as Map)['url'] ?? '').toString()
          : '';
      final block = _imageBlockFromDataUrl(url);
      if (block != null) {
        out.add(block);
      } else {
        // 丢块必须留痕：否则症状是「用户发了图、模型说没看到图」而日志零痕迹
        // （本项目第 5 次同型事故正是这个形状）。
        out.add({
          'type': 'text',
          'text': '[图片未能转发到本通道：不是 data: URL，Anthropic 只收 base64]',
        });
      }
      continue;
    }
    out.add({
      'type': 'text',
      'text': '[已跳过不支持的内容块：$type]',
    });
  }
  return out.isEmpty
      ? [
          {'type': 'text', 'text': ''}
        ]
      : out;
}

Map<String, dynamic>? _imageBlockFromDataUrl(String url) {
  if (!url.startsWith('data:')) return null;
  final comma = url.indexOf(',');
  if (comma < 0) return null;
  final meta = url.substring(5, comma); // 形如 image/png;base64
  final semi = meta.indexOf(';');
  final mime = semi < 0 ? meta : meta.substring(0, semi);
  final b64 = url.substring(comma + 1);
  if (mime.isEmpty || b64.isEmpty) return null;
  return <String, dynamic>{
    'type': 'image',
    'source': <String, dynamic>{
      'type': 'base64',
      'media_type': mime,
      'data': b64,
    },
  };
}

List<Map<String, dynamic>> _mergeConsecutiveSameRole(
    List<Map<String, dynamic>> msgs) {
  final out = <Map<String, dynamic>>[];
  for (final m in msgs) {
    if (out.isNotEmpty && out.last['role'] == m['role']) {
      (out.last['content'] as List)
          .addAll((m['content'] as List).cast<Map<String, dynamic>>());
      continue;
    }
    out.add(<String, dynamic>{
      'role': m['role'],
      'content': (m['content'] as List).cast<Map<String, dynamic>>(),
    });
  }
  if (out.isNotEmpty && out.first['role'] == 'assistant') {
    // 补一条空 user 会污染上下文 ⇒ 丢掉开头那条（调用方日志里能看到条数差）
    out.removeAt(0);
  }
  return out;
}

String _flattenToText(Object? content) {
  if (content is! List) return content?.toString() ?? '';
  final b = StringBuffer();
  for (final part in content) {
    if (part is Map && part['type'] == 'text') {
      b.write((part['text'] ?? '').toString());
    }
  }
  return b.toString();
}

/// 解析一行 SSE。
///
/// 判据只用 **data 里的 type**，不去解析 `event:` 头：本次核到的三个实现
/// （官方形状 + Bedrock + 百炼兼容实现）里事件名与 data.type 一致，
/// 只依赖一个来源就少一处会写歪的地方。`event:` 行返回 null 由调用方跳过。
/// 返回 null ＝ 这行没有信息量（空行 / event 头 / ping / 未知类型）。
/// 不是合法 JSON 时**抛 FormatException**，由调用方按「畸形 chunk」计数
/// —— 与 OpenAI 路径同一口径，绝不静默丢。
AnthropicDelta? parseAnthropicSseLine(String line) {
  final trimmed = line.trim();
  if (trimmed.isEmpty || !trimmed.startsWith('data:')) return null;
  final data = trimmed.substring(5).trim();
  if (data.isEmpty || data == '[DONE]') return null;
  final Object? decoded;
  try {
    decoded = json.decode(data);
  } on FormatException {
    rethrow;
  } catch (_) {
    throw const FormatException('anthropic sse: not json');
  }
  if (decoded is! Map) return null;
  final j = Map<String, dynamic>.from(decoded);
  switch (j['type']) {
    case 'message_start':
      final msg = j['message'];
      return AnthropicDelta(usage: anthropicUsage(msg is Map
          ? Map<String, dynamic>.from(msg)
          : const <String, dynamic>{}));
    case 'content_block_start':
      final b = j['content_block'];
      if (b is Map && b['type'] == 'tool_use') {
        // 本通道没发 tools，上游仍调工具 ⇒ 转成可读文本进正文，
        // 用户与模型都看得见（绝不静默丢弃）。
        return AnthropicDelta(text: '\n<tool_use name="${b['name'] ?? ''}" />\n');
      }
      return null;
    case 'content_block_delta':
      final d = j['delta'];
      if (d is! Map) return null;
      switch (d['type']) {
        case 'text_delta':
          return AnthropicDelta(text: (d['text'] ?? '').toString());
        case 'thinking_delta':
          return AnthropicDelta(thinking: (d['thinking'] ?? '').toString());
        default:
          return null; // signature_delta / input_json_delta：本通道用不到
      }
    case 'message_delta':
      final d = j['delta'];
      return AnthropicDelta(
        stopReason:
            d is Map ? ((d['stop_reason'] ?? '').toString()) : null,
        usage: anthropicUsage(j),
      );
    case 'message_stop':
      return const AnthropicDelta(done: true);
    case 'error':
      final e = j['error'];
      return AnthropicDelta(
          error: e is Map
              ? '${e['type'] ?? 'error'}: ${e['message'] ?? ''}'
              : 'Anthropic 流内错误');
    default:
      return null; // ping 等
  }
}

/// 非流式响应体 → 同一个 [AnthropicDelta]（completeChat 用）。
AnthropicDelta parseAnthropicResponse(Map<String, dynamic> body) {
  final text = StringBuffer();
  final thinking = StringBuffer();
  final content = body['content'];
  if (content is List) {
    for (final b in content) {
      if (b is! Map) continue;
      switch (b['type']) {
        case 'text':
          text.write((b['text'] ?? '').toString());
          break;
        case 'thinking':
          thinking.write((b['thinking'] ?? '').toString());
          break;
        case 'tool_use':
          text.write('\n<tool_use name="${b['name'] ?? ''}" />\n');
          break;
        default:
          text.write('\n<不支持的内容块：${b['type']}>\n');
      }
    }
  }
  return AnthropicDelta(
    text: text.toString(),
    thinking: thinking.toString(),
    stopReason: (body['stop_reason'] ?? '').toString(),
    usage: anthropicUsage(body),
  );
}

/// usage 字段映射（三处来源共用：`message_start.message.usage` /
/// `message_delta.usage` / 非流式顶层 `usage`）。
///
/// 字段名与 OpenAI 完全不同：`input_tokens` / `output_tokens` /
/// `cache_read_input_tokens` / `cache_creation_input_tokens`，
/// 且**没有** total ⇒ total 由 prompt+completion 相加（与 G65 口径一致；
/// 单边缺失不猜）。全空则返回 null（区分「没有 usage」与「usage 全 0」）。
TokenUsage? anthropicUsage(Map<String, dynamic> holder) {
  final raw = holder['usage'];
  if (raw is! Map) return null;
  final u = Map<String, dynamic>.from(raw);
  int? read(String k) {
    final v = u[k];
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  final prompt = read('input_tokens');
  final completion = read('output_tokens');
  final cacheRead = read('cache_read_input_tokens');
  final cacheWrite = read('cache_creation_input_tokens');
  if (prompt == null &&
      completion == null &&
      cacheRead == null &&
      cacheWrite == null) {
    return null;
  }
  return TokenUsage(
    promptTokens: prompt,
    completionTokens: completion,
    totalTokens: (prompt != null || completion != null)
        ? (prompt ?? 0) + (completion ?? 0)
        : null,
    cacheReadTokens: cacheRead,
    cacheWriteTokens: cacheWrite,
  );
}

/// 日志用：把请求体里的 base64 图片换成占位，避免整张图进导出日志。
String anthropicBodyForLog(Map<String, dynamic> body) {
  try {
    final copy = jsonDecode(jsonEncode(body)) as Map<String, dynamic>;
    final msgs = copy['messages'];
    if (msgs is List) {
      for (final m in msgs) {
        if (m is! Map) continue;
        final c = m['content'];
        if (c is! List) continue;
        for (final part in c) {
          if (part is! Map) continue;
          final src = part['source'];
          if (src is Map && src['data'] is String) {
            src['data'] = '<base64 ${(src['data'] as String).length} chars>';
          }
        }
      }
    }
    return jsonEncode(copy);
  } catch (_) {
    return '<无法序列化的请求体，已省略>';
  }
}

/// usage 合并：**逐字段后到优先**，不是相加。
///
/// 为什么不能用现成的 `TokenUsage.merge`：那个语义是**相加**（为多轮/多请求归账设计），
/// 而 Anthropic 把同一份 usage 拆在 `message_start`（只有 input）与
/// `message_delta`（output + 两个缓存计数，部分实现连 input 也重发）两个事件里。
/// 相加会把 input 双计 ⇒ 用户看到的 token 明细直接错一倍（G65 刚把总量口径修对，
/// 不能在这里又引入新的错源）。
TokenUsage usageLastWins(TokenUsage a, TokenUsage? b) {
  if (b == null) return a;
  int? pick(int? older, int? newer) => newer ?? older;
  return TokenUsage(
    promptTokens: pick(a.promptTokens, b.promptTokens),
    completionTokens: pick(a.completionTokens, b.completionTokens),
    totalTokens: pick(a.totalTokens, b.totalTokens),
    cacheReadTokens: pick(a.cacheReadTokens, b.cacheReadTokens),
    cacheWriteTokens: pick(a.cacheWriteTokens, b.cacheWriteTokens),
    cacheHitTokens: pick(a.cacheHitTokens, b.cacheHitTokens),
    cacheMissTokens: pick(a.cacheMissTokens, b.cacheMissTokens),
  );
}
