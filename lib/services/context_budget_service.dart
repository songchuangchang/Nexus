import '../models/api_config.dart';
import '../models/chat_message.dart';
import 'api_service.dart';
import 'token_estimator.dart';
import '../models/context_compaction_segment.dart';
import '../models/conversation.dart';
import 'logger_service.dart';

/// 上游**没被我们指定**输出上限时，按多大额度给回答留地方（build168 · #99）。
///
/// 口径来源：DeepSeek 官方文档（`api-docs.deepseek.com`，2026-09-26 取）写的是
/// 不传 `max_tokens` 时默认 **8K（非思考档）/ 64K（思考档）**。这里取 8K 那一档：
/// 思考档的 64K 不可能拿来当预留（1M 窗口也要吃掉 6% 历史），而且**我们读不到**
/// 上游这一轮到底进没进思考档 —— 宁可少留，也不要凭猜把历史挤空。
/// 留少了的后果是可观测的（超窗会被上游拒、轮次画像里有数），留多了的后果是
/// 静默少带历史 —— 后者更难查，所以不取大值。
const int kUpstreamDefaultOutputReserve = 8192;

/// 本轮该为"回答"预留多少 token。**发不发上限的判据只在 `requestMaxTokens` 那一处**，
/// 这里复用它的返回值：我们真发了 ⇒ 预留就等于发出去的那个数；没发 ⇒ 按上游默认档留。
int outputReserveFor(ApiConfig config) =>
    requestMaxTokens(configured: config.maxTokens) ?? kUpstreamDefaultOutputReserve;

/// 上下文占用进入「接近上限」档的阈值（占用率口径，0.85）。
///
/// **只定义一次**：自动压缩判定（[ContextBudgetSelection.isNearLimit]，按
/// token 比较 `estimatedTokens >= budget * 阈值`）与界面分档
/// （[contextUsageLevel]，按 ratio 比较）必须是同一个数 —— 此前顶栏用量条与
/// 容量面板各自写了一遍 `0.85`，谁只改一处，同一条数据就会在两处显示成
/// 不同的颜色与文案。
const double kContextNearLimitRatio = 0.85;

/// 上下文占用的**显示**分档：只服务配色与文案，不参与任何截断/压缩决策。
enum ContextUsageLevel {
  /// 正常（< 阈值）：主色，无提示文案。
  normal,

  /// 接近上限（≥ [kContextNearLimitRatio]）：错误色 + 文案提示。
  nearLimit,

  /// 已达或超出预算：错误色 + 文案提示。
  atLimit,
}

/// 占用率 → 显示分档。
///
/// 抽成纯函数是为了让边界**可断言**（0.849 / 0.85 / 1.0 三处），
/// 而不是把阈值散在 build 方法里只能靠肉眼比对。
ContextUsageLevel contextUsageLevel(double ratio) {
  if (ratio >= 1.0) return ContextUsageLevel.atLimit;
  if (ratio >= kContextNearLimitRatio) return ContextUsageLevel.nearLimit;
  return ContextUsageLevel.normal;
}

class ContextBudgetComponents {
  final int searchTokens;
  final int memoryTokens;
  final int attachmentTokens;
  final int ocrTokens;
  final int imageTokens;
  final int toolCallTokens;
  final int selfCheckTokens;
  final int workspaceTokens;
  final int temporaryMessageTokens;
  final int additionalTokens;

  const ContextBudgetComponents({
    this.searchTokens = 0,
    this.memoryTokens = 0,
    this.attachmentTokens = 0,
    this.ocrTokens = 0,
    this.imageTokens = 0,
    this.toolCallTokens = 0,
    this.selfCheckTokens = 0,
    this.workspaceTokens = 0,
    this.temporaryMessageTokens = 0,
    this.additionalTokens = 0,
  });

  int get totalTokens =>
      searchTokens +
      memoryTokens +
      attachmentTokens +
      ocrTokens +
      imageTokens +
      toolCallTokens +
      selfCheckTokens +
      workspaceTokens +
      temporaryMessageTokens +
      additionalTokens;
}

class ContextBudgetSelection {
  final List<ChatMessage> messages;
  final int estimatedTokens;
  final int budgetTokens;
  final int reservedTokens;

  const ContextBudgetSelection({
    required this.messages,
    required this.estimatedTokens,
    required this.budgetTokens,
    required this.reservedTokens,
  });

  bool get isNearLimit =>
      estimatedTokens >= (budgetTokens * kContextNearLimitRatio).round();
}

class ContextBudgetService {
  static const defaultContextTokens = 200000;
  static const maxContextTokens = 1000000;

  /// build132：历史保底预算比例。
  ///
  /// 背景（真机「AI 不记得上下文/看不到之前的文件」）：固定成本 =
  /// stablePrefix（ReAct 协议 + 插件目录/骨架 + 记忆）+ 压缩摘要 + 本条消息
  /// + 输出预留 maxTokens + 各项预留组件。任何一项变大都会挤占历史，
  /// 一旦 `budget - fixedCost <= 0`，下面的选史循环对**每条消息**都会走
  /// `continue`（`selectedHistory` 恒为空 ⇒ 连 break 条件都不成立），
  /// **整段历史被静默丢弃**：无日志、无提示，预算面板还显示「未超限」。
  /// 保底后宁可略微超名义预算（有 isNearLimit → 自动压缩兜底），
  /// 也不允许历史变成 0 条。
  static const double kMinHistoryBudgetRatio = 0.25;

