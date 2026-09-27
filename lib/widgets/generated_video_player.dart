import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../services/platform_capabilities.dart';

/// 已生成视频的本地播放器（基于 package:video_player）。
///
/// 为什么拆成独立组件：视频页历史列表里可能同时存在多个可播放项，每个都各自持有
/// 一个原生 [VideoPlayerController]。拆出来后每个实例只管自己的生命周期——
/// [dispose] 里**必须** `controller.dispose()`，否则原生播放器句柄泄漏、
/// 后台继续占用解码器（项目铁律：原生资源/定时器必须在 dispose 释放）。
class GeneratedVideoPlayer extends StatefulWidget {
  final File file;

  const GeneratedVideoPlayer({super.key, required this.file});

  @override
  State<GeneratedVideoPlayer> createState() => _GeneratedVideoPlayerState();
}

class _GeneratedVideoPlayerState extends State<GeneratedVideoPlayer> {
  // 桌面闸门（M2）：video_player 没有 Windows/Linux 实现，不支持的平台
  // 根本不创建控制器（否则 MissingPluginException），直接渲染降级占位。
  final bool _unsupported = !PlatformCapabilities.supportsVideoPlayer;
  VideoPlayerController? _controller;
  bool _initialized = false;
  bool _hasError = false;
  // 标记组件是否已卸载：initialize 是异步的，跨过 await 后 widget 可能已被
  // 移除，此时绝不能 setState（否则 "setState after dispose" 崩溃）。
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    if (_unsupported) return;
    _controller = VideoPlayerController.file(widget.file);
    _init();
  }

  Future<void> _init() async {
    try {
      await _controller!.initialize();
      // 异步初始化完成后必须查 mounted/disposed，防止对已卸载的 widget  setState
      if (_disposed || !mounted) return;
      setState(() => _initialized = true);
    } catch (e) {
      if (_disposed || !mounted) return;
      setState(() => _hasError = true);
    }
  }

  void _togglePlay() {
    if (!_initialized) return;
    final controller = _controller!;
    // 播放/暂停是同步切换，无需查 mounted
    if (controller.value.isPlaying) {
      controller.pause();
    } else {
      controller.play();
    }
    setState(() {});
  }

  @override
  void dispose() {
    // 铁律：原生播放器句柄必须在此释放，否则句柄泄漏 + 后台持续占用解码资源
    _disposed = true;
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final cs = Theme.of(context).colorScheme;

    if (_unsupported) {
      // 降级占位（M2）：明确告诉用户是平台不支持，而不是文件坏了——
      // 两种情况的处置完全不同（去文件管理器打开 vs 重新生成）。
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(Icons.videocam_off_outlined, color: cs.outline),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                isZh
                    ? '当前平台暂不支持应用内播放视频，请到文件所在目录用系统播放器打开'
                    : 'In-app video playback is not supported on this platform. '
                        'Open the file with a system player instead.',
                style: TextStyle(color: cs.outline),
              ),
            ),
          ],
        ),
      );
    }
    if (_hasError) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: cs.errorContainer.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(Icons.broken_image_outlined, color: cs.error),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                isZh
                    ? '视频加载失败（文件可能已损坏或被清理）'
                    : 'Failed to load video (file may be corrupted or cleared).',
                style: TextStyle(color: cs.error),
              ),
            ),
          ],
        ),
      );
    }

    if (!_initialized) {
      // 未初始化完先给个占位，避免布局跳动
      return const AspectRatio(
        aspectRatio: 16 / 9,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    // 走到这里一定过了能力闸门且初始化成功，控制器非空。
    final controller = _controller!;
    return Column(
      children: [
        AspectRatio(
          aspectRatio: controller.value.aspectRatio,
          child: VideoPlayer(controller),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            IconButton(
              tooltip: isZh ? '播放/暂停' : 'Play/Pause',
              icon: Icon(
                controller.value.isPlaying
                    ? Icons.pause_circle_outline
                    : Icons.play_circle_outline,
                color: cs.primary,
              ),
              onPressed: _togglePlay,
            ),
            Expanded(
              child: VideoProgressIndicator(
                controller,
                allowScrubbing: true,
                colors: VideoProgressColors(
                  playedColor: cs.primary,
                  bufferedColor: cs.surfaceContainerHighest,
                  backgroundColor: cs.surfaceContainerLow,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
