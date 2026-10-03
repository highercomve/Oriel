package dev.oriel

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RadialGradient
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import org.json.JSONArray
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.math.tan

/**
 * <canvas> in the native renderer: the program the page recorded
 * (src/native_ui/js/src/canvas.js, the node's `cv` prop) replayed into a
 * bitmap of the canvas's own, then drawn at its box. The rules are the GTK
 * backend's (gtk.zig paintCanvas): every paint replays the whole program
 * from the context's defaults; an extra restore() is ignored; clearRect
 * clears the bitmap, never the page; a scale by 0 hides what follows until
 * the restore() that undoes it.
 */
internal sealed class CvOp {
    object Save : CvOp()
    object Restore : CvOp()
    object BeginPath : CvOp()
    object ClosePath : CvOp()
    object Stroke : CvOp()
    class Fill(val evenOdd: Boolean) : CvOp()
    class Clip(val evenOdd: Boolean) : CvOp()
    class Translate(val x: Float, val y: Float) : CvOp()
    class Scale(val x: Float, val y: Float) : CvOp()
    class Rotate(val a: Float) : CvOp()
    class MoveTo(val x: Float, val y: Float) : CvOp()
    class LineTo(val x: Float, val y: Float) : CvOp()
    class Rect(val x: Float, val y: Float, val w: Float, val h: Float) : CvOp()
    class Arc(val x: Float, val y: Float, val r: Float, val a0: Float, val a1: Float, val ccw: Boolean) : CvOp()
    class Quad(val cx: Float, val cy: Float, val x: Float, val y: Float) : CvOp()
    class Bezier(val c1x: Float, val c1y: Float, val c2x: Float, val c2y: Float, val x: Float, val y: Float) : CvOp()
    class FillRect(val x: Float, val y: Float, val w: Float, val h: Float) : CvOp()
    class StrokeRect(val x: Float, val y: Float, val w: Float, val h: Float) : CvOp()
    class ClearRect(val x: Float, val y: Float, val w: Float, val h: Float) : CvOp()
    class Text(val t: String, val x: Float, val y: Float, val stroke: Boolean) : CvOp()
    class FillStyle(val paint: CvPaint) : CvOp()
    class StrokeStyle(val paint: CvPaint) : CvOp()
    class LineWidth(val w: Float) : CvOp()
    class LineCap(val cap: Int) : CvOp()
    class LineJoin(val join: Int) : CvOp()
    class GlobalAlpha(val a: Float) : CvOp()
    class Font(val italic: Boolean, val weight: Int, val size: Float, val family: String) : CvOp()
    class TextAlign(val align: Int) : CvOp()
    class TextBaseline(val baseline: Int) : CvOp()
    class LinearGrad(val id: Int, val x0: Float, val y0: Float, val x1: Float, val y1: Float) : CvOp()
    class RadialGrad(val id: Int, val x0: Float, val y0: Float, val r0: Float, val x1: Float, val y1: Float, val r1: Float) : CvOp()
    class ColorStop(val id: Int, val off: Float, val color: Int) : CvOp()
}

/** A fill or stroke style: a color (ARGB), or a gradient by id. */
internal sealed class CvPaint {
    class Solid(val color: Int) : CvPaint()
    class Grad(val id: Int) : CvPaint()
}

internal object CanvasProgram {
    /** The `cv` prop as ops; ops with a non-finite number are dropped (tree.zig parseCanvasCmds). */
    fun parse(cv: JSONArray?): List<CvOp> {
        if (cv == null) return emptyList()
        val out = ArrayList<CvOp>(cv.length())
        for (i in 0 until cv.length()) {
            val op = cv.optJSONArray(i) ?: continue
            if (op.length() == 0) continue
            val tag = op.opt(0) as? String ?: continue
            if (!finite(op)) continue
            parseOp(tag, op)?.let { out += it }
        }
        return out
    }

    private fun finite(op: JSONArray): Boolean {
        for (i in 1 until op.length()) {
            val v = op.opt(i)
            if (v is Number && !v.toFloat().isFinite()) return false
        }
        return true
    }

    /** A number argument; anything else is 0, as in the Zig parser. */
    private fun n(op: JSONArray, i: Int): Float = (op.opt(i) as? Number)?.toFloat() ?: 0f

