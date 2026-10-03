//! The native renderer's node tree (docs/native-renderer.md): the operations
//! from the JS side (src/native_ui/js/src/render.js), one Yoga node per
//! native node, the CSS properties mapped onto Yoga, and the frames, scroll
//! offsets and clips the backends draw and hit-test with.

const std = @import("std");
pub const yg = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("yoga/Yoga.h");
});

const log = std.log.scoped(.native_ui);
const prof = @import("prof.zig");

pub const Kind = enum { view, text, input, textarea, select, icon, image, canvas };

pub const Color = [4]f32; // r, g, b 0-255; a 0-1

pub const Run = struct {
    t: []const u8,
    c: Color = .{ 0, 0, 0, 1 },
    sz: f32 = 16,
    w: f32 = 400,
    i: bool = false,
    mono: bool = false,
    u: bool = false,
    bg: ?Color = null,
};

// A text-only update owns its new string separately from the unchanged
// box/font props arena. Replaced in place, never accumulated per frame.
const TextOverride = struct { run: Run, text: []u8 };
const LeafStyle = struct { arena: std.heap.ArenaAllocator, props: Props, yn: yg.YGNodeRef };

/// A linear gradient (`angle`), or a radial one: `radial` is cx, cy, rx,
/// ry, each px (a number) or a percentage of the box ("50%").
pub const Gradient = struct { angle: f32 = 180, radial: ?[4]Dim = null, stops: []const [5]f32 = &.{} };
pub const Background = struct { color: ?Color = null, gradient: ?Gradient = null };
pub const Shadow = struct { x: f32 = 0, y: f32 = 0, blur: f32 = 0, spread: f32 = 0, color: Color = .{ 0, 0, 0, 0.3 } };
pub const Shape = struct {
    d: []const u8,
    fill: ?Color = null,
    stroke: ?Color = null,
    sw: f32 = 1,
    cap: []const u8 = "butt",
    join: []const u8 = "miter",
    evenodd: bool = false,
};
pub const Icon = struct { vb: [4]f32 = .{ 0, 0, 24, 24 }, shapes: []const Shape = &.{} };

/// One <canvas> 2d-context drawing op (src/native_ui/js/src/canvas.js):
/// the recorded program, replayed into the backend's draw pass each paint.
/// A paint is a color or a gradient id (`grads` in the canvas painter).
pub const CanvasPaint = union(enum) {
    color: Color,
    grad: u16,
};

pub const CanvasFont = struct { italic: bool = false, weight: f32 = 400, size: f32 = 10, family: []const u8 = "" };

pub const CanvasCmd = union(enum) {
    save,
    restore,
    begin_path,
    close_path,
    fill: bool, // evenodd
    stroke,
    clip: bool, // evenodd
    translate: [2]f32,
    scale: [2]f32,
    rotate: f32,
    move_to: [2]f32,
    line_to: [2]f32,
    rect: [4]f32,
    arc: struct { x: f32, y: f32, r: f32, a0: f32, a1: f32, ccw: bool },
    bezier_to: [6]f32,
    fill_rect: [4]f32,
    stroke_rect: [4]f32,
    clear_rect: [4]f32,
    fill_text: struct { t: []const u8, x: f32, y: f32 },
    stroke_text: struct { t: []const u8, x: f32, y: f32 },
    fill_style: CanvasPaint,
    stroke_style: CanvasPaint,
    line_width: f32,
    line_cap: u2, // butt, round, square
    line_join: u2, // miter, round, bevel
    global_alpha: f32,
    font: CanvasFont,
    text_align: u2, // left, center, right
    text_baseline: u3, // alphabetic, top, hanging, middle, bottom
    linear_gradient: struct { id: u16, x0: f32, y0: f32, x1: f32, y1: f32 },
    radial_gradient: struct { id: u16, x0: f32, y0: f32, r0: f32, x1: f32, y1: f32, r1: f32 },
    color_stop: struct { id: u16, off: f32, c: Color },
};

/// A canvas node's drawing program, parsed from its props' `cv` (kept on
/// the node, not in Props: it isn't one property, it's the whole program).
pub fn parseCanvasCmds(a: std.mem.Allocator, v: std.json.Value) ![]CanvasCmd {
    if (v != .array) return error.BadCmds;
    const items = v.array.items;
    var out: std.ArrayList(CanvasCmd) = .empty;
    errdefer out.deinit(a);
    try out.ensureTotalCapacity(a, items.len);
    for (items) |item| {
        if (item != .array or item.array.items.len == 0 or item.array.items[0] != .string) continue;
        const op = item.array.items;
        const tag = op[0].string;
        const x: f32 = numAt(op, 1);
        const y: f32 = numAt(op, 2);
        var c: ?CanvasCmd = null;
        if (std.mem.eql(u8, tag, "sv")) {
            c = .save;
        } else if (std.mem.eql(u8, tag, "rs")) {
            c = .restore;
        } else if (std.mem.eql(u8, tag, "bp")) {
            c = .begin_path;
        } else if (std.mem.eql(u8, tag, "cp")) {
            c = .close_path;
        } else if (std.mem.eql(u8, tag, "st")) {
            c = .stroke;
        } else if (std.mem.eql(u8, tag, "fl")) {
            c = .{ .fill = numAt(op, 1) != 0 };
        } else if (std.mem.eql(u8, tag, "cl")) {
            c = .{ .clip = numAt(op, 1) != 0 };
        } else if (std.mem.eql(u8, tag, "tl")) {
            c = .{ .translate = .{ x, y } };
        } else if (std.mem.eql(u8, tag, "ts")) {
            c = .{ .scale = .{ x, y } };
        } else if (std.mem.eql(u8, tag, "tr")) {
            c = .{ .rotate = x };
        } else if (std.mem.eql(u8, tag, "mv")) {
            c = .{ .move_to = .{ x, y } };
        } else if (std.mem.eql(u8, tag, "ln")) {
            c = .{ .line_to = .{ x, y } };
        } else if (std.mem.eql(u8, tag, "rc")) {
            c = .{ .rect = .{ x, y, numAt(op, 3), numAt(op, 4) } };
        } else if (std.mem.eql(u8, tag, "ar")) {
            c = .{ .arc = .{ .x = x, .y = y, .r = numAt(op, 3), .a0 = numAt(op, 4), .a1 = numAt(op, 5), .ccw = numAt(op, 6) != 0 } };
        } else if (std.mem.eql(u8, tag, "bz")) {
            c = .{ .bezier_to = .{ x, y, numAt(op, 3), numAt(op, 4), numAt(op, 5), numAt(op, 6) } };
        } else if (std.mem.eql(u8, tag, "fr")) {
            c = .{ .fill_rect = .{ x, y, numAt(op, 3), numAt(op, 4) } };
        } else if (std.mem.eql(u8, tag, "sr")) {
            c = .{ .stroke_rect = .{ x, y, numAt(op, 3), numAt(op, 4) } };
        } else if (std.mem.eql(u8, tag, "cr")) {
            c = .{ .clear_rect = .{ x, y, numAt(op, 3), numAt(op, 4) } };
        } else if (std.mem.eql(u8, tag, "tx") or std.mem.eql(u8, tag, "sx")) {
            if (op.len < 2 or op[1] != .string or op[1].string.len == 0) continue;
            const t = try a.dupe(u8, op[1].string);
            c = if (std.mem.eql(u8, tag, "tx"))
                .{ .fill_text = .{ .t = t, .x = numAt(op, 2), .y = numAt(op, 3) } }
            else
                .{ .stroke_text = .{ .t = t, .x = numAt(op, 2), .y = numAt(op, 3) } };
        } else if (std.mem.eql(u8, tag, "sf") or std.mem.eql(u8, tag, "ss")) {
            const paint = paintAt(op[1]) orelse continue;
            c = if (std.mem.eql(u8, tag, "sf")) CanvasCmd{ .fill_style = paint } else CanvasCmd{ .stroke_style = paint };
        } else if (std.mem.eql(u8, tag, "lw")) {
            c = .{ .line_width = x };
        } else if (std.mem.eql(u8, tag, "ga")) {
            c = .{ .global_alpha = x };
        } else if (std.mem.eql(u8, tag, "lc")) {
            c = .{ .line_cap = @intCast(wordAt(op, &.{ "butt", "round", "square" }, 2) orelse continue) };
        } else if (std.mem.eql(u8, tag, "lj")) {
            c = .{ .line_join = @intCast(wordAt(op, &.{ "miter", "round", "bevel" }, 2) orelse continue) };
        } else if (std.mem.eql(u8, tag, "ta")) {
            const i = wordAt(op, &.{ "left", "center", "right", "start", "end" }, 2) orelse continue;
            c = .{ .text_align = @intCast(if (i == 3) 0 else if (i == 4) 2 else i) };
        } else if (std.mem.eql(u8, tag, "tb")) {
            const i = wordAt(op, &.{ "alphabetic", "top", "hanging", "middle", "bottom", "ideographic" }, 4) orelse continue;
            c = .{ .text_baseline = @intCast(@min(4, i)) };
        } else if (std.mem.eql(u8, tag, "fo") and op.len > 4) {
            c = .{ .font = .{ .italic = numAt(op, 1) != 0, .weight = numAt(op, 2), .size = numAt(op, 3), .family = try a.dupe(u8, op[4].string) } };
        } else if (std.mem.eql(u8, tag, "gl") and op.len > 5) {
            // ["gl",id,x0,y0,x1,y1]: the points after the id.
            c = .{ .linear_gradient = .{ .id = gradId(op[1]), .x0 = numAt(op, 2), .y0 = numAt(op, 3), .x1 = numAt(op, 4), .y1 = numAt(op, 5) } };
        } else if (std.mem.eql(u8, tag, "gr") and op.len > 7) {
            // ["gr",id,x0,y0,r0,x1,y1,r1]
            c = .{ .radial_gradient = .{ .id = gradId(op[1]), .x0 = numAt(op, 2), .y0 = numAt(op, 3), .r0 = numAt(op, 4), .x1 = numAt(op, 5), .y1 = numAt(op, 6), .r1 = numAt(op, 7) } };
        } else if (std.mem.eql(u8, tag, "gs") and op.len > 6) {
            c = .{ .color_stop = .{ .id = gradId(op[1]), .off = numAt(op, 2), .c = .{ numAt(op, 3), numAt(op, 4), numAt(op, 5), numAt(op, 6) } } };
        }
        // A call with an argument that isn't finite (or overflows f32) is
        // ignored, as a browser's canvas does.
        const finite = for (op[1..]) |arg| switch (arg) {
            .float => |fv| if (!std.math.isFinite(@as(f32, @floatCast(fv)))) break false,
            .integer => |iv| if (!std.math.isFinite(@as(f32, @floatFromInt(iv)))) break false,
            else => {},
        } else true;
        if (!finite) continue;
        if (c) |cc| out.appendAssumeCapacity(cc);
    }
    return out.items;
}

/// Arguments per op code of a program as numbers (decodeCanvas; canvas.js's
/// CANVAS_ARGS, index = code).
const canvas_args = [_]u8{ 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 1, 2, 2, 4, 6, 6, 4, 4, 4, 3, 3, 5, 5, 1, 1, 1, 1, 1, 1, 4, 5, 7, 6 };

/// A canvas program as numbers (host.canvas: canvas.js encodeProgram):
/// each op its code and its fixed arguments, strings by index into
/// `strs`, paints as kind (0 color, 1 gradient) and four numbers. The same
/// commands as parseCanvasCmds makes from the JSON form; an op with an
/// argument that isn't finite is ignored, a malformed tail ends it.
pub fn decodeCanvas(a: std.mem.Allocator, nums: []const f64, strs: []const []const u8) ![]CanvasCmd {
    var out: std.ArrayList(CanvasCmd) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < nums.len) {
        const code_f = nums[i];
        if (!(code_f >= 1 and code_f < canvas_args.len)) break;
        const code: usize = @intFromFloat(code_f);
        const argc = canvas_args[code];
        if (i + 1 + argc > nums.len) break;
        const v = nums[i + 1 ..][0..argc];
        i += 1 + argc;
        const finite = for (v) |x| {
            if (!std.math.isFinite(@as(f32, @floatCast(x)))) break false;
        } else true;
        if (!finite) continue;
        const f = struct {
            fn at(args: []const f64, k: usize) f32 {
                return @floatCast(args[k]);
            }
        }.at;
        const str = struct {
            fn at(alloc: std.mem.Allocator, list: []const []const u8, x: f64) !?[]const u8 {
                if (!(x >= 0 and x < @as(f64, @floatFromInt(list.len)))) return null;
                return try alloc.dupe(u8, list[@intFromFloat(x)]);
            }
        }.at;
        const paint = struct {
            fn at(args: []const f64) ?CanvasPaint {
                if (args[0] == 1) return .{ .grad = @intCast(@max(0, @min(sat(i64, args[1]), std.math.maxInt(u16)))) };
                if (args[0] == 0) return .{ .color = .{ @floatCast(args[1]), @floatCast(args[2]), @floatCast(args[3]), @floatCast(args[4]) } };
                return null;
            }
        }.at;
        const word = struct {
            fn at(x: f64, max: u8) ?u8 {
                return if (x >= 0 and x <= @as(f64, @floatFromInt(max))) @intFromFloat(x) else null;
            }
        }.at;
        const c: ?CanvasCmd = switch (code) {
            1 => .save,
            2 => .restore,
            3 => .begin_path,
            4 => .close_path,
            5 => .stroke,
            6 => .{ .fill = v[0] != 0 },
            7 => .{ .clip = v[0] != 0 },
            8 => .{ .translate = .{ f(v, 0), f(v, 1) } },
            9 => .{ .scale = .{ f(v, 0), f(v, 1) } },
            10 => .{ .rotate = f(v, 0) },
            11 => .{ .move_to = .{ f(v, 0), f(v, 1) } },
            12 => .{ .line_to = .{ f(v, 0), f(v, 1) } },
            13 => .{ .rect = .{ f(v, 0), f(v, 1), f(v, 2), f(v, 3) } },
            14 => .{ .arc = .{ .x = f(v, 0), .y = f(v, 1), .r = f(v, 2), .a0 = f(v, 3), .a1 = f(v, 4), .ccw = v[5] != 0 } },
            15 => .{ .bezier_to = .{ f(v, 0), f(v, 1), f(v, 2), f(v, 3), f(v, 4), f(v, 5) } },
            16 => .{ .fill_rect = .{ f(v, 0), f(v, 1), f(v, 2), f(v, 3) } },
            17 => .{ .stroke_rect = .{ f(v, 0), f(v, 1), f(v, 2), f(v, 3) } },
            18 => .{ .clear_rect = .{ f(v, 0), f(v, 1), f(v, 2), f(v, 3) } },
            19, 20 => blk: {
                const t = (try str(a, strs, v[0])) orelse break :blk null;
                if (t.len == 0) break :blk null;
                break :blk if (code == 19) .{ .fill_text = .{ .t = t, .x = f(v, 1), .y = f(v, 2) } } else .{ .stroke_text = .{ .t = t, .x = f(v, 1), .y = f(v, 2) } };
            },
            21, 22 => blk: {
                const p = paint(v) orelse break :blk null;
                break :blk if (code == 21) CanvasCmd{ .fill_style = p } else CanvasCmd{ .stroke_style = p };
            },
            23 => .{ .line_width = f(v, 0) },
            24 => .{ .global_alpha = f(v, 0) },
            25 => if (word(v[0], 2)) |w| CanvasCmd{ .line_cap = @intCast(w) } else null,
            26 => if (word(v[0], 2)) |w| CanvasCmd{ .line_join = @intCast(w) } else null,
            27 => if (word(v[0], 2)) |w| CanvasCmd{ .text_align = @intCast(w) } else null,
            28 => if (word(v[0], 4)) |w| CanvasCmd{ .text_baseline = @intCast(w) } else null,
            29 => .{ .font = .{ .italic = v[0] != 0, .weight = f(v, 1), .size = f(v, 2), .family = (try str(a, strs, v[3])) orelse "" } },
            30 => .{ .linear_gradient = .{ .id = gradOf(v[0]), .x0 = f(v, 1), .y0 = f(v, 2), .x1 = f(v, 3), .y1 = f(v, 4) } },
            31 => .{ .radial_gradient = .{ .id = gradOf(v[0]), .x0 = f(v, 1), .y0 = f(v, 2), .r0 = f(v, 3), .x1 = f(v, 4), .y1 = f(v, 5), .r1 = f(v, 6) } },
            32 => .{ .color_stop = .{ .id = gradOf(v[0]), .off = f(v, 1), .c = .{ f(v, 2), f(v, 3), f(v, 4), f(v, 5) } } },
            else => null,
        };
        if (c) |cc| try out.append(a, cc);
    }
    return out.items;
}

