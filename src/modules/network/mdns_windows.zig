//! mDNS / DNS-SD on Windows (network/mdns.zig's backend): the DNS client's
//! own responder through dnsapi's DnsServiceRegister, DnsServiceBrowse and
//! DnsServiceResolve (windns.h, Windows 10 1809+). The service does the
//! multicast, so the app opens no sockets.
//!
//! Threads: the API calls are asynchronous; their callbacks come on the
//! DNS client's thread-pool threads. `register` and `unregister` wait for
//! theirs (an event). A browse callback starts a resolve for each instance
//! announced (a PTR record) and reports one that left (TTL 0); a resolve's
//! completion builds the `found` event. Events reach the handler under
//! `call_mutex`, one at a time across all browsers, after re-checking that
//! the browser still runs; `stopBrowse` cancels the browse and its resolves
//! and then waits out a handler running on another thread.
//!
//! Every OS request keeps its memory in a static slot (or, for a resolve, a
//! heap block freed by its own callback), and every callback finds its
//! browser or registration by id: a late callback after a stop finds
//! nothing and does nothing.
//!
//! TXT values travel as UTF-16 strings here, so they must be UTF-8 text
//! without NUL (Quick Share's are base64): `register` returns
//! error.InvalidTxt otherwise. A resolved value that isn't valid UTF-16 is
//! passed on as Windows decoded it.

const std = @import("std");
const mdns = @import("mdns.zig");
const win32 = @import("../../platform/windows/win32.zig");
const ShellMod = @import("../../platform/windows/Shell.zig");

const log = std.log.scoped(.mdns);
const gpa = std.heap.smp_allocator;

// ------------------------------------------------------------- windns.h

const DWORD = u32;
const WCHAR = u16;

const ServiceInstance = extern struct {
    pszInstanceName: ?[*:0]WCHAR,
    pszHostName: ?[*:0]WCHAR,
    ip4Address: ?*align(1) const u32,
    ip6Address: ?*const [16]u8,
    wPort: u16,
    wPriority: u16,
    wWeight: u16,
    dwPropertyCount: DWORD,
    keys: ?[*]?[*:0]WCHAR,
    values: ?[*]?[*:0]WCHAR,
    dwInterfaceIndex: DWORD,
};

const Cancel = extern struct { reserved: ?*anyopaque = null };

const RegisterComplete = *const fn (status: DWORD, ctx: ?*anyopaque, instance: ?*ServiceInstance) callconv(.winapi) void;
const BrowseCallback = *const fn (status: DWORD, ctx: ?*anyopaque, records: ?*Record) callconv(.winapi) void;
const ResolveComplete = *const fn (status: DWORD, ctx: ?*anyopaque, instance: ?*ServiceInstance) callconv(.winapi) void;

const RegisterRequest = extern struct {
    Version: u32 = request_version1,
    InterfaceIndex: u32 = 0,
    pServiceInstance: ?*ServiceInstance = null,
    pRegisterCompletionCallback: ?RegisterComplete = null,
    pQueryContext: ?*anyopaque = null,
    hCredentials: ?*anyopaque = null,
    unicastEnabled: i32 = 0,
};

const BrowseRequest = extern struct {
    Version: u32 = request_version1,
    InterfaceIndex: u32 = 0,
    QueryName: ?[*:0]const WCHAR = null,
    pBrowseCallback: ?BrowseCallback = null,
    pQueryContext: ?*anyopaque = null,
};

const ResolveRequest = extern struct {
    Version: u32 = request_version1,
    InterfaceIndex: u32 = 0,
    QueryName: ?[*:0]WCHAR = null,
    pResolveCompletionCallback: ?ResolveComplete = null,
    pQueryContext: ?*anyopaque = null,
};

