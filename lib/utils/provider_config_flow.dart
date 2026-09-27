import '../models/api_account.dart';
import '../models/api_config.dart';
import '../models/api_provider_template.dart';

/// build138 · B 批（交接单 §7.2 之 B ＝任务书 G47/G48）：
/// 「从大到小」结构反转里**与 UI 无关的那半逻辑**。
///
/// 为什么单独成文件（而不是写在页面里）：这几条判断是整批里唯一会
/// **改到用户存量数据**的地方（复用哪个 Key、叫什么名、算不算已配置）。
/// 写在 State 类里就只能靠手点验证；提出来之后它们是纯函数，
/// 直接被 `test/build138_provider_flow_test.dart` 钉住。
///
/// 铁律背景：本项目反复栽在「能力看起来接好了但没有调用点」——
/// 所以这里的每个函数都必须在 `provider_models_screen.dart` /
/// `api_config_screen.dart` 里被真实调用，测试里也断言了这一点。

/// 该厂商（模板）下用户**已有**的配置。
List<ApiConfig> configsForTemplate(
  List<ApiConfig> all,
  ApiProviderTemplate template,
) =>
    all.where((c) => c.templateId == template.id).toList(growable: false);

/// 该厂商（模板）下用户已建的**账号**（build138 · G45）。
///
/// 返回 List 而不是「一个」：同一厂商合法地可能有多个账号 ——
/// 自建代理与官方域名两个 host、或同 host 的两把 Key（见 [AccountGrouping]）。
/// 「怎么算同一个账号」的判据只写在 AccountGrouping 一处，这里不另算一遍。
List<ApiAccount> accountsForTemplate(
  List<ApiAccount> all,
  ApiProviderTemplate template,
) =>
    all.where((a) => a.templateId == template.id).toList(growable: false);

/// 新建模型条目时**挂到哪个账号**（G45「一把 Key 多模型」的选路）。
///
/// ① 先挑有 Key 的账号：用户加第二个模型十有八九还是用同一个 Key，
///    挑空 Key 的账号会让他在编辑页再抄一遍（正是本批要消掉的动作）；
/// ② 全是空 Key（本地 Ollama / LM Studio）时取第一个，至少地址能带过去；
/// ③ 一个都没有 → null，让 `saveApiConfig` 的懒绑定去建，
///    不要在 UI 层重复实现一遍建账号的逻辑。
ApiAccount? donorAccountFor(
  List<ApiAccount> accounts,
  ApiProviderTemplate template,
) {
  final same = accountsForTemplate(accounts, template);
  for (final a in same) {
    if (a.apiKey.trim().isNotEmpty) return a;
  }
  return same.firstOrNull;
}

/// 这个模型名是否已被该厂商的某条配置使用（二级页上要打「使用中」标记）。
bool isModelInUse(List<ApiConfig> sameTemplate, String modelId) =>
    sameTemplate.any((c) => c.model.trim() == modelId.trim());

/// 该厂商是否已经「配置过」（一级页徽标的唯一判据）。
///
/// 判据刻意只看**有没有 Key**：本地厂商（Ollama / LM Studio）本来不需要 Key，
/// 建过配置就算配置好；其余厂商「填了地址没填 Key」不能报成「已配置」，
/// 否则一级页会在用户下次点击时说谎（这正是本项目的老毛病）。
bool templateIsConfigured(
  List<ApiConfig> sameTemplate,
  ApiProviderTemplate template,
) {
  if (sameTemplate.isEmpty) return false;
  if (template.group == ApiProviderGroup.local) return true;
  return sameTemplate.any((c) => c.apiKey.trim().isNotEmpty);
}

/// 给新配置起一个**在同厂商内不重复**的名字。
///
/// 为什么在建草稿阶段就要做：名字是用户在 ModelSwitcher 里唯一看得见的标识，
/// 出现两条同名「DeepSeek」会让人以为其中一个是坏的（真机上用户确实因此重复建配置）。
String dedupedConfigName(
  ApiProviderTemplate template,
  List<ApiConfig> sameTemplate,
) {
  final base = template.defaultConfigName.trim().isEmpty
      ? (template.nameEn.trim().isEmpty ? template.id : template.nameEn)
      : template.defaultConfigName.trim();
  bool taken(String n) => sameTemplate.any((c) => c.name == n);
  if (!taken(base)) return base;
  var n = 2;
  while (taken('$base $n')) {
    n++;
  }
  return '$base $n';
}

