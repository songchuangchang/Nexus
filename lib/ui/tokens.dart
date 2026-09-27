import 'package:flutter/material.dart';
// #89：`SpringSimulation` 只从 physics 库导出（material 侧只 re-export 了
// SpringDescription/Simulation），弹簧档需要它把弹簧归一成 Curve。
import 'package:flutter/physics.dart' show SpringSimulation;

/// v1.7.38 build90（全量 UI 重构）：Nexus 朴素风设计令牌。
///
/// 设计基调（用户拍板：V2 朴素风常驻全 App）：
/// - 去彩色容器：不使用 primaryContainer/tertiary 大色块，统一中性灰分层
/// - 去 emoji：图标/文字/状态一律 Material 图标 + 中性色
/// - 圆角克制：气泡 12、面板/代码块 8、行内可点 6、卡片 14
/// - AI 内容通栏无底无边框；分组卡片用极浅灰底而非彩色
abstract final class AppRadius {
  static const double inline = 6; // 行内可点区域 / chip / 附件
  static const double panel = 8; // 思考面板 / 代码块 / 引用块内层
  static const double bubble = 12; // 用户气泡 / 输入框
  static const double card = 14; // 设置分组卡片
  /// 悬浮胶囊（「回到底部」这类贴在内容之上的小浮层）。
  /// build138 真机反馈③补档：胶囊要同时用在 ClipRRect / 装饰 / InkWell 三处，
  /// 圆角必须一致，散写数字既过不了 R3 机检，也会在改法时漏改一处（直角切圆角）。
  static const double pill = 18;
}

abstract final class AppGap {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
}

abstract final class AppPad {
  static const EdgeInsets bubble =
      EdgeInsets.symmetric(horizontal: 12, vertical: 8);
  static const EdgeInsets panel = EdgeInsets.all(10);
  static const EdgeInsets card = EdgeInsets.all(12);
  static const EdgeInsets page =
      EdgeInsets.symmetric(horizontal: 12, vertical: 8);
}

/// 动效时长令牌（build133 建立 · build165 #89 起逐档对齐 Material motion tokens）：
/// 全 App **唯一**的动画时长来源。
///
/// 为什么要有它：动效的「系统一致」只能靠唯一真源保证 —— 散写
/// 240/260/300ms 会让同一个动作在不同页面快慢不一，且无法机检。
/// 机检规则 R9（`test/v2_ui_rules.dart` + `tools/v2_ui_audit.py`）
/// 禁止 UI 层裸写 `duration: Duration(milliseconds: …)`。
///
/// **数值出处（build165 #89）**：每一档直接引用 Flutter SDK 自带的具名档
/// `Durations.shortX/mediumX/longX/extralongX`（M3 duration tokens；
/// SDK `material/motion.dart`，上游是 MDC-Android `docs/theming/Motion.md`），
/// **不再手抄字面量** —— SDK 常量是第一真源，本文件只做「语义 → 具名档」的映射，
/// 免得我们成为第二真源（教训 #62）。
/// ⚠️ 这是 **Material（Google）** 的参数，不是 OPPO：OPPO 没有对外公开的动效
/// 规范/可接入 SDK（2026-09-26 调研核实）。我们从 ColorOS 取的是**取向**
/// （无缝、跟手、可打断），不是数值 —— 对外口径按「标准 > 厂商私有」排。
///
/// build165 改了三档（旧自造值 → 新具名档）：fast 120→short2(100) ·
/// slow 280→medium2(300) · skeleton 1200→extralong4(1000)；
/// 其余档恰好原本就落在 Material 具名档上（base/minAsync=short4、
/// minLoading=medium4、pulse/toast=extralong3），换成引用后数值一字未动。
abstract final class AppDur {
  /// 局部状态切换：图标位（测试中 → 成功/失败）、发送 ↔ 停止
  /// = Durations.short2（100ms）
  static const Duration fast = Durations.short2;

  /// 出现 / 交叉淡入：新消息入场、图片解码完成、四态切换、列表增删
  /// = Durations.short4（200ms）
  static const Duration base = Durations.short4;

