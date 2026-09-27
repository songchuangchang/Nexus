import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_gen_en.dart';
import 'app_localizations_gen_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizationsGen
/// returned by `AppLocalizationsGen.of(context)`.
///
/// Applications need to include `AppLocalizationsGen.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations_gen.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizationsGen.localizationsDelegates,
///   supportedLocales: AppLocalizationsGen.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizationsGen.supportedLocales
/// property.
abstract class AppLocalizationsGen {
  AppLocalizationsGen(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizationsGen of(BuildContext context) {
    return Localizations.of<AppLocalizationsGen>(context, AppLocalizationsGen)!;
  }

  static const LocalizationsDelegate<AppLocalizationsGen> delegate =
      _AppLocalizationsGenDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh')
  ];

  /// No description provided for @selectLanguage.
  ///
  /// In en, this message translates to:
  /// **'Select Language'**
  String get selectLanguage;

  /// No description provided for @selectLanguageSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Choose your preferred language'**
  String get selectLanguageSubtitle;

  /// No description provided for @continueBtn.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get continueBtn;

  /// No description provided for @chinese.
  ///
  /// In en, this message translates to:
  /// **'Chinese (Simplified)'**
  String get chinese;

  /// No description provided for @english.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get english;

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'Nexus'**
  String get appTitle;

  /// No description provided for @noConversations.
  ///
  /// In en, this message translates to:
  /// **'No conversations yet'**
  String get noConversations;

  /// No description provided for @newChat.
  ///
  /// In en, this message translates to:
  /// **'New Chat'**
  String get newChat;

  /// No description provided for @clearMessages.
  ///
  /// In en, this message translates to:
  /// **'Clear messages'**
  String get clearMessages;

  /// No description provided for @startChattingWith.
  ///
  /// In en, this message translates to:
  /// **'Start chatting with {model}'**
  String startChattingWith(String model);

  /// No description provided for @apiConfigNotFound.
  ///
  /// In en, this message translates to:
  /// **'API configuration not found'**
  String get apiConfigNotFound;

  /// No description provided for @goBack.
  ///
  /// In en, this message translates to:
  /// **'Go Back'**
  String get goBack;

  /// No description provided for @typeAMessage.
  ///
  /// In en, this message translates to:
  /// **'Type a message...'**
  String get typeAMessage;

  /// No description provided for @send.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get send;

  /// No description provided for @stop.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get stop;

  /// No description provided for @apiSettings.
  ///
  /// In en, this message translates to:
  /// **'API Settings'**
  String get apiSettings;

  /// No description provided for @apiConfigs.
  ///
  /// In en, this message translates to:
  /// **'API Configurations'**
  String get apiConfigs;

  /// No description provided for @apiConfigsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Manage API providers'**
  String get apiConfigsSubtitle;

  /// No description provided for @addApiConfig.
  ///
  /// In en, this message translates to:
  /// **'Add API Config'**
  String get addApiConfig;

  /// No description provided for @editApiConfig.
  ///
  /// In en, this message translates to:
  /// **'Edit API Config'**
  String get editApiConfig;

  /// No description provided for @selectTemplate.
  ///
  /// In en, this message translates to:
  /// **'Quick select a template'**
  String get selectTemplate;

  /// No description provided for @selectTemplateSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Tap a chip below to auto-fill Base URL and recommended model; you only need to paste your API Key.'**
  String get selectTemplateSubtitle;

  /// No description provided for @configName.
  ///
  /// In en, this message translates to:
  /// **'Config Name'**
  String get configName;

  /// No description provided for @baseUrl.
  ///
  /// In en, this message translates to:
  /// **'Base URL'**
  String get baseUrl;

  /// No description provided for @apiKey.
  ///
  /// In en, this message translates to:
  /// **'API Key'**
  String get apiKey;

  /// No description provided for @model.
  ///
  /// In en, this message translates to:
  /// **'Model'**
  String get model;

  /// No description provided for @systemPrompt.
  ///
  /// In en, this message translates to:
  /// **'System Prompt (optional)'**
  String get systemPrompt;

