//! What both UI engines share: engine_js.zig (a page's HTML, CSS and
//! JavaScript in QuickJS) and engine_zig.zig (an app's .oriel views run
//! from Zig). Each engine is its front end; this is the machinery under it:
//! the open engines by serial, the tree's backend hooks, the app's display
//! frame callbacks, painting coalesced to one per frame, scrolling.
//!
//! Functions take the engine (`e: anytype`) and use the fields both have
//! by the same names: tree, backend, booted, in_call, frame_pending,
//! relaid, frame_hooks.
const std = @import("std");
const tree_mod = @import("tree.zig");
const interaction = @import("interaction.zig");
const Node = tree_mod.Node;

/// The open engines by serial (UI thread): what a Zig handle that outlived
/// its window looks up. Serials are unique per process, so an answer meant
/// for a closed window never reaches a new one at the same address.
pub fn Registry(comptime Engine: type) type {
    return struct {
        // usize: 32-bit targets (armv7, x86 Android) have no 64-bit atomic
        // add. Wrapping would take 4 billion engines in one process.
        var next_serial: std.atomic.Value(usize) = .init(0);
        var live: std.AutoHashMapUnmanaged(u64, *Engine) = .empty;

        pub fn newSerial() u64 {
            return @as(u64, next_serial.fetchAdd(1, .monotonic)) + 1;
        }
        pub fn add(e: *Engine) !void {
            try live.put(std.heap.smp_allocator, e.serial, e);
        }
        pub fn remove(serial: u64) void {
            _ = live.remove(serial);
        }
        pub fn get(serial: u64) ?*Engine {
            return live.get(serial);
        }
    };
}

/// The app's Zig at each display frame (a canvas it animates), while each
/// callback returns true. Callbacks may add or cancel callbacks while they
/// run: a cancelled one is skipped and dropped after the pass, and one added
/// during a frame starts with the next.
pub fn FrameHooks(comptime Engine: type) type {
    return struct {
        const Self = @This();
        pub const Hook = struct {
            ctx: *anyopaque,
            func: *const fn (ctx: *anyopaque, e: *Engine, interval_ms: f64) bool,
            run_after: u64 = 0,
            cancelled: bool = false,
        };

        list: std.ArrayList(Hook) = .empty,
        /// A pass is running: what the hooks commit shows with this frame.
        running: bool = false,
        frame: u64 = 0,

        pub fn deinit(h: *Self, gpa: std.mem.Allocator) void {
            h.list.deinit(gpa);
        }
        /// Drop every callback (a reload). During a pass they're cancelled
        /// instead: the pass drops them, not its caller from under it.
        pub fn clear(h: *Self) void {
            if (!h.running) return h.list.clearRetainingCapacity();
            for (h.list.items) |*hook| hook.cancelled = true;
        }
        pub fn any(h: *const Self) bool {
            return h.list.items.len > 0;
        }
        pub fn add(h: *Self, gpa: std.mem.Allocator, hook: Hook) !void {
            var pending = hook;
            pending.run_after = h.frame + @intFromBool(h.running);
            pending.cancelled = false;
            try h.list.append(gpa, pending);
        }
        /// Stop the callbacks with this context.
        pub fn remove(h: *Self, ctx: *anyopaque) void {
            var i: usize = 0;
            while (i < h.list.items.len) {
                if (h.list.items[i].ctx != ctx) {
                    i += 1;
                } else if (h.running) {
                    h.list.items[i].cancelled = true;
                    i += 1;
                } else _ = h.list.orderedRemove(i);
            }
        }
        /// One display frame's pass. A frame delivered while a pass runs (a
        /// callback that pumps the backend's loop) is skipped: the pass in
        /// progress owns the list.
        pub fn run(h: *Self, e: *Engine, interval_ms: f64) void {
            if (h.running) return;
            h.frame += 1;
            h.running = true;
            defer h.running = false;
            var i: usize = 0;
            while (i < h.list.items.len) {
                const hook = h.list.items[i];
                if (hook.cancelled) {
                    _ = h.list.orderedRemove(i);
                    continue;
                }
                if (hook.run_after > h.frame) {
                    i += 1;
                    continue;
                }
                const keep = hook.func(hook.ctx, e, interval_ms);
                if (keep and !h.list.items[i].cancelled) i += 1 else _ = h.list.orderedRemove(i);
            }
        }
    };
}

