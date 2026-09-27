import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'package:flutter/foundation.dart';

enum MessageRole { user, assistant, system }

class TokenUsage {
  final int? promptTokens;
  final int? completionTokens;
  final int? totalTokens;
  final int? cacheReadTokens;
  final int? cacheWriteTokens;
  final int? cacheHitTokens;
  final int? cacheMissTokens;

  const TokenUsage({
    this.promptTokens,
    this.completionTokens,
    this.totalTokens,
    this.cacheReadTokens,
    this.cacheWriteTokens,
    this.cacheHitTokens,
    this.cacheMissTokens,
  });

  bool get hasCacheData =>
      cacheReadTokens != null ||
      cacheWriteTokens != null ||
      cacheHitTokens != null ||
      cacheMissTokens != null;

  TokenUsage merge(TokenUsage other) => TokenUsage(
        promptTokens: _sumNullable(promptTokens, other.promptTokens),
        completionTokens:
            _sumNullable(completionTokens, other.completionTokens),
        totalTokens: _sumNullable(totalTokens, other.totalTokens),
        cacheReadTokens: _sumNullable(cacheReadTokens, other.cacheReadTokens),
        cacheWriteTokens:
            _sumNullable(cacheWriteTokens, other.cacheWriteTokens),
        cacheHitTokens: _sumNullable(cacheHitTokens, other.cacheHitTokens),
        cacheMissTokens: _sumNullable(cacheMissTokens, other.cacheMissTokens),
      );

  static int? _sumNullable(int? a, int? b) {
    if (a == null && b == null) return null;
    return (a ?? 0) + (b ?? 0);
  }
}

extension MessageRoleExtension on MessageRole {
  String get value {
    switch (this) {
      case MessageRole.user:
        return 'user';
      case MessageRole.assistant:
        return 'assistant';
      case MessageRole.system:
        return 'system';
    }
  }

  static MessageRole fromString(String value) {
    switch (value) {
      case 'user':
        return MessageRole.user;
      case 'assistant':
        return MessageRole.assistant;
      case 'system':
        return MessageRole.system;
      default:
        return MessageRole.user;
    }
  }
}

/// v1.3.1 build 11: ReAct 协议每一步（内存级，不落库）
/// kind: 'thinking' | 'search' | 'search_result'
/// v1.7.22: 新增 phase（阶段）和 round（轮次）字段，支持思考过程分类折叠
class ReasoningStep {
  final String kind;
  String content;
  int? resultCount;
  int? latencyMs;
  final DateTime ts;
  final String phase;
  final int round;
  String? pluginId;
  String? pluginName;
  String? toolName;
  String status;
  String? arguments;
  String? resultSummary;

  ReasoningStep(
    this.kind,
    this.content, {
    this.resultCount,
    this.latencyMs,
    this.phase = '',
    this.round = 0,
    this.pluginId,
    this.pluginName,
    this.toolName,
    this.status = '',
    this.arguments,
    this.resultSummary,
  }) : ts = DateTime.now();

  /// 这一步**只有进度占位文本**（`🧠 思考中…` / `正在思考是否需要联网搜索…` /
  /// `📦`/`📩` 进度行），没有任何真实思考内容。
  ///
  /// build142：把这条判据从 `ChatMessage.hasReasoning` 里**搬出来**放这儿，
  /// 因为消费点从 1 个变成了 3 个 —— 折叠面板（`_mergeNodes`）与
  /// 「导出思考过程」也要它。原来只有 `hasReasoning` 认占位，
  /// 于是真机报了：面板不显示（对），**但导出里第一行仍然是一条假的「思考过程」**，
  /// 里面只有一句 `正在思考是否需要联网搜索…`。同一语义两处各判一次必出这种岔子（#62）。
  bool get isProgressPlaceholderOnly {
    if (kind != 'thinking') return false; // 工具/搜索/反问节点永远是真实动作
    for (final line in content.split('\n')) {
      if (!isThinkingPlaceholderLine(line)) return false;
    }
    return true;
  }

