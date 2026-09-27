import '../models/chat_message.dart';

/// B-005：全项目**唯一** token 估算口径（纯函数，可单测）。
///
/// 旧口径 `字符数 / 2.5` 对中文系统性低估约 40%~60%（中文约 1 字 = 1~1.5 token，
/// 不是 2.5 字符/token），连锁导致三处偏差：
/// 1) 输入栏用量条明显偏小；
/// 2) 自动压缩 isNearLimit(85%) 迟迟到不了 —— 「该压不压」；
/// 3) 真触发压缩时 historyBudget 裁剪目标偏小 —— 「压了没效果」。
///
/// 新口径按字符类别加权：
///   token ~= CJK 字符数 x 1.0 + 非 CJK 字符数 / 4.0
/// 纯中文约 1 字/token、纯英文约 4 字符/token，混合自动加权，比统一 /2.5 更接近
/// Qwen / DeepSeek / GPT 系实测值。
///
/// 口径说明：估算**只用于发送前预测**；有服务端返回的真实 prompt_tokens 时，
/// 面板/用量显示应以真实值为准（估算值仅作无 usage 时的兜底）。
class TokenEstimator {
  TokenEstimator._();

  /// B3（N-5）：CJK 区间补全——原实现漏韩文谚文与 CJK 扩展 B 及以后，
  /// 这类字符落进 `other` 按 ÷4 计，韩文/生僻汉字段落被系统性低估 4 倍
  /// （与旧口径 `字符数/2.5` 同型偏差，只是换了字符集）。
  static bool _isCjk(int r) {
    return (r >= 0x3040 && r <= 0x30FF) || // 平假名/片假名
        (r >= 0x3400 && r <= 0x4DBF) || // CJK 扩展 A
        (r >= 0x4E00 && r <= 0x9FFF) || // CJK 基本区
        (r >= 0xF900 && r <= 0xFAFF) || // CJK 兼容
        (r >= 0x3000 && r <= 0x303F) || // CJK 标点
        (r >= 0xFF00 && r <= 0xFFEF) || // 全角字符
        (r >= 0x1100 && r <= 0x11FF) || // 谚文字母（Jamo）
        (r >= 0x3130 && r <= 0x318F) || // 谚文兼容字母
        (r >= 0xAC00 && r <= 0xD7AF) || // 谚文音节（韩文主体）
        (r >= 0x20000 && r <= 0x2A6DF) || // CJK 扩展 B
        (r >= 0x2A700 && r <= 0x2EBEF) || // CJK 扩展 C~F
        (r >= 0x2F800 && r <= 0x2FA1F) || // CJK 兼容补充
        (r >= 0x30000 && r <= 0x3134F); // CJK 扩展 G
  }

  /// 纯文本估算（空串返回 0）
  static int text(String? value) {
    final s = value ?? '';
    if (s.isEmpty) return 0;
    var cjk = 0;
    var other = 0;
    for (final r in s.runes) {
      if (_isCjk(r)) {
        cjk++;
      } else {
        other++;
      }
    }
    final t = cjk * 1.0 + other / 4.0;
    return t <= 0 ? 0 : t.ceil();
  }

  /// 单条消息估算：正文 + 附件已抽取文本。
  ///
  /// text/doc 附件的 extractedText 会**真实进入请求体**（长文档可达数万字符），
  /// 旧实现只算 content.length 会漏掉这一大块，是长文档会话低估的主因。
  static int message(ChatMessage msg) {
    var total = text(msg.content);
    for (final a in msg.attachments) {
      final ex = a.extractedText;
      if (ex != null && ex.isNotEmpty) total += text(ex);
    }
    return total;
  }

  /// 多条消息合计
  static int messages(List<ChatMessage> list) =>
      list.fold(0, (sum, m) => sum + message(m));
}