/// Point the tree's notifications at the backend and give it the window's size.
pub fn hookTree(e: anytype, width: f32, height: f32) void {
    const backend = e.backend;
    e.tree.width = width;
    e.tree.height = height;
    e.tree.on_remove = backend.removed;
    e.tree.on_props = backend.props;
    e.tree.props_need_value = backend.mirrors_props;
    e.tree.on_ax = backend.ax_changed;
    e.tree.on_text = backend.text;
    e.tree.measure_texts = backend.measure_texts;
    e.tree.on_leaf_style = backend.leaf_style;
    e.tree.on_create = backend.leaf;
    e.tree.on_paint = backend.paint;
    e.tree.on_canvas = backend.canvas;
}

/// Lay out if anything changed, and have the backend draw it.
pub fn layoutAndShow(e: anytype) void {
    if (e.tree.needsLayout()) {
        e.tree.layout();
        e.relaid = true;
    }
    if (e.relaid or e.tree.paint_dirty) {
        e.relaid = false;
        e.tree.paint_dirty = false;
        e.backend.laid_out(e.backend.ctx);
    }
}

/// Changes are waiting to be shown: at the next frame when the backend
/// paces them (`Backend.request_frame`: one layout and draw however many
/// events came), else now. False: the caller shows them now.
pub fn deferToFrame(e: anytype) bool {
    if (!e.booted) return false;
    const request = e.backend.request_frame orelse return false;
    if (!e.frame_pending) {
        e.frame_pending = true;
        request(e.backend.ctx);
    }
    return true;
}

/// The timer id both engines give the display frame when the backend has no
/// frame clock (`Backend.request_display_frame`): 60 Hz.
pub const display_frame_timer: u32 = std.math.maxInt(u32) - 2;

/// The timer of ORIEL_NUI_DUMP_AT=<seconds>: the tree dumped once then
/// (Tree.dump; with ORIEL_NUI_DUMP=props, the props too), to see it after
/// the UI changed (a panel opened).
pub const dump_timer: u32 = std.math.maxInt(u32) - 3;

/// Boot: schedule ORIEL_NUI_DUMP_AT's dump, if it's set.
pub fn scheduleDump(e: anytype) void {
    const at = std.c.getenv("ORIEL_NUI_DUMP_AT") orelse return;
    const seconds = std.fmt.parseFloat(f64, std.mem.span(at)) catch return;
    if (!(seconds >= 0 and seconds < 3600)) return;
    e.backend.add_timer(e.backend.ctx, e, dump_timer, @intFromFloat(seconds * 1000));
}

/// The dump's turn: laid out first.
pub fn dumpNow(e: anytype) void {
    if (e.tree.needsLayout()) {
        e.tree.layout();
        e.relaid = true;
    }
    e.tree.dump();
}

/// Ask for the next display frame (frame callbacks are waiting): the
/// backend's frame clock, else a timer (`display_frame_timer`, which the
/// engine's timerFired turns into `displayFrame`).
pub fn requestDisplayFrame(e: anytype) void {
    if (e.backend.request_display_frame) |request| request(e.backend.ctx) else e.backend.add_timer(e.backend.ctx, e, display_frame_timer, 17);
}

pub const Axis = enum { x, y };

/// Move a scroller by `delta` along `axis`, within its content: true if it
/// moved. The tree notes it (Tree.scrolled) and places the views again;
/// the engine tells its front end and has it drawn.
pub fn moveScroll(e: anytype, node: *Node, axis: Axis, delta: f32) bool {
    const pos = switch (axis) {
        .x => &node.scroll_x,
        .y => &node.scroll_y,
    };
    const room = switch (axis) {
        .x => node.content_w - node.frame.w,
        .y => node.content_h - node.frame.h,
    };
    const before = pos.*;
    pos.* = std.math.clamp(before + delta, 0, @max(0, room));
    if (pos.* == before) return false;
    e.tree.noteScroll(node);
    e.tree.replace();
    return true;
}

/// A ring (interaction.ring) as the tree draws it.
pub fn outline(r: interaction.Ring) tree_mod.Outline {
    return .{ .w = r.w, .o = r.o, .c = r.c, .r = r.r, .h = if (r.halo) .{ 255, 255, 255, 1 } else null };
}

