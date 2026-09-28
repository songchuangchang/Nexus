import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import '../models/chat_message.dart';
import 'logger_service.dart';
import 'platform_capabilities.dart';
import 'package:flutter/foundation.dart';

class TextRecognitionResult {
  final String fileName;
  final String text;
  final int charCount;
  final int durationMs;
  final bool success;
  final String? errorKind;

  const TextRecognitionResult({
    required this.fileName,
    required this.text,
    required this.charCount,
    required this.durationMs,
    required this.success,
    this.errorKind,
  });

  bool get isUsable => success && text.trim().isNotEmpty;
}

/// 本机 OCR 封装。
///
/// 业务侧只关心“图片路径 -> 可注入上下文的文本”。实际识别使用 Google ML Kit
/// Text Recognition 的 Flutter 插件层；日志只记录文件名、字符数、耗时和错误类别。
class TextRecognitionService {
  static const int maxOcrChars = 12000;

  /// O2-4 口径的「识图不可用」实话（build172 起单一来源）：
  /// 引擎失败 ≠ 识别到 0 字——失败时必须明确告知模型"你看不到这张图"，
  /// 不得塞「[未识别到文字]」伪装成识别过了只是没字（会让模型误以为已读图
  /// 而反复反问）。errorKind 带错误码供真机定位（CJK 模型未下载 / 无 GMS /
  /// release R8 混淆缺 keep，三种根因全靠它区分）。
  static String unusableNotice(String? errorKind) =>
      '[本机图片识别不可用（${errorKind ?? '-'}）——你看不到这张图片的内容，'
      '请如实告知用户，并建议切换支持视觉的模型或由用户手动描述图片文字]';

  /// build172（照片读取修复）：对图片附件做**入口 OCR**——识别结果写进
  /// `extractedText`（字段是 final，构造新附件对象原位替换）。
  ///
  /// 为什么在入口做：三条发送路径（编排 / ReAct / 直聊）此前只有直聊有 OCR
  /// 兜底，编排路径的图片永远是占位文本（真机 18:44 带图编排实测）。
  /// 在分流之前跑一次，编排器既有的「extractedText 非空即正文」分支、
  /// 直聊/ReAct 的 payload 构造就都能拿到图内文字。
  ///
  /// 口径：
  ///  - 只处理 `type == image` 且有 `localPath` 的附件；非图片原样保留；
  ///  - `extractedText` 已有正文（重试/续跑）的**跳过**，不重复识别；
  ///  - 引擎失败（errorKind 非空）→ extractedText 写 [unusableNotice] 实话，
  ///    **不伪造正文**；识别成功但 0 字 → 写「[未识别到文字]」；
  ///  - 返回**是否发生了引擎级失败**（上游据此给用户 SnackBar 提示）。
  ///
  /// [recognize] 可注入（测试用假实现，不碰 ML Kit 平台通道）。
  static Future<bool> ensureImagesOcrd(
    List<MessageAttachment> attachments, {
    Future<TextRecognitionResult> Function(String path)? recognize,
  }) async {
    final impl =
        recognize ?? (path) => TextRecognitionService().recognizeImagePath(path);
    var engineFailed = false;
    for (var i = 0; i < attachments.length; i++) {
      final a = attachments[i];
      if (a.type != AttachmentType.image || a.localPath == null) continue;
      if ((a.extractedText ?? '').trim().isNotEmpty) continue;
      final r = await impl(a.localPath!);
      if (!r.isUsable && r.errorKind != null) engineFailed = true;
      attachments[i] = MessageAttachment(
        id: a.id,
        type: a.type,
        fileName: a.fileName,
        extractedText: r.isUsable
            ? r.text
            : (r.errorKind != null ? unusableNotice(r.errorKind) : '[未识别到文字]'),
        localPath: a.localPath,
        mimeType: a.mimeType,
        sizeBytes: a.sizeBytes,
      );
    }
    return engineFailed;
  }

  Future<TextRecognitionResult> recognizeImagePath(String imagePath) async {
    final fileName = p.basename(imagePath);
    final start = DateTime.now();
    // 桌面闸门（M2）：ML Kit 文字识别只有 android/ios 实现，Windows/Linux 上
    // 调下去只会吃 MissingPluginException。在能力边界提前返回明确的
    // 'unsupported_platform'，上游 errorKind!=null 的既有提示路径直接生效。
    if (!PlatformCapabilities.supportsOnDeviceOcr) {
      LoggerService.instance.warn(
        'OCR skipped: platform=${PlatformCapabilities.os} 无 ML Kit 实现, '
        'file=${_safeLogName(fileName)}',
        tag: 'OCR',
      );
      return _result(fileName, '', start, 'unsupported_platform');
    }
    TextRecognizer? recognizer;
    try {
      final file = File(imagePath);
      if (!await file.exists()) {
        return _result(fileName, '图片文件不存在', start, 'missing');
      }
      recognizer = TextRecognizer(script: TextRecognitionScript.chinese);
      final input = InputImage.fromFile(file);
      final recognized = await recognizer.processImage(input);
      final text = _sanitize(recognized.text);
      return _result(fileName, text, start, null,
          success: text.trim().isNotEmpty);
    } catch (e) {
      // O2-1（build95）：完整记录 PlatformException 的 code/message/details——
      // 原实现只打 e.runtimeType，把真正的错误码丢了，真机无法定位
      //（CJK 模型未下载 / 无 GMS / release R8 混淆缺 keep，三种根因全靠 code 区分）。
      final String errKind;
      final String errDesc;
      if (e is PlatformException) {
        errKind = 'PlatformException(${e.code})';
        errDesc =
            'PlatformException(code=${e.code}, message=${e.message}, details=${e.details})';
      } else {
        errKind = e.runtimeType.toString();
        errDesc = '${e.runtimeType}: $e';
      }
      LoggerService.instance.warn(
        'OCR failed: file=${_safeLogName(fileName)}, error=$errDesc',
        tag: 'OCR',
      );
      // O2-4（build95）：引擎失败 ≠ 识别到 0 字——text 留空（不再塞
      // 「[未识别到文字]」伪装占位），errorKind 带错误码，由上游区分
      // 「识图不可用」与「识别成功但没字」两种状态。
      return _result(fileName, '', start, errKind);
    } finally {
      if (recognizer != null) {
        try {
          await recognizer.close();
        } catch (e) {
          // 资源释放失败不影响 OCR 结果返回。
          debugPrint('catch 静默异常: $e');
        }
      }
    }
  }

  TextRecognitionResult _result(
    String fileName,
    String text,
    DateTime start,
    String? errorKind, {
    bool success = false,
  }) {
    final sanitized = _sanitize(text);
    return TextRecognitionResult(
      fileName: fileName,
      text: sanitized,
      charCount: sanitized.trim().length,
      durationMs: DateTime.now().difference(start).inMilliseconds,
      success: success,
      errorKind: errorKind,
    );
  }

  String _sanitize(String text) {
    final trimmed = text.trim();
    if (trimmed.length <= maxOcrChars) return trimmed;
    return '${trimmed.substring(0, maxOcrChars)}\n…[OCR 内容过长，已截断]';
  }

  String _safeLogName(String name) {
    final base = p.basename(name);
    return base.replaceAll(RegExp(r'[^\w\-. ()\[\]]'), '_');
  }
}
