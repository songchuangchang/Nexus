import 'package:flutter/material.dart';
import '../models/api_account.dart';
import '../models/api_config.dart';
import '../models/api_provider_template.dart';
import '../screens/api_config_screen.dart';
import '../screens/api_config_edit_screen.dart';
import '../ui/tokens.dart';
import '../utils/model_name_cleaner.dart';
import '../utils/provider_config_flow.dart';
import 'vendor_avatar.dart';

/// 模型切换器（v1.7.18 需求5）
///
/// 取代旧 DropdownButton + ConstrainedBox(maxWidth:100) 截断长名的方案。
/// - 收起态：横长方形按钮 `🤖 {清洗名} ▾`，`MainAxisSize.min` + `Flexible`
///   + `TextOverflow.ellipsis`，超屏才省略并包 `Tooltip(原始名)`。
/// - 展开态：`PopupMenuButton<Object>` 竖列表，每项「清洗名主 + 原始名副」，
///   每项右侧可见编辑小图标；**首项「➕ 添加模型」value=非空哨兵 [_kAddModel]**
///   （v1.7.42 从末项挪到顶部：末项紧贴输入框上沿，tap 偏下会落到弹窗外）。
///
/// 决策 Q3/Q4 已锁：清洗走 [ModelNameCleaner.cleanModelName]；选「➕添加模型」
/// 由本组件内部 `Navigator.push(rootNavigator, ApiConfigScreen)`，**不**经 onModelChanged
///（后者只承载真模型选中）。
///
/// ⚠️ build102 修复（build34 起反馈的「添加模型跳转不了」真根因）：该项的
/// value 不能用 null —— Flutter 的 PopupMenuButton 在 showMenu 返回 null（含
/// 点弹窗外关闭）时走 `onCanceled` 并直接 return（popup_menu.dart:1722），
/// `onSelected` **永远收不到 null**，null 哨兵项等于死入口。故改用非空哨兵。
/// （build103：注释改写措辞——源码契约测试对本文件有 not-contains 强断言，
/// 文档里不得再出现该字面量；教训 #50 的变体：契约断言连注释也要避让。）
class ModelSwitcher extends StatelessWidget {
  final List<ApiConfig> availableConfigs;
  final ApiConfig? currentConfig;
  final ValueChanged<ApiConfig>? onModelChanged;
  final bool isZh;

  /// build138（G48）：条目所属账号（`api_accounts` 的行）。
  /// 只用来给「同一服务商下不止一个账号」的组渲染小标题；不传（空列表）时
  /// 标题退化成连接 host，分组判据本身不变（见 [splitByAccount]）。
  final List<ApiAccount> accounts;

  /// 「➕ 添加模型」菜单项的非空哨兵（不能用 null，见类注释）。
  static const Object _kAddModel = Object();

