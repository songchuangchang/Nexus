import 'dart:async';
import 'dart:io';
import 'screens/webdav_settings_screen.dart';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'theme.dart';
import 'l10n/app_localizations.dart';
import 'providers/locale_provider.dart';
import 'providers/font_size_provider.dart';
import 'providers/chat_skin_provider.dart';
import 'screens/backup_settings_screen.dart';
import 'screens/data_pack_update_screen.dart';
import 'screens/video_gen_screen.dart';
import 'services/live_task_center.dart';
import 'services/app_resume_signal.dart';
import 'services/stream_probe.dart';
import 'services/storage_service.dart';
import 'services/app_update_service.dart';
import 'services/biometric_service.dart';
import 'services/logger_service.dart';
import 'services/data_pack_service.dart';
import 'services/share_intent_service.dart';
import 'models/chat_message.dart';
import 'models/conversation.dart';
import 'models/shared_payload.dart';
import 'di/providers.dart';
import 'screens/onboarding_language_screen.dart';
import 'screens/conversation_list_screen.dart';
import 'desktop/workbench_screen.dart';
import 'screens/api_config_screen.dart';
import 'screens/chat_screen.dart';
import 'plugins/plugin_registry.dart';
import 'plugins/builtin_plugins.dart';
import 'utils/app_snackbar.dart';
import 'utils/frame_probe.dart';
import 'ui/app_shell.dart';
// build167：设置里那道「愿意后台化」总闸（持久化位 + "通知/岛肯不肯用"的唯一判据）。
// 消费点：本文件的 `_initLiveTask`（冷启动问不问系统要权限）与
// `screens/general_settings_screen.dart`（那一组的三行都读同一份判据）。
import 'utils/background_run_switch.dart';

/// v1.7.12：全局 ScaffoldMessengerKey（启动后静默更新提示、全局 Toast 等场景需要脱离当前页面 context 弹 SnackBar）
final GlobalKey<ScaffoldMessengerState> rootScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

/// build123：全局 NavigatorKey——分享到达时可能身处任意页面（或还在首帧），
/// 需要一个不依赖当前 context 的导航入口把「最近的聊天页」推到栈顶。
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

void main() {
  // 全部初始化与 runApp 必须处于同一 Zone，否则 Flutter 绑定在 root zone、
  // runApp 在自定义 zone，启动时报 "Zone mismatch" 警告。
  runZonedGuarded(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      final logger = LoggerService.instance;
      // 先初始化 logger（后续所有埋点依赖它）
      logger.init().ignore();

      // v1.4.2：全局 Flutter 异常捕获（UI 线程同步错误）
      FlutterError.onError = (FlutterErrorDetails details) {
        FlutterError.presentError(details);
        // 已知无害的绘制提示（ListTile 水波纹被装饰盒盖住），只刷日志不产生实际影响，
        // 且流式期间每秒重复刷，直接过滤掉防日志洪泛
        final exStr = details.exceptionAsString();
        if (exStr.contains('ListTile background color or ink splashes')) {
          return;
        }
        logger.error(
          'FlutterError: ${details.exception}',
          stack: details.stack,
          cat: LogCat.error,
          tag: 'UI',
        );
      };

      // v1.4.2：全局异步异常捕获（async/await 链路上未被处理的 error）
      PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
        logger.error(
          'PlatformDispatcher.uncaught: $error',
          error: error,
          stack: stack,
          cat: LogCat.error,
          tag: 'ASYNC',
        );
        return true;
      };

      runApp(const AIChatApp());
      // build169（169-B）：帧探针挂在 runApp **之后** —— 它要的是
      // `WidgetsBinding.instance` 已经就绪、且第一帧已经开始排。
      // 这台平板上外部帧尺子三条路全实测走不通（见 lib/utils/frame_probe.dart 文件头），
      // 进程内这一个读数是"这一帧多久"唯一的来源，走自己的日志通道 ⇒
      // 遍历机械 `adb logcat` 直接能收，不需要用户动手。
      FrameProbe.instance.start();
    },
    (Object error, StackTrace stack) {
      LoggerService.instance.error(
        'runZonedGuarded: $error',
        error: error,
        stack: stack,
        cat: LogCat.error,
        tag: 'ZONE',
      );
    },
  );
}

class AIChatApp extends StatefulWidget {
  const AIChatApp({super.key});

  @override
  State<AIChatApp> createState() => _AIChatAppState();
}

class _AIChatAppState extends State<AIChatApp> with WidgetsBindingObserver {
  // v1.7.9 (M18)：去掉 late final，允许初始化失败后重试重赋值
  late Future<bool> _initFuture;
  final _logger = LoggerService.instance;

