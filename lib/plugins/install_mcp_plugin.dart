import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/chat_message.dart';
import '../models/mcp_market_models.dart';
import '../services/logger_service.dart';
import '../services/mcp_registry_service.dart';
import '../services/security_audit_log.dart';
import '../services/security_gate.dart';
import 'plugin_context.dart';
import 'plugin_interface.dart';
import 'plugin_registry.dart';

/// AI 代装 MCP 插件（2026-09-06 待办 · build90 第 3 步）
///
/// AI 输出 <install_mcp endpoint="..." query="..." name="..." /> 时触发：
/// 直连 HTTPS 端点或市场搜索（query，直链优先）→ 本地安全扫描（不过硬拒）
/// →（可选远程深扫）→ installRemoteMcp 注册启用 → 当轮即可 <mcp_call>。
///
/// 与 install_skill 的差异：
/// - MCP 需要鉴权 header 的服务器（headerSpecs 非空）AI 无法代填凭据 →
///   直接拒绝并引导用户去插件市场手动安装。
/// - 无「已安装幂等」快路径：installRemoteMcp 自带覆盖式更新语义，
///   已装服务器重装=刷新工具列表，无害。
class InstallMcpPlugin extends ReActPlugin {
  /// 全局 PluginRegistry 解析器，createBuiltinPluginRegistry 创建后绑定。
  static PluginRegistry? Function()? registryResolver;

  /// 测试注入：替换直连/市场搜索解析逻辑（不触网）。生产为 null。
  static Future<McpRegistryServer> Function({
    required String endpoint,
    required String query,
    required String name,
  })? serverResolver;

  @override
  String get triggerType => 'install_mcp';

  @override
  RegExp? get legacyTrigger => null;

  @override
  PluginSource get source => PluginSource.system;

  @override
  PluginMetadata get metadata => const PluginMetadata(
        id: 'nexus.builtin.install_mcp',
        name: 'AI 代装 MCP',
        version: '1.7.38',
        author: 'Nexus Team',
        description:
            'AI 在聊天中自助安装 MCP 服务器：支持 HTTPS 直连端点或按关键词搜官方市场，全程本地安全扫描，装完当轮即可调用。',
        homepage: 'https://nexus.local/plugins/install_mcp',
        minAppVersion: '1.7.38',
        tags: ['内置', 'MCP', '安装'],
        promptProtocol: '''
【MCP 代装工具】使用说明：
- 使用场景：用户要求"安装/连接一个 MCP 服务器"，或当前任务需要某个尚不存在的 MCP 能力（如打车、支付、地图）时。
- 协议格式（自闭合标签）：<install_mcp endpoint="https直连端点" query="市场搜索关键词" name="可选名称" />
  - endpoint：MCP 服务器的 https 直连端点（Streamable HTTP 型）。【直连优先】：endpoint 非空时忽略 query。
  - ⚠️ endpoint 必须是真实可访问的完整 URL。MCP 市场的服务器名（如 com.example/server、ac.inference.sh）是「反域名标识符」而不是网址——禁止把名字拼/反拼成域名当 endpoint（如把 ac.inference.sh 拼成 sh.inference.ac）。没有确切直链时一律只用 query，宿主会从市场结果的真实 remotes 字段取端点。
  - query：没有直链时填官方市场（registry.modelcontextprotocol.io）搜索关键词，宿主取第一个结果安装。
  - endpoint 与 query 至少填一个。
- 安全关卡（不可绕过）：安装前必须通过本地安全扫描（及可选远程深扫），不通过会被直接拒绝，结果以 <toolresult kind="install_mcp"> 返回给你。
- 需要鉴权凭据（API Key 等 header）的服务器无法代装：会在 toolresult 里说明，此时应引导用户去插件市场手动安装并填写凭据。
- 安装成功后：该 MCP 立即注册并启用，你可在后续轮次用 <mcp_call plugin_id="服务器名" tool="工具名">JSON参数</mcp_call> 调用其工具（先用 <mcp_detail> 查看可用工具）。
- ❌ 禁止：不要输出 <answer> 让用户"去插件市场手动安装"来代替本标签——市场内可直接搜到的服务器你可以直接代装。
- 【内置推荐连接器】用户没给直链时，可优先推荐以下目录服务（安装仍需用户在插件市场/插件管理确认）：
  - amap(高德地图, key-query)：POI/路线/天气；github(GitHub 官方, PAT header)：仓库/Issue/PR；
  - context7(库文档)/deepwiki(仓库问答)/mslearn(微软文档)：开发文档检索；
  - modelscope(魔搭托管, 中文生态)；didi(滴滴出行, key-query)。
''',
      );