  /// N13：思考步骤里的"纯进度占位行"判定。
  /// 只匹配确切的进度文案格式（🧠 思考中…/🧠 Thinking... (round …)、📦/📩 进度行），
  /// 不用宽泛的 contains('thinking') 误伤真实思考内容（英文真实思考常带这个词）。
  static bool isThinkingPlaceholderLine(String line) {
    final t = line.trim();
    if (t.isEmpty) return true;
    if (t.contains('🧠') || t.contains('📦') || t.contains('📩')) return true;
    if (t.contains('思考中…')) return true;
    // build142：宿主自己发的两条进度占位也收进来（真机导出里那条假「思考过程」
    // 就是这两句之一，之前只认带 🧠 的旧文案 ⇒ 新文案逃过判定）。
    if (t.contains('正在思考是否需要联网搜索')) return true;
    if (t.startsWith('Thinking whether to search')) return true;
    if (RegExp(r'Thinking\.\.\.').hasMatch(t)) return true;
    return false;
  }


  ReasoningStep._({
    required this.kind,
    required this.content,
    this.resultCount,
    this.latencyMs,
    required this.ts,
    this.phase = '',
    this.round = 0,
    this.pluginId,
    this.pluginName,
    this.toolName,
    this.status = '',
    this.arguments,
    this.resultSummary,
  });

  Map<String, dynamic> toMap() => {
        'kind': kind,
        'content': content,
        if (resultCount != null) 'resultCount': resultCount,
        if (latencyMs != null) 'latencyMs': latencyMs,
        'ts': ts.toIso8601String(),
        if (phase.isNotEmpty) 'phase': phase,
        if (round > 0) 'round': round,
        if (pluginId != null) 'pluginId': pluginId,
        if (pluginName != null) 'pluginName': pluginName,
        if (toolName != null) 'toolName': toolName,
        if (status.isNotEmpty) 'status': status,
        if (arguments != null) 'arguments': arguments,
        if (resultSummary != null) 'resultSummary': resultSummary,
      };

  factory ReasoningStep.fromMap(Map<String, dynamic> m) => ReasoningStep._(
        // build138（P1-3）：kind/content/ts 改容错读法。老库行可能根本没有这些列
        // （phase/round/status/pluginId/toolName 都是后加的），硬转抛一次就会连累
        // 同一条消息里其他已经解好的步骤（见 ChatMessage.fromMap 的注释）。
        // ts 缺省用当前时间而非 epoch：UI 拿 steps.first.ts 做差值与 HH:mm:ss 展示
        // （message_bubble_v2.dart:709/1278），1970 会渲染出一个荒谬耗时。
        kind: (m['kind'] as String?) ?? '',
        content: (m['content'] as String?) ?? '',
        resultCount: m['resultCount'] as int?,
        latencyMs: m['latencyMs'] as int?,
        ts: DateTime.tryParse(m['ts'] as String? ?? '') ?? DateTime.now(),
        phase: (m['phase'] as String?) ?? '',
        round: (m['round'] as int?) ?? 0,
        pluginId: m['pluginId'] as String?,
        pluginName: m['pluginName'] as String?,
        toolName: m['toolName'] as String?,
        status: (m['status'] as String?) ?? '',
        arguments: m['arguments'] as String?,
        resultSummary: m['resultSummary'] as String?,
      );
}

/// v1.7.38：搜索来源引用（Chatbox 风格引用卡片）。
/// ReAct 搜索插件每次命中后把 {title, url} 追加到 ChatMessage.searchSources，
/// 落库为 messages.searchSources（JSON 数组字符串），气泡下方渲染「📎 来源 N」。
class SearchSource {
  final String title;
  final String url;

  const SearchSource({required this.title, required this.url});

  /// 域名（引用卡片副标题）；解析失败返回空串
  String get domain {
    try {
      return Uri.parse(url).host;
    } catch (_) {
      return '';
    }
  }

  Map<String, dynamic> toMap() => {'title': title, 'url': url};

  factory SearchSource.fromMap(Map<String, dynamic> m) => SearchSource(
        title: (m['title'] as String?) ?? '',
        url: (m['url'] as String?) ?? '',
      );
}

/// v1.7.26 (E3)：重试版本快照（v1.7.22 原为 UI 层内存结构，现下沉到 models
/// 供 StorageService 持久化到 message_versions 表——此前仅存活于进程内存，
/// 重启后版本切换功能丢失）
class RetryVersion {
  final String content;
  final List<ReasoningStep> reasoningSteps;
  final int? promptTokens;
  final int? completionTokens;
  final int? totalTokens;
  final int? cacheReadTokens;
  final int? cacheWriteTokens;
  final int? cacheHitTokens;
  final int? cacheMissTokens;
  final int injectedWebSearchCount;
  final bool showStaleFootnote;
  final String modelName;
  final List<SearchSource> searchSources;
  RetryVersion({
    required this.content,
    this.reasoningSteps = const [],
    this.promptTokens,
    this.completionTokens,
    this.totalTokens,
    this.cacheReadTokens,
    this.cacheWriteTokens,
    this.cacheHitTokens,
    this.cacheMissTokens,
    this.injectedWebSearchCount = 0,
    this.showStaleFootnote = false,
    this.modelName = '',
    this.searchSources = const [],
  });
}

