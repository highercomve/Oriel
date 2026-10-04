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
const Radii = tree_mod.Radii;
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
    @cInclude("dwrite_1.h");
    @cInclude("wincodec.h");
    @cInclude("commctrl.h");
    @cInclude("richedit.h");
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
/// On a text field that is a RichEdit (Field.rich).
const prop_rich = std.unicode.utf8ToUtf16LeStringLiteral("OrielNuiRich");

/// Text fields as RichEdit 5 (msftedit.dll: DirectWrite's colour emoji,
/// many undo steps) rather than EDIT (GDI: emoji in black and white, one
/// undo step). EDIT stays for when it's false or msftedit won't load.
const rich_edit = true;

var rich_loaded: ?bool = null;

fn loadRichEdit() bool {
    if (rich_loaded == null) rich_loaded = c.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("Msftedit.dll")) != null;
    return rich_loaded.?;
}

/// TO_DISPLAYFONTCOLOR (richedit.h of newer SDKs): colour fonts' colours.
const TO_DISPLAYFONTCOLOR: c.LPARAM = 0x0010;

/// A new RichEdit as a page's field: plain text (a paste brings no
/// formatting), many undo steps, EN_CHANGE, colour emoji.
fn setupRichEdit(hwnd: c.HWND) void {
    _ = c.SetPropW(hwnd, prop_rich, @ptrFromInt(1));
    _ = c.SendMessageW(hwnd, c.EM_SETTEXTMODE, c.TM_PLAINTEXT | c.TM_MULTILEVELUNDO | c.TM_MULTICODEPAGE, 0);
    _ = c.SendMessageW(hwnd, c.EM_SETEVENTMASK, 0, c.ENM_CHANGE);
    const typo: c.WPARAM = @intCast(c.TO_ADVANCEDTYPOGRAPHY | TO_DISPLAYFONTCOLOR);
    _ = c.SendMessageW(hwnd, c.EM_SETTYPOGRAPHYOPTIONS, typo, @intCast(typo));
}

/// A RichEdit's colours (it asks for no WM_CTLCOLOREDIT): its background
/// and all its text's colour.
fn richColors(f: *const Field) void {
    _ = c.SendMessageW(f.hwnd, c.EM_SETBKGNDCOLOR, 0, @intCast(f.bg));
    var cf: c.CHARFORMAT2W = std.mem.zeroes(c.CHARFORMAT2W);
    cf.cbSize = @sizeOf(c.CHARFORMAT2W);
    cf.dwMask = c.CFM_COLOR;
    cf.crTextColor = f.fg;
    _ = c.SendMessageW(f.hwnd, c.EM_SETCHARFORMAT, c.SCF_ALL, @bitCast(@intFromPtr(&cf)));
}

/// An edit's length in its own positions (a RichEdit counts a line break
/// once; GetWindowTextLength counts CR LF).
fn editLength(hwnd: c.HWND, rich: bool) c.DWORD {
    if (!rich) return @intCast(c.GetWindowTextLengthW(hwnd));
    var gtl: c.GETTEXTLENGTHEX = .{ .flags = c.GTL_PRECISE | c.GTL_NUMCHARS, .codepage = 1200 };
    const n = c.SendMessageW(hwnd, c.EM_GETTEXTLENGTHEX, @intFromPtr(&gtl), 0);
    return if (n < 0) 0 else @intCast(n);
}

/// A RichEdit's context menu (it has none of its own; an EDIT's): undo,
/// cut, copy, paste, delete, select all.
fn richMenu(hwnd: c.HWND, lparam: c.LPARAM) void {
    const menu = c.CreatePopupMenu() orelse return;
    defer _ = c.DestroyMenu(menu);
    var a: c.DWORD = 0;
    var b: c.DWORD = 0;
    _ = c.SendMessageW(hwnd, c.EM_GETSEL, @intFromPtr(&a), @bitCast(@intFromPtr(&b)));
    const selected = a != b;
    const can_undo = c.SendMessageW(hwnd, c.EM_CANUNDO, 0, 0) != 0;
    const can_paste = c.IsClipboardFormatAvailable(c.CF_UNICODETEXT) != 0;
    const items = [_]struct { id: usize, text: [:0]const u16, on: bool }{
        .{ .id = 1, .text = std.unicode.utf8ToUtf16LeStringLiteral("Undo"), .on = can_undo },
        .{ .id = 0, .text = std.unicode.utf8ToUtf16LeStringLiteral(""), .on = false },
        .{ .id = 2, .text = std.unicode.utf8ToUtf16LeStringLiteral("Cut"), .on = selected },
        .{ .id = 3, .text = std.unicode.utf8ToUtf16LeStringLiteral("Copy"), .on = selected },
        .{ .id = 4, .text = std.unicode.utf8ToUtf16LeStringLiteral("Paste"), .on = can_paste },
        .{ .id = 5, .text = std.unicode.utf8ToUtf16LeStringLiteral("Delete"), .on = selected },
        .{ .id = 0, .text = std.unicode.utf8ToUtf16LeStringLiteral(""), .on = false },
        .{ .id = 6, .text = std.unicode.utf8ToUtf16LeStringLiteral("Select All"), .on = editLength(hwnd, true) > 0 },
    };
    for (items) |it| {
        if (it.id == 0) {
            _ = c.AppendMenuW(menu, c.MF_SEPARATOR, 0, null);
        } else {
            _ = c.AppendMenuW(menu, @intCast(c.MF_STRING | (if (it.on) @as(c_long, 0) else @as(c_long, c.MF_GRAYED))), it.id, it.text.ptr);
        }
    }
    var x: c_int = @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam))))));
    var y: c_int = @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) >> 16))));
    if (lparam == -1) {
        // From the keyboard: at the caret.
        var pt: c.POINT = .{ .x = 0, .y = 0 };
        _ = c.GetCaretPos(&pt);
        _ = c.ClientToScreen(hwnd, &pt);
        x = pt.x;
        y = pt.y;
    }
    _ = c.SetFocus(hwnd);
    const cmd = c.TrackPopupMenu(menu, c.TPM_RETURNCMD | c.TPM_RIGHTBUTTON, x, y, 0, hwnd, null);
    switch (cmd) {
        1 => _ = c.SendMessageW(hwnd, c.EM_UNDO, 0, 0),
        2 => _ = c.SendMessageW(hwnd, c.WM_CUT, 0, 0),
        3 => _ = c.SendMessageW(hwnd, c.WM_COPY, 0, 0),
        4 => _ = c.SendMessageW(hwnd, c.WM_PASTE, 0, 0),
        5 => _ = c.SendMessageW(hwnd, c.WM_CLEAR, 0, 0),
        6 => _ = c.SendMessageW(hwnd, c.EM_SETSEL, 0, -1),
        else => {},
    }
}
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
    /// The font's family and weight (familyOf's, cached for the process).
    font_face: ?[*:0]const u16 = null,
    font_weight: c_int = 0,
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
    /// Its font's own (a themed combobox is never shorter than that and
    /// its frame: a smaller one only cuts the text).
    item_nat: c_int = 0,
    /// A RichEdit (rich_edit), not an EDIT: positions count a line break
    /// once, it paints no cue banner, colors by message.
    rich: bool = false,
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
    const v = @max(@max(8, f.item_nat), item_h);
    if (v == f.item_h) return;
    _ = c.SendMessageW(f.hwnd, c.CB_SETITEMHEIGHT, std.math.maxInt(usize), @intCast(v));
    f.item_h = v;
}

/// The UA style's field border (render.js: 2px inset #ccc, a select's and a
/// textarea's 1px, or 1px #767676) all round: the page didn't style it.
fn uaBorder(n: *Node) bool {
    const bw = n.props.bw orelse return false;
    const bc = n.props.bc orelse return false;
    for (bw, bc) |w, col| {
        const ua = ((w == 2 or w == 1) and col[0] == 204 and col[1] == 204 and col[2] == 204) or
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
    /// Mouse buttons down, as the DOM's `buttons` bits.
    buttons: u32 = 0,
    /// A pointer move waiting for the next display frame (queueMove).
    move: ?PendingMove = null,
    /// The touch or pen contact being followed (one at a time).
    contact: ?Contact = null,
    /// What keydown sent for each virtual key, for its keyup (a typed
    /// character comes as WM_CHAR, which keyup's key code doesn't say).
    key_names: [256][16]u8 = undefined,
    key_lens: [256]u8 = @splat(0),
    /// The last WM_KEYDOWN's virtual key: the key of the WM_CHAR it makes.
    char_vk: c.WPARAM = 0,
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
    /// The field node the page last heard has the keyboard ("focus" and
    /// "blur", focusCheck); 0: none.
    focused: i64 = 0,
    /// A field the page focused before its control existed (focus() right
    /// after showing it): given the keyboard once syncFields makes it.
    focus_pending: i64 = 0,
    /// A scrollbar the mouse is holding (onScrollbarDown): its scroller,
    /// the part, and for the thumb where in it the mouse took it.
    sb_node: i64 = 0,
    sb_part: SbPart = .none,
    sb_grab: f32 = 0,
    /// A WM_FOCUS_CHECK is queued.
    focus_check_posted: bool = false,
    /// OLE drops (dropTarget): the canvas's registered target, the drag
    /// over it now (its counter, what it carries, the last effect the
    /// page chose) and whether one is inside.
    drop_target: ?*DropTarget = null,
    drag_session: u32 = 0,
    drag_inside: bool = false,
    drag_kinds: DragKinds = .{},
    drag_effect: u32 = 0,

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
        const w = cssPx(rc.right - rc.left, s.scale);
        const h = cssPx(rc.bottom - rc.top, s.scale);
        s.engine = try Engine.create(gpa, .{
            .ctx = s,
            .measure = measure,
            .laid_out = laidOut,
            .removed = removed,
            .add_timer = addTimer,
            .request_display_frame = requestDisplayFrame,
            .warm_fonts = warmFonts,
            .font_metrics = fontMetrics,
            .font_metrics_family = fontMetricsFamily,
            .invoke = invoke,
            .focus = focus,
            .selection = selection,
            .set_selection = setSelection,
            .props = propsChanged,
            .text = textChanged,
        }, assets, platform_json, label, url, w, h);
        // WebView2's classic scrollbars (and thin ones) keep room in the layout.
        s.engine.tree.scrollbar = .{ 15, 10 };
        // Only now may the canvas reach the surface: before, `s.engine` is
        // undefined (and on failure the canvas goes away without it).
        _ = c.SetWindowLongPtrW(s.hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(s)));
        // Drops into the page (OLE: its fields' own targets are revoked).
        s.drop_target = registerDropTarget(s.hwnd);
        s.engine.boot(s.dark, false);
        return s;
    }

    /// The window goes away: the page, its fields and the canvas.
    pub fn destroy(s: *Surface) void {
        // The canvas stops reaching the surface first: destroying the
        // fields sends it messages (EN_KILLFOCUS, WM_CTLCOLOR*) while the
        // engine goes away, and its timers die with it below.
        _ = c.SetWindowLongPtrW(s.hwnd, c.GWLP_USERDATA, 0);
        // No more drops (OLE lets the target go once it's done with it).
        if (s.drop_target != null) _ = RevokeDragDrop(s.hwnd);
        s.drop_target = null;
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
        // In whole CSS px, rounded up, as Chromium lays a page out at a
        // fractional scale (784 px at 125%: 628, not 627.2); the page is
        // still drawn at the scale, its last fraction of a px cut.
        s.engine.resize(cssPx(pw, s.scale), cssPx(ph, s.scale), s.dark);
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
    // ORIEL_NUI_SCALE (testing): this scale instead of the monitor's, as
    // WebView2's --force-device-scale-factor.
    if (forcedScale()) |k| return k;
    const dpi = c.GetDpiForWindow(hwnd);
    return if (dpi == 0) 1 else @as(f32, @floatFromInt(dpi)) / 96.0;
}

/// Physical px as whole CSS px, rounded up (a hair of float error isn't a
/// px more: 785 / 1.25 is 628).
fn cssPx(physical: c_int, scale: f32) f32 {
    const v = @as(f32, @floatFromInt(physical)) / scale;
    return @ceil(v - 1e-3);
}

var forced_scale: ?f32 = null;
var forced_scale_read = false;

fn forcedScale() ?f32 {
    if (!forced_scale_read) {
        forced_scale_read = true;
        var buf: [32]u16 = undefined;
        const n = c.GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("ORIEL_NUI_SCALE"), &buf, buf.len);
        if (n > 0 and n < buf.len) {
            var ascii: [32]u8 = undefined;
            for (buf[0..n], 0..) |u, i| ascii[i] = if (u < 128) @intCast(u) else '?';
            const k = std.fmt.parseFloat(f32, ascii[0..n]) catch 0;
            if (k >= 0.5 and k <= 8) forced_scale = k;
        }
    }
    return forced_scale;
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
fn onDisplayFrame(s0: *Surface, hwnd: c.HWND) void {
    defer vsync.done(hwnd);
    // Input first, then the frame (as a browser): a move waiting goes to
    // the page, whose handler may ask for the frame that shows it.
    const s = flushMove(s0) orelse return;
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
    if (s.fields.get(node.id)) |f| {
        s.focus_pending = 0;
        _ = c.SetFocus(f.hwnd);
        return;
    }
    s.focus_pending = if (node.kind == .input or node.kind == .textarea or node.kind == .select) node.id else 0;
    // Not a field (a button, a link): the keyboard leaves the field that
    // had it, so typing goes to the page.
    const had = c.GetFocus() orelse return;
    if (had != s.hwnd and c.IsChild(s.hwnd, had) != 0) _ = c.SetFocus(s.hwnd);
}

/// Backend.selection: an edit's EM_GETSEL, in its value's units (a
/// textarea's CR LF line ends counted as the value's one LF).
fn selection(ctx: *anyopaque, node: *Node, out: *[2]u32) bool {
    const s = surfaceOf(ctx);
    const f = s.fields.get(node.id) orelse return false;
    if (f.kind != .input and f.kind != .textarea) return false;
    var a: c.DWORD = 0;
    var b: c.DWORD = 0;
    _ = c.SendMessageW(f.hwnd, c.EM_GETSEL, @intFromPtr(&a), @bitCast(@intFromPtr(&b)));
    out.* = .{ a, b };
    // An EDIT's CR LF counts twice; a RichEdit's line break once, as the
    // value's LF.
    if (f.kind == .textarea and !f.rich) {
        const crs = editCrs(s, f.hwnd, @max(a, b)) orelse return true;
        out.* = .{ a - crs[0], b - crs[1] };
    }
    return true;
}

/// Backend.set_selection: EM_SETSEL (a textarea's LF as its CR LF),
/// scrolled to.
fn setSelection(ctx: *anyopaque, node: *Node, start: u32, end: u32) void {
    const s = surfaceOf(ctx);
    const f = s.fields.get(node.id) orelse return;
    if (f.kind != .input and f.kind != .textarea) return;
    var a = start;
    var b = end;
    if (f.kind == .textarea and !f.rich) {
        a += valueLineBreaks(s, f.hwnd, start);
        b += valueLineBreaks(s, f.hwnd, end);
    }
    _ = c.SendMessageW(f.hwnd, c.EM_SETSEL, a, @intCast(b));
    _ = c.SendMessageW(f.hwnd, c.EM_SCROLLCARET, 0, 0);
}

/// How many CRs an edit's text has before positions a and b (its units),
/// for the first `upto` units read.
fn editCrs(s: *Surface, hwnd: c.HWND, upto: u32) ?[2]u32 {
    var a: c.DWORD = 0;
    var b: c.DWORD = 0;
    _ = c.SendMessageW(hwnd, c.EM_GETSEL, @intFromPtr(&a), @bitCast(@intFromPtr(&b)));
    const len: usize = @intCast(c.GetWindowTextLengthW(hwnd));
    const buf = s.gpa.alloc(u16, len + 1) catch return null;
    defer s.gpa.free(buf);
    const got: usize = @intCast(c.GetWindowTextW(hwnd, buf.ptr, @intCast(len + 1)));
    var out: [2]u32 = .{ 0, 0 };
    for (buf[0..@min(got, upto)], 0..) |u, i| if (u == 0x0D) {
        if (i < a) out[0] += 1;
        if (i < b) out[1] += 1;
    };
    return out;
}

/// How many line breaks a textarea's value has before value position `at`
/// (each is CR LF, one unit more, in the edit).
fn valueLineBreaks(s: *Surface, hwnd: c.HWND, at: u32) u32 {
    const len: usize = @intCast(c.GetWindowTextLengthW(hwnd));
    const buf = s.gpa.alloc(u16, len + 1) catch return 0;
    defer s.gpa.free(buf);
    const got: usize = @intCast(c.GetWindowTextW(hwnd, buf.ptr, @intCast(len + 1)));
    var value_pos: u32 = 0;
    var breaks: u32 = 0;
    for (buf[0..got]) |u| {
        if (value_pos >= at) break;
        if (u == 0x0D) {
            breaks += 1;
            continue;
        }
        value_pos += 1;
    }
    return breaks;
}

fn removed(ctx: *anyopaque, node: *Node) void {
    const s = surfaceOf(ctx);
    if (s.images.fetchRemove(node.id)) |kv| {
        var img = kv.value;
        img.deinit();
    }
    if (s.canvases.fetchRemove(node.id)) |kv| freeCanvas(kv.value);
    if (s.focused == node.id) s.focused = 0;
    if (s.focus_pending == node.id) s.focus_pending = 0;
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
        if (f.kind == .textarea or f.rich) setPlaceholder(s, f, n.props.ph orelse "");
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
            if (f.item_nat == 0) f.item_nat = @intCast(c.SendMessageW(f.hwnd, c.CB_GETITEMHEIGHT, std.math.maxInt(usize), 0));
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
                } else if (ch > box.h) {
                    // Its font's height and frame: centered on the box,
                    // over its edges (Chromium's is the CSS box exactly).
                    place.y = box.y - (ch - box.h) / 2;
                    limit = .{ .x = box.x, .y = place.y, .w = box.w, .h = ch };
                }
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
    // A focus() that came before its field's control did.
    if (s.focus_pending != 0) if (s.fields.get(s.focus_pending)) |f| {
        s.focus_pending = 0;
        _ = c.SetFocus(f.hwnd);
    };
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
    subclass(hwnd, &controlProc);
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
    // Text fields: RichEdit 5 when it loads (colour emoji, many undo
    // steps), else EDIT.
    const rich = rich_edit and (n.kind == .input or n.kind == .textarea) and loadRichEdit();
    const class = if (rich) std.unicode.utf8ToUtf16LeStringLiteral("RICHEDIT50W") else std.unicode.utf8ToUtf16LeStringLiteral("EDIT");
    const style: c.DWORD = switch (n.kind) {
        .input => @as(c.DWORD, c.WS_CHILD | c.WS_TABSTOP | c.ES_AUTOHSCROLL) | (if (n.props.pw) @as(c.DWORD, c.ES_PASSWORD) else @as(c.DWORD, 0)),
        .textarea => c.WS_CHILD | c.WS_TABSTOP | c.ES_MULTILINE | c.ES_AUTOVSCROLL | c.ES_WANTRETURN,
        .select => c.WS_CHILD | c.WS_TABSTOP | c.CBS_DROPDOWNLIST | c.WS_VSCROLL,
        else => unreachable,
    };
    const cls = if (n.kind == .select) std.unicode.utf8ToUtf16LeStringLiteral("COMBOBOX") else class;
    const clip = try makeClip(s);
    errdefer _ = c.DestroyWindow(clip);
    // A RichEdit drawn with Direct2D (Notepad's: colour emoji), else the
    // GDI one.
    const d2d_class = std.unicode.utf8ToUtf16LeStringLiteral("RichEditD2DPT");
    const hwnd = (if (rich) c.CreateWindowExW(0, d2d_class, null, style, 0, 0, 1, 1, clip, null, c.GetModuleHandleW(null), null) else null) orelse
        c.CreateWindowExW(0, cls, null, style, 0, 0, 1, 1, clip, null, c.GetModuleHandleW(null), null) orelse return error.CreateWindowFailed;
    _ = c.SetPropW(hwnd, prop_node, @ptrFromInt(@as(usize, @intCast(n.id))));
    switch (n.kind) {
        .input, .textarea => {
            if (rich) setupRichEdit(hwnd);
            // A RichEdit takes OLE drops itself: a file's path would go into
            // the field without the page seeing the drag. Without its
            // target, drags over it reach the canvas's (dropTarget), and a
            // text drop goes in through the page's drop (dnd.js insert).
            if (rich) _ = RevokeDragDrop(hwnd);
            if (rich and n.props.pw) _ = c.SendMessageW(hwnd, c.EM_SETPASSWORDCHAR, 0x2022, 0);
            if (!rich) if (n.props.ph) |ph| {
                const w = try std.unicode.utf8ToUtf16LeAllocZ(s.gpa, ph);
                defer s.gpa.free(w);
                _ = c.SendMessageW(hwnd, EM_SETCUEBANNER, c.TRUE, @bitCast(@intFromPtr(w.ptr)));
            };
            // Enter, Escape and Tab go to the page first (a form's submit).
            subclass(hwnd, &fieldProc);
        },
        .select => {
            subclass(hwnd, &controlProc);
            if (n.props.options) |opts| for (opts) |o| {
                const w = try std.unicode.utf8ToUtf16LeAllocZ(s.gpa, o[1]);
                defer s.gpa.free(w);
                _ = c.SendMessageW(hwnd, c.CB_ADDSTRING, 0, @bitCast(@intFromPtr(w.ptr)));
            };
        },
        else => {},
    }
    return .{ .hwnd = hwnd, .clip = clip, .kind = n.kind, .rich = rich };
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
            // A painted placeholder goes or comes back with the value (a
            // RichEdit sends no EN_CHANGE for it).
            if (f.ph != null) _ = c.InvalidateRect(f.hwnd, null, c.TRUE);
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
    const face = familyOf(n.props.ff, n.props.mono);
    const weight: c_int = @intFromFloat(@max(1, @min(1000, n.props.fwt orelse 400)));
    const font_changed = size != f.font_px or face.ptr != f.font_face or weight != f.font_weight;
    if (size != f.font_px or face.ptr != f.font_face or weight != f.font_weight) {
        const font = c.CreateFontW(-size, 0, 0, 0, weight, @intFromBool(n.props.it), 0, 0, c.DEFAULT_CHARSET, c.OUT_DEFAULT_PRECIS, c.CLIP_DEFAULT_PRECIS, c.CLEARTYPE_QUALITY, c.DEFAULT_PITCH, face);
        if (font != null) {
            _ = c.SendMessageW(f.hwnd, c.WM_SETFONT, @intFromPtr(font), c.TRUE);
            // A select's field height again, from the new font's.
            f.item_h = 0;
            f.item_nat = 0;
            if (f.font) |old| _ = c.DeleteObject(old);
            f.font = font;
            f.font_px = size;
            f.font_face = face.ptr;
            f.font_weight = weight;
        }
    }
    const fg = colorRef(n.props.col orelse .{ 0, 0, 0, 1 });
    const bg = backgroundUnder(s, n);
    const colors_changed = fg != f.fg or bg != f.bg or f.brush == null;
    if (fg != f.fg or bg != f.bg or f.brush == null) {
        f.fg = fg;
        f.bg = bg;
        if (f.brush) |b| _ = c.DeleteObject(b);
        f.brush = c.CreateSolidBrush(bg);
        _ = c.InvalidateRect(f.hwnd, null, c.TRUE);
    }
    // A RichEdit takes its colours by message (WM_SETFONT reset its text's).
    if (f.rich and (font_changed or colors_changed)) richColors(f);
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