/// 点二级页里某个模型后，**送去编辑页的草稿配置**。
///
/// 三条关键设计（都会被测试钉住）：
/// ① **不入库**：调用方把它当 `config:` 传给 `ApiConfigEditScreen`（编辑页内部
///    是 `widget.config ?? ApiConfig.create()` + `saveApiConfig` 幂等 upsert），
///    用户不点保存就什么都不留下 —— 避免出现「填了个没 Key 的假配置」
///    被 ModelSwitcher 选中然后 401；
/// ② **复用同厂商已有连接的 Key 与地址**：同厂商多模型是常态
///    （一个 DeepSeek Key 既能打 V4-Flash 也能打 V4-Pro），
///    否则用户每加一个模型都要重抄一遍 Key；
/// ③ 已有连接的地址非空时**优先沿用已有**而不是模板地址 ——
///    用户可能填的是自建中转/代理，模板地址不能覆盖他的选择。
///
/// build138（G45）新增第 ④ 条：传 [accounts] 时草稿**直接带上账号 id**，
/// 新条目从第一条起就在账号名下 —— Key/地址/cachedModels 之后都在账号那一处改。
/// 不传（老调用点）时行为与 B 批一致：从已有配置里挑 donor，
/// accountId 留空，由 `StorageService.saveApiConfig` 的懒绑定补上。
ApiConfig draftConfigForModel({
  required ApiProviderTemplate template,
  required String modelId,
  required List<ApiConfig> all,
  List<ApiAccount> accounts = const [],
}) {
  final same = configsForTemplate(all, template);
  final donor = donorAccountFor(accounts, template);
  ApiConfig? donorCfg;
  if (donor == null) {
    for (final c in same) {
      if (c.apiKey.trim().isNotEmpty) {
        donorCfg = c;
        break;
      }
    }
  }
  final donorUrl = donor?.baseUrl.trim() ?? donorCfg?.baseUrl.trim() ?? '';
  final baseUrl = donorUrl.isNotEmpty ? donorUrl : template.baseUrl;
  final cfg = ApiConfig.create(
    name: dedupedConfigName(template, same),
    baseUrl: baseUrl,
    apiKey: donor?.apiKey ?? donorCfg?.apiKey ?? '',
    model: modelId,
  );
  // templateId 不在 ApiConfig.create() 的参数里（历史签名），必须显式补上：
  // 漏了这一行，二级页的「使用中」标记与一级页的徽标双双失效
  // （新配置会被算成 templateId='custom'，从此跟该厂商脱钩）。
  cfg.templateId = template.id;
  final boundAccount = donor == null ? '' : donor.id;
  if (boundAccount.isNotEmpty) cfg.accountId = boundAccount;
  return cfg;
}

/// 一组「同一服务商的连接」（B 批 / 任务书 G48：ModelSwitcher 从「一条平铺列表」
/// 变成「服务商 → 该服务商的模型」两级）。
class ProviderGroup {
  const ProviderGroup({
    required this.templateId,
    required this.label,
    required this.configs,
    this.accounts = const [],
  });

  final String templateId;
  final String label;
  final List<ApiConfig> configs;

  /// G48 的账号维度：`configs` 按账号再切的分片（顺序与 [configs] 一致，
  /// 且 `accounts.expand((a) => a.configs)` 恰好等于 `configs` —— 有测试钉住）。
  /// 只有一个分片时 UI 不必渲染小标题（否则每层都顶一行说明，比平铺还难读）。
  final List<AccountSlice> accounts;
}

/// 按服务商分组，**保持用户配置的原有顺序**（第一次出现的 templateId 决定组序），
/// 但把 `custom`（手填地址/中转站）永远排到最后。
///
/// 为什么组序要稳：ModelSwitcher 里如果每次打开组序都变，用户按位置记忆
/// （「第三个是我公司那个中转」）会失效。
/// [labelFor] 由调用方给（页面要按当前语言取名），本函数不碰 UI —— 这样它可单测。
/// [accountLabelFor] 同理，用于组内的账号小标题（G48）；不给时退化成
/// 「切片里第一条的条目名」——够用，但真机上传递的应该是 `api_accounts.name`。
List<ProviderGroup> groupByProvider(
  List<ApiConfig> configs, {
  required String Function(String templateId) labelFor,
  String Function(ApiConfig member, int memberCount)? accountLabelFor,
}) {
  final order = <String>[];
  final buckets = <String, List<ApiConfig>>{};
  for (final c in configs) {
    final id = c.templateId.isEmpty ? ApiProviderTemplate.customId : c.templateId;
    if (!buckets.containsKey(id)) {
      order.add(id);
      buckets[id] = <ApiConfig>[];
    }
    buckets[id]!.add(c);
  }
  // custom 永远垫底（它不是服务商，是「其它」）
  order.removeWhere((id) => id == ApiProviderTemplate.customId);
  if (buckets.containsKey(ApiProviderTemplate.customId)) {
    order.add(ApiProviderTemplate.customId);
  }
  final accountLabel =
      accountLabelFor ?? (member, count) => member.name.trim();
  return [
    for (final id in order)
      ProviderGroup(
        templateId: id,
        label: labelFor(id),
        configs: buckets[id]!,
        accounts: splitByAccount(buckets[id]!, labelOf: accountLabel),
      ),
  ];
}