/// DNS_RECORDW, up to its data (PTR: one name).
const Record = extern struct {
    pNext: ?*Record,
    pName: ?[*:0]WCHAR,
    wType: u16,
    wDataLength: u16,
    Flags: DWORD,
    dwTtl: DWORD,
    dwReserved: DWORD,
    /// Data.PTR.pNameHost for a PTR record.
    ptr_name_host: ?[*:0]WCHAR,
};

const request_version1: u32 = 1;
const request_pending: DWORD = 9506; // DNS_REQUEST_PENDING
const type_ptr: u16 = 12;
const free_record_list: u32 = 1; // DnsFreeRecordList

extern "dnsapi" fn DnsServiceConstructInstance(name: [*:0]const WCHAR, host: [*:0]const WCHAR, ip4: ?*const u32, ip6: ?*const [16]u8, port: u16, priority: u16, weight: u16, count: DWORD, keys: ?[*]const [*:0]const WCHAR, values: ?[*]const [*:0]const WCHAR) callconv(.winapi) ?*ServiceInstance;
extern "dnsapi" fn DnsServiceFreeInstance(instance: *ServiceInstance) callconv(.winapi) void;
extern "dnsapi" fn DnsServiceRegister(req: *RegisterRequest, cancel: ?*Cancel) callconv(.winapi) DWORD;
extern "dnsapi" fn DnsServiceRegisterCancel(cancel: *Cancel) callconv(.winapi) DWORD;
extern "dnsapi" fn DnsServiceDeRegister(req: *RegisterRequest, cancel: ?*Cancel) callconv(.winapi) DWORD;
extern "dnsapi" fn DnsServiceBrowse(req: *BrowseRequest, cancel: *Cancel) callconv(.winapi) DWORD;
extern "dnsapi" fn DnsServiceBrowseCancel(cancel: *Cancel) callconv(.winapi) DWORD;
extern "dnsapi" fn DnsServiceResolve(req: *ResolveRequest, cancel: *Cancel) callconv(.winapi) DWORD;
extern "dnsapi" fn DnsServiceResolveCancel(cancel: *Cancel) callconv(.winapi) DWORD;
extern "dnsapi" fn DnsRecordListFree(list: *Record, free_type: u32) callconv(.winapi) void;
extern "kernel32" fn GetComputerNameExW(kind: u32, buf: ?[*]WCHAR, len: *DWORD) callconv(.winapi) i32;
extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) DWORD;

// ------------------------------------------------------------------ state

/// "_name._tcp" plus ".local" and a NUL, as UTF-16.
const max_query = 40;

const RegSlot = struct {
    id: u32 = 0,
    req: RegisterRequest = .{},
    cancel: Cancel = .{},
    event: ?win32.HANDLE = null,
    status: DWORD = 0,
    name_buf: [mdns.max_name_bytes]u8 = undefined,
    name_len: u8 = 0,
};

const BrowseSlot = struct {
    id: u32 = 0,
    handler: ?mdns.Handler = null,
    ctx: ?*anyopaque = null,
    type_buf: [32]u8 = undefined,
    type_len: u8 = 0,
    query: [max_query:0]WCHAR = @splat(0),
    req: BrowseRequest = .{},
    cancel: Cancel = .{},
    /// Resolves in flight (freed by their callbacks).
    resolves: std.ArrayList(*Resolve) = .empty,
    /// Names reported `found`, and a hash of what was reported (an update
    /// repeats `found`, an identical answer doesn't). Under `call_mutex`.
    found: std.StringHashMapUnmanaged(Known) = .empty,

    fn serviceType(s: *const BrowseSlot) []const u8 {
        return s.type_buf[0..s.type_len];
    }
};

const Resolve = struct {
    browser: u32,
    name: [:0]WCHAR,
    req: ResolveRequest = .{},
    cancel: Cancel = .{},
};

var table_mutex: ShellMod.Mutex = .{};
var regs: [mdns.max_handles]RegSlot = @splat(.{});
var browsers: [mdns.max_handles]BrowseSlot = @splat(.{});
var next_id: u32 = 1;