  /// 尺寸 / 位移：思考面板展开、滚动定位、页面转场；
  /// 容器转场的**离场**档也复用它（MDC container transform outgoing = medium2）
  /// = Durations.medium2（300ms）
  static const Duration slow = Durations.medium2;

  /// #89 新增档：**整页容器转场**的进入时长（产物卡片 → 预览页的 container
  /// transform，见 `lib/ui/app_container_transform.dart`）。
  /// MDC：incoming = long1；「全屏/转场用 slow 档」的选档规则与此一致。
  /// = Durations.long1（450ms）
  static const Duration containerEnter = Durations.long1;

  /// 循环呼吸：流式光标 = Durations.extralong3（900ms）
  static const Duration pulse = Durations.extralong3;

  /// 循环呼吸：骨架屏（比光标慢，避免抢注意力）
  /// = Durations.extralong4（1000ms；Material 最大一档，旧的 1200 没有对应档）
  static const Duration skeleton = Durations.extralong4;

  /// 图标位 loading 的**最小显示时长**：接口很快时「转圈闪一下」
  /// 比不转更糟，故 spinner 一旦出现至少停留这么久。
  /// = Durations.medium4（400ms）
  static const Duration minLoading = Durations.medium4;

  /// 异步内容（四态切换）的最小显示时长，防慢网下 spinner 闪烁
  /// = Durations.short4（200ms）
  static const Duration minAsync = Durations.short4;

  /// 轻量确认类浮层（「已存入记忆」等）的停留时长。
  ///
  /// 注意边界：R9 只机检 `Duration(milliseconds:` 写法，因此全库另有 66 处
  /// `SnackBar(duration: Duration(seconds: N))`（N 从 2 到 8 不等）**不在 R9 覆盖内**。
  /// 那些浮层多为错误/长文案、停留时长各有用意，统一它们属于独立议题
  /// （后续 R10「浮层停留时长一致性」），本 build 不顺手改行为。
  /// = Durations.extralong3（900ms）
  static const Duration toast = Durations.extralong3;
}

/// **非动画**的等待/超时时长，集中放在这里而不是散落各文件。
///
/// 为什么不并进 [AppDur]：D1 那道闸的口径是"写死的时长字面量只许住在 tokens.dart"，
/// 放进来是为了让"时长不许散落"这条**只有一份实现**；但**语义必须分开** ——
/// 这两个值是平台通道调用的超时，不是任何观感时长。谁以后调动效档位（比如把
/// `medium2` 改成 250ms）**都不该顺手把"读一次退出原因愿意等多久"改掉**；
/// 反过来，为了 IPC 改这里也不该牵动任何过渡。所以另立一档，注释写明用途与出处。
abstract final class AppWait {
  /// 读一次心跳快照的超时：那只是读一个 `@Volatile` 静态量，慢就说明原生主线程被占住，
  /// 再等下去就是"为一条读数把正事变成新故障"（build165 取证那路的原话）。
  static const Duration heartbeatDiag = Duration(milliseconds: 400);

  /// 读上次进程退出原因的超时：那是一次走 system_server 的 IPC，比读静态量慢一个量级。
  static const Duration exitReasonsIpc = Duration(seconds: 3);

  /// 键盘占位量"连续这么久没再变化"⇒ 认定这一轮已经坐稳（build166 的峰值改锚判据）。
  ///
  /// 为什么住在这里而不是 `keyboard_inset.dart` 里写死：D1 的口径是"字面时长只许住
  /// tokens.dart"，这条不能例外。为什么**不是**动画时长：OPPO 真机那份导出里 IME 动画
  /// 约 270ms、逐帧都在变（+28/+36/+32/…），一个 200ms 的字节级平台只可能是"停住了"
  /// 而不是"还在动"。它也不驱动任何观感 —— 只决定"什么时候允许把分母改锚到当前这一档"。
  static const Duration imeSettleHold = Duration(milliseconds: 200);
}

