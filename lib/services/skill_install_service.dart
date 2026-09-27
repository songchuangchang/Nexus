import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/skill_models.dart';
import '../models/web_search_config.dart';
import '../plugins/plugin_interface.dart';
import '../plugins/plugin_registry.dart';
import 'github_content_fetcher.dart';
import 'logger_service.dart';
import 'security_audit_log.dart';
import 'security_gate.dart';
import 'skill_parser.dart';
import 'skill_registry_service.dart';

/// Skill 代装结果
class SkillInstallResult {
  final bool ok;
  final String? pluginId;
  final String? name;
  final String? error;
  final bool blockedByScan;
  final bool alreadyInstalled;
  final List<String> findings;
  final String? skillDir;

  const SkillInstallResult({
    required this.ok,
    this.pluginId,
    this.name,
    this.error,
    this.blockedByScan = false,
    this.alreadyInstalled = false,
    this.findings = const [],
    this.skillDir,
  });
}

/// Skill 代装服务（待办① / 拍板⑥）：聊天内 <install_skill> 触发的无 UI 安装管线。
///
/// 链路与插件市场 _installSkill 共用同一套关卡：
///   直链 URL 或市场条目（直链优先，query 走 SkillRegistryService 市场搜索）
///   → 下载（SKILL.md 原文或 zip 包）
///   → LocalScanService 本地安全扫描（+可选 SkillSpector 远程深扫），不过即拒绝
///   → 解压解析 SKILL.md
///   → 写入 .skills/<pluginId>/ 目录（应用支持目录下）
///   → PluginRegistry.installDeclarative 注册并启用（当轮即可 <skill_call>）
///
/// 与市场安装的差异：无弹窗确认（AI 代装场景无人值守），扫描不通过一律硬拒。
/// 日志脱敏：只记录 URL host 与 Skill 名，不落完整 URL（可能带签名 token）。
class SkillInstallService {
  static final LoggerService _logger = LoggerService.instance;

  /// zip 解压上限：条目数与解压后总字节数（防 zip bomb）
  static const int kMaxZipEntries = 200;
  static const int kMaxUncompressedBytes = 20 * 1024 * 1024;

