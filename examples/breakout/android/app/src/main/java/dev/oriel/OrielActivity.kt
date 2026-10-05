package dev.oriel

import android.app.Activity
import android.app.ActivityManager
import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.view.KeyEvent
import android.view.KeyboardShortcutGroup
import android.view.KeyboardShortcutInfo
import android.view.Menu
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.webkit.ValueCallback
import android.webkit.WebView
import android.widget.FrameLayout

/**
 * Shows one Oriel window. The launcher ([OrielMainActivity], `singleTask`)
 * shows the main window and receives later launches (deep links) through
 * `onNewIntent`; each other window gets an [OrielWindowActivity] in a task of
 * its own, so in desktop windowing every window is a separate, resizable
 * window. Configuration changes (resizing) don't recreate the Activity
 * (`android:configChanges` in the manifest), and the WebView outlives it
 * anyway ([OrielWindow]).
 */
open class OrielActivity : Activity() {
    private lateinit var root: FrameLayout
    private var closingByRuntime = false
    private var started = false
    private var chooserCallback: ValueCallback<Array<Uri>>? = null

    internal val orielWindow: OrielWindow?
        get() = OrielRuntime.windows.values.firstOrNull { it.activity === this }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        root = FrameLayout(this)
        // Android 15 draws apps targeting API 35 edge to edge: keep the page
        // clear of the status and navigation bars, the display cutout and the
        // keyboard (which no longer resizes the window). Fullscreen hides the
        // bars, so their insets are 0 and the page fills the screen.
        root.setOnApplyWindowInsetsListener { v, insets ->
            if (Build.VERSION.SDK_INT >= 30) {
                val i = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout() or WindowInsets.Type.ime())
                v.setPadding(i.left, i.top, i.right, i.bottom)
                WindowInsets.CONSUMED
            } else {
                @Suppress("DEPRECATION")
                v.setPadding(insets.systemWindowInsetLeft, insets.systemWindowInsetTop, insets.systemWindowInsetRight, insets.systemWindowInsetBottom)
                @Suppress("DEPRECATION")
                insets.consumeSystemWindowInsets()
            }
        }
        setContentView(root)
        OrielRuntime.onActivityCreated(this, intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        OrielRuntime.onActivityNewIntent(this, intent)
    }

    override fun onStart() {
        super.onStart()
        started = true
    }

    override fun onStop() {
        started = false
        super.onStop()
    }

    /** Window focus, for reads only a focused app may make (the clipboard). */
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        OrielRuntime.focusChanged(this, hasFocus)
    }

    override fun onResume() {
        super.onResume()
        OrielRuntime.foreground = this
    }

    override fun onDestroy() {
        val w = orielWindow
        w?.detachFrom(this)
        // Finished by the user (the caption's close button, swiped away from
        // Recents): the window closes (or hides, with hide-on-close).
        if (w != null && isFinishing && !closingByRuntime && !isChangingConfigurations) NativeLib.onCloseRequested(w.id)
        OrielRuntime.onActivityDestroyed(this)
        super.onDestroy()
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        val w = orielWindow
        when {
            w != null && w.goBack() -> {}
            // Like other launcher apps: back leaves the main window running.
            w == null || w.isMain -> moveTaskToBack(true)
            else -> NativeLib.onCloseRequested(w.id)
        }
    }

    // --- Keyboard shortcuts (global_shortcut on Android: this app's windows) --

    /** A registered shortcut goes to Zig before the WebView sees the key. */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.action == KeyEvent.ACTION_DOWN) {
            val s = OrielRuntime.shortcuts.firstOrNull { it.keyCode == event.keyCode && event.hasModifiers(it.meta) }
            if (s != null) {
                if (event.repeatCount == 0) NativeLib.onShortcut(s.id.bytes())
                return true
            }
        } else if (event.action == KeyEvent.ACTION_UP &&
            OrielRuntime.shortcuts.any { it.keyCode == event.keyCode && event.hasModifiers(it.meta) }
        ) {
            return true // its key down was consumed: so is the key up
        }
        return super.dispatchKeyEvent(event)
    }

    /** The system's keyboard shortcuts helper (Meta+/). */
    override fun onProvideKeyboardShortcuts(data: MutableList<KeyboardShortcutGroup>, menu: Menu?, deviceId: Int) {
        super.onProvideKeyboardShortcuts(data, menu, deviceId)
        val list = OrielRuntime.shortcuts
        if (list.isEmpty()) return
        data.add(KeyboardShortcutGroup(OrielRuntime.appLabel(), list.map { KeyboardShortcutInfo(it.label, it.keyCode, it.meta) }))
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig) // the WebView relayouts; the page gets `resize`
    }

    internal fun hasWindowFocusOrVisible(): Boolean = started

    internal fun setContent(view: View) {
        root.removeAllViews()
        root.addView(view, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        view.requestFocus(View.FOCUS_DOWN)
    }

    /**
     * The window's title and the page's theme-color as its task description:
     * ChromeOS paints the window's caption in that colour, as Chrome does an
     * installed web app's. A task colour must be opaque (a translucent one
     * is made so); on Android 15+ the caption's icons follow its lightness.
     */
    /** The status bar's colour before the page's theme-color first replaced it. */
    private var themeStatusBar: Int? = null

    internal fun applyTitle(title: String, themeColor: Int?) {
        setTitle(title)
        val color = themeColor?.let { it or (0xff shl 24) } ?: 0
        @Suppress("DEPRECATION")
        setTaskDescription(ActivityManager.TaskDescription(title, null, color))
        // ChromeOS paints an Android window's caption with its status bar's
        // colour: the theme's own comes back when the page drops its colour.
        @Suppress("DEPRECATION")
        run {
            val base = themeStatusBar ?: window.statusBarColor.also { themeStatusBar = it }
            window.statusBarColor = if (themeColor != null) color else base
        }
        if (Build.VERSION.SDK_INT >= 35) {
            val light = themeColor != null && android.graphics.Color.luminance(color) > 0.5f
            window.insetsController?.setSystemBarsAppearance(
                if (light) WindowInsetsController.APPEARANCE_LIGHT_CAPTION_BARS else 0,
                WindowInsetsController.APPEARANCE_LIGHT_CAPTION_BARS,
            )
        }
    }

    internal fun applyFullscreen(on: Boolean) {
        if (Build.VERSION.SDK_INT >= 30) {
            val c = window.insetsController ?: return
            if (on) {
                c.hide(WindowInsets.Type.systemBars())
                c.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            } else {
                c.show(WindowInsets.Type.systemBars())
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = if (on) {
                View.SYSTEM_UI_FLAG_FULLSCREEN or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
            } else {
                0
            }
        }
    }

    /** Closed by Oriel (window destroyed, app exited): no close request. */
    internal fun finishByRuntime() {
        closingByRuntime = true
        finishAndRemoveTask()
    }

    // --- Pickers and permission prompts -----------------------------------------

    internal fun chooseFiles(intent: Intent, multiple: Boolean, callback: ValueCallback<Array<Uri>>): Boolean {
        chooserCallback?.onReceiveValue(null)
        chooserCallback = callback
        if (multiple) intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        return try {
            @Suppress("DEPRECATION")
            startActivityForResult(intent, REQ_CHOOSER)
            true
        } catch (e: Exception) {
            chooserCallback = null
            false
        }
    }

    internal fun pickDocument(intent: Intent, kind: Int): Boolean = try {
        @Suppress("DEPRECATION")
        startActivityForResult(intent, if (kind == 0) REQ_OPEN else REQ_SAVE)
        true
    } catch (e: Exception) {
        false
    }

    internal fun pickFolder(intent: Intent): Boolean = try {
        @Suppress("DEPRECATION")
        startActivityForResult(intent, REQ_FOLDER)
        true
    } catch (e: Exception) {
        false
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        when (requestCode) {
            REQ_CHOOSER -> {
                val cb = chooserCallback ?: return
                chooserCallback = null
                val uris = if (resultCode != RESULT_OK || data == null) null else {
                    val clip = data.clipData
                    if (clip != null) Array(clip.itemCount) { clip.getItemAt(it).uri } else data.data?.let { arrayOf(it) }
                }
                cb.onReceiveValue(uris)
            }
            REQ_OPEN, REQ_SAVE -> OrielRuntime.onDocumentPicked(
                if (requestCode == REQ_OPEN) 0 else 1,
                if (resultCode == RESULT_OK) data?.data else null,
            )
            REQ_FOLDER -> OrielRuntime.onFolderPicked(if (resultCode == RESULT_OK) data else null)
            else -> @Suppress("DEPRECATION") super.onActivityResult(requestCode, resultCode, data)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray) {
        OrielPermissions.onResult(this, requestCode, permissions, grantResults)
    }

    companion object {
        private const val REQ_CHOOSER = 0x4F01
        private const val REQ_OPEN = 0x4F02
        private const val REQ_SAVE = 0x4F03
        private const val REQ_FOLDER = 0x4F04
    }
}

/** The main window, deep links (`singleTask`). */
class OrielMainActivity : OrielActivity()

/**
 * The launcher icon: opens OrielMainActivity at the size the app gave its
 * main window last time (desktop windowing, e.g. ChromeOS), which only a
 * launch can set; then goes. Draws nothing (Theme.NoDisplay).
 */
class OrielLaunchActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val main = Intent(intent).setClass(this, OrielMainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val size = OrielRuntime.rememberedMainSize(this)
        val options = size?.let { OrielRuntime.launchBounds(this, it.first, it.second) }
        startActivity(main, options?.toBundle())
        finish()
    }
}

/** Every other window, each in its own task. */
open class OrielWindowActivity : OrielActivity()

/** A transparent window (Theme.Oriel.Transparent): a translucent Activity. */
class OrielTransparentWindowActivity : OrielWindowActivity()
