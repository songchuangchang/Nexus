import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../constants.dart' show kAppVersionConst;
import '../utils/redact.dart' as redact;

// ============================================================================
// v1.4.2：全链路结构化日志分类
//
// 设计目标：**用户每一次按键/操作/网络请求/异常都有一条可筛选的日志**，
// 出现 bug 时不用猜，打开日志按分类过滤就能还原完整操作链路。
//
// 分类说明：
//   APP      — 应用生命周期（启动/前后台/版本初始化）
//   UI       — 用户界面操作（点击按钮/切换页面/对话框打开关闭）
//   NAV      — 页面路由导航（进入/离开页面）
//   DB       — 数据库读写/迁移/PRAGMA 自检
//   CHAT     — 对话生命周期（新建/删除/标题更新）
//   API      — LLM API 请求/响应（含耗时/状态码；密钥会被脱敏）
//   REACT    — ReAct 循环（thinking/search/ask_user/download/self_check 各阶段）
//   COMPRESS — 上下文压缩（手动/自动触发、token、摘要 token）
//   WS       — 联网搜索（web_search + 文件下载搜索）
//   DOWNLOAD — 下载任务（APK/视频/图片/文档等，含进度/成功/失败）
//   BACKUP   — 导入导出备份
//   CONFIG   — 设置/配置修改
//   ERROR    — 全局异常捕获、未处理 async error
//   PERF     — 性能相关（慢操作、build 耗时）
// ============================================================================
enum LogCat {
  app('APP'),
  ui('UI'),
  nav('NAV'),
  db('DB'),
  chat('CHAT'),
  api('API'),
  react('REACT'),
  compress('COMPRESS'),
  ws('WS'),
  download('DOWNLOAD'),
  backup('BACKUP'),
  config('CONFIG'),
  error('ERROR'),
  perf('PERF');

  final String key;
  const LogCat(this.key);

  /// 英文 key → 中文展示名（用于日志查看页筛选 chip）
  String get labelCN {
    switch (this) {
      case LogCat.app:
        return '应用';
      case LogCat.ui:
        return 'UI';
      case LogCat.nav:
        return '导航';
      case LogCat.db:
        return '数据库';
      case LogCat.chat:
        return '聊天';
      case LogCat.api:
        return 'API';
      case LogCat.react:
        return 'ReAct';
      case LogCat.compress:
        return '压缩';
      case LogCat.ws:
        return '搜索';
      case LogCat.download:
        return '下载';
      case LogCat.backup:
        return '备份';
      case LogCat.config:
        return '配置';
      case LogCat.error:
        return '错误';
      case LogCat.perf:
        return '性能';
    }
  }

  /// v1.6.6：英文界面下的展示名
  String get labelEN {
    switch (this) {
      case LogCat.app:
        return 'App';
      case LogCat.ui:
        return 'UI';
      case LogCat.nav:
        return 'Nav';
      case LogCat.db:
        return 'DB';
      case LogCat.chat:
        return 'Chat';
      case LogCat.api:
        return 'API';
      case LogCat.react:
        return 'ReAct';
      case LogCat.compress:
        return 'Compress';
      case LogCat.ws:
        return 'Search';
      case LogCat.download:
        return 'Download';
      case LogCat.backup:
        return 'Backup';
      case LogCat.config:
        return 'Config';
      case LogCat.error:
        return 'Error';
      case LogCat.perf:
        return 'Perf';
    }
  }

  /// 颜色标记（ANSI 16 色级别；这里仅用于 UI 渲染查表，不直接写文件）
  int get colorSeedHash => key.hashCode;
}

/// 应用运行日志服务（单例，v1.4.2 全链路结构化）
///
/// - 内存里留最近 [maxMemoryLines] 行，UI 可以直接读
/// - 同时追加写到本地文件 `app_logs/aichat_<date>.log`，每天一个文件
/// - 单个日志文件超过 [maxFileBytes] 自动滚动到 `aichat_<date>.1.log`
/// - 提供"导出全部 / 打开 / 清空"接口，方便用户把日志发给我看
/// - 新增 **分类便捷方法**：`ui()`, `nav()`, `db()`, `chat()`, `react()`,
///   `compress()`, `download()`, `backup()`, `config()` 等，让业务代码写日志像英语句子
/// - **敏感信息永远不记**：Authorization/Bearer/sk-*/apiKey/TVLY 等会自动脱敏
class LoggerService extends ChangeNotifier {
  LoggerService._internal();
  static final LoggerService instance = LoggerService._internal();

