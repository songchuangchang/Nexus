import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:archive/archive.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:uuid/uuid.dart';
import '../models/chat_message.dart';
import 'biometric_service.dart';
import 'logger_service.dart';
import 'package:flutter/foundation.dart';

/// v1.3.6：📎 附件解析服务
///
/// 支持三类附件：
///   - text  : txt/md/log 等纯文本 → 读文件内容（截断到 30000 字符）
///   - image : 照片 → 复制到 app docs 目录用作缩略图，发 API 时再转 base64
///   - doc   : pdf/docx → 抽取文本（截断到 30000 字符）
///
/// 设计要点：
///   - 图片的 base64 不落库（避免 DB 膨胀），只在调 API 时由 [imageToBase64] 现转
///   - 文本类附件把抽取出来的文本存进 extractedText，发 API 时拼到用户消息正文里
class AttachmentService {
  static const int _maxTextChars = 30000; // 约 7.5k tokens，够用又不爆请求体
  // build129（#106）：改为 public——UI 需要在调用解析前先量体积、决定要不要
  // 「先问一句」（用户口径：插入体积不设硬上限，过大也要问，确认后照办）。
  static const int maxRawFileBytes = 50 * 1024 * 1024;
  static const int _maxPdfBytes = 30 * 1024 * 1024;
  static const int _maxPdfPages = 500;
  static const int _maxDocxBytes = 30 * 1024 * 1024;
  static const int _maxDocxEntries = 200;
  static const int _maxDocxUncompressedBytes = 100 * 1024 * 1024;
  // v1.7.33：XLSX 解析限额（复用 docx 的压缩/条目安全阀思路，独立命名便于后续调参）
  static const int _maxXlsxBytes = 30 * 1024 * 1024;
  static const int _maxXlsxEntries = 200;
  static const int _maxXlsxUncompressedBytes = 100 * 1024 * 1024;
  static const int _maxXlsxCells = 20000;

  // ───────────────────────────────────────────────────────────────────────────
  // build153（用户「通过其他应用分享的文件支持类型太少了，加强一下」）
  //
  // 症状定位：清单侧根本不窄（`AndroidManifest.xml` 的 SEND / SEND_MULTIPLE 都是
  // `*/*`，任何 App 分享都会列到我们），**窄的是分派表**：`_processByExtension`
  // 只认 8 个扩展名，其余一律 `default → null`。所以真机表现是
  // 「分享一张照片给 Nexus → 没反应/不支持」「分享一段 .json / .kt / .html → 不支持」。
  //
  // 三条做法上的约束：
  // 1. **一份名单**：原来 `allowedExtensions` 在 [pickDocument] 与
  //    [pickDocumentsForKnowledge] 各写了一份字面量（两份真源，加类型必漏一处 ——
  //    与本仓教训 #62 同族）。现在两处都从这里派生。
  // 2. 图片要能进：图片走的是 [_processImage] 那条既有路（复制进 docs 目录 +
  //    发 API 时现转 base64），分享只是换了个入口，**不另写第二套图片处理**。
  // 3. 未知扩展名不许"猜格式"，但可以做一件更宽的事：**按内容判定是不是文本**
  //    （见 [looksLikeUtf8Text]）。是就照文本附件处理（原文名保留，模型看得到文件名），
  //    含 NUL / 非法 UTF-8 就照旧拒绝 —— 不把二进制塞进 prompt 是另一条既有口径。
  //    这样"加类型"不必每次改表：`.srt`、`.toml`、某个没听过的代码后缀都能用。

  /// 图片类（按扩展名）。`heic/heif` **故意不在**：我们没有转码，iPhone 原图喂给
  /// 视觉模型会被拒，宁可现在报"不支持"，不要接进来再在 API 那侧失败得更难查。
  static const Map<String, String> imageExtensions = {
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'gif': 'image/gif',
    'webp': 'image/webp',
    'bmp': 'image/bmp',
    'tif': 'image/tiff',
    'tiff': 'image/tiff',
  };

  /// 有专用解析器的文档（二进制容器，**不能**当文本嗅）
  static const List<String> parsedDocExtensions = [
    'pdf',
    'docx',
    'xlsx',
    'pptx',
  ];

  /// 表格（逗号口径特殊，走既有 `_processCsvFile`）
  static const List<String> csvExtensions = ['csv'];

  /// 明确当文本处理的常见后缀（代码/标记/数据/配置）。表外的走内容嗅探兜底，
  /// 所以**这张表不需要穷举、也不要往里编后缀**（曾写过一条不存在的 `txt2`，已删）：
  /// 它的唯一作用是让日志与附件名保持可读，不是白名单闸门。
  static const List<String> textExtensions = [
    'txt', 'md', 'markdown', 'mdx', 'log', 'json', 'jsonl', 'ndjson', 'yaml',
    'yml', 'xml', 'html', 'htm', 'svg', 'css', 'scss', 'less', 'ts', 'tsx',
    'js', 'jsx', 'mjs', 'java', 'kt', 'kts', 'swift', 'go', 'rs', 'c', 'h',
    'cc', 'cpp', 'hpp', 'py', 'rb', 'php', 'lua', 'dart', 'sh', 'bash', 'zsh',
    'bat', 'ps1', 'sql', 'ini', 'conf', 'cfg', 'env', 'properties', 'toml',
    'gitignore', 'editorconfig', 'envrc', 'gradle', 'proto', 'graphql', 'gql',
    'srt', 'vtt', 'ass', 'lrc', 'm3u', 'm3u8', 'nfo', 'diz', 'reg',
  ];

  /// 三处入口共用的文件选择器扩展名名单（图片 + 文档 + 表格 + 文本）
  static final List<String> pickableExtensions = [
    ...textExtensions,
    ...csvExtensions,
    ...parsedDocExtensions,
    ...imageExtensions.keys,
  ];

  /// 分派表（纯函数，也是 [_processByExtension] 唯一的判据）。
  /// 返回值是"族"而不是类型，方便测试与日志。
  static String? attachmentKindFor(String ext) {
    final e = ext.toLowerCase();
    if (imageExtensions.containsKey(e)) return 'image';
    if (csvExtensions.contains(e)) return 'csv';
    if (parsedDocExtensions.contains(e)) return e;
    if (textExtensions.contains(e)) return 'text';
    return null; // 交给内容嗅探那条分支，不等于"不支持"
  }

  /// **表外后缀里明确要拒绝的那一批**：这些不是"还没加进名单"，而是"我们真的没有解析器，
  /// 而内容嗅探又**会**把它们当文本放进来"。最典型就是国内常见的"把 `<table>` 存成 .xls"：
  /// 它是合法 UTF-8、没有 NUL ⇒ 嗅探会判成文本，模型于是读到一整页 HTML 标记 ——
  /// `test/build138_g61_g62_office_test.dart` 钉的就是这条（"伪装文件不许读出一段 HTML"）。
  /// 压缩/可执行/媒体那些**不进这张表**：它们含 NUL，本来就被嗅探挡在外面，
  /// 列出来只会让表与实际判据各说一套。
  static const Set<String> refusedExtensions = {
    'xls', 'doc', 'ppt', 'pps', 'wks', 'wps', 'mdb', 'accdb', // 老式 Office
    'odt', 'ods', 'odp', // OpenDocument 是 zip 容器（同上，防止被当文本）
    'rtf', // 文本但满是标记，抽出来读不通
    'pages', 'keynote', 'key', 'numbers', // iWork 包
  };

