import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/live_task_center.dart';
import '../services/live_task_wiring.dart';
import '../l10n/app_localizations.dart';
import '../services/backup_service.dart';
import '../services/logger_service.dart';
import '../services/storage_service.dart';
import '../services/webdav_service.dart';
import '../utils/app_snackbar.dart';

/// build104（S6）：WebDAV 设置键提升为库级常量——自动同步需要从 App 启动
/// 链路读取（键原先锁在 State 类里，导致「自动同步」开关存而无人消费）。
const String kWebdavUrl = 'webdav_url';
const String kWebdavUser = 'webdav_user';
const String kWebdavPass = 'webdav_pass';
const String kWebdavDir = 'webdav_dir';
const String kWebdavAutoSync = 'webdav_auto_sync';
const String kWebdavKeepLatest = 'webdav_keep_latest';
const String kWebdavLastSyncAt = 'webdav_last_sync_at';
/// build155（设置/表单路扫描）：「远端目录」这一格的**唯一**归一口径 + 默认值。
///
/// 为什么必须只有一处：这一格此前在同一条链上有三套读法 ——
///  - 手动上传 `_syncNow`：空 ⇒ 'aichat'；
///  - 恢复 `_restore` / 下载：`_dirCtrl.text.trim()` **原样用**（空 ⇒ 指向网盘根目录）；
///  - 后台自动同步：`getString(kWebdavDir) ?? 'aichat'` —— 空串不是 null，`??` 兜不住，
///    于是它也读根目录。
/// 触发路径很普通：用户清空「远端目录」→ 点保存（旧代码把空串原样落库）→
/// 「立即上传备份」把备份写进 `aichat/`，再点「从网盘恢复」去列**根目录**
/// ⇒ 提示「网盘上没有本应用的备份」，而文件一直在盘上；夜间自动同步则往根目录写。
/// 现在三处都过这一个函数，纯空白也回默认目录。
const String kWebdavDefaultDir = 'aichat';

/// [raw]（存进来或敲进来的目录）→ 实际要用的目录；空 / 纯空白 ⇒ [kWebdavDefaultDir]。
String webdavDirOrDefault(String? raw) {
  final t = raw?.trim() ?? '';
  return t.isEmpty ? kWebdavDefaultDir : t;
}

/// build146（网盘轮转 P0 / 自动同步死码 P1）：网盘上传的**进程内互斥**。
///
/// 为什么手动同步也要占这把锁：自动同步是 `main.dart:328` 用
/// `unawaited(maybeWebdavAutoSync())` 起的，用户同一时刻进设置页点「立即上传备份」
/// 就是两条链各自 PUT、各自轮转 —— [WebDavService] 的 `justUploaded` 只保护**自己**
/// 刚写那一份，保护不了**对方**那一份 ⇒ 后跑完的那条会把先跑完的那份当旧备份删掉。
/// 顺带这也压住了 `uploadWithRetention` 那个**固定** LiveTask id（`webdav_put`）在
/// 两条链之间互相摘通知的老问题（本文件不改 id 的唯一性，只是让两条链不再同时在这）。
/// 单用户、单机、两条链都是分钟级以下 ⇒ 一个布尔够，不上队列。
bool _webdavSyncInFlight = false;

/// build146：「上传成功了，但旧备份没清理干净」的人话。手动路径拿它拼 SnackBar
/// （双语，和本页其它文案一致），自动路径拿它拼通知（固定中文 —— 本仓库
/// [LiveTaskWiring]/LiveTaskCenter 的 title/body 全是中文，见 live_task_wiring.dart）。
String webdavPruneFailureText(WebDavSyncResult r, {required bool zh}) {
  if (zh) {
    if (r.pruneFailures > 0) {
      return '备份已上传，但旧备份清理失败 ${r.pruneFailures} 份'
          '（已删 ${r.pruned} 份，网盘可能继续增长）';
    }
    return '备份已上传，但旧备份清理未完成：${r.pruneError ?? '未知原因'}';
  }
  if (r.pruneFailures > 0) {
    return 'Uploaded, but ${r.pruneFailures} old backups could not be deleted'
        ' (${r.pruned} pruned; your drive may keep growing)';
  }
  return 'Uploaded, but pruning did not complete: ${r.pruneError ?? 'unknown'}';
}

