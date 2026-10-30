package dev.oriel

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.ActivityInfo
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorFilter
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.RectF
import android.graphics.drawable.Drawable
import android.os.Build
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.net.Uri
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.widget.FrameLayout
import android.widget.Button
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.MediaController
import android.widget.TextView

/**
 * oriel.video on Android (src/modules/video/android.zig): a full-window
 * player over an Oriel window's WebView. MediaPlayer draws into a
 * SurfaceView (sized to the video's aspect ratio, black around it), with a
 * MediaController for play, pause and seeking, the title, a mute button
 * and a close button. Back, Esc and the close button close it.
 *
 * Embedded (a rectangle of the page, in CSS pixels): the player sits over
 * that part of the page, under the page's own bar, without a title or a
 * close button of its own; the page moves it with `setRect`. Its
 * fullscreen button (or `setFullscreen`) covers the screen: the system
 * bars hide, a landscape video turns the phone sideways, and Back or Esc
 * come back to the page's rectangle. Embedded, Back and Esc are the page's.
 *
 * When the video's sound can't be decoded on this device (AC3 or DTS on
 * most phones), the picture still plays: the player says so and, for a
 * URL other apps can open, offers to open it in one (VLC and the like).
 *
 * Plain URLs (http, https, file, content) go to MediaPlayer as they are.
 * The app's media URLs (`https://app.localhost/media/<path>`) exist only in
 * the WebView's request interception, so they are read in-process as
 * [OrielMedia] serves them: Zig's media source, else the root's file.
 *
 * Zig hears the end, errors and a close it didn't ask for through
 * `NativeLib.onSystemEvent("video", ...)`: "ended", "error\n<message>",
 * "closed", "audio-unsupported", "fullscreen\n1" / "fullscreen\n0". Main
 * thread only.
 */
internal object OrielVideo {
    private const val TAG = "OrielVideo"
    /** android.zig's UrlKind. */
    private const val KIND_APP_MEDIA = 3
    /** OrielRuntime.videoPlay's answers. */
    const val SHOWN = 0
    const val NOT_FOUND = -2
    const val FAILED = -3

    private var player: Player? = null

    val isShowing: Boolean get() = player != null

    /** Show the player over `activity` playing `url` (replacing one that shows). */
    fun play(activity: OrielActivity, url: String, title: String, kind: Int, rect: RectF?): Int {
        player?.release(notify = false)
        player = null
        val mp = MediaPlayer()
        try {
            val uri = Uri.parse(url)
            if (kind == KIND_APP_MEDIA) {
                if (!OrielMedia.setDataSource(mp, uri)) {
                    mp.release()
                    return NOT_FOUND
                }
            } else {
                mp.setDataSource(activity, uri)
            }
        } catch (e: Exception) {
            Log.w(TAG, "can't open $url: $e")
            mp.release()
            return FAILED
        }
        // Another app can open it unless it's an app media URL (only this
        // process's WebView serves those).
        val p = Player(activity, mp, title, if (kind == KIND_APP_MEDIA) null else Uri.parse(url), rect)
        player = p
        p.show()
        return SHOWN
    }

    /** Close the player Zig asked to close: true when one was showing. */
    fun close(): Boolean {
        val p = player ?: return false
        Log.i(TAG, "closed by the app")
        player = null
        p.release(notify = false)
        return true
    }

    fun setRect(rect: RectF) {
        player?.setRect(rect)
    }

    fun setFullscreen(on: Boolean) {
        player?.setFullscreen(on)
    }

    fun setVisible(visible: Boolean) {
        player?.setVisible(visible)
    }

    /** Back (and Esc) leave fullscreen, else close a player covering the
     * window; an embedded one leaves them to the page. */
    fun handleBack(activity: OrielActivity): Boolean {
        val p = player ?: return false
        if (p.activity !== activity) return false
        if (p.fullscreen) {
            p.setFullscreen(false)
            return true
        }
        if (p.embedded) return false
        Log.i(TAG, "closed by back")
        closeByUser(p)
        return true
    }

