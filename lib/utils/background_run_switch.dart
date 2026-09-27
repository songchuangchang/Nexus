/// build167（机主 2026-09-26 16:03 那条建议 + 18:4x 那句「我开了后台，退出来又给我暂停」）：
/// 设置里那道**「愿意后台化」总闸**的持久化位，以及它管住的**唯一判据**。
///
/// ## 为什么要有这一道闸（取证见 `docs/BUGSCAN_build166_20260926.md` ③）
/// 165 的 B 片是"退到后台就由本端把这条流收起来"（`lib/utils/drop_continue.dart`
/// 的 [shouldAbortStreamOnLeaveApp] 那一条），当时的前提是"进程反正会被厂商冻结，
/// 等它断只会得到一句假『网络中断』"。机主已经按 165 那个指引去 ColorOS 给了后台放行 ——
/// 前提不成立了，而我们一边让他开后台、一边自己把线掐了。
/// 所以这件事从此挂在一道**他拨的开关**上：
///  · 关（默认）⇒ 与 166 逐字节同行为（收流 + 回前台重发 + 「已暂停」）；
///  · 开 ⇒ 不收流，并且**只有开过之后**才向系统问通知权限、才把进度投影到通知栏/灵动岛。
///
/// ## 两条硬边界（写在这里免得实现时又"把还没发生的说成已发生"）
///  · **这道闸不承诺能后台**：165 的结论是"能向系统申请的豁免集合是**空集**"，
///    放不放行由 ColorOS 决定。所以它管的只是**我们做不做那件事**（收流 / 问权限 / 投影），
///    页面文案也因此只许说"本应用不再收起这条连接"，不许说"后台不会中断"。
///  · **已经给过权限的设备不去撤销**（撤销不了，三方 App 没有这个 API）：总闸关掉时
///    只是不再主动用 —— 不请求、不投影，系统那边那份授权原样留着。
///
/// ## 为什么判据住在这里而不是各调用点自己写 `&&`
/// "总闸 && 那个既有的通知开关"这一格，冷启动要问、设置页两行都要问。
/// 写第二份就会漂成两种口径（教训 #62）：某一条路上总闸关着却照样问权限、或反过来。
library;

import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences 的键（**只在这里定义一次**，与 `kLiveNotificationsEnabled`
/// 那条"设置页与启动读同一把 key"的规矩同一条）。
const String kBackgroundRunAllowedKey = 'background_run_allowed';

/// 读总闸。**默认 false**：没拨过开关的用户走的是 166 的原路，一条路径都没变。
///
/// 读不到 / 抛错时调用方也应当按 `false` 处理（= 现状），不许在这里猜一个"他大概想要后台"。
Future<bool> loadBackgroundRunAllowed({SharedPreferences? prefs}) async {
  final p = prefs ?? await SharedPreferences.getInstance();
  return p.getBool(kBackgroundRunAllowedKey) ?? false;
}

/// 落盘总闸（用户亲手拨的那一下才调，任何自动逻辑都不许写这一位）。
Future<void> saveBackgroundRunAllowed(bool allowed,
    {SharedPreferences? prefs}) async {
  final p = prefs ?? await SharedPreferences.getInstance();
  await p.setBool(kBackgroundRunAllowedKey, allowed);
}

/// 通知栏 / 灵动岛这一路我们**肯不肯用**（唯一判据）。
///
/// 两个入参都是既有的东西，不新造标志：
///  · [backgroundRunAllowed]：本轮新增的总闸（[loadBackgroundRunAllowed]）；
///  · [notificationsSwitch]：build142 起就有的那把「后台进度通知」开关
///    （`kLiveNotificationsEnabled`，默认开）。
/// 返回值同时决定三件事，因此**只有这一处**判断：
///  ① 冷启动问不问系统要 `POST_NOTIFICATIONS`（总闸没开过就不问）；
///  ② 设置页那一行点不点得动（机主要的是"允许之后才能开启灵动岛和通知"）；
///  ③ 投影到通知栏/灵动岛（关掉时走既有的 `LiveTaskCenter.setUserEnabled(false)`，
///    撤投影但**不撤销系统授权**，也不动任务真源）。
bool mayUseLiveNotifications({
  required bool backgroundRunAllowed,
  required bool notificationsSwitch,
}) =>
    backgroundRunAllowed && notificationsSwitch;
