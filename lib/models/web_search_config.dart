/// 联网搜索配置 & 搜索结果
///
/// v1.3.9 支持的搜索后端：
///   1) Bing 直爬（默认，无需 Key，国内可访问）
///   2) Tavily API（需 Key，结果结构化，质量高）
library web_search_config;

///   3) SearXNG（自建/公共实例，可选）
///   4) DuckDuckGo 直爬（无需 Key，国内可访问）
///   5) SerpAPI（需 Key，聚合 Google/Bing 等多引擎，100次/月免费）
///   6) Brave Search API（需 Key，2000次/月免费，质量好）
///   7) Google CSE 自定义搜索（需 Key + cx，100次/天免费）

import 'package:flutter/foundation.dart';

import '../services/repo_endpoints.dart';
import '../services/secret_store.dart';

enum WebSearchProvider {
  bing, // 默认 Bing 直爬，无需 Key
  tavily, // Tavily API（付费+免费层）
  searxng, // SearXNG 公共/自建（可选）
  duckduckgo, // v1.3.9 新增：DuckDuckGo 直爬，无需 Key
  serpapi, // v1.3.9 新增：SerpAPI 聚合搜索，需 Key
  brave, // v1.3.9 新增：Brave Search API，需 Key
  googlecse, // v1.3.9 新增：Google CSE 自定义搜索，需 Key + cx
}

/// v1.5.2：联网搜索服务商的官网链接（用户点击跳转去注册 / 查 Key）
extension WebSearchProviderInfo on WebSearchProvider {
  String get officialUrl {
    switch (this) {
      case WebSearchProvider.bing:
        return 'https://www.bing.com/';
      case WebSearchProvider.tavily:
        return 'https://tavily.com/';
      case WebSearchProvider.searxng:
        return 'https://docs.searxng.org/';
      case WebSearchProvider.duckduckgo:
        return 'https://duckduckgo.com/';
      case WebSearchProvider.serpapi:
        return 'https://serpapi.com/';
      case WebSearchProvider.brave:
        return 'https://brave.com/search/api/';
      case WebSearchProvider.googlecse:
        return 'https://programmablesearchengine.google.com/';
    }
  }
}

/// 远程规则源默认 URL（用户 GitHub 仓库，自动同步）
///
/// build171：地址不再在这里写字面量——它和
/// `screens/security_scan_settings_screen.dart` 里"恢复默认"按钮填的是**同一条**，
/// 以前两处各有一份，改一处就会静默分叉（现在两份都指 [kRepoRulesUrlDefault]）。
const String _defaultRulesUrl = kRepoRulesUrlDefault;

/// build145（循环审查第 7 轮 P0-2）：`fromMap` 的宽松取串。
/// 列里躺着非字符串（版本错配 / 手工改库）时**不抛**，退回 [fallback]；
/// 空串退回 [emptyFallback]。理由不是"少一行红字"：这一抛会让**整份**
/// WebSearchConfig 读不出来，而 `getBiometricLockEnabled` 就挂在它上面，
/// 于是"某列类型不对"会升级成"应用锁的读取状态未知"。
String _urlOr(Object? v, String fallback, String emptyFallback) {
  if (v is! String) return fallback;
  if (v.isEmpty) return emptyFallback;
  return v;
}

/// 通用搜索配置（单一配置，简单 KV 存 SQLite 就够了）
class WebSearchConfig extends ChangeNotifier implements SecretBearing {
  /// 总开关：false 时所有联网搜索功能禁用
  bool webSearchEnabled;

  /// 选用的搜索服务商
  WebSearchProvider provider;

  /// Tavily API Key（Bearer Token 形式）
  String tavilyApiKey;

  /// Tavily 搜索深度：basic / advanced
  String tavilySearchDepth;

  /// Tavily 默认返回结果数（3-10）
  int tavilyMaxResults;

  /// 是否为「自动」档位：true 时执行侧忽略 tavilyMaxResults，由 AI 自行决定条数
  /// （配置值保留不删，切回固定档即恢复使用）
  bool tavilyAutoMaxResults;

