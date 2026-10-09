package dev.oriel

import android.app.ActivityManager
import android.app.ActivityOptions
import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ComponentCallbacks2
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Rect
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import android.util.Log
import android.view.WindowManager
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileNotFoundException

/**
 * The Android side of Oriel. Zig (src/platform/android) calls the
 * `@JvmStatic` methods below over JNI, always on the main thread; Kotlin
 * calls back through [NativeLib]. Windows are kept here by id; their
 * Activities come and go ([OrielActivity]).
 */
object OrielRuntime {
    /** How long a started window Activity counts as pending (it normally attaches within a second). */
    private const val LAUNCH_PENDING_MS = 5000L
    private const val TAG = "Oriel"
    const val EXTRA_WINDOW = "dev.oriel.window"
    const val EXTRA_NOTIFICATION = "dev.oriel.notification"
    const val EXTRA_NOTIFICATION_CODE = "dev.oriel.notification.code"
    const val EXTRA_ARGS = "dev.oriel.args"
    private const val CHANNEL = "oriel"
    /** espeak-ng's compiled data (-Dkokoro), shipped as assets. */
    private const val ESPEAK_DATA = "espeak-ng-data"

    internal lateinit var app: Application
        private set
    private val main = Handler(Looper.getMainLooper())
    private var loaded = false
    internal val windows = HashMap<Int, OrielWindow>()
    private var mainWindow: OrielWindow? = null
    /** The launcher Activity (the main window's), once created. */
    private var mainActivity: OrielActivity? = null
    /** The Activity in front (for permission prompts and pickers). */
    internal var foreground: OrielActivity? = null

    // ---------------------------------------------------------------------
    // Lifecycle (from OrielActivity)
    // ---------------------------------------------------------------------

    internal fun onActivityCreated(activity: OrielActivity, intent: Intent) {
        ensureLoaded(activity)
        if (activity is OrielWindowActivity) {
            val w = windows[intent.getIntExtra(EXTRA_WINDOW, -1)]
            if (w == null || w.destroyed) activity.finishByRuntime() else w.attachTo(activity)
            return
        }
        mainActivity = activity
        mainWindow?.let { if (!it.destroyed) it.attachTo(activity) }
        val args = argsOf(intent)
        extractAssetDir(ESPEAK_DATA)
        when (NativeLib.start(app.filesDir.path.bytes(), app.cacheDir.path.bytes(), (app.getExternalFilesDir(null)?.path ?: "").bytes(), args)) {
            1 -> {
                Log.i(TAG, "started")
                // A tap that launched the app: Zig holds it until the app's
                // handler and page listen (notification/common.zig).
                notificationTap(intent, direct = true)
            }
            2 -> {
                if (args.isNotEmpty()) NativeLib.onNewIntent(args)
                notificationTap(intent)
            }
            else -> Log.e(TAG, "liboriel.so failed to start (see the log above)")
        }
    }

    internal fun onActivityNewIntent(activity: OrielActivity, intent: Intent) {
        if (activity is OrielWindowActivity) return
        NativeLib.onNewIntent(argsOf(intent))
        notificationTap(intent)
    }

    internal fun onActivityDestroyed(activity: OrielActivity) {
        if (mainActivity === activity) mainActivity = null
        if (foreground === activity) foreground = null
    }

    /**
     * Copy the APK's `assets/<name>/` to `<filesDir>/<name>/` for native code
     * that reads files (espeak-ng-data with -Dkokoro:
     * src/modules/tts/espeak_data.zig). Once per install or update (the
     * package's lastUpdateTime, kept in a marker file); apps without the
     * assets skip it. Copied to a temporary directory first, so an
     * interrupted copy is redone on the next start.
     */
    private fun extractAssetDir(name: String) {
        val names = try { app.assets.list(name) } catch (e: java.io.IOException) { null }
        if (names.isNullOrEmpty()) return
        val stamp = try {
            @Suppress("DEPRECATION")
            app.packageManager.getPackageInfo(app.packageName, 0).lastUpdateTime.toString()
        } catch (e: Exception) { "0" }
        val dest = File(app.filesDir, name)
        val marker = File(dest, ".oriel-assets")
        if (marker.isFile && marker.readText() == stamp) return
        val tmp = File(app.filesDir, "$name.tmp")
        try {
            tmp.deleteRecursively()
            copyAssets(name, tmp)
            File(tmp, ".oriel-assets").writeText(stamp)
            dest.deleteRecursively()
            if (!tmp.renameTo(dest)) throw java.io.IOException("cannot rename $tmp")
        } catch (e: Exception) {
            Log.e(TAG, "extracting assets/$name: $e")
            tmp.deleteRecursively()
        }
    }

