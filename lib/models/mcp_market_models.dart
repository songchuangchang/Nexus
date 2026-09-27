import '../utils/ssrf_guard.dart';

/// v1.7.2 安全改进：危险工具黑名单
/// 这些工具可能执行破坏性操作，调用前需要用户确认
///
/// build97 (P1-7 修复)：原实现是精确名全等匹配，改个名（delete_file_v2 /
/// remove_all / run_script / db_exec / file_delete / execute_sql_query）
/// 就绕过确认弹窗。改三层判定：
///   1) 全名精确匹配（历史清单保留，含多词名）；
///   2) 词元匹配：按下划线/连字符/数字拆词，任一词元命中危险词根即确认
///      （delete_file_v2→{delete,file,v2}，run_script→{run,script}）；
///   3) 安全子串匹配：绝不会误伤的词根（delete/drop/sql 等）做 contains 兜底，
///      挡住 filedelete 这类连写变体；rm/run/send 等短词不走子串
///      （会误伤 alarm/sender）。
class McpDangerousTools {
  /// 危险工具全名黑名单（不区分大小写）——精确匹配层
  static const Set<String> dangerousToolNames = {
    // 文件操作
    'delete_file', 'delete', 'remove_file', 'remove',
    'delete_directory', 'rmdir', 'rm',
    // 写入/上传类（build99 F4：未受控写入/上传等价于外泄/污染）
    'write_file', 'upload_file', 'cmdline_info',
    // 执行类
    'execute', 'exec', 'run_command', 'run', 'shell', 'sh',
    'bash', 'zsh', 'cmd', 'powershell',
    'execute_command', 'system', 'eval',
    // 数据库操作
    'execute_sql', 'drop_table', 'delete_from',
    'truncate', 'drop_database',
    // 网络操作
    'send_request', 'http_request', 'fetch',
    'wget', 'curl', 'nc', 'ncat', 'netcat',
    // 危险操作
    'format', 'reset', 'clear', 'wipe',
    'clearcache',
    'send_email', 'send_message',
  };

  /// 危险词元（拆词后任一命中即危险）
  static const Set<String> _dangerousTokens = {
    // 文件/数据破坏
    'delete', 'remove', 'rm', 'rmdir', 'wipe', 'destroy',
    'drop', 'truncate', 'overwrite', 'move', 'rename',
    'chmod', 'chown', 'format', 'reset', 'clear',
    // 写入/上传/追加/PUT 类（build100 中2 验收 F4：补 write/upload/append/put/
    // cmdline，挡住 write_file_v2 / upload_file_x / append_file / put_object /
    // cmdline_info_v2 等带版本号的改名绕过；词元是精确相等，typewriter /
    // uploader / output / computer 等连写/含 put 子串的常规工具不会被误伤——
    // 它们拆词后整词不等于 write/upload/append/put/cmdline）
    'write', 'upload', 'append', 'put', 'cmdline',
    // 命令/代码执行（build99 验收 N5：补 shell 家族 bash/zsh/cmd/sh）
    'exec', 'execute', 'shell', 'eval', 'run',
    'bash', 'zsh', 'cmd', 'sh',
    // 数据库
    'sql',
    // 网络外发（request/email/message 不入词元——会误伤 make_request /
    // list_emails / get_messages 等只读工具；send_* 由 send 词元兜底）
    'fetch', 'http', 'send',
    // 网络下载器（build99 验收 N5：wget/curl/nc 可被用于外带数据/拉恶意载荷）
    'wget', 'curl', 'nc', 'ncat',
    // 系统控制
    'kill', 'shutdown',
  };

  /// 安全危险子串：这些词根作为子串不会误伤正常词，用于挡住连写变体
  /// （如 filedelete / dropuser / executesql）。
  /// 注意：rm / run / send / clear 等短词严禁放进来
  /// （alarm / runtime / sender 会误伤）。
  static const List<String> _dangerousSubstrings = [
    'delete', 'remove', 'truncate', 'destroy',
    'drop', 'wipe', 'exec', 'sql', 'shell',
  ];

  static final RegExp _wordRuns = RegExp(r'[a-z]+');