  /// SearXNG 自定义实例 URL（为空就用公共列表）
  String searxngInstanceUrl;

  /// v1.3.9 新增：SerpAPI Key（聚合 Google/Bing 等）
  String serpApiKey;

  /// v1.3.9 新增：SerpAPI 使用的引擎（google / bing / duckduckgo / baidu 等）
  String serpapiEngine;

  /// v1.3.9 新增：Brave Search API Key
  String braveApiKey;

  /// v1.3.9 新增：Google CSE API Key
  String googleCseApiKey;

  /// v1.3.9 新增：Google CSE 搜索引擎 ID（cx）
  String googleCseId;

  /// 每次搜索注入到 LLM 的最大摘要长度（字符）
  int maxSnippetCharsPerResult;

  /// 注入到 prompt 的最大结果数
  int maxResultsInject;

  // ==========================================================================
  // v1.3.1 build 11: 🌐 常驻开关 + ReAct 思考循环配置（全部持久化）
  // v1.3.3 build 13: 新增 reactAutoMode（AI 自动决定搜索轮次）
  // ==========================================================================

  /// 用户输入框 🌐 按钮上次是否开启（true=常驻，不用每次都点）
  bool persistentWebSearchToggle;

  /// 是否启用 ReAct 自主思考 + 搜索循环（类 Chatbox 思考模式）
  bool reactEnabled;

  /// 思考程度：控制 ReAct 最大搜索轮次（Low=2 / Default=3 / Medium=5 / High=8）
  /// v1.3.3：当 reactAutoMode=true 时，此值代表自动档的上限（默认 30，可调）
  int reactMaxRounds;

  /// v1.3.3 新增：是否为"自动"档位（AI 自己决定搜索轮次）
  bool reactAutoMode;

  /// v1.3.4 新增：GitHub release asset 下载加速代理 URL
  String githubProxyUrl;

  /// v1.3.4 新增：详细日志模式（默认 false）
  bool verboseLogging;

  // ==========================================================================
  // v1.7.5 新增：安全审查配置
  // ==========================================================================

  /// SkillSpector 服务地址（用于审查 Skill 和 MCP）
  String skillspectorEndpoint;

  /// 是否启用 Skill 安全审查
  bool enableSkillSecurityScan;

  /// 是否启用 MCP 安全审查
  bool enableMcpSecurityScan;

  /// MobSF 服务地址（用于审查 APK）
  String mobsfEndpoint;

  /// 是否启用 APK 安全审查
  bool enableApkSecurityScan;

  // ==========================================================================
  // v1.7.10 新增：本地安全扫描（零配置，默认开）
  // ==========================================================================

  /// 是否启用本地规则扫描（Skill/MCP 安装前，纯 Dart 离线扫描）
  bool enableLocalScan;

  /// 远程规则源 URL（预留：留空走内置规则；填 GitHub raw JSON 地址可热更新规则）
  String localScanRulesUrl;

  // ==========================================================================
  // v1.7.11 新增：VirusTotal 云端查毒 + MobSF API Key
  // ==========================================================================

  /// VirusTotal API Key（免费注册 500次/天，用于 APK/文件下载后哈希查毒）
  String virusTotalApiKey;

  /// 是否启用 VirusTotal 云端查毒（默认关，需填 API Key 后才开）
  bool enableVirusTotalScan;

  /// MobSF API Key（自部署 MobSF 也可配认证，v1.7.11 P0 修复）
  String mobsfApiKey;

  /// v1.7.22：生物识别锁开关（持久化到 web_search_configs）
  bool biometricLockEnabled;

