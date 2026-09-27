import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/api_config.dart';
import '../utils/download_url_guard.dart';
import 'logger_service.dart';

/// 文生图服务层。
///
/// 走 OpenAI 兼容的 `POST {baseUrl}/v1/images/generations` 端点（与对话共用
/// baseUrl / apiKey，只换端点）。2026 现状：DALL·E 3 已停用，由 gpt-image 系列
/// 接班；大量国产模型（qwen-image / doubao-seedream / flux / grok-image /
/// sora_image 等）在中转站以「dall-e-3 格式」暴露同一端点。因此响应可能是
/// `b64_json` 也可能是 `url`，两者都要支持，且同一响应内可能混用。
class ImageGenService {
  // 图片生成很慢：官方文档称复杂提示最长约 2 分钟，给足 180s 总超时避免误杀。
  static const Duration _timeout = Duration(seconds: 180);
  // URL 下载也单独给超时（落盘前必须先把图拉下来，URL 有时效）。
  static const Duration _downloadTimeout = Duration(seconds: 120);

  static const String _tag = 'ImageGen';

  /// 发起一次文生图请求并把结果落盘到应用文档目录。
  ///
  /// - [prompt] 提示词（必填）
  /// - [size] 尺寸，默认 1024x1024
  /// - [n] 张数
  /// - [quality] low/medium/high，部分模型支持；null 则不传该字段
  /// - [modelOverride] 为空则用 `config.effectiveImageModel`
  ///   （= 配置里的文生图专用模型，未填则回落对话模型；build125）
  ///
  /// 任何失败都以 [ImageGenException] 抛出，不会静默返回空结果。
  static Future<ImageGenResult> generate(
    ApiConfig config, {
    required String prompt,
    String size = '1024x1024',
    int n = 1,
    String? quality,
    String? modelOverride,
    // build129：图生图（image-to-image）。非空则改走 /v1/images/edits（multipart），
    // 而不是 /v1/images/generations（JSON）。两者响应体同构 → 解析/落盘完全复用。
    String? inputImageBase64,
    String? inputImageName,
  }) async {
    // build125：模型解析优先级 = 显式 override > 配置的「文生图专用模型」> 对话模型。
    // 为什么不是直接用 config.model：中转站的对话模型与图像模型通常不同名
    // （对话 grok-4.6 / 生图 grok-2-image），拿对话模型名打 images 端点稳定 400
    // （真机日志实锤：4 次尝试全 400，同 key 的 chat 端点 200）。
    final override = (modelOverride ?? config.imageModel).trim();
    final fromDedicated = override.isNotEmpty;
    final model = fromDedicated ? override : config.model.trim();
    if (model.isEmpty) {
      throw const ImageGenException(
        message: '未指定文生图模型（model 为空），请先在配置中选择一个支持生图的模型。',
      );
    }
    if (prompt.trim().isEmpty) {
      throw const ImageGenException(message: '提示词（prompt）不能为空。');
    }

    final isEdit = (inputImageBase64 ?? '').trim().isNotEmpty;

    // 构造请求体：quality 仅在非空时带上，避免部分模型因不认识该字段而 400。
    final body = <String, dynamic>{
      'model': model,
      'prompt': prompt,
      'n': n,
      'size': size,
    };
    if (quality != null && quality.trim().isNotEmpty) {
      body['quality'] = quality.trim();
    }

    // 鉴权头：照项目既有习惯——本地/无鉴权端点 apiKey 为空时不发 Authorization。
    final headers = {'Content-Type': 'application/json'};
    if (config.apiKey.isNotEmpty) {
      headers['Authorization'] = 'Bearer ${config.apiKey}';
    }

    final uri = Uri.parse(
        isEdit ? config.imagesEditsEndpoint : config.imagesEndpoint);
    // 日志脱敏：imagesEndpoint 本身是路径不含 Key，但仍是面向用户的地址，只记 host+path。
    LoggerService.instance.info(
      'POST ${isEdit ? '图生图（edits）' : '文生图'} -> '
      '${uri.scheme}://${uri.host}${uri.path} | model=$model'
      '（${fromDedicated ? '文生图专用模型' : '回落到对话模型'}） size=$size n=$n'
      '${quality != null ? ' quality=$quality' : ''}'
      '${isEdit ? ' 参考图=${(inputImageName ?? '').trim().isEmpty ? 'input.png' : inputImageName}' : ''}',
      tag: _tag,
    );

    final http.Response resp;
    if (isEdit) {
      // OpenAI 官方的 edits 端点是 multipart/form-data（不是 JSON），照规范发。
      // 不引 http_parser 显式设 MIME：文件名保留真实扩展名即可（多数网关按扩展名判型），
      // 为此新增一个直接依赖不划算（且会触发 depend_on_referenced_packages）。
      final req = http.MultipartRequest('POST', uri);
      if (config.apiKey.isNotEmpty) {
        req.headers['Authorization'] = 'Bearer ${config.apiKey}';
      }
      req.fields['model'] = model;
      req.fields['prompt'] = prompt;
      req.fields['n'] = '$n';
      req.fields['size'] = size;
      if (quality != null && quality.trim().isNotEmpty) {
        req.fields['quality'] = quality.trim();
      }
      final Uint8List imgBytes;
      try {
        imgBytes = base64Decode(inputImageBase64!.trim());
      } catch (e) {
        throw ImageGenException(
          message: '参考图数据不合法（base64 解码失败），请重新选择图片。',
          detail: _truncate(e.toString()),
        );
      }
      final fname = (inputImageName ?? '').trim().isEmpty
          ? 'input.png'
          : inputImageName!.trim();
      req.files
          .add(http.MultipartFile.fromBytes('image', imgBytes, filename: fname));
      final streamed = await req.send().timeout(_timeout);
      resp = await http.Response.fromStream(streamed);
    } else {
      resp = await http
          .post(uri, headers: headers, body: jsonEncode(body))
          .timeout(_timeout);
    }

    LoggerService.instance.info(
      '${isEdit ? '图生图' : '文生图'} HTTP 状态: ${resp.statusCode}',
      tag: _tag,
    );

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      // build125（可诊断性）：上游错误正文**必须落日志**。此前只塞进异常的 detail
      // 且调用方丢弃 → 日志里只有「HTTP 状态: 400」一行，排查时无法区分
      // 「模型不支持该端点 / 参数名错 / 额度不足」，真机日志实锤模型只能瞎改参数
      // 重试（quality high→medium、换 prompt）白烧 4 轮。
      LoggerService.instance.warn(
        '${isEdit ? '图生图' : '文生图'}失败 HTTP ${resp.statusCode} | model=$model | '
        '上游响应: ${_truncate(resp.body)}',
        tag: _tag,
      );
      // build126：把上游点名的可用模型清单**留在进程内**，供「API 配置 → 文生图
      // 模型」一键填入——真机实锤用户/模型都无从知道自己的中转站有哪些图像模型。
      lastUpstreamSuggestedModels = parseSuggestedModels(resp.body);
      throw _statusException(resp.statusCode, resp.body, model: model);
    }

