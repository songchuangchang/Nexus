/// build163：聊天里那张**附件卡片**「能不能点、点开给什么」的唯一判据。
///
/// 为什么单独成文件（与 [html_preview] 同一个理由）：
///  · 真 WebView / 真看图器在 flutter_test 里都渲染不出来，判据层是这次唯一能对
///    「哪些类型给了点击」做**行为断言**的地方；
///  · 判据只准有一处：卡片画在哪（`message_bubble_v2.dart`）与"能不能点"各写一遍，
///    早晚变成"卡片上有『预览』字样、点下去没有内容"或反之（本仓教训 #62 同族）。
///
/// 为什么这些函数交回的是**内容/路径**而不是 bool：
///  调用点拿到 `null` 就必须不画点击，拿到非 null 就直接喂给预览页 ——
///  「判它可点」与「给它可点的载荷」因此不可能是两套口径（假入口就是这么长出来的）。
///
/// 依赖说明：本文件不含 widget、不吃 BuildContext，但**不是**零 Flutter 依赖 ——
/// 它要 import 既有分派表所在的那个文件才能拿到 `attachmentErrorPrefix`（跨文件契约，
/// 见它的定义处），抄一份字面量就是第二真源。
library;

import '../models/chat_message.dart';
import '../services/attachment_service.dart' show AttachmentService;
import 'html_preview.dart';

/// 点附件卡片后的去向。
enum AttachmentTap {
  /// 不可点（**默认值**，不是"未知就当成能点"的兜底档）
  none,

  /// 走 build162 的 App 内 HTML 预览页（`html_preview_screen.dart`）
  htmlPreview,

  /// 走本仓既有的内置全屏看图（`message_bubble_v2.dart::_openGeneratedFile`）
  viewImage,
}

/// 分派表：判据全部住在两个取值函数里，这里只做优先顺序。
AttachmentTap attachmentTapFor(MessageAttachment a) {
  if (attachmentHtmlBody(a) != null) return AttachmentTap.htmlPreview;
  if (attachmentImagePath(a) != null) return AttachmentTap.viewImage;
  return AttachmentTap.none;
}

/// 交回可以直接喂给预览页的 HTML 正文；**拿不到内容 / 类型不对**返回 null。
///
/// 后缀判据复用 [isHtmlPreviewFile]（build162 为「工作区/附件分派」写的那一个），
/// 不在这里重抄一份 `.html/.htm` 名单。
String? attachmentHtmlBody(MessageAttachment a) {
  if (!isHtmlPreviewFile(a.fileName)) return null;
  final text = a.extractedText;
  if (text == null || text.trim().isEmpty) return null;
  // 解析器把**拒绝原因**也塞在 extractedText 里（`_errorAttachment`：超 50 MB、
  // 非法 UTF-8…）。那种"正文"是一句错误说明，喂进 WebView 只会得到一张写着错误的页，
  // 与"这条附件根本没有内容"等价 ⇒ 不给点击。口径同知识库导入与 ws_read 那两处。
  if (text.startsWith(AttachmentService.attachmentErrorPrefix)) return null;
  // 不再套 `extractHtmlDocument` 那道"整条就是文档"的闸：那是给**助手消息正文**用的
  // （混排说明不该长出预览按钮）。附件是一份货真价实的 .html 文件，后缀就是判据，
  // 与文件管理页那一支分派同一口径。
  // 代价如实说明：被 `_capText` 截断过的长文件，尾巴上那句
  // 「…[内容超过 30000 字符，已截断]」会跟着正文一起渲染 —— 那是**提示不是装饰**，
  // 用户看得见"这页不完整"，比悄悄少一截好（本仓静默降级按缺陷处理）。
  return text;
}

/// 交回可以直接交给内置看图器的图片本地路径；没有路径返回 null。
///
/// 为什么只有图片这一族有路径：`AttachmentService._processImage` 会把图复制进
/// app docs 目录并写 `localPath`；文本/文档那两族（`_processTextFile`/`_processPdf`
/// /`_processDocx`/…）**只写 extractedText、从不写 localPath** ——
/// 于是"打开原文件"这条路对它们根本不存在（选文件那一步之后原路径就不再留存，
/// 分享进来的也是复制体）。拿不到路径的附件不许做成可点。
String? attachmentImagePath(MessageAttachment a) {
  if (a.type != AttachmentType.image) return null;
  final p = a.localPath;
  return (p == null || p.isEmpty) ? null : p;
}
