import 'dart:async';
import 'dart:convert';
import 'dart:typed_data' show BytesBuilder;

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/mcp_market_models.dart';
import 'logger_service.dart';
import 'package:flutter/foundation.dart';

enum McpRegistryErrorType {
  network,
  timeout,
  invalidResponse,
  noCompatibleServers,
}

class McpRegistryException implements Exception {
  final McpRegistryErrorType type;
  final String message;

  const McpRegistryException(this.type, this.message);

  @override
  String toString() => 'McpRegistryException(${type.name}): $message';
}

class McpRegistryService {
  /// build119：注册表请求可观测性——此前零日志，「搜不到」时无法从真机日志
  /// 判断是请求未发出、参数被忽略还是网络失败（用户实测「MCP 搜索没能力」
  /// 就是这么被误判的）。
  static final LoggerService _logger = LoggerService.instance;

  static final Uri defaultEndpoint =
      Uri.parse('https://registry.modelcontextprotocol.io/v0.1/servers');
  static const int maxPageSize = 100;
  static const int maxResponseBytes = 2 * 1024 * 1024;
  static const String _cacheKey = 'mcp_registry_first_page_v1';

  final http.Client _client;
  final Uri endpoint;
  final Duration timeout;
  final Future<SharedPreferences> Function() _preferences;
  final bool _ownsClient;

  McpRegistryService({
    http.Client? client,
    Uri? endpoint,
    this.timeout = const Duration(seconds: 15),
    Future<SharedPreferences> Function()? preferences,
  })  : _client = client ?? http.Client(),
        endpoint = endpoint ?? defaultEndpoint,
        _preferences = preferences ?? SharedPreferences.getInstance,
        _ownsClient = client == null;

  Future<McpRegistryPage> fetchPage({
    int limit = 30,
    String? cursor,
    String search = '',
    bool allowCacheFallback = true,
  }) async {
    if (limit < 1 || limit > maxPageSize) {
      throw const McpRegistryException(
        McpRegistryErrorType.invalidResponse,
        'Page limit is out of range',
      );
    }
    if (cursor != null && (cursor.isEmpty || cursor.length > 500)) {
      throw const McpRegistryException(
        McpRegistryErrorType.invalidResponse,
        'Cursor is invalid',
      );
    }

    try {
      final page =
          await _fetchNetwork(limit: limit, cursor: cursor, search: search);
      _logger.info(
          'MCP 注册表结果: ${page.servers.length} 条'
          '（search="${search.trim()}"${page.nextCursor != null ? "，有下一页" : ""}）',
          tag: 'McpRegistry');
      if (cursor == null) await _writeCache(page);
      return page;
    } on McpRegistryException {
      if (allowCacheFallback && cursor == null) {
        final cached = await _readCache(search);
        if (cached != null) return cached;
      }
      rethrow;
    } on Exception catch (error) {
      if (allowCacheFallback && cursor == null) {
        final cached = await _readCache(search);
        if (cached != null) {
          _logger.warn(
              'MCP 注册表网络失败，已回落首页缓存（本地按 "$search" 过滤）: $error',
              tag: 'McpRegistry');
          return cached;
        }
      }
      _logger.error('MCP 注册表请求失败: $error', tag: 'McpRegistry');
      throw McpRegistryException(
        McpRegistryErrorType.network,
        'Registry request failed: ${error.runtimeType}',
      );
    }
  }

