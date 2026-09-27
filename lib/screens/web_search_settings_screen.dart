// v1.7.15：拆分自 settings_screen.dart 的 _buildWebSearchSection（原 L750-L1178）
//
// 目的：把 WebSearch 设置从主 SettingsScreen 拆到独立 sub-screen，让 Switch 切换的
// 高度突变只发生在本页面里，主 SettingsScreen 不再受高度突变影响（白窗口根因消除）。
//
// 数据流：通过 Provider<StorageService> 直接读写 web_search_configs 表，不再依赖
// 主 SettingsScreenState 的 _searchCfg / _saveSearchConfig。

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../models/web_search_config.dart';
import '../plugins/plugin_registry.dart';
import '../services/biometric_service.dart';
import '../services/storage_service.dart';
import '../services/web_search_service.dart';
import '../ui/tokens.dart';
import '../utils/app_snackbar.dart';

class WebSearchSettingsScreen extends StatefulWidget {
  const WebSearchSettingsScreen({super.key});

  @override
  State<WebSearchSettingsScreen> createState() =>
      _WebSearchSettingsScreenState();
}

class _WebSearchSettingsScreenState extends State<WebSearchSettingsScreen> {
  // 自有 controller（不再共享主 SettingsScreenState 的 11 个 controller）
  final _tavilyCtrl = TextEditingController();
  final _searxngCtrl = TextEditingController();
  final _ghProxyCtrl = TextEditingController();
  final _serpApiKeyCtrl = TextEditingController();
  final _serpApiEngineCtrl = TextEditingController();
  final _braveApiKeyCtrl = TextEditingController();
  final _googleCseKeyCtrl = TextEditingController();
  final _googleCseIdCtrl = TextEditingController();

  // 自有状态
  WebSearchConfig? _searchCfg;
  int _tavilyMaxResults = 5;
  // build138（甲2）：检索注入深度。这两个字段 v1.3.x 起就存在**并且真的被消费**
  // （web_search_service.dart:729 截断摘要 / :728 结果数上限、
  //   agent_orchestrator.dart:537 编排路径同取 maxResultsInject），
  // 但改造前全 lib **没有任何读取点**（只有 storage/backup 在读写值）
  // ⇒ 用户只能吃默认 400 字 / 5 条，「搜到 10 条却只注入 5 条、每条还只给 400 字」
  // 这类体感问题无从调整。此处补 UI 入口，范围与消费端的 clamp 对齐。
  int _maxSnippetChars = 400;
  int _maxResultsInject = 5;
  bool _testingSearch = false;
  String? _testSearchMsg;
  bool? _testSearchOk;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  @override
  void dispose() {
    _tavilyCtrl.dispose();
    _searxngCtrl.dispose();
    _ghProxyCtrl.dispose();
    _serpApiKeyCtrl.dispose();
    _serpApiEngineCtrl.dispose();
    _braveApiKeyCtrl.dispose();
    _googleCseKeyCtrl.dispose();
    _googleCseIdCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    final storage = context.read<StorageService>();
    final cfg = await storage.getWebSearchConfig();
    if (!mounted) return;
    setState(() {
      _searchCfg = cfg;
      _tavilyMaxResults = cfg.tavilyMaxResults;
      _maxSnippetChars = cfg.maxSnippetCharsPerResult;
      _maxResultsInject = cfg.maxResultsInject;
      _tavilyCtrl.text = cfg.tavilyApiKey;
      _searxngCtrl.text = cfg.searxngInstanceUrl;
      _ghProxyCtrl.text = cfg.githubProxyUrl;
      _serpApiKeyCtrl.text = cfg.serpApiKey;
      _serpApiEngineCtrl.text = cfg.serpapiEngine;
      _braveApiKeyCtrl.text = cfg.braveApiKey;
      _googleCseKeyCtrl.text = cfg.googleCseApiKey;
      _googleCseIdCtrl.text = cfg.googleCseId;
    });
    await context
        .read<PluginRegistry>()
        .setEnabled(PluginRegistry.kSearchPluginId, cfg.webSearchEnabled);
    if (!mounted) return;
  }

