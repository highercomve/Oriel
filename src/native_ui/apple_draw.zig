//! The native renderer's drawing on Apple platforms, shared by the AppKit
//! (appkit.zig) and UIKit (uikit.zig) backends (docs/native-renderer.md):
//! text measured and drawn with CoreText, boxes, gradients, borders,
//! shadows and icons with CoreGraphics. The backends only provide the view,
//! the fields and the input; `paint` draws a whole tree into the view's
//! context, which both give with a top-left origin (y down).
//!
//! UI thread only (the font cache isn't locked).

const std = @import("std");
const objc = @import("../platform/apple/objc.zig");
const tree_mod = @import("tree.zig");
const svg_path = @import("svg_path.zig");
const Engine = @import("engine.zig").Engine;
const Node = tree_mod.Node;
const Rect = tree_mod.Rect;
const Object = objc.Object;

// ---------------------------------------------------------------------------
// CoreFoundation, CoreGraphics, CoreText

pub const CGFloat = f64;
pub const CGPoint = extern struct { x: CGFloat, y: CGFloat };
pub const CGSize = extern struct { width: CGFloat, height: CGFloat };
pub const CGRect = extern struct { origin: CGPoint, size: CGSize };
const CFRange = extern struct { location: c_long, length: c_long };
const CGAffineTransform = extern struct { a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat, tx: CGFloat, ty: CGFloat };

pub const CGContextRef = *opaque {};
const CFTypeRef = *anyopaque;
const CFStringRef = *anyopaque;
const CFAttributedStringRef = *anyopaque;
const CTFontRef = *anyopaque;
const Radii = tree_mod.Radii;
const CGColorSpaceRef = *anyopaque;
const CGColorRef = *anyopaque;
const CGGradientRef = *anyopaque;
const CTFramesetterRef = *anyopaque;
const CTFrameRef = *anyopaque;
const CGPathRef = *anyopaque;
const CTParagraphStyleRef = *anyopaque;
const CFNumberRef = *anyopaque;

extern fn CFRelease(cf: CFTypeRef) void;
extern fn CFRetain(cf: CFTypeRef) CFTypeRef;
extern fn CFStringCreateWithBytes(alloc: ?*anyopaque, bytes: [*]const u8, len: c_long, encoding: u32, external: u8) ?CFStringRef;
extern fn CFStringGetLength(s: CFStringRef) c_long;
extern fn CFAttributedStringCreateMutable(alloc: ?*anyopaque, max: c_long) ?CFAttributedStringRef;
extern fn CFAttributedStringReplaceString(s: CFAttributedStringRef, range: CFRange, replacement: CFStringRef) void;
extern fn CFAttributedStringSetAttribute(s: CFAttributedStringRef, range: CFRange, name: CFStringRef, value: CFTypeRef) void;
extern fn CFAttributedStringGetLength(s: CFAttributedStringRef) c_long;
extern fn CFNumberCreate(alloc: ?*anyopaque, kind: c_long, value: *const anyopaque) ?CFNumberRef;
const kCFStringEncodingUTF8: u32 = 0x08000100;
const kCFNumberFloat64Type: c_long = 6;
const kCFNumberSInt32Type: c_long = 3;

extern fn CGContextSaveGState(c: CGContextRef) void;
extern fn CGContextRestoreGState(c: CGContextRef) void;
extern fn CGContextClipToRect(c: CGContextRef, r: CGRect) void;
extern fn CGContextClip(c: CGContextRef) void;
extern fn CGContextEOClip(c: CGContextRef) void;
extern fn CGContextBeginPath(c: CGContextRef) void;
extern fn CGContextMoveToPoint(c: CGContextRef, x: CGFloat, y: CGFloat) void;
extern fn CGContextAddLineToPoint(c: CGContextRef, x: CGFloat, y: CGFloat) void;
extern fn CGContextAddCurveToPoint(c: CGContextRef, x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat, x: CGFloat, y: CGFloat) void;
extern fn CGContextAddQuadCurveToPoint(c: CGContextRef, cx: CGFloat, cy: CGFloat, x: CGFloat, y: CGFloat) void;
extern fn CGContextAddArcToPoint(c: CGContextRef, x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat, r: CGFloat) void;
extern fn CGContextAddRect(c: CGContextRef, r: CGRect) void;
extern fn CGContextClosePath(c: CGContextRef) void;
extern fn CGContextFillPath(c: CGContextRef) void;
extern fn CGContextEOFillPath(c: CGContextRef) void;
extern fn CGContextFillRect(c: CGContextRef, r: CGRect) void;
extern fn CGContextClearRect(c: CGContextRef, r: CGRect) void;
extern fn CGContextStrokePath(c: CGContextRef) void;
extern fn CGContextDrawPath(c: CGContextRef, mode: c_int) void;
extern fn CGContextSetRGBFillColor(c: CGContextRef, r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) void;
extern fn CGContextSetRGBStrokeColor(c: CGContextRef, r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) void;
extern fn CGContextSetLineWidth(c: CGContextRef, w: CGFloat) void;
extern fn CGContextSetLineCap(c: CGContextRef, cap: c_int) void;
extern fn CGContextSetLineDash(c: CGContextRef, phase: CGFloat, lengths: ?[*]const CGFloat, count: usize) void;
extern fn CGContextFillEllipseInRect(c: CGContextRef, r: CGRect) void;
extern fn CGContextSetLineJoin(c: CGContextRef, join: c_int) void;
extern fn CGContextTranslateCTM(c: CGContextRef, x: CGFloat, y: CGFloat) void;
extern fn CGContextScaleCTM(c: CGContextRef, x: CGFloat, y: CGFloat) void;
extern fn CGContextRotateCTM(c: CGContextRef, angle: CGFloat) void;
extern fn CGContextSetAlpha(c: CGContextRef, a: CGFloat) void;
extern fn CGContextBeginTransparencyLayer(c: CGContextRef, aux: ?*anyopaque) void;
extern fn CGContextEndTransparencyLayer(c: CGContextRef) void;
extern fn CGContextSetTextMatrix(c: CGContextRef, t: CGAffineTransform) void;
extern fn CGContextDrawLinearGradient(c: CGContextRef, g: CGGradientRef, start: CGPoint, end: CGPoint, options: u32) void;
extern fn CGContextDrawRadialGradient(c: CGContextRef, g: CGGradientRef, sc: CGPoint, sr: CGFloat, ec: CGPoint, er: CGFloat, options: u32) void;
extern fn CGColorSpaceCreateDeviceRGB() ?CGColorSpaceRef;
extern fn CGColorSpaceCreateWithName(name: CFStringRef) ?CGColorSpaceRef;
extern const kCGColorSpaceSRGB: CFStringRef;
extern fn CGContextSetFillColorSpace(c: CGContextRef, space: CGColorSpaceRef) void;
extern fn CGContextSetStrokeColorSpace(c: CGContextRef, space: CGColorSpaceRef) void;
extern fn CGContextSetFillColor(c: CGContextRef, components: [*]const CGFloat) void;
extern fn CGContextSetStrokeColor(c: CGContextRef, components: [*]const CGFloat) void;
extern fn CGColorSpaceRelease(s: CGColorSpaceRef) void;
extern fn CGColorCreate(space: CGColorSpaceRef, components: [*]const CGFloat) ?CGColorRef;
extern fn CGColorRelease(c: CGColorRef) void;
extern fn CGGradientCreateWithColorComponents(space: CGColorSpaceRef, components: [*]const CGFloat, locations: [*]const CGFloat, count: usize) ?CGGradientRef;
extern fn CGGradientRelease(g: CGGradientRef) void;
extern fn CGPathCreateWithRect(r: CGRect, t: ?*const CGAffineTransform) ?CGPathRef;
extern fn CGContextAddArc(c: CGContextRef, x: CGFloat, y: CGFloat, r: CGFloat, a0: CGFloat, a1: CGFloat, clockwise: c_int) void;
extern fn CGContextDrawImage(c: CGContextRef, r: CGRect, img: CGImageRef) void;
extern fn CGImageRelease(img: CGImageRef) void;
extern fn CFDataCreate(alloc: ?*anyopaque, bytes: [*]const u8, len: c_long) ?CFTypeRef;
extern fn CGImageSourceCreateWithData(data: CFTypeRef, options: ?*anyopaque) ?CFTypeRef;
extern fn CGImageSourceCopyPropertiesAtIndex(src: CFTypeRef, index: usize, options: ?*anyopaque) ?CFTypeRef;
extern fn CFDictionaryGetValue(dict: CFTypeRef, key: *const anyopaque) ?*const anyopaque;
extern fn CFNumberGetValue(num: *const anyopaque, kind: c_long, out: *anyopaque) u8;
extern const kCGImagePropertyPixelWidth: CFStringRef;
extern fn CGImageSourceCreateThumbnailAtIndex(src: CFTypeRef, index: usize, options: ?CFTypeRef) ?CGImageRef;
extern fn CFDictionaryCreate(alloc: ?*anyopaque, keys: [*]const ?*const anyopaque, values: [*]const ?*const anyopaque, n: c_long, kcb: *const anyopaque, vcb: *const anyopaque) ?CFTypeRef;
extern const kCFTypeDictionaryKeyCallBacks: u8;
extern const kCFTypeDictionaryValueCallBacks: u8;
extern const kCFBooleanTrue: CFTypeRef;
extern const kCGImageSourceCreateThumbnailFromImageAlways: CFStringRef;
extern const kCGImageSourceCreateThumbnailWithTransform: CFStringRef;
extern const kCGImageSourceThumbnailMaxPixelSize: CFStringRef;
extern const kCGImagePropertyPixelHeight: CFStringRef;
const CGImageRef = *anyopaque;
const kCFNumberSInt64Type: c_long = 4;
extern fn CGBitmapContextCreate(data: ?*anyopaque, w: usize, h: usize, bpc: usize, bpr: usize, space: CGColorSpaceRef, info: u32) ?CGContextRef;
extern fn CGBitmapContextCreateImage(c: CGContextRef) ?CGImageRef;
extern fn CGContextRelease(c: CGContextRef) void;
extern fn CGBitmapContextGetData(c: CGContextRef) ?[*]u8;
extern fn CGContextAddPath(c: CGContextRef, p: CGPathRef) void;
extern fn CGContextConcatCTM(c: CGContextRef, t: CGAffineTransform) void;
extern fn CGContextSetBlendMode(c: CGContextRef, mode: c_int) void;
extern fn CGContextReplacePathWithStrokedPath(c: CGContextRef) void;
extern fn CGContextSetTextDrawingMode(c: CGContextRef, mode: c_int) void;
extern fn CGContextSetTextPosition(c: CGContextRef, x: CGFloat, y: CGFloat) void;
extern fn CGPathCreateMutable() ?CGPathRef;
extern fn CGPathMoveToPoint(p: CGPathRef, t: ?*const CGAffineTransform, x: CGFloat, y: CGFloat) void;
extern fn CGPathAddLineToPoint(p: CGPathRef, t: ?*const CGAffineTransform, x: CGFloat, y: CGFloat) void;
extern fn CGPathAddCurveToPoint(p: CGPathRef, t: ?*const CGAffineTransform, x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat, x: CGFloat, y: CGFloat) void;
extern fn CGPathAddRect(p: CGPathRef, t: ?*const CGAffineTransform, r: CGRect) void;
extern fn CGPathAddArc(p: CGPathRef, t: ?*const CGAffineTransform, x: CGFloat, y: CGFloat, r: CGFloat, a0: CGFloat, a1: CGFloat, clockwise: bool) void;
extern fn CGPathCloseSubpath(p: CGPathRef) void;
extern fn CGPathIsEmpty(p: CGPathRef) bool;
extern fn CGPathCreateCopyByTransformingPath(p: CGPathRef, t: *const CGAffineTransform) ?CGPathRef;
extern fn CGAffineTransformInvert(t: CGAffineTransform) CGAffineTransform;
extern fn CTLineCreateWithAttributedString(s: CFAttributedStringRef) ?CFTypeRef;
extern fn CTLineGetTypographicBounds(line: CFTypeRef, ascent: ?*CGFloat, descent: ?*CGFloat, leading: ?*CGFloat) f64;
extern fn CTLineDraw(line: CFTypeRef, c: CGContextRef) void;
extern fn CTFontGetAscent(font: CTFontRef) CGFloat;
extern fn CTFontCopyFamilyName(font: CTFontRef) ?CFStringRef;
extern fn CFStringCompare(a: CFStringRef, b: CFStringRef, options: u32) isize;
extern fn CTFontGetDescent(font: CTFontRef) CGFloat;
extern fn CTFontGetLeading(font: CTFontRef) CGFloat;
extern fn CTFontCreateWithName(name: CFStringRef, size: CGFloat, matrix: ?*const CGAffineTransform) ?CTFontRef;
extern const kCTForegroundColorFromContextAttributeName: CFStringRef;
const kCGImageAlphaPremultipliedLast: u32 = 1;
const kCGBitmapByteOrder32Big: u32 = 4 << 12;
const kCGBlendModeNormal: c_int = 0;
const kCGBlendModeClear: c_int = 16;
const kCGTextFill: c_int = 0;
const kCGTextStroke: c_int = 1;
const kCGTextClip: c_int = 7;
const kCGTextStrokeClip: c_int = 5;
extern fn CGPathRelease(p: CGPathRef) void;
const kCGPathFill: c_int = 0;
const kCGPathEOFill: c_int = 1;
const kCGPathFillStroke: c_int = 3;
const kCGPathEOFillStroke: c_int = 4;
const kCGGradientDrawsBeforeAndAfter: u32 = 3;