  /// 检查工具是否危险
  static bool isDangerous(String toolName) {
    final n = toolName.toLowerCase().trim();
    if (n.isEmpty) return false;
    // 1) 全名精确匹配
    if (dangerousToolNames.contains(n)) return true;
    // 2) 词元匹配
    final tokens =
        _wordRuns.allMatches(n).map((m) => m.group(0)!).toSet();
    if (tokens.any(_dangerousTokens.contains)) return true;
    // 3) 安全子串兜底（连写变体）
    if (_dangerousSubstrings.any(n.contains)) return true;
    return false;
  }

  /// 获取危险工具的警告信息
  static String getWarning(String toolName, {bool isZh = true}) {
    if (isZh) {
      return '⚠️ 危险操作：此工具可能执行破坏性操作（删除文件、执行命令、修改数据库等）。\n\n工具：$toolName\n\n请确认你了解此操作的风险。';
    }
    return '⚠️ Dangerous Operation: This tool may perform destructive actions (delete files, execute commands, modify databases, etc.).\n\nTool: $toolName\n\nPlease confirm you understand the risks.';
  }
}

class McpModelFormatException implements FormatException {
  @override
  final String message;
  @override
  final dynamic source;
  @override
  final int? offset;

  const McpModelFormatException(this.message, [this.source, this.offset]);

  @override
  String toString() => 'McpModelFormatException: $message';
}

/// v1.7.37（待办⑬）：MCP Registry remotes[].headers 声明的鉴权请求头规格。
/// 官方 registry JSON 里 remote 可带 headers: [{name, description, isRequired, isSecret}]，
/// 安装时据此引导用户填写真实凭据值。
class McpHeaderSpec {
  static const int maxNameLength = 128;
  static const int maxDescriptionLength = 500;

  final String name;
  final String description;
  final bool isRequired;
  final bool isSecret;

  const McpHeaderSpec({
    required this.name,
    this.description = '',
    this.isRequired = false,
    this.isSecret = true,
  });

  factory McpHeaderSpec.fromJson(Map<String, dynamic> json) {
    final name = _requiredString(json, 'name', maxNameLength);
    if (!isValidHeaderName(name)) {
      throw const McpModelFormatException('Header name is invalid');
    }
    return McpHeaderSpec(
      name: name,
      description:
          _optionalString(json, 'description', maxDescriptionLength) ?? '',
      isRequired: json['isRequired'] == true,
      isSecret: json['isSecret'] != false,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'isRequired': isRequired,
        'isSecret': isSecret,
      };
}

/// HTTP header 名校验（RFC 7230 token，拒绝控制字符/注入）
bool isValidHeaderName(String name) =>
    RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]{1,128}$").hasMatch(name);

/// HTTP header 值校验（拒绝 CR/LF 注入）
bool isValidHeaderValue(String value) =>
    value.length <= 4096 && !value.contains(RegExp(r'[\r\n]'));

/// 解析/清洗 customHeaders：过滤非法 name/value，数量上限 20。
/// 敏感信息：返回值可能含凭据明文，严禁写入日志。
Map<String, String> sanitizeCustomHeaders(dynamic raw) {
  if (raw is! Map) return const {};
  final result = <String, String>{};
  for (final entry in raw.entries) {
    if (result.length >= 20) break;
    final key = entry.key;
    final value = entry.value;
    if (key is! String || value is! String) continue;
    final name = key.trim();
    if (!isValidHeaderName(name) || !isValidHeaderValue(value)) continue;
    if (value.isEmpty) continue;
    result[name] = value;
  }
  return result;
}

class McpRegistryServer {
  static const int maxNameLength = 200;
  static const int maxTitleLength = 200;
  static const int maxDescriptionLength = 4000;
  static const int maxVersionLength = 100;

  final String name;
  final String title;
  final String description;
  final String version;
  final String status;
  final Uri? homepage;
  final Uri endpoint;
  final String transportType;

  /// v1.7.37（待办⑬）：registry remote 声明的鉴权 header 规格（可为空）
  final List<McpHeaderSpec> headerSpecs;