/// build104（S6）：自动同步真实触发点——App 启动完成后调用一次。
/// 开关开启且距上次同步 ≥24h 时，后台推送一份**不含密钥**的全量备份到
/// 用户网盘（保留策略与手动同步一致）。任何失败静默（不打扰启动）。
/// build146（自动同步死码 P1）：本函数的**开关入口**补齐了 —— 设置页此前只有一个
/// 绑定 `_keepLatest` 的 SwitchListTile，`kWebdavAutoSync` 只被读、被 `_save()` 回写，
/// 全仓库没有任何地方把它写成 true（grep `_autoSync` 只有声明/加载/保存三处），
/// 于是整条自动同步是死功能。现在它由页面上「自动同步」那一行实时落盘。
Future<void> maybeWebdavAutoSync() async {
  // build142（灵动岛）：这是**用户没动手**的例行后台同步 ⇒ 成功不弹高打扰通知，
  // 但进行中仍然投影成一条低打扰进度通知（原来整条链路连一行 UI 反馈都没有）。
  return LiveTaskWiring.withQuietSuccess(() async {
    final log = LoggerService.instance;
    if (_webdavSyncInFlight) {
      // 撞上手动同步：跳过这一轮，**不写时间戳** ⇒ 下次启动还会再试。
      log.warn('[WebDAV] auto sync skipped: 已有网盘同步在跑', tag: 'Dav');
      return;
    }
    _webdavSyncInFlight = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!(prefs.getBool(kWebdavAutoSync) ?? false)) return;
      final url = prefs.getString(kWebdavUrl) ?? '';
      final user = prefs.getString(kWebdavUser) ?? '';
      final pass = prefs.getString(kWebdavPass) ?? '';
      if (url.isEmpty || user.isEmpty || pass.isEmpty) return;
      final dir = webdavDirOrDefault(prefs.getString(kWebdavDir));
      // build146：走统一口径读 —— 旧存档里的 0（当年"关掉开关"写下的）在这里
      // 必须是「不轮转」，不能原样喂给轮转逻辑。
      final keep =
          WebDavService.normalizeKeepLatest(prefs.getInt(kWebdavKeepLatest));
      final last = prefs.getInt(kWebdavLastSyncAt) ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - last < const Duration(hours: 24).inMilliseconds) return;
      final storage = StorageService.instance;
      if (!storage.isInitialized) await storage.init();
      final json = await BackupService(storage).exportAll(includeKeys: false);
      final stamp =
          DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
      final res = await WebDavService().uploadWithRetention(
        baseUrl: url,
        username: user,
        password: pass,
        dirPath: dir,
        fileName: 'aichat_backup_auto_$stamp.txt',
        content: json,
        keepLatest: keep,
      );
      // build146：原来这一行**无条件**执行（`ok == false` 也写）⇒ 网盘没凭据、
      // 目录被删、断网……任意一次失败都会把下一次重试挡足 24 小时，而用户在
      // 设置页上只看得到「自动同步」是开着的。时间戳的语义是「上次成功同步」，
      // 那就只在真的传上去了之后才写。
      if (res.uploaded) {
        await prefs.setInt(kWebdavLastSyncAt, now);
      } else {
        log.warn('[WebDAV] auto sync 上传失败，不记时间戳（下次启动即重试）', tag: 'Dav');
      }
      // 失败要播报：`withQuietSuccess` 压掉的只该是好消息（build142 的口径，
      // 见 LiveTaskWiring.track 的 finally）。上传本身的失败 `track` 已经弹了
      // （`okCheck` 判 uploaded），这里补的是它覆盖不到的那一半：**清理没跑完**。
      // 复用同一个原语 LiveTaskCenter.alert，不另起通知路径；**不传固定 id**
      // （中枢用自增序号），免得和手动那条 `backup:webdav_put` 抢同一个通知。
      if (res.uploaded && !res.fullyOk) {
        await LiveTaskCenter.instance.alert(
          title: '网盘旧备份清理未完成',
          body: webdavPruneFailureText(res, zh: true),
          route: kLiveRouteBackup,
        );
      }
      log.info(
          '[WebDAV] auto sync done: uploaded=${res.uploaded} pruned=${res.pruned} '
          'pruneFailures=${res.pruneFailures} keepLatest=$keep',
          tag: 'Dav');
    } catch (e) {
      // build146：原来是 `debugPrint` —— release 包里一行都留不下（静默 = 不可排查）。
      log.warn('[WebDAV] auto sync failed: $e', tag: 'Dav');
    } finally {
      _webdavSyncInFlight = false;
    }
  });
}

