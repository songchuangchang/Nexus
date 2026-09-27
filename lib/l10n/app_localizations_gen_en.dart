// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations_gen.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsGenEn extends AppLocalizationsGen {
  AppLocalizationsGenEn([String locale = 'en']) : super(locale);

  @override
  String get selectLanguage => 'Select Language';

  @override
  String get selectLanguageSubtitle => 'Choose your preferred language';

  @override
  String get continueBtn => 'Continue';

  @override
  String get chinese => 'Chinese (Simplified)';

  @override
  String get english => 'English';

  @override
  String get appTitle => 'Nexus';

  @override
  String get noConversations => 'No conversations yet';

  @override
  String get newChat => 'New Chat';

  @override
  String get clearMessages => 'Clear messages';

  @override
  String startChattingWith(String model) {
    return 'Start chatting with $model';
  }

  @override
  String get apiConfigNotFound => 'API configuration not found';

  @override
  String get goBack => 'Go Back';

  @override
  String get typeAMessage => 'Type a message...';

  @override
  String get send => 'Send';

  @override
  String get stop => 'Stop';

  @override
  String get apiSettings => 'API Settings';

  @override
  String get apiConfigs => 'API Configurations';

  @override
  String get apiConfigsSubtitle => 'Manage API providers';

  @override
  String get addApiConfig => 'Add API Config';

  @override
  String get editApiConfig => 'Edit API Config';

  @override
  String get selectTemplate => 'Quick select a template';

  @override
  String get selectTemplateSubtitle =>
      'Tap a chip below to auto-fill Base URL and recommended model; you only need to paste your API Key.';

  @override
  String get configName => 'Config Name';

  @override
  String get baseUrl => 'Base URL';

  @override
  String get apiKey => 'API Key';

  @override
  String get model => 'Model';

  @override
  String get systemPrompt => 'System Prompt (optional)';

  @override
  String get temperature => 'Temperature';

  @override
  String get maxTokens => 'Max Tokens';

  @override
  String get save => 'Save';

  @override
  String get delete => 'Delete';

  @override
  String get cancel => 'Cancel';

  @override
  String get testConnection => 'Test Connection';

  @override
  String get connectionOk => 'Connection successful!';

  @override
  String get connectionFailed => 'Connection failed';

  @override
  String get settings => 'Settings';

  @override
  String get about => 'About';

  @override
  String get aboutSubtitle => 'About Nexus';

  @override
  String get storage => 'Storage';

  @override
  String get storageSubtitle => 'Data stored locally via SQLite';

  @override
  String get supportedApis => 'Supported APIs';

  @override
  String get supportedApisSubtitle => 'Any OpenAI-compatible API';

  @override
  String get supportedApiProviders => 'Supported API Providers';

  @override
  String get language => 'Language';

  @override
  String get languageSubtitle => 'Change display language';

  @override
  String get systemLanguage => 'Follow System';

  @override
  String get appDownloads => 'App Downloads';

  @override
  String get appDownloadsSubtitle => 'Manage downloaded APK files';

  @override
  String get ok => 'OK';

  @override
  String get downloadApp => 'Download App';

  @override
  String get searchingApp => 'Searching for download sources...';

  @override
  String get foundSources => 'Found the following download options:';

  @override
  String get sourceOfficial => 'Official';

  @override
  String get sourceTrustedThirdParty => 'Trusted 3rd Party';

  @override
  String get sourceUnknown => 'Unknown / Risk';

  @override
  String get version => 'Version';

  @override
  String get size => 'Size';

  @override
  String get arch => 'Arch';

  @override
  String get securityLevel => 'Security';

  @override
  String get officialSigned => 'Official signature, safe and reliable';

  @override
  String get thirdPartyWarn =>
      'Third-party platform, official source recommended';

  @override
  String get unknownRisk => 'Unknown source, not recommended';

  @override
  String get viewDetails => 'View Details';

  @override
  String get chooseSource => 'Choose this source';

  @override
  String get confirmDownload => 'Confirm Download';

  @override
  String get confirmDownloadMsg => 'About to download the following file:';

  @override
  String get fileName => 'File name';

  @override
  String get saveLocation => 'Save location';

  @override
  String get sourceUrl => 'Source URL';

  @override
  String get checksum => 'SHA256 Checksum';

  @override
  String get allowDownload => 'Allow Download';

  @override
  String get downloading => 'Downloading...';

  @override
  String get downloadComplete => 'Download complete!';

  @override
  String get downloadFailed => 'Download failed';

  @override
  String get openFolder => 'Open Folder';

  @override
  String get installApk => 'Install APK';

  @override
  String get fileSavedTo => 'File saved to:';

  @override
  String get integrityVerified => 'File integrity verified (checksum matched)';

  @override
  String get integrityFailed =>
      'File integrity check FAILED, file may be corrupted';

  @override
  String get checksumNotProvided => 'Checksum not provided by source';

  @override
  String get viewLogs => 'View Logs';

  @override
  String get viewLogsSubtitle => 'View recent app runtime logs';

  @override
  String get exportLogs => 'Export Logs';

  @override
  String get exportLogsSubtitle => 'Export all logs to a single txt file';

  @override
  String get clearLogs => 'Clear Logs';

  @override
  String get clearLogsSubtitle => 'Delete all log files from device';

  @override
  String get clearLogsConfirm =>
      'Are you sure to clear ALL logs? This cannot be undone.';

  @override
  String get clear => 'Clear';

  @override
  String get open => 'Open';

  @override
  String get openFailed => 'Open failed';

  @override
  String get logExportedTo => 'Log exported to';

  @override
  String get exportFailed => 'Export failed';

  @override
  String get logsCleared => 'Logs cleared';

  @override
  String get copied => 'Copied to clipboard';

  @override
  String get copyAll => 'Copy All';

  @override
  String get autoScrollOn => 'Auto-scroll: ON (tap to pause)';

  @override
  String get autoScrollOff => 'Auto-scroll: OFF (tap to resume)';

  @override
  String get noLogs =>
      'No logs yet. Send a message or test a connection to generate logs.';

  @override
  String get webSearch => 'Web Search';

  @override
  String get webSearchSubtitle => 'Enable online search for AI responses';

  @override
  String get webSearchMaster => 'Master Switch';

  @override
  String get webSearchMasterSubtitleOn =>
      'All online features enabled (chat search + app download search)';

  @override
  String get webSearchMasterSubtitleOff =>
      'Online search disabled. App download for non-built-in apps will prompt to enable this.';

  @override
  String get webSearchProvider => 'Search Provider';

  @override
  String get webSearchProviderBing => 'Bing (no key required)';

  @override
  String get webSearchProviderTavily => 'Tavily (API Key required)';

  @override
  String get webSearchProviderSearxng => 'SearXNG (self-hosted)';

  @override
  String get tavilyApiKey => 'Tavily API Key';

  @override
  String get tavilyApiKeyHint => 'tvly-xxxxxxxxxxxx';

  @override
  String get tavilyDepth => 'Search Depth';

  @override
  String get tavilyDepthBasic => 'Basic (fast)';

  @override
  String get tavilyDepthAdvanced => 'Advanced (accurate)';

  @override
  String get tavilyMaxResults => 'Results Count';

  @override
  String get searxngInstance => 'SearXNG Instance URL';

  @override
  String get searxngInstanceHint => 'https://your-searxng.example.com';

  @override
  String get providerNotUsable =>
      'Current provider misconfigured, will fallback to Bing';

  @override
  String get webSearchSaved => 'Web search settings saved';

  @override
  String get tavilyKeyMasked => 'Tavily Key saved (masked: ***)';

  @override
  String get searchModeOn => 'Web search ENABLED for next message';

  @override
  String get searchModeOff => 'Normal chat (no web search)';

  @override
  String get searchModeDisabled => 'Web search is disabled in Settings';

  @override
  String get searchDisabledHint =>
      'Web search disabled. Go to Settings → Web Search to enable.';

  @override
  String get searchingNow => 'Searching the web...';

  @override
  String searchResultCount(String count) {
    return 'Found $count results, injected into context.';
  }

  @override
  String get searchResultEmpty =>
      'No search results found. Answering with internal knowledge.';

  @override
  String get aiKnowledgeWarning =>
      '⚠️ This response is based on AI internal knowledge and may be outdated. Tap 🌐 in the input bar to enable real-time web search.';

  @override
  String get aiKnowledgeWarningShort =>
      '⚠️ Based on AI internal knowledge — may be outdated.';

  @override
  String get goToSettings => 'Go to Settings';

  @override
  String get aiDownloadIntro =>
      'I can help you find & download apps. Tell me the app name, e.g. \"download WeChat\".';

  @override
  String get aiDownloadNeedsWeb =>
      'App search requires web search to be enabled. Open Settings?';

  @override
  String get aiDownloadPrecheckDialog => '⚠️ App Download Notice';

  @override
  String get aiDownloadPrecheckBuiltin =>
      'This app is in the built-in catalog — sources verified ✅';

  @override
  String get aiDownloadPrecheckWeb =>
      '🌐 This app is NOT in the built-in catalog. Real-time web search will be used; sources found online are third-party and need your confirmation before download.';

  @override
  String get aiDownloadPrecheckWebOff =>
      'Web search is OFF. Only built-in catalog can be used. Enable web search in Settings to find more apps.';

  @override
  String get aiKnowledgeDisclaimer =>
      'ℹ️ Note: Any app name I recall comes from my training data and may be outdated. I will verify real availability via web search before presenting links.';

  @override
  String get confirmContinue => 'Continue';

  @override
  String get testSearchConnection => 'Test Search Connection';

  @override
  String get testSearchConnectionSaving => 'Saving…';

  @override
  String get testSearchConnectionTesting => 'Testing…';

  @override
  String searchTestSuccess(String msg) {
    return '✅ Search connection OK: $msg';
  }

  @override
  String searchTestFail(String msg) {
    return '❌ Search connection failed: $msg';
  }

  @override
  String get searchTestNoConfig =>
      'No search provider selected. Configure at least one provider first.';

  @override
  String get searchTestTavilyKeyEmpty => 'Tavily API Key is empty.';

  @override
  String get searchTestSearxngUrlEmpty => 'SearXNG instance URL is empty.';

  @override
  String get searchTestBingKeyEmpty => 'Bing Custom Search API Key is empty.';

  @override
  String get searchTestBingConfigEmpty => 'Bing Custom Search ID is empty.';

  @override
  String get logPrivacyNote =>
      'Logs never include chat content, full API Keys, or personal info. Keys are always masked as ***.';

  @override
  String get logPrivacyTag => '🔒 Privacy-first logging';

  @override
  String get securityScan => 'Security Scan';

  @override
  String get securityScanSubtitle =>
      'Configure SkillSpector and MobSF services';

  @override
  String get skillspectorEndpoint => 'SkillSpector Endpoint';

  @override
  String get skillspectorEndpointHint => 'http://192.168.1.100:8000';

  @override
  String get enableSkillSecurityScan => 'Enable Skill Security Scan';

  @override
  String get enableMcpSecurityScan => 'Enable MCP Security Scan';

  @override
  String get mobsfEndpoint => 'MobSF Endpoint';

  @override
  String get mobsfEndpointHint => 'http://192.168.1.100:8080';

  @override
  String get enableApkSecurityScan => 'Enable APK Security Scan';

  @override
  String get connectionSuccess => 'Connection successful';

  @override
  String get scanning => 'Running security scan...';

  @override
  String get scanResult => 'Security Scan Result';

  @override
  String get riskScore => 'Risk Score';

  @override
  String get lowRisk => 'Low Risk';

  @override
  String get mediumRisk => 'Medium Risk';

  @override
  String get highRisk => 'High Risk';

  @override
  String get criticalRisk => 'Critical Risk';

  @override
  String get findings => 'Findings';

  @override
  String get unsafeWarning =>
      'This plugin has security risks, install with caution';

  @override
  String get continueInstall => 'Continue';

  @override
  String get cancelled => 'Installation cancelled';

  @override
  String get updateAvailable => 'Update Available';

  @override
  String get update => 'Update';

  @override
  String get currentVersion => 'Current';

  @override
  String get latestVersion => 'Latest';

  @override
  String get checkingUpdates => 'Checking for updates...';

  @override
  String get noUpdates => 'All plugins are up to date';

  @override
  String get fontSize => 'Font Size';

  @override
  String get fontSizeSubtitle => 'Adjust text size across the app';

  @override
  String get fontSizePreview =>
      'This is a preview of the text size. The font will look like this everywhere in the app.';

  @override
  String get fontSizeSmall => 'Small';

  @override
  String get fontSizeLarge => 'Large';

  @override
  String get fontSizeReset => 'Reset';

  @override
  String get bgRunGroupHeader => 'Background running';

  @override
  String get bgRunTitle => 'Run in the background';

  @override
  String get bgRunSubtitleOn =>
      'Leaving the app no longer closes this round’s connection. The system may still drop it.';

  @override
  String get bgRunSubtitleOff =>
      'Leaving the app closes this round’s connection and restarts the round when you return. The system may still drop it.';

  @override
  String get bgRunIslandNeedsMaster =>
      'Turn on “Run in the background” first; otherwise this row asks for no permission and shows no progress.';
}
