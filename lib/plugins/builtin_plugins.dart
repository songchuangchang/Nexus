import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/chat_message.dart';
import '../models/memory_models.dart';
import '../services/coord_convert.dart';
import '../services/balance_service.dart';
import '../services/storage_service.dart';
import '../services/web_search_service.dart';
import '../services/attachment_service.dart';
import '../services/workspace_service.dart';
import '../services/article_extractor.dart';
import '../services/logger_service.dart';
import '../utils/ask_user_option.dart';
import '../utils/office_writer.dart';
import '../utils/workspace_permission.dart';
import 'plugin_interface.dart';
import 'plugin_context.dart';
import 'plugin_registry.dart';
import 'install_skill_plugin.dart';
import 'install_mcp_plugin.dart';
import 'gen_plugins.dart';

final ReActPlugin kFallbackUnknownTagPlugin = FallbackUnknownTagPlugin();

List<ReActPlugin> get builtinReActPlugins => [
      // build122：生成类（图片同步产出 / 视频异步提交，见 gen_plugins.dart）
      ImageGenPlugin(),
      VideoGenPlugin(),
      SearchPlugin(),
      DownloadPlugin(),
      AskUserPlugin(),
      SelfCheckPlugin(),
      AnswerPlugin(),
      // v1.7.38（待办①/拍板⑥）：AI 代装 Skill
      InstallSkillPlugin(),
      // v1.7.38（build90 第 3 步）：AI 代装 MCP
      InstallMcpPlugin(),
      // v1.7.38（build90 第 3 步）：<card> 富交互卡片协议（提示词注入用）
      CardPlugin(),
      // v1.7.39（build92）：回答后推荐后续问题（提示词注入，标签在宿主层提取）
      SuggestPlugin(),
      // v1.7.39（build92）：复杂任务待办清单
      TodoPlugin(),
      // v1.7.39（build92）：AI 自动写全局/项目记忆
      MemoryWritePlugin(),
      // N8（build94）：AI 按用户要求删除记忆（与标签/FC 双通道对齐）
      MemoryDeletePlugin(),
      // build104（M2b）：连接器指南——MCP 连接类问题注入接入步骤+错误对照表
      ConnectorGuidePlugin(),
      // build104（M2c）：AI 查询应用日志辅助排障（隐私护栏：默认关+逐次确认）
      LogQueryPlugin(),
      // build104（U3）：IP 定位城市级锚点——「附近」类查询的定位兜底
      IpLocatePlugin(),
      // build106：设备 GPS 精确定位——「最近地铁站/打车/导航」类街道级定位
      DeviceLocationPlugin(),
      // build108（Q1）：API 余额/用量查询——「我的 API 还剩多少钱」
      QuotaPlugin(),
      // build113（任务五 WS-2）：AI 文件工作区（沙箱内下载/读/写/删/导出）
      _WsListPlugin(),
      _WsReadPlugin(),
      // build136：按需检索（定位符号/字符串，避免整目录回灌）
      _WsGrepPlugin(),
      _WsWritePlugin(),
      // build136：事务式精准编辑（改代码优先走它）
      _WsPatchPlugin(),
      _WsDeletePlugin(),
      _WsDownloadPlugin(),
      _WsExportPlugin(),
      _WsMakeFilePlugin(),
      // v1.7.37：DeepResearchPlugin 已删除——深度研究并入思考强度 1.0 档
      //（轮数/提示词由 ApiService.isDeepResearchEffort + kDeepResearchProtocol 驱动）
    ];

PluginRegistry createBuiltinPluginRegistry({StorageService? storage}) {
  final r = PluginRegistry(storage: storage);
  r.registerAll(builtinReActPlugins);
  r.setFallback(kFallbackUnknownTagPlugin);
  // InstallSkillPlugin 在 handle 里需要把新 Skill 注册回同一个 registry；
  // 绑定 resolver，避免插件内跨 async 用 context.read 崩溃
  InstallSkillPlugin.registryResolver = () => r;
  // v1.7.38：InstallMcpPlugin 同理（installRemoteMcp 需要写回同一 registry）
  InstallMcpPlugin.registryResolver = () => r;
  // build104（U3）：IpLocatePlugin 需要读取已装高德连接器的 Key
  IpLocatePlugin.registryResolver = () => r;
  return r;
}

class SearchPlugin extends ReActPlugin {
  @override
  String get triggerType => 'search';

  @override
  RegExp? get legacyTrigger => null;

  @override
  PluginSource get source => PluginSource.system;

  @override
  PluginMetadata get metadata => const PluginMetadata(
        id: 'nexus.builtin.search',
        name: '联网搜索',
        version: '1.6.8',
        author: 'Nexus Team',
        description: '通过 ReAct 协议为 AI 提供联网搜索能力，支持 basic / advanced 两档深度。',
        homepage: 'https://nexus.local/plugins/search',
        minAppVersion: '1.6.8',
        tags: ['内置', '搜索', 'ReAct'],
        extra: {'notWhen': '纯常识/数学/逻辑/已有知识能回答的问题，不需要实时信息'},
        promptProtocol: '''
【搜索工具】使用说明：
- 当你需要最新资讯、实时数据或超出训练数据截止日期的信息时，调用搜索工具。
- 输出：<search query="搜索关键词" depth="basic|advanced" />
  - query：搜索引擎友好的中文或英文关键词，短语即可，不要自然长句。
  - depth：basic（快速查询，默认）或 advanced（深入调研，耗 token 约 2 倍，命中更全）。
- 示例 1：最新的 Flutter 3.x 特性
  <search query="Flutter 3 new features 2026" depth="basic" />
- 示例 2：深度调研微信小程序最新架构
  <search query="微信小程序 架构 2026 最新" depth="advanced" />
- 搜索结果会以"工具消息"形式返回给你，你再基于结果给出答案。
''',
      );

  @override
  Future<void> handle(BuildContext context, PluginContext pc,
      Map<String, dynamic> attrs) async {
    // v1.7.4 fix: react_parser 把 query 存在 content 字段，不是 query 字段
    final q = (attrs['content'] as String? ?? '').trim();
    final rawDepth = attrs['depth'] as String? ?? 'auto';
    if (q.isEmpty) {
      pc.addReasoningStep('search', '搜索关键词为空，已忽略');
      return;
    }
    final isZh =
        pc.userMsg?.content.contains(RegExp(r'[\u4e00-\u9fff]')) ?? true;
    // tavilyDepth 直接用字符串（basic / advanced），其他值让 searchGeneral 走默认
    final depthLabel = switch (rawDepth.toLowerCase()) {
      'advanced' => isZh ? '高级' : 'Adv',
      'basic' => isZh ? '基础' : 'Basic',
      _ => isZh ? '自动' : 'Auto',
    };
    pc.addReasoningStep(
        'search',
        isZh
            ? '🔍 正在搜索「$q」（深度：$depthLabel）...'
            : '🔍 Searching for "$q" (depth: $depthLabel)...');
    final stopwatch = Stopwatch()..start();
    final cfg = (rawDepth.toLowerCase() == 'advanced' ||
            rawDepth.toLowerCase() == 'basic')
        ? pc.webSearchCfg.copyWith(tavilySearchDepth: rawDepth.toLowerCase())
        : pc.webSearchCfg;
    // WebSearchService 是静态类；build139 起用带原因的入口，把「服务故障」和
    // 「确实没搜到」分开（原先两者都是空列表 → 一律显示「未找到有效结果」）。
    final (results, searchError) =
        await WebSearchService.searchGeneralDetailed(q, cfg);
    final hits = results.length;
    pc.incrementTotalSearchHits(hits);
    stopwatch.stop();
    final summary = hits == 0
        ? (searchError == null
            ? (isZh ? '未找到有效结果' : 'No results')
            : (isZh
                ? '搜索服务不可用（$searchError），本轮未取得任何结果'
                : 'Search service unavailable ($searchError); no results obtained'))
        : (isZh ? '命中 $hits 条' : 'Got $hits results');
    // v1.7.31：搜索结果摘要丰富化，包含前 10 条标题+URL 供用户查看
    final visibleSummary = StringBuffer();
    visibleSummary.write(summary);
    if (hits > 0) {
      visibleSummary.writeln();
      for (int i = 0; i < results.length && i < 10; i++) {
        final r = results[i];
        visibleSummary.writeln('${i + 1}. ${r.title}');
        visibleSummary.writeln('   ${r.url}');
      }
    }
    pc.markLastSearchResult(hits,
        latency: stopwatch.elapsed, summary: visibleSummary.toString());
    // v1.7.38：收集本轮搜索结果的 URL 列表到消息（气泡渲染「📎 来源 N」引用卡片，
    // 按 URL 去重；随 assistantMsg 落库到 messages.searchSources）
    pc.assistantMsg.addSearchSources(
        results.map((r) => SearchSource(title: r.title, url: r.url)));
    final isVerbose = pc.webSearchCfg.verboseLogging;
    if (isVerbose) {
      pc.logger.verbose(
          '[ReAct-Search] query=$q depth=$rawDepth hits=$hits latency=${stopwatch.elapsedMilliseconds}ms');
      for (int i = 0; i < results.length && i < 3; i++) {
        final r = results[i];
        pc.logger.verbose('  #${i + 1}  ${r.title}  ${r.url}');
      }
    }
    // 用 static WebSearchService.formatAsSearchContext 把搜索结果拼给 AI
    final formatted = hits > 0
        ? WebSearchService.formatAsSearchContext(results, cfg, query: q)
        : '';

    // build101（C3 深度阅读）：思考强度拉满（≥0.8）时，额外抓取前几条结果的
    // 网页正文，让模型看到真实内容而不是 1~2 行摘要。
    // 仅在深度档生效——普通提问多抓 3 个页面会明显拖慢响应。
    final deepReadBlock = await _deepReadTopResults(
      results,
      effort: pc.currentReasoningEffort,
      isZh: isZh,
      pc: pc,
    );

    final sb = StringBuffer();
    sb.writeln('---TOOL RESULT START (search)---');
    sb.writeln('query: ${_xmlEscape(q)}');
    sb.writeln('depth: $rawDepth');
    sb.writeln('hits: $hits');
    sb.writeln('latency_ms: ${stopwatch.elapsedMilliseconds}');
    if (formatted.isNotEmpty) sb.writeln(formatted);
    if (deepReadBlock.isNotEmpty) {
      sb.writeln();
      sb.writeln(deepReadBlock);
    }
    sb.writeln('---TOOL RESULT END (search)---');
    final userMsgContent = sb.toString();
    // v1.7.35 修复（用户第7条反馈）：不再把 rawResp 写进 assistantMsg.content。
    // 此前 amsg.content = rawResp 会把含 <thinking> 的原始输出直接显示在
    // 答案气泡里（"第一轮思考过程出现在结论中"），且会被中途节流保存持久化。
    // 搜索轮的 UI 应只显示思考面板（reasoningSteps），content 留给最终 <answer>。
    final convId = pc.userMsg?.conversationId ?? pc.assistantMsg.conversationId;
    final u = ChatMessage.create(
      conversationId: convId,
      role: MessageRole.user,
      content: userMsgContent,
    );
    pc.addMessage(u);
  }
}

class DownloadPlugin extends ReActPlugin {
  @override
  String get triggerType => 'download';

  @override
  RegExp? get legacyTrigger => RegExp(
      r'(帮我|我要|给我)?下载\s*(安装包|apk)?\s*[：:]?\s*(.+?)(安装包|apk)?\s*[。.!！?？]?$',
      caseSensitive: false);

  @override
  PluginSource get source => PluginSource.system;

  @override
  PluginMetadata get metadata => const PluginMetadata(
        id: 'nexus.builtin.download',
        name: '文件与应用下载',
        version: '1.6.8',
        author: 'Nexus Team',
        description:
            '支持 APP 搜索下载（catalog/GitHub/联网）、通用文件按类型搜索下载、URL 直链下载三种子模式。',
        homepage: 'https://nexus.local/plugins/download',
        minAppVersion: '1.6.8',
        tags: ['内置', '下载', '文件', 'APP'],
        extra: {'notWhen': '用户只是咨询"是什么/怎么手动安装/哪里找官网"，没让你帮他下载'},
        promptProtocol: '''
【下载工具】使用说明：
- 使用场景：用户请求下载 APP 安装包、图片、视频、文档、PDF、压缩包等任何需要"保存到本地文件"的内容。
- ⚠️ 核心规则：只要识别出下载意图，【必须】输出 <download> 标签触发下载流程。【禁止】用 <answer> 文字回复"请去官网下载"代替——那样用户什么也下载不到。
- 协议格式：<download intent="true|false" canonical="应用通用名" keywords="关键词1,关键词2,关键词3" domains="官域1,官域2" platform="android|pc" url="直链URL" type="app|pdf|mp4|jpg|doc|any" query="文件名关键词" />
- 字段类型与默认值：所有字段都是 XML 属性字符串；intent 默认 false，仅 true/1/yes/是视为执行下载；canonical、keywords、domains、url、query 默认空字符串；platform 缺省默认 android，只接受 android 或 pc；type 缺省 app，type="download" 也按 app 处理。keywords 与 domains 使用英文逗号或中文逗号分隔。
- 三种互斥调用方式（每次只走一条）：
  ① URL 直链下载：url 为以 http 开头的 URL；url 优先，其他字段可省略，type 默认 app。
  ② 通用文件搜索下载：type 不能为 app 且 query 非空；type 使用文件类型字符串（如 pdf、mp4、jpg、doc、any），query 是非空文件名或检索关键词。
  ③ APP 搜索下载：type="app" 或省略 type，intent="true"，canonical 填应用通用名，keywords 填一个或多个检索关键词，domains 填官方域名（可为空），platform 填 android 或 pc。
- 信息不足策略：若应用名、文件名、直链 URL 或其他必要下载目标不明确，先输出 <ask_user> 补齐信息，再输出 <download>；不要用 <answer> 代替。用户未说明平台不算信息不足，直接使用 platform="android"。只有用户明确要求选择平台，或明确存在 Android/PC 平台分歧且需要用户决定时，才输出 <ask_user> 询问平台。
- 示例 1：下载微信 APP 安卓版
  <download intent="true" canonical="微信" keywords="微信,WeChat APK,微信安卓版" domains="weixin.qq.com" platform="android" />
- 示例 2：2026 年 PDF 报告"年度技术白皮书"
  <download intent="true" type="pdf" query="2026 年度技术白皮书 pdf" />
- 示例 3：下载直链 https://example.com/some-app.apk
  <download intent="true" url="https://example.com/some-app.apk" />
- ❌ 错误做法：用 <answer>回复"您可以去官网下载"——用户无法直接下载。
- ✅ 正确做法：输出 <download intent="true" canonical="..." ... /> 标签，系统会自动搜索来源并弹出下载确认面板。
- 非下载意图 → intent="false"，将被忽略不执行任何操作。
''',
      );