fn gradOf(x: f64) u16 {
    return @intCast(@max(0, @min(sat(i64, x), std.math.maxInt(u16))));
}

/// lineCap, lineJoin, textAlign, textBaseline: the recorder sends the word
/// ("round"); a number (its index) is taken too, up to `max`. Null: neither.
fn wordAt(op: []const std.json.Value, words: []const []const u8, max: usize) ?usize {
    if (op.len < 2) return null;
    return switch (op[1]) {
        .string => |w| for (words, 0..) |word, i| {
            if (std.mem.eql(u8, w, word)) break i;
        } else null,
        .integer => |i| if (i >= 0 and i <= max) @intCast(i) else null,
        .float => |f| if (f >= 0 and f <= @as(f64, @floatFromInt(max))) @intFromFloat(f) else null,
        else => null,
    };
}

fn numAt(op: []const std.json.Value, i: usize) f32 {
    if (i >= op.len) return 0;
    return switch (op[i]) {
        .integer => |x| @floatFromInt(x),
        .float => |x| @floatCast(x),
        else => 0,
    };
}

/// `x` as an integer of type T, saturated to its range (NaN: 0). Values
/// from the page (a font size, a gradient id) can be anything;
/// @intFromFloat would panic on one out of range.
pub fn sat(comptime T: type, x: anytype) T {
    const f: f64 = switch (@typeInfo(@TypeOf(x))) {
        .float, .comptime_float => @floatCast(x),
        else => @floatFromInt(x),
    };
    if (std.math.isNan(f)) return 0;
    const lo: f64 = @floatFromInt(std.math.minInt(T));
    const hi: f64 = @floatFromInt(std.math.maxInt(T));
    if (f <= lo) return std.math.minInt(T);
    if (f >= hi) return std.math.maxInt(T);
    return @intFromFloat(f);
}

test "sat clamps page values" {
    try std.testing.expectEqual(@as(i32, std.math.maxInt(i32)), sat(i32, 3e12));
    try std.testing.expectEqual(@as(i32, std.math.minInt(i32)), sat(i32, -1e30));
    try std.testing.expectEqual(@as(i32, 0), sat(i32, std.math.nan(f64)));
    try std.testing.expectEqual(@as(i64, 7), sat(i64, 7.9));
}

/// A paint: [r,g,b,a] (or [r,g,b]) — or ["g", id] for a gradient.
fn paintAt(v: std.json.Value) ?CanvasPaint {
    if (v != .array) return null;
    const a = v.array.items;
    if (a.len == 2 and a[0] == .string and std.mem.eql(u8, a[0].string, "g")) {
        const id = switch (a[1]) {
            .integer => |x| x,
            .float => |x| sat(i64, x),
            else => return null,
        };
        if (id < 0 or id > std.math.maxInt(u16)) return null;
        return .{ .grad = @intCast(id) };
    }
    const rgb: Color = .{ numAt(a, 0), numAt(a, 1), numAt(a, 2), if (a.len > 3) numAt(a, 3) else 1 };
    return .{ .color = rgb };
}

fn gradId(v: std.json.Value) u16 {
    const x = switch (v) {
        .integer => |i| i,
        .float => |f| sat(i64, f),
        else => 0,
    };
    return @intCast(@max(0, @min(x, std.math.maxInt(u16))));
}

/// A length: a number (px), "50%", "auto", or null.
pub const Dim = std.json.Value;

pub const Props = struct {
    root: bool = false,
    // Layout
    fd: ?[]const u8 = null,
    fw: ?[]const u8 = null,
    jc: ?[]const u8 = null,
    ai: ?[]const u8 = null,
    as: ?[]const u8 = null,
    ac: ?[]const u8 = null,
    fg: ?f32 = null,
    fs: ?f32 = null,
    fb: ?Dim = null,
    w: ?Dim = null,
    h: ?Dim = null,
    minw: ?Dim = null,
    minh: ?Dim = null,
    maxw: ?Dim = null,
    maxh: ?Dim = null,
    m: ?[4]Dim = null,
    pad: ?[4]Dim = null,
    bw: ?[4]f32 = null,
    bc: ?[4]Color = null,
    rg: ?f32 = null,
    cg: ?f32 = null,
    pos: ?[]const u8 = null,
    ins: ?[4]?Dim = null,
    rel: ?[4]?f32 = null,
    scroll: bool = false,
    /// overflow-x: auto/scroll: scrolls sideways.
    scrollx: bool = false,
    /// A table (its border-spacing), a table row, a table cell (its colspan):
    /// sizeTables lays the cells out in columns.
    table: ?f32 = null,
    trow: bool = false,
    tcell: ?f32 = null,
    /// position: sticky, its insets (top, right, bottom, left; null: auto).
    sticky: ?[4]?f32 = null,
    clip: bool = false,
    ar: ?f32 = null,
    tx: ?f32 = null,
    /// Drawn scaled and rotated (degrees) around the frame's center.
    sc: ?f32 = null,
    rot: ?f32 = null,
    ty: ?f32 = null,
    // Drawing
    bg: ?Background = null,
    br: ?[4]Dim = null,
    op: ?f32 = null,
    sh: ?Shadow = null,
    vis: ?bool = null,
    click: bool = false,
    z: ?i32 = null,
    // Text
    col: ?Color = null,
    fz: ?f32 = null,
    fwt: ?f32 = null,
    it: bool = false,
    mono: bool = false,
    lh: ?f32 = null,
    ta: ?[]const u8 = null,
    nowrap: bool = false,
    ls: ?f32 = null,
    runs: ?[]const Run = null,
    // Fields
    val: ?[]const u8 = null,
    ph: ?[]const u8 = null,
    dis: bool = false,
    pw: bool = false,
    /// A textarea's cols (20 when absent): its natural width.
    cols: ?f32 = null,
    options: ?[]const [2][]const u8 = null,
    /// <input type=range>: min, max, step (0: any).
    range: ?[3]f64 = null,
    // Icons
    icon: ?Icon = null,
    // Images (<img>): a data: URI or an app asset path, and CSS object-fit.
    src: ?[]const u8 = null,
    fit: ?[]const u8 = null,
    // <canvas>: the drawing's coordinate space (the bitmap's px size).
    cw: ?f32 = null,
    ch: ?f32 = null,
    // A default checkbox/radio (<input> without appearance: none).
    ctl: ?[]const u8 = null,
    on: bool = false,
    acc: ?Color = null,
};

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn contains(r: Rect, px: f32, py: f32) bool {
        return px >= r.x and py >= r.y and px < r.x + r.w and py < r.y + r.h;
    }

    pub fn intersect(a: Rect, b: Rect) Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.x + a.w, b.x + b.w);
        const y1 = @min(a.y + a.h, b.y + b.h);
        return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
    }
};

/// <input type=range> (`props.range`: min, max, step): what a slider shows
/// and sends, as Android's SeekBar does it (AppKit, UIKit and Win32 use it).
pub const Range = struct {
    min: f64,
    max: f64,
    /// The step; "any" (0) is a thousandth of the span.
    step: f64,

    pub fn of(n: *const Node) Range {
        const r = n.props.range orelse [3]f64{ 0, 100, 1 };
        const lo = if (std.math.isFinite(r[0])) r[0] else 0;
        const hi = if (std.math.isFinite(r[1]) and r[1] >= lo) r[1] else lo;
        const any = (hi - lo) / 1000;
        const step = if (std.math.isFinite(r[2]) and r[2] > 0) r[2] else any;
        return .{ .min = lo, .max = hi, .step = if (step > 0) step else 1 };
    }

    /// `x` on the nearest step, inside min…max.
    pub fn snap(r: Range, x: f64) f64 {
        if (!std.math.isFinite(x)) return r.min;
        const steps = @round((std.math.clamp(x, r.min, r.max) - r.min) / r.step);
        return std.math.clamp(r.min + steps * r.step, r.min, r.max);
    }

    /// The page's text for a value ("3", "0.25"), the input's value attribute.
    pub fn text(r: Range, buf: []u8, x: f64) []const u8 {
        const v = r.snap(x);
        if (v == @floor(v) and @abs(v) < 1e15) return std.fmt.bufPrint(buf, "{d}", .{@as(i64, @intFromFloat(v))}) catch "0";
        const s = std.fmt.bufPrint(buf, "{d:.6}", .{v}) catch return "0";
        var end = s.len;
        while (end > 0 and s[end - 1] == '0') end -= 1;
        if (end > 0 and s[end - 1] == '.') end -= 1;
        return s[0..end];
    }

    /// A page value ("0.2") as a number, min when it isn't one.
    pub fn parse(r: Range, v: []const u8) f64 {
        return r.snap(std.fmt.parseFloat(f64, std.mem.trim(u8, v, " ")) catch r.min);
    }
};

test "Range snaps and prints like Android" {
    var n: Node = undefined;
    n.props = .{ .range = .{ 0, 1, 0.05 } };
    const r = Range.of(&n);
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0.25", r.text(&buf, 0.26));
    try std.testing.expectEqualStrings("1", r.text(&buf, 7));
    try std.testing.expectEqualStrings("0", r.text(&buf, -3));
    try std.testing.expectEqual(@as(f64, 0.2), r.parse("0.2"));
    try std.testing.expectEqual(@as(f64, 0), r.parse("x"));
    n.props = .{};
    const d = Range.of(&n);
    try std.testing.expectEqualStrings("50", d.text(&buf, 49.6));
    n.props = .{ .range = .{ 5, 1, 0 } }; // max below min: pinned at min
    try std.testing.expectEqualStrings("5", Range.of(&n).text(&buf, 3));
}

/// A node's children in CSS paint order: negative z-index first, then the
/// boxes in the flow, then positioned ones (absolute, fixed, sticky,
/// relative) with z-index auto or 0, then positive z-index; tree order
/// within each layer. So a sticky header paints over the rows scrolled
/// under it, as in a browser. `reverse`: topmost first (hit testing). No
/// allocation: one pass per layer present (two when nothing is positioned).
/// A copy of `s` with each invalid UTF-8 sequence as U+FFFD. Text from
/// the direct bridge comes straight from QuickJS, which keeps a lone
/// surrogate as bytes no backend can draw (DirectWrite and CoreText drop
/// the whole run).
fn dupeUtf8Lossy(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    if (std.unicode.utf8ValidateSlice(s)) return gpa.dupe(u8, s);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 0;
        if (len > 0 and i + len <= s.len and std.meta.isError(std.unicode.utf8Decode(s[i .. i + len])) == false) {
            try out.appendSlice(gpa, s[i .. i + len]);
            i += len;
        } else {
            try out.appendSlice(gpa, "\u{FFFD}");
            i += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

/// The page's JSON with each lone UTF-16 surrogate escape (\ud800-\udfff
/// without its pair: text cut inside an emoji) made \ufffd: std.json
/// rejects them, and with them a whole frame's ops. The input itself when
/// it has none (the usual case: no copy, one scan); else a copy in `a`, of
/// the same length (both escapes are six bytes).
pub fn wellFormedEscapes(a: std.mem.Allocator, json: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, json, "\\ud") == null and std.mem.indexOf(u8, json, "\\uD") == null) return json;
    const out = try a.alloc(u8, json.len);
    var o: usize = 0;
    var i: usize = 0;
    while (i < json.len) {
        if (json[i] != '\\' or i + 1 >= json.len) {
            out[o] = json[i];
            o += 1;
            i += 1;
            continue;
        }
        // An escape: two bytes, or six for \uXXXX (a backslash escaped
        // as \\ is two bytes, so the u after it starts no escape).
        const unit = if (json[i + 1] == 'u') hex4(json, i + 2) else null;
        const len: usize = if (unit != null) 6 else 2;
        if (unit) |u| if (u >= 0xD800 and u <= 0xDFFF) {
            const paired = u <= 0xDBFF and i + 12 <= json.len and json[i + 6] == '\\' and json[i + 7] == 'u' and
                if (hex4(json, i + 8)) |lo| lo >= 0xDC00 and lo <= 0xDFFF else false;
            if (paired) {
                @memcpy(out[o..][0..12], json[i..][0..12]);
                o += 12;
                i += 12;
            } else {
                @memcpy(out[o..][0..6], "\\ufffd");
                o += 6;
                i += 6;
            }
            continue;
        };
        @memcpy(out[o..][0..len], json[i..][0..len]);
        o += len;
        i += len;
    }
    return out[0..o];
}

fn hex4(s: []const u8, at: usize) ?u16 {
    if (at + 4 > s.len) return null;
    return std.fmt.parseInt(u16, s[at..][0..4], 16) catch null;
}

test "wellFormedEscapes makes lone surrogates U+FFFD, keeps the rest" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const clean = "[\"p\",1,{\"t\":\"ok\"}]";
    try std.testing.expect((try wellFormedEscapes(a, clean)).ptr == clean.ptr);
    try std.testing.expectEqualStrings("\"a\\ufffdb\\ufffd\\ud83d\\ude00\\\\ud800\\ufffd\"",
        try wellFormedEscapes(a, "\"a\\ud83db\\ude00\\ud83d\\ude00\\\\ud800\\uDBFF\""));
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, try wellFormedEscapes(a, "[\"x\\ud800\"]"), .{});
    try std.testing.expectEqualStrings("x\u{FFFD}", v.array.items[0].string);
}

test "dupeUtf8Lossy replaces invalid sequences" {
    const gpa = std.testing.allocator;
    const ok = try dupeUtf8Lossy(gpa, "héllo");
    defer gpa.free(ok);
    try std.testing.expectEqualStrings("héllo", ok);
    const bad = try dupeUtf8Lossy(gpa, "\xed\xa0\x80x\xff");
    defer gpa.free(bad);
    try std.testing.expectEqualStrings("\u{FFFD}\u{FFFD}\u{FFFD}x\u{FFFD}", bad);
}

pub const PaintIter = struct {
    kids: []const *Node,
    reverse: bool = false,
    layer: ?i64 = null,
    i: usize = 0,

    /// The layer: 2 × z-index, +1 for a positioned box (above the flow at
    /// the same z); the flow is 0.
    pub fn layerOf(k: *const Node) i64 {
        const p = k.props;
        const positioned = p.pos != null or p.sticky != null or p.rel != null;
        const z: i64 = p.z orelse 0;
        return 2 * z + @intFromBool(positioned);
    }

    pub fn next(it: *PaintIter) ?*Node {
        while (true) {
            if (it.layer) |layer| {
                while (it.i < it.kids.len) {
                    const k = it.kids[if (it.reverse) it.kids.len - 1 - it.i else it.i];
                    it.i += 1;
                    if (layerOf(k) == layer) return k;
                }
            }
            // The next layer up (or down, reversed) that has a child.
            var found: ?i64 = null;
            for (it.kids) |k| {
                const l = layerOf(k);
                if (it.layer) |cur| if (if (it.reverse) l >= cur else l <= cur) continue;
                if (found == null or (if (it.reverse) l > found.? else l < found.?)) found = l;
            }
            it.layer = found orelse return null;
            it.i = 0;
        }
    }
};

