//! oriel.network.mdns between Zig and a backend's other side (Kotlin):
//! internal to the backends (network/android.zig).

const std = @import("std");
const Allocator = std.mem.Allocator;
const mdns = @import("mdns.zig");
const Txt = mdns.Txt;
const Event = mdns.Event;
const Found = mdns.Found;

// ---------------------------------------------------------------------------
// The wire format between Zig and a backend's other side (Kotlin): big
// endian, as java.io.DataOutputStream writes. A string is a u16 length and
// its bytes.
//
//   TXT (Zig -> Kotlin, register): u16 count, then per entry: key, value.
//   Event (Kotlin -> Zig): u8 kind, name, then
//     kind 0 (found): host (empty = none), u16 port,
//                     u8 address count, addresses, u8 TXT count, key/value pairs
//     kind 1 (lost):  nothing more.
// ---------------------------------------------------------------------------

/// The TXT record in the wire format above (caller frees). Validate first.
pub fn encodeTxt(gpa: Allocator, txt: []const Txt) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try putU16(gpa, &out, @intCast(txt.len));
    for (txt) |t| {
        try putStr(gpa, &out, t.key);
        try putStr(gpa, &out, t.value);
    }
    return out.toOwnedSlice(gpa);
}

fn putU16(gpa: Allocator, out: *std.ArrayList(u8), v: u16) Allocator.Error!void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .big);
    try out.appendSlice(gpa, &b);
}

fn putStr(gpa: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    try putU16(gpa, out, @intCast(@min(s.len, std.math.maxInt(u16))));
    try out.appendSlice(gpa, s[0..@min(s.len, std.math.maxInt(u16))]);
}

pub const DecodeError = error{ Malformed, OutOfMemory };

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn u8_(self: *Reader) DecodeError!u8 {
        if (self.pos + 1 > self.bytes.len) return error.Malformed;
        defer self.pos += 1;
        return self.bytes[self.pos];
    }

    fn u16_(self: *Reader) DecodeError!u16 {
        if (self.pos + 2 > self.bytes.len) return error.Malformed;
        defer self.pos += 2;
        return std.mem.readInt(u16, self.bytes[self.pos..][0..2], .big);
    }

    fn str(self: *Reader) DecodeError![]const u8 {
        const n = try self.u16_();
        if (self.pos + n > self.bytes.len) return error.Malformed;
        defer self.pos += n;
        return self.bytes[self.pos..][0..n];
    }

    /// A string C callers get NUL-terminated (a name, host, address or TXT
    /// key): one with a NUL inside would be silently cut there.
    fn text(self: *Reader) DecodeError![]const u8 {
        const s = try self.str();
        if (std.mem.indexOfScalar(u8, s, 0) != null) return error.Malformed;
        return s;
    }
};

/// Decode a TXT record from the wire format (slices point into `bytes`;
/// the array is allocated with `arena`).
pub fn decodeTxt(arena: Allocator, bytes: []const u8) DecodeError![]Txt {
    var r: Reader = .{ .bytes = bytes };
    const n = try r.u16_();
    const txt = try arena.alloc(Txt, n);
    for (txt) |*t| t.* = .{ .key = try r.str(), .value = try r.str() };
    if (r.pos != bytes.len) return error.Malformed;
    return txt;
}

/// Decode an event from the wire format. Strings point into `bytes`; the
/// arrays are allocated with `arena`. `service_type` becomes the event's
/// `type`.
pub fn decodeEvent(arena: Allocator, bytes: []const u8, service_type: []const u8) DecodeError!Event {
    var r: Reader = .{ .bytes = bytes };
    const kind = try r.u8_();
    const name = try r.text();
    const event: Event = switch (kind) {
        0 => blk: {
            const host = try r.text();
            const port = try r.u16_();
            const addresses = try arena.alloc([]const u8, try r.u8_());
            for (addresses) |*a| a.* = try r.text();
            const txt = try arena.alloc(Txt, try r.u8_());
            for (txt) |*t| t.* = .{ .key = try r.text(), .value = try r.str() };
            break :blk .{ .found = .{
                .name = name,
                .type = service_type,
                .host = if (host.len == 0) null else host,
                .addresses = addresses,
                .port = port,
                .txt = txt,
            } };
        },
        1 => .{ .lost = .{ .name = name, .type = service_type } },
        else => return error.Malformed,
    };
    if (r.pos != bytes.len) return error.Malformed;
    return event;
}

