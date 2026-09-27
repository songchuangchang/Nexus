import 'dart:async';

import '../utils/bg_forensics.dart';
import '../utils/round_exit.dart';
import 'app_download_service.dart';
import 'live_task_center.dart';
import 'logger_service.dart';

/// build142（灵动岛）：四类任务源 → [LiveTaskCenter] 的**接线层**。
///
/// 为什么单独一层而不是把通知代码写进各个服务：
/// 1. 服务们不该知道通知的存在（下载服务在 build138 之前就没有任何 UI 假设）；
/// 2. 「什么算进行中」这件事必须只有一个人说得上话（教训 #62），散到 5 个调用点
///    必然出现「有的地方上了岛、有的地方没上」；
/// 3. 单测能打到的只有这一层的纯映射部分 —— 混进服务里就连测都没法测。
///
/// 每一段接线都遵循同一形状：**进入时登记、离开时摘除（`finally` 覆盖所有出口）**。
/// build141 那条「反问面板都关了、请求还挂 4.8 秒」就是这个形状没做全 ⇒
/// 这里的每个 `start` 都必须有配对的 `end`，否则常驻通知会永远挂着。
class LiveTaskWiring {
  LiveTaskWiring._();

  static const String prefixDownload = 'dl:';
  static const String prefixVideo = 'video:';
  static const String prefixResearch = 'research:';
  static const String prefixBackup = 'backup:';
  static const String prefixDataPack = 'pack:';
  static const String prefixAskUser = 'ask:';

  /// build161（真机反馈「那个灵动岛他不是一瞬间就出来的，不是发消息之后立刻出来的，
  /// 它是过几秒钟之后才有的」）：发送入口登记那一行时用的文案。
  ///
  /// 为什么不是「正在生成」也不是「准备中 · 上限 N 轮」：写这一行的那一刻，
  /// 探活还没跑、消息还没落库、`maxRounds` 还没算出来 —— 说"正在生成"就是本仓库
  /// 反复被点名的那条假话（`LiveTask.terminalTitle` 那段、build158 的「已完成」同族）。
  /// 「已发送 · 正在准备」说的是真事：用户的消息已经发出去了，App 正在替它做发送前那串活。
  static const String sendPrepareLabel = '已发送 · 正在准备';

  static AppDownloadService? _downloads;
  static void Function()? _downloadsListener;

  /// 取中枢，并顺手把「到点要把底层也停掉」这一半挂上。
  ///
  /// 为什么是"顺手挂"而不是在 `main.dart` / DI 里显式装一次：本批只准动这两个文件，
  /// 而**每一条往岛上登记任务的路都必须经过这一层** —— 挂在这里就等于"只要有接线在
  /// 登记任务，取消入口就一定在"，比放在某个启动点少一个"忘了调"的口子
  /// （`??=` 幂等，测试自己塞一个假回调也不会被这里覆盖掉）。
  static LiveTaskCenter get _center {
    final c = LiveTaskCenter.instance;
    c.onDeadlineExceeded ??= _onDeadlineExceeded;
    return c;
  }

  /// build156（用户「那个更新的灵动岛要给他限时，如果失败了的话，就及时给他收回来」）：
  /// 时限到点时对**底层那件事**能做什么。
  ///
  /// 一条硬口径先写在这里：**接不上就明说接不上，绝不允许伪造一个"已取消"**。
  /// 本仓库反复出现的缺陷形状就是"注释/文案承诺了一个没人实现的动作"
  /// （`LiveTask.done` 那个字段两边都没实现过就是现成例子）。所以这里逐个 kind
  /// 核对过一遍可调用入口：
  ///
  /// · `download`：**build157（#73）起有真入口了**。缺的从来不是能力，是**id 对不上**：
  ///   `AppDownloadService.cancelDownload(taskId)` 吃调用方生成的 taskId，而岛上这一行的
  ///   id 是 `dl:<appName>#<fileName>`（见 [downloadTasksFor]），两边没有映射。
  ///   现在走 `svc.inFlightTaskId`（就是 `_cancelFlags` 那唯一一个在途键，不另造副本）
  ///   ⇒ 到点真的会把那条下载打断（循环下一轮 break、删半成品、走 cancelled 收尾）。
  ///   拿不到唯一键时（并发/漏清理）退回"只收屏幕"并记一行 warn，**不猜一条去停**。
  /// · `backup` / `dataPack`：这两类都跑在 [track] 那个 `await body()` 里面，
  ///   WebDav / 备份服务本身没有取消入口（全仓没有 `cancelBackup` 这类东西）。
  ///   真返回值回来时 `track` 的 `finally` 会**再 finish 一次**，把这一行换成真实结果 ——
  ///   时限那条"无响应"只是先替用户把屏幕收干净。
  /// · `video`：状态由 `StorageService` 写库后递进来（[onVideoTask]），轮询循环在
  ///   视频生成那个屏幕里，接线层手上没有句柄。
  /// · `research`：停止位是 chat screen 的 state（`_reactLoopStopRequested`），
  ///   同理拿不到。
  /// · `askUser`：**根本不会走到这里**（[deadlineFor] 返回 null，它不限时）。
  ///
  /// 于是除下载外其余三类的实际效果仍是：**屏幕上不再挂着"正在…"，底层该跑的还在跑**。
  /// 这两件事分开说清楚，正是这条日志存在的理由（也是把取消入口接下来时唯一要改的地方）。
  /// 真回调本身（不是替身）：给测试核对"每个 kind 走哪条路"这个口径用。
  static Future<void> Function(LiveTask) get deadlineCancelHook =>
      _onDeadlineExceeded;

