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

/// A paint: [r,g,b,a] (or [r,g,b]) — or ["g", id] for a gradient.
fn paintAt(v: std.json.Value) ?CanvasPaint {
    if (v != .array) return null;
    const a = v.array.items;
    if (a.len == 2 and a[0] == .string and std.mem.eql(u8, a[0].string, "g")) {
        const id = switch (a[1]) {
            .integer => |x| x,
            .float => |x| @as(i64, @intFromFloat(x)),
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
        .float => |f| @as(i64, @intFromFloat(f)),
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
    options: ?[]const [2][]const u8 = null,
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
    /// For a canvas node: its drawing program, from props `cv`.
    canvas: ?[]const CanvasCmd = null,
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
    gpa: std.mem.Allocator,
    nodes: std.AutoHashMap(i64, *Node),
    root: ?*Node = null,
    config: yg.YGConfigRef,
    measure_ctx: *anyopaque,
    measure: Measure,
    /// Something changed since the last layout.
    dirty: bool = true,
    width: f32 = 800,
    height: f32 = 600,
    /// Called before a node goes (its widget is destroyed).
    on_remove: ?*const fn (ctx: *anyopaque, node: *Node) void = null,
    /// Called after a node's props changed, with the props as sent (backends
    /// that keep their own copy: Android).
    on_props: ?*const fn (ctx: *anyopaque, node: *Node, props: std.json.Value) void = null,

    pub fn init(gpa: std.mem.Allocator, measure_ctx: *anyopaque, measure: Measure) Tree {
        const config = yg.YGConfigNew();
        yg.YGConfigSetUseWebDefaults(config, true);
        yg.YGConfigSetPointScaleFactor(config, 1);
        return .{ .gpa = gpa, .nodes = .init(gpa), .config = config, .measure_ctx = measure_ctx, .measure = measure };
    }

    pub fn deinit(t: *Tree) void {
        var it = t.nodes.valueIterator();
        while (it.next()) |n| freeNode(t, n.*);
        t.nodes.deinit();
        yg.YGConfigFree(t.config);
    }

    fn freeNode(t: *Tree, n: *Node) void {
        if (t.on_remove) |cb| cb(t.measure_ctx, n);
        yg.YGNodeFree(n.yn);
        n.kids.deinit(t.gpa);
        n.arena.deinit();
        t.gpa.destroy(n);
    }

    pub fn get(t: *Tree, id: i64) ?*Node {
        return t.nodes.get(id);
    }

    // -----------------------------------------------------------------
    // Operations

    pub fn apply(t: *Tree, json: []const u8) !void {
        var arena: std.heap.ArenaAllocator = .init(t.gpa);
        defer arena.deinit();
        const ops = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{});
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
                'p' => if (arg) |x| if (t.nodes.get(id)) |n| try t.setProps(n, x),
                'k' => if (arg) |x| if (x == .array) if (t.nodes.get(id)) |n| try t.setKids(n, x.array.items),
                'd' => t.destroy(id),
                'r' => t.root = t.nodes.get(id),
                else => {},
            }
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
        yg.YGNodeSetContext(n.yn, n);
        if (kind == .text or kind == .input or kind == .textarea or kind == .select or kind == .image) {
            yg.YGNodeSetMeasureFunc(n.yn, measureFn);
        }
        try t.nodes.put(id, n);
    }

    fn destroy(t: *Tree, id: i64) void {
        const n = t.nodes.get(id) orelse return;
        _ = t.nodes.remove(id);
        if (n.parent) |p| {
            for (p.kids.items, 0..) |k, i| if (k == n) {
                _ = p.kids.orderedRemove(i);
                break;
            };
            yg.YGNodeRemoveChild(p.yn, n.yn);
        }
        for (n.kids.items) |k| {
            yg.YGNodeRemoveChild(n.yn, k.yn);
            k.parent = null;
        }
        if (t.root == n) t.root = null;
        freeNode(t, n);
    }

    fn setProps(t: *Tree, n: *Node, value: std.json.Value) !void {
        // A value the backend hasn't taken yet lives in the arena reset
        // below: keep a copy, or it would point into reused memory when the
        // new props carry no `val` (fields send it only when it changed).
        const unconsumed: ?[]u8 = if (n.pending_value) |v| try t.gpa.dupe(u8, v) else null;
        defer if (unconsumed) |u| t.gpa.free(u);
        n.pending_value = null;
        // Keep a little for the next props, not an old <img> data: URI's megabytes.
        _ = n.arena.reset(.{ .retain_with_limit = 64 * 1024 });
        // The old props' slices are gone with the reset: if copying the new
        // ones fails, the node must not keep pointing into the arena.
        n.props = .{};
        const a = n.arena.allocator();
        // Copy the JSON value into the node's arena (the ops arena goes away).
        const copy = try cloneValue(a, value);
        n.props = std.json.parseFromValueLeaky(Props, a, copy, .{ .ignore_unknown_fields = true }) catch |err| blk: {
            log.warn("node {d}: bad props ({s})", .{ n.id, @errorName(err) });
            break :blk .{};
        };
        if (n.props.val) |v| {
            n.pending_value = v;
        } else if (unconsumed) |u| {
            n.pending_value = try a.dupe(u8, u);
        }
        // A canvas's drawing program (its arena holds the strings).
        n.canvas = null;
        if (copy == .object) if (copy.object.get("cv")) |cv| {
            if (parseCanvasCmds(a, cv)) |cmds| {
                n.canvas = cmds;
            } else |err| log.warn("node {d}: bad canvas ops ({s})", .{ n.id, @errorName(err) });
        };
        styleYoga(n);
        if (t.on_props) |cb| cb(t.measure_ctx, n, copy);
        if (yg.YGNodeHasMeasureFunc(n.yn)) yg.YGNodeMarkDirty(n.yn);
    }

    fn setKids(t: *Tree, n: *Node, ids: []const std.json.Value) !void {
        for (n.kids.items) |k| {
            yg.YGNodeRemoveChild(n.yn, k.yn);
            k.parent = null;
        }
        n.kids.clearRetainingCapacity();
        for (ids) |v| {
            const k = t.nodes.get(num(v) orelse continue) orelse continue;
            if (k.parent) |old| {
                for (old.kids.items, 0..) |x, i| if (x == k) {
                    _ = old.kids.orderedRemove(i);
                    break;
                };
                yg.YGNodeRemoveChild(old.yn, k.yn);
            }
            if (yg.YGNodeHasMeasureFunc(n.yn)) continue; // a measured leaf can't have children
            yg.YGNodeInsertChild(n.yn, k.yn, yg.YGNodeGetChildCount(n.yn));
            k.parent = n;
            try n.kids.append(t.gpa, k);
        }
    }

    // -----------------------------------------------------------------
    // Layout

    pub fn layout(t: *Tree) void {
        const root = t.root orelse return;
        yg.YGNodeStyleSetWidth(root.yn, t.width);
        yg.YGNodeStyleSetHeight(root.yn, t.height);
        yg.YGNodeCalculateLayout(root.yn, t.width, t.height, yg.YGDirectionLTR);
        const window: Rect = .{ .w = t.width, .h = t.height };
        place(root, 0, 0, window, window);
        t.dirty = false;
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
        var i = n.kids.items.len;
        while (i > 0) {
            i -= 1;
            if (hitIn(n.kids.items[i], x, y)) |h| return h;
        }
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
    n.tree.measure(n.tree.measure_ctx, n, max_w, &out);
    if (width_mode == yg.YGMeasureModeExactly) out[0] = width;
    if (width_mode == yg.YGMeasureModeAtMost) out[0] = @min(out[0], width);
    return .{ .width = out[0], .height = out[1] };
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
    const y = n.yn;
    const p = n.props;
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
