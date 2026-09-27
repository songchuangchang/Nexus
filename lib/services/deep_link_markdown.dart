/// build107（U5）：把 AI 答案里的地图深链（amapuri:// / androidamap:// / geo:）
/// 转成可点 Markdown 链接。
///
/// 背景：弱模型爱把深链写进反引号代码段（实机样本：amapuri://navi 被反引号
/// 包裹 → flutter_markdown 代码段没有点击目标 →「点了没反应」），裸 URI 也
/// 不会被自动 linkify。宿主侧统一兜底转成 [label](uri) 链接形态，配合
/// AndroidManifest <queries> 的 scheme 声明即可唤起高德/地图应用。
library;

import 'launch_uri_normalizer.dart';

/// B1（N-9）：生成 markdown 链接时先过唯一归一入口——原实现把匹配到的 URI
/// **原样**塞进 `[label](uri)`，中文 query（真机样本 `toName=朱村地铁站`）
/// 未编码，点击后 Android Intent 拉起失败。编码在此完成，链接文本保持原文。
String _encodedTarget(String uri) {
  final n = normalizeLaunchUri(uri);
  return n.uri?.toString() ?? uri;
}

/// 裸深链（不含反引号壳）。排除会被中文标点/闭合符粘住的尾随字符。
/// W3（补充单02）：补高德 https 导航域（uri.amap.com / m.amap.com）——
/// 历史只认自定义 scheme（amapuri://），模型给的标准 https 导航链不可点
/// （N-9 真机补证：「弹了跳转框但跳不动」证据链之一）。
final RegExp _bareDeepUriPattern = RegExp(
  r'(?<!\]\()((?:amapuri|androidamap)://[^\s`)\]}，。；！？、）】》"]+|'
  r'https?://(?:uri\.amap\.com|m\.amap\.com)/[^\s`)\]}，。；！？、）】》"]+|'
  r'geo:[^\s`)\]}，。；！？、）】》"]+)',
  caseSensitive: false,
);

/// 反引号代码段内含深链的整段（单行内）——连壳一起替换，壳里文字保留。
final RegExp _codeSpanDeepUriPattern = RegExp(
  r'`([^`\n]*?(?:amapuri|androidamap)://[^\s`)\]}，。；！？、）】》"]+|'
  r'[^`\n]*?https?://(?:uri\.amap\.com|m\.amap\.com)/[^\s`)\]}，。；！？、）】》"]+|'
  r'[^`\n]*?geo:[^\s`)\]}，。；！？、）】》"]+[^`\n]*?)`',
  caseSensitive: false,
);

String deepLinkLabel(String uri) {
  final u = uri.toLowerCase();
  if (u.startsWith('https://uri.amap.com') || u.startsWith('https://m.amap.com')) {
    return '🧭 高德导航（网页版）';
  }
  if (u.startsWith('amapuri://navi')) return '🧭 唤起高德导航';
  if (u.startsWith('amapuri://') || u.startsWith('androidamap://')) {
    return '🧭 打开高德地图';
  }
  return '📍 在地图应用中打开';
}

/// 纯函数：把文本中的地图深链转成 Markdown 链接；无深链时原样返回。
/// 代码围栏（```块）内的内容不转换（示例代码不该被改写）。
String linkifyDeepUris(String markdown) {
  if (markdown.isEmpty || !markdown.contains('://') && !markdown.contains('geo:')) {
    return markdown;
  }
  // ① 反引号代码段含深链：整壳替换，段内文字保留、深链转链接
  var text = markdown.replaceAllMapped(_codeSpanDeepUriPattern, (m) {
    final inner = m.group(1)!;
    return inner.replaceAllMapped(_bareDeepUriPattern, (mm) {
      final uri = mm.group(1)!;
      return '[${deepLinkLabel(uri)}](${_encodedTarget(uri)})';
    });
  });
  // ② 代码围栏外的裸深链：逐段转换（奇数段是围栏内容，跳过）
  final parts = text.split('```');
  for (var i = 0; i < parts.length; i += 2) {
    parts[i] = parts[i].replaceAllMapped(_bareDeepUriPattern, (m) {
      final uri = m.group(1)!;
      return '[${deepLinkLabel(uri)}](${_encodedTarget(uri)})';
    });
  }
  return parts.join('```');
}
