import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/api_config.dart';
import '../models/chat_message.dart';
import '../models/video_task.dart';
import '../screens/api_config_screen.dart';
import '../services/attachment_service.dart';
import '../services/logger_service.dart';
import '../services/storage_service.dart';
import '../services/video_gen_service.dart';
import '../utils/app_snackbar.dart';
import '../widgets/generated_video_player.dart';
import '../ui/image_decode.dart';

/// 视频生成页（UI + 接线，服务层见 [VideoGenService] / [VideoTask]）。
///
/// 关键点：
/// - 视频是**任务制**（提交→轮询→下载），且**按秒计费、pro 更贵**，所以成本确认
///   框必须显著写出「时长 × 模式」；
/// - 提交后立刻把 [VideoTask] 落库（钱花了不能白花，且上游 URL 仅 24h 有效）；
/// - 页面内用单一 [Timer.periodic] 每 10s 轮询所有未终态任务，completed 立刻
///   下载落盘；**Timer 必须在 dispose 里 cancel**（项目铁律）；
/// - **启动续查**：initState 读 [StorageService.getPendingVideoTasks]，未到终态
///   的任务自动恢复轮询（用户切后台/杀进程回来仍能拿到成品）。
class VideoGenScreen extends StatefulWidget {
  const VideoGenScreen({super.key});

  @override
  State<VideoGenScreen> createState() => _VideoGenScreenState();
}

class _VideoGenScreenState extends State<VideoGenScreen> {
  late final StorageService _storage;

  List<ApiConfig> _configs = [];
  ApiConfig? _selectedConfig;

  final _promptController = TextEditingController();
  int _seconds = 5; // 5 / 10
  String _size = '1280x720'; // 横屏 / 竖屏
  String _mode = 'std'; // std / pro

  bool _busy = false;
  List<VideoTask> _tasks = [];

  /// build129：图生视频的参考图（null = 纯文生视频）。
  /// 存 MessageAttachment 而非 base64：base64 可能到几 MB，常驻内存没必要，
  /// 提交那一刻现转（[AttachmentService.imageToBase64]）。
  MessageAttachment? _refImage;

  /// build129：参考图原始字节上限。上游对 input_reference 普遍限制 10MB 上下，
  /// 这里取 8MB——超过就直接拦在本地，避免「等 1~5 分钟换来一个 400」。
  static const int _maxRefImageBytes = 8 * 1024 * 1024;

  /// 单一轮询定时器（负责所有未终态任务）。dispose 必须 cancel。
  Timer? _pollTimer;
  /// 轮询重入保护：生成可能比 10s 间隔更慢，防止上一轮未完又触发。
  bool _isPolling = false;

  static final LoggerService _logger = LoggerService.instance;

  static const List<String> _sizes = [
    '1280x720',
    '1920x1080',
    '720x1280',
  ];