pub const Node = struct {
    id: i64,
    kind: Kind,
    yn: yg.YGNodeRef,
    parent: ?*Node = null,
    kids: std.ArrayList(*Node) = .empty,
    arena: std.heap.ArenaAllocator,
    props: Props = .{},
    /// The value the page last set (fields); null once the backend took it.
    pending_value: ?[]const u8 = null,
    /// For a canvas node: its drawing program, from props `cv` (in the
    /// props arena) or host.canvas (in canvas_arena, kept across props).
    canvas: ?[]const CanvasCmd = null,
    canvas_from_props: bool = false,
    canvas_arena: ?*std.heap.ArenaAllocator = null,
    /// After layout: the frame in window coordinates, the visible part.
    frame: Rect = .{},
    clip: Rect = .{},
    /// Scroll containers: the content's height and the offset.
    content_h: f32 = 0,
    scroll_y: f32 = 0,
    scroll_x: f32 = 0,
    content_w: f32 = 0,
    /// The backend's widget for this node, if any.
    native: ?*anyopaque = null,
    /// Backend natural text size; invalidated on props/text changes. A
    /// backend epoch invalidates it when font context settings change.
    measured_text_size: ?[2]f32 = null,
    text_measure_epoch: u64 = 0,
    text_override: ?*TextOverride = null,
    /// A growing text item in a row (flex: 1): its longest word's width,
    /// set as its min width only when its share of the row comes out
    /// narrower (Tree.freezeGrowMins); nan: none.
    grow_min: f32 = std.math.nan(f32),
    /// Its min width set and its growth off for this layout.
    grow_frozen: bool = false,
    /// A leaf made from a leaf style (createLeaf): its id, so a row stamped
    /// again keeps a leaf whose style is the same (0: not a leaf).
    leaf_style: i64 = 0,
    /// Made by the tree itself (stampRow, stampList), not by the page's
    /// ops: nothing else names it, so it goes with its parent, or when its
    /// parent's children are set without it.
    stamp_owned: bool = false,
    tree: *Tree,

    /// Draws something itself (vs. a box that only lays out its children).
    pub fn visual(n: *const Node) bool {
        if (n.kind != .view) return true;
        const p = n.props;
        return p.bg != null or p.bw != null or p.sh != null or p.scroll or p.clip or p.root;
    }

    /// The frame minus border and padding: where text and fields go.
    pub fn content(n: *const Node) Rect {
        const l = yg.YGNodeLayoutGetPadding(n.yn, yg.YGEdgeLeft) + yg.YGNodeLayoutGetBorder(n.yn, yg.YGEdgeLeft);
        const t = yg.YGNodeLayoutGetPadding(n.yn, yg.YGEdgeTop) + yg.YGNodeLayoutGetBorder(n.yn, yg.YGEdgeTop);
        const r = yg.YGNodeLayoutGetPadding(n.yn, yg.YGEdgeRight) + yg.YGNodeLayoutGetBorder(n.yn, yg.YGEdgeRight);
        const b = yg.YGNodeLayoutGetPadding(n.yn, yg.YGEdgeBottom) + yg.YGNodeLayoutGetBorder(n.yn, yg.YGEdgeBottom);
        return .{ .x = n.frame.x + l, .y = n.frame.y + t, .w = @max(0, n.frame.w - l - r), .h = @max(0, n.frame.h - t - b) };
    }

    pub fn radius(n: *const Node) [4]f32 {
        const br = n.props.br orelse return .{ 0, 0, 0, 0 };
        var out: [4]f32 = undefined;
        const lim = @min(n.frame.w, n.frame.h) / 2;
        for (br, 0..) |v, i| {
            out[i] = @min(lim, switch (v) {
                .integer => |x| @as(f32, @floatFromInt(x)),
                .float => |x| @as(f32, @floatCast(x)),
                .string => |s| if (std.mem.endsWith(u8, s, "%")) (std.fmt.parseFloat(f32, s[0 .. s.len - 1]) catch 0) / 100 * @min(n.frame.w, n.frame.h) else 0,
                else => 0,
            });
        }
        return out;
    }
};

pub const Measure = *const fn (ctx: *anyopaque, node: *Node, max_width: f32, out: *[2]f32) void;

