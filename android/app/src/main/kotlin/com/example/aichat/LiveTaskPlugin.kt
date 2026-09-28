package com.example.aichat

import android.app.Activity
import android.app.ActivityManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * build142（灵动岛）：Dart ↔ 原生 的唯一通道。
 *
 * 语义：**快照重绘**。Dart 的 `LiveTaskCenter` 是唯一真源，每次变化把整份
 * 「进行中任务」快照推过来，原生侧不记历史、不做节流（节流也在 Dart 做）
 * —— 这样两端不会各持一半状态（教训 #62），也就不会出现「任务早就结束了、
 * 通知还挂着」这类最难查的缺陷。
 *
 * 冷启动点通知时 Dart 还没就绪，所以路由载荷与分享通道用同一套缓冲打法：
 * 先存，等 Dart 调 `getInitialRoute` 取走；热启动则直接 invokeMethod 推过去。
 */
class LiveTaskPlugin(
    private val activityProvider: () -> Activity?,
    private val appContext: () -> Context,
) {
    companion object {
        const val CHANNEL = "nexus/live_task"
        private const val REQ_POST_NOTIFICATIONS = 9001

        // build165（任务 #88）：两个跳转目标。**两个不同的 Settings action，不合成一个** ——
        // 应用信息页里那个「允许后台活动」是厂商的冻结开关，
        // 电池优化列表页管的是 AOSP 的 Doze 那一层，用户照着说明找错页就等于没找。
        // 字面量与 Dart 侧 `lib/utils/background_run_guide.dart` 的常量必须逐字相同
        // （测试 test/build165_bg_guide_test.dart 比对这两处）。
        private const val TARGET_APP_DETAILS = "app_details"
        private const val TARGET_BATTERY_OPT = "ignore_battery_optimizations"

        /// 确认「Intent 已经发出去」的状态字（不是 bool：通道异常时 Dart 收到 null，
        /// null 绝不能被读成成功）。
        private const val STATUS_OPENED = "opened"

        // build165（任务 #86）：两个**只加读数**的通道方法，字面量写在下面的分发处
        // （`"heartbeatDiag" ->` / `"exitReasonsDiag" ->`，与本文件其它方法同一形状）。
        // Dart 侧那份住在 `lib/utils/bg_forensics.dart`（kHeartbeatMethod / kExitReasonsMethod），
        // 两边必须逐字相同 —— `test/build165_heartbeat_test.dart` 里钉着字面量比对
        // （build165 #88 那两个 target 常量的同一配方）。

        /**
         * 交回最近几条进程退出记录。取 5 条而不是 1 条：用户一早上会连着开关好几次 App，
         * 只回最近一条就会把"这一次为什么没心跳"和"上一次为什么被杀"错配成同一件事。
         * 上限也不许放大 —— description 最长 255 字，每条还带 trace 之外的几个数值，
         * 这一行是要进导出日志的。
         */
        private const val MAX_EXIT_RECORDS = 5

        /** description 截断长度（原生侧就截，不把 255 字的长句整条塞进 Dart 日志）。 */
        private const val MAX_DESCRIPTION_CHARS = 200
    }

    private var channel: MethodChannel? = null
    private var pendingRoute: String? = null
    private var flutterReady = false
    private var permissionResult: MethodChannel.Result? = null

    fun configure(engine: FlutterEngine) {
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel = ch
        ch.setMethodCallHandler { call, result -> handle(call, result) }
    }

    /** Activity 收到的 Intent 里若带「点通知回 App」的路由，缓冲或直接推给 Dart。 */
    fun handleOpenIntent(intent: Intent?, warm: Boolean) {
        if (intent == null) return
        if (intent.action != LiveNotification.ACTION_OPEN) return
        val route = intent.getStringExtra(LiveNotification.EXTRA_ROUTE) ?: ""
        if (warm && flutterReady) {
            channel?.invokeMethod("onOpenTask", mapOf("route" to route))
        } else {
            pendingRoute = route
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        val ctx = try {
            appContext()
        } catch (t: Throwable) {
            result.error("no_context", t.message, null); return
        }
        try {
            when (call.method) {
                "initialize" -> {
                    LiveNotification.ensureChannels(ctx)
                    flutterReady = true
                    result.success(
                        mapOf(
                            "notificationsEnabled" to LiveNotification.notificationsEnabled(ctx),
                            "permissionGranted" to hasPostPermission(ctx),
                            "sdkInt" to Build.VERSION.SDK_INT,
                            // 腿 B 能不能生效完全取决于设备是不是 Android 16 —— 这个数
                            // 也顺带回答「为什么我这没有岛」，出问题时日志里能直接看出来。
                            "liveUpdatesSupported" to (Build.VERSION.SDK_INT >= 36),
                        )
                    )
                }

                "getInitialRoute" -> {
                    val r = pendingRoute
                    pendingRoute = null
                    result.success(r)
                }

                "syncTasks" -> {
                    val snapshot = call.argument<String>("snapshot") ?: "{}"
                    val specialUse = call.argument<Boolean>("specialUse") ?: false
                    LiveTaskService.sync(ctx, snapshot, specialUse)
                    // 带回渲染诊断，让 Dart 那边能把它写进 App 日志（原生 Log 进不了导出）。
                    // build155：后半截是**系统侧**的读数（那条常驻通知在不在、有没有被提升）。
                    // 只带 `lastDiag` 的那一版永远只能回答"我们写得合不合条件"，
                    // 而真机反馈问的是"为什么没有岛" —— 两个问题不是一回事。
                    result.success(
                        LiveNotification.lastDiag + " | " + LiveNotification.postedDiag(ctx)
                    )
                }

                "liveDiag" -> {
                    // 只读诊断：不贴通知、不起服务（切后台那一刻起服务正好会被后台限制拒掉，
                    // 白抛一次异常还把日志弄成误导）。Dart 侧在 `paused` 时调它，
                    // 拿到的就是"用户离开 App 的这一瞬，系统手里那条岛长成什么样"。
                    result.success(
                        LiveNotification.lastDiag + " | " + LiveNotification.postedDiag(ctx)
                    )
                }

                "heartbeatDiag" -> {
                    // build165（任务 #86）①：**每秒一跳**的那个进程内心跳，读的是静态量。
                    // 用途是把三种可能分开（三选一，修法互斥）：
                    //  · ticks 跟着墙钟涨、流却死了 ⇒ 身体好的，问题在网络/上游那一侧；
                    //  · 墙钟走了 46s 而 ticks 只涨了几次 ⇒ 进程那段时间被挂起/冻结；
                    //  · 一个 tick 都没有（everStarted=false）⇒ 连前台服务都没起，先回头看保活。
                    // 这里**不判定、只交数**：判定的口径只住 Dart 那一份纯函数（教训 #62），
                    // 两边各判一次就会出现两种说法。
                    result.success(LiveTaskService.heartbeatSnapshot())
                }

                "exitReasonsDiag" -> {
                    // build165（任务 #86）②：上一次进程是**怎么没的**。
                    // Android 17 那条按设备总 RAM 的内存上限对**所有应用**生效（与 targetSdk 无关），
                    // 超了就杀，而 `ApplicationExitInfo.description` 里带 `MemoryLimiter` 字样 ——
                    // 这一条读数是唯一能把"被内存上限杀掉"和"被冻结""网络关线"分开的凭据。
                    // ⚠️ 这是一次 system_server 的 IPC，**只许 Dart 在回到前台时问一次**，
                    // 不许进每秒心跳（真机日志里那一行就是这么定的口径）。
                    result.success(exitReasonsSnapshot(ctx))
                }

                "stopTasks" -> {
                    // build155（第 13 轮 · 撤销完备性）：**这里必须自己撤 1001，不能只靠服务**。
                    // 原来 `stopAll()` 只做 `stopService`，而 1001 的撤销完全挂在
                    // `LiveTaskService.onDestroy → shutdown()` 上 —— 于是这两条路径留不住：
                    //   · 进程被杀（用户从最近任务划掉 / LMK）后再冷启动：服务随进程一起没了，
                    //     但 **1001 是系统替我们持有的**，进程死了它还在，而且 `setOngoing(true)`
                    //     让用户划不掉 ⇒ 一条「Nexus 后台任务」的常驻条永远挂着，
                    //     而 Dart 侧此时任务集是空的（真源说"没有任务"，投影却显示"有"）。
                    //   · `syncTasks` 那次 `startForegroundService` 直接抛（后台限制）时同理：
                    //     服务从没建过，后面所有 stopService 都是空转、没有 onDestroy。
                    // 判据回到本文件的口径：**真源在 Dart**，Dart 会调 `stopTasks` 就说明它认为
                    // 没有任何进行中的任务了 ⇒ 无条件把两条常驻 id 都收掉是安全的
                    // （`cancel` 幂等，双撤无害；高打扰 alert 各有自己的 id 与撤销主人，不在这动）。
                    LiveTaskService.stopAll(ctx)
                    LiveNotification.cancel(ctx, LiveNotification.ID_ONGOING)
                    // build145（第 9 轮 P1-2）：兜底通知（ID_ONGOING_FALLBACK=1002）以前
                    // **没有任何人负责撤** —— 它只在 `startForeground` 被拒那一刻贴出去，
                    // 而那次紧接着就 `stopSelf()`，于是：
                    //   · `shutdown()` 只撤 1001；
                    //   · 服务此刻已经不在，后面所有 `stopService` 都是空转、不会再走 onDestroy；
                    //   ⇒ 用户看到的是一条「Nexus 后台任务」的不确定条**永远挂着**，
                    //     下一轮下载真的起来时还会多出第二条。
                    // 这里补一次显式撤销（`shutdown()` 里撤是不行的：兜底条存在的全部理由
                    // 就是「服务自己的 onDestroy 会秒撤它」）。双撤无害，cancel 是幂等的。
                    LiveNotification.cancel(ctx, LiveNotification.ID_ONGOING_FALLBACK)
                    result.success(null)
                }

                "postAlert" -> {
                    LiveNotification.postAlert(
                        ctx,
                        call.argument<Int>("id") ?: 0,
                        call.argument<String>("title") ?: "",
                        call.argument<String>("body") ?: "",
                        call.argument<String>("route") ?: "",
                        call.argument<Boolean>("ongoing") ?: false,
                    )
                    result.success(true)
                }

                "cancelAlert" -> {
                    LiveNotification.cancel(ctx, call.argument<Int>("id") ?: 0)
                    result.success(null)
                }

                "requestPermission" -> {
                    val act = activityProvider()
                    if (act == null || hasPostPermission(ctx)) {
                        result.success(hasPostPermission(ctx))
                    } else if (Build.VERSION.SDK_INT < 33) {
                        // Android 13 以下无需授权，通知开关才是决定因素
                        result.success(LiveNotification.notificationsEnabled(ctx))
                    } else {
                        // 重入保护：上一次申请还挂着没回执时，先把**旧的那个**结掉。
                        // 直接覆盖会让先发起的那次 `await` 永远不返回（设置页连点两次就会撞上）。
                        permissionResult?.safeSuccess(false)
                        permissionResult = result
                        try {
                            ActivityCompat.requestPermissions(
                                act,
                                arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
                                REQ_POST_NOTIFICATIONS,
                            )
                        } catch (t: Throwable) {
                            // 挂出去的 result 必须先摘回来：否则下面 catch 会把它成功一次，
                            // 系统稍后再回调一次 —— 双重 complete 会直接抛 IllegalStateException。
                            permissionResult = null
                            throw t
                        }
                    }
                }

                "openNotificationSettings" -> {
                    val i = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                        .putExtra(Settings.EXTRA_APP_PACKAGE, ctx.packageName)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    ctx.startActivity(i)
                    result.success(true)
                }

                "openSystemSettingsPage" -> {
                    // build165（任务 #88）：把用户送到系统里那个我们读不到、也拨不动的开关所在的页面。
                    // 交回的是**状态字符串**（成功=opened，失败=一句人话的原因），
                    // 因为这一条的唯一价值是"如实"：谎报他拨没拨，比不给他这个入口更坏。
                    result.success(
                        openSettingsPage(ctx, call.argument<String>("target") ?: "")
                    )
                }

                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            // 通知这一路任何异常都不许冒回 Dart：它都在 UI 的关键路径上（下载/备份/发消息），
            // 抛上去会把用户正在做的正事一起打断。
            android.util.Log.w("LiveTaskPlugin", "${call.method} 失败：${t.javaClass.simpleName} ${t.message}")
            if (permissionResult === result) permissionResult = null
            // build145（第 9 轮 P2-9）：**兜底回执必须按方法的返回类型给**。
            // 原来一律 `success(false)`，而 Dart 侧 `syncTasks` 是
            // `invokeMethod<String>` ⇒ 收到 Boolean 会抛
            // "type 'bool' is not a subtype of type 'String?'"，
            // 于是日志里留下的那条 ERROR 是**我的兜底造出来的**，真正的原因（上面那行
            // 原生 Log）反而不在导出日志里 —— 等于在最关键的一步上把可排查性换成了噪音。
            when (call.method) {
                "syncTasks" -> result.success(
                    "render-failed ${t.javaClass.simpleName}: ${t.message?.take(120)}"
                )
                "requestPermission" -> result.success(false)
                // build165（#88）：这一条的返回类型是「状态字符串」，兜底也必须回一个字符串。
                // 回 null 会被 Dart 侧当成"没结果"，而这里的情况是**确实没跳成** ——
                // 必须带原因（本仓口径：静默降级按缺陷处理）。
                "openSystemSettingsPage" -> result.success(
                    "原生侧抛出异常，跳转没有发生：${t.javaClass.simpleName} ${t.message?.take(120)}"
                )
                // build165（任务 #86）：这两条的返回类型是 Map ⇒ 兜底也必须回一张 Map，
                // 而且要**明说"读不到"**：回 null 会被 Dart 侧读成"没读数"，
                // 而我们真正知道的是"读的时候炸了"（本仓口径：静默降级按缺陷处理）。
                "heartbeatDiag" -> result.success(
                    mapOf(
                        "available" to false,
                        "note" to "原生读心跳时抛出 ${t.javaClass.simpleName}: ${t.message?.take(120)}",
                    )
                )
                "exitReasonsDiag" -> result.success(
                    mapOf(
                        "available" to false,
                        "note" to "原生读退出原因时抛出 ${t.javaClass.simpleName}: ${t.message?.take(120)}",
                    )
                )
                else -> result.success(null)
            }
        }
    }

    /**
     * build165（任务 #88）：跳「本应用的应用信息页」或「AOSP 电池优化列表页」。
     *
     * 交回 [STATUS_OPENED] = Intent 确实发出去了；否则交回**一句给人看的失败原因**。
     * 三种失败各有各的话，不许合并、更不许静默：
     *  · 目标不认识 —— 这是我们自己的缺陷（Dart 传错字符串），不是系统拦的；
     *  · 拿不到 Activity —— 只有 activity context 才保证设置页关掉后回到的是这一屏；
     *  · 系统里没有这一页（ActivityNotFoundException）/ 版本太低（电池优化页要 Android 6+）。
     *
     * 为什么不谎报"开关开没开"：三方 App 没有任何 API 能读到厂商那个后台活动开关
     * （真机取证：docs/BUGSCAN_build164_20260925.md ⑬ —— AOSP 的 Doze / 网络限制 /
     * cached 进程冻结三条都被官方原文排除，剩下的是厂商管控，且没有可申请的免冻结接口）。
     * 所以这一条能力只做到"把你送到那一屏"为止，页面上的文案也只承诺这一点。
     */
    private fun openSettingsPage(ctx: Context, target: String): String {
        val action = when (target) {
            TARGET_APP_DETAILS -> Settings.ACTION_APPLICATION_DETAILS_SETTINGS
            TARGET_BATTERY_OPT -> {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
                    return "本机 Android 版本低于 6.0（API ${Build.VERSION.SDK_INT}），" +
                        "系统里没有「忽略电池优化」这个列表页"
                }
                Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS
            }
            else -> return "App 自己传了不认识的目标「$target」，跳转没有发生" +
                "（这是 App 的缺陷，不是系统拦的）"
        }
        val act = activityProvider()
            ?: return "拿不到当前界面（Activity 还没建起来或已销毁），跳转没有发生"
        // 应用信息页要靠 `package:` 这个 data 指明"看哪个应用"；电池优化列表页是一张清单，没有 data。
        val data = if (target == TARGET_APP_DETAILS) {
            Uri.fromParts("package", ctx.packageName, null)
        } else {
            null
        }
        val intent = Intent(action, data).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            act.startActivity(intent)
            return STATUS_OPENED
        } catch (e: ActivityNotFoundException) {
            return "这台设备的系统里没有「$action」这一页：${e.message ?: e.javaClass.simpleName}"
        } catch (e: SecurityException) {
            return "系统拒绝了这个跳转（SecurityException）：${e.message ?: e.javaClass.simpleName}"
        } catch (e: Throwable) {
            return "跳转抛出 ${e.javaClass.simpleName}：${e.message?.take(120) ?: "无消息"}"
        }
    }

    /** MainActivity 的 `onRequestPermissionsResult` 转发过来。 */
    fun onPermissionResult(requestCode: Int, granted: Boolean) {
        if (requestCode != REQ_POST_NOTIFICATIONS) return
        val r = permissionResult ?: return
        permissionResult = null
        r.success(granted)
    }

    /** 只对「再也没人等」的挂起回执补一次应答；已完成过的直接忽略。 */
    private fun MethodChannel.Result.safeSuccess(v: Any?) = try {
        success(v)
    } catch (t: Throwable) {
        android.util.Log.w("LiveTaskPlugin", "补应答时该回执已完成：${t.message}")
    }

    private fun hasPostPermission(ctx: Context): Boolean = try {
        ContextCompat.checkSelfPermission(
            ctx, android.Manifest.permission.POST_NOTIFICATIONS
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED
    } catch (t: Throwable) {
        true
    }

    /**
     * build165（任务 #86）②：读最近几条「这个进程上一次是怎么没的」。
     *
     * ## 这一条读数是用来分清哪三种可能的
     *  1. **被系统按内存上限杀掉** —— Android 17 起那条按设备总 RAM 的上限**对所有应用生效**
     *     （与 targetSdk 无关），超了直接杀，而它的字样只出现在
     *     `ApplicationExitInfo.description` 里（`MemoryLimiter`）。这就是下面那个
     *     `memoryLimiterHit` 布尔存在的全部理由。
     *  2. **被冻结/挂起** —— 这条**不**会留下退出记录（进程没死，只是没人调度），
     *     所以要和 ① 的原生心跳合起来看：回前台那一行里「ticks 断档 + 没有新退出记录」
     *     才是冻结的形状。
     *  3. **上游或网络把连接关了** —— 进程一直活着，同样没有退出记录，
     *     但 ticks 会跟墙钟一起涨。
     *
     * ## 三条口径
     *  · **不自己编 reason/subReason/importance 的码表**：这些是 AOSP 的常量号，
     *    每加一个 Android 版本就补几个新值，猜错就等于把假话写进取证日志
     *    —— 原数交回，Dart 侧只印数字与 description 原文；
     *  · 取的是**这个包名的历史记录**（pid 传 0），不是"当前进程"：要看的恰恰是上一世；
     *  · 这是一次 system_server 的 IPC，调用方只许在**回到前台时问一次**
     *    （Dart 那侧的锚点由 `test/build165_heartbeat_test.dart` 钉住）。
     */
    private fun exitReasonsSnapshot(ctx: Context): Map<String, Any?> {
        // 版本判断是硬要求：本模块 minSdk 24，而 getHistoricalProcessExitReasons 要 API 29。
        // 低版本必须回一句"系统里没有这个接口"，而不是在这里抛、被上面的 catch 记成一次故障。
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return mapOf(
                "available" to false,
                "sdkInt" to Build.VERSION.SDK_INT,
                "note" to "本机 API ${Build.VERSION.SDK_INT} 低于 29（Android 10），" +
                    "系统里没有读取历史退出原因的接口",
            )
        }
        val am = ctx.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            ?: return mapOf(
                "available" to false,
                "sdkInt" to Build.VERSION.SDK_INT,
                "note" to "拿不到 ActivityManager 系统服务",
            )
        val records = try {
            am.getHistoricalProcessExitReasons(ctx.packageName, 0, MAX_EXIT_RECORDS)
        } catch (t: Throwable) {
            // 厂商 ROM 在这条接口上不是没炸过（SecurityException / NoSuchMethodError）。
            return mapOf(
                "available" to false,
                "sdkInt" to Build.VERSION.SDK_INT,
                "note" to "getHistoricalProcessExitReasons 抛出 ${t.javaClass.simpleName}: " +
                    "${t.message?.take(120) ?: "无消息"}",
            )
        }
        val fmt = SimpleDateFormat("MM-dd HH:mm:ss", Locale.getDefault())
        val exits = records.map { e ->
            val desc = e.description ?: ""
            mapOf(
                "timestampMs" to e.timestamp,
                "time" to fmt.format(Date(e.timestamp)),
                "pid" to e.pid,
                "processName" to (e.processName ?: ""),
                "reason" to e.reason,
                // 没有 "subReason" 这一格：`ApplicationExitInfo.getSubReason()` 是 @TestApi，
                // 本机 compileSdk 36 的 `android.jar` 里没有这个公开 getter（javap 查过），
                // 编不过 = 拿不到；宁可少一格，也不发一个恒 0 的字段让 Dart 侧当成读数。
                // 内存上限那条嫌疑走下面 description / pss / rss / importance 四格。
                "importance" to e.importance,
                "status" to e.status,
                "description" to desc.take(MAX_DESCRIPTION_CHARS),
                "memoryLimiterHit" to desc.contains("MemoryLimiter"),
                // 内存上限那条嫌疑就看这两个数与上面那个布尔：RSS 多高算超了这台机的上限
                // 我们没有本地判据（那是按设备总 RAM 算的），所以只把数交回去，不在这判定。
                "pssBytes" to e.pss,
                "rssBytes" to e.rss,
            )
        }
        return mapOf(
            "available" to true,
            "sdkInt" to Build.VERSION.SDK_INT,
            "count" to exits.size,
            "exits" to exits,
        )
    }
}