/// One handler call at a time, across browsers.
var call_mutex: ShellMod.Mutex = .{};
/// The thread running a handler (0: none): `stopBrowse` from inside a
/// handler mustn't wait for itself.
var handler_tid: std.atomic.Value(DWORD) = .init(0);

fn newId() u32 {
    const id = next_id;
    next_id +%= 1;
    if (next_id == 0) next_id = 1;
    return id;
}

fn findReg(id: u32) ?*RegSlot {
    for (&regs) |*s| if (s.id == id and id != 0) return s;
    return null;
}

fn findBrowser(id: u32) ?*BrowseSlot {
    for (&browsers) |*s| if (s.id == id and id != 0) return s;
    return null;
}

fn idCtx(id: u32) ?*anyopaque {
    return @ptrFromInt(@as(usize, id));
}

fn ctxId(ctx: ?*anyopaque) u32 {
    return @truncate(@intFromPtr(ctx));
}

// ---------------------------------------------------------------- backend

pub const backend = struct {
    pub const supported = true;

    pub fn register(service: mdns.Service) mdns.Error!mdns.Registration {
        for (service.txt) |t| {
            if (!std.unicode.utf8ValidateSlice(t.value) or std.mem.indexOfScalar(u8, t.value, 0) != null) return error.InvalidTxt;
        }
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const full = try fullName(arena, service.name, service.type);
        const host = localHost(arena) catch return error.Failed;
        const keys = try arena.alloc([*:0]const WCHAR, service.txt.len);
        const values = try arena.alloc([*:0]const WCHAR, service.txt.len);
        for (service.txt, keys, values) |t, *k, *v| {
            k.* = (try wide(arena, t.key)).ptr;
            v.* = (try wide(arena, t.value)).ptr;
        }
        const instance = DnsServiceConstructInstance(full.ptr, host.ptr, null, null, service.port, 0, 0, @intCast(service.txt.len), if (keys.len > 0) keys.ptr else null, if (values.len > 0) values.ptr else null) orelse {
            log.err("register {s}: DnsServiceConstructInstance failed", .{service.type});
            return error.Failed;
        };
        const event = win32.CreateEventW(null, win32.FALSE, win32.FALSE, null) orelse {
            DnsServiceFreeInstance(instance);
            return error.Failed;
        };

        const slot, const id = blk: {
            table_mutex.lock();
            defer table_mutex.unlock();
            for (&regs) |*s| if (s.id == 0) {
                const id = newId();
                s.* = .{ .id = id, .event = event };
                s.req = .{ .pServiceInstance = instance, .pRegisterCompletionCallback = onRegistered, .pQueryContext = idCtx(id) };
                break :blk .{ s, id };
            };
            DnsServiceFreeInstance(instance);
            _ = win32.CloseHandle(event);
            return error.TooMany;
        };

        const rc = DnsServiceRegister(&slot.req, &slot.cancel);
        if (rc != request_pending) {
            log.err("register {s}: DnsServiceRegister: {d}", .{ service.type, rc });
            release(id);
            return error.Failed;
        }
        if (win32.WaitForSingleObject(event, mdns.answer_timeout_ms) != win32.WAIT_OBJECT_0) {
            log.err("register {s}: no answer", .{service.type});
            _ = DnsServiceRegisterCancel(&slot.cancel);
            // The cancel completes through the callback: wait for it, so
            // the slot can go.
            _ = win32.WaitForSingleObject(event, 2000);
            release(id);
            return error.Timeout;
        }
        if (slot.status != 0) {
            log.err("register {s}: {d}", .{ service.type, slot.status });
            release(id);
            return error.Failed;
        }
        var reg: mdns.Registration = .{ .id = id };
        if (slot.name_len > 0) {
            reg.name_len = slot.name_len;
            @memcpy(reg.name_buf[0..slot.name_len], slot.name_buf[0..slot.name_len]);
        } else {
            reg.name_len = @intCast(service.name.len);
            @memcpy(reg.name_buf[0..service.name.len], service.name);
        }
        return reg;
    }

    pub fn unregister(id: u32) void {
        const slot = blk: {
            table_mutex.lock();
            defer table_mutex.unlock();
            break :blk findReg(id) orelse return;
        };
        _ = win32.ResetEvent(slot.event.?);
        const rc = DnsServiceDeRegister(&slot.req, null);
        if (rc == request_pending) {
            if (win32.WaitForSingleObject(slot.event.?, mdns.answer_timeout_ms) != win32.WAIT_OBJECT_0)
                log.warn("unregister: no answer", .{});
        } else if (rc != 0) log.warn("unregister: DnsServiceDeRegister: {d}", .{rc});
        release(id);
    }

    pub fn browse(service_type: []const u8, handler: mdns.Handler, ctx: ?*anyopaque) mdns.Error!mdns.Browser {
        const slot, const id = blk: {
            table_mutex.lock();
            defer table_mutex.unlock();
            for (&browsers) |*s| if (s.id == 0) {
                const id = newId();
                s.* = .{ .id = id, .handler = handler, .ctx = ctx, .type_len = @intCast(service_type.len) };
                @memcpy(s.type_buf[0..service_type.len], service_type);
                const n = std.unicode.utf8ToUtf16Le(&s.query, service_type) catch unreachable; // validated ASCII
                for (".local", n..) |c, i| s.query[i] = c;
                s.query[n + 6] = 0;
                s.req = .{ .QueryName = &s.query, .pBrowseCallback = onBrowse, .pQueryContext = idCtx(id) };
                break :blk .{ s, id };
            };
            return error.TooMany;
        };
        const rc = DnsServiceBrowse(&slot.req, &slot.cancel);
        if (rc != request_pending) {
            log.err("browse {s}: DnsServiceBrowse: {d}", .{ service_type, rc });
            table_mutex.lock();
            slot.* = .{};
            table_mutex.unlock();
            return error.Failed;
        }
        return .{ .id = id };
    }

    pub fn stopBrowse(id: u32) void {
        var resolves: std.ArrayList(*Resolve) = .empty;
        var found: std.StringHashMapUnmanaged(Known) = .empty;
        var cancel: Cancel = .{};
        {
            table_mutex.lock();
            defer table_mutex.unlock();
            const s = findBrowser(id) orelse return;
            resolves = s.resolves;
            found = s.found;
            cancel = s.cancel;
            // The request memory stays in the slot (late callbacks find no id).
            s.id = 0;
            s.handler = null;
            s.resolves = .empty;
            s.found = .empty;
        }
        _ = DnsServiceBrowseCancel(&cancel);
        // Each resolve's callback frees it (with a cancelled status).
        for (resolves.items) |r| _ = DnsServiceResolveCancel(&r.cancel);
        resolves.deinit(gpa);
        // Wait out a handler running on another thread; deliver re-checks
        // the browser under call_mutex, so none starts after this.
        if (handler_tid.load(.acquire) != GetCurrentThreadId()) {
            call_mutex.lock();
            call_mutex.unlock();
        }
        freeFound(&found);
    }
};

