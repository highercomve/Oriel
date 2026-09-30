//! iOS audio capture: AVAudioSession + AudioQueue input, mono f32 at the
//! requested rate (AudioQueue resamples).
//!
//! `open` sets the app's audio session to play-and-record (mixing with
//! other apps, speaker and Bluetooth allowed) and activates it. Sources:
//! "default", then the session's available inputs (built-in microphone,
//! headset, Bluetooth), named by their port UID; opening one makes it the
//! preferred input. Other apps' audio can't be captured on iOS.
//!
//! Needs the microphone permission (`.permissions = .{ .microphone = "..." }`,
//! then `permissions.request(.microphone)`); a denied app records silence,
//! so `open` fails with error.MicrophonePermissionDenied. Capturing in the
//! background needs the `audio` background mode (`.ios = .{ .background_audio
//! = true }` in build.zig).

const std = @import("std");
const apple = @import("../../platform/ios/apple.zig");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");

const Object = apple.Object;
const c = std.c;
const log = std.log.scoped(.oriel);

// --- AudioToolbox -------------------------------------------------------------------

const OSStatus = i32;
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

extern "c" fn AudioQueueNewInput(format: *const AudioStreamBasicDescription, cb: InputCallback, user: ?*anyopaque, run_loop: ?*anyopaque, mode: ?*anyopaque, flags: u32, out: *?AudioQueueRef) OSStatus;
extern "c" fn AudioQueueAllocateBuffer(queue: AudioQueueRef, size: u32, out: *?*AudioQueueBuffer) OSStatus;
extern "c" fn AudioQueueEnqueueBuffer(queue: AudioQueueRef, buffer: *AudioQueueBuffer, n: u32, descs: ?*const anyopaque) OSStatus;
extern "c" fn AudioQueueStart(queue: AudioQueueRef, start: ?*const anyopaque) OSStatus;
extern "c" fn AudioQueueStop(queue: AudioQueueRef, immediate: u8) OSStatus;
extern "c" fn AudioQueueDispose(queue: AudioQueueRef, immediate: u8) OSStatus;

extern const AVMediaTypeAudio: apple.id;
extern const AVAudioSessionCategoryPlayAndRecord: apple.id;

const kAudioFormatLinearPCM: u32 = 0x6C70_636D; // 'lpcm'
const kAudioFormatFlagIsFloat: u32 = 1 << 0;
const kAudioFormatFlagIsPacked: u32 = 1 << 3;

// AVAudioSessionCategoryOptions
const option_mix_with_others: c_ulong = 0x1;
const option_allow_bluetooth: c_ulong = 0x4;
const option_default_to_speaker: c_ulong = 0x8;

fn session() Object {
    return apple.class("AVAudioSession").msgSend(Object, "sharedInstance", .{});
}

fn appendSource(gpa: std.mem.Allocator, list: *std.ArrayList(common.Source), name: []const u8, description: []const u8) !void {
    const n = try gpa.dupeZ(u8, name);
    errdefer gpa.free(n);
    const d = try gpa.dupe(u8, description);
    errdefer gpa.free(d);
    try list.append(gpa, .{ .name = n, .description = d, .monitor = false });
}

/// "default", then the session's inputs. Free with `freeSources`.
pub fn listSources(gpa: std.mem.Allocator) ![]common.Source {
    const pool = apple.objc.AutoreleasePool.init();
    defer pool.deinit();
    var list: std.ArrayList(common.Source) = .empty;
    errdefer {
        for (list.items) |s| {
            gpa.free(s.name);
            gpa.free(s.description);
        }
        list.deinit(gpa);
    }
    try appendSource(gpa, &list, "default", "Microphone");
    const inputs = session().msgSend(Object, "availableInputs", .{});
    if (inputs.value != null) {
        const n = inputs.msgSend(c_ulong, "count", .{});
        var i: c_ulong = 0;
        while (i < n) : (i += 1) {
            const port = inputs.msgSend(Object, "objectAtIndex:", .{i});
            const uid = apple.utf8(port.msgSend(Object, "UID", .{})) orelse continue;
            const name = apple.utf8(port.msgSend(Object, "portName", .{})) orelse uid;
            try appendSource(gpa, &list, uid, name);
        }
    }
    return list.toOwnedSlice(gpa);
}