extern fn CTFontCreateCopyWithSymbolicTraits(font: CTFontRef, size: CGFloat, matrix: ?*const CGAffineTransform, value: u32, mask: u32) ?CTFontRef;
extern fn CTFramesetterCreateWithAttributedString(s: CFAttributedStringRef) ?CTFramesetterRef;
extern fn CTFramesetterSuggestFrameSizeWithConstraints(fs: CTFramesetterRef, range: CFRange, attrs: ?*anyopaque, constraints: CGSize, fit: ?*CFRange) CGSize;
extern fn CTFramesetterCreateFrame(fs: CTFramesetterRef, range: CFRange, path: CGPathRef, attrs: ?*anyopaque) ?CTFrameRef;
extern fn CTFrameDraw(frame: CTFrameRef, c: CGContextRef) void;
extern fn CTFrameGetLines(frame: CTFrameRef) CFTypeRef;
extern fn CTFrameGetLineOrigins(frame: CTFrameRef, range: CFRange, origins: [*]CGPoint) void;
extern fn CTLineGetStringRange(line: CFTypeRef) CFRange;
extern fn CTLineGetOffsetForStringIndex(line: CFTypeRef, index: c_long, secondary: ?*CGFloat) CGFloat;
extern fn CTLineGetTrailingWhitespaceWidth(line: CFTypeRef) f64;
extern fn CTLineGetGlyphRuns(line: CFTypeRef) CFTypeRef;
extern fn CTRunGetStringRange(run: CFTypeRef) CFRange;
extern fn CTRunGetGlyphCount(run: CFTypeRef) c_long;
extern fn CTRunGetPositions(run: CFTypeRef, range: CFRange, out: [*]CGPoint) void;
extern fn CTRunGetTypographicBounds(run: CFTypeRef, range: CFRange, ascent: ?*CGFloat, descent: ?*CGFloat, leading: ?*CGFloat) f64;
extern fn CFArrayGetCount(a: CFTypeRef) c_long;
extern fn CFArrayGetValueAtIndex(a: CFTypeRef, i: c_long) CFTypeRef;
const CTParagraphStyleSetting = extern struct { spec: u32, size: usize, value: *const anyopaque };
extern fn CTParagraphStyleCreate(settings: [*]const CTParagraphStyleSetting, count: usize) ?CTParagraphStyleRef;
const kCTParagraphStyleSpecifierAlignment: u32 = 0;
const kCTParagraphStyleSpecifierLineBreakMode: u32 = 6;
const kCTParagraphStyleSpecifierMaximumLineHeight: u32 = 8;
const kCTParagraphStyleSpecifierMinimumLineHeight: u32 = 9;
const kCTFontItalicTrait: u32 = 1 << 0;
const kCTFontBoldTrait: u32 = 1 << 1;
const kCFCompareCaseInsensitive: u32 = 1;
extern const kCTFontAttributeName: CFStringRef;
extern const kCTForegroundColorAttributeName: CFStringRef;
extern const kCTUnderlineStyleAttributeName: CFStringRef;
extern const kCTKernAttributeName: CFStringRef;
extern const kCTParagraphStyleAttributeName: CFStringRef;

const big: CGFloat = 1e7;

fn rect(r: Rect) CGRect {
    return .{ .origin = .{ .x = r.x, .y = r.y }, .size = .{ .width = r.w, .height = r.h } };
}

// ---------------------------------------------------------------------------
// Fonts: the system font (San Francisco) at a weight, from NSFont/UIFont,
// which are toll-free bridged to CTFont. Cached, retained, for the run.

const FontKey = struct { size: f32, weight: i32, italic: bool, mono: bool, family: u64 };
var font_cache: std.ArrayListUnmanaged(struct { key: FontKey, font: CTFontRef }) = .empty;
const font_cache_max = 128;

/// CSS font-weight (100-900) to NSFontWeight/UIFontWeight.
fn appleWeight(w: f32) f64 {
    const table = [_]f64{ -0.8, -0.6, -0.4, 0, 0.23, 0.3, 0.4, 0.56, 0.62 };
    const i: usize = @intFromFloat(std.math.clamp(@round(w / 100) - 1, 0, 8));
    return table[i];
}

/// `font_class`: "NSFont" (AppKit) or "UIFont" (UIKit). `family`: the CSS
/// font-family list (null: sans-serif), resolved as WKWebView does
/// (resolveFamily).
pub fn font(comptime font_class: [:0]const u8, size: f32, weight: f32, italic: bool, mono: bool, family: ?[]const u8) ?CTFontRef {
    // Half points: a font-size transition would otherwise add a font per frame.
    const half = std.math.clamp(@round(size * 2) / 2, 0.5, 2000);
    const key: FontKey = .{
        .size = half,
        .weight = @intFromFloat(std.math.clamp(@round(weight / 100), 1, 9)),
        .italic = italic,
        .mono = mono,
        .family = if (family) |f| std.hash.Wyhash.hash(0, f) else 0,
    };
    for (font_cache.items) |e| if (std.meta.eql(e.key, key)) return e.font;
    // Bounded: past the limit start over (the text already built keeps the
    // fonts it uses retained).
    if (font_cache.items.len >= font_cache_max) {
        for (font_cache.items) |e| CFRelease(e.font);
        font_cache.clearRetainingCapacity();
    }
    var ct = resolveFamily(font_class, half, weight, mono, family) orelse return null;
    if (italic) if (CTFontCreateCopyWithSymbolicTraits(ct, 0, null, kCTFontItalicTrait, kCTFontItalicTrait)) |it| {
        CFRelease(ct);
        ct = it;
    };
    font_cache.append(std.heap.smp_allocator, .{ .key = key, .font = ct }) catch {
        CFRelease(ct);
        return null;
    };
    return ct;
}

/// The system font (+1), or its monospaced cut, at a CSS weight.
fn systemFont(comptime font_class: [:0]const u8, size: f32, weight: f32, mono: bool) ?CTFontRef {
    const cls = objc.getClass(font_class) orelse return null;
    const sel = if (mono) "monospacedSystemFontOfSize:weight:" else "systemFontOfSize:weight:";
    const f = cls.msgSend(Object, sel, .{ @as(CGFloat, size), appleWeight(weight) });
    if (f.value == null) return null;
    return CFRetain(@ptrCast(f.value.?));
}

/// An installed family by name (+1), bold from 600, or null when it isn't
/// installed (CoreText would substitute another).
fn namedFont(name: []const u8, size: f32, weight: f32) ?CTFontRef {
    const cf = CFStringCreateWithBytes(null, name.ptr, @intCast(name.len), kCFStringEncodingUTF8, 0) orelse return null;
    defer CFRelease(cf);
    var f = CTFontCreateWithName(cf, size, null) orelse return null;
    const got = CTFontCopyFamilyName(f) orelse {
        CFRelease(f);
        return null;
    };
    defer CFRelease(got);
    if (CFStringCompare(got, cf, kCFCompareCaseInsensitive) != 0) {
        CFRelease(f);
        return null;
    }
    if (weight >= 600) if (CTFontCreateCopyWithSymbolicTraits(f, 0, null, kCTFontBoldTrait, kCTFontBoldTrait)) |bold| {
        CFRelease(f);
        f = bold;
    };
    return f;
}

/// A CSS font-family list to a font (+1), as WKWebView resolves it: the
/// first family that's installed; system-ui (and -apple-system,
/// BlinkMacSystemFont, ui-sans-serif) the system font, ui-monospace its
/// monospaced cut; the generic families WebKit's defaults (sans-serif
/// Helvetica, serif and "default" — no font-family on the page — Times,
/// monospace Courier). Null: sans-serif (or monospace for `mono`).
fn resolveFamily(comptime font_class: [:0]const u8, size: f32, weight: f32, mono: bool, family: ?[]const u8) ?CTFontRef {
    const eq = std.ascii.eqlIgnoreCase;
    var it = std.mem.tokenizeScalar(u8, family orelse "", ',');
    while (it.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t\"'");
        if (name.len == 0) continue;
        if (eq(name, "system-ui") or eq(name, "-apple-system") or eq(name, "BlinkMacSystemFont") or eq(name, "ui-sans-serif"))
            return systemFont(font_class, size, weight, false);
        if (eq(name, "ui-monospace")) return systemFont(font_class, size, weight, true);
        // "default": the page sets no font-family (WebKit's standard font).
        if (eq(name, "serif") or eq(name, "ui-serif") or eq(name, "default")) {
            // iOS has Times New Roman under Times' name.
            if (namedFont("Times", size, weight) orelse namedFont("Times New Roman", size, weight)) |f| return f;
            continue;
        }
        const generic: ?[]const u8 = if (eq(name, "sans-serif")) "Helvetica" else if (eq(name, "monospace")) "Courier" else if (eq(name, "cursive")) "Apple Chancery" else if (eq(name, "fantasy")) "Papyrus" else null;
        if (namedFont(generic orelse name, size, weight)) |f| return f;
    }
    return namedFont(if (mono) "Courier" else "Helvetica", size, weight) orelse systemFont(font_class, size, weight, mono);
}

/// A font's line metrics as WebKit uses them on Apple platforms
/// (FontCocoa): line-height: normal is their sum. Measured against
/// WKWebView (16 and 36 px; system-ui, Helvetica, Courier, Times, Helvetica
/// Neue):
/// - macOS: ascent, descent and line gap each rounded to whole pixels;
///   Times, Helvetica and Courier get round((ascent + descent) x 0.15)
///   more ascent, to match their Windows counterparts.
/// - iOS: each rounded up; Helvetica gets round(sum x 0.15) more ascent
///   (iOS's Times is Times New Roman, and its Courier gets none).
const LineMetrics = struct { ascent: f32, descent: f32, gap: f32 };

const ios = @import("builtin").os.tag == .ios;

fn familyIs(f: CTFontRef, comptime names: []const []const u8) bool {
    const fam = CTFontCopyFamilyName(f) orelse return false;
    defer CFRelease(fam);
    inline for (names) |name| {
        if (CFStringCreateWithBytes(null, name.ptr, name.len, kCFStringEncodingUTF8, 0)) |cf| {
            defer CFRelease(cf);
            if (CFStringCompare(fam, cf, kCFCompareCaseInsensitive) == 0) return true;
        }
    }
    return false;
}

fn lineMetrics(f: CTFontRef) LineMetrics {
    const A: f32 = @floatCast(CTFontGetAscent(f));
    const D: f32 = @floatCast(CTFontGetDescent(f));
    const L: f32 = @floatCast(@max(0, CTFontGetLeading(f)));
    if (ios) {
        var a = @ceil(A);
        const d = @ceil(D);
        const g = @ceil(L);
        if (familyIs(f, &.{"Helvetica"})) a += @round((a + d + g) * 0.15);
        return .{ .ascent = a, .descent = d, .gap = g };
    }
    var a = @round(A);
    const d = @round(D);
    if (familyIs(f, &.{ "Times", "Helvetica", "Courier" })) a += @round((a + d) * 0.15);
    return .{ .ascent = a, .descent = d, .gap = @round(L) };
}

/// Backend.font_metrics: the ascent, descent and line gap (px, as WebKit
/// rounds them) of the default sans-serif (or monospace) at `size`.
pub fn fontMetrics(comptime font_class: [:0]const u8, size: f32, mono: bool, out: *[3]f32) bool {
    if (!(size > 0) or !std.math.isFinite(size)) return false;
    const f = font(font_class, size, 400, false, mono, null) orelse return false;
    const m = lineMetrics(f);
    out.* = .{ m.ascent, m.descent, m.gap };
    return true;
}

/// A field's line (input, select, textarea): its CSS line-height, else
/// the normal line height of its font, as WebKit sizes a control's text.
pub fn fieldLine(comptime font_class: [:0]const u8, n: *const Node) f32 {
    const fz = n.props.fz orelse 16;
    if (n.props.lh) |lh| if (lh >= 1 and std.math.isFinite(lh)) return @floor(lh);
    const f = font(font_class, fz, n.props.fwt orelse 400, n.props.it, n.props.mono, n.props.ff) orelse return @round(fz * 1.2);
    const m = lineMetrics(f);
    return m.ascent + m.descent + m.gap;
}

/// A text node's line box: its height (CSS line-height, whole pixels as
/// WebKit keeps it, else normal: its largest font's ascent + descent +
/// gap) and that font's ascent and descent, which place the baseline.
const LineBox = struct { h: f32, m: LineMetrics };

fn lineBoxOf(comptime font_class: [:0]const u8, n: *const Node) ?LineBox {
    var size: f32 = n.props.fz orelse 16;
    var weight: f32 = 400;
    var italic = false;
    var mono = n.props.mono;
    var family = n.props.ff;
    if (n.props.runs) |runs| {
        if (runs.len > 0) size = 0;
        for (runs) |r| if (r.sz >= size) {
            size = r.sz;
            weight = r.w;
            italic = r.i;
            mono = r.mono or n.props.mono;
            family = r.ff orelse n.props.ff;
        };
    }
    const f = font(font_class, size, weight, italic, mono, family) orelse return null;
    const m = lineMetrics(f);
    if (n.props.lh) |lh| {
        if (!(lh >= 1) or !std.math.isFinite(lh)) return null;
        return .{ .h = @floor(lh), .m = m };
    }
    return .{ .h = m.ascent + m.descent + m.gap, .m = m };
}

// ---------------------------------------------------------------------------
// Text

/// A text node's runs as a CoreText attributed string (+1), or null.
fn attributed(comptime font_class: [:0]const u8, n: *const Node) ?CFAttributedStringRef {
    const runs = n.props.runs orelse return null;
    const s = CFAttributedStringCreateMutable(null, 0) orelse return null;
    const space = srgb() orelse {
        CFRelease(s);
        return null;
    };
    for (runs) |r| {
        if (r.t.len == 0) continue;
        const str = CFStringCreateWithBytes(null, r.t.ptr, @intCast(r.t.len), kCFStringEncodingUTF8, 0) orelse continue;
        defer CFRelease(str);
        const start = CFAttributedStringGetLength(s);
        CFAttributedStringReplaceString(s, .{ .location = start, .length = 0 }, str);
        const range: CFRange = .{ .location = start, .length = CFStringGetLength(str) };
        if (font(font_class, r.sz, r.w, r.i, r.mono or n.props.mono, r.ff orelse n.props.ff)) |f| CFAttributedStringSetAttribute(s, range, kCTFontAttributeName, f);
        const comps = [4]CGFloat{ r.c[0] / 255, r.c[1] / 255, r.c[2] / 255, r.c[3] };
        if (CGColorCreate(space, &comps)) |col| {
            CFAttributedStringSetAttribute(s, range, kCTForegroundColorAttributeName, col);
            CGColorRelease(col);
        }
        if (r.u) {
            const one: i32 = 1;
            if (CFNumberCreate(null, kCFNumberSInt32Type, &one)) |num| {
                CFAttributedStringSetAttribute(s, range, kCTUnderlineStyleAttributeName, num);
                CFRelease(num);
            }
        }
    }
    const len = CFAttributedStringGetLength(s);
    if (len == 0) return s;
    const all: CFRange = .{ .location = 0, .length = len };
    if (n.props.ls) |ls| {
        const v: f64 = ls;
        if (CFNumberCreate(null, kCFNumberFloat64Type, &v)) |num| {
            CFAttributedStringSetAttribute(s, all, kCTKernAttributeName, num);
            CFRelease(num);
        }
    }
    // Alignment and line height.
    var settings: [4]CTParagraphStyleSetting = undefined;
    var count: usize = 0;
    var alignment: u8 = 0; // left (natural would follow the language)
    if (n.props.ta) |ta| {
        if (std.mem.eql(u8, ta, "center")) alignment = 2;
        if (std.mem.eql(u8, ta, "right") or std.mem.eql(u8, ta, "end")) alignment = 1;
    }
    settings[count] = .{ .spec = kCTParagraphStyleSpecifierAlignment, .size = 1, .value = &alignment };
    count += 1;
    // Every line exactly its line box (lineBoxOf: CSS's, or normal as
    // WebKit makes it): CoreText measures lines x that.
    var lh: CGFloat = 0;
    if (lineBoxOf(font_class, n)) |lb| {
        lh = lb.h;
        settings[count] = .{ .spec = kCTParagraphStyleSpecifierMinimumLineHeight, .size = @sizeOf(CGFloat), .value = &lh };
        count += 1;
        settings[count] = .{ .spec = kCTParagraphStyleSpecifierMaximumLineHeight, .size = @sizeOf(CGFloat), .value = &lh };
        count += 1;
    }
    if (CTParagraphStyleCreate(&settings, count)) |ps| {
        CFAttributedStringSetAttribute(s, all, kCTParagraphStyleAttributeName, ps);
        CFRelease(ps);
    }
    return s;
}

