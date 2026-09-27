import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

/// 桌面能力登记表（M2，docs/DESKTOP_PROJECT_BRIEF_20260924.md §8）。
///
/// 每个能力的判据来自插件自己 pubspec.yaml 的 platforms 声明（2026-09-24 从
/// 本机 pub cache 逐字核对）：
/// - google_mlkit_text_recognition 0.16.0：android / ios
/// - video_player 2.14.0：android / ios / macos / web
/// - open_filex 4.7.0：android / ios
///
/// Windows / Linux 上这三个插件都没有实现。不设闸门的话调用会在运行期炸
/// MissingPluginException，炸点离用户操作很远、无法定位；有闸门就能在能力边界
/// 提前返回明确的「不支持」，走各自的降级路径。
class PlatformCapabilities {
  PlatformCapabilities._();

  /// 测试注入：非 null 时代替 Platform.operatingSystem 的判定输入。
  /// 生产代码永远是 null；测试结束必须调 [resetDebugOverride]，否则会污染
  /// 同进程的其他测试。
  @visibleForTesting
  static String? debugOperatingSystem;

  @visibleForTesting
  static void resetDebugOverride() => debugOperatingSystem = null;

  static String get os =>
      debugOperatingSystem ?? (kIsWeb ? 'web' : Platform.operatingSystem);

  static bool get isDesktop =>
      os == 'windows' || os == 'linux' || os == 'macos';

  /// 本机 OCR（ML Kit 文字识别）：插件只声明 android / ios。
  static bool get supportsOnDeviceOcr => os == 'android' || os == 'ios';

  /// 视频播放（video_player）：android / ios / macos / web。
  static bool get supportsVideoPlayer =>
      os == 'android' || os == 'ios' || os == 'macos' || os == 'web';

  /// 系统「打开方式」（open_filex）：插件只声明 android / ios。
  /// Windows 的等价物是 explorer.exe，走 FileOpenService 的降级分支。
  static bool get supportsOpenFilex => os == 'android' || os == 'ios';
}