  /// No description provided for @temperature.
  ///
  /// In en, this message translates to:
  /// **'Temperature'**
  String get temperature;

  /// No description provided for @maxTokens.
  ///
  /// In en, this message translates to:
  /// **'Max Tokens'**
  String get maxTokens;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @testConnection.
  ///
  /// In en, this message translates to:
  /// **'Test Connection'**
  String get testConnection;

  /// No description provided for @connectionOk.
  ///
  /// In en, this message translates to:
  /// **'Connection successful!'**
  String get connectionOk;

  /// No description provided for @connectionFailed.
  ///
  /// In en, this message translates to:
  /// **'Connection failed'**
  String get connectionFailed;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @about.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get about;

  /// No description provided for @aboutSubtitle.
  ///
  /// In en, this message translates to:
  /// **'About Nexus'**
  String get aboutSubtitle;

  /// No description provided for @storage.
  ///
  /// In en, this message translates to:
  /// **'Storage'**
  String get storage;

  /// No description provided for @storageSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Data stored locally via SQLite'**
  String get storageSubtitle;

  /// No description provided for @supportedApis.
  ///
  /// In en, this message translates to:
  /// **'Supported APIs'**
  String get supportedApis;

  /// No description provided for @supportedApisSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Any OpenAI-compatible API'**
  String get supportedApisSubtitle;

  /// No description provided for @supportedApiProviders.
  ///
  /// In en, this message translates to:
  /// **'Supported API Providers'**
  String get supportedApiProviders;

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// No description provided for @languageSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Change display language'**
  String get languageSubtitle;

  /// No description provided for @systemLanguage.
  ///
  /// In en, this message translates to:
  /// **'Follow System'**
  String get systemLanguage;

  /// No description provided for @appDownloads.
  ///
  /// In en, this message translates to:
  /// **'App Downloads'**
  String get appDownloads;

  /// No description provided for @appDownloadsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Manage downloaded APK files'**
  String get appDownloadsSubtitle;

  /// No description provided for @ok.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get ok;

  /// No description provided for @downloadApp.
  ///
  /// In en, this message translates to:
  /// **'Download App'**
  String get downloadApp;

  /// No description provided for @searchingApp.
  ///
  /// In en, this message translates to:
  /// **'Searching for download sources...'**
  String get searchingApp;

  /// No description provided for @foundSources.
  ///
  /// In en, this message translates to:
  /// **'Found the following download options:'**
  String get foundSources;

  /// No description provided for @sourceOfficial.
  ///
  /// In en, this message translates to:
  /// **'Official'**
  String get sourceOfficial;

  /// No description provided for @sourceTrustedThirdParty.
  ///
  /// In en, this message translates to:
  /// **'Trusted 3rd Party'**
  String get sourceTrustedThirdParty;

  /// No description provided for @sourceUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown / Risk'**
  String get sourceUnknown;

  /// No description provided for @version.
  ///
  /// In en, this message translates to:
  /// **'Version'**
  String get version;

  /// No description provided for @size.
  ///
  /// In en, this message translates to:
  /// **'Size'**
  String get size;

  /// No description provided for @arch.
  ///
  /// In en, this message translates to:
  /// **'Arch'**
  String get arch;

  /// No description provided for @securityLevel.
  ///
  /// In en, this message translates to:
  /// **'Security'**
  String get securityLevel;

  /// No description provided for @officialSigned.
  ///
  /// In en, this message translates to:
  /// **'Official signature, safe and reliable'**
  String get officialSigned;

  /// No description provided for @thirdPartyWarn.
  ///
  /// In en, this message translates to:
  /// **'Third-party platform, official source recommended'**
  String get thirdPartyWarn;

  /// No description provided for @unknownRisk.
  ///
  /// In en, this message translates to:
  /// **'Unknown source, not recommended'**
  String get unknownRisk;

  /// No description provided for @viewDetails.
  ///
  /// In en, this message translates to:
  /// **'View Details'**
  String get viewDetails;

  /// No description provided for @chooseSource.
  ///
  /// In en, this message translates to:
  /// **'Choose this source'**
  String get chooseSource;

