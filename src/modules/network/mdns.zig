//! oriel.network.mdns: DNS-SD service registration and browsing (mDNS on
//! the local link), through the platform's own responder, so no app needs
//! multicast sockets, the multicast lock or Apple's multicast entitlement.
//!
//!     const reg = try oriel.network.mdns.register(.{
//!         .type = "_FC9F5ED42C8A._tcp",
//!         .name = "I0FCQ0QAAAAAAA",
//!         .port = 47001,
//!         .txt = &.{.{ .key = "n", .value = endpoint_info_b64 }},
//!     });
//!     defer reg.unregister();
//!     std.log.info("announced as {s}", .{reg.name()}); // the OS may rename on a conflict
//!
//!     const browser = try oriel.network.mdns.browse("_FC9F5ED42C8A._tcp", onEvent, null);
//!     defer browser.stop();
//!
//!     fn onEvent(ctx: ?*anyopaque, event: *const oriel.network.mdns.Event) void {
//!         switch (event.*) {
//!             .found => |f| ..., // f.addresses: "192.168.1.20", "fe80::1%wlan0"
//!             .lost => |l| ...,
//!         }
//!     }
//!
//! Threads:
//! - `register` and `browse` may be called from any thread, the main thread
//!   and a handler included. They block until the OS accepts or refuses
//!   (normally well under a second, at most `answer_timeout_ms`), so the
//!   errors come back from the call.
//! - `Registration.unregister` and `Browser.stop`: any thread, a handler
//!   included. Once `stop` returns the handler isn't called again (from
//!   inside the handler: once that call returns).
//! - Handlers run on the backend's mDNS thread (Android: the `oriel-mdns`
//!   Java thread), never on the main thread, one call at a time across all
//!   browsers, and may start before `browse` returns. An event's data is
//!   valid only during the call: copy what you keep. Don't block in a
//!   handler (later events wait for it), and don't wait there for the main
//!   thread: it may be in `stop`, waiting for the handler.
//! - `found` repeats for a name whose addresses, port or TXT change (an
//!   update); `lost` comes only for a name that was `found`.
//!
//! Declaring `.permissions = .{ .local_network = "..." }` is required
//! (`error.NotDeclared`), as it is for the multicast lock: iOS and macOS
//! will need its NSLocalNetworkUsageDescription and NSBonjourServices.
//!
//! Backends:
//! - Android: NsdManager (OrielMdns.kt). See network/android.zig.
//! - Linux, Windows, macOS, iOS: `error.Unsupported` for now (`supported()`
//!   is false). TODO: Apple DNSServiceRegister/DNSServiceBrowse (dns_sd.h,
//!   libSystem) or NWListener/NWBrowser; Linux Avahi over D-Bus
//!   (org.freedesktop.Avahi EntryGroup and ServiceBrowser); Windows
//!   DnsServiceRegister/DnsServiceBrowse/DnsServiceResolve (windns.h, 10+).
//!
//! A C ABI over this for native code linked into the app (a Rust engine):
//! network/mdns_c.zig, exported on Android.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// One TXT record entry (`key=value`). The value is bytes: DNS-SD allows any.
pub const Txt = struct { key: []const u8, value: []const u8 };

/// A service to announce. `type`: `_name._tcp` or `_name._udp` (no domain,
/// no subtype), e.g. Quick Share's "_FC9F5ED42C8A._tcp". `name`: the
/// instance name, 1 to 63 bytes of UTF-8.
pub const Service = struct {
    type: []const u8,
    name: []const u8,
    port: u16,
    txt: []const Txt = &.{},
};

/// A service seen on the network, resolved.
pub const Found = struct {
    name: []const u8,
    /// The type browsed for, as passed to `browse`.
    type: []const u8,
    /// The target host's name, when the platform reports it (Android
    /// doesn't).
    host: ?[]const u8,
    /// IPv4 and IPv6 addresses as text; a link-local IPv6 address carries
    /// its scope ("fe80::1%wlan0"). Can be empty.
    addresses: []const []const u8,
    port: u16,
    txt: []const Txt,

    /// The value of TXT key `key` (keys compare case-insensitively).
    pub fn txtValue(self: Found, key: []const u8) ?[]const u8 {
        for (self.txt) |t| if (std.ascii.eqlIgnoreCase(t.key, key)) return t.value;
        return null;
    }
};

pub const Lost = struct { name: []const u8, type: []const u8 };

pub const Event = union(enum) {
    found: Found,
    lost: Lost,
};

/// Called for each event on the mDNS thread; `event` is valid only during
/// the call.
pub const Handler = *const fn (ctx: ?*anyopaque, event: *const Event) void;

