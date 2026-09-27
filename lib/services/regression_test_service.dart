import 'dart:io';
import 'dart:ui' as ui;

import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/api_config.dart';
import '../models/chat_message.dart';
import '../plugins/builtin_plugins.dart';
import '../prompts/agent_prompts.dart';
import 'agent_parser.dart';
import 'api_service.dart';
import 'logger_service.dart';
import 'react_parser.dart';
import 'storage_service.dart';

/// v1.7.36+：与生产解析器（agent_parser）对齐——先剥离模型习惯性包裹的
/// `<thinking>…</thinking>` 与 `<answer>…</answer>` 外壳，再评判内容。
/// 生产链路 extractQueries/extractSynthesis 本就容忍这层外壳，
/// 回归测试若按"零其他标签"严判会把正常输出误报为失败。
String _stripAgentWrappers(String raw) {
  var s = raw.replaceAll(
      RegExp(r'<thinking>[\s\S]*?</thinking>', caseSensitive: false), '');
  s = stripAnswerTag(s);
  return s.trim();
}

/// 单个回归测试用例的结果
///
/// 自动判定（autoPassed）+ 人工二次确认（userVerdict）双轨：
/// - autoPassed=true  → 系统判定 AI 回复符合预期
/// - autoPassed=false → 系统判定异常（用户仍可标"正确"覆盖）
/// - userVerdict=null → 用户尚未确认
class RegressionTestResult {
  final String id;
  final String name;
  final String description;
  final bool autoPassed;
  /// build97 (P1-6)：跳过（如未配置 API）≠ 自动通过。
  /// 旧实现 _skipped 给 autoPassed=true，统计进通过数 → 全绿假象，
  /// 掩盖真实提示词/模型退化。
  final bool skipped;
  final String detail;
  final String rawResponse;
  bool? userVerdict; // null=未确认, true=正确, false=异常

  RegressionTestResult({
    required this.id,
    required this.name,
    required this.description,
    required this.autoPassed,
    this.skipped = false,
    required this.detail,
    required this.rawResponse,
    this.userVerdict,
  });
}

/// AI 回归测试服务（v1.4.4 新增）
///
/// 与 SelfCheckService 的区别：
///   - SelfCheckService：检查 App 自身基础设施（DB schema / 日志脱敏 / API 连通性等）
///   - RegressionTestService：发送固定输入，验证 AI 模型行为是否符合预期
///
/// 三类用例：
///   1. 反问对话框检测（关键词触发 AI 输出 <ask_user> 标签）
///   2. TXT 附件内容识别（附件含 "12345678"，问"什么数字"，AI 应答出 12345678）
///   3. 图片附件内容识别（图片含 "12345678"，问"什么数字"，AI 应答出 12345678）
///
/// 自动判定 + 人工二次确认：
///   系统按规则自动判 pass/fail，用户可在结果上点「正确」覆盖或「异常」标错。
class RegressionTestService {
  static final _logger = LoggerService.instance;

  /// 固定测试期望内容（所有附件测试都用这串数字）
  static const String kExpectedContent = '12345678';

  /// 触发反问对话框的关键词（用户可发送这些词让 AI 主动反问）
  static const List<String> kRebuttalTriggers = [
    '测试反问',
    '请反问我一个问题',
    '用 <ask_user> 协议问我',
  ];

  // ===========================================================================
  // 一、运行时生成固定测试文件
  // ===========================================================================