/// build101（E2 WebDAV 同步）：把备份文件推到用户自己的网盘。
///
/// 配置存在 shared_preferences（不进 DB）：WebDAV 是「设备级」的基础设施
/// 配置，与设备绑定，不应随备份 JSON 一起导出（否则 A 设备的网盘凭据
/// 会被带到 B 设备）。
///
/// 安全：密码存 shared_preferences 明文。Android 上应用私有目录本身有
/// 沙箱保护；如需更强保护，这里可换 flutter_secure_storage（当前不引，
/// 避免多一个原生依赖）。
class WebDavSettingsScreen extends StatefulWidget {
  const WebDavSettingsScreen({super.key});

  @override
  State<WebDavSettingsScreen> createState() => _WebDavSettingsScreenState();
}

class _WebDavSettingsScreenState extends State<WebDavSettingsScreen> {

  final _urlCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _dirCtrl = TextEditingController(text: kWebdavDefaultDir);

  /// 「自动同步」开关的界面状态 —— 唯一写 `kWebdavAutoSync` 的地方就是它
  /// （外加 `_save()` 的回写）。build146 之前这个字段**没有任何入口能置真**。
  bool _autoSync = false;

  /// 真正持久化 + 传给轮转逻辑的值。语义与 `kWebdavKeepLatest` 逐字一致：
  /// `0` = **不轮转（网盘上的备份全部保留）**，`>=1` = 保留 N 份。
  /// 见 [WebDavService.normalizeKeepLatest] / [WebDavService.backupsToDelete]。
  int _keepLatest = 10;

  /// 开关拨回"开"时要恢复的份数。build146：原来关一下就是 `_keepLatest = 0`，
  /// 再开就**硬写回 10** —— 用户之前调过的份数被静默改掉；而且 0 会被下游读成
  /// "删光"。现在关闭只翻开关，数字留在这里。
  int _pruneKeep = 10;

  bool _obscure = true;
  bool _loading = true;
  bool _busy = false;

