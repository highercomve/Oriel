//! macOS audio capture: CoreAudio devices + AudioQueue input.
//!
//! `listSources` returns every device with input channels: `name` is its
//! CoreAudio UID, `description` its display name. macOS has no built-in
//! way to capture what the speakers play; a virtual loopback device
//! (BlackHole, Soundflower, Rogue Amoeba Loopback) does, and is listed with
//! `monitor = true` when installed (route the output to it, e.g. with a
//! Multi-Output Device in Audio MIDI Setup).
//!
//! `Stream` asks AudioQueue for mono float32 at the requested rate (it
//! resamples); its callback fills a ring buffer that `read` drains,
//! blocking until the caller's buffer is full, like the Linux backend.
//!
//! Microphone permission: a denied app just records silence, so `open`
//! checks the authorization first and fails with
//! error.MicrophonePermissionDenied. When not yet decided, the first
//! `open` makes macOS show its permission prompt (for an unbundled
//! executable, it asks on behalf of the terminal that started it).

const std = @import("std");
const cocoa = @import("../../platform/macos/cocoa.zig");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");

const Object = cocoa.Object;
const c = std.c;
const log = std.log.scoped(.oriel);

// --- CoreAudio / AudioToolbox / CoreFoundation -----------------------------------------

const OSStatus = i32;
const AudioObjectID = u32;
const CFStringRef = *opaque {};
const AudioObjectPropertyAddress = extern struct { selector: u32, scope: u32, element: u32 };
const AudioBuffer = extern struct { channels: u32, bytes: u32, data: ?*anyopaque };
const AudioBufferListHead = extern struct { count: u32, first: AudioBuffer }; // followed by count-1 more
const AudioStreamBasicDescription = extern struct {
    sample_rate: f64,
    format_id: u32,
    format_flags: u32,
    bytes_per_packet: u32,
    frames_per_packet: u32,
    bytes_per_frame: u32,
    channels_per_frame: u32,
    bits_per_channel: u32,
    reserved: u32 = 0,
};
const AudioQueueRef = *opaque {};
const AudioQueueBuffer = extern struct {
    capacity: u32,
    data: *anyopaque,
    byte_size: u32,
    user_data: ?*anyopaque,
    packet_desc_capacity: u32,
    packet_descs: ?*anyopaque,
    packet_desc_count: u32,
};
const InputCallback = *const fn (user: ?*anyopaque, queue: AudioQueueRef, buffer: *AudioQueueBuffer, start: *const anyopaque, packets: u32, descs: ?*const anyopaque) callconv(.c) void;

extern "c" fn AudioObjectGetPropertyDataSize(id: AudioObjectID, addr: *const AudioObjectPropertyAddress, qual_size: u32, qual: ?*const anyopaque, size: *u32) OSStatus;
extern "c" fn AudioObjectGetPropertyData(id: AudioObjectID, addr: *const AudioObjectPropertyAddress, qual_size: u32, qual: ?*const anyopaque, size: *u32, data: *anyopaque) OSStatus;
extern "c" fn AudioQueueNewInput(format: *const AudioStreamBasicDescription, cb: InputCallback, user: ?*anyopaque, run_loop: ?*anyopaque, mode: ?*anyopaque, flags: u32, out: *?AudioQueueRef) OSStatus;
extern "c" fn AudioQueueAllocateBuffer(queue: AudioQueueRef, size: u32, out: *?*AudioQueueBuffer) OSStatus;
extern "c" fn AudioQueueEnqueueBuffer(queue: AudioQueueRef, buffer: *AudioQueueBuffer, n: u32, descs: ?*const anyopaque) OSStatus;
extern "c" fn AudioQueueSetProperty(queue: AudioQueueRef, id: u32, data: *const anyopaque, size: u32) OSStatus;
extern "c" fn AudioQueueStart(queue: AudioQueueRef, start: ?*const anyopaque) OSStatus;
extern "c" fn AudioQueueStop(queue: AudioQueueRef, immediate: u8) OSStatus;
extern "c" fn AudioQueueDispose(queue: AudioQueueRef, immediate: u8) OSStatus;
extern "c" fn CFStringCreateWithBytes(alloc: ?*anyopaque, bytes: [*]const u8, len: isize, encoding: u32, external: u8) ?CFStringRef;
extern "c" fn CFStringGetCString(str: CFStringRef, buf: [*]u8, size: isize, encoding: u32) u8;
extern "c" fn CFRelease(obj: *anyopaque) void;
extern var AVMediaTypeAudio: cocoa.id;