  Future<void> _saveConfig() async {
    final cfg = _searchCfg;
    if (cfg == null) return;
    final newCfg = cfg.copyWith(
      tavilyApiKey: _tavilyCtrl.text,
      searxngInstanceUrl: _searxngCtrl.text,
      githubProxyUrl: _ghProxyCtrl.text,
      serpApiKey: _serpApiKeyCtrl.text,
      serpapiEngine: _serpApiEngineCtrl.text,
      braveApiKey: _braveApiKeyCtrl.text,
      googleCseApiKey: _googleCseKeyCtrl.text,
      googleCseId: _googleCseIdCtrl.text,
      tavilyMaxResults: _tavilyMaxResults,
      maxSnippetCharsPerResult: _maxSnippetChars,
      maxResultsInject: _maxResultsInject,
    );
    setState(() => _searchCfg = newCfg);
    await context.read<StorageService>().saveWebSearchConfig(newCfg);
  }

  Future<void> _setWebSearchEnabled(bool value) async {
    final registry = context.read<PluginRegistry>();
    final cfg = _searchCfg;
    if (cfg == null) return;
    if (mounted) {
      setState(() => _searchCfg = cfg.copyWith(webSearchEnabled: value));
    }
    // B-015：总开关此前只改内存态 + 运行时插件态，**唯独没落库**——而联网开关的
    // 权威持久源是 web_search_configs 表，下次启动 _loadConfig 会用库里的旧值
    // 反向 setEnabled 覆盖运行时，用户刚才的切换被整体抹掉（「开关记不住」）。
    // 同页其它所有控件都走 _saveConfig，这里补齐同一出口。
    await _saveConfig();
    await registry.setEnabled(PluginRegistry.kSearchPluginId, value);
  }

