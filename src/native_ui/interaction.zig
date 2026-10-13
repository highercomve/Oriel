//! How a window responds to the keyboard and pointer, as the platform's
//! WebView does (measured there), for both front ends: the native
//! renderer's page (main.js asks through __host) and .oriel views
//! (focus.zig). One set of rules:
//!
//! - the focus ring each platform draws, by kind of element;
//! - which elements Tab visits and in what order, and whether a click
//!   focuses an element;
//! - how far a key scrolls, and the glide that animates it.
//!
//! Each front end finds its candidates (the page's DOM in document order,
//! a view's tree in tree order) and keeps what only it knows (DOM events,
//! a field's own keys); the decisions are here. Pure rules, no tree: the
//! engines apply them (engine_core.zig scrolls), and the JavaScript tests'
//! fake hosts get them compiled to WebAssembly (interaction_wasm.zig).
const std = @import("std");

/// A color: r, g, b 0-255, a 0-1 (tree.Color).
pub const Color = [4]f32;

/// A focus ring: `w` wide, `o` out from the border box, corners at least
/// `r` round, with a 1px white halo (`halo`). tree.Outline draws it.
pub const Ring = struct { w: f32, o: f32 = 0, c: Color, r: f32 = 0, halo: bool = false };

pub const Os = enum { linux, windows, macos, android, ios, other };

/// What the platform JSON says about input (`os`, `fullKeyboardAccess`,
/// `accent`), and the accent the window last heard ("accent" events).
pub const Platform = struct {
    os: Os = .other,
    /// macOS's keyboard navigation setting: Tab visits buttons and links too.
    full_keyboard_access: bool = false,
    accent: ?[3]f32 = null,

    pub fn parse(gpa: std.mem.Allocator, json: []const u8) Platform {
        const Raw = struct { os: []const u8 = "", fullKeyboardAccess: bool = false, accent: ?[3]f32 = null };
        const parsed = std.json.parseFromSlice(Raw, gpa, json, .{ .ignore_unknown_fields = true }) catch return .{};
        defer parsed.deinit();
        const a = parsed.value.accent;
        return .{
            .os = std.meta.stringToEnum(Os, parsed.value.os) orelse .other,
            .full_keyboard_access = parsed.value.fullKeyboardAccess,
            .accent = if (a) |c| accentOf(c[0], c[1], c[2]) else null,
        };
    }

    /// An "accent" event's `[r, g, b]`: the rings follow it.
    pub fn setAccent(p: *Platform, gpa: std.mem.Allocator, data: []const u8) void {
        const parsed = std.json.parseFromSlice([3]f32, gpa, data, .{}) catch return;
        defer parsed.deinit();
        p.accent = accentOf(parsed.value[0], parsed.value[1], parsed.value[2]);
    }
};

/// An accent color from outside (the platform JSON, an "accent" event, the
/// page): each channel finite and 0-255, else none (the default ring).
pub fn accentOf(r: anytype, g: anytype, b: anytype) ?[3]f32 {
    const ok = struct {
        fn f(v: f64) bool {
            return std.math.isFinite(v) and v >= 0 and v <= 255;
        }
    }.f;
    const c = [3]f64{ @floatCast(r), @floatCast(g), @floatCast(b) };
    if (!ok(c[0]) or !ok(c[1]) or !ok(c[2])) return null;
    return .{ @floatCast(c[0]), @floatCast(c[1]), @floatCast(c[2]) };
}

// ---------------------------------------------------------------------------
// Focus rings

/// The kind of element a ring is drawn around (render.js ringFor): a text
/// field, a button or other control, a checkbox or radio, a link, any
/// other box.
pub const RingKind = enum { field, control, check, link, box };

