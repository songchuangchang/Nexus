/// 本地安全扫描服务（v1.7.10）
///
/// 纯 Dart 静态规则引擎，零部署、零 API Key、离线可用。
/// 用于 Skill (SKILL.md) 和 MCP 配置的安装前安全审查。
library local_scan_service;

///
/// 设计：
///   1) 内置规则库（高置信度、低误报起步，逐步扩充）
///   2) 远程规则 JSON 合并预留：settings 配置 rulesUrl 后，
///      拉取远程规则与内置规则合并（远程同 ID 规则覆盖内置，可禁用内置规则）
///   3) 只警告不硬拦：结果以风险报告呈现，安装决定权在用户
///
/// 规则思路借鉴 SkillSpector (NVIDIA, Apache-2.0) 的检测类别，
/// 实现为纯 Dart 正则匹配。
///
/// ⚠️ 本地规则扫描仅供参考，不能保证查出所有问题。

import 'dart:convert';
import 'custom_scan_rules.dart';
import 'github_content_fetcher.dart';
import 'logger_service.dart';
import '../utils/regex_safety.dart';
import 'security_scan_service.dart'
    show SecurityFinding, SecurityScanResult, SecuritySeverity;

/// 扫描目标类型
enum LocalScanTarget { skill, mcp }

/// 单条扫描规则
class LocalScanRule {
  final String id;
  final String title;
  final String description;
  final SecuritySeverity severity;
  final String category;
  final String pattern; // 正则，dotAll + caseInsensitive
  final bool enabled;

  /// 仅对这些目标生效（空 = 全部）
  final List<LocalScanTarget> targets;

  const LocalScanRule({
    required this.id,
    required this.title,
    required this.description,
    required this.severity,
    required this.category,
    required this.pattern,
    this.enabled = true,
    this.targets = const [],
  });