pub const Tree = struct {
    deleted_nodes: usize = 0,
    leaf_styles: std.AutoHashMapUnmanaged(i64, *LeafStyle) = .empty,
    leaf_style_bytes: usize = 0,
    /// Row plans for stampRow's callers (defineStampPlan), by id - 1.
    stamp_plans: std.ArrayList(StampPlan) = .empty,
    gpa: std.mem.Allocator,
    nodes: std.AutoHashMap(i64, *Node),
    root: ?*Node = null,
    config: yg.YGConfigRef,
    measure_ctx: *anyopaque,
    measure: Measure,
    /// Something changed since the last layout.
    dirty: bool = true,
    paint_dirty: bool = false,
    /// Backend supplies natural text sizes and context epochs. Equal,
    /// unwrapped metrics can reuse the current frames after a text edit.
    reuse_text_layout: bool = false,
    width: f32 = 800,
    height: f32 = 600,
    /// Called before a node goes (its widget is destroyed).
    on_remove: ?*const fn (ctx: *anyopaque, node: *Node) void = null,
    /// Called after a node's props changed, with the props as sent (backends
    /// that keep their own copy: Android).
    on_props: ?*const fn (ctx: *anyopaque, node: *Node, props: std.json.Value) void = null,
    on_text: ?*const fn (ctx: *anyopaque, node: *Node) void = null,
    /// A leaf style was defined (defineLeafStyle), with its props JSON, and a
    /// node was made from one (on_create: createLeaf, which host.leaf and
    /// stamped rows and lists all go through). These nodes get no on_props,
    /// so a backend that mirrors props (Android) learns of them here.
    on_leaf_style: ?*const fn (ctx: *anyopaque, id: i64, json: []const u8) void = null,
    on_create: ?*const fn (ctx: *anyopaque, node: *Node) void = null,
    /// A node's transform or opacity changed alone (the "x" op: an
    /// animation's frame), its other props as they were: backends that
    /// mirror props (Android) send just those, without on_props' JSON.
    on_paint: ?*const fn (ctx: *anyopaque, node: *Node) void = null,
    /// A canvas node's program changed (host.canvas: setCanvas), not in its
    /// props: backends that mirror props send node.canvas themselves.
    on_canvas: ?*const fn (ctx: *anyopaque, node: *Node) void = null,

    pub fn init(gpa: std.mem.Allocator, measure_ctx: *anyopaque, measure: Measure) Tree {
        const config = yg.YGConfigNew();
        yg.YGConfigSetUseWebDefaults(config, true);
        yg.YGConfigSetPointScaleFactor(config, 1);
        return .{ .gpa = gpa, .nodes = .init(gpa), .config = config, .measure_ctx = measure_ctx, .measure = measure };
    }

    pub fn deinit(t: *Tree) void {
        for (t.stamp_plans.items) |plan| t.gpa.free(plan.mem);
        t.stamp_plans.deinit(t.gpa);
        var it = t.nodes.valueIterator();
        while (it.next()) |n| freeNode(t, n.*);
        t.nodes.deinit();
        var styles = t.leaf_styles.valueIterator();
        while (styles.next()) |style| {
            yg.YGNodeFree(style.*.yn);
            style.*.arena.deinit();
            t.gpa.destroy(style.*);
        }
        t.leaf_styles.deinit(t.gpa);
        yg.YGConfigFree(t.config);
    }

    fn freeNode(t: *Tree, n: *Node) void {
        if (t.on_remove) |cb| cb(t.measure_ctx, n);
        if (n.canvas_arena) |ar| {
            ar.deinit();
            t.gpa.destroy(ar);
        }
        t.dropTextOverride(n);
        yg.YGNodeFree(n.yn);
        n.kids.deinit(t.gpa);
        n.arena.deinit();
        t.gpa.destroy(n);
    }

    pub fn get(t: *Tree, id: i64) ?*Node {
        return t.nodes.get(id);
    }

    /// Intern immutable typed props once; each new leaf shares them. The
    /// cache is bounded and lives until nodes are freed at tree destruction.
    pub fn defineLeafStyle(t: *Tree, id: i64, json: []const u8) !bool {
        if (t.leaf_styles.contains(id)) return false;
        if (t.leaf_styles.count() >= 1024 or json.len > 8192 or t.leaf_style_bytes + json.len > 2 * 1024 * 1024) return false;
        const style = try t.gpa.create(LeafStyle);
        errdefer t.gpa.destroy(style);
        style.* = .{ .arena = .init(t.gpa), .props = .{}, .yn = yg.YGNodeNewWithConfig(t.config) };
        errdefer yg.YGNodeFree(style.yn);
        errdefer style.arena.deinit();
        const a = style.arena.allocator();
        style.props = try std.json.parseFromSliceLeaky(Props, a, try wellFormedEscapes(a, json), .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        try ownProps(a, &style.props);
        applyYogaStyle(style.yn, style.props);
        try t.leaf_styles.put(t.gpa, id, style);
        t.leaf_style_bytes += json.len;
        if (t.on_leaf_style) |cb| cb(t.measure_ctx, id, json);
        return true;
    }

    /// Create a new text/view node without reparsing and copying its style.
    /// View children can be attached through the ordinary kids operation.
    /// No existing node is replaced: a declined call leaves JSON fallback
    /// free to handle general updates and backend mirrored properties.
    pub fn createLeaf(t: *Tree, id: i64, kind: Kind, style_id: i64, text: []const u8) !bool {
        if (t.nodes.contains(id) or (kind != .text and kind != .view)) return false;
        const style = t.leaf_styles.get(style_id) orelse return false;
        if (kind == .text and (style.props.runs == null or style.props.runs.?.len != 1)) return false;
        if (kind == .view and style.props.runs != null) return false;
        try t.create(id, kind);
        errdefer t.destroy(id);
        const n = t.get(id).?;
        n.props = style.props;
        if (kind == .text) {
            const owned = try dupeUtf8Lossy(t.gpa, text);
            errdefer t.gpa.free(owned);
            const o = try t.gpa.create(TextOverride);
            o.* = .{ .run = style.props.runs.?[0], .text = owned };
            o.run.t = owned;
            n.text_override = o;
            n.props.runs = @as(*const [1]Run, @ptrCast(&o.run));
        }
        // Copy only style: each node keeps its own measure callback,
        // context, children and layout. Avoid dozens of setters per row.
        yg.YGNodeCopyStyle(n.yn, style.yn);
        n.leaf_style = style_id;
        t.dirty = true;
        if (t.on_create) |cb| cb(t.measure_ctx, n);
        return true;
    }

    /// A row plan (defineStampPlan): for each child element, in source
    /// order, its leaf styles (text and box) and how its text is written;
    /// and the order the children are laid out in (CSS order).
    pub const StampPlan = struct {
        /// The one allocation holding both slices below.
        mem: []align(@alignOf(StampEntry)) u8,
        entries: []StampEntry,
        /// Into `entries`, laid-out order (the slice after them).
        order: []const u16,
    };
    pub const StampEntry = struct {
        text_style: i64,
        view_style: i64,
        transform: enum(u8) { none, upper, lower },
    };

    /// Register a row plan: [n, (text style, box style, transform) × n,
    /// order × n] as numbers (the page's runtime builds it). Its id (> 0),
    /// or 0 when malformed or past the bound.
    pub fn defineStampPlan(t: *Tree, v: []const f64) !u32 {
        if (v.len < 1 or t.stamp_plans.items.len >= 1024) return 0;
        const count = sat(usize, v[0]);
        if (count == 0 or count > 64 or v.len != 1 + count * 4) return 0;
        // One allocation: the entries, then the order.
        const bytes = count * @sizeOf(StampEntry) + count * @sizeOf(u16);
        const mem = try t.gpa.alignedAlloc(u8, .of(StampEntry), bytes);
        errdefer t.gpa.free(mem);
        const entries: []StampEntry = @as([*]StampEntry, @ptrCast(mem.ptr))[0..count];
        const order: []u16 = @as([*]u16, @ptrCast(@alignCast(mem.ptr + count * @sizeOf(StampEntry))))[0..count];
        for (entries, 0..) |*e, i| {
            const tr = sat(u8, v[1 + i * 3 + 2]);
            e.* = .{ .text_style = sat(i64, v[1 + i * 3]), .view_style = sat(i64, v[1 + i * 3 + 1]), .transform = if (tr == 1) .upper else if (tr == 2) .lower else .none };
        }
        for (order, 0..) |*o, i| {
            const at = sat(usize, v[1 + count * 3 + i]);
            if (at >= count) return error.BadPlan;
            o.* = @intCast(at);
        }
        try t.stamp_plans.append(t.gpa, .{ .mem = mem, .entries = entries, .order = order });
        return @intCast(t.stamp_plans.items.len);
    }

    pub fn stampPlan(t: *Tree, id: u32) ?StampPlan {
        if (id == 0 or id > t.stamp_plans.items.len) return null;
        return t.stamp_plans.items[id - 1];
    }

    /// A stamped child: its id, its kind and leaf style, its text.
    pub const StampLeaf = struct { id: i64, kind: Kind, style: i64, text: []const u8 };

    /// Make row `row_id`'s children these leaves (in laid-out order),
    /// without the page's ops: a leaf with the same id, kind and style is
    /// kept (its text updated), others are made from their leaf style, and
    /// the row's old stamped children not among them go. False when the
    /// row or a style is unknown (nothing changed then).
    pub fn stampRow(t: *Tree, row_id: i64, leaves: []const StampLeaf) !bool {
        const row = t.nodes.get(row_id) orelse return false;
        for (leaves) |l| if (!t.leaf_styles.contains(l.style) or l.id == row_id) return false;
        for (leaves) |l| {
            if (t.nodes.get(l.id)) |old| {
                if (old.kind == l.kind and old.leaf_style == l.style and old.leaf_style != 0) {
                    if (l.kind == .text) _ = try t.updateText(l.id, l.text);
                    continue;
                }
                t.destroy(l.id);
            }
            if (!try t.createLeaf(l.id, l.kind, l.style, l.text)) return false;
            t.nodes.get(l.id).?.stamp_owned = true;
        }
        // The same children in the same order (a text update): they stay
        // attached, each updated above (its min width with its text).
        same: {
            if (row.kids.items.len != leaves.len) break :same;
            for (row.kids.items, leaves) |k, l| if (k.id != l.id) break :same;
            return true;
        }
        const Ids = struct {
            leaves: []const StampLeaf,
            fn len(x: @This()) usize {
                return x.leaves.len;
            }
            fn at(x: @This(), i: usize) ?i64 {
                return x.leaves[i].id;
            }
        };
        try t.attachKids(row, Ids{ .leaves = leaves });
        return true;
    }

    /// Make list `list_id`'s children `ids`, in order (stampList: the rows
    /// the tree stamped, after the first, which the page's ops made).
    pub fn stampKids(t: *Tree, list_id: i64, ids: []const i64) !bool {
        const list = t.nodes.get(list_id) orelse return false;
        const Ids = struct {
            ids: []const i64,
            fn len(x: @This()) usize {
                return x.ids.len;
            }
            fn at(x: @This(), i: usize) ?i64 {
                return x.ids[i];
            }
        };
        try t.attachKids(list, Ids{ .ids = ids });
        return true;
    }

    fn dropTextOverride(t: *Tree, n: *Node) void {
        if (n.text_override) |o| {
            n.props.runs = null;
            t.gpa.free(o.text);
            t.gpa.destroy(o);
            n.text_override = null;
        }
    }

    /// Direct bridge for one existing text run: unchanged font, paint and
    /// layout props need neither JSON decoding nor Yoga style setters.
    pub fn updateText(t: *Tree, id: i64, text: []const u8) !bool {
        const n = t.nodes.get(id) orelse return false;
        if (n.kind != .text) return false;
        const runs = n.props.runs orelse return false;
        if (runs.len != 1) return false;
        if (std.mem.eql(u8, runs[0].t, text)) return true;
        const previous_size = n.measured_text_size;
        const previous_epoch = n.text_measure_epoch;
        const owned = try dupeUtf8Lossy(t.gpa, text);
        errdefer t.gpa.free(owned);
        const o = n.text_override orelse try t.gpa.create(TextOverride);
        const run = runs[0];
        if (n.text_override != null) t.gpa.free(o.text);
        o.* = .{ .run = run, .text = owned };
        o.run.t = owned;
        n.text_override = o;
        n.props.runs = @as(*const [1]Run, @ptrCast(&o.run));
        n.measured_text_size = null;
        if (t.on_text) |cb| cb(t.measure_ctx, n);
        // Its longest word changed with it (a min width in a row): else the
        // item keeps the old text's minimum ("1" as wide as "a longer chip").
        const old_min = yg.YGNodeStyleGetMinWidth(n.yn).value;
        const old_grow_min = n.grow_min;
        t.wordMinWidth(n);
        const new_min = yg.YGNodeStyleGetMinWidth(n.yn).value;
        const min_changed = !sameMin(old_min, new_min) or !sameMin(old_grow_min, n.grow_min);
        var same_layout = false;
        if (t.reuse_text_layout and !t.dirty and n.parent != null and previous_epoch != 0) {
            if (previous_size) |previous| {
                const content_width = yg.YGNodeLayoutGetWidth(n.yn) -
                    yg.YGNodeLayoutGetPadding(n.yn, yg.YGEdgeLeft) - yg.YGNodeLayoutGetPadding(n.yn, yg.YGEdgeRight) -
                    yg.YGNodeLayoutGetBorder(n.yn, yg.YGEdgeLeft) - yg.YGNodeLayoutGetBorder(n.yn, yg.YGEdgeRight);
                if (n.props.nowrap or content_width >= previous[0]) {
                    var current = [2]f32{ std.math.nan(f32), std.math.nan(f32) };
                    t.measure(t.measure_ctx, n, std.math.inf(f32), &current);
                    same_layout = previous_epoch == n.text_measure_epoch and previous[0] == current[0] and previous[1] == current[1];
                }
            }
        }
        // Yoga's measurement cache must still be invalidated: a future
        // resize may wrap these different words at different positions.
        yg.YGNodeMarkDirty(n.yn);
        if (!same_layout or min_changed) t.dirty = true;
        t.paint_dirty = true;
        return true;
    }

    // -----------------------------------------------------------------
    // Operations

    pub fn apply(t: *Tree, json: []const u8) !void {
        var arena: std.heap.ArenaAllocator = .init(t.gpa);
        defer arena.deinit();
        const t0 = prof.now();
        const ops = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), try wellFormedEscapes(arena.allocator(), json), .{});
        const t1 = prof.now();
        prof.props_ms = 0;
        defer prof.report("apply parse {d:.2} ops {d:.2} (props {d:.2}) {d} bytes", .{ t1 - t0, prof.now() - t1, prof.props_ms, json.len });
        if (ops != .array) return error.BadOps;
        // Ops come from the page's runtime (and `__host.ops` is reachable from
        // the page): skip any that doesn't have the expected shape.
        for (ops.array.items) |op| {
            if (op != .array or op.array.items.len < 2) continue;
            const a = op.array.items;
            if (a[0] != .string or a[0].string.len == 0) continue;
            const kind = a[0].string;
            const id = num(a[1]) orelse continue;
            const arg: ?std.json.Value = if (a.len > 2) a[2] else null;
            switch (kind[0]) {
                'c' => if (arg) |x| if (x == .string) try t.create(id, std.meta.stringToEnum(Kind, x.string) orelse .view),
                'p' => if (arg) |x| if (t.nodes.get(id)) |n| {
                    const p0 = prof.now();
                    try t.setProps(n, x);
                    prof.props_ms += prof.now() - p0;
                },
                'k' => if (arg) |x| if (x == .array) if (t.nodes.get(id)) |n| try t.setKids(n, x.array.items),
                'd' => t.destroy(id),
                'r' => t.root = t.nodes.get(id),
                // ["x", id, tx, ty, sc, rot, op] (each a number or null):
                // a node's transform and opacity alone.
                'x' => if (t.nodes.get(id)) |n| if (a.len >= 7) t.setPaint(n, a[2..7]),
                else => {},
            }
        }
        // Rebuilding lists leaves tombstones in the node lookup table.
        // Compact in place after large removals before new ids arrive.
        if (t.deleted_nodes >= 1024) {
            t.nodes.rehash();
            t.deleted_nodes = 0;
        }
        t.dirty = true;
    }

    /// A node id from a JS number: NaN, infinities and values outside i64
    /// (which @intFromFloat would panic on) name no node (render.js counts
    /// up from 1, with 0 and -1 for the window's nodes).
    pub fn idOf(x: f64) i64 {
        if (!std.math.isFinite(x) or x <= -0x1p63 or x >= 0x1p63) return std.math.minInt(i64);
        return @intFromFloat(x);
    }

    /// A node id from an op, or null when it isn't one (`apply` skips it).
    fn num(v: std.json.Value) ?i64 {
        return switch (v) {
            .integer => |i| i,
            .float => |x| if (idOf(x) == std.math.minInt(i64)) null else idOf(x),
            else => null,
        };
    }

    fn create(t: *Tree, id: i64, kind: Kind) !void {
        if (t.nodes.get(id) != null) t.destroy(id);
        const n = try t.gpa.create(Node);
        n.* = .{ .id = id, .kind = kind, .yn = yg.YGNodeNewWithConfig(t.config), .arena = .init(t.gpa), .tree = t };
        errdefer {
            yg.YGNodeFree(n.yn);
            n.arena.deinit();
            t.gpa.destroy(n);
        }
        yg.YGNodeSetContext(n.yn, n);
        if (kind == .text or kind == .input or kind == .textarea or kind == .select or kind == .image) {
            yg.YGNodeSetMeasureFunc(n.yn, measureFn);
        }
        try t.nodes.put(id, n);
    }

    pub fn destroy(t: *Tree, id: i64) void {
        const n = t.nodes.get(id) orelse return;
        _ = t.nodes.remove(id);
        t.deleted_nodes += 1;
        if (n.parent) |p| {
            for (p.kids.items, 0..) |k, i| if (k == n) {
                _ = p.kids.orderedRemove(i);
                break;
            };
            yg.YGNodeRemoveChild(p.yn, n.yn);
        }
        // Removing the first child repeatedly shifts Yoga's vector on
        // every iteration: quadratic work for a large list. Detach once.
        yg.YGNodeRemoveAllChildren(n.yn);
        for (n.kids.items) |k| k.parent = null;
        if (t.root == n) t.root = null;
        // Children the tree stamped itself: nothing else names them.
        // (Detached above: destroying one doesn't touch `n.kids`.)
        for (n.kids.items) |k| if (k.stamp_owned) t.destroy(k.id);
        freeNode(t, n);
    }

    /// A canvas node's program as numbers (host.canvas: decodeCanvas), kept
    /// in an arena of its own, outside its props.
    pub fn setCanvas(t: *Tree, id: i64, nums: []const f64, strs: []const []const u8) !bool {
        const n = t.nodes.get(id) orelse return false;
        const arena = n.canvas_arena orelse blk: {
            const ar = try t.gpa.create(std.heap.ArenaAllocator);
            ar.* = .init(t.gpa);
            n.canvas_arena = ar;
            break :blk ar;
        };
        n.canvas = null; // its old program is in the arena reset below
        // A game redraws each frame: keep a frame's worth, not a peak's.
        _ = arena.reset(.{ .retain_with_limit = 1 << 20 });
        n.canvas = try decodeCanvas(arena.allocator(), nums, strs);
        n.canvas_from_props = false;
        t.paint_dirty = true;
        if (t.on_canvas) |cb| cb(t.measure_ctx, n);
        return true;
    }

    /// tx, ty, sc, rot, op as given (null: unset): drawing and frames only
    /// (translate moves a box after layout), no Yoga style.
    fn setPaint(t: *Tree, n: *Node, v: []const std.json.Value) void {
        n.props.tx = numF(v[0]);
        n.props.ty = numF(v[1]);
        n.props.sc = numF(v[2]);
        n.props.rot = numF(v[3]);
        n.props.op = numF(v[4]);
        // Frames are placed again with the new translation (Yoga has
        // nothing to lay out again).
        t.dirty = true;
        t.paint_dirty = true;
        if (t.on_paint) |cb| cb(t.measure_ctx, n);
    }

    fn numF(v: std.json.Value) ?f32 {
        return switch (v) {
            .integer => |i| @floatFromInt(i),
            .float => |f| if (std.math.isFinite(f)) @floatCast(f) else null,
            else => null,
        };
    }

    fn setProps(t: *Tree, n: *Node, value: std.json.Value) !void {
        // A value the backend hasn't taken yet lives in the arena reset
        // below: keep a copy, or it would point into reused memory when the
        // new props carry no `val` (fields send it only when it changed).
        const unconsumed: ?[]u8 = if (n.pending_value) |v| try t.gpa.dupe(u8, v) else null;
        defer if (unconsumed) |u| t.gpa.free(u);
        n.pending_value = null;
        n.measured_text_size = null;
        t.dropTextOverride(n);
        // Keep a little for the next props, not an old <img> data: URI's megabytes.
        _ = n.arena.reset(.{ .retain_with_limit = 64 * 1024 });
        // The old props' slices are gone with the reset: if copying the new
        // ones fails, the node must not keep pointing into the arena.
        n.props = .{};
        const a = n.arena.allocator();
        // Parsed from the ops' JSON into the node's arena (the ops arena goes
        // away): std.json copies strings and slices, not the Dims (JSON
        // values), whose strings ownProps copies.
        n.props = std.json.parseFromValueLeaky(Props, a, value, .{ .ignore_unknown_fields = true }) catch |err| blk: {
            log.warn("node {d}: bad props ({s})", .{ n.id, @errorName(err) });
            break :blk .{};
        };
        ownProps(a, &n.props) catch |err| {
            n.props = .{};
            return err;
        };
        if (n.props.val) |v| {
            n.pending_value = v;
        } else if (unconsumed) |u| {
            n.pending_value = try a.dupe(u8, u);
        }
        // A canvas's drawing program in its props (its arena holds the
        // strings); one host.canvas sent stays (it isn't in the props).
        if (n.canvas_from_props) n.canvas = null;
        if (value == .object) if (value.object.get("cv")) |cv| {
            if (parseCanvasCmds(a, cv)) |cmds| {
                n.canvas = cmds;
                n.canvas_from_props = true;
            } else |err| log.warn("node {d}: bad canvas ops ({s})", .{ n.id, @errorName(err) });
        };
        styleYoga(n);
        // The props as sent, valid during the call (the ops arena).
        if (t.on_props) |cb| cb(t.measure_ctx, n, value);
        // After the backend saw the new props (GTK drops its cached size).
        wordMinWidth(t, n);
        // A row or a column now: its text items' min width follows.
        for (n.kids.items) |k| wordMinWidth(t, k);
        if (yg.YGNodeHasMeasureFunc(n.yn)) yg.YGNodeMarkDirty(n.yn);
    }

    fn isAncestorOrSelf(k: *const Node, n: *const Node) bool {
        var p: ?*const Node = n;
        while (p) |x| : (p = x.parent) if (x == k) return true;
        return false;
    }

    fn setKids(t: *Tree, n: *Node, ids: []const std.json.Value) !void {
        const Ids = struct {
            values: []const std.json.Value,
            fn len(x: @This()) usize {
                return x.values.len;
            }
            fn at(x: @This(), i: usize) ?i64 {
                return num(x.values[i]);
            }
        };
        try t.attachKids(n, Ids{ .values = ids });
    }

    /// Make `ids` (len()/at(i)) `n`'s children, in order. Old children the
    /// tree stamped itself that aren't among them go (nothing else names them).
    fn attachKids(t: *Tree, n: *Node, ids: anytype) !void {
        try n.kids.ensureTotalCapacity(t.gpa, ids.len());
        var stale: std.ArrayList(i64) = .empty;
        defer stale.deinit(t.gpa);
        for (n.kids.items) |k| if (k.stamp_owned) try stale.append(t.gpa, k.id);
        yg.YGNodeRemoveAllChildren(n.yn);
        for (n.kids.items) |k| k.parent = null;
        n.kids.clearRetainingCapacity();
        defer for (stale.items) |id| if (t.nodes.get(id)) |k| if (k.parent == null) t.destroy(id);
        for (0..ids.len()) |at| {
            const k = t.nodes.get(ids.at(at) orelse continue) orelse continue;
            // `n` itself or one of its ancestors as a child would make a
            // cycle (layout and paint would recurse forever).
            if (isAncestorOrSelf(k, n)) continue;
            if (k.parent) |old| {
                for (old.kids.items, 0..) |x, i| if (x == k) {
                    _ = old.kids.orderedRemove(i);
                    break;
                };
                yg.YGNodeRemoveChild(old.yn, k.yn);
            }
            if (yg.YGNodeHasMeasureFunc(n.yn)) {
                // A measured leaf can't have children: `k` is left detached
                // (not pointing at a parent that no longer lists it).
                k.parent = null;
                continue;
            }
            yg.YGNodeInsertChild(n.yn, k.yn, yg.YGNodeGetChildCount(n.yn));
            k.parent = n;
            n.kids.appendAssumeCapacity(k);
            wordMinWidth(t, k);
        }
    }

    /// CSS's min-width: auto for a text item in a flex row: its longest
    /// word, so the row shrinks its other items (a slider) rather than
    /// breaking a label mid-word ("Rang/e"). Yoga has no min-content: the
    /// text's unwrapped width (the backend's measure), all of it for one
    /// word, else the longest word's share of the characters with a margin
    /// (never more than the whole). Not in a column, nor when the page sets
    /// min-width.
    fn wordMinWidth(t: *Tree, k: *Node) void {
        if (k.kind != .text or k.props.minw != null) return;
        const in_row = if (k.parent) |p| std.mem.startsWith(u8, p.props.fd orelse "column", "row") else false;
        const runs = k.props.runs orelse &.{};
        var total: usize = 0;
        var longest: usize = 0;
        var word: usize = 0;
        for (runs) |r| {
            var it = (std.unicode.Utf8View.init(r.t) catch continue).iterator();
            while (it.nextCodepoint()) |cp| {
                total += 1;
                if (cp == ' ' or cp == '\t' or cp == '\n') {
                    word = 0;
                } else {
                    word += 1;
                    longest = @max(longest, word);
                }
            }
        }
        // A growing item (flex: 1, a segmented control's buttons): CSS
        // shares the room from its 0 basis, so equal buttons stay equal;
        // Yoga would start from this minimum and widen the longer labels.
        // Its minimum waits for the layout (freezeGrowMins).
        const grows = (k.props.fg orelse 0) > 0;
        unfreeze(k);
        k.grow_min = std.math.nan(f32);
        if (!in_row or k.props.nowrap or longest == 0 or grows) yg.YGNodeStyleSetMinWidth(k.yn, std.math.nan(f32));
        if (!in_row or k.props.nowrap or longest == 0) return;
        var out: [2]f32 = .{ 0, 0 };
        t.measure(t.measure_ctx, k, std.math.inf(f32), &out);
        if (!(out[0] > 0) or !std.math.isFinite(out[0])) return;
        const share = out[0] * @as(f32, @floatFromInt(longest)) / @as(f32, @floatFromInt(total)) * 1.15;
        // Yoga's min-width is the border box: the text's own padding and
        // border come on top (a padded label otherwise wraps its last letters).
        var inset: f32 = 0;
        if (k.props.pad) |pd| inset += (dimPx(pd[1]) orelse 0) + (dimPx(pd[3]) orelse 0);
        if (k.props.bw) |bw| inset += bw[1] + bw[3];
        const min = inset + if (longest == total) out[0] else @min(out[0], share);
        if (grows) k.grow_min = min else yg.YGNodeStyleSetMinWidth(k.yn, min);
    }

    fn sameMin(a: f32, b: f32) bool {
        return a == b or (std.math.isNan(a) and std.math.isNan(b));
    }

    /// Back to sharing the row from its basis (its props' growth, no min).
    fn unfreeze(k: *Node) void {
        if (!k.grow_frozen) return;
        k.grow_frozen = false;
        yg.YGNodeStyleSetFlexGrow(k.yn, k.props.fg orelse 0);
        yg.YGNodeStyleSetMinWidth(k.yn, std.math.nan(f32));
    }

    /// Every frozen item under `n` unfrozen, for a new layout (the room
    /// may have grown).
    fn unfreezeAll(n: *Node) void {
        unfreeze(n);
        for (n.kids.items) |k| unfreezeAll(k);
    }

    /// CSS's flexible lengths (§9.7) for growing text items: each shares
    /// the row from its basis, and one whose share comes out narrower than
    /// its longest word is frozen at that width (min-width, no growth)
    /// while the others share the rest. True if one was frozen (the
    /// layout runs again).
    fn freezeGrowMins(n: *Node) bool {
        var any = false;
        if (!n.grow_frozen and n.grow_min > 0 and yg.YGNodeLayoutGetWidth(n.yn) + 0.5 < n.grow_min) {
            n.grow_frozen = true;
            yg.YGNodeStyleSetMinWidth(n.yn, n.grow_min);
            yg.YGNodeStyleSetFlexGrow(n.yn, 0);
            any = true;
        }
        for (n.kids.items) |k| {
            if (freezeGrowMins(k)) any = true;
        }
        return any;
    }

    // -----------------------------------------------------------------
    // Layout

    pub fn layout(t: *Tree) void {
        const root = t.root orelse return;
        yg.YGNodeStyleSetWidth(root.yn, t.width);
        yg.YGNodeStyleSetHeight(root.yn, t.height);
        prof.measures = 0;
        prof.measure_ms = 0;
        const y0 = prof.now();
        unfreezeAll(root);
        yg.YGNodeCalculateLayout(root.yn, t.width, t.height, yg.YGDirectionLTR);
        // Growing labels narrower than their longest word: frozen at it,
        // the others share the rest (a few rounds: freezing one can
        // narrow the others).
        var rounds: usize = 0;
        while (rounds < 4 and freezeGrowMins(root)) : (rounds += 1)
            yg.YGNodeCalculateLayout(root.yn, t.width, t.height, yg.YGDirectionLTR);
        prof.report("yoga {d:.2}, {d} measures {d:.2}", .{ prof.now() - y0, prof.measures, prof.measure_ms });
        // Tables need the first pass's widths, then fix their cells' widths
        // and lay out again (every layout: a cell's content may have changed).
        if (sizeTables(t, root)) yg.YGNodeCalculateLayout(root.yn, t.width, t.height, yg.YGDirectionLTR);
        const window: Rect = .{ .w = t.width, .h = t.height };
        place(root, 0, 0, window, window);
        t.dirty = false;
    }

    /// CSS's automatic table layout, for every table under `n`: true if
    /// there was one. A column is as wide as its widest cell (a cell's
    /// natural width: its content's, or its CSS width if wider); a cell
    /// spanning columns widens them evenly if it needs more; the columns
    /// shrink in proportion when they don't fit the room, and grow to a
    /// table's CSS width.
    fn sizeTables(t: *Tree, n: *Node) bool {
        var any = false;
        if (n.props.table != null) {
            sizeTable(t, n) catch {};
            any = true;
        }
        for (n.kids.items) |k| {
            if (sizeTables(t, k)) any = true;
        }
        return any;
    }

    const max_table_cols = 1000;

    fn sizeTable(t: *Tree, table: *Node) !void {
        const gpa = t.gpa;
        const sp = table.props.table orelse 0;
        var rows: std.ArrayList(*Node) = .empty;
        defer rows.deinit(gpa);
        try collectRows(gpa, table, &rows);
        // Natural widths, in row and cell order (for the spanning pass).
        var natural: std.ArrayList(f32) = .empty;
        defer natural.deinit(gpa);
        var cols: std.ArrayList(f32) = .empty;
        defer cols.deinit(gpa);
        for (rows.items) |row| {
            var c: usize = 0;
            for (row.kids.items) |cell| {
                const span = cellSpan(cell) orelse continue;
                if (c + span > max_table_cols) break;
                const w = naturalWidth(cell);
                try natural.append(gpa, w);
                while (cols.items.len < c + span) try cols.append(gpa, 0);
                if (span == 1) cols.items[c] = @max(cols.items[c], w);
                c += span;
            }
        }
        const ncols = cols.items.len;
        if (ncols == 0) return;
        // Spanning cells: more room, shared by the columns they cover.
        var i: usize = 0;
        for (rows.items) |row| {
            var c: usize = 0;
            for (row.kids.items) |cell| {
                const span = cellSpan(cell) orelse continue;
                if (c + span > max_table_cols) break;
                const w = natural.items[i];
                i += 1;
                if (span > 1) {
                    const have = sumCols(cols.items[c .. c + span]) + sp * @as(f32, @floatFromInt(span - 1));
                    if (w > have) for (cols.items[c .. c + span]) |*col| {
                        col.* += (w - have) / @as(f32, @floatFromInt(span));
                    };
                }
                c += span;
            }
        }
        // The room: the table's own width when CSS sets it, else its
        // container's (the table shrinks to its columns up to that).
        const gaps = sp * @as(f32, @floatFromInt(ncols - 1));
        const own = edgesX(table.yn);
        const explicit = if (table.props.w) |d| d != .null and !(d == .string and std.mem.eql(u8, d.string, "auto")) else false;
        const room = blk: {
            if (explicit) break :blk yg.YGNodeLayoutGetWidth(table.yn) - own;
            const parent = table.parent orelse break :blk std.math.inf(f32);
            break :blk yg.YGNodeLayoutGetWidth(parent.yn) - edgesX(parent.yn) -
                yg.YGNodeLayoutGetMargin(table.yn, yg.YGEdgeLeft) - yg.YGNodeLayoutGetMargin(table.yn, yg.YGEdgeRight) - own;
        } - gaps;
        const sum = sumCols(cols.items);
        if (std.math.isFinite(room) and room >= 0) {
            if (sum > room and sum > 0) {
                const k = room / sum;
                for (cols.items) |*col| col.* *= k;
            } else if ((explicit or stretched(table)) and sum < room) {
                if (sum > 0) {
                    const k = room / sum;
                    for (cols.items) |*col| col.* *= k;
                } else for (cols.items) |*col| {
                    col.* = room / @as(f32, @floatFromInt(ncols));
                }
            }
        }
        // Each cell as wide as its columns (and the spacing between them).
        for (rows.items) |row| {
            var c: usize = 0;
            for (row.kids.items) |cell| {
                const span = cellSpan(cell) orelse continue;
                if (c + span > max_table_cols) break;
                const w = sumCols(cols.items[c .. c + span]) + sp * @as(f32, @floatFromInt(span - 1));
                yg.YGNodeStyleSetWidth(cell.yn, @max(0, w));
                c += span;
            }
        }
    }

    /// An auto-width table that its flex column stretches (no align-self;
    /// the column's items stretch): as wide as the column, as in a browser,
    /// its columns sharing the room. In a block, or with align-self, it
    /// shrinks to its columns (render.js gives it align-self: flex-start).
    fn stretched(table: *Node) bool {
        if (table.props.as != null) return false;
        const parent = table.parent orelse return false;
        const fd = parent.props.fd orelse "column";
        if (!std.mem.startsWith(u8, fd, "column")) return false;
        const ai = parent.props.ai orelse "stretch";
        return std.mem.eql(u8, ai, "stretch") or std.mem.eql(u8, ai, "normal");
    }

    /// The table's rows, through its row groups (not nested tables').
    fn collectRows(gpa: std.mem.Allocator, n: *Node, rows: *std.ArrayList(*Node)) !void {
        for (n.kids.items) |k| {
            if (k.props.trow) {
                try rows.append(gpa, k);
            } else if (k.props.table == null and k.props.tcell == null) {
                try collectRows(gpa, k, rows);
            }
        }
    }

    fn cellSpan(cell: *Node) ?usize {
        const s = cell.props.tcell orelse return null;
        if (!std.math.isFinite(s)) return 1;
        return @intFromFloat(std.math.clamp(s, 1, max_table_cols));
    }

    /// A cell laid out on its own with no width: its content's width.
    fn naturalWidth(cell: *Node) f32 {
        yg.YGNodeStyleSetWidthAuto(cell.yn);
        yg.YGNodeCalculateLayout(cell.yn, std.math.nan(f32), std.math.nan(f32), yg.YGDirectionLTR);
        var w = yg.YGNodeLayoutGetWidth(cell.yn);
        if (!std.math.isFinite(w)) w = 0;
        if (cell.props.w) |d| if (dimPx(d)) |px| {
            w = @max(w, px);
        };
        return w;
    }

    fn sumCols(cols: []const f32) f32 {
        var s: f32 = 0;
        for (cols) |c| s += c;
        return s;
    }

    /// Left + right padding and borders (a box's frame minus its content).
    fn edgesX(y: yg.YGNodeRef) f32 {
        return yg.YGNodeLayoutGetPadding(y, yg.YGEdgeLeft) + yg.YGNodeLayoutGetPadding(y, yg.YGEdgeRight) +
            yg.YGNodeLayoutGetBorder(y, yg.YGEdgeLeft) + yg.YGNodeLayoutGetBorder(y, yg.YGEdgeRight);
    }

    /// `view`: the visible box of the nearest scroll container (what a
    /// sticky box sticks to).
    fn place(n: *Node, ox: f32, oy: f32, clip: Rect, view: Rect) void {
        const p = n.props;
        n.frame = .{
            .x = ox + yg.YGNodeLayoutGetLeft(n.yn) + (p.tx orelse 0),
            .y = oy + yg.YGNodeLayoutGetTop(n.yn) + (p.ty orelse 0),
            .w = yg.YGNodeLayoutGetWidth(n.yn),
            .h = yg.YGNodeLayoutGetHeight(n.yn),
        };
        if (p.sticky) |ins| if (n.parent) |parent| stick(&n.frame, ins, view, parent.frame);
        n.clip = clip;
        var child_clip = clip;
        var child_view = view;
        if (p.scroll or p.scrollx or p.clip) child_clip = clip.intersect(n.frame);
        if (p.scroll or p.scrollx) child_view = n.frame;
        if (p.scroll) {
            var bottom: f32 = 0;
            for (n.kids.items) |k| bottom = @max(bottom, overflowBottom(k, 0));
            n.content_h = bottom + yg.YGNodeLayoutGetPadding(n.yn, yg.YGEdgeBottom);
            n.scroll_y = std.math.clamp(n.scroll_y, 0, @max(0, n.content_h - n.frame.h));
        }
        if (p.scrollx) {
            var right: f32 = 0;
            for (n.kids.items) |k| right = @max(right, overflowRight(k, 0));
            n.content_w = right + yg.YGNodeLayoutGetPadding(n.yn, yg.YGEdgeRight);
            n.scroll_x = std.math.clamp(n.scroll_x, 0, @max(0, n.content_w - n.frame.w));
        }
        const sy = if (p.scroll) n.scroll_y else 0;
        const sx = if (p.scrollx) n.scroll_x else 0;
        for (n.kids.items) |k| place(k, n.frame.x - sx, n.frame.y - sy, child_clip, child_view);
    }

    /// position: sticky: the box stays in the scroll container's view (minus
    /// its insets) as the page scrolls, but never leaves its parent's box.
    fn stick(f: *Rect, ins: [4]?f32, view: Rect, parent: Rect) void {
        if (ins[0]) |top| {
            const want = @min(view.y + top, parent.y + parent.h - f.h);
            if (want > f.y) f.y = want;
        }
        if (ins[2]) |bottom| {
            const want = @max(view.y + view.h - bottom - f.h, parent.y);
            if (want < f.y) f.y = want;
        }
        if (ins[3]) |left| {
            const want = @min(view.x + left, parent.x + parent.w - f.w);
            if (want > f.x) f.x = want;
        }
        if (ins[1]) |right| {
            const want = @max(view.x + view.w - right - f.w, parent.x);
            if (want < f.x) f.x = want;
        }
    }

    /// How far right a node's box reaches, with what overflows it (the
    /// horizontal twin of overflowBottom).
    fn overflowRight(k: *Node, left: f32) f32 {
        const x = left + yg.YGNodeLayoutGetLeft(k.yn);
        var right = x + yg.YGNodeLayoutGetWidth(k.yn) + yg.YGNodeLayoutGetMargin(k.yn, yg.YGEdgeRight);
        if (!k.props.scroll and !k.props.scrollx and !k.props.clip) {
            for (k.kids.items) |c| right = @max(right, overflowRight(c, x));
        }
        return right;
    }

    /// How far down a node's box reaches, with what overflows it (CSS's
    /// scrollable overflow): a page whose body is `height: 100%` still
    /// scrolls its taller content. A box that clips or scrolls keeps its
    /// own overflow. `top`: the parent's top in the scroll container.
    fn overflowBottom(k: *Node, top: f32) f32 {
        const y = top + yg.YGNodeLayoutGetTop(k.yn);
        var bottom = y + yg.YGNodeLayoutGetHeight(k.yn) + yg.YGNodeLayoutGetMargin(k.yn, yg.YGEdgeBottom);
        if (!k.props.scroll and !k.props.scrollx and !k.props.clip) {
            for (k.kids.items) |c| bottom = @max(bottom, overflowBottom(c, y));
        }
        return bottom;
    }

    /// Debugging (ORIEL_NUI_DUMP=1): the laid-out tree on stderr.
    pub fn dump(t: *Tree) void {
        const root = t.root orelse return;
        dumpNode(root, 0);
    }

    fn dumpNode(n: *Node, depth: usize) void {
        var text: []const u8 = "";
        if (n.props.runs) |runs| if (runs.len > 0) {
            text = runs[0].t;
        };
        var pad: [64]u8 = undefined;
        @memset(&pad, ' ');
        std.debug.print("{s}{s}#{d} {d:.0},{d:.0} {d:.0}x{d:.0} \"{s}\"\n", .{ pad[0..@min(depth * 2, 64)], @tagName(n.kind), n.id, n.frame.x, n.frame.y, n.frame.w, n.frame.h, text[0..@min(text.len, 30)] });
        for (n.kids.items) |k| dumpNode(k, depth + 1);
    }

    /// Re-place after a scroll (no new layout).
    pub fn replace(t: *Tree) void {
        const root = t.root orelse return;
        const window: Rect = .{ .w = t.width, .h = t.height };
        place(root, 0, 0, window, window);
    }

    /// The deepest node under a point (later siblings on top).
    pub fn hit(t: *Tree, x: f32, y: f32) ?*Node {
        const root = t.root orelse return null;
        return hitIn(root, x, y);
    }

    fn hitIn(n: *Node, x: f32, y: f32) ?*Node {
        if (n.props.vis == false) return null;
        if (!n.clip.contains(x, y)) return null;
        // Topmost first: the paint order backwards.
        var it: PaintIter = .{ .kids = n.kids.items, .reverse = true };
        while (it.next()) |k| if (hitIn(k, x, y)) |h| return h;
        return if (n.frame.contains(x, y) and n.props.root == false) n else null;
    }

    /// The nearest scroll container around a node (or the node itself).
    pub fn scroller(_: *Tree, start: ?*Node) ?*Node {
        var n = start;
        while (n) |x| : (n = x.parent) if (x.props.scroll and x.content_h > x.frame.h + 0.5) return x;
        return null;
    }

    /// The nearest container that can scroll sideways.
    pub fn scrollerX(_: *Tree, start: ?*Node) ?*Node {
        var n = start;
        while (n) |x| : (n = x.parent) if (x.props.scrollx and x.content_w > x.frame.w + 0.5) return x;
        return null;
    }

    /// Scroll so a node is visible (block: start, end, center, nearest).
    pub fn scrollIntoView(t: *Tree, node: *Node, block: []const u8) void {
        var n: ?*Node = node.parent;
        var target = node.frame;
        while (n) |s| : (n = s.parent) {
            if (!s.props.scroll) continue;
            const top_in_content = target.y - s.frame.y + s.scroll_y;
            const want = if (std.mem.eql(u8, block, "end"))
                top_in_content + target.h - s.frame.h
            else if (std.mem.eql(u8, block, "center"))
                top_in_content + target.h / 2 - s.frame.h / 2
            else
                top_in_content;
            s.scroll_y = std.math.clamp(want, 0, @max(0, s.content_h - s.frame.h));
            target = s.frame;
        }
        t.replace();
    }
};