/// The platform's focus ring for that kind of element:
/// - WebKitGTK (Linux): 2px in the accent at 0.8 alpha (WebKit's blue
///   without one), over a control's border (5px corners), just outside a
///   link or another box. No halo.
/// - Chromium (WebView2, Android's WebView): a 2px band in a 1px white
///   halo, corners at least r round: over a control's border (o -2, r 3),
///   1px over a box's edge (o -1, r 4), just outside a link, 1px off a
///   checkbox. #101010 on Windows, #E59700 on Android.
/// - WKWebView: the accent at half alpha (macOS rgb(0, 103, 244), iOS
///   rgb(0, 122, 255)); macOS 4px, 1px off a box or link and 1px over a
///   control (AppKit's bezel: 5); iOS 3px, 2px over a control (r 8).
/// Measured in each WebView (render.js had them before).
pub fn ring(p: Platform, kind: RingKind) Ring {
    const R = struct {
        fn of(w: f32, c: Color, o: f32, r: f32, halo: bool) Ring {
            return .{ .w = w, .o = o, .c = c, .r = r, .halo = halo };
        }
    };
    switch (p.os) {
        .linux => {
            const a = p.accent orelse [3]f32{ 52, 132, 228 };
            const c: Color = .{ a[0], a[1], a[2], 0.8 };
            return switch (kind) {
                .field, .control => R.of(2, c, -2, 5, false),
                .check => R.of(2, c, 0, 3, false),
                .link, .box => R.of(2, c, 1, 3, false),
            };
        },
        .windows, .android => {
            const c: Color = if (p.os == .windows) .{ 16, 16, 16, 1 } else .{ 229, 151, 0, 1 };
            return switch (kind) {
                .field, .control => R.of(2, c, -2, 3, true),
                .check => R.of(2, c, 1, 3, true),
                .link => R.of(2, c, 0, 4, true),
                .box => R.of(2, c, -1, 4, true),
            };
        },
        .macos => {
            const a = p.accent orelse [3]f32{ 0, 103, 244 };
            const c: Color = .{ a[0], a[1], a[2], 0.5 };
            return switch (kind) {
                .field => R.of(4, c, -1, 2, false),
                .control, .check => R.of(4, c, -1, 5, false),
                .link, .box => R.of(4, c, 1, 2, false),
            };
        },
        .ios => {
            const a = p.accent orelse [3]f32{ 0, 122, 255 };
            const c: Color = .{ a[0], a[1], a[2], 0.5 };
            return switch (kind) {
                .field, .control, .check => R.of(3, c, -2, 8, false),
                .link, .box => R.of(3, c, 0, 0, false),
            };
        },
        // Another platform: WebKit's default ring.
        .other => return .{ .w = 2, .c = .{ 0, 103, 244, 1 }, .o = 1 },
    }
}

/// The ring as host.focusRing answers it: `[w, o, r, red, green, blue,
/// alpha, halo]`, rounded to 6 places (f32's 0.8 is 0.800000011920929).
pub fn ringNumbers(r: Ring) [8]f64 {
    const tidy = struct {
        fn f(x: f32) f64 {
            return @round(@as(f64, x) * 1e6) / 1e6;
        }
    }.f;
    return .{ tidy(r.w), tidy(r.o), tidy(r.r), tidy(r.c[0]), tidy(r.c[1]), tidy(r.c[2]), tidy(r.c[3]), @floatFromInt(@intFromBool(r.halo)) };
}

// ---------------------------------------------------------------------------
// Sequential focus (Tab)

/// Which elements Tab visits, as the platform's WebView does (measured):
/// - mac: macOS without Full Keyboard Access: text fields, selects,
///   textareas and contenteditable, plus anything with an explicit
///   tabindex >= 0 (a button or link without one is skipped);
/// - ios: the same, but a tabindex doesn't bring in a button, checkbox or
///   range;
/// - all: browsers' order (Full Keyboard Access, other platforms).
pub const TabRule = enum { all, mac, ios };

pub fn tabRule(p: Platform) TabRule {
    return switch (p.os) {
        .ios => .ios,
        .macos => if (p.full_keyboard_access) .all else .mac,
        else => .all,
    };
}

