// build176（内置浏览器 · 刀二的总闸形状，**只有这一层**）：
// 「AI 自主开网页 / 读页 / 点页 / 后退」这四个 ReAct 动作要不要注册，判据只住这一个文件。
//
// 用户 2026-09-28 定的口径（`docs/WEB_BROWSER_P0_接线清单_20260928.md` §四 + 研究文档 §八）：
//  ① **默认关**：设置里显式开启之后才注册工具。没拨过这一格的用户走今天的行为路径，
//     一个字节都不变（10-02 刀二落地后由 `filterAgentToolsByBrowserFlag` 在**交进 FC
//     请求之前**摘掉那四个 schema；插件本体照旧无条件在册——⑩ 按运行期注册表判，
//     摘在册＝跨表锁当场红，所以"关"体现在执行第一跳与名单，不体现在注册表）。
//  ② **平台闸要说得出"这台设备不支持"**：`pubspec.yaml:54` 的 `webview_flutter: 4.14.1`
//     的 `platforms` 只有 android/ios/macos（10-01 现读确认）⇒ Windows 上**不许**把这一格
//     显示成"可以开"，也不许把"不支持"塌成 `false` 的沉默：读出来的必须是**两件事**
//     ——用户拨的那一位（switchOn）与这台设备到底支不支持（support）。
//  ③ 判据只住一处（照 `StorageService.autoMemoryEnabled()` 那个形状，见
//     `test/build173_auto_memory_switch_test.dart` ③ 的口径：键名一个所有者、
//     `getBool(键)` 全仓一处读）。多处读早晚漂成"页面显示的与落库判的不是同一回事"。
//  ④ **不缓存**：每次读都回 prefs。"关回去立刻生效"靠的是这个——一旦进程内缓存一位，
//     用户在设置里关掉之后当前会话仍在注册工具，那一格就成了假闸。
//
// 与 `lib/utils/web_dom_serializer.dart` / `lib/utils/web_session_state.dart`（刀一）的关系：
// 那两个文件是**判据层**（拿到页面之后怎么序列化、接管状态机、域名闸），本文件是**入口层**
// （这条能力在**这台设备上、这个用户手里**开不开）。两层互不认识，刀二接线时按
// 「本文件说允许 → 注册 → 执行时再问刀一的闸」的顺序串起来。
//
// 本文件**不 import 任何 UI / 插件 / 解析层**（它是入口层，谁都能问它，它不问任何人）。
// 10-02 刀二落地后它的读取点恰好两处，由 `test/build176_browser_wiring_lock_test.dart`
// E 组钉着：**设置页那一格（拨）＋ `lib/plugins/web_browser_plugins.dart`（判）**。
// 第三处 import 就红——多一个所有者就多一份口径，早晚漂成"页面显示开着、注册处判的是关"。

import 'dart:io' show Platform;

import 'package:shared_preferences/shared_preferences.dart';

/// 总闸的持久化键名。**唯一所有者**（结构锁盯：全仓一次定义、一次读）。
const String kBrowserToolsEnabledKey = 'browser_tools_enabled';

/// 这一族能力的四个 ReAct 动作名——刀二注册时要进 ①–⑨ 那九张表，
/// 名单住这里一处（`test/build176_browser_wiring_lock_test.dart` 用它当跨表一致性的被查对象）。
const List<String> kBrowserWebActionNames = [
  'web_navigate',
  'web_read',
  'web_act',
  'web_back',
];

/// 平台支持度。**两个值都要能被 UI 读到**：`unsupportedPlatform` 不是 `false`，
/// 它是一张必须上屏的说明（"这台设备不支持"），把它塌成沉默就是白屏事故的前半段。
enum BrowserSupport { available, unsupportedPlatform }

/// `webview_flutter 4.14.1` 实际提供的平台（`pubspec.yaml:54`；判据层的唯一名单）。
const List<String> kBrowserSupportedOsNames = ['android', 'ios', 'macos'];

/// 纯判定：这个操作系统名到底跑不跑得了内置浏览器。
///
/// 参数是 `Platform.operatingSystem` 那串小写名（`windows`/`linux`/`macos`/…），
/// 由调用方交进来而不是在这里读 `Platform`——判据要能在任何宿主上测。
bool browserPlatformSupportedName(String osName) =>
    kBrowserSupportedOsNames.contains(osName.trim().toLowerCase());

