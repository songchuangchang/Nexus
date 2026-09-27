import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/skill_models.dart';
import 'github_content_fetcher.dart';
import 'logger_service.dart';

/// Skill 市场服务
/// 从公开数据源获取 SKILL.md 技能列表
///
/// 数据源优先级（v1.7.8 调整）：
/// 1. SkillsMP API（实测可用，数据最全）
/// 2. GitHub 仓库搜索（无需认证，60 次/小时）
///
/// v1.7.8 修复两个致命问题：
/// - GitHub /search/code 匿名调用必返回 401（该接口需要认证），
///   改用 /search/repositories 搜仓库再拼 raw SKILL.md 直链
/// - SkillsMP 实际返回结构是 {success, data: {skills: [...]}}（嵌套），
///   旧代码读顶层 data['skills'] → 永远为空；
///   且字段是 githubUrl/skillUrl/stars，不是 downloadUrl/sourceUrl
class SkillRegistryService {
  static final LoggerService _logger = LoggerService.instance;

  /// 获取技能列表（多源 fallback）
  static Future<List<SkillMarketItem>> fetchSkills({
    String? search,
    int limit = 50,
  }) async {
    final query =
        (search != null && search.trim().isNotEmpty) ? search.trim() : 'skill';

    // 源 1：SkillsMP API（实测可用，数据最全）
    try {
      final skills = await _fetchFromSkillsMP(query, limit);
      if (skills.isNotEmpty) {
        _logger.info('SkillsMP 获取 ${skills.length} 个 Skill', tag: 'Skill');
        return skills;
      }
    } catch (e) {
      _logger.error('SkillsMP 失败: $e', tag: 'Skill');
    }

    // 源 2：GitHub 仓库搜索（无需认证）
    try {
      final skills = await _fetchFromGitHub(query, limit);
      if (skills.isNotEmpty) {
        _logger.info('GitHub 搜索获取 ${skills.length} 个 Skill', tag: 'Skill');
        return skills;
      }
    } catch (e) {
      _logger.error('GitHub 搜索失败: $e', tag: 'Skill');
    }

    _logger.error('所有 Skill 数据源均失败，返回列表为空', tag: 'Skill');
    return [];
  }

  /// 源 1：SkillsMP API
  ///
  /// 实测（2026-08-24）返回格式：
  /// {
  ///   "success": true,
  ///   "data": {
  ///     "skills": [{
  ///       "id": "openclaw-openclaw-skills-skill-creator-skill-md",
  ///       "name": "skill-creator",
  ///       "author": "openclaw",
  ///       "description": "...",
  ///       "githubUrl": "https://github.com/{owner}/{repo}/tree/{branch}/{path}",
  ///       "skillUrl": "https://skillsmp.com/creators/...",
  ///       "stars": 386620,
  ///       "updatedAt": 1786437360
  ///     }]
  ///   }
  /// }
  ///
  /// githubUrl → SKILL.md raw 直链转换：
  /// https://github.com/o/r/tree/main/skills/foo
  /// → https://raw.githubusercontent.com/o/r/main/skills/foo/SKILL.md
  static Future<List<SkillMarketItem>> _fetchFromSkillsMP(
      String query, int limit) async {
    final uri = Uri.https('skillsmp.com', '/api/v1/skills/search', {
      'q': query,
      'limit': limit.toString(),
      'sortBy': 'stars',
    });

    _logger.info('SkillsMP 搜索 Skill: $query', tag: 'Skill');

    final response = await http.get(uri, headers: {
      'Accept': 'application/json',
      'User-Agent': 'Nexus-App/1.0',
    }).timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      _logger.error('SkillsMP API 返回 ${response.statusCode}', tag: 'Skill');
      return [];
    }

    final data = json.decode(response.body) as Map<String, dynamic>;
    final success = data['success'] as bool? ?? false;
    if (!success) {
      _logger.error('SkillsMP 返回 success=false', tag: 'Skill');
      return [];
    }

    // v1.7.8：skills 嵌套在 data.data.skills（兼容旧版顶层 skills）
    List<dynamic> skillsData;
    final dataNode = data['data'];
    if (dataNode is Map<String, dynamic> && dataNode['skills'] is List) {
      skillsData = dataNode['skills'] as List<dynamic>;
    } else {
      skillsData = (data['skills'] as List<dynamic>?) ?? [];
    }

