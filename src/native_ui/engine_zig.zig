//! Native tree and platform lifecycle driven by Zig, without QuickJS/DOM.
const std = @import("std");
const internal = @import("../core/internal.zig");
pub const Tree = @import("tree.zig").Tree;
pub const Node = @import("tree.zig").Node;
pub const Asset = @import("../core/App.zig").Asset;
pub const drop = @import("drop.zig");
const focus = @import("focus.zig");
const interaction = @import("interaction.zig");
pub const Backend = @import("backend.zig").Backend(Engine);
pub const FontSpec = @import("backend.zig").FontSpec;
const core = @import("engine_core.zig");
const log = std.log.scoped(.zig_ui);
const registry = core.Registry(Engine);

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
    frame_pending: bool = false,
    relaid: bool = false,
    frame_hooks: core.FrameHooks(Engine) = .{},
    /// Keyboard focus (focus.zig), the platform's input rules' facts and a
    /// key scroll's glide (interaction.zig).
    focus: focus.State = .{},
    platform: interaction.Platform = .{},
    glide: interaction.Glide = .{},
    pub const FrameHook = core.FrameHooks(Engine).Hook;
    pub const drag_copy: u8 = 1;
    pub const drag_move: u8 = 2;
    pub const drag_link: u8 = 4;

    pub fn create(gpa: std.mem.Allocator, backend: Backend, assets: []const Asset, platform_json: [:0]const u8, _: [:0]const u8, _: [:0]const u8, width: f32, height: f32) !*Engine {
        const driver = configured_driver orelse return error.MissingZigUiDriver;
        const e = try gpa.create(Engine);
        errdefer gpa.destroy(e);
        e.* = .{ .gpa = gpa, .tree = Tree.init(gpa, backend.ctx, backend.measure), .backend = backend, .driver = driver, .assets = assets, .drops = .init(gpa), .serial = registry.newSerial() };
        errdefer e.tree.deinit();
        core.hookTree(e, width, height);
        e.tree.controls = nativeControls(gpa, platform_json);
        e.platform = interaction.Platform.parse(gpa, platform_json);
        try registry.add(e);
        return e;
    }

    pub fn bySerial(serial: u64) ?*Engine {
        return registry.get(serial);
    }
    pub fn busy(e: *const Engine) bool {
        return e.in_call > 0 or e.frame_hooks.running;
    }
    pub fn destroy(e: *Engine) void {
        std.debug.assert(!e.busy());
        registry.remove(e.serial);
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
            e.show();
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
        e.glide.stopOnTouch(kind, data);
        if (eq(u8, kind, "accent")) {
            e.platform.setAccent(e.gpa, data);
            try focus.clearRing(&e.tree, &e.focus);
        } else if (eq(u8, kind, "input") or eq(u8, kind, "change")) {
            try e.fieldEdited(id, data);
        } else if (eq(u8, kind, "focus")) {
            if (e.tree.get(id) != null) {
                e.focus.id = id;
                e.focus.visible = true;
            }
        } else if (eq(u8, kind, "blur")) {
            if (e.focus.id == id) e.focus.id = 0;
        } else if (eq(u8, kind, "click")) {
            return e.clicked(id, data);
        } else if (eq(u8, kind, "key") or eq(u8, kind, "keyup")) {
            if (e.appEvent(id, kind, data)) return true;
            var name: [32]u8 = undefined;
            const key = focus.keyOf(e.gpa, data, &name) orelse return false;
            return e.keyDefault(eq(u8, kind, "key"), key);
        }
        return e.appEvent(id, kind, data);
    }

    /// A field's edit: its value is the node's before the app hears of it.
    fn fieldEdited(e: *Engine, id: i64, data: []const u8) !void {
        const n = e.tree.get(id) orelse return;
        if (!focus.isField(n)) return;
        const v = try focus.editedValue(e.gpa, data) orelse return;
        defer v.deinit();
        try e.tree.acceptUiValue(id, focus.valueOf(v.value));
    }

    /// A click focuses what it lands in, without a ring, where the
    /// platform's click does (WebKit on macOS and iOS: fields and what has a
    /// tabindex only); a checkbox or radio checks itself and the app hears
    /// "change" instead.
    fn clicked(e: *Engine, id: i64, data: []const u8) !bool {
        if (focus.focusTarget(&e.tree, id)) |target| {
            if (!focus.isNative(target) and interaction.clickFocuses(interaction.tabRule(e.platform), focus.kindOf(target), target.props.ti != null)) {
                e.focus.id = target.id;
                e.focus.visible = false;
                e.backend.focus(e.backend.ctx, target);
            }
        }
        // Focusing can run the app's code (a field's "blur"), which may
        // have removed the node: look it up again.
        if (e.tree.get(id)) |node| if (node.kind == .check or node.props.ctl != null) {
            const on = try focus.toggle(&e.tree, node);
            return e.appEvent(id, "change", if (on) "true" else "false");
        };
        return e.appEvent(id, "click", data);
    }

    /// What a key does when the app didn't prevent it (interaction.zig's
    /// rules: Tab's order, activation, scrolling).
    fn keyDefault(e: *Engine, down: bool, key: focus.Key) !bool {
        const eq = std.mem.eql;
        const mods = key.mods & (2 | 4 | 8) != 0;
        if (down and !mods and eq(u8, key.key, "Tab")) {
            if (e.tree.needsLayout()) {
                e.tree.layout();
                e.relaid = true;
            }
            const cands = try focus.candidates(&e.tree, e.gpa);
            defer e.gpa.free(cands);
            const active: ?i64 = if (e.focus.id != 0) e.focus.id else null;
            const next_id = try interaction.tabNext(e.gpa, interaction.tabRule(e.platform), cands, active, key.mods & 1 != 0) orelse return false;
            const target = e.tree.get(next_id) orelse return false;
            e.focus.id = target.id;
            e.focus.visible = true;
            e.backend.focus(e.backend.ctx, target);
            e.glide.active = false;
            // Focusing can run the app's code (a field's "blur"), which may
            // have removed the target: look it up again.
            if (e.tree.get(next_id)) |focused| e.tree.scrollIntoView(focused, "nearest");
            return true;
        }
        const focused = e.tree.get(e.focus.id);
        // Keys typed in a field are the field's.
        if (focused) |f| if (focus.isField(f)) return false;
        // Enter and Space on a drawn element (a native widget handles its
        // own), still enabled, shown and in the tree after the app's handler.
        if (focused) |f| if (!focus.isNative(f) and !mods) {
            if (!focus.focusable(&e.tree, f)) return false;
            const space = eq(u8, key.key, " ");
            if (space and down) {
                e.focus.space = f.id;
                return true; // its release activates it; no page scroll
            }
            if (space) {
                const pressed_here = e.focus.space == f.id;
                e.focus.space = 0;
                if (!pressed_here) return false;
            }
            const checkable = f.props.ctl != null;
            if (interaction.activates(key.key, down, key.repeat, focus.isDrawnButton(f), false, checkable)) {
                e.focus.visible = true;
                if (checkable) {
                    const on = try focus.toggle(&e.tree, f);
                    _ = e.appEvent(f.id, "change", if (on) "true" else "false");
                } else _ = e.appEvent(f.id, "click", "0");
                return true;
            }
        };
        if (!down or mods) return false;
        // Else the window's scroller: the first in the view (its root may
        // only lay out a header and a scrolling body).
        return core.keyScroll(Engine, e, focused, focus.firstScroller(&e.tree), key.key, key.mods & 1 != 0);
    }

    fn updateRing(e: *Engine) void {
        focus.updateRing(&e.tree, &e.focus, e.platform) catch |err| log.err("focus ring: {s}", .{@errorName(err)});
    }
    pub fn timerFired(e: *Engine, id: u32) void {
        if (id == core.display_frame_timer) return e.displayFrame(1000.0 / 60.0);
        e.in_call += 1;
        if (e.driver.timer) |cb| cb(e, id) catch |err| log.err("timer: {s}", .{@errorName(err)});
        e.in_call -= 1;
        e.show();
    }
    pub fn displayFrame(e: *Engine, interval_ms: f64) void {
        e.flushScrolls();
        e.frame_hooks.run(e, interval_ms);
        if (e.frame_hooks.any()) e.requestDisplayFrame();
        e.paintNow();
    }
    /// Lay out and draw what changed, now.
    pub fn paintNow(e: *Engine) void {
        core.layoutAndShow(e);
    }
    /// What an event, timer or reply changed: drawn at the next frame
    /// when the backend paces frames (one layout however many came), else now.
    fn show(e: *Engine) void {
        if (!core.deferToFrame(e)) core.layoutAndShow(e);
    }
    pub fn addFrameHook(e: *Engine, hook: FrameHook) !void {
        try e.frame_hooks.add(e.gpa, hook);
        e.requestDisplayFrame();
    }
    pub fn removeFrameHooks(e: *Engine, ctx: *anyopaque) void {
        e.frame_hooks.remove(ctx);
    }
    fn requestDisplayFrame(e: *Engine) void {
        core.requestDisplayFrame(e);
    }
    pub fn frame(e: *Engine) void {
        e.frame_pending = false;
        if (e.in_call > 0) return; // that call shows it when it returns
        core.layoutAndShow(e);
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
    /// A wheel or touch scroll: a key scroll's glide there stops.
    pub fn scrollBy(e: *Engine, n: *Node, dy: f32) bool {
        e.glide.stopFor(n.id);
        return e.scrolled(n, core.moveScroll(e, n, .y, dy));
    }
    pub fn scrollByX(e: *Engine, n: *Node, dx: f32) bool {
        e.glide.stopFor(n.id);
        return e.scrolled(n, core.moveScroll(e, n, .x, dx));
    }
    /// The glide's own scroll (interaction.Glider).
    pub fn setScrollY(e: *Engine, n: *Node, y: f32) void {
        _ = e.scrolled(n, core.moveScroll(e, n, .y, y - n.scroll_y));
    }
    /// A scroller moved: the app hears of it at once (a virtual list mounts
    /// the rows now in view), then it's drawn.
    fn scrolled(e: *Engine, n: *Node, moved: bool) bool {
        if (!moved) return false;
        e.in_call += 1;
        if (e.driver.scrolled) |cb| cb(e, n.id) catch |err| log.err("scroll: {s}", .{@errorName(err)});
        e.in_call -= 1;
        e.relaid = true;
        core.layoutAndShow(e);
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
        e.show();
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
    try std.testing.expectEqual(@as(usize, 0), e.frame_hooks.list.items.len);
    var other: usize = 0;
    try e.addFrameHook(.{ .ctx = &calls, .func = Fake.cancel_self });
    try e.addFrameHook(.{ .ctx = &calls, .func = Fake.late });
    try e.addFrameHook(.{ .ctx = &other, .func = Fake.late });
    e.displayFrame(16.67);
    try std.testing.expectEqual(@as(usize, 1), other);
    try std.testing.expectEqual(@as(usize, 0), e.frame_hooks.list.items.len);
    e.resolve(42, false, "failure");
}