    private fun parseOp(tag: String, op: JSONArray): CvOp? = when (tag) {
        "sv" -> CvOp.Save
        "rs" -> CvOp.Restore
        "bp" -> CvOp.BeginPath
        "cp" -> CvOp.ClosePath
        "st" -> CvOp.Stroke
        "fl" -> CvOp.Fill(n(op, 1) != 0f)
        "cl" -> CvOp.Clip(n(op, 1) != 0f)
        "tl" -> CvOp.Translate(n(op, 1), n(op, 2))
        "ts" -> CvOp.Scale(n(op, 1), n(op, 2))
        "tr" -> CvOp.Rotate(n(op, 1))
        "mv" -> CvOp.MoveTo(n(op, 1), n(op, 2))
        "ln" -> CvOp.LineTo(n(op, 1), n(op, 2))
        "rc" -> CvOp.Rect(n(op, 1), n(op, 2), n(op, 3), n(op, 4))
        "ar" -> CvOp.Arc(n(op, 1), n(op, 2), n(op, 3), n(op, 4), n(op, 5), n(op, 6) != 0f)
        "qc" -> CvOp.Quad(n(op, 1), n(op, 2), n(op, 3), n(op, 4))
        "bz" -> CvOp.Bezier(n(op, 1), n(op, 2), n(op, 3), n(op, 4), n(op, 5), n(op, 6))
        "fr" -> CvOp.FillRect(n(op, 1), n(op, 2), n(op, 3), n(op, 4))
        "sr" -> CvOp.StrokeRect(n(op, 1), n(op, 2), n(op, 3), n(op, 4))
        "cr" -> CvOp.ClearRect(n(op, 1), n(op, 2), n(op, 3), n(op, 4))
        "tx", "sx" -> (op.opt(1) as? String)?.takeIf { it.isNotEmpty() }?.let { CvOp.Text(it, n(op, 2), n(op, 3), tag == "sx") }
        "sf" -> paint(op.opt(1))?.let { CvOp.FillStyle(it) }
        "ss" -> paint(op.opt(1))?.let { CvOp.StrokeStyle(it) }
        "lw" -> CvOp.LineWidth(n(op, 1))
        "ga" -> CvOp.GlobalAlpha(n(op, 1))
        "lc" -> wordAt(op, CAPS, 2)?.let { CvOp.LineCap(it) }
        "lj" -> wordAt(op, JOINS, 2)?.let { CvOp.LineJoin(it) }
        // start and end as left and right (left-to-right text).
        "ta" -> wordAt(op, ALIGNS, 2)?.let { CvOp.TextAlign(if (it == 3) 0 else if (it == 4) 2 else it) }
        // ideographic as bottom.
        "tb" -> wordAt(op, BASELINES, 4)?.let { CvOp.TextBaseline(minOf(4, it)) }
        "fo" -> if (op.length() > 4) CvOp.Font(n(op, 1) != 0f, n(op, 2).toInt(), n(op, 3), op.opt(4) as? String ?: "") else null
        "gl" -> if (op.length() > 5) CvOp.LinearGrad(gradId(op.opt(1)), n(op, 2), n(op, 3), n(op, 4), n(op, 5)) else null
        "gr" -> if (op.length() > 7) CvOp.RadialGrad(gradId(op.opt(1)), n(op, 2), n(op, 3), n(op, 4), n(op, 5), n(op, 6), n(op, 7)) else null
        "gs" -> if (op.length() > 6) CvOp.ColorStop(gradId(op.opt(1)), n(op, 2), rgba(n(op, 3), n(op, 4), n(op, 5), n(op, 6))) else null
        else -> null
    }

    /**
     * `count` ops packed by android.zig's putCanvasCmd from the program
     * tree.zig parsed (a tag, the CanvasCmd variant's index, then its
     * fields), as `parse` would make them from the JSON; null when cut off.
     */
    fun unpack(b: java.nio.ByteBuffer, count: Int): List<CvOp>? {
        if (count < 0) return null
        val out = ArrayList<CvOp>(count)
        fun f() = b.float
        fun str(): String? {
            val len = b.int
            if (len < 0 || len > b.remaining()) return null
            val s = String(b.array(), b.arrayOffset() + b.position(), len, Charsets.UTF_8)
            b.position(b.position() + len)
            return s
        }
        fun paint(): CvPaint = if (b.get().toInt() == 0) CvPaint.Solid(rgba(f(), f(), f(), f())) else CvPaint.Grad(b.int)
        try {
            repeat(count) {
                val op: CvOp? = when (b.get().toInt()) {
                    0 -> CvOp.Save
                    1 -> CvOp.Restore
                    2 -> CvOp.BeginPath
                    3 -> CvOp.ClosePath
                    4 -> CvOp.Fill(b.get().toInt() != 0)
                    5 -> CvOp.Stroke
                    6 -> CvOp.Clip(b.get().toInt() != 0)
                    7 -> CvOp.Translate(f(), f())
                    8 -> CvOp.Scale(f(), f())
                    9 -> CvOp.Rotate(f())
                    10 -> CvOp.MoveTo(f(), f())
                    11 -> CvOp.LineTo(f(), f())
                    12 -> CvOp.Rect(f(), f(), f(), f())
                    13 -> CvOp.Arc(f(), f(), f(), f(), f(), b.get().toInt() != 0)
                    14 -> CvOp.Bezier(f(), f(), f(), f(), f(), f())
                    15 -> CvOp.FillRect(f(), f(), f(), f())
                    16 -> CvOp.StrokeRect(f(), f(), f(), f())
                    17 -> CvOp.ClearRect(f(), f(), f(), f())
                    18, 19 -> {
                        val stroke = b.get(b.position() - 1).toInt() == 19
                        val t = str() ?: return null
                        val x = f(); val y = f()
                        if (t.isEmpty()) null else CvOp.Text(t, x, y, stroke)
                    }
                    20 -> CvOp.FillStyle(paint())
                    21 -> CvOp.StrokeStyle(paint())
                    22 -> CvOp.LineWidth(f())
                    23 -> CvOp.LineCap(b.get().toInt())
                    24 -> CvOp.LineJoin(b.get().toInt())
                    25 -> CvOp.GlobalAlpha(f())
                    26 -> {
                        val italic = b.get().toInt() != 0
                        val weight = f().toInt(); val size = f()
                        CvOp.Font(italic, weight, size, str() ?: return null)
                    }
                    27 -> CvOp.TextAlign(b.get().toInt())
                    28 -> CvOp.TextBaseline(b.get().toInt())
                    29 -> CvOp.LinearGrad(b.int, f(), f(), f(), f())
                    30 -> CvOp.RadialGrad(b.int, f(), f(), f(), f(), f(), f())
                    31 -> CvOp.ColorStop(b.int, f(), rgba(f(), f(), f(), f()))
                    else -> return null
                }
                if (op != null) out += op
            }
        } catch (e: java.nio.BufferUnderflowException) {
            return null
        }
        return out
    }