/// A text node's CoreText objects, kept in `Node.native` from one layout
/// and paint to the next: building them is most of a frame's cost. Dropped
/// when the node's props change (`dropText`) or it goes away.
const TextCache = struct {
    /// Null for a node without text.
    fs: ?CTFramesetterRef,
    /// The frame drawn last time, for its width and height.
    frame: ?CTFrameRef = null,
    frame_w: CGFloat = -1,
    frame_h: CGFloat = -1,
};

fn textCache(comptime font_class: [:0]const u8, n: *Node) ?*TextCache {
    if (n.native) |p| return @ptrCast(@alignCast(p));
    const c = std.heap.smp_allocator.create(TextCache) catch return null;
    c.* = .{ .fs = null };
    if (attributed(font_class, n)) |s| {
        defer CFRelease(s);
        if (CFAttributedStringGetLength(s) > 0) c.fs = CTFramesetterCreateWithAttributedString(s);
    }
    n.native = c;
    return c;
}

/// Forget a text node's CoreText objects (its props changed, or it goes).
pub fn dropText(n: *Node) void {
    if (n.kind != .text) return;
    const p = n.native orelse return;
    n.native = null;
    const c: *TextCache = @ptrCast(@alignCast(p));
    if (c.frame) |f| CFRelease(f);
    if (c.fs) |fs| CFRelease(fs);
    std.heap.smp_allocator.destroy(c);
}

/// Forget everything a node keeps here (it goes away): its text or picture.
pub fn dropNative(n: *Node) void {
    switch (n.kind) {
        .text => dropText(n),
        .image => dropImage(n),
        .canvas => dropCanvas(n),
        else => {},
    }
}

/// Load a font the page will use (Backend.warm_fonts): a short line in it,
/// laid out as the first text in that size and weight would be, so its
/// match, load and glyph tables aren't paid for when a page or tab first
/// shows (about 6 ms for the first fonts on iOS).
pub fn warmFont(comptime font_class: [:0]const u8, spec: @import("engine.zig").FontSpec) void {
    var run: tree_mod.Run = .{ .t = "Aa", .sz = spec.size, .w = @floatFromInt(spec.weight), .i = spec.italic, .mono = spec.mono };
    var n: Node = undefined; // attributed() reads only its props
    n.props = .{};
    n.props.fz = spec.size;
    n.props.mono = spec.mono;
    n.props.runs = @as(*const [1]tree_mod.Run, &run);
    const str = attributed(font_class, &n) orelse return;
    defer CFRelease(str);
    const line = CTLineCreateWithAttributedString(str) orelse return;
    defer CFRelease(line);
    _ = CTLineGetTypographicBounds(line, null, null, null);
}

/// The size a text node needs at `max_width` (inf: one line per paragraph).
/// Its natural (unwrapped) size is kept in the node under the surface's
/// text epoch (`epoch`, from 1): a measure at a width it fits in needs no
/// CoreText, and a text-only update that keeps that size keeps its layout
/// (`Tree.reuse_text_layout`). New props or text clear it.
pub fn measureText(comptime font_class: [:0]const u8, n: *Node, max_width: f32, epoch: u64) [2]f32 {
    const nat = if (n.measured_text_size != null and n.text_measure_epoch == epoch) n.measured_text_size.? else blk: {
        const size = suggestText(font_class, n, big) orelse return .{ 0, 0 };
        n.measured_text_size = size;
        n.text_measure_epoch = epoch;
        break :blk size;
    };
    if (n.props.nowrap or std.math.isInf(max_width) or max_width >= nat[0]) return nat;
    return suggestText(font_class, n, @max(1, max_width)) orelse .{ 0, 0 };
}

fn suggestText(comptime font_class: [:0]const u8, n: *Node, w: CGFloat) ?[2]f32 {
    const cache = textCache(font_class, n) orelse return null;
    const fs = cache.fs orelse return .{ 0, @round((n.props.fz orelse 16) * 1.2) };
    const size = CTFramesetterSuggestFrameSizeWithConstraints(fs, .{ .location = 0, .length = 0 }, null, .{ .width = if (n.props.nowrap) big else w, .height = big }, null);
    // Lines x the line box (CoreText's own height can be a hair over, a
    // font's leading on top of the fixed line height).
    if (lineBoxOf(font_class, n)) |lb| {
        const lines = @max(1, @round(size.height / lb.h));
        return .{ @floatCast(@ceil(size.width) + 1), @floatCast(lines * lb.h) };
    }
    return .{ @floatCast(@ceil(size.width) + 1), @floatCast(@ceil(size.height)) };
}

fn paintText(comptime font_class: [:0]const u8, cg: CGContextRef, n: *Node) void {
    const c = n.content();
    const cache = textCache(font_class, n) orelse return;
    const fs = cache.fs orelse return;
    // As wide as laid out (+1, as measured), and tall enough for every line:
    // the frame lays text out from its top.
    const w: CGFloat = if (n.props.nowrap) big else c.w + 1;
    var h: CGFloat = c.h;
    // A CSS line-height: the lines are placed here (cssLineOrigin), so the
    // frame only breaks them, in a frame tall enough to keep every one (a
    // line-height under the font's own height made CoreText drop lines).
    const lb = lineBoxOf(font_class, n);
    if (cache.frame == null or cache.frame_w != w or cache.frame_h < h) {
        const need = CTFramesetterSuggestFrameSizeWithConstraints(fs, .{ .location = 0, .length = 0 }, null, .{ .width = w, .height = big }, null);
        h = @max(c.h, @ceil(need.height));
        if (lb) |box| {
            // Lines at the font's own height (generously: 3 font sizes each).
            const lines = @ceil(need.height / box.h) + 1;
            h = @max(h, lines * 3 * @as(CGFloat, n.props.fz orelse 16));
        }
        const path = CGPathCreateWithRect(.{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = if (n.props.nowrap) @ceil(need.width) + 1 else w, .height = h } }, null) orelse return;
        defer CGPathRelease(path);
        const created = CTFramesetterCreateFrame(fs, .{ .location = 0, .length = 0 }, path, null) orelse return;
        if (cache.frame) |old| CFRelease(old);
        cache.frame = created;
        cache.frame_w = w;
        cache.frame_h = h;
    }
    h = cache.frame_h;
    const frame = cache.frame.?;
    // CoreText draws with y up: flip around the text's box.
    CGContextSaveGState(cg);
    defer CGContextRestoreGState(cg);
    CGContextTranslateCTM(cg, c.x, c.y + h);
    CGContextScaleCTM(cg, 1, -1);
    CGContextSetTextMatrix(cg, .{ .a = 1, .b = 0, .c = 0, .d = 1, .tx = 0, .ty = 0 });
    paintRunBackgrounds(cg, frame, h, lb, n);
    if (lb == null) return CTFrameDraw(frame, cg);
    const lines = CTFrameGetLines(frame);
    var i: c_long = 0;
    while (i < CFArrayGetCount(lines)) : (i += 1) {
        const line = CFArrayGetValueAtIndex(lines, i);
        const o = lineOrigin(frame, i, h, lb);
        CGContextSetTextPosition(cg, o.x, o.y);
        CTLineDraw(line, cg);
    }
}

/// Line `i`'s origin in the flipped CoreText space paintText sets up (y up
/// from the bottom of a frame `h` tall): in its line box (`lb`), the
/// baseline half the leading under the top plus the ascent, as CSS and
/// WebKit place it (gtk.zig and win32.zig do the same), the glyphs
/// overflowing a line box shorter than the font. Without one, CoreText's.
fn lineOrigin(frame: CTFrameRef, i: c_long, h: CGFloat, lb: ?LineBox) CGPoint {
    var o: [1]CGPoint = undefined;
    CTFrameGetLineOrigins(frame, .{ .location = i, .length = 1 }, &o);
    const box = lb orelse return o[0];
    const top = @as(CGFloat, @floatFromInt(i)) * box.h + (box.h - (box.m.ascent + box.m.descent)) / 2;
    return .{ .x = o[0].x, .y = h - (top + box.m.ascent) };
}