/// The page hears which field has the keyboard ("focus" and "blur", so
/// :focus, :focus-visible and document.activeElement follow it), after a
/// field's or the canvas's focus changed. Focus that went to another
/// window (another app) changes nothing; the page itself having it means
/// no field. Checked once the change settled (a posted WM_FOCUS_CHECK): a
/// page's own el.focus() moves the keyboard while its script runs.
fn queueFocusCheck(s: *Surface) void {
    if (!s.focus_check_posted) s.focus_check_posted = c.PostMessageW(s.hwnd, WM_FOCUS_CHECK, 0, 0) != 0;
}

const WM_FOCUS_CHECK: c.UINT = c.WM_APP + 0x54;

fn focusCheck(s: *Surface) void {
    const f = c.GetFocus() orelse return;
    var nid: i64 = 0;
    if (f != s.hwnd) {
        if (fieldOf(s, f) orelse fieldOf(s, c.GetParent(f))) |fx| {
            nid = fx.node.id;
        } else if (c.IsChild(s.hwnd, f) == 0) return;
    }
    if (nid == s.focused) return;
    const old = s.focused;
    s.focused = nid;
    const hwnd = s.hwnd;
    if (old != 0) {
        _ = s.engine.event(old, "blur", "null");
        if (liveSurface(hwnd) == null) return; // the page closed its window
    }
    if (nid != 0) _ = s.engine.event(nid, "focus", "null");
}

fn onFieldCommand(s: *Surface, code: c.WORD, hwnd: c.HWND) void {
    if (s.updating) return;
    const fx = fieldOf(s, hwnd) orelse return;
    switch (fx.field.kind) {
        .input, .textarea => if (code == c.EN_CHANGE) {
            if (fx.field.ph != null) _ = c.InvalidateRect(hwnd, null, c.TRUE);
            const text = fieldText(s, hwnd) orelse return;
            defer s.gpa.free(text);
            // [value, inputType, data]: the edit its beforeinput announced
            // (a typed character, a deletion, a paste); else typing's.
            const value = std.json.Stringify.valueAlloc(s.gpa, text, .{}) catch return;
            defer s.gpa.free(value);
            const known = edit_hwnd == hwnd;
            const kind = if (known) edit_type else "insertText";
            const data = if (known and edit_text != null) std.json.Stringify.valueAlloc(s.gpa, edit_text.?, .{}) catch return else null;
            defer if (data) |d| s.gpa.free(d);
            edit_hwnd = null;
            const json = std.fmt.allocPrint(s.gpa, "[{s},\"{s}\",{s}]", .{ value, kind, data orelse "null" }) catch return;
            defer s.gpa.free(json);
            _ = s.engine.event(fx.node.id, "input", json);
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

/// A field's own window procedure in place of its class's (fieldProc,
/// controlProc), kept to call on.
fn subclass(hwnd: c.HWND, proc: c.WNDPROC) void {
    const old = c.SetWindowLongPtrW(hwnd, c.GWLP_WNDPROC, @bitCast(@intFromPtr(proc)));
    _ = c.SetPropW(hwnd, prop_old_proc, @ptrFromInt(@as(usize, @bitCast(old))));
}

/// A field's keys go to the page first, as a browser's do: keydown (a
/// named key or a Ctrl shortcut at WM_KEYDOWN, a typed character at its
/// WM_CHAR), then the control (unless the page prevented the keydown),
/// then keyup. The field whose key the page prevented (or Tab, which the
/// page always has: main.js moves the focus) gets none of its WM_CHARs.
var key_eaten: c.HWND = null;
/// The last WM_KEYDOWN was the IME's (VK_PROCESSKEY): its composition is
/// the control's; no keydown for its characters (Chromium sends one
/// "Process" keydown; Win32 sends none).
var key_ime = false;

/// True when the message is eaten (the control mustn't see it).
fn fieldKey(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) bool {
    switch (msg) {
        c.WM_KEYDOWN, c.WM_SYSKEYDOWN, c.WM_CHAR, c.WM_KEYUP, c.WM_SYSKEYUP => {},
        else => return false,
    }
    const p: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(c.GetWindowLongPtrW(c.GetParent(hwnd), c.GWLP_USERDATA))));
    const s = surfaceOf(p orelse return false);
    const fx = fieldOf(s, hwnd) orelse return false;
    // Copied before the page runs: its handler may remove this field (a
    // submitted form re-rendered), destroying this very window.
    const id = fx.node.id;
    const single_line = fx.field.kind == .input;
    const edit = fx.field.kind == .input or fx.field.kind == .textarea;
    const rich = fx.field.rich;
    s.in_control += 1;
    defer s.in_control -= 1;
    switch (msg) {
        c.WM_KEYDOWN, c.WM_SYSKEYDOWN => {
            key_eaten = null;
            edit_hwnd = null;
            key_ime = wparam == c.VK_PROCESSKEY;
            if (key_ime) return false;
            // The key a WM_CHAR from this one belongs to (its keyup's).
            s.char_vk = wparam;
            const ctrl = c.GetKeyState(c.VK_CONTROL) < 0;
            const alt = c.GetKeyState(c.VK_MENU) < 0;
            var ch: [1]u8 = undefined;
            const name: []const u8 = keyName(wparam) orelse if (ctrl and ((wparam >= 'A' and wparam <= 'Z') or (wparam >= '0' and wparam <= '9'))) blk: {
                // Ctrl+letter types no character: the shortcut as its key.
                ch[0] = std.ascii.toLower(@intCast(wparam));
                break :blk &ch;
            } else return false; // a character: at its WM_CHAR
            const prevented = sendKey(s, id, name, wparam, repeated(lparam));
            // Gone: nothing left to hand the key to.
            if (c.IsWindow(hwnd) == 0 or c.GetPropW(hwnd, prop_node) == null) return true;
            // Tab is the page's (no tab typed, no beep); so is a prevented
            // key; Enter in a one-line field (it would beep); Escape's
            // character (a multiline edit would close a dialog).
            const tab = wparam == c.VK_TAB and !ctrl and !alt;
            if (tab or prevented or (wparam == c.VK_RETURN and single_line) or wparam == c.VK_ESCAPE) key_eaten = hwnd;
            if (tab or prevented or (wparam == c.VK_RETURN and single_line)) return true;
            // The edit this key makes: beforeinput first; prevented, the
            // field doesn't make it (its WM_CHAR is eaten too).
            if (edit and !alt) if (keyEdit(hwnd, wparam, ctrl, single_line, rich)) |kind| {
                // A paste's data is the text it inserts.
                const pasted = if (std.mem.eql(u8, kind, "insertFromPaste")) pasteText(s, hwnd, single_line) else null;
                defer if (pasted) |t| s.gpa.free(t);
                if (beforeInput(s, id, hwnd, kind, pasted)) {
                    key_eaten = hwnd;
                    return true;
                }
                if (c.IsWindow(hwnd) == 0 or c.GetPropW(hwnd, prop_node) == null) return true;
            };
            return false;
        },
        c.WM_CHAR => {
            if (key_eaten == hwnd) return true;
            if (wparam < 0x20 or wparam == 0x7F) return false; // control characters: WM_KEYDOWN's
            if (key_ime or !edit) return false;
            if (c.GetKeyState(c.VK_CONTROL) < 0 and c.GetKeyState(c.VK_MENU) >= 0) return false;
            var units: [2]u16 = .{ @intCast(wparam & 0xFFFF), 0 };
            var buf: [8]u8 = undefined;
            const len = std.unicode.utf16LeToUtf8(&buf, units[0..1]) catch return false;
            const prevented = sendKey(s, id, buf[0..len], s.char_vk, repeated(lparam));
            if (prevented or c.IsWindow(hwnd) == 0 or c.GetPropW(hwnd, prop_node) == null) return true;
            // Then the edit: insertText, the character.
            return beforeInput(s, id, hwnd, "insertText", buf[0..len]) or c.IsWindow(hwnd) == 0 or c.GetPropW(hwnd, prop_node) == null;
        },
        else => {
            sendKeyUp(s, id, wparam);
            return c.IsWindow(hwnd) == 0 or c.GetPropW(hwnd, prop_node) == null;
        },
    }
}

/// The edit a key makes in an edit control, as Chromium names it
/// (InputEvent.inputType), or null (it moves the caret, or does nothing:
/// a backspace at the start).
fn keyEdit(hwnd: c.HWND, vk: c.WPARAM, ctrl: bool, single_line: bool, rich: bool) ?[]const u8 {
    var a: c.DWORD = 0;
    var b: c.DWORD = 0;
    _ = c.SendMessageW(hwnd, c.EM_GETSEL, @intFromPtr(&a), @bitCast(@intFromPtr(&b)));
    const len = editLength(hwnd, rich);
    const selected = a != b;
    return switch (vk) {
        c.VK_BACK => if (!selected and a == 0) null else if (ctrl) "deleteWordBackward" else "deleteContentBackward",
        c.VK_DELETE => if (!selected and a >= len) null else if (ctrl) "deleteWordForward" else "deleteContentForward",
        c.VK_RETURN => if (single_line) null else "insertLineBreak",
        'V' => if (ctrl) "insertFromPaste" else null,
        'X' => if (ctrl and selected) "deleteByCut" else null,
        'Z' => if (ctrl) "historyUndo" else null,
        else => null,
    };
}

/// The edit an edit control is about to make, for its input event
/// (EN_CHANGE): its inputType and text (owned), set by beforeInput.
var edit_hwnd: c.HWND = null;
var edit_type: []const u8 = "";
var edit_text: ?[]u8 = null;

/// beforeinput on field `id` for an edit (`data`: the text it inserts);
/// true when the page prevented it. Remembered for the input event.
fn beforeInput(s: *Surface, id: i64, hwnd: c.HWND, kind: []const u8, data: ?[]const u8) bool {
    edit_hwnd = hwnd;
    edit_type = kind;
    if (edit_text) |t| std.heap.page_allocator.free(t);
    edit_text = if (data) |d| std.heap.page_allocator.dupe(u8, d) catch null else null;
    const quoted = if (data) |d| std.json.Stringify.valueAlloc(s.gpa, d, .{}) catch return false else null;
    defer if (quoted) |q| s.gpa.free(q);
    const json = std.fmt.allocPrint(s.gpa, "[\"{s}\",{s}]", .{ kind, quoted orelse "null" }) catch return false;
    defer s.gpa.free(json);
    const prevented = s.engine.event(id, "beforeinput", json);
    if (prevented) edit_hwnd = null;
    return prevented;
}

/// The clipboard's text, as a paste puts it into a field: UTF-8 with LF
/// line ends, none in a one-line field (as Chromium strips them). Caller
/// frees.
fn pasteText(s: *Surface, hwnd: c.HWND, single_line: bool) ?[]u8 {
    if (c.OpenClipboard(hwnd) == 0) return null;
    defer _ = c.CloseClipboard();
    const h = c.GetClipboardData(c.CF_UNICODETEXT) orelse return null;
    const p: [*:0]const u16 = @ptrCast(@alignCast(c.GlobalLock(h) orelse return null));
    defer _ = c.GlobalUnlock(h);
    const utf8 = std.unicode.utf16LeToUtf8Alloc(s.gpa, std.mem.span(p)) catch return null;
    defer s.gpa.free(utf8);
    var out: std.ArrayList(u8) = .empty;
    for (utf8) |ch| {
        if (ch == '\r') continue;
        if (ch == '\n' and single_line) continue;
        out.append(s.gpa, ch) catch return null;
    }
    return out.toOwnedSlice(s.gpa) catch null;
}

/// A select's and a slider's window procedure: keys go to the page first.
fn controlProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const old: c.WNDPROC = @ptrCast(c.GetPropW(hwnd, prop_old_proc) orelse return c.DefWindowProcW(hwnd, msg, wparam, lparam));
    if (fieldKey(hwnd, msg, wparam, lparam)) return 0;
    if (msg == c.WM_NCDESTROY) {
        _ = c.SetWindowLongPtrW(hwnd, c.GWLP_WNDPROC, @bitCast(@intFromPtr(old)));
        _ = c.RemovePropW(hwnd, prop_old_proc);
    }
    return c.CallWindowProcW(old, hwnd, msg, wparam, lparam);
}

/// Edit controls' window procedure: keys go to the page first; a
/// textarea's placeholder.
fn fieldProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const old: c.WNDPROC = @ptrCast(c.GetPropW(hwnd, prop_old_proc) orelse return c.DefWindowProcW(hwnd, msg, wparam, lparam));
    if (fieldKey(hwnd, msg, wparam, lparam)) return 0;
    if (msg == c.WM_CONTEXTMENU and c.GetPropW(hwnd, prop_rich) != null) {
        richMenu(hwnd, lparam);
        return 0;
    }
    switch (msg) {
        c.WM_NCDESTROY => {
            _ = c.SetWindowLongPtrW(hwnd, c.GWLP_WNDPROC, @bitCast(@intFromPtr(old)));
            _ = c.RemovePropW(hwnd, prop_old_proc);
        },
        c.WM_PAINT => {
            const r = c.CallWindowProcW(old, hwnd, msg, wparam, lparam);
            const style: usize = @bitCast(c.GetWindowLongPtrW(hwnd, c.GWL_STYLE));
            if (style & c.ES_MULTILINE != 0 or c.GetPropW(hwnd, prop_rich) != null) paintPlaceholder(hwnd);
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
        // As browsers fire them: a modifier's own keydown and keyup.
        c.VK_SHIFT => "Shift",
        c.VK_CONTROL => "Control",
        c.VK_MENU => "Alt",
        c.VK_LWIN, c.VK_RWIN => "Meta",
        else => null,
    };
}

/// keydown for the page (on node `id`, a field's; 0: the focused element),
/// `repeat` on auto-repeat; remembered for virtual key `vk`'s keyup.
fn sendKey(s: *Surface, id: i64, name: []const u8, vk: c.WPARAM, repeat: bool) bool {
    if (vk < 256 and name.len <= 16) {
        @memcpy(s.key_names[vk][0..name.len], name);
        s.key_lens[vk] = @intCast(name.len);
    }
    const key = std.json.Stringify.valueAlloc(s.gpa, name, .{}) catch return false;
    defer s.gpa.free(key);
    var buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "[{s},{d},{}]", .{ key, modFlags(), repeat }) catch return false;
    return s.engine.event(id, "key", json);
}

/// keyup for the page: the key its keydown sent.
fn sendKeyUp(s: *Surface, id: i64, vk: c.WPARAM) void {
    if (vk >= 256 or s.key_lens[vk] == 0) return;
    const name = s.key_names[vk][0..s.key_lens[vk]];
    s.key_lens[vk] = 0;
    const key = std.json.Stringify.valueAlloc(s.gpa, name, .{}) catch return;
    defer s.gpa.free(key);
    var buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "[{s},{d}]", .{ key, modFlags() }) catch return;
    _ = s.engine.event(id, "keyup", json);
}

/// Auto-repeat: a WM_KEYDOWN or WM_CHAR whose key was already down
/// (lParam bit 30).
fn repeated(lparam: c.LPARAM) bool {
    return (@as(usize, @bitCast(lparam)) >> 30) & 1 != 0;
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

// ---------------------------------------------------------------------------
// Pointer events (docs/native-renderer.md, "Pointer and key events")

const PendingMove = struct { at: [2]f32, buttons: u32, kind: PointerKind, mods: u32 };
const PointerKind = enum { mouse, touch, pen };

/// A touch or pen contact: its pointer id, where it went down and was
/// last, whether the page took the drag (down's result) or it became a
/// scroll.
const Contact = struct { id: u32, kind: PointerKind, start: [2]f32, last: [2]f32, taken: bool, scrolling: bool = false };

/// The surface of the canvas `hwnd`, while it's alive: an event's handler
/// may close the page's window.
fn liveSurface(hwnd: c.HWND) ?*Surface {
    if (c.IsWindow(hwnd) == 0) return null;
    const p: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA))));
    return if (p) |sp| surfaceOf(sp) else null;
}

/// A pointer event for the page (main.js pointerEvent) at `p` (CSS px),
/// on the node there. True when the page took it.
fn sendPointer(s: *Surface, phase: []const u8, p: [2]f32, buttons: u32, kind: PointerKind, mods: u32) bool {
    if (!std.math.isFinite(p[0]) or !std.math.isFinite(p[1])) return false;
    const nid = targetAt(s, p);
    var buf: [112]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "[\"{s}\",{d:.2},{d:.2},{d},1,\"{s}\",{d}]", .{ phase, p[0], p[1], buttons, @tagName(kind), mods }) catch return false;
    return s.engine.event(nid, "pointer", json);
}

/// A move waits for the next display frame (the latest one wins), so a
/// 1000 Hz mouse doesn't flood the page.
fn queueMove(s: *Surface, p: [2]f32, buttons: u32, kind: PointerKind, mods: u32) void {
    s.move = .{ .at = p, .buttons = buttons, .kind = kind, .mods = mods };
    if (!s.ticking) {
        s.ticking = true;
        vsync.arm(s.hwnd);
    }
}

/// The move waiting, now (before a down or an up, at a display frame).
/// Null when the page closed the window meanwhile.
fn flushMove(s: *Surface) ?*Surface {
    const m = s.move orelse return s;
    s.move = null;
    const hwnd = s.hwnd;
    _ = sendPointer(s, "move", m.at, m.buttons, m.kind, m.mods);
    return liveSurface(hwnd);
}

/// The DOM's `buttons` bits of a mouse message's wParam (MK_*).
fn buttonsOf(wparam: c.WPARAM) u32 {
    var b: u32 = 0;
    if (wparam & c.MK_LBUTTON != 0) b |= 1;
    if (wparam & c.MK_RBUTTON != 0) b |= 2;
    if (wparam & c.MK_MBUTTON != 0) b |= 4;
    if (wparam & c.MK_XBUTTON1 != 0) b |= 8;
    if (wparam & c.MK_XBUTTON2 != 0) b |= 16;
    return b;
}

/// A mouse message Windows made from a touch or a pen (WM_POINTER*
/// handles those; this one would be the same contact twice).
fn fromTouch() bool {
    return (@as(usize, @bitCast(c.GetMessageExtraInfo())) & 0xFFFFFF00) == 0xFF515700;
}

/// A mouse button went down: the page's pointerdown, the window keeping
/// the mouse until every button is up.
fn onButtonDown(s: *Surface, lparam: c.LPARAM, bit: u32) void {
    const hwnd = s.hwnd;
    _ = c.SetCapture(hwnd);
    const pt = pointOf(s, lparam);
    const ls = flushMove(s) orelse return;
    ls.buttons |= bit;
    _ = sendPointer(ls, "down", pt, ls.buttons, .mouse, modFlags());
}

/// A mouse button went up: the page's pointerup (a move waiting first).
/// Null when the page closed the window.
fn onButtonUp(s: *Surface, lparam: c.LPARAM, bit: u32) ?*Surface {
    const hwnd = s.hwnd;
    const pt = pointOf(s, lparam);
    const ls = flushMove(s) orelse return null;
    ls.buttons &= ~bit;
    if (ls.buttons == 0) _ = c.ReleaseCapture();
    _ = sendPointer(ls, "up", pt, ls.buttons, .mouse, modFlags());
    return liveSurface(hwnd);
}