    return _persistResponse(resp.body);
  }

  /// build129：把一次成功响应体解析并落盘（generations / edits 共用同一份逻辑）。
  ///
  /// 抽出来的原因：图生图与文生图的**响应体完全同构**（都是 data[] 里给 b64_json
  /// 或 url），落盘/命名/原子写/扩展名推断不该存在第二份实现——本项目已经吃过
  /// 「同一语义两处各写一遍、只改一处」的亏（build125 的图片/视频模型缺口）。
  static Future<ImageGenResult> _persistResponse(String respBody) async {
    // 解析与网络/落盘分离：纯函数负责把响应体拆成「图片数据列表」。
    List<ParsedImage> items;
    try {
      items = parseImageGenResponse(respBody);
    } on ImageGenException {
      rethrow;
    } catch (e) {
      throw ImageGenException(
        message: '响应解析失败：返回内容不是合法的 JSON。',
        detail: _truncate(e.toString()),
      );
    }

    // 落盘：b64 直接写；url 先下载再写。两者混用也在同一次循环里处理。
    final dir = await _ensureDir();
    final stamp = _stamp(DateTime.now());
    final files = <File>[];
    final revised = <String>[];

    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      late final Uint8List bytes;
      String? ext;

      if (it.bytes != null) {
        bytes = it.bytes!;
        // b64 不携带 mime，扩展名交给下面的兜底（默认 png）。
      } else if (it.url != null) {
        // build133（③）：下载前做 scheme 白名单校验（纵深防御）。
        // 正常路径（上游返回的 http/https 链接）不受影响；file:// 之类的
        // 非常规 scheme 直接拒绝，不再把"按服务端指示读取本地文件"的口子留着。
        if (!isSafeDownloadUrl(it.url)) {
          throw ImageGenException(
            message: '图片下载失败：URL 不是 http/https，已拒绝。',
            detail: _truncate(it.url!),
          );
        }
        // URL 有时效，必须落盘；按 content-type 优先、URL 后缀兜底推断扩展名。
        final dl = await http
            .get(Uri.parse(it.url!))
            .timeout(_downloadTimeout);
        if (dl.statusCode != 200) {
          throw ImageGenException(
            message: '图片下载失败（HTTP ${dl.statusCode}），URL 可能已失效。',
            detail: _truncate(dl.body),
          );
        }
        bytes = dl.bodyBytes;
        ext = _extFromContentType(dl.headers['content-type']) ??
            _extFromUrl(it.url!);
      } else {
        // 纯函数已保证至少二选一，这里只是双保险。
        continue;
      }

      final name = 'img_${stamp}_${i + 1}.${ext ?? 'png'}';
      final file = await _atomicWrite(dir, name, bytes);
      files.add(file);
      revised.add(it.revisedPrompt ?? '');
      LoggerService.instance.info(
        '图片落盘: ${file.path} (${bytes.length} bytes)'
        '${it.revisedPrompt != null ? ' | revised: ${it.revisedPrompt}' : ''}',
        tag: _tag,
      );
    }

    LoggerService.instance.info(
      '图片生成完成: 共 ${files.length} 张',
      tag: _tag,
    );

    return ImageGenResult(files: files, revisedPrompts: revised);
  }

  /// 递归创建 `{appDoc}/generated/images/` 并返回该目录。
  static Future<Directory> _ensureDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(
      '${docs.path}${Platform.pathSeparator}generated${Platform.pathSeparator}images',
    );
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// 原子写：先写同目录临时文件，再 rename 覆盖目标。
  /// 避免写入中途崩溃/被杀留下半截文件（项目 workspace_service 同款写法）。
  static Future<File> _atomicWrite(
    Directory dir,
    String name,
    Uint8List bytes,
  ) async {
    final target = File('${dir.path}${Platform.pathSeparator}$name');
    final tmp = File(
      '${target.path}.tmp_${DateTime.now().microsecondsSinceEpoch}',
    );
    await tmp.writeAsBytes(bytes, flush: true);
    if (await target.exists()) await target.delete();
    return await tmp.rename(target.path);
  }

  /// 把 HTTP 非 2xx 转成面向用户的中文异常（状态码分情况给提示）。
  ///
  /// build125：加 [model] 入参——400/404 这类「模型/端点不匹配」的错误必须把
  /// **实际使用的模型名**说清楚，否则唯一可行的修复动作（换生图模型）无人知晓
  /// （真机日志实锤：模型只能猜「是不是 quality 参数不对」而反复改参数重试）。
  static ImageGenException _statusException(
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
        message = '无权限（403）：当前 Key 或账户不支持 images 文生图能力。';
      case 404:
        message = '接口不存在（404）：当前中转/网关可能不支持 images 文生图端点；'
            '也可能是$modelHint 不属于图像模型，请在「API 配置 → 文生图模型」换一个。';
      case 400:
        message = '请求被拒（400）：$modelHint 很可能不是文生图模型（对话模型不能生图）。'
            '请到「API 配置 → 文生图模型」填一个图像模型名（如 gpt-image-1 / dall-e-3 / '
            'grok-2-image / flux-schnell / doubao-seedream），再重试。'
            // build126：上游正文里本来就点名了可用模型，把它直接回灌——
            // 省掉「猜模型名」这一步（真机正文：'Use gpt-image-1.5, gpt-image-2, ...'）。
            '${_suggestedSuffix(body)}';
      case 429:
        message = '请求过于频繁（429）：额度或限速受限，请稍后再试。';
      case 500:
      case 502:
      case 503:
      case 504:
        message = '服务端错误（$code）：上游模型服务暂不可用，请稍后再试。';
      default:
        message = '图片生成请求失败（HTTP $code）。';
    }
    return ImageGenException(message: message, detail: detail);
  }

  /// build126：把上游 400 正文里点名的可用模型拼成一句回灌文案（无则空串）。
  static String _suggestedSuffix(String body) {
    final s = parseSuggestedModels(body);
    return s.isEmpty ? '' : '上游本次明确建议：${s.join(' / ')}。';
  }

  /// build126：最近一次 400 里**上游点名的可用模型清单**（进程内缓存，不落库）。
  ///
  /// 供「API 配置 → 文生图模型」一键填入。为什么不落库：这串名字随 Key/中转站变化，
  /// 跨会话复用反而误导（换了 Key 还提示旧站的模型名）。
  static List<String> lastUpstreamSuggestedModels = const [];

  /// build126：从上游错误正文里解析「它建议你用的模型名清单」（纯函数，无副作用）。
  ///
  /// 上游 OpenAI 兼容网关的典型正文：
  /// `{"error":{"message":"Model grok-4.6 is not supported on /v1/images/generations.
  /// Use gpt-image-1.5, gpt-image-2, grok-imagine-image, grok-imagine-image-quality,
  /// grok-imagine-image-2.0."}}`
  /// 即 `Use A, B, C.`——取 `Use ` 之后到句末（引号/换行/花括号为止），按逗号/顿号
  /// 切分，只保留「像模型名」的 token（字母数字与 . _ : - /，且至少含一个字母）。
  /// 注意：正则**禁用内联标志** `(?i)`（Android release 必崩，铁律 6），一律用命名参数。
  static List<String> parseSuggestedModels(String body) {
    if (body.trim().isEmpty) return const [];
    final idx = body.toLowerCase().indexOf('use ');
    if (idx < 0) return const [];
    var tail = body.substring(idx + 4);
    final stop = tail.indexOf(RegExp(r'["\n\r{}]'));
    if (stop >= 0) tail = tail.substring(0, stop);
    final out = <String>[];
    for (final raw in tail.split(RegExp(r'[,，、;；]'))) {
      var t = raw.trim().replaceAll(RegExp(r'[.\s]+$'), '');
      t = t.replaceFirst(RegExp(r'^(or|and)\s+', caseSensitive: false), '');
      if (t.isEmpty || t.length > 64) continue;
      if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:/-]*$').hasMatch(t)) continue;
      if (!RegExp(r'[A-Za-z]').hasMatch(t)) continue;
      if (out.contains(t)) continue;
      out.add(t);
    }
    return out;
  }

  /// 把响应体里的 detail 截断到 500 字以内，避免把大段原始内容打进日志/异常。
  static String _truncate(String s) =>
      s.length > 500 ? '${s.substring(0, 500)}…(截断)' : s;

  /// 仅供测试：把「HTTP 状态码 → 用户可见文案」暴露为纯函数（不联网、无副作用）。
  ///
  /// build125 加：400 文案必须**指名当前模型**（真机日志实锤，不指名模型时模型只能
  /// 猜「是不是 quality 参数不对」而反复改参数重试）——这条要求需要行为断言守住。
  @visibleForTesting
  static String statusMessageForTest(int code, String body, {String? model}) =>
      _statusException(code, body, model: model).message;
}

