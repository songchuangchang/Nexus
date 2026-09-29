import 'dart:convert';
import 'package:flutter/material.dart';
import '../models/chat_message.dart';
import '../models/mcp_market_models.dart';
import '../services/logger_service.dart';
import '../services/mcp_client_service.dart';
import '../utils/ssrf_guard.dart';
import 'plugin_context.dart';
import 'plugin_interface.dart';
// build173（S13/S19b）：裸 toolresult 通道收口到同一个信封构造函数。
import 'builtin_plugins.dart' show toolResultTag;

class InstalledMcpPlugin extends ReActPlugin {
  final PluginMetadata _meta;
  final McpClientService _client;
  final String _endpoint;

  InstalledMcpPlugin(
      {required PluginMetadata metadata, McpClientService? client})
      : _meta = metadata,
        // v1.7.37（待办⑬）：从 extra.customHeaders 读鉴权头注入 MCP client。
        // 敏感信息：值绝不写日志。
        // build153（SSRF）：**生产构造点必须注入 `defaultSsrfIpLookup`**。
        // 不注入时闸只跑同步语法层（字面 IP / 内部域名 / 数字化形态），
        // 「域名解析到 127.0.0.1 / 169.254.169.254」这一类要靠 DNS 才看得见 ——
        // 而 DNS 阶段只在真正执行的那条路径上算数（本仓铁律：能力没进执行路径 = 不存在）。
        // 单测走 `client:` 注入或假解析器，不依赖真实 DNS（见 test/build153_ssrf_test.dart）。
        _client = client ??
            McpClientService(
                customHeaders:
                    sanitizeCustomHeaders(metadata.extra['customHeaders']),
                ipLookup: defaultSsrfIpLookup),
        _endpoint = metadata.extra['endpoint']?.toString() ?? '' {
    if (_endpoint.isEmpty) {
      throw const FormatException('MCP endpoint is required');
    }
  }

  factory InstalledMcpPlugin.fromMetadata(PluginMetadata metadata) {
    if (!metadata.kind.isRemote) {
      throw const FormatException('Plugin metadata is not an MCP plugin');
    }
    return InstalledMcpPlugin(metadata: metadata);
  }

  @override
  String get triggerType => 'mcp_call';

  @override
  RegExp? get legacyTrigger => null;

  @override
  PluginSource get source => PluginSource.installed;

  @override
  PluginMetadata get metadata => _meta;

  /// O8-2（build96）：插件级鉴权熔断——本插件任一工具一次 401/403 即置位，
  /// 之后任何工具调用不再真实发请求，直接回「去配置密钥」toolresult，
  /// 防止模型换工具名绕过 E5/(pluginId,tool) 熔断连环 401（实测 5 次）。
  bool _authFailed = false;

  List<Map<String, dynamic>> get tools {
    final raw = _meta.extra['tools'];
    return raw is List
        ? raw.whereType<Map>().map(Map<String, dynamic>.from).toList()
        : const [];
  }

