/// 安全审查服务
///
/// 支持三种审查后端：
///   1) SkillSpector — 审查 Skill (SKILL.md) 和 MCP 插件安全性
///   2) MobSF — 审查 APK 安装包安全性
library security_scan_service;

///   3) VirusTotal — 云端哈希查毒（免费 API Key 500次/天，v1.7.11 新增）
///
/// 用户在设置页配置 endpoint 并启用/禁用审查开关。
/// 安装前自动调用审查，展示风险评分。

import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'logger_service.dart';

/// 审查结果严重程度
enum SecuritySeverity {
  info,
  low,
  medium,
  high,
  critical,
}

/// 单个审查发现
class SecurityFinding {
  final String id;
  final String title;
  final String description;
  final SecuritySeverity severity;
  final String category;

  const SecurityFinding({
    required this.id,
    required this.title,
    required this.description,
    required this.severity,
    required this.category,
  });

  factory SecurityFinding.fromJson(Map<String, dynamic> json) {
    return SecurityFinding(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? json['finding'] as String? ?? '',
      description:
          json['description'] as String? ?? json['detail'] as String? ?? '',
      severity: _parseSeverity(json['severity'] as String? ?? ''),
      category: json['category'] as String? ?? json['type'] as String? ?? '',
    );
  }

  static SecuritySeverity _parseSeverity(String s) {
    switch (s.toLowerCase()) {
      case 'critical':
        return SecuritySeverity.critical;
      case 'high':
        return SecuritySeverity.high;
      case 'medium':
      case 'moderate':
        return SecuritySeverity.medium;
      case 'low':
        return SecuritySeverity.low;
      default:
        return SecuritySeverity.info;
    }
  }
}

/// 安全审查结果
class SecurityScanResult {
  final bool success;
  final String errorMessage;
  final int riskScore; // 0-100
  final SecuritySeverity severity;
  final bool safeToInstall;
  final List<SecurityFinding> findings;
  final String rawResponse;
  final Duration scanDuration;

  const SecurityScanResult({
    required this.success,
    this.errorMessage = '',
    this.riskScore = 0,
    this.severity = SecuritySeverity.info,
    this.safeToInstall = true,
    this.findings = const [],
    this.rawResponse = '',
    this.scanDuration = Duration.zero,
  });

  /// 风险等级标签（中文）
  String get riskLabelZh {
    if (riskScore <= 20) return '低风险';
    if (riskScore <= 50) return '中风险';
    if (riskScore <= 80) return '高风险';
    return '极高风险';
  }

  /// 风险等级标签（英文）
  String get riskLabelEn {
    if (riskScore <= 20) return 'Low Risk';
    if (riskScore <= 50) return 'Medium Risk';
    if (riskScore <= 80) return 'High Risk';
    return 'Critical Risk';
  }

  /// 风险等级颜色
  String get riskColor {
    if (riskScore <= 20) return 'green';
    if (riskScore <= 50) return 'orange';
    if (riskScore <= 80) return 'red';
    return 'darkred';
  }
}

/// 安全审查服务
class SecurityScanService {
  static final LoggerService _logger = LoggerService.instance;

  /// 审查 Skill (SKILL.md 内容)
  ///
  /// [skillspectorEndpoint] SkillSpector 服务地址，如 http://192.168.1.100:8000
  /// [skillContent] SKILL.md 的完整内容
  /// [skillName] Skill 名称（用于日志）
  static Future<SecurityScanResult> scanSkill({
    required String skillspectorEndpoint,
    required String skillContent,
    String skillName = '',
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      _logger.info('开始审查 Skill: $skillName', tag: 'SecurityScan');

      final endpoint =
          skillspectorEndpoint.trim().replaceAll(RegExp(r'/+$'), '');
      final uri = Uri.parse('$endpoint/api/v1/scan');

      final response = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({
              'type': 'skill',
              'content': skillContent,
              'name': skillName,
            }),
          )
          .timeout(const Duration(seconds: 30));

      stopwatch.stop();

      if (response.statusCode != 200) {
        _logger.error('SkillSpector 返回 ${response.statusCode}',
            tag: 'SecurityScan');
        return SecurityScanResult(
          success: false,
          errorMessage: 'HTTP ${response.statusCode}',
          scanDuration: stopwatch.elapsed,
        );
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return _parseSkillSpectorResponse(data, stopwatch.elapsed);
    } catch (e) {
      stopwatch.stop();
      _logger.error('Skill 审查失败: $e', tag: 'SecurityScan');
      return SecurityScanResult(
        success: false,
        errorMessage: e.toString(),
        scanDuration: stopwatch.elapsed,
      );
    }
  }

