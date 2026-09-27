/// B1（N-9）：外链/深链唤起的**唯一归一入口**（纯函数，可单测）。
///
/// **为什么必须收口**（教训 #62 的同型问题）：全项目有多个「把 URL 交给系统
/// 唤起」的通道，各自处理程度不一——
/// - `LauncherUtils.openExternalUrl`：曾自写 percent-encode（W3 加的）；
/// - `interact_card._buildPay` 第三通道：裸 `Uri.tryParse` + `launchUrl`；
/// - `deep_link_markdown` 生成 markdown 链时：URI 原样塞进去；
/// - `message_bubble_v2._onTapLink`：走 LauncherUtils。
/// 每处各修一次就是打地鼠，故收敛到本函数，全部通道强制过它。
///
/// **编码口径（build117 实测修正，重要）**：
/// Dart 的 `Uri.parse` **本身就会**对非 ASCII 做 UTF-8 percent-encode，且
/// **保留** query 里的 `,`（坐标分隔符）。实测（`temp/b1_diag2.dart`）：
/// ```
/// Uri.parse('…?from=113.686787,23.291558,我的位置&toName=朱村地铁站')
///   .toString() == '…?from=113.686787,23.291558,%E6%88%91…&toName=%E6%9C%B1…'
/// ```
/// 因此本函数**不做二次编码**——二次编码会产出 `%25E6…`（双重编码，服务端解出
/// 乱码）。真正的历史 bug 恰恰相反：W3 的 `_percentEncodeNonAscii` 用
/// `Uri(queryParameters:)` 重建，把坐标逗号编码成 `%2C`（实测
/// `113.686787%2C23.291558`），高德侧解析不出坐标 →「弹了跳转框但跳不动」。
///
/// 归一 = 「解析校验 + 交给 Dart 自己的编码器产出可 launch 的规范形态」。
library;

/// 归一结果：可交给 launchUrl 的 URI + 是否发生过改写（供日志/断言）。
class NormalizedLaunchUri {
  final Uri? uri;

  /// 原始字符串与归一结果不一致（含非 ASCII 被编码、空格被编码等）。
  final bool wasRewritten;

  /// 无法解析（空串 / 无 scheme）时为 true，uri 为 null。
  final bool isInvalid;

  const NormalizedLaunchUri({
    required this.uri,
    required this.wasRewritten,
    required this.isInvalid,
  });
}

/// 归一入口：解析校验 → 产出 percent-encode 后的规范 URI。
///
/// - 无效（空串 / 无 scheme / 解析失败）→ `isInvalid = true`，`uri = null`；
/// - 已全 ASCII 且无需改写 → `wasRewritten = false`，原样返回（零行为变化）；
/// - 含非 ASCII / 空格等需编码内容 → 返回 `Uri.parse(raw)`（Dart 已编码），
///   `wasRewritten = true`。
///
/// **不做二次编码**：见文件头说明（`Uri.parse` 已编码；重复编码会双重转义）。
NormalizedLaunchUri normalizeLaunchUri(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    return const NormalizedLaunchUri(
        uri: null, wasRewritten: false, isInvalid: true);
  }
  final parsed = Uri.tryParse(trimmed);
  if (parsed == null || !parsed.hasScheme) {
    return const NormalizedLaunchUri(
        uri: null, wasRewritten: false, isInvalid: true);
  }
  // Dart 的 Uri.toString() 即规范编码形态（非 ASCII → UTF-8 percent-encode，
  // 空格 → %20，`,` 保留）。与原文比较即可知是否发生改写。
  final canonical = parsed.toString();
  return NormalizedLaunchUri(
    uri: parsed,
    wasRewritten: canonical != trimmed,
    isInvalid: false,
  );
}

/// 便捷入口：只要归一后的 Uri（无效返回 null）。
Uri? normalizeLaunchUriOrNull(String raw) => normalizeLaunchUri(raw).uri;
