package com.example.aichat

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.graphics.drawable.IconCompat
import org.json.JSONObject

/**
 * build142（灵动岛 · 腿 A + 腿 B）：应用外进度通知的**唯一渲染出口**。
 *
 * 为什么不引 `flutter_local_notifications`（本轮实测，不是印象）：
 * 它对 Android 16 的 Live Updates 还没有支持 —— 上游 PR #2810 仍 `open`/未合并、
 * issue #2773 仍 `open`、仓库内搜 `requestPromotedOngoing` / `ProgressStyleInformation`
 * / `liveUpdate` 三组关键词命中数均为 0、最新发行 22.3.1 的 changelog 里没有这族 API。
 * ⇒ 想要「状态栏图标上转进度」这一层，横竖得自己写 Kotlin；既然要写 Kotlin，
 *   再加一个三方依赖只会多一套真源（教训 #62）。
 *
 * 为什么腿 B 不声明任何新权限（同样是实测）：
 * `javap` 读 `androidx.core:1.18.0` 的字节码，`setRequestPromotedOngoing(true)` 的实现
 * 只是往 extras 里塞 `"android.requestPromotedOngoing" = true`，**不引用任何权限常量**；
 * 而 `android-36` 的 `android.jar` 里 `Notification` 有 `FLAG_PROMOTED_ONGOING` 与
 * `hasPromotableCharacteristics()`。
 * ⚠️ **build145 推翻了我当时由此得出的结论**：我当时因为 `Manifest.permission` 里搜不到
 * `POST_PROMOTED_NOTIFICATIONS` 这个常量，就判定"权限名查无实据"、故意不写进清单。
 * 错在把「有没有 Java 常量」当成了「权限存不存在」——清单权限是字符串，常量常有平台时间差。
 * 官方文档原文要求声明它（normal 权限），而真机 `canPostPromotedNotifications()=false`
 * + `promotable=true` 的组合正好是"没声明所以没资格"的样子 ⇒ 现已补进 AndroidManifest。
 *
 * 三条硬约束：
 * 1. **任何 Android 16 专属调用都必须版本守卫 + try/catch** —— 猜错只能让通知变朴素，不能崩 App；
 * 2. **Dart 每次传整份快照，这里幂等重绘** —— 不留「上一份状态」在原生侧，避免两端各有一半真源；
 * 3. 进行中通知**低打扰**（不响铃不振动），只有完成/失败/待回答才走高打扰渠道。
 */
object LiveNotification {

    /** 常驻进度（低打扰）：整个 App 只有一条，任务再多也合并成摘要 */
    const val ID_ONGOING = 1001

    /**
     * 前台服务**起不来时**的兜底通知用独立 id。
     *
     * 共用 ID_ONGOING 会被服务自己的 `onDestroy → cancel(ID_ONGOING)` 秒撤 ——
     * 于是「Android 12+ 用户点完下载立刻切后台」这条最常见的路径变成整条功能静默
     * （本轮自审抓到的 P0）。分开之后：兜底那条不归服务管，只由下一次渲染覆盖。
     */
    const val ID_ONGOING_FALLBACK = 1002
    const val CHANNEL_ONGOING = "nexus_live_ongoing"

    /** 完成 / 失败 / 待回答（高打扰，会响） */
    const val CHANNEL_ALERT = "nexus_live_alert"

    /** 点通知回 App 用的 action，与 MainActivity 的路由解析对齐 */
    const val ACTION_OPEN = "com.example.aichat.live.OPEN"
    const val EXTRA_ROUTE = "route"

    const val TYPE_DATA_SYNC = "dataSync"
    const val TYPE_SPECIAL_USE = "specialUse"

    /**
     * 分段条的段数上限（与 Dart 侧 `kLiveStageSegmentCap` 同一个数，两边必须一致）。
     *
     * 为什么有上限：岛/通知里那条带很窄，段数一多每段就细到看不出色差 ——
     * 看不出的分段等于没有，还会把「哪几段做完了」从"能读"变成"要盯着看半天"。
     * 所以第 5 段往后合并成最后一段（段长 = 余下的阶段数）。
     */
    private const val LIVE_SEGMENT_CAP = 5

    /** 未完成段的 alpha（25% 不透明度）：与强调色同色相压淡，见 [accentArgb]。 */
    private const val DIM_ALPHA = 0x40

    /**
     * 显示序分桶数（build168 ③ / 真机反馈 #97）。
     *
     * `prio` 的档位表**只有 Dart 那一份**（`live_task_center.dart` 的
     * `liveDisplayPriority()`：0 等人答 / 1 失败 / 2 进行中 / 3 已完成）。
     * 这里不复制第二张判据表，只按传来的数字分桶；这个数字是**桶的个数**不是档位含义，
     * 越界的值一律夹进边界（旧包传来的 0..3 落在边界内，坏数据只是退回排在最后）。
     */
    private const val LIVE_PRIO_BUCKETS = 4

    /** 主题问不到强调色时的兜底蓝（`?android:attr/colorAccent` 在部分 ROM 上取不到值）。 */
    private val ACCENT_FALLBACK = 0xFF1A73E8.toInt()

