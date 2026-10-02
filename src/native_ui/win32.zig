//! The native renderer's Win32 backend (docs/native-renderer.md).
//!
//! Boxes, text (DirectWrite) and icons (Direct2D path geometries, from
//! svg_path.zig) are drawn with Direct2D in one child window, the canvas;
//! text fields, text areas and selects are real EDIT and COMBOBOX controls,
//! children of the canvas placed at their nodes' frames. Clicks, the wheel
//! and keys are hit-tested on the node tree and sent to the page, as on GTK.
//!
//! The tree is in CSS pixels; the render target's DPI is the window's, so
//! Direct2D draws in the same units, and pointer positions are divided by
//! the scale. A transparent window (overlays) clears to transparent: with
//! the DWM blur-behind its parent window gets, only what the page paints
//! shows.

const std = @import("std");
const engine_mod = @import("engine.zig");
const tree_mod = @import("tree.zig");
const svg_path = @import("svg_path.zig");
const Engine = engine_mod.Engine;
const Node = tree_mod.Node;
const Rect = tree_mod.Rect;

const log = std.log.scoped(.native_ui);

pub const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("COBJMACROS", "1");
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("UNICODE", "1");
    @cInclude("windows.h");
    @cInclude("d2d1.h");
    @cInclude("dwrite.h");
    @cInclude("wincodec.h");
});

// The import libraries don't export these.
const IID_IDWriteFactory = c.GUID{ .Data1 = 0xb859ee5a, .Data2 = 0xd838, .Data3 = 0x4b5b, .Data4 = .{ 0xa2, 0xe8, 0x1a, 0xdc, 0x7d, 0x93, 0xdb, 0x48 } };
const IID_ID2D1Factory = c.GUID{ .Data1 = 0x06152247, .Data2 = 0x6f50, .Data3 = 0x465a, .Data4 = .{ 0x92, 0x45, 0x11, 0x8b, 0xfd, 0x3b, 0x60, 0x07 } };
const CLSID_WICImagingFactory = c.GUID{ .Data1 = 0xcacaf262, .Data2 = 0x9370, .Data3 = 0x4615, .Data4 = .{ 0xa1, 0x3b, 0x9f, 0x55, 0x39, 0xda, 0x4c, 0x0a } };
const IID_IWICImagingFactory = c.GUID{ .Data1 = 0xec5ec8a9, .Data2 = 0xc395, .Data3 = 0x4314, .Data4 = .{ 0x9c, 0x77, 0x54, 0xd7, 0xa9, 0x35, 0xff, 0x70 } };
const GUID_WICPixelFormat32bppPBGRA = c.GUID{ .Data1 = 0x6fddc324, .Data2 = 0x4e03, .Data3 = 0x4bfe, .Data4 = .{ 0xb1, 0x85, 0x3d, 0x77, 0x76, 0x8d, 0xc9, 0x10 } };

const D2DERR_RECREATE_TARGET: c.HRESULT = @bitCast(@as(u32, 0x8899000C));
/// D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT (Windows 8.1+): color emoji.
const draw_text_color_font: c.D2D1_DRAW_TEXT_OPTIONS = 4;
const EM_SETCUEBANNER: c.UINT = 0x1501;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("OrielNativeCanvas");
const prop_old_proc = std.unicode.utf8ToUtf16LeStringLiteral("OrielNuiProc");
const prop_node = std.unicode.utf8ToUtf16LeStringLiteral("OrielNuiNode");

// Shared by every window (all on the UI thread).
var d2d: ?*c.ID2D1Factory = null;
var dwrite: ?*c.IDWriteFactory = null;
/// Images (<img>); created on the first one.
var wic: ?*c.IWICImagingFactory = null;
var class_registered = false;

pub const Invoke = *const fn (ctx: ?*anyopaque, engine: *Engine, call_id: u32, cmd: []const u8, args_json: []const u8) void;

const Field = struct {
    hwnd: c.HWND,
    kind: tree_mod.Kind,
    font: ?c.HFONT = null,
    font_px: c_int = 0,
    brush: ?c.HBRUSH = null,
    bg: c.COLORREF = 0xFFFFFF,
    fg: c.COLORREF = 0,
    /// A window region limits it to its scroll containers' visible part.
    clipped: bool = false,
    /// A textarea's placeholder (owned; the cue banner is single-line only),
    /// painted by fieldProc while the field is empty.
    ph: ?[:0]u16 = null,
    ph_hash: u64 = 0,
};

/// An <img>'s picture: decoded once per src (WIC, premultiplied BGRA), and
/// the Direct2D bitmap made from it for the current render target.
const Image = struct {
    src_hash: u64,
    /// Null when it couldn't be decoded or is over the size limit (then w/h
    /// are still its declared size, for layout).
    wic: ?*c.IWICBitmap = null,
    bitmap: ?*c.ID2D1Bitmap = null,
    w: f32 = 0,
    h: f32 = 0,

    fn deinit(img: *Image) void {
        releaseCom(img.bitmap);
        releaseCom(img.wic);
        img.bitmap = null;
        img.wic = null;
    }
};

/// A window's native page: the canvas inside the app's window.
pub const Surface = struct {
    gpa: std.mem.Allocator,
    engine: *Engine = undefined,
    parent: c.HWND,
    hwnd: c.HWND = null,
    rt: ?*c.ID2D1HwndRenderTarget = null,
    brush: ?*c.ID2D1SolidColorBrush = null,
    /// Physical pixels per CSS pixel (the window's DPI / 96).
    scale: f32 = 1,
    /// The window is transparent (WindowOptions.transparent): no white page
    /// under the content.
    transparent: bool = false,
    dark: bool = false,
    fields: std.AutoHashMap(i64, Field),
    /// Decoded pictures by node id (released with the node or a new src).
    images: std.AutoHashMap(i64, Image),
    invoke_fn: Invoke,
    invoke_ctx: ?*anyopaque,
    pointer: [2]f32 = .{ 0, 0 },
    hovered: i64 = 0,
    hand: bool = false,
    tracking: bool = false,
    updating: bool = false,

    /// The canvas fills `parent`'s client area.
    pub fn create(gpa: std.mem.Allocator, assets: []const engine_mod.Asset, platform_json: [:0]const u8, label: [:0]const u8, url: [:0]const u8, parent: *anyopaque, transparent: bool, invoke_fn: Invoke, invoke_ctx: ?*anyopaque) !*Surface {
        try initShared();
        const s = try gpa.create(Surface);
        errdefer gpa.destroy(s);
        const hparent = toHandle(c.HWND, @intFromPtr(parent));
        s.* = .{
            .gpa = gpa,
            .parent = hparent,
            .scale = dpiScale(hparent),
            .transparent = transparent,
            .dark = prefersDark(),
            .fields = .init(gpa),
            .images = .init(gpa),
            .invoke_fn = invoke_fn,
            .invoke_ctx = invoke_ctx,
        };
        errdefer s.fields.deinit();
        errdefer s.images.deinit();
        var rc: c.RECT = undefined;
        _ = c.GetClientRect(hparent, &rc);
        const hinst = c.GetModuleHandleW(null);
        s.hwnd = c.CreateWindowExW(0, class_name, null, c.WS_CHILD | c.WS_VISIBLE | c.WS_CLIPCHILDREN, 0, 0, rc.right - rc.left, rc.bottom - rc.top, hparent, null, hinst, null) orelse return error.CreateWindowFailed;
        errdefer _ = c.DestroyWindow(s.hwnd);
        const w: f32 = @as(f32, @floatFromInt(rc.right - rc.left)) / s.scale;
        const h: f32 = @as(f32, @floatFromInt(rc.bottom - rc.top)) / s.scale;
        s.engine = try Engine.create(gpa, .{
            .ctx = s,
            .measure = measure,
            .laid_out = laidOut,
            .removed = removed,
            .add_timer = addTimer,
            .invoke = invoke,
            .focus = focus,
        }, assets, platform_json, label, url, w, h);
        // Only now may the canvas reach the surface: before, `s.engine` is
        // undefined (and on failure the canvas goes away without it).
        _ = c.SetWindowLongPtrW(s.hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(s)));
        s.engine.boot(s.dark, false);
        return s;
    }

    /// The window goes away: the page, its fields and the canvas.
    pub fn destroy(s: *Surface) void {
        // The canvas stops reaching the surface first: destroying the
        // fields sends it messages (EN_KILLFOCUS, WM_CTLCOLOR*) while the
        // engine goes away, and its timers die with it below.
        _ = c.SetWindowLongPtrW(s.hwnd, c.GWLP_USERDATA, 0);
        // Then the engine: freeing its nodes calls `removed` for the fields.
        s.engine.destroy();
        var it = s.fields.valueIterator();
        while (it.next()) |f| freeField(s, f);
        s.fields.deinit();
        // The target first: it walks the images to drop their bitmaps.
        releaseTarget(s);
        var imgs = s.images.valueIterator();
        while (imgs.next()) |img| img.deinit();
        s.images.deinit();
        _ = c.DestroyWindow(s.hwnd);
        s.gpa.destroy(s);
    }

    /// For WindowHandle.deinit_fn.
    pub fn destroyErased(ctx: *anyopaque) void {
        destroy(@ptrCast(@alignCast(ctx)));
    }

    /// The parent window was resized: fill its client area again.
    pub fn resize(s: *Surface) void {
        var rc: c.RECT = undefined;
        _ = c.GetClientRect(s.parent, &rc);
        const pw = rc.right - rc.left;
        const ph = rc.bottom - rc.top;
        _ = c.MoveWindow(s.hwnd, 0, 0, pw, ph, c.TRUE);
        if (s.rt) |rt| {
            const size: c.D2D1_SIZE_U = .{ .width = @intCast(@max(1, pw)), .height = @intCast(@max(1, ph)) };
            if (rt.lpVtbl.*.Resize.?(rt, &size) < 0) releaseTarget(s);
        }
        s.engine.resize(@as(f32, @floatFromInt(pw)) / s.scale, @as(f32, @floatFromInt(ph)) / s.scale, s.dark);
        _ = c.InvalidateRect(s.hwnd, null, c.FALSE);
    }

    /// Moved to a monitor with another DPI (the parent took its new size).
    pub fn dpiChanged(s: *Surface) void {
        s.scale = dpiScale(s.parent);
        releaseTarget(s); // recreated at the new DPI
        var it = s.fields.valueIterator();
        while (it.next()) |f| f.font_px = 0; // fonts at the new size
        s.resize();
        syncFields(s);
    }

    /// The window got the keyboard focus: give it to the page.
    pub fn takeFocus(s: *Surface) void {
        _ = c.SetFocus(s.hwnd);
    }

    /// A wheel message the parent got (the focus was on it).
    pub fn wheel(s: *Surface, wparam: usize, lparam: isize) void {
        _ = c.SendMessageW(s.hwnd, c.WM_MOUSEWHEEL, wparam, lparam);
    }

    fn prefersDark() bool {
        if (std.c.getenv("ORIEL_COLOR_SCHEME")) |v| return std.mem.eql(u8, std.mem.span(v), "dark");
        var value: c.DWORD = 1;
        var size: c.DWORD = @sizeOf(c.DWORD);
        const key = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize");
        const name = std.unicode.utf8ToUtf16LeStringLiteral("AppsUseLightTheme");
        if (RegGetValueW(HKEY_CURRENT_USER, key, name, c.RRF_RT_REG_DWORD, null, &value, &size) != 0) return false;
        return value == 0;
    }
};

