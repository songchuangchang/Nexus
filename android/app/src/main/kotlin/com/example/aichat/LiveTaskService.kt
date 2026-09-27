package com.example.aichat

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import androidx.core.app.ServiceCompat
import org.json.JSONObject

/**
 * build142（灵动岛）：把「应用外继续跑」这件事落到前台服务上。
 *
 * 为什么要**两个**服务而不是一个：Android 14+ 要求前台服务声明类型，且类型是
 * **按服务类**在清单里写死的。下载 / 备份属于 `dataSync`（有「用户主动发起」与
 * Android 15 起约 6 小时/日的配额），而 AI 长轮（深度研究、视频生成）语义上不属于
 * 任何一种既有类型，只能用 `specialUse` 并在应用商店写用途说明。
 * ⇒ 混进一个「万能服务」等于把两类合规风险叠在一起，还会让 dataSync 配额被长任务吃掉。
 *
 * 通知本体一律由 [LiveNotification] 渲染：服务只负责「让进程活着 + 把快照贴上去」，
 * 自己不持有任何任务状态（教训 #62：真源在 Dart 的 `LiveTaskCenter`，这里只是投影）。
 */
abstract class LiveTaskService : Service() {

    /** 子类返回 `ServiceInfo.FOREGROUND_SERVICE_TYPE_*`（清单里也要有同名声明，否则 Android 14+ 抛异常）。 */
    protected abstract fun foregroundType(): Int

    /** 清单 `<service android:foregroundServiceType="...">` 用的字符串，随 [foregroundType] 一起声明。 */
    protected abstract fun foregroundTypeName(): String

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        // build165（任务 #86）：心跳从**服务活着的那一刻**起跳，与快照/通知完全无关 ——
        // 这一条读数要回答的是"进程这具身体还在不在跑"，所以它必须挂在服务上，
        // 不能挂在 Dart 的 Timer 上（Dart Timer 在进程被冻结时根本不跑，
        // `live_task_center.dart` 里那句"只挂一条延时的限时在后台等于没有限时"说的就是这件事）。
        BgHeartbeat.noteServiceCreated()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // 空快照 = Dart 侧认为已经没有进行中的任务了。此时必须**主动退出**，
        // 否则一条常驻通知会永远挂着（用户第一反应就是关通知，功能等于没有）。
        val raw = intent?.getStringExtra(EXTRA_SNAPSHOT) ?: "{}"
        val snapshot = try {
            JSONObject(raw)
        } catch (t: Throwable) {
            JSONObject()
        }
        val tasks = snapshot.optJSONArray("tasks")
        if (tasks == null || tasks.length() == 0) {
            shutdown()
            return START_NOT_STICKY
        }
        // 通知渲染失败不许把服务搞崩：降级成「无通知的前台服务」是非法的（Android 8+
        // 5 秒内必须 startForeground 一条通知），所以兜底自己造一条最朴素的。
        val notification = try {
            LiveNotification.renderOngoing(this, snapshot)
        } catch (t: Throwable) {
            android.util.Log.w(TAG, "快照渲染失败，用兜底通知：${t.message}")
            LiveNotification.ensureChannels(this)
            androidx.core.app.NotificationCompat.Builder(this, LiveNotification.CHANNEL_ONGOING)
                .setSmallIcon(applicationInfo.icon)
                .setContentTitle("Nexus 后台任务进行中")
                .setOngoing(true)
                .setSilent(true)
                .build()
        }
        // ⚠️ SecurityException 的真实来源：Android 12+ 从后台启动带 dataSync 类型的前台服务
        // 会被拒（"not allowed to start ... while in background"）。调用点只在用户主动发起
        // 任务时启动，但「用户点了下载 → 立刻切后台 → Dart 才回头 sync」这条竞态真实存在，
        // 所以整段兜住：起不来服务**不能**让异常抛回 Dart 的调用链。
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ServiceCompat.startForeground(this, LiveNotification.ID_ONGOING, notification, foregroundType())
            } else {
                @Suppress("DEPRECATION")
                startForeground(LiveNotification.ID_ONGOING, notification)
            }
        } catch (t: Throwable) {
            android.util.Log.w(TAG, "startForeground(${foregroundTypeName()}) 被拒，退回普通通知：${t.message}")
            try {
                LiveNotification.notifyOngoingDirect(this, snapshot)
            } catch (t2: Throwable) {
                android.util.Log.w(TAG, "普通通知也没贴上：${t2.message}")
            }
            stopSelf()
        }
        // build145（第 9 轮 P1-2）：前台服务贴上去了 ⇒ 之前那次「被拒」留下的兜底通知
        // 就成了**第二条常驻条**（同一个任务在通知栏出现两次），这里顺手收掉。
        // 为什么由「成功这一次」负责而不是由 `shutdown()` 负责：见 LiveNotification
        // 里 ID_ONGOING_FALLBACK 那段注释 —— 兜底条存在的全部理由就是
        // 「服务自己的 onDestroy 会秒撤它」，所以谁都不能在 onDestroy 里撤。
        // 但「撤 1001 的那次前台成功」一定是**当前这条快照**的负责人，兜底条此刻已是重复品。
        try {
            LiveNotification.cancel(this, LiveNotification.ID_ONGOING_FALLBACK)
        } catch (t: Throwable) {
            android.util.Log.w(TAG, "收兜底通知失败：${t.message}")
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        // build165（任务 #86）：服务一销毁就停表。漏掉这一步的后果不是耗电，是**读数失真**：
        // 一个没人要的每秒任务还在往 ticks 里加数，下一次"心跳没断档"就成了假证据。
        BgHeartbeat.noteServiceDestroyed()
        shutdown()
        super.onDestroy()
    }

    private fun shutdown() {
        try {
            ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        } catch (t: Throwable) {
            android.util.Log.w(TAG, "stopForeground 失败：${t.message}")
        }
        LiveNotification.cancel(this, LiveNotification.ID_ONGOING)
        stopSelf()
    }

    companion object {
        private const val TAG = "LiveTaskService"
        const val EXTRA_SNAPSHOT = "snapshot"

        /**
         * Dart 侧唯一的启动入口。传空任务列表即等价于「停」。
         *
         * 用 `startService` 而不是 `bindService`：本项目的所有更新都是「快照重绘」语义，
         * 不需要双向连接；绑定反而会在 Activity 销毁/重建时留下悬挂的连接要自己管。
         */
        fun sync(ctx: Context, snapshotJson: String, specialUse: Boolean) {
            val cls = if (specialUse) LiveAgentService::class.java else LiveDownloadService::class.java
            val other = if (specialUse) LiveDownloadService::class.java else LiveAgentService::class.java
            // 类型翻转（下载完了、研究还在跑）时**必须先停另一个**：
            // 两个服务同时前台 = 两条几乎一样的常驻通知，而且旧那条会一直挂着。
            try {
                ctx.stopService(Intent(ctx, other))
            } catch (t: Throwable) {
                android.util.Log.w(TAG, "切换服务类型时停止旧服务失败：${t.message}")
            }
            val intent = Intent(ctx, cls).putExtra(EXTRA_SNAPSHOT, snapshotJson)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    ctx.startForegroundService(intent)
                } else {
                    ctx.startService(intent)
                }
            } catch (t: Throwable) {
                // Android 12+ 后台限制下 startForegroundService 本身就会抛
                android.util.Log.w(TAG, "startForegroundService 失败（${if (specialUse) "specialUse" else "dataSync"}）：${t.message}")
                throw t
            }
        }

        fun stopAll(ctx: Context) {
            for (cls in listOf(LiveDownloadService::class.java, LiveAgentService::class.java)) {
                try {
                    ctx.stopService(Intent(ctx, cls))
                } catch (t: Throwable) {
                    android.util.Log.w(TAG, "stopService 失败：${t.message}")
                }
            }
        }

        /**
         * build165（任务 #86）：心跳快照（通道方法 `heartbeatDiag` 交回去的就是这张表）。
         *
         * 纯进程内静态量读数：不查系统服务、不贴通知、不动任务状态，所以 Dart 侧
         * 可以**在掉线那一刻**问一句，代价是一次通道往返。
         */
        fun heartbeatSnapshot(): Map<String, Any?> = BgHeartbeat.snapshot()
    }
}