    fun manager(ctx: Context): NotificationManager =
        ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    /** 幂等建渠道。通知渠道创建后其重要性不可再改，所以只在第一次生效。 */
    fun ensureChannels(ctx: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = manager(ctx)
        if (mgr.getNotificationChannel(CHANNEL_ONGOING) == null) {
            mgr.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ONGOING, "后台任务进度", NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "下载、备份、生成等长任务的常驻进度"
                    setShowBadge(false)
                    enableVibration(false)
                    enableLights(false)
                }
            )
        }
        if (mgr.getNotificationChannel(CHANNEL_ALERT) == null) {
            mgr.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ALERT, "任务完成与待回答", NotificationManager.IMPORTANCE_HIGH
                ).apply { description = "任务完成、失败，以及 AI 反问等待你回答时的提醒" }
            )
        }
    }

    fun notificationsEnabled(ctx: Context): Boolean =
        try {
            NotificationManagerCompat.from(ctx).areNotificationsEnabled()
        } catch (t: Throwable) {
            false
        }

    /**
     * 渲染常驻快照。`snapshot` 是 Dart 传来的整份 JSON：
     * `{"promoted":true,"tasks":[{"id","kind","title","pill","detail","progress","indeterminate","done","ok","prio","waitingUser","stages":[…]}...]}`
     * （build152 起 `stages` 真的被 `applyLiveUpdate` 读走画成分段条；
     * build153 起 `pill` 真的被 `renderOngoing` 读走占标题位 —— 这两句都是
     * 「曾经承诺过没人实现」的那类注释，改口径时要连着改，见 `live_task_center.dart`
     * 的 `LiveTask.pill` 与 `docs/OPPO_FLUID_CLOUD_PUSH_接入清单.md` §五）
     *
     * build168 ③/#97 新增两格，**两边都有人读了**（不再是"注释承诺了没人实现"）：
     *  · `prio` = 这一行该不该当标题（0 等人答 / 1 失败 / 2 进行中 / 3 已完成），
     *    表住在 `live_task_center.dart` 的 `liveDisplayPriority()`，本文件只按数字分桶；
     *  · `waitingUser` = 这一行停在「模型问了一句、等人答」上。`renderOngoing` 用它
     *    决定标题前缀（低版本）与 `endedCount`，`applyLiveUpdate` 用它选第三枚端点图标
     *    `ic_live_action`。**只有为真时 Dart 才输出这个键**（与 `stages` 同一条纪律），
     *    所以缺键 = false = 逐字节旧行为。
     *
     * 返回要贴到前台服务上的通知；调用方（服务）**必须**把它交给 `startForeground`，
     * 否则服务会在几秒内被系统掐掉（Android 8+ 硬规则）。
     */
    fun renderOngoing(ctx: Context, snapshot: JSONObject): Notification {
        ensureChannels(ctx)
        val tasks = snapshot.optJSONArray("tasks") ?: org.json.JSONArray()
        val count = tasks.length()

        // build153（真机反馈「你确定按了 oppo 的布局了吗」的另一半 —— 查截图时发现的）：
        // 以前这里把 `tasks` **按 Dart 传来的原序**当成"全部进行中"来算：
        // `count = tasks.length()`、标题取 `tasks[0]`、百分比遍历全体。
        // 但快照里一直会混着 build149 那批**停留 [LiveTaskCenter.terminalHold] 秒的终态行**
        // （`done=true` + `progress=1.0`）⇒ 三处同时失真：
        //  · 「进行中 2 项」里那"2 项"其实一项早跑完了（用户看到的就是这句假统计）；
        //  · 终态行的 100% 会把还在跑的下载 30% **盖掉**（与 build145 那条
        //    「一个不确定任务不许把真实百分比盖掉」同型，只是这次盖它的是"已完成"）；
        //  · 排在 0 号的是"✓ 已完成"时，标题说的是刚结束的那件事，还在跑的那件没人提。
        // 口径改为：**进行中的排前面**，统计只数进行中的；全都在终态时终态行自己当标题
        // （那正是"完成√停几秒再撤"要的效果，不能撤了这条反把它判没）。
        val running = ArrayList<JSONObject>()
        val finished = ArrayList<JSONObject>()
        for (i in 0 until count) {
            val t = tasks.optJSONObject(i) ?: continue
            if (t.optBoolean("done", false)) finished.add(t) else running.add(t)
        }
        // build168 ③（真机反馈缺陷 #97）：标题那一格**只按 Dart 传来的 `prio` 选**。
        // 上面那对 running/finished 二分**留着**，但它现在只管"共几项"那个计数，
        // 不再顺手决定谁当标题 —— 旧写法把两件事混在一句里，于是
        // 「下载刚跑完 + 一轮停在反问上」同时在场时，屏幕上说的是那件**已经结束**的事，
        // 真正等他答的那一行既没标题也没人念（`done=true` 的等待行永远排在在跑的后面）。
        // `prio` 的档位表住在 `live_task_center.dart` 的 `liveDisplayPriority()`
        // （0 等人答 / 1 失败 / 2 进行中 / 3 已完成），跨语言不能共享代码，
        // 由 `test/build142_live_task_test.dart` 与本文件的锚点测试钉住同一个数字。
        // 读不到 `prio`（旧包 / 别的下发方）时按**同一张表**从 done/ok 现推，
        // 于是缺字段只是退回旧行为，不会出现"这边没标题那边有标题"的两张皮。
        // 分桶拼接 = 天然**稳定**（同档保持收到的顺序），与 Dart 侧 `liveDisplayOrder`
        // 那条"同档内按登记序"的口径一字不差；两条同为进行中的下载不会每次换人当标题。
        val buckets = Array(LIVE_PRIO_BUCKETS) { ArrayList<JSONObject>() }
        for (i in 0 until count) {
            val t = tasks.optJSONObject(i) ?: continue
            val p = if (t.has("prio")) {
                t.optInt("prio", 2)
            } else if (!t.optBoolean("done", false)) {
                2
            } else if (t.optBoolean("waitingUser", false)) {
                0
            } else if (t.optBoolean("ok", true)) {
                3
            } else {
                1
            }
            buckets[p.coerceIn(0, LIVE_PRIO_BUCKETS - 1)].add(t)
        }
        val ordered = ArrayList<JSONObject>(count).apply {
            for (b in buckets) addAll(b)
        }
        // 聚合百分比只看进行中的那些；全是终态行时才让终态自己的满格上屏。
        val aggregate = if (running.isNotEmpty()) running else ordered

        // 摘要口径：进度取最大（用户关心的是「有没有快好了」，不是均值）。
        var maxProgress = -1
        var indeterminate = false
        var headTitle = if (ordered.isEmpty()) "Nexus 后台任务" else ""
        val detail = StringBuilder()
        // build153（用户批准「可以」，口径见 `live_task_center.dart` 的 `LiveTask.pill`）：
        // 岛/状态栏**胶囊**那一格放的是短名（≤5 字符，官方规范：超长会先拉长胶囊、
        // 到最大宽度后以「…」截断）。`pill` 由 Dart 按 kind 推，表外没有短名就
        // 照旧用完整标题 —— 宁可长一点被截，也不编一个读不通的短词。
        val shortTitle = ordered.firstOrNull()?.optString("pill", "") ?: ""
        // 进度**遍历全体（= aggregate）**取最大，文案只列前 3 项：两者口径必须分开。
        // 原来一并在前 3 项里算 —— 旧的「不确定」任务排在前面时，
        // 真实的下载百分比永远上不了屏，而 Dart 那边按全体算节流，两边各说一套。
        for (i in aggregate.indices) {
            val t = aggregate[i]
            val p = t.optDouble("progress", Double.NaN)
            if (!p.isNaN()) {
                maxProgress = maxOf(maxProgress, (p * 100).toInt())
            } else {
                indeterminate = true
            }
        }
        for (i in ordered.indices) {
            val t = ordered[i]
            if (i == 0) headTitle = t.optString("title", headTitle)
            if (i < 3) {
                // build148（真机反馈「灵动岛不合理」）：正文以前**永远从标题开始拼**，
                // 而标题已经由下面的 `setContentTitle` 说过一次 ⇒ 单任务时岛里两行是
                // 「正在更新资源包 · 已完成」+「正在更新资源包 · 已完成 · 新的模板…」，
                // 第二行等于没有信息（能显示的结果信息被重复文案挤掉了，长 detail 还会被截）。
                // 口径改为：标题只由 contentTitle 表达，正文只补**标题里没有的东西**；
                // 多任务时正文是一张列表、没有任务名就分不清哪段属于谁，所以 i>0 仍拼标题。
                val extra = t.optString("detail", "")
                if (i > 0) {
                    val name = t.optString("title", "")
                    if (name.isNotEmpty()) {
                        if (detail.isNotEmpty()) detail.append(" · ")
                        detail.append(name)
                    }
                } else if (shortTitle.isNotEmpty()) {
                    // 标题那一格被短名占了 ⇒ 完整任务名落到正文开头，一个字都不丢。
                    // （与 build148 那条"正文别再重复标题"不冲突：那条的前提是
                    //   标题与正文说的是同一句；这里标题已经换成「备份中」了。）
                    val name = t.optString("title", "")
                    if (name.isNotEmpty()) detail.append(name)
                }
                if (extra.isNotEmpty()) {
                    if (detail.isNotEmpty()) detail.append(" · ")
                    detail.append(extra)
                }
                // build145（第 9 轮 P2-3）：任务自己的 `detail` 以前**从来没上过屏**
                // —— 这个 StringBuilder 只拼 title。于是 Dart 那边辛苦算出来的
                // 「12.4 MB / 26.1 MB」「第 3/8 轮」全被丢掉，跑了十分钟的研究在通知里
                // 始终是一句「深度研究中」。要么就把它拼进来，要么别在文档里承诺这个字段。
            }
        }
        // 只要有一项确定可用就以百分比为准；全都不确定才画不确定条。
        if (maxProgress < 0) indeterminate = true
        // build145（循环审查第 9 轮 P1-1）：**一个不确定任务不许把真实百分比盖掉**。
        // 上面那句注释定的就是这条口径，但代码当时是 `maxProgress >= 0 && !indeterminate`
        // —— `indeterminate` 在循环里被**任意一个**无进度任务置真，于是
        // 「下载(47%) + 深度研究(无字节进度)」同时在场时，下载那条真百分比**永远上不了屏**，
        // 通知里只有一根无限转的条（Live Update 那侧同理，两边一起错得很一致）。
        // Dart 侧仍按全体最大百分比节流 ⇒ 内容在变、条不动，用户读成"卡住了"。
        val hasPercent = maxProgress >= 0
        // 标题位：有短名用短名（岛/胶囊那一格放不下长句），没有就照旧用完整标题。
        //
        // build168 ①（#97，设计稿 `docs/UI_MOCK_island_states_20260926.html` 那张表下面
        // 那段"为什么 ⚠ 不能当字符写进标题"）：**状态的主信号是端点图标**，
        // 因为 pill 一窄就被切掉的是标题尾巴（「更新资源包 · 已完成」丢的正是最后那个词）。
        // 而 `ProgressStyle` 只在 Android 16（API 36）上真的画出来 ——
        // 见本文件 `applyLiveUpdate` 开头那句 `if (Build.VERSION.SDK_INT < 36) return`。
        // 低版本没有图标这一格，状态必须换一个地方上屏：退回**标题前缀**。
        // 前缀只准用不在 R1 码段（U+2600–U+27BF）里的四个字符：
        // √(U+221A) / ×(U+00D7) / ！(U+FF01) / …(U+2026)。
        // 只在"这一行本来会挂端点图标"的时候加前缀（= 终态行），进行中不加：
        // 图标族本来就只在终态挂（本文件口径「还在跑的行右边出现完成符就是假消息」），
        // 前缀跟着同一条规则，才不会让低版本多出一句高版本没有的话。
        val headRow = ordered.firstOrNull()
        val statePrefix =
            if (Build.VERSION.SDK_INT >= 36 || headRow == null ||
                !headRow.optBoolean("done", false)
            ) "" else when {
                headRow.optBoolean("waitingUser", false) -> "！"
                headRow.optBoolean("ok", true) -> "√"
                else -> "×"
            }
        val titleText =
            statePrefix + (if (shortTitle.isNotEmpty()) shortTitle else headTitle)
        if (ordered.size > 3) detail.append(" · 等 ${ordered.size} 项")

        val pi = openIntent(ctx, ordered.firstOrNull()?.optString("route") ?: "")

        val b = NotificationCompat.Builder(ctx, CHANNEL_ONGOING)
            .setSmallIcon(smallIcon(ctx))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(pi)
        // 刻意**不用** notification group：本条是唯一一条常驻通知，
        // 「只有 summary、没有 child」在某些 ROM 上会被整组吞掉（表现是通知凭空消失，
        // 比少一个折叠效果难查得多）。任务再多也只合并成这一条摘要。
        if (ordered.size <= 1) {
            b.setContentTitle(titleText)
            if (detail.isNotEmpty()) b.setContentText(detail.toString())
        } else {
            // build153（真机反馈「你确定按了 oppo 的布局了吗」）：以前多任务把数量
            // **拼进标题**（"进行中 2 项 · 深度研究中"）。折叠态那格只放得下一句短标题，
            // 于是厂商侧被截成「进行中 2 项 · T…」——占满整行的是一句我们自己造的统计文案，
            // 真正在跑的是哪件事反而看不见。
            // 口径改为与模板同形：**标题位放短名**（Dart 按 kind 推的 `pill`，推不出来才
            // 放完整任务名），"共几项"挪进 subText
            // （通知头部那枚小标签，正是数量/分组这类元信息的槽位）。
            // 计数只数**进行中的**：那 8 秒里混着的终态行不是"进行中"（本文件口径：
            // 宁可少报也不虚报）。全都在终态时明说"已结束"，不假装还在跑。
            // ⚠️ subText 在各家 ROM 折叠态显不显示、显示在哪，只能真机验收（与整族
            //    ProgressStyle 同进同一批验收项，见 docs/RELEASENOTES build153）。
            b.setContentTitle(titleText)
            // 「已结束」那个数**不把等待行算进去**：`done=true` 在它那一档说的是
            // "此刻没有任何东西在跑"（见 `live_task_center.dart` 的 `waitingUser`），
            // 不是"这轮交付完了"。把「等你回答」计进"已结束 N 项"，正是 #97 那句
            // 「反问轮被写成已完成」在多任务那一格的翻版 —— 宁可少报也不虚报。
            val endedCount = finished.count { !it.optBoolean("waitingUser", false) }
            val badge = when {
                running.size > 1 -> "共 ${running.size} 项"
                running.isEmpty() && endedCount > 1 -> "$endedCount 项已结束"
                else -> ""
            }
            if (badge.isNotEmpty()) b.setSubText(badge)
            b.setContentText(detail.toString())
                .setStyle(NotificationCompat.BigTextStyle().bigText(detail.toString()))
        }
        // 进度条：能算出百分比就画确定的，否则退回不确定态（不确定态不许显示假百分比）。
        if (hasPercent) {
            b.setProgress(100, maxProgress.coerceIn(0, 100), false)
        } else {
            // build148（真机反馈③「下面一条线有什么用」）：不确定态原来写
            // `setProgress(0, 0, true)` —— **max = 0** 是个自相矛盾的输入：
            // 0 分之 0。标准 NotificationCompat 会因 indeterminate=true 忽略数值，
            // 但 ROM 的映射层不一定：ColorOS 把这种输入画成一条**接近满格的实心条**，
            // 于是"没有进度可比"的任务（深度研究、备份、下载整包）在用户眼里
            // 像"卡在 100% 不动"。max 给 100 与确定分支同口径，值仍是 0、仍标不确定，
            // 数学上不再出现"总长为零"。
            // 注：真正的不确定态由下面 applyLiveUpdate 里的
            // `ProgressStyle.setProgressIndeterminate(true)` 表达；这一行只是
            // 老宿主/读不到 style 的场景下的兜底 extras，兜底也不许画出假满格。
            b.setProgress(100, 0, true)
        }

        applyLiveUpdate(ctx, b, snapshot, ordered.firstOrNull(), maxProgress, !hasPercent)
        val n = b.build()
        // 每次渲染都留一行「我们这条通知**自己合不合条件**」的现场，交给 Dart 写日志。
        //
        // build155 订正口径：这一行**回答不了"系统到底提升了没有"**。
        // `hasPromotableCharacteristics()` 是对通知自身字段的纯计算（ongoing + 标准样式 +
        // 渠道不是 MIN + 不是 group 摘要），build 之后问就有意义；但
        // `FLAG_PROMOTED_ONGOING` 是系统在 posting 时写到**它那份副本**上的标记，
        // 从 `b.build()` 的副本读出来恒为 false —— 上一版把它当结论用，等于拿一条
        // 恒假的对角线判断「这台机器不给岛」。那一半改由 [postedDiag] 从
        // `activeNotifications` 回读，见 [LiveTaskPlugin] 的 `syncTasks` / `liveDiag`。
        lastDiag = diagnose(ctx, n)
        return n
    }

    /** 上一次渲染的诊断串（由 `LiveTaskPlugin.syncTasks` 带回 Dart 写日志）。 */
    @Volatile
    var lastDiag: String = ""
        private set

    /**
     * 「这条通知有没有资格被提升成 Live Update」的现场。
     *
     * 三个数各自回答一个问题：
     * - `canPost` = 用户/厂商**允不允许本应用**发提升通知（ColorOS 那个开关、OEM 策略都算在这）；
     * - `promotable` = 这条通知**本身**够不够格（ongoing + 标准样式 + 渠道不是 MIN + 不是 group 摘要）；
     * - `localPromotedFlag` = ⚠️ **在本副本上恒为 false，没有判读价值**（系统在 posting 时才写这个
     *   标记，写的还是它自己那份副本）。build155 起改了键名，就是为了不再冒充系统结论；
     *   真正的结论看 [postedDiag] 输出的 `promotedFlag=`。
     * 三者组合能把「没有岛」分成三类原因：应用被关 / 我们写法不合条件 / 厂商就是不给渲染 ——
     * 但第三类**只能由 [postedDiag] 判**，别拿本函数的 `localPromotedFlag=false` 当证据。
     */
    private fun diagnose(ctx: Context, n: Notification): String {
        val sdk = Build.VERSION.SDK_INT
        if (sdk < 36) return "sdk=$sdk 不支持 Live Updates，按普通进度通知渲染"
        return try {
            val mgr = manager(ctx)
            val canPost = try {
                mgr.canPostPromotedNotifications()
            } catch (t: Throwable) {
                false
            }
            val promoted = (n.flags and Notification.FLAG_PROMOTED_ONGOING) != 0
            // `localPromotedFlag` 而不是 `promotedFlag`（build155）：这个名字在日志里
            // 曾经冒充系统判定，害得排查往不存在的 API 上带。系统那一半只由
            // [postedDiag] 以 `promotedFlag=` 的键名输出，Dart 侧据此解析，不再有两处同名。
            "sdk=$sdk canPost=$canPost promotable=${n.hasPromotableCharacteristics()} " +
                // `Notification.getStyle()` 不是公开 API，问不出来；改读 extras 里的模板类名 ——
                // 它才是框架侧真正生效的样式（compat 在 36 上会映射到 `Notification$ProgressStyle`）。
                "localPromotedFlag=$promoted template=${n.extras?.getString(Notification.EXTRA_TEMPLATE)?.substringAfterLast('.')} " +
                "ongoing=${n.flags and Notification.FLAG_ONGOING_EVENT != 0} " +
                "channel=${n.channelId} notifEnabled=${notificationsEnabled(ctx)}"
        } catch (t: Throwable) {
            // 判据 API 本身抛异常也要留痕：静默 = 不可排查
            "sdk=$sdk 诊断失败 ${t.javaClass.simpleName}: ${t.message}"
        }
    }

    /**
     * **系统侧**回读那条常驻通知（build155 新增，真机导出逼出来的）。
     *
     * 为什么 [diagnose] 不够：它量的是我们刚 `build()` 出来的那个对象，而
     * `FLAG_PROMOTED_ONGOING` 是**系统在 posting 时才往它自己那份副本上写的标记**，
     * 从自己造的副本读它恒为 false —— 与设备给不给岛毫无关系。
     * build154 那份导出里 `promotedFlag=false` 就是这么来的：一条恒假的读数，
     * 差点把「岛没提升」的排查带去 `setForegroundServiceId` 这种**本机 SDK 里根本
     * 不存在**的 API（android-36 `android.jar` javap 实测只有
     * `setForegroundServiceBehavior`，没有任何 `setForegroundServiceId`）。
     *
     * 只读、不贴、不起服务 ⇒ 可以在任意时刻（含切后台那一刻）调用。
     * 读不到就是读不到，也要把"读不到"写成一行 —— 不许回空串让 Dart 侧静默。
     */
    fun postedDiag(ctx: Context): String {
        val sdk = Build.VERSION.SDK_INT
        return try {
            val arr = manager(ctx).activeNotifications
            val mine = arr?.firstOrNull {
                it.id == ID_ONGOING || it.id == ID_ONGOING_FALLBACK
            }
            if (mine == null) {
                // `active=0` 本身就是结论：常驻条此刻不在系统手里
                // （服务没起来 / 已被撤 / 厂商把整组通知吞了）。
                "active=${arr?.size ?: -1} 常驻条不在活动列表"
            } else {
                val n = mine.notification
                val base = "active=${arr?.size ?: 0} id=${mine.id} " +
                    "ongoing=${(n.flags and Notification.FLAG_ONGOING_EVENT) != 0} " +
                    "summary=${(n.flags and Notification.FLAG_GROUP_SUMMARY) != 0} " +
                    "template=${n.extras?.getString(Notification.EXTRA_TEMPLATE)?.substringAfterLast('.')}"
                if (sdk < 36) {
                    // 36 以下这两个判定不存在，读了会抛 NoSuchMethod/FieldError —— 别读。
                    "$base 无LiveUpdates(sdk=$sdk)"
                } else {
                    "$base promotedFlag=${(n.flags and Notification.FLAG_PROMOTED_ONGOING) != 0} " +
                        "promotable=${n.hasPromotableCharacteristics()}"
                }
            }
        } catch (t: Throwable) {
            "活动通知回读失败 ${t.javaClass.simpleName}: ${t.message}"
        }
    }

    /**
     * 腿 B：Android 16 的 Live Updates（`ProgressStyle` + promoted ongoing）。
     *
     * 全部包在 try/catch 里 —— 这一族的语义我只能在**这台机器的 android.jar / AAR** 上核对，
     * 真机（尤其非 Pixel ROM）表现是本期验收项。任何一步失败 ⇒ 退化成上面那条普通进度通知，
     * **绝不能让通知更新这件事把 App 弄崩**。
     */
    private fun applyLiveUpdate(
        ctx: Context,
        b: NotificationCompat.Builder,
        snapshot: JSONObject,
        // build153：分段条与端点图标跟的是**标题那一行**（`renderOngoing` 里排好序的
        // 第一份任务），不是"快照里恰好排第 0 的那份"。取 tasks[0] 会画成两张皮：
        // 刚结束那条停在 0 号 ⇒ 岛上挂 ✓ 完成符，而标题与进度说的还是正在跑的那件。
        head: JSONObject?,
        percent: Int,
        indeterminate: Boolean,
    ) {
        if (Build.VERSION.SDK_INT < 36) return // 低版本按系统规则自动退化为普通通知
        if (!snapshot.optBoolean("promoted", true)) return
        try {
            b.setRequestPromotedOngoing(true)
            // `ProgressStyle.setProgress(int)` 只吃一个参数（javap 实测 1.18.0 的签名）：
            // 它表达的是**百分比**本身，不像 Builder.setProgress(max, prog, indeterminate)。
            // 不确定态必须走 `setProgressIndeterminate(true)` —— 上一版把 -1 硬夹成 0，
            // 于是深度研究/视频/备份这些**没有字节进度**的任务会在 Android 16 上显示成
            // 「一条 0% 的假进度条」（普通通知那侧反而是对的不确定条）——
            // 违反本文件自己定的口径：不确定态不许显示假百分比。
            val style = NotificationCompat.ProgressStyle()
            if (indeterminate || percent < 0) {
                style.setProgressIndeterminate(true)
            } else {
                style.setProgress(percent.coerceIn(0, 100))
            }
            val first = head
            // build152（用户原话「一直是准备中，下面一条线有什么用」）：一根不确定条
            // 是**没有字节进度的那类任务**（编排 / 研究 / 备份）在岛上全部能说的东西，
            // 跑十分钟与刚起步长得一模一样。ProgressStyle 真正多出来的表达力是**分段**：
            // 每段一个相对长度 + 一个颜色（javap 实测只有 Segment(length)/setId/setColor，
            // 没有"高亮当前段"这种入口），所以把 Dart 传来的 stages 落成"第几段走完了"。
            // 不确定态**照样分段**：那正是唯一需要分段的那类任务，别把它关掉。
            if (first != null) {
                val segments = stageSegments(first.optJSONArray("stages"), accentArgb(ctx))
                if (segments != null) style.setProgressSegments(segments)
                // build152（用户原话「完成之后…也没显示完成√」）：终态才挂图标，
                // 进行中不挂 —— 一条还在跑的行右边出现完成符就是假消息
                // （与本文件上面「不许画假百分比」是同一条口径）。
                // 图标落在 end 位是这族 API 的全部能力（javap 实测只有 tracker/start/end 三个
                // 槽位，没有"跟着进度头走"的入口）：具体落在屏幕哪个位置真机才能定，
                // 与整族 ProgressStyle 一样列进本期真机验收项。
                //
                // build168 ①（#97）：**done/ok 两个布尔之外还有第三态**。
                // 旧写法是一句 `ok ? ic_live_done : ic_live_fail` 的二分 ⇒ 一轮结束在
                // 反问上时 `ok=true`（它确实没坏），于是那一格挂上了勾 ——
                // 机主看到的「反问轮被写成已完成」就是这一行画出来的。
                // 判据读 Dart 传来的 `waitingUser`（写的 key 与读的 key 必须逐字相同，
                // 由 `test/build170_island_waiting_user_test.dart` 把两端串起来），
                // 并且**排在最前**：三态里只有它是两个布尔**编码不出来**的那一个
                // （`ok=true` 会给它挂勾、`ok=false` 会给它挂叉，两个都是谎）。
                // 缺字段（旧包 / 别的下发方）时 `optBoolean` 默认 false ⇒ 逐字节退回
                // 原来的二分，不会凭空多出第三枚图标。
                if (first.optBoolean("done", false)) {
                    val icon = when {
                        first.optBoolean("waitingUser", false) -> R.drawable.ic_live_action
                        first.optBoolean("ok", true) -> R.drawable.ic_live_done
                        else -> R.drawable.ic_live_fail
                    }
                    style.setProgressEndIcon(IconCompat.createWithResource(ctx, icon))
                }
            }
            b.setStyle(style)
        } catch (t: Throwable) {
            // 静默退化，但留一行可排查的痕迹（本项目口径：静默 = 不可排查）
            android.util.Log.w("LiveNotification", "ProgressStyle 未生效，退回普通进度通知: ${t.javaClass.simpleName} ${t.message}")
        }
    }

    /**
     * `stages`（Dart 传来的 `[{"label","done"}...]`）→ 分段条的段表。
     *
     * 规则与 `live_task_center.dart` 的 `liveStageSegments()` **逐条同口径**
     * （跨语言没法共用代码，两边由 `test/build142_live_task_test.dart` 的锚点钉住）：
     * 少于 2 段返回 null（宿主自己画连续条更好看）、上限 [LIVE_SEGMENT_CAP] 段、
     * 超出的合并进最后一段、合并段**全完成才算完成**。
     * 全程只用 `opt*`：JSON 形状被 Dart 侧改坏时这里是 null / 未完成，不抛异常。
     */
    private fun stageSegments(
        stages: org.json.JSONArray?,
        accentArgb: Int,
    ): ArrayList<NotificationCompat.ProgressStyle.Segment>? {
        if (stages == null || stages.length() < 2) return null
        val total = stages.length()
        val head = minOf(total, LIVE_SEGMENT_CAP - 1)
        val dim = (accentArgb and 0x00FFFFFF) or (DIM_ALPHA shl 24)
        val out = ArrayList<NotificationCompat.ProgressStyle.Segment>(LIVE_SEGMENT_CAP)
        // 段长一律给 1（Segment 吃的是**相对权重**不是像素）⇒ 等长分段
        for (i in 0 until head) {
            val done = stages.optJSONObject(i)?.optBoolean("done", false) == true
            out.add(
                NotificationCompat.ProgressStyle.Segment(1)
                    .setId(i + 1)
                    .setColor(if (done) accentArgb else dim)
            )
        }
        val merged = total - head
        if (merged > 0) {
            var allDone = true
            for (i in head until total) {
                if (stages.optJSONObject(i)?.optBoolean("done", false) != true) allDone = false
            }
            out.add(
                NotificationCompat.ProgressStyle.Segment(merged)
                    .setId(head + 1)
                    .setColor(if (allDone) accentArgb else dim)
            )
        }
        return out
    }

    /**
     * 完成段的颜色：问主题要强调色，问不到用 [ACCENT_FALLBACK]。
     *
     * 未完成段不另选颜色，而是把同一个强调色**压淡**（[DIM_ALPHA]）—— 不换灰：
     * 两段同色相，用户才会把它们读成"同一条进度的前后截"，换成灰会读成
     * "另一条东西 / 这条被禁用了"。压淡而不是写死一个灰值，是因为通知底色
     * 深浅两套都有，写死必有一套看不见（与 `ic_live_done.xml` 不写 tint 同一条理由）。
     */
    private fun accentArgb(ctx: Context): Int = try {
        val tv = android.util.TypedValue()
        val hit = ctx.theme.resolveAttribute(android.R.attr.colorAccent, tv, true)
        if (hit && tv.data != 0) tv.data else ACCENT_FALLBACK
    } catch (t: Throwable) {
        // 主题问不到就用兜底蓝：这族 API 猜错只该让通知变朴素，不该让上报错崩在渲染里
        ACCENT_FALLBACK
    }

    /** 完成 / 失败 / 待回答：一次性高打扰通知，点进去直达对应页面。 */
    fun postAlert(
        ctx: Context, id: Int, title: String, body: String, route: String, ongoing: Boolean
    ) {
        ensureChannels(ctx)
        val b = NotificationCompat.Builder(ctx, CHANNEL_ALERT)
            .setSmallIcon(smallIcon(ctx))
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setAutoCancel(!ongoing)
            .setOngoing(ongoing)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(openIntent(ctx, route))
        safeNotify(ctx, id, b.build())
    }

    /**
     * 前台服务起不来时的退路：把它当**普通通知**贴上去（不占常驻通知位的服务语义）。
     *
     * 存在的意义是「宁可少承诺一点后台存活，也不要什么都不显示」——
     * 用户在 Android 12+ 的后台限制下点过下载又立刻切走时，仍能看见一条进度通知。
     */
    fun notifyOngoingDirect(ctx: Context, snapshot: JSONObject) {
        safeNotify(ctx, ID_ONGOING_FALLBACK, renderOngoing(ctx, snapshot))
    }

    fun cancel(ctx: Context, id: Int) {
        try {
            NotificationManagerCompat.from(ctx).cancel(id)
        } catch (t: Throwable) {
            android.util.Log.w("LiveNotification", "cancel($id) 失败: ${t.message}")
        }
    }

    private fun safeNotify(ctx: Context, id: Int, n: Notification) {
        // Android 13+ 没给 POST_NOTIFICATIONS 时 notify() 会抛 SecurityException，
        // 而不是静默不显示 ⇒ 必须自己兜住：没权限就不报，别把异常抛回 Dart 调用链。
        if (!notificationsEnabled(ctx) && !hasPostPermission(ctx)) return
        try {
            NotificationManagerCompat.from(ctx).notify(id, n)
        } catch (t: SecurityException) {
            android.util.Log.w("LiveNotification", "无通知权限，已跳过：${t.message}")
        } catch (t: Throwable) {
            android.util.Log.w("LiveNotification", "notify 失败: ${t.message}")
        }
    }

    private fun hasPostPermission(ctx: Context): Boolean = try {
        androidx.core.content.ContextCompat.checkSelfPermission(
            ctx, android.Manifest.permission.POST_NOTIFICATIONS
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED
    } catch (t: Throwable) {
        true // 老版本无此权限模型：当作有，交给 areNotificationsEnabled 判断
    }

    /// requestCode 按路由分开：不同目的地的通知必须各自带回自己的 route，
    /// 全部复用同一个 requestCode 会让「点哪条都跳最后注册的那个页面」。
    private fun openIntent(ctx: Context, route: String): PendingIntent {
        val intent = Intent(ctx, MainActivity::class.java).apply {
            action = ACTION_OPEN
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra(EXTRA_ROUTE, route)
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        return PendingIntent.getActivity(ctx, route.hashCode() and 0xFFFF, intent, flags)
    }

    private fun smallIcon(ctx: Context): Int {
        // build153（用户「兼容按 OPPO 和谷歌来」）：改用自己的**白色剪影** vector
        // （`ic_stat_nexus.xml` 里把当年那条"避开 vector"的理由与本轮实测的 minSdk=24 一起写着）。
        // 两家的规范在这一条上是同一个要求：Google 要"小图标是白色剪影"（系统按 alpha 着色，
        // 彩色 mipmap 带不透明底会被涂成一整块），OPPO 的胶囊左边那位 [A]/[A1*] 也要**可着色的
        // 服务图标**，且 [A1*] 必配（AOD / 手表 / 气泡态兜底）。
        // 资源找不到时（理论上不会发生）退回原来的"一定有"那条路，不让通知因为一个图标炸掉。
        return try {
            val id = R.drawable.ic_stat_nexus
            if (id != 0) id else legacyIcon(ctx)
        } catch (t: Throwable) {
            legacyIcon(ctx)
        }
    }

    /** 旧口径：应用自身图标（彩色 mipmap），再兜底系统下载图标。只留给上面那个 catch 分支。 */
    private fun legacyIcon(ctx: Context): Int {
        val id = try {
            ctx.applicationInfo.icon
        } catch (t: Throwable) {
            0
        }
        return if (id == 0) android.R.drawable.stat_sys_download else id
    }

}