  static const int maxMemoryLines = 20000;
  static const int maxFileBytes = 10 * 1024 * 1024;
  static const int maxKeptDays = 7;

  final List<String> _buffer = [];
  List<String> get buffer => List.unmodifiable(_buffer);

  /// v1.4.2：按分类的内存缓冲副本（用于日志查看页分类筛选）
  final Map<LogCat, List<String>> _byCat = {
    for (final c in LogCat.values) c: [],
  };
  List<String> linesByCat(LogCat c) => List.unmodifiable(_byCat[c] ?? const []);

  Directory? _logDir;
  bool _initialized = false;

  /// 落盘串行链（build152）：见 `_log()` 里第 3 步的注释 ——
  /// 每条日志各起一个异步 append 会让行与行、以及滚动 `rename` 互相踩，
  /// 真机日志里出现过整条 ERROR 丢掉时间戳与级别前缀。挂在这条链上按序写。
  Future<void> _writeChain = Future<void>.value();

  final Map<String, DateTime> _lastLogTime = {};
  static const _floodWindow = Duration(milliseconds: 500);

  /// v1.3.4：详细日志模式开关
  bool _verboseEnabled = false;
  bool get verboseEnabled => _verboseEnabled;
  set verboseEnabled(bool v) {
    _verboseEnabled = v;
    app('Verbose logging ${v ? "ENABLED" : "disabled"} (聊天内容/搜索结果将${v ? "会" : "不会"}被记录)');
  }

  Future<void> init() async {
    if (_initialized) return;
    try {
      final appDir = await getApplicationDocumentsDirectory();
      _logDir = Directory(p.join(appDir.path, 'app_logs'));
      if (!_logDir!.existsSync()) {
        await _logDir!.create(recursive: true);
      }
      _initialized = true;
      app('LoggerService initialized at ${_logDir!.path} (maxMemoryLines=$maxMemoryLines, verbose=$_verboseEnabled)');
      _purgeOldLogs();
    } catch (e, st) {
      debugPrint('LoggerService init failed: $e\n$st');
    }
  }

  // ---------- 通用级别方法（向后兼容） ----------
  void debug(String msg, {LogCat? cat, String? tag}) =>
      _write('DEBUG', msg, cat: cat, tag: tag);
  void info(String msg, {LogCat? cat, String? tag}) =>
      _write('INFO', msg, cat: cat, tag: tag);
  void warn(String msg, {LogCat? cat, String? tag}) =>
      _write('WARN', msg, cat: cat, tag: tag);
  void error(String msg,
      {Object? error, StackTrace? stack, LogCat? cat, String? tag}) {
    final buf = StringBuffer(msg);
    if (error != null) buf.write('\n  ↳ error: $error');
    if (stack != null) {
      buf.write(
          '\n  ↳ stack:\n${stack.toString().split('\n').take(8).join('\n')}');
    }
    _write('ERROR', buf.toString(), cat: cat ?? LogCat.error, tag: tag);
  }

  /// 详细日志 — 只在 verboseEnabled=true 时写入
  /// 用于记录聊天内容、搜索结果详情、AI 思考全文等敏感信息（找问题用）
  void verbose(String msg, {LogCat? cat, String? tag}) {
    if (!_verboseEnabled) return;
    _write('VERBOSE', msg, cat: cat, tag: tag);
  }

