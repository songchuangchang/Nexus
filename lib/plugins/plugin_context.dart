import 'package:flutter/material.dart';
import '../models/chat_message.dart';
import '../models/web_search_config.dart';
import '../models/api_config.dart';
import '../services/storage_service.dart';
import '../services/web_search_service.dart';
import '../services/app_download_service.dart';
import '../services/logger_service.dart';
import '../utils/app_snackbar.dart';

class PluginContext {
  final List<ChatMessage> workingMessages;
  final StringBuffer answerBuffer;
  bool answered;
  bool mounted;
  final WebSearchConfig webSearchCfg;
  final ApiConfig? conversationApiConfig;
  final ChatMessage? userMsg;
  final ChatMessage assistantMsg;
  final String? rawResp;
  int totalSearchHits = 0;

  /// build125：内置「生成类」插件的**本消息**连续失败计数（key = triggerType）。
  ///
  /// 为什么需要它：MCP 侧已有 N6 熔断（`plugin_registry._mcpFailStreaks`），但内置
  /// 插件的失败是**插件自己 catch 后回灌 toolresult**（不抛异常）→ 宿主根本看不见，
  /// 于是模型能对着一个注定失败的工具反复重试。真机日志实锤：image_gen 连续 4 次
  /// 400（每次换 prompt → E5 的「动作+参数指纹」各不相同，永不熔断），21:36 一直
  /// 空转到 21:51 用户放弃。计数挂在 PluginContext 上 = 天然按「一条用户消息」作用域，
  /// 不需要额外的复位钩子，也不会跨会话串味。
  final Map<String, int> _genFailStreaks = {};

  /// 记一次生成失败，返回该工具在本消息内的**累计**失败次数。
  int noteGenFailure(String tool) {
    final n = (_genFailStreaks[tool] ?? 0) + 1;
    _genFailStreaks[tool] = n;
    return n;
  }

  /// 生成成功即清零（「失败 1 次 + 成功」不应被算作连续失败）。
  void clearGenFailure(String tool) => _genFailStreaks.remove(tool);

  /// 该生成类工具是否已熔断（默认阈值 2：一次失败可能是偶发，两次判不可用）。
  bool isGenCircuitOpen(String tool, {int threshold = 2}) =>
      (_genFailStreaks[tool] ?? 0) >= threshold;

  /// build101（C3 深度阅读）：本会话当前思考强度（0.0~1.0）。
  /// 插件据此决定是否额外抓取网页正文（≥0.8 视为深度档）。
  final double currentReasoningEffort;
  final StorageService? _storage;
  final WebSearchService? _webSearch;
  final AppDownloadService? _appDownload;
  final LoggerService? _logger;
  final BuildContext? _rootContext;
  final VoidCallback? _onRequestStop;
  final void Function(String text)? _onAppendReasoning;
  final void Function(String text)? _onAppendUserMessage;
  final void Function(String text,
      {int injectedWebSearchCount, bool forceSave})? _onFinalizeAnswer;
  final void Function(VoidCallback fn)? _onSetState;
  /// build129：**`force` 必须走独立形参**。
  ///
  /// 旧实现把「强制保存」编码成魔数塞进 count（`cb(force ? 999999999 : …)`），
  /// 而消费端把 count 当作「搜索结果条数」写进
  /// `assistantMsg.injectedWebSearchCount`（chat_screen_react.dart 的
  /// `onSaveAssistantContent`）→ 生成类插件（gen_plugins.dart:242 image_gen）
  /// 一调 `saveAssistantContent(force: true)`，气泡页脚就渲染成
  /// 「已联网注入 999999999 条搜索结果」、toast 也跟着念一遍。
  ///
  /// 教训：**语义要用类型表达，不能借用数值取值域**（哨兵值一旦跨过
  /// 类型边界就会被下游按原语义消费）。此处 count 现在恒为真实命中数。
  final Future<void> Function(int searchHits, {bool force})?
      _onSaveAssistantContent;
  final Future<String?> Function(String question, List<String> options)?
      _onShowAskUser;
  final Future<void> Function({
    required String userText,
    required String keyword,
    required List<String> altKeywords,
    required List<String> officialDomains,
    ChatMessage? existingUserMsg,
    ChatMessage? existingPlaceholder,
    String platform,
  })? _onPresentAppDownloadSources;
  final Future<void> Function({
    required String userText,
    required String query,
    String? fileType,
    ChatMessage? existingUserMsg,
    ChatMessage? existingPlaceholder,
  })? _onPresentFileSources;
  final Future<void> Function(String url, ChatMessage assistantMsg)?
      _onGenericDownload;
  final void Function(bool value)? _onAnsweredChanged;

