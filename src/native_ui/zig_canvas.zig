//! Canvas from Zig: the app's Zig code draws into a page's <canvas> on the
//! native renderer (-Dnative_ui), with no JavaScript per frame
//! (docs/native-renderer.md, "Canvas from Zig"). `oriel.canvas`.
//!
//!     const canvas = oriel.canvas;
//!     var c = canvas.Canvas.open(window, "game") orelse return; // <canvas id="game">
//!     var p = canvas.Program.init(gpa);
//!     defer p.deinit();
//!     try canvas.onFrame(window, &game, Game.frame); // each display frame
//!     // in Game.frame: p.begin(); p.fillStyle(canvas.rgb(0x10141b));
//!     //   p.fillRect(0, 0, w, h); ...; _ = c.commit(&p);
//!
//! A Program is the same drawing model as the page's 2d context (the
//! renderer's CanvasCmd list: paths, arcs, rects, text, transforms,
//! gradients), replayed by each backend as a page's canvas is. Build it on
//! any thread; commit on the UI thread (a frame callback runs there; from a
//! worker, hand the program over with App.runOnMain). At commit the tree
//! takes the program's memory and gives back the previous frame's, so a
//! program redrawn every frame allocates nothing once warm.
//!
//! Once Zig commits to a canvas, the page's own drawing into it (its 2d
//! context) is ignored until release(). The WebView has no such canvas:
//! open() returns null there, and the page draws with JavaScript.

const std = @import("std");
const tree_mod = @import("tree.zig");
const engine_mod = @import("engine.zig");
const target = @import("../core/target.zig");
const App = @import("../core/App.zig");

pub const Engine = engine_mod.Engine;
pub const Cmd = tree_mod.CanvasCmd;
pub const Font = tree_mod.CanvasFont;
/// r, g, b 0–255, alpha 0–1 (as the page's colors).
pub const Color = tree_mod.Color;

pub fn rgb(hex: u24) Color {
    return rgba(hex, 1);
}

pub fn rgba(hex: u24, alpha: f32) Color {
    return .{ @floatFromInt(hex >> 16), @floatFromInt((hex >> 8) & 0xff), @floatFromInt(hex & 0xff), alpha };
}

pub const Cap = enum(u2) { butt, round, square };
pub const Join = enum(u2) { miter, round, bevel };
pub const TextAlign = enum(u2) { left, center, right };
pub const Baseline = enum(u3) { alphabetic, top, hanging, middle, bottom };