  // ---------- 分类便捷方法（v1.4.2 新增） ----------
  // 写日志就像写英语句子：logger.ui('新建聊天按钮被点击'), logger.db('saveConversation succeed id=xxx')
  void app(String m) => info(m, cat: LogCat.app);
  void ui(String m) => info(m, cat: LogCat.ui);
  void nav(String m) => info(m, cat: LogCat.nav);
  void db(String m) => info(m, cat: LogCat.db);
  void dbWarn(String m) => warn(m, cat: LogCat.db);
  void chat(String m) => info(m, cat: LogCat.chat);
  void api(String m) => info(m, cat: LogCat.api);
  void react(String m) => info(m, cat: LogCat.react);
  void compress(String m) => info(m, cat: LogCat.compress);
  void ws(String m) => info(m, cat: LogCat.ws);
  void download(String m) => info(m, cat: LogCat.download);
  void backup(String m) => info(m, cat: LogCat.backup);
  void config(String m) => info(m, cat: LogCat.config);
  void perf(String m) => info(m, cat: LogCat.perf);

  // 带 VERBOSE 级别的分类变体
  void vChat(String m) => verbose(m, cat: LogCat.chat);
  void vReact(String m) => verbose(m, cat: LogCat.react);
  void vWs(String m) => verbose(m, cat: LogCat.ws);
  void vApi(String m) => verbose(m, cat: LogCat.api);

  // v1.7.16：日志写入节流通知——ReAct 流式期每秒数千条日志，每条 notifyListeners
  // 会造成重建风暴。按 200ms 节流 + 尾部 Timer 兜底，确保最终状态能刷出来。
  DateTime _lastNotifyAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _pendingNotify;

  void _notifyThrottled() {
    // build138（扫描 P1-7 的连带修复）：**没有监听者就不排 Timer**。
    // 原来每条日志都可能排一个 200ms 尾部 Timer 去 notifyListeners——
    // ① 生产环境里这是纯多余的空转；
    // ② 单测里它会在 widget 树销毁后仍然 pending，直接把用例判成
    //    "A Timer is still pending even after the widget tree was disposed"
    //    （新增的 registry 启动期日志一接上 LoggerService 就踩中，
    //     t9_fault_fixture_test / widget_test 各挂一次）。
    // 日志本身已经同步进了缓冲与文件，通知只是给 UI 刷新高频日志用的。
    if (!hasListeners) return;
    // build/layout/paint 期间 notifyListeners 会抛
    // "setState() or markNeedsBuild() called during build"（日志可能在 build 里写）。
    // 非 idle 阶段一律推迟到帧末微任务后再通知。
    // 单测无 WidgetsFlutterBinding 时访问 SchedulerBinding.instance 会断言，
    // 用 try/catch 兜底：拿不到 binding 就跳过阶段检查。
    SchedulerBinding? binding;
    try {
      binding = SchedulerBinding.instance;
    } catch (_) {
      binding = null;
    }
    if (binding != null) {
      final phase = binding.schedulerPhase;
      if (phase != SchedulerPhase.idle &&
          phase != SchedulerPhase.postFrameCallbacks) {
        _pendingNotify ??= Timer(const Duration(milliseconds: 200), () {
          _pendingNotify = null;
          _lastNotifyAt = DateTime.now();
          notifyListeners();
        });
        return;
      }
    }
    final now = DateTime.now();
    if (now.difference(_lastNotifyAt) >= const Duration(milliseconds: 200)) {
      _lastNotifyAt = now;
      _pendingNotify?.cancel();
      _pendingNotify = null;
      notifyListeners();
    } else {
      _pendingNotify ??= Timer(const Duration(milliseconds: 200), () {
        _pendingNotify = null;
        _lastNotifyAt = DateTime.now();
        notifyListeners();
      });
    }
  }