fn measureFn(node: yg.YGNodeConstRef, width: f32, width_mode: yg.YGMeasureMode, height: f32, height_mode: yg.YGMeasureMode) callconv(.c) yg.YGSize {
    _ = height;
    _ = height_mode;
    const n: *Node = @ptrCast(@alignCast(yg.YGNodeGetContext(node)));
    const max_w: f32 = if (width_mode == yg.YGMeasureModeUndefined or std.math.isNan(width)) std.math.inf(f32) else width;
    var out: [2]f32 = .{ 0, 0 };
    const m0 = prof.now();
    n.tree.measure(n.tree.measure_ctx, n, max_w, &out);
    if (prof.enabled) {
        prof.measure_ms += prof.now() - m0;
        prof.measures += 1;
    }
    // A textarea is `cols` characters wide (about 0.6 em each, plus its
    // padding), as in a browser, not as wide as it may be; stretched in a
    // flex column it still fills it (that width is exact).
    if (n.kind == .textarea) if (n.props.cols) |cols| {
        const fz = n.props.fz orelse 16;
        out[0] = @min(out[0], cols * fz * 0.6 + 8);
    };
    if (width_mode == yg.YGMeasureModeExactly) out[0] = width;
    if (width_mode == yg.YGMeasureModeAtMost) out[0] = @min(out[0], width);
    return .{ .width = out[0], .height = out[1] };
}

/// A Dim's string into the node's arena (numbers need nothing).
fn ownDim(a: std.mem.Allocator, d: *Dim) !void {
    d.* = switch (d.*) {
        .string, .number_string, .array, .object => try cloneValue(a, d.*),
        else => return,
    };
}

/// The Dims in parsed props, which still point into the ops' JSON.
fn ownProps(a: std.mem.Allocator, p: *Props) !void {
    inline for (std.meta.fields(Props)) |f| {
        switch (f.type) {
            ?Dim => if (@field(p, f.name)) |*d| try ownDim(a, d),
            ?[4]Dim => if (@field(p, f.name)) |*arr| for (arr) |*d| try ownDim(a, d),
            ?[4]?Dim => if (@field(p, f.name)) |*arr| for (arr) |*od| if (od.*) |*d| try ownDim(a, d),
            else => {},
        }
    }
    if (p.bg) |*bg| if (bg.gradient) |*g| if (g.radial) |*r| for (r) |*d| try ownDim(a, d);
}

fn cloneValue(a: std.mem.Allocator, v: std.json.Value) !std.json.Value {
    return switch (v) {
        .string => |s| .{ .string = try a.dupe(u8, s) },
        .number_string => |s| .{ .number_string = try a.dupe(u8, s) },
        .array => |arr| blk: {
            var out = std.json.Array.init(a);
            try out.ensureTotalCapacity(arr.items.len);
            for (arr.items) |x| out.appendAssumeCapacity(try cloneValue(a, x));
            break :blk .{ .array = out };
        },
        .object => |obj| blk: {
            var out: std.json.ObjectMap = .empty;
            var it = obj.iterator();
            while (it.next()) |e| try out.put(a, try a.dupe(u8, e.key_ptr.*), try cloneValue(a, e.value_ptr.*));
            break :blk .{ .object = out };
        },
        else => v,
    };
}

// ---------------------------------------------------------------------------
// CSS → Yoga

