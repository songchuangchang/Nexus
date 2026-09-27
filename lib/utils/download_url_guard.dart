// build133（③）：下载类 URL 的纵深防御。
//
// 背景：图片/视频生成结果的下载 URL 直接来自受控上游 API，实际不可控的输入只有
// 上游返回体。但 `http.get(Uri.parse(url))` 对非常规 scheme 的行为由底层 client
// 决定（`file://` 抛 UnsupportedError、无 scheme 可能被当成相对地址解析），
// 一旦上游被篡改或被配置成恶意端点，就等于留下一个"按服务端指示读取本地文件"的口子。
// 这里只做白名单校验，不改变正常路径（http/https）的行为。
//
// 纯函数、无 IO ⇒ 可单测。

/// 允许下载的 scheme 白名单（小写比较）。
const Set<String> kAllowedDownloadSchemes = {'http', 'https'};

/// 是否为可安全下载的 http(s) URL。
///
/// 拒绝：null / 空串 / 无 scheme（相对地址）/ 非白名单 scheme（`file`、`data`、
/// `content`、`ftp` 等）/ `Uri.tryParse` 解析失败。
bool isSafeDownloadUrl(String? raw) {
  if (raw == null) return false;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return false;
  final uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.hasScheme) return false;
  return kAllowedDownloadSchemes.contains(uri.scheme.toLowerCase());
}
