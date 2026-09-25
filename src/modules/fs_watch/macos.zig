//! File-system watching on macOS: FSEvents with per-file events.
//!
//! The stream runs on a private serial dispatch queue; its callback queues
//! events under a mutex and `poll` drains them without blocking, like the
//! non-blocking inotify fd on Linux. FSEvents watches whole subtrees, so
//! only events for direct children of a watched directory are reported
//! (inotify semantics). Paths from FSEvents are canonical (`/private/var/…`
//! for `/var/…`), so watched directories are compared by their realpath.
//! FSEvents batches events for `latency` (50 ms) before delivering them.

const std = @import("std");
const oriel = @import("../../oriel.zig");
pub const common = @import("common.zig");

pub const buffer_align = common.buffer_align;
pub const Event = common.Event;

const c = std.c;
const gpa = std.heap.smp_allocator;

// --- CoreServices / CoreFoundation (C API) ---------------------------------

const CFIndex = isize;
const FSEventStreamRef = *opaque {};
const FSEventStreamEventFlags = u32;
const FSEventStreamEventId = u64;
const FSEventStreamContext = extern struct {
    version: CFIndex = 0,
    info: ?*anyopaque,
    retain: ?*const anyopaque = null,
    release: ?*const anyopaque = null,
    copyDescription: ?*const anyopaque = null,
};
const FSEventStreamCallback = *const fn (
    stream: FSEventStreamRef,
    info: ?*anyopaque,
    num_events: usize,
    paths: *anyopaque, // char** (no kFSEventStreamCreateFlagUseCFTypes)
    flags: [*]const FSEventStreamEventFlags,
    ids: [*]const FSEventStreamEventId,
) callconv(.c) void;

extern "c" fn CFStringCreateWithBytes(alloc: ?*anyopaque, bytes: [*]const u8, len: CFIndex, encoding: u32, is_external: u8) ?*anyopaque;
extern "c" fn CFArrayCreate(alloc: ?*anyopaque, values: [*]const ?*anyopaque, count: CFIndex, callbacks: ?*const anyopaque) ?*anyopaque;
extern "c" fn CFRelease(obj: *anyopaque) void;
extern const kCFTypeArrayCallBacks: u8;
extern "c" fn FSEventStreamCreate(alloc: ?*anyopaque, cb: FSEventStreamCallback, ctx: *FSEventStreamContext, paths: *anyopaque, since: FSEventStreamEventId, latency: f64, flags: u32) ?FSEventStreamRef;
extern "c" fn FSEventStreamSetDispatchQueue(stream: FSEventStreamRef, queue: ?*anyopaque) void;
extern "c" fn FSEventStreamStart(stream: FSEventStreamRef) u8;
extern "c" fn FSEventStreamStop(stream: FSEventStreamRef) void;
extern "c" fn FSEventStreamInvalidate(stream: FSEventStreamRef) void;
extern "c" fn FSEventStreamRelease(stream: FSEventStreamRef) void;
extern "c" fn dispatch_queue_create(label: [*:0]const u8, attr: ?*anyopaque) ?*anyopaque;
extern "c" fn dispatch_release(obj: *anyopaque) void;

const kCFStringEncodingUTF8: u32 = 0x08000100;
const kFSEventStreamEventIdSinceNow: FSEventStreamEventId = 0xFFFFFFFFFFFFFFFF;
const kFSEventStreamCreateFlagNoDefer: u32 = 0x02;
const kFSEventStreamCreateFlagFileEvents: u32 = 0x10;
const flag_created: u32 = 0x100;
const flag_removed: u32 = 0x200;
const flag_renamed: u32 = 0x800;
const flag_modified: u32 = 0x1000;
const latency_s = 0.05;

// ---------------------------------------------------------------------------