fn release(id: u32) void {
    table_mutex.lock();
    defer table_mutex.unlock();
    const s = findReg(id) orelse return;
    if (s.req.pServiceInstance) |i| DnsServiceFreeInstance(i);
    if (s.event) |e| _ = win32.CloseHandle(e);
    s.* = .{};
}

/// What was reported for a name: every address any interface's resolve
/// gave (Windows answers one interface per resolve), and a hash of the
/// last `found` (an update repeats it, an identical answer doesn't).
const Known = struct {
    sig: u64 = 0,
    addresses: std.ArrayList([]u8) = .empty,

    fn deinit(k: *Known) void {
        for (k.addresses.items) |a| gpa.free(a);
        k.addresses.deinit(gpa);
    }

    /// Adds the addresses it doesn't have yet.
    fn merge(k: *Known, addresses: []const []const u8) !void {
        outer: for (addresses) |a| {
            for (k.addresses.items) |have| if (std.mem.eql(u8, have, a)) continue :outer;
            const copy = try gpa.dupe(u8, a);
            k.addresses.append(gpa, copy) catch |e| {
                gpa.free(copy);
                return e;
            };
        }
    }
};

fn freeFound(found: *std.StringHashMapUnmanaged(Known)) void {
    var it = found.iterator();
    while (it.next()) |e| {
        gpa.free(e.key_ptr.*);
        e.value_ptr.deinit();
    }
    found.deinit(gpa);
}

