// v1.7.15 第二轮拆分：原 settings_screen.dart 的"通用设置" Section +
// About / API Configs / Storage / Supported APIs 4 个 ListTile
//
// 目的：把通用设置从主 SettingsScreen 拆到独立 sub-screen，主 settings 只剩
// 导航 ListTile，行数从 1077 → <500。
//
// 设计权衡：本来这一 Section 没有高度突变 Switch，但拆出来后主 settings 变得
// 一目了然（只剩导航入口），且关于/存储这种"信息类" ListTile 单独成页更符合
// 用户预期。

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/web_search_config.dart';
import '../services/biometric_service.dart';
import '../services/live_task_center.dart';
import '../services/storage_service.dart';
import '../ui/tokens.dart';
import '../utils/app_snackbar.dart';
import '../utils/background_run_guide.dart';
// build167（机主 26 日 16:03 那条建议）：「愿意后台化」总闸 —— 持久化位与
// 「通知/灵动岛肯不肯用」的那一份判据都住在这里，页面上不许自己写第二串 `&&`。
import '../utils/background_run_switch.dart';
import '../utils/workspace_permission.dart';
import 'builtin_prompt_catalog_screen.dart';
import 'data_pack_update_screen.dart';
import 'workspace_permission_settings_screen.dart';

/// build167：从 StatelessWidget 改成 StatefulWidget —— 这一页现在要**持有**
/// 「愿意后台化」那一位：它是这一组第一行的开关，同时决定第二行（灵动岛/通知）
/// 点不点得动。用一个 State 拿着、往下传，而不是让两行各自异步读 prefs：
/// 两处各读各的就会在总闸刚拨完那一刻出现"上面已经开、下面还点不动"的错位
/// （本仓口径：两处同毛病先查共享组件，逐页补会留两种口径）。
class GeneralSettingsScreen extends StatefulWidget {
  const GeneralSettingsScreen({super.key});

  @override
  State<GeneralSettingsScreen> createState() => _GeneralSettingsScreenState();
}

class _GeneralSettingsScreenState extends State<GeneralSettingsScreen> {
  /// 总闸（`kBackgroundRunAllowedKey`）。null = 还没读到，此时那一行显示为关且点不动。
  bool? _backgroundRunAllowed;

  @override
  void initState() {
    super.initState();
    _loadBackgroundRunSwitch();
  }

  Future<void> _loadBackgroundRunSwitch() async {
    final allowed = await loadBackgroundRunAllowed();
    if (!mounted) return;
    setState(() => _backgroundRunAllowed = allowed);
  }

