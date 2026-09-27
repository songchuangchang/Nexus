/// v1.7.3 Skill 市场模型
/// 支持从公开市场（skills.sh / Agent Skill Exchange）获取 SKILL.md 格式的技能
library skill_models;

/// Skill 元数据（从 SKILL.md frontmatter 解析）
class SkillMetadata {
  final String name;
  final String description;
  final String? version;
  final String? author;
  final String? homepage;
  final String? trigger; // 触发条件（如 "user mentions translate"）
  final List<String> tags;

  const SkillMetadata({
    required this.name,
    required this.description,
    this.version,
    this.author,
    this.homepage,
    this.trigger,
    this.tags = const [],
  });

  factory SkillMetadata.fromJson(Map<String, dynamic> json) {
    return SkillMetadata(
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      version: json['version'] as String?,
      author: json['author'] as String?,
      homepage: json['homepage'] as String?,
      trigger: json['trigger'] as String?,
      tags: (json['tags'] as List<dynamic>?)?.cast<String>() ?? [],
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        if (version != null) 'version': version,
        if (author != null) 'author': author,
        if (homepage != null) 'homepage': homepage,
        if (trigger != null) 'trigger': trigger,
        'tags': tags,
      };
}

/// 已解析的 Skill（包含元数据 + 指令正文）
class ParsedSkill {
  final SkillMetadata metadata;
  final String instruction; // Markdown 正文（作为 promptProtocol）
  final String rawContent; // 原始 SKILL.md 内容

  const ParsedSkill({
    required this.metadata,
    required this.instruction,
    required this.rawContent,
  });

  /// 生成 plugin id（基于 name）
  /// v1.7.9 (M16 修复)：纯中文/非 ASCII 名字清洗后全部坍缩为 'skill._' →
  /// 多个此类 Skill 互相覆盖（ConflictAlgorithm.replace）。清洗结果无字母数字时追加
  /// 无符号 hashCode 保证唯一
  String get pluginId => pluginIdFor(metadata.name);

  /// v1.7.9 (M12 修复)：抽出统一的 ID 生成逻辑
  /// 市场卡片判断"已安装"与安装流程必须用同一算法，否则 ID 不一致 → 装完仍显示可安装
  static String pluginIdFor(String name) {
    final cleaned = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (cleaned.isEmpty) {
      final hash = name.hashCode.toUnsigned(32).toRadixString(36);
      return 'skill._$hash';
    }
    return 'skill.$cleaned';
  }
}

/// Skill 市场列表项（从公开市场获取）
class SkillMarketItem {
  final String name;
  final String description;
  final String? version;
  final String? author;
  final String? homepage;
  final String downloadUrl; // SKILL.md 下载地址
  final List<String> tags;
  final int? installCount; // 安装量（skills.sh 有）

  const SkillMarketItem({
    required this.name,
    required this.description,
    this.version,
    this.author,
    this.homepage,
    required this.downloadUrl,
    this.tags = const [],
    this.installCount,
  });

  factory SkillMarketItem.fromJson(Map<String, dynamic> json) {
    return SkillMarketItem(
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      version: json['version'] as String?,
      author: json['author'] as String?,
      homepage: json['homepage'] as String?,
      downloadUrl:
          json['downloadUrl'] as String? ?? json['url'] as String? ?? '',
      tags: (json['tags'] as List<dynamic>?)?.cast<String>() ?? [],
      installCount: json['installCount'] as int?,
    );
  }
}