    private val CAPS = listOf("butt", "round", "square")
    private val JOINS = listOf("miter", "round", "bevel")
    private val ALIGNS = listOf("left", "center", "right", "start", "end")
    private val BASELINES = listOf("alphabetic", "top", "hanging", "middle", "bottom", "ideographic")

    /**
     * A keyword argument (canvas.js sends the word: ["lc","round"]) as its
     * index in `words`, or a number index up to `max`; null drops the op
     * (an unknown word), as tree.zig's wordAt does.
     */
    private fun wordAt(op: JSONArray, words: List<String>, max: Int): Int? = when (val v = op.opt(1)) {
        is String -> words.indexOf(v).takeIf { it >= 0 }
        is Number -> v.toDouble().takeIf { it >= 0 && it <= max }?.toInt()
        else -> null
    }

    private fun gradId(v: Any?): Int = (v as? Number)?.toInt()?.coerceIn(0, 65535) ?: 0

    /** [r,g,b,a] or [r,g,b] (r g b 0-255, a 0-1), or ["g", id]. */
    private fun paint(v: Any?): CvPaint? {
        val a = v as? JSONArray ?: return null
        if (a.length() == 2 && a.opt(0) == "g") return CvPaint.Grad(gradId(a.opt(1)))
        if (a.length() < 3) return null
        val c = FloatArray(4) { (a.opt(it) as? Number)?.toFloat() ?: if (it == 3) 1f else 0f }
        if (c.any { !it.isFinite() }) return null
        return CvPaint.Solid(rgba(c[0], c[1], c[2], c[3]))
    }

    private fun rgba(r: Float, g: Float, b: Float, a: Float): Int = Color.argb(
        (a.coerceIn(0f, 1f) * 255).toInt(), r.toInt().coerceIn(0, 255), g.toInt().coerceIn(0, 255), b.toInt().coerceIn(0, 255),
    )
}

/**
 * One canvas node's bitmap, kept between paints while its size holds (a
 * game loop redraws every frame) and recycled when the size changes or the
 * node goes.
 */
internal class CanvasSurface {
    private var bitmap: Bitmap? = null

    fun recycle() {
        bitmap?.recycle()
        bitmap = null
    }

    /**
     * Replay `ops` into the bitmap (box `w`×`h` dp, `density` px per dp)
     * and draw it on `page` at (x, y), clipped to `clip` (the rounded box).
     */
    fun paint(page: Canvas, ops: List<CvOp>, cw: Float, ch: Float, x: Float, y: Float, w: Float, h: Float, density: Float, clip: Path?) {
        if (w <= 0 || h <= 0 || ops.isEmpty()) return
        if (page.isHardwareAccelerated) return paintDirect(page, ops, cw, ch, x, y, w, h, clip)
        // Frame size × density, at most 16384 a side and 16 M pixels (64 MB).
        var scale = density
        var pw = ceil(w * scale).toInt()
        var ph = ceil(h * scale).toInt()
        val maxSide = 16384
        val maxPixels = 16L * 1024 * 1024
        if (pw > maxSide || ph > maxSide || pw.toLong() * ph > maxPixels) {
            scale *= min(min(maxSide.toFloat() / pw, maxSide.toFloat() / ph), sqrt(maxPixels.toFloat() / (pw.toFloat() * ph)))
            pw = ceil(w * scale).toInt().coerceAtLeast(1)
            ph = ceil(h * scale).toInt().coerceAtLeast(1)
        }
        val bmp = bitmapOf(pw, ph) ?: return
        bmp.eraseColor(Color.TRANSPARENT)
        val c = Canvas(bmp)
        c.scale(scale, scale)
        // The drawing's space is the bitmap's (cw × ch), stretched to the box.
        if (cw > 0 && ch > 0) c.scale(w / cw, h / ch)
        Replay(c).run(ops)
        page.save()
        if (clip != null) page.clipPath(clip)
        page.drawBitmap(bmp, null, RectF(x, y, x + w, y + h), compositePaint)
        page.restore()
    }

