/// build165（任务 #88）：设置页那一行「后台被系统限制怎么办」的**判据层**（纯函数）。
///
/// 为什么单独成文件、为什么写成纯函数（与 [html_preview] / `attachment_tap.dart` /
/// `agent_artifact_cards.dart` 同一个理由）：
///  · 这一行的全部判据都发生在真机上（ColorOS 的后台管控只有装机才看得见），
///    flutter_test 里既没有 Activity 也没有 Settings 页面 ⇒ 判据层是唯一能对
///    「要不要出现、写什么字、点了去哪个 action、失败说什么」做**行为断言**的地方；
///  · 判据只准住一处：设置页"画不画"与"点了去哪"各写一遍，早晚漂移成
///    「页面上写着去 A 页、按钮把用户送到 B 页」（教训 #62 同族）。
///
/// 为什么要做这一行（docs/BUGSCAN_build164_20260925.md ⑬ 的取证结论）：
///  机主的 App 在 OPPO / ColorOS（Android 16、targetSdk 36）上「一进后台这轮回答就停摆」。
///  AOSP 那三层已经用官方原文排除（Doze 要「未接电源 + 静止 + 灭屏」一段时间；带前台服务时
///  网络是 No restrictions；cached-apps freezer 只 stop cached 进程），端点变量也已排除
///  （官方端点与中转站同一种失败形状）⇒ 剩下的是**厂商后台管控**，
///  而厂商侧**没有任何面向三方 App 的可申请免冻结 API** —— 唯一的钥匙是用户自己在
///  系统设置里拨的那个开关（ColorOS：设置 → 应用 → 本应用 → 允许后台活动）。
///  我们能为他做的只有「把他送到那个页面」，且**绝不谎报他拨没拨**。
///
/// 诚实条款（这一条是本次交付的红线，`test/build165_bg_guide_test.dart` 里钉着探针）：
///  那个开关的**状态读不到**（三方 App 没有 API），所以这一行交回的每一个字符串里
///  都不许出现"已开启 / 未开启 / 正常"这类断言状态的措辞 —— 只许说"读不到，请自己确认"。
///  同理**不假装能认出 ColorOS**：拿不到可靠的品牌/ROM 判据（本仓没有读 Build.MANUFACTURER
///  到这一层的通道，而就算读了，ROM 也能被刷），所以对所有 Android 用户交回同一句中性文案。
library;

/// 原生通道的方法名（Dart 与 Kotlin 引同一个字符串，只在这里定义一次）。
const String kBgGuideMethod = 'openSystemSettingsPage';

/// 日志 tag（可 grep）。这一行是下一次真机取证的读数：
/// 「他到底进过那个页面没有」只能靠我们自己留痕，系统不会告诉我们。
const String kBgGuideLogTag = 'BgGuide';

/// 跳转目标①：本应用的应用信息页（ColorOS 的「允许后台活动」就在这里那一屏）。
const String kBgGuideTargetAppDetails = 'app_details';

/// 跳转目标②：AOSP 的「忽略电池优化」列表页（Android 6+）。
/// 与①**不是一回事**：①管的是厂商后台冻结，②管的是 Doze 那一层，
/// 混成一个 action 就会出现「用户按说明找了半天、那个开关其实在另一页」。
const String kBgGuideTargetBatteryOpt = 'ignore_battery_optimizations';

/// 原生侧确认「startActivity 已经出去」的状态字。
/// 之所以回一个状态字而不是 bool：通道异常时 Dart 会收到 null，
/// 而 null 绝不能被读成"成功"（本仓口径：静默降级按缺陷处理）。
const String kBgGuideStatusOpened = 'opened';

/// 这一行要不要出现 + 出现时页面上的每一个字符串 + 点了去哪个目标。
class BgGuideRow {
  const BgGuideRow({
    required this.visible,
    required this.title,
    required this.body,
    required this.honestNote,
    required this.pathHint,
    required this.primaryLabel,
    required this.primaryTarget,
    required this.secondaryLabel,
    required this.secondaryTarget,
    required this.secondaryNote,
  });

  final bool visible;
  final String title;

  /// 「为什么要给你这一行」——含"部分厂商系统（如 ColorOS）"那句中性描述。
  final String body;

  /// 诚实条款那一句：读不到开关状态，请自己确认。
  final String honestNote;

  /// 手路径提示（他不点按钮也能自己去）。
  final String pathHint;

  final String primaryLabel;

