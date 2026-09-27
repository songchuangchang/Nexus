/// 插件更新检查服务
///
/// 检查已安装的 MCP 和 Skill 插件是否有新版本可用
library plugin_update_service;

import 'logger_service.dart';
import '../plugins/plugin_interface.dart';
import '../plugins/plugin_registry.dart';
import '../models/skill_models.dart';
import '../models/mcp_market_models.dart';
import 'skill_registry_service.dart';
import 'skill_parser.dart';
import 'mcp_registry_service.dart';

/// 更新信息
class PluginUpdateInfo {
  final String pluginId;
  final String currentVersion;
  final String latestVersion;
  final String downloadUrl;
  final bool hasUpdate;

  const PluginUpdateInfo({
    required this.pluginId,
    required this.currentVersion,
    required this.latestVersion,
    required this.downloadUrl,
    required this.hasUpdate,
  });
}

/// 插件更新检查服务
class PluginUpdateService {
  static final LoggerService _logger = LoggerService.instance;

  /// 执行单个插件的更新（v1.7.12 补真实执行逻辑，之前是 TODO 占位）
  ///
  /// 返回 (success, message)
  static Future<(bool, String)> updatePlugin(
    PluginUpdateInfo info,
    PluginRegistry registry,
  ) async {
    final pluginId = info.pluginId;
    final plugin = registry.getById(pluginId);
    if (plugin == null) return (false, '插件未安装: $pluginId');
    final kind = plugin.metadata.kind;

    try {
      if (kind.isDeclarative) {
        return await _updateSkill(info, registry, plugin);
      } else if (kind.isRemote) {
        return await _updateMcp(info, registry);
      }
      // v1.7.14：代码审查指出 PluginKind enum 仅 declarative/mcpRemote 两值，
      // 此分支实际不可达；保留以防未来加新 PluginKind 漏改这里，至少返回明确错误而非
      // 静默穿透到 (true, ...) 默认值。返回字段含 ${kind.name} 便于排错。
      return (false, '不支持的插件类型: ${kind.name}');
    } catch (e, st) {
      _logger.error('更新插件失败 [$pluginId]: $e',
          error: e, stack: st, tag: 'PluginUpdate');
      return (false, '更新失败: $e');
    }
  }

  /// Skill 更新：重新下载 SKILL.md → 解析 metadata → 调用 installDeclarative 覆盖安装
  static Future<(bool, String)> _updateSkill(
    PluginUpdateInfo info,
    PluginRegistry registry,
    dynamic plugin,
  ) async {
    _logger.info(
        'Skill 更新开始: ${info.pluginId} v${info.currentVersion}→v${info.latestVersion}',
        tag: 'PluginUpdate');
    final metadata = plugin.metadata as PluginMetadata;
    final extraUrl = metadata.extra['downloadUrl'];
    final downloadUrl = (extraUrl is String && extraUrl.trim().isNotEmpty)
        ? extraUrl.trim()
        : metadata.homepage;
    if (downloadUrl.isEmpty) {
      return (false, '缺少下载 URL');
    }
    // 下载 + 解析最新 SKILL.md
    final content =
        await SkillRegistryService.downloadSkillContent(downloadUrl);
    final ParsedSkill parsed;
    try {
      parsed = SkillParser.parse(content);
    } catch (e) {
      return (false, '解析 SKILL.md 失败: $e');
    }
    // 保留原 extra 中的 downloadUrl/skillSummary，构造新 metadata
    final extra = Map<String, dynamic>.from(metadata.extra);
    extra['downloadUrl'] = downloadUrl;
    // v1.7.12：跟 _installSkill 写法保持一致
    // SkillMetadata 没有 promptProtocol 字段，SKILL.md 正文 instruction 直接存进 promptProtocol
    // （DeclarativePlugin 用 promptProtocol 字段承载 Skill 的正文内容）
    final String effectiveProtocol = parsed.instruction;
    // 用原 id 保证覆盖安装（parsed.metadata 的 id/version 用最新的）
    final newMeta = PluginMetadata(
      id: metadata.id,
      name: parsed.metadata.name,
      version: parsed.metadata.version ?? info.latestVersion,
      author: parsed.metadata.author ?? metadata.author,
      description: parsed.metadata.description,
      homepage: parsed.metadata.homepage ?? metadata.homepage,
      promptProtocol: effectiveProtocol,
      tags: parsed.metadata.tags,
      kind: PluginKind.declarative,
      triggerType: metadata.triggerType,
      extra: extra,
    );
    await registry.installDeclarative(newMeta);
    _logger.info('Skill 更新成功: ${info.pluginId} → v${newMeta.version}',
        tag: 'PluginUpdate');
    return (true, '已更新到 v${newMeta.version}');
  }

