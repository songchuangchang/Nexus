import 'package:url_launcher/url_launcher.dart';
import '../services/biometric_service.dart';
import '../services/launch_uri_normalizer.dart' as launch_uri;
import '../services/logger_service.dart';

/// 外链打开公共工具（v1.7.18 抽自 api_config_edit_screen._openUrl 模式）
///
/// 统一所有「在系统浏览器打开外链」的场景：
/// - 安全审查设置页 MobSF/SkillSpector/VirusTotal 官网（需求4）
/// - API 配置编辑页服务商官网（可选去重）
/// - 后续新增的外链场景
///
/// B1（N-9）：URL 归一（解析 + 非 ASCII percent-encode）**收口到唯一入口**
/// `normalizeLaunchUri`（见 services/launch_uri_normalizer.dart）。此前
/// interact_card 的支付/导航第三通道是裸 `Uri.tryParse` + `launchUrl`、
/// deep_link_markdown 生成的 markdown 链也未编码——同一语义各写一份必漏
/// （教训 #62）。所有通道一律经本类或该纯函数，禁止裸 Uri.tryParse→launchUrl。
///
/// 注意：conversation_list_screen 的「下载文件夹」走 SAF content:// scheme，
/// 仍是原 launchUrl 调用，不属于本工具职责（不同场景，勿强行统一）。
class LauncherUtils {
  static final _logger = LoggerService.instance;

  /// B1：外链归一入口（委托纯函数，便于单测）。
  ///
  /// 解析 → 产出 percent-encode 后的规范 URI（Dart `Uri` 自带 UTF-8 编码，
  /// 逗号等结构字符保留）。无效输入返回 null。
  static Uri? normalizeLaunchUri(String raw) =>
      launch_uri.normalizeLaunchUri(raw).uri;

  /// 在系统浏览器中打开指定 URL。
  ///
  /// 流程：归一（含编码）→ canLaunchUrl 守卫 → LaunchMode.externalApplication 打开。
  /// 返回 true 表示成功唤起系统浏览器，false 表示无法打开（调用方可弹 SnackBar 兜底）。
  static Future<bool> openExternalUrl(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      _logger.warn('[Launcher] openExternalUrl: empty url', tag: 'Launcher');
      return false;
    }
    // B1：统一归一入口（原实现内联 _percentEncodeNonAscii，现收口到纯函数）
    final normalized = launch_uri.normalizeLaunchUri(trimmed);
    final uri = normalized.uri;
    if (normalized.isInvalid || uri == null) {
      _logger.warn('[Launcher] openExternalUrl: invalid uri "$trimmed"',
          tag: 'Launcher');
      return false;
    }
    if (normalized.wasRewritten) {
      _logger.info('[Launcher] normalized non-ASCII uri: $uri', tag: 'Launcher');
    }
    try {
      // canLaunchUrl 守卫：部分 Android 设备对外链 scheme 查询受限，
      // 守卫失败时仍尝试直接 launchUrl（externalApplication），给一次机会。
      final canLaunch = await canLaunchUrl(uri);
      if (!canLaunch) {
        _logger.info('[Launcher] canLaunchUrl=false for "$trimmed"，仍尝试直接打开',
            tag: 'Launcher');
      }
      final ok = await BiometricService.guardActivityTransition(
        () => launchUrl(uri, mode: LaunchMode.externalApplication),
        fallbackDuration: const Duration(seconds: 120),
      );
      if (!ok) {
        _logger.warn('[Launcher] launchUrl returned false for "$trimmed"',
            tag: 'Launcher');
      } else {
        // W3：点击与 launch 结果都可观测（此前成功无日志，真机无法定位「跳不动」）
        _logger.info('[Launcher] opened OK: $trimmed', tag: 'Launcher');
      }
      return ok;
    } catch (e, st) {
      _logger.error('[Launcher] openExternalUrl 失败: $e',
          error: e, stack: st, tag: 'Launcher');
      return false;
    }
  }
}