/// v1.3.6：📎 附件类型
/// - text: txt/md 等纯文本（extractedText 直接读文件内容）
/// - image: 照片（localPath 存本地路径，发 API 时再转 base64，避免 DB 存大块 base64）
/// - doc: pdf/docx（extractedText 存已抽取的文本）
enum AttachmentType { text, image, doc }

extension AttachmentTypeExtension on AttachmentType {
  String get value {
    switch (this) {
      case AttachmentType.text:
        return 'text';
      case AttachmentType.image:
        return 'image';
      case AttachmentType.doc:
        return 'doc';
    }
  }

  static AttachmentType fromString(String v) {
    switch (v) {
      case 'image':
        return AttachmentType.image;
      case 'doc':
        return AttachmentType.doc;
      default:
        return AttachmentType.text;
    }
  }
}

class MessageAttachment {
  final String id;
  final AttachmentType type;
  final String fileName;
  final String? extractedText; // text/doc: 已抽取文本（过长会截断）
  final String? localPath; // image: 本地路径（发 API 时再转 base64）
  final String? mimeType; // image: image/jpeg 等
  final int? sizeBytes;

  const MessageAttachment({
    required this.id,
    required this.type,
    required this.fileName,
    this.extractedText,
    this.localPath,
    this.mimeType,
    this.sizeBytes,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'type': type.value,
        'fileName': fileName,
        if (extractedText != null) 'extractedText': extractedText,
        if (localPath != null) 'localPath': localPath,
        if (mimeType != null) 'mimeType': mimeType,
        if (sizeBytes != null) 'sizeBytes': sizeBytes,
      };

  factory MessageAttachment.fromMap(Map<String, dynamic> m) =>
      MessageAttachment(
        id: m['id'] as String,
        type: AttachmentTypeExtension.fromString(m['type'] as String),
        fileName: m['fileName'] as String,
        extractedText: m['extractedText'] as String?,
        localPath: m['localPath'] as String?,
        mimeType: m['mimeType'] as String?,
        sizeBytes: m['sizeBytes'] as int?,
      );
}

/// build138（P1-3）：把「列表列」的解码拆成两步 —— 先解出原始数组，再由调用方
/// **逐元素** try/catch（见 ChatMessage.fromMap）。
///
/// 为什么不再让一个 `try` 罩住整个 for 循环：数组里任意一个坏元素抛出，就会把
/// 同一条消息里**已经解好的前 N 个好元素**一起丢掉（旧行为只剩 debugPrint 一条，
/// release 环境连日志都进不去）。而 toMap 是按内存列表序列化的，ReAct 的节流回写
/// （chat_screen_react 的 _throttledSaveAssistantContent → storage.saveMessage）
/// 会把截断后的列表覆盖回 DB ⇒ 症状从「思考面板显示不全」升级成「步骤永久丢失」。
///
/// 返回值：数组本身坏掉（JSON 截断 / 不是数组）时返回空表 —— 这时确实无从逐元素容错。
List<Object?> _decodeJsonList(String raw, String column) {
  try {
    final decoded = json.decode(raw);
    if (decoded is List) return decoded;
    debugPrint('[ChatMessage] $column 列不是 JSON 数组，按空表处理');
  } catch (e) {
    debugPrint('[ChatMessage] $column 整列 JSON 解码失败: $e');
  }
  return const [];
}

class ChatMessage {
  /// build138（P1-3 补完）：反序列化时「坏元素被跳过」的上报口。
  ///
  /// 扫描报告点破了一件事：build138 把 P1-3 的修复写成 `debugPrint`，
  /// 列表确实保住了，但**真机上丢掉的元素仍然无人知晓**（release 包 debugPrint
  /// 不进导出日志）——同一种「静默降级」只修了一半。
  /// 这里做成可注入的静态钩子而不是直接 import LoggerService：
  /// ① model 层不依赖 service 层（单测无需插件通道）；
  /// ② 计数与最近一次错误可被断言（`corruptElementCount`）；
  /// ③ 真正的落日志由 main.dart 接线（唯一的调用点，见 bootstrap）。
  static void Function(String message)? corruptReporter;
  static int corruptElementCount = 0;
  static String? lastCorruptElementError;

