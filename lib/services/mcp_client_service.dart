import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../constants.dart';
import '../models/mcp_market_models.dart';
import '../utils/ssrf_guard.dart';

/// O8-1（build96）：MCP 鉴权失败专用异常（HTTP 401/403）。
/// 与网络/参数错误区分：主循环与插件据此做「插件级熔断」——同插件一次 401
/// 即整插件短路，换工具名/重试均不再真实发请求（实测模型连环换工具试 5 次 401）。
class McpAuthException implements Exception {
  final int status; // 401 / 403
  final String? endpoint;
  String? pluginId; // 客户端不知道 pluginId，由调用侧补挂

  McpAuthException({required this.status, this.endpoint, this.pluginId});

  @override
  String toString() =>
      'McpAuthException(HTTP $status${endpoint != null ? ', $endpoint' : ''})';
}

class McpClientService {
  static const int maxRedirects = 5;
  static const int maxResponseBytes = 1024 * 1024;
  static const int maxTools = McpToolDefinition.maxToolCount;

  final http.Client _client;
  // v1.7.37（待办⑬）：自定义鉴权请求头（Authorization: Bearer 等）。
  // 敏感信息：含凭据明文，绝不写入日志。
  final Map<String, String> _customHeaders;
  // build153（SSRF）：域名→IP 的解析器。默认走系统 DNS；单测注入假解析器，
  // 不需要真发请求即可钉住「解析到内网 / 解析失败一律拒绝」的语义。
  final SsrfIpLookup? _ipLookup;
  int _nextId = 0;
  String? _sessionId;
  String? _endpoint;
  Map<String, McpToolDefinition> _tools = const {};

  McpClientService(
      {http.Client? client,
      Map<String, String>? customHeaders,
      SsrfIpLookup? ipLookup})
      : _client = client ?? http.Client(),
        _customHeaders = Map.unmodifiable(customHeaders ?? const {}),
        _ipLookup = ipLookup;

  Uri validateEndpointForTesting(String endpoint) =>
      _validateEndpoint(endpoint);

  /// build153：**入口级**完整闸（语法 + 字面 IP + DNS→IP）。安装/测试连接、
  /// 以及市场条目下发校验走这里；DNS 解析失败按拒绝处理（fail-closed）。
  Future<Uri> validateEndpointForSsrf(String endpoint) async {
    final uri = _validateEndpoint(endpoint);
    final reason = await ssrfRejectionReason(
        uri, lookup: _ipLookup ?? defaultSsrfIpLookup);
    if (reason != null) {
      throw FormatException('MCP endpoint rejected by SSRF guard: $reason');
    }
    return uri;
  }

  Uri _validateEndpoint(String endpoint) {
    final uri = Uri.tryParse(endpoint);
    if (!isSafeMcpHttpsUri(uri)) {
      throw const FormatException('MCP endpoint must be a public HTTPS URL');
    }
    return uri!;
  }

  /// 语法闸 + IP 层 SSRF 判定。每个出站 hop 前都要过一次：重定向可以把请求带到
  /// 另一台主机，只验首跳等于没验。
  ///
  /// `_ipLookup == null` 时跑**同步层**（https/userInfo/内部域名字面/IP 字面量分类，
  /// 含 IPv4-mapped、十进制/八进制数字化形态）；注入了解析器（安装/测试连接入口、
  /// 以及市场条目下发时的批量校验）才追加 DNS→IP 判定。 DNS 失败一律拒绝。
  Future<Uri> _guardEndpoint(String endpoint) async {
    final uri = _validateEndpoint(endpoint);
    final lookup = _ipLookup;
    if (lookup == null) return uri;
    final reason = await ssrfRejectionReason(uri, lookup: lookup);
    if (reason != null) {
      throw FormatException('MCP endpoint rejected by SSRF guard: $reason');
    }
    return uri;
  }

