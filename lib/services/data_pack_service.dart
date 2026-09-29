// build138 / G54–G56：数据/资源包热更 —— 统一服务层。
//
// 收敛前的事实（grep 实证）：仓库里真正「内置兜底 + 远程覆盖」的数据包有三个，
// 各自实现一套 SharedPreferences 缓存 + 7 天刷新 + 失败不清缓存：
//   ① 厂商模板  ApiProviderTemplateCatalog （lib/models/api_provider_template.dart）
//   ② 内置提示词 / 插件 ReAct 协议  BuiltinPromptCatalog（lib/services/builtin_prompt_catalog.dart）
//      —— 任务书写的 `plugin_prompt_catalog.dart` 是纯函数目录构建器，
//         插件协议的**远程数据**实际落在 BuiltinPromptCatalog，这里按真实实现收敛。
//   ③ MCP 连接器目录  McpCatalog （lib/models/mcp_catalog.dart，此前自己直连拉取、
//      无 7 天策略、无版本闸门）
//
// 收敛后：缓存读写、多源有序回退、版本/校验闸门、状态记账**只在本文件实现一次**；
// 三个 catalog 只保留「把 JSON 应用进内存」的能力（G46 的模板「只增不删」合并
// 原样保留在 ApiProviderTemplateCatalog.all 里，不在本文件重复实现）。
//
// 网络可注入（[DataPackFetcher]）：单测喂假响应，绝不真发请求。
import 'dart:async';

import 'live_task_center.dart';
import 'live_task_wiring.dart';
import 'repo_endpoints.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';
import '../models/api_provider_template.dart';
import '../models/mcp_catalog.dart';
import 'builtin_prompt_catalog.dart';
import 'data_pack_baseline.dart';
import 'data_pack_pref_keys.dart';
import 'data_pack_protocol.dart';
import 'github_content_fetcher.dart';
import 'logger_service.dart';

export 'data_pack_pref_keys.dart' show DataPackPrefKeys;
export 'data_pack_protocol.dart';
export '../models/api_provider_template.dart' show TemplateBaseUrlOverride;

/// 取一个 URL 的抽象（生产 = GitHubContentFetcher 自适应候选链）。
typedef DataPackFetcher = Future<String> Function(String url);

/// 默认拉取：统一走 GitHubContentFetcher（用户代理 → direct → ghproxy 三兄弟 → jsdelivr）。
Future<String> _defaultFetcher(String url) => GitHubContentFetcher.fetchText(
      url,
      headers: const {'Accept': 'application/json'},
      totalTimeout: const Duration(seconds: 20),
      tag: 'DataPack',
    );

/// 一个包的静态描述 + 落地钩子。
class DataPackSpec {
  const DataPackSpec({
    required this.id,
    required this.nameZh,
    required this.nameEn,
    required this.urlKey,
    required this.jsonKey,
    required this.updatedKey,
    required this.retryKey,
    required this.defaultSources,
    required this.applyPayload,
    required this.clearApplied,
    required this.countItems,
    this.descriptionZh = '',
    this.descriptionEn = '',
  });

  final String id;
  final String nameZh;
  final String nameEn;
  final String descriptionZh;
  final String descriptionEn;

  /// SharedPreferences 键（沿用既有键名 → 老用户不丢配置）。
  final String urlKey;
  final String jsonKey;
  final String updatedKey;
  final String retryKey;

  /// 内置默认源（有序：主 → 备）。用户自定义源非空时优先用户配置。
  final List<String> defaultSources;

  /// 把校验通过的原始 JSON 应用进对应 catalog（内存生效）。
  final Future<bool> Function(String rawJson) applyPayload;

  /// 丢弃已应用的远程数据，回落内置。
  final Future<void> Function(SharedPreferences prefs) clearApplied;

  /// 有效条目数（0 视为空包，拒绝应用）。
  final int Function(Object? decoded) countItems;
}

class _Pack {
  _Pack(this.spec, List<String> sources) : sources = List.of(sources);

  final DataPackSpec spec;
  List<String> sources;

  DataPackStatus status = DataPackStatus.builtin;
  DataPackReject reject = DataPackReject.none;
  String detail = '';
  String? remoteDataVersion;
  DateTime? lastUpdatedAt;
  int appliedCount = 0;
  bool hasRemoteData = false;

  /// 本次生效的远程数据是从本地缓存读出来的（陈旧判定用）。
  bool loadedFromCache = false;

  // S1（build172）：apiTemplates 包「改写内置厂商 baseUrl」的二次确认挂起现场。
  // 非 apiTemplates 包恒为空；pendingRaw != null ⇒ 有载荷正等用户确认。
  String? pendingRaw;
  String? pendingDataVersion;
  int pendingItemCount = 0;
  List<TemplateBaseUrlOverride> pendingOverrides = const [];

  DataPackState snapshot() => DataPackState(
        id: spec.id,
        nameZh: spec.nameZh,
        nameEn: spec.nameEn,
        sourceUrls: List.unmodifiable(sources),
        status: status,
        reject: reject,
        detail: detail,
        remoteDataVersion: remoteDataVersion,
        lastUpdatedAt: lastUpdatedAt,
        appliedCount: appliedCount,
        hasRemoteData: hasRemoteData,
      );
}

