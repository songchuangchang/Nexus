import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../services/app_download_service.dart';
import '../services/biometric_service.dart';
import '../services/file_open_service.dart';
import '../services/logger_service.dart';
import '../ui/tokens.dart';
import '../utils/app_snackbar.dart';

class DownloadProgressDialog extends StatefulWidget {
  final String appName;
  final AppDownloadSource source;

  const DownloadProgressDialog({
    super.key,
    required this.appName,
    required this.source,
  });

  @override
  State<DownloadProgressDialog> createState() => _DownloadProgressDialogState();
}

class _DownloadProgressDialogState extends State<DownloadProgressDialog> {
  final LoggerService _log = LoggerService.instance;

  /// build165：「重试」按下到 `currentTask` 真的出现之间有一小段空窗
  /// （`startDownload` 先 `await getSaveDirectory()` 才写 `currentTask`），
  /// 连点两次会双双越过服务层的互斥判据 ⇒ 同一个 fullPath 两个写句柄
  /// = build147 那条「产出损坏 APK」的成因。这一格只在对话框手里，服务层看不见。
  bool _retryInFlight = false;

  /// 本框最后一次看到的非空任务。服务层失败时会在 finally 里把 `currentTask`
  /// 清成 null（:1377），光看 `currentTask` 分不清「从没启动」和「刚失败」，
  /// 那行取证日志要靠它。
  DownloadTask? _lastSeenTask;

  /// 每次进入「无任务」这一支只写一行日志（重建不刷屏），离开时复位。
  bool _idleLogged = false;

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<AppDownloadService>();
    final task = svc.currentTask;
    final colorScheme = Theme.of(context).colorScheme;
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';

    if (task != null) {
      _lastSeenTask = task;
      _idleLogged = false;
    } else {
      // build165：这一支不画进度。
      return _buildNoTaskView(context, svc, isZh);
    }