fn fourCC(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .big);
}

const kAudioObjectSystemObject: AudioObjectID = 1;
const sel_devices = fourCC("dev#");
const sel_stream_config = fourCC("slay");
const sel_name = fourCC("lnam");
const sel_uid = fourCC("uid ");
const sel_default_input = fourCC("dIn ");
const scope_global = fourCC("glob");
const scope_input = fourCC("inpt");
const kAudioFormatLinearPCM = fourCC("lpcm");
const kAudioFormatFlagIsFloat: u32 = 1 << 0;
const kAudioFormatFlagIsPacked: u32 = 1 << 3;
const kAudioQueueProperty_CurrentDevice = fourCC("aqcd");
const kCFStringEncodingUTF8: u32 = 0x08000100;

fn property(selector: u32, scope: u32) AudioObjectPropertyAddress {
    return .{ .selector = selector, .scope = scope, .element = 0 };
}

/// A CFString property as UTF-8 (caller frees), or null.
fn stringProperty(gpa: std.mem.Allocator, id: AudioObjectID, selector: u32) !?[:0]u8 {
    var str: ?CFStringRef = null;
    var size: u32 = @sizeOf(?CFStringRef);
    const addr = property(selector, scope_global);
    if (AudioObjectGetPropertyData(id, &addr, 0, null, &size, @ptrCast(&str)) != 0) return null;
    const s = str orelse return null;
    defer CFRelease(s);
    var buf: [512]u8 = undefined;
    if (CFStringGetCString(s, &buf, buf.len, kCFStringEncodingUTF8) == 0) return null;
    return try gpa.dupeZ(u8, std.mem.sliceTo(&buf, 0));
}

fn inputChannels(gpa: std.mem.Allocator, id: AudioObjectID) !u32 {
    const addr = property(sel_stream_config, scope_input);
    var size: u32 = 0;
    if (AudioObjectGetPropertyDataSize(id, &addr, 0, null, &size) != 0 or size < @sizeOf(AudioBufferListHead)) return 0;
    const raw = try gpa.alignedAlloc(u8, .of(AudioBufferListHead), size);
    defer gpa.free(raw);
    if (AudioObjectGetPropertyData(id, &addr, 0, null, &size, raw.ptr) != 0) return 0;
    const head: *const AudioBufferListHead = @ptrCast(raw.ptr);
    const buffers: [*]const AudioBuffer = @ptrCast(&head.first);
    const count = @min(head.count, (size - @offsetOf(AudioBufferListHead, "first")) / @sizeOf(AudioBuffer));
    var channels: u32 = 0;
    for (buffers[0..count]) |b| channels += b.channels;
    return channels;
}

/// Virtual loopback drivers that expose what the speakers play.
fn isLoopback(name: []const u8) bool {
    const known = [_][]const u8{ "BlackHole", "Soundflower", "Loopback" };
    for (known) |k| if (std.mem.indexOf(u8, name, k) != null) return true;
    return false;
}

/// Every input device. Free with `common.freeSources`.
pub fn listSources(gpa: std.mem.Allocator) ![]common.Source {
    const addr = property(sel_devices, scope_global);
    var size: u32 = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, null, &size) != 0) return error.CoreAudioFailed;
    const ids = try gpa.alloc(AudioObjectID, size / @sizeOf(AudioObjectID));
    defer gpa.free(ids);
    if (ids.len > 0 and AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, null, &size, ids.ptr) != 0) return error.CoreAudioFailed;

    var list: std.ArrayList(common.Source) = .empty;
    errdefer {
        for (list.items) |s| {
            gpa.free(s.name);
            gpa.free(s.description);
        }
        list.deinit(gpa);
    }
    for (ids[0 .. size / @sizeOf(AudioObjectID)]) |id| {
        if (try inputChannels(gpa, id) == 0) continue;
        const uid = try stringProperty(gpa, id, sel_uid) orelse continue;
        errdefer gpa.free(uid);
        const name = try stringProperty(gpa, id, sel_name) orelse try gpa.dupeZ(u8, uid);
        errdefer gpa.free(name);
        try list.append(gpa, .{ .name = uid, .description = name[0..name.len], .monitor = isLoopback(name) });
    }
    return list.toOwnedSlice(gpa);
}