/// 一次「已过版本闸门的载荷」进 catalog 的结果（S1 确认闸引入）。
enum _PackApplyOutcome {
  /// 已真正应用进 catalog（缓存重放 / 远程刷新两条路径共用）。
  applied,

  /// apiTemplates 包检出「改写内置厂商 baseUrl」⇒ 挂起待用户确认，本轮不应用。
  pended,

  /// applyPayload 返回 false（载荷解析失败等），按既有语义记账。
  failed,
}

/// S1（build172）：一个包当前挂起的「待二次确认」载荷快照（目前只有
/// apiTemplates 包会出现；UI 从 [DataPackService.pendingOf] 读它）。
class DataPackPendingConfirmation {
  const DataPackPendingConfirmation({
    required this.packId,
    required this.rawJson,
    required this.dataVersion,
    required this.itemCount,
    required this.overrides,
  });

  final String packId;

  /// 挂起的原始载荷（确认时原样应用的就是这份字节）。
  final String rawJson;
  final String dataVersion;
  final int itemCount;

  /// 检出改写的内置厂商清单（id / 显示名 / 内置地址 → 远程地址）。
  final List<TemplateBaseUrlOverride> overrides;
}

/// 数据/资源包统一服务（G54/G55/G56 的唯一实现点）。
class DataPackService extends ChangeNotifier {
  DataPackService({DataPackFetcher? fetcher, String? appVersion})
      : _fetcher = fetcher ?? _defaultFetcher,
        _appVersion = appVersion ?? kAppVersionConst {
    _packs = _allSpecs(appVersion: _appVersion)
        .map((s) => _Pack(s, List.of(s.defaultSources)))
        .toList();
  }

  static final DataPackService instance = DataPackService();

  static const String packApiTemplates = 'api_templates';
  static const String packBuiltinPrompts = 'builtin_prompts';
  static const String packMcpCatalog = 'mcp_catalog';

  DataPackFetcher _fetcher;
  final String _appVersion;
  late final List<_Pack> _packs;

  final LoggerService _logger = LoggerService.instance;

  List<String> get packIds => _packs.map((p) => p.spec.id).toList(growable: false);

  /// 三个包的版本/时间/状态一次读出（G56：页面只消费这个）。
  List<DataPackState> get states =>
      _packs.map((p) => p.snapshot()).toList(growable: false);

  DataPackState? stateOf(String id) {
    final p = _find(id);
    return p?.snapshot();
  }

  _Pack? _find(String id) {
    for (final p in _packs) {
      if (p.spec.id == id) return p;
    }
    return null;
  }

  /// 测试钩子：把单例状态打回「只有内置数据」。
  @visibleForTesting
  static void resetAllForTest() {
    instance._reset();
  }

  /// 测试钩子：替换单例的取源实现（页面级测试同样绝不真发请求）。
  /// 传 null 恢复生产实现。
  @visibleForTesting
  static void useFetcherForTest(DataPackFetcher? fetcher) {
    instance._fetcher = fetcher ?? _defaultFetcher;
  }

  @visibleForTesting
  void resetForTest() => _reset();

  void _reset() {
    for (final p in _packs) {
      p.sources = List.of(p.spec.defaultSources);
      p.status = DataPackStatus.builtin;
      p.reject = DataPackReject.none;
      p.detail = '';
      p.remoteDataVersion = null;
      p.lastUpdatedAt = null;
      p.appliedCount = 0;
      p.hasRemoteData = false;
      p.loadedFromCache = false;
      p.pendingRaw = null;
      p.pendingDataVersion = null;
      p.pendingItemCount = 0;
      p.pendingOverrides = const [];
    }
  }

  // ==================================================================
  // 启动：读本地缓存 → 按 7 天/retryPending 决定是否刷新
  // ==================================================================