extern "user32" fn GetPointerType(id: u32, t: *u32) callconv(.winapi) c_int;
const WM_POINTERUPDATE = 0x0245;
const WM_POINTERDOWN = 0x0246;
const WM_POINTERUP = 0x0247;
const WM_POINTERCAPTURECHANGED = 0x024C;
const POINTER_FLAG_INCONTACT = 0x4;

/// WM_POINTER* for a touch or a pen (a mouse keeps its own messages):
/// false to leave it to DefWindowProc.
fn onPointer(s: *Surface, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) bool {
    const id: u32 = @truncate(wparam & 0xFFFF);
    var ptype: u32 = 0;
    if (GetPointerType(id, &ptype) == 0) return false;
    const kind: PointerKind = switch (ptype) {
        2 => .touch,
        3 => .pen,
        else => return false,
    };
    const flags: u32 = @truncate((wparam >> 16) & 0xFFFF);
    // Screen coordinates.
    var p: c.POINT = .{
        .x = @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)))))),
        .y = @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) >> 16)))),
    };
    _ = c.ScreenToClient(s.hwnd, &p);
    const pt: [2]f32 = .{ @as(f32, @floatFromInt(p.x)) / s.scale, @as(f32, @floatFromInt(p.y)) / s.scale };
    const hwnd = s.hwnd;
    switch (msg) {
        WM_POINTERDOWN => {
            if (s.contact != null) return true; // one contact at a time
            _ = c.SetFocus(hwnd);
            // :active while it's down.
            const pressed = targetAt(s, pt);
            if (pressed != 0) _ = s.engine.event(pressed, "press", "null");
            const ls = liveSurface(hwnd) orelse return true;
            const ls2 = flushMove(ls) orelse return true;
            const taken = sendPointer(ls2, "down", pt, 1, kind, modFlags());
            const ls3 = liveSurface(hwnd) orelse return true;
            ls3.contact = .{ .id = id, .kind = kind, .start = pt, .last = pt, .taken = taken };
        },
        WM_POINTERUPDATE => {
            const ct = if (s.contact) |*x| (if (x.id == id) x else null) else null;
            if (ct == null) {
                // A pen above the screen: a hover move.
                if (kind == .pen and flags & POINTER_FLAG_INCONTACT == 0) {
                    onMove(s, pt);
                    if (liveSurface(hwnd)) |ls| queueMove(ls, pt, 0, .pen, modFlags());
                }
                return true;
            }
            const k = ct.?;
            if (k.taken) {
                queueMove(s, pt, 1, kind, modFlags());
            } else {
                // Not the page's: past a few px it's a scroll, and the page
                // hears the pointer was cancelled.
                const dx = pt[0] - k.start[0];
                const dy = pt[1] - k.start[1];
                if (!k.scrolling and dx * dx + dy * dy > 8 * 8) {
                    k.scrolling = true;
                    s.move = null;
                    _ = sendPointer(s, "cancel", pt, 0, kind, modFlags());
                    const ls = liveSurface(hwnd) orelse return true;
                    _ = ls.engine.event(0, "release", "null");
                    const ls2 = liveSurface(hwnd) orelse return true;
                    if (ls2.contact) |*c2| scrollTouch(ls2, c2.start, c2.last, pt);
                    if (ls2.contact) |*c2| c2.last = pt;
                    return true;
                }
                if (k.scrolling) scrollTouch(s, k.start, k.last, pt);
            }
            if (liveSurface(hwnd)) |ls| {
                if (ls.contact) |*c2| c2.last = pt;
            }
        },
        WM_POINTERUP => {
            const k = s.contact orelse return true;
            if (k.id != id) return true;
            s.contact = null;
            if (k.scrolling) return true;
            const ls = flushMove(s) orelse return true;
            _ = sendPointer(ls, "up", pt, 0, kind, modFlags());
            const ls2 = liveSurface(hwnd) orelse return true;
            _ = ls2.engine.event(0, "release", "null");
            const ls3 = liveSurface(hwnd) orelse return true;
            // The click a tap makes, with the up's coordinates.
            var buf: [16]u8 = undefined;
            const fl = std.fmt.bufPrint(&buf, "{d}", .{modFlags()}) catch return true;
            const link = linkAt(ls3, pt);
            if (link != 0) {
                _ = ls3.engine.event(link, "click", fl);
                return true;
            }
            const n = ls3.engine.tree.hit(pt[0], pt[1]) orelse return true;
            if (disabledUp(n)) return true;
            _ = ls3.engine.event(n.id, "click", fl);
        },
        WM_POINTERCAPTURECHANGED => {
            const k = s.contact orelse return true;
            if (k.id != id) return true;
            s.contact = null;
            if (!k.scrolling) {
                s.move = null;
                _ = sendPointer(s, "cancel", k.last, 0, kind, modFlags());
                if (liveSurface(hwnd)) |ls| _ = ls.engine.event(0, "release", "null");
            }
        },
        else => return false,
    }
    return true;
}

/// A touch that became a scroll: the scroll containers under where it
/// went down follow it from `from` to `to`.
fn scrollTouch(s: *Surface, start: [2]f32, from: [2]f32, to: [2]f32) void {
    const hit = s.engine.tree.hit(start[0], start[1]);
    const dy = from[1] - to[1];
    const dx = from[0] - to[0];
    if (dx != 0) {
        var tx = s.engine.tree.scrollerX(hit);
        while (tx) |t| {
            if (s.engine.scrollByX(t, dx)) break;
            tx = s.engine.tree.scrollerX(t.parent);
        }
    }
    if (dy != 0) {
        var target = s.engine.tree.scroller(hit);
        while (target) |t| {
            if (s.engine.scrollBy(t, dy)) break;
            target = s.engine.tree.scroller(t.parent);
        }
    }
}

fn onMove(s: *Surface, pt: [2]f32) void {
    s.pointer = pt;
    if (!s.tracking) {
        var tme: c.TRACKMOUSEEVENT = .{ .cbSize = @sizeOf(c.TRACKMOUSEEVENT), .dwFlags = c.TME_LEAVE, .hwndTrack = s.hwnd, .dwHoverTime = 0 };
        s.tracking = c.TrackMouseEvent(&tme) != 0;
    }
    const n = s.engine.tree.hit(pt[0], pt[1]);
    const link = linkAt(s, pt);
    s.hand = link != 0 or (n != null and clickableUp(n.?));
    // :hover: the page hears when the node under the pointer changes (a
    // link amid the text: its element).
    const id: i64 = if (link != 0) link else if (n) |node| node.id else 0;
    if (id != s.hovered) {
        s.hovered = id;
        _ = s.engine.event(id, "hover", "null");
    }
}

/// The clickable element of the text run under `pt` (a link amid the text
/// has no node of its own: its runs carry its id, Run.k), else 0.
fn linkAt(s: *Surface, pt: [2]f32) i64 {
    const n = s.engine.tree.hit(pt[0], pt[1]) orelse return 0;
    if (n.kind != .text) return 0;
    const runs = n.props.runs orelse return 0;
    for (runs) |r| {
        if (r.k != null) break;
    } else return 0;
    const ct = n.content();
    const layout = textLayout(s, n, paintWidth(ct.w), null) orelse return 0;
    defer releaseCom(@as(?*c.IDWriteTextLayout, layout));
    // Lines of their own heights (a font on some only) are drawn moved
    // (paintText's lineShift): the point back in the layout's spacing.
    var y = pt[1] - ct.y;
    var ext_buf: [64]Extent = undefined;
    if (lineExtents(&n.props, layout, &ext_buf, null)) |xs| if (textExtent(&n.props)) |all| {
        var top: f32 = 0;
        for (xs, 0..) |e, k| {
            const h = e.top + e.bottom;
            if (y < top + h or k + 1 == xs.len) {
                y -= lineShift(xs, all, k);
                break;
            }
            top += h;
        }
    };
    var trailing: c.BOOL = 0;
    var inside: c.BOOL = 0;
    var m: c.DWRITE_HIT_TEST_METRICS = undefined;
    if (layout.lpVtbl.*.HitTestPoint.?(layout, pt[0] - ct.x, y, &trailing, &inside, &m) < 0 or inside == 0) return 0;
    // The run holding that UTF-16 position.
    var pos: u32 = 0;
    for (runs) |r| {
        pos += @intCast(std.unicode.calcUtf16LeLen(r.t) catch r.t.len);
        if (m.textPosition < pos) return if (r.k) |k| k else 0;
    }
    return 0;
}

/// The node a pointer at `pt` is on: a link run's element, else the node
/// there (0: none).
fn targetAt(s: *Surface, pt: [2]f32) i64 {
    const link = linkAt(s, pt);
    if (link != 0) return link;
    return if (s.engine.tree.hit(pt[0], pt[1])) |n| n.id else 0;
}

/// The wheel (WM_MOUSEWHEEL) or the tilt wheel / a touchpad's sideways
/// swipe (WM_MOUSEHWHEEL, `sideways`); Shift with the wheel scrolls
/// sideways too, as in a browser.
// ---------------------------------------------------------------------------
// Scrollbars: WebView2's on Windows, in the room a scroller keeps for one
// (Tree.scrollbar, Node.gutter): a 15px bar (10px thin), arrow buttons at
// its ends, a pill thumb; light, or dark with a dark color-scheme, or
// scrollbar-color's. Arrows scroll 40px, the track 87.5% of the view, both
// repeating while held; the thumb drags.

const SbPart = enum { none, up, down, page_up, page_down, thumb };

/// The SetTimer id of a held arrow's or track's repeat.
const sb_timer: usize = @as(usize, std.math.maxInt(u32)) + 5;

const Scrollbar = struct {
    bar: Rect,
    up: Rect,
    down: Rect,
    /// Zero-sized when the scroller can't scroll (overflow-y: scroll on
    /// short content: arrows only).
    thumb: Rect,
    /// Where the thumb's top can go: from `start`, `travel` px.
    start: f32,
    travel: f32,
    /// How far the scroller scrolls.
    range: f32,
};

fn scrollbarOf(n: *const Node) ?Scrollbar {
    const g = n.gutter;
    if (!(g > 0)) return null;
    const bw = n.props.bw orelse [4]f32{ 0, 0, 0, 0 };
    const bar: Rect = .{ .x = n.frame.x + n.frame.w - bw[1] - g, .y = n.frame.y + bw[0], .w = g, .h = n.frame.h - bw[0] - bw[2] };
    if (bar.h <= 0) return null;
    const btn = @min(g, bar.h / 2);
    const start = bar.y + btn;
    const len = bar.h - 2 * btn;
    const range = @max(0, n.content_h - n.frame.h);
    var sb: Scrollbar = .{
        .bar = bar,
        .up = .{ .x = bar.x, .y = bar.y, .w = g, .h = btn },
        .down = .{ .x = bar.x, .y = bar.y + bar.h - btn, .w = g, .h = btn },
        .thumb = .{ .x = bar.x, .y = start, .w = 0, .h = 0 },
        .start = start,
        .travel = 0,
        .range = range,
    };
    if (range > 0.5 and len > 0 and n.content_h > 0) {
        const thumb_len = @min(len, @max(g + 2, len * n.frame.h / n.content_h));
        sb.travel = len - thumb_len;
        sb.thumb = .{ .x = bar.x, .y = start + sb.travel * std.math.clamp(n.scroll_y / range, 0, 1), .w = g, .h = thumb_len };
    }
    return sb;
}

fn paintScrollbar(p: *Painter, n: *Node) void {
    const sb = scrollbarOf(n) orelse return;
    const dark = n.props.dk;
    const track: tree_mod.Color = if (n.props.sbc) |cc| cc[1] else if (dark) .{ 44, 44, 44, 1 } else .{ 252, 252, 252, 1 };
    const ink: tree_mod.Color = if (n.props.sbc) |cc| cc[0] else if (dark) .{ 159, 159, 159, 1 } else .{ 139, 139, 139, 1 };
    const vt = p.vt();
    const bar = rectF(sb.bar);
    vt.FillRectangle.?(p.rt, &bar, p.solid(track));
    // The thumb: a pill 60% of the bar's width, 2px in from its ends.
    const tw = @round(sb.bar.w * 0.6);
    if (sb.thumb.h > 4) {
        const rr: c.D2D1_ROUNDED_RECT = .{
            .rect = .{ .left = sb.thumb.x + (sb.bar.w - tw) / 2, .top = sb.thumb.y + 2, .right = sb.thumb.x + (sb.bar.w + tw) / 2, .bottom = sb.thumb.y + sb.thumb.h - 2 },
            .radiusX = tw / 2,
            .radiusY = tw / 2,
        };
        vt.FillRoundedRectangle.?(p.rt, &rr, p.solid(ink));
    }
    // The arrows: triangles as wide as the thumb, a little above and
    // below their button's middle.
    const cx = sb.bar.x + sb.bar.w / 2;
    for ([2]Rect{ sb.up, sb.down }, 0..) |b, i| {
        if (b.h < 4) continue;
        const cy = b.y + b.h / 2;
        const dir: f32 = if (i == 0) 1 else -1;
        const tip: c.D2D1_POINT_2F = .{ .x = cx, .y = cy - dir * tw * 0.3 };
        const base_y = cy + dir * tw * 0.45;
        const tri = triangleGeometry(tip, .{ .x = cx + tw / 2, .y = base_y }, .{ .x = cx - tw / 2, .y = base_y }) orelse continue;
        defer releaseCom(@as(?*c.ID2D1PathGeometry, tri));
        vt.FillGeometry.?(p.rt, @ptrCast(tri), p.solid(ink), null);
    }
}

/// The scroller whose scrollbar is at `pt`, and its bar.
fn scrollbarAt(s: *Surface, pt: [2]f32) ?struct { node: *Node, sb: Scrollbar } {
    var n = s.engine.tree.hit(pt[0], pt[1]);
    while (n) |x| : (n = x.parent) {
        const sb = scrollbarOf(x) orelse continue;
        if (pt[0] >= sb.bar.x and pt[0] < sb.bar.x + sb.bar.w and pt[1] >= sb.bar.y and pt[1] < sb.bar.y + sb.bar.h) return .{ .node = x, .sb = sb };
    }
    return null;
}

/// A press on a scrollbar: true when it was one (the page doesn't get it).
fn onScrollbarDown(s: *Surface, pt: [2]f32) bool {
    const at = scrollbarAt(s, pt) orelse return false;
    const n = at.node;
    const sb = at.sb;
    s.sb_node = n.id;
    s.sb_part = if (pt[1] < sb.up.y + sb.up.h)
        .up
    else if (pt[1] >= sb.down.y)
        .down
    else if (sb.thumb.h > 0 and pt[1] >= sb.thumb.y and pt[1] < sb.thumb.y + sb.thumb.h)
        .thumb
    else if (sb.thumb.h > 0 and pt[1] < sb.thumb.y)
        .page_up
    else
        .page_down;
    s.sb_grab = pt[1] - sb.thumb.y;
    _ = c.SetCapture(s.hwnd);
    if (s.sb_part != .thumb) {
        scrollbarStep(s, pt);
        // Held: again after a pause, then quickly (as Windows' own).
        _ = c.SetTimer(s.hwnd, sb_timer, 400, null);
    }
    return true;
}

/// One step of the held arrow or track: 40px, or 87.5% of the view; the
/// track stops once the thumb reaches the mouse.
fn scrollbarStep(s: *Surface, pt: [2]f32) void {
    const n = s.engine.tree.get(s.sb_node) orelse return;
    const sb = scrollbarOf(n) orelse return;
    const page = @round(sb.bar.h * 0.875);
    const dy: f32 = switch (s.sb_part) {
        .up => -40,
        .down => 40,
        .page_up => if (pt[1] < sb.thumb.y) -page else return,
        .page_down => if (pt[1] >= sb.thumb.y + sb.thumb.h) page else return,
        else => return,
    };
    _ = s.engine.scrollBy(n, dy);
}

fn onScrollbarTimer(s: *Surface) void {
    if (s.sb_part == .none or s.sb_part == .thumb) return;
    var cp: c.POINT = undefined;
    _ = c.GetCursorPos(&cp);
    _ = c.ScreenToClient(s.hwnd, &cp);
    scrollbarStep(s, .{ @as(f32, @floatFromInt(cp.x)) / s.scale, @as(f32, @floatFromInt(cp.y)) / s.scale });
    if (liveSurface(s.hwnd)) |ls| if (ls.sb_part != .none) {
        _ = c.SetTimer(ls.hwnd, sb_timer, 50, null);
    };
}

/// The thumb dragged to `pt`: true while a scrollbar has the mouse.
fn onScrollbarMove(s: *Surface, pt: [2]f32) bool {
    if (s.sb_part == .none) return false;
    if (s.sb_part != .thumb) return true;
    const n = s.engine.tree.get(s.sb_node) orelse return true;
    const sb = scrollbarOf(n) orelse return true;
    if (!(sb.travel > 0)) return true;
    const frac = std.math.clamp((pt[1] - s.sb_grab - sb.start) / sb.travel, 0, 1);
    _ = s.engine.scrollBy(n, frac * sb.range - n.scroll_y);
    return true;
}

/// The mouse let go of a scrollbar: true when one had it.
fn onScrollbarUp(s: *Surface) bool {
    if (s.sb_part == .none) return false;
    s.sb_part = .none;
    s.sb_node = 0;
    _ = c.KillTimer(s.hwnd, sb_timer);
    if (c.GetCapture() == s.hwnd) _ = c.ReleaseCapture();
    return true;
}

/// SPI_GETWHEELSCROLLLINES (3 by default; a page at a time counts as 3).
fn wheelLines() f32 {
    var lines: c.UINT = 3;
    if (c.SystemParametersInfoW(c.SPI_GETWHEELSCROLLLINES, 0, @ptrCast(&lines), 0) == 0) return 3;
    if (lines == 0 or lines > 100) return 3;
    return @floatFromInt(lines);
}

