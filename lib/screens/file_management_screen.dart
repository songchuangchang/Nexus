import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../services/biometric_service.dart';
import '../services/file_open_service.dart';
import '../services/logger_service.dart';
import '../services/workspace_service.dart';
import '../utils/app_snackbar.dart';
// build162：`.html`/`.htm` 的单列判据（纯函数，与气泡那枚「预览」同一口径）
import '../utils/html_preview.dart';
import 'html_preview_screen.dart';

/// build102（D）：文件管理页 —— 统一浏览/打开/分享/删除 App 产出的文件。
///
/// 收录目录（与各服务落盘路径一一对应，改路径需同步）：
/// - 应用文档目录 `app_logs/`：运行日志 + 日志导出（logger_service.dart init()）
/// - 下载目录 `Nexus_Downloads/`：备份导出 / 更新包（backup_service.dart
///   writeExportToFile；getDownloadsDirectory 不可用时回退应用文档目录）
///
/// Android 11+ 分区存储可能拒绝列出公共下载目录：build102 起该区显示空态 +
/// 路径提示，并提供「打开目录」按钮走系统文件管理器兜底。
/// build138（P1-5）：「列不出」不再显示成「没有文件」——改为失败态（读取失败 +
/// 原因 + 重试），只有真正读成功且目录为空才显示「暂无文件」。

/// 「用户在文件管理页点了一个文件」这一跳**最后走到了哪里**（#84 取证用）。
///
/// 为什么要把去向做成枚举而不是只打一句"已打开"：`exports/四格式展示.html`
/// 那次取证（`docs/BUGSCAN_build164_20260925.md` ⑤）里，同一秒先写了 3 字节、
/// 后写了 2004 字节两份，而整份日志**一个字都没写**他点的是哪条路径、
/// 那一刻磁盘上是多少字节、有没有进预览页 ⇒ `HtmlPreview` tag 0 命中时，
/// 「他没点」与「点了没进去」这两种情况在日志里长得一模一样。
///
/// `openDirectly` 也在里面，因为**点列表行本身就是"打开"**（`onTap: _openFile`）：
/// 只给两枚「预览」菜单项留痕，仍然分不清他没点与点了行 —— 那是四个入口里
/// 他最可能按的那一个（量的量 ≠ 他看的量）。
///
/// 刻意**没有**再加一个 `dispatch*(name)` 分派函数：菜单项的判据已经由
/// `_isPreviewable` + `isHtmlPreviewFile` 在 `itemBuilder` 里写定（162 的锚点），
/// 这里再造一个只被日志读的分派表就是重犯教训 #62（"分派表是死的"）。
enum FileHopDest {
  /// App 内 WebView 预览页（`.html`/`.htm` 的分派结果）
  inAppPreview('App内预览页'),

  /// 交给系统应用渲染（svg/md/markdown 那条既有分派）
  systemPreview('系统预览'),

  /// 系统里没有能渲染它的应用，已经回退成分享面板
  shareSheet('分享面板回退'),

  /// 直接按列表行打开（走 `FileOpenService`，不经任何读文本通道）
  openDirectly('系统直接打开'),

  /// 停在原地没进去（读盘失败 / 文件不存在 / 不在工作区内）
  notOpened('未进预览');

  final String label;
  const FileHopDest(this.label);
}

/// 那一跳的日志行（**纯函数**：只拼字符串，不碰平台通道，所以能单测）。
///
/// 每一项都是"当时看到的事实"，取不到的写「测不出」而不是 0：
///  · [diskBytes] —— `File.length()` 问出来的**磁盘真实字节数**。
///    绝不能拿 [readChars] 冒充：`WorkspaceService.readText` 回灌的是 utf8 解码后的
///    字符，一份 2004 字节的中文 html 只有 ~700 字符；⑤ 那次要分的正是字节那一列。
///  · [readChars] —— 读回内容的字符数（截断后含那句「[已截断，全文 N 字符]」标注）。
///    null = 这一跳**没有读内容**（交给系统应用的那条路、或读盘失败），写成「未读」，
///    不是 0 —— 0 字符与没读是两件事。
///  · [truncated] —— 是否触发了 `WorkspaceService.readBackLimit`(30000 字符) 截断。
String fileHopLogLine({
  required String path,
  required int? diskBytes,
  int? readChars,
  bool truncated = false,
  required FileHopDest dest,
  String? error,
}) {
  final bytes = diskBytes == null ? '磁盘字节=测不出' : '磁盘字节=$diskBytes';
  final chars = readChars == null ? '读回字符=未读' : '读回字符=$readChars';
  final errNote = error == null ? '' : ' 原因=$error';
  return '[$kFilesLogTag] 点开文件: 路径=$path $bytes $chars '
      '截断=${truncated ? '是' : '否'} 去向=${dest.label}$errNote';
}

