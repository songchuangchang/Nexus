import 'dart:io';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../models/chat_message.dart';
import '../models/plugin_hint_config.dart';
import '../ui/app_sheet.dart';
// build168（宽屏档）：功能行的排布档读这里（断点/列宽的唯一所有者），
// 本文件不写任何宽度数字。
import '../ui/app_content.dart';
import '../ui/tokens.dart';
import 'chat_input_actions.dart';
import 'chat_input_action_button.dart';
import 'chat_input_config.dart';
import 'model_switcher.dart';
import '../ui/image_decode.dart';
import '../utils/keyboard_inset.dart';

/// 输入区正文该**画几行** —— build166 起的口径：**只由引擎那一份连续进度 t 算**。
///
/// 这是同一条判据的第 12 次改口径。改的不是"翻到哪一档"，而是**什么时候翻、谁驱动翻**：
/// 用户 2026-09-26 13:20 装完 `v1.7.108+165` 报「输入框展开是正常的，**收缩还是有卡顿**」。
/// 第十一轮取证（已定案）给出的两个成因：
///  ① **两把表**：抬起由 [ImeLift] 逐帧从引擎读（OPPO 真机约 270ms、节拍不规则），
///    行数却由 build163 那个 200ms `TweenAnimationBuilder` 自己跑 —— 两件事没有理由同步。
///  ② **翻档时刻错、方向不对称**：驱动量是布尔 `keyboardUp`，弹起在 `insets=4` 的
///    **第一帧**就翻满 4 档，收起却要等 `insets=0` 的**最后一帧**才翻回 1 档
///    ⇒ 展开看起来同步（所以他说"正常"），收缩是"框先落回底部、停一下、再收行"。
///    另外补间每帧重建一次正文，一轮开键约 48 次全段文本重排，而高度真变的只有 3 次。
///
/// 修法（方案①）：**让第二把表退休，而不是给它换转速**。行数与抬起消费同一个
/// 由引擎逐帧给的 [ImeFrame.t]（`imeOpenProgress` = 本帧占位 / 本轮峰值），于是
///  · 收起方向：行数随 `lift` 一路同步落回去 —— 用户报的那一段；
///  · 引擎一步到位（系统"移除动画"、某些 ROM 的输入法根本不 animate）时 t 直接 0→1，
///    自然没有中间档 ⇒ **本轮不新增任何动画开关**（对比 163 靠 `AppMotion` 归零）；
///  · 高度仍然只有 `TextField` 的 `minLines..maxLines` 一个所有者：这里算出的是
///    它的**控制量**，不是又一次 `child.size` 测量（D3 禁用名单那条闸与此同族）。
///
/// 代价与已知边界（写清楚，别当没有）：展开方向上"本轮峰值"就是本帧的占位量 ⇒ t 从
/// 第一帧起为 1、行数一步落满档，位移由引擎的抬起继续完成。这与 163 的"200ms 内基本
/// 已经满档"只差约 90ms，且用户明确说展开是正常的；真要再改，该改的是**让分母来自上一轮**
/// （跨轮保留峰值），**不是**把补间装回去。
///
/// 历史（这条判据为什么已经改到第 12 次，全部留在这里）：
///  · build138 #8 档③ 做过 `focused ? min(3, maxLines) : 1`；
///  · build153 撤掉它，因为用户第 7 次报"只能伸不能缩" —— 病根是**驱动量选了焦点**：
///    删空文字后焦点还在，最低行数就永远停在 3，缩不回去是这条规则本身造成的；
///  · build162 换成引擎那份"键盘到底开着没有"（布尔）驱动 ⇒ 收回必然发生，但翻档时刻
///    仍然是错的（上面成因②）；build163 给它补了 200ms 过渡 ⇒ 展开方向被补平了，
///    收缩方向反而露出尾巴（成因①）——就是这一次的报告；
///  · build166 起：连续进度 [ImeFrame.t] 驱动，`keyboardUp` 那个布尔**只进日志**
///    （与树内旧判据对账），不再参与画几行。
///
/// 为什么不按 `controller.text` 的行数算 min：那要依赖"每次文本变化都重建这半截 widget"，
/// 而重建时机不在本文件手里 —— 一旦某次删改没触发重建，min 停在旧值，"缩不回去"
/// 会以更难查的形式回来。键盘占位是引擎事件（`didChangeMetrics` 必然触发重画），
/// 比文本变化可靠；而**内容本身该占几行**从来就归 `TextField` 自己算（`maxLines` 以内
/// 软/硬换行都即时长高，见 `test/build138_composer_test.dart` 那组）。
const int kComposerOpenLines = 4;

/// 键盘进度 → 行数档。`t=0` 一行、`t=1` [kComposerOpenLines] 行，中间逐档走。
///
/// [maxLines] 是调用点那道横屏 `compactInput` 的夹子（那时上限只有 5）：
/// `minLines > maxLines` 会让 `TextField` 直接 assert 崩掉，所以这里夹死它。
int composerMinLines({required double progress, int maxLines = 10}) {
  // 进度先夹进 0..1：`ImeLift` 那边已经夹过，这里再夹一次是给"以后有人从别处喂数"
  // 兜底 —— 一个 1.4 的进度会把行数顶到 maxLines 以上，然后被 TextField assert。
  final double t =
      progress.isFinite ? progress.clamp(0.0, 1.0).toDouble() : 0.0;
  return (1 + ((kComposerOpenLines - 1) * t).round()).clamp(1, maxLines);
}


