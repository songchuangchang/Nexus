import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// build104（M3）：GitHub Device Flow 登录（RFC 8628）。
///
/// 为什么选 Device Flow 而不是网页回调 OAuth：
/// - 不需要 WebView、不需要处理回调跳转、不需要把 client_secret 打进包里；
/// - 体验 = 显示一个 user code，用户在任意设备上打开
///   github.com/login/device 输码授权，App 轮询拿 token。
///
/// ⚠️ 前置：需在 GitHub 创建一个 OAuth App（勾选 Enable Device Flow），
/// 把 client_id 填进 [clientId]。client_id 不是机密（网页可见），但为避免
/// 占用无效值导致误导性报错，留空时 [start] 返回明确错误。
///
/// 令牌存 flutter_secure_storage（Android Keystore 加密），键 [tokenKey]。
/// GitHub OAuth App 令牌默认不过期；撤销走设置里的「断开连接」。
class GitHubDeviceFlow {
  GitHubDeviceFlow._();

  /// GitHub OAuth App 的 Client ID（需勾选 Enable Device Flow）。
  ///
  /// **B-004 修复**：改为构建期注入，不再留空占位——
  ///   flutter build apk --release --dart-define=GITHUB_OAUTH_CLIENT_ID=Iv1.xxxx
  /// 留空（默认）时 [isConfigured] 为 false，UI 据此隐藏/禁用登录入口并说明原因，
  /// 而不是让用户点到一个必然抛「尚未配置 Client ID」的按钮。
  static const String clientId = String.fromEnvironment(
    'GITHUB_OAUTH_CLIENT_ID',
    defaultValue: '',
  );

  /// B-004：是否已配置 Client ID（UI 据此决定「输码授权」入口的显隐）
  static bool get isConfigured => clientId.isNotEmpty;

  static const _deviceCodeUrl = 'https://github.com/login/device/code';
  static const _tokenUrl = 'https://github.com/login/oauth/access_token';
  static const tokenKey = 'github_device_flow_token';

  static const _storage = FlutterSecureStorage();

  static Future<String?> getStoredToken() =>
      _storage.read(key: tokenKey);

  static Future<void> deleteStoredToken() =>
      _storage.delete(key: tokenKey);

  /// 发起授权：返回 (userCode, verificationUri, 轮询间隔秒, deviceCode)。
  ///
  /// **B-011 修复**：RFC 8628 响应里有**两个不同的码**——
  /// `device_code`（长串，仅用于客户端轮询换 token）与 `user_code`（短码，
  /// 给人输）。旧实现丢掉了 device_code，UI 只能拿 user_code 当 device_code
  /// 去轮询 → GitHub 必然返回错误或一直 authorization_pending，配了 clientId
  /// 也永远拿不到 token。现完整返回两者。
  ///
  /// 失败抛 [DeviceFlowException]，message 为用户可读文案。
  static Future<
      ({
        String userCode,
        String verificationUri,
        int interval,
        String deviceCode
      })> start() async {
    if (clientId.isEmpty) {
      throw const DeviceFlowException(
          '尚未配置 GitHub OAuth App 的 Client ID（需勾选 Enable Device Flow），'
          '见 RELEASENOTES/连接器指南。');
    }
    final resp = await _post(_deviceCodeUrl, {
      'client_id': clientId,
      'scope': 'repo read:user',
    });
    final j = _decodeJsonObject(resp, 'device code 响应');
    if (j['error'] != null) {
      throw DeviceFlowException('GitHub 返回错误：${j['error']}');
    }
    final userCode = j['user_code'] as String? ?? '';
    // B-011：必须保留 device_code（轮询专用），与展示用的 user_code 严格区分
    final deviceCode = j['device_code'] as String? ?? '';
    final verificationUri = j['verification_uri'] as String? ??
        'https://github.com/login/device';
    final interval = (j['interval'] as num?)?.toInt() ?? 5;
    if (userCode.isEmpty) throw const DeviceFlowException('GitHub 未返回 user_code');
    if (deviceCode.isEmpty) {
      throw const DeviceFlowException('GitHub 未返回 device_code（授权无法继续）');
    }
    return (
      userCode: userCode,
      verificationUri: verificationUri,
      interval: interval,
      deviceCode: deviceCode,
    );
  }

