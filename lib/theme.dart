import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

class AppTheme {
  // v1.4.2：把紫色主题改成蓝绿色，对话框/输入框更清晰可见
  static const _seed = Color(0xFF006874);

  /// build133：全 App 统一页面转场。
  ///
  /// 为什么全局改、而不是把 30 处 `Navigator.push(MaterialPageRoute(...))` 逐个换成
  /// `AppPageRoute`：逐个替换是 30 次改动，而且**以后新增页面一定会漏** —— 「转场不一致」
  /// 恰恰是最容易在新增页面时复发的毛病。改默认 builder 一次覆盖全部。
  ///
  /// 取值理由：
  /// - Android/桌面 → [FadeUpwardsPageTransitionsBuilder]：淡入 + 轻微上移，克制，
  ///   与「内容从下方接着长出来」的聊天观感一致；
  /// - iOS/macOS → [CupertinoPageTransitionsBuilder]：保留侧滑返回手势。
  ///
  /// ⚠️ **这张表是整表替换，不是「只覆盖列出的平台」** —— `ThemeData` 把 builders
  /// 整个交给 `PageTransitionsTheme`，缺项的平台会走框架的兜底分支
  /// （`page_transitions_theme.dart`：*"If a builder for the current platform is not
  /// found, then the ZoomPageTransitionsBuilder is used"*），**不是**保持系统默认。
  /// 所以 iOS/macOS 必须**显式写出来**：漏写的后果不是「沿用 Cupertino」，而是
  /// 「iOS 被悄悄换成 Zoom、侧滑返回转场丢掉」。
  ///
  /// 另一处**已知代价**：本 SDK 里 Android 的框架默认是
  /// `PredictiveBackPageTransitionsBuilder`（Android 14+ 返回手势预览），
  /// 这里换成 FadeUpwards ⇒ **预测式返回的预览动画不再出现**。
  /// 二者不可兼得（Flutter 没有「FadeUpwards + 预测式返回」的现成 builder），
  /// 当前取舍：优先全 App 转场一致 + 克制形态。
  ///
  /// 需要单独控制时长/形态的页面仍可用 `AppPageRoute`（lib/ui/app_page_route.dart）显式覆盖。
  static const PageTransitionsTheme _transitions = PageTransitionsTheme(
    builders: <TargetPlatform, PageTransitionsBuilder>{
      TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
      TargetPlatform.fuchsia: FadeUpwardsPageTransitionsBuilder(),
      TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
      TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
      // 显式列出，防止回退 Zoom（见上方 ⚠️）
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
    },
  );