  @override
  Future<void> handle(BuildContext context, PluginContext pc,
      Map<String, dynamic> attrs) async {
    final isZh =
        pc.userMsg?.content.contains(RegExp(r'[\u4e00-\u9fff]')) ?? true;
    final dlUrl = (attrs['url'] as String? ?? '').trim();
    final userMsg = pc.userMsg;
    final amsg = pc.assistantMsg;
    // v1.6.9 build42：legacyTrigger（用户输入纯文本"下载微信"，禁用 ReAct 老流程或 registry dispatch legacy）
    //   从 attrs['legacyMatch'] RegExpMatch 捕获组解析 keyword，而不是依赖 XML 属性。
    //   DownloadPlugin.legacyTrigger = (帮我|我要|给我)?下载\s*(安装包|apk)?\s*[：:]?\s*(.+?)(安装包|apk)?\s*[。.!！?？]?$
    //   group(3) = 用户要的核心关键词（"微信"）。
    final legacy = attrs['legacyMatch'] as RegExpMatch?;
    String legacyKeyword = '';
    if (legacy != null) {
      final g = legacy.group(3)?.trim() ?? '';
      // 去掉首尾的"安装包/apk/应用"后缀残留
      legacyKeyword = g
          .replaceAllMapped(
              RegExp(r'^(安装包|apk|应用)\s*|\s*(安装包|apk|应用)$',
                  caseSensitive: false),
              (_) => '')
          .trim();
    }

    if (dlUrl.isNotEmpty && dlUrl.startsWith('http')) {
      pc.setAnswered(true);
      pc.logger.info('[DL] ReAct trigger direct URL: $dlUrl');
      pc.addReasoningStep(
          'download',
          isZh
              ? '📥 确认直链下载：${_ellipse(dlUrl, 80)}'
              : '📥 Direct download: ${_ellipse(dlUrl, 80)}');
      // v1.7.35 修复：不写 amsg.content = rawResp（思考会漏进结论），
      // 下载流程随后会自行设置干净的进度/结果文案。
      await pc.genericDownload(dlUrl, amsg);
      return;
    }

    // v1.7.9 (M15 修复)：优先读 type_attr
    // parser 片段自带 'type': 'download' 键（片段类型），旧写法 `attrs['type'] ?? attrs['type_attr']`
    // 永远先命中 'download' → AI 显式输出的 type="pdf|mp4|..." 永不生效，文件类型过滤全部失效
    final dlType =
        (attrs['type_attr'] as String? ?? attrs['type'] as String? ?? 'app')
            .toLowerCase()
            .trim();
    final dlQuery = (attrs['query'] as String? ?? '').trim();

    // 'download' 是片段类型而非文件类型 → 视为 app 下载
    final effectiveDlType = dlType == 'download' ? 'app' : dlType;

    if (effectiveDlType != 'app' && dlQuery.isNotEmpty) {
      pc.logger.info(
          '[DL] ReAct trigger file search: type=$effectiveDlType query=$dlQuery');
      pc.addReasoningStep(
          'download',
          isZh
              ? '📥 确认是「$effectiveDlType 文件」下载请求，搜索「$dlQuery」...'
              : '📥 Download file type=$effectiveDlType query="$dlQuery"...');
      final userText = userMsg?.content ?? dlQuery;
      await pc.presentFileSources(
        userText: userText,
        query: dlQuery,
        fileType: effectiveDlType,
        existingUserMsg: userMsg,
        existingPlaceholder: amsg,
      );
      return;
    }

    final intentRaw = (attrs['intent'] as String? ?? '').toLowerCase().trim();
    final canonical =
        (attrs['canonical'] as String? ?? attrs['content'] as String? ?? '')
            .trim();
    final keywordsRaw = (attrs['keywords'] as String? ?? '').trim();
    final domainsRaw = (attrs['domains'] as String? ?? '').trim();
    final platform = ((attrs['platform'] as String? ?? '').trim().isNotEmpty
            ? attrs['platform'] as String
            : 'android')
        .toLowerCase();
    final altKeywords = keywordsRaw
        .split(RegExp(r'[,，]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty && e != canonical)
        .toList(growable: false);
    final officialDomains = domainsRaw
        .split(RegExp(r'[,，]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    var keyword = canonical;
    if (keyword.isEmpty) {
      keyword = altKeywords.isNotEmpty ? altKeywords.first : '';
    }
    // v1.6.9 build42：legacy 兜底：用户直接输入"下载微信"时 legacyMatch 给出 keyword
    if (keyword.isEmpty && legacyKeyword.isNotEmpty) {
      keyword = legacyKeyword;
    }
    // legacy 场景下默认 intent=true（因为 legacyTrigger 匹配到了就代表用户明确有下载意图）
    var intentTrue = intentRaw == 'true' ||
        intentRaw == '1' ||
        intentRaw == 'yes' ||
        intentRaw == '是';
    if (!intentTrue && legacy != null && keyword.isNotEmpty) {
      intentTrue = true;
    }
    if (!intentTrue) {
      // 没有下载意图 = 正常回答轮里这个标签根本没出现，静默跳过是对的
      return;
    }
    if (keyword.isEmpty) {
      // build145 #7(b)：**有意图却没关键词**不能静默 return —— 旧写法让模型以为
      // 下载已经触发，用户只看到「点了没反应」，日志里也一个字没有（静默 = 不可排查）。
      // 这里补一条可见的失败步骤 + 一条 toolresult 告诉模型「缺什么、怎么办」。
      final step = pc.addReasoningStep('download',
          _wsIsZh(pc) ? '缺少下载关键词' : 'Missing download keyword',
          status: 'failed');
      pc.updateReasoningStep(step,
          status: 'failed',
          resultSummary: _wsIsZh(pc) ? '参数不足' : 'missing argument');
      pc.addMessage(ChatMessage.create(
        conversationId: pc.assistantMsg.conversationId,
        role: MessageRole.user,
        // build146 ③：外壳统一走 toolResultTag（本条正文是宿主自撰文案，
        // 但同一套转义 + trust="untrusted" 口径不该按调用点分叉）
        content: toolResultTag(
          pluginId: 'nexus.builtin.download',
          tool: 'download',
          attrs: const {'status': 'failed'},
          body: _wsIsZh(pc)
              ? '缺少下载关键词：请给出要下载的软件名或直链（如 download keyword="微信"）。'
              : 'Missing download keyword: provide an app name or a direct URL.',
        ),
      ));
      return;
    }
    pc.setAnswered(true);
    final userText = userMsg?.content ?? keyword;
    final isPC = platform == 'pc';
    final thinkLabel = isZh
        ? (isPC
            ? '📥 确认「$keyword」（电脑端）下载请求，正在准备来源...'
            : '📥 确认「$keyword」（手机端）下载请求，正在准备来源...')
        : (isPC
            ? '📥 Confirmed APP download "$keyword" (PC), preparing sources...'
            : '📥 Confirmed APP download "$keyword" (Android), preparing sources...');
    pc.logger.info(
        '[DL] ReAct trigger app search: keyword=$keyword platform=$platform alt=${altKeywords.length} domains=${officialDomains.length}');
    pc.addReasoningStep('download', thinkLabel);
    await pc.presentAppDownloadSources(
      userText: userText,
      keyword: keyword,
      altKeywords: altKeywords,
      officialDomains: officialDomains,
      existingUserMsg: userMsg,
      existingPlaceholder: amsg,
      platform: platform,
    );
  }
}

class AskUserPlugin extends ReActPlugin {
  // build93(S2)：选项上限；build127：兜底切分复用同一组上限做"像不像选项"判定，
  // 避免两处魔数各自漂移。
  // build140（反馈⑦）：三个上限的**唯一来源**挪到 `utils/ask_user_option.dart`
  //（清洗现在逐字段做：标题 / 说明分别截断）。这里只转发，不留第二个魔数。
  static const int kMaxOptionChars = AskUserOption.maxTitleChars;
  static const int kMaxOptions = AskUserOption.maxOptions;
  // build127：无选项时，问题超过该长度即判为"不像提问"（思考残留），不弹面板。
  static const int kMaxQuestionChars = 120;

  // build93(S2)：选项清洗——截 30 字、去重、上限 8 条。
  // build139（真机反馈④）：**只剩 1 条不再丢空**。原来清洗后 <2 条一律返回空列表，
  // 于是「模型只给了一个选项」与「模型压根没给选项」这两种情况在面板上长得一模一样
  // （都只剩输入框）——用户看到的正是「反问的推荐用不了」。而唯一选项恰恰是可点的答案，
  // 丢掉它没有任何收益：build127 担心的是"思考碎片被切成一堆假选项"，那由
  // 兜底切分的 2~8 条上限与 `kMaxQuestionChars` 闸门管，与这里无关。
  // build140（反馈⑦）：整条清洗走 `AskUserOption.cleanWires`——线格式仍是 List<String>，
  // 但单个选项现在可以带 `::说明` 与 `::推荐`。
  // ⚠️ 教训 #166：清洗链只许这一条实现，下游不许各自按分隔符切一刀兜一手。
  static List<String> cleanOptions(List<String> options) =>
      AskUserOption.cleanWires(options);

  /// build127：清掉混进标签体的 XML 残留，且**保留换行**（v1.7.7 兜底切分依赖换行）。
  /// 真机证据（2026-09-18 导出日志）：<ask_user> 未闭合时，标签体会把前缀的
  /// <thinking> 整段一起收进来，旧逻辑于是拿思考片段当标题、按换行切出 12 段当选项。
  static String sanitizePayload(String raw) {
    var s = raw;
    final thinkEnd = s.lastIndexOf('</thinking>');
    if (thinkEnd >= 0) s = s.substring(thinkEnd + '</thinking>'.length);
    return s.replaceAll(RegExp(r'<[^>]{1,60}>'), ' ').trim();
  }

  /// build139：**提问框没能展示给用户**（UI 抛异常 / 宿主未注入回调 / 页面已销毁）
  /// 时的降级指令，与 [_injectDeclined] 严格分开。
  ///
  /// 三条区别是有意的：① 如实告知"用户没看到问题"，不让模型以为自己被拒绝；
  /// ② 本轮同样禁止再问（否则换个措辞接着弹，故障被放大成骚扰），但**下一轮**
  /// 允许 —— 因为这不是用户的意愿，而 [_injectDeclined] 的"永久禁止"前提是用户确实答过；
  /// ③ 要求把未确认的假设写进 <answer>，用户才看得见缺了什么。
  void _injectAskUiFailure(PluginContext pc, bool isZh) {
    final text = isZh
        ? '提问组件本次未能显示给用户（应用侧故障，用户没有看到问题，也没有拒绝）。'
            '本轮禁止再次使用 <ask_user>；必须基于现有信息给出 <answer>，'
            '并在其中写明你做了哪些未确认的假设，用户下次可以补充。'
        : 'The question could not be shown to the user (app-side failure; the user '
            'neither saw nor declined it). Do NOT use <ask_user> again in this turn; '
            'give the final <answer> from available information and state explicitly '
            'which assumptions remain unconfirmed, so the user can correct them next turn.';
    // 不新增含 emoji 的行：R1 棘轮按「含 emoji 的行数」逐行计数（见 [_injectDeclined] 注释）。
    pc.appendReasoning(isZh
        ? '提问未能显示（应用侧故障，用户没有拒绝）'
        : 'Question not displayed (app-side failure; the user did not decline)');
    final convId = pc.userMsg?.conversationId ?? pc.assistantMsg.conversationId;
    pc.addMessage(ChatMessage.create(
      conversationId: convId,
      role: MessageRole.user,
      content: isZh
          ? '（系统提示，非用户输入）：$text'
          : '(System note, not user input): $text',
    ));
  }


  /// build127：把 O1（build95）的"用户拒绝补充"收口指令抽成单一实现，
  /// 供「用户真跳过」与「提问无效被跳过」两种情形复用，避免长文案两处各自漂移。
  void _injectDeclined(PluginContext pc, bool isZh) {
    final text = isZh
        ? '用户已拒绝补充该信息。禁止就同一缺口再次使用 <ask_user> 反问（换措辞也不行）；'
            '必须基于现有信息直接给出最终答复（<answer>）；若信息确实不足，'
            '在 <answer> 中明确说明缺什么、当前结论是什么。'
        : 'The user declined to provide this information. Do NOT use <ask_user> '
            'again for the same missing information (rephrasing does not count as new); '
            'give the final <answer> based on available information, explicitly stating '
            'what is missing if you cannot be certain.';
    // 注意：这里保持**单行** —— R1 棘轮按「含 emoji 的行数」计数（tools/v2_ui_audit.py
    // 的 EMOJI 逐行匹配），把 ? : 拆成两行会被判成新增违规（build128 踩过）。
    // 写法与下方「你的回复」注入那处保持一致。
    pc.appendReasoning(isZh ? '🚫 用户跳过了提问（禁止就同一缺口再反问）' : '🚫 User skipped (no re-ask for the same gap)');
    final convId = pc.userMsg?.conversationId ?? pc.assistantMsg.conversationId;
    pc.addMessage(ChatMessage.create(
      conversationId: convId,
      role: MessageRole.user,
      content: isZh
          ? '（用户回复 AI 的提问）：$text'
          : '(Reply to AI\'s question): $text',
    ));
  }

  @override
  String get triggerType => 'ask_user';

  @override
  RegExp? get legacyTrigger => null;

  @override
  PluginSource get source => PluginSource.system;

  @override
  PluginMetadata get metadata => const PluginMetadata(
        id: 'nexus.builtin.ask_user',
        name: 'AI 反问用户',
        version: '1.6.8',
        author: 'Nexus Team',
        description: '当 AI 遇到信息不足、多选决策时，用 <ask_user> 标签弹选项面板向用户提问澄清。',
        homepage: 'https://nexus.local/plugins/ask_user',
        minAppVersion: '1.6.8',
        tags: ['内置', '交互', '反问'],
        extra: {'notWhen': '信息已足够回答时，不要没话找话弹选项'},
        promptProtocol: '''
【反问工具】使用说明：
- 当信息不足以推进下一步时（如：下载 APP 不知道用户想要手机版还是电脑版），反问用户。
- ⚠️ 核心规则：<ask_user> 标签内【必须】包含"问题 + 2~8 个选项"，问题与选项、选项与选项之间用"两个竖线 ||"分隔。【禁止】只写问题不带选项——那样用户只能手动打字，体验差。
- ⚠️ 克制反问：能力边界/方法咨询类问题（如"你能帮我安装 X 吗""X 怎么用"）请直接如实回答并给出操作步骤，【不要】为此反问；只有真正缺少无法推断的必要信息（应用名、URL、格式等）且会改变行动方案时才反问。
- 协议格式：<ask_user>问题文案||选项1文案||选项2文案||选项3文案...</ask_user>
- 选项还可以各带两段可选后缀，用"两个冒号 ::"分隔：`标题::一行说明::推荐`。
  - 说明写给"看不懂这两个选项差别"的人看，一句话、别超过 60 字；标题仍限 30 字。
  - 只有**一个**你认为最合适的选项才写 `::推荐`（写两条等于没推荐）。
  - 顺序固定为「标题 → 说明 → 推荐」，不想要说明但想要推荐时写 `标题::::推荐`。
  - 旧写法（不带 ::）完全照旧可用，不要为了用新功能而把没有说明的选项硬凑一段。
- 示例 1：
  <ask_user>你想要下载微信的哪个版本？||手机版 Android::装机量最大，功能最全::推荐||电脑版 Windows::需在官网下载 exe||电脑版 Mac::Apple 芯片与 Intel 芯片安装包不同</ask_user>
- 示例 2：
  <ask_user>请问报告需要什么格式？||PDF 文档::排版固定，适合直接发给别人::推荐||Word 文档::对方还要继续改内容时选这个||Markdown 源码::纯文本，方便进版本库</ask_user>
- ❌ 错误做法：只写 <ask_user>你想要哪个版本？</ask_user>（没有选项按钮，用户只能打字）。
- ✅ 正确做法：<ask_user>你想要哪个版本？||手机版||电脑版</ask_user>（有选项按钮可一键点选）。
- 工具会把用户的最终选择以"用户消息"形式注入工作上下文，你在下一轮中直接用用户回复继续。
''',
      );

  @override
  Future<void> handle(BuildContext context, PluginContext pc,
      Map<String, dynamic> attrs) async {
    final isZh =
        pc.userMsg?.content.contains(RegExp(r'[\u4e00-\u9fff]')) ?? true;
    // build127：先清洗标签体再解析（剥离 </thinking> 前缀与 XML 残留）。
    final content = AskUserPlugin.sanitizePayload(
        (attrs['content'] as String? ?? '').trim());
    if (content.isEmpty) return;
    final parts = content
        .split('||')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (parts.isEmpty) return;
    var questionText = parts.first;
    var options = parts.length > 1 ? parts.sublist(1) : <String>[];
    // v1.7.7 兜底：AI 没用 || 分隔时（只写问题或用别的分隔符），尝试换行/分号/顿号提取选项。
    // build127 加固：兜底结果必须"像选项"才接受——2~8 条且每条 ≤30 字（与 cleanOptions 同组上限）。
    // 旧逻辑只要切出 ≥2 段就全盘接受，而 cleanOptions 只会截 30 字/留 8 条，
    // 于是 12 段思考碎片被"清洗"成 8 个看似正常的选项 ⇒ 用户看到标题与选项全错。
    if (options.isEmpty) {
      final fallbackParts = content
          .split(RegExp(r'[\n;；]'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      final looksLikeOptions = fallbackParts.length >= 2 &&
          fallbackParts.length <= AskUserPlugin.kMaxOptions &&
          fallbackParts.every((e) => e.length <= AskUserPlugin.kMaxOptionChars);
      if (looksLikeOptions) {
        questionText = fallbackParts.first;
        options = fallbackParts.sublist(1);
        pc.logger.info(
            '[AskUser] fallback separator parsed ${options.length} options',
            tag: 'Plugin');
      } else if (fallbackParts.length >= 2) {
        pc.logger.warn(
            '[AskUser] 兜底切分被拒：切成 ${fallbackParts.length} 段'
            '（最长 ${fallbackParts.fold<int>(0, (m, e) => e.length > m ? e.length : m)} 字），'
            '不像选项，疑似 thinking 泄漏',
            tag: 'Plugin');
      }
    }
    // build127：无选项且问题本身不像提问（过长 ⇒ 思考残留）⇒ 不弹面板。
    // 走与"用户跳过"同一条降级路径，把收口指令明确交给模型：
    // 既避免把思考片段当问题展示，也避免模型换个措辞就同一缺口继续反问。
    // build139（全量扫描）：这条闸门原来**只在 options 为空时**生效，而"只剩 1 条
    // 不再整组丢空"上线后，一段含一个 `||` 的思考碎片就能同时产出"超长问题 +
    // 一条被截到 30 字的垃圾选项" ⇒ 用户点下去把碎片当答案发回去。
    // 判据不变（问题长度才是"像不像提问"的信号），只是不再因为"恰好有一条选项"
    // 就跳过检查；正常的一选项反问（问题短）完全不受影响。
    if (options.length <= 1 &&
        questionText.length > AskUserPlugin.kMaxQuestionChars) {
      pc.logger.warn(
          '[AskUser] 提问无效已跳过（选项 ${options.length} 条且问题长 '
          '${questionText.length} 字，疑似思考残留）',
          tag: 'Plugin');
      _injectDeclined(pc, isZh);
      return;
    }
    // build93(S2)：选项清洗——去重、≤30字、2~8 条；清洗后不足 2 条则不渲染按钮只留输入框
    options = AskUserPlugin.cleanOptions(options);
    // build140（反馈⑦）：这行摘要**只放标题**。清洗后的选项串可能带 `::说明`，
    // 原样 join 会把说明文字灌进思考面板那一行（也灌进给模型的上下文），
    // 面板要的是"问了什么、给了哪几个选项"，不是一篇小作文。
    final pcContent =
        '$questionText${options.isNotEmpty ? ' [${AskUserOption.titles(options).join(' / ')}]' : ''}';
    final askStep = pc.addReasoningStep('ask_user', pcContent);
    pc.appendReasoning(
        isZh ? '❓ AI 想问你：$questionText' : '❓ AI asks: $questionText');
    final reply = await pc.showAskUser(questionText, options);
    // O1（build95）：用户跳过时不再注入模棱两可的「(用户跳过了这个问题)」
    // ——模型看到后会换着措辞就同一缺口反复反问。改为明确指令：
    // 拒绝补充 + 禁止就同一缺口再次 ask_user + 必须基于现有信息直接作答。
    // build127：指令文本抽到 _injectDeclined，与"提问无效被跳过"共用同一实现。
    // build139：区分「用户真的跳过」与「提问框根本没弹出来」（UI 异常/回调缺失）。
    // 后者绝不能沿用前者的文案 —— 那等于向模型伪造用户意图（用户从未被问到）。
    if (pc.lastAskUserFailed) {
      _injectAskUiFailure(pc, isZh);
      return;
    }
    if (reply == null || reply.trim().isEmpty) {
      _injectDeclined(pc, isZh);
      return;
    }
    final finalReply = reply;
    // build140（反馈⑦ 第 2 条「答后摘要」）：把「你答了什么」写回**同一个** ask_user 步骤。
    // 为什么塞进 reasoningSteps 而不是新开字段：`ChatMessage.toMap` 本来就把整列
    // reasoningSteps 存进现有列 ⇒ **零迁移**（新列要走 DB 五保险 + 迁移四同步，
    // 而这里要的只是"同一对数据换个地方存"）。渲染侧见
    // `message_bubble_v2.dart` 的 ask_user 节点分支。
    pc.updateReasoningStep(askStep, resultSummary: finalReply);
    pc.appendReasoning(
        isZh ? '📩 你的回复：$finalReply' : '📩 Your reply: $finalReply');
    final convId = pc.userMsg?.conversationId ?? pc.assistantMsg.conversationId;
    final pcRole = ChatMessage.create(
      conversationId: convId,
      role: MessageRole.user,
      content: isZh
          ? '（用户回复 AI 的提问）：$finalReply'
          : '(Reply to AI\'s question): $finalReply',
    );
    pc.addMessage(pcRole);
  }
}

class SelfCheckPlugin extends ReActPlugin {
  @override
  String get triggerType => 'self_check';

  @override
  RegExp? get legacyTrigger => null;

  @override
  PluginSource get source => PluginSource.system;

  @override
  PluginMetadata get metadata => const PluginMetadata(
        id: 'nexus.builtin.self_check',
        name: 'AI 自我终止判定',
        version: '1.6.8',
        author: 'Nexus Team',
        description: '系统每 20 秒自动注入一次自检消息；AI 输出 <self_check> 判定是否停止思考，避免死循环卡壳。',
        homepage: 'https://nexus.local/plugins/self_check',
        minAppVersion: '1.6.8',
        tags: ['内置', '自检', '安全'],
        promptProtocol: '''
【自检工具】使用说明：
- 当你在工作区看到"[系统自检]"消息时，必须输出 <self_check> 标签判定下一步。
- 格式：<self_check continue="true|false" reason="简要说明原因" />
  - continue=true：继续思考或搜索。
  - continue=false：信息已经足够或超过最大轮次，停止思考并总结答案。
- 示例 1（继续）：<self_check continue="true" reason="搜索结果还不够明确，需要再补充一次关键词查询" />
- 示例 2（终止）：<self_check continue="false" reason="信息已齐，输出最终答案" />
- 判定为 false 后，建议紧跟 <answer>...</answer> 标签给出最终回复。
''',
      );

  @override
  Future<void> handle(BuildContext context, PluginContext pc,
      Map<String, dynamic> attrs) async {
    final isZh =
        pc.userMsg?.content.contains(RegExp(r'[\u4e00-\u9fff]')) ?? true;
    final cont = (attrs['continue'] as String? ?? 'true').toLowerCase().trim();
    final reason = (attrs['reason'] as String? ?? '').trim();
    final shouldStop = cont != 'true';
    final actionLabel = isZh
        ? (shouldStop ? '⏹️ 应终止思考' : '▶️ 应继续思考')
        : (shouldStop ? '⏹️ STOP thinking' : '▶️ CONTINUE thinking');
    final reasonLabel = reason.isNotEmpty ? '（$reason）' : '';
    pc.addReasoningStep('self_check', '$actionLabel$reasonLabel');
    pc.appendReasoning(isZh
        ? (shouldStop
            ? '⏹️ AI 自检判定：应终止思考。$reasonLabel'
            : '✅ AI 自检判定：继续思考。$reasonLabel')
        : (shouldStop
            ? '⏹️ Self-check: STOP thinking. $reasonLabel'
            : '✅ Self-check: CONTINUE thinking. $reasonLabel'));
    if (shouldStop) {
      pc.logger.info(
          '[Chat] AI self-check said STOP (reason: ${reason.isEmpty ? "none" : reason})');
      pc.requestStopLoop();
    }
  }
}

class AnswerPlugin extends ReActPlugin {
  @override
  String get triggerType => 'answer';

  @override
  RegExp? get legacyTrigger => null;

  @override
  PluginSource get source => PluginSource.system;

  @override
  PluginMetadata get metadata => const PluginMetadata(
        id: 'nexus.builtin.answer',
        name: '最终答案输出',
        version: '1.6.8',
        author: 'Nexus Team',
        description:
            '当 AI 认为无需进一步思考/搜索时，输出 <answer> 标签结束 ReAct 循环并将正文作为最终回复给用户。',
        homepage: 'https://nexus.local/plugins/answer',
        minAppVersion: '1.6.8',
        tags: ['内置', '输出', 'ReAct'],
        promptProtocol: '''
【最终答案】使用说明：
- 当你准备好给出用户的最终回复时，使用 <answer>...</answer> 把内容包住。
- 支持完整 Markdown：标题、列表、代码块、引用、表格、加粗、斜体、链接、图片。
- 如果前面做了搜索，可以在答案正文中引用搜索到的链接、来源名称。
- 示例：
  <answer>
  ## Flutter 3.x 在 2026 年的三大特性
  1. ...
  2. ...
  参考链接：[搜索命中的标题](https://example.com/x)
  </answer>
- 输出 <answer> 后循环立即结束，不会再让你思考，所以请确保把需要表达的内容一次写完。
- 语言跟随用户：用户用中文回答中文，用户用英文回答英文，不要中英混杂。
''',
      );

  @override
  Future<void> handle(BuildContext context, PluginContext pc,
      Map<String, dynamic> attrs) async {
    var answer =
        attrs['content'] as String? ?? attrs['answer'] as String? ?? '';
    // v1.7.36：双保险——剥离混入 <answer> 的思考标签，防止推理过程泄漏进最终答案
    answer = answer
        .replaceAll(
            RegExp(r'<(?:thinking|think)>[\s\S]*?</(?:thinking|think)>',
                caseSensitive: false),
            '')
        .replaceAll(RegExp(r'</?(?:thinking|think)>', caseSensitive: false), '')
        .trim();
    // v1.7.36+：弱模型误用子代理编排标签时的兜底清洗——
    // 这些标签属于内部编排协议，绝不应出现在给用户的最终答案里；
    // 在此清洗可同时保证写入聊天记录的内容是干净的（避免污染后续轮次的上下文示范）。
    // <synthesis>…</synthesis> → 解包为内部内容（模型本意是给结构化答案）
    // build97 (P2-11 修复)：旧实现只保留首个 synthesis 块，块外正文全部丢弃。
    // 标签本身就是给宿主的解包指令，直接剥标签、保留全部内容即可。
    answer = answer
        .replaceAll(RegExp(r'</?synthesis>', caseSensitive: false), '')
        .trim();
    // <queries>…</queries> → 解包，内部 <query> 转成列表行
    if (RegExp(r'<queries>', caseSensitive: false).hasMatch(answer)) {
      answer = answer
          .replaceAll(RegExp(r'</?queries>', caseSensitive: false), '')
          // build97 (P2-10 修复)：replaceAll 不解析 $1 分组，
          // 旧写法正文会原样出现「- $1」且搜索词被吞，必须用 replaceAllMapped。
          .replaceAllMapped(
              RegExp(r'<query>([\s\S]*?)</query>',
                  caseSensitive: false),
              (m) => '- ${(m.group(1) ?? '').trim()}')
          .trim();
    }
    // 自闭合的 <route …/> 与 <plugin_call …/> 在答案里无意义 → 直接删除
    answer = answer
        .replaceAll(RegExp(r'<route\s[^>]*/?>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<plugin_call\s[^>]*/?>', caseSensitive: false), '')
        .trim();
    await pc.saveAssistantContent(force: false);
    pc.finalizeAnswer(answer,
        injectedWebSearchCount: pc.totalSearchHits, forceSave: true);
  }
}

/// v1.7.38（build90 第 3 步）：<card> 富交互卡片协议插件。
///
/// 卡片标签由 AI 放在 <answer> 正文里、气泡端提取渲染（见
/// interact_card.dart），本插件只负责把协议说明注入主提示词；
/// handle 仅在 AI 把卡片误放到 <answer> 外时留一个可见节点提醒。
class CardPlugin extends ReActPlugin {
  @override
  String get triggerType => 'card';

  @override
  RegExp? get legacyTrigger => null;

  @override
  PluginSource get source => PluginSource.system;

  @override
  PluginMetadata get metadata => const PluginMetadata(
        id: 'nexus.builtin.card',
        name: '富交互卡片',
        version: '1.7.38',
        author: 'Nexus Team',
        description: 'AI 输出 <card> 标签时，聊天流内渲染原生交互卡片（比价/订单/支付确认），对标千问对话内小屏幕。',
        homepage: 'https://nexus.local/plugins/card',
        minAppVersion: '1.7.38',
        tags: ['内置', '卡片', '交互'],
        extra: {'notWhen': '普通文字对话/回答，只有比价/订单/支付确认场景才用卡片'},
        promptProtocol: '''
【富交互卡片】使用说明：
- 使用场景：调工具拿到结构化数据（比价/订单/支付）时，在 <answer> 正文里输出卡片标签，宿主渲染成原生卡片供用户直接点选，不再只吐纯文本。
- 协议格式（必须放在 <answer> 内，JSON 单行且合法，可同时输出多张）：
  <card type="options" title="打车比价">{"options":[{"label":"经济型","price":"¥12.5","detail":"预计3分钟接驾"},{"label":"舒适型","price":"¥18.0","detail":"预计5分钟接驾"}]}</card>
  <card type="order" title="订单状态">{"rows":[{"k":"状态","v":"司机已接单"},{"k":"距离","v":"1.2km"}]}</card>
  <card type="pay" title="支付确认">{"amount":"¥25.00","payee":"滴滴出行","url":"https://example.com/pay"}</card>
- 三类卡片：options=选项/比价卡（options 数组，label 必填，price/detail 可选）；order=订单/状态卡（rows 数组，k/v 键值对）；pay=支付确认卡（amount/payee/url）。
- 交互闭环：用户在 options 卡点选后，会以「我选择：X」作为用户消息发回给你，请据此继续下一步流程（如调工具下单）。
- 安全铁律：pay 卡只用于展示和跳转确认，绝不声称已完成支付；下单/支付等敏感动作前必须先获得用户在卡片或对话中的明确确认。
''',
      );

  @override
  Future<void> handle(BuildContext context, PluginContext pc,
      Map<String, dynamic> attrs) async {
    final isZh = pc.userMsg?.content.contains(RegExp(r'[一-龥]')) ?? true;
    pc.addReasoningStep(
      'card',
      isZh
          ? '卡片标签出现在 <answer> 之外，不会渲染；请在答案正文内输出卡片'
          : 'card tag outside <answer> is not rendered; put cards inside the answer',
      status: 'invalid',
    );
  }
}

/// build99：删除滴滴打车工作流 Skill —— 用户拍板"没什么用"。
/// 叫车能力在滴滴 MCP 本体，Skill 只包装一段提示词规则，
/// 实际"叫车"由用户手动装滴滴 MCP（mcp.didichuxing.com 个人 Key）即可，
/// AI 拿到工具列表会自动用，无需此 Skill。同步清理：
/// - 插件注册项 `_builtinPlugins` 中的 `DidiRidePlugin()`（已删）
/// - MCP 依赖门 `kPromptPluginMcpDeps` 中仅剩这一项条目（已删）
/// - 旧 build91 D2 的设计注释保留用于交接溯源
///
/// 历史：
/// - build97：只装 Skill 不装 MCP → AI 复述流程不执行，已通过依赖门临时缓解
/// - build98：实测介绍浮夸（"全链路规则"暗示有打车能力） + 引用过时工具名
///   `taxi_generate_ride_app_link`（官方文档是 `taxi_new_order`）
/// - build99：删除（用户拍板）
///
/// 保留常量 `kPromptPluginMcpDeps`（空表）以维持 chat_screen_react.dart 的
/// 依赖门检测逻辑不报错——若未来再新增纯提示词插件 + MCP 依赖，填回此处即可
const Map<String, String> kPromptPluginMcpDeps = {};

/// v1.7.39（build92）：推荐后续问题插件。
///
/// 协议：<suggest>问题1||问题2||问题3</suggest>，配对标签放在 </answer> 之后。
/// 标签由宿主层（chat_screen_react.dart）直接提取到 assistantMsg.suggestions 渲染可点击气泡，
/// 不走 dispatch——本插件只负责提示词注入，handle 永不调用。
class SuggestPlugin extends ReActPlugin {
  @override
  String get triggerType => 'suggest';

  @override
  RegExp? get legacyTrigger => null;

  @override
  PluginSource get source => PluginSource.system;

  @override
  PluginMetadata get metadata => const PluginMetadata(
        id: 'nexus.builtin.suggest',
        name: '推荐追问',
        version: '1.7.39',
        author: 'Nexus Team',
        description: '回答后推荐 2-4 个用户可能想问的后续问题，渲染为可点击气泡，点击直接发送。',
        homepage: 'https://nexus.local/plugins/suggest',
        minAppVersion: '1.7.39',
        tags: ['内置', '推荐', '交互'],
        extra: {'notWhen': '用户问题已完全闭环（如简单问候、明确结束话题）时，不要硬凑推荐'},
        promptProtocol: '''
【推荐追问】使用说明：
- 使用场景：给出 <answer> 后，预判用户最可能接着问的 2-4 个后续问题，用 <suggest> 标签输出。
- 硬性要求（build94/P4）：只要本轮回答不是完全闭环（简单问候/明确结束话题除外），就必须在 </answer> 之后输出 <suggest>；不要把推荐写进 <answer> 正文里口头带一句——宿主只认 <suggest> 标签，写进正文等于没给。
- 时机（build140/反馈⑤）：<suggest> 必须与 </answer> **在同一次回复里、紧挨着**输出，
  中间不要插入 thinking、不要另起一轮、不要等用户追问才给。
  宿主是「解析到就立刻画推荐气泡」的口径 ⇒ 你和结论同一次给完，用户就和结论同屏看到；
  留到下一轮再给，等于这一轮没有推荐。
- 协议格式（必须放在 </answer> 之后，多个问题用 || 分隔，每条 ≤30 字）：
  <suggest>它和X有什么区别？||给我一个具体例子||怎么应用到我的场景？</suggest>
- 问题必须是用户视角的追问（用户会点发送），不要写成"我可以帮你……"的 AI 口吻。
- 每条都要能直接用当前上下文回答或推进，不要推荐需要用户补充大量信息的问题。
''',
      );

  @override
  Future<void> handle(BuildContext context, PluginContext pc,
      Map<String, dynamic> attrs) async {
    // 标签在宿主层提取，handle 永不调用。
  }
}

/// v1.7.39（build92）：待办清单插件。
///
/// 协议：<todo action="add|done|list|clear" items="事项1||事项2" />（自闭合）。
/// 复杂多步任务时 AI 列待办，渲染成可勾选卡片；完成某步用 action="done" 勾掉。
/// 不落库，纯 UI 状态。
class TodoPlugin extends ReActPlugin {
  @override
  String get triggerType => 'todo';

  @override
  RegExp? get legacyTrigger => null;

  @override
  PluginSource get source => PluginSource.system;

  @override
  PluginMetadata get metadata => const PluginMetadata(
        id: 'nexus.builtin.todo',
        name: '待办清单',
        version: '1.7.39',
        author: 'Nexus Team',
        description: '复杂多步任务时列出待办清单并随进度勾选，让用户看到任务全貌和当前进度。',
        homepage: 'https://nexus.local/plugins/todo',
        minAppVersion: '1.7.39',
        tags: ['内置', '待办', '任务'],
        extra: {'notWhen': '简单问答/一步能完成的任务，列待办反而是噪音'},
        promptProtocol: '''
【待办清单】使用说明：
- 使用场景：任务需要 ≥3 步才能完成时，在动手前先输出 <todo> 列清单，让用户看到全貌。
- 协议格式（自闭合标签，items 内多项用 || 分隔）：
  <todo action="add" items="搜索最新价格||对比三个方案||给出推荐结论" />
  <todo action="done" items="搜索最新价格" />
  <todo action="clear" />
- action：add=增量新增（同名项保留原勾态，不会清空旧项）；done=勾掉已完成项（items 填已完成的那几项）；list=查看当前清单；clear=清空。
- 每次 add/done/clear/list 后，系统都会把当前清单全文（含勾态）回灌给你，你随时能看到清单现状。
- 每完成一步立刻用 done 勾掉，不要攒到最后一起勾。
- 清单项写成动词短语（≤20 字），不要写长句。
- 清单仅在当前这条回复的任务周期内有效。
''',
      );

  @override
  Future<void> handle(BuildContext context, PluginContext pc,
      Map<String, dynamic> attrs) async {
    final isZh = pc.userMsg?.content.contains(RegExp(r'[一-龥]')) ?? true;
    final action = (attrs['action'] as String? ?? 'add').toLowerCase();
    final items = (attrs['items'] as String? ?? '')
        .split('||')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    final list = pc.assistantMsg.todoItems;
    switch (action) {
      case 'add':
        // O11（build96）：add 改增量合并——按 text 归一化去重，已存在项保留
        // done 状态，不再 clear 重建（原来模型想补一项会把旧项全清掉）。
        mergeTodoItems(list, items);
        break;
      case 'done':
        for (final item in items) {
          final needle = item.trim();
          if (needle.isEmpty) continue;
          for (final entry in list) {
            final text = (entry['text'] as String? ?? '').trim();
            // build94：弱模型措辞微偏导致全等匹配勾不上——
            // 先 trim 全等，再退到互相包含匹配
            if (text == needle ||
                (text.isNotEmpty &&
                    (text.contains(needle) || needle.contains(text)))) {
              entry['done'] = true;
            }
          }
        }
        break;
      case 'clear':
        list.clear();
        break;
      case 'list':
        // O11（build96）：list 不再是空实现——下方统一回灌当前清单全文。
        break;
    }
    // O11（build96）：每次 add/done/clear/list 之后，把「当前清单全文（序号+勾态）」
    // 作为 toolresult 回灌 workingMessages——模型下一轮一定看得到现状，
    // 不再盲操作（00:30 日志实测：模型建完清单下一轮就看不见，done 勾不上）。
    final rendered = renderTodoListText(list, isZh: isZh);
    pc.addMessage(ChatMessage.create(
      conversationId:
          pc.userMsg?.conversationId ?? pc.assistantMsg.conversationId,
      role: MessageRole.user,
      // build146 ③：清单条目文本源自模型输出（用户可控），走统一转义外壳
      content: toolResultTag(
        pluginId: 'nexus.builtin.todo',
        tool: action,
        body: rendered,
      ),
    ));
    pc.addReasoningStep(
      'todo',
      isZh
          ? '待办清单：${list.where((e) => e['done'] == true).length}/${list.length} 已完成'
          : 'Todo: ${list.where((e) => e['done'] == true).length}/${list.length} done',
    );
  }
}

/// O11（build96）：add 增量合并——新项按归一化 text 去重追加，
/// 已存在项（含其 done 状态）原样保留。纯函数，可单测。
void mergeTodoItems(List<Map<String, dynamic>> list, List<String> newItems) {
  String norm(String s) => s.trim().toLowerCase();
  final existing = {for (final e in list) norm(e['text']?.toString() ?? '')};
  for (final item in newItems) {
    final key = norm(item);
    if (key.isEmpty || existing.contains(key)) continue;
    list.add({'text': item.trim(), 'done': false});
    existing.add(key);
  }
}

/// O11（build96）：渲染当前清单全文（序号 + [x]/[ ] 勾态），
/// 供 toolresult 回灌与 list 动作返回。纯函数，可单测。
String renderTodoListText(List<Map<String, dynamic>> list,
    {required bool isZh}) {
  if (list.isEmpty) return isZh ? '（清单为空）' : '(list is empty)';
  final buf = StringBuffer(isZh ? '当前待办清单：\n' : 'Current todo list:\n');
  for (var i = 0; i < list.length; i++) {
    final done = list[i]['done'] == true;
    final text = list[i]['text']?.toString() ?? '';
    buf.writeln('${i + 1}. [${done ? 'x' : ' '}] $text');
  }
  return buf.toString().trimRight();
}

/// v1.7.39（build92）：AI 自动写记忆插件。
///
/// 协议：<memory_write scope="global|project" key="..." value="..." />（自闭合）。
/// 用户透露长期偏好/事实（如"我不吃辣""我的手机号是X"）时自动落库，
/// scope=global 写全局记忆（所有对话生效），scope=project 写当前项目记忆。
class MemoryWritePlugin extends ReActPlugin {
  // build93(D1)：自动写只准覆盖 source=auto 且未 pinned 的旧记忆；手动/置顶永不被误删
  static bool autoOverwriteAllowed(String source, bool pinned) =>
      source == 'auto' && !pinned;

  @override
  String get triggerType => 'memory_write';

  @override
  RegExp? get legacyTrigger => null;

  @override
  PluginSource get source => PluginSource.system;

  @override
  PluginMetadata get metadata => const PluginMetadata(
        id: 'nexus.builtin.memory_write',
        name: '自动记忆',
        version: '1.7.39',
        author: 'Nexus Team',
        description: '用户透露长期偏好/事实时自动写入全局或项目记忆，后续对话自动携带。',
        homepage: 'https://nexus.local/plugins/memory',
        minAppVersion: '1.7.39',
        tags: ['内置', '记忆'],
        extra: {'notWhen': '一次性/临时信息（如"今天天气""这次帮我……"），不值得长期记忆'},
        promptProtocol: '''
【自动记忆】使用说明：
- 使用场景：用户主动透露长期有效的偏好/事实（饮食禁忌、常用地址、手机号、工作技术栈等）时，用 <memory_write> 落库。
- 协议格式（自闭合标签，放在 <answer> 之外，不影响回答正文）：
  <memory_write scope="global" key="饮食偏好" value="不吃辣" />
  <memory_write scope="project" key="技术栈" value="Flutter + Dart，状态管理用 Provider" />
- scope：global=跨所有对话生效的偏好/事实；project=仅当前项目相关的上下文（项目不存在时自动降级为 global）。
- key 是简短分类名（≤10 字），value 是一句话事实（≤50 字）；同 key 会覆盖旧值。
- 写完照常回答，不要在 <answer> 里复述"我已记住……"，宿主会提示用户。
- ⚠️ 格式反例（以下写法宿主历史上无法识别，等于没写——实机翻车教训）：
  <memory_write">entries=[{...}]、<memory_write>{json}</memory_write>
  标签名后不能粘引号，负载必须用 scope/key/value 属性，禁止 JSON 数组/对象。
''',
      );

  @override
  Future<void> handle(BuildContext context, PluginContext pc,
      Map<String, dynamic> attrs) async {
    final isZh = pc.userMsg?.content.contains(RegExp(r'[一-龥]')) ?? true;
    final scope = (attrs['scope'] as String? ?? 'global').toLowerCase();
    final key = (attrs['key'] as String? ?? '').trim();
    final value = (attrs['value'] as String? ?? '').trim();
    // build104（U4）：容错解析标记（畸形 <memory_write">entries=[...] 被归一化时置位）
    final tolerant = attrs['tolerant']?.toString() == 'true';
    // build104（U4）：写后回灌——成功/跳过/失败都喂 toolresult，让模型下一轮
    // 明确知道写入结果，消除"写了不知道"导致的重复写入（实机：一条记忆写了 3 次）
    void feedback(String status, String text) {
      pc.addMessage(ChatMessage.create(
        conversationId: pc.assistantMsg.conversationId,
        role: MessageRole.user,
        // build146 ③：原来只替 `<`，`>` / `&` 原样透传；改走统一外壳
        content: toolResultTag(
          pluginId: 'nexus.builtin.memory_write',
          tool: 'memory_write',
          attrs: {'status': status},
          body: text,
        ),
      ));
    }

    if (key.isEmpty || value.isEmpty) {
      pc.addReasoningStep(
        'memory_write',
        isZh
            ? '${tolerant ? "（容错解析）" : ""}记忆写入失败：key/value 为空'
            : 'memory write failed: empty key/value',
        status: 'invalid',
      );
      feedback('invalid',
          isZh ? 'memory_write 格式错误：key/value 为空，未写入' : 'memory_write: empty key/value, not saved');
      return;
    }
    final storage = pc.storage;
    final content = '$key：$value';
    try {
      if (scope == 'project') {
        // 查当前对话所属项目；无项目则降级为全局
        final conv =
            await storage.getConversation(pc.assistantMsg.conversationId);
        final projectId = conv?.projectId ?? '';
        if (projectId.isNotEmpty) {
          final existing = await storage.loadProjectMemories(projectId);
          // build93(D1)：同 key 覆盖只限 source=auto 的旧记忆；
          // 用户手动添加的记忆永不被自动写误删
          // build94(E6/B5)：同 key 已有手动/置顶记忆时跳过写入，
          // 避免补抽取/重试造成同 key 双条并存
          var blockedByManual = false;
          for (final m in existing) {
            if (m.content.startsWith('$key：')) {
              if (MemoryWritePlugin.autoOverwriteAllowed(m.source, false)) {
                await storage.deleteProjectMemory(m.id);
              } else {
                blockedByManual = true;
              }
            }
          }
          if (blockedByManual) {
          pc.addReasoningStep('memory_write',
              isZh
                  ? '${tolerant ? "（容错解析）" : ""}跳过写入：【本项目】已有同 key 手动记忆「$key」，未覆盖'
                  : 'Skipped: manual project memory "$key" exists');
          feedback('skipped',
              isZh ? '已有同 key 手动记忆「$key」，未覆盖' : 'Manual memory "$key" exists, not overwritten');
          return;
        }
        await storage.saveProjectMemory(ProjectMemory(
            id: 'pm_${DateTime.now().millisecondsSinceEpoch}',
            projectId: projectId,
            content: content,
            source: 'auto',
          ));
          pc.addReasoningStep('memory_write',
              isZh ? '${tolerant ? "（容错解析）" : ""}已写入项目记忆：$content' : 'Saved to project memory: $content');
          feedback('saved', '已写入项目记忆：$content');
          // M2：标明作用域，避免「一个会一个不会」的误解
          pc.showSnackBar(
              isZh ? '已记住【本项目】：$content' : 'Remembered [project]: $content');
          return;
        }
      }
      final existing = await storage.loadGlobalMemories();
      // build93(D1)：只覆盖 source=auto 且未 pinned 的旧记忆；手动/置顶记忆不动
      var blockedByManual = false;
      for (final m in existing) {
        if (m.content.startsWith('$key：')) {
          if (MemoryWritePlugin.autoOverwriteAllowed(m.source, m.pinned)) {
            await storage.deleteGlobalMemory(m.id);
          } else {
            blockedByManual = true;
          }
        }
      }
      if (blockedByManual) {
        pc.addReasoningStep('memory_write',
            isZh
                ? '${tolerant ? "（容错解析）" : ""}跳过写入：【全局】已有同 key 手动/置顶记忆「$key」，未覆盖'
                : 'Skipped: manual/pinned global memory "$key" exists');
        feedback('skipped',
            isZh ? '已有同 key 手动/置顶记忆「$key」，未覆盖' : 'Manual/pinned memory "$key" exists, not overwritten');
        return;
      }
      await storage.saveGlobalMemory(GlobalMemory(
        id: 'gm_${DateTime.now().millisecondsSinceEpoch}',
        content: content,
        source: 'auto',
      ));
      pc.addReasoningStep('memory_write',
          isZh ? '${tolerant ? "（容错解析）" : ""}已写入全局记忆：$content' : 'Saved to global memory: $content');
      feedback('saved', '已写入全局记忆：$content');
      pc.showSnackBar(
          isZh ? '已记住【全局】：$content' : 'Remembered [global]: $content');
    } catch (e) {
      pc.addReasoningStep(
        'memory_write',
        isZh ? '记忆写入失败：$e' : 'memory write failed: $e',
        status: 'error',
      );
      feedback('failed', isZh ? '记忆写入失败：$e' : 'memory write failed: $e');
    }
  }
}

/// build104（U3）：IP 定位城市级锚点插件。
///
/// 背景：高德 MCP 没有"获取我的位置"工具，App 也没有 GPS 权限——「附近」类
/// 查询永远缺锚点。本插件用已装高德连接器的 Web 服务 Key 调
/// `restapi.amap.com/v3/ip` 做 **IP 城市级定位**（精度到市，够"附近推荐"用）。
/// 隐私：请求会把设备公网 IP 发给高德；提示词已注明仅城市级、用户可拒绝回答。
class IpLocatePlugin extends ReActPlugin {
  static PluginRegistry Function()? registryResolver;

  @override
  String get triggerType => 'ip_locate';

  @override
  RegExp? get legacyTrigger => null;

  @override
  PluginSource get source => PluginSource.system;

  @override
  PluginMetadata get metadata => const PluginMetadata(
        id: 'nexus.builtin.ip_locate',
        name: 'IP 定位',
        version: '1.7.49',
        author: 'Nexus Team',
        description: 'IP 城市级定位（依赖已安装的高德连接器 Key），为附近类查询提供位置锚点。',
        homepage: 'https://nexus.local/plugins/ip_locate',
        minAppVersion: '1.7.49',
        tags: ['内置', '定位'],
        extra: {'notWhen': '用户已明确说明城市/地址时不要定位；需要街道级精度时本工具不够用'},
        promptProtocol: '''
【IP 定位】"附近/周边/我所在城市"类查询缺位置锚点时，先输出 <ip_locate /> 获取城市级定位（来源=IP，仅到市）：
- 返回示例：定位：广东省 广州市（IP 城市级，误差可能到邻市，谨慎用于精确导航）。
- 拿到城市后用高德连接器的 POI 工具（如 maps_textsearch）按城市搜索。
- 若返回"未安装高德连接器"：引导用户到 插件管理 → 推荐连接器 安装高德地图并填 Key。
- 隐私：定位请求会把公网 IP 发给高德；用户明确拒绝提供位置时不要调用本工具。
''',
      );

  @override
  Future<void> handle(BuildContext context, PluginContext pc,
      Map<String, dynamic> attrs) async {
    final isZh = pc.userMsg?.content.contains(RegExp(r'[一-龥]')) ?? true;
    final step = pc.addReasoningStep(
      'ip_locate',
      isZh ? 'IP 定位（城市级）' : 'IP locate (city-level)',
      status: 'running',
    );

    // ① 找已装的高德连接器并从端点提取 Key
    final registry = registryResolver?.call();
    ReActPlugin? amap;
    if (registry != null) {
      for (final p in registry.plugins) {
        if (p.metadata.id == 'amap' ||
            p.metadata.name.toLowerCase().contains('amap')) {
          amap = p;
          break;
        }
      }
    }
    String key = '';
    if (amap != null) {
      final endpoint = amap.metadata.extra['endpoint']?.toString() ?? '';
      final uri = Uri.tryParse(endpoint);
      key = uri?.queryParameters['key'] ?? '';
    }
    if (key.isEmpty) {
      pc.updateReasoningStep(step,
          status: 'blocked',
          resultSummary:
              isZh ? '未安装高德连接器或未配置 Key' : 'AMap connector not installed');
      pc.addMessage(ChatMessage.create(
        conversationId: pc.assistantMsg.conversationId,
        role: MessageRole.user,
        // build146 ③：ip_locate 的正文含**上游 HTTP 响应字段**（$info/$desc），
        // 原先未转义直拼 —— 上游返回一段 `</toolresult>…` 即可越栏
        content: toolResultTag(
          pluginId: 'nexus.builtin.ip_locate',
          tool: 'ip_locate',
          attrs: const {'status': 'blocked'},
          body:
              '未安装高德连接器或未配置 Key。请引导用户到 插件管理 → 推荐连接器 安装高德地图并填入 Web 服务 Key；或直接询问用户所在城市。',
        ),
      ));
      return;
    }
    // ② 调高德 IP 定位
    try {
      final resp = await http
          .get(Uri.parse('https://restapi.amap.com/v3/ip?key=$key'))
          .timeout(const Duration(seconds: 12));
      final j = jsonDecode(utf8.decode(resp.bodyBytes, allowMalformed: true))
          as Map<String, dynamic>;
      if (j['status'] != '1') {
        final info = j['info']?.toString() ?? 'HTTP ${resp.statusCode}';
        pc.updateReasoningStep(step,
            status: 'failed', resultSummary: 'IP 定位失败：$info');
        pc.addMessage(ChatMessage.create(
          conversationId: pc.assistantMsg.conversationId,
          role: MessageRole.user,
          content: toolResultTag(
            pluginId: 'nexus.builtin.ip_locate',
            tool: 'ip_locate',
            attrs: {'status': 'failed'},
            body: 'IP 定位失败：$info。请直接询问用户所在城市。',
          ),
        ));
        return;
      }
      final province = (j['province'] as String? ?? '').trim();
      final city = (j['city'] as String? ?? '').trim();
      final desc = '定位：$province $city（IP 城市级，误差可能到邻市）';
      pc.updateReasoningStep(step,
          status: 'done', resultSummary: desc);
      pc.addMessage(ChatMessage.create(
        conversationId: pc.assistantMsg.conversationId,
        role: MessageRole.user,
        content: toolResultTag(
          pluginId: 'nexus.builtin.ip_locate',
          tool: 'ip_locate',
          attrs: {'status': 'done'},
          body: desc,
        ),
      ));
    } catch (e) {
      pc.updateReasoningStep(step,
          status: 'failed', resultSummary: 'IP 定位异常：$e');
      pc.addMessage(ChatMessage.create(
        conversationId: pc.assistantMsg.conversationId,
        role: MessageRole.user,
        content: toolResultTag(
          pluginId: 'nexus.builtin.ip_locate',
          tool: 'ip_locate',
          attrs: const {'status': 'failed'},
          body: 'IP 定位异常，请直接询问用户所在城市。',
        ),
      ));
    }
  }
}

/// v1.7.50（build106）：设备 GPS 精确定位插件。
///
/// 协议：<get_location />（自闭合，N9 兼容配对/裸开写法）。
/// 背景：ip_locate 只有 IP 城市级精度，「最近地铁站/打车出发地/步行导航」
/// 需要街道级坐标——本插件用 geolocator 取设备 GPS（WGS-84），转 GCJ-02
/// （高德坐标系）后以 toolresult 回灌；坐标可直接喂高德 MCP 的
/// maps_regeocode / maps_around_search / maps_direction_* 系列工具。
/// 隐私：定位结果属敏感位置信息——仅当用户请求确实需要位置时调用；
/// 权限由系统弹窗控制，用户拒绝后不要反复调用、如实改问用户。
class DeviceLocationPlugin extends ReActPlugin {
  @override
  String get triggerType => 'get_location';

  @override
  RegExp? get legacyTrigger => null;

  @override
  PluginSource get source => PluginSource.system;

  @override
  PluginMetadata get metadata => const PluginMetadata(
        id: 'nexus.builtin.get_location',
        name: '设备定位',
        version: '1.7.50',
        author: 'Nexus Team',
        description: 'GPS 精确定位（街道级）：输出 <get_location /> 获取设备坐标（GCJ-02，可直接喂高德工具）。',
        homepage: 'https://nexus.local/plugins/get_location',
        minAppVersion: '1.7.50',
        tags: ['内置', '定位'],
        extra: {
          'notWhen':
              '用户已给出明确地址/地标时不要调用；只需城市级精度时用 ip_locate；用户拒绝定位后不要反复调用',
        },
        promptProtocol: '''
【设备定位】需要街道级精确位置（最近地铁站/打车出发地/周边推荐/路线规划）时，先输出 <get_location /> 获取 GPS 定位：
- 返回示例：定位成功（GPS，GCJ-02 高德坐标）：lat=23.008900, lng=113.399200；精度约 ±35 米。
- 坐标已是 GCJ-02（高德坐标系），传给高德 MCP 工具时用 "lng,lat" 顺序（如 "113.399200,23.008900"）。
- 下一步：maps_regeocode 坐标转地址 / maps_around_search 搜周边 POI / maps_direction_transit_integrated、maps_direction_walking 规划路线。
- 返回"权限被拒/服务未开"：改用 <ip_locate />（城市级）或直接文字询问用户位置，不要连续重试本工具。
- 隐私：仅当用户的请求确实需要位置时才调用；用户明确拒绝提供位置时不要调用。
''',
      );

  @override
  Future<void> handle(BuildContext context, PluginContext pc,
      Map<String, dynamic> attrs) async {
    final isZh = pc.userMsg?.content.contains(RegExp(r'[一-龥]')) ?? true;
    final step = pc.addReasoningStep(
      'get_location',
      isZh ? '设备定位（GPS）' : 'Device location (GPS)',
      status: 'running',
    );

    Future<void> finish(String status, String summary, String result) async {
      pc.updateReasoningStep(step, status: status, resultSummary: summary);
      pc.addMessage(ChatMessage.create(
        conversationId: pc.assistantMsg.conversationId,
        role: MessageRole.user,
        // build146 ③：本条正文是宿主自撰文案，仍走统一外壳——一个语义只留一处
        // 实现，不给"下次改这里忘了改那里"留口（法则 #62）
        content: toolResultTag(
          pluginId: 'nexus.builtin.get_location',
          tool: 'get_location',
          attrs: {'status': status},
          body: result,
        ),
      ));
    }

    try {
      // ① 系统定位服务总开关
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        await finish(
          'blocked',
          isZh ? '定位服务未开启' : 'location service off',
          '设备定位服务未开启。请引导用户到系统快捷开关/设置开启「位置信息」，或改用 <ip_locate /> 获取城市级位置、或直接询问用户所在位置。',
        );
        return;
      }
      // ② 运行时权限：未授权则现场弹系统授权框（调用发生在用户前台对话中）
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied) {
        await finish(
          'blocked',
          isZh ? '用户拒绝定位权限' : 'permission denied',
          '用户拒绝了定位权限。请直接用文字询问用户所在位置，不要连续重复调用本工具。',
        );
        return;
      }
      if (permission == LocationPermission.deniedForever) {
        await finish(
          'blocked',
          isZh ? '定位权限被永久拒绝' : 'permission denied forever',
          '定位权限被永久拒绝（系统不再弹窗）。请引导用户到 系统设置 → 应用 → Nexus → 权限 手动开启「位置信息」，或改用 <ip_locate /> / 直接询问用户位置。',
        );
        return;
      }
      // ③ 取位置：实时高精度（15 秒上限），失败回退最近缓存位置
      Position pos;
      try {
        pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 15),
          ),
        );
      } catch (_) {
        final last = await Geolocator.getLastKnownPosition();
        if (last == null) rethrow;
        pos = last;
      }
      // ④ WGS-84 → GCJ-02：不转换直接喂高德会偏移数百米，「最近」会答错
      final gcj = wgs84ToGcj02(pos.latitude, pos.longitude);
      final lat = gcj[0].toStringAsFixed(6);
      final lng = gcj[1].toStringAsFixed(6);
      final desc = '定位成功（GPS，GCJ-02 高德坐标）：lat=$lat, lng=$lng；'
          '精度约 ±${pos.accuracy.toStringAsFixed(0)} 米。'
          '传给高德 MCP 工具时用 "lng,lat" 顺序（如 "$lng,$lat"）。';
      await finish('done', desc, desc);
    } catch (e) {
      await finish(
        'failed',
        '定位异常：$e',
        '定位失败（GPS 超时或不可用）。可建议用户换到开阔处再试一次，或改用 <ip_locate /> 获取城市级位置、或直接询问用户所在位置。',
      );
    }
  }
}

/// v1.7.52（build108 Q1）：API 余额/用量查询插件。
///
/// 协议：<query_quota />（自闭合，N9 兼容配对/裸开写法）。
/// 用户问「我的 API 还剩多少钱/余额/用量」时调用，遍历全部 API 配置
/// 查询余额（OpenAI billing 兼容 / DeepSeek / SiliconFlow 三类端点自动
/// 探测，见 BalanceService）。隐私：请求只发往各配置自己的服务端。
/// 结果带 TTL 缓存；attr refresh="true" 强制绕缓存重查。
class QuotaPlugin extends ReActPlugin {
  @override
  String get triggerType => 'query_quota';