    /** An asset file or directory (`list` is empty for a file) to `to`. */
    private fun copyAssets(path: String, to: File) {
        val children = app.assets.list(path) ?: emptyArray()
        if (children.isEmpty()) {
            app.assets.open(path).use { input -> to.outputStream().use { input.copyTo(it) } }
            return
        }
        if (!to.isDirectory && !to.mkdirs()) throw java.io.IOException("cannot create $to")
        for (child in children) copyAssets("$path/$child", File(to, child))
    }

    private fun ensureLoaded(context: Context) {
        if (loaded) return
        app = context.applicationContext as Application
        System.loadLibrary("oriel")
        loaded = true
        app.registerComponentCallbacks(TrimMemory)
    }

    /**
     * Memory pressure to Zig as the "trim-memory" system event (data: the
     * level): liboriel.so purges malloc's caches, and the app may drop its
     * own (src/platform/android/android.zig).
     */
    private object TrimMemory : ComponentCallbacks2 {
        override fun onTrimMemory(level: Int) = NativeLib.onSystemEvent("trim-memory".bytes(), level.toString().bytes())
        override fun onConfigurationChanged(newConfig: Configuration) {}
        @Suppress("OVERRIDE_DEPRECATION", "DEPRECATION") // Before Android 14 only; the same as TRIM_MEMORY_COMPLETE.
        override fun onLowMemory() = onTrimMemory(ComponentCallbacks2.TRIM_MEMORY_COMPLETE)
    }

    /** A launch's arguments: the intent's data URI (a deep link) and `dev.oriel.args`. */
    private fun argsOf(intent: Intent): Array<ByteArray> {
        val list = mutableListOf<ByteArray>()
        intent.getStringArrayExtra(EXTRA_ARGS)?.forEach { list += it.bytes() }
        intent.dataString?.let { list += it.bytes() }
        return list.toTypedArray()
    }

    // ---------------------------------------------------------------------
    // Windows (src/platform/android/window.zig)
    // ---------------------------------------------------------------------

    @JvmStatic
    fun createWindow(
        id: Int, label: ByteArray, title: ByteArray, url: ByteArray,
        width: Int, height: Int, minWidth: Int, minHeight: Int, flags: Int,
        script: ByteArray, rules: ByteArray,
    ): Boolean {
        val w = try {
            OrielWindow(
                id, label.utf8(), title.utf8(), url.utf8(), width, height, minWidth, minHeight, flags,
                script.utf8(), rules.utf8().split('\n').filter { it.isNotEmpty() }.toSet(),
            )
        } catch (e: Exception) {
            Log.e(TAG, "cannot create the window's view (is Android System WebView installed?)", e)
            return false
        }
        windows[id] = w
        if (w.isMain) {
            mainWindow = w
            mainActivity?.let { w.attachTo(it) }
            rememberMainSize(w.width, w.height)
        }
        if (!w.native) w.load(w.url)
        return true
    }

    @JvmStatic
    fun destroyWindow(id: Int) {
        val w = windows.remove(id) ?: return
        if (mainWindow === w) mainWindow = null
        w.destroy()
    }

    @JvmStatic
    fun showWindow(id: Int) {
        val w = windows[id] ?: return
        val host = w.activity
        if (host != null && !host.isFinishing) {
            bringToFront(host)
            return
        }
        // Already starting (show then focus, before the Activity attached):
        // a second start would open a second, empty Activity for the window.
        val now = SystemClock.uptimeMillis()
        if (w.launchedAt != 0L && now - w.launchedAt < LAUNCH_PENDING_MS) return
        val intent = if (w.isMain) {
            Intent(app, OrielMainActivity::class.java)
        } else {
            val cls = if (w.translucent) OrielTransparentWindowActivity::class.java else OrielWindowActivity::class.java
            Intent(app, cls).putExtra(EXTRA_WINDOW, id)
                .addFlags(Intent.FLAG_ACTIVITY_MULTIPLE_TASK or Intent.FLAG_ACTIVITY_NEW_DOCUMENT)
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            w.launchedAt = now
            app.startActivity(intent, launchBounds(w)?.toBundle())
        } catch (e: Exception) {
            w.launchedAt = 0L
            Log.e(TAG, "cannot show window ${w.label}", e)
        }
    }

    /** The window's size, centered, for desktop windowing (ignored elsewhere). */
    private fun launchBounds(w: OrielWindow): ActivityOptions? = launchBounds(app, w.width, w.height)

    /** A `width`×`height` dp window, centered (ignored outside desktop windowing). */
    fun launchBounds(context: Context, width: Int, height: Int): ActivityOptions? {
        if (width <= 0 || height <= 0) return null
        val wm = context.getSystemService(WindowManager::class.java)
        val screen = if (Build.VERSION.SDK_INT >= 30) wm.maximumWindowMetrics.bounds else Rect(0, 0, context.resources.displayMetrics.widthPixels, context.resources.displayMetrics.heightPixels)
        val pw = minOf(context.px(width), screen.width())
        val ph = minOf(context.px(height), screen.height())
        val left = screen.left + (screen.width() - pw) / 2
        val top = screen.top + (screen.height() - ph) / 2
        return ActivityOptions.makeBasic().setLaunchBounds(Rect(left, top, left + pw, top + ph))
    }