  static Future<void> _onDeadlineExceeded(LiveTask task) async {
    if (task.kind == LiveTaskKind.download) {
      final svc = _downloads;
      final id = svc?.inFlightTaskId;
      if (svc != null && id != null) {
        // 与用户手点「取消」同一条路径：置 flag，循环下一轮中断并清理半成品。
        svc.cancelDownload(id);
        LoggerService.instance.warn(
          '到期收回：download 已请求取消底层下载 taskId=$id id=${task.id}',
          tag: 'Live',
        );
        return;
      }
      LoggerService.instance.warn(
        '到期收回：download 拿不到唯一在途 taskId（并发或未清理），'
        '只收通知不猜着停 id=${task.id}',
        tag: 'Live',
      );
      return;
    }
    if (task.kind == LiveTaskKind.backup || task.kind == LiveTaskKind.dataPack) {
      LoggerService.instance.warn(
        '到期收回：${task.kind.name} 没有取消入口，底层任务仍在运行'
        '（它真返回时会把这一行换成真实结果）id=${task.id}',
        tag: 'Live',
      );
      return;
    }
    LoggerService.instance.warn(
      '到期收回：${task.kind.name} 没有取消入口，底层任务仍在运行 id=${task.id}',
      tag: 'Live',
    );
  }

  /// 已经弹过一次「完成/失败」的**任务键**（`dl:` / `video:` 前缀 + id + 终态）
  /// —— 防止每次状态回调都重发一条通知。
  ///
  /// 视频这一类尤其必要：轮询每 10 秒把同一行 `completed` **重复写库**，
  /// 没有这层去重就会每 10 秒弹一次「视频已生成」。
  static final Set<String> _announced = <String>{};

  static bool _announceOnce(String key) {
    if (_announced.contains(key)) return false;
    _announced.add(key);
    if (_announced.length > 400) _announced.clear(); // 只防无界增长，不做 LRU
    return true;
  }

  /// 在 DI 层（`providers.dart`）创建下载服务时调用一次。
  static void bindAppDownloads(AppDownloadService svc) {
    // 重复 bind（widget test 里每次建 provider 都会走一遍）必须先把旧实例的监听摘掉，
    // 否则旧服务每 notify 一次就投影一遍已经不存在的那份任务。
    if (_downloads != null && !identical(_downloads, svc)) unbindAppDownloads();
    _downloads = svc;
    _downloadsListener ??= () => unawaited(projectDownloads());
    svc.addListener(_downloadsListener!);
  }

  static void unbindAppDownloads() {
    final svc = _downloads;
    final l = _downloadsListener;
    if (svc != null && l != null) svc.removeListener(l);
    _downloads = null;
  }

  /// 下载投影（纯映射部分抽成 [downloadTasksFor] 以便单测）。
  /// 在途下载只有一个来源：`svc.currentTask`。
  ///
  /// 为什么不能扫 `history`（本轮自审抓到的 P1，主打场景差点整个没实现）：
  /// `history` 只在**成功收尾**时 `insert(0, task)`（`app_download_service.dart:1313/1347`），
  /// 在途与失败的任务都不在里面 ⇒ 拿 `!isTerminal` 去过滤 history 会得到**恒空**，
  /// 「正在下载 xx%」这条通知永远不出现，而失败提醒那段代码是死代码。
  static List<LiveTask> downloadTasksFor(AppDownloadService svc) {
    final out = <LiveTask>[];
    for (final t in [if (svc.currentTask != null) svc.currentTask!]) {
      if (t.isTerminal) continue;
      final known = t.totalBytes > 0;
      out.add(LiveTask(
        id: '$prefixDownload${t.appName}#${t.fileName}',
        kind: LiveTaskKind.download,
        title: '正在下载 ${t.appName}',
        progress: known ? t.progress.clamp(0.0, 1.0) : null,
        indeterminate: !known,
        route: kLiveRouteChat,
        detail: known
            ? '${_mb(t.receivedBytes)} / ${_mb(t.totalBytes)} · ${t.fileName}'
            : t.fileName,
      ));
    }
    return out;
  }

