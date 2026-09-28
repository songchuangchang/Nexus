/// APP 更新检查服务（v1.7.12）
///
/// 从 GitHub Releases 查询最新版本，支持手动 + 启动自动检查。
/// 查询接口由 [kRepoReleaseApiLatest] 给（仓库地址只住 `repo_endpoints.dart` 一处）。
library app_update_service;

import 'dart:convert';
import 'package:http/http.dart' as http;

import 'repo_endpoints.dart';
import '../constants.dart' show kAppVersionConst;
import 'biometric_service.dart';
import 'file_open_service.dart';
import 'github_content_fetcher.dart';
import 'logger_service.dart';
import 'app_download_service.dart';

/// APP 更新信息
class AppUpdateInfo {
  final String currentVersion;
  final String latestVersion;
  final String latestTag;
  final String releaseNotes;
  final String apkUrl;
  final int apkSize; // bytes
  final bool hasUpdate;
  final String? publishedAt;

  /// S2（build172）：更新源自带 APK 的 SHA-256（64 位 hex，来自 Release 资产
  /// 的摘要字段）。null/空 = 源没提供 ⇒ [AppUpdateService.downloadAndInstall]
  /// 会 fail-closed 拒绝安装（防装上被篡改的包）。
  final String? sha256;

  const AppUpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.latestTag,
    required this.releaseNotes,
    required this.apkUrl,
    required this.apkSize,
    required this.hasUpdate,
    this.publishedAt,
    this.sha256,
  });
}

/// S2（build172）：GitHub Release 资产的 digest 字段 → 纯十六进制 sha256；
/// 格式不对返回 null。
///
/// GitHub API 资产摘要形如 `"sha256:bbbf8ec2..."`。规则：
/// null/空 → null；前缀（冒号前）大小写不敏感且必须是 sha256；hex 部分必须
/// 恰好 64 位十六进制字符，否则返回 null。顶层纯函数，单测直调。
String? parseGitHubDigest(Object? digest) {
  if (digest is! String) return null;
  final s = digest.trim();
  if (s.isEmpty) return null;
  final colon = s.indexOf(':');
  if (colon < 0) return null;
  final algo = s.substring(0, colon).trim().toLowerCase();
  if (algo != 'sha256') return null;
  final hex = s.substring(colon + 1).trim();
  if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hex)) return null;
  return hex.toLowerCase();
}

/// APP 更新检查服务
class AppUpdateService {
  static final LoggerService _logger = LoggerService.instance;
  static const _repoApiLatest = kRepoReleaseApiLatest;

  /// v1.7.13：启动静默检查 one-shot 守卫
  ///
  /// 触发背景：v1.7.12 把静默检查写在 main.dart FutureBuilder 的 builder 闭包里，
  /// 每次 rebuild 都注册新的 addPostFrameCallback，导致启动后 5 秒内重复打 5 次
  /// GitHub API（nexus_export_2026-08-25T10-51-47 日志可见）。
  ///
  /// 修复：用 static 标志保证「每次 app 进程只跑一次」启动静默检查。
  static bool _hasRunStartupSilentCheck = false;

  /// 启动静默检查是否已跑过（true=已跑过，不再重复）
  static bool get hasRunStartupSilentCheck => _hasRunStartupSilentCheck;

  /// 标记启动静默检查已跑（幂等：多次调用只生效一次）
  /// 调用方应在调 checkForUpdate 之前先调本方法判断是否需要继续。
  static void markStartupSilentCheckRun() {
    _hasRunStartupSilentCheck = true;
  }

  /// 仅供测试用：重置 one-shot 守卫，让单测之间互不影响
  static void resetSilentCheckGuardForTest() {
    _hasRunStartupSilentCheck = false;
  }

