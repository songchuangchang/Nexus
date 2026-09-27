// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations_gen.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsGenZh extends AppLocalizationsGen {
  AppLocalizationsGenZh([String locale = 'zh']) : super(locale);

  @override
  String get selectLanguage => '选择语言';

  @override
  String get selectLanguageSubtitle => '请选择你偏好的显示语言';

  @override
  String get continueBtn => '继续';

  @override
  String get chinese => '简体中文';

  @override
  String get english => 'English';

  @override
  String get appTitle => 'Nexus';

  @override
  String get noConversations => '还没有会话';

  @override
  String get newChat => '新建聊天';

  @override
  String get clearMessages => '清空消息';

  @override
  String startChattingWith(String model) {
    return '开始和 $model 对话';
  }

  @override
  String get apiConfigNotFound => '找不到 API 配置';

  @override
  String get goBack => '返回';

  @override
  String get typeAMessage => '输入消息...';

  @override
  String get send => '发送';

  @override
  String get stop => '停止';

  @override
  String get apiSettings => 'API 设置';

  @override
  String get apiConfigs => 'API 配置';

  @override
  String get apiConfigsSubtitle => '管理 API 服务商';

  @override
  String get addApiConfig => '添加 API 配置';

  @override
  String get editApiConfig => '编辑 API 配置';

  @override
  String get selectTemplate => '快速选择模板';

  @override
  String get selectTemplateSubtitle => '选一个常用服务商模板，自动填入地址和模型';

  @override
  String get configName => '配置名称';

  @override
  String get baseUrl => '服务地址';

  @override
  String get apiKey => 'API 密钥';

  @override
  String get model => '模型';

  @override
  String get systemPrompt => '系统提示词（可选）';

  @override
  String get temperature => '温度';

  @override
  String get maxTokens => '最大 Token';

  @override
  String get save => '保存';

  @override
  String get delete => '删除';

  @override
  String get cancel => '取消';

  @override
  String get testConnection => '测试连接';

  @override
  String get connectionOk => '连接成功！';

  @override
  String get connectionFailed => '连接失败';

  @override
  String get settings => '设置';

  @override
  String get about => '关于';

  @override
  String get aboutSubtitle => '关于 Nexus';

  @override
  String get storage => '存储';

  @override
  String get storageSubtitle => '数据通过 SQLite 保存在本地';

  @override
  String get supportedApis => '支持的 API';

  @override
  String get supportedApisSubtitle => '任何兼容 OpenAI 协议的 API';

  @override
  String get supportedApiProviders => '支持的 API 服务商';

  @override
  String get language => '语言';

  @override
  String get languageSubtitle => '切换显示语言';

  @override
  String get systemLanguage => '跟随系统';

  @override
  String get appDownloads => '应用下载';

  @override
  String get appDownloadsSubtitle => '管理已下载的 APK 安装包';

  @override
  String get ok => '好的';

  @override
  String get downloadApp => '下载 APP';

  @override
  String get searchingApp => '正在搜索下载来源...';

  @override
  String get foundSources => '找到以下下载选项：';

  @override
  String get sourceOfficial => '官方';

  @override
  String get sourceTrustedThirdParty => '可信第三方';

  @override
  String get sourceUnknown => '未知 / 有风险';

  @override
  String get version => '版本';

  @override
  String get size => '大小';

  @override
  String get arch => '架构';

  @override
  String get securityLevel => '安全性';

  @override
  String get officialSigned => '官方签名，安全可靠';

  @override
  String get thirdPartyWarn => '第三方平台，建议优先官方';

  @override
  String get unknownRisk => '来源不明，不推荐下载';

  @override
  String get viewDetails => '查看详情';

  @override
  String get chooseSource => '选择此源下载';

  @override
  String get confirmDownload => '确认下载';

  @override
  String get confirmDownloadMsg => '即将下载以下文件：';

  @override
  String get fileName => '文件名';

  @override
  String get saveLocation => '保存位置';

  @override
  String get sourceUrl => '来源链接';

  @override
  String get checksum => '校验值';

  @override
  String get allowDownload => '允许下载';

  @override
  String get downloading => '下载中...';

  @override
  String get downloadComplete => '下载完成！';

  @override
  String get downloadFailed => '下载失败';

  @override
  String get openFolder => '打开文件夹';

  @override
  String get installApk => '安装 APK';

  @override
  String get fileSavedTo => '文件已保存到：';

  @override
  String get integrityVerified => '文件完整性校验通过（校验值匹配）';

  @override
  String get integrityFailed => '文件完整性校验失败，文件可能损坏';

  @override
  String get checksumNotProvided => '来源未提供校验值';

  @override
  String get viewLogs => '查看日志';

  @override
  String get viewLogsSubtitle => '查看最近的运行日志';

  @override
  String get exportLogs => '导出日志';

  @override
  String get exportLogsSubtitle => '把所有日志打包成一个 txt 文件';

  @override
  String get clearLogs => '清空日志';

  @override
  String get clearLogsSubtitle => '删除设备上的所有日志文件';

  @override
  String get clearLogsConfirm => '确定要清空所有日志吗？此操作不可撤销。';

  @override
  String get clear => '清空';

  @override
  String get open => '打开';

  @override
  String get openFailed => '打开失败';

  @override
  String get logExportedTo => '日志已导出到';

  @override
  String get exportFailed => '导出失败';

  @override
  String get logsCleared => '日志已清空';

  @override
  String get copied => '已复制到剪贴板';

  @override
  String get copyAll => '复制全部';

  @override
  String get autoScrollOn => '自动滚动：开（点一下暂停）';

  @override
  String get autoScrollOff => '自动滚动：关（点一下恢复）';

  @override
  String get noLogs => '还没有日志。发条消息或测试一下连接就会产生日志。';

  @override
  String get webSearch => '联网搜索';

  @override
  String get webSearchSubtitle => '让 AI 在回答前先搜索最新信息';

  @override
  String get webSearchMaster => '总开关';

  @override
  String get webSearchMasterSubtitleOn => '已启用：聊天联网搜索 + 应用下载搜索均可使用';

  @override
  String get webSearchMasterSubtitleOff => '已关闭。若要下载内置目录以外的 APP，会提示你先打开此开关。';

  @override
  String get webSearchProvider => '搜索服务商';

  @override
  String get webSearchProviderBing => '必应 Bing（免 Key，国内可用）';

  @override
  String get webSearchProviderTavily => 'Tavily（需 API Key，结果更精准）';

  @override
  String get webSearchProviderSearxng => 'SearXNG（自建/公共实例）';

  @override
  String get tavilyApiKey => 'Tavily API Key';

  @override
  String get tavilyApiKeyHint => 'tvly-xxxxxxxxxxxx';

  @override
  String get tavilyDepth => '搜索深度';

  @override
  String get tavilyDepthBasic => '基础（快速）';

  @override
  String get tavilyDepthAdvanced => '高级（精准）';

  @override
  String get tavilyMaxResults => '返回结果数量';

  @override
  String get searxngInstance => 'SearXNG 实例地址';

  @override
  String get searxngInstanceHint => 'https://你的-searxng.域名.com';

  @override
  String get providerNotUsable => '当前搜索服务商配置不完整，将自动回退到 Bing';

  @override
  String get webSearchSaved => '联网搜索设置已保存';

  @override
  String get tavilyKeyMasked => 'Tavily Key 已保存（已脱敏：***）';

  @override
  String get searchModeOn => '下一条消息将联网搜索';

  @override
  String get searchModeOff => '普通聊天（不联网搜索）';

  @override
  String get searchModeDisabled => '已在设置中关闭联网搜索';

  @override
  String get searchDisabledHint => '联网搜索已关闭。请前往 设置 → 联网搜索 中打开。';

  @override
  String get searchingNow => '正在上网搜索...';

  @override
  String searchResultCount(String count) {
    return '找到 $count 条结果，已注入到回答上下文中。';
  }

  @override
  String get searchResultEmpty => '联网搜索未找到结果，将使用 AI 内置知识回答。';

  @override
  String get aiKnowledgeWarning =>
      '⚠️ 以下内容基于 AI 训练数据生成，可能已过时。点击输入框旁的 🌐 可实时联网搜索最新内容。';

  @override
  String get aiKnowledgeWarningShort => '⚠️ 基于 AI 内置知识，可能已过时。';

  @override
  String get goToSettings => '前往设置';

  @override
  String get aiDownloadIntro => '我可以帮你查找并下载 APP。告诉我应用名称即可，例如\"帮我下载微信\"。';

  @override
  String get aiDownloadNeedsWeb => '下载 APP 需要联网搜索才能工作。要打开设置吗？';

  @override
  String get aiDownloadPrecheckDialog => '⚠️ APP 下载提示';

  @override
  String get aiDownloadPrecheckBuiltin => '此 APP 在官方内置目录中，来源已验证 ✅';

  @override
  String get aiDownloadPrecheckWeb =>
      '🌐 此 APP 不在内置目录中，将通过实时联网搜索查找来源；搜索到的第三方链接需要你确认后才会下载。';

  @override
  String get aiDownloadPrecheckWebOff => '联网搜索已关闭，只能使用内置目录。请在设置中打开联网搜索以获取更多来源。';

  @override
  String get aiKnowledgeDisclaimer =>
      'ℹ️ 提示：我识别到的 APP 名称来自 AI 训练数据，可能不是最新版本。我会通过实时联网搜索确认真实下载地址后再展示给你。';

  @override
  String get confirmContinue => '继续';

  @override
  String get testSearchConnection => '测试搜索连接 / Test';

  @override
  String get testSearchConnectionSaving => '保存配置中…';

  @override
  String get testSearchConnectionTesting => '测试中…';

  @override
  String searchTestSuccess(String msg) {
    return '✅ 搜索连接正常：$msg';
  }

  @override
  String searchTestFail(String msg) {
    return '❌ 搜索连接失败：$msg';
  }

  @override
  String get searchTestNoConfig => '未选择任何搜索服务商，请先配置至少一种。';

  @override
  String get searchTestTavilyKeyEmpty => 'Tavily API Key 为空。';

  @override
  String get searchTestSearxngUrlEmpty => 'SearXNG 实例地址为空。';

  @override
  String get searchTestBingKeyEmpty => 'Bing 自定义搜索 API Key 为空。';

  @override
  String get searchTestBingConfigEmpty => 'Bing 自定义搜索配置 ID 为空。';

  @override
  String get logPrivacyNote =>
      '日志绝不记录聊天内容、完整 API Key 或任何个人敏感信息。所有 Key 均已脱敏为 ***。';

  @override
  String get logPrivacyTag => '🔒 隐私优先的日志记录';

  @override
  String get securityScan => '安全审查';

  @override
  String get securityScanSubtitle => '配置 SkillSpector 和 MobSF 服务';

  @override
  String get skillspectorEndpoint => 'SkillSpector 端点';

  @override
  String get skillspectorEndpointHint => 'http://192.168.1.100:8000';

  @override
  String get enableSkillSecurityScan => '启用 Skill 安全审查';

  @override
  String get enableMcpSecurityScan => '启用 MCP 安全审查';

  @override
  String get mobsfEndpoint => 'MobSF 端点';

  @override
  String get mobsfEndpointHint => 'http://192.168.1.100:8080';

  @override
  String get enableApkSecurityScan => '启用 APK 安全审查';

  @override
  String get connectionSuccess => '连接成功';

  @override
  String get scanning => '正在进行安全审查...';

  @override
  String get scanResult => '安全审查结果';

  @override
  String get riskScore => '风险评分';

  @override
  String get lowRisk => '低风险';

  @override
  String get mediumRisk => '中风险';

  @override
  String get highRisk => '高风险';

  @override
  String get criticalRisk => '极高风险';

  @override
  String get findings => '发现的问题';

  @override
  String get unsafeWarning => '此插件存在安全风险，建议谨慎安装';

  @override
  String get continueInstall => '继续安装';

  @override
  String get cancelled => '已取消安装';

  @override
  String get updateAvailable => '有可用更新';

  @override
  String get update => '更新';

  @override
  String get currentVersion => '当前版本';

  @override
  String get latestVersion => '最新版本';

  @override
  String get checkingUpdates => '正在检查更新...';

  @override
  String get noUpdates => '所有插件已是最新版本';

  @override
  String get fontSize => '字体大小';

  @override
  String get fontSizeSubtitle => '调整应用中文字显示的大小';

  @override
  String get fontSizePreview => '这是字体大小的预览效果。调整后应用中所有文字都会按此比例显示。';

  @override
  String get fontSizeSmall => '小';

  @override
  String get fontSizeLarge => '大';

  @override
  String get fontSizeReset => '恢复默认';

  @override
  String get bgRunGroupHeader => '后台运行';

  @override
  String get bgRunTitle => '愿意后台化';

  @override
  String get bgRunSubtitleOn => '离开 App 时不再由本应用收起这条连接。系统仍可能中止。';

  @override
  String get bgRunSubtitleOff => '离开 App 时收起这条连接，回前台重新发起这一轮。系统仍可能中止。';

  @override
  String get bgRunIslandNeedsMaster => '先打开「愿意后台化」，否则这一行不向系统要权限、也不显示进度。';
}
