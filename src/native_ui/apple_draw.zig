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
extern fn CGContextFillRect(c: CGContextRef, r: CGRect) void;
extern fn CGContextClearRect(c: CGContextRef, r: CGRect) void;
extern fn CGContextStrokePath(c: CGContextRef) void;
extern fn CGContextDrawPath(c: CGContextRef, mode: c_int) void;
extern fn CGContextSetRGBFillColor(c: CGContextRef, r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) void;
extern fn CGContextSetRGBStrokeColor(c: CGContextRef, r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) void;
extern fn CGContextSetLineWidth(c: CGContextRef, w: CGFloat) void;
extern fn CGContextSetLineCap(c: CGContextRef, cap: c_int) void;
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
extern fn CGColorSpaceRelease(s: CGColorSpaceRef) void;
extern fn CGColorCreate(space: CGColorSpaceRef, components: [*]const CGFloat) ?CGColorRef;
extern fn CGColorRelease(c: CGColorRef) void;
extern fn CGGradientCreateWithColorComponents(space: CGColorSpaceRef, components: [*]const CGFloat, locations: [*]const CGFloat, count: usize) ?CGGradientRef;
extern fn CGGradientRelease(g: CGGradientRef) void;
extern fn CGPathCreateWithRect(r: CGRect, t: ?*const CGAffineTransform) ?CGPathRef;
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
const CTParagraphStyleSetting = extern struct { spec: u32, size: usize, value: *const anyopaque };
extern fn CTParagraphStyleCreate(settings: [*]const CTParagraphStyleSetting, count: usize) ?CTParagraphStyleRef;
const kCTParagraphStyleSpecifierAlignment: u32 = 0;
const kCTParagraphStyleSpecifierLineBreakMode: u32 = 6;
const kCTParagraphStyleSpecifierMaximumLineHeight: u32 = 8;
const kCTParagraphStyleSpecifierMinimumLineHeight: u32 = 9;
const kCTFontItalicTrait: u32 = 1 << 0;
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

const FontKey = struct { size: f32, weight: i32, italic: bool, mono: bool };
var font_cache: std.ArrayListUnmanaged(struct { key: FontKey, font: CTFontRef }) = .empty;

/// CSS font-weight (100-900) to NSFontWeight/UIFontWeight.
fn appleWeight(w: f32) f64 {
    const table = [_]f64{ -0.8, -0.6, -0.4, 0, 0.23, 0.3, 0.4, 0.56, 0.62 };
    const i: usize = @intFromFloat(std.math.clamp(@round(w / 100) - 1, 0, 8));
    return table[i];
}