  /// 主入口。直链优先：url 非空时直接用 url；否则用 query 搜市场取第一个条目。
  ///
  /// 可注入点（测试用）：
  /// - [downloader]：替换网络下载
  /// - [marketSearch]：替换市场搜索
  /// - [skillsRootDir]：替换 .skills 根目录（默认应用支持目录/.skills）
  /// - [installer]：替换注册动作（默认 registry.installDeclarative，会写 DB）
  static Future<SkillInstallResult> install({
    required PluginRegistry registry,
    required WebSearchConfig cfg,
    String url = '',
    String query = '',
    Future<Uint8List> Function(String url)? downloader,
    Future<List<SkillMarketItem>> Function(String query)? marketSearch,
    String? skillsRootDir,
    Future<void> Function(PluginMetadata metadata)? installer,
  }) async {
    try {
      // 1) 解析下载地址：直链优先，其次市场搜索
      var effectiveUrl = url.trim();
      var homepage = '';
      if (effectiveUrl.isEmpty) {
        if (query.trim().isEmpty) {
          return const SkillInstallResult(
              ok: false, error: '缺少 url 或 query 参数');
        }
        final search = marketSearch ??
            (q) => SkillRegistryService.fetchSkills(search: q, limit: 10);
        final items = await search(query.trim());
        if (items.isEmpty) {
          return SkillInstallResult(
              ok: false, error: '市场未找到与「$query」匹配的 Skill');
        }
        effectiveUrl = items.first.downloadUrl;
        homepage = items.first.homepage ?? '';
        _logger.info('Skill 代装：市场命中 ${items.first.name}', tag: 'Skill');
      }
      final uri = Uri.tryParse(effectiveUrl);
      if (uri == null || !uri.scheme.startsWith('http')) {
        return const SkillInstallResult(ok: false, error: '下载地址非法');
      }
      final host = uri.host;
      _logger.info('Skill 代装：开始下载 host=$host', tag: 'Skill');

      // 2) 下载（SKILL.md 文本或 zip 二进制）
      final fetch = downloader ?? (u) => _downloadBytes(u, cfg.githubProxyUrl);
      final bytes = await fetch(effectiveUrl);
      if (bytes.isEmpty) {
        return const SkillInstallResult(ok: false, error: '下载内容为空');
      }

      // 3) zip → 解压；否则按 SKILL.md 纯文本
      final isZip =
          _looksLikeZip(bytes) || effectiveUrl.toLowerCase().endsWith('.zip');
      Map<String, Uint8List> files;
      String skillMdName;
      if (isZip) {
        final extracted = _extractZip(bytes);
        if (extracted == null) {
          return const SkillInstallResult(ok: false, error: 'zip 解压失败或超出安全限制');
        }
        files = extracted;
        final md = _findSkillMd(files);
        if (md == null) {
          return const SkillInstallResult(
              ok: false, error: 'zip 内未找到 SKILL.md');
        }
        skillMdName = md;
      } else {
        files = {'SKILL.md': bytes};
        skillMdName = 'SKILL.md';
      }
      final content = utf8.decode(files[skillMdName]!, allowMalformed: true);

      // 4) 解析 SKILL.md
      final ParsedSkill parsed;
      try {
        parsed = SkillParser.parse(content);
      } catch (e) {
        return SkillInstallResult(ok: false, error: 'SKILL.md 解析失败：$e');
      }
      final pluginId = parsed.pluginId;
      final skillName = parsed.metadata.name;

      // 5) 已安装 → 幂等返回
      if (registry.getById(pluginId) != null) {
        return SkillInstallResult(
          ok: true,
          pluginId: pluginId,
          name: skillName,
          alreadyInstalled: true,
        );
      }

      // 6) 安全扫描（build98 统一入口 SecurityGate；不过即硬拒，无用户确认通道）
      // build97 (P1-8)：AI 代装通道改 fail-closed——扫描器异常/不可用
      // 也拒绝（旧实现 success=false 时放行，异常直接向上抛由上层吞掉）。
      // build99 (验收 N4)：AI 代装通道本地规则强制必跑（忽略用户开关）。
      final gateReport = await SecurityGate.scanSkill(
        skillContent: content,
        skillName: skillName,
        sourceUrl: effectiveUrl,
        cfg: cfg,
        forceLocalScan: true,
      );
      if (gateReport.anyEngineFailed) {
        return SkillInstallResult(
          ok: false,
          name: skillName,
          blockedByScan: true,
          error:
              '安全扫描服务不可用（${gateReport.engineError}），已拒绝自动安装；请在 Skill 市场手动安装确认。',
        );
      }
      if (gateReport.blocked || gateReport.unsafe) {
        final titles = gateReport.findings
            .map((f) => f.title)
            .toList(growable: false);
        final reason = gateReport.blocked
            ? gateReport.blockReason
            : '风险分 ${gateReport.riskScore}/100：${titles.join('；')}';
        _logger.warn('Skill 代装被安全审查拦截: $skillName $reason',
            tag: 'Skill');
        await SecurityAuditLog.record(
            type: 'reject',
            target: skillName,
            outcome: 'blocked',
            detail: reason);
        return SkillInstallResult(
          ok: false,
          name: skillName,
          blockedByScan: true,
          findings: titles,
          error: '安全审查不通过（$reason）',
        );
      }

      // 7) 写入 .skills/<pluginId>/（写盘失败不阻断注册，仅告警）
      String? skillDir;
      try {
        final root = skillsRootDir ?? await _defaultSkillsRoot();
        skillDir = await _writeSkillFiles(root, pluginId, files);
      } catch (e) {
        _logger.warn('Skill 代装：写盘失败（继续注册）: $e', tag: 'Skill');
      }

      // 8) 组装 metadata 并注册（与市场安装同一套 triggerType 猜测/summary 规则）
      final guessedTrigger = guessSkillTriggerType(
        parsed.metadata.trigger,
        parsed.metadata.name,
        parsed.metadata.description,
        parsed.instruction,
      );
      final metadata = PluginMetadata(
        id: pluginId,
        name: parsed.metadata.name,
        version: parsed.metadata.version ?? '1.0.0',
        author: parsed.metadata.author ?? 'Unknown',
        description: parsed.metadata.description,
        homepage: parsed.metadata.homepage ?? homepage,
        promptProtocol: parsed.instruction,
        tags: parsed.metadata.tags,
        kind: PluginKind.declarative,
        triggerType: guessedTrigger,
        extra: {
          'downloadUrl': effectiveUrl,
          'skillSummary': buildSkillSummary(
            name: parsed.metadata.name,
            description: parsed.metadata.description,
            triggerDesc: parsed.metadata.trigger,
            triggerType: guessedTrigger,
          ),
          if (skillDir != null) 'skillDir': skillDir,
        },
      );
      // build155（第 13 轮 P1-1）：代装＝显式安装动作 → 显式启用；
      // installDeclarative 的默认已改为「同 id 已存在则沿用其开关」（更新场景），
      // 这里必须显式传 true，否则「安装成功，已启用」的文案与提示会失真。
      if (installer != null) {
        await installer(metadata);
      } else {
        await registry.installDeclarative(metadata, enable: true);
      }
      _logger.info('Skill 代装完成: $pluginId ($skillName)', tag: 'Skill');
      await SecurityAuditLog.record(
          type: 'install', target: skillName, outcome: 'pass', detail: pluginId);
      return SkillInstallResult(
        ok: true,
        pluginId: pluginId,
        name: skillName,
        skillDir: skillDir,
      );
    } catch (e) {
      _logger.error('Skill 代装异常: $e', tag: 'Skill');
      return SkillInstallResult(ok: false, error: '安装失败：$e');
    }
  }

