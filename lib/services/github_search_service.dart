import 'dart:convert';
import 'package:http/http.dart' as http;
import 'logger_service.dart';

// ---------- 数据模型（Dart 不支持嵌套类，必须顶层定义）----------
class GhRepo {
  final String owner;
  final String repo;
  final String fullName;
  final String description;
  final int stars;
  final String htmlUrl;
  GhRepo({
    required this.owner,
    required this.repo,
    required this.fullName,
    required this.description,
    required this.stars,
    required this.htmlUrl,
  });
}

class GhApkAsset {
  final String name;
  final String browserDownloadUrl;
  final int sizeBytes;
  final String contentType;
  final String? label;
  GhApkAsset({
    required this.name,
    required this.browserDownloadUrl,
    required this.sizeBytes,
    required this.contentType,
    this.label,
  });

  /// 尝试从文件名里识别架构，如 arm64-v8a / armeabi-v7a / x86_64 / x86 / universal
  String get arch {
    final n = name.toLowerCase();
    if (n.contains('arm64-v8a') || n.contains('arm64')) return 'arm64-v8a';
    if (n.contains('armeabi-v7a') ||
        n.contains('armeabi') ||
        n.contains('armv7')) {
      return 'armeabi-v7a';
    }
    if (n.contains('x86_64')) return 'x86_64';
    if (n.contains('x86') || n.contains('i386') || n.contains('i686')) {
      return 'x86';
    }
    if (n.contains('universal')) return 'universal';
    if (n.contains('arm')) return 'arm';
    return '';
  }

  /// arm64-v8a 优先 > universal > armeabi > x86_64 > x86 > 其它
  int get archPriority {
    switch (arch) {
      case 'arm64-v8a':
        return 0;
      case 'universal':
        return 1;
      case 'armeabi-v7a':
        return 2;
      case 'arm':
        return 3;
      case 'x86_64':
        return 4;
      case 'x86':
        return 5;
      default:
        return 9;
    }
  }
}

class GhRelease {
  final String tagName;
  final String name;
  final String htmlUrl;
  final String body; // changelog (markdown)
  final bool prerelease;
  final DateTime? publishedAt;
  final List<GhApkAsset> apkAssets;
  GhRelease({
    required this.tagName,
    required this.name,
    required this.htmlUrl,
    required this.body,
    required this.prerelease,
    required this.publishedAt,
    required this.apkAssets,
  });
}

class GhApkSource {
  final GhRepo repo;
  final GhRelease release;
  final GhApkAsset asset;

  GhApkSource({
    required this.repo,
    required this.release,
    required this.asset,
  });

  /// 展示给用户看的版本（优先 Release.name，其次 tag）
  String get displayVersion =>
      release.name.isNotEmpty ? release.name : release.tagName;

  String get changelog {
    final parts = <String>[
      'GitHub Release · repo: ${repo.fullName} (⭐${repo.stars})'
    ];
    if (release.prerelease) parts.add('[Pre-release]');
    if (repo.description.isNotEmpty) parts.add(repo.description);
    if (release.body.isNotEmpty) {
      var b = release.body.replaceAll('\r', '').trim();
      if (b.length > 300) b = '${b.substring(0, 300)}…';
      parts.add(b);
    }
    return parts.join('\n');
  }

