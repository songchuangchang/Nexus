import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';

import '../utils/regex_safety.dart';
import 'file_open_service.dart';
import 'logger_service.dart';
import 'security_gate.dart';

/// build136（G66）：补丁计划结果——成功带新内容，失败带可读原因。
///
/// 「失败」是正常输出而非异常：事务式补丁要求任一前提不成立就整体拒绝，
/// 并把原因回灌给模型（Codex apply_patch 的核心洞见——把「改错函数」
/// 挡在 apply 阶段，而不是留到运行阶段才发现）。
class PatchOutcome {
  final String? content;
  final String? error;
  final int occurrences;
  final int line;

  const PatchOutcome._({
    this.content,
    this.error,
    this.occurrences = 0,
    this.line = 0,
  });

  bool get ok => error == null;
}

/// build136（G67）：一条检索命中（`文件:行号: 内容`）。
class GrepHit {
  final String file;
  final int line;
  final String text;

  const GrepHit(this.file, this.line, this.text);

  @override
  String toString() => '$file:$line: $text';
}

/// build113（任务五 WS-1）：应用内 AI 文件工作区。
///
/// AI 在 [root]（`<Documents>/ai_workspace/`）内拥有受限读写能力：
/// 下载网络文本 → 读取/改写/删除 → 分享/打开。**只处理文本类小文件，
/// 不执行文件内容、不编译、不跑代码**。
///
/// 安全红线（WS-4，验收 G26/G27）：
/// - 路径逃不出 [root]：入参相对路径先 normalize，结果必须仍在根内；
///   拒绝 `..` 越界 / 绝对路径 / 盘符 / 超长名 / 深度 >3；越界返回结构化错误，
///   不崩、不写。
/// - 下载仅 HTTPS 且过 SecurityGate.auditUrl；一期只收文本类扩展名。
/// - 限额：单文本文件 ≤1MB、单次下载 ≤10MB、总量 ≤50MB、文件数 ≤200。
/// - 写入走「临时文件 + rename 原子替换」，杜绝半截文件；默认不覆盖。
/// - 所有错误可见化（结构化结果），禁止静默失败或静默成功。
class WorkspaceService {
  WorkspaceService._();

  static final LoggerService _logger = LoggerService.instance;

  // ===== 限额常量（可调） =====
  static const int maxFileBytes = 1 * 1024 * 1024; // 单文本文件 1MB
  static const int maxDownloadBytes = 10 * 1024 * 1024; // 单次下载 10MB
  static const int maxTotalBytes = 50 * 1024 * 1024; // 工作区总量 50MB
  static const int maxFileCount = 200;
  static const int maxNameLen = 120; // 单段文件/目录名长度
  static const int maxDepth = 3; // 子目录深度
  static const int readBackLimit = 30000; // readText 回灌上限（对齐附件口径）
  static const Duration downloadTimeout = Duration(seconds: 15);

  /// build138（G63）：二进制产物的单文件上限（11MB 的 xlsx 必须被限额拒绝）。
  static const int maxBinaryFileBytes = 10 * 1024 * 1024;

  /// 一期只收文本类（G27：错误 Content-Type / 二进制拒绝）
  static const Set<String> textExtensions = {
    'txt', 'md', 'markdown', 'json', 'csv', 'tsv', 'log', 'xml', 'html',
    'htm', 'yaml', 'yml', 'ini', 'toml', 'css', 'js', 'ts', 'py', 'java',
    'kt', 'go', 'rs', 'c', 'h', 'cpp', 'sh', 'bat', 'sql', 'dart', 'svg',
  };

  /// build138（G61/G62/G63）：工作区可存的二进制**产物**类型。
  ///
  /// 刻意只收这三类（都是本 App 自己能生成、也能自己读回的）：
  /// - 图片/视频不进工作区（走附件与生成页，那里有缩略图与配额）；
  /// - `.xls`/`.doc` 这些「旧二进制 Office」不收 —— 我们没有真生成器，
  ///   收了就等于允许「换扩展名的假文件」混进来（G64 红线的另一面）。
  static const Set<String> binaryExtensions = {'xlsx', 'docx', 'pdf'};

  /// 取扩展名（小写，无点）；无扩展名返回空串。
  static String extOf(String name) {
    final base = name.split(RegExp(r'[/\\]')).last;
    final i = base.lastIndexOf('.');
    if (i <= 0 || i == base.length - 1) return '';
    return base.substring(i + 1).toLowerCase();
  }

  /// 是否二进制产物名。判定只看扩展名白名单，不看内容（内容由生成器保证）。
  static bool isBinaryName(String rel) => binaryExtensions.contains(extOf(rel));