  /// 解析 pubspec 格式版本字符串 "1.7.11+58" → 语义化比较用 "1.7.11.58"
  /// 返回纯数字段列表
  static List<int> _parseVersion(String raw) {
    var s = raw.trim();
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    // 去掉 -beta 等预发布后缀
    final dash = s.indexOf('-');
    if (dash >= 0) s = s.substring(0, dash);
    // pubspec 的 +build 分隔："1.7.11+58" → ["1.7.11", "58"]
    final plus = s.indexOf('+');
    String mainPart;
    String buildPart = '';
    if (plus >= 0) {
      mainPart = s.substring(0, plus);
      buildPart = s.substring(plus + 1);
    } else {
      mainPart = s;
    }
    final parts =
        mainPart.split('.').map((e) => int.tryParse(e.trim()) ?? 0).toList();
    if (buildPart.isNotEmpty) {
      final buildNum = int.tryParse(buildPart.trim());
      if (buildNum != null) parts.add(buildNum);
    }
    return parts;
  }

  /// 版本比较：>0 表示 v1 > v2
  static int compareVersions(String v1, String v2) {
    final p1 = _parseVersion(v1);
    final p2 = _parseVersion(v2);
    final maxLen = p1.length > p2.length ? p1.length : p2.length;
    for (int i = 0; i < maxLen; i++) {
      final a = i < p1.length ? p1[i] : 0;
      final b = i < p2.length ? p2[i] : 0;
      if (a > b) return 1;
      if (a < b) return -1;
    }
    return 0;
  }

  /// 从最新 Release 的 assets 里找 .apk 结尾的
  static Map<String, dynamic>? _findApkAsset(List<dynamic> assets) {
    for (final a in assets) {
      final m = a as Map<String, dynamic>;
      final name = (m['name'] as String? ?? '').toLowerCase();
      if (name.endsWith('.apk')) return m;
    }
    return null;
  }

  /// 带代理回落的 HTTP GET（v1.7.38：统一走 GitHubContentFetcher 对冲链）
  static Future<http.Response> _getWithProxyFallback(String url) async {
    final bytes =
        await GitHubContentFetcher.fetchBytes(url, tag: 'update-check');
    return http.Response.bytes(bytes, 200);
  }

  /// 检查 APP 是否有新版本
  static Future<AppUpdateInfo> checkForUpdate() async {
    const current = kAppVersionConst;
    _logger.info('AppUpdate: 开始检查更新，当前版本 $current', tag: 'AppUpdate');

    try {
      final resp = await _getWithProxyFallback(_repoApiLatest);
      final data =
          jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;

      final tag = data['tag_name'] as String? ?? ''; // e.g. "v1.7.11+58"
      final releaseNotes = data['body'] as String? ?? '';
      final publishedAt = data['published_at'] as String?;
      final assets = data['assets'] as List<dynamic>? ?? [];
      final apk = _findApkAsset(assets);

      if (apk == null) {
        throw Exception('Release 中未找到 APK 资产');
      }

      final apkUrl = apk['browser_download_url'] as String? ?? '';
      final apkSize = apk['size'] as int? ?? 0;
      // S2（build172）：读取资产自带的完整性摘要（此前从未被读）
      final apkSha256 = parseGitHubDigest(apk['digest']);

      // tag 中解析出版本号："v1.7.11+58" → "1.7.11+58"
      var latest = tag;
      if (latest.startsWith('v') || latest.startsWith('V')) {
        latest = latest.substring(1);
      }
      final hasUpdate =
          latest.isNotEmpty && compareVersions(latest, current) > 0;

      _logger.info(
          'AppUpdate: 最新 $latest, 当前 $current, hasUpdate=$hasUpdate, '
          'apk=$apkUrl (${(apkSize / 1024 / 1024).toStringAsFixed(2)}MB), '
          'sha256=${apkSha256 == null ? 'missing' : 'ok'}',
          tag: 'AppUpdate');

      return AppUpdateInfo(
        currentVersion: current,
        latestVersion: latest,
        latestTag: tag,
        releaseNotes: releaseNotes,
        apkUrl: apkUrl,
        apkSize: apkSize,
        hasUpdate: hasUpdate,
        publishedAt: publishedAt,
        sha256: apkSha256,
      );
    } catch (e) {
      // build145：降到 WARN 且不写堆栈。原因不是「不重要」，而是**这条在正常配置下必然发生**：
      // 更新清单在私有仓库里（用户 09-22 明确「仓库不用管」），于是每次启动几乎注定 403/404，
      // 以 ERROR 面孔长期占着日志 ⇒ 真出问题（上游真断了）时反而看不出来。
      // 「过度上报」与「静默」是同一枚硬币的两面（build141 观察 B 同一族）。
      _logger.warn('AppUpdate: 检查更新失败（多为仓库私有/离线所致，属预期）: $e',
          tag: 'AppUpdate');
      return const AppUpdateInfo(
        currentVersion: current,
        latestVersion: current,
        latestTag: '',
        releaseNotes: '',
        apkUrl: '',
        apkSize: 0,
        hasUpdate: false,
      );
    }
  }

