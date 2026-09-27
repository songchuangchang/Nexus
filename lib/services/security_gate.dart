/// 安全审查统一入口（build98 安全审查体系重构）
///
/// 安装链路只调这里，不再各调各的：
///   1) URL/域名审查（仅 https、私网地址拦截、恶意域名黑名单命中直接拒装，
///      吞并 P2-8「Skill 允许 http://」）
///   2) 本地规则扫描（AI 代装通道强制必跑 forceLocalScan=true；手动安装受
///      enableLocalScan 开关控制——build99 验收 N4，原文案「离线必跑」与代码不符）
///   3) 远程引擎叠加（SkillSpector，配置了端点+开关才跑）
///   合并为一份 GateReport：风险分取各引擎最大值，findings 汇总。
///
/// 附带本地加强④⑤：
///   ④ env/凭据类字段（KEY/SECRET/TOKEN/PASSWORD）提示「明文存储本机」
///   ⑤ severity >= high 时 forceConfirmEveryCall=true，调用方装完后把
///      extra['securityForceConfirm']=true 写入插件，工具调用强制每次弹确认
library security_gate;

import 'package:http/http.dart' as http;

import '../models/web_search_config.dart';
import 'local_scan_service.dart';
import 'logger_service.dart';
import 'security_audit_log.dart';
import 'security_scan_service.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

/// 统一审查报告
class GateReport {
  /// URL/域名审查发现（硬性，blocked=true 时不允许装）
  final List<SecurityFinding> urlFindings;

  /// 本地规则扫描结果（未启用/未执行为 null）
  final SecurityScanResult? localResult;

  /// 远程深扫结果（未启用/未执行为 null）
  final SecurityScanResult? remoteResult;

  /// ④ 命中的敏感凭据字段名（提示明文存储本机）
  final List<String> sensitiveKeys;

  /// 黑名单/URL 审查硬拦截
  final bool blocked;
  final String blockReason;

  const GateReport({
    this.urlFindings = const [],
    this.localResult,
    this.remoteResult,
    this.sensitiveKeys = const [],
    this.blocked = false,
    this.blockReason = '',
  });

  /// 合并后的全部 findings
  List<SecurityFinding> get findings => [
        ...urlFindings,
        ...?localResult?.findings,
        ...?remoteResult?.findings,
      ];

  /// 合并风险分（取各引擎最大值）
  int get riskScore {
    var s = 0;
    if (urlFindings.isNotEmpty) s = 60;
    if (localResult != null && localResult!.riskScore > s) {
      s = localResult!.riskScore;
    }
    if (remoteResult != null && remoteResult!.riskScore > s) {
      s = remoteResult!.riskScore;
    }
    return s;
  }

  SecuritySeverity get severity {
    var max = SecuritySeverity.info;
    for (final f in findings) {
      if (f.severity.index > max.index) max = f.severity;
    }
    return max;
  }

  /// 任一引擎判定不安全
  bool get unsafe =>
      blocked ||
      (localResult != null && localResult!.success && !localResult!.safeToInstall) ||
      (remoteResult != null &&
          remoteResult!.success &&
          !remoteResult!.safeToInstall);

  /// 任一已启用引擎执行失败（fail-closed 场景由调用方决定）
  bool get anyEngineFailed =>
      (localResult != null && !localResult!.success) ||
      (remoteResult != null && !remoteResult!.success);

  String get engineError {
    if (localResult != null && !localResult!.success) {
      return localResult!.errorMessage;
    }
    if (remoteResult != null && !remoteResult!.success) {
      return remoteResult!.errorMessage;
    }
    return '';
  }

  /// ⑤ 扫出 high/critical → 该插件工具调用强制每次弹确认
  bool get forceConfirmEveryCall =>
      severity.index >= SecuritySeverity.high.index;
}

class SecurityGate {
  static final LoggerService _logger = LoggerService.instance;

