import 'dart:convert';
import '../models/skill_models.dart';

/// SKILL.md 解析器
/// 格式：frontmatter (YAML) + 正文 (Markdown)
class SkillParser {
  /// 解析 SKILL.md 内容
  static ParsedSkill parse(String content) {
    final lines = content.split('\n');

    // 查找 frontmatter 边界
    if (lines.isEmpty || lines[0].trim() != '---') {
      throw const FormatException('SKILL.md 必须以 --- 开头');
    }

    int endIndex = -1;
    for (int i = 1; i < lines.length; i++) {
      if (lines[i].trim() == '---') {
        endIndex = i;
        break;
      }
    }

    if (endIndex == -1) {
      throw const FormatException('SKILL.md 缺少 frontmatter 结束标记 ---');
    }

    // 提取 frontmatter 和正文
    final frontmatterLines = lines.sublist(1, endIndex);
    final instruction = lines.sublist(endIndex + 1).join('\n').trim();

    if (instruction.isEmpty) {
      throw const FormatException('SKILL.md 正文不能为空');
    }

    // 解析 frontmatter (简单 YAML 解析)
    final metadata = _parseFrontmatter(frontmatterLines);

    return ParsedSkill(
      metadata: metadata,
      instruction: instruction,
      rawContent: content,
    );
  }

  /// 解析 frontmatter (简单 YAML)
  static SkillMetadata _parseFrontmatter(List<String> lines) {
    final map = <String, dynamic>{};

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;

      final colonIndex = trimmed.indexOf(':');
      if (colonIndex == -1) continue;

      final key = trimmed.substring(0, colonIndex).trim();
      var value = trimmed.substring(colonIndex + 1).trim();

      // 处理数组 (tags: [a, b, c])
      if (value.startsWith('[') && value.endsWith(']')) {
        final arrayContent = value.substring(1, value.length - 1);
        map[key] = arrayContent
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
      } else {
        // 处理字符串
        if (value.startsWith('"') && value.endsWith('"')) {
          value = value.substring(1, value.length - 1);
        } else if (value.startsWith("'") && value.endsWith("'")) {
          value = value.substring(1, value.length - 1);
        }
        map[key] = value;
      }
    }

    return SkillMetadata(
      name: map['name'] as String? ?? '',
      description: map['description'] as String? ?? '',
      version: map['version'] as String?,
      author: map['author'] as String?,
      homepage: map['homepage'] as String?,
      trigger: map['trigger'] as String?,
      tags: (map['tags'] as List?)?.cast<String>() ?? [],
    );
  }

  /// 从 JSON 解析（用于从公开市场获取的列表）
  static SkillMetadata parseMetadataFromJson(String jsonStr) {
    try {
      final map = json.decode(jsonStr) as Map<String, dynamic>;
      return SkillMetadata.fromJson(map);
    } catch (e) {
      throw FormatException('无法解析 Skill 元数据: $e');
    }
  }
}