/// A run's background (an inline highlight, a <code> amid the text): a box
/// under its glyphs on each line it spans, as a browser paints an inline
/// box's background. CoreText draws no backgrounds; the frame's lines give
/// the positions (in the flipped CoreText space paintText set up).
fn paintRunBackgrounds(cg: CGContextRef, frame: CTFrameRef, h: CGFloat, lb: ?LineBox, n: *Node) void {
    const runs = n.props.runs orelse return;
    var any = false;
    for (runs) |r| if (r.bg != null) {
        any = true;
        break;
    };
    if (!any) return;
    const lines = CTFrameGetLines(frame);
    const count = CFArrayGetCount(lines);
    if (count <= 0) return;
    var origins_buf: [256]CGPoint = undefined;
    const shown: usize = @intCast(@min(count, origins_buf.len));
    for (0..shown) |i| origins_buf[i] = lineOrigin(frame, @intCast(i), h, lb);
    // Each run's range in the string (UTF-16 units), as attributed() built it.
    var start: c_long = 0;
    for (runs) |r| {
        if (r.t.len == 0) continue;
        const str = CFStringCreateWithBytes(null, r.t.ptr, @intCast(r.t.len), kCFStringEncodingUTF8, 0) orelse continue;
        const len = CFStringGetLength(str);
        CFRelease(str);
        defer start += len;
        const bg = r.bg orelse continue;
        if (bg[3] <= 0) continue;
        // The block's own background on its own text (render.js gives a run
        // its element's background): the box already has it, and over a
        // line box shorter than the glyphs it would spill outside it.
        if (n.props.bg) |own| if (own.color) |oc| if (std.mem.eql(f32, &oc, &bg)) continue;
        setFill(cg, bg);
        const end = start + len;
        for (0..shown) |i| {
            const line = CFArrayGetValueAtIndex(lines, @intCast(i));
            const lr = CTLineGetStringRange(line);
            if (@max(start, lr.location) >= @min(end, lr.location + lr.length)) continue;
            const width = CTLineGetTypographicBounds(line, null, null, null);
            // Not under the space a line wraps after (a browser paints none there).
            const text_end: CGFloat = @floatCast(width - CTLineGetTrailingWhitespaceWidth(line));
            const o = origins_buf[i];
            // Per glyph run (one font, one direction): a right-to-left run
            // amid left-to-right text has its own place on the line.
            const glyph_runs = CTLineGetGlyphRuns(line);
            var g: c_long = 0;
            while (g < CFArrayGetCount(glyph_runs)) : (g += 1) {
                const run = CFArrayGetValueAtIndex(glyph_runs, g);
                const sr = CTRunGetStringRange(run);
                const a = @max(start, sr.location);
                const b = @min(end, sr.location + sr.length);
                if (a >= b or CTRunGetGlyphCount(run) == 0) continue;
                var ascent: CGFloat = 0;
                var descent: CGFloat = 0;
                const run_w = CTRunGetTypographicBounds(run, .{ .location = 0, .length = 0 }, &ascent, &descent, null);
                var x0: CGFloat = undefined;
                var x1: CGFloat = undefined;
                if (a == sr.location and b == sr.location + sr.length) {
                    var first: [1]CGPoint = undefined;
                    CTRunGetPositions(run, .{ .location = 0, .length = 1 }, &first);
                    x0 = first[0].x;
                    x1 = x0 + @as(CGFloat, @floatCast(run_w));
                } else {
                    const xa = CTLineGetOffsetForStringIndex(line, a, null);
                    const xb = CTLineGetOffsetForStringIndex(line, b, null);
                    x0 = @min(xa, xb);
                    x1 = @max(xa, xb);
                }
                x1 = @min(x1, text_end);
                if (x1 <= x0) continue;
                CGContextFillRect(cg, .{
                    .origin = .{ .x = o.x + x0, .y = o.y - descent },
                    .size = .{ .width = x1 - x0, .height = ascent + descent },
                });
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Fields

/// The part of a field the page shows: its content box within its clip,
/// minus what the page paints over it later (a fixed header or footer bar
/// across it), since native controls sit above everything drawn. Bars that
/// cover the field's whole width cut it from the top or the bottom.
/// <input type=range>: shared with the other backends (tree.zig).
pub const Range = tree_mod.Range;

pub fn visiblePart(tree: *tree_mod.Tree, field: *Node) Rect {
    var shown = field.clip.intersect(field.content());
    const root = tree.root orelse return shown;
    var after = false;
    cutBy(root, field, &after, &shown);
    return shown;
}

fn cutBy(n: *Node, field: *Node, after: *bool, shown: *Rect) void {
    if (n == field) {
        after.* = true;
        return; // its own children are inside it
    }
    if (n.props.vis == false) return;
    if (after.* and n.props.bg != null and shown.h > 0) {
        const cover = n.clip.intersect(n.frame);
        if (cover.x <= shown.x and cover.x + cover.w >= shown.x + shown.w and cover.h > 0) {
            const top = shown.y;
            const bottom = shown.y + shown.h;
            if (cover.y <= top and cover.y + cover.h > top) {
                // Over its top: what's left starts below the bar.
                const new_top = @min(bottom, cover.y + cover.h);
                shown.* = .{ .x = shown.x, .y = new_top, .w = shown.w, .h = bottom - new_top };
            } else if (cover.y < bottom and cover.y + cover.h >= bottom) {
                shown.* = .{ .x = shown.x, .y = top, .w = shown.w, .h = @max(0, cover.y - top) };
            }
        }
    }
    // In paint order: what paints after the field covers it.
    var it: tree_mod.PaintIter = .{ .kids = n.kids.items };
    while (it.next()) |k| cutBy(k, field, after, shown);
}

// ---------------------------------------------------------------------------
// Drawing

/// Whether a text area's control is empty (its placeholder shows): the
/// backend knows, from its UITextView / NSTextView.
pub const Fields = struct {
    ctx: *anyopaque,
    empty: *const fn (ctx: *anyopaque, n: *Node) bool,
};

/// Draw the engine's tree into `cg` (top-left origin). `transparent`:
/// nothing under the page (a transparent window); else white, as in a browser.
/// `scale`: the display's backing scale (a canvas's bitmap is that many
/// pixels per point).
pub fn paint(comptime font_class: [:0]const u8, cg: CGContextRef, engine: *Engine, transparent: bool, fields: Fields, scale: f64) void {
    const tree = &engine.tree;
    if (tree.needsLayout()) tree.layout();
    const all: CGRect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = tree.width, .height = tree.height } };
    if (transparent) {
        CGContextClearRect(cg, all);
    } else {
        setFillRGBA(cg, 1, 1, 1, 1);
        CGContextFillRect(cg, all);
    }
    const root = tree.root orelse return;
    paintNode(font_class, cg, engine, fields, scale, root);
}

fn paintNode(comptime font_class: [:0]const u8, cg: CGContextRef, engine: *Engine, fields: Fields, scale: f64, n: *Node) void {
    // Nothing of it on screen (absolutely placed children may still be).
    const p = n.props;
    if (p.vis == false) return;
    const f = n.frame;
    const visible = n.clip.intersect(.{ .x = f.x - 40, .y = f.y - 40, .w = f.w + 80, .h = f.h + 80 });
    if ((visible.w <= 0 or visible.h <= 0) and n.kids.items.len == 0) return;
    CGContextSaveGState(cg);
    defer CGContextRestoreGState(cg);
    CGContextClipToRect(cg, rect(n.clip));
    // scale and rotate: around the box's center, for it and its children.
    const sc = p.sc orelse 1;
    const rot = p.rot orelse 0;
    if (sc != 1 or rot != 0) {
        const cx = f.x + f.w / 2;
        const cy = f.y + f.h / 2;
        CGContextTranslateCTM(cg, cx, cy);
        if (rot != 0) CGContextRotateCTM(cg, rot * std.math.pi / 180.0);
        if (sc != 1) CGContextScaleCTM(cg, sc, sc);
        CGContextTranslateCTM(cg, -cx, -cy);
    }
    const alpha = p.op orelse 1;
    if (alpha < 1) {
        CGContextSetAlpha(cg, alpha);
        CGContextBeginTransparencyLayer(cg, null);
    }
    defer if (alpha < 1) CGContextEndTransparencyLayer(cg);

    const r = n.radiusXY();
    if (p.sh) |sh| shadow(cg, f, r, sh);
    if (p.bg) |bg| {
        // The color under the gradient (CSS layers).
        if (bg.color) |col| {
            roundRect(cg, f, r);
            setFill(cg, col);
            CGContextFillPath(cg);
        }
        if (bg.gradient) |g| gradient(cg, f, r, g);
    }
    if (p.bw) |bw| border(cg, f, r, bw, p.bc, p.bs);
    switch (n.kind) {
        .text => paintText(font_class, cg, n),
        .icon => paintIcon(cg, n),
        .image => paintImage(cg, engine, n),
        .textarea => if (fields.empty(fields.ctx, n)) paintPlaceholder(font_class, cg, n),
        .view => if (p.ctl != null) paintControl(cg, n),
        .canvas => paintCanvas(font_class, cg, scale, n),
        else => {},
    }
    // A box that clips its content (overflow hidden, or a scroller) with
    // rounded corners: the children are clipped to its rounded padding box
    // (only them: its own border and background are already drawn).
    const round_clip = n.roundClips();
    if (round_clip) {
        CGContextSaveGState(cg);
        const pb = n.paddingClipXY();
        roundRect(cg, pb.rect, pb.radii);
        CGContextClip(cg);
    }
    // CSS paint order: positioned boxes (a sticky header) over the flow.
    var it: tree_mod.PaintIter = .{ .kids = n.kids.items };
    while (it.next()) |k| paintNode(font_class, cg, engine, fields, scale, k);
    if (round_clip) CGContextRestoreGState(cg);
    // Over the box and its children, outside its own clip.
    if (p.ol) |ol| paintOutline(cg, f, r, ol);
}

/// CSS outline: a border of its own around the box grown by offset +
/// width, its corners the box's radius grown as much (square ones stay
/// square), solid, dashed or dotted (as gtk.zig's).
fn paintOutline(cg: CGContextRef, f: Rect, r: Radii, ol: tree_mod.Outline) void {
    if (!(ol.w > 0) or !(ol.c[3] > 0)) return;
    const grow = ol.o + ol.w;
    const box: Rect = .{ .x = f.x - grow, .y = f.y - grow, .w = f.w + 2 * grow, .h = f.h + 2 * grow };
    if (box.w <= 2 * ol.w or box.h <= 2 * ol.w) return;
    var radii = r.grown(grow);
    for (&radii.x) |*x| x.* = @max(x.*, ol.r);
    for (&radii.y) |*y| y.* = @max(y.*, ol.r);
    CGContextSaveGState(cg);
    defer CGContextRestoreGState(cg);
    // A focus ring's halo: 1px around it, its corners 1px rounder.
    if (ol.h) |h| if (h[3] > 0) {
        const halo: Rect = .{ .x = box.x - 1, .y = box.y - 1, .w = box.w + 2, .h = box.h + 2 };
        border(cg, halo, radii.grown(1), .{ 1, 1, 1, 1 }, .{ h, h, h, h }, null);
    };
    if (ol.s == null) {
        // Solid: the ring between the outer edge and the inner one, so a
        // corner rounder outside than the width (a focus ring's) stays round.
        const inner: Rect = .{ .x = box.x + ol.w, .y = box.y + ol.w, .w = box.w - 2 * ol.w, .h = box.h - 2 * ol.w };
        roundRect(cg, box, radii);
        addRoundRect(cg, inner, radii.grown(-ol.w));
        setFill(cg, ol.c);
        CGContextEOFillPath(cg);
        return;
    }
    border(cg, box, radii, .{ ol.w, ol.w, ol.w, ol.w }, .{ ol.c, ol.c, ol.c, ol.c }, ol.s);
}

/// CSS colors are sRGB (as WebKit draws them, matched to the display):
/// every fill, stroke, gradient, text color and canvas bitmap is in this
/// space, not the device's (whose values would go to the display as they
/// are). Created once, kept.
var srgb_space: ?CGColorSpaceRef = null;

fn srgb() ?CGColorSpaceRef {
    if (srgb_space == null) srgb_space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB) orelse CGColorSpaceCreateDeviceRGB();
    return srgb_space;
}

fn setFillRGBA(cg: CGContextRef, r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) void {
    const space = srgb() orelse return CGContextSetRGBFillColor(cg, r, g, b, a);
    const comps = [4]CGFloat{ r, g, b, a };
    CGContextSetFillColorSpace(cg, space);
    CGContextSetFillColor(cg, &comps);
}

fn setStrokeRGBA(cg: CGContextRef, r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) void {
    const space = srgb() orelse return CGContextSetRGBStrokeColor(cg, r, g, b, a);
    const comps = [4]CGFloat{ r, g, b, a };
    CGContextSetStrokeColorSpace(cg, space);
    CGContextSetStrokeColor(cg, &comps);
}

fn setFill(cg: CGContextRef, c: tree_mod.Color) void {
    setFillRGBA(cg, c[0] / 255, c[1] / 255, c[2] / 255, c[3]);
}

fn setStroke(cg: CGContextRef, c: tree_mod.Color) void {
    setStrokeRGBA(cg, c[0] / 255, c[1] / 255, c[2] / 255, c[3]);
}

/// A rectangle with per-corner radii (top-left, top-right, bottom-right,
/// bottom-left) as the current path.
fn roundRect(cg: CGContextRef, f: Rect, r: Radii) void {
    CGContextBeginPath(cg);
    addRoundRect(cg, f, r);
}

/// roundRect's shape added to the current path.
fn addRoundRect(cg: CGContextRef, f: Rect, r: Radii) void {
    if (r.square()) return CGContextAddRect(cg, rect(f));
    addEllipseRect(cg, f, r.x, r.y);
}

fn gradient(cg: CGContextRef, f: Rect, r: Radii, g: tree_mod.Gradient) void {
    if (g.stops.len == 0) return;
    const space = srgb() orelse return;
    var comps: [64 * 4]CGFloat = undefined;
    var locs: [64]CGFloat = undefined;
    const count = @min(g.stops.len, locs.len);
    for (g.stops[0..count], 0..) |st, i| {
        comps[i * 4 + 0] = st[0] / 255;
        comps[i * 4 + 1] = st[1] / 255;
        comps[i * 4 + 2] = st[2] / 255;
        comps[i * 4 + 3] = st[3];
        locs[i] = std.math.clamp(st[4], 0, 1);
    }
    const grad = CGGradientCreateWithColorComponents(space, &comps, &locs, count) orelse return;
    defer CGGradientRelease(grad);
    CGContextSaveGState(cg);
    defer CGContextRestoreGState(cg);
    roundRect(cg, f, r);
    CGContextClip(cg);
    if (g.radialIn(f.w, f.h)) |rad| {
        // A unit circle at the origin, stretched onto the ellipse.
        CGContextTranslateCTM(cg, f.x + rad[0], f.y + rad[1]);
        CGContextScaleCTM(cg, rad[2], rad[3]);
        CGContextDrawRadialGradient(cg, grad, .{ .x = 0, .y = 0 }, 0, .{ .x = 0, .y = 0 }, 1, kCGGradientDrawsBeforeAndAfter);
        return;
    }
    // The CSS gradient line: through the center at `angle` (0 = up), long
    // enough for the corners to get the end colors.
    const a = g.angle * std.math.pi / 180.0;
    const dx = @sin(a);
    const dy = -@cos(a);
    const len = @abs(f.w * dx) + @abs(f.h * dy);
    const cx = f.x + f.w / 2;
    const cy = f.y + f.h / 2;
    CGContextDrawLinearGradient(cg, grad, .{ .x = cx - dx * len / 2, .y = cy - dy * len / 2 }, .{ .x = cx + dx * len / 2, .y = cy + dy * len / 2 }, kCGGradientDrawsBeforeAndAfter);
}

/// A dashed or dotted stroke `w` wide, as Chromium draws a rounded one:
/// dashes 3 widths long with 3-width gaps, square dots a width apart for
/// thin borders, round ones from 3 px.
fn setBorderDash(cg: CGContextRef, bs: ?tree_mod.BorderStyle, w: f32) void {
    const style = bs orelse return;
    const d: CGFloat = w;
    const dashes: [2]CGFloat = switch (style) {
        .dashed => .{ 3 * d, 3 * d },
        .dotted => if (w < 3) .{ d, d } else .{ 0, 2 * d },
    };
    CGContextSetLineCap(cg, if (style == .dotted and w >= 3) 1 else 0);
    CGContextSetLineDash(cg, 0, &dashes, dashes.len);
}

/// One straight side dashed or dotted as Chromium draws it: a dash (3
/// widths; a dot: 1) at each end and whole ones between, the gaps
/// stretched to fit. Dots from 3 px are round.
fn dashedSide(cg: CGContextRef, sd: Rect, across: bool, w: f32, style: tree_mod.BorderStyle) void {
    const len = if (across) sd.w else sd.h;
    if (len <= 0 or w <= 0) return;
    const dash = if (style == .dashed) 3 * w else w;
    const n = @max(1, @round((len + dash) / (2 * dash)));
    const gap = if (n > 1) (len - n * dash) / (n - 1) else 0;
    var k: f32 = 0;
    while (k < n) : (k += 1) {
        const at = k * (dash + gap);
        const d = if (n == 1) len else dash;
        const rc: Rect = if (across) .{ .x = sd.x + at, .y = sd.y, .w = d, .h = sd.h } else .{ .x = sd.x, .y = sd.y + at, .w = sd.w, .h = d };
        if (style == .dotted and w >= 3) {
            CGContextFillEllipseInRect(cg, rect(.{ .x = rc.x + rc.w / 2 - w / 2, .y = rc.y + rc.h / 2 - w / 2, .w = w, .h = w }));
        } else CGContextFillRect(cg, rect(rc));
    }
}

fn border(cg: CGContextRef, f: Rect, r: Radii, bw: [4]f32, bc: ?[4]tree_mod.Color, bs: ?tree_mod.BorderStyle) void {
    const colors = bc orelse return;
    const uniform = bw[0] == bw[1] and bw[1] == bw[2] and bw[2] == bw[3];
    // Square corners, dashed or dotted: each side's dashes fitted to it
    // (the per-side path below); one pattern around the rectangle would
    // leave a side a stray dash.
    const square = r.square();
    // Rounded and solid: the ring between the border box and the padding
    // box, filled (as WebKit draws it; a stroke along the middle notches
    // where two quarter ellipses meet), each color in its wedge.
    if (!square and bs == null) return roundedSides(cg, f, r, bw, colors);
    if (uniform and bw[0] > 0 and !(bs != null and square)) {
        const half = bw[0] / 2;
        const inner: Rect = .{ .x = f.x + half, .y = f.y + half, .w = f.w - bw[0], .h = f.h - bw[0] };
        const ri = r.grown(-half);
        CGContextSaveGState(cg);
        defer CGContextRestoreGState(cg);
        CGContextSetLineWidth(cg, bw[0]);
        setBorderDash(cg, bs, bw[0]);
        const same = for (colors[1..]) |c| {
            if (!std.mem.eql(f32, &c, &colors[0])) break false;
        } else true;
        if (same) {
            roundRect(cg, inner, ri);
            setStroke(cg, colors[0]);
            CGContextStrokePath(cg);
            return;
        }
        // Sides in different colors (a spinner: border-top-color on a grey
        // ring): the rounded border stroked once per side, clipped to that
        // side's wedge (its two corners and the box's center), so the
        // colors meet on the diagonals, as in CSS.
        const cx = f.x + f.w / 2;
        const cy = f.y + f.h / 2;
        const corners = [4][2]f32{ .{ f.x, f.y }, .{ f.x + f.w, f.y }, .{ f.x + f.w, f.y + f.h }, .{ f.x, f.y + f.h } };
        for (0..4) |i| {
            if (colors[i][3] <= 0) continue;
            const a0 = corners[i];
            const a1 = corners[(i + 1) % 4];
            CGContextSaveGState(cg);
            defer CGContextRestoreGState(cg);
            CGContextBeginPath(cg);
            CGContextMoveToPoint(cg, a0[0], a0[1]);
            CGContextAddLineToPoint(cg, a1[0], a1[1]);
            CGContextAddLineToPoint(cg, cx, cy);
            CGContextClosePath(cg);
            CGContextClip(cg);
            roundRect(cg, inner, ri);
            setStroke(cg, colors[i]);
            CGContextStrokePath(cg);
        }
        return;
    }
    // Per side (straight edges).
    const sides = [4]Rect{
        .{ .x = f.x, .y = f.y, .w = f.w, .h = bw[0] },
        .{ .x = f.x + f.w - bw[1], .y = f.y, .w = bw[1], .h = f.h },
        .{ .x = f.x, .y = f.y + f.h - bw[2], .w = f.w, .h = bw[2] },
        .{ .x = f.x, .y = f.y, .w = bw[3], .h = f.h },
    };
    for (sides, 0..) |sd, i| {
        if (bw[i] <= 0 or colors[i][3] <= 0) continue;
        setFill(cg, colors[i]);
        if (bs) |style| dashedSide(cg, sd, i == 0 or i == 2, bw[i], style) else CGContextFillRect(cg, rect(sd));
    }
}

/// A rounded border whose sides differ in width (border-radius: 12px with
/// border-left: 6px), as gtk.zig's roundedSides and browsers draw it: the
/// area between the border box and the padding box, whose corners are
/// ellipses (the radius less each side's width, as CSS makes them), each
/// side's color clipped to its wedge: the lines from its outer corners
/// through its inner corners (where browsers join two colors), up to the
/// middle.
fn roundedSides(cg: CGContextRef, f: Rect, radii: Radii, bw: [4]f32, colors: [4]tree_mod.Color) void {
    const pb = tree_mod.paddingBoxXY(f, radii, bw);
    const inner = pb.rect;
    // One color where every drawn side has the same: one fill.
    var first: ?tree_mod.Color = null;
    const same = for (0..4) |i| {
        if (bw[i] <= 0) continue;
        if (first) |c| {
            if (!std.mem.eql(f32, &c, &colors[i])) break false;
        } else first = colors[i];
    } else true;
    const outer = [4][2]f32{ .{ f.x, f.y }, .{ f.x + f.w, f.y }, .{ f.x + f.w, f.y + f.h }, .{ f.x, f.y + f.h } };
    const in = [4][2]f32{ .{ inner.x, inner.y }, .{ inner.x + inner.w, inner.y }, .{ inner.x + inner.w, inner.y + inner.h }, .{ inner.x, inner.y + inner.h } };
    const mid = [2]f32{ inner.x + inner.w / 2, inner.y + inner.h / 2 };
    // Each corner's join, from the outer corner through the inner one,
    // stopped where it reaches the middle's row or column.
    var join: [4][2]f32 = undefined;
    for (0..4) |k| {
        const dx = in[k][0] - outer[k][0];
        const dy = in[k][1] - outer[k][1];
        var t: f32 = std.math.floatMax(f32);
        if (dx != 0) t = @min(t, (mid[0] - outer[k][0]) / dx);
        if (dy != 0) t = @min(t, (mid[1] - outer[k][1]) / dy);
        if (dx == 0 and dy == 0) t = 0;
        join[k] = .{ outer[k][0] + @max(0, t) * dx, outer[k][1] + @max(0, t) * dy };
    }
    // Neighboring sides of one color share one wedge (no seam where two
    // clips would meet): a run of them starts after a side of another color.
    const sameAs = struct {
        fn eq(c: [4]tree_mod.Color, w: [4]f32, a: usize, b: usize) bool {
            return w[a] > 0 and w[b] > 0 and std.mem.eql(f32, &c[a], &c[b]);
        }
    }.eq;
    for (0..4) |i| {
        if (bw[i] <= 0 or colors[i][3] <= 0) continue;
        if (!same and sameAs(colors, bw, i, (i + 3) % 4)) continue; // in the run before it
        CGContextSaveGState(cg);
        defer CGContextRestoreGState(cg);
        if (!same) {
            CGContextBeginPath(cg);
            CGContextMoveToPoint(cg, outer[i][0], outer[i][1]);
            var last = i;
            while (sameAs(colors, bw, last, (last + 1) % 4) and (last + 1) % 4 != i) {
                last = (last + 1) % 4;
                CGContextAddLineToPoint(cg, outer[last][0], outer[last][1]);
            }
            const j = (last + 1) % 4;
            CGContextAddLineToPoint(cg, outer[j][0], outer[j][1]);
            CGContextAddLineToPoint(cg, join[j][0], join[j][1]);
            CGContextAddLineToPoint(cg, mid[0], mid[1]);
            CGContextAddLineToPoint(cg, join[i][0], join[i][1]);
            CGContextClosePath(cg);
            CGContextClip(cg);
        }
        CGContextBeginPath(cg);
        addEllipseRect(cg, f, radii.x, radii.y);
        addEllipseRect(cg, inner, pb.radii.x, pb.radii.y);
        setFill(cg, colors[i]);
        CGContextEOFillPath(cg); // even-odd: the ring
        if (same) return;
    }
}

/// A rectangle with elliptical corners (`rx`, `ry` each: top left, top
/// right, bottom right, bottom left), added to the current path; a corner
/// without a radius along either axis is square.
fn addEllipseRect(cg: CGContextRef, f: Rect, rx: [4]f32, ry: [4]f32) void {
    // A quarter ellipse as one cubic (the circle's constant).
    const k: f32 = 0.5522847;
    var ax: [4]f32 = undefined;
    var ay: [4]f32 = undefined;
    for (0..4) |i| {
        const round = rx[i] > 0 and ry[i] > 0;
        ax[i] = if (round) rx[i] else 0;
        ay[i] = if (round) ry[i] else 0;
    }
    const x = f.x;
    const y = f.y;
    const w = f.w;
    const h = f.h;
    // (No line where two corners meet: a zero-length one would show as a
    // dot where a stroke joins it.)
    CGContextMoveToPoint(cg, x + ax[0], y);
    if (x + ax[0] < x + w - ax[1]) CGContextAddLineToPoint(cg, x + w - ax[1], y);
    if (ax[1] > 0) CGContextAddCurveToPoint(cg, x + w - ax[1] + k * ax[1], y, x + w, y + ay[1] - k * ay[1], x + w, y + ay[1]);
    if (y + ay[1] < y + h - ay[2]) CGContextAddLineToPoint(cg, x + w, y + h - ay[2]);
    if (ax[2] > 0) CGContextAddCurveToPoint(cg, x + w, y + h - ay[2] + k * ay[2], x + w - ax[2] + k * ax[2], y + h, x + w - ax[2], y + h);
    if (x + ax[3] < x + w - ax[2]) CGContextAddLineToPoint(cg, x + ax[3], y + h);
    if (ax[3] > 0) CGContextAddCurveToPoint(cg, x + ax[3] - k * ax[3], y + h, x, y + h - ay[3] + k * ay[3], x, y + h - ay[3]);
    if (y + ay[0] < y + h - ay[3]) CGContextAddLineToPoint(cg, x, y + ay[0]);
    if (ax[0] > 0) CGContextAddCurveToPoint(cg, x, y + ay[0] - k * ay[0], x + ax[0] - k * ax[0], y, x + ax[0], y);
    CGContextClosePath(cg);
}

fn shadow(cg: CGContextRef, f: Rect, r: Radii, sh: tree_mod.Shadow) void {
    // As on GTK: stacked layers from half the blur inside the box to half
    // outside, so the edge gets half the color and it fades over the blur.
    // No blur: one layer, the whole color (stacked ones would all fall on
    // the same edge and add up to less).
    const steps: usize = if (sh.blur > 0) 8 else 1;
    var i: usize = 0;
    while (i < steps) : (i += 1) {
        const t: f32 = (@as(f32, @floatFromInt(i)) + 0.5) / @as(f32, @floatFromInt(steps));
        const grow = sh.spread + sh.blur * (t - 0.5);
        const box: Rect = .{ .x = f.x + sh.x - grow, .y = f.y + sh.y - grow, .w = f.w + 2 * grow, .h = f.h + 2 * grow };
        if (box.w <= 0 or box.h <= 0) continue;
        var rr = r;
        for (&rr.x) |*x| x.* = @max(0, x.* + grow);
        for (&rr.y) |*y| y.* = @max(0, y.* + grow);
        roundRect(cg, box, rr);
        var c = sh.color;
        c[3] = sh.color[3] / @as(f32, @floatFromInt(steps));
        setFill(cg, c);
        CGContextFillPath(cg);
    }
}

const PathSink = svg_path.Sink(CGContextRef);

fn pMove(cg: CGContextRef, x: f64, y: f64) void {
    CGContextMoveToPoint(cg, x, y);
}
fn pLine(cg: CGContextRef, x: f64, y: f64) void {
    CGContextAddLineToPoint(cg, x, y);
}
fn pCubic(cg: CGContextRef, a: f64, b: f64, c: f64, d: f64, e: f64, f: f64) void {
    CGContextAddCurveToPoint(cg, a, b, c, d, e, f);
}
fn pQuad(cg: CGContextRef, a: f64, b: f64, c: f64, d: f64) void {
    CGContextAddQuadCurveToPoint(cg, a, b, c, d);
}
fn pClose(cg: CGContextRef) void {
    CGContextClosePath(cg);
}

fn paintIcon(cg: CGContextRef, n: *const Node) void {
    const icon = n.props.icon orelse return;
    const c = n.content();
    if (c.w <= 0 or c.h <= 0 or icon.vb[2] <= 0 or icon.vb[3] <= 0) return;
    const scale = @min(c.w / icon.vb[2], c.h / icon.vb[3]);
    CGContextSaveGState(cg);
    defer CGContextRestoreGState(cg);
    CGContextTranslateCTM(cg, c.x + (c.w - icon.vb[2] * scale) / 2, c.y + (c.h - icon.vb[3] * scale) / 2);
    CGContextScaleCTM(cg, scale, scale);
    CGContextTranslateCTM(cg, -icon.vb[0], -icon.vb[1]);
    const sink: PathSink = .{ .ctx = cg, .move = pMove, .line = pLine, .cubic = pCubic, .quad = pQuad, .close = pClose };
    for (icon.shapes) |sh| {
        if (sh.fill == null and sh.stroke == null) continue;
        CGContextBeginPath(cg);
        _ = svg_path.parse(CGContextRef, sh.d, sink);
        if (sh.fill) |fill| setFill(cg, fill);
        if (sh.stroke) |stroke| {
            setStroke(cg, stroke);
            CGContextSetLineWidth(cg, sh.sw);
            CGContextSetLineCap(cg, if (std.mem.eql(u8, sh.cap, "round")) 1 else if (std.mem.eql(u8, sh.cap, "square")) 2 else 0);
            CGContextSetLineJoin(cg, if (std.mem.eql(u8, sh.join, "round")) 1 else if (std.mem.eql(u8, sh.join, "bevel")) 2 else 0);
        }
        const mode: c_int = if (sh.fill != null and sh.stroke != null)
            (if (sh.evenodd) kCGPathEOFillStroke else kCGPathFillStroke)
        else if (sh.fill != null)
            (if (sh.evenodd) kCGPathEOFill else kCGPathFill)
        else
            2; // kCGPathStroke
        CGContextDrawPath(cg, mode);
    }
}

test {
    _ = svg_path;
}

// ---------------------------------------------------------------------------
// Default checkbox and radio, a text area's placeholder

/// A default checkbox or radio (`ctl`): an outlined box or circle, filled
/// with the accent color (`acc`, else blue) and a white mark when checked
/// (`on`); dimmed when disabled. As on GTK.
fn paintControl(cg: CGContextRef, n: *const Node) void {
    const c = n.frame;
    const size = @min(c.w, c.h);
    if (!(size > 0)) return; // NaN too
    const x = c.x + (c.w - size) / 2;
    const y = c.y + (c.h - size) / 2;
    const radio = std.mem.eql(u8, n.props.ctl.?, "radio");
    const acc = n.props.acc orelse tree_mod.Color{ 59, 108, 255, 1 };
    const alpha: f32 = if (n.props.dis) 0.45 else 1;
    CGContextSaveGState(cg);
    defer CGContextRestoreGState(cg);
    const outline = struct {
        fn f(g: CGContextRef, is_radio: bool, ox: f32, oy: f32, sz: f32) void {
            CGContextBeginPath(g);
            if (is_radio) {
                CGContextAddArc(g, ox + sz / 2, oy + sz / 2, sz / 2 - 0.5, 0, 2 * std.math.pi, 0);
                CGContextClosePath(g);
            } else roundRect(g, .{ .x = ox + 0.5, .y = oy + 0.5, .w = sz - 1, .h = sz - 1 }, Radii.circle(.{ 2.5, 2.5, 2.5, 2.5 }));
        }
    }.f;
    outline(cg, radio, x, y, size);
    if (n.props.on) {
        setFill(cg, .{ acc[0], acc[1], acc[2], acc[3] * alpha });
        CGContextFillPath(cg);
        if (radio) {
            CGContextBeginPath(cg);
            CGContextAddArc(cg, x + size / 2, y + size / 2, size * 0.2, 0, 2 * std.math.pi, 0);
            setFill(cg, .{ 255, 255, 255, alpha });
            CGContextFillPath(cg);
        } else {
            setStroke(cg, .{ 255, 255, 255, alpha });
            CGContextSetLineWidth(cg, @max(1.5, size * 0.13));
            CGContextSetLineCap(cg, 1);
            CGContextSetLineJoin(cg, 1);
            CGContextBeginPath(cg);
            CGContextMoveToPoint(cg, x + size * 0.25, y + size * 0.52);
            CGContextAddLineToPoint(cg, x + size * 0.43, y + size * 0.7);
            CGContextAddLineToPoint(cg, x + size * 0.76, y + size * 0.32);
            CGContextStrokePath(cg);
        }
    } else {
        setFill(cg, .{ 255, 255, 255, alpha });
        setStroke(cg, .{ 118, 118, 118, alpha });
        CGContextSetLineWidth(cg, 1);
        CGContextDrawPath(cg, kCGPathFillStroke);
    }
}

/// A <textarea>'s placeholder: NSTextView and UITextView have none, so it's
/// drawn under the (transparent) control while it's empty, in the text color
/// at half strength, as a browser does.
fn paintPlaceholder(comptime font_class: [:0]const u8, cg: CGContextRef, n: *const Node) void {
    const ph = n.props.ph orelse return;
    if (ph.len == 0) return;
    const c = n.content();
    if (!(c.w > 0) or !(c.h > 0)) return; // NaN too
    const s = CFAttributedStringCreateMutable(null, 0) orelse return;
    defer CFRelease(s);
    const str = CFStringCreateWithBytes(null, ph.ptr, @intCast(ph.len), kCFStringEncodingUTF8, 0) orelse return;
    defer CFRelease(str);
    CFAttributedStringReplaceString(s, .{ .location = 0, .length = 0 }, str);
    const all: CFRange = .{ .location = 0, .length = CFStringGetLength(str) };
    if (font(font_class, n.props.fz orelse 16, 400, false, n.props.mono, n.props.ff)) |f| CFAttributedStringSetAttribute(s, all, kCTFontAttributeName, f);
    const col = n.props.col orelse tree_mod.Color{ 0, 0, 0, 1 };
    const space = srgb() orelse return;
    const comps = [4]CGFloat{ col[0] / 255, col[1] / 255, col[2] / 255, col[3] * 0.5 };
    if (CGColorCreate(space, &comps)) |cc| {
        CFAttributedStringSetAttribute(s, all, kCTForegroundColorAttributeName, cc);
        CGColorRelease(cc);
    }
    const fs = CTFramesetterCreateWithAttributedString(s) orelse return;
    defer CFRelease(fs);
    const path = CGPathCreateWithRect(.{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = c.w, .height = c.h } }, null) orelse return;
    defer CGPathRelease(path);
    const frame = CTFramesetterCreateFrame(fs, .{ .location = 0, .length = 0 }, path, null) orelse return;
    defer CFRelease(frame);
    CGContextSaveGState(cg);
    defer CGContextRestoreGState(cg);
    CGContextClipToRect(cg, rect(c));
    CGContextTranslateCTM(cg, c.x, c.y + c.h);
    CGContextScaleCTM(cg, 1, -1);
    CGContextSetTextMatrix(cg, .{ .a = 1, .b = 0, .c = 0, .d = 1, .tx = 0, .ty = 0 });
    CTFrameDraw(frame, cg);
}