  static ThemeData get darkTheme {
    const scheme = ColorScheme.dark(
      primary: Color(0xFF4FD8EB),
      onPrimary: Color(0xFF003840),
      primaryContainer: Color(0xFF004F59),
      onPrimaryContainer: Color(0xFF7FF4FF),
      secondary: Color(0xFFBCCDDB),
      onSecondary: Color(0xFF1A333E),
      secondaryContainer: Color(0xFF334B57),
      onSecondaryContainer: Color(0xFFD8E9F4),
      tertiary: Color(0xFFC8D6F4),
      onTertiary: Color(0xFF1A2F55),
      tertiaryContainer: Color(0xFF334672),
      onTertiaryContainer: Color(0xFFDCE1FF),
      error: Color(0xFFF2B8B5),
      onError: Color(0xFF601410),
      errorContainer: Color(0xFF8C1D18),
      onErrorContainer: Color(0xFFF9DEDC),
      surface: Color(0xFF0F1316),
      onSurface: Color(0xFFDDE3E8),
      onSurfaceVariant: Color(0xFFBFC5CB),
      surfaceContainerHighest: Color(0xFF333B3F),
      surfaceContainerHigh: Color(0xFF283034),
      surfaceContainer: Color(0xFF1F272B),
      surfaceContainerLow: Color(0xFF171E22),
      outline: Color(0xFF8D9499),
      outlineVariant: Color(0xFF434A4E),
      brightness: Brightness.dark,
    );
    return ThemeData(
      useMaterial3: true,
      pageTransitionsTheme: _transitions,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 2,
        backgroundColor: scheme.surfaceContainer,
        foregroundColor: scheme.onSurface,
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerHigh,
        elevation: 1,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        surfaceTintColor: Colors.transparent,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainer,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: scheme.primary,
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      textTheme: TextTheme(
        bodyLarge: TextStyle(color: scheme.onSurface),
        bodyMedium: TextStyle(color: scheme.onSurface),
        bodySmall: TextStyle(color: scheme.onSurfaceVariant),
        titleLarge:
            TextStyle(color: scheme.onSurface, fontWeight: FontWeight.bold),
        titleMedium:
            TextStyle(color: scheme.onSurface, fontWeight: FontWeight.w600),
        titleSmall:
            TextStyle(color: scheme.onSurface, fontWeight: FontWeight.w600),
        headlineSmall:
            TextStyle(color: scheme.onSurface, fontWeight: FontWeight.bold),
      ),
      // v1.4.2：文本选择高亮改成青蓝色，比紫色更明显
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: scheme.primary,
        selectionColor: scheme.primary.withValues(alpha: 0.35),
        selectionHandleColor: scheme.primary,
      ),
    );
  }

  static ThemeData get lightTheme {
    const scheme = ColorScheme.light(
      primary: _seed,
      onPrimary: Colors.white,
      primaryContainer: Color(0xFF97F0FF),
      onPrimaryContainer: Color(0xFF001F24),
      secondary: Color(0xFF4A6267),
      onSecondary: Colors.white,
      secondaryContainer: Color(0xFFCDE7EC),
      onSecondaryContainer: Color(0xFF051F23),
      tertiary: Color(0xFF525E7D),
      onTertiary: Colors.white,
      tertiaryContainer: Color(0xFFDAE2FF),
      onTertiaryContainer: Color(0xFF0E1B37),
      error: Color(0xFFBA1A1A),
      onError: Colors.white,
      errorContainer: Color(0xFFFFDAD6),
      onErrorContainer: Color(0xFF410002),
      surface: Color(0xFFFAFDFD),
      onSurface: Color(0xFF191C1D),
      onSurfaceVariant: Color(0xFF3F484A),
      surfaceContainerHighest: Color(0xFFDDE4E6),
      surfaceContainerHigh: Color(0xFFE7EBED),
      surfaceContainer: Color(0xFFEEF2F3),
      surfaceContainerLow: Color(0xFFF4F7F8),
      outline: Color(0xFF6F797B),
      outlineVariant: Color(0xFFBFC8CA),
    );
    return ThemeData(
      useMaterial3: true,
      pageTransitionsTheme: _transitions,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 2,
        backgroundColor: scheme.surfaceContainer,
        foregroundColor: scheme.onSurface,
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerLow,
        elevation: 1,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        surfaceTintColor: Colors.transparent,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainer,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: scheme.primary,
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      textTheme: TextTheme(
        bodyLarge: TextStyle(color: scheme.onSurface),
        bodyMedium: TextStyle(color: scheme.onSurface),
        bodySmall: TextStyle(color: scheme.onSurfaceVariant),
        titleLarge:
            TextStyle(color: scheme.onSurface, fontWeight: FontWeight.bold),
        titleMedium:
            TextStyle(color: scheme.onSurface, fontWeight: FontWeight.w600),
        titleSmall:
            TextStyle(color: scheme.onSurface, fontWeight: FontWeight.w600),
        headlineSmall:
            TextStyle(color: scheme.onSurface, fontWeight: FontWeight.bold),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: scheme.primary,
        selectionColor: scheme.primary.withValues(alpha: 0.35),
        selectionHandleColor: scheme.primary,
      ),
    );
  }
}