pub const Error = error{
    /// No backend on this platform yet (`supported()` is false).
    Unsupported,
    /// The app doesn't declare `.permissions = .{ .local_network = "..." }`.
    NotDeclared,
    /// Not `_name._tcp` / `_name._udp` (see `validateType`).
    InvalidServiceType,
    /// The instance name is empty, longer than 63 bytes or not UTF-8.
    InvalidName,
    /// A TXT key is empty, has `=` or a non-printable byte, an entry is
    /// over 255 bytes, or the record over `max_txt_bytes`.
    InvalidTxt,
    /// The OS refused (logged with its reason), or the app isn't running.
    Failed,
    /// The OS didn't answer within `answer_timeout_ms`.
    Timeout,
    /// Too many registrations or browsers at once (`max_handles`).
    TooMany,
    OutOfMemory,
};

/// How long `register` and `browse` wait for the OS.
pub const answer_timeout_ms = 10_000;
/// The DNS label limit for an instance name.
pub const max_name_bytes = 63;
/// The whole TXT record (RFC 6763 6.2 suggests staying under 1300 bytes so
/// it fits a packet; Android refuses more).
pub const max_txt_bytes = 1300;
/// Registrations, and browsers, alive at once (each).
pub const max_handles = 32;

/// An announced service, until `unregister`.
pub const Registration = struct {
    id: u32,
    name_buf: [max_name_bytes]u8 = undefined,
    name_len: u8 = 0,

    /// The name the OS announces: the requested one, or a renamed one
    /// ("Name (2)") if another device had it.
    pub fn name(self: *const Registration) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn unregister(self: Registration) void {
        backend.unregister(self.id);
    }
};

/// A running browse, until `stop`.
pub const Browser = struct {
    id: u32,

    pub fn stop(self: Browser) void {
        backend.stopBrowse(self.id);
    }
};

const backend = @import("../network.zig").impl.mdns_backend;
const common = @import("common.zig");

/// Whether this platform has a backend (false: `register` and `browse`
/// return `error.Unsupported`).
pub fn supported() bool {
    return backend.supported;
}

/// Announce `service` until `unregister`. Blocks until the OS accepts it.
pub fn register(service: Service) Error!Registration {
    try validateService(service);
    if (!backend.supported) return error.Unsupported;
    if (!common.localNetworkDeclared()) return error.NotDeclared;
    return backend.register(service);
}

/// Browse for `service_type` until `stop`; `handler(ctx, event)` gets the
/// services found (resolved) and lost. Blocks until the OS starts browsing.
pub fn browse(service_type: []const u8, handler: Handler, ctx: ?*anyopaque) Error!Browser {
    try validateType(service_type);
    if (!backend.supported) return error.Unsupported;
    if (!common.localNetworkDeclared()) return error.NotDeclared;
    return backend.browse(trimDot(service_type), handler, ctx);
}

/// The backend for platforms without one yet.
pub const Unsupported = struct {
    pub const supported = false;
    pub fn register(_: Service) Error!Registration {
        return error.Unsupported;
    }
    pub fn unregister(_: u32) void {}
    pub fn browse(_: []const u8, _: Handler, _: ?*anyopaque) Error!Browser {
        return error.Unsupported;
    }
    pub fn stopBrowse(_: u32) void {}
};

// ---------------------------------------------------------------------------
// Validation (pure)
// ---------------------------------------------------------------------------

fn trimDot(t: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, t, ".")) t[0 .. t.len - 1] else t;
}

/// A service type every backend accepts: `_name._tcp` or `_name._udp`, an
/// optional trailing dot, no subtype or domain. `name` follows RFC 6335:
/// 1 to 15 letters, digits and hyphens, at least one letter, no hyphen at
/// either end or two in a row. Case doesn't matter.
pub fn validateType(service_type: []const u8) Error!void {
    const t = trimDot(service_type);
    var parts = std.mem.splitScalar(u8, t, '.');
    const service = parts.next() orelse return error.InvalidServiceType;
    const proto = parts.next() orelse return error.InvalidServiceType;
    if (parts.next() != null) return error.InvalidServiceType;
    if (!std.ascii.eqlIgnoreCase(proto, "_tcp") and !std.ascii.eqlIgnoreCase(proto, "_udp")) return error.InvalidServiceType;
    if (service.len < 2 or service[0] != '_') return error.InvalidServiceType;
    const label = service[1..];
    if (label.len > 15) return error.InvalidServiceType;
    if (label[0] == '-' or label[label.len - 1] == '-') return error.InvalidServiceType;
    var letters: usize = 0;
    for (label, 0..) |c, i| {
        if (std.ascii.isAlphabetic(c)) {
            letters += 1;
        } else if (c == '-') {
            if (label[i - 1] == '-') return error.InvalidServiceType;
        } else if (!std.ascii.isDigit(c)) return error.InvalidServiceType;
    }
    if (letters == 0) return error.InvalidServiceType;
}

pub fn validateName(name: []const u8) Error!void {
    if (name.len == 0 or name.len > max_name_bytes) return error.InvalidName;
    if (!std.unicode.utf8ValidateSlice(name)) return error.InvalidName;
    for (name) |c| if (c < 0x20 or c == 0x7f) return error.InvalidName;
}

