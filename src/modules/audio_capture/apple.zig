//! Shared CoreAudio / AudioQueue capture logic for macOS and iOS.

const std = @import("std");
const apple = @import("../../platform/apple/apple.zig");
const common = @import("common.zig");

const c = std.c;

pub const OSStatus = i32;
pub const AudioStreamBasicDescription = extern struct {
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
pub const AudioQueueRef = *opaque {};
pub const AudioQueueBuffer = extern struct {
    capacity: u32,
    data: *anyopaque,
    byte_size: u32,
    user_data: ?*anyopaque,
    packet_desc_capacity: u32,
    packet_descs: ?*anyopaque,
    packet_desc_count: u32,
};
pub const InputCallback = *const fn (user: ?*anyopaque, queue: AudioQueueRef, buffer: *AudioQueueBuffer, start: *const anyopaque, packets: u32, descs: ?*const anyopaque) callconv(.c) void;

pub extern "c" fn AudioQueueNewInput(format: *const AudioStreamBasicDescription, cb: InputCallback, user: ?*anyopaque, run_loop: ?*anyopaque, mode: ?*anyopaque, flags: u32, out: *?AudioQueueRef) OSStatus;
pub extern "c" fn AudioQueueAllocateBuffer(queue: AudioQueueRef, size: u32, out: *?*AudioQueueBuffer) OSStatus;
pub extern "c" fn AudioQueueEnqueueBuffer(queue: AudioQueueRef, buffer: *AudioQueueBuffer, n: u32, descs: ?*const anyopaque) OSStatus;
pub extern "c" fn AudioQueueSetProperty(queue: AudioQueueRef, id: u32, data: *const anyopaque, size: u32) OSStatus;
pub extern "c" fn AudioQueueStart(queue: AudioQueueRef, start: ?*const anyopaque) OSStatus;
pub extern "c" fn AudioQueueStop(queue: AudioQueueRef, immediate: u8) OSStatus;
pub extern "c" fn AudioQueueDispose(queue: AudioQueueRef, immediate: u8) OSStatus;

pub const kAudioFormatLinearPCM: u32 = 0x6C70_636D; // 'lpcm'
pub const kAudioFormatFlagIsFloat: u32 = 1 << 0;
pub const kAudioFormatFlagIsPacked: u32 = 1 << 3;

pub const buffer_count = 3;

pub fn appendSource(gpa: std.mem.Allocator, list: *std.ArrayList(common.Source), name: []const u8, description: []const u8) !void {
    const n = try gpa.dupeZ(u8, name);
    errdefer gpa.free(n);
    const d = try gpa.dupe(u8, description);
    errdefer gpa.free(d);
    try list.append(gpa, .{ .name = n, .description = d, .monitor = false });
}

/// Shared with the AudioQueue callback thread (heap, stable address).
pub const State = struct {
    mutex: c.pthread_mutex_t = .{},
    cond: c.pthread_cond_t = .{},
    ring: []f32,
    head: usize = 0, // next sample to read
    len: usize = 0, // samples available
    running: bool = true,

    pub fn pushFromTap(ctx: *anyopaque, samples: []const f32) void {
        const self: *State = @ptrCast(@alignCast(ctx));
        self.push(samples);
    }

    pub fn push(self: *State, samples: []const f32) void {
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

pub fn onInput(user: ?*anyopaque, queue: AudioQueueRef, buffer: *AudioQueueBuffer, _: *const anyopaque, _: u32, _: ?*const anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(user.?));
    const samples: [*]const f32 = @ptrCast(@alignCast(buffer.data));
    state.push(samples[0 .. buffer.byte_size / @sizeOf(f32)]);
    _ = c.pthread_mutex_lock(&state.mutex);
    const running = state.running;
    _ = c.pthread_mutex_unlock(&state.mutex);
    if (running) _ = AudioQueueEnqueueBuffer(queue, buffer, 0, null);
}

pub fn readStream(st: *State, samples: []f32) !void {
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