  const McpRegistryServer({
    required this.name,
    required this.title,
    required this.description,
    required this.version,
    required this.status,
    required this.endpoint,
    required this.transportType,
    this.homepage,
    this.headerSpecs = const [],
  });

  factory McpRegistryServer.fromJson(Map<String, dynamic> json) {
    final rawServer = json['server'];
    final server =
        rawServer is Map ? Map<String, dynamic>.from(rawServer) : json;
    final name = _requiredString(server, 'name', maxNameLength);
    final version = _requiredString(server, 'version', maxVersionLength);
    final title = _optionalString(server, 'title', maxTitleLength) ?? name;
    final description =
        _optionalString(server, 'description', maxDescriptionLength) ?? '';

    final officialMeta = _officialMetadata(json);
    final status =
        (_optionalString(officialMeta, 'status', 40) ?? 'active').toLowerCase();
    final remote = _selectRemote(server['remotes']);
    final endpoint = Uri.tryParse(remote.$2);
    if (!isSafeMcpHttpsUri(endpoint)) {
      throw const McpModelFormatException('Remote endpoint must be HTTPS');
    }

    Uri? homepage;
    final homepageValue = _optionalString(server, 'websiteUrl', 2048) ??
        _optionalString(server, 'homepage', 2048);
    if (homepageValue != null) {
      final parsed = Uri.tryParse(homepageValue);
      // build153：市场条目的 baseUrl/主页同样过 SSRF 闸（旧实现只看 scheme==https
      // 与非空 host，`https://169.254.169.254/` 这类会原样存进模型并展示/点开）。
      if (parsed != null && isSafeMcpHttpsUri(parsed)) {
        homepage = parsed;
      }
    }

    return McpRegistryServer(
      name: name,
      title: title,
      description: description,
      version: version,
      status: status,
      homepage: homepage,
      endpoint: endpoint!,
      transportType: remote.$1,
      headerSpecs: remote.$3,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'title': title,
        'description': description,
        'version': version,
        'status': status,
        'homepage': homepage?.toString(),
        'endpoint': endpoint.toString(),
        'transportType': transportType,
        'headerSpecs': headerSpecs.map((e) => e.toJson()).toList(),
      };

  factory McpRegistryServer.fromCacheJson(Map<String, dynamic> json) {
    final endpoint = Uri.tryParse(json['endpoint'] as String? ?? '');
    if (!isSafeMcpHttpsUri(endpoint)) {
      throw const McpModelFormatException('Cached endpoint is invalid');
    }
    final homepageValue = json['homepage'] as String?;
    final parsedHomepage =
        homepageValue == null ? null : Uri.tryParse(homepageValue);
    return McpRegistryServer(
      name: _requiredString(json, 'name', maxNameLength),
      title: _requiredString(json, 'title', maxTitleLength),
      description:
          _optionalString(json, 'description', maxDescriptionLength) ?? '',
      version: _requiredString(json, 'version', maxVersionLength),
      status: _requiredString(json, 'status', 40),
      endpoint: endpoint!,
      transportType: _requiredString(json, 'transportType', 40),
      homepage: parsedHomepage,
      headerSpecs: _headerSpecsFromJson(json['headerSpecs']),
    );
  }

  static List<McpHeaderSpec> _headerSpecsFromJson(dynamic raw) {
    if (raw is! List || raw.length > 20) return const [];
    final specs = <McpHeaderSpec>[];
    for (final item in raw) {
      if (item is! Map) continue;
      specs.add(McpHeaderSpec.fromJson(Map<String, dynamic>.from(item)));
    }
    return List.unmodifiable(specs);
  }

  static Map<String, dynamic> _officialMetadata(Map<String, dynamic> json) {
    final rawMeta = json['_meta'];
    if (rawMeta is! Map) return const {};
    final official = rawMeta['io.modelcontextprotocol.registry/official'];
    return official is Map ? Map<String, dynamic>.from(official) : const {};
  }

  static (String, String, List<McpHeaderSpec>) _selectRemote(
      dynamic rawRemotes) {
    if (rawRemotes is! List) {
      throw const McpModelFormatException('Server has no remote transport');
    }
    String? sseUrl;
    List<McpHeaderSpec> sseSpecs = const [];
    for (final raw in rawRemotes) {
      if (raw is! Map) continue;
      final remote = Map<String, dynamic>.from(raw);
      final type = remote['type'];
      final url = remote['url'];
      if (url is! String || url.trim().isEmpty) continue;
      final parsed = Uri.tryParse(url);
      if (!isSafeMcpHttpsUri(parsed)) continue;
      if (type == 'streamable-http') {
        return (
          'streamable-http',
          url,
          _headerSpecsFromJson(remote['headers'])
        );
      }
      if (type == 'sse' && sseUrl == null) {
        sseUrl = url;
        sseSpecs = _headerSpecsFromJson(remote['headers']);
      }
    }
    if (sseUrl != null) return ('sse', sseUrl, sseSpecs);
    throw const McpModelFormatException(
        'Server has no supported remote transport');
  }
}

class McpToolDefinition {
  static const int maxNameLength = 128;
  static const int maxDescriptionLength = 2000;
  static const int maxToolCount = 100;

  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  const McpToolDefinition({
    required this.name,
    required this.description,
    required this.inputSchema,
  });