/// 用户那一位的真值表：`关` 或 `平台不支持` 都不注册，只有「开着 **且** 跑得动」才注册。
///
/// 之所以收成函数而不是让调用方自己 `if (on && ok)`：两处手写就会漂成两种口径
/// （设置页显示"已开启"、注册处却按平台闸不注册 = 界面上没人能触发的那一类事故）。
bool browserToolsTakeEffect({required bool switchOn, required BrowserSupport support}) =>
    switchOn && support == BrowserSupport.available;

/// 一次读取的全部答案：用户拨的那一位 + 这台设备支不支持 + 由此派生的"要不要注册"。
class BrowserFeatureState {
  const BrowserFeatureState({
    required this.switchOn,
    required this.support,
    required this.osName,
  });

  /// 用户在设置里拨的那一位（缺省 = 关）。**注意**：这一位在 Windows 上也读得到 `true`——
  /// 他可能在 Android 上开过、或者被别的设备同步过来；它不代表这一族工具会注册。
  final bool switchOn;

  /// 这台设备的平台支持度（与用户那一位数无关）。
  final BrowserSupport support;

  /// 判定用的操作系统名（`Platform.operatingSystem` 形状）。
  final String osName;

  /// 唯一的生效判定：这一族工具该不该被注册。
  bool get toolsShouldRegister =>
      browserToolsTakeEffect(switchOn: switchOn, support: support);

  /// 平台不支持时给用户的**如实**说明（`support == available` 时返回 null，
  /// 而不是返回一句空串让调用方去猜"这是没有说明还是说明被吞了"）。
  String? unsupportedNotice({bool zh = true}) {
    if (support == BrowserSupport.available) return null;
    return zh
        ? '这台设备（$osName）不支持内置浏览器：webview_flutter 目前只提供 '
            'Android / iOS / macOS 三个平台。这一格在支持的设备上才有效，'
            '当前不会注册网页动作（${kBrowserWebActionNames.join(' / ')}），'
            'AI 也不会调用它们。'
        : 'This device ($osName) does not support the built-in browser: '
            'webview_flutter currently covers Android / iOS / macOS only. '
            'Web actions (${kBrowserWebActionNames.join(' / ')}) will not be '
            'registered here and the assistant will not call them.';
  }
}

/// 读操作系统名（测试用 [osOverride] 注入，别为了让 Windows 变绿去改源码）。
String browserOperatingSystemName({String? osOverride}) =>
    (osOverride ?? Platform.operatingSystem).trim().toLowerCase();

/// **唯一读取口**：这一族工具今天该不该注册。
///
/// 每次调用都回 prefs 现读（④：不缓存 ⇒ 关回去立刻生效）。
Future<BrowserFeatureState> browserFeatureState({
  SharedPreferences? prefs,
  String? osOverride,
}) async {
  final p = prefs ?? await SharedPreferences.getInstance();
  final os = browserOperatingSystemName(osOverride: osOverride);
  return BrowserFeatureState(
    // ① 默认关：prefs 里没有这一位 ⇒ false（没拨过开关的人走今天的路径）。
    switchOn: p.getBool(kBrowserToolsEnabledKey) ?? false,
    support: browserPlatformSupportedName(os)
        ? BrowserSupport.available
        : BrowserSupport.unsupportedPlatform,
    osName: os,
  );
}

/// 便捷谓词：等价于 `browserFeatureState(...).toolsShouldRegister`。
/// 注册点只准调这一个（判据只住一处；⑨ 那九张表的接线都从这里问一次）。
Future<bool> browserToolsRegistrationAllowed({
  SharedPreferences? prefs,
  String? osOverride,
}) async =>
    (await browserFeatureState(prefs: prefs, osOverride: osOverride)).toolsShouldRegister;

/// 落盘总闸（只有设置页那一行由用户亲手拨时才调）。
///
/// 平台不支持时**照落不误**：不许在这里偷偷写 `false`。用户在 Windows 上拨过什么，
/// 换到支持的设备上就该是什么——把落盘也接上平台闸会让"这台设备不支持"变成
/// "这台设备不许有偏好"，那是另一件事（而且下次开机读到的仍是默认，谁也说不清是谁改的）。
Future<void> setBrowserToolsEnabled(bool enabled, {SharedPreferences? prefs}) async {
  final p = prefs ?? await SharedPreferences.getInstance();
  await p.setBool(kBrowserToolsEnabledKey, enabled);
}