/// What kind of focusable element a candidate is, for the rules above.
pub const FocusKind = enum(u8) {
    /// Text-like: a text field, select, textarea, contenteditable.
    text,
    /// A form control that isn't text-like: button, checkbox, radio, range.
    control,
    /// Anything else focusable: a link, an element with a tabindex, a
    /// drawn button in an .oriel view.
    other,
};

/// One element that can take focus, as a front end found it (enabled,
/// shown), in document (or tree) order.
pub const Candidate = struct {
    id: i64,
    kind: FocusKind,
    /// An explicit tabindex (null: none, a focusable element's 0).
    tabindex: ?i32 = null,
    /// A radio's group (0: not a radio in a named group), and whether it's
    /// checked: a group is one stop.
    group: u32 = 0,
    checked: bool = false,
};

/// Whether Tab visits it on this platform.
fn visits(rule: TabRule, c: Candidate) bool {
    if (c.tabindex) |t| {
        if (t < 0) return false;
        return !(rule == .ios and c.kind == .control);
    }
    return rule == .all or c.kind == .text;
}

/// The candidate Tab (Shift+Tab: `back`) moves the focus to from `active`
/// (an id; null: nothing focused), as browsers order it: positive tabindex
/// first (ascending, then in order), then the rest in order; a radio group
/// is one stop (its checked radio, else the focused one, else its first).
/// Wraps around. Null: nothing to visit.
pub fn tabNext(gpa: std.mem.Allocator, rule: TabRule, cands: []const Candidate, active: ?i64, back: bool) !?i64 {
    if (cands.len > max_candidates) return error.TooManyCandidates;
    // Each radio group's stop, in one pass.
    var stops: std.AutoHashMapUnmanaged(u32, GroupStop) = .empty;
    defer stops.deinit(gpa);
    for (cands) |c| {
        if (c.group == 0 or !visits(rule, c)) continue;
        const gop = try stops.getOrPut(gpa, c.group);
        if (!gop.found_existing) gop.value_ptr.* = .{ .first = c.id };
        if (c.checked and gop.value_ptr.checked == null) gop.value_ptr.checked = c.id;
        if (active != null and c.id == active.?) gop.value_ptr.focused = c.id;
    }
    var order: std.ArrayList(Candidate) = .empty;
    defer order.deinit(gpa);
    try order.ensureTotalCapacity(gpa, cands.len);
    for (cands) |c| {
        if (!visits(rule, c)) continue;
        if (c.group != 0 and stops.get(c.group).?.stop() != c.id) continue;
        order.appendAssumeCapacity(c);
    }
    if (order.items.len == 0) return null;
    // Positive tabindex first, ascending; the rest after them. Equal ones
    // keep their document order: a stable sort.
    std.sort.block(Candidate, order.items, {}, struct {
        fn positive(c: Candidate) bool {
            return (c.tabindex orelse 0) > 0;
        }
        fn lt(_: void, a: Candidate, b: Candidate) bool {
            if (positive(a) and positive(b)) return a.tabindex.? < b.tabindex.?;
            return positive(a) and !positive(b);
        }
    }.lt);
    const n = order.items.len;
    const at: ?usize = if (active) |id| for (order.items, 0..) |c, i| {
        if (c.id == id) break i;
    } else null else null;
    const i = if (at) |a| (if (back) (a + n - 1) % n else (a + 1) % n) else if (back) n - 1 else 0;
    return order.items[i].id;
}

/// The most candidates Tab orders (a page with more fails its Tab, rather
/// than holding the UI thread), and the most bytes they come in.
pub const max_candidates = 4096;
pub const max_candidates_json = max_candidates * 48;

/// A radio group's Tab stop: its checked radio, else the focused one, else
/// its first.
const GroupStop = struct {
    first: i64,
    checked: ?i64 = null,
    focused: ?i64 = null,
    fn stop(g: GroupStop) i64 {
        return g.checked orelse g.focused orelse g.first;
    }
};

