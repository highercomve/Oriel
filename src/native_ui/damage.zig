//! What changed on screen from one frame to the next, for a backend that
//! keeps the last frame's pixels and paints only over what changed
//! (gtk.zig's tiles). Each frame, `collect` walks the tree in paint order
//! and gives every painted node a fingerprint of everything its pixels
//! depend on: its props and canvas program, its frame and clip, its place
//! in the paint order, the opacity, transform and rounded clip its
//! ancestors paint it under, and what the backend adds (`Hooks.extra`). A
//! node whose fingerprint changed, or that appeared or went, damages where
//! its pixels were and where they are now.
//!
//! Nothing in the tree has to say what it changed: a fingerprint that
//! misses nothing the painting reads is all it takes, and one that changes
//! for nothing only paints more.

const std = @import("std");
const tree_mod = @import("tree.zig");
const Node = tree_mod.Node;
const Rect = tree_mod.Rect;

pub const Hooks = struct {
    ctx: *anyopaque,
    /// Where a node's own painting (not its children's) stays, in window
    /// coordinates, before its clip: its frame and what paints past it (a
    /// shadow, an outline, text overflowing its box).
    bounds: *const fn (ctx: *anyopaque, n: *Node) Rect,
    /// What a node's pixels depend on beyond the tree (a field's
    /// placeholder shows while it's empty), mixed into its fingerprint.
    extra: ?*const fn (ctx: *anyopaque, n: *Node) u64 = null,
};

/// Past these, everything is taken as changed: a tree deeper than any page
/// (the walk recurses), or more changed areas than are worth telling apart.
const max_depth = 512;
const max_rects = 256;

const Entry = struct {
    hash: u64,
    /// Where its own pixels are (empty: none in view).
    rect: Rect,
    /// Where its and its descendants' pixels are.
    subtree: Rect,
};

