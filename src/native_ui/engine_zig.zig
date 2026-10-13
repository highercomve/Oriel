//! Native tree and platform lifecycle driven by Zig, without QuickJS/DOM.
const std = @import("std");
const internal = @import("../core/internal.zig");
pub const Tree = @import("tree.zig").Tree;
pub const Node = @import("tree.zig").Node;
pub const Asset = @import("../core/App.zig").Asset;
pub const drop = @import("drop.zig");
pub const Backend = @import("backend.zig").Backend(Engine);
pub const FontSpec = @import("backend.zig").FontSpec;
const log = std.log.scoped(.zig_ui);
var next_serial: std.atomic.Value(usize) = .init(0);
var live: std.AutoHashMapUnmanaged(u64, *Engine) = .empty;

pub const Driver = struct {
    boot: *const fn (*Engine) anyerror!void,
    event: ?*const fn (*Engine, i64, []const u8, []const u8) bool = null,
    timer: ?*const fn (*Engine, u32) anyerror!void = null,
    resized: ?*const fn (*Engine) anyerror!void = null,
    shutdown: ?*const fn (*Engine) void = null,
    resolved: ?*const fn (*Engine, u32, bool, []const u8) anyerror!void = null,
    scrolled: ?*const fn (*Engine, i64) anyerror!void = null,
};
/// Configure on the UI thread before starting the app. Each engine takes a copy.
pub var configured_driver: ?Driver = null;