    fun onKey(activity: OrielActivity, event: KeyEvent): Boolean {
        val p = player ?: return false
        if (p.activity !== activity || event.keyCode != KeyEvent.KEYCODE_ESCAPE) return false
        if (p.embedded && !p.fullscreen) return false
        if (event.action == KeyEvent.ACTION_UP) {
            if (p.fullscreen) p.setFullscreen(false) else {
                Log.i(TAG, "closed by Esc")
                closeByUser(p)
            }
        }
        return true
    }

    /** The Activity holding the player is going away: the player too. */
    fun onActivityDestroyed(activity: OrielActivity) {
        val p = player ?: return
        if (p.activity === activity) {
            Log.i(TAG, "closed: its Activity went away")
            closeByUser(p)
        }
    }

    private fun closeByUser(p: Player) {
        if (player !== p) return
        player = null
        p.release(notify = true)
    }

    private fun report(data: String) = NativeLib.onSystemEvent("video".bytes(), data.bytes())

    /** One shown video: its views over the WebView, and its MediaPlayer. */
    private class Player(
        val activity: OrielActivity,
        private val mp: MediaPlayer,
        title: String,
        private val shareable: Uri?,
        /** Embedded: the page's rectangle, in CSS pixels. */
        private var rect: RectF?,
    ) : SurfaceHolder.Callback, MediaController.MediaPlayerControl {
        val embedded = rect != null
        var fullscreen = false
            private set
        private var savedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        /** The system bars showed before fullscreen hid them. */
        private var barsShowed = true
        private var savedUiFlags = 0
        private lateinit var fullscreenButton: ImageButton
        /** Hidden while it played: the surface comes back, so does the playing. */
        private var resumeOnSurface = false
        private val root = FitFrame(activity)
        private val surface = SurfaceView(activity)
        private val controller = MediaController(activity)
        private var prepared = false
        private var released = false
        /** MediaPlayer reported an error: it's in its Error state. */
        private var failed = false
        private var buffered = 0
        private var muted = false
        private var noSoundShown = false

        init {
            root.setBackgroundColor(Color.BLACK)
            root.isClickable = true // the page underneath gets no touches
            root.isFocusable = true
            root.surface = surface
            root.addView(surface, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
            val pad = dp(12)
            // Embedded, the page around it has the title and a way to close it.
            if (title.isNotEmpty() && !embedded) {
                val label = TextView(activity).apply {
                    text = title
                    setTextColor(Color.WHITE)
                    setShadowLayer(4f, 0f, 1f, Color.BLACK)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
                    maxLines = 1
                    ellipsize = android.text.TextUtils.TruncateAt.END
                    setPadding(pad, pad, pad, pad)
                }
                root.addView(label, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.TOP or Gravity.START).apply {
                    marginEnd = dp(112)
                })
            }
            val close = ImageButton(activity).apply {
                setImageResource(android.R.drawable.ic_menu_close_clear_cancel)
                setBackgroundColor(0x66000000)
                contentDescription = "Close"
                setOnClickListener {
                    Log.i(TAG, "closed by its close button")
                    OrielVideo.closeByUser(this@Player)
                }
            }
            if (!embedded) root.addView(close, FrameLayout.LayoutParams(dp(48), dp(48), Gravity.TOP or Gravity.END).apply {
                setMargins(pad, pad, pad, pad)
            })
            // Right of the mute button; where the close button is, embedded.
            val slot = if (embedded) 0 else 1
            fullscreenButton = ImageButton(activity).apply {
                setImageDrawable(FullscreenIcon(exit = false, density = activity.resources.displayMetrics.density))
                setBackgroundColor(0x66000000)
                contentDescription = "Fullscreen"
                setOnClickListener { setFullscreen(!fullscreen) }
            }
            root.addView(fullscreenButton, FrameLayout.LayoutParams(dp(48), dp(48), Gravity.TOP or Gravity.END).apply {
                setMargins(pad, pad, pad + dp(56) * slot, pad)
            })
            val mute = ImageButton(activity).apply {
                setImageResource(android.R.drawable.ic_lock_silent_mode_off)
                setBackgroundColor(0x66000000)
                contentDescription = "Mute"
                setOnClickListener {
                    muted = !muted
                    if (!released) mp.setVolume(if (muted) 0f else 1f, if (muted) 0f else 1f)
                    setImageResource(if (muted) android.R.drawable.ic_lock_silent_mode else android.R.drawable.ic_lock_silent_mode_off)
                    contentDescription = if (muted) "Unmute" else "Mute"
                }
            }
            root.addView(mute, FrameLayout.LayoutParams(dp(48), dp(48), Gravity.TOP or Gravity.END).apply {
                setMargins(pad, pad, pad + dp(56) * (slot + 1), pad)
            })
            root.setOnClickListener { if (controller.isShowing) controller.hide() else if (prepared) controller.show() }
            surface.holder.addCallback(this)

            mp.setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build())
            mp.setScreenOnWhilePlaying(true)
            mp.setOnPreparedListener {
                prepared = true
                it.start()
                if (root.isAttachedToWindow) controller.show()
            }
            mp.setOnVideoSizeChangedListener { _, w, h -> root.setVideoSize(w, h) }
            mp.setOnBufferingUpdateListener { _, percent -> buffered = percent }
            mp.setOnCompletionListener {
                if (root.isAttachedToWindow) controller.show(0)
                OrielVideo.report("ended")
            }
            mp.setOnInfoListener { _, what, _ ->
                if (what == MediaPlayer.MEDIA_INFO_AUDIO_NOT_PLAYING) showNoSound()
                false
            }
            mp.setOnErrorListener { _, what, extra ->
                failed = true
                OrielVideo.report("error\n${errorText(what, extra)}")
                true // no completion callback after it
            }
            controller.setMediaPlayer(this)
            controller.setAnchorView(root)
        }