  /// 审查 MCP 插件
  ///
  /// [skillspectorEndpoint] SkillSpector 服务地址
  /// [toolsJson] MCP 工具定义的 JSON 字符串
  /// [serverName] MCP 服务器名称
  /// [endpoint] MCP 服务端点 URL
  static Future<SecurityScanResult> scanMcp({
    required String skillspectorEndpoint,
    required String toolsJson,
    String serverName = '',
    String endpoint = '',
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      _logger.info('开始审查 MCP: $serverName', tag: 'SecurityScan');

      final uri = Uri.parse(
          '${skillspectorEndpoint.trim().replaceAll(RegExp(r'/+$'), '')}/api/v1/scan');

      final response = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({
              'type': 'mcp',
              'tools': toolsJson,
              'server_name': serverName,
              'endpoint': endpoint,
            }),
          )
          .timeout(const Duration(seconds: 30));

      stopwatch.stop();

      if (response.statusCode != 200) {
        _logger.error('SkillSpector MCP 审查返回 ${response.statusCode}',
            tag: 'SecurityScan');
        return SecurityScanResult(
          success: false,
          errorMessage: 'HTTP ${response.statusCode}',
          scanDuration: stopwatch.elapsed,
        );
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return _parseSkillSpectorResponse(data, stopwatch.elapsed);
    } catch (e) {
      stopwatch.stop();
      _logger.error('MCP 审查失败: $e', tag: 'SecurityScan');
      return SecurityScanResult(
        success: false,
        errorMessage: e.toString(),
        scanDuration: stopwatch.elapsed,
      );
    }
  }