// ---------------------------------------------------------------------------
// Images (<img src="data:…"> or an app asset), decoded with ImageIO

/// An image node's picture, kept in `Node.native` until its `src` changes
/// (not on every props update: a transition would decode it every frame).
const ImageCache = struct {
    src_hash: u64,
    /// The `src` slice last hashed: the same one isn't hashed again (a big
    /// data: URI is megabytes, and measure and paint ask every frame).
    src_ptr: usize = 0,
    src_len: usize = 0,
    /// Null when the picture couldn't be decoded, or is over the limit.
    image: ?CGImageRef,
    w: f32,
    h: f32,
};

/// The largest picture decoded: 4096 x 4096 px declared. Larger ones keep
/// their declared size for layout and aren't drawn, as on GTK: a tiny file
/// can declare 30000 x 30000 px.
const max_image_pixels: u64 = 4096 * 4096;
/// What's kept decoded is at most this many px on its longer side (16 MB
/// as 8-bit RGBA, whatever the file's depth), so a page of big pictures
/// doesn't hold gigabytes.
const max_decoded_side: i64 = 2048;

fn dropImage(n: *Node) void {
    const p = n.native orelse return;
    n.native = null;
    const c: *ImageCache = @ptrCast(@alignCast(p));
    if (c.image) |img| CGImageRelease(img);
    std.heap.smp_allocator.destroy(c);
}