// -------------------------------------------------------------- callbacks

/// Registration and deregistration complete (DNS client thread).
fn onRegistered(status: DWORD, ctx: ?*anyopaque, instance: ?*ServiceInstance) callconv(.winapi) void {
    defer if (instance) |i| DnsServiceFreeInstance(i);
    table_mutex.lock();
    defer table_mutex.unlock();
    const s = findReg(ctxId(ctx)) orelse return;
    s.status = status;
    if (instance) |i| if (i.pszInstanceName) |n| {
        var buf: [256]u8 = undefined;
        const full = utf8Into(&buf, std.mem.span(n));
        const label = instanceLabel(full, "");
        const len = @min(label.len, s.name_buf.len);
        @memcpy(s.name_buf[0..len], label[0..len]);
        s.name_len = @intCast(len);
    };
    if (s.event) |e| _ = win32.SetEvent(e);
}

/// Records from a browse: a PTR per instance; TTL 0 means it left.
fn onBrowse(status: DWORD, ctx: ?*anyopaque, records: ?*Record) callconv(.winapi) void {
    defer if (records) |r| DnsRecordListFree(r, free_record_list);
    const id = ctxId(ctx);
    if (status != 0) {
        if (status != 1223) log.warn("browse: status {d}", .{status}); // ERROR_CANCELLED
        return;
    }
    var rec = records;
    while (rec) |r| : (rec = r.pNext) {
        if (r.wType != type_ptr) continue;
        const target = r.ptr_name_host orelse continue;
        if (r.dwTtl == 0) {
            lost(id, std.mem.span(target));
        } else {
            startResolve(id, std.mem.span(target));
        }
    }
}

fn startResolve(browser: u32, name_w: []const WCHAR) void {
    const r = gpa.create(Resolve) catch return;
    r.* = .{ .browser = browser, .name = gpa.dupeZ(WCHAR, name_w) catch {
        gpa.destroy(r);
        return;
    } };
    r.req = .{ .QueryName = r.name.ptr, .pResolveCompletionCallback = onResolved, .pQueryContext = r };
    {
        table_mutex.lock();
        defer table_mutex.unlock();
        const s = findBrowser(browser) orelse return freeResolve(r);
        s.resolves.append(gpa, r) catch return freeResolve(r);
    }
    const rc = DnsServiceResolve(&r.req, &r.cancel);
    if (rc != request_pending) {
        log.warn("resolve: DnsServiceResolve: {d}", .{rc});
        forgetResolve(r);
        freeResolve(r);
    }
}

fn forgetResolve(r: *Resolve) void {
    table_mutex.lock();
    defer table_mutex.unlock();
    const s = findBrowser(r.browser) orelse return;
    for (s.resolves.items, 0..) |x, i| if (x == r) {
        _ = s.resolves.swapRemove(i);
        return;
    };
}

fn freeResolve(r: *Resolve) void {
    gpa.free(r.name);
    gpa.destroy(r);
}