fn styleYoga(n: *Node) void {
    applyYogaStyle(n.yn, n.props);
}

fn applyYogaStyle(y: yg.YGNodeRef, p: Props) void {
    yg.YGNodeStyleSetFlexDirection(y, flexDir(p.fd));
    yg.YGNodeStyleSetFlexWrap(y, if (p.fw) |w| (if (std.mem.eql(u8, w, "wrap-reverse")) yg.YGWrapWrapReverse else yg.YGWrapWrap) else yg.YGWrapNoWrap);
    yg.YGNodeStyleSetJustifyContent(y, justify(p.jc));
    yg.YGNodeStyleSetAlignItems(y, alignOf(p.ai, yg.YGAlignStretch));
    yg.YGNodeStyleSetAlignSelf(y, alignOf(p.as, yg.YGAlignAuto));
    yg.YGNodeStyleSetAlignContent(y, alignOf(p.ac, yg.YGAlignFlexStart));
    yg.YGNodeStyleSetFlexGrow(y, p.fg orelse 0);
    yg.YGNodeStyleSetFlexShrink(y, p.fs orelse 1);
    dim(y, p.fb, yg.YGNodeStyleSetFlexBasis, yg.YGNodeStyleSetFlexBasisPercent, yg.YGNodeStyleSetFlexBasisAuto);
    dim(y, p.w, yg.YGNodeStyleSetWidth, yg.YGNodeStyleSetWidthPercent, yg.YGNodeStyleSetWidthAuto);
    dim(y, p.h, yg.YGNodeStyleSetHeight, yg.YGNodeStyleSetHeightPercent, yg.YGNodeStyleSetHeightAuto);
    dimNoAuto(y, p.minw, yg.YGNodeStyleSetMinWidth, yg.YGNodeStyleSetMinWidthPercent);
    dimNoAuto(y, p.minh, yg.YGNodeStyleSetMinHeight, yg.YGNodeStyleSetMinHeightPercent);
    dimNoAuto(y, p.maxw, yg.YGNodeStyleSetMaxWidth, yg.YGNodeStyleSetMaxWidthPercent);
    dimNoAuto(y, p.maxh, yg.YGNodeStyleSetMaxHeight, yg.YGNodeStyleSetMaxHeightPercent);
    const edges = [4]yg.YGEdge{ yg.YGEdgeTop, yg.YGEdgeRight, yg.YGEdgeBottom, yg.YGEdgeLeft };
    for (edges, 0..) |e, i| {
        const m: Dim = if (p.m) |mm| mm[i] else .{ .integer = 0 };
        switch (m) {
            .string => |s| if (std.mem.eql(u8, s, "auto")) yg.YGNodeStyleSetMarginAuto(y, e) else if (pct(s)) |v| yg.YGNodeStyleSetMarginPercent(y, e, v) else yg.YGNodeStyleSetMargin(y, e, 0),
            else => yg.YGNodeStyleSetMargin(y, e, dimPx(m) orelse 0),
        }
        const pd: Dim = if (p.pad) |pp| pp[i] else .{ .integer = 0 };
        switch (pd) {
            .string => |s| if (pct(s)) |v| yg.YGNodeStyleSetPaddingPercent(y, e, v) else yg.YGNodeStyleSetPadding(y, e, 0),
            else => yg.YGNodeStyleSetPadding(y, e, dimPx(pd) orelse 0),
        }
        yg.YGNodeStyleSetBorder(y, e, if (p.bw) |bw| bw[i] else 0);
        if (p.ins) |ins| {
            if (ins[i]) |v| switch (v) {
                .string => |s| if (pct(s)) |x| yg.YGNodeStyleSetPositionPercent(y, e, x) else yg.YGNodeStyleSetPositionAuto(y, e),
                else => yg.YGNodeStyleSetPosition(y, e, dimPx(v) orelse 0),
            } else yg.YGNodeStyleSetPositionAuto(y, e);
        } else if (p.rel) |rel| {
            if (rel[i]) |v| yg.YGNodeStyleSetPosition(y, e, v) else yg.YGNodeStyleSetPositionAuto(y, e);
        } else yg.YGNodeStyleSetPositionAuto(y, e);
    }
    yg.YGNodeStyleSetGap(y, yg.YGGutterRow, p.rg orelse 0);
    yg.YGNodeStyleSetGap(y, yg.YGGutterColumn, p.cg orelse 0);
    yg.YGNodeStyleSetPositionType(y, if (p.pos != null and std.mem.eql(u8, p.pos.?, "absolute")) yg.YGPositionTypeAbsolute else yg.YGPositionTypeRelative);
    yg.YGNodeStyleSetOverflow(y, if (p.scroll or p.scrollx) yg.YGOverflowScroll else if (p.clip) yg.YGOverflowHidden else yg.YGOverflowVisible);
    if (p.ar) |ar| yg.YGNodeStyleSetAspectRatio(y, ar) else yg.YGNodeStyleSetAspectRatio(y, std.math.nan(f32));
    yg.YGNodeStyleSetDisplay(y, yg.YGDisplayFlex);
}

fn dimPx(v: Dim) ?f32 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |x| @floatCast(x),
        else => null,
    };
}

fn pct(s: []const u8) ?f32 {
    if (!std.mem.endsWith(u8, s, "%")) return null;
    return std.fmt.parseFloat(f32, s[0 .. s.len - 1]) catch null;
}

fn dim(y: yg.YGNodeRef, v: ?Dim, set: anytype, set_pct: anytype, set_auto: anytype) void {
    const d = v orelse return set_auto(y);
    switch (d) {
        .string => |s| if (pct(s)) |x| set_pct(y, x) else set_auto(y),
        .null => set_auto(y),
        else => set(y, dimPx(d) orelse return set_auto(y)),
    }
}

fn dimNoAuto(y: yg.YGNodeRef, v: ?Dim, set: anytype, set_pct: anytype) void {
    const d = v orelse return set(y, std.math.nan(f32));
    switch (d) {
        .string => |s| if (pct(s)) |x| set_pct(y, x) else set(y, std.math.nan(f32)),
        else => set(y, dimPx(d) orelse std.math.nan(f32)),
    }
}

fn flexDir(s: ?[]const u8) yg.YGFlexDirection {
    const v = s orelse return yg.YGFlexDirectionColumn;
    if (std.mem.eql(u8, v, "row")) return yg.YGFlexDirectionRow;
    if (std.mem.eql(u8, v, "row-reverse")) return yg.YGFlexDirectionRowReverse;
    if (std.mem.eql(u8, v, "column-reverse")) return yg.YGFlexDirectionColumnReverse;
    return yg.YGFlexDirectionColumn;
}

fn justify(s: ?[]const u8) yg.YGJustify {
    const v = s orelse return yg.YGJustifyFlexStart;
    if (std.mem.eql(u8, v, "center")) return yg.YGJustifyCenter;
    if (std.mem.eql(u8, v, "flex-end") or std.mem.eql(u8, v, "end") or std.mem.eql(u8, v, "right")) return yg.YGJustifyFlexEnd;
    if (std.mem.eql(u8, v, "space-between")) return yg.YGJustifySpaceBetween;
    if (std.mem.eql(u8, v, "space-around")) return yg.YGJustifySpaceAround;
    if (std.mem.eql(u8, v, "space-evenly")) return yg.YGJustifySpaceEvenly;
    return yg.YGJustifyFlexStart;
}

fn alignOf(s: ?[]const u8, default: yg.YGAlign) yg.YGAlign {
    const v = s orelse return default;
    if (std.mem.eql(u8, v, "center")) return yg.YGAlignCenter;
    if (std.mem.eql(u8, v, "flex-start") or std.mem.eql(u8, v, "start") or std.mem.eql(u8, v, "self-start")) return yg.YGAlignFlexStart;
    if (std.mem.eql(u8, v, "flex-end") or std.mem.eql(u8, v, "end") or std.mem.eql(u8, v, "self-end")) return yg.YGAlignFlexEnd;
    if (std.mem.eql(u8, v, "stretch") or std.mem.eql(u8, v, "normal")) return yg.YGAlignStretch;
    if (std.mem.eql(u8, v, "baseline")) return yg.YGAlignBaseline;
    if (std.mem.eql(u8, v, "space-between")) return yg.YGAlignSpaceBetween;
    if (std.mem.eql(u8, v, "space-around")) return yg.YGAlignSpaceAround;
    if (std.mem.eql(u8, v, "auto")) return yg.YGAlignAuto;
    return default;
}

fn testMeasure(_: *anyopaque, _: *Node, _: f32, out: *[2]f32) void {
    out.* = .{ 10, 10 };
}

test "shared leaf styles own strings and isolate text and general updates" {
    if (!@import("build_options").native_ui) return error.SkipZigTest;
    var ctx: u8 = 0;
    var t = Tree.init(std.testing.allocator, &ctx, testMeasure);
    defer t.deinit();
    const source = try std.testing.allocator.dupe(u8,
        \\{"w":"50%","pad":[1,2,3,4],"fz":18,"runs":[{"t":"","sz":18,"w":700,"c":[255,0,0,1]}]}
    );
    defer std.testing.allocator.free(source);
    try std.testing.expect(try t.defineLeafStyle(1, source));
    @memset(source, 'x');
    try std.testing.expect(try t.createLeaf(10, .text, 1, "first Ω\x00"));
    try std.testing.expect(try t.createLeaf(11, .text, 1, "second"));
    const a = t.get(10).?;
    const b = t.get(11).?;
    try std.testing.expectEqualStrings("50%", a.props.w.?.string);
    try std.testing.expectEqualStrings("first Ω\x00", a.props.runs.?[0].t);
    try std.testing.expectEqualStrings("second", b.props.runs.?[0].t);
    const width = yg.YGNodeStyleGetWidth(a.yn);
    try std.testing.expectEqual(@as(yg.YGUnit, yg.YGUnitPercent), width.unit);
    try std.testing.expectEqual(@as(f32, 50), width.value);
    try std.testing.expectEqual(@as(f32, 4), yg.YGNodeStyleGetPadding(a.yn, yg.YGEdgeLeft).value);
    try std.testing.expect(yg.YGNodeHasMeasureFunc(a.yn));
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(a)), yg.YGNodeGetContext(a.yn));
    try std.testing.expect(!try t.createLeaf(10, .text, 1, "duplicate"));
    try std.testing.expect(!try t.createLeaf(12, .input, 1, "field"));
    try std.testing.expect(!try t.createLeaf(12, .view, 1, "not text"));
    try std.testing.expect(!try t.createLeaf(12, .text, 99, "missing"));
    try std.testing.expect(try t.updateText(10, "updated"));
    try std.testing.expectEqualStrings("second", b.props.runs.?[0].t);
    try t.apply(
        \\[["p",10,{"w":90,"runs":[{"t":"general","sz":22}]}]]
    );
    try std.testing.expectEqualStrings("general", a.props.runs.?[0].t);
    try std.testing.expectEqual(@as(f32, 22), a.props.runs.?[0].sz);
    try std.testing.expectEqual(@as(f32, 18), b.props.runs.?[0].sz);
    try std.testing.expectEqualStrings("50%", b.props.w.?.string);
    try std.testing.expectEqual(@as(f32, 90), yg.YGNodeStyleGetWidth(a.yn).value);
    try std.testing.expectEqual(@as(yg.YGUnit, yg.YGUnitPercent), yg.YGNodeStyleGetWidth(b.yn).unit);
    try std.testing.expectEqual(@as(f32, 50), yg.YGNodeStyleGetWidth(b.yn).value);
    try std.testing.expect(try t.defineLeafStyle(2, "{\"w\":8,\"h\":8,\"bg\":{\"color\":[255,0,0,1]}}"));
    try std.testing.expect(try t.createLeaf(12, .view, 2, ""));
    try std.testing.expectEqual(@as(i64, 8), t.get(12).?.props.w.?.integer);
    try std.testing.expect(!yg.YGNodeHasMeasureFunc(t.get(12).?.yn));
    try std.testing.expect(!try t.defineLeafStyle(2, "{}"));
}

test "a text changed in place gets its new longest word as min width in a row" {
    if (!@import("build_options").native_ui) return error.SkipZigTest;
    const Context = struct {
        // 10 px a character, unwrapped.
        fn measure(_: *anyopaque, n: *Node, _: f32, out: *[2]f32) void {
            out.* = .{ @floatFromInt(10 * n.props.runs.?[0].t.len), 10 };
        }
    };
    var ctx: u8 = 0;
    var t = Tree.init(std.testing.allocator, &ctx, Context.measure);
    defer t.deinit();
    try t.apply(
        \\[["c",0,"view"],["p",0,{"fd":"row"}],["c",1,"text"],["p",1,{"runs":[{"t":"longword"}]}],["k",0,[1]],["r",0]]
    );
    const n = t.get(1).?;
    try std.testing.expectEqual(@as(f32, 80), yg.YGNodeStyleGetMinWidth(n.yn).value);
    t.layout();
    try std.testing.expect(try t.updateText(1, "1"));
    try std.testing.expectEqual(@as(f32, 10), yg.YGNodeStyleGetMinWidth(n.yn).value);
    try std.testing.expect(t.dirty);
}

test "equal unwrapped text metrics reuse frames but invalidate future wrapping" {
    if (!@import("build_options").native_ui) return error.SkipZigTest;
    const Context = struct {
        epoch: u64 = 1,
        calls: usize = 0,
        fn measure(ctx: *anyopaque, n: *Node, width: f32, out: *[2]f32) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            c.calls += 1;
            const natural: [2]f32 = .{ if (std.mem.startsWith(u8, n.props.runs.?[0].t, "wide")) 30 else 20, 10 };
            n.measured_text_size = natural;
            n.text_measure_epoch = c.epoch;
            out.* = natural;
            if (!n.props.nowrap and width < natural[0]) {
                out.* = .{ width, if (std.mem.indexOfScalar(u8, n.props.runs.?[0].t, ' ') != null) 30 else 20 };
            }
        }
    };
    var ctx: Context = .{};
    var t = Tree.init(std.testing.allocator, &ctx, Context.measure);
    defer t.deinit();
    t.reuse_text_layout = true;
    try t.apply(
        \\[["c",0,"view"],["p",0,{"fd":"column"}],["c",1,"text"],["p",1,{"runs":[{"t":"aaaa"}]}],["k",0,[1]],["r",0]]
    );
    t.layout();
    const n = t.get(1).?;
    const original = n.frame;
    try std.testing.expect(try t.updateText(1, "a a"));
    try std.testing.expect(!t.dirty);
    try std.testing.expect(t.paint_dirty);
    try std.testing.expectEqualDeep(original, n.frame);
    try std.testing.expect(yg.YGNodeIsDirty(n.yn));
    // The retained frame was valid at the old width. A later narrow layout
    // must measure the new words rather than using Yoga's old text cache.
    t.width = 10;
    t.dirty = true;
    t.layout();
    try std.testing.expectEqual(@as(f32, 30), n.frame.h);
    try std.testing.expect(try t.updateText(1, "bbbb"));
    try std.testing.expect(t.dirty); // equal natural size, but currently wrapped
    t.layout();
    try std.testing.expectEqual(@as(f32, 20), n.frame.h);
    t.width = 800;
    t.dirty = true;
    t.layout();
    ctx.epoch += 1;
    try std.testing.expect(try t.updateText(1, "cccc"));
    try std.testing.expect(t.dirty); // same metrics, changed font context
    t.layout();
    try std.testing.expect(try t.updateText(1, "wide text"));
    try std.testing.expect(t.dirty); // changed intrinsic width
}

test "a node can't become its own descendant" {
    if (!@import("build_options").native_ui) return error.SkipZigTest;
    var ctx: u8 = 0;
    var t = Tree.init(std.testing.allocator, &ctx, testMeasure);
    defer t.deinit();
    try t.apply(
        \\[["c",900,"view"],["c",901,"view"],["k",900,[901]],["k",901,[900,901]],["r",900]]
    );
    try std.testing.expectEqual(@as(usize, 0), t.get(901).?.kids.items.len);
    try std.testing.expect(t.get(901).?.parent == t.get(900).?);
    t.layout();
}