  static Future<void> projectDownloads() async {
    final svc = _downloads;
    if (svc == null) return;
    final live = downloadTasksFor(svc);
    await _center.syncGroup(prefixDownload, live);
    // 完成 / 失败各弹一次，且只在「刚从在途变成终态」时弹（Announced 集合去重）。
    for (final t in svc.history) {
      if (!t.isTerminal) continue;
      if (!_announceOnce('dl:${t.appName}#${t.fileName}')) continue;
      if (t.error != null) {
        // 失败必须说原因：与 build138「搜索故障不许报成未找到结果」同族口径
        await _center.alert(
          title: '下载失败：${t.appName}',
          body: t.error!,
          route: kLiveRouteChat,
        );
      } else {
        await _center.alert(
          title: '${t.appName} 已下载完成',
          body: '${t.fileName} · 点按安装',
          route: kLiveRouteChat,
        );
      }
    }
  }

  /// 视频任务：由 `StorageService` 在写库后直接递原语过来（**不查库、不订阅全量通知**——
  /// StorageService 的 notifyListeners 覆盖所有表，挂在上面会在每次存消息时白扫一遍库）。
  static Future<void> onVideoTask({
    required String id,
    required String state,
    required String label,
    bool isTerminal = true,
  }) async {
    final center = _center;
    if (state == 'completed' || state == 'failed') {
      await center.remove('$prefixVideo$id');
      // 去重键带终态：同一任务从 completed 变 failed（用户重试）还要再报一次
      if (isTerminal && _announceOnce('video:$id:$state')) {
        await center.alert(
          title: state == 'completed' ? '视频已生成' : '视频生成失败',
          body: label,
          route: kLiveRouteVideo,
        );
      }
      return;
    }
    await center.upsert(LiveTask(
      id: '$prefixVideo$id',
      kind: LiveTaskKind.video,
      title: '视频生成中',
      indeterminate: true,
      route: kLiveRouteVideo,
      detail: label,
    ));
  }

  /// 深度研究 / ReAct 长轮。[roundLabel] 直接进摘要行，让用户知道「跑到第几轮了」。
  ///
  /// build148（真机反馈①「只有思考过程才有流体云，表前面没有」的另一半）：
  /// 标题原来写死「深度研究中」，而**默认档任何一轮普通聊天都会走 ReAct**
  /// ⇒ 普通对话在通知栏被标成"深度研究中"，用户看不出这一轮到底在干什么。
  /// 现在按调用方给的 [deep] 分流：`深度研究中` / `AI 思考中`。
  /// 真·深度研究走编排器那条路以前**完全不上岛**（编排器里没有 LiveTaskWiring），
  /// 那条由 `chat_screen_orchestrator.dart` 自己接同样的 start/update/end。
  ///
  /// build152（真机反馈「一直是准备中，下面一条线有什么用」）：[stages] 是这一轮
  /// 走过的**阶段**（编排：路由 / 取证 / 合成）。这类任务没有字节级进度，
  /// 一根不确定条就是它全部能说的东西 —— 分段条才是 ProgressStyle 真正能表达的
  /// 「第几步完了」。刻意**只在有人填的时候才有**：下载/备份没有阶段概念，
  /// 空列表在原生侧等于不调 `setProgressSegments`，形状与 build151 完全一致。
  ///
  /// build161（真机反馈「那个灵动岛他不是一瞬间就出来的…过几秒钟之后才有的」）：
  /// **重复用同一个 [sessionId] 调这里是安全的**，登记点提前到发送入口之后就靠这一条：
  /// · 落到 [LiveTaskCenter.upsert] 是 `_tasks[id] = task` —— 同一 id 只有一行，
  ///   不会多出第二行；
  /// · `startedAt` 由 `LiveTaskCenter._trackDeadlines` 记，那里明写「同 id 再次
  ///   upsert 不重置 startedAt」⇒ build156 那条时限仍从**第一次**登记算起，
  ///   中途再 start 一次不会给这一行续命；
  /// · 变的只有标题 / detail / stages，正是要的效果。
  /// 所以循环与编排器里那两处 `onResearchStart`（`onResearchUpdate` 本来就是它的
  /// 别名）**不必换成别的入口**：它们只是把「已发送 · 正在准备」换成
  /// 「准备中 · 上限 N 轮」/「编排 · 路由 → 专家 → 合成」，同一行、时限不动。
  static Future<void> onResearchStart(String sessionId, String roundLabel,
      {bool deep = false, List<LiveStage> stages = const []}) =>
      _center.upsert(LiveTask(
        id: '$prefixResearch$sessionId',
        kind: LiveTaskKind.research,
        title: deep ? '深度研究中' : 'AI 思考中',
        indeterminate: true,
        route: kLiveRouteChat,
        detail: roundLabel,
        stages: stages,
      ));

