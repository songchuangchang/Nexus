// build162（用户 16:45 那份真机日志）：把"掉线自动续写"从**掉线当时**挪到
// **回到前台那一刻**。这个类只做两件事：
//  ① 给一个"现在在不在前台"的真源（直接读 `WidgetsBinding.lifecycleState`，
//     不自己再记一份 bool —— 再记一份就有两份真源，`_reactLoopStopRequested`
//     那三个写入方两个时刻不同的教训见 chat_screen.dart:266 的注释）；
//  ② 把 `resumed` 那一下通知给挂着事的页面。
//
// build165（#87，用户 08:04 那份导出）：② 补了对称的那半条腿 —— `paused`/`hidden`
// 那一下也要有**唯一一个**通知点（[notifyBackgrounded]），因为"退到后台就把这条流
// 收起来"必须由页面自己做，而它同样不许自己 addObserver。类名沿用不改：
// 改名会把 162 那段注释与所有既有引用一起搅动，收益为零。
//
// 为什么不在页面里自己 `addObserver`：全仓的前后台事件已经由 `main.dart`
// 的 `_AIChatAppState.didChangeAppLifecycleState` 统一打点（日志里那些
// `Lifecycle: resumed` 就是它写的），再挂一个 observer 就有第二个真源、第二套
// 假 resumed 判据（生物锁那一族为"选图片就弹锁"吃过亏，见 main.dart:327）。
// 所以这里只做**被那唯一一处调用**的通知点，不是 observer。
import 'package:flutter/widgets.dart';

import 'logger_service.dart';

class AppResumeSignal {
  AppResumeSignal._();

  static final AppResumeSignal instance = AppResumeSignal._();

  final Map<String, void Function()> _handlers = {};

  /// build165 ①：另一张表，不是把上面那张复用一遍。
  ///
  /// 理由与 `inForeground` 那段的"不再自己记一份 bool"同一条：进出 App 是**两个方向**
  /// 的两件事，塞进同一个 handler 就得让每个消费方自己再判一次方向，
  /// 而判错一次方向的代价（回前台时去收流 / 退后台时去重发）都是真机上那族假话。
  /// 现有消费方（`chat_screen.dart` 的掉线续写）只关心回来的那一下，行为一字不改。
  final Map<String, void Function()> _backgroundedHandlers = {};

  /// 此刻 App 在前台吗（`resumed` 才算前台）。
  ///
  /// `inactive` 算**不在**前台：用户那份日志里切后台打的正是 `inactive`
  /// （16:40:30.952），而它后面紧跟的 `resumed` 才是能起流的时刻。
  /// 小窗/分屏/下拉面板也会报 `inactive`，那种情况下几百毫秒后就有 `resumed`，
  /// 挂起那一笔会立刻被兑现 —— 代价只是晚一点起，不是不起。
  bool get inForeground =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  /// 此刻是"人已经离开 App"吗（只认 `paused` / `hidden`，build165 ①）。
  ///
  /// 刻意**不**把 `inactive` 算进来：下拉通知栏、分屏、系统权限框都会报 inactive，
  /// 那种时候把在飞的连接收掉，等于把人正在看的那一屏挖掉一块 —— 而 `main.dart`
  /// 那条后台快照探针（build156）也是同一口径「只认 paused：hidden/inactive 在小窗/
  /// 分屏/系统面板都会来，会把探针基线洗脏」（`hidden` 在这里被算进来是因为它按
  /// Android 的定义就是"活动不可见"，收线是对的；洗基线是另一件事，那行代码没动）。
  bool get leavingApp =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.hidden;

  /// 按会话 id 注册（与 `ShareIntentService.registerInserter` 同一形状：
  /// 栈里可能压着多个 ChatScreen，同一个 id 后注册的顶掉前一个，页面
  /// dispose 时必须 [unregister]，否则回调指向已销毁的 State）。
  void register(String key, void Function() onResumed) {
    _handlers[key] = onResumed;
  }

  /// 注册"离开 App"那一下的通知（build165 ①）。与 [unregister] 成对，同一把键。
  void registerLeavingApp(String key, void Function() onLeft) {
    _backgroundedHandlers[key] = onLeft;
  }

  void unregister(String key) {
    _handlers.remove(key);
    _backgroundedHandlers.remove(key);
  }

  /// 只由 `main.dart` 那个既有的生命周期回调在 `paused`/`hidden` 分支调用。
  ///
  /// 每个处理器各自兜住异常（与 [notifyResumed] 同一条理由：这一层没有重试，
  /// 吞了就是永久的）。收流这件事尤其不能吞：漏掉一次就是回到"整条流在后台停摆"。
  void notifyBackgrounded() {
    if (_backgroundedHandlers.isEmpty) return;
    final logger = LoggerService.instance;
    logger.app('[Resume] 离开 App，通知 ${_backgroundedHandlers.length} 个在飞的轮次收流');
    for (final fn in _backgroundedHandlers.values.toList(growable: false)) {
      try {
        fn();
      } catch (e, st) {
        logger.error('App background handler failed',
            error: e, stack: st, tag: 'RESUME');
      }
    }
  }

  /// 只由 `main.dart` 那个既有的生命周期回调在 `resumed` 分支调用。
  ///
  /// 每个处理器各自兜住异常：挂着事的页面不止一个时，一个处理器的异常不许
  /// 把别人的续写一起吞掉（这一层没有任何重试，吞了就是永久的）。
  void notifyResumed() {
    if (_handlers.isEmpty) return;
    final logger = LoggerService.instance;
    logger.app('[Resume] 回到前台，通知 ${_handlers.length} 个挂起方');
    for (final fn in _handlers.values.toList(growable: false)) {
      try {
        fn();
      } catch (e, st) {
        logger.error('App resume handler failed',
            error: e, stack: st, tag: 'RESUME');
      }
    }
  }
}