  /// 生成/复用 TXT 测试文件
  ///
  /// 写入固定内容 [kExpectedContent] 到 app docs 目录的 regression_test_text.txt
  static Future<File> ensureTxtTestFile() async {
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}/regression_test_text.txt');
    if (!await f.exists() || (await f.readAsString()) != kExpectedContent) {
      await f.writeAsString(kExpectedContent);
      _logger.info('[REGRESSION] Generated TXT test file: ${f.path}',
          tag: 'Reg');
    }
    return f;
  }

  /// 生成/复用 图片测试文件（白底黑字"12345678"）
  ///
  /// 用 Canvas 绘制 400x100 白底图片，黑色 40px 文字居中。
  static Future<File> ensureImageTestFile() async {
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}/regression_test_image.png');
    if (await f.exists() && await f.length() > 0) {
      return f; // 已生成则复用
    }

    const width = 400;
    const height = 100;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);

    // 白底
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );

    // 黑字 "12345678"
    final paragraph = ui.ParagraphBuilder(
      ui.ParagraphStyle(
        fontSize: 40,
        fontWeight: ui.FontWeight.bold,
        textAlign: ui.TextAlign.left,
      ),
    )
      ..pushStyle(ui.TextStyle(color: const ui.Color(0xFF000000), fontSize: 40))
      ..addText(kExpectedContent);
    final p = paragraph.build()
      ..layout(ui.ParagraphConstraints(width: width.toDouble()));

    // 文字居中绘制
    canvas.drawParagraph(p, const ui.Offset(40, 30));

    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) {
      throw StateError('regression_test_image: toByteData returned null');
    }
    final png = byteData.buffer.asUint8List();
    await f.writeAsBytes(png);
    _logger.info(
        '[REGRESSION] Generated PNG test file: ${f.path} (${png.length} bytes)',
        tag: 'Reg');
    return f;
  }

  // ===========================================================================
  // 二、运行测试用例
  // ===========================================================================

  /// 运行所有用例（消耗 token，需用户手动触发）
  ///
  /// 顺序执行：对话链路 → 反问 → TXT → 图片 → 4 个子代理标签协议判定
  static Future<List<RegressionTestResult>> runAll({bool isZh = true}) async {
    final results = <RegressionTestResult>[];
    // B-006：逐项隔离——单项异常（存储满 / 离屏渲染失败 / 网络异常等）不再中断
    // 整批，其余用例照常执行出结果（与 SelfCheckService.runAll 的隔离强度对齐）。
    Future<void> runGuarded(
      String id,
      String name,
      Future<RegressionTestResult> Function() fn,
    ) async {
      try {
        results.add(await fn());
      } catch (e) {
        _logger.info('[REGRESSION] case "$id" threw: $e', tag: 'Reg');
        results.add(_error(id, name, '', e.toString(), isZh));
      }
    }

    await runGuarded('dialog_link', isZh ? '对话链路' : 'Dialog link',
        () => runDialogLinkTest(isZh));
    await runGuarded('rebuttal_dialog', isZh ? '反问对话框检测' : 'Rebuttal dialog',
        () => runRebuttalDialogTest(isZh));
    await runGuarded('txt_attachment',
        isZh ? 'TXT 附件内容识别' : 'TXT attachment', () => runTxtAttachmentTest(isZh));
    await runGuarded('image_attachment',
        isZh ? '图片附件内容识别' : 'Image attachment', () => runImageAttachmentTest(isZh));
    // v1.7.34：子代理编排 4 个标签协议测试（每例 1 次 LLM 调用，纯 prompt 驱动，不联网）
    await runGuarded('subagent_route', isZh ? '子代理路由' : 'Subagent route',
        () => runSubagentRouteTest(isZh));
    await runGuarded('subagent_search', isZh ? '子代理搜索' : 'Subagent search',
        () => runSubagentSearchAgentTest(isZh));
    await runGuarded('subagent_synthesis',
        isZh ? '子代理综合' : 'Subagent synthesis',
        () => runSubagentSynthesisAgentTest(isZh));
    await runGuarded('subagent_plugin', isZh ? '子代理插件' : 'Subagent plugin',
        () => runSubagentPluginAgentTest(isZh));

    final passCount = results
        .where((r) => !r.skipped && r.autoPassed && r.userVerdict != false)
        .length;
    final skippedCount = results.where((r) => r.skipped).length;
    _logger.info(
        '[REGRESSION] 测试完成：$passCount/${results.length} 自动通过；'
        '$skippedCount 项跳过；'
        '${results.where((r) => r.userVerdict == true).length} 项用户确认正确，'
        '${results.where((r) => r.userVerdict == false).length} 项用户标记异常',
        tag: 'Reg');
    return results;
  }

  /// 用例 0：对话链路测试（v1.4.6 合并自原 SelfCheckService._checkDialogTest）
  ///
  /// 发送短消息，验证完整对话链路：API 连通 → 返回非空回复。
  /// 自动判定：resp 非空 → 通过。
  static Future<RegressionTestResult> runDialogLinkTest(bool isZh) async {
    const id = 'dialog_link';
    final name = isZh ? '对话链路测试' : 'Dialog link test';
    final desc = isZh
        ? '发送"请只回复「测试成功」四个字"，AI 应返回非空回复'
        : 'Send "请只回复「测试成功」四个字", AI should return a non-empty reply';

    final cfg = await _getFirstApiConfig();
    if (cfg == null) {
      return _skipped(
          id, name, desc, isZh ? '未配置 API' : 'No API configured', isZh);
    }

    final apiSvc = ApiService();
    final userMsg = ChatMessage.create(
      conversationId: 'regression_test',
      role: MessageRole.user,
      content: '请只回复「测试成功」四个字',
    );

    try {
      final resp = await apiSvc.completeChat(
        config: cfg,
        messages: [userMsg],
        reasoningEffort: 'low',
        timeout: const Duration(seconds: 30),
      );
      final pass = resp.isNotEmpty;
      return RegressionTestResult(
        id: id,
        name: name,
        description: desc,
        autoPassed: pass,
        detail: pass
            ? (isZh ? '收到 ${resp.length} 字回复' : 'Got ${resp.length}-char reply')
            : (isZh ? '异常：回复为空' : 'Error: empty reply'),
        rawResponse: resp,
      );
    } catch (e) {
      return _error(id, name, desc, e.toString(), isZh);
    }
  }

  /// 用例 1：反问对话框检测
  ///
  /// 构造一个会触发 AI 输出 `<ask_user>` 标签的提示词，
  /// 调用 completeChat，用 parseReActOutput 检查返回里是否含 ask_user 标签。
  static Future<RegressionTestResult> runRebuttalDialogTest(bool isZh) async {
    const id = 'rebuttal_dialog';
    final name = isZh ? '反问对话框检测' : 'Rebuttal dialog detection';
    final desc = isZh
        ? '发送"测试反问"关键词，AI 应输出 <ask_user> 标签触发反问对话框'
        : 'Send "测试反问" keyword, AI should output the <ask_user> tag to trigger the rebuttal dialog';

    final cfg = await _getFirstApiConfig();
    if (cfg == null) {
      return _skipped(
          id, name, desc, isZh ? '未配置 API' : 'No API configured', isZh);
    }

    final apiSvc = ApiService();
    // 在 system prompt 里注入 ReAct 协议说明，让 AI 知道可以用 <ask_user>
    final userMsg = ChatMessage.create(
      conversationId: 'regression_test',
      role: MessageRole.user,
      content: '${kRebuttalTriggers.first}：请用 <ask_user> 标签向我提问一个'
          '简单问题，例如"你喜欢什么颜色？"，可选附上 2~3 个选项让用户选。',
    );
    final systemMsg = ChatMessage.create(
      conversationId: 'regression_test',
      role: MessageRole.system,
      content:
          '${cfg.systemPrompt}\n${buildReactSystemPromptFromPlugins(builtinReActPlugins)}',
    );

    try {
      final resp = await apiSvc.completeChat(
        config: cfg.copyWith(systemPrompt: ''), // system 已通过 systemMsg 注入
        messages: [systemMsg, userMsg],
        reasoningEffort: 'low',
        timeout: const Duration(seconds: 60),
      );
      final parsed = parseReActOutput(resp);
      final hasAskUser = parsed.any((p) => p['type'] == 'ask_user');
      final askPiece = parsed.firstWhere(
        (p) => p['type'] == 'ask_user',
        orElse: () => <String, String>{},
      );
      final detail = hasAskUser
          ? (isZh
              ? 'AI 输出 <ask_user> 标签（内容：${askPiece['content'] ?? ''}）'
              : 'AI output <ask_user> tag (content: ${askPiece['content'] ?? ''})')
          : (isZh
              ? 'AI 未输出 <ask_user> 标签'
              : 'AI did not output <ask_user> tag');
      return RegressionTestResult(
        id: id,
        name: name,
        description: desc,
        autoPassed: hasAskUser,
        detail: detail,
        rawResponse: resp,
      );
    } catch (e) {
      return _error(id, name, desc, e.toString(), isZh);
    }
  }

  /// 用例 2：TXT 附件内容识别
  ///
  /// 构造 MessageAttachment(type: text, extractedText: "12345678")，
  /// 发送"附件里写着什么数字？"，AI 应答出 "12345678"。
  static Future<RegressionTestResult> runTxtAttachmentTest(bool isZh) async {
    const id = 'txt_attachment';
    final name = isZh ? 'TXT 附件内容识别' : 'TXT attachment content recognition';
    final desc = isZh
        ? '附件内容为"12345678"，问"附件里写着什么数字"，AI 应答出 12345678'
        : 'Attachment contains "12345678"; ask what number is written in it, AI should answer 12345678';

    final cfg = await _getFirstApiConfig();
    if (cfg == null) {
      return _skipped(
          id, name, desc, isZh ? '未配置 API' : 'No API configured', isZh);
    }

    // 同时生成实际文件并复用，方便后续手动调试
    // B-006：测试文件生成纳入用例保护——存储满/无写权限时只让本用例失败，
    // 不再穿出 runXxx 中断整批。
    try {
      await ensureTxtTestFile();
    } catch (e) {
      return _error(id, name, desc, e.toString(), isZh);
    }

    final apiSvc = ApiService();
    final userMsg = ChatMessage.create(
      conversationId: 'regression_test',
      role: MessageRole.user,
      content: '请看附件，告诉我里面写着什么数字（只需回答数字本身，不要解释）。',
    )..attachments.add(MessageAttachment(
        id: const Uuid().v4(),
        type: AttachmentType.text,
        fileName: 'regression_test_text.txt',
        extractedText: kExpectedContent,
      ));

    return _runAttachmentTest(id, name, desc, cfg, userMsg, apiSvc, isZh);
  }

  /// 用例 3：图片附件内容识别
  ///
  /// 生成白底黑字"12345678"PNG，构造 MessageAttachment(type: image)，
  /// 发送"图片里写着什么数字？"，AI 应答出 "12345678"。
  static Future<RegressionTestResult> runImageAttachmentTest(bool isZh) async {
    const id = 'image_attachment';
    final name = isZh ? '图片附件内容识别' : 'Image attachment content recognition';
    final desc = isZh
        ? '图片含"12345678"字样，问"图片里写着什么数字"，AI 应答出 12345678'
        : 'Image contains "12345678"; ask what number is written in it, AI should answer 12345678';

    final cfg = await _getFirstApiConfig();
    if (cfg == null) {
      return _skipped(
          id, name, desc, isZh ? '未配置 API' : 'No API configured', isZh);
    }

    // B-006：同 TXT 用例——离屏 Canvas 渲染失败（toByteData 返回 null）时
    // 只让本用例失败，不影响其余用例。
    final File imgFile;
    try {
      imgFile = await ensureImageTestFile();
    } catch (e) {
      return _error(id, name, desc, e.toString(), isZh);
    }

    final apiSvc = ApiService();
    final userMsg = ChatMessage.create(
      conversationId: 'regression_test',
      role: MessageRole.user,
      content: '请看附件图片，告诉我图片里写着什么数字（只需回答数字本身，不要解释）。',
    )..attachments.add(MessageAttachment(
        id: const Uuid().v4(),
        type: AttachmentType.image,
        fileName: 'regression_test_image.png',
        localPath: imgFile.path,
        mimeType: 'image/png',
      ));

    return _runAttachmentTest(id, name, desc, cfg, userMsg, apiSvc, isZh);
  }

  // ===========================================================================
  // v1.7.34：子代理编排标签协议测试
  //   每个测试 = 1 次 LLM 调用（用对应专家的 prompt 作为 system）
  //   判定：AI 回复是否含目标标签 + 关键结构
  // ===========================================================================

  /// 用例 4：主代理（路由器）—— 输出必须含 `<route target="..."/>`
  ///
  /// 输入：用户消息 "什么是量子计算？"（常识类，应路由到 self）
  /// 判定：正则命中 `<route ... target="self" ...>` 且未包含 <answer>
  static Future<RegressionTestResult> runSubagentRouteTest(bool isZh) async {
    const id = 'subagent_route';
    final name = isZh ? '子代理·主代理路由' : 'Subagent · Main Agent Route';
    final desc = isZh
        ? '常识类问题「什么是量子计算？」，AI 应输出 <route target="self" .../> 且只输出 route 标签'
        : 'For a common-sense question, AI should output <route target="self" .../> only';

    final cfg = await _getFirstApiConfig();
    if (cfg == null) {
      return _skipped(
          id, name, desc, isZh ? '未配置 API' : 'No API configured', isZh);
    }

    final apiSvc = ApiService();
    final systemPrompt = buildMainAgentPrompt(
      isZh: isZh,
      deepResearch: false,
      stageSynthesize: false,
    );
    final systemMsg = ChatMessage.create(
      conversationId: 'regression_test',
      role: MessageRole.system,
      content: systemPrompt,
    );
    final userMsg = ChatMessage.create(
      conversationId: 'regression_test',
      role: MessageRole.user,
      content: '什么是量子计算？请只用一行 route 标签回答，不要展开。',
    );

    try {
      final resp = await apiSvc.completeChat(
        config: cfg.copyWith(systemPrompt: ''),
        messages: [systemMsg, userMsg],
        reasoningEffort: 'low',
        timeout: const Duration(seconds: 60),
      );
      // 判定：必须含 <route 标签；常识类应 target=self；不应含 <answer>
      final routeRe = RegExp(r'<route\s+[^>]*target\s*=\s*"([^"]+)"[^>]*?/?>',
          caseSensitive: false);
      final m = routeRe.firstMatch(resp);
      final hasRoute = m != null;
      final target = m?.group(1)?.toLowerCase().trim() ?? '';
      final validTarget =
          {'self', 'search', 'synthesis', 'plugin'}.contains(target);
      final targetIsSelf = target == 'self';
      final noAnswer =
          !RegExp(r'<answer>', caseSensitive: false).hasMatch(resp);
      final pass = hasRoute && validTarget && noAnswer && targetIsSelf;
      final detail = hasRoute
          ? (isZh
              ? '命中 <route> 标签（target=$target${targetIsSelf ? '' : '⚠ 常识问题应为 self'}；含 <answer>=$noAnswer）'
              : 'Matched <route> tag (target=$target${targetIsSelf ? '' : '⚠ should be self'}; contains <answer>=${!noAnswer})')
          : (isZh ? '未命中 <route> 标签' : 'No <route> tag found');
      return RegressionTestResult(
        id: id,
        name: name,
        description: desc,
        autoPassed: pass,
        detail: detail,
        rawResponse: resp,
      );
    } catch (e) {
      return _error(id, name, desc, e.toString(), isZh);
    }
  }

  /// 用例 5：搜索专家 —— 输出必须含 `<queries>` + 至少 1 个 `<query>`，最多 5 条
  ///
  /// 输入：用户消息 "2025 年最新 AI 大模型排名"
  /// 判定：正则命中 `<queries>` 包裹，`<query>` 数量在 [1,5] 区间
  static Future<RegressionTestResult> runSubagentSearchAgentTest(
      bool isZh) async {
    const id = 'subagent_search';
    final name = isZh ? '子代理·搜索专家' : 'Subagent · Search Agent';
    final desc = isZh
        ? '输入需检索的问题，AI 应输出 <queries> + 1~5 条 <query> 标签'
        : 'AI should output <queries> with 1-5 <query> tags';

    final cfg = await _getFirstApiConfig();
    if (cfg == null) {
      return _skipped(
          id, name, desc, isZh ? '未配置 API' : 'No API configured', isZh);
    }

    final apiSvc = ApiService();
    final systemMsg = ChatMessage.create(
      conversationId: 'regression_test',
      role: MessageRole.system,
      content: buildSearchAgentPrompt(isZh: isZh),
    );
    final userMsg = ChatMessage.create(
      conversationId: 'regression_test',
      role: MessageRole.user,
      content: isZh
          ? '2025 年最新 AI 大模型排名（需要联网查询）'
          : 'Latest 2025 AI LLM rankings (needs web search)',
    );

    try {
      final resp = await apiSvc.completeChat(
        config: cfg.copyWith(systemPrompt: ''),
        messages: [systemMsg, userMsg],
        reasoningEffort: 'low',
        timeout: const Duration(seconds: 60),
      );
      // v1.7.36+：先剥离 <thinking>/<answer> 外壳（生产解析器容忍），再评判
      final body = _stripAgentWrappers(resp);
      final hasOuter =
          RegExp(r'<queries>', caseSensitive: false).hasMatch(body);
      final queryMatches =
          RegExp(r'<query\s*>\s*([\s\S]*?)\s*</query>', caseSensitive: false)
              .allMatches(body)
              .toList();
      final count = queryMatches.length;
      final hasContent =
          queryMatches.any((m) => (m.group(1) ?? '').trim().length >= 3);
      final noOther =
          !RegExp(r'<route>|<plugin_call>|<synthesis>', caseSensitive: false)
              .hasMatch(body);
      final pass =
          hasOuter && count >= 1 && count <= 5 && hasContent && noOther;
      final detail = hasOuter
          ? (isZh
              ? '命中 <queries>，共 $count 条 query${hasContent ? '，内容非空' : '⚠ 内容过短'}；含其他标签=$noOther'
              : 'Matched <queries>, $count queries${hasContent ? ', non-empty' : '⚠ too short'}; no other tags=$noOther')
          : (isZh ? '未命中 <queries> 标签' : 'No <queries> tag found');
      return RegressionTestResult(
        id: id,
        name: name,
        description: desc,
        autoPassed: pass,
        detail: detail,
        rawResponse: resp,
      );
    } catch (e) {
      return _error(id, name, desc, e.toString(), isZh);
    }
  }

  /// 用例 6：综合专家 —— 输出必须含 `<synthesis>` + 三节结构（结论/证据/分歧）
  ///
  /// 输入：一段假证据，问"分析这段证据"
  /// 判定：命中 `<synthesis>` + 三节标题（中文：结论/证据/分歧；英文：Conclusion/Evidence/Disagreements）
  static Future<RegressionTestResult> runSubagentSynthesisAgentTest(
      bool isZh) async {
    const id = 'subagent_synthesis';
    final name = isZh ? '子代理·综合专家' : 'Subagent · Synthesis Agent';
    final desc = isZh
        ? '给一段假证据，AI 应输出 <synthesis> 并含「结论/证据/分歧」三节'
        : 'Given fake evidence, AI should output <synthesis> with Conclusion/Evidence/Disagreements sections';

    final cfg = await _getFirstApiConfig();
    if (cfg == null) {
      return _skipped(
          id, name, desc, isZh ? '未配置 API' : 'No API configured', isZh);
    }

    final apiSvc = ApiService();
    final systemMsg = ChatMessage.create(
      conversationId: 'regression_test',
      role: MessageRole.system,
      content: buildSynthesisAgentPrompt(isZh: isZh),
    );
    const fakeEvidence =
        '[1] AlphaLab (2025-03): 该药在二期试验中缓解症状率 62%。URL: https://example.com/alpha\n'
        '[2] BetaReview (2025-05): 独立评测称症状缓解率约 40%，样本较小。URL: https://example.com/beta\n'
        '[3] GammaPharma (2025-06): 三期试验预计 2026 Q1 出结果，未公布数据。URL: https://example.com/gamma';
    final userMsg = ChatMessage.create(
      conversationId: 'regression_test',
      role: MessageRole.user,
      content: isZh
          ? '用户问题：请综合分析这款新药的有效性，并指出证据分歧。\n\n已收集证据：\n$fakeEvidence'
          : 'User question: Analyze the drug effectiveness and flag evidence conflicts.\n\nCollected evidence:\n$fakeEvidence',
    );

    try {
      final resp = await apiSvc.completeChat(
        config: cfg.copyWith(systemPrompt: ''),
        messages: [systemMsg, userMsg],
        reasoningEffort: 'low',
        timeout: const Duration(minutes: 2),
      );
      // v1.7.36+：先剥离 <thinking>/<answer> 外壳（生产解析器容忍），再评判
      final body = _stripAgentWrappers(resp);
      final hasSyn =
          RegExp(r'<synthesis>', caseSensitive: false).hasMatch(body);
      // 三节标题兼容中英文（复用生产判定函数）
      final sections = checkSynthesisSections(body, isZh: isZh);
      final hasConclusion = sections.conclusion;
      final hasEvidence = sections.evidence;
      final hasDisagree = sections.disagree;
      final noOther =
          !RegExp(r'<queries>|<route>|<plugin_call>', caseSensitive: false)
              .hasMatch(body);
      final pass =
          hasSyn && hasConclusion && hasEvidence && hasDisagree && noOther;
      final detail = hasSyn
          ? (isZh
              ? '命中 <synthesis>；结论=$hasConclusion 证据=$hasEvidence 分歧=$hasDisagree 无其他标签=$noOther'
              : 'Matched <synthesis>; conclusion=$hasConclusion evidence=$hasEvidence disagree=$hasDisagree noOther=$noOther')
          : (isZh ? '未命中 <synthesis> 标签' : 'No <synthesis> tag found');
      return RegressionTestResult(
        id: id,
        name: name,
        description: desc,
        autoPassed: pass,
        detail: detail,
        rawResponse: resp,
      );
    } catch (e) {
      return _error(id, name, desc, e.toString(), isZh);
    }
  }

  /// 用例 7：插件专家 —— 输入有匹配插件时应输出 `<plugin_call name="...">`；无匹配时输出 skip
  ///
  /// 双子场景：
  ///   A) 有 calculator 插件，问"2+3"，应 target=calculator
  ///   B) 空插件清单，问"随便聊聊"，应 skip=true
  /// 判定：至少一个子场景命中正确标签，两个都命中为满分通过
  static Future<RegressionTestResult> runSubagentPluginAgentTest(
      bool isZh) async {
    const id = 'subagent_plugin';
    final name = isZh ? '子代理·插件专家' : 'Subagent · Plugin Agent';
    final desc = isZh
        ? 'A) 有 calculator 插件时应输出 <plugin_call name="calculator">；B) 无插件时输出 skip=true'
        : 'A) With calculator plugin, output <plugin_call name="calculator">; B) With empty list, output skip="true"';

    final cfg = await _getFirstApiConfig();
    if (cfg == null) {
      return _skipped(
          id, name, desc, isZh ? '未配置 API' : 'No API configured', isZh);
    }

    final apiSvc = ApiService();
    // 子场景 A：有匹配的插件
    final sysA = ChatMessage.create(
      conversationId: 'regression_test',
      role: MessageRole.system,
      content: buildPluginAgentPrompt(
        isZh: isZh,
        availablePlugins: [
          {'name': 'calculator', 'description': '计算数学表达式，如 2+3、sqrt(9)'},
        ],
      ),
    );
    final userA = ChatMessage.create(
      conversationId: 'regression_test',
      role: MessageRole.user,
      content: isZh ? '帮我算 2+3' : 'Calculate 2+3',
    );

    // 子场景 B：无匹配插件（空清单）
    final sysB = ChatMessage.create(
      conversationId: 'regression_test',
      role: MessageRole.system,
      content: buildPluginAgentPrompt(isZh: isZh, availablePlugins: []),
    );
    final userB = ChatMessage.create(
      conversationId: 'regression_test',
      role: MessageRole.user,
      content: isZh ? '今天天气怎么样？随便聊聊' : 'How about today? Chat casually',
    );

    try {
      final respA = await apiSvc.completeChat(
        config: cfg.copyWith(systemPrompt: ''),
        messages: [sysA, userA],
        reasoningEffort: 'low',
        timeout: const Duration(seconds: 60),
      );
      final respB = await apiSvc.completeChat(
        config: cfg.copyWith(systemPrompt: ''),
        messages: [sysB, userB],
        reasoningEffort: 'low',
        timeout: const Duration(seconds: 60),
      );

      final nameRe = RegExp(r'<plugin_call\s+[^>]*name\s*=\s*"([^"]+)"',
          caseSensitive: false);
      final skipRe = RegExp(r'<plugin_call\s+[^>]*skip\s*=\s*"true"',
          caseSensitive: false);

      final mA = nameRe.firstMatch(respA);
      final aCorrect = mA != null && mA.group(1)!.toLowerCase() == 'calculator';
      final hasAnyATag =
          RegExp(r'<plugin_call', caseSensitive: false).hasMatch(respA);
      final bSkip = skipRe.hasMatch(respB);
      final hasAnyBTag =
          RegExp(r'<plugin_call', caseSensitive: false).hasMatch(respB);
      // 判定：A 命中 calculator 且 B 命中 skip
      final pass = aCorrect && bSkip;
      final detail = isZh
          ? '场景A name=calculator 命中=$aCorrect（含 plugin_call 标签=$hasAnyATag）；'
              '场景B skip=true 命中=$bSkip（含 plugin_call 标签=$hasAnyBTag）'
          : 'A name=calculator hit=$aCorrect (has plugin_call=$hasAnyATag); '
              'B skip=true hit=$bSkip (has plugin_call=$hasAnyBTag)';
      return RegressionTestResult(
        id: id,
        name: name,
        description: desc,
        autoPassed: pass,
        detail: detail,
        rawResponse: '[A]\n$respA\n\n[B]\n$respB',
      );
    } catch (e) {
      return _error(id, name, desc, e.toString(), isZh);
    }
  }

  // ===========================================================================
  // 三、辅助方法
  // ===========================================================================

  /// 通用附件测试：发送 user 消息（含附件）→ 检查 AI 回复是否包含期望数字
  static Future<RegressionTestResult> _runAttachmentTest(
    String id,
    String name,
    String desc,
    dynamic cfg, // ApiConfig
    ChatMessage userMsg,
    ApiService apiSvc,
    bool isZh,
  ) async {
    try {
      final resp = await apiSvc.completeChat(
        config: cfg,
        messages: [userMsg],
        reasoningEffort: 'low',
        timeout: const Duration(seconds: 90),
      );

      // 提取 AI 最终答案（若 ReAct 标签包裹，先解析）
      final parsed = parseReActOutput(resp);
      final answerPiece = parsed.firstWhere(
        (p) => p['type'] == 'answer',
        orElse: () => <String, String>{'type': 'answer', 'content': resp},
      );
      final answerText = (answerPiece['content'] ?? resp).trim();

      final matched = matchExpectedContent(answerText, kExpectedContent);
      final detail = matched
          ? (isZh
              ? 'AI 回复正确：包含 "$kExpectedContent"'
              : 'AI reply correct: contains "$kExpectedContent"')
          : (isZh
              ? 'AI 回复异常：未包含 "$kExpectedContent"（实际回复：'
                  '${answerText.length > 100 ? '${answerText.substring(0, 100)}...' : answerText}）'
              : 'AI reply abnormal: "$kExpectedContent" not found (actual reply: '
                  '${answerText.length > 100 ? '${answerText.substring(0, 100)}...' : answerText})');
      return RegressionTestResult(
        id: id,
        name: name,
        description: desc,
        autoPassed: matched,
        detail: detail,
        rawResponse: resp,
      );
    } catch (e) {
      return _error(id, name, desc, e.toString(), isZh);
    }
  }

  /// 内容匹配规则（纯函数，可单测）
  ///
  /// 满足以下任一条件即视为通过：
  ///   1. 回复完全等于期望（trim 后）
  ///   2. 回复包含期望内容（连写）
  ///   3. 回复包含期望数字（允许 8 个数字间有空格/破折号分隔）
  ///   4. 回复里逐字符匹配期望内容的所有数字字符（如"1 2 3 4 5 6 7 8"）
  static bool matchExpectedContent(String response, String expected) {
    final r = response.trim();
    final e = expected.trim();
    if (r.isEmpty) return false;

    // 1. 完全相等
    if (r == e) return true;

    // 2. 包含期望内容
    if (r.contains(e)) return true;

    // 3. 允许分隔符（空格/破折号/逗号）插入到数字之间
    // 提取回复里的所有数字字符
    final digitsInResp = r.replaceAll(RegExp(r'[^0-9]'), '');
    final digitsInExp = e.replaceAll(RegExp(r'[^0-9]'), '');
    if (digitsInResp == digitsInExp && digitsInExp.isNotEmpty) {
      return true;
    }

    // 4. 回复里包含期望的连续数字（防御性兜底，覆盖 OCR 可能把 8 识别成 B 等）
    if (digitsInResp.contains(digitsInExp)) {
      return true;
    }

    return false;
  }

  /// 从 StorageService 取第一个 ApiConfig（v1.4.2 SelfCheckService 同款逻辑）
  static Future<ApiConfig?> _getFirstApiConfig() async {
    try {
      final storage = StorageService.instance;
      final configs = await storage.getApiConfigs();
      return configs.isEmpty ? null : configs.first;
    } catch (e) {
      _logger.warn('[REGRESSION] _getFirstApiConfig failed: $e', tag: 'Reg');
      return null;
    }
  }

  static RegressionTestResult _skipped(
      String id, String name, String desc, String reason, bool isZh) {
    return RegressionTestResult(
      id: id,
      name: name,
      description: desc,
      // build97 (P1-6)：跳过不计自动通过（autoPassed=false），
      // UI 单独以「跳过」徽章展示，统计三分：通过/失败/跳过。
      autoPassed: false,
      skipped: true,
      detail: isZh ? '跳过：$reason' : 'Skipped: $reason',
      rawResponse: '',
    );
  }

  static RegressionTestResult _error(
      String id, String name, String desc, String err, bool isZh) {
    return RegressionTestResult(
      id: id,
      name: name,
      description: desc,
      autoPassed: false,
      detail: isZh ? '错误：$err' : 'Error: $err',
      rawResponse: '',
    );
  }
}