pub const Damage = struct {
    entries: std.AutoHashMapUnmanaged(i64, Entry) = .empty,
    next: std.AutoHashMapUnmanaged(i64, Entry) = .empty,
    /// The last collect's changes, when not `all`.
    rects: std.ArrayList(Rect) = .empty,
    /// Everything changed (the first frame, a new size, no memory to tell).
    all: bool = true,

    pub fn deinit(d: *Damage, gpa: std.mem.Allocator) void {
        d.entries.deinit(gpa);
        d.next.deinit(gpa);
        d.rects.deinit(gpa);
    }

    /// The next collect reports everything changed.
    pub fn invalidate(d: *Damage) void {
        d.all = true;
    }

    /// Fingerprint the tree as it is now and set `rects` (or `all`) to what
    /// changed since the last collect.
    pub fn collect(d: *Damage, gpa: std.mem.Allocator, root: ?*Node, hooks: Hooks) void {
        d.rects.clearRetainingCapacity();
        d.next.clearRetainingCapacity();
        const walked = if (root) |r| d.walk(gpa, r, .{ .hooks = hooks }) else true;
        if (!walked) {
            // Out of memory: no fingerprints to compare with next time.
            d.entries.clearRetainingCapacity();
            d.all = true;
            return;
        }
        if (!d.all) d.diff(gpa) catch {
            d.all = true;
        };
        std.mem.swap(std.AutoHashMapUnmanaged(i64, Entry), &d.entries, &d.next);
    }

    /// Whether `r` needs painting again (the last collect's changes reach it).
    pub fn reaches(d: *const Damage, r: Rect) bool {
        if (d.all) return true;
        for (d.rects.items) |c| if (overlaps(c, r)) return true;
        return false;
    }

    /// Where node `id`'s and its descendants' pixels are (from the last
    /// collect): a tile `r` doesn't reach paints none of them. Null: not
    /// painted at the last collect.
    pub fn subtree(d: *const Damage, id: i64) ?Rect {
        return if (d.entries.get(id)) |e| e.subtree else null;
    }

    /// The painting was drawn: the next collect compares with this one.
    pub fn painted(d: *Damage) void {
        d.all = false;
    }

    const Context = struct {
        hooks: Hooks,
        /// The opacity, transforms and rounded clips of the ancestors.
        seed: u64 = 0,
        /// Under a scaled or rotated ancestor: that ancestor's clip, which
        /// everything under it is painted inside of (its descendants'
        /// frames and clips are in its transformed space).
        transformed: ?Rect = null,
        parent: i64 = 0,
        order: usize = 0,
        depth: u32 = 0,
    };

    /// False: out of memory, too deep, or a box nowhere (not finite).
    fn walk(d: *Damage, gpa: std.mem.Allocator, n: *Node, c: Context) bool {
        if (c.depth >= max_depth) return false;
        const p = n.props;
        // Not painted, nor its children (gtk.zig paint).
        if (p.vis == false) return true;
        var h = std.hash.Wyhash.init(c.seed);
        hashDeep(&h, n.kind);
        hashDeep(&h, p);
        hashDeep(&h, n.canvas);
        hashDeep(&h, n.frame);
        hashDeep(&h, n.clip);
        hashDeep(&h, c.parent);
        hashDeep(&h, c.order);
        if (c.hooks.extra) |extra| hashDeep(&h, extra(c.hooks.ctx, n));
        const transforms = (p.sc orelse 1) != 1 or (p.rot orelse 0) != 0;
        // Everything a box paints is inside its clip (paint clips to it
        // first); its own painting is inside its bounds too, unless it is
        // transformed (its bounds are in the space before).
        const own = c.transformed orelse if (transforms) n.clip else n.clip.intersect(c.hooks.bounds(c.hooks.ctx, n));
        // A NaN would overlap nothing: its change would never be painted.
        const rect = if (finite(own)) own else if (finite(n.clip)) n.clip else return false;
        hashDeep(&h, rect);

        // What its children are painted under.
        var seed = std.hash.Wyhash.init(c.seed);
        hashDeep(&seed, p.op);
        if (transforms) {
            hashDeep(&seed, p.sc);
            hashDeep(&seed, p.rot);
            hashDeep(&seed, n.frame);
        }
        if (n.roundClips()) hashDeep(&seed, n.paddingClipXY());
        var kids: Context = .{
            .hooks = c.hooks,
            .seed = seed.final(),
            .transformed = c.transformed orelse if (transforms) n.clip else null,
            .parent = n.id,
            .depth = c.depth + 1,
        };
        var all = rect;
        var it: tree_mod.PaintIter = .{ .kids = n.kids.items };
        while (it.next()) |k| : (kids.order += 1) {
            if (!d.walk(gpa, k, kids)) return false;
            if (d.next.get(k.id)) |e| all = join(all, e.subtree);
        }
        d.next.put(gpa, n.id, .{ .hash = h.final(), .rect = rect, .subtree = all }) catch return false;
        return true;
    }

    fn diff(d: *Damage, gpa: std.mem.Allocator) !void {
        var now = d.next.iterator();
        while (now.next()) |e| {
            const new = e.value_ptr.*;
            if (d.entries.get(e.key_ptr.*)) |old| {
                if (old.hash == new.hash) continue;
                try d.add(gpa, old.rect);
            }
            try d.add(gpa, new.rect);
        }
        var before = d.entries.iterator();
        while (before.next()) |e| if (!d.next.contains(e.key_ptr.*)) try d.add(gpa, e.value_ptr.rect);
    }

    fn add(d: *Damage, gpa: std.mem.Allocator, r: Rect) !void {
        if (r.w <= 0 or r.h <= 0) return;
        // Within one already there (a row's texts in the row's change).
        for (d.rects.items) |c| if (inside(r, c)) return;
        if (d.rects.items.len >= max_rects) return error.TooManyChanges;
        try d.rects.append(gpa, r);
    }
};

fn finite(r: Rect) bool {
    return std.math.isFinite(r.x) and std.math.isFinite(r.y) and std.math.isFinite(r.w) and std.math.isFinite(r.h);
}

pub fn overlaps(a: Rect, b: Rect) bool {
    return a.w > 0 and a.h > 0 and b.w > 0 and b.h > 0 and
        a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h;
}

/// Whether `a` is within `b`.
pub fn inside(a: Rect, b: Rect) bool {
    return a.x >= b.x and a.y >= b.y and a.x + a.w <= b.x + b.w and a.y + a.h <= b.y + b.h;
}

/// The smallest rectangle around both (an empty one adds nothing).
pub fn join(a: Rect, b: Rect) Rect {
    if (a.w <= 0 or a.h <= 0) return b;
    if (b.w <= 0 or b.h <= 0) return a;
    const x0 = @min(a.x, b.x);
    const y0 = @min(a.y, b.y);
    return .{ .x = x0, .y = y0, .w = @max(a.x + a.w, b.x + b.w) - x0, .h = @max(a.y + a.h, b.y + b.h) - y0 };
}

/// `r` grown by `d` on every side.
pub fn grown(r: Rect, d: f32) Rect {
    return .{ .x = r.x - d, .y = r.y - d, .w = r.w + 2 * d, .h = r.h + 2 * d };
}

