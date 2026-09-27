import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/api_config.dart';
import '../utils/download_url_guard.dart';
// build129：只借它的 parseSuggestedModels 纯函数（400 正文里的「上游建议模型名」），
// 两边不是互调关系，也不构成循环依赖（image_gen_service 不 import 本文件）。
import 'image_gen_service.dart';
import 'logger_service.dart';

// ============================================================================
// 视频生成服务层（文生视频 / 图生视频，OpenAI 兼容的异步任务制）
//
// 为什么是「任务制」而非「请求-响应」：
//   视频生成官方口径耗时 1~5 分钟，且结果 URL 仅保留 24 小时、按秒计费。
//   因此接口被业界收敛成「先提交拿任务 id → 轮询状态 → 完成后取下载链接」的两段式，
//   与文生图的同步返回不同。本服务层只负责这两段 + 把成品尽快落盘（赶在 24h 过期前）。
//
// 为什么所有「同名不同形」都收敛成单一归一函数：
//   项目历史上被「同一语义多处各写一份」坑过——不同中转站把状态/结果放在不同字段
//   （task_result.videos[0].url、data[0].url、video_url、output.video_url …）。
//   所以状态与 URL 各只写一个纯函数（parseState / parseResultUrl），全项目共用，避免方言扩散。
//
// 为什么结果 URL 提取「取不到就返回 null 而不抛」：
//   视频是异步的，轮询早期（queued/processing）本来就没有成品 URL。
//   拿到 null 就该交给上层按 state 处理，而不是当异常——否则轮询会被误判为失败。
// ============================================================================

/// 任务状态（归一后的枚举）。
///
/// 把各中转站的方言状态统一成这 5 个：轮询 UI / DB 任务表 / ReAct 工具都只认这个。
enum VideoTaskState { queued, processing, completed, failed, unknown }

/// 视频生成失败的结构化异常。
///
/// [message] 面向用户的中文提示；[detail] 为原始响应片段/异常串（已截断），只用于排查、不展示给用户。
class VideoGenException implements Exception {
  final String message;
  final String? detail;

  const VideoGenException({required this.message, this.detail});

  @override
  String toString() =>
      detail != null ? 'VideoGenException: $message\n  detail: $detail' : 'VideoGenException: $message';
}

/// 某一次查询的「任务快照」，是上层唯一需要理解的数据结构。
class VideoTaskSnapshot {
  final String id;
  final VideoTaskState state;
  final String? resultUrl; // completed 时才有
  final String? errorMessage; // failed 时才有
  final int? progressPercent; // 上游给了才带

  const VideoTaskSnapshot({
    required this.id,
    required this.state,
    this.resultUrl,
    this.errorMessage,
    this.progressPercent,
  });
}

class VideoGenService {
  // 超时按官方耗时分布给：
  //   submit 建任务网络往返快，但中转可能慢，给 60s；
  //   query 单次轮询，给 30s；
  //   download 视频可达数十 MB，用流式 + 总超时 180s，避免大文件占内存又不被误杀。
  static const Duration _submitTimeout = Duration(seconds: 60);
  static const Duration _queryTimeout = Duration(seconds: 30);
  static const Duration _downloadTimeout = Duration(seconds: 180);

  static const String _tag = 'VideoGen';

