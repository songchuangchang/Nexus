// build153（SSRF 批）：MCP「用户可填 / 市场下发」URL 的 IP 层判定。
//
// 为什么要换判定口径：旧实现（`isSafeMcpHttpsUri` / `SecurityGate.isPrivateHost`）
// 只做**句法**闸 —— 字面 IP 按字节分类，**域名一律当公网返回 false（放行）**。
// 于是 `https://内网域名/`（内部 wiki、`metadata.google.internal`、把 `api.internal`
// 指到 169.254.169.254 的 DNS 记录）全部漏网，市场条目只要下发一个域名就能让 App
// 替攻击者打内网请求（含云元数据服务）。
//
// 本文件的口径：
//   1) 主机名先按字面 IP 分类（`isPrivateIpBytes`，纯函数、可单测）；
//   2) 不是字面 IP 的，**解析 DNS 后按解析到的 IP 判定**（`ssrfRejectionReason`），
//      解析器可注入 ⇒ 单测里不需要真发 DNS；
//   3) DNS 解析失败 / 解析结果为空 ⇒ **拒绝**（fail-closed，绝不因解析不了而放行）；
//   4) 重定向后必须再走一遍同样的闸（见 `mcp_client_service._guardEndpoint` 的逐跳调用）。
//
// 数字化但语法坏掉的 host（`0177.0.0.1`、`2130706433`、`999.1.1.1`）：底层网络栈
// 有的会按 inet_aton 风格解析成功，句法层无法安全分类 ⇒ 直接按内网拦（fail-closed）。

import 'dart:io';

/// 可注入的 DNS 解析器（默认走 `InternetAddress.lookup`，单测里给假实现）。
typedef SsrfIpLookup = Future<List<InternetAddress>> Function(String host);

/// 默认解析器：系统 DNS。异常原样抛给上层，由上层按 fail-closed 处理。
Future<List<InternetAddress>> defaultSsrfIpLookup(String host) =>
    InternetAddress.lookup(host);

/// 明确按名字拦掉的内部域名后缀（元数据服务、RFC 6762 本地域、常见内网 TLD）。
/// 只是**第一层**：真正的判定在 IP 层，这里避免为明显的内部名字白跑一次 DNS。
const Set<String> kSsrfBlockedHostSuffixes = {
  '.localhost',
  '.local',
  '.internal',
  '.home.arpa',
  '.intratest',
};

/// 云厂商元数据服务的**字面**主机名（各厂商同 IP，按名字兜一层）。
const Set<String> kSsrfBlockedMetadataHosts = {
  'metadata',
  'metadata.google.internal',
  'metadata.google',
  'instance-data',
};

/// 数字化主机形状（与 build145 的句法闸同一套判据）：以数字开头，且只由
/// 数字、`a-f`、`x`（0x 前缀）、点构成。含其它字母的按**名字**处理，交给 DNS。
final RegExp _digitizedHostShape = RegExp(r'^[0-9][0-9a-fx.]*$');

/// 是否像 IP 字面量（含 IPv6 的冒号形态）。
bool isIpLikeHost(String host) =>
    host.contains(':') || _digitizedHostShape.hasMatch(host);

/// URL 的 `host` 对 IPv6 会带方括号（`[::1]`），分类前剥掉。
String bareHost(String host) {
  final h = host.trim().toLowerCase();
  if (h.startsWith('[') && h.endsWith(']') && h.length > 2) {
    return h.substring(1, h.length - 1);
  }
  return h;
}