/// Tab from the page (main.js tabCandidates): `json` the candidates in
/// document order, `[kind, tabindex | null, group, checked]` each (kind 0
/// text, 1 control, 2 other); the index Tab moves to from index `active`
/// (null: none), or null. Malformed or too many candidates: null.
pub fn tabNextJson(gpa: std.mem.Allocator, rule: TabRule, json: []const u8, active: ?usize, back: bool) !?usize {
    if (json.len > max_candidates_json) return null;
    const Raw = struct { u8, ?i32, u32, bool };
    const parsed = std.json.parseFromSlice([]const Raw, gpa, json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer parsed.deinit();
    if (parsed.value.len > max_candidates) return null;
    const cands = try gpa.alloc(Candidate, parsed.value.len);
    defer gpa.free(cands);
    for (parsed.value, cands, 0..) |r, *c, i| c.* = .{ .id = @intCast(i), .kind = kindFrom(r[0]), .tabindex = r[1], .group = r[2], .checked = r[3] };
    const at: ?i64 = if (active) |a| if (a < cands.len) @intCast(a) else null else null;
    const next = try tabNext(gpa, rule, cands, at, back) orelse return null;
    return @intCast(next);
}

/// A kind's number as main.js sends it (0 text, 1 control, else other).
pub fn kindFrom(n: anytype) FocusKind {
    return switch (n) {
        0 => .text,
        1 => .control,
        else => .other,
    };
}

/// A ring kind's number (field 0, control 1, check 2, link 3, box 4).
pub fn ringKindFrom(n: anytype) RingKind {
    return std.enums.fromInt(RingKind, @min(n, 4)) orelse .box;
}

/// Whether a click (a press) focuses an element of this kind. WebKit on
/// macOS and iOS focuses no button, link or checkbox on a click: only
/// text fields, selects and what has a tabindex.
pub fn clickFocuses(rule: TabRule, kind: FocusKind, has_tabindex: bool) bool {
    return has_tabindex or rule == .all or kind == .text;
}

// ---------------------------------------------------------------------------
// Keys that activate

/// Whether a key activates a focused element, as browsers do: Enter (on
/// press, not repeated) a button or a link (or a <summary>); Space (on
/// release) a button, checkbox or radio.
pub fn activates(key: []const u8, down: bool, repeat: bool, button: bool, link: bool, checkable: bool) bool {
    if (std.mem.eql(u8, key, "Enter")) return down and !repeat and (button or link);
    if (std.mem.eql(u8, key, " ")) return !down and (button or checkable);
    return false;
}

// ---------------------------------------------------------------------------
// Keys that scroll

/// How a key scrolls (Chromium's amounts): ArrowUp/Down 40px, PageUp/Down
/// and Space (Shift: up) 87.5% of the view, Home/End to the ends.
pub const Step = struct {
    /// Pixels (`line`), or a fraction of the view (`page`), or to an end.
    amount: f32,
    kind: enum { line, page, end },
};

pub fn scrollStep(key: []const u8, shift: bool) ?Step {
    const eq = std.mem.eql;
    if (eq(u8, key, "ArrowDown")) return .{ .amount = 40, .kind = .line };
    if (eq(u8, key, "ArrowUp")) return .{ .amount = -40, .kind = .line };
    if (eq(u8, key, "PageDown")) return .{ .amount = 0.875, .kind = .page };
    if (eq(u8, key, "PageUp")) return .{ .amount = -0.875, .kind = .page };
    if (eq(u8, key, " ")) return .{ .amount = if (shift) -0.875 else 0.875, .kind = .page };
    if (eq(u8, key, "Home")) return .{ .amount = -1, .kind = .end };
    if (eq(u8, key, "End")) return .{ .amount = 1, .kind = .end };
    return null;
}

/// Where a key takes a scroller now at `top` (or going there, mid-glide)
/// that shows `view` px of its content and goes down to `max`.
pub fn keyTarget(top: f32, view: f32, max: f32, step: Step) f32 {
    const by: f32 = switch (step.kind) {
        .line => step.amount,
        .page => @round(step.amount * view),
        .end => if (step.amount < 0) -std.math.inf(f32) else std.math.inf(f32),
    };
    return std.math.clamp(top + by, 0, @max(0, max));
}

// ---------------------------------------------------------------------------
// The glide

/// A cubic Bézier timing function (x1, y1, x2, y2), solved for x by
/// Newton's method (CSS's; transitions.js has the same for the page's).
pub fn bezier(x1: f64, y1: f64, x2: f64, y2: f64, p: f64) f64 {
    if (p <= 0) return 0;
    if (p >= 1) return 1;
    const cx = 3 * x1;
    const bx = 3 * (x2 - x1) - cx;
    const ax = 1 - cx - bx;
    const cy = 3 * y1;
    const by = 3 * (y2 - y1) - cy;
    const ay = 1 - cy - by;
    var t = p;
    for (0..8) |_| {
        const e = ((ax * t + bx) * t + cx) * t - p;
        if (@abs(e) < 1e-4) break;
        const d = (3 * ax * t + 2 * bx) * t + cx;
        if (@abs(d) < 1e-6) break;
        t -= e / d;
    }
    t = std.math.clamp(t, 0, 1);
    return ((ay * t + by) * t + cy) * t;
}

/// A key scroll glides as WKWebView's does (measured on macOS): a page,
/// Space, Home or End over 200 ms on `ease`, however far; an arrow's 40px
/// over 256 ms on `ease-out`, 20 ms in. A page's own scroll, a wheel or a
/// touch stops it where it is.
pub const Glide = struct {
    target: i64 = 0,
    from: f32 = 0,
    to: f32 = 0,
    t0: f64 = 0,
    line: bool = false,
    active: bool = false,
    /// A frame callback drives it (engine_core.keyScroll): one at a time,
    /// whether or not a glide is running.
    hooked: bool = false,
    /// Which glide this is: a frame that runs the app's code (a scroll it
    /// hears of) can start another; the old one's end mustn't stop it.
    gen: u32 = 0,

    /// Where scroller `id` (now at `scroll_y`) is going: mid-glide a key
    /// goes on from there.
    pub fn top(g: *const Glide, id: i64, scroll_y: f32) f32 {
        return if (g.active and g.target == id) g.to else scroll_y;
    }

    pub fn start(g: *Glide, id: i64, scroll_y: f32, to: f32, step: Step, now_ms: f64) void {
        g.* = .{ .target = id, .from = scroll_y, .to = to, .t0 = now_ms, .line = step.kind == .line, .active = true, .hooked = g.hooked, .gen = g.gen +% 1 };
    }

    /// A touch went down: a glide anywhere stops (the "pointer" event's
    /// data `["down", x, y, buttons, id, "touch", mods]`).
    pub fn stopOnTouch(g: *Glide, kind: []const u8, data: []const u8) void {
        if (!g.active or !std.mem.eql(u8, kind, "pointer")) return;
        if (std.mem.startsWith(u8, data, "[\"down\"") and std.mem.indexOf(u8, data, "\"touch\"") != null) g.active = false;
    }

    /// The offset at `now_ms`, and whether it has arrived.
    pub fn at(g: *const Glide, now_ms: f64) struct { y: f32, done: bool } {
        const ms: f64 = if (g.line) 256 else 200;
        const delay: f64 = if (g.line) 20 else 0;
        const raw = (now_ms - g.t0 - delay) / ms;
        // No clock (NaN): there.
        const p = if (std.math.isNan(raw)) 1 else std.math.clamp(raw, 0, 1);
        const e = if (g.line) bezier(0, 0, 0.58, 1, p) else bezier(0.25, 0.1, 0.25, 1, p);
        return .{ .y = g.from + (g.to - g.from) * @as(f32, @floatCast(e)), .done = p >= 1 };
    }

    /// Something else scrolled that scroller: the glide stops.
    pub fn stopFor(g: *Glide, id: i64) void {
        if (g.target == id) g.active = false;
    }
};

test "tab order: positive tabindex first, radio groups are one stop, platform rules" {
    const gpa = std.testing.allocator;
    // The page from tab-focus.test.mjs, as main.js finds its candidates.
    const cands = [_]Candidate{
        .{ .id = 1, .kind = .other }, // a href
        .{ .id = 2, .kind = .text }, // input
        .{ .id = 3, .kind = .other, .tabindex = 0 }, // div tabindex=0
        .{ .id = 4, .kind = .other, .tabindex = 2 },
        .{ .id = 5, .kind = .other, .tabindex = 1 },
        .{ .id = 6, .kind = .text, .tabindex = -1 },
        .{ .id = 7, .kind = .control }, // button tabindex="x"
    };
    var order: [7]i64 = undefined;
    var at: ?i64 = null;
    for (&order) |*o| {
        at = try tabNext(gpa, .all, &cands, at, false);
        o.* = at.?;
    }
    try std.testing.expectEqual([7]i64{ 5, 4, 1, 2, 3, 7, 5 }, order);
    try std.testing.expectEqual(@as(?i64, 7), try tabNext(gpa, .all, &cands, 5, true));
    // macOS without Full Keyboard Access: text-like and explicit tabindex.
    at = null;
    var mac: [4]i64 = undefined;
    for (&mac) |*o| {
        at = try tabNext(gpa, .mac, &cands, at, false);
        o.* = at.?;
    }
    try std.testing.expectEqual([4]i64{ 5, 4, 2, 3 }, mac);
    // iOS: a tabindex doesn't bring in a control.
    const ios = [_]Candidate{ .{ .id = 1, .kind = .control, .tabindex = 0 }, .{ .id = 2, .kind = .text } };
    try std.testing.expectEqual(@as(?i64, 2), try tabNext(gpa, .ios, &ios, null, false));
    // A radio group: its checked radio, else the focused one, else its first.
    const radios = [_]Candidate{
        .{ .id = 1, .kind = .text },
        .{ .id = 2, .kind = .control, .group = 9 },
        .{ .id = 3, .kind = .control, .group = 9, .checked = true },
        .{ .id = 4, .kind = .control, .group = 9 },
        .{ .id = 5, .kind = .text },
    };
    try std.testing.expectEqual(@as(?i64, 3), try tabNext(gpa, .all, &radios, 1, false));
    try std.testing.expectEqual(@as(?i64, 5), try tabNext(gpa, .all, &radios, 3, false));
    const unchecked = [_]Candidate{ .{ .id = 2, .kind = .control, .group = 9 }, .{ .id = 4, .kind = .control, .group = 9 } };
    try std.testing.expectEqual(@as(?i64, 2), try tabNext(gpa, .all, &unchecked, null, false));
    try std.testing.expectEqual(@as(?i64, null), try tabNext(gpa, .mac, &unchecked, null, false));
}

test "rings, clicks, activation and key steps" {
    const linux: Platform = .{ .os = .linux };
    try std.testing.expectEqual(@as(f32, -2), ring(linux, .control).o);
    try std.testing.expectEqual(@as(f32, 0.8), ring(linux, .box).c[3]);
    const mac: Platform = .{ .os = .macos, .accent = .{ 10, 20, 30 } };
    try std.testing.expectEqual(Color{ 10, 20, 30, 0.5 }, ring(mac, .link).c);
    try std.testing.expect(ring(.{ .os = .windows }, .box).halo);
    try std.testing.expect(!clickFocuses(.mac, .control, false));
    try std.testing.expect(clickFocuses(.mac, .text, false));
    try std.testing.expect(clickFocuses(.all, .control, false));
    try std.testing.expect(activates("Enter", true, false, false, true, false));
    try std.testing.expect(!activates("Enter", true, true, true, false, false));
    try std.testing.expect(activates(" ", false, false, false, false, true));
    try std.testing.expect(!activates(" ", false, false, false, true, false));
    try std.testing.expect(!activates(" ", true, false, true, false, true));
    try std.testing.expectEqual(@as(f32, -0.875), scrollStep(" ", true).?.amount);
    try std.testing.expect(scrollStep("a", false) == null);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), bezier(0.42, 0, 0.58, 1, 0.5), 1e-3);
    var g: Glide = .{ .from = 0, .to = 100, .t0 = 0, .line = false, .active = true };
    try std.testing.expectEqual(@as(f32, 0), g.at(0).y);
    try std.testing.expect(g.at(200).done);
    try std.testing.expectEqual(@as(f32, 100), g.at(250).y);
    g.line = true;
    try std.testing.expectEqual(@as(f32, 0), g.at(20).y);
    try std.testing.expectEqual(@as(f32, 525), keyTarget(0, 600, 3000, .{ .amount = 0.875, .kind = .page }));
    try std.testing.expectEqual(@as(f32, 3000), keyTarget(10, 600, 3000, .{ .amount = 1, .kind = .end }));
    g.stopOnTouch("pointer", "[\"down\",1,1,1,1,\"mouse\",0]");
    try std.testing.expect(g.active);
    g.stopOnTouch("pointer", "[\"down\",1,1,1,1,\"touch\",0]");
    try std.testing.expect(!g.active);
}