  static void _reportCorrupt(String what, Object error) {
    corruptElementCount++;
    lastCorruptElementError = '$what: $error';
    final msg = '[ChatMessage] $what 元素损坏，已跳过: $error';
    final r = corruptReporter;
    if (r != null) {
      r(msg);
    } else {
      debugPrint(msg);
    }
  }

  final String id;
  final String conversationId;
  final MessageRole role;
  String content;

  /// v1.7.26 (E4)：改为可变——历史消息重试后需写回旧对话原有的时间戳做原位
  /// 重插，DB 依赖 createdAt ASC 排序，若沿用新时间则重载后顺序会被打乱
  DateTime createdAt;
  String? modelName;

  // ===== UI 标记（不落库 / 不参与序列化，纯用于本次会话内气泡展示）=====
  /// true → 在气泡底部加一行"⚠️ 基于 AI 内置知识，可能已过时"的淡色 footnote
  bool showStaleFootnote = false;

  /// true → 在气泡底部加一行"🌐 已联网搜索注入 N 条搜索结果"的淡色 footnote
  int injectedWebSearchCount = 0;

  /// 搜索结果命中数的**合理上限**（纯展示用）。
  ///
  /// build129：历史事故——`PluginContext.saveAssistantContent` 曾把「强制保存」
  /// 编码成 999999999 借 count 形参传给宿主，宿主原样写进本字段，气泡页脚于是
  /// 显示「已联网注入 999999999 条搜索结果」。根因已用类型修掉（force 改独立
  /// 命名字段），此处再留一道**渲染兜底**：真命中数不可能上千（单次搜索 5~20 条，
  /// 深度阅读也就几十条），超限值一律按「不可信 → 不展示」处理。
  static const int maxSaneSearchHits = 1000;

  /// 命中数入池前的净化：越界/负值一律归 0（调用方见 0 即跳过展示）。
  static int sanitizeSearchHits(int raw) =>
      (raw > 0 && raw <= maxSaneSearchHits) ? raw : 0;

  /// v1.3.1 build 11: ReAct 思考过程（每一步 thinking/search/结果）
  final List<ReasoningStep> reasoningSteps = [];

  /// true → ReAct 循环已经跑过（决定 UI 上显示折叠面板）
  bool get hasReasoning {
    // v1.7.25：只认"有真实内容"的思考——纯进度占位（🧠 思考中…/📦/📩）不算，
    // 单步骤流程（如纯下载）不展示无意义的思考面板；多步骤/真实思考/搜索结果才显示。
    // N13 修复：占位行与真实思考文本常混在同一 step（流式先写占位、后追加真实内容），
    // 旧逻辑用 contains('思考中'/'thinking') 整段判定 → 含占位的真实思考被整段误杀
    // （英文真实思考含 "thinking" 字样也会被误杀）。现改为逐行剔除占位行后再判定。
    if (reasoningSteps.isEmpty) return false;
    // build142：判定本身搬到 [ReasoningStep.isProgressPlaceholderOnly]（原因写在那里 ——
    // 消费点从 1 个变 3 个），这里只留「有没有任何一步不是纯占位」这一层语义。
    return reasoningSteps.any((st) => !st.isProgressPlaceholderOnly);
  }

  /// v1.3.6：token 用量统计（prompt + completion + total）
  int? promptTokens;
  int? completionTokens;
  int? totalTokens;
  int? cacheReadTokens;
  int? cacheWriteTokens;
  int? cacheHitTokens;
  int? cacheMissTokens;

  /// v1.3.6：📎 附件列表（落库为 JSON 字符串）
  final List<MessageAttachment> attachments = [];

  /// build122：AI **生成产物**的本地路径（图片/视频，落库为 JSON 字符串）。
  ///
  /// ## 为什么不复用 [attachments]
  /// `ApiService._buildMessagesPayload` 对**所有角色**的 `attachments` 都会做
  /// 多模态处理（图片转 vision 输入、非视觉模型下还会走 OCR）。生成产物若挂在
  /// attachments 上，下一轮就会被当成**用户提供的图片输入**回灌给模型：
  /// 既浪费 token，又会让模型「看到自己生成的图」而语义错乱。
  /// 因此单独开一个字段——它**只用于本地渲染，永不进 API 请求**。
  final List<String> generatedFiles = [];