  static Future<void> onResearchUpdate(String sessionId, String roundLabel,
          {bool deep = false, List<LiveStage> stages = const []}) =>
      onResearchStart(sessionId, roundLabel, deep: deep, stages: stages);

  /// build165（任务 #86）：**掉线那一刻**问一次原生心跳，交回一行读数。
  ///
  /// 这一行是用来分清哪三种可能的（三种修法互斥，现有读数分不开）：
  /// ① 进程被冻结/挂起、② 被系统按内存上限杀掉、③ 上游或网络把连接关了。
  /// 掉线这这一刻能直接拿到的是「当前 ticks + 这一秒还在不在跳」：
  /// 在跳 ⇒ 身体是好的（③ 那一侧）；没在跳/读不到 ⇒ 交给回前台那一行
  /// （`[BgForensics]`）拿两次的**差**去判①，②由退出记录那一半回答。
  ///
  /// 为什么走接线层而不是让 screen 直接 import 中枢：`chat_screen.dart` 从来没有
  /// `live_task_center.dart` 这条 import（岛的一切都从这里过），为一行日志新开依赖边
  /// 不值得。**文案仍只住 `bg_forensics.dart` 那一份**（教训 #62），这里不做第二次判定。
  static Future<String> heartbeatLineAtDrop({required String endKind}) async {
    final hb = await _center.heartbeatSnapshot('drop');
    return bgHeartbeatDropLine(hb, endKind: endKind);
  }

  /// 一轮结束：先换成终态那一行停 [LiveTaskCenter.terminalHold] 秒再撤。
  ///
  /// build150（真机反馈「完成之后是没退了但也没显示完成√」）：**成功也走停留**。
  /// 原来只有带 [error] 那一支会 `finish`，成功直接 `remove` —— 于是 148 反馈④
  /// 要的「完成✅」只在失败时兑现了，成功那一半仍然"跑着跑着没了"，用户在岛/通知栏
  /// 里读不到"这轮结束了、结果在 App 里"。现在两条称：
  ///  · 成功 → 「AI 思考 · 已完成」/「深度研究 · 已完成」+ 满格条；
  ///  · 失败 → 「… · 失败」+ 原因一行（进度条沿用最后一次真实进度，不假报 0%）；
  ///  · **build168 ① [waitingUser]** → 「… · 等你回答」+ 不挂 `√`、不挂 `×`：
  ///    这一轮结束在「模型问了一句」上，写已完成是假消息、写失败是假故障。
  /// [quiet] 仍是例外：自动/后台例行轮次连进行中都不该抢，结束也不留条。
  static Future<void> onResearchEnd(String sessionId,
      {String? error,
      bool deep = false,
      bool quiet = false,
      bool waitingUser = false,
      bool isZh = true,
      String okBody = '回答已生成，回到 App 可看结论'}) async {
    final center = _center;
    final id = '$prefixResearch$sessionId';
    if (quiet) {
      await center.remove(id);
      return;
    }
    // 两条都**不管那一行还在不在都要写**：
    // 循环内抛错时 finally 会先 `remove`（那是 build142 配的收尾），
    // 如果这里因为"行已经不在了"就什么都不做，用户看到的仍然是"跑着跑着没了"——
    // 而那正是本次反馈要修的东西。行不在就用同一套 id/kind/route 造一条终态行。
    final existing = center.current.where((t) => t.id == id).firstOrNull;
    final ok = error == null;
    await center.finish(LiveTask(
      id: id,
      kind: existing?.kind ?? LiveTaskKind.research,
      title: LiveTask.terminalTitle(deep ? '深度研究' : 'AI 思考',
          ok: ok, waitingUser: waitingUser),
      detail: waitingUser
          ? askUserWaitingIslandBody(isZh: isZh)
          : (ok ? okBody : oneLine(error)),
      route: kLiveRouteChat,
      // 终态不许留一根还在转的不确定条（那是「已完成」下面的自相矛盾，
      // 也正是 148 反馈③「下面一条线有什么用」的余形）：成功给满格，
      // 失败停在最后一次真实进度（没有就从 0 起，但不画"还在跑"）。
      // build168 ①：等人那一档**跟失败同一支**——它没跑完，画满格就是替它宣告结束。
      progress: (ok && !waitingUser)
          ? 1.0
          : (existing?.progress ?? 0.0),
      indeterminate: false,
      done: true,
      ok: ok,
      waitingUser: waitingUser,
    ));
  }

