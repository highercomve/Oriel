//! Bounded, content-keyed measurements survive node replacement. Keys own
//! every byte and compare in full: hash collisions cannot alias text sizes.
const std = @import("std");
const tree = @import("tree.zig");

pub const Cache = struct {
    entries: std.StringHashMapUnmanaged([2]f32) = .empty,
    bytes: usize = 0,
    capacity_resets: usize = 0,
    max_entries: usize = 16_384,
    max_bytes: usize = 4 * 1024 * 1024,

    pub fn clear(c: *Cache, gpa: std.mem.Allocator) void {
        var it = c.entries.keyIterator();
        while (it.next()) |key| gpa.free(key.*);
        c.entries.clearRetainingCapacity();
        c.bytes = 0;
    }

    pub fn deinit(c: *Cache, gpa: std.mem.Allocator) void {
        c.clear(gpa);
        c.entries.deinit(gpa);
    }

    pub fn get(c: *const Cache, key: []const u8) ?[2]f32 {
        return c.entries.get(key);
    }

    pub fn put(c: *Cache, gpa: std.mem.Allocator, key: []const u8, size: [2]f32) !void {
        if (key.len > c.max_bytes or c.max_entries == 0) return;
        if (c.entries.contains(key)) return;
        if (c.entries.count() >= c.max_entries or c.bytes + key.len > c.max_bytes) {
            c.clear(gpa);
            c.capacity_resets += 1;
        }
        const owned = try gpa.dupe(u8, key);
        errdefer gpa.free(owned);
        try c.entries.put(gpa, owned, size);
        c.bytes += owned.len;
    }
};

// Limit key work for long paragraphs: these keep the ordinary per-node
// natural-size cache. Include all text-layout inputs, including paint attrs,
// to avoid assumptions about which attributes affect Pango's extents.
pub fn keyFor(buf: *[1024]u8, props: *const tree.Props, width: f32) ?[]const u8 {
    const runs = props.runs orelse return null;
    if (runs.len > 4) return null;
    var text_len: usize = 0;
    for (runs) |r| text_len += r.t.len;
    if (text_len > 480) return null;
    var k = Key{ .buf = buf };
    k.float(width);
    k.float(props.fz orelse 16);
    k.byte(@intFromBool(props.mono));
    k.optional(props.lh);
    k.optional(props.ls);
    // The font family lists (a font of its own: other glyphs, other
    // metrics); longer ones aren't keyed.
    if (!k.family(props.ff)) return null;
    const ta = props.ta orelse "left";
    k.byte(if (std.mem.eql(u8, ta, "center")) 1 else if (std.mem.eql(u8, ta, "right")) 2 else 0);
    k.byte(@intCast(runs.len));
    for (runs) |r| {
        k.integer(@intCast(r.t.len));
        @memcpy(buf[k.len..][0..r.t.len], r.t);
        k.len += r.t.len;
        k.float(r.sz);
        k.float(r.w);
        k.optional(r.lh);
        k.byte(@intFromBool(r.i));
        k.byte(@intFromBool(r.mono));
        k.byte(@intFromBool(r.u));
        for (r.c) |channel| k.float(channel);
        k.byte(@intFromBool(r.bg != null));
        if (r.bg) |bg| for (bg) |channel| k.float(channel);
        // An inline box's room in the line (its box, as runs group).
        k.byte(@intFromBool(r.ib != null));
        if (r.ib) |ib| {
            k.integer(ib.k);
            k.float(ib.start());
            k.float(ib.end());
        }
        if (!k.family(r.ff)) return null;
    }
    return buf[0..k.len];
}

const Key = struct {
    buf: *[1024]u8,
    len: usize = 0,
    fn byte(k: *Key, value: u8) void {
        k.buf[k.len] = value;
        k.len += 1;
    }
    fn integer(k: *Key, value: u32) void {
        std.mem.writeInt(u32, k.buf[k.len..][0..4], value, .little);
        k.len += 4;
    }
    fn float(k: *Key, value: f32) void {
        k.integer(@bitCast(value));
    }
    fn family(k: *Key, value: ?[]const u8) bool {
        const f = value orelse {
            k.byte(0);
            return true;
        };
        if (f.len > 48) return false;
        k.byte(@intCast(f.len + 1));
        @memcpy(k.buf[k.len..][0..f.len], f);
        k.len += f.len;
        return true;
    }
    fn optional(k: *Key, value: ?f32) void {
        k.byte(@intFromBool(value != null));
        if (value) |v| k.float(v);
    }
};

test "measurement keys distinguish text, width, fonts, run boundaries and spacing" {
    var a: [1024]u8 = undefined;
    var b: [1024]u8 = undefined;
    var runs = [_]tree.Run{.{ .t = "same Ω\x00text" }};
    var props = tree.Props{ .runs = &runs };
    const original = keyFor(&a, &props, 200).?;
    try std.testing.expectEqualSlices(u8, original, keyFor(&b, &props, 200).?);
    try std.testing.expect(!std.mem.eql(u8, original, keyFor(&b, &props, 100).?));
    runs[0].w = 700;
    try std.testing.expect(!std.mem.eql(u8, original, keyFor(&b, &props, 200).?));
    runs[0].w = 400;
    props.ls = 2;
    try std.testing.expect(!std.mem.eql(u8, original, keyFor(&b, &props, 200).?));
    props.ls = null;
    props.lh = 24;
    try std.testing.expect(!std.mem.eql(u8, original, keyFor(&b, &props, 200).?));
    props.lh = null;
    runs[0].t = "different";
    try std.testing.expect(!std.mem.eql(u8, original, keyFor(&b, &props, 200).?));
    var split = [_]tree.Run{ .{ .t = "same " }, .{ .t = "Ω\x00text" } };
    props.runs = &split;
    try std.testing.expect(!std.mem.eql(u8, original, keyFor(&b, &props, 200).?));
}

test "measurement cache owns keys and remains bounded" {
    var c = Cache{ .max_entries = 2, .max_bytes = 10 };
    defer c.deinit(std.testing.allocator);
    var key = [_]u8{ 'a', 'b' };
    try c.put(std.testing.allocator, &key, .{ 10, 20 });
    key[0] = 'x';
    try std.testing.expectEqual(@as(f32, 10), c.get("ab").?[0]);
    try c.put(std.testing.allocator, "cd", .{ 30, 40 });
    try c.put(std.testing.allocator, "ef", .{ 50, 60 });
    try std.testing.expect(c.get("ab") == null);
    try std.testing.expectEqual(@as(usize, 1), c.entries.count());
    try c.put(std.testing.allocator, "too large to retain", .{ 0, 0 });
    try std.testing.expectEqual(@as(usize, 1), c.entries.count());
    c.clear(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), c.bytes);
}
