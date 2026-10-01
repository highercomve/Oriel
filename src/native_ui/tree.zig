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

pub const Kind = enum { view, text, input, textarea, select, icon };

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
    /// After layout: the frame in window coordinates, the visible part.
    frame: Rect = .{},
    clip: Rect = .{},
    /// Scroll containers: the content's height and the offset.
    content_h: f32 = 0,
    scroll_y: f32 = 0,
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
        for (ops.array.items) |op| {
            const a = op.array.items;
            const kind = a[0].string;
            const id = num(a[1]);
            switch (kind[0]) {
                'c' => try t.create(id, std.meta.stringToEnum(Kind, a[2].string) orelse .view),
                'p' => if (t.nodes.get(id)) |n| try t.setProps(n, a[2]),
                'k' => if (t.nodes.get(id)) |n| try t.setKids(n, a[2].array.items),
                'd' => t.destroy(id),
                'r' => t.root = t.nodes.get(id),
                else => {},
            }
        }
        t.dirty = true;
    }

    fn num(v: std.json.Value) i64 {
        return switch (v) {
            .integer => |i| i,
            .float => |x| @intFromFloat(x),
            else => 0,
        };
    }

    fn create(t: *Tree, id: i64, kind: Kind) !void {
        if (t.nodes.get(id) != null) t.destroy(id);
        const n = try t.gpa.create(Node);
        n.* = .{ .id = id, .kind = kind, .yn = yg.YGNodeNewWithConfig(t.config), .arena = .init(t.gpa), .tree = t };
        yg.YGNodeSetContext(n.yn, n);
        if (kind == .text or kind == .input or kind == .textarea or kind == .select) {
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
        _ = n.arena.reset(.retain_capacity);
        const a = n.arena.allocator();
        // Copy the JSON value into the node's arena (the ops arena goes away).
        const copy = try cloneValue(a, value);
        n.props = std.json.parseFromValueLeaky(Props, a, copy, .{ .ignore_unknown_fields = true }) catch |err| blk: {
            log.warn("node {d}: bad props ({s})", .{ n.id, @errorName(err) });
            break :blk .{};
        };
        if (n.props.val) |v| n.pending_value = v;
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
            const k = t.nodes.get(num(v)) orelse continue;
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
        place(root, 0, 0, window);
        t.dirty = false;
    }

    fn place(n: *Node, ox: f32, oy: f32, clip: Rect) void {
        const p = n.props;
        n.frame = .{
            .x = ox + yg.YGNodeLayoutGetLeft(n.yn) + (p.tx orelse 0),
            .y = oy + yg.YGNodeLayoutGetTop(n.yn) + (p.ty orelse 0),
            .w = yg.YGNodeLayoutGetWidth(n.yn),
            .h = yg.YGNodeLayoutGetHeight(n.yn),
        };
        n.clip = clip;
        var child_clip = clip;
        if (p.scroll or p.clip) child_clip = clip.intersect(n.frame);
        if (p.scroll) {
            var bottom: f32 = 0;
            for (n.kids.items) |k| bottom = @max(bottom, yg.YGNodeLayoutGetTop(k.yn) + yg.YGNodeLayoutGetHeight(k.yn) + yg.YGNodeLayoutGetMargin(k.yn, yg.YGEdgeBottom));
            n.content_h = bottom + yg.YGNodeLayoutGetPadding(n.yn, yg.YGEdgeBottom);
            n.scroll_y = std.math.clamp(n.scroll_y, 0, @max(0, n.content_h - n.frame.h));
        }
        const sy = if (p.scroll) n.scroll_y else 0;
        for (n.kids.items) |k| place(k, n.frame.x, n.frame.y - sy, child_clip);
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
        place(root, 0, 0, .{ .w = t.width, .h = t.height });
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
    yg.YGNodeStyleSetOverflow(y, if (p.scroll) yg.YGOverflowScroll else if (p.clip) yg.YGOverflowHidden else yg.YGOverflowVisible);
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
