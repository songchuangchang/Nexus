package com.example.aichat

import android.content.Intent
import android.content.pm.ApplicationInfo
import android.net.Uri
import android.os.Bundle
import android.os.StrictMode
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * build123：接收「其他 App 分享到 Nexus」的载荷。
 *
 * 为什么自建通道而不用三方分享插件：
 * 需求只有「取载荷 + 文件落私有目录」两件事，而三方插件普遍要求改 launchMode 语义、
 * 自带 FileProvider 与生命周期假设；本项目对新增依赖的代价有实测（pub add 会触发
 * pub get 删掉 l10n 生成产物，已复现两次）。自建通道行为完全可控。
 *
 * 关键设计：**文件必须复制到应用私有目录**，不能把 content:// 交给 Dart。
 * 分享 URI 的读权限随 Intent 生命周期失效，而用户完全可能「先插入输入框、过几分钟
 * 才点发送」——那时再读 URI 会拿到空文件或抛 SecurityException。
 */
class MainActivity : FlutterFragmentActivity() {
    companion object {
        private const val CHANNEL = "nexus/share_intent"
    }

    private var channel: MethodChannel? = null

    /** 冷启动收到的分享：Dart 侧尚未就绪，先缓冲，由 getInitialShare 取走 */
    private var pendingShare: Map<String, Any?>? = null

    /** Dart 侧 handler 注册完成（它会在 init 后立刻调 getInitialShare） */
    private var flutterReady = false

    /**
     * build142（灵动岛）：后台进度通知的通道。
     * 用 provider 闭包而不是直接捕获 `this`，是因为回调可能落在 Activity 销毁之后
     * （点通知 → 系统重建 Activity → 旧的还在收尾），那时必须拿到**当前**实例。
     */
    private val liveTask = LiveTaskPlugin(
        activityProvider = { this },
        appContext = { applicationContext },
    )

