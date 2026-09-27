import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'logger_service.dart';

/// build98：厂商图标磁盘缓存。
///
/// 背景（build97 实测）：VendorAvatar 直连 google.com/s2/favicons，国内
/// 返回空白占位图（HTTP 200 但内容是空白图）→ API 配置页一排纯白方块；
/// 且 Flutter 对失败网络图不缓存，流式高频重建反复请求被墙域名。
///
/// 机制：
/// - 图标 URL 由远程模板 JSON 的 iconUrl 字段下发（远程更新），内置模板
///   为空 → 直接用品牌色块内置图标（离线保底，永无白块）。
/// - 下载成功写入 supportDir/vendor_icons/<md5(url)>.png，进程内记忆命中；
/// - 下载失败/内容可疑（<128 字节、PNG 魔数不符、http 协议）记入失败集合，
///   App 生命周期内不重试。
///
/// build100 三项加固：
/// - 下载在途去重：同 URL 并发请求复用同一个 Future（首屏多张同图或顶栏
///   rebuild 不再重复请求）；
/// - PNG 魔数校验：>128 字节但非真实 PNG（HTML 错误页/JSON 401 响应）会
///   走错误页路径，被 cache 缓存后永不重下且解码失败——改为校验 0x89PNG
///   头后才落盘；
/// - HTTPS 强校验：远程模板下发的 iconUrl 必须 https；http 视为不安全
///   直接拒收（内置常量本身已是 https，主要防御未来远程 JSON 下发 http
///   链接的场景，避免中间人替换 + 私网 SSRF 风险）。
class VendorIconCache {
  VendorIconCache._();
  static final VendorIconCache instance = VendorIconCache._();

  /// 进程级解析结果记忆（url → File；null 值表示失败）
  final Map<String, File?> _memory = {};

  /// build100：同 URL 下载在途复用，防止首屏多个 FutureBuilder 并发请求
  final Map<String, Future<File?>> _inFlight = {};

  /// 测试专用：清空进程记忆 + 在途
  @visibleForTesting
  void clearMemory() {
    _memory.clear();
    _inFlight.clear();
  }

  /// 内容下界：小于该字节数视为空白占位图/错误页，不缓存
  static const int minIconBytes = 128;

  /// build100：PNG 文件魔数（前 4 字节）。CDN 偶尔返回 200 + HTML/JSON 错误
  /// 页（403/404 透传、网关维护页）字节数 > 128 但不是图，解码必败且永不重下。
  static const List<int> _kPngMagic = [0x89, 0x50, 0x4E, 0x47]; // ‰PNG

  /// 解析图标本地文件；未缓存时后台下载。失败返回 null（调用方显示内置保底）。
  Future<File?> resolve(String url) async {
    if (url.isEmpty) return null;
    // build100：拒收非 https 协议（防御远程模板下发 http/SSRF）
    if (!url.startsWith('https://')) {
      LoggerService.instance.warn(
          '[VendorIcon] reject non-https url: $url',
          tag: 'VendorIcon');
      _memory[url] = null;
      return null;
    }
    if (_memory.containsKey(url)) return _memory[url];
    // build100：在途去重——同 URL 并发共享同一个 Future
    final existing = _inFlight[url];
    if (existing != null) return existing;
    final future = _doResolve(url);
    _inFlight[url] = future;
    try {
      return await future;
    } finally {
      _inFlight.remove(url);
    }
  }

  Future<File?> _doResolve(String url) async {
    try {
      final dir = await _iconDir();
      final file =
          File(p.join(dir.path, '${md5.convert(utf8.encode(url))}.png'));
      if (await file.exists() && await _isValidPngFile(file)) {
        _memory[url] = file;
        return file;
      }
      final resp = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 10));
      final bytes = resp.bodyBytes;
      if (resp.statusCode != 200) {
        LoggerService.instance.warn(
            '[VendorIcon] reject HTTP ${resp.statusCode}: $url',
            tag: 'VendorIcon');
      } else if (bytes.length < minIconBytes) {
        LoggerService.instance.warn(
            '[VendorIcon] reject too-small ${bytes.length}B: $url',
            tag: 'VendorIcon');
      } else if (!_isValidPngBytes(bytes)) {
        LoggerService.instance.warn(
            '[VendorIcon] reject bad PNG magic ${bytes.length}B: $url',
            tag: 'VendorIcon');
      } else {
        await file.writeAsBytes(bytes, flush: true);
        _memory[url] = file;
        return file;
      }
    } catch (e) {
      LoggerService.instance.warn('[VendorIcon] download failed: $url ($e)',
          tag: 'VendorIcon');
    }
    _memory[url] = null;
    return null;
  }

  /// build100：磁盘缓存命中时再校一次 PNG 魔数（防御历史上以错误页缓存
  /// 落盘后被复用）。
  Future<bool> _isValidPngFile(File f) async {
    if (await f.length() < minIconBytes) return false;
    try {
      final raf = await f.open();
      try {
        final head = await raf.read(_kPngMagic.length);
        return _isValidPngBytes(head);
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

  static bool _isValidPngBytes(List<int> bytes) {
    if (bytes.length < _kPngMagic.length) return false;
    for (var i = 0; i < _kPngMagic.length; i++) {
      if (bytes[i] != _kPngMagic[i]) return false;
    }
    return true;
  }

  Future<Directory> _iconDir() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'vendor_icons'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }
}