/// 本页日志的 tag（与文件名字符串绑在一处，别再抄出第二个口径）。
const String kFilesLogTag = 'Files';

class FileManagementScreen extends StatefulWidget {
  const FileManagementScreen({super.key});

  @override
  State<FileManagementScreen> createState() => _FileManagementScreenState();
}

class _FileEntry {
  final File file;

  /// build138（HTML 预览闭环）：仅「AI 工作区」分区的条目带**工作区相对路径**
  /// —— 预览必须走 WorkspaceService.openExternal（内部先做沙箱路径校验，再
  /// open→share 回退），而它只接受相对路径；其它两个分区没有这层沙箱语义。
  final String? rel;

  const _FileEntry(this.file, {this.rel});
}

/// build138（P1-5）：列目录的结果必须同时携带「成功列出的条目」与「失败原因」，
/// 否则失败无法与真空目录区分（旧实现只返回 List，失败即空表）。
class _DirListing {
  final List<_FileEntry> files;
  final String? error;

  /// build138（扫描 P2-8）：目录里文件数超过枚举硬上限时为 true ——
  /// 「只列出了前一部分」必须让用户看得见，否则页面本身又是一个静默降级。
  final bool truncated;

  const _DirListing(this.files, {this.error, this.truncated = false});
}

class _FileSection {
  final String title;
  final String subtitle;
  final List<_FileEntry> files;

  /// build138（P1-5）：非空 = 该目录读取失败（权限被拒/流中断/stat 抛），
  /// 渲染走失败态 + 重试，而不是「暂无文件」。
  final String? error;

  /// build113（WS-3）：分区头部右侧自定义动作（如 AI 工作区的「清空工作区」）
  final Widget? headerAction;

  /// build138（扫描 P2-8）：该目录被**有界枚举/渲染上限**截断过，
  /// 必须在分区底部如实写明（否则「文件不见了」又是一次静默降级）。
  final bool truncated;

  const _FileSection(this.title, this.subtitle, this.files,
      {this.error, this.headerAction, this.truncated = false});
}

class _FileManagementScreenState extends State<FileManagementScreen> {
  bool _loading = true;
  final List<_FileSection> _sections = [];
  final LoggerService _log = LoggerService.instance;