  // ---------- 核心：写日志 ----------
  void _write(String level, String msg, {LogCat? cat, String? tag}) {
    final safeMsg = level == 'VERBOSE'
        ? _scrubSensitive(msg, truncate: false)
        : _scrubSensitive(msg);
    final floodKey = '$level|${cat?.key ?? 'GEN'}|$safeMsg';
    final lastTime = _lastLogTime[floodKey];
    final nowTime = DateTime.now();
    if (lastTime != null && nowTime.difference(lastTime) < _floodWindow) {
      return;
    }
    _lastLogTime[floodKey] = nowTime;
    if (_lastLogTime.length > 5000) {
      _lastLogTime.clear();
    }
    final now = nowTime; // 行格式：
    //   2026-08-20T18:12:48.488 [INFO][UI][新建聊天] 按钮被点击
    //   2026-08-20T18:12:49.001 [INFO][REACT] detected tag: <ask_user>
    final c = cat?.key ?? 'GEN';
    final lineParts = [
      now.toIso8601String(),
      '[$level]',
      '[$c]',
      if (tag != null) '[$tag]',
      safeMsg,
    ];
    final line = lineParts.join(' ');

    // 1) 内存缓冲（总量）
    _buffer.add(line);
    if (_buffer.length > maxMemoryLines) {
      _buffer.removeRange(0, _buffer.length - maxMemoryLines);
    }
    // 2) 按分类缓冲
    if (cat != null) {
      final bucket = _byCat[cat] ??= [];
      bucket.add(line);
      if (bucket.length > maxMemoryLines) {
        bucket.removeRange(0, bucket.length - maxMemoryLines);
      }
    }
    _notifyThrottled();

    // 3) 文件（不阻塞 UI，但**串行**写；失败不抛）
    // v1.6.8 修复 Bug#11：原代码用一堆 *Sync 方法，每条日志都阻塞主线程做磁盘 IO ⇒ 改异步。
    // build152（日志挖掘 §2k）：那次改出了**第二个**问题 —— `unawaited(_writeFileAsync(...))`
    // 是"每条日志各起一个异步任务"，于是多个 append 与那个滚动 `rename` 会在事件循环里交错：
    // 真机日志里能看到被吃掉前缀的裸尾巴（`irect: Exception: HTTP 404 | …`、` lifecycle observer`），
    // 也就是**一条 ERROR 的时间戳与级别整段丢失**。这个仓库的定位流程全靠导出日志，
    // 行被撕断等于把证据本身弄坏了 —— 所以保留"不阻塞调用方"，改成挂在一条链上串行落盘。
    if (_initialized && _logDir != null) {
      _writeChain = _writeChain
          .then((_) => _writeFileAsync(line, now))
          // 上一次失败不许把整条链断掉（断了之后所有日志静默不再落盘）。
          .catchError((_) {});
    }

    // 4) debugPrint 让 IDE 也能看到
    debugPrint(line);
  }

  /// 异步文件写入（v1.6.8 修复 Bug#11）：把同步 *Sync 调用全部改为 async/await，
  /// 让 event loop 调度，不阻塞调用方。
  Future<void> _writeFileAsync(String line, DateTime now) async {
    try {
      final date =
          '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
      final file = File(p.join(_logDir!.path, 'nexus_$date.log'));
      if (await file.exists() && await file.length() > maxFileBytes) {
        final rolled = File('${file.path}.1');
        if (await rolled.exists()) await rolled.delete();
        await file.rename(rolled.path);
      }
      await file.writeAsString('$line\n', mode: FileMode.append, flush: true);
    } catch (e) {
      debugPrint('Logger write failed: $e');
    }
  }

