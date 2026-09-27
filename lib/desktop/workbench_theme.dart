/// B1.5 桌面工作台视觉层（方向：zcode / workbuddy 那种干净克制的
/// 专业代码工具感——紧凑排版、发丝级分隔线、低饱和强调色）。
///
/// 这一层是桌面端「颜色 / 字号 / 间距 / 控件尺寸」的唯一所有者：
/// lib/desktop 下的界面代码不再散落 Color(0x…) 与 fontSize 字面量，
/// 统一从这里取（M-1 口径乙不变：本层零 Duration、零动画对象，
/// 悬停反馈一律瞬时换色，不开 splash、不开过渡）。
library;

import 'package:flutter/material.dart';

/// 桌面工作台尺寸令牌。
abstract final class WbSize {
  static const double toolbarH = 40;
  static const double sidebarW = 264;
  static const double agentPanelW = 420;
  static const double gitPanelH = 260;
  static const double fileHeaderH = 30;
  static const double treeRowH = 24;
  static const double treeIndent = 14;

  /// 树行末 git 状态槽宽（S2：`U` / `•`）。
  static const double treeBadgeW = 16;
}

/// 桌面工作台配色。亮暗各一套，实例不可变，[WbColors.of] 按主题取。
class WbColors {
  const WbColors({
    required this.windowBg,
    required this.sidebarBg,
    required this.panelBg,
    required this.border,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.accent,
    required this.accentSoft,
    required this.rowHover,
    required this.rowSelected,
    required this.ok,
    required this.warn,
    required this.warnSoft,
    required this.danger,
  });

  /// 窗口底色 / 侧栏底色 / 卡片与面板底色 / 发丝分隔线。
  final Color windowBg;
  final Color sidebarBg;
  final Color panelBg;
  final Color border;

  /// 三级文字：正文 / 次级说明 / 弱化（行号、占位）。
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;

  /// 低饱和强调色与其浅底（选中态、链接、主按钮文字）。
  final Color accent;
  final Color accentSoft;

  /// 行级悬停 / 选中底（瞬时切换，无动画）。
  final Color rowHover;
  final Color rowSelected;

  /// 状态色：通过 / 提醒（及其浅底）/ 危险。
  final Color ok;
  final Color warn;
  final Color warnSoft;
  final Color danger;

  static WbColors of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;

  static const WbColors light = WbColors(
    windowBg: Color(0xFFFAFAF9),
    sidebarBg: Color(0xFFF4F4F2),
    panelBg: Color(0xFFFFFFFF),
    border: Color(0xFFE4E4E0),
    textPrimary: Color(0xFF1F2328),
    textSecondary: Color(0xFF6A7078),
    textTertiary: Color(0xFF9BA1A8),
    accent: Color(0xFF0E7A8A),
    accentSoft: Color(0x1A0E7A8A),
    rowHover: Color(0x0A1F2328),
    rowSelected: Color(0x1A0E7A8A),
    ok: Color(0xFF1A7F37),
    warn: Color(0xFF9A6700),
    warnSoft: Color(0x149A6700),
    danger: Color(0xFFB42318),
  );

  // S3：默认套改深色，值取 GitHub Dark 系（低饱和，和 ZCode/Qoder 同一观感族）。
  static const WbColors dark = WbColors(
    windowBg: Color(0xFF0D1117),
    sidebarBg: Color(0xFF161B22),
    panelBg: Color(0xFF1C2128),
    border: Color(0xFF21262D),
    textPrimary: Color(0xFFE6EDF3),
    textSecondary: Color(0xFF9AA4B2),
    textTertiary: Color(0xFF6E7681),
    accent: Color(0xFF2E9BAE),
    accentSoft: Color(0x242E9BAE),
    rowHover: Color(0x0AFFFFFF),
    rowSelected: Color(0x242E9BAE),
    ok: Color(0xFF3FB950),
    warn: Color(0xFFD29922),
    warnSoft: Color(0x1FD29922),
    danger: Color(0xFFF85149),
  );
}