  /// #97 ②：这一次投影**会不会根本不上屏**（岛与提醒都算）。
  ///
  /// 为什么暴露给屏幕那边：总闸关着（默认档）时 `alert`/`finish` 都不会有任何一行
  /// 出现在通知栏，而"这一轮结束在模型问的那一句上"这件事必须让人看见 ——
  /// 于是气泡要自己补那一格。让调用方去猜总闸状态 = 同一道判据住两个文件
  /// （build167 立的那道闸只住 `background_run_switch.dart` 与 center 这里）。
  /// 它**不是**新的用户开关，读的就是 center 那一条 [LiveTaskCenter.alertBlocked]。
  static bool get projectionBlocked => _center.alertBlocked;

  /// 通知里的 detail 只有一行地方：换行压成空格、超长截断（原因本身要留着）。
  ///
  /// build149 起公开给调用方用（编排器那条 `onStep` 也要走同一个截断口径）：
  /// detail 的长度上限是**这个模块的契约**，谁写 detail 谁自己裁 = 迟早有人写进
  /// 一段 500 字的检索词，岛里那行被系统截成看不懂的半句。
  static String oneLine(String s) {
    final flat = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= 120 ? flat : '${flat.substring(0, 120)}…';
  }

  /// 编排的三个段（与 `agent_orchestrator.dart` 里那三个 `phase:` 一一对应）。
  ///
  /// 名单写死在这里是有意的：岛上那三段是**给人读的中文**，不该由步骤内容自己带
  /// （步骤文案是讲给思考面板看的，长短不一、还有英文档）。
  static const List<String> orchStageLabels = ['路由', '取证', '合成'];

  /// 步骤的 `phase` → 第几段。编排器还会发 `orchestrate` 这类不属于三段的步骤，
  /// 落不到名单上就是"没推进"（返回 null，不猜）。
  static const Map<String, int> orchPhaseIndex = {
    'route': 0,
    'expert': 1,
    'synthesize': 2,
  };

  /// 「出现过哪些阶段」→ 三段各自完成与否（纯函数，好测）。
  ///
  /// 为什么取**历史最远**而不是"当前这一步属于第几段"：编排器在 `target=synthesis`
  /// 却本轮没资料可综合时，会**补发一条 route 步骤**改道去检索
  /// （`agent_orchestrator.dart:366`）。按当前步骤判的话，岛上的段会
  /// 从「合成」退回「路由」—— 进度条倒着走比压根没有进度条更糟
  /// （与 [LiveTask.terminalTitle] 那段「不许把进行中转成已完成」同一条口径）。
  static List<LiveStage> orchStagesFromPhase(Iterable<String> phases) {
    var reached = -1;
    for (final p in phases) {
      final i = orchPhaseIndex[p];
      if (i != null && i > reached) reached = i;
    }
    return [
      for (var i = 0; i < orchStageLabels.length; i++)
        LiveStage(orchStageLabels[i], done: i <= reached),
    ];
  }

  /// build153（真机反馈②「你确定按了 oppo 的布局了吗？」的一半）：ReAct 那一类轮次
  /// 任务**从来没有过 stages** —— 分段条只在编排那一条路上出现过，而默认档几乎所有
  /// 普通对话走的都是 ReAct（`chat_screen_react.dart`）。于是最常见的路径在岛上仍然
  /// 是一根不动的不确定条，与 build152 修的那个形状一模一样（148→151→152 三次同型：
  /// 只修了看得到的那一条路，另一条路没人问 ⇒ 教训「能力没进真正执行的那条路径 = 不存在」）。
  ///
  /// 阶段源就用循环**自己的轮次**：`round` 与 `maxRounds` 都在调用点现场，
  /// 不在这里另存一个计数器（#62：两份真源迟早各算一套）。
  /// 段数超过 [kLiveStageSegmentCap] 由合并规则处理（前 4 轮各一段 + 余下合一段，
  /// 合段长度 = 余下轮数 ⇒ 视觉长度仍按轮数成比例），且**合段全完成才算完成** ——
  /// 宁可少报，也不虚报。
  /// 任何输入都不抛：`totalRounds < 2`（单轮循环没有可分的阶段）返回空，
  /// `doneRounds` 越界一律夹到边界；空列表在原生侧等于不调 `setProgressSegments`。
  static List<LiveStage> roundStages({
    required int doneRounds,
    required int totalRounds,
  }) {
    if (totalRounds < 2) return const [];
    final done = doneRounds.clamp(0, totalRounds);
    return [
      for (var i = 0; i < totalRounds; i++) LiveStage('第 ${i + 1} 轮', done: i < done),
    ];
  }

