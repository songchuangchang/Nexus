import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/data_pack_pref_keys.dart';

/// build104（M1）：MCP 推荐连接器目录——远程刷新 + 内置兜底（同 api_templates 模式）。
///
/// - 内置 [builtinEntries] 为编译期兜底（离线可用）；远程 `mcp_catalog.json`
///   （仓库根，走 GitHubContentFetcher 自适应代理链）按 id 覆盖/追加。
/// - 目录条目只是"推荐展示"，实际安装一律走 SecurityGate + installRemoteMcp，
///   远程内容不享受任何豁免。
/// - [summaryForPrompt] 为 install_mcp 代装提示词注入用的静态摘要（编译期，
///   保证 ReAct 前缀逐字节稳定，不随远程内容变化——前缀稳定性铁律）。
class McpCatalogEntry {
  final String id;
  final String name;
  final String nameZh;
  final String description;
  final String endpoint;

  /// none = 免鉴权；key-header = 把 key 放进请求头；key-query = key 拼 URL 参数
  final String auth;
  final String? headerName;
  final String? headerPrefix;
  final String? queryParam;

  /// 申请指引（安装时在凭据框里展示给用户）
  final String secretHint;
  final String docsUrl;
  final String category;

  /// 端点人工核实日期（仅展示，不参与逻辑）
  final String verifiedAt;

  const McpCatalogEntry({
    required this.id,
    required this.name,
    required this.nameZh,
    required this.description,
    required this.endpoint,
    required this.auth,
    this.headerName,
    this.headerPrefix,
    this.queryParam,
    this.secretHint = '',
    required this.docsUrl,
    required this.category,
    required this.verifiedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'nameZh': nameZh,
        'description': description,
        'endpoint': endpoint,
        'auth': auth,
        if (headerName != null) 'headerName': headerName,
        if (headerPrefix != null) 'headerPrefix': headerPrefix,
        if (queryParam != null) 'queryParam': queryParam,
        'secretHint': secretHint,
        'docsUrl': docsUrl,
        'category': category,
        'verifiedAt': verifiedAt,
      };

  static McpCatalogEntry fromJson(Map<String, dynamic> j) => McpCatalogEntry(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        nameZh: j['nameZh'] as String? ?? '',
        description: j['description'] as String? ?? '',
        endpoint: j['endpoint'] as String? ?? '',
        auth: j['auth'] as String? ?? 'none',
        headerName: j['headerName'] as String?,
        headerPrefix: j['headerPrefix'] as String?,
        queryParam: j['queryParam'] as String?,
        secretHint: j['secretHint'] as String? ?? '',
        docsUrl: j['docsUrl'] as String? ?? '',
        category: j['category'] as String? ?? '',
        verifiedAt: j['verifiedAt'] as String? ?? '',
      );

  /// 免鉴权服务可直接填空凭据
  bool get needsSecret => auth != 'none';
}

class McpCatalog {
  McpCatalog._();

  static const _cacheKey = DataPackPrefKeys.mcpJson;

  /// build138（G54–G56）：本目录的远程覆盖**不再自己去拉**。
  /// 缓存读写、多源有序回退、dataVersion/sha256 闸门统一由 `DataPackService`
  /// 负责，校验通过后回调 [applyRemotePayload] 把条目放进内存。
  static List<McpCatalogEntry>? _remoteApplied;

  /// 已应用的远程条目数（0＝只用内置兜底）。
  static int get remoteEntryCount => _remoteApplied?.length ?? 0;

  /// 测试钩子：清空内存里的远程条目。
  @visibleForTesting
  static void resetForTest() => _remoteApplied = null;

  /// [DataPackService] 校验通过后调用：应用原始信封；无有效条目返回 false。
  static bool applyRemotePayload(String rawJson) {
    final list = decodeEntries(_tryDecode(rawJson));
    if (list.isEmpty) return false;
    _remoteApplied = list;
    return true;
  }

  /// 丢弃远程条目（回落内置）。
  static Future<void> clearRemotePayload(SharedPreferences? prefs) async {
    _remoteApplied = null;
    if (prefs != null) await prefs.remove(_cacheKey);
  }