/// A handle (HWND, HDC) from an integer. Handles aren't pointers and
/// needn't be aligned, but the headers type them as pointers to aligned
/// structs: reinterpret the bits instead of a checked @ptrFromInt.
fn toHandle(comptime T: type, v: usize) T {
    const bits = v;
    return @as(*const T, @ptrCast(&bits)).*;
}

/// A length in device pixels: rounded, NaN and infinities (a layout gone
/// wrong) as 0, clamped to what a window can hold. @intFromFloat would panic.
fn px(v: f32) c_int {
    if (!std.math.isFinite(v)) return 0;
    return @intFromFloat(std.math.clamp(@round(v), -1e6, 1e6));
}

fn dpiScale(hwnd: c.HWND) f32 {
    const dpi = c.GetDpiForWindow(hwnd);
    return if (dpi == 0) 1 else @as(f32, @floatFromInt(dpi)) / 96.0;
}

fn initShared() !void {
    if (d2d == null) {
        var f: ?*c.ID2D1Factory = null;
        if (c.D2D1CreateFactory(c.D2D1_FACTORY_TYPE_SINGLE_THREADED, &IID_ID2D1Factory, null, @ptrCast(&f)) < 0 or f == null) return error.Direct2DUnavailable;
        d2d = f;
    }
    if (dwrite == null) {
        var f: ?*c.IDWriteFactory = null;
        if (c.DWriteCreateFactory(c.DWRITE_FACTORY_TYPE_SHARED, &IID_IDWriteFactory, @ptrCast(&f)) < 0 or f == null) return error.DirectWriteUnavailable;
        dwrite = f;
    }
    if (!class_registered) {
        const wc: c.WNDCLASSEXW = .{
            .cbSize = @sizeOf(c.WNDCLASSEXW),
            .style = c.CS_DBLCLKS,
            .lpfnWndProc = canvasProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = c.GetModuleHandleW(null),
            .hIcon = null,
            .hCursor = null, // WM_SETCURSOR picks it
            .hbrBackground = null, // no erase: Direct2D paints everything
            .lpszMenuName = null,
            .lpszClassName = class_name,
            .hIconSm = null,
        };
        if (c.RegisterClassExW(&wc) == 0 and c.GetLastError() != 1410) return error.RegisterClassFailed; // 1410: already registered
        class_registered = true;
    }
}

fn releaseCom(p: anytype) void {
    if (p) |o| {
        const u: *c.IUnknown = @ptrCast(o);
        _ = u.lpVtbl.*.Release.?(u);
    }
}

/// An HWND render target as the ID2D1RenderTarget it derives from.
fn baseRt(rt: *c.ID2D1HwndRenderTarget) *c.ID2D1RenderTarget {
    return @ptrCast(rt);
}

// Pointer-from-integer constants the headers' macros can't translate.
const LoadCursorW = @extern(*const fn (?*anyopaque, usize) callconv(.winapi) ?*anyopaque, .{ .name = "LoadCursorW", .library_name = "user32" });
const RegGetValueW = @extern(*const fn (usize, [*:0]const u16, [*:0]const u16, u32, ?*u32, ?*anyopaque, ?*u32) callconv(.winapi) i32, .{ .name = "RegGetValueW", .library_name = "advapi32" });
const IDC_ARROW: usize = 32512;
const IDC_HAND: usize = 32649;
const HKEY_CURRENT_USER: usize = 0x80000001;

fn releaseTarget(s: *Surface) void {
    // Bitmaps belong to the render target: made again from the WIC copy.
    var imgs = s.images.valueIterator();
    while (imgs.next()) |img| {
        releaseCom(img.bitmap);
        img.bitmap = null;
    }
    releaseCom(s.brush);
    s.brush = null;
    releaseCom(s.rt);
    s.rt = null;
}

fn ensureTarget(s: *Surface) bool {
    if (s.rt != null) return true;
    var rc: c.RECT = undefined;
    _ = c.GetClientRect(s.hwnd, &rc);
    const dpi = 96.0 * s.scale;
    const props: c.D2D1_RENDER_TARGET_PROPERTIES = .{
        .type = c.D2D1_RENDER_TARGET_TYPE_DEFAULT,
        .pixelFormat = .{ .format = c.DXGI_FORMAT_B8G8R8A8_UNORM, .alphaMode = c.D2D1_ALPHA_MODE_PREMULTIPLIED },
        .dpiX = dpi,
        .dpiY = dpi,
        .usage = c.D2D1_RENDER_TARGET_USAGE_NONE,
        .minLevel = c.D2D1_FEATURE_LEVEL_DEFAULT,
    };
    const hprops: c.D2D1_HWND_RENDER_TARGET_PROPERTIES = .{
        .hwnd = s.hwnd,
        .pixelSize = .{ .width = @intCast(@max(1, rc.right - rc.left)), .height = @intCast(@max(1, rc.bottom - rc.top)) },
        .presentOptions = c.D2D1_PRESENT_OPTIONS_NONE,
    };
    const f = d2d.?;
    var rt: ?*c.ID2D1HwndRenderTarget = null;
    if (f.lpVtbl.*.CreateHwndRenderTarget.?(f, &props, &hprops, &rt) < 0 or rt == null) {
        log.err("native ui: Direct2D render target failed", .{});
        return false;
    }
    s.rt = rt;
    var brush: ?*c.ID2D1SolidColorBrush = null;
    const black: c.D2D1_COLOR_F = .{ .r = 0, .g = 0, .b = 0, .a = 1 };
    const base = baseRt(rt.?);
    if (base.lpVtbl.*.CreateSolidColorBrush.?(base, &black, null, &brush) < 0) {
        releaseTarget(s);
        return false;
    }
    s.brush = brush;
    return true;
}

fn surfaceOf(p: ?*anyopaque) *Surface {
    return @ptrCast(@alignCast(p.?));
}

// ---------------------------------------------------------------------------
// Backend hooks

fn invoke(ctx: *anyopaque, engine: *Engine, call_id: u32, cmd: []const u8, args_json: []const u8) void {
    const s = surfaceOf(ctx);
    s.invoke_fn(s.invoke_ctx, engine, call_id, cmd, args_json);
}

fn addTimer(ctx: *anyopaque, _: *Engine, id: u32, ms: u32) void {
    const s = surfaceOf(ctx);
    // Timer ids are the page's (unique per engine); +1 keeps them off 0.
    _ = c.SetTimer(s.hwnd, @as(usize, id) + 1, @max(1, ms), null);
}

fn focus(ctx: *anyopaque, node: *Node) void {
    const s = surfaceOf(ctx);
    if (s.fields.get(node.id)) |f| _ = c.SetFocus(f.hwnd);
}

fn removed(ctx: *anyopaque, node: *Node) void {
    const s = surfaceOf(ctx);
    if (s.images.fetchRemove(node.id)) |kv| {
        var img = kv.value;
        img.deinit();
    }
    if (s.fields.fetchRemove(node.id)) |kv| {
        var f = kv.value;
        freeField(s, &f);
    }
}

fn laidOut(ctx: *anyopaque) void {
    const s = surfaceOf(ctx);
    syncFields(s);
    _ = c.InvalidateRect(s.hwnd, null, c.FALSE);
}

// ---------------------------------------------------------------------------
// Fields: EDIT and COMBOBOX controls for input, textarea and select

fn freeField(s: *Surface, f: *Field) void {
    if (f.ph) |ph| s.gpa.free(ph);
    f.ph = null;
    _ = c.RemovePropW(f.hwnd, prop_node);
    _ = c.DestroyWindow(f.hwnd);
    if (f.font) |h| _ = c.DeleteObject(h);
    if (f.brush) |b| _ = c.DeleteObject(b);
    f.font = null;
    f.brush = null;
}

/// A box the page paints over what came before it (an opaque background),
/// with its place in paint order.
const Occluder = struct { order: u32, rect: Rect };

const PaintOrder = struct {
    occluders: std.ArrayList(Occluder) = .empty,
    /// Fields' places in paint order.
    fields: std.AutoHashMapUnmanaged(i64, u32) = .empty,
    next: u32 = 0,

    fn deinit(po: *PaintOrder, gpa: std.mem.Allocator) void {
        po.occluders.deinit(gpa);
        po.fields.deinit(gpa);
    }

    fn walk(po: *PaintOrder, gpa: std.mem.Allocator, n: *Node) void {
        if (n.props.vis == false) return;
        po.next += 1;
        const order = po.next;
        if (n.kind == .input or n.kind == .textarea or n.kind == .select) po.fields.put(gpa, n.id, order) catch {};
        if (paintsOpaque(n)) po.occluders.append(gpa, .{ .order = order, .rect = n.clip.intersect(n.frame) }) catch {};
        for (n.kids.items) |k| po.walk(gpa, k);
    }

    fn paintsOpaque(n: *Node) bool {
        const bg = n.props.bg orelse return false;
        if ((n.props.op orelse 1) < 0.99) return false;
        if (bg.color) |col| if (col[3] >= 0.99) return true;
        if (bg.gradient) |g| {
            for (g.stops) |st| if (st[3] < 0.99) return false;
            return g.stops.len > 0;
        }
        return false;
    }
};

/// Fields are child windows, always above the canvas: limit each to what
/// the page shows of it, inside its scroll containers and not under boxes
/// painted after it (a footer over scrolled content). Null: all of it.
fn fieldRegion(s: *Surface, po: *const PaintOrder, n: *Node, r: Rect) c.HRGN {
    const vis = n.clip.intersect(r);
    const order = po.fields.get(n.id) orelse 0;
    var covered = false;
    for (po.occluders.items) |o| {
        if (o.order <= order) continue;
        if (o.rect.intersect(vis).w > 0 and o.rect.intersect(vis).h > 0) covered = true;
    }
    if (!covered and vis.w >= r.w - 0.5 and vis.h >= r.h - 0.5) return null;
    const local = struct {
        fn rgn(sc: f32, base: Rect, a: Rect) c.HRGN {
            return c.CreateRectRgn(
                px((a.x - base.x) * sc),
                px((a.y - base.y) * sc),
                px((a.x + a.w - base.x) * sc),
                px((a.y + a.h - base.y) * sc),
            );
        }
    }.rgn;
    const region = local(s.scale, r, vis);
    if (covered) for (po.occluders.items) |o| {
        if (o.order <= order) continue;
        const cut = o.rect.intersect(vis);
        if (cut.w <= 0 or cut.h <= 0) continue;
        const hole = local(s.scale, r, cut);
        _ = c.CombineRgn(region, region, hole, c.RGN_DIFF);
        _ = c.DeleteObject(hole);
    };
    return region;
}