/// New props: the next look at the picture compares `src` by its contents
/// once. The props arena is reused, so a new `src` of the same length can
/// land at the old one's address ("assets/on.png" -> "assets/no.png"), and
/// the pointer alone would keep the old picture.
pub fn imagePropsChanged(n: *Node) void {
    if (n.kind != .image) return;
    const p = n.native orelse return;
    const c: *ImageCache = @ptrCast(@alignCast(p));
    c.src_ptr = 0;
    c.src_len = 0;
}

fn imageOf(engine: *Engine, n: *Node) ?*ImageCache {
    const src = n.props.src orelse {
        dropImage(n); // no src any more: no picture
        return null;
    };
    var hash: ?u64 = null;
    if (n.native) |p| {
        const c: *ImageCache = @ptrCast(@alignCast(p));
        if (c.src_ptr == @intFromPtr(src.ptr) and c.src_len == src.len) return c;
        hash = std.hash.Wyhash.hash(src.len, src);
        if (c.src_hash == hash.?) {
            c.src_ptr = @intFromPtr(src.ptr);
            c.src_len = src.len;
            return c;
        }
        dropImage(n);
    }
    const c = std.heap.smp_allocator.create(ImageCache) catch return null;
    c.* = .{ .src_hash = hash orelse std.hash.Wyhash.hash(src.len, src), .src_ptr = @intFromPtr(src.ptr), .src_len = src.len, .image = null, .w = 0, .h = 0 };
    decodeImage(engine, src, c) catch |err| std.log.scoped(.native_ui).warn("native ui: image {s}: {s}", .{ src[0..@min(src.len, 48)], @errorName(err) });
    n.native = c;
    return c;
}

fn decodeImage(engine: *Engine, src: []const u8, out: *ImageCache) !void {
    const gpa = std.heap.smp_allocator;
    var owned: ?[]u8 = null;
    defer if (owned) |o| gpa.free(o);
    const bytes: []const u8 = if (std.mem.startsWith(u8, src, "data:")) blk: {
        const comma = std.mem.indexOfScalar(u8, src, ',') orelse return error.BadDataUri;
        if (std.mem.indexOf(u8, src[0..comma], ";base64") == null) return error.NotBase64;
        const b64 = std.mem.trim(u8, src[comma + 1 ..], " \t\r\n");
        const dec = std.base64.standard.Decoder;
        const buf = try gpa.alloc(u8, try dec.calcSizeForSlice(b64));
        owned = buf;
        try dec.decode(buf, b64);
        break :blk buf;
    } else engine.assetData(src) orelse return error.AssetNotFound;
    return decodeBytes(bytes, out, max_image_pixels);
}

/// Decode an image file's bytes into `out` (its declared size even when it
/// isn't decoded).
fn decodeBytes(bytes: []const u8, out: *ImageCache, limit: u64) !void {
    if (bytes.len == 0 or bytes.len > std.math.maxInt(c_long)) return error.EmptyImage;
    const data = CFDataCreate(null, bytes.ptr, @intCast(bytes.len)) orelse return error.OutOfMemory;
    defer CFRelease(data);
    const isrc = CGImageSourceCreateWithData(data, null) orelse return error.UnknownFormat;
    defer CFRelease(isrc);
    // The declared size first, from the header: nothing is decoded yet.
    const props = CGImageSourceCopyPropertiesAtIndex(isrc, 0, null) orelse return error.UnknownFormat;
    defer CFRelease(props);
    var w: i64 = 0;
    var h: i64 = 0;
    if (CFDictionaryGetValue(props, kCGImagePropertyPixelWidth)) |v| _ = CFNumberGetValue(v, kCFNumberSInt64Type, &w);
    if (CFDictionaryGetValue(props, kCGImagePropertyPixelHeight)) |v| _ = CFNumberGetValue(v, kCFNumberSInt64Type, &h);
    if (w <= 0 or h <= 0) return error.UnknownFormat;
    out.w = @floatFromInt(@min(w, 1 << 24));
    out.h = @floatFromInt(@min(h, 1 << 24));
    if (@as(u64, @intCast(w)) > limit or @as(u64, @intCast(h)) > limit or
        @as(u64, @intCast(w)) * @as(u64, @intCast(h)) > limit) return error.OverThePixelLimit;
    // Decoded at most max_decoded_side px on its longer side (a thumbnail:
    // ImageIO decodes straight to that size), upright per its orientation.
    const side = std.math.clamp(@max(w, h), 1, max_decoded_side);
    const side_num = CFNumberCreate(null, kCFNumberSInt64Type, &side) orelse return error.OutOfMemory;
    defer CFRelease(side_num);
    const keys = [_]?*const anyopaque{ kCGImageSourceCreateThumbnailFromImageAlways, kCGImageSourceCreateThumbnailWithTransform, kCGImageSourceThumbnailMaxPixelSize };
    const values = [_]?*const anyopaque{ kCFBooleanTrue, kCFBooleanTrue, side_num };
    const opts = CFDictionaryCreate(null, &keys, &values, keys.len, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) orelse return error.OutOfMemory;
    defer CFRelease(opts);
    out.image = CGImageSourceCreateThumbnailAtIndex(isrc, 0, opts) orelse return error.DecodeFailed;
}

/// An image's natural size, scaled down to the width it may take.
pub fn measureImage(engine: *Engine, n: *Node, max_width: f32) [2]f32 {
    const c = imageOf(engine, n) orelse return .{ 0, 0 };
    if (!(c.w > 0) or !(c.h > 0)) return .{ 0, 0 };
    const k: f32 = if (!std.math.isInf(max_width) and max_width < c.w) @max(0, max_width) / c.w else 1;
    return .{ c.w * k, c.h * k };
}

/// Drawn in its content box per CSS object-fit (fill by default).
fn paintImage(cg: CGContextRef, engine: *Engine, n: *Node) void {
    const c_img = imageOf(engine, n) orelse return;
    const img = c_img.image orelse return;
    const c = n.content();
    if (!(c.w > 0) or !(c.h > 0) or !(c_img.w > 0) or !(c_img.h > 0)) return; // NaN too
    const fit = n.props.fit orelse "fill";
    var kx: f32 = c.w / c_img.w;
    var ky: f32 = c.h / c_img.h;
    if (std.mem.eql(u8, fit, "contain")) {
        kx = @min(kx, ky);
        ky = kx;
    } else if (std.mem.eql(u8, fit, "cover")) {
        kx = @max(kx, ky);
        ky = kx;
    } else if (std.mem.eql(u8, fit, "none")) {
        kx = 1;
        ky = 1;
    } else if (std.mem.eql(u8, fit, "scale-down")) {
        kx = @min(1, @min(kx, ky));
        ky = kx;
    }
    const dw = c_img.w * kx;
    const dh = c_img.h * ky;
    CGContextSaveGState(cg);
    defer CGContextRestoreGState(cg);
    CGContextClipToRect(cg, rect(c));
    // CGContextDrawImage draws with y up: flip around the picture's box.
    CGContextTranslateCTM(cg, c.x + (c.w - dw) / 2, c.y + (c.h - dh) / 2 + dh);
    CGContextScaleCTM(cg, 1, -1);
    CGContextDrawImage(cg, .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = dw, .height = dh } }, img);
}

fn testPng(comptime w: u32, comptime h: u32, with_pixels: bool) ![]u8 {
    const gpa = std.testing.allocator;
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    if (with_pixels) for (0..h) |_| {
        try raw.append(gpa, 0);
        try raw.appendNTimes(gpa, 0x80, w * 4);
    };
    var z: std.ArrayList(u8) = .empty;
    defer z.deinit(gpa);
    // A stored (uncompressed) zlib stream: header, one final block, adler32.
    try z.appendSlice(gpa, &.{ 0x78, 0x01, 0x01 });
    const len: u16 = @intCast(raw.items.len);
    try z.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, len)));
    try z.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, ~len)));
    try z.appendSlice(gpa, raw.items);
    try z.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u32, std.hash.Adler32.hash(raw.items))));
    var png: std.ArrayList(u8) = .empty;
    errdefer png.deinit(gpa);
    try png.appendSlice(gpa, "\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8..13].* = .{ 8, 6, 0, 0, 0 };
    inline for (.{ .{ "IHDR", &ihdr }, .{ "IDAT", z.items }, .{ "IEND", "" } }) |c| {
        const data: []const u8 = c[1];
        try png.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(data.len))));
        var crc = std.hash.Crc32.init();
        crc.update(c[0]);
        crc.update(data);
        try png.appendSlice(gpa, c[0]);
        try png.appendSlice(gpa, data);
        try png.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u32, crc.final())));
    }
    return png.toOwnedSlice(gpa);
}

test "images: decoded, and over the pixel limit only measured" {
    const small = try testPng(4, 3, true);
    defer std.testing.allocator.free(small);
    var c: ImageCache = .{ .src_hash = 0, .image = null, .w = 0, .h = 0 };
    try decodeBytes(small, &c, max_image_pixels);
    defer if (c.image) |img| CGImageRelease(img);
    try std.testing.expect(c.image != null);
    try std.testing.expectEqual(@as(f32, 4), c.w);
    try std.testing.expectEqual(@as(f32, 3), c.h);
    // Over the limit (12 px against 10 here; 4096 x 4096 in the app): its
    // declared size from the header, for layout, and nothing decoded.
    var b: ImageCache = .{ .src_hash = 0, .image = null, .w = 0, .h = 0 };
    try std.testing.expectError(error.OverThePixelLimit, decodeBytes(small, &b, 10));
    try std.testing.expect(b.image == null);
    try std.testing.expectEqual(@as(f32, 4), b.w);
    // A header declaring 30000 x 30000 px with no picture behind it: ImageIO
    // gives it no size, so nothing is drawn (and nothing decoded).
    const huge = try testPng(30000, 30000, false);
    defer std.testing.allocator.free(huge);
    var j: ImageCache = .{ .src_hash = 0, .image = null, .w = 0, .h = 0 };
    try std.testing.expectError(error.UnknownFormat, decodeBytes(huge, &j, max_image_pixels));
    try std.testing.expect(j.image == null);
    // Not an image.
    try std.testing.expectError(error.UnknownFormat, decodeBytes("not a picture at all", &j, max_image_pixels));
}

// ---------------------------------------------------------------------------
// <canvas>: the recorded program (src/native_ui/js/src/canvas.js) replayed
// into the canvas's own bitmap, then drawn at its frame. Every paint replays
// the whole program from the context's defaults (docs/native-renderer.md).

/// A canvas node's bitmap, kept in `Node.native` from frame to frame while
/// its size holds (a game loop redraws every frame).
const CanvasBitmap = struct { ctx: CGContextRef, w: usize, h: usize };

/// The largest bitmap side, in pixels, and the largest area: 16 M px
/// (64 MB as RGBA); a bigger canvas gets a bitmap of fewer pixels per point.
const max_canvas_side: f64 = 16384;
const max_canvas_pixels: f64 = 4096 * 4096;

fn dropCanvas(n: *Node) void {
    const p = n.native orelse return;
    n.native = null;
    const b: *CanvasBitmap = @ptrCast(@alignCast(p));
    CGContextRelease(b.ctx);
    std.heap.smp_allocator.destroy(b);
}

fn canvasBitmap(n: *Node, w: usize, h: usize) ?*CanvasBitmap {
    if (n.native) |p| {
        const b: *CanvasBitmap = @ptrCast(@alignCast(p));
        if (b.w == w and b.h == h) return b;
        dropCanvas(n);
    }
    const space = srgb() orelse return null;
    // Premultiplied RGBA, its memory owned by the context.
    const ctx = CGBitmapContextCreate(null, w, h, 8, 0, space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big) orelse return null;
    const b = std.heap.smp_allocator.create(CanvasBitmap) catch {
        CGContextRelease(ctx);
        return null;
    };
    b.* = .{ .ctx = ctx, .w = w, .h = h };
    n.native = b;
    return b;
}