  /// No description provided for @confirmDownload.
  ///
  /// In en, this message translates to:
  /// **'Confirm Download'**
  String get confirmDownload;

  /// No description provided for @confirmDownloadMsg.
  ///
  /// In en, this message translates to:
  /// **'About to download the following file:'**
  String get confirmDownloadMsg;

  /// No description provided for @fileName.
  ///
  /// In en, this message translates to:
  /// **'File name'**
  String get fileName;

  /// No description provided for @saveLocation.
  ///
  /// In en, this message translates to:
  /// **'Save location'**
  String get saveLocation;

  /// No description provided for @sourceUrl.
  ///
  /// In en, this message translates to:
  /// **'Source URL'**
  String get sourceUrl;

  /// No description provided for @checksum.
  ///
  /// In en, this message translates to:
  /// **'SHA256 Checksum'**
  String get checksum;

  /// No description provided for @allowDownload.
  ///
  /// In en, this message translates to:
  /// **'Allow Download'**
  String get allowDownload;

  /// No description provided for @downloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading...'**
  String get downloading;

  /// No description provided for @downloadComplete.
  ///
  /// In en, this message translates to:
  /// **'Download complete!'**
  String get downloadComplete;

  /// No description provided for @downloadFailed.
  ///
  /// In en, this message translates to:
  /// **'Download failed'**
  String get downloadFailed;

  /// No description provided for @openFolder.
  ///
  /// In en, this message translates to:
  /// **'Open Folder'**
  String get openFolder;

  /// No description provided for @installApk.
  ///
  /// In en, this message translates to:
  /// **'Install APK'**
  String get installApk;

  /// No description provided for @fileSavedTo.
  ///
  /// In en, this message translates to:
  /// **'File saved to:'**
  String get fileSavedTo;

  /// No description provided for @integrityVerified.
  ///
  /// In en, this message translates to:
  /// **'File integrity verified (checksum matched)'**
  String get integrityVerified;

  /// No description provided for @integrityFailed.
  ///
  /// In en, this message translates to:
  /// **'File integrity check FAILED, file may be corrupted'**
  String get integrityFailed;

  /// No description provided for @checksumNotProvided.
  ///
  /// In en, this message translates to:
  /// **'Checksum not provided by source'**
  String get checksumNotProvided;

  /// No description provided for @viewLogs.
  ///
  /// In en, this message translates to:
  /// **'View Logs'**
  String get viewLogs;

  /// No description provided for @viewLogsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'View recent app runtime logs'**
  String get viewLogsSubtitle;

  /// No description provided for @exportLogs.
  ///
  /// In en, this message translates to:
  /// **'Export Logs'**
  String get exportLogs;

  /// No description provided for @exportLogsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Export all logs to a single txt file'**
  String get exportLogsSubtitle;

  /// No description provided for @clearLogs.
  ///
  /// In en, this message translates to:
  /// **'Clear Logs'**
  String get clearLogs;

  /// No description provided for @clearLogsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Delete all log files from device'**
  String get clearLogsSubtitle;

  /// No description provided for @clearLogsConfirm.
  ///
  /// In en, this message translates to:
  /// **'Are you sure to clear ALL logs? This cannot be undone.'**
  String get clearLogsConfirm;

  /// No description provided for @clear.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get clear;

  /// No description provided for @open.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get open;

  /// No description provided for @openFailed.
  ///
  /// In en, this message translates to:
  /// **'Open failed'**
  String get openFailed;

  /// No description provided for @logExportedTo.
  ///
  /// In en, this message translates to:
  /// **'Log exported to'**
  String get logExportedTo;

  /// No description provided for @exportFailed.
  ///
  /// In en, this message translates to:
  /// **'Export failed'**
  String get exportFailed;

  /// No description provided for @logsCleared.
  ///
  /// In en, this message translates to:
  /// **'Logs cleared'**
  String get logsCleared;

  /// No description provided for @copied.
  ///
  /// In en, this message translates to:
  /// **'Copied to clipboard'**
  String get copied;

  /// No description provided for @copyAll.
  ///
  /// In en, this message translates to:
  /// **'Copy All'**
  String get copyAll;