  /// build138（甲2）：注入深度滑块行（标签 + 数值 + 滑块 + 一句口径说明）。
  /// 拖动过程中只 setState，`onChangeEnd` 才落库 —— 与本页 tavilyMaxResults
  /// 那条滑块同一套时序（避免每帧写 DB）。
  Widget _buildDepthSlider({
    required String label,
    required String valueText,
    required String hint,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onChangeEnd,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ),
            Text(
              valueText,
              style: TextStyle(fontSize: 12, color: cs.onSurface),
            ),
          ],
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          label: valueText,
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            hint,
            style: TextStyle(fontSize: 11, color: cs.appTextSub),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final cfg = _searchCfg;
    return Scaffold(
      appBar: AppBar(title: Text(l.tr('webSearch'))),
      body: cfg == null
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: _buildSection(l, colorScheme, cfg),
            ),
    );
  }

  Widget _buildSection(
    AppLocalizations l,
    ColorScheme colorScheme,
    WebSearchConfig cfg,
  ) {
    final zh = l.locale.languageCode == 'zh';
    final usable = cfg.isProviderUsable();
    return Container(
      decoration: BoxDecoration(
        color: colorScheme.appPanelLight,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: colorScheme.appBorder),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题 + 总开关
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(Icons.travel_explore_outlined,
                  color: colorScheme.appTextSub),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l.tr('webSearch'),
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 15)),
                    const SizedBox(height: 2),
                    Text(
                      cfg.webSearchEnabled
                          ? l.tr('webSearchMasterSubtitleOn')
                          : l.tr('webSearchMasterSubtitleOff'),
                      style: TextStyle(
                          fontSize: 12, color: colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              Switch(
                value: cfg.webSearchEnabled,
                onChanged: (value) => _setWebSearchEnabled(value),
              ),
            ],
          ),
          if (!cfg.webSearchEnabled)
            const SizedBox(height: 2)
          else ...[
            const SizedBox(height: 10),
            // Provider 选择
            Text('${l.tr('webSearchProvider')}:',
                style: TextStyle(
                    fontSize: 12, color: colorScheme.onSurfaceVariant)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                _providerChip(l, WebSearchProvider.bing, cfg),
                _providerChip(l, WebSearchProvider.duckduckgo, cfg),
                _providerChip(l, WebSearchProvider.tavily, cfg),
                _providerChip(l, WebSearchProvider.serpapi, cfg),
                _providerChip(l, WebSearchProvider.brave, cfg),
                _providerChip(l, WebSearchProvider.googlecse, cfg),
                _providerChip(l, WebSearchProvider.searxng, cfg),
              ],
            ),
            if (!usable) ...[
              const SizedBox(height: 6),
              Text('⚠️ ${l.tr('providerNotUsable')}',
                  style: TextStyle(fontSize: 12, color: colorScheme.tertiary)),
            ],
            // v1.5.2：当前服务商官网链接
            InkWell(
              onTap: () => _openProviderUrl(cfg.provider.officialUrl),
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.open_in_new,
                        size: 14, color: colorScheme.primary),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        zh
                            ? '访问官网（注册 / 查 API Key）'
                            : 'Official site (signup / API key)',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: colorScheme.primary,
                          fontWeight: FontWeight.w600,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Tavily 配置
            if (cfg.provider == WebSearchProvider.tavily) ...[
              TextField(
                controller: _tavilyCtrl,
                obscureText: true,
                decoration: InputDecoration(
                  isDense: true,
                  border: const OutlineInputBorder(),
                  labelText: l.tr('tavilyApiKey'),
                  hintText: l.tr('tavilyApiKeyHint'),
                  prefixIcon: const Icon(Icons.key_outlined, size: 18),
                ),
                onChanged: (_) => _saveConfig(),
              ),
              const SizedBox(height: 8),
              Text(
                  '${l.tr('tavilyDepth')}: ${cfg.tavilySearchDepth == 'auto' ? (zh ? '自动（AI 决定）' : 'Auto (AI decides)') : cfg.tavilySearchDepth}',
                  style: TextStyle(
                      fontSize: 12, color: colorScheme.onSurfaceVariant)),
              Wrap(
                spacing: 6,
                children: [
                  ChoiceChip(
                    label: Text(zh ? '自动（推荐）' : 'Auto (Recommended)'),
                    selected: cfg.tavilySearchDepth == 'auto',
                    onSelected: (_) {
                      setState(() =>
                          _searchCfg = cfg.copyWith(tavilySearchDepth: 'auto'));
                      _saveConfig();
                    },
                  ),
                  ChoiceChip(
                    label: Text(l.tr('tavilyDepthBasic')),
                    selected: cfg.tavilySearchDepth == 'basic',
                    onSelected: (_) {
                      setState(() => _searchCfg =
                          cfg.copyWith(tavilySearchDepth: 'basic'));
                      _saveConfig();
                    },
                  ),
                  ChoiceChip(
                    label: Text(l.tr('tavilyDepthAdvanced')),
                    selected: cfg.tavilySearchDepth == 'advanced',
                    onSelected: (_) {
                      setState(() => _searchCfg =
                          cfg.copyWith(tavilySearchDepth: 'advanced'));
                      _saveConfig();
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // 结果数四档：自动（AI 决定）/基础=5/高级=10/自定义
              // 打开页面时已存值 ≠5 且 ≠10 → 自动落「自定义」档；
              // 自动档执行侧忽略 tavilyMaxResults（配置值保留不删）
              Builder(builder: (context) {
                final tier = cfg.tavilyAutoMaxResults
                    ? 'auto'
                    : (_tavilyMaxResults == 5
                        ? 'basic'
                        : (_tavilyMaxResults == 10 ? 'advanced' : 'custom'));
                void select(String t) {
                  setState(() {
                    switch (t) {
                      case 'auto':
                        _searchCfg =
                            cfg.copyWith(tavilyAutoMaxResults: true);
                        break;
                      case 'basic':
                        _tavilyMaxResults = 5;
                        _searchCfg = cfg.copyWith(
                            tavilyMaxResults: 5,
                            tavilyAutoMaxResults: false);
                        break;
                      case 'advanced':
                        _tavilyMaxResults = 10;
                        _searchCfg = cfg.copyWith(
                            tavilyMaxResults: 10,
                            tavilyAutoMaxResults: false);
                        break;
                      default:
                        _searchCfg =
                            cfg.copyWith(tavilyAutoMaxResults: false);
                    }
                  });
                  _saveConfig();
                }

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        '${l.tr('tavilyMaxResults')}: ${tier == 'auto' ? (zh ? '自动（AI 决定）' : 'Auto (AI decides)') : '$_tavilyMaxResults'}',
                        style: TextStyle(
                            fontSize: 12,
                            color: colorScheme.onSurfaceVariant)),
                    Wrap(
                      spacing: 6,
                      children: [
                        ChoiceChip(
                          label: Text(zh ? '自动' : 'Auto'),
                          selected: tier == 'auto',
                          onSelected: (_) => select('auto'),
                        ),
                        ChoiceChip(
                          label: Text(zh ? '基础 (5)' : 'Basic (5)'),
                          selected: tier == 'basic',
                          onSelected: (_) => select('basic'),
                        ),
                        ChoiceChip(
                          label: Text(zh ? '高级 (10)' : 'Advanced (10)'),
                          selected: tier == 'advanced',
                          onSelected: (_) => select('advanced'),
                        ),
                        ChoiceChip(
                          label: Text(zh ? '自定义' : 'Custom'),
                          selected: tier == 'custom',
                          onSelected: (_) => select('custom'),
                        ),
                      ],
                    ),
                    // v1.7.42 修复（build98 实测反馈·用户规格）：非「自动」档都显示
                    // 调整框 —— 自动=隐藏；基础/高级/自定义=显示；拖动偏离 5/10 时
                    // tier 重算自动落「自定义」（chip 跟跳），与既有推导逻辑闭环
                    if (tier != 'auto')
                      Row(
                        children: [
                          Text('$_tavilyMaxResults',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: colorScheme.onSurfaceVariant)),
                          Expanded(
                            child: Slider(
                              value: _tavilyMaxResults.toDouble(),
                              min: 3,
                              max: 10,
                              divisions: 7,
                              label: '$_tavilyMaxResults',
                              onChanged: (v) => setState(
                                  () => _tavilyMaxResults = v.round()),
                              onChangeEnd: (_) => _saveConfig(),
                            ),
                          ),
                        ],
                      ),
                  ],
                );
              }),
            ],
            // SearXNG 配置
            if (cfg.provider == WebSearchProvider.searxng) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _searxngCtrl,
                decoration: InputDecoration(
                  isDense: true,
                  border: const OutlineInputBorder(),
                  labelText: l.tr('searxngInstance'),
                  hintText: l.tr('searxngInstanceHint'),
                  prefixIcon: const Icon(Icons.dns_outlined, size: 18),
                ),
                onChanged: (_) => _saveConfig(),
              ),
            ],
            // DuckDuckGo 提示
            if (cfg.provider == WebSearchProvider.duckduckgo) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  children: [
                    Icon(Icons.check_circle_outline,
                        size: 16, color: colorScheme.appTextSub),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        zh
                            ? 'DuckDuckGo 直爬模式，无需 API Key，国内可访问。结果可能被反爬限制。'
                            : 'DuckDuckGo direct scraping, no API Key needed. May be rate-limited.',
                        style: TextStyle(
                            fontSize: 12, color: colorScheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            // SerpAPI 配置
            if (cfg.provider == WebSearchProvider.serpapi) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _serpApiKeyCtrl,
                obscureText: true,
                decoration: InputDecoration(
                  isDense: true,
                  border: const OutlineInputBorder(),
                  labelText: 'SerpAPI API Key',
                  hintText: zh
                      ? '到 serpapi.com 注册免费获取（100次/月免费）'
                      : 'Sign up at serpapi.com (100 free/month)',
                  prefixIcon: const Icon(Icons.key_outlined, size: 18),
                ),
                onChanged: (_) => _saveConfig(),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _serpApiEngineCtrl,
                decoration: InputDecoration(
                  isDense: true,
                  border: const OutlineInputBorder(),
                  labelText: zh ? '搜索引擎（默认 google）' : 'Engine (default google)',
                  hintText: zh
                      ? '可选: google / bing / baidu / duckduckgo / yandex'
                      : 'Options: google / bing / baidu / duckduckgo / yandex',
                  prefixIcon: const Icon(Icons.search, size: 18),
                ),
                onChanged: (_) => _saveConfig(),
              ),
            ],
            // Brave Search API 配置
            if (cfg.provider == WebSearchProvider.brave) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _braveApiKeyCtrl,
                obscureText: true,
                decoration: InputDecoration(
                  isDense: true,
                  border: const OutlineInputBorder(),
                  labelText: 'Brave Search API Key',
                  hintText: zh
                      ? '到 brave.com/search/api 注册（2000次/月免费）'
                      : 'Sign up at brave.com/search/api (2000 free/month)',
                  prefixIcon: const Icon(Icons.key_outlined, size: 18),
                ),
                onChanged: (_) => _saveConfig(),
              ),
            ],
            // Google CSE 配置
            if (cfg.provider == WebSearchProvider.googlecse) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _googleCseKeyCtrl,
                obscureText: true,
                decoration: InputDecoration(
                  isDense: true,
                  border: const OutlineInputBorder(),
                  labelText: 'Google CSE API Key',
                  hintText: zh
                      ? 'Google Cloud Console 启用 Custom Search API'
                      : 'Enable Custom Search API in Google Cloud Console',
                  prefixIcon: const Icon(Icons.key_outlined, size: 18),
                ),
                onChanged: (_) => _saveConfig(),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _googleCseIdCtrl,
                decoration: InputDecoration(
                  isDense: true,
                  border: const OutlineInputBorder(),
                  labelText: 'Google CSE 搜索引擎 ID (cx)',
                  hintText: zh
                      ? '到 cse.google.com 创建自定义搜索引擎获取 cx'
                      : 'Create a Custom Search Engine at cse.google.com to get cx',
                  prefixIcon: const Icon(Icons.tag, size: 18),
                ),
                onChanged: (_) => _saveConfig(),
              ),
            ],
            const SizedBox(height: 8),
            // build138（甲2）：**检索注入深度**。这两个字段一直是被真读的
            // （web_search_service.dart:728/729、agent_orchestrator.dart:537），
            // 但改造前没有任何 UI 能改 ⇒ 只能吃默认 5 条 / 400 字。
            // 口径要和上面的「返回结果数」分清：那一条是**向服务商要多少条**，
            // 这里是**其中多少条、每条多少字进 prompt**。
            const SizedBox(height: 10),
            Text(
              zh ? '注入深度（搜到 → 给模型看多少）' : 'Injection depth',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
            ),
            _buildDepthSlider(
              label: zh ? '注入结果数' : 'Results injected',
              valueText: zh ? '$_maxResultsInject 条' : '$_maxResultsInject',
              hint: zh
                  ? '默认 5、最多 10。搜到 10 条但只注入 5 条时，剩下的模型看不到。'
                  : 'Default 5, max 10. Results beyond this cap never reach the model.',
              value: _maxResultsInject.toDouble().clamp(1, 10),
              min: 1,
              max: 10,
              divisions: 9,
              onChanged: (v) => setState(() => _maxResultsInject = v.round()),
              onChangeEnd: (_) => _saveConfig(),
            ),
            _buildDepthSlider(
              label: zh ? '每条摘要字数' : 'Chars per result',
              valueText: zh ? '$_maxSnippetChars 字' : '$_maxSnippetChars',
              hint: zh
                  ? '默认 400，范围 100–2000。调大＝原文更全但 token 涨得快；'
                      '超出部分会被截断（末尾带省略号）。'
                  : 'Default 400, range 100–2000. Larger = more original text, '
                      'more tokens; the rest is truncated with an ellipsis.',
              value: _maxSnippetChars.toDouble().clamp(100, 2000),
              min: 100,
              max: 2000,
              divisions: 19,
              onChanged: (v) => setState(() => _maxSnippetChars = v.round()),
              onChangeEnd: (_) => _saveConfig(),
            ),
            const SizedBox(height: 8),
            // GitHub 下载加速代理
            TextField(
              controller: _ghProxyCtrl,
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                labelText: zh
                    ? 'GitHub 代理（高级·可选）'
                    : 'GitHub proxy (advanced, optional)',
                hintText: zh
                    ? '一般留空：App 已自动选择最快线路（直连/镜像对冲）'
                    : 'Usually empty: app auto-picks fastest route (direct/mirror hedge)',
                prefixIcon: const Icon(Icons.speed_outlined, size: 18),
                suffixIcon: _ghProxyCtrl.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        tooltip: zh ? '清空（改回直连）' : 'Clear (use direct)',
                        onPressed: () {
                          setState(() => _ghProxyCtrl.clear());
                          _saveConfig();
                        },
                      )
                    : null,
              ),
              onChanged: (_) => _saveConfig(),
            ),
            const SizedBox(height: 6),
            // 推荐 chip：点一下自动填入
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                _buildGhProxyChip(
                    'ghproxy.com', 'https://ghproxy.com', zh, colorScheme),
                _buildGhProxyChip(
                    'ghproxy.net', 'https://ghproxy.net', zh, colorScheme),
                _buildGhProxyChip('mirror.ghproxy.com',
                    'https://mirror.ghproxy.com', zh, colorScheme),
                _buildGhProxyChip(
                    'kkgithub (域名替换)', 'https://kkgithub.com', zh, colorScheme),
              ],
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 4),
              child: Text(
                zh
                    ? '国内访问 github.com/.../releases/download/ 慢或超时，填代理后下载会走代理加速。'
                        '前缀型（如 ghproxy.com）拼在原 URL 前；'
                        '域名替换型（如 kkgithub.com）替换 github.com 域名。'
                        '代理失败会自动回退直连重试一次。'
                    : 'CN access to github.com release assets is slow; '
                        'proxy rewrites the download URL. Auto-fallback to direct on failure.',
                style: TextStyle(
                    fontSize: 11, color: colorScheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: 8),
            // 测试搜索连接
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _testingSearch
                      ? null
                      : () async {
                          await _saveConfig();
                          final latest = _searchCfg;
                          if (latest != null && mounted) {
                            await _testSearchConnection(latest);
                          }
                        },
                  icon: _testingSearch
                      ? SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: colorScheme.primary,
                          ),
                        )
                      : const Icon(Icons.network_check, size: 18),
                  label: Text(_testingSearch
                      ? (zh ? '测试中...' : 'Testing...')
                      : (zh ? '测试搜索连接' : 'Test search')),
                ),
                const SizedBox(width: 10),
                if (_testSearchMsg != null)
                  Expanded(
                    child: Text(
                      _testSearchMsg!,
                      style: TextStyle(
                        fontSize: 12,
                        color: _testSearchOk == true
                            ? colorScheme.primary
                            : _testSearchOk == false
                                ? colorScheme.error
                                : colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // v1.7.15：从 settings_screen.dart L1316-L1350 搬过来的 _providerChip
  Widget _providerChip(
      AppLocalizations l, WebSearchProvider p, WebSearchConfig cfg) {
    String label;
    final zh = l.locale.languageCode == 'zh';
    switch (p) {
      case WebSearchProvider.bing:
        label = l.tr('webSearchProviderBing');
        break;
      case WebSearchProvider.duckduckgo:
        label = zh ? 'DuckDuckGo' : 'DuckDuckGo';
        break;
      case WebSearchProvider.tavily:
        label = l.tr('webSearchProviderTavily');
        break;
      case WebSearchProvider.serpapi:
        label = zh ? 'SerpAPI' : 'SerpAPI';
        break;
      case WebSearchProvider.brave:
        label = zh ? 'Brave' : 'Brave';
        break;
      case WebSearchProvider.googlecse:
        label = zh ? 'Google CSE' : 'Google CSE';
        break;
      case WebSearchProvider.searxng:
        label = l.tr('webSearchProviderSearxng');
        break;
    }
    return ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 12.5)),
      selected: cfg.provider == p,
      onSelected: (_) {
        setState(() => _searchCfg = cfg.copyWith(provider: p));
        Future.microtask(_saveConfig);
      },
    );
  }

  // v1.7.15：从 settings_screen.dart L721-L738 搬过来的 _buildGhProxyChip
  Widget _buildGhProxyChip(
      String label, String url, bool zh, ColorScheme colorScheme) {
    final selected = _ghProxyCtrl.text.trim() == url;
    return ChoiceChip(
      showCheckmark: false,
      label: Text(label, style: const TextStyle(fontSize: 11.5)),
      selected: selected,
      selectedColor: colorScheme.primary.withValues(alpha: 0.18),
      side: selected
          ? BorderSide(color: colorScheme.primary.withValues(alpha: 0.6))
          : null,
      onSelected: (_) {
        setState(() {
          _ghProxyCtrl.text = url;
        });
        // v1.7.26 (E8)：与上方 provider / ghModels / maxResults 等 chip 保持
        // 一致，选择代理后立即落库，避免仅改文本框（重启后选择丢失）
        Future.microtask(_saveConfig);
      },
    );
  }

  // v1.7.15：从 settings_screen.dart L741-L747 搬过来的 _openProviderUrl
  Future<void> _openProviderUrl(String url) async {
    if (url.isEmpty) return;
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await BiometricService.guardActivityTransition(
        () => launchUrl(uri, mode: LaunchMode.externalApplication),
        fallbackDuration: const Duration(seconds: 120),
      );
    }
  }

  // v1.7.15：从 settings_screen.dart L436-L459 搬过来的 _testSearchConnection
  Future<void> _testSearchConnection(WebSearchConfig cfg) async {
    final zh = AppLocalizations.of(context).locale.languageCode == 'zh';
    setState(() {
      _testingSearch = true;
      _testSearchOk = null;
      _testSearchMsg = zh ? '测试中...' : 'Testing...';
    });
    final (ok, msg, ms) = await WebSearchService.testConnection(cfg);
    if (mounted) {
      setState(() {
        _testingSearch = false;
        _testSearchOk = ok;
        _testSearchMsg = msg;
      });
      AppSnackBar.showSnackBar(context, 
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: ok
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.error,
          content: Text(ok ? '✅ $msg' : '❌ $msg'),
          duration: Duration(seconds: ok ? 3 : 6),
        ),
      );
    }
  }
}