  Future<McpRegistryPage> _fetchNetwork({
    required int limit,
    String? cursor,
    String search = '',
  }) async {
    final query = search.trim();
    // build119 修复（实测取证）：官方注册表只认 **search** 参数；旧代码拼的是
    // `q` —— 该参数被服务端**静默忽略**，于是「无论搜什么都返回同一批默认结果」，
    // 用户感知为「MCP 没有搜索能力」。三测对照（curl 2026-09-16）：
    //   ?q=weather      → 返回 ac.inference.sh/mcp（与 weather 无关，默认列表）
    //   ?q=zzzznotexist → 同上（完全一致，证实 q 不生效）
    //   ?search=zzzznotexist → {"servers":[]}（**生效**，过滤到 0 条）
    final uri = endpoint.replace(queryParameters: {
      ...endpoint.queryParameters,
      'limit': '$limit',
      if (cursor != null) 'cursor': cursor,
      if (query.isNotEmpty) 'search': query,
    });
    _logger.info(
        'MCP 注册表请求: uri=${uri.toString().replaceAll(RegExp(r'[?&]'), ' ')}',
        tag: 'McpRegistry');
    final request = http.Request('GET', uri)
      ..followRedirects = false
      ..headers['Accept'] = 'application/json';

    http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(timeout);
    } on TimeoutException catch (_) {
      throw const McpRegistryException(
        McpRegistryErrorType.timeout,
        'Registry request timed out',
      );
    } on Exception catch (error) {
      throw McpRegistryException(
        McpRegistryErrorType.network,
        'Registry request failed: ${error.runtimeType}',
      );
    }
    if (response.isRedirect) {
      throw const McpRegistryException(
        McpRegistryErrorType.invalidResponse,
        'Registry redirect was rejected',
      );
    }
    if (response.statusCode != 200) {
      throw McpRegistryException(
        McpRegistryErrorType.network,
        'Registry returned HTTP ${response.statusCode}',
      );
    }
    if (!_isJsonContentType(response.headers['content-type'])) {
      throw const McpRegistryException(
        McpRegistryErrorType.invalidResponse,
        'Registry response is not JSON',
      );
    }