  static const int _minKeep = 1;
  static const int _maxKeep = 60;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    _dirCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _urlCtrl.text = p.getString(kWebdavUrl) ?? '';
      _userCtrl.text = p.getString(kWebdavUser) ?? '';
      _passCtrl.text = p.getString(kWebdavPass) ?? '';
      _dirCtrl.text = webdavDirOrDefault(p.getString(kWebdavDir));
      _autoSync = p.getBool(kWebdavAutoSync) ?? false;
      // build146：旧版本存下的 0 / 负数在这里**原样保留为 0（不轮转）**，
      // 而不是被 `?? 10` 之后又被开关写回"删光"。开关显示为"关"，
      // 数字用默认 10 待恢复（0 不携带任何"上次想留几份"的信息）。
      final stored = WebDavService.normalizeKeepLatest(p.getInt(kWebdavKeepLatest));
      _keepLatest = stored;
      _pruneKeep = stored >= 1 ? stored : 10;
      _loading = false;
    });
  }

  /// 两个开关都走**实时落盘**：本页的 `kWebdavAutoSync` 一旦只靠「保存」按钮持久化，
  /// 用户拨完就返回上一页的场景下自动同步仍然是死的（这正是 build146 P1 的形状）。
  /// `_save()` 里那几个 `set*` 保留 —— 它们是各字段的**全量**写回，不冲突。
  Future<void> _persistSwitches() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(kWebdavAutoSync, _autoSync);
    await p.setInt(kWebdavKeepLatest, _keepLatest);
  }

  void _toggleAutoSync(bool v) {
    setState(() => _autoSync = v);
    unawaited(_persistSwitches());
  }

  void _togglePrune(bool v) {
    setState(() {
      if (v) {
        _keepLatest = _pruneKeep >= _minKeep ? _pruneKeep : 10;
      } else {
        // 关：份数记进 `_pruneKeep`，持久化 0 = 不轮转。**删除份数永远不可能
        // 经由本 UI 变成 0-through-UI**（0 只作为"关"的哨兵值存在）。
        _pruneKeep = _keepLatest >= _minKeep ? _keepLatest : _pruneKeep;
        _keepLatest = 0;
      }
    });
    unawaited(_persistSwitches());
  }

  void _bumpKeep(int delta) {
    var v = (_keepLatest >= _minKeep ? _keepLatest : _pruneKeep) + delta;
    if (v < _minKeep) v = _minKeep;
    if (v > _maxKeep) v = _maxKeep;
    setState(() {
      _keepLatest = v;
      _pruneKeep = v;
    });
    unawaited(_persistSwitches());
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(kWebdavUrl, _urlCtrl.text.trim());
    await p.setString(kWebdavUser, _userCtrl.text.trim());
    await p.setString(kWebdavPass, _passCtrl.text);
    await p.setString(kWebdavDir, webdavDirOrDefault(_dirCtrl.text));
    await p.setBool(kWebdavAutoSync, _autoSync);
    await p.setInt(kWebdavKeepLatest, _keepLatest);
    if (!mounted) return;
    AppSnackBar.showSnackBar(context, 
      SnackBar(
          content: Text(
              AppLocalizations.of(context).locale.languageCode == 'zh'
                  ? '已保存'
                  : 'Saved')),
    );
  }

  Future<void> _test() async {
    final l = AppLocalizations.of(context);
    final zh = l.locale.languageCode == 'zh';
    setState(() => _busy = true);
    await _save();
    if (!mounted) return;
    final (ok, msg, ms) = await WebDavService().test(
      baseUrl: _urlCtrl.text.trim(),
      username: _userCtrl.text.trim(),
      password: _passCtrl.text,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ok
            ? (zh ? '连接成功' : 'Connected')
            : (zh ? '连接失败' : 'Connection failed')),
        content: Text(ok
            ? (zh ? '连接正常，耗时 ${ms}ms' : 'OK in ${ms}ms')
            : msg),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(zh ? '好' : 'OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _syncNow() async {
    final l = AppLocalizations.of(context);
    final zh = l.locale.languageCode == 'zh';
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      AppSnackBar.showSnackBar(context, 
        SnackBar(
            content: Text(zh
                ? '请先填写 WebDAV 地址'
                : 'Enter the WebDAV URL first')),
      );
      return;
    }
    // build146（P1）：进程内互斥。夜里那趟自动同步还没跑完时手动再点一次，
    // 两条链会各自 PUT + 各自轮转，后跑完的把先跑完那份删掉 ⇒ 直接拒绝并说清楚。
    if (_webdavSyncInFlight) {
      AppSnackBar.showSnackBar(context, 
        SnackBar(
            content: Text(zh
                ? '已有一次网盘同步在进行中，请稍后再试'
                : 'A drive sync is already running, try again shortly')),
      );
      return;
    }
    _webdavSyncInFlight = true;
    setState(() => _busy = true);
    await _save();
    if (!mounted) {
      _webdavSyncInFlight = false;
      return;
    }
    try {
      final storage = context.read<StorageService>();
      // 默认不含密钥上传（网盘是第三方存储，凭据不该出本机）
      final json = await BackupService(storage).exportAll(includeKeys: false);
      final now = DateTime.now();
      final stamp = '${now.year}${now.month.toString().padLeft(2, '0')}'
          '${now.day.toString().padLeft(2, '0')}_'
          '${now.hour.toString().padLeft(2, '0')}'
          '${now.minute.toString().padLeft(2, '0')}'
          '${now.second.toString().padLeft(2, '0')}';
      final res = await WebDavService().uploadWithRetention(
        baseUrl: url,
        username: _userCtrl.text.trim(),
        password: _passCtrl.text,
        dirPath: webdavDirOrDefault(_dirCtrl.text),
        fileName: 'aichat_backup_$stamp.txt',
        content: json,
        // `_keepLatest` 与 `kWebdavKeepLatest` 同源（`_save()` 写的就是它），
        // 所以"页面上看到的"和"真正生效的"不会分家。0 = 不轮转。
        keepLatest: _keepLatest,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      // build146：原来只要 `uploadWithRetention` 返回 true 就一律「已上传到网盘」，
      // 而那个 true 当时并不包含"旧备份删掉了"这件事 ⇒ 现在分三档说。
      AppSnackBar.showSnackBar(context, 
        SnackBar(
          duration: const Duration(seconds: 5),
          content: Text(!res.uploaded
              ? (zh ? '上传失败，请检查日志' : 'Upload failed, check logs')
              : res.fullyOk
                  ? (zh ? '已上传到网盘' : 'Uploaded')
                  : webdavPruneFailureText(res, zh: zh)),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      AppSnackBar.showSnackBar(context, 
        SnackBar(content: Text('${zh ? '失败' : 'Failed'}: $e')),
      );
    } finally {
      _webdavSyncInFlight = false;
    }
  }

  Future<void> _restore() async {
    final l = AppLocalizations.of(context);
    final zh = l.locale.languageCode == 'zh';
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      // build155：原来这里静默 return —— 按钮是亮的、点下去什么都不发生也没话说
      // （本页其它入口都给文案）。
      AppSnackBar.showSnackBar(context, SnackBar(
          content: Text(
              zh ? '请先填写 WebDAV 地址' : 'Enter the WebDAV URL first')));
      return;
    }
    // build155：恢复是**破坏性**动作（整份覆盖本地库），入口要挡住「正在跑」的同步。
    // `_busy` 只压得住本页自己发起的那次上传；`maybeWebdavAutoSync` 由 main.dart 起、
    // 不置 `_busy`，于是「后台正在 PUT + 轮转删旧备份」与「下载并覆盖本地库」可以同时跑
    // —— 上传可能把**恢复到一半**的库传上网盘，轮转又可能在恢复途中删备份。
    // `_syncNow` 早就有这把 `_webdavSyncInFlight` 闸门，这里补上同一把。
    if (_webdavSyncInFlight) {
      AppSnackBar.showSnackBar(context, SnackBar(
          content: Text(zh
              ? '网盘同步正在进行中，请等它结束后再恢复'
              : 'A WebDAV sync is in progress; wait for it before restoring')));
      return;
    }    setState(() => _busy = true);
    // B-013：列文件阶段此前在 try 之外——地址/密码错、断网、服务端 5xx 时
    // dav.list 抛异常会直接穿出 onPressed，后面唯一能把 _busy 复位的语句到不了，
    // 四个按钮永久置灰、页面看着像卡死（且没有任何错误提示）。
    final List<String> names;
    final dav = WebDavService();
    try {
      names = await dav.list(
        baseUrl: url,
        username: _userCtrl.text.trim(),
        password: _passCtrl.text,
        dirPath: webdavDirOrDefault(_dirCtrl.text),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      AppSnackBar.showSnackBar(context, SnackBar(
        content: Text(zh ? '连接网盘失败：$e' : 'WebDAV failed: $e'),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }
    final backups = names
        .where((n) => n.startsWith('aichat_backup_'))
        .toList()
      ..sort((a, b) => b.compareTo(a)); // 新的在前
    if (!mounted) return;
    setState(() => _busy = false);
    if (backups.isEmpty) {
      AppSnackBar.showSnackBar(context, 
        SnackBar(
            content: Text(zh ? '网盘上没有找到备份' : 'No backup found')),
      );
      return;
    }
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(zh ? '选择要恢复的备份' : 'Choose a backup'),
        children: [
          for (final n in backups.take(20))
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, n),
              child: Text(n, style: const TextStyle(fontSize: 13)),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(zh ? '确认恢复' : 'Confirm restore'),
        content: Text(zh
            ? '将用「$picked」覆盖本机数据（合并模式）。'
                '当前对话、配置将被该备份的内容覆盖或补充。'
            : 'Restore "$picked" in merge mode. Local data will be '
                'overwritten or extended.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(zh ? '取消' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(zh ? '恢复' : 'Restore'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    setState(() => _busy = true);
    final json = await dav.download(
      baseUrl: url,
      username: _userCtrl.text.trim(),
      password: _passCtrl.text,
      remotePath: '${webdavDirOrDefault(_dirCtrl.text)}/$picked',
    );
    if (!mounted) return;
    if (json == null) {
      setState(() => _busy = false);
      AppSnackBar.showSnackBar(context, 
        SnackBar(content: Text(zh ? '下载失败' : 'Download failed')),
      );
      return;
    }
    try {
      final storage = context.read<StorageService>();
      final stats = await BackupService(storage).importFromString(json, merge: true);
      if (!mounted) return;
      setState(() => _busy = false);
      AppSnackBar.showSnackBar(context, 
        SnackBar(
          content: Text(zh
              ? '恢复完成：${stats.conversations} 个会话，${stats.messages} 条消息'
              : 'Restored: ${stats.conversations} chats, ${stats.messages} messages'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      AppSnackBar.showSnackBar(context, 
        SnackBar(content: Text('${zh ? '恢复失败' : 'Restore failed'}: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final zh = l.locale.languageCode == 'zh';

    return Scaffold(
      appBar: AppBar(title: Text(zh ? 'WebDAV 同步' : 'WebDAV Sync')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      zh
                          ? '把备份上传到你自己已有的网盘（坚果云 / Nextcloud / '
                              '群晖等）。应用不经过任何中间服务器，凭据只存在本机。'
                          : 'Upload backups to your own WebDAV drive. No '
                              'intermediate server; credentials stay local.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _urlCtrl,
                  decoration: const InputDecoration(
                    labelText: 'WebDAV URL',
                    hintText: 'https://dav.jianguoyun.com/dav',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final p in WebDavService.presets)
                      ActionChip(
                        label: Text(p.name, style: const TextStyle(fontSize: 11)),
                        onPressed: () => setState(() {
                          _urlCtrl.text = p.url;
                          AppSnackBar.showSnackBar(context, 
                            SnackBar(
                              content: Text(p.hint),
                              duration: const Duration(seconds: 4),
                            ),
                          );
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _userCtrl,
                  decoration: InputDecoration(
                    labelText: zh ? '用户名' : 'Username',
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _passCtrl,
                  obscureText: _obscure,
                  decoration: InputDecoration(
                    labelText: zh ? '密码 / 应用密码' : 'Password / app password',
                    border: const OutlineInputBorder(),
                    helperText: zh
                        ? '坚果云等必须用「应用密码」，不是登录密码。⚠️ 密码明文存储于本机（与 API Key 同级），勿用主密码'
                        : 'Many providers require an app password',
                    suffixIcon: IconButton(
                      icon: Icon(
                          _obscure ? Icons.visibility_off : Icons.visibility),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _dirCtrl,
                  decoration: InputDecoration(
                    labelText: zh ? '远端目录' : 'Remote folder',
                    border: const OutlineInputBorder(),
                    helperText: zh
                        ? '不存在会自动创建'
                        : 'Created automatically if missing',
                  ),
                ),
                const SizedBox(height: 12),
                // build146（自动同步死码 P1）：这一行就是全仓库**唯一**能把
                // `kWebdavAutoSync` 写成 true 的入口。此前该键只有声明（:17）、
                // 加载（`_load`）、`_save()` 回写三处，页面上唯一的 SwitchListTile
                // 绑的是 `_keepLatest` ⇒ `maybeWebdavAutoSync()` 永远在第一行 return，
                // 「自动同步」是个没有入口的死功能。开关即时落盘，见 `_toggleAutoSync`。
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(zh ? '自动同步' : 'Auto sync'),
                  subtitle: Text(zh
                      ? 'App 启动后若距上次成功上传超过 24 小时，后台自动上传一份不含密钥的备份'
                      : 'At app start, uploads a key-free backup in the background '
                          'if the last successful upload is older than 24 hours'),
                  value: _autoSync,
                  onChanged: _toggleAutoSync,
                ),
                const SizedBox(height: 4),
                // build146（网盘轮转 P0）：这一行原先叫「保留最近份数 / Keep latest」，
                // `onChanged: (v) => setState(() => _keepLatest = v ? 10 : 0)` ——
                // 名字是个开关、写下去的是个数字，而 0 传进轮转逻辑等于
                // 「把网盘上本应用的备份全删掉（含刚上传那份）」，随后 UI 还提示
                // 「已上传到网盘」。现在开关管的是**要不要清理**（开 = `_keepLatest > 0`），
                // 留几份由下面的步进器明说，关闭只写 0 这个"不轮转"哨兵值，
                // 删除份数不可能再由界面凑成 0。
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(zh ? '自动清理旧备份' : 'Auto-prune old backups'),
                  subtitle: Text(_keepLatest > 0
                      ? (zh
                          ? '每次上传后删除超出保留份数的旧备份（只删本应用的备份文件）'
                          : 'After each upload, delete this app\'s older backups '
                              'beyond the kept count')
                      : (zh
                          ? '已关闭：网盘上的备份全部保留，一个文件也不删'
                          : 'Off: every backup on the drive is kept, nothing is deleted')),
                  value: _keepLatest > 0,
                  onChanged: _togglePrune,
                ),
                // 份数只在"开"的时候可调；"关"的时候灰着显示上次记住的数，
                // 再拨回来还是那个数（不再被硬写成 10）。
                IgnorePointer(
                  ignoring: _keepLatest <= 0,
                  child: Opacity(
                    opacity: _keepLatest > 0 ? 1 : 0.4,
                    child: Row(
                      children: [
                        Text(zh ? '保留份数' : 'Keep',
                            style: Theme.of(context).textTheme.bodyMedium),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline),
                          tooltip: zh ? '减少保留份数' : 'Keep fewer',
                          onPressed: _keepLatest > 0 ? () => _bumpKeep(-1) : null,
                        ),
                        SizedBox(
                          width: 68,
                          child: Text(
                            // 关闭状态显示的是"下次打开会用"的那个数，不是 0 ——
                            // 显示 0 会让人以为"保留 0 份"，那正是被修掉的读法。
                            zh ? '保留 ${_keepLatest > 0 ? _keepLatest : _pruneKeep} 份'
                                : '${_keepLatest > 0 ? _keepLatest : _pruneKeep} files',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.add_circle_outline),
                          tooltip: zh ? '增加保留份数' : 'Keep more',
                          onPressed: _keepLatest > 0 ? () => _bumpKeep(1) : null,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : _test,
                        icon: const Icon(Icons.wifi_tethering, size: 18),
                        label: Text(zh ? '测试连接' : 'Test'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : _save,
                        icon: const Icon(Icons.save_outlined, size: 18),
                        label: Text(zh ? '保存' : 'Save'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: _busy ? null : _syncNow,
                  icon: _busy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cloud_upload_outlined, size: 18),
                  label: Text(zh ? '立即上传备份' : 'Upload backup now'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _restore,
                  icon: const Icon(Icons.cloud_download_outlined, size: 18),
                  label: Text(zh ? '从网盘恢复' : 'Restore from drive'),
                ),
              ],
            ),
    );
  }
}