fn onWheel(s: *Surface, wparam: c.WPARAM, lparam: c.LPARAM, sideways: bool) void {
    // Wheel positions are in screen coordinates.
    var p: c.POINT = .{
        .x = @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)))))),
        .y = @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) >> 16)))),
    };
    _ = c.ScreenToClient(s.hwnd, &p);
    const pt: [2]f32 = .{ @as(f32, @floatFromInt(p.x)) / s.scale, @as(f32, @floatFromInt(p.y)) / s.scale };
    const delta: i16 = @bitCast(@as(u16, @truncate(wparam >> 16)));
    // 120 per notch, down positive; as Chromium on Windows: the system's
    // lines per notch at 100/3 px a line (3 lines: 100 px).
    const dy = -@as(f32, @floatFromInt(delta)) / 120.0 * wheelLines() * (100.0 / 3.0);
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
        // The page itself has the keyboard: a field that had it lost it.
        c.WM_SETFOCUS => {
            queueFocusCheck(s);
            return 0;
        },
        WM_FOCUS_CHECK => {
            s.focus_check_posted = false;
            focusCheck(s);
            return 0;
        },
        WM_DISPLAY_FRAME => {
            onDisplayFrame(s, hwnd);
            return 0;
        },
        c.WM_TIMER => {
            _ = c.KillTimer(hwnd, wparam);
            if (wparam == sb_timer) {
                onScrollbarTimer(s);
                return 0;
            }
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
            if (fromTouch()) return 0;
            // A scrollbar's: not the page's.
            if (onScrollbarDown(s, pointOf(s, lparam))) return 0;
            _ = c.SetFocus(hwnd);
            const pt = pointOf(s, lparam);
            // :active while the button is down.
            const pressed = targetAt(s, pt);
            if (pressed != 0) _ = s.engine.event(pressed, "press", "null");
            if (liveSurface(hwnd)) |ls| onButtonDown(ls, lparam, 1);
            return 0;
        },
        c.WM_RBUTTONDOWN, c.WM_RBUTTONDBLCLK, c.WM_MBUTTONDOWN, c.WM_MBUTTONDBLCLK => {
            if (fromTouch()) return 0;
            const right = msg == c.WM_RBUTTONDOWN or msg == c.WM_RBUTTONDBLCLK;
            onButtonDown(s, lparam, if (right) 2 else 4);
            return 0;
        },
        c.WM_LBUTTONUP => {
            if (fromTouch()) return 0;
            if (onScrollbarUp(s)) return 0;
            const ls = onButtonUp(s, lparam, 1) orelse return 0;
            _ = ls.engine.event(0, "release", "null");
            const ls2 = liveSurface(hwnd) orelse return 0;
            // The click, with the up's coordinates.
            const pt = pointOf(ls2, lparam);
            var buf: [16]u8 = undefined;
            const flags = std.fmt.bufPrint(&buf, "{d}", .{modFlags()}) catch return 0;
            // A link amid the text: its element's click.
            const link = linkAt(ls2, pt);
            if (link != 0) {
                _ = ls2.engine.event(link, "click", flags);
                return 0;
            }
            const n = ls2.engine.tree.hit(pt[0], pt[1]) orelse return 0;
            if (disabledUp(n)) return 0;
            _ = ls2.engine.event(n.id, "click", flags);
            return 0;
        },
        c.WM_RBUTTONUP => {
            if (fromTouch()) return 0;
            const ls = onButtonUp(s, lparam, 2) orelse return 0;
            const pt = pointOf(ls, lparam);
            const target = targetAt(ls, pt);
            if (target == 0) return 0;
            // As Chromium on Windows: on the release, after auxclick, the
            // secondary button's with the buttons still held (measured).
            var buf: [64]u8 = undefined;
            const json = std.fmt.bufPrint(&buf, "[{d:.0},{d:.0},2,{d},{d}]", .{ pt[0], pt[1], ls.buttons, modFlags() }) catch return 0;
            _ = ls.engine.event(target, "contextmenu", json);
            return 0;
        },
        c.WM_MBUTTONUP => {
            if (fromTouch()) return 0;
            _ = onButtonUp(s, lparam, 4);
            return 0;
        },
        // Back and forward (buttons 3 and 4, bits 8 and 16): the page's
        // downs, ups and auxclicks, as Chromium's. TRUE, as the docs ask.
        c.WM_XBUTTONDOWN, c.WM_XBUTTONDBLCLK, c.WM_XBUTTONUP => {
            if (fromTouch()) return c.TRUE;
            const bit: u32 = if ((wparam >> 16) & 0xFFFF == c.XBUTTON2) 16 else 8;
            if (msg == c.WM_XBUTTONUP) _ = onButtonUp(s, lparam, bit) else onButtonDown(s, lparam, bit);
            return c.TRUE;
        },
        c.WM_MOUSEMOVE => {
            if (fromTouch()) return 0;
            const pt = pointOf(s, lparam);
            if (onScrollbarMove(s, pt)) return 0;
            onMove(s, pt);
            if (liveSurface(hwnd)) |ls| queueMove(ls, pt, buttonsOf(wparam), .mouse, modFlags());
            return 0;
        },
        // The mouse taken away while a button was down (another window, a
        // menu): the buttons are up as far as the page goes.
        c.WM_CAPTURECHANGED => {
            if (s.sb_part != .none and toHandle(c.HWND, @bitCast(lparam)) != hwnd) _ = onScrollbarUp(s);
            if (s.buttons != 0 and toHandle(c.HWND, @bitCast(lparam)) != hwnd) {
                s.buttons = 0;
                s.move = null;
                _ = sendPointer(s, "cancel", s.pointer, 0, .mouse, modFlags());
            }
            return 0;
        },
        WM_POINTERDOWN, WM_POINTERUPDATE, WM_POINTERUP, WM_POINTERCAPTURECHANGED => {
            if (onPointer(s, msg, wparam, lparam)) return 0;
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
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
            // The key a WM_CHAR from this one belongs to (its keyup's).
            s.char_vk = wparam;
            if (keyName(wparam)) |name| {
                if (sendKey(s, 0, name, wparam, repeated(lparam))) return 0;
            } else if (c.GetKeyState(c.VK_CONTROL) < 0 and ((wparam >= 'A' and wparam <= 'Z') or (wparam >= '0' and wparam <= '9'))) {
                // Ctrl+letter types no character: the shortcut as its key.
                const ch: u8 = std.ascii.toLower(@intCast(wparam));
                if (sendKey(s, 0, &.{ch}, wparam, repeated(lparam))) return 0;
            }
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        c.WM_KEYUP, c.WM_SYSKEYUP => {
            sendKeyUp(s, 0, wparam);
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        c.WM_CHAR => {
            if (wparam < 0x20 or wparam == 0x7F) return 0; // control characters: WM_KEYDOWN's
            if (c.GetKeyState(c.VK_CONTROL) < 0 and c.GetKeyState(c.VK_MENU) >= 0) return 0;
            var units: [2]u16 = .{ @intCast(wparam & 0xFFFF), 0 };
            var buf: [8]u8 = undefined;
            const len = std.unicode.utf16LeToUtf8(&buf, units[0..1]) catch return 0;
            _ = sendKey(s, 0, buf[0..len], s.char_vk, repeated(lparam));
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
            const code: c.WORD = @truncate(wparam >> 16);
            // A field took or lost the keyboard.
            if (code == c.EN_SETFOCUS or code == c.EN_KILLFOCUS or code == c.CBN_SETFOCUS or code == c.CBN_KILLFOCUS) {
                queueFocusCheck(s);
                return 0;
            }
            if (lparam != 0) onFieldCommand(s, code, toHandle(c.HWND, @bitCast(lparam)));
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
            // NM_SETFOCUS / NM_KILLFOCUS (NM_FIRST - 7, - 8): a trackbar's focus.
            if (hdr.code == @as(c.UINT, @bitCast(@as(i32, -7))) or hdr.code == @as(c.UINT, @bitCast(@as(i32, -8)))) {
                queueFocusCheck(s);
                return 0;
            }
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
/// The width a laid-out text is drawn (and hit-tested) at: its box's, as
/// it was measured, so its lines break where measure broke them (a line
/// 0.6px over the box wraps, as in Chromium); a LayoutUnit (1/64 px) more
/// absorbs float error.
fn paintWidth(box_w: f32) f32 {
    return box_w + 1.0 / 64.0;
}

fn textLayout(s: *Surface, n: *Node, width: f32, brushes: ?*std.ArrayList(*c.ID2D1SolidColorBrush)) ?*c.IDWriteTextLayout {
    return textLayoutOf(s, &n.props, width, brushes);
}

// ---------------------------------------------------------------------------
// Fonts and line boxes (docs/native-renderer.md, "Text metrics"), as
// WebView2 (Chromium) makes them on Windows.

/// A CSS font-family list (`ff`; null: Oriel's default sans, or the
/// monospace one) as the DirectWrite family Chromium would use: the
/// first installed name, or generic family (system-ui: Segoe UI,
/// sans-serif: Arial, serif: Times New Roman, monospace: Consolas;
/// "default", no font-family set: Times New Roman, as WebView2).
/// Null-terminated UTF-16, cached by list (owned for the process).
var families: std.StringHashMapUnmanaged([:0]const u16) = .empty;

fn familyOf(list: ?[]const u8, mono: bool) [:0]const u16 {
    const l = list orelse return if (mono) mono_face else sans_face;
    if (families.get(l)) |f| return f;
    const f = resolveFamily(l) orelse (if (mono) mono_face else sans_face);
    const key = std.heap.page_allocator.dupe(u8, l) catch return f;
    families.put(std.heap.page_allocator, key, f) catch {};
    return f;
}

fn resolveFamily(list: []const u8) ?[:0]const u16 {
    const generics = .{
        .{ "system-ui", "Segoe UI" },     .{ "-apple-system", "Segoe UI" },     .{ "blinkmacsystemfont", "Segoe UI" },
        .{ "ui-sans-serif", "Segoe UI" }, .{ "sans-serif", "Arial" },           .{ "serif", "Times New Roman" },
        .{ "ui-serif", "Times New Roman" }, .{ "monospace", "Consolas" },     .{ "ui-monospace", "Consolas" },
        .{ "cursive", "Comic Sans MS" },  .{ "fantasy", "Impact" },             .{ "math", "Cambria Math" },
        .{ "emoji", "Segoe UI Emoji" },   .{ "ui-rounded", "Segoe UI" },
        // Chromium's control font (render.js's UA sheet for fields).
        .{ "-webkit-small-control", "Arial" },
        // The page set no font-family: WebView2's default face.
        .{ "default", "Times New Roman" },
    };
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t\"'");
        if (name.len == 0 or name.len > 120) continue;
        var lower_buf: [120]u8 = undefined;
        const lower = std.ascii.lowerString(&lower_buf, name);
        inline for (generics) |g| if (std.mem.eql(u8, lower, g[0])) return std.unicode.utf8ToUtf16LeStringLiteral(g[1]);
        // A named family, when it's installed.
        const w = std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, name) catch continue;
        if (installed(w)) return w;
        std.heap.page_allocator.free(w);
    }
    return null;
}

fn installed(family: [:0]const u16) bool {
    const dw = dwrite orelse return false;
    var coll: ?*c.IDWriteFontCollection = null;
    if (dw.lpVtbl.*.GetSystemFontCollection.?(dw, &coll, c.FALSE) < 0 or coll == null) return false;
    defer releaseCom(coll);
    var index: c.UINT32 = 0;
    var exists: c.BOOL = c.FALSE;
    return coll.?.lpVtbl.*.FindFamilyName.?(coll, family.ptr, &index, &exists) >= 0 and exists != 0;
}

/// A face's ascent, descent and line gap per em, unhinted (its font
/// tables, as DirectWrite's DWRITE_FONT_METRICS has them), cached by
/// family, weight and italic; null when DirectWrite can't say (remembered
/// too: a missing face isn't asked for again on every layout).
var font_ratios: std.AutoHashMapUnmanaged(u64, ?[3]f32) = .empty;

fn fontRatios(family: [:0]const u16, weight: f32, italic: bool) ?[3]f32 {
    const w: u32 = @intFromFloat(@max(1, @min(999, weight)));
    const key: u64 = std.hash.Wyhash.hash(w | (@as(u64, @intFromBool(italic)) << 10), std.mem.sliceAsBytes(family));
    if (font_ratios.get(key)) |v| return v;
    const v = queryRatios(family, w, italic);
    font_ratios.put(std.heap.page_allocator, key, v) catch {};
    return v;
}

fn queryRatios(name: [:0]const u16, w: u32, italic: bool) ?[3]f32 {
    const dw = dwrite orelse return null;
    var coll: ?*c.IDWriteFontCollection = null;
    if (dw.lpVtbl.*.GetSystemFontCollection.?(dw, &coll, c.FALSE) < 0 or coll == null) return null;
    defer releaseCom(coll);
    var index: c.UINT32 = 0;
    var exists: c.BOOL = c.FALSE;
    if (coll.?.lpVtbl.*.FindFamilyName.?(coll, name.ptr, &index, &exists) < 0 or exists == 0) return null;
    var family: ?*c.IDWriteFontFamily = null;
    if (coll.?.lpVtbl.*.GetFontFamily.?(coll, index, &family) < 0 or family == null) return null;
    defer releaseCom(family);
    var font: ?*c.IDWriteFont = null;
    if (family.?.lpVtbl.*.GetFirstMatchingFont.?(family, @intCast(w), c.DWRITE_FONT_STRETCH_NORMAL, if (italic) c.DWRITE_FONT_STYLE_ITALIC else c.DWRITE_FONT_STYLE_NORMAL, &font) < 0 or font == null) return null;
    defer releaseCom(font);
    var fm: c.DWRITE_FONT_METRICS = undefined;
    font.?.lpVtbl.*.GetMetrics.?(font, &fm);
    if (fm.designUnitsPerEm == 0) return null;
    const em: f32 = @floatFromInt(fm.designUnitsPerEm);
    return .{ @as(f32, @floatFromInt(fm.ascent)) / em, @as(f32, @floatFromInt(fm.descent)) / em, @as(f32, @floatFromInt(fm.lineGap)) / em };
}

/// A face's widths per em, as Chromium sizes a text field by them: its
/// glyph box's (head's xMax - xMin: its widest character) and its "x"'s
/// advance (its average character); cached by family, null remembered.
var char_widths: std.AutoHashMapUnmanaged(u64, ?[2]f32) = .empty;

fn charWidths(family: [:0]const u16) ?[2]f32 {
    const key = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(family));
    if (char_widths.get(key)) |v| return v;
    const v = queryCharWidths(family);
    char_widths.put(std.heap.page_allocator, key, v) catch {};
    return v;
}

fn queryCharWidths(name: [:0]const u16) ?[2]f32 {
    const dw = dwrite orelse return null;
    var coll: ?*c.IDWriteFontCollection = null;
    if (dw.lpVtbl.*.GetSystemFontCollection.?(dw, &coll, c.FALSE) < 0 or coll == null) return null;
    defer releaseCom(coll);
    var index: c.UINT32 = 0;
    var exists: c.BOOL = c.FALSE;
    if (coll.?.lpVtbl.*.FindFamilyName.?(coll, name.ptr, &index, &exists) < 0 or exists == 0) return null;
    var family: ?*c.IDWriteFontFamily = null;
    if (coll.?.lpVtbl.*.GetFontFamily.?(coll, index, &family) < 0 or family == null) return null;
    defer releaseCom(family);
    var font: ?*c.IDWriteFont = null;
    if (family.?.lpVtbl.*.GetFirstMatchingFont.?(family, 400, c.DWRITE_FONT_STRETCH_NORMAL, c.DWRITE_FONT_STYLE_NORMAL, &font) < 0 or font == null) return null;
    defer releaseCom(font);
    var face: ?*c.IDWriteFontFace = null;
    if (font.?.lpVtbl.*.CreateFontFace.?(font, &face) < 0 or face == null) return null;
    defer releaseCom(face);
    const fc = face.?;
    var f1: ?*c.IDWriteFontFace1 = null;
    if (fc.lpVtbl.*.QueryInterface.?(fc, &iid_font_face1, @ptrCast(&f1)) < 0 or f1 == null) return null;
    defer releaseCom(f1);
    var m1: c.DWRITE_FONT_METRICS1 = undefined;
    f1.?.lpVtbl.*.IDWriteFontFace1_GetMetrics.?(f1, &m1);
    if (m1.designUnitsPerEm == 0) return null;
    const em: f32 = @floatFromInt(m1.designUnitsPerEm);
    const cp = [1]u32{'x'};
    var glyph: [1]u16 = undefined;
    var gm: [1]c.DWRITE_GLYPH_METRICS = undefined;
    if (fc.lpVtbl.*.GetGlyphIndicesW.?(fc, &cp, 1, &glyph) < 0 or fc.lpVtbl.*.GetDesignGlyphMetrics.?(fc, &glyph, 1, &gm, c.FALSE) < 0) return null;
    return .{ @as(f32, @floatFromInt(@as(i32, m1.glyphBoxRight) - m1.glyphBoxLeft)) / em, @as(f32, @floatFromInt(gm[0].advanceWidth)) / em };
}

/// A text field's content width as Chromium makes it for `size`
/// characters: that many average characters (each rounded to a pixel),
/// plus a widest character less an average one. Arial 13.33px, size 20:
/// 20 * 7 + 36 - 7 = 169.
fn inputWidth(n: *const Node, size: f32) f32 {
    const fz = n.props.fz orelse 16;
    const w = charWidths(familyOf(n.props.ff, n.props.mono)) orelse return @round(size * fz * 0.5 + fz);
    const avg = @round(w[1] * fz);
    return @ceil(avg * size) + @round(w[0] * fz) - avg;
}

/// A textarea's: `cols` average characters (unrounded here) and a
/// scrollbar (Consolas 13.33px, 20 cols: 147 + 15 = 162).
fn textareaWidth(n: *const Node, cols: f32) f32 {
    const fz = n.props.fz orelse 16;
    const w = charWidths(familyOf(n.props.ff, n.props.mono)) orelse return cols * fz * 0.6 + 8;
    return @ceil(w[1] * fz * cols) + 15;
}

/// The width of one line of `text` in the field's font (DirectWrite's).
fn plainWidth(n: *const Node, text: []const u8) f32 {
    const dw = dwrite orelse return 0;
    var buf: [256]u16 = undefined;
    const len = std.unicode.utf8ToUtf16Le(&buf, text[0..@min(text.len, 200)]) catch return 0;
    const weight: c.DWRITE_FONT_WEIGHT = @intFromFloat(@max(1, @min(999, n.props.fwt orelse 400)));
    const style: c.DWRITE_FONT_STYLE = if (n.props.it) c.DWRITE_FONT_STYLE_ITALIC else c.DWRITE_FONT_STYLE_NORMAL;
    var format: ?*c.IDWriteTextFormat = null;
    if (dw.lpVtbl.*.CreateTextFormat.?(dw, familyOf(n.props.ff, n.props.mono), null, weight, style, c.DWRITE_FONT_STRETCH_NORMAL, n.props.fz orelse 16, std.unicode.utf8ToUtf16LeStringLiteral(""), &format) < 0 or format == null) return 0;
    defer releaseCom(format);
    var layout: ?*c.IDWriteTextLayout = null;
    if (dw.lpVtbl.*.CreateTextLayout.?(dw, &buf, @intCast(len), format, 1e6, 1e6, &layout) < 0 or layout == null) return 0;
    defer releaseCom(layout);
    var m: c.DWRITE_TEXT_METRICS = undefined;
    if (layout.?.lpVtbl.*.GetMetrics.?(layout, &m) < 0) return 0;
    return m.widthIncludingTrailingWhitespace;
}

/// A select's: its widest option, its inner padding and its arrow
/// (Chromium on Windows: about 20.6px more; "one" in Arial 13.33px is 43).
fn selectWidth(n: *const Node) f32 {
    var widest: f32 = 0;
    for (n.props.options orelse &.{}) |o| widest = @max(widest, plainWidth(n, o[1]));
    return @round(widest + 20.6);
}

const iid_font_face1: c.GUID = .{ .Data1 = 0xa71efdb4, .Data2 = 0x9fdb, .Data3 = 0x4838, .Data4 = .{ 0xad, 0x90, 0xcf, 0xc3, 0xbe, 0x8c, 0x3d, 0xaf } };

/// Backend.font_metrics: the default sans (or monospace) face's ascent,
/// descent and line gap in px at `size`, unhinted.
fn fontMetrics(_: *anyopaque, size: f32, mono: bool, out: *[3]f32) bool {
    if (!(size > 0) or !std.math.isFinite(size)) return false;
    const r = fontRatios(if (mono) mono_face else sans_face, 400, false) orelse return false;
    out.* = .{ r[0] * size, r[1] * size, r[2] * size };
    return true;
}

/// Backend.font_metrics_family: the same for a CSS font-family list (a
/// line's strut in its block's own font, as familyOf resolves it).
fn fontMetricsFamily(_: *anyopaque, size: f32, mono: bool, family: []const u8, out: *[3]f32) bool {
    if (!(size > 0) or !std.math.isFinite(size)) return false;
    const r = fontRatios(familyOf(family, mono), 400, false) orelse return false;
    out.* = .{ r[0] * size, r[1] * size, r[2] * size };
    return true;
}

/// The run a line's box is made from: the largest (its font sets
/// line-height: normal and the baseline).
fn largestRun(runs: []const tree_mod.Run) ?tree_mod.Run {
    var big: ?tree_mod.Run = null;
    for (runs) |r| if (big == null or r.sz > big.?.sz) {
        big = r;
    };
    return big;
}

fn runFamily(props: *const tree_mod.Props, r: tree_mod.Run) [:0]const u16 {
    return familyOf(r.ff orelse props.ff, r.mono or props.mono);
}

/// line-height: normal as Chromium makes it: the font's ascent, descent
/// and line gap, each rounded (Segoe UI at 16px: 17 + 4 + 0 = 21).
fn normalLineHeight(family: [:0]const u16, size: f32, weight: f32, italic: bool) ?f32 {
    const m = fontRatios(family, weight, italic) orelse return null;
    return @round(m[0] * size) + @round(m[1] * size) + @round(m[2] * size);
}

/// The height of a line of this text, as CSS stacks its inline boxes on
/// one baseline (textExtent): every line alike, the tallest any line can
/// be (lineExtents has each line's). Its CSS line-height (fractional, as
/// Chromium keeps it) when the fonts' metrics can't be had.
fn lineBox(props: *const tree_mod.Props) ?f32 {
    if (textExtent(props)) |e| return e.top + e.bottom;
    if (props.lh) |lh| return if (lh > 0) lh else null;
    return null;
}

/// Above and below a line's baseline (px).
const Extent = struct { top: f32, bottom: f32 };

/// An inline box's extent on its line as Chromium lays it out: its font's
/// ascent and descent (each rounded) and the leading around them: the
/// line-height less them, or the font's line gap (rounded) when normal,
/// split with the smaller half above.
fn fontExtent(family: [:0]const u16, sz: f32, weight: f32, italic: bool, lh: ?f32) ?Extent {
    const m = fontRatios(family, weight, italic) orelse return null;
    const a = @round(m[0] * sz);
    const d = @round(m[1] * sz);
    if (lh) |h| if (h > 0) {
        // Chromium floors the half above (CalculateLeadingSpace); the
        // rest goes below.
        const lead = h - (a + d);
        const up = @floor(lead / 2);
        return .{ .top = a + up, .bottom = d + lead - up };
    };
    const gap = @round(m[2] * sz);
    const up = @floor(gap / 2);
    return .{ .top = a + up, .bottom = d + gap - up };
}

/// An inline box's content area: its font's ascent and descent, rounded.
fn contentExtent(family: [:0]const u16, sz: f32, weight: f32, italic: bool) ?Extent {
    const m = fontRatios(family, weight, italic) orelse return null;
    return .{ .top = @round(m[0] * sz), .bottom = @round(m[1] * sz) };
}

/// The block's own font's (CSS's strut: every line has it).
fn strutExtent(props: *const tree_mod.Props) ?Extent {
    return fontExtent(familyOf(props.ff, props.mono), props.fz orelse 16, props.fwt orelse 400, props.it, props.lh);
}

fn runExtent(props: *const tree_mod.Props, r: tree_mod.Run) ?Extent {
    return fontExtent(runFamily(props, r), r.sz, r.w, r.i, r.lh orelse props.lh);
}

fn widen(e: ?Extent, x: ?Extent) ?Extent {
    const b = x orelse return e;
    const a = e orelse return b;
    return .{ .top = @max(a.top, b.top), .bottom = @max(a.bottom, b.bottom) };
}

/// Every run's box with the strut's: the line box of a line that has
/// them all (a 16px Arial line with monospace code in it: 15 above, 4
/// below, 19, as Chromium makes it).
fn textExtent(props: *const tree_mod.Props) ?Extent {
    var e = strutExtent(props);
    for (props.runs orelse &.{}) |r| e = widen(e, runExtent(props, r));
    return e;
}