test "bulk child replacement retains order and detached node ownership" {
    if (!@import("build_options").native_ui) return error.SkipZigTest;
    var ctx: u8 = 0;
    var t = Tree.init(std.testing.allocator, &ctx, testMeasure);
    defer t.deinit();
    try t.apply(
        \\[["c",0,"view"],["c",1,"view"],["c",2,"view"],["c",3,"view"],["c",4,"view"],["k",0,[1,2,3]],["r",0]]
    );
    const one = t.get(1).?;
    const two = t.get(2).?;
    const three = t.get(3).?;
    try t.apply("[[\"k\",0,[3,1]]]");
    try std.testing.expectEqual(two, t.get(2).?);
    try std.testing.expect(two.parent == null);
    try std.testing.expect(yg.YGNodeGetOwner(two.yn) == null);
    try std.testing.expectEqual(three.yn, yg.YGNodeGetChild(t.get(0).?.yn, 0));
    try std.testing.expectEqual(one.yn, yg.YGNodeGetChild(t.get(0).?.yn, 1));
    try t.apply("[[\"k\",4,[1,2]],[\"k\",0,[3,4]]]");
    try std.testing.expectEqual(t.get(4).?, one.parent.?);
    try std.testing.expectEqual(t.get(4).?, two.parent.?);
    try std.testing.expectEqual(three, t.get(0).?.kids.items[0]);
    try t.apply("[[\"d\",4]]");
    try std.testing.expect(one.parent == null and two.parent == null);
    try std.testing.expect(yg.YGNodeGetOwner(one.yn) == null);
    try std.testing.expectEqual(one, t.get(1).?);
    try std.testing.expectEqual(@as(usize, 1), t.get(0).?.kids.items.len);
    try t.apply("[[\"k\",0,[]]]");
    try std.testing.expect(three.parent == null);
    try std.testing.expectEqual(@as(usize, 0), yg.YGNodeGetChildCount(t.get(0).?.yn));
}

test "children rejected by measured leaves detach before old parent destruction" {
    if (!@import("build_options").native_ui) return error.SkipZigTest;
    for ([_]Kind{ .text, .input, .textarea, .select, .image }) |kind| {
        var ctx: u8 = 0;
        var t = Tree.init(std.testing.allocator, &ctx, testMeasure);
        defer t.deinit();
        try t.apply(
            \\[["c",1,"view"],["c",2,"view"],["c",4,"view"],["k",1,[2]]]
        );
        const ops = try std.fmt.allocPrint(std.testing.allocator, "[[\"c\",3,\"{s}\"],[\"k\",3,[2]]]", .{@tagName(kind)});
        defer std.testing.allocator.free(ops);
        try t.apply(ops);
        const child = t.get(2).?;
        try std.testing.expect(child.parent == null);
        try std.testing.expect(yg.YGNodeGetOwner(child.yn) == null);
        try std.testing.expectEqual(@as(usize, 0), t.get(1).?.kids.items.len);
        try std.testing.expectEqual(@as(usize, 0), t.get(3).?.kids.items.len);
        // The old parent may now be freed; reattachment must not dereference it.
        try t.apply("[[\"d\",1],[\"k\",4,[2]],[\"r\",4]]");
        try std.testing.expectEqual(t.get(4).?, child.parent.?);
        try std.testing.expectEqual(child.yn, yg.YGNodeGetChild(t.get(4).?.yn, 0));
        t.layout();
    }
}

test "shared Yoga styles lay out like general property updates" {
    if (!@import("build_options").native_ui) return error.SkipZigTest;
    var ctx: u8 = 0;
    var shared = Tree.init(std.testing.allocator, &ctx, testMeasure);
    defer shared.deinit();
    var general = Tree.init(std.testing.allocator, &ctx, testMeasure);
    defer general.deinit();
    const root =
        \\[["c",0,"view"],["p",0,{"fd":"row","fw":"wrap","ai":"center","cg":7,"rg":3,"pad":[2,4,6,8]}],["r",0]]
    ;
    const props =
        \\{"w":"40%","minh":20,"maxw":350,"m":[3,5,7,9],"pad":[1,2,3,4],"bw":[0,1,2,3],"fg":1,"fs":0,"as":"flex-end","runs":[{"t":"first","sz":18}]}
    ;
    try shared.apply(root);
    try general.apply(root);
    try std.testing.expect(try shared.defineLeafStyle(1, props));
    for (1..4) |i| {
        const id: i64 = @intCast(i);
        try std.testing.expect(try shared.createLeaf(id, .text, 1, "first"));
        const ops = try std.fmt.allocPrint(std.testing.allocator, "[[\"c\",{d},\"text\"],[\"p\",{d},{s}]]", .{ id, id, props });
        defer std.testing.allocator.free(ops);
        try general.apply(ops);
    }
    try shared.apply("[[\"k\",0,[1,2,3]]]");
    try general.apply("[[\"k\",0,[1,2,3]]]");
    shared.layout();
    general.layout();
    for (0..4) |i| {
        const id: i64 = @intCast(i);
        try std.testing.expectEqualDeep(general.get(id).?.frame, shared.get(id).?.frame);
    }
}

fn leafAllocationFailures(gpa: std.mem.Allocator) !void {
    var ctx: u8 = 0;
    var t = Tree.init(gpa, &ctx, testMeasure);
    defer t.deinit();
    _ = try t.defineLeafStyle(1, "{\"w\":\"50%\",\"runs\":[{\"t\":\"\",\"sz\":18}]}");
    _ = try t.createLeaf(10, .text, 1, "owned text");
    _ = try t.updateText(10, "updated text");
}

test "leaf style and text creation clean up every allocation failure" {
    if (!@import("build_options").native_ui) return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, leafAllocationFailures, .{});
}

test "native node lookup survives repeated large list removals" {
    if (!@import("build_options").native_ui) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var ctx: u8 = 0;
    var t = Tree.init(gpa, &ctx, testMeasure);
    defer t.deinit();
    _ = try t.defineLeafStyle(1, "{\"w\":8,\"h\":8}");
    _ = try t.createLeaf(99, .view, 1, "");
    const permanent = t.get(99).?;
    for (0..3) |round| {
        const base: i64 = @intCast(100 + round * 2000);
        var ops: std.ArrayList(u8) = .empty;
        defer ops.deinit(gpa);
        try ops.append(gpa, '[');
        for (0..1100) |i| {
            const id = base + @as(i64, @intCast(i));
            try std.testing.expect(try t.createLeaf(id, .view, 1, ""));
            if (i > 0) try ops.append(gpa, ',');
            var buf: [48]u8 = undefined;
            try ops.appendSlice(gpa, try std.fmt.bufPrint(&buf, "[\"d\",{d}]", .{id}));
        }
        try ops.append(gpa, ']');
        try t.apply(ops.items);
        try std.testing.expectEqual(@as(u32, 1), t.nodes.count());
        try std.testing.expectEqual(permanent, t.get(99).?);
        try std.testing.expect(t.get(base) == null);
    }
}

test "a padded text in a flex row keeps its word plus its padding and border" {
    if (!@import("build_options").native_ui) return error.SkipZigTest;
    var ctx: u8 = 0;
    var t = Tree.init(std.testing.allocator, &ctx, testMeasure);
    defer t.deinit();
    try t.apply(
        \\[["c",1,"view"],["p",1,{"fd":"row"}],["c",2,"text"],["p",2,{"pad":[0,6,0,6],"bw":[1,1,1,1],"runs":[{"t":"Alpha","sz":14}]}],["k",1,[2]],["r",1]]
    );
    // testMeasure: 10 wide; + 6 + 6 padding + 1 + 1 border.
    const mw = yg.YGNodeStyleGetMinWidth(t.get(2).?.yn);
    try std.testing.expectEqual(@as(f32, 24), mw.value);
}

test "flex: 1 labels in a row stay equal with room and keep whole words without" {
    if (!@import("build_options").native_ui) return error.SkipZigTest;
    const Context = struct {
        // 10 px a character, unwrapped.
        fn measure(_: *anyopaque, n: *Node, _: f32, out: *[2]f32) void {
            const s = std.unicode.utf8CountCodepoints(n.props.runs.?[0].t) catch 0;
            out.* = .{ @floatFromInt(10 * s), 10 };
        }
    };
    var ctx: u8 = 0;
    var t = Tree.init(std.testing.allocator, &ctx, Context.measure);
    defer t.deinit();
    try t.apply(
        \\[["c",0,"view"],["p",0,{"fd":"row"}],
        \\["c",1,"text"],["p",1,{"fg":1,"fb":0,"runs":[{"t":"Auto"}]}],
        \\["c",2,"text"],["p",2,{"fg":1,"fb":0,"runs":[{"t":"English"}]}],
        \\["c",3,"text"],["p",3,{"fg":1,"fb":0,"runs":[{"t":"Español"}]}],
        \\["k",0,[1,2,3]],["r",0]]
    );
    const auto = t.get(1).?;
    const english = t.get(2).?;
    const espanol = t.get(3).?;
    // Room for every word: equal thirds, as in a browser.
    t.width = 300;
    t.height = 100;
    t.layout();
    for ([_]*Node{ auto, english, espanol }) |n| try std.testing.expectEqual(@as(f32, 100), yg.YGNodeLayoutGetWidth(n.yn));
    // A third (66.7) is less than "English" and "Español" (70): they keep
    // their words, "Auto" takes the rest.
    t.width = 200;
    t.layout();
    try std.testing.expectEqual(@as(f32, 70), yg.YGNodeLayoutGetWidth(english.yn));
    try std.testing.expectEqual(@as(f32, 70), yg.YGNodeLayoutGetWidth(espanol.yn));
    try std.testing.expectEqual(@as(f32, 60), yg.YGNodeLayoutGetWidth(auto.yn));
    // Wide again: equal again (nothing stays frozen).
    t.width = 300;
    t.layout();
    for ([_]*Node{ auto, english, espanol }) |n| try std.testing.expectEqual(@as(f32, 100), yg.YGNodeLayoutGetWidth(n.yn));
}

test "direct text updates preserve props, dirty layout, and release overrides" {
    if (!@import("build_options").native_ui) return error.SkipZigTest;
    var ctx: u8 = 0;
    var t = Tree.init(std.testing.allocator, &ctx, testMeasure);
    defer t.deinit();
    try t.apply(
        \\[["c",1,"text"],["p",1,{"w":100,"fz":18,"pad":[1,2,3,4],"runs":[{"t":"old","sz":18,"w":700,"c":[255,0,0,1]}]}],["r",1]]
    );
    const n = t.get(1).?;
    t.layout();
    try std.testing.expect(!t.dirty);
    n.measured_text_size = .{ 10, 10 };
    try std.testing.expect(try t.updateText(1, "new Ω\x00text"));
    try std.testing.expect(n.measured_text_size == null);
    try std.testing.expect(t.dirty);
    try std.testing.expect(yg.YGNodeIsDirty(n.yn));
    const run = n.props.runs.?[0];
    try std.testing.expectEqualStrings("new Ω\x00text", run.t);
    try std.testing.expectEqual(@as(f32, 18), run.sz);
    try std.testing.expectEqual(@as(f32, 700), run.w);
    try std.testing.expectEqual(@as(f32, 255), run.c[0]);
    try std.testing.expectEqual(@as(i64, 100), n.props.w.?.integer);
    try std.testing.expectEqual(@as(i64, 2), n.props.pad.?[1].integer);
    for (0..10) |_| try std.testing.expect(try t.updateText(1, "again"));
    try std.testing.expect(!try t.updateText(99, "unknown"));
    try t.apply(
        \\[["p",1,{"runs":[{"t":"general"}]}]]
    );
    try std.testing.expect(n.text_override == null);
    try std.testing.expectEqualStrings("general", n.props.runs.?[0].t);
    try t.apply(
        \\[["p",1,{"runs":[{"t":"one"},{"t":"two"}]}]]
    );
    try std.testing.expect(!try t.updateText(1, "mixed"));
}

test "a field's pending value survives a props update without one" {
    if (!@import("build_options").native_ui) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var ctx: u8 = 0;
    var t = Tree.init(gpa, &ctx, testMeasure);
    defer t.deinit();
    try t.apply("[[\"c\",1,\"input\"],[\"r\",1]]");
    const long = "x" ** 3000;
    try t.apply("[[\"p\",1,{\"val\":\"" ++ long ++ "\"}]]");
    // A large update without `val` (a transition, a placeholder): the props
    // arena is reset and grows past its old buffer.
    try t.apply("[[\"p\",1,{\"ph\":\"" ++ ("y" ** 20000) ++ "\"}]]");
    const n = t.get(1).?;
    try std.testing.expectEqualStrings(long, n.pending_value.?);
}

test "props' strings outlive the ops they came in" {
    if (!@import("build_options").native_ui) return error.SkipZigTest;
    var ctx: u8 = 0;
    var t = Tree.init(std.testing.allocator, &ctx, testMeasure);
    defer t.deinit();
    try t.apply("[[\"c\",1,\"view\"],[\"p\",1,{\"w\":\"50%\",\"m\":[\"auto\",1,2,\"10%\"],\"ins\":[null,\"5%\",3,null],\"bg\":{\"gradient\":{\"radial\":[\"50%\",\"25%\",8,\"71%\"],\"stops\":[[1,2,3,1,0]]}},\"fd\":\"row\"}]]");
    // Another apply reuses the freed ops memory.
    try t.apply("[[\"c\",2,\"view\"],[\"p\",2,{\"w\":\"XXXXXXXX\",\"m\":[\"XXXXXXX\",1,2,\"XXXXXX\"],\"fd\":\"column\"}]]");
    const p = t.get(1).?.props;
    try std.testing.expectEqualStrings("50%", p.w.?.string);
    try std.testing.expectEqualStrings("auto", p.m.?[0].string);
    try std.testing.expectEqualStrings("10%", p.m.?[3].string);
    try std.testing.expectEqualStrings("5%", p.ins.?[1].?.string);
    try std.testing.expectEqualStrings("71%", p.bg.?.gradient.?.radial.?[3].string);
    try std.testing.expectEqualStrings("row", p.fd.?);
}

test "ops with a bad shape or id are skipped" {
    if (!@import("build_options").native_ui) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var ctx: u8 = 0;
    var t = Tree.init(gpa, &ctx, testMeasure);
    defer t.deinit();
    try t.apply("[1,[],[\"\"],[\"c\"],[\"c\",1e300,\"view\"],[\"c\",2],[\"k\",3,5],[\"p\",4]]");
    try std.testing.expectEqual(@as(usize, 0), t.nodes.count());
    try std.testing.expectError(error.BadOps, t.apply("{}"));
}

test "canvas ops parse" {
    // Pure JSON → CanvasCmd, no Yoga or native_ui needed.
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\[["sv"],["sf",[255,0,0,1]],["ss",["g",3]],["fr",1,2,3,4],["ar",5,6,7,8,9,1],["tx","hi",10,11],["fo",1,700,16,"sans-serif"],["gs",3,0.5,1,2,3,4]]
    , .{});
    const cmds = try parseCanvasCmds(a, json);
    try t.expectEqual(8, cmds.len);
    try t.expectEqual(CanvasCmd.save, cmds[0]);
    try t.expectEqual([4]f32{ 255, 0, 0, 1 }, cmds[1].fill_style.color);
    try t.expectEqual(@as(u16, 3), cmds[2].stroke_style.grad);
    try t.expectEqual([4]f32{ 1, 2, 3, 4 }, cmds[3].fill_rect);
    try t.expectEqual(@as(f32, 5), cmds[4].arc.x);
    try t.expectEqual(@as(f32, 7), cmds[4].arc.r);
    try t.expect(cmds[4].arc.ccw);
    try t.expectEqualStrings("hi", cmds[5].fill_text.t);
    try t.expectEqual(@as(f32, 16), cmds[6].font.size);
    try t.expect(cmds[6].font.italic);
    try t.expectEqual(@as(f32, 0.5), cmds[7].color_stop.off);
    // Words as canvas.js sends them, and gradients' points after their id.
    const words = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\[["lc","round"],["lj","bevel"],["ta","end"],["tb","middle"],["tb","ideographic"],["lc","nope"],["gl",4,1,2,3,5],["gr",5,1,2,3,4,6,7]]
    , .{});
    const wc = try parseCanvasCmds(a, words);
    try t.expectEqual(7, wc.len);
    try t.expectEqual(@as(u2, 1), wc[0].line_cap);
    try t.expectEqual(@as(u2, 2), wc[1].line_join);
    try t.expectEqual(@as(u2, 2), wc[2].text_align);
    try t.expectEqual(@as(u3, 3), wc[3].text_baseline);
    try t.expectEqual(@as(u3, 4), wc[4].text_baseline);
    try t.expectEqual(@as(u16, 4), wc[5].linear_gradient.id);
    try t.expectEqual(@as(f32, 1), wc[5].linear_gradient.x0);
    try t.expectEqual(@as(f32, 5), wc[5].linear_gradient.y1);
    try t.expectEqual(@as(u16, 5), wc[6].radial_gradient.id);
    try t.expectEqual(@as(f32, 3), wc[6].radial_gradient.r0);
    try t.expectEqual(@as(f32, 4), wc[6].radial_gradient.x1);
    try t.expectEqual(@as(f32, 7), wc[6].radial_gradient.r1);
    // Junk ops are dropped, not fatal.
    const junk = try std.json.parseFromSliceLeaky(std.json.Value, a, "[[42],[\"zz\",1],[\"fr\",1,2,3,4]]", .{});
    const ok = try parseCanvasCmds(a, junk);
    try t.expectEqual(1, ok.len);
    // Arguments that overflow f32 (a browser ignores non-finite calls).
    const huge = try std.json.parseFromSliceLeaky(std.json.Value, a, "[[\"ts\",1e300,1],[\"fr\",1,2,3,4]]", .{});
    try t.expectEqual(1, (try parseCanvasCmds(a, huge)).len);
}