/// 聊天输入框（v1.7.18 重构：构造 26 参数 → 5 参数，CC 41→≤15）
///
/// 构造：`{required ChatInputConfig config, required ChatInputActions actions,
/// required TextEditingController controller, required VoidCallback onSend,
/// required VoidCallback onStop}`。
///
/// build126（B1）**composer 化**——由「框外按钮行 + 框内输入」改为**单一大框**：
///   [提示条]（3 分支：搜索模式 / 思考中 / 禁用，仍在框外上方）
///   ┌────────────────────────────────────────────┐
///   │ 占位符 / 正文（框内顶部对齐，minLines 撑高）    │
///   │ [附件 chip 行]（有附件时才出现）               │
///   │ [+]      [状态] [功能按钮…] [发送 / 停止]      │  ← 功能行收进框内底部
///   └────────────────────────────────────────────┘
///
/// B1 一并修掉本文件三处存量违规：
///   - R1 emoji：原用 🌐/🧠/🔌 等 emoji 当按钮文字与提示前缀 → 纯 Material 图标；
///     按钮改纯图标后用 `Semantics(label: tooltip)` 补读屏（原来靠可见文字被读屏识别）。
///   - R3 圆角：输入框 `circular(24)` → `AppRadius.bubble`(12)（tokens 里 bubble 的
///     语义注释本就是「用户气泡 / 输入框」）；同文件 `circular(16)` → `AppRadius.card`、
///     `circular(4)` → `AppRadius.inline`。
///
/// 未纳入本次（保持功能不变，避免夹带）：图里的 🎤 语音输入是**新功能**，
/// 当前 `ChatInputActions` 无对应回调，需单独立项。
///
/// build138（输入区改造 · 已批准的方案 B + Q2 + Q3 + #8 档③）：治「违和感」八条
/// 里的 6 条，外加「写入位置太小」——
///   · #1 输入框主题描边：`border/enabledBorder/focusedBorder/disabledBorder` 四处
///     全显式 `InputBorder.none`（只写 border 那一个键没用，applyDefaults 会回落到
///     theme.dart 的 OutlineInputBorder）⇒「框中框」消失；
///   · #2 模型 chip 圆角/彩色 → 中性（见 model_switcher.dart）；
///   · #3 「自动」三处表达 → 提示条一处文字 + 按钮一个圆点；
///   · #5 提示条去底去框（装饰全部让给 composer）；
///   · #6 🧠 弹层换 [showAppSheet]，渐变特效字换 `titleMedium`（本文件 hardColor 2 → 0）；
///   · #7 附件 chip 与 composer 分层（appBubble 底 + 实色 surface chip）；
///   · #8 写入区 35dp → 48dp 一行可点区（字号 16 / 行高 1.5 / 纵向内边距 12）。
///     同批还加过"聚焦撑 minLines 3 ⇒ 96dp"那一档，**build153 已撤**：
///     它就是用户第 7 次报的"只能伸不能缩"的真身，理由与代价见 [composerMinLines]。
/// **发送键保留 primary 亮青**（方案 B）：全输入区唯一彩色，主操作辨识度不牺牲。
/// 范围只在本目录 4 个 widget 文件，未动 chat_screen.dart 的用量条与层序。
class ChatInput extends StatelessWidget {
  final ChatInputConfig config;
  final ChatInputActions actions;
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSend;
  final VoidCallback onStop;

