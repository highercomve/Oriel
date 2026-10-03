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
const text_measure_cache = @import("text_measure_cache.zig");
const prof = @import("prof.zig");
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
    @cInclude("d2d1_1.h");
    @cInclude("dwrite.h");
    @cInclude("wincodec.h");
    @cInclude("commctrl.h");
});

// The import libraries don't export these.
const IID_IDWriteFactory = c.GUID{ .Data1 = 0xb859ee5a, .Data2 = 0xd838, .Data3 = 0x4b5b, .Data4 = .{ 0xa2, 0xe8, 0x1a, 0xdc, 0x7d, 0x93, 0xdb, 0x48 } };
const IID_ID2D1Factory = c.GUID{ .Data1 = 0x06152247, .Data2 = 0x6f50, .Data3 = 0x465a, .Data4 = .{ 0x92, 0x45, 0x11, 0x8b, 0xfd, 0x3b, 0x60, 0x07 } };
const CLSID_WICImagingFactory = c.GUID{ .Data1 = 0xcacaf262, .Data2 = 0x9370, .Data3 = 0x4615, .Data4 = .{ 0xa1, 0x3b, 0x9f, 0x55, 0x39, 0xda, 0x4c, 0x0a } };
const IID_IWICImagingFactory = c.GUID{ .Data1 = 0xec5ec8a9, .Data2 = 0xc395, .Data3 = 0x4314, .Data4 = .{ 0x9c, 0x77, 0x54, 0xd7, 0xa9, 0x35, 0xff, 0x70 } };
const IID_ID2D1DeviceContext = c.GUID{ .Data1 = 0xe8f7fe7a, .Data2 = 0x191c, .Data3 = 0x466d, .Data4 = .{ 0xad, 0x95, 0x97, 0x56, 0x78, 0xbd, 0xa9, 0x98 } };
const GUID_WICPixelFormat32bppPBGRA =c.GUID{ .Data1 = 0x6fddc324, .Data2 = 0x4e03, .Data3 = 0x4bfe, .Data4 = .{ 0xb1, 0x85, 0x3d, 0x77, 0x76, 0x8d, 0xc9, 0x10 } };

const D2DERR_RECREATE_TARGET: c.HRESULT = @bitCast(@as(u32, 0x8899000C));
/// D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT (Windows 8.1+): color emoji.
const draw_text_color_font: c.D2D1_DRAW_TEXT_OPTIONS = 4;
const EM_SETCUEBANNER: c.UINT = 0x1501;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("OrielNativeCanvas");
const clip_class_name = std.unicode.utf8ToUtf16LeStringLiteral("OrielFieldClip");
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
    /// The control's parent: a window as large as the part of it the page
    /// shows (inside its scroll containers, not under boxes painted after
    /// it), the control placed in it at its offset. Not a window region:
    /// the canvas's Direct2D present leaves out a child's whole rectangle,
    /// so a region's cut-away part kept the control's old pixels.
    clip: c.HWND,
    kind: tree_mod.Kind,
    font: ?c.HFONT = null,
    font_px: c_int = 0,
    brush: ?c.HBRUSH = null,
    bg: c.COLORREF = 0xFFFFFF,
    fg: c.COLORREF = 0,
    /// A select's theme is the dark one (its background is dark).
    dark_theme: bool = false,
    /// A textarea's placeholder (owned; the cue banner is single-line only),
    /// painted by fieldProc while the field is empty.
    ph: ?[:0]u16 = null,
    ph_hash: u64 = 0,
    /// A select's selection-field height (CB_SETITEMHEIGHT), in pixels.
    item_h: c_int = 0,
    /// <input type=range>: a trackbar, positions 0…steps of the range's step.
    slider: bool = false,
    /// The position last sent as `input` (a drag sends it once per step).
    sent_pos: isize = -1,
};

/// A slider's position for a value, and the number of steps (its maximum).
fn sliderPos(r: tree_mod.Range, v: f64) isize {
    return @intFromFloat(@round((r.snap(v) - r.min) / r.step));
}
fn sliderSteps(r: tree_mod.Range) isize {
    return @intFromFloat(@min(@round((r.max - r.min) / r.step), std.math.maxInt(i32)));
}

var common_controls = false;

/// A combobox's closed height in pixels: its drop button's rect and the same
/// inset below it (the window's own rect includes the list).
fn comboClosedHeight(hwnd: c.HWND) ?c_int {
    var cbi: c.COMBOBOXINFO = undefined;
    cbi.cbSize = @sizeOf(c.COMBOBOXINFO);
    if (c.GetComboBoxInfo(hwnd, &cbi) == 0) return null;
    const closed = cbi.rcButton.bottom + cbi.rcButton.top;
    return if (closed > 0) closed else null;
}

/// A select's selection-field height (CB_SETITEMHEIGHT with -1).
fn setItemHeight(f: *Field, item_h: c_int) void {
    const v = @max(8, item_h);
    if (v == f.item_h) return;
    _ = c.SendMessageW(f.hwnd, c.CB_SETITEMHEIGHT, std.math.maxInt(usize), @intCast(v));
    f.item_h = v;
}

/// The UA style's field border (render.js: 2px inset #ccc, or 1px #767676)
/// all round: the page didn't style it.
fn uaBorder(n: *Node) bool {
    const bw = n.props.bw orelse return false;
    const bc = n.props.bc orelse return false;
    for (bw, bc) |w, col| {
        const ua = (w == 2 and col[0] == 204 and col[1] == 204 and col[2] == 204) or
            (w == 1 and col[0] == 118 and col[1] == 118 and col[2] == 118);
        if (!ua) return false;
    }
    return true;
}