  @override
  Future<void> handle(BuildContext context, PluginContext pc,
      Map<String, dynamic> attrs) async {
    if (attrs['pluginId']?.toString() != _meta.id) return;
    final tool = attrs['tool']?.toString().trim() ?? '';
    final rawArgs = attrs['arguments']?.toString() ?? '{}';
    // build97：在任何 await 之前取一次语言（避免 use_build_context_synchronously）。
    // 用 maybeLocaleOf——裸 BuildContext（单测/异常宿主）没有 Localizations 祖先，
    // localeOf 会抛异常。
    final locale = Localizations.maybeLocaleOf(context);
    final isZh = locale?.languageCode != 'en';
    final startedAt = Stopwatch()..start();
    ReasoningStep? activity;
    void finish({required String status, String? summary, String? text}) {
      startedAt.stop();
      pc.updateReasoningStep(
        activity,
        latencyMs: startedAt.elapsedMilliseconds,
        status: status,
        resultSummary: summary ?? text,
      );
    }

    activity = pc.addReasoningStep(
      'mcp_call',
      'MCP ${_meta.name} · $tool',
      pluginId: _meta.id,
      pluginName: _meta.name,
      toolName: tool.isEmpty ? null : tool,
      arguments: rawArgs,
      status: 'running',
    );
    // v1.7.9 (M14 修复)：工具名不存在时不再 throw（此前异常被 dispatch 静默吞掉，
    // AI 收不到任何反馈 → 幻觉工具名反复重试耗尽轮次），改为注入错误 toolresult
    if (tool.isEmpty || !tools.any((t) => t['name']?.toString() == tool)) {
      LoggerService.instance.warn(
        '[MCP] 工具不存在: plugin=${_meta.id}, tool=$tool, available=${tools.map((t) => t['name']).join(',')}',
        tag: 'MCP',
      );
      final message =
          'MCP tool "$tool" not found. Available tools: ${tools.map((t) => t['name']).join(', ')}. 请改用列表中的工具名。';
      finish(status: 'not_found', text: message);
      pc.addMessage(_toolMessage(pc, tool.isEmpty ? '(empty)' : tool, message));
      return;
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(rawArgs);
    } catch (_) {
      const message = 'MCP arguments must be a JSON object';
      finish(status: 'invalid', text: message);
      pc.addMessage(_toolMessage(pc, tool, message));
      return;
    }
    if (decoded is! Map) {
      const message = 'MCP arguments must be a JSON object';
      finish(status: 'invalid', text: message);
      pc.addMessage(_toolMessage(pc, tool, message));
      return;
    }

    // O8-2（build96）：插件级鉴权熔断——已 401/403 的插件整插件短路，
    // 任何工具调用不再真实发请求，直接回「去配置密钥」指引。
    if (_authFailed) {
      final message = _authBlockedMessage(isZh: isZh);
      LoggerService.instance.warn(
        '[MCP] O8 circuit-breaker: plugin=${_meta.id}, tool=$tool blocked (auth failed earlier), no real request sent',
        tag: 'MCP',
      );
      finish(status: 'auth_blocked', text: message);
      pc.addMessage(_toolMessage(pc, tool, message));
      return;
    }

    // v1.7.2 安全改进：危险工具调用前弹窗确认
    // build98（本地加强⑤）：安装扫描出 high/critical 的插件强制每次弹确认
    final forceConfirm = _meta.extra['securityForceConfirm'] == true;
    if (forceConfirm || McpDangerousTools.isDangerous(tool)) {
      final confirmed =
          await _showDangerousToolConfirmation(context, tool, rawArgs);
      if (!confirmed) {
        const message = '用户拒绝执行此危险操作';
        finish(status: 'rejected', text: message);
        pc.addMessage(_toolMessage(pc, tool, message));
        return;
      }
    }

    // v1.7.2 安全改进：MCP 日志记录
    LoggerService.instance.info(
      '[MCP] 调用工具: plugin=${_meta.id}, tool=$tool, args=$rawArgs',
      tag: 'MCP',
    );

    try {
      final result = await _client.toolsCall(
          _endpoint, tool, Map<String, dynamic>.from(decoded));
      final text = jsonEncode(result);
      // v1.7.1 fix C1: MCP 工具结果上限从 65536 改为 4000 字符，避免撑爆 LLM 上下文
      final limited = text.length > 4000
          ? '${text.substring(0, 4000)}…[已截断，原始长度 ${text.length}]'
          : text;

      // v1.7.2 安全改进：MCP 日志记录
      LoggerService.instance.info(
        '[MCP] 工具调用成功: plugin=${_meta.id}, tool=$tool, result_length=${text.length}',
        tag: 'MCP',
      );

      finish(status: 'success', summary: limited);
      pc.addMessage(_toolMessage(pc, tool, limited));
    } on McpAuthException catch (e) {
      // O8-2（build96）：一次 401/403 → 整插件熔断，并告诉模型别再试。
      e.pluginId = _meta.id;
      _authFailed = true;
      LoggerService.instance.error(
        '[MCP] O8 auth failed (${e.status}): plugin=${_meta.id}, tool=$tool — plugin circuit-broken for this session',
        tag: 'MCP',
      );
      final message = _authBlockedMessage(status: e.status, isZh: isZh);
      finish(status: 'auth_failed', text: message);
      pc.addMessage(_toolMessage(pc, tool, message));
    } catch (e) {
      // v1.7.2 安全改进：MCP 日志记录
      LoggerService.instance.error(
        '[MCP] 工具调用失败: plugin=${_meta.id}, tool=$tool, error=$e',
        tag: 'MCP',
      );

      // M-1 修复：工具调用失败要作为可读错误回传给 AI，避免静默无反馈导致反复重试。
      final message = 'MCP tool "$tool" failed: ${e.toString()}';
      finish(status: 'failed', text: message);
      pc.addMessage(_toolMessage(pc, tool, message));
    }
  }