/// A resolve finished (DNS client thread): the `found` event.
fn onResolved(status: DWORD, ctx: ?*anyopaque, instance: ?*ServiceInstance) callconv(.winapi) void {
    const r: *Resolve = @ptrCast(@alignCast(ctx.?));
    defer {
        if (instance) |i| DnsServiceFreeInstance(i);
        freeResolve(r);
    }
    forgetResolve(r);
    if (status != 0) {
        if (status != 1223) log.warn("resolve: status {d}", .{status});
        return;
    }
    const i = instance orelse return;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const found = buildFound(arena, i) catch return;
    deliverFound(r.browser, found);
}

fn buildFound(arena: std.mem.Allocator, i: *const ServiceInstance) !mdns.Found {
    const full = if (i.pszInstanceName) |n| try std.unicode.utf16LeToUtf8Alloc(arena, std.mem.span(n)) else "";
    var addresses: std.ArrayList([]const u8) = .empty;
    if (i.ip4Address) |a| try addresses.append(arena, try formatIp4(arena, a.*));
    if (i.ip6Address) |a| try addresses.append(arena, try formatIp6(arena, a.*, i.dwInterfaceIndex));
    const txt = try arena.alloc(mdns.Txt, i.dwPropertyCount);
    var n: usize = 0;
    for (0..i.dwPropertyCount) |k| {
        const key = (i.keys orelse break)[k] orelse continue;
        const value = (i.values orelse break)[k];
        txt[n] = .{
            .key = try std.unicode.utf16LeToUtf8Alloc(arena, std.mem.span(key)),
            .value = if (value) |v| try std.unicode.utf16LeToUtf8Alloc(arena, std.mem.span(v)) else "",
        };
        n += 1;
    }
    const host = if (i.pszHostName) |h| std.mem.trimEnd(u8, try std.unicode.utf16LeToUtf8Alloc(arena, std.mem.span(h)), ".") else null;
    return .{
        .name = full, // the label is cut in deliverFound, which knows the type
        .type = "",
        .host = host,
        .addresses = addresses.items,
        .port = i.wPort,
        .txt = txt[0..n],
    };
}

fn deliverFound(browser: u32, found_full: mdns.Found) void {
    call_mutex.lock();
    defer call_mutex.unlock();
    var type_buf: [32]u8 = undefined;
    const handler, const ctx, const service_type, const slot = blk: {
        table_mutex.lock();
        defer table_mutex.unlock();
        const s = findBrowser(browser) orelse return; // stopped
        @memcpy(type_buf[0..s.type_len], s.serviceType());
        break :blk .{ s.handler.?, s.ctx, type_buf[0..s.type_len], s };
    };
    var f = found_full;
    f.type = service_type;
    f.name = instanceLabel(f.name, service_type);
    const known = blk: {
        if (slot.found.getPtr(f.name)) |k| break :blk k;
        const key = gpa.dupe(u8, f.name) catch return;
        const gop = slot.found.getOrPut(gpa, key) catch {
            gpa.free(key);
            return;
        };
        gop.value_ptr.* = .{};
        break :blk gop.value_ptr;
    };
    // The addresses of every interface so far; an identical answer (a
    // re-announcement, another interface's known address) isn't news.
    known.merge(f.addresses) catch return;
    f.addresses = @ptrCast(known.addresses.items);
    const sig = signature(f);
    if (sig == known.sig) return;
    known.sig = sig;
    const event: mdns.Event = .{ .found = f };
    call(handler, ctx, &event);
}

fn lost(browser: u32, name_w: []const WCHAR) void {
    var buf: [512]u8 = undefined;
    const full = utf8Into(&buf, name_w);
    call_mutex.lock();
    defer call_mutex.unlock();
    var type_buf: [32]u8 = undefined;
    const handler, const ctx, const service_type, const slot = blk: {
        table_mutex.lock();
        defer table_mutex.unlock();
        const s = findBrowser(browser) orelse return;
        @memcpy(type_buf[0..s.type_len], s.serviceType());
        break :blk .{ s.handler.?, s.ctx, type_buf[0..s.type_len], s };
    };
    const name = instanceLabel(full, service_type);
    // Only a name that was `found`.
    const kv = slot.found.fetchRemove(name) orelse return;
    defer gpa.free(kv.key);
    var known = kv.value;
    defer known.deinit();
    const event: mdns.Event = .{ .lost = .{ .name = name, .type = service_type } };
    call(handler, ctx, &event);
}

