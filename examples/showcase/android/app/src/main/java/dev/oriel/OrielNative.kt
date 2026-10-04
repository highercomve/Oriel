package dev.oriel

import android.annotation.SuppressLint
import android.content.Context
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BlurMaskFilter
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RadialGradient
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.os.Handler
import android.os.Looper
import android.text.Editable
import android.text.InputFilter
import android.text.InputType
import android.text.Layout
import android.text.SpannableStringBuilder
import android.text.Spannable
import android.text.Spanned
import android.text.StaticLayout
import android.text.TextPaint
import android.text.TextUtils
import android.text.TextWatcher
import android.text.style.RelativeSizeSpan
import android.text.style.BackgroundColorSpan
import android.text.style.ForegroundColorSpan
import android.text.style.MetricAffectingSpan
import android.text.style.UnderlineSpan
import android.util.Log
import android.util.TypedValue
import android.view.Choreographer
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.View
import android.view.ViewConfiguration
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.OverScroller
import android.widget.SeekBar
import android.widget.Spinner
import android.widget.TextView
import org.json.JSONArray
import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.math.tan

/**
 * The natives of the native renderer's Android backend
 * (src/native_ui/android.zig), in liboriel.so when built with -Dnative_ui.
 * Coordinates are CSS px (dp).
 */
internal object NuiNative {
    @JvmStatic external fun resize(window: Int, width: Float, height: Float, dark: Boolean)
    @JvmStatic external fun tap(window: Int, x: Float, y: Float)
    /** A pointer event for the page: phase 0 down, 1 move (sent at the next
     *  display frame), 2 up, 3 cancel. True when the page prevented the
     *  default (on down: it takes the drag). */
    @JvmStatic external fun pointer(window: Int, phase: Int, x: Float, y: Float, buttons: Int, mouse: Boolean, mods: Int): Boolean
    /** A finger or button down on (x, y) (:active), or up. */
    @JvmStatic external fun press(window: Int, x: Float, y: Float, down: Boolean)
    /** A mouse over (x, y) (:hover), or gone (x < 0). */
    @JvmStatic external fun hover(window: Int, x: Float, y: Float)
    @JvmStatic external fun longPress(window: Int, x: Float, y: Float): Boolean
    @JvmStatic external fun scroll(window: Int, x: Float, y: Float, dy: Float): Boolean
    /** Scroll sideways at (x, y) dp: true if a container moved. */
    @JvmStatic external fun scrollX(window: Int, x: Float, y: Float, dx: Float): Boolean
    @JvmStatic external fun event(window: Int, id: Int, kind: ByteArray, data: ByteArray): Boolean
    @JvmStatic external fun timer(window: Int, id: Int)
    @JvmStatic external fun back(window: Int): Boolean
    @JvmStatic external fun jsMemory(window: Int): Long
    /** ORIEL_NUI_TRACE is set (`debug.oriel.env`): NuiView logs each draw. */
    @JvmStatic external fun trace(): Boolean
    /** ORIEL_NUI_DUMP is set: NuiView logs what it holds after each frames(). */
    @JvmStatic external fun dump(): Boolean
    @JvmStatic external fun textCheck(): Boolean
    /** The display refreshed: the window's requestAnimationFrame callbacks run. */
    @JvmStatic external fun displayFrame(window: Int, intervalMs: Float)
    /** An app asset's bytes (an <img> src), or null. */
    @JvmStatic external fun asset(window: Int, path: ByteArray): ByteArray?
}

/** The calls from Zig (through OrielRuntime's `nui*` statics). */
internal object Nui {
    val views = HashMap<Int, NuiView>()
    private val main = Handler(Looper.getMainLooper())
    /** Logs "nui drawn <window>" (tag OrielNui) after each draw: logcat's
     *  timestamps then give a change's on-screen time against the page's own
     *  log lines (examples/render-bench). */
    val trace by lazy { NuiNative.trace() }
    val dump by lazy { NuiNative.dump() }
    /** ORIEL_NUI_TEXT_CHECK: plain lines measured both ways, differences logged. */
    val textCheck by lazy { NuiNative.textCheck() }

    fun viewport(window: Int): Long {
        val res = (views[window]?.context ?: OrielRuntime.app).resources
        val m = res.displayMetrics
        val v = views[window]
        val wp = if (v != null && v.width > 0) v.width else m.widthPixels
        val hp = if (v != null && v.height > 0) v.height else m.heightPixels
        val k = cssScale(wp, m.density)
        val w = Math.round(wp / k).toLong()
        val h = Math.round(hp / k).toLong()
        val dark = if (isDark(res.configuration)) 1L else 0L
        return (dark shl 32) or ((h and 0xffff) shl 16) or (w and 0xffff)
    }

    /**
     * Device pixels per CSS px for a page `px` wide, as Chromium makes its
     * layout viewport: the width in DIPs rounded up to whole CSS px (1080 px
     * at 2.625 is 412, not 411.43), the page scaled to fit, so a row the
     * WebView fits in 412 px fits here too.
     */
    fun cssScale(px: Int, density: Float): Float = if (px > 0) px / ceil(px / density - 1e-3f) else density

    fun isDark(c: Configuration) = c.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES

    /** One Choreographer callback for the window's next display frame
     *  (android.zig's requestDisplayFrame posts one at a time). */
    fun requestFrame(window: Int) {
        views[window]?.requestDisplayFrame()
    }

    fun displayFrame(v: NuiView) {
        val hz = v.display?.refreshRate?.takeIf { it > 0 } ?: 60f
        if (trace && ++displayFrames % 120 == 0) Log.d("OrielNui", "nui display frames $displayFrames at $hz Hz")
        NuiNative.displayFrame(v.window, 1000f / hz)
    }
    private var displayFrames = 0

    fun timer(window: Int, id: Int, ms: Int) {
        main.postDelayed({ if (views.containsKey(window)) NuiNative.timer(window, id) }, ms.toLong())
    }
}

/** A node's props, decoded once (see `Props` in src/native_ui/tree.zig). */
internal class NuiNode(val id: Int, var kind: String) {
    var p = JSONObject()
    var bg: Int? = null
    var gradient: JSONObject? = null
    var br: JSONArray? = null
    var bw: FloatArray? = null
    var bc: IntArray? = null
    var op = 1f
    var sc = 1f
    var rot = 0f
    var shadow: JSONObject? = null
    /** An <img>: its decoded picture (maybe downsampled), its natural size in px, and the src it came from. */
    /** A <canvas>: its drawing program, parsed once per change (OrielCanvas.kt). */
    var canvasOps: List<CvOp> = emptyList()
    var image: Bitmap? = null
    var imageW = 0
    var imageH = 0
    /** Which src the picture came from (length and hash: the src itself can be megabytes). */
    var imageKey = 0L
    var text: CharSequence? = null
    var paint: TextPaint? = null
    var layout: StaticLayout? = null
    var layoutWidth = -1
    var icon: NuiIcon? = null
    /** Inline outlines (a focused link's ring): runs with `ol`, neighbours with the same one together. */
    var rings: List<RunRing> = emptyList()

    /** Runs `start` until `end` of the text with outline `ol`, their content
     *  area (fonts' ascent and descent, px) `above` and `below` the baseline. */
    class RunRing(val start: Int, val end: Int, val ol: JSONObject, val above: Float, val below: Float)

    /** A single run's text set apart from `p` (setText, a leaf's text):
     *  `p` may be a leaf style's, shared by every node made from it. */
    private var runText: String? = null

    fun update(json: String, kind: String) = update(JSONObject(json), kind)

    fun update(props: JSONObject, kind: String) {
        this.kind = kind
        p = props
        runText = null
        derive()
    }

    /** A node made from a leaf style (NuiView.leaves): the style's parsed
     *  props, shared and read-only, and this node's own text. */
    fun fromStyle(style: NuiNode, text: String?) {
        p = style.p
        runText = text
        bg = style.bg
        gradient = style.gradient
        br = style.br
        bw = style.bw
        bc = style.bc
        op = style.op
        sc = style.sc
        rot = style.rot
        shadow = style.shadow
        layout = null
        layoutWidth = -1
        forgetSize()
        this.text = null
        icon = null
        if (kind == "text") buildText()
    }

    /** Its text as drawn (ORIEL_NUI_DUMP). */
    fun textForDump(): String = text?.toString() ?: ""

    /** What `p` gives: colors, borders, transforms, the text's paint. */
    private fun derive() {
        val b = p.optJSONObject("bg")
        bg = b?.optJSONArray("color")?.let { color(it) }
        gradient = b?.optJSONObject("gradient")
        br = p.optJSONArray("br")
        bw = p.optJSONArray("bw")?.let { a -> FloatArray(4) { a.optDouble(it, 0.0).toFloat() } }
        bc = p.optJSONArray("bc")?.let { a -> IntArray(4) { color(a.optJSONArray(it)) } }
        op = p.optDouble("op", 1.0).toFloat()
        sc = p.optDouble("sc", 1.0).toFloat()
        rot = p.optDouble("rot", 0.0).toFloat()
        shadow = p.optJSONObject("sh")
        layout = null
        layoutWidth = -1
        forgetSize()
        text = null
        icon = null
        if (kind == "text") buildText()
        if (kind == "icon") p.optJSONObject("icon")?.let { icon = NuiIcon(it) }
        if (kind == "canvas") {
            canvasOps = CanvasProgram.parse(p.optJSONArray("cv"))
            p.remove("cv") // parsed: the JSON isn't kept
        }
    }

    /** A single run's new text (NuiView.text): same styles, new words. */
    fun setText(t: String): Boolean {
        val runs = p.optJSONArray("runs") ?: return false
        if (kind != "text" || runs.length() != 1) return false
        runText = t
        layout = null
        layoutWidth = -1
        forgetSize()
        // Same styles: the paint stays, only the styled text is new.
        if (paint != null) text = spans(p.optDouble("fz", 16.0).toFloat(), p.optBoolean("mono")) else buildText()
        return true
    }

    private fun buildText() {
        val fz = p.optDouble("fz", 16.0).toFloat()
        val mono = p.optBoolean("mono")
        val ff = p.optString("ff")
        val tp = TextPaint(Paint.ANTI_ALIAS_FLAG)
        tp.textSize = fz
        tp.typeface = typeface(p.optDouble("fwt", 400.0).toInt(), p.optBoolean("it"), family(ff, mono))
        tp.color = p.optJSONArray("col")?.let { color(it) } ?: Color.BLACK
        if (p.has("ls")) tp.letterSpacing = p.optDouble("ls").toFloat() / fz
        text = spans(fz, mono)
        paint = tp
    }

    /** The runs as one styled text (each run's color, size, font, underline, background). */
    private fun spans(fz: Float, mono: Boolean): CharSequence {
        val sb = SpannableStringBuilder()
        val runs = p.optJSONArray("runs") ?: JSONArray()
        // Each run's start, end and size, for line-height (LineHeight).
        val sized = ArrayList<Float>()
        val rings = ArrayList<RunRing>()
        val density = android.content.res.Resources.getSystem().displayMetrics.density
        for (i in 0 until runs.length()) {
            val r = runs.optJSONObject(i) ?: continue
            val start = sb.length
            sb.append(if (i == 0 && runs.length() == 1) runText ?: r.optString("t") else r.optString("t"))
            val end = sb.length
            if (end == start) continue
            sized += start.toFloat(); sized += end.toFloat(); sized += r.optDouble("sz", fz.toDouble()).toFloat()
            val flags = Spanned.SPAN_EXCLUSIVE_EXCLUSIVE
            r.optJSONArray("c")?.let { sb.setSpan(ForegroundColorSpan(color(it)), start, end, flags) }
            sb.setSpan(RelativeSizeSpan(r.optDouble("sz", fz.toDouble()).toFloat() / fz), start, end, flags)
            sb.setSpan(FontSpan(typeface(r.optDouble("w", 400.0).toInt(), r.optBoolean("i"), family(r.optString("ff").ifEmpty { p.optString("ff") }, r.optBoolean("mono") || mono))), start, end, flags)
            if (r.optBoolean("u")) sb.setSpan(UnderlineSpan(), start, end, flags)
            r.optJSONArray("bg")?.let { val c = color(it); if (Color.alpha(c) > 0) sb.setSpan(BackgroundColorSpan(c), start, end, flags) }
            r.optJSONObject("ol")?.let { ol ->
                // Its box's content area: the run's font's ascent and descent,
                // rounded in device pixels (win32.zig contentExtent).
                val sz = r.optDouble("sz", fz.toDouble()).toFloat()
                val m = fontRatios(r.optString("ff").ifEmpty { p.optString("ff") }, r.optBoolean("mono") || mono)
                val above = Math.round(m[0] * sz * density) / density
                val below = Math.round(m[1] * sz * density) / density
                val last = rings.lastOrNull()
                if (last != null && last.end == start && last.ol.toString() == ol.toString()) {
                    rings[rings.size - 1] = RunRing(last.start, end, ol, max(last.above, above), max(last.below, below))
                } else rings += RunRing(start, end, ol, above, below)
            }
        }
        this.rings = rings
        // line-height: every line exactly that tall (CSS's, a length here);
        // normal (no lh): the font's own, as Chrome makes it (LineHeight).
        if (sb.isNotEmpty()) {
            val m = fontRatios(p.optString("ff"), mono)
            val lh = if (p.has("lh")) p.optDouble("lh").toFloat() else Float.NaN
            sb.setSpan(LineHeight(lh, fz, m, sized.toFloatArray()), 0, sb.length, Spanned.SPAN_INCLUSIVE_INCLUSIVE)
        }
        return sb
    }

    // Yoga measures a text more than once per layout (and Tree.wordMinWidth
    // once more), usually at the same width: its one-line width and the last
    // answer are kept until its text or styles change.
    private var desiredWidth = -1
    private var measuredFor = Int.MIN_VALUE
    private var measured = 0L

    private fun forgetSize() {
        desiredWidth = -1
        measuredFor = Int.MIN_VALUE
    }

    /** The text's width on one line, in dp (+1 for rounding). */
    private fun desired(t: CharSequence, tp: TextPaint): Int {
        if (desiredWidth < 0) desiredWidth = ceil(Layout.getDesiredWidth(t, tp)).toInt() + 1
        return desiredWidth
    }