  const ModelSwitcher({
    super.key,
    required this.availableConfigs,
    required this.currentConfig,
    required this.onModelChanged,
    required this.isZh,
    this.accounts = const <ApiAccount>[],
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // 无任何配置 → 灰色禁用态 chip，点击直接进设置
    if (availableConfigs.isEmpty) return _buildEmptyChip(context, cs);
    return _buildPopupMenu(context, cs);
  }

  /// 无配置时的灰色提示 chip（点击进设置添加模型）
  ///
  /// build138（#2/Q3）：底色/描边改用 tokens（`appBubble` + `appBorder`），圆角
  /// 10 → `AppRadius.panel`(8)。原来这里是不透明度和圆角都各写一套，与功能行里
  /// ActionButton 的圆角 8 不一致 ⇒ 同一排三种形状语言。
  Widget _buildEmptyChip(BuildContext context, ColorScheme cs) {
    return GestureDetector(
      onTap: () => _openSettings(context),
      behavior: HitTestBehavior.opaque,
      child: Container(
        margin: const EdgeInsets.only(right: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: cs.appBubble,
          borderRadius: BorderRadius.circular(AppRadius.panel),
          border: Border.all(color: cs.appBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const VendorAvatar(templateId: 'custom', size: 14),
            const SizedBox(width: 4),
            Text(
              isZh ? '未配置' : 'N/A',
              style: TextStyle(
                fontSize: 11,
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 有配置时的 PopupMenuButton 收起态
  Widget _buildPopupMenu(BuildContext context, ColorScheme cs) {
    final cfg = currentConfig;
    final cleanName = cfg != null
        ? ModelNameCleaner.cleanModelName(cfg.model)
        : (isZh ? '未选模型' : 'No model');
    final hasValidCurrent =
        cfg != null && availableConfigs.any((c) => c.id == cfg.id);

    return Container(
      margin: const EdgeInsets.only(right: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        // build138（#2/Q3）：primary@0.10 底 + primary@0.35 描边 + 圆角 10
        // 是输入区唯一一处「彩色容器 chip」，与朴素风「容器一律中性」冲突，
        // 也和右侧 ActionButton 的圆角 8 对不齐。改为 appBubble/appBorder +
        // AppRadius.panel；方案 B 下输入区唯一彩色只剩「发送」一处。
        color: cs.appBubble,
        borderRadius: BorderRadius.circular(AppRadius.panel),
        border: Border.all(color: cs.appBorder),
      ),
      child: Semantics(
        // build183（#36）：读屏标签补角色前缀。原来这枚筹码只把裸模型名送进语义树，
        // 听不出「这是干什么的控件」，自动化也只能按形状猜锚（#35 那条脆弱锚的根因）。
        // 可见文字一个字没动，label 是**加**在父节点上，子节点仍在树里。
        button: true,
        label: isZh ? '切换模型：$cleanName' : 'Switch model: $cleanName',
        child: PopupMenuButton<Object>(
          tooltip: isZh ? '切换模型' : 'Switch model',
        onSelected: (v) => _onSelected(v, context),
        itemBuilder: (ctx) => _buildItems(ctx, cs),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            VendorAvatar(templateId: cfg?.templateId ?? 'custom', size: 14),
            const SizedBox(width: 4),
            Flexible(
              child: Tooltip(
                message: cfg?.model ?? '',
                child: Text(
                  cleanName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: hasValidCurrent ? cs.onSurface : cs.appTextSub,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            Icon(
              Icons.arrow_drop_down,
              size: 16,
              color: cs.appTextSub,
            ),
          ],
        ),
        ),
      ),
    );
  }

  /// 构建弹出列表：➕添加模型（顶部，非空哨兵值）+ 分隔 + 每个配置（清洗名主+原始名副）
  /// v1.7.36：长按模型项 → 直接打开该模型的编辑页
  /// v1.7.42 修复（build98 实测反馈）：➕ 原在弹窗末尾、紧贴输入框上沿，
  /// tap 偏下会落到弹窗外 →「按了没反应 + 点到聊天框」；挪到顶部一并解决。
  /// 编辑入口从隐藏的长按升级为每项右侧可见小图标（内层 GestureDetector
  /// 在手势竞技场中优先于 item 的 InkWell → 点图标只编辑、不切换模型）。
  /// build101 (EP3)：文案「➕ 编辑模型」→「➕ 添加模型」。
  /// 原文案有歧义（像是「编辑当前模型」），实际行为是跳到 API 配置列表页去**新增**配置，
  /// 用户因此怀疑该项没用。功能本身有用（已有配置想再加一个模型时的唯一入口），故只改文案。
  /// build102 (A)：value 从 null 改为非空哨兵 [_kAddModel] —— null 是「点外部关闭」
  /// 的返回值，PopupMenuButton 对它走 onCanceled 永不回调 onSelected（真根因）。
  List<PopupMenuEntry<Object>> _buildItems(
      BuildContext context, ColorScheme cs) {
    final items = <PopupMenuEntry<Object>>[];
    // ➕ 固定在弹窗顶部：离输入框最远，命中区不再贴弹窗底边
    items.add(
      PopupMenuItem<Object>(
        value: _kAddModel,
        child: Row(
          children: [
            // build138（#4 同批）：文案去 ➕（emoji 由左侧 Material 图标承载，
            // 本来就是同一个意思画两遍）；取色改中性 —— 弹出层也属于输入区，
            // 方案 B 下「唯一彩色」的口径要一路成立到弹窗里。
            Icon(Icons.add_circle_outline,
                size: 16, color: cs.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(
              isZh ? '添加模型' : 'Add model',
              style: TextStyle(
                fontSize: 13,
                color: cs.onSurface,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
    items.add(const PopupMenuDivider());
    // build138（B 批 / G48）：平铺列表 → **「服务商 → 模型」两级**。
    // 组序由 [groupByProvider] 定（保持配置原有顺序、custom 垫底），
    // 组头是不可选中的说明行（enabled:false）——**不会**新增 value 类型，
    // onSelected 依旧只会收到 ApiConfig 或 [_kAddModel]，
    // 所以 `onModelChanged(ApiConfig)` 的签名和行为一个字都没改。
    // 为什么用「组头 + 组内项」而不是 SubmenuButton 真级联：SubmenuButton 属于
    // MenuAnchor 体系，不能出现在 PopupMenuButton.itemBuilder 里，换它等于把
    // 整个切换器重写一遍（收益不抵风险）。
    for (final g in groupByProvider(availableConfigs, labelFor: (id) {
      final t = ApiProviderTemplateCatalog.instance.all
          .where((e) => e.id == id)
          .firstOrNull;
      if (t == null) {
        return id == ApiProviderTemplate.customId
            ? (isZh ? '自定义 / 中转站' : 'Custom / proxy')
            : id;
      }
      return isZh ? t.nameZh : t.nameEn;
    }, accountLabelFor: _accountLabel)) {
      items.add(
        PopupMenuItem<Object>(
          enabled: false,
          height: 30,
          child: Row(
            children: [
              VendorAvatar(templateId: g.templateId, size: 14),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  g.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                // G48 起组内还会按账号再切，所以这里的计数口径是**模型条目**
                // （原来写「个连接」，与下面的账号小标题一起看会自相矛盾）。
                isZh ? '${g.configs.length} 个模型' : '${g.configs.length}',
                style: TextStyle(fontSize: 11, color: cs.outline),
              ),
            ],
          ),
        ),
      );
      for (final a in g.accounts) {
        // build138（G48 账号维度）：同一服务商下**不止一个账号**时才插小标题
        // （公司号 / 个人号、官方域名 / 自建代理）。只有一个账号时不插 ——
        // 每层都顶一行说明会比平铺列表更难扫。
        // 为什么这件事必须做：切模型 = 决定「用哪把 Key 打哪个模型」。同厂商两个
        // 账号在平铺列表里长得一模一样，点错一个就是拿个人号的额度跑公司的模型，
        // 而账单上看不出区别。
        if (g.accounts.length > 1) {
          items.add(
            PopupMenuItem<Object>(
              enabled: false,
              height: 26,
              child: Padding(
                padding: const EdgeInsets.only(left: 20),
                child: Row(
                  children: [
                    Icon(Icons.badge_outlined, size: 12, color: cs.outline),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        a.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10.5,
                          color: cs.outline,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        for (final c in a.configs) {
          items.add(
            PopupMenuItem<Object>(
              value: c,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onLongPress: () => _openEditConfig(context, c),
                child: Row(
                  children: [
                    Expanded(
                      child: _ModelOption(
                        cleanName: ModelNameCleaner.cleanModelName(c.model),
                        originalName: c.model,
                        templateId: c.templateId,
                        cs: cs,
                      ),
                    ),
                    // build157（⑫ 真 P2）：编辑键原本 28dp 宽 / 36dp 高，而且和
                    // 「选中这个模型」抢同一条点击手势 —— 点偏 1dp 就换掉正在用的
                    // 模型，这是有账单后果的误触。
                    // 这里做两件事：
                    //   ① 命中块抬到 40×40。**宽度靠内边距吃左边 Expanded(模型名)
                    //      的富余**（模型名那两行本来就是 maxLines:1 + ellipsis，
                    //      少 12dp 只是多省略一两个字），Row 的总宽 = 菜单项宽 =
                    //      一个字没变 ⇒ 不存在"把行撑宽"这条溢出路径；
                    //      高度多出的几 dp 由弹窗自己的滚动区吸收。
                    //   ② 同一块上 onTap / onLongPress 一律走编辑，编辑区内部
                    //      不再有任何一点是"落到整行 = 选中模型"的（opaque 命中 +
                    //      比图标大一圈的余量），滑出这块才会落到选中。
                    GestureDetector(
                      // key 只为机检服务（test/build157_tap_targets_test.dart 要
                      // 单独量这一块的大小）；不参与任何布局与语义。
                      key: const ValueKey<String>('modelSwitcherEditAction'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _openEditConfig(context, c),
                      onLongPress: () => _openEditConfig(context, c),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                            minHeight: 40, minWidth: 40),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Center(
                            child: Icon(Icons.edit_outlined,
                                size: 16, color: cs.onSurfaceVariant),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
      }
    }
    return items;
  }

  /// 组内账号小标题：优先 `api_accounts.name`，没传账号表 / 名字为空时退化成
  /// 连接 host（**不含 Key**，弹窗会被截图，见 v1.7.x 的 Key 掩码约定）。
  String _accountLabel(ApiConfig member, int memberCount) {
    final id = member.accountId.trim();
    if (id.isNotEmpty) {
      final acc = accounts.where((x) => x.id == id).firstOrNull;
      final n = acc?.name.trim() ?? '';
      if (n.isNotEmpty) return n;
    }
    final host = AccountGrouping.hostKey(member.baseUrl);
    if (host.isEmpty) return isZh ? '未填地址' : 'No URL';
    return memberCount > 1
        ? (isZh ? '$host（$memberCount 个模型）' : '$host ($memberCount models)')
        : host;
  }

  /// 选中处理：哨兵 → 进设置；ApiConfig → onModelChanged
  void _onSelected(Object v, BuildContext context) {
    if (identical(v, _kAddModel)) {
      _openSettings(context);
    } else {
      onModelChanged?.call(v as ApiConfig);
    }
  }

  /// 跳转 API 配置列表页（选「➕编辑模型」时）。postFrame 避免在 popup 关闭同帧 push。
  /// v1.7.42：对齐 _openEditConfig 改用 rootNavigator —— 两处跳转原本一个用
  /// root 一个不用（不对称隐患：嵌套 Navigator 下会 push 到被覆盖的层）。
  void _openSettings(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute(builder: (_) => const ApiConfigScreen()),
      );
    });
  }

  /// 长按模型项：先关闭弹窗，再直接打开该模型的编辑页
  void _openEditConfig(BuildContext menuContext, ApiConfig config) {
    final nav = Navigator.of(menuContext, rootNavigator: true);
    Navigator.of(menuContext).pop(); // 关闭弹窗，不触发 onSelected
    WidgetsBinding.instance.addPostFrameCallback((_) {
      nav.push(
        MaterialPageRoute(builder: (_) => ApiConfigEditScreen(config: config)),
      );
    });
  }
}

/// 弹出列表单个模型项：清洗名（主）+ 原始名（副，小字灰）
class _ModelOption extends StatelessWidget {
  final String cleanName;
  final String originalName;
  final String templateId;
  final ColorScheme cs;

  const _ModelOption({
    required this.cleanName,
    required this.originalName,
    required this.templateId,
    required this.cs,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        VendorAvatar(templateId: templateId, size: 16),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                cleanName,
                style: const TextStyle(fontSize: 13),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (originalName != cleanName)
                Text(
                  originalName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