  /// No description provided for @autoScrollOn.
  ///
  /// In en, this message translates to:
  /// **'Auto-scroll: ON (tap to pause)'**
  String get autoScrollOn;

  /// No description provided for @autoScrollOff.
  ///
  /// In en, this message translates to:
  /// **'Auto-scroll: OFF (tap to resume)'**
  String get autoScrollOff;

  /// No description provided for @noLogs.
  ///
  /// In en, this message translates to:
  /// **'No logs yet. Send a message or test a connection to generate logs.'**
  String get noLogs;

  /// No description provided for @webSearch.
  ///
  /// In en, this message translates to:
  /// **'Web Search'**
  String get webSearch;

  /// No description provided for @webSearchSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Enable online search for AI responses'**
  String get webSearchSubtitle;

  /// No description provided for @webSearchMaster.
  ///
  /// In en, this message translates to:
  /// **'Master Switch'**
  String get webSearchMaster;

  /// No description provided for @webSearchMasterSubtitleOn.
  ///
  /// In en, this message translates to:
  /// **'All online features enabled (chat search + app download search)'**
  String get webSearchMasterSubtitleOn;

  /// No description provided for @webSearchMasterSubtitleOff.
  ///
  /// In en, this message translates to:
  /// **'Online search disabled. App download for non-built-in apps will prompt to enable this.'**
  String get webSearchMasterSubtitleOff;

  /// No description provided for @webSearchProvider.
  ///
  /// In en, this message translates to:
  /// **'Search Provider'**
  String get webSearchProvider;

  /// No description provided for @webSearchProviderBing.
  ///
  /// In en, this message translates to:
  /// **'Bing (no key required)'**
  String get webSearchProviderBing;

  /// No description provided for @webSearchProviderTavily.
  ///
  /// In en, this message translates to:
  /// **'Tavily (API Key required)'**
  String get webSearchProviderTavily;

  /// No description provided for @webSearchProviderSearxng.
  ///
  /// In en, this message translates to:
  /// **'SearXNG (self-hosted)'**
  String get webSearchProviderSearxng;

  /// No description provided for @tavilyApiKey.
  ///
  /// In en, this message translates to:
  /// **'Tavily API Key'**
  String get tavilyApiKey;

  /// No description provided for @tavilyApiKeyHint.
  ///
  /// In en, this message translates to:
  /// **'tvly-xxxxxxxxxxxx'**
  String get tavilyApiKeyHint;

  /// No description provided for @tavilyDepth.
  ///
  /// In en, this message translates to:
  /// **'Search Depth'**
  String get tavilyDepth;

  /// No description provided for @tavilyDepthBasic.
  ///
  /// In en, this message translates to:
  /// **'Basic (fast)'**
  String get tavilyDepthBasic;

  /// No description provided for @tavilyDepthAdvanced.
  ///
  /// In en, this message translates to:
  /// **'Advanced (accurate)'**
  String get tavilyDepthAdvanced;

  /// No description provided for @tavilyMaxResults.
  ///
  /// In en, this message translates to:
  /// **'Results Count'**
  String get tavilyMaxResults;

  /// No description provided for @searxngInstance.
  ///
  /// In en, this message translates to:
  /// **'SearXNG Instance URL'**
  String get searxngInstance;

  /// No description provided for @searxngInstanceHint.
  ///
  /// In en, this message translates to:
  /// **'https://your-searxng.example.com'**
  String get searxngInstanceHint;

  /// No description provided for @providerNotUsable.
  ///
  /// In en, this message translates to:
  /// **'Current provider misconfigured, will fallback to Bing'**
  String get providerNotUsable;

  /// No description provided for @webSearchSaved.
  ///
  /// In en, this message translates to:
  /// **'Web search settings saved'**
  String get webSearchSaved;

  /// No description provided for @tavilyKeyMasked.
  ///
  /// In en, this message translates to:
  /// **'Tavily Key saved (masked: ***)'**
  String get tavilyKeyMasked;

