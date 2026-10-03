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
import android.text.InputType
import android.text.Layout
import android.text.SpannableStringBuilder
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

    fun viewport(window: Int): Long {
        val res = (views[window]?.context ?: OrielRuntime.app).resources
        val m = res.displayMetrics
        val v = views[window]
        val w = if (v != null && v.width > 0) (v.width / m.density).toLong() else (m.widthPixels / m.density).toLong()
        val h = if (v != null && v.height > 0) (v.height / m.density).toLong() else (m.heightPixels / m.density).toLong()
        val dark = if (isDark(res.configuration)) 1L else 0L
        return (dark shl 32) or ((h and 0xffff) shl 16) or (w and 0xffff)
    }

    fun isDark(c: Configuration) = c.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES

    /** One Choreographer callback for the window's next display frame
     *  (android.zig's requestDisplayFrame posts one at a time). */
    fun requestFrame(window: Int) {
        Choreographer.getInstance().postFrameCallback {
            val v = views[window] ?: return@postFrameCallback // the window closed
            val hz = v.display?.refreshRate?.takeIf { it > 0 } ?: 60f
            if (trace && ++displayFrames % 120 == 0) Log.d("OrielNui", "nui display frames $displayFrames at $hz Hz")
            NuiNative.displayFrame(window, 1000f / hz)
        }
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

    /** A single run's text set apart from `p` (setText, a leaf's text):
     *  `p` may be a leaf style's, shared by every node made from it. */
    private var runText: String? = null

    fun update(json: String, kind: String) {
        this.kind = kind
        p = JSONObject(json)
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
        val tp = TextPaint(Paint.ANTI_ALIAS_FLAG)
        tp.textSize = fz
        tp.typeface = typeface(p.optDouble("fwt", 400.0).toInt(), p.optBoolean("it"), mono)
        tp.color = p.optJSONArray("col")?.let { color(it) } ?: Color.BLACK
        if (p.has("ls")) tp.letterSpacing = p.optDouble("ls").toFloat() / fz
        text = spans(fz, mono)
        paint = tp
    }

    /** The runs as one styled text (each run's color, size, font, underline, background). */
    private fun spans(fz: Float, mono: Boolean): CharSequence {
        val sb = SpannableStringBuilder()
        val runs = p.optJSONArray("runs") ?: JSONArray()
        for (i in 0 until runs.length()) {
            val r = runs.optJSONObject(i) ?: continue
            val start = sb.length
            sb.append(if (i == 0 && runs.length() == 1) runText ?: r.optString("t") else r.optString("t"))
            val end = sb.length
            if (end == start) continue
            val flags = Spanned.SPAN_EXCLUSIVE_EXCLUSIVE
            r.optJSONArray("c")?.let { sb.setSpan(ForegroundColorSpan(color(it)), start, end, flags) }
            sb.setSpan(RelativeSizeSpan(r.optDouble("sz", fz.toDouble()).toFloat() / fz), start, end, flags)
            sb.setSpan(FontSpan(typeface(r.optDouble("w", 400.0).toInt(), r.optBoolean("i"), r.optBoolean("mono") || mono)), start, end, flags)
            if (r.optBoolean("u")) sb.setSpan(UnderlineSpan(), start, end, flags)
            r.optJSONArray("bg")?.let { val c = color(it); if (Color.alpha(c) > 0) sb.setSpan(BackgroundColorSpan(c), start, end, flags) }
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
        val b = StaticLayout.Builder.obtain(t, 0, t.length, tp, w).setAlignment(align).setIncludePad(false)
        if (p.has("lh")) {
            val fz = p.optDouble("fz", 16.0).toFloat()
            b.setLineSpacing(0f, p.optDouble("lh").toFloat() / (fz * 1.17f))
        }
        if (nowrap) b.setMaxLines(1).setEllipsize(TextUtils.TruncateAt.END)
        layout = b.build()
        layoutWidth = w
        return layout
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
        val desired = desired(t, tp)
        val width = if (max64 < 0) desired else min(desired, max(1, max64 / 64))
        val l = textLayout(width) ?: return 0
        var w = 0f
        for (i in 0 until l.lineCount) w = max(w, l.getLineWidth(i))
        val wf = min(ceil(w) + 1, width.toFloat())
        measured = ((wf * 64).toLong() shl 32) or (l.height * 64L)
        measuredFor = max64
        return measured
    }

    companion object {
        fun color(a: JSONArray?): Int {
            if (a == null) return Color.TRANSPARENT
            val alpha = (a.optDouble(3, 1.0) * 255).toInt().coerceIn(0, 255)
            return Color.argb(alpha, a.optInt(0).coerceIn(0, 255), a.optInt(1).coerceIn(0, 255), a.optInt(2).coerceIn(0, 255))
        }

        fun typeface(weight: Int, italic: Boolean, mono: Boolean): Typeface =
            Typeface.create(if (mono) Typeface.MONOSPACE else Typeface.DEFAULT, weight.coerceIn(1, 1000), italic)
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
    private val density = resources.displayMetrics.density
    private var updating = false
    /** The page prevented the last Enter (its key up is consumed too). */
    private var enterTaken = false
    private var dark = Nui.isDark(resources.configuration)
    /** Under the page: the root's background; else white, as in a browser, or nothing in a transparent window. */
    private val pageDefault = if (transparent) Color.TRANSPARENT else Color.WHITE
    private var background: Int = pageDefault

    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
    private val shadowPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val path = Path()
    private val rect = RectF()

    init {
        setWillNotDraw(false)
        isFocusableInTouchMode = true
        clipChildren = true
    }

    // --- From Zig ---------------------------------------------------------

    fun props(id: Int, kind: String, json: String) {
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
            Log.d("OrielNui", "nui dump ${n?.kind ?: "?"} ${"%.1f %.1f %.1f %.1f".format(f[i + 1], f[i + 2], f[i + 3], f[i + 4])} bg=${n?.bg} fz=${n?.p?.optDouble("fz", 0.0)} \"$t\"")
            i += REC
        }
        Log.d("OrielNui", "nui dump end $window")
    }

    /** Leaf styles, parsed once (NuiNode templates), by style id. */
    private val leafStyles = HashMap<Int, NuiNode>()

    /**
     * Leaf styles and the nodes the tree made from them (android.zig's
     * flushLeaves; host.leaf, stamped rows), packed little-endian:
     * 'S' style id, JSON length, JSON; 'L' node id, kind (0 view, 1 text),
     * style id, text length, text.
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
                'L' -> {
                    val kind = if (b.get().toInt() == 1) "text" else "view"
                    val style = leafStyles[b.int]
                    val text = utf8(b, b.int) ?: return
                    if (style == null) continue // not sent (an id beyond an int): not drawn
                    nodes[id] = NuiNode(id, kind).also { it.fromStyle(style, if (kind == "text") text else null) }
                }
                else -> return
            }
        }
        orderDirty = true
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
        val f = fields[id] ?: makeField(id) ?: return
        updating = true
        try {
            when (f) {
                is SeekBar -> rangeOf(nodes[id])?.let { f.progress = it.progress(v) }
                is EditText -> if (f.text.toString() != v) { f.setText(v); f.setSelection(v.length) }
                is Spinner -> {
                    selectValues[id] = v
                    options(nodes[id])?.indexOfFirst { it.first == v }?.let { if (it >= 0) f.setSelection(it) }
                }
            }
        } finally { updating = false }
    }

    fun focusField(id: Int) {
        val f = fields[id] ?: return
        f.requestFocus()
        if (f is EditText) context.getSystemService(InputMethodManager::class.java)?.showSoftInput(f, 0)
    }

    // --- Size ---------------------------------------------------------------

    /** Out of its window: the canvases' bitmaps go (the next paint makes new ones). */
    override fun onDetachedFromWindow() {
        super.onDetachedFromWindow()
        for (c in canvases.values) c.recycle()
        canvases.clear()
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        onSize(w, h)
        if (w > 0 && h > 0) NuiNative.resize(window, w / density, h / density, dark)
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
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

    private fun makeField(id: Int): View? {
        val n = nodes[id] ?: return null
        val v: View = if (n.kind == "input" && n.p.has("range")) slider(n, id) else when (n.kind) {
            "input", "textarea" -> EditText(context).apply {
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
                addTextChangedListener(object : TextWatcher {
                    override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                    override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                    override fun afterTextChanged(s: Editable?) {
                        if (!updating) NuiNative.event(window, id, "input".bytes(), (s?.toString() ?: "").bytes())
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
                    val prevented = NuiNative.event(window, id, "key".bytes(), "[\"Enter\",$mods]".bytes())
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

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                scroller.forceFinished(true)
                downX = e.x; downY = e.y; lastY = e.y
                dragging = false; longPressed = false
                velocity?.recycle()
                velocity = VelocityTracker.obtain().also { it.addMovement(e) }
                postDelayed(longPress, ViewConfiguration.getLongPressTimeout().toLong())
                NuiNative.press(window, e.x / density, e.y / density, true)
                if (!hasFocus()) requestFocus()
            }
            MotionEvent.ACTION_MOVE -> {
                velocity?.addMovement(e)
                if (!dragging && (abs(e.y - downY) > slop || abs(e.x - downX) > slop)) {
                    dragging = true
                    sideways = abs(e.x - downX) > abs(e.y - downY)
                    removeCallbacks(longPress)
                    NuiNative.press(window, 0f, 0f, false) // a drag isn't a press
                    lastY = e.y
                    lastX = e.x
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
                if (!dragging && !longPressed) {
                    hideKeyboard()
                    NuiNative.tap(window, e.x / density, e.y / density)
                } else if (dragging) {
                    val v = velocity
                    v?.computeCurrentVelocity(1000)
                    val vy = v?.yVelocity ?: 0f
                    if (!sideways && abs(vy) > ViewConfiguration.get(context).scaledMinimumFlingVelocity) fling(-vy)
                }
                velocity?.recycle(); velocity = null
            }
            MotionEvent.ACTION_CANCEL -> {
                removeCallbacks(longPress)
                NuiNative.press(window, 0f, 0f, false)
                velocity?.recycle(); velocity = null
            }
        }
        return true
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
            MotionEvent.ACTION_HOVER_ENTER, MotionEvent.ACTION_HOVER_MOVE -> NuiNative.hover(window, e.x / density, e.y / density)
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
                    canvas.restore()
                }
                "icon" -> n.icon?.let { icon(canvas, it, f[r + 9], f[r + 10], f[r + 11], f[r + 12]) }
                "image" -> n.image?.let { image(canvas, it, n.p.optString("fit", "fill"), f[r + 9], f[r + 10], f[r + 11], f[r + 12]) }
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
        for (k in kidsInOrder[r] ?: IntArray(0)) draw(canvas, k)
        canvas.restoreToCount(save)
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

    private fun radii(n: NuiNode, w: Float, h: Float): FloatArray? {
        val br = n.br ?: return null
        val lim = min(w, h) / 2
        val out = FloatArray(4)
        var any = false
        for (i in 0 until 4) {
            val v = br.opt(i)
            val px = when (v) {
                is Number -> v.toFloat()
                is String -> if (v.endsWith("%")) (v.dropLast(1).toFloatOrNull() ?: 0f) / 100 * min(w, h) else 0f
                else -> 0f
            }
            out[i] = min(lim, px)
            if (out[i] > 0) any = true
        }
        return if (any) out else null
    }

    private fun roundRect(x: Float, y: Float, w: Float, h: Float, r: FloatArray?) {
        path.reset()
        rect.set(x, y, x + w, y + h)
        if (r == null) path.addRect(rect, Path.Direction.CW)
        else path.addRoundRect(rect, floatArrayOf(r[0], r[0], r[1], r[1], r[2], r[2], r[3], r[3]), Path.Direction.CW)
    }

    /** A gradient length: px (a number) or "50%" of `total`. */
    private fun boxLen(v: Any?, total: Float): Float = when (v) {
        is Number -> v.toFloat()
        is String -> if (v.endsWith("%")) (v.dropLast(1).toFloatOrNull() ?: 0f) / 100 * total else 0f
        else -> 0f
    }

    private fun gradient(g: JSONObject, x: Float, y: Float, w: Float, h: Float): Shader? {
        val stops = g.optJSONArray("stops") ?: return null
        if (stops.length() < 2) return null
        val colors = IntArray(stops.length())
        val pos = FloatArray(stops.length())
        for (i in 0 until stops.length()) {
            val s = stops.optJSONArray(i)
            colors[i] = NuiNode.color(s)
            pos[i] = s?.optDouble(4, 0.0)?.toFloat() ?: 0f
        }
        g.optJSONArray("radial")?.let { r ->
            // A circle of radius rx, squeezed to ry vertically.
            val cx = x + boxLen(r.opt(0), w); val cy = y + boxLen(r.opt(1), h)
            val rx = max(0.01f, boxLen(r.opt(2), w)); val ry = max(0.01f, boxLen(r.opt(3), h))
            return RadialGradient(cx, cy, rx, colors, pos, Shader.TileMode.CLAMP).also {
                it.setLocalMatrix(Matrix().apply { setScale(1f, ry / rx, cx, cy) })
            }
        }
        val a = Math.toRadians(g.optDouble("angle", 180.0))
        val dx = sin(a).toFloat(); val dy = (-cos(a)).toFloat()
        val len = abs(w * dx) + abs(h * dy)
        val cx = x + w / 2; val cy = y + h / 2
        return LinearGradient(cx - dx * len / 2, cy - dy * len / 2, cx + dx * len / 2, cy + dy * len / 2, colors, pos, Shader.TileMode.CLAMP)
    }

    private fun border(canvas: Canvas, n: NuiNode, bw: FloatArray, x: Float, y: Float, w: Float, h: Float, r: FloatArray?) {
        val colors = n.bc ?: return
        if (bw[0] == bw[1] && bw[1] == bw[2] && bw[2] == bw[3]) {
            if (bw[0] <= 0) return
            val half = bw[0] / 2
            roundRect(x + half, y + half, w - bw[0], h - bw[0], r?.let { a -> FloatArray(4) { max(0f, a[it] - half) } })
            stroke.color = colors[0]
            stroke.strokeWidth = bw[0]
            stroke.strokeCap = Paint.Cap.BUTT
            stroke.strokeJoin = Paint.Join.MITER
            canvas.drawPath(path, stroke)
            return
        }
        val sides = arrayOf(
            floatArrayOf(x, y, w, bw[0]),
            floatArrayOf(x + w - bw[1], y, bw[1], h),
            floatArrayOf(x, y + h - bw[2], w, bw[2]),
            floatArrayOf(x, y, bw[3], h),
        )
        for (i in 0 until 4) {
            if (bw[i] <= 0 || Color.alpha(colors[i]) == 0) continue
            fill.color = colors[i]
            canvas.drawRect(sides[i][0], sides[i][1], sides[i][0] + sides[i][2], sides[i][1] + sides[i][3], fill)
        }
    }

    /** A box-shadow: the shape, grown by the spread, blurred like CSS (sigma = blur / 2). */
    private fun shadow(canvas: Canvas, sh: JSONObject, x: Float, y: Float, w: Float, h: Float, r: FloatArray?) {
        val sx = sh.optDouble("x", 0.0).toFloat(); val sy = sh.optDouble("y", 0.0).toFloat()
        val blur = sh.optDouble("blur", 0.0).toFloat(); val spread = sh.optDouble("spread", 0.0).toFloat()
        val c = sh.optJSONArray("color")?.let { NuiNode.color(it) } ?: Color.argb(77, 0, 0, 0)
        roundRect(x + sx - spread, y + sy - spread, w + 2 * spread, h + 2 * spread, FloatArray(4) { max(0f, (r?.get(it) ?: 0f) + spread) })
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
        /** The largest side an <img> is decoded at (px); larger pictures are downsampled. */
        const val MAX_IMAGE_SIDE = 4096
    }
}