  @override
  RegExp? get legacyTrigger => null;

  @override
  PluginSource get source => PluginSource.system;

  @override
  PluginMetadata get metadata => const PluginMetadata(
        id: 'nexus.builtin.query_quota',
        name: '余额查询',
        version: '1.7.52',
        author: 'Nexus Team',
        description: '查询 API 配置的余额/用量：输出 <query_quota />，用各服务自己的余额接口（one-api 中转/DeepSeek/SiliconFlow）。',
        homepage: 'https://nexus.local/plugins/query_quota',
        minAppVersion: '1.7.52',
        tags: ['内置', '余额'],
        extra: {
          'notWhen': '与余额/用量/费用完全无关的问题不要调用',
        },
        promptProtocol: '''
【余额查询】用户问「我的 API 还剩多少钱/余额/用量」时，输出 <query_quota />（attr refresh="true" 可强制刷新缓存）：
- 返回逐条列出各 API 配置的余额/已用；不支持的端点会标「不支持余额接口」。
- 隐私：查询只发往该配置自己的服务端（key 不发给第三方）。
''',
      );

  @override
  Future<void> handle(BuildContext context, PluginContext pc,
      Map<String, dynamic> attrs) async {
    final isZh = pc.userMsg?.content.contains(RegExp(r'[一-龥]')) ?? true;
    final force = (attrs['refresh']?.toString() == 'true');
    final step = pc.addReasoningStep(
      'query_quota',
      isZh ? '余额查询' : 'Quota query',
      status: 'running',
    );

    Future<void> finish(String status, String summary, String result) async {
      pc.updateReasoningStep(step, status: status, resultSummary: summary);
      pc.addMessage(ChatMessage.create(
        conversationId: pc.assistantMsg.conversationId,
        role: MessageRole.user,
        // build146 ③：走统一外壳（正文是配置名 + 余额数字，本身不含外部文本，
        // 但外壳只允许一处实现）
        content: toolResultTag(
          pluginId: 'nexus.builtin.query_quota',
          tool: 'query_quota',
          attrs: {'status': status},
          body: result,
        ),
      ));
    }

    try {
      final configs = await pc.storage.getApiConfigs();
      if (configs.isEmpty) {
        await finish('blocked', '无 API 配置',
            '还没有任何 API 配置，请引导用户先到 设置 → API 配置 添加。');
        return;
      }
      final sb = StringBuffer();
      var okCount = 0;
      for (final cfg in configs) {
        final info = await BalanceService.fetchFor(cfg, force: force);
        if (info == null) {
          sb.writeln('- ${cfg.name}：不支持余额接口（或查询失败）');
        } else {
          okCount++;
          sb.writeln('- ${cfg.name}：${info.display}');
        }
      }
      final head = force ? '已强制刷新，' : '';
      final desc = '$head共 ${configs.length} 个配置，$okCount 个查询成功：\n$sb';
      await finish(okCount > 0 ? 'done' : 'failed',
          '$okCount/${configs.length} 查询成功', desc.trim());
    } catch (e) {
      await finish('failed', '余额查询异常：$e', '余额查询失败，请如实告知用户暂时无法查询。');
    }
  }
}

/// N8（build94）：AI 删除记忆插件。
///
/// 协议：<memory_delete scope="global|project" key="..." />（自闭合，N9 起兼容配对写法）。
/// 用户明确要求"忘掉/删除"某条记忆时按 key 删除。安全约束与 D1 一致：
/// 只删 source=auto 且未 pinned 的记忆；手动/置顶记忆只提示、绝不删。
class MemoryDeletePlugin extends ReActPlugin {
  @override
  String get triggerType => 'memory_delete';