/// RFC 6763 6.4-6.5: keys are printable ASCII without `=`; each `key=value`
/// fits its 255-byte length prefix. Keys must be distinct
/// (case-insensitively), and the record at most `max_txt_bytes`.
pub fn validateTxt(txt: []const Txt) Error!void {
    var total: usize = 0;
    for (txt, 0..) |t, i| {
        if (t.key.len == 0) return error.InvalidTxt;
        for (t.key) |c| if (c < 0x20 or c > 0x7e or c == '=') return error.InvalidTxt;
        const entry = t.key.len + 1 + t.value.len;
        if (entry > 255) return error.InvalidTxt;
        for (txt[0..i]) |prev| if (std.ascii.eqlIgnoreCase(prev.key, t.key)) return error.InvalidTxt;
        total += 1 + entry;
    }
    if (total > max_txt_bytes) return error.InvalidTxt;
}

pub fn validateService(service: Service) Error!void {
    try validateType(service.type);
    try validateName(service.name);
    try validateTxt(service.txt);
}

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
    const name = try r.str();
    const event: Event = switch (kind) {
        0 => blk: {
            const host = try r.str();
            const port = try r.u16_();
            const addresses = try arena.alloc([]const u8, try r.u8_());
            for (addresses) |*a| a.* = try r.str();
            const txt = try arena.alloc(Txt, try r.u8_());
            for (txt) |*t| t.* = .{ .key = try r.str(), .value = try r.str() };
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

test validateType {
    try validateType("_FC9F5ED42C8A._tcp");
    try validateType("_http._tcp.");
    try validateType("_my-svc._udp");
    try validateType("_a._TCP");
    try validateType("_abcdefghijklmno._tcp"); // 15
    const bad = [_][]const u8{
        "",                       "_tcp",             "http._tcp",            "_http",
        "_http._sctp",            "_._tcp",           "__._tcp",              "_-http._tcp",
        "_http-._tcp",            "_ht--tp._tcp",     "_123._tcp",            "_ht.tp._tcp",
        "_abcdefghijklmnop._tcp", "_http._tcp.local", "_sub._sub._http._tcp", "_ht_tp._tcp",
        "_http._tcp..",
    };
    for (bad) |t| testing.expectError(error.InvalidServiceType, validateType(t)) catch |err| {
        std.debug.print("accepted: \"{s}\"\n", .{t});
        return err;
    };
}

test validateName {
    try validateName("I0FCQ0QAAAAAAA");
    try validateName("Sergio's Pixel (2)");
    try validateName("a" ** 63);
    try testing.expectError(error.InvalidName, validateName(""));
    try testing.expectError(error.InvalidName, validateName("a" ** 64));
    try testing.expectError(error.InvalidName, validateName("bad\xff"));
    try testing.expectError(error.InvalidName, validateName("tab\there"));
}

test validateTxt {
    try validateTxt(&.{});
    try validateTxt(&.{ .{ .key = "n", .value = "AQIDBA" }, .{ .key = "flag", .value = "" }, .{ .key = "bin", .value = "\x00\xff" } });
    try testing.expectError(error.InvalidTxt, validateTxt(&.{.{ .key = "", .value = "x" }}));
    try testing.expectError(error.InvalidTxt, validateTxt(&.{.{ .key = "a=b", .value = "x" }}));
    try testing.expectError(error.InvalidTxt, validateTxt(&.{.{ .key = "k\x01", .value = "x" }}));
    try testing.expectError(error.InvalidTxt, validateTxt(&.{ .{ .key = "k", .value = "1" }, .{ .key = "K", .value = "2" } }));
    try validateTxt(&.{.{ .key = "k", .value = "v" ** 253 }}); // 255 with "k="
    try testing.expectError(error.InvalidTxt, validateTxt(&.{.{ .key = "k", .value = "v" ** 254 }}));
    const big = [_]Txt{
        .{ .key = "a", .value = "x" ** 250 }, .{ .key = "b", .value = "x" ** 250 }, .{ .key = "c", .value = "x" ** 250 },
        .{ .key = "d", .value = "x" ** 250 }, .{ .key = "e", .value = "x" ** 250 }, .{ .key = "f", .value = "x" ** 250 },
    };
    try testing.expectError(error.InvalidTxt, validateTxt(&big));
}

test validateService {
    try validateService(.{ .type = "_FC9F5ED42C8A._tcp", .name = "I0FCQ0QAAAAAAA", .port = 1 });
    try testing.expectError(error.InvalidServiceType, validateService(.{ .type = "_x", .name = "n", .port = 1 }));
    try testing.expectError(error.InvalidName, validateService(.{ .type = "_x._tcp", .name = "", .port = 1 }));
}

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

test "Registration.name" {
    var r: Registration = .{ .id = 1 };
    @memcpy(r.name_buf[0..4], "Name");
    r.name_len = 4;
    try testing.expectEqualStrings("Name", r.name());
}