  /// 敏感凭据字段名（④）
  static final RegExp _sensitiveKey =
      RegExp(r'(KEY|SECRET|TOKEN|PASSWORD|CREDENTIAL)', caseSensitive: false);

  static List<String> findSensitiveKeys(Iterable<String> names) =>
      names.where((n) => _sensitiveKey.hasMatch(n)).toList();

  /// MCP 安装前统一审查
  static Future<GateReport> scanMcp({
    required String serverName,
    required String endpoint,
    required String toolsJson,
    required WebSearchConfig cfg,
    List<String> envKeys = const [],
    // build99（验收 N4）：AI 代装通道无用户确认，本地规则强制跑（忽略开关）
    bool forceLocalScan = false,
  }) async {
    // 黑名单随规则源先同步一次（有缓存则秒回）
    if (cfg.localScanRulesUrl.trim().isNotEmpty) {
      await LocalScanService.prefetchRules(cfg.localScanRulesUrl);
    }

    final urlFindings = await auditUrl(endpoint, recordTarget: serverName);
    final blocked = urlFindings.any(
        (f) => f.severity.index >= SecuritySeverity.high.index);
    final blockReason = blocked
        ? urlFindings
            .where((f) => f.severity.index >= SecuritySeverity.high.index)
            .map((f) => f.title)
            .join('；')
        : '';

    SecurityScanResult? localResult;
    SecurityScanResult? remoteResult;
    if (!blocked) {
      if (forceLocalScan || cfg.enableLocalScan) {
        localResult = await LocalScanService.scanMcp(
          toolsJson: toolsJson,
          serverName: serverName,
          endpoint: endpoint,
          rulesUrl: cfg.localScanRulesUrl,
        );
      }
      if (cfg.enableMcpSecurityScan && cfg.skillspectorEndpoint.isNotEmpty) {
        remoteResult = await SecurityScanService.scanMcp(
          skillspectorEndpoint: cfg.skillspectorEndpoint,
          toolsJson: toolsJson,
          serverName: serverName,
          endpoint: endpoint,
        );
      }
    }

    final report = GateReport(
      urlFindings: urlFindings,
      localResult: localResult,
      remoteResult: remoteResult,
      sensitiveKeys: findSensitiveKeys(envKeys),
      blocked: blocked,
      blockReason: blockReason,
    );
    await _record('scan', serverName, report);
    return report;
  }

  /// Skill 安装前统一审查
  static Future<GateReport> scanSkill({
    required String skillContent,
    String skillName = '',
    String sourceUrl = '',
    required WebSearchConfig cfg,
    // build99（验收 N4）：AI 代装通道无用户确认，本地规则强制跑（忽略开关）
    bool forceLocalScan = false,
  }) async {
    if (cfg.localScanRulesUrl.trim().isNotEmpty) {
      await LocalScanService.prefetchRules(cfg.localScanRulesUrl);
    }

    final urlFindings = sourceUrl.trim().isEmpty
        ? <SecurityFinding>[]
        : await auditUrl(sourceUrl, recordTarget: skillName);
    final blocked = urlFindings.any(
        (f) => f.severity.index >= SecuritySeverity.high.index);
    final blockReason = blocked
        ? urlFindings
            .where((f) => f.severity.index >= SecuritySeverity.high.index)
            .map((f) => f.title)
            .join('；')
        : '';

    SecurityScanResult? localResult;
    SecurityScanResult? remoteResult;
    if (!blocked) {
      if (forceLocalScan || cfg.enableLocalScan) {
        localResult = await LocalScanService.scanSkill(
          skillContent: skillContent,
          skillName: skillName,
          rulesUrl: cfg.localScanRulesUrl,
        );
      }
      if (cfg.enableSkillSecurityScan && cfg.skillspectorEndpoint.isNotEmpty) {
        remoteResult = await SecurityScanService.scanSkill(
          skillspectorEndpoint: cfg.skillspectorEndpoint,
          skillContent: skillContent,
          skillName: skillName,
        );
      }
    }

    final report = GateReport(
      urlFindings: urlFindings,
      localResult: localResult,
      remoteResult: remoteResult,
      blocked: blocked,
      blockReason: blockReason,
    );
    await _record('scan', skillName.isEmpty ? sourceUrl : skillName, report);
    return report;
  }

