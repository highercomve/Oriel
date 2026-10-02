//! The app's `Io` on Android: `std.Io.Threaded` with two lookups changed.
//!
//! Host names: Threaded resolves them itself on Linux, from /etc/resolv.conf
//! and /etc/hosts. Android has neither: its resolver is the netd service
//! behind libc's getaddrinfo (per-network DNS, private DNS, VPNs), so every
//! lookup failed with NameServerFailure (no downloads, no update checks, no
//! HTTP to a host name).
//!
//! The executable path: an app process is Android's app_process64, so an
//! app that starts itself as a helper (`--llm-helper`, a worker) started the
//! Android runtime instead. The APK carries a small launcher next to the
//! library (liboriel_exec.so: launcher.zig), which runs the app's `main` in a
//! process of its own, and this is the path apps get.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const HostName = net.HostName;
const posix = std.posix;

var vtable: Io.VTable = undefined;

var base_vtable: *const Io.VTable = undefined;

/// `base` with these lookups; `base` must outlive the result.
pub fn wrap(base: Io) Io {
    base_vtable = base.vtable;
    vtable = base.vtable.*;
    vtable.netLookup = netLookup;
    vtable.processExecutablePath = executablePath;
    return .{ .userdata = base.userdata, .vtable = &vtable };
}

/// The launcher's name, next to liboriel.so in the app's native library
/// directory (build.zig installs it; the Gradle project extracts the
/// libraries so it is a file Android lets the app run).
pub const launcher_name = "liboriel_exec.so";

fn executablePath(userdata: ?*anyopaque, buffer: []u8) std.process.ExecutablePathError!usize {
    if (launcherPath(buffer)) |n| return n;
    return base_vtable.processExecutablePath(userdata, buffer);
}

/// bionic's Dl_info (std declares dladdr for Darwin only).
const DlInfo = extern struct {
    fname: ?[*:0]const u8,
    fbase: ?*anyopaque,
    sname: ?[*:0]const u8,
    saddr: ?*anyopaque,
};
extern "c" fn dladdr(addr: ?*const anyopaque, info: *DlInfo) c_int;

/// `<directory of this library>/liboriel_exec.so` if it can be run.
fn launcherPath(buffer: []u8) ?usize {
    var info: DlInfo = undefined;
    if (dladdr(@ptrCast(&launcherPath), &info) == 0) return null;
    const lib = std.mem.sliceTo(info.fname orelse return null, 0);
    const dir = std.fs.path.dirname(lib) orelse return null;
    const n = dir.len + 1 + launcher_name.len;
    if (n + 1 > buffer.len) return null;
    @memcpy(buffer[0..dir.len], dir);
    buffer[dir.len] = '/';
    @memcpy(buffer[dir.len + 1 .. n], launcher_name);
    buffer[n] = 0;
    if (std.c.access(@ptrCast(buffer[0..n :0].ptr), std.c.X_OK) != 0) return null;
    return n;
}

fn netLookup(
    userdata: ?*anyopaque,
    host_name: HostName,
    resolved: *Io.Queue(HostName.LookupResult),
    options: HostName.LookupOptions,
) HostName.LookupError!void {
    const io: Io = .{ .userdata = userdata, .vtable = &vtable };
    defer resolved.close(io);
    lookup(io, host_name, resolved, options) catch |err| switch (err) {
        error.Closed => unreachable, // `resolved` stays open until netLookup returns
        else => |e| return e,
    };
}

fn lookup(
    io: Io,
    host_name: HostName,
    resolved: *Io.Queue(HostName.LookupResult),
    options: HostName.LookupOptions,
) (HostName.LookupError || Io.QueueClosedError)!void {
    const name = host_name.bytes;
    var name_buf: [HostName.max_len:0]u8 = undefined;
    @memcpy(name_buf[0..name.len], name);
    name_buf[name.len] = 0;
    var port_buf: [8]u8 = undefined;
    const port = std.fmt.bufPrintZ(&port_buf, "{d}", .{options.port}) catch unreachable;

    const hints: posix.addrinfo = .{
        .flags = .{ .CANONNAME = options.canonical_name_buffer != null, .NUMERICSERV = true },
        .family = if (options.family) |f| switch (f) {
            .ip4 => posix.AF.INET,
            .ip6 => posix.AF.INET6,
        } else posix.AF.UNSPEC,
        .socktype = posix.SOCK.STREAM,
        .protocol = posix.IPPROTO.TCP,
        .canonname = null,
        .addr = null,
        .addrlen = 0,
        .next = null,
    };
    var res: ?*posix.addrinfo = null;
    // Blocking (bionic has no asynchronous getaddrinfo); netd answers or
    // times out on its own.
    while (true) switch (std.c.getaddrinfo(name_buf[0..name.len :0].ptr, port.ptr, &hints, &res)) {
        @as(std.c.EAI, @enumFromInt(0)) => break,
        .SYSTEM => switch (posix.errno(-1)) {
            .INTR => continue,
            else => return error.NameServerFailure,
        },
        .AGAIN, .FAIL => return error.NameServerFailure,
        .NODATA, .NONAME => return error.UnknownHostName,
        .FAMILY, .ADDRFAMILY => return error.AddressFamilyUnsupported,
        .MEMORY => return error.SystemResources,
        else => return error.NameServerFailure,
    };
    defer if (res) |r| std.c.freeaddrinfo(r);

    var found = false;
    var canon: ?[*:0]const u8 = null;
    var it = res;
    while (it) |info| : (it = info.next) {
        const sa = info.addr orelse continue;
        const addr: net.IpAddress = switch (sa.family) {
            posix.AF.INET => blk: {
                const in: *const posix.sockaddr.in = @ptrCast(@alignCast(sa));
                break :blk .{ .ip4 = .{ .port = std.mem.bigToNative(u16, in.port), .bytes = @bitCast(in.addr) } };
            },
            posix.AF.INET6 => blk: {
                const in6: *const posix.sockaddr.in6 = @ptrCast(@alignCast(sa));
                break :blk .{ .ip6 = .{
                    .port = std.mem.bigToNative(u16, in6.port),
                    .bytes = in6.addr,
                    .flow = in6.flowinfo,
                    .interface = .{ .index = in6.scope_id },
                } };
            },
            else => continue,
        };
        try resolved.putOne(io, .{ .address = addr });
        found = true;
        if (canon == null) canon = info.canonname;
    }
    if (!found) return error.UnknownHostName;
    if (options.canonical_name_buffer) |buf| {
        const n = if (canon) |c| std.mem.sliceTo(c, 0) else name;
        const len = @min(n.len, buf.len);
        @memcpy(buf[0..len], n[0..len]);
        try resolved.putOne(io, .{ .canonical_name = .{ .bytes = buf[0..len] } });
    }
}
