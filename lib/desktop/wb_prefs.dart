/// P5：工作台窗口级小设置的持久化封装。载体复用 app 现有机制
/// （shared_preferences，pubspec ^2.3.2，主数据仍走 SQLite 不动）。
/// 口径：读失败/无记录一律返回 null，由调用方落默认（规格 §3 默认暗）；
/// 写失败静默——偏好读写不该弹错或拖垮工作台启动。
library;

import 'package:shared_preferences/shared_preferences.dart';

class WbPrefs {
  static const _kDark = 'wb_dark';

  /// 明暗记录；null = 无记录或读失败（调用方落默认暗）。
  static Future<bool?> readDark() async {
    try {
      final sp = await SharedPreferences.getInstance();
      return sp.getBool(_kDark);
    } catch (_) {
      return null;
    }
  }

  /// 切换即写；写失败静默（下次启动回落默认，与「无记录」体验一致）。
  static Future<void> writeDark(bool dark) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(_kDark, dark);
    } catch (_) {
      // 静默：偏好写失败不值得打断用户。
    }
  }
}