  factory McpToolDefinition.fromJson(Map<String, dynamic> json) {
    final name = _requiredString(json, 'name', maxNameLength);
    if (!RegExp(r'^[A-Za-z0-9_.:/-]+$').hasMatch(name)) {
      throw const McpModelFormatException(
          'Tool name contains invalid characters');
    }
    final rawSchema = json['inputSchema'];
    if (rawSchema is! Map) {
      throw const McpModelFormatException('Tool inputSchema must be an object');
    }
    final schema = Map<String, dynamic>.from(rawSchema);
    _validateJsonValue(schema, depth: 0, maxDepth: 12, itemBudget: 1000);
    return McpToolDefinition(
      name: name,
      description:
          _optionalString(json, 'description', maxDescriptionLength) ?? '',
      inputSchema: schema,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'inputSchema': inputSchema,
      };
}

class InstalledMcpConfig {
  final String serverName;
  final String serverVersion;
  final Uri endpoint;
  final String protocolVersion;
  final List<McpToolDefinition> tools;
  final DateTime lastVerifiedAt;

  /// v1.7.37（待办⑬）：自定义鉴权请求头（如 Authorization: Bearer ...）。
  /// 敏感信息：含凭据明文，严禁写入日志/备份调试输出。
  /// 持久化在 plugins 表 metadataJson JSON 列内（extra），老数据无此键 → fromJson 默认 {}，
  /// 无需 DB 列迁移（五保险仅适用独立列）。
  final Map<String, String> customHeaders;

  const InstalledMcpConfig({
    required this.serverName,
    required this.serverVersion,
    required this.endpoint,
    required this.protocolVersion,
    required this.tools,
    required this.lastVerifiedAt,
    this.customHeaders = const {},
  });

  factory InstalledMcpConfig.fromJson(Map<String, dynamic> json) {
    final endpoint = Uri.tryParse(json['endpoint'] as String? ?? '');
    final verifiedAt =
        DateTime.tryParse(json['lastVerifiedAt'] as String? ?? '');
    final rawTools = json['tools'];
    if (!isSafeMcpHttpsUri(endpoint) || rawTools is! List) {
      throw const McpModelFormatException('Installed endpoint is invalid');
    }
    if (verifiedAt == null ||
        rawTools.length > McpToolDefinition.maxToolCount) {
      throw const McpModelFormatException(
          'Installed MCP configuration is invalid');
    }
    return InstalledMcpConfig(
      serverName: _requiredString(json, 'serverName', 200),
      serverVersion: _requiredString(json, 'serverVersion', 100),
      endpoint: endpoint!,
      protocolVersion: _requiredString(json, 'protocolVersion', 40),
      tools: rawTools.map((e) {
        if (e is! Map) {
          throw const McpModelFormatException('Installed MCP tool is invalid');
        }
        return McpToolDefinition.fromJson(Map<String, dynamic>.from(e));
      }).toList(growable: false),
      lastVerifiedAt: verifiedAt.toUtc(),
      customHeaders: sanitizeCustomHeaders(json['customHeaders']),
    );
  }

