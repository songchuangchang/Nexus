import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'chat_message.dart';

class Conversation {
  final String id;
  String title;
  String apiConfigId;
  String? lastMessage;
  int contextLimit;
  double temperature;
  double topP;
  bool enable20sCheck;
  bool contextAuto;
  bool autoCompress;
  bool largeContextMax;
  bool isPinned;
  // v1.7.25：思考相关改为每对话独有
  bool reactEnabled; // 自主思考总开关（原全局，改为每对话独有）
  bool reactAutoMode; // 思考程度：自动档
  int reactMaxRounds; // 思考程度：轮数/上限（自动档=上限）
  double
      reasoningEffort; // 思考强度：0.0=默认(跟随轮数) 0.1–1.0 连续（≤0.33 low / ≤0.66 medium / 否则 high）
  // v1.7.34：跨对话记忆 + 深度研究 + 子代理编排
  String summary; // 跨对话记忆摘要（后台 completeChat 生成，≤500 字）
  bool memoryEnabled; // 跨对话摘要开关（关闭时发送前不注入历史摘要）
  // build94 (D3)：长期记忆（全局/项目记忆）独立开关——与跨对话摘要拆分，
  // 关掉后 MemoryBlockBuilder 不再注入长期记忆块
  bool longTermMemoryEnabled;
  bool deepResearchMode; // 深度研究模式（自动开启多专家混合 + 更高轮数 + 关闭 20s 自检）
  String
      subagentMode; // 子代理模式：auto / main_only / force_search / force_synthesis / force_plugin
  // v1.7.38 build90（⑧项目记忆）：所属项目 id，空串=不属于任何项目
  String projectId;
  // build101（B5 会话归档）：归档后不在主列表显示，需在「归档」筛选下查看
  bool isArchived;
  // build101（B3/B4 消息编辑）：本会话内被引用/置顶的消息 id 列表（JSON 数组字符串）
  String starredMessageIds;
  // build101（C1 知识库 RAG）：绑定的知识库 id，空串=不启用知识库检索
  String knowledgeBaseId;
  // build101（E8 自定义助手）：绑定的助手 id，空串=不使用角色预设
  String assistantId;
  DateTime updatedAt;
  DateTime createdAt;

  Conversation({
    required this.id,
    required this.title,
    required this.apiConfigId,
    this.lastMessage,
    this.contextLimit = 20,
    this.temperature = 0.7,
    this.topP = 1.0,
    this.enable20sCheck = true,
    this.contextAuto = true,
    this.autoCompress = false,
    this.largeContextMax = false,
    this.isPinned = false,
    this.reactEnabled = true,
    this.reactAutoMode = true,
    this.reactMaxRounds = 30,
    this.reasoningEffort = 0.0,
    this.summary = '',
    this.memoryEnabled = true,
    this.longTermMemoryEnabled = true,
    this.deepResearchMode = false,
    this.subagentMode = 'auto',
    this.projectId = '',
    this.isArchived = false,
    this.starredMessageIds = '',
    this.knowledgeBaseId = '',
    this.assistantId = '',
    required this.updatedAt,
    required this.createdAt,
  });

  factory Conversation.create({
    required String apiConfigId,
    String title = 'New Chat',
  }) {
    final now = DateTime.now();
    return Conversation(
      id: const Uuid().v4(),
      title: title,
      apiConfigId: apiConfigId,
      updatedAt: now,
      createdAt: now,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'apiConfigId': apiConfigId,
      'lastMessage': lastMessage,
      'contextLimit': contextLimit,
      'temperature': temperature,
      'topP': topP,
      'enable20sCheck': enable20sCheck ? 1 : 0,
      'contextAuto': contextAuto ? 1 : 0,
      'autoCompress': autoCompress ? 1 : 0,
      'largeContextMax': largeContextMax ? 1 : 0,
      'isPinned': isPinned ? 1 : 0,
      'reactEnabled': reactEnabled ? 1 : 0,
      'reactAutoMode': reactAutoMode ? 1 : 0,
      'reactMaxRounds': reactMaxRounds,
      'reasoningEffort': reasoningEffort,
      'summary': summary,
      'memoryEnabled': memoryEnabled ? 1 : 0,
      'longTermMemoryEnabled': longTermMemoryEnabled ? 1 : 0,
      'deepResearchMode': deepResearchMode ? 1 : 0,
      'subagentMode': subagentMode,
      'projectId': projectId,
      'isArchived': isArchived ? 1 : 0,
      'starredMessageIds': starredMessageIds,
      'knowledgeBaseId': knowledgeBaseId,
      'assistantId': assistantId,
      'updatedAt': updatedAt.toIso8601String(),
      'createdAt': createdAt.toIso8601String(),
    };
  }