/// All of a window's decoded pictures together (see imageOf).
const max_image_cache_bytes: u64 = 256 * 1024 * 1024;

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

    /// What its decoded pixels take (BGRA; the GPU bitmap made from them
    /// is the same again, released with the render target).
    fn bytes(img: *const Image) u64 {
        if (img.wic == null) return 0;
        return @as(u64, @intFromFloat(img.w)) * @as(u64, @intFromFloat(img.h)) * 4;
    }

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
    /// Each <canvas>'s bitmap by node id, kept from frame to frame while its
    /// size holds (released with the node or the render target).
    canvases: std.AutoHashMap(i64, CanvasBitmap),
    /// Text sizes by content and layout inputs (shared with GTK's scheme),
    /// and the epoch the nodes' cached natural sizes belong to (a DPI
    /// change starts a new one).
    text_measurements: text_measure_cache.Cache = .{},
    text_epoch: u64 = 1,
    /// fastTextSize's glyph-pair widths, per font.
    glyph_widths: std.AutoHashMapUnmanaged(FontKey, *PairWidths) = .empty,
    invoke_fn: Invoke,
    invoke_ctx: ?*anyopaque,
    pointer: [2]f32 = .{ 0, 0 },
    hovered: i64 = 0,
    hand: bool = false,
    tracking: bool = false,
    updating: bool = false,
    /// requestAnimationFrame on the display's refresh (requestDisplayFrame):
    /// the page asked for the next frame, and the window is armed on the
    /// vsync thread.
    /// Fonts to load while idle (warmFonts), in the page's order.
    warm: std.ArrayListUnmanaged(engine_mod.FontSpec) = .empty,
    frame_wanted: bool = false,
    ticking: bool = false,
    /// Removed fields' controls, destroyed later (flushDoomed): a page can
    /// remove a field from the field's own notification (EN_CHANGE,
    /// CBN_SELCHANGE, WM_HSCROLL), and the control's code still runs after
    /// it returns: destroying it there crashed comctl32.
    doomed: std.ArrayListUnmanaged(Doomed) = .empty,
    doomed_posted: bool = false,
    /// Inside a control's notification to the canvas (or a field's own
    /// message): a nested message loop there must not flush `doomed`.
    in_control: u32 = 0,
    /// The tree's node count after the last layout, and whether trim_timer
    /// is armed (laidOut: a big drop gives the empty slabs back).
    node_count: usize = 0,
    trim_armed: bool = false,

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
            .canvases = .init(gpa),
            .invoke_fn = invoke_fn,
            .invoke_ctx = invoke_ctx,
        };
        errdefer s.fields.deinit();
        errdefer s.images.deinit();
        errdefer s.canvases.deinit();
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
            .request_display_frame = requestDisplayFrame,
            .warm_fonts = warmFonts,
            .invoke = invoke,
            .focus = focus,
            .props = propsChanged,
            .text = textChanged,
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
        // No more display frames for this window.
        if (s.ticking) vsync.disarm(s.hwnd);
        s.ticking = false;
        // Then the engine: freeing its nodes calls `removed` for the fields.
        s.engine.destroy();
        var it = s.fields.valueIterator();
        while (it.next()) |f| freeField(s, f);
        s.fields.deinit();
        // Not inside any control now: their windows and GDI objects go.
        flushDoomed(s);
        s.doomed.deinit(s.gpa);
        s.warm.deinit(s.gpa);
        // The target first: it walks the images to drop their bitmaps, and
        // releases the canvases (made by it).
        releaseTarget(s);
        var imgs = s.images.valueIterator();
        while (imgs.next()) |img| img.deinit();
        s.images.deinit();
        s.canvases.deinit();
        s.text_measurements.deinit(s.gpa);
        clearGlyphWidths(s);
        s.glyph_widths.deinit(s.gpa);
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
        // Text measured again (in DIPs it shouldn't move, but rounding and
        // hinting may).
        s.text_measurements.clear(s.gpa);
        clearGlyphWidths(s);
        s.text_epoch +%= 1;
        var it = s.fields.valueIterator();
        while (it.next()) |f| f.font_px = 0; // fonts at the new size
        s.resize();
        syncFields(s);
    }

    /// The window got the keyboard focus: give it to the page.
    pub fn takeFocus(s: *Surface) void {
        _ = c.SetFocus(s.hwnd);
    }

    /// A wheel message (WM_MOUSEWHEEL or WM_MOUSEHWHEEL) the parent got (the
    /// focus was on it).
    pub fn wheel(s: *Surface, msg: u32, wparam: usize, lparam: isize) void {
        _ = c.SendMessageW(s.hwnd, msg, wparam, lparam);
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
        var clip_wc = wc;
        clip_wc.lpfnWndProc = clipProc;
        clip_wc.style = 0;
        clip_wc.lpszClassName = clip_class_name;
        if (c.RegisterClassExW(&clip_wc) == 0 and c.GetLastError() != 1410) return error.RegisterClassFailed;
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
    // Canvases' bitmaps too: drawn again whole on the next paint.
    var cvs = s.canvases.valueIterator();
    while (cvs.next()) |b| freeCanvas(b.*);
    s.canvases.clearRetainingCapacity();
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

// ---------------------------------------------------------------------------
// Display frames (host.vsync): requestAnimationFrame on the display's refresh
//
// One thread for the process waits for each DWM composition (DwmFlush: the
// display's refresh) while any window wants frames, and posts
// WM_DISPLAY_FRAME to those windows, at most one queued per window. The UI
// thread runs the frame (onDisplayFrame) as GTK's tick callback does: the
// window stays armed only while the page keeps asking.

const WM_DISPLAY_FRAME: c.UINT = c.WM_APP + 0x52;

const DwmFlush = @extern(*const fn () callconv(.winapi) c.HRESULT, .{ .name = "DwmFlush", .library_name = "dwmapi" });
const DwmGetCompositionTimingInfo = @extern(*const fn (c.HWND, *DwmTimingInfo) callconv(.winapi) c.HRESULT, .{ .name = "DwmGetCompositionTimingInfo", .library_name = "dwmapi" });
/// DWM_TIMING_INFO (dwmapi.h, packed to 1, 292 bytes; cbSize must match):
/// only the refresh rate is read.
const DwmTimingInfo = extern struct {
    cbSize: u32 align(1),
    rateRefresh_num: u32 align(1),
    rateRefresh_den: u32 align(1),
    qpcRefreshPeriod: u64 align(1),
    rest: [272]u8 align(1) = undefined,
};
comptime {
    std.debug.assert(@sizeOf(DwmTimingInfo) == 292);
}

const vsync = struct {
    const Entry = struct { hwnd: c.HWND, posted: bool = false };
    /// The entries are shared with the vsync thread (an SRW lock).
    const mutex = struct {
        var lock_: c.SRWLOCK = .{ .Ptr = null };
        fn lock() void {
            c.AcquireSRWLockExclusive(&lock_);
        }
        fn unlock() void {
            c.ReleaseSRWLockExclusive(&lock_);
        }
    };
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    var wake: c.HANDLE = null;
    var started = false;

    /// The window gets WM_DISPLAY_FRAME at each refresh until disarm (UI thread).
    fn arm(hwnd: c.HWND) void {
        if (!started) {
            wake = c.CreateEventW(null, c.FALSE, c.FALSE, null);
            if (wake == null) return;
            const t = std.Thread.spawn(.{}, run, .{}) catch return;
            t.detach();
            started = true;
        }
        mutex.lock();
        defer mutex.unlock();
        for (entries.items) |e| if (e.hwnd == hwnd) return;
        entries.append(std.heap.page_allocator, .{ .hwnd = hwnd }) catch return;
        _ = c.SetEvent(wake);
    }

    fn disarm(hwnd: c.HWND) void {
        mutex.lock();
        defer mutex.unlock();
        for (entries.items, 0..) |e, i| if (e.hwnd == hwnd) {
            _ = entries.swapRemove(i);
            return;
        };
    }

    /// The window ran its frame: the next refresh may post again.
    fn done(hwnd: c.HWND) void {
        mutex.lock();
        defer mutex.unlock();
        for (entries.items) |*e| if (e.hwnd == hwnd) {
            e.posted = false;
        };
    }

    fn run() void {
        while (true) {
            mutex.lock();
            const any = entries.items.len > 0;
            mutex.unlock();
            if (!any) {
                _ = c.WaitForSingleObject(wake, c.INFINITE);
                continue;
            }
            // The next composition; without DWM (none on Windows 8+), a
            // 60 Hz-ish wait.
            if (DwmFlush() < 0) c.Sleep(15);
            mutex.lock();
            defer mutex.unlock();
            for (entries.items) |*e| {
                // One queued per window; a minimized one waits.
                if (e.posted or c.IsIconic(e.hwnd) != 0) continue;
                if (c.PostMessageW(e.hwnd, WM_DISPLAY_FRAME, 0, 0) != 0) e.posted = true;
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Fonts loaded while idle (host.warmFonts)
//
// The first text in a face pays for DirectWrite's font match and load (on a
// cold start, reading the font file): the page sends the sizes and weights
// its rules use, and each is loaded on its own idle turn. WM_TIMER comes
// only when nothing else is queued, and a turn with any input, posted
// message (a display frame), paint or due timer waiting, or an animation
// running, is put off: a frame is never delayed by more than one face.

/// The SetTimer id of the warm-up turns (above every page timer id + 1).
const warm_timer: usize = @as(usize, std.math.maxInt(u32)) + 3;
/// The SetTimer id of the pools' trim, 2 s after a render removed many
/// nodes (laidOut), as GTK's onTrim.
const trim_timer: usize = @as(usize, std.math.maxInt(u32)) + 4;

fn warmFonts(ctx: *anyopaque, specs: []const engine_mod.FontSpec) void {
    const s = surfaceOf(ctx);
    s.warm.appendSlice(s.gpa, specs) catch return;
    _ = c.SetTimer(s.hwnd, warm_timer, 1, null);
}

fn onWarmTimer(s: *Surface, hwnd: c.HWND) void {
    if (s.warm.items.len == 0) return;
    // Only when idle: anything queued goes first, and an animation keeps
    // the thread for its frames.
    if ((c.GetQueueStatus(c.QS_ALLINPUT) >> 16) != 0 or s.ticking) {
        _ = c.SetTimer(hwnd, warm_timer, 50, null);
        return;
    }
    // In the page's order: the commonest first.
    const spec = s.warm.orderedRemove(0);
    const t0 = prof.now();
    warmFace(spec);
    prof.report("warm font {d:.1}px {d}{s}{s} {d:.2}", .{ spec.size, spec.weight, if (spec.italic) " italic" else "", if (spec.mono) " mono" else "", prof.now() - t0 });
    if (s.warm.items.len > 0) _ = c.SetTimer(hwnd, warm_timer, 1, null);
}

/// A short text laid out in the face (as textLayout makes it): its font
/// matched, loaded and shaped once.
fn warmFace(spec: engine_mod.FontSpec) void {
    const dw = dwrite orelse return;
    const weight: c.DWRITE_FONT_WEIGHT = @intCast(std.math.clamp(spec.weight, 1, 999));
    const style: c.DWRITE_FONT_STYLE = if (spec.italic) c.DWRITE_FONT_STYLE_ITALIC else c.DWRITE_FONT_STYLE_NORMAL;
    const size = if (std.math.isFinite(spec.size) and spec.size > 0) spec.size else 16;
    var format: ?*c.IDWriteTextFormat = null;
    if (dw.lpVtbl.*.CreateTextFormat.?(dw, if (spec.mono) mono_face else sans_face, null, weight, style, c.DWRITE_FONT_STRETCH_NORMAL, size, std.unicode.utf8ToUtf16LeStringLiteral(""), &format) < 0 or format == null) return;
    defer releaseCom(format);
    const text = std.unicode.utf8ToUtf16LeStringLiteral("Aa");
    var layout: ?*c.IDWriteTextLayout = null;
    if (dw.lpVtbl.*.CreateTextLayout.?(dw, text, text.len, format, 1e6, 1e6, &layout) < 0 or layout == null) return;
    defer releaseCom(layout);
    var m: c.DWRITE_TEXT_METRICS = undefined;
    _ = layout.?.lpVtbl.*.GetMetrics.?(layout, &m);
}

/// host.vsync: the page's next animation frame comes at the display's next
/// refresh.
fn requestDisplayFrame(ctx: *anyopaque) void {
    const s = surfaceOf(ctx);
    s.frame_wanted = true;
    if (!s.ticking) {
        s.ticking = true;
        vsync.arm(s.hwnd);
    }
}

/// The display refreshed (WM_DISPLAY_FRAME, UI thread).
fn onDisplayFrame(s: *Surface, hwnd: c.HWND) void {
    defer vsync.done(hwnd);
    if (!s.frame_wanted) {
        s.ticking = false;
        vsync.disarm(hwnd);
        return;
    }
    s.frame_wanted = false;
    // The last frame on screen first: a posted message comes before
    // WM_PAINT, and a page that keeps every frame busy would never paint.
    _ = c.UpdateWindow(hwnd);
    var info: DwmTimingInfo = .{ .cbSize = @sizeOf(DwmTimingInfo), .rateRefresh_num = 0, .rateRefresh_den = 0, .qpcRefreshPeriod = 0 };
    const interval: f64 = if (DwmGetCompositionTimingInfo(null, &info) >= 0 and info.rateRefresh_num > 0)
        1000.0 * @as(f64, @floatFromInt(info.rateRefresh_den)) / @as(f64, @floatFromInt(info.rateRefresh_num))
    else
        0;
    s.engine.displayFrame(interval);
    // The page may have closed its window during the frame.
    if (c.IsWindow(hwnd) == 0) return;
    const p: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA))));
    const still = surfaceOf(p orelse return);
    if (!still.frame_wanted) {
        still.ticking = false;
        vsync.disarm(hwnd);
    }
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
    if (comptime prof.enabled) timer_due[id % timer_due.len] = .{ .id = id, .due = prof.now() + @as(f64, @floatFromInt(ms)) };
}

/// -Dnative_ui_prof: when each page timer should fire (its lateness is
/// reported when it does: SetTimer's tick, or the page's own work past the
/// frame's slot).
var timer_due: [64]struct { id: u32 = 0, due: f64 = 0 } = @splat(.{});

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
    if (s.canvases.fetchRemove(node.id)) |kv| freeCanvas(kv.value);
    if (s.fields.fetchRemove(node.id)) |kv| {
        var f = kv.value;
        freeField(s, &f);
    }
}

fn laidOut(ctx: *anyopaque) void {
    const s = surfaceOf(ctx);
    // A render that removed many nodes (a page section rebuilt): the
    // tree's empty slabs go back 2 s later (trimPools keeps one), unless a
    // new list took them by then. The canvas's timer: it dies with the
    // window, and a destroyed surface's canvas no longer reaches it.
    const count = s.engine.tree.nodes.count();
    if (s.node_count > count + 1000 and !s.trim_armed) {
        s.trim_armed = c.SetTimer(s.hwnd, trim_timer, 2000, null) != 0;
        prof.report("trim armed: {d} -> {d} nodes", .{ s.node_count, count });
    }
    s.node_count = count;
    syncFields(s);
    _ = c.InvalidateRect(s.hwnd, null, c.FALSE);
}

// ---------------------------------------------------------------------------
// Fields: EDIT and COMBOBOX controls for input, textarea and select

/// A removed field's control, its font and brush (still selected into it),
/// destroyed by flushDoomed.
const Doomed = struct { hwnd: c.HWND, font: ?c.HFONT, brush: ?c.HBRUSH };

const WM_FREE_FIELDS: c.UINT = c.WM_APP + 0x53;

/// The field leaves the page now: no node (so no more events to the page)
/// and hidden. Its window goes later (WM_FREE_FIELDS): this may run inside
/// that window's own notification.
fn freeField(s: *Surface, f: *Field) void {
    if (f.ph) |ph| s.gpa.free(ph);
    f.ph = null;
    _ = c.RemovePropW(f.hwnd, prop_node);
    // Its control no longer finds the surface through it (the surface may
    // go before the window does: destroy frees the fields, then flushes).
    _ = c.SetWindowLongPtrW(f.clip, c.GWLP_USERDATA, 0);
    _ = c.ShowWindow(f.clip, c.SW_HIDE);
    // The clip window goes with its control in it.
    s.doomed.append(s.gpa, .{ .hwnd = f.clip, .font = f.font, .brush = f.brush }) catch {
        // No room to defer it: hidden and orphaned rather than destroyed
        // under the control's feet (the canvas's DestroyWindow takes it).
        f.font = null;
        f.brush = null;
        return;
    };
    f.font = null;
    f.brush = null;
    if (!s.doomed_posted) s.doomed_posted = c.PostMessageW(s.hwnd, WM_FREE_FIELDS, 0, 0) != 0;
}

