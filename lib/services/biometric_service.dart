import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'logger_service.dart';

class BiometricService {
  BiometricService._();

  static final _auth = LocalAuthentication();
  static final _logger = LoggerService.instance;

  /// v1.7.30：标记 App 内原生 Activity 跳转（相机/相册/文档选择器/外链/文件打开），
  /// 避免 didChangeAppLifecycleState 误判为"从后台返回"而重新触发生物锁。
  ///
  /// **B-003 修复：内部改为深度计数，不再用单个 bool。**
  /// 旧实现在跳转重叠时会互相踩：先发起 120s 兜底的外链跳转 A（如安装 APK 后
  /// 打开外部应用），其停留期间又发生一次 2s 兜底的相册/文件选择 B；B 结束 2s
  /// 后把标志清成 false，而 A 的外部停留尚未结束 —— App 恢复前台时被误判为
  /// 「从后台返回」，误弹生物锁（与该标志要消除的误锁正好相反）。
  /// 计数制下只有全部跳转都结束（depth 归零）才解除保护。
  static int _activityDepth = 0;

  /// 是否有 App 内原生跳转正在进行（main.dart 的 didChangeAppLifecycleState 读它）
  static bool get inAppActivityTransition => _activityDepth > 0;

  /// 开始一次 App 内跳转（须与 [endActivityTransition] 配对）
  static void beginActivityTransition() {
    _activityDepth++;
  }

  /// 结束一次 App 内跳转（计数归零才真正解除保护）
  static void endActivityTransition() {
    if (_activityDepth > 0) _activityDepth--;
  }

  /// 包裹会拉起原生 Activity 的异步操作，设置标志避免返回时重新上锁。
  ///
  /// - startActivityForResult 风格（image_picker, FilePicker）：await 阻塞到用户返回，
  ///   onResume 紧随 onActivityResult，2 秒兜底足够。
  /// - fire-and-forget 风格（url_launcher, OpenFilex）：await 立即返回，
  ///   需更长兜底覆盖用户在外部 App 的短暂停留（默认 120 秒）。
  static Future<T> guardActivityTransition<T>(
    Future<T> Function() action, {
    Duration fallbackDuration = const Duration(seconds: 2),
  }) async {
    beginActivityTransition();
    try {
      return await action();
    } finally {
      // B-003：只递减计数，不再无条件清零 —— 长跳转的保护不会被短跳转提前解掉
      Future.delayed(fallbackDuration, endActivityTransition);
    }
  }

  /// v1.7.36：可用性放宽——无指纹/面部的设备只要有系统锁屏（PIN/图案/密码）
  /// 也视为可用（isDeviceSupported 含设备凭据），应用锁 UI 不再整个消失。
  static Future<bool> get isAvailable async {
    try {
      return await _auth.isDeviceSupported() || await _auth.canCheckBiometrics;
    } on PlatformException catch (e) {
      _logger.warn('Biometric check failed: $e', tag: 'BIOMETRIC');
      return false;
    }
  }

  static Future<List<BiometricType>> get availableBiometrics async {
    try {
      return await _auth.getAvailableBiometrics();
    } on PlatformException {
      return [];
    }
  }

  static Future<bool> authenticate({required String reason}) async {
    try {
      final canCheck = await isAvailable;
      if (!canCheck) {
        _logger.warn('Biometric not available on this device',
            tag: 'BIOMETRIC');
        return false;
      }
      // v1.7.36：biometricOnly 改 false，无指纹设备自动降级为系统锁屏
      // PIN/图案/密码验证（local_auth 在 biometricOnly:false 时允许设备凭据）。
      final didAuth = await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false,
        ),
      );
      _logger.app('Biometric auth result: $didAuth');
      return didAuth;
    } on PlatformException catch (e) {
      _logger.error('Biometric auth error: $e', tag: 'BIOMETRIC');
      return false;
    }
  }

  static String get biometricTypeName {
    return 'biometric';
  }
}