    /** The text laid out `width` dp wide (unbounded: -1). */
    fun textLayout(width: Int): StaticLayout? {
        val t = text ?: return null
        val tp = paint ?: return null
        val nowrap = p.optBoolean("nowrap")
        val w = if (width < 0 || nowrap) desired(t, tp) else max(1, width)
        if (layout != null && layoutWidth == w) return layout
        val align = when (p.optString("ta")) {
            "center" -> Layout.Alignment.ALIGN_CENTER
            "right", "end" -> Layout.Alignment.ALIGN_OPPOSITE
            else -> Layout.Alignment.ALIGN_NORMAL
        }
        val b = builder(t, tp, w).setAlignment(align)
        if (nowrap) b.setMaxLines(1).setEllipsize(TextUtils.TruncateAt.END)
        layout = b.build()
        layoutWidth = w
        return layout
    }

    private fun builder(t: CharSequence, tp: TextPaint, w: Int): StaticLayout.Builder {
        return StaticLayout.Builder.obtain(t, 0, t.length, tp, w).setIncludePad(false)
    }

    /** One run of printable ASCII, no letter spacing: as tall as any other
     *  line of its style (no fallback font can make it taller). */
    private fun plainLine(t: CharSequence): Boolean {
        if (t.isEmpty() || p.has("ls") || (p.optJSONArray("runs")?.length() ?: 0) != 1) return false
        for (i in 0 until t.length) if (t[i] < ' ' || t[i] > '~') return false
        return true
    }

    /** A plain line's style: a paint with its run's font and size, and its
     *  line height from a StaticLayout of one character (once per style). */
    private class LineStyle(val paint: TextPaint, val height: Int)

    private fun lineStyle(t: CharSequence, tp: TextPaint): LineStyle {
        val r = p.optJSONArray("runs")?.optJSONObject(0)
        val fz = p.optDouble("fz", 16.0)
        val mono = p.optBoolean("mono") || (r?.optBoolean("mono") ?: false)
        val sz = r?.optDouble("sz", fz) ?: fz
        val w = r?.optDouble("w", 400.0)?.toInt() ?: 400
        val italic = r?.optBoolean("i") ?: false
        val ff = r?.optString("ff")?.ifEmpty { null } ?: p.optString("ff")
        val key = "$fz $sz $w $italic $mono ${p.optDouble("lh", -1.0)} $ff"
        return lineStyles.getOrPut(key) {
            val fp = TextPaint(Paint.ANTI_ALIAS_FLAG)
            fp.textSize = sz.toFloat()
            fp.typeface = typeface(w, italic, family(ff, mono))
            LineStyle(fp, builder(t.subSequence(0, 1), tp, 1 shl 20).build().height)
        }
    }

    /**
     * A plain text that fits on one line at `max64` (or unbounded): its width
     * from the font (rounded as the StaticLayout path: ceil + 1) and its
     * style's line height, no layout. Null: the full path measures it.
     */
    private fun fastSize(t: CharSequence, tp: TextPaint, max64: Int): Long? {
        if (!plainLine(t)) return null
        val st = lineStyle(t, tp)
        val w = ceil(st.paint.measureText(t, 0, t.length)).toInt() + 1
        if (max64 >= 0 && w > max(1, max64 / 64)) return null // it wraps
        return (w * 64L shl 32) or (st.height * 64L)
    }

    /** Size for Yoga: width and height in 1/64 dp, packed. */
    fun measure(max64: Int): Long {
        if (kind == "image") {
            // Its natural size (pixels as CSS px), scaled down to the width it may take.
            if (image == null || imageW <= 0 || imageH <= 0) return 0
            val k = if (max64 >= 0 && max64 / 64f < imageW) max64 / 64f / imageW else 1f
            return ((imageW * k * 64).toLong() shl 32) or (imageH * k * 64).toLong()
        }
        val t = text ?: return 0
        val tp = paint ?: return 0
        if (max64 == measuredFor) return measured
        // A plain line without a StaticLayout (most of a thousand updated
        // rows are never drawn, so their layouts would go unused).
        val fast = fastSize(t, tp, max64)
        if (fast != null && Nui.textCheck) {
            val full = layoutSize(t, tp, max64)
            if (full != fast) Log.d("OrielNui", "nui text check \"$t\" at $max64: fast ${fast shr 32}x${fast and 0xffffffff} layout ${full shr 32}x${full and 0xffffffff} (1/64 dp)")
        }
        measured = fast ?: layoutSize(t, tp, max64)
        measuredFor = max64
        return measured
    }

    /** The size from a StaticLayout at `max64` (any text). */
    private fun layoutSize(t: CharSequence, tp: TextPaint, max64: Int): Long {
        val desired = desired(t, tp)
        val width = if (max64 < 0) desired else min(desired, max(1, max64 / 64))
        val l = textLayout(width) ?: return 0
        var w = 0f
        for (i in 0 until l.lineCount) w = max(w, l.getLineWidth(i))
        val wf = min(ceil(w) + 1, width.toFloat())
        return ((wf * 64).toLong() shl 32) or (l.height * 64L)
    }

    companion object {
        /** Plain lines' styles (lineStyle). */
        private val lineStyles = HashMap<String, LineStyle>()

        fun color(a: JSONArray?): Int {
            if (a == null) return Color.TRANSPARENT
            val alpha = (a.optDouble(3, 1.0) * 255).toInt().coerceIn(0, 255)
            return Color.argb(alpha, a.optInt(0).coerceIn(0, 255), a.optInt(1).coerceIn(0, 255), a.optInt(2).coerceIn(0, 255))
        }

        /** A font family's ascent, descent and line gap per px of size (LineHeight), by CSS font-family list and mono. */
        private val ratios = HashMap<String, FloatArray>()

        fun fontRatios(ff: String, mono: Boolean): FloatArray = ratios.getOrPut("$mono $ff") {
            val tp = TextPaint(Paint.ANTI_ALIAS_FLAG)
            tp.textSize = 100f
            tp.typeface = family(ff, mono)
            val fm = tp.fontMetrics
            floatArrayOf(-fm.ascent / 100f, fm.descent / 100f, max(0f, fm.leading) / 100f)
        }

        /** The default sans (or monospace) font's ascent, descent and line gap at `size` px, in 1/64 px, 21 bits each. */
        fun fontMetrics(size: Float, mono: Boolean): Long {
            val m = fontRatios("", mono)
            fun q(v: Float) = (v * size * 64).toLong().coerceIn(0, (1L shl 21) - 1)
            return (q(m[0]) shl 42) or (q(m[1]) shl 21) or q(m[2])
        }

        /** CSS font-family lists resolved, as Chrome on Android does: the first family the system has. */
        private val families = HashMap<String, Typeface>()

        fun family(ff: String?, mono: Boolean): Typeface {
            if (ff.isNullOrEmpty()) return if (mono) Typeface.MONOSPACE else Typeface.DEFAULT
            return families.getOrPut(ff) {
                for (raw in ff.split(',')) {
                    val name = raw.trim().trim('"', '\'')
                    when (name.lowercase()) {
                        "sans-serif", "system-ui", "ui-sans-serif", "-apple-system", "blinkmacsystemfont", "roboto" -> return@getOrPut Typeface.DEFAULT
                        "monospace", "ui-monospace" -> return@getOrPut Typeface.MONOSPACE
                        "serif", "ui-serif" -> return@getOrPut Typeface.SERIF
                        "" -> continue
                    }
                    // A family the system knows (fonts.xml: cursive, casual, …); an unknown name gives the default.
                    val tf = Typeface.create(name, Typeface.NORMAL)
                    if (tf !== Typeface.DEFAULT) return@getOrPut tf
                }
                Typeface.DEFAULT
            }
        }

        fun typeface(weight: Int, italic: Boolean, mono: Boolean): Typeface = typeface(weight, italic, family(null, mono))

        fun typeface(weight: Int, italic: Boolean, base: Typeface): Typeface = Typeface.create(base, weight.coerceIn(1, 1000), italic)
    }
}

/**
 * CSS line-height on Android's lines. Every text size on a line gets a box
 * of its line height with its glyphs centred in it (half-leading, shorter
 * than the font too), all on one baseline with the paragraph's own size
 * (the strut); the line covers them. The line height is `px`, or with
 * `line-height: normal` (`px` NaN) the font's own as Chrome on Android
 * makes it: ascent, descent and line gap each rounded in device pixels.
 * One size: each line that tall, a fractional height rounded per line so n
 * lines add up to n × it (23.2: 23, 23, 24…). `m`: the font's ascent,
 * descent and line gap per px; `runs`: start, end, size of each run.
 */
private class LineHeight(private val px: Float, private val fz: Float, private val m: FloatArray, private val runs: FloatArray) :
    android.text.style.LineHeightSpan {
    private val density = android.content.res.Resources.getSystem().displayMetrics.density

    private fun heightAt(sz: Float): Float {
        if (!px.isNaN()) return px
        val k = sz * density
        return (Math.round(m[0] * k) + Math.round(m[1] * k) + Math.round(m[2] * k)) / density
    }

    override fun chooseHeight(text: CharSequence, start: Int, end: Int, spanstartv: Int, lineHeight: Int, fm: Paint.FontMetricsInt) {
        val a = m[0]; val d = m[1]
        val lh = heightAt(fz)
        if (fm.descent - fm.ascent <= 0 || !(lh > 0)) return
        // Above and below the baseline: the strut's, then each run's on this line.
        var above = a * fz + (lh - (a + d) * fz) / 2
        var below = d * fz + (lh - (a + d) * fz) / 2
        var mixed = false
        var i = 0
        while (i + 2 < runs.size) {
            val sz = runs[i + 2]
            if (runs[i] < end && runs[i + 1] > start && sz != fz) {
                val h = (heightAt(sz) - (a + d) * sz) / 2
                above = max(above, a * sz + h)
                below = max(below, d * sz + h)
                mixed = true
            }
            i += 3
        }
        if (mixed) {
            fm.ascent = -Math.round(above)
            fm.descent = Math.round(below)
        } else {
            // This line's top is `lineHeight` (spanstartv: where the span began).
            val line = Math.round((lineHeight - spanstartv) / lh)
            val target = Math.round((line + 1) * lh) - Math.round(line * lh)
            fm.ascent = -Math.round(above)
            fm.descent = fm.ascent + target
        }
        fm.top = fm.ascent
        fm.bottom = fm.descent
    }
}

/** A run's font: the typeface with its weight and style. */
private class FontSpan(val tf: Typeface) : MetricAffectingSpan() {
    override fun updateDrawState(tp: TextPaint) { tp.typeface = tf }
    override fun updateMeasureState(tp: TextPaint) { tp.typeface = tf }
}

/** An inline SVG: paths in viewBox units (from src/native_ui/js/src/icons.js). */
internal class NuiIcon(o: JSONObject) {
    val vb = o.optJSONArray("vb")?.let { a -> FloatArray(4) { a.optDouble(it).toFloat() } } ?: floatArrayOf(0f, 0f, 24f, 24f)
    class Shape(val path: Path, val fill: Int?, val stroke: Int?, val sw: Float, val cap: Paint.Cap, val join: Paint.Join)
    val shapes = ArrayList<Shape>()

    init {
        val list = o.optJSONArray("shapes") ?: JSONArray()
        for (i in 0 until list.length()) {
            val s = list.optJSONObject(i) ?: continue
            val path = try { SvgPath.parse(s.optString("d")) } catch (e: Exception) { continue }
            if (s.optBoolean("evenodd")) path.fillType = Path.FillType.EVEN_ODD
            shapes += Shape(
                path,
                s.optJSONArray("fill")?.let { NuiNode.color(it) },
                s.optJSONArray("stroke")?.let { NuiNode.color(it) },
                s.optDouble("sw", 1.0).toFloat(),
                when (s.optString("cap")) { "round" -> Paint.Cap.ROUND; "square" -> Paint.Cap.SQUARE; else -> Paint.Cap.BUTT },
                when (s.optString("join")) { "round" -> Paint.Join.ROUND; "bevel" -> Paint.Join.BEVEL; else -> Paint.Join.MITER },
            )
        }
    }
}

/** SVG path data to a Path (all commands; arcs as cubics). */
internal object SvgPath {
    fun parse(d: String): Path {
        val path = Path()
        var i = 0
        var cmd = ' '
        var x = 0f; var y = 0f; var sx = 0f; var sy = 0f
        var cx = 0f; var cy = 0f // the last control point (S, T)
        var last = ' '
        fun skip() { while (i < d.length && (d[i].isWhitespace() || d[i] == ',')) i++ }
        fun num(): Float {
            skip()
            val start = i
            if (i < d.length && (d[i] == '-' || d[i] == '+')) i++
            var dot = false
            var exp = false
            while (i < d.length) {
                val c = d[i]
                if (c.isDigit()) { i++; continue }
                if (c == '.' && !dot && !exp) { dot = true; i++; continue }
                if ((c == 'e' || c == 'E') && !exp) { exp = true; i++; if (i < d.length && (d[i] == '-' || d[i] == '+')) i++; continue }
                break
            }
            return d.substring(start, i).toFloat()
        }
        fun flag(): Boolean { skip(); val c = d[i]; i++; return c == '1' }
        while (true) {
            skip()
            if (i >= d.length) break
            if (d[i].isLetter()) { cmd = d[i]; i++ } else if (cmd == ' ' || cmd == 'Z' || cmd == 'z') break
            val rel = cmd.isLowerCase()
            val ox = if (rel) x else 0f
            val oy = if (rel) y else 0f
            when (cmd.uppercaseChar()) {
                'M' -> {
                    x = ox + num(); y = oy + num(); path.moveTo(x, y); sx = x; sy = y
                    cmd = if (rel) 'l' else 'L' // more pairs are line-tos
                }
                'L' -> { x = ox + num(); y = oy + num(); path.lineTo(x, y) }
                'H' -> { x = ox + num(); path.lineTo(x, y) }
                'V' -> { y = oy + num(); path.lineTo(x, y) }
                'C' -> {
                    val x1 = ox + num(); val y1 = oy + num(); val x2 = ox + num(); val y2 = oy + num()
                    x = ox + num(); y = oy + num(); path.cubicTo(x1, y1, x2, y2, x, y); cx = x2; cy = y2
                }
                'S' -> {
                    val x1 = if (last.uppercaseChar() == 'C' || last.uppercaseChar() == 'S') 2 * x - cx else x
                    val y1 = if (last.uppercaseChar() == 'C' || last.uppercaseChar() == 'S') 2 * y - cy else y
                    val x2 = ox + num(); val y2 = oy + num()
                    x = ox + num(); y = oy + num(); path.cubicTo(x1, y1, x2, y2, x, y); cx = x2; cy = y2
                }
                'Q' -> {
                    val x1 = ox + num(); val y1 = oy + num()
                    x = ox + num(); y = oy + num(); path.quadTo(x1, y1, x, y); cx = x1; cy = y1
                }
                'T' -> {
                    val x1 = if (last.uppercaseChar() == 'Q' || last.uppercaseChar() == 'T') 2 * x - cx else x
                    val y1 = if (last.uppercaseChar() == 'Q' || last.uppercaseChar() == 'T') 2 * y - cy else y
                    x = ox + num(); y = oy + num(); path.quadTo(x1, y1, x, y); cx = x1; cy = y1
                }
                'A' -> {
                    val rx = num(); val ry = num(); val rot = num(); val large = flag(); val sweep = flag()
                    val nx = ox + num(); val ny = oy + num()
                    arc(path, x, y, rx, ry, rot, large, sweep, nx, ny)
                    x = nx; y = ny
                }
                'Z' -> { path.close(); x = sx; y = sy }
                else -> break
            }
            last = cmd
        }
        return path
    }