    /**
     * On a hardware canvas: the program replayed onto the page itself, as a
     * View's onDraw would (a display list the GPU draws, no bitmap to raster
     * and upload each frame). A clearRect needs pixels of its own to clear:
     * the program then draws into a layer (on the GPU too).
     */
    private fun paintDirect(page: Canvas, ops: List<CvOp>, cw: Float, ch: Float, x: Float, y: Float, w: Float, h: Float, clip: Path?) {
        recycle()
        val saved = page.save()
        if (clip != null) page.clipPath(clip)
        page.clipRect(x, y, x + w, y + h)
        if (ops.any { it is CvOp.ClearRect }) page.saveLayer(x, y, x + w, y + h, null)
        page.translate(x, y)
        // The drawing's space is the bitmap's (cw × ch), stretched to the box.
        if (cw > 0 && ch > 0) page.scale(w / cw, h / ch)
        Replay(page).run(ops)
        page.restoreToCount(saved)
    }

    private fun bitmapOf(pw: Int, ph: Int): Bitmap? {
        bitmap?.let { if (it.width == pw && it.height == ph && !it.isRecycled) return it }
        recycle()
        return try {
            Bitmap.createBitmap(pw, ph, Bitmap.Config.ARGB_8888).also { bitmap = it }
        } catch (e: OutOfMemoryError) {
            null
        } catch (e: IllegalArgumentException) {
            null
        }
    }

    private companion object {
        val compositePaint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
    }
}

/** One replay of a program into a canvas, from the context's defaults. */
private class Replay(private val c: Canvas) {
    private class State(
        var fill: CvPaint = CvPaint.Solid(Color.BLACK),
        var stroke: CvPaint = CvPaint.Solid(Color.BLACK),
        var lw: Float = 1f,
        var cap: Int = 0, // butt, round, square
        var join: Int = 0, // miter, round, bevel
        var alpha: Float = 1f,
        var italic: Boolean = false,
        var weight: Int = 400,
        var size: Float = 10f,
        var family: String = "sans-serif",
        var align: Int = 0, // left, center, right
        var baseline: Int = 0, // alphabetic, top, hanging, middle, bottom
        // A scale by 0: nothing drawn until the restore() that undoes it.
        var singular: Boolean = false,
        // The program's transform so far (translate, scale, rotate), as the
        // canvas has it on top of the bitmap's own scale.
        val ctm: Matrix = Matrix(),
    ) {
        fun copy() = State(fill, stroke, lw, cap, join, alpha, italic, weight, size, family, align, baseline, singular, Matrix(ctm))
    }

    private class Grad(val linear: Boolean, val g: FloatArray) {
        val stops = ArrayList<Pair<Float, Int>>()
        var shader: Shader? = null
    }

    private var st = State()
    private val states = ArrayList<State>()
    private val grads = HashMap<Int, Grad>()
    /** The path in the bitmap's space: each point mapped by the transform
     *  in effect when it was added, as a browser keeps it (a path built
     *  under a transform restored before fill() stays where it was drawn). */
    private val path = Path()
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val pt = FloatArray(6)
    private val inverse = Matrix()
    private val userPath = Path()
    /** The path is one whole circle (an arc of a full turn on an empty
     *  path): its center and radius as given, and the transform then, so a
     *  fill under the same transform is a drawCircle, not a path. */
    private var circle = false
    private var circleX = 0f
    private var circleY = 0f
    private var circleR = 0f
    private val circleCtm = Matrix()
    private val ctmNow = Matrix()
    /**
     * What the path holds but `path` doesn't yet, while it's moveTos and
     * whole circles: most such paths are filled circle by circle and
     * dropped, so their curves are made only when something needs the
     * Path (pathNow): a fill that isn't of circles, a stroke, a clip, or
     * another kind of segment. Records, in order: 0 and a moveTo's point
     * (the bitmap's space); 1 and an arc's x, y, r, a0, sweep and the
     * transform's 9 values then.
     */
    private var lazy = FloatArray(256)
    private var lazyLen = 0
    private val lazyCtm = Matrix()
    private val lazyM = FloatArray(9)
    /**
     * The current path as whole circles in the bitmap's space (cx, cy, r
     * each), while it's nothing else: a game's balls in one path. Filled
     * opaque, they're drawn one by one (fillCircles), as win32.zig and
     * apple_draw.zig do: a path of hundreds of circles was most of
     * Breakout's frame at 500 balls.
     */
    private var circles = FloatArray(96)
    private var circleCount = 0
    /** The path is only `circles` (each starting fresh or at a moveTo on
     *  its own start point), all wound the same way. */
    private var onlyCircles = true
    private var circlesCcw = false
    /** A moveTo not yet followed by anything (the bitmap's space). */
    private var moved = false
    private var moveX = 0f
    private var moveY = 0f
    private val m9 = FloatArray(9)