  /// 有效条目数（G55 的「空包不许覆盖内置」判定按这个口径）。
  static int countEntries(Object? decoded) => decodeEntries(decoded).length;

  /// 解码信封：兼容 `[{...}]` 与 `{"entries":[{...}]}`，过滤掉缺 id/endpoint 的行。
  static List<McpCatalogEntry> decodeEntries(Object? decoded) {
    final list = decoded is List
        ? decoded
        : (decoded is Map
            ? (decoded['entries'] as List? ?? const [])
            : const []);
    return list
        .whereType<Map>()
        .map((m) => McpCatalogEntry.fromJson(Map<String, dynamic>.from(m)))
        .where((e) => e.id.isNotEmpty && e.endpoint.isNotEmpty)
        .toList();
  }

  static Object? _tryDecode(String raw) {
    try {
      return jsonDecode(raw);
    } catch (e) {
      debugPrint('[McpCatalog] 缓存 JSON 损坏: $e');
      return null;
    }
  }

  /// 编译期兜底目录（2026-09-13 逐条人工核实端点在线）
  static const List<McpCatalogEntry> builtinEntries = [
    McpCatalogEntry(
      id: 'amap',
      name: 'AMap Maps',
      nameZh: '高德地图',
      description:
          'POI 搜索、路线规划、实时天气、骑行/步行/驾车导航等 12 大位置服务。中文场景首选。',
      endpoint: 'https://mcp.amap.com/mcp',
      auth: 'key-query',
      queryParam: 'key',
      secretHint:
          '到 lbs.amap.com 开放平台 → 应用管理 → 创建应用 → 创建 Key。⚠️ 服务平台必须选「Web 服务」——不要选「Web端(JS API)」！两者都不需要 SHA1 极易混；选错 JS API 时能连上（工具列表正常）但一调用就报 USERKEY_PLAT_NOMATCH',
      docsUrl: 'https://lbs.amap.com/api/mcp-server/gettingstarted',
      category: '生活/地图',
      verifiedAt: '2026-09-13',
    ),
    McpCatalogEntry(
      id: 'github',
      name: 'GitHub (Official)',
      nameZh: 'GitHub 官方',
      description: '仓库/Issue/PR/文件读写全套 22 工具。需 GitHub PAT（Settings → Developer settings 生成，勾 repo 权限）。',
      endpoint: 'https://api.githubcopilot.com/mcp/',
      auth: 'key-header',
      headerName: 'Authorization',
      headerPrefix: 'Bearer ',
      secretHint:
          'github.com → Settings → Developer settings → Personal access tokens → Generate（勾 repo / read:user）',
      docsUrl: 'https://github.com/github/github-mcp-server',
      category: '开发',
      verifiedAt: '2026-09-13',
    ),
    McpCatalogEntry(
      id: 'context7',
      name: 'Context7',
      nameZh: 'Context7 库文档',
      description: '实时检索各种库/框架的最新官方文档与代码示例，写代码时避免 API 过时幻觉。免费，key 可选。',
      endpoint: 'https://mcp.context7.com/mcp',
      auth: 'key-header',
      headerName: 'CONTEXT7_API_KEY',
      headerPrefix: '',
      secretHint: 'context7.com 免费使用；要更高速率限制时才需要到官网申请 API Key',
      docsUrl: 'https://context7.com',
      category: '开发/文档',
      verifiedAt: '2026-09-13',
    ),
    McpCatalogEntry(
      id: 'deepwiki',
      name: 'DeepWiki',
      nameZh: 'DeepWiki 仓库问答',
      description: '对公开 GitHub 仓库提问，返回结构化的架构/用法解读（把仓库变成可问答的 wiki）。免费。',
      endpoint: 'https://mcp.deepwiki.com/mcp',
      auth: 'none',
      secretHint: '',
      docsUrl: 'https://deepwiki.com',
      category: '开发/文档',
      verifiedAt: '2026-09-13',
    ),
    McpCatalogEntry(
      id: 'mslearn',
      name: 'Microsoft Learn',
      nameZh: '微软官方文档',
      description: '检索 Microsoft Learn 官方文档（Azure/.NET/Windows/VS 等）。免费公开端点。',
      endpoint: 'https://learn.microsoft.com/api/mcp',
      auth: 'none',
      secretHint: '',
      docsUrl: 'https://learn.microsoft.com/api/mcp',
      category: '开发/文档',
      verifiedAt: '2026-09-13',
    ),
    McpCatalogEntry(
      id: 'modelscope',
      name: 'ModelScope 广场',
      nameZh: '魔搭托管 MCP',
      description: '魔搭社区的托管 MCP 生态入口（中文生态，含支付宝/地图等托管实例）。到 modelscope.cn 的 MCP 广场获取带 token 的专属端点后填入。',
      endpoint: 'https://mcp.modelscope.cn/mcp',
      auth: 'key-header',
      headerName: 'Authorization',
      headerPrefix: 'Bearer ',
      secretHint: 'modelscope.cn → MCP 广场 → 选服务 → 「连接服务」里复制带你 token 的专属 URL/Token',
      docsUrl: 'https://modelscope.cn/mcp/servers',
      category: '中文生态',
      verifiedAt: '2026-09-13',
    ),
    McpCatalogEntry(
      id: 'didi',
      name: 'DiDi Ride',
      nameZh: '滴滴出行',
      description: '打车比价/叫车/查单（taxi_estimate / taxi_create_order 等）。需在 mcp.didichuxing.com 用滴滴账号激活个人 MCP Key。',
      endpoint: 'https://mcp.didichuxing.com/mcp-servers',
      auth: 'key-query',
      queryParam: 'key',
      secretHint: 'mcp.didichuxing.com 用滴滴账号登录 → 激活个人 MCP Key → 填入此处',
      docsUrl: 'https://mcp.didichuxing.com',
      category: '生活/出行',
      verifiedAt: '2026-09-13',
    ),
  ];

