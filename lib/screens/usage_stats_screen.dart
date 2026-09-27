import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../models/usage_stat.dart';
import '../services/storage_service.dart';
import '../ui/app_async_view.dart';
import '../ui/app_skeleton.dart';
import '../ui/app_state_view.dart';
import '../ui/tokens.dart';

/// build101（E10 用量统计）：token 消耗看板。
///
/// 三个维度：
/// - 总览：全时段累计（消息数 / 总 token / 缓存命中率）
/// - 按模型：哪个模型最贵（全时段聚合）
/// - 按天：最近 N 天的消耗趋势（带简易柱状图）
///
/// **不硬编码价格**：各厂商定价变动频繁且区分缓存价/输出价，写死必然过期。
/// 这里只展示 token 量，让用户拿自己的账单单价去乘。
///
/// build134（用量视觉重做）：整页迁到 M4 版式组件——四态外壳 [AppAsyncView] +
/// 骨架 [AppSkeleton] + 空态 [AppEmptyView] + 分组卡片 [AppSectionCard]，
/// 间距/圆角一律取令牌。数值格式统一 [UsageStat.fmtTokens]（与顶栏用量条同源）。
class UsageStatsScreen extends StatefulWidget {
  const UsageStatsScreen({super.key});

  @override
  State<UsageStatsScreen> createState() => _UsageStatsScreenState();
}

class _UsageStatsScreenState extends State<UsageStatsScreen> {
  bool _loading = true;

  /// 非空即失败；交给 [AppAsyncView] 渲染失败态（带重试）。
  Object? _error;