  @override
  RegExp? get legacyTrigger => null;

  @override
  PluginSource get source => PluginSource.system;

  @override
  PluginMetadata get metadata => const PluginMetadata(
        id: 'nexus.builtin.memory_delete',
        name: '记忆删除',
        version: '1.7.40',
        author: 'Nexus Team',
        description: '用户明确要求忘掉某条偏好/事实时，按 key 删除全局或项目记忆。',
        homepage: 'https://nexus.local/plugins/memory',
        minAppVersion: '1.7.40',
        tags: ['内置', '记忆'],
        extra: {'notWhen': '用户没有明确删除意图时，绝不主动调用'},
        promptProtocol: '''
【记忆删除】使用说明：
- 使用场景：仅当用户明确说"忘掉/删除/不要记住 XXX"时才使用；不得主动清理记忆。
- 协议格式（自闭合标签，放在 <answer> 之外）：
  <memory_delete scope="global" key="饮食偏好" />
- scope：global=全局记忆（默认）；project=当前项目记忆。
- 只能删除 AI 自动写入的记忆；用户手动添加/置顶的记忆不会被删除，会在回答中说明。
''',
      );

  @override
  Future<void> handle(BuildContext context, PluginContext pc,
      Map<String, dynamic> attrs) async {
    final isZh = pc.userMsg?.content.contains(RegExp(r'[一-龥]')) ?? true;
    final scope = (attrs['scope'] as String? ?? 'global').toLowerCase();
    final key = (attrs['key'] as String? ?? '').trim();
    if (key.isEmpty) {
      pc.addReasoningStep(
        'memory_delete',
        isZh ? '记忆删除失败：key 为空' : 'memory delete failed: empty key',
        status: 'invalid',
      );
      return;
    }
    final storage = pc.storage;
    try {
      var deleted = 0;
      var skipped = 0;
      if (scope == 'project') {
        // 查当前对话所属项目；无项目则无可删（不降级，避免误删全局）
        final conv =
            await storage.getConversation(pc.assistantMsg.conversationId);
        final projectId = conv?.projectId ?? '';
        if (projectId.isNotEmpty) {
          final existing = await storage.loadProjectMemories(projectId);
          for (final m in existing) {
            if (!m.content.startsWith('$key：')) continue;
            // 与 D1 同约束：只删 source=auto 且未 pinned 的记忆
            if (MemoryWritePlugin.autoOverwriteAllowed(m.source, false)) {
              await storage.deleteProjectMemory(m.id);
              deleted++;
            } else {
              skipped++;
            }
          }
        }
      } else {
        final existing = await storage.loadGlobalMemories();
        for (final m in existing) {
          if (!m.content.startsWith('$key：')) continue;
          if (MemoryWritePlugin.autoOverwriteAllowed(m.source, m.pinned)) {
            await storage.deleteGlobalMemory(m.id);
            deleted++;
          } else {
            skipped++;
          }
        }
      }
      final scopeLabel = scope == 'project'
          ? (isZh ? '项目记忆' : 'project memory')
          : (isZh ? '全局记忆' : 'global memory');
      final String msg;
      if (deleted > 0) {
        msg = isZh
            ? '已从$scopeLabel删除：$key（$deleted 条）'
            : 'Deleted "$key" from $scopeLabel ($deleted)';
      } else if (skipped > 0) {
        msg = isZh
            ? '未删除：$key 为手动/置顶记忆，请在设置中手动删除'
            : 'Not deleted: "$key" is manual/pinned, remove it in Settings';
      } else {
        msg = isZh
            ? '$scopeLabel中未找到：$key'
            : 'No "$key" found in $scopeLabel';
      }
      pc.addReasoningStep('memory_delete', msg);
      if (deleted > 0) {
        pc.showSnackBar(isZh ? '已忘掉：$key' : 'Forgot: $key');
      }
    } catch (e) {
      pc.addReasoningStep(
        'memory_delete',
        isZh ? '记忆删除失败：$e' : 'memory delete failed: $e',
        status: 'error',
      );
    }
  }
}

/// build104（M2b）：连接器指南插件——MCP/连接器类问题的「使用说明 + 错误对照表」/// 常驻注入。知识文本随 promptProtocol 进 system 前缀（编译期静态，前缀稳定）；
/// `<connector_guide/>` 标签仅用于让 AI 在回答前显式声明已引用指南（可见化）。
class ConnectorGuidePlugin extends ReActPlugin {
  @override
  String get triggerType => 'connector_guide';