  /// v1.7.38：搜索来源引用列表（落库为 JSON 字符串，气泡渲染引用卡片）
  final List<SearchSource> searchSources = [];

  /// v1.7.39 build92：AI 推荐的后续问题（不落库，纯 UI 展示，点击直接发送）
  final List<String> suggestions = [];

  /// v1.7.39 build92：AI 创建的待办清单（不落库，纯 UI 展示，可勾选）
  /// 每项: {'text': '事项内容', 'done': false}
  final List<Map<String, dynamic>> todoItems = [];

  String retryOf = '';
  int retryIndex = 0;

  ChatMessage({
    required this.id,
    required this.conversationId,
    required this.role,
    required this.content,
    required this.createdAt,
    this.modelName,
    this.showStaleFootnote = false,
    this.injectedWebSearchCount = 0,
    this.retryOf = '',
    this.retryIndex = 0,
  });

  factory ChatMessage.create({
    required String conversationId,
    required MessageRole role,
    required String content,
    String? modelName,
    bool showStaleFootnote = false,
    int injectedWebSearchCount = 0,
  }) {
    return ChatMessage(
      id: const Uuid().v4(),
      conversationId: conversationId,
      role: role,
      content: content,
      createdAt: DateTime.now(),
      modelName: modelName,
      showStaleFootnote: showStaleFootnote,
      injectedWebSearchCount: injectedWebSearchCount,
    );
  }

  // 添加一步思考过程（setState 后气泡会实时刷新）
  void addReasoning(ReasoningStep step) {
    reasoningSteps.add(step);
  }

  void appendLastThinking(String chunk) {
    if (reasoningSteps.isEmpty || reasoningSteps.last.kind != 'thinking') {
      reasoningSteps.add(ReasoningStep('thinking', chunk));
    } else {
      reasoningSteps.last.content += chunk;
    }
  }

  /// v1.7.25：每轮思考强制新建独立 step。
  /// 修复：连续多轮 thinking（无 search 打断）时 appendLastThinking 会合并到
  /// 同一个 step，且 setLastReasoningPhase 把 phase 覆盖成最新轮次 → 第一轮
  /// 内容在最后"突然切换/消失"。每轮开始调用本方法即可按轮次分隔。
  void startNewThinking(String chunk) {
    reasoningSteps.add(ReasoningStep('thinking', chunk));
  }

  void markLastSearchResult(
      {required int count, int? latencyMs, required String summary}) {
    reasoningSteps.add(ReasoningStep(
      'search_result',
      summary,
      resultCount: count,
      latencyMs: latencyMs,
    ));
  }

  void setLastReasoningPhase(String phase, int round) {
    if (reasoningSteps.isEmpty) return;
    final last = reasoningSteps.last;
    // N13 修复：重建 step 时必须透传插件类元数据
    // （pluginId/pluginName/toolName/status/arguments/resultSummary），
    // 否则插件/工具步骤被 setLastReasoningPhase 覆盖后折叠面板里丢失工具名与结果摘要。
    reasoningSteps[reasoningSteps.length - 1] = ReasoningStep(
      last.kind,
      last.content,
      resultCount: last.resultCount,
      latencyMs: last.latencyMs,
      phase: phase,
      round: round,
      pluginId: last.pluginId,
      pluginName: last.pluginName,
      toolName: last.toolName,
      status: last.status,
      arguments: last.arguments,
      resultSummary: last.resultSummary,
    );
  }

  /// 追加搜索来源（按 URL 去重，保持顺序）
  void addSearchSources(Iterable<SearchSource> sources) {
    final seen = searchSources.map((s) => s.url).toSet();
    for (final s in sources) {
      if (s.url.isEmpty || !seen.add(s.url)) continue;
      searchSources.add(s);
    }
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'conversationId': conversationId,
      'role': role.value,
      'content': content,
      'createdAt': createdAt.toIso8601String(),
      'modelName': modelName,
      // v1.3.6：附件序列化为 JSON 数组字符串
      'attachments': json.encode(attachments.map((a) => a.toMap()).toList()),
      // build122：生成产物路径（同上，JSON 数组字符串；不进 API 请求）
      'generatedFiles': json.encode(generatedFiles),
      'retryOf': retryOf,
      'retryIndex': retryIndex,
      'reasoningSteps':
          json.encode(reasoningSteps.map((s) => s.toMap()).toList()),
      // v1.7.38：搜索来源引用序列化为 JSON 数组字符串
      'searchSources':
          json.encode(searchSources.map((s) => s.toMap()).toList()),
      // v1.7.26 (C2)：token 用量持久化（此前仅内存，重启后丢失）
      if (promptTokens != null) 'promptTokens': promptTokens,
      if (completionTokens != null) 'completionTokens': completionTokens,
      if (totalTokens != null) 'totalTokens': totalTokens,
      if (cacheReadTokens != null) 'cacheReadTokens': cacheReadTokens,
      if (cacheWriteTokens != null) 'cacheWriteTokens': cacheWriteTokens,
      if (cacheHitTokens != null) 'cacheHitTokens': cacheHitTokens,
      if (cacheMissTokens != null) 'cacheMissTokens': cacheMissTokens,
    };
  }