  const ChatInput({
    super.key,
    required this.config,
    required this.actions,
    required this.controller,
    required this.focusNode,
    required this.onSend,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) =>
      ImeLift(builder: (context, frame) => _buildBody(context, frame));

  Widget _buildBody(BuildContext context, ImeFrame frame) {
    final imeLift = frame.lift;
    final l = AppLocalizations.of(context);
    final isZh = l.locale.languageCode == 'zh';
    final cs = Theme.of(context).colorScheme;
    final mediaQuery = MediaQuery.of(context);
    // ===== build148 输入区重构（用户原话：「输入伸缩，还是不行，直接重构算了」）=====
    // 「框该画几行」这件事**不再问"键盘在不在"**。这条判据在这台机器上翻过五次，
    // 五次都是在旧式子上再猜一次（学静止基线 / 等两帧 / 稳定窗口 / 绝对参照 / 焦点改判参照），
    // 而"画几行"本来就是内容决定的，不需要一个传感器来代答 ⇒ `minLines..maxLines` 只跟内容走。
    // 留着的那行 `keyboardUpForLog` **只写日志、不参与决策**（对账用）。
    // ⑩ 横屏防 BOTTOM OVERFLOWED 的上限保留原样：它只影响"最多长多高/要不要滚"，
    // 不参与"撑高还是收起"，判错最多多一条滚动条，不会像 minLines 那样把输入框卡死。
    //
    // **build161 订正这段注释的两个前提**（它当年是"再猜一次"的产物，而且猜反了）：
    //  · 原写"AndroidManifest 用 adjustResize ⇒ 系统直接缩应用窗口，所以 viewInsets 全程 0"——
    //    真机 160 那份导出证明**窗口根本没缩**（`窗高` 恒 932，键盘弹起也是 932）：
    //    Android 16 edge-to-edge 下系统不缩窗口，只把 IME 占位**派给引擎**（`原生insets` 到 220）。
    //  · 原写"键盘占位交给布局本身消化，两条路都已覆盖"——**两条都没覆盖**：
    //    窗口没缩 ⇒ 第一条不存在；`Scaffold` 读的是树内 `MediaQuery.viewInsets`（本机恒 0）
    //    ⇒ 第二条从未生效。结果就是"框照常涨缩，但涨到键盘后面"，用户读作"不伸不缩"。
    // ⇒ 于是"整块该抬多高"这件事**第一次有了明确的消费者**：下面那个 [ImeLift] 给的抬起量。
    //    当时写的分工是「抬多少问引擎，画几行问内容」——
    // **build166 订正这半句**（用户 2026-09-26 13:20「展开是正常的，收缩还是有卡顿」）：
    //    "画几行问内容"只说对了一半。内容决定的是**要多高时该出滚动条**（maxLines 以内
    //    的长高一直是 TextField 自己在算，没被动过）；而"框至少该空几行"是**键盘状态**，
    //    162/163 拿一个布尔去驱动它，于是翻档时刻必然与逐帧的抬起错开。现在两件事
    //    吃同一个由引擎逐帧给的 [ImeFrame.t]：**抬多少、画几行，同一把表**。
    //    口径与代价见 [composerMinLines] 的类注释（含"展开方向第一帧就落满档"这一条）。
    // build161：可写高度改吃**引擎自己那一份键盘占位**（[imeLiftLogical] 算出来的抬起量），
    // 不再吃 `mediaQuery.viewInsets.bottom` —— 本机那一个是恒 0 的坏读数（证据见
    // [ImeLift] 的注释：引擎报 220、上限恒 852、Scaffold 因此一次都没抬）。
    // `imeLift == 0` 的两种情形都仍然正确：老式 adjustResize 机器窗口已被系统缩掉，
    // 这里的 `size.height` 本来就是键盘以上的空间。
    final maxInputHeight = (mediaQuery.size.height -
            imeLift -
            mediaQuery.padding.top -
            kToolbarHeight -
            24)
        .clamp(96.0, double.infinity);
    // 抬起量落在**这一层**：整块输入区（提示条 + 正文 + 功能行）一起上移，
    // 上方那个 Expanded 的消息列表自然缩短。全仓这一处是键盘高度的唯一消费者
    // —— `Scaffold.resizeToAvoidBottomInset` 已在 chat_screen 里显式关掉，
    // 否则 MediaQuery 哪天修好了就会抬两次（"尺寸不许有第二个所有者"）。
    // build168 备注：这里试过 `SizedBox(width: double.infinity)` + 外层 Column 改
    // `crossAxisAlignment.stretch`（推断"卡片被内容列松约束所以收缩"），**实测零变化**
    // （914dp 下功能行仍停在 670.5）⇒ 已撤回，不留没证据的改动。
    // 真正的成因与现象记在 test/build168_wide_content_test.dart ④ 与
    // docs/BUGSCAN_build166_20260926.md 的 168-D 节。
    return Padding(
      padding: EdgeInsets.only(bottom: imeLift),
      child: SafeArea(
        top: false,
        // 键盘收起（lift=0）时导航条仍归 SafeArea 管；键盘上来时那一截已经被键盘盖住，
        // 再由它垫一次就把输入框顶高一个导航条的高度 —— 关掉。
        bottom: imeLift <= 0,
        child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          border: Border(
            top: BorderSide(
              color: Theme.of(context).dividerColor.withValues(alpha: 0.5),
            ),
          ),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxInputHeight),
          child: SingleChildScrollView(
            reverse: true,
            physics: const ClampingScrollPhysics(),
            // build148：整棵输入区跟着焦点走。原来只有正文那半截包了 AnimatedBuilder，
            // 提示条的 compact 档读的是 build() 那一次的 MediaQuery —— 两者不同帧，
            // 横屏会出现「提示条已收起、正文还没撑开」的半更新。现在同一个 `focused`
            // 一次求值、两处共用（build140 反馈③ 的"只此一处、只算一次"不变，
            // 只是把输入源从传感器换成事实）。
            child: AnimatedBuilder(
              animation: focusNode,
              builder: (context, _) {
                final focused = focusNode.hasFocus;
                final keyboardUpForLog = keyboardOccludesBottom(context,
                    keyboardCertainlyClosed: !focused);
                // 横屏且正在写才收起提示条（原来还要再 && 键盘占位，同一个错口径）。
                final compactInput =
                    mediaQuery.orientation == Orientation.landscape && focused;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!compactInput) _buildStatusHintBar(l, cs, isZh),
                    _buildComposer(context, cs, l, isZh, focused, compactInput,
                        keyboardUpForLog,
                        // `capHeight`/`lift`/`frame` 到这里**只给日志读**（对账用）。
                        // 尺寸决策仍然只有 minLines..maxLines 一处，而它的输入只有两样：
                        // 本帧进度 frame.t 与内容本身。
                        capHeight: maxInputHeight,
                        frame: frame),
                  ],
                );
              },
            ),
          ),
        ),
      ),
      ),
    );
  }

  // ================ 提示条（3 分支）================

  Widget _buildStatusHintBar(AppLocalizations l, ColorScheme cs, bool isZh) {
    // v1.7.38 朴素风：提示条统一中性浅灰底，仅用文字/图标区分语义
    // build126（B1）：emoji 前缀 → Material 图标（Icons.*），语义不变
    // 思考队列提示（最高优先级：生成中且有排队的补充消息）
    if (config.isGenerating && config.pendingFollowupCount > 0) {
      return _hintBox(
        isZh
            ? '已加入思考队列 ${config.pendingFollowupCount} 条，AI 下一轮会处理'
            : 'Queued for next round: ${config.pendingFollowupCount} message(s)',
        cs,
        icon: Icons.playlist_add,
      );
    }
    // 搜索模式提示
    if (config.searchEnabled && config.searchMode && !config.isGenerating) {
      // build138（#3）：文案里的「自动」只留这一处。原来此处还会再拼一段插件态后缀
      // （「 · 自动」/「 · 手动(N)」），同一条提示里出现两个「自动」，用户分不清哪个是
      // 思考档、哪个是插件；且功能行上还有一处裸文字「自动」⇒ 同屏三处。
      // 现只保留思考档这一处，插件态由其按钮圆点 + tooltip 承载。
      final reactPart = config.reactAutoMode
          ? (isZh
              ? '${l.tr('searchModeOn')} · 自动 · 上限 ${config.reactRounds} 轮'
              : '${l.tr('searchModeOn')} · Auto · up to ${config.reactRounds} rounds')
          : (isZh
              ? '${l.tr('searchModeOn')} · ${config.reactLevelLabel} · ${config.reactRounds}轮'
              : '${l.tr('searchModeOn')} · ${_stripLabel(isZh, config.reactLevelLabel)} · ${config.reactRounds}');
      return _hintBox(reactPart, cs, icon: Icons.travel_explore);
    }
    // 思考中提示
    if (config.isGenerating) {
      return _hintBox(
        isZh ? '思考中… 可继续输入补充信息' : 'Thinking... you can type more to add',
        cs,
        icon: Icons.psychology_alt_outlined,
      );
    }
    // 搜索禁用提示
    if (!config.searchEnabled) {
      return _hintBox(l.tr('searchModeDisabled'), cs, icon: Icons.block);
    }
    return const SizedBox.shrink();
  }

  /// 提示条：build138（#5）**去底去框** —— 一行「图标 + 中性小字」，不再自带
  /// 圆角底色与描边。原来它自带一层中性浅灰底 + 描边，而 composer 大框
  /// 当时反而无边框 ⇒ 视觉层级倒挂（提示条比主区更「像控件」），是「违和感」的
  /// 来源之一。现在装饰全部让给 composer，提示条只作说明文字。
  Widget _hintBox(String text, ColorScheme cs, {IconData? icon}) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, top: 0, bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(icon, size: 13, color: cs.appTextSub),
            ),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(text, style: TextStyle(fontSize: 11, color: cs.appTextSub)),
          ),
        ],
      ),
    );
  }

  // ================ composer 大框（B1）================

  /// 单一大框：占位符在框内顶部、功能行收进框内底部。
  ///
  /// build138（#1/#2/#7）：底色由不透明 `surfaceContainerHighest` 改为用户气泡同源
  /// 的 `cs.appBubble`(0.65)，并补 1px `cs.appBorder` 描边 —— 此前「刻意不加 border」
  /// 的判断只看了 V2 R4（不要多余装饰），漏掉了它带来的两个副作用：
  ///   · 附件 chip 与 composer 同色（#7，看起来「没渲染」）；
  ///   · 输入框主题描边（theme.dart 的 enabled/focusedBorder）成了框内第二层框（#1）。
  /// 现在**外框由本 Container 承担、内层 TextField 四处 border 全 none** ⇒ 框中框消失，
  /// 且大框有了唯一的一圈边，不再显得「没画完」。
  /// [focused]/[keyboardUpForLog] 由 [build] 里唯一一次求值传下来：前者是提示条 compact 档
  /// 的输入，后者**只进日志**（build148 重构，见 build() 顶部注释）。
  /// [frame] 是 [ImeLift] 这一帧交出来的引擎现场（见 [_buildTextField] 怎么用它）。
  Widget _buildComposer(BuildContext context, ColorScheme cs, AppLocalizations l,
      bool isZh, bool focused, bool compactInput, bool keyboardUpForLog,
      {double capHeight = -1, required ImeFrame frame}) {
    return Container(
      decoration: BoxDecoration(
        color: cs.appBubble,
        borderRadius: BorderRadius.circular(AppRadius.bubble),
        border: Border.all(color: cs.appBorder),
      ),
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 2, 10, 0),
            child: _buildTextField(context, l, cs, isZh, focused, compactInput,
                keyboardUpForLog,
                capHeight: capHeight,
                frame: frame),
          ),
          if (config.pendingAttachments.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
              child: _buildAttachmentBar(context, cs),
            ),
          const SizedBox(height: 2),
          _buildComposerActionRow(context, cs, l, isZh),
        ],
      ),
    );
  }

  /// 框内正文区。**这里只给下限与上限**，中间那一档由谁给、什么时候翻，改过三次：
  ///  · build153：下限恒 1 行（"焦点撑 3 行"就是第 7 次报的"只能伸不能缩"的真身）；
  ///  · build162/163：下限跟 `keyboardUp` 这个布尔走，再给它补一段自己的 200ms 过渡；
  ///  · build166（用户 2026-09-26 13:20「展开是正常的，收缩还是有卡顿」）：**下限跟
  ///    引擎逐帧给的进度走** —— `composerMinLines(progress: frame.t)`。
  ///    抬起与行数从此吃同一个量，本文件不再有任何自己的时长（口径、历史与代价
  ///    全在 [composerMinLines] 上面那段）。
  ///  · 焦点**仍然不撑高**；内容该占几行也仍然由 `TextField` 自己在 `maxLines` 以内算，
  ///    本轮一位都没动（`test/build138_composer_test.dart` 那组继续有效）。
  ///
  /// build138（#8 档③）的字号 16 / 行高 1.5 / 纵向内边距 12 原样保留：
  /// 一行就是 48dp 可点区，内容多了自然长高。
  ///
  /// **build156：外层 `AnimatedSize` 已删除**（第八轮，这次是量出来的不是猜的）：
  /// `test/build156_input_grow_test.dart` 沿父链实测 —— TextField 本身长对了
  /// （48→72→96），但 `AnimatedSize` 永远停在首帧量到的 48，把可见大框钉成
  /// 一行高，多出的行按 `Clip.hardEdge` 裁掉 ⇒ 真机症状「框只有一行、字被挤住」。
  /// 机制（SDK `rendering/animated_size.dart` 实读）：`RenderAnimatedSize` 只在**自己**
  /// 的 `performLayout` 重跑时才重读 `child.size`（`_layoutStable` 那台状态机），
  /// 没有任何通知兜底；而它在 `SingleChildScrollView(reverse:true)` 视口的
  /// 无界布局里，纯文本变化驱动的局部重排**不会再轮到它**。
  /// 「布局尺寸不许有第二个所有者」—— 高度唯一所有者本来就是 TextField 的
  /// `minLines..maxLines`，摘掉争所有权且失灵的那个，不加任何新的高度计算。
  /// build163 当年补过渡补的也是所有者自己的**控制量**（逐帧改 `minLines` 的行数），
  /// 不是把那层量 child.size 的容器装回去；build166 更进一步：控制量的**过程**也交给
  /// 引擎给（`frame.t`），自己一方连时长都不剩了。
  Widget _buildTextField(BuildContext context, AppLocalizations l, ColorScheme cs,
      bool isZh, bool focused, bool compactInput, bool keyboardUpForLog,
      {double capHeight = -1, required ImeFrame frame}) {
    final maxLines = compactInput ? 5 : 10;
    // 进度 → 档（含横屏 `compactInput` 那道 maxLines 夹子：minLines > maxLines 会让
    // TextField 直接 assert 崩掉，夹子在 [composerMinLines] 里，只此一处）。
    final minLines = composerMinLines(progress: frame.t, maxLines: maxLines);
    // build145：把「实际画成几行」留一行现场。build166 起这一行还要能回答
    // "这一档是引擎的进度算出来的，还是另一把表算出来的" ⇒ 同帧带 `t=` 与 `峰值=`。
    // `keyboardUp=`（树内旧判据）与 `引擎键盘=`（引擎侧）两列继续对账：
    // 若尺寸跟着 `引擎键盘` 走而不跟 `t` 走，说明有人又把布尔读回了布局。
    logComposerShape(
      focused: focused,
      keyboardUp: keyboardUpForLog,
      engineKeyboardUp: frame.keyboardUp,
      progress: frame.t,
      peakSpace: frame.peakSpace,
      minLines: minLines,
      maxLines: maxLines,
      textLength: controller.text.length,
    );
    _scheduleGeomLog(context, capHeight, frame);
    // 只在**整数行真的变了**的那一帧重建正文（第十一轮数出来的账：旧写法每帧重建，
    // 一轮开键约 48 次全段文本重排，而高度真变的只有 3 次）。判据与机制见 [_ComposerLines]。
    return _ComposerLines(
      lines: minLines,
      inputs: <Object?>[
        l,
        cs,
        isZh,
        maxLines,
        controller,
        focusNode,
        config,
        actions,
        onSend,
      ],
      builder: (lines) => _buildTextFieldBody(l, cs, isZh, lines, maxLines),
    );
  }

  /// build158（第 9 次同一条「多行不撑高」反馈）：**只量不改**。
  ///
  /// 为什么这一次不再先猜：前八次全是"读代码 + 在测试里泵一遍"，而测试从来不复现真机
  /// （build156 那次好不容易量出 117→141→165，判的是**没有键盘**的一帧；
  /// 他的机器是 `adjustResize`，键盘弹起时窗口本身被系统缩掉）。
  /// 三条日志数字就能把"谁在钉高度"定死，不用再猜第九次：
  ///  · `正文=48` 且 `换行>0` ⇒ 长高本身没发生（`TextField` 那层的问题）；
  ///  · `正文≈上限` ⇒ 上面那个 `ConstrainedBox(maxHeight:)` 在按键盘缩过的窗口里夹死它；
  ///  · `视口` 很小而 `正文` 正常 ⇒ 外层布局（宿主 Column / 滚动视口）在吃高度。
  /// 取值一律在**帧后**读，因为 build 期间还没有尺寸；同一次改动只报一帧（去重按整行文本）。
  void _scheduleGeomLog(BuildContext context, double capHeight, ImeFrame frame) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      final self = context.size;
      final viewport = Scrollable.maybeOf(context)?.position.viewportDimension;
      final text = controller.text;
      final newlines = '\n'.allMatches(text).length;
      // 引擎那侧的原始读数：`View.viewInsets` 是系统直接派给 FlutterView 的 IME 占位，
      // 不经过任何 MediaQuery 覆盖。它和 `MediaQuery.viewInsets`（键盘判据读的）不一样时，
      // 就是"树里有人把 insets 吃了"；两者都是 0 而人正在打字，就是"系统根本没派"。
      final view = View.maybeOf(context);
      final dpr = view == null || view.devicePixelRatio == 0
          ? 1.0
          : view.devicePixelRatio;
      logComposerGeom(
        fieldHeight: self?.height,
        fieldWidth: self?.width,
        viewportHeight: viewport,
        capHeight: capHeight,
        chars: text.length,
        newlines: newlines,
        rawImeInsetLogical: view == null ? null : view.viewInsets.bottom / dpr,
        rawWindowHeightLogical:
            view == null ? null : view.physicalSize.height / dpr,
        // build161 补的三个数。前两个是**同一帧**里树内/引擎两份读数 ——
        // 160 那份导出之所以要把"谁吃了 insets"钉死，就是因为这两个数以前
        // 来自不同轮次的日志，永远对不齐。第三个 `顶边y` 是**结果**：
        // 键盘弹起时这个数必须变小（框被抬起来），不变小就是还在键盘后面。
        // 高度对不对已经证明是对的，位置是这十次里唯一没量过的一个观测量。
        treeInsetsLogical: MediaQuery.maybeViewInsetsOf(context)?.bottom,
        liftLogical: frame.lift,
        // build166：`t` 与 `峰值` 就打在 `抬起` 后面 —— **同一行、同一帧**。
        // 这三个数并排就是"一把表"的直接证据：抬起一路在掉而 t 钉着不动（或反过来）
        // 说明行数那一路还有自己的表；两列同步、行数逐档跟着落 = 用户要的那件事。
        progressLogical: frame.t,
        peakSpaceLogical: frame.peakSpace,
        fieldTopY: self == null
            ? null
            : (context.findRenderObject() as RenderBox?)
                ?.localToGlobal(Offset.zero)
                .dy,
      );
    });
  }

  Widget _buildTextFieldBody(AppLocalizations l, ColorScheme cs, bool isZh,
      int minLines, int maxLines) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      minLines: minLines,
      maxLines: maxLines,
      textAlignVertical: TextAlignVertical.top,
      textInputAction: TextInputAction.newline,
      enabled: true,
      readOnly: false,
      style: const TextStyle(fontSize: 16, height: 1.5),
      decoration: InputDecoration(
        hintText: config.isGenerating
            ? (isZh ? '思考中… 可补充信息加入队列' : 'Thinking... type to queue a message')
            : l.tr('typeAMessage'),
        isDense: true,
        filled: false,
        // build138（#1 根修）：**四个 border 键全部显式 none**。
        // 只写 `border: InputBorder.none` 是不够的 ——
        // `InputDecoration.applyDefaults` 的顺序是
        // `enabledBorder ?? theme.enabledBorder` / `focusedBorder ?? theme.focusedBorder`，
        // 而 lib/theme.dart 的 inputDecorationTheme 给所有输入框配了 12 圆角的
        // OutlineInputBorder ⇒ 大框内部又长出一圈框（聚焦还亮青），这就是「违和感」
        // 的第 1 条根因（探针实测过：改前 border 生效的确实是主题那两个键）。
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        disabledBorder: InputBorder.none,
        // build130 曾为绕开上面那圈主题描边把内边距压到 8（描边紧贴零内边距会把
        // 字形上下沿顶穿圆角环）。描边已删 ⇒ 内边距可自由取值，这里按 #8 档②抬到 12。
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
      ),
      onSubmitted: (_) {
        onSend();
      },
      // build101（F5）：长文本粘贴 → 转 text 附件。
      // 只在开关打开且「整段内容」超阈值时触发一次；触发后由
      // ChatScreen 清空输入框，避免递归（清空后长度回落不满足条件）。
      onChanged: (text) {
        final cb = actions.onLongTextPasted;
        if (cb == null) return;
        if (!config.pasteLongAsFile) return;
        if (text.length < config.pasteLongAsFileThreshold) return;
        cb(text);
      },
    );
  }

  /// 框内底部功能行：`[+] … [状态] [功能按钮…] [发送/停止]`
  ///
  /// build126（B1）：由「框外按钮行（[功能按钮] Spacer [状态]）」改为框内底部，
  /// 并把 `[+]` 附件按钮从输入框左侧一并收进来（原在输入行最左，视觉上是框外）。
  ///
  /// build168（宽屏档）：那一根 `Spacer()` 在 424dp 手机上是**看不出来**的（余量本来
  /// 就只有按钮之间的缝），到 914dp 平板上它把 700dp 全吞了 ⇒ 用户报的第一眼症状
  /// 「上面那排按钮不适应」就是这么来的：`+` 钉最左、按钮簇钉最右，中间一整条空的。
  /// 列宽夹到 720dp 之后再看，仍然是两个孤岛（缝约 400dp），所以宽档改排布：
  /// **`+` 与功能按钮并作一簇落在左边，`Spacer()` 挪到发送键之前**（发送键继续独占地
  /// 位右端 —— 它是这一行唯一的彩色、也是主操作，右端是它的老位置，不该动）。
  /// 手机侧（compact）走下面那条**逐字未改**的分支：`[+] Spacer [按钮…][2][发送]`。
  /// 两档共用同一个判据（[AppContent.isWide]，吃内容列宽不吃屏宽），断点只有一个家。
  ///
  /// ⚠️ 两个分支里模型 chip 那个 `Flexible`（build152 布局扫描 P1-1）**一位都没动**：
  /// 它必须是松散的，否则长模型名会把发送键顶出屏幕（机制见 `_buildFunctionButtons`）。
  Widget _buildComposerActionRow(
      BuildContext context, ColorScheme cs, AppLocalizations l, bool isZh) {
    // 左：[+] 添加附件
    // build101（F7）：补 Semantics，读屏（TalkBack / VoiceOver）可识别
    final addButton = Semantics(
      button: true,
      enabled: !config.isGenerating,
      label: isZh ? '添加附件（照片 / 文档）' : 'Add attachment (photo/document)',
      child: IconButton(
        onPressed: config.isGenerating ? null : actions.onPickAttachment,
        icon: const Icon(Icons.add, size: 22),
        tooltip: isZh ? '添加附件（照片/文档）' : 'Add attachment (photo/document)',
        color: cs.onSurfaceVariant,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      ),
    );
    // 功能按钮（按 config.buttonOrder 自定义显隐/顺序）
    // build138（#3）：这里曾有一串裸状态文字（原 `自动 / 中 (Medium)`），已删。
    // 它与提示条的「自动」、思考按钮角标是同一件事的三份表达，同屏最多三处；
    // 现在只留「提示条一处文字 + 按钮一处圆点」，具体档位由 tooltip / 弹层给。
    final functionButtons = _buildFunctionButtons(context, cs, l, isZh);
    final sendOrStop = _buildSendOrStop(context, isZh, cs);
    if (AppContent.isWide(context)) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          addButton,
          const SizedBox(width: AppGap.sm),
          ...functionButtons,
          const Spacer(),
          sendOrStop,
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        addButton,
        const Spacer(),
        ...functionButtons,
        const SizedBox(width: 2),
        sendOrStop,
      ],
    );
  }

  /// 发送 / 停止（生成中为「入队发送 + 停止」双按钮）
  ///
  /// build134：两态之间**交叉缩放淡入淡出**（120ms / easeOut，即 `AppDur.fast` +
  /// `AppCurve.morph` —— 这两个令牌的注释里写的就是「发送 ↔ 停止」，此前没人用）。
  /// 旧实现是 `if (config.isGenerating) return …; return …;`，按下瞬间整棵子树被
  /// 替换，观感是按钮「跳」了一下。AnimatedSwitcher 默认把新旧两帧叠在中心，
  /// 所以过渡期内不位移；宽度要到过渡结束才落到新态（双按钮比单按钮宽），
  /// 这点差异由父 Row 的右对齐吸收。
  Widget _buildSendOrStop(BuildContext context, bool isZh, ColorScheme cs) {
    return AnimatedSwitcher(
      duration: AppMotion.duration(context, AppDur.fast),
      switchInCurve: AppCurve.morph,
      switchOutCurve: AppCurve.morph,
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        // 交叉缩放：旧帧缩到 0.92 淡出、新帧从 0.92 放大淡入 ⇒ 同位置「换了件东西」
        // （0.92 取自规格 C3：幅度再大就会像「弹一下」，再小就看不出来）
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.92, end: 1.0).animate(anim),
          child: child,
        ),
      ),
      child: config.isGenerating
          ? Row(
              // key 必须区分两态：AnimatedSwitcher 靠它判定「child 换了」
              key: const ValueKey<String>('send-stop'),
              mainAxisSize: MainAxisSize.min,
              children: [
                // 发送按钮（补充消息入队）
                Semantics(
                  button: true,
                  label: isZh ? '加入队列并发送' : 'Queue message and send',
                  child: IconButton.filled(
                    onPressed: onSend,
                    icon: const Icon(Icons.arrow_upward, size: 20),
                    // build138（方案 B）：两态显式同色 —— `IconButton.filled` 的
                    // **默认底是 secondaryContainer**（icon_button.dart 的
                    // _FilledIconButtonDefaultsM3），不是 primary；原写法靠
                    // styleFrom 覆盖成了 primary，空闲态却漏了（真机上两态不同色，
                    // 按下还会「变色一下」）。
                    style: IconButton.styleFrom(
                      backgroundColor: cs.primary,
                      foregroundColor: cs.onPrimary,
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                const SizedBox(width: 2),
                // 停止按钮
                Semantics(
                  button: true,
                  label: isZh ? '停止生成' : 'Stop generating',
                  child: IconButton(
                    onPressed: onStop,
                    icon: const Icon(Icons.stop_circle_rounded, size: 24),
                    color: cs.error,
                    tooltip: isZh ? '停止生成' : 'Stop generating',
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            )
          : Semantics(
              key: const ValueKey<String>('send-idle'),
              button: true,
              label: isZh ? '发送' : 'Send',
              child: IconButton.filled(
                onPressed: onSend,
                icon: const Icon(Icons.arrow_upward),
                // 方案 B 的「全输入区唯一彩色」就落在这颗键上：显式写死 primary，
                // 不依赖 IconButton.filled 的默认档（默认是 secondaryContainer，
                // 中性偏暗，撑不起「主操作」的辨识度）。
                style: IconButton.styleFrom(
                  backgroundColor: cs.primary,
                  foregroundColor: cs.onPrimary,
                ),
                visualDensity: VisualDensity.compact,
              ),
            ),
    );
  }

  // ================ 功能按钮（搜索 / 思考 / 插件）================

  /// 按钮按 id 建表，再按 config.buttonOrder（设置页自定义显隐/顺序）渲染。
  /// build126（B1）：emoji 标签全部去掉 → 传 `label: null` 走纯图标形态，
  /// 由 ActionButton 内部用 `Semantics(label: tooltip)` 保证读屏可识别。
  List<Widget> _buildFunctionButtons(
      BuildContext context, ColorScheme cs, AppLocalizations l, bool isZh) {
    final buttons = <String, Widget>{
      // 模型选择器（需求5）
      //
      // build152（布局扫描 P1-1）：**必须包 Flexible**，否则长模型名把发送键顶出屏幕。
      // 判据来自 SDK 而非印象：`RenderFlex._computeSizes` 给非弹性子节点的约束是
      // 「交叉轴有界、主轴无限宽」⇒ `ModelSwitcher` 内部那个 `Flexible + maxLines:1 +
      // ellipsis` 落在 `canFlex == false` 分支，拿到无限宽，省略号**永远不触发**，
      // chip 宽度 = 模型名全长。真实样本：`Qwen3 Next 80B A23B Instruct`（28 字符）
      // 在 393dp 宽、四个按钮全开时约 120dp 可用文本宽里放不下 ⇒ 最右侧「发送/停止」
      // 被画到屏幕外，点它落进系统手势区 = **这条会话发不出消息**。
      // 类注释里写的「超屏才省略并包 Tooltip」原设计，缺的就是这一层有界约束。
      'model': Flexible(
        child: ModelSwitcher(
          availableConfigs: config.availableConfigs,
          // build138（G48）：账号表随配置一起下来，弹窗里同厂商多账号才有小标题可认
          accounts: config.availableAccounts,
          currentConfig: config.currentConfig,
          onModelChanged: actions.onModelChanged,
          isZh: isZh,
        ),
      ),
      // 搜索
      'search': ActionButton(
        icon: Icons.travel_explore,
        enabled: config.searchEnabled,
        active: config.searchEnabled && config.searchMode,
        tooltip: config.searchEnabled
            ? (config.searchMode ? l.tr('searchModeOn') : l.tr('searchModeOff'))
            : l.tr('searchDisabledHint'),
        onTap: config.isGenerating
            ? null
            : () {
                if (!config.searchEnabled) {
                  actions.onOpenSearchSettings?.call();
                } else {
                  actions.onToggleSearch?.call();
                }
              },
        onLongPress: (config.searchEnabled &&
                !config.isGenerating &&
                actions.onLongPressSearch != null)
            ? actions.onLongPressSearch
            : null,
      ),
      // 思考（v1.7.25：点按弹思考强度细化滑块；长按跳对话设置）
      'react': ActionButton(
        icon: Icons.psychology_alt_outlined,
        badge: config.reactEnabled
            ? (config.reasoningEffort <= 0
                ? 'DEF'
                : config.reasoningEffort >= 1.0
                    ? 'MAX'
                    : '${(config.reasoningEffort * 100).round()}%')
            : null,
        enabled: config.reactEnabled,
        active: config.reactEnabled &&
            (config.reactRounds > 0 || config.reactAutoMode),
        tooltip: config.reactEnabled
            ? (isZh
                ? '思考强度：${reasoningEffortLabel(config.reasoningEffort, true)}'
                : 'Reasoning effort: ${reasoningEffortLabel(config.reasoningEffort, false)}')
            : (isZh
                ? '需先打开联网搜索 + 自主思考'
                : 'Enable web search + autonomous thinking first'),
        onTap: config.isGenerating || !config.reactEnabled
            ? null
            : () => _showReasoningEffortPicker(
                context, actions, config.reasoningEffort),
        onLongPress: (config.reactEnabled &&
                !config.isGenerating &&
                actions.onLongPressReact != null)
            ? actions.onLongPressReact
            : null,
      ),
      // 插件（v1.7.17 三态）
      'plugin': ActionButton(
        icon: Icons.extension_outlined,
        enabled: !config.isGenerating,
        active: config.pluginHintMode != PluginHintMode.off,
        badge: _pluginHintBadge(),
        tooltip: _pluginHintTooltip(isZh),
        onTap: config.isGenerating ? null : actions.onTogglePluginHint,
        onLongPress: config.isGenerating ? null : actions.onEditPluginHint,
      ),
    };
    return [
      for (final id in config.buttonOrder)
        if (buttons.containsKey(id)) buttons[id]!,
    ];
  }

  /// 思考强度点按 → 统一底部弹层（0.0–1.0，0.1 步进；0=默认/自动，1.0=深度研究）
  ///
  /// build138（#6，Q2 已批）：由手搓的通用对话框（全 `lib/` 最后一处裸弹层）换成
  /// [showAppSheet]。原实现三个问题一次消掉：
  ///   · 靠「输入框上方 92 像素」这类魔法偏移与 0.92 屏宽手摆位置（输入框一改高度
  ///     就对不齐，而 #8 这次正是来改高度的）；
  ///   · 自绘 Material（elevation 4 / surfaceContainerHigh / 卡片圆角）与其它弹层
  ///     「每种弹层长得都不一样」；
  ///   · 深度研究档标题用渐变遮罩 + 两个硬编码色值画特效字（本文件仅存的 2 处
  ///     硬编码色，也是全 App 唯一一处渐变文字）⇒ 改 [AppSheetHeader] 的 titleMedium。
  /// 顺带把「改了就直接生效」改为**显式「取消 / 应用」**：拖动滑块的过程中不该写库。
  /// （⚠️ 上述被删掉的写法，测试按「本文件不得再出现」断言，注释里也别复现字面量。）
  Future<void> _showReasoningEffortPicker(
      BuildContext context, ChatInputActions actions, double current) async {
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    var effort = current;
    // v1.7.37：更大上下文 Max 开关并入本面板
    var largeCtx = config.largeContextMax;
    final picked = await showAppSheet<({double effort, bool largeCtx})>(
      context: context,
      scrollable: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppSheetHeader(
              title: effort >= 1.0
                  ? (isZh ? '深度研究 MAX' : 'Deep research MAX')
                  : (isZh ? '思考强度' : 'Reasoning effort'),
              subtitle: effort >= 1.0
                  ? (isZh
                      ? '多轮检索 · 交叉验证 · 深度推理 · 最多 80 轮，token 消耗显著增加'
                      : 'Multi-round search · cross-validation · deep reasoning · up to 80 rounds; token usage increases significantly')
                  : null,
            ),
            Slider(
              value: effort.clamp(0.0, 1.0),
              min: 0,
              max: 1,
              divisions: 10,
              onChanged: (v) => setSt(() {
                effort = double.parse(v.toStringAsFixed(1));
              }),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppGap.lg),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(isZh ? '默认 0.0' : 'Default 0.0',
                      style: const TextStyle(fontSize: 11)),
                  Text(isZh ? '中 0.5' : 'Medium 0.5',
                      style: const TextStyle(fontSize: 11)),
                  Text(isZh ? '深度 1.0' : 'Deep 1.0',
                      style: const TextStyle(fontSize: 11)),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppGap.lg),
              child: Text(
                isZh
                    ? '当前：${reasoningEffortLabel(effort, true)}'
                    : 'Current: ${reasoningEffortLabel(effort, false)}',
                style: TextStyle(
                    fontSize: 11, color: Theme.of(ctx).colorScheme.primary),
              ),
            ),
            const Divider(height: 16),
            // v1.7.37：更大上下文 Max（200K→1M），开 Max 时自动压缩不生效
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(
                isZh ? '更大上下文 Max' : 'Larger context Max',
                style: const TextStyle(fontSize: 13),
              ),
              subtitle: Text(
                isZh
                    ? '200K → 1M tokens；token 消耗更快；开启时自动压缩不生效'
                    : '200K → 1M tokens; consumes tokens faster; auto-compress disabled while on',
                style: const TextStyle(fontSize: 11),
              ),
              value: largeCtx,
              onChanged: (v) => setSt(() => largeCtx = v),
            ),
            AppSheetActions(
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(isZh ? '取消' : 'Cancel'),
                ),
                FilledButton(
                  onPressed: () =>
                      Navigator.pop(ctx, (effort: effort, largeCtx: largeCtx)),
                  child: Text(isZh ? '应用' : 'Apply'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    // 取消 / 下滑关闭 ⇒ picked 为 null ⇒ 一位都不改（build138：拖动过程不写库）
    if (picked == null) return;
    if (picked.effort != current) {
      actions.onReasoningEffortChanged?.call(picked.effort);
    }
    if (picked.largeCtx != config.largeContextMax) {
      actions.onLargeContextMaxChanged?.call(picked.largeCtx);
    }
  }

  // ================ 附件预览行（B1：移入框内）================

  Widget _buildAttachmentBar(BuildContext context, ColorScheme cs) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: config.pendingAttachments
          .map((a) => _buildAttachmentChip(context, a, cs))
          .toList(),
    );
  }

  Widget _buildAttachmentChip(
      BuildContext context, MessageAttachment a, ColorScheme cs) {
    final isImg = a.type == AttachmentType.image;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        // build138（#7）：原来 chip 底色与 composer 完全同色（都是
        // surfaceContainerHighest）⇒ 附件条像「没渲染」的一片糊色。composer 已改
        // appBubble(0.65)，这里改实色 surface ⇒ 附件浮在大框之上，层级自然拉开。
        color: cs.surface,
        borderRadius: BorderRadius.circular(AppRadius.panel),
        border: Border.all(color: cs.appBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isImg && a.localPath != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.inline),
              child: Image.file(
                File(a.localPath!),
                width: 28,
                height: 28,
                // build138（扫描 P2-4）：28dp 的缩略图此前不限宽解码，
                // 4000×3000 的相机原图整张进缓存（~48MB/张）。按 DPR 折算限宽。
                cacheWidth: decodeCacheWidth(context, 28),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    Icon(_iconFor(a), size: 18, color: cs.onSurfaceVariant),
              ),
            )
          else
            // build138（#2 同源口径）：图标去彩色 —— 方案 B 下输入区唯一彩色只留发送键
            Icon(_iconFor(a), size: 18, color: cs.onSurfaceVariant),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 120),
            child: Text(
              a.fileName,
              style: const TextStyle(fontSize: 11),
              // build152（布局扫描 L4）：`overflow: ellipsis` **单独写是不生效的** ——
              // `softWrap` 默认为真，文本会在 120dp 内换行而不是截断。
              // 真机样本 `Screenshot_20260923-071203_Nexus.jpg`（35 字符）会把 chip
              // 撑成 3–4 行，整个待发附件区与输入区跟着变高。
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (actions.onRemoveAttachment != null)
            InkWell(
              onTap: () => actions.onRemoveAttachment!(a),
              child: Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Icon(Icons.close, size: 14, color: cs.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }

  IconData _iconFor(MessageAttachment a) {
    switch (a.type) {
      case AttachmentType.image:
        return Icons.image_outlined;
      case AttachmentType.text:
        return Icons.description_outlined;
      case AttachmentType.doc:
        return Icons.article_outlined;
    }
  }

  // ================ 插件提示文案辅助 ================

  /// 英文界面下从双语标签 '低 (Low)' 取括号内英文部分
  static String _stripLabel(bool isZh, String label) {
    if (isZh) return label;
    final m = RegExp(r'\(([^)]+)\)').firstMatch(label);
    return m?.group(1) ?? label;
  }

  /// build138（#3）：原来这里还有一个「插件态后缀」函数（在提示条末尾再拼一段
  /// 「 · 自动」/「 · 手动(N)」）**已删除**。它会让同一条提示里出现两个「自动」
  /// （思考档 + 插件档），加上功能行的裸文字一共三处；插件态改由按钮圆点 +
  /// tooltip 承载，文案不再拼接。

  /// 插件按钮 badge（manual 显示勾选数，auto 显示 AUTO，off 无）
  String? _pluginHintBadge() {
    switch (config.pluginHintMode) {
      case PluginHintMode.off:
        return null;
      case PluginHintMode.manual:
        return '${config.pluginHintManualCount}';
      case PluginHintMode.auto:
        return 'AUTO';
    }
  }

  /// 插件按钮 tooltip
  String _pluginHintTooltip(bool isZh) {
    switch (config.pluginHintMode) {
      case PluginHintMode.off:
        return isZh ? '插件提示：关闭' : 'Plugin hint: off';
      case PluginHintMode.manual:
        return isZh
            ? '插件提示：手动（${config.pluginHintManualCount} 项已勾选）'
            : 'Plugin hint: manual (${config.pluginHintManualCount} selected)';
      case PluginHintMode.auto:
        return isZh ? '插件提示：自动' : 'Plugin hint: auto';
    }
  }
}

/// build166：正文只在**整数行真的变了**的那一帧重建。
///
/// 为什么要有这一层（第十一轮数出来的那笔账）：行数改成跟着引擎逐帧走以后，
/// 抬起的每一帧都会重算一次行数，而一帧里真正变到的只有 `minLines` 这一个整数 ——
/// 旧写法（自带 200ms 补间）一轮开键要重建正文约 48 次、每次重排用户正在打的整段文本，
/// 而高度真变的只有 3 次。**每帧一次不叫修好**，所以这一层把重建次数钉回档位数
/// （判据：`test/build166_composer_progress_test.dart` 的实例身份计数）。
///
/// 机制是框架自己的短路，不是我们自己攒子树：`Element.updateChild` 在
/// `child.widget == newWidget` 时**复用元素、连 update 都不调用**
/// （SDK `flutter/lib/src/widgets/framework.dart` 那行注释的原话是
/// "widgets that \"don't update\" (because they didn't change)"）。
/// 所以行数没变就把**同一个 widget 实例**交回去，整棵正文（含 `EditableText`
/// 的文本布局）根本不参与这一帧。
///
/// 缓存必须能被"行数以外的变化"打掉，否则这里会把旧提示文案或旧回调留在树上 ——
/// 那是比多重建几次严重得多的错。[inputs] 就是正文构建时读到的**其余全部**输入
/// （见 `_buildTextField` 调用点那一份表）：任一项不等就重建。
/// 逐项用 `==` 比较而不是比 List 的身份：这些值（AppLocalizations / ColorScheme /
/// controller / config / actions）在**同一帧的连续重建之间**身份稳定，
/// 只有真换了主题、语言、输入框配置时才会变。
///
/// 与"第二个尺寸所有者"那条闸的关系（build156 / D3 禁用名单）：这一层**不读任何布局
/// 结果、不做裁剪、没有时长**，它只是把同一个 widget 实例再交回去一次。
/// 高度仍然只有 `TextField` 的 `minLines..maxLines` 一个所有者。
class _ComposerLines extends StatefulWidget {
  const _ComposerLines({
    required this.lines,
    required this.inputs,
    required this.builder,
  });

  /// 本帧该画几行（`composerMinLines(progress:)` 的**输出**，已经夹进 maxLines）。
  final int lines;

  /// 正文构建时读到的其余输入 —— 变了就必须重建（防缓存把旧文案/旧回调留住）。
  final List<Object?> inputs;

  /// 真正建正文：拿到行数，交回 `TextField`。
  final Widget Function(int lines) builder;

  @override
  State<_ComposerLines> createState() => _ComposerLinesState();
}

class _ComposerLinesState extends State<_ComposerLines> {
  int? _builtLines;
  List<Object?>? _builtInputs;
  Widget? _built;

  static bool _sameInputs(List<Object?> a, List<Object?> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final cached = _built;
    final builtInputs = _builtInputs;
    if (cached != null &&
        builtInputs != null &&
        _builtLines == widget.lines &&
        _sameInputs(builtInputs, widget.inputs)) {
      return cached;
    }
    _builtLines = widget.lines;
    // 存一份拷贝：调用点每帧新建那个 List，留着引用会把"上一帧的输入"当成"这一帧的"。
    _builtInputs = List<Object?>.of(widget.inputs);
    return _built = widget.builder(widget.lines);
  }
}
