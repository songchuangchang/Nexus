import 'dart:async';
import '../models/api_config.dart';
import '../models/chat_message.dart';
import 'api_service.dart';

/// build101（E5 多模型对比）：同一问题并发发给多个模型，并排对比回答。
///
/// 与「重试版本」的差异：重试是**串行逐个**看同一模型的不同回答；
/// 对比是**并发**看不同模型的回答——用于选型（「哪个模型更适合我的场景」）。
///
/// 实现要点：
/// - 每个模型一条独立 stopScope，用户可单独中止
/// - 非流式（completeChat）：对比场景要的是最终结果，流式并排渲染复杂度高、
///   收益低（用户看的是「结论差异」而非「逐字生成」）
/// - 单个失败不影响其他：失败的模型返回 error 字段，UI 灰显
class ModelComparisonService {
  /// 并发对比。[configs] 建议 2~4 个（再多屏幕放不下、也很费钱）。
  static Future<List<ComparisonResult>> compare({
    required ApiService api,
    required List<ApiConfig> configs,
    required String question,
    required String systemPrompt,
    Duration timeout = const Duration(seconds: 120),
  }) async {
    final futures = configs.map((cfg) {
      return _askOne(
        api: api,
        cfg: cfg,
        question: question,
        systemPrompt: systemPrompt,
        timeout: timeout,
      );
    });
    return Future.wait(futures);
  }

  static Future<ComparisonResult> _askOne({
    required ApiService api,
    required ApiConfig cfg,
    required String question,
    required String systemPrompt,
    required Duration timeout,
  }) async {
    final sw = Stopwatch()..start();
    try {
      final messages = <ChatMessage>[
        if (systemPrompt.trim().isNotEmpty)
          ChatMessage.create(
            conversationId: 'compare',
            role: MessageRole.system,
            content: systemPrompt.trim(),
          ),
        ChatMessage.create(
          conversationId: 'compare',
          role: MessageRole.user,
          content: question,
        ),
      ];
      final answer = await api.completeChat(
        config: cfg,
        messages: messages,
        timeout: timeout,
        stopScope: 'compare_${cfg.id}',
      );
      sw.stop();
      return ComparisonResult(
        configId: cfg.id,
        configName: cfg.name,
        model: cfg.model,
        answer: answer.trim(),
        latencyMs: sw.elapsedMilliseconds,
        error: null,
      );
    } catch (e) {
      sw.stop();
      return ComparisonResult(
        configId: cfg.id,
        configName: cfg.name,
        model: cfg.model,
        answer: '',
        latencyMs: sw.elapsedMilliseconds,
        error: '$e',
      );
    }
  }
}

/// build101（E5）：单个模型的对比结果。
class ComparisonResult {
  final String configId;
  final String configName;
  final String model;
  final String answer;
  final int latencyMs;

  /// 非 null 表示该模型调用失败（其他列仍正常展示）
  final String? error;

  const ComparisonResult({
    required this.configId,
    required this.configName,
    required this.model,
    required this.answer,
    required this.latencyMs,
    this.error,
  });

  bool get ok => error == null && answer.isNotEmpty;

  /// 估算输出速度（字符/秒）——对比时「快慢」比「总耗时」更有意义
  double get charsPerSecond {
    if (latencyMs <= 0) return 0;
    return answer.length / (latencyMs / 1000);
  }
}