fn call(handler: mdns.Handler, ctx: ?*anyopaque, event: *const mdns.Event) void {
    handler_tid.store(GetCurrentThreadId(), .release);
    defer handler_tid.store(0, .release);
    handler(ctx, event);
}

// ---------------------------------------------------------------- helpers

/// "Name._type._tcp.local" as UTF-16 (arena).
fn fullName(arena: std.mem.Allocator, name: []const u8, service_type: []const u8) ![:0]WCHAR {
    const s = try std.fmt.allocPrint(arena, "{s}.{s}.local", .{ name, service_type });
    return wide(arena, s);
}

fn wide(arena: std.mem.Allocator, s: []const u8) ![:0]WCHAR {
    return std.unicode.utf8ToUtf16LeAllocZ(arena, s) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidName,
    };
}

/// This machine's mDNS host name, "<computer>.local" (UTF-16, arena).
fn localHost(arena: std.mem.Allocator) ![:0]WCHAR {
    var buf: [256]WCHAR = undefined;
    var len: DWORD = buf.len;
    if (GetComputerNameExW(1, &buf, &len) == 0) return error.Failed; // ComputerNameDnsHostname
    const name = try std.unicode.utf16LeToUtf8Alloc(arena, buf[0..len]);
    return wide(arena, try std.fmt.allocPrint(arena, "{s}.local", .{name}));
}

/// UTF-16 to UTF-8 into `buf` (truncated; unpaired surrogates replaced).
fn utf8Into(buf: []u8, w: []const WCHAR) []const u8 {
    var n: usize = 0;
    var it = std.unicode.Utf16LeIterator.init(w);
    while (true) {
        const cp = (it.nextCodepoint() catch 0xFFFD) orelse break;
        var tmp: [4]u8 = undefined;
        const k = std.unicode.utf8Encode(cp, &tmp) catch continue;
        if (n + k > buf.len) break;
        @memcpy(buf[n..][0..k], tmp[0..k]);
        n += k;
    }
    return buf[0..n];
}

/// The instance label of "Label._type._tcp.local[.]": everything before
/// the service type (with an empty `service_type`: before the last three
/// labels). Windows hands the label unescaped.
pub fn instanceLabel(full: []const u8, service_type: []const u8) []const u8 {
    const name = std.mem.trimEnd(u8, full, ".");
    if (service_type.len > 0) {
        // ".<type>.local", case-insensitively.
        if (name.len > service_type.len + 7) {
            const tail = name[name.len - service_type.len - 7 ..];
            if (tail[0] == '.' and std.ascii.eqlIgnoreCase(tail[1 .. 1 + service_type.len], service_type) and
                std.ascii.eqlIgnoreCase(tail[1 + service_type.len ..], ".local"))
                return name[0 .. name.len - tail.len];
        }
        return name;
    }
    var end = name.len;
    var dots: usize = 0;
    while (end > 0) : (end -= 1) {
        if (name[end - 1] == '.') {
            dots += 1;
            if (dots == 3) return name[0 .. end - 1];
        }
    }
    return name;
}

fn signature(f: mdns.Found) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.asBytes(&f.port));
    for (f.addresses) |a| {
        h.update(a);
        h.update("\x00");
    }
    for (f.txt) |t| {
        h.update(t.key);
        h.update("=");
        h.update(t.value);
        h.update("\x00");
    }
    if (f.host) |x| h.update(x);
    return h.final();
}

fn formatIp4(arena: std.mem.Allocator, a: u32) ![]const u8 {
    const b = std.mem.asBytes(&a); // network order in memory
    return std.fmt.allocPrint(arena, "{d}.{d}.{d}.{d}", .{ b[0], b[1], b[2], b[3] });
}

