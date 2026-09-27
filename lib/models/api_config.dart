import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'package:flutter/foundation.dart';

import '../services/secret_store.dart';

/// 历史默认的输出上限（从 v1 一路带到这里，没人改过它，也没人**选**过它）。
///
/// build167 起它多一层语义：**"配到这个数及以下"= 用户没配过** ⇒
/// `api_service.requestMaxTokens` 会**不发** `max_tokens`，把默认交回上游
/// （DeepSeek 官方默认：非思考档 8K、思考档 64K；我们发 4096 比默认还低一半，
/// 真机因此把整页 HTML 拦腰截断）。数值本身没动，动的是"我们不再替你做主"。
const int kLegacyUnsetMaxTokens = 2048;

class ApiConfig implements SecretBearing {
  final String id;
  String name;
  String baseUrl;

  /// 连接密钥。
  ///
  /// build146（密钥入 Keystore）：这一格在**内存里**永远是真值，但它落库时
  /// 不再进 `api_configs.apiKey` 列 —— 该列落成空串，值进 [secretLocations]
  /// 指向的保险库键。抹掉/回填都由 `StorageService` 读写路径负责
  /// （保存走 [_persistableApiKeyFor]，读取走 [applySecret]），
  /// 因此所有既有调用点（`config.apiKey` 直接拼 Authorization 头）一行都不用改。
  String apiKey;
  String model;
  // build125：文生图**专用**模型名（留空 = 用对话模型 model）。
  // 为什么必须单独一列：绝大多数中转站里「对话模型」与「图像模型」是两套名字
  // （如对话 grok-4.6 / 生图 grok-2-image），拿对话模型名打
  // /v1/images/generations 会稳定 400（真机日志 nexus_export_2026-09-17T22-09 实锤
  // 4 次尝试全部 400，而同一 key 的 chat/completions 是 200）。
  String imageModel;
  // build129：文生视频**专用**模型名（留空 = 用对话模型 model）。
  // 与 imageModel 是同一个坑的两半——build125 只补了图片这一半：
  // 真机日志 nexus_export_2026-09-19T10-05 实锤，/v1/videos 用对话模型 grok-4.6
  // 稳定 400（上游原文：`Model grok-4.6 is not supported on /v1/videos/generations,
  // /v1/videos/edits, or /v1/videos/extensions. Use grok-imagine-video.`），
  // 而同一 key 生图换成 grok-imagine-image-2.0 后立刻 200 出图。
  // 视频比图片更刚需：视频没有「试错即出图」的便宜路径，错一次就是 1~5 分钟白等。
  String videoModel;
  String systemPrompt;
  double temperature;
  double topP;
  int maxTokens;
  int? contextWindowTokens;
  String templateId;

  /// build138（G44/G45，任务书 §三）：所属**账号** id —— 连接身份（baseUrl/Key/
  /// 在线模型列表）归 [ApiAccount]，本条只表示「该账号下的一个模型条目」。
  ///
  /// 空串是**合法**状态而不是脏数据：v39 之前的库、以及导入的 v2/v3 备份都可能
  /// 没有账号。所有读路径都按「空 ⇒ 用本条自己的 baseUrl/apiKey」回退
  /// （见 [AccountGrouping.fillFromAccount]），因此老库升级后零行为变化。
  String accountId;

  String cachedModels;
  bool supportVision;
  // T1：function calling 原生工具通道开关（默认开；T7 探测失败后自动置 false）
  bool supportToolCalls;
  // build122：生成类能力位。刻意与 supportVision/supportToolCalls 区分开——
  // 前者描述「**输入**能否收图」，这两个描述「**输出**能否产图/产视频」，
  // 是两条独立的能力轴（同一个 key 下：能看图的模型未必能生图，反之亦然）。
  // 默认 false：不猜（同 supportVision 的口径——探测/用户显式开启才用），
  // 避免用户在中转不支持时被端点 404 打个措手不及。
  bool supportImageGen;
  bool supportVideoGen;

