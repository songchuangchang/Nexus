import 'dart:convert';
import 'live_task_center.dart';
import 'live_task_wiring.dart';
import 'package:http/http.dart' as http;
import 'logger_service.dart';

/// build101（E2 WebDAV 同步）：把备份 JSON 推到用户自己的 WebDAV 网盘。
///
/// **为什么选 WebDAV 而不是自建服务端**：坚果云 / Nextcloud / Synology /
/// 群晖 / 阿里云盘（经 WebDAV 网关）全都支持 WebDAV，用户拿自己已有的
/// 账号即可，不需要向本项目提供任何凭据，隐私边界清晰。
///
/// 协议要点（RFC 4918）：
/// - `PUT <url>` 写文件；`GET <url>` 读；`MKCOL` 建目录；`PROPFIND` 列目录
/// - 坚果云要求用**应用密码**而非登录密码，且 PUT 的目标目录必须已存在
/// - 鉴权用 Basic（`base64(user:pass)`）
/// build146（网盘轮转 P0）：`uploadWithRetention` 的返回值。
///
/// **为什么不再是 `bool`**：原先的一句 `return true` 只说「PUT 成功」，把
/// 「PUT 成功但 N 份旧备份没删掉」和「全部成功」压成同一个值 ⇒ 调用方（设置页、
/// 自动同步）只能对用户说「已上传到网盘」，而清理失败是**看得见的事实**（网盘会
/// 一直涨、坚果云超量会拒绝写入），静默 = 不可排查。
/// 只有两个调用点（`webdav_settings_screen.dart` 的手动上传与 `maybeWebdavAutoSync`），
/// 都已跟着改；`LiveTaskWiring.track` 的 `okCheck` 现在判 `uploaded`，
/// 语义与原来的 `okCheck: (r) => r` 逐字一致（PUT 没成就不许报成功），
/// 不会因为清理失败而谎报「上传失败」。
class WebDavSyncResult {
  /// 备份本身是否写进了网盘。
  final bool uploaded;

  /// 成功删除的旧备份份数。
  final int pruned;

  /// DELETE 返回非 2xx 或抛异常的次数（**逐份计数**，不许只 log 成"已清理"）。
  final int pruneFailures;

  /// 整轮清理没跑起来（列目录失败等），null = 没有这种情况。
  ///
  /// build146 第 10 轮：这个字段原来**永远是 null** —— 列目录的 `list()` 把
  /// 非 2xx 和异常都吞成空表，于是"根本没读到网盘上有什么"被压成"网盘上没有旧备份"，
  /// 于是 `fullyOk` 为真、设置页说「已上传到网盘」，而网盘上一份都没清理且永不自愈
  /// （坚果云目录只读 / PROPFIND 被拒 / 30s 超时都是这个形状）。现在 `list()` 会抛
  /// [WebDavListException]，这一支才真的可达。
  final String? pruneError;

  const WebDavSyncResult({
    required this.uploaded,
    this.pruned = 0,
    this.pruneFailures = 0,
    this.pruneError,
  });

  /// 上传成功**且**清理一轮无异常 —— 只有这个值才配得上「已上传到网盘」这句好话。
  bool get fullyOk => uploaded && pruneFailures == 0 && pruneError == null;
}

/// 列目录失败（网络 / 鉴权 / 非 2xx / 超时）。
///
/// build146 第 10 轮：**为什么宁可抛而不是回空表**。空表是一个**事实断言**
/// （"这个目录里没有文件"），而失败时我们并不知道目录里有什么。把它压成空表
/// 会让两个下游各自把"我不知道"读成假事实：
///  · `webdav_settings_screen.dart:_restore()` 读成「网盘上没有找到备份」
///    （那里早就写了 catch，说明调用方本来就当它会抛 —— 是 `list` 自己没守约）；
///  · 轮转回路读成「网盘上没有旧备份 ⇒ 无需清理 ⇒ `fullyOk=true`」。
/// 后者尤其坏：用户会以为保留策略在收敛，网盘实际一直在涨，且下一次同步还是这个结果。
class WebDavListException implements Exception {
  final String message;
  const WebDavListException(this.message);

  @override
  String toString() => 'WebDavListException: $message';
}

class WebDavService {
  final LoggerService _log = LoggerService.instance;