  Future<http.Response> _post(Map<String, dynamic> payload) async {
    var uri = await _guardEndpoint(_endpoint!);
    for (var redirect = 0;; redirect++) {
      final request = http.Request('POST', uri)
        ..followRedirects = false
        ..headers.addAll(_headers())
        ..body = jsonEncode(payload);
      final streamed = await _client.send(request).timeout(
            const Duration(seconds: 30),
          );
      if (!_isRedirectStatus(streamed.statusCode)) {
        return http.Response.fromStream(streamed);
      }
      if (redirect >= maxRedirects) {
        throw const FormatException('MCP redirect limit exceeded');
      }
      final location = streamed.headers['location'];
      if (location == null) {
        throw const FormatException('MCP redirect has no location');
      }
      // 重定向后再验一次：换主机 / 换 scheme / 被指向内网或元数据段都在此拦。
      uri = await _guardEndpoint(uri.resolve(location).toString());
    }
  }

  static bool _isRedirectStatus(int statusCode) =>
      statusCode == 301 ||
      statusCode == 302 ||
      statusCode == 303 ||
      statusCode == 307 ||
      statusCode == 308;

  // 自定义头先放，协议头后写（Content-Type/Accept/Protocol-Version 不可被自定义覆盖，
  // 防止破坏 MCP 协议握手；Authorization 等鉴权头正常生效）。
  Map<String, String> _headers() => {
        ..._customHeaders,
        'Content-Type': 'application/json',
        'Accept': 'application/json, text/event-stream',
        'MCP-Protocol-Version': '2025-03-26',
        if (_sessionId != null) 'Mcp-Session-Id': _sessionId!,
      };

  Future<void> _notify(String method, Map<String, dynamic> params) async {
    final response = await _post({
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
    });
    if (response.statusCode < 200 || response.statusCode >= 300) {
      _throwForStatus(response.statusCode);
    }
  }

  /// O8-1：401/403 抛专用鉴权异常，其余维持通用 Exception。
  Never _throwForStatus(int statusCode) {
    if (statusCode == 401 || statusCode == 403) {
      throw McpAuthException(status: statusCode, endpoint: _endpoint);
    }
    throw Exception('MCP HTTP $statusCode');
  }

  Future<Map<String, dynamic>> _request(
      String method, Map<String, dynamic> params) async {
    final id = ++_nextId;
    final response = await _post({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });
    if (response.statusCode < 200 || response.statusCode >= 300) {
      _throwForStatus(response.statusCode);
    }
    final session = response.headers['mcp-session-id'];
    if (session != null && session.isNotEmpty) _sessionId = session;
    if (response.bodyBytes.length > maxResponseBytes) {
      throw Exception('MCP response is too large');
    }
    final jsonBody =
        _decodeResponse(response.body, response.headers['content-type'] ?? '');
    if (jsonBody['id'] != id) {
      throw Exception('MCP response id mismatch');
    }
    if (jsonBody['error'] is Map) {
      throw Exception(
          jsonBody['error']['message']?.toString() ?? 'MCP request failed');
    }
    final result = jsonBody['result'];
    if (result is! Map) {
      throw const FormatException('MCP result must be an object');
    }
    return Map<String, dynamic>.from(result);
  }

  Map<String, dynamic> _decodeResponse(String body, String contentType) {
    if (contentType.toLowerCase().contains('text/event-stream')) {
      final events = <String>[];
      final dataLines = <String>[];
      for (final line in body.split(RegExp(r'\r?\n'))) {
        if (line.isEmpty) {
          if (dataLines.isNotEmpty) {
            events.add(dataLines.join('\n'));
            dataLines.clear();
          }
        } else if (line.startsWith('data:')) {
          dataLines.add(line.substring(5).trimLeft());
        }
      }
      if (dataLines.isNotEmpty) events.add(dataLines.join('\n'));

      for (final data in events.reversed) {
        if (data.isNotEmpty && data != '[DONE]') {
          final decoded = jsonDecode(data);
          if (decoded is Map) return Map<String, dynamic>.from(decoded);
        }
      }
      throw const FormatException('MCP SSE response has no data');
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw const FormatException('MCP response must be an object');
    }
    return Map<String, dynamic>.from(decoded);
  }

