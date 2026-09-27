import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/shared_payload.dart';
import 'logger_service.dart';

/// build123：接收「外部 App 分享到 Nexus」的载荷。
///
/// ## 为什么走自建 MethodChannel 而不是引三方包
/// 需求只有三件事：冷启动取一次载荷、运行中收推送、文件先落私有目录。
/// 三方分享插件普遍需要改 `launchMode` 语义、带自己的 FileProvider 与生命周期假设，
/// 而本项目对「新增依赖」有明确代价（`pub add` 会触发 pub get 删掉 l10n 生成产物，
/// 已复现两次）。自建通道只有 ~150 行 Kotlin，行为完全可控。
///
/// ## 载荷为什么不「就地消费」
/// 分享到达时用户可能：①冷启动 ②已在某个聊天页 ③在设置页。
/// 三种情况的目标会话可能不同（最近会话 vs 当前会话），所以本服务只负责
/// **收下并广播**，由 UI 层决定插到哪里——服务不猜导航意图。
class ShareIntentService {
  ShareIntentService._();

  static final ShareIntentService instance = ShareIntentService._();

  static const MethodChannel _channel = MethodChannel('nexus/share_intent');

  final LoggerService _logger = LoggerService.instance;

  final StreamController<SharedPayload> _controller =
      StreamController<SharedPayload>.broadcast();

  /// 尚无订阅者时先存这里（防止「分享先到、UI 后订阅」丢载荷）
  SharedPayload? _buffered;

  /// 冷启动载荷（`takeInitial` 会清空，保证只处理一次）
  SharedPayload? _initial;

  bool _initialized = false;

  /// 运行中的分享事件（已打开 App 时收到分享）
  Stream<SharedPayload> get stream => _controller.stream;

  /// 初始化：注册原生回调。可重复调用（幂等）。
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onShare') {
        final payload =
            SharedPayload.fromMap((call.arguments as Map?)?.cast<Object?, Object?>());
        if (payload != null) _emit(payload);
      }
      return null;
    });
    // 冷启动载荷：原生侧在 Dart 未就绪时会先缓冲，这里主动取一次
    try {
      final raw = await _channel.invokeMethod<Object?>('getInitialShare');
      final payload =
          SharedPayload.fromMap((raw as Map?)?.cast<Object?, Object?>());
      if (payload != null) {
        _initial = payload;
        _logger.info('[Share] 冷启动收到分享 ${payload.describe()}',
            cat: LogCat.app, tag: 'Share');
      }
    } catch (e) {
      // 平台通道不可用（如非 Android）不算错误，静默降级为「无分享」
      _logger.info('[Share] 分享通道不可用：$e', cat: LogCat.app, tag: 'Share');
    }
  }

  /// 取走冷启动载荷（只返回一次）。
  ///
  /// 与 [drainBuffered] 一起构成「不丢也不重」的取件口：
  /// 冷启动走原生缓冲，运行中走 [stream]；若事件早于订阅到达，
  /// [_emit] 会先存进 [_buffered]，由 [drainBuffered] 补取。
  SharedPayload? takeInitial() {
    final p = _initial;
    _initial = null;
    return p;
  }

  /// 取走「订阅之前就已到达」的运行中载荷（只返回一次）。
  SharedPayload? drainBuffered() {
    final p = _buffered;
    _buffered = null;
    return p;
  }

  void _emit(SharedPayload p) {
    _logger.info('[Share] 运行中收到分享 ${p.describe()}',
        cat: LogCat.app, tag: 'Share');
    if (_controller.hasListener) {
      _controller.add(p);
    } else {
      _buffered = p;
    }
  }

  // ---------------------------------------------------------------------------
  // 「当前已打开该会话」时直接投递到输入框（避免压出重复的 ChatScreen）
  // ---------------------------------------------------------------------------

  /// conversationId → 插入回调（由 ChatScreen 注册）
  final Map<String, void Function(SharedPayload)> _inserters = {};

  void registerInserter(String conversationId, void Function(SharedPayload) fn) {
    _inserters[conversationId] = fn;
  }

  void unregisterInserter(String conversationId) {
    _inserters.remove(conversationId);
  }

  /// 若该会话正开着，直接把载荷插进它的输入框并返回 true；否则 false（由调用方导航）。
  bool deliverToOpenChat(String conversationId, SharedPayload payload) {
    final fn = _inserters[conversationId];
    if (fn == null) return false;
    fn(payload);
    return true;
  }

  @visibleForTesting
  void resetForTest() {
    _initial = null;
    _buffered = null;
    _inserters.clear();
  }
}