  /// 创建视频生成任务（文生视频；[inputImageBase64] 非空则为图生视频）。
  ///
  /// 返回的是「刚入队」的快照（state 通常 queued，resultUrl 为 null）。
  /// 任何失败都抛 [VideoGenException]，不会静默返回。
  static Future<VideoTaskSnapshot> submit(
    ApiConfig config, {
    required String prompt,
    int seconds = 5,
    String size = '1280x720',
    String mode = 'std',
    String? inputImageBase64,
    String? modelOverride,
  }) async {
    // build129：取「文生视频专用模型」——此前这里写的是 config.model（对话模型），
    // 是 build125 只修图片那半留下的缺口：真机日志 nexus_export_2026-09-19T10-05
    // 实锤 POST /v1/videos 带 grok-4.6 稳定 400（上游原文点名 Use grok-imagine-video）。
    final model = (modelOverride ?? config.effectiveVideoModel).trim();
    if (model.isEmpty) {
      throw const VideoGenException(
        message: '未指定视频生成模型，请到「API 配置 → 文生视频模型」填一个支持视频生成的'
            '模型名（如 grok-imagine-video / kling-video-o1 / sora-2），再重试。',
      );
    }
    if (prompt.trim().isEmpty) {
      throw const VideoGenException(message: '提示词（prompt）不能为空。');
    }

    // 构造请求体：input_reference 仅在图生视频时带上（Base64 或 URL）。
    final body = <String, dynamic>{
      'model': model,
      'prompt': prompt,
      'seconds': seconds,
      'size': size,
      'mode': mode,
    };
    if (inputImageBase64 != null && inputImageBase64.trim().isNotEmpty) {
      body['input_reference'] = inputImageBase64.trim();
    }

    final headers = {'Content-Type': 'application/json'};
    // 本地/无鉴权端点 apiKey 为空时不发 Authorization（照项目既有习惯）。
    if (config.apiKey.isNotEmpty) {
      headers['Authorization'] = 'Bearer ${config.apiKey}';
    }

    final uri = Uri.parse(config.videosEndpoint);
    // 日志脱敏：只记 host+path，绝不带 apiKey 或任何 query 里的 token。
    final safeEp = '${uri.scheme}://${uri.host}${uri.path}';
    LoggerService.instance.info(
      'POST 创建视频任务 -> $safeEp | model=$model seconds=$seconds size=$size mode=$mode'
      '${inputImageBase64 != null ? ' | 图生视频:是' : ''}',
      tag: _tag,
    );

    late final http.Response resp;
    try {
      resp = await http
          .post(uri, headers: headers, body: jsonEncode(body))
          .timeout(_submitTimeout);
    } on TimeoutException {
      throw VideoGenException(
        message: '创建视频任务超时（>${_submitTimeout.inSeconds}s），请检查网络或中转服务。',
      );
    }

    LoggerService.instance.info('创建视频任务 HTTP 状态: ${resp.statusCode}', tag: _tag);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw _statusException(resp.statusCode, resp.body, model: model);
    }