  /// ② 安装链接 URL/域名审查：仅 https、私网地址拦截、黑名单命中直接拒装、
  /// 重定向后目标复检（网络不可达不拦截，仅记 info）
  static Future<List<SecurityFinding>> auditUrl(String rawUrl,
      {String recordTarget = ''}) async {
    final findings = <SecurityFinding>[];
    final url = rawUrl.trim();
    if (url.isEmpty) return findings;

    Uri? uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) {
      findings.add(const SecurityFinding(
        id: 'GATE-URL-000',
        title: '安装链接不是合法 URL',
        description: '无法解析的链接，已拒绝安装。',
        severity: SecuritySeverity.high,
        category: 'supply-chain',
      ));
      return findings;
    }

    // 仅 https（吞并 P2-8：Skill 允许 http://）
    if (uri.scheme != 'https') {
      findings.add(const SecurityFinding(
        id: 'GATE-URL-001',
        title: '安装链接未使用 HTTPS',
        description: '明文 http:// 链接可被中间人篡改，已拒绝安装。',
        severity: SecuritySeverity.high,
        category: 'supply-chain',
      ));
    }

    // 私网/回环地址（安装链接不应指向内网）
    if (isPrivateHost(uri.host)) {
      findings.add(SecurityFinding(
        id: 'GATE-URL-002',
        title: '安装链接指向私网/回环地址',
        description: 'host=${uri.host}，疑似 SSRF 或本地劫持，已拒绝安装。',
        severity: SecuritySeverity.critical,
        category: 'supply-chain',
      ));
    }

    // ③ 恶意域名黑名单（随 rules.json 远程更新）
    final host = uri.host.toLowerCase();
    final hit = LocalScanService.blacklistedDomains
        .any((d) => host == d || host.endsWith('.$d'));
    if (hit) {
      findings.add(SecurityFinding(
        id: 'GATE-URL-003',
        title: '域名命中恶意指纹黑名单',
        description: 'host=$host 在远程黑名单中，已拒绝安装。',
        severity: SecuritySeverity.critical,
        category: 'supply-chain',
      ));
      await SecurityAuditLog.record(
        type: 'blacklist_hit',
        target: recordTarget.isEmpty ? host : recordTarget,
        outcome: 'blocked',
        detail: 'domain=$host',
      );
    }

    if (findings.any(
        (f) => f.severity.index >= SecuritySeverity.high.index)) {
      return findings; // 已硬拦，不再发网络请求
    }