/// Destroys the removed fields' controls and frees their GDI objects
/// (outside any control's notification).
fn flushDoomed(s: *Surface) void {
    for (s.doomed.items) |d| {
        _ = c.DestroyWindow(d.hwnd);
        if (d.font) |h| _ = c.DeleteObject(h);
        if (d.brush) |b| _ = c.DeleteObject(b);
    }
    s.doomed.clearRetainingCapacity();
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
        var it: tree_mod.PaintIter = .{ .kids = n.kids.items };
        while (it.next()) |k| po.walk(gpa, k);
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
fn fieldVisible(po: *const PaintOrder, n: *Node, r: Rect) Rect {
    var vis = n.clip.intersect(r);
    const order = po.fields.get(n.id) orelse 0;
    for (po.occluders.items) |o| {
        if (o.order <= order) continue;
        const cut = o.rect.intersect(vis);
        if (cut.w <= 0 or cut.h <= 0) continue;
        // What's left beside the box: the largest of the parts above,
        // below, left and right of it (a clip window is a rectangle).
        const parts = [4]Rect{
            .{ .x = vis.x, .y = vis.y, .w = vis.w, .h = cut.y - vis.y },
            .{ .x = vis.x, .y = cut.y + cut.h, .w = vis.w, .h = vis.y + vis.h - (cut.y + cut.h) },
            .{ .x = vis.x, .y = vis.y, .w = cut.x - vis.x, .h = vis.h },
            .{ .x = cut.x + cut.w, .y = vis.y, .w = vis.x + vis.w - (cut.x + cut.w), .h = vis.h },
        };
        var best: Rect = .{ .x = vis.x, .y = vis.y, .w = 0, .h = 0 };
        for (parts) |p| if (p.w > 0 and p.h > 0 and p.w * p.h > best.w * best.h) {
            best = p;
        };
        vis = best;
    }
    return vis;
}

/// A node's padding box: its frame inside its border.
fn paddingBox(n: *Node) Rect {
    const f = n.frame;
    const bw = n.props.bw orelse return f;
    return .{ .x = f.x + bw[3], .y = f.y + bw[0], .w = @max(0, f.w - bw[1] - bw[3]), .h = @max(0, f.h - bw[0] - bw[2]) };
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
        if (f.slider) setSliderRange(f.*, n);
        if (f.kind == .textarea) setPlaceholder(s, f, n.props.ph orelse "");
        const visible = n.clip.intersect(n.frame).h > 1 and n.frame.w > 1 and n.props.vis != false;
        if (!visible) {
            _ = c.ShowWindow(f.clip, c.SW_HIDE);
            continue;
        }
        // At the node's content box, in the canvas's physical pixels. An
        // unstyled select at its border box: the combobox's own border is
        // its border (not a second one inside the CSS one).
        const ua_select = f.kind == .select and uaBorder(n);
        const box = if (ua_select) n.frame else n.content();
        // Where the control goes, and the part of the page it may show.
        var place = box;
        var limit = box;
        const w: c_int = @max(1, px(box.w * s.scale));
        var h: c_int = @max(1, px(box.h * s.scale));
        const box_h = h;
        if (f.kind == .select) {
            // The selection field fits the box (else the combobox keeps
            // its font's height and sticks out below it): a first guess
            // at its border, corrected below by the closed height.
            if (f.item_h == 0) setItemHeight(f, box_h - px(6 * s.scale));
            // A combobox's height includes its drop-down list.
            h += px(200 * s.scale);
        }
        _ = c.SetWindowPos(f.hwnd, null, 0, 0, w, h, c.SWP_NOZORDER | c.SWP_NOACTIVATE | c.SWP_NOMOVE);
        if (f.kind == .select) {
            if (comboClosedHeight(f.hwnd)) |closed| {
                const off = box_h - closed;
                if (off != 0 and @abs(off) < @divTrunc(box_h, 2)) setItemHeight(f, f.item_h + off);
            }
            // A combobox can't be as short as a padded box's content (its
            // font's height at least): centered in the padding box, as a
            // browser centers a select's text, and cut at it.
            if (comboClosedHeight(f.hwnd)) |closed| {
                const ch = @as(f32, @floatFromInt(closed)) / s.scale;
                if (!ua_select and ch > box.h) {
                    const pb = paddingBox(n);
                    limit = .{ .x = box.x, .y = pb.y, .w = box.w, .h = pb.h };
                    place.y = pb.y + @max(0, (pb.h - ch) / 2);
                } else limit.h = @max(box.h, ch);
                // No more than the closed combobox covers: the clip window
                // paints nothing of its own (and the canvas doesn't paint
                // under it).
                limit = limit.intersect(.{ .x = place.x, .y = place.y, .w = box.w, .h = ch });
            }
        }
        const vis = fieldVisible(&po, n, limit);
        // In physical pixels, inside the control's own rectangle (rounding
        // must not leave the clip window an edge the control doesn't cover).
        const cx = px(place.x * s.scale);
        const cy = px(place.y * s.scale);
        const ch: c_int = if (f.kind == .select) comboClosedHeight(f.hwnd) orelse h else h;
        const x0 = @max(cx, px(vis.x * s.scale));
        const y0 = @max(cy, px(vis.y * s.scale));
        const x1 = @min(cx + w, px((vis.x + vis.w) * s.scale));
        const y1 = @min(cy + ch, px((vis.y + vis.h) * s.scale));
        if (x1 <= x0 or y1 <= y0) {
            _ = c.ShowWindow(f.clip, c.SW_HIDE);
            continue;
        }
        _ = c.SetWindowPos(f.clip, null, x0, y0, x1 - x0, y1 - y0, c.SWP_NOZORDER | c.SWP_NOACTIVATE | c.SWP_SHOWWINDOW);
        _ = c.SetWindowPos(f.hwnd, null, cx - x0, cy - y0, 0, 0, c.SWP_NOZORDER | c.SWP_NOACTIVATE | c.SWP_NOSIZE | c.SWP_SHOWWINDOW);
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

/// <input type=range>: a trackbar, positions 0…steps (the value snaps to
/// the range's step); its WM_HSCROLL goes to the canvas (onSlider).
fn makeSlider(s: *Surface, n: *Node) !Field {
    if (!common_controls) {
        const icc: c.INITCOMMONCONTROLSEX = .{ .dwSize = @sizeOf(c.INITCOMMONCONTROLSEX), .dwICC = c.ICC_BAR_CLASSES };
        _ = c.InitCommonControlsEx(&icc);
        common_controls = true;
    }
    const cls = std.unicode.utf8ToUtf16LeStringLiteral("msctls_trackbar32");
    const style: c.DWORD = c.WS_CHILD | c.WS_TABSTOP | c.TBS_HORZ | c.TBS_NOTICKS;
    // In its clip window, as the other fields (makeField).
    const clip = try makeClip(s);
    errdefer _ = c.DestroyWindow(clip);
    const hwnd = c.CreateWindowExW(0, cls, null, style, 0, 0, 1, 1, clip, null, c.GetModuleHandleW(null), null) orelse return error.CreateWindowFailed;
    _ = c.SetPropW(hwnd, prop_node, @ptrFromInt(@as(usize, @intCast(n.id))));
    const f: Field = .{ .hwnd = hwnd, .clip = clip, .kind = n.kind, .slider = true };
    setSliderRange(f, n);
    return f;
}

fn setSliderRange(f: Field, n: *Node) void {
    const steps = sliderSteps(tree_mod.Range.of(n));
    if (c.SendMessageW(f.hwnd, c.TBM_GETRANGEMAX, 0, 0) == steps) return;
    _ = c.SendMessageW(f.hwnd, c.TBM_SETRANGEMIN, c.FALSE, 0);
    _ = c.SendMessageW(f.hwnd, c.TBM_SETRANGEMAX, c.TRUE, steps);
    _ = c.SendMessageW(f.hwnd, c.TBM_SETLINESIZE, 0, 1);
    _ = c.SendMessageW(f.hwnd, c.TBM_SETPAGESIZE, 0, @max(1, @divTrunc(steps, 10)));
}

/// A trackbar moved (WM_HSCROLL): `input` for each new position while it
/// drags or a key steps it, `change` when it's let go (TB_ENDTRACK), as
/// AppKit's slider and Android's SeekBar send them.
fn onSlider(s: *Surface, code: c.WORD, hwnd: c.HWND) void {
    if (s.updating) return;
    const fx = fieldOf(s, hwnd) orelse return;
    if (!fx.field.slider) return;
    const r = tree_mod.Range.of(fx.node);
    const pos: isize = c.SendMessageW(hwnd, c.TBM_GETPOS, 0, 0);
    var buf: [48]u8 = undefined;
    const text = r.text(&buf, r.min + @as(f64, @floatFromInt(pos)) * r.step);
    if (pos != fx.field.sent_pos) {
        fx.field.sent_pos = pos;
        sendValue(s, fx.node, "input", text);
    }
    if (code != c.TB_ENDTRACK) return;
    // The page may have closed the window or rebuilt the node.
    if (c.IsWindow(hwnd) == 0) return;
    const again = fieldOf(s, hwnd) orelse return;
    sendValue(s, again.node, "change", text);
}

/// accent-color on a trackbar (NM_CUSTOMDRAW): the thumb and the channel up
/// to it in the accent, the rest of the channel grey. Null: draw the default.
fn sliderDraw(s: *Surface, cd: *c.NMCUSTOMDRAW) ?c.LRESULT {
    const fx = fieldOf(s, cd.hdr.hwndFrom) orelse return null;
    if (!fx.field.slider) return null;
    const acc = fx.node.props.acc orelse return null;
    if (cd.dwDrawStage == c.CDDS_PREPAINT) return c.CDRF_NOTIFYITEMDRAW;
    if (cd.dwDrawStage != c.CDDS_ITEMPREPAINT) return null;
    const col = colorRef(acc);
    switch (cd.dwItemSpec) {
        c.TBCD_CHANNEL => {
            var thumb: c.RECT = undefined;
            _ = c.SendMessageW(cd.hdr.hwndFrom, c.TBM_GETTHUMBRECT, 0, @bitCast(@intFromPtr(&thumb)));
            const grey = c.CreateSolidBrush(0xB0B0B0) orelse return null;
            defer _ = c.DeleteObject(grey);
            const fill = c.CreateSolidBrush(col) orelse return null;
            defer _ = c.DeleteObject(fill);
            _ = c.FillRect(cd.hdc, &cd.rc, grey);
            var done = cd.rc;
            done.right = @max(done.left, @min(done.right, @divTrunc(thumb.left + thumb.right, 2)));
            _ = c.FillRect(cd.hdc, &done, fill);
            return c.CDRF_SKIPDEFAULT;
        },
        c.TBCD_THUMB => {
            const brush = c.CreateSolidBrush(col) orelse return null;
            defer _ = c.DeleteObject(brush);
            const pen = c.CreatePen(c.PS_SOLID, 1, col) orelse return null;
            defer _ = c.DeleteObject(pen);
            const old_brush = c.SelectObject(cd.hdc, brush);
            const old_pen = c.SelectObject(cd.hdc, pen);
            defer {
                _ = c.SelectObject(cd.hdc, old_brush);
                _ = c.SelectObject(cd.hdc, old_pen);
            }
            const rc = cd.rc;
            const w = rc.right - rc.left;
            _ = c.RoundRect(cd.hdc, rc.left, rc.top, rc.right, rc.bottom, w, w);
            return c.CDRF_SKIPDEFAULT;
        },
        else => return null,
    }
}

fn makeField(s: *Surface, n: *Node) !Field {
    if (n.kind == .input and n.props.range != null) return makeSlider(s, n);
    const class = std.unicode.utf8ToUtf16LeStringLiteral("EDIT");
    const style: c.DWORD = switch (n.kind) {
        .input => @as(c.DWORD, c.WS_CHILD | c.WS_TABSTOP | c.ES_AUTOHSCROLL) | (if (n.props.pw) @as(c.DWORD, c.ES_PASSWORD) else @as(c.DWORD, 0)),
        .textarea => c.WS_CHILD | c.WS_TABSTOP | c.ES_MULTILINE | c.ES_AUTOVSCROLL | c.ES_WANTRETURN,
        .select => c.WS_CHILD | c.WS_TABSTOP | c.CBS_DROPDOWNLIST | c.WS_VSCROLL,
        else => unreachable,
    };
    const cls = if (n.kind == .select) std.unicode.utf8ToUtf16LeStringLiteral("COMBOBOX") else class;
    const clip = try makeClip(s);
    errdefer _ = c.DestroyWindow(clip);
    const hwnd = c.CreateWindowExW(0, cls, null, style, 0, 0, 1, 1, clip, null, c.GetModuleHandleW(null), null) orelse return error.CreateWindowFailed;
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
    return .{ .hwnd = hwnd, .clip = clip, .kind = n.kind };
}

/// A field's clip window (Field.clip), hidden until placed. In a transparent
/// window GDI's pixels come out with zero alpha (the control would show
/// what's behind the window): there it's a layered child, composed opaque
/// by DWM (Windows 8+), with the control drawn into it.
fn makeClip(s: *Surface) !c.HWND {
    const hinst = c.GetModuleHandleW(null);
    const style: c.DWORD = c.WS_CHILD | c.WS_CLIPCHILDREN;
    const clip: c.HWND = blk: {
        if (s.transparent) {
            if (c.CreateWindowExW(c.WS_EX_LAYERED | c.WS_EX_CONTROLPARENT, clip_class_name, null, style, 0, 0, 1, 1, s.hwnd, null, hinst, null)) |h| {
                _ = c.SetLayeredWindowAttributes(h, 0, 255, c.LWA_ALPHA);
                break :blk h;
            }
        }
        break :blk c.CreateWindowExW(c.WS_EX_CONTROLPARENT, clip_class_name, null, style, 0, 0, 1, 1, s.hwnd, null, hinst, null) orelse return error.CreateWindowFailed;
    };
    // The surface, as the canvas has it: a control finds it from its parent.
    _ = c.SetWindowLongPtrW(clip, c.GWLP_USERDATA, c.GetWindowLongPtrW(s.hwnd, c.GWLP_USERDATA));
    return clip;
}

fn setFieldValue(s: *Surface, f: *Field, n: *Node, v: []const u8) void {
    if (f.slider) {
        const r = tree_mod.Range.of(n);
        const pos = sliderPos(r, r.parse(v));
        _ = c.SendMessageW(f.hwnd, c.TBM_SETPOS, c.TRUE, pos);
        f.sent_pos = pos;
        return;
    }
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
    // A closed combobox draws with its theme, not WM_CTLCOLOR*: on a dark
    // background, the dark one (the file dialogs'), else a white box on a
    // dark page.
    if (f.kind == .select) {
        const dark = luminance(bg) < 0.5;
        if (dark != f.dark_theme) {
            f.dark_theme = dark;
            setWindowTheme(f.hwnd, if (dark) std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_CFD") else null);
        }
    }
}

fn luminance(col: c.COLORREF) f32 {
    const r: f32 = @floatFromInt(col & 0xFF);
    const g: f32 = @floatFromInt((col >> 8) & 0xFF);
    const b: f32 = @floatFromInt((col >> 16) & 0xFF);
    return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
}

const SetWindowThemeFn = *const fn (c.HWND, ?[*:0]const u16, ?[*:0]const u16) callconv(.winapi) c.HRESULT;
var set_window_theme: ?SetWindowThemeFn = null;
var set_window_theme_loaded = false;

/// uxtheme's SetWindowTheme, loaded on first use (no import library).
fn setWindowTheme(hwnd: c.HWND, app: ?[*:0]const u16) void {
    if (!set_window_theme_loaded) {
        set_window_theme_loaded = true;
        if (c.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("uxtheme.dll"))) |lib| {
            if (c.GetProcAddress(lib, "SetWindowTheme")) |p| set_window_theme = @ptrCast(p);
        }
    }
    if (set_window_theme) |f| _ = f(hwnd, app, null);
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
                    s.in_control += 1;
                    const prevented = s.engine.event(id, "key", json);
                    s.in_control -= 1;
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

/// The wheel (WM_MOUSEWHEEL) or the tilt wheel / a touchpad's sideways
/// swipe (WM_MOUSEHWHEEL, `sideways`); Shift with the wheel scrolls
/// sideways too, as in a browser.
fn onWheel(s: *Surface, wparam: c.WPARAM, lparam: c.LPARAM, sideways: bool) void {
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
    const hit = s.engine.tree.hit(pt[0], pt[1]);
    if (sideways or wparam & c.MK_SHIFT != 0) {
        // WM_MOUSEHWHEEL: right positive; Shift+wheel: down scrolls right.
        const dx = if (sideways) -dy else dy;
        var tx = s.engine.tree.scrollerX(hit);
        while (tx) |t| {
            if (s.engine.scrollByX(t, dx)) return;
            tx = s.engine.tree.scrollerX(t.parent);
        }
        if (sideways) return;
    }
    var target = s.engine.tree.scroller(hit);
    while (target) |t| {
        if (s.engine.scrollBy(t, dy)) return;
        target = s.engine.tree.scroller(t.parent);
    }
}

/// A field's clip window (Field.clip): what its control tells its parent
/// goes to the canvas; it paints nothing itself (the control covers it).
fn clipProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    switch (msg) {
        c.WM_COMMAND, c.WM_HSCROLL, c.WM_NOTIFY, c.WM_CTLCOLOREDIT, c.WM_CTLCOLORLISTBOX, c.WM_CTLCOLORSTATIC => {
            const canvas = c.GetParent(hwnd) orelse return c.DefWindowProcW(hwnd, msg, wparam, lparam);
            return c.SendMessageW(canvas, msg, wparam, lparam);
        },
        c.WM_ERASEBKGND => return 1,
        else => return c.DefWindowProcW(hwnd, msg, wparam, lparam),
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
        WM_DISPLAY_FRAME => {
            onDisplayFrame(s, hwnd);
            return 0;
        },
        c.WM_TIMER => {
            _ = c.KillTimer(hwnd, wparam);
            if (wparam == warm_timer) {
                onWarmTimer(s, hwnd);
                return 0;
            }
            if (wparam == trim_timer) {
                s.trim_armed = false;
                const freed = s.engine.tree.trimPools();
                prof.report("trim pools {d}", .{freed});
                return 0;
            }
            // Ours are the page's ids + 1 (addTimer): nothing else is.
            if (wparam == 0 or wparam > std.math.maxInt(u32) + 1) return 0;
            if (comptime prof.enabled) {
                const id: u32 = @intCast(wparam - 1);
                const d = timer_due[id % timer_due.len];
                if (d.id == id) prof.report("timer late {d:.2}", .{prof.now() - d.due});
            }
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
        c.WM_MOUSEWHEEL, c.WM_MOUSEHWHEEL => {
            onWheel(s, wparam, lparam, msg == c.WM_MOUSEHWHEEL);
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
        // Removed fields' controls: now that no control's code is running.
        WM_FREE_FIELDS => {
            s.doomed_posted = false;
            if (s.in_control > 0) {
                // A nested message loop inside a control's notification.
                s.doomed_posted = c.PostMessageW(hwnd, WM_FREE_FIELDS, 0, 0) != 0;
                return 0;
            }
            flushDoomed(s);
            return 0;
        },
        c.WM_COMMAND => {
            s.in_control += 1;
            defer s.in_control -= 1;
            if (lparam != 0) onFieldCommand(s, @truncate(wparam >> 16), toHandle(c.HWND, @bitCast(lparam)));
            return 0;
        },
        // A trackbar (<input type=range>) moved.
        c.WM_HSCROLL => {
            s.in_control += 1;
            defer s.in_control -= 1;
            if (lparam != 0) onSlider(s, @truncate(wparam), toHandle(c.HWND, @bitCast(lparam)));
            return 0;
        },
        c.WM_NOTIFY => if (lparam != 0) {
            const hdr: *const c.NMHDR = @ptrFromInt(@as(usize, @bitCast(lparam)));
            // NM_CUSTOMDRAW (NM_FIRST - 12; the header's macro doesn't translate).
            if (hdr.code == @as(c.UINT, @bitCast(@as(i32, -12)))) {
                if (sliderDraw(s, @ptrFromInt(@as(usize, @bitCast(lparam))))) |r| return r;
            }
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
    return textLayoutOf(s, &n.props, width, brushes);
}

/// textLayout for props (a probe's: fastTextSize).
fn textLayoutOf(s: *Surface, props: *const tree_mod.Props, width: f32, brushes: ?*std.ArrayList(*c.ID2D1SolidColorBrush)) ?*c.IDWriteTextLayout {
    const runs = props.runs orelse return null;
    const u = runsUtf16(s, runs) orelse return null;
    defer {
        s.gpa.free(u.text);
        s.gpa.free(u.ranges);
    }
    const dw = dwrite.?;
    const fz = props.fz orelse 16;
    var format: ?*c.IDWriteTextFormat = null;
    if (dw.lpVtbl.*.CreateTextFormat.?(dw, if (props.mono) mono_face else sans_face, null, c.DWRITE_FONT_WEIGHT_NORMAL, c.DWRITE_FONT_STYLE_NORMAL, c.DWRITE_FONT_STRETCH_NORMAL, fz, std.unicode.utf8ToUtf16LeStringLiteral(""), &format) < 0) return null;
    defer releaseCom(format);
    const nowrap = props.nowrap or std.math.isInf(width);
    const max_w: f32 = if (nowrap) 1e6 else @max(1, width);
    var layout: ?*c.IDWriteTextLayout = null;
    if (dw.lpVtbl.*.CreateTextLayout.?(dw, u.text.ptr, @intCast(u.text.len), format, max_w, 1e6, &layout) < 0) return null;
    const l = layout.?;
    const vt = l.lpVtbl.*;
    const fmt: *c.IDWriteTextFormat = @ptrCast(l);
    const fvt = fmt.lpVtbl.*;
    _ = fvt.SetWordWrapping.?(fmt, if (nowrap) c.DWRITE_WORD_WRAPPING_NO_WRAP else c.DWRITE_WORD_WRAPPING_WRAP);
    if (props.ta) |ta| {
        const a: c.DWRITE_TEXT_ALIGNMENT = if (std.mem.eql(u8, ta, "center")) c.DWRITE_TEXT_ALIGNMENT_CENTER else if (std.mem.eql(u8, ta, "right") or std.mem.eql(u8, ta, "end")) c.DWRITE_TEXT_ALIGNMENT_TRAILING else c.DWRITE_TEXT_ALIGNMENT_LEADING;
        // A line wider than nothing can't be aligned: only with a width.
        if (!nowrap) _ = fvt.SetTextAlignment.?(fmt, a);
    }
    if (props.lh) |lh| _ = fvt.SetLineSpacing.?(fmt, c.DWRITE_LINE_SPACING_METHOD_UNIFORM, lh, lh * 0.8);
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
// <canvas>: the recorded program (src/native_ui/js/src/canvas.js) replayed
// with Direct2D into the canvas's own bitmap render target (kept from frame
// to frame while its size holds), then drawn on the page clipped to the
// box's border-radius. The program can't reach the page: an unbalanced
// restore() is ignored and a clearRect clears the bitmap only. Every paint
// replays the whole program from the context's defaults.

/// A canvas's bitmap: made by the window's render target, released with it.
const CanvasBitmap = struct { rt: *c.ID2D1BitmapRenderTarget, w: u32, h: u32 };

fn freeCanvas(b: CanvasBitmap) void {
    releaseCom(@as(?*c.ID2D1BitmapRenderTarget, b.rt));
}

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
    /// A scale by 0: nothing drawn until the restore() that undoes it (the
    /// transform has no inverse).
    singular: bool = false,
    /// User space to the bitmap's (DIPs: the box's CSS pixels).
    xf: c.D2D1_MATRIX_3X2_F = identity,
    /// How many clip layers were pushed when it was saved.
    clips: usize = 0,
};

const P2 = c.D2D1_POINT_2F;

/// The current path, in the bitmap's space: each point is transformed when
/// it's added, as in a browser. It outlives fills, strokes and clips.
const PathOp = union(enum) { move: P2, line: P2, bezier: [3]P2, close };

const CanvasGrad = struct {
    radial: bool,
    /// linear: x0 y0 x1 y1; radial: x0 y0 r0 x1 y1 r1 (user space).
    g: [6]f32,
    stops: std.ArrayList(c.D2D1_GRADIENT_STOP) = .empty,
};

/// The largest canvas bitmap: 4096 x 4096 px (64 MB as BGRA).
const max_canvas_pixels: f32 = 4096 * 4096;

fn paintCanvas(p: *Painter, n: *Node) void {
    const cmds = n.canvas orelse return;
    const s = p.s;
    const f = n.frame;
    if (!(f.w > 0 and f.h > 0) or !std.math.isFinite(f.w * f.h * s.scale)) return;
    // At most max_canvas_pixels (as on GTK and Apple): a bigger canvas gets
    // a bitmap of fewer pixels per point, scaled up on the page (the target
    // keeps the box's size in DIPs).
    var sf: f32 = s.scale;
    const area = f.w * sf * f.h * sf;
    if (area > max_canvas_pixels) sf *= @sqrt(max_canvas_pixels / area);
    const pw: u32 = @intFromFloat(@max(1, @min(16384, @ceil(f.w * sf))));
    const ph: u32 = @intFromFloat(@max(1, @min(16384, @ceil(f.h * sf))));
    if (pw == 0 or ph == 0) return;
    var owned: ?*c.ID2D1BitmapRenderTarget = null; // not cached: released after this frame
    defer releaseCom(owned);
    const crt = canvasTarget(p, n.id, f, pw, ph, &owned) orelse return;
    const rt: *c.ID2D1RenderTarget = @ptrCast(crt);
    const vt = rt.lpVtbl.*;
    var solid: ?*c.ID2D1SolidColorBrush = null;
    const black: c.D2D1_COLOR_F = .{ .r = 0, .g = 0, .b = 0, .a = 1 };
    if (vt.CreateSolidColorBrush.?(rt, &black, null, &solid) < 0 or solid == null) return;
    defer releaseCom(solid);
    // Copy blending (Windows 8+): a clearRect through a rotation or a clip.
    var dc: ?*c.ID2D1DeviceContext = null;
    const unk: *c.IUnknown = @ptrCast(rt);
    if (unk.lpVtbl.*.QueryInterface.?(unk, &IID_ID2D1DeviceContext, @ptrCast(&dc)) < 0) dc = null;
    defer releaseCom(dc);

    vt.BeginDraw.?(rt);
    vt.SetTransform.?(rt, &identity);
    const clear: c.D2D1_COLOR_F = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    vt.Clear.?(rt, &clear);
    var cv: CanvasPainter = .{ .gpa = s.gpa, .rt = rt, .solid = solid.?, .dc = dc, .grads = .init(s.gpa) };
    defer cv.deinit();
    // The bitmap's space, scaled to the box (CSS width/height stretch it,
    // as in a browser).
    const cw = n.props.cw orelse f.w;
    const ch = n.props.ch orelse f.h;
    if (cw > 0 and ch > 0) cv.st.xf = matrix(f.w / cw, 0, 0, f.h / ch, 0, 0);
    for (cmds) |cmd| cv.run(cmd);
    // Layers must be popped before EndDraw.
    cv.popClips(0);
    if (vt.EndDraw.?(rt, null, null) < 0) {
        // The device was lost: made again on the next paint.
        if (owned == null) if (s.canvases.fetchRemove(n.id)) |kv| freeCanvas(kv.value);
        return;
    }

    var bmp: ?*c.ID2D1Bitmap = null;
    if (crt.lpVtbl.*.GetBitmap.?(crt, &bmp) < 0 or bmp == null) return;
    defer releaseCom(bmp);
    const pv = p.vt();
    // Clipped to the box's rounded corners, as a browser clips a replaced
    // element's content to its border-radius.
    const r = n.radius();
    const mask = if (r[0] > 0 or r[1] > 0 or r[2] > 0 or r[3] > 0) roundRectGeometry(f, r) else null;
    defer releaseCom(mask);
    if (mask) |m| {
        const params: c.D2D1_LAYER_PARAMETERS = .{
            .contentBounds = .{ .left = -1e6, .top = -1e6, .right = 1e6, .bottom = 1e6 },
            .geometricMask = @ptrCast(m),
            .maskAntialiasMode = c.D2D1_ANTIALIAS_MODE_PER_PRIMITIVE,
            .maskTransform = identity,
            .opacity = 1,
            .opacityBrush = null,
            .layerOptions = c.D2D1_LAYER_OPTIONS_NONE,
        };
        pv.PushLayer.?(p.rt, &params, null);
    }
    const dest = rectF(f);
    pv.DrawBitmap.?(p.rt, bmp, &dest, 1, c.D2D1_BITMAP_INTERPOLATION_MODE_LINEAR, null);
    if (mask != null) pv.PopLayer.?(p.rt);
}

/// The node's bitmap from the last frame when the size holds (a game loop
/// redraws every frame), else a new one. One that can't be cached goes in
/// `owned` (the caller releases it).
fn canvasTarget(p: *Painter, id: i64, f: Rect, pw: u32, ph: u32, owned: *?*c.ID2D1BitmapRenderTarget) ?*c.ID2D1BitmapRenderTarget {
    const s = p.s;
    if (s.canvases.get(id)) |b| {
        if (b.w == pw and b.h == ph) return b.rt;
        _ = s.canvases.remove(id);
        freeCanvas(b);
    }
    // The box's size in DIPs at the window's pixel density (capped).
    const size: c.D2D1_SIZE_F = .{ .width = f.w, .height = f.h };
    const psize: c.D2D1_SIZE_U = .{ .width = pw, .height = ph };
    const fmt: c.D2D1_PIXEL_FORMAT = .{ .format = c.DXGI_FORMAT_B8G8R8A8_UNORM, .alphaMode = c.D2D1_ALPHA_MODE_PREMULTIPLIED };
    var bt: ?*c.ID2D1BitmapRenderTarget = null;
    if (p.vt().CreateCompatibleRenderTarget.?(p.rt, &size, &psize, &fmt, c.D2D1_COMPATIBLE_RENDER_TARGET_OPTIONS_NONE, &bt) < 0 or bt == null) return null;
    s.canvases.put(id, .{ .rt = bt.?, .w = pw, .h = ph }) catch {
        owned.* = bt;
    };
    return bt;
}

fn invert(m: c.D2D1_MATRIX_3X2_F) ?c.D2D1_MATRIX_3X2_F {
    const a = mget(m);
    const det = a[0] * a[3] - a[1] * a[2];
    if (!std.math.isFinite(det) or @abs(det) < 1e-12) return null;
    const n0 = a[3] / det;
    const n1 = -a[1] / det;
    const n2 = -a[2] / det;
    const n3 = a[0] / det;
    return matrix(n0, n1, n2, n3, -(a[4] * n0 + a[5] * n2), -(a[4] * n1 + a[5] * n3));
}

fn addRef(o: anytype) void {
    const u: *c.IUnknown = @ptrCast(o);
    _ = u.lpVtbl.*.AddRef.?(u);
}

const CanvasPainter = struct {
    gpa: std.mem.Allocator,
    rt: *c.ID2D1RenderTarget,
    solid: *c.ID2D1SolidColorBrush,
    dc: ?*c.ID2D1DeviceContext,
    st: CanvasState = .{},
    states: std.ArrayList(CanvasState) = .empty,
    path: std.ArrayList(PathOp) = .empty,
    /// The current point (null: none yet) and its subpath's start.
    cur: ?P2 = null,
    start: P2 = .{ .x = 0, .y = 0 },
    grads: std.AutoHashMap(u16, CanvasGrad),
    /// clip() masks pushed as layers, in the bitmap's space (owned).
    clips: std.ArrayList(*c.ID2D1PathGeometry) = .empty,

    fn deinit(cv: *CanvasPainter) void {
        // popClips(0) ran before EndDraw; anything left is only released.
        for (cv.clips.items) |g| releaseCom(@as(?*c.ID2D1PathGeometry, g));
        cv.clips.deinit(cv.gpa);
        cv.states.deinit(cv.gpa);
        cv.path.deinit(cv.gpa);
        var it = cv.grads.valueIterator();
        while (it.next()) |g| g.stops.deinit(cv.gpa);
        cv.grads.deinit();
    }

    fn run(cv: *CanvasPainter, cmd: tree_mod.CanvasCmd) void {
        if (cv.st.singular) switch (cmd) {
            .translate, .scale, .rotate, .begin_path, .close_path, .move_to, .line_to, .rect, .arc, .bezier_to, .fill, .stroke, .clip, .fill_rect, .stroke_rect, .clear_rect, .fill_text, .stroke_text => return,
            else => {},
        };
        switch (cmd) {
            .save => {
                var saved = cv.st;
                saved.clips = cv.clips.items.len;
                cv.states.append(cv.gpa, saved) catch return;
            },
            // Only what this program saved: an extra restore() is ignored.
            .restore => if (cv.states.pop()) |prev| {
                cv.popClips(prev.clips);
                cv.st = prev;
            },
            .translate => |t| cv.st.xf = mul(matrix(1, 0, 0, 1, t[0], t[1]), cv.st.xf),
            .scale => |t| if (t[0] == 0 or t[1] == 0) {
                cv.st.singular = true;
            } else {
                cv.st.xf = mul(matrix(t[0], 0, 0, t[1], 0, 0), cv.st.xf);
            },
            .rotate => |a| cv.st.xf = mul(matrix(@cos(a), @sin(a), -@sin(a), @cos(a), 0, 0), cv.st.xf),
            .begin_path => {
                cv.path.clearRetainingCapacity();
                cv.cur = null;
            },
            .close_path => if (cv.cur != null) {
                cv.add(.close);
                cv.cur = cv.start;
            },
            .move_to => |pt| cv.moveTo(cv.point(pt[0], pt[1])),
            .line_to => |pt| cv.lineTo(cv.point(pt[0], pt[1])),
            .rect => |r| {
                cv.moveTo(cv.point(r[0], r[1]));
                cv.lineTo(cv.point(r[0] + r[2], r[1]));
                cv.lineTo(cv.point(r[0] + r[2], r[1] + r[3]));
                cv.lineTo(cv.point(r[0], r[1] + r[3]));
                cv.add(.close);
                // A new subpath at the rectangle's corner.
                cv.moveTo(cv.point(r[0], r[1]));
            },
            .arc => |a| cv.arc(a.x, a.y, a.r, a.a0, a.a1, a.ccw),
            .bezier_to => |b| {
                const c1 = cv.point(b[0], b[1]);
                if (cv.cur == null) cv.moveTo(c1);
                const end = cv.point(b[4], b[5]);
                cv.add(.{ .bezier = .{ c1, cv.point(b[2], b[3]), end } });
                cv.cur = end;
            },
            .fill => |even| if (cv.path.items.len > 0) {
                const geo = cv.pathGeometry(even) orelse return;
                defer releaseCom(@as(?*c.ID2D1PathGeometry, geo));
                cv.draw(@ptrCast(geo), cv.st.fill, false);
            },
            .stroke => if (cv.path.items.len > 0) {
                const geo = cv.pathGeometry(false) orelse return;
                defer releaseCom(@as(?*c.ID2D1PathGeometry, geo));
                cv.draw(@ptrCast(geo), cv.st.stroke, true);
            },
            .clip => |even| {
                // An empty path clips everything out, as in a browser.
                const geo = cv.pathGeometry(even) orelse return;
                cv.clips.append(cv.gpa, geo) catch {
                    releaseCom(@as(?*c.ID2D1PathGeometry, geo));
                    return;
                };
                cv.pushClip(geo);
            },
            .fill_rect => |r| cv.rectOp(r, false),
            .stroke_rect => |r| cv.rectOp(r, true),
            .clear_rect => |r| cv.clearRect(r),
            .fill_text => |t| cv.text(t.t, t.x, t.y, false),
            .stroke_text => |t| cv.text(t.t, t.x, t.y, true),
            .fill_style => |src| cv.st.fill = src,
            .stroke_style => |src| cv.st.stroke = src,
            .line_width => |w| cv.st.lw = @max(0, w),
            .line_cap => |cap| cv.st.cap = cap,
            .line_join => |join| cv.st.join = join,
            .global_alpha => |a| cv.st.alpha = a,
            .font => |fnt| cv.st.font = fnt,
            .text_align => |a| cv.st.talign = a,
            .text_baseline => |b| cv.st.tbase = b,
            .linear_gradient => |g| cv.setGrad(g.id, false, .{ g.x0, g.y0, g.x1, g.y1, 0, 0 }),
            .radial_gradient => |g| cv.setGrad(g.id, true, .{ g.x0, g.y0, g.r0, g.x1, g.y1, g.r1 }),
            .color_stop => |cs| if (cv.grads.getPtr(cs.id)) |g| {
                g.stops.append(cv.gpa, .{ .position = std.math.clamp(cs.off, 0, 1), .color = d2dColor(cs.c) }) catch {};
            },
        }
    }

    fn point(cv: *CanvasPainter, x: f32, y: f32) P2 {
        const m = mget(cv.st.xf);
        return .{ .x = x * m[0] + y * m[2] + m[4], .y = x * m[1] + y * m[3] + m[5] };
    }

    fn add(cv: *CanvasPainter, op: PathOp) void {
        // A point that overflowed through the transform isn't added (as
        // moveTo and lineTo skip theirs).
        if (op == .bezier) for (op.bezier) |pt| {
            if (!std.math.isFinite(pt.x) or !std.math.isFinite(pt.y)) return;
        };
        cv.path.append(cv.gpa, op) catch {};
    }

    fn moveTo(cv: *CanvasPainter, pt: P2) void {
        if (!std.math.isFinite(pt.x) or !std.math.isFinite(pt.y)) return;
        cv.add(.{ .move = pt });
        cv.cur = pt;
        cv.start = pt;
    }

    fn lineTo(cv: *CanvasPainter, pt: P2) void {
        if (!std.math.isFinite(pt.x) or !std.math.isFinite(pt.y)) return;
        if (cv.cur == null) return cv.moveTo(pt);
        cv.add(.{ .line = pt });
        cv.cur = pt;
    }

    /// As cubic Béziers of up to a quarter turn each, from a0 to a1
    /// (clockwise in the y-down space unless ccw), joined to the current
    /// point by a line.
    fn arc(cv: *CanvasPainter, x: f32, y: f32, r: f32, a0: f32, a1: f32, ccw: bool) void {
        if (r < 0) return;
        const two_pi: f32 = 2.0 * std.math.pi;
        const sweep: f32 = if (ccw) blk: {
            const d = a0 - a1;
            break :blk -(if (d >= two_pi) two_pi else @mod(d, two_pi));
        } else blk: {
            const d = a1 - a0;
            break :blk if (d >= two_pi) two_pi else @mod(d, two_pi);
        };
        const p0 = cv.point(x + r * @cos(a0), y + r * @sin(a0));
        if (cv.cur == null) cv.moveTo(p0) else cv.lineTo(p0);
        if (sweep == 0 or r == 0) return;
        const segs: f32 = @max(1, @ceil(@abs(sweep) / (std.math.pi / 2.0)));
        const step = sweep / segs;
        const k = 4.0 / 3.0 * @tan(step / 4);
        var i: f32 = 0;
        while (i < segs) : (i += 1) {
            const t0 = a0 + step * i;
            const t1 = t0 + step;
            const cs0 = @cos(t0);
            const sn0 = @sin(t0);
            const cs1 = @cos(t1);
            const sn1 = @sin(t1);
            const end = cv.point(x + r * cs1, y + r * sn1);
            cv.add(.{ .bezier = .{
                cv.point(x + r * (cs0 - k * sn0), y + r * (sn0 + k * cs0)),
                cv.point(x + r * (cs1 + k * sn1), y + r * (sn1 - k * cs1)),
                end,
            } });
            cv.cur = end;
        }
    }

    /// The current path as a Direct2D geometry (caller releases).
    fn pathGeometry(cv: *CanvasPainter, evenodd: bool) ?*c.ID2D1PathGeometry {
        const fac = d2d.?;
        var geo: ?*c.ID2D1PathGeometry = null;
        if (fac.lpVtbl.*.CreatePathGeometry.?(fac, &geo) < 0 or geo == null) return null;
        var sink: ?*c.ID2D1GeometrySink = null;
        if (geo.?.lpVtbl.*.Open.?(geo, &sink) < 0 or sink == null) {
            releaseCom(geo);
            return null;
        }
        defer releaseCom(sink);
        const sk: *c.ID2D1SimplifiedGeometrySink = @ptrCast(sink.?);
        const sv = sk.lpVtbl.*;
        sv.SetFillMode.?(sk, if (evenodd) c.D2D1_FILL_MODE_ALTERNATE else c.D2D1_FILL_MODE_WINDING);
        var open = false;
        var last: P2 = .{ .x = 0, .y = 0 };
        var fig_start: P2 = last;
        for (cv.path.items) |op| switch (op) {
            .move => |pt| {
                if (open) sv.EndFigure.?(sk, c.D2D1_FIGURE_END_OPEN);
                sv.BeginFigure.?(sk, pt, c.D2D1_FIGURE_BEGIN_FILLED);
                open = true;
                last = pt;
                fig_start = pt;
            },
            .line => |pt| {
                if (!open) {
                    sv.BeginFigure.?(sk, last, c.D2D1_FIGURE_BEGIN_FILLED);
                    open = true;
                    fig_start = last;
                }
                sv.AddLines.?(sk, &pt, 1);
                last = pt;
            },
            .bezier => |b| {
                if (!open) {
                    sv.BeginFigure.?(sk, last, c.D2D1_FIGURE_BEGIN_FILLED);
                    open = true;
                    fig_start = last;
                }
                const seg: c.D2D1_BEZIER_SEGMENT = .{ .point1 = b[0], .point2 = b[1], .point3 = b[2] };
                sv.AddBeziers.?(sk, &seg, 1);
                last = b[2];
            },
            .close => if (open) {
                sv.EndFigure.?(sk, c.D2D1_FIGURE_END_CLOSED);
                open = false;
                last = fig_start;
            },
        };
        if (open) sv.EndFigure.?(sk, c.D2D1_FIGURE_END_OPEN);
        if (sv.Close.?(sk) < 0) {
            releaseCom(geo);
            return null;
        }
        return geo;
    }

    /// A paint's brush with the global alpha in (caller releases); null:
    /// nothing to paint with (a gradient without stops).
    fn brushOf(cv: *CanvasPainter, src: tree_mod.CanvasPaint) ?*c.ID2D1Brush {
        switch (src) {
            .color => |col| {
                const v = d2dColor(.{ col[0], col[1], col[2], col[3] * cv.st.alpha });
                cv.solid.lpVtbl.*.SetColor.?(cv.solid, &v);
                addRef(cv.solid);
                return @ptrCast(cv.solid);
            },
            .grad => |id| {
                const g = cv.grads.getPtr(id) orelse return null;
                const b = cv.gradientBrush(g) orelse return null;
                b.lpVtbl.*.SetOpacity.?(b, cv.st.alpha);
                return b;
            },
        }
    }

    fn gradientBrush(cv: *CanvasPainter, g: *const CanvasGrad) ?*c.ID2D1Brush {
        if (g.stops.items.len == 0) return null;
        const stops = cv.gpa.dupe(c.D2D1_GRADIENT_STOP, g.stops.items) catch return null;
        defer cv.gpa.free(stops);
        // In offset order; stops at the same offset keep theirs (stable).
        std.sort.insertion(c.D2D1_GRADIENT_STOP, stops, {}, struct {
            fn less(_: void, a: c.D2D1_GRADIENT_STOP, b: c.D2D1_GRADIENT_STOP) bool {
                return a.position < b.position;
            }
        }.less);
        // A radial gradient's inner circle (concentric, as Direct2D draws
        // one): the stops start at r0.
        if (g.radial and g.g[2] > 0 and g.g[5] > 0) {
            const k = std.math.clamp(g.g[2] / g.g[5], 0, 1);
            for (stops) |*st| st.position = k + st.position * (1 - k);
        }
        const vt = cv.rt.lpVtbl.*;
        var coll: ?*c.ID2D1GradientStopCollection = null;
        if (vt.CreateGradientStopCollection.?(cv.rt, stops.ptr, @intCast(stops.len), c.D2D1_GAMMA_2_2, c.D2D1_EXTEND_MODE_CLAMP, &coll) < 0) return null;
        defer releaseCom(coll);
        if (g.radial) {
            const props: c.D2D1_RADIAL_GRADIENT_BRUSH_PROPERTIES = .{
                .center = .{ .x = g.g[3], .y = g.g[4] },
                .gradientOriginOffset = .{ .x = g.g[0] - g.g[3], .y = g.g[1] - g.g[4] },
                .radiusX = @max(0.001, g.g[5]),
                .radiusY = @max(0.001, g.g[5]),
            };
            var b: ?*c.ID2D1RadialGradientBrush = null;
            if (vt.CreateRadialGradientBrush.?(cv.rt, &props, null, coll, &b) < 0) return null;
            return @ptrCast(b);
        }
        const props: c.D2D1_LINEAR_GRADIENT_BRUSH_PROPERTIES = .{
            .startPoint = .{ .x = g.g[0], .y = g.g[1] },
            .endPoint = .{ .x = g.g[2], .y = g.g[3] },
        };
        var b: ?*c.ID2D1LinearGradientBrush = null;
        if (vt.CreateLinearGradientBrush.?(cv.rt, &props, null, coll, &b) < 0) return null;
        return @ptrCast(b);
    }

    fn setGrad(cv: *CanvasPainter, id: u16, radial: bool, g: [6]f32) void {
        if (cv.grads.fetchRemove(id)) |old| {
            var o = old.value;
            o.stops.deinit(cv.gpa);
        }
        cv.grads.put(id, .{ .radial = radial, .g = g }) catch {};
    }

    fn strokeStyleOf(cv: *CanvasPainter) ?*c.ID2D1StrokeStyle {
        const caps = [3][]const u8{ "butt", "round", "square" };
        const joins = [3][]const u8{ "miter", "round", "bevel" };
        return strokeStyle(caps[@min(2, cv.st.cap)], joins[@min(2, cv.st.join)]);
    }

    /// Fills or strokes a geometry in the bitmap's space. Drawn back in
    /// user space (the geometry through the inverse transform, the target
    /// through the transform) so a gradient's points and the line width
    /// are the program's; a plain fill needs neither.
    fn draw(cv: *CanvasPainter, geo: *c.ID2D1Geometry, src: tree_mod.CanvasPaint, stroke: bool) void {
        const brush = cv.brushOf(src) orelse return;
        defer releaseCom(@as(?*c.ID2D1Brush, brush));
        const vt = cv.rt.lpVtbl.*;
        if (!stroke and src == .color) {
            vt.SetTransform.?(cv.rt, &identity);
            vt.FillGeometry.?(cv.rt, geo, brush, null);
            return;
        }
        const inv = invert(cv.st.xf) orelse return;
        const fac = d2d.?;
        var tg: ?*c.ID2D1TransformedGeometry = null;
        if (fac.lpVtbl.*.CreateTransformedGeometry.?(fac, geo, &inv, &tg) < 0 or tg == null) return;
        defer releaseCom(tg);
        vt.SetTransform.?(cv.rt, &cv.st.xf);
        if (stroke) {
            const style = cv.strokeStyleOf();
            defer releaseCom(style);
            vt.DrawGeometry.?(cv.rt, @ptrCast(tg), brush, @max(0.1, cv.st.lw), style);
        } else vt.FillGeometry.?(cv.rt, @ptrCast(tg), brush, null);
    }

    /// fillRect / strokeRect: their own rectangle; the current path stays.
    fn rectOp(cv: *CanvasPainter, r: [4]f32, stroke: bool) void {
        const brush = cv.brushOf(if (stroke) cv.st.stroke else cv.st.fill) orelse return;
        defer releaseCom(@as(?*c.ID2D1Brush, brush));
        const rc: c.D2D1_RECT_F = .{ .left = @min(r[0], r[0] + r[2]), .top = @min(r[1], r[1] + r[3]), .right = @max(r[0], r[0] + r[2]), .bottom = @max(r[1], r[1] + r[3]) };
        const vt = cv.rt.lpVtbl.*;
        vt.SetTransform.?(cv.rt, &cv.st.xf);
        if (stroke) {
            const style = cv.strokeStyleOf();
            defer releaseCom(style);
            vt.DrawRectangle.?(cv.rt, &rc, brush, @max(0.1, cv.st.lw), style);
        } else vt.FillRectangle.?(cv.rt, &rc, brush);
    }

    fn pushClip(cv: *CanvasPainter, geo: *c.ID2D1PathGeometry) void {
        // The mask is in the bitmap's space: no transform.
        cv.rt.lpVtbl.*.SetTransform.?(cv.rt, &identity);
        const params: c.D2D1_LAYER_PARAMETERS = .{
            .contentBounds = .{ .left = -1e6, .top = -1e6, .right = 1e6, .bottom = 1e6 },
            .geometricMask = @ptrCast(geo),
            .maskAntialiasMode = c.D2D1_ANTIALIAS_MODE_PER_PRIMITIVE,
            .maskTransform = identity,
            .opacity = 1,
            .opacityBrush = null,
            .layerOptions = c.D2D1_LAYER_OPTIONS_NONE,
        };
        cv.rt.lpVtbl.*.PushLayer.?(cv.rt, &params, null);
    }

    /// Pops the clip layers above `keep` (and releases their masks).
    fn popClips(cv: *CanvasPainter, keep: usize) void {
        while (cv.clips.items.len > keep) {
            const g = cv.clips.pop().?;
            cv.rt.lpVtbl.*.PopLayer.?(cv.rt);
            releaseCom(@as(?*c.ID2D1PathGeometry, g));
        }
    }

    /// To transparent, in the bitmap only (whatever's behind the canvas
    /// shows there: its own CSS background, as in a browser).
    fn clearRect(cv: *CanvasPainter, r: [4]f32) void {
        const pts = [4]P2{ cv.point(r[0], r[1]), cv.point(r[0] + r[2], r[1]), cv.point(r[0] + r[2], r[1] + r[3]), cv.point(r[0], r[1] + r[3]) };
        const vt = cv.rt.lpVtbl.*;
        const m = mget(cv.st.xf);
        const none: c.D2D1_COLOR_F = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        if (cv.clips.items.len == 0 and m[1] == 0 and m[2] == 0) {
            // Axis-aligned, unclipped: the common case (a game loop's clear).
            var rc: c.D2D1_RECT_F = .{ .left = pts[0].x, .top = pts[0].y, .right = pts[0].x, .bottom = pts[0].y };
            for (pts[1..]) |pt| {
                rc.left = @min(rc.left, pt.x);
                rc.top = @min(rc.top, pt.y);
                rc.right = @max(rc.right, pt.x);
                rc.bottom = @max(rc.bottom, pt.y);
            }
            vt.SetTransform.?(cv.rt, &identity);
            vt.PushAxisAlignedClip.?(cv.rt, &rc, c.D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
            vt.Clear.?(cv.rt, &none);
            vt.PopAxisAlignedClip.?(cv.rt);
            return;
        }
        // Rotated or clipped: the quad (inside the clips) copied over as
        // transparent. Out of the clip layers first: inside one, a clear
        // would only clear the layer, not the bitmap under it.
        const dc = cv.dc orelse return;
        var geo: *c.ID2D1Geometry = @ptrCast(polygonGeometry(&pts) orelse return);
        defer releaseCom(@as(?*c.ID2D1Geometry, geo));
        for (cv.clips.items) |clip| {
            const next = intersectGeometry(geo, @ptrCast(clip)) orelse return;
            releaseCom(@as(?*c.ID2D1Geometry, geo));
            geo = @ptrCast(next);
        }
        for (cv.clips.items) |_| vt.PopLayer.?(cv.rt);
        vt.SetTransform.?(cv.rt, &identity);
        cv.solid.lpVtbl.*.SetColor.?(cv.solid, &none);
        dc.lpVtbl.*.SetPrimitiveBlend.?(dc, c.D2D1_PRIMITIVE_BLEND_COPY);
        vt.FillGeometry.?(cv.rt, geo, @ptrCast(cv.solid), null);
        dc.lpVtbl.*.SetPrimitiveBlend.?(dc, c.D2D1_PRIMITIVE_BLEND_SOURCE_OVER);
        for (cv.clips.items) |clip| cv.pushClip(clip);
    }

    /// fillText / strokeText: one line (DirectWrite), placed by textAlign
    /// and textBaseline.
    fn text(cv: *CanvasPainter, t: []const u8, x: f32, y: f32, stroke: bool) void {
        const font = cv.st.font;
        if (t.len == 0 or !(font.size > 0)) return;
        const u = std.unicode.utf8ToUtf16LeAlloc(cv.gpa, t) catch return;
        defer cv.gpa.free(u);
        const family = std.unicode.utf8ToUtf16LeAllocZ(cv.gpa, canvasFamily(font.family)) catch return;
        defer cv.gpa.free(family);
        const dw = dwrite.?;
        const weight: c.DWRITE_FONT_WEIGHT = @intFromFloat(std.math.clamp(font.weight, 1, 999));
        const style: c.DWRITE_FONT_STYLE = if (font.italic) c.DWRITE_FONT_STYLE_ITALIC else c.DWRITE_FONT_STYLE_NORMAL;
        var format: ?*c.IDWriteTextFormat = null;
        if (dw.lpVtbl.*.CreateTextFormat.?(dw, family.ptr, null, weight, style, c.DWRITE_FONT_STRETCH_NORMAL, font.size, std.unicode.utf8ToUtf16LeStringLiteral(""), &format) < 0 or format == null) return;
        defer releaseCom(format);
        _ = format.?.lpVtbl.*.SetWordWrapping.?(format, c.DWRITE_WORD_WRAPPING_NO_WRAP);
        var layout: ?*c.IDWriteTextLayout = null;
        if (dw.lpVtbl.*.CreateTextLayout.?(dw, u.ptr, @intCast(u.len), format, 1e6, 1e6, &layout) < 0 or layout == null) return;
        defer releaseCom(layout);
        const l = layout.?;
        var m: c.DWRITE_TEXT_METRICS = undefined;
        if (l.lpVtbl.*.GetMetrics.?(l, &m) < 0) return;
        var lm: [1]c.DWRITE_LINE_METRICS = undefined;
        var lines: u32 = 0;
        const baseline: f32 = if (l.lpVtbl.*.GetLineMetrics.?(l, &lm, 1, &lines) >= 0 and lines > 0) lm[0].baseline else font.size * 0.8;
        // The layout's top-left from the anchor (x, y).
        var tx = x;
        var ty = y;
        switch (cv.st.talign) {
            1 => tx -= m.width / 2,
            2 => tx -= m.width,
            else => {},
        }
        switch (cv.st.tbase) {
            1 => {}, // top
            3 => ty -= m.height / 2, // middle
            4 => ty -= m.height, // bottom
            else => ty -= baseline, // alphabetic / hanging
        }
        const vt = cv.rt.lpVtbl.*;
        if (!stroke) {
            const brush = cv.brushOf(cv.st.fill) orelse return;
            defer releaseCom(@as(?*c.ID2D1Brush, brush));
            vt.SetTransform.?(cv.rt, &cv.st.xf);
            vt.DrawTextLayout.?(cv.rt, .{ .x = tx, .y = ty }, l, brush, draw_text_color_font);
            return;
        }
        // The glyphs' outlines, stroked (the current path stays out of it).
        const outline = glyphOutline(cv.gpa, t, family, weight, style, font.size) orelse return;
        defer releaseCom(@as(?*c.ID2D1PathGeometry, outline));
        const fac = d2d.?;
        const at = matrix(1, 0, 0, 1, tx, ty + baseline);
        var tg: ?*c.ID2D1TransformedGeometry = null;
        if (fac.lpVtbl.*.CreateTransformedGeometry.?(fac, @ptrCast(outline), &at, &tg) < 0 or tg == null) return;
        defer releaseCom(tg);
        const brush = cv.brushOf(cv.st.stroke) orelse return;
        defer releaseCom(@as(?*c.ID2D1Brush, brush));
        const st_style = cv.strokeStyleOf();
        defer releaseCom(st_style);
        vt.SetTransform.?(cv.rt, &cv.st.xf);
        vt.DrawGeometry.?(cv.rt, @ptrCast(tg), brush, @max(0.1, cv.st.lw), st_style);
    }
};

/// A canvas font's family: the first of the list, the generic ones as
/// Windows' faces.
fn canvasFamily(family: []const u8) []const u8 {
    const first = std.mem.trim(u8, if (std.mem.indexOfScalar(u8, family, ',')) |i| family[0..i] else family, " \t'\"");
    if (first.len == 0 or std.ascii.eqlIgnoreCase(first, "sans-serif") or std.ascii.eqlIgnoreCase(first, "system-ui")) return "Segoe UI";
    if (std.ascii.eqlIgnoreCase(first, "monospace")) return "Consolas";
    if (std.ascii.eqlIgnoreCase(first, "serif")) return "Times New Roman";
    return first;
}

/// A closed polygon (caller releases).
fn polygonGeometry(pts: []const P2) ?*c.ID2D1PathGeometry {
    const fac = d2d.?;
    var geo: ?*c.ID2D1PathGeometry = null;
    if (fac.lpVtbl.*.CreatePathGeometry.?(fac, &geo) < 0 or geo == null) return null;
    var sink: ?*c.ID2D1GeometrySink = null;
    if (geo.?.lpVtbl.*.Open.?(geo, &sink) < 0 or sink == null) {
        releaseCom(geo);
        return null;
    }
    defer releaseCom(sink);
    const sk: *c.ID2D1SimplifiedGeometrySink = @ptrCast(sink.?);
    const sv = sk.lpVtbl.*;
    sv.BeginFigure.?(sk, pts[0], c.D2D1_FIGURE_BEGIN_FILLED);
    sv.AddLines.?(sk, pts[1..].ptr, @intCast(pts.len - 1));
    sv.EndFigure.?(sk, c.D2D1_FIGURE_END_CLOSED);
    if (sv.Close.?(sk) < 0) {
        releaseCom(geo);
        return null;
    }
    return geo;
}

/// a ∩ b as a new geometry (caller releases).
fn intersectGeometry(a: *c.ID2D1Geometry, b: *c.ID2D1Geometry) ?*c.ID2D1PathGeometry {
    const fac = d2d.?;
    var geo: ?*c.ID2D1PathGeometry = null;
    if (fac.lpVtbl.*.CreatePathGeometry.?(fac, &geo) < 0 or geo == null) return null;
    var sink: ?*c.ID2D1GeometrySink = null;
    if (geo.?.lpVtbl.*.Open.?(geo, &sink) < 0 or sink == null) {
        releaseCom(geo);
        return null;
    }
    defer releaseCom(sink);
    const ok = a.lpVtbl.*.CombineWithGeometry.?(a, b, c.D2D1_COMBINE_MODE_INTERSECT, null, 0.25, @ptrCast(sink)) >= 0;
    const sk: *c.ID2D1SimplifiedGeometrySink = @ptrCast(sink.?);
    if (sk.lpVtbl.*.Close.?(sk) < 0 or !ok) {
        releaseCom(geo);
        return null;
    }
    return geo;
}

/// strokeText's glyphs as one geometry, the baseline's origin at (0, 0)
/// (caller releases). The family's own glyphs only (no fallback fonts).
fn glyphOutline(gpa: std.mem.Allocator, t: []const u8, family: [:0]const u16, weight: c.DWRITE_FONT_WEIGHT, style: c.DWRITE_FONT_STYLE, size: f32) ?*c.ID2D1PathGeometry {
    const dw = dwrite.?;
    var coll: ?*c.IDWriteFontCollection = null;
    if (dw.lpVtbl.*.GetSystemFontCollection.?(dw, &coll, c.FALSE) < 0 or coll == null) return null;
    defer releaseCom(coll);
    const cl = coll.?;
    var index: u32 = 0;
    var exists: c.BOOL = c.FALSE;
    if (cl.lpVtbl.*.FindFamilyName.?(cl, family.ptr, &index, &exists) < 0 or exists == c.FALSE) {
        if (cl.lpVtbl.*.FindFamilyName.?(cl, sans_face, &index, &exists) < 0 or exists == c.FALSE) return null;
    }
    var fam: ?*c.IDWriteFontFamily = null;
    if (cl.lpVtbl.*.GetFontFamily.?(cl, index, &fam) < 0 or fam == null) return null;
    defer releaseCom(fam);
    var font: ?*c.IDWriteFont = null;
    if (fam.?.lpVtbl.*.GetFirstMatchingFont.?(fam, weight, c.DWRITE_FONT_STRETCH_NORMAL, style, &font) < 0 or font == null) return null;
    defer releaseCom(font);
    var face: ?*c.IDWriteFontFace = null;
    if (font.?.lpVtbl.*.CreateFontFace.?(font, &face) < 0 or face == null) return null;
    defer releaseCom(face);
    const fc = face.?;

    var cps: std.ArrayList(u32) = .empty;
    defer cps.deinit(gpa);
    var it = (std.unicode.Utf8View.init(t) catch return null).iterator();
    while (it.nextCodepoint()) |cp| cps.append(gpa, cp) catch return null;
    if (cps.items.len == 0) return null;
    const glyphs = gpa.alloc(u16, cps.items.len) catch return null;
    defer gpa.free(glyphs);
    const metrics = gpa.alloc(c.DWRITE_GLYPH_METRICS, cps.items.len) catch return null;
    defer gpa.free(metrics);
    const advances = gpa.alloc(f32, cps.items.len) catch return null;
    defer gpa.free(advances);
    if (fc.lpVtbl.*.GetGlyphIndicesW.?(fc, cps.items.ptr, @intCast(cps.items.len), glyphs.ptr) < 0) return null;
    if (fc.lpVtbl.*.GetDesignGlyphMetrics.?(fc, glyphs.ptr, @intCast(glyphs.len), metrics.ptr, c.FALSE) < 0) return null;
    var fm: c.DWRITE_FONT_METRICS = undefined;
    fc.lpVtbl.*.GetMetrics.?(fc, &fm);
    const upem: f32 = @floatFromInt(@max(1, fm.designUnitsPerEm));
    for (metrics, advances) |gm, *adv| adv.* = @as(f32, @floatFromInt(gm.advanceWidth)) * size / upem;

    const fac = d2d.?;
    var geo: ?*c.ID2D1PathGeometry = null;
    if (fac.lpVtbl.*.CreatePathGeometry.?(fac, &geo) < 0 or geo == null) return null;
    var sink: ?*c.ID2D1GeometrySink = null;
    if (geo.?.lpVtbl.*.Open.?(geo, &sink) < 0 or sink == null) {
        releaseCom(geo);
        return null;
    }
    defer releaseCom(sink);
    const ok = fc.lpVtbl.*.GetGlyphRunOutline.?(fc, size, glyphs.ptr, advances.ptr, null, @intCast(glyphs.len), c.FALSE, c.FALSE, @ptrCast(sink)) >= 0;
    const sk: *c.ID2D1SimplifiedGeometrySink = @ptrCast(sink.?);
    if (sk.lpVtbl.*.Close.?(sk) < 0 or !ok) {
        releaseCom(geo);
        return null;
    }
    return geo;
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
    // All of the window's pictures together at most max_image_cache_bytes:
    // past it the others go before this one is kept (they decode again
    // when painted).
    var total = img.bytes();
    var it = s.images.valueIterator();
    while (it.next()) |other| total += other.bytes();
    if (total > max_image_cache_bytes) {
        var rest = s.images.valueIterator();
        while (rest.next()) |other| other.deinit();
        s.images.clearRetainingCapacity();
    }
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

/// A text's size at `width` (inf: unwrapped), through the shared cache
/// (keyed by the text and every layout input, so equal rows share it).
fn measuredText(s: *Surface, n: *Node, width: f32) ?[2]f32 {
    const actual_width = if (n.props.nowrap or std.math.isInf(width)) std.math.inf(f32) else @max(1, width);
    // One line of plain text: its width from its glyph pairs, no layout.
    if (fastTextSize(s, &n.props)) |size| if (std.math.isInf(actual_width) or size[0] - 1 <= actual_width) {
        if (textCheck()) checkTextSize(s, n, actual_width, size);
        return size;
    };
    var buf: [1024]u8 = undefined;
    const key = text_measure_cache.keyFor(&buf, &n.props, actual_width);
    if (key) |k| if (s.text_measurements.get(k)) |size| return size;
    const layout = textLayout(s, n, actual_width, null) orelse return null;
    defer releaseCom(@as(?*c.IDWriteTextLayout, layout));
    var m: c.DWRITE_TEXT_METRICS = undefined;
    if (layout.lpVtbl.*.GetMetrics.?(layout, &m) < 0) return null;
    const size: [2]f32 = .{ @ceil(m.widthIncludingTrailingWhitespace) + 1, @ceil(m.height) };
    if (key) |k| s.text_measurements.put(s.gpa, k, size) catch {};
    return size;
}

// ---------------------------------------------------------------------------
// Plain text without a layout (gtk.zig's scheme): one run of printable
// ASCII on one line is as wide as its glyphs, each as wide as DirectWrite
// makes it before the next one (its advance with the pair's kerning).
// Those widths are measured once per font and pair, with DirectWrite
// itself: width("ab") - width("b"). A pair DirectWrite makes one cluster
// (a ligature), more than one run, letter spacing, other characters or a
// text that wraps take the layout. ORIEL_NUI_TEXT_CHECK=1 measures both and
// logs any difference. A new string was an IDWriteTextLayout (~19 µs):
// most of render-bench's "update 1000 rows".

const FontKey = struct { mono: bool, italic: bool, weight: u16, size: u32, fz: u32, lh: i32 };
const pair_unknown: f32 = -1e30;
const pair_ligature: f32 = -2e30;
const PairWidths = struct {
    /// Single-line height in DIPs, rounded up as measuredText's (0: not
    /// measured yet).
    height: f32 = 0,
    /// [a][b]: a's width in DIPs before b (b = 128: at the end).
    w: [128][129]f32 = @splat(@splat(pair_unknown)),
};

fn clearGlyphWidths(s: *Surface) void {
    var it = s.glyph_widths.valueIterator();
    while (it.next()) |t| s.gpa.destroy(t.*);
    s.glyph_widths.clearRetainingCapacity();
}

fn fastTextSize(s: *Surface, props: *const tree_mod.Props) ?[2]f32 {
    const runs = props.runs orelse return null;
    if (runs.len != 1 or props.ls != null) return null;
    const r = runs[0];
    const t = r.t;
    if (t.len == 0 or t.len > 512) return null;
    for (t) |ch| if (ch < 0x20 or ch >= 0x7f) return null;
    const key: FontKey = .{
        .mono = r.mono or props.mono,
        .italic = r.i,
        .weight = tree_mod.sat(u16, r.w),
        .size = tree_mod.sat(u32, r.sz * 64),
        .fz = tree_mod.sat(u32, (props.fz orelse 16) * 64),
        .lh = if (props.lh) |lh| tree_mod.sat(i32, lh * 64) else -1,
    };
    const table = s.glyph_widths.get(key) orelse blk: {
        if (s.glyph_widths.count() >= 64) clearGlyphWidths(s);
        const tbl = s.gpa.create(PairWidths) catch return null;
        tbl.* = .{};
        s.glyph_widths.put(s.gpa, key, tbl) catch {
            s.gpa.destroy(tbl);
            return null;
        };
        break :blk tbl;
    };
    if (table.height == 0) {
        const p = probe(s, props, r, "A") orelse return null;
        table.height = @ceil(p.h);
    }
    var sum: f64 = 0;
    for (t, 0..) |ch, i| {
        const next: u8 = if (i + 1 < t.len) t[i + 1] else 128;
        sum += pairWidth(s, props, r, table, ch, next) orelse return null;
    }
    // As measuredText rounds DirectWrite's width; a sum of pairs may land
    // a hair over a whole number the layout's own sum lands on.
    const w: f32 = @floatCast(sum);
    return .{ @ceil(w - 0.001) + 1, table.height };
}

fn pairWidth(s: *Surface, props: *const tree_mod.Props, r: tree_mod.Run, table: *PairWidths, a: u8, b: u8) ?f32 {
    const known = table.w[a][b];
    if (known == pair_ligature) return null;
    if (known != pair_unknown) return known;
    var w: f32 = undefined;
    if (b == 128) {
        const one = [1]u8{a};
        w = (probe(s, props, r, &one) orelse return null).w;
    } else {
        const two = [2]u8{ a, b };
        const pair = probe(s, props, r, &two) orelse return null;
        const after = pairWidth(s, props, r, table, b, 128) orelse return null;
        if (pair.clusters != 2) {
            table.w[a][b] = pair_ligature;
            return null;
        }
        w = pair.w - after;
    }
    table.w[a][b] = w;
    return w;
}

/// `text` laid out on one line with the run's style: its width (trailing
/// spaces included), height and clusters.
fn probe(s: *Surface, props: *const tree_mod.Props, r: tree_mod.Run, text: []const u8) ?struct { w: f32, h: f32, clusters: u32 } {
    var run = r;
    run.t = text;
    var p = props.*;
    p.runs = @as(*const [1]tree_mod.Run, &run);
    const layout = textLayoutOf(s, &p, std.math.inf(f32), null) orelse return null;
    defer releaseCom(@as(?*c.IDWriteTextLayout, layout));
    var m: c.DWRITE_TEXT_METRICS = undefined;
    if (layout.lpVtbl.*.GetMetrics.?(layout, &m) < 0) return null;
    // With no buffer it reports how many there are (and fails).
    var clusters: u32 = 0;
    _ = layout.lpVtbl.*.GetClusterMetrics.?(layout, null, 0, &clusters);
    return .{ .w = m.widthIncludingTrailingWhitespace, .h = m.height, .clusters = clusters };
}

var text_check: ?bool = null;

/// ORIEL_NUI_TEXT_CHECK is set (read once).
fn textCheck() bool {
    if (text_check == null) text_check = c.GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("ORIEL_NUI_TEXT_CHECK"), null, 0) > 0;
    return text_check.?;
}

/// ORIEL_NUI_TEXT_CHECK: the fast size against DirectWrite's layout.
fn checkTextSize(s: *Surface, n: *Node, width: f32, fast: [2]f32) void {
    const layout = textLayout(s, n, width, null) orelse return;
    defer releaseCom(@as(?*c.IDWriteTextLayout, layout));
    var m: c.DWRITE_TEXT_METRICS = undefined;
    if (layout.lpVtbl.*.GetMetrics.?(layout, &m) < 0) return;
    const size: [2]f32 = .{ @ceil(m.widthIncludingTrailingWhitespace) + 1, @ceil(m.height) };
    if (size[0] != fast[0] or size[1] != fast[1]) {
        const t = if (n.props.runs) |runs| runs[0].t else "";
        log.warn("text size: fast {d}x{d}, DirectWrite {d}x{d} ({d}): \"{s}\"", .{ fast[0], fast[1], size[0], size[1], m.widthIncludingTrailingWhitespace, t[0..@min(t.len, 60)] });
    }
}

/// New props or a new text (the direct bridge): measured again.
fn propsChanged(ctx: *anyopaque, node: *Node, _: std.json.Value) void {
    textChanged(ctx, node);
}

fn textChanged(_: *anyopaque, node: *Node) void {
    node.measured_text_size = null;
}

fn measure(ctx: *anyopaque, n: *Node, max_width: f32, out: *[2]f32) void {
    const s = surfaceOf(ctx);
    const fz = n.props.fz orelse 16;
    switch (n.kind) {
        .text => {
            // Its natural size (kept on the node until its props or text
            // change); at a width it fits in, that's the answer. Yoga asks
            // several times per node and layout: a DirectWrite layout each
            // time was most of a big list's update.
            const nat = if (n.measured_text_size != null and n.text_measure_epoch == s.text_epoch) n.measured_text_size.? else blk: {
                const size = measuredText(s, n, std.math.inf(f32)) orelse return;
                n.measured_text_size = size;
                n.text_measure_epoch = s.text_epoch;
                break :blk size;
            };
            if (n.props.nowrap or max_width >= nat[0]) {
                out.* = nat;
                return;
            }
            out.* = measuredText(s, n, max_width) orelse return;
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
    const t0 = prof.now();
    if (s.engine.tree.needsLayout()) s.engine.tree.layout();
    const t1 = prof.now();
    if (!ensureTarget(s)) return;
    const t2 = prof.now();
    var t3: f64 = t2;
    defer prof.report("draw layout {d:.2} target {d:.2} paint {d:.2} present {d:.2}", .{ t1 - t0, t2 - t1, t3 - t2, prof.now() - t3 });
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
    t3 = prof.now();
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
    if (props.bw) |bw| border(p, f, r, bw, props.bc, props.bs);
    switch (n.kind) {
        .text => paintText(p, n),
        .icon => paintIcon(p, n),
        .image => paintImage(p, n),
        .view => if (n.props.ctl != null) paintControl(p, n),
        .canvas => paintCanvas(p, n),
        else => {},
    }
    // CSS paint order: positioned boxes (a sticky header) over the flow.
    var it: tree_mod.PaintIter = .{ .kids = n.kids.items };
    while (it.next()) |k| paint(p, k);
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

fn strokeShape(p: *Painter, f: Rect, r: [4]f32, brush: *c.ID2D1Brush, width: f32, st: ?*c.ID2D1StrokeStyle) void {
    if (f.w <= 0 or f.h <= 0) return;
    const vt = p.vt();
    if (uniform(r)) {
        if (r[0] <= 0) {
            const rc = rectF(f);
            vt.DrawRectangle.?(p.rt, &rc, brush, width, st);
        } else {
            const rr: c.D2D1_ROUNDED_RECT = .{ .rect = rectF(f), .radiusX = r[0], .radiusY = r[0] };
            vt.DrawRoundedRectangle.?(p.rt, &rr, brush, width, st);
        }
        return;
    }
    const geo = roundRectGeometry(f, r) orelse return;
    defer releaseCom(@as(?*c.ID2D1PathGeometry, geo));
    vt.DrawGeometry.?(p.rt, @ptrCast(geo), brush, width, st);
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
    if (g.radialIn(f.w, f.h)) |rad| {
        const props: c.D2D1_RADIAL_GRADIENT_BRUSH_PROPERTIES = .{
            .center = .{ .x = f.x + rad[0], .y = f.y + rad[1] },
            .gradientOriginOffset = .{ .x = 0, .y = 0 },
            .radiusX = rad[2],
            .radiusY = rad[3],
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

/// Dashed and dotted borders' strokes, made once: dashes 3 widths long
/// with 3-width gaps, square dots a width apart for thin borders, round
/// ones from 3 px (as Chromium draws them).
var border_strokes: [3]?*c.ID2D1StrokeStyle = .{ null, null, null };

fn borderStroke(bs: ?tree_mod.BorderStyle, width: f32) ?*c.ID2D1StrokeStyle {
    const style = bs orelse return null;
    const i: usize = switch (style) {
        .dashed => 0,
        .dotted => if (width < 3) 1 else 2,
    };
    if (border_strokes[i]) |st| return st;
    const fac = d2d orelse return null;
    const dashes: []const f32 = switch (i) {
        0 => &.{ 3, 3 },
        1 => &.{ 1, 1 },
        else => &.{ 0, 2 },
    };
    const cap: c.D2D1_CAP_STYLE = if (i == 2) c.D2D1_CAP_STYLE_ROUND else c.D2D1_CAP_STYLE_FLAT;
    const props: c.D2D1_STROKE_STYLE_PROPERTIES = .{ .startCap = c.D2D1_CAP_STYLE_FLAT, .endCap = c.D2D1_CAP_STYLE_FLAT, .dashCap = cap, .lineJoin = c.D2D1_LINE_JOIN_MITER, .miterLimit = 10, .dashStyle = c.D2D1_DASH_STYLE_CUSTOM, .dashOffset = 0 };
    var st: ?*c.ID2D1StrokeStyle = null;
    if (fac.lpVtbl.*.CreateStrokeStyle.?(fac, &props, dashes.ptr, @intCast(dashes.len), &st) < 0) return null;
    border_strokes[i] = st;
    return st;
}

/// One straight side dashed or dotted as Chromium draws it: a dash (3
/// widths; a dot: 1) at each end and whole ones between, the gaps
/// stretched to fit. Dots from 3 px are round.
fn dashedSide(p: *Painter, sd: Rect, across: bool, w: f32, style: tree_mod.BorderStyle, brush: *c.ID2D1Brush) void {
    const len = if (across) sd.w else sd.h;
    if (len <= 0 or w <= 0) return;
    const dash = if (style == .dashed) 3 * w else w;
    var n = @round((len + dash) / (2 * dash));
    if (n < 1) n = 1;
    const gap = if (n > 1) (len - n * dash) / (n - 1) else 0;
    const vt = p.vt();
    var k: f32 = 0;
    while (k < n) : (k += 1) {
        const at = k * (dash + gap);
        const d = if (n == 1) len else dash;
        const rc: Rect = if (across) .{ .x = sd.x + at, .y = sd.y, .w = d, .h = sd.h } else .{ .x = sd.x, .y = sd.y + at, .w = sd.w, .h = d };
        if (style == .dotted and w >= 3) {
            const e: c.D2D1_ELLIPSE = .{ .point = .{ .x = rc.x + rc.w / 2, .y = rc.y + rc.h / 2 }, .radiusX = w / 2, .radiusY = w / 2 };
            vt.FillEllipse.?(p.rt, &e, brush);
        } else {
            const rf = rectF(rc);
            vt.FillRectangle.?(p.rt, &rf, brush);
        }
    }
}

fn border(p: *Painter, f: Rect, r: [4]f32, bw: [4]f32, bc: ?[4]tree_mod.Color, bs: ?tree_mod.BorderStyle) void {
    const colors = bc orelse return;
    // Square corners, dashed or dotted: each side's dashes fitted to it
    // (the per-side path below); one pattern around the rectangle would
    // leave a side a stray dash.
    const square = uniform(r) and r[0] <= 0;
    if (uniform(bw) and bw[0] > 0 and !(bs != null and square)) {
        const st = borderStroke(bs, bw[0]);
        const half = bw[0] / 2;
        const inner: Rect = .{ .x = f.x + half, .y = f.y + half, .w = f.w - bw[0], .h = f.h - bw[0] };
        var ri = r;
        for (&ri) |*x| x.* = @max(0, x.* - half);
        const same = for (colors[1..]) |col| {
            if (!std.mem.eql(f32, &col, &colors[0])) break false;
        } else true;
        if (same) {
            strokeShape(p, inner, ri, p.solid(colors[0]), bw[0], st);
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
            strokeShape(p, inner, ri, p.solid(colors[i]), bw[0], st);
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
        if (bs) |style| {
            dashedSide(p, sd, i == 0 or i == 2, bw[i], style, p.solid(colors[i]));
            continue;
        }
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