  /// 测试连接：PROPFIND 根目录（Depth: 0）。
  ///
  /// 返回 (成功, 消息, 延迟ms)。不抛异常——UI 需要展示具体失败原因。
  Future<(bool, String, int?)> test({
    required String baseUrl,
    required String username,
    required String password,
    String? client,
  }) async {
    final url = _normalize(baseUrl);
    if (url.isEmpty) return (false, 'Invalid URL', null);
    final sw = Stopwatch()..start();
    final c = http.Client();
    try {
      final req = http.Request('PROPFIND', Uri.parse(url))
        ..headers.addAll(_authHeaders(username, password))
        ..headers['Depth'] = '0'
        ..headers['Content-Type'] = 'application/xml';
      final resp = await c
          .send(req)
          .timeout(const Duration(seconds: 20));
      sw.stop();
      if (resp.statusCode == 207 || resp.statusCode == 200) {
        return (true, 'OK', sw.elapsedMilliseconds);
      }
      if (resp.statusCode == 401) {
        return (false, '401 Unauthorized — check username/app-password', sw.elapsedMilliseconds);
      }
      if (resp.statusCode == 404) {
        return (false, '404 Not Found — check the directory path', sw.elapsedMilliseconds);
      }
      return (false, 'HTTP ${resp.statusCode}', sw.elapsedMilliseconds);
    } catch (e) {
      sw.stop();
      return (false, '$e', sw.elapsedMilliseconds);
    } finally {
      c.close();
    }
  }

  /// 确保目录存在（逐级 MKCOL；已存在返回 405 属正常，忽略）。
  Future<bool> ensureDirectory({
    required String baseUrl,
    required String username,
    required String password,
    required String dirPath,
  }) async {
    final root = _normalize(baseUrl);
    if (root.isEmpty) return false;
    final segs = dirPath.split('/').where((s) => s.trim().isNotEmpty).toList();
    if (segs.isEmpty) return true;
    final client = http.Client();
    try {
      var cur = root.endsWith('/') ? root.substring(0, root.length - 1) : root;
      for (final seg in segs) {
        cur = '$cur/$seg';
        try {
          final req = http.Request('MKCOL', Uri.parse(cur))
            ..headers.addAll(_authHeaders(username, password));
          final resp =
              await client.send(req).timeout(const Duration(seconds: 20));
          // 201 = 创建成功；405/301 = 已存在
          if (resp.statusCode >= 400 &&
              resp.statusCode != 405 &&
              resp.statusCode != 301) {
            _log.warn('[WebDAV] MKCOL $cur -> ${resp.statusCode}', tag: 'Dav');
            return false;
          }
        } catch (e) {
          _log.warn('[WebDAV] MKCOL $cur failed: $e', tag: 'Dav');
          return false;
        }
      }
      return true;
    } finally {
      client.close();
    }
  }

  /// 上传字符串内容（用于备份 JSON）。
  Future<bool> upload({
    required String baseUrl,
    required String username,
    required String password,
    required String remotePath,
    required String content,
  }) async {
    final root = _normalize(baseUrl);
    if (root.isEmpty) return false;
    final client = http.Client();
    try {
      final uri = Uri.parse('${_trimSlash(root)}/$remotePath');
      final resp = await client
          .put(
            uri,
            headers: {
              ..._authHeaders(username, password),
              'Content-Type': 'application/json; charset=utf-8',
            },
            body: utf8.encode(content),
          )
          .timeout(const Duration(seconds: 120));
      final ok = resp.statusCode >= 200 && resp.statusCode < 300;
      _log.info('[WebDAV] PUT $uri -> ${resp.statusCode}', tag: 'Dav');
      return ok;
    } catch (e) {
      _log.warn('[WebDAV] PUT failed: $e', tag: 'Dav');
      return false;
    } finally {
      client.close();
    }
  }

  /// 下载远端文件内容。
  /// build142（灵动岛）：恢复前从网盘拉整份备份，几百 KB 到几 MB，弱网会很久。
  Future<String?> download({
    required String baseUrl,
    required String username,
    required String password,
    required String remotePath,
  }) async =>
      LiveTaskWiring.track(
        id: 'webdav_get',
        title: '正在从网盘取备份',
        kind: LiveTaskKind.backup,
        okBody: '已从网盘取回备份',
        okCheck: (r) => r != null, // 返回 null = 取不到，不许报成功
        body: () => _downloadInner(
          baseUrl: baseUrl,
          username: username,
          password: password,
          remotePath: remotePath,
        ),
      );