  factory ChatMessage.fromMap(Map<String, dynamic> map) {
    final msg = ChatMessage(
      id: map['id'] as String,
      conversationId: map['conversationId'] as String,
      role: MessageRoleExtension.fromString(map['role'] as String),
      content: map['content'] as String,
      createdAt: DateTime.parse(map['createdAt'] as String),
      modelName: map['modelName'] as String?,
      retryOf: (map['retryOf'] as String?) ?? '',
      retryIndex: (map['retryIndex'] as int?) ?? 0,
    );
    // v1.3.6：反序列化附件（旧消息无此列 → 空）
    final raw = map['attachments'] as String?;
    if (raw != null && raw.isNotEmpty && raw != '[]') {
      // build138（P1-3）：容错粒度 = 单个元素（坏元素只丢它自己）
      final list = _decodeJsonList(raw, 'attachments');
      for (var i = 0; i < list.length; i++) {
        try {
          msg.attachments.add(
              MessageAttachment.fromMap(list[i] as Map<String, dynamic>));
        } catch (e) {
          _reportCorrupt('attachments[$i]', e);
        }
      }
    }
    // build122：反序列化生成产物路径（旧消息无此列 → 空）
    final rawGen = map['generatedFiles'] as String?;
    if (rawGen != null && rawGen.isNotEmpty && rawGen != '[]') {
      final list = _decodeJsonList(rawGen, 'generatedFiles');
      for (var i = 0; i < list.length; i++) {
        final p = list[i]?.toString() ?? '';
        if (p.isNotEmpty) msg.generatedFiles.add(p);
      }
    }
    // 反序列化思考步骤
    final reasoningRaw = map['reasoningSteps'] as String?;
    if (reasoningRaw != null &&
        reasoningRaw.isNotEmpty &&
        reasoningRaw != '[]') {
      final list = _decodeJsonList(reasoningRaw, 'reasoningSteps');
      for (var i = 0; i < list.length; i++) {
        try {
          msg.reasoningSteps
              .add(ReasoningStep.fromMap(list[i] as Map<String, dynamic>));
        } catch (e) {
          _reportCorrupt('reasoningSteps[$i]', e);
        }
      }
    }
    // v1.7.38：反序列化搜索来源引用（旧消息无此列 → 空）
    final sourcesRaw = map['searchSources'] as String?;
    if (sourcesRaw != null && sourcesRaw.isNotEmpty && sourcesRaw != '[]') {
      final list = _decodeJsonList(sourcesRaw, 'searchSources');
      for (var i = 0; i < list.length; i++) {
        try {
          msg.searchSources
              .add(SearchSource.fromMap(list[i] as Map<String, dynamic>));
        } catch (e) {
          _reportCorrupt('searchSources[$i]', e);
        }
      }
    }
    // v1.7.26 (C2)：token 用量反序列化（旧库无此列 → null）
    msg.promptTokens = map['promptTokens'] as int?;
    msg.completionTokens = map['completionTokens'] as int?;
    msg.totalTokens = map['totalTokens'] as int?;
    msg.cacheReadTokens = map['cacheReadTokens'] as int?;
    msg.cacheWriteTokens = map['cacheWriteTokens'] as int?;
    msg.cacheHitTokens = map['cacheHitTokens'] as int?;
    msg.cacheMissTokens = map['cacheMissTokens'] as int?;
    return msg;
  }

  String toJson() => json.encode(toMap());

  factory ChatMessage.fromJson(String source) =>
      ChatMessage.fromMap(json.decode(source) as Map<String, dynamic>);
}