  @override
  RegExp? get legacyTrigger => null;

  @override
  PluginSource get source => PluginSource.system;

  @override
  PluginMetadata get metadata => const PluginMetadata(
        id: 'nexus.builtin.connector_guide',
        name: '连接器指南',
        version: '1.7.48',
        author: 'Nexus Team',
        description: 'MCP 连接器接入步骤与常见错误对照表（401/超时/工具数为 0）。',
        homepage: 'https://nexus.local/plugins/connector_guide',
        minAppVersion: '1.7.48',
        tags: ['内置', 'MCP', '连接器'],
        extra: {'notWhen': '与连接器/MCP 完全无关的问题不要引用本指南'},
        promptProtocol: '''
【连接器指南】用户问"怎么连/装某个 MCP 服务"或连接器报错时，先输出 <connector_guide /> 再按下面内容回答：
- 推荐连接器（插件管理 → 推荐连接器 一键安装）：高德地图（高德 MCP-Key）、GitHub 官方（PAT）、Context7 / DeepWiki / Microsoft Learn（免鉴权）、魔搭托管、滴滴（MCP Key）。
- 接入三步：①插件管理 → 推荐连接器 → 选服务；②按提示填密钥（每个服务旁有申请指引）；③安装（自动过安全审查）→ 对话中即可用。
- 位置类查询（附近/最近/路线/打车）：先用 <get_location /> 拿设备 GPS 坐标（GCJ-02，街道级），再用高德 maps_regeocode / maps_around_search / maps_direction_* 查周边与规划路线；高德 MCP 本身没有"获取我的位置"工具，<ip_locate /> 只有城市级精度，要街道级就用 get_location。
- 深链输出格式：给「唤起高德导航/打开地图」类链接时，一律写成 Markdown 链接形态 [打开高德导航](amapuri://...)——不要放进反引号代码块（代码块不可点击，用户点了没反应）。
- 高德链接模板（B1）：**有终点坐标**用 `https://uri.amap.com/navigation?from=起点lng,lat&to=终点lng,lat&toName=终点名&mode=car`；**只有终点名没有坐标**用 `https://uri.amap.com/marker?name=终点名&callnative=1`（搜索模板，由高德侧解析地名），或 `https://uri.amap.com/search?keyword=终点名&callnative=1`；坐标格式恒为 `经度,纬度`（逗号分隔，高德顺序）。**绝不要**在链接里写 `xxxx` 之类占位符——拿不到坐标就用搜索模板或直接给文字方案。
- 错误对照：
  · 401/鉴权失效 → 密钥过期或填错：插件管理 → 钥匙图标更新鉴权头；
  · 连接超时 → 该服务在当前网络不可达：换网络或换同类服务；
  · 工具列表为 0 → 端点写错或协议不兼容：核对官方文档的端点地址；
  · 反复失败 → 点插件管理里的「体检」按钮看具体哪一环失败。
- 通用原则：密钥等价于账号权限，不要外发；一个服务装一次即可，重复安装会被覆盖。
''',
      );

  @override
  Future<void> handle(BuildContext context, PluginContext pc,
      Map<String, dynamic> attrs) async {
    pc.addReasoningStep(
      'connector_guide',
      '连接器指南已引用',
      status: 'done',
      resultSummary: '已向模型注入接入步骤与错误对照表',
    );
  }
}

/// build104（M2c）：AI 查询应用日志辅助排障。
/// 隐私护栏（三条，缺一不可）：
/// ①设置开关「允许 AI 读取日志」默认关（SharedPreferences aiLogReadEnabled）；
/// ②每次读取前弹确认（铁律 10）；
/// ③硬排除：VERBOSE 级别行与 [CHAT] 分类行（详细模式下聊天正文只出现在这两处），
///   输出截 4000 字符（与 MCP 工具结果上限同口径）。
class LogQueryPlugin extends ReActPlugin {
  @override
  String get triggerType => 'log_query';

  @override
  RegExp? get legacyTrigger => null;

  @override
  PluginSource get source => PluginSource.system;

  @override
  PluginMetadata get metadata => const PluginMetadata(
        id: 'nexus.builtin.log_query',
        name: '日志查询',
        version: '1.7.48',
        author: 'Nexus Team',
        description: '排障时查询应用运行日志（分类/关键字/尾部行数），隐私护栏默认关闭。',
        homepage: 'https://nexus.local/plugins/log_query',
        minAppVersion: '1.7.48',
        tags: ['内置', '日志', '排障'],
        extra: {'notWhen': '与排障无关的闲聊/写作场景不要查询日志'},
        promptProtocol: '''
【日志查询】排障时（用户说"发消息失败/连接不上/看看日志"）可输出：
  <log_query category="API|ERROR|REACT|APP" keyword="可选关键字" tail="40" />
category 取 API/ERROR/REACT/APP/DB/DOWNLOAD 之一；tail 为返回行数（≤200）。系统会先弹确认征得用户同意，同意后返回过滤后的日志摘录（已自动剔除聊天内容）。拿到日志后：给出"现象→原因→建议"三段式结论，不要逐行复述。
''',
      );

  static const String _toggleKey = 'aiLogReadEnabled';