    fun run(ops: List<CvOp>) {
        for (op in ops) {
            if (st.singular && skippedWhenSingular(op)) continue
            step(op)
        }
        // Balance what the program left saved.
        repeat(states.size) { c.restore() }
    }

    private fun skippedWhenSingular(op: CvOp) = when (op) {
        is CvOp.Translate, is CvOp.Scale, is CvOp.Rotate, CvOp.BeginPath, CvOp.ClosePath, is CvOp.MoveTo, is CvOp.LineTo,
        is CvOp.Rect, is CvOp.Arc, is CvOp.Quad, is CvOp.Bezier, is CvOp.Fill, CvOp.Stroke, is CvOp.Clip,
        is CvOp.FillRect, is CvOp.StrokeRect, is CvOp.ClearRect, is CvOp.Text -> true
        else -> false
    }

    private fun step(op: CvOp) {
        when (op) {
            CvOp.Save -> { states += st.copy(); c.save() }
            // Only what this program saved: an extra restore() is ignored.
            CvOp.Restore -> if (states.isNotEmpty()) { st = states.removeAt(states.size - 1); c.restore() }
            is CvOp.Translate -> { c.translate(op.x, op.y); st.ctm.preTranslate(op.x, op.y) }
            is CvOp.Scale -> if (op.x == 0f || op.y == 0f) st.singular = true else { c.scale(op.x, op.y); st.ctm.preScale(op.x, op.y) }
            is CvOp.Rotate -> Math.toDegrees(op.a.toDouble()).toFloat().let { c.rotate(it); st.ctm.preRotate(it) }
            CvOp.BeginPath -> { path.reset(); lazyLen = 0; circle = false; circleCount = 0; onlyCircles = true; moved = false }
            CvOp.ClosePath -> { pathNow(); path.close(); notCircles() }
            is CvOp.MoveTo -> {
                circle = false; map(op.x, op.y)
                if (onlyCircles) lazyMove(pt[0], pt[1]) else { pathNow(); path.moveTo(pt[0], pt[1]) }
                moved = true; moveX = pt[0]; moveY = pt[1]
            }
            is CvOp.LineTo -> { pathNow(); circle = false; notCircles(); map(op.x, op.y); if (path.isEmpty) path.moveTo(pt[0], pt[1]) else path.lineTo(pt[0], pt[1]) }
            is CvOp.Rect -> {
                pathNow(); circle = false; notCircles()
                map(op.x, op.y); path.moveTo(pt[0], pt[1])
                map(op.x + op.w, op.y); path.lineTo(pt[0], pt[1])
                map(op.x + op.w, op.y + op.h); path.lineTo(pt[0], pt[1])
                map(op.x, op.y + op.h); path.lineTo(pt[0], pt[1])
                path.close()
                map(op.x, op.y); path.moveTo(pt[0], pt[1]) // as a browser: the next subpath starts at the rect's origin
            }
            is CvOp.Arc -> arc(op)
            is CvOp.Quad -> {
                pathNow(); circle = false; notCircles()
                if (path.isEmpty) { map(op.cx, op.cy); path.moveTo(pt[0], pt[1]) }
                map(op.cx, op.cy, op.x, op.y); path.quadTo(pt[0], pt[1], pt[2], pt[3])
            }
            is CvOp.Bezier -> {
                pathNow(); circle = false; notCircles()
                if (path.isEmpty) { map(op.c1x, op.c1y); path.moveTo(pt[0], pt[1]) }
                map(op.c1x, op.c1y, op.c2x, op.c2y, op.x, op.y); path.cubicTo(pt[0], pt[1], pt[2], pt[3], pt[4], pt[5])
            }
            is CvOp.Fill -> {
                path.fillType = if (op.evenOdd) Path.FillType.EVEN_ODD else Path.FillType.WINDING
                if (use(st.fill, Paint.Style.FILL)) {
                    if (!op.evenOdd && fillCircles()) Unit
                    else if (circle && st.ctm == circleCtm) c.drawCircle(circleX, circleY, circleR, paint)
                    else { pathNow(); inUserSpace()?.let { c.drawPath(it, paint) } }
                }
            }
            // The line width, dashes and joins in the transform in effect now.
            CvOp.Stroke -> if (use(st.stroke, Paint.Style.STROKE)) { pathNow(); inUserSpace()?.let { c.drawPath(it, paint) } }
            is CvOp.Clip -> {
                pathNow()
                path.fillType = if (op.evenOdd) Path.FillType.EVEN_ODD else Path.FillType.WINDING
                inUserSpace()?.let { c.clipPath(it) } // the path stays, as a canvas keeps it
            }
            is CvOp.FillRect -> if (use(st.fill, Paint.Style.FILL)) c.drawRect(op.x, op.y, op.x + op.w, op.y + op.h, paint)
            is CvOp.StrokeRect -> if (use(st.stroke, Paint.Style.STROKE)) c.drawRect(op.x, op.y, op.x + op.w, op.y + op.h, paint)
            is CvOp.ClearRect -> c.drawRect(op.x, op.y, op.x + op.w, op.y + op.h, clearPaint)
            is CvOp.Text -> text(op)
            is CvOp.FillStyle -> st.fill = op.paint
            is CvOp.StrokeStyle -> st.stroke = op.paint
            is CvOp.LineWidth -> st.lw = op.w.coerceAtLeast(0f)
            is CvOp.LineCap -> st.cap = op.cap
            is CvOp.LineJoin -> st.join = op.join
            is CvOp.GlobalAlpha -> st.alpha = op.a.coerceIn(0f, 1f)
            is CvOp.Font -> { st.italic = op.italic; st.weight = op.weight; st.size = op.size; st.family = op.family }
            is CvOp.TextAlign -> st.align = op.align
            is CvOp.TextBaseline -> st.baseline = op.baseline
            is CvOp.LinearGrad -> grads[op.id] = Grad(true, floatArrayOf(op.x0, op.y0, op.x1, op.y1))
            is CvOp.RadialGrad -> grads[op.id] = Grad(false, floatArrayOf(op.x0, op.y0, op.r0, op.x1, op.y1, op.r1))
            is CvOp.ColorStop -> grads[op.id]?.let { it.stops += op.off.coerceIn(0f, 1f) to op.color; it.shader = null }
        }
    }