  /// 下载并安装更新 APK
  ///
  /// 返回下载结果 Map（含 fullPath / success 等字段）
  static Future<Map<String, dynamic>> downloadAndInstall(
    AppUpdateInfo info, {
    void Function(int received, int total)? onProgress,
  }) async {
    // S2（build172）：自更新 fail-closed —— 更新源没提供 SHA-256 一律拒绝安装，
    // 防止装上被篡改的 APK。放在路由探测（resolveBest）之前：无校验和直接拒绝，
    // 不发任何网络请求。有校验和时由下载器落盘后实算比对（见 verifyFileSha256）。
    if ((info.sha256 ?? '').trim().isEmpty) {
      _logger.error(
          'AppUpdate: 更新源未提供 SHA-256 校验和，已拒绝安装: ${info.apkUrl}',
          tag: 'AppUpdate');
      return {
        'success': false,
        'error': '更新源未提供 SHA-256 校验和，已拒绝安装（防止装上被篡改的包）',
      };
    }
    _logger.info('AppUpdate: 开始下载更新 v${info.latestVersion} → ${info.apkUrl}',
        tag: 'AppUpdate');
    // v1.7.38：大文件不对冲——先用 GitHubContentFetcher 串行探测选最优路由，
    // 再交给下载器单次下载（避免 100MB APK 多路并发浪费流量）
    final String effective;
    try {
      effective = await GitHubContentFetcher.resolveBest(info.apkUrl,
          tag: 'update-apk');
    } catch (e) {
      _logger.error('AppUpdate: 所有下载路径均不可用: $e', tag: 'AppUpdate');
      return {'success': false, 'error': e.toString()};
    }
    try {
      // AppDownloadService 是 Provider 级 ChangeNotifier，这里后台下载新建临时实例即可
      // （Provider 里的那个主要给 UI 监听，后台下载不需要共享它的监听）
      final dlSvc = AppDownloadService();
      final fileName = 'Nexus_v${info.latestVersion}_release.apk';
      final result = await dlSvc.downloadFileFromUrl(
        url: effective,
        fileName: fileName,
        onProgress: onProgress,
        taskId: 'app_update_${DateTime.now().millisecondsSinceEpoch}',
        // S2（build172）：把检查阶段拿到的校验和交给下载器，落盘后实算比对
        sha256Hex: info.sha256,
      );
      if (result['success'] != true) {
        _logger.error('AppUpdate: 下载失败: ${result['error']}', tag: 'AppUpdate');
        return result;
      }
      final fullPath = result['fullPath'] as String? ?? '';
      _logger.info('AppUpdate: 下载结束 success=true, path=$fullPath',
          tag: 'AppUpdate');
      if (fullPath.isNotEmpty) {
        // 尝试拉起 APK 安装器
        try {
          final r = await BiometricService.guardActivityTransition(
            () => FileOpenService.open(fullPath,
                type: 'application/vnd.android.package-archive'),
            fallbackDuration: const Duration(seconds: 120),
          );
          _logger.info('AppUpdate: 调安装器结果 status=${r.status} msg=${r.message}',
              tag: 'AppUpdate');
        } catch (e) {
          _logger.warn('AppUpdate: 拉起安装器失败: $e', tag: 'AppUpdate');
        }
      }
      return result;
    } catch (e) {
      _logger.error('AppUpdate: 下载更新异常: $e', error: e, tag: 'AppUpdate');
      return {'success': false, 'error': e.toString()};
    }
  }
}