const identity: CGAffineTransform = .{ .a = 1, .b = 0, .c = 0, .d = 1, .tx = 0, .ty = 0 };

extern fn CGAffineTransformTranslate(t: CGAffineTransform, x: CGFloat, y: CGFloat) CGAffineTransform;
extern fn CGAffineTransformScale(t: CGAffineTransform, x: CGFloat, y: CGFloat) CGAffineTransform;
extern fn CGAffineTransformRotate(t: CGAffineTransform, a: CGFloat) CGAffineTransform;

const CanvasState = struct {
    fill: tree_mod.CanvasPaint = .{ .color = .{ 0, 0, 0, 1 } },
    stroke: tree_mod.CanvasPaint = .{ .color = .{ 0, 0, 0, 1 } },
    lw: f32 = 1,
    cap: u2 = 0, // butt, round, square
    join: u2 = 0, // miter, round, bevel
    alpha: f32 = 1,
    font: tree_mod.CanvasFont = .{ .size = 10 },
    talign: u2 = 0, // left, center, right
    tbase: u3 = 0, // alphabetic, top, hanging, middle, bottom
    /// The canvas transform (path points are put through it when added, as
    /// a canvas does: a later transform doesn't move them).
    m: CGAffineTransform = identity,
    /// A scale by 0: nothing drawn until the restore() that undoes it.
    singular: bool = false,
};

/// A gradient by id, as recorded: built into a CGGradient when used (its
/// stops come after it).
const CanvasGrad = struct {
    radial: bool,
    c: [6]f32, // x0, y0, x1, y1 (linear); x0, y0, r0, x1, y1, r1 (radial)
    stops: std.ArrayListUnmanaged([5]f32) = .empty, // r, g, b, a, offset
};

const Replay = struct {
    gpa: std.mem.Allocator,
    ctx: CGContextRef,
    st: CanvasState = .{},
    states: std.ArrayListUnmanaged(CanvasState) = .empty,
    /// The current path, in the canvas's base space (transforms applied):
    /// it survives fill, stroke, fillRect, clearRect and clip.
    path: CGPathRef,
    grads: std.AutoHashMapUnmanaged(u16, CanvasGrad) = .empty,
    /// The current path as whole circles (base space: cx, cy, radius), while
    /// it's nothing else: a game's balls in one path. Filled opaque, they're
    /// drawn one by one (CoreGraphics' rasterizer slows down a lot on one
    /// path of hundreds of circles: 500 balls went from 120 to ~50 fps).
    circles: std.ArrayListUnmanaged([3]f64) = .empty,
    /// The path is only `circles` (each starting fresh or at a moveTo on
    /// its own start point), all wound the same way.
    only_circles: bool = true,
    circles_ccw: bool = false,
    /// A moveTo not yet followed by anything (base space).
    pending_move: ?[2]f64 = null,

    fn deinit(r: *Replay) void {
        r.circles.deinit(r.gpa);
        CFRelease(r.path);
        // Balanced: what the program saved and didn't restore.
        for (r.states.items) |_| CGContextRestoreGState(r.ctx);
        r.states.deinit(r.gpa);
        var it = r.grads.valueIterator();
        while (it.next()) |g| g.stops.deinit(r.gpa);
        r.grads.deinit(r.gpa);
    }

    fn newPath(r: *Replay) void {
        const fresh = CGPathCreateMutable() orelse return;
        CFRelease(r.path);
        r.path = fresh;
        r.circles.clearRetainingCapacity();
        r.only_circles = true;
        r.pending_move = null;
    }

    /// The path gets something other than a whole circle.
    fn notCircles(r: *Replay) void {
        r.only_circles = false;
        r.circles.clearRetainingCapacity();
    }

    /// An arc was added (canvas units, before the transform): a whole circle
    /// keeps the path's circles, anything else ends them.
    fn noteArc(r: *Replay, x: f32, y: f32, radius: f32, a0: f32, a1: f32, ccw: bool) void {
        if (!r.only_circles) return;
        const m = r.st.m;
        const two_pi: f32 = 2.0 * std.math.pi;
        // (A turn from a0 != 0 may round a hair short in f32.)
        const whole = (if (ccw) a0 - a1 else a1 - a0) >= two_pi - 1e-4;
        // A circle stays one: orthogonal columns of the same length.
        const s2 = m.a * m.a + m.b * m.b;
        const similar = s2 > 0 and @abs(s2 - (m.c * m.c + m.d * m.d)) <= 1e-9 * s2 and @abs(m.a * m.c + m.b * m.d) <= 1e-9 * s2;
        // Its winding in base space: a reflection turns it the other way.
        const winding = ccw != (m.a * m.d - m.b * m.c < 0);
        if (!whole or !similar or !(radius >= 0) or (r.circles.items.len > 0 and winding != r.circles_ccw)) return r.notCircles();
        // Its start point: where a moveTo must be, if the path has more.
        const sx: f64 = x + radius * @cos(a0);
        const sy: f64 = y + radius * @sin(a0);
        const start = [2]f64{ m.a * sx + m.c * sy + m.tx, m.b * sx + m.d * sy + m.ty };
        if (r.pending_move) |p| {
            const tol = 1e-3 * @max(1.0, @sqrt(s2) * radius);
            if (@abs(p[0] - start[0]) > tol or @abs(p[1] - start[1]) > tol) return r.notCircles();
        } else if (!CGPathIsEmpty(r.path)) {
            // Joined to what came before by a line: not just circles.
            return r.notCircles();
        }
        r.pending_move = null;
        r.circles_ccw = winding;
        r.circles.append(r.gpa, .{ m.a * x + m.c * y + m.tx, m.b * x + m.d * y + m.ty, @sqrt(s2) * radius }) catch r.notCircles();
    }
};

fn paintCanvas(comptime font_class: [:0]const u8, cg: CGContextRef, scale: f64, n: *Node) void {
    const cmds = n.canvas orelse return;
    const f = n.frame;
    if (!(f.w > 0) or !(f.h > 0)) return; // NaN too
    var sf: f64 = if (scale > 0 and std.math.isFinite(scale)) scale else 1;
    const area = @as(f64, f.w) * f.h * sf * sf;
    if (area > max_canvas_pixels) sf *= @sqrt(max_canvas_pixels / area);
    const pw: usize = @intFromFloat(@min(max_canvas_side, @ceil(f.w * sf)));
    const ph: usize = @intFromFloat(@min(max_canvas_side, @ceil(f.h * sf)));
    if (pw == 0 or ph == 0) return;
    const bmp = canvasBitmap(n, pw, ph) orelse return;
    const ctx = bmp.ctx;
    // The program draws into the canvas's own bitmap: an unbalanced
    // restore() can't reach the page's states, and clearRect clears the
    // canvas, not the page behind it.
    CGContextSaveGState(ctx);
    CGContextClearRect(ctx, .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = @floatFromInt(pw), .height = @floatFromInt(ph) } });
    // y down, in points, then the bitmap's space scaled to the box (CSS
    // width/height stretch it, as in a browser).
    CGContextTranslateCTM(ctx, 0, @floatFromInt(ph));
    CGContextScaleCTM(ctx, @as(f64, @floatFromInt(pw)) / f.w, -@as(f64, @floatFromInt(ph)) / f.h);
    const cw = n.props.cw orelse f.w;
    const ch = n.props.ch orelse f.h;
    if (cw > 0 and ch > 0) CGContextScaleCTM(ctx, f.w / cw, f.h / ch);
    var r: Replay = .{ .gpa = std.heap.smp_allocator, .ctx = ctx, .path = CGPathCreateMutable() orelse {
        CGContextRestoreGState(ctx);
        return;
    } };
    replay(font_class, &r, cmds);
    r.deinit();
    CGContextRestoreGState(ctx);

    // The bitmap at the frame, clipped to the box's rounded corners (as a
    // browser clips a replaced element's content to its border-radius).
    const img = CGBitmapContextCreateImage(ctx) orelse return;
    defer CGImageRelease(img);
    CGContextSaveGState(cg);
    defer CGContextRestoreGState(cg);
    roundRect(cg, f, n.radiusXY());
    CGContextClip(cg);
    CGContextTranslateCTM(cg, f.x, f.y + f.h);
    CGContextScaleCTM(cg, 1, -1);
    CGContextDrawImage(cg, .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = f.w, .height = f.h } }, img);
}

fn replay(comptime font_class: [:0]const u8, r: *Replay, cmds: []const tree_mod.CanvasCmd) void {
    const ctx = r.ctx;
    for (cmds) |cmd| {
        if (r.st.singular) switch (cmd) {
            .translate, .scale, .rotate, .begin_path, .close_path, .move_to, .line_to, .rect, .arc, .bezier_to, .fill, .stroke, .clip, .fill_rect, .stroke_rect, .clear_rect, .fill_text, .stroke_text => continue,
            else => {},
        };
        const m = &r.st.m;
        defer if (!r.st.singular and !invertible(r.st.m)) {
            // A transform that overflowed or collapsed (scale(1e-30) twice):
            // as a scale by 0, nothing until the restore() that undoes it.
            r.st.singular = true;
        };
        switch (cmd) {
            .save => {
                // Saved together or not at all, so restore stays balanced.
                r.states.append(r.gpa, r.st) catch continue;
                CGContextSaveGState(ctx);
            },
            .restore => {
                // Only what this program saved: an extra restore() is ignored.
                if (r.states.pop()) |prev| {
                    r.st = prev;
                    CGContextRestoreGState(ctx);
                }
            },
            .translate => |t| m.* = CGAffineTransformTranslate(m.*, t[0], t[1]),
            .scale => |t| if (t[0] == 0 or t[1] == 0) {
                r.st.singular = true;
            } else {
                m.* = CGAffineTransformScale(m.*, t[0], t[1]);
            },
            .rotate => |a| m.* = CGAffineTransformRotate(m.*, a),
            .begin_path => r.newPath(),
            .close_path => if (!CGPathIsEmpty(r.path)) {
                CGPathCloseSubpath(r.path);
                // A closed circle is still one; an open moveTo isn't a figure.
                if (r.pending_move != null) r.notCircles();
            },
            .move_to => |p| {
                CGPathMoveToPoint(r.path, m, p[0], p[1]);
                const t = m.*;
                r.pending_move = .{ t.a * p[0] + t.c * p[1] + t.tx, t.b * p[0] + t.d * p[1] + t.ty };
            },
            .line_to => |p| {
                if (CGPathIsEmpty(r.path)) CGPathMoveToPoint(r.path, m, p[0], p[1]) else CGPathAddLineToPoint(r.path, m, p[0], p[1]);
                r.notCircles();
            },
            .rect => |q| {
                CGPathAddRect(r.path, m, .{ .origin = .{ .x = q[0], .y = q[1] }, .size = .{ .width = q[2], .height = q[3] } });
                r.notCircles();
            },
            .arc => |a| {
                // Canvas angles grow clockwise on screen (y down); CG's
                // `clockwise` means decreasing angles, so it's the canvas's
                // counterclockwise. A sweep of a full turn or more is a circle.
                const two_pi: f32 = 2.0 * std.math.pi;
                var a1 = a.a1;
                if (!a.ccw and a1 - a.a0 >= two_pi) a1 = a.a0 + two_pi;
                if (a.ccw and a.a0 - a1 >= two_pi) a1 = a.a0 - two_pi;
                r.noteArc(a.x, a.y, @max(0, a.r), a.a0, a1, a.ccw);
                CGPathAddArc(r.path, m, a.x, a.y, @max(0, a.r), a.a0, a1, a.ccw);
            },
            .bezier_to => |b| {
                r.notCircles();
                if (CGPathIsEmpty(r.path)) CGPathMoveToPoint(r.path, m, b[0], b[1]);
                CGPathAddCurveToPoint(r.path, m, b[0], b[1], b[2], b[3], b[4], b[5]);
            },
            .fill => |even| if (even or !fillCircles(r)) fillPath(r, r.path, even),
            .stroke => strokePath(r, r.path),
            .clip => |even| {
                // An empty path clips everything (CG would leave the clip as is).
                if (CGPathIsEmpty(r.path)) {
                    CGContextClipToRect(ctx, .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } });
                } else {
                    CGContextAddPath(ctx, r.path);
                    if (even) CGContextEOClip(ctx) else CGContextClip(ctx);
                }
            },
            .fill_rect, .stroke_rect, .clear_rect => |q| {
                // Their own path: the current one stays.
                const tmp = CGPathCreateMutable() orelse continue;
                defer CFRelease(tmp);
                CGPathAddRect(tmp, m, .{ .origin = .{ .x = q[0], .y = q[1] }, .size = .{ .width = q[2], .height = q[3] } });
                switch (cmd) {
                    .fill_rect => fillPath(r, tmp, false),
                    .stroke_rect => strokePath(r, tmp),
                    else => {
                        // To transparent, under the clip, whatever the transform.
                        CGContextSaveGState(ctx);
                        defer CGContextRestoreGState(ctx);
                        CGContextSetBlendMode(ctx, kCGBlendModeClear);
                        CGContextAddPath(ctx, tmp);
                        CGContextFillPath(ctx);
                    },
                }
            },
            .fill_text => |t| canvasText(font_class, r, t.t, t.x, t.y, false),
            .stroke_text => |t| canvasText(font_class, r, t.t, t.x, t.y, true),
            .fill_style => |src| r.st.fill = src,
            .stroke_style => |src| r.st.stroke = src,
            .line_width => |w| r.st.lw = @max(0, w),
            .line_cap => |cap| r.st.cap = cap,
            .line_join => |join| r.st.join = join,
            .global_alpha => |a| r.st.alpha = std.math.clamp(a, 0, 1),
            .font => |fnt| r.st.font = fnt,
            .text_align => |a| r.st.talign = a,
            .text_baseline => |b| r.st.tbase = b,
            .linear_gradient => |g| putGrad(r, g.id, .{ .radial = false, .c = .{ g.x0, g.y0, g.x1, g.y1, 0, 0 } }),
            .radial_gradient => |g| putGrad(r, g.id, .{ .radial = true, .c = .{ g.x0, g.y0, @max(0, g.r0), g.x1, g.y1, @max(0, g.r1) } }),
            .color_stop => |c| if (r.grads.getPtr(c.id)) |g| {
                if (g.stops.items.len < 256) g.stops.append(r.gpa, .{ c.c[0], c.c[1], c.c[2], c.c[3], std.math.clamp(c.off, 0, 1) }) catch {};
            },
        }
    }
}

fn invertible(m: CGAffineTransform) bool {
    inline for (.{ m.a, m.b, m.c, m.d, m.tx, m.ty }) |v| if (!std.math.isFinite(v)) return false;
    const det = m.a * m.d - m.b * m.c;
    return std.math.isFinite(det) and det != 0;
}