  /// 按给定节奏轮询令牌，直到授权成功/过期/被取消。
  /// [isCancelled] 由 UI 的取消按钮置位。
  /// 返回 access token 并自动写入安全存储；用户拒绝/过期抛 [DeviceFlowException]。
  static Future<String> pollForToken({
    required String deviceCode,
    required int intervalSeconds,
    required bool Function() isCancelled,
    Duration overallTimeout = const Duration(minutes: 10),
  }) async {
    final deadline = DateTime.now().add(overallTimeout);
    var interval = intervalSeconds;
    while (!isCancelled()) {
      if (DateTime.now().isAfter(deadline)) {
        throw const DeviceFlowException('授权超时（10 分钟未完成），请重试。');
      }
      await Future<void>.delayed(Duration(seconds: interval));
      if (isCancelled()) throw const DeviceFlowException('已取消');
      final resp = await _post(_tokenUrl, {
        'client_id': clientId,
        'device_code': deviceCode,
        'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
      });
      final j = _decodeJsonObject(resp, 'token 轮询响应');
      final token = j['access_token'] as String?;
      if (token != null && token.isNotEmpty) {
        await _storage.write(key: tokenKey, value: token);
        return token;
      }
      final error = j['error'] as String? ?? '';
      switch (error) {
        case 'authorization_pending':
          break; // 用户还没输完码，继续轮询
        case 'slow_down':
          interval += 5;
          break;
        case 'expired_token':
          throw const DeviceFlowException('授权码已过期，请重新发起登录。');
        case 'access_denied':
          throw const DeviceFlowException('你在 GitHub 上拒绝了授权。');
        default:
          throw DeviceFlowException('GitHub 返回错误：$error');
      }
    }
    throw const DeviceFlowException('已取消');
  }

  static Future<String> _post(String url, Map<String, String> body) async {
    try {
      final resp = await http
          .post(Uri.parse(url),
              headers: const {
                'Accept': 'application/json',
                'Content-Type': 'application/x-www-form-urlencoded',
              },
              body: body.entries
                  .map((e) =>
                      '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
                  .join('&'))
          .timeout(const Duration(seconds: 30));
      return utf8.decode(resp.bodyBytes, allowMalformed: true);
    } on TimeoutException {
      throw const DeviceFlowException(
          '连接 github.com 超时（当前网络可能无法直连 GitHub）。');
    } catch (e) {
      throw DeviceFlowException(
          '网络请求失败：当前网络可能无法访问 github.com。$e');
    }
  }

  /// 解析 GitHub 返回的 JSON 对象，失败一律转成 [DeviceFlowException]。
  ///
  /// 全量缺陷扫描修复：此前 [start] / [pollForToken] 直接写
  /// `jsonDecode(resp) as Map<String, dynamic>`，与两个方法的文档承诺
  /// （「失败抛 [DeviceFlowException]」）不符，会把**技术原始异常**漏到 UI：
  ///   · 链路被代理/网关拦截返回 HTML → `FormatException`；
  ///   · 返回 JSON 数组/标量 → `TypeError`（注意它属 `Error` 而非 `Exception`，
  ///     调用方写 `on Exception` 是**兜不住**的，会一直冒到 FutureBuilder）。
  /// 这里统一收敛，同时把「不是 JSON」这个最可能的网络诱因写进文案。
  static Map<String, dynamic> _decodeJsonObject(String resp, String what) {
    Object? decoded;
    try {
      decoded = jsonDecode(resp);
    } on FormatException catch (e) {
      throw DeviceFlowException(
          '$what 不是合法 JSON（可能被代理或网关拦截）：${e.message}');
    }
    if (decoded is! Map<String, dynamic>) {
      throw DeviceFlowException(
          '$what 结构异常：期望 JSON 对象，实际为 ${decoded.runtimeType}');
    }
    return decoded;
  }
}

class DeviceFlowException implements Exception {
  final String message;
  const DeviceFlowException(this.message);
  @override
  String toString() => message;
}