fn hasDefaultInput() bool {
    var id: AudioObjectID = 0;
    var size: u32 = @sizeOf(AudioObjectID);
    const addr = property(sel_default_input, scope_global);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, null, &size, &id) != 0) return false;
    return id != 0; // kAudioObjectUnknown
}

// --- Permission -------------------------------------------------------------------------

pub const Permission = enum { not_determined, restricted, denied, authorized };

pub fn microphonePermission() Permission {
    const cls = cocoa.objc.getClass("AVCaptureDevice") orelse return .authorized;
    const status = cls.msgSend(isize, "authorizationStatusForMediaType:", .{Object{ .value = AVMediaTypeAudio }});
    return switch (status) {
        0 => .not_determined,
        1 => .restricted,
        2 => .denied,
        else => .authorized,
    };
}

// --- Stream -------------------------------------------------------------------------------

const buffer_count = 3;

/// Shared with the AudioQueue callback thread (heap, stable address).
const State = struct {
    mutex: c.pthread_mutex_t = .{},
    cond: c.pthread_cond_t = .{},
    ring: []f32,
    head: usize = 0, // next sample to read
    len: usize = 0, // samples available
    running: bool = true,

    fn push(self: *State, samples: []const f32) void {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        for (samples) |s| {
            if (self.len == self.ring.len) { // full: drop the oldest sample
                self.head = (self.head + 1) % self.ring.len;
                self.len -= 1;
            }
            self.ring[(self.head + self.len) % self.ring.len] = s;
            self.len += 1;
        }
        _ = c.pthread_cond_signal(&self.cond);
    }
};

fn onInput(user: ?*anyopaque, queue: AudioQueueRef, buffer: *AudioQueueBuffer, _: *const anyopaque, _: u32, _: ?*const anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(user.?));
    const samples: [*]const f32 = @ptrCast(@alignCast(buffer.data));
    state.push(samples[0 .. buffer.byte_size / @sizeOf(f32)]);
    _ = c.pthread_mutex_lock(&state.mutex);
    const running = state.running;
    _ = c.pthread_mutex_unlock(&state.mutex);
    if (running) _ = AudioQueueEnqueueBuffer(queue, buffer, 0, null);
}