  /// G50（build136）：采样参数的**唯一**默认值来源。
  ///
  /// 恒发 `temperature: 0.7` / `top_p: 1.0` 有两个真实代价：
  /// ① 用户从没设过的值被当成「用户的选择」发给上游；
  /// ② 部分推理模型不接受 temperature，恒发即 400。
  /// 而这两列自 v1.7.25 起编辑页就已没有控件，值只能靠旧数据/导入带进来。
  static const double kDefaultTemperature = 0.7;
  static const double kDefaultTopP = 1.0;

  /// G50（build136）：请求体里该带的采样参数。
  ///
  /// 只带**用户显式设过的非默认值**：
  /// - 会话设置面板的温度 / Top P 滑杆会经 `_conversationApiConfig`
  ///   （chat_screen_context）把会话值 `copyWith` 进来，非默认即代表用户真的调过 ⇒ 照发；
  /// - 等于默认值则**整项不发**，让上游用自己的默认 —— 治「没设过也恒发」。
  ///
  /// 两处请求体（streamChat / completeChat）都用它，口径只有这一处。
  Map<String, dynamic> get samplingParams => <String, dynamic>{
        if (temperature != kDefaultTemperature) 'temperature': temperature,
        if (topP != kDefaultTopP) 'top_p': topP,
      };

  ApiConfig({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.imageModel = '',
    this.videoModel = '',
    this.systemPrompt = '',
    this.temperature = kDefaultTemperature,
    this.topP = kDefaultTopP,
    this.maxTokens = kLegacyUnsetMaxTokens,
    this.contextWindowTokens,
    this.templateId = 'custom',
    this.accountId = '',
    this.cachedModels = '',
    this.supportVision = false,
    this.supportToolCalls = true,
    this.supportImageGen = false,
    this.supportVideoGen = false,
  });

  /// G53（build136）：**不再有假默认**。
  ///
  /// 原先 name='New API' / baseUrl='https://api.openai.com' / model='gpt-4o-mini'，
  /// 于是两条「无配置」路径会真实落一条 openai 假配置：`main.dart` 的分享冷启动、
  /// `conversation_list_screen._createConversation`。用户从没填过 Key，却多出一个
  /// 「看起来能用」的模型条目，第一条消息必然 401。
  /// 现在三处默认全为空串，调用方必须显式给值；空配置一律走「引导建账号」。
  factory ApiConfig.create({
    String name = '',
    String baseUrl = '',
    String apiKey = '',
    String model = '',
  }) {
    return ApiConfig(
      id: const Uuid().v4(),
      name: name,
      baseUrl: baseUrl,
      apiKey: apiKey,
      model: model,
    );
  }

  /// build125：文生图实际使用的模型名。
  ///
  /// 优先级：`imageModel`（专用，用户在「API 配置」里显式填写）→ `model`（对话模型，
  /// 兼容老配置/单模型中转）。空串兜底到对话模型，保证老配置行为不变。
  String get effectiveImageModel {
    final dedicated = imageModel.trim();
    return dedicated.isNotEmpty ? dedicated : model.trim();
  }

  /// build125：是否配置了「文生图专用模型」（UI 用于显示/提示，判断口径只有这一处）。
  bool get hasDedicatedImageModel => imageModel.trim().isNotEmpty;

  /// build129：文生视频实际使用的模型名。
  ///
  /// 优先级与 [effectiveImageModel] **逐字同构**：`videoModel`（专用）→ `model`（对话模型，
  /// 兼容老配置/单模型中转）。两处若哪天要改口径，必须一起改——不然「图片能选、视频不能」
  /// 这种半截修复会再来一次（这正是本字段存在的理由）。
  String get effectiveVideoModel {
    final dedicated = videoModel.trim();
    return dedicated.isNotEmpty ? dedicated : model.trim();
  }

  /// build129：是否配置了「文生视频专用模型」。
  bool get hasDedicatedVideoModel => videoModel.trim().isNotEmpty;

  /// build138（G52，任务书 §三.5）：余额/用量缓存的键 = **账号 id**（无账号时退回
  /// 本条 id，行为与升级前一致）。
  ///
  /// 为什么必须换键：余额是**账号**的属性，一个 DeepSeek Key 下挂 3 个模型曾是
  /// 3 条独立配置 ⇒ `BalanceService` 按 config.id 缓存形同没有缓存，
  /// 打开一次列表页发 3 次 `/user/balance`。换成账号键后同账号多模型只查一次。
  String get balanceCacheKey =>
      accountId.trim().isNotEmpty ? accountId.trim() : id;