  /// 审查 APK 文件
  ///
  /// [mobsfEndpoint] MobSF 服务地址，如 http://192.168.1.100:8080
  /// [apkFilePath] APK 文件本地路径
  /// [apkName] APK 名称（用于日志）
  /// [mobsfApiKey] MobSF API Key（v1.7.11 P0 修复：自部署也可能要求认证）
  static Future<SecurityScanResult> scanApk({
    required String mobsfEndpoint,
    required String apkFilePath,
    String apkName = '',
    String mobsfApiKey = '',
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      _logger.info('开始审查 APK: $apkName', tag: 'SecurityScan');

      final endpoint = mobsfEndpoint.trim().replaceAll(RegExp(r'/+$'), '');
      final authHeaders = <String, String>{
        'Content-Type': 'application/json',
        if (mobsfApiKey.isNotEmpty) 'Authorization': mobsfApiKey,
      };

      // 1. 上传 APK
      final uploadUri = Uri.parse('$endpoint/api/v1/upload');
      final uploadRequest = http.MultipartRequest('POST', uploadUri);
      if (mobsfApiKey.isNotEmpty) {
        uploadRequest.headers['Authorization'] = mobsfApiKey;
      }
      uploadRequest.files
          .add(await http.MultipartFile.fromPath('file', apkFilePath));

      final uploadResponse =
          await uploadRequest.send().timeout(const Duration(seconds: 60));
      if (uploadResponse.statusCode != 200) {
        _logger.error('MobSF 上传失败: ${uploadResponse.statusCode}',
            tag: 'SecurityScan');
        return SecurityScanResult(
          success: false,
          errorMessage: 'Upload failed: HTTP ${uploadResponse.statusCode}',
          scanDuration: stopwatch.elapsed,
        );
      }

      final uploadData = jsonDecode(await uploadResponse.stream.bytesToString())
          as Map<String, dynamic>;
      final scanHash = uploadData['hash'] as String? ?? '';
      if (scanHash.isEmpty) {
        return SecurityScanResult(
          success: false,
          errorMessage: 'MobSF 未返回 hash',
          scanDuration: stopwatch.elapsed,
        );
      }

      // 2. 触发扫描
      final scanUri = Uri.parse('$endpoint/api/v1/scan');
      final scanResponse = await http
          .post(
            scanUri,
            headers: authHeaders,
            body: jsonEncode({'hash': scanHash, 're_scan': true}),
          )
          .timeout(const Duration(seconds: 120));

      if (scanResponse.statusCode != 200) {
        _logger.error('MobSF 扫描失败: ${scanResponse.statusCode}',
            tag: 'SecurityScan');
        return SecurityScanResult(
          success: false,
          errorMessage: 'Scan failed: HTTP ${scanResponse.statusCode}',
          scanDuration: stopwatch.elapsed,
        );
      }

      // 3. 轮询获取完整报告（v1.7.11 P0 修复：/api/v1/scan 是异步的，需轮询到完成）
      Map<String, dynamic>? reportData;
      for (var i = 0; i < 10; i++) {
        await Future.delayed(const Duration(seconds: 3));
        final reportUri =
            Uri.parse('$endpoint/api/v1/report_json?hash=$scanHash');
        final reportResponse = await http
            .get(
              reportUri,
              headers: authHeaders,
            )
            .timeout(const Duration(seconds: 30));

        if (reportResponse.statusCode == 200) {
          final data = jsonDecode(reportResponse.body) as Map<String, dynamic>;
          final status = data['status'] as String? ?? '';
          _logger.info('MobSF 轮询 #$i: status=$status',
              cat: LogCat.db, tag: 'SecurityScan');
          if (status == 'completed' || status == 'success') {
            reportData = data;
            break;
          }
        }
      }

      stopwatch.stop();
      if (reportData == null) {
        return SecurityScanResult(
          success: false,
          errorMessage: 'MobSF 扫描超时：轮询 10 次仍未完成',
          scanDuration: stopwatch.elapsed,
        );
      }
      return _parseMobSFResponse(reportData, stopwatch.elapsed);
    } catch (e) {
      stopwatch.stop();
      _logger.error('APK 审查失败: $e', tag: 'SecurityScan');
      return SecurityScanResult(
        success: false,
        errorMessage: e.toString(),
        scanDuration: stopwatch.elapsed,
      );
    }
  }