  @override
  Future<void> handle(BuildContext context, PluginContext pc,
      Map<String, dynamic> attrs) async {
    final isZh = pc.userMsg?.content.contains(RegExp(r'[一-龥]')) ?? true;
    final category =
        (attrs['category'] as String? ?? 'ERROR').toUpperCase().trim();
    final keyword = (attrs['keyword'] as String? ?? '').trim();
    final tail =
        ((int.tryParse(attrs['tail']?.toString() ?? '') ?? 40).clamp(5, 200));
    final step = pc.addReasoningStep(
      'log_query',
      '日志查询 · $category${keyword.isEmpty ? '' : ' · "$keyword"'}',
      status: 'running',
    );

    // 护栏①：总开关默认关
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_toggleKey) ?? false;
    if (!enabled) {
      _finish(pc, step, 'blocked',
          isZh ? '已关闭：到 设置 → 日志与调试 → 打开「允许 AI 读取日志」后再试' : 'Disabled: enable "Allow AI to read logs" in Settings → Logs');
      return;
    }
    if (!context.mounted) return;
    // 护栏②：逐次确认
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text(isZh ? '允许 AI 读取日志？' : 'Allow AI to read logs?'),
        content: Text(isZh
            ? '将读取最近日志的「$category」分类摘录（不含聊天内容）并发送给当前模型用于排障。'
            : 'Read recent "$category" log excerpts (chat content excluded) and send them to the current model for troubleshooting.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: Text(isZh ? '拒绝' : 'Deny')),
          FilledButton(
              onPressed: () => Navigator.pop(dctx, true),
              child: Text(isZh ? '允许一次' : 'Allow once')),
        ],
      ),
    );
    if (ok != true) {
      _finish(pc, step, 'rejected', isZh ? '用户拒绝本次日志读取' : 'User denied log read');
      return;
    }

    // 读取：app_logs 目录最新 2 个文件（覆盖跨天），逐行过滤
    try {
      final dir = await getApplicationDocumentsDirectory();
      final logDir = Directory('${dir.path}${Platform.pathSeparator}app_logs');
      if (!await logDir.exists()) {
        _finish(pc, step, 'done', isZh ? '日志目录为空（还没有产生日志）' : 'No logs yet');
        return;
      }
      final files = (await logDir
              .list()
              .where((f) => f is File && f.path.endsWith('.log'))
              .toList())
          .cast<File>()
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path));
      final lines = <String>[];
      for (final f in files.take(2)) {
        final content = await f.readAsString();
        lines.addAll(content.split('\n').reversed);
      }
      // 护栏③：硬排除 VERBOSE 级别与 [CHAT] 分类（详细模式下聊天正文只在这两处）
      String filter(String raw) {
        var s = raw.trim();
        if (s.contains('[VERBOSE]')) return '';
        if (s.contains('[CHAT]')) return '';
        if (category != 'ALL' && !s.contains('[$category]')) return '';
        if (keyword.isNotEmpty && !s.contains(keyword)) return '';
        return s;
      }

      final picked = <String>[];
      for (final raw in lines) {
        final s = filter(raw);
        if (s.isNotEmpty) {
          picked.add(s);
          if (picked.length >= tail) break;
        }
      }
      final excerpt = picked.isEmpty
          ? (isZh ? '（$category 分类下最近没有匹配日志）' : '(no matching log lines)')
          : picked.reversed.join('\n');
      final result = excerpt.length > 4000
          ? '${excerpt.substring(excerpt.length - 4000)}…'
          : excerpt;
      _finish(pc, step, 'done', isZh ? '返回 ${picked.length} 行' : '${picked.length} lines');
      pc.addMessage(ChatMessage.create(
        conversationId: pc.assistantMsg.conversationId,
        role: MessageRole.user,
        // build146 ③：$result 是**磁盘上读回的日志原文**（内容不由本插件构造），
        // 原先整段未转义直拼 —— 一行 </toolresult> 即可越栏
        content: toolResultTag(
          pluginId: 'nexus.builtin.log_query',
          tool: 'log_query',
          attrs: {'category': category},
          body: result,
        ),
      ));
    } catch (e) {
      _finish(pc, step, 'failed', 'log read failed: $e');
    }
  }

  void _finish(PluginContext pc, ReasoningStep? step, String status,
      String summary) {
    pc.updateReasoningStep(step, status: status, resultSummary: summary);
    pc.addMessage(ChatMessage.create(
      conversationId: pc.assistantMsg.conversationId,
      role: MessageRole.user,
      // build146 ③：原来只替 `<`，`&`/`>` 照样透传；统一走外壳
      content: toolResultTag(
        pluginId: 'nexus.builtin.log_query',
        tool: 'log_query',
        attrs: {'status': status},
        body: summary,
      ),
    ));
  }
}

class FallbackUnknownTagPlugin extends ReActPlugin {
  @override
  String get triggerType => '__fallback_unknown__';

  @override
  RegExp? get legacyTrigger => null;

  @override
  PluginSource get source => PluginSource.system;

  @override
  PluginMetadata get metadata => const PluginMetadata(
        id: '__fallback_unknown__',
        name: '未知 ReAct 标签兜底',
        version: '1.6.8',
        author: 'Nexus Team',
        description: '当 AI 输出了无法识别的标签时，静默记录为思考步骤，不再导致循环静默丢弃。',
        minAppVersion: '1.6.8',
        tags: ['内置', '兜底'],
      );

  @override
  Future<void> handle(BuildContext context, PluginContext pc,
      Map<String, dynamic> attrs) async {
    final type = attrs['type'] as String? ?? 'unknown';
    final snippet =
        (attrs['content'] as String? ?? attrs['raw'] as String? ?? '')
            .replaceAll('\n', ' ')
            .trim();
    final preview =
        snippet.length <= 40 ? snippet : '${snippet.substring(0, 40)}...';
    final isZh =
        pc.userMsg?.content.contains(RegExp(r'[\u4e00-\u9fff]')) ?? true;
    final label = isZh
        ? '未知 ReAct 标签类型：<$type>（预览：$preview）。已忽略。'
        : 'Unknown ReAct tag <$type> (preview: $preview). Ignored.';
    pc.addReasoningStep('unknown_tag', label);
    pc.logger
        .warn('[ReAct] Fallback: unknown triggerType=$type preview=$preview');
  }
}

/// build101（C3 深度阅读）：思考强度 ≥ 0.8 时抓取前几条搜索结果的网页正文。
///
/// 返回可直接拼进 TOOL RESULT 的文本块；未达深度档 / 无结果 / 全部抓取失败
/// 都返回空串（调用方按空串跳过，不影响原有 snippet 路径）。
///
/// 设计要点：
/// - 并发抓取（`Future.wait`）而非串行——串行 3 个页面最坏 60s，用户无法接受
/// - 单页上限 512KB / 20s 超时，防大文件和死链拖死整轮
/// - 正文截断到 4000 字符，3 页共 1.2 万字符 ≈ 4K token，深研档可接受
/// - 失败静默：抓不到就用原 snippet，不因抓取失败中断搜索链路
Future<String> _deepReadTopResults(
  List<SearchResultItem> results, {
  required double effort,
  required bool isZh,
  required PluginContext pc,
}) async {
  if (effort < 0.8 || results.isEmpty) return '';
  // 只抓前 3 条，且必须是可抓取的公开网页
  // build146（行业分歧安全批 ①）：`r.url` 是**搜索结果**里的 URL，SEO 可投毒
  // ⇒ 这是一条外部可控目标的读回通道。私网/回环拦截已下沉到
  // `ArticleExtractor.isFetchable`（复用 SecurityGate.isPrivateHost），
  // `fetch()` 内还有第二道（清单在别处拼装，不能指望调用点）。
  final targets = results
      .where((r) => ArticleExtractor.isFetchable(r.url))
      .take(3)
      .toList();
  if (targets.isEmpty) return '';

  pc.addReasoningStep(
      'search',
      isZh
          ? '📖 深度阅读 %d 篇网页正文...'.replaceFirst('%d', '${targets.length}')
          : '📖 Deep-reading ${targets.length} pages...');
  final sw = Stopwatch()..start();

  final fetched = await Future.wait(targets.map((r) async {
    final art = await ArticleExtractor.fetch(r.url);
    return (item: r, art: art);
  }));
  sw.stop();

  final ok = fetched.where((f) => f.art != null).toList();
  if (ok.isEmpty) {
    // build140（缺口报告 §6「网页正文抽取的可见性」）：**这一条 return 之前必须收掉
    // 上面那个 `search` 步骤**，否则思考面板里会留下一个永远转圈的「📖 深度阅读 3 篇网页正文...」
    // ——`message_bubble_v2.dart::_mergeNodes()` 判定 search 节点"有没有结果"的依据是
    // **紧邻的下一条是不是 `search_result`**，没有就当成还在跑。
    // 而且失败原因一个字都不记，用户只会觉得"卡住了"。
    // 与 build138「搜索故障不再报成未找到结果」是同一族欠账：静默 = 不可排查。
    // 文案不带 emoji：`v2_ui_guard_test.dart` R1 棘轮禁"用户可见字符串里的 emoji"
    // （旧的那几条 📖 是基线里的历史欠账，只许减不许增），节点图标由气泡自己渲染。
    pc.addReasoningStep(
        'search_result',
        isZh
            ? '深度阅读未能取到任何正文（${targets.length} 篇均失败，'
                '可能是付费墙/反爬/超时），已回退到搜索摘要'
            : 'Deep read got no page contents (${targets.length} failed — '
                'paywall / bot protection / timeout); fell back to snippets',
        resultCount: 0,
        latencyMs: sw.elapsedMilliseconds);
    return '';
  }

  final sb = StringBuffer();
  sb.writeln(isZh
      ? '=== 网页正文（深度阅读，共 ${ok.length} 篇）==='
      : '=== Page contents (deep read, ${ok.length} pages) ===');
  for (var i = 0; i < ok.length; i++) {
    final f = ok[i];
    final art = f.art!;
    final title = art.title.isNotEmpty ? art.title : f.item.title;
    final body =
        art.text.length > 4000 ? '${art.text.substring(0, 4000)}...' : art.text;
    sb.writeln();
    sb.writeln('--- [${i + 1}] $title ---');
    sb.writeln('URL: ${f.item.url}');
    sb.writeln(body);
  }
  pc.addReasoningStep(
      'search_result',
      isZh
          ? '📖 已读取 ${ok.length} 篇正文（${sw.elapsedMilliseconds}ms）'
          : '📖 Read ${ok.length} pages (${sw.elapsedMilliseconds}ms)',
      resultCount: ok.length,
      latencyMs: sw.elapsedMilliseconds);
  return sb.toString().trim();
}

String _xmlEscape(String s) {
  return const HtmlEscape().convert(s);
}

String _ellipse(String s, int max) {
  if (s.length <= max) return s;
  return '${s.substring(0, max)}...';
}

// ============================================================================
// build146（行业分歧安全批 ③）：`<toolresult>` 外壳的**唯一实现点**（法则 #62
// ——一个语义只允许一处实现）。
//
// 起因（P1）：`_wsToolResult` 原先把 `$result` 原样插进
// `<toolresult …>$result</toolresult>`，而 `$result` 是 **AI 工作区里任意本地
// 文件的内容**（ws_read / ws_grep / ws_download 回灌）。文件里只要有一行
// `</toolresult>`，围栏就被提前闭合，后面的文字宿主会当成"第二条工具结果"读
// —— 一个下载下来的 txt 就能越栏注入指令。同仓库其它通道（本文件的
// memory_write / log_query、gen_plugins.dart:70、installed_mcp_plugin.dart:303）
// 都做了 `<`→`&lt;`，偏偏工作区这条最容易被外部内容占据的通道没做。
//
// 两条口径一起落地：
//   1) **转义**：正文走 [escapeToolResultContent]（`&`/`<`/`>`），属性值额外
//      禁引号与换行，闭合标签不可能由正文构造出来；
//   2) **数据不是指令**（业界对 prompt injection 的标配约定）：外壳固定带
//      `encoding="escaped" trust="untrusted"`，配合 api_service / agent_prompts
//      里新增的一句协议文本，让模型知道标签内是检索到的资料。
//
// 已核：宿主侧**没有**按属性解析 `toolresult` 的代码（grep：只有
// react_stream_scrubber 的通用 `<[^>]+>` 剥离、react_parser:1700 的自语 cue 词
// 表、message_bubble_v2:1742 的展示层剥标签），加属性不会破坏识别；
// 这三条都在 build146 的回归里钉住了。
//
// 待办（本轮未合并的同类点，都改成调本函数即可，逐条列在此处免得又散）：
//   · lib/plugins/gen_plugins.dart:69（图生成回灌，只替 `<`）
//   · lib/plugins/installed_mcp_plugin.dart:303（自带一份 `_escape`）
//   · lib/plugins/plugin_registry.dart:592/622/641/776/781（宿主级 toolresult）
//   · lib/plugins/install_mcp_plugin.dart、install_skill_plugin.dart（kind=… 外壳）
//   · lib/services/article_extractor.dart 的正文与 `---TOOL RESULT START (search)---`
//     纯文本块不是 XML 外壳，走的是"协议文本 + 小标题"提示，不改转义。
// ============================================================================

/// toolresult **正文**转义：`&` 必须先替，否则会把 `&lt;` 二次转义成 `&amp;lt;`。
/// 纯函数，可单测。
String escapeToolResultContent(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

/// 属性值转义：正文三件套 + 双引号 + 换行（换行会切断按行处理标签的正则）。
String escapeToolResultAttr(String s) => escapeToolResultContent(s)
    .replaceAll('"', '&quot;')
    .replaceAll('\n', ' ')
    .replaceAll('\r', ' ');

/// 拼一条完整的 `<toolresult …>…</toolresult>` 回灌文本。
///
/// [attrs] 是调用方的附加属性（`status` / `category` / `is_error` …），
/// 顺序保持传入顺序，便于与历史文案对照；`encoding` / `trust` 由本函数固定追加，
/// 不给调用方关掉的机会。
String toolResultTag({
  required String pluginId,
  required String tool,
  Map<String, String> attrs = const {},
  required String body,
}) {
  final buf = StringBuffer('<toolresult plugin_id="')
    ..write(escapeToolResultAttr(pluginId))
    ..write('" tool="')
    ..write(escapeToolResultAttr(tool))
    ..write('"');
  attrs.forEach((k, v) {
    buf
      ..write(' ')
      ..write(escapeToolResultAttr(k))
      ..write('="')
      ..write(escapeToolResultAttr(v))
      ..write('"');
  });
  buf
    ..write(' encoding="escaped" trust="untrusted">')
    ..write(escapeToolResultContent(body))
    ..write('</toolresult>');
  return buf.toString();
}


// ===========================================================================
// build113（任务五 WS-2）：AI 文件工作区——6 个内置动作，原生 FC + 标签双通道。
// 安全红线（WS-4）：路径逃不出 ai_workspace（见 WorkspaceService.resolve）；
// 写/删默认当次人工确认（build138 甲1 起可按「权限档位」放宽：删除任何档位都必弹，
// 详见 lib/utils/workspace_permission.dart 的 wsNeedsConfirm）；下载仅
// HTTPS 且过 SecurityGate；所有错误可见化、禁止静默失败或静默成功。
// reasoning 步骤 kind='workspace'（中文状态、无 emoji），结果以工具消息回灌。
// ===========================================================================

/// 写/删确认对话框。
///
/// build138（甲1）：这里不再是「每次必弹、不提供始终允许」的硬编码——
/// 档位由 [wsNeedsConfirm] 判定（默认档 alwaysAsk 与旧行为逐字节一致）。
/// 红线不变且写死在纯函数里：**删除任何档位都必弹**，覆盖已有文件在
/// 「自动改文件」档仍弹；只有用户主动切到「全自动」才允许覆盖不询问。
class _WsConfirmDialog extends StatelessWidget {
  final String title;
  final String body;
  const _WsConfirmDialog({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消')),
        FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认')),
      ],
    );
  }
}

/// 工作区写/改/删的人工闸门——**三处调用点（ws_write / ws_patch / ws_delete）
/// 的逻辑都不动**，档位只改这一个函数 ⇒ 影响面可控（评审批准的实施口径）。
Future<bool> _wsConfirm(PluginContext pc, String title, String body,
    {required WsOpKind kind, bool isOverwrite = false}) async {
  final tier = await WorkspacePermissionStore.load();
  if (!wsNeedsConfirm(tier, kind: kind, isOverwrite: isOverwrite)) {
    // 放行也要留痕：真机排查「AI 什么时候把我文件改了」时，日志里得有一行。
    LoggerService.instance
        .info('[WS] ${kind.name} 按档位「${tier.name}」自动放行（未弹确认）',
            cat: LogCat.ws, tag: 'ws_permission');
    return true;
  }
  final r = await pc.showDialogWidget<bool>(
      _WsConfirmDialog(title: title, body: body));
  return r == true;
}

void _wsToolResult(PluginContext pc, String action, String status,
    String summary, String result, bool isZh) {
  pc.addMessage(ChatMessage.create(
    conversationId: pc.assistantMsg.conversationId,
    role: MessageRole.user,
    // build146（行业分歧安全批 ③）：改走统一外壳。此处 `$result` 曾是**未转义**
    // 的工作区文件内容 ⇒ 一个本地文件即可闭合 </toolresult> 伪造第二条工具结果。
    content: toolResultTag(
      pluginId: 'nexus.builtin.workspace',
      tool: action,
      attrs: {'status': status},
      body: result,
    ),
  ));
}

/// 每个插件共用的 isZh 判定。
bool _wsIsZh(PluginContext pc) =>
    pc.userMsg?.content.contains(RegExp(r'[\u4e00-\u9fff]')) ?? true;