/** 下载 / 备份 / 数据包：`dataSync`。 */
class LiveDownloadService : LiveTaskService() {
    override fun foregroundType(): Int = ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
    override fun foregroundTypeName(): String = "dataSync"
}

/** 深度研究 / 长轮 Agent / 视频生成轮询：`specialUse`（需在商店写用途说明）。 */
class LiveAgentService : LiveTaskService() {
    override fun foregroundType(): Int =
        if (Build.VERSION.SDK_INT >= 34) ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else 0

    override fun foregroundTypeName(): String = "specialUse"
}

/**
 * build165（任务 #86）：**进程内心跳**——用来把「这一轮流式回答为什么停」那三种可能分开的读数。
 *
 * ## 为什么必须有它（已取证，别重查）
 * 机主的 App（OPPO / ColorOS 16 / Android 16、targetSdk 36）一进后台这一轮就停摆。
 * 上游与端点已排除（官方与中转站同一种失败形状），AOSP 的 Doze / App Standby / cached-apps
 * freezer 三条也已用官方原文排除（前台服务当时确实在跑、`promotedFlag=true`）。
 * 剩下三种可能**修法互斥**，而现有读数分不开：
 *  1. **进程被冻结/挂起** —— 那么原生侧做什么都白做，先解决保活；
 *  2. **被系统按内存上限杀掉**（Android 17 起那条按设备总 RAM 的上限对所有应用生效，
 *     `ApplicationExitInfo` 的 description 里带 `MemoryLimiter`）—— 那是另一套修法；
 *  3. **上游或网络把连接关了** —— 进程一直活着，只有 socket 死了。
 * 把 1 和 3 分开的**唯一**依据就是一个"跟 Dart 完全无关、只由主线程每秒加一"的计数器：
 * 墙钟走了 46 秒而 ticks 只涨了几次 ⇒ 进程那段时间根本没在跑（1）；
 * ticks 每秒都在涨而流死了 ⇒ 身体是好的，出问题的是连接（3）；
 * 压根一个 tick 都没有 ⇒ 连服务都没起（这条本来就该先排掉，见 [snapshot] 的 `everStarted`）。
 *
 * ## 为什么不引依赖、为什么用 postDelayed
 * `Handler(Looper.getMainLooper()).postDelayed` 自投递是 Android 最常规的做法，
 * 不需要 WorkManager / 不需要协程库（本模块现在一个协程依赖都没有）。
 * 时钟取 [SystemClock.elapsedRealtime]：它不含深度睡眠、不受用户改系统时间影响，
 * 而本仓已经在"拿墙上时钟当判据"上吃过几次亏（`round_timing.dart` 那句"时间戳非单调"）。
 *
 * ## 生命周期（不许漏一个每秒任务在跑）
 * 起：[LiveTaskService.onCreate]；停：[LiveTaskService.onDestroy]。
 * 两个服务子类（dataSync / specialUse）在类型翻转时会**先起新的、停旧的**，
 * 所以这里按 [servicesAlive] 引用计数，只有掉到 0 才真停表 ——
 * 否则那次翻转会把刚起的那条心跳顺手掐掉，读数变成"服务没起"的假阳性。
 */