  UsageStat _total = const UsageStat(day: '', model: '');
  List<UsageStat> _byDay = const [];
  List<UsageStat> _byModel = const [];
  int _days = 30;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 读库并刷新。
  ///
  /// 原实现没有 try/catch：`queryUsage*` 一旦抛异常就永远走不到
  /// `_loading = false`，用户看到的是**永久转圈**——既没有失败提示也没有出路。
  /// 现在把异常落到界面上，并由失败态提供「重试」。
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final storage = context.read<StorageService>();
      final total = await storage.queryUsageTotal();
      final byDay = await storage.queryUsageStats(days: _days);
      final byModel = await storage.queryUsageByModel();
      if (!mounted) return;
      setState(() {
        _total = total;
        _byDay = byDay;
        _byModel = byModel;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  /// 把「按天×模型」压成「按天」（同一天多模型求和），并补齐空缺日期。
  List<({String day, int total, int prompt, int completion})> _dailySeries() {
    final map = <String, ({int t, int p, int c})>{};
    for (final s in _byDay) {
      final cur = map[s.day] ?? (t: 0, p: 0, c: 0);
      map[s.day] = (
        t: cur.t + s.totalTokens,
        p: cur.p + s.promptTokens,
        c: cur.c + s.completionTokens,
      );
    }
    final out = <({String day, int total, int prompt, int completion})>[];
    final today = DateTime.now();
    for (var i = _days - 1; i >= 0; i--) {
      final d = today.subtract(Duration(days: i));
      final key =
          '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      final v = map[key];
      out.add((
        day: key,
        total: v?.t ?? 0,
        prompt: v?.p ?? 0,
        completion: v?.c ?? 0,
      ));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final zh = l.locale.languageCode == 'zh';
    return Scaffold(
      appBar: AppBar(
        title: Text(zh ? '用量统计' : 'Usage Statistics'),
        actions: [
          PopupMenuButton<int>(
            tooltip: zh ? '时间范围' : 'Range',
            initialValue: _days,
            onSelected: (v) {
              setState(() => _days = v);
              _load();
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 7, child: Text(zh ? '最近 7 天' : 'Last 7 days')),
              PopupMenuItem(
                  value: 30, child: Text(zh ? '最近 30 天' : 'Last 30 days')),
              PopupMenuItem(
                  value: 90, child: Text(zh ? '最近 90 天' : 'Last 90 days')),
            ],
          ),
        ],
      ),
      // 四态外壳：加载 / 失败 / 空 / 数据一次接好。
      // minDisplay 取**整页**档（AppDur.minLoading）：快读时不让骨架闪一下就走。
      body: AppAsyncView(
        loading: _loading,
        error: _error,
        onRetry: _load,
        zh: zh,
        minDisplay: AppDur.minLoading,
        errorTitle: zh ? '用量数据读取失败' : 'Failed to read usage data',
        loadingChild: const Padding(
          padding: EdgeInsets.all(AppGap.md),
          child: AppSkeleton.card(count: 3),
        ),
        child: _total.isEmpty
            ? _empty(zh)
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  // AppSectionCard 自带卡片间距（高亮 bottom margin），
                  // 调用方不再逐张补 SizedBox —— 少一处「有人补有人忘」。
                  padding: const EdgeInsets.all(AppGap.md),
                  children: [
                    _overviewCard(zh),
                    _dailyChart(zh),
                    _modelBreakdown(zh),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _empty(bool zh) {
    // 空态必须有出路：这里给「刷新」，用户从别处聊完回来不用退出重进。
    return AppEmptyView(
      icon: Icons.insights_outlined,
      title: zh ? '还没有用量数据' : 'No usage data yet',
      subtitle: zh
          ? '与 AI 对话后，这里会按天、按模型统计 token 消耗。'
          : 'After you chat, token usage per day and per model shows up here.',
      action: TextButton.icon(
        onPressed: _load,
        icon: const Icon(Icons.refresh, size: 16),
        label: Text(zh ? '刷新' : 'Refresh'),
      ),
    );
  }

  Widget _overviewCard(bool zh) {
    final cs = Theme.of(context).colorScheme;
    return AppSectionCard(
      title: zh ? '全部时间' : 'All time',
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppGap.md, vertical: AppGap.xs),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _metric(
                    zh ? '总 Token' : 'Total tokens',
                    UsageStat.fmtTokens(_total.totalTokens),
                    cs.primary,
                  ),
                  _metric(
                    zh ? '输入' : 'Prompt',
                    UsageStat.fmtTokens(_total.promptTokens),
                    cs.onSurface,
                  ),
                  _metric(
                    zh ? '输出' : 'Completion',
                    UsageStat.fmtTokens(_total.completionTokens),
                    cs.onSurface,
                  ),
                ],
              ),
              const Divider(height: AppGap.xl),
              Row(
                children: [
                  _metric(
                    zh ? 'AI 回复数' : 'Replies',
                    '${_total.msgCount}',
                    cs.onSurface,
                  ),
                  _metric(
                    zh ? '缓存命中率' : 'Cache hit',
                    _total.cacheHitRate > 0
                        ? '${(_total.cacheHitRate * 100).toStringAsFixed(0)}%'
                        : '—',
                    cs.onSurface,
                  ),
                  _metric(
                    zh ? '缓存读取' : 'Cache read',
                    UsageStat.fmtTokens(_total.cacheReadTokens),
                    cs.onSurface,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _metric(String label, String value, Color color) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.appTextSub)),
          const SizedBox(height: AppGap.xs),
          Text(value,
              style: theme.textTheme.titleMedium
                  ?.copyWith(color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  /// 简易柱状图：用 Row + 按比例高度的 Container 手绘。
  /// 不引图表库——7~90 根柱子的需求用 30 行代码就够，且能精确控制主题色。
  Widget _dailyChart(bool zh) {
    final theme = Theme.of(context);
    final series = _dailySeries();
    final maxVal = series.fold<int>(0, (m, s) => s.total > m ? s.total : m);
    final cs = theme.colorScheme;
    final peakDay = series.isEmpty
        ? null
        : series.reduce((a, b) => a.total >= b.total ? a : b);

    return AppSectionCard(
      title: zh ? '每日消耗' : 'Daily usage',
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppGap.md, vertical: AppGap.xs),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (peakDay != null && peakDay.total > 0)
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    zh
                        ? '峰值 ${UsageStat.fmtTokens(peakDay.total)}'
                        : 'Peak ${UsageStat.fmtTokens(peakDay.total)}',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: cs.appTextSub),
                  ),
                ),
              const SizedBox(height: AppGap.sm),
              if (maxVal == 0)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppGap.lg),
                  child: Center(
                    child: Text(
                      zh ? '所选区间内没有用量' : 'No usage in this range',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: cs.appTextSub),
                    ),
                  ),
                )
              else
                SizedBox(
                  height: 120,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (final s in series)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 0.5),
                            child: Tooltip(
                              message:
                                  '${s.day}\n${UsageStat.fmtTokens(s.total)} tokens',
                              child: Container(
                                height: maxVal == 0
                                    ? 0
                                    : (s.total / maxVal * 116).clamp(0, 116),
                                decoration: BoxDecoration(
                                  color: s.total == 0
                                      ? cs.surfaceContainerHighest
                                      : cs.primary.withValues(alpha: 0.75),
                                  // R3：圆角取令牌（原先写死的 2 不在允许集内）。
                                  borderRadius: const BorderRadius.vertical(
                                      top: Radius.circular(AppRadius.inline)),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: AppGap.xs),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    series.isEmpty ? '' : series.first.day.substring(5),
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: cs.appTextFaint),
                  ),
                  Text(
                    series.isEmpty ? '' : series.last.day.substring(5),
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: cs.appTextFaint),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _modelBreakdown(bool zh) {
    if (_byModel.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final maxVal =
        _byModel.fold<int>(0, (m, s) => s.totalTokens > m ? s.totalTokens : m);
    return AppSectionCard(
      title: zh ? '按模型' : 'By model',
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppGap.md, vertical: AppGap.xs),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final m in _byModel) ...[
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        m.model,
                        style: theme.textTheme.bodyMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: AppGap.sm),
                    Text(
                      '${UsageStat.fmtTokens(m.totalTokens)} · ${m.msgCount}',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: cs.appTextSub),
                    ),
                  ],
                ),
                const SizedBox(height: AppGap.xs),
                ClipRRect(
                  // R3：原先写死 3，不在允许集内。
                  borderRadius: BorderRadius.circular(AppRadius.inline),
                  child: LinearProgressIndicator(
                    value: maxVal == 0 ? 0 : m.totalTokens / maxVal,
                    minHeight: 6,
                    backgroundColor: cs.surfaceContainerHighest,
                  ),
                ),
                const SizedBox(height: AppGap.md),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