/// 动效曲线令牌：只有四条，语义绑定用途而非形状。
///
/// **数值出处（build165 #89）**：直接引用 Flutter SDK 自带的 `Easing.*`
/// （M3 easing tokens，SDK `material/motion.dart`；与上表同源，
/// 上游是 MDC-Android `docs/theming/Motion.md`）。同样是 **Material 参数、
/// 不是 OPPO**（OPPO 无可核实公开动效规范，口径见 [AppDur] 文件头）。
abstract final class AppCurve {
  /// 入场 / 展开：起步快、收尾稳
  /// = Easing.emphasizedDecelerate cubic(0.05, 0.7, 0.1, 1.0)
  /// （旧值 Curves.easeOutCubic；emphasized 减速段"起步冲、落点零速"，
  /// 是无痕入场观感的主要来源）
  static const Curve enter = Easing.emphasizedDecelerate;

  /// 退场：起步慢、离场干脆
  /// = Easing.emphasizedAccelerate cubic(0.3, 0.0, 0.8, 0.15)
  static const Curve exit = Easing.emphasizedAccelerate;

  /// 循环 / 通用 / **容器转场主体**（MDC container transform 的 standard 档）
  /// = Easing.standard cubic(0.2, 0.0, 0.0, 1.0)
  static const Curve standard = Easing.standard;

  /// 图标形变（同位置换图标）
  /// = Easing.standardDecelerate cubic(0.0, 0.0, 0.0, 1.0)
  static const Curve morph = Easing.standardDecelerate;
}

/// 弹簧令牌（build165 #89 新增）：Material MotionSpec 弹簧表的 6 个
/// SpringDescription 档（dampingRatio / stiffness 成对给出，mass=1）。
///
/// 选档规则（MDC 原文）：小部件用 fast、**全屏/转场用 slow**、其余 default；
/// **位移/尺寸这类"空间量"用 spatial（允许轻微 overshoot）**，
/// **透明度/颜色这类"effects 量"用 effects（ratio=1，不应 overshoot）**。
///
/// Flutter SDK 只有弹簧的**类型与物理实现**（`SpringDescription` /
/// `SpringSimulation`），没有这组数值，所以数值只落在这里 = 本仓弹簧档唯一真源。
/// damping 系数一律交 `SpringDescription.withDampingRatio` 由 SDK 换算
/// （d = 2ζ√(km)），我们不抄换算公式（教训 #62）。
/// ⚠️ 出处是 Material，不是 OPPO（口径见 [AppDur] 文件头）。
abstract final class AppSpring {
  /// fast · spatial（小部件位移/尺寸；ζ=0.9, k=1400）
  static final SpringDescription spatialFast = SpringDescription.withDampingRatio(
      mass: 1.0, stiffness: 1400.0, ratio: 0.9);

  /// default · spatial（一般空间量；ζ=0.9, k=700）
  static final SpringDescription spatialDefault = SpringDescription.withDampingRatio(
      mass: 1.0, stiffness: 700.0, ratio: 0.9);

  /// slow · spatial（**全屏/转场位移**；ζ=0.9, k=300）—— #89 容器转场用的就是它
  static final SpringDescription spatialSlow = SpringDescription.withDampingRatio(
      mass: 1.0, stiffness: 300.0, ratio: 0.9);

  /// fast · effects（透明度/颜色，不应 overshoot；ζ=1, k=3800）
  static final SpringDescription effectsFast = SpringDescription.withDampingRatio(
      mass: 1.0, stiffness: 3800.0, ratio: 1.0);

  /// default · effects（ζ=1, k=1600）
  static final SpringDescription effectsDefault = SpringDescription.withDampingRatio(
      mass: 1.0, stiffness: 1600.0, ratio: 1.0);

  /// slow · effects（ζ=1, k=800）
  static final SpringDescription effectsSlow = SpringDescription.withDampingRatio(
      mass: 1.0, stiffness: 800.0, ratio: 1.0);

  /// [spatialSlow] 的 0→1 形状版：Hero 转场的飞行曲线只能吃 `Curve`
  /// （SDK 的 Hero 飞行挂在路由线性时钟上，`SpringDescription` 不是 Curve），
  /// 这一档把慢空间弹簧归一成曲线，供 `AppContainerHero` 使用。
  static final AppSpringShape spatialSlowShape = AppSpringShape(spatialSlow);
}