  /// 工作区条目的类型标注（G63：ws_list 要能区分文本/二进制，
  /// 模型据此决定「读回」还是「直接导出」）。
  static String kindOf(String rel) {
    final ext = extOf(rel);
    if (binaryExtensions.contains(ext)) return 'binary:$ext';
    if (textExtensions.contains(ext)) return 'text:$ext';
    return ext.isEmpty ? 'unknown' : 'other:$ext';
  }

  static Directory? _cachedRoot;

  /// 测试钩子：注入临时目录替代 path_provider（G26 单测用）。
  @visibleForTesting
  static Directory? overrideRoot;

  /// 工作区根目录（懒创建）。
  static Future<Directory> root() async {
    if (overrideRoot != null) return overrideRoot!;
    if (_cachedRoot != null) return _cachedRoot!;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}${Platform.pathSeparator}ai_workspace');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _cachedRoot = dir;
    return dir;
  }

  /// 统一结果对象见文件底部 [WorkspaceResult]。

  // ---------------------------------------------------------------------------
  // 路径安全（G26 红线，纯函数部分可单测）
  // ---------------------------------------------------------------------------

  /// 文件/目录单段名白名单：字母/数字/下划线/中划线/点/空格/中文。
  static bool isValidSegment(String seg) {
    if (seg.isEmpty || seg.length > maxNameLen) return false;
    if (seg == '.' || seg == '..') return false;
    return RegExp(r'^[a-zA-Z0-9_\-\. \u4e00-\u9fff]+$').hasMatch(seg);
  }

  /// 校验相对路径并返回「根内绝对路径」；不合法返回 null（结构化错误）。
  ///
  /// 规则：禁止绝对路径/盘符；禁止 `..` 段；逐段过白名单；深度 ≤3；
  /// 归一化后必须仍在根内（双保险）。
  static Future<(String?, String?)> resolve(String rel) async {
    final rootDir = await root();
    var t = rel.trim().replaceAll('\\', '/');
    if (t.isEmpty) return (null, '路径为空');
    if (t.startsWith('/') || t.startsWith(RegExp(r'[A-Za-z]:'))) {
      return (null, '拒绝绝对路径');
    }
    final segs = t.split('/').where((s) => s.isNotEmpty).toList();
    if (segs.any((s) => s == '..' || s == '.')) {
      return (null, '拒绝相对穿越（..）');
    }
    if (segs.any((s) => !isValidSegment(s))) {
      return (null, '文件名不合法（仅允许中英文/数字/下划线/中划线/点，≤$maxNameLen 字）');
    }
    if (segs.length > maxDepth) {
      return (null, '子目录深度超限（≤$maxDepth 层）');
    }
    final abs = '${rootDir.path}${Platform.pathSeparator}${segs.join(Platform.pathSeparator)}';
    final normRoot = '${_normalize(rootDir.path)}/';
    final normAbs = _normalize(abs);
    if (!normAbs.startsWith(normRoot)) {
      return (null, '路径逃出工作区');
    }
    return (abs, null);
  }

  /// 轻量路径归一化：统一分隔符后做前缀比对（工作区内不创建符号链接，
  /// 且 resolve 已先拒绝绝对路径/穿越段，此处为双保险比对）。
  static String _normalize(String p) => p.replaceAll('\\', '/');

  // ---------------------------------------------------------------------------
  // 动作实现
  // ---------------------------------------------------------------------------

  /// 列工作区（名/大小/修改时间），递归 ≤maxDepth 层。
  static Future<List<Map<String, dynamic>>> list() async {
    final dir = await root();
    final out = <Map<String, dynamic>>[];
    if (!dir.existsSync()) return out;
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final st = e.statSync();
      out.add({
        'path': e.path.substring(dir.path.length + 1),
        'name': e.uri.pathSegments.last,
        'bytes': st.size,
        'modified': st.modified.toIso8601String(),
        // build138（G63）：类型标注——模型据此决定读回还是导出，
        // 不再靠猜扩展名（猜错就把 xlsx 当文本读，回灌一堆乱码）。
        'kind': kindOf(e.path.substring(dir.path.length + 1)),
      });
    }
    out.sort((a, b) => (a['path'] as String).compareTo(b['path'] as String));
    return out;
  }

  /// 读文本回灌模型（超 [readBackLimit] 截断并标注）。
  static Future<(String?, bool, String?)> readText(String rel) async {
    final (abs, err) = await resolve(rel);
    if (abs == null) return (null, false, err);
    final f = File(abs);
    if (!f.existsSync()) return (null, false, '文件不存在');
    // build138（G63）：二进制**绝不能按文本读**——xlsx/docx 是 ZIP、pdf 有
    // 二进制流，readAsStringSync 要么抛异常、要么回灌一堆乱码给模型。
    // 这里给结构性拒绝 + 下一步可做什么（不是「读不了」三个字）。
    if (isBinaryName(rel)) {
      return (
        null,
        false,
        '「$rel」是二进制文件（${extOf(rel)}），不能按文本读取。'
            '要给别人看就用 ws_export（mode=open 系统打开 / mode=share 分享）；'
            '要改内容就用 ws_make_file 重新生成一份。'
      );
    }
    final bytes = f.lengthSync();
    if (bytes > maxFileBytes) {
      return (null, false, '文件超限（超过 $maxFileBytes 字节，拒绝读取）');
    }
    // 白名单之外的扩展名（.exe / .zip / 改名后的 office）用「内容嗅探」兜底：
    // 前 4KB 出现 NUL 即判二进制。不这样做的话 readAsStringSync 会抛
    // FormatException，模型只看到「读取失败」而不知道原因。
    if (!textExtensions.contains(extOf(rel))) {
      final raf = f.openSync();
      final List<int> head;
      try {
        head = raf.readSync(4096);
      } finally {
        raf.closeSync();
      }
      if (head.contains(0)) {
        return (null, false, '「$rel」不是文本文件（内容含二进制字节），拒绝读取。'
            '要给别人看就用 ws_export。');
      }
    }
    String content;
    try {
      // build138（G63）：不用 `readAsStringSync()`——它在 Windows 上把解码失败
      // 包成 FileSystemException（Linux/Android 才是 FormatException），
      // catch 口径不统一就会「本该给可读错误」变成异常冒到调用方。
      // 自己按字节读再 utf8.decode，两平台同一异常类型、同一行为。
      content = utf8.decode(f.readAsBytesSync());
    } on FormatException catch (e) {
      return (null, false, '「$rel」不是合法 UTF-8 文本，拒绝读取（$e）。'
          '要给别人看就用 ws_export。');
    }
    var truncated = false;
    if (content.length > readBackLimit) {
      content =
          '${content.substring(0, readBackLimit)}\n…[已截断，全文 ${content.length} 字符]';
      truncated = true;
    }
    return (content, truncated, null);
  }

  /// 写文本（临时文件 + rename 原子替换；[overwrite] 默认 false）。
  static Future<(String?, String?)> writeText(String rel, String content,
      {bool overwrite = false}) async {
    final (abs, err) = await resolve(rel);
    if (abs == null) return (null, err);
    // build138（G64 红线）：二进制格式**只能**由生成器产出（writeBinary /
    // ws_make_file）。用文本通道写 .xlsx/.docx/.pdf 就是「换扩展名的假文件」，
    // 用户拿到手打不开 —— 这正是本单要根除的 HTML 伪装 .xls 的入口。
    if (isBinaryName(rel)) {
      return (null, '「.${extOf(rel)}」是二进制格式，不能用文本写入；'
          '请用 ws_make_file 生成真文件。');
    }
    final bytes = utf8.encode(content).length;
    if (bytes > maxFileBytes) return (null, '写入超限（$bytes 字节 > $maxFileBytes）');
    final f = File(abs);
    if (f.existsSync() && !overwrite) {
      return (null, '文件已存在（需显式 overwrite 才覆盖）');
    }
    // 限额：总量 / 文件数（覆盖写入时排除自身）
    final limitErr = await _checkQuota(bytes,
        exclude: f.existsSync() ? abs : null);
    if (limitErr != null) return (null, limitErr);
    // 父目录（≤3 层由 resolve 保证合法性）
    final parent = f.parent;
    if (!parent.existsSync()) parent.createSync(recursive: true);
    // 原子写：tmp + rename
    final tmp = File('$abs.tmp_${DateTime.now().millisecondsSinceEpoch}');
    try {
      tmp.writeAsStringSync(content, flush: true);
      if (f.existsSync()) f.deleteSync();
      tmp.renameSync(abs);
    } catch (e) {
      // build138（G63 同批）：失败清场，与 writeBinary 一致 —— 半截 .tmp
      // 留在工作区里会被 ws_list 列出来，用户以为是文件。
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (_) {}
      _logger.warn('[Workspace] 文本写入失败 $rel：$e', tag: 'Workspace');
      return (null, '写入失败：$e');
    }
    _logger.info('workspace write: $rel ($bytes bytes)', tag: 'Workspace');
    return (abs, null);
  }

  /// build138（G63）：写**二进制产物**（xlsx/docx/pdf）。
  ///
  /// 与 [writeText] 的关键差异，都是任务书 G63 的点：
  /// - 扩展名必须在 [binaryExtensions] 白名单内（不给「换扩展名的假文件」开门）；
  /// - 单文件上限 [maxBinaryFileBytes]（11MB 直接拒）；
  /// - 同样走「临时文件 + rename」原子替换，**任何一步失败都把 tmp 删干净**
  ///   （渲染异常后工作区里不得有残留文件）。
  static Future<(String?, String?)> writeBinary(
      String rel, List<int> bytes,
      {bool overwrite = false}) async {
    final (abs, err) = await resolve(rel);
    if (abs == null) return (null, err);
    final ext = extOf(rel);
    if (!binaryExtensions.contains(ext)) {
      return (null, '拒绝写入二进制文件「.$ext」（允许：'
          '${binaryExtensions.join('/')}）');
    }
    if (bytes.isEmpty) return (null, '内容为空，未写入。');
    if (bytes.length > maxBinaryFileBytes) {
      return (null, '二进制文件超限（${bytes.length} 字节 > '
          '$maxBinaryFileBytes）');
    }
    final f = File(abs);
    if (f.existsSync() && !overwrite) {
      return (null, '文件已存在（需显式 overwrite 才覆盖）');
    }
    final limitErr =
        await _checkQuota(bytes.length, exclude: f.existsSync() ? abs : null);
    if (limitErr != null) return (null, limitErr);
    final parent = f.parent;
    if (!parent.existsSync()) parent.createSync(recursive: true);
    final tmp = File('$abs.tmp_${DateTime.now().millisecondsSinceEpoch}');
    try {
      tmp.writeAsBytesSync(bytes, flush: true);
      if (f.existsSync()) f.deleteSync();
      tmp.renameSync(abs);
    } catch (e) {
      // 失败清场：半截文件与 .tmp 残留都不许留
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (_) {}
      _logger.warn('[Workspace] 二进制写入失败 $rel：$e', tag: 'Workspace');
      return (null, '写入失败：$e');
    }
    _logger.info('workspace write(binary): $rel (${bytes.length} bytes)',
        tag: 'Workspace');
    return (abs, null);
  }

  // ---------------------------------------------------------------------------
  // build136（G66/G67）：写代码能力——事务式补丁 + 按需检索
  //
  // 参照 Codex CLI 的 apply_patch 与 DSH 的 fs/shell 能力缝，但受手机约束：
  // 仍**不执行、不编译、不跑代码**（沿用工作区红线），只把「改代码」做对——
  // - ws_patch：定位式精准替换，**事务性**：任一前提不成立就整体拒绝，并把可读
  //   原因回灌给模型。相比 ws_write 整文件重写，省 token（手机上尤其关键），
  //   且强制模型承诺上下文行，把「改错函数」挡在 apply 阶段。
  // - ws_grep：按需取上下文（Codex 的 rg/ls/cat 路线），避免整目录回灌。
  // 判定逻辑一律提成顶层纯函数（planPatch / grepInFile），真机数值可写进单测。
  // ---------------------------------------------------------------------------

  /// find 片段长度上限（防模型把整个文件塞进 find 属性）。
  static const int maxPatchFindLen = 4000;
  static const int maxGrepHits = 200;
  static const int maxGrepLineLen = 200;
  static const int maxGrepPatternLen = 200;

  /// 一次 grep 的**总时间预算**（build157，第 15 轮扫描 P1 的第二道闸）。
  ///
  /// 分工要说清，别以为有一道就够：
  /// · [catastrophicBacktrackRisk] 拦的是"静态可判定"的嵌套量词 —— 它是唯一能防住
  ///   **单行**卡死的那道（实测 `^(a+)+b` 配 32 字符就要 113 秒，那时换文件已经太晚）；
  /// · 这一条预算拦的是"pattern 没被静态闸抓住、但扫遍整个工作区越来越慢"的累计成本。
  /// 超预算时**必须把"被截断"说出来**：把"没扫完"报成"没命中"，模型就会照着这个
  /// 假事实继续往下推理（本仓库反复出现的静默降级形状）。
  static const int grepTimeBudgetMs = 3000;

  /// 补丁计划（纯函数）：成功给新内容，失败给可读原因 + 出现次数/行号。
  static PatchOutcome planPatch(String content, String find, String replace,
      {bool all = false}) {
    if (find.isEmpty) return const PatchOutcome._(error: 'find 不能为空');
    if (find.length > maxPatchFindLen) {
      return PatchOutcome._(
          error: 'find 过长（${find.length} 字符 > $maxPatchFindLen），请缩短为唯一片段');
    }
    if (find == replace) {
      return const PatchOutcome._(error: 'find 与 replace 完全相同，没有改动');
    }
    final occurrences = <int>[];
    var from = 0;
    while (occurrences.length <= 50) {
      final i = content.indexOf(find, from);
      if (i < 0) break;
      occurrences.add(i);
      from = i + find.length;
    }
    if (occurrences.isEmpty) {
      return const PatchOutcome._(
          error: '未找到该片段（缩进/换行需与原文逐字一致；建议先 ws_grep 或 ws_read 取回原文再改）');
    }
    if (occurrences.length > 1 && !all) {
      final lines =
          occurrences.take(5).map((o) => _lineOf(content, o)).join('、');
      return PatchOutcome._(
          occurrences: occurrences.length,
          error: '该片段出现 ${occurrences.length} 次（行 $lines），不够唯一：'
              '请把上下文行一起写进 find，或加 all="true" 全部替换');
    }
    final next = all
        ? content.replaceAll(find, replace)
        : content.replaceRange(
            occurrences.first, occurrences.first + find.length, replace);
    if (utf8.encode(next).length > maxFileBytes) {
      return const PatchOutcome._(
          error: '改动后超单文件上限（$maxFileBytes 字节），请拆分文件');
    }
    return PatchOutcome._(
      content: next,
      occurrences: all ? occurrences.length : 1,
      line: _lineOf(content, occurrences.first),
    );
  }

  /// 偏移量 → 行号（1 起）。
  static int _lineOf(String content, int offset) =>
      '\n'.allMatches(content.substring(0, offset)).length + 1;

  /// 按需检索单文件（纯函数；[re] 由调用方编译，超长行只在截断窗口内匹配）。
  static List<GrepHit> grepInFile(String rel, String content, RegExp re,
      {int max = maxGrepHits}) {
    final hits = <GrepHit>[];
    final lines = content.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.length > maxGrepLineLen) {
        if (re.hasMatch(line.substring(0, maxGrepLineLen))) {
          hits.add(
              GrepHit(rel, i + 1, '${line.substring(0, maxGrepLineLen)}…'));
        }
      } else if (re.hasMatch(line)) {
        hits.add(GrepHit(rel, i + 1, line));
      }
      if (hits.length >= max) break;
    }
    return hits;
  }

  /// 读原文（不截断，供补丁定位用）；超限返回错误。
  static Future<(String?, String?)> _readRaw(String rel) async {
    final (abs, err) = await resolve(rel);
    if (abs == null) return (null, err);
    final f = File(abs);
    if (!f.existsSync()) return (null, '文件不存在');
    if (f.lengthSync() > maxFileBytes) {
      return (null, '文件超限（超过 $maxFileBytes 字节）');
    }
    return (f.readAsStringSync(), null);
  }

  /// 事务式精准替换：定位失败 ⇒ 整体不落盘，返回可读原因。
  static Future<(PatchOutcome?, String?)> applyPatch(
      String rel, String find, String replace,
      {bool all = false}) async {
    final (content, rerr) = await _readRaw(rel);
    if (content == null) return (null, rerr);
    final plan = planPatch(content, find, replace, all: all);
    if (!plan.ok) return (plan, null);
    final (abs, werr) = await writeText(rel, plan.content!, overwrite: true);
    if (abs == null) return (null, werr);
    _logger.info('workspace patch: $rel（${plan.occurrences} 处）',
        tag: 'Workspace');
    return (plan, null);
  }

  /// 按需检索工作区（[glob] 支持 `*.dart` 这类末段通配；缺省扫全部文本文件）。
  static Future<(List<GrepHit>, String?)> grep(String pattern,
      {String glob = '', bool ignoreCase = false}) async {
    final p = pattern.trim();
    if (p.isEmpty) return (const <GrepHit>[], 'pattern 不能为空');
    if (p.length > maxGrepPatternLen) {
      return (const <GrepHit>[], 'pattern 过长（≤$maxGrepPatternLen 字符）');
    }
    // build157（第 15 轮扫描 P1）：语法合法 ≠ 能跑。`^(a+)+b` 这种嵌套量词
    // 在 irregexp 上是灾难性回溯，实测 32 字符输入要 113 秒，而这条循环在 UI isolate 上
    // ⇒ App 冻死。pattern 由**模型**写，所以这道闸不能指望调用方自觉。
    final risk = catastrophicBacktrackRisk(p);
    if (risk != null) {
      return (
        const <GrepHit>[],
        '正则会被引擎卡死（$risk）：请改成人能跑的写法，'
            '例如把 (a+)+ 展平成 a+，或用两个更简单的 pattern 分两次查'
      );
    }
    final RegExp re;
    try {
      re = RegExp(p, caseSensitive: !ignoreCase);
    } on FormatException catch (e) {
      return (const <GrepHit>[], '正则不合法：${e.message}');
    }
    final files = await list();
    final hits = <GrepHit>[];
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    var scanned = 0;
    for (final f in files) {
      final rel = f['path']?.toString() ?? '';
      if (rel.isEmpty) continue;
      if (!globMatch(rel, glob)) continue;
      // 第二道闸：见 [grepTimeBudgetMs] 的分工说明。检查点放在读文件之前，
      // 因为工作区可能上百个文件，`_readRaw` 本身就是主要成本之一。
      if (grepOverBudget(
          startedAtMs: startedAt,
          nowMs: DateTime.now().millisecondsSinceEpoch,
          budgetMs: grepTimeBudgetMs)) {
        return (
          hits,
          '检索超出 ${grepTimeBudgetMs}ms 预算被截断（只扫完 $scanned 个文件，'
              '停在 $rel 之前）：这不是"没命中"，请缩小 glob 或简化 pattern'
        );
      }
      scanned++;
      final (content, _) = await _readRaw(rel);
      if (content == null) continue; // 超限/不可读：跳过
      hits.addAll(grepInFile(rel, content, re, max: maxGrepHits - hits.length));
      if (hits.length >= maxGrepHits) break;
    }
    return (hits, null);
  }

  /// 末段通配匹配（纯函数）：`*.dart` / `test_*.txt` / `src/*.dart`。
  static bool globMatch(String rel, String glob) {
    final g = glob.trim().toLowerCase().replaceAll('\\', '/');
    if (g.isEmpty) return true;
    final r = rel.toLowerCase().replaceAll('\\', '/');
    if (!g.contains('*')) return r == g || r.endsWith('/$g');
    final parts = g.split('/');
    final segs = r.split('/');
    if (parts.length > segs.length) return false;
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      final seg = segs[segs.length - parts.length + i];
      if (!part.contains('*')) {
        if (part != seg) return false;
      } else {
        final re = RegExp('^${RegExp.escape(part).replaceAll(r'\*', '.*')}\$');
        if (!re.hasMatch(seg)) return false;
      }
    }
    return true;
  }

  static Future<void> delete(String rel) async {
    final (abs, err) = await resolve(rel);
    if (abs == null) throw FileSystemException(err ?? '路径不合法');
    final f = File(abs);
    if (!f.existsSync()) throw const FileSystemException('文件不存在');
    f.deleteSync();
    _logger.info('workspace delete: $rel', tag: 'Workspace');
  }

  /// build145（循环审查第 7 轮 P0-5）：流式读完响应体，**边读边判体积上限**。
  ///
  /// 这是「上限保护内存」的唯一实现点，单独成函数并可被单测直接喂一条流：
  /// [downloadFromUrl] 前面横着 https 硬闸与 SecurityGate 的私网/回环拦截
  /// （GATE-URL-002），单测环境打不进它的网络段（详见 build145 测试文件头）。
  ///
  /// 语义：累计字节一超过 [maxBytes] 就 return（`await for` 异常退出会取消订阅、
  /// 连接随之断开），剩下的 body **一个字节都不再读**，内存峰值 ≈
  /// maxBytes + 一个分块。[budget] 是**整段读取**的墙钟预算：`stream.timeout`
  /// 管住「一条字节都不发」的僵死连接，循环里的 Stopwatch 管住「每 10s 滴一个
  /// 字节」的慢速服务器（逐事件超时对后者永远不触发，这正是旧写法漏掉的那一半）。
  ///
  /// 返回 `(bytes, null)` 或 `(null, 最终文案)`；文案已是给模型看的口径
  /// （`下载体超限（>NMB）` / `下载失败：…`），调用方直接透出，别再包一层。
  @visibleForTesting
  static Future<(Uint8List?, String?)> drainCapped(
    Stream<List<int>> stream, {
    int maxBytes = maxDownloadBytes,
    Duration budget = downloadTimeout,
  }) async {
    // copy:false：socket 分块本身就是 Uint8List，再拷一份等于把峰值翻倍
    final builder = BytesBuilder(copy: false);
    final sw = Stopwatch()..start();
    try {
      await for (final chunk in stream.timeout(budget)) {
        builder.add(chunk);
        if (builder.length > maxBytes) {
          return (null, '下载体超限（>${maxBytes ~/ 1048576}MB）');
        }
        if (sw.elapsed >= budget) {
          return (null,
              '下载失败：TimeoutException after $budget（读取阶段超出总预算）');
        }
      }
    } catch (e) {
      // 含 TimeoutException（僵死/断流）与网络错误，口径与旧代码的 catch 一致
      return (null, '下载失败：$e');
    }
    return (builder.takeBytes(), null);
  }

  /// 下载进工作区（HTTPS + SecurityGate + 限额 + 文本类型）。
  /// [filename] 缺省取 URL 末段；重名自动追加 (1)。
  static Future<(String?, int?, String?)> downloadFromUrl(String url,
      {String? filename}) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.scheme != 'https') {
      return (null, null, '仅允许 https 下载');
    }
    try {
      final findings = await SecurityGate.auditUrl(url);
      if (findings.isNotEmpty) {
        return (null, null,
            '安全审查未通过：${findings.map((f) => f.title).join('；')}');
      }
    } catch (e) {
      return (null, null, '安全审查异常：$e');
    }
    // 扩展名白名单
    var name = (filename?.trim().isNotEmpty ?? false)
        ? filename!.trim()
        : uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? 'download.txt';
    name = name.replaceAll('\\', '/').split('/').last;
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    if (!textExtensions.contains(ext)) {
      return (null, null, '仅支持文本类扩展名（txt/md/json/csv/log/xml/html/代码文本…），拒绝「.$ext」');
    }
    if (!isValidSegment(name)) return (null, null, '文件名不合法');

    // build145（循环审查第 7 轮 P0-5）：下面曾是 `http.get(...)` 拿到 resp 之后
    // 再比 `resp.bodyBytes.length > maxDownloadBytes` —— **那是事后检查**：
    // `http.get` 会先把整个响应体缓冲进内存，第一个字节都还没比对，恶意/慢速
    // 服务器给一个 5GB body 就已经把 App OOM 掉了，永远走不到「下载体超限」
    // 那一行。旧上限只保护了磁盘，没保护内存。**别为了"简洁"把这里改回
    // http.get**，那等于把这条 P0 请回来。现在改成 send() 拿 StreamedResponse
    // → [drainCapped] 逐块累计，一超限立刻断流。
    final sw = Stopwatch()..start(); // 墙钟预算从发请求起算（旧代码只管首包）
    final client = http.Client(); // 逐请求实例；漏 close 在本仓库按缺陷处理
    Uint8List? bodyBytes;
    Map<String, String> respHeaders = const {};
    try {
      final req = http.Request('GET', uri)
        ..headers['User-Agent'] = 'Nexus-Workspace/1.0';
      // followRedirects / maxRedirects 沿用 http 默认（true / 5）：本条只修内存
      // 上限，「auditUrl 审的是入参 URL、请求却可能已被重定向到别处」的 SSRF
      // 缺口是另一件事，不在这里顺手改口径。
      final resp = await client.send(req).timeout(downloadTimeout);
      if (resp.statusCode != 200) {
        return (null, null, 'HTTP ${resp.statusCode}');
      }
      // 读取段只能用完剩下的预算：负数会被 Stream.timeout 的 RangeError 拒掉，
      // 预算已耗尽时按「立刻超时」处理才是正确语义。
      final left = downloadTimeout - sw.elapsed;
      final (bytes, derr) = await drainCapped(
          resp.stream, budget: left.isNegative ? Duration.zero : left);
      if (derr != null) {
        // 超限/超时的文案已是最终口径，且**在 writeText 之前返回**＝不落盘
        return (null, null, derr);
      }
      bodyBytes = bytes;
      respHeaders = resp.headers;
    } catch (e) {
      return (null, null, '下载失败：$e');
    } finally {
      client.close();
    }
    // Content-Type 粗查：显式二进制类型拒绝
    final ct = (respHeaders['content-type'] ?? '').toLowerCase();
    if (ct.contains('application/octet-stream') ||
        ct.startsWith('image/') ||
        ct.startsWith('video/') ||
        ct.startsWith('audio/') ||
        ct.contains('zip') ||
        ct.contains('gzip')) {
      return (null, null, '拒绝非文本 Content-Type：$ct');
    }
    // 走到这里 bodyBytes 必非空：超限/超时/状态码/异常都在 try 内 return 了
    final body = utf8.decode(bodyBytes!, allowMalformed: true);
    if (utf8.encode(body).length > maxDownloadBytes) {
      return (null, null, '下载体超限');
    }
    // 重名自动追加 (1)、(2)…
    var rel = name;
    var i = 1;
    while ((await resolve(rel)).$1 != null &&
        File((await resolve(rel)).$1!).existsSync()) {
      final dot = name.lastIndexOf('.');
      rel = dot <= 0
          ? '$name(${i++})'
          : '${name.substring(0, dot)}(${i++})${name.substring(dot)}';
    }
    final (abs, werr) = await writeText(rel, body);
    if (abs == null) return (null, null, werr);
    return (rel, utf8.encode(body).length, null);
  }

  /// file_picker 选文本文件复制进来。
  static Future<(String?, int?, String?)> importFromPicker() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: textExtensions.toList(),
      withData: false,
    );
    if (picked == null || picked.files.isEmpty) return (null, null, '未选择文件');
    final src = picked.files.single;
    if (src.path == null) return (null, null, '选取结果无路径');
    var name = src.name;
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    if (!textExtensions.contains(ext)) {
      return (null, null, '仅支持文本类扩展名，拒绝「.$ext」');
    }
    if (!isValidSegment(name)) return (null, null, '文件名不合法');
    final f = File(src.path!);
    if (f.lengthSync() > maxFileBytes) {
      return (null, null, '文件超限（超过 $maxFileBytes 字节）');
    }
    // 重名追加 (1)
    var rel = name;
    var i = 1;
    while ((await resolve(rel)).$1 != null &&
        File((await resolve(rel)).$1!).existsSync()) {
      final dot = name.lastIndexOf('.');
      rel = dot <= 0 ? '$name(${i++})' : '${name.substring(0, dot)}(${i++})${name.substring(dot)}';
    }
    final (abs, err) = await writeText(rel, f.readAsStringSync());
    if (abs == null) return (null, null, err);
    return (rel, f.lengthSync(), null);
  }

  /// share_plus 系统分享。
  static Future<String?> share(String rel) async {
    final (abs, err) = await resolve(rel);
    if (abs == null) return err;
    if (!File(abs).existsSync()) return '文件不存在';
    await Share.shareXFiles([XFile(abs)]);
    return null;
  }

  /// 系统打开（M2：手机走 open_filex，Windows 由 FileOpenService 降级 explorer）。
  ///
  /// build138（G63）：返回 `(错误, 是否已回退为分享)`。手机上「没有能打开
  /// xlsx/docx 的应用」是常态（没装 WPS/Office），报错了事等于功能不可用 ——
  /// 现在自动回退系统分享面板，让用户自己挑应用，并把这条路径如实告诉模型。
  static Future<(String?, bool)> openExternal(String rel) async {
    final (abs, err) = await resolve(rel);
    if (abs == null) return (err, false);
    if (!File(abs).existsSync()) return ('文件不存在', false);
    final r = await FileOpenService.open(abs);
    if (r.ok) return (null, false);
    final msg = '打开失败：${r.message}';
    try {
      await Share.shareXFiles([XFile(abs)]);
      _logger.info('workspace open→share fallback: $rel (${r.message})',
          tag: 'Workspace');
      return (null, true);
    } catch (e) {
      _logger.warn('[Workspace] open 与 share 均失败 $rel：$e',
          tag: 'Workspace');
      return (msg, false);
    }
  }

  /// 清空工作区（UI 入口，二次确认由调用方负责）。
  static Future<int> clearAll() async {
    final dir = await root();
    var n = 0;
    if (dir.existsSync()) {
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is File) {
          try {
            e.deleteSync();
            n++;
          } catch (_) {}
        }
      }
    }
    _logger.info('workspace cleared: $n files', tag: 'Workspace');
    return n;
  }

  static Future<String?> _checkQuota(int addingBytes,
      {String? exclude}) async {
    final dir = await root();
    var total = 0;
    var count = 0;
    if (dir.existsSync()) {
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        if (exclude != null && e.path == exclude) continue;
        count++;
        total += e.lengthSync();
      }
    }
    if (count + 1 > maxFileCount) return '文件数超限（≤$maxFileCount）';
    if (total + addingBytes > maxTotalBytes) {
      return '工作区总量超限（≤${maxTotalBytes ~/ 1048576}MB）';
    }
    return null;
  }

  /// 动作回灌给模型的文本摘要（ reasoning 不泄漏进答案，仅进工具消息）。
  static String describe(List<Map<String, dynamic>> files) {
    if (files.isEmpty) return '（空）';
    return files.map((f) {
      final kind = f['kind'] as String? ?? '';
      // build145 #9：这条注记在 build141 之后就说谎了 —— 那一批已经把 xlsx/docx/pdf
      // 接上了 `AttachmentService.extractDocument()`（`ws_read` 能抽成文本回灌），
      // 但 ws_list 这里仍对模型说「不能 ws_read」⇒ 模型照描述办事，**永远不去读自己
      // 生成的表格**，于是用户又看到"读不了"（build141 修过的反馈换个入口复发）。
      // 描述必须跟着能力走：按扩展名分「可抽取」与「真读不了」两类。
      final ext = kind.startsWith('binary:') ? kind.substring(7) : '';
      final note = !kind.startsWith('binary:')
          ? ''
          : (binaryExtensions.contains(ext)
              ? ' · 二进制 $ext，可 ws_read（会抽成文本回给你，别让用户重新导出）'
              : ' · 二进制 $ext，无解析器，用 ws_export 打开/分享');
      return '${f['path']}（${((f['bytes'] as int) / 1024).toStringAsFixed(1)}KB$note）';
    }).join('\n');
  }
}

/// 统一结果对象（WS-1）：ok/path/bytes/errorCode/message。
@immutable
class WorkspaceResult {
  final bool ok;
  final String? path;
  final int? bytes;
  final String? errorCode;
  final String? message;
  final bool truncated;

  const WorkspaceResult({
    required this.ok,
    this.path,
    this.bytes,
    this.errorCode,
    this.message,
    this.truncated = false,
  });

  factory WorkspaceResult.fail(String code, String msg) =>
      WorkspaceResult(ok: false, errorCode: code, message: msg);
}