test "idOf: JS numbers to node ids" {
    try std.testing.expectEqual(@as(i64, 42), Tree.idOf(42));
    try std.testing.expectEqual(@as(i64, -1), Tree.idOf(-1));
    try std.testing.expectEqual(@as(i64, 0), Tree.idOf(0));
    const none = std.math.minInt(i64);
    try std.testing.expectEqual(none, Tree.idOf(std.math.nan(f64)));
    try std.testing.expectEqual(none, Tree.idOf(std.math.inf(f64)));
    try std.testing.expectEqual(none, Tree.idOf(-std.math.inf(f64)));
    try std.testing.expectEqual(none, Tree.idOf(1e300));
    try std.testing.expectEqual(none, Tree.idOf(-1e300));
}

test "a field's value set by the page survives props that don't repeat it" {
    // Yoga is linked only with -Dnative_ui.
    if (!@import("build_options").native_ui) return error.SkipZigTest;
    const Dummy = struct {
        fn measure(_: *anyopaque, _: *Node, _: f32, out: *[2]f32) void {
            out.* = .{ 10, 10 };
        }
    };
    var ctx: u8 = 0;
    var t = Tree.init(std.testing.allocator, &ctx, Dummy.measure);
    defer t.deinit();
    try t.apply("[[\"c\",1,\"input\"],[\"p\",1,{\"val\":\"typed by the page\"}]]");
    // Before the backend took it: new props without `val` (fields send it
    // only when it changed) reset the node's arena.
    try t.apply("[[\"p\",1,{\"ph\":\"a placeholder that reuses the arena's memory\"}]]");
    const n = t.get(1).?;
    try std.testing.expectEqualStrings("typed by the page", n.pending_value.?);
    try std.testing.expectEqualStrings("a placeholder that reuses the arena's memory", n.props.ph.?);
}

test "paint order: the flow, then positioned boxes, z-index around them" {
    const t = std.testing;
    var nodes: [6]Node = undefined;
    for (&nodes, 0..) |*n, i| n.* = .{ .id = @intCast(i), .kind = .view, .yn = undefined, .arena = undefined, .tree = undefined };
    nodes[0].props.sticky = .{ 0, null, null, null }; // a sticky header, first in the tree
    nodes[2].props.z = -1;
    nodes[3].props.pos = "absolute";
    nodes[3].props.z = 2;
    nodes[4].props.rel = .{ 1, null, null, null };
    var kids: [6]*Node = undefined;
    for (&kids, &nodes) |*k, *n| k.* = n;
    var order: [6]i64 = undefined;
    var it: PaintIter = .{ .kids = &kids };
    var i: usize = 0;
    while (it.next()) |n| : (i += 1) order[i] = n.id;
    try t.expectEqual(6, i);
    try t.expectEqualSlices(i64, &.{ 2, 1, 5, 0, 4, 3 }, &order);
    var rev: PaintIter = .{ .kids = &kids, .reverse = true };
    i = 0;
    while (rev.next()) |n| : (i += 1) order[i] = n.id;
    try t.expectEqualSlices(i64, &.{ 3, 4, 0, 5, 1, 2 }, &order);
    // Nothing positioned: tree order.
    var plain: [3]Node = undefined;
    for (&plain, 0..) |*n, j| n.* = .{ .id = @intCast(j), .kind = .view, .yn = undefined, .arena = undefined, .tree = undefined };
    var pk = [3]*Node{ &plain[0], &plain[1], &plain[2] };
    var pit: PaintIter = .{ .kids = &pk };
    try t.expectEqual(@as(i64, 0), pit.next().?.id);
    try t.expectEqual(@as(i64, 1), pit.next().?.id);
    try t.expectEqual(@as(i64, 2), pit.next().?.id);
    try t.expect(pit.next() == null);
}

test "sticky: kept in the view, never out of its parent" {
    const view: Rect = .{ .x = 0, .y = 0, .w = 400, .h = 600 };
    const parent: Rect = .{ .x = 0, .y = -300, .w = 400, .h = 1200 };
    // A footer (bottom: 0) below the view moves up to its bottom edge.
    var f: Rect = .{ .x = 0, .y = 840, .w = 400, .h = 60 };
    Tree.stick(&f, .{ null, null, 0, null }, view, parent);
    try std.testing.expectEqual(@as(f32, 540), f.y);
    // In view already: it stays.
    f = .{ .x = 0, .y = 200, .w = 400, .h = 60 };
    Tree.stick(&f, .{ null, null, 0, null }, view, parent);
    try std.testing.expectEqual(@as(f32, 200), f.y);
    // A header (top: 0) scrolled above the view comes down to its top...
    f = .{ .x = 0, .y = -100, .w = 400, .h = 40 };
    Tree.stick(&f, .{ 0, null, null, null }, view, parent);
    try std.testing.expectEqual(@as(f32, 0), f.y);
    // ...but not past the end of its parent (which ends at -80).
    f = .{ .x = 0, .y = -200, .w = 400, .h = 40 };
    Tree.stick(&f, .{ 0, null, null, null }, view, .{ .x = 0, .y = -300, .w = 400, .h = 220 });
    try std.testing.expectEqual(@as(f32, -120), f.y);
}

test "tables: columns as wide as their widest cell, spans widen them" {
    const noMeasure = struct {
        fn f(_: *anyopaque, _: *Node, _: f32, out: *[2]f32) void {
            out.* = .{ 0, 0 };
        }
    }.f;
    var ctx: u8 = 0;
    var t = Tree.init(std.testing.allocator, &ctx, noMeasure);
    defer t.deinit();
    t.width = 1000;
    t.height = 800;
    // A table (spacing 2) with two rows of fixed-width content, then a row
    // whose one cell spans both columns and needs more room than they have.
    try t.apply(
        \\[["c",0,"view"],["c",1,"view"],["c",2,"view"],["c",3,"view"],["c",12,"view"],
        \\ ["c",4,"view"],["c",5,"view"],["c",6,"view"],["c",7,"view"],["c",13,"view"],
        \\ ["c",8,"view"],["c",9,"view"],["c",10,"view"],["c",11,"view"],["c",14,"view"],
        \\ ["p",0,{"root":true,"fd":"column","ai":"stretch"}],
        \\ ["p",1,{"table":2,"fd":"column","ai":"stretch","as":"flex-start","rg":2,"pad":[2,2,2,2]}],
        \\ ["p",2,{"trow":true,"fd":"row","ai":"stretch","cg":2}],
        \\ ["p",3,{"trow":true,"fd":"row","ai":"stretch","cg":2}],
        \\ ["p",12,{"trow":true,"fd":"row","ai":"stretch","cg":2}],
        \\ ["p",4,{"tcell":1,"fs":0}],["p",5,{"tcell":1,"fs":0}],["p",6,{"tcell":1,"fs":0}],["p",7,{"tcell":1,"fs":0}],
        \\ ["p",13,{"tcell":2,"fs":0}],
        \\ ["p",8,{"w":50,"h":10}],["p",9,{"w":100,"h":10}],["p",10,{"w":80,"h":10}],["p",11,{"w":20,"h":10}],
        \\ ["p",14,{"w":250,"h":10}],
        \\ ["k",4,[8]],["k",5,[9]],["k",6,[10]],["k",7,[11]],["k",13,[14]],
        \\ ["k",2,[4,5]],["k",3,[6,7]],["k",12,[13]],["k",1,[2,3,12]],["k",0,[1]],["r",0]]
    );
    t.layout();
    const w = struct {
        fn of(tree: *Tree, id: i64) f32 {
            return tree.get(id).?.frame.w;
        }
    }.of;
    // Columns 80 and 100 (182 with the gap) widened to the spanning 250:
    // 34 more each.
    try std.testing.expectEqual(@as(f32, 114), w(&t, 4));
    try std.testing.expectEqual(@as(f32, 134), w(&t, 5));
    try std.testing.expectEqual(@as(f32, 114), w(&t, 6));
    try std.testing.expectEqual(@as(f32, 134), w(&t, 7));
    try std.testing.expectEqual(@as(f32, 250), w(&t, 13));
    // The table: its columns, the gap and its padding.
    try std.testing.expectEqual(@as(f32, 254), w(&t, 1));
}

test "stampRow makes, keeps, updates and drops a row's leaves" {
    if (!@import("build_options").native_ui) return error.SkipZigTest;
    var ctx: u8 = 0;
    var t = Tree.init(std.testing.allocator, &ctx, testMeasure);
    defer t.deinit();
    try std.testing.expect(try t.defineLeafStyle(1, "{\"fz\":14,\"runs\":[{\"t\":\"\",\"sz\":14,\"w\":400,\"c\":[0,0,0,1]}]}"));
    try std.testing.expect(try t.defineLeafStyle(2, "{\"w\":8,\"h\":8}"));
    try t.apply("[[\"c\",0,\"view\"],[\"c\",5,\"view\"],[\"p\",5,{\"fd\":\"row\"}],[\"k\",0,[5]],[\"r\",0]]");
    // A plan: two children, laid out in reverse order.
    const plan = try t.defineStampPlan(&.{ 2, 1, 2, 0, 1, 2, 1, 1, 0 });
    try std.testing.expect(plan > 0);
    try std.testing.expectEqual(@as(usize, 2), t.stampPlan(plan).?.entries.len);
    try std.testing.expectEqual(@as(u32, 0), try t.defineStampPlan(&.{ 2, 1, 2, 0 }));

    const first = [_]Tree.StampLeaf{ .{ .id = 11, .kind = .view, .style = 2, .text = "" }, .{ .id = 10, .kind = .text, .style = 1, .text = "Row 1" } };
    try std.testing.expect(try t.stampRow(5, &first));
    const row = t.get(5).?;
    try std.testing.expect(t.get(10).?.stamp_owned and t.get(11).?.stamp_owned);
    try std.testing.expectEqual(@as(usize, 2), row.kids.items.len);
    try std.testing.expectEqual(@as(i64, 11), row.kids.items[0].id);
    const text = t.get(10).?;
    try std.testing.expectEqualStrings("Row 1", text.props.runs.?[0].t);

    // Again with a new text: the same leaf, updated in place.
    const second = [_]Tree.StampLeaf{ .{ .id = 11, .kind = .view, .style = 2, .text = "" }, .{ .id = 10, .kind = .text, .style = 1, .text = "Row 1, updated" } };
    try std.testing.expect(try t.stampRow(5, &second));
    try std.testing.expect(t.get(10).? == text);
    try std.testing.expectEqualStrings("Row 1, updated", text.props.runs.?[0].t);

    // The text child empty now: a box; the other child gone.
    const third = [_]Tree.StampLeaf{.{ .id = 10, .kind = .view, .style = 2, .text = "" }};
    try std.testing.expect(try t.stampRow(5, &third));
    try std.testing.expect(t.get(11) == null);
    try std.testing.expectEqual(Kind.view, t.get(10).?.kind);
    try std.testing.expectEqual(@as(usize, 1), row.kids.items.len);

    // An unknown style changes nothing.
    const bad = [_]Tree.StampLeaf{.{ .id = 12, .kind = .view, .style = 9, .text = "" }};
    try std.testing.expect(!try t.stampRow(5, &bad));
    try std.testing.expect(t.get(10) != null);

    // The page's ops set its children: the stamped ones go.
    try t.apply("[[\"c\",20,\"view\"],[\"k\",5,[20]]]");
    try std.testing.expect(t.get(10) == null);

    // Stamped again: the ops' child is detached, not destroyed (the page's
    // runtime still names it); then the row goes, its leaves with it.
    try std.testing.expect(try t.stampRow(5, &first));
    try std.testing.expect(t.get(20).?.parent == null);
    try t.apply("[[\"d\",5]]");
    try std.testing.expect(t.get(10) == null and t.get(11) == null);
}

test "the x op sets transform and opacity alone and moves the frame" {
    if (!@import("build_options").native_ui) return error.SkipZigTest;
    var ctx: u8 = 0;
    var t = Tree.init(std.testing.allocator, &ctx, testMeasure);
    defer t.deinit();
    const Hook = struct {
        var calls: usize = 0;
        fn paint(_: *anyopaque, _: *Node) void {
            calls += 1;
        }
    };
    t.on_paint = Hook.paint;
    try t.apply("[[\"c\",0,\"view\"],[\"c\",1,\"view\"],[\"p\",1,{\"w\":10,\"h\":10,\"bg\":{\"color\":[1,2,3,1]}}],[\"k\",0,[1]],[\"r\",0]]");
    t.layout();
    const n = t.get(1).?;
    try std.testing.expectEqual(@as(f32, 0), n.frame.x);
    try t.apply("[[\"x\",1,5,6,2,null,0.5]]");
    try std.testing.expect(t.dirty and Hook.calls == 1);
    try std.testing.expectEqual(@as(?f32, 2), n.props.sc);
    try std.testing.expectEqual(@as(?f32, null), n.props.rot);
    try std.testing.expect(n.props.bg != null); // the rest as it was
    t.layout();
    try std.testing.expectEqual(@as(f32, 5), n.frame.x);
    try std.testing.expectEqual(@as(f32, 6), n.frame.y);
    try t.apply("[[\"x\",1,null,null,null,null,null],[\"x\",99,1,1,1,1,1]]");
    try std.testing.expectEqual(@as(?f32, null), n.props.tx);
}

test "decodeCanvas makes the commands parseCanvasCmds makes from JSON" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\[["sv"],["sf",[255,0,0,0.5]],["ss",["g",3]],["lw",2],["lc","round"],["lj","bevel"],["ta","end"],["tb","middle"],
        \\ ["fo",1,700,12,"serif"],["bp"],["ar",10,20,5,0,6.28,1],["fl",0],["tx","hi",1,2],["sx","yo",3,4],
        \\ ["gl",3,0,0,10,0],["gs",3,0.5,1,2,3,1],["gr",4,1,2,3,4,5,6],["tl",1,2],["ts",2,2],["tr",0.5],
        \\ ["mv",1,1],["ln",2,2],["rc",0,0,4,4],["bz",1,2,3,4,5,6],["cp"],["cl",1],["st"],["fr",0,0,1,1],
        \\ ["sr",0,0,2,2],["cr",0,0,3,3],["ga",0.25],["rs"]]
    , .{});
    const strs = [_][]const u8{ "serif", "hi", "yo" };
    const nums = [_]f64{
        1, 21, 0, 255, 0, 0, 0.5, 22, 1, 3, 0, 0, 0, 23, 2, 25, 1, 26, 2, 27, 2, 28, 3,
        29, 1, 700, 12, 0, 3, 14, 10, 20, 5, 0, 6.28, 1, 6, 0, 19, 1, 1, 2, 20, 2, 3, 4,
        30, 3, 0, 0, 10, 0, 32, 3, 0.5, 1, 2, 3, 1, 31, 4, 1, 2, 3, 4, 5, 6, 8, 1, 2, 9, 2, 2, 10, 0.5,
        11, 1, 1, 12, 2, 2, 13, 0, 0, 4, 4, 15, 1, 2, 3, 4, 5, 6, 4, 7, 1, 5, 16, 0, 0, 1, 1,
        17, 0, 0, 2, 2, 18, 0, 0, 3, 3, 24, 0.25, 2,
    };
    const want = try parseCanvasCmds(a, json);
    const got = try decodeCanvas(a, &nums, &strs);
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| {
        try std.testing.expectEqual(std.meta.activeTag(w), std.meta.activeTag(g));
        switch (w) {
            .fill_text => |x| try std.testing.expectEqualStrings(x.t, g.fill_text.t),
            .stroke_text => |x| try std.testing.expectEqualStrings(x.t, g.stroke_text.t),
            .font => |x| {
                try std.testing.expectEqualStrings(x.family, g.font.family);
                try std.testing.expectEqual(x.size, g.font.size);
            },
            else => try std.testing.expect(std.meta.eql(w, g)),
        }
    }
    // A non-finite argument skips that op; a malformed tail ends the program.
    const bad = [_]f64{ 8, std.math.inf(f64), 1, 99, 1 };
    try std.testing.expectEqual(@as(usize, 0), (try decodeCanvas(a, &bad, &.{})).len);
}