  WebSearchConfig({
    this.webSearchEnabled = true,
    this.provider = WebSearchProvider.bing,
    this.tavilyApiKey = '',
    this.tavilySearchDepth = 'auto',
    this.tavilyMaxResults = 5,
    this.tavilyAutoMaxResults = false,
    this.searxngInstanceUrl = '',
    this.serpApiKey = '',
    this.serpapiEngine = 'google',
    this.braveApiKey = '',
    this.googleCseApiKey = '',
    this.googleCseId = '',
    this.maxSnippetCharsPerResult = 400,
    this.maxResultsInject = 5,
    this.persistentWebSearchToggle = true,
    this.reactEnabled = true,
    this.reactMaxRounds = 3,
    this.reactAutoMode = false,
    this.githubProxyUrl = '',
    this.verboseLogging = false,
    this.skillspectorEndpoint = '',
    this.enableSkillSecurityScan = false,
    this.enableMcpSecurityScan = false,
    this.mobsfEndpoint = '',
    this.enableApkSecurityScan = false,
    this.enableLocalScan = true,
    this.localScanRulesUrl = _defaultRulesUrl,
    this.virusTotalApiKey = '',
    this.enableVirusTotalScan = false,
    this.mobsfApiKey = '',
    this.biometricLockEnabled = false,
  });

  factory WebSearchConfig.fromMap(Map<String, dynamic> m) => WebSearchConfig(
        // v1.7.37：恢复自由开关（用户拍板 2026-09-05）——默认开启，但尊重历史存储值；
        // 关闭后不再注入 search 协议以节省 token
        webSearchEnabled: (m['webSearchEnabled'] as int? ?? 1) == 1,
        provider: WebSearchProvider.values.firstWhere(
          // build145（第 7 轮 P0-2 的一半）：`as String?` 遇非字符串（列变形、
          // 别的版本写过数字）会**抛**，而抛出的后果是"整份配置读不出来"——
          // 应用锁那条链正好踩在这上面（storage_service.dart:1437 → main.dart 的 gate），
          // 抛一次就等于给别人开了一次后门。这类"有明确默认值"的字段一律宽松取默认。
          (e) => e.name == (m['provider'] is String ? m['provider'] : 'bing'),
          orElse: () => WebSearchProvider.bing,
        ),
        tavilyApiKey: m['tavilyApiKey'] as String? ?? '',
        tavilySearchDepth: m['tavilySearchDepth'] as String? ?? 'auto',
        tavilyMaxResults: m['tavilyMaxResults'] as int? ?? 5,
        tavilyAutoMaxResults: (m['tavilyAutoMaxResults'] as int? ?? 0) == 1,
        searxngInstanceUrl: m['searxngInstanceUrl'] as String? ?? '',
        serpApiKey: m['serpApiKey'] as String? ?? '',
        serpapiEngine: m['serpapiEngine'] as String? ?? 'google',
        braveApiKey: m['braveApiKey'] as String? ?? '',
        googleCseApiKey: m['googleCseApiKey'] as String? ?? '',
        googleCseId: m['googleCseId'] as String? ?? '',
        maxSnippetCharsPerResult: m['maxSnippetCharsPerResult'] as int? ?? 400,
        maxResultsInject: m['maxResultsInject'] as int? ?? 5,
        persistentWebSearchToggle:
            (m['persistentWebSearchToggle'] as int? ?? 1) == 1,
        reactEnabled: (m['reactEnabled'] as int? ?? 1) == 1,
        reactMaxRounds: m['reactMaxRounds'] as int? ?? 3,
        reactAutoMode: (m['reactAutoMode'] as int? ?? 0) == 1,
        githubProxyUrl: m['githubProxyUrl'] as String? ?? '',
        verboseLogging: (m['verboseLogging'] as int? ?? 0) == 1,
        skillspectorEndpoint: m['skillspectorEndpoint'] as String? ?? '',
        enableSkillSecurityScan:
            (m['enableSkillSecurityScan'] as int? ?? 0) == 1,
        enableMcpSecurityScan: (m['enableMcpSecurityScan'] as int? ?? 0) == 1,
        mobsfEndpoint: m['mobsfEndpoint'] as String? ?? '',
        enableApkSecurityScan: (m['enableApkSecurityScan'] as int? ?? 0) == 1,
        enableLocalScan: (m['enableLocalScan'] as int? ?? 1) == 1,
        localScanRulesUrl: _urlOr(
            m['localScanRulesUrl'], _defaultRulesUrl, _defaultRulesUrl),
        // ↑ 同上：原来末尾是 `m['localScanRulesUrl'] as String`，非字符串直接抛。
        // 空串与"没有这一列"都退回默认规则地址（口径不变）。
        virusTotalApiKey: m['virusTotalApiKey'] as String? ?? '',
        enableVirusTotalScan: (m['enableVirusTotalScan'] as int? ?? 0) == 1,
        mobsfApiKey: m['mobsfApiKey'] as String? ?? '',
        biometricLockEnabled: (m['biometricLockEnabled'] as int? ?? 0) == 1,
      );