  /// [kBgGuideTargetAppDetails]
  final String primaryTarget;

  final String secondaryLabel;

  /// [kBgGuideTargetBatteryOpt]
  final String secondaryTarget;

  /// 第二个按钮旁边的说明：为什么这是**另一个**页面。
  final String secondaryNote;

  /// 不显示时用的那一行（所有字符串为空 ⇒ 渲染层拿不到任何可画的东西，
  /// 也就不会出现在非 Android 平台上）。
  static const BgGuideRow hidden = BgGuideRow(
    visible: false,
    title: '',
    body: '',
    honestNote: '',
    pathHint: '',
    primaryLabel: '',
    primaryTarget: '',
    secondaryLabel: '',
    secondaryTarget: '',
    secondaryNote: '',
  );

  /// 页面上会出现的全部字符串（诚实探针逐个查，新加字段别忘了登记进来）。
  List<String> get displayedTexts => [
        title,
        body,
        honestNote,
        pathHint,
        primaryLabel,
        secondaryLabel,
        secondaryNote,
      ];
}

/// 判据：这一行要不要出现、写什么、点了去哪。
///
/// 为什么收 `isAndroid` 而不是自己读平台：判据要吃 BuildContext 或 `dart:io` 就没法
/// 脱开真机做行为断言（本仓这三个纯判据文件的共同打法）。调用点算好再传进来。
BgGuideRow bgGuideRow({required bool isAndroid, required bool zh}) {
  if (!isAndroid) return BgGuideRow.hidden;
  if (zh) {
    return const BgGuideRow(
      visible: true,
      title: '后台被系统限制怎么办',
      body: '部分厂商系统（如 ColorOS）会在后台限制网络，回答可能停在半路。',
      honestNote: '那个开关我们读不到，也无法替你拨，请按下面的路径自己确认。',
      pathHint: 'ColorOS：设置 → 应用 → 本应用 → 允许后台活动',
      primaryLabel: '打开应用信息页',
      primaryTarget: kBgGuideTargetAppDetails,
      secondaryLabel: '打开电池优化列表',
      secondaryTarget: kBgGuideTargetBatteryOpt,
      secondaryNote: '另一个页面：AOSP 电池优化，管的是 Doze 那一层。',
    );
  }
  return const BgGuideRow(
    visible: true,
    title: 'Background limits',
    body: 'Some vendor systems (ColorOS and others) cut this app\u2019s network in the '
        'background, so an answer can stall halfway.',
    honestNote: 'We cannot read that switch or flip it for you \u2014 '
        'check the path below yourself.',
    pathHint: 'ColorOS: Settings \u2192 Apps \u2192 this app \u2192 allow background activity',
    primaryLabel: 'Open app info page',
    primaryTarget: kBgGuideTargetAppDetails,
    secondaryLabel: 'Battery optimization list',
    secondaryTarget: kBgGuideTargetBatteryOpt,
    secondaryNote: 'A different page: AOSP battery optimization \u2014 the Doze layer.',
  );
}

/// 失败时页面上那句话。
///
/// 原因字符串**只能由原生侧产出**（教训 #62）：这里只负责把它包成人话，
/// 拿不到原因时也必须留一行能看的字 —— 空串就是"点了没反应"那个反复出现的假完成形状。
String bgGuideFailureText(String? nativeReason, {required bool zh}) {
  final reason = (nativeReason ?? '').trim();
  if (reason.isEmpty) {
    return zh
        ? '跳转没有成功，而原生这一侧没有给出原因（这本身按缺陷处理：'
            '请把日志里 BgGuide 那一行发给我们）'
        : 'The jump did not happen and the native side gave no reason '
            '(treated as a defect: please send us the BgGuide line from the log)';
  }
  return zh ? '跳转没有成功：$reason' : 'The jump did not happen: $reason';
}

/// 点了之后打的那一行日志（含"跳哪个 action + 成功/失败 + 失败原因"）。
///
/// 为什么把格式也放进判据文件：下一次真机取证要能一眼回答
/// 「他到底进过那个页面没有」，格式散在调用点就会漂成两种读数（同一条命令行的两种拼法）。
String bgGuideLogLine({
  required String target,
  required bool ok,
  String? nativeReason,
}) {
  final reason = (nativeReason ?? '').trim();
  final tail = reason.isEmpty ? '' : ' 原因=$reason';
  return '后台指引 target=$target 结果=${ok ? kBgGuideStatusOpened : 'failed'}$tail';
}