  /// 脱敏：移除/遮挡可能出现在日志里的敏感信息
  ///
  /// v1.4.2 扩展：
  ///   - 新增 `Authorization` 通用 Bearer 前缀（支持无引号/有引号/大写变体）
  ///   - 支持更广泛的 sk-* / xox* / gsk* 等 API Key 前缀
  ///   - 支持 `tavily-xxx` / `tvly-xxx` / `serp_xxx` / `brave-xxx` / `google_xxx` 等搜索 Key
  ///   - 对长 token 只保留前 4 后 4 位
  static String _scrubSensitive(String msg, {bool truncate = true}) {
    if (msg.isEmpty) return msg;
    String s = msg;

    // 1) Authorization: Bearer <token> （覆盖各种大小写/引号/空格）
    s = s.replaceAllMapped(
      RegExp(
          r'("?Authorization"?\s*:?\s*"?)\s*(Bearer|Basic)\s+([A-Za-z0-9\-_.=]+)',
          caseSensitive: false),
      (m) {
        final prefix = m.group(1)!;
        final scheme = m.group(2)!;
        final token = m.group(3)!;
        return '$prefix$scheme ${_maskToken(token)}';
      },
    );

    // 2) 通用 api_key / apikey / api-key 等
    s = s.replaceAllMapped(
      RegExp(
          r'("?api[_-]?key"?\s*[:=]\s*"?)([^\s&",\]\}\)]+)(?=[\s&",\]\}\)]|$)',
          caseSensitive: false),
      (m) => '${m.group(1)}***',
    );

    // 3) 常见云 / 开源 API Key 前缀（支持长 token 不截断）
    s = s.replaceAllMapped(
      RegExp(
          r'\b(sk|pk|rk|xox[baprs]|ghp|gho|ghu|ghr|glm|glmao|deepseek|ds|vllm|qwen|gsk|msk|ant|claude|apikey|ollama)-[A-Za-z0-9\-/.]{10,}\b',
          caseSensitive: false),
      (m) => _maskToken(m.group(0)!),
    );

    // 4) 搜索服务商 API Key
    s = s.replaceAllMapped(
      RegExp(
          r'\b(tvly|tavily|serpapi|serp|brave|google|bing)_?[A-Za-z0-9\-]{12,}\b',
          caseSensitive: false),
      (m) => '${m.group(1)}-***',
    );

    // 4b) AWS Access Key（AKIA + 16 位大写字母数字，20 字符总长）
    s = s.replaceAllMapped(
      RegExp(r'\bAKIA[A-Z0-9]{16}\b'),
      (m) => _maskToken(m.group(0)!),
    );

    // 5) 通用长 Token（至少 24 字符的 base64-hex 混合串，带/不带前缀）
    s = s.replaceAllMapped(
      RegExp(r'\b([A-Za-z0-9_\-\.]{32,})\b'),
      (m) => _maskToken(m.group(1)!),
    );

    // 6) build153：**按值/按形态的统一收尾兜底**（与备份导出共用
    //    lib/utils/redact.dart，写前单点）。上面 1)~5) 全是"认前缀/认长度"的
    //    模式，仍有缝：裸 `Bearer <token>`（无 Authorization 头名）、含 `+` `/`
    //    的 base64 Basic 段（1 的模式类漏这两个字符，匹配半截就断）、
    //    `?key=` 查询位、多行请求体里的 Authorization 行。这一道不认字段名，
    //    只认密钥形态，且 token 字符类都不含 `\n` + 头行 multiLine 逐行锚定
    //    ⇒ 多行内容里每一行都能独立命中，行数结构不坏。
    //    放在最后的理由：1)~5) 已按旧契约（`xxxx***xxxx`）处理掉的串，这里
    //    只会原样稳定通过（占位符守卫见 _maskToken），不破坏 logger_scrub_test
    //    锁定的历史格式。
    s = redact.redactSecretsInText(s);

    if (truncate && s.length > 500) {
      s = '${s.substring(0, 120)} ... [TRUNCATED ${s.length} chars] ... ${s.substring(s.length - 120)}';
    }
    return s;
  }

  /// 长 token 脱敏：保留前 4 后 4，中间用 *** 替换
  static String _maskToken(String token) {
    // build153：上游共享脱敏已落成 __REDACTED__ 的位置**不得再剥**——
    // 否则占位符本身被 mask 成 `__RE***ED__`，二次 scrub 不再幂等
    // （日志去重 floodKey 与测试都依赖"同一输入同一输出"）。
    if (token == redact.kRedactedPlaceholder) return token;
    if (token.length <= 8) return '***';
    return '${token.substring(0, 4)}***${token.substring(token.length - 4)}';
  }

  // ---------- 测试可见桥（供 test/ 目录使用） ----------
  @visibleForTesting
  static String scrubForTest(String msg, {bool truncate = true}) =>
      _scrubSensitive(msg, truncate: truncate);

  @visibleForTesting
  static String maskForTest(String token) => _maskToken(token);

  // ---------- 公开脱敏（供自检等生产代码复用同一套逻辑） ----------
  /// 对一段文本做敏感信息脱敏，返回脱敏后的结果（自检服务用）。
  static String scrubSensitive(String msg, {bool truncate = true}) =>
      _scrubSensitive(msg, truncate: truncate);