fn syncFields(s: *Surface) void {
    var po: PaintOrder = .{};
    defer po.deinit(s.gpa);
    if (s.engine.tree.root) |root| po.walk(s.gpa, root);
    var it = s.engine.tree.nodes.valueIterator();
    while (it.next()) |np| {
        const n = np.*;
        if (n.kind != .input and n.kind != .textarea and n.kind != .select) continue;
        const gop = s.fields.getOrPut(n.id) catch continue;
        if (!gop.found_existing) {
            gop.value_ptr.* = makeField(s, n) catch {
                s.fields.removeByPtr(gop.key_ptr);
                continue;
            };
        }
        const f = gop.value_ptr;
        s.updating = true;
        defer s.updating = false;
        if (n.pending_value) |v| {
            n.pending_value = null;
            setFieldValue(s, f, n, v);
        }
        _ = c.EnableWindow(f.hwnd, @intFromBool(!n.props.dis));
        styleField(s, f, n);
        if (f.kind == .textarea) setPlaceholder(s, f, n.props.ph orelse "");
        // At the node's content box, in the canvas's physical pixels.
        const r = n.content();
        const visible = n.clip.intersect(n.frame).h > 1 and n.frame.w > 1 and n.props.vis != false;
        if (visible) {
            const x = px(r.x * s.scale);
            const y = px(r.y * s.scale);
            const w: c_int = @max(1, px(r.w * s.scale));
            var h: c_int = @max(1, px(r.h * s.scale));
            // A combobox's height includes its drop-down list.
            if (f.kind == .select) h += px(200 * s.scale);
            _ = c.SetWindowPos(f.hwnd, null, x, y, w, h, c.SWP_NOZORDER | c.SWP_NOACTIVATE | c.SWP_SHOWWINDOW);
            const rgn = fieldRegion(s, &po, n, r);
            if (rgn != null or f.clipped) {
                // The window owns the region from here on.
                _ = c.SetWindowRgn(f.hwnd, rgn, c.TRUE);
                f.clipped = rgn != null;
            }
        } else {
            _ = c.ShowWindow(f.hwnd, c.SW_HIDE);
        }
    }
}

fn setPlaceholder(s: *Surface, f: *Field, ph: []const u8) void {
    const hash = std.hash.Wyhash.hash(1, ph);
    if (hash == f.ph_hash and (f.ph != null) == (ph.len > 0)) return;
    if (f.ph) |old| s.gpa.free(old);
    f.ph = if (ph.len > 0) std.unicode.utf8ToUtf16LeAllocZ(s.gpa, ph) catch null else null;
    f.ph_hash = hash;
    _ = c.InvalidateRect(f.hwnd, null, c.TRUE);
}

/// Half way between two colors (a placeholder: the text color at half
/// strength over the field's background, as a browser shows it).
fn blend(a: c.COLORREF, b: c.COLORREF) c.COLORREF {
    const r = ((a & 0xFF) + (b & 0xFF)) / 2;
    const g = (((a >> 8) & 0xFF) + ((b >> 8) & 0xFF)) / 2;
    const bl = (((a >> 16) & 0xFF) + ((b >> 16) & 0xFF)) / 2;
    return r | (g << 8) | (bl << 16);
}

/// After an empty multi-line field painted itself: its placeholder on top.
fn paintPlaceholder(hwnd: c.HWND) void {
    if (c.GetWindowTextLengthW(hwnd) > 0) return;
    const canvas = c.GetParent(hwnd);
    const p: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(c.GetWindowLongPtrW(canvas, c.GWLP_USERDATA))));
    const s = surfaceOf(p orelse return);
    const fx = fieldOf(s, hwnd) orelse return;
    const ph = fx.field.ph orelse return;
    const hdc = c.GetDC(hwnd) orelse return;
    defer _ = c.ReleaseDC(hwnd, hdc);
    var rc: c.RECT = undefined;
    _ = c.SendMessageW(hwnd, c.EM_GETRECT, 0, @bitCast(@intFromPtr(&rc)));
    const old_font = if (fx.field.font) |font| c.SelectObject(hdc, font) else null;
    defer if (old_font) |o| {
        _ = c.SelectObject(hdc, o);
    };
    _ = c.SetBkMode(hdc, c.TRANSPARENT);
    _ = c.SetTextColor(hdc, blend(fx.field.fg, fx.field.bg));
    _ = c.DrawTextW(hdc, ph.ptr, -1, &rc, c.DT_WORDBREAK | c.DT_NOPREFIX | c.DT_EDITCONTROL);
}

fn makeField(s: *Surface, n: *Node) !Field {
    const class = std.unicode.utf8ToUtf16LeStringLiteral("EDIT");
    const style: c.DWORD = switch (n.kind) {
        .input => @as(c.DWORD, c.WS_CHILD | c.WS_TABSTOP | c.ES_AUTOHSCROLL) | (if (n.props.pw) @as(c.DWORD, c.ES_PASSWORD) else @as(c.DWORD, 0)),
        .textarea => c.WS_CHILD | c.WS_TABSTOP | c.ES_MULTILINE | c.ES_AUTOVSCROLL | c.ES_WANTRETURN,
        .select => c.WS_CHILD | c.WS_TABSTOP | c.CBS_DROPDOWNLIST | c.WS_VSCROLL,
        else => unreachable,
    };
    const cls = if (n.kind == .select) std.unicode.utf8ToUtf16LeStringLiteral("COMBOBOX") else class;
    const hinst = c.GetModuleHandleW(null);
    // In a transparent window GDI's pixels come out with zero alpha (the
    // control would show what's behind the window): there a field is a
    // layered child, composed opaque by DWM (Windows 8+).
    const hwnd: c.HWND = blk: {
        if (s.transparent) {
            if (c.CreateWindowExW(c.WS_EX_LAYERED, cls, null, style, 0, 0, 1, 1, s.hwnd, null, hinst, null)) |h| {
                _ = c.SetLayeredWindowAttributes(h, 0, 255, c.LWA_ALPHA);
                break :blk h;
            }
        }
        break :blk c.CreateWindowExW(0, cls, null, style, 0, 0, 1, 1, s.hwnd, null, hinst, null) orelse return error.CreateWindowFailed;
    };
    errdefer _ = c.DestroyWindow(hwnd);
    _ = c.SetPropW(hwnd, prop_node, @ptrFromInt(@as(usize, @intCast(n.id))));
    switch (n.kind) {
        .input, .textarea => {
            if (n.props.ph) |ph| {
                const w = try std.unicode.utf8ToUtf16LeAllocZ(s.gpa, ph);
                defer s.gpa.free(w);
                _ = c.SendMessageW(hwnd, EM_SETCUEBANNER, c.TRUE, @bitCast(@intFromPtr(w.ptr)));
            }
            // Enter and Escape go to the page first (a form's submit).
            const old = c.SetWindowLongPtrW(hwnd, c.GWLP_WNDPROC, @bitCast(@intFromPtr(&fieldProc)));
            _ = c.SetPropW(hwnd, prop_old_proc, @ptrFromInt(@as(usize, @bitCast(old))));
        },
        .select => if (n.props.options) |opts| for (opts) |o| {
            const w = try std.unicode.utf8ToUtf16LeAllocZ(s.gpa, o[1]);
            defer s.gpa.free(w);
            _ = c.SendMessageW(hwnd, c.CB_ADDSTRING, 0, @bitCast(@intFromPtr(w.ptr)));
        },
        else => {},
    }
    return .{ .hwnd = hwnd, .kind = n.kind };
}

fn setFieldValue(s: *Surface, f: *Field, n: *Node, v: []const u8) void {
    switch (f.kind) {
        .input, .textarea => {
            // EDIT controls want CRLF line ends.
            var crlf: std.ArrayList(u8) = .empty;
            defer crlf.deinit(s.gpa);
            for (v) |ch| {
                if (ch == '\n' and f.kind == .textarea) crlf.append(s.gpa, '\r') catch return;
                crlf.append(s.gpa, ch) catch return;
            }
            const w = std.unicode.utf8ToUtf16LeAllocZ(s.gpa, crlf.items) catch return;
            defer s.gpa.free(w);
            _ = c.SetWindowTextW(f.hwnd, w.ptr);
        },
        .select => if (n.props.options) |opts| for (opts, 0..) |o, i| {
            if (std.mem.eql(u8, o[0], v)) _ = c.SendMessageW(f.hwnd, c.CB_SETCURSEL, i, 0);
        },
        else => {},
    }
}

fn colorRef(col: tree_mod.Color) c.COLORREF {
    const r: u32 = @intFromFloat(@max(0, @min(255, col[0])));
    const g: u32 = @intFromFloat(@max(0, @min(255, col[1])));
    const b: u32 = @intFromFloat(@max(0, @min(255, col[2])));
    return r | (g << 8) | (b << 16);
}

/// The color behind a field: its own background, else the nearest
/// ancestor's opaque one, else the page's.
fn backgroundUnder(s: *Surface, n: *Node) c.COLORREF {
    var p: ?*Node = n;
    while (p) |x| : (p = x.parent) {
        if (x.props.bg) |bg| if (bg.color) |col| if (col[3] > 0.5) return colorRef(col);
    }
    return if (s.dark) 0x202020 else 0xFFFFFF;
}

fn styleField(s: *Surface, f: *Field, n: *Node) void {
    const size = px((n.props.fz orelse 16) * s.scale);
    if (size != f.font_px) {
        const face = std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI");
        const font = c.CreateFontW(-size, 0, 0, 0, c.FW_NORMAL, 0, 0, 0, c.DEFAULT_CHARSET, c.OUT_DEFAULT_PRECIS, c.CLIP_DEFAULT_PRECIS, c.CLEARTYPE_QUALITY, c.DEFAULT_PITCH, face);
        if (font != null) {
            _ = c.SendMessageW(f.hwnd, c.WM_SETFONT, @intFromPtr(font), c.TRUE);
            if (f.font) |old| _ = c.DeleteObject(old);
            f.font = font;
            f.font_px = size;
        }
    }
    const fg = colorRef(n.props.col orelse .{ 0, 0, 0, 1 });
    const bg = backgroundUnder(s, n);
    if (fg != f.fg or bg != f.bg or f.brush == null) {
        f.fg = fg;
        f.bg = bg;
        if (f.brush) |b| _ = c.DeleteObject(b);
        f.brush = c.CreateSolidBrush(bg);
        _ = c.InvalidateRect(f.hwnd, null, c.TRUE);
    }
}

fn fieldOf(s: *Surface, hwnd: c.HWND) ?struct { field: *Field, node: *Node } {
    const id: i64 = @intCast(@intFromPtr(c.GetPropW(hwnd, prop_node) orelse return null));
    const f = s.fields.getPtr(id) orelse return null;
    const n = s.engine.tree.get(id) orelse return null;
    return .{ .field = f, .node = n };
}

fn sendValue(s: *Surface, n: *Node, kind: []const u8, text: []const u8) void {
    const json = std.json.Stringify.valueAlloc(s.gpa, text, .{}) catch return;
    defer s.gpa.free(json);
    _ = s.engine.event(n.id, kind, json);
}

/// A field's text as UTF-8 with \n line ends. Caller frees.
fn fieldText(s: *Surface, hwnd: c.HWND) ?[]u8 {
    const len = c.GetWindowTextLengthW(hwnd);
    const buf = s.gpa.alloc(u16, @intCast(len + 1)) catch return null;
    defer s.gpa.free(buf);
    const got = c.GetWindowTextW(hwnd, buf.ptr, len + 1);
    var out: std.ArrayList(u8) = .empty;
    const utf8 = std.unicode.utf16LeToUtf8Alloc(s.gpa, buf[0..@intCast(got)]) catch return null;
    defer s.gpa.free(utf8);
    for (utf8) |ch| if (ch != '\r') out.append(s.gpa, ch) catch {
        out.deinit(s.gpa);
        return null;
    };
    // On failure the list still owns its buffer.
    return out.toOwnedSlice(s.gpa) catch {
        out.deinit(s.gpa);
        return null;
    };
}