  String get sizeMB {
    if (asset.sizeBytes <= 0) return 'unknown';
    return '${(asset.sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// GitHub Releases APK 搜索服务
/// 使用 GitHub 开放 REST API（匿名，60 次/小时/IP），无需 token
/// 文档：
///  - 搜索仓库：https://docs.github.com/en/rest/search/search#search-repositories
///  - 获取最新 Release：https://docs.github.com/en/rest/releases/releases#get-the-latest-release
class GitHubSearchService {
  static const _apiBase = 'https://api.github.com';
  static const _ua = 'AIChat-App/1.2 (+https://github.com)';
  static const _accept = 'application/vnd.github+json';
  static const _apiVersion = '2022-11-28';

  static final _logger = LoggerService.instance;

  // ---------- v1.3.4 新增：GitHub release asset 下载代理重写 ----------

  /// 把 GitHub release asset 的原始下载 URL 用代理重写
  /// 支持三种格式：
  ///   1) 模板型（含 {url} 占位符）：直接 replaceAll
  ///   2) 域名替换型（如 https://kkgithub.com、https://bgithub.xyz）：
  ///      把原 URL 的 `https://github.com` 替换成 proxy
  ///   3) 前缀型（默认，如 https://ghproxy.com）：直接拼 `proxy + '/' + 原 URL`
  /// proxy 为空/纯空格 → 返回原 URL（直连 github.com）
  static String rewriteDownloadUrl(String originalUrl, String proxy) {
    // v1.6.8 修复 Bug#12：删除 L153 的死代码（L151 已检查 proxy.trim().isEmpty 并返回，
    // L153 if (p.isEmpty) 永远 false）
    if (proxy.trim().isEmpty) return originalUrl;
    final p = proxy.trim();

    // 1) 模板型：含 {url}
    if (p.contains('{url}')) {
      return p.replaceAll('{url}', originalUrl);
    }

    // 统一去掉末尾斜杠
    String proxyClean = p;
    while (proxyClean.endsWith('/')) {
      proxyClean = proxyClean.substring(0, proxyClean.length - 1);
    }
    if (proxyClean.isEmpty) return originalUrl;

    // 2) 域名替换型：原 URL 以 https://github.com 开头，
    //    且 proxy 本身只是个域名（无 path 或只有 /），
    //    且 proxy 不含 github.com（否则会循环）
    if (originalUrl.startsWith('https://github.com/') &&
        !proxyClean.toLowerCase().contains('github.com')) {
      final uri = Uri.tryParse(proxyClean);
      if (uri != null && (uri.path.isEmpty || uri.path == '/')) {
        // proxy 是单域名 → 域名替换
        return originalUrl.replaceFirst('https://github.com', proxyClean);
      }
    }

    // 3) 前缀型（默认）
    return '$proxyClean/$originalUrl';
  }

  /// 判断某 URL 是不是 GitHub release 直链（用于 AppDownloadService 决定要不要存 originalDownloadUrl）
  static bool isGithubReleaseUrl(String url) {
    final u = url.toLowerCase();
    return u.startsWith('https://github.com/') ||
        u.startsWith('https://www.github.com/');
  }

  // ---------- 对外 API ----------

  /// 搜 APP 名 → 返回 GitHub Release 上的 APK 列表（已按架构优先级排序，arm64 第一）
  static Future<List<GhApkSource>> searchApk(String appName,
      {int maxRepos = 3}) async {
    _logger.info('[GitHub] Search APK for: "$appName"');

    final repos = await _searchRepos(appName, max: maxRepos);
    if (repos.isEmpty) {
      _logger.warn('[GitHub] No repositories matched');
      return [];
    }

    final results = <GhApkSource>[];
    for (final r in repos) {
      final release = await _getLatestRelease(r.owner, r.repo);
      if (release == null) continue;
      if (release.apkAssets.isEmpty) {
        _logger.info('[GitHub] ${r.fullName} latest release has no APK assets');
        continue;
      }
      // 按架构优先级排序（arm64 优先）
      final sorted = List<GhApkAsset>.from(release.apkAssets)
        ..sort((a, b) => a.archPriority.compareTo(b.archPriority));

      for (final asset in sorted) {
        results.add(GhApkSource(repo: r, release: release, asset: asset));
      }
    }

    _logger.info('[GitHub] Found ${results.length} APK sources');
    _logger.verbose(
        '[GitHub] APK sources for "$appName":\n${results.map((s) => '  - ${s.repo.fullName} / ${s.release.tagName} / ${s.asset.name} (${s.asset.browserDownloadUrl})').join('\n')}',
        tag: 'GH');
    return results;
  }

  // ---------- 内部 HTTP ----------

  static Map<String, String> get _headers => {
        'Accept': _accept,
        'User-Agent': _ua,
        'X-GitHub-Api-Version': _apiVersion,
      };

  /// 搜索 GitHub 仓库（按 stars 降序，优先 Android/Java/Kotlin）
  static Future<List<GhRepo>> _searchRepos(String q, {int max = 3}) async {
    try {
      final query = Uri.encodeComponent('$q android topic:android');
      final url =
          '$_apiBase/search/repositories?q=$query&sort=stars&order=desc&per_page=$max';

      final response = await http
          .get(Uri.parse(url), headers: _headers)
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        final bodySnippet = response.body.length <= 200
            ? response.body
            : response.body.substring(0, 200);
        _logger.warn(
            '[GitHub] search returned ${response.statusCode}: $bodySnippet');
        return [];
      }
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      final items = data['items'] as List<dynamic>? ?? [];
      final result = <GhRepo>[];
      for (final it in items) {
        final full = (it['full_name'] as String? ?? '').trim();
        final parts = full.split('/');
        if (parts.length != 2) continue;
        final desc = (it['description'] as String? ?? '').trim();

        // 过滤：必须看起来是 Android 项目
        final topics = (it['topics'] as List<dynamic>? ?? [])
            .map((e) => e.toString().toLowerCase())
            .toList();
        final langs = (it['language'] as String? ?? '').toLowerCase();
        final lookAndroid = topics.contains('android') ||
            langs == 'java' ||
            langs == 'kotlin' ||
            desc.toLowerCase().contains('android') ||
            q.toLowerCase().contains('github');

        if (!lookAndroid) continue;

        result.add(GhRepo(
          owner: parts[0],
          repo: parts[1],
          fullName: full,
          description: desc,
          stars: (it['stargazers_count'] as num?)?.toInt() ?? 0,
          htmlUrl: it['html_url'] as String? ?? '',
        ));
      }
      return result;
    } catch (e, st) {
      _logger.error('[GitHub] search failed', error: e, stack: st, tag: 'GH');
      return [];
    }
  }

  /// 获取最新 release，并从中提取 .apk 资源
  static Future<GhRelease?> _getLatestRelease(String owner, String repo) async {
    try {
      final url = '$_apiBase/repos/$owner/$repo/releases/latest';
      final response = await http
          .get(Uri.parse(url), headers: _headers)
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        _logger.info(
            '[GitHub] $owner/$repo releases/latest returned ${response.statusCode}');
        return null;
      }
      final d = jsonDecode(utf8.decode(response.bodyBytes));
      final assets = d['assets'] as List<dynamic>? ?? [];
      final apks = <GhApkAsset>[];
      for (final a in assets) {
        final name = (a['name'] as String? ?? '');
        final lowName = name.toLowerCase();
        if (!lowName.endsWith('.apk')) continue;
        final ct = (a['content_type'] as String? ?? '').toLowerCase();
        // APK 标准 MIME，或 octet-stream（有些作者传通用类型）都接受
        if (!ct.contains('android.package-archive') &&
            !ct.contains('octet-stream')) {
          continue;
        }

        apks.add(GhApkAsset(
          name: name.isEmpty ? 'unknown.apk' : name,
          browserDownloadUrl: a['browser_download_url'] as String? ?? '',
          sizeBytes: (a['size'] as num?)?.toInt() ?? 0,
          contentType: ct,
          label: a['label'] as String?,
        ));
      }

      final pubStr = d['published_at'] as String?;
      return GhRelease(
        tagName: d['tag_name'] as String? ?? '',
        name: d['name'] as String? ?? '',
        htmlUrl: d['html_url'] as String? ?? '',
        body: d['body'] as String? ?? '',
        prerelease: d['prerelease'] as bool? ?? false,
        publishedAt: pubStr != null ? DateTime.tryParse(pubStr) : null,
        apkAssets: apks,
      );
    } catch (e, st) {
      _logger.error('[GitHub] releases/latest failed $owner/$repo',
          error: e, stack: st, tag: 'GH');
      return null;
    }
  }
}
