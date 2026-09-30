// build174 / 《展望合卷》上篇·一第 1 项：热更载荷的**签名验证**（信任锚）—— 纯函数层。
//
// 结构锁（test/build174_pack_signature_test.dart 的 ⑦ 组钉死）：本文件里**不许**出现
// `dart:io` 或 `package:flutter/` 的 import。它只做「字节进、枚举出」：
// 不碰磁盘、不碰网络、不读 SharedPreferences、不起 isolate、不画界面。
// 规范字节由 `data_pack_protocol.dart` 供给（与既有 sha256 闸**同一份**规范化实现，
// 见那里的 `canonicalDataPackBytesForSignature`），本文件不认识 JSON 信封。
//
// 为什么要这一层（此前的实话）：四条远程载荷（api_templates / builtin_prompts /
// mcp_catalog / rules）唯一的完整性凭据是载荷**自己带的** `sha256` 字段。那是校验和
// 不是凭据——改内容的人顺手重算一遍摘要就过了。信任锚必须来自 APK 之内、
// 与载荷不可分离，所以这里是「编译进二进制的一把公钥 + 载荷里的 Ed25519 签名」。
//
// 为什么走纯 Dart（用户 2026-09-29 拍板的乙案）：甲案复用 APK 的 keystore，
// 会撞上桌面端那条平行实现、并且密钥轮换时**静默裂开**；纯 Dart 一把裸公钥
// 在 Android / 桌面 / 单测里是同一个形状，锚的字节可逐字核对。
//
// 失败口径：本文件**从不抛异常**。任何异常都归成 [PackSignatureStatus.invalid]——
// 验签层的「我不知道」不许冒泡成刷新链路的崩溃，更不许冒泡成"放行"。
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../constants.dart';

/// 一次验签的四种结局（拒因词表之间只隔 `data_pack_protocol.dart` 里那一处映射）。
enum PackSignatureStatus {
  /// 签名与规范字节、与内置信任锚都对得上。
  ok,

  /// 载荷里没有 `signature`（或值是空串 / 纯空白）。
  missing,

  /// 有字段，但根本不是 64 字节的十六进制——**没进到**密码学判定。
  malformed,

  /// 格式合法，密码学验签不过（内容被改过，或签名者不是那把私钥的主人）。
  invalid,
}

/// Ed25519 裸公钥长度（32 字节 = 64 位十六进制）。
const int _ed25519PublicKeyBytes = 32;

/// Ed25519 签名长度（64 字节 = 128 位十六进制）。
const int _ed25519SignatureBytes = 64;

/// **仅供单测**的锚位。优先级排在显式传参之后、内置常量之前：
/// `显式 anchorPublicKeyHex` ＞ 本字段 ＞ [kDataPackSignaturePublicKeyHex]。
///
/// 为什么不干脆删掉它（我一度这么打算，后来核过改口）：服务层有 20 条判据是走
/// `DataPackService.refreshPack/checkAll` 进来的，要把测试公钥送到那 4 个
/// `evaluateSignedDataPackPayload` 调用点，就得让**公开服务 API 多带一个锚参数**——
/// 那等于给生产调用方也开了一个"把锚换成我的钥匙"的口子，比原来的测试缝更坏。
/// 所以锚位留着，但收紧成三条：① 纯函数层优先用显式传参（CLI 与协议层判据都这么走，
/// 不留全局痕迹）；② 全局锚位只准测试碰，`lib/` 里零调用点由 ⑦ 组结构锁钉着；
/// ③ 用了它的每个测试文件必须在 `tearDown` 里清回去（同文件已有锁）。
String? _anchorOverrideHexForTest;

/// 解析后的锚字节；换锚时作废，解析不出来 ⇒ null ⇒ 一律 [PackSignatureStatus.invalid]。
Uint8List? _anchorBytes;