class _WsListPlugin extends ReActPlugin {
  @override
  String get triggerType => 'ws_list';
  @override
  RegExp? get legacyTrigger => null;
  @override
  PluginSource get source => PluginSource.system;
  @override
  PluginMetadata get metadata => const PluginMetadata(
        id: 'nexus.builtin.ws_list',
        name: '工作区列目录',
        version: '1.7.57',
        author: 'Nexus Team',
        description: '列出 AI 文件工作区（只处理文本类小文件，沙箱目录，不执行内容）。',
        homepage: 'https://nexus.local/plugins/ws_list',
        minAppVersion: '1.7.57',
        tags: ['内置', '工作区'],
        promptProtocol: '''
【AI 文件工作区·列目录】输出 <ws_list /> 即列出工作区全部文件（相对路径+大小）。
''',
      );

  @override
  Future<void> handle(BuildContext context, PluginContext pc,
      Map<String, dynamic> attrs) async {
    final isZh = _wsIsZh(pc);
    final step = pc.addReasoningStep('workspace',
        isZh ? '正在列工作区目录' : 'Listing workspace',
        status: 'running');
    try {
      final files = await WorkspaceService.list();
      final body = WorkspaceService.describe(files);
      pc.updateReasoningStep(
          step,
          status: 'success',
          resultSummary: isZh ? '共 ${files.length} 个文件' : '${files.length} files');
      _wsToolResult(pc, 'ws_list', 'success', '', '工作区文件（相对路径）：\n$body', isZh);
    } catch (e) {
      pc.updateReasoningStep(step, status: 'failed', resultSummary: '列目录失败');
      _wsToolResult(pc, 'ws_list', 'failed', '', '列目录失败：$e', isZh);
    }
  }
}

class _WsReadPlugin extends ReActPlugin {
  @override
  String get triggerType => 'ws_read';
  @override
  RegExp? get legacyTrigger => null;
  @override
  PluginSource get source => PluginSource.system;
  @override
  PluginMetadata get metadata => const PluginMetadata(
        id: 'nexus.builtin.ws_read',
        name: '工作区读文件',
        version: '1.7.57',
        author: 'Nexus Team',
        description: '读取 AI 文件工作区内的文件：文本直接回灌，'
            'xlsx/docx/pdf 用 App 自己的解析器抽文本（超 3 万字截断标注）。',
        homepage: 'https://nexus.local/plugins/ws_read',
        minAppVersion: '1.7.57',
        tags: ['内置', '工作区'],
        promptProtocol: '''
【AI 文件工作区·读文件】输出 <ws_read path="相对路径" />，文件内容会回灌给你。
文本类（txt/md/csv/json…）原样回灌；xlsx/docx/pdf 会走 App 的文档解析器抽成文本
（xlsx 出「# 工作表名 + 管道分隔的行」，所以**你自己生成的表格也能读回来核对**）。
读失败时会告诉你原因（超限 / 损坏 / 扫描件 PDF 无文本），不要把它当成「文件不存在」。
''',
      );

  @override
  Future<void> handle(BuildContext context, PluginContext pc,
      Map<String, dynamic> attrs) async {
    final isZh = _wsIsZh(pc);
    final rel = (attrs['path'] as String? ?? '').trim();
    // build141（真机反馈②「能读的读到了，但那个 xlsx 读不了」）：
    // 工作区的二进制白名单（`binaryExtensions` = xlsx/docx/pdf）**恰好就是**
    // AttachmentService 有真解析器的那三类 —— 也就是说这些文件我们既能写、也能读回，
    // 只是 `ws_read` 一直只走文本通道（`WorkspaceService.readText` 对二进制结构性拒绝，
    // 那是 build138 G63 有意加的，当时只修了「别拿文本读 ZIP」）。
    // 而 `AttachmentService.extractDocument()`（按路径、不占附件配额、与用户手动挂附件
    // **同一套** `_process*`）自 build138 起就存在，生产调用点却是 0 个 —— 只有单测在用。
    // ⇒ 本分支就是把这条死能力接上：模型读 xlsx/docx/pdf 时走真解析器，不再回「读不了」。
    if (WorkspaceService.binaryExtensions
        .contains(WorkspaceService.extOf(rel))) {
      await _readDocument(rel, pc, isZh);
      return;
    }
    final step = pc.addReasoningStep('workspace',
        isZh ? '正在读取 $rel' : 'Reading $rel',
        status: 'running');
    final (content, truncated, err) = await WorkspaceService.readText(rel);
    if (err != null) {
      pc.updateReasoningStep(step, status: 'failed', resultSummary: err);
      _wsToolResult(pc, 'ws_read', 'failed', '', '读取「$rel」失败：$err', isZh);
      return;
    }
    pc.updateReasoningStep(step, status: 'success', resultSummary: '已读取');
    _wsToolResult(pc, 'ws_read', 'success', '',
        '文件「$rel」内容${truncated == true ? '（已截断）' : ''}：\n$content', isZh);
  }

  /// 二进制文档（xlsx / docx / pdf）→ 抽文本回灌。
  ///
  /// 三条硬约束：
  /// 1. **必须走 `extractDocument`**，不许在这里另写一份 zip/xml 解析
  ///    （教训 #62：同一语义只留一个实现；且「用 App 里真正那套解析器读回来」
  ///    本身就是 build138 给它留的用途）；
  /// 2. 安全阀**继承**解析器自带的（`_maxXlsxBytes` / `_maxXlsxEntries` /
  ///    `_maxXlsxUncompressedBytes` 等长在 `_processXlsx` 自己身上），
  ///    所以这里不引入新的 zip bomb 面；
  /// 3. 失败**必须说原因**（超限 / 损坏 / 抽出来是空的），不许只回「读不了」——
  ///    与 build138「搜索故障不再报成未找到结果」同族：静默 = 不可排查。
  Future<void> _readDocument(
      String rel, PluginContext pc, bool isZh) async {
    final step = pc.addReasoningStep('workspace',
        isZh ? '正在抽取 $rel' : 'Extracting $rel',
        status: 'running');
    final (abs, resolveErr) = await WorkspaceService.resolve(rel);
    if (abs == null) {
      pc.updateReasoningStep(step,
          status: 'failed', resultSummary: resolveErr ?? '路径无法解析');
      _wsToolResult(pc, 'ws_read', 'failed', '',
          '读取「$rel」失败：${resolveErr ?? '路径无法解析'}', isZh);
      return;
    }
    // `WorkspaceService.resolve` 只校验路径合法性（绝对路径 / 穿越 / 文件名 / 深度），
    // **不校验存在**。不补这一句，「文件不存在」会掉进下面 att == null 的分支，
    // 被报成「文件损坏 / 扩展名不符」——那是不同的病，模型照错提示排查就会走歪。
    if (!File(abs).existsSync()) {
      pc.updateReasoningStep(step, status: 'failed', resultSummary: '文件不存在');
      _wsToolResult(pc, 'ws_read', 'failed', '',
          '读取「$rel」失败：文件不存在（可先用 ws_list 确认路径）', isZh);
      return;
    }
    final att = await AttachmentService().extractDocument(abs);
    final raw = att?.extractedText ?? '';
    // 解析器把**拒绝原因**也塞在 `extractedText` 里（`_errorAttachment` 写的是
    // `[附件无法处理: xxx]`）。不认这个前缀就会把「XLSX 文件超过 30 MB 限制」
    // 当成文件正文回灌给模型、还把这一步标成 success —— 那是把故障报成成功。
    final rejected = raw.startsWith('[附件无法处理');
    final text = rejected ? '' : raw.trim();
    if (att == null || rejected || text.isEmpty) {
      // 三种情况分开说：解析器主动拒绝（自带原因）/ 没产出 / 产出为空（扫描件 PDF）。
      final reason = rejected
          ? raw
              .substring('[附件无法处理: '.length)
              .replaceFirst(RegExp(r'\]$'), '')
              .trim()
          : (att == null
              ? (isZh
                  ? '解析器未能读出内容（文件损坏，或扩展名与实际格式不符）'
                  : 'parser produced nothing (corrupt or extension mismatch)')
              : (isZh
                  ? '文档内没有可抽取的文本（扫描件 PDF 需要 OCR，当前不支持）'
                  : 'no extractable text (scanned PDF needs OCR, not supported)'));
      pc.updateReasoningStep(step, status: 'failed', resultSummary: reason);
      _wsToolResult(pc, 'ws_read', 'failed', '', '读取「$rel」失败：$reason', isZh);
      return;
    }
    final truncated = text.length > WorkspaceService.readBackLimit;
    final body = truncated
        ? '${text.substring(0, WorkspaceService.readBackLimit)}\n'
            '…[已截断，全文 ${text.length} 字符]'
        : text;
    pc.updateReasoningStep(step,
        status: 'success',
        resultSummary: isZh
            ? '已抽取 ${WorkspaceService.extOf(rel).toUpperCase()} 文本'
                '（${text.length} 字符）'
            : 'extracted ${text.length} chars');
    _wsToolResult(pc, 'ws_read', 'success', '',
        '文件「$rel」（${WorkspaceService.extOf(rel).toUpperCase()} 已抽取为文本'
        '${truncated ? '，已截断' : ''}）：\n$body',
        isZh);
  }
}

class _WsWritePlugin extends ReActPlugin {
  @override
  String get triggerType => 'ws_write';
  @override
  RegExp? get legacyTrigger => null;
  @override
  PluginSource get source => PluginSource.system;
  @override
  PluginMetadata get metadata => const PluginMetadata(
        id: 'nexus.builtin.ws_write',
        name: '工作区写文件',
        version: '1.7.57',
        author: 'Nexus Team',
        description: '向 AI 文件工作区写入/改写文本文件（是否弹确认框取决于权限档位，默认必弹、不覆盖）。',
        homepage: 'https://nexus.local/plugins/ws_write',
        minAppVersion: '1.7.57',
        tags: ['内置', '工作区'],
        promptProtocol: '''
【AI 文件工作区·写文件】输出 <ws_write path="相对路径" content="文本内容" overwrite="false" />
- content 一次 ≤8000 字；超长内容请拆多次（换文件名续写，或先 read 再让用户手工合并）。
- overwrite="true" 才覆盖同名文件；写/改前是否弹确认框取决于用户的权限档位（默认必弹），取消则不写。
- **只能写文本**。要 .xlsx / .docx / .pdf 请用 <ws_make_file/>（服务层会拒绝把文本写进这些扩展名，
  硬写只会产出打不开的假文件）；纯数据要兜底就用 .csv。
''',
      );

  @override
  Future<void> handle(BuildContext context, PluginContext pc,
      Map<String, dynamic> attrs) async {
    final isZh = _wsIsZh(pc);
    final rel = (attrs['path'] as String? ?? '').trim();
    final content = (attrs['content'] as String? ?? '');
    final overwrite = attrs['overwrite']?.toString() == 'true';
    final step = pc.addReasoningStep('workspace',
        isZh ? '正在写入 $rel' : 'Writing $rel',
        status: 'running');
    // WS-4：写前当次确认（显示路径+字节数+新建/覆盖），取消则不写
    final bytes = content.codeUnits.length;
    final confirmed = await _wsConfirm(
        pc,
        isZh ? 'AI 想要${overwrite ? '覆盖' : '写入'}文件' : 'AI wants to write',
        '${isZh ? '路径' : 'Path'}：$rel\n${isZh ? '大小' : 'Size'}：$bytes 字符\n'
            '${isZh ? '模式' : 'Mode'}：${overwrite ? (isZh ? '覆盖' : 'overwrite') : (isZh ? '新建（不覆盖）' : 'create')}',
        kind: WsOpKind.write,
        isOverwrite: overwrite);
    if (!confirmed) {
      pc.updateReasoningStep(step, status: 'blocked', resultSummary: '用户取消');
      _wsToolResult(pc, 'ws_write', 'blocked', '', '用户取消了本次写入（未落盘）。', isZh);
      return;
    }
    final (abs, err) =
        await WorkspaceService.writeText(rel, content, overwrite: overwrite);
    if (abs == null) {
      pc.updateReasoningStep(step, status: 'failed', resultSummary: err);
      _wsToolResult(pc, 'ws_write', 'failed', '', '写入「$rel」失败：$err', isZh);
      return;
    }
    pc.updateReasoningStep(step, status: 'success', resultSummary: '已保存');
    _wsToolResult(pc, 'ws_write', 'success', '', '已保存到工作区「$rel」。', isZh);
  }
}

class _WsDeletePlugin extends ReActPlugin {
  @override
  String get triggerType => 'ws_delete';
  @override
  RegExp? get legacyTrigger => null;
  @override
  PluginSource get source => PluginSource.system;
  @override
  PluginMetadata get metadata => const PluginMetadata(
        id: 'nexus.builtin.ws_delete',
        name: '工作区删文件',
        version: '1.7.57',
        author: 'Nexus Team',
        description: '删除 AI 文件工作区内的文件（删前必须弹确认框）。',
        homepage: 'https://nexus.local/plugins/ws_delete',
        minAppVersion: '1.7.57',
        tags: ['内置', '工作区'],
        promptProtocol: '''
【AI 文件工作区·删文件】输出 <ws_delete path="相对路径" />，删前用户会看到确认框，取消则不删。
''',
      );

  @override
  Future<void> handle(BuildContext context, PluginContext pc,
      Map<String, dynamic> attrs) async {
    final isZh = _wsIsZh(pc);
    final rel = (attrs['path'] as String? ?? '').trim();
    final step = pc.addReasoningStep('workspace',
        isZh ? '正在删除 $rel' : 'Deleting $rel',
        status: 'running');
    final confirmed = await _wsConfirm(
        pc,
        isZh ? 'AI 想要删除文件' : 'AI wants to delete',
        '${isZh ? '路径' : 'Path'}：$rel\n${isZh ? '删除后不可恢复，确认？' : 'This cannot be undone. Confirm?'}',
        // 删除＝不可逆：wsNeedsConfirm 里任何档位都返回 true，写死在此以防将来加档漏掉
        kind: WsOpKind.delete);
    if (!confirmed) {
      pc.updateReasoningStep(step, status: 'blocked', resultSummary: '用户取消');
      _wsToolResult(pc, 'ws_delete', 'blocked', '', '用户取消了本次删除。', isZh);
      return;
    }
    try {
      await WorkspaceService.delete(rel);
      pc.updateReasoningStep(step, status: 'success', resultSummary: '已删除');
      _wsToolResult(pc, 'ws_delete', 'success', '', '已删除「$rel」。', isZh);
    } catch (e) {
      pc.updateReasoningStep(step, status: 'failed', resultSummary: '删除失败');
      _wsToolResult(pc, 'ws_delete', 'failed', '', '删除「$rel」失败：$e', isZh);
    }
  }
}

/// build136（G66）：事务式精准编辑——对齐 Codex CLI 的 apply_patch 编辑通道。
///
/// 为什么不让模型用 ws_write 改代码：整文件重写既费 token（手机上直接决定
/// 可用性），又容易把没打算改的地方改掉。ws_patch 用「定位 + 替换」把改动
/// 限定在一处，并**强制模型承诺上下文**：find 不唯一就整体拒绝并回报行号。
class _WsPatchPlugin extends ReActPlugin {
  @override
  String get triggerType => 'ws_patch';
  @override
  RegExp? get legacyTrigger => null;
  @override
  PluginSource get source => PluginSource.system;
  @override
  PluginMetadata get metadata => const PluginMetadata(
        id: 'nexus.builtin.ws_patch',
        name: '工作区精准改文件',
        version: '1.7.76',
        author: 'Nexus Team',
        description: '在工作区文件内做定位式替换（事务式：找不到或不唯一则整体不改）。',
        homepage: 'https://nexus.local/plugins/ws_patch',
        minAppVersion: '1.7.76',
        tags: ['内置', '工作区'],
        promptProtocol: '''
【AI 文件工作区·精准改文件】输出
<ws_patch path="相对路径" find="原文片段" replace="新片段" all="false" />
- find 必须与原文逐字一致（含缩进与换行），并带足上下文使其唯一。
- find 出现多次且 all="false" 会整体拒绝并回报行号；确实要全改才写 all="true"。
- 改代码优先用它，不要用 ws_write 整文件重写（省 token、不易改错地方）。
''',
      );

  @override
  Future<void> handle(BuildContext context, PluginContext pc,
      Map<String, dynamic> attrs) async {
    final isZh = _wsIsZh(pc);
    final rel = (attrs['path'] as String? ?? '').trim();
    final find = attrs['find'] as String? ?? '';
    final replace = attrs['replace'] as String? ?? '';
    final all = attrs['all']?.toString() == 'true';
    final step = pc.addReasoningStep('workspace',
        isZh ? '正在修改 $rel' : 'Patching $rel',
        status: 'running');
    final confirmed = await _wsConfirm(
        pc,
        isZh ? 'AI 想要修改文件' : 'AI wants to patch',
        '${isZh ? '路径' : 'Path'}：$rel\n'
            '${isZh ? '查找' : 'Find'}：${_ellipse(find.replaceAll('\n', '⏎'), 120)}\n'
            '${isZh ? '替换为' : 'Replace'}：${_ellipse(replace.replaceAll('\n', '⏎'), 120)}\n'
            '${isZh ? '范围' : 'Scope'}：${all ? (isZh ? '全部匹配' : 'all') : (isZh ? '仅第一处' : 'first only')}',
        kind: WsOpKind.patch);
    if (!confirmed) {
      pc.updateReasoningStep(step, status: 'blocked', resultSummary: '用户取消');
      _wsToolResult(pc, 'ws_patch', 'blocked', '', '用户取消了本次修改（文件未改动）。', isZh);
      return;
    }
    final (plan, err) =
        await WorkspaceService.applyPatch(rel, find, replace, all: all);
    if (plan != null && !plan.ok) {
      // 事务式拒绝：文件一个字节都没动，把可读原因回灌给模型纠正后重试
      pc.updateReasoningStep(step, status: 'failed', resultSummary: plan.error);
      _wsToolResult(
          pc, 'ws_patch', 'failed', '', '补丁未应用（文件未改动）：${plan.error}', isZh);
      return;
    }
    if (plan == null) {
      pc.updateReasoningStep(step, status: 'failed', resultSummary: err);
      _wsToolResult(pc, 'ws_patch', 'failed', '', '修改「$rel」失败：$err', isZh);
      return;
    }
    pc.updateReasoningStep(step,
        status: 'success', resultSummary: '已改 ${plan.occurrences} 处');
    _wsToolResult(pc, 'ws_patch', 'success', '',
        '已在「$rel」第 ${plan.line} 行起替换 ${plan.occurrences} 处。', isZh);
  }
}