  /// 内容嗅探：前 [probeBytes] 字节里没有 NUL、且能严格按 UTF-8 解码 ⇒ 当文本。
  /// 纯函数（只吃 bytes），所以能直接测。刻意**不**做"猜编码/转码"：
  /// GBK/Big5 之类解码失败就是失败，把乱码塞进 prompt 比拒绝更坏（口径同"宁缺毋伪"）。
  static bool looksLikeUtf8Text(List<int> bytes, {int probeBytes = 8192}) {
    final head = bytes.length > probeBytes ? bytes.sublist(0, probeBytes) : bytes;
    if (head.isEmpty) return true; // 空文件按文本走，后面的抽取自然得到空串
    if (head.contains(0)) return false;
    try {
      utf8.decode(head, allowMalformed: false);
    } catch (_) {
      return false;
    }
    return true;
  }
  // ───────────────────────────────────────────────────────────────────────────

  final _log = LoggerService.instance;
  final _picker = ImagePicker();

  /// 从相册选一张照片
  Future<MessageAttachment?> pickImageFromGallery() async {
    BiometricService.beginActivityTransition();
    try {
      final xf = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1280,
        maxHeight: 1280,
        imageQuality: 85,
      );
      if (xf == null) return null;
      return await _processImage(xf);
    } catch (e, st) {
      _log.error('pickImageFromGallery failed',
          error: e, stack: st, tag: 'Att');
      return null;
    } finally {
      Future.delayed(const Duration(seconds: 2), () {
        BiometricService.endActivityTransition();
      });
    }
  }

  /// 拍照
  Future<MessageAttachment?> pickImageFromCamera() async {
    BiometricService.beginActivityTransition();
    try {
      final xf = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1280,
        maxHeight: 1280,
        imageQuality: 85,
      );
      if (xf == null) return null;
      return await _processImage(xf);
    } catch (e, st) {
      _log.error('pickImageFromCamera failed', error: e, stack: st, tag: 'Att');
      return null;
    } finally {
      Future.delayed(const Duration(seconds: 2), () {
        BiometricService.endActivityTransition();
      });
    }
  }

  /// 选文档（txt/md/log/csv/pdf/docx/xlsx）
  Future<MessageAttachment?> pickDocument() async {
    BiometricService.beginActivityTransition();
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: pickableExtensions,
        withData: false,
      );
      if (result == null || result.files.isEmpty) return null;
      final pf = result.files.first;
      final path = pf.path;
      if (path == null) return null;
      final file = File(path);
      if (!await file.exists()) return null;
      final fileSize = await file.length();
      if (fileSize > maxRawFileBytes) {
        _log.warn('Document rejected: $path exceeds $maxRawFileBytes bytes',
            tag: 'Att');
        return _errorAttachment(
            pf.name, '附件超过 ${maxRawFileBytes ~/ (1024 * 1024)} MB 限制');
      }
      return await _processByExtension(file, pf.name);
    } catch (e, st) {
      _log.error('pickDocument failed', error: e, stack: st, tag: 'Att');
      return null;
    } finally {
      Future.delayed(const Duration(seconds: 2), () {
        BiometricService.endActivityTransition();
      });
    }
  }

  /// build123：把「外部 App 分享进来的文件」变成可发送的附件。
  ///
  /// 与 [pickDocument] 的差异只有入口——原生侧已把 `content://` 复制成本地文件，
  /// 这里复用**同一个** `_process*` 分派，保证「分享来的 pdf」与「选来的 pdf」
  /// 解析行为完全一致（同一语义两套实现正是本项目历史上反复出问题的地方）。
  ///
  /// 返回 null 表示不可用（不存在/扩展名不支持等）——调用方必须给用户
  /// 明确提示，**不能静默什么都不发生**。
  ///
  /// build129（#106）：[allowOversize] = 用户已在「体积过大」弹层里确认继续。
  /// 此前超 [maxRawFileBytes] 一律硬拒绝（只留一条错误附件，用户没法坚持），
  /// 现在改为**可确认继续**：UI 先量体积（[sizeOfFile]）→ 过大则问一次 →
  /// 用户确认后带 `allowOversize: true` 再来。默认 false，保持旧行为不变。
  /// 注意：这里放开的只是「原始体积」这一道闸；各格式解析器自带的
  /// 安全阀（pdf 页数/字节、docx/xlsx 条目与解压后体积等）**照旧生效**，
  /// 它们是防解压炸弹的，不属于「拒绝用户的大文件」。
  Future<MessageAttachment?> attachSharedFile(
    String path, {
    String? displayName,
    String? mimeType,
    bool allowOversize = false,
  }) async {
    try {
      final file = File(path);
      if (!await file.exists()) {
        _log.warn('Shared file missing: $path', tag: 'Att');
        return null;
      }
      final size = await file.length();
      if (size > maxRawFileBytes) {
        if (!allowOversize) {
          _log.warn('Shared file rejected (too large): $size bytes', tag: 'Att');
          return _errorAttachment(displayName ?? _basename(path),
              '附件超过 ${maxRawFileBytes ~/ (1024 * 1024)} MB 限制');
        }
        // 用户确认继续——记录在案（真出问题时要能回溯是谁放行的这批体积）
        _log.warn(
            'Shared file accepted oversize by user confirmation: $size bytes',
            tag: 'Att');
      }
      final name = displayName?.trim().isNotEmpty == true
          ? displayName!.trim()
          : _basename(path);
      // 扩展名优先取**文件名**（原生侧已按原名复制）；文件名没扩展名时
      // 才退回 mimeType 推断，否则「微信分享的 file」会因无扩展名被判不支持
      // 注意：不能用既有的 `_ext()`——它对无扩展名的字符串会返回整串
      // （`split('.').last`），会把「无扩展名」误判成「扩展名=整个文件名」。
      final nameExt = _extOf(name);
      final ext = nameExt.isNotEmpty ? nameExt : _extFromMime(mimeType);
      if (ext.isEmpty) {
        // build153：这里以前**直接 return null** ⇒ 文件名没后缀、mime 又不明
        // （`application/octet-stream`，微信/文件管理器常见）的分享一律进不来。
        // 现在交给分派表的内容嗅探那一支去判（判不过仍然拒，见 `_processByExtension`）。
        _log.info('分享文件无可用扩展名，改按内容判定：name=$name mime=$mimeType',
            tag: 'Att');
      }
      return await _processByExtension(file, name);
    } catch (e, st) {
      _log.error('attachSharedFile failed', error: e, stack: st, tag: 'Att');
      return null;
    }
  }

  /// 按路径抽取文档文本（不占附件配额、不写会话缓存）。
  ///
  /// build138（G61/G62）：ws_make_file 生成的 xlsx/docx/pdf 需要「用 App 里
  /// 真正的那套解析器读回来」才能证明是**真文件**而不是改了扩展名的文本 ——
  /// 单测走的就是这条入口，所以它必须是公开的、与 [attachSharedFile] 同源
  /// （同一套 `_process*`），不能是为了测试另写一份宽松解析。
  Future<MessageAttachment?> extractDocument(String path) async {
    final f = File(path);
    if (!await f.exists()) return null;
    // build154：**体积闸门口径对齐**。`pickDocument` / `attachSharedFile` /
    // `pickDocumentsForKnowledge` 三个入口都是「先量原始体积 → 过 maxRawFileBytes」，
    // 只有这条入口直接进解析器（`ws_read` 用的正是它）。工作区自带限额
    // （文本 1MB / 二进制 10MB）把它盖住了，但它是公开方法、参数是任意路径：
    // 换一个调用方就是整条链上唯一的漏口（老代码里它还会把整份大文件读进内存）。
    final size = await f.length();
    if (size > maxRawFileBytes) {
      _log.warn('extractDocument rejected: $path exceeds $maxRawFileBytes bytes',
          tag: 'Att');
      return _errorAttachment(_basename(path),
          '附件超过 ${maxRawFileBytes ~/ (1024 * 1024)} MB 限制');
    }
    return await _processByExtension(f, _basename(path));
  }

  /// 扩展名 → 解析器分派（[pickDocument]、[attachSharedFile]、[extractDocument]
  /// 与知识库多选**唯一共用**的出口）。判据只有一处：[attachmentKindFor]。
  Future<MessageAttachment?> _processByExtension(File file, String name) async {
    final ext = _extOf(name);
    // 先过拒绝表：这些后缀**不许**掉进下面的内容嗅探（见 [refusedExtensions]）
    if (refusedExtensions.contains(ext)) {
      _log.warn('Refused by design (无解析器，且内容像文本也不收): .$ext — $name',
          tag: 'Att');
      return null;
    }
    switch (attachmentKindFor(ext)) {
      case 'image':
        // 分享/选择来的图片走**同一个** [_processImage]（复制进 docs 目录、
        // 发 API 时现转 base64）：不为分享另写一套图片处理，否则
        // "相册选的 jpg 能用、微信分享的 jpg 不能用"这种分裂一定会再出现。
        return await _processImage(XFile(file.path,
            name: name, mimeType: imageExtensions[ext]));
      case 'csv':
        return await _processCsvFile(file, name);
      case 'pdf':
        return await _processPdf(file, name);
      case 'docx':
        return await _processDocx(file, name);
      case 'pptx':
        return await _processPptx(file, name);
      case 'xlsx':
        return await _processXlsx(file, name);
      case 'text':
        return await _processTextFile(file, name);
      default:
        // 表外的后缀**不等于不支持**：读头部字节按内容判一次
        // （见 [looksLikeUtf8Text]）。没有 NUL 且能严格按 UTF-8 解码 ⇒ 当文本收。
        // 判不过就照旧返回 null（含 NUL 的二进制、GBK 之类解码失败的不塞进 prompt）。
        if (await _headLooksTextual(file)) {
          _log.info('附件按内容判为文本（后缀 .$ext 不在表内）：$name', tag: 'Att');
          return await _processTextFile(file, name);
        }
        _log.warn('Unsupported file ext: $ext (且头部不像文本)', tag: 'Att');
        return null;
    }
  }

  /// 只读文件头 8 KB 做内容判定。刻意不用 `readAsBytes()`：
  /// 50 MB 的分享文件为了"是不是文本"整个读进内存是一次白白的大拷贝。
  Future<bool> _headLooksTextual(File file) async {
    final raf = await file.open();
    try {
      final n = await raf.length();
      final head = await raf.read(n < _sniffProbeBytes ? n : _sniffProbeBytes);
      return looksLikeUtf8Text(head, probeBytes: _sniffProbeBytes);
    } finally {
      await raf.close();
    }
  }

  static const int _sniffProbeBytes = 8192;

  // ───────────────────────────────────────────────────────────────────────────
  // build154（循环审计第 12 轮 · 文件读写一路）
  //
  // 1. **嗅探只看前 8KB，抽取却读整份文件** —— 这是 build153 那批改动的真实缺口：
  //    `_headLooksTextual` 用 `RandomAccessFile` 只读 8KB（注释还写着"不要
  //    readAsBytes() 白拷一遍"），可紧跟着的 `_processTextFile` / `_processCsvFile`
  //    是 `file.readAsString()`，把**整个文件**（`allowOversize` 之后连 50MB 这道闸
  //    都没有）一次性读进内存，`_truncate` 再拷一份 ⇒ 手机上几倍于文件体积的峰值。
  // 2. **"前 8KB 干净、后面是二进制"** 在旧实现里不是"收进 prompt 一段乱码"这么简单：
  //    `readAsString()` 默认 `allowMalformed: false`，尾部非法字节会抛 `FormatException`
  //    → 冒到 `attachSharedFile` 的 `catch` → **return null** ⇒ 用户看到的就是
  //    "分享文件没反应"，正是 build153 自己在这条链上反复消灭的那个形状（见
  //    [_processImage] 里"静默 = 不可排查"那段注释）。所以我的判断是：
  //    **这是缺陷，不是已知取舍**——真正的取舍只到"头部像文本就敢试"为止，
  //    全量读入和静默吞掉都不在取舍里。
  // 3. 上限读取后，"后面是二进制"最多只污染到 [_maxTextChars] 个字符（且解码失败
  //    就整条拒绝、给可见原因），内存峰值从 O(文件体积) 变成 O(上限)。
  // 4. 编码口径不变：**不猜编码、不转码**（GBK/Big5 解码失败就是失败，宁缺毋伪）。
  //
  // 一个 UTF-8 码点最多 4 字节，所以按 4×上限 读字节一定够截出上限个字符。
  static const int _textHeadReadBytes = 4 * (_maxTextChars + 8);

  /// 头部窗口内读文本（**绝不整文件读入**）。
  /// 返回 `(text, decoded, hasMore)`：`decoded=false` 表示截断点之前就已经不是合法
  /// UTF-8；`hasMore` 表示文件比读取窗口大（还有没读的部分，调用方要如实标注）。
  Future<({String text, bool decoded, bool hasMore})> _readTextHead(File file) async {
    final raf = await file.open();
    try {
      final len = await raf.length();
      final n = len < _textHeadReadBytes ? len : _textHeadReadBytes;
      final bytes = await raf.read(n);
      final cut = completeUtf8Prefix(bytes);
      try {
        final body = utf8.decode(bytes.sublist(0, cut), allowMalformed: false);
        // 去 UTF-8 BOM（与 CSV 同口径；文本附件带 BOM 时首字符会进 prompt）
        return (
          text: body.startsWith('\uFEFF') ? body.substring(1) : body,
          decoded: true,
          hasMore: len > n,
        );
      } on FormatException {
        return (text: '', decoded: false, hasMore: len > n);
      }
    } finally {
      await raf.close();
    }
  }

  /// 截断点回退到最后一个**完整** UTF-8 码点的边界（否则把一个汉字从中间切开，
  /// 合法文本也会被误判成"解码失败"）。纯函数，供单测直接喂字节。
  ///
  /// 判据：从末尾**最多回看 3 个**后继字节找到最后一个码点的首字节，再看它需要的
  /// 字节数够不够。**不能**一直回退到"所有后继字节"——一个汉字的第 2、3 字节都是
  /// 后继字节，那样会把窗口末尾每个完整的汉字都误当成残缺码点丢掉
  /// （第一版就是这么错的，测试里"5 个汉字被砍成空串"）。
  @visibleForTesting
  static int completeUtf8Prefix(List<int> bytes) {
    var i = bytes.length;
    var back = 0;
    while (i > 0 && back < 3 && (bytes[i - 1] & 0xC0) == 0x80) {
      i--;
      back++;
    }
    if (i == 0) return 0; // 整段都是后继字节：不是任何码点的合法开头
    final lead = bytes[i - 1];
    final need = lead < 0x80
        ? 1
        : (lead & 0xE0) == 0xC0
            ? 2
            : (lead & 0xF0) == 0xE0
                ? 3
                : (lead & 0xF8) == 0xF0
                    ? 4
                    : 1;
    // 首字节在 i-1，窗口里还剩 bytes.length-(i-1) 个字节可用
    return bytes.length - (i - 1) >= need ? bytes.length : i - 1;
  }

  static String _basename(String path) {
    final i = path.lastIndexOf(RegExp(r'[/\\]'));
    return i < 0 ? path : path.substring(i + 1);
  }

  /// 只取「文件名最后一个点之后」的扩展名；无点 / 点是首字符 / 点是末字符
  /// 一律返回空串（不能像 `split('.').last` 那样把整串当扩展名）。
  static String _extOf(String name) {
    final base = _basename(name);
    final i = base.lastIndexOf('.');
    if (i <= 0 || i == base.length - 1) return '';
    return base.substring(i + 1).toLowerCase();
  }

  /// mimeType → 扩展名（**只在文件名没扩展名时**兜底用，见 [attachSharedFile]）。
  /// 覆盖到分派表认识的各族；`application/octet-stream` 一律返回空串，
  /// 让后面的内容嗅探那一支去判（不是"判不出来就不接"）。
  @visibleForTesting
  static String extFromMimeForTest(String? mime) => _extFromMime(mime);

  static String _extFromMime(String? mime) {
    if (mime == null) return '';
    final m = mime.toLowerCase();
    if (m.contains('pdf')) return 'pdf';
    if (m.contains('csv')) return 'csv';
    // OOXML 与**老式 Office** 的 mime 必须分开映射（build154 第 12 轮 R2 确证后我改的）：
    // 原来 `excel→xlsx` / `msword→docx`，于是老 .doc/.xls 走"无扩展名"这条入口时
    // 被塞给 zip 解析器 ⇒ 抛异常 ⇒ `attachSharedFile` catch 成 null ⇒ 又是"分享没反应"。
    // 现在如实映射成各自的真实后缀，让 [refusedExtensions] 那一道把它们挡在**入口**，
    // 用户拿到的是"不支持"而不是一片安静。
    // 代价：极少数把 xlsx 报成 `vnd.ms-excel` 的提供方（历史上确有）会在"文件名无扩展名"时
    // 被明确拒绝 —— 有扩展名的正常情况不受影响，因为扩展名优先于 mime。
    if (m.contains('spreadsheetml')) return 'xlsx';
    if (m.contains('presentationml')) return 'pptx';
    if (m.contains('wordprocessingml')) return 'docx';
    if (m.contains('excel')) return 'xls';
    if (m.contains('powerpoint')) return 'ppt';
    if (m.contains('msword')) return 'doc';
    // 图片：以前这里**一个都没有** ⇒ 相册/相机 App 分享图片时如果只给 mime
    // 不给文件名后缀，就会被判"不支持"。按 [imageExtensions] 的值反查，
    // 保证两张表不会各说一套。
    for (final e in imageExtensions.entries) {
      if (m == e.value || m.contains('/${e.key}')) return e.key;
    }
    // 明确是文本/结构化数据的后缀（模型侧按原文读，无需专用解析器）
    if (m.startsWith('text/')) return 'txt';
    if (m.contains('json')) return 'json';
    if (m.contains('yaml')) return 'yaml';
    if (m.contains('xml') || m.contains('html')) return 'txt';
    return '';
  }

  /// build101（C1 知识库）：多选文档并抽取纯文本，返回 (文件名, 文本) 列表。
  ///
  /// 与 [pickDocument] 的差异：
  /// - 支持多选（一次导入多篇进知识库）
  /// - 只返回文本，不写会话附件缓存、不占附件配额
  /// - 抽取走同一套 `_process*`，保证 PDF/docx/xlsx/csv/txt 解析行为一致
  Future<List<({String name, String text})>> pickDocumentsForKnowledge()
      async {
    BiometricService.beginActivityTransition();
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: pickableExtensions,
        allowMultiple: true,
        withData: false,
      );
      if (result == null || result.files.isEmpty) return const [];
      final out = <({String name, String text})>[];
      for (final pf in result.files) {
        final path = pf.path;
        if (path == null) continue;
        final file = File(path);
        if (!await file.exists()) continue;
        final fileSize = await file.length();
        if (fileSize > maxRawFileBytes) {
          _log.warn('KB doc skipped (too large): $path', tag: 'Att');
          continue;
        }
        try {
          // build153：这里原来是**第三份**扩展名 switch（与 `_processByExtension`
          // 同一套判据抄了两遍）⇒ 加类型必然出现"分享能收、知识库导入不收"。
          // 改成调同一个分派出口，判据只留一处。
          // 名字空时退回 path（旧代码就是按 path 取的扩展名，行为不能缩）。
          final att = await _processByExtension(
              file, pf.name.isEmpty ? path : pf.name);
          if (att == null) continue;
          final text = att.extractedText ?? '';
          // build154：解析器把**拒绝原因**也塞在 extractedText 里（[_errorAttachment]）。
          // 不认这个前缀就会把「PDF 文件超过 30 MB 限制」当成文档正文**导入知识库并向量化入库**，
          // 之后检索命中它、模型把这句错误当资料回答 —— `ws_read` 那侧
          // （builtin_plugins）已经认了这个前缀，两个入口口径必须一致（教训 #62 同族）。
          if (text.trim().isNotEmpty && !text.startsWith(attachmentErrorPrefix)) {
            out.add((name: pf.name, text: text));
          }
        } catch (e, st) {
          _log.error('KB doc extract failed: $path',
              error: e, stack: st, tag: 'Att');
        }
      }
      return out;
    } catch (e, st) {
      _log.error('pickDocumentsForKnowledge failed',
          error: e, stack: st, tag: 'Att');
      return const [];
    } finally {
      Future.delayed(const Duration(seconds: 2), () {
        BiometricService.endActivityTransition();
      });
    }
  }

  /// 发 API 时把图片本地文件转成 base64（不含 data: 前缀，由调用方拼）
  Future<String?> imageToBase64(MessageAttachment att) async {
    if (att.type != AttachmentType.image || att.localPath == null) return null;
    try {
      final bytes = await File(att.localPath!).readAsBytes();
      return base64Encode(bytes);
    } catch (e) {
      _log.error('imageToBase64 failed: $e', tag: 'Att');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  Future<MessageAttachment?> _processImage(XFile xf) async {
    final imageSize = await File(xf.path).length();
    if (imageSize > maxRawFileBytes) {
      _log.warn('Image rejected: ${xf.path} exceeds $maxRawFileBytes bytes',
          tag: 'Att');
      // build153：这里原来是 `return null` ⇒ 分享一张 6000 万像素的大图进来"什么都没发生"
      // （静默 = 不可排查，本仓反复踩过的那一类）。改成与本文件其它超限分支同一个形状：
      // 给一条错误附件，用户看得见原因（`pickDocument` 早就是这个写法）。
      return _errorAttachment(
          xf.name.isEmpty ? _basename(xf.path) : xf.name,
          '图片超过 ${maxRawFileBytes ~/ (1024 * 1024)} MB 限制');
    }
    final mime = xf.mimeType ?? 'image/jpeg';
    // 扩展名优先取**名字**（分享来的是原名），名字没有扩展名才退回路径；
    // 旧代码只看 path，而 `_ext` 对无点字符串会把整串返回 ⇒ 复制出的附件名会变成
    // `att_xxx.一长串没意义的东西`。这里用 `_extOf`（无扩展名就返回空串）而不是 `_ext`。
    var ext = _extOf(xf.name).isNotEmpty ? _extOf(xf.name) : _extOf(xf.path);
    if (ext.isEmpty) {
      // 名字与路径都拿不到扩展名（部分分享只给 content:// 的编号名）：
      // 按 mime 给一个，再不行落 jpg —— 不留 `att_xxx.` 这种带尾点的文件名。
      ext = mime.endsWith('png')
          ? 'png'
          : mime.endsWith('webp')
              ? 'webp'
              : 'jpg';
    }
    ext = ext.toLowerCase();
    // 复制到 app docs 目录持久化（避免相册/缓存路径被系统清理后缩略图失效）
    final dir = await getApplicationDocumentsDirectory();
    final dest = '${dir.path}/att_${const Uuid().v4()}.$ext';
    await File(xf.path).copy(dest);
    // build138（静默降级扫描）：原来直接把 `Future<int>` 插进字符串，
    // 日志里永远是 `Instance of 'Future<int>' KB` —— 排查图片体积时这条日志全是废的。
    final kb = await _kbOf(dest);
    _log.info('Image attachment: $dest ($kb KB) mime=$mime', tag: 'Att');
    return MessageAttachment(
      id: const Uuid().v4(),
      type: AttachmentType.image,
      fileName: xf.name.isEmpty ? 'image.$ext' : xf.name,
      localPath: dest,
      mimeType: mime,
    );
  }

  Future<MessageAttachment> _processTextFile(File file, String name) async {
    // build154：以前这里 `await file.readAsString()` 整文件进内存（见 [_readTextHead] 上方注释）
    final head = await _readTextHead(file);
    if (!head.decoded) {
      _log.warn('Text attachment refused (非法 UTF-8): $name', tag: 'Att');
      return _errorAttachment(name,
          '文件在开头部分之后就不是合法 UTF-8 文本（可能是 GBK/Big5 编码，或文本后面内嵌了二进制），未加入对话');
    }
    final text = _capText(head.text, hasMore: head.hasMore);
    _log.info('Text attachment: $name chars=${text.length}', tag: 'Att');
    return MessageAttachment(
      id: const Uuid().v4(),
      type: AttachmentType.text,
      fileName: name,
      extractedText: text,
    );
  }

  /// 截断到 [_maxTextChars] 并**如实标注**（[hasMore]：文件比读取窗口还大时，
  /// 哪怕字符数没超限也要说明"后面没读"，否则模型会把手上的片段当成全文）。
  String _capText(String s, {bool hasMore = false}) {
    if (s.length > _maxTextChars) {
      return '${s.substring(0, _maxTextChars)}\n\n…[内容超过 $_maxTextChars 字符，已截断]';
    }
    if (hasMore) {
      return '$s\n\n…[文件超出读取窗口 $_textHeadReadBytes 字节，后面未读取]';
    }
    return s;
  }

  Future<MessageAttachment> _processPdf(File file, String name) async {
    final fileSize = await file.length();
    if (fileSize > _maxPdfBytes) {
      _log.warn('PDF rejected: $name exceeds $_maxPdfBytes bytes', tag: 'Att');
      return _errorAttachment(
          name, 'PDF 文件超过 ${_maxPdfBytes ~/ (1024 * 1024)} MB 限制');
    }
    String text = '';
    // v1.6.8 修复 Bug#8：PdfDocument 持有原生资源，仅在早退路径 dispose 不够，
    // 正常路径和 catch 路径都泄漏。改为 try/finally 保证一定释放。
    PdfDocument? doc;
    try {
      final bytes = await file.readAsBytes();
      doc = PdfDocument(inputBytes: bytes);
      final extractor = PdfTextExtractor(doc);
      final pageCount = doc.pages.count;
      if (pageCount > _maxPdfPages) {
        _log.warn('PDF rejected: $name has $pageCount pages', tag: 'Att');
        return _errorAttachment(name, 'PDF 页数超过 $_maxPdfPages 页限制');
      }
      final buf = StringBuffer();
      var failedPages = 0;
      for (int i = 0; i < doc.pages.count; i++) {
        try {
          buf.writeln(
              extractor.extractText(startPageIndex: i, endPageIndex: i));
        } catch (e) {
          // build138（静默降级扫描）：这里原本只 `debugPrint` —— release 包里
          // debugPrint 是空转，于是「跳过无法解析的页」等于悄悄少了几页，
          // 模型拿着半份 PDF 还会当成全文回答。现在留日志 + 在文本里显式声明缺页。
          failedPages++;
          _log.warn('PDF 第 ${i + 1} 页解析失败，已跳过：$e', tag: 'Att');
        }
        if (buf.length >= _maxTextChars) break;
      }
      text = failedPages == 0
          ? buf.toString()
          : '$buf\n\n[注意：该 PDF 有 $failedPages 页解析失败并被跳过，上面的文本不完整]';
    } catch (e, st) {
      _log.error('PDF extract failed: $e', error: e, stack: st, tag: 'Att');
      text = '[PDF 文本抽取失败: $e]';
    } finally {
      doc?.dispose();
    }
    final truncated = _truncate(text);
    _log.info('PDF attachment: $name chars=${text.length}', tag: 'Att');
    return MessageAttachment(
      id: const Uuid().v4(),
      type: AttachmentType.doc,
      fileName: name,
      extractedText: truncated,
    );
  }

  Future<MessageAttachment> _processDocx(File file, String name) async {
    final fileSize = await file.length();
    if (fileSize > _maxDocxBytes) {
      _log.warn('DOCX rejected: $name exceeds $_maxDocxBytes bytes',
          tag: 'Att');
      return _errorAttachment(
          name, 'DOCX 压缩包超过 ${_maxDocxBytes ~/ (1024 * 1024)} MB 限制');
    }
    String text = '';
    try {
      final bytes = await file.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      if (archive.files.length > _maxDocxEntries) {
        return _errorAttachment(name, 'DOCX 压缩包条目超过 $_maxDocxEntries 个限制');
      }
      final uncompressedBytes = archive.files.fold<int>(
        0,
        (total, entry) => total + entry.size,
      );
      if (uncompressedBytes > _maxDocxUncompressedBytes) {
        return _errorAttachment(name,
            'DOCX 解压后大小超过 ${_maxDocxUncompressedBytes ~/ (1024 * 1024)} MB 限制');
      }
      final docEntry = archive.findFile('word/document.xml');
      if (docEntry == null) {
        text = '[docx 内未找到 word/document.xml]';
      } else {
        text = docxPlainText(utf8.decode(docEntry.content as List<int>));
      }
    } catch (e, st) {
      _log.error('docx extract failed: $e', error: e, stack: st, tag: 'Att');
      text = '[docx 文本抽取失败: $e]';
    }
    final truncated = _truncate(text);
    _log.info('docx attachment: $name chars=${text.length}', tag: 'Att');
    return MessageAttachment(
      id: const Uuid().v4(),
      type: AttachmentType.doc,
      fileName: name,
      extractedText: truncated,
    );
  }

  /// build138（G62）：word/document.xml → 纯文本（表格保结构）。
  ///
  /// 旧实现是「`</w:p>`→换行 + 正则剥标签」一刀切，对**表格**是坏的：
  /// 一个单元格一段，于是「姓名 / 语文 / 数学」变成三行、还会带空行，
  /// 模型读到的表格没有行、也没有列。现在按 `<w:tbl>` 分段处理：
  /// 表外保持「段落 = 一行」，表内保持「行 = 一行、单元格用 ` | ` 分隔」，
  /// 与工作区 xlsx 的输出口径一致（两个格式在模型侧同构，少一类误读）。
  @visibleForTesting
  static String docxPlainText(String documentXml) {
    String strip(String s) => _decodeXmlEntities(
        s.replaceAll(RegExp(r'<[^>]*>'), '').trim());

    final body = StringBuffer();
    final tblRe = RegExp(r'<w:tbl\b.*?</w:tbl>', dotAll: true);
    var last = 0;
    for (final m in tblRe.allMatches(documentXml)) {
      final pre = documentXml.substring(last, m.start);
      if (pre.isNotEmpty) body.writeln(_docxParagraphs(pre, strip));
      for (final row in RegExp(r'<w:tr\b.*?</w:tr>', dotAll: true)
          .allMatches(m.group(0)!)) {
        final cells = <String>[];
        for (final tc in RegExp(r'<w:tc\b.*?</w:tc>', dotAll: true)
            .allMatches(row.group(0)!)) {
          // 单元格内可能有多个段落：压成一行，内部用空格连接。
          cells.add(strip(tc.group(0)!.replaceAll(RegExp(r'</w:p>'), ' ')));
        }
        if (cells.isNotEmpty) body.writeln(cells.join(' | '));
      }
      last = m.end;
    }
    body.write(_docxParagraphs(documentXml.substring(last), strip));
    return body.toString().replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  static String _docxParagraphs(String xml, String Function(String) strip) {
    final buf = StringBuffer();
    for (final p in xml.split(RegExp(r'</w:p>'))) {
      final t = strip(p);
      if (t.isNotEmpty) buf.writeln(t);
    }
    return buf.toString();
  }

  /// build101（C4 pptx 解析）：PPTX 是 OOXML 压缩包，每页幻灯片一个
  /// `ppt/slides/slideN.xml`，文本在 `<a:t>` 里、段落边界是 `</a:p>`。
  ///
  /// 按 slide 编号排序输出并标注页码——PPT 的「第 N 页」对用户和模型都是
  /// 有效定位信息，比 docx 的连续文本更有价值。
  Future<MessageAttachment> _processPptx(File file, String name) async {
    final fileSize = await file.length();
    if (fileSize > _maxDocxBytes) {
      _log.warn('PPTX rejected: $name exceeds $_maxDocxBytes bytes',
          tag: 'Att');
      return _errorAttachment(
          name, 'PPTX 压缩包超过 ${_maxDocxBytes ~/ (1024 * 1024)} MB 限制');
    }
    String text = '';
    try {
      final bytes = await file.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      // 复用 docx 的条目/解压体积上限（同为 OOXML，风险特征一致）
      if (archive.files.length > _maxDocxEntries) {
        return _errorAttachment(
            name, 'PPTX 压缩包条目超过 $_maxDocxEntries 个限制');
      }
      final uncompressedBytes = archive.files.fold<int>(
        0,
        (total, entry) => total + entry.size,
      );
      if (uncompressedBytes > _maxDocxUncompressedBytes) {
        return _errorAttachment(name,
            'PPTX 解压后大小超过 ${_maxDocxUncompressedBytes ~/ (1024 * 1024)} MB 限制');
      }

      // slideN.xml 需按数字排序（字符串排序会把 slide10 排到 slide2 前）
      final slideEntries = archive.files
          .where((f) =>
              RegExp(r'^ppt/slides/slide\d+\.xml$').hasMatch(f.name))
          .toList()
        ..sort((a, b) {
          int numOf(String n) =>
              int.tryParse(RegExp(r'slide(\d+)\.xml').firstMatch(n)?.group(1) ??
                  '0') ??
              0;
          return numOf(a.name).compareTo(numOf(b.name));
        });

      if (slideEntries.isEmpty) {
        text = '[pptx 内未找到 ppt/slides/slide*.xml]';
      } else {
        final buf = StringBuffer();
        for (var i = 0; i < slideEntries.length; i++) {
          final entry = slideEntries[i];
          final xml = utf8.decode(entry.content as List<int>,
              allowMalformed: true);
          // 段落结束 → 换行；<a:br/> → 换行；其余标签剥掉
          var slideText = xml
              .replaceAll(RegExp(r'</a:p>'), '\n')
              .replaceAll(RegExp(r'<a:br\s*/>'), '\n')
              .replaceAll(RegExp(r'<[^>]+>'), '')
              .replaceAll(RegExp(r'[ \t]+'), ' ')
              .replaceAll(RegExp(r'\n{2,}'), '\n')
              .trim();
          slideText = _unescapeXml(slideText);
          if (slideText.isEmpty) continue;
          buf.writeln('【第 ${i + 1} 页】');
          buf.writeln(slideText);
          buf.writeln();
        }
        // 备注页（演讲者备注）也常含关键信息
        final notesEntries = archive.files.where((f) =>
            RegExp(r'^ppt/notesSlides/notesSlide\d+\.xml$')
                .hasMatch(f.name));
        final notesBuf = StringBuffer();
        for (final entry in notesEntries) {
          final xml = utf8.decode(entry.content as List<int>,
              allowMalformed: true);
          final t = _unescapeXml(xml
              .replaceAll(RegExp(r'</a:p>'), '\n')
              .replaceAll(RegExp(r'<[^>]+>'), '')
              .trim());
          if (t.isNotEmpty && !RegExp(r'^\d+$').hasMatch(t)) {
            notesBuf.writeln(t);
          }
        }
        if (notesBuf.isNotEmpty) {
          buf.writeln('【演讲者备注】');
          buf.writeln(notesBuf.toString().trim());
        }
        text = buf.toString().trim();
      }
    } catch (e, st) {
      _log.error('pptx extract failed: $e', error: e, stack: st, tag: 'Att');
      text = '[pptx 文本抽取失败: $e]';
    }
    final truncated = _truncate(text);
    _log.info('pptx attachment: $name chars=${text.length}', tag: 'Att');
    return MessageAttachment(
      id: const Uuid().v4(),
      type: AttachmentType.doc,
      fileName: name,
      extractedText: truncated,
    );
  }

  /// build101（C4）：XML 实体反转义（pptx/docx 共用）
  String _unescapeXml(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'");

  /// v1.7.33：CSV → 按 RFC4180 风格解析（支持双引号包裹 + 逗号/分号/制表符分隔 + BOM），
  /// 输出为「表头 + 每行管道分隔」的纯文本，避免塞给模型时列错位。
  Future<MessageAttachment> _processCsvFile(File file, String name) async {
    final fileSize = await file.length();
    if (fileSize > maxRawFileBytes) {
      _log.warn('CSV rejected: $name exceeds $maxRawFileBytes bytes',
          tag: 'Att');
      return _errorAttachment(
          name, 'CSV 文件超过 ${maxRawFileBytes ~/ (1024 * 1024)} MB 限制');
    }
    String text;
    // build154：与文本附件同一个**上限读取**（旧实现 `readAsString()` 把整份
    // 50MB CSV 读进内存，再 `_parseCsv` 拆成 List<List<String>>、再 join 一份
    // ⇒ 约三倍峰值）。BOM 由 [_readTextHead] 统一剥掉，与文本附件同口径。
    final head = await _readTextHead(file);
    if (!head.decoded) {
      _log.warn('CSV refused (非法 UTF-8): $name', tag: 'Att');
      return _errorAttachment(name,
          'CSV 不是合法 UTF-8 文本（Excel 里请另存为「CSV UTF-8」），未加入对话');
    }
    try {
      final raw = head.text;
      // 去 UTF-8 BOM（Excel 导出的 CSV 常见），否则第一列表头会带隐形字符
      text = raw.startsWith('\uFEFF') ? raw.substring(1) : raw;
      final rows = _parseCsv(text);
      if (rows.isEmpty) {
        text = '[CSV 内没有可解析的数据行]';
      } else {
        final lines = <String>[];
        lines.add('CSV 共 ${rows.length} 行（第一行为表头，若存在）'
            '${head.hasMore ? '；注意：文件超出读取窗口，后面未读取' : ''}');
        for (final row in rows) {
          final cells =
              row.map((c) => c.replaceAll(RegExp(r'[\r\n\t]+'), ' ')).toList();
          lines.add(cells.join(' | '));
        }
        text = lines.join('\n');
      }
      _log.info('CSV attachment: $name chars=${text.length}', tag: 'Att');
    } catch (e, st) {
      _log.error('CSV parse failed: $e', error: e, stack: st, tag: 'Att');
      text = '[CSV 解析失败: $e]';
    }
    return MessageAttachment(
      id: const Uuid().v4(),
      type: AttachmentType.text,
      fileName: name,
      extractedText: _capText(text),
    );
  }

  /// 公开桥接：CSV 解析（供单测直接验证，逻辑与 _processCsvFile 同源）
  static List<List<String>> parseCsv(String text) => _parseCsv(text);

  /// 公开桥接：XML 实体解码（供单测验证）
  static String decodeXmlEntities(String s) => _decodeXmlEntities(s);

  /// 极简 RFC4180 解析器：双引号包裹字段可含分隔符与换行，"" 转义为 "。
  /// 分隔符按首行出现频率自动判定（, > ; > \t）。
  /// 兼容 UTF-8 BOM、\r\n / \r / \n 三种换行。
  static List<List<String>> _parseCsv(String text) {
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    if (text.trim().isEmpty) return const [];
    final firstLine = text.split(RegExp(r'[\r\n]+')).first;
    final counts = <String, int>{',': 0, ';': 0, '\t': 0};
    for (final d in counts.keys) {
      var idx = firstLine.indexOf(d);
      while (idx != -1) {
        counts[d] = counts[d]! + 1;
        idx = firstLine.indexOf(d, idx + 1);
      }
    }
    final sep =
        counts.entries.reduce((a, b) => (a.value >= b.value ? a : b)).key;

    final rows = <List<String>>[];
    final row = <String>[];
    final cell = StringBuffer();
    var inQuotes = false;
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (inQuotes) {
        if (ch == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            cell.write('"');
            i++;
          } else {
            inQuotes = false;
          }
        } else if (ch == '\r' && i + 1 < text.length && text[i + 1] == '\n') {
          cell.write('\n');
          i++;
        } else {
          cell.write(ch);
        }
      } else if (ch == '"' && cell.isEmpty) {
        inQuotes = true;
      } else if (ch == sep) {
        row.add(cell.toString());
        cell.clear();
      } else if (ch == '\n' ||
          (ch == '\r' && (i + 1 >= text.length || text[i + 1] != '\n'))) {
        row.add(cell.toString());
        cell.clear();
        rows.add(row.toList());
        row.clear();
      } else if (ch == '\r') {
        // CRLF 中的 \r：跳过，换行由 \n 统一处理
      } else {
        cell.write(ch);
      }
    }
    if (cell.isNotEmpty || row.isNotEmpty) {
      row.add(cell.toString());
      rows.add(row.toList());
    }
    return rows;
  }

  /// v1.7.33：XLSX（xlsx = zip 内的 OOXML 工作簿）→ 抽出各 sheet 的单元格文本，
  /// 输出为「# Sheet 名 + 行管道分隔」的纯文本。用现有 archive 依赖，不新增依赖。
  Future<MessageAttachment> _processXlsx(File file, String name) async {
    final fileSize = await file.length();
    if (fileSize > _maxXlsxBytes) {
      _log.warn('XLSX rejected: $name exceeds $_maxXlsxBytes bytes',
          tag: 'Att');
      return _errorAttachment(
          name, 'XLSX 文件超过 ${_maxXlsxBytes ~/ (1024 * 1024)} MB 限制');
    }
    String text;
    try {
      final bytes = await file.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      if (archive.files.length > _maxXlsxEntries) {
        return _errorAttachment(name, 'XLSX 压缩包条目超过 $_maxXlsxEntries 个限制');
      }
      final uncompressedBytes = archive.files.fold<int>(
        0,
        (total, entry) => total + entry.size,
      );
      if (uncompressedBytes > _maxXlsxUncompressedBytes) {
        return _errorAttachment(name,
            'XLSX 解压后大小超过 ${_maxXlsxUncompressedBytes ~/ (1024 * 1024)} MB 限制');
      }

      final buf = StringBuffer();
      var cells = 0;

      // sharedStrings：共享字符串表（xlsx 里字符串默认存索引）
      final sharedStrings = <String>[];
      final ssEntry = archive.findFile('xl/sharedStrings.xml');
      if (ssEntry != null) {
        final ssXml = utf8.decode(ssEntry.content as List<int>);
        // <si><t>text</t></si> 或 <si><r><t>..</t></r>...
        final siRe = RegExp(r'<si>(.*?)</si>', dotAll: true);
        final tRe = RegExp(r'<t[^>]*>(.*?)</t>', dotAll: true);
        for (final m in siRe.allMatches(ssXml)) {
          final inner = m.group(1) ?? '';
          sharedStrings.add(_decodeXmlText(
              tRe.allMatches(inner).map((t) => t.group(1) ?? '').join()));
        }
      }

      // 按 workbook.xml 的 sheet 顺序找 sheet1.xml/sheet2.xml…
      final wbEntry = archive.findFile('xl/workbook.xml');
      final sheetOrder = <String>[];
      if (wbEntry != null) {
        final wbXml = utf8.decode(wbEntry.content as List<int>);
        final nameRe = RegExp(r'<sheet[^>]*name="([^"]*)"');
        for (final m in nameRe.allMatches(wbXml)) {
          sheetOrder.add(_decodeXmlEntities(m.group(1) ?? ''));
        }
      }
      for (var i = 1; i <= sheetOrder.length; i++) {
        final entry = archive.findFile('xl/worksheets/sheet$i.xml');
        if (entry == null) continue;
        final xml = utf8.decode(entry.content as List<int>);
        final sheetName =
            sheetOrder[i - 1].isEmpty ? 'Sheet$i' : sheetOrder[i - 1];
        buf.writeln('# $sheetName');

        final rowRe =
            RegExp(r'<row[^>]*r="(\d+)"[^>]*>(.*?)</row>', dotAll: true);
        final cellRe =
            RegExp(r'<c\b([^>]*)>(.*?)</c>|<c\b([^>]*)\s*/>', dotAll: true);
        var rowCount = 0;
        for (final rm in rowRe.allMatches(xml)) {
          if (rowCount++ >= 500) {
            buf.writeln('…[该表超过 500 行，已截断]');
            break;
          }
          final cellsInRow = <String>[];
          for (final cm in cellRe.allMatches(rm.group(2) ?? '')) {
            final attrs = cm.group(1) ?? cm.group(3) ?? '';
            final inner = cm.group(2) ?? '';
            final typeM = RegExp(r't="([^"]*)"').firstMatch(attrs);
            final type = typeM?.group(1);
            final vMatch =
                RegExp(r'<v[^>]*>(.*?)</v>', dotAll: true).firstMatch(inner);
            var value = '';
            if (type == 'inlineStr') {
              value = _decodeXmlText(RegExp(r'<t[^>]*>(.*?)</t>', dotAll: true)
                  .allMatches(inner)
                  .map((t) => t.group(1) ?? '')
                  .join());
            } else if (type == 's') {
              final idx = int.tryParse((vMatch?.group(1) ?? '').trim()) ?? -1;
              if (idx >= 0 && idx < sharedStrings.length) {
                value = sharedStrings[idx];
              }
            } else if (vMatch != null) {
              value = _decodeXmlText(vMatch.group(1) ?? '');
            }
            cellsInRow.add(value);
            if (++cells >= _maxXlsxCells) break;
          }
          buf.writeln(cellsInRow.join(' | '));
          if (cells >= _maxXlsxCells) {
            buf.writeln('…[单元格总数超过 $_maxXlsxCells，已截断]');
            break;
          }
        }
        buf.writeln();
        if (cells >= _maxXlsxCells) break;
      }
      text = buf.toString().trim();
      if (text.isEmpty) text = '[XLSX 内未找到可解析的工作表]';
      _log.info('xlsx attachment: $name cells=$cells', tag: 'Att');
    } catch (e, st) {
      _log.error('xlsx extract failed: $e', error: e, stack: st, tag: 'Att');
      text = '[xlsx 解析失败: $e]';
    }
    return MessageAttachment(
      id: const Uuid().v4(),
      type: AttachmentType.doc,
      fileName: name,
      extractedText: _truncate(text),
    );
  }

  /// 处理 XML 字符实体（仅做数值实体，字母实体的 5 个标准项已在 docx 分支处理）
  static String _decodeXmlText(String s) =>
      _decodeXmlEntities(RegExp(r'&#x([0-9a-fA-F]+);').allMatches(s).isEmpty
          ? s
          : s.replaceFirstMapped(RegExp(r'&#x([0-9a-fA-F]+);'),
              (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16))));

  static String _decodeXmlEntities(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'");

  /// 解析失败/主动拒绝时 `extractedText` 的固定前缀。
  /// 下游（知识库导入、`ws_read`）靠它区分「这是错误说明」与「这是文档正文」，
  /// 所以它是**跨文件契约**，改字面量必须同时改调用方。
  static const String attachmentErrorPrefix = '[附件无法处理';

  MessageAttachment _errorAttachment(String name, String message) {
    return MessageAttachment(
      id: const Uuid().v4(),
      type: AttachmentType.doc,
      fileName: name,
      extractedText: '$attachmentErrorPrefix: $message]',
    );
  }

  /// build129（#106）：只量体积、不解析、无副作用——供 UI 在调用前判断
  /// 「是否需要先问一句」。读不到（不存在 / 无权限）返回 null，
  /// 交给后续流程按既有方式出声报错，不在这里吞掉。
  Future<int?> sizeOfFile(String path) async {
    try {
      final f = File(path);
      if (!await f.exists()) return null;
      return await f.length();
    } catch (_) {
      return null;
    }
  }

  String _truncate(String s) {
    if (s.length <= _maxTextChars) return s;
    return '${s.substring(0, _maxTextChars)}\n\n…[内容超过 $_maxTextChars 字符，已截断]';
  }

  // `_ext(path) = path.split('.').last` 这个形状**不许再回来**：它对没有点的字符串
  // 会把整串当扩展名返回（分享来的 `content://…/12345` 会变成 `att_xxx.12345`）。
  // 一律用 [_extOf]（无扩展名返回空串）。build153 把最后两处 `_ext` 调用换掉后它就没引用了，
  // 留着只会诱使下一个人复用 —— 所以删掉，判据写在这行注释里。

  Future<int> _kbOf(String path) async {
    try {
      final s = await File(path).length();
      return (s / 1024).round();
    } catch (_) {
      return 0;
    }
  }
}