/// Hash a value and everything it points to: strings and slices by their
/// contents (a text replaced in place, at the same address, still counts),
/// floats by their bits.
fn hashDeep(h: *std.hash.Wyhash, v: anytype) void {
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .void, .null => {},
        .bool, .int, .float, .@"enum" => h.update(std.mem.asBytes(&v)),
        .optional => if (v) |x| {
            h.update(&.{1});
            hashDeep(h, x);
        } else h.update(&.{0}),
        .array => |a| switch (@typeInfo(a.child)) {
            // No padding between them: the bytes at once.
            .int, .float => h.update(std.mem.asBytes(&v)),
            else => for (v) |x| hashDeep(h, x),
        },
        .pointer => |ptr| switch (ptr.size) {
            .slice => {
                h.update(std.mem.asBytes(&v.len));
                if (ptr.child == u8) h.update(v) else for (v) |x| hashDeep(h, x);
            },
            .one => hashDeep(h, v.*),
            else => @compileError("hashDeep: " ++ @typeName(T)),
        },
        .@"struct" => |st| inline for (st.fields) |f| hashDeep(h, @field(v, f.name)),
        .@"union" => |u| {
            if (u.tag_type == null) @compileError("hashDeep: " ++ @typeName(T));
            hashDeep(h, std.meta.activeTag(v));
            switch (v) {
                inline else => |x| hashDeep(h, x),
            }
        },
        else => @compileError("hashDeep: " ++ @typeName(T)),
    }
}

// ---------------------------------------------------------------------------
// Tests

const Tree = tree_mod.Tree;

fn testMeasure(_: *anyopaque, _: *Node, _: f32, out: *[2]f32) void {
    out.* = .{ 40, 10 };
}

fn frameBounds(_: *anyopaque, n: *Node) Rect {
    return grown(n.frame, 1);
}

fn collectNow(d: *Damage, t: *Tree) void {
    if (t.needsLayout()) t.layout();
    var ctx: u8 = 0;
    d.collect(std.testing.allocator, t.root, .{ .ctx = &ctx, .bounds = frameBounds });
}

fn testTree(t: *Tree) !void {
    try t.apply(
        \\[["c",1,"view"],["p",1,{"w":400,"h":300,"fd":"row","cg":20}],
        \\ ["c",2,"view"],["p",2,{"w":100,"h":50,"bg":{"color":[255,0,0,1]}}],
        \\ ["c",3,"view"],["p",3,{"w":100,"h":50,"bg":{"color":[0,0,255,1]}}],
        \\ ["k",1,[2,3]],["r",1]]
    );
}

test "the first frame is all damage; an unchanged one none" {
    var ctx: u8 = 0;
    var t = Tree.init(std.testing.allocator, &ctx, testMeasure);
    defer t.deinit();
    try testTree(&t);
    var d: Damage = .{};
    defer d.deinit(std.testing.allocator);
    collectNow(&d, &t);
    try std.testing.expect(d.all);
    d.painted();
    collectNow(&d, &t);
    try std.testing.expect(!d.all);
    try std.testing.expectEqual(@as(usize, 0), d.rects.items.len);
    try std.testing.expect(!d.reaches(.{ .x = 0, .y = 0, .w = 400, .h = 300 }));
}

test "a changed color damages its box only" {
    var ctx: u8 = 0;
    var t = Tree.init(std.testing.allocator, &ctx, testMeasure);
    defer t.deinit();
    try testTree(&t);
    var d: Damage = .{};
    defer d.deinit(std.testing.allocator);
    collectNow(&d, &t);
    d.painted();
    try t.apply(
        \\[["p",3,{"w":100,"h":50,"bg":{"color":[0,255,0,1]}}]]
    );
    collectNow(&d, &t);
    try std.testing.expectEqual(@as(usize, 1), d.rects.items.len);
    const box = t.get(3).?.frame;
    try std.testing.expect(d.reaches(box));
    try std.testing.expect(!d.reaches(t.get(2).?.frame));
}

test "a moved box damages where it was and where it is" {
    var ctx: u8 = 0;
    var t = Tree.init(std.testing.allocator, &ctx, testMeasure);
    defer t.deinit();
    try testTree(&t);
    var d: Damage = .{};
    defer d.deinit(std.testing.allocator);
    collectNow(&d, &t);
    d.painted();
    const before = t.get(3).?.frame;
    // Box 2 wider: box 3 moves right.
    try t.apply(
        \\[["p",2,{"w":150,"h":50,"bg":{"color":[255,0,0,1]}}]]
    );
    collectNow(&d, &t);
    try std.testing.expect(d.reaches(before));
    try std.testing.expect(d.reaches(t.get(3).?.frame));
    try std.testing.expect(!d.reaches(.{ .x = 0, .y = 100, .w = 400, .h = 200 }));
}