    final skills = <SkillMarketItem>[];
    for (final item in skillsData) {
      if (item is! Map<String, dynamic>) continue;
      try {
        final name = (item['name'] as String? ?? '').trim();
        if (name.isEmpty) continue;
        final description = item['description'] as String? ?? '';
        final author = (item['author'] as String? ?? '').trim();
        final githubUrl = (item['githubUrl'] as String? ?? '').trim();
        final skillUrl = (item['skillUrl'] as String? ?? '').trim();
        final stars = item['stars'];

        // githubUrl → raw SKILL.md 直链
        String downloadUrl = _githubTreeUrlToRawSkillMd(githubUrl);
        // 兼容直传 downloadUrl 字段的数据源
        final directUrl = (item['downloadUrl'] as String? ?? '').trim();
        if (directUrl.isNotEmpty) downloadUrl = directUrl;

        if (downloadUrl.isEmpty) continue;

        final tags = <String>['skillsmp'];
        if (stars is int && stars > 0) tags.add('★$stars');

        skills.add(SkillMarketItem(
          name: name,
          description: description,
          author: author.isNotEmpty ? author : 'unknown',
          homepage: skillUrl.isNotEmpty ? skillUrl : githubUrl,
          downloadUrl: downloadUrl,
          tags: tags,
        ));
      } catch (e) {
        _logger.error('解析 SkillsMP Skill 失败: $e', tag: 'Skill');
      }
    }
    return skills;
  }

  /// https://github.com/{owner}/{repo}/tree/{branch}/{path}
  /// → https://raw.githubusercontent.com/{owner}/{repo}/{branch}/{path}/SKILL.md
  /// 非法输入返回空串
  static String _githubTreeUrlToRawSkillMd(String githubUrl) {
    if (!githubUrl.startsWith('https://github.com/')) return '';
    final path = githubUrl.substring('https://github.com/'.length);
    final rawPath =
        path.contains('/tree/') ? path.replaceFirst('/tree/', '/') : path;
    return 'https://raw.githubusercontent.com/$rawPath/SKILL.md';
  }

  /// 源 2：GitHub 仓库搜索（无需认证，60 次/小时）
  /// v1.7.8：/search/code 匿名返回 401（需认证），改用 /search/repositories
  /// 返回的是仓库列表，下载地址拼仓库根目录的 SKILL.md（HEAD 兜底任意默认分支）
  static Future<List<SkillMarketItem>> _fetchFromGitHub(
      String query, int limit) async {
    final uri = Uri.https('api.github.com', '/search/repositories', {
      'q': 'claude skill $query',
      'sort': 'stars',
      'order': 'desc',
      'per_page': limit.toString(),
    });

    _logger.info('GitHub 仓库搜索 Skill: $query', tag: 'Skill');

    final response = await http.get(uri, headers: {
      'Accept': 'application/vnd.github.v3+json',
      'User-Agent': 'Nexus-App/1.0',
    }).timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      _logger.error('GitHub API 返回 ${response.statusCode}', tag: 'Skill');
      return [];
    }

    final data = json.decode(response.body) as Map<String, dynamic>;
    final items = (data['items'] as List<dynamic>?) ?? [];

    final skills = <SkillMarketItem>[];
    for (final item in items) {
      if (item is! Map<String, dynamic>) continue;
      try {
        final repoFullName = (item['full_name'] as String? ?? '').trim();
        if (repoFullName.isEmpty) continue;
        final description =
            item['description'] as String? ?? 'SKILL.md from $repoFullName';
        final repoUrl = item['html_url'] as String? ?? '';
        final stars = item['stargazers_count'] as int? ?? 0;

        skills.add(SkillMarketItem(
          name: repoFullName.split('/').last,
          description: description,
          author: repoFullName.split('/').first,
          homepage: repoUrl,
          downloadUrl:
              'https://raw.githubusercontent.com/$repoFullName/HEAD/SKILL.md',
          tags: ['github', if (stars > 0) '★$stars'],
        ));
      } catch (e) {
        _logger.error('解析 GitHub Skill 失败: $e', tag: 'Skill');
      }
    }
    return skills;
  }

  /// 下载 SKILL.md 内容
  ///
  /// v1.7.38：统一走 GitHubContentFetcher（对冲并发+成功记忆+超时拆分+全链路日志）。
  /// - [proxyUrl] 来自 WebSearchConfig.githubProxyUrl，非空时作最高优先级覆盖候选。
  /// - 全失败抛中文 Exception（调用方 plugin_market_screen catch 已用 $error 拼 SnackBar 透传）。
  static Future<String> downloadSkillContent(String url,
      {String proxyUrl = ''}) async {
    _logger.info('下载技能内容: $url', tag: 'Skill');
    try {
      return await GitHubContentFetcher.fetchString(
        url,
        userProxy: proxyUrl,
        headers: const {'Accept': 'text/markdown, text/plain, */*'},
        tag: 'skill-content',
      );
    } on TimeoutException {
      throw Exception('下载超时，请检查网络');
    } catch (e) {
      _logger.error('下载技能异常: $e', tag: 'Skill');
      throw Exception('下载失败：$e');
    }
  }

  /// 测试连接（用 GitHub API 作为连通性检测）
  static Future<bool> testConnection() async {
    try {
      final response = await http.get(
        Uri.parse('https://api.github.com/rate_limit'),
        headers: {'User-Agent': 'Nexus-App/1.0'},
      ).timeout(const Duration(seconds: 5));
      return response.statusCode == 200;
    } catch (e) {
      _logger.error('测试连接失败: $e', tag: 'Skill');
      return false;
    }
  }
}