  static List<ChatMessage> selectCompactionSource({
    required String conversationId,
    required List<ChatMessage> messages,
    required List<ContextCompactionSegment> segments,
    int? targetTokens,
  }) {
    final normalizedSegments = _normalizeSegments(
      conversationId: conversationId,
      messages: messages,
      segments: segments,
    );
    final covered = _coveredMessageIds(messages, normalizedSegments);
    final candidateTokens = messages
        .where((message) => !covered.contains(message.id))
        .fold<int>(0,
            (sum, message) => sum + ApiServiceTokenEstimate.message(message));
    final target = targetTokens ?? (candidateTokens / 2).ceil();
    if (target <= 0) return const [];

    final source = <ChatMessage>[];
    var used = 0;
    for (final message in messages) {
      if (covered.contains(message.id)) {
        if (source.isNotEmpty) break;
        continue;
      }
      source.add(message);
      used += ApiServiceTokenEstimate.message(message);
      if (source.length >= 2 && used >= target) break;
    }
    return source.length >= 2 ? source : const [];
  }

  /// N12：压缩源里可能混入未落库的注入消息（ReAct 循环的 toolresult/自检，
  /// 由 ChatMessage.create 临时生成、从不写库）。若段边界落在这类 id 上，
  /// 重新加载会话后 _normalizeSegments 找不到边界 → 整段摘要被静默丢弃，
  /// 表现为"压缩过但下次对话又爆长"。这里把 source 裁剪到已落库消息，
  /// 边界保证是持久化 id。
  static List<ChatMessage> clampCompactionSourceToPersisted(
      List<ChatMessage> source, Set<String> persistedIds) {
    final filtered =
        source.where((m) => persistedIds.contains(m.id)).toList();
    return filtered.length >= 2 ? filtered : const [];
  }

  static ContextBudgetSelection select({
    required Conversation conversation,
    required ApiConfig config,
    required List<ChatMessage> messages,
    required List<ContextCompactionSegment> segments,
    required ChatMessage currentMessage,
    List<ChatMessage> stablePrefix = const [],
    ContextBudgetComponents components = const ContextBudgetComponents(),
  }) {
    final budget = conversation.largeContextMax
        ? maxContextTokens
        : (config.contextWindowTokens ?? defaultContextTokens);
    // build168（#99）：预留量以前直接吃 `config.maxTokens`，那是"我们一定会发这个上限"
    // 时代的口径。build167 起配置 ≤ [kLegacyUnsetMaxTokens] 时**不再传 max_tokens**、
    // 交回上游默认（DeepSeek 官方：非思考 8K / 思考 64K）⇒ 继续按 2048 预留，
    // 缺口就从 2048 拉大到 6144：预算以为本轮最多再写 2048 字，于是按更满的历史投喂，
    // 模型真写长了先撞的是**整包超窗**（上游 400 / 历史被挤），不是我们那句截断提示。
    // 判据只此一处，且复用 `requestMaxTokens` —— 不在这里重写"发不发"那条线。
    final reserved =
        outputReserveFor(config) + components.totalTokens;
    final normalizedSegments = _normalizeSegments(
      conversationId: conversation.id,
      messages: messages,
      segments: segments,
    );
    final covered = _coveredMessageIds(messages, normalizedSegments);
    final summaries = normalizedSegments.map((segment) {
      return ChatMessage(
        id: 'context-summary:${conversation.id}:${segment.startMessageId}:${segment.endMessageId}',
        conversationId: conversation.id,
        role: MessageRole.system,
        content: '[Context summary]\n${segment.summary}',
        createdAt: segment.createdAt,
      );
    }).toList();

    final selectedHistory = <ChatMessage>[];
    final currentCost = ApiServiceTokenEstimate.message(currentMessage);
    final fixedCost =
        _estimate(stablePrefix) + _estimate(summaries) + currentCost + reserved;
    // build132：历史保底——原实现 `(budget - fixedCost).clamp(0, budget)`，
    // 归零即整段历史消失（详见 kMinHistoryBudgetRatio 注释）。
    final rawHistoryBudget = (budget - fixedCost).clamp(0, budget);
    final historyFloor = (budget * kMinHistoryBudgetRatio).round();
    final historyBudget =
        rawHistoryBudget < historyFloor ? historyFloor : rawHistoryBudget;
    var historyUsed = 0;
    for (final message in messages.reversed) {
      if (covered.contains(message.id)) continue;
      final cost = ApiServiceTokenEstimate.message(message);
      if (historyUsed + cost > historyBudget && selectedHistory.isNotEmpty) {
        break;
      }
      if (historyUsed + cost > historyBudget) continue;
      selectedHistory.add(message);
      historyUsed += cost;
    }

    // build138（乙·方案①）：conversation.contextLimit / contextAuto 此前是
    // **死字段**——全库除了 toMap/fromMap、CREATE TABLE、自检清单里的字符串名，
    // 没有任何读取点（这是本项目第 6 次踩「看起来已经接好了」那一族）。
    // 现在接到唯一选史口径里，与上面的 token 预算**取交集**：
    // 手动档（contextAuto=false）⇒ 条数上限先生效，超出的老消息同样不进上下文；
    // 自动档（默认 true）⇒ 完全不看条数，线上行为零变化。
    final countCap = conversation.contextAuto
        ? 0
        : (conversation.contextLimit < 1 ? 1 : conversation.contextLimit);
    var countTrimmed = 0;
    if (countCap > 0 && selectedHistory.length > countCap) {
      // selectedHistory 是按「从最新往老」的顺序收集的，砍掉尾部＝留下最近 N 条。
      countTrimmed = selectedHistory.length - countCap;
      selectedHistory.removeRange(countCap, selectedHistory.length);
    }

    // build132：可观测性——此前这条链路**完全无日志**，真机导出里看不到
    // 「历史被丢了」，只能靠用户描述猜。现在每次选史都留一行（CHAT 分类）。
    LoggerService.instance.chat(
      '[Ctx] budget=$budget fixed=$fixedCost historyBudget=$historyBudget'
      '${rawHistoryBudget < historyFloor ? '(保底生效, raw=$rawHistoryBudget)' : ''} '
      '${countCap > 0 ? '条数上限=$countCap(丢$countTrimmed) ' : ''}'
      'history=${selectedHistory.length}/${messages.length} '
      'summaries=${summaries.length} prefix=${stablePrefix.length}',
    );

    final result = <ChatMessage>[
      ...stablePrefix,
      ...summaries,
      ...selectedHistory.reversed,
      currentMessage,
    ];
    return ContextBudgetSelection(
      messages: result,
      estimatedTokens: _estimate(result) + reserved,
      budgetTokens: budget,
      reservedTokens: reserved,
    );
  }