  // v1.6.5：全局唯一 LocaleProvider 实例（此前 _initApp 和 Provider 各建一个，
  // 后者从未 init() → 重启后 _locale 恒为 null → 回落系统语言，用户选的英文失效）
  late final LocaleProvider _localeProvider = LocaleProvider();
  late final FontSizeProvider _fontSizeProvider = FontSizeProvider();
  late final ChatSkinProvider _chatSkinProvider = ChatSkinProvider();

  // v1.6.9：全局 PluginRegistry（插件化架构核心注册器）。
  // 用户要求：插件启用 → prompt 里加对应协议；禁用 → 不加；安装新插件 → 追加到后面。
  // **必须先同步创建**，否则 widget test 里 build 同步访问 MultiProvider 时会 LateInitializationError。
  // 构造函数内部会异步调用 _initFromStorage() 读启用状态，避免首屏读不到。
  final PluginRegistry _pluginRegistry = createBuiltinPluginRegistry();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _logger
        .app('initState: AIChatApp mounting, registering lifecycle observer');
    _initFuture = _initApp();
    _initShareHandling();
    // build142（灵动岛）：后台进度通知。失败静默（非 Android / 未授权都不能影响启动）
    unawaited(_initLiveTask());
  }

  @override
  void dispose() {
    _shareSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // ===== build123：外部「分享到 Nexus」接收 =====
  StreamSubscription<SharedPayload>? _shareSub;
  bool _shareRouteInFlight = false;

  /// 订阅分享事件 + 取冷启动载荷。
  ///
  /// 顺序有意为之：**先订阅再取冷启动**。若原生在订阅前就通过 `onShare` 推了
  /// 载荷，服务会把它暂存在 buffered 里，随后 drain 补取——两条路径都不会丢，
  /// 也不会重复（原生对同一份载荷只会走其中一条）。
  Future<void> _initShareHandling() async {
    final svc = ShareIntentService.instance;
    _shareSub = svc.stream.listen(_handleSharePayload);
    await svc.init();
    final cold = svc.takeInitial();
    if (cold != null) {
      await _handleSharePayload(cold);
    }
    final buffered = svc.drainBuffered();
    if (buffered != null) {
      await _handleSharePayload(buffered);
    }
  }

  /// build142（灵动岛）：起通知 + 接「点通知回哪一页」。
  ///
  /// **不**在这里做换轮计数：Android 的 pause/resume 已经会经 `_BiometricGateState`
  /// 走完 build111 B-003 那套 `inAppActivityTransition` 深度计数，再补一次就是双重计数
  /// （要么误弹解锁、要么该锁时不锁 —— 正是 B-003 修过的族问题）。
  ///
  /// build167（用户 26 日 16:03 那条建议的原话：「设置第一个是**是否愿意后台化**，
  /// 若允许之后才能开启灵动岛和通知，**不是一开始就要询问是否允许**」）：
  /// 这一路多了一道总闸。判据只有一份（`mayUseLiveNotifications`，住在
  /// `lib/utils/background_run_switch.dart`），它同时决定下面这三件事 ——
  ///  ① 冷启动问不问系统要 `POST_NOTIFICATIONS`（总闸没开过就一个字都不问）；
  ///  ② 传给中枢的 `userEnabled`（关掉时走既有的 `setUserEnabled(false)`：撤投影、
  ///     不动任务真源，也**不撤销**用户早就给过的系统授权 —— 那个撤销不了）；
  ///  ③ 设置页那一行点不点得动。
  /// 这一条只管"我们做不做"，**不承诺后台一定跑得成**（165 的结论：可申请豁免的集合是
  /// 空集，放不放行由 ColorOS 决定）；`BgForensics` 那两行读数与这道闸无关 ——
  /// 回前台那一行只认 `_ready`（见 [LiveTaskCenter.logResumeForensics]），
  /// 总闸开着还是关着都得照打，否则"是系统冻了还是我们掐的"下次仍然只能猜。
  Future<void> _initLiveTask() async {
    final prefs = await SharedPreferences.getInstance();
    final notificationsSwitch = prefs.getBool(kLiveNotificationsEnabled) ?? true;
    final backgroundRunAllowed = await loadBackgroundRunAllowed(prefs: prefs);
    final enabled = mayUseLiveNotifications(
        backgroundRunAllowed: backgroundRunAllowed,
        notificationsSwitch: notificationsSwitch);
    final center = LiveTaskCenter.instance;
    // 顺序要紧：**回调先挂上再 initialize**。
    // initialize 内部一拿到原生回执就会重放冷启动路由，回调晚挂一帧那条路由就永久丢了
    // （表现为「点了通知，App 到前台但没跳到该去的那页」）。
    center.onOpen = (route) async => _openLiveRoute(route);
    await center.initialize(userEnabled: enabled);
    if (!enabled) {
      LoggerService.instance.info(
        'LiveTask 启动：总闸=${backgroundRunAllowed ? '开' : '关（默认）'} '
        '通知开关=${notificationsSwitch ? '开' : '关'} 生效=关 ⇒ 不请求系统通知权限、不投影进度',
        tag: 'Live',
      );
      return;
    }
    // Android 13+ 的授权：**只有总闸开过才走到这一行**（被拒后设置页里还有开关能补）。
    final granted = await center.requestPermission();
    LoggerService.instance.info(
      'LiveTask 启动：总闸=开 通知开关=开 授权=${granted == true ? '已给' : '未给/待给'} ${center.describe()}',
      tag: 'Live',
    );
  }

  /// 点通知的落地页。未知路由**什么都不做**（App 已回到前台，别乱推页面）。
  Future<void> _openLiveRoute(String route) async {
    if (route.isEmpty || route == kLiveRouteChat) return;
    final nav = await _waitNavigator();
    final ctx = nav?.context;
    // 跨 await 用 context 之前必须复查有效性：等 Navigator 最长 3 秒，
    // 这期间 Activity 被销毁不是罕见事（点通知 → 系统先杀后重建）。
    if (ctx == null || !ctx.mounted) return;
    final Widget page;
    switch (route) {
      case kLiveRouteVideo:
        page = const VideoGenScreen();
      case kLiveRouteBackup:
        page = const BackupSettingsScreen();
      case kLiveRouteDataPacks:
        page = const DataPackUpdateScreen();
      default:
        return;
    }
    await Navigator.of(ctx).push(MaterialPageRoute(builder: (_) => page));
  }

  /// 等待 Navigator 就绪：冷启动时分享事件可能早于 MaterialApp 首帧，
  /// 此时 currentState 仍为 null（最多等 3 秒，超时则记日志放弃）。
  Future<NavigatorState?> _waitNavigator() async {
    for (var i = 0; i < 30; i++) {
      final nav = rootNavigatorKey.currentState;
      if (nav != null) return nav;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return null;
  }

  /// 分享落点决策：**不落在首页（会话列表），直接进最近的聊天页**。
  ///
  /// - 目标会话 = 最近活跃会话（`getMostRecentConversation`）；一个都没有就新建；
  /// - 目标会话**正开着** → 直接把内容投进它的输入框（不叠第二层 ChatScreen，
  ///   否则栈里两个同一会话会出现「发完一条列表不刷新」的错位）；
  /// - 否则把 ChatScreen 推到栈顶——底下仍保留会话列表，返回键可回首页。
  Future<void> _handleSharePayload(SharedPayload payload) async {
    if (_shareRouteInFlight) return; // 并发投递只处理一次
    _shareRouteInFlight = true;
    try {
      final storage = StorageService.instance;
      if (!storage.isInitialized) await storage.init();
      var conv = await storage.getMostRecentConversation();
      if (conv == null) {
        var configs = await storage.getApiConfigs();
        if (configs.isEmpty) {
          // G53（build136）：原先这里落一条 **openai 假配置**
          // （ApiConfig.create() 的默认值 name='New API' /
          // baseUrl='https://api.openai.com' / model='gpt-4o-mini'）。
          // 用户从没填过 Key 也会得到一条「看起来能用」的配置，发出去必然 401。
          // 改为引导去配置页建账号：配好继续投递，没配就如实记录内容被丢弃
          // （不再静默造数据）。
          _logger.warn('[Share] 无 API 配置，先引导配置 ${payload.describe()}');
          final nav0 = await _waitNavigator();
          if (nav0 == null) {
            _logger.warn('[Share] Navigator 未就绪，分享内容被丢弃 ${payload.describe()}');
            return;
          }
          await nav0.push(
            MaterialPageRoute(builder: (_) => const ApiConfigScreen()),
          );
          configs = await storage.getApiConfigs();
          if (configs.isEmpty) {
            _logger.warn('[Share] 仍未配置 API，分享内容被丢弃 ${payload.describe()}');
            return;
          }
        }
        conv = Conversation.create(apiConfigId: configs.first.id);
        await storage.saveConversation(conv);
        _logger.app('[Share] 无历史会话，已新建 id=${conv.id}');
      }
      if (ShareIntentService.instance.deliverToOpenChat(conv.id, payload)) {
        _logger.app('[Share] 已投递到当前打开的会话 ${conv.id}');
        return;
      }
      final nav = await _waitNavigator();
      if (nav == null) {
        _logger.warn('[Share] Navigator 未就绪，分享内容被丢弃 ${payload.describe()}');
        return;
      }
      _logger.nav('[Share] push → ChatScreen conv=${conv.id}');
      await nav.push(MaterialPageRoute(
        builder: (_) => ChatScreen(conversation: conv!, initialShare: payload),
      ));
    } catch (e, st) {
      _logger.error('[Share] 处理分享失败', error: e, stack: st);
    } finally {
      _shareRouteInFlight = false;
    }
  }

  // v1.4.2：应用前后台生命周期埋点
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _logger.app('Lifecycle: ${state.name}');
    // build156（后台冻结探针）：出去/回来各记一次，回来那一下写一行结论。
    // 用户报「思考中退后台，岛卡住；回去又继续思考」——这句话有两种成因且修法互斥：
    // 甲=流还在收、只是岛没心跳；乙=整条流在后台停摆（进程被冻结）。
    // 分辨只需"后台期间 chunk 增量"这一个数，别再靠语感猜（输入框那条猜了七轮）。
    // 只认 paused：hidden/inactive 在小窗/分屏/系统面板都会来，会把探针基线洗脏。
    if (state == AppLifecycleState.paused) StreamProbe.notePaused();
    // build165 ①（用户 08:04 那份导出：带后台的 7 轮里 5 轮只收到 0~1 个 chunk，
    // 8 次报错全落在 `resumed` 之前 0.10~0.19 秒）：**在被冻之前自己收线**。
    // 机制假设已收窄到"进程冻结 ⇒ 没人读 socket ⇒ 缓冲填满 ⇒ 上游关线"，而厂商侧
    // 没有任何可申请免冻结的 API（AOSP 的 Doze/资源表/freezer 三条都已用官方原文排除）
    // ⇒ 能做的只有主动收，把"说不清的网络故障"换成"我们收的、并且欠他一次重发"。
    // 通知点与下面 `notifyResumed()` 同在这一处：页面侧一律不自己 addObserver。
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      AppResumeSignal.instance.notifyBackgrounded();
    }
    if (state == AppLifecycleState.resumed) {
      final verdict = StreamProbe.noteResumed();
      if (verdict != null) _logger.app(verdict);
      // build165（任务 #86）：**这一处是全仓唯一**读「上一次进程是怎么没的」的地方，
      // 也是那一行「心跳断档 || 上次退出」并列读数的唯一出口。
      // 为什么只在这一次：`getHistoricalProcessExitReasons` 是一次 system_server 的 IPC，
      // 放进每秒心跳就是白烧 IPC（本机 minSdk 24，原生侧另带 API 29 版本判断）。
      // 为什么要它：带后台的 7 轮里 5 轮只收到 0~1 个 chunk，而"没收到"有三种成因
      // （进程被冻结 / 被内存上限杀掉（Android 17 起对所有应用生效，描述里带
      // `MemoryLimiter`）/ 上游或网络关线），三者修法互斥，光靠 chunk 数分不开。
      unawaited(LiveTaskCenter.instance.logResumeForensics());
      // build162：回前台这一下也是「掉线续写」唯一允许的起飞时刻。
      // 真机结论（用户 16:45 那份，1.7.104+161）：人在后台时新起的流必然在
      // 几秒内被对端关闭 ⇒ 161 那种"掉线当时立刻续"在后台里注定失败。
      // 通知点只这一处（本方法是全仓打 `Lifecycle:` 的那个 observer，
      // 页面侧不再各自 addObserver）。
      AppResumeSignal.instance.notifyResumed();
    }
    _maybeResyncLiveTaskOnBackground(state);
    _maybeReclaimLiveTaskRows(state);
    _maybeAutoSyncOnResume(state);
  }

  /// build157（第 15 轮扫描 P2）：回前台先问一句"岛上有该收没收的行吗"。
  ///
  /// 为什么单独一条而不塞进 [LiveTaskCenter.resyncForBackground] 那条路：
  /// 那条只在 `paused` 跑，而"任务刚完成就锁屏"这一族的停留期是在**冻结期间**过掉的；
  /// 解冻后延时通常会补跑，但**通知在进程被杀后还留在栏上**（Dart 侧已经什么都没有），
  /// 于是回到前台的这一刻是唯一能收拾它的时机。只清扫、不补推，前台零打扰。
  void _maybeReclaimLiveTaskRows(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(LiveTaskCenter.instance.reclaimStaleRows());
  }

  /// build149（真机反馈「在这些地方退出没有灵动岛」）：出去的那一刻补推一次岛快照。
  ///
  /// 系统与判定口径写在 [LiveTaskCenter.resyncForBackground]：promoted ongoing 的
  /// 判定发生在**贴通知那一刻**，而最后一次贴往往发生在还在前台的时候。
  /// 只认 `paused`：`hidden`/`inactive` 在小窗、分屏、系统面板上都会来，
  /// 那些场景人还在看屏幕，不该把岛"重新申请"一次（真推了也只是白推）。
  void _maybeResyncLiveTaskOnBackground(AppLifecycleState state) {
    if (state != AppLifecycleState.paused) return;
    unawaited(LiveTaskCenter.instance.resyncForBackground());
  }

  DateTime? _lastPausedAt;

  /// 「真的出去过」的最短后台时长。低于它的一律当假 resumed 丢掉：
  /// 打开相机/相册/文档选择器、指纹框开合都会成对报 paused→resumed
  /// （v1.7.30 在应用锁那条路上已经为此吃过一次「一选图片就弹锁」）。
  static const Duration _resumeSyncGap = Duration(minutes: 5);

  /// build146（自动同步只有一个触发点）：`maybeWebdavAutoSync()` 原来只在
  /// `_initApp()` 末尾跑一次 ⇒ **手机不杀进程就永远不再自动备份**，
  /// 而设置页那个「自动同步」开关看起来是开着的。现在回前台补一次检查。
  /// 24h 闸门在函数内部读时间戳 ⇒ 这里多叫几次只是白跑一趟判断，不会重复上传。
  void _maybeAutoSyncOnResume(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _lastPausedAt = DateTime.now();
      return;
    }
    if (state != AppLifecycleState.resumed) return;
    final since = _lastPausedAt;
    if (since == null) return;
    _lastPausedAt = null;
    if (DateTime.now().difference(since) < _resumeSyncGap) return;
    _logger.app('Lifecycle: 后台 ${DateTime.now().difference(since).inMinutes} 分 ⇒ 触发 WebDAV 自动同步检查');
    unawaited(maybeWebdavAutoSync());
  }

  Future<bool> _initApp() async {
    final stopwatch = Stopwatch()..start();
    await _logger.init();
    _logger.app(
        'App starting (LoggerService ready in ${stopwatch.elapsedMilliseconds}ms)');

    // build138（P1-3 补完）：把消息反序列化的「坏元素已跳过」接到真日志上。
    // ChatMessage 自己不 import LoggerService（保持 model 层可单测），
    // **这里是全库唯一的接线点** —— 没这一行，P1-3 的容错就还是静默降级。
    ChatMessage.corruptReporter = (m) => _logger.dbWarn(m);

    await StorageService.instance.init();
    _logger
        .app('StorageService ready (total ${stopwatch.elapsedMilliseconds}ms)');

    // v1.7.32：远程模板/协议先加载本地成功缓存，再按 7 天策略在线更新。
    // v1.7.42（冷启动优化）：deferRemoteRefresh=true，远程刷新挪后台，
    // 首帧只加载本地缓存，不阻塞启动（jsdelivr 国内被墙时 20s 超时不再拖慢启动）。
    // 首次启动或上次失败会在本次启动后台重试一次，失败不清空旧缓存。
    // build138（G54–G56）：三个数据包（厂商模板 / 内置提示词·插件协议 / MCP 目录）
    // 的缓存、多源有序回退、版本与 sha256 闸门统一由 DataPackService 编排；
    // 默认源与 7 天节奏都在它的注册表里，这里不再各包各写一遍。
    await DataPackService.instance.initialize(deferRemoteRefresh: true);

    // v1.6.9：PluginRegistry 已经在字段初始化时同步 createBuiltinPluginRegistry()，
    // 这里仅绑定 StorageService 实例（它的 _initFromStorage 会从 storage 读插件启用状态），
    // 给 30ms 让内部 await StorageService 完成，避免首屏渲染时还没读。
    // 因为 createBuiltinPluginRegistry(storage: null) 时会用 StorageService.instance 兜底，
    // 所以这里不需要再手动重绑，只需要等一下即可。
    await Future.delayed(const Duration(milliseconds: 30));
    _logger.app(
        'PluginRegistry ready (${_pluginRegistry.plugins.length} plugins, total ${stopwatch.elapsedMilliseconds}ms)');

    final localeProvider = _localeProvider;
    await _localeProvider.init();
    await _fontSizeProvider.init();
    await _chatSkinProvider.init();
    final done = await localeProvider.isOnboardingCompleted;
    stopwatch.stop();
    _logger.app(
        'Init complete: onboarded=$done, total ${stopwatch.elapsedMilliseconds}ms');
    // build104（S6）：WebDAV 自动同步真实触发点——开关开启且距上次同步 ≥24h
    // 时后台推备份（不含密钥）。失败静默，绝不阻塞启动。
    unawaited(maybeWebdavAutoSync());
    return done;
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      // v1.7.24 (#12)：集中式 DI 层，见 lib/di/providers.dart + docs/DI_EVALUATION.md
      providers: buildAppProviders(
        localeProvider: _localeProvider,
        fontSizeProvider: _fontSizeProvider,
        chatSkinProvider: _chatSkinProvider,
        pluginRegistry: _pluginRegistry,
      ),
      child: Consumer<LocaleProvider>(
        builder: (context, lp, child) {
          return Consumer<FontSizeProvider>(
            builder: (context, fsp, _) {
              return MaterialApp(
                // v1.7.29: textScaler 必须在 MaterialApp.builder 内注入；
                // 包在 MaterialApp 外层会被 WidgetsApp 内部 MediaQuery(fromView) 覆盖，字体缩放失效
                // v1.7.26: 生物识别锁全局门（builder 位于 Navigator 之上，覆盖所有路由/页面）
                // build182（#160）：[AppWindowChrome] 落在**同一层、且在最外**——
                //  整窗背景与系统条避让是全 App 唯一的所有者，所以它必须包得住
                //  锁页（`_BiometricGate` 自己那一屏）与路由栈里的每一页。
                //  它只**抬** `MediaQuery.padding`（取 padding 与 systemGestureInsets 的较大者），
                //  所以今天所有 `SafeArea`/`ListView` 的自动避让口径不变；读数落一条
                //  `tag: Chrome` 日志＝装机后判"这台机到底报了什么"的唯一通道。
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(fsp.scale),
                  ),
                  child: AppWindowChrome(
                    readout: (r) => LoggerService.instance.info(
                      r.toLine(),
                      tag: 'Chrome',
                    ),
                    child: _BiometricGate(child: child),
                  ),
                ),
                title: 'Nexus',
                scaffoldMessengerKey: rootScaffoldMessengerKey,
                navigatorKey: rootNavigatorKey,
                locale: lp.locale,
                navigatorObservers: [
                  // v1.4.2：路由导航埋点 Observer（所有 push/pop/replace 都会落一条 NAV 日志）
                  _LifecycleNavObserver(logger: _logger),
                ],
                localizationsDelegates: const [
                  AppLocalizations.delegate,
                  GlobalMaterialLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                ],
                supportedLocales: const [
                  Locale('en'),
                  Locale('zh'),
                ],
                localeResolutionCallback: (deviceLocale, supported) {
                  if (lp.locale != null) return lp.locale;
                  for (final s in supported) {
                    if (deviceLocale?.languageCode == s.languageCode) {
                      return deviceLocale;
                    }
                  }
                  return supported.first;
                },
                theme: AppTheme.lightTheme,
                darkTheme: AppTheme.darkTheme,
                // build101（D5）：主题模式可手动指定（跟随系统 / 浅色 / 深色），
                // 由 ChatSkinProvider 从 shared_preferences 读取
                themeMode: switch (context.watch<ChatSkinProvider>().themeMode) {
                  'light' => ThemeMode.light,
                  'dark' => ThemeMode.dark,
                  _ => ThemeMode.system,
                },
                debugShowCheckedModeBanner: false,
                // B 线定位：Windows 桌面 = 代码工作台，不进手机聊天那套 home。
                home: Platform.isWindows
                    ? const DesktopWorkbenchScreen()
                    : FutureBuilder<bool>(
                  future: _initFuture,
                  builder: (context, snapshot) {
                    // v1.7.9 (M18 修复)：初始化抛异常时不再永久卡无按钮 loading 屏
                    if (snapshot.hasError) {
                      _logger.error('App init failed: ${snapshot.error}',
                          error: snapshot.error);
                      return Scaffold(
                        body: Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.error_outline,
                                    size: 48,
                                    color: Theme.of(context).colorScheme.error),
                                const SizedBox(height: 16),
                                const Text('初始化失败 / Initialization failed',
                                    style: TextStyle(fontSize: 16)),
                                const SizedBox(height: 8),
                                Text(
                                  '${snapshot.error}',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant),
                                ),
                                const SizedBox(height: 16),
                                FilledButton(
                                  onPressed: () {
                                    // 重启进程级初始化
                                    setState(() {
                                      _initFuture = _initApp();
                                    });
                                  },
                                  child: const Text('重试 / Retry'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }
                    if (!snapshot.hasData) {
                      return const Scaffold(
                        body: Center(child: CircularProgressIndicator()),
                      );
                    }
                    final onboarded = snapshot.data!;
                    if (!onboarded) {
                      _logger.nav('→ OnboardingLanguageScreen (first run)');
                      return const OnboardingLanguageScreen();
                    }
                    _logger.nav('→ ConversationListScreen');
                    // v1.7.12 引入启动静默检查 / v1.7.13 加 one-shot 守卫
                    // v1.7.13 修复：FutureBuilder 每次 rebuild 都会再注册一次 post-frame callback，
                    //   导致启动后 5 秒内重复打 5 次 GitHub API（撞速率限制风险）。
                    //   用 AppUpdateService.hasRunStartupSilentCheck 守卫保证每个进程只跑一次。
                    if (!AppUpdateService.hasRunStartupSilentCheck) {
                      AppUpdateService.markStartupSilentCheckRun();
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        Future<void>.delayed(const Duration(seconds: 3),
                            () async {
                          try {
                            final ctx = rootScaffoldMessengerKey.currentContext;
                            final info =
                                await AppUpdateService.checkForUpdate();
                            if (info.hasUpdate && ctx != null && ctx.mounted) {
                              final zh =
                                  Localizations.localeOf(ctx).languageCode ==
                                      'zh';
                              final sizeMb = (info.apkSize / 1024 / 1024)
                                  .toStringAsFixed(1);
                              AppSnackBar.showSnackBar(ctx, 
                                SnackBar(
                                  content: Text(zh
                                      ? '🎉 发现新版本 v${info.latestVersion}（${sizeMb}MB）\n去「设置 → 检查更新」下载安装'
                                      : '🎉 New version v${info.latestVersion} (${sizeMb}MB)\nGo to Settings → Check Update to install'),
                                  duration: const Duration(seconds: 8),
                                  action: SnackBarAction(
                                    label: zh ? '知道了' : 'OK',
                                    onPressed: () {},
                                  ),
                                ),
                              );
                            }
                          } catch (e) {
                            // 静默忽略：网络不通 / 服务器 5xx 都不打扰用户
                            debugPrint('catch 静默异常: $e');
                          }
                        });
                      });
                    }
                    return const ConversationListScreen();
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// 路由 Observer：所有页面进出都记一条 NAV 日志
/// 找 bug 时可以还原"用户按了什么 → 到了什么页面 → 然后崩了"的完整路径
class _LifecycleNavObserver extends NavigatorObserver {
  final LoggerService logger;
  _LifecycleNavObserver({required this.logger});

  String _name(Route<dynamic>? r) {
    if (r == null) {
      return 'Route<null>';
    }
    if (r.settings.name != null && r.settings.name!.isNotEmpty) {
      return r.settings.name!;
    }
    // Route.widget 不公开，fallback 用 runtimeType 字符串
    return r.runtimeType.toString();
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    logger.nav('push: ${_name(previousRoute)} → ${_name(route)}');
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    logger.nav('pop:  ${_name(route)} → ${_name(previousRoute)}');
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    logger.nav('replace: ${_name(oldRoute)} → ${_name(newRoute)}');
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    logger.nav('remove: ${_name(route)} (prev=${_name(previousRoute)})');
  }
}

// ===== v1.7.26：生物识别锁门 UI（启动画面 / 锁定页） =====
class _BiometricSplash extends StatelessWidget {
  const _BiometricSplash();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_bubble_outline,
                size: 56, color: colorScheme.primary),
            const SizedBox(height: 16),
            Text(
              'Nexus',
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurface),
            ),
          ],
        ),
      ),
    );
  }
}