  Map<String, dynamic> toJson() => {
        'serverName': serverName,
        'serverVersion': serverVersion,
        'endpoint': endpoint.toString(),
        'protocolVersion': protocolVersion,
        'tools': tools.map((e) => e.toJson()).toList(growable: false),
        'lastVerifiedAt': lastVerifiedAt.toUtc().toIso8601String(),
        if (customHeaders.isNotEmpty) 'customHeaders': customHeaders,
      };
}

class McpRegistryPage {
  final List<McpRegistryServer> servers;
  final String? nextCursor;
  final bool fromCache;
  final DateTime? cachedAt;

  const McpRegistryPage({
    required this.servers,
    this.nextCursor,
    this.fromCache = false,
    this.cachedAt,
  });

  McpRegistryPage copyWith({
    List<McpRegistryServer>? servers,
    String? nextCursor,
    bool? fromCache,
    DateTime? cachedAt,
  }) =>
      McpRegistryPage(
        servers: servers ?? this.servers,
        nextCursor: nextCursor ?? this.nextCursor,
        fromCache: fromCache ?? this.fromCache,
        cachedAt: cachedAt ?? this.cachedAt,
      );
}

/// build153：MCP URL 的**同步**安全闸（scheme=https + 字面 IP 分类 + 内部域名）。
///
/// 判定实现挪到 `lib/utils/ssrf_guard.dart`（纯函数、可单测）。域名要判内网必须
/// 走 DNS，同步函数做不到 ⇒ 下发/自填入口在真正发请求前还要过
/// [assertMcpEndpointSsrfSafe]（`mcp_client_service` 逐跳调用）。
bool isSafeMcpHttpsUri(Uri? uri) => ssrfEndpointSyntaxRejection(uri) == null;

/// 市场条目 baseUrl / 端点的完整 SSRF 闸（含 DNS，解析失败即拒绝）。
/// 返回 `null` 表示放行，否则为拒绝原因。
Future<String?> mcpEndpointSsrfRejection(Uri? uri, {SsrfIpLookup? lookup}) =>
    ssrfRejectionReason(uri, lookup: lookup);

/// 同上，失败即抛 [FormatException]（与 `McpClientService` 既有错误口径一致）。
Future<Uri> assertMcpEndpointSsrfSafe(Uri? uri, {SsrfIpLookup? lookup}) async {
  final reason = await ssrfRejectionReason(uri, lookup: lookup);
  if (reason != null) {
    throw FormatException('MCP endpoint rejected by SSRF guard: $reason');
  }
  return uri!;
}

String _requiredString(Map<String, dynamic> json, String key, int maxLength) {
  final value = _optionalString(json, key, maxLength);
  if (value == null || value.isEmpty) {
    throw McpModelFormatException('$key is required');
  }
  return value;
}

String? _optionalString(Map<String, dynamic> json, String key, int maxLength) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String || value.length > maxLength) {
    throw McpModelFormatException('$key is invalid');
  }
  return value.trim();
}

int _validateJsonValue(
  dynamic value, {
  required int depth,
  required int maxDepth,
  required int itemBudget,
}) {
  if (depth > maxDepth || itemBudget < 0) {
    throw const McpModelFormatException('JSON structure exceeds limits');
  }
  var remaining = itemBudget - 1;
  if (value is Map) {
    for (final entry in value.entries) {
      if (entry.key is! String || (entry.key as String).length > 256) {
        throw const McpModelFormatException('JSON object key is invalid');
      }
      remaining = _validateJsonValue(
        entry.value,
        depth: depth + 1,
        maxDepth: maxDepth,
        itemBudget: remaining,
      );
    }
  } else if (value is List) {
    for (final item in value) {
      remaining = _validateJsonValue(
        item,
        depth: depth + 1,
        maxDepth: maxDepth,
        itemBudget: remaining,
      );
    }
  } else if (value is! String &&
      value is! num &&
      value is! bool &&
      value != null) {
    throw const McpModelFormatException('Unsupported JSON value');
  } else if (value is String && value.length > 10000) {
    throw const McpModelFormatException('JSON string exceeds limit');
  }
  return remaining;
}