/// 把 [SpringDescription] 归一成 0→1 的 [Curve]（build165 #89）。
///
/// 弹簧本来**没有固定时长**：这里取「在默认容差下落定所需的时间」
/// （用 SDK `SpringSimulation.isDone` 二分出来，不手解物理方程）当作形状轴，
/// 拉伸到调用方给的时钟上 —— **快慢仍由时长档决定，曲线只出形状**。
/// 终点保证恰好 1.0（`snapToEnd: true`）：t≥1 一律落终态。
///
/// reduced（无障碍「移除动画」）的落终态责任在**时长**上：调用方一律
/// `AppMotion.duration(context, …)`，归零后路由动画同帧直达 1.0，
/// 本曲线不存在"弹簧收敛中"被卡住的路径；#89 转场还额外用
/// `HeroMode(enabled: false)` 干脆不起飞（见 app_container_transform.dart）。
final class AppSpringShape extends Curve {
  AppSpringShape(SpringDescription spring)
      : _sim = SpringSimulation(spring, 0.0, 1.0, 0.0, snapToEnd: true) {
    _settle = _settleTime(_sim);
  }

  final SpringSimulation _sim;

  /// 落定时间（秒）。构造期算一次，transform 每帧只查表。
  late final double _settle;

  static double _settleTime(SpringSimulation sim) {
    var hi = 0.02;
    while (!sim.isDone(hi) && hi < 30.0) {
      hi *= 2.0;
    }
    var lo = hi / 2.0;
    for (var i = 0; i < 48; i++) {
      final mid = (lo + hi) / 2;
      if (sim.isDone(mid)) {
        hi = mid;
      } else {
        lo = mid;
      }
    }
    return hi;
  }

  @override
  double transform(double t) {
    if (t <= 0.0) return 0.0;
    if (t >= 1.0) return 1.0;
    return _sim.x(t * _settle);
  }
}

/// 动效取用入口。
///
/// [duration] 是**唯一**允许读 `disableAnimations` 的地方 —— 调用方
/// 一律写成 `AppMotion.duration(context, AppDur.slow)`，不要各自判断，
/// 否则「无障碍开关只对一半动效生效」这种半残状态一定会出现。
abstract final class AppMotion {
  /// 系统是否开启了「移除动画」（无障碍 / 省电）
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  /// 归零版时长：reduced 时返回 [Duration.zero]（隐式动画组件会直接落终态）
  static Duration duration(BuildContext context, Duration normal) =>
      reduced(context) ? Duration.zero : normal;
}

extension AppColors on ColorScheme {
  /// 用户气泡 / 强调浅灰底（不透明容器用）
  Color get appBubble => surfaceContainerHighest.withValues(alpha: 0.65);

  /// 面板浅灰底（思考面板、行内 code）
  Color get appPanel => surfaceContainerHighest.withValues(alpha: 0.5);

  /// 更浅的面板底（引用块、来源面板）
  Color get appPanelLight => surfaceContainerHighest.withValues(alpha: 0.35);

  /// 浮层小件底（「回到底部」胶囊等悬浮在内容之上的小件）——需透出下方内容。
  ///
  /// build138 真机反馈③：0.65 这一档在**暗色主题**下仍然读成一块实心板
  /// （`surfaceContainerHighest` 本身就比背景亮一档，0.65 叠加后几乎不透出消息文字，
  /// 再配 elevation 的投影 = "贴了块长方形遮住内容"）。观感上"透不透"不只由 alpha
  /// 决定，还取决于底下有没有真的把背景模糊掉。
  /// ⇒ 该档降到 0.30，并只用于「BackdropFilter 毛玻璃」形态（调用点必须自带模糊 +
  ///   1px 描边交代边界，且不带投影）；alpha 低而边界靠描边，才既透又不"糊成一片"。
  Color get appFloating => surfaceContainerHighest.withValues(alpha: 0.30);

  /// 次级文字（说明、footnote、域名）
  Color get appTextSub => onSurfaceVariant;

