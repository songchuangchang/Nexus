/// build101（E10 用量统计）：token 消耗聚合结果。
///
/// 数据源是 messages 表已落库的 token 列（v1.7.26 起持久化），
/// 因此**无需新增表**，历史对话自动纳入统计。
class UsageStat {
  /// 日期（yyyy-MM-dd）；按模型聚合或总计时为 ''
  final String day;

  /// 模型名；按天聚合或总计时为 ''
  final String model;

  final int msgCount;
  final int promptTokens;
  final int completionTokens;
  final int totalTokens;
  final int cacheReadTokens;
  final int cacheHitTokens;

  const UsageStat({
    required this.day,
    required this.model,
    this.msgCount = 0,
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.totalTokens = 0,
    this.cacheReadTokens = 0,
    this.cacheHitTokens = 0,
  });

  bool get isEmpty => msgCount == 0 && totalTokens == 0;

  /// 缓存命中率（0~1）；无数据返回 0。
  ///
  /// 口径：cacheHit / (cacheHit + cacheRead)。各厂商字段名不同，
  /// 这里做保守估算，仅在两个字段都有值时有意义。
  double get cacheHitRate {
    final denom = cacheHitTokens + cacheReadTokens;
    if (denom <= 0) return 0;
    return cacheHitTokens / denom;
  }

  /// 人类可读的 token 数（12.3K / 1.2M）
  static String fmtTokens(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(2)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return '$n';
  }
}