/// 单张解析结果的纯数据结构：要么内联 [bytes]（来自 b64_json），
/// 要么带 [url]（稍后下载）。[revisedPrompt] 为服务端改写后的提示词。
typedef ParsedImage = ({
  Uint8List? bytes,
  String? url,
  String? revisedPrompt,
});

/// 纯函数：把 images/generations 的响应体拆成图片数据列表。
///
/// 覆盖场景：
/// - 全部 b64_json
/// - 全部 url
/// - 同一响应内 b64 与 url 混用
/// - 畸形：JSON 解析失败 / data 非列表或为空 / 条目既无 b64 也无 url → 抛 [ImageGenException]
///
/// 该函数只解析、不联网、不落盘，便于单测。
List<ParsedImage> parseImageGenResponse(String body) {
  late final dynamic decoded;
  try {
    decoded = jsonDecode(body);
  } catch (e) {
    throw const ImageGenException(
      message: '响应解析失败：返回内容不是合法的 JSON。',
    );
  }

  final data = decoded is Map<String, dynamic> ? decoded['data'] : null;
  if (data is! List || data.isEmpty) {
    throw const ImageGenException(
      message: '服务端未返回任何图片数据（data 为空或不合法）。',
    );
  }

  final items = <ParsedImage>[];
  for (final raw in data) {
    if (raw is! Map<String, dynamic>) continue;

    final b64 = raw['b64_json'];
    final url = raw['url'];
    final revised = raw['revised_prompt'] as String?;

    if (b64 is String && b64.isNotEmpty) {
      // b64 可能带 data URI 前缀（如 data:image/png;base64,），这里剥掉它。
      var pure = b64;
      final comma = b64.indexOf(',');
      if (comma > 0 && b64.substring(0, comma).contains(';base64')) {
        pure = b64.substring(comma + 1);
      }
      try {
        items.add((
          bytes: base64Decode(pure),
          url: null,
          revisedPrompt: revised,
        ));
      } catch (e) {
        // 单张 base64 损坏：跳过该张，但记一条 warn 让上层可感知。
        LoggerService.instance.warn(
          '跳过一张损坏的 b64_json: ${ImageGenService._truncate(e.toString())}',
          tag: ImageGenService._tag,
        );
      }
    } else if (url is String && url.isNotEmpty) {
      items.add((bytes: null, url: url, revisedPrompt: revised));
    }
    // 既无 b64 也无 url 的条目：忽略，交给下面的整体判空。
  }

  if (items.isEmpty) {
    throw const ImageGenException(
      message: '响应里既没有 b64_json 也没有 url，无法生成图片。',
    );
  }
  return items;
}