    /**
     * The main window's size as the app asked for it (dp), remembered for
     * the next launch: the launcher starts the app before its code says
     * (OrielLaunchActivity).
     */
    private const val SIZE_PREFS = "dev.oriel.window"

    fun rememberedMainSize(context: Context): Pair<Int, Int>? {
        val p = context.getSharedPreferences(SIZE_PREFS, Context.MODE_PRIVATE)
        val w = p.getInt("main.width", 0)
        val h = p.getInt("main.height", 0)
        return if (w > 0 && h > 0) w to h else null
    }

    private fun rememberMainSize(width: Int, height: Int) {
        if (width <= 0 || height <= 0 || rememberedMainSize(app) == (width to height)) return
        app.getSharedPreferences(SIZE_PREFS, Context.MODE_PRIVATE).edit().putInt("main.width", width).putInt("main.height", height).apply()
    }

    private fun bringToFront(activity: OrielActivity) {
        val am = app.getSystemService(ActivityManager::class.java)
        am.appTasks.firstOrNull { it.taskInfo.taskId == activity.taskId }?.moveToFront()
    }

    @JvmStatic
    fun hideWindow(id: Int) {
        windows[id]?.activity?.moveTaskToBack(true)
    }

    @JvmStatic
    fun isWindowShown(id: Int): Boolean = windows[id]?.isShown ?: false

    @JvmStatic
    fun setTitle(id: Int, title: ByteArray) {
        val w = windows[id] ?: return
        w.title = title.utf8()
        w.activity?.applyTitle(w.title, w.themeColor)
    }

    /** The page's theme-color as ARGB (has: false, none): the window's caption (android/window.zig). */
    @JvmStatic
    fun setThemeColor(id: Int, has: Boolean, argb: Int) {
        val w = windows[id] ?: return
        w.themeColor = if (has) argb else null
        w.activity?.applyTitle(w.title, w.themeColor)
    }

    @JvmStatic
    fun setFullscreen(id: Int, on: Boolean) {
        val w = windows[id] ?: return
        w.fullscreen = on
        w.activity?.applyFullscreen(on)
    }

    @JvmStatic
    fun isFullscreen(id: Int): Boolean = windows[id]?.fullscreen ?: false

    @JvmStatic
    fun setMaximized(id: Int, on: Boolean) {
        windows[id]?.maximized = on
    }

    @JvmStatic
    fun isMaximized(id: Int): Boolean = windows[id]?.maximized ?: false

    /** The launch size the next time the window's Activity starts (dp). */
    @JvmStatic
    fun setSize(id: Int, width: Int, height: Int) {
        val w = windows[id] ?: return
        w.width = width
        w.height = height
    }

    /** (width << 32) | height, in CSS px. */
    @JvmStatic
    fun getSize(id: Int): Long {
        val w = windows[id] ?: return 0
        return (w.cssWidth.toLong() shl 32) or (w.cssHeight.toLong() and 0xffffffffL)
    }

    /** The display's size in dp, packed like [getSize]. */
    @JvmStatic
    fun getWorkArea(id: Int): Long {
        val context: Context = windows[id]?.activity ?: app
        val wm = context.getSystemService(WindowManager::class.java)
        val bounds = if (Build.VERSION.SDK_INT >= 30) wm.maximumWindowMetrics.bounds else Rect(0, 0, context.resources.displayMetrics.widthPixels, context.resources.displayMetrics.heightPixels)
        return (context.dp(bounds.width()).toLong() shl 32) or (context.dp(bounds.height()).toLong() and 0xffffffffL)
    }

    // --- The battery, for power meters (render-bench's power_now) ---