    return _buildTaskView(context, task, colorScheme, isZh);
  }

  /// 服务层里**没有任何任务在跑**时该说的话。
  ///
  /// 这里原来是一个整框的转圈（M19 只补了个「关闭」按钮，没解决「这一支根本不该转圈」）：
  /// 代码此刻**已经知道**没有任何任务在跑，画一个"在路上"的圈 = 画一幅与事实相反的图，
  /// 机主因此截图问「这个 UI 用来干嘛的」。改成：事实一句 + 原因一句 + 两个真动作。
  ///
  /// 「重试」不另写一份下载启动逻辑：走 `app_source_selector.dart:159` 点某个源时
  /// 调用的同一个入口 `AppDownloadService.startDownload`，参数（appName/source）
  /// 本来就是本框的两个 required 字段，所以这里不存在「拿不到参数只能只留关闭」的情形。
  /// 确认环节也不重复：进这一支之前 `DownloadConfirmDialog` 已经点过「确认」了。
  Widget _buildNoTaskView(
      BuildContext context, AppDownloadService svc, bool isZh) {
    _logIdleOnce(svc);
    final colorScheme = Theme.of(context).colorScheme;
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card)),
      title: Row(
        children: [
          Icon(Icons.hourglass_disabled_rounded,
              size: 28, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(isZh ? '这个下载没有真正启动' : 'This download never started'),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            isZh
                ? '下载服务里此刻没有这条任务，所以这里没有进度可显示。'
                    '走到这一支通常是三件事之一：刚确认完、服务层还没把它登记上'
                    '（正在建目录/挑路由）；已有另一条下载占着这个位置；'
                    '或者上一次下载失败后被清理掉了。'
                : 'The download service holds no task right now, so there is '
                    'nothing to show progress for. Three states land here: you '
                    'just confirmed and the service has not registered it yet '
                    '(creating the folder / picking a route); another download '
                    'owns that slot; or the previous one failed and was cleared.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 10),
          Text(
            isZh
                ? '这个框对应的来源：${widget.appName} ← '
                    '${widget.source.sourceName}（v${widget.source.version}）'
                : 'Source this dialog was opened for: ${widget.appName} ← '
                    '${widget.source.sourceName} (v${widget.source.version})',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(isZh ? '关闭' : 'Close'),
        ),
        FilledButton.icon(
          onPressed: _retryInFlight ? null : () => _retry(svc, isZh),
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: Text(isZh ? '重试' : 'Retry'),
        ),
      ],
    );
  }

  /// 一行可 grep 的取证日志（tag `Download`）。下次机主再截图问「这是什么」，
  /// 日志里要能直接答出：那一刻服务层到底有没有任务、上一个任务停在哪、
  /// 这个框是为哪个来源开的。
  void _logIdleOnce(AppDownloadService svc) {
    if (_idleLogged) return;
    _idleLogged = true;
    final prev = _lastSeenTask;
    final running = svc.currentTask;
    final prevDesc = prev == null
        ? 'none(opened before startDownload wrote currentTask)'
        : '${prev.appName}/${prev.source.sourceName} '
            'terminal=${prev.isTerminal} '
            'bytes=${prev.receivedBytes}/${prev.totalBytes} '
            'error=${prev.error ?? 'null'}';
    _log.warn(
        '[Download] Progress dialog idle: '
        'currentTask=${running == null ? 'null' : 'non-null'} '
        'lockHeld=${running != null && !running.isTerminal} '
        'previousTask=$prevDesc '
        'serviceHistory=${svc.history.isEmpty ? 'empty(only successes are recorded)' : '${svc.history.first.appName}/${svc.history.first.source.sourceName}'} '
        'dialogSource=${widget.appName}<${widget.source.sourceName}:'
        '${widget.source.version}@${widget.source.sourceDomain}>',
        cat: LogCat.download,
        tag: 'Download');
  }

  /// 从「无任务」这一支重新发起那一次下载 —— 与服务层唯一的公开入口同一个。
  Future<void> _retry(AppDownloadService svc, bool isZh) async {
    if (_retryInFlight) return;
    final running = svc.currentTask;
    if (running != null && !running.isTerminal) {
      // 有任务在途 ⇒ 这个框会被 watch 重建成进度条，不需要也不能再起一条
      _log.warn(
          '[Download] Retry skipped: a task is already in flight '
          '(${running.appName}/${running.source.sourceName}) — refusing to '
          'open a second writer on the same file',
          cat: LogCat.download,
          tag: 'Download');
      return;
    }
    if (svc.isRegistering) {
      // 服务层正在登记这条任务（`currentTask` 还差一个 await 就写上了）
      // ⇒ 等着就好，起第二条就是给同一个文件添一个写句柄
      _log.warn('[Download] Retry skipped: service is registering a task '
          'for ${widget.appName} — not starting a second one',
          cat: LogCat.download, tag: 'Download');
      return;
    }
    _retryInFlight = true;
    try {
      await svc.startDownload(
        appName: widget.appName,
        source: widget.source,
      );
    } catch (e, st) {
      _log.error(
          '[Download] Retry from progress dialog failed: '
          '${widget.appName} via ${widget.source.sourceName}',
          error: e,
          stack: st,
          cat: LogCat.download,
          tag: 'Download');
      if (mounted) {
        AppSnackBar.showSnackBar(
            context,
            SnackBar(
              content: Text(isZh ? '还是没启动：$e' : 'Still not started: $e'),
              duration: const Duration(seconds: 5),
            ));
      }
    } finally {
      _retryInFlight = false;
      if (mounted) setState(() {});
    }
  }

  Widget _buildTaskView(BuildContext context, DownloadTask task,
      ColorScheme colorScheme, bool isZh) {
    final complete = task.isComplete && task.error == null;
    final failed = task.error != null;

    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Row(
        children: [
          Expanded(
            child: Text(complete
                ? (isZh ? '✅ 下载完成' : '✅ Download Complete')
                : failed
                    ? (isZh ? '❌ 下载失败' : '❌ Download Failed')
                    : (isZh ? '⬇️ 下载中' : '⬇️ Downloading...')),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!complete && !failed) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                minHeight: 10,
                value: task.progress > 0 ? task.progress : null,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text(
                      '${_fmt(task.receivedBytes)} / ${_fmt(task.totalBytes)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall),
                ),
                Text('${(task.progress * 100).toStringAsFixed(1)}%',
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 12),
            Text(task.fileName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    )),
          ] else if (complete) ...[
            Icon(Icons.check_circle_rounded,
                size: 64, color: colorScheme.appTextSub),
            const SizedBox(height: 12),
            Text(task.fileName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    )),
            const SizedBox(height: 6),
            Text(isZh ? '已保存到：' : 'Saved to:',
                style: Theme.of(context).textTheme.bodySmall),
            Text(task.fullPath,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontFamily: 'monospace',
                    )),
          ] else ...[
            Icon(Icons.error_outline_rounded,
                size: 64, color: colorScheme.error),
            const SizedBox(height: 12),
            Text(task.error ?? 'Unknown error',
                maxLines: 5,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colorScheme.error,
                  fontWeight: FontWeight.w500,
                )),
          ],
        ],
      ),
      actions: [
        if (!complete && !failed)
          TextButton(
            onPressed: () {
              // build147 第 11 轮：这里原来顺手把 `currentTask = null`，
              // 而 `AppDownloadService.startDownload` 的**互斥判据就是它**
              // （`currentTask != null && !currentTask!.isTerminal`，:1253）。
              // 于是「后台下载」= 拆掉互斥：回列表再点一个来源就能起第二条下载，
              // 同一个 App 同一版本两次 ⇒ 同一个 fullPath 两个写句柄交错、
              // 后一条把前一条截断 ⇒ **产出损坏的 APK**（SHA-256 只校验得到其中一条，
              // 校验通过也照样是坏包）。
              // 「后台」的语义是"这个框关掉，下载继续"，从来不是"这条任务不存在了"
              // ⇒ 只 pop，不碰服务层状态。复位仍归 `startDownload` 的 finally 唯一负责
              // （build138 P1-2 就是为这件事把复位挪进 finally 的）。
              Navigator.pop(context);
            },
            child: Text(isZh ? '后台下载' : 'Background'),
          ),
        if (complete) ...[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(isZh ? '关闭' : 'Close'),
          ),
          TextButton.icon(
            onPressed: () async {
              try {
                await BiometricService.guardActivityTransition(
                  () => FileOpenService.open(task.saveDir),
                  fallbackDuration: const Duration(seconds: 120),
                );
              } catch (e) {
                _log.warn('[Download] Open folder failed: $e');
              }
              if (context.mounted) Navigator.pop(context);
            },
            icon: const Icon(Icons.folder_rounded),
            label: Text(isZh ? '打开文件夹' : 'Open Folder'),
          ),
          FilledButton.icon(
            onPressed: () async {
              try {
                final r = await BiometricService.guardActivityTransition(
                  () => FileOpenService.open(task.fullPath,
                      type: 'application/vnd.android.package-archive'),
                  fallbackDuration: const Duration(seconds: 120),
                );
                _log.info(
                    '[Download] Open APK result: status=${r.status} message=${r.message}');
              } catch (e, st) {
                _log.error('[Download] Open APK failed',
                    error: e, stack: st, tag: 'OpenAPK');
                if (context.mounted) {
                  AppSnackBar.showSnackBar(context, SnackBar(
                    content: Text(
                        isZh
                            ? '安装器打不开，请去文件管理器找：\n${task.fullPath}'
                            : 'Installer failed to open, find it in your file manager:\n${task.fullPath}',
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis),
                  ));
                }
              }
              if (context.mounted) Navigator.pop(context);
            },
            icon: const Icon(Icons.install_mobile_rounded),
            label: Text(isZh ? '安装' : 'Install APK'),
          ),
        ] else if (failed) ...[
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: Text(isZh ? '确定' : 'OK'),
          ),
        ],
      ],
    );
  }

  static String _fmt(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    double size = bytes.toDouble();
    int unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    return '${size.toStringAsFixed(1)} ${units[unit]}';
  }
}