/// build136（G67）：按需检索——对齐 Codex 的 rg/ls/cat 路线。
///
/// 模型不必先整目录回灌：先 grep 定位，再 ws_read/ws_patch 精确作业。
class _WsGrepPlugin extends ReActPlugin {
  @override
  String get triggerType => 'ws_grep';
  @override
  RegExp? get legacyTrigger => null;
  @override
  PluginSource get source => PluginSource.system;
  @override
  PluginMetadata get metadata => const PluginMetadata(
        id: 'nexus.builtin.ws_grep',
        name: '工作区检索',
        version: '1.7.76',
        author: 'Nexus Team',
        description: '在工作区文本文件里按正则检索，返回「文件:行号: 内容」（上限 200 行）。',
        homepage: 'https://nexus.local/plugins/ws_grep',
        minAppVersion: '1.7.76',
        tags: ['内置', '工作区'],
        promptProtocol: '''
【AI 文件工作区·检索】输出 <ws_grep pattern="正则" glob="*.dart" ignore_case="false" />
- 用来定位符号/字符串在第几个文件第几行，避免先整目录读取。
- glob 缺省扫全部文本文件；结果最多 200 行。
''',
      );

  @override
  Future<void> handle(BuildContext context, PluginContext pc,
      Map<String, dynamic> attrs) async {
    final isZh = _wsIsZh(pc);
    final pattern = (attrs['pattern'] as String? ?? '').trim();
    final glob = (attrs['glob'] as String? ?? '').trim();
    final ignoreCase = attrs['ignore_case']?.toString() == 'true';
    final step = pc.addReasoningStep('workspace',
        isZh ? '正在检索 $pattern' : 'Grepping $pattern',
        status: 'running');
    final (hits, err) =
        await WorkspaceService.grep(pattern, glob: glob, ignoreCase: ignoreCase);
    if (err != null) {
      pc.updateReasoningStep(step, status: 'failed', resultSummary: err);
      _wsToolResult(pc, 'ws_grep', 'failed', '', '检索失败：$err', isZh);
      return;
    }
    if (hits.isEmpty) {
      pc.updateReasoningStep(step, status: 'success', resultSummary: '无命中');
      _wsToolResult(pc, 'ws_grep', 'success', '',
          '检索「$pattern」无命中${glob.isEmpty ? '' : '（glob=$glob）'}。', isZh);
      return;
    }
    final capped = hits.length >= WorkspaceService.maxGrepHits;
    final body = hits.take(WorkspaceService.maxGrepHits).join('\n');
    pc.updateReasoningStep(step,
        status: 'success', resultSummary: '命中 ${hits.length} 行');
    _wsToolResult(
        pc,
        'ws_grep',
        'success',
        '',
        '检索「$pattern」命中 ${hits.length} 行${capped ? '（已达上限，结果可能不全）' : ''}：\n$body',
        isZh);
  }
}

class _WsDownloadPlugin extends ReActPlugin {
  @override
  String get triggerType => 'ws_download';
  @override
  RegExp? get legacyTrigger => null;
  @override
  PluginSource get source => PluginSource.system;
  @override
  PluginMetadata get metadata => const PluginMetadata(
        id: 'nexus.builtin.ws_download',
        name: '工作区下载',
        version: '1.7.57',
        author: 'Nexus Team',
        description: '把网络上的文本类文件下载进 AI 文件工作区（仅 HTTPS + 安全审查 + 10MB 上限）。',
        homepage: 'https://nexus.local/plugins/ws_download',
        minAppVersion: '1.7.57',
        tags: ['内置', '工作区'],
        promptProtocol: '''
【AI 文件工作区·下载】输出 <ws_download url="https://…" filename="可选" />。
- 仅 https 文本类文件（txt/md/json/csv/log/xml/html/代码文本），二进制/可执行拒绝。
- 下载后可用 ws_read 读取、ws_write 改写、ws_export 分享。
''',
      );

  @override
  Future<void> handle(BuildContext context, PluginContext pc,
      Map<String, dynamic> attrs) async {
    final isZh = _wsIsZh(pc);
    final url = (attrs['url'] ?? attrs['content'] as String? ?? '').trim();
    final filename = (attrs['filename'] as String? ?? '').trim();
    final step = pc.addReasoningStep('workspace',
        isZh ? '正在下载到工作区：$url' : 'Downloading $url',
        status: 'running');
    if (url.isEmpty) {
      pc.updateReasoningStep(step, status: 'failed', resultSummary: 'URL 为空');
      _wsToolResult(pc, 'ws_download', 'failed', '', '下载失败：URL 为空。', isZh);
      return;
    }
    // build145（循环审查第 7 轮 P0-4）：这条路径此前**不过 `_wsConfirm`** ——
    // ws_write / ws_patch / ws_delete / ws_generate 四处都有人工闸门，唯独它能直接
    // 让手机去拉一个 URL 并写进工作区。它同时跨了两类副作用（出网 + 落盘），
    // 反而是这几条里最需要问一句的那个。确认里必须把 URL 摊开给人看：
    // 「AI 想下载」和「AI 想从 https://x/y 下载」不是一回事，前者没法判断。
    final confirmed = await _wsConfirm(
        pc,
        isZh ? 'AI 想要下载到工作区' : 'AI wants to download into the workspace',
        '${isZh ? '来源' : 'URL'}：$url\n'
            '${isZh ? '存为' : 'As'}：'
            '${filename.trim().isEmpty ? (isZh ? '按 URL 末段命名' : 'from URL path') : filename.trim()}\n'
            '${isZh ? '限制' : 'Limits'}：'
            '${isZh ? '仅 HTTPS · 文本类型 · 上限 10MB' : 'https only · text types · 10MB cap'}',
        kind: WsOpKind.write);
    if (!confirmed) {
      pc.updateReasoningStep(step, status: 'blocked', resultSummary: '用户取消');
      _wsToolResult(pc, 'ws_download', 'blocked', '', '用户取消了本次下载（未发起请求）。',
          isZh);
      return;
    }
    final (rel, bytes, err) =
        await WorkspaceService.downloadFromUrl(url, filename: filename);
    if (err != null) {
      pc.updateReasoningStep(step, status: 'failed', resultSummary: err);
      _wsToolResult(pc, 'ws_download', 'failed', '', '下载「$url」失败：$err', isZh);
      return;
    }
    pc.updateReasoningStep(step, status: 'success', resultSummary: '已下载');
    _wsToolResult(pc, 'ws_download', 'success', '',
        '已保存到工作区「$rel」（$bytes 字节）。', isZh);
  }
}

class _WsExportPlugin extends ReActPlugin {
  @override
  String get triggerType => 'ws_export';
  @override
  RegExp? get legacyTrigger => null;
  @override
  PluginSource get source => PluginSource.system;
  @override
  PluginMetadata get metadata => const PluginMetadata(
        id: 'nexus.builtin.ws_export',
        name: '工作区导出',
        version: '1.7.57',
        author: 'Nexus Team',
        description: '把工作区文件分享出去（系统分享面板）或用系统方式打开。',
        homepage: 'https://nexus.local/plugins/ws_export',
        minAppVersion: '1.7.57',
        tags: ['内置', '工作区'],
        promptProtocol: '''
【AI 文件工作区·导出】输出 <ws_export path="相对路径" mode="share|open" />。
- share：弹系统分享面板；open：用系统方式打开。
''',
      );

  @override
  Future<void> handle(BuildContext context, PluginContext pc,
      Map<String, dynamic> attrs) async {
    final isZh = _wsIsZh(pc);
    final rel = (attrs['path'] ?? attrs['content'] as String? ?? '').trim();
    final mode = (attrs['mode'] as String? ?? 'share').trim();
    final step = pc.addReasoningStep('workspace',
        isZh ? '正在导出 $rel' : 'Exporting $rel',
        status: 'running');
    // build138（G63）：open 无可用应用时服务层会自动回退分享面板，
    // 回退与否如实写进回灌文本，不能让模型以为「已经打开了」。
    String? err;
    var fellBackToShare = false;
    if (mode == 'open') {
      final (e, usedShare) = await WorkspaceService.openExternal(rel);
      err = e;
      fellBackToShare = usedShare;
    } else {
      err = await WorkspaceService.share(rel);
    }
    if (err != null) {
      pc.updateReasoningStep(step, status: 'failed', resultSummary: err);
      _wsToolResult(pc, 'ws_export', 'failed', '', '导出「$rel」失败：$err', isZh);
      return;
    }
    pc.updateReasoningStep(step,
        status: 'success',
        resultSummary: fellBackToShare ? '已改走分享' : '已导出');
    _wsToolResult(
        pc,
        'ws_export',
        'success',
        '',
        mode != 'open'
            ? '已调起分享面板（$rel）。'
            : fellBackToShare
                ? '设备上没有能直接打开「$rel」的应用，已改为调起分享面板，'
                    '用户可自行选择应用打开。'
                : '已用系统方式打开「$rel」。',
        isZh);
  }
}

/// build138（G61–G64）：生成**真文件**（xlsx / docx / pdf，纯数据兜底 csv）。
///
/// 与 ws_write 的分工：ws_write 只能写文本（服务层现在会直接拒绝对
/// .xlsx/.docx/.pdf 写文本），ws_make_file 收的是**文本载荷**——表格用
/// CSV/TSV、文档用 markdown 风格正文——由 [OfficeWriter] 在设备本地渲染成
/// 符合 OOXML / PDF 规范的文件（文件头 `PK` / `%PDF`，可被 WPS/Excel 无警告打开）。
///
/// 三条红线（G64）：
/// 1. 参数里**没有** base64 / 二进制字段；载荷里出现超长 base64 串按结构性
///    错误拒绝（那是模型想把图片塞进文本通道的典型症状）；
/// 2. 不接受 `.xls`/`.doc`/`.html` 这类「换扩展名的假文件」，兜底只有 `.csv`；
/// 3. 渲染失败 = 显式失败并回灌原因，**绝不**退化成「写个同名文本文件交差」。
class _WsMakeFilePlugin extends ReActPlugin {
  @override
  String get triggerType => 'ws_make_file';
  @override
  RegExp? get legacyTrigger => null;
  @override
  PluginSource get source => PluginSource.system;
  @override
  PluginMetadata get metadata => const PluginMetadata(
        id: 'nexus.builtin.ws_make_file',
        name: '工作区生成文件',
        version: '1.7.81',
        author: 'Nexus Team',
        description: '把表格/正文文本渲染成真正的 Excel / Word / PDF 文件存进工作区。',
        homepage: 'https://nexus.local/plugins/ws_make_file',
        minAppVersion: '1.7.81',
        tags: ['内置', '工作区'],
        promptProtocol: '''
【AI 文件工作区·生成真文件】输出
<ws_make_file path="exports/成绩表.xlsx" content="姓名,语文,数学&#10;张三,90,85" kind="xlsx" overwrite="false" title="可选标题" />
- kind：xlsx | docx | pdf | csv | md | txt（给了带扩展名的 path 时可省略）。
- **换行必须写 `&#10;`**（标签属性里写字面的反斜杠 n 不会变成换行，
  整份表格会被压成一行）。走工具调用（function call）通道时直接写真实换行即可。
- xlsx：content 是 CSV 或制表符分隔文本，一行一条记录，第一行通常是表头；
  多个工作表用单独一行「## sheet: 名称」分节。
- docx / pdf：content 是 markdown 正文（# / ## / ### 标题、普通段落、
  以 | 分隔的表格行，|---| 分隔行会被忽略）。
- 只接受文本数据。禁止把 base64 / 二进制内容写进 content（会被拒绝）；
  需要图片请走附件上传，不要塞进单元格。
- 表格类要发给用户但担心对方打不开时，可另生成一份 .csv 兜底。
- 生成后用 <ws_export path="exports/成绩表.xlsx" mode="open|share" /> 打开或分享。
- 覆盖同名文件需显式 overwrite="true"，否则拒绝写入。
''',
      );

  @override
  Future<void> handle(BuildContext context, PluginContext pc,
      Map<String, dynamic> attrs) async {
    final isZh = _wsIsZh(pc);
    final rawPath = (attrs['path'] as String? ?? '').trim();
    final rawKind = (attrs['kind'] as String? ?? '').trim();
    final content = (attrs['content'] as String? ??
            attrs['body'] as String? ??
            attrs['data'] as String? ??
            '')
        .toString();
    final title = (attrs['title'] as String? ?? '').trim();
    final overwrite = attrs['overwrite']?.toString() == 'true';

    final target = OfficeWriter.resolveTarget(path: rawPath, kind: rawKind);
    final shown = target.rel.isEmpty ? rawPath : target.rel;
    final step = pc.addReasoningStep('workspace',
        isZh ? '正在生成 $shown' : 'Generating $shown',
        status: 'running');

    void fail(String reason) {
      pc.updateReasoningStep(step, status: 'failed', resultSummary: reason);
      _wsToolResult(pc, 'ws_make_file', 'failed', '', reason, isZh);
    }

    if (target.error != null) {
      fail(target.error!);
      return;
    }
    if (content.trim().isEmpty) {
      fail('content 为空，没有可生成的内容。');
      return;
    }
    // 载荷红线对**所有**类型生效（csv/md 也不许夹 base64）。
    final payloadErr = OfficeWriter.checkPayload(content);
    if (payloadErr != null) {
      fail(payloadErr);
      return;
    }

    final kind = target.kind;
    final confirmed = await _wsConfirm(
        pc,
        isZh ? 'AI 想要生成文件' : 'AI wants to create a file',
        '${isZh ? '路径' : 'Path'}：${target.rel}\n'
            '${isZh ? '类型' : 'Kind'}：$kind\n'
            '${isZh ? '数据量' : 'Payload'}：${content.length} 字符\n'
            '${isZh ? '模式' : 'Mode'}：'
            '${overwrite ? (isZh ? '覆盖同名文件' : 'overwrite') : (isZh ? '新建（不覆盖）' : 'create')}',
        kind: WsOpKind.write,
        isOverwrite: overwrite);
    if (!confirmed) {
      pc.updateReasoningStep(step, status: 'blocked', resultSummary: '用户取消');
      _wsToolResult(pc, 'ws_make_file', 'blocked', '', '用户取消了本次生成（未落盘）。',
          isZh);
      return;
    }

    List<int>? bytes;
    String? desc;
    switch (kind) {
      case 'xlsx':
        final parsed = OfficeWriter.parseSheets(content);
        if (parsed.error != null) return fail(parsed.error!);
        final (b, e) = OfficeWriter.buildXlsx(parsed.sheets);
        if (e != null) return fail(e);
        bytes = b;
        desc = '${parsed.sheets.length} 个工作表 · '
            '${parsed.sheets.first.rows.length} 行';
        break;
      case 'docx':
        final parsed = OfficeWriter.parseBlocks(content);
        if (parsed.error != null) return fail(parsed.error!);
        final (b, e) =
            OfficeWriter.buildDocx(parsed.blocks, title: title.isEmpty ? null : title);
        if (e != null) return fail(e);
        bytes = b;
        desc = '${parsed.blocks.length} 个段落/块';
        break;
      case 'pdf':
        final parsed = OfficeWriter.parseBlocks(content);
        if (parsed.error != null) return fail(parsed.error!);
        final (fontData, _) = await PdfFontLocator.loadFont();
        final (b, e) = await OfficeWriter.buildPdf(parsed.blocks,
            fontData: fontData,
            title: title.isEmpty ? null : title);
        if (e != null) {
          fail('$e ${isZh ? '（可改用 csv / md 兜底）' : '(fall back to csv / md)'}');
          return;
        }
        bytes = b;
        desc = '${parsed.blocks.length} 个段落/块';
        break;
      case 'csv':
      case 'md':
      case 'txt':
        // 文本类直接走 writeText（与 ws_write 同一落盘通道，口径一致）。
        final (abs, err) = await WorkspaceService.writeText(target.rel, content,
            overwrite: overwrite);
        if (abs == null) return fail('写入「${target.rel}」失败：$err');
        _finish(pc, step, target.rel, kind, utf8.encode(content).length, desc,
            isZh);
        return;
      default:
        return fail('不支持的生成类型 .$kind');
    }
    if (bytes == null) return fail('生成失败：渲染返回空。');
    final (abs, err) = await WorkspaceService.writeBinary(target.rel, bytes,
        overwrite: overwrite);
    if (abs == null) return fail('写入「${target.rel}」失败：$err');
    _finish(pc, step, target.rel, kind, bytes.length, desc, isZh);
  }

  /// 成功收尾：思考面板留「结果卡」，工具消息给出可执行的下一步。
  void _finish(PluginContext pc, ReasoningStep? step, String rel, String kind,
      int bytes, String? desc, bool isZh) {
    final kb = (bytes / 1024).toStringAsFixed(1);
    pc.updateReasoningStep(step,
        status: 'success',
        resultSummary: isZh ? '$kind 已生成（$kb KB）' : '$kind created ($kb KB)');
    _wsToolResult(
        pc,
        'ws_make_file',
        'success',
        '',
        isZh
            ? '已生成真 $kind 文件「$rel」（$kb KB${desc == null ? '' : '，$desc'}）。'
                '请用 <ws_export path="$rel" mode="open" /> 打开或 '
                'mode="share" 分享；不要再自己拼下载链接。'
            : 'Created a real $kind file "$rel" ($kb KB${desc == null ? '' : ', $desc'}). '
                'Use <ws_export path="$rel" mode="open|share" />; never invent a download link.',
        isZh);
  }
}