    final bytes = await _readLimited(response.stream, maxResponseBytes);
    dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException catch (_) {
      throw const McpRegistryException(
        McpRegistryErrorType.invalidResponse,
        'Registry returned malformed JSON',
      );
    }
    if (decoded is! Map) {
      throw const McpRegistryException(
        McpRegistryErrorType.invalidResponse,
        'Registry response root must be an object',
      );
    }
    return _parsePage(Map<String, dynamic>.from(decoded));
  }

  McpRegistryPage _parsePage(Map<String, dynamic> json) {
    final rawServers = json['servers'];
    final rawMetadata = json['metadata'];
    if (rawServers is! List || rawServers.length > maxPageSize) {
      throw const McpRegistryException(
        McpRegistryErrorType.invalidResponse,
        'Registry servers list is invalid',
      );
    }

    final seen = <String>{};
    final servers = <McpRegistryServer>[];
    for (final raw in rawServers) {
      if (raw is! Map) continue;
      final entry = Map<String, dynamic>.from(raw);
      if (!_isCompatibleEntry(entry)) continue;
      try {
        final server = McpRegistryServer.fromJson(entry);
        if (server.status == 'deleted' || server.status == 'deprecated') {
          continue;
        }
        if (!seen.add(server.name)) continue;
        servers.add(server);
      } on FormatException catch (_) {
        continue;
      }
    }

    final metadata = rawMetadata is Map
        ? Map<String, dynamic>.from(rawMetadata)
        : const <String, dynamic>{};
    final rawCursor = metadata['nextCursor'] ?? metadata['next_cursor'];
    final nextCursor =
        rawCursor is String && rawCursor.isNotEmpty && rawCursor.length <= 500
            ? rawCursor
            : null;
    if (servers.isEmpty) {
      throw const McpRegistryException(
        McpRegistryErrorType.noCompatibleServers,
        'No compatible anonymous HTTPS MCP servers were found',
      );
    }
    return McpRegistryPage(servers: servers, nextCursor: nextCursor);
  }

  bool _isCompatibleEntry(Map<String, dynamic> entry) {
    final rawServer = entry['server'];
    if (rawServer is! Map) return false;
    final server = Map<String, dynamic>.from(rawServer);
    if (_containsCredentialRequirement(server)) return false;

    final packages = server['packages'];
    if (packages is List &&
        packages.any((item) {
          if (item is! Map) return true;
          final type = '${item['registryType'] ?? ''}'.toLowerCase();
          final transport = item['transport'];
          final transportType =
              transport is Map ? '${transport['type'] ?? ''}' : '';
          return const {'npm', 'pypi', 'nuget', 'oci', 'docker', 'mcpb'}
                  .contains(type) ||
              transportType.toLowerCase() == 'stdio';
        })) {
      if (server['remotes'] is! List) return false;
    }

    final remotes = server['remotes'];
    return remotes is List &&
        remotes.any((item) {
          if (item is! Map) return false;
          final type = item['type'];
          final uri = Uri.tryParse(item['url'] as String? ?? '');
          return (type == 'streamable-http' || type == 'sse') &&
              uri != null &&
              isSafeMcpHttpsUri(uri) &&
              !_containsCredentialRequirement(Map<String, dynamic>.from(item));
        });
  }

  bool _containsCredentialRequirement(dynamic value, [String key = '']) {
    final normalizedKey = key.toLowerCase();
    if (const {
      'headers',
      'environmentvariables',
      'env',
      'secrets',
      'oauth',
      'authorization',
    }.contains(normalizedKey)) {
      if (value is Map && value.isNotEmpty) return true;
      if (value is List && value.isNotEmpty) return true;
      if (value is String && value.isNotEmpty) return true;
    }
    if (value is Map) {
      return value.entries.any(
        (entry) => _containsCredentialRequirement(entry.value, '${entry.key}'),
      );
    }
    if (value is List) {
      return value.any((item) => _containsCredentialRequirement(item, key));
    }
    return false;
  }

  Future<void> _writeCache(McpRegistryPage page) async {
    try {
      final prefs = await _preferences();
      final value = jsonEncode({
        'cachedAt': DateTime.now().toUtc().toIso8601String(),
        'nextCursor': page.nextCursor,
        'servers': page.servers.map((e) => e.toJson()).toList(growable: false),
      });
      if (utf8.encode(value).length <= maxResponseBytes) {
        await prefs.setString(_cacheKey, value);
      }
    } on Exception catch (e) { debugPrint('catch 静默异常: $e'); }
  }

  Future<McpRegistryPage?> _readCache(String search) async {
    try {
      final prefs = await _preferences();
      final raw = prefs.getString(_cacheKey);
      if (raw == null || utf8.encode(raw).length > maxResponseBytes) {
        return null;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final map = Map<String, dynamic>.from(decoded);
      final rawServers = map['servers'];
      final cachedAt = DateTime.tryParse(map['cachedAt'] as String? ?? '');
      if (rawServers is! List ||
          cachedAt == null ||
          rawServers.length > maxPageSize) {
        return null;
      }
      final query = search.trim().toLowerCase();
      final servers = <McpRegistryServer>[];
      for (final raw in rawServers.whereType<Map>()) {
        try {
          final server =
              McpRegistryServer.fromCacheJson(Map<String, dynamic>.from(raw));
          if (query.isEmpty ||
              server.name.toLowerCase().contains(query) ||
              server.title.toLowerCase().contains(query) ||
              server.description.toLowerCase().contains(query)) {
            servers.add(server);
          }
        } on FormatException catch (_) {
          continue;
        }
      }
      return McpRegistryPage(
        servers: servers,
        nextCursor: map['nextCursor'] as String?,
        fromCache: true,
        cachedAt: cachedAt.toUtc(),
      );
    } on Exception catch (_) {
      return null;
    }
  }

  void close() {
    if (_ownsClient) _client.close();
  }

  static bool _isJsonContentType(String? value) =>
      value?.split(';').first.trim().toLowerCase() == 'application/json';

  static Future<List<int>> _readLimited(
    Stream<List<int>> stream,
    int maxBytes,
  ) async {
    final builder = BytesBuilder(copy: false);
    var length = 0;
    await for (final chunk in stream) {
      length += chunk.length;
      if (length > maxBytes) {
        throw const McpRegistryException(
          McpRegistryErrorType.invalidResponse,
          'Registry response exceeds size limit',
        );
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }
}
