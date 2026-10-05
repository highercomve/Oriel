//! A C ABI over oriel.network.mdns, for native code linked into the app (a
//! Rust or C engine in the same liboriel.so). Exported on Android only, the
//! one platform with a backend so far. The same rules as the Zig API
//! (network/mdns.zig): `local_network` must be declared; register/browse
//! block until the OS answers; callbacks run on the mDNS thread (Android:
//! `oriel-mdns`), one at a time, and the event is valid only during the
//! call; unregister/stop work from any thread, a callback included, and no
//! callback starts after `oriel_mdns_browse_stop` returns.
//!
//! ```c
//! #include <stddef.h>
//! #include <stdint.h>
//!
//! typedef struct oriel_mdns_txt {
//!     const char *key;           // NUL-terminated, printable ASCII, no '='
//!     const uint8_t *value;      // any bytes (may be NULL when value_len is 0)
//!     size_t value_len;
//! } oriel_mdns_txt;
//!
//! enum { ORIEL_MDNS_FOUND = 0, ORIEL_MDNS_LOST = 1 };
//!
//! typedef struct oriel_mdns_event {
//!     int32_t kind;                    // ORIEL_MDNS_FOUND or ORIEL_MDNS_LOST
//!     const char *name;                // the instance name (UTF-8)
//!     const char *type;                // the type browsed, e.g. "_FC9F5ED42C8A._tcp"
//!     const char *host;                // NULL when unknown (always on Android); NULL for LOST
//!     const char *const *addresses;    // "192.168.1.20", "fe80::1%wlan0"; FOUND only
//!     size_t address_count;
//!     uint16_t port;                   // FOUND only
//!     const oriel_mdns_txt *txt;       // FOUND only
//!     size_t txt_count;
//! } oriel_mdns_event;
//!
//! typedef void (*oriel_mdns_callback)(void *ctx, const oriel_mdns_event *event);
//!
//! // 1 when this platform has a backend.
//! int32_t oriel_mdns_supported(void);
//! // 0, or a negative ORIEL_MDNS_E_* code. `out_name` (may be NULL) gets the
//! // announced name, NUL-terminated and truncated to `out_name_size` (64 fits any).
//! int32_t oriel_mdns_register(const char *type, const char *name, uint16_t port,
//!                             const oriel_mdns_txt *txt, size_t txt_count,
//!                             uint32_t *out_handle, char *out_name, size_t out_name_size);
//! void oriel_mdns_unregister(uint32_t handle);
//! int32_t oriel_mdns_browse(const char *type, oriel_mdns_callback cb, void *ctx,
//!                           uint32_t *out_handle);
//! void oriel_mdns_browse_stop(uint32_t handle);
//!
//! enum {
//!     ORIEL_MDNS_E_UNSUPPORTED = -1, ORIEL_MDNS_E_NOT_DECLARED = -2,
//!     ORIEL_MDNS_E_INVALID_TYPE = -3, ORIEL_MDNS_E_INVALID_NAME = -4,
//!     ORIEL_MDNS_E_INVALID_TXT = -5, ORIEL_MDNS_E_FAILED = -6,
//!     ORIEL_MDNS_E_TIMEOUT = -7, ORIEL_MDNS_E_TOO_MANY = -8,
//!     ORIEL_MDNS_E_NO_MEMORY = -9, ORIEL_MDNS_E_INVALID_ARGUMENT = -10,
//! };
//! ```
//!
//! From Rust: declare these `extern "C"` with `#[repr(C)]` structs of the
//! same layout; copy what the callback needs (`CStr::from_ptr(...)
//! .to_owned()`) before returning.

const std = @import("std");
const mdns = @import("mdns.zig");
const target = @import("../../core/target.zig");
const heap = @import("../../core/heap.zig");

pub const Txt = extern struct {
    key: ?[*:0]const u8,
    value: ?[*]const u8,
    value_len: usize,
};

pub const Event = extern struct {
    kind: i32,
    name: [*:0]const u8,
    type: [*:0]const u8,
    host: ?[*:0]const u8,
    addresses: ?[*]const [*:0]const u8,
    address_count: usize,
    port: u16,
    txt: ?[*]const Txt,
    txt_count: usize,
};

pub const Callback = *const fn (ctx: ?*anyopaque, event: *const Event) callconv(.c) void;

pub const found: i32 = 0;
pub const lost: i32 = 1;

pub fn errorCode(err: mdns.Error) i32 {
    return switch (err) {
        error.Unsupported => -1,
        error.NotDeclared => -2,
        error.InvalidServiceType => -3,
        error.InvalidName => -4,
        error.InvalidTxt => -5,
        error.Failed => -6,
        error.Timeout => -7,
        error.TooMany => -8,
        error.OutOfMemory => -9,
    };
}
pub const invalid_argument: i32 = -10;