  @override
  void initState() {
    super.initState();
    _storage = context.read<StorageService>();
    _loadConfigs();
    _loadTasks();
    // 启动轮询：单个 Timer 轮询所有未终态任务；间隔 10s
    _pollTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _pollAll(),
    );
  }

  Future<void> _loadConfigs() async {
    final list = await _storage.getApiConfigs();
    if (!mounted) return;
    setState(() {
      _configs = list;
      _selectedConfig = list.isNotEmpty ? list.first : null;
    });
  }

  /// 载入历史 + 续查未终态任务（启动续查）。
  Future<void> _loadTasks() async {
    final history = await _storage.getVideoTasks(limit: 50);
    final pending = await _storage.getPendingVideoTasks();
    if (!mounted) return;
    // 历史已含 pending（pending 是未终态子集）；用 map 去重，pending 兜底补遗漏
    final map = <String, VideoTask>{};
    for (final t in history) {
      map[t.id] = t;
    }
    for (final t in pending) {
      map.putIfAbsent(t.id, () => t);
    }
    final list = map.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    setState(() => _tasks = list);
  }

  @override
  void dispose() {
    // 铁律：Timer 必须在此 cancel，否则页面销毁后回调仍跑 → setState on unmounted
    _pollTimer?.cancel();
    _pollTimer = null;
    _promptController.dispose();
    super.dispose();
  }

  /// 按 apiConfigId 找回提交时用过的配置（换 key/删配置后可能找不到）。
  ApiConfig? _configFor(String id) {
    try {
      return _configs.firstWhere((c) => c.id == id);
    } catch (_) {
      return null;
    }
  }

  /// build129：选一张参考图（图生视频）。
  ///
  /// 为什么在本地就拦大小：图生视频要传 base64（体积 ×1.33），超限时上游只会回一个
  /// 语焉不详的 400，而视频提交本身要等 1~5 分钟——先拦住比事后报错便宜得多。
  Future<void> _pickRefImage() async {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final att = await AttachmentService().pickImageFromGallery();
    if (!mounted || att == null) return;
    var size = att.sizeBytes ?? 0;
    if (size == 0 && att.localPath != null) {
      try {
        size = await File(att.localPath!).length();
      } catch (_) {
        size = 0; // 读不到大小就不拦（交给上游判断），不因体检失败阻断主流程
      }
    }
    if (size > _maxRefImageBytes) {
      _toast(isZh
          ? '参考图太大（${(size / 1024 / 1024).toStringAsFixed(1)}MB > '
              '${_maxRefImageBytes ~/ (1024 * 1024)}MB），请先压缩再试'
          : 'Reference image too large (max ${_maxRefImageBytes ~/ (1024 * 1024)}MB)');
      return;
    }
    if (!mounted) return;
    setState(() => _refImage = att);
  }

  Future<void> _submit() async {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final config = _selectedConfig;
    if (config == null) {
      _toast(isZh ? '请先选择一个 API 配置' : 'Select an API config first');
      return;
    }
    if (_promptController.text.trim().isEmpty) {
      _toast(isZh ? '提示词不能为空' : 'Prompt cannot be empty');
      return;
    }

    // 视频按秒计费、pro 更贵——成本确认框必须显著写出「时长 × 模式」
    final confirmed = await _confirmVideoCost(isZh, config);
    if (!confirmed) return;

    if (!mounted) return;
    setState(() => _busy = true);
    try {
      // build129：有参考图则现转 base64（图生视频）；失败不静默降级为文生视频
      // ——用户明明选了图，悄悄不传等于骗他。
      String? refB64;
      final refImg = _refImage;
      if (refImg != null) {
        refB64 = await AttachmentService().imageToBase64(refImg);
        if (refB64 == null || refB64.isEmpty) {
          if (mounted) {
            setState(() => _busy = false);
            _toast(isZh ? '参考图读取失败（文件可能已被清理），请重新选择' : 'Failed to read the reference image');
          }
          return;
        }
      }
      if (!mounted) return;
      final snap = await VideoGenService.submit(
        config,
        prompt: _promptController.text.trim(),
        seconds: _seconds,
        size: _size,
        mode: _mode,
        inputImageBase64: refB64,
      );
      if (!mounted) return;
      // 为什么立刻落库：视频是异步任务 + 上游 URL 24h 有效，先存盘才能在
      // 切后台/杀进程后回来续查续下，钱花了不能白花。
      final task = VideoTask.create(
        apiConfigId: config.id,
        remoteTaskId: snap.id,
        prompt: _promptController.text.trim(),
        // build129：存**实际使用的**视频模型（此前存 config.model = 对话模型，
        // 任务卡上显示的模型名与实际调用的不一致，排障时会把人带偏）。
        model: config.effectiveVideoModel,
        seconds: _seconds,
        size: _size,
        mode: _mode,
        state: snap.state.name,
      );
      await _storage.saveVideoTask(task);
      if (!mounted) return;
      setState(() => _tasks.insert(0, task));
    } on VideoGenException catch (e) {
      if (!mounted) return;
      // 面向用户只给 message；detail 仅进日志
      _logger.warn('video submit failed: ${e.detail ?? e.message}', tag: 'VideoGen');
      _toast(e.message);
    } catch (e) {
      if (!mounted) return;
      _logger.error('video submit unexpected: $e', tag: 'VideoGen');
      _toast(isZh ? '提交失败：$e' : 'Submit failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 轮询所有未终态任务：query → 更新本地 task → 刷新 UI；completed 立刻下载落盘。
  Future<void> _pollAll() async {
    if (_isPolling) return; // 防止上一轮未完成又触发（Timer 间隔 10s）
    _isPolling = true;
    try {
      final pending = _tasks.where((t) => !t.isTerminal).toList();
      if (pending.isEmpty) return;
      for (final t in pending) {
        if (!mounted) return;
        final config = _configFor(t.apiConfigId);
        if (config == null) {
          // 配置被删：无法续查，跳过（保留原状态，用户可手动删除）
          _logger.warn('video poll skip: config ${t.apiConfigId} missing',
              tag: 'VideoGen');
          continue;
        }
        VideoTaskSnapshot snap;
        try {
          snap = await VideoGenService.query(config, t.remoteTaskId);
        } catch (e) {
          // 单次轮询失败（网络抖动常见）不应中断整轮——记日志，下次再试
          _logger.warn('video poll query failed: $e', tag: 'VideoGen');
          continue;
        }

        // 先按状态更新内存与本地库
        var updated = t.copyWith(
          state: snap.state.name,
          resultUrl: snap.resultUrl,
          errorMessage: snap.errorMessage,
          updatedAt: DateTime.now(),
        );

        // 到 completed 且有 URL：立刻下载落盘（赶在 24h 过期前，避免结果永久丢失）
        if (snap.state == VideoTaskState.completed) {
          if (snap.resultUrl == null || snap.resultUrl!.isEmpty) {
            updated = updated.copyWith(
              state: 'failed',
              errorMessage: '任务完成但未返回结果 URL',
            );
          } else if (updated.localPath.isEmpty) {
            try {
              final file = await VideoGenService.download(
                snap.resultUrl!,
                taskId: t.remoteTaskId,
              );
              updated = updated.copyWith(localPath: file.path);
            } catch (e) {
              _logger.error('video download failed: $e', tag: 'VideoGen');
              // 下载失败不把任务判失败（URL 24h 内还能再试），仅记日志
            }
          }
        }

        await _storage.updateVideoTask(updated);
        if (!mounted) return;
        setState(() {
          final idx = _tasks.indexWhere((x) => x.id == updated.id);
          if (idx >= 0) _tasks[idx] = updated;
        });
      }
    } finally {
      _isPolling = false;
    }
  }

  Future<void> _deleteTask(VideoTask task) async {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isZh ? '删除该视频任务？' : 'Delete this video task?'),
        content: Text(isZh
            ? '将删除本地记录${task.isReady ? '与已下载的视频文件' : ''}。'
            : 'This deletes the local record${task.isReady ? ' and the downloaded video' : ''}.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(isZh ? '取消' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(isZh ? '删除' : 'Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _storage.deleteVideoTask(task.id);
    // 已落盘的成品一并清理（失败任务无本地文件，try/catch 兜底）
    if (task.isReady) {
      try {
        await File(task.localPath).delete();
      } catch (_) {
        // 文件可能已被手动清理，忽略
      }
    }
    if (!mounted) return;
    setState(() => _tasks.removeWhere((t) => t.id == task.id));
  }

  Future<void> _openSettings() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ApiConfigScreen()),
    );
    if (!mounted) return;
    _loadConfigs();
  }

  Future<bool> _confirmVideoCost(bool isZh, ApiConfig config) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isZh ? '确认生成视频' : 'Confirm Video Generation'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 显著提示：视频按秒计费、pro 更贵
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Theme.of(ctx)
                      .colorScheme
                      .errorContainer
                      .withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  isZh
                      ? '视频按秒计费，pro 模式更贵。将按「时长 × 模式」扣额度。'
                      : 'Video is billed per second; pro mode costs more. '
                          'You will be charged by "duration × mode".',
                  style: TextStyle(
                    color: Theme.of(ctx).colorScheme.error,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _kv(isZh ? '时长' : 'Duration', '$_seconds s'),
              _kv(
                isZh ? '模式' : 'Mode',
                _mode == 'pro'
                    ? (isZh ? 'pro（更贵）' : 'pro (costlier)')
                    : (isZh ? 'std' : 'std'),
              ),
              _kv(isZh ? '分辨率' : 'Resolution', _size),
              // build129：显示**实际使用**的视频模型（effectiveVideoModel），
              // 而不是对话模型——成本框是用户唯一能复核模型的时机。
              _kv(isZh ? '模型' : 'Model', config.effectiveVideoModel),
              if (_refImage != null)
                _kv(isZh ? '参考图' : 'Ref image',
                    '${_refImage!.fileName}${isZh ? '（图生视频）' : ' (image-to-video)'}'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(isZh ? '取消' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(isZh ? '继续' : 'Continue'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  void _toast(String msg) {
    if (!mounted) return;
    AppSnackBar.showSnackBar(
      context,
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Widget _kv(String label, String value) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(label,
                style: TextStyle(
                    color: cs.onSurfaceVariant, fontWeight: FontWeight.w600)),
          ),
          Expanded(child: Text(value, style: TextStyle(color: cs.onSurface))),
        ],
      ),
    );
  }

  /// 任务状态的中文/英文标签。
  String _stateLabel(VideoTask t, bool isZh) {
    switch (t.state) {
      case 'queued':
        return isZh ? '排队中' : 'Queued';
      case 'processing':
        return isZh ? '生成中' : 'Processing';
      case 'completed':
        return isZh ? '已完成' : 'Completed';
      case 'failed':
        return isZh ? '失败' : 'Failed';
      default:
        return isZh ? '未知' : 'Unknown';
    }
  }

  /// 单条历史任务卡片（含状态、播放器、删除）。
  Widget _buildTaskCard(VideoTask t, bool isZh) {
    final cs = Theme.of(context).colorScheme;
    final summary = t.prompt.length > 40
        ? '${t.prompt.substring(0, 40)}…'
        : t.prompt;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    summary.isEmpty ? (isZh ? '（无提示词）' : '(no prompt)') : summary,
                    style: Theme.of(context).textTheme.bodyMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: isZh ? '删除' : 'Delete',
                  icon: Icon(Icons.delete_outline, color: cs.error),
                  onPressed: () => _deleteTask(t),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${_stateLabel(t, isZh)} · ${t.seconds}s · ${t.mode} · ${t.size}',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
            ),
            // 下载中提示（completed 但还没落盘）
            if (t.state == 'completed' && t.localPath.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  isZh ? '下载中…' : 'Downloading…',
                  style: TextStyle(color: cs.primary, fontSize: 12),
                ),
              ),
            // 失败原因
            if (t.state == 'failed' && t.errorMessage.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  t.errorMessage,
                  style: TextStyle(color: cs.error, fontSize: 12),
                ),
              ),
            // 已完成且已落盘 → 播放器
            if (t.isReady)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: GeneratedVideoPlayer(file: File(t.localPath)),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(isZh ? 'AI 视频' : 'AI Video'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(isZh ? 'API 配置' : 'API config',
                style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 6),
            DropdownButton<ApiConfig>(
              value: _selectedConfig,
              isExpanded: true,
              hint: Text(isZh ? '选择 API 配置' : 'Select API config'),
              items: _configs
                  .map((c) => DropdownMenuItem(
                        value: c,
                        child: Text('${c.name} · ${c.model}'),
                      ))
                  .toList(),
              onChanged: (c) => setState(() => _selectedConfig = c),
            ),

            if (_selectedConfig != null && !_selectedConfig!.supportVideoGen)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, color: cs.onSurfaceVariant),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          isZh
                              ? '当前配置未开启「视频生成」能力位。若确定该端点支持，可前往设置手动开启；不拦截你继续尝试。'
                              : 'This config has not enabled the video-gen capability. '
                                  'If you know the endpoint supports it, enable it in Settings; we won\'t block you.',
                          style: TextStyle(color: cs.onSurfaceVariant),
                        ),
                      ),
                      TextButton(
                        onPressed: _openSettings,
                        child: Text(isZh ? '去设置' : 'Settings'),
                      ),
                    ],
                  ),
                ),
              ),

            const SizedBox(height: 16),
            Text(isZh ? '提示词' : 'Prompt',
                style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 6),
            TextField(
              controller: _promptController,
              maxLines: 4,
              minLines: 2,
              decoration: InputDecoration(
                hintText: isZh ? '描述你想生成的视频…' : 'Describe the video…',
                border: const OutlineInputBorder(),
              ),
            ),

            const SizedBox(height: 16),
            // build129：图生视频（参考图）。
            // 此前 VideoGenService.submit 早已支持 input_reference，但**没有任何调用方
            // 传过**它 —— 能力存在却无人能用到，等同上线即弃。
            Row(
              children: [
                Icon(Icons.add_photo_alternate_outlined,
                    size: 18, color: cs.onSurfaceVariant),
                const SizedBox(width: 6),
                Text(
                  isZh ? '参考图（可选，图生视频）' : 'Reference image (optional)',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ],
            ),
            const SizedBox(height: 6),
            if (_refImage == null)
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _pickRefImage,
                  icon: const Icon(Icons.photo_library_outlined, size: 18),
                  label: Text(isZh ? '选择图片' : 'Pick image'),
                ),
              )
            else
              Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.file(
                      File(_refImage!.localPath!),
                      width: 56,
                      height: 56,
                      // build138（扫描 P2-4）：参考图缩略图限宽解码
                      cacheWidth: decodeCacheWidth(context, 56),
                      fit: BoxFit.cover,
                      // 文件被系统清理时不崩，退回占位图标
                      errorBuilder: (_, __, ___) => Container(
                        width: 56,
                        height: 56,
                        color: cs.surfaceContainerHighest,
                        child: Icon(Icons.broken_image_outlined,
                            size: 20, color: cs.onSurfaceVariant),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _refImage!.fileName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                  IconButton(
                    tooltip: isZh ? '移除参考图' : 'Remove',
                    onPressed:
                        _busy ? null : () => setState(() => _refImage = null),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),

            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(isZh ? '时长' : 'Duration',
                          style: Theme.of(context).textTheme.labelMedium),
                      const SizedBox(height: 6),
                      DropdownButton<int>(
                        value: _seconds,
                        isExpanded: true,
                        items: const [
                          DropdownMenuItem(value: 5, child: Text('5 s')),
                          DropdownMenuItem(value: 10, child: Text('10 s')),
                        ],
                        onChanged: (v) {
                          if (v != null) setState(() => _seconds = v);
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(isZh ? '模式' : 'Mode',
                          style: Theme.of(context).textTheme.labelMedium),
                      const SizedBox(height: 6),
                      DropdownButton<String>(
                        value: _mode,
                        isExpanded: true,
                        items: const [
                          DropdownMenuItem(
                              value: 'std', child: Text('std')),
                          DropdownMenuItem(
                              value: 'pro', child: Text('pro（更贵）')),
                        ],
                        onChanged: (v) {
                          if (v != null) setState(() => _mode = v);
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),
            Text(isZh ? '分辨率' : 'Resolution',
                style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 6),
            DropdownButton<String>(
              value: _size,
              isExpanded: true,
              items: _sizes
                  .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                  .toList(),
              onChanged: (v) {
                if (v != null) setState(() => _size = v);
              },
            ),

            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _busy ? null : _submit,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.movie_creation_outlined),
                label: Text(_busy
                    ? (isZh ? '提交中…' : 'Submitting…')
                    : (isZh ? '生成视频' : 'Generate video')),
              ),
            ),

            if (_busy)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: LinearProgressIndicator(),
              ),

            const SizedBox(height: 24),
            Text(isZh ? '历史任务' : 'History',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            if (_tasks.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Center(
                  child: Text(
                    isZh ? '还没有视频任务' : 'No video tasks yet',
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                ),
              )
            else
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _tasks.length,
                itemBuilder: (ctx, i) => _buildTaskCard(_tasks[i], isZh),
              ),
          ],
        ),
      ),
    );
  }
}
