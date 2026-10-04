package dev.oriel

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.inputmethodservice.InputMethodService
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

/**
 * System entry points that stand in for desktop hotkeys, tray menus and
 * synthetic typing on Android. Each reaches the app as a system event
 * (`oriel.android.onSystemEvent` in Zig, the `android:event` event in the
 * page), and only while the app runs (it is started when needed).
 *
 *   "tile"            the Quick Settings tile was tapped
 *   "action"          a notification action (data: its id)
 *   "media-button"    the headset button, while the foreground service runs
 *   "ime-mic"         the Oriel keyboard's main button
 *   "ime-open"        the Oriel keyboard came up (data: the field's input type)
 *   "ime-close"       it went away
 */
internal object OrielSystem {
    private const val TAG = "Oriel"

    /** The keyboard, while it is the active input method. */
    internal var inputMethod: OrielInputMethod? = null
    private var tileActive = false
    private var tileLabel: String? = null

    fun send(name: String, data: String = "") {
        if (!loadedAndRunning()) {
            Log.i(TAG, "system event $name while the app isn't running: starting it")
            OrielRuntime.app.startActivity(Intent(OrielRuntime.app, OrielMainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            return
        }
        NativeLib.onSystemEvent(name.bytes(), data.bytes())
    }

    private fun loadedAndRunning(): Boolean = try {
        OrielRuntime.app // initialized once an Activity started
        NativeLib.isRunning()
    } catch (e: Throwable) {
        false
    }

    fun commitText(text: String): Boolean {
        val ime = inputMethod ?: return false
        val ic = ime.currentInputConnection ?: return false
        return ic.commitText(text, 1)
    }

    fun setTile(active: Boolean, label: String?) {
        tileActive = active
        tileLabel = label
        val app = try { OrielRuntime.app } catch (e: Throwable) { return }
        TileService.requestListeningState(app, ComponentName(app, OrielTileService::class.java))
    }

    fun applyTile(tile: Tile) {
        tile.state = if (tileActive) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tileLabel?.let { tile.label = it }
        tile.updateTile()
    }
}

/** The Quick Settings tile (declared when build.zig sets `.android.tile`). */
class OrielTileService : TileService() {
    override fun onStartListening() {
        qsTile?.let { OrielSystem.applyTile(it) }
    }

    override fun onClick() {
        OrielSystem.send("tile")
    }
}

/** Notification actions of the foreground service. */
class OrielActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        OrielSystem.send("action", intent.getStringExtra(EXTRA_ACTION) ?: return)
    }

    companion object {
        const val EXTRA_ACTION = "dev.oriel.action"
    }
}

/**
 * The Oriel keyboard (declared when build.zig sets `.android.input_method`):
 * one big button that sends "ime-mic" (GhostPen: dictate), a label the app
 * sets (`oriel.android.setKeyboardStatus`), and a button back to the
 * previous keyboard. The app types into the focused field of any app with
 * `oriel.android.commitText`: the policy-safe way to insert text.
 */
class OrielInputMethod : InputMethodService() {
    private var status: TextView? = null
    private var main: Button? = null

    override fun onCreate() {
        super.onCreate()
        OrielSystem.inputMethod = this
    }

    override fun onDestroy() {
        if (OrielSystem.inputMethod === this) OrielSystem.inputMethod = null
        super.onDestroy()
    }

    override fun onCreateInputView(): View {
        val pad = (12 * resources.displayMetrics.density).toInt()
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad, pad, pad)
            gravity = Gravity.CENTER_HORIZONTAL
        }
        status = TextView(this).apply {
            text = OrielKeyboardState.status
            gravity = Gravity.CENTER
            setTextColor(Color.GRAY)
        }
        main = Button(this).apply {
            text = OrielKeyboardState.button
            textSize = 18f
            setOnClickListener { OrielSystem.send("ime-mic") }
        }
        val back = Button(this).apply {
            text = "⌨"
            contentDescription = "Switch keyboard"
            setOnClickListener { if (!switchToPreviousInputMethod()) requestHideSelf(0) }
        }
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(main, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            addView(back, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT))
        }
        root.addView(status)
        root.addView(row)
        return root
    }

    override fun onStartInputView(info: EditorInfo, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        refresh()
        OrielSystem.send("ime-open", info.inputType.toString())
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        OrielSystem.send("ime-close")
        super.onFinishInputView(finishingInput)
    }

    internal fun refresh() {
        status?.text = OrielKeyboardState.status
        main?.text = OrielKeyboardState.button
    }
}

internal object OrielKeyboardState {
    var status = ""
    var button = "🎤"
}