  // ==========================================================================
  // 下载（v1.7.38：统一走 GitHubContentFetcher——对冲并发+成功记忆+超时拆分+全链路日志）
  // ==========================================================================

  static Future<Uint8List> _downloadBytes(String url, String proxyUrl) async {
    try {
      return await GitHubContentFetcher.fetchBytes(
        url,
        userProxy: proxyUrl,
        headers: const {
          'Accept': 'application/zip, text/markdown, text/plain, */*',
        },
        tag: 'skill-install',
      );
    } catch (e) {
      throw Exception('下载失败：$e');
    }
  }

  // ==========================================================================
  // zip 解压（防 zip-slip / zip bomb）
  // ==========================================================================

  static bool _looksLikeZip(Uint8List bytes) =>
      bytes.length >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4B; // 'PK'

  static bool _isSafeEntryName(String name) {
    final norm = name.replaceAll('\\', '/');
    if (norm.startsWith('/') || norm.contains(':')) return false;
    return !norm.split('/').contains('..');
  }

  /// 返回 entry相对路径 → 字节；超出安全限制或解压失败返回 null
  static Map<String, Uint8List>? _extractZip(Uint8List bytes) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      _logger.warn('Skill 代装：zip 解码失败: $e', tag: 'Skill');
      return null;
    }
    final files = <String, Uint8List>{};
    var totalBytes = 0;
    var entryCount = 0;
    for (final entry in archive) {
      if (!entry.isFile) continue;
      entryCount++;
      if (entryCount > kMaxZipEntries) return null;
      final name = entry.name.replaceAll('\\', '/');
      if (!_isSafeEntryName(name)) {
        _logger.warn('Skill 代装：跳过不安全路径 entry=$name', tag: 'Skill');
        continue;
      }
      final bytesData = entry.content;
      totalBytes += bytesData.length;
      if (totalBytes > kMaxUncompressedBytes) return null;
      files[name] = bytesData;
    }
    return files;
  }

  /// 在解压结果中定位 SKILL.md：basename 命中（大小写不敏感），路径最短者优先
  static String? _findSkillMd(Map<String, Uint8List> files) {
    final hits = files.keys
        .where((k) => k.split('/').last.toLowerCase() == 'skill.md')
        .toList();
    if (hits.isEmpty) return null;
    hits.sort((a, b) => a.length.compareTo(b.length));
    return hits.first;
  }

  // ==========================================================================
  // 写盘：.skills/<pluginId>/
  // ==========================================================================

  static Future<String> _defaultSkillsRoot() async {
    final dir = await getApplicationSupportDirectory();
    return p.join(dir.path, '.skills');
  }

  static Future<String> _writeSkillFiles(
      String root, String pluginId, Map<String, Uint8List> files) async {
    final dir = Directory(p.join(root, pluginId));
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    for (final entry in files.entries) {
      final file = File(p.join(dir.path, entry.key));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(entry.value, flush: true);
    }
    _logger.info('Skill 代装：写入 ${files.length} 个文件到 ${dir.path}', tag: 'Skill');
    return dir.path;
  }

  // ==========================================================================
  // 与插件市场共用的 triggerType 猜测 / summary 构造（v1.7.12 起源自 plugin_market_screen）
  // ==========================================================================

  /// 根据 Skill 的元数据/正文猜测 triggerType。
  /// 避免硬编码同一触发器导致 PluginRegistry._fallbacks 互相覆盖。
  static String guessSkillTriggerType(
    String? frontmatterTrigger,
    String name,
    String description,
    String instruction,
  ) {
    final haystack = [
      frontmatterTrigger ?? '',
      name,
      description,
    ].join(' ').toLowerCase();
    final haystackDeep = [haystack, instruction.toLowerCase()].join(' ');

    if (_containsAny(haystackDeep, const [
      '下载',
      'download',
      'apk',
      '安装包',
      '安装应用',
    ])) {
      return 'download';
    }
    if (_containsAny(haystack, const [
      '搜索',
      '联网',
      'search',
      '查找',
      '查询信息',
    ])) {
      return 'search';
    }
    if (_containsAny(haystackDeep, const [
      '反问',
      'ask_user',
      '让用户选择',
      '用户确认',
      '确认一下',
      '需要用户',
    ])) {
      return 'ask_user';
    }
    if (_containsAny(haystackDeep, const [
      '自检',
      'self_check',
      '卡住',
      '卡壳',
      '检查是否',
    ])) {
      return 'self_check';
    }
    // mcp_call 是 MCP 专用，Skill 不会触发这个类型，跳过

    // 都匹配不上时 → 用 skill.<name> 作为独立 triggerType，不同 Skill 不互相抢占
    final cleaned = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return cleaned.isEmpty ? 'skill.generic' : 'skill.$cleaned';
  }

  /// 构造 Skill 的结构化简介，保存在 metadata.extra['skillSummary']，
  /// 供 buildReactSystemPromptFromPlugins 拼成"Skill 可用清单"注入 system prompt。
  static String buildSkillSummary({
    required String name,
    required String description,
    required String? triggerDesc,
    required String triggerType,
  }) {
    final trigger = triggerDesc?.trim().isNotEmpty == true
        ? triggerDesc!.trim()
        : '当对话内容涉及"${description.isEmpty ? name : _shortDesc(description)}"时';
    return '$name | type=$triggerType | 触发时机: $trigger';
  }

  static bool _containsAny(String s, List<String> keywords) {
    for (final k in keywords) {
      if (s.contains(k.toLowerCase())) return true;
    }
    return false;
  }

  static String _shortDesc(String description) {
    final d = description.replaceAll(RegExp(r'\s+'), ' ').trim();
    return d.length <= 20 ? d : '${d.substring(0, 20)}…';
  }
}
