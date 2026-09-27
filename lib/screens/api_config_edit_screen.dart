import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../models/api_config.dart';
import '../services/protocol/anthropic_protocol.dart';
import '../models/api_provider_template.dart';
import '../services/storage_service.dart';
import '../services/image_gen_service.dart';
import '../services/video_gen_service.dart';
import '../services/model_capability_memory.dart';
import '../services/api_service.dart';
import '../services/logger_service.dart';
import '../ui/tokens.dart';
import '../utils/launcher_utils.dart';
import '../widgets/vendor_avatar.dart';

/// build139（真机反馈②）：表单页限宽。
///
/// 宽屏（平板横屏 / 桌面窗口）上限宽不给，一行输入框能拉到 1200dp 以上，
/// 视线要从 label 一路追到屏幕最右边；680 是「字段并排也不挤」的下限，
/// 同时保证手机上等于通栏（不产生二次回归）。
const double kFormMaxWidth = 680;

class ApiConfigEditScreen extends StatefulWidget {
  final ApiConfig? config;

  const ApiConfigEditScreen({super.key, this.config});

  @override
  State<ApiConfigEditScreen> createState() => _ApiConfigEditScreenState();
}

class _ApiConfigEditScreenState extends State<ApiConfigEditScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late TextEditingController _baseUrlController;
  late TextEditingController _apiKeyController;
  late TextEditingController _modelController;
  // build125：文生图专用模型（留空 = 回落 _modelController 的对话模型）。
  late TextEditingController _imageModelController;
  // build129：文生视频专用模型（留空 = 回落 _modelController 的对话模型）。与图片侧成对。
  late TextEditingController _videoModelController;
  late TextEditingController _systemPromptController;
  late double _temperature;
  late TextEditingController _maxTokensController;
  late TextEditingController _contextWindowController;
  // v1.7.33：视觉支持开关（关闭时图片附件走本机 OCR 降级，不发给模型）
  late bool _supportVision;
  // build93 (T1)：工具调用开关
  late bool _supportToolCalls;
  // build123：生成类能力位——build122 加了字段/DB 列/端点，但**设置页没有开关**，
  // 用户无法开启，图片/视频生成页只能一直显示「该配置未开启生成能力」。
  late bool _supportImageGen;
  late bool _supportVideoGen;
  bool _toolCallsManuallyOverridden = false;
  bool _visionManuallyOverridden = false;

  /// build126 (C2)：模型视觉能力**记忆表**（modelId → 是否真的能收图）。
  ///
  /// 为什么不直接用 `ApiConfig.detectVisionSupport`：它是保守白名单，
  /// 新视觉模型（qwen3-vl / internvl / llava…）一律命中不到，只能用户手动开；
  /// 而手动开启的结论**跨会话不会被记住** —— 用户下次再选一次同款模型
  /// （`_onModelSelected` / 下拉菜单会重置 `_visionManuallyOverridden` 并用启发式
  /// 重算），开关又被打回 false，图片静默退回 OCR。
  ///
  /// 记忆表补上「记住」这一半，与启发式组成双向学习（见 ModelCapabilityMemory）。
  /// 与 `_visionManuallyOverridden` **正交不冲突**：后者管「本次编辑会话内用户
  /// 拨过开关就别再自动重算」，本表管「跨会话记住观测结论」。
  ///
  /// initState 异步读一次进内存，之后在 onChanged / 菜单回调里同步解析
  /// （那些回调不能 await）。
  Map<String, bool> _visionMemory = const {};
  bool _isTesting = false;
  String _testResult = '';
  bool _testSuccess = false;
  String _selectedTemplateId = ApiProviderTemplate.customId;

  /// build138（A 批）：当前所选服务商是否走 Anthropic 原生协议。
  /// 直接查 api_service 用的**同一张表**，避免「UI 说一套、请求走另一套」。
  bool get _isAnthropicNative =>
      kNativeProtocols[_selectedTemplateId] == ChatProtocol.anthropicMessages;
  // 当前选中的模型 id（仅用于高亮 UI；真正落到 config 的是 _modelController.text）
  String _selectedModelId = '';

  // v1.5.0：动态拉取模型列表
  bool _isRefreshingModels = false;
  String _refreshModelsMsg = '';
  List<String> _cachedModels = const [];
  String? _lastRefreshedAt;

  /// v1.5.3：按 baseUrl 缓存模型列表，切模板时恢复对应服务商的模型，
  /// 不串台（DeepSeek 模型不会串到阿里云）、不丢失（切回 DeepSeek 还在）。
  /// key = baseUrl，value = 该服务商拉取到的模型 id 列表。
  final Map<String, List<String>> _modelsByUrl = {};

  /// v1.5.4：按 baseUrl 分桶缓存 API Key，每个服务商独立保存自己的 Key。
  /// 切模板时自动切换对应服务商的 Key（DeepSeek 的 Key 不会串到阿里云，切回 DeepSeek 还在）。
  /// key = baseUrl，value = 该服务商的 API Key。
  final Map<String, String> _apiKeysByUrl = {};

  @override
  void initState() {
    super.initState();
    final c = widget.config ?? ApiConfig.create();
    _nameController = TextEditingController(text: c.name);
    _baseUrlController = TextEditingController(text: c.baseUrl);
    _apiKeyController = TextEditingController(text: c.apiKey);
    _modelController = TextEditingController(text: c.model);
    _imageModelController = TextEditingController(text: c.imageModel);
    _videoModelController = TextEditingController(text: c.videoModel);
    _systemPromptController = TextEditingController(text: c.systemPrompt);
    _temperature = c.temperature;
    _maxTokensController = TextEditingController(text: '${c.maxTokens}');
    _contextWindowController = TextEditingController(
      text: '${c.contextWindowTokens ?? 200000}',
    );
    _supportVision = c.supportVision;
    _supportToolCalls = c.supportToolCalls;
    // build126 (C2)：异步读视觉能力记忆表。默认空表 = 全部回落启发式，
    // 所以首帧行为与改动前完全一致，读到后 setState 再按记忆修正。
    unawaited(ModelCapabilityMemory.loadVisionMap().then((m) {
      if (mounted) setState(() => _visionMemory = m);
    }));
    _supportImageGen = c.supportImageGen;
    _supportVideoGen = c.supportVideoGen;
    // v1.5.0：从 ApiConfig 加载已缓存的模型列表（用户上次拉的）
    _cachedModels = c.cachedModelsList;
    // v1.5.3：把当前配置的 cachedModels 按 baseUrl 存入缓存 Map（编辑已有配置时）
    if (c.cachedModelsList.isNotEmpty && c.baseUrl.trim().isNotEmpty) {
      _modelsByUrl[c.baseUrl.trim()] = c.cachedModelsList;
    }
    // v1.5.4：把当前配置的 API Key 按 baseUrl 存入缓存 Map（编辑已有配置时）
    if (c.apiKey.isNotEmpty && c.baseUrl.trim().isNotEmpty) {
      _apiKeysByUrl[c.baseUrl.trim()] = c.apiKey;
    }
    // 如果已保存了 templateId，直接使用（v1.7.22+）；旧数据（templateId='custom'）则尝试反向匹配
    _selectedTemplateId = c.templateId;
    if (_selectedTemplateId == ApiProviderTemplate.customId) {
      _guessTemplateFromExisting();
    }
    // v1.7.32：模型列表只允许用户点击“在线刷新”获取，避免输入过程中反复请求。
    // 成功列表会随配置保存，之后作为离线可用缓存展示。
  }

  /// v1.5.0：调 ApiService.listModels 拉取真实可用模型列表
  ///
  /// 参考实现：Chatbox 的 `OpenAICompatible.listModels()`
  /// 调 `GET {baseUrl}/v1/models`，解析 `data[].id` 列表。
  ///
  /// 失败处理：保留旧 _cachedModels 不覆盖，UI 显示「拉取失败，已用上次缓存的列表」。
  /// 成功处理：缓存到 _cachedModels + 写回 ApiConfig.cachedModels（点保存时落库）。
  Future<void> _refreshModels() async {
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    var baseUrl = _baseUrlController.text.trim();
    if (baseUrl.isEmpty &&
        _selectedTemplateId != ApiProviderTemplate.customId) {
      // v1.7.36：已选模板但 Base URL 为空 → 自动回填模板地址，无需用户先填
      final t = ApiProviderTemplateCatalog.instance.all
          .where((e) => e.id == _selectedTemplateId)
          .firstOrNull;
      if (t != null && t.baseUrl.isNotEmpty) {
        baseUrl = t.baseUrl;
        _baseUrlController.text = baseUrl;
        if (_nameController.text.trim().isEmpty) {
          _nameController.text = t.defaultConfigName;
        }
      }
    }
    if (baseUrl.isEmpty) {
      setState(() => _refreshModelsMsg =
          isZh ? '⚠️ 请先填 Base URL' : '⚠️ Fill Base URL first');
      return;
    }
    setState(() {
      _isRefreshingModels = true;
      _refreshModelsMsg = '';
    });
    final logger = context.read<LoggerService>();
    try {
      final apiSvc = ApiService();
      final tmpCfg = ApiConfig(
        id: widget.config?.id ?? 'tmp',
        name: _nameController.text.trim(),
        baseUrl: baseUrl,
        apiKey: _apiKeyController.text.trim(),
        model: _modelController.text.trim(),
      );
      final models = await apiSvc.listModels(tmpCfg);
      // v1.5.3：异步回来后页面可能已销毁（用户退出），必须检查 mounted
      if (!mounted) return;
      if (models.isEmpty) {
        setState(() {
          _isRefreshingModels = false;
          _refreshModelsMsg =
              isZh ? '⚠️ 接口返回 0 个模型' : '⚠️ API returned 0 models';
        });
        return;
      }
      // 成功
      final now = DateTime.now();
      _lastRefreshedAt =
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
      logger.info('[Config] Models refreshed: ${models.length} from $baseUrl',
          cat: LogCat.api, tag: 'Config');
      setState(() {
        _cachedModels = models;
        if (!_visionManuallyOverridden &&
            _modelController.text.trim().isNotEmpty) {
          // build126 (C2)：记忆优先于白名单启发式
          _supportVision = ModelCapabilityMemory.resolveVisionSync(
              _modelController.text, _visionMemory);
        }
        if (!_toolCallsManuallyOverridden &&
            _modelController.text.trim().isNotEmpty) {
          _supportToolCalls =
              ApiConfig.detectToolCallsSupport(_modelController.text);
        }
        // v1.5.3：按 baseUrl 缓存，切模板时恢复、不串台
        _modelsByUrl[baseUrl] = models;
        _isRefreshingModels = false;
        _refreshModelsMsg = isZh
            ? '✅ 找到 ${models.length} 个模型'
                '${_lastRefreshedAt != null ? '（$_lastRefreshedAt）' : ''}'
            : '✅ Found ${models.length} models'
                '${_lastRefreshedAt != null ? ' ($_lastRefreshedAt)' : ''}';
      });
    } catch (e) {
      logger.warn('[Config] Refresh models failed: $e', tag: 'Config');
      // v1.5.3：异步回来后页面可能已销毁，必须检查 mounted（修 666.txt 崩溃）
      if (!mounted) return;
      setState(() {
        _isRefreshingModels = false;
        final errStr = e.toString();
        // v1.5.3：401 给明确提示（通常是 Key 没填/无效，不是 URL 问题）
        if (errStr.contains('401')) {
          // v1.7.36：401 且模板有预置模型时，自动回退内置列表（像 Chatbox 一样
          // 不填 Key 也能直接选模型，不再卡死在报错上）
          final t = ApiProviderTemplateCatalog.instance.all
              .where((e) => e.id == _selectedTemplateId)
              .firstOrNull;
          if (_cachedModels.isEmpty && t != null && t.models.isNotEmpty) {
            _cachedModels = t.models.map((m) => m.id).toList();
            _modelsByUrl[baseUrl] = _cachedModels;
            _refreshModelsMsg = isZh
                ? '💡 在线列表需要 API Key；已加载内置模型（${_cachedModels.length} 个），可直接在下方选择'
                : '💡 Online list needs API key; loaded ${_cachedModels.length} built-in models below';
          } else if (_cachedModels.isEmpty) {
            _refreshModelsMsg = isZh
                ? '❌ 拉取失败：401 未授权，请先填写正确的 API Key'
                : '❌ Failed: 401 unauthorized. Check your API key';
          } else {
            _refreshModelsMsg = isZh
                ? '⚠️ 401 未授权（请检查 API Key），已用上次缓存的 ${_cachedModels.length} 个模型'
                : '⚠️ 401 unauthorized (check API key), using ${_cachedModels.length} cached models';
          }
        } else {
          _refreshModelsMsg = _cachedModels.isEmpty
              ? (isZh ? '❌ 拉取失败：$e' : '❌ Failed: $e')
              : (isZh
                  ? '⚠️ 拉取失败（$e），已用上次缓存的 ${_cachedModels.length} 个模型'
                  : '⚠️ Failed ($e), using ${_cachedModels.length} cached models');
        }
      });
    }
  }

  /// 编辑已有配置时，根据 baseUrl 尝试匹配到模板（让 UI 显示对应模型列表）
  ///
  /// build101 (EP2)：修复**空串恒真陷阱**。
  /// 旧实现把模板 baseUrl 剥去 scheme 后 `.split('/').first` 取 host 再 `url.contains(host)`，
  /// 但 Ollama / LM Studio（`group: local`）的 `baseUrl = ''`（用户要自己填 IP），
  /// `''.split('/').first == ''` → `url.contains('')` **恒为 true** →
  /// 任何自定义 baseUrl 都会被改写成 ollama/lmstudio，保存后分组显示成「本地模型」。
  /// 修复口径：
  ///   ① `baseUrl.isEmpty` 的模板直接 continue（没有 host 可比，不参与匹配）
  ///   ② host 比对从「子串 contains」收紧为「精确相等 or 点号后缀匹配」，
  ///      避免 `api.x.com` 被 `x.com` 的模糊子串规则误伤、也避免 `foobar.com` 命中 `bar.com`
  void _guessTemplateFromExisting() {
    final url = _baseUrlController.text.trim();
    if (url.isEmpty) return;
    final host = _hostOf(url);
    if (host.isEmpty) return;
    for (final t in ApiProviderTemplateCatalog.instance.all) {
      // ① 空 baseUrl 模板（Ollama / LM Studio）不参与匹配
      if (t.baseUrl.trim().isEmpty) continue;
      final tHost = _hostOf(t.baseUrl);
      if (tHost.isEmpty) continue;
      // ② 精确相等，或点号后缀匹配（`api.deepseek.com` 命中 `deepseek.com`）
      if (host == tHost ||
          host.endsWith('.$tHost') ||
          tHost.endsWith('.$host')) {
        _selectedTemplateId = t.id;
        _selectedModelId = _modelController.text.trim();
        return;
      }
    }
  }

  /// 从 URL 中提取 host（剥 scheme / 路径 / 端口）。
  /// 例：`https://api.deepseek.com/v1` → `api.deepseek.com`
  String _hostOf(String raw) {
    var s = raw.trim();
    s = s.replaceAll('https://', '').replaceAll('http://', '');
    final slash = s.indexOf('/');
    if (slash >= 0) s = s.substring(0, slash);
    final colon = s.indexOf(':');
    if (colon >= 0) s = s.substring(0, colon);
    return s.toLowerCase();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final storage = context.read<StorageService>();
    final logger = context.read<LoggerService>();
    // v1.5.4：保存前把当前 Key 同步到分桶 Map（确保切走再切回能恢复）
    final curBaseUrl = _baseUrlController.text.trim();
    if (curBaseUrl.isNotEmpty) {
      _apiKeysByUrl[curBaseUrl] = _apiKeyController.text.trim();
    }
    // v1.5.0：cachedModels 序列化成 JSON 字符串一起落库（空列表→空字符串）
    final cachedJson = _cachedModels.isEmpty ? '' : json.encode(_cachedModels);
    final config = (widget.config ?? ApiConfig.create()).copyWith(
      name: _nameController.text.trim(),
      baseUrl: curBaseUrl,
      apiKey: _apiKeyController.text.trim(),
      model: _modelController.text.trim(),
      imageModel: _imageModelController.text.trim(),
      videoModel: _videoModelController.text.trim(),
      systemPrompt: _systemPromptController.text.trim(),
      temperature: _temperature,
      maxTokens: int.tryParse(_maxTokensController.text.trim()) ?? 2048,
      contextWindowTokens:
          int.tryParse(_contextWindowController.text.trim()) ?? 200000,
      supportVision: _supportVision,
      // build97 (P0-3 修复)：漏传 supportToolCalls——开关拨了保存即丢，
      // T7 降级写 false 后用户无法手动改回（工具通道永久失效）。
      supportToolCalls: _supportToolCalls,
      // build123：生成类能力位漏传即「开关拨了保存就丢」（与 build97 的
      // supportToolCalls 同一个坑，别再犯第二次）
      supportImageGen: _supportImageGen,
      supportVideoGen: _supportVideoGen,
      templateId: _selectedTemplateId,
      cachedModels: cachedJson,
    );
    logger.info(
        'Saving API config: name="${config.name}" model="${config.model}" baseUrl="${config.baseUrl}" cachedModels=${_cachedModels.length}项',
        tag: 'ApiConfig');
    final savedId = await storage.saveApiConfig(config);
    // build138（G45）：本页的「地址 / Key / 在线模型列表」三个字段是**账号**的属性，
    // 只写条目 = 同账号的其它模型还留着旧 Key，改天就是一半能用一半 401。
    // 顺序不能反：saveApiAccount 会按 accountId 把同步值刷到已入库的条目上，
    // 所以必须先有上面的 saveApiConfig（它还可能顺手懒绑定/新建账号）。
    final saved = await storage.getApiConfig(savedId);
    final acctId = saved?.accountId.trim() ?? '';
    if (acctId.isNotEmpty) {
      final account = await storage.getApiAccount(acctId);
      if (account != null) {
        await storage.saveApiAccount(account.copyWith(
          // 账号名**不跟着条目名改**：条目名是「DeepSeek 2」这种模型级标识，
          // 拿它覆盖账号名会让一级页的厂商卡变成「DeepSeek 2」。
          baseUrl: config.baseUrl,
          apiKey: config.apiKey,
          cachedModels: cachedJson,
        ));
      }
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> _testConnection() async {
    final l = AppLocalizations.of(context);
    final logger = context.read<LoggerService>();
    setState(() {
      _isTesting = true;
      _testResult = '';
    });
    try {
      final config = ApiConfig(
        id: widget.config?.id ?? '',
        name: _nameController.text,
        baseUrl: _baseUrlController.text.trim(),
        apiKey: _apiKeyController.text.trim(),
        model: _modelController.text.trim(),
      );
      logger.info(
          'Testing connection → baseUrl=${config.baseUrl} model=${config.model}',
          tag: 'ApiTest');
      final t0 = DateTime.now();
      final result = await context.read<ApiService>().testConnection(config);
      final ms = DateTime.now().difference(t0).inMilliseconds;
      logger.info(
          'Test OK (${ms}ms): ${result.length > 80 ? result.substring(0, 80) : result}',
          tag: 'ApiTest');
      // v1.6.8 修复 Bug#15：await 后 setState 必须检查 mounted（同文件 _refreshModels 已做，
      // _testConnection 三处漏检：try 成功 / catch 失败 / finally 重置）
      if (!mounted) return;
      setState(() {
        _testResult = '${l.tr('connectionOk')} (${ms}ms)';
        _testSuccess = true;
      });
    } catch (e, st) {
      logger.error('Test connection failed',
          error: e, stack: st, tag: 'ApiTest');
      if (!mounted) return;
      setState(() {
        _testResult = '${l.tr('connectionFailed')} : $e';
        _testSuccess = false;
      });
    } finally {
      if (mounted) setState(() => _isTesting = false);
    }
  }

  /// 选择服务商模板
  /// v1.5.4 变更：API Key 按 baseUrl 分桶缓存（DeepSeek Key / 阿里云 Key 各自独立）。
  /// 切换前先把当前 Key 存回旧服务商桶，切换后恢复新服务商的 Key（没有就空）。
  /// 模型列表同样按 baseUrl 恢复。
  Future<void> _applyTemplate(ApiProviderTemplate? t) async {
    if (t == null) {
      // build101 (EP1)：点「自定义」时清空上一个模板的残留。
      // 旧行为（v1.5.4 起）故意不覆盖用户输入，导致：从 DeepSeek 点自定义后，
      // 名称/Base URL/模型仍是 DeepSeek 的，用户以为已清空 → 保存后 templateId
      // 被 _guessTemplateFromExisting 猜回 ollama/lmstudio（EP2），分组显示错乱。
      // 新口径：清空 name/baseUrl/model + 各自的分桶缓存指针，让用户从空白开始填。
      // API Key 不清——按 baseUrl 分桶，清空 URL 后 Key 会被回填到 '' 桶，切回原服务商仍能恢复。
      setState(() {
        final oldBaseUrl = _baseUrlController.text.trim();
        if (oldBaseUrl.isNotEmpty) {
          _apiKeysByUrl[oldBaseUrl] = _apiKeyController.text;
        }
        _selectedTemplateId = ApiProviderTemplate.customId;
        _nameController.clear();
        _baseUrlController.clear();
        _modelController.clear();
        _selectedModelId = '';
        _apiKeyController.clear();
        _cachedModels = const [];
        _refreshModelsMsg = '';
        _visionManuallyOverridden = false;
        _supportVision = false;
        _toolCallsManuallyOverridden = false;
        _supportToolCalls = false;
      });
      return;
    }
    setState(() {
      // 切换前：把当前填的 Key 存回旧服务商桶（防止 DeepSeek Key 串到阿里云）
      final oldBaseUrl = _baseUrlController.text.trim();
      if (oldBaseUrl.isNotEmpty) {
        _apiKeysByUrl[oldBaseUrl] = _apiKeyController.text;
      }

      _selectedTemplateId = t.id;
      // 名称/Base URL/Model 都从模板来（每次切换都覆盖，避免残留上一个模板的 model id）
      _nameController.text = t.defaultConfigName;
      _baseUrlController.text = t.baseUrl;
      final recId = t.recommendedModelId;
      _modelController.text = recId;
      _selectedModelId = recId;
      _visionManuallyOverridden = false;
      _supportVision =
          ModelCapabilityMemory.resolveVisionSync(recId, _visionMemory);
      // v1.5.4：恢复新服务商的 Key（没有就空），每个服务商 Key 独立
      _apiKeyController.text = _apiKeysByUrl[t.baseUrl] ?? '';
      // v1.5.3：从缓存 Map 恢复该服务商的模型列表（不串台、不丢失）。
      // baseUrl 为空（本地模型 Ollama/LM Studio）时返回空列表，等用户填 IP 再刷新。
      _cachedModels = _modelsByUrl[t.baseUrl] ?? const [];
      _refreshModelsMsg = '';
    });
  }

  /// v1.5.2：已删除。原来切换服务商前弹窗问"保留还是清空 Key"，
  /// 用户反馈"不要每次切换"，改为强制保留 Key（不清空、不弹窗）。
  /// 保留此方法会造成 unused 警告，故一并删除。

  /// 在模板内切换模型版本
  void _selectModel(ModelOption m) {
    setState(() {
      _selectedModelId = m.id;
      _modelController.text = m.id;
      _visionManuallyOverridden = false;
      _supportVision =
          ModelCapabilityMemory.resolveVisionSync(m.id, _visionMemory);
      _toolCallsManuallyOverridden = false;
      _supportToolCalls = ApiConfig.detectToolCallsSupport(m.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final isZh = l.locale.languageCode == 'zh';

    // build139（真机反馈②「编辑 API 页都靠左」）：这一页是设置区里唯一没上
    // AppSectionCard 的页面——一整列控件贴着左边灌到底，宽屏（平板 / 桌面窗口）
    // 上输入框一路拉到 1200dp，右边全是空白。
    // 本次只「装箱 + 限宽 + 保存落到常驻底栏」，字段、校验、handler 原样不动。
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.config == null
            ? l.tr('addApiConfig')
            : l.tr('editApiConfig')),
      ),
      // build139 自查②：底栏**不放**在 Scaffold 的底部导航槽位上。
      // 那个槽位是按 `bottom = size.height` 定位的，不参与键盘避让——Scaffold
      // 只把 body 按 viewInsets 收缩（见其 _ScaffoldLayout.performLayout）。
      // 放那里会出现「一打字保存就没」：在 Base URL / Key 里唤起键盘后，
      // 整条底栏沉到键盘下面，必须按返回收键盘才点得到。
      // 改放 body 末尾（body 会被键盘顶起）⇒ 键盘弹起时底栏跟着上移，常驻可见。
      body: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.2,
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: kFormMaxWidth),
                  child: Form(
                    key: _formKey,
                    child: ListView(
                      padding: AppPad.page,
                      children: [
                        // ================ Template Selector ================
                        ..._group(l.tr('selectTemplate'), [
                          Text(l.tr('selectTemplateSubtitle'),
                              style: Theme.of(context).textTheme.bodySmall),
                          const SizedBox(height: 12),
                          ..._buildGroupChips(isZh),
                          const SizedBox(height: 4),
                          if (_selectedTemplateId !=
                              ApiProviderTemplate.customId)
                            _templateInfoHint(isZh),
                        ]),

                        // ================ 模型版本切换器（选了非自定义模板才显示）================
                        if (_selectedTemplateId != ApiProviderTemplate.customId)
                          ..._group(isZh ? '模型版本' : 'Model version',
                              [_buildModelVersionSelector(isZh)]),

                        // ================ 连接配置 ================
                        ..._group(isZh ? '连接配置' : 'Connection', [
                          TextFormField(
                            controller: _nameController,
                            decoration: InputDecoration(
                              labelText: l.tr('configName'),
                              hintText: 'OpenAI / DeepSeek',
                              border: const OutlineInputBorder(),
                            ),
                            validator: (v) =>
                                (v == null || v.isEmpty) ? '*' : null,
                          ),
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _baseUrlController,
                            decoration: InputDecoration(
                              labelText: l.tr('baseUrl'),
                              hintText: 'https://api.openai.com/v1',
                              helperText: (_selectedTemplateId == 'ollama' ||
                                      _selectedTemplateId == 'lmstudio')
                                  ? (isZh
                                      ? '⚠️ 手机端请填电脑局域网 IP，如 http://192.168.1.100:11434/v1\n（不能用 localhost，localhost 在手机上指手机本身，连不到电脑的本地模型服务）'
                                      : '⚠️ On phone use PC LAN IP, e.g. http://192.168.1.100:11434/v1\n(localhost on phone means phone itself, cannot reach PC local model)')
                                  // build138（A 批）：协议要在设置页**看得见**。判定与请求侧
                                  // 共用 kNativeProtocols 一张表 —— 两处各写一份就会出现
                                  // 「这里显示 OpenAI 格式、实际却打 /v1/messages」这种谎。
                                  : _isAnthropicNative
                                      ? (isZh
                                          ? '本配置走 Anthropic Messages 原生协议：POST …/v1/messages（按所选服务商自动判定）'
                                          : 'Uses the native Anthropic Messages protocol: POST .../v1/messages (auto-detected by provider)')
                                      : null,
                              border: const OutlineInputBorder(),
                            ),
                            validator: (v) =>
                                (v == null || v.isEmpty) ? '*' : null,
                          ),
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _apiKeyController,
                            decoration: InputDecoration(
                              labelText: l.tr('apiKey'),
                              hintText: 'sk-...',
                              border: const OutlineInputBorder(),
                              suffixIcon: _selectedTemplateId !=
                                      ApiProviderTemplate.customId
                                  ? Icon(Icons.check_circle,
                                      color:
                                          Theme.of(context).colorScheme.primary,
                                      size: 20)
                                  : null,
                            ),
                            obscureText: true,
                            validator: (v) {
                              // Local Ollama / LM Studio 可以不填 Key
                              if (_selectedTemplateId == 'ollama' ||
                                  _selectedTemplateId == 'lmstudio') {
                                return null;
                              }
                              return (v == null || v.isEmpty) ? '*' : null;
                            },
                          ),
                          const SizedBox(height: 16),
                        ]),

                        // ================ 模型与提示词 ================
                        ..._group(isZh ? '模型与提示词' : 'Model & prompt', [
                          // v1.7.18（需求3）：模型输入/刷新/缓存下拉抽独立方法降 CC
                          ..._buildModelInputSection(isZh, l),
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _systemPromptController,
                            decoration: InputDecoration(
                              labelText: l.tr('systemPrompt'),
                              hintText: 'You are a helpful assistant...',
                              border: const OutlineInputBorder(),
                            ),
                            maxLines: 3,
                          ),
                        ]),

                        // ================ 能力开关 ================
                        ..._group(isZh ? '能力开关' : 'Capabilities', [
                          // v1.7.33：视觉支持开关——关闭后图片附件不发给模型，改用本机 OCR 把文字注入上下文
                          SwitchListTile(
                            title: Text(isZh
                                ? '视觉支持（图片理解）'
                                : 'Vision support (image understanding)'),
                            subtitle: Text(
                              isZh
                                  ? '关闭后，图片附件改为在本机用 OCR 识别文字并注入上下文；适合不支持图片的文本模型'
                                  : 'When off, images are OCR-ed locally into text instead of being sent to the model; good for text-only models',
                              style: const TextStyle(fontSize: 11),
                            ),
                            dense: true,
                            value: _supportVision,
                            onChanged: (v) => setState(() {
                              _supportVision = v;
                              _visionManuallyOverridden = true;
                            }),
                          ),
                          // build93 (T1)：工具调用（function calling）开关——开启后 ReAct 动作走原生
                          // tools 硬约束通道；带 tools 请求被 400/422 拒绝时会自动关闭并记住
                          SwitchListTile(
                            title: Text(isZh
                                ? '工具调用（Function Calling）'
                                : 'Tool calls (function calling)'),
                            subtitle: Text(
                              isZh
                                  ? '开启后自主思考的动作（搜索/反问/待办/记忆等）走结构化工具通道；模型不支持时会自动降级回标签模式'
                                  : 'When on, agent actions (search/ask/todo/memory) use structured tool calls; auto-falls back to tag mode if the model rejects tools',
                              style: const TextStyle(fontSize: 11),
                            ),
                            dense: true,
                            value: _supportToolCalls,
                            onChanged: (v) => setState(() {
                              _supportToolCalls = v;
                              _toolCallsManuallyOverridden = true;
                            }),
                          ),
                          // build123：图片生成能力位——走 {baseUrl}/v1/images/generations。
                          // 为什么是「手动开关」而不是自动探测：生成端点在部分中转站存在但模型不支持，
                          // 探测会误判；而默认关闭的代价只是「用户没开」，默认打开的代价是
                          // 「用户在聊天里让 AI 画图，结果收到一个 404 报错」。
                          SwitchListTile(
                            title:
                                Text(isZh ? '图片生成（文生图）' : 'Image generation'),
                            subtitle: Text(
                              isZh
                                  ? '开启后可用「AI 绘图」页与聊天内绘图；调用 /v1/images/generations，按张计费（需服务商支持，如 gpt-image / 即梦 / flux）'
                                  : 'Enables the AI Drawing page and in-chat drawing via /v1/images/generations (billed per image; provider must support it)',
                              style: const TextStyle(fontSize: 11),
                            ),
                            dense: true,
                            value: _supportImageGen,
                            onChanged: (v) =>
                                setState(() => _supportImageGen = v),
                          ),
                          // build125：开启图片生成后，直接给出「文生图模型」输入框。
                          // 这是真机日志 nexus_export_2026-09-17T22-09 的直接修复点：该用户把对话
                          // 模型设成 grok-4.6，聊天里让 AI 画图 → 4 次全 400（同一 key 的 chat
                          // 端点是 200），此前 App 内**没有任何地方**能指定生图模型。
                          if (_supportImageGen) _buildImageModelField(isZh),
                          // build123：视频生成能力位——走 /v1/videos 异步任务 + 轮询。
                          // 按秒计费，且上游结果链接只有 24 小时有效，默认关闭更安全。
                          SwitchListTile(
                            title:
                                Text(isZh ? '视频生成（文生视频）' : 'Video generation'),
                            subtitle: Text(
                              isZh
                                  ? '开启后可用「AI 视频」页与聊天内生成视频；异步任务，按秒计费（需服务商支持，如可灵 / 即梦 / Vidu）'
                                  : 'Enables the AI Video page and in-chat video generation (async task, billed per second; provider must support it)',
                              style: const TextStyle(fontSize: 11),
                            ),
                            dense: true,
                            value: _supportVideoGen,
                            onChanged: (v) =>
                                setState(() => _supportVideoGen = v),
                          ),
                          // build129：开启视频生成后，直接给出「文生视频模型」输入框（与图片侧同构）。
                          // 这是真机日志 nexus_export_2026-09-19T10-05 的直接修复点：该用户拿对话
                          // 模型 grok-4.6 打 /v1/videos → 400「Use grok-imagine-video」，App 内
                          // **没有任何地方**能指定视频模型。
                          if (_supportVideoGen) _buildVideoModelField(isZh),
                        ]),

                        // ================ 上下文与输出长度 ================
                        // v1.7.25：温度改为每对话自定义（对话设置面板可调），API 配置不再暴露温度
                        ..._group(
                            isZh ? '上下文与输出长度' : 'Context & output length', [
                          TextFormField(
                            controller: _contextWindowController,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: isZh
                                  ? '上下文窗口（tokens）'
                                  : 'Context window (tokens)',
                              helperText: isZh
                                  ? '留空使用默认值 200000'
                                  : 'Leave empty to use the default 200000',
                              border: const OutlineInputBorder(),
                            ),
                            validator: (value) {
                              if (value == null || value.trim().isEmpty) {
                                return null;
                              }
                              final parsed = int.tryParse(value.trim());
                              return parsed == null || parsed <= 0
                                  ? (isZh
                                      ? '请输入正整数'
                                      : 'Enter a positive integer')
                                  : null;
                            },
                          ),
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _maxTokensController,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: l.tr('maxTokens'),
                              helperText: isZh
                                  ? '留空使用默认值 2048'
                                  : 'Leave empty to use the default 2048',
                              border: const OutlineInputBorder(),
                            ),
                            validator: (value) {
                              if (value == null || value.trim().isEmpty) {
                                return null;
                              }
                              final parsed = int.tryParse(value.trim());
                              return parsed == null || parsed <= 0
                                  ? (isZh
                                      ? '请输入正整数'
                                      : 'Enter a positive integer')
                                  : null;
                            },
                          ),
                        ]),

                        // ================ 连通性测试 ================
                        ..._group(l.tr('testConnection'), [
                          // v1.7.18（需求3）：测试连接按钮 + 结果抽独立方法降 CC
                          ..._buildTestSection(l),
                        ]),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // 底栏与表单同宽同列：否则宽屏上表单是 680 的居中列，底下两个按钮
            // 却被各自 Expanded 拉到 ~600dp —— 与本次要治的"过宽"是同一个毛病。
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: kFormMaxWidth),
                child: _buildSaveBar(l),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// build139（真机反馈②）：把既有控件原样装进设置页统一的分组卡片。
  ///
  /// 只提供「标题 + 内边距」这层壳，不碰任何字段行为；组间距由
  /// [AppSectionCard] 自带的下边距负责，所以装箱时把原先散在字段之间的
  /// `Divider` / 尾随 `SizedBox` 一并去掉（否则分组卡片和分隔线会变成两套
  /// 互相矛盾的分组语言）。
  List<Widget> _group(String title, List<Widget> rows) => [
        AppSectionCard(
          title: title,
          children: [
            Padding(
              padding:
                  const EdgeInsets.fromLTRB(AppGap.md, 0, AppGap.md, AppGap.md),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: rows,
              ),
            ),
          ],
        ),
      ];

  /// build139（真机反馈②）：保存 / 取消常驻底栏（挂在 body 末尾，见 build 里的说明）。
  ///
  /// 改前的保存入口有两个：AppBar 右上角一个裸勾（没人猜得到是保存），
  /// 以及列表最末尾一个通栏按钮（这一页改完有 700+dp 高，点保存要先滚到底）。
  /// 收成一条底栏：左「取消」右「保存」，改完不用滚。
  Widget _buildSaveBar(AppLocalizations l) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(
            AppGap.lg, AppGap.sm, AppGap.lg, AppGap.sm),
        decoration: BoxDecoration(
          color: cs.surface,
          border: Border(top: BorderSide(color: cs.appBorder)),
        ),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: Text(l.tr('cancel')),
              ),
            ),
            const SizedBox(width: AppGap.md),
            Expanded(
              child: FilledButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.save_outlined, size: 18),
                label: Text(l.tr('save')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- v1.7.18（需求3）：build 子段（降 CC）----------

  /// 模型输入框 + 刷新按钮 + 刷新结果提示 + 缓存下拉（custom 兜底）
  List<Widget> _buildModelInputSection(bool isZh, AppLocalizations l) {
    return [
      // v1.5.0：模型输入框 + 「🔄 刷新模型列表」按钮
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextFormField(
              controller: _modelController,
              decoration: InputDecoration(
                labelText: l.tr('model'),
                hintText: 'gpt-4o-mini',
                helperText: _selectedTemplateId != ApiProviderTemplate.customId
                    ? (isZh
                        ? '已通过上方切换器填好，可手动覆盖'
                        : 'Auto-filled by selector above; editable')
                    : null,
                border: const OutlineInputBorder(),
              ),
              onChanged: (value) {
                _selectedModelId = value.trim();
                if (!_visionManuallyOverridden) {
                  setState(() {
                    _supportVision = ModelCapabilityMemory.resolveVisionSync(
                        value, _visionMemory);
                  });
                }
                if (!_toolCallsManuallyOverridden) {
                  setState(() {
                    _supportToolCalls = ApiConfig.detectToolCallsSupport(value);
                  });
                }
              },
              validator: (v) => (v == null || v.isEmpty) ? '*' : null,
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.tonalIcon(
            onPressed: _isRefreshingModels ? null : _refreshModels,
            icon: _isRefreshingModels
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            label: Text(isZh ? '在线刷新' : 'Refresh Online'),
          ),
        ],
      ),
      if (_refreshModelsMsg.isNotEmpty) ...[
        const SizedBox(height: 6),
        Text(
          _refreshModelsMsg,
          style: TextStyle(
            fontSize: 12,
            color: _refreshModelsMsg.startsWith('✅')
                ? Theme.of(context).colorScheme.primary
                : (_refreshModelsMsg.startsWith('⚠️') ||
                        _refreshModelsMsg.startsWith('❌')
                    ? Theme.of(context).colorScheme.error
                    : Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
      ],
      // v1.5.1：custom 模板兜底显示缓存模型下拉
      if (_cachedModels.isNotEmpty &&
          _selectedTemplateId == ApiProviderTemplate.customId) ...[
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          initialValue: _cachedModels.contains(_modelController.text.trim())
              ? _modelController.text.trim()
              : null,
          decoration: InputDecoration(
            labelText: isZh ? '已缓存模型（点击切换）' : 'Cached models (tap to switch)',
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          items: _cachedModels
              .map((id) => DropdownMenuItem(
                    value: id,
                    child: Text(id, style: const TextStyle(fontSize: 13)),
                  ))
              .toList(),
          onChanged: (v) {
            if (v != null) {
              setState(() {
                _modelController.text = v;
                _selectedModelId = v;
              });
            }
          },
        ),
      ],
    ];
  }

  /// 测试连接按钮 + 结果提示框
  List<Widget> _buildTestSection(AppLocalizations l) {
    return [
      FilledButton.tonalIcon(
        onPressed: _isTesting ? null : _testConnection,
        icon: _isTesting
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.wifi_tethering),
        label: Text(l.tr('testConnection')),
      ),
      if (_testResult.isNotEmpty) ...[
        const SizedBox(height: 12),
        Builder(builder: (context) {
          final cs = Theme.of(context).colorScheme;
          return Container(
            padding: AppPad.card,
            decoration: BoxDecoration(
              color: cs.appPanelLight,
              borderRadius: BorderRadius.circular(AppRadius.panel),
              border: Border.all(color: cs.appBorder),
            ),
            child: Text(
              _testResult,
              style: TextStyle(
                color: _testSuccess ? cs.primary : cs.error,
              ),
            ),
          );
        }),
      ],
    ];
  }

  // ---------- 模型版本切换器 ----------
  /// build125：文生图**专用**模型输入框（仅在开启「图片生成」能力后显示）。
  ///
  /// build126 改口径：从「可选」改为**必填**——留空不是「回落对话模型还能用」，
  /// 而是「拿对话模型去打 /v1/images/generations」→ 上游**必然 400**
  /// （真机实证：对话模型 grok-4.6 打生图端点，15 分钟内 4 次 400 全失败）。
  /// 同时把「填入」的门槛降到零：①已拉取的模型列表；②上游 400 正文里点名的
  /// 可用模型（[ImageGenService.lastUpstreamSuggestedModels]）优先排在最前。
  Widget _buildImageModelField(bool isZh) {
    final cs = Theme.of(context).colorScheme;
    final upstream = ImageGenService.lastUpstreamSuggestedModels;
    // 没拉取过模型列表时给一份常见图像模型兜底（比让用户凭空手输强）
    final fallback = _cachedModels.isNotEmpty
        ? _cachedModels
        : const <String>[
            'gpt-image-1',
            'dall-e-3',
            'grok-imagine-image',
            'flux-schnell',
            'doubao-seedream',
          ];
    final picks = <String>[
      ...upstream,
      ...fallback.where((m) => !upstream.contains(m)),
    ];
    return Padding(
      padding: const EdgeInsets.only(left: 4, right: 4, bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextFormField(
            controller: _imageModelController,
            decoration: InputDecoration(
              labelText: isZh ? '文生图模型（开启图片生成后必填）' : 'Image model (required)',
              hintText: 'gpt-image-1 / dall-e-3 / grok-imagine-image',
              isDense: true,
              helperMaxLines: 3,
              helperText: isZh
                  ? '必须填一个**图像**模型名（对话模型不能生图）。留空 = 拿上面的对话模型去打生图端点 → 必然报 400。'
                  : 'Must be an IMAGE model. Empty = the chat model hits the image endpoint and fails with 400.',
              suffixIcon: PopupMenuButton<String>(
                tooltip: isZh
                    ? (_cachedModels.isEmpty
                        ? '常见图像模型（点"测试连接"可拉取真实列表）'
                        : '从已获取的模型列表选择')
                    : 'Pick an image model',
                icon: const Icon(Icons.list_alt, size: 20),
                onSelected: (v) =>
                    setState(() => _imageModelController.text = v),
                itemBuilder: (_) => picks
                    .map((m) => PopupMenuItem<String>(
                          value: m,
                          child: Text(m, style: const TextStyle(fontSize: 13)),
                        ))
                    .toList(growable: false),
              ),
            ),
          ),
          // build126：留空红字警示（实时跟随输入框内容，不需要额外监听）
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _imageModelController,
            builder: (_, v, __) {
              if (v.text.trim().isNotEmpty) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 4, left: 12, right: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.error_outline, size: 14, color: cs.error),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        isZh
                            ? '留空 = 生图必然失败（400）。请从右侧列表挑一个，或填中转站文档里的图像模型名。'
                            : 'Empty = image generation will fail (400). Pick one from the list.',
                        style: TextStyle(fontSize: 11.5, color: cs.error),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          if (upstream.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 12, right: 12),
              child: Text(
                isZh
                    ? '上次上游提示可用模型：${upstream.join(' / ')}'
                    : 'Upstream suggested: ${upstream.join(' / ')}',
                style: TextStyle(fontSize: 11.5, color: cs.primary),
              ),
            ),
        ],
      ),
    );
  }

  /// build129：文生视频**专用**模型输入框（仅在开启「视频生成」能力后显示）。
  ///
  /// 与 `_buildImageModelField` **逐块同构**——两处必须一起改，理由写在
  /// `ApiConfig.effectiveVideoModel` 的注释里：本项目已经吃过一次「同一个坑只补一半」
  /// 的亏（build125 只补了图片，视频拖到 build129 才补，期间每次生成都是 400）。
  /// 视频比图片更该拦：图片错一次只损失几秒，视频错一次要白等 1~5 分钟。
  Widget _buildVideoModelField(bool isZh) {
    final cs = Theme.of(context).colorScheme;
    final upstream = VideoGenService.lastUpstreamSuggestedVideoModels;
    // 没拉取过模型列表时给一份常见视频模型兜底（比让用户凭空手输强）
    final fallback = _cachedModels.isNotEmpty
        ? _cachedModels
        : const <String>[
            'grok-imagine-video',
            'kling-video-o1',
            'sora-2',
            'veo-3',
            'doubao-seedance',
          ];
    final picks = <String>[
      ...upstream,
      ...fallback.where((m) => !upstream.contains(m)),
    ];
    return Padding(
      padding: const EdgeInsets.only(left: 4, right: 4, bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextFormField(
            controller: _videoModelController,
            decoration: InputDecoration(
              labelText: isZh ? '文生视频模型（开启视频生成后必填）' : 'Video model (required)',
              hintText: 'grok-imagine-video / kling-video-o1 / sora-2',
              isDense: true,
              helperMaxLines: 3,
              helperText: isZh
                  ? '必须填一个**视频**模型名（对话模型不能生视频）。留空 = 拿上面的对话模型去打视频端点 → 必然报 400。'
                  : 'Must be a VIDEO model. Empty = the chat model hits the video endpoint and fails with 400.',
              suffixIcon: PopupMenuButton<String>(
                tooltip: isZh
                    ? (_cachedModels.isEmpty
                        ? '常见视频模型（点"测试连接"可拉取真实列表）'
                        : '从已获取的模型列表选择')
                    : 'Pick a video model',
                icon: const Icon(Icons.list_alt, size: 20),
                onSelected: (v) =>
                    setState(() => _videoModelController.text = v),
                itemBuilder: (_) => picks
                    .map((m) => PopupMenuItem<String>(
                          value: m,
                          child: Text(m, style: const TextStyle(fontSize: 13)),
                        ))
                    .toList(growable: false),
              ),
            ),
          ),
          // 与图片侧同构：留空红字警示（实时跟随输入框内容）
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _videoModelController,
            builder: (_, v, __) {
              if (v.text.trim().isNotEmpty) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 4, left: 12, right: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.error_outline, size: 14, color: cs.error),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        isZh
                            ? '留空 = 视频必然失败（400）。请从右侧列表挑一个，或填中转站文档里的视频模型名。'
                            : 'Empty = video generation will fail (400). Pick one from the list.',
                        style: TextStyle(fontSize: 11.5, color: cs.error),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          if (upstream.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 12, right: 12),
              child: Text(
                isZh
                    ? '上次上游提示可用模型：${upstream.join(' / ')}'
                    : 'Upstream suggested: ${upstream.join(' / ')}',
                style: TextStyle(fontSize: 11.5, color: cs.primary),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildModelVersionSelector(bool isZh) {
    final cs = Theme.of(context).colorScheme;
    // B-016：陈旧 templateId（模板改名/删除/备份带入）时 firstWhere 会抛
    // StateError，异常发生在 build 阶段 → 整个编辑页红屏，用户连表单都进不去、
    // 无法自救。改为 firstOrNull + 空值回退（等同「自定义」表单语义）。
    final t = ApiProviderTemplateCatalog.instance.all
        .where((e) => e.id == _selectedTemplateId)
        .firstOrNull;
    if (t == null) return const SizedBox.shrink();
    if (t.models.isEmpty) {
      // 没有多个版本（比如 LM Studio），就只显示一个"单一模型"提示
      return Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: t.color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(children: [
          Icon(Icons.memory, color: t.color, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              isZh
                  ? '此服务商仅单一模型：${t.defaultModel}'
                  : 'Single model: ${t.defaultModel}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ]),
      );
    }
    // v1.5.1：把动态拉取的模型（_cachedModels）和模板预设模型合并显示。
    // - 预设模型用 ⭐ 图标（t.models，来自模板硬编码）
    // - 在线模型用 ☁️ 图标（_cachedModels，点🔄刷新拉取）
    // 两组独立显示，中间有分隔标题。在线模型若和预设同名则去重（不重复显示）。
    final presetIds = t.models.map((m) => m.id).toSet();
    final onlineOnly = _cachedModels
        .where((id) => !presetIds.contains(id))
        .toList(growable: false);
    final hasOnline = onlineOnly.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Icon(Icons.memory, color: t.color, size: 18),
          const SizedBox(width: 6),
          Text(isZh ? '选择模型版本' : 'Choose Model Version',
              style: Theme.of(context).textTheme.titleMedium),
        ]),
        const SizedBox(height: 4),
        Text(isZh ? '点一下即可切换，无需手动输入' : 'Tap to switch, no typing needed',
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 10),
        // ===== 组 1：⭐ 推荐（模板预设模型）=====
        if (t.models.isNotEmpty) ...[
          _buildSectionLabel(isZh ? '⭐ 推荐' : '⭐ Recommended', t.color),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: t.models.map((m) {
              final selected = _selectedModelId == m.id;
              return FilterChip(
                selected: selected,
                showCheckmark: false,
                avatar: m.recommended
                    ? Icon(Icons.star, size: 14, color: t.color)
                    : null,
                onSelected: (_) => _selectModel(m),
                label: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(m.displayName(isZh)),
                    if (m.isFreeModel) ...[
                      const SizedBox(width: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: cs.appPanel,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: cs.appBorder),
                        ),
                        child: Text(
                          isZh ? '免费' : 'FREE',
                          style: TextStyle(
                            color: cs.appTextSub,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                    if (m.note(isZh) != null && m.note(isZh)!.isNotEmpty) ...[
                      const SizedBox(width: 4),
                      Text(
                        m.note(isZh)!,
                        style: TextStyle(
                          fontSize: 10,
                          color: t.color.withValues(alpha: 0.9),
                        ),
                      ),
                    ],
                  ],
                ),
              );
            }).toList(),
          ),
        ],
        // ===== 组 2：☁️ 在线拉取（动态模型）=====
        if (hasOnline) ...[
          const SizedBox(height: 10),
          _buildSectionLabel(isZh ? '已缓存（离线可用）' : 'Cached (available offline)',
              Theme.of(context).colorScheme.primary),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: onlineOnly.map((id) {
              final selected =
                  _selectedModelId == id || _modelController.text.trim() == id;
              return FilterChip(
                selected: selected,
                showCheckmark: false,
                avatar: Icon(Icons.cloud_outlined,
                    size: 14, color: cs.onSurfaceVariant),
                onSelected: (_) {
                  setState(() {
                    _selectedModelId = id;
                    _modelController.text = id;
                    _visionManuallyOverridden = false;
                    _supportVision = ModelCapabilityMemory.resolveVisionSync(
                        id, _visionMemory);
                    _toolCallsManuallyOverridden = false;
                    _supportToolCalls = ApiConfig.detectToolCallsSupport(id);
                  });
                },
                label: Text(id, style: const TextStyle(fontSize: 13)),
              );
            }).toList(),
          ),
        ],
      ],
    );
  }

  /// v1.5.1：模型分组的小标签（⭐推荐 / ☁️在线）
  Widget _buildSectionLabel(String text, Color color) {
    return Row(
      children: [
        Container(
          width: 3,
          height: 14,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 6),
        Text(text,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            )),
      ],
    );
  }

  // ---------- Template group builders ----------
  List<Widget> _buildGroupChips(bool isZh) {
    const groups = [
      (ApiProviderGroup.domestic, '国内服务商 / Domestic'),
      (ApiProviderGroup.international, '国际服务商 / International'),
      (ApiProviderGroup.local, '本地模型 / Local (no Key)'),
    ];
    final List<Widget> out = [];
    for (final (g, title) in groups) {
      final templates = ApiProviderTemplateCatalog.instance.byGroup(g);
      final displayTitle = isZh
          ? title.split(' / ').first.trim()
          : title.split(' / ').last.trim();
      out.add(Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 2),
        child: Text('• $displayTitle',
            style: Theme.of(context)
                .textTheme
                .labelMedium
                ?.copyWith(color: Theme.of(context).colorScheme.appTextSub)),
      ));
      out.add(SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            ...templates.map((t) => Padding(
                  padding: const EdgeInsets.only(right: 6, bottom: 6),
                  child: _buildTemplateChip(t, isZh),
                )),
            // Custom "clear" chip 放在每个组末尾（任意一组都能点）
            if (g == ApiProviderGroup.domestic)
              Padding(
                padding: const EdgeInsets.only(right: 6, bottom: 6),
                child: _buildCustomChip(isZh),
              ),
          ],
        ),
      ));
    }
    return out;
  }

  Widget _buildTemplateChip(ApiProviderTemplate t, bool isZh) {
    final selected = _selectedTemplateId == t.id;
    final name = isZh ? t.nameZh : t.nameEn;
    return FilterChip(
      selected: selected,
      showCheckmark: false,
      onSelected: (_) {
        _applyTemplate(t);
      },
      avatar: VendorAvatar(templateId: t.id, size: 16),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(name),
          if (t.hasFreeTier) ...[
            const SizedBox(width: 4),
            Tooltip(
              message: isZh
                  ? (t.freeDetailZh.isEmpty
                      ? '提供永久可循环使用的免费 API 层'
                      : t.freeDetailZh)
                  : (t.freeDetailEn.isEmpty
                      ? 'Offers a permanently renewable free API tier'
                      : t.freeDetailEn),
              preferBelow: false,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.appPanelLight,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                      color: Theme.of(context).colorScheme.appBorder),
                ),
                child: Text(
                  isZh ? '部分免费' : 'PARTIAL FREE',
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.appTextSub,
                      fontSize: 10,
                      fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCustomChip(bool isZh) {
    final selected = _selectedTemplateId == ApiProviderTemplate.customId;
    return FilterChip(
      selected: selected,
      showCheckmark: false,
      onSelected: (_) {
        _applyTemplate(null);
      },
      avatar: const Icon(Icons.edit, size: 14),
      label: Text(isZh ? '自定义' : 'Custom'),
    );
  }

  Widget _templateInfoHint(bool isZh) {
    final cs = Theme.of(context).colorScheme;
    // B-016：同 _buildModelVersionSelector，陈旧 templateId 不得让页面红屏
    final t = ApiProviderTemplateCatalog.instance.all
        .where((e) => e.id == _selectedTemplateId)
        .firstOrNull;
    if (t == null) return const SizedBox.shrink();
    final desc = isZh ? t.descZh : t.descEn;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: t.color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: t.color.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, color: t.color, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  desc.isEmpty
                      ? (isZh
                          ? '已自动填入默认 Base URL 与推荐模型'
                          : 'Auto-filled Base URL & default model')
                      : '${isZh ? '说明：' : 'Note: '}$desc',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                ),
              ),
            ],
          ),
          // v1.5.2：官网链接（点击跳转去注册账号 / 查 API Key）
          if (t.officialUrl.isNotEmpty) ...[
            const SizedBox(height: 8),
            InkWell(
              onTap: () => _openUrl(t.officialUrl),
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.open_in_new, size: 14, color: cs.primary),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        isZh
                            ? '访问官网（注册 / 查 API Key）'
                            : 'Official site (signup / API key)',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: cs.primary,
                          fontWeight: FontWeight.w600,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// v1.5.2：用系统浏览器打开官网链接
  Future<void> _openUrl(String url) async {
    // v1.7.18（需求3/4）：改用公共 LauncherUtils.openExternalUrl 去重
    await LauncherUtils.openExternalUrl(url);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    _modelController.dispose();
    _imageModelController.dispose();
    _videoModelController.dispose();
    _systemPromptController.dispose();
    _maxTokensController.dispose();
    _contextWindowController.dispose();
    super.dispose();
  }
}