/// The view a scroller shows (its frame less its top and bottom borders).
pub fn viewHeight(n: *const Node) f32 {
    const yg = tree_mod.yg;
    return n.frame.h - yg.YGNodeLayoutGetBorder(n.yn, yg.YGEdgeTop) - yg.YGNodeLayoutGetBorder(n.yn, yg.YGEdgeBottom);
}

/// How far down a scroller can go.
pub fn maxScroll(n: *const Node) f32 {
    return @max(0, n.content_h - n.frame.h);
}

/// The scroller a key moves: the nearest one around `from` that has more
/// inside than it shows, else `fallback` (the window's) if it does.
pub fn scrollerFor(from: ?*Node, fallback: ?*Node) ?*Node {
    var at = from;
    var depth: usize = 0;
    while (at) |n| : (at = n.parent) {
        if (n.props.scroll and maxScroll(n) > 0.5) return n;
        depth += 1;
        if (depth > 256) break;
    }
    if (fallback) |f| if (maxScroll(f) > 0.5) return f;
    return null;
}

/// A key that scrolls (interaction.scrollStep), from `from`'s nearest
/// scroller else `fallback`: glides there. False: not a scrolling key, no
/// scroller, or already there. Lays out only for a scrolling key.
pub fn keyScroll(comptime Engine: type, e: *Engine, from: ?*Node, fallback: ?*Node, key: []const u8, shift: bool) !bool {
    const step = interaction.scrollStep(key, shift) orelse return false;
    if (e.tree.needsLayout()) {
        e.tree.layout();
        e.relaid = true;
    }
    const n = scrollerFor(from, fallback) orelse return false;
    const top = e.glide.top(n.id, n.scroll_y);
    const to = interaction.keyTarget(top, viewHeight(n), maxScroll(n), step);
    if (to == top) return false;
    e.glide.start(n.id, n.scroll_y, to, step, nowMs());
    if (!e.glide.hooked) {
        e.addFrameHook(.{ .ctx = @ptrCast(&e.glide), .func = Glide(Engine).frame }) catch |err| {
            e.glide.active = false;
            return err;
        };
        e.glide.hooked = true;
    }
    return true;
}

/// The glide on the engine's display frames: `e.glide` moved by the
/// engine's own `setScrollY(node, y)` (what a scroll means to its front
/// end), each frame until it arrives or something stops it; then the one
/// callback goes.
fn Glide(comptime Engine: type) type {
    return struct {
        fn frame(ctx: *anyopaque, e: *Engine, _: f64) bool {
            const g: *interaction.Glide = @ptrCast(@alignCast(ctx));
            if (g.active) if (e.tree.get(g.target)) |n| {
                const pos = g.at(nowMs());
                const gen = g.gen;
                e.setScrollY(n, pos.y);
                // The app may have started another glide meanwhile: that
                // one goes on.
                if (pos.done and g.gen == gen) g.active = false;
            } else {
                g.active = false;
            };
            g.hooked = g.active;
            return g.active;
        }
    };
}

/// Tests' clock (tests of the glide set it; else the real one).
pub var test_now: ?f64 = null;

/// A monotonic clock in ms; NaN when the platform's clock fails (a glide
/// then ends where it was going: interaction.Glide.at).
pub fn nowMs() f64 {
    if (@import("builtin").is_test) if (test_now) |t| return t;
    if (comptime @import("builtin").os.tag == .windows) {
        const qpc = @extern(*const fn (*i64) callconv(.winapi) c_int, .{ .name = "QueryPerformanceCounter", .library_name = "kernel32" });
        const qpf = @extern(*const fn (*i64) callconv(.winapi) c_int, .{ .name = "QueryPerformanceFrequency", .library_name = "kernel32" });
        var t: i64 = 0;
        var f: i64 = 1;
        if (qpc(&t) == 0 or qpf(&f) == 0 or f <= 0) return std.math.nan(f64);
        return @as(f64, @floatFromInt(t)) * 1e3 / @as(f64, @floatFromInt(f));
    }
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return std.math.nan(f64);
    return @as(f64, @floatFromInt(ts.sec)) * 1e3 + @as(f64, @floatFromInt(ts.nsec)) / 1e6;
}