/// One frame's drawing. Methods record (they don't fail: out of memory
/// marks the program, and commit refuses it).
pub const Program = struct {
    arena: std.heap.ArenaAllocator,
    cmds: std.ArrayList(Cmd) = .empty,
    next_gradient: u16 = 0,
    failed: bool = false,
    /// The last frame's length: the next begin() reserves as much.
    last_len: usize = 0,

    pub fn init(gpa: std.mem.Allocator) Program {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(p: *Program) void {
        p.arena.deinit();
        p.* = undefined;
    }

    /// Start a new frame's drawing (the last one's commands go).
    pub fn begin(p: *Program) void {
        _ = p.arena.reset(.{ .retain_with_limit = 4 << 20 });
        p.cmds = .empty;
        p.next_gradient = 0;
        p.failed = false;
        p.cmds.ensureTotalCapacity(p.arena.allocator(), p.last_len + 16) catch {
            p.failed = true;
        };
    }

    pub fn len(p: *const Program) usize {
        return p.cmds.items.len;
    }

    fn add(p: *Program, c: Cmd) void {
        p.cmds.append(p.arena.allocator(), c) catch {
            p.failed = true;
        };
    }

    fn dupe(p: *Program, s: []const u8) []const u8 {
        return p.arena.allocator().dupe(u8, s) catch blk: {
            p.failed = true;
            break :blk "";
        };
    }

    pub fn save(p: *Program) void {
        p.add(.save);
    }
    pub fn restore(p: *Program) void {
        p.add(.restore);
    }
    pub fn beginPath(p: *Program) void {
        p.add(.begin_path);
    }
    pub fn closePath(p: *Program) void {
        p.add(.close_path);
    }
    /// Fill the path (nonzero rule).
    pub fn fill(p: *Program) void {
        p.add(.{ .fill = false });
    }
    pub fn fillEvenOdd(p: *Program) void {
        p.add(.{ .fill = true });
    }
    pub fn stroke(p: *Program) void {
        p.add(.stroke);
    }
    pub fn clip(p: *Program) void {
        p.add(.{ .clip = false });
    }
    pub fn translate(p: *Program, x: f32, y: f32) void {
        p.add(.{ .translate = .{ x, y } });
    }
    pub fn scale(p: *Program, x: f32, y: f32) void {
        p.add(.{ .scale = .{ x, y } });
    }
    /// Radians.
    pub fn rotate(p: *Program, angle: f32) void {
        p.add(.{ .rotate = angle });
    }
    pub fn moveTo(p: *Program, x: f32, y: f32) void {
        p.add(.{ .move_to = .{ x, y } });
    }
    pub fn lineTo(p: *Program, x: f32, y: f32) void {
        p.add(.{ .line_to = .{ x, y } });
    }
    pub fn rect(p: *Program, x: f32, y: f32, w: f32, h: f32) void {
        p.add(.{ .rect = .{ x, y, w, h } });
    }
    /// Angles in radians, clockwise unless `ccw`.
    pub fn arc(p: *Program, x: f32, y: f32, r: f32, a0: f32, a1: f32, ccw: bool) void {
        p.add(.{ .arc = .{ .x = x, .y = y, .r = r, .a0 = a0, .a1 = a1, .ccw = ccw } });
    }
    /// A full circle as a path of its own (beginPath + arc).
    pub fn circle(p: *Program, x: f32, y: f32, r: f32) void {
        p.beginPath();
        p.arc(x, y, r, 0, 2 * std.math.pi, false);
    }
    pub fn bezierCurveTo(p: *Program, c1x: f32, c1y: f32, c2x: f32, c2y: f32, x: f32, y: f32) void {
        p.add(.{ .bezier_to = .{ c1x, c1y, c2x, c2y, x, y } });
    }
    pub fn fillRect(p: *Program, x: f32, y: f32, w: f32, h: f32) void {
        p.add(.{ .fill_rect = .{ x, y, w, h } });
    }
    pub fn strokeRect(p: *Program, x: f32, y: f32, w: f32, h: f32) void {
        p.add(.{ .stroke_rect = .{ x, y, w, h } });
    }
    pub fn clearRect(p: *Program, x: f32, y: f32, w: f32, h: f32) void {
        p.add(.{ .clear_rect = .{ x, y, w, h } });
    }
    /// The text is copied.
    pub fn fillText(p: *Program, text: []const u8, x: f32, y: f32) void {
        p.add(.{ .fill_text = .{ .t = p.dupe(text), .x = x, .y = y } });
    }
    pub fn strokeText(p: *Program, text: []const u8, x: f32, y: f32) void {
        p.add(.{ .stroke_text = .{ .t = p.dupe(text), .x = x, .y = y } });
    }
    pub fn fillStyle(p: *Program, c: Color) void {
        p.add(.{ .fill_style = .{ .color = c } });
    }
    pub fn strokeStyle(p: *Program, c: Color) void {
        p.add(.{ .stroke_style = .{ .color = c } });
    }
    /// A gradient made with linearGradient/radialGradient in this frame.
    pub fn fillGradient(p: *Program, gradient: u16) void {
        p.add(.{ .fill_style = .{ .grad = gradient } });
    }
    pub fn strokeGradient(p: *Program, gradient: u16) void {
        p.add(.{ .stroke_style = .{ .grad = gradient } });
    }
    pub fn lineWidth(p: *Program, w: f32) void {
        p.add(.{ .line_width = w });
    }
    pub fn lineCap(p: *Program, cap: Cap) void {
        p.add(.{ .line_cap = @intFromEnum(cap) });
    }
    pub fn lineJoin(p: *Program, join: Join) void {
        p.add(.{ .line_join = @intFromEnum(join) });
    }
    pub fn globalAlpha(p: *Program, a: f32) void {
        p.add(.{ .global_alpha = a });
    }
    /// `family`: a CSS family ("sans-serif", "monospace", a font's name);
    /// copied.
    pub fn font(p: *Program, size: f32, weight: f32, italic: bool, family: []const u8) void {
        p.add(.{ .font = .{ .size = size, .weight = weight, .italic = italic, .family = p.dupe(family) } });
    }
    pub fn textAlign(p: *Program, a: TextAlign) void {
        p.add(.{ .text_align = @intFromEnum(a) });
    }
    pub fn textBaseline(p: *Program, b: Baseline) void {
        p.add(.{ .text_baseline = @intFromEnum(b) });
    }
    /// A linear gradient for this frame: its id (fillGradient), with stops
    /// added by colorStop.
    pub fn linearGradient(p: *Program, x0: f32, y0: f32, x1: f32, y1: f32) u16 {
        p.next_gradient +%= 1;
        p.add(.{ .linear_gradient = .{ .id = p.next_gradient, .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 } });
        return p.next_gradient;
    }
    pub fn radialGradient(p: *Program, x0: f32, y0: f32, r0: f32, x1: f32, y1: f32, r1: f32) u16 {
        p.next_gradient +%= 1;
        p.add(.{ .radial_gradient = .{ .id = p.next_gradient, .x0 = x0, .y0 = y0, .r0 = r0, .x1 = x1, .y1 = y1, .r1 = r1 } });
        return p.next_gradient;
    }
    pub fn colorStop(p: *Program, gradient: u16, offset: f32, c: Color) void {
        p.add(.{ .color_stop = .{ .id = gradient, .off = offset, .c = c } });
    }
};

/// A page's <canvas>, by its id attribute, in one native window. A value:
/// it holds no pointer, so it stays safe after the window or the element
/// goes (commit then returns false).
pub const Canvas = struct {
    serial: u64,
    node: i64,
    eid_buf: [64]u8 = undefined,
    eid_len: u8 = 0,

    /// The <canvas id="element_id"> in `window`'s page (UI thread). Null:
    /// not a native window, or no such canvas (yet: the page renders it
    /// after it loads).
    pub fn open(window: *App.Window, element_id: []const u8) ?Canvas {
        return openIn(engineOf(window) orelse return null, element_id);
    }

    pub fn openIn(e: *Engine, element_id: []const u8) ?Canvas {
        if (element_id.len > 64) return null;
        const n = e.tree.canvasByEid(element_id) orelse return null;
        var c: Canvas = .{ .serial = e.serial, .node = n.id, .eid_len = @intCast(element_id.len) };
        @memcpy(c.eid_buf[0..element_id.len], element_id);
        return c;
    }

    pub fn elementId(c: *const Canvas) []const u8 {
        return c.eid_buf[0..c.eid_len];
    }

    /// Its engine and node now: the node is found again by the element's
    /// id when the page made a new one.
    fn resolve(c: *Canvas) ?struct { e: *Engine, n: *tree_mod.Node } {
        const e = Engine.bySerial(c.serial) orelse return null;
        if (e.tree.get(c.node)) |n| if (n.kind == .canvas) return .{ .e = e, .n = n };
        const n = e.tree.canvasByEid(c.elementId()) orelse return null;
        c.node = n.id;
        return .{ .e = e, .n = n };
    }

    /// Its drawing space (the element's width and height attributes, as
    /// the page's 2d context has it), or null if it's gone.
    pub fn size(c: *Canvas) ?[2]f32 {
        const r = c.resolve() orelse return null;
        return .{ r.n.props.cw orelse r.n.frame.w, r.n.props.ch orelse r.n.frame.h };
    }

    /// Show `p` (UI thread): the tree takes its commands and memory, and
    /// `p` gets the previous frame's memory back (call p.begin() before
    /// drawing again). False (nothing taken): the window or the canvas is
    /// gone, or `p` ran out of memory. The window draws it at its next
    /// paint; inside onFrame, at this frame's.
    pub fn commit(c: *Canvas, p: *Program) bool {
        if (p.failed) return false;
        const r = c.resolve() orelse return false;
        if (!r.e.tree.commitCanvas(r.n.id, p.cmds.items, &p.arena)) return false;
        p.last_len = p.cmds.items.len;
        p.cmds = .empty;
        // Outside a frame callback: show it now.
        if (r.e.in_call == 0 and !r.e.in_frame_hooks) r.e.paintNow();
        return true;
    }

    /// The page draws it again (its next 2d-context drawing replaces Zig's).
    pub fn release(c: *Canvas) void {
        const r = c.resolve() orelse return;
        r.e.tree.releaseCanvas(r.n.id);
    }
};

/// What a frame callback gets.
pub const Frame = struct {
    /// The display's refresh interval (0: unknown).
    interval_ms: f64,
};

/// Call `func(ctx, frame)` on the UI thread at each display frame of
/// `window` (its refresh rate), until it returns false or stopFrames.
/// `ctx` is a pointer the callback gets back; it must stay valid while the
/// callback runs (stopFrames before freeing it). Frames stop when no
/// callback (and no requestAnimationFrame) wants one.
pub fn onFrame(window: *App.Window, ctx: anytype, comptime func: fn (@TypeOf(ctx), Frame) bool) !void {
    const e = engineOf(window) orelse return error.NotNative;
    try onFrameIn(e, ctx, func);
}

pub fn onFrameIn(e: *Engine, ctx: anytype, comptime func: fn (@TypeOf(ctx), Frame) bool) !void {
    const Ctx = @TypeOf(ctx);
    if (@typeInfo(Ctx) != .pointer) @compileError("onFrame: ctx must be a pointer");
    const Thunk = struct {
        fn call(c: *anyopaque, _: *Engine, interval_ms: f64) bool {
            return func(@ptrCast(@alignCast(c)), .{ .interval_ms = interval_ms });
        }
    };
    try e.addFrameHook(.{ .ctx = @ptrCast(@constCast(ctx)), .func = Thunk.call });
}

/// Stop `ctx`'s frame callbacks in `window`.
pub fn stopFrames(window: *App.Window, ctx: anytype) void {
    const e = engineOf(window) orelse return;
    e.removeFrameHooks(@ptrCast(@constCast(ctx)));
}

/// The native renderer's engine of `window`, or null (a WebView window).
pub fn engineOf(window: *App.Window) ?*Engine {
    const h = window.handle;
    return switch (target.os) {
        .linux, .windows => @ptrCast(@alignCast(h.native orelse return null)),
        .macos => blk: {
            const Surface = @import("appkit.zig").Surface;
            const s: *Surface = @ptrCast(@alignCast(h.native orelse return null));
            break :blk s.engine;
        },
        .ios => blk: {
            const Surface = @import("uikit.zig").Surface;
            const s: *Surface = @ptrCast(@alignCast(h.native orelse return null));
            break :blk s.engine;
        },
        .android => @import("android.zig").engineOf(h.id),
        .other => null,
    };
}

test "a program records the 2d drawing, and commits into a tree's canvas" {
    if (!@import("build_options").native_ui) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var p = Program.init(gpa);
    defer p.deinit();
    var ctx: u8 = 0;
    const Measure = struct {
        fn m(_: *anyopaque, _: *tree_mod.Node, _: f32, out: *[2]f32) void {
            out.* = .{ 0, 0 };
        }
    };
    var t = tree_mod.Tree.init(gpa, &ctx, Measure.m);
    defer t.deinit();
    try t.apply(
        \\[["c",2,"canvas"],["p",2,{"eid":"g"}],["r",2]]
    );
    for (0..3) |frame| {
        p.begin();
        p.fillStyle(rgb(0x10141b));
        p.fillRect(0, 0, 100, 50);
        const g = p.linearGradient(0, 0, 100, 0);
        p.colorStop(g, 0, rgb(0xff0000));
        p.colorStop(g, 1, rgba(0x0000ff, 0.5));
        p.fillGradient(g);
        p.circle(10, 10, 6);
        p.fill();
        p.font(12, 400, false, "sans-serif");
        p.textBaseline(.top);
        var buf: [16]u8 = undefined;
        p.fillText(try std.fmt.bufPrint(&buf, "frame {d}", .{frame}), 8, 8);
        try std.testing.expect(!p.failed);
        const cmds = p.cmds.items;
        try std.testing.expect(t.commitCanvas(2, cmds, &p.arena));
        p.last_len = cmds.len;
        p.cmds = .empty;
        const n = t.get(2).?;
        try std.testing.expectEqual(@as(usize, 12), n.canvas.?.len);
        try std.testing.expectEqual(@as(f32, 255), n.canvas.?[3].color_stop.c[0]);
        try std.testing.expectEqual(@as(u16, 1), n.canvas.?[5].fill_style.grad);
        try std.testing.expectEqualStrings("sans-serif", n.canvas.?[9].font.family);
    }
    // The frame text, from the tree's copy.
    try std.testing.expectEqualStrings("frame 2", t.get(2).?.canvas.?[11].fill_text.t);
}