  @override
  Map<String, dynamic> toMap() => {
        'id': 'singleton',
        'webSearchEnabled': webSearchEnabled ? 1 : 0,
        'provider': provider.name,
        'tavilyApiKey': tavilyApiKey,
        'tavilySearchDepth': tavilySearchDepth,
        'tavilyMaxResults': tavilyMaxResults,
        'tavilyAutoMaxResults': tavilyAutoMaxResults ? 1 : 0,
        'searxngInstanceUrl': searxngInstanceUrl,
        'serpApiKey': serpApiKey,
        'serpapiEngine': serpapiEngine,
        'braveApiKey': braveApiKey,
        'googleCseApiKey': googleCseApiKey,
        'googleCseId': googleCseId,
        'maxSnippetCharsPerResult': maxSnippetCharsPerResult,
        'maxResultsInject': maxResultsInject,
        'persistentWebSearchToggle': persistentWebSearchToggle ? 1 : 0,
        'reactEnabled': reactEnabled ? 1 : 0,
        'reactMaxRounds': reactMaxRounds,
        'reactAutoMode': reactAutoMode ? 1 : 0,
        'githubProxyUrl': githubProxyUrl,
        'verboseLogging': verboseLogging ? 1 : 0,
        'skillspectorEndpoint': skillspectorEndpoint,
        'enableSkillSecurityScan': enableSkillSecurityScan ? 1 : 0,
        'enableMcpSecurityScan': enableMcpSecurityScan ? 1 : 0,
        'mobsfEndpoint': mobsfEndpoint,
        'enableApkSecurityScan': enableApkSecurityScan ? 1 : 0,
        'enableLocalScan': enableLocalScan ? 1 : 0,
        'localScanRulesUrl': localScanRulesUrl,
        'virusTotalApiKey': virusTotalApiKey,
        'enableVirusTotalScan': enableVirusTotalScan ? 1 : 0,
        'mobsfApiKey': mobsfApiKey,
        'biometricLockEnabled': biometricLockEnabled ? 1 : 0,
      };

  // ==========================================================================
  // build146（密钥入 Keystore）
  //
  // 这张表是**单例行**（id = 'singleton'），六个 provider Key 各占一列：
  //   tavilyApiKey / serpApiKey / braveApiKey / googleCseApiKey /
  //   virusTotalApiKey / mobsfApiKey
  // （`googleCseId` 是搜索引擎实例 id（cx），不是 bearer 凭据，**不迁**，
  //  口径与本仓库既有剥敏白名单一致 —— 那个正则只认 apikey/token/secret 结尾。）
  //
  // 与 [ApiConfig] 的分工逐字同构：[toMap] 带真值（备份导出、内存重建要用），
  // [toRowMap] 把六列抹成空串（落库用），[applySecret] 在读取时回填。
  // 列与保险库键的对应关系**只在这里定义一份**（[secretColumns]），
  // 迁移计划与孤儿清扫都从它派生 —— 新增一个 provider Key 字段时只需要在这
  // 一处登记，不会重演「备份按字段名剥敏、每加一列漏一列」那类缺陷。
  // ==========================================================================

