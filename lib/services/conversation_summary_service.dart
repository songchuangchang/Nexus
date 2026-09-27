// v1.7.34：跨对话记忆摘要生成服务
//
// 触发时机：任意对话保存新消息后，消息总数达到 kInterval 的整数倍且 memoryEnabled
// 打开时，后台异步调 completeChat 生成 ≤500 字摘要并写回 conversations.summary。
//
// 设计要点：
// 1. 失败静默，不打扰用户（不 notify、不弹窗）
// 2. 用低 temperature（0.2）+ reasoningEffort=low 保证稳定输出、少 token
// 3. 幂等：并发时用 _pending 集合去重
// 4. 不刷 updatedAt，避免污染对话列表排序（复用 storage.updateConversationSummary）

import '../models/chat_message.dart';
import '../models/conversation.dart';
import 'api_service.dart';
import 'logger_service.dart';
import 'storage_service.dart';

class ConversationSummaryService {
  ConversationSummaryService._internal();

  static final ConversationSummaryService instance =
      ConversationSummaryService._internal();

  final _logger = LoggerService.instance;
  final StorageService _storage = StorageService.instance;
  final ApiService _api = ApiService();

  /// 每 N 条消息触发一次摘要生成
  static const int kInterval = 5;

  /// 摘要最大字符数
  static const int kMaxChars = 500;

  /// 用于摘要的最大 token（比 kMaxChars 略宽，留余量）
  static const int kSummaryMaxTokens = 400;

  /// 每条消息在 transcript 里的最大字符数（避免过长）
  static const int kPerMsgMaxChars = 500;

  /// 用于摘要的最大消息条数
  static const int kMaxMsgsForSummary = 40;

  /// 并发去重：正在生成中的 conversationId 集合
  final Set<String> _pending = {};

  /// 生成摘要的 system prompt
  static const String _kSystemPromptZh =
      '你是对话摘要器。请把用户提供的多轮对话内容压缩成不超过 500 字的中文摘要，'
      '必须保留：1) 用户的核心意图或问题；2) 关键结论或事实；3) 涉及的具体工具/链接/文件；4) 未解决或悬而未决的部分。'
      '不要输出任何寒暄、前后缀或引号，直接输出摘要正文。不要使用 Markdown 标题或列表符号。';

  /// 对外入口：在消息保存后调用；内部按 kInterval 判断是否触发
  Future<void> maybeRegenerate({required String conversationId}) async {
    if (_pending.contains(conversationId)) return;

    final conv = await _storage.getConversation(conversationId);
    if (conv == null) return;
    if (!conv.memoryEnabled) return;

    final msgs = await _storage.getMessages(conversationId);
    if (msgs.isEmpty) return;
    if (msgs.length % kInterval != 0) return;

    _pending.add(conversationId);
    try {
      final summary = await _generate(conv, msgs);
      if (summary.isNotEmpty) {
        await _storage.updateConversationSummary(conversationId, summary);
        _logger.app('Summary regenerated for conversation '
            '${conversationId.substring(0, conversationId.length > 8 ? 8 : conversationId.length)} '
            '(msgs=${msgs.length}, chars=${summary.length})');
      }
    } catch (e) {
      // 静默失败，不打扰用户；仅记日志
      _logger.app('Summary generation failed for conversation: $e');
    } finally {
      _pending.remove(conversationId);
    }
  }

  /// 主动重生成（供用户手动触发或回归测试用）
  Future<String> regenerateNow({required String conversationId}) async {
    final conv = await _storage.getConversation(conversationId);
    if (conv == null) return '';
    final msgs = await _storage.getMessages(conversationId);
    if (msgs.isEmpty) return '';
    return _generate(conv, msgs);
  }

  /// 生成摘要核心逻辑
  Future<String> _generate(Conversation conv, List<ChatMessage> msgs) async {
    final cfg = await _storage.getApiConfig(conv.apiConfigId);
    if (cfg == null) return '';

    final transcript = _buildTranscript(msgs);
    if (transcript.isEmpty) return '';

    // 复制 config 并把 temperature / maxTokens 覆盖成摘要友好参数
    final summaryCfg = cfg.copyWith(
      temperature: 0.2,
      maxTokens: kSummaryMaxTokens,
    );

    final messages = [
      ChatMessage.create(
        conversationId: conv.id,
        role: MessageRole.system,
        content: _kSystemPromptZh,
      ),
      ChatMessage.create(
        conversationId: conv.id,
        role: MessageRole.user,
        content: '对话标题：${conv.title}\n\n对话内容：\n$transcript',
      ),
    ];

    final raw = await _api.completeChat(
      config: summaryCfg,
      messages: messages,
      reasoningEffort: 'low',
      timeout: const Duration(minutes: 2),
    );
    final cleaned = _cleanSummary(raw);
    return cleaned.length > kMaxChars
        ? cleaned.substring(0, kMaxChars)
        : cleaned;
  }

  /// 把消息列表拼成纯文本 transcript（每条 ≤kPerMsgMaxChars 字，总条数上限 kMaxMsgsForSummary）
  static String _buildTranscript(List<ChatMessage> msgs) {
    final buf = StringBuffer();
    final tail = msgs.length > kMaxMsgsForSummary
        ? msgs.sublist(msgs.length - kMaxMsgsForSummary)
        : msgs;
    for (final m in tail) {
      if (m.role == MessageRole.system) continue;
      final role = m.role == MessageRole.user ? '用户' : '助手';
      var text = m.content.trim();
      if (text.isEmpty) continue;
      if (text.length > kPerMsgMaxChars) {
        text = '${text.substring(0, kPerMsgMaxChars)}…';
      }
      buf.writeln('$role：$text');
    }
    return buf.toString().trim();
  }

  /// 清理 LLM 输出：去掉代码块、多余空行、可能的前后缀引号
  static String _cleanSummary(String raw) {
    var s = raw.trim();
    // 去掉 ``` 代码块围栏
    final fence = RegExp(r'```(?:\w+)?\s*([\s\S]*?)```');
    if (fence.hasMatch(s)) {
      s = fence.firstMatch(s)!.group(1)!.trim();
    }
    // 去掉首尾引号（中英文单双引号 + 中文引号）
    s = s.replaceFirst(RegExp(r'^[\s”“‘’"+]+'), '');
    s = s.replaceFirst(RegExp(r'[\s”“‘’"+]+$'), '');
    // 压缩多余空行
    s = s.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return s.trim();
  }
}