/// A capture stream delivering mono f32 samples at the requested rate.
/// `read` blocks until the buffer is full; `read` and `close` must be
/// called from the same thread.
pub const Stream = struct {
    queue: AudioQueueRef,
    state: *State,

    /// Open `source` (a `Source.name`, i.e. a CoreAudio device UID; null =
    /// the default input). `app_name` is unused on macOS.
    pub fn open(source: ?[:0]const u8, app_name: [:0]const u8, rate: u32) !Stream {
        _ = app_name;
        if (source == null and !hasDefaultInput()) return error.NoInputDevice; // e.g. a VM without audio input
        switch (microphonePermission()) {
            .denied, .restricted => return error.MicrophonePermissionDenied,
            .not_determined, .authorized => {},
        }
        const gpa = std.heap.smp_allocator;
        const state = try gpa.create(State);
        errdefer gpa.destroy(state);
        state.* = .{ .ring = try gpa.alloc(f32, rate * 2) }; // 2 s of slack
        errdefer gpa.free(state.ring);

        const format: AudioStreamBasicDescription = .{
            .sample_rate = @floatFromInt(rate),
            .format_id = kAudioFormatLinearPCM,
            .format_flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            .bytes_per_packet = @sizeOf(f32),
            .frames_per_packet = 1,
            .bytes_per_frame = @sizeOf(f32),
            .channels_per_frame = 1,
            .bits_per_channel = 32,
        };
        var queue_opt: ?AudioQueueRef = null;
        if (AudioQueueNewInput(&format, &onInput, state, null, null, 0, &queue_opt) != 0) return error.OpenFailed;
        const queue = queue_opt orelse return error.OpenFailed;
        errdefer _ = AudioQueueDispose(queue, 1);

        if (source) |uid| {
            const str = CFStringCreateWithBytes(null, uid.ptr, @intCast(uid.len), kCFStringEncodingUTF8, 0) orelse return error.OutOfMemory;
            defer CFRelease(str);
            if (AudioQueueSetProperty(queue, kAudioQueueProperty_CurrentDevice, @ptrCast(&str), @sizeOf(CFStringRef)) != 0) {
                log.warn("cannot open input {s}", .{uid});
                return error.OpenFailed;
            }
        }
        // ~100 ms buffers, like the Linux fragments.
        const bytes: u32 = rate / 10 * @sizeOf(f32);
        for (0..buffer_count) |_| {
            var buf: ?*AudioQueueBuffer = null;
            if (AudioQueueAllocateBuffer(queue, bytes, &buf) != 0) return error.OpenFailed;
            _ = AudioQueueEnqueueBuffer(queue, buf.?, 0, null);
        }
        if (AudioQueueStart(queue, null) != 0) return error.OpenFailed;
        return .{ .queue = queue, .state = state };
    }

    /// Fill `samples` completely (blocks).
    pub fn read(self: *Stream, samples: []f32) !void {
        const st = self.state;
        var filled: usize = 0;
        _ = c.pthread_mutex_lock(&st.mutex);
        defer _ = c.pthread_mutex_unlock(&st.mutex);
        while (filled < samples.len) {
            while (st.len == 0) {
                if (!st.running) return error.ReadFailed;
                _ = c.pthread_cond_wait(&st.cond, &st.mutex);
            }
            const n = @min(st.len, samples.len - filled);
            for (0..n) |i| samples[filled + i] = st.ring[(st.head + i) % st.ring.len];
            st.head = (st.head + n) % st.ring.len;
            st.len -= n;
            filled += n;
        }
    }

    pub fn close(self: *Stream) void {
        _ = c.pthread_mutex_lock(&self.state.mutex);
        self.state.running = false;
        _ = c.pthread_cond_broadcast(&self.state.cond);
        _ = c.pthread_mutex_unlock(&self.state.mutex);
        // Synchronous: no callback runs after these return.
        _ = AudioQueueStop(self.queue, 1);
        _ = AudioQueueDispose(self.queue, 1);
        const gpa = std.heap.smp_allocator;
        gpa.free(self.state.ring);
        gpa.destroy(self.state);
    }
};

/// Lists the inputs and reports the microphone permission; opening a
/// stream would show the permission prompt, so the check doesn't.
pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    const sources = listSources(gpa) catch |err| return .{
        .module = "audio_capture",
        .ok = false,
        .detail = try std.fmt.allocPrint(gpa, "CoreAudio: {s}", .{@errorName(err)}),
    };
    defer common.freeSources(gpa, sources);
    var monitors: usize = 0;
    for (sources) |s| monitors += @intFromBool(s.monitor);
    return .{
        .module = "audio_capture",
        .ok = true,
        .detail = try std.fmt.allocPrint(gpa, "CoreAudio: {d} inputs, {d} system-audio (loopback) devices; microphone permission: {s}", .{
            sources.len - monitors,
            monitors,
            @tagName(microphonePermission()),
        }),
    };
}

test isLoopback {
    try std.testing.expect(isLoopback("BlackHole 2ch"));
    try std.testing.expect(!isLoopback("MacBook Pro Microphone"));
}

test "listSources returns owned, freeable sources" {
    const gpa = std.testing.allocator;
    const sources = try listSources(gpa);
    common.freeSources(gpa, sources);
}

test {
    std.testing.refAllDecls(@This());
}
