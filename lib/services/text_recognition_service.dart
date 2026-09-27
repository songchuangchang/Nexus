import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
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