  /// VirusTotal 云端哈希查毒（v1.7.11 新增）
  ///
  /// [apiKey] VirusTotal API Key（免费注册 500次/天）
  /// [filePath] 文件本地路径
  /// [fileName] 文件名（用于日志）
  ///
  /// 流程：算 SHA-256 → GET /api/v3/files/{hash} 哈希查询（秒回不上传）
  /// 哈希未命中（404）→ 返回 notFound=true，调用方可决定是否上传文件本体
  static Future<SecurityScanResult> scanFileWithVirusTotal({
    required String apiKey,
    required String filePath,
    String fileName = '',
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      _logger.info('VirusTotal 查毒开始: $fileName', tag: 'SecurityScan');

      // 1. 计算 SHA-256
      final file = File(filePath);
      final bytes = await file.readAsBytes();
      final hash = sha256.convert(bytes);
      final sha256Hex = hash.toString();
      _logger.info('VirusTotal SHA-256: $sha256Hex',
          cat: LogCat.db, tag: 'SecurityScan');

      // 2. 哈希查询
      final uri =
          Uri.parse('https://www.virustotal.com/api/v3/files/$sha256Hex');
      final response = await http.get(
        uri,
        headers: {'x-apikey': apiKey},
      ).timeout(const Duration(seconds: 15));

      stopwatch.stop();

      if (response.statusCode == 404) {
        // 哈希未命中：VirusTotal 数据库中没有此文件
        _logger.info('VirusTotal 哈希未命中: $fileName', tag: 'SecurityScan');
        return SecurityScanResult(
          success: true,
          riskScore: 0,
          severity: SecuritySeverity.info,
          safeToInstall: true,
          findings: [
            const SecurityFinding(
              id: 'vt-not-found',
              title: 'VirusTotal 数据库未收录',
              description:
                  '此文件未被 VirusTotal 扫描过，无法判定安全性。可手动上传到 virustotal.com 查询。',
              severity: SecuritySeverity.info,
              category: 'virustotal',
            ),
          ],
          rawResponse: '{"hash":"$sha256Hex","found":false}',
          scanDuration: stopwatch.elapsed,
        );
      }

      if (response.statusCode != 200) {
        _logger.error('VirusTotal 返回 ${response.statusCode}',
            tag: 'SecurityScan');
        return SecurityScanResult(
          success: false,
          errorMessage: 'HTTP ${response.statusCode}',
          scanDuration: stopwatch.elapsed,
        );
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return _parseVirusTotalResponse(data, sha256Hex, stopwatch.elapsed);
    } catch (e) {
      stopwatch.stop();
      _logger.error('VirusTotal 查毒失败: $e', tag: 'SecurityScan');
      return SecurityScanResult(
        success: false,
        errorMessage: e.toString(),
        scanDuration: stopwatch.elapsed,
      );
    }
  }

  /// 测试 VirusTotal API Key 有效性
  static Future<(bool, String, int)> testVirusTotalConnection(
      String apiKey) async {
    final stopwatch = Stopwatch()..start();
    try {
      final uri = Uri.parse('https://www.virustotal.com/api/v3/users/me');
      final response = await http.get(
        uri,
        headers: {'x-apikey': apiKey},
      ).timeout(const Duration(seconds: 10));
      stopwatch.stop();
      if (response.statusCode == 200) {
        return (
          true,
          'API Key 有效 (${stopwatch.elapsed.inMilliseconds}ms)',
          stopwatch.elapsed.inMilliseconds
        );
      }
      return (
        false,
        'HTTP ${response.statusCode} - Key 无效或过期',
        stopwatch.elapsed.inMilliseconds
      );
    } catch (e) {
      stopwatch.stop();
      return (false, '连接失败: $e', stopwatch.elapsed.inMilliseconds);
    }
  }

  /// 测试 SkillSpector 连接
  static Future<(bool, String, int)> testSkillSpectorConnection(
      String endpoint) async {
    final stopwatch = Stopwatch()..start();
    try {
      final uri =
          Uri.parse('${endpoint.trim().replaceAll(RegExp(r'/+$'), '')}/health');
      final response = await http.get(uri).timeout(const Duration(seconds: 5));
      stopwatch.stop();
      if (response.statusCode == 200) {
        return (
          true,
          '连接成功 (${stopwatch.elapsed.inMilliseconds}ms)',
          stopwatch.elapsed.inMilliseconds
        );
      }
      return (
        false,
        'HTTP ${response.statusCode}',
        stopwatch.elapsed.inMilliseconds
      );
    } catch (e) {
      stopwatch.stop();
      return (false, '连接失败: $e', stopwatch.elapsed.inMilliseconds);
    }
  }

  /// 测试 MobSF 连接
  static Future<(bool, String, int)> testMobSFConnection(
      String endpoint) async {
    final stopwatch = Stopwatch()..start();
    try {
      final uri = Uri.parse(
          '${endpoint.trim().replaceAll(RegExp(r'/+$'), '')}/api/v1/server_info');
      final response = await http.get(uri).timeout(const Duration(seconds: 5));
      stopwatch.stop();
      if (response.statusCode == 200) {
        return (
          true,
          '连接成功 (${stopwatch.elapsed.inMilliseconds}ms)',
          stopwatch.elapsed.inMilliseconds
        );
      }
      return (
        false,
        'HTTP ${response.statusCode}',
        stopwatch.elapsed.inMilliseconds
      );
    } catch (e) {
      stopwatch.stop();
      return (false, '连接失败: $e', stopwatch.elapsed.inMilliseconds);
    }
  }

  /// 解析 SkillSpector 响应
  static SecurityScanResult _parseSkillSpectorResponse(
      Map<String, dynamic> data, Duration duration) {
    final riskScore = (data['risk_score'] as num?)?.toInt() ?? 0;
    final severity =
        SecurityFinding._parseSeverity(data['severity'] as String? ?? '');
    final safeToInstall = data['safe_to_install'] as bool? ?? (riskScore <= 50);

    final findingsList = <SecurityFinding>[];
    final findings = data['findings'] as List<dynamic>? ?? [];
    for (final f in findings) {
      if (f is Map<String, dynamic>) {
        findingsList.add(SecurityFinding.fromJson(f));
      }
    }

    return SecurityScanResult(
      success: true,
      riskScore: riskScore,
      severity: severity,
      safeToInstall: safeToInstall,
      findings: findingsList,
      rawResponse: jsonEncode(data),
      scanDuration: duration,
    );
  }

  /// 解析 MobSF 响应（v1.7.11 P1 修复：响应格式调整）
  static SecurityScanResult _parseMobSFResponse(
      Map<String, dynamic> data, Duration duration) {
    // MobSF 返回的格式与 SkillSpector 不同，需要转换
    final riskScore = _calculateMobSFRiskScore(data);
    final severity = _parseMobSFSeverity(data);
    final safeToInstall = riskScore <= 50;

    final findingsList = <SecurityFinding>[];

    // 解析权限问题
    final permissions = data['permissions'] as Map<String, dynamic>? ?? {};
    for (final entry in permissions.entries) {
      final permData = entry.value as Map<String, dynamic>? ?? {};
      final status = permData['status'] as String? ?? '';
      if (status == 'dangerous' || status == 'sensitive') {
        findingsList.add(SecurityFinding(
          id: 'perm_${entry.key}',
          title: '危险权限: ${entry.key}',
          description: permData['description'] as String? ?? '',
          severity: status == 'dangerous'
              ? SecuritySeverity.high
              : SecuritySeverity.medium,
          category: 'permissions',
        ));
      }
    }

    // 解析代码问题（v1.7.11 P1 修复：MobSF v4 findings 在 vulnerabilities.findings 下）
    final vulnerabilities = data['vulnerabilities'] as Map<String, dynamic>?;
    // v1.7.16 修复：MobSF findings 可能是 List 或 Map，`as Map` 优先级高于 `??`，
    // List 时会在短路前抛 CastError 被外层 catch 吞掉 → 安全审查静默失效。
    // 改为先取原始值再判断类型，非 Map 一律给空表，不抛异常。
    final rawFindings = vulnerabilities?['findings'] ?? data['findings'];
    final findings = rawFindings is Map
        ? Map<String, dynamic>.from(rawFindings)
        : <String, dynamic>{};
    for (final entry in findings.entries) {
      final findingData = entry.value as Map<String, dynamic>? ?? {};
      final severityStr = findingData['severity'] as String? ?? 'info';
      findingsList.add(SecurityFinding(
        id: entry.key,
        title: findingData['metadata']?['title'] as String? ?? entry.key,
        description: findingData['detailed_desc'] as String? ?? '',
        severity: SecurityFinding._parseSeverity(severityStr),
        category: findingData['category'] as String? ?? 'code',
      ));
    }

    return SecurityScanResult(
      success: true,
      riskScore: riskScore,
      severity: severity,
      safeToInstall: safeToInstall,
      findings: findingsList,
      rawResponse: jsonEncode(data),
      scanDuration: duration,
    );
  }

  /// 解析 VirusTotal 响应（v1.7.11 新增）
  static SecurityScanResult _parseVirusTotalResponse(
    Map<String, dynamic> data,
    String sha256Hash,
    Duration duration,
  ) {
    final attributes = data['data']?['attributes'] as Map<String, dynamic>?;
    if (attributes == null) {
      return SecurityScanResult(
        success: false,
        errorMessage: 'VirusTotal 响应格式异常：缺少 data.attributes',
        scanDuration: duration,
      );
    }

    final stats =
        attributes['last_analysis_stats'] as Map<String, dynamic>? ?? {};
    final malicious = (stats['malicious'] as num?)?.toInt() ?? 0;
    final suspicious = (stats['suspicious'] as num?)?.toInt() ?? 0;
    final undetected = (stats['undetected'] as num?)?.toInt() ?? 0;
    final harmless = (stats['harmless'] as num?)?.toInt() ?? 0;
    final totalEngines = malicious + suspicious + undetected + harmless;

    // 风险评分：malicious * 10 + suspicious * 5，封顶 100
    final riskScore = (malicious * 10 + suspicious * 5).clamp(0, 100);

    // 严重程度
    SecuritySeverity severity;
    if (malicious >= 10) {
      severity = SecuritySeverity.critical;
    } else if (malicious >= 3) {
      severity = SecuritySeverity.high;
    } else if (malicious >= 1) {
      severity = SecuritySeverity.medium;
    } else if (suspicious >= 1) {
      severity = SecuritySeverity.low;
    } else {
      severity = SecuritySeverity.info;
    }

    final findings = <SecurityFinding>[];
    if (malicious > 0) {
      findings.add(SecurityFinding(
        id: 'vt-malicious',
        title: '$malicious 个引擎检测为恶意',
        description: '在 $totalEngines 个引擎中，$malicious 个标记为恶意，$suspicious 个可疑。',
        severity: severity,
        category: 'virustotal',
      ));
    }
    if (suspicious > 0) {
      findings.add(SecurityFinding(
        id: 'vt-suspicious',
        title: '$suspicious 个引擎检测为可疑',
        description: '在 $totalEngines 个引擎中，$suspicious 个标记为可疑。',
        severity: SecuritySeverity.low,
        category: 'virustotal',
      ));
    }
    if (malicious == 0 && suspicious == 0) {
      findings.add(SecurityFinding(
        id: 'vt-clean',
        title: '$totalEngines 个引擎均未检测到恶意',
        description: 'VirusTotal 查询 SHA-256: $sha256Hash，全部引擎判定为安全或未检出。',
        severity: SecuritySeverity.info,
        category: 'virustotal',
      ));
    }

    _logger.info(
        'VirusTotal 结果: malicious=$malicious, suspicious=$suspicious, '
        'undetected=$undetected, harmless=$harmless, risk=$riskScore',
        tag: 'SecurityScan');

    return SecurityScanResult(
      success: true,
      riskScore: riskScore,
      severity: severity,
      safeToInstall: riskScore < 40,
      findings: findings,
      rawResponse: jsonEncode(data),
      scanDuration: duration,
    );
  }

  /// 计算 MobSF 风险分数
  static int _calculateMobSFRiskScore(Map<String, dynamic> data) {
    int score = 0;

    // 权限风险
    final permissions = data['permissions'] as Map<String, dynamic>? ?? {};
    for (final entry in permissions.entries) {
      final permData = entry.value as Map<String, dynamic>? ?? {};
      final status = permData['status'] as String? ?? '';
      if (status == 'dangerous') {
        score += 5;
      } else if (status == 'sensitive') {
        score += 2;
      }
    }

    // 代码发现风险（v1.7.11 P1：findings 在 vulnerabilities.findings 下）
    final vulnerabilities = data['vulnerabilities'] as Map<String, dynamic>?;
    // v1.7.16 修复：MobSF findings 可能是 List 或 Map，`as Map` 优先级高于 `??`，
    // List 时会在短路前抛 CastError 被外层 catch 吞掉 → 安全审查静默失效。
    // 改为先取原始值再判断类型，非 Map 一律给空表，不抛异常。
    final rawFindings = vulnerabilities?['findings'] ?? data['findings'];
    final findings = rawFindings is Map
        ? Map<String, dynamic>.from(rawFindings)
        : <String, dynamic>{};
    for (final entry in findings.entries) {
      final findingData = entry.value as Map<String, dynamic>? ?? {};
      final severity = findingData['severity'] as String? ?? 'info';
      switch (severity.toLowerCase()) {
        case 'critical':
          score += 20;
          break;
        case 'high':
          score += 10;
          break;
        case 'medium':
          score += 5;
          break;
        case 'low':
          score += 2;
          break;
      }
    }

    return score.clamp(0, 100);
  }

  /// 解析 MobSF 整体严重程度
  static SecuritySeverity _parseMobSFSeverity(Map<String, dynamic> data) {
    final riskScore = _calculateMobSFRiskScore(data);
    if (riskScore <= 20) return SecuritySeverity.low;
    if (riskScore <= 50) return SecuritySeverity.medium;
    if (riskScore <= 80) return SecuritySeverity.high;
    return SecuritySeverity.critical;
  }
}