test "tab order: tabindex 2147483647 still comes first; too many candidates fail" {
    const gpa = std.testing.allocator;
    const cands = [_]Candidate{
        .{ .id = 1, .kind = .text },
        .{ .id = 2, .kind = .other, .tabindex = std.math.maxInt(i32) },
    };
    try std.testing.expectEqual(@as(?i64, 2), try tabNext(gpa, .all, &cands, null, false));
    const many = try gpa.alloc(Candidate, max_candidates + 1);
    defer gpa.free(many);
    @memset(many, .{ .id = 0, .kind = .text });
    try std.testing.expectError(error.TooManyCandidates, tabNext(gpa, .all, many, null, false));
}

test tabNextJson {
    const gpa = std.testing.allocator;
    const json = "[[2,null,0,false],[0,null,0,false],[2,2,0,false],[1,null,7,false],[1,null,7,true]]";
    try std.testing.expectEqual(@as(?usize, 2), try tabNextJson(gpa, .all, json, null, false));
    try std.testing.expectEqual(@as(?usize, 0), try tabNextJson(gpa, .all, json, 2, false));
    try std.testing.expectEqual(@as(?usize, 4), try tabNextJson(gpa, .all, json, 1, false));
    try std.testing.expectEqual(@as(?usize, 1), try tabNextJson(gpa, .mac, json, 2, false));
    try std.testing.expectEqual(@as(?usize, null), try tabNextJson(gpa, .all, "nonsense", null, false));
}

test accentOf {
    try std.testing.expectEqual(@as(?[3]f32, .{ 1, 2, 3 }), accentOf(@as(f64, 1), @as(f64, 2), @as(f64, 3)));
    try std.testing.expectEqual(@as(?[3]f32, null), accentOf(std.math.nan(f64), @as(f64, 2), @as(f64, 3)));
    try std.testing.expectEqual(@as(?[3]f32, null), accentOf(@as(f64, 300), @as(f64, 2), @as(f64, 3)));
}

test "platform JSON" {
    const p = Platform.parse(std.testing.allocator, "{\"os\":\"macos\",\"fullKeyboardAccess\":true,\"accent\":[1,2,3],\"dpr\":2}");
    try std.testing.expectEqual(Os.macos, p.os);
    try std.testing.expect(p.full_keyboard_access);
    try std.testing.expectEqual(TabRule.all, tabRule(p));
    try std.testing.expectEqual(TabRule.mac, tabRule(.{ .os = .macos }));
}