fn onFieldCommand(s: *Surface, code: c.WORD, hwnd: c.HWND) void {
    if (s.updating) return;
    const fx = fieldOf(s, hwnd) orelse return;
    switch (fx.field.kind) {
        .input, .textarea => if (code == c.EN_CHANGE) {
            if (fx.field.kind == .textarea and fx.field.ph != null) _ = c.InvalidateRect(hwnd, null, c.TRUE);
            const text = fieldText(s, hwnd) orelse return;
            defer s.gpa.free(text);
            sendValue(s, fx.node, "input", text);
        },
        .select => if (code == c.CBN_SELCHANGE) {
            const i = c.SendMessageW(hwnd, c.CB_GETCURSEL, 0, 0);
            const opts = fx.node.props.options orelse return;
            if (i < 0 or i >= opts.len) return;
            sendValue(s, fx.node, "change", opts[@intCast(i)][0]);
        },
        else => {},
    }
}

/// Edit controls' window procedure: Enter and Escape go to the page first.
fn fieldProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const old: c.WNDPROC = @ptrCast(c.GetPropW(hwnd, prop_old_proc) orelse return c.DefWindowProcW(hwnd, msg, wparam, lparam));
    switch (msg) {
        c.WM_KEYDOWN => if (wparam == c.VK_RETURN or wparam == c.VK_ESCAPE) {
            const canvas = c.GetParent(hwnd);
            const p: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(c.GetWindowLongPtrW(canvas, c.GWLP_USERDATA))));
            if (p) |sp| {
                const s = surfaceOf(sp);
                if (fieldOf(s, hwnd)) |fx| {
                    // Copied before the page runs: its handler may remove
                    // this field (a submitted form re-rendered), freeing the
                    // map entry and destroying this very window.
                    const id = fx.node.id;
                    const single_line = fx.field.kind == .input;
                    const name = if (wparam == c.VK_RETURN) "Enter" else "Escape";
                    var buf: [48]u8 = undefined;
                    const json = std.fmt.bufPrint(&buf, "[\"{s}\",{d}]", .{ name, modFlags() }) catch "";
                    const prevented = s.engine.event(id, "key", json);
                    // Gone: nothing left to hand the key to.
                    if (c.IsWindow(hwnd) == 0 or c.GetPropW(hwnd, prop_node) == null) return 0;
                    // A single-line field has no use for Enter (it would beep).
                    if (prevented or single_line) return 0;
                }
            }
        },
        c.WM_CHAR => if (wparam == '\r' or wparam == 27) {
            const style: usize = @bitCast(c.GetWindowLongPtrW(hwnd, c.GWL_STYLE));
            if (style & c.ES_MULTILINE == 0) return 0; // no beep
        },
        c.WM_NCDESTROY => {
            _ = c.SetWindowLongPtrW(hwnd, c.GWLP_WNDPROC, @bitCast(@intFromPtr(old)));
            _ = c.RemovePropW(hwnd, prop_old_proc);
        },
        c.WM_PAINT => {
            const r = c.CallWindowProcW(old, hwnd, msg, wparam, lparam);
            const style: usize = @bitCast(c.GetWindowLongPtrW(hwnd, c.GWL_STYLE));
            if (style & c.ES_MULTILINE != 0) paintPlaceholder(hwnd);
            return r;
        },
        else => {},
    }
    return c.CallWindowProcW(old, hwnd, msg, wparam, lparam);
}

// ---------------------------------------------------------------------------
// Input

fn modFlags() u32 {
    var f: u32 = 0;
    if (c.GetKeyState(c.VK_SHIFT) < 0) f |= 1;
    if (c.GetKeyState(c.VK_CONTROL) < 0) f |= 2;
    if (c.GetKeyState(c.VK_MENU) < 0) f |= 4;
    if (c.GetKeyState(c.VK_LWIN) < 0 or c.GetKeyState(c.VK_RWIN) < 0) f |= 8;
    return f;
}

/// The page's key name for a virtual key, for keys that don't type a
/// character (those come as WM_CHAR).
fn keyName(vk: c.WPARAM) ?[]const u8 {
    return switch (vk) {
        c.VK_RETURN => "Enter",
        c.VK_ESCAPE => "Escape",
        c.VK_TAB => "Tab",
        c.VK_BACK => "Backspace",
        c.VK_DELETE => "Delete",
        c.VK_UP => "ArrowUp",
        c.VK_DOWN => "ArrowDown",
        c.VK_LEFT => "ArrowLeft",
        c.VK_RIGHT => "ArrowRight",
        c.VK_HOME => "Home",
        c.VK_END => "End",
        c.VK_PRIOR => "PageUp",
        c.VK_NEXT => "PageDown",
        else => null,
    };
}

fn sendKey(s: *Surface, name: []const u8) bool {
    const key = std.json.Stringify.valueAlloc(s.gpa, name, .{}) catch return false;
    defer s.gpa.free(key);
    var buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "[{s},{d}]", .{ key, modFlags() }) catch return false;
    return s.engine.event(0, "key", json);
}

fn disabledUp(start: *Node) bool {
    var n: ?*Node = start;
    while (n) |x| : (n = x.parent) if (x.props.dis) return true;
    return false;
}

fn clickableUp(start: *Node) bool {
    var n: ?*Node = start;
    while (n) |x| : (n = x.parent) if (x.props.click) return !x.props.dis;
    return false;
}

fn pointOf(s: *Surface, lparam: c.LPARAM) [2]f32 {
    const x: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)))));
    const y: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) >> 16)));
    return .{ @as(f32, @floatFromInt(x)) / s.scale, @as(f32, @floatFromInt(y)) / s.scale };
}

fn onMove(s: *Surface, pt: [2]f32) void {
    s.pointer = pt;
    if (!s.tracking) {
        var tme: c.TRACKMOUSEEVENT = .{ .cbSize = @sizeOf(c.TRACKMOUSEEVENT), .dwFlags = c.TME_LEAVE, .hwndTrack = s.hwnd, .dwHoverTime = 0 };
        s.tracking = c.TrackMouseEvent(&tme) != 0;
    }
    const n = s.engine.tree.hit(pt[0], pt[1]);
    s.hand = n != null and clickableUp(n.?);
    // :hover: the page hears when the node under the pointer changes.
    const id: i64 = if (n) |node| node.id else 0;
    if (id != s.hovered) {
        s.hovered = id;
        _ = s.engine.event(id, "hover", "null");
    }
}

fn onWheel(s: *Surface, wparam: c.WPARAM, lparam: c.LPARAM) void {
    // Wheel positions are in screen coordinates.
    var p: c.POINT = .{
        .x = @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)))))),
        .y = @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) >> 16)))),
    };
    _ = c.ScreenToClient(s.hwnd, &p);
    const pt: [2]f32 = .{ @as(f32, @floatFromInt(p.x)) / s.scale, @as(f32, @floatFromInt(p.y)) / s.scale };
    const delta: i16 = @bitCast(@as(u16, @truncate(wparam >> 16)));
    // 120 per notch; GTK's 48 px per notch, down positive.
    const dy = -@as(f32, @floatFromInt(delta)) / 120.0 * 48.0;
    var target = s.engine.tree.scroller(s.engine.tree.hit(pt[0], pt[1]));
    while (target) |t| {
        if (s.engine.scrollBy(t, dy)) return;
        target = s.engine.tree.scroller(t.parent);
    }
}