    /**
     * The battery now: its current in µA (BatteryManager's CURRENT_NOW, its
     * sign the device's: most report a discharge as negative) shifted 32,
     * the voltage in mV shifted 1, and 1 while a charger is plugged in.
     * 0: unknown.
     */
    @JvmStatic
    fun batteryNow(): Long {
        val bm = app.getSystemService(BatteryManager::class.java) ?: return 0
        val ua = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_NOW)
        if (ua == Int.MIN_VALUE) return 0
        // The sticky battery broadcast, read without a receiver.
        val i = app.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val mv = i?.getIntExtra(BatteryManager.EXTRA_VOLTAGE, 0) ?: 0
        val plugged = (i?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0) != 0
        return (ua.toLong() shl 32) or ((mv.toLong() and 0x7fffffff) shl 1) or (if (plugged) 1L else 0L)
    }

    /** The battery's charge counter in µAh, or Long.MIN_VALUE when the device has none. */
    @JvmStatic
    fun batteryCharge(): Long {
        val bm = app.getSystemService(BatteryManager::class.java) ?: return Long.MIN_VALUE
        val v = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CHARGE_COUNTER)
        return if (v == Int.MIN_VALUE || v <= 0) Long.MIN_VALUE else v.toLong()
    }

    // --- The native renderer (-Dnative_ui; src/native_ui/android.zig) ---

    @JvmStatic
    fun nuiViewport(id: Int): Long = Nui.viewport(id)

    /** The display's density in thousandths: the page's devicePixelRatio (android.zig withDensity). */
    @JvmStatic
    fun nuiDensity(id: Int): Int = Math.round(((Nui.views[id]?.context ?: windows[id]?.activity ?: app).resources.displayMetrics.density) * 1000)

    @JvmStatic
    fun nuiMeasure(id: Int, node: Int, max64: Int): Long = Nui.views[id]?.measureText(node, max64) ?: 0

    /** The text font's ascent, descent and line gap at `size64` / 64 px, in 1/64 px, 21 bits each (android.zig's fontMetrics). */
    @JvmStatic
    fun nuiFontMetrics(size64: Int, mono: Boolean): Long = NuiNode.fontMetrics(size64 / 64f, mono)

    /** The same in a CSS font-family list's font (as text runs resolve it): a line's strut. */
    @JvmStatic
    fun nuiFontMetricsFamily(size64: Int, mono: Boolean, family: ByteArray): Long = NuiNode.fontMetrics(size64 / 64f, mono, family.utf8())

    /** A text's first baseline in 1/64 dp, or -1 (android.zig's noteBaseline). */
    @JvmStatic
    fun nuiBaseline(id: Int, node: Int): Int = Nui.views[id]?.baselineOf(node) ?: -1

    /** A string's width in 1/64 dp in a font (`ff`, the CSS family list) at
     *  `size64` / 64 px: a select's options (android.zig longestOption). */
    @JvmStatic
    fun nuiTextWidth(text: ByteArray, size64: Int, ff: ByteArray, mono: Boolean): Int {
        val p = android.text.TextPaint(android.graphics.Paint.ANTI_ALIAS_FLAG or android.graphics.Paint.SUBPIXEL_TEXT_FLAG or android.graphics.Paint.LINEAR_TEXT_FLAG)
        p.textSize = size64 / 64f
        p.typeface = NuiNode.family(ff.utf8(), mono)
        return Math.round(p.measureText(text.utf8()) * 64)
    }

    /** Texts' unbounded sizes, all of a frame's at once (android.zig's measureTexts). */
    /** The system's accent colour (ARGB; 0: none) for window `id`'s theme: Material You's on Android 12+. */
    @JvmStatic
    fun nuiAccent(id: Int): Int = Nui.views[id]?.accent() ?: Nui.accent(app)

    @JvmStatic
    fun nuiMeasureTexts(id: Int, nodes: ByteArray): ByteArray = Nui.views[id]?.measureTexts(nodes) ?: ByteArray(0)

    @JvmStatic
    fun nuiProps(id: Int, node: Int, kind: ByteArray, json: ByteArray) {
        Nui.views[id]?.props(node, kind.utf8(), json.utf8())
    }

    /** Leaf styles and the nodes made from them (android.zig's flushLeaves). */
    @JvmStatic
    fun nuiLeaves(id: Int, bytes: ByteArray) {
        Nui.views[id]?.leaves(bytes)
    }

    /** A text node's single run has new text (the direct text bridge, no props JSON). */
    @JvmStatic
    fun nuiText(id: Int, node: Int, text: ByteArray) {
        Nui.views[id]?.text(node, text.utf8())
    }

    @JvmStatic
    fun nuiRemove(id: Int, node: Int) {
        Nui.views[id]?.remove(node)
    }

    @JvmStatic
    fun nuiFrames(id: Int, frames: ByteArray) {
        Nui.views[id]?.frames(frames)
    }

    @JvmStatic
    fun nuiValue(id: Int, node: Int, value: ByteArray) {
        Nui.views[id]?.value(node, value.utf8())
    }

    @JvmStatic
    fun nuiRequestFrame(id: Int) = Nui.requestFrame(id)

    @JvmStatic
    fun nuiTimer(id: Int, timer: Int, ms: Int) = Nui.timer(id, timer, ms)

    @JvmStatic
    fun nuiFocus(id: Int, node: Int) {
        Nui.views[id]?.focusField(node)
    }

    /** A text field's selection in UTF-16 units, start << 32 | end, or -1 (android.zig selection). */
    @JvmStatic
    fun nuiSelection(id: Int, node: Int): Long = Nui.views[id]?.selection(node) ?: -1

    @JvmStatic
    fun nuiSetSelection(id: Int, node: Int, start: Int, end: Int) {
        Nui.views[id]?.setSelection(node, start, end)
    }

    @JvmStatic
    fun evalJs(id: Int, script: ByteArray) {
        windows[id]?.eval(script.utf8())
    }

    @JvmStatic
    fun postMessage(id: Int, json: ByteArray) {
        windows[id]?.post(json.utf8())
    }

    @JvmStatic
    fun loadUrl(id: Int, url: ByteArray) {
        windows[id]?.load(url.utf8())
    }

    /** Dev mode: the dev server may still be starting. */
    @JvmStatic
    fun retryLoad(id: Int, url: ByteArray, delayMs: Int) {
        val u = url.utf8()
        main.postDelayed({ windows[id]?.load(u) }, delayMs.toLong())
    }

    @JvmStatic
    fun openExternal(uri: ByteArray) {
        try {
            app.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(uri.utf8())).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (e: ActivityNotFoundException) {
            Log.w(TAG, "no app opens ${uri.utf8()}")
        }
    }

    /** The app's `main` returned: close what is left. */
    @JvmStatic
    fun onExit(code: Int) {
        Log.i(TAG, "exited with $code")
        for (w in windows.values.toList()) w.destroy()
        windows.clear()
        mainWindow = null
        mainActivity?.finishByRuntime()
        mainActivity = null
    }

    // ---------------------------------------------------------------------
    // Permissions (src/core/permissions/android.zig)
    // ---------------------------------------------------------------------

    @JvmStatic
    fun permissionStatus(kind: Int): Int = OrielPermissions.status(kind)

    @JvmStatic
    fun requestPermission(kind: Int): Boolean = OrielPermissions.request(kind)

    @JvmStatic
    fun openPermissionSettings(kind: Int): Boolean = OrielPermissions.openSettings(kind)

    // ---------------------------------------------------------------------
    // Clipboard (src/plugins/clipboard/android.zig)
    // ---------------------------------------------------------------------

    private val clipboard get() = app.getSystemService(ClipboardManager::class.java)

    /** The Oriel activity that has window focus, if one does. */
    private var focused: OrielActivity? = null

    fun focusChanged(activity: OrielActivity, hasFocus: Boolean) {
        if (hasFocus) focused = activity else if (focused === activity) focused = null
    }

    /**
     * Whether one of the app's windows has input focus: Android 10+ lets only
     * the focused app read the clipboard (else it reads as empty).
     */
    @JvmStatic
    fun hasFocus(): Boolean = focused?.let { !it.isFinishing && it.hasWindowFocus() } ?: false

    @JvmStatic
    fun clipboardReadText(): ByteArray? {
        val clip = clipboard.primaryClip ?: return null
        if (clip.itemCount == 0) return null
        return clip.getItemAt(0).coerceToText(app)?.toString()?.bytes()
    }

    @JvmStatic
    fun clipboardWriteText(text: ByteArray): Boolean {
        clipboard.setPrimaryClip(ClipData.newPlainText("text", text.utf8()))
        return true
    }

    /** The first image of the clip, as PNG. */
    @JvmStatic
    fun clipboardReadImage(): ByteArray? {
        val clip = clipboard.primaryClip ?: return null
        for (i in 0 until clip.itemCount) {
            val uri = clip.getItemAt(i).uri ?: continue
            val type = app.contentResolver.getType(uri) ?: continue
            if (!type.startsWith("image/")) continue
            return try {
                app.contentResolver.openInputStream(uri)?.use { input ->
                    val bitmap = BitmapFactory.decodeStream(input) ?: return null
                    ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
                }
            } catch (e: Exception) {
                Log.w(TAG, "cannot read the clipboard image", e)
                null
            }
        }
        return null
    }

    @JvmStatic
    fun clipboardWriteImage(png: ByteArray): Boolean {
        return try {
            val file = OrielFileProvider.newFile(app, "clipboard", "image.png")
            file.writeBytes(png)
            val uri = OrielFileProvider.uriFor(app, file)
            clipboard.setPrimaryClip(ClipData.newUri(app.contentResolver, "image", uri))
            true
        } catch (e: Exception) {
            Log.w(TAG, "cannot put the image on the clipboard", e)
            false
        }
    }

    // ---------------------------------------------------------------------
    // Notifications (src/modules/notification/android.zig)
    // ---------------------------------------------------------------------

    private fun notificationManager(): NotificationManager {
        val nm = app.getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, appLabel(), NotificationManager.IMPORTANCE_DEFAULT))
        }
        return nm
    }

    internal fun appLabel(): String = app.applicationInfo.loadLabel(app.packageManager).toString()

    /** `res/drawable/ic_notification` if the app has one, else its icon. */
    internal fun notificationIcon(): Int {
        val custom = app.resources.getIdentifier("ic_notification", "drawable", app.packageName)
        return if (custom != 0) custom else app.applicationInfo.icon
    }

    internal fun openAppIntent(): PendingIntent = PendingIntent.getActivity(
        app, 0, Intent(app, OrielMainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    /** The device's name (src/core/system.zig): Settings' "Device name", else the Bluetooth name, else the model. */
    @JvmStatic
    fun deviceName(): ByteArray {
        val cr = app.contentResolver
        val named = listOf(
            { android.provider.Settings.Global.getString(cr, "device_name") },
            { android.provider.Settings.Secure.getString(cr, "bluetooth_name") },
        ).firstNotNullOfOrNull { get -> try { get()?.takeIf { it.isNotBlank() } } catch (e: Exception) { null } }
        val model = android.os.Build.MODEL ?: "Android"
        val maker = android.os.Build.MANUFACTURER ?: ""
        return (named ?: if (model.startsWith(maker, ignoreCase = true)) model else "$maker $model".trim()).bytes()
    }

    @JvmStatic
    fun notificationsEnabled(): Boolean = notificationManager().areNotificationsEnabled()

    /**
     * A tap opens the app and sends the system event "notification" with
     * "\u001f<id>"; a button ([actions]: "id\tlabel" lines) sends
     * "<action>\u001f<id>" without opening it (src/modules/notification/common.zig).
     */
    @JvmStatic
    fun notify(id: ByteArray?, title: ByteArray, body: ByteArray?, actions: ByteArray?): Boolean {
        val nm = notificationManager()
        if (!nm.areNotificationsEnabled()) return false
        val tag = id?.utf8()
        val code = if (tag == null) (System.currentTimeMillis() and 0x7fffffff).toInt() else 1
        val key = tag ?: ""
        // Request codes keep each notification's PendingIntents (and extras) apart.
        val base = 31 * key.hashCode() + code
        val open = Intent(app, OrielMainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .putExtra(EXTRA_NOTIFICATION, key)
        val builder = android.app.Notification.Builder(app, CHANNEL)
            .setSmallIcon(notificationIcon())
            .setContentTitle(title.utf8())
            .setContentIntent(PendingIntent.getActivity(app, base, open, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
            .setAutoCancel(true)
        body?.let { builder.setContentText(it.utf8()).setStyle(android.app.Notification.BigTextStyle().bigText(it.utf8())) }
        actions?.utf8()?.lineSequence()?.filter { it.contains('\t') }?.take(3)?.forEachIndexed { i, line ->
            val tab = line.indexOf('\t')
            val press = Intent(app, OrielActionReceiver::class.java)
                .putExtra(OrielActionReceiver.EXTRA_ACTION, line.substring(0, tab))
                .putExtra(EXTRA_NOTIFICATION, key)
                .putExtra(EXTRA_NOTIFICATION_CODE, code)
            val pi = PendingIntent.getBroadcast(app, base + i + 1, press, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            builder.addAction(android.app.Notification.Action.Builder(android.graphics.drawable.Icon.createWithResource(app, notificationIcon()), line.substring(tab + 1), pi).build())
        }
        return try {
            nm.notify(tag, code, builder.build())
            true
        } catch (e: SecurityException) {
            false
        }
    }

    /** A button was pressed: dismiss its notification (buttons don't). */
    internal fun cancelNotification(tag: String, code: Int) {
        app.getSystemService(NotificationManager::class.java).cancel(tag.ifEmpty { null }, code)
    }

    /**
     * The main activity was opened by a tap on a notification: report it
     * once. [direct]: the app is starting, so straight to Zig (OrielSystem.send
     * would start it again while it isn't running yet).
     */
    private fun notificationTap(intent: Intent, direct: Boolean = false) {
        val key = intent.getStringExtra(EXTRA_NOTIFICATION) ?: return
        intent.removeExtra(EXTRA_NOTIFICATION)
        val data = "\u001f" + key
        if (direct) NativeLib.onSystemEvent("notification".bytes(), data.bytes()) else OrielSystem.send("notification", data)
    }

    // ---------------------------------------------------------------------
    // File dialogs (src/modules/dialog/android.zig)
    // ---------------------------------------------------------------------

    @JvmStatic
    fun showFileDialog(kind: Int, title: ByteArray): Boolean {
        val host = foreground ?: mainActivity ?: return false
        val intent = if (kind == 0) {
            Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*")
        } else {
            Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*")
                .putExtra(Intent.EXTRA_TITLE, "untitled")
        }
        intent.putExtra("android.provider.extra.PROMPT", title.utf8())
        return host.pickDocument(intent, kind)
    }

    /** The picker's answer: open copies into the cache, save opens a descriptor. */
    internal fun onDocumentPicked(kind: Int, uri: Uri?) {
        if (uri == null) {
            NativeLib.onFileDialogResult(null)
            return
        }
        Thread {
            val path = try {
                if (kind == 0) copyToCache(uri) else openForWriting(uri)
            } catch (e: Exception) {
                Log.w(TAG, "cannot use the picked document", e)
                null
            }
            NativeLib.onFileDialogResult(path?.bytes())
        }.start()
    }

    private fun displayName(uri: Uri): String {
        app.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) it.getString(0)?.let { name -> return name.replace('/', '_') }
        }
        return "document"
    }

    private fun copyToCache(uri: Uri): String {
        val dir = File(app.cacheDir, "picked").apply { mkdirs() }
        val out = File(dir, displayName(uri))
        app.contentResolver.openInputStream(uri)!!.use { input -> out.outputStream().use { input.copyTo(it) } }
        return out.path
    }

    private fun openForWriting(uri: Uri): String {
        val pfd = app.contentResolver.openFileDescriptor(uri, "rwt")!!
        return "/proc/self/fd/${pfd.detachFd()}"
    }

    // ---------------------------------------------------------------------
    // Folders with lasting access (src/modules/dialog/android.zig). Each call
    // answers once through NativeLib.onFolderResult(request, status, data),
    // from a thread of its own; returning false means it won't.
    // ---------------------------------------------------------------------

    private const val FOLDER_OK = 0
    private const val FOLDER_UNAVAILABLE = 1
    private const val FOLDER_FAILED = 2
    private const val FOLDER_NOT_FOUND = 3
    private const val GRANT_RW = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION

    /** The folder picker's pending request (one at a time: Zig's `busy`). */
    private var folderRequest = 0L

    @JvmStatic
    fun showFolderDialog(request: Long, title: ByteArray): Boolean {
        val host = foreground ?: mainActivity ?: return false
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
            .addFlags(GRANT_RW or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            .putExtra("android.provider.extra.PROMPT", title.utf8())
        folderRequest = request
        return host.pickFolder(intent).also { if (!it) folderRequest = 0L }
    }

    /** The tree picker's answer (null: cancelled): keep the grant, report "uri\nname". */
    internal fun onFolderPicked(data: Intent?) {
        val request = folderRequest
        if (request == 0L) return
        folderRequest = 0L
        val uri = data?.data ?: return NativeLib.onFolderResult(request, FOLDER_OK, null)
        Thread {
            try {
                app.contentResolver.takePersistableUriPermission(uri, data.flags and GRANT_RW)
                val name = documentName(treeDocument(uri)) ?: uri.lastPathSegment ?: "folder"
                NativeLib.onFolderResult(request, FOLDER_OK, "$uri\n$name".bytes())
            } catch (e: Exception) {
                Log.w(TAG, "cannot keep access to the picked folder", e)
                NativeLib.onFolderResult(request, FOLDER_FAILED, null)
            }
        }.start()
    }

    @JvmStatic
    fun folderName(request: Long, id: ByteArray): Boolean {
        val tree = Uri.parse(id.utf8())
        Thread {
            val name = try {
                if (held(tree)) documentName(treeDocument(tree)) else null
            } catch (e: Exception) {
                null // revoked, or the folder is gone
            }
            if (name != null) NativeLib.onFolderResult(request, FOLDER_OK, name.bytes())
            else NativeLib.onFolderResult(request, FOLDER_UNAVAILABLE, null)
        }.start()
        return true
    }

    @JvmStatic
    fun saveToFolder(request: Long, id: ByteArray, src: ByteArray, name: ByteArray, mime: ByteArray?): Boolean {
        val tree = Uri.parse(id.utf8())
        val source = File(src.utf8())
        val displayName = name.utf8()
        Thread {
            val (status, data) = try {
                saveDocument(tree, source, displayName, mime?.utf8())
            } catch (e: Exception) {
                Log.w(TAG, "cannot save into the folder", e)
                FOLDER_FAILED to null
            }
            NativeLib.onFolderResult(request, status, data?.bytes())
        }.start()
        return true
    }

    private fun saveDocument(tree: Uri, source: File, name: String, mime: String?): Pair<Int, String?> {
        if (!source.isFile) return FOLDER_NOT_FOUND to null
        if (!held(tree)) return FOLDER_UNAVAILABLE to null
        val resolver = app.contentResolver
        val type = mime ?: MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase())
            ?: "application/octet-stream"
        val doc = try {
            DocumentsContract.createDocument(resolver, treeDocument(tree), type, name)
        } catch (e: FileNotFoundException) {
            return FOLDER_UNAVAILABLE to null // the folder is gone
        } catch (e: SecurityException) {
            return FOLDER_UNAVAILABLE to null
        } ?: return FOLDER_FAILED to null
        try {
            source.inputStream().use { input -> resolver.openOutputStream(doc, "w")!!.use { input.copyTo(it) } }
        } catch (e: Exception) {
            try { DocumentsContract.deleteDocument(resolver, doc) } catch (_: Exception) {}
            throw e
        }
        return FOLDER_OK to (documentName(doc) ?: name)
    }

    @JvmStatic
    fun forgetFolder(id: ByteArray) {
        try {
            app.contentResolver.releasePersistableUriPermission(Uri.parse(id.utf8()), GRANT_RW)
        } catch (e: SecurityException) {
            // Not held (any more).
        }
    }

    /** Whether the app still holds the persisted write grant for `tree`. */
    private fun held(tree: Uri): Boolean =
        app.contentResolver.persistedUriPermissions.any { it.uri == tree && it.isWritePermission }

    /** The document URI of a tree's root folder. */
    private fun treeDocument(tree: Uri): Uri =
        DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))

    /** A document's display name, or null when it can't be read (gone). */
    private fun documentName(doc: Uri): String? =
        app.contentResolver.query(doc, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) it.getString(0) else null
        }

    // ---------------------------------------------------------------------
    // Audio (src/modules/audio_capture/android.zig) and the foreground service
    // ---------------------------------------------------------------------

    /** "id\tname\n" per input device. */
    @JvmStatic
    fun audioInputs(): ByteArray {
        val am = app.getSystemService(AudioManager::class.java)
        val sb = StringBuilder()
        for (d in am.getDevices(AudioManager.GET_DEVICES_INPUTS)) {
            if (d.type == AudioDeviceInfo.TYPE_TELEPHONY) continue
            sb.append(d.id).append('\t').append(d.productName).append(" (").append(typeName(d.type)).append(")\n")
        }
        return sb.toString().bytes()
    }

    private fun typeName(type: Int): String = when (type) {
        AudioDeviceInfo.TYPE_BUILTIN_MIC -> "built-in microphone"
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "Bluetooth"
        AudioDeviceInfo.TYPE_WIRED_HEADSET -> "headset"
        AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_HEADSET -> "USB"
        else -> "input"
    }

    /**
     * Keep the app capturing (microphone) with a notification while it is
     * in the background: `oriel.android.setForegroundService(...)` from Zig.
     * `actions`: "id\tlabel\n" lines, buttons on the notification.
     */
    @JvmStatic
    fun setForegroundService(on: Boolean, title: ByteArray, text: ByteArray, actions: ByteArray): Boolean {
        val intent = Intent(app, OrielAudioService::class.java)
        return try {
            if (on) {
                intent.putExtra(OrielAudioService.EXTRA_TITLE, title.utf8()).putExtra(OrielAudioService.EXTRA_TEXT, text.utf8())
                    .putExtra(OrielAudioService.EXTRA_ACTIONS, actions.utf8())
                app.startForegroundService(intent)
            } else {
                app.stopService(intent)
            }
            true
        } catch (e: Exception) {
            Log.w(TAG, "foreground service", e)
            false
        }
    }

    // ---------------------------------------------------------------------
    // System entry points (src/platform/android/android.zig: system events)
    // ---------------------------------------------------------------------

    @JvmStatic
    fun commitText(text: ByteArray): Boolean = OrielSystem.commitText(text.utf8())

    @JvmStatic
    fun keyboardActive(): Boolean = OrielSystem.inputMethod?.currentInputConnection != null

    @JvmStatic
    fun setKeyboardStatus(status: ByteArray, button: ByteArray) {
        OrielKeyboardState.status = status.utf8()
        OrielKeyboardState.button = button.utf8()
        OrielSystem.inputMethod?.refresh()
    }

    @JvmStatic
    fun setTile(active: Boolean, label: ByteArray) {
        OrielSystem.setTile(active, label.utf8().ifEmpty { null })
    }

    // System speech recognizer (src/modules/dictation/android.zig)
    // ---------------------------------------------------------------------

    @JvmStatic
    fun speechAvailable(): Int = OrielSpeech.available()

    @JvmStatic
    fun speechStart(language: ByteArray, onDevice: Boolean): Boolean = OrielSpeech.start(language.utf8(), onDevice)

    @JvmStatic
    fun speechStop() = OrielSpeech.stop()

    // mDNS / DNS-SD (src/modules/network/android.zig, OrielMdns)
    // ---------------------------------------------------------------------

    @JvmStatic
    fun mdnsRegister(id: Int, name: ByteArray, type: ByteArray, port: Int, txt: ByteArray): Boolean =
        OrielMdns.register(id, name, type, port, txt)

    @JvmStatic
    fun mdnsUnregister(id: Int) = OrielMdns.unregister(id)

    @JvmStatic
    fun mdnsBrowse(id: Int, type: ByteArray): Boolean = OrielMdns.browse(id, type)

    @JvmStatic
    fun mdnsStopBrowse(id: Int) = OrielMdns.stopBrowse(id)

    // Keyboard shortcuts (src/plugins/global_shortcut/android.zig)
    // ---------------------------------------------------------------------

    internal class Shortcut(val id: String, val keyCode: Int, val meta: Int, val label: String)

    /** The registered shortcuts: OrielActivity matches key presses against them. */
    @Volatile internal var shortcuts: List<Shortcut> = emptyList()

    /** The whole table, one "id\tkeycode\tmeta\tlabel" line per shortcut. */
    @JvmStatic
    fun setShortcuts(table: ByteArray) {
        shortcuts = table.utf8().lineSequence().mapNotNull { line ->
            val f = line.split('\t')
            if (f.size < 4) null else Shortcut(f[0], f[1].toIntOrNull() ?: return@mapNotNull null, f[2].toIntOrNull() ?: 0, f[3])
        }.toList()
    }
}