  /// 备份 / 恢复 / 数据包：没有字节级进度，一律不确定态（**不许画假百分比**）。
  static Future<void> onBackupStart(String id, String title) =>
      _center.upsert(LiveTask(
        id: '$prefixBackup$id',
        kind: LiveTaskKind.backup,
        title: title,
        indeterminate: true,
        route: kLiveRouteBackup,
      ));

  static Future<void> onBackupEnd(String id, String title, {String? error}) async {
    await _center.remove('$prefixBackup$id');
    await _center.alert(
      title: error == null ? '$title 完成' : '$title 失败',
      body: error ?? '数据已同步到你的网盘',
      route: kLiveRouteBackup,
    );
  }

  static Future<void> onDataPackStart(String id) =>
      _center.upsert(LiveTask(
        id: '$prefixDataPack$id',
        kind: LiveTaskKind.dataPack,
        title: '正在更新资源包',
        indeterminate: true,
        route: kLiveRouteDataPacks,
      ));

  static Future<void> onDataPackEnd(String id, {String? error}) async {
    await _center.remove('$prefixDataPack$id');
    await _center.alert(
      title: error == null ? '资源包已更新' : '资源包更新失败',
      body: error ?? '新的模板、提示词与目录已生效',
      route: kLiveRouteDataPacks,
    );
  }

  /// 通用「有始有终」包装：**改名 + 包一层**，而不是在原函数里到处补 `remove()`。
  ///
  /// 理由：这些服务函数各有 3–4 个 `return`（早退、失败、成功），在函数体里补收尾
  /// 必然漏一条 —— build141 反馈④「同一个动作的两条分支，一条补了刷新、另一条没补」
  /// 就是这个形状。包一层则无论走哪条出口，`finally` 都执行。
  ///
  /// [title] 是进行中的说法（`正在打包备份数据`），完成/失败通知由它派生。
  static Future<T> track<T>({
    required String id,
    required String title,
    required LiveTaskKind kind,
    String route = kLiveRouteBackup,
    String okBody = '已完成',
    bool announceOnSuccess = true,
    bool Function(T result)? okCheck,
    required Future<T> Function() body,
  }) async {
    final center = _center;
    final lid = '${kind.name}:$id';
    // build153（用户「授权码那条不做，兼容按 OPPO 和谷歌来」→ 补 Google 实时活动规范的
    // 第一条硬条件）：**常驻那一行只给"由用户发起"的事**。
    // 官方对 Live Updates 的适用口径是"持续进行、由用户发起、有时效"，并且明写滥用后果是
    // 用户会撤掉本应用的发布权限 —— 而夜里那份自动备份恰好三条里只满足两条。
    // 原来 `withQuietSuccess` 只压高打扰提醒，**常驻那条照上** ⇒ 用户没碰手机的时候
    // 状态栏自己长出一条"正在上传到网盘"，一天一次、每天如此（`maybeWebdavAutoSync`
    // 的 24h 节流），这正是规范里点名的"噪音"形状。
    // 于是判据落到这里：静默作用域里的任务**根本不上常驻行**；
    // 失败照旧弹提醒（下面那个 `!ok`，一条都不让步 —— 降噪砍掉的只该是好消息）。
    // 手动点的那一下走的是另一条调用链、看不见这个 zone 值（build145 改这条的理由），
    // 所以"我自己按了备份却什么都没有"不会发生。
    if (_quietSuccess) {
      // 正文**不带** `[Live]` 前缀：tag 已经打的是 Live，再加一次导出里就是
      // `[Live] [Live] …`（`test/build142_live_task_test.dart` 里那条锚点防的就是这个）。
      LoggerService.instance
          .debug('静默作用域：$lid 不上常驻行（自动/例行任务不占状态栏）',
              tag: 'Live');
    } else {
      await center.upsert(LiveTask(
        id: lid,
        kind: kind,
        title: title,
        indeterminate: true,
        route: route,
      ));
    }
    String? err;
    late final T result;
    var completed = false;
    try {
      result = await body();
      completed = true;
      // 有些服务**不抛异常**来表达失败：`WebDavService.download` 返回 null、
      // `uploadWithRetention` 返回 false。不判返回值就会把失败弹成「已完成」——
      // 与 build138「静默 = 不可排查」同族，而且更坏：那是假完成。
      if (okCheck != null && !okCheck(result)) {
        err = '上游未确认成功（返回${result == null ? '空值' : '失败'}）';
      }
      return result;
    } catch (e) {
      err = '$e';
      rethrow;
    } finally {
      final ok = err == null;
      // build148（真机反馈④「完成✅、报错X，不要直接消失」）：结束不再直接撤条，
      // 先换成「· 已完成 / · 失败」那一行停 `LiveTaskCenter.terminalHold` 秒再撤。
      // 只有**本来上了岛**的任务才停留（没这一行时凭空冒出一条是噪音）。
      // 并发同名（手动同步撞上自动同步）时先结束的那个会把还在跑的那条摘掉：
      // 表现为「通知少一条」，不是「通知挂着不走」—— 宁可少报也不虚报。
      if (center.current.any((t) => t.id == lid)) {
        await center.finish(LiveTask(
          id: lid,
          kind: kind,
          title: LiveTask.terminalTitle(title, ok: ok),
          detail: err == null ? okBody : oneLine(err),
          route: route,
          // build150：与 [onResearchEnd] 同一口径 —— 终态不留还在转的不确定条。
          progress: ok ? 1.0 : 0.0,
          indeterminate: false,
          done: true,
          ok: ok,
        ));
      } else {
        await center.remove(lid);
      }
      // 成功要不要弹由调用方决定；**失败永远弹** ——
      // 「静默 = 不可排查」不因降噪让步（降噪砍掉的只该是好消息）。
      // 停留那一行是给"下拉看通知栏"的人，heads-up 是给"没在看手机"的人，
      // 两者不互相替代（只留其一就会：要么错过，要么下拉时什么都没有）。
      // 降噪**只作用于好消息**：自动同步在夜里失败，用户必须知道。
      // （上一版把整个 alert 包进 `_quietSuccess`，用例立刻抓到「失败也不弹」——
      //  这正是我自己写注释里承诺过不许发生的那件事。）
      if (!ok || (completed && announceOnSuccess && !_quietSuccess)) {
        await center.alert(
          title: ok ? '$title 完成' : '$title 失败',
          body: err ?? okBody,
          route: route,
        );
      }
    }
  }