  /// [deferRemoteRefresh] = true 时远程刷新挪后台，**不阻塞启动**（沿用既有语义）。
  /// 任何包的失败都只记账，绝不抛异常给启动链路。
  Future<void> initialize({bool deferRemoteRefresh = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final due = <_Pack>[];
    for (final p in _packs) {
      final stored = parseDataPackSources(prefs.getString(p.spec.urlKey));
      p.sources = stored.isNotEmpty ? stored : List.of(p.spec.defaultSources);

      final cachedAt =
          DateTime.tryParse(prefs.getString(p.spec.updatedKey) ?? '');
      final cachedRaw = prefs.getString(p.spec.jsonKey);
      if (cachedRaw != null && cachedRaw.isNotEmpty) {
        final check = evaluateDataPackPayload(
          rawJson: cachedRaw,
          baselineVersion: await readAppliedBaseline(p.spec.id),
          appVersion: _appVersion,
          itemCountOf: p.spec.countItems,
        );
        var outcome = _PackApplyOutcome.failed;
        if (check.accepted) {
          try {
            outcome = await _applyPackPayload(p, cachedRaw, check, prefs);
          } catch (e) {
            _logger.warn('${p.spec.id} 应用缓存异常: $e',
                tag: 'DataPack');
          }
        }
        if (outcome == _PackApplyOutcome.applied &&
            check.dataVersion != null) {
          p.status = DataPackStatus.updated;
          p.reject = DataPackReject.none;
          p.detail = '';
          p.remoteDataVersion = check.dataVersion;
          p.appliedCount = check.itemCount;
          p.lastUpdatedAt = cachedAt;
          p.hasRemoteData = true;
          p.loadedFromCache = true;
          // X11：缓存重放同样计入基线（幂等；升级首启时把旧版基线补齐）
          await writeAppliedBaseline(p.spec.id, check.dataVersion!);
        } else if (outcome == _PackApplyOutcome.pended) {
          // S1：缓存里的载荷因「改写内置厂商 baseUrl」挂起待确认 ——
          // 不应用也**不清**：缓存与基线都留着，等用户在数据包页处理。
          p.status = DataPackStatus.builtin;
          p.reject = DataPackReject.none;
          p.detail = '';
        } else {
          // 旧代码写的缓存 / 被版本或校验挡下的缓存 → 丢弃，回落内置。
          // （基线随应用推进，比基线旧的缓存留着只会挡住下次更新。）
          await p.spec.clearApplied(prefs);
          p.status = DataPackStatus.builtin;
          p.reject = check.reject;
          p.detail = check.detail;
          _logger.info(
              '${p.spec.id} 本地缓存未应用：'
              '${describeDataPackReject(check.reject, detail: check.detail)}',
              tag: 'DataPack');
        }
      }
      // S1：恢复上次挂起的「待确认」现场（重启后界面还能看到确认条）。
      await _restorePending(p, prefs);
      // build145：`retryKey` 是**粘性的**（只有成功才清）⇒ 对「仓库私有 / 长期离线」的设备，
      // 旧写法等于每次冷启动都把 3 个包 × 2 个源 × 5~6 个候选 ≈ 数十个注定失败的请求重跑一遍。
      // 真机 13:16 那份导出实证：43 秒 109 行日志里 62 行（57%）是它，还带一条 ERROR。
      // 现在加指数退避（6h 起、翻倍、封顶 7 天），**跳过时留一行 INFO**——退避不能变成新的静默。
      final now = DateTime.now();
      final retry = prefs.getBool(p.spec.retryKey) ?? false;
      final stamp = decodeDataPackRetryStamp(
          prefs.getString(_retryStampKey(p.spec.retryKey)));
      final backingOff = retry &&
          !dataPackRetryAllowed(
              lastFailureAt: stamp.at, failures: stamp.failures, now: now);
      if (backingOff) {
        final left = dataPackRetryBackoff(stamp.failures) -
            now.difference(stamp.at!);
        final mins = left.inMinutes < 1 ? 1 : left.inMinutes;
        // build161 措辞修正：streak 现在只由**暂时性**全源失败累积（401/403/404
        // 这类永久性拒绝不计数，见 classifyDataPackFailureKind），旧文案「N 次全源
        // 失败」会把私有仓库的永久失败也暗示成"在退避、等等就好"——恰恰是这次
        // 34 小时锁死看起来像正常机制的原因。
        _logger.info(
            '${p.spec.id} 已连续 ${stamp.failures} 次暂时性全源失败，退避中：'
            '约 $mins 分钟后再试（'
            '${describeDataPackReject(p.reject, detail: p.detail)}）',
            tag: 'DataPack');
        // build145（第 9 轮 P2-7）：**退避不许把失败态洗成"还没拉过"**。
        // 上面那个 INFO 只进日志，而这一页读的是 `p.status` —— 旧写法让它停在
        // `builtin`，于是"更新失败 · 内置数据 · 尚未拉取远程包"：
        // 一个连续失败 N 次、下次还要失败的东西，在界面上长得像"刚装好还没联网"。
        // 这直接违反本文件自己写的口径「退避不能变成新的静默」+「失败必须带原因」
        // （第 1 轮就是为这条加的退避）。现在保留失败事实，并把"什么时候再试"一起说清。
        // 只在**没有可用远程数据**时翻：缓存已经应用成功的（status=updated）不去动它，
        // 那种情况退避只是"下次刷新晚一点"，不是失败。
        if (!p.hasRemoteData) {
          p.status = DataPackStatus.failed;
          p.reject = DataPackReject.fetchFailed;
          p.detail = '已连续 ${stamp.failures} 次暂时性全源失败，约 $mins 分钟后自动重试';
        }
      } else if (retry ||
          isDataPackRefreshDue(p.lastUpdatedAt ?? cachedAt, now)) {
        due.add(p);
      }
    }
    if (due.isEmpty) return;
    if (deferRemoteRefresh) {
      unawaited(_refreshSome(due, prefs));
    } else {
      await _refreshSome(due, prefs);
    }
  }

  /// 退避现场挤在 retryKey 的派生键里（见 `DataPackRetryStamp` 的注释）。
  static String _retryStampKey(String retryKey) => '${retryKey}_at';

  Future<void> _refreshSome(List<_Pack> packs, SharedPreferences prefs) async {
    for (final p in packs) {
      try {
        await _refreshPack(p, prefs);
      } catch (e, st) {
        // 兜底：编排本身出异常也绝不能冒到启动链路 / 用户界面。
        _logger.error('${p.spec.id} 刷新流程异常',
            error: e, stack: st, tag: 'DataPack');
      }
    }
  }

  // ==================================================================
  // 手动刷新（设置页「检查更新」）
  // ==================================================================

  /// 逐包刷新，返回每包结果（页面据此提示「已是最新 / 更新 N 条 / 失败原因」）。
  Future<List<DataPackState>> checkAll() async {
    final prefs = await SharedPreferences.getInstance();
    final out = <DataPackState>[];
    for (final p in _packs) {
      try {
        out.add(await _refreshPack(p, prefs));
      } catch (e, st) {
        _logger.error('${p.spec.id} 检查更新异常',
            error: e, stack: st, tag: 'DataPack');
        out.add(p.snapshot());
      }
    }
    return out;
  }

  /// 单包刷新（自定义源填完立即生效用它）。未知 id 返回 null。
  Future<DataPackState?> refreshPack(String id) async {
    final p = _find(id);
    if (p == null) return null;
    final prefs = await SharedPreferences.getInstance();
    try {
      return await _refreshPack(p, prefs);
    } catch (e, st) {
      _logger.error('${p.spec.id} 刷新异常',
          error: e, stack: st, tag: 'DataPack');
      return p.snapshot();
    }
  }

  /// 用户自定义源：有序列表（主 → 备）。**立即生效**并持久化（G56）。
  /// 传空列表 = 清掉自定义、回到内置默认源。
  Future<void> setCustomSources(String id, List<String> urls,
      {bool refresh = true}) async {
    final p = _find(id);
    if (p == null) return;
    final list = parseDataPackSources(urls.join('\n'));
    p.sources = list.isEmpty ? List.of(p.spec.defaultSources) : list;
    final prefs = await SharedPreferences.getInstance();
    if (list.isEmpty) {
      await prefs.remove(p.spec.urlKey);
    } else {
      await prefs.setString(p.spec.urlKey, encodeDataPackSources(list));
    }
    _logger.info('${p.spec.id} 源已更新：${p.sources.join(' → ')}',
        tag: 'DataPack');
    notifyListeners();
    if (refresh) await refreshPack(id);
  }

  /// 生效源列表（页面展示用）。
  List<String> sourcesOf(String id) => _find(id)?.sources ?? const [];

  // ==================================================================
  // 核心编排：有序源 → 闸门 → 应用 → 落缓存
  // ==================================================================

  /// build142（灵动岛）：数据包按源逐个回退拉取（G54），源全挂时用户只能干等 ——
  /// 这一层让「正在更新资源包 / 更新失败」在应用外也看得见。
  Future<DataPackState> _refreshPack(_Pack p, SharedPreferences prefs) =>
      LiveTaskWiring.track(
        id: 'pack_${p.spec.id}',
        title: '正在更新资源包',
        kind: LiveTaskKind.dataPack,
        route: kLiveRouteDataPacks,
        okBody: '新的模板、提示词与目录已生效',
        // 启动即刷的例行更新，无变化是常态：成功不弹（否则每次开机一条），**失败照弹**。
        announceOnSuccess: false,
        body: () => _refreshPackInner(p, prefs),
      );

    Future<DataPackState> _refreshPackInner(_Pack p, SharedPreferences prefs) async {
    if (p.sources.isEmpty) {
      p.status = DataPackStatus.failed;
      p.reject = DataPackReject.noSources;
      p.detail = '';
      notifyListeners();
      return p.snapshot();
    }

    final failures = <String>[];
    var lastReject = DataPackReject.fetchFailed;
    // 每个源一条失败类别（G54 的 continue 分支逐源追加；成功即 return，不会有多余项）。
    final sourceKinds = <DataPackFailureKind>[];

    for (final url in p.sources) {
      String body;
      try {
        body = await _fetcher(url);
      } catch (e) {
        lastReject = classifyDataPackFailure(e);
        final kind = classifyDataPackFailureKind(e);
        sourceKinds.add(kind);
        failures.add('$url → $e');
        // 单源级失败也带上类别：permanent/transient 在源头就分开写，
        // 免得下游把「私有仓库 404」又读成一次网络抖动。
        _logger.warn(
            '${p.spec.id} 源失败（${kind == DataPackFailureKind.permanent ? '永久性拒绝' : '暂时性故障'}）: $e',
            tag: 'DataPack');
        continue; // 按序尝试下一个源（G54）
      }

      final check = evaluateDataPackPayload(
        rawJson: body,
        baselineVersion: await readAppliedBaseline(p.spec.id),
        appVersion: _appVersion,
        itemCountOf: p.spec.countItems,
      );
      if (!check.accepted) {
        lastReject = check.reject;
        // 拿到了内容但没过闸门 —— 与"重试不会变好"的鉴权/找不到型拒绝无关，
        // 本批不动它的退避语义：记暂时性，照旧参与计数（permanent 豁免不扩大到这儿）。
        sourceKinds.add(DataPackFailureKind.transient);
        failures.add(
            '$url → ${describeDataPackReject(check.reject, detail: check.detail)}');
        // 校验没过：绝不落缓存、绝不应用（G55 防污染）
        continue;
      }

      bool applied;
      try {
        final outcome = await _applyPackPayload(p, body, check, prefs);
        if (outcome == _PackApplyOutcome.pended) {
          // S1：载荷检出「改写内置厂商 baseUrl」，挂起等用户二次确认。
          // 这不是拉取失败：不落缓存、不计退避、也不再试下一个源
          // （换源等于换一份没人核对过的载荷，它同样要过这道闸）。
          p.status = DataPackStatus.builtin;
          p.reject = DataPackReject.none;
          p.detail = '';
          notifyListeners();
          return p.snapshot();
        }
        applied = outcome == _PackApplyOutcome.applied;
      } catch (e, st) {
        _logger.error('${p.spec.id} 应用异常',
            error: e, stack: st, tag: 'DataPack');
        applied = false;
        failures.add('$url → 应用异常: $e');
      }
      if (!applied) {
        lastReject = DataPackReject.emptyPayload;
        sourceKinds.add(DataPackFailureKind.transient);
        continue;
      }

      final now = DateTime.now();
      await prefs.setString(p.spec.urlKey, encodeDataPackSources(p.sources));
      await prefs.setString(p.spec.jsonKey, body);
      await prefs.setString(p.spec.updatedKey, now.toIso8601String());
      await prefs.setBool(p.spec.retryKey, false);
      // X11：应用成功才落「上次已应用的 dataVersion」基线——
      // 失败/拒绝绝不落（否则一次坏载荷把自己的版本钉进基线，挡住后面的正确版本）。
      if (check.dataVersion != null) {
        await writeAppliedBaseline(p.spec.id, check.dataVersion!);
      }
      // 成功一次就把退避现场清掉（否则下一次偶发失败会从很久的倍数开始算）
      await prefs.remove(_retryStampKey(p.spec.retryKey));
      await afterApplied(p.spec.id, now);

      p.status = DataPackStatus.updated;
      p.reject = DataPackReject.none;
      p.detail = '';
      p.remoteDataVersion = check.dataVersion;
      p.appliedCount = check.itemCount;
      p.lastUpdatedAt = now;
      p.hasRemoteData = true;
      p.loadedFromCache = false;
      _logger.info(
          '${p.spec.id} 已更新到 ${check.dataVersion}'
          '（${check.itemCount} 条）via $url',
          tag: 'DataPack');
      notifyListeners();
      return p.snapshot();
    }

    // 全部源都没成：保留内置与旧缓存（只置 retry 标记，下次启动重试）。
    await prefs.setBool(p.spec.retryKey, true);
    // 记退避现场：时间 + 连续失败次数（第 N 次失败后等 6h * 2^(N-1)，封顶 7 天）。
    // build161 口径：**计数只吃 dataPackRoundCountsTowardBackoff 的结论** ——
    // 纯永久性拒绝（401/403/404，私有仓库是有意为之）的那一轮不写时间戳、
    // 不动已有 streak；含任何暂时性失败的那一轮按 build145 原样 +1。
    // （旧写法把两类混计，真机连续 4 轮 404/403 就退避 ~34 小时：永久态被
    // 当成"再等等"，更新被事实上锁死一天多，而那 4 次失败重试永远不会变好。）
    final countsForBackoff = dataPackRoundCountsTowardBackoff(sourceKinds);
    var streak = 0;
    {
      final prev = decodeDataPackRetryStamp(
          prefs.getString(_retryStampKey(p.spec.retryKey)));
      streak = prev.failures;
      if (countsForBackoff) {
        streak = prev.failures + 1;
        await prefs.setString(
            _retryStampKey(p.spec.retryKey),
            encodeDataPackRetryStamp(DateTime.now(), streak));
      }
    }
    p.status = DataPackStatus.failed;
    p.reject = lastReject;
    p.detail = _clampDetail(failures.join(' | '));
    // 两类失败在**同一条汇总**里分开写：不许让人把永久拒绝误读成"在退避"，
    // 也不许让暂时性故障丢掉"第几次、还要等多久"的账（汇总行是 build145
    // 降噪后唯一保留的失败明细，锚点测试盯着「全部 N 个源失败」这个前缀）。
    if (countsForBackoff) {
      _logger.warn('${p.spec.id} 全部 ${p.sources.length} 个源失败'
          '（含暂时性故障 ⇒ 连续第 $streak 次计入退避，'
          '约 ${dataPackRetryBackoff(streak).inMinutes} 分钟后才再试）：'
          '${p.detail}',
          tag: 'DataPack');
    } else {
      _logger.warn('${p.spec.id} 全部 ${p.sources.length} 个源失败'
          '（均为永久性拒绝 401/403/404：私有仓库/无权限/资源不存在，'
          '重试不会变好 ⇒ 不计入连续失败、不退避，只记这一行原因）：'
          '${p.detail}',
          tag: 'DataPack');
    }

    // build131 语义保留：抖动期照旧用旧缓存；只有「旧缓存已陈旧到不可信」
    // 又刷不上新时，才丢弃它回落内置（否则旧覆盖会永久压住新版内置）。
    if (p.loadedFromCache) {
      final updated = DateTime.tryParse(prefs.getString(p.spec.updatedKey) ?? '');
      if (isDataPackCacheStale(updated, DateTime.now())) {
        await p.spec.clearApplied(prefs);
        p.hasRemoteData = false;
        p.loadedFromCache = false;
        p.remoteDataVersion = null;
        p.appliedCount = 0;
        p.lastUpdatedAt = null;
        p.detail = '${p.detail} | 本地缓存已过期，回落内置默认';
        _logger.warn('${p.spec.id} 缓存陈旧，已回落内置', tag: 'DataPack');
      }
    }
    notifyListeners();
    return p.snapshot();
  }

  /// 应用成功后的钩子：把「生效时间」同步回各 catalog 的展示字段。
  Future<void> afterApplied(String id, DateTime at) async {
    switch (id) {
      case packApiTemplates:
        ApiProviderTemplateCatalog.instance.lastUpdatedAt = at;
        break;
      case packBuiltinPrompts:
        BuiltinPromptCatalog.instance.lastUpdatedAt = at;
        break;
      default:
        break;
    }
  }

  // ==================================================================
  // S1（build172）：apiTemplates 包「改写内置厂商 baseUrl」的二次确认闸
  // ==================================================================

  /// 某包当前挂起的「待二次确认」载荷（只有 apiTemplates 包会出现）。
  /// UI（数据包更新页）从这里读警示条内容；null = 没有待确认载荷。
  DataPackPendingConfirmation? pendingOf(String id) {
    final p = _find(id);
    if (p == null || p.pendingRaw == null) return null;
    return DataPackPendingConfirmation(
      packId: p.spec.id,
      rawJson: p.pendingRaw!,
      dataVersion: p.pendingDataVersion ?? '',
      itemCount: p.pendingItemCount,
      overrides: p.pendingOverrides,
    );
  }

  /// 用户点「确认应用」：复核闸门 → 真正应用 → 落缓存/基线/确认指纹 → 清 pending。
  /// 复核不过（挂起期间基线被推进等）⇒ 作废 pending 并如实记日志。
  Future<DataPackState?> confirmPending(String id) async {
    final p = _find(id);
    if (p == null) return null;
    final prefs = await SharedPreferences.getInstance();
    final raw =
        p.pendingRaw ?? prefs.getString(DataPackPrefKeys.apiTemplatePendingRaw) ?? '';
    if (raw.isEmpty) return p.snapshot();
    // 确认前再过一次完整闸门：挂起期间基线可能已被别的路径推进，
    // 绝不借「用户点了确认」绕过版本/校验闸。
    final check = evaluateDataPackPayload(
      rawJson: raw,
      baselineVersion: await readAppliedBaseline(p.spec.id),
      appVersion: _appVersion,
      itemCountOf: p.spec.countItems,
    );
    if (!check.accepted) {
      await _clearPending(p, prefs);
      _logger.warn(
          '${p.spec.id} 待确认载荷复核未过闸'
          '（${describeDataPackReject(check.reject, detail: check.detail)}），已作废',
          tag: 'DataPack');
      notifyListeners();
      return p.snapshot();
    }
    bool applied = false;
    try {
      applied = await p.spec.applyPayload(raw);
    } catch (e, st) {
      _logger.error('${p.spec.id} 确认后应用异常',
          error: e, stack: st, tag: 'DataPack');
    }
    if (!applied) {
      _logger.warn('${p.spec.id} 待确认载荷应用失败，保留挂起状态', tag: 'DataPack');
      return p.snapshot();
    }
    final now = DateTime.now();
    await prefs.setString(p.spec.jsonKey, raw);
    await prefs.setString(p.spec.updatedKey, now.toIso8601String());
    await prefs.setBool(p.spec.retryKey, false);
    await prefs.remove(_retryStampKey(p.spec.retryKey));
    // S1：把「用户确认过的字节」记成指纹——此后同内容重放不再进确认闸，
    // 远程同版本换内容（指纹对不上）仍会照常检出。
    await prefs.setString(
        DataPackPrefKeys.apiTemplateConfirmedSha, sha256HexOf(raw));
    if (check.dataVersion != null) {
      await writeAppliedBaseline(p.spec.id, check.dataVersion!);
    }
    await _clearPending(p, prefs);
    await afterApplied(p.spec.id, now);
    p.status = DataPackStatus.updated;
    p.reject = DataPackReject.none;
    p.detail = '';
    p.remoteDataVersion = check.dataVersion;
    p.appliedCount = check.itemCount;
    p.lastUpdatedAt = now;
    p.hasRemoteData = true;
    p.loadedFromCache = false;
    _logger.info(
        '${p.spec.id} 用户确认后应用 ${check.dataVersion}（${check.itemCount} 条）',
        tag: 'DataPack');
    notifyListeners();
    return p.snapshot();
  }

  /// 用户点「放弃」：只清 pending，**基线不动**。
  /// 有意为之：下次拉到同一份载荷仍会再进 pending，直到用户处理。
  Future<DataPackState?> discardPending(String id) async {
    final p = _find(id);
    if (p == null) return null;
    final prefs = await SharedPreferences.getInstance();
    await _clearPending(p, prefs);
    _logger.info('${p.spec.id} 已放弃待确认载荷（基线保留，下次拉取仍会再挂起）',
        tag: 'DataPack');
    notifyListeners();
    return p.snapshot();
  }

  /// 统一的应用入口：两条应用路径（启动缓存重放 / 远程刷新）都走这里。
  /// apiTemplates 包在应用前先跑 [detectBaseUrlOverrides]：检出改写 ⇒
  /// 不应用、挂 pending、返回 [ _PackApplyOutcome.pended]；
  /// 用户在数据包页确认后经 [confirmPending] 真正应用。
  Future<_PackApplyOutcome> _applyPackPayload(
    _Pack p,
    String rawJson,
    DataPackCheckResult check,
    SharedPreferences prefs,
  ) async {
    if (p.spec.id == packApiTemplates &&
        !_isConfirmedTemplateBody(rawJson, prefs)) {
      final overrides = _detectTemplateOverrides(rawJson);
      if (overrides.isNotEmpty) {
        await _storePending(p, rawJson, check, overrides, prefs);
        _logger.warn(
            '${p.spec.id} 检出 ${overrides.length} 处内置厂商 baseUrl 改写'
            '（${overrides.map((o) => o.id).join('、')}），'
            '已挂起待用户确认，本轮不应用',
            tag: 'DataPack');
        return _PackApplyOutcome.pended;
      }
    }
    final ok = await p.spec.applyPayload(rawJson);
    return ok ? _PackApplyOutcome.applied : _PackApplyOutcome.failed;
  }

  /// 这份载荷是否就是用户**已确认过**的那一份（S1 幂等重放）：
  /// 确认时把 body 的 sha256 记进 prefs；命中 ⇒ 缓存重放/再拉取不再进确认闸
  /// （否则用户确认一次、之后每次启动又被挂起一次）。
  /// 远程同版本换内容（指纹对不上）⇒ 照常检出——确认只对确认过的字节生效。
  bool _isConfirmedTemplateBody(String rawJson, SharedPreferences prefs) =>
      prefs.getString(DataPackPrefKeys.apiTemplateConfirmedSha) ==
      sha256HexOf(rawJson);

  /// 解码载荷并检出「远程改写内置厂商 baseUrl」的条目。
  /// 解码失败按「无改写」处理——坏载荷会在随后的 applyPayload 里如实失败。
  List<TemplateBaseUrlOverride> _detectTemplateOverrides(String rawJson) {
    try {
      final templates =
          ApiProviderTemplateCatalog.instance.parseTemplatesJson(rawJson);
      return ApiProviderTemplateCatalog.detectBaseUrlOverrides(
        ApiProviderTemplateCatalog.builtinTemplates,
        templates,
      );
    } catch (_) {
      return const [];
    }
  }

  Future<void> _storePending(
    _Pack p,
    String rawJson,
    DataPackCheckResult check,
    List<TemplateBaseUrlOverride> overrides,
    SharedPreferences prefs,
  ) async {
    p.pendingRaw = rawJson;
    p.pendingDataVersion = check.dataVersion;
    p.pendingItemCount = check.itemCount;
    p.pendingOverrides = List.unmodifiable(overrides);
    await prefs.setString(DataPackPrefKeys.apiTemplatePendingRaw, rawJson);
  }

  /// 启动时从 prefs 恢复挂起现场；内置清单随 App 升级变化后，旧挂起可能
  /// 不再构成改写 ⇒ 自动失效（重跑检出，检不出就清）。
  Future<void> _restorePending(_Pack p, SharedPreferences prefs) async {
    if (p.spec.id != packApiTemplates) return;
    final raw = prefs.getString(DataPackPrefKeys.apiTemplatePendingRaw);
    if (raw == null || raw.isEmpty) return;
    final overrides = _detectTemplateOverrides(raw);
    if (overrides.isEmpty) {
      await _clearPending(p, prefs);
      return;
    }
    final check = evaluateDataPackPayload(
      rawJson: raw,
      baselineVersion: await readAppliedBaseline(p.spec.id),
      appVersion: _appVersion,
      itemCountOf: p.spec.countItems,
    );
    p.pendingRaw = raw;
    p.pendingDataVersion = check.dataVersion;
    p.pendingItemCount = check.itemCount;
    p.pendingOverrides = List.unmodifiable(overrides);
  }

  Future<void> _clearPending(_Pack p, SharedPreferences prefs) async {
    p.pendingRaw = null;
    p.pendingDataVersion = null;
    p.pendingItemCount = 0;
    p.pendingOverrides = const [];
    await prefs.remove(DataPackPrefKeys.apiTemplatePendingRaw);
  }

  static String _clampDetail(String s) =>
      s.length <= 600 ? s : '${s.substring(0, 600)}…';

  // ==================================================================
  // 包注册表（新增数据包只在这里加一条）
  // ==================================================================

  static List<DataPackSpec> _allSpecs({required String appVersion}) {
    // build171：两个源前缀与"镜像优先、raw 兜底"的顺序都住在 `repo_endpoints.dart`。
    // 以前这两行是写死的**私有仓库**地址 ⇒ 对所有人永远 404/403（G54–G56 的立项事实），
    // 这个服务从上线起就没真取到过远端数据包；迁到公开的 Nexus 之后才第一次取得到。
    //
    // X11（build172）：不再有「内置数据版本 = App 版本」这个闸门基准——基准改为
    // 每包持久化的「上次已应用的 dataVersion」（data_pack_baseline.dart）。
    // 旧基准下载荷停在 1.7.32/1.7.37、App 已到 1.7.114 ⇒ 每个用户恒判旧、热更从未生效。
    // [appVersion] 仍要传：只喂 minAppVersion 闸。
    List<String> sourcesOf(String file) => repoFileSources(file);

    return [
      DataPackSpec(
        id: packApiTemplates,
        nameZh: '服务商模板',
        nameEn: 'Provider templates',
        descriptionZh: 'API 配置页的厂商与模型清单（内置为底、只增不删）',
        descriptionEn: 'Provider/model catalog (built-in as base)',
        urlKey: DataPackPrefKeys.apiTemplateUrl,
        jsonKey: DataPackPrefKeys.apiTemplateJson,
        updatedKey: DataPackPrefKeys.apiTemplateUpdatedAt,
        retryKey: DataPackPrefKeys.apiTemplateRetryPending,
        defaultSources: sourcesOf('api_templates.json'),
        applyPayload: (raw) async =>
            ApiProviderTemplateCatalog.instance.applyJson(raw),
        clearApplied: (prefs) async {
          ApiProviderTemplateCatalog.instance.clearRemotePayload();
          // X11：用户放弃/清除远程载荷 ⇒ 基线一并清，下次拉取视为首用。
          await clearAppliedBaseline(packApiTemplates);
          await prefs.remove(DataPackPrefKeys.apiTemplateJson);
          // S25（build173）：确认指纹必须跟着一起清，否则这次清除是「清不干净」的。
          // 链条逐字是这样的：基线清了 ⇒ 下次拉同一份载荷按首次过版本闸；
          // 但指纹还在 ⇒ _applyPackPayload 里 _isConfirmedTemplateBody 命中旧指纹
          // ⇒ 跳过 baseUrl 改写确认闸、**静默应用同一份恶意字节**——
          // 而用户刚刚才放弃过它。方向是「永久静默放行」，不是永久拒绝。
          await prefs.remove(DataPackPrefKeys.apiTemplateConfirmedSha);
        },
        countItems: countTemplateItems,
      ),
      DataPackSpec(
        id: packBuiltinPrompts,
        nameZh: '内置提示词 / 插件协议',
        nameEn: 'Built-in prompts & plugin protocols',
        descriptionZh: 'ReAct 插件协议、格式骨架与触发词的远程覆盖',
        descriptionEn: 'ReAct protocols, format skeletons and trigger words',
        urlKey: DataPackPrefKeys.promptsUrl,
        jsonKey: DataPackPrefKeys.promptsJson,
        updatedKey: DataPackPrefKeys.promptsUpdatedAt,
        retryKey: DataPackPrefKeys.promptsRetryPending,
        defaultSources: sourcesOf('builtin_prompts.json'),
        applyPayload: (raw) async => BuiltinPromptCatalog.instance.applyJson(raw),
        clearApplied: (prefs) async {
          await BuiltinPromptCatalog.instance.discardRemoteCache(prefs);
          // X11：同上——清载荷必须连基线一起清。
          await clearAppliedBaseline(packBuiltinPrompts);
        },
        countItems: countPromptItems,
      ),
      DataPackSpec(
        id: packMcpCatalog,
        nameZh: 'MCP 连接器目录',
        nameEn: 'MCP connector catalog',
        descriptionZh: '插件市场「推荐连接器」列表（远程按 id 覆盖内置，安装仍需确认）',
        descriptionEn: 'Recommended MCP connectors',
        urlKey: DataPackPrefKeys.mcpUrl,
        jsonKey: DataPackPrefKeys.mcpJson,
        updatedKey: DataPackPrefKeys.mcpUpdatedAt,
        retryKey: DataPackPrefKeys.mcpRetryPending,
        defaultSources: sourcesOf('mcp_catalog.json'),
        applyPayload: (raw) async => McpCatalog.applyRemotePayload(raw),
        clearApplied: (prefs) async {
          await McpCatalog.clearRemotePayload(prefs);
          // X11：同上——清载荷必须连基线一起清。
          await clearAppliedBaseline(packMcpCatalog);
        },
        countItems: countMcpItems,
      ),
    ];
  }
}

// ==================================================================
// 各包的「有效条目数」判定（纯函数，与 catalog 解码口径一致）
// ==================================================================

int countTemplateItems(Object? decoded) {
  final list = decoded is List
      ? decoded
      : (decoded is Map ? (decoded['templates'] as List? ?? const []) : const []);
  return list
      .whereType<Map>()
      .where((m) => (m['id']?.toString().trim() ?? '').isNotEmpty)
      .length;
}

int countPromptItems(Object? decoded) {
  if (decoded is! Map) return 0;
  var n = 0;
  final plugins = decoded['plugins'];
  if (plugins is List) {
    n += plugins.whereType<Map>().where((p) {
      final id = p['id']?.toString().trim() ?? '';
      final pp = p['promptProtocol']?.toString().trim() ?? '';
      return id.isNotEmpty && pp.isNotEmpty;
    }).length;
  }
  final prompts = decoded['prompts'];
  if (prompts is Map) {
    n += prompts.entries.where((e) => (e.value?.toString().trim() ?? '').isNotEmpty).length;
  }
  final formats = decoded['formats'];
  if (formats is Map) {
    n += formats.entries.where((e) => (e.value?.toString().trim() ?? '').isNotEmpty).length;
  }
  final words = decoded['triggerWords'];
  if (words is Map) {
    n += words.entries.where((e) => e.value is List && (e.value as List).isNotEmpty).length;
  }
  return n;
}

int countMcpItems(Object? decoded) => McpCatalog.countEntries(decoded);
