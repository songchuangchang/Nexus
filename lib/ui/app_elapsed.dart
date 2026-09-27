// 流式计时器（build133 从 `lib/widgets/message_bubble_v2.dart` 迁入 lib/ui 并公开）。
//
// 为什么迁：它从 build101 起就只服务气泡头 / 思考块标题 / 思考节点三处，但
// build133 的四态组件（M4）与「已等待 Ns · 当前阶段」也要用它。留在消息气泡文件里
// 私有化，要么复制一份（真源分裂），要么让别的 UI 反向依赖一个巨型 widgets 文件。
//
// 迁出时**行为逐字保留**，`test/build132_timer_guard_test.dart` 的七条源码契约断言
// 只改「去哪读源码」，断言内容一条未减。
import 'dart:async';

import 'package:flutter/material.dart';

/// 锚点（本轮首步时间）距今超过该阈值即认为「这不是一个正在进行的思考」，
/// 退回静态文案。取值依据：本项目最长档（深度研究 80 轮）真机耗时也就十几分钟
/// 量级，30 分钟足够宽松；而陈旧锚点的荒谬值（小时级）必然被挡下。
///
/// build133：由私有 `_kLiveTimerMaxAge` 提为公开常量（组件迁出后，父层的
/// `liveFresh` 判定仍要用它）。**唯一真源** —— 不得在别处再写死 30 / 1800。
const Duration kLiveTimerMaxAge = Duration(minutes: 30);

/// build132（计时器审计）：锚点是否已超时——超过即**停表**（不再跳动）。
///
/// [now] 显式传入（而非内部取 `DateTime.now()`），单测可注入任意时刻。
/// 之所以提成顶层纯函数：build126 的「时效护栏」只能靠「常量存在」来断言，
/// 行为无法被测试覆盖 —— 这正是「思考过程 58225 秒」能在护栏之后继续存在的原因。
bool isLiveTimerStale({required DateTime startTs, required DateTime now}) =>
    now.difference(startTs) >= kLiveTimerMaxAge;

/// build132（计时器审计）：计时器文案的唯一实现（纯函数，可单测）。
///
/// 三条硬约束：
/// ① **有上界**：超过 [kLiveTimerMaxAge] 不再显示会无限增长的秒数，改用「> N 分钟」。
///    不用「已中断」——长跑（深度研究 32 次 MCP）也可能真的超过 30 分钟，断言「中断」
///    会撒谎；「> 30 分钟」在卡死与真长跑两种情况下都成立。
/// ② **不为负**：系统时钟回拨（NTP 校时 / 用户改时间）时差值可能为负 ⇒ 钳到 0。
/// ③ 0–10s 带一位小数（保留跳动感），≥10s 退化为整秒。
String formatLiveTimerLabel({
  required DateTime startTs,
  required DateTime now,
  required String prefix,
  required bool zh,
}) {
  final ms = now.difference(startTs).inMilliseconds;
  if (ms >= kLiveTimerMaxAge.inMilliseconds) {
    final m = kLiveTimerMaxAge.inMinutes;
    return zh ? '$prefix > $m 分钟' : '$prefix > ${m}m';
  }
  final s = (ms < 0 ? 0 : ms) / 1000.0;
  final str = s < 10 ? s.toStringAsFixed(1) : s.round().toString();
  return zh ? '$prefix $str 秒' : '$prefix ${str}s';
}

/// build101（D3）：流式计时器；build133 迁入 lib/ui 并公开为 `AppElapsed`。
///
/// [stage] 是 build133 新增的「当前阶段」文案（如「检索资料」），显示在秒数之后。
/// 它**不参与** [_label] 的比对：阶段由父层按事件更新（走 widget 更新 → 重建），
/// 若并入比对串，每 500ms 的 _tick 都会因为阶段相同而空转一次字符串拼接。
class AppElapsed extends StatefulWidget {
  final DateTime startTs;
  final bool zh;
  final String prefix;
  final TextStyle? style;

  /// 当前阶段文案（build133 · M4）；null / 空串时不显示。
  final String? stage;

  const AppElapsed({
    super.key,
    required this.startTs,
    required this.zh,
    this.prefix = 'Thinking',
    this.style,
    this.stage,
  });

  @override
  State<AppElapsed> createState() => AppElapsedState();
}

class AppElapsedState extends State<AppElapsed> {
  Timer? _timer;
  /// build129（性能）：已渲染文案。定时器**只在文案真的变了**才 setState ——
  /// 0–10s 段文案带一位小数、每拍都在变（保留跳动感）；≥10s 后文案退化为整秒，
  /// 2Hz 轮询里有一半是空转，靠这个比对自动降到 ~1Hz。
  /// 本组件在气泡头、思考块标题、**每个思考节点**三处都可能同时存活，
  /// 收益会按实例数叠加。
  String _label = '';

  /// build132（计时器审计）：已越过 [kLiveTimerMaxAge] 并**停表**。
  bool _frozen = false;

  @override
  void initState() {
    super.initState();
    _label = _format();
    // build132：挂载时锚点就已陈旧（isStreaming 卡住、锚点是几小时前的时间戳）
    // ⇒ 只显示有上界的文案，**根本不启动定时器**。
    // 父层的 liveFresh 只在 build 那一刻判一次，「先新后卡」的实例它管不到，
    // 兜底必须落在本组件内部——真机「思考过程 58225 秒」正是这条路径。
    if (_isStale) {
      _frozen = true;
      return;
    }
    _startTimer();
  }

  void _startTimer() {
    _timer ??=
        Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
  }

  /// 锚点距今是否已达上限。
  bool get _isStale =>
      isLiveTimerStale(startTs: widget.startTs, now: DateTime.now());

  void _tick() {
    if (!mounted || _frozen) return;
    final next = _format();
    if (next != _label) setState(() => _label = next);
    // build132：越界即停表。此后文案恒为「> N 分钟」，再跳下去只是每 500ms 空转。
    if (_isStale) {
      _timer?.cancel();
      _timer = null;
      _frozen = true;
    }
  }

  @override
  void didUpdateWidget(covariant AppElapsed oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 锚点/语言/前缀任一变化立刻按新参数重算，不必等下一拍
    if (oldWidget.startTs != widget.startTs ||
        oldWidget.zh != widget.zh ||
        oldWidget.prefix != widget.prefix) {
      _label = _format();
      // 锚点前移（新一轮 / 新节点）后重新变新鲜 → 复活定时器，
      // 否则一次陈旧会把该实例永久钉死成静态文案。
      if (_frozen && !_isStale) {
        _frozen = false;
        _startTimer();
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _format() => formatLiveTimerLabel(
        startTs: widget.startTs,
        now: DateTime.now(),
        prefix: widget.prefix,
        zh: widget.zh,
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stage = widget.stage;
    final text = (stage == null || stage.isEmpty) ? _label : '$_label · $stage';
    return Text(
      text,
      style: widget.style ??
          theme.textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurfaceVariant,
          ),
    );
  }
}