/// Encode an event in the wire format (what OrielMdns.kt sends; for tests
/// and other backends).
pub fn encodeEvent(gpa: Allocator, event: Event) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    switch (event) {
        .found => |f| {
            try out.append(gpa, 0);
            try putStr(gpa, &out, f.name);
            try putStr(gpa, &out, f.host orelse "");
            try putU16(gpa, &out, f.port);
            try out.append(gpa, @intCast(@min(f.addresses.len, 255)));
            for (f.addresses[0..@min(f.addresses.len, 255)]) |a| try putStr(gpa, &out, a);
            try out.append(gpa, @intCast(@min(f.txt.len, 255)));
            for (f.txt[0..@min(f.txt.len, 255)]) |t| {
                try putStr(gpa, &out, t.key);
                try putStr(gpa, &out, t.value);
            }
        },
        .lost => |l| {
            try out.append(gpa, 1);
            try putStr(gpa, &out, l.name);
        },
    }
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "TXT: encode and decode are binary safe" {
    const txt = [_]Txt{ .{ .key = "n", .value = "I0FCQ0QAAAAAAA-_" }, .{ .key = "bin", .value = "\x00\x01\xff" }, .{ .key = "e", .value = "" } };
    const bytes = try encodeTxt(testing.allocator, &txt);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, "\x00\x03" ++ "\x00\x01n\x00\x10I0FCQ0QAAAAAAA-_" ++ "\x00\x03bin\x00\x03\x00\x01\xff" ++ "\x00\x01e\x00\x00", bytes);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const back = try decodeTxt(arena.allocator(), bytes);
    try testing.expectEqual(@as(usize, 3), back.len);
    for (txt, back) |a, b| {
        try testing.expectEqualStrings(a.key, b.key);
        try testing.expectEqualSlices(u8, a.value, b.value);
    }
    try testing.expectError(error.Malformed, decodeTxt(arena.allocator(), bytes[0 .. bytes.len - 1]));
}

test "Event: found and lost round-trip through the wire format" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const found: Event = .{ .found = .{
        .name = "I0FCQ0QAAAAAAA",
        .type = "_FC9F5ED42C8A._tcp",
        .host = null,
        .addresses = &.{ "192.168.1.20", "fe80::1%wlan0" },
        .port = 47001,
        .txt = &.{.{ .key = "n", .value = "\x00\xffAB" }},
    } };
    const bytes = try encodeEvent(a, found);
    const ev = try decodeEvent(a, bytes, "_FC9F5ED42C8A._tcp");
    const f = ev.found;
    try testing.expectEqualStrings("I0FCQ0QAAAAAAA", f.name);
    try testing.expectEqualStrings("_FC9F5ED42C8A._tcp", f.type);
    try testing.expect(f.host == null);
    try testing.expectEqual(@as(u16, 47001), f.port);
    try testing.expectEqual(@as(usize, 2), f.addresses.len);
    try testing.expectEqualStrings("fe80::1%wlan0", f.addresses[1]);
    try testing.expectEqualSlices(u8, "\x00\xffAB", f.txtValue("N").?);
    try testing.expect(f.txtValue("x") == null);

    const with_host = try encodeEvent(a, .{ .found = .{ .name = "x", .type = "", .host = "pixel.local", .addresses = &.{}, .port = 1, .txt = &.{} } });
    try testing.expectEqualStrings("pixel.local", (try decodeEvent(a, with_host, "_x._tcp")).found.host.?);

    const lost_bytes = try encodeEvent(a, .{ .lost = .{ .name = "gone", .type = "" } });
    try testing.expectEqualSlices(u8, "\x01\x00\x04gone", lost_bytes);
    const lost = (try decodeEvent(a, lost_bytes, "_x._tcp")).lost;
    try testing.expectEqualStrings("gone", lost.name);
    try testing.expectEqualStrings("_x._tcp", lost.type);
}

test "Event: malformed input is refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][]const u8{ "", "\x02\x00\x00", "\x01\x00\x05abc", "\x01\x00\x01ab", "\x00\x00\x01x\x00\x00\x00", "\x00\x00\x01x\x00\x00\x00\x01\x02\x00" };
    for (cases) |c| try testing.expectError(error.Malformed, decodeEvent(a, c, "_x._tcp"));
}

test "Event: a NUL inside a name, address or TXT key is refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok: Found = .{ .name = "n", .type = "", .host = null, .addresses = &.{"10.0.0.1"}, .port = 1, .txt = &.{.{ .key = "k", .value = "\x00v" }} };
    _ = try decodeEvent(a, try encodeEvent(a, .{ .found = ok }), "_x._tcp"); // a NUL in a value is fine
    var bad_name = ok;
    bad_name.name = "a\x00b";
    var bad_host = ok;
    bad_host.host = "h\x00.local";
    var bad_address = ok;
    bad_address.addresses = &.{"10.0.0.1\x00evil"};
    var bad_key = ok;
    bad_key.txt = &.{.{ .key = "k\x00", .value = "v" }};
    for ([_]Found{ bad_name, bad_host, bad_address, bad_key }) |f|
        try testing.expectError(error.Malformed, decodeEvent(a, try encodeEvent(a, .{ .found = f }), "_x._tcp"));
    try testing.expectError(error.Malformed, decodeEvent(a, try encodeEvent(a, .{ .lost = .{ .name = "\x00", .type = "" } }), "_x._tcp"));
}