  /// MCP 更新：从 McpRegistry 重新获取最新 server → 重跑 installRemoteMcp（会 upsert 覆盖）
  static Future<(bool, String)> _updateMcp(
    PluginUpdateInfo info,
    PluginRegistry registry,
  ) async {
    _logger.info(
        'MCP 更新开始: ${info.pluginId} v${info.currentVersion}→v${info.latestVersion}',
        tag: 'PluginUpdate');
    final mcpSvc = McpRegistryService();
    final page = await mcpSvc.fetchPage(limit: 50, search: info.pluginId);
    McpRegistryServer? target;
    for (final s in page.servers) {
      if (s.name == info.pluginId) {
        target = s;
        break;
      }
    }
    if (target == null) {
      return (false, '在 MCP Registry 中未找到服务器: ${info.pluginId}');
    }
    // 重新安装（方法内部走 upsertPlugin 覆盖）
    await registry.installRemoteMcp(target);
    _logger.info('MCP 更新成功: ${info.pluginId} → v${target.version}',
        tag: 'PluginUpdate');
    return (true, '已更新到 v${target.version}');
  }

  /// 检查所有已安装插件的更新
  static Future<List<PluginUpdateInfo>> checkAllUpdates(
      PluginRegistry registry) async {
    final plugins = registry.plugins;
    final updates = <PluginUpdateInfo>[];

    for (final plugin in plugins) {
      // v1.7.12：跳过 system 来源插件（内置的 search/download/ask_user/self_check/answer）
      // 它们的 homepage 填的是伪域名 nexus.local，更新检查去请求会 DNS 失败刷屏 ERROR 日志。
      // System 插件随 App 版本一起升级，不需要单独检查更新。
      if (plugin.source == PluginSource.system) {
        _logger.info('跳过 System 插件更新检查: ${plugin.metadata.id}',
            tag: 'PluginUpdate');
        continue;
      }
      try {
        final updateInfo = await checkPluginUpdate(plugin);
        if (updateInfo != null && updateInfo.hasUpdate) {
          updates.add(updateInfo);
        }
      } catch (e) {
        _logger.error('检查插件更新失败 [${plugin.metadata.name}]: $e',
            tag: 'PluginUpdate');
      }
    }

    _logger.info('插件更新检查完成，发现 ${updates.length} 个更新', tag: 'PluginUpdate');
    return updates;
  }

  /// 检查单个插件的更新
  /// v1.7.8：修复 dynamic 调用 PluginKind.name 抛 NoSuchMethodError
  /// （.name 是 EnumName 扩展成员，dynamic 接收者无法静态解析扩展 → 改强类型 + == 比较）
  static Future<PluginUpdateInfo?> checkPluginUpdate(dynamic plugin) async {
    final metadata = plugin.metadata as PluginMetadata;
    final pluginId = metadata.id;
    final currentVersion = metadata.version;
    final kind = metadata.kind;

    // 根据插件类型选择不同的检查方式
    if (kind.isRemote) {
      return await _checkMcpUpdate(pluginId, currentVersion);
    } else if (kind.isDeclarative) {
      return await _checkSkillUpdate(pluginId, currentVersion, metadata);
    }

    return null;
  }