/// 代码着色令牌。色值和界面色一样，只准出现在这一处
/// （test/desktop_theme_test.dart 有 grep 闸）；[CodePalette] 只是按主题取这里的值。
abstract final class WbSyntax {
  // 暗色：VS Code Dark+ 系，低饱和久看不累；gutter/行号跟深色底同族。
  static const Color darkKeyword = Color(0xFF569CD6);
  static const Color darkString = Color(0xFFCE9178);
  static const Color darkComment = Color(0xFF6A9955);
  static const Color darkNumber = Color(0xFFB5CEA8);
  static const Color darkIdent = Color(0xFFD4D4D4);
  static const Color darkPunct = Color(0xFFD4D4D4);
  static const Color darkGutter = Color(0xFF161B22);
  static const Color darkLineNo = Color(0xFF6E7681);

  // 亮色：GitHub Light 系，比 VS Code 亮的纯蓝/纯绿更克制。
  static const Color lightKeyword = Color(0xFFCF222E);
  static const Color lightString = Color(0xFF0A3069);
  static const Color lightComment = Color(0xFF6E7781);
  static const Color lightNumber = Color(0xFF0550AE);
  static const Color lightIdent = Color(0xFF1F2328);
  static const Color lightPunct = Color(0xFF1F2328);
  static const Color lightGutter = Color(0xFFF6F6F4);
  static const Color lightLineNo = Color(0xFF9BA1A8);
}

/// 桌面工作台字号/字体令牌。颜色一律由调用方按 [WbColors] 上。
abstract final class WbText {
  static const TextStyle ui11 = TextStyle(fontSize: 11, height: 1.3);
  static const TextStyle ui12 = TextStyle(fontSize: 12, height: 1.3);
  static const TextStyle ui13 = TextStyle(fontSize: 13, height: 1.3);

  /// 代码与路径等宽体。
  static const TextStyle code13 = TextStyle(
    fontFamily: 'Consolas',
    fontFamilyFallback: ['Cascadia Mono', 'Courier New', 'monospace'],
    fontSize: 13,
    height: 1.35,
  );
  static const TextStyle code12 = TextStyle(
    fontFamily: 'Consolas',
    fontFamilyFallback: ['Cascadia Mono', 'Courier New', 'monospace'],
    fontSize: 12,
    height: 1.35,
  );
}

/// 工作台子树的主题覆盖：不动全 App 主题（手机端那套原样），
/// 只在桌面工作台这一支换底色、发丝线、关 splash、收紧密度。
///
/// S3：桌面**默认深色**（两家参照物都是深色优先），浅色保留可切；
/// 明暗由调用方传 [dark]，不再跟随外层 Theme 的 brightness。
ThemeData wbTheme(BuildContext context, {bool dark = true}) {
  final c = dark ? WbColors.dark : WbColors.light;
  final base = Theme.of(context);
  return base.copyWith(
    brightness: dark ? Brightness.dark : Brightness.light,
    scaffoldBackgroundColor: c.windowBg,
    dividerColor: c.border,
    splashFactory: NoSplash.splashFactory,
    highlightColor: const Color(0x00000000),
    visualDensity: VisualDensity.compact,
    colorScheme: base.colorScheme.copyWith(
      primary: c.accent,
      surface: c.windowBg,
      onSurface: c.textPrimary,
      onSurfaceVariant: c.textSecondary,
      outline: c.border,
      error: c.danger,
    ),
  );
}

/// 工具栏按钮：图标+文字的紧凑件。悬停瞬时换底（MouseRegion + setState），
/// 无 InkWell 水波纹、无过渡——符合 M-1 口径乙「零动画对象」。
class WbToolButton extends StatefulWidget {
  const WbToolButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  /// true = 面板已展开，按钮保持浅底（瞬时态，不是动画）。
  final bool active;

  @override
  State<WbToolButton> createState() => _WbToolButtonState();
}

class _WbToolButtonState extends State<WbToolButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = WbColors.of(context);
    final enabled = widget.onPressed != null;
    final fg = !enabled
        ? c.textTertiary
        : widget.active
            ? c.accent
            : c.textSecondary;
    final bg = widget.active
        ? c.accentSoft
        : _hover && enabled
            ? c.rowHover
            : const Color(0x00000000);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, size: 15, color: fg),
              const SizedBox(width: 5),
              Text(widget.label, style: WbText.ui12.copyWith(color: fg)),
            ],
          ),
        ),
      ),
    );
  }
}