object BgHeartbeat {

    /** 心跳间隔。1 秒是刻意的：机主报的那次「离开 46s」要能用"应该跳了 46 次"直接对账。 */
    private const val TICK_INTERVAL_MS = 1000L

    /** 判「这一秒还在不在跳」的宽限期：两次 tick 之间 + 主线程被占住的抖动都算在跳。 */
    private const val LIVE_WINDOW_MS = 2500L

    /** 累计跳了多少次。**进程内单调增**，进程死了就归零（这正是它能当"上一世怎么死的"的对照）。 */
    @Volatile
    var ticks: Long = 0L
        private set

    /** 最近一次跳的时刻（[SystemClock.elapsedRealtime]）；0 = 一次都没跳过。 */
    @Volatile
    var lastTickAt: Long = 0L
        private set

    /** 这个进程里**有没有起过**心跳服务（false = 从没起过，读数要说的就是"压根没有 ticks"）。 */
    @Volatile
    var everStarted: Boolean = false
        private set

    /** 当前活着的前台服务实例数（引用计数，见类注释的生命周期那一段）。 */
    @Volatile
    private var servicesAlive: Int = 0

    private var handler: Handler? = null

    fun noteServiceCreated() = synchronized(this) {
        servicesAlive += 1
        if (!everStarted) everStarted = true
        startTicking()
    }

    fun noteServiceDestroyed() = synchronized(this) {
        servicesAlive = if (servicesAlive > 0) servicesAlive - 1 else 0
        if (servicesAlive == 0) stopTicking()
    }

    private fun startTicking() {
        if (handler != null) return // 幂等：翻转类型时第二次 start 不许排进第二个每秒任务
        val h = Handler(Looper.getMainLooper())
        handler = h
        h.postDelayed(ticker, TICK_INTERVAL_MS)
    }

    private fun stopTicking() {
        val h = handler ?: return
        h.removeCallbacks(ticker)
        handler = null
    }

    private val ticker = object : Runnable {
        override fun run() {
            ticks += 1
            lastTickAt = SystemClock.elapsedRealtime()
            // 自投递而不是 CountDownTimer：后者要算总时长、到点自己停，
            // 而这里要的是"服务活着就一直跳"。
            handler?.postDelayed(this, TICK_INTERVAL_MS)
        }
    }

    /**
     * 给 Dart 的那张表（通道方法 `heartbeatDiag`）。
     *
     * 键名是 Dart 侧 `bg_forensics.dart` 的 `BgHeartbeat.fromMap` 逐字读的，两边不许各写一套。
     * `ageMs` 只回答"**问这一刻**距上次跳过了多久"（主线程是不是正被占住）；
     * 判"后台那 46 秒有没有在跳"用的是两次 ticks 的差，不是这个数 ——
     * 解冻后第一次 tick 立刻就把 ageMs 洗成 0，拿它当断档证据会得出反的结论。
     */
    fun snapshot(): Map<String, Any?> = synchronized(this) {
        val age = if (lastTickAt == 0L) -1L else SystemClock.elapsedRealtime() - lastTickAt
        mapOf(
            "available" to true,
            "ticks" to ticks,
            "ageMs" to age,
            "ticking" to (age >= 0L && age <= LIVE_WINDOW_MS),
            "services" to servicesAlive,
            "everStarted" to everStarted,
            "intervalMs" to TICK_INTERVAL_MS,
        )
    }
}