/// 纯函数：给定 IP 的原始字节（4 = IPv4，16 = IPv6），是否属于
/// 内网 / 回环 / 链路本地 / 元数据段 / 其它不可公网路由的地址。
///
/// 长度不是 4 或 16 ⇒ 按内网返回 true（fail-closed）。
bool isPrivateIpBytes(List<int> bytes) {
  if (bytes.length == 4) return _isPrivateIpv4(bytes[0], bytes[1]);
  if (bytes.length != 16) return true;

  // IPv4-mapped（::ffff:a.b.c.d）与 IPv4-compatible（::a.b.c.d，已废弃但解析器仍认）：
  // 内嵌的 IPv4 走同一个分类器，否则 `::ffff:127.0.0.1` 就是绕闸入口。
  if (bytes.take(10).every((value) => value == 0)) {
    if (bytes[10] == 0xff && bytes[11] == 0xff) {
      return _isPrivateIpv4(bytes[12], bytes[13]); // IPv4-mapped
    }
    if (bytes[10] == 0 && bytes[11] == 0) {
      if (bytes.every((value) => value == 0)) return true; // ::（未指定）
      if (bytes.take(15).every((value) => value == 0) && bytes[15] == 1) {
        return true; // ::1 回环
      }
      // IPv4-compatible ::a.b.c.d：老解析器仍会认，按内嵌 IPv4 判。
      return _isPrivateIpv4(bytes[12], bytes[13]);
    }
    // 前 10 字节为 0 但 10/11 既不是 0 也不是 ffff：非可路由形态，fail-closed。
    return true;
  }
  if ((bytes[0] & 0xfe) == 0xfc) return true; // fc00::/7 ULA（含 fd00::/8）
  if (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) return true; // fe80::/10 链路本地
  if (bytes[0] == 0xff) return true; // ff00::/8 组播
  // 2002::/16（6to4）在字节 2..5 里直接嵌了 IPv4，不检查就等于
  // `2002:7f00:0001::` = 127.0.0.1 的绕道。
  if (bytes[0] == 0x20 && bytes[1] == 0x02) {
    return _isPrivateIpv4(bytes[2], bytes[3]);
  }
  // 2001:0db8::/32 文档段、100::/64 Discard-only：不可路由，按内网拦。
  if (bytes[0] == 0x00 && bytes[1] == 0x01) return true; // ::/96 等过渡段残留
  if (bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8) {
    return true;
  }
  if (bytes[0] == 0x00 && bytes[1] == 0x64 && bytes[2] == 0xff && bytes[3] == 0x9b) {
    return true; // 64:ff9b::/96 NAT64 前缀：目的地址在尾 32 位，按内网拦更稳
  }
  return false;
}

/// IPv4 分类（a/b = 前两段）。0.0.0.0/8、10/8、127/8、169.254/16（含
/// 169.254.169.254 元数据）、172.16/12、192.168/16，另加 CGNAT 100.64/10、
/// 192.0.0/24、198.18/15 基准测试段、以及 ≥224 的组播/保留段。
bool _isPrivateIpv4(int a, int b) {
  if (a == 0) return true; // 0.0.0.0/8“本机”
  if (a == 10) return true;
  if (a == 127) return true;
  if (a == 169 && b == 254) return true; // 链路本地 + 云元数据
  if (a == 172 && b >= 16 && b <= 31) return true;
  if (a == 192 && b == 168) return true;
  if (a == 192 && b == 0) return true;
  if (a == 100 && b >= 64 && b <= 127) return true;
  if (a == 198 && (b == 18 || b == 19)) return true;
  if (a >= 224) return true;
  return false;
}

/// 纯函数：字面 IP 文本（IPv4/IPv6，可带方括号）是否内网地址。
/// 不是合法 IP 字面量 ⇒ 返回 false（调用方需再走 DNS 或 fail-closed 判断）。
bool isPrivateIpLiteralText(String host) {
  final address = InternetAddress.tryParse(bareHost(host));
  if (address == null) return false;
  return isPrivateIpBytes(address.rawAddress);
}