/// 换/清锚位（传 null 还原）。
void usePackSignatureAnchorForTest(String? publicKeyHex) {
  _anchorOverrideHexForTest = publicKeyHex;
  _anchorBytes = null; // 换锚必须作废缓存，否则测试之间会串
}

/// 三级取锚：显式传参 ＞ 测试锚位 ＞ 内置常量。任一级解析失败 ⇒ null ⇒ 一律不验过。
Uint8List? _resolveAnchor(String? explicitHex) {
  final hex = (explicitHex ?? _anchorOverrideHexForTest ?? kDataPackSignaturePublicKeyHex).trim();
  final cached = _anchorBytes;
  // 只有"走内置/测试锚位且没传参"时才能吃缓存，否则会把上一条用例的锚漏给这一条。
  if (explicitHex == null && cached != null) return cached;
  final parsed = _tryDecodeHex(hex);
  if (parsed == null || parsed.length != _ed25519PublicKeyBytes) return null;
  if (explicitHex == null) _anchorBytes = parsed;
  return parsed;
}

/// 唯一的对外入口：规范字节 + 载荷里那串 `signature` ⇒ 四态结论。
///
/// [signatureHex] 收**原文**（可以是 null / 空 / 任意字符串）：`missing` 与
/// `malformed` 的区别就在这个字符串的形状里，先剥成字节再传进来就分不出这两档了。
///
/// [anchorPublicKeyHex] 是**信任锚**。省略＝按上面那三级取（生产路径就是内置常量）。
/// 发版工具 `tools/sign_pack.dart` 与协议层判据一律**显式传**，这样它们不留任何全局状态。
Future<PackSignatureStatus> verifyPackSignature({
  required List<int> canonicalBytes,
  required String? signatureHex,
  String? anchorPublicKeyHex,
}) async {
  final raw = signatureHex?.trim() ?? '';
  if (raw.isEmpty) return PackSignatureStatus.missing;

  final signature = _tryDecodeHex(raw);
  if (signature == null || signature.length != _ed25519SignatureBytes) {
    return PackSignatureStatus.malformed;
  }
  final anchor = _resolveAnchor(anchorPublicKeyHex);
  if (anchor == null) {
    // 锚本身写坏了（半截十六进制 / 长度不对）⇒ 没有任何签名算「验过」。
    return PackSignatureStatus.invalid;
  }

  try {
    final ok = await Ed25519().verify(
      canonicalBytes,
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(anchor, type: KeyPairType.ed25519),
      ),
    );
    return ok ? PackSignatureStatus.ok : PackSignatureStatus.invalid;
  } catch (_) {
    return PackSignatureStatus.invalid;
  }
}

/// 严格十六进制解码：奇数长度 / 非 `[0-9a-fA-F]` ⇒ null。
///
/// 不用 `int.parse` 也不用 `Base64`/`codeUnits` 那类宽容路径：`malformed` 这一档
/// 的全部意义就是「只有这一种写法算合法」，宽容一分就多一分可乘之机。
Uint8List? _tryDecodeHex(String raw) {
  if (raw.isEmpty || raw.length.isOdd) return null;
  final out = Uint8List(raw.length ~/ 2);
  for (var i = 0; i + 1 < raw.length; i += 2) {
    final hi = _hexNibble(raw.codeUnitAt(i));
    final lo = _hexNibble(raw.codeUnitAt(i + 1));
    if (hi < 0 || lo < 0) return null;
    out[i ~/ 2] = (hi << 4) | lo;
  }
  return out;
}

int _hexNibble(int codeUnit) {
  if (codeUnit >= 0x30 && codeUnit <= 0x39) return codeUnit - 0x30; // '0'-'9'
  if (codeUnit >= 0x61 && codeUnit <= 0x66) return codeUnit - 0x57; // 'a'-'f'
  if (codeUnit >= 0x41 && codeUnit <= 0x46) return codeUnit - 0x37; // 'A'-'F'
  return -1;
}
