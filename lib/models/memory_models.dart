/// v1.7.38 build90（第 4 步 · 待办⑧⑨）：全局/项目记忆 + 斜杠命令数据模型。
library;

/// 全局记忆：跨所有对话生效的用户偏好/事实（一句话一条）。
class GlobalMemory {
  GlobalMemory({
    required this.id,
    required this.content,
    this.source = 'manual',
    this.pinned = false,
    int? createdAt,
    int? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch,
        updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch;

  final String id;
  String content;
  // manual（用户在记忆页自己写的）/ auto（AI 自动写的，唯一被「自动记忆」总闸管住的那一档）
  // / conversation:<id>（从某次会话带出来的）。
  // build173：这一行的旧注释只写了 manual 与 conversation:<id>，`auto` 从没写进来，
  // 而 `auto` 恰恰是判据里被单独对待的那一档（storage_service 的总闸、
  // memory_block_builder._isAuto、builtin_plugins.autoOverwriteAllowed 都只认它）。
  String source;
  bool pinned; // 钉住=永不自动清理
  final int createdAt;
  int updatedAt;

  Map<String, dynamic> toMap() => {
        'id': id,
        'content': content,
        'source': source,
        'pinned': pinned ? 1 : 0,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  factory GlobalMemory.fromMap(Map<String, dynamic> map) => GlobalMemory(
        id: map['id'] as String,
        content: (map['content'] as String?) ?? '',
        source: (map['source'] as String?) ?? 'manual',
        pinned: ((map['pinned'] as int?) ?? 0) == 1,
        createdAt: (map['createdAt'] as int?) ?? 0,
        updatedAt: (map['updatedAt'] as int?) ?? 0,
      );
}

/// 项目：按话题分组沉淀上下文的容器。
class Project {
  Project({
    required this.id,
    required this.name,
    int? createdAt,
  }) : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch;

  final String id;
  String name;
  final int createdAt;

  Map<String, dynamic> toMap() =>
      {'id': id, 'name': name, 'createdAt': createdAt};

  factory Project.fromMap(Map<String, dynamic> map) => Project(
        id: map['id'] as String,
        name: (map['name'] as String?) ?? '',
        createdAt: (map['createdAt'] as int?) ?? 0,
      );
}

/// 项目记忆：进入该项目对话时自动携带。
class ProjectMemory {
  ProjectMemory({
    required this.id,
    required this.projectId,
    required this.content,
    this.source = 'manual',
    int? createdAt,
    int? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch,
        updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch;

  final String id;
  final String projectId;
  String content;
  String source;
  final int createdAt;
  int updatedAt;

  Map<String, dynamic> toMap() => {
        'id': id,
        'projectId': projectId,
        'content': content,
        'source': source,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  factory ProjectMemory.fromMap(Map<String, dynamic> map) => ProjectMemory(
        id: map['id'] as String,
        projectId: (map['projectId'] as String?) ?? '',
        content: (map['content'] as String?) ?? '',
        source: (map['source'] as String?) ?? 'manual',
        createdAt: (map['createdAt'] as int?) ?? 0,
        updatedAt: (map['updatedAt'] as int?) ?? 0,
      );
}

/// 斜杠命令：聊天输入 `/` 唤起的 prompt 模板。
/// scope: 'global' 或 'project:<id>'。
class SlashCommand {
  SlashCommand({
    required this.id,
    required this.name,
    required this.promptTemplate,
    this.scope = 'global',
    int? createdAt,
    int? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch,
        updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch;

  static const int maxTemplateLength = 4000;

  final String id;
  String name; // / 后的词，如 review
  String promptTemplate; // 支持 {{input}} 占位符
  String scope;
  final int createdAt;
  int updatedAt;

  bool get hasInputPlaceholder => promptTemplate.contains('{{input}}');

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'promptTemplate': promptTemplate,
        'scope': scope,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  factory SlashCommand.fromMap(Map<String, dynamic> map) => SlashCommand(
        id: map['id'] as String,
        name: (map['name'] as String?) ?? '',
        promptTemplate: (map['promptTemplate'] as String?) ?? '',
        scope: (map['scope'] as String?) ?? 'global',
        createdAt: (map['createdAt'] as int?) ?? 0,
        updatedAt: (map['updatedAt'] as int?) ?? 0,
      );
}