/// RFC 5952 text; a link-local address gets "%<interface index>".
pub fn formatIp6(arena: std.mem.Allocator, a: [16]u8, scope: u32) ![]const u8 {
    var words: [8]u16 = undefined;
    for (&words, 0..) |*w, i| w.* = std.mem.readInt(u16, a[i * 2 ..][0..2], .big);
    // The longest run of two or more zero words becomes "::".
    var best_at: usize = 8;
    var best_len: usize = 1;
    var i: usize = 0;
    while (i < 8) {
        if (words[i] != 0) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < 8 and words[j] == 0) j += 1;
        if (j - i > best_len) {
            best_at = i;
            best_len = j - i;
        }
        i = j;
    }
    var out: std.ArrayList(u8) = .empty;
    i = 0;
    while (i < 8) {
        if (i == best_at) {
            try out.appendSlice(arena, "::");
            i += best_len;
            continue;
        }
        if (i > 0 and i != best_at + best_len) try out.append(arena, ':');
        try out.print(arena, "{x}", .{words[i]});
        i += 1;
    }
    const link_local = a[0] == 0xfe and (a[1] & 0xc0) == 0x80;
    if (link_local and scope != 0) try out.print(arena, "%{d}", .{scope});
    return out.items;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test instanceLabel {
    try testing.expectEqualStrings("I0FCQ0QAAAAAAA", instanceLabel("I0FCQ0QAAAAAAA._FC9F5ED42C8A._tcp.local", "_FC9F5ED42C8A._tcp"));
    try testing.expectEqualStrings("Oriel mDNS test", instanceLabel("Oriel mDNS test._oriel._TCP.LOCAL.", "_oriel._tcp"));
    try testing.expectEqualStrings("a.b", instanceLabel("a.b._x._udp.local", "_x._udp"));
    try testing.expectEqualStrings("a.b", instanceLabel("a.b._x._udp.local", ""));
    try testing.expectEqualStrings("odd", instanceLabel("odd", "_x._tcp"));
}

test formatIp6 {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("fe80::1%12", try formatIp6(a, .{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 12));
    try testing.expectEqualStrings("2001:db8::8:800:200c:417a", try formatIp6(a, .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 8, 8, 0, 0x20, 0x0c, 0x41, 0x7a }, 3));
    try testing.expectEqualStrings("::", try formatIp6(a, @splat(0), 0));
    try testing.expectEqualStrings("2001:db8:0:1:1:1:1:1", try formatIp6(a, .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1 }, 0));
    try testing.expectEqualStrings("1::", try formatIp6(a, .{ 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, 0));
}

test formatIp4 {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const be: u32 = std.mem.bigToNative(u32, 0xC0A80114);
    try testing.expectEqualStrings("192.168.1.20", try formatIp4(arena.allocator(), be));
}

test "windns.h layouts" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    // DNS_RECORDW: the data union right after the 32-byte header.
    try testing.expectEqual(@as(usize, 32), @offsetOf(Record, "ptr_name_host"));
    // DNS_SERVICE_INSTANCE: four pointers, three WORDs, a DWORD, two pointers, a DWORD.
    try testing.expectEqual(@as(usize, 32), @offsetOf(ServiceInstance, "wPort"));
    try testing.expectEqual(@as(usize, 40), @offsetOf(ServiceInstance, "dwPropertyCount"));
    try testing.expectEqual(@as(usize, 48), @offsetOf(ServiceInstance, "keys"));
    try testing.expectEqual(@as(usize, 64), @offsetOf(ServiceInstance, "dwInterfaceIndex"));
    try testing.expectEqual(@as(usize, 48), @sizeOf(RegisterRequest));
    try testing.expectEqual(@as(usize, 32), @sizeOf(BrowseRequest));
    try testing.expectEqual(@as(usize, 32), @sizeOf(ResolveRequest));
}