/// Each line's extent when they differ (a font on some lines only), from
/// the runs on it; null when every line is textExtent's (the layout's
/// uniform spacing is then exact). With `glyphs`, each line's content area
/// too (its fonts' ascent and descent: where its glyphs are).
fn lineExtents(props: *const tree_mod.Props, layout: *c.IDWriteTextLayout, out: []Extent, glyphs: ?[]Extent) ?[]Extent {
    const runs = props.runs orelse return null;
    if (runs.len < 2) return null;
    const all = textExtent(props) orelse return null;
    var lines: [64]c.DWRITE_LINE_METRICS = undefined;
    var count: u32 = 0;
    if (layout.lpVtbl.*.GetLineMetrics.?(layout, &lines, lines.len, &count) < 0 or count < 2 or count > lines.len) return null;
    const strut = strutExtent(props);
    const strut_glyphs = contentExtent(familyOf(props.ff, props.mono), props.fz orelse 16, props.fwt orelse 400, props.it);
    var differ = false;
    var ls: u32 = 0;
    var ri: usize = 0;
    var rs: u32 = 0; // ri's first unit
    for (lines[0..count], 0..) |line, k| {
        if (k >= out.len) return null;
        const le = ls + line.length;
        var e = strut;
        var g = strut_glyphs;
        // The runs with a part on this line.
        while (ri < runs.len) {
            const len: u32 = @intCast(std.unicode.calcUtf16LeLen(runs[ri].t) catch runs[ri].t.len);
            const re = rs + len;
            if (re > ls and rs < le and len > 0) {
                e = widen(e, runExtent(props, runs[ri]));
                g = widen(g, contentExtent(runFamily(props, runs[ri]), runs[ri].sz, runs[ri].w, runs[ri].i));
            }
            if (re > le) break; // goes on to the next line
            rs = re;
            ri += 1;
        }
        const x = e orelse all;
        out[k] = x;
        if (glyphs) |gs| if (k < gs.len) {
            gs[k] = g orelse x;
        };
        if (x.top != all.top or x.bottom != all.bottom) differ = true;
        ls = le;
    }
    return if (differ) out[0..count] else null;
}

/// Where line `k` is drawn in a layout spaced uniformly by textExtent:
/// how far to move it (0 when lines are alike) to sit where its own
/// extent puts it, below the lines before it.
fn lineShift(exts: []const Extent, all: Extent, k: usize) f32 {
    var y: f32 = 0;
    for (exts[0..k]) |e| y += e.top + e.bottom;
    const h = all.top + all.bottom;
    return y + exts[k].top - (@as(f32, @floatFromInt(k)) * h + all.top);
}

/// A field's line: its CSS line-height, else its font's normal one.
fn fieldLine(n: *const Node) f32 {
    if (n.props.lh) |lh| if (lh > 0) return lh;
    const fz = n.props.fz orelse 16;
    return normalLineHeight(familyOf(n.props.ff, n.props.mono), fz, n.props.fwt orelse 400, n.props.it) orelse @round(fz * 1.15);
}

/// A text's height from DirectWrite's: lines of its line box exactly
/// (a fractional line-height kept, as Chromium does; Yoga rounds a text's
/// height to the nearest pixel), else rounded up.
fn textHeight(props: *const tree_mod.Props, h: f32) f32 {
    return if (lineBox(props) != null) h else @ceil(h);
}