    /** Points (x0, y0, x1, y1…) mapped by the transform into `pt`. */
    private fun map(vararg xy: Float) {
        for (i in xy.indices) pt[i] = xy[i]
        st.ctm.mapPoints(pt, 0, pt, 0, xy.size / 2)
    }

    /**
     * The path back in the space of the transform in effect now, to draw or
     * clip under it (the canvas has it): a fill lands where the path was
     * built, a stroke's width and a gradient follow the transform now, as in
     * a browser. Null when the transform can't be undone (nothing drawn).
     */
    private fun inUserSpace(): Path? {
        if (!st.ctm.invert(inverse)) return null
        userPath.set(path)
        userPath.transform(inverse)
        return userPath
    }

    /**
     * arc(x, y, r, a0, a1, ccw): clockwise (y down) from a0 to a1, or the
     * other way; a sweep of a whole turn or more is the whole circle. A line
     * joins the path's current point to the arc's start. Added as cubic
     * curves (at most a quarter turn each) whose points the transform maps,
     * so a rotated or scaled arc (an ellipse) keeps its shape.
     */
    private fun arc(a: CvOp.Arc) {
        if (a.r < 0) return
        val twoPi = (2 * PI).toFloat()
        var sweep = a.a1 - a.a0
        if (!a.ccw) {
            if (sweep >= twoPi) sweep = twoPi
            else if (sweep < 0) sweep = sweep % twoPi + twoPi
        } else {
            if (sweep <= -twoPi) sweep = -twoPi
            else if (sweep > 0) sweep = sweep % twoPi - twoPi
        }
        // The path's first segment (not even a moveTo before it, which Skia
        // counts): a fill under the same transform can be a drawCircle.
        val first = lazyLen == 0 && path.isEmpty
        trackCircle(a, sweep, twoPi)
        if (first && abs(sweep) == twoPi && a.r > 0) {
            circle = true
            circleX = a.x; circleY = a.y; circleR = a.r; circleCtm.set(st.ctm)
        } else circle = false
        // Still only circles (or this one on an empty path): kept as a
        // record; the curves come when something needs them.
        if (onlyCircles || circle) { lazyArc(a.x, a.y, a.r, a.a0, sweep); return }
        pathNow()
        arcPath(a.x, a.y, a.r, a.a0, sweep)
    }

    private fun lazyRoom(n: Int) {
        if (lazyLen + n > lazy.size) lazy = lazy.copyOf(maxOf(lazy.size * 2, lazyLen + n))
    }