extern "c" fn dispatch_sync_f(queue: *anyopaque, ctx: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;

fn noop(_: ?*anyopaque) callconv(.c) void {}

const Pending = struct { kind: Event.Kind, name: []u8 };

const State = struct {
    mutex: c.pthread_mutex_t = .{},
    /// Canonical paths of the watched directories (owned).
    dirs: std.ArrayList([]u8) = .empty,
    /// Events not yet returned by `poll` (names owned). Guarded by `mutex`.
    pending: std.ArrayList(Pending) = .empty,
    queue: *anyopaque,
    stream: ?FSEventStreamRef = null,

    fn lock(self: *State) void {
        _ = c.pthread_mutex_lock(&self.mutex);
    }

    fn unlock(self: *State) void {
        _ = c.pthread_mutex_unlock(&self.mutex);
    }

    /// Stop and release the stream; after this no callback runs.
    fn stopStream(self: *State) void {
        const s = self.stream orelse return;
        FSEventStreamStop(s);
        FSEventStreamInvalidate(s);
        // A callback already running (or queued) on our serial queue ends
        // before this returns, so the caller may free the state after it.
        dispatch_sync_f(self.queue, null, &noop);
        FSEventStreamRelease(s);
        self.stream = null;
    }

    /// (Re)create the stream for every watched directory.
    fn startStream(self: *State) !void {
        self.stopStream();
        var strings: std.ArrayList(?*anyopaque) = .empty;
        defer {
            for (strings.items) |str| CFRelease(str.?);
            strings.deinit(gpa);
        }
        for (self.dirs.items) |d| {
            const str = CFStringCreateWithBytes(null, d.ptr, @intCast(d.len), kCFStringEncodingUTF8, 0) orelse return error.OutOfMemory;
            strings.append(gpa, str) catch |err| {
                CFRelease(str);
                return err;
            };
        }
        const array = CFArrayCreate(null, strings.items.ptr, @intCast(strings.items.len), @ptrCast(&kCFTypeArrayCallBacks)) orelse return error.OutOfMemory;
        defer CFRelease(array);
        var ctx: FSEventStreamContext = .{ .info = self }; // copied by FSEventStreamCreate
        const stream = FSEventStreamCreate(null, &onEvents, &ctx, array, kFSEventStreamEventIdSinceNow, latency_s, kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer) orelse return error.FSEventStreamCreate;
        FSEventStreamSetDispatchQueue(stream, self.queue);
        if (FSEventStreamStart(stream) == 0) {
            FSEventStreamInvalidate(stream);
            FSEventStreamRelease(stream);
            return error.FSEventStreamStart;
        }
        self.stream = stream;
    }
};

/// On the stream's dispatch queue.
fn onEvents(_: FSEventStreamRef, info: ?*anyopaque, num: usize, paths_raw: *anyopaque, flags: [*]const FSEventStreamEventFlags, _: [*]const FSEventStreamEventId) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(info.?));
    const paths: [*]const [*:0]const u8 = @ptrCast(@alignCast(paths_raw));
    state.lock();
    defer state.unlock();
    for (0..num) |i| {
        const path = std.mem.span(paths[i]);
        const parent = std.fs.path.dirname(path) orelse continue;
        const watched = for (state.dirs.items) |d| {
            if (std.mem.eql(u8, d, parent)) break true;
        } else false;
        if (!watched) continue;
        const kind = classify(flags[i], exists(paths[i]));
        const name = gpa.dupe(u8, std.fs.path.basename(path)) catch continue; // dropped under memory pressure
        state.pending.append(gpa, .{ .kind = kind, .name = name }) catch gpa.free(name);
    }
}

fn exists(path: [*:0]const u8) bool {
    return c.access(path, 0) == 0; // F_OK
}

/// FSEvents coalesces flags for a path within one batch; decide by what the
/// file is now.
fn classify(flags: u32, now_exists: bool) Event.Kind {
    if (!now_exists and flags & (flag_removed | flag_renamed) != 0) return .deleted;
    if (now_exists and flags & (flag_created | flag_renamed) != 0) return .created;
    if (now_exists and flags & flag_modified != 0) return .modified;
    return .other;
}

pub const Watcher = struct {
    state: *State,

    pub fn init() !Watcher {
        const state = try gpa.create(State);
        errdefer gpa.destroy(state);
        state.* = .{ .queue = dispatch_queue_create("dev.oriel.fs_watch", null) orelse return error.DispatchQueueCreate };
        return .{ .state = state };
    }

    pub fn deinit(self: Watcher) void {
        const s = self.state;
        s.stopStream();
        dispatch_release(s.queue);
        for (s.dirs.items) |d| gpa.free(d);
        s.dirs.deinit(gpa);
        for (s.pending.items) |p| gpa.free(p.name);
        s.pending.deinit(gpa);
        _ = c.pthread_mutex_destroy(&s.mutex);
        gpa.destroy(s);
    }

    /// Watch the direct children of the directory `path`.
    pub fn add(self: Watcher, path: [:0]const u8) !void {
        var real_buf: [std.fs.max_path_bytes]u8 = undefined;
        const real = c.realpath(path.ptr, &real_buf) orelse return error.WatchPathNotFound;
        const canonical = try gpa.dupe(u8, std.mem.span(real));
        errdefer gpa.free(canonical);
        const s = self.state;
        s.lock();
        s.dirs.append(gpa, canonical) catch |err| {
            s.unlock();
            return err;
        };
        s.unlock();
        // The callback never runs while the stream is being replaced.
        try s.startStream();
    }

    /// Return pending events without blocking. Names point into `buf`;
    /// events whose name doesn't fit wait for the next call (a name longer
    /// than all of `buf` is dropped, so it can't block the rest).
    pub fn poll(self: Watcher, buf: []align(buffer_align) u8, out: []Event) !usize {
        const s = self.state;
        s.lock();
        defer s.unlock();
        var n: usize = 0;
        var used: usize = 0;
        var taken: usize = 0;
        for (s.pending.items) |p| {
            if (p.name.len > buf.len) {
                taken += 1;
                gpa.free(p.name);
                continue;
            }
            if (n == out.len or used + p.name.len > buf.len) break;
            @memcpy(buf[used..][0..p.name.len], p.name);
            out[n] = .{ .kind = p.kind, .name = buf[used..][0..p.name.len] };
            used += p.name.len;
            n += 1;
            taken += 1;
            gpa.free(p.name);
        }
        s.pending.replaceRangeAssumeCapacity(0, taken, &.{});
        return n;
    }
};