  /// 弱化文字（footnote 更淡）
  ///
  /// build157（⑫）：alpha 0.5 → 0.8。
  /// 判据是本仓库自己那份实算口径（`docs/UI_TASTE_build152.html`
  /// 「暗/亮可读性 · 关键 alpha 实算」：C=(L1+0.05)/(L2+0.05)，
  /// 前景×α+背景×(1−α) 预混），小字要过 4.5:1 这条正文线。
  /// 亮色 `onSurfaceVariant` = #3F484A，原来那档落在 `surface`(#FAFDFD) 上只有
  /// 2.52:1（11px footnote 直接糊），暗色也只有 3.52:1。
  /// 为什么一步要到 0.8：这 11 处调用点**不是**都打在 `surface` 上，
  /// 半数打在 `appPanelLight` / `appBubble` / `surfaceContainer` 这类浅灰底上，
  /// 而底色越深对比越低，所以必须按最暗的那块底来定档（实算，非估）：
  ///   α 0.74 → surface 4.46 / panelLight 4.27 / bubble 4.10 / container 4.22
  ///   α 0.76 → 4.70 / 4.49 / 4.30 / 4.44（三处仍不过线）
  ///   α 0.78 → 4.96 / 4.72 / 4.52 / 4.66（过线但 bubble 只剩 0.02 余量）
  ///   α 0.80 → 5.23 / 4.97 / 4.75 / 4.91（四底全部 ≥4.5，暗色 7.19）
  /// ⇒ 0.8 是「亮色四种实际底色都过 4.5 且留余量」的最小整档；
  ///   与 `appTextSub`（α 1.0，亮色 9.18）之间仍有可辨的层级差。
  Color get appTextFaint => onSurfaceVariant.withValues(alpha: 0.8);

  /// 中性描边（分组卡片边框、分隔）
  Color get appBorder => outlineVariant.withValues(alpha: 0.6);
}

/// 设置页统一分组卡片：圆角 14 浅灰底 + 可选标题。
///
/// build139 修的一处全局隐患：卡片底原来挂在 `Container`（= DecoratedBox）上，
/// 而 `ListTile` / `SwitchListTile` 的水波纹是画在**最近的 Material 祖先**上的。
/// 于是各设置页里凡是放在卡片内的 tile，点击既没有波纹也没有高亮（release 不报错，
/// 只是"点了没反应"；debug 直接抛 assertion）。这里把底色/描边/圆角改由 [Material]
/// 自己承担，tile 的波纹就有了落点，观感与原来一致。
class AppSectionCard extends StatelessWidget {
  const AppSectionCard({
    super.key,
    this.title,
    required this.children,
    this.contentPadding =
        const EdgeInsets.symmetric(horizontal: AppGap.md),
  });

  final String? title;
  final List<Widget> children;

  /// 卡片的**水平留白只在这里给一次**。
  ///
  /// build163（机主两条截图：「通用设置 ui 很怪」「api 好像也是同样问题」）的根因就在这里：
  /// 全仓 62 处行都写着 `contentPadding: EdgeInsets.zero` —— 那是"把水平留白交给卡片"的约定，
  /// 而旧版 `AppSectionCard` **只给标题 12、从不给行**，于是图标压在卡片左边框上、
  /// 标题与副标题一直顶到右边框。两个页面"同样怪"不是各写错一次，是同一个共享组件缺了这一格。
  /// 改在共享组件里而不是逐页补 padding：逐页补就会有两种口径并存，下一次新页面照样踩。
  final EdgeInsetsGeometry contentPadding;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppGap.md),
      child: Material(
        // 浮在页面背景上的半透明面板：不需要自身投影，靠描边交代边界
        type: MaterialType.canvas,
        color: cs.appPanelLight,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
          side: BorderSide(color: cs.appBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
                child: Text(title!,
                    style: tt.labelLarge?.copyWith(
                        fontWeight: FontWeight.w600, color: cs.appTextSub)),
              ),
            // 每一行各自套一次：行与行之间仍然通铺（分隔靠描边/留白），
            // 但左右两侧从此都有格子。
            ...children.map((child) =>
                Padding(padding: contentPadding, child: child)),
            const SizedBox(height: AppGap.xs),
          ],
        ),
      ),
    );
  }
}