  /// build101：已引用/置顶的消息 id 集合（解析失败时返回空集，不抛）
  Set<String> get starredIds {
    if (starredMessageIds.trim().isEmpty) return const {};
    try {
      final list = json.decode(starredMessageIds);
      if (list is List) return list.whereType<String>().toSet();
    } catch (_) {
      // 脏数据降级：当作没有引用
    }
    return const {};
  }

  /// build101：设置引用消息 id 集合并序列化
  void setStarredIds(Set<String> ids) {
    starredMessageIds = ids.isEmpty ? '' : json.encode(ids.toList());
  }

  factory Conversation.fromMap(Map<String, dynamic> map) {    // v1.7.37 迁移：深度研究独立开关并入思考强度 1.0 档
    // 老数据 deepResearchMode=1 且未手动设过强度（0.0）→ 自动升到深度档
    var reasoningEffort = (map['reasoningEffort'] as num?)?.toDouble() ?? 0.0;
    final deepResearchMode = ((map['deepResearchMode'] as int?) ?? 0) == 1;
    if (deepResearchMode && reasoningEffort <= 0.0) {
      reasoningEffort = 1.0;
    }
    return Conversation(
      id: map['id'] as String,
      title: map['title'] as String,
      apiConfigId: map['apiConfigId'] as String,
      lastMessage: map['lastMessage'] as String?,
      contextLimit: (map['contextLimit'] as int?) ?? 20,
      temperature: (map['temperature'] as num?)?.toDouble() ?? 0.7,
      topP: (map['topP'] as num?)?.toDouble() ?? 1.0,
      enable20sCheck: ((map['enable20sCheck'] as int?) ?? 1) == 1,
      contextAuto: ((map['contextAuto'] as int?) ?? 1) == 1,
      autoCompress: ((map['autoCompress'] as int?) ?? 0) == 1,
      largeContextMax: ((map['largeContextMax'] as int?) ?? 0) == 1,
      isPinned: ((map['isPinned'] as int?) ?? 0) == 1,
      reactEnabled: ((map['reactEnabled'] as int?) ?? 1) == 1,
      reactAutoMode: ((map['reactAutoMode'] as int?) ?? 1) == 1,
      reactMaxRounds: (map['reactMaxRounds'] as int?) ?? 30,
      reasoningEffort: reasoningEffort,
      summary: (map['summary'] as String?) ?? '',
      memoryEnabled: ((map['memoryEnabled'] as int?) ?? 1) == 1,
      longTermMemoryEnabled:
          ((map['longTermMemoryEnabled'] as int?) ?? 1) == 1,
      deepResearchMode: deepResearchMode,
      subagentMode:
          _sanitizeSubagentMode((map['subagentMode'] as String?) ?? 'auto'),
      projectId: (map['projectId'] as String?) ?? '',
      isArchived: ((map['isArchived'] as int?) ?? 0) == 1,
      starredMessageIds: (map['starredMessageIds'] as String?) ?? '',
      knowledgeBaseId: (map['knowledgeBaseId'] as String?) ?? '',
      assistantId: (map['assistantId'] as String?) ?? '',
      updatedAt: DateTime.parse(map['updatedAt'] as String),
      createdAt: DateTime.parse(map['createdAt'] as String),
    );
  }

