/// build123：外部 App「分享到 Nexus」的载荷。
///
/// 为什么单独建模而不是直接用 Map：
/// 分享有两个形态（文本/网址 与 文件），它们的后续处理路径**完全不同**
/// （文本直接粘进输入框；文件必须先落本地 + 走附件解析），
/// 用一个带 kind 的密封模型能让「文件走了文本分支」这类错误在编译期暴露，
/// 而不是运行时才发现「粘了一串 content:// 字符串」。
enum SharedKind {
  /// 文本 / 网址 / 任意纯文字
  text,

  /// 文件（已在原生侧复制到应用私有目录，[filePath] 一定可读）
  file,
}

class SharedPayload {
  final SharedKind kind;

  /// 文本分享的正文（网址就是普通文本，不做任何包装）
  final String? text;

  /// 文件分享：**已复制到应用私有目录**的本地路径。
  /// 原始 `content://` URI 不落这里——URI 的读权限随 Intent 生命周期失效，
  /// 存 URI 会在「先插入输入框、过一会儿再点发送」时读到空文件。
  final String? filePath;

  final String? fileName;
  final String? mimeType;
  final int? sizeBytes;

  /// 多文件分享时的总数（>1 说明只取了第一个，UI 要如实告知）
  final int? extraCount;

  /// 原生侧失败回执（`copy_failed` / `too_large`…）。
  /// 非空表示这是一条「失败回执」——[filePath] 不可用，UI **必须如实告知用户**，
  /// 不能静默什么都不发生（「分享了但没反应」正是本项目反复出现的假完成形态）。
  final String? error;

  const SharedPayload({
    required this.kind,
    this.text,
    this.filePath,
    this.fileName,
    this.mimeType,
    this.sizeBytes,
    this.extraCount,
    this.error,
  });

  bool get isFile => kind == SharedKind.file;
  bool get isText => kind == SharedKind.text;
  bool get hasError => error != null && error!.isNotEmpty;

  /// 原生侧 MethodChannel 传过来的 Map → 模型。
  /// 无法识别的载荷返回 null（宁可什么都不做，也不要粘一段垃圾进输入框）。
  static SharedPayload? fromMap(Map<Object?, Object?>? m) {
    if (m == null) return null;
    final kind = m['kind']?.toString();
    final error = m['error']?.toString();
    if (kind == 'file') {
      final path = m['filePath']?.toString();
      if ((path == null || path.isEmpty) && (error == null || error.isEmpty)) {
        return null;
      }
      return SharedPayload(
        kind: SharedKind.file,
        filePath: (path == null || path.isEmpty) ? null : path,
        fileName: m['fileName']?.toString(),
        mimeType: m['mimeType']?.toString(),
        sizeBytes: int.tryParse('${m['sizeBytes']}'),
        extraCount: int.tryParse('${m['extraCount']}'),
        error: error,
      );
    }
    if (kind == 'text') {
      final text = m['text']?.toString();
      if (text == null || text.trim().isEmpty) return null;
      return SharedPayload(kind: SharedKind.text, text: text);
    }
    return null;
  }

  /// 诊断用的简短描述（**不打全文**：分享内容可能很长且含隐私）
  String describe() => isFile
      ? 'file(${fileName ?? '?'}, ${sizeBytes ?? -1}B${hasError ? ', err=$error' : ''})'
      : 'text(${text!.length} chars)';
}
