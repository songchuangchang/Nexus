import 'package:flutter/material.dart';

/// build113（SB-1）：全工程 SnackBar 统一入口。
///
/// ScaffoldMessenger.showSnackBar 默认把连续触发**入队逐条连播**：
/// 短时间 N 次触发 → 排队弹 N 次、旧条滞留队列（用户所见「多次弹、还保留」）。
/// 这里先 clearSnackBars()（清掉当前与队列）再 show——
/// 同一时刻屏幕上只有最新一条，旧条不保留。
///
/// C4（build117）：在「不堆叠」之上补**同类去重**——同一文案在短时间窗口内
/// 重复触发时只显示一次（真机场景：批量操作/循环里同一个提示连续弹多次）。
/// 窗口取 [_dedupWindow]（3 秒）：足够吃掉连发重复，又不至于吞掉用户
/// 间隔一段后的再次主动操作反馈。
class AppSnackBar {
  AppSnackBar._();

  /// 同类消息去重窗口。
  static const Duration _dedupWindow = Duration(seconds: 3);

  /// 最近一次展示的文案 → 时刻（用于同类去重）。
  static final Map<String, DateTime> _recent = <String, DateTime>{};

  /// 接收现成 SnackBar（duration/behavior/action 由调用方自定，行为不变）。
  static void showSnackBar(BuildContext context, SnackBar snackBar) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    // C4：同类去重——取 SnackBar 的纯文本内容作为 key（非 Text 内容不做
    // 去重，避免误吞富内容提示）。命中窗口内的重复直接丢弃。
    final key = _textKeyOf(snackBar);
    if (key != null && _isDuplicate(key)) return;
    messenger
      ..clearSnackBars()
      ..showSnackBar(snackBar);
  }

  /// 快捷文本入口。
  static void show(BuildContext context, String text,
      {Duration duration = const Duration(seconds: 3),
      SnackBarAction? action}) {
    showSnackBar(
      context,
      SnackBar(content: Text(text), duration: duration, action: action),
    );
  }

  /// 提取 SnackBar 的文本 key；非 Text 内容返回 null（不参与去重）。
  static String? _textKeyOf(SnackBar snackBar) {
    final content = snackBar.content;
    if (content is Text) return content.data ?? content.textSpan?.toPlainText();
    return null;
  }

  /// 命中去重窗口返回 true（并刷新时刻，避免长尾连发反复触发）。
  static bool _isDuplicate(String key) {
    final now = DateTime.now();
    final last = _recent[key];
    if (last != null && now.difference(last) < _dedupWindow) {
      _recent[key] = now;
      return true;
    }
    _recent[key] = now;
    // 顺手清理过期项，防 Map 无界增长（弹窗文案种类有限，代价可忽略）
    if (_recent.length > 64) {
      _recent.removeWhere((_, t) => now.difference(t) > _dedupWindow);
    }
    return false;
  }

  /// 测试钩子：清空去重记录（静态状态跨用例隔离）。
  @visibleForTesting
  static void resetDedupForTest() => _recent.clear();

  /// 测试钩子：当前记录条数。
  @visibleForTesting
  static int get dedupEntryCountForTest => _recent.length;
}

/// build113（SB-3）：同类弹层防叠守卫——同一 key 的弹层已开则直接忽略
/// 本次触发，防快速连点叠多层；弹层关闭（含异常路径）由调用方在 finally 复位。
///
/// build128（死状态自愈）：若某次打开让 `await showAppSheet(...)` 永不返回
/// （路由始终没被 pop），`finally` 就永不执行，key 会**永久**留在表里 ——
/// 用户侧表现是「点了没反应」，且只能靠重启清掉（build127 已实测此现象）。
/// 两条依据说明残留可安全自愈：
///   1. 这类弹层的唯一入口（如 `chat_screen.dart:467` 的 GestureDetector）
///      都位于弹层**之下**，弹层可见时被模态遮罩挡住、点不到 ⇒ 能走到
///      「被拦」这一步，即已证明当前没有该 key 的弹层在场，登记必为残留；
///   2. 正常的一次开→关一定会在 finally 里 `exit`（3 秒内必完成），
///      故「超窗口仍被占用」本身就是异常信号。
/// ⇒ 超过 [_staleAfter] 仍被占用的登记按残留处理：释放并放行本次触发。
/// 取 3 秒是为了保住原始防连点语义（快速双击仍落在窗口内被吞掉）。
class GuardedOverlay {
  GuardedOverlay._();

  /// key → 登记时刻（原来只存 key 的 Set，无法判别残留，故升级为 Map）。
  static final Map<String, DateTime> _open = <String, DateTime>{};

  /// 超过该时长仍被占用 ⇒ 视为上一次未释放的残留。
  /// 正常弹层要么已关闭（finally 已 exit），要么仍在遮罩后（点不到入口）。
  static const Duration _staleAfter = Duration(seconds: 3);

  /// 已开且未过期返回 false（本次触发被吞）；否则登记并返回 true。
  ///
  /// [now] 仅供测试注入时钟，生产调用一律省略。
  static bool tryEnter(String key, {DateTime? now}) {
    final t = now ?? DateTime.now();
    final since = _open[key];
    if (since != null && t.difference(since) < _staleAfter) return false;
    _open[key] = t;
    return true;
  }

  /// 关闭时复位（务必放 finally）。
  static void exit(String key) => _open.remove(key);

  /// 测试钩子：登记时刻（未占用为 null）。
  @visibleForTesting
  static DateTime? openedAtForTest(String key) => _open[key];

  /// 测试钩子：清空全部登记。
  @visibleForTesting
  static void resetForTest() => _open.clear();
}