    Future<String?> _downloadInner({
    required String baseUrl,
    required String username,
    required String password,
    required String remotePath,
  }) async {
    final root = _normalize(baseUrl);
    if (root.isEmpty) return null;
    final client = http.Client();
    try {
      final uri = Uri.parse('${_trimSlash(root)}/$remotePath');
      final resp = await client
          .get(uri, headers: _authHeaders(username, password))
          .timeout(const Duration(seconds: 120));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        _log.warn('[WebDAV] GET $uri -> ${resp.statusCode}', tag: 'Dav');
        return null;
      }
      return utf8.decode(resp.bodyBytes, allowMalformed: true);
    } catch (e) {
      _log.warn('[WebDAV] GET failed: $e', tag: 'Dav');
      return null;
    } finally {
      client.close();
    }
  }

  /// 列出某目录下的文件名（PROPFIND Depth: 1，从 XML 里抠 href 末段）。
  ///
  /// **失败抛 [WebDavListException]，不返回空表**（理由见那个类的注释）：
  /// 空表是"目录里没有文件"这个事实，失败时我们没资格断言它。
  Future<List<String>> list({
    required String baseUrl,
    required String username,
    required String password,
    String dirPath = '',
  }) async {
    final root = _normalize(baseUrl);
    if (root.isEmpty) throw const WebDavListException('网盘地址为空');
    final client = http.Client();
    try {
      final target = dirPath.isEmpty
          ? root
          : '${_trimSlash(root)}/${_trimSlash(dirPath)}';
      final req = http.Request('PROPFIND', Uri.parse(target))
        ..headers.addAll(_authHeaders(username, password))
        ..headers['Depth'] = '1'
        ..headers['Content-Type'] = 'application/xml';
      final streamed =
          await client.send(req).timeout(const Duration(seconds: 30));
      if (streamed.statusCode != 207 && streamed.statusCode != 200) {
        throw WebDavListException('列目录 HTTP ${streamed.statusCode}');
      }
      final body = await streamed.stream.bytesToString();
      // 抽 <d:href>...</d:href>（命名空间前缀不固定，用宽松匹配）
      final names = <String>[];
      for (final m in RegExp(r'<[^>]*href[^>]*>([^<]+)</', caseSensitive: false)
          .allMatches(body)) {
        final href = Uri.decodeFull(m.group(1)!.trim());
        final seg = href.split('/').where((s) => s.isNotEmpty).lastOrNull;
        if (seg != null && seg.isNotEmpty) names.add(seg);
      }
      return names;
    } on WebDavListException {
      // 已经在上面判过状态码的失败：原样抛出去，不许被下面那个 catch 二次包装成
      // "未知异常"，也不许在这儿被吞掉。
      rethrow;
    } catch (e) {
      _log.warn('[WebDAV] PROPFIND failed: $e', tag: 'Dav');
      throw WebDavListException('列目录失败：$e');
    } finally {
      client.close();
    }
  }

  /// 便捷：上传备份并保留最近 N 份（按文件名时间戳排序，删旧的）。
  /// build142（灵动岛）：上传（含保留策略的旧文件清理）是整条链路里最慢的一步，
  /// 而**自动同步完全没有 UI**（`maybeWebdavAutoSync` 失败只 debugPrint）⇒ 这条必须上岛。
  ///
  /// build146（网盘轮转 P0）：[keepLatest] 现在只有一种解释 ——
  /// `<= 0` = **不轮转（网盘上的备份全部保留）**，`>= 1` = 保留这么多份。
  /// 旧版本里 0 是从设置页那个「保留最近份数」开关拨到"关"时写下来的，
  /// 传到这里就成了「一份都不留」⇒ 关掉开关会把网盘（含刚上传那份）删光。
  Future<WebDavSyncResult> uploadWithRetention({
    required String baseUrl,
    required String username,
    required String password,
    required String dirPath,
    required String fileName,
    required String content,
    int keepLatest = 10,
  }) async =>
      LiveTaskWiring.track(
        // build146：这个 id 是**固定串**（不带手动/自动之分）⇒ 手动与自动同时跑时
        // 后结束的那条会把另一条还在进行的进度通知摘掉（并发同名，`track` 的注释里
        // 已经承认过这个取舍：宁可少报不虚报）。本文件不动它的唯一性，改成由
        // `maybeWebdavAutoSync` / 设置页的进程内互斥保证两条链不会同时在这。
        id: 'webdav_put',
        title: '正在上传到网盘',
        kind: LiveTaskKind.backup,
        okBody: '网盘上已有最新一份备份',
        // 判 `uploaded` 而不是判 `fullyOk`：清理失败时备份确实已经上去了，
        // 弹「上传失败」是谎报；清理失败另有出口（返回值 → UI 文案 / 自动同步提醒）。
        okCheck: (r) => r.uploaded, // 返回 false = 上传没成，**不许**弹「完成」
        body: () => _uploadWithRetentionInner(
          baseUrl: baseUrl,
          username: username,
          password: password,
          dirPath: dirPath,
          fileName: fileName,
          content: content,
          keepLatest: keepLatest,
        ),
      );

    Future<WebDavSyncResult> _uploadWithRetentionInner({
    required String baseUrl,
    required String username,
    required String password,
    required String dirPath,
    required String fileName,
    required String content,
    int keepLatest = 10,
  }) async {
    await ensureDirectory(
      baseUrl: baseUrl,
      username: username,
      password: password,
      dirPath: dirPath,
    );
    final ok = await upload(
      baseUrl: baseUrl,
      username: username,
      password: password,
      remotePath: '${_trimSlash(dirPath)}/$fileName',
      content: content,
    );
    if (!ok) return const WebDavSyncResult(uploaded: false);
    // 保留策略：只清理本应用产生的备份文件
    var pruned = 0;
    var failures = 0;
    String? cleanupError;
    try {
      final names = await list(
        baseUrl: baseUrl,
        username: username,
        password: password,
        dirPath: dirPath,
      );
      final backups = sortBackupsOldToNew(names
          .where((n) => n.startsWith('aichat_backup_') && n.endsWith('.txt'))
          .toList());
      // build146：以前是 `..sort()` 按名字排 —— 手动名 `2026…` 与自动名 `auto_2026-…`
      // 混排时 `'a' > '2'` ⇒ 所有自动份都排在所有手动份之后 ⇒ "保留最近 N 份"
      // 执行成"自动全留、先删你手动存的"。现在按文件名里各自的真实时刻排（旧→新），
      // 读不出时间的排最后（绝不进待删段）。`justUploaded` 的保护仍然保留，
      // 因为列目录可能早于落盘（服务端目录缓存），位置依然不可信。
      final toDelete = backupsToDelete(
        names: backups,
        keepLatest: keepLatest,
        justUploaded: fileName,
      );
      if (keepLatest <= 0 && backups.length > 1) {
        _log.info(
            '[WebDAV] retention OFF (keepLatest=$keepLatest): keep all ${backups.length} backups',
            tag: 'Dav');
      }
      if (toDelete.isNotEmpty) {
        final client = http.Client();
        try {
          for (final n in toDelete) {
            final uri = Uri.parse(
                '${_trimSlash(_normalize(baseUrl))}/${_trimSlash(dirPath)}/$n');
            // build146：原来这里连状态码都不看，紧接着就打一行
            // `pruned old backup` ⇒ 服务端 403/423（只读、被锁）时日志会说"已清理"，
            // 用户和排查的人都以为网盘在收敛，实际一份没删。
            try {
              final resp = await client
                  .delete(uri, headers: _authHeaders(username, password))
                  .timeout(const Duration(seconds: 30));
              if (resp.statusCode >= 200 && resp.statusCode < 300) {
                pruned++;
                _log.info('[WebDAV] pruned old backup: $n -> ${resp.statusCode}',
                    tag: 'Dav');
              } else {
                failures++;
                _log.warn(
                    '[WebDAV] prune FAILED: $n -> HTTP ${resp.statusCode}',
                    tag: 'Dav');
              }
            } catch (e) {
              failures++;
              _log.warn('[WebDAV] prune FAILED: $n: $e', tag: 'Dav');
            }
          }
        } finally {
          client.close();
        }
        if (failures > 0) {
          _log.warn(
              '[WebDAV] retention: deleted $pruned, FAILED $failures, '
              'remaining ${backups.length - pruned} (keepLatest=$keepLatest)',
              tag: 'Dav');
        }
      }
    } catch (e) {
      // 列清理失败不影响上传成功的事实 —— 但**必须带出去**：一份都没删成这件事
      // 用户有权知道（网盘配额是会撞的）。
      cleanupError = '$e';
      _log.warn('[WebDAV] retention cleanup failed: $e', tag: 'Dav');
    }
    return WebDavSyncResult(
      uploaded: true,
      pruned: pruned,
      pruneFailures: failures,
      pruneError: cleanupError,
    );
  }

  /// build146（网盘轮转 P0）：`webdav_keep_latest` 的读取口径 —— 集中在这一个函数，
  /// 免得「0 到底是什么意思」在 UI、自动同步、轮转三处各写各的。
  ///
  /// 旧版本会把「关闭轮转」写成 **0**，而下游 `sublist(0, length - 0)` 把整份列表
  /// 当成待删。现在 `stored <= 0`（含旧存档里的 0 和任何负数）一律解释为
  /// **不轮转**。`null`（从没存过）才是默认 [fallback] 份。
  /// 故意不把 0「翻译」成 10：0 是用户自己拨出来的关，替他改主意就是新的惊喜。
  static int normalizeKeepLatest(int? stored, {int fallback = 10}) {
    if (stored == null) return fallback;
    return stored <= 0 ? 0 : stored;
  }

  /// build146（网盘轮转 P0）：**纯函数** —— 从「本应用产生的、已按名升序（旧→新）
  /// 排好的」备份文件名里算出这一轮该删哪些。
  ///
  /// 为什么要抽出来：本仓库没有 WebDAV 的测试替身（`list`/`delete` 直接打网络），
  /// 而轮转决策恰恰是这条链上唯一会**吃掉用户数据**的环节 ⇒ 必须能和 IO 分开测。
  ///
  /// 三条硬约束（每条都有用例钉着）：
  /// 1. `keepLatest <= 0` ⇒ 返回空：关掉开关 = 全部保留，绝不是"删光"。
  /// 2. [justUploaded] 永不进删除名单。不能靠"它是最新的所以排在末尾"——
  ///    自动同步的文件名带 `auto_` 段，按名升序时整组 auto 都排在手动组之后，
  ///    刚 PUT 完的手动那份可能正躺在待删区间里（这就是原 P0 的第二半）。
  /// 3. 返回值永远不等于整个输入：网盘上至少留 1 份。[justUploaded] 已经在盘上，
  ///    它通常就是那一份；万一这次列表里没它（列目录早于落盘、服务端目录缓存），
  ///    就退一步从旧份里至少留 1 份 —— 清空网盘永远不是"保留 N 份"的意思。
  static List<String> backupsToDelete({
    required List<String> names,
    required int keepLatest,
    required String justUploaded,
  }) {
    if (keepLatest <= 0) return const [];
    final hasNew = names.contains(justUploaded);
    // 去重并保持入参顺序（PROPFIND 偶尔把同一 href 回两遍；重复计入会多删）
    final seen = <String>{};
    final candidates = <String>[];
    for (final n in names) {
      if (n == justUploaded || !seen.add(n)) continue;
      candidates.add(n);
    }
    if (candidates.isEmpty) return const [];
    // 新那份总是占掉 keepLatest 的一个名额（它已经在盘上了）。
    var keepOthers = keepLatest - 1;
    if (keepOthers < 0) keepOthers = 0;
    if (!hasNew && keepOthers < 1) keepOthers = 1;
    if (candidates.length <= keepOthers) return const [];
    // 待删的是**最旧**的那一段（列表升序 ⇒ 从头切）
    return candidates.sublist(0, candidates.length - keepOthers);
  }

  /// build146（第 10 轮，轮转口径）：从备份文件名解析出**它自己的时间**。
  ///
  /// 为什么要这个函数：轮转是"删最旧的 N 份"，而两份代码用**两种时间格式**命名
  /// （手动 `backup_service.dart:484-490` 是 `aichat_backup_YYYYMMDD_HHMMSS.txt`，
  /// 自动 `webdav_settings_screen.dart:90-97` 是 `aichat_backup_auto_<ISO>.txt`）。
  /// 按文件名排序时 `'a' > '2'` ⇒ **所有** auto 份都排在**所有**手动份之后，
  /// 于是「保留最近 10 份」实际执行成"自动备份全留、先删你手动存的那几份"——
  /// 与用户在看板上读到的意思正好相反。这里把名字翻回真实时刻，让两类一视同仁。
  ///
  /// 解析不出来 ⇒ 返回 `null`，排序时按"最新"处理（**永不进待删段**）：
  /// 一个我们读不懂时间的文件，没资格被"按最旧"删掉。
  static DateTime? backupTimeFromName(String name) {
    var s = name;
    const prefix = 'aichat_backup_';
    if (s.startsWith(prefix)) s = s.substring(prefix.length);
    if (s.startsWith('auto_')) s = s.substring('auto_'.length);
    if (s.endsWith('.txt')) s = s.substring(0, s.length - '.txt'.length);
    // 手动格式：20260922_190433
    final compact = RegExp(
            r'^(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})$')
        .firstMatch(s);
    if (compact != null) {
      final p = _sixInts(compact);
      return _safeDateTime(p);
    }
    // 自动格式：2026-09-22T19-04-33-123456（ISO 串里的 `:` 与 `.` 都被换成了 `-`）
    final isoish = RegExp(
            r'^(\d{4})-(\d{2})-(\d{2})T(\d{2})-(\d{2})-(\d{2})')
        .firstMatch(s);
    if (isoish != null) {
      final p = _sixInts(isoish);
      return _safeDateTime(p);
    }
    return null;
  }

  static List<int> _sixInts(RegExpMatch m) => [
        for (var i = 1; i <= 6; i++) int.parse(m.group(i)!),
      ];

  static DateTime? _safeDateTime(List<int> p) {
    // 越界（月份 13、秒 60 之类脏名字）不当成时间看，避免构造期抛。
    if (p[1] < 1 || p[1] > 12) return null;
    if (p[2] < 1 || p[2] > 31) return null;
    if (p[3] > 23 || p[4] > 59 || p[5] > 59) return null;
    try {
      return DateTime(p[0], p[1], p[2], p[3], p[4], p[5]);
    } catch (_) {
      return null;
    }
  }

  /// 旧→新排序（供 [backupsToDelete] 用；它约定入参已按时间升序）。
  /// 同刻或读不出时间的，再按名字排，保证结果**确定**（不依赖 PROPFIND 的返回顺序）。
  static List<String> sortBackupsOldToNew(Iterable<String> names) {
    final list = names.toList();
    list.sort((a, b) {
      final ta = backupTimeFromName(a);
      final tb = backupTimeFromName(b);
      if (ta == null && tb == null) return a.compareTo(b);
      // 读不出时间 ⇒ 视作"最新"，永远排在后面 ⇒ 不进"删最旧"的那一段。
      if (ta == null) return 1;
      if (tb == null) return -1;
      final c = ta.compareTo(tb);
      return c != 0 ? c : a.compareTo(b);
    });
    return list;
  }

  // ------------------------------------------------------------------

  static String _normalize(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return '';
    if (!s.startsWith('http://') && !s.startsWith('https://')) {
      s = 'https://$s';
    }
    // 坚果云等要求 URL 不带尾部斜杠指向账号根
    while (s.endsWith('/') && !s.endsWith('://')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  static String _trimSlash(String s) {
    var t = s;
    while (t.startsWith('/')) {
      t = t.substring(1);
    }
    while (t.endsWith('/')) {
      t = t.substring(0, t.length - 1);
    }
    return t;
  }

  static Map<String, String> _authHeaders(String user, String pass) {
    final raw = '$user:$pass';
    final b64 = base64Encode(utf8.encode(raw));
    return {'Authorization': 'Basic $b64'};
  }

  // ------------------------------------------------------------------
  // 常用服务商的 URL 模板（帮用户少查文档）
  // ------------------------------------------------------------------

  static const List<({String name, String url, String hint})> presets = [
    (
      name: '坚果云',
      url: 'https://dav.jianguoyun.com/dav',
      hint: '需在坚果云「安全选项」里生成应用密码，不能用登录密码',
    ),
    (
      name: 'Nextcloud',
      url: 'https://your-domain.com/remote.php/dav/files/USERNAME',
      hint: '把 your-domain.com 和 USERNAME 换成你的',
    ),
    (
      name: '群晖 Synology',
      url: 'https://your-nas:5006',
      hint: '需在套件中心开启 WebDAV Server；端口默认 5006(https)',
    ),
    (
      name: 'Box',
      url: 'https://dav.box.com/dav',
      hint: '用 Box 的应用密码',
    ),
    (
      name: 'InfiniCLOUD',
      url: 'https://your-id.teracloud.jp/dav',
      hint: '免费 20GB；密码在「应用密码」里生成',
    ),
  ];
}

/// 供 Dart 侧 `lastOrNull` 使用（避免引 collection 包）
extension _LastOrNull<E> on Iterable<E> {
  E? get lastOrNull {
    if (isEmpty) return null;
    return last;
  }
}