  /// No description provided for @searchModeOn.
  ///
  /// In en, this message translates to:
  /// **'Web search ENABLED for next message'**
  String get searchModeOn;

  /// No description provided for @searchModeOff.
  ///
  /// In en, this message translates to:
  /// **'Normal chat (no web search)'**
  String get searchModeOff;

  /// No description provided for @searchModeDisabled.
  ///
  /// In en, this message translates to:
  /// **'Web search is disabled in Settings'**
  String get searchModeDisabled;

  /// No description provided for @searchDisabledHint.
  ///
  /// In en, this message translates to:
  /// **'Web search disabled. Go to Settings → Web Search to enable.'**
  String get searchDisabledHint;

  /// No description provided for @searchingNow.
  ///
  /// In en, this message translates to:
  /// **'Searching the web...'**
  String get searchingNow;

  /// No description provided for @searchResultCount.
  ///
  /// In en, this message translates to:
  /// **'Found {count} results, injected into context.'**
  String searchResultCount(String count);

  /// No description provided for @searchResultEmpty.
  ///
  /// In en, this message translates to:
  /// **'No search results found. Answering with internal knowledge.'**
  String get searchResultEmpty;

  /// No description provided for @aiKnowledgeWarning.
  ///
  /// In en, this message translates to:
  /// **'⚠️ This response is based on AI internal knowledge and may be outdated. Tap 🌐 in the input bar to enable real-time web search.'**
  String get aiKnowledgeWarning;

  /// No description provided for @aiKnowledgeWarningShort.
  ///
  /// In en, this message translates to:
  /// **'⚠️ Based on AI internal knowledge — may be outdated.'**
  String get aiKnowledgeWarningShort;

  /// No description provided for @goToSettings.
  ///
  /// In en, this message translates to:
  /// **'Go to Settings'**
  String get goToSettings;

  /// No description provided for @aiDownloadIntro.
  ///
  /// In en, this message translates to:
  /// **'I can help you find & download apps. Tell me the app name, e.g. \"download WeChat\".'**
  String get aiDownloadIntro;

  /// No description provided for @aiDownloadNeedsWeb.
  ///
  /// In en, this message translates to:
  /// **'App search requires web search to be enabled. Open Settings?'**
  String get aiDownloadNeedsWeb;

  /// No description provided for @aiDownloadPrecheckDialog.
  ///
  /// In en, this message translates to:
  /// **'⚠️ App Download Notice'**
  String get aiDownloadPrecheckDialog;

  /// No description provided for @aiDownloadPrecheckBuiltin.
  ///
  /// In en, this message translates to:
  /// **'This app is in the built-in catalog — sources verified ✅'**
  String get aiDownloadPrecheckBuiltin;

  /// No description provided for @aiDownloadPrecheckWeb.
  ///
  /// In en, this message translates to:
  /// **'🌐 This app is NOT in the built-in catalog. Real-time web search will be used; sources found online are third-party and need your confirmation before download.'**
  String get aiDownloadPrecheckWeb;

  /// No description provided for @aiDownloadPrecheckWebOff.
  ///
  /// In en, this message translates to:
  /// **'Web search is OFF. Only built-in catalog can be used. Enable web search in Settings to find more apps.'**
  String get aiDownloadPrecheckWebOff;

  /// No description provided for @aiKnowledgeDisclaimer.
  ///
  /// In en, this message translates to:
  /// **'ℹ️ Note: Any app name I recall comes from my training data and may be outdated. I will verify real availability via web search before presenting links.'**
  String get aiKnowledgeDisclaimer;

  /// No description provided for @confirmContinue.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get confirmContinue;

  /// No description provided for @testSearchConnection.
  ///
  /// In en, this message translates to:
  /// **'Test Search Connection'**
  String get testSearchConnection;

  /// No description provided for @testSearchConnectionSaving.
  ///
  /// In en, this message translates to:
  /// **'Saving…'**
  String get testSearchConnectionSaving;

  /// No description provided for @testSearchConnectionTesting.
  ///
  /// In en, this message translates to:
  /// **'Testing…'**
  String get testSearchConnectionTesting;