    private fun lazyMove(x: Float, y: Float) {
        lazyRoom(3)
        lazy[lazyLen] = 0f; lazy[lazyLen + 1] = x; lazy[lazyLen + 2] = y
        lazyLen += 3
    }

    private fun lazyArc(x: Float, y: Float, r: Float, a0: Float, sweep: Float) {
        lazyRoom(15)
        lazy[lazyLen] = 1f; lazy[lazyLen + 1] = x; lazy[lazyLen + 2] = y; lazy[lazyLen + 3] = r
        lazy[lazyLen + 4] = a0; lazy[lazyLen + 5] = sweep
        st.ctm.getValues(lazyM)
        System.arraycopy(lazyM, 0, lazy, lazyLen + 6, 9)
        lazyLen += 15
    }

    private fun lazyHasArc(): Boolean {
        var i = 0
        while (i < lazyLen) { if (lazy[i] == 1f) return true; i += if (lazy[i] == 0f) 3 else 15 }
        return false
    }

    /** Something other than a whole circle joined the path. */
    private fun notCircles() {
        onlyCircles = false
        circleCount = 0
    }

    /**
     * An arc into the path: still only circles if it's a whole one, under a
     * transform that keeps circles round (no skew, the same scale both
     * ways), starting fresh or at the moveTo just before it on its own
     * start point, wound as the others.
     */
    private fun trackCircle(a: CvOp.Arc, sweep: Float, twoPi: Float) {
        if (!onlyCircles) return
        st.ctm.getValues(m9)
        val sx = m9[Matrix.MSCALE_X]; val kx = m9[Matrix.MSKEW_X]; val ky = m9[Matrix.MSKEW_Y]; val sy = m9[Matrix.MSCALE_Y]
        val s2 = sx * sx + ky * ky
        val similar = abs(s2 - (kx * kx + sy * sy)) <= 1e-4f * s2 && abs(sx * kx + ky * sy) <= 1e-4f * s2 &&
            m9[Matrix.MPERSP_0] == 0f && m9[Matrix.MPERSP_1] == 0f
        val det = sx * sy - kx * ky
        val ccw = (sweep < 0) != (det < 0)
        if (abs(sweep) != twoPi || !similar || !(s2 > 0) || (circleCount > 0 && ccw != circlesCcw)) return notCircles()
        map(a.x + a.r * cos(a.a0), a.y + a.r * sin(a.a0), a.x, a.y)
        val sxp = pt[0]; val syp = pt[1]; val cx = pt[2]; val cy = pt[3]
        if (moved) {
            // Joined to its moveTo by a line unless it starts right there.
            if (abs(sxp - moveX) > 0.01f || abs(syp - moveY) > 0.01f) return notCircles()
        } else if (circleCount > 0 || !path.isEmpty || lazyHasArc()) return notCircles()
        moved = false
        circlesCcw = ccw
        if (circleCount * 3 + 3 > circles.size) circles = circles.copyOf(circles.size * 2)
        circles[circleCount * 3] = cx; circles[circleCount * 3 + 1] = cy; circles[circleCount * 3 + 2] = a.r * sqrt(s2)
        circleCount++
    }

    /**
     * The path filled as its circles, one by one, when that's the same
     * picture (win32.zig fillCircles): a nonzero fill (even-odd makes holes
     * where they overlap) of whole circles wound one way (their union), in
     * an opaque color (an overlap can't blend twice). Many circles only: a
     * few go the usual way. False: fill the path.
     */
    private fun fillCircles(): Boolean {
        if (!onlyCircles || circleCount < 8 || moved) return false
        val fill = st.fill as? CvPaint.Solid ?: return false
        if (Color.alpha(fill.color) != 255 || st.alpha < 1f) return false
        // The circles are in the bitmap's space: drawn under the canvas's
        // own transform without the program's.
        if (!st.ctm.invert(inverse)) return false
        c.save()
        c.concat(inverse)
        for (i in 0 until circleCount) c.drawCircle(circles[i * 3], circles[i * 3 + 1], circles[i * 3 + 2], paint)
        c.restore()
        return true
    }

    /** The records into `path`, in order, each arc under the transform it
     *  was given in: the Path the ops would have made at once. */
    private fun pathNow() {
        if (lazyLen == 0) return
        val n = lazyLen
        lazyLen = 0
        ctmNow.set(st.ctm)
        var i = 0
        while (i < n) {
            if (lazy[i] == 0f) { path.moveTo(lazy[i + 1], lazy[i + 2]); i += 3; continue }
            System.arraycopy(lazy, i + 6, lazyM, 0, 9)
            lazyCtm.setValues(lazyM)
            st.ctm.set(lazyCtm)
            arcPath(lazy[i + 1], lazy[i + 2], lazy[i + 3], lazy[i + 4], lazy[i + 5])
            i += 15
        }
        st.ctm.set(ctmNow)
    }