  @override
  Future<void> handle(BuildContext context, PluginContext pc,
      Map<String, dynamic> attrs) async {
    final isZh = pc.userMsg?.content.contains(RegExp(r'[一-龥]')) ?? true;
    final endpoint = (attrs['endpoint'] as String? ?? '').trim();
    final query =
        (attrs['query'] as String? ?? attrs['content'] as String? ?? '').trim();
    final name = (attrs['name'] as String? ?? '').trim();

    if (endpoint.isEmpty && query.isEmpty) {
      pc.addReasoningStep(
        'install_mcp',
        isZh
            ? '代装参数为空（endpoint/query 至少一个），已忽略'
            : 'install_mcp: empty params, ignored',
        status: 'invalid',
        resultSummary: 'missing endpoint/query',
      );
      return;
    }
    final registry = registryResolver?.call();
    if (registry == null) {
      pc.addReasoningStep(
        'install_mcp',
        isZh ? '插件注册表不可用，无法代装' : 'Plugin registry unavailable',
        status: 'failed',
      );
      return;
    }

    // ── 1. 解析目标服务器：直连优先，其次市场搜索 ──
    McpRegistryServer server;
    try {
      server = serverResolver != null
          ? await serverResolver!(endpoint: endpoint, query: query, name: name)
          : await _resolveServer(endpoint: endpoint, query: query, name: name);
    } catch (e) {
      pc.addReasoningStep(
        'install_mcp',
        isZh ? '❌ MCP 代装失败：$e' : '❌ MCP install failed: $e',
        status: 'failed',
        resultSummary: e.toString(),
      );
      pc.addMessage(ChatMessage.create(
        conversationId:
            pc.userMsg?.conversationId ?? pc.assistantMsg.conversationId,
        role: MessageRole.user,
        content: '<toolresult kind="install_mcp" status="failed">'
            'Install failed: $e. '
            'Check the endpoint/query and try again, or ask the user for a valid source.'
            '</toolresult>',
      ));
      return;
    }

    final sourceLabel = endpoint.isNotEmpty
        ? server.endpoint.host
        : (isZh ? '市场搜索「$query」' : 'market "$query"');
    pc.addReasoningStep(
      'install_mcp',
      isZh
          ? '🔌 正在代装 MCP「${server.title}」（来源：$sourceLabel）...'
          : '🔌 Installing MCP "${server.title}" (source: $sourceLabel)...',
      status: 'running',
    );
    LoggerService.instance.info(
        '[InstallMcp] trigger source=$sourceLabel server=${server.name}',
        tag: 'Plugin');

    final convId = pc.userMsg?.conversationId ?? pc.assistantMsg.conversationId;

    // ── 2. 鉴权 header 检查：AI 无法代填凭据 → 引导手动安装 ──
    if (server.headerSpecs.isNotEmpty) {
      pc.addReasoningStep(
        'install_mcp',
        isZh
            ? '🔒 「${server.title}」需要鉴权凭据（${server.headerSpecs.length} 个请求头），AI 无法代填，请在插件市场手动安装'
            : '🔒 "${server.title}" requires auth headers; install manually from the plugin market',
        pluginId: server.name,
        pluginName: server.title,
        status: 'blocked',
        resultSummary: 'auth required',
      );
      pc.addMessage(ChatMessage.create(
        conversationId: convId,
        role: MessageRole.user,
        content: '<toolresult kind="install_mcp" status="blocked">'
            'Server "${server.name}" requires authentication headers '
            '(${server.headerSpecs.map((h) => h.name).join(', ')}). '
            'You cannot auto-install it. Tell the user to install it manually '
            'from the plugin market (插件市场) and fill in the credentials.'
            '</toolresult>',
      ));
      return;
    }

    // ── 3. 安全扫描：统一入口 SecurityGate（build98 安全审查体系重构）——
    // URL/域名审查（仅 https+黑名单，命中硬拒）→ 本地规则 → 可选远程深扫。
    // build97 (P1-8)：AI 代装通道无用户确认，改 fail-closed——
    // 扫描器抛异常或引擎执行失败即拒绝安装，提示用户改走插件市场手动安装。
    // build99 (验收 N4)：AI 代装通道本地规则强制必跑（用户关掉开关也不裸奔）。
    final cfg = pc.webSearchCfg;
    final toolsJson = jsonEncode({
      'server_name': server.name,
      'endpoint': server.endpoint.toString(),
      'transport': server.transportType,
      'description': server.description,
    });
    GateReport report;
    try {
      report = await SecurityGate.scanMcp(
        serverName: server.name,
        endpoint: server.endpoint.toString(),
        toolsJson: toolsJson,
        cfg: cfg,
        envKeys: server.headerSpecs.map((h) => h.name).toList(),
        forceLocalScan: true,
      );
    } catch (e) {
      // build97 (P1-8)：扫描器异常 = fail-closed（旧实现 fail-open，
      // 「让扫描器失败」即可零防护绕过 AI 代装）。
      LoggerService.instance
          .warn('[InstallMcp] scan error → blocked (fail-closed): $e',
              tag: 'Plugin');
      _rejectScanUnavailable(pc, convId, server, e.toString(), isZh);
      return;
    }
    if (report.anyEngineFailed) {
      _rejectScanUnavailable(pc, convId, server, report.engineError, isZh);
      return;
    }
    if (report.blocked || report.unsafe) {
      final reason = report.blocked
          ? report.blockReason
          : report.findings.map((f) => f.title).join('；');
      await SecurityAuditLog.record(
          type: 'reject', target: server.name, outcome: 'blocked', detail: reason);
      _rejectByScan(pc, convId, server, reason, isZh);
      return;
    }
    // build98（本地加强④）：凭据类字段明文存储提示
    if (report.sensitiveKeys.isNotEmpty) {
      pc.addReasoningStep(
        'install_mcp',
        isZh
            ? '🔑 注意：凭据字段（${report.sensitiveKeys.join(', ')}）将以明文存储在本机'
            : '🔑 Note: credential fields (${report.sensitiveKeys.join(', ')}) will be stored in plaintext locally',
        pluginId: server.name,
        pluginName: server.title,
        status: 'running',
      );
    }

    // ── 4. 安装注册（发现工具 → 写库 → 注册启用） ──
    try {
      // build155（第 13 轮 P1-1）：AI 代装是显式安装动作 → 显式启用（口径同市场）。
      await registry.installRemoteMcp(server,
          forceConfirmEveryCall: report.forceConfirmEveryCall, enable: true);
    } catch (e) {
      pc.addReasoningStep(
        'install_mcp',
        isZh ? '❌ MCP 代装失败：$e' : '❌ MCP install failed: $e',
        pluginId: server.name,
        pluginName: server.title,
        status: 'failed',
        resultSummary: e.toString(),
      );
      pc.addMessage(ChatMessage.create(
        conversationId: convId,
        role: MessageRole.user,
        content: '<toolresult kind="install_mcp" status="failed">'
            'Installation failed: $e. '
            'The server may be offline or incompatible. Inform the user and suggest alternatives.'
            '</toolresult>',
      ));
      return;
    }

    await SecurityAuditLog.record(
        type: 'install',
        target: server.name,
        outcome: 'pass',
        detail: 'endpoint=${server.endpoint.host}');

    pc.addReasoningStep(
      'install_mcp',
      isZh
          ? '✅ MCP「${server.title}」安装成功并已启用（${server.endpoint.host}）'
          : '✅ MCP "${server.title}" installed and enabled (${server.endpoint.host})',
      pluginId: server.name,
      pluginName: server.title,
      status: 'success',
      resultSummary: 'installed',
    );
    pc.addMessage(ChatMessage.create(
      conversationId: convId,
      role: MessageRole.user,
      content: '<toolresult kind="install_mcp" status="success">'
          'MCP server installed and enabled. pluginId=${server.name} '
          'endpoint=${server.endpoint.host}. '
          'Use <mcp_detail plugin_id="${server.name}"/> to list its tools, '
          'then call them via <mcp_call plugin_id="${server.name}" tool="...">args</mcp_call>.'
          '</toolresult>',
    ));
  }