pub fn check(gpa_check: std.mem.Allocator, ctx: oriel.CheckContext) !oriel.Check {
    var dir_buf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrintZ(&dir_buf, "/tmp/oriel-fswatch-{d}", .{c.getpid()});
    _ = c.mkdir(dir.ptr, 0o700);
    defer _ = c.rmdir(dir.ptr);

    const watcher = try Watcher.init();
    defer watcher.deinit();
    try watcher.add(dir);

    var file_buf: [96]u8 = undefined;
    const file = try std.fmt.bufPrintZ(&file_buf, "{s}/hello.txt", .{dir});
    const fd = c.open(file.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.CreateTestFile;
    _ = c.close(fd);
    defer _ = c.unlink(file.ptr);

    // FSEvents delivers after its latency: wait up to 2 s.
    var buf: [4096]u8 align(buffer_align) = undefined;
    var events: [8]Event = undefined;
    var n: usize = 0;
    var waited: u32 = 0;
    while (n == 0 and waited < 2000) : (waited += 20) {
        try ctx.io.sleep(.fromMilliseconds(20), .awake);
        n = try watcher.poll(&buf, &events);
    }
    const seen = n > 0 and events[0].kind == .created and std.mem.eql(u8, events[0].name, "hello.txt");
    return .{
        .module = "fs_watch",
        .ok = seen,
        .detail = try std.fmt.allocPrint(gpa_check, "FSEvents: {d} event(s) after {d} ms, first = {s} {s}", .{
            n,
            waited,
            if (n > 0) @tagName(events[0].kind) else "-",
            if (n > 0) events[0].name else "-",
        }),
    };
}

test classify {
    try std.testing.expectEqual(Event.Kind.created, classify(flag_created | flag_modified, true));
    try std.testing.expectEqual(Event.Kind.modified, classify(flag_modified, true));
    try std.testing.expectEqual(Event.Kind.deleted, classify(flag_created | flag_removed, false));
    try std.testing.expectEqual(Event.Kind.deleted, classify(flag_renamed, false));
}

test "Watcher reports created, modified and deleted children only" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "w/sub");
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/w", .{path_buf[0..len]}, 0);
    defer std.testing.allocator.free(dir);

    const watcher = try Watcher.init();
    defer watcher.deinit();
    try watcher.add(dir);
    try io.sleep(.fromMilliseconds(200), .awake); // let the stream start

    try tmp.dir.writeFile(io, .{ .sub_path = "w/a.txt", .data = "1" });
    try tmp.dir.writeFile(io, .{ .sub_path = "w/sub/deep.txt", .data = "x" }); // not a direct child

    var buf: [4096]u8 align(buffer_align) = undefined;
    var events: [16]Event = undefined;
    var seen_created = false;
    var waited: u32 = 0;
    while (!seen_created and waited < 3000) : (waited += 20) {
        try io.sleep(.fromMilliseconds(20), .awake);
        const n = try watcher.poll(&buf, &events);
        for (events[0..n]) |e| {
            try std.testing.expect(!std.mem.eql(u8, e.name, "deep.txt"));
            if (e.kind == .created and std.mem.eql(u8, e.name, "a.txt")) seen_created = true;
        }
    }
    try std.testing.expect(seen_created);

    try tmp.dir.deleteFile(io, "w/a.txt");
    var seen_deleted = false;
    waited = 0;
    while (!seen_deleted and waited < 3000) : (waited += 20) {
        try io.sleep(.fromMilliseconds(20), .awake);
        const n = try watcher.poll(&buf, &events);
        for (events[0..n]) |e| {
            if (e.kind == .deleted and std.mem.eql(u8, e.name, "a.txt")) seen_deleted = true;
        }
    }
    try std.testing.expect(seen_deleted);
}
