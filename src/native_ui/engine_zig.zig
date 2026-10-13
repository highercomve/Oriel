//! Native tree and platform lifecycle driven by Zig, without QuickJS/DOM.
const std = @import("std");
const internal = @import("../core/internal.zig");
pub const Tree = @import("tree.zig").Tree;
pub const Node = @import("tree.zig").Node;
pub const Asset = @import("../core/App.zig").Asset;
pub const drop = @import("drop.zig");
const focus = @import("focus.zig");
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
    /// Keyboard focus (focus.zig).
    focus: focus.State = .{},
    pub const FrameHook = struct { ctx: *anyopaque, func: *const fn (*anyopaque, *Engine, f64) bool, run_after: u64 = 0, cancelled: bool = false };
    pub const drag_copy: u8 = 1;
    pub const drag_move: u8 = 2;
    pub const drag_link: u8 = 4;
    const frame_timer: u32 = std.math.maxInt(u32) - 1;

    pub fn create(gpa: std.mem.Allocator, backend: Backend, assets: []const Asset, platform_json: [:0]const u8, _: [:0]const u8, _: [:0]const u8, width: f32, height: f32) !*Engine {
        const driver = configured_driver orelse return error.MissingZigUiDriver;
        const e = try gpa.create(Engine);
        errdefer gpa.destroy(e);
        e.* = .{ .gpa = gpa, .tree = Tree.init(gpa, backend.ctx, backend.measure), .backend = backend, .driver = driver, .assets = assets, .drops = .init(gpa), .serial = @as(u64, next_serial.fetchAdd(1, .monotonic)) + 1 };
        errdefer e.tree.deinit();
        e.tree.width = width;
        e.tree.height = height;
        e.tree.controls = nativeControls(gpa, platform_json);
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
    /// A backend event: the engine's own bookkeeping (focus, field values,
    /// checkboxes), then the app's `Driver.event`, then the default action
    /// it didn't prevent (Tab, Enter/Space, scrolling keys). True: handled.
    pub fn event(e: *Engine, id: i64, kind: []const u8, data: []const u8) bool {
        e.in_call += 1;
        defer {
            e.in_call -= 1;
            e.paintNow();
        }
        const handled = e.dispatch(id, kind, data) catch |err| blk: {
            log.err("event {s}: {s}", .{ kind, @errorName(err) });
            break :blk false;
        };
        e.focus.visible = e.focus.visible and e.tree.get(e.focus.id) != null;
        e.updateRing();
        return handled;
    }

    fn appEvent(e: *Engine, id: i64, kind: []const u8, data: []const u8) bool {
        const cb = e.driver.event orelse return false;
        return cb(e, id, kind, data);
    }

    fn dispatch(e: *Engine, id: i64, kind: []const u8, data: []const u8) !bool {
        const eq = std.mem.eql;
        const n = e.tree.get(id);
        if (eq(u8, kind, "accent")) {
            const v = std.json.parseFromSlice([3]f32, e.gpa, data, .{}) catch null;
            if (v) |c| {
                defer c.deinit();
                e.focus.accent = c.value;
                if (e.focus.ring != 0) {
                    const ring_id = e.focus.ring;
                    e.focus.ring = 0;
                    if (e.tree.get(ring_id)) |r| {
                        var props = r.props;
                        props.ol = null;
                        try e.tree.updateUiProps(ring_id, props);
                    }
                }
            }
            return e.appEvent(id, kind, data);
        }
        // A field's edit: its value is the node's before the app hears of it.
        if ((eq(u8, kind, "input") or eq(u8, kind, "change")) and n != null and (n.?.kind == .input or n.?.kind == .textarea or n.?.kind == .select)) {
            if (try focus.editedValue(e.gpa, data)) |v| {
                defer v.deinit();
                try e.tree.acceptUiValue(id, focus.valueOf(v.value));
            }
            return e.appEvent(id, kind, data);
        }
        if (eq(u8, kind, "focus") and n != null) {
            e.focus.id = id;
            e.focus.visible = true;
            return e.appEvent(id, kind, data);
        }
        if (eq(u8, kind, "blur")) {
            if (e.focus.id == id) e.focus.id = 0;
            return e.appEvent(id, kind, data);
        }
        if (eq(u8, kind, "click")) {
            // A click focuses what it lands in, without a ring.
            if (focus.focusTarget(&e.tree, id)) |target| {
                if (!focus.isNative(target)) {
                    e.focus.id = target.id;
                    e.focus.visible = false;
                }
            }
            if (n) |node| if (node.kind == .check or node.props.ctl != null) {
                // A checkbox or radio checks itself; the app hears "change".
                const on = try focus.toggle(&e.tree, node);
                return e.appEvent(id, "change", if (on) "true" else "false");
            };
            return e.appEvent(id, kind, data);
        }
        if (eq(u8, kind, "key") or eq(u8, kind, "keyup")) {
            if (e.appEvent(id, kind, data)) return true;
            var name: [32]u8 = undefined;
            const key = focus.keyOf(e.gpa, data, &name) orelse return false;
            return e.keyDefault(eq(u8, kind, "key"), key.key, key.mods);
        }
        return e.appEvent(id, kind, data);
    }

    /// What a key does when the app didn't prevent it.
    fn keyDefault(e: *Engine, down: bool, key: []const u8, mods: i64) !bool {
        const eq = std.mem.eql;
        const focused = e.tree.get(e.focus.id);
        if (down and eq(u8, key, "Tab")) {
            const target = try focus.next(&e.tree, e.gpa, e.focus.id, focus.isShift(mods)) orelse return false;
            e.focus.id = target.id;
            e.focus.visible = true;
            e.backend.focus(e.backend.ctx, target);
            e.tree.scrollIntoView(target, "nearest");
            return true;
        }
        // Keys typed in a field are the field's.
        if (focused) |f| if (f.kind == .input or f.kind == .textarea or f.kind == .select) return false;
        // Enter (on press) and Space (on release) activate a drawn element;
        // a native widget handles its own.
        if (focused) |f| if (!focus.isNative(f)) {
            const enter = eq(u8, key, "Enter");
            const space = eq(u8, key, " ");
            if (space and down) return true; // not a page scroll
            if ((enter and down) or (space and !down)) {
                e.focus.visible = true;
                if (f.props.ctl != null) {
                    const on = try focus.toggle(&e.tree, f);
                    _ = e.appEvent(f.id, "change", if (on) "true" else "false");
                } else _ = e.appEvent(f.id, "click", "0");
                return true;
            }
        };
        if (!down) return false;
        const scroller = focus.scrollerFor(&e.tree, e.focus.id) orelse return false;
        const dy = focus.scrollDelta(scroller, key) orelse return false;
        _ = e.scrollBy(scroller, dy);
        return true;
    }

    fn updateRing(e: *Engine) void {
        focus.updateRing(&e.tree, &e.focus) catch |err| log.err("focus ring: {s}", .{@errorName(err)});
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

/// Which of `.check` and `.button` the backend hosts as platform widgets
/// (its platform JSON's `controls`, as render.js reads it).
fn nativeControls(gpa: std.mem.Allocator, platform_json: []const u8) @FieldType(Tree, "controls") {
    var out: @FieldType(Tree, "controls") = .{ .check = false, .button = false };
    const parsed = std.json.parseFromSlice(struct { controls: []const []const u8 = &.{} }, gpa, platform_json, .{ .ignore_unknown_fields = true }) catch return out;
    defer parsed.deinit();
    for (parsed.value.controls) |c| {
        if (std.mem.eql(u8, c, "check")) out.check = true;
        if (std.mem.eql(u8, c, "button")) out.button = true;
    }
    return out;
}

test nativeControls {
    const gpa = std.testing.allocator;
    const both = nativeControls(gpa, "{\"os\":\"linux\",\"controls\":[\"check\",\"button\"]}");
    try std.testing.expect(both.check and both.button);
    const ios = nativeControls(gpa, "{\"controls\":[\"button\"]}");
    try std.testing.expect(!ios.check and ios.button);
    const none = nativeControls(gpa, "{}");
    try std.testing.expect(!none.check and !none.button);
}

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