    try {
      return _snapshotFromBody(resp.body, null);
    } on VideoGenException {
      rethrow;
    } catch (e) {
      throw VideoGenException(
        message: '响应解析失败：返回内容不是合法的 JSON。',
        detail: _truncate(e.toString()),
      );
    }
  }

  /// 查询任务状态 / 进度 / 成品链接。
  ///
  /// 轮询时反复调用本方法；completed 时快照里带 [VideoTaskSnapshot.resultUrl]。
  static Future<VideoTaskSnapshot> query(ApiConfig config, String taskId) async {
    if (taskId.trim().isEmpty) {
      throw const VideoGenException(message: '查询任务失败：taskId 不能为空。');
    }

    final headers = <String, String>{};
    if (config.apiKey.isNotEmpty) {
      headers['Authorization'] = 'Bearer ${config.apiKey}';
    }

    final url = config.videoStatusEndpoint(taskId);
    final safeUrl = Uri.parse(url);
    LoggerService.instance.info(
      'GET 查询视频任务 -> ${safeUrl.scheme}://${safeUrl.host}${safeUrl.path} | id=$taskId',
      tag: _tag,
    );

    late final http.Response resp;
    try {
      resp = await http
          .get(Uri.parse(url), headers: headers)
          .timeout(_queryTimeout);
    } on TimeoutException {
      throw VideoGenException(
        message: '查询视频任务超时（>${_queryTimeout.inSeconds}s），稍后重试即可。',
      );
    }

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw _statusException(resp.statusCode, resp.body);
    }

    late final VideoTaskSnapshot snap;
    try {
      snap = _snapshotFromBody(resp.body, taskId);
    } on VideoGenException {
      rethrow;
    } catch (e) {
      throw VideoGenException(
        message: '响应解析失败：返回内容不是合法的 JSON。',
        detail: _truncate(e.toString()),
      );
    }

    // 状态流转可观测：每次轮询都把当前状态打出来，便于还原任务生命周期。
    LoggerService.instance.info(
      '视频任务状态 id=$taskId state=${snap.state.name}'
      '${snap.progressPercent != null ? ' progress=${snap.progressPercent}%' : ''}',
      tag: _tag,
    );
    if (snap.state == VideoTaskState.failed) {
      LoggerService.instance.error(
        '视频任务失败 id=$taskId | ${snap.errorMessage ?? '未知原因'}',
        tag: _tag,
      );
    }
    return snap;
  }

  /// 把成品视频下载到本地并落盘。
  ///
  /// 为什么必须尽快落盘：结果 URL 仅保留 24 小时且按秒计费，不在手里的链接随时会失效。
  /// 为什么用流式 + 原子写：视频可达数十 MB，一次性读进内存有 OOM 风险；
  /// 先写同目录临时文件再 rename，避免写到一半被杀留下半截文件。
  static Future<File> download(String url, {required String taskId}) async {
    if (url.trim().isEmpty) {
      throw const VideoGenException(message: '下载失败：视频 URL 为空。');
    }
    // build133（③）：scheme 白名单（纵深防御）。正常 http/https 路径不受影响；
    // file:// 等非常规 scheme 直接拒绝，避免下游 client 行为不可预期。
    if (!isSafeDownloadUrl(url)) {
      throw const VideoGenException(
          message: '下载失败：URL 不是 http/https，已拒绝。');
    }

    // 日志脱敏：去掉 query（token 常藏在 ? 后面），只留路径。
    final safeLog = url.split('?').first;
    LoggerService.instance.info('下载视频 -> $safeLog | id=$taskId', tag: _tag);

    final dir = await _ensureDir();
    final target = File('${dir.path}${Platform.pathSeparator}vid_${_sanitizeTaskId(taskId)}.mp4');
    final tmp = File('${target.path}.tmp_${DateTime.now().microsecondsSinceEpoch}');

    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(url));
      final resp = await client.send(request).timeout(_downloadTimeout);
      if (resp.statusCode != 200) {
        throw VideoGenException(
          message: '视频下载失败（HTTP ${resp.statusCode}），URL 可能已过期或失效。',
          detail: 'HTTP ${resp.statusCode}',
        );
      }

      // 流式写盘：response.stream.pipe 直接把字节泵进文件，内存只过一小段缓冲。
      final sink = tmp.openWrite();
      try {
        await resp.stream.pipe(sink);
      } finally {
        await sink.flush();
        await sink.close();
      }

      final bytes = await tmp.length();
      if (await target.exists()) await target.delete();
      final out = await tmp.rename(target.path);

      LoggerService.instance.info(
        '视频落盘成功: ${out.path} ($bytes bytes)',
        tag: _tag,
      );
      return out;
    } on VideoGenException {
      // 清理半成品临时文件，避免留下 .tmp_ 垃圾。
      if (await tmp.exists()) await tmp.delete();
      rethrow;
    } on TimeoutException {
      if (await tmp.exists()) await tmp.delete();
      throw VideoGenException(
        message: '视频下载超时（>${_downloadTimeout.inSeconds}s），链接可能较慢或已失效。',
      );
    } catch (e) {
      if (await tmp.exists()) await tmp.delete();
      throw VideoGenException(
        message: '视频下载失败：网络或存储异常。',
        detail: _truncate(e.toString()),
      );
    } finally {
      client.close();
    }
  }

  /// 纯函数：状态字符串 → 枚举（多方言容错，可单测）。
  ///
  /// 容错规则：先 trim + 转小写，再把下划线/连字符/空白统一抹掉（所以
  /// queued / QUEUED / in_queue / in-queue / in queue 都归到同一形态），
  /// 仍匹配不上（含 null/空串）→ [VideoTaskState.unknown]。
  static VideoTaskState parseState(String? raw) {
    if (raw == null) return VideoTaskState.unknown;
    final s = raw
        .toString()
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[\s_\-]+'), '');
    if (s.isEmpty) return VideoTaskState.unknown;

    // queued 组
    if (s == 'queued' ||
        s == 'pending' ||
        s == 'submitted' ||
        s == 'created' ||
        s == 'inqueue') {
      return VideoTaskState.queued;
    }
    // processing 组（in_progress → inprogress）
    if (s == 'processing' ||
        s == 'running' ||
        s == 'inprogress' ||
        s == 'generating') {
      return VideoTaskState.processing;
    }
    // completed 组
    if (s == 'completed' ||
        s == 'succeeded' ||
        s == 'success' ||
        s == 'done') {
      return VideoTaskState.completed;
    }
    // failed 组（cancelled / canceled 两种拼写都收）
    if (s == 'failed' ||
        s == 'error' ||
        s == 'cancelled' ||
        s == 'canceled') {
      return VideoTaskState.failed;
    }
    return VideoTaskState.unknown;
  }

  /// 纯函数：从查询响应体提取成品视频 URL（多方言容错，可单测）。
  ///
  /// 覆盖各中转站把链接放在不同位置的方言；取不到返回 null 而不抛——
  /// 轮询早期本来就没有 URL，应交给上层按 state 处理，而非当错误。
  static String? parseResultUrl(String responseBody) {
    if (responseBody.trim().isEmpty) return null;
    dynamic decoded;
    try {
      decoded = jsonDecode(responseBody);
    } catch (_) {
      // 畸形 JSON：不抛，返回 null，让上层按状态决定（如重试或报解析失败）。
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    return _extractResultUrl(decoded);
  }

  // --------------------------------------------------------------------------
  // 以下为内部实现
  // --------------------------------------------------------------------------

  /// 递归创建 `{appDoc}/generated/videos/`。
  static Future<Directory> _ensureDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(
      '${docs.path}${Platform.pathSeparator}generated${Platform.pathSeparator}videos',
    );
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// 把响应体解析成任务快照；[knownId] 为查询时已知的 id（响应缺失 id 时的兜底）。
  static VideoTaskSnapshot _snapshotFromBody(String body, String? knownId) {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw VideoGenException(
        message: '响应格式异常：预期一个 JSON 对象，但拿到了其他类型。',
        detail: _truncate(body),
      );
    }

    final id = _asString(decoded['id']) ?? knownId;
    if (id == null || id.isEmpty) {
      throw VideoGenException(
        message: '响应缺少任务 id（任务可能创建失败）。',
        detail: _truncate(body),
      );
    }

    final state = parseState(
      _asString(decoded['status']) ?? _asString(decoded['state']),
    );
    final resultUrl = _extractResultUrl(decoded);
    final errorMessage =
        state == VideoTaskState.failed ? _extractError(decoded) : null;
    final progress = _extractProgress(decoded);

    return VideoTaskSnapshot(
      id: id,
      state: state,
      resultUrl: resultUrl,
      errorMessage: errorMessage,
      progressPercent: progress,
    );
  }

  /// 从已解码的响应体里按多路径方言提取视频 URL。
  static String? _extractResultUrl(dynamic node) {
    const paths = <List<Object>>[
      ['task_result', 'videos', 0, 'url'], // 主流：任务结果里的视频数组
      ['task_result', 'video_url'],
      ['task_result', 'url'],
      ['data', 0, 'url'],
      ['data', 0, 'video_url'],
      ['output', 'video_url'],
      ['content', 'video_url'],
      ['video_url'], // 平铺在顶层
      ['url'],
    ];
    for (final p in paths) {
      final v = _walk(node, p);
      if (v != null) return v;
    }
    return null;
  }

  /// 沿 [path] 在嵌套结构里取值；任一环类型不符即返回 null（不抛）。
  static String? _walk(dynamic node, List<Object> path) {
    dynamic cur = node;
    for (final seg in path) {
      if (seg is String) {
        if (cur is! Map) return null;
        cur = cur[seg];
      } else if (seg is int) {
        if (cur is! List || seg < 0 || seg >= cur.length) return null;
        cur = cur[seg];
      } else {
        return null;
      }
    }
    return cur is String && cur.isNotEmpty ? cur : null;
  }

  /// 提取失败原因（多方言）：error / error_message / message / last_error / task_result.error。
  static String? _extractError(Map<String, dynamic> decoded) {
    for (final key in const [
      'error_message',
      'errorMessage',
      'error',
      'last_error',
      'message',
    ]) {
      final v = decoded[key];
      if (v is String && v.isNotEmpty) return v;
      // error 有时是对象（{message:...}），取它的 message。
      if (v is Map && v['message'] is String) return v['message'] as String;
    }
    // task_result 里也可能带 error。
    final tr = decoded['task_result'];
    if (tr is Map) {
      final e = tr['error'];
      if (e is String && e.isNotEmpty) return e;
      if (e is Map && e['message'] is String) return e['message'] as String;
    }
    return null;
  }

  /// 提取进度百分比（多方言）：progress / progress_percent / percent / task_result.progress。
  static int? _extractProgress(Map<String, dynamic> decoded) {
    num? pick(String key) => decoded[key] is num ? decoded[key] as num : null;
    num? v =
        pick('progress') ?? pick('progress_percent') ?? pick('percent');
    if (v == null) {
      final tr = decoded['task_result'];
      if (tr is Map && tr['progress'] is num) v = tr['progress'] as num;
    }
    if (v == null) return null;
    final p = v.round();
    if (p < 0) return 0;
    if (p > 100) return 100;
    return p;
  }

  /// 把 HTTP 非 2xx 转成面向用户的中文异常（按状态码分情况给提示）。
  /// build129：加 [model] 入参——与 `ImageGenService._statusException` 同构。
  /// 400/404 这类「模型/端点不匹配」的错必须把**实际使用的模型名**说出来，否则唯一
  /// 可行的修复动作（换视频模型）无人知晓：真机日志里模型只能猜「是不是参数不对」，
  /// 于是连搜 7 轮「怎么给 video_gen 传 model」，最后用户手动停止。
  static VideoGenException _statusException(
    int code,
    String body, {
    String? model,
  }) {
    final detail = _truncate(body);
    final m = (model ?? '').trim();
    final modelHint = m.isEmpty ? '当前模型' : '当前模型「$m」';
    String message;
    switch (code) {
      case 401:
        message = '鉴权失败（401）：请检查 API Key 是否正确、是否已过期。';
      case 403:
        message = '无权限（403）：当前 Key 或账户不支持视频生成能力。';
      case 404:
        // 历史坑点：很多中转只实现了 chat，没实现 videos 端点。
        message = '接口不存在（404）：当前中转/网关可能不支持 videos 视频端点；'
            '也可能是$modelHint 不属于视频模型，请在「API 配置 → 文生视频模型」换一个。';
      case 400:
        message = '请求被拒（400）：$modelHint 很可能不是文生视频模型（对话模型不能生视频）。'
            '请到「API 配置 → 文生视频模型」填一个视频模型名'
            '（如 grok-imagine-video / kling-video-o1 / sora-2），再重试。'
            // 上游正文本来就点名了可用模型，直接回灌——省掉「猜模型名」这一步
            // （真机正文：'Use grok-imagine-video.'）。
            '${_suggestedSuffix(body)}';
      case 429:
        message = '请求过于频繁（429）：额度或限速受限，请稍后再试。';
      case 500:
      case 502:
      case 503:
      case 504:
        message = '服务端错误（$code）：上游模型服务暂不可用，请稍后再试。';
      default:
        message = '视频请求失败（HTTP $code）。';
    }
    return VideoGenException(message: message, detail: detail);
  }

  /// build129：最近一次视频 400 里**上游点名的可用模型清单**（进程内缓存，不落库）。
  ///
  /// 用途与 `ImageGenService.lastUpstreamSuggestedModels` 一致：给「对话设置 → 生成模型」
  /// 选择器当候选。不落库的理由也一致——这串名字随 Key/中转站变化，跨会话复用会误导。
  static List<String> lastUpstreamSuggestedVideoModels = const [];

  /// build129：把上游 400 正文里点名的可用模型拼成一句回灌文案（无则空串）。
  ///
  /// 解析器**直接复用** `ImageGenService.parseSuggestedModels`：它是纯函数、且逻辑
  /// 与端点无关（都是 OpenAI 兼容网关的 `Use A, B, C.` 句式）。不复制第二份的原因
  /// 是本项目吃过「同一语义多处各写一份」的亏（见 video_gen_service 头部注释）。
  static String _suggestedSuffix(String body) {
    final s = ImageGenService.parseSuggestedModels(body);
    if (s.isNotEmpty) lastUpstreamSuggestedVideoModels = List.unmodifiable(s);
    return s.isEmpty ? '' : '上游本次明确建议：${s.join(' / ')}。';
  }

  /// taskId 文件名安全清洗：只留字母数字下划线连字符，其余替换为 _，并限长 64。
  static String _sanitizeTaskId(String id) {
    var cleaned = id.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');
    if (cleaned.isEmpty) cleaned = 'unknown';
    if (cleaned.length > 64) cleaned = cleaned.substring(0, 64);
    return cleaned;
  }

  /// 取字符串值（非 String 或非空返回 null）。
  static String? _asString(dynamic v) =>
      v is String && v.isNotEmpty ? v : null;

  /// 把异常 detail 截断到 500 字以内，避免把大段原始内容打进日志/异常。
  static String _truncate(String s) =>
      s.length > 500 ? '${s.substring(0, 500)}…(截断)' : s;
}