  /// 直连端点 → 手工构造 McpRegistryServer；否则市场搜索取第一条
  Future<McpRegistryServer> _resolveServer({
    required String endpoint,
    required String query,
    required String name,
  }) async {
    if (endpoint.isNotEmpty) {
      final uri = Uri.tryParse(endpoint);
      if (uri == null || !uri.isScheme('HTTPS') || uri.host.isEmpty) {
        throw const FormatException('endpoint 必须是合法的 https:// URL');
      }
      final serverName = name.isNotEmpty ? name : uri.host;
      return McpRegistryServer(
        name: serverName,
        title: serverName,
        description: '',
        version: '1.0.0',
        status: 'active',
        endpoint: uri,
        transportType: 'streamable-http',
      );
    }
    final page = await McpRegistryService().fetchPage(search: query, limit: 10);
    if (page.servers.isEmpty) {
      throw FormatException('市场搜索「$query」无结果');
    }
    return page.servers.first;
  }

  void _rejectByScan(PluginContext pc, String convId, McpRegistryServer server,
      String findings, bool isZh) {
    pc.addReasoningStep(
      'install_mcp',
      isZh
          ? '🛡️ MCP「${server.title}」安全扫描不通过，已拒绝安装。命中：$findings'
          : '🛡️ MCP "${server.title}" rejected by security scan. Findings: $findings',
      pluginId: server.name,
      pluginName: server.title,
      status: 'blocked',
      resultSummary: findings,
    );
    pc.addMessage(ChatMessage.create(
      conversationId: convId,
      role: MessageRole.user,
      content: '<toolresult kind="install_mcp" status="blocked">'
          'Installation REJECTED by security scan. Findings: $findings. '
          'Do NOT retry the same source; inform the user why it was blocked.'
          '</toolresult>',
    ));
  }

  /// build97 (P1-8)：扫描服务不可用时拒绝（fail-closed）。
  void _rejectScanUnavailable(PluginContext pc, String convId,
      McpRegistryServer server, String detail, bool isZh) {
    pc.addReasoningStep(
      'install_mcp',
      isZh
          ? '🛡️ MCP「${server.title}」安全扫描服务不可用，已拒绝代装（$detail）。'
              '请用户到插件市场手动安装。'
          : '🛡️ MCP "${server.title}" blocked: security scan unavailable ($detail). '
              'Ask the user to install manually from the plugin market.',
      pluginId: server.name,
      pluginName: server.title,
      status: 'blocked',
      resultSummary: 'scan unavailable: $detail',
    );
    pc.addMessage(ChatMessage.create(
      conversationId: convId,
      role: MessageRole.user,
      content: '<toolresult kind="install_mcp" status="blocked">'
          'Installation REJECTED because the security scanner is unavailable: $detail. '
          'Do not retry auto-install; tell the user to install manually from '
          'the plugin market.'
          '</toolresult>',
    ));
  }
}