class _BiometricLockScreen extends StatelessWidget {
  final VoidCallback onUnlock;
  const _BiometricLockScreen({required this.onUnlock});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [colorScheme.primaryContainer, colorScheme.surface],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_outline, size: 72, color: colorScheme.primary),
                const SizedBox(height: 16),
                Text(
                  'Nexus',
                  style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface),
                ),
                const SizedBox(height: 8),
                Text(
                  zh ? '应用已锁定 · 请验证身份' : 'App locked · Verify to continue',
                  style: TextStyle(
                      fontSize: 14, color: colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: onUnlock,
                  icon: const Icon(Icons.fingerprint),
                  label: Text(zh ? '解锁 / Unlock' : 'Unlock'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ===== v1.7.26：生物识别锁全局门（MaterialApp.builder 挂载，覆盖所有路由） =====
//  - 监听 StorageService（ChangeNotifier）→ 开关切换实时生效，无需重启
//  - 验证通过前不渲染 child（含所有 push 页面）→ 修复"首页有锁、聊天页没锁"
//  - 回到前台立即重锁 + 自动验证（fail-closed：异常一律视为未验证）
class _BiometricGate extends StatefulWidget {
  final Widget? child;
  const _BiometricGate({this.child});

  @override
  State<_BiometricGate> createState() => _BiometricGateState();
}

class _BiometricGateState extends State<_BiometricGate>
    with WidgetsBindingObserver {
  bool? _enabled; // null=检测中 / true=开启 / false=未开启
  bool _verified = false;
  bool _verifying = false; // 验证进行中：屏蔽 BiometricPrompt 弹/关触发的假 resumed
  bool _wasPaused = false; // 仅真正进入后台后，返回前台才重新验证
  bool _isZh = false;
  final _storage = StorageService.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _storage.addListener(_onStorageChanged);
    _apply();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _storage.removeListener(_onStorageChanged);
    super.dispose();
  }

  void _onStorageChanged() {
    // 设置页切开关 → saveWebSearchConfig notifyListeners → 这里实时响应
    _apply();
  }

  Future<void> _apply() async {
    final wasKnown = _enabled; // null = 还没读到过任何确定值
    try {
      final enabled = await _storage.getBiometricLockEnabled();
      if (!mounted) return;
      setState(() {
        final wasEnabled = _enabled;
        _enabled = enabled;
        if (!enabled) {
          _verified = true; // 关闭 → 直接解锁
        } else if (wasEnabled != true || !_verified) {
          _verified = false; // 开启（含刚打开/启动）→ 重置为需验证
        }
      });
      if (enabled == true && !_verified) {
        await _verify();
      }
    } catch (e) {
      LoggerService.instance
          .error('Biometric gate apply failed: $e', tag: 'BIOMETRIC');
      // build145（循环审查第 7 轮 P0-2）：这里原来写 `setState(() => _enabled = false)`
      // —— 一次 DB 读失败就把整个应用**解锁**，而本文件 :623 的注释一直自称 fail-closed。
      // 抛出源是真实的：`getWebSearchConfig` 用 `.map(WebSearchConfig.fromMap)` 绕开了
      // `_parseRows`（storage_service.dart:1437），任一行字段变形即整表抛；
      // `getBiometricLockEnabled` 又直接踩在它上面（:1453-1456）没有兜底。
      //
      // 新规则（三档，共同点是不许"读不到 ⇒ 当没开"）：
      // ① 之前已经读到过确定值（开 or 关）→ **维持原状**。一次瞬时读失败既不该
      //    把锁解开（原状 true），也不该给从没开过锁的用户凭空弹一次锁屏（原状 false）。
      // ② 冷启动第一次读就失败（`_enabled` 仍是 null，状态未知）→ 只有**验得出**才关门：
      //    `BiometricService.authenticate` 在设备不可用时直接返回 false
      //    （biometric_service.dart:75-80），无指纹又无锁屏凭据的机器一旦上锁就是
      //    **永久出不去**，那比 fail-open 更糟 —— 所以这里必须是"能验才关"。
      // ③ 无论走哪档，错误都要留在日志里（静默 = 不可排查，build138 口径）。
      // `isAvailable` 自己只兜 PlatformException（:56-63），MissingPluginException
      // 会从它里面穿出来 —— 那时宁可判「验不出」放行，也绝不停在 null 上：
      // `_enabled` 留在 null 就是 build() 的启动画面，那是**永远出不去**的白屏。
      if (!mounted) return;
      var canVerify = false;
      try {
        canVerify = await BiometricService.isAvailable;
      } catch (e2) {
        LoggerService.instance
            .error('Biometric availability probe failed: $e2', tag: 'BIOMETRIC');
      }
      if (!mounted) return;
      setState(() {
        if (wasKnown != null) return; // ① 维持原状
        _enabled = canVerify; // ② 验得出就关着，验不出就放行
        _verified = !canVerify;
      });
      if (wasKnown == null && canVerify) await _verify();
    }
  }

  Future<void> _verify() async {
    // 防重入：BiometricPrompt 弹出/关闭会触发 spurious paused→resumed，
    // 若不拦截会导致 _verify 被叠加调用 → 解锁后立刻又弹一次。
    if (_verifying) return;
    _verifying = true;
    try {
      final authed = await BiometricService.authenticate(
        reason: _isZh ? '请验证身份以解锁应用' : 'Please authenticate to unlock the app',
      );
      LoggerService.instance.app('Biometric verify result: $authed');
      if (mounted) setState(() => _verified = authed);
    } catch (e) {
      LoggerService.instance
          .error('Biometric verify failed: $e', tag: 'BIOMETRIC');
      if (mounted) setState(() => _verified = false);
    } finally {
      // 保留 ~800ms 屏蔽期，吸收指纹框关闭瞬间产生的假 resumed 事件
      await Future.delayed(const Duration(milliseconds: 800));
      if (mounted) _verifying = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _wasPaused = true;
      return;
    }
    // inactive 可能只是小窗、分屏或系统面板，不应在返回时强制验证。
    if (state != AppLifecycleState.resumed || !_wasPaused) return;
    _wasPaused = false;
    // v1.7.30：跳过 App 内原生 Activity 跳转（相机/相册/文档选择器）的 resumed
    if (BiometricService.inAppActivityTransition) {
      BiometricService.endActivityTransition();
      return;
    }
    if (_enabled == true && _verified && !_verifying) {
      if (mounted) setState(() => _verified = false);
      _verify();
    }
  }

  @override
  Widget build(BuildContext context) {
    _isZh = Localizations.localeOf(context).languageCode == 'zh';
    if (_enabled == null) {
      // 状态未确定：启动画面（不渲染任何聊天内容）
      return const _BiometricSplash();
    }
    if (_enabled == true && !_verified) {
      return _BiometricLockScreen(onUnlock: _verify);
    }
    return widget.child ?? const SizedBox.shrink();
  }
}