        /** The sound can't be decoded here: say so, and offer another app. */
        private fun showNoSound() {
            if (noSoundShown || released) return
            noSoundShown = true
            OrielVideo.report("audio-unsupported")
            val bar = LinearLayout(activity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setBackgroundColor(0xCC000000.toInt())
                setPadding(dp(12), dp(8), dp(8), dp(8))
            }
            val message = TextView(activity).apply {
                text = "This video's sound isn't supported on this device."
                setTextColor(Color.WHITE)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            }
            bar.addView(message, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            shareable?.let { uri ->
                val open = Button(activity).apply {
                    text = "Open in another app"
                    setOnClickListener { openElsewhere(uri) }
                }
                bar.addView(open, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            }
            root.addView(bar, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.TOP).apply {
                topMargin = dp(72)
            })
        }

        /** Hands the video to another app (it plays what this one can't). */
        private fun openElsewhere(uri: Uri) {
            val intent = Intent(Intent.ACTION_VIEW).setDataAndType(uri, "video/*")
            try {
                if (ok() && mp.isPlaying) mp.pause()
                activity.startActivity(Intent.createChooser(intent, "Open with"))
            } catch (e: ActivityNotFoundException) {
                Log.w(TAG, "no app opens $uri: $e")
            }
        }

        fun show() {
            activity.addOverlay(root)
            place()
            // Covering the window, keys go to the player; embedded, the page keeps them.
            if (!embedded) root.requestFocus()
            mp.prepareAsync()
        }

        /** Hidden, the surface goes (playback pauses); shown, it resumes. */
        fun setVisible(visible: Boolean) {
            if (released) return
            if (!visible) {
                resumeOnSurface = ok() && mp.isPlaying
                controller.hide()
            }
            root.visibility = if (visible) View.VISIBLE else View.INVISIBLE
        }

        fun setRect(r: RectF) {
            if (!embedded || released) return
            rect = r
            if (!fullscreen) place()
        }

        /** Over the page's rectangle (embedded), else the whole window. The
         * page's CSS pixels are dp; the overlay starts where the page does. */
        private fun place() {
            val r = rect
            root.layoutParams = if (r == null || fullscreen) {
                FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
            } else {
                val d = activity.resources.displayMetrics.density
                FrameLayout.LayoutParams((r.width() * d).toInt(), (r.height() * d).toInt(), Gravity.TOP or Gravity.START).apply {
                    leftMargin = (r.left * d).toInt()
                    topMargin = (r.top * d).toInt()
                }
            }
            if (controller.isShowing) controller.hide()
        }

        /** The whole screen: the window, without the system bars, sideways
         * for a landscape video. Back, Esc or the button come back. */
        fun setFullscreen(on: Boolean) {
            if (on == fullscreen || released) return
            fullscreen = on
            if (on) {
                savedOrientation = activity.requestedOrientation
                if (videoWide()) activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                hideBars()
            } else {
                activity.requestedOrientation = savedOrientation
                restoreBars()
            }
            fullscreenButton.setImageDrawable(FullscreenIcon(exit = on, density = activity.resources.displayMetrics.density))
            fullscreenButton.contentDescription = if (on) "Exit fullscreen" else "Fullscreen"
            place()
            if (on) root.requestFocus()
            OrielVideo.report(if (on) "fullscreen\n1" else "fullscreen\n0")
        }

        private fun videoWide(): Boolean = ok() && mp.videoWidth > mp.videoHeight

        @Suppress("DEPRECATION")
        private fun hideBars() {
            val w = activity.window
            if (Build.VERSION.SDK_INT >= 30) {
                barsShowed = w.decorView.rootWindowInsets?.isVisible(WindowInsets.Type.systemBars()) ?: true
                w.insetsController?.let {
                    it.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                    it.hide(WindowInsets.Type.systemBars())
                }
            } else {
                savedUiFlags = w.decorView.systemUiVisibility
                w.decorView.systemUiVisibility = savedUiFlags or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
                    View.SYSTEM_UI_FLAG_FULLSCREEN or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
            }
        }

        @Suppress("DEPRECATION")
        private fun restoreBars() {
            val w = activity.window
            if (Build.VERSION.SDK_INT >= 30) {
                if (barsShowed) w.insetsController?.show(WindowInsets.Type.systemBars())
            } else {
                w.decorView.systemUiVisibility = savedUiFlags
            }
        }

        fun release(notify: Boolean) {
            if (released) return
            released = true
            if (fullscreen) {
                fullscreen = false
                activity.requestedOrientation = savedOrientation
                restoreBars()
            }
            controller.hide()
            surface.holder.removeCallback(this)
            activity.removeOverlay(root)
            mp.setOnErrorListener(null)
            mp.setOnCompletionListener(null)
            mp.setOnInfoListener(null)
            mp.release()
            if (notify) OrielVideo.report("closed")
        }

        private fun dp(v: Int): Int = (v * activity.resources.displayMetrics.density + 0.5f).toInt()

        // SurfaceHolder.Callback: the surface goes away when the app goes to the background.
        override fun surfaceCreated(holder: SurfaceHolder) {
            if (released) return
            mp.setDisplay(holder)
            if (resumeOnSurface && ok()) mp.start()
            resumeOnSurface = false
        }

        override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

        override fun surfaceDestroyed(holder: SurfaceHolder) {
            if (released) return
            if (ok() && mp.isPlaying) mp.pause()
            mp.setDisplay(null)
        }

        private fun ok() = prepared && !released && !failed

        // MediaController.MediaPlayerControl
        override fun start() { if (ok()) mp.start() }
        override fun pause() { if (ok()) mp.pause() }
        override fun getDuration(): Int = if (ok()) mp.duration else 0
        override fun getCurrentPosition(): Int = if (ok()) mp.currentPosition else 0
        override fun seekTo(pos: Int) { if (ok()) mp.seekTo(pos.toLong(), MediaPlayer.SEEK_PREVIOUS_SYNC) }
        override fun isPlaying(): Boolean = ok() && mp.isPlaying
        override fun getBufferPercentage(): Int = buffered
        override fun canPause(): Boolean = true
        override fun canSeekBackward(): Boolean = true
        override fun canSeekForward(): Boolean = true
        override fun getAudioSessionId(): Int = if (released) 0 else mp.audioSessionId
    }