  /// 落库列名 ↔ 保险库坐标的唯一对照表。
  static const List<String> secretColumns = <String>[
    'tavilyApiKey',
    'serpApiKey',
    'braveApiKey',
    'googleCseApiKey',
    'virusTotalApiKey',
    'mobsfApiKey',
  ];

  /// [column]（必须是 [secretColumns] 之一）对应的保险库坐标。
  static SecretLocation secretLocationFor(String column) => SecretLocation(
        scope: SecretStore.webSearchScope,
        rowId: SecretStore.webSearchRowId,
        table: 'web_search_configs',
        column: column,
      );

  /// 全部密钥坐标（迁移计划与清扫的输入）。
  static List<SecretLocation> secretLocationsAll() =>
      [for (final c in secretColumns) secretLocationFor(c)];

  /// 本条携带的密钥坐标（实例方法，与 [ApiConfig.secretLocations] 同签名）。
  @override
  List<SecretLocation> secretLocations() => secretLocationsAll();

  /// 本次生命周期里**保险库没读到值**的字段名（区别于「用户清空」，
  /// 见 [SecretReadResult.failed]）。纯内存标记，不进 `toMap` / 不落库。
  ///
  /// 为什么这个对象特别需要它：本类的 Key 有六把，而设置页大量开关走的是
  /// 「读整份单例 → 改一个布尔 → 整份写回」。没有这个标记时，任何一把 Key
  /// 读抛都会让下一次拨开关把它当成"用户清空了"删掉。
  @override
  final Set<String> unreadableSecrets = <String>{};

  /// [loc] 这个坐标上当前存着什么值。
  @override
  String secretValueAt(SecretLocation loc) {
    switch (loc.column) {
      case 'tavilyApiKey':
        return tavilyApiKey;
      case 'serpApiKey':
        return serpApiKey;
      case 'braveApiKey':
        return braveApiKey;
      case 'googleCseApiKey':
        return googleCseApiKey;
      case 'virusTotalApiKey':
        return virusTotalApiKey;
      case 'mobsfApiKey':
        return mobsfApiKey;
      default:
        return '';
    }
  }

  /// 把保险库读到的值回填进本对象（值为空 / 列不认识时不动）。
  @override
  void applySecret(SecretLocation loc, String value) {
    // build147 第 11 轮：坐标先对上再回填。另外两类密钥对象都判 `rowId`，
    // 这里以前只判列名 —— 今天行 id 恒 `singleton` 没有触发面，但"谁的键写进谁"
    // 这条不变量不该靠"目前只有一个单例"来保证（纵深防御，一行的事）。
    if (loc.scope != SecretStore.webSearchScope ||
        loc.rowId != SecretStore.webSearchRowId) {
      return;
    }
    if (value.trim().isEmpty) return;
    switch (loc.column) {
      case 'tavilyApiKey':
        tavilyApiKey = value;
        break;
      case 'serpApiKey':
        serpApiKey = value;
        break;
      case 'braveApiKey':
        braveApiKey = value;
        break;
      case 'googleCseApiKey':
        googleCseApiKey = value;
        break;
      case 'virusTotalApiKey':
        virusTotalApiKey = value;
        break;
      case 'mobsfApiKey':
        mobsfApiKey = value;
        break;
      default:
        break;
    }
  }

  /// 落库用的一行：六个密钥列抹成空串（列保留，见上方方案说明）。
  @override
  Map<String, dynamic> toRowMap() {
    final m = toMap();
    for (final c in secretColumns) {
      m[c] = '';
    }
    return m;
  }

  /// 这一行里的密钥值是否已经被抹干净（落库前的自检用）。
  static List<String> rowsStillHoldingSecrets(Map<String, dynamic> row) => [
        for (final c in secretColumns)
          if (row[c] is String && (row[c] as String).trim().isNotEmpty) c
      ];

