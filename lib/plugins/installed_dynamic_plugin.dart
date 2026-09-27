import 'dart:convert';
import 'package:flutter/material.dart';
import '../services/logger_service.dart';
import 'plugin_context.dart';
import 'plugin_interface.dart';
import 'installed_mcp_plugin.dart';

/// 从 DB 行 / 市场元数据构造的已安装声明式插件
///
/// 【设计目的】
/// 1. 插件市场安装的第三方插件（目前是 demo 内置插件包，未来会是下载的 dart 源码包）
///    不需要手动写 ReActPlugin 子类，通过 DB 行的 metadataJson 就能重建 runtime 插件对象。
/// 2. 解决 NEW-BUG-02：PluginRegistry 启动时从 plugins 表 reload，
///    能重新 register 所有 source=installed 的插件，
///    保证重启后 promptProtocol 仍然会被拼进 system prompt、已安装列表仍可见。
///
/// 【处理逻辑】
/// - metadata / source：从构造参数直接拿
/// - triggerType：按插件 id 的常见前缀（download/search/ask_user/answer/self_check）映射，
///   否则默认 __installed_{id}（不会被 dispatch 的 XML triggerType 命中，
///   但 promptProtocol 仍能被拼给 AI）
/// - legacyTrigger：null（市场插件暂时不提供老流程 legacy 关键字兜底）
/// - handle：只写 reasoning step 不崩溃，真正的执行逻辑未来会在下载源码后用子类或
///   反射替换。
class InstalledDynamicPlugin extends ReActPlugin {
  final PluginMetadata _meta;
  final PluginSource _source;

  InstalledDynamicPlugin({
    required PluginMetadata metadata,
    PluginSource source = PluginSource.installed,
  })  : _meta = metadata,
        _source = source;

  /// 从 plugins 表的 DB 行重建（配合 StorageService.loadAllPlugins）
  ///
  /// row 期望结构：
  /// { id, name, version, source(String: installed/system/community),
  ///   author, description, installedAt(int), metadataJson(String) }
  ///
  /// 优先使用 metadataJson 反序列化出的完整 PluginMetadata（包含 promptProtocol/tags/homepage 等完整信息），
  /// 退化场景（metadataJson 字段损坏/缺失/非法 JSON）：从 id/name/version/author/description 等列粗粒度重建。
  static ReActPlugin fromDbRow(Map<String, dynamic> row) {
    PluginMetadata meta;
    try {
      final raw = row['metadataJson'];
      if (raw is String && raw.trim().isNotEmpty) {
        final parsed = jsonDecode(raw) as Map<String, dynamic>;
        meta = PluginMetadata.fromMap(parsed);
        // 以 DB 主键 id 为准（metadataJson 可能不一致）
        if (row['id'] is String && (row['id'] as String).isNotEmpty) {
          meta = meta.copyWith(id: row['id'] as String);
        }
      } else {
        meta = PluginMetadata(
          id: (row['id'] as String?) ?? 'unknown.plugin',
          name: (row['name'] as String?) ?? 'Unknown Plugin',
          version: (row['version'] as String?) ?? '0.0.0',
          author: (row['author'] as String?) ?? '',
          description: (row['description'] as String?) ?? '',
        );
      }
    } catch (e) {
      // build155（第 13 轮 P1-3）：这条降级路径此前**完全无痕**，而它的后果很重——
      // 退化重建出来的 metadata 只有 id/name/version，promptProtocol（Skill 正文＝能力说明）
      // 与 extra（downloadUrl / skillDir / skillSummary）全丢，于是：
      //   插件管理里「已安装」且可以打开开关，但 system prompt 里没有它的能力协议、
      //   检查更新固定返回「缺少下载 URL」，用户既用不了也看不出为什么。
      // 行为不变（仍降级重建，保证启动不被一行坏数据打断），但必须留下一行可导出的日志。
      LoggerService.instance.warn(
          '[Plugin] ${row['id']} 的 metadataJson 无法解析，已退化重建'
          '（promptProtocol/extra 丢失）：$e',
          tag: 'PluginBoot');
      meta = PluginMetadata(
        id: (row['id'] as String?) ?? 'unknown.plugin',
        name: (row['name'] as String?) ?? 'Unknown Plugin',
        version: (row['version'] as String?) ?? '0.0.0',
        author: (row['author'] as String?) ?? '',
        description: (row['description'] as String?) ?? '',
      );
    }

    PluginSource src;
    switch ((row['source'] as String?) ?? PluginSource.installed.name) {
      case 'system':
        src = PluginSource.system;
        break;
      case 'market':
        src = PluginSource.market;
        break;
      case 'installed':
      default:
        src = PluginSource.installed;
        break;
    }
    if (meta.kind.isRemote) {
      return InstalledMcpPlugin.fromMetadata(meta);
    }
    return InstalledDynamicPlugin(metadata: meta, source: src);
  }

  @override
  String get triggerType {
    // v1.7.1 fix M2: 优先使用 metadata 中明确指定的 triggerType
    if (_meta.triggerType.isNotEmpty) {
      return _meta.triggerType;
    }
    // 后备：通过 id 猜测（向后兼容）
    final id = _meta.id.toLowerCase();
    if (id.contains('download')) return 'download';
    if (id.contains('search')) return 'search';
    if (id.contains('ask')) return 'ask_user';
    if (id.contains('answer')) return 'answer';
    if (id.contains('selfcheck') || id.contains('self_check')) {
      return 'self_check';
    }
    return '__installed_${_meta.id}';
  }

  @override
  RegExp? get legacyTrigger => null;

  @override
  PluginSource get source => _source;

  @override
  PluginMetadata get metadata => _meta;

  @override
  Future<void> handle(BuildContext context, PluginContext pc,
      Map<String, dynamic> attrs) async {
    final fallback =
        attrs['content']?.toString() ?? attrs['query']?.toString() ?? '';
    final preview = fallback.isEmpty
        ? '-'
        : fallback.substring(0, fallback.length > 40 ? 40 : fallback.length);
    final isExplicitSkill = attrs['type']?.toString() == 'skill_call';
    pc.addReasoningStep(
      isExplicitSkill ? 'skill_call' : 'installed_plugin_${_meta.id}',
      isExplicitSkill
          ? 'Skill ${_meta.name}'
          : '[Installed plugin ${_meta.name} v${_meta.version}] '
              'received trigger type=$triggerType (preview: $preview)',
      pluginId: _meta.id,
      pluginName: _meta.name,
      status: isExplicitSkill ? 'success' : 'injected',
      arguments: attrs['arguments']?.toString() ?? fallback,
      resultSummary:
          isExplicitSkill ? 'Skill promptProtocol 已注入，未执行第三方代码' : 'Skill 规则已注入',
    );
  }
}