    /** An SVG elliptical arc as cubic Béziers (SVG 1.1, appendix F.6). */
    private fun arc(path: Path, x1: Float, y1: Float, rxIn: Float, ryIn: Float, angle: Float, large: Boolean, sweep: Boolean, x2: Float, y2: Float) {
        var rx = abs(rxIn); var ry = abs(ryIn)
        if (rx == 0f || ry == 0f || (x1 == x2 && y1 == y2)) { path.lineTo(x2, y2); return }
        val phi = Math.toRadians(angle.toDouble())
        val cp = cos(phi); val sp = sin(phi)
        val dx = (x1 - x2) / 2.0; val dy = (y1 - y2) / 2.0
        val x1p = cp * dx + sp * dy
        val y1p = -sp * dx + cp * dy
        val lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if (lam > 1) { val s = sqrt(lam).toFloat(); rx *= s; ry *= s }
        val rx2 = rx.toDouble() * rx; val ry2 = ry.toDouble() * ry
        var num = rx2 * ry2 - rx2 * y1p * y1p - ry2 * x1p * x1p
        if (num < 0) num = 0.0
        var coef = sqrt(num / (rx2 * y1p * y1p + ry2 * x1p * x1p))
        if (large == sweep) coef = -coef
        val cxp = coef * rx * y1p / ry
        val cyp = -coef * ry * x1p / rx
        val cx = cp * cxp - sp * cyp + (x1 + x2) / 2.0
        val cy = sp * cxp + cp * cyp + (y1 + y2) / 2.0
        fun ang(ux: Double, uy: Double, vx: Double, vy: Double): Double {
            val a = Math.atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        val theta1 = ang(1.0, 0.0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var dtheta = ang((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if (!sweep && dtheta > 0) dtheta -= 2 * Math.PI
        if (sweep && dtheta < 0) dtheta += 2 * Math.PI
        val segs = ceil(abs(dtheta) / (Math.PI / 2)).toInt().coerceAtLeast(1)
        val delta = dtheta / segs
        val t = 4.0 / 3.0 * tan(delta / 4)
        var th = theta1
        for (s in 0 until segs) {
            val c1 = cos(th); val s1 = sin(th)
            val th2 = th + delta
            val c2 = cos(th2); val s2 = sin(th2)
            // Unit-circle points and controls, then scaled, rotated, moved.
            fun px(ux: Double, uy: Double) = (cx + rx * ux * cp - ry * uy * sp).toFloat()
            fun py(ux: Double, uy: Double) = (cy + rx * ux * sp + ry * uy * cp).toFloat()
            path.cubicTo(
                px(c1 - t * s1, s1 + t * c1), py(c1 - t * s1, s1 + t * c1),
                px(c2 + t * s2, s2 - t * c2), py(c2 + t * s2, s2 - t * c2),
                px(c2, s2), py(c2, s2),
            )
            th = th2
        }
    }
}

/**
 * A native window's page: draws the node tree (boxes, text, icons) on a
 * Canvas in CSS px (scaled by the density), and holds the fields as real
 * EditText/Spinner children placed at their nodes' content boxes.
 */
@SuppressLint("ViewConstructor")
internal class NuiView(context: Context, val window: Int, private val transparent: Boolean, private val onSize: (Int, Int) -> Unit) : FrameLayout(context) {
    private val nodes = HashMap<Int, NuiNode>()
    private val fields = HashMap<Int, View>()
    /** Each select's value as last shown (the page's, or the user's pick). */
    private val selectValues = HashMap<Int, String>()
    /** Each <canvas> node's bitmap, kept between paints (OrielCanvas.kt). */
    private val canvases = HashMap<Int, CanvasSurface>()
    private var frames = FloatArray(0)
    /** `frames` as ints: each record's node id (slot 0). */
    private var ids = IntArray(0)
    private val index = HashMap<Int, Int>() // node id → record
    /** Device pixels per CSS px (Nui.cssScale): the display's density, a
     *  little less where its width in DIPs isn't whole. */
    private var density = resources.displayMetrics.density
    /** The display's density as the page last heard it (devicePixelRatio). */
    private var dpr = resources.displayMetrics.density
    private var updating = false
    /** The page prevented the last Enter (its key up is consumed too). */
    private var enterTaken = false
    private var dark = Nui.isDark(resources.configuration)
    /** Under the page: the root's background; else white, as in a browser, or nothing in a transparent window. */
    private val pageDefault = if (transparent) Color.TRANSPARENT else Color.WHITE
    private var background: Int = pageDefault

    // Keep Zig's requested frame pending while the window is hidden. A
    // background game must not run its rAF/physics loop at display speed.
    // The same callback is reused, and only one is posted for this view.
    private var displayRequested = false
    private var displayPosted = false
    private val displayCallback = Choreographer.FrameCallback {
        displayPosted = false
        if (displayRequested && canDisplayFrame() && Nui.views[window] === this) {
            displayRequested = false
            Nui.displayFrame(this)
        }
    }

    fun requestDisplayFrame() {
        displayRequested = true
        updateDisplayFrame()
    }

    private fun canDisplayFrame() = isAttachedToWindow && windowVisibility == VISIBLE && isShown

    private fun updateDisplayFrame() {
        val choreographer = Choreographer.getInstance()
        if (!canDisplayFrame()) {
            if (displayPosted) choreographer.removeFrameCallback(displayCallback)
            displayPosted = false
        } else if (displayRequested && !displayPosted) {
            displayPosted = true
            choreographer.postFrameCallback(displayCallback)
        }
    }

    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
    private val shadowPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val path = Path()
    private val rect = RectF()

    init {
        setWillNotDraw(false)
        isFocusableInTouchMode = true
        // The page draws its own focus (:focus-visible): no system highlight over the whole view.
        defaultFocusHighlightEnabled = false
        clipChildren = true
    }

    // --- From Zig ---------------------------------------------------------

    fun props(id: Int, kind: String, json: String) = props(id, kind, JSONObject(json))

    fun props(id: Int, kind: String, json: JSONObject) {
        val n = nodes.getOrPut(id) { NuiNode(id, kind) }
        n.update(json, kind)
        orderDirty = true // z-index or position may have changed
        if (kind == "image") decodeImage(n)
        if (n.p.optBoolean("root")) background = n.bg ?: pageDefault
        val f = fields[id]
        if (f != null) styleField(n, f)
    }

    /**
     * An <img>'s picture: a base64 data: URI or an app asset path. The
     * bytes may come from outside (a clipboard image), so the size is read
     * first and a large picture is downsampled: a small PNG can declare
     * 30000 x 30000 pixels (3.6 GB decoded).
     */
    private fun decodeImage(n: NuiNode) {
        val src = n.p.optString("src", "")
        // Decoded, the src isn't needed: don't keep a data: URI in the props.
        n.p.remove("src")
        val key = (src.length.toLong() shl 32) or (src.hashCode().toLong() and 0xffffffffL)
        if (key == n.imageKey) return
        n.imageKey = key
        n.image = null
        n.imageW = 0
        n.imageH = 0
        if (src.isEmpty()) return
        val bytes = try {
            if (src.startsWith("data:")) {
                val comma = src.indexOf(',')
                if (comma < 0 || !src.substring(0, comma).contains(";base64")) null
                else android.util.Base64.decode(src.substring(comma + 1), android.util.Base64.DEFAULT)
            } else NuiNative.asset(window, src.bytes())
        } catch (e: IllegalArgumentException) { null } catch (e: OutOfMemoryError) { null }
        if (bytes == null) return imageFailed(src)
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return imageFailed(src)
        var sample = 1
        while (bounds.outWidth / sample > MAX_IMAGE_SIDE || bounds.outHeight / sample > MAX_IMAGE_SIDE) sample *= 2
        n.image = try {
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })
        } catch (e: OutOfMemoryError) { null }
        if (n.image == null) return imageFailed(src)
        n.imageW = bounds.outWidth
        n.imageH = bounds.outHeight
    }

    private fun imageFailed(src: String) {
        android.util.Log.w("Oriel", "native ui: image ${src.take(48)}: can't decode")
    }

    fun text(id: Int, t: String) {
        if (nodes[id]?.setText(t) == true) invalidate()
    }

    /** ORIEL_NUI_DUMP: each record as NuiView will draw it (ids left out:
     *  they differ between runtimes), between "nui dump begin" and "end". */
    private fun dumpFrames() {
        val f = frames
        Log.d("OrielNui", "nui dump begin $window")
        var i = 0
        while (i + REC <= f.size) {
            val n = nodes[ids[i]]
            val t = n?.textForDump() ?: ""
            Log.d("OrielNui", "nui dump ${n?.kind ?: "?"} ${"%.1f %.1f %.1f %.1f".format(f[i + 1], f[i + 2], f[i + 3], f[i + 4])} bg=${n?.bg} fz=${n?.p?.optDouble("fz", 0.0)} \"$t\" ${n?.p}")
            i += REC
        }
        Log.d("OrielNui", "nui dump end $window")
    }

    /** Leaf styles, parsed once (NuiNode templates), by style id. */
    private val leafStyles = HashMap<Int, NuiNode>()

    /**
     * One batch of changes from android.zig (flushLeaves), packed
     * little-endian, in order:
     * 'S' style id, JSON length, JSON: a leaf style (host.leaf, stamping);
     * 'L' node id, kind (0 view, 1 text), style id, text length, text: a
     * node made from one; 'T' node id, text length, text: a run's new text;
     * 'X' node id, opacity, scale, rotation: an animation frame's change;
     * 'C' node id, op count, ops: a canvas's new program;
     * 'P' node id, kind, props: a node's props (a binary value, readValue);
     * 'Y' style id, props: a leaf style as a binary value.
     */
    fun leaves(bytes: ByteArray) {
        val b = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        while (b.remaining() >= 9) {
            val tag = b.get().toInt().toChar()
            val id = b.int
            when (tag) {
                'S' -> {
                    val json = utf8(b, b.int) ?: return
                    leafStyles[id] = NuiNode(id, "style").also { it.update(json, "style") }
                }
                'Y' -> {
                    val props = readValue(b) as? JSONObject ?: return
                    leafStyles[id] = NuiNode(id, "style").also { it.update(props, "style") }
                }
                'P' -> {
                    val kind = utf8(b, b.int) ?: return
                    val props = readValue(b) as? JSONObject ?: return
                    props(id, kind, props)
                }
                'L' -> {
                    val kind = if (b.get().toInt() == 1) "text" else "view"
                    val style = leafStyles[b.int]
                    val text = utf8(b, b.int) ?: return
                    if (style == null) continue // not sent (an id beyond an int): not drawn
                    nodes[id] = NuiNode(id, kind).also { it.fromStyle(style, if (kind == "text") text else null) }
                }
                'T' -> {
                    val text = utf8(b, b.int) ?: return
                    nodes[id]?.setText(text)
                }
                'X' -> {
                    val op = b.float
                    val sc = b.float
                    val rot = b.float
                    nodes[id]?.let { it.op = op; it.sc = sc; it.rot = rot }
                }
                'C' -> {
                    val ops = CanvasProgram.unpack(b, b.int) ?: return
                    nodes[id]?.canvasOps = ops
                }
                else -> return
            }
        }
        orderDirty = true
        invalidate()
    }

    /**
     * A binary value (android.zig's putValue) as the JSONObject/JSONArray
     * the JSON would have parsed to: a type byte (0 null, 1 false, 2 true,
     * 3 int, 4 double, 5 string, 6 array, 7 object), then the value; an
     * object's keys index PROP_KEYS, or 255 and the key as a string.
     */
    private fun readValue(b: ByteBuffer): Any? = when (b.get().toInt()) {
        0 -> JSONObject.NULL
        1 -> false
        2 -> true
        3 -> b.int
        4 -> b.double
        5 -> utf8(b, b.int)
        6 -> JSONArray().also { a -> repeat(b.int) { a.put(readValue(b)) } }
        7 -> JSONObject().also { o ->
            repeat(b.int) {
                val k = b.get().toInt() and 0xff
                val key = if (k == 255) utf8(b, b.int) ?: return null else PROP_KEYS.getOrNull(k) ?: return null
                o.put(key, readValue(b))
            }
        }
        else -> null
    }

    private fun utf8(b: ByteBuffer, len: Int): String? {
        if (len < 0 || len > b.remaining()) return null
        val s = String(b.array(), b.arrayOffset() + b.position(), len, Charsets.UTF_8)
        b.position(b.position() + len)
        return s
    }

    fun remove(id: Int) {
        nodes.remove(id)
        canvases.remove(id)?.recycle()
        selectValues.remove(id)
        fields.remove(id)?.let { removeView(it) }
    }

    fun measureText(id: Int, max64: Int): Long = nodes[id]?.measure(max64) ?: 0

    /** Node ids (little-endian ints) to their unbounded sizes (little-endian longs, as measureText). */
    fun measureTexts(ids: ByteArray): ByteArray {
        val n = ids.size / 4
        val inb = ByteBuffer.wrap(ids).order(ByteOrder.LITTLE_ENDIAN)
        val out = ByteBuffer.allocate(n * 8).order(ByteOrder.LITTLE_ENDIAN)
        for (i in 0 until n) out.putLong(nodes[inb.getInt()]?.measure(-1) ?: 0)
        return out.array()
    }

    fun frames(bytes: ByteArray) {
        val bb = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        val fb = bb.asFloatBuffer()
        frames = FloatArray(fb.remaining()).also { fb.get(it) }
        // A record's first slot is its node's id as int bits (android.zig's
        // pack): read as an int, not a float, so no id is rounded or a NaN.
        ids = IntArray(frames.size).also { bb.asIntBuffer().get(it) }
        index.clear()
        var i = 0
        while (i + REC <= frames.size) { index[ids[i]] = i; i += REC }
        orderDirty = true
        if (Nui.dump) dumpFrames()
        syncFields()
        requestLayout()
        invalidate()
    }

    fun value(id: Int, v: String) {
        // The page set it from its beforeinput, while the field's filter is
        // still editing: after that edit.
        if (filtering) { post { value(id, v) }; return }
        val f = fields[id] ?: makeField(id) ?: return
        updating = true
        try {
            when (f) {
                is SeekBar -> rangeOf(nodes[id])?.let { f.progress = it.progress(v) }
                is EditText -> {
                    if (f.text.toString() != v) { f.setText(v); f.setSelection(v.length) }
                    (f as? Field)?.sent = v
                }
                is Spinner -> {
                    selectValues[id] = v
                    options(nodes[id])?.indexOfFirst { it.first == v }?.let { if (it >= 0) f.setSelection(it) }
                }
            }
        } finally { updating = false }
    }

    fun focusField(id: Int) {
        val f = fields[id]
        if (f == null) {
            // The page focused something that isn't a field (a button, a link,
            // its Tab navigation): the keys come back to the page's view.
            if (findFocus() is EditText) hideKeyboard() else if (findFocus() !== this) requestFocus()
            return
        }
        f.requestFocus()
        if (f is EditText) context.getSystemService(InputMethodManager::class.java)?.showSoftInput(f, 0)
    }

    // --- Size ---------------------------------------------------------------

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        updateDisplayFrame()
    }

    override fun onWindowVisibilityChanged(visibility: Int) {
        super.onWindowVisibilityChanged(visibility)
        updateDisplayFrame()
    }

    override fun onVisibilityChanged(changedView: View, visibility: Int) {
        super.onVisibilityChanged(changedView, visibility)
        if (isAttachedToWindow) updateDisplayFrame()
    }

    /** Out of its window: the canvases' bitmaps go (the next paint makes new ones). */
    override fun onDetachedFromWindow() {
        if (displayPosted) Choreographer.getInstance().removeFrameCallback(displayCallback)
        displayPosted = false
        super.onDetachedFromWindow()
        for (c in canvases.values) c.recycle()
        canvases.clear()
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        density = Nui.cssScale(w, resources.displayMetrics.density)
        onSize(w, h)
        if (w > 0 && h > 0) NuiNative.resize(window, w / density, h / density, dark)
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        // Another display (a ChromeOS window moved): the page's devicePixelRatio.
        val scale = resources.displayMetrics.density
        if (scale != dpr) {
            dpr = scale
            if (width > 0) density = Nui.cssScale(width, scale)
            NuiNative.event(window, 0, "dpr".bytes(), scale.toString().bytes())
        }
        val d = Nui.isDark(newConfig)
        if (d != dark) {
            dark = d
            if (width > 0) NuiNative.resize(window, width / density, height / density, dark)
        }
    }

    // --- Fields ---------------------------------------------------------------

    private fun isField(kind: String) = kind == "input" || kind == "textarea" || kind == "select"

    private fun syncFields() {
        // What's drawn over the page: the root's children after the scroll view (fixed elements).
        val fixed = ArrayList<RectF>()
        if (frames.size >= REC * 2) {
            var k = REC + REC * (1 + frames[REC + 13].toInt())
            val end = REC * (1 + frames[13].toInt())
            while (k < end) {
                fixed += RectF(frames[k + 1], frames[k + 2], frames[k + 1] + frames[k + 3], frames[k + 2] + frames[k + 4])
                k += REC * (1 + frames[k + 13].toInt())
            }
        }
        // A snapshot: making or hiding a field can run callbacks that change `nodes`.
        for (n in nodes.values.toList()) {
            if (!isField(n.kind)) continue
            val f = fields[n.id] ?: makeField(n.id) ?: continue
            val r = index[n.id]
            val vis = if (r != null && frames[r + 3] > 1) visibleRect(r, fixed + paintedOver(r)) else null
            if (vis == null) { f.visibility = INVISIBLE; continue }
            f.visibility = VISIBLE
            // The widget sits at the content box: clip it to the visible part.
            val cx = frames[r!! + 9]; val cy = frames[r + 10]
            f.clipBounds = android.graphics.Rect(
                ((vis.left - cx) * density).toInt(), ((vis.top - cy) * density).toInt(),
                ((vis.right - cx) * density).toInt(), ((vis.bottom - cy) * density).toInt(),
            )
        }
    }

    /**
     * The visible boxes with a background painted after the field at record
     * `r` (in paint order, after its subtree): a sticky footer, a z-index bar. The
     * canvas draws them over the field, but its widget sits above the canvas.
     */
    private fun paintedOver(r: Int): List<RectF> {
        val out = ArrayList<RectF>()
        ensurePaintOrder()
        val from = paintEnd[r] ?: return out
        for (pos in from until paintOrder.size) {
            val k = paintOrder[pos]
            val n = nodes[ids[k]]
            if (n != null && (n.bg?.let { Color.alpha(it) > 0 } == true || n.gradient != null)) {
                val v = RectF(frames[k + 1], frames[k + 2], frames[k + 1] + frames[k + 3], frames[k + 2] + frames[k + 4])
                if (v.intersect(frames[k + 5], frames[k + 6], frames[k + 5] + frames[k + 7], frames[k + 6] + frames[k + 8])) out += v
            }
        }
        return out
    }

    /** A field's content box inside its clip, minus the bars over it; null if hidden. */
    private fun visibleRect(r: Int, overlays: List<RectF>): RectF? {
        val v = RectF(frames[r + 9], frames[r + 10], frames[r + 9] + frames[r + 11], frames[r + 10] + frames[r + 12])
        if (!v.intersect(frames[r + 5], frames[r + 6], frames[r + 5] + frames[r + 7], frames[r + 6] + frames[r + 8])) return null
        for (o in overlays) {
            if (o.left > v.left || o.right < v.right) continue // only bars across the field
            if (o.top <= v.top && o.bottom > v.top) v.top = o.bottom
            if (o.bottom >= v.bottom && o.top < v.bottom) v.bottom = o.top
        }
        return if (v.height() > 1 && v.width() > 1) v else null
    }

    private fun options(n: NuiNode?): List<Pair<String, String>>? {
        val a = n?.p?.optJSONArray("options") ?: return null
        return (0 until a.length()).map { val o = a.optJSONArray(it); (o?.optString(0) ?: "") to (o?.optString(1) ?: "") }
    }

    /** A text field: its edit in progress (beforeinput's type and data, for
     *  the input after it), the value last sent, and a context menu's action. */
    private class Field(ctx: Context) : EditText(ctx) {
        var editType: String? = null
        var editData: String? = null
        var sent = ""
        var menu = 0
        override fun onTextContextMenuItem(id: Int): Boolean {
            menu = id
            try { return super.onTextContextMenuItem(id) } finally { menu = 0 }
        }
    }

    /** A field's filter is asking the page (its beforeinput). */
    private var filtering = false
    /** The hardware key a field is handling (dispatchKeyEvent), for the edit it makes. */
    private var editKey: KeyEvent? = null

    /**
     * An edit about to replace dest[dstart, dend) with source[start, end)
     * (InputFilter): beforeinput on the field, with Chromium's inputType;
     * prevented, the old text stays. An input method's composition is the
     * field's own (no beforeinput: docs "Field edits and selection").
     */
    private fun beforeInput(f: Field, id: Int, multi: Boolean, source: CharSequence, start: Int, end: Int, dest: Spanned, dstart: Int, dend: Int): CharSequence? {
        f.editType = null; f.editData = null
        if (updating || filtering) return null
        if (source is Spannable && BaseInputConnection.getComposingSpanStart(source) >= 0) return null
        if (dest is Spannable) {
            val cs = BaseInputConnection.getComposingSpanStart(dest)
            val ce = BaseInputConnection.getComposingSpanEnd(dest)
            if (cs >= 0 && dstart >= min(cs, ce) && dend <= max(cs, ce)) return null
        }
        val text = source.subSequence(start, end).toString()
        if (text.isEmpty() && dstart == dend) return null
        val key = editKey
        val ctrl = key?.isCtrlPressed == true
        val (type, data) = when {
            f.menu == android.R.id.paste || f.menu == android.R.id.pasteAsPlainText || (ctrl && key?.keyCode == KeyEvent.KEYCODE_V) ->
                "insertFromPaste" to (if (multi) text else text.replace(Regex("\r\n|\n|\r"), ""))
            f.menu == android.R.id.cut || (ctrl && key?.keyCode == KeyEvent.KEYCODE_X) -> "deleteByCut" to null
            f.menu == android.R.id.undo || (ctrl && key?.keyCode == KeyEvent.KEYCODE_Z) -> "historyUndo" to null
            f.menu == android.R.id.redo -> "historyRedo" to null
            text.isEmpty() -> (if (key?.keyCode == KeyEvent.KEYCODE_FORWARD_DEL) "deleteContentForward" else "deleteContentBackward") to null
            multi && text == "\n" -> "insertLineBreak" to null
            else -> "insertText" to text
        }
        filtering = true
        val prevented = try {
            NuiNative.event(window, id, "beforeinput".bytes(), JSONArray().put(type).put(data ?: JSONObject.NULL).toString().bytes())
        } finally { filtering = false }
        if (prevented) return dest.subSequence(dstart, dend)
        // As Chromium: a paste's input carries no data.
        f.editType = type; f.editData = if (type == "insertFromPaste") null else data
        return null
    }

    /** A text field's selection, start and end in UTF-16 units (packed), or -1 (android.zig selection). */
    fun selection(id: Int): Long {
        val f = fields[id] as? EditText ?: return -1
        val a = f.selectionStart; val b = f.selectionEnd
        if (a < 0 || b < 0) return -1
        return (min(a, b).toLong() shl 32) or max(a, b).toLong()
    }

    /** Select start..end of a text field (el.setSelectionRange). */
    fun setSelection(id: Int, start: Int, end: Int) {
        val f = fields[id] as? EditText ?: return
        val len = f.text.length
        f.setSelection(start.coerceIn(0, len), end.coerceIn(0, len))
    }

    private fun makeField(id: Int): View? {
        val n = nodes[id] ?: return null
        val v: View = if (n.kind == "input" && n.p.has("range")) slider(n, id) else when (n.kind) {
            "input", "textarea" -> Field(context).apply {
                background = null
                setPadding(0, 0, 0, 0)
                val multi = n.kind == "textarea"
                inputType = when {
                    n.p.optBoolean("pw") -> InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
                    multi -> InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
                    else -> InputType.TYPE_CLASS_TEXT
                }
                gravity = if (multi) Gravity.TOP or Gravity.START else Gravity.CENTER_VERTICAL or Gravity.START
                if (!multi) { isSingleLine = true; imeOptions = EditorInfo.IME_ACTION_DONE }
                sent = n.p.optString("val")
                val field = this
                // Every edit (keys, the soft keyboard's commits, paste, cut,
                // undo) asks the page first: beforeinput, as Chromium names it.
                filters = arrayOf(InputFilter { source, start, end, dest, dstart, dend -> beforeInput(field, id, multi, source, start, end, dest, dstart, dend) })
                addTextChangedListener(object : TextWatcher {
                    override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                    override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                    override fun afterTextChanged(s: Editable?) {
                        if (updating) return
                        val v = s?.toString() ?: ""
                        val type = field.editType
                        val data = field.editData
                        field.editType = null; field.editData = null
                        // A prevented edit puts back what was there: nothing changed.
                        if (v == field.sent) return
                        field.sent = v
                        // [value, inputType, data]; a composition's (no type) as a plain value.
                        if (type == null) NuiNative.event(window, id, "input".bytes(), v.bytes())
                        else NuiNative.event(window, id, "edit".bytes(), JSONArray().put(v).put(type).put(data ?: JSONObject.NULL).toString().bytes())
                    }
                })
                // Enter: the page's keydown (it may send a chat message). A
                // hardware Enter calls this on both key down and key up: only
                // the down counts. In a text area, Enter the page doesn't
                // prevent (or Shift+Enter) is a new line.
                setOnEditorActionListener { _, action, ev ->
                    if (action != EditorInfo.IME_ACTION_DONE && action != EditorInfo.IME_NULL) return@setOnEditorActionListener false
                    if (ev != null && ev.action != KeyEvent.ACTION_DOWN) return@setOnEditorActionListener multi.not() || enterTaken
                    var mods = 0
                    if (ev?.isShiftPressed == true) mods = mods or 1
                    if (ev?.isCtrlPressed == true) mods = mods or 2
                    if (ev?.isAltPressed == true) mods = mods or 4
                    if (ev?.isMetaPressed == true) mods = mods or 8
                    // A hardware Enter's keydown already reached the page (dispatchKeyEvent).
                    val prevented = if (ev != null && fieldKeySent) false
                        else NuiNative.event(window, id, "key".bytes(), "[\"Enter\",$mods]".bytes())
                    enterTaken = prevented
                    !multi || prevented
                }
            }
            "select" -> Spinner(context).apply {
                background = null
                setPadding(0, 0, 0, 0)
                onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
                    override fun onItemSelected(parent: AdapterView<*>?, view: View?, pos: Int, rowId: Long) {
                        if (updating) return
                        val o = options(nodes[id]) ?: return
                        if (pos !in o.indices) return
                        // Android also calls this after the first layout, with
                        // what the page already shows: only a new value is a change.
                        if (selectValues[id] == o[pos].first) return
                        selectValues[id] = o[pos].first
                        NuiNative.event(window, id, "change".bytes(), o[pos].first.bytes())
                    }
                    override fun onNothingSelected(parent: AdapterView<*>?) {}
                }
            }
            else -> return null
        }
        // Posted, not sent: Android changes focus synchronously while Zig is
        // calling into Kotlin (a focused field removed while its node is
        // destroyed, hidden while the frames are applied), and the page's
        // handler could then render and free nodes in the middle of that.
        v.setOnFocusChangeListener { _, has ->
            val kind = if (has) "focus" else "blur"
            post { if (Nui.views[window] === this) NuiNative.event(window, id, kind.bytes(), ByteArray(0)) }
        }
        fields[id] = v
        styleField(n, v)
        addView(v)
        return v
    }