/// 由 HTTP Content-Type 推断扩展名（优先）。
String? _extFromContentType(String? ct) {
  if (ct == null) return null;
  final lower = ct.toLowerCase();
  if (lower.contains('png')) return 'png';
  if (lower.contains('jpeg') || lower.contains('jpg')) return 'jpg';
  if (lower.contains('webp')) return 'webp';
  if (lower.contains('gif')) return 'gif';
  if (lower.contains('bmp')) return 'bmp';
  return null;
}

/// 由 URL 路径后缀推断扩展名（兜底）。
String? _extFromUrl(String url) {
  final path = Uri.parse(url).path;
  final dot = path.lastIndexOf('.');
  if (dot < 0 || dot >= path.length - 1) return null;
  final e = path.substring(dot + 1).toLowerCase();
  if (const ['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'].contains(e)) {
    return e == 'jpeg' ? 'jpg' : e;
  }
  return null;
}

/// yyyyMMdd_HHmmss 时间戳（手写格式化，避免引入 intl 新依赖）。
String _stamp(DateTime t) {
  String p(int n) => n.toString().padLeft(2, '0');
  return '${t.year}${p(t.month)}${p(t.day)}_${p(t.hour)}${p(t.minute)}${p(t.second)}';
}

/// 文生图失败的结构化异常。
///
/// [message] 面向用户的中文提示；[detail] 为原始响应片段/异常串（已截断），用于排查。
class ImageGenException implements Exception {
  final String message;
  final String? detail;

  const ImageGenException({required this.message, this.detail});

  @override
  String toString() =>
      detail != null ? 'ImageGenException: $message\n  detail: $detail' : 'ImageGenException: $message';
}

/// 文生图成功结果。
///
/// [files] 已落盘的图片；[revisedPrompts] 服务端改写后的提示词（按图对齐，可能为空串）。
class ImageGenResult {
  final List<File> files;
  final List<String> revisedPrompts;

  const ImageGenResult({required this.files, required this.revisedPrompts});
}
