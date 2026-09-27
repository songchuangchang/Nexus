import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_localizations_gen.dart';

class AppLocalizations {
  final Locale locale;

  /// v1.7.24 (#11)：数据源切换到 Flutter 官方 gen-l10n（.arb → AppLocalizationsGen）。
  final AppLocalizationsGen _gen;

  AppLocalizations(this.locale) : _gen = lookupAppLocalizationsGen(locale);

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// v1.7.24 (#11)：key → 生成类 getter 映射（数据源 .arb，消费点零改动）。
  static final Map<String,
      String Function(AppLocalizationsGen, Map<String, String>?)> _getterMap = {
    'selectLanguage': (g, _) => g.selectLanguage,
    'selectLanguageSubtitle': (g, _) => g.selectLanguageSubtitle,
    'continueBtn': (g, _) => g.continueBtn,
    'chinese': (g, _) => g.chinese,
    'english': (g, _) => g.english,
    'appTitle': (g, _) => g.appTitle,
    'noConversations': (g, _) => g.noConversations,
    'newChat': (g, _) => g.newChat,
    'clearMessages': (g, _) => g.clearMessages,
    'apiConfigNotFound': (g, _) => g.apiConfigNotFound,
    'goBack': (g, _) => g.goBack,
    'typeAMessage': (g, _) => g.typeAMessage,
    'send': (g, _) => g.send,
    'stop': (g, _) => g.stop,
    'apiSettings': (g, _) => g.apiSettings,
    'apiConfigs': (g, _) => g.apiConfigs,
    'apiConfigsSubtitle': (g, _) => g.apiConfigsSubtitle,
    'addApiConfig': (g, _) => g.addApiConfig,
    'editApiConfig': (g, _) => g.editApiConfig,
    'selectTemplate': (g, _) => g.selectTemplate,
    'selectTemplateSubtitle': (g, _) => g.selectTemplateSubtitle,
    'configName': (g, _) => g.configName,
    'baseUrl': (g, _) => g.baseUrl,
    'apiKey': (g, _) => g.apiKey,
    'model': (g, _) => g.model,
    'systemPrompt': (g, _) => g.systemPrompt,
    'temperature': (g, _) => g.temperature,
    'maxTokens': (g, _) => g.maxTokens,
    'save': (g, _) => g.save,
    'delete': (g, _) => g.delete,
    'cancel': (g, _) => g.cancel,
    'testConnection': (g, _) => g.testConnection,
    'connectionOk': (g, _) => g.connectionOk,
    'connectionFailed': (g, _) => g.connectionFailed,
    'settings': (g, _) => g.settings,
    'about': (g, _) => g.about,
    'aboutSubtitle': (g, _) => g.aboutSubtitle,
    'storage': (g, _) => g.storage,
    'storageSubtitle': (g, _) => g.storageSubtitle,
    'supportedApis': (g, _) => g.supportedApis,
    'supportedApisSubtitle': (g, _) => g.supportedApisSubtitle,
    'supportedApiProviders': (g, _) => g.supportedApiProviders,
    'language': (g, _) => g.language,
    'languageSubtitle': (g, _) => g.languageSubtitle,
    'systemLanguage': (g, _) => g.systemLanguage,
    'appDownloads': (g, _) => g.appDownloads,
    'appDownloadsSubtitle': (g, _) => g.appDownloadsSubtitle,
    'ok': (g, _) => g.ok,
    'downloadApp': (g, _) => g.downloadApp,
    'searchingApp': (g, _) => g.searchingApp,
    'foundSources': (g, _) => g.foundSources,
    'sourceOfficial': (g, _) => g.sourceOfficial,
    'sourceTrustedThirdParty': (g, _) => g.sourceTrustedThirdParty,
    'sourceUnknown': (g, _) => g.sourceUnknown,
    'version': (g, _) => g.version,
    'size': (g, _) => g.size,
    'arch': (g, _) => g.arch,
    'securityLevel': (g, _) => g.securityLevel,
    'officialSigned': (g, _) => g.officialSigned,
    'thirdPartyWarn': (g, _) => g.thirdPartyWarn,
    'unknownRisk': (g, _) => g.unknownRisk,
    'viewDetails': (g, _) => g.viewDetails,
    'chooseSource': (g, _) => g.chooseSource,
    'confirmDownload': (g, _) => g.confirmDownload,
    'confirmDownloadMsg': (g, _) => g.confirmDownloadMsg,
    'fileName': (g, _) => g.fileName,
    'saveLocation': (g, _) => g.saveLocation,
    'sourceUrl': (g, _) => g.sourceUrl,
    'checksum': (g, _) => g.checksum,
    'allowDownload': (g, _) => g.allowDownload,
    'downloading': (g, _) => g.downloading,
    'downloadComplete': (g, _) => g.downloadComplete,
    'downloadFailed': (g, _) => g.downloadFailed,
    'openFolder': (g, _) => g.openFolder,
    'installApk': (g, _) => g.installApk,
    'fileSavedTo': (g, _) => g.fileSavedTo,
    'integrityVerified': (g, _) => g.integrityVerified,
    'integrityFailed': (g, _) => g.integrityFailed,
    'checksumNotProvided': (g, _) => g.checksumNotProvided,
    'viewLogs': (g, _) => g.viewLogs,
    'viewLogsSubtitle': (g, _) => g.viewLogsSubtitle,
    'exportLogs': (g, _) => g.exportLogs,
    'exportLogsSubtitle': (g, _) => g.exportLogsSubtitle,
    'clearLogs': (g, _) => g.clearLogs,
    'clearLogsSubtitle': (g, _) => g.clearLogsSubtitle,
    'clearLogsConfirm': (g, _) => g.clearLogsConfirm,
    'clear': (g, _) => g.clear,
    'open': (g, _) => g.open,
    'openFailed': (g, _) => g.openFailed,
    'logExportedTo': (g, _) => g.logExportedTo,
    'exportFailed': (g, _) => g.exportFailed,
    'logsCleared': (g, _) => g.logsCleared,
    'copied': (g, _) => g.copied,
    'copyAll': (g, _) => g.copyAll,
    'autoScrollOn': (g, _) => g.autoScrollOn,
    'autoScrollOff': (g, _) => g.autoScrollOff,
    'noLogs': (g, _) => g.noLogs,
    'webSearch': (g, _) => g.webSearch,
    'webSearchSubtitle': (g, _) => g.webSearchSubtitle,
    'webSearchMaster': (g, _) => g.webSearchMaster,
    'webSearchMasterSubtitleOn': (g, _) => g.webSearchMasterSubtitleOn,
    'webSearchMasterSubtitleOff': (g, _) => g.webSearchMasterSubtitleOff,
    'webSearchProvider': (g, _) => g.webSearchProvider,
    'webSearchProviderBing': (g, _) => g.webSearchProviderBing,
    'webSearchProviderTavily': (g, _) => g.webSearchProviderTavily,
    'webSearchProviderSearxng': (g, _) => g.webSearchProviderSearxng,
    'tavilyApiKey': (g, _) => g.tavilyApiKey,
    'tavilyApiKeyHint': (g, _) => g.tavilyApiKeyHint,
    'tavilyDepth': (g, _) => g.tavilyDepth,
    'tavilyDepthBasic': (g, _) => g.tavilyDepthBasic,
    'tavilyDepthAdvanced': (g, _) => g.tavilyDepthAdvanced,
    'tavilyMaxResults': (g, _) => g.tavilyMaxResults,
    'searxngInstance': (g, _) => g.searxngInstance,
    'searxngInstanceHint': (g, _) => g.searxngInstanceHint,
    'providerNotUsable': (g, _) => g.providerNotUsable,
    'webSearchSaved': (g, _) => g.webSearchSaved,
    'tavilyKeyMasked': (g, _) => g.tavilyKeyMasked,
    'searchModeOn': (g, _) => g.searchModeOn,
    'searchModeOff': (g, _) => g.searchModeOff,
    'searchModeDisabled': (g, _) => g.searchModeDisabled,
    'searchDisabledHint': (g, _) => g.searchDisabledHint,
    'searchingNow': (g, _) => g.searchingNow,
    'searchResultEmpty': (g, _) => g.searchResultEmpty,
    'aiKnowledgeWarning': (g, _) => g.aiKnowledgeWarning,
    'aiKnowledgeWarningShort': (g, _) => g.aiKnowledgeWarningShort,
    'goToSettings': (g, _) => g.goToSettings,
    'aiDownloadIntro': (g, _) => g.aiDownloadIntro,
    'aiDownloadNeedsWeb': (g, _) => g.aiDownloadNeedsWeb,
    'aiDownloadPrecheckDialog': (g, _) => g.aiDownloadPrecheckDialog,
    'aiDownloadPrecheckBuiltin': (g, _) => g.aiDownloadPrecheckBuiltin,
    'aiDownloadPrecheckWeb': (g, _) => g.aiDownloadPrecheckWeb,
    'aiDownloadPrecheckWebOff': (g, _) => g.aiDownloadPrecheckWebOff,
    'aiKnowledgeDisclaimer': (g, _) => g.aiKnowledgeDisclaimer,
    'confirmContinue': (g, _) => g.confirmContinue,
    'testSearchConnection': (g, _) => g.testSearchConnection,
    'testSearchConnectionSaving': (g, _) => g.testSearchConnectionSaving,
    'testSearchConnectionTesting': (g, _) => g.testSearchConnectionTesting,
    'searchTestNoConfig': (g, _) => g.searchTestNoConfig,
    'searchTestTavilyKeyEmpty': (g, _) => g.searchTestTavilyKeyEmpty,
    'searchTestSearxngUrlEmpty': (g, _) => g.searchTestSearxngUrlEmpty,
    'searchTestBingKeyEmpty': (g, _) => g.searchTestBingKeyEmpty,
    'searchTestBingConfigEmpty': (g, _) => g.searchTestBingConfigEmpty,
    'logPrivacyNote': (g, _) => g.logPrivacyNote,
    'logPrivacyTag': (g, _) => g.logPrivacyTag,
    'securityScan': (g, _) => g.securityScan,
    'securityScanSubtitle': (g, _) => g.securityScanSubtitle,
    'skillspectorEndpoint': (g, _) => g.skillspectorEndpoint,
    'skillspectorEndpointHint': (g, _) => g.skillspectorEndpointHint,
    'enableSkillSecurityScan': (g, _) => g.enableSkillSecurityScan,
    'enableMcpSecurityScan': (g, _) => g.enableMcpSecurityScan,
    'mobsfEndpoint': (g, _) => g.mobsfEndpoint,
    'mobsfEndpointHint': (g, _) => g.mobsfEndpointHint,
    'enableApkSecurityScan': (g, _) => g.enableApkSecurityScan,
    'connectionSuccess': (g, _) => g.connectionSuccess,
    'scanning': (g, _) => g.scanning,
    'scanResult': (g, _) => g.scanResult,
    'riskScore': (g, _) => g.riskScore,
    'lowRisk': (g, _) => g.lowRisk,
    'mediumRisk': (g, _) => g.mediumRisk,
    'highRisk': (g, _) => g.highRisk,
    'criticalRisk': (g, _) => g.criticalRisk,
    'findings': (g, _) => g.findings,
    'unsafeWarning': (g, _) => g.unsafeWarning,
    'continueInstall': (g, _) => g.continueInstall,
    'cancelled': (g, _) => g.cancelled,
    'updateAvailable': (g, _) => g.updateAvailable,
    'update': (g, _) => g.update,
    'currentVersion': (g, _) => g.currentVersion,
    'latestVersion': (g, _) => g.latestVersion,
    'checkingUpdates': (g, _) => g.checkingUpdates,
    'noUpdates': (g, _) => g.noUpdates,
    'fontSize': (g, _) => g.fontSize,
    'fontSizeSubtitle': (g, _) => g.fontSizeSubtitle,
    'fontSizePreview': (g, _) => g.fontSizePreview,
    'fontSizeSmall': (g, _) => g.fontSizeSmall,
    'fontSizeLarge': (g, _) => g.fontSizeLarge,
    'fontSizeReset': (g, _) => g.fontSizeReset,
    // build167：设置里那道「愿意后台化」总闸那一组的文案（zh/en 两份都在 l10n）。
    // 口径见 `lib/utils/background_run_switch.dart` 文件头：**只说我们做了什么**，
    // 不许出现"后台不会中断"那类我们读不到、也不由我们保证的状态断言
    // （165 的结论：能向系统申请的豁免集合是空集，放不放行由 ColorOS 决定）。
    'bgRunGroupHeader': (g, _) => g.bgRunGroupHeader,
    'bgRunTitle': (g, _) => g.bgRunTitle,
    'bgRunSubtitleOn': (g, _) => g.bgRunSubtitleOn,
    'bgRunSubtitleOff': (g, _) => g.bgRunSubtitleOff,
    'bgRunIslandNeedsMaster': (g, _) => g.bgRunIslandNeedsMaster,
    'startChattingWith': (g, a) => g.startChattingWith(a?['model'] ?? ''),
    'searchResultCount': (g, a) => g.searchResultCount(a?['count'] ?? ''),
    'searchTestSuccess': (g, a) => g.searchTestSuccess(a?['msg'] ?? ''),
    'searchTestFail': (g, a) => g.searchTestFail(a?['msg'] ?? ''),
  };

  /// v1.7.24 (#11)：兼容层 —— 通过 _getterMap 委托到生成的 AppLocalizationsGen。
  String tr(String key, {Map<String, String>? args}) {
    final fn = _getterMap[key];
    if (fn == null) return key;
    return fn(_gen, args);
  }
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => ['en', 'zh'].contains(locale.languageCode);

  @override
  Future<AppLocalizations> load(Locale locale) =>
      SynchronousFuture<AppLocalizations>(AppLocalizations(locale));

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}