  WebSearchConfig copyWith({
    bool? webSearchEnabled,
    WebSearchProvider? provider,
    String? tavilyApiKey,
    String? tavilySearchDepth,
    int? tavilyMaxResults,
    bool? tavilyAutoMaxResults,
    String? searxngInstanceUrl,
    String? serpApiKey,
    String? serpapiEngine,
    String? braveApiKey,
    String? googleCseApiKey,
    String? googleCseId,
    int? maxSnippetCharsPerResult,
    int? maxResultsInject,
    bool? persistentWebSearchToggle,
    bool? reactEnabled,
    int? reactMaxRounds,
    bool? reactAutoMode,
    String? githubProxyUrl,
    bool? verboseLogging,
    String? skillspectorEndpoint,
    bool? enableSkillSecurityScan,
    bool? enableMcpSecurityScan,
    String? mobsfEndpoint,
    bool? enableApkSecurityScan,
    bool? enableLocalScan,
    String? localScanRulesUrl,
    String? virusTotalApiKey,
    bool? enableVirusTotalScan,
    String? mobsfApiKey,
    bool? biometricLockEnabled,
  }) {
    return WebSearchConfig(
      webSearchEnabled: webSearchEnabled ?? this.webSearchEnabled,
      provider: provider ?? this.provider,
      tavilyApiKey: tavilyApiKey ?? this.tavilyApiKey,
      tavilySearchDepth: tavilySearchDepth ?? this.tavilySearchDepth,
      tavilyMaxResults: tavilyMaxResults ?? this.tavilyMaxResults,
      tavilyAutoMaxResults: tavilyAutoMaxResults ?? this.tavilyAutoMaxResults,
      searxngInstanceUrl: searxngInstanceUrl ?? this.searxngInstanceUrl,
      serpApiKey: serpApiKey ?? this.serpApiKey,
      serpapiEngine: serpapiEngine ?? this.serpapiEngine,
      braveApiKey: braveApiKey ?? this.braveApiKey,
      googleCseApiKey: googleCseApiKey ?? this.googleCseApiKey,
      googleCseId: googleCseId ?? this.googleCseId,
      maxSnippetCharsPerResult:
          maxSnippetCharsPerResult ?? this.maxSnippetCharsPerResult,
      maxResultsInject: maxResultsInject ?? this.maxResultsInject,
      persistentWebSearchToggle:
          persistentWebSearchToggle ?? this.persistentWebSearchToggle,
      reactEnabled: reactEnabled ?? this.reactEnabled,
      reactMaxRounds: reactMaxRounds ?? this.reactMaxRounds,
      reactAutoMode: reactAutoMode ?? this.reactAutoMode,
      githubProxyUrl: githubProxyUrl ?? this.githubProxyUrl,
      verboseLogging: verboseLogging ?? this.verboseLogging,
      skillspectorEndpoint: skillspectorEndpoint ?? this.skillspectorEndpoint,
      enableSkillSecurityScan:
          enableSkillSecurityScan ?? this.enableSkillSecurityScan,
      enableMcpSecurityScan:
          enableMcpSecurityScan ?? this.enableMcpSecurityScan,
      mobsfEndpoint: mobsfEndpoint ?? this.mobsfEndpoint,
      enableApkSecurityScan:
          enableApkSecurityScan ?? this.enableApkSecurityScan,
      enableLocalScan: enableLocalScan ?? this.enableLocalScan,
      localScanRulesUrl: localScanRulesUrl ?? this.localScanRulesUrl,
      virusTotalApiKey: virusTotalApiKey ?? this.virusTotalApiKey,
      enableVirusTotalScan: enableVirusTotalScan ?? this.enableVirusTotalScan,
      mobsfApiKey: mobsfApiKey ?? this.mobsfApiKey,
      biometricLockEnabled: biometricLockEnabled ?? this.biometricLockEnabled,
    )
      // build152（数据层扫描 D1，P0）：`copyWith` 新建对象时**必须把"这一格本次没读到值"
      // 的标记带过去**。不带 ⇒ 标记在每一次"改个开关顺手落库"的路径上凭空消失，
      // 而 `storage_service.dart` 的 `_rowOfSecrets` 正是靠它拦住"空值覆盖 + 删保险库条目"：
      // 标记一丢，Keystore 读抛的那格就被当成"用户清空了 Key"，
      // 于是列落空串、保险库条目被 deleteKey —— **两把副本同时没掉**，
      // 与 build147 修掉的那条 P0 逐字同形。触发只要"某台机器 Keystore 不稳 + 用户拨一下
      // 搜索开关"，而这条路径上没有任何日志。
      // 三个模型（本文件 / api_config / api_account）同一口径，见
      // test/build152_copywith_secret_marker_test.dart 的结构锁。
      ..unreadableSecrets.addAll(unreadableSecrets);
  }