  /// No description provided for @searchTestSuccess.
  ///
  /// In en, this message translates to:
  /// **'✅ Search connection OK: {msg}'**
  String searchTestSuccess(String msg);

  /// No description provided for @searchTestFail.
  ///
  /// In en, this message translates to:
  /// **'❌ Search connection failed: {msg}'**
  String searchTestFail(String msg);

  /// No description provided for @searchTestNoConfig.
  ///
  /// In en, this message translates to:
  /// **'No search provider selected. Configure at least one provider first.'**
  String get searchTestNoConfig;

  /// No description provided for @searchTestTavilyKeyEmpty.
  ///
  /// In en, this message translates to:
  /// **'Tavily API Key is empty.'**
  String get searchTestTavilyKeyEmpty;

  /// No description provided for @searchTestSearxngUrlEmpty.
  ///
  /// In en, this message translates to:
  /// **'SearXNG instance URL is empty.'**
  String get searchTestSearxngUrlEmpty;

  /// No description provided for @searchTestBingKeyEmpty.
  ///
  /// In en, this message translates to:
  /// **'Bing Custom Search API Key is empty.'**
  String get searchTestBingKeyEmpty;

  /// No description provided for @searchTestBingConfigEmpty.
  ///
  /// In en, this message translates to:
  /// **'Bing Custom Search ID is empty.'**
  String get searchTestBingConfigEmpty;

  /// No description provided for @logPrivacyNote.
  ///
  /// In en, this message translates to:
  /// **'Logs never include chat content, full API Keys, or personal info. Keys are always masked as ***.'**
  String get logPrivacyNote;

  /// No description provided for @logPrivacyTag.
  ///
  /// In en, this message translates to:
  /// **'🔒 Privacy-first logging'**
  String get logPrivacyTag;

  /// No description provided for @securityScan.
  ///
  /// In en, this message translates to:
  /// **'Security Scan'**
  String get securityScan;

  /// No description provided for @securityScanSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Configure SkillSpector and MobSF services'**
  String get securityScanSubtitle;

  /// No description provided for @skillspectorEndpoint.
  ///
  /// In en, this message translates to:
  /// **'SkillSpector Endpoint'**
  String get skillspectorEndpoint;

  /// No description provided for @skillspectorEndpointHint.
  ///
  /// In en, this message translates to:
  /// **'http://192.168.1.100:8000'**
  String get skillspectorEndpointHint;

  /// No description provided for @enableSkillSecurityScan.
  ///
  /// In en, this message translates to:
  /// **'Enable Skill Security Scan'**
  String get enableSkillSecurityScan;

  /// No description provided for @enableMcpSecurityScan.
  ///
  /// In en, this message translates to:
  /// **'Enable MCP Security Scan'**
  String get enableMcpSecurityScan;

  /// No description provided for @mobsfEndpoint.
  ///
  /// In en, this message translates to:
  /// **'MobSF Endpoint'**
  String get mobsfEndpoint;

  /// No description provided for @mobsfEndpointHint.
  ///
  /// In en, this message translates to:
  /// **'http://192.168.1.100:8080'**
  String get mobsfEndpointHint;

  /// No description provided for @enableApkSecurityScan.
  ///
  /// In en, this message translates to:
  /// **'Enable APK Security Scan'**
  String get enableApkSecurityScan;

  /// No description provided for @connectionSuccess.
  ///
  /// In en, this message translates to:
  /// **'Connection successful'**
  String get connectionSuccess;

  /// No description provided for @scanning.
  ///
  /// In en, this message translates to:
  /// **'Running security scan...'**
  String get scanning;

  /// No description provided for @scanResult.
  ///
  /// In en, this message translates to:
  /// **'Security Scan Result'**
  String get scanResult;

  /// No description provided for @riskScore.
  ///
  /// In en, this message translates to:
  /// **'Risk Score'**
  String get riskScore;

  /// No description provided for @lowRisk.
  ///
  /// In en, this message translates to:
  /// **'Low Risk'**
  String get lowRisk;

  /// No description provided for @mediumRisk.
  ///
  /// In en, this message translates to:
  /// **'Medium Risk'**
  String get mediumRisk;