    // 重定向复检：最多跟随 3 跳，每跳目标重新过 https/私网/黑名单
    try {
      var current = uri;
      for (var hop = 0; hop < 3; hop++) {
        final req = http.Request('HEAD', current)
          ..followRedirects = false
          ..maxRedirects = 0;
        final resp = await req.send().timeout(const Duration(seconds: 8));
        if (resp.statusCode >= 300 &&
            resp.statusCode < 400 &&
            resp.headers['location'] != null) {
          final next = current.resolve(resp.headers['location']!);
          if (next.scheme != 'https' || isPrivateHost(next.host)) {
            findings.add(SecurityFinding(
              id: 'GATE-URL-004',
              title: '安装链接重定向到不安全地址',
              description: '第 ${hop + 1} 跳重定向到 ${next.host}（${next.scheme}），已拒绝安装。',
              severity: SecuritySeverity.high,
              category: 'supply-chain',
            ));
            return findings;
          }
          final nextHost = next.host.toLowerCase();
          if (LocalScanService.blacklistedDomains
              .any((d) => nextHost == d || nextHost.endsWith('.$d'))) {
            findings.add(SecurityFinding(
              id: 'GATE-URL-005',
              title: '重定向目标命中恶意域名黑名单',
              description: '第 ${hop + 1} 跳重定向到 $nextHost，已拒绝安装。',
              severity: SecuritySeverity.critical,
              category: 'supply-chain',
            ));
            return findings;
          }
          current = next;
          continue;
        }
        break; // 非重定向，结束
      }
    } catch (e) {
      // 网络不可达不拦截安装（可能是离线/内网环境），仅记日志
      _logger.info('URL 重定向复检跳过（网络不可达）: $e', tag: 'SecurityGate');
    }
    return findings;
  }

  /// build145：字面数字化主机的形状 —— 以数字开头，且只由数字、a-f（十六进制
  /// 残留位）、x（0x 前缀）与点构成。含其它字母的主机（`example.com`、
  /// `3star.test`）判定为名字，不尝试 DNS，一律按公网返回 false。
  static final RegExp _ipv4LiteralShape = RegExp(r'^[0-9][0-9a-fx.]*$');
  static final RegExp _ipv4HexDigits = RegExp(r'^[0-9a-f]+$');
  static final RegExp _ipv4OctalDigits = RegExp(r'^[0-7]+$');
  static final RegExp _ipv6Group = RegExp(r'^[0-9a-f]{1,4}$');

  /// build138（扫描 P2-7）：由 `_isPrivateHost` 改名并开放给测试——
  /// 这个判定是 SSRF 的第一道闸，此前**没有任何可断言的入口**（私有静态 +
  /// 调用点要真网络），畸形数字化主机抛异常导致 fail-open 这件事写不出回归。
  ///
  /// build145（循环审查第 7 轮 P1）：本函数是**句法闸，不是解析器**——
  /// 它不做 DNS，且**故意**不做：
  ///   1) 一旦在这里解析域名，就重新引入「检查时刻解析出的 IP ≠ 请求时刻的
  ///      IP」的 TOCTOU 窗口（DNS rebinding 正是打这个缝）；
  ///   2) 拿不到答案时也不猜：非数字主机名（含指向 127.0.0.1 的域名）一律
  ///      返回 false（视作公网）。防「域名→私网 IP」必须靠出口网络策略 /
  ///      代理白名单，而不是本函数。后来的读者请勿把「过了这道闸」理解成
  ///      「目标一定是公网」。
  ///
  /// 句法覆盖（总原则 fail-closed：解析不了 / 不能确信是公网 ⇒ 私网）：
  ///   · `localhost` / `*.localhost` / `*.local`；
  ///   · IPv6：回环（`::`、`::1`）、链路本地 fe80::/10、ULA fc00::/7、
  ///     IPv4-mapped/compatible（`::ffff:a.b.c.d`、`::a.b.c.d`，取内嵌 IPv4
  ///     走同一个 IPv4 分类器）；仅 2000::/3 全局单播放行；
  ///   · IPv4 的任意 Android 网络栈会认的文本形态：1~4 段点分（末段吸收剩余
  ///     字节，`127.1`==127.0.0.1、`10`==0.0.0.10），十进制 / 0x 十六进制 /
  ///     前导 0 八进制，以及单段 32 位整数（2130706433、0x7f000001、0177.0.0.1）；
  ///   · 私网/保留段：0/8、10/8、100.64.0.0/10（CGNAT）、127/8、169.254/16、
  ///     172.16/12、192.0.0.0/24、192.168/16、198.18.0.0/15。
  @visibleForTesting
  static bool isPrivateHost(String host) {
    final h = host.toLowerCase();
    if (h.isEmpty) return true; // 空 host 交给调用点的 URL 合法性检查，这里先拦
    if (h == 'localhost' || h.endsWith('.localhost') || h.endsWith('.local')) {
      return true;
    }
    // 含 ':' 即按 IPv6 处理。注意 build145 实测：Uri.parse('http://[::1]/x')
    // 的 .host 返回 `::1`（**不带**方括号），旧实现 `h.startsWith('[')` 是
    // 死代码，「IPv6 一律按私网」实际只匹配了字面 '::1'，fd00::/fe80::/
    // ::ffff:127.0.0.1 全部漏网走人最后的 return false（视作公网）。
    if (h.contains(':')) return _isPrivateIpv6(h);
    if (_ipv4LiteralShape.hasMatch(h)) {
      final v = _parseIpv4Literal(h);
      // build138（扫描 P2-7）的教训保留：解析不了 / 越界（例如
      // `99999999999999999999.1.1.1`，旧代码 int.parse 抛 FormatException 被
      // 调用点 catch 成「网络不可达」而 fail-open）⇒ 按私网拦下。
      return v == null || _isPrivateIpv4(v);
    }
    return false; // 普通主机名：本函数不做 DNS（理由见上方文档）
  }

  /// 按 inet_aton 语义把数字化主机解析成 32 位地址；解析不了 / 越界返回 null。
  static int? _parseIpv4Literal(String h) {
    final parts = h.split('.');
    if (parts.length > 4) return null;
    final vals = <int>[];
    for (final p in parts) {
      final v = _parseIpv4Part(p);
      if (v == null) return null;
      vals.add(v);
    }
    final n = vals.length;
    if (n == 1) {
      return vals[0] <= 0xFFFFFFFF ? vals[0] : null;
    }
    if (vals[0] > 255) return null;
    if (n == 2) {
      return vals[1] <= 0xFFFFFF ? (vals[0] << 24) | vals[1] : null;
    }
    if (vals[1] > 255) return null;
    if (n == 3) {
      return vals[2] <= 0xFFFF
          ? (vals[0] << 24) | (vals[1] << 16) | vals[2]
          : null;
    }
    if (vals[2] > 255 || vals[3] > 255) return null;
    return (vals[0] << 24) | (vals[1] << 16) | (vals[2] << 8) | vals[3];
  }

  /// 单个文本段：十进制 / 0x 十六进制 / 前导 0 八进制；不合法返回 null。
  /// 一律 tryParse + 显式 radix（入参已小写）——`int.parse` 对无界数字串会
  /// 抛 FormatException，正是 build138 P2-7 修掉的坑。
  static int? _parseIpv4Part(String p) {
    if (p.isEmpty) return null;
    if (p == '0') return 0;
    if (p.startsWith('0x')) {
      final d = p.substring(2);
      return _ipv4HexDigits.hasMatch(d) ? int.tryParse(d, radix: 16) : null;
    }
    if (p.startsWith('0')) {
      final d = p.substring(1);
      return _ipv4OctalDigits.hasMatch(d) ? int.tryParse(d, radix: 8) : null;
    }
    return int.tryParse(p, radix: 10); // 混入字母时 tryParse 自然给 null
  }

  /// 已解析成 32 位地址后的私网/保留段判定。
  /// build145（循环审查第 7 轮 P1）补上原实现漏掉、且 Android 上真实可达的：
  /// 100.64.0.0/10（CGNAT，部分 VPN/热点栈把本机分到这里）、192.0.0.0/24、
  /// 198.18.0.0/15（IETF 保留/基准测试段）。
  static bool _isPrivateIpv4(int addr) {
    final a = (addr >> 24) & 0xFF;
    final b = (addr >> 16) & 0xFF;
    if (a == 10 || a == 127 || a == 0) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    if (a == 192 && b == 168) return true;
    if (a == 169 && b == 254) return true;
    if (a == 100 && b >= 64 && b <= 127) return true;
    if (a == 192 && b == 0 && ((addr >> 8) & 0xFF) == 0) return true;
    if (a == 198 && (b == 18 || b == 19)) return true;
    return false;
  }

  /// IPv6 句法判定：展开成 16 字节后分类。规则集见 [isPrivateHost] 文档；
  /// 唯一放行的是 2000::/3 全局单播，其余（含解析失败）一律私网（fail-closed）。
  static bool _isPrivateIpv6(String host) {
    var s = host;
    if (s.length >= 2 && s.startsWith('[') && s.endsWith(']')) {
      s = s.substring(1, s.length - 1); // 兼容手工带方括号的调用形态
    }
    final bytes = _expandIpv6(s);
    if (bytes == null) return true;
    bool allZero(int from, int to) {
      for (var i = from; i < to; i++) {
        if (bytes[i] != 0) return false;
      }
      return true;
    }
    final mapped = allZero(0, 10) && bytes[10] == 0xFF && bytes[11] == 0xFF;
    final compatible = allZero(0, 12); // 也覆盖 '::' 与 '::1'
    if (mapped || compatible) {
      final embedded =
          (bytes[12] << 24) | (bytes[13] << 16) | (bytes[14] << 8) | bytes[15];
      return _isPrivateIpv4(embedded);
    }
    if (bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80) return true; // fe80::/10
    if ((bytes[0] & 0xFE) == 0xFC) return true; // fc00::/7 ULA
    if ((bytes[0] & 0xE0) == 0x20) return false; // 2000::/3 全局单播
    return true; // 组播 ff00::/8、保留段等：不能确信是公网 ⇒ 私网
  }

  /// 把去括号后的 IPv6 文本展开成 16 字节；不支持的写法一律 null（⇒ 私网）。
  static List<int>? _expandIpv6(String s) {
    if (s.isEmpty) return null;
    final dc = s.indexOf('::');
    if (dc != -1 && s.indexOf('::', dc + 2) != -1) return null; // '::' 至多一个
    final leftStr = dc == -1 ? s : s.substring(0, dc);
    final rightStr = dc == -1 ? '' : s.substring(dc + 2);
    final left = _ipv6SegmentToBytes(leftStr);
    final right = _ipv6SegmentToBytes(rightStr);
    if (left == null || right == null) return null;
    if (dc == -1) {
      if (left.length != 16) return null; // 无压缩必须凑满 8 段
    } else if (left.length + right.length > 14) {
      return null; // '::' 必须至少代表一个 16 位零段
    }
    final bytes = List<int>.filled(16, 0);
    bytes.setRange(0, left.length, left);
    bytes.setRange(16 - right.length, 16, right);
    return bytes;
  }

  /// 一段（':' 分隔的 token 串）转字节；末 token 允许内嵌 IPv4 点分形态
  /// （`::ffff:127.0.0.1` 里的 `127.0.0.1`，走同一个 IPv4 解析器）。
  static List<int>? _ipv6SegmentToBytes(String seg) {
    if (seg.isEmpty) return const <int>[];
    final tokens = seg.split(':');
    final bytes = <int>[];
    for (var i = 0; i < tokens.length; i++) {
      final t = tokens[i];
      if (t.contains('.')) {
        if (i != tokens.length - 1) return null; // 内嵌 IPv4 只允许出现在末尾
        final v4 = _parseIpv4Literal(t);
        if (v4 == null) return null;
        bytes
          ..add((v4 >> 24) & 0xFF)
          ..add((v4 >> 16) & 0xFF)
          ..add((v4 >> 8) & 0xFF)
          ..add(v4 & 0xFF);
        continue;
      }
      if (!_ipv6Group.hasMatch(t)) return null;
      final g = int.tryParse(t, radix: 16);
      if (g == null) return null;
      bytes
        ..add((g >> 8) & 0xFF)
        ..add(g & 0xFF);
    }
    return bytes;
  }

  static Future<void> _record(
      String type, String target, GateReport report) async {
    await SecurityAuditLog.record(
      type: type,
      target: target,
      outcome: report.blocked
          ? 'blocked'
          : report.unsafe
              ? 'warn'
              : report.anyEngineFailed
                  ? 'failed'
                  : 'pass',
      detail: report.blocked
          ? report.blockReason
          : 'risk=${report.riskScore}, findings=${report.findings.length}',
    );
  }
}