fn canvasProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const p: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA))));
    const s = if (p) |sp| surfaceOf(sp) else return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    switch (msg) {
        c.WM_PAINT => {
            var ps: c.PAINTSTRUCT = undefined;
            _ = c.BeginPaint(hwnd, &ps);
            paintAll(s);
            _ = c.EndPaint(hwnd, &ps);
            return 0;
        },
        c.WM_ERASEBKGND => return 1,
        c.WM_TIMER => {
            _ = c.KillTimer(hwnd, wparam);
            // Ours are the page's ids + 1 (addTimer): nothing else is.
            if (wparam == 0 or wparam > std.math.maxInt(u32) + 1) return 0;
            s.engine.timerFired(@intCast(wparam - 1));
            return 0;
        },
        c.WM_LBUTTONDOWN, c.WM_LBUTTONDBLCLK => {
            _ = c.SetFocus(hwnd);
            _ = c.SetCapture(hwnd);
            const pt = pointOf(s, lparam);
            // :active while the button is down.
            if (s.engine.tree.hit(pt[0], pt[1])) |n| _ = s.engine.event(n.id, "press", "null");
            return 0;
        },
        c.WM_LBUTTONUP => {
            _ = c.ReleaseCapture();
            _ = s.engine.event(0, "release", "null");
            const pt = pointOf(s, lparam);
            const n = s.engine.tree.hit(pt[0], pt[1]) orelse return 0;
            if (disabledUp(n)) return 0;
            var buf: [16]u8 = undefined;
            const flags = std.fmt.bufPrint(&buf, "{d}", .{modFlags()}) catch return 0;
            _ = s.engine.event(n.id, "click", flags);
            return 0;
        },
        c.WM_RBUTTONUP => {
            const pt = pointOf(s, lparam);
            const n = s.engine.tree.hit(pt[0], pt[1]) orelse return 0;
            var buf: [64]u8 = undefined;
            const json = std.fmt.bufPrint(&buf, "[{d:.0},{d:.0}]", .{ pt[0], pt[1] }) catch return 0;
            _ = s.engine.event(n.id, "contextmenu", json);
            return 0;
        },
        c.WM_MOUSEMOVE => {
            onMove(s, pointOf(s, lparam));
            return 0;
        },
        c.WM_MOUSELEAVE => {
            s.tracking = false;
            if (s.hovered != 0) {
                s.hovered = 0;
                _ = s.engine.event(0, "hover", "null");
            }
            return 0;
        },
        c.WM_SETCURSOR => if (@as(u16, @truncate(@as(usize, @bitCast(lparam)))) == c.HTCLIENT) {
            _ = c.SetCursor(toHandle(c.HCURSOR, @intFromPtr(LoadCursorW(null, if (s.hand) IDC_HAND else IDC_ARROW))));
            return c.TRUE;
        },
        c.WM_MOUSEWHEEL => {
            onWheel(s, wparam, lparam);
            return 0;
        },
        c.WM_KEYDOWN, c.WM_SYSKEYDOWN => {
            if (keyName(wparam)) |name| {
                if (sendKey(s, name)) return 0;
            } else if (c.GetKeyState(c.VK_CONTROL) < 0 and ((wparam >= 'A' and wparam <= 'Z') or (wparam >= '0' and wparam <= '9'))) {
                // Ctrl+letter types no character: the shortcut as its key.
                const ch: u8 = std.ascii.toLower(@intCast(wparam));
                if (sendKey(s, &.{ch})) return 0;
            }
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        c.WM_CHAR => {
            if (wparam < 0x20 or wparam == 0x7F) return 0; // control characters: WM_KEYDOWN's
            if (c.GetKeyState(c.VK_CONTROL) < 0 and c.GetKeyState(c.VK_MENU) >= 0) return 0;
            var units: [2]u16 = .{ @intCast(wparam & 0xFFFF), 0 };
            var buf: [8]u8 = undefined;
            const len = std.unicode.utf16LeToUtf8(&buf, units[0..1]) catch return 0;
            _ = sendKey(s, buf[0..len]);
            return 0;
        },
        c.WM_COMMAND => {
            if (lparam != 0) onFieldCommand(s, @truncate(wparam >> 16), toHandle(c.HWND, @bitCast(lparam)));
            return 0;
        },
        c.WM_CTLCOLOREDIT, c.WM_CTLCOLORLISTBOX, c.WM_CTLCOLORSTATIC => {
            const field_hwnd = toHandle(c.HWND, @bitCast(lparam));
            const hdc = toHandle(c.HDC, wparam);
            // A combobox's list asks for itself: look at its owner.
            const fx = fieldOf(s, field_hwnd) orelse fieldOf(s, c.GetParent(field_hwnd)) orelse return c.DefWindowProcW(hwnd, msg, wparam, lparam);
            _ = c.SetTextColor(hdc, fx.field.fg);
            _ = c.SetBkColor(hdc, fx.field.bg);
            return @bitCast(@intFromPtr(fx.field.brush orelse return c.DefWindowProcW(hwnd, msg, wparam, lparam)));
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}

// ---------------------------------------------------------------------------
// Text

const Utf16Text = struct {
    text: []u16,
    /// Each run's [start, end) in UTF-16 units.
    ranges: []c.DWRITE_TEXT_RANGE,
};

fn runsUtf16(s: *Surface, runs: []const tree_mod.Run) ?Utf16Text {
    var text: std.ArrayList(u16) = .empty;
    var ranges = s.gpa.alloc(c.DWRITE_TEXT_RANGE, runs.len) catch return null;
    for (runs, 0..) |r, i| {
        const start: u32 = @intCast(text.items.len);
        const w = std.unicode.utf8ToUtf16LeAlloc(s.gpa, r.t) catch {
            text.deinit(s.gpa);
            s.gpa.free(ranges);
            return null;
        };
        defer s.gpa.free(w);
        text.appendSlice(s.gpa, w) catch {
            text.deinit(s.gpa);
            s.gpa.free(ranges);
            return null;
        };
        ranges[i] = .{ .startPosition = start, .length = @as(u32, @intCast(text.items.len)) - start };
    }
    const owned = text.toOwnedSlice(s.gpa) catch {
        text.deinit(s.gpa);
        s.gpa.free(ranges);
        return null;
    };
    return .{ .text = owned, .ranges = ranges };
}

const mono_face = std.unicode.utf8ToUtf16LeStringLiteral("Consolas");
const sans_face = std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI");

/// A DirectWrite layout of a text node's runs at `width` (inf: one line
/// unless it has line breaks). With `rt`, each run's color is set as its
/// drawing effect (brushes released with the layout's caller's list).
fn textLayout(s: *Surface, n: *Node, width: f32, brushes: ?*std.ArrayList(*c.ID2D1SolidColorBrush)) ?*c.IDWriteTextLayout {
    const runs = n.props.runs orelse return null;
    const u = runsUtf16(s, runs) orelse return null;
    defer {
        s.gpa.free(u.text);
        s.gpa.free(u.ranges);
    }
    const dw = dwrite.?;
    const fz = n.props.fz orelse 16;
    var format: ?*c.IDWriteTextFormat = null;
    if (dw.lpVtbl.*.CreateTextFormat.?(dw, if (n.props.mono) mono_face else sans_face, null, c.DWRITE_FONT_WEIGHT_NORMAL, c.DWRITE_FONT_STYLE_NORMAL, c.DWRITE_FONT_STRETCH_NORMAL, fz, std.unicode.utf8ToUtf16LeStringLiteral(""), &format) < 0) return null;
    defer releaseCom(format);
    const nowrap = n.props.nowrap or std.math.isInf(width);
    const max_w: f32 = if (nowrap) 1e6 else @max(1, width);
    var layout: ?*c.IDWriteTextLayout = null;
    if (dw.lpVtbl.*.CreateTextLayout.?(dw, u.text.ptr, @intCast(u.text.len), format, max_w, 1e6, &layout) < 0) return null;
    const l = layout.?;
    const vt = l.lpVtbl.*;
    const fmt: *c.IDWriteTextFormat = @ptrCast(l);
    const fvt = fmt.lpVtbl.*;
    _ = fvt.SetWordWrapping.?(fmt, if (nowrap) c.DWRITE_WORD_WRAPPING_NO_WRAP else c.DWRITE_WORD_WRAPPING_WRAP);
    if (n.props.ta) |ta| {
        const a: c.DWRITE_TEXT_ALIGNMENT = if (std.mem.eql(u8, ta, "center")) c.DWRITE_TEXT_ALIGNMENT_CENTER else if (std.mem.eql(u8, ta, "right") or std.mem.eql(u8, ta, "end")) c.DWRITE_TEXT_ALIGNMENT_TRAILING else c.DWRITE_TEXT_ALIGNMENT_LEADING;
        // A line wider than nothing can't be aligned: only with a width.
        if (!nowrap) _ = fvt.SetTextAlignment.?(fmt, a);
    }
    if (n.props.lh) |lh| _ = fvt.SetLineSpacing.?(fmt, c.DWRITE_LINE_SPACING_METHOD_UNIFORM, lh, lh * 0.8);
    for (runs, u.ranges) |r, range| {
        if (range.length == 0) continue;
        _ = vt.SetFontSize.?(l, r.sz, range);
        _ = vt.SetFontWeight.?(l, @intFromFloat(@max(1, @min(999, r.w))), range);
        if (r.i) _ = vt.SetFontStyle.?(l, c.DWRITE_FONT_STYLE_ITALIC, range);
        if (r.mono) _ = vt.SetFontFamilyName.?(l, mono_face, range);
        if (r.u) _ = vt.SetUnderline.?(l, c.TRUE, range);
        if (brushes) |list| if (s.rt) |hrt| {
            const rt = baseRt(hrt);
            var b: ?*c.ID2D1SolidColorBrush = null;
            const col = d2dColor(r.c);
            if (rt.lpVtbl.*.CreateSolidColorBrush.?(rt, &col, null, &b) >= 0 and b != null) {
                list.append(s.gpa, b.?) catch {
                    releaseCom(b);
                    continue;
                };
                _ = vt.SetDrawingEffect.?(l, @ptrCast(b.?), range);
            }
        };
    }
    return l;
}

// ---------------------------------------------------------------------------
// Images (<img src="data:…"> or an app asset), decoded with WIC

/// The largest picture decoded: 4096 x 4096 px (64 MB as BGRA). Larger ones
/// keep their declared size for layout and aren't drawn.
const max_image_pixels: u64 = 4096 * 4096;

fn wicFactory() ?*c.IWICImagingFactory {
    if (wic) |f| return f;
    // COM on this (the UI) thread; already initialized is fine.
    _ = c.CoInitializeEx(null, c.COINIT_APARTMENTTHREADED);
    var f: ?*c.IWICImagingFactory = null;
    if (c.CoCreateInstance(&CLSID_WICImagingFactory, null, c.CLSCTX_INPROC_SERVER, &IID_IWICImagingFactory, @ptrCast(&f)) < 0) return null;
    wic = f;
    return f;
}

/// The node's picture (decoded on first use and when src changes). The
/// pointer is into `images`: valid until the next insert or removal.
fn imageOf(s: *Surface, n: *Node) ?*Image {
    const src = n.props.src orelse return null;
    const hash = std.hash.Wyhash.hash(0, src);
    if (s.images.getPtr(n.id)) |img| {
        if (img.src_hash == hash) return img;
        img.deinit();
        _ = s.images.remove(n.id);
    }
    var img: Image = decodeImage(s, src) catch |err| blk: {
        log.warn("native ui: image {s}: {s}", .{ src[0..@min(src.len, 48)], @errorName(err) });
        break :blk .{ .src_hash = 0 };
    };
    img.src_hash = hash;
    const gop = s.images.getOrPut(n.id) catch {
        img.deinit();
        return null;
    };
    gop.value_ptr.* = img;
    return gop.value_ptr;
}

fn decodeImage(s: *Surface, src: []const u8) !Image {
    var owned: ?[]u8 = null;
    defer if (owned) |o| s.gpa.free(o);
    const bytes: []const u8 = if (std.mem.startsWith(u8, src, "data:")) blk: {
        const comma = std.mem.indexOfScalar(u8, src, ',') orelse return error.BadDataUri;
        if (std.mem.indexOf(u8, src[0..comma], ";base64") == null) return error.NotBase64;
        const b64 = std.mem.trim(u8, src[comma + 1 ..], " \t\r\n");
        const dec = std.base64.standard.Decoder;
        const buf = try s.gpa.alloc(u8, try dec.calcSizeForSlice(b64));
        owned = buf;
        try dec.decode(buf, b64);
        break :blk buf;
    } else s.engine.assetData(src) orelse return error.AssetNotFound;
    if (bytes.len == 0 or bytes.len > std.math.maxInt(u32)) return error.BadImage;

    const f = wicFactory() orelse return error.WicUnavailable;
    const fv = f.lpVtbl.*;
    // A stream over the bytes (not copied: they outlive the decode below,
    // which copies the pixels into a bitmap of its own).
    var stream: ?*c.IWICStream = null;
    if (fv.CreateStream.?(f, &stream) < 0) return error.WicFailed;
    defer releaseCom(stream);
    if (stream.?.lpVtbl.*.InitializeFromMemory.?(stream, @constCast(bytes.ptr), @intCast(bytes.len)) < 0) return error.WicFailed;
    var decoder: ?*c.IWICBitmapDecoder = null;
    if (fv.CreateDecoderFromStream.?(f, @ptrCast(stream), null, c.WICDecodeMetadataCacheOnDemand, &decoder) < 0) return error.UnknownFormat;
    defer releaseCom(decoder);
    var frame: ?*c.IWICBitmapFrameDecode = null;
    if (decoder.?.lpVtbl.*.GetFrame.?(decoder, 0, &frame) < 0) return error.DecodeFailed;
    defer releaseCom(frame);

    // The declared size first (the header only): a tiny file can declare
    // 30000x30000 px, and decoding it would allocate gigabytes.
    var w: c.UINT = 0;
    var h: c.UINT = 0;
    const frame_src: *c.IWICBitmapSource = @ptrCast(frame.?);
    if (frame_src.lpVtbl.*.GetSize.?(frame_src, &w, &h) < 0 or w == 0 or h == 0) return error.EmptyImage;
    if (@as(u64, w) * @as(u64, h) > max_image_pixels) {
        log.warn("native ui: image {d}x{d} px is over the {d}-pixel limit: not drawn", .{ w, h, max_image_pixels });
        return .{ .src_hash = 0, .w = @floatFromInt(w), .h = @floatFromInt(h) };
    }

    var conv: ?*c.IWICFormatConverter = null;
    if (fv.CreateFormatConverter.?(f, &conv) < 0) return error.WicFailed;
    defer releaseCom(conv);
    if (conv.?.lpVtbl.*.Initialize.?(conv, frame_src, &GUID_WICPixelFormat32bppPBGRA, c.WICBitmapDitherTypeNone, null, 0, c.WICBitmapPaletteTypeCustom) < 0) return error.DecodeFailed;
    // Decoded now, into memory of its own.
    var bmp: ?*c.IWICBitmap = null;
    if (fv.CreateBitmapFromSource.?(f, @ptrCast(conv), c.WICBitmapCacheOnLoad, &bmp) < 0 or bmp == null) return error.DecodeFailed;
    return .{ .src_hash = 0, .wic = bmp, .w = @floatFromInt(w), .h = @floatFromInt(h) };
}

/// Drawn in its content box per CSS object-fit (fill by default).
fn paintImage(p: *Painter, n: *Node) void {
    const img = imageOf(p.s, n) orelse return;
    const wbmp = img.wic orelse return;
    const ct = n.content();
    if (ct.w <= 0 or ct.h <= 0 or img.w <= 0 or img.h <= 0) return;
    const vt = p.vt();
    if (img.bitmap == null) {
        var b: ?*c.ID2D1Bitmap = null;
        if (vt.CreateBitmapFromWicBitmap.?(p.rt, @ptrCast(wbmp), null, &b) < 0) return;
        img.bitmap = b;
    }
    const fit = n.props.fit orelse "fill";
    var kx: f32 = ct.w / img.w;
    var ky: f32 = ct.h / img.h;
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
    const dw = img.w * kx;
    const dh = img.h * ky;
    const dest: c.D2D1_RECT_F = .{ .left = ct.x + (ct.w - dw) / 2, .top = ct.y + (ct.h - dh) / 2, .right = ct.x + (ct.w + dw) / 2, .bottom = ct.y + (ct.h + dh) / 2 };
    const box = rectF(ct);
    vt.PushAxisAlignedClip.?(p.rt, &box, c.D2D1_ANTIALIAS_MODE_ALIASED);
    defer vt.PopAxisAlignedClip.?(p.rt);
    vt.DrawBitmap.?(p.rt, img.bitmap, &dest, 1, c.D2D1_BITMAP_INTERPOLATION_MODE_LINEAR, null);
}

// ---------------------------------------------------------------------------
// Default checkbox and radio (an <input> without appearance: none)

/// An outlined box/circle, filled with the accent color (or a blue default)
/// and a white mark when checked; dimmed when disabled (as gtk.zig draws it).
fn paintControl(p: *Painter, n: *Node) void {
    const fr = n.frame;
    const size = @min(fr.w, fr.h);
    if (size <= 0) return;
    const x = fr.x + (fr.w - size) / 2;
    const y = fr.y + (fr.h - size) / 2;
    const radio = std.mem.eql(u8, n.props.ctl.?, "radio");
    const acc = n.props.acc orelse tree_mod.Color{ 59, 108, 255, 1 };
    const alpha: f32 = if (n.props.dis) 0.45 else 1;
    const vt = p.vt();
    const circle: c.D2D1_ELLIPSE = .{ .point = .{ .x = x + size / 2, .y = y + size / 2 }, .radiusX = size / 2 - 0.5, .radiusY = size / 2 - 0.5 };
    const box: c.D2D1_ROUNDED_RECT = .{ .rect = .{ .left = x + 0.5, .top = y + 0.5, .right = x + size - 0.5, .bottom = y + size - 0.5 }, .radiusX = 2.5, .radiusY = 2.5 };
    if (n.props.on) {
        const fill = p.solid(.{ acc[0], acc[1], acc[2], acc[3] * alpha });
        if (radio) vt.FillEllipse.?(p.rt, &circle, fill) else vt.FillRoundedRectangle.?(p.rt, &box, fill);
        const white = p.solid(.{ 255, 255, 255, alpha });
        if (radio) {
            const dot: c.D2D1_ELLIPSE = .{ .point = circle.point, .radiusX = size * 0.2, .radiusY = size * 0.2 };
            vt.FillEllipse.?(p.rt, &dot, white);
        } else {
            const st = strokeStyle("round", "round");
            defer releaseCom(st);
            const sw = @max(1.5, size * 0.13);
            const a: c.D2D1_POINT_2F = .{ .x = x + size * 0.25, .y = y + size * 0.52 };
            const b: c.D2D1_POINT_2F = .{ .x = x + size * 0.43, .y = y + size * 0.7 };
            const e: c.D2D1_POINT_2F = .{ .x = x + size * 0.76, .y = y + size * 0.32 };
            vt.DrawLine.?(p.rt, a, b, white, sw, st);
            vt.DrawLine.?(p.rt, b, e, white, sw, st);
        }
    } else {
        const white = p.solid(.{ 255, 255, 255, alpha });
        if (radio) vt.FillEllipse.?(p.rt, &circle, white) else vt.FillRoundedRectangle.?(p.rt, &box, white);
        const grey = p.solid(.{ 118, 118, 118, alpha });
        if (radio) vt.DrawEllipse.?(p.rt, &circle, grey, 1, null) else vt.DrawRoundedRectangle.?(p.rt, &box, grey, 1, null);
    }
}

fn measure(ctx: *anyopaque, n: *Node, max_width: f32, out: *[2]f32) void {
    const s = surfaceOf(ctx);
    const fz = n.props.fz orelse 16;
    switch (n.kind) {
        .text => {
            const layout = textLayout(s, n, max_width, null) orelse return;
            defer releaseCom(@as(?*c.IDWriteTextLayout, layout));
            var m: c.DWRITE_TEXT_METRICS = undefined;
            if (layout.lpVtbl.*.GetMetrics.?(layout, &m) < 0) return;
            out.* = .{ @ceil(m.widthIncludingTrailingWhitespace) + 1, @ceil(m.height) };
        },
        .input, .select => out.* = .{ if (std.math.isInf(max_width)) 150 else @min(max_width, 150), @round(fz * 1.45) },
        .textarea => out.* = .{ if (std.math.isInf(max_width)) 200 else max_width, @round(fz * 1.45 * 2) },
        .image => {
            // Its natural size, scaled down to the width it may take.
            const img = imageOf(s, n) orelse return;
            if (img.w <= 0 or img.h <= 0) return;
            const k: f32 = if (!std.math.isInf(max_width) and max_width < img.w) max_width / img.w else 1;
            out.* = .{ img.w * k, img.h * k };
        },
        else => out.* = .{ 0, 0 },
    }
}

// ---------------------------------------------------------------------------
// Drawing

fn d2dColor(col: tree_mod.Color) c.D2D1_COLOR_F {
    return .{ .r = col[0] / 255, .g = col[1] / 255, .b = col[2] / 255, .a = @max(0, @min(1, col[3])) };
}

fn rectF(r: Rect) c.D2D1_RECT_F {
    return .{ .left = r.x, .top = r.y, .right = r.x + r.w, .bottom = r.y + r.h };
}

const identity: c.D2D1_MATRIX_3X2_F = matrix(1, 0, 0, 1, 0, 0);

fn matrix(a: f32, b: f32, cc: f32, d: f32, e: f32, f: f32) c.D2D1_MATRIX_3X2_F {
    var m: c.D2D1_MATRIX_3X2_F = undefined;
    @as(*[6]f32, @ptrCast(&m)).* = .{ a, b, cc, d, e, f };
    return m;
}

fn mget(m: c.D2D1_MATRIX_3X2_F) [6]f32 {
    return @as(*const [6]f32, @ptrCast(&m)).*;
}

/// `a` then `b` (row vectors: p * a * b).
fn mul(a: c.D2D1_MATRIX_3X2_F, b: c.D2D1_MATRIX_3X2_F) c.D2D1_MATRIX_3X2_F {
    const x = mget(a);
    const y = mget(b);
    return matrix(
        x[0] * y[0] + x[1] * y[2],
        x[0] * y[1] + x[1] * y[3],
        x[2] * y[0] + x[3] * y[2],
        x[2] * y[1] + x[3] * y[3],
        x[4] * y[0] + x[5] * y[2] + y[4],
        x[4] * y[1] + x[5] * y[3] + y[5],
    );
}

const Painter = struct {
    s: *Surface,
    rt: *c.ID2D1RenderTarget,
    brush: *c.ID2D1SolidColorBrush,
    xf: c.D2D1_MATRIX_3X2_F = identity,

    fn vt(p: *Painter) c.ID2D1RenderTargetVtbl {
        return p.rt.lpVtbl.*;
    }

    fn solid(p: *Painter, col: tree_mod.Color) *c.ID2D1Brush {
        const v = d2dColor(col);
        p.brush.lpVtbl.*.SetColor.?(p.brush, &v);
        return @ptrCast(p.brush);
    }

    fn setTransform(p: *Painter, m: c.D2D1_MATRIX_3X2_F) void {
        p.xf = m;
        p.vt().SetTransform.?(p.rt, &m);
    }
};

fn paintAll(s: *Surface) void {
    if (s.engine.tree.dirty) s.engine.tree.layout();
    if (!ensureTarget(s)) return;
    const hrt = s.rt.?;
    const rt: *c.ID2D1RenderTarget = @ptrCast(hrt);
    const vt = rt.lpVtbl.*;
    vt.BeginDraw.?(rt);
    vt.SetTransform.?(rt, &identity);
    // Under the page: white, as in a browser (the root's background, if any,
    // is painted over it); nothing in a transparent window.
    const under: c.D2D1_COLOR_F = if (s.transparent) .{ .r = 0, .g = 0, .b = 0, .a = 0 } else .{ .r = 1, .g = 1, .b = 1, .a = 1 };
    vt.Clear.?(rt, &under);
    if (s.engine.tree.root) |root| {
        var p: Painter = .{ .s = s, .rt = rt, .brush = s.brush.? };
        paint(&p, root);
    }
    const hr = vt.EndDraw.?(rt, null, null);
    if (hr == D2DERR_RECREATE_TARGET) {
        releaseTarget(s);
        _ = c.InvalidateRect(s.hwnd, null, c.FALSE);
    }
}

fn paint(p: *Painter, n: *Node) void {
    const props = n.props;
    if (props.vis == false) return;
    const f = n.frame;
    const visible = n.clip.intersect(.{ .x = f.x - 40, .y = f.y - 40, .w = f.w + 80, .h = f.h + 80 });
    if ((visible.w <= 0 or visible.h <= 0) and n.kids.items.len == 0) return;
    const vt = p.vt();
    const clip = rectF(n.clip);
    vt.PushAxisAlignedClip.?(p.rt, &clip, c.D2D1_ANTIALIAS_MODE_ALIASED);
    defer vt.PopAxisAlignedClip.?(p.rt);
    // scale and rotate: around the box's center, for it and its children.
    const saved = p.xf;
    defer p.setTransform(saved);
    const sc = props.sc orelse 1;
    const rot = props.rot orelse 0;
    if (sc != 1 or rot != 0) {
        const cx = f.x + f.w / 2;
        const cy = f.y + f.h / 2;
        const a = rot * std.math.pi / 180.0;
        const cs = @cos(a) * sc;
        const sn = @sin(a) * sc;
        // Translate to the center, rotate and scale, translate back.
        const local = mul(mul(matrix(1, 0, 0, 1, -cx, -cy), matrix(cs, sn, -sn, cs, 0, 0)), matrix(1, 0, 0, 1, cx, cy));
        p.setTransform(mul(local, saved));
    }
    const alpha = props.op orelse 1;
    if (alpha < 1) {
        const params: c.D2D1_LAYER_PARAMETERS = .{
            .contentBounds = .{ .left = -1e6, .top = -1e6, .right = 1e6, .bottom = 1e6 },
            .geometricMask = null,
            .maskAntialiasMode = c.D2D1_ANTIALIAS_MODE_PER_PRIMITIVE,
            .maskTransform = identity,
            .opacity = @max(0, alpha),
            .opacityBrush = null,
            .layerOptions = c.D2D1_LAYER_OPTIONS_NONE,
        };
        vt.PushLayer.?(p.rt, &params, null);
    }
    defer if (alpha < 1) vt.PopLayer.?(p.rt);

    const r = n.radius();
    if (props.sh) |sh| shadow(p, f, r, sh);
    if (props.bg) |bg| {
        // The color under the gradient (CSS layers).
        if (bg.color) |col| fillShape(p, f, r, p.solid(col));
        if (bg.gradient) |g| if (gradientBrush(p, f, g)) |gb| {
            fillShape(p, f, r, gb);
            releaseCom(@as(?*c.ID2D1Brush, gb));
        };
    }
    if (props.bw) |bw| border(p, f, r, bw, props.bc);
    switch (n.kind) {
        .text => paintText(p, n),
        .icon => paintIcon(p, n),
        .image => paintImage(p, n),
        .view => if (n.props.ctl != null) paintControl(p, n),
        else => {},
    }
    for (n.kids.items) |k| paint(p, k);
}

fn uniform(r: [4]f32) bool {
    return r[0] == r[1] and r[1] == r[2] and r[2] == r[3];
}

/// A box with per-corner radii (top-left, top-right, bottom-right,
/// bottom-left) as a path geometry. Caller releases.
fn roundRectGeometry(f: Rect, r: [4]f32) ?*c.ID2D1PathGeometry {
    const fac = d2d.?;
    var geo: ?*c.ID2D1PathGeometry = null;
    if (fac.lpVtbl.*.CreatePathGeometry.?(fac, &geo) < 0) return null;
    var sink: ?*c.ID2D1GeometrySink = null;
    if (geo.?.lpVtbl.*.Open.?(geo, &sink) < 0) {
        releaseCom(geo);
        return null;
    }
    const sk = sink.?;
    const v = sk.lpVtbl.*;
    const simple: *c.ID2D1SimplifiedGeometrySink = @ptrCast(sk);
    const sv = simple.lpVtbl.*;
    const x = f.x;
    const y = f.y;
    const w = f.w;
    const h = f.h;
    sv.BeginFigure.?(simple, .{ .x = x + r[0], .y = y }, c.D2D1_FIGURE_BEGIN_FILLED);
    const corner = struct {
        fn add(s: *c.ID2D1GeometrySink, rad: f32, to: c.D2D1_POINT_2F) void {
            if (rad <= 0) {
                s.lpVtbl.*.AddLine.?(s, to);
                return;
            }
            const arc: c.D2D1_ARC_SEGMENT = .{ .point = to, .size = .{ .width = rad, .height = rad }, .rotationAngle = 0, .sweepDirection = c.D2D1_SWEEP_DIRECTION_CLOCKWISE, .arcSize = c.D2D1_ARC_SIZE_SMALL };
            s.lpVtbl.*.AddArc.?(s, &arc);
        }
    }.add;
    v.AddLine.?(sk, .{ .x = x + w - r[1], .y = y });
    corner(sk, r[1], .{ .x = x + w, .y = y + r[1] });
    v.AddLine.?(sk, .{ .x = x + w, .y = y + h - r[2] });
    corner(sk, r[2], .{ .x = x + w - r[2], .y = y + h });
    v.AddLine.?(sk, .{ .x = x + r[3], .y = y + h });
    corner(sk, r[3], .{ .x = x, .y = y + h - r[3] });
    v.AddLine.?(sk, .{ .x = x, .y = y + r[0] });
    corner(sk, r[0], .{ .x = x + r[0], .y = y });
    sv.EndFigure.?(simple, c.D2D1_FIGURE_END_CLOSED);
    _ = sv.Close.?(simple);
    releaseCom(sink);
    return geo;
}

/// A filled triangle as a path geometry (a border side's mask). Caller
/// releases.
fn triangleGeometry(a: c.D2D1_POINT_2F, b: c.D2D1_POINT_2F, d: c.D2D1_POINT_2F) ?*c.ID2D1PathGeometry {
    const fac = d2d.?;
    var geo: ?*c.ID2D1PathGeometry = null;
    if (fac.lpVtbl.*.CreatePathGeometry.?(fac, &geo) < 0) return null;
    var sink: ?*c.ID2D1GeometrySink = null;
    if (geo.?.lpVtbl.*.Open.?(geo, &sink) < 0) {
        releaseCom(geo);
        return null;
    }
    const simple: *c.ID2D1SimplifiedGeometrySink = @ptrCast(sink.?);
    const sv = simple.lpVtbl.*;
    sv.BeginFigure.?(simple, a, c.D2D1_FIGURE_BEGIN_FILLED);
    const pts = [2]c.D2D1_POINT_2F{ b, d };
    sv.AddLines.?(simple, &pts, pts.len);
    sv.EndFigure.?(simple, c.D2D1_FIGURE_END_CLOSED);
    _ = sv.Close.?(simple);
    releaseCom(sink);
    return geo;
}

fn fillShape(p: *Painter, f: Rect, r: [4]f32, brush: *c.ID2D1Brush) void {
    if (f.w <= 0 or f.h <= 0) return;
    const vt = p.vt();
    if (uniform(r)) {
        if (r[0] <= 0) {
            const rc = rectF(f);
            vt.FillRectangle.?(p.rt, &rc, brush);
        } else {
            const rr: c.D2D1_ROUNDED_RECT = .{ .rect = rectF(f), .radiusX = r[0], .radiusY = r[0] };
            vt.FillRoundedRectangle.?(p.rt, &rr, brush);
        }
        return;
    }
    const geo = roundRectGeometry(f, r) orelse return;
    defer releaseCom(@as(?*c.ID2D1PathGeometry, geo));
    vt.FillGeometry.?(p.rt, @ptrCast(geo), brush, null);
}

fn strokeShape(p: *Painter, f: Rect, r: [4]f32, brush: *c.ID2D1Brush, width: f32) void {
    if (f.w <= 0 or f.h <= 0) return;
    const vt = p.vt();
    if (uniform(r)) {
        if (r[0] <= 0) {
            const rc = rectF(f);
            vt.DrawRectangle.?(p.rt, &rc, brush, width, null);
        } else {
            const rr: c.D2D1_ROUNDED_RECT = .{ .rect = rectF(f), .radiusX = r[0], .radiusY = r[0] };
            vt.DrawRoundedRectangle.?(p.rt, &rr, brush, width, null);
        }
        return;
    }
    const geo = roundRectGeometry(f, r) orelse return;
    defer releaseCom(@as(?*c.ID2D1PathGeometry, geo));
    vt.DrawGeometry.?(p.rt, @ptrCast(geo), brush, width, null);
}

/// A gradient length: px, or "50%" of `total`.
fn boxLen(v: tree_mod.Dim, total: f32) f32 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |x| @floatCast(x),
        .string => |str| if (std.mem.endsWith(u8, str, "%")) (std.fmt.parseFloat(f32, str[0 .. str.len - 1]) catch 0) / 100 * total else 0,
        else => 0,
    };
}