  /// v1.5.0：把 cachedModels JSON 字符串解码成 List<String>
  ///
  /// 反序列化失败 / 空字符串 → 返回空列表（不抛异常，避免 UI 渲染崩溃）
  List<String> get cachedModelsList {
    if (cachedModels.isEmpty) return const [];
    try {
      final list = json.decode(cachedModels);
      if (list is List) {
        return list.map((e) => e.toString()).toList();
      }
    } catch (e) { debugPrint('catch 静默异常: $e'); }
    return const [];
  }

  @override
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'baseUrl': baseUrl,
      'apiKey': apiKey,
      'model': model,
      'imageModel': imageModel,
      'videoModel': videoModel,
      'systemPrompt': systemPrompt,
      'temperature': temperature,
      'topP': topP,
      'maxTokens': maxTokens,
      if (contextWindowTokens != null)
        'contextWindowTokens': contextWindowTokens,
      'templateId': templateId,
      'accountId': accountId,
      'cachedModels': cachedModels,
      'supportVision': supportVision ? 1 : 0,
      'supportToolCalls': supportToolCalls ? 1 : 0,
      'supportImageGen': supportImageGen ? 1 : 0,
      'supportVideoGen': supportVideoGen ? 1 : 0,
    };
  }

  // ==========================================================================
  // build146（密钥入 Keystore）—— 与 [ApiAccount] / [WebSearchConfig] 逐字同构的
  // 三个成员，实现 [SecretBearing]。口径：
  //   [toMap]      完整语义（备份导出、分享、内存重建），密钥列带真值。
  //   [toRowMap]   落库形状，密钥列抹空 —— **只有** StorageService 确认保险库
  //                写入并读回校验通过时才允许拿它去 insert。
  //   [applySecret] 读路径回填。
  // 「哪一列是密钥」这件事在模型和保险库键名里只写一份（这里 + secret_store 的
  // scope 常量），新增密钥字段时改这一处即可 —— 备份剥敏、迁移、清扫都从这里派生。
  // ==========================================================================

  @override
  List<SecretLocation> secretLocations() => [
        SecretLocation(
          scope: SecretStore.apiConfigScope,
          rowId: id,
          table: 'api_configs',
          column: 'apiKey',
        ),
      ];

  @override
  String secretValueAt(SecretLocation loc) => apiKey;

  /// 本次生命周期里**保险库没读到值**的字段名（区别于「用户清空」，
  /// 见 [SecretReadResult.failed]）。纯内存标记：不进 `toMap`、不落库、
  /// 不参与 `fromMap` 往返 —— 它只对"这一份对象接下来会被写回去"负责。
  @override
  final Set<String> unreadableSecrets = <String>{};

  /// 回填。**空值不覆盖**是刻意的：读路径先跑保险库、再跑账号补值，
  /// 若这里允许空串把已有的列内明文抹掉，保险库坏掉的那一刻就会丢 Key。
  @override
  void applySecret(SecretLocation loc, String value) {
    if (loc.rowId != id || loc.column != 'apiKey') return;
    if (value.trim().isEmpty) return;
    apiKey = value;
  }

  @override
  Map<String, dynamic> toRowMap() => toMap()..['apiKey'] = '';

  /// Returns true only for model identifiers that clearly advertise image input.
  /// Unknown providers remain disabled until the user explicitly enables vision.
  static bool detectVisionSupport(String modelId) {
    final normalized = modelId.trim().toLowerCase();
    if (normalized.isEmpty) return false;

    const markers = <String>[
      'vision',
      'image',
      'multimodal',
      '4o',
      'gpt-5',
      'gemini',
      'claude-3',
      'claude-4',
      'glm-4v',
      // 视觉版族是 GLM-5V / GLM-5V-Turbo（含 turbo 等后缀）
      'glm-5v',
      // build97 (P2-5 修复)：GLM-5.3 是纯文本推理模型（输入模态仅 Text），
      // contains 全族命中（含 glm-5.3-flash）会导致每次带图都白发一次
      // 注定 400 的请求再降级 OCR。视觉能力交用户手动开关。
      'moonshot-v1-vision',
    ];
    if (markers.any(normalized.contains)) return true;

    // Match VL as a model-family segment, not as an arbitrary substring.
    return RegExp(r'(^|[-_./])vl([\-_.:/]|$)').hasMatch(normalized);
  }

  /// T1：工具调用（function calling）能力启发式。
  /// 默认乐观（true）——OpenAI 兼容网关普遍透传 tools；
  /// 仅对已知不支持的历史模型族返回 false。探测失败后由 T7 自动置 false。
  static bool detectToolCallsSupport(String modelId) {
    final normalized = modelId.trim().toLowerCase();
    if (normalized.isEmpty) return false;
    const denyMarkers = <String>[
      'o1-preview',
      'o1-mini',
      'gpt-3.5-turbo-instruct',
      'text-davinci',
      'babbage',
      'curie',
    ];
    return !denyMarkers.any(normalized.contains);
  }

  factory ApiConfig.fromMap(Map<String, dynamic> map) {
    return ApiConfig(
      id: map['id'] as String,
      name: map['name'] as String,
      baseUrl: map['baseUrl'] as String,
      apiKey: map['apiKey'] as String,
      model: map['model'] as String,
      imageModel: (map['imageModel'] as String?) ?? '',
      videoModel: (map['videoModel'] as String?) ?? '',
      systemPrompt: (map['systemPrompt'] as String?) ?? '',
      temperature: (map['temperature'] as num?)?.toDouble() ?? 0.7,
      topP: (map['topP'] as num?)?.toDouble() ?? 1.0,
      maxTokens: (map['maxTokens'] as num?)?.toInt() ?? kLegacyUnsetMaxTokens,
      contextWindowTokens: (map['contextWindowTokens'] as num?)?.toInt(),
      templateId: (map['templateId'] as String?) ?? 'custom',
      accountId: (map['accountId'] as String?) ?? '',
      cachedModels: (map['cachedModels'] as String?) ?? '',
      supportVision: (map['supportVision'] as num?)?.toInt() == 1,
      // T1：默认开（缺列/老数据视为支持，由 T7 探测失败后自动关）
      supportToolCalls: (map['supportToolCalls'] as num?)?.toInt() != 0,
      supportImageGen: (map['supportImageGen'] as num?)?.toInt() == 1,
      supportVideoGen: (map['supportVideoGen'] as num?)?.toInt() == 1,
    );
  }

  String toJson() => json.encode(toMap());

  factory ApiConfig.fromJson(String source) =>
      ApiConfig.fromMap(json.decode(source) as Map<String, dynamic>);

  ApiConfig copyWith({
    /// G51（build136）：导入时「重复 id → 换新 id 新增」需要能改 id。
    String? id,
    String? name,
    String? baseUrl,
    String? apiKey,
    String? model,
    String? imageModel,
    String? videoModel,
    String? systemPrompt,
    double? temperature,
    double? topP,
    int? maxTokens,
    int? contextWindowTokens,
    String? templateId,
    String? accountId,
    String? cachedModels,
    bool? supportVision,
    bool? supportToolCalls,
    bool? supportImageGen,
    bool? supportVideoGen,
  }) {
    return ApiConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
      imageModel: imageModel ?? this.imageModel,
      videoModel: videoModel ?? this.videoModel,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      temperature: temperature ?? this.temperature,
      topP: topP ?? this.topP,
      maxTokens: maxTokens ?? this.maxTokens,
      contextWindowTokens: contextWindowTokens ?? this.contextWindowTokens,
      templateId: templateId ?? this.templateId,
      accountId: accountId ?? this.accountId,
      cachedModels: cachedModels ?? this.cachedModels,
      supportVision: supportVision ?? this.supportVision,
      supportToolCalls: supportToolCalls ?? this.supportToolCalls,
      supportImageGen: supportImageGen ?? this.supportImageGen,
      supportVideoGen: supportVideoGen ?? this.supportVideoGen,
    )
      // build152（D1，P0）：见 `web_search_config.dart` 里同一段注释 ——
      // `copyWith` 丢掉「本次没读到密钥」的标记 = 让 build147 那条 Key 消失 P0 复活。
      // 本文件这条最容易被踩：ReAct 探测失败后会 `baseCfg.copyWith(supportToolCalls: false)`
      // 落库降级（chat_screen_react.dart 里两处），一次降级就把标记洗掉。
      ..unreadableSecrets.addAll(unreadableSecrets);
  }

  String get chatEndpoint {
    String url = baseUrl.trim();
    if (url.endsWith('/')) url = url.substring(0, url.length - 1);
    if (_isVersionedBase(url)) {
      return '$url/chat/completions';
    }
    return '$url/v1/chat/completions';
  }

  /// v1.5.0：拼接 `GET {baseUrl}/v1/models` 端点
  ///
  /// OpenAI 兼容服务都支持；本地模型（Ollama `http://localhost:11434/v1/models`）也兼容
  String get modelsEndpoint {
    String url = baseUrl.trim();
    if (url.endsWith('/')) url = url.substring(0, url.length - 1);
    if (_isVersionedBase(url)) {
      return '$url/models';
    }
    return '$url/v1/models';
  }

  /// build122：图片生成端点 `POST {baseUrl}/v1/images/generations`。
  ///
  /// 与 [modelsEndpoint] 同源处理 baseUrl：尾部斜杠与「已带版本路径」两种情况都归一
  /// —— 否则智谱 `.../paas/v4` 这类会被拼成 `.../v4/v1/images/generations`（多一层 /v1），
  /// 与 v1.5.2 修 models 端点那个 bug 是同一个坑。
  String get imagesEndpoint => _joinEndpoint('images/generations');

  /// build129：图生图（编辑）端点 `POST {baseUrl}/v1/images/edits`（OpenAI 兼容形态）。
  /// 与 [imagesEndpoint] 同源拼法；上游若不支持该端点会返回 404，由服务层给文案。
  String get imagesEditsEndpoint => _joinEndpoint('images/edits');

  /// build122：视频生成创建端点 `POST {baseUrl}/v1/videos`（兼容 OpenAI Videos API 形态）。
  String get videosEndpoint => _joinEndpoint('videos');

  /// build122：视频任务查询端点 `GET {baseUrl}/v1/videos/{id}`。
  String videoStatusEndpoint(String taskId) => _joinEndpoint('videos/$taskId');

  /// 把 `{相对路径}` 拼到 baseUrl 上（统一处理尾部斜杠 / 已带版本前缀）。
  String _joinEndpoint(String relative) {
    String url = baseUrl.trim();
    if (url.endsWith('/')) url = url.substring(0, url.length - 1);
    if (_isVersionedBase(url)) {
      return '$url/$relative';
    }
    return '$url/v1/$relative';
  }

  /// v1.5.2：判断 baseUrl 是否已经带了版本路径（末尾一段以 `v`+数字开头，如 /v1、/v4）
  /// 修复 v1.5.0~v1.5.1 的 bug：智谱 GLM 的 baseUrl 是 `.../api/paas/v4`（末尾 /v4，不是 /v1），
  /// 旧逻辑只识别 /v1，导致 models 端点被错误拼成 `.../v4/v1/models`（多一个 /v1），
  /// 智谱刷新模型返回 401。
  ///
  /// 现在统一识别 `/v\d+` 结尾：
  ///   - DeepSeek `.../v1` → 直接拼 /models ✅
  ///   - 阿里云 `.../compatible-mode/v1` → 直接拼 /models ✅
  ///   - 智谱 `.../paas/v4` → 直接拼 /models ✅（修复点）
  ///   - Ollama `...:11434/v1` → 直接拼 /models ✅
  ///   - OpenAI 裸域名 `api.openai.com`（无版本）→ 拼 /v1/models ✅
  static bool _isVersionedBase(String url) {
    final last = url.split('/').last;
    return RegExp(r'^v\d').hasMatch(last);
  }
}