pub const Engine = struct {
    gpa: std.mem.Allocator,
    tree: Tree,
    backend: Backend,
    driver: Driver,
    assets: []const Asset,
    drops: drop.DropFiles,
    serial: u64,
    booted: bool = false,
    dark: ?bool = null,
    coarse: bool = false,
    in_call: u32 = 0,
    in_frame_hooks: bool = false,
    frame_pending: bool = false,
    relaid: bool = false,
    frame_hooks: std.ArrayList(FrameHook) = .empty,
    frame_number: u64 = 0,
    pub const FrameHook = struct { ctx: *anyopaque, func: *const fn (*anyopaque, *Engine, f64) bool, run_after: u64 = 0, cancelled: bool = false };
    pub const drag_copy: u8 = 1;
    pub const drag_move: u8 = 2;
    pub const drag_link: u8 = 4;
    const frame_timer: u32 = std.math.maxInt(u32) - 1;

    pub fn create(gpa: std.mem.Allocator, backend: Backend, assets: []const Asset, _: [:0]const u8, _: [:0]const u8, _: [:0]const u8, width: f32, height: f32) !*Engine {
        const driver = configured_driver orelse return error.MissingZigUiDriver;
        const e = try gpa.create(Engine);
        errdefer gpa.destroy(e);
        e.* = .{ .gpa = gpa, .tree = Tree.init(gpa, backend.ctx, backend.measure), .backend = backend, .driver = driver, .assets = assets, .drops = .init(gpa), .serial = @as(u64, next_serial.fetchAdd(1, .monotonic)) + 1 };
        errdefer e.tree.deinit();
        e.tree.width = width;
        e.tree.height = height;
        e.tree.on_remove = backend.removed;
        e.tree.on_props = backend.props;
        e.tree.on_ax = backend.ax_changed;
        e.tree.on_text = backend.text;
        e.tree.measure_texts = backend.measure_texts;
        e.tree.on_leaf_style = backend.leaf_style;
        e.tree.on_create = backend.leaf;
        e.tree.on_paint = backend.paint;
        e.tree.on_canvas = backend.canvas;
        try live.put(std.heap.smp_allocator, e.serial, e);
        return e;
    }

    pub fn bySerial(serial: u64) ?*Engine {
        return live.get(serial);
    }
    pub fn busy(e: *const Engine) bool {
        return e.in_call > 0 or e.in_frame_hooks;
    }
    pub fn destroy(e: *Engine) void {
        std.debug.assert(!e.busy());
        _ = live.remove(e.serial);
        if (e.driver.shutdown) |cb| cb(e);
        e.frame_hooks.deinit(e.gpa);
        e.drops.deinit();
        e.tree.deinit();
        if (e.backend.deinit) |cb| cb(e.backend.ctx);
        e.gpa.destroy(e);
    }
    pub fn boot(e: *Engine, dark: bool, coarse: bool) void {
        e.dark = dark;
        e.coarse = coarse;
        e.driver.boot(e) catch |err| {
            log.err("boot: {s}", .{@errorName(err)});
            return;
        };
        e.booted = true;
        e.paintNow();
        log.info(".oriel view booted: {d} nodes, no JavaScript runtime", .{e.tree.nodes.count()});
    }
    pub fn event(e: *Engine, id: i64, kind: []const u8, data: []const u8) bool {
        const cb = e.driver.event orelse return false;
        e.in_call += 1;
        const handled = cb(e, id, kind, data);
        e.in_call -= 1;
        e.paintNow();
        return handled;
    }
    pub fn timerFired(e: *Engine, id: u32) void {
        if (id == frame_timer) return e.displayFrame(1000.0 / 60.0);
        e.in_call += 1;
        if (e.driver.timer) |cb| cb(e, id) catch |err| log.err("timer: {s}", .{@errorName(err)});
        e.in_call -= 1;
        e.paintNow();
    }
    pub fn displayFrame(e: *Engine, interval_ms: f64) void {
        e.frame_number += 1;
        e.flushScrolls();
        e.in_frame_hooks = true;
        var i: usize = 0;
        while (i < e.frame_hooks.items.len) {
            const h = e.frame_hooks.items[i];
            if (h.cancelled) {
                _ = e.frame_hooks.orderedRemove(i);
                continue;
            }
            if (h.run_after > e.frame_number) {
                i += 1;
                continue;
            }
            const keep = h.func(h.ctx, e, interval_ms);
            if (keep and !e.frame_hooks.items[i].cancelled) i += 1 else _ = e.frame_hooks.orderedRemove(i);
        }
        e.in_frame_hooks = false;
        if (e.frame_hooks.items.len > 0) e.requestDisplayFrame();
        e.paintNow();
    }
    pub fn paintNow(e: *Engine) void {
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
    pub fn addFrameHook(e: *Engine, hook: FrameHook) !void {
        var pending = hook;
        pending.run_after = e.frame_number + @intFromBool(e.in_frame_hooks);
        try e.frame_hooks.append(e.gpa, pending);
        e.requestDisplayFrame();
    }
    pub fn removeFrameHooks(e: *Engine, ctx: *anyopaque) void {
        var i: usize = 0;
        while (i < e.frame_hooks.items.len) {
            if (e.frame_hooks.items[i].ctx != ctx) {
                i += 1;
            } else if (e.in_frame_hooks) {
                e.frame_hooks.items[i].cancelled = true;
                i += 1;
            } else _ = e.frame_hooks.orderedRemove(i);
        }
    }
    fn requestDisplayFrame(e: *Engine) void {
        if (e.backend.request_display_frame) |cb| cb(e.backend.ctx) else e.backend.add_timer(e.backend.ctx, e, frame_timer, 17);
    }
    pub fn frame(e: *Engine) void {
        e.frame_pending = false;
        e.paintNow();
    }
    pub fn resize(e: *Engine, width: f32, height: f32, dark: bool) void {
        if (width == e.tree.width and height == e.tree.height and dark == e.dark) return;
        e.tree.width = width;
        e.tree.height = height;
        e.dark = dark;
        e.tree.dirty = true;
        if (e.driver.resized) |cb| cb(e) catch |err| log.err("resize: {s}", .{@errorName(err)});
        e.paintNow();
    }
    pub fn scrollBy(e: *Engine, n: *Node, dy: f32) bool {
        const before = n.scroll_y;
        n.scroll_y = std.math.clamp(before + dy, 0, @max(0, n.content_h - n.frame.h));
        if (before == n.scroll_y) return false;
        e.tree.noteScroll(n);
        e.tree.replace();
        e.in_call += 1;
        if (e.driver.scrolled) |cb| cb(e, n.id) catch |err| log.err("scroll: {s}", .{@errorName(err)});
        e.in_call -= 1;
        e.relaid = true;
        e.paintNow();
        return true;
    }
    pub fn scrollByX(e: *Engine, n: *Node, dx: f32) bool {
        const before = n.scroll_x;
        n.scroll_x = std.math.clamp(before + dx, 0, @max(0, n.content_w - n.frame.w));
        if (before == n.scroll_x) return false;
        e.tree.noteScroll(n);
        e.tree.replace();
        e.in_call += 1;
        if (e.driver.scrolled) |cb| cb(e, n.id) catch |err| log.err("scroll: {s}", .{@errorName(err)});
        e.in_call -= 1;
        e.relaid = true;
        e.paintNow();
        return true;
    }
    pub fn flushScrolls(e: *Engine) void {
        for (e.tree.scrolled.items) |id| if (e.tree.get(id)) |n| {
            n.scroll_noted = false;
        };
        e.tree.scrolled.clearRetainingCapacity();
    }
    pub fn assetData(e: *Engine, path: []const u8) ?[]const u8 {
        return if (internal.findAsset(e.assets, path, false)) |a| a.data else null;
    }
    pub fn back(e: *Engine) bool {
        return e.event(0, "back", "null");
    }
    pub fn dragEvent(e: *Engine, id: i64, data: []const u8) u8 {
        _ = e.event(id, "drag", data);
        return 0;
    }
    pub fn setA11y(e: *Engine, on: bool) void {
        _ = on;
        if (e.backend.ax_changed) |cb| cb(e.backend.ctx, -1);
    }
    pub fn jsMemory(_: *Engine) usize {
        return 0;
    }
    pub fn collectGarbage(_: *Engine) void {}
    pub fn evalScript(_: *Engine, _: [:0]const u8) void {}
    pub fn message(e: *Engine, json: []const u8) void {
        _ = e.event(0, "message", json);
    }
    pub fn resolve(e: *Engine, id: u32, ok: bool, json: []const u8) void {
        e.in_call += 1;
        if (e.driver.resolved) |cb| cb(e, id, ok, json) catch |err| log.err("resolve: {s}", .{@errorName(err)});
        e.in_call -= 1;
        e.paintNow();
    }
    pub fn dropPathCommand(_: *Engine, _: std.mem.Allocator, _: []const u8) ![]u8 {
        return error.UnsupportedInZigUi;
    }
};

test "a display callback added during a frame runs on the following frame" {
    const Fake = struct {
        fn measure(_: *anyopaque, _: *Node, _: f32, out: *[2]f32) void {
            out.* = .{ 0, 0 };
        }
        fn laid(_: *anyopaque) void {}
        fn removed(_: *anyopaque, _: *Node) void {}
        fn timer(_: *anyopaque, _: *Engine, _: u32, _: u32) void {}
        fn invoke(_: *anyopaque, _: *Engine, _: u32, _: []const u8, _: []const u8) void {}
        fn focus(_: *anyopaque, _: *Node) void {}
        fn boot(_: *Engine) !void {}
        fn first(ctx: *anyopaque, e: *Engine, _: f64) bool {
            e.addFrameHook(.{ .ctx = ctx, .func = late }) catch unreachable;
            return false;
        }
        fn cancel_self(ctx: *anyopaque, e: *Engine, _: f64) bool {
            e.removeFrameHooks(ctx);
            return false;
        }
        fn resolved_test(e: *Engine, id: u32, ok: bool, json: []const u8) !void {
            try std.testing.expect(e.busy());
            try std.testing.expectEqual(@as(u32, 42), id);
            try std.testing.expect(!ok);
            try std.testing.expectEqualStrings("failure", json);
        }
        fn late(ctx: *anyopaque, _: *Engine, _: f64) bool {
            const calls: *usize = @ptrCast(@alignCast(ctx));
            calls.* += 1;
            return false;
        }
    };
    const saved = configured_driver;
    defer configured_driver = saved;
    configured_driver = .{ .boot = Fake.boot, .resolved = Fake.resolved_test };
    var calls: usize = 0;
    const e = try Engine.create(std.testing.allocator, .{ .ctx = &calls, .measure = Fake.measure, .laid_out = Fake.laid, .removed = Fake.removed, .add_timer = Fake.timer, .invoke = Fake.invoke, .focus = Fake.focus }, &.{}, "{}", "main", "bench.oriel", 900, 700);
    defer e.destroy();
    try e.addFrameHook(.{ .ctx = &calls, .func = Fake.first });
    e.displayFrame(16.67);
    try std.testing.expectEqual(@as(usize, 0), calls);
    e.displayFrame(16.67);
    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expectEqual(@as(usize, 0), e.frame_hooks.items.len);
    var other: usize = 0;
    try e.addFrameHook(.{ .ctx = &calls, .func = Fake.cancel_self });
    try e.addFrameHook(.{ .ctx = &calls, .func = Fake.late });
    try e.addFrameHook(.{ .ctx = &other, .func = Fake.late });
    e.displayFrame(16.67);
    try std.testing.expectEqual(@as(usize, 1), other);
    try std.testing.expectEqual(@as(usize, 0), e.frame_hooks.items.len);
    e.resolve(42, false, "failure");
}