/// 一个「账号切片」：同一服务商组内、属于**同一个账号**的那些模型条目。
///
/// [accountKey] 是稳定身份（不是显示名）：优先 `api_accounts.id`，
/// 没有绑定时退化成「连接桶 + 字面 Key」，见 [accountKeyOf] 的说明。
class AccountSlice {
  const AccountSlice({
    required this.accountKey,
    required this.label,
    required this.configs,
  });

  final String accountKey;
  final String label;
  final List<ApiConfig> configs;
}

/// 条目的账号身份键（G48 账号维度）。
///
/// 优先用 [ApiConfig.accountId]（v39 起正常数据都有）。**没绑定**时必须退化到
/// 「连接桶 + Key 字面值」而不是只看连接桶 —— 同 host 的两把不同 Key 属于两个
/// 账号（G44 的安全红线），合并成一个切片就等于把 A 号的 Key 显示成 B 号的模型，
/// 用户点一下，请求带着另一把 Key 发出去了。空 Key 不参与这个判断：它表示
/// 「还没填」，与同桶里有 Key 的那一组同属一个账号（与 [AccountGrouping.plan] 同口径）。
String accountKeyOf(ApiConfig c) {
  final id = c.accountId.trim();
  if (id.isNotEmpty) return 'acct:$id';
  final bucket =
      AccountGrouping.bucketOf(templateId: c.templateId, baseUrl: c.baseUrl);
  // Key 段**参与键值**：同 host 的两把不同 Key 是两个账号（G44 安全红线），
  // 合成一个切片等于把 A 号的 Key 当成 B 号用。空 Key 用空段占位，
  // 在下面 [splitByAccount] 里并进同桶第一个有 Key 的切片 ——
  // 「空」不是「另一把 Key」，是「还没填」，与 AccountGrouping.plan 同口径。
  return 'bucket:$bucket|key:${c.apiKey.trim()}';
}

/// 组内按账号再切一刀，**保持条目原有顺序**；只有一个切片时调用方可以不渲染小标题。
///
/// [labelOf] 由调用方给（页面要按当前语言取名，且账号名来自 `api_accounts`），
/// 本函数不碰 UI —— 这样它能单测。第二个参数是切片内的条目数，给「共 N 个模型」用。
List<AccountSlice> splitByAccount(
  List<ApiConfig> configs, {
  required String Function(ApiConfig member, int memberCount) labelOf,
}) {
  final order = <String>[];
  final buckets = <String, List<ApiConfig>>{};
  for (final c in configs) {
    final k = accountKeyOf(c);
    if (!buckets.containsKey(k)) {
      order.add(k);
      buckets[k] = <ApiConfig>[];
    }
    buckets[k]!.add(c);
  }
  // 把「空 Key」切片并进同桶第一个有 Key 的切片（没有有 Key 的就自己 standalone）。
  for (final empty in order.where((k) => k.endsWith('|key:')).toList()) {
    final prefix = empty.substring(0, empty.length - '|key:'.length);
    String donor = '';
    for (final k in order) {
      if (k != empty && k.startsWith('$prefix|key:') && !k.endsWith('|key:')) {
        donor = k;
        break;
      }
    }
    if (donor.isEmpty) continue;
    buckets[donor]!.addAll(buckets[empty]!);
    buckets.remove(empty);
    order.remove(empty);
  }
  return [
    for (final k in order)
      AccountSlice(
        accountKey: k,
        label: labelOf(buckets[k]!.first, buckets[k]!.length),
        configs: buckets[k]!,
      ),
  ];
}