fn putGrad(r: *Replay, id: u16, g: CanvasGrad) void {
    if (r.grads.fetchRemove(id)) |old| {
        var o = old.value;
        o.stops.deinit(r.gpa);
    }
    r.grads.put(r.gpa, id, g) catch {};
}

/// Draw gradient `id` (in the canvas transform's space) over what's clipped.
fn drawGrad(r: *Replay, id: u16) void {
    const g = r.grads.get(id) orelse return;
    if (g.stops.items.len == 0) return;
    const space = srgb() orelse return;
    var comps: [256 * 4]CGFloat = undefined;
    var locs: [256]CGFloat = undefined;
    // Stops sorted by offset (the page may add them in any order), stable.
    var order: [256]u16 = undefined;
    const count = g.stops.items.len;
    for (0..count) |i| order[i] = @intCast(i);
    const items = g.stops.items;
    std.sort.insertion(u16, order[0..count], items, struct {
        fn lt(st: []const [5]f32, a: u16, b: u16) bool {
            return st[a][4] < st[b][4];
        }
    }.lt);
    for (order[0..count], 0..) |k, i| {
        const st = items[k];
        comps[i * 4 + 0] = st[0] / 255;
        comps[i * 4 + 1] = st[1] / 255;
        comps[i * 4 + 2] = st[2] / 255;
        comps[i * 4 + 3] = st[3];
        locs[i] = st[4];
    }
    const grad = CGGradientCreateWithColorComponents(space, &comps, &locs, count) orelse return;
    defer CGGradientRelease(grad);
    CGContextConcatCTM(r.ctx, r.st.m);
    if (g.radial) {
        CGContextDrawRadialGradient(r.ctx, grad, .{ .x = g.c[0], .y = g.c[1] }, g.c[2], .{ .x = g.c[3], .y = g.c[4] }, g.c[5], kCGGradientDrawsBeforeAndAfter);
    } else {
        CGContextDrawLinearGradient(r.ctx, grad, .{ .x = g.c[0], .y = g.c[1] }, .{ .x = g.c[2], .y = g.c[3] }, kCGGradientDrawsBeforeAndAfter);
    }
}

fn setPaintColor(ctx: CGContextRef, c: tree_mod.Color, alpha: f32, stroke: bool) void {
    const comps = .{ c[0] / 255, c[1] / 255, c[2] / 255, c[3] * alpha };
    if (stroke) setStrokeRGBA(ctx, comps[0], comps[1], comps[2], comps[3]) else setFillRGBA(ctx, comps[0], comps[1], comps[2], comps[3]);
}

/// Off in a test: the same pictures the slow way.
var circles_one_by_one = true;

/// The current path filled as its circles, one by one, when that's the
/// same picture: a nonzero fill (even-odd makes holes where they overlap)
/// of whole circles wound one way (their union), in an opaque color (an
/// overlap can't blend twice).
/// Many circles only: a few go the usual way. False: fill the path.
fn fillCircles(r: *Replay) bool {
    if (!circles_one_by_one or !r.only_circles or r.circles.items.len < 8 or r.pending_move != null) return false;
    const c = switch (r.st.fill) {
        .color => |c| c,
        .grad => return false,
    };
    if (c[3] * r.st.alpha < 1) return false;
    const ctx = r.ctx;
    CGContextSaveGState(ctx);
    defer CGContextRestoreGState(ctx);
    setPaintColor(ctx, c, r.st.alpha, false);
    for (r.circles.items) |k| {
        CGContextFillEllipseInRect(ctx, .{ .origin = .{ .x = k[0] - k[2], .y = k[1] - k[2] }, .size = .{ .width = 2 * k[2], .height = 2 * k[2] } });
    }
    return true;
}

fn fillPath(r: *Replay, path: CGPathRef, even: bool) void {
    const ctx = r.ctx;
    if (CGPathIsEmpty(path)) return; // nothing to fill (a gradient would flood the clip)
    CGContextSaveGState(ctx);
    defer CGContextRestoreGState(ctx);
    CGContextAddPath(ctx, path);
    switch (r.st.fill) {
        .color => |c| {
            setPaintColor(ctx, c, r.st.alpha, false);
            CGContextDrawPath(ctx, if (even) kCGPathEOFill else kCGPathFill);
        },
        .grad => |id| {
            if (even) CGContextEOClip(ctx) else CGContextClip(ctx);
            drawGrad(r, id);
        },
    }
}

/// Stroked in the canvas transform's space, so the line width and dashes
/// scale with it, as in a canvas.
fn strokePath(r: *Replay, path: CGPathRef) void {
    const ctx = r.ctx;
    if (CGPathIsEmpty(path)) return;
    const inv = CGAffineTransformInvert(r.st.m);
    const local = CGPathCreateCopyByTransformingPath(path, &inv) orelse return;
    defer CFRelease(local);
    CGContextSaveGState(ctx);
    defer CGContextRestoreGState(ctx);
    CGContextConcatCTM(ctx, r.st.m);
    CGContextAddPath(ctx, local);
    CGContextSetLineWidth(ctx, @max(0.1, r.st.lw));
    CGContextSetLineCap(ctx, r.st.cap);
    CGContextSetLineJoin(ctx, r.st.join);
    switch (r.st.stroke) {
        .color => |c| {
            setPaintColor(ctx, c, r.st.alpha, true);
            CGContextStrokePath(ctx);
        },
        .grad => |id| {
            CGContextReplacePathWithStrokedPath(ctx);
            CGContextClip(ctx);
            // drawGrad applies the transform itself: undo ours first.
            CGContextConcatCTM(ctx, CGAffineTransformInvert(r.st.m));
            drawGrad(r, id);
        },
    }
}

/// fillText / strokeText: one line (no wrapping), placed by textAlign and
/// textBaseline from (x, y), in the canvas transform.
fn canvasText(comptime font_class: [:0]const u8, r: *Replay, text: []const u8, x: f32, y: f32, stroke: bool) void {
    if (text.len == 0) return;
    const ctx = r.ctx;
    const st = r.st;
    const size: f32 = if (st.font.size > 0 and st.font.size < 2000) st.font.size else 10;
    const fam = st.font.family;
    const generic_sans = fam.len == 0 or std.ascii.endsWithIgnoreCase(fam, "sans-serif") or std.ascii.endsWithIgnoreCase(fam, "system-ui");
    const mono = std.ascii.endsWithIgnoreCase(fam, "monospace");
    // A named family (or the generic serif) through CoreText; else the
    // system font, as the page's own text.
    var named: ?CTFontRef = null;
    defer if (named) |nf| CFRelease(nf);
    if (!generic_sans and !mono) {
        const name: []const u8 = if (std.ascii.endsWithIgnoreCase(fam, "serif")) "Times New Roman" else std.mem.trim(u8, fam, " \"'");
        if (CFStringCreateWithBytes(null, name.ptr, @intCast(name.len), kCFStringEncodingUTF8, 0)) |cf| {
            defer CFRelease(cf);
            named = CTFontCreateWithName(cf, size, null);
        }
    }
    const fnt = named orelse font(font_class, size, st.font.weight, st.font.italic, mono, if (mono) "ui-monospace" else "system-ui") orelse return;
    const s = CFAttributedStringCreateMutable(null, 0) orelse return;
    defer CFRelease(s);
    const str = CFStringCreateWithBytes(null, text.ptr, @intCast(@min(text.len, 1 << 20)), kCFStringEncodingUTF8, 0) orelse return;
    defer CFRelease(str);
    CFAttributedStringReplaceString(s, .{ .location = 0, .length = 0 }, str);
    const all: CFRange = .{ .location = 0, .length = CFStringGetLength(str) };
    CFAttributedStringSetAttribute(s, all, kCTFontAttributeName, fnt);
    CFAttributedStringSetAttribute(s, all, kCTForegroundColorFromContextAttributeName, kCFBooleanTrue);
    const line = CTLineCreateWithAttributedString(s) orelse return;
    defer CFRelease(line);
    var ascent: CGFloat = 0;
    var descent: CGFloat = 0;
    const width = CTLineGetTypographicBounds(line, &ascent, &descent, null);
    // The baseline's start from the anchor (x, y), y down.
    var px: f64 = x;
    var py: f64 = y;
    switch (st.talign) {
        1 => px -= width / 2,
        2 => px -= width,
        else => {},
    }
    switch (st.tbase) {
        1, 2 => py += ascent, // top, hanging
        3 => py += (ascent - descent) / 2, // middle
        4 => py -= descent, // bottom
        else => {}, // alphabetic
    }
    CGContextSaveGState(ctx);
    defer CGContextRestoreGState(ctx);
    CGContextConcatCTM(ctx, st.m);
    // Glyphs are drawn y up: flip them in the y-down space.
    CGContextSetTextMatrix(ctx, .{ .a = 1, .b = 0, .c = 0, .d = -1, .tx = 0, .ty = 0 });
    CGContextSetTextPosition(ctx, px, py);
    const paint_src = if (stroke) st.stroke else st.fill;
    switch (paint_src) {
        .color => |c| {
            setPaintColor(ctx, c, st.alpha, stroke);
            if (stroke) CGContextSetLineWidth(ctx, @max(0.5, st.lw));
            CGContextSetTextDrawingMode(ctx, if (stroke) kCGTextStroke else kCGTextFill);
            CTLineDraw(line, ctx);
        },
        .grad => |id| {
            // The glyphs as a clip, then the gradient through them.
            if (stroke) CGContextSetLineWidth(ctx, @max(0.5, st.lw));
            CGContextSetTextDrawingMode(ctx, if (stroke) kCGTextStrokeClip else kCGTextClip);
            CTLineDraw(line, ctx);
            CGContextConcatCTM(ctx, CGAffineTransformInvert(st.m));
            drawGrad(r, id);
        },
    }
}

test "canvas: a path of whole circles is filled one by one, with the same pixels" {
    const C = tree_mod.CanvasCmd;
    const arcAt = struct {
        fn f(x: f32, y: f32, rad: f32, ccw: bool) [2]C {
            const turn: f32 = 2.0 * std.math.pi;
            return .{ .{ .move_to = .{ x + rad, y } }, .{ .arc = .{ .x = x, .y = y, .r = rad, .a0 = 0, .a1 = if (ccw) -turn else turn, .ccw = ccw } } };
        }
    }.f;
    const space = CGColorSpaceCreateDeviceRGB().?;
    defer CGColorSpaceRelease(space);
    const w = 64;
    const h = 48;
    const Bmp = struct {
        fn make(sp: CGColorSpaceRef) CGContextRef {
            return CGBitmapContextCreate(null, w, h, 8, 0, sp, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big).?;
        }
    };
    // What the replay makes of a program: whole circles, or not.
    const Probe = struct {
        fn run(sp: CGColorSpaceRef, cmds: []const C) !struct { only: bool, n: usize } {
            const ctx = Bmp.make(sp);
            defer CGContextRelease(ctx);
            var r: Replay = .{ .gpa = std.testing.allocator, .ctx = ctx, .path = CGPathCreateMutable().? };
            defer r.deinit();
            replay("NSFont", &r, cmds);
            return .{ .only = r.only_circles and r.pending_move == null, .n = r.circles.items.len };
        }
    };
    var many: [40]C = undefined;
    for (0..20) |i| {
        const fi: f32 = @floatFromInt(i);
        const pair = arcAt(6 + @mod(fi * 7, 52), 6 + @mod(fi * 5, 36), 3 + @mod(fi, 4), false);
        many[2 * i] = pair[0];
        many[2 * i + 1] = pair[1];
    }
    const ok = try Probe.run(space, &many);
    try std.testing.expect(ok.only);
    try std.testing.expectEqual(@as(usize, 20), ok.n);
    // Not just circles: a line, a part of a circle, the other way round, a
    // moveTo away from the circle's start, a stretched transform.
    const a = arcAt(20, 20, 5, false);
    const b = arcAt(30, 20, 5, true);
    try std.testing.expect(!(try Probe.run(space, &.{ a[0], a[1], .{ .line_to = .{ 1, 1 } } })).only);
    try std.testing.expect(!(try Probe.run(space, &.{.{ .arc = .{ .x = 9, .y = 9, .r = 4, .a0 = 0, .a1 = 3, .ccw = false } }})).only);
    try std.testing.expect(!(try Probe.run(space, &.{ a[0], a[1], b[0], b[1] })).only);
    try std.testing.expect(!(try Probe.run(space, &.{ .{ .move_to = .{ 1, 1 } }, a[1] })).only);
    try std.testing.expect(!(try Probe.run(space, &.{ .{ .scale = .{ 2, 1 } }, a[0], a[1] })).only);
    try std.testing.expect((try Probe.run(space, &.{ .{ .rotate = 0.5 }, .{ .scale = .{ 2, 2 } }, a[0], a[1] })).only);
    // A reflected circle winds the other way: with a plain one, not a union.
    try std.testing.expect(!(try Probe.run(space, &.{ a[0], a[1], .save, .{ .scale = .{ -1, 1 } }, .{ .move_to = .{ -25, 20 } }, .{ .arc = .{ .x = -30, .y = 20, .r = 5, .a0 = 0, .a1 = 2 * std.math.pi, .ccw = false } }, .restore })).only);
    // Reflected and drawn the other way round: the same winding, still circles.
    try std.testing.expect((try Probe.run(space, &.{ a[0], a[1], .save, .{ .scale = .{ -1, 1 } }, .{ .move_to = .{ -25, 20 } }, .{ .arc = .{ .x = -30, .y = 20, .r = 5, .a0 = 0, .a1 = -2 * std.math.pi, .ccw = true } }, .restore })).only);
    // The same picture both ways: overlapping opaque circles, one fill.
    var prog: [42]C = undefined;
    prog[0] = .{ .fill_style = .{ .color = .{ 255, 255, 255, 1 } } };
    @memcpy(prog[1..41], &many);
    prog[41] = .{ .fill = false };
    var pixels: [2][w * h * 4]u8 = undefined;
    for (0..2) |k| {
        circles_one_by_one = k == 0;
        defer circles_one_by_one = true;
        const ctx = Bmp.make(space);
        defer CGContextRelease(ctx);
        var r: Replay = .{ .gpa = std.testing.allocator, .ctx = ctx, .path = CGPathCreateMutable().? };
        replay("NSFont", &r, &prog);
        r.deinit();
        @memcpy(&pixels[k], CGBitmapContextGetData(ctx).?[0 .. w * h * 4]);
    }
    // Antialiased edges may round a little differently; the shapes match.
    var off: usize = 0;
    for (pixels[0], pixels[1]) |p, q| {
        if (@abs(@as(i16, p) - @as(i16, q)) > 40) off += 1;
    }
    try std.testing.expect(off < 30);
}
