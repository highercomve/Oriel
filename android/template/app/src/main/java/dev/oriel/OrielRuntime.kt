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
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Rect
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.OpenableColumns
import android.util.Log
import android.view.WindowManager
import java.io.ByteArrayOutputStream
import java.io.File

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
    const val EXTRA_ARGS = "dev.oriel.args"
    private const val CHANNEL = "oriel"

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
        when (NativeLib.start(app.filesDir.path.bytes(), app.cacheDir.path.bytes(), (app.getExternalFilesDir(null)?.path ?: "").bytes(), args)) {
            1 -> Log.i(TAG, "started")
            2 -> if (args.isNotEmpty()) NativeLib.onNewIntent(args)
            else -> Log.e(TAG, "liboriel.so failed to start (see the log above)")
        }
    }

    internal fun onActivityNewIntent(activity: OrielActivity, intent: Intent) {
        if (activity !is OrielWindowActivity) NativeLib.onNewIntent(argsOf(intent))
    }

    internal fun onActivityDestroyed(activity: OrielActivity) {
        if (mainActivity === activity) mainActivity = null
        if (foreground === activity) foreground = null
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
        w.activity?.applyTitle(w.title)
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
        return (context.dp(bounds.width()).toLong() shl 32) or context.dp(bounds.height()).toLong()
    }

    // --- The native renderer (-Dnative_ui; src/native_ui/android.zig) ---

    @JvmStatic
    fun nuiViewport(id: Int): Long = Nui.viewport(id)

    @JvmStatic
    fun nuiMeasure(id: Int, node: Int, max64: Int): Long = Nui.views[id]?.measureText(node, max64) ?: 0

    @JvmStatic
    fun nuiProps(id: Int, node: Int, kind: ByteArray, json: ByteArray) {
        Nui.views[id]?.props(node, kind.utf8(), json.utf8())
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

    @JvmStatic
    fun notificationsEnabled(): Boolean = notificationManager().areNotificationsEnabled()

    @JvmStatic
    fun notify(id: ByteArray?, title: ByteArray, body: ByteArray?): Boolean {
        val nm = notificationManager()
        if (!nm.areNotificationsEnabled()) return false
        val builder = android.app.Notification.Builder(app, CHANNEL)
            .setSmallIcon(notificationIcon())
            .setContentTitle(title.utf8())
            .setContentIntent(openAppIntent())
            .setAutoCancel(true)
        body?.let { builder.setContentText(it.utf8()).setStyle(android.app.Notification.BigTextStyle().bigText(it.utf8())) }
        val tag = id?.utf8()
        return try {
            nm.notify(tag, if (tag == null) (System.currentTimeMillis() and 0x7fffffff).toInt() else 1, builder.build())
            true
        } catch (e: SecurityException) {
            false
        }
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