/// A brush for a CSS gradient over `f`. Caller releases.
fn gradientBrush(p: *Painter, f: Rect, g: tree_mod.Gradient) ?*c.ID2D1Brush {
    if (g.stops.len == 0) return null;
    var stops_buf: [16]c.D2D1_GRADIENT_STOP = undefined;
    const count = @min(g.stops.len, stops_buf.len);
    for (g.stops[0..count], 0..) |st, i| stops_buf[i] = .{ .position = st[4], .color = d2dColor(.{ st[0], st[1], st[2], st[3] }) };
    const vt = p.vt();
    var coll: ?*c.ID2D1GradientStopCollection = null;
    if (vt.CreateGradientStopCollection.?(p.rt, &stops_buf, @intCast(count), c.D2D1_GAMMA_2_2, c.D2D1_EXTEND_MODE_CLAMP, &coll) < 0) return null;
    defer releaseCom(coll);
    if (g.radial) |rad| {
        const props: c.D2D1_RADIAL_GRADIENT_BRUSH_PROPERTIES = .{
            .center = .{ .x = f.x + boxLen(rad[0], f.w), .y = f.y + boxLen(rad[1], f.h) },
            .gradientOriginOffset = .{ .x = 0, .y = 0 },
            .radiusX = @max(0.01, boxLen(rad[2], f.w)),
            .radiusY = @max(0.01, boxLen(rad[3], f.h)),
        };
        var b: ?*c.ID2D1RadialGradientBrush = null;
        if (vt.CreateRadialGradientBrush.?(p.rt, &props, null, coll, &b) < 0) return null;
        return @ptrCast(b);
    }
    // CSS angles: 0deg points up, clockwise; the gradient line spans the box.
    const a = g.angle * std.math.pi / 180.0;
    const dx = @sin(a);
    const dy = -@cos(a);
    const len = @abs(f.w * dx) + @abs(f.h * dy);
    const cx = f.x + f.w / 2;
    const cy = f.y + f.h / 2;
    const props: c.D2D1_LINEAR_GRADIENT_BRUSH_PROPERTIES = .{
        .startPoint = .{ .x = cx - dx * len / 2, .y = cy - dy * len / 2 },
        .endPoint = .{ .x = cx + dx * len / 2, .y = cy + dy * len / 2 },
    };
    var b: ?*c.ID2D1LinearGradientBrush = null;
    if (vt.CreateLinearGradientBrush.?(p.rt, &props, null, coll, &b) < 0) return null;
    return @ptrCast(b);
}