test "frame hooks: self-cancellation, cancelling another, adding during a pass" {
    const Fake = struct {
        hooks: FrameHooks(@This()) = .{},
        calls: [4]u32 = @splat(0),
        const Hooks = FrameHooks(@This());
        fn cancelSelf(ctx: *anyopaque, e: *@This(), _: f64) bool {
            e.calls[0] += 1;
            e.hooks.remove(ctx);
            return false;
        }
        fn cancelLater(_: *anyopaque, e: *@This(), _: f64) bool {
            e.calls[1] += 1;
            e.hooks.remove(@ptrCast(&e.calls[2]));
            return true;
        }
        fn later(_: *anyopaque, e: *@This(), _: f64) bool {
            e.calls[2] += 1;
            return true;
        }
        fn adds(_: *anyopaque, e: *@This(), _: f64) bool {
            e.calls[3] += 1;
            if (e.calls[3] == 1) e.hooks.add(std.testing.allocator, .{ .ctx = @ptrCast(&e.calls[3]), .func = adds }) catch unreachable;
            return e.calls[3] < 3;
        }
    };
    var f: Fake = .{};
    defer f.hooks.deinit(std.testing.allocator);
    const gpa = std.testing.allocator;
    try f.hooks.add(gpa, .{ .ctx = @ptrCast(&f.calls[0]), .func = Fake.cancelSelf });
    try f.hooks.add(gpa, .{ .ctx = @ptrCast(&f.calls[1]), .func = Fake.cancelLater });
    try f.hooks.add(gpa, .{ .ctx = @ptrCast(&f.calls[2]), .func = Fake.later });
    try f.hooks.add(gpa, .{ .ctx = @ptrCast(&f.calls[3]), .func = Fake.adds });
    f.hooks.run(&f, 16);
    // The cancelled `later` never ran; the hook added during the pass waits.
    try std.testing.expectEqual([4]u32{ 1, 1, 0, 1 }, f.calls);
    try std.testing.expectEqual(@as(usize, 3), f.hooks.list.items.len);
    f.hooks.run(&f, 16);
    try std.testing.expectEqual([4]u32{ 1, 2, 0, 3 }, f.calls);
    f.hooks.run(&f, 16);
    try std.testing.expectEqual(@as(u32, 3), f.calls[1]);
}

test "frame hooks: a nested pass is skipped; clearing during a pass cancels" {
    const Fake = struct {
        hooks: FrameHooks(@This()) = .{},
        calls: u32 = 0,
        nested: u32 = 0,
        fn reenter(_: *anyopaque, e: *@This(), interval: f64) bool {
            e.calls += 1;
            // A callback that pumps the loop into another frame.
            e.hooks.run(e, interval);
            e.nested += 1;
            e.hooks.clear();
            return true;
        }
    };
    var f: Fake = .{};
    defer f.hooks.deinit(std.testing.allocator);
    try f.hooks.add(std.testing.allocator, .{ .ctx = @ptrCast(&f.calls), .func = Fake.reenter });
    f.hooks.run(&f, 16);
    try std.testing.expectEqual(@as(u32, 1), f.calls);
    try std.testing.expectEqual(@as(u32, 1), f.nested);
    // Cleared during its own pass: dropped after it, not under it.
    try std.testing.expect(!f.hooks.any());
}