test "a hidden or removed box damages where it was" {
    var ctx: u8 = 0;
    var t = Tree.init(std.testing.allocator, &ctx, testMeasure);
    defer t.deinit();
    try testTree(&t);
    var d: Damage = .{};
    defer d.deinit(std.testing.allocator);
    collectNow(&d, &t);
    d.painted();
    const box = t.get(3).?.frame;
    t.destroy(3);
    collectNow(&d, &t);
    try std.testing.expect(d.reaches(box));
}

test "an ancestor's opacity damages its children past its box" {
    var ctx: u8 = 0;
    var t = Tree.init(std.testing.allocator, &ctx, testMeasure);
    defer t.deinit();
    try testTree(&t);
    var d: Damage = .{};
    defer d.deinit(std.testing.allocator);
    collectNow(&d, &t);
    d.painted();
    // Box 3's own props are the same; its parent's opacity isn't.
    t.applyPaint(&.{ 1, 1, 5, std.math.nan(f64), std.math.nan(f64), std.math.nan(f64), std.math.nan(f64), 0.5 });
    collectNow(&d, &t);
    try std.testing.expect(d.reaches(t.get(3).?.frame));
}

test "subtree: where a box's and its children's pixels are" {
    var ctx: u8 = 0;
    var t = Tree.init(std.testing.allocator, &ctx, testMeasure);
    defer t.deinit();
    try testTree(&t);
    var d: Damage = .{};
    defer d.deinit(std.testing.allocator);
    collectNow(&d, &t);
    const all = d.subtree(1).?;
    try std.testing.expect(inside(t.get(2).?.frame, all) and inside(t.get(3).?.frame, all));
    try std.testing.expectEqual(@as(?Rect, null), d.subtree(99));
}

test "more changes than worth telling apart: everything changed" {
    var ctx: u8 = 0;
    var t = Tree.init(std.testing.allocator, &ctx, testMeasure);
    defer t.deinit();
    try testTree(&t);
    var d: Damage = .{};
    defer d.deinit(std.testing.allocator);
    collectNow(&d, &t);
    d.painted();
    for (0..max_rects + 1) |i| {
        const x: f32 = @floatFromInt(i * 3);
        d.add(std.testing.allocator, .{ .x = x, .y = 0, .w = 1, .h = 1 }) catch |err| {
            try std.testing.expectEqual(error.TooManyChanges, err);
            try std.testing.expectEqual(max_rects, i);
            return;
        };
    }
    return error.TestExpectedError;
}

fn nanBounds(_: *anyopaque, _: *Node) Rect {
    return .{ .x = std.math.nan(f32), .y = 0, .w = 1, .h = 1 };
}

test "a box with bounds nowhere damages its clip, not nothing" {
    var ctx: u8 = 0;
    var t = Tree.init(std.testing.allocator, &ctx, testMeasure);
    defer t.deinit();
    try testTree(&t);
    if (t.needsLayout()) t.layout();
    var d: Damage = .{};
    defer d.deinit(std.testing.allocator);
    d.collect(std.testing.allocator, t.root, .{ .ctx = &ctx, .bounds = nanBounds });
    d.painted();
    try t.apply(
        \\[["p",3,{"w":100,"h":50,"bg":{"color":[0,255,0,1]}}]]
    );
    if (t.needsLayout()) t.layout();
    d.collect(std.testing.allocator, t.root, .{ .ctx = &ctx, .bounds = nanBounds });
    try std.testing.expect(d.reaches(t.get(3).?.frame));
}

test "hashDeep: slices by content, floats by bits" {
    var a = std.hash.Wyhash.init(0);
    var b = std.hash.Wyhash.init(0);
    var buf = "abc".*;
    hashDeep(&a, @as([]const u8, &buf));
    buf[1] = 'x';
    hashDeep(&b, @as([]const u8, &buf));
    try std.testing.expect(a.final() != b.final());
    var c = std.hash.Wyhash.init(0);
    var e = std.hash.Wyhash.init(0);
    hashDeep(&c, @as(?f32, 1.5));
    hashDeep(&e, @as(?f32, 1.5));
    try std.testing.expectEqual(c.final(), e.final());
}