    private fun errorText(what: Int, extra: Int): String {
        val w = when (what) {
            MediaPlayer.MEDIA_ERROR_SERVER_DIED -> "MEDIA_ERROR_SERVER_DIED"
            else -> "MEDIA_ERROR_UNKNOWN"
        }
        val e = when (extra) {
            MediaPlayer.MEDIA_ERROR_IO -> "MEDIA_ERROR_IO"
            MediaPlayer.MEDIA_ERROR_MALFORMED -> "MEDIA_ERROR_MALFORMED"
            MediaPlayer.MEDIA_ERROR_UNSUPPORTED -> "MEDIA_ERROR_UNSUPPORTED"
            MediaPlayer.MEDIA_ERROR_TIMED_OUT -> "MEDIA_ERROR_TIMED_OUT"
            else -> extra.toString()
        }
        return "$w ($e)"
    }

    /** Four corners: pointing out (fullscreen) or in (exit fullscreen). */
    private class FullscreenIcon(private val exit: Boolean, private val density: Float) : Drawable() {
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            style = Paint.Style.STROKE
            strokeWidth = 2.5f * density
        }

        override fun draw(canvas: Canvas) {
            val b = bounds
            val half = minOf(b.width(), b.height()) * 0.3f
            val arm = half * 0.6f
            val cx = b.exactCenterX()
            val cy = b.exactCenterY()
            val path = Path()
            for (sx in intArrayOf(-1, 1)) for (sy in intArrayOf(-1, 1)) {
                // The corner's point, and arms toward the centre (in) or away (out).
                val at = if (exit) half * 0.35f else half
                val x = cx + sx * at
                val y = cy + sy * at
                val dir = if (exit) 1 else -1
                path.moveTo(x, y + dir * sy * arm)
                path.lineTo(x, y)
                path.lineTo(x + dir * sx * arm, y)
            }
            canvas.drawPath(path, paint)
        }