fn border(p: *Painter, f: Rect, r: [4]f32, bw: [4]f32, bc: ?[4]tree_mod.Color) void {
    const colors = bc orelse return;
    if (uniform(bw) and bw[0] > 0) {
        const half = bw[0] / 2;
        const inner: Rect = .{ .x = f.x + half, .y = f.y + half, .w = f.w - bw[0], .h = f.h - bw[0] };
        var ri = r;
        for (&ri) |*x| x.* = @max(0, x.* - half);
        const same = for (colors[1..]) |col| {
            if (!std.mem.eql(f32, &col, &colors[0])) break false;
        } else true;
        if (same) {
            strokeShape(p, inner, ri, p.solid(colors[0]), bw[0]);
            return;
        }
        // Sides in different colors (a spinner: border-top-color on a grey
        // ring): the rounded border stroked once per side, masked to that
        // side's wedge (its two corners and the box's center), so the
        // colors meet on the diagonals, as in CSS.
        const center: c.D2D1_POINT_2F = .{ .x = f.x + f.w / 2, .y = f.y + f.h / 2 };
        const corners = [4]c.D2D1_POINT_2F{
            .{ .x = f.x, .y = f.y },
            .{ .x = f.x + f.w, .y = f.y },
            .{ .x = f.x + f.w, .y = f.y + f.h },
            .{ .x = f.x, .y = f.y + f.h },
        };
        const vt = p.vt();
        for (0..4) |i| {
            if (colors[i][3] <= 0) continue;
            const wedge = triangleGeometry(corners[i], corners[(i + 1) % 4], center) orelse continue;
            defer releaseCom(@as(?*c.ID2D1PathGeometry, wedge));
            const params: c.D2D1_LAYER_PARAMETERS = .{
                .contentBounds = .{ .left = -1e6, .top = -1e6, .right = 1e6, .bottom = 1e6 },
                .geometricMask = @ptrCast(wedge),
                .maskAntialiasMode = c.D2D1_ANTIALIAS_MODE_PER_PRIMITIVE,
                .maskTransform = identity,
                .opacity = 1,
                .opacityBrush = null,
                .layerOptions = c.D2D1_LAYER_OPTIONS_NONE,
            };
            vt.PushLayer.?(p.rt, &params, null);
            strokeShape(p, inner, ri, p.solid(colors[i]), bw[0]);
            vt.PopLayer.?(p.rt);
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
        const rc = rectF(sd);
        p.vt().FillRectangle.?(p.rt, &rc, p.solid(colors[i]));
    }
}

fn shadow(p: *Painter, f: Rect, r: [4]f32, sh: tree_mod.Shadow) void {
    // A soft shadow from stacked layers, from half the blur inside the box
    // to half outside (as GTK draws it): the box's edge gets half the color
    // and the shadow fades out over the blur distance.
    const steps: usize = 8;
    var i: usize = 0;
    while (i < steps) : (i += 1) {
        const t: f32 = (@as(f32, @floatFromInt(i)) + 0.5) / @as(f32, @floatFromInt(steps));
        const grow = sh.spread + sh.blur * (t - 0.5);
        const rect: Rect = .{ .x = f.x + sh.x - grow, .y = f.y + sh.y - grow, .w = f.w + 2 * grow, .h = f.h + 2 * grow };
        if (rect.w <= 0 or rect.h <= 0) continue;
        var rr = r;
        for (&rr) |*x| x.* = @max(0, x.* + grow);
        var col = sh.color;
        col[3] = sh.color[3] / @as(f32, @floatFromInt(steps));
        fillShape(p, rect, rr, p.solid(col));
    }
}

fn paintText(p: *Painter, n: *Node) void {
    const s = p.s;
    const ct = n.content();
    var brushes: std.ArrayList(*c.ID2D1SolidColorBrush) = .empty;
    defer {
        for (brushes.items) |b| releaseCom(@as(?*c.ID2D1SolidColorBrush, b));
        brushes.deinit(s.gpa);
    }
    const layout = textLayout(s, n, ct.w + 1, &brushes) orelse return;
    defer releaseCom(@as(?*c.IDWriteTextLayout, layout));
    // Run backgrounds (marks, code), behind the text.
    if (n.props.runs) |runs| {
        var pos: u32 = 0;
        for (runs) |r| {
            const w16: u32 = @intCast(std.unicode.calcUtf16LeLen(r.t) catch r.t.len);
            defer pos += w16;
            const bg = r.bg orelse continue;
            if (bg[3] <= 0 or w16 == 0) continue;
            var rects: [16]c.DWRITE_HIT_TEST_METRICS = undefined;
            var count: u32 = 0;
            if (layout.lpVtbl.*.HitTestTextRange.?(layout, pos, w16, ct.x, ct.y, &rects, rects.len, &count) < 0) continue;
            for (rects[0..@min(count, rects.len)]) |m| {
                const rc: c.D2D1_RECT_F = .{ .left = m.left, .top = m.top, .right = m.left + m.width, .bottom = m.top + m.height };
                p.vt().FillRectangle.?(p.rt, &rc, p.solid(bg));
            }
        }
    }
    // Runs without a color of their own (none: each run sets one) use black.
    const origin: c.D2D1_POINT_2F = .{ .x = ct.x, .y = ct.y };
    p.vt().DrawTextLayout.?(p.rt, origin, layout, p.solid(.{ 0, 0, 0, 1 }), draw_text_color_font);
}

/// Feeds svg_path's commands into a Direct2D geometry sink.
const PathSink = struct {
    sink: *c.ID2D1GeometrySink,
    open: bool = false,
    filled: bool,
    x: f32 = 0,
    y: f32 = 0,
    sx: f32 = 0,
    sy: f32 = 0,

    fn simple(ps: *PathSink) *c.ID2D1SimplifiedGeometrySink {
        return @ptrCast(ps.sink);
    }
    fn begin(ps: *PathSink) void {
        if (ps.open) return;
        ps.simple().lpVtbl.*.BeginFigure.?(ps.simple(), .{ .x = ps.x, .y = ps.y }, if (ps.filled) c.D2D1_FIGURE_BEGIN_FILLED else c.D2D1_FIGURE_BEGIN_HOLLOW);
        ps.open = true;
    }
    fn end(ps: *PathSink, closed: bool) void {
        if (!ps.open) return;
        ps.simple().lpVtbl.*.EndFigure.?(ps.simple(), if (closed) c.D2D1_FIGURE_END_CLOSED else c.D2D1_FIGURE_END_OPEN);
        ps.open = false;
    }
    pub fn move(ps: *PathSink, x: f32, y: f32) void {
        ps.end(false);
        ps.x = x;
        ps.y = y;
        ps.sx = x;
        ps.sy = y;
    }
    pub fn line(ps: *PathSink, x: f32, y: f32) void {
        ps.begin();
        ps.sink.lpVtbl.*.AddLine.?(ps.sink, .{ .x = x, .y = y });
        ps.x = x;
        ps.y = y;
    }
    pub fn cubic(ps: *PathSink, x1: f32, y1: f32, x2: f32, y2: f32, x: f32, y: f32) void {
        ps.begin();
        const seg: c.D2D1_BEZIER_SEGMENT = .{ .point1 = .{ .x = x1, .y = y1 }, .point2 = .{ .x = x2, .y = y2 }, .point3 = .{ .x = x, .y = y } };
        ps.sink.lpVtbl.*.AddBezier.?(ps.sink, &seg);
        ps.x = x;
        ps.y = y;
    }
    pub fn quad(ps: *PathSink, x1: f32, y1: f32, x: f32, y: f32) void {
        ps.begin();
        const seg: c.D2D1_QUADRATIC_BEZIER_SEGMENT = .{ .point1 = .{ .x = x1, .y = y1 }, .point2 = .{ .x = x, .y = y } };
        ps.sink.lpVtbl.*.AddQuadraticBezier.?(ps.sink, &seg);
        ps.x = x;
        ps.y = y;
    }
    pub fn arc(ps: *PathSink, rx: f32, ry: f32, rot: f32, large: bool, sweep: bool, x: f32, y: f32) void {
        if (rx == 0 or ry == 0) return ps.line(x, y);
        ps.begin();
        // y points down: SVG's positive-angle sweep is clockwise on screen.
        const a: c.D2D1_ARC_SEGMENT = .{
            .point = .{ .x = x, .y = y },
            .size = .{ .width = rx, .height = ry },
            .rotationAngle = rot,
            .sweepDirection = if (sweep) c.D2D1_SWEEP_DIRECTION_CLOCKWISE else c.D2D1_SWEEP_DIRECTION_COUNTER_CLOCKWISE,
            .arcSize = if (large) c.D2D1_ARC_SIZE_LARGE else c.D2D1_ARC_SIZE_SMALL,
        };
        ps.sink.lpVtbl.*.AddArc.?(ps.sink, &a);
        ps.x = x;
        ps.y = y;
    }
    pub fn close(ps: *PathSink) void {
        ps.end(true);
        ps.x = ps.sx;
        ps.y = ps.sy;
    }
};

/// svg_path's sink (f64; arcs already turned into cubics) onto PathSink.
const S = struct {
    fn f(v: f64) f32 {
        return @floatCast(v);
    }
    fn move(ps: *PathSink, x: f64, y: f64) void {
        ps.move(f(x), f(y));
    }
    fn line(ps: *PathSink, x: f64, y: f64) void {
        ps.line(f(x), f(y));
    }
    fn cubic(ps: *PathSink, x1: f64, y1: f64, x2: f64, y2: f64, x: f64, y: f64) void {
        ps.cubic(f(x1), f(y1), f(x2), f(y2), f(x), f(y));
    }
    fn quad(ps: *PathSink, x1: f64, y1: f64, x: f64, y: f64) void {
        ps.quad(f(x1), f(y1), f(x), f(y));
    }
    fn close(ps: *PathSink) void {
        ps.close();
    }
};

fn pathGeometry(d: []const u8, filled: bool, evenodd: bool) ?*c.ID2D1PathGeometry {
    const fac = d2d.?;
    var geo: ?*c.ID2D1PathGeometry = null;
    if (fac.lpVtbl.*.CreatePathGeometry.?(fac, &geo) < 0) return null;
    var sink: ?*c.ID2D1GeometrySink = null;
    if (geo.?.lpVtbl.*.Open.?(geo, &sink) < 0) {
        releaseCom(geo);
        return null;
    }
    defer releaseCom(sink);
    var ps: PathSink = .{ .sink = sink.?, .filled = filled };
    ps.simple().lpVtbl.*.SetFillMode.?(ps.simple(), if (evenodd) c.D2D1_FILL_MODE_ALTERNATE else c.D2D1_FILL_MODE_WINDING);
    _ = svg_path.parse(*PathSink, d, .{
        .ctx = &ps,
        .move = S.move,
        .line = S.line,
        .cubic = S.cubic,
        .quad = S.quad,
        .close = S.close,
    });
    ps.end(false);
    if (ps.simple().lpVtbl.*.Close.?(ps.simple()) < 0) {
        releaseCom(geo);
        return null;
    }
    return geo;
}

fn strokeStyle(cap: []const u8, join: []const u8) ?*c.ID2D1StrokeStyle {
    const capv: c.D2D1_CAP_STYLE = if (std.mem.eql(u8, cap, "round")) c.D2D1_CAP_STYLE_ROUND else if (std.mem.eql(u8, cap, "square")) c.D2D1_CAP_STYLE_SQUARE else c.D2D1_CAP_STYLE_FLAT;
    const joinv: c.D2D1_LINE_JOIN = if (std.mem.eql(u8, join, "round")) c.D2D1_LINE_JOIN_ROUND else if (std.mem.eql(u8, join, "bevel")) c.D2D1_LINE_JOIN_BEVEL else c.D2D1_LINE_JOIN_MITER;
    const props: c.D2D1_STROKE_STYLE_PROPERTIES = .{ .startCap = capv, .endCap = capv, .dashCap = capv, .lineJoin = joinv, .miterLimit = 10, .dashStyle = c.D2D1_DASH_STYLE_SOLID, .dashOffset = 0 };
    const fac = d2d.?;
    var st: ?*c.ID2D1StrokeStyle = null;
    if (fac.lpVtbl.*.CreateStrokeStyle.?(fac, &props, null, 0, &st) < 0) return null;
    return st;
}

fn paintIcon(p: *Painter, n: *Node) void {
    const icon = n.props.icon orelse return;
    const ct = n.content();
    if (ct.w <= 0 or ct.h <= 0 or icon.vb[2] <= 0 or icon.vb[3] <= 0) return;
    const scale = @min(ct.w / icon.vb[2], ct.h / icon.vb[3]);
    const saved = p.xf;
    defer p.setTransform(saved);
    // viewBox → the content box, centered.
    const tx = ct.x + (ct.w - icon.vb[2] * scale) / 2 - icon.vb[0] * scale;
    const ty = ct.y + (ct.h - icon.vb[3] * scale) / 2 - icon.vb[1] * scale;
    p.setTransform(mul(matrix(scale, 0, 0, scale, tx, ty), saved));
    const vt = p.vt();
    for (icon.shapes) |sh| {
        const geo = pathGeometry(sh.d, sh.fill != null, sh.evenodd) orelse continue;
        defer releaseCom(@as(?*c.ID2D1PathGeometry, geo));
        if (sh.fill) |fill| vt.FillGeometry.?(p.rt, @ptrCast(geo), p.solid(fill), null);
        if (sh.stroke) |stroke| {
            const st = strokeStyle(sh.cap, sh.join);
            defer releaseCom(st);
            vt.DrawGeometry.?(p.rt, @ptrCast(geo), p.solid(stroke), sh.sw, st);
        }
    }
}