/// `font_class`: "NSFont" (AppKit) or "UIFont" (UIKit).
pub fn font(comptime font_class: [:0]const u8, size: f32, weight: f32, italic: bool, mono: bool) ?CTFontRef {
    const key: FontKey = .{ .size = size, .weight = @intFromFloat(std.math.clamp(@round(weight / 100), 1, 9)), .italic = italic, .mono = mono };
    for (font_cache.items) |e| if (std.meta.eql(e.key, key)) return e.font;
    const cls = objc.getClass(font_class) orelse return null;
    const sel = if (mono) "monospacedSystemFontOfSize:weight:" else "systemFontOfSize:weight:";
    const f = cls.msgSend(Object, sel, .{ @as(CGFloat, size), appleWeight(weight) });
    if (f.value == null) return null;
    var ct: CTFontRef = CFRetain(@ptrCast(f.value.?));
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

// ---------------------------------------------------------------------------
// Text

/// A text node's runs as a CoreText attributed string (+1), or null.
fn attributed(comptime font_class: [:0]const u8, n: *const Node) ?CFAttributedStringRef {
    const runs = n.props.runs orelse return null;
    const s = CFAttributedStringCreateMutable(null, 0) orelse return null;
    const space = CGColorSpaceCreateDeviceRGB() orelse {
        CFRelease(s);
        return null;
    };
    defer CGColorSpaceRelease(space);
    for (runs) |r| {
        if (r.t.len == 0) continue;
        const str = CFStringCreateWithBytes(null, r.t.ptr, @intCast(r.t.len), kCFStringEncodingUTF8, 0) orelse continue;
        defer CFRelease(str);
        const start = CFAttributedStringGetLength(s);
        CFAttributedStringReplaceString(s, .{ .location = start, .length = 0 }, str);
        const range: CFRange = .{ .location = start, .length = CFStringGetLength(str) };
        if (font(font_class, r.sz, r.w, r.i, r.mono or n.props.mono)) |f| CFAttributedStringSetAttribute(s, range, kCTFontAttributeName, f);
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
    var lh: CGFloat = 0;
    if (n.props.lh) |v| {
        lh = v;
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

/// The size a text node needs at `max_width` (inf: one line per paragraph).
pub fn measureText(comptime font_class: [:0]const u8, n: *Node, max_width: f32) [2]f32 {
    const cache = textCache(font_class, n) orelse return .{ 0, 0 };
    const fs = cache.fs orelse return .{ 0, @round((n.props.fz orelse 16) * 1.2) };
    const w: CGFloat = if (n.props.nowrap or std.math.isInf(max_width)) big else @max(1, max_width);
    const size = CTFramesetterSuggestFrameSizeWithConstraints(fs, .{ .location = 0, .length = 0 }, null, .{ .width = w, .height = big }, null);
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
    if (cache.frame == null or cache.frame_w != w or cache.frame_h < h) {
        const need = CTFramesetterSuggestFrameSizeWithConstraints(fs, .{ .location = 0, .length = 0 }, null, .{ .width = w, .height = big }, null);
        h = @max(c.h, @ceil(need.height));
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
    CTFrameDraw(frame, cg);
}

// ---------------------------------------------------------------------------
// Fields

/// The part of a field the page shows: its content box within its clip,
/// minus what the page paints over it later (a fixed header or footer bar
/// across it), since native controls sit above everything drawn. Bars that
/// cover the field's whole width cut it from the top or the bottom.
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
    for (n.kids.items) |k| cutBy(k, field, after, shown);
}

// ---------------------------------------------------------------------------
// Drawing

/// Draw `tree` into `cg` (top-left origin). `transparent`: nothing under the
/// page (a transparent window); else white, as in a browser.
pub fn paint(comptime font_class: [:0]const u8, cg: CGContextRef, tree: *tree_mod.Tree, transparent: bool) void {
    if (tree.dirty) tree.layout();
    const all: CGRect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = tree.width, .height = tree.height } };
    if (transparent) {
        CGContextClearRect(cg, all);
    } else {
        CGContextSetRGBFillColor(cg, 1, 1, 1, 1);
        CGContextFillRect(cg, all);
    }
    const root = tree.root orelse return;
    paintNode(font_class, cg, root);
}

fn paintNode(comptime font_class: [:0]const u8, cg: CGContextRef, n: *Node) void {
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

    const r = n.radius();
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
    if (p.bw) |bw| border(cg, f, r, bw, p.bc);
    switch (n.kind) {
        .text => paintText(font_class, cg, n),
        .icon => paintIcon(cg, n),
        else => {},
    }
    for (n.kids.items) |k| paintNode(font_class, cg, k);
}

fn setFill(cg: CGContextRef, c: tree_mod.Color) void {
    CGContextSetRGBFillColor(cg, c[0] / 255, c[1] / 255, c[2] / 255, c[3]);
}

fn setStroke(cg: CGContextRef, c: tree_mod.Color) void {
    CGContextSetRGBStrokeColor(cg, c[0] / 255, c[1] / 255, c[2] / 255, c[3]);
}

/// A rectangle with per-corner radii (top-left, top-right, bottom-right,
/// bottom-left) as the current path.
fn roundRect(cg: CGContextRef, f: Rect, r: [4]f32) void {
    CGContextBeginPath(cg);
    if (r[0] == 0 and r[1] == 0 and r[2] == 0 and r[3] == 0) {
        CGContextAddRect(cg, rect(f));
        return;
    }
    const x: CGFloat = f.x;
    const y: CGFloat = f.y;
    const w: CGFloat = f.w;
    const h: CGFloat = f.h;
    CGContextMoveToPoint(cg, x + r[0], y);
    CGContextAddArcToPoint(cg, x + w, y, x + w, y + h, r[1]);
    CGContextAddArcToPoint(cg, x + w, y + h, x, y + h, r[2]);
    CGContextAddArcToPoint(cg, x, y + h, x, y, r[3]);
    CGContextAddArcToPoint(cg, x, y, x + w, y, r[0]);
    CGContextClosePath(cg);
}

fn gradient(cg: CGContextRef, f: Rect, r: [4]f32, g: tree_mod.Gradient) void {
    if (g.stops.len == 0) return;
    const space = CGColorSpaceCreateDeviceRGB() orelse return;
    defer CGColorSpaceRelease(space);
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
    if (g.radial) |rad| {
        // A unit circle at the origin, stretched onto the ellipse.
        const cx = f.x + boxLen(rad[0], f.w);
        const cy = f.y + boxLen(rad[1], f.h);
        const rx = @max(0.01, boxLen(rad[2], f.w));
        const ry = @max(0.01, boxLen(rad[3], f.h));
        CGContextTranslateCTM(cg, cx, cy);
        CGContextScaleCTM(cg, rx, ry);
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

/// A gradient length: px, or "50%" of `total`.
fn boxLen(v: tree_mod.Dim, total: f32) f32 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |x| @floatCast(x),
        .string => |s| if (std.mem.endsWith(u8, s, "%")) (std.fmt.parseFloat(f32, s[0 .. s.len - 1]) catch 0) / 100 * total else 0,
        else => 0,
    };
}

fn border(cg: CGContextRef, f: Rect, r: [4]f32, bw: [4]f32, bc: ?[4]tree_mod.Color) void {
    const colors = bc orelse return;
    const uniform = bw[0] == bw[1] and bw[1] == bw[2] and bw[2] == bw[3];
    if (uniform and bw[0] > 0) {
        const half = bw[0] / 2;
        const inner: Rect = .{ .x = f.x + half, .y = f.y + half, .w = f.w - bw[0], .h = f.h - bw[0] };
        var ri = r;
        for (&ri) |*x| x.* = @max(0, x.* - half);
        roundRect(cg, inner, ri);
        setStroke(cg, colors[0]);
        CGContextSetLineWidth(cg, bw[0]);
        CGContextStrokePath(cg);
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
        CGContextFillRect(cg, rect(sd));
    }
}

fn shadow(cg: CGContextRef, f: Rect, r: [4]f32, sh: tree_mod.Shadow) void {
    // As on GTK: stacked layers from half the blur inside the box to half
    // outside, so the edge gets half the color and it fades over the blur.
    const steps: usize = 8;
    var i: usize = 0;
    while (i < steps) : (i += 1) {
        const t: f32 = (@as(f32, @floatFromInt(i)) + 0.5) / @as(f32, @floatFromInt(steps));
        const grow = sh.spread + sh.blur * (t - 0.5);
        const box: Rect = .{ .x = f.x + sh.x - grow, .y = f.y + sh.y - grow, .w = f.w + 2 * grow, .h = f.h + 2 * grow };
        if (box.w <= 0 or box.h <= 0) continue;
        var rr = r;
        for (&rr) |*x| x.* = @max(0, x.* + grow);
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