  /// No description provided for @highRisk.
  ///
  /// In en, this message translates to:
  /// **'High Risk'**
  String get highRisk;

  /// No description provided for @criticalRisk.
  ///
  /// In en, this message translates to:
  /// **'Critical Risk'**
  String get criticalRisk;

  /// No description provided for @findings.
  ///
  /// In en, this message translates to:
  /// **'Findings'**
  String get findings;

  /// No description provided for @unsafeWarning.
  ///
  /// In en, this message translates to:
  /// **'This plugin has security risks, install with caution'**
  String get unsafeWarning;

  /// No description provided for @continueInstall.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get continueInstall;

  /// No description provided for @cancelled.
  ///
  /// In en, this message translates to:
  /// **'Installation cancelled'**
  String get cancelled;

  /// No description provided for @updateAvailable.
  ///
  /// In en, this message translates to:
  /// **'Update Available'**
  String get updateAvailable;

  /// No description provided for @update.
  ///
  /// In en, this message translates to:
  /// **'Update'**
  String get update;

  /// No description provided for @currentVersion.
  ///
  /// In en, this message translates to:
  /// **'Current'**
  String get currentVersion;

  /// No description provided for @latestVersion.
  ///
  /// In en, this message translates to:
  /// **'Latest'**
  String get latestVersion;

  /// No description provided for @checkingUpdates.
  ///
  /// In en, this message translates to:
  /// **'Checking for updates...'**
  String get checkingUpdates;

  /// No description provided for @noUpdates.
  ///
  /// In en, this message translates to:
  /// **'All plugins are up to date'**
  String get noUpdates;

  /// No description provided for @fontSize.
  ///
  /// In en, this message translates to:
  /// **'Font Size'**
  String get fontSize;

  /// No description provided for @fontSizeSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Adjust text size across the app'**
  String get fontSizeSubtitle;

  /// No description provided for @fontSizePreview.
  ///
  /// In en, this message translates to:
  /// **'This is a preview of the text size. The font will look like this everywhere in the app.'**
  String get fontSizePreview;

  /// No description provided for @fontSizeSmall.
  ///
  /// In en, this message translates to:
  /// **'Small'**
  String get fontSizeSmall;

  /// No description provided for @fontSizeLarge.
  ///
  /// In en, this message translates to:
  /// **'Large'**
  String get fontSizeLarge;

  /// No description provided for @fontSizeReset.
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get fontSizeReset;

  /// No description provided for @bgRunGroupHeader.
  ///
  /// In en, this message translates to:
  /// **'Background running'**
  String get bgRunGroupHeader;

  /// No description provided for @bgRunTitle.
  ///
  /// In en, this message translates to:
  /// **'Run in the background'**
  String get bgRunTitle;

  /// No description provided for @bgRunSubtitleOn.
  ///
  /// In en, this message translates to:
  /// **'Leaving the app no longer closes this round’s connection. The system may still drop it.'**
  String get bgRunSubtitleOn;

  /// No description provided for @bgRunSubtitleOff.
  ///
  /// In en, this message translates to:
  /// **'Leaving the app closes this round’s connection and restarts the round when you return. The system may still drop it.'**
  String get bgRunSubtitleOff;

  /// No description provided for @bgRunIslandNeedsMaster.
  ///
  /// In en, this message translates to:
  /// **'Turn on “Run in the background” first; otherwise this row asks for no permission and shows no progress.'**
  String get bgRunIslandNeedsMaster;
}

class _AppLocalizationsGenDelegate
    extends LocalizationsDelegate<AppLocalizationsGen> {
  const _AppLocalizationsGenDelegate();

  @override
  Future<AppLocalizationsGen> load(Locale locale) {
    return SynchronousFuture<AppLocalizationsGen>(
        lookupAppLocalizationsGen(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsGenDelegate old) => false;
}

AppLocalizationsGen lookupAppLocalizationsGen(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsGenEn();
    case 'zh':
      return AppLocalizationsGenZh();
  }

  throw FlutterError(
      'AppLocalizationsGen.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