  /// 「静默作用域」：自动同步这类**用户没动手**的例行任务用它降噪。
  ///
  /// build145（第 9 轮 P2-6）：从**进程级布尔**改成 **zone 局部值**。
  /// 进程级的那个是全局开关：夜里自动同步正在跑的时候，用户手动点一次「导出备份」，
  /// 他这次动作也被判定为"静默" ⇒ **他自己按的那一下没有完成提醒**（该报的没报）；
  /// 反过来手动那次先结束、`finally` 把开关拨回 false，自动同步随后结束就照常弹一条
  /// （不该报的又报了）。两头都错，而且错得看时序。
  /// zone 局部值跟着**调用链**走：只有起在 [withQuietSuccess] 里面的那些 await 看得见它，
  /// 同一时刻别的链一律按"用户动手"处理 ⇒ 两头各判各的。
  static const Object _quietKey = #liveTaskQuietSuccess;

  /// 当前调用链是否处于「压掉成功提醒」的作用域内。
  static bool get _quietSuccess => Zone.current[_quietKey] == true;

  /// 在 [body] 执行期间压掉成功提醒（进行中投影照旧、失败照旧说原因）。
  static Future<T> withQuietSuccess<T>(Future<T> Function() body) async =>
      runZoned<Future<T>>(body,
          zoneValues: <Object, Object>{_quietKey: true});

  /// AI 反问等待回答：**只发提醒，不起服务**（它是「等你回来」，不是「替你跑」）。
  ///
  /// build145（第 9 轮 P2-5）：任务 id 从固定的 `ask:2001` 改成**按会话**。
  /// 两个会话可以同时各自卡在反问上（A 在深度研究里问、B 也在问），固定 id 意味着
  /// 第二个 upsert 直接**覆盖**第一个，而且谁先答完谁就把对方那条
  /// 「AI 想问你一个问题」的常驻提醒撤掉 —— 表现成"B 没人问却少了条提醒"。
  ///
  /// 系统通知（[askUserAlertId]）**仍然只有一条**，这是有意的：它是"有东西等你答"的
  /// 信号，不是每个会话一格；但撤它的条件改成「askUser 任务集合空了」，
  /// 而不是"某一次结束"。真源在集合上，不在某一次调用上。
  static const int askUserAlertId = kAskUserAlertId;

  static String askUserTaskId(String conversationId) =>
      '$prefixAskUser${conversationId.isEmpty ? 'unknown' : conversationId}';