/// `event` as the C struct, its strings and arrays allocated with `arena`.
pub fn toC(arena: std.mem.Allocator, event: *const mdns.Event) std.mem.Allocator.Error!Event {
    switch (event.*) {
        .found => |f| {
            const addresses = try arena.alloc([*:0]const u8, f.addresses.len);
            for (addresses, f.addresses) |*d, s| d.* = try arena.dupeZ(u8, s);
            const txt = try arena.alloc(Txt, f.txt.len);
            for (txt, f.txt) |*d, s| d.* = .{ .key = try arena.dupeZ(u8, s.key), .value = s.value.ptr, .value_len = s.value.len };
            return .{
                .kind = found,
                .name = try arena.dupeZ(u8, f.name),
                .type = try arena.dupeZ(u8, f.type),
                .host = if (f.host) |h| try arena.dupeZ(u8, h) else null,
                .addresses = addresses.ptr,
                .address_count = addresses.len,
                .port = f.port,
                .txt = txt.ptr,
                .txt_count = txt.len,
            };
        },
        .lost => |l| return .{
            .kind = lost,
            .name = try arena.dupeZ(u8, l.name),
            .type = try arena.dupeZ(u8, l.type),
            .host = null,
            .addresses = null,
            .address_count = 0,
            .port = 0,
            .txt = null,
            .txt_count = 0,
        },
    }
}

/// The TXT entries of a C array (slices into the caller's memory).
pub fn fromC(arena: std.mem.Allocator, txt: ?[*]const Txt, count: usize) error{ OutOfMemory, InvalidArgument }![]mdns.Txt {
    if (count == 0) return &.{};
    const in = (txt orelse return error.InvalidArgument)[0..count];
    const out = try arena.alloc(mdns.Txt, count);
    for (out, in) |*d, s| {
        const key = s.key orelse return error.InvalidArgument;
        const value: []const u8 = if (s.value_len == 0) "" else (s.value orelse return error.InvalidArgument)[0..s.value_len];
        d.* = .{ .key = std.mem.span(key), .value = value };
    }
    return out;
}

/// A C callback behind a Zig handler, until its browser stops.
const Adapter = struct {
    cb: Callback,
    ctx: ?*anyopaque,
    handle: u32 = 0,

    fn handle_(ctx: ?*anyopaque, event: *const mdns.Event) void {
        const self: *Adapter = @ptrCast(@alignCast(ctx.?));
        const cb = self.cb;
        const user = self.ctx;
        var arena: std.heap.ArenaAllocator = .init(heap.gpa);
        defer arena.deinit();
        const c = toC(arena.allocator(), event) catch return;
        // `self` may be freed from inside the callback (browse_stop).
        cb(user, &c);
    }
};

/// The adapters of live browsers, to free on stop.
var adapters: [mdns.max_handles]?*Adapter = @splat(null);
var adapters_busy: std.atomic.Value(bool) = .init(false);