    private fun arcPath(x: Float, y: Float, r: Float, a0: Float, sweep: Float) {
        var t = a0
        map(x + r * cos(t), y + r * sin(t))
        if (path.isEmpty) path.moveTo(pt[0], pt[1]) else path.lineTo(pt[0], pt[1])
        if (r == 0f || sweep == 0f) return
        val n = ceil(abs(sweep) / (PI.toFloat() / 2) - 1e-4f).toInt().coerceAtLeast(1)
        val step = sweep / n
        val k = 4f / 3f * tan(step / 4)
        repeat(n) {
            val t1 = t + step
            val c0 = cos(t); val s0 = sin(t); val c1 = cos(t1); val s1 = sin(t1)
            map(
                x + r * (c0 - k * s0), y + r * (s0 + k * c0),
                x + r * (c1 + k * s1), y + r * (s1 - k * c1),
                x + r * c1, y + r * s1,
            )
            path.cubicTo(pt[0], pt[1], pt[2], pt[3], pt[4], pt[5])
            t = t1
        }
    }

    /** Set up `paint` for a style; false when there's nothing to draw with. */
    private fun use(p: CvPaint, style: Paint.Style): Boolean {
        paint.reset()
        paint.isAntiAlias = true
        paint.style = style
        if (style == Paint.Style.STROKE) {
            paint.strokeWidth = st.lw.coerceAtLeast(0.1f)
            paint.strokeCap = when (st.cap) { 1 -> Paint.Cap.ROUND; 2 -> Paint.Cap.SQUARE; else -> Paint.Cap.BUTT }
            paint.strokeJoin = when (st.join) { 1 -> Paint.Join.ROUND; 2 -> Paint.Join.BEVEL; else -> Paint.Join.MITER }
        }
        when (p) {
            is CvPaint.Solid -> {
                // The global alpha goes into colors; gradients' stops carry their own (as on GTK).
                paint.color = Color.argb((Color.alpha(p.color) * st.alpha).toInt(), Color.red(p.color), Color.green(p.color), Color.blue(p.color))
            }
            is CvPaint.Grad -> paint.shader = shaderOf(p.id) ?: return false
        }
        return true
    }

    private fun shaderOf(id: Int): Shader? {
        val g = grads[id] ?: return null
        g.shader?.let { return it }
        if (g.stops.isEmpty()) return null
        // Offsets in order (a stable sort, as a canvas orders them); one stop is a flat color.
        val stops = g.stops.withIndex().sortedWith(compareBy({ it.value.first }, { it.index })).map { it.value }
        val colors = IntArray(maxOf(2, stops.size)) { stops[min(it, stops.size - 1)].second }
        val pos = FloatArray(colors.size) { if (stops.size == 1) it.toFloat() else stops[it].first }
        val v = g.g
        g.shader = if (g.linear) LinearGradient(v[0], v[1], v[2], v[3], colors, pos, Shader.TileMode.CLAMP)
        // Two circles, as canvas's createRadialGradient (API 29).
        else RadialGradient(v[0], v[1], v[2].coerceAtLeast(0f), v[3], v[4], v[5].coerceAtLeast(0.001f),
            LongArray(colors.size) { Color.pack(colors[it]) }, pos, Shader.TileMode.CLAMP)
        return g.shader
    }

    private fun text(op: CvOp.Text) {
        if (!use(if (op.stroke) st.stroke else st.fill, if (op.stroke) Paint.Style.STROKE else Paint.Style.FILL)) return
        if (op.stroke) paint.strokeWidth = st.lw.coerceAtLeast(0.5f)
        paint.textSize = st.size.coerceAtLeast(1f)
        paint.typeface = Typeface.create(familyOf(st.family), st.weight.coerceIn(1, 1000), st.italic)
        paint.textAlign = when (st.align) { 1 -> Paint.Align.CENTER; 2 -> Paint.Align.RIGHT; else -> Paint.Align.LEFT }
        val fm = paint.fontMetrics
        // The anchor's y as a baseline: top, middle and bottom move it by the font's box.
        val y = when (st.baseline) {
            1 -> op.y - fm.ascent // top
            3 -> op.y - (fm.ascent + fm.descent) / 2 // middle
            4 -> op.y - fm.descent // bottom
            else -> op.y // alphabetic, hanging
        }
        c.drawText(op.t, op.x, y, paint)
    }

    private fun familyOf(family: String): Typeface {
        val f = family.lowercase()
        return when {
            f.endsWith("monospace") -> Typeface.MONOSPACE
            f.endsWith("sans-serif") || f.isEmpty() -> Typeface.SANS_SERIF
            f.endsWith("serif") -> Typeface.SERIF
            else -> Typeface.create(family, Typeface.NORMAL)
        }
    }

    private companion object {
        val clearPaint = Paint().apply { xfermode = PorterDuffXfermode(PorterDuff.Mode.CLEAR) }
    }
}