  static Future<void> onAskUserStart(String conversationId, String question) async {
    await _center.upsert(LiveTask(
      id: askUserTaskId(conversationId),
      kind: LiveTaskKind.askUser,
      title: 'AI 在等你回答',
      indeterminate: true,
      route: kLiveRouteChat,
      detail: question,
    ));
    await _center.alert(
      id: askUserAlertId,
      title: 'AI 想问你一个问题',
      body: question,
      route: kLiveRouteChat,
      ongoing: true,
    );
  }

  static Future<void> onAskUserEnd(String conversationId) async {
    final center = _center;
    await center.remove(askUserTaskId(conversationId));
    // 只有**没有别的会话也在等**时才撤这条系统提醒（见上面「撤它的条件」）。
    if (!center.hasAskUserTasks) {
      await center.cancelAlert(askUserAlertId);
    }
  }

  static String _mb(int bytes) {
    if (bytes <= 0) return '0 MB';
    final mb = bytes / (1024 * 1024);
    return mb >= 100 ? '${mb.round()} MB' : '${mb.toStringAsFixed(1)} MB';
  }
}

/// build161（真机反馈「那个灵动岛他不是一瞬间就出来的…它是过几秒钟之后才有的」）：
/// 「发送这一轮」在岛上那一行的**归属把手**。
///
/// 为什么要有这个东西（而不是在 `_sendMessage` 里多写几行 `onResearchEnd`）：
/// 登记点原来挂在进 ReAct 循环之前，而那里前面压着一整串 await（探活、改标题、
/// 落库、插件枚举、MCP 注册、SharedPreferences、记忆块、RAG 向量化）——
/// 真机量到的是 6 秒与 19 秒，用户读到的就是"过几秒钟才有岛"。
/// 把登记挪到发送入口、任何 await 之前之后，**从登记到有人负责收尾之间多出了一批出口**：
/// 探活弹框里点「取消」、无 AI 配置、页面已卸载、DB 写入抛错、装配阶段抛异常。
/// 逐个出口补 `end` 正是这个仓库反复犯的错（漏一条 = 岛上一行「进行中」永驻，
/// 而 build156 那条 20 分钟时限对"刚发一条消息"来说等于永驻）。
/// 于是把规矩收成一条：**谁先认领（[claim]），这一行归谁收尾**；这一轮跑完还没人
/// 认领，由发送入口那层 `finally` 调 [releaseIfUnowned] 安静撤掉。
/// 认领与撤除都按 [sessionId]（= 本轮用户消息 id）认，新一轮的行绝不被旧一轮动到。
class SendIslandRow {
  SendIslandRow(this.sessionId, {required this.deep});

  /// 这一轮的用户消息 id —— 与 [LiveTaskWiring.onResearchStart] 拼出的行 id 同源。
  final String sessionId;

  /// 深度研究 / 普通思考：决定标题是「深度研究中」还是「AI 思考中」。
  /// 登记那一刻就读得到（会话自己的 `reasoningEffort`，同步且无 await），
  /// 所以不必等循环算完 `maxRounds` 才上岛 —— 那正是本次要挪走的那段延迟。
  final bool deep;

  bool _owned = false;

  /// 是否已有人认领（true ⇒ [releaseIfUnowned] 不许再动这一行）。
  bool get owned => _owned;

  /// 登记：**必须排在任何 await 之前调用**，这是 build161 全部的意义。
  ///
  /// 不 `await` 它（调用点是 `unawaited(...)`，与其余上岛点同形状）：
  /// `upsert` 在进 `_apply` 后**同步**就把行写进真源，第一次 await 之前
  /// 屏幕上已经有这一行了；把它 await 上反而让"发下一条"要等通知层回执。
  Future<void> register() => LiveTaskWiring.onResearchStart(
      sessionId, LiveTaskWiring.sendPrepareLabel,
      deep: deep);

  /// 认领这一行的收尾：调用方随后自己写终态（`onResearchEnd`）。可重复调，幂等。
  void claim() => _owned = true;

  /// 兜底：没人认领过才把这一行**安静撤掉**。
  ///
  /// 走 `quiet`（[onResearchEnd] 里是直接 remove）而不是写终态：这些出口的共同点是
  /// **这一轮什么都没发生**（没开始生成，也没失败）——写「· 已完成」是假消息，
  /// 写「· 失败」是吓人的假故障，与 build150/155 给"用户按了停止"定的那条口径同形。
  Future<void> releaseIfUnowned() {
    if (_owned) return Future<void>.value();
    _owned = true;
    return LiveTaskWiring.onResearchEnd(sessionId, deep: deep, quiet: true);
  }
}