fn lockAdapters() void {
    while (adapters_busy.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn unlockAdapters() void {
    adapters_busy.store(false, .release);
}

fn supported() callconv(.c) i32 {
    return @intFromBool(mdns.supported());
}

fn register(
    type_z: ?[*:0]const u8,
    name_z: ?[*:0]const u8,
    port: u16,
    txt: ?[*]const Txt,
    txt_count: usize,
    out_handle: ?*u32,
    out_name: ?[*]u8,
    out_name_size: usize,
) callconv(.c) i32 {
    const t = type_z orelse return invalid_argument;
    const n = name_z orelse return invalid_argument;
    var arena: std.heap.ArenaAllocator = .init(heap.gpa);
    defer arena.deinit();
    const entries = fromC(arena.allocator(), txt, txt_count) catch |err| return switch (err) {
        error.OutOfMemory => errorCode(error.OutOfMemory),
        error.InvalidArgument => invalid_argument,
    };
    const reg = mdns.register(.{ .type = std.mem.span(t), .name = std.mem.span(n), .port = port, .txt = entries }) catch |err| return errorCode(err);
    if (out_handle) |h| h.* = reg.id;
    if (out_name) |buf| if (out_name_size > 0) {
        const len = @min(reg.name().len, out_name_size - 1);
        @memcpy(buf[0..len], reg.name()[0..len]);
        buf[len] = 0;
    };
    return 0;
}

fn unregister(handle: u32) callconv(.c) void {
    (mdns.Registration{ .id = handle }).unregister();
}

fn browse(type_z: ?[*:0]const u8, cb: ?Callback, ctx: ?*anyopaque, out_handle: ?*u32) callconv(.c) i32 {
    const t = type_z orelse return invalid_argument;
    const callback = cb orelse return invalid_argument;
    const adapter = heap.gpa.create(Adapter) catch return errorCode(error.OutOfMemory);
    adapter.* = .{ .cb = callback, .ctx = ctx };
    const slot = blk: {
        lockAdapters();
        defer unlockAdapters();
        for (&adapters, 0..) |*a, i| if (a.* == null) {
            a.* = adapter;
            break :blk i;
        };
        heap.gpa.destroy(adapter);
        return errorCode(error.TooMany);
    };
    const b = mdns.browse(std.mem.span(t), Adapter.handle_, adapter) catch |err| {
        lockAdapters();
        adapters[slot] = null;
        unlockAdapters();
        heap.gpa.destroy(adapter);
        return errorCode(err);
    };
    // Set before any event can reach a stop for this handle (the caller
    // learns the handle from us).
    adapter.handle = b.id;
    if (out_handle) |h| h.* = b.id;
    return 0;
}

fn browseStop(handle: u32) callconv(.c) void {
    (mdns.Browser{ .id = handle }).stop();
    const adapter = blk: {
        lockAdapters();
        defer unlockAdapters();
        for (&adapters) |*a| if (a.*) |p| if (p.handle == handle) {
            a.* = null;
            break :blk p;
        };
        return;
    };
    heap.gpa.destroy(adapter);
}

comptime {
    if (target.is_android) {
        @export(&supported, .{ .name = "oriel_mdns_supported" });
        @export(&register, .{ .name = "oriel_mdns_register" });
        @export(&unregister, .{ .name = "oriel_mdns_unregister" });
        @export(&browse, .{ .name = "oriel_mdns_browse" });
        @export(&browseStop, .{ .name = "oriel_mdns_browse_stop" });
    }
}

const testing = std.testing;

test "toC: found carries NUL-terminated strings and binary TXT" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const ev: mdns.Event = .{ .found = .{
        .name = "I0FCQ0QAAAAAAA",
        .type = "_FC9F5ED42C8A._tcp",
        .host = null,
        .addresses = &.{ "192.168.1.20", "fe80::1%wlan0" },
        .port = 47001,
        .txt = &.{.{ .key = "n", .value = "\x00\xff" }},
    } };
    const c = try toC(arena.allocator(), &ev);
    try testing.expectEqual(found, c.kind);
    try testing.expectEqualStrings("I0FCQ0QAAAAAAA", std.mem.span(c.name));
    try testing.expectEqualStrings("_FC9F5ED42C8A._tcp", std.mem.span(c.type));
    try testing.expect(c.host == null);
    try testing.expectEqual(@as(usize, 2), c.address_count);
    try testing.expectEqualStrings("fe80::1%wlan0", std.mem.span(c.addresses.?[1]));
    try testing.expectEqual(@as(u16, 47001), c.port);
    try testing.expectEqual(@as(usize, 1), c.txt_count);
    try testing.expectEqualStrings("n", std.mem.span(c.txt.?[0].key.?));
    try testing.expectEqualSlices(u8, "\x00\xff", c.txt.?[0].value.?[0..c.txt.?[0].value_len]);

    const l = try toC(arena.allocator(), &.{ .lost = .{ .name = "gone", .type = "_x._tcp" } });
    try testing.expectEqual(lost, l.kind);
    try testing.expectEqualStrings("gone", std.mem.span(l.name));
    try testing.expectEqual(@as(usize, 0), l.address_count);
}

test "fromC: TXT from C arrays" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = [_]u8{ 0, 1, 2 };
    const in = [_]Txt{ .{ .key = "n", .value = &v, .value_len = 3 }, .{ .key = "e", .value = null, .value_len = 0 } };
    const out = try fromC(arena.allocator(), &in, in.len);
    try testing.expectEqualStrings("n", out[0].key);
    try testing.expectEqualSlices(u8, &v, out[0].value);
    try testing.expectEqualStrings("", out[1].value);
    try testing.expectEqual(@as(usize, 0), (try fromC(arena.allocator(), null, 0)).len);
    try testing.expectError(error.InvalidArgument, fromC(arena.allocator(), null, 1));
    const no_key = [_]Txt{.{ .key = null, .value = null, .value_len = 0 }};
    try testing.expectError(error.InvalidArgument, fromC(arena.allocator(), &no_key, 1));
}

test errorCode {
    try testing.expectEqual(@as(i32, -1), errorCode(error.Unsupported));
    try testing.expectEqual(@as(i32, -9), errorCode(error.OutOfMemory));
}