  /// 检查 MCP 插件更新
  static Future<PluginUpdateInfo?> _checkMcpUpdate(
      String pluginId, String currentVersion) async {
    try {
      _logger.info('检查 MCP 更新: $pluginId', tag: 'PluginUpdate');

      // 从 MCP Registry 获取最新版本
      final registry = McpRegistryService();
      final page = await registry.fetchPage(limit: 100, search: pluginId);

      for (final server in page.servers) {
        if (server.name == pluginId) {
          final latestVersion = server.version;
          final hasUpdate = _compareVersions(latestVersion, currentVersion) > 0;

          return PluginUpdateInfo(
            pluginId: pluginId,
            currentVersion: currentVersion,
            latestVersion: latestVersion,
            downloadUrl: server.endpoint.toString(),
            hasUpdate: hasUpdate,
          );
        }
      }
    } catch (e) {
      _logger.error('检查 MCP 更新失败 [$pluginId]: $e', tag: 'PluginUpdate');
    }

    return null;
  }

  /// 检查 Skill 插件更新
  /// v1.7.8：优先用安装时存的 extra['downloadUrl']（SKILL.md 直链），
  /// homepage 可能是市场页面 URL（skillsmp.com/creators/...），下载回来是 HTML 无法解析
  static Future<PluginUpdateInfo?> _checkSkillUpdate(
    String pluginId,
    String currentVersion,
    PluginMetadata metadata,
  ) async {
    try {
      _logger.info('检查 Skill 更新: $pluginId', tag: 'PluginUpdate');

      // 优先安装时保存的 SKILL.md 直链，其次 homepage
      final extraUrl = metadata.extra['downloadUrl'];
      final downloadUrl = (extraUrl is String && extraUrl.trim().isNotEmpty)
          ? extraUrl.trim()
          : metadata.homepage;
      if (downloadUrl.isEmpty) {
        _logger.warn('Skill [$pluginId] 没有下载 URL，无法检查更新', tag: 'PluginUpdate');
        return null;
      }

      // 下载最新的 SKILL.md
      final content =
          await SkillRegistryService.downloadSkillContent(downloadUrl);
      final parsed = SkillParser.parse(content);
      final latestVersion = parsed.metadata.version ?? '1.0.0';

      final hasUpdate = _compareVersions(latestVersion, currentVersion) > 0;

      return PluginUpdateInfo(
        pluginId: pluginId,
        currentVersion: currentVersion,
        latestVersion: latestVersion,
        downloadUrl: downloadUrl,
        hasUpdate: hasUpdate,
      );
    } catch (e) {
      _logger.error('检查 Skill 更新失败 [$pluginId]: $e', tag: 'PluginUpdate');
    }

    return null;
  }

  /// 比较版本号（语义化版本）
  /// 返回：>0 表示 v1 > v2，<0 表示 v1 < v2，0 表示相等
  /// v1.7.9 (M5 修复)：先剥离 "v"/"V" 前缀和 "-beta"/"+build" 等预发布后缀
  /// （之前 "v2.0.0" 解析为 [0,2,0] → 误判比 "1.9.0" 旧；"1.2.3-beta" 段解析失败取 0）
  static int _compareVersions(String v1, String v2) {
    List<int> parse(String raw) {
      var s = raw.trim();
      if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
      // 去掉预发布/构建后缀（"1.2.3-beta.1+build5" → "1.2.3"）
      final dash = s.indexOf('-');
      final plus = s.indexOf('+');
      var cut = s.length;
      if (dash >= 0 && dash < cut) cut = dash;
      if (plus >= 0 && plus < cut) cut = plus;
      s = s.substring(0, cut);
      return s.split('.').map((e) => int.tryParse(e.trim()) ?? 0).toList();
    }

    final parts1 = parse(v1);
    final parts2 = parse(v2);

    final maxLen =
        parts1.length > parts2.length ? parts1.length : parts2.length;

    for (int i = 0; i < maxLen; i++) {
      final p1 = i < parts1.length ? parts1[i] : 0;
      final p2 = i < parts2.length ? parts2[i] : 0;

      if (p1 > p2) return 1;
      if (p1 < p2) return -1;
    }

    return 0;
  }
}