  Future<List<Map<String, dynamic>>> discoverTools(String endpoint) async {
    _endpoint = _validateEndpoint(endpoint).toString();
    _sessionId = null;
    _tools = const {};
    await _request('initialize', {
      'protocolVersion': '2025-03-26',
      'capabilities': <String, dynamic>{},
      'clientInfo': {'name': 'Nexus', 'version': kAppVersionConst},
    });
    await _notify('notifications/initialized', {});

    final tools = <Map<String, dynamic>>[];
    final cursors = <String>{};
    String? cursor;
    do {
      final result = await _request('tools/list', {
        if (cursor != null) 'cursor': cursor,
      });
      final raw = result['tools'];
      if (raw is! List || tools.length + raw.length > maxTools) {
        throw const FormatException('MCP tools/list returned invalid tools');
      }
      for (final rawTool in raw) {
        if (rawTool is! Map) {
          throw const FormatException('MCP tool must be an object');
        }
        final tool = Map<String, dynamic>.from(rawTool);
        final definition = McpToolDefinition.fromJson(tool);
        if (_tools.containsKey(definition.name)) {
          throw const FormatException('MCP tools/list returned duplicate tool');
        }
        _tools = {..._tools, definition.name: definition};
        tools.add(tool);
      }
      final next = result['nextCursor'];
      if (next == null) {
        cursor = null;
      } else if (next is! String ||
          next.isEmpty ||
          next.length > 500 ||
          !cursors.add(next)) {
        throw const FormatException('MCP tools/list returned invalid cursor');
      } else {
        cursor = next;
      }
    } while (cursor != null);
    if (tools.isEmpty) {
      throw const FormatException('MCP tools/list returned no tools');
    }
    return tools;
  }

  /// 运行时执行 tools/call 前确保已完成 initialize 握手。
  /// 安装阶段的 discoverTools 会建立 session，但运行时恢复出的插件持有全新 client，
  /// 必须补一次 initialize + notifications/initialized，严格有状态服务端才会接受调用。
  Future<void> _ensureInitialized() async {
    if (_sessionId != null) return;
    await _request('initialize', {
      'protocolVersion': '2025-03-26',
      'capabilities': <String, dynamic>{},
      'clientInfo': {'name': 'Nexus', 'version': kAppVersionConst},
    });
    await _notify('notifications/initialized', {});
  }

  Future<dynamic> toolsCall(
      String endpoint, String tool, Map<String, dynamic> arguments) async {
    _endpoint = _validateEndpoint(endpoint).toString();
    // v1.7.16 修复：运行时恢复的插件持有全新 client，_tools 为空会短路白名单校验
    // （原 `_tools.isNotEmpty &&` 条件在空表时整体为 false，校验被跳过）。
    // 改为：空表时先 discoverTools 填充 schema，再严格 containsKey 校验。
    if (_tools.isEmpty) {
      await discoverTools(endpoint);
    } else {
      await _ensureInitialized();
    }
    if (!RegExp(r'^[A-Za-z0-9_.:/-]{1,128}$').hasMatch(tool) ||
        !_tools.containsKey(tool)) {
      throw const FormatException('MCP tool is not in the discovered schema');
    }
    if (jsonEncode(arguments).length > 100000) {
      throw const FormatException('MCP arguments exceed size limit');
    }
    final result = await _request('tools/call', {
      'name': tool,
      'arguments': arguments,
    });
    return result['content'] ?? result['structuredContent'] ?? result;
  }

  Future<void> closeSession() async {
    if (_endpoint == null || _sessionId == null) return;
    try {
      // 会话关闭也是出站请求，且端点可能在别处被改写过 ⇒ 先过 SSRF 闸再发。
      final uri = await _guardEndpoint(_endpoint!);
      final request = http.Request('DELETE', uri)
        ..followRedirects = false
        ..headers.addAll(_headers());
      await _client.send(request).timeout(const Duration(seconds: 10));
    } on Exception {
      // Session closure is best effort.
    } finally {
      _sessionId = null;
    }
  }

  void close() => _client.close();
}