  PluginContext({
    required this.workingMessages,
    required this.assistantMsg,
    required this.webSearchCfg,
    this.currentReasoningEffort = 0.0,
    this.conversationApiConfig,
    this.userMsg,
    this.rawResp,
    StorageService? storage,
    WebSearchService? webSearch,
    AppDownloadService? appDownload,
    LoggerService? logger,
    StringBuffer? answerBuffer,
    this.answered = false,
    this.mounted = true,
    BuildContext? rootContext,
    VoidCallback? onRequestStop,
    void Function(String text)? onAppendReasoning,
    void Function(String text)? onAppendUserMessage,
    void Function(String text, {int injectedWebSearchCount, bool forceSave})?
        onFinalizeAnswer,
    void Function(VoidCallback fn)? onSetState,
    Future<void> Function(int searchHits, {bool force})?
        onSaveAssistantContent,
    Future<String?> Function(String question, List<String> options)?
        onShowAskUser,
    Future<void> Function({
      required String userText,
      required String keyword,
      required List<String> altKeywords,
      required List<String> officialDomains,
      ChatMessage? existingUserMsg,
      ChatMessage? existingPlaceholder,
      String platform,
    })? onPresentAppDownloadSources,
    Future<void> Function({
      required String userText,
      required String query,
      String? fileType,
      ChatMessage? existingUserMsg,
      ChatMessage? existingPlaceholder,
    })? onPresentFileSources,
    Future<void> Function(String url, ChatMessage assistantMsg)?
        onGenericDownload,
    void Function(bool value)? onAnsweredChanged,
  })  : answerBuffer = answerBuffer ?? StringBuffer(),
        _storage = storage,
        _webSearch = webSearch,
        _appDownload = appDownload,
        _logger = logger,
        _rootContext = rootContext,
        _onRequestStop = onRequestStop,
        _onAppendReasoning = onAppendReasoning,
        _onAppendUserMessage = onAppendUserMessage,
        _onFinalizeAnswer = onFinalizeAnswer,
        _onSetState = onSetState,
        _onSaveAssistantContent = onSaveAssistantContent,
        _onShowAskUser = onShowAskUser,
        _onPresentAppDownloadSources = onPresentAppDownloadSources,
        _onPresentFileSources = onPresentFileSources,
        _onGenericDownload = onGenericDownload,
        _onAnsweredChanged = onAnsweredChanged;

  StorageService get storage {
    assert(_storage != null, 'PluginContext.storage 未注入');
    return _storage!;
  }

  WebSearchService get webSearch {
    assert(_webSearch != null, 'PluginContext.webSearch 未注入');
    return _webSearch!;
  }

  AppDownloadService get appDownload {
    assert(_appDownload != null, 'PluginContext.appDownload 未注入');
    return _appDownload!;
  }

  LoggerService get logger {
    assert(_logger != null, 'PluginContext.logger 未注入');
    return _logger!;
  }

  /// build139：把「被吞掉的异常」统一落到 LoggerService，并带上调用点。
  ///
  /// 原写法是 24 处一字不差的 `catch (e) { debugPrint('catch 静默异常: $e'); }`，
  /// 两宗罪：① `debugPrint` 只进 stdout，**不落到 LoggerService 的日志文件**，
  /// 真机出问题时导出日志里一个字都查不到（本仓库反复吃过「降级路径无痕迹」的亏，
  /// 见 build139 静默降级扫描）；② 文案不带位置信息，就算看见也不知道哪一步炸的。
  /// 用 `StackTrace.current` 的第二帧补调用点（第一帧是本方法自身）。
  void _logSwallow(Object e) {
    final frames = StackTrace.current.toString().split('\n');
    final where = frames.length > 1 ? frames[1].trim() : '?';
    _logger?.warn('catch 静默异常 @ $where: $e', tag: 'Plugin');
    debugPrint('catch 静默异常 @ $where: $e');
  }