  /// ReAct 思考程度 -> 中文 label
  String get reactLevelLabel =>
      reactAutoMode ? '自动 (Auto)' : estimateLevelLabel(reactMaxRounds);

  // build138（扫描 P2-9）：删除 `reactLevelLabelEn` / `estimateLevelLabelEn` /
  // `effectiveMaxRounds` 三个**零调用点**成员。英文界面真正走的是
  // `chat_input.dart` 的 `_stripLabel(isZh, reactLevelLabel)`（把「中 (Medium)」
  // 里的中文段剥掉），这套 En 表从未接进任何调用点 —— 留着＝下一任以为
  // 「英文档位名已经有了」，本项目最高频的那类事故。

  static String estimateLevelLabel(int rounds) {
    if (rounds <= 0) return '关 (Off)';
    if (rounds <= 2) return '低 (Low)';
    if (rounds <= 5) return '中 (Medium)';
    if (rounds <= 8) return '高 (High)';
    if (rounds <= 30) return '极高 (Max)';
    return '极限 (Xtreme)';
  }

  /// 选中的 provider 实际是否可用（缺 Key/实例地址则视为不可用，回退 Bing）
  bool isProviderUsable() {
    switch (provider) {
      case WebSearchProvider.bing:
        return true; // 永远可用
      case WebSearchProvider.duckduckgo:
        return true; // v1.3.9：永远可用，无需 Key
      case WebSearchProvider.tavily:
        return tavilyApiKey.trim().isNotEmpty;
      case WebSearchProvider.searxng:
        return searxngInstanceUrl.trim().isNotEmpty;
      case WebSearchProvider.serpapi:
        return serpApiKey.trim().isNotEmpty;
      case WebSearchProvider.brave:
        return braveApiKey.trim().isNotEmpty;
      case WebSearchProvider.googlecse:
        return googleCseApiKey.trim().isNotEmpty &&
            googleCseId.trim().isNotEmpty;
    }
  }

  /// 当 provider 不可用时，推荐的 fallback（Bing 或 DuckDuckGo）
  WebSearchProvider effectiveProvider() =>
      isProviderUsable() ? provider : WebSearchProvider.bing;

  /// v1.3.9：provider 显示名（中文）
  String get providerDisplayNameZh {
    switch (provider) {
      case WebSearchProvider.bing:
        return 'Bing 直爬 (无需 Key)';
      case WebSearchProvider.duckduckgo:
        return 'DuckDuckGo 直爬 (无需 Key)';
      case WebSearchProvider.tavily:
        return 'Tavily API (需 Key)';
      case WebSearchProvider.searxng:
        return 'SearXNG 自建/公共 (需实例地址)';
      case WebSearchProvider.serpapi:
        return 'SerpAPI 聚合搜索 (需 Key, 100次/月免费)';
      case WebSearchProvider.brave:
        return 'Brave Search API (需 Key, 2000次/月免费)';
      case WebSearchProvider.googlecse:
        return 'Google CSE 自定义搜索 (需 Key + cx, 100次/天免费)';
    }
  }

  @override
  String toString() => 'WebSearchConfig(enabled=$webSearchEnabled, '
      'provider=${provider.name}, tavilyKey=${tavilyApiKey.isEmpty ? 'empty' : '***'}, '
      'serpApiKey=${serpApiKey.isEmpty ? 'empty' : '***'}, '
      'braveApiKey=${braveApiKey.isEmpty ? 'empty' : '***'})';
}