  /// install_mcp 代装提示词注入用的静态摘要（编译期，前缀稳定）。
  static const String summaryForPrompt =
      '【内置推荐连接器】用户没给直链时，可优先推荐以下目录服务（安装仍需用户在插件市场/插件管理确认）：\n'
      '- amap(高德地图, key-query)：POI/路线/天气；\n'
      '- github(GitHub 官方, PAT header)：仓库/Issue/PR；\n'
      '- context7(库文档)/deepwiki(仓库问答)/mslearn(微软文档)：开发文档检索；\n'
      '- modelscope(魔搭托管, 中文生态)；didi(滴滴出行, key-query)。';

  /// 加载目录：已应用的远程条目 →（缺省时）SP 缓存的远程条目 → 与内置按 id 合并。
  /// 任何失败都静默回退（目录是推荐性数据，绝不能阻塞 UI）。
  ///
  /// build138：网络刷新不在此发生，统一走 `DataPackService.refreshPack(packMcpCatalog)`
  /// （带版本与 sha256 闸门）；此前这里自己直连拉取、且默认 URL 写成了相对路径，
  /// 实际每次都失败——等于从来没有远程目录。
  static Future<List<McpCatalogEntry>> load() async {
    var remote = _remoteApplied ?? const <McpCatalogEntry>[];
    if (remote.isEmpty) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final cached = prefs.getString(_cacheKey);
        if (cached != null && cached.isNotEmpty) {
          remote = decodeEntries(_tryDecode(cached));
        }
      } catch (e) {
        debugPrint('[McpCatalog] 缓存读取跳过: $e');
      }
    }
    // 合并：远程按 id 覆盖内置；内置独有的保留
    final byId = <String, McpCatalogEntry>{};
    for (final e in builtinEntries) {
      byId[e.id] = e;
    }
    for (final e in remote) {
      if (e.id.isNotEmpty && e.endpoint.isNotEmpty) byId[e.id] = e;
    }
    final out = byId.values.toList();
    // 内置序优先（amap/github 置顶），远程新增的排后面
    out.sort((a, b) {
      final ai = builtinEntries.indexWhere((x) => x.id == a.id);
      final bi = builtinEntries.indexWhere((x) => x.id == b.id);
      return (ai < 0 ? 999 : ai).compareTo(bi < 0 ? 999 : bi);
    });
    return out;
  }
}