  /// 子代理模式合法值白名单——非白名单值一律回退到 'auto'（防远程 JSON 覆盖 / 手动改库引入脏数据）
  static const Set<String> kSubagentModes = {
    'auto',
    'main_only',
    'force_search',
    'force_synthesis',
    'force_plugin',
  };

  static String _sanitizeSubagentMode(String s) =>
      kSubagentModes.contains(s) ? s : 'auto';

  String toJson() => json.encode(toMap());

  factory Conversation.fromJson(String source) =>
      Conversation.fromMap(json.decode(source) as Map<String, dynamic>);
}

/// build101（F1 会话内查找）：单条消息的搜索命中
///
/// 与 [ConversationSearchHit] 的区别：会话内搜索需要拿到**消息在列表中的
/// 下标**（用于滚动定位），所以额外携带 [indexInConversation]。
/// [matchStartInSnippet] 是关键字在 [snippet] 中的起始位置，UI 侧据此
/// 做高亮（避免再做一次全文 indexOf 导致的不一致）。
class MessageSearchHit {
  final ChatMessage message;

  /// 该消息在 `_messages` 列表中的下标（0 起）。
  final int indexInConversation;

  /// 含关键字的上下文窗口文本（关键字前后各若干字符）。
  final String snippet;

  /// 关键字在 [snippet] 中的起始下标；-1 表示未找到（理论上不会）。
  final int matchStartInSnippet;

  /// 命中次数（同一消息内可能出现多次）。
  final int matchCount;

  const MessageSearchHit({
    required this.message,
    required this.indexInConversation,
    required this.snippet,
    required this.matchStartInSnippet,
    this.matchCount = 1,
  });
}

/// build101（B2 全局会话搜索）：一条搜索结果
///
/// `matchedInTitle=true` 表示命中会话标题；否则命中某条消息内容，
/// `snippet` 为该消息全文（UI 侧做关键字截窗与高亮）。
class ConversationSearchHit {
  final Conversation conversation;
  final bool matchedInTitle;
  final String snippet;

  const ConversationSearchHit({
    required this.conversation,
    required this.matchedInTitle,
    required this.snippet,
  });
}

/// build145（循环审查第 7 轮 P1）：合并导入时把 [Conversation.starredMessageIds]
/// 里引用的消息 id 换成重映射后的新 id。
///
/// 为什么必须有这一步：合并模式下消息主键撞车会重新分配 id（build97 P1-1，
/// `messageIdMap`），当时把引用链一路改到了 `messages.retryOf`、
/// `message_versions.retryOfId`、`context_compaction_segments.start/endMessageId` ——
/// 唯独漏了收藏：**收藏列表存的是一串消息 id**，导完备份后那些 id 全部指向
/// 不存在（甚至属于别人）的行，`starredIds` 又对脏数据静默返回空集（:130-132），
/// 所以表现出来就是"换机/合并之后收藏凭空消失"，且没有任何一行日志。
///
/// 编解码刻意复用 [Conversation.starredIds] / setStarredIds 的同一套口径
/// （JSON 数组字符串、空集写空串），不引第二种表示法（设计法则 #62）。
String remapStarredMessageIds(
    String starredJson, Map<String, String> messageIdMap) {
  if (starredJson.trim().isEmpty) return '';
  final Object? decoded;
  try {
    decoded = json.decode(starredJson);
  } catch (_) {
    // 脏数据原样留着：这里没有"正确答案"，猜一个反而把坏数据写成看起来好的。
    return starredJson;
  }
  if (decoded is! List) return starredJson;
  final out = <String>[];
  for (final item in decoded) {
    if (item is! String) continue;
    final mapped = messageIdMap[item] ?? item;
    if (!out.contains(mapped)) out.add(mapped);
  }
  return out.isEmpty ? '' : json.encode(out);
}