  // ---------- UI / 导出 ----------
  /// 把所有现有日志（内存 + 全部日志文件）合并成一个字符串
  Future<String> exportAllText() async {
    final sb = StringBuffer();
    sb.writeln(
        '===== Nexus Log Export $kAppVersionConst ${DateTime.now().toIso8601String()} =====');
    sb.writeln('Categories: ${LogCat.values.map((c) => c.key).join(', ')}');
    if (_logDir != null && _logDir!.existsSync()) {
      final files = _logDir!
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.log'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final f in files) {
        sb.writeln('\n----- FILE: ${p.basename(f.path)} -----');
        try {
          sb.writeln(f.readAsStringSync());
        } catch (_) {
          try {
            sb.writeln(f.readAsStringSync(encoding: latin1));
          } catch (e) {
            sb.writeln('  (read failed: $e)');
          }
        }
      }
    }
    sb.writeln(
        '\n----- IN-MEMORY BUFFER (latest ${_buffer.length} lines) -----');
    sb.writeln(_buffer.join('\n'));
    return sb.toString();
  }

  Future<String> exportToSingleFile() async {
    await init();
    final text = await exportAllText();
    final ts =
        DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    final out = File(p.join(_logDir!.path, 'nexus_export_$ts.txt'));
    await out.writeAsString(text, flush: true);
    app('Log exported to ${out.path}');
    return out.path;
  }

  Future<String?> logDirPath() async {
    await init();
    return _logDir?.path;
  }

  Future<List<File>> listLogFiles() async {
    await init();
    if (_logDir == null) return [];
    return _logDir!
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.log') || f.path.endsWith('.txt'))
        .toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
  }

  /// 「日志被清空」的代数：任何按签名节流的一次性日志都要把它算进签名，
  /// 否则用户清空日志后复现就再也打不出那一行（build142 修的正是这个）。
  int _clearGeneration = 0;
  int get clearGeneration => _clearGeneration;

  Future<void> clearAll() async {
    _buffer.clear();
    for (final c in LogCat.values) {
      _byCat[c]?.clear();
    }
    if (_logDir != null && _logDir!.existsSync()) {
      for (final f in _logDir!.listSync().whereType<File>()) {
        try {
          f.deleteSync();
        } catch (e) { debugPrint('catch 静默异常: $e'); }
      }
    }
    notifyListeners();
    // build142（键盘采数补修）：**先自增代数再写这条**。
    // 节流签名不带代数的话，「清空日志 → 复现 → 导出」会什么都不打 ——
    // 判据的签名与清空前一模一样，而清空把唯一那行删掉了。
    // 真机 07:39 那份导出里没有 [Keyboard] 行，根因就是这个（build141 记为遗留）。
    _clearGeneration++;
    app('Logs cleared by user');
  }

  void _purgeOldLogs() {
    if (_logDir == null || !_logDir!.existsSync()) return;
    final cutoff = DateTime.now().subtract(const Duration(days: maxKeptDays));
    for (final f in _logDir!.listSync().whereType<File>()) {
      try {
        final stat = f.statSync();
        if (stat.modified.isBefore(cutoff)) {
          f.deleteSync();
        }
      } catch (e) { debugPrint('catch 静默异常: $e'); }
    }
  }

  List<String> search(String query, {LogCat? cat}) {
    if (query.isEmpty) return [];
    final lower = query.toLowerCase();
    final source = cat != null ? (_byCat[cat] ?? []) : _buffer;
    return source.where((line) => line.toLowerCase().contains(lower)).toList();
  }

  List<String> searchByCategory(LogCat cat, {String? query}) {
    final lines = _byCat[cat] ?? [];
    if (query == null || query.isEmpty) return List.unmodifiable(lines);
    final lower = query.toLowerCase();
    return lines.where((l) => l.toLowerCase().contains(lower)).toList();
  }

  @override
  void dispose() {
    _pendingNotify?.cancel();
    _pendingNotify = null;
    super.dispose();
  }
}