pub const Permission = enum { not_determined, restricted, denied, authorized };

pub fn microphonePermission() Permission {
    const status = apple.class("AVCaptureDevice").msgSend(isize, "authorizationStatusForMediaType:", .{AVMediaTypeAudio});
    return switch (status) {
        0 => .not_determined,
        1 => .restricted,
        2 => .denied,
        else => .authorized,
    };
}

/// Play-and-record, active; `uid` (a port UID) becomes the preferred input.
fn activateSession(uid: ?[]const u8) !void {
    const pool = apple.objc.AutoreleasePool.init();
    defer pool.deinit();
    const s = session();
    if (!apple.isTrue(s.msgSend(apple.c.BOOL, "setCategory:withOptions:error:", .{
        AVAudioSessionCategoryPlayAndRecord,
        option_mix_with_others | option_allow_bluetooth | option_default_to_speaker,
        @as(?*anyopaque, null),
    }))) return error.AudioSessionFailed;
    if (uid) |u| {
        const inputs = s.msgSend(Object, "availableInputs", .{});
        const n = if (inputs.value != null) inputs.msgSend(c_ulong, "count", .{}) else 0;
        var i: c_ulong = 0;
        const found = while (i < n) : (i += 1) {
            const port = inputs.msgSend(Object, "objectAtIndex:", .{i});
            const port_uid = apple.utf8(port.msgSend(Object, "UID", .{})) orelse continue;
            if (std.mem.eql(u8, port_uid, u)) break port;
        } else null;
        const port = found orelse return error.NoInputDevice;
        _ = s.msgSend(apple.c.BOOL, "setPreferredInput:error:", .{ port, @as(?*anyopaque, null) });
    }
    if (!apple.isTrue(s.msgSend(apple.c.BOOL, "setActive:error:", .{ apple.boolean(true), @as(?*anyopaque, null) }))) return error.AudioSessionFailed;
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

    /// Open `source` (a `Source.name`: "default" or a port UID; null =
    /// the default input). `app_name` is unused on iOS.
    pub fn open(source: ?[:0]const u8, app_name: [:0]const u8, rate: u32) !Stream {
        if (rate < 8000 or rate > 192000) return error.UnsupportedSampleRate;
        _ = app_name;
        switch (microphonePermission()) {
            .denied, .restricted => return error.MicrophonePermissionDenied,
            .not_determined, .authorized => {},
        }
        const uid: ?[]const u8 = if (source) |s| (if (std.mem.eql(u8, s, "default")) null else s) else null;
        try activateSession(uid);

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

        // ~100 ms buffers.
        const bytes: u32 = rate / 10 * @sizeOf(f32);
        for (0..buffer_count) |_| {
            var buf: ?*AudioQueueBuffer = null;
            if (AudioQueueAllocateBuffer(queue, bytes, &buf) != 0) return error.OpenFailed;
            _ = AudioQueueEnqueueBuffer(queue, buf.?, 0, null);
        }
        if (AudioQueueStart(queue, null) != 0) {
            log.warn("AudioQueueStart failed (is the audio session interrupted?)", .{});
            return error.OpenFailed;
        }
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
        _ = c.pthread_cond_destroy(&self.state.cond);
        _ = c.pthread_mutex_destroy(&self.state.mutex);
        gpa.destroy(self.state);
    }
};

/// Lists the inputs and reports the microphone permission (opening a
/// stream would show the prompt, so the check doesn't).
pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    const sources = listSources(gpa) catch |err| return .{
        .module = "audio_capture",
        .ok = false,
        .detail = try std.fmt.allocPrint(gpa, "AVAudioSession: {s}", .{@errorName(err)}),
    };
    defer common.freeSources(gpa, sources);
    return .{
        .module = "audio_capture",
        .ok = true,
        .detail = try std.fmt.allocPrint(gpa, "AVAudioSession + AudioQueue: {d} inputs; microphone permission: {s}", .{
            sources.len,
            @tagName(microphonePermission()),
        }),
    };
}