/// Where a line of `lh` puts its baseline, as CSS does: the tallest top of
/// its inline boxes (textExtent: each font's rounded ascent plus its share
/// of the leading, which is negative when lh is shorter than the font: the
/// glyphs stay centered on the line, a 36px h1 on 23.2px lines); 0.8 lh
/// when the metrics can't be had.
fn cssBaseline(props: *const tree_mod.Props, runs: []const tree_mod.Run, lh: f32) f32 {
    _ = runs;
    const e = textExtent(props) orelse return lh * 0.8;
    return e.top;
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
    const base_family = familyOf(props.ff, props.mono);
    if (dw.lpVtbl.*.CreateTextFormat.?(dw, base_family.ptr, null, c.DWRITE_FONT_WEIGHT_NORMAL, c.DWRITE_FONT_STYLE_NORMAL, c.DWRITE_FONT_STRETCH_NORMAL, fz, std.unicode.utf8ToUtf16LeStringLiteral(""), &format) < 0) return null;
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
    // Every line exactly its CSS box (line-height, else normal as Chromium
    // makes it), the glyphs centered as CSS does.
    if (lineBox(props)) |lh| _ = fvt.SetLineSpacing.?(fmt, c.DWRITE_LINE_SPACING_METHOD_UNIFORM, lh, cssBaseline(props, runs, lh));
    for (runs, u.ranges) |r, range| {
        if (range.length == 0) continue;
        _ = vt.SetFontSize.?(l, r.sz, range);
        _ = vt.SetFontWeight.?(l, @intFromFloat(@max(1, @min(999, r.w))), range);
        if (r.i) _ = vt.SetFontStyle.?(l, c.DWRITE_FONT_STYLE_ITALIC, range);
        const fam = runFamily(props, r);
        if (fam.ptr != base_family.ptr) _ = vt.SetFontFamilyName.?(l, fam.ptr, range);
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
    // letter-spacing: after every character, as browsers add it
    // (IDWriteTextLayout1, Windows 8+; without it, none).
    if (props.ls) |ls| if (ls != 0 and std.math.isFinite(ls)) {
        var l1: ?*c.IDWriteTextLayout1 = null;
        if (vt.QueryInterface.?(l, &iid_text_layout1, @ptrCast(&l1)) >= 0) if (l1) |x| {
            defer releaseCom(@as(?*c.IDWriteTextLayout1, x));
            _ = x.lpVtbl.*.SetCharacterSpacing.?(x, 0, ls, 0, .{ .startPosition = 0, .length = @intCast(u.text.len) });
        };
    };
    inlineBoxRoom(l, runs, if (props.ls) |ls| (if (std.math.isFinite(ls)) ls else 0) else 0);
    return l;
}

const iid_text_layout1: c.GUID = .{ .Data1 = 0x9064D822, .Data2 = 0x80A7, .Data3 = 0x465C, .Data4 = .{ 0xA9, 0x86, 0xDF, 0x65, 0xF7, 0x8B, 0x8F, 0xEB } };

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
    const r = n.radiusXY();
    const mask = if (!r.square()) roundRectGeometry(f, r) else null;
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
    /// The current path as whole circles (the bitmap's space: cx, cy,
    /// radius), while it's nothing else: a game's balls in one path.
    /// Filled opaque, they're drawn one by one (fillCircles), as Apple's
    /// apple_draw.zig: a geometry of hundreds of circles a fill was most of
    /// Breakout's frame at 500 balls.
    circles: std.ArrayList([3]f32) = .empty,
    /// The path is only `circles` (each starting fresh or at a moveTo on
    /// its own start point), all wound the same way.
    only_circles: bool = true,
    circles_ccw: bool = false,
    /// A moveTo not yet followed by anything (the bitmap's space).
    pending_move: ?P2 = null,

    fn deinit(cv: *CanvasPainter) void {
        // popClips(0) ran before EndDraw; anything left is only released.
        for (cv.clips.items) |g| releaseCom(@as(?*c.ID2D1PathGeometry, g));
        cv.clips.deinit(cv.gpa);
        cv.circles.deinit(cv.gpa);
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
                cv.circles.clearRetainingCapacity();
                cv.only_circles = true;
                cv.pending_move = null;
            },
            .close_path => if (cv.cur != null) {
                cv.add(.close);
                cv.cur = cv.start;
                // A closed circle is still one; an open moveTo isn't a figure.
                if (cv.pending_move != null) cv.notCircles();
            },
            .move_to => |pt| {
                const p = cv.point(pt[0], pt[1]);
                cv.moveTo(p);
                cv.pending_move = p;
            },
            .line_to => |pt| {
                cv.lineTo(cv.point(pt[0], pt[1]));
                cv.notCircles();
            },
            .rect => |r| {
                cv.notCircles();
                cv.moveTo(cv.point(r[0], r[1]));
                cv.lineTo(cv.point(r[0] + r[2], r[1]));
                cv.lineTo(cv.point(r[0] + r[2], r[1] + r[3]));
                cv.lineTo(cv.point(r[0], r[1] + r[3]));
                cv.add(.close);
                // A new subpath at the rectangle's corner.
                cv.moveTo(cv.point(r[0], r[1]));
            },
            .arc => |a| {
                cv.noteArc(a.x, a.y, a.r, a.a0, a.a1, a.ccw);
                cv.arc(a.x, a.y, a.r, a.a0, a.a1, a.ccw);
            },
            .bezier_to => |b| {
                cv.notCircles();
                const c1 = cv.point(b[0], b[1]);
                if (cv.cur == null) cv.moveTo(c1);
                const end = cv.point(b[4], b[5]);
                cv.add(.{ .bezier = .{ c1, cv.point(b[2], b[3]), end } });
                cv.cur = end;
            },
            .fill => |even| if (cv.path.items.len > 0) {
                if (!even and cv.fillCircles()) return;
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

    /// The path gets something other than a whole circle.
    fn notCircles(cv: *CanvasPainter) void {
        cv.only_circles = false;
        cv.circles.clearRetainingCapacity();
    }

    /// An arc is added (user units, before the transform): a whole circle
    /// keeps the path's circles, anything else ends them.
    fn noteArc(cv: *CanvasPainter, x: f32, y: f32, r: f32, a0: f32, a1: f32, ccw: bool) void {
        if (!cv.only_circles) return;
        const m = mget(cv.st.xf);
        const two_pi: f32 = 2.0 * std.math.pi;
        // (A turn from a0 != 0 may round a hair short in f32.)
        const whole = (if (ccw) a0 - a1 else a1 - a0) >= two_pi - 1e-4;
        // A circle stays one: orthogonal columns of the same length.
        const s2 = m[0] * m[0] + m[1] * m[1];
        const similar = s2 > 0 and @abs(s2 - (m[2] * m[2] + m[3] * m[3])) <= 1e-5 * s2 and @abs(m[0] * m[2] + m[1] * m[3]) <= 1e-5 * s2;
        // Its winding in the bitmap's space: a reflection turns it round.
        const winding = ccw != (m[0] * m[3] - m[1] * m[2] < 0);
        if (!whole or !similar or !(r >= 0) or (cv.circles.items.len > 0 and winding != cv.circles_ccw)) return cv.notCircles();
        // Its start point: where a moveTo must be, if the path has more.
        const start = cv.point(x + r * @cos(a0), y + r * @sin(a0));
        if (cv.pending_move) |p| {
            const tol = 1e-3 * @max(1.0, @sqrt(s2) * r);
            if (@abs(p.x - start.x) > tol or @abs(p.y - start.y) > tol) return cv.notCircles();
        } else if (cv.path.items.len > 0) {
            // Joined to what came before by a line: not just circles.
            return cv.notCircles();
        }
        const center = cv.point(x, y);
        if (!std.math.isFinite(center.x) or !std.math.isFinite(center.y)) return cv.notCircles();
        cv.pending_move = null;
        cv.circles_ccw = winding;
        cv.circles.append(cv.gpa, .{ center.x, center.y, @sqrt(s2) * r }) catch cv.notCircles();
    }

    /// Off in a test: the same pictures the slow way.
    var circles_one_by_one = true;

    /// The current path filled as its circles, one by one, when that's the
    /// same picture: a nonzero fill (even-odd makes holes where they
    /// overlap) of whole circles wound one way (their union), in an opaque
    /// color (an overlap can't blend twice). Many circles only: a few go
    /// the usual way. False: fill the path.
    fn fillCircles(cv: *CanvasPainter) bool {
        if (!circles_one_by_one or !cv.only_circles or cv.circles.items.len < 8 or cv.pending_move != null) return false;
        const col = switch (cv.st.fill) {
            .color => |x| x,
            .grad => return false,
        };
        if (col[3] * cv.st.alpha < 1) return false;
        const brush = cv.brushOf(cv.st.fill) orelse return false;
        defer releaseCom(@as(?*c.ID2D1Brush, brush));
        const vt = cv.rt.lpVtbl.*;
        vt.SetTransform.?(cv.rt, &identity);
        for (cv.circles.items) |k| {
            const e: c.D2D1_ELLIPSE = .{ .point = .{ .x = k[0], .y = k[1] }, .radiusX = k[2], .radiusY = k[2] };
            vt.FillEllipse.?(cv.rt, &e, brush);
        }
        return true;
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

/// A text's width as the layout keeps it: DirectWrite's, rounded up to a
/// LayoutUnit (1/64 px) as Chromium keeps it (a whole pixel more made a
/// chip or a button 1 to 2px wider than WebView2's). A sum of glyph pairs
/// may land a hair over the layout's own sum: 0.001 px of slack.
fn textWidth(w: f32) f32 {
    return @ceil((w - 0.001) * 64) / 64;
}

/// A text's size at `width` (inf: unwrapped), through the shared cache
/// (keyed by the text and every layout input, so equal rows share it).
fn measuredText(s: *Surface, n: *Node, width: f32) ?[2]f32 {
    const actual_width = if (n.props.nowrap or std.math.isInf(width)) std.math.inf(f32) else @max(1, width);
    // One line of plain text: its width from its glyph pairs, no layout.
    if (fastTextSize(s, &n.props)) |size| if (std.math.isInf(actual_width) or size[0] <= actual_width) {
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
    var size: [2]f32 = .{ textWidth(m.widthIncludingTrailingWhitespace), textHeight(&n.props, m.height) };
    // Lines of their own heights: theirs added up.
    var ext_buf: [64]Extent = undefined;
    if (lineExtents(&n.props, layout, &ext_buf, null)) |xs| {
        size[1] = 0;
        for (xs) |e| size[1] += e.top + e.bottom;
    }
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

const FontKey = struct { mono: bool, italic: bool, weight: u16, size: u32, fz: u32, lh: i32, family: u64 };
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
    if (runs.len != 1 or props.ls != null or runs[0].ib != null) return null;
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
        .family = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(runFamily(props, r))),
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
        table.height = textHeight(props, p.h);
    }
    var sum: f64 = 0;
    for (t, 0..) |ch, i| {
        const next: u8 = if (i + 1 < t.len) t[i + 1] else 128;
        sum += pairWidth(s, props, r, table, ch, next) orelse return null;
    }
    // As measuredText rounds DirectWrite's width; a sum of pairs may land
    // a hair over a whole number the layout's own sum lands on.
    const w: f32 = @floatCast(sum);
    return .{ textWidth(w), table.height };
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
    const size: [2]f32 = .{ textWidth(m.widthIncludingTrailingWhitespace), textHeight(&n.props, m.height) };
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
    switch (n.kind) {
        .text => {
            // Its natural size (kept on the node until its props or text
            // change); at a width it fits in, that's the answer. Yoga asks
            // several times per node and layout: a DirectWrite layout each
            // time was most of a big list's update.
            // Its first baseline (inline rows line up on it): where
            // textLayoutOf's uniform lines put it (cssBaseline).
            if (lineBox(&n.props)) |lh| n.baseline = cssBaseline(&n.props, n.props.runs orelse &.{}, lh);
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
            // Broken into lines at max_width: no wider than that (its
            // widest line + 1 can be), so it's drawn at the width its lines
            // were broken at.
            out[0] = @min(out[0], max_width);
        },
        // As Chromium: a line of the field's font (its line-height, else
        // the font's normal one), `rows` of them in a textarea; a select's
        // menu list adds 1px above and below. As wide as `size` (cols)
        // characters, `cols` of them in a textarea, a select's widest option.
        .input, .select, .textarea => {
            const line = fieldLine(n);
            const w: f32 = switch (n.kind) {
                .select => selectWidth(n),
                .textarea => textareaWidth(n, n.props.cols orelse 20),
                else => if (n.props.cols) |size| inputWidth(n, size) else 150,
            };
            const h = switch (n.kind) {
                .select => line + 2,
                .textarea => line * (n.props.rows orelse 2),
                else => line,
            };
            out.* = .{ @min(max_width, w), h };
        },
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

    const r = n.radiusXY();
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
    // overflow: hidden (or a scroller) with rounded corners: the children
    // are cut to the rounded padding box (the box's own border isn't),
    // through a layer with that shape as its mask. Only such boxes pay.
    const mask: ?*c.ID2D1Geometry = if (n.kids.items.len > 0 and n.roundClips()) roundClipGeometry(n.paddingClipXY()) else null;
    defer if (mask) |m| releaseCom(@as(?*c.ID2D1Geometry, m));
    if (mask) |m| {
        const pb = n.paddingClipXY().rect;
        const params: c.D2D1_LAYER_PARAMETERS = .{
            .contentBounds = rectF(pb),
            .geometricMask = m,
            .maskAntialiasMode = c.D2D1_ANTIALIAS_MODE_PER_PRIMITIVE,
            .maskTransform = identity,
            .opacity = 1,
            .opacityBrush = null,
            .layerOptions = c.D2D1_LAYER_OPTIONS_NONE,
        };
        vt.PushLayer.?(p.rt, &params, null);
    }
    // CSS paint order: positioned boxes (a sticky header) over the flow.
    var it: tree_mod.PaintIter = .{ .kids = n.kids.items };
    while (it.next()) |k| paint(p, k);
    if (mask != null) vt.PopLayer.?(p.rt);
    // Its scrollbar, over its content (in its own clip).
    if (n.gutter > 0) paintScrollbar(p, n);
    // The outline: over the box and its children, outside its own clip
    // (with its transform and opacity).
    if (props.ol) |ol| paintOutline(p, f, r, ol);
}

/// CSS outline: a border of its own around the box grown by offset +
/// width, its corners the box's radius grown as much (square ones stay
/// square), solid, dashed or dotted.
fn paintOutline(p: *Painter, f: Rect, r: Radii, ol: tree_mod.Outline) void {
    if (!(ol.w > 0) or !(ol.c[3] > 0)) return;
    const grow = ol.o + ol.w;
    const box: Rect = .{ .x = f.x - grow, .y = f.y - grow, .w = f.w + 2 * grow, .h = f.h + 2 * grow };
    if (box.w <= 2 * ol.w or box.h <= 2 * ol.w) return;
    var radii = r.grown(grow);
    for (&radii.x) |*x| x.* = @max(x.*, ol.r);
    for (&radii.y) |*y| y.* = @max(y.*, ol.r);
    // A focus ring's halo: 1px around it, its corners 1px rounder.
    if (ol.h) |h| if (h[3] > 0) {
        const halo: Rect = .{ .x = box.x - 1, .y = box.y - 1, .w = box.w + 2, .h = box.h + 2 };
        border(p, halo, radii.grown(1), .{ 1, 1, 1, 1 }, .{ h, h, h, h }, null);
    };
    const bw = [4]f32{ ol.w, ol.w, ol.w, ol.w };
    const bc = [4]tree_mod.Color{ ol.c, ol.c, ol.c, ol.c };
    border(p, box, radii, bw, bc, ol.s);
}

/// A rounded rectangle as a geometry (caller releases): Direct2D's own
/// when the corners are alike, else a path of per-corner arcs.
fn roundClipGeometry(rr: tree_mod.RoundRectXY) ?*c.ID2D1Geometry {
    if (rr.rect.w <= 0 or rr.rect.h <= 0) return null;
    // Radii that don't fit are scaled down together, as CSS does.
    const r = rr.radii.fitted(rr.rect.w, rr.rect.h);
    if (r.uniform()) {
        const fac = d2d.?;
        const shape: c.D2D1_ROUNDED_RECT = .{ .rect = rectF(rr.rect), .radiusX = r.x[0], .radiusY = r.y[0] };
        var geo: ?*c.ID2D1RoundedRectangleGeometry = null;
        if (fac.lpVtbl.*.CreateRoundedRectangleGeometry.?(fac, &shape, &geo) < 0 or geo == null) return null;
        return @ptrCast(geo);
    }
    const geo = roundRectGeometry(rr.rect, r) orelse return null;
    return @ptrCast(geo);
}

fn uniform(r: [4]f32) bool {
    return r[0] == r[1] and r[1] == r[2] and r[2] == r[3];
}

/// A box with per-corner elliptical radii (top-left, top-right,
/// bottom-right, bottom-left) as a path geometry. Caller releases.
fn roundRectGeometry(f: Rect, r: Radii) ?*c.ID2D1PathGeometry {
    const fac = d2d.?;
    var geo: ?*c.ID2D1PathGeometry = null;
    if (fac.lpVtbl.*.CreatePathGeometry.?(fac, &geo) < 0) return null;
    var sink: ?*c.ID2D1GeometrySink = null;
    if (geo.?.lpVtbl.*.Open.?(geo, &sink) < 0) {
        releaseCom(geo);
        return null;
    }
    roundFigure(sink.?, f, r.x, r.y);
    const simple: *c.ID2D1SimplifiedGeometrySink = @ptrCast(sink.?);
    _ = simple.lpVtbl.*.Close.?(simple);
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

fn fillShape(p: *Painter, f: Rect, r: Radii, brush: *c.ID2D1Brush) void {
    if (f.w <= 0 or f.h <= 0) return;
    const vt = p.vt();
    if (r.square()) {
        const rc = rectF(f);
        vt.FillRectangle.?(p.rt, &rc, brush);
        return;
    }
    if (r.uniform()) {
        const rr: c.D2D1_ROUNDED_RECT = .{ .rect = rectF(f), .radiusX = r.x[0], .radiusY = r.y[0] };
        vt.FillRoundedRectangle.?(p.rt, &rr, brush);
        return;
    }
    const geo = roundRectGeometry(f, r) orelse return;
    defer releaseCom(@as(?*c.ID2D1PathGeometry, geo));
    vt.FillGeometry.?(p.rt, @ptrCast(geo), brush, null);
}

fn strokeShape(p: *Painter, f: Rect, r: Radii, brush: *c.ID2D1Brush, width: f32, st: ?*c.ID2D1StrokeStyle) void {
    if (f.w <= 0 or f.h <= 0) return;
    const vt = p.vt();
    if (r.square()) {
        const rc = rectF(f);
        vt.DrawRectangle.?(p.rt, &rc, brush, width, st);
        return;
    }
    if (r.uniform()) {
        const rr: c.D2D1_ROUNDED_RECT = .{ .rect = rectF(f), .radiusX = r.x[0], .radiusY = r.y[0] };
        vt.DrawRoundedRectangle.?(p.rt, &rr, brush, width, st);
        return;
    }
    const geo = roundRectGeometry(f, r) orelse return;
    defer releaseCom(@as(?*c.ID2D1PathGeometry, geo));
    vt.DrawGeometry.?(p.rt, @ptrCast(geo), brush, width, st);
}

/// A brush for a CSS gradient over `f`. Caller releases.
fn gradientBrush(p: *Painter, f: Rect, g: tree_mod.Gradient) ?*c.ID2D1Brush {
    if (g.stops.len == 0) return null;
    // CSS angles: 0deg points up, clockwise; the gradient line spans the box.
    const a = g.angle * std.math.pi / 180.0;
    const dx = @sin(a);
    const dy = -@cos(a);
    const len = @abs(f.w * dx) + @abs(f.h * dy);
    const radial = g.radialIn(f.w, f.h);
    // Positions in px or missing, and a repeating gradient's period
    // (tree.zig); a period repeats by the brush wrapping.
    var resolved_buf: [64]tree_mod.Gradient.Stop = undefined;
    const res = g.resolve(if (radial) |rad| rad[2] else len, &resolved_buf);
    if (res.stops.len == 0) return null;
    var stops_buf: [64]c.D2D1_GRADIENT_STOP = undefined;
    const count = @min(res.stops.len, stops_buf.len);
    for (res.stops[0..count], 0..) |st, i| stops_buf[i] = .{ .position = st[4], .color = d2dColor(.{ st[0], st[1], st[2], st[3] }) };
    const per = res.period orelse 1;
    const vt = p.vt();
    var coll: ?*c.ID2D1GradientStopCollection = null;
    const extend: c.D2D1_EXTEND_MODE = if (res.period != null) c.D2D1_EXTEND_MODE_WRAP else c.D2D1_EXTEND_MODE_CLAMP;
    if (vt.CreateGradientStopCollection.?(p.rt, &stops_buf, @intCast(count), c.D2D1_GAMMA_2_2, extend, &coll) < 0) return null;
    defer releaseCom(coll);
    if (radial) |rad| {
        const props: c.D2D1_RADIAL_GRADIENT_BRUSH_PROPERTIES = .{
            .center = .{ .x = f.x + rad[0], .y = f.y + rad[1] },
            .gradientOriginOffset = .{ .x = 0, .y = 0 },
            .radiusX = rad[2] * per,
            .radiusY = rad[3] * per,
        };
        var b: ?*c.ID2D1RadialGradientBrush = null;
        if (vt.CreateRadialGradientBrush.?(p.rt, &props, null, coll, &b) < 0) return null;
        return @ptrCast(b);
    }
    const cx = f.x + f.w / 2;
    const cy = f.y + f.h / 2;
    // One period long when it repeats (from the line's start).
    const props: c.D2D1_LINEAR_GRADIENT_BRUSH_PROPERTIES = .{
        .startPoint = .{ .x = cx - dx * len / 2, .y = cy - dy * len / 2 },
        .endPoint = .{ .x = cx - dx * len / 2 + dx * len * per, .y = cy - dy * len / 2 + dy * len * per },
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

/// Chromium's dash and gap, in border widths (StyledStrokeData): a dash 3
/// wide with a 2-wide gap below 3px, 2 and 1 from 3px; a dot and a gap 1.
fn dashRatio(style: tree_mod.BorderStyle, w: f32) [2]f32 {
    if (style == .dotted) return .{ 1, 1 };
    return if (w >= 3) .{ 2, 1 } else .{ 3, 2 };
}

/// The gap that fits whole dashes to `length` (Chromium's
/// SelectBestDashGap): a closed path has as many gaps as dashes, an open
/// one a dash at each end; of the two nearest counts, the gap nearer the
/// wanted one.
fn bestDashGap(length: f32, dash: f32, gap: f32, closed: bool) f32 {
    const available = if (closed) length else length + gap;
    const min_dashes = @floor(available / @max(1e-3, dash + gap));
    const max_dashes = min_dashes + 1;
    const min_gaps = if (closed) min_dashes else min_dashes - 1;
    const max_gaps = if (closed) max_dashes else max_dashes - 1;
    const min_gap = if (min_gaps > 0) (length - min_dashes * dash) / min_gaps else gap;
    const max_gap = if (max_gaps > 0) (length - max_dashes * dash) / max_gaps else gap;
    return if (max_gap <= 0 or @abs(min_gap - gap) < @abs(max_gap - gap)) min_gap else max_gap;
}

/// A rounded border dashed or dotted as Chromium strokes it: one closed
/// path from the top side's start (after the top-left corner), clockwise,
/// its dashes' gap fitted to the whole length (bestDashGap); round dots
/// from 3px.
fn dashedShape(p: *Painter, f: Rect, r: Radii, brush: *c.ID2D1Brush, w: f32, style: tree_mod.BorderStyle) void {
    if (f.w <= 0 or f.h <= 0 or !(w > 0)) return;
    const geo = roundRectGeometry(f, r) orelse return;
    defer releaseCom(@as(?*c.ID2D1PathGeometry, geo));
    var len: f32 = 0;
    const g: *c.ID2D1Geometry = @ptrCast(geo);
    if (g.lpVtbl.*.ComputeLength.?(g, null, 0.25, &len) < 0 or !(len > 0)) return;
    const ratio = dashRatio(style, w);
    const dash = ratio[0] * w;
    const gap = bestDashGap(len, dash, ratio[1] * w, true);
    const round = style == .dotted and w >= 3;
    // In stroke widths; a round dot is a 0-long dash with round caps.
    const dashes = if (round) [2]f32{ 0, (dash + gap) / w } else [2]f32{ dash / w, gap / w };
    const cap: c.D2D1_CAP_STYLE = if (round) c.D2D1_CAP_STYLE_ROUND else c.D2D1_CAP_STYLE_FLAT;
    const props: c.D2D1_STROKE_STYLE_PROPERTIES = .{ .startCap = c.D2D1_CAP_STYLE_FLAT, .endCap = c.D2D1_CAP_STYLE_FLAT, .dashCap = cap, .lineJoin = c.D2D1_LINE_JOIN_MITER, .miterLimit = 10, .dashStyle = c.D2D1_DASH_STYLE_CUSTOM, .dashOffset = if (round) -0.5 * dash / w else 0 };
    var st: ?*c.ID2D1StrokeStyle = null;
    if (d2d.?.lpVtbl.*.CreateStrokeStyle.?(d2d.?, &props, &dashes, 2, &st) < 0 or st == null) return;
    defer releaseCom(st);
    p.vt().DrawGeometry.?(p.rt, @ptrCast(geo), brush, w, st);
}

/// One straight side dashed or dotted as Chromium draws it: a dash (3
/// widths; a dot: 1) at each end and whole ones between, the gaps
/// stretched to fit. Dots from 3 px are round.
fn dashedSide(p: *Painter, sd: Rect, across: bool, w: f32, style: tree_mod.BorderStyle, brush: *c.ID2D1Brush) void {
    const len = if (across) sd.w else sd.h;
    if (len <= 0 or w <= 0) return;
    const ratio = dashRatio(style, w);
    const dash = ratio[0] * w;
    const gap = bestDashGap(len, dash, ratio[1] * w, false);
    var n = @round((len + gap) / @max(1e-3, dash + gap));
    if (n < 1) n = 1;
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

fn border(p: *Painter, f: Rect, r: Radii, bw: [4]f32, bc: ?[4]tree_mod.Color, bs: ?tree_mod.BorderStyle) void {
    const colors = bc orelse return;
    // Square corners, dashed or dotted: each side's dashes fitted to it
    // (the per-side path below); one pattern around the rectangle would
    // leave a side a stray dash.
    const square = r.square();
    if (uniform(bw) and bw[0] > 0 and !(bs != null and square)) {
        const st = borderStroke(bs, bw[0]);
        const half = bw[0] / 2;
        const inner: Rect = .{ .x = f.x + half, .y = f.y + half, .w = f.w - bw[0], .h = f.h - bw[0] };
        const ri = r.grown(-half);
        const same = for (colors[1..]) |col| {
            if (!std.mem.eql(f32, &col, &colors[0])) break false;
        } else true;
        if (same) {
            if (bs) |style| dashedShape(p, inner, ri, p.solid(colors[0]), bw[0], style) else strokeShape(p, inner, ri, p.solid(colors[0]), bw[0], st);
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
            if (bs) |style| dashedShape(p, inner, ri, p.solid(colors[i]), bw[0], style) else strokeShape(p, inner, ri, p.solid(colors[i]), bw[0], st);
            vt.PopLayer.?(p.rt);
        }
        return;
    }
    // Solid sides of different widths: the ring between the border box
    // and the padding box, its inner corners elliptical (each radius less
    // the two sides' widths), each color cut along the line from an outer
    // corner to the padding box's, as browsers join them.
    if (bs == null) {
        unevenBorder(p, f, r, bw, colors);
        return;
    }
    // Dashed or dotted, per side (straight edges).
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

fn unevenBorder(p: *Painter, f: Rect, radii: Radii, bw: [4]f32, colors: [4]tree_mod.Color) void {
    if (f.w <= 0 or f.h <= 0) return;
    if (@max(@max(bw[0], bw[1]), @max(bw[2], bw[3])) <= 0) return;
    // Radii that don't fit are scaled down together, as CSS does.
    const r = radii.fitted(f.w, f.h);
    const inner: Rect = .{ .x = f.x + bw[3], .y = f.y + bw[0], .w = @max(0, f.w - bw[1] - bw[3]), .h = @max(0, f.h - bw[0] - bw[2]) };
    // Inner corners (top-left, top-right, bottom-right, bottom-left): x
    // radius less the left or right side, y less the top or bottom.
    const ir = tree_mod.paddingBoxXY(f, r, bw).radii;
    const fac = d2d.?;
    var geo: ?*c.ID2D1PathGeometry = null;
    if (fac.lpVtbl.*.CreatePathGeometry.?(fac, &geo) < 0 or geo == null) return;
    defer releaseCom(geo);
    var sink: ?*c.ID2D1GeometrySink = null;
    if (geo.?.lpVtbl.*.Open.?(geo, &sink) < 0 or sink == null) return;
    const simple: *c.ID2D1SimplifiedGeometrySink = @ptrCast(sink.?);
    simple.lpVtbl.*.SetFillMode.?(simple, c.D2D1_FILL_MODE_ALTERNATE);
    roundFigure(sink.?, f, r.x, r.y);
    if (inner.w > 0 and inner.h > 0) roundFigure(sink.?, inner, ir.x, ir.y);
    _ = simple.lpVtbl.*.Close.?(simple);
    releaseCom(sink);
    const ring: *c.ID2D1Geometry = @ptrCast(geo.?);
    const vt = p.vt();
    const same = for (colors[1..]) |col| {
        if (!std.mem.eql(f32, &col, &colors[0])) break false;
    } else true;
    if (same) {
        if (colors[0][3] > 0) vt.FillGeometry.?(p.rt, ring, p.solid(colors[0]), null);
        return;
    }
    const outer = [4]c.D2D1_POINT_2F{
        .{ .x = f.x, .y = f.y },             .{ .x = f.x + f.w, .y = f.y },
        .{ .x = f.x + f.w, .y = f.y + f.h }, .{ .x = f.x, .y = f.y + f.h },
    };
    const pad = [4]c.D2D1_POINT_2F{
        .{ .x = inner.x, .y = inner.y },                     .{ .x = inner.x + inner.w, .y = inner.y },
        .{ .x = inner.x + inner.w, .y = inner.y + inner.h }, .{ .x = inner.x, .y = inner.y + inner.h },
    };
    const center: c.D2D1_POINT_2F = .{ .x = f.x + f.w / 2, .y = f.y + f.h / 2 };
    // Each corner's join line: from the outer corner through the padding
    // box's (toward the middle when both sides there are 0 wide).
    var dir: [4]c.D2D1_POINT_2F = undefined;
    for (0..4) |i| {
        dir[i] = .{ .x = pad[i].x - outer[i].x, .y = pad[i].y - outer[i].y };
        if (@abs(dir[i].x) + @abs(dir[i].y) < 1e-3) dir[i] = .{ .x = center.x - outer[i].x, .y = center.y - outer[i].y };
    }
    // Each line drawn out of its corner's square (the radius, or the
    // sides' widths), no further than the middle.
    var ends: [4]c.D2D1_POINT_2F = undefined;
    const cw = [4][2]f32{ .{ bw[3], bw[0] }, .{ bw[1], bw[0] }, .{ bw[1], bw[2] }, .{ bw[3], bw[2] } };
    for (0..4) |i| {
        const size = @min(@max(@max(r.x[i], r.y[i]), @max(cw[i][0], cw[i][1])) + 1, @min(f.w, f.h) / 2);
        const k = size / @max(1e-3, @max(@abs(dir[i].x), @abs(dir[i].y)));
        ends[i] = .{ .x = outer[i].x + dir[i].x * k, .y = outer[i].y + dir[i].y * k };
    }
    // Neighbouring sides of one color go under one mask: two anti-aliased
    // masks meeting on their join line would leave a faint seam there.
    const drawn = struct {
        fn at(w: [4]f32, cs: [4]tree_mod.Color, i: usize) bool {
            return w[i] > 0 and cs[i][3] > 0;
        }
    }.at;
    const sameAs = struct {
        fn at(w: [4]f32, cs: [4]tree_mod.Color, a: usize, b: usize) bool {
            return w[a] > 0 and w[b] > 0 and std.mem.eql(f32, &cs[a], &cs[b]);
        }
    }.at;
    // Start where a group begins (a side unlike the one before it).
    var first: usize = 0;
    while (first < 4 and sameAs(bw, colors, first, (first + 3) % 4)) first += 1;
    if (first == 4) first = 0;
    var done: usize = 0;
    while (done < 4) {
        const i = (first + done) % 4;
        var m: usize = 1;
        while (done + m < 4 and sameAs(bw, colors, i, (i + m) % 4)) m += 1;
        done += m;
        if (!drawn(bw, colors, i)) continue;
        // The sides' share: their outer corners, the last and first
        // corners' join lines as far as the curves go, then the middle (no
        // ring there).
        var pts: [8]c.D2D1_POINT_2F = undefined;
        var np: usize = 0;
        for (0..m + 1) |k| {
            pts[np] = outer[(i + k) % 4];
            np += 1;
        }
        pts[np] = ends[(i + m) % 4];
        pts[np + 1] = center;
        pts[np + 2] = ends[i];
        np += 3;
        const mask = polygonGeometry(pts[0..np]) orelse continue;
        defer releaseCom(@as(?*c.ID2D1PathGeometry, mask));
        const params: c.D2D1_LAYER_PARAMETERS = .{
            .contentBounds = .{ .left = -1e6, .top = -1e6, .right = 1e6, .bottom = 1e6 },
            .geometricMask = @ptrCast(mask),
            .maskAntialiasMode = c.D2D1_ANTIALIAS_MODE_PER_PRIMITIVE,
            .maskTransform = identity,
            .opacity = 1,
            .opacityBrush = null,
            .layerOptions = c.D2D1_LAYER_OPTIONS_NONE,
        };
        vt.PushLayer.?(p.rt, &params, null);
        vt.FillGeometry.?(p.rt, ring, p.solid(colors[i]), null);
        vt.PopLayer.?(p.rt);
    }
}

/// A rounded rectangle as one closed figure of `sink`, its corners
/// (top-left, top-right, bottom-right, bottom-left) elliptical: rx by ry.
fn roundFigure(sink: *c.ID2D1GeometrySink, f: Rect, rx: [4]f32, ry: [4]f32) void {
    const simple: *c.ID2D1SimplifiedGeometrySink = @ptrCast(sink);
    const x = f.x;
    const y = f.y;
    const w = f.w;
    const h = f.h;
    const corner = struct {
        fn add(s: *c.ID2D1GeometrySink, a: f32, b: f32, to: c.D2D1_POINT_2F) void {
            if (a <= 0 or b <= 0) {
                s.lpVtbl.*.AddLine.?(s, to);
                return;
            }
            const arc: c.D2D1_ARC_SEGMENT = .{ .point = to, .size = .{ .width = a, .height = b }, .rotationAngle = 0, .sweepDirection = c.D2D1_SWEEP_DIRECTION_CLOCKWISE, .arcSize = c.D2D1_ARC_SIZE_SMALL };
            s.lpVtbl.*.AddArc.?(s, &arc);
        }
    }.add;
    const k0: f32 = if (rx[0] > 0 and ry[0] > 0) 1 else 0;
    const k1: f32 = if (rx[1] > 0 and ry[1] > 0) 1 else 0;
    const k2: f32 = if (rx[2] > 0 and ry[2] > 0) 1 else 0;
    const k3: f32 = if (rx[3] > 0 and ry[3] > 0) 1 else 0;
    simple.lpVtbl.*.BeginFigure.?(simple, .{ .x = x + rx[0] * k0, .y = y }, c.D2D1_FIGURE_BEGIN_FILLED);
    sink.lpVtbl.*.AddLine.?(sink, .{ .x = x + w - rx[1] * k1, .y = y });
    corner(sink, rx[1], ry[1], .{ .x = x + w, .y = y + ry[1] * k1 });
    sink.lpVtbl.*.AddLine.?(sink, .{ .x = x + w, .y = y + h - ry[2] * k2 });
    corner(sink, rx[2], ry[2], .{ .x = x + w - rx[2] * k2, .y = y + h });
    sink.lpVtbl.*.AddLine.?(sink, .{ .x = x + rx[3] * k3, .y = y + h });
    corner(sink, rx[3], ry[3], .{ .x = x, .y = y + h - ry[3] * k3 });
    sink.lpVtbl.*.AddLine.?(sink, .{ .x = x, .y = y + ry[0] * k0 });
    corner(sink, rx[0], ry[0], .{ .x = x + rx[0] * k0, .y = y });
    simple.lpVtbl.*.EndFigure.?(simple, c.D2D1_FIGURE_END_CLOSED);
}

fn shadow(p: *Painter, f: Rect, r: Radii, sh: tree_mod.Shadow) void {
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
        for (&rr.x) |*x| x.* = @max(0, x.* + grow);
        for (&rr.y) |*y| y.* = @max(0, y.* + grow);
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
    const layout = textLayout(s, n, paintWidth(ct.w), &brushes) orelse return;
    defer releaseCom(@as(?*c.IDWriteTextLayout, layout));
    // Lines of different heights (a font on some only): each drawn moved
    // to where its own extent puts it (lineShift).
    var ext_buf: [64]Extent = undefined;
    var glyph_buf: [64]Extent = undefined;
    const exts = lineExtents(&n.props, layout, &ext_buf, &glyph_buf);
    const all = textExtent(&n.props);
    const shift = struct {
        fn at(e: ?[]const Extent, a: ?Extent, y0: f32, top: f32) f32 {
            const xs = e orelse return 0;
            const ae = a orelse return 0;
            const h = ae.top + ae.bottom;
            if (!(h > 0)) return 0;
            const k: usize = @intFromFloat(@max(0, @min(@as(f32, @floatFromInt(xs.len - 1)), @round((top - y0) / h))));
            return lineShift(xs, ae, k);
        }
    }.at;
    // Inline boxes (a padded <code> chip), behind the text.
    if (n.props.runs) |runs| paintInlineBoxes(p, &n.props, layout, runs, ct.x, ct.y, .{ .exts = exts, .all = all, .box = null });
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
                const dy = shift(exts, all, ct.y, m.top);
                const rc: c.D2D1_RECT_F = .{ .left = m.left, .top = m.top + dy, .right = m.left + m.width, .bottom = m.top + m.height + dy };
                p.vt().FillRectangle.?(p.rt, &rc, p.solid(bg));
            }
        }
    }
    // Runs without a color of their own (none: each run sets one) use black.
    const origin: c.D2D1_POINT_2F = .{ .x = ct.x, .y = ct.y };
    if (exts) |xs| {
        const h = all.?.top + all.?.bottom;
        // Each copy shows its own line's glyphs: cut, in the layout, midway
        // between a line's glyphs and the next one's (a big font on a
        // tight line-height overflows its line box, as in browsers).
        const gs = glyph_buf[0..xs.len];
        const cut = struct {
            fn at(g: []const Extent, a: Extent, lh: f32, k: usize) f32 {
                const base = @as(f32, @floatFromInt(k)) * lh + a.top;
                return (base + g[k].bottom + base + lh - g[k + 1].top) / 2;
            }
        }.at;
        for (0..xs.len) |k| {
            const dy = lineShift(xs, all.?, k);
            const above: f32 = if (k == 0) -1e4 else cut(gs, all.?, h, k - 1);
            const below: f32 = if (k + 1 == xs.len) 1e4 else cut(gs, all.?, h, k);
            const band: c.D2D1_RECT_F = .{ .left = ct.x - 1e4, .top = ct.y + above + dy, .right = ct.x + ct.w + 1e4, .bottom = ct.y + below + dy };
            p.vt().PushAxisAlignedClip.?(p.rt, &band, c.D2D1_ANTIALIAS_MODE_ALIASED);
            p.vt().DrawTextLayout.?(p.rt, .{ .x = ct.x, .y = ct.y + dy }, layout, p.solid(.{ 0, 0, 0, 1 }), draw_text_color_font);
            p.vt().PopAxisAlignedClip.?(p.rt);
        }
    } else p.vt().DrawTextLayout.?(p.rt, origin, layout, p.solid(.{ 0, 0, 0, 1 }), draw_text_color_font);
    // A focused inline link's ring (or an inline element's outline),
    // around each of its line fragments: its runs (a <b> in it) together.
    if (n.props.runs) |runs| {
        var pos: u32 = 0;
        var i: usize = 0;
        while (i < runs.len) : (i += 1) {
            const start = pos;
            pos += @intCast(std.unicode.calcUtf16LeLen(runs[i].t) catch runs[i].t.len);
            const ol = runs[i].ol orelse continue;
            // Its boxes' content area: the runs' fonts' ascent and descent.
            var box: ?Extent = contentExtent(runFamily(&n.props, runs[i]), runs[i].sz, runs[i].w, runs[i].i);
            while (i + 1 < runs.len and runs[i + 1].ol != null and std.meta.eql(runs[i + 1].ol.?, ol)) : (i += 1) {
                pos += @intCast(std.unicode.calcUtf16LeLen(runs[i + 1].t) catch runs[i + 1].t.len);
                box = widen(box, contentExtent(runFamily(&n.props, runs[i + 1]), runs[i + 1].sz, runs[i + 1].w, runs[i + 1].i));
            }
            runRing(p, layout, runs, ct.x, ct.y, start, pos, ol, .{ .exts = exts, .all = all, .box = box });
        }
    }
}

/// An outline around the text from UTF-16 position `start` to `end` of a
/// layout drawn at (x, y): a box per line it's on (the spaces where a line
/// wraps left out, as tall as that line, its sides on whole pixels), and
/// around them one outline, as Chromium draws a wrapped link's ring.
/// Where its lines are (paintText): each line's extent when they differ,
/// all of them together, and the ring's runs' content area (ascent and
/// descent: the box's height, as Chromium draws an inline box's ring).
const RingLines = struct { exts: ?[]const Extent, all: ?Extent, box: ?Extent };

fn runRing(p: *Painter, layout: *c.IDWriteTextLayout, runs: []const tree_mod.Run, x: f32, y: f32, start: u32, end: u32, ol: tree_mod.Outline, at: RingLines) void {
    var lines_buf: [64]c.DWRITE_LINE_METRICS = undefined;
    var count: u32 = 0;
    if (layout.lpVtbl.*.GetLineMetrics.?(layout, &lines_buf, lines_buf.len, &count) < 0 and count > lines_buf.len) return;
    var boxes: [64]Rect = undefined;
    var nb: usize = 0;
    var ls: u32 = 0;
    for (lines_buf[0..@min(count, lines_buf.len)], 0..) |line, k| {
        defer ls += line.length;
        var a = @max(start, ls);
        var b = @min(end, ls + line.length);
        while (a < b and isSpaceAt(runs, a)) a += 1;
        while (b > a and (isSpaceAt(runs, b - 1) or unitAt(runs, b - 1) == 0x0A or unitAt(runs, b - 1) == 0x0D)) b -= 1;
        if (a >= b) continue;
        var rects: [16]c.DWRITE_HIT_TEST_METRICS = undefined;
        var n: u32 = 0;
        if (layout.lpVtbl.*.HitTestTextRange.?(layout, a, b - a, x, y, &rects, rects.len, &n) < 0) continue;
        // One box over the pieces (they split where the style does).
        var x0: f32 = std.math.floatMax(f32);
        var x1: f32 = -std.math.floatMax(f32);
        var top: f32 = std.math.floatMax(f32);
        var bottom: f32 = -std.math.floatMax(f32);
        for (rects[0..@min(n, rects.len)]) |m| {
            x0 = @min(x0, m.left);
            x1 = @max(x1, m.left + m.width);
            top = @min(top, m.top);
            bottom = @max(bottom, m.top + m.height);
        }
        x0 = @round(x0);
        x1 = @round(x1);
        // Its height: the content area around the line's baseline.
        if (at.all) |all| if (at.box) |cb| {
            const h = all.top + all.bottom;
            const dy = if (at.exts) |xs| (if (k < xs.len) lineShift(xs, all, k) else 0) else 0;
            const base = y + @as(f32, @floatFromInt(k)) * h + all.top + dy;
            top = base - cb.top;
            bottom = base + cb.bottom;
        };
        if (x1 > x0 and bottom > top and nb < boxes.len) {
            boxes[nb] = .{ .x = x0, .y = top, .w = x1 - x0, .h = bottom - top };
            nb += 1;
        }
    }
    if (nb == 0) return;
    if (nb == 1 or ol.s != null) {
        // One line (or dashes, which go per box): the box's own outline.
        for (boxes[0..nb]) |b| paintOutline(p, b, .{}, ol);
        return;
    }
    // The ring: the boxes grown by offset + width, less them grown by the
    // offset; the halo 1px around that.
    const outer = boxesUnion(boxes[0..nb], ol.o + ol.w, ol.r) orelse return;
    defer releaseCom(@as(?*c.ID2D1PathGeometry, outer));
    const inner = boxesUnion(boxes[0..nb], ol.o, @max(0, ol.r - ol.w)) orelse return;
    defer releaseCom(@as(?*c.ID2D1PathGeometry, inner));
    const vt = p.vt();
    if (ol.h) |h| if (h[3] > 0) if (boxesUnion(boxes[0..nb], ol.o + ol.w + 1, ol.r + 1)) |halo| {
        defer releaseCom(@as(?*c.ID2D1PathGeometry, halo));
        if (combineGeometry(@ptrCast(halo), @ptrCast(outer), c.D2D1_COMBINE_MODE_EXCLUDE)) |edge| {
            defer releaseCom(@as(?*c.ID2D1PathGeometry, edge));
            vt.FillGeometry.?(p.rt, @ptrCast(edge), p.solid(h), null);
        }
    };
    if (combineGeometry(@ptrCast(outer), @ptrCast(inner), c.D2D1_COMBINE_MODE_EXCLUDE)) |ring| {
        defer releaseCom(@as(?*c.ID2D1PathGeometry, ring));
        vt.FillGeometry.?(p.rt, @ptrCast(ring), p.solid(ol.c), null);
    }
}

/// The boxes, each grown by `grow` with corners `r` round, as one shape
/// (caller releases).
fn boxesUnion(boxes: []const Rect, grow: f32, r: f32) ?*c.ID2D1PathGeometry {
    var acc: ?*c.ID2D1PathGeometry = null;
    for (boxes) |b| {
        const g: Rect = .{ .x = b.x - grow, .y = b.y - grow, .w = b.w + 2 * grow, .h = b.h + 2 * grow };
        if (g.w <= 0 or g.h <= 0) continue;
        const one = roundRectGeometry(g, Radii.circle(.{ r, r, r, r })) orelse continue;
        if (acc) |a| {
            defer releaseCom(@as(?*c.ID2D1PathGeometry, a));
            defer releaseCom(@as(?*c.ID2D1PathGeometry, one));
            acc = combineGeometry(@ptrCast(a), @ptrCast(one), c.D2D1_COMBINE_MODE_UNION);
        } else acc = one;
    }
    return acc;
}

/// a and b combined (union, exclude...) as a new geometry (caller
/// releases).
fn combineGeometry(a: *c.ID2D1Geometry, b: *c.ID2D1Geometry, mode: c.D2D1_COMBINE_MODE) ?*c.ID2D1PathGeometry {
    const fac = d2d.?;
    var geo: ?*c.ID2D1PathGeometry = null;
    if (fac.lpVtbl.*.CreatePathGeometry.?(fac, &geo) < 0 or geo == null) return null;
    var sink: ?*c.ID2D1GeometrySink = null;
    if (geo.?.lpVtbl.*.Open.?(geo, &sink) < 0 or sink == null) {
        releaseCom(geo);
        return null;
    }
    defer releaseCom(sink);
    const ok = a.lpVtbl.*.CombineWithGeometry.?(a, b, mode, null, 0.25, @ptrCast(sink)) >= 0;
    const sk: *c.ID2D1SimplifiedGeometrySink = @ptrCast(sink.?);
    if (sk.lpVtbl.*.Close.?(sk) < 0 or !ok) {
        releaseCom(geo);
        return null;
    }
    return geo;
}

/// The UTF-16 unit at `at` of the runs' text (0 past it).
fn unitAt(runs: []const tree_mod.Run, at: u32) u16 {
    var pos: u32 = 0;
    for (runs) |r| {
        var it = std.unicode.Utf8View.initUnchecked(r.t).iterator();
        while (it.nextCodepoint()) |cp| {
            const units: u32 = if (cp >= 0x10000) 2 else 1;
            if (at < pos + units) return if (units == 1) @intCast(cp) else 0xD800;
            pos += units;
        }
    }
    return 0;
}

fn isSpaceAt(runs: []const tree_mod.Run, at: u32) bool {
    const u = unitAt(runs, at);
    return u == ' ' or u == 0xA0 or u == 0x09;
}

/// Each inline box's run group (docs/native-renderer.md, "Inline boxes"):
/// its runs' UTF-16 range and its decoration. Consecutive runs with the
/// same box (`k`) are one.
const BoxSpan = struct { start: u32, end: u32, first_run: usize, last_run: usize, ib: tree_mod.InlineBox };

fn inlineBoxSpans(runs: []const tree_mod.Run, out: []BoxSpan) []BoxSpan {
    var k: usize = 0;
    var start: u32 = 0;
    var i: usize = 0;
    while (i < runs.len) : (i += 1) {
        const len: u32 = @intCast(std.unicode.calcUtf16LeLen(runs[i].t) catch runs[i].t.len);
        const ib = runs[i].ib orelse {
            start += len;
            continue;
        };
        const first = i;
        var end = start + len;
        while (i + 1 < runs.len and runs[i + 1].ib != null and runs[i + 1].ib.?.k == ib.k) : (i += 1)
            end += @intCast(std.unicode.calcUtf16LeLen(runs[i + 1].t) catch runs[i + 1].t.len);
        if (end > start and k < out.len) {
            out[k] = .{ .start = start, .end = end, .first_run = first, .last_run = i, .ib = ib };
            k += 1;
        }
        start = end;
    }
    return out[0..k];
}

/// The inline boxes' room in the line: their start side (margin, border,
/// padding) as leading spacing on their first character, their end side
/// as trailing spacing on their last (IDWriteTextLayout1, with the
/// letter-spacing `ls` every character has; without it, none).
fn inlineBoxRoom(l: *c.IDWriteTextLayout, runs: []const tree_mod.Run, ls: f32) void {
    var spans_buf: [64]BoxSpan = undefined;
    const spans = inlineBoxSpans(runs, &spans_buf);
    if (spans.len == 0) return;
    var l1: ?*c.IDWriteTextLayout1 = null;
    if (l.lpVtbl.*.QueryInterface.?(l, &iid_text_layout1, @ptrCast(&l1)) < 0) return;
    const x = l1 orelse return;
    defer releaseCom(@as(?*c.IDWriteTextLayout1, x));
    // Per character (a code point: a surrogate pair's two units): the
    // room before it and after it.
    const Edge = struct { at: u32, len: u32, lead: f32 = 0, trail: f32 = 0 };
    var edges: [128]Edge = undefined;
    var m: usize = 0;
    const slot = struct {
        fn f(e: []Edge, cnt: *usize, at: u32, len: u32) ?*Edge {
            for (e[0..cnt.*]) |*q| if (q.at == at) return q;
            if (cnt.* >= e.len) return null;
            e[cnt.*] = .{ .at = at, .len = len };
            cnt.* += 1;
            return &e[cnt.* - 1];
        }
    }.f;
    for (spans) |sp| {
        const head_len: u32 = if (unitAt(runs, sp.start) == 0xD800 and sp.end - sp.start >= 2) 2 else 1;
        if (slot(&edges, &m, sp.start, head_len)) |e| e.lead += sp.ib.start();
        const tail_len: u32 = if (unitAt(runs, sp.end - 1) == 0xD800 and sp.end - sp.start >= 2) 2 else 1;
        if (slot(&edges, &m, sp.end - tail_len, tail_len)) |e| e.trail += sp.ib.end();
    }
    for (edges[0..m]) |e| {
        if (!(e.lead > 0) and !(e.trail > 0)) continue;
        _ = x.lpVtbl.*.SetCharacterSpacing.?(x, e.lead, ls + e.trail, 0, .{ .startPosition = e.at, .length = e.len });
    }
}

/// The inline boxes' decoration (render.js inlineBox) over each line
/// fragment, under the text: as Chromium slices it, the start side (its
/// border, padding and corners) on the box's first fragment and the end
/// side on its last; as tall as its fonts' content area plus the vertical
/// padding and border (which take no room in the line).
fn paintInlineBoxes(p: *Painter, props: *const tree_mod.Props, layout: *c.IDWriteTextLayout, runs: []const tree_mod.Run, x: f32, y: f32, at: RingLines) void {
    var spans_buf: [64]BoxSpan = undefined;
    const spans = inlineBoxSpans(runs, &spans_buf);
    if (spans.len == 0) return;
    var lines_buf: [64]c.DWRITE_LINE_METRICS = undefined;
    var count: u32 = 0;
    if (layout.lpVtbl.*.GetLineMetrics.?(layout, &lines_buf, lines_buf.len, &count) < 0 or count > lines_buf.len) return;
    for (spans) |sp| {
        const ib = sp.ib;
        const bw = ib.bw orelse [4]f32{ 0, 0, 0, 0 };
        // Its content area: its runs' fonts' ascent and descent.
        var cb: ?Extent = null;
        for (runs[sp.first_run .. sp.last_run + 1]) |r| cb = widen(cb, contentExtent(runFamily(props, r), r.sz, r.w, r.i));
        var ls: u32 = 0;
        for (lines_buf[0..count], 0..) |line, k| {
            defer ls += line.length;
            const a = @max(sp.start, ls);
            var b = @min(sp.end, ls + line.length);
            if (a >= b) continue;
            const first = a == sp.start;
            const last = b == sp.end;
            // A fragment that wraps: up to the end of the line's text, not
            // over the space it wraps after.
            if (!last) while (b > a and (isSpaceAt(runs, b - 1) or unitAt(runs, b - 1) == 0x0A or unitAt(runs, b - 1) == 0x0D)) {
                b -= 1;
            };
            if (a >= b) continue;
            var rects: [16]c.DWRITE_HIT_TEST_METRICS = undefined;
            var n: u32 = 0;
            if (layout.lpVtbl.*.HitTestTextRange.?(layout, a, b - a, x, y, &rects, rects.len, &n) < 0) continue;
            var x0: f32 = std.math.floatMax(f32);
            var x1: f32 = -std.math.floatMax(f32);
            for (rects[0..@min(n, rects.len)]) |hm| {
                x0 = @min(x0, hm.left);
                x1 = @max(x1, hm.left + hm.width);
            }
            // The room's margins are outside the box.
            if (first) x0 += ib.m[3];
            if (last) x1 -= ib.m[1];
            if (!(x1 > x0)) continue;
            // Around the line's baseline (runRing's).
            const all = at.all orelse continue;
            const ce = cb orelse all;
            const h = all.top + all.bottom;
            const dy = if (at.exts) |xs| (if (k < xs.len) lineShift(xs, all, k) else 0) else 0;
            const base = y + @as(f32, @floatFromInt(k)) * h + all.top + dy;
            // On whole pixels, as Chromium snaps it.
            const top = @round(base - ce.top - ib.p[0] - bw[0]);
            const bottom = @round(base + ce.bottom + ib.p[2] + bw[2]);
            x0 = @round(x0);
            x1 = @round(x1);
            if (!(x1 > x0)) continue;
            const box: Rect = .{ .x = x0, .y = top, .w = x1 - x0, .h = bottom - top };
            var radii: Radii = .{};
            if (ib.br) |r| {
                const keep = [4]bool{ first, last, last, first };
                for (0..4) |q| if (keep[q]) {
                    radii.x[q] = r[q];
                    radii.y[q] = r[q];
                };
                radii = radii.fitted(box.w, box.h);
            }
            if (ib.bg) |bg| if (bg[3] > 0) fillShape(p, box, radii, p.solid(bg));
            if (ib.bw != null) {
                const sides = [4]f32{ bw[0], if (last) bw[1] else 0, bw[2], if (first) bw[3] else 0 };
                border(p, box, radii, sides, .{ ib.bc, ib.bc, ib.bc, ib.bc }, null);
            }
        }
    }
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

// ---------------------------------------------------------------------------
// Drag and drop (docs/drag-and-drop-design.md, sections 1 and 5): drops
// into the page through OLE. The canvas registers an IDropTarget; the page
// answers each enter and over with an effect mask (Engine.dragEvent), which
// OLE gets as one DROPEFFECT (the same bits: copy 1, move 2, link 4). A
// drop's data is there at once: Drop opens the files into the engine's
// table (drop.zig), sends "drop", and returns the page's own answer.

/// At most this many items in a drop, and this long a string (larger
/// ones are left out and logged).
const drag_max_items = 4096;
const drag_max_string = 16 * 1024 * 1024;

const POINTL = extern struct { x: i32, y: i32 };
const FORMATETC = extern struct { cfFormat: u16, ptd: ?*anyopaque = null, dwAspect: u32 = 1, lindex: i32 = -1, tymed: u32 = 1 };
const STGMEDIUM = extern struct { tymed: u32, data: ?*anyopaque, release: ?*anyopaque };
const HRESULT = c_long;
const S_OK: HRESULT = 0;
const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
const CF_UNICODETEXT: u16 = 13;
const CF_HDROP: u16 = 15;
const MK_SHIFT: u32 = 0x4;
const MK_CONTROL: u32 = 0x8;
const MK_ALT: u32 = 0x20;

/// IDataObject: only what a drop reads (GetData, QueryGetData).
const IDataObject = extern struct {
    vtbl: *const extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const anyopaque,
        GetData: *const fn (*IDataObject, *const FORMATETC, *STGMEDIUM) callconv(.winapi) HRESULT,
        GetDataHere: *const anyopaque,
        QueryGetData: *const fn (*IDataObject, *const FORMATETC) callconv(.winapi) HRESULT,
    },

    fn has(d: *IDataObject, format: u16) bool {
        if (format == 0) return false;
        const f: FORMATETC = .{ .cfFormat = format };
        return d.vtbl.QueryGetData(d, &f) == S_OK;
    }

    /// The format's HGLOBAL (ReleaseStgMedium when done).
    fn global(d: *IDataObject, format: u16) ?STGMEDIUM {
        if (format == 0) return null;
        const f: FORMATETC = .{ .cfFormat = format };
        var m: STGMEDIUM = undefined;
        if (d.vtbl.GetData(d, &f, &m) != S_OK) return null;
        if (m.tymed != 1 or m.data == null) {
            ReleaseStgMedium(&m);
            return null;
        }
        return m;
    }
};

/// The shell's drag image over the window while a drag from Explorer is
/// in it (CLSID_DragDropHelper).
const IDropTargetHelper = extern struct {
    vtbl: *const extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IDropTargetHelper) callconv(.winapi) u32,
        DragEnter: *const fn (*IDropTargetHelper, c.HWND, *IDataObject, *c.POINT, u32) callconv(.winapi) HRESULT,
        DragLeave: *const fn (*IDropTargetHelper) callconv(.winapi) HRESULT,
        DragOver: *const fn (*IDropTargetHelper, *c.POINT, u32) callconv(.winapi) HRESULT,
        Drop: *const fn (*IDropTargetHelper, *IDataObject, *c.POINT, u32) callconv(.winapi) HRESULT,
    },
};

extern "ole32" fn OleInitialize(reserved: ?*anyopaque) callconv(.winapi) HRESULT;
extern "ole32" fn RegisterDragDrop(hwnd: c.HWND, target: *DropTarget) callconv(.winapi) HRESULT;
extern "ole32" fn RevokeDragDrop(hwnd: c.HWND) callconv(.winapi) HRESULT;
extern "ole32" fn ReleaseStgMedium(m: *STGMEDIUM) callconv(.winapi) void;
extern "shell32" fn DragQueryFileW(drop: ?*anyopaque, index: u32, file: ?[*]u16, len: u32) callconv(.winapi) u32;

const iid_unknown: c.GUID = .{ .Data1 = 0x00000000, .Data2 = 0x0000, .Data3 = 0x0000, .Data4 = .{ 0xC0, 0, 0, 0, 0, 0, 0, 0x46 } };
const iid_drop_target: c.GUID = .{ .Data1 = 0x00000122, .Data2 = 0x0000, .Data3 = 0x0000, .Data4 = .{ 0xC0, 0, 0, 0, 0, 0, 0, 0x46 } };
const clsid_drag_drop_helper: c.GUID = .{ .Data1 = 0x4657278A, .Data2 = 0x411B, .Data3 = 0x11D2, .Data4 = .{ 0x83, 0x9A, 0x00, 0xC0, 0x4F, 0xD9, 0x18, 0xD0 } };
const iid_drop_target_helper: c.GUID = .{ .Data1 = 0x4657278B, .Data2 = 0x411B, .Data3 = 0x11D2, .Data4 = .{ 0x83, 0x9A, 0x00, 0xC0, 0x4F, 0xD9, 0x18, 0xD0 } };

/// The registered clipboard formats a drag can carry (0 until known).
var cf_url: u16 = 0; // UniformResourceLocatorW
var cf_html: u16 = 0; // HTML Format
var ole_ready: ?bool = null;

/// The canvas's IDropTarget: a COM object OLE holds (RegisterDragDrop
/// adds a reference, RevokeDragDrop drops it). It keeps only the canvas
/// window: the surface is looked up on each call, so a page that closes
/// its window during a drag leaves nothing dangling.
const DropTarget = extern struct {
    vtbl: *const Vtbl,
    refs: u32,
    hwnd: c.HWND,
    helper: ?*IDropTargetHelper,

    const Vtbl = extern struct {
        QueryInterface: *const fn (*DropTarget, *const c.GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*DropTarget) callconv(.winapi) u32,
        Release: *const fn (*DropTarget) callconv(.winapi) u32,
        DragEnter: *const fn (*DropTarget, *IDataObject, u32, POINTL, *u32) callconv(.winapi) HRESULT,
        DragOver: *const fn (*DropTarget, u32, POINTL, *u32) callconv(.winapi) HRESULT,
        DragLeave: *const fn (*DropTarget) callconv(.winapi) HRESULT,
        Drop: *const fn (*DropTarget, *IDataObject, u32, POINTL, *u32) callconv(.winapi) HRESULT,
    };

    const vtbl_impl: Vtbl = .{
        .QueryInterface = queryInterface,
        .AddRef = addRefTarget,
        .Release = release,
        .DragEnter = dragEnter,
        .DragOver = dragOver,
        .DragLeave = dragLeave,
        .Drop = drop,
    };

    fn queryInterface(t: *DropTarget, iid: *const c.GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        if (std.mem.eql(u8, std.mem.asBytes(iid), std.mem.asBytes(&iid_unknown)) or std.mem.eql(u8, std.mem.asBytes(iid), std.mem.asBytes(&iid_drop_target))) {
            out.* = t;
            _ = addRefTarget(t);
            return S_OK;
        }
        out.* = null;
        return E_NOINTERFACE;
    }

    fn addRefTarget(t: *DropTarget) callconv(.winapi) u32 {
        t.refs += 1;
        return t.refs;
    }

    fn release(t: *DropTarget) callconv(.winapi) u32 {
        t.refs -= 1;
        const left = t.refs;
        if (left == 0) {
            if (t.helper) |h| _ = h.vtbl.Release(h);
            std.heap.page_allocator.destroy(t);
        }
        return left;
    }

    fn dragEnter(t: *DropTarget, data: *IDataObject, keys: u32, pt: POINTL, effect: *u32) callconv(.winapi) HRESULT {
        const allowed = effect.*;
        const s = liveSurface(t.hwnd);
        if (s) |ls| {
            ls.drag_session +%= 1;
            ls.drag_inside = true;
            ls.drag_kinds = DragKinds.of(data);
        }
        effect.* = if (s) |ls| dragAnswer(ls, true, keys, pt, allowed) else 0;
        var sp: c.POINT = .{ .x = pt.x, .y = pt.y };
        if (t.helper) |h| _ = h.vtbl.DragEnter(h, t.hwnd, data, &sp, effect.*);
        return S_OK;
    }

    fn dragOver(t: *DropTarget, keys: u32, pt: POINTL, effect: *u32) callconv(.winapi) HRESULT {
        const allowed = effect.*;
        const s = liveSurface(t.hwnd);
        effect.* = if (s) |ls| (if (ls.drag_inside) dragAnswer(ls, false, keys, pt, allowed) else 0) else 0;
        var sp: c.POINT = .{ .x = pt.x, .y = pt.y };
        if (t.helper) |h| _ = h.vtbl.DragOver(h, &sp, effect.*);
        return S_OK;
    }

    fn dragLeave(t: *DropTarget) callconv(.winapi) HRESULT {
        if (t.helper) |h| _ = h.vtbl.DragLeave(h);
        const s = liveSurface(t.hwnd) orelse return S_OK;
        if (!s.drag_inside) return S_OK;
        s.drag_inside = false;
        s.drag_effect = 0;
        sendDragLeave(s, s.drag_session);
        return S_OK;
    }

    fn drop(t: *DropTarget, data: *IDataObject, keys: u32, pt: POINTL, effect: *u32) callconv(.winapi) HRESULT {
        const allowed = effect.* & 7;
        effect.* = dropInto(t.hwnd, data, keys, pt, allowed);
        var sp: c.POINT = .{ .x = pt.x, .y = pt.y };
        if (t.helper) |h| _ = h.vtbl.Drop(h, data, &sp, effect.*);
        return S_OK;
    }
};

/// OLE on this (the UI) thread, once, and the canvas's drop target. Null
/// when OLE can't be had (no drops into the page then).
fn registerDropTarget(hwnd: c.HWND) ?*DropTarget {
    if (ole_ready == null) {
        const hr = OleInitialize(null);
        ole_ready = hr >= 0;
        if (hr < 0) log.warn("native ui: OleInitialize failed (0x{x}): no drops", .{@as(u32, @bitCast(hr))});
        cf_url = @truncate(c.RegisterClipboardFormatW(std.unicode.utf8ToUtf16LeStringLiteral("UniformResourceLocatorW")));
        cf_html = @truncate(c.RegisterClipboardFormatW(std.unicode.utf8ToUtf16LeStringLiteral("HTML Format")));
    }
    if (ole_ready != true) return null;
    const t = std.heap.page_allocator.create(DropTarget) catch return null;
    t.* = .{ .vtbl = &DropTarget.vtbl_impl, .refs = 1, .hwnd = hwnd, .helper = null };
    var helper: ?*IDropTargetHelper = null;
    if (c.CoCreateInstance(&clsid_drag_drop_helper, null, c.CLSCTX_INPROC_SERVER, &iid_drop_target_helper, @ptrCast(&helper)) >= 0) t.helper = helper;
    const hr = RegisterDragDrop(hwnd, t);
    // OLE holds it from here (or no one does): ours goes.
    _ = DropTarget.release(t);
    if (hr < 0) {
        log.warn("native ui: RegisterDragDrop failed (0x{x})", .{@as(u32, @bitCast(hr))});
        return null;
    }
    return t;
}

/// What a drag carries, as the page's DataTransfer types.
const DragKinds = struct {
    files: bool = false,
    plain: bool = false,
    uri_list: bool = false,
    html: bool = false,

    fn of(d: *IDataObject) DragKinds {
        return .{
            .files = d.has(CF_HDROP),
            .plain = d.has(CF_UNICODETEXT),
            .uri_list = d.has(cf_url),
            .html = d.has(cf_html),
        };
    }

    /// The strings the page sees: none with files, as in Chrome (Explorer
    /// offers the files' paths as text beside them).
    fn strings(k: DragKinds) [3]?[]const u8 {
        if (k.files) return .{ null, null, null };
        return .{
            if (k.plain) "text/plain" else null,
            if (k.uri_list) "text/uri-list" else null,
            if (k.html) "text/html" else null,
        };
    }

    /// enter's items: [[kind, type], ...].
    fn writeItems(k: DragKinds, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try out.append(gpa, '[');
        var first = true;
        if (k.files) {
            try out.appendSlice(gpa, "[\"file\",\"\"]");
            first = false;
        }
        for (k.strings()) |mime| if (mime) |m| {
            if (!first) try out.append(gpa, ',');
            first = false;
            try out.print(gpa, "[\"string\",\"{s}\"]", .{m});
        };
        try out.append(gpa, ']');
    }
};

/// grfKeyState as the pointer flags (shift 1, ctrl 2, alt 4).
fn dragMods(keys: u32) u32 {
    var m: u32 = 0;
    if (keys & MK_SHIFT != 0) m |= 1;
    if (keys & MK_CONTROL != 0) m |= 2;
    if (keys & MK_ALT != 0) m |= 4;
    return m;
}

/// The operation the keys ask for, as Explorer reads them (Ctrl copy,
/// Shift move, both a link), else the first the source allows.
fn suggestedEffect(allowed: u32, mods: u32) u32 {
    if (allowed == 0) return 0;
    if (std.math.isPowerOfTwo(allowed)) return allowed;
    const ctrl = mods & 2 != 0;
    const shift = mods & 1 != 0;
    const wanted: u32 = if (ctrl and shift) 4 else if (ctrl) 1 else if (shift) 2 else 0;
    if (wanted & allowed != 0) return wanted;
    return firstEffect(allowed);
}

fn firstEffect(mask: u32) u32 {
    inline for (.{ 1, 2, 4 }) |a| if (mask & a != 0) return a;
    return 0;
}

/// The page's mask as the one effect OLE is told: the suggested one if
/// the page allows it, else its first (0: no drop here).
fn pickEffect(mask: u32, allowed: u32, suggested: u32) u32 {
    const m = mask & allowed;
    if (m & suggested != 0) return suggested;
    return firstEffect(m);
}

/// A screen point as the page's (CSS px in the canvas).
fn dragPoint(s: *Surface, pt: POINTL) [2]f32 {
    var p: c.POINT = .{ .x = pt.x, .y = pt.y };
    _ = c.ScreenToClient(s.hwnd, &p);
    return .{ @as(f32, @floatFromInt(p.x)) / s.scale, @as(f32, @floatFromInt(p.y)) / s.scale };
}

/// "enter" or "over" on the node under the pointer: the effect for OLE.
fn dragAnswer(s: *Surface, enter: bool, keys: u32, pt: POINTL, allowed_in: u32) u32 {
    const hwnd = s.hwnd;
    const allowed = allowed_in & 7;
    const mods = dragMods(keys);
    const suggested = suggestedEffect(allowed, mods);
    const p = dragPoint(s, pt);
    // Not s.gpa in the defer: the page may close its window inside.
    const gpa = s.gpa;
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(gpa);
    json.print(gpa, "[\"{s}\",{d:.2},{d:.2},{d},{d},{d},{d}", .{ if (enter) "enter" else "over", p[0], p[1], allowed, suggested, mods, s.drag_session }) catch return 0;
    if (enter) {
        json.append(gpa, ',') catch return 0;
        s.drag_kinds.writeItems(gpa, &json) catch return 0;
    }
    json.append(gpa, ']') catch return 0;
    const mask = s.engine.dragEvent(targetAt(s, p), json.items);
    const ls = liveSurface(hwnd) orelse return 0; // the page closed its window
    ls.drag_effect = pickEffect(mask, allowed, suggested);
    return ls.drag_effect;
}

fn sendDragLeave(s: *Surface, session: u32) void {
    var buf: [32]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "[\"leave\",{d}]", .{session}) catch return;
    _ = s.engine.dragEvent(0, json);
}

/// The drop: its files opened into the engine's table, or its strings,
/// sent to the page as "drop"; the page's answer as OLE's effect.
fn dropInto(hwnd: c.HWND, data: *IDataObject, keys: u32, pt: POINTL, allowed: u32) u32 {
    const s = liveSurface(hwnd) orelse return 0;
    if (!s.drag_inside) return 0;
    s.drag_inside = false;
    const last = s.drag_effect;
    s.drag_effect = 0;
    const session = s.drag_session;
    // The page took no drop here: the drag just leaves.
    if (last == 0) {
        sendDragLeave(s, session);
        return 0;
    }
    const mods = dragMods(keys);
    const suggested = suggestedEffect(allowed, mods);
    const p = dragPoint(s, pt);
    const gpa = s.gpa;
    var items: DropItems = .{ .gpa = gpa };
    defer items.deinit();
    if (s.drag_kinds.files) dropFiles(s, data, &items) else dropStrings(s.drag_kinds, data, &items);
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(gpa);
    json.print(gpa, "[\"drop\",{d:.2},{d:.2},{d},{d},{d},{d},[{s}]]", .{ p[0], p[1], allowed, suggested, mods, session, items.json.items }) catch {
        items.releaseAll(s);
        sendDragLeave(s, session);
        return 0;
    };
    const mask = s.engine.dragEvent(targetAt(s, p), json.items);
    if (liveSurface(hwnd) == null) return 0;
    return pickEffect(mask, allowed, suggested);
}

/// A drop's items' JSON (comma-separated) and the handles in it.
const DropItems = struct {
    gpa: std.mem.Allocator,
    json: std.ArrayList(u8) = .empty,
    count: usize = 0,
    handles: std.ArrayList(u32) = .empty,

    fn deinit(d: *DropItems) void {
        d.json.deinit(d.gpa);
        d.handles.deinit(d.gpa);
    }

    /// Room for one more item (a comma before it).
    fn start(d: *DropItems) !bool {
        if (d.count >= drag_max_items) {
            if (d.count == drag_max_items) log.warn("native ui: a drop of more than {d} items: the rest left out", .{drag_max_items});
            d.count = drag_max_items + 1;
            return false;
        }
        if (d.count > 0) try d.json.append(d.gpa, ',');
        d.count += 1;
        return true;
    }

    /// The JSON couldn't be sent: its files are let go.
    fn releaseAll(d: *DropItems, s: *Surface) void {
        for (d.handles.items) |h| s.engine.drops.release(h);
    }

    fn string(d: *DropItems, value: []const u8) !void {
        const quoted = try std.json.Stringify.valueAlloc(d.gpa, value, .{});
        defer d.gpa.free(quoted);
        try d.json.appendSlice(d.gpa, quoted);
    }
};

/// Each file of the CF_HDROP opened into the engine's table (regular
/// files only): ["file", mime, name, size, lastModifiedMs, handle]. Only
/// the name reaches the page, never the path.
fn dropFiles(s: *Surface, data: *IDataObject, items: *DropItems) void {
    var m = data.global(CF_HDROP) orelse return;
    defer ReleaseStgMedium(&m);
    const hdrop = m.data;
    const n = DragQueryFileW(hdrop, 0xFFFFFFFF, null, 0);
    var i: u32 = 0;
    while (i < n and items.count <= drag_max_items) : (i += 1) {
        const len = DragQueryFileW(hdrop, i, null, 0);
        if (len == 0) continue;
        const wide = s.gpa.alloc(u16, len + 1) catch continue;
        defer s.gpa.free(wide);
        if (DragQueryFileW(hdrop, i, wide.ptr, len + 1) != len) continue;
        const path = std.unicode.utf16LeToUtf8AllocZ(s.gpa, wide[0..len]) catch continue;
        defer s.gpa.free(path);
        const handle = (s.engine.drops.addPath(path) catch |err| {
            log.warn("native ui: a dropped file: {s}", .{@errorName(err)});
            continue;
        }) orelse continue; // not a regular file (a folder)
        const info = s.engine.drops.info(handle).?;
        const name = std.fs.path.basenameWindows(path);
        const added = fileItem(items, name, info, handle) catch false;
        if (added) items.handles.append(items.gpa, handle) catch {} else s.engine.drops.release(handle);
    }
}

fn fileItem(items: *DropItems, name: []const u8, info: engine_mod.drop.Entry, handle: u32) !bool {
    if (!try items.start()) return false;
    try items.json.appendSlice(items.gpa, "[\"file\",");
    var mime_buf: [128]u8 = undefined;
    try items.string(mimeOf(name, &mime_buf));
    try items.json.append(items.gpa, ',');
    try items.string(name);
    try items.json.print(items.gpa, ",{d},{d},{d}]", .{ info.size, info.mtimeMs(), handle });
    return true;
}

/// A file's MIME type from its extension, as Chromium gives File.type on
/// Windows: its own table for the common ones, then the registry's
/// (HKCR\.ext "Content Type"); "" when unknown.
fn mimeOf(name: []const u8, buf: []u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    if (dot == 0 or dot + 1 == name.len) return "";
    const ext = name[dot + 1 ..];
    const known = [_][2][]const u8{
        .{ "html", "text/html" },      .{ "htm", "text/html" },          .{ "css", "text/css" },
        .{ "js", "text/javascript" },  .{ "mjs", "text/javascript" },    .{ "json", "application/json" },
        .{ "txt", "text/plain" },      .{ "text", "text/plain" },        .{ "csv", "text/csv" },
        .{ "xml", "text/xml" },        .{ "md", "text/markdown" },       .{ "png", "image/png" },
        .{ "jpg", "image/jpeg" },      .{ "jpeg", "image/jpeg" },        .{ "gif", "image/gif" },
        .{ "webp", "image/webp" },     .{ "svg", "image/svg+xml" },      .{ "ico", "image/x-icon" },
        .{ "bmp", "image/bmp" },       .{ "avif", "image/avif" },        .{ "pdf", "application/pdf" },
        .{ "zip", "application/zip" }, .{ "gz", "application/gzip" },   .{ "wasm", "application/wasm" },
        .{ "mp3", "audio/mpeg" },      .{ "wav", "audio/wav" },          .{ "ogg", "audio/ogg" },
        .{ "flac", "audio/flac" },     .{ "mp4", "video/mp4" },          .{ "webm", "video/webm" },
    };
    for (known) |k| if (std.ascii.eqlIgnoreCase(ext, k[0])) return k[1];
    // The registry: ".ext" under HKEY_CLASSES_ROOT.
    var key: [72]u16 = undefined;
    if (ext.len + 2 > key.len) return "";
    key[0] = '.';
    for (ext, 0..) |ch, j| {
        if (ch >= 0x80) return "";
        key[j + 1] = ch;
    }
    key[ext.len + 1] = 0;
    var value: [128]u16 = undefined;
    var size: u32 = @sizeOf(@TypeOf(value));
    const RRF_RT_REG_SZ: u32 = 0x2;
    if (c.RegGetValueW(c.HKEY_CLASSES_ROOT, @ptrCast(&key), std.unicode.utf8ToUtf16LeStringLiteral("Content Type"), RRF_RT_REG_SZ, null, &value, &size) != 0) return "";
    const units = std.mem.sliceTo(&value, 0);
    var out: usize = 0;
    for (units) |u| {
        if (u >= 0x80 or out >= buf.len) return "";
        buf[out] = std.ascii.toLower(@intCast(u));
        out += 1;
    }
    return buf[0..out];
}

/// The drag's strings: ["string", type, value] each (text, a link,
/// HTML's fragment).
fn dropStrings(kinds: DragKinds, data: *IDataObject, items: *DropItems) void {
    const formats = [_]u16{ CF_UNICODETEXT, cf_url, cf_html };
    for (kinds.strings(), formats) |mime, format| if (mime) |m| {
        var med = data.global(format) orelse continue;
        defer ReleaseStgMedium(&med);
        const size = c.GlobalSize(med.data);
        const ptr = c.GlobalLock(med.data) orelse continue;
        defer _ = c.GlobalUnlock(med.data);
        const text = (if (format == cf_html)
            htmlFragment(items.gpa, @as([*]const u8, @ptrCast(ptr))[0..size])
        else
            utf16Text(items.gpa, @as([*]const u16, @ptrCast(@alignCast(ptr)))[0 .. size / 2])) orelse continue;
        defer items.gpa.free(text);
        if (text.len > drag_max_string) {
            log.warn("native ui: a dropped {s} over {d} MiB left out", .{ m, drag_max_string >> 20 });
            continue;
        }
        stringItem(items, m, text) catch {};
    };
}

/// UTF-16 up to its NUL as UTF-8 (owned).
fn utf16Text(gpa: std.mem.Allocator, units: []const u16) ?[]u8 {
    const end = std.mem.indexOfScalar(u16, units, 0) orelse units.len;
    return std.unicode.utf16LeToUtf8Alloc(gpa, units[0..end]) catch null;
}

/// CF_HTML's fragment (StartFragment to EndFragment, UTF-8 byte offsets
/// in its header), as Chromium reads it (owned).
fn htmlFragment(gpa: std.mem.Allocator, bytes: []const u8) ?[]u8 {
    const doc = bytes[0 .. std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len];
    const start = headerOffset(doc, "StartFragment:") orelse return null;
    const end = headerOffset(doc, "EndFragment:") orelse return null;
    if (start > end or end > doc.len) return null;
    return gpa.dupe(u8, doc[start..end]) catch null;
}

/// CF_HTML's header field `name` (its decimal value).
fn headerOffset(doc: []const u8, name: []const u8) ?usize {
    const at = std.mem.indexOf(u8, doc, name) orelse return null;
    var i = at + name.len;
    var v: usize = 0;
    var any = false;
    while (i < doc.len and doc[i] >= '0' and doc[i] <= '9') : (i += 1) {
        v = std.math.mul(usize, v, 10) catch return null;
        v = std.math.add(usize, v, doc[i] - '0') catch return null;
        any = true;
    }
    return if (any) v else null;
}

fn stringItem(items: *DropItems, mime: []const u8, text: []const u8) !void {
    if (!try items.start()) return;
    try items.json.appendSlice(items.gpa, "[\"string\",");
    try items.string(mime);
    try items.json.append(items.gpa, ',');
    try items.string(text);
    try items.json.append(items.gpa, ']');
}