/// 同步语法 + 字面 IP 层判定。返回 `null` 表示这一层放行，否则为拒绝原因。
///
/// 注意：域名的判定**不在**这里 —— 需要 DNS，见 [ssrfRejectionReason]。
String? ssrfEndpointSyntaxRejection(Uri? uri) {
  if (uri == null) return 'URL 为空或无法解析';
  final scheme = uri.scheme.toLowerCase();
  if (scheme.isEmpty) return 'URL 缺少 scheme';
  if (scheme != 'https') return '仅允许 https，实际为 $scheme';
  final host = bareHost(uri.host);
  if (host.isEmpty) return 'URL 无主机名';
  if (uri.userInfo.isNotEmpty) return 'URL 不得内嵌凭据（userInfo）';
  if (uri.hasFragment) return 'URL 不得带 fragment';
  if (kSsrfBlockedMetadataHosts.contains(host)) return '主机名是元数据服务别名：$host';
  for (final suffix in kSsrfBlockedHostSuffixes) {
    if (host == suffix.substring(1) || host.endsWith(suffix)) {
      return '主机名属于内部域名：$host';
    }
  }
  final address = InternetAddress.tryParse(host);
  if (address != null) {
    // Dart 的 `InternetAddress.tryParse` 会把 `0177.0.0.1` 当成十进制 177，
    // 而 Android/Bionic 的 inet_aton 会按**八进制**解析成 127.0.0.1。这种
    // 「两种栈解析结果不同」的形态没法安全分类 ⇒ 直接拦（fail-closed）。
    if (_hasOctalAmbiguousOctet(host)) {
      return 'IPv4 主机含前导零段（八进制歧义），无法安全解析：$host';
    }
    if (isPrivateIpBytes(address.rawAddress)) {
      return '字面 IP 指向内网/元数据段：$host';
    }
    return null;
  }
  // 像 IP 但 Dart 解析不出来：底层栈可能仍能解析（inet_aton 风格）⇒ 按内网拦。
  if (isIpLikeHost(host)) return '主机形态为数字化 IP 但无法安全解析：$host';
  return null;
}

/// `1.2.3.4` 里某一段写成 `0177` / `0300` 这种前导零形态 ⇒ 八进制歧义。
bool _hasOctalAmbiguousOctet(String host) {
  if (host.contains(':')) return false; // IPv6 字面量没有八进制段
  final parts = host.split('.');
  if (parts.length != 4) return false;
  return parts.any((part) =>
      part.length > 1 && part.startsWith('0') && RegExp(r'^0[0-9]+$').hasMatch(part));
}

/// 完整判定（含 DNS）：返回 `null` 表示放行，否则为拒绝原因。
///
/// DNS 解析抛异常、或解析结果为空 ⇒ 一律拒绝（fail-closed）。
/// 任一解析到的地址是内网 ⇒ 拒绝（不允许「有公网就不拦」，否则 Happy Eyeballs
/// 会挑到那条 AAAA 记录）。
Future<String?> ssrfRejectionReason(Uri? uri, {SsrfIpLookup? lookup}) async {
  final syntax = ssrfEndpointSyntaxRejection(uri);
  if (syntax != null) return syntax;
  final host = bareHost(uri!.host);
  if (InternetAddress.tryParse(host) != null) return null; // 字面公网 IP，无需 DNS
  final resolver = lookup ?? defaultSsrfIpLookup;
  List<InternetAddress> resolved;
  try {
    resolved = await resolver(host);
  } catch (error) {
    return '主机 $host DNS 解析失败，按内网处理（fail-closed）：$error';
  }
  if (resolved.isEmpty) return '主机 $host 无 DNS 解析结果，按内网处理';
  for (final address in resolved) {
    if (isPrivateIpBytes(address.rawAddress)) {
      return '主机 $host 解析到内网地址 ${address.address}';
    }
  }
  return null;
}

/// [ssrfRejectionReason] 的布尔形态（true = 可安全发起请求）。
Future<bool> isSsrfSafeEndpointUri(Uri? uri, {SsrfIpLookup? lookup}) async =>
    await ssrfRejectionReason(uri, lookup: lookup) == null;