        override fun getIntrinsicWidth() = (24 * density).toInt()
        override fun getIntrinsicHeight() = (24 * density).toInt()
        override fun setAlpha(alpha: Int) { paint.alpha = alpha }
        override fun setColorFilter(colorFilter: ColorFilter?) { paint.colorFilter = colorFilter }
        @Deprecated("Deprecated in Java")
        override fun getOpacity() = PixelFormat.TRANSLUCENT
    }

    /**
     * Black, with the surface fitted to the video's aspect ratio and centred.
     * It takes every pointer event over it: a mouse's clicks and hovers
     * arrive as generic motion events, which a FrameLayout hands to the
     * next view down when nobody here takes them, and the WebView behind
     * would turn them into clicks on the page (ChromeOS, a mouse on a tablet).
     */
    private class FitFrame(context: Context) : FrameLayout(context) {
        var surface: View? = null

        override fun onGenericMotionEvent(event: MotionEvent): Boolean = true

        override fun onHoverEvent(event: MotionEvent): Boolean {
            super.onHoverEvent(event)
            return true
        }
        private var videoW = 0
        private var videoH = 0

        fun setVideoSize(w: Int, h: Int) {
            if (w == videoW && h == videoH) return
            videoW = w
            videoH = h
            requestLayout()
        }

        override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
            super.onLayout(changed, left, top, right, bottom)
            val s = surface ?: return
            val w = right - left
            val h = bottom - top
            if (videoW <= 0 || videoH <= 0 || w <= 0 || h <= 0) return
            // Fit: the whole video shows, bars on two sides.
            val fitW: Int
            val fitH: Int
            if (w.toLong() * videoH > h.toLong() * videoW) {
                fitH = h
                fitW = (h.toLong() * videoW / videoH).toInt()
            } else {
                fitW = w
                fitH = (w.toLong() * videoH / videoW).toInt()
            }
            val x = (w - fitW) / 2
            val y = (h - fitH) / 2
            s.layout(x, y, x + fitW, y + fitH)
        }
    }
}