  /// build138（扫描 P2-8）：枚举硬上限 / 渲染上限（见 _listDir）
  static const int kEnumerateCap = 2000;
  static const int kRenderCap = 200;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // ① 日志与导出：documents/app_logs
    String logPath = '';
    List<_FileEntry> logFiles = const [];
    String? logError;
    bool logTrunc = false;
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final logDir = Directory(p.join(appDir.path, 'app_logs'));
      logPath = logDir.path;
      final listing = await _listDir(logDir);
      logFiles = listing.files;
      logError = listing.error;
      logTrunc = listing.truncated;
    } catch (e) {
      // build138（P1-5）：连基目录都拿不到也是「失败」，不能继续伪装成空态
      logError = e.toString();
      _log.warn('[Files] logs base dir unavailable: $e', tag: 'Files');
    }

    // ② 下载与备份：Nexus_Downloads（解析顺序与 backup_service 一致）
    Directory? base;
    try {
      base = await getDownloadsDirectory();
    } catch (_) {
      base = null;
    }
    if (base == null) {
      try {
        base = await getApplicationDocumentsDirectory();
      } catch (_) {
        base = null;
      }
    }
    String dlPath = '';
    List<_FileEntry> dlFiles = const [];
    String? dlError;
    bool dlTrunc = false;
    if (base != null) {
      final dlDir = Directory(p.join(base.path, 'Nexus_Downloads'));
      dlPath = dlDir.path;
      final listing = await _listDir(dlDir);
      dlFiles = listing.files;
      dlError = listing.error;
      dlTrunc = listing.truncated;
    }

    // ③ build113（WS-3）：AI 文件工作区（沙箱 ai_workspace/，与附件/下载物理分开；
    //    工作区文件默认不进备份、不上 WebDAV，仅显式 ws_export/分享才外流）
    String wsPath = '';
    List<_FileEntry> wsFiles = const [];
    String? wsError;
    bool wsTrunc = false;
    try {
      final rootDir = await WorkspaceService.root();
      wsPath = rootDir.path;
      // build138：递归列出 —— AI 生成的二进制产物统一落在 exports/ 子目录
      // （OfficeWriter/WorkspaceService 的约定），不递归的话这一区永远「暂无文件」，
      // 而导出的 xlsx 就找不到出口了（WorkspaceService.list() 本身也是递归的）。
      final listing = await _listDir(rootDir, recursive: true);
      // build138：给工作区条目算出**相对路径**（预览入口要用 openExternal，
      // 它只收相对路径且必须在沙箱内）；分隔符统一成 '/'，与 resolve 同源。
      wsFiles = listing.files
          .map((e) => _FileEntry(
                e.file,
                rel: e.file.path.length > rootDir.path.length + 1
                    ? e.file.path
                        .substring(rootDir.path.length + 1)
                        .replaceAll(Platform.pathSeparator, '/')
                    : p.basename(e.file.path),
              ))
          .toList();
      wsError = listing.error;
      wsTrunc = listing.truncated;
    } catch (e) {
      wsError = e.toString();
      _log.warn('[Files] workspace root unavailable: $e', tag: 'Files');
    }

    final isZh = mounted &&
        AppLocalizations.of(context).locale.languageCode == 'zh';
    if (mounted) {
      setState(() {
        _sections
          ..clear()
          ..addAll([
            _FileSection(
              isZh ? '日志与导出' : 'Logs & exports',
              logPath,
              logFiles,
              error: logError,
              truncated: logTrunc,
            ),
            _FileSection(
              isZh ? '下载与备份' : 'Downloads & backups',
              dlPath,
              dlFiles,
              error: dlError,
              truncated: dlTrunc,
            ),
            _FileSection(
              isZh ? 'AI 工作区' : 'AI workspace',
              wsPath,
              wsFiles,
              error: wsError,
              truncated: wsTrunc,
              headerAction: (wsFiles.isEmpty && wsPath.isEmpty)
                  ? null
                  : TextButton.icon(
                      onPressed: _loading ? null : _clearWorkspace,
                      icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                      label: Text(isZh ? '清空工作区' : 'Clear workspace',
                          style: const TextStyle(fontSize: 12)),
                    ),
            ),
          ]);
        _loading = false;
      });
    }
  }

  /// WS-3：清空工作区（破坏性操作，二次确认——铁律 10）
  Future<void> _clearWorkspace() async {
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text(isZh ? '清空 AI 工作区' : 'Clear AI workspace'),
        content: Text(isZh
            ? '确定删除工作区内全部文件吗？AI 下载/改写的文件将全部丢失，此操作不可撤销。'
            : 'Delete ALL files in the AI workspace? This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: Text(isZh ? '取消' : 'Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(dctx).colorScheme.error),
              onPressed: () => Navigator.pop(dctx, true),
              child: Text(isZh ? '清空' : 'Clear')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final n = await WorkspaceService.clearAll();
    if (!mounted) return;
    AppSnackBar.showSnackBar(context, SnackBar(
        content: Text(isZh ? '已清空 $n 个文件' : 'Cleared $n files'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2)));
    await _load();
  }

  /// build138（P1-5）：列目录失败必须把原因带回调用方 + 留日志。
  /// 旧实现 `catch (_) { return const []; }` 把三类失败一律降级成空表 ——
  /// ① Android 13+ 分区存储拒绝列出公共下载目录（权限被拒）
  /// ② 排序里 lastModifiedSync() 抛（列目录与删除竞态很常见）
  /// ③ dir.list() 流中断
  /// 消费端只按 files.isEmpty 分支 ⇒ 全显示「暂无文件」，用户读成「我的文件没了」，
  /// 而真机零日志无从排查（本页正是找导出/下载文件的兜底入口）。
  Future<_DirListing> _listDir(Directory dir, {bool recursive = false}) async {
    // entries 提到 try 外：流中断/排序抛时已成功列出的条目仍可展示（部分成功）
    final entries = <_FileEntry>[];
    var truncated = false;
    try {
      if (!await dir.exists()) return const _DirListing([]);
      // build138（扫描 P2-8）：**有界枚举**。旧实现把目录里的每一个文件都收进
      // 内存再逐个建 ListTile；导出目录被 AI 工作区写满（上千个 .md/.csv）时，
      // 打开本页 = 一次性解码上千行 + 建同样数量的 Widget，低端机直接卡死。
      // 现在最多枚举 kEnumerateCap 个（多一个用来判定「是否还有更多」），
      // 排序后只渲染 kRenderCap 行，并在页面上明确写出被截断。
      // 代价：超过枚举上限的目录里「最新」是近似的——已在 UI 上如实说明。
      await for (final entity in dir.list(
          recursive: recursive, followLinks: false)) {
        if (entity is! File) continue;
        if (entries.length >= kEnumerateCap) {
          truncated = true;
          break;
        }
        entries.add(_FileEntry(entity));
      }
      entries.sort((a, b) => b.file
          .lastModifiedSync()
          .compareTo(a.file.lastModifiedSync()));
      final shown = entries.length > kRenderCap
          ? entries.sublist(0, kRenderCap)
          : entries;
      return _DirListing(shown, truncated: truncated || entries.length > kRenderCap);
    } catch (e) {
      _log.warn('[Files] list ${dir.path} failed: $e', tag: 'Files');
      return _DirListing(entries, error: e.toString());
    }
  }

  String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  String _fmtDate(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  IconData _iconFor(String name) {
    final ext = p.extension(name).toLowerCase();
    switch (ext) {
      case '.txt':
      case '.log':
        return Icons.description_outlined;
      case '.json':
        return Icons.data_object_outlined;
      case '.md':
        return Icons.article_outlined;
      case '.apk':
        return Icons.android;
      case '.jpg':
      case '.jpeg':
      case '.png':
      case '.webp':
        return Icons.image_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }

  /// build164 #84：列表行**直接点下去就是"打开"** —— 它和两枚「预览」菜单项一样，
  /// 都是"用户点开的是哪个路径、多少字节"这条取证问题上的一个入口（而且是最顺手的那个）。
  /// 只给预览那两条留痕，⑤ 那个问题依旧答不了（量的量 ≠ 他看的量）。
  /// 失败照旧有 SnackBar，这一版只补日志，一个行为判据都没动。
  Future<void> _openFile(File file) async {
    int? diskBytes;
    try {
      if (await file.exists()) diskBytes = await file.length();
    } catch (_) {
      diskBytes = null; // 取不到就写「测不出」，不许拿 0 冒充一个空文件
    }
    try {
      await FileOpenService.open(file.path);
      _log.info(
          fileHopLogLine(
              path: file.path, diskBytes: diskBytes, dest: FileHopDest.openDirectly),
          tag: kFilesLogTag);
    } catch (e) {
      _log.warn(
          fileHopLogLine(
              path: file.path,
              diskBytes: diskBytes,
              dest: FileHopDest.notOpened,
              error: e.toString()),
          tag: kFilesLogTag);
      if (mounted) {
        final isZh =
            AppLocalizations.of(context).locale.languageCode == 'zh';
        AppSnackBar.showSnackBar(context, SnackBar(
            content: Text(isZh
                ? '无法打开该文件'
                : 'Cannot open this file')));
      }
    }
  }

  Future<void> _shareFile(File file) async {
    try {
      await Share.shareXFiles([XFile(file.path)]);
    } catch (_) {
      // 部分 ROM 无分享目标会抛异常，静默即可
    }
  }

  /// build138（HTML 工作区预览闭环）：能在系统浏览器/查看器里**渲染**出来的类型。
  ///
  /// 判据是「交给外部应用后用户看到的不是源码」：html/htm/svg 交给浏览器会
  /// 真渲染成页面，md 交给 Markdown 查看器/浏览器插件也是渲染态；
  /// txt/json/csv 本来就是纯文本，「打开」即「预览」，不再单列入口。
  static const Set<String> previewExtensions = {
    'html', 'htm', 'svg', 'md', 'markdown',
  };

  static bool _isPreviewable(String name) =>
      previewExtensions.contains(WorkspaceService.extOf(name));

  /// build164 #84：这一跳要**可证**。⑤ 那次的取证缺口是"他没点"与"点了没进去"
  /// 在日志里同形，所以：先问磁盘要字节数，再读文本，无论成功失败都落一行。
  /// 拿不到字节数（路径非法 / 文件不在 / stat 抛）就写「测不出」——
  /// 本仓口径：不许把「我不知道」压成 0。
  Future<int?> _diskBytesOf(String rel) async {
    try {
      final (abs, err) = await WorkspaceService.resolve(rel);
      if (abs == null || err != null) return null;
      final f = File(abs);
      if (!await f.exists()) return null;
      return await f.length();
    } catch (e) {
      _log.warn('[$kFilesLogTag] stat $rel failed: $e', tag: kFilesLogTag);
      return null;
    }
  }

  /// 预览 = 用系统应用（浏览器优先）打开工作区里的这个文件。
  ///
  /// 走 [WorkspaceService.openExternal] 而不是本页的 [_openFile]：前者
  /// ① 先过沙箱路径校验（绝对路径/`..`/非法名都进不去），
  /// ② 手机上「没有能打开该类型的应用」是常态，它带 open→share 自动回退，
  ///    回退与否由返回值如实告知（G63 契约）。
  /// 失败可见化：任何非成功分支都必须落到 SnackBar，禁止静默。
  Future<void> _previewWorkspaceFile(String rel) async {
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    final diskBytes = await _diskBytesOf(rel);
    try {
      final (err, fellBackToShare) = await WorkspaceService.openExternal(rel);
      // 日志在 `mounted` 判断**之前**：这一跳发生过没有，跟页面此刻还在不在无关。
      final hopLine = fileHopLogLine(
          path: rel,
          diskBytes: diskBytes,
          dest: err != null
              ? FileHopDest.notOpened
              : (fellBackToShare
                  ? FileHopDest.shareSheet
                  : FileHopDest.systemPreview),
          error: err);
      if (err == null) {
        _log.info(hopLine, tag: kFilesLogTag);
      } else {
        _log.warn(hopLine, tag: kFilesLogTag);
      }
      if (!mounted) return;
      if (err != null) {
        AppSnackBar.showSnackBar(context, SnackBar(
            content: Text(
                isZh ? '预览失败：$err\n文件：$rel' : 'Preview failed: $err\nFile: $rel'),
            duration: const Duration(seconds: 5),
            behavior: SnackBarBehavior.floating));
        return;
      }
      if (fellBackToShare) {
        // 系统里没有能渲染它的浏览器 → 已经拉起分享面板让用户自己挑应用
        AppSnackBar.showSnackBar(context, SnackBar(
            content: Text(isZh
                ? '本机没有可直接预览的应用，已改为分享面板，请挑一个能打开它的应用'
                : 'No app can preview this here — opened the share sheet instead'),
            duration: const Duration(seconds: 4),
            behavior: SnackBarBehavior.floating));
      }
    } catch (e) {
      // 平台通道抛异常（无 Activity/权限）也要说清楚，不能点一下没反应
      if (!mounted) return;
      AppSnackBar.showSnackBar(context, SnackBar(
          content: Text(isZh
              ? '预览失败：无法调起系统应用（$e）\n文件：$rel'
              : 'Preview failed: cannot launch a system app ($e)\nFile: $rel'),
          duration: const Duration(seconds: 5),
          behavior: SnackBarBehavior.floating));
    }
  }

  /// build162：`.html`/`.htm` 走 **App 内**预览页（本仓的 WebView，见
  /// `html_preview_screen.dart`），不再单列「交给系统浏览器」那一条 ——
  /// 两枚都叫「预览」的菜单项一定会有人按错，所以这里做**排他分支**：
  /// build138 那条能力没作废，它变成预览页上的「用浏览器打开」action。
  ///
  /// 读文件只走 [WorkspaceService.readText]（既有那条带「二进制拒绝 / 超限标注」的
  /// 通道），不自己 `File.readAsString`。代价是它的 30000 字符回灌上限会截断，
  /// 所以**必须把截断说出来**（本仓红线：静默降级按缺陷处理），
  /// 完整文件仍然可以用「用浏览器打开」拿到。
  ///
  /// build164 #84：这一跳现在**每一次点击都留一行**（成功进预览页 / 读盘失败 /
  /// 文件不存在都写），字段是路径 + 磁盘真实字节数 + 读回字符数 + 截断标注 + 去向。
  /// 页面上的可见提示也一条不缺：失败必落 SnackBar（原来就有，这里只补了字节数）。
  Future<void> _previewHtmlWorkspaceFile(String rel) async {
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    // 顺序有讲究：**先问磁盘要字节数，再去读文本**。⑤ 那件事是同一条路径
    // 在同一秒内先落 3 字节、后落 2004 字节 —— 先 stat 才拿到的是"他点下去那一刻"
    // 磁盘上躺着的那份，读到一半被覆盖也不会把两个时刻混成一列。
    final diskBytes = await _diskBytesOf(rel);
    final (content, truncated, err) = await WorkspaceService.readText(rel);
    final failed = err != null || content == null;
    // 日志写在 `mounted` 之前：这一跳发生过没有，与页面此刻还在不在无关
    // （否则"点完就退后台"这种最常见的动作又变成零痕迹）。
    final hopLine = fileHopLogLine(
      path: rel,
      diskBytes: diskBytes,
      readChars: content?.length,
      truncated: truncated,
      dest: failed ? FileHopDest.notOpened : FileHopDest.inAppPreview,
      error: err ?? (content == null ? '读取未返回内容' : null),
    );
    if (failed) {
      _log.warn(hopLine, tag: kFilesLogTag);
    } else {
      _log.info(hopLine, tag: kFilesLogTag);
    }
    if (!mounted) return;
    if (failed) {
      // 页面提示带上字节数：0 字节 / 3 字节 这种"文件在、内容还没写完"的形状，
      // 光说"预览失败"他永远不知道自己点开的是哪一份。
      final bytesNote = diskBytes == null
          ? ''
          : (isZh ? '\n磁盘上这份是 $diskBytes 字节' : '\nFile on disk: $diskBytes bytes');
      AppSnackBar.showSnackBar(context, SnackBar(
          content: Text(isZh
              ? '预览失败：${err ?? '读取未返回内容'}\n文件：$rel$bytesNote'
              : 'Preview failed: ${err ?? 'no content'}\nFile: $rel$bytesNote'),
          duration: const Duration(seconds: 5),
          behavior: SnackBarBehavior.floating));
      return;
    }
    if (truncated) {
      AppSnackBar.showSnackBar(context, SnackBar(
          content: Text(isZh
              ? '文件过长，App 内只预览开头一段；完整内容请用预览页的「用浏览器打开」'
              : 'File too long — the in-app preview shows only the first part'),
          duration: const Duration(seconds: 4),
          behavior: SnackBarBehavior.floating));
    }
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => HtmlPreviewScreen(
              html: content,
              fileName: p.basename(rel),
              workspaceRel: rel,
            )));
  }

  /// 删除文件（破坏性操作，必须确认——铁律 10）
  Future<void> _deleteFile(_FileEntry entry) async {
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    final name = p.basename(entry.file.path);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text(isZh ? '删除文件' : 'Delete file'),
        content: Text(isZh
            ? '确定要删除「$name」吗？此操作不可撤销。'
            : 'Delete "$name"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: Text(isZh ? '取消' : 'Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(dctx).colorScheme.error),
            onPressed: () => Navigator.pop(dctx, true),
            child: Text(isZh ? '删除' : 'Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await entry.file.delete();
    } catch (_) {
      // 删除失败（被占用/权限）不阻断刷新
    }
    await _load();
  }

  /// build103（I2）：打开目录多级回退（迁移自 conversation_list_screen 的
  /// _openDownloadFolder，该页主页图标已删）。旧实现只 OpenFilex 单发——
  /// Android 上对目录路径经常打不开且失败静默，用户点空态「暂无文件」无任何反馈。
  /// 回退链：OpenFilex（ACTION_VIEW）→ SAF content://（仅公共 Download 有对应
  /// 形态，app 私有 documents 目录 SAF 到不了）→ SnackBar 提示路径手动开。
  Future<void> _openDir(String path) async {
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    // ① 系统打开（桌面 M2：Windows 由 FileOpenService 降级到 explorer.exe，
    // 桌面到这一步已经成功 return，不会走进下面的 SAF 分支）
    try {
      final r = await BiometricService.guardActivityTransition(
        () => FileOpenService.open(path),
        fallbackDuration: const Duration(seconds: 120),
      );
      if (r.ok) return;
    } catch (_) {
      // 继续下一级回退
    }
    // ② SAF content://（分区存储下文件管理器可识别的标准形态）
    final uris = <Uri>[
      Uri.parse(
          'content://com.android.externalstorage.documents/document/primary%3ADownload%2FNexus_Downloads'),
      Uri.parse(
          'content://com.android.externalstorage.documents/document/primary%3ADownload'),
    ];
    for (final uri in uris) {
      try {
        final launched = await BiometricService.guardActivityTransition(
          () => launchUrl(uri, mode: LaunchMode.externalApplication),
          fallbackDuration: const Duration(seconds: 120),
        );
        if (launched) return;
      } catch (_) {
        // 继续下一级回退
      }
    }
    // ③ 全部失败 → 提示路径让用户手动打开
    if (mounted) {
      AppSnackBar.showSnackBar(context, 
        SnackBar(
          content: Text(isZh
              ? '无法自动打开文件管理器\n目录路径：$path'
              : 'Cannot open file manager automatically\nDirectory: $path'),
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isZh =
        AppLocalizations.of(context).locale.languageCode == 'zh';
    return Scaffold(
      appBar: AppBar(
        title: Text(isZh ? '文件管理' : 'File management'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: isZh ? '刷新' : 'Refresh',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                for (final section in _sections) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(section.title,
                                  style:
                                      Theme.of(context).textTheme.titleSmall),
                            ),
                            if (section.headerAction != null)
                              section.headerAction!,
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          section.subtitle.isEmpty
                              ? (isZh ? '目录不可用' : 'Directory unavailable')
                              : section.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color:
                                  Theme.of(context).colorScheme.outline),
                        ),
                      ],
                    ),
                  ),
                  // build138（P1-5）：失败态与空态分离——读不了就说读不了，并给
                  // 重试入口（用户去系统设置授予权限后回来点一下即可）。
                  if (section.error != null)
                    ListTile(
                      leading: Icon(Icons.error_outline,
                          color: Theme.of(context).colorScheme.error),
                      title: Text(isZh ? '读取失败' : 'Cannot read folder'),
                      subtitle: Text(
                        section.error!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: TextButton(
                        onPressed: _loading ? null : _load,
                        child:
                            Text(isZh ? '重试' : 'Retry', style: const TextStyle(fontSize: 12)),
                      ),
                    ),
                  if (section.files.isEmpty && section.error == null)
                    ListTile(
                      leading: Icon(Icons.folder_open,
                          color: Theme.of(context).colorScheme.outline),
                      title: Text(isZh ? '暂无文件' : 'No files'),
                      subtitle: section.subtitle.isEmpty
                          ? null
                          : Text(
                              isZh
                                  ? '点按可尝试用系统文件管理器打开该目录'
                                  : 'Tap to open this directory in the system file manager',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                      onTap: section.subtitle.isEmpty
                          ? null
                          : () => _openDir(section.subtitle),
                    )
                  else
                    for (final entry in section.files)
                      ListTile(
                        leading: Icon(_iconFor(p.basename(entry.file.path)),
                            color: Theme.of(context).colorScheme.primary),
                        // build138：工作区分区递归列了，子目录里的文件必须带
                        // 相对路径显示（exports/x.xlsx），否则用户看到的是两
                        // 个同名文件、无从分辨。
                        title: Text(entry.rel ?? p.basename(entry.file.path),
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          () {
                            try {
                              final st = entry.file.statSync();
                              return '${_fmtSize(st.size)} · ${_fmtDate(st.modified)}';
                            } catch (_) {
                              return '';
                            }
                          }(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => _openFile(entry.file),
                        trailing: PopupMenuButton<String>(
                          tooltip: isZh ? '更多操作' : 'More',
                          onSelected: (action) {
                            switch (action) {
                              case 'open':
                                _openFile(entry.file);
                                break;
                              case 'preview':
                                final rel = entry.rel;
                                if (rel == null) {
                                  // 理论上到不了这里（菜单项只在工作区条目上出现），
                                  // 真到了也要说清楚，不许静默吞掉点击
                                  AppSnackBar.showSnackBar(context, SnackBar(
                                      content: Text(isZh
                                          ? '预览失败：该文件不在 AI 工作区内'
                                          : 'Preview failed: file is outside the AI workspace'),
                                      behavior: SnackBarBehavior.floating));
                                } else {
                                  _previewWorkspaceFile(rel);
                                }
                                break;
                              // build162：`.html`/`.htm` 的「预览」在 App 内渲染
                              case 'html_preview':
                                final rel = entry.rel;
                                if (rel == null) {
                                  AppSnackBar.showSnackBar(context, SnackBar(
                                      content: Text(isZh
                                          ? '预览失败：该文件不在 AI 工作区内'
                                          : 'Preview failed: file is outside the AI workspace'),
                                      behavior: SnackBarBehavior.floating));
                                } else {
                                  _previewHtmlWorkspaceFile(rel);
                                }
                                break;
                              case 'share':
                                _shareFile(entry.file);
                                break;
                              case 'delete':
                                _deleteFile(entry);
                                break;
                            }
                          },
                          itemBuilder: (_) => [
                            PopupMenuItem(
                                value: 'open',
                                child: Text(isZh ? '打开' : 'Open')),
                            // build138（HTML 预览闭环）：工作区里的 html/htm/svg/md
                            // 单列「预览」——交给系统浏览器渲染，打不开时
                            // openExternal 自带 share 回退，两条路径都有提示。
                            // build162 起 html/htm 从这一条里**分出去**走 App 内预览页
                            // （`previewExtensions` 保留 html/htm：它们确实"值得预览"，
                            // 变的只是宿主），这里排他是为了不让两枚都叫「预览」。
                            if (entry.rel != null &&
                                _isPreviewable(p.basename(entry.file.path)) &&
                                !isHtmlPreviewFile(
                                    p.basename(entry.file.path)))
                              PopupMenuItem(
                                  value: 'preview',
                                  child: Text(isZh ? '预览' : 'Preview')),
                            if (entry.rel != null &&
                                isHtmlPreviewFile(
                                    p.basename(entry.file.path)))
                              PopupMenuItem(
                                  value: 'html_preview',
                                  child: Text(isZh ? '预览' : 'Preview')),
                            PopupMenuItem(
                                value: 'share',
                                child: Text(isZh ? '分享' : 'Share')),
                            PopupMenuItem(
                                value: 'delete',
                                child: Text(isZh ? '删除' : 'Delete',
                                    style: TextStyle(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .error))),
                          ],
                        ),
                      ),
                  // build138（扫描 P2-8）：被上限截断时必须写明——
                  // 用户看到的「就这些文件」不等于目录里的真实内容。
                  if (section.truncated)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                      child: Text(
                        isZh
                            ? '为保持流畅，本区只列出最近 ${_FileManagementScreenState.kRenderCap} 个文件（目录内可能更多）'
                            : 'Showing only the ${_FileManagementScreenState.kRenderCap} most recent files here (the folder may contain more)',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.outline),
                      ),
                    ),
                ],
              ],
            ),
    );
  }
}