    // v1.7.24（十大维度·性能）：Debug 下开启 StrictMode 主线程磁盘/网络访问监控，
    // 提前抓出卡顿根因（主线程 IO / 泄漏的 SQLite/Closable/Activity）。
    override fun onCreate(savedInstanceState: Bundle?) {
        // build160（真机 11:04 那份导出定到的根因候选）：整台机器上键盘从来没被我们看见 ——
        // 输入框伸缩的九轮里，`viewInsets.bottom` 恒 0、窗口高度恒 932、`keyboardUp=false`
        // 而 `focused=true`；框其实照常长缩（31 字 119 / 97 字 176 / 10 换行 290），
        // 只是**涨到键盘后面去了**，所以用户读到的永远是"不涨不缩"。
        // 这台是 Android 16（targetSdk 36）：`windowOptOutEdgeToEdgeEnforcement` 那道
        // 退路在新版本已经被拿掉，只能显式告诉窗口"装饰不归你管，insets 往下派"。
        // 为什么不是 `WindowCompat.setDecorFitsSystemWindows`：那是 androidx.core 的扩展，
        // 本仓没引 `core-ktx` 依赖 —— 为一个布尔拉一条新依赖不值得（而且引依赖在本项目有实测代价：
        // `pub add` 会连带删掉 l10n 生成产物，已复现两次）。API 30 以下保持原行为不动。
        if (android.os.Build.VERSION.SDK_INT >= 30) {
            window.setDecorFitsSystemWindows(false)
        }
        val isDebug = (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        if (isDebug) {
            StrictMode.setThreadPolicy(
                StrictMode.ThreadPolicy.Builder()
                    .detectDiskReads()
                    .detectDiskWrites()
                    .detectNetwork()
                    .penaltyLog()
                    .build()
            )
            StrictMode.setVmPolicy(
                StrictMode.VmPolicy.Builder()
                    .detectLeakedSqlLiteObjects()
                    .detectLeakedClosableObjects()
                    .detectActivityLeaks()
                    .penaltyLog()
                    .build()
            )
        }
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // build142（灵动岛）：后台进度通知的双向通道
        liveTask.configure(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                // 冷启动取件：取走并清空，保证同一份载荷只被处理一次
                "getInitialShare" -> {
                    flutterReady = true
                    val p = pendingShare
                    pendingShare = null
                    result.success(p)
                }
                "clearInitialShare" -> {
                    pendingShare = null
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        // 冷启动：Activity 的启动 Intent 本身就是分享 Intent
        handleShareIntent(intent, warm = false)
        // 冷启动点通知：路由先缓冲，等 Dart 调 getInitialRoute 取走
        liveTask.handleOpenIntent(intent, warm = false)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        // 热启动：App 已在后台/前台，把载荷推给 Dart（它决定插到哪个会话）
        handleShareIntent(intent, warm = true)
        // build142：点常驻/完成通知回到前台也走这里
        liveTask.handleOpenIntent(intent, warm = true)
    }

    private fun handleShareIntent(intent: Intent?, warm: Boolean) {
        val payload = extractShare(intent) ?: return
        if (warm && flutterReady) {
            channel?.invokeMethod("onShare", payload)
        } else {
            // Dart 未就绪（或冷启动）→ 缓冲，等 getInitialShare 来取
            pendingShare = payload
        }
    }

    /** 把 Intent 归一成 Dart 侧载荷；不是分享 Intent 或取不到内容时返回 null */
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        // build142：Android 13+ 的 POST_NOTIFICATIONS 走原生申请。
        // **不引 permission_handler** —— 全仓只留一条权限申请路径（HANDOVER 雷区）。
        val granted = grantResults.isNotEmpty() && grantResults[0] ==
            android.content.pm.PackageManager.PERMISSION_GRANTED
        liveTask.onPermissionResult(requestCode, granted)
    }

    private fun extractShare(intent: Intent?): Map<String, Any?>? {
        if (intent == null) return null
        val action = intent.action
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) return null

        // 1) 文件优先：带 EXTRA_STREAM / ClipData 就是文件分享
        val uris = collectStreamUris(intent)
        if (uris.isNotEmpty()) {
            val copied = copyToPrivateStorage(uris.first())
            if (copied == null) {
                // 复制失败必须回执，让 Dart 侧如实提示——静默丢弃会让用户
                // 以为「分享了但没反应」（本项目历史上反复出现的假完成形态）
                return mapOf(
                    "kind" to "file",
                    "error" to "copy_failed",
                    "mimeType" to (intent.type ?: ""),
                    "extraCount" to uris.size,
                )
            }
            return mapOf(
                "kind" to "file",
                "filePath" to copied.first,
                "fileName" to copied.second,
                "sizeBytes" to copied.third,
                "mimeType" to (intent.type ?: ""),
                "extraCount" to uris.size,
            )
        }

        // 2) 文本 / 网址：原样交给 Dart 粘进输入框
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
            ?: intent.clipData
                ?.takeIf { it.itemCount > 0 }
                ?.getItemAt(0)
                ?.coerceToText(this)
                ?.toString()
        if (!text.isNullOrBlank()) {
            return mapOf("kind" to "text", "text" to text)
        }
        return null
    }

    @Suppress("DEPRECATION")
    private fun collectStreamUris(intent: Intent): List<Uri> {
        val out = mutableListOf<Uri>()
        intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let { out.add(it) }
        intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { out.addAll(it) }
        intent.clipData?.let { cd ->
            for (i in 0 until cd.itemCount) {
                cd.getItemAt(i).uri?.let { out.add(it) }
            }
        }
        return out.distinct()
    }

    /**
     * 复制分享文件到 `cacheDir/shared_in/`。
     *
     * 文件名加时间戳前缀：多选分享时原始文件名可能重复，直接落同名会互相覆盖，
     * 用户看到的两个附件会变成同一个内容。
     *
     * @return (绝对路径, 展示用文件名, 字节数)；失败返回 null
     */
    private fun copyToPrivateStorage(uri: Uri): Triple<String, String, Long>? {
        return try {
            val displayName = sanitize(
                queryDisplayName(uri) ?: "shared_${System.currentTimeMillis()}"
            )
            val dir = File(cacheDir, "shared_in")
            if (!dir.exists() && !dir.mkdirs()) return null
            val target = File(dir, "${System.currentTimeMillis()}_$displayName")
            val input = contentResolver.openInputStream(uri) ?: return null
            input.use { src ->
                target.outputStream().use { dst -> src.copyTo(dst) }
            }
            Triple(target.absolutePath, displayName, target.length())
        } catch (t: Throwable) {
            null
        }
    }

    private fun queryDisplayName(uri: Uri): String? {
        return try {
            contentResolver.query(
                uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null
            )?.use { c ->
                if (c.moveToFirst()) {
                    val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0) c.getString(idx) else null
                } else null
            }
        } catch (t: Throwable) {
            null
        }
    }

    /** 去掉路径分隔符与控制字符（防止 `../` 之类把文件写出目标目录） */
    private fun sanitize(name: String): String {
        val cleaned = name.replace(Regex("[\\\\/:*?\"<>|\\u0000-\\u001F]"), "_").trim()
        return if (cleaned.isEmpty()) "shared_file" else cleaned.take(120)
    }
}