    /**
     * <input type=range>: a SeekBar over the page's min/max/step (`range`).
     * Dragging sends `input` with the value as text, letting go `change`.
     */
    private class Range(val min: Double, val max: Double, step: Double) {
        val stepSize = if (step > 0) step else (max - min) / 1000
        val steps = if (max > min && stepSize > 0) ((max - min) / stepSize).roundToInt().coerceIn(1, 100_000) else 1
        fun progress(v: String) = v.toDoubleOrNull()?.let { ((it.coerceIn(min, max) - min) / stepSize).roundToInt().coerceIn(0, steps) } ?: 0
        fun value(progress: Int): String {
            val x = (min + progress * stepSize).coerceIn(min, max)
            return if (x == floor(x) && abs(x) < 1e15) x.toLong().toString()
            else String.format(java.util.Locale.ROOT, "%.6f", x).trimEnd('0').trimEnd('.')
        }
    }

    private fun rangeOf(n: NuiNode?): Range? {
        val r = n?.p?.optJSONArray("range") ?: return null
        return Range(r.optDouble(0, 0.0), r.optDouble(1, 100.0), r.optDouble(2, 1.0))
    }

    private fun slider(n: NuiNode, id: Int): View = SeekBar(context).apply {
        setPadding(0, 0, 0, 0)
        val r = rangeOf(n) ?: Range(0.0, 100.0, 1.0)
        max = r.steps
        setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(bar: SeekBar, progress: Int, fromUser: Boolean) {
                if (!fromUser || updating) return
                val value = (rangeOf(nodes[id]) ?: r).value(progress)
                NuiNative.event(window, id, "input".bytes(), value.bytes())
            }
            override fun onStartTrackingTouch(bar: SeekBar) {}
            override fun onStopTrackingTouch(bar: SeekBar) {
                val value = (rangeOf(nodes[id]) ?: r).value(bar.progress)
                NuiNative.event(window, id, "change".bytes(), value.bytes())
            }
        })
    }

    /** A select's options, drawn with the node's font size and color. */
    private inner class Options(val id: Int, val labels: List<String>) : ArrayAdapter<String>(context, android.R.layout.simple_spinner_item, labels) {
        init { setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item) }

        override fun getView(position: Int, convertView: View?, parent: android.view.ViewGroup): View {
            val v = super.getView(position, convertView, parent) as TextView
            val p = nodes[id]?.p
            v.setTextColor(p?.optJSONArray("col")?.let { NuiNode.color(it) } ?: Color.BLACK)
            v.setTextSize(TypedValue.COMPLEX_UNIT_DIP, p?.optDouble("fz", 16.0)?.toFloat() ?: 16f)
            v.setPadding(0, 0, 0, 0)
            v.isSingleLine = true
            v.ellipsize = TextUtils.TruncateAt.END
            return v
        }
    }

    private fun styleField(n: NuiNode, v: View) {
        val color = n.p.optJSONArray("col")?.let { NuiNode.color(it) } ?: Color.BLACK
        val fz = n.p.optDouble("fz", 16.0).toFloat()
        v.isEnabled = !n.p.optBoolean("dis")
        if (v is SeekBar) {
            val r = rangeOf(n)
            updating = true
            try {
                if (r != null) {
                    v.max = r.steps
                    if (n.p.has("val")) v.progress = r.progress(n.p.optString("val"))
                }
            } finally { updating = false }
            n.p.optJSONArray("acc")?.let { NuiNode.color(it) }?.let {
                val tint = android.content.res.ColorStateList.valueOf(it)
                v.progressTintList = tint
                v.thumbTintList = tint
            }
        }
        if (v is Spinner) {
            // New options (the page fills a select later): a new adapter, the
            // page's value selected again, without a change event.
            val opts = options(n) ?: emptyList()
            val labels = opts.map { it.second }
            val current = v.adapter as? Options
            updating = true
            try {
                if (current == null || current.labels != labels) v.adapter = Options(n.id, labels)
                else current.notifyDataSetChanged()
                val value = n.p.optString("val", "")
                selectValues[n.id] = value
                val i = opts.indexOfFirst { it.first == value }
                if (i >= 0 && i != v.selectedItemPosition) v.setSelection(i, false)
            } finally { updating = false }
        }
        if (v is EditText) {
            v.setTextColor(color)
            v.setHintTextColor((color and 0x00ffffff) or 0x80000000.toInt())
            v.setTextSize(TypedValue.COMPLEX_UNIT_DIP, fz)
            v.hint = n.p.optString("ph", "")
        }
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        setMeasuredDimension(MeasureSpec.getSize(widthMeasureSpec), MeasureSpec.getSize(heightMeasureSpec))
        for ((id, v) in fields) {
            val r = index[id]
            val w = if (r != null) (frames[r + 11] * density).toInt().coerceAtLeast(1) else 1
            val h = if (r != null) (frames[r + 12] * density).toInt().coerceAtLeast(1) else 1
            v.measure(MeasureSpec.makeMeasureSpec(w, MeasureSpec.EXACTLY), MeasureSpec.makeMeasureSpec(h, MeasureSpec.EXACTLY))
        }
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        for ((id, v) in fields) {
            val i = index[id] ?: continue
            val x = (frames[i + 9] * density).toInt()
            val y = (frames[i + 10] * density).toInt()
            v.layout(x, y, x + v.measuredWidth, y + v.measuredHeight)
        }
    }

    // --- Touch ------------------------------------------------------------------

    private val slop = ViewConfiguration.get(context).scaledTouchSlop
    private val scroller = OverScroller(context)
    private var velocity: VelocityTracker? = null
    private var downX = 0f
    private var downY = 0f
    private var lastY = 0f
    private var lastX = 0f
    private var dragging = false
    /** The drag scrolls sideways (it started more across than down). */
    private var sideways = false
    private var longPressed = false
    /** The page heard this touch's down and no up or cancel yet. */
    private var pointerDown = false
    /** The page took the touch's drag (touch-action: none, or it prevented
     *  the pointerdown): no scrolling, fling or long press. */
    private var pageDrag = false
    /** The touch is the mouse (ChromeOS): its drags don't scroll. */
    private var mouseTouch = false
    private val longPress = Runnable {
        longPressed = true
        if (NuiNative.longPress(window, downX / density, downY / density)) performHapticFeedback(HAPTIC_FEEDBACK_ENABLED)
    }

    /**
     * A vertical drag that starts on a field (EditText, Spinner) scrolls the
     * page, as in a ScrollView: past the touch slop the page takes it over
     * (the field gets a cancel), unless the field scrolls its own text.
     */
    override fun onInterceptTouchEvent(e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> { downX = e.x; downY = e.y }
            MotionEvent.ACTION_MOVE -> {
                val dy = e.y - downY
                if (abs(dy) <= slop || abs(dy) < abs(e.x - downX)) return false
                val under = fields.values.firstOrNull { it.visibility == VISIBLE && downX >= it.left && downX < it.right && downY >= it.top && downY < it.bottom }
                if (under != null && under.canScrollVertically(if (dy < 0) 1 else -1)) return false
                scroller.forceFinished(true)
                removeCallbacks(longPress)
                dragging = true; sideways = false; longPressed = false; lastY = e.y; lastX = e.x
                velocity?.recycle()
                velocity = VelocityTracker.obtain().also { it.addMovement(e) }
                return true
            }
        }
        return false
    }

    /** Shift 1, control 2, alt 4, meta 8 (the DOM's modifier keys). */
    private fun mods(meta: Int): Int =
        (if (meta and KeyEvent.META_SHIFT_ON != 0) 1 else 0) or (if (meta and KeyEvent.META_CTRL_ON != 0) 2 else 0) or
            (if (meta and KeyEvent.META_ALT_ON != 0) 4 else 0) or (if (meta and KeyEvent.META_META_ON != 0) 8 else 0)

    /** The pressed buttons as the DOM's `buttons` (a finger: the primary). */
    private fun buttons(e: MotionEvent): Int {
        if (!mouseTouch) return 1
        val b = e.buttonState
        return (if (b and MotionEvent.BUTTON_PRIMARY != 0) 1 else 0) or (if (b and MotionEvent.BUTTON_SECONDARY != 0) 2 else 0) or
            (if (b and MotionEvent.BUTTON_TERTIARY != 0) 4 else 0)
    }

    private fun pointer(phase: Int, e: MotionEvent, buttons: Int): Boolean =
        NuiNative.pointer(window, phase, e.x / density, e.y / density, buttons, mouseTouch, mods(e.metaState))

    /** The page's pointer goes: cancelled (a scroll took the touch) or up. */
    private fun endPointer(phase: Int, e: MotionEvent) {
        if (!pointerDown) return
        pointerDown = false
        pointer(phase, e, if (mouseTouch && phase == 2) buttons(e) else 0)
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                scroller.forceFinished(true)
                downX = e.x; downY = e.y; lastY = e.y
                dragging = false; longPressed = false
                mouseTouch = e.getToolType(0) == MotionEvent.TOOL_TYPE_MOUSE
                velocity?.recycle()
                velocity = VelocityTracker.obtain().also { it.addMovement(e) }
                NuiNative.press(window, e.x / density, e.y / density, true)
                pointerDown = true
                pageDrag = pointer(0, e, buttons(e))
                if (!pageDrag && !mouseTouch) postDelayed(longPress, ViewConfiguration.getLongPressTimeout().toLong())
                if (!hasFocus()) requestFocus()
            }
            MotionEvent.ACTION_MOVE -> {
                velocity?.addMovement(e)
                val beyond = abs(e.y - downY) > slop || abs(e.x - downX) > slop
                // The page's drag, or the mouse's: the page hears every move, nothing scrolls.
                if (pageDrag || mouseTouch) {
                    if (!dragging && beyond) {
                        dragging = true
                        removeCallbacks(longPress)
                        NuiNative.press(window, 0f, 0f, false) // a drag isn't a press
                    }
                    if (pointerDown) pointer(1, e, buttons(e))
                    return true
                }
                if (!dragging && beyond) {
                    dragging = true
                    sideways = abs(e.x - downX) > abs(e.y - downY)
                    removeCallbacks(longPress)
                    NuiNative.press(window, 0f, 0f, false) // a drag isn't a press
                    // The page scrolls: its pointer is cancelled, as in a browser.
                    endPointer(3, e)
                    lastY = e.y
                    lastX = e.x
                } else if (!dragging && pointerDown) {
                    pointer(1, e, buttons(e))
                }
                if (dragging && sideways) {
                    NuiNative.scrollX(window, downX / density, downY / density, (lastX - e.x) / density)
                    lastX = e.x
                } else if (dragging) {
                    NuiNative.scroll(window, downX / density, downY / density, (lastY - e.y) / density)
                    lastY = e.y
                }
            }
            MotionEvent.ACTION_UP -> {
                removeCallbacks(longPress)
                if (!dragging) NuiNative.press(window, 0f, 0f, false)
                velocity?.addMovement(e)
                // The page hears the lift (pointerup) before the tap's click.
                endPointer(2, e)
                if (!dragging && !longPressed) {
                    hideKeyboard()
                    NuiNative.tap(window, e.x / density, e.y / density)
                } else if (dragging && !pageDrag && !mouseTouch) {
                    val v = velocity
                    v?.computeCurrentVelocity(1000)
                    val vy = v?.yVelocity ?: 0f
                    if (!sideways && abs(vy) > ViewConfiguration.get(context).scaledMinimumFlingVelocity) fling(-vy)
                }
                pageDrag = false
                velocity?.recycle(); velocity = null
            }
            MotionEvent.ACTION_CANCEL -> {
                removeCallbacks(longPress)
                NuiNative.press(window, 0f, 0f, false)
                endPointer(3, e)
                pageDrag = false
                velocity?.recycle(); velocity = null
            }
        }
        return true
    }

    // --- Keys -------------------------------------------------------------------

    /** Tab and Shift+Tab in a field go to the page first (its focus order,
     *  as a browser's), not Android's own focus search. */
    override fun dispatchKeyEvent(e: KeyEvent): Boolean {
        val focused = findFocus()
        // A hardware key in a field reaches the page first, on the field (as a
        // browser's keydown and keyup); what the page prevents the field never
        // gets. Soft keyboards' keys stay the field's: their text comes as
        // input events.
        val field = if (focused != null && focused !== this) fields.entries.firstOrNull { it.value === focused }?.key else null
        if (field != null && e.flags and KeyEvent.FLAG_SOFT_KEYBOARD == 0) {
            val k = keyName(e)
            if (k != null) {
                when (e.action) {
                    KeyEvent.ACTION_DOWN -> {
                        val json = "[${JSONObject.quote(k)},${mods(e.metaState)},${e.repeatCount > 0}]"
                        val prevented = NuiNative.event(window, field, "key".bytes(), json.bytes())
                        fieldKeySent = true
                        if (prevented) { swallowed += e.keyCode; return true }
                        swallowed -= e.keyCode
                    }
                    KeyEvent.ACTION_UP -> {
                        NuiNative.event(window, field, "keyup".bytes(), "[${JSONObject.quote(k)},${mods(e.metaState)}]".bytes())
                        if (swallowed.remove(e.keyCode)) return true
                    }
                }
                // Tab the page didn't prevent: its own focus navigation, not Android's.
                if (e.keyCode == KeyEvent.KEYCODE_TAB) return true
                editKey = e
                return try { super.dispatchKeyEvent(e) } finally { fieldKeySent = false; editKey = null }
            }
        }
        if (e.keyCode == KeyEvent.KEYCODE_TAB && focused != null && focused !== this) {
            val used = when (e.action) {
                KeyEvent.ACTION_DOWN -> onKeyDown(e.keyCode, e)
                KeyEvent.ACTION_UP -> onKeyUp(e.keyCode, e)
                else -> false
            }
            if (used) return true
        }
        return super.dispatchKeyEvent(e)
    }

    /** Key codes whose keydown the page prevented in a field: their keyup stays from the field too. */
    private val swallowed = HashSet<Int>()
    /** While a field handles a hardware key, its keydown already reached the page (Enter's editor action). */
    private var fieldKeySent = false

    /** The page's keydown (with repeat) and keyup; what it prevents is consumed. */
    override fun onKeyDown(keyCode: Int, e: KeyEvent): Boolean {
        val k = keyName(e) ?: return super.onKeyDown(keyCode, e)
        val json = "[${JSONObject.quote(k)},${mods(e.metaState)},${e.repeatCount > 0}]"
        return NuiNative.event(window, 0, "key".bytes(), json.bytes()) || super.onKeyDown(keyCode, e)
    }

    override fun onKeyUp(keyCode: Int, e: KeyEvent): Boolean {
        val k = keyName(e) ?: return super.onKeyUp(keyCode, e)
        val json = "[${JSONObject.quote(k)},${mods(e.metaState)}]"
        return NuiNative.event(window, 0, "keyup".bytes(), json.bytes()) || super.onKeyUp(keyCode, e)
    }

    /** The DOM's `key`: named keys, else the character typed (null: not the page's). */
    private fun keyName(e: KeyEvent): String? = when (e.keyCode) {
        KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> "Enter"
        KeyEvent.KEYCODE_ESCAPE -> "Escape"
        KeyEvent.KEYCODE_TAB -> "Tab"
        KeyEvent.KEYCODE_DEL -> "Backspace"
        KeyEvent.KEYCODE_FORWARD_DEL -> "Delete"
        KeyEvent.KEYCODE_DPAD_UP -> "ArrowUp"
        KeyEvent.KEYCODE_DPAD_DOWN -> "ArrowDown"
        KeyEvent.KEYCODE_DPAD_LEFT -> "ArrowLeft"
        KeyEvent.KEYCODE_DPAD_RIGHT -> "ArrowRight"
        KeyEvent.KEYCODE_MOVE_HOME -> "Home"
        KeyEvent.KEYCODE_MOVE_END -> "End"
        KeyEvent.KEYCODE_PAGE_UP -> "PageUp"
        KeyEvent.KEYCODE_PAGE_DOWN -> "PageDown"
        KeyEvent.KEYCODE_SPACE -> " "
        KeyEvent.KEYCODE_SHIFT_LEFT, KeyEvent.KEYCODE_SHIFT_RIGHT -> "Shift"
        KeyEvent.KEYCODE_CTRL_LEFT, KeyEvent.KEYCODE_CTRL_RIGHT -> "Control"
        KeyEvent.KEYCODE_ALT_LEFT, KeyEvent.KEYCODE_ALT_RIGHT -> "Alt"
        KeyEvent.KEYCODE_META_LEFT, KeyEvent.KEYCODE_META_RIGHT -> "Meta"
        else -> {
            val c = e.getUnicodeChar(e.metaState and (KeyEvent.META_CTRL_MASK or KeyEvent.META_ALT_MASK or KeyEvent.META_META_MASK).inv())
            if (c > 0 && !Character.isISOControl(c)) String(Character.toChars(c)) else null
        }
    }

    /** The mouse wheel and two-finger trackpad scrolling (ChromeOS, desktop mode). */
    override fun onGenericMotionEvent(e: MotionEvent): Boolean {
        if (e.actionMasked == MotionEvent.ACTION_SCROLL && e.isFromSource(android.view.InputDevice.SOURCE_CLASS_POINTER)) {
            val vc = ViewConfiguration.get(context)
            var v = e.getAxisValue(MotionEvent.AXIS_VSCROLL)
            var h = e.getAxisValue(MotionEvent.AXIS_HSCROLL)
            // Shift + wheel scrolls sideways, as in a browser.
            if (e.metaState and KeyEvent.META_SHIFT_ON != 0 && h == 0f) { h = -v; v = 0f }
            var moved = false
            if (v != 0f) {
                scroller.forceFinished(true)
                moved = NuiNative.scroll(window, e.x / density, e.y / density, -v * vc.scaledVerticalScrollFactor / density)
            }
            if (h != 0f) moved = NuiNative.scrollX(window, e.x / density, e.y / density, h * vc.scaledHorizontalScrollFactor / density) || moved
            if (moved) return true
        }
        return super.onGenericMotionEvent(e)
    }

    /** A mouse or trackpad over the page (ChromeOS, desktop mode): :hover. */
    override fun onHoverEvent(e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_HOVER_ENTER, MotionEvent.ACTION_HOVER_MOVE -> {
                NuiNative.hover(window, e.x / density, e.y / density)
                // A hover move for the page's pointer (no buttons), once per frame.
                NuiNative.pointer(window, 1, e.x / density, e.y / density, 0, true, mods(e.metaState))
            }
            MotionEvent.ACTION_HOVER_EXIT -> NuiNative.hover(window, -1f, -1f)
        }
        return super.onHoverEvent(e)
    }

    private fun fling(vy: Float) {
        scroller.fling(0, 0, 0, vy.toInt(), 0, 0, Int.MIN_VALUE / 2, Int.MAX_VALUE / 2)
        var last = 0
        val x = downX / density
        val y = downY / density
        val step = object : Runnable {
            override fun run() {
                if (!scroller.computeScrollOffset()) return
                val cur = scroller.currY
                val moved = NuiNative.scroll(window, x, y, (cur - last) / density)
                last = cur
                if (moved) postOnAnimation(this) else scroller.forceFinished(true)
            }
        }
        postOnAnimation(step)
    }

    private fun hideKeyboard() {
        val focused = findFocus()
        if (focused is EditText) {
            context.getSystemService(InputMethodManager::class.java)?.hideSoftInputFromWindow(windowToken, 0)
            focused.clearFocus()
            requestFocus()
        }
    }

    // --- Drawing --------------------------------------------------------------

    override fun onDraw(canvas: Canvas) {
        try {
            drawPage(canvas)
        } finally {
            if (Nui.trace) Log.d("OrielNui", "nui drawn $window")
        }
    }

    private fun drawPage(canvas: Canvas) {
        canvas.drawColor(background)
        if (frames.size < REC) return
        canvas.save()
        canvas.scale(density, density)
        ensurePaintOrder()
        for (r in topLevel) draw(canvas, r)
        canvas.restore()
    }

    // --- Paint order -------------------------------------------------------------
    // CSS's, as tree.zig's PaintIter: a parent's children by layer (2 × z-index,
    // +1 for a positioned or sticky box), tree order within a layer. A sticky
    // header paints over the rows scrolled under it. Computed once per change.

    private var orderDirty = true
    private var topLevel = IntArray(0)
    /** Each record's children in paint order (records of `frames`). */
    private val kidsInOrder = HashMap<Int, IntArray>()
    /** Every record in paint order, and where each one's subtree ends in it. */
    private var paintOrder = IntArray(0)
    private val paintEnd = HashMap<Int, Int>()

    private fun layerOf(k: Int): Long {
        val p = nodes[ids[k]]?.p ?: return 0
        val positioned = p.has("pos") || p.has("sticky") || p.has("rel")
        val z = (p.opt("z") as? Number)?.toLong() ?: 0L
        return 2 * z + if (positioned) 1 else 0
    }

    private fun ordered(records: List<Int>): IntArray {
        if (records.size < 2) return records.toIntArray()
        val layers = records.map { layerOf(it) }
        if (layers.all { it == layers[0] }) return records.toIntArray()
        // A stable sort: tree order within a layer.
        return records.indices.sortedBy { layers[it] }.map { records[it] }.toIntArray()
    }

    private fun ensurePaintOrder() {
        if (!orderDirty) return
        orderDirty = false
        kidsInOrder.clear()
        paintEnd.clear()
        val f = frames
        val tops = ArrayList<Int>()
        var i = 0
        while (i + REC <= f.size) { tops += i; i += REC * (1 + f[i + 13].toInt()) }
        topLevel = ordered(tops)
        val out = ArrayList<Int>(f.size / REC)
        fun visit(r: Int) {
            out += r
            val end = r + REC * (1 + f[r + 13].toInt())
            val kids = ArrayList<Int>()
            var k = r + REC
            while (k < end && k + REC <= f.size) { kids += k; k += REC * (1 + f[k + 13].toInt()) }
            val order = ordered(kids)
            kidsInOrder[r] = order
            for (c in order) visit(c)
            paintEnd[r] = out.size
        }
        for (r in topLevel) visit(r)
        paintOrder = out.toIntArray()
    }

    /** Record `r` and its subtree (the records after it). */
    private fun draw(canvas: Canvas, r: Int) {
        val f = frames
        val n = nodes[ids[r]]
        val end = r + REC * (1 + f[r + 13].toInt())
        val x = f[r + 1]; val y = f[r + 2]; val w = f[r + 3]; val h = f[r + 4]
        val clipL = f[r + 5]; val clipT = f[r + 6]; val clipR = clipL + f[r + 7]; val clipB = clipT + f[r + 8]
        val visible = x - 40 < clipR && x + w + 40 > clipL && y - 40 < clipB && y + h + 40 > clipT
        if (!visible && end == r + REC) return
        val save = canvas.save()
        canvas.clipRect(clipL, clipT, clipR, clipB)
        // scale and rotate: around the box's center, for it and its children.
        if (n != null && (n.sc != 1f || n.rot != 0f)) {
            if (n.rot != 0f) canvas.rotate(n.rot, x + w / 2, y + h / 2)
            if (n.sc != 1f) canvas.scale(n.sc, n.sc, x + w / 2, y + h / 2)
        }
        if (n != null && n.op < 1f) canvas.saveLayerAlpha(clipL, clipT, clipR, clipB, (n.op * 255).toInt().coerceIn(0, 255))
        if (n != null && visible) {
            // A box over the whole window (a frameless window's rounded
            // panel): square. Android windows are rectangles under a system
            // caption, so the corners would show the window behind the page.
            val fillsWindow = x <= 0.5f && y <= 0.5f && x + w >= width / density - 0.5f && y + h >= height / density - 0.5f
            val radii = if (fillsWindow) null else radii(n, w, h)
            n.shadow?.let { shadow(canvas, it, x, y, w, h, radii) }
            // The color under the gradient (CSS layers).
            n.bg?.let {
                roundRect(x, y, w, h, radii)
                fill.color = it
                canvas.drawPath(path, fill)
            }
            n.gradient?.let { g ->
                val shader = gradient(g, x, y, w, h) ?: return@let
                roundRect(x, y, w, h, radii)
                fill.color = Color.BLACK
                fill.shader = shader
                canvas.drawPath(path, fill)
                fill.shader = null
            }
            n.bw?.let { border(canvas, n, it, x, y, w, h, radii) }
            if (n.kind == "view" && n.p.has("ctl")) control(canvas, n, x, y, w, h)
            when (n.kind) {
                "text" -> n.textLayout(ceil(f[r + 11]).toInt() + 1)?.let {
                    canvas.save()
                    canvas.translate(f[r + 9], f[r + 10])
                    it.draw(canvas)
                    for (ring in n.rings) runRing(canvas, it, ring)
                    canvas.restore()
                }
                "icon" -> n.icon?.let { icon(canvas, it, f[r + 9], f[r + 10], f[r + 11], f[r + 12]) }
                "image" -> n.image?.let {
                    // Clipped to the content edge's curve, as browsers clip a
                    // replaced element: each corner less the border and padding on its sides.
                    val cx = f[r + 9]; val cy = f[r + 10]; val cw = f[r + 11]; val ch = f[r + 12]
                    val inner = inset(radii, cx - x, cy - y, x + w - cx - cw, y + h - cy - ch)
                    val clipped = canvas.save()
                    if (inner != null) { roundRect(cx, cy, cw, ch, inner); canvas.clipPath(path) }
                    image(canvas, it, n.p.optString("fit", "fill"), cx, cy, cw, ch)
                    canvas.restoreToCount(clipped)
                }
                "canvas" -> if (n.canvasOps.isNotEmpty()) {
                    // At the box, clipped to its rounded corners (radii set above).
                    val clip = radii?.let { roundRect(x, y, w, h, it); path }
                    canvases.getOrPut(n.id) { CanvasSurface() }.paint(
                        canvas, n.canvasOps, n.p.optDouble("cw", w.toDouble()).toFloat(), n.p.optDouble("ch", h.toDouble()).toFloat(),
                        x, y, w, h, density, clip,
                    )
                }
            }
        }
        val kids = kidsInOrder[r] ?: IntArray(0)
        val inner = canvas.save()
        // A box that clips (overflow hidden, or a scroller) with rounded
        // corners: its children are clipped to its rounded padding box
        // (tree.zig's roundClips and paddingClip); its own border isn't.
        if (n != null && kids.isNotEmpty() && (n.p.optBoolean("clip") || n.p.optBoolean("scroll") || n.p.optBoolean("scrollx"))) {
            radii(n, w, h)?.let { paddingClip(canvas, x, y, w, h, it, n.bw) }
        }
        for (k in kids) draw(canvas, k)
        canvas.restoreToCount(inner)
        // The outline: after the content and children, outside the box's own clip.
        if (n != null && visible) n.p.optJSONObject("ol")?.let { outline(canvas, it, x, y, w, h, radii(n, w, h)) }
        canvas.restoreToCount(save)
    }

    /**
     * CSS outline (`ol`: w, c, o?, s?, h?, r?), as win32.zig's paintOutline:
     * a border of its own around the border box grown by offset + width, its
     * radii grown as much (a square corner stays square) and at least `r`,
     * solid, dashed or dotted; a focus ring's halo `h`: 1px around it, its
     * corners 1px rounder.
     */
    private fun outline(canvas: Canvas, ol: JSONObject, x: Float, y: Float, w: Float, h: Float, r: FloatArray?) {
        val ow = ol.optDouble("w", 0.0).toFloat()
        val color = NuiNode.color(ol.optJSONArray("c"))
        if (!(ow > 0) || Color.alpha(color) == 0) return
        val grow = ol.optDouble("o", 0.0).toFloat() + ow
        val bx = x - grow; val by = y - grow; val bw = w + 2 * grow; val bh = h + 2 * grow
        if (bw <= 2 * ow || bh <= 2 * ow) return
        val least = ol.optDouble("r", 0.0).toFloat()
        val g = grown(r, grow)
        val outer = FloatArray(8) { max(g?.get(it) ?: 0f, least) }
        ol.optJSONArray("h")?.let { hj ->
            val halo = NuiNode.color(hj)
            if (Color.alpha(halo) == 0) return@let
            roundRect(bx - 0.5f, by - 0.5f, bw + 1, bh + 1, grown(outer, 0.5f))
            stroke.color = halo
            stroke.strokeWidth = 1f
            stroke.strokeJoin = Paint.Join.MITER
            stroke.strokeCap = Paint.Cap.BUTT
            canvas.drawPath(path, stroke)
        }
        val half = ow / 2
        val square = square(outer)
        roundRect(bx + half, by + half, bw - ow, bh - ow, if (square) null else shrunk(outer, half))
        stroke.color = color
        stroke.strokeWidth = ow
        stroke.strokeJoin = Paint.Join.MITER
        stroke.strokeCap = Paint.Cap.BUTT
        val style = ol.optString("s")
        if (style == "dashed" && square) {
            // As Chrome: each side on its own, corner to corner (solid corners),
            // dashes of 2 × width (3 × below 3 px), gaps about the width, evened out.
            val d = if (ow >= 3) 2 * ow else 3 * ow
            val l = bx + half; val t = by + half; val rr = bx + bw - half; val b = by + bh - half
            for ((x0, y0, x1, y1) in listOf(floatArrayOf(bx, t, bx + bw, t), floatArrayOf(bx, b, bx + bw, b), floatArrayOf(l, by, l, by + bh), floatArrayOf(rr, by, rr, by + bh))) {
                val len = abs(x1 - x0) + abs(y1 - y0)
                var n = max(2, Math.round((len + ow) / (d + ow)))
                while (n > 2 && len - n * d < (n - 1) * 0.5f * ow) n--
                val gap = (len - n * d) / (n - 1)
                stroke.pathEffect = if (gap > 0) android.graphics.DashPathEffect(floatArrayOf(d, gap), 0f) else null
                canvas.drawLine(x0, y0, x1, y1, stroke)
            }
            stroke.pathEffect = null
            return
        }
        if (style == "dashed" || style == "dotted") {
            // gtk.zig's dashPattern over the whole outline: dashes of 3 × width
            // (dots of width), as many as fit with even gaps; round dots from 3 px.
            val len = android.graphics.PathMeasure(path, true).length
            val d = if (style == "dotted") ow else 3 * ow
            if (len > d) {
                val k = max(2f, Math.round((len + d) / (2 * d)).toFloat())
                val gap = (len - k * d) / (k - 1)
                stroke.pathEffect = if (style == "dotted" && ow >= 3) {
                    stroke.strokeCap = Paint.Cap.ROUND
                    android.graphics.DashPathEffect(floatArrayOf(0.001f, d + gap - 0.001f), 0f)
                } else android.graphics.DashPathEffect(floatArrayOf(d, gap), 0f)
            }
        }
        canvas.drawPath(path, stroke)
        stroke.pathEffect = null
        stroke.strokeCap = Paint.Cap.BUTT
    }

    /**
     * An inline element's outline (a focused link's ring, Run `ol`) around
     * its runs as laid out (win32.zig runRing): a box per line they're on,
     * the spaces where a line wraps left out, its sides on whole pixels, as
     * tall as their content area around the line's baseline; several lines
     * get one outline around them all, as Chromium draws a wrapped link's.
     */
    private fun runRing(canvas: Canvas, l: Layout, ring: NuiNode.RunRing) {
        val t = l.text
        val boxes = ArrayList<RectF>()
        for (k in 0 until l.lineCount) {
            var a = max(ring.start, l.getLineStart(k))
            var b = min(ring.end, l.getLineEnd(k))
            while (a < b && t[a] == ' ') a++
            while (b > a && (t[b - 1] == ' ' || t[b - 1] == '\n' || t[b - 1] == '\r')) b--
            if (a >= b) continue
            ringPath.reset()
            l.getSelectionPath(a, b, ringPath)
            ringPath.computeBounds(rect, true)
            val x0 = Math.round(rect.left).toFloat(); val x1 = Math.round(rect.right).toFloat()
            val base = l.getLineBaseline(k).toFloat()
            if (x1 > x0) boxes += RectF(x0, base - ring.above, x1, base + ring.below)
        }
        if (boxes.isEmpty()) return
        val ol = ring.ol
        if (boxes.size == 1 || ol.has("s")) {
            // One line (or dashes, which go per box): the box's own outline.
            for (b in boxes) outline(canvas, ol, b.left, b.top, b.width(), b.height(), null)
            return
        }
        val ow = ol.optDouble("w", 0.0).toFloat()
        val color = NuiNode.color(ol.optJSONArray("c"))
        if (!(ow > 0) || Color.alpha(color) == 0) return
        val o = ol.optDouble("o", 0.0).toFloat()
        val r = ol.optDouble("r", 0.0).toFloat()
        // The ring: the boxes grown by offset + width, less them grown by the
        // offset; the halo 1px around that.
        fun union(grow: Float, radius: Float): Path {
            val u = Path()
            for (b in boxes) {
                val one = Path()
                val g = RectF(b.left - grow, b.top - grow, b.right + grow, b.bottom + grow)
                if (g.width() <= 0 || g.height() <= 0) continue
                if (radius > 0) one.addRoundRect(g, radius, radius, Path.Direction.CW) else one.addRect(g, Path.Direction.CW)
                u.op(one, Path.Op.UNION)
            }
            return u
        }
        val outer = union(o + ow, r)
        ol.optJSONArray("h")?.let { hj ->
            val halo = NuiNode.color(hj)
            if (Color.alpha(halo) == 0) return@let
            val edge = union(o + ow + 1, r + 1)
            edge.op(outer, Path.Op.DIFFERENCE)
            fill.color = halo
            canvas.drawPath(edge, fill)
        }
        outer.op(union(o, max(0f, r - ow)), Path.Op.DIFFERENCE)
        fill.color = color
        canvas.drawPath(outer, fill)
    }

    private val ringPath = Path()

    /** Clip to the box's padding box (tree.zig paddingClipXY): inset by the
     *  borders `bw` (top, right, bottom, left), each corner's ellipse less
     *  the borders on its two sides. */
    private fun paddingClip(canvas: Canvas, x: Float, y: Float, w: Float, h: Float, r: FloatArray, bw: FloatArray?) {
        val b = bw ?: FloatArray(4)
        roundRect(x + b[3], y + b[0], max(0f, w - b[1] - b[3]), max(0f, h - b[0] - b[2]), inset(r, b[3], b[0], b[1], b[2]))
        canvas.clipPath(path)
    }

    /** An <img> in its content box, per CSS object-fit (fill by default). */
    private fun image(canvas: Canvas, b: Bitmap, fit: String, x: Float, y: Float, w: Float, h: Float) {
        if (w <= 0 || h <= 0 || b.width <= 0 || b.height <= 0) return
        var kx = w / b.width
        var ky = h / b.height
        when (fit) {
            "contain" -> { kx = min(kx, ky); ky = kx }
            "cover" -> { kx = max(kx, ky); ky = kx }
            "none" -> { kx = 1f; ky = 1f }
            "scale-down" -> { kx = min(1f, min(kx, ky)); ky = kx }
        }
        val dw = b.width * kx
        val dh = b.height * ky
        canvas.save()
        canvas.clipRect(x, y, x + w, y + h)
        val l = x + (w - dw) / 2
        val t = y + (h - dh) / 2
        canvas.drawBitmap(b, null, RectF(l, t, l + dw, t + dh), imagePaint)
        canvas.restore()
    }

    private val imagePaint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
    private val controlPaint = Paint(Paint.ANTI_ALIAS_FLAG)

    /**
     * A default checkbox or radio (no appearance: none), as the GTK backend
     * draws it: filled in accent-color with a check or dot when on, white
     * with a grey outline when off, faded when disabled.
     */
    private fun control(canvas: Canvas, n: NuiNode, bx: Float, by: Float, bw: Float, bh: Float) {
        val size = min(bw, bh)
        if (size <= 0) return
        val x = bx + (bw - size) / 2
        val y = by + (bh - size) / 2
        val radio = n.p.optString("ctl") == "radio"
        val alpha = if (n.p.optBoolean("dis")) 0.45f else 1f
        val acc = n.p.optJSONArray("acc")?.let { NuiNode.color(it) } ?: Color.rgb(59, 108, 255)
        fun faded(c: Int) = Color.argb((Color.alpha(c) * alpha).toInt(), Color.red(c), Color.green(c), Color.blue(c))
        val shape = Path().apply {
            if (radio) addCircle(x + size / 2, y + size / 2, size / 2 - 0.5f, Path.Direction.CW)
            else addRoundRect(RectF(x + 0.5f, y + 0.5f, x + size - 0.5f, y + size - 0.5f), 2.5f, 2.5f, Path.Direction.CW)
        }
        val p = controlPaint
        p.shader = null
        if (n.p.optBoolean("on")) {
            p.style = Paint.Style.FILL; p.color = faded(acc)
            canvas.drawPath(shape, p)
            p.color = faded(Color.WHITE)
            if (radio) {
                canvas.drawCircle(x + size / 2, y + size / 2, size * 0.2f, p)
            } else {
                p.style = Paint.Style.STROKE
                p.strokeWidth = max(1.5f, size * 0.13f)
                p.strokeCap = Paint.Cap.ROUND; p.strokeJoin = Paint.Join.ROUND
                val check = Path().apply {
                    moveTo(x + size * 0.25f, y + size * 0.52f)
                    lineTo(x + size * 0.43f, y + size * 0.7f)
                    lineTo(x + size * 0.76f, y + size * 0.32f)
                }
                canvas.drawPath(check, p)
            }
        } else {
            p.style = Paint.Style.FILL; p.color = faded(Color.WHITE)
            canvas.drawPath(shape, p)
            p.style = Paint.Style.STROKE; p.strokeWidth = 1f; p.color = faded(Color.rgb(118, 118, 118))
            canvas.drawPath(shape, p)
        }
    }

    /**
     * The corners as CSS draws them (tree.zig radiusXY): `br` is four
     * corners, each one length or [x, y]; an x percentage is of the box's
     * width, a y one of its height, and all are scaled down together until
     * adjacent ones fit (Radii.fitted). Path.addRoundRect's order: (x, y)
     * each, top left, top right, bottom right, bottom left; a corner with
     * either axis 0 is square. Null when every corner is.
     */
    private fun radii(n: NuiNode, w: Float, h: Float): FloatArray? {
        val br = n.br ?: return null
        val r = FloatArray(8)
        for (i in 0 until 4) {
            val v = br.opt(i)
            val xy = v as? JSONArray
            val rx = if (xy != null && xy.length() == 2) boxLen(xy.opt(0), w) else boxLen(v, w)
            val ry = if (xy != null && xy.length() == 2) boxLen(xy.opt(1), h) else boxLen(v, h)
            if (rx > 0 && ry > 0) { r[2 * i] = rx; r[2 * i + 1] = ry }
        }
        fun fit(len: Float, sum: Float) = if (sum > 0) max(0f, len) / sum else 1f
        val f = min(min(fit(w, r[0] + r[2]), fit(w, r[6] + r[4])), min(fit(h, r[1] + r[7]), fit(h, r[3] + r[5])))
        if (f < 1) for (i in r.indices) r[i] *= f
        return if (square(r)) null else r
    }

    /** No rounded corner (Radii.square). */
    private fun square(r: FloatArray?) = r == null || (0 until 4).none { r[2 * it] > 0 && r[2 * it + 1] > 0 }

    /** Each rounded corner grown by `d` on both axes, a square one staying square (Radii.grown). */
    private fun grown(r: FloatArray?, d: Float): FloatArray? {
        if (r == null) return null
        val out = FloatArray(8)
        for (i in 0 until 4) if (r[2 * i] > 0 && r[2 * i + 1] > 0) {
            out[2 * i] = max(0f, r[2 * i] + d); out[2 * i + 1] = max(0f, r[2 * i + 1] + d)
        }
        return if (square(out)) null else out
    }

    /** Each corner less `d` on both axes (a stroke's middle inside the box). */
    private fun shrunk(r: FloatArray?, d: Float): FloatArray? = r?.let { a -> FloatArray(8) { max(0f, a[it] - d) } }

    /**
     * The radii inside the box's edges inset by l, t, r, b (tree.zig
     * paddingBoxXY): each corner's x radius less its side's (left or
     * right) inset, its y radius less the top's or bottom's.
     */
    private fun inset(r: FloatArray?, l: Float, t: Float, rr: Float, b: Float): FloatArray? {
        if (r == null) return null
        val out = floatArrayOf(r[0] - l, r[1] - t, r[2] - rr, r[3] - t, r[4] - rr, r[5] - b, r[6] - l, r[7] - b)
        for (i in out.indices) out[i] = max(0f, out[i])
        return if (square(out)) null else out
    }

    private fun roundRect(x: Float, y: Float, w: Float, h: Float, r: FloatArray?) {
        path.reset()
        rect.set(x, y, x + w, y + h)
        if (square(r)) path.addRect(rect, Path.Direction.CW)
        else path.addRoundRect(rect, r!!, Path.Direction.CW)
    }

    /** A gradient length: px (a number) or "50%" of `total`. */
    private fun boxLen(v: Any?, total: Float): Float = when (v) {
        is Number -> v.toFloat()
        is String -> if (v.endsWith("%")) (v.dropLast(1).toFloatOrNull() ?: 0f) / 100 * total else 0f
        else -> 0f
    }

    /** A radial gradient's center (from the box's origin) and radii in a w x h box: tree.zig's Gradient.radialIn. */
    private fun radialIn(g: JSONObject, r: JSONArray, w: Float, h: Float): FloatArray {
        val cx = boxLen(r.opt(0), w); val cy = boxLen(r.opt(1), h)
        var rx = boxLen(r.opt(2), w); var ry = boxLen(r.opt(3), h)
        val circle = g.optBoolean("circle", false)
        val ext = g.optString("ext", "").let { if (it.isEmpty() || it in EXTENTS) it else "farthest-corner" }
        if (ext.isNotEmpty()) {
            // The distances to the nearer and farther side, each axis.
            val nx = min(abs(cx), abs(w - cx)); val ny = min(abs(cy), abs(h - cy))
            val fx = max(abs(cx), abs(w - cx)); val fy = max(abs(cy), abs(h - cy))
            if (circle) {
                rx = when (ext) {
                    "closest-side" -> min(nx, ny)
                    "farthest-side" -> max(fx, fy)
                    "closest-corner" -> hypot(nx, ny)
                    else -> hypot(fx, fy)
                }
                ry = rx
            } else {
                // An ellipse through a corner keeps the sides' aspect ratio: those radii times sqrt(2).
                val k = if (ext.endsWith("-corner")) sqrt(2f) else 1f
                val near = ext.startsWith("closest")
                rx = k * (if (near) nx else fx); ry = k * (if (near) ny else fy)
            }
        } else if (circle) ry = rx
        return floatArrayOf(cx, cy, max(0.01f, rx), max(0.01f, ry))
    }

    /** Stops ready to draw (tree.zig Gradient.Resolved): colors, positions 0..1 and, repeating, the period as a fraction of the line. */
    private class Stops(val colors: IntArray, val pos: FloatArray, val period: Float?)

    /**
     * The stops over a gradient line `line` px long (tree.zig
     * Gradient.resolve): `su` gives each stop's unit when they aren't all
     * fractions (`%` a fraction, `p` px, `a` none given: evenly between the
     * given ones, the first 0 and the last 1; `c` a calc(): its fraction
     * and its px part in `sp`). Repeating (`rep`): one
     * period's stops, 0..1 within it, phased so a period starts at the
     * line's start, and the period's length as a fraction of the line.
     */
    private fun resolveStops(g: JSONObject, stops: JSONArray, line: Float): Stops {
        val n = stops.length()
        val s = Array(n) { i -> stops.optJSONArray(i).let { a -> FloatArray(5) { a?.optDouble(it, if (it == 3) 1.0 else 0.0)?.toFloat() ?: 0f } } }
        val su = g.optString("su", "")
        if (su.isNotEmpty()) {
            val auto = BooleanArray(n) { (if (it < su.length) su[it] else '%') == 'a' }
            val sp = g.optJSONArray("sp")
            for (i in 0 until n) {
                val u = if (i < su.length) su[i] else '%'
                if (u == 'p') s[i][4] = if (line > 0) s[i][4] / line else 0f
                // calc(100% - 20px): the fraction in pos, the px in sp.
                if (u == 'c' && sp != null && i < sp.length() && line > 0) s[i][4] += sp.optDouble(i, 0.0).toFloat() / line
            }
            if (auto[0]) { s[0][4] = 0f; auto[0] = false }
            if (n > 1 && auto[n - 1]) { s[n - 1][4] = 1f; auto[n - 1] = false }
            // Missing positions: evenly between the given ones.
            var i = 1
            while (i < n) {
                if (!auto[i]) { i++; continue }
                var j = i
                while (j < n && auto[j]) j++
                val a = s[i - 1][4]; val b = if (j < n) s[j][4] else a
                for (k in i until j) s[k][4] = a + (b - a) * (k - i + 1) / (j - i + 1)
                i = j
            }
        }
        // Never back: a position less than one before it is that one.
        for (i in 1 until n) s[i][4] = max(s[i][4], s[i - 1][4])
        fun out(list: List<FloatArray>, period: Float?) = Stops(
            IntArray(list.size) { val c = list[it]; Color.argb((c[3] * 255).toInt().coerceIn(0, 255), c[0].toInt().coerceIn(0, 255), c[1].toInt().coerceIn(0, 255), c[2].toInt().coerceIn(0, 255)) },
            FloatArray(list.size) { list[it][4] }, period,
        )
        if (!g.optBoolean("rep")) return out(s.toList(), null)
        val first = s[0][4]
        val per = s[n - 1][4] - first
        // No period: the last color everywhere (as browsers draw it).
        if (!(per > 1e-6f)) return out(s.map { s[n - 1].copyOf().also { c -> c[4] = it[4] } }, null)
        for (st in s) st[4] = (st[4] - first) / per
        // Phased so a period starts at 0: the line's 0 is `at` into a period.
        val q = first / per
        val at = 1 - (q - floor(q))
        if (!(at > 1e-6f && at < 1 - 1e-6f)) return out(s.toList(), per)
        val wrap = s[n - 1].copyOf()
        for (i in 1 until n) if (s[i][4] >= at) {
            val a = s[i - 1]; val b = s[i]
            val t = if (b[4] > a[4]) (at - a[4]) / (b[4] - a[4]) else 0f
            for (c in 0 until 4) wrap[c] = a[c] + (b[c] - a[c]) * t
            break
        }
        val list = ArrayList<FloatArray>(n + 2)
        list += wrap.copyOf().also { it[4] = 0f }
        for (st in s) if (st[4] >= at) list += st.copyOf().also { it[4] = st[4] - at }
        for (st in s) if (st[4] < at) list += st.copyOf().also { it[4] = st[4] + (1 - at) }
        list += wrap.copyOf().also { it[4] = 1f }
        return out(list, per)
    }

    private fun gradient(g: JSONObject, x: Float, y: Float, w: Float, h: Float): Shader? {
        val stops = g.optJSONArray("stops") ?: return null
        if (stops.length() < 2) return null
        g.optJSONArray("radial")?.let { r ->
            // A circle of radius rx, squeezed to ry vertically; its line is the x radius.
            val (ox, oy, rx, ry) = radialIn(g, r, w, h)
            val st = resolveStops(g, stops, rx)
            val cx = x + ox; val cy = y + oy
            // Repeating: one period's gradient, repeated (Shader.TileMode.REPEAT).
            val radius = max(0.01f, rx * (st.period ?: 1f))
            val mode = if (st.period != null) Shader.TileMode.REPEAT else Shader.TileMode.CLAMP
            return RadialGradient(cx, cy, radius, st.colors, st.pos, mode).also {
                it.setLocalMatrix(Matrix().apply { setScale(1f, ry / rx, cx, cy) })
            }
        }
        val a = Math.toRadians(g.optDouble("angle", 180.0))
        val dx = sin(a).toFloat(); val dy = (-cos(a)).toFloat()
        val len = abs(w * dx) + abs(h * dy)
        val st = resolveStops(g, stops, len)
        val cx = x + w / 2; val cy = y + h / 2
        val x0 = cx - dx * len / 2; val y0 = cy - dy * len / 2
        // Repeating: the line's first period, repeated beyond it (Shader.TileMode.REPEAT).
        val end = len * (st.period ?: 1f)
        val mode = if (st.period != null) Shader.TileMode.REPEAT else Shader.TileMode.CLAMP
        return LinearGradient(x0, y0, x0 + dx * end, y0 + dy * end, st.colors, st.pos, mode)
    }

    private fun border(canvas: Canvas, n: NuiNode, bw: FloatArray, x: Float, y: Float, w: Float, h: Float, r: FloatArray?) {
        val colors = n.bc ?: return
        val drawn = (0 until 4).filter { bw[it] > 0 }
        if (drawn.isEmpty()) return
        val oneColor = drawn.all { colors[it] == colors[drawn[0]] }
        if (bw[0] == bw[1] && bw[1] == bw[2] && bw[2] == bw[3] && oneColor) {
            val half = bw[0] / 2
            roundRect(x + half, y + half, w - bw[0], h - bw[0], shrunk(r, half))
            stroke.color = colors[0]
            stroke.strokeWidth = bw[0]
            stroke.strokeCap = Paint.Cap.BUTT
            stroke.strokeJoin = Paint.Join.MITER
            canvas.drawPath(path, stroke)
            return
        }
        sides(canvas, x, y, w, h, r ?: FloatArray(8), bw, colors, oneColor)
    }

    private val ring = Path()
    private val wedge = Path()

    /**
     * Sides of different widths or colors, as browsers draw them (gtk.zig's
     * roundedSides): the area between the border box and the padding box,
     * whose corners are ellipses (the radius less each side's width), each
     * side's color clipped to its wedge, the lines from its outer corners
     * through its inner corners (where browsers join two colors) up to the
     * middle.
     */
    private fun sides(canvas: Canvas, x: Float, y: Float, w: Float, h: Float, r: FloatArray, bw: FloatArray, colors: IntArray, oneColor: Boolean) {
        val ix = x + bw[3]; val iy = y + bw[0]
        val iw = max(0f, w - bw[1] - bw[3]); val ih = max(0f, h - bw[0] - bw[2])
        // Inner corners: each outer ellipse less the borders on its two sides.
        val innerRadii = inset(r, bw[3], bw[0], bw[1], bw[2]) ?: FloatArray(8)
        ring.reset()
        ring.fillType = Path.FillType.EVEN_ODD
        ring.addRoundRect(RectF(x, y, x + w, y + h), r, Path.Direction.CW)
        ring.addRoundRect(RectF(ix, iy, ix + iw, iy + ih), innerRadii, Path.Direction.CW)
        if (oneColor) {
            fill.color = colors[(0 until 4).first { bw[it] > 0 }]
            canvas.drawPath(ring, fill)
            return
        }
        val outer = arrayOf(floatArrayOf(x, y), floatArrayOf(x + w, y), floatArrayOf(x + w, y + h), floatArrayOf(x, y + h))
        val inner = arrayOf(floatArrayOf(ix, iy), floatArrayOf(ix + iw, iy), floatArrayOf(ix + iw, iy + ih), floatArrayOf(ix, iy + ih))
        val mx = ix + iw / 2; val my = iy + ih / 2
        // Each corner's join, from the outer corner through the inner one,
        // stopped where it reaches the middle's row or column.
        val join = Array(4) { k ->
            val dx = inner[k][0] - outer[k][0]; val dy = inner[k][1] - outer[k][1]
            var t = Float.MAX_VALUE
            if (dx != 0f) t = min(t, (mx - outer[k][0]) / dx)
            if (dy != 0f) t = min(t, (my - outer[k][1]) / dy)
            if (dx == 0f && dy == 0f) t = 0f
            floatArrayOf(outer[k][0] + max(0f, t) * dx, outer[k][1] + max(0f, t) * dy)
        }
        // Neighboring sides of one color share one wedge (no seam where two
        // anti-aliased clips would meet): a run of them starts after a side
        // of another color (apple_draw.zig's roundedSides).
        fun sameAs(a: Int, b: Int) = bw[a] > 0 && bw[b] > 0 && colors[a] == colors[b]
        for (i in 0 until 4) {
            if (bw[i] <= 0 || Color.alpha(colors[i]) == 0) continue
            if (sameAs(i, (i + 3) % 4)) continue // in the run before it
            wedge.reset()
            wedge.moveTo(outer[i][0], outer[i][1])
            var last = i
            while (sameAs(last, (last + 1) % 4) && (last + 1) % 4 != i) {
                last = (last + 1) % 4
                wedge.lineTo(outer[last][0], outer[last][1])
            }
            val j = (last + 1) % 4
            wedge.lineTo(outer[j][0], outer[j][1])
            wedge.lineTo(join[j][0], join[j][1]); wedge.lineTo(mx, my); wedge.lineTo(join[i][0], join[i][1])
            wedge.close()
            canvas.save()
            canvas.clipPath(wedge)
            fill.color = colors[i]
            canvas.drawPath(ring, fill)
            canvas.restore()
        }
    }

    /** A box-shadow: the shape, grown by the spread, blurred like CSS (sigma = blur / 2). */
    private fun shadow(canvas: Canvas, sh: JSONObject, x: Float, y: Float, w: Float, h: Float, r: FloatArray?) {
        val sx = sh.optDouble("x", 0.0).toFloat(); val sy = sh.optDouble("y", 0.0).toFloat()
        val blur = sh.optDouble("blur", 0.0).toFloat(); val spread = sh.optDouble("spread", 0.0).toFloat()
        val c = sh.optJSONArray("color")?.let { NuiNode.color(it) } ?: Color.argb(77, 0, 0, 0)
        // Its rounded corners grown by the spread, square ones staying square (Radii.grown).
        roundRect(x + sx - spread, y + sy - spread, w + 2 * spread, h + 2 * spread, grown(r, spread))
        shadowPaint.color = c
        // Skia's blur radius r is sigma = 0.57735 r + 0.5; it scales with the canvas (dp).
        shadowPaint.maskFilter = if (blur > 0) BlurMaskFilter(max(0.01f, (blur / 2 - 0.5f) / 0.57735f), BlurMaskFilter.Blur.NORMAL) else null
        canvas.drawPath(path, shadowPaint)
    }

    private fun icon(canvas: Canvas, icon: NuiIcon, cx: Float, cy: Float, cw: Float, ch: Float) {
        val vb = icon.vb
        if (cw <= 0 || ch <= 0 || vb[2] <= 0 || vb[3] <= 0) return
        val scale = min(cw / vb[2], ch / vb[3])
        canvas.save()
        canvas.translate(cx + (cw - vb[2] * scale) / 2, cy + (ch - vb[3] * scale) / 2)
        canvas.scale(scale, scale)
        canvas.translate(-vb[0], -vb[1])
        for (s in icon.shapes) {
            s.fill?.let { fill.color = it; canvas.drawPath(s.path, fill) }
            s.stroke?.let {
                stroke.color = it
                stroke.strokeWidth = s.sw
                stroke.strokeCap = s.cap
                stroke.strokeJoin = s.join
                canvas.drawPath(s.path, stroke)
            }
        }
        canvas.restore()
    }

    companion object {
        /** Floats per node in the frames from Zig (android.zig `record_len`). */
        const val REC = 14
        /** android.zig's prop_keys, index for index (append only). */
        val PROP_KEYS = arrayOf("fd","w","h","fs","ai","runs","t","c","sz","wt","dis","click","cg","rg","ar","val","maxw","maxh","minw","minh","fw","fg","fb","as","ac","jc","acc","src","range","pw","pos","ph","pad","m","options","on","icon","fit","cw","ch","cv","ctl","cols","trow","tcell","table","bc","bg","br","bw","clip","col","fwt","fz","ins","it","lh","ls","mono","nowrap","op","rel","rot","sc","scroll","scrollx","sh","sticky","ta","tx","ty","vis","z","root","color","gradient","angle","stops","radial","spread","blur","x","y","vb","shapes","d","fill","stroke","sw","cap","join","evenodd","u","i","label","href","hover","radius","cx","cy","ff","ol")
        /** The largest side an <img> is decoded at (px); larger pictures are downsampled. */
        const val MAX_IMAGE_SIDE = 4096
        /** radial-gradient sizes (tree.zig Gradient.RadialExtent); another is farthest-corner. */
        val EXTENTS = setOf("closest-side", "farthest-side", "closest-corner", "farthest-corner")
    }
}