  static List<ContextCompactionSegment> _normalizeSegments({
    required String conversationId,
    required List<ChatMessage> messages,
    required List<ContextCompactionSegment> segments,
  }) {
    final intervals = <_SegmentInterval>[];
    for (final segment in segments) {
      if (segment.conversationId != conversationId) continue;
      final start = messages.indexWhere((m) => m.id == segment.startMessageId);
      final end = messages.indexWhere((m) => m.id == segment.endMessageId);
      if (start < 0 || end < start) continue;
      intervals.add(_SegmentInterval(start, end, segment));
    }
    intervals.sort((a, b) {
      final startOrder = a.start.compareTo(b.start);
      if (startOrder != 0) return startOrder;
      return a.end.compareTo(b.end);
    });

    final normalized = <ContextCompactionSegment>[];
    for (final interval in intervals) {
      if (normalized.isEmpty) {
        normalized.add(interval.segment);
        continue;
      }
      final previous = normalized.last;
      final previousStart =
          messages.indexWhere((m) => m.id == previous.startMessageId);
      final previousEnd =
          messages.indexWhere((m) => m.id == previous.endMessageId);
      if (interval.start > previousEnd + 1) {
        normalized.add(interval.segment);
        continue;
      }
      if (interval.end <= previousEnd) continue;
      normalized[normalized.length - 1] = ContextCompactionSegment(
        id: previous.id,
        conversationId: conversationId,
        summary: '${previous.summary}\n${interval.segment.summary}',
        startMessageId: messages[previousStart].id,
        endMessageId: messages[interval.end].id,
        sourceTokenEstimate:
            previous.sourceTokenEstimate + interval.segment.sourceTokenEstimate,
        createdAt: previous.createdAt,
      );
    }
    return normalized;
  }

  static Set<String> _coveredMessageIds(
    List<ChatMessage> messages,
    List<ContextCompactionSegment> segments,
  ) {
    final covered = <String>{};
    for (final segment in segments) {
      final start = messages.indexWhere((m) => m.id == segment.startMessageId);
      final end = messages.indexWhere((m) => m.id == segment.endMessageId);
      for (var i = start; i <= end; i++) {
        covered.add(messages[i].id);
      }
    }
    return covered;
  }

  static int _estimate(List<ChatMessage> messages) => messages.fold(
      0, (sum, message) => sum + ApiServiceTokenEstimate.message(message));
}

class _SegmentInterval {
  final int start;
  final int end;
  final ContextCompactionSegment segment;

  const _SegmentInterval(this.start, this.end, this.segment);
}

/// B-005：保留旧类名做兼容壳，实现委托全项目唯一口径 TokenEstimator。
///
/// 历史原因该类被 UI 层（用量条 / 容量面板 / 分项估算）与压缩决策
/// （selectCompactionSource / historyBudget / isNearLimit）同时使用，
/// 两处口径必须一致，故统一收敛到 TokenEstimator。
class ApiServiceTokenEstimate {
  static int message(ChatMessage message) => TokenEstimator.message(message);

  static int text(String value) => TokenEstimator.text(value);
}