  void showSnackBar(String message, {bool error = false}) {
    if (!mounted) return;
    try {
      final ctx = _rootContext;
      if (ctx == null) return;
      ScaffoldMessenger.of(ctx).hideCurrentSnackBar();
      AppSnackBar.showSnackBar(ctx, 
        SnackBar(
          content: Text(message),
          backgroundColor: error ? Theme.of(ctx).colorScheme.error : null,
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) { _logSwallow(e); }
  }

  void hideCurrentSnackBar() {
    if (!mounted) return;
    try {
      final ctx = _rootContext;
      if (ctx == null) return;
      ScaffoldMessenger.of(ctx).hideCurrentSnackBar();
    } catch (e) { _logSwallow(e); }
  }

  Future<T?> showDialogWidget<T>(Widget dialog,
      {bool barrierDismissible = true}) async {
    if (!mounted) return null;
    try {
      final ctx = _rootContext;
      if (ctx == null) return null;
      return await Navigator.of(ctx).push<T>(
        DialogRoute<T>(
          context: ctx,
          builder: (_) => dialog,
          barrierDismissible: barrierDismissible,
        ),
      );
    } catch (e) {
      _logSwallow(e);
      return null;
    }
  }

  Future<void> navigatorPush(MaterialPageRoute route) async {
    if (!mounted) return;
    try {
      final ctx = _rootContext;
      if (ctx == null) return;
      await Navigator.of(ctx).push(route);
    } catch (e) { _logSwallow(e); }
  }

  void appendReasoning(String text) {
    if (!mounted) return;
    try {
      _safeSetState(() {
        answerBuffer.write(text);
        final cb = _onAppendReasoning;
        if (cb != null) cb(text);
        if (workingMessages.isNotEmpty) {
          final last = workingMessages.last;
          last.appendLastThinking(text);
        }
      });
    } catch (e) { _logSwallow(e); }
  }

  ReasoningStep? addReasoningStep(
    String type,
    String label, {
    String? content,
    int? resultCount,
    int? latencyMs,
    String? pluginId,
    String? pluginName,
    String? toolName,
    String status = '',
    String? arguments,
    String? resultSummary,
  }) {
    if (!mounted) return null;
    ReasoningStep? step;
    try {
      _safeSetState(() {
        step = ReasoningStep(
          type,
          content ?? label,
          resultCount: resultCount,
          latencyMs: latencyMs,
          pluginId: pluginId,
          pluginName: pluginName,
          toolName: toolName,
          status: status,
          arguments: arguments,
          resultSummary: resultSummary,
        );
        assistantMsg.addReasoning(step!);
      });
    } catch (e) { _logSwallow(e); }
    return step;
  }

  void updateReasoningStep(
    ReasoningStep? step, {
    String? content,
    int? latencyMs,
    String? status,
    String? resultSummary,
    int? resultCount,
  }) {
    if (!mounted || step == null) return;
    try {
      _safeSetState(() {
        if (content != null) step.content = content;
        if (latencyMs != null) step.latencyMs = latencyMs;
        if (status != null) step.status = status;
        if (resultSummary != null) step.resultSummary = resultSummary;
        if (resultCount != null) step.resultCount = resultCount;
      });
    } catch (e) { _logSwallow(e); }
  }

  void appendUserMessage(String text) {
    if (!mounted) return;
    try {
      final cb = _onAppendUserMessage;
      if (cb != null) cb(text);
    } catch (e) { _logSwallow(e); }
  }

  void finalizeAnswer(String text,
      {int injectedWebSearchCount = 0, bool forceSave = true}) {
    if (!mounted) return;
    try {
      answered = true;
      answerBuffer.clear();
      answerBuffer.write(text);
      final cb = _onFinalizeAnswer;
      if (cb != null) {
        cb(text,
            injectedWebSearchCount: injectedWebSearchCount,
            forceSave: forceSave);
      }
    } catch (e) { _logSwallow(e); }
  }

  void requestStopLoop() {
    if (!mounted) return;
    try {
      final cb = _onRequestStop;
      if (cb != null) cb();
    } catch (e) { _logSwallow(e); }
  }

  void appendAnswerChunk(String chunk) {
    if (!mounted) return;
    try {
      _safeSetState(() {
        answerBuffer.write(chunk);
        if (workingMessages.isNotEmpty) {
          workingMessages.last.content = answerBuffer.toString();
        }
      });
    } catch (e) { _logSwallow(e); }
  }

  void mutateMessageAt(int index, void Function(ChatMessage msg) mutator) {
    if (!mounted) return;
    try {
      if (index < 0 || index >= workingMessages.length) return;
      _safeSetState(() {
        mutator(workingMessages[index]);
      });
    } catch (e) { _logSwallow(e); }
  }

  ChatMessage? lastMessage() {
    try {
      return workingMessages.isEmpty ? null : workingMessages.last;
    } catch (_) {
      return null;
    }
  }

  void addMessage(ChatMessage msg) {
    if (!mounted) return;
    try {
      _safeSetState(() {
        workingMessages.add(msg);
      });
    } catch (e) { _logSwallow(e); }
  }

  void setMounted(bool value) {
    try {
      mounted = value;
    } catch (e) { _logSwallow(e); }
  }

  void setAnswered(bool value) {
    if (!mounted) return;
    try {
      answered = value;
      _onAnsweredChanged?.call(value);
    } catch (e) { _logSwallow(e); }
  }

  void incrementTotalSearchHits([int delta = 1]) {
    try {
      totalSearchHits += delta;
    } catch (e) { _logSwallow(e); }
  }

  void markLastSearchResult(int count, {Duration? latency, String? summary}) {
    if (!mounted) return;
    try {
      _safeSetState(() {
        assistantMsg.markLastSearchResult(
          count: count,
          latencyMs: latency?.inMilliseconds,
          summary: summary ?? '',
        );
      });
    } catch (e) { _logSwallow(e); }
  }

  void setInjectedWebSearchCount(int count) {
    if (!mounted) return;
    try {
      _safeSetState(() {
        assistantMsg.injectedWebSearchCount = count;
      });
    } catch (e) { _logSwallow(e); }
  }

  void setShowStaleFootnote(bool v) {
    if (!mounted) return;
    try {
      _safeSetState(() {
        assistantMsg.showStaleFootnote = v;
      });
    } catch (e) { _logSwallow(e); }
  }

  /// build139（静默降级修复）：上一次 [showAskUser] 是否**抛异常**而没问出口。
  ///
  /// 原实现 catch 后 `return null`，而 null 同时是「用户跳过」的返回值 ——
  /// 调用方（builtin_plugins.dart 的 AskUserPlugin）于是往对话里注入
  /// 「用户已拒绝补充该信息，禁止就同一缺口再问」，把**我们自己的 UI 故障**
  /// 说成**用户的意愿**，模型据此闭嘴。故障可以降级，但不能伪造用户意图。
  bool get lastAskUserFailed => _lastAskUserFailed;
  bool _lastAskUserFailed = false;

  Future<String?> showAskUser(String question, List<String> options) async {
    _lastAskUserFailed = false;
    final cb = _onShowAskUser;
    if (cb == null) {
      _lastAskUserFailed = true;
      _logger?.warn('[AskUser] 宿主未注入提问回调，问题未展示：$question',
          tag: 'Plugin');
      return null;
    }
    if (!mounted) {
      _lastAskUserFailed = true;
      _logger?.warn('[AskUser] 页面已销毁，问题未展示：$question', tag: 'Plugin');
      return null;
    }
    try {
      return await cb(question, options);
    } catch (e) {
      _lastAskUserFailed = true;
      _logger?.warn('[AskUser] 提问组件异常，问题未送达用户：$e', tag: 'Plugin');
      return null;
    }
  }

  Future<void> presentAppDownloadSources({
    required String userText,
    required String keyword,
    required List<String> altKeywords,
    required List<String> officialDomains,
    ChatMessage? existingUserMsg,
    ChatMessage? existingPlaceholder,
    String platform = 'android',
  }) async {
    final cb = _onPresentAppDownloadSources;
    if (cb == null || !mounted) return;
    try {
      await cb(
        userText: userText,
        keyword: keyword,
        altKeywords: altKeywords,
        officialDomains: officialDomains,
        existingUserMsg: existingUserMsg,
        existingPlaceholder: existingPlaceholder,
        platform: platform,
      );
    } catch (e) { _logSwallow(e); }
  }

  Future<void> presentFileSources({
    required String userText,
    required String query,
    String? fileType,
    ChatMessage? existingUserMsg,
    ChatMessage? existingPlaceholder,
  }) async {
    final cb = _onPresentFileSources;
    if (cb == null || !mounted) return;
    try {
      await cb(
        userText: userText,
        query: query,
        fileType: fileType,
        existingUserMsg: existingUserMsg,
        existingPlaceholder: existingPlaceholder,
      );
    } catch (e) { _logSwallow(e); }
  }

  Future<void> genericDownload(String url, ChatMessage amsg) async {
    final cb = _onGenericDownload;
    if (cb == null || !mounted) return;
    await cb(url, amsg);
  }

  Future<void> saveAssistantContent({bool force = false}) async {
    final cb = _onSaveAssistantContent;
    if (cb == null) return;
    try {
      // build129：count 只装**真实命中数**；force 用命名形参表达（勿再用魔数）。
      await cb(totalSearchHits, force: force);
    } catch (e) { _logSwallow(e); }
  }

  void _safeSetState(VoidCallback fn) {
    try {
      fn();
      final setStateCb = _onSetState;
      if (setStateCb != null) setStateCb(() {});
    } catch (e) { _logSwallow(e); }
  }
}