  factory LocalScanRule.fromJson(Map<String, dynamic> json) {
    final targetNames = (json['targets'] as List<dynamic>? ?? [])
        .map((t) => t.toString())
        .toList();
    final parsedTargets = <LocalScanTarget>[];
    for (final t in targetNames) {
      if (t == 'skill') parsedTargets.add(LocalScanTarget.skill);
      if (t == 'mcp') parsedTargets.add(LocalScanTarget.mcp);
    }
    return LocalScanRule(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? json['id'] as String? ?? '',
      description: json['description'] as String? ?? '',
      severity: _parseSeverity(json['severity'] as String? ?? 'medium'),
      category: json['category'] as String? ?? 'other',
      pattern: json['pattern'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? true,
      targets: parsedTargets,
    );
  }

  static SecuritySeverity _parseSeverity(String s) {
    switch (s.toLowerCase()) {
      case 'critical':
        return SecuritySeverity.critical;
      case 'high':
        return SecuritySeverity.high;
      case 'medium':
      case 'moderate':
        return SecuritySeverity.medium;
      case 'low':
        return SecuritySeverity.low;
      default:
        return SecuritySeverity.info;
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'description': description,
        'severity': severity.name,
        'category': category,
        'pattern': pattern,
        'enabled': enabled,
        'targets': targets.map((t) => t.name).toList(),
      };

  bool appliesTo(LocalScanTarget target) =>
      targets.isEmpty || targets.contains(target);
}

/// 本地扫描服务
class LocalScanService {
  static final LoggerService _logger = LoggerService.instance;

  /// 远程规则缓存（进程内，避免每次安装都拉取）
  static List<LocalScanRule>? _remoteRulesCache;
  static DateTime _remoteRulesFetchedAt =
      DateTime.fromMillisecondsSinceEpoch(0);
  static const _remoteCacheTtl = Duration(minutes: 10);

  /// build98（本地加强③）：恶意指纹黑名单（随 rules.json 远程更新，命中直接拒装）
  static Set<String> _blacklistDomains = {};
  static Set<String> _blacklistSha256 = {};
  static Set<String> get blacklistedDomains => _blacklistDomains;
  static Set<String> get blacklistedSha256 => _blacklistSha256;

  // ==========================================================================
  // 内置规则库（v1.7.10 首批：高置信度、低误报）
  // 借鉴 SkillSpector 检测类别：提示词注入 / 数据外传 / 危险调用 /
  // 供应链混淆 / 敏感路径 / MCP 投毒
  // ==========================================================================

  static const List<LocalScanRule> builtinRules = [
    // --- 危险代码执行 ---
    LocalScanRule(
      id: 'LS-EXE-001',
      title: '危险函数调用 exec()',
      description: '检测到 Python exec() 调用，可执行任意代码，是恶意 Skill 的常见手法。',
      severity: SecuritySeverity.high,
      category: 'dangerous-code',
      pattern: r'\bexec\s*\(',
      targets: [LocalScanTarget.skill],
    ),
    LocalScanRule(
      id: 'LS-EXE-002',
      title: '危险函数调用 eval()',
      description: '检测到 Python eval() 调用，可执行任意表达式，常被用于动态执行恶意代码。',
      severity: SecuritySeverity.high,
      category: 'dangerous-code',
      pattern: r'\beval\s*\(',
      targets: [LocalScanTarget.skill],
    ),
    LocalScanRule(
      id: 'LS-EXE-003',
      title: '系统命令调用',
      description:
          '检测到 os.system / subprocess / os.popen 等系统命令调用，可能在宿主机执行任意命令。',
      severity: SecuritySeverity.high,
      category: 'dangerous-code',
      pattern:
          r'(os\.system\s*\(|subprocess\.(run|call|Popen|check_output)|os\.popen\s*\(|\bshell\s*=\s*True)',
      targets: [LocalScanTarget.skill],
    ),

    // --- 数据外传 ---
    LocalScanRule(
      id: 'LS-EXF-001',
      title: '环境变量收集 + 外发组合',
      description:
          '同时出现环境变量读取（os.environ 等）和网络请求（requests.post 等），疑似收集凭据并发往外部服务器。',
      severity: SecuritySeverity.critical,
      category: 'data-exfiltration',
      pattern:
          r'(os\.environ|environ\.get|getenv).{0,600}(requests\.(post|put)|urllib\.request|urlopen|httpx\.|aiohttp\.|curl\s|wget\s)',
      targets: [LocalScanTarget.skill],
    ),
    LocalScanRule(
      id: 'LS-EXF-002',
      title: '读取敏感文件路径',
      description: '检测到读取 SSH 密钥 / .env / 浏览器凭据等敏感路径的代码。',
      severity: SecuritySeverity.critical,
      category: 'data-exfiltration',
      pattern:
          r'(\.ssh[/\\]id_rsa|\.aws[/\\]credentials|\.env\b|Chrome[/\\]User Data[/\\]Default[/\\]Login Data|\.netrc|\.gnupg)',
      targets: [LocalScanTarget.skill],
    ),

    // --- 提示词注入 ---
    LocalScanRule(
      id: 'LS-INJ-001',
      title: '提示词注入指令',
      description:
          '检测到 "ignore previous instructions" 类指令覆盖模式，可能企图让 AI 无视安全约束。',
      severity: SecuritySeverity.high,
      category: 'prompt-injection',
      pattern:
          r'(ignore|disregard|forget)\s+(all\s+)?(previous|prior|above|earlier|preceding)\s+(instructions?|rules?|prompts?|directives?|constraints?)',
    ),
    LocalScanRule(
      id: 'LS-INJ-002',
      title: '系统提示词泄露指令',
      description: '检测到要求输出/泄露系统提示词的指令（如 "reveal your system prompt"）。',
      severity: SecuritySeverity.medium,
      category: 'prompt-injection',
      pattern:
          r'(reveal|show|print|output|repeat|leak)\s+(your\s+)?(system\s+)?(prompt|instructions|initial\s+instructions|hidden\s+rules)',
    ),

    // --- 供应链 / 混淆 ---
    LocalScanRule(
      id: 'LS-OBF-001',
      title: '超长 Base64 混淆串',
      description: '检测到超过 500 字符的 Base64 长串，常见于隐藏恶意 payload。',
      severity: SecuritySeverity.high,
      category: 'obfuscation',
      pattern: r'[A-Za-z0-9+/]{500,}={0,2}',
      targets: [LocalScanTarget.skill],
    ),
    LocalScanRule(
      id: 'LS-OBF-002',
      title: '超长 Hex 混淆串',
      description: '检测到超过 200 字符的十六进制长串，可能用于混淆代码或数据。',
      severity: SecuritySeverity.medium,
      category: 'obfuscation',
      pattern: r'(?:\\x[0-9a-fA-F]{2}){50,}|\b[0-9a-fA-F]{200,}\b',
      targets: [LocalScanTarget.skill],
    ),

    // --- MCP 专项 ---
    LocalScanRule(
      id: 'LS-MCP-001',
      title: 'MCP 工具描述含不可见 Unicode 字符',
      description: '工具名称/描述中包含零宽字符或双向控制符（Unicode 欺骗），可能对用户隐藏真实行为。',
      severity: SecuritySeverity.critical,
      category: 'mcp-poisoning',
      pattern: '[\u200B-\u200F\u202A-\u202E\u2060\u2066-\u2069\uFEFF]',
      targets: [LocalScanTarget.mcp],
    ),
    LocalScanRule(
      id: 'LS-MCP-002',
      title: 'MCP 工具描述内嵌指令注入',
      description:
          '工具描述中出现指令覆盖类语句（ignore instructions 等），疑似工具投毒（tool poisoning）。',
      severity: SecuritySeverity.critical,
      category: 'mcp-poisoning',
      pattern:
          r'(ignore|disregard|override)\s+(all\s+)?(previous|prior|above)\s+(instructions?|rules?|system)',
      targets: [LocalScanTarget.mcp],
    ),
    LocalScanRule(
      id: 'LS-MCP-003',
      title: 'MCP 配置含可疑远程脚本执行',
      description: 'MCP 配置/描述中包含 curl|bash、wget|sh 等管道执行远程脚本模式，高危。',
      severity: SecuritySeverity.critical,
      category: 'mcp-poisoning',
      pattern:
          r'(curl[^|;]{0,200}\|\s*(ba)?sh|wget[^|;]{0,200}\|\s*(ba)?sh|powershell\s+-enc|iwr[^|;]{0,100}\|)',
      targets: [LocalScanTarget.mcp],
    ),
  ];

  /// 扫描 Skill 内容（SKILL.md 全文）
  static Future<SecurityScanResult> scanSkill({
    required String skillContent,
    String skillName = '',
    String rulesUrl = '',
  }) async {
    return _scan(
      content: skillContent,
      target: LocalScanTarget.skill,
      name: skillName,
      rulesUrl: rulesUrl,
    );
  }

  /// 扫描 MCP 配置（工具定义 JSON + 服务器信息）
  static Future<SecurityScanResult> scanMcp({
    required String toolsJson,
    String serverName = '',
    String endpoint = '',
    String rulesUrl = '',
  }) async {
    // 服务器名也参与扫描（Unicode 欺骗检测）
    final content = '$serverName\n$endpoint\n$toolsJson';
    return _scan(
      content: content,
      target: LocalScanTarget.mcp,
      name: serverName,
      rulesUrl: rulesUrl,
    );
  }

  /// 核心扫描逻辑
  static Future<SecurityScanResult> _scan({
    required String content,
    required LocalScanTarget target,
    required String name,
    required String rulesUrl,
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      _logger.info(
          '本地扫描开始: $name (target=${target.name}, ${content.length} chars)',
          tag: 'LocalScan');

      final rules = await _getEffectiveRules(rulesUrl);
      final findings = <SecurityFinding>[];
      final matchedRuleIds = <String>{};

      for (final rule in rules) {
        if (!rule.enabled || !rule.appliesTo(target)) continue;
        if (rule.pattern.isEmpty) continue;
        // build171（S5）：编译前必须先过回溯闸。语法合法 ≠ 能跑 ——
        // `(a+)+$` 六个字符就能让 irregexp 在一段普通文本上指数爆炸，而这行
        // `re.hasMatch(content)` 跑在 **UI isolate** 上 ⇒ 整个界面冻死，
        // 用户只会看到「卡住」。旧实现唯一那道闸是**正则长度 >200 字符**，
        // 长度拦不住回溯（爆炸样本全都远短于 200）。
        // 闸对内置/远程/自定义**一视同仁**（内置里以后塞一条坏的同样要拦），
        // 且**逐条跳过**：一条坏规则不许让整轮扫描中断或报错。
        final risk = catastrophicBacktrackRisk(rule.pattern);
        if (risk != null) {
          _logger.warn('规则 ${rule.id} 正则会被引擎卡死（$risk），已跳过',
              tag: 'LocalScan');
          continue;
        }
        try {
          final regex =
              RegExp(rule.pattern, dotAll: true, caseSensitive: false);
          if (regex.hasMatch(content)) {
            findings.add(SecurityFinding(
              id: rule.id,
              title: rule.title,
              description: rule.description,
              severity: rule.severity,
              category: rule.category,
            ));
            matchedRuleIds.add(rule.id);
          }
        } catch (e) {
          // 单条规则正则错误不影响整体扫描
          _logger.warn('规则 ${rule.id} 正则错误: $e', tag: 'LocalScan');
        }
      }

      final riskScore = _calculateRiskScore(findings);
      final result = SecurityScanResult(
        success: true,
        riskScore: riskScore,
        severity: _maxSeverity(findings),
        safeToInstall: riskScore < 40,
        findings: findings,
        scanDuration: stopwatch.elapsed,
      );

      _logger.info(
          '本地扫描完成: $name → ${findings.length} findings, risk=$riskScore'
          '${matchedRuleIds.isNotEmpty ? ', rules=[${matchedRuleIds.join(',')}]' : ''}',
          tag: 'LocalScan');
      return result;
    } catch (e) {
      stopwatch.stop();
      _logger.error('本地扫描失败: $e', tag: 'LocalScan');
      return SecurityScanResult(
        success: false,
        errorMessage: e.toString(),
        scanDuration: stopwatch.elapsed,
      );
    }
  }

  /// 计算风险分（0-100）
  /// 每条 finding 按严重度加权，取总和后封顶
  static int _calculateRiskScore(List<SecurityFinding> findings) {
    if (findings.isEmpty) return 0;
    const weights = {
      SecuritySeverity.critical: 45,
      SecuritySeverity.high: 30,
      SecuritySeverity.medium: 15,
      SecuritySeverity.low: 5,
      SecuritySeverity.info: 0,
    };
    var score = 0;
    for (final f in findings) {
      score += weights[f.severity] ?? 0;
    }
    return score.clamp(0, 100);
  }

  static SecuritySeverity _maxSeverity(List<SecurityFinding> findings) {
    if (findings.isEmpty) return SecuritySeverity.info;
    var max = SecuritySeverity.info;
    for (final f in findings) {
      if (f.severity.index > max.index) max = f.severity;
    }
    return max;
  }

  // ==========================================================================
  // 远程规则（预留）：rulesUrl 非空时拉取并合并
  // JSON 格式：
  // {
  //   "version": 2,
  //   "rules": [ { "id":"LS-XXX-001", "title":"...", "description":"...",
  //                "severity":"high", "category":"...",
  //                "pattern":"...", "enabled":true, "targets":["skill"] } ],
  //   "disableBuiltin": ["UR-1"]  // 可选：只关得动非内置规则
  //                               // （LS- 那 12 条一律禁不掉，见 _protectedRuleIds）
  // }
  // ==========================================================================

  static Future<List<LocalScanRule>> _getEffectiveRules(String rulesUrl) async {
    var builtin = List<LocalScanRule>.from(builtinRules);

    // build98（本地加强⑥）：用户自定义规则追加合并（离线可用，ID 前缀 UR-）
    try {
      final custom = await CustomScanRules.load();
      if (custom.isNotEmpty) {
        builtin = mergeCustomRules(builtin, custom);
      }
    } catch (e) {
      _logger.warn('自定义规则合并失败: $e', tag: 'LocalScan');
    }

    if (rulesUrl.trim().isEmpty) return builtin;

    // 缓存命中直接用
    if (_remoteRulesCache != null &&
        DateTime.now().difference(_remoteRulesFetchedAt) < _remoteCacheTtl) {
      return _mergeRules(builtin, _remoteRulesCache!, keepBuiltinIds: true);
    }

    final trimmedUrl = rulesUrl.trim();
    if (!_isSafePublicUrl(trimmedUrl)) {
      _logger.warn('远程规则 URL 未通过安全校验，回落内置规则', tag: 'LocalScan');
      return builtin;
    }

    // v1.7.38：统一走 GitHubContentFetcher（对冲并发+成功记忆+超时拆分+全链路日志）
    try {
      final body = await GitHubContentFetcher.fetchText(
        trimmedUrl,
        totalTimeout: const Duration(seconds: 20),
        tag: 'scan-rules',
      );
      final data = jsonDecode(body) as Map<String, dynamic>;
      final rulesJson = (data['rules'] as List<dynamic>? ?? [])
          .map((r) => LocalScanRule.fromJson(r as Map<String, dynamic>? ?? {}))
          .where((r) {
        if (r.id.isEmpty || r.pattern.isEmpty) return false;
        if (r.pattern.length > 200) {
          _logger.warn('远程规则 ${r.id} 正则过长(${r.pattern.length}字符)，已跳过',
              tag: 'LocalScan');
          return false;
        }
        return true;
      }).toList();
      // build98（P2-7）/build171（S3）：disableBuiltin 的条数上限与受保护名单
      // 都收进 mergeRemoteRules —— 内置那 12 条一律禁不掉，见 _protectedRuleIds。
      final disableBuiltin = (data['disableBuiltin'] as List<dynamic>? ?? [])
          .map((e) => e.toString());
      // build98（本地加强③）：黑名单随 rules.json 下发
      final bl = data['blacklist'];
      if (bl is Map) {
        _blacklistDomains = (bl['domains'] as List<dynamic>? ?? [])
            .map((e) => e.toString().toLowerCase())
            .where((e) => e.isNotEmpty)
            .toSet();
        _blacklistSha256 = (bl['sha256'] as List<dynamic>? ?? [])
            .map((e) => e.toString().toLowerCase())
            .where((e) => e.isNotEmpty)
            .toSet();
      }
      _remoteRulesCache = rulesJson;
      _remoteRulesFetchedAt = DateTime.now();
      _logger.info('远程规则拉取成功: ${rulesJson.length} 条 (v${data['version']})',
          tag: 'LocalScan');
      return mergeRemoteRules(builtin, rulesJson,
          disableBuiltin: disableBuiltin);
    } catch (e) {
      _logger.warn('远程规则拉取异常: $e', tag: 'LocalScan');
    }
    _logger.warn('远程规则拉取失败，回落内置规则', tag: 'LocalScan');
    return builtin;
  }

  // build98（P2-7）→ build171（S3）：核心安全规则不允许被远程 rules.json 禁用。
  //
  // 旧实现是一份**写死的 id 名单**（5 个：LS-EXF-001/002、LS-MCP-001/002/003）。
  // 而远程 `disableBuiltin` 同样被限到 [maxRemoteDisableBuiltin] 条 ⇒
  // 5 个名额刚好够把名单外的 LS-EXE-001/002/003 + LS-INJ-001/002 一次关掉：
  // 「危险代码执行」与「提示注入」两族可以整族被远程清零，日志里连一条痕迹都没有。
  //
  // 现在保护集合**从 builtinRules 的 id 推导**，不再写死名单：内置规则一律不可
  // 被远程禁用，以后新增内置规则自动进闸，不需要有人记得往名单里补一行
  // （判据见 test/build171_remote_rule_gates_test.dart 的枚举那条）。
  static Set<String> get _protectedRuleIds =>
      builtinRules.map((r) => r.id).toSet();

  /// 远程 `disableBuiltin` 一次最多能声明几条（build98 的上限，build171 保持不变）。
  static const int maxRemoteDisableBuiltin = 5;

  /// build171（S3）：远程 `disableBuiltin` 的闸——先按 build98 的口径取前
  /// [maxRemoteDisableBuiltin] 条，再把命中受保护内置 id 的**记日志并忽略**。
  /// 可见性沿用 build98：走 `_logger.warn`，**不许**降级成 `debugPrint`
  /// （release 构建里 debugPrint 是 no-op，闸就变成没人看得见的静默丢弃）。
  static Set<String> _applyDisableGate(Iterable<String> rawIds) {
    final disabledIds = rawIds.take(maxRemoteDisableBuiltin).toSet();
    // build98（P2-7）：核心安全规则不允许被远程禁用，命中则记日志并忽略
    disabledIds.removeWhere((id) {
      if (_protectedRuleIds.contains(id)) {
        _logger.warn('远程规则试图禁用受保护核心规则 $id，已忽略',
            tag: 'LocalScan');
        return true;
      }
      return false;
    });
    return disabledIds;
  }

  /// build171（S3）：「禁用闸 + 合并」这两步的合成入口（远程与自定义同一条路）。
  ///
  /// 从 [_getEffectiveRules] 里**逐字拆出**，只为让这道闸能被单测钉住——原路径
  /// 要先过一次真 HTTP（GitHubContentFetcher），单测里起不来。
  /// build171 起这**就是**远程那一路的正门：远程新规则可追加、非内置 id 仍可被远程禁用，
  /// 但同 id 顶掉内置那一条自 171 起不允许（`keepBuiltinIds: true`）——
  /// 与 `disableBuiltin` 合起来才是"内置 12 条既删不掉也顶不掉"。
  static List<LocalScanRule> mergeRemoteRules(
    List<LocalScanRule> base,
    List<LocalScanRule> remote, {
    Iterable<String> disableBuiltin = const [],
  }) =>
      _mergeRules(base, remote,
          disabledIds: _applyDisableGate(disableBuiltin), keepBuiltinIds: true);

  /// 本地自定义规则那一路（用户在设置里自己写的，`CustomScanRules.load()` 的结果）。
  /// 与远程分开是 171 的口径：**本地意志可以顶内置**（同 id 覆盖语义原样保留），
  /// 下发的载荷不行。生产码在 `_getEffectiveRules` 里走的就是这个入口，
  /// 所以判据钉的不是一个测试专用的复制品。
  static List<LocalScanRule> mergeCustomRules(
    List<LocalScanRule> base,
    List<LocalScanRule> custom,
  ) =>
      _mergeRules(base, custom);

  static bool _isSafePublicUrl(String url) {
    try {
      final uri = Uri.parse(url);
      var host = uri.host;
      if (uri.scheme != 'https') return false;
      if (host.isEmpty) return false;
      // build98（P2-7）：IPv6 一律拒绝（规则源场景无合理 IPv6 需求）。
      // Uri.parse 对 IPv6 host 可能带或不带方括号，两种都覆盖。
      if (host.startsWith('[')) return false;
      if (host.contains(':')) return false;
      host = host.toLowerCase();
      // build98（P2-7）：拒绝 localhost 及本地域
      if (host == 'localhost' ||
          host.endsWith('.localhost') ||
          host.endsWith('.local') ||
          host.endsWith('.internal')) {
        return false;
      }
      if (RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(host)) {
        final parts = host.split('.').map(int.parse).toList();
        if (parts[0] == 10) return false;
        if (parts[0] == 172 && parts[1] >= 16 && parts[1] <= 31) return false;
        if (parts[0] == 192 && parts[1] == 168) return false;
        if (parts[0] == 127) return false;
        if (parts[0] == 169 && parts[1] == 254) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 合并规则：远程同 ID 覆盖内置；disableBuiltin 中的内置规则被禁用；
  /// 远程新增规则追加
  static List<LocalScanRule> _mergeRules(
    List<LocalScanRule> builtin,
    List<LocalScanRule> remote, {
    Set<String> disabledIds = const {},
    bool keepBuiltinIds = false,
  }) {
    final remoteById = {for (final r in remote) r.id: r};
    final merged = <LocalScanRule>[];
    for (final b in builtin) {
      if (disabledIds.contains(b.id)) continue; // 远程声明禁用
      if (remoteById.containsKey(b.id)) {
        if (keepBuiltinIds) {
          // build171（S3 补的那一刀，**只作用于远程那一路**）：保护口径从"禁不掉"
          // 扩到"顶不掉"。只挡 `disableBuiltin` 不够——远程下发一条同 id、
          // `enabled:false`（或一条永不匹配的正则）盖住内置那条，列表里 id 还在、
          // UI 一切正常，实际那一族的检测已静默消失，与"整族关掉"同一个后果。
          // 用户自己在设置里写的自定义规则照旧可以顶内置（那是本地意志，不是下发的载荷）；
          // 两条路过去共用一个 merge 函数，正是这道洞的根因，所以拆成两个入口。
          _logger.warn('远程规则与内置同 id（${b.id}），已保留内置那一条',
              tag: 'LocalScan');
          merged.add(b);
        } else {
          merged.add(remoteById[b.id]!); // 同 id 覆盖（本地自定义那一路，语义不变）
        }
      } else {
        merged.add(b);
      }
    }
    // 远程新增规则
    for (final r in remote) {
      if (!merged.any((m) => m.id == r.id)) merged.add(r);
    }
    return merged;
  }

  /// 清除远程规则缓存（设置页修改 URL 后调用）
  static void clearCache() {
    _remoteRulesCache = null;
    _remoteRulesFetchedAt = DateTime.fromMillisecondsSinceEpoch(0);
    _blacklistDomains = {};
    _blacklistSha256 = {};
    _lastSyncStatus = null;
  }

  // ==========================================================================
  // 自动同步状态（P2-3）
  // ==========================================================================

  static DateTime? _lastSyncTime;
  static String? _lastSyncStatus;

  static DateTime? get lastSyncTime => _lastSyncTime;
  static String? get lastSyncStatus => _lastSyncStatus;

  /// 手动触发远程规则同步（从 URL 拉取并缓存）
  static Future<({bool ok, String message})> prefetchRules(
      String rulesUrl) async {
    if (rulesUrl.trim().isEmpty) {
      _lastSyncStatus = 'empty_url';
      return (ok: false, message: 'URL is empty');
    }
    clearCache();
    try {
      await _getEffectiveRules(rulesUrl);
      final remoteCount = _remoteRulesCache?.length ?? 0;
      _lastSyncTime = DateTime.now();
      if (remoteCount > 0) {
        _lastSyncStatus = 'ok';
        return (ok: true, message: 'Synced $remoteCount remote rules');
      } else {
        _lastSyncStatus = 'ok_builtin_only';
        return (ok: true, message: 'No remote rules, using builtin only');
      }
    } catch (e) {
      _lastSyncTime = DateTime.now();
      _lastSyncStatus = 'error';
      return (ok: false, message: 'Sync failed: $e');
    }
  }
}