  /// v1.7.2 安全改进：危险工具调用确认弹窗
  Future<bool> _showDangerousToolConfirmation(
      BuildContext context, String tool, String args) async {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final cs = Theme.of(context).colorScheme;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: cs.tertiary, size: 28),
            const SizedBox(width: 8),
            Text(isZh ? '危险操作确认' : 'Dangerous Operation'),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                isZh
                    ? '⚠️ AI 想要调用一个危险工具：'
                    : '⚠️ AI wants to call a dangerous tool:',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cs.tertiary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: cs.tertiary.withValues(alpha: 0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${isZh ? '工具名称' : 'Tool'}: $tool'),
                    const SizedBox(height: 4),
                    Text('${isZh ? '参数' : 'Arguments'}: $args'),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                McpDangerousTools.getWarning(tool, isZh: isZh),
                style: TextStyle(
                  color: cs.tertiary,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                isZh
                    ? '此操作可能执行破坏性行为（删除文件、执行命令、修改数据库等）。请确认你了解此操作的风险。'
                    : 'This operation may perform destructive actions (delete files, execute commands, modify databases, etc.). Please confirm you understand the risks.',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(isZh ? '拒绝' : 'Deny'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: cs.tertiary,
            ),
            child: Text(isZh ? '允许一次' : 'Allow Once'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  /// O8-2：鉴权失败/熔断时回给模型的统一指引（O8-4：明确「换工具/重试无意义」）。
  /// build97 (P2-2 修复)：原消息硬编码中文，违反 isZh/tr 双语规则，补英文分支。
  /// build99 (验收 N2)：原文案指路「刷新/重试」按钮——该入口不存在；实际
  /// 复位路径是「钥匙图标改鉴权头 → updateMcpCustomHeaders 重建插件实例」，
  /// 文案改为与真实 UI/行为一致。
  String _authBlockedMessage({int? status, bool isZh = true}) {
    final code = status != null ? 'HTTP $status' : 'HTTP 401/403';
    if (!isZh) {
      return 'MCP "${_meta.name}" is unauthorized ($code). This service requires a '
          'valid key/token; retrying or switching to other tools of this plugin '
          'is futile. Stop calling this plugin and tell the user directly to '
          'open Settings → Plugin management → ${_meta.name} and tap the key '
          'icon (Headers/Auth) to update the auth headers — saving reconnects '
          'the plugin and clears this circuit breaker automatically.';
    }
    return 'MCP "${_meta.name}" 未授权（$code）。该服务需要有效密钥/Token；'
        '重试与换用本插件的其他工具均无效，请停止调用本插件，'
        '直接告知用户：到「设置 → 插件管理 → ${_meta.name}」'
        '点钥匙图标（请求头（鉴权））更新鉴权头——保存后插件自动重连，熔断自动复位。';
  }

  ChatMessage _toolMessage(PluginContext pc, String tool, String text) {
    return ChatMessage.create(
      conversationId:
          pc.userMsg?.conversationId ?? pc.assistantMsg.conversationId,
      role: MessageRole.user,
      // build173（S13/S19b）裸通道收口：MCP 的**上游返回原文**是本片最主要的一条
      // 不可信内容入口，原先这里自带一份 `_escape`（`& < " >` 四件套，不含 `=`）、
      // 外壳手拼，既没有 `encoding`/`trust`，也从没过结构锁。改成走同一个信封
      // 构造函数 ⇒ 转义与结构锁都在 builtin_plugins 那一处收口。
      // **删掉 `_escape`**：预转义再过一次外壳就是二次转义（`&amp;lt;`），
      // 属性位（plugin_id/tool）由信封自己按属性口径转义。
      content: toolResultTag(
        pluginId: _meta.id,
        tool: tool,
        body: text,
      ),
    );
  }

  void close() => _client.close();
}