  /// 拨总闸那一下：落盘 → 让中枢按**生效值**开始/停止投影 → 只有开过才问系统要权限。
  ///
  /// 三条都对齐了既有事实，没有新造状态：
  ///  · 关掉时走 `setUserEnabled(false)` —— 撤通知栏/灵动岛的投影，
  ///    **不动任务真源、也不撤销用户早就给过的系统授权**（那个三方 App 撤不了）；
  ///  · 打开时才 `requestPermission()`：机主要的是"不是一开始就要询问是否允许"，
  ///    这一行是全仓**唯一**会在总闸之外主动弹系统权限框的地方（冷启动那一处
  ///    由 `main.dart` 的 `_initLiveTask` 读同一份判据，已经不会再无条件问）；
  ///  · 生效值只由 [mayUseLiveNotifications] 给，页面不自己写 `&&`。
  Future<void> _toggleBackgroundRun(bool v) async {
    await saveBackgroundRunAllowed(v);
    if (!mounted) return;
    setState(() => _backgroundRunAllowed = v);
    final prefs = await SharedPreferences.getInstance();
    final effective = mayUseLiveNotifications(
      backgroundRunAllowed: v,
      notificationsSwitch: prefs.getBool(kLiveNotificationsEnabled) ?? true,
    );
    await LiveTaskCenter.instance.setUserEnabled(effective);
    if (effective) await LiveTaskCenter.instance.requestPermission();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final zh = l.locale.languageCode == 'zh';
    final backgroundRunAllowed = _backgroundRunAllowed ?? false;
    return Scaffold(
      appBar: AppBar(title: Text(zh ? '通用设置' : 'General')),
      // v1.7.25：设置页固定缩放，避免全局字体缩放挤压布局
      body: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.2,
        child: ListView(
          padding: AppPad.page,
          children: [
            // build167（机主 16:03 那条建议的形状）：**「后台运行」这一组，第一项就是总闸**。
            // 三行是同一件事的三层，必须在一组里、一个口径：
            //  ① 是否愿意后台化（总闸，默认关 = 与 166 逐字节同行为）；
            //  ② 灵动岛/后台进度通知（**总闸关着时点不动**，也不向系统要权限）；
            //  ③ build165 那行 ColorOS 指引（`lib/utils/background_run_guide.dart`）——
            //     它本来就管"系统肯不肯让我们在后台跑"，166 却把它挂在别处，
            //     于是同一件事有两处入口两种口径。并进这一组，判据与文案一个字没改。
            AppSectionCard(
              children: [
                Padding(
                  // 水平留白由 `AppSectionCard.contentPadding` 给，这里只留上下
                  padding: const EdgeInsets.fromLTRB(0, 8, 0, 2),
                  child: Text(
                    l.tr('bgRunGroupHeader'),
                    style: TextStyle(
                        fontSize: 12, color: colorScheme.onSurfaceVariant),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  secondary: const Icon(Icons.battery_saver_outlined),
                  title: Text(l.tr('bgRunTitle')),
                  // 副标题**只说我们做了什么**：
                  //  开 ⇒ "不再由本应用收起这条连接"（这是本应用的行为，读得到）；
                  //  关 ⇒ "由本应用收起 + 回前台重发"（同样是行为；"关着就不问权限、
                  //  不投影"那一句只说一遍，在灵动岛那一行下面的 `bgRunIslandNeedsMaster`）。
                  // 禁止的形状是"后台不会中断/已开启后台运行"——那是**系统**的决定了什么,
                  // 而 165 的结论是：能申请的豁免集合是**空集**，我们连它开没开都读不到。
                  // 所以两句都带"系统仍可能中止"（机主 26 日嫌啰嗦之后只留这一处 hedge，
                  // 删掉的是重复的那半句"本应用不保证"，不是 hedge 本身）。
                  subtitle: Text(
                    backgroundRunAllowed
                        ? l.tr('bgRunSubtitleOn')
                        : l.tr('bgRunSubtitleOff'),
                    style: const TextStyle(fontSize: 12),
                  ),
                  value: backgroundRunAllowed,
                  onChanged: _backgroundRunAllowed == null
                      ? null
                      : _toggleBackgroundRun,
                ),
                LiveNotificationsCard(masterAllowed: backgroundRunAllowed),
                const BackgroundRunGuideCard(),
              ],
            ),
            AppSectionCard(
              // build163：原来这里写着 `title: '通用设置'` —— 与上面 AppBar 的标题
              // 一模一样，同一页里同一句词出现两次（机主圈出来的"很怪"有一半是这个）。
              // 卡片现在只留一行说明，标题交给 AppBar 一处。
              children: [
                Padding(
                  // 水平留白由 `AppSectionCard.contentPadding` 给，这里只留上下
                  padding: const EdgeInsets.fromLTRB(0, 8, 0, 2),
                  child: Text(
                    zh
                        ? '生物识别 / 云端更新 / 代理'
                        : 'Biometric / Remote update / Proxy',
                    style: TextStyle(
                        fontSize: 12, color: colorScheme.onSurfaceVariant),
                  ),
                ),
                // v1.7.25：信息类（关于/API配置/存储/服务商/GitHub）已拆到「关于」页
                // build138（G54）：原来这里并排两个「XX 云端更新」入口，各自只有一个
                // 单 URL 输入框、失败也不说原因。三个数据包收敛到 DataPackService 后，
                // 统一收成一个「数据包更新」子页（多源有序 + 版本/sha256 闸门 + 状态）。
                _buildDataPackTile(context, zh),
                // build140（P0 缺口⑤）：与上一条成对——「数据包更新」调**源**，
                // 「内置提示词与协议」看**生效值**（哪几条被远程覆盖、正文长什么样）。
                // 少这一条，数据包拉下来之后用户看不见它到底改了什么。
                _buildPromptCatalogTile(context, zh),
                _buildGitHubProxyTile(context, zh),
                _buildBiometricLockTile(context, zh),
                // build138（甲1）：AI 文件工作区权限档位——消费点在
                // builtin_plugins._wsConfirm()，档位默认「每次确认」＝现状零变化。
                _buildWorkspacePermissionTile(context, zh),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// build138（G54）：数据包更新入口（厂商模板 / 内置提示词·插件协议 / MCP 目录）。
  Widget _buildDataPackTile(BuildContext context, bool zh) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: const Icon(Icons.inventory_2_outlined),
      title: Text(zh ? '数据包更新' : 'Data pack updates'),
      subtitle: Text(
        zh
            ? '服务商模板 / 内置提示词与插件协议 / MCP 目录 · 可自定义源、按序回退'
            : 'Provider templates / prompts & protocols / MCP catalog · custom sources with ordered fallback',
        style: const TextStyle(fontSize: 12),
      ),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const DataPackUpdateScreen()),
      ),
    );
  }

  /// build140（P0 缺口⑤）：内置提示词 / ReAct 协议目录浏览页入口。
  ///
  /// 这条能力从 build93 起就在（`BuiltinPromptCatalog` 被 api_service / plugin_registry /
  /// data_pack_service 三方消费），但**此前没有任何界面看得到它**：远程 JSON 覆盖了哪几条、
  /// 生效的到底是远程文本还是编译期内置、模型这一轮实际收到的协议长什么样，
  /// 只能连日志翻或改代码验证。
  Widget _buildPromptCatalogTile(BuildContext context, bool zh) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: const Icon(Icons.rule_outlined),
      title: Text(zh ? '内置提示词与协议' : 'Built-in prompts'),
      subtitle: Text(
        zh
            ? '查看每个内置插件当前生效的协议正文 · 标出哪几条被远程数据包覆盖'
            : 'Read the protocol text each built-in plugin actually uses · '
                'marks which ones the remote pack overrides',
        style: const TextStyle(fontSize: 12),
      ),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const BuiltinPromptCatalogScreen()),
      ),
    );
  }

  Widget _buildGitHubProxyTile(BuildContext context, bool zh) {
    return FutureBuilder<WebSearchConfig>(
      future: context.read<StorageService>().getWebSearchConfig(),
      builder: (context, snapshot) {
        final proxy = snapshot.data?.githubProxyUrl ?? '';
        return ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.swap_horiz_outlined),
          title: Text(zh ? 'GitHub 代理' : 'GitHub Proxy'),
          subtitle: Text(
            proxy.isNotEmpty ? proxy : (zh ? '未设置（直连）' : 'Not set (direct)'),
            style: const TextStyle(fontSize: 12),
          ),
          onTap: proxy.isNotEmpty
              ? () {
                  showDialog(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: Text(zh ? 'GitHub 代理地址' : 'GitHub Proxy URL'),
                      content: Text(proxy),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: Text(zh ? '关闭' : 'Close'),
                        ),
                      ],
                    ),
                  );
                }
              : null,
        );
      },
    );
  }

  /// build138（甲1）：AI 文件工作区权限档位入口。
  /// 档位存在 SharedPreferences（与「允许 AI 读取日志」同类全局开关，不占 DB 列），
  /// 消费点是 builtin_plugins._wsConfirm()；默认「每次确认」＝线上现状。
  Widget _buildWorkspacePermissionTile(BuildContext context, bool zh) {
    return FutureBuilder<WsPermissionTier>(
      future: WorkspacePermissionStore.load(),
      builder: (context, snap) {
        final tier = snap.data ?? WsPermissionTier.alwaysAsk;
        return ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          leading: const Icon(Icons.shield_outlined),
          title: Text(zh ? 'AI 文件工作区权限' : 'AI workspace permission'),
          subtitle: Text(
            zh
                ? '当前：${wsPermissionTierLabel(tier, true).title} · AI 写/改/删工作区文件前是否要问你'
                : 'Current: ${wsPermissionTierLabel(tier, false).title}',
            style: const TextStyle(fontSize: 12),
          ),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => const WorkspacePermissionSettingsScreen()),
          ),
        );
      },
    );
  }

  Widget _buildBiometricLockTile(BuildContext context, bool zh) {
    final storage = context.read<StorageService>();
    return FutureBuilder<bool>(
      future: BiometricService.isAvailable,
      builder: (context, snapshot) {
        final available = snapshot.data ?? false;
        if (!available) return const SizedBox.shrink();
        // v1.7.26: 监听 StorageService（ChangeNotifier）→ 切开关后 UI 实时更新（不再等重启）
        return ListenableBuilder(
          listenable: storage,
          builder: (context, _) {
            return FutureBuilder<bool>(
              future: storage.getBiometricLockEnabled(),
              builder: (context, snap) {
                final enabled = snap.data ?? false;
                return SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  secondary: const Icon(Icons.lock_outline),
                  title: Text(zh ? '应用锁' : 'App Lock'),
                  subtitle: Text(
                    zh
                        ? '每次打开应用需验证指纹/面部/锁屏密码'
                        : 'Require fingerprint/face/screen lock to open app',
                    style: const TextStyle(fontSize: 12),
                  ),
                  value: enabled,
                  onChanged: (val) async {
                    if (val) {
                      final authed = await BiometricService.authenticate(
                        reason: zh
                            ? '请验证身份以开启生物识别锁'
                            : 'Please authenticate to enable biometric lock',
                      );
                      if (!authed) {
                        // build98（P2）：生物识别失败/取消时给用户明确反馈
                        if (context.mounted) {
                          AppSnackBar.showSnackBar(context, SnackBar(
                            content: Text(zh
                                ? '身份验证未通过，未开启应用锁'
                                : 'Authentication failed; app lock not enabled'),
                            backgroundColor:
                                Theme.of(context).colorScheme.error,
                          ));
                        }
                        return;
                      }
                    }
                    await storage.setBiometricLockEnabled(val);
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}

/// build142（灵动岛）：后台进度通知的开关 + 权限状态 + 系统设置入口。
///
/// 单独做成 StatefulWidget 而不是往 StatelessWidget 里塞：这一条要显示
/// 「通知权限到底给没给」，而那是异步从原生问回来的，必须有本地状态。
///
/// build167（机主 26 日 16:03：「若允许之后才能开启灵动岛和通知」）：这一行挂在
/// 那道「愿意后台化」总闸**后面** —— 总闸关着时它点不动、也不向系统要权限，
/// 显示的也是"生效值"而不是自己那把 pref（否则上面关着、这里画一个开着的开关，
/// 用户读到的是一句假话）。判据只有一份：[mayUseLiveNotifications]。
class LiveNotificationsCard extends StatefulWidget {
  const LiveNotificationsCard({super.key, required this.masterAllowed});

  /// 上面那一项「愿意后台化」的当前值，由宿主读好传下来（**不在这里再读一遍 prefs**：
  /// 两处各读各的会在拨完总闸那一刻错位）。
  final bool masterAllowed;

  @override
  State<LiveNotificationsCard> createState() => _LiveNotificationsCardState();
}

class _LiveNotificationsCardState extends State<LiveNotificationsCard> {
  bool? _on;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _on = prefs.getBool(kLiveNotificationsEnabled) ?? true;
      _loading = false;
    });
  }

  Future<void> _toggle(bool v) async {
    // 总闸关着 ⇒ 这一行根本点不动（`onChanged` 给的 null），这里再挡一次是护栏：
    // 走到这里就会写 prefs、就会把投影打开 —— 那是机主明确说"不是一开始就要询问"的那件事。
    if (!widget.masterAllowed) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kLiveNotificationsEnabled, v);
    await LiveTaskCenter.instance.setUserEnabled(mayUseLiveNotifications(
        backgroundRunAllowed: widget.masterAllowed, notificationsSwitch: v));
    if (!mounted) return;
    setState(() => _on = v);
    if (v) await LiveTaskCenter.instance.requestPermission();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final zh = l.locale.languageCode == 'zh';
    final center = LiveTaskCenter.instance;
    final cs = Theme.of(context).colorScheme;
    final granted = center.permissionGranted == true;
    final live = center.liveUpdatesSupported == true;
    final effective = mayUseLiveNotifications(
        backgroundRunAllowed: widget.masterAllowed,
        notificationsSwitch: _on ?? true);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: effective,
          onChanged: (_loading || !widget.masterAllowed) ? null : _toggle,
          title: Text(zh ? '后台进度通知' : 'Background progress'),
          subtitle: Text(zh
              ? '下载 / 备份 / 深度研究 / 反问等待时在通知栏显示进度'
              : 'Show progress for downloads, backups, research and questions'),
        ),
        if (!widget.masterAllowed)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Text(
              l.tr('bgRunIslandNeedsMaster'),
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ),
        if (effective && !granted)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  // build155（第 13 轮 · 权限引导一致性）：这条引导原来无论什么版本都
                  // 挂一个「去允许」按钮，而按钮做的是 `requestPermission()` ——
                  // **Android 13 以下系统里根本没有这个弹窗**（原生那个方法在 sdk<33 时
                  // 直接返回 `areNotificationsEnabled()`，一个对话框都不弹）。
                  // 于是 Android 12 的用户按下去"什么都没发生"，而真正管用的那个开关
                  // 在系统通知设置里、页面上又没有任何入口（本卡片下面那个
                  // 「实时活动」引导同样是只给一句"请到系统通知设置里找"、不给门）。
                  // 口径：**承诺不了弹窗就给门**，两种情形分开写。
                  zh ? '系统还没允许本应用显示通知' : 'Notifications are blocked',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: center.sdkInt >= 33
                        ? () => center.requestPermission()
                        : () => center.openNotificationSettings(),
                    child: Text(zh
                        ? (center.sdkInt >= 33 ? '去允许' : '打开通知设置')
                        : (center.sdkInt >= 33 ? 'Allow' : 'Open settings')),
                  ),
                ),
              ],
            ),
          ),
        if (effective && granted)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    zh
                        ? switch (center.promotedAllowed) {
                            // build145 真机实证：ColorOS 16 上 `canPostPromotedNotifications()`
                            // 返回 false、而我们这条通知 `promotable=true`（系统认可它够格）
                            // ⇒ 「没有岛」是系统不让发，不是 App 坏了。这话必须直接说给用户，
                            //   否则他只会再报一次「灵动岛用不了」。
                            // build155：文案改口径 —— `canPost=false` 有两种原因
                            // （ROM 就没有这个功能 / 有功能但默认没给我们开），
                            // 而旧文案断言"系统里有那个开关、你去找找"，
                            // 在前一种 ROM 上是**让用户去找一个不存在的东西**。
                            // 改成"有就去开、没有就是本机不支持"，并把门给出来。
                            false => live
                                ? '系统未允许实时活动：到通知设置找「实时活动/流体云」，没有就是本机不支持'
                                : '本机非 Android 16，按普通进度通知显示',
                            true => // `canPost=true` 只说明"门是开的"，不等于"岛已经出来了"。
                                // 旧文案在这里写「状态栏/锁屏应有进度」，而用户此刻看到的
                                // 正是一条都没有 —— 那句"应有"既误导他去找不存在的东西，
                                // 也让我们自己的排查从第一行就被带偏（build154 那份导出
                                // 就是被一条恒假的 `promotedFlag=false` 带去的）。
                                // 现在按系统侧回读的三态说实话。
                                switch (center.systemPromoted) {
                                  true => '系统已把这条任务提升为实时活动',
                                  false => live
                                      ? '系统允许发布，但这条还没被提升（厂商没渲染或时机未到）'
                                      : '本机非 Android 16，按普通进度通知显示',
                                  null => '系统允许发布；这条提升与否还没问过系统',
                                },
                            null => '还没跑过长任务，系统判定要等第一次下发后才知道',
                          }
                        : 'Background progress notifications enabled',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                ),
                // 只有这一句在教用户去系统设置里找东西时才配一个门；
                // 「本机非 Android 16」与「还没跑过长任务」两种情形没有可去之处，不摆空按钮。
                if (live && center.promotedAllowed == false)
                  TextButton(
                    onPressed: () => center.openNotificationSettings(),
                    child: Text(zh ? '通知设置' : 'Settings'),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// build165（任务 #88）：「后台被系统限制怎么办」这一行。
///
/// 为什么单独成 widget 而不是往上面那张卡片里塞几行：这一条要有本地状态 ——
/// 跳转失败的原因只有原生回执那一刻才知道，而回执必须**显示在页面上**
/// （本仓口径：静默降级按缺陷处理；对用户"点了没反应"就是最常见的假完成形状）。
///
/// 判据（要不要出现 / 写什么 / 点了去哪个 action / 失败说什么）全在
/// `lib/utils/background_run_guide.dart` 那份纯函数里，这里**一字不编**：
/// 页面只负责把交回的字符串摆上去。诚实条款也在那里 —— 系统里那个开关读不到，
/// 所以这一行永远不许出现"已开启/未开启"这类断言状态的措辞。
class BackgroundRunGuideCard extends StatefulWidget {
  const BackgroundRunGuideCard({super.key});

  @override
  State<BackgroundRunGuideCard> createState() => _BackgroundRunGuideCardState();
}

class _BackgroundRunGuideCardState extends State<BackgroundRunGuideCard> {
  /// 上一次跳转的失败原因（null = 没有失败过，或刚成功）。
  String? _error;
  bool _busy = false;

  Future<void> _open(String target, bool zh) async {
    if (_busy) return;
    setState(() => _busy = true);
    // 日志由 LiveTaskCenter 那一侧打（tag=BgGuide，含目标 + 成功/失败 + 原因）：
    // 下一轮真机取证要回答的就是「他到底进过那个页面没有」。
    final why = await LiveTaskCenter.instance.openSystemSettingsPage(target);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = why == null ? null : bgGuideFailureText(why, zh: zh);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final zh = l.locale.languageCode == 'zh';
    final cs = Theme.of(context).colorScheme;
    final row = bgGuideRow(
        isAndroid: defaultTargetPlatform == TargetPlatform.android, zh: zh);
    if (!row.visible) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          // 水平留白归 `AppSectionCard.contentPadding`（build163 收进组件的那一次），
          // 这里再写一份就是两种口径。
          contentPadding: EdgeInsets.zero,
          dense: true,
          leading: const Icon(Icons.settings_applications_outlined),
          title: Text(row.title),
          subtitle: Text(
            '${row.body}\n${row.honestNote}',
            style: const TextStyle(fontSize: 12),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 0, 0, 4),
          child: Text(
            row.pathHint,
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
        ),
        Row(
          children: [
            Expanded(
              child: TextButton(
                onPressed: _busy ? null : () => _open(row.primaryTarget, zh),
                child: Text(row.primaryLabel),
              ),
            ),
            Expanded(
              child: TextButton(
                onPressed: _busy ? null : () => _open(row.secondaryTarget, zh),
                child: Text(row.secondaryLabel),
              ),
            ),
          ],
        ),
        Text(
          row.secondaryNote,
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 4, 0, 0),
            child: Text(_error!,
                style: TextStyle(fontSize: 12, color: cs.error)),
          ),
      ],
    );
  }
}