test "a key scroll glides as WKWebView's, and a wheel, the page or a touch stops it" {
    const ui = @import("ui.zig");
    const Fake = struct {
        tree: tree_mod.Tree,
        glide: interaction.Glide = .{},
        hooks: FrameHooks(@This()) = .{},
        set: std.ArrayList(f32) = .empty,
        relaid: bool = false,
        pub fn addFrameHook(e: *@This(), hook: FrameHooks(@This()).Hook) !void {
            try e.hooks.add(std.testing.allocator, hook);
        }
        pub fn setScrollY(e: *@This(), n: *Node, y: f32) void {
            n.scroll_y = std.math.clamp(y, 0, maxScroll(n));
            e.set.append(std.testing.allocator, @round(n.scroll_y)) catch unreachable;
        }
        fn frames(e: *@This(), count: usize) void {
            for (0..count) |_| {
                test_now.? += 1000.0 / 60.0;
                e.hooks.run(e, 1000.0 / 60.0);
            }
        }
    };
    const measure = struct {
        fn f(_: *anyopaque, _: *Node, _: f32, out: *[2]f32) void {
            out.* = .{ 10, 10 };
        }
    }.f;
    var ctx: u8 = 0;
    var e: Fake = .{ .tree = tree_mod.Tree.init(std.testing.allocator, &ctx, measure) };
    defer {
        e.tree.deinit();
        e.hooks.deinit(std.testing.allocator);
        e.set.deinit(std.testing.allocator);
        test_now = null;
    }
    const V = ui.View("<column id=\"page\" scroll=\"true\" width=\"400\" height=\"600\"><view height=\"3000\" shrink=\"0\" /></column>");
    try V.prepare(&e.tree, 10);
    _ = try V.mount(&e.tree, 1, 10, &.{});
    const page = e.tree.get(1).?;
    e.tree.root = page;
    e.tree.width = 400;
    e.tree.height = 600;
    e.tree.layout();
    try std.testing.expectEqual(@as(f32, 2400), maxScroll(page));
    test_now = 1000;
    const key = struct {
        fn press(f: *Fake, k: []const u8) !bool {
            return keyScroll(Fake, f, null, f.tree.root, k, false);
        }
    }.press;

    try std.testing.expect(try key(&e, "PageDown"));
    try std.testing.expectEqual(@as(usize, 0), e.set.items.len); // on the next frame
    e.frames(1);
    try std.testing.expect(e.set.items[0] > 0 and e.set.items[0] < 525 * 0.1); // a slow start
    e.frames(10);
    try std.testing.expect(e.set.items[10] < 525); // still going at 11 frames
    e.frames(1);
    try std.testing.expectEqual(@as(f32, 525), e.set.items[e.set.items.len - 1]); // 87.5% at 200 ms
    for (e.set.items[1..], e.set.items[0 .. e.set.items.len - 1]) |b, a| try std.testing.expect(b >= a);
    const n = e.set.items.len;
    e.frames(3);
    try std.testing.expectEqual(n, e.set.items.len); // then it stops

    // A second PageDown while it glides: on to two pages from there.
    e.set.clearRetainingCapacity();
    _ = try key(&e, "PageDown");
    e.frames(4);
    _ = try key(&e, "PageDown");
    e.frames(20);
    try std.testing.expectEqual(@as(f32, 525 * 3), e.set.items[e.set.items.len - 1]);

    // An arrow: 40px over 256 ms (20 ms in).
    e.set.clearRetainingCapacity();
    _ = try key(&e, "ArrowDown");
    e.frames(15);
    try std.testing.expect(e.set.items[e.set.items.len - 1] < 525 * 3 + 40);
    e.frames(3);
    try std.testing.expectEqual(@as(f32, 525 * 3 + 40), e.set.items[e.set.items.len - 1]);

    // A wheel (the engine's scrollBy) stops it.
    e.set.clearRetainingCapacity();
    _ = try key(&e, "PageUp");
    e.frames(3);
    var k = e.set.items.len;
    e.glide.stopFor(page.id);
    e.frames(5);
    try std.testing.expectEqual(k, e.set.items.len);

    // A touch going down stops it.
    _ = try key(&e, "PageDown");
    e.frames(2);
    k = e.set.items.len;
    e.glide.stopOnTouch("pointer", "[\"down\",10,10,1,1,\"touch\",0]");
    e.frames(5);
    try std.testing.expectEqual(k, e.set.items.len);

    // A key right after a stop: still one frame callback driving it.
    _ = try key(&e, "PageDown");
    e.glide.stopFor(page.id);
    _ = try key(&e, "PageDown");
    try std.testing.expectEqual(@as(usize, 1), e.hooks.list.items.len);
    e.frames(30);
    try std.testing.expectEqual(@as(usize, 0), e.hooks.list.items.len);
    try std.testing.expect(!e.glide.hooked);

    // Not a scrolling key, or already at the end: not taken.
    try std.testing.expect(!try key(&e, "a"));
    page.scroll_y = 0;
    try std.testing.expect(!try key(&e, "Home"));
}
