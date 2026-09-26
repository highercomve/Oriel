//! System audio capture without a driver: a Core Audio process tap
//! (macOS 14.2+) on all output, read through a private aggregate device.
//!
//! The tap delivers the output device's format (usually 48 kHz float
//! stereo); `Tap` mixes it to mono and decimates it to the requested rate
//! (averaging each output period, which also low-passes the signal), then
//! hands the samples to `sink`.
//!
//! Permission: macOS asks once for "System Audio Recording" (for an
//! unbundled executable, on behalf of the app that started it). There is no
//! public API to read that permission; when it is denied the tap records
//! silence.

const std = @import("std");
const cocoa = @import("../../platform/macos/cocoa.zig");

const Object = cocoa.Object;
const log = std.log.scoped(.oriel);

const OSStatus = i32;
const AudioObjectID = u32;
const AudioDeviceIOProcID = *opaque {};
const AudioObjectPropertyAddress = extern struct { selector: u32, scope: u32, element: u32 };
const AudioBuffer = extern struct { channels: u32, bytes: u32, data: ?*anyopaque };
const AudioBufferList = extern struct { count: u32, first: AudioBuffer };
const AudioStreamBasicDescription = extern struct {
    sample_rate: f64,
    format_id: u32,
    format_flags: u32,
    bytes_per_packet: u32,
    frames_per_packet: u32,
    bytes_per_frame: u32,
    channels_per_frame: u32,
    bits_per_channel: u32,
    reserved: u32,
};
const IOProc = *const fn (device: AudioObjectID, now: ?*const anyopaque, input: ?*const AudioBufferList, input_time: ?*const anyopaque, output: ?*AudioBufferList, output_time: ?*const anyopaque, user: ?*anyopaque) callconv(.c) OSStatus;

// macOS 14.2+: weak, so an app built for an older macOS still launches there
// (null when the running macOS has no process taps).
const AudioHardwareCreateProcessTap = @extern(?*const fn (description: cocoa.id, out: *AudioObjectID) callconv(.c) OSStatus, .{ .name = "AudioHardwareCreateProcessTap", .linkage = .weak });
const AudioHardwareDestroyProcessTap = @extern(?*const fn (tap: AudioObjectID) callconv(.c) OSStatus, .{ .name = "AudioHardwareDestroyProcessTap", .linkage = .weak });
extern "c" fn AudioHardwareCreateAggregateDevice(description: cocoa.id, out: *AudioObjectID) OSStatus; // CFDictionaryRef, toll-free bridged
extern "c" fn AudioHardwareDestroyAggregateDevice(device: AudioObjectID) OSStatus;
extern "c" fn AudioDeviceCreateIOProcID(device: AudioObjectID, proc: IOProc, user: ?*anyopaque, out: *?AudioDeviceIOProcID) OSStatus;
extern "c" fn AudioDeviceDestroyIOProcID(device: AudioObjectID, proc: AudioDeviceIOProcID) OSStatus;
extern "c" fn AudioDeviceStart(device: AudioObjectID, proc: ?AudioDeviceIOProcID) OSStatus;
extern "c" fn AudioDeviceStop(device: AudioObjectID, proc: ?AudioDeviceIOProcID) OSStatus;
extern "c" fn AudioObjectGetPropertyData(id: AudioObjectID, addr: *const AudioObjectPropertyAddress, qual_size: u32, qual: ?*const anyopaque, size: *u32, data: *anyopaque) OSStatus;

fn fourCC(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .big);
}

const kAudioObjectSystemObject: AudioObjectID = 1;
const scope_global = fourCC("glob");

/// Whether this macOS has process taps (14.2+).
pub fn available() bool {
    return cocoa.objc.getClass("CATapDescription") != null and
        AudioHardwareCreateProcessTap != null and AudioHardwareDestroyProcessTap != null;
}

/// The `Source.name` of the system-audio tap in `listSources`.
pub const source_name = "oriel:system-audio";

/// Mixes interleaved or planar float frames to mono and decimates them.
pub const Decimator = struct {
    /// Input frames per output sample (>= 1).
    step: f64,
    phase: f64 = 0,
    acc: f64 = 0,
    count: u32 = 0,

    pub fn init(in_rate: f64, out_rate: f64) Decimator {
        return .{ .step = @max(1.0, in_rate / out_rate) };
    }

    /// Feed one mono input sample; returns an output sample when a period
    /// is complete.
    pub fn feed(self: *Decimator, x: f32) ?f32 {
        self.acc += x;
        self.count += 1;
        self.phase += 1;
        if (self.phase < self.step) return null;
        self.phase -= self.step;
        const out: f32 = @floatCast(self.acc / @as(f64, @floatFromInt(self.count)));
        self.acc = 0;
        self.count = 0;
        return out;
    }
};

pub const Sink = *const fn (ctx: *anyopaque, samples: []const f32) void;

pub const Tap = struct {
    tap_id: AudioObjectID = 0,
    aggregate: AudioObjectID = 0,
    proc: ?AudioDeviceIOProcID = null,
    decimator: Decimator,
    sink: Sink,
    sink_ctx: *anyopaque,
    /// Scratch for one IO cycle's output (IO thread only).
    out: [4096]f32 = undefined,

    /// Start tapping all system output, delivering mono samples at `rate`
    /// to `sink` (called on Core Audio's IO thread). `self` must stay put
    /// until `stop`.
    pub fn start(self: *Tap, rate: u32) !void {
        const pool = cocoa.objc.AutoreleasePool.init();
        defer pool.deinit();
        const desc_class = cocoa.objc.getClass("CATapDescription") orelse return error.SystemAudioUnsupported;
        const empty = cocoa.class("NSArray").msgSend(Object, "array", .{});
        const desc = desc_class.msgSend(Object, "alloc", .{}).msgSend(Object, "initStereoGlobalTapButExcludeProcesses:", .{empty});
        if (desc.value == null) return error.SystemAudioUnsupported;
        defer desc.release();
        desc.msgSend(void, "setPrivate:", .{cocoa.boolean(true)});
        if (cocoa.nsString("Oriel system audio")) |name| {
            defer name.release();
            desc.msgSend(void, "setName:", .{name});
        }
        const create_tap = AudioHardwareCreateProcessTap orelse return error.SystemAudioUnsupported;
        const destroy_tap = AudioHardwareDestroyProcessTap orelse return error.SystemAudioUnsupported;
        if (create_tap(desc.value, &self.tap_id) != 0) return error.TapCreateFailed;
        errdefer _ = destroy_tap(self.tap_id);

        var format: AudioStreamBasicDescription = undefined;
        var size: u32 = @sizeOf(AudioStreamBasicDescription);
        const fmt_addr: AudioObjectPropertyAddress = .{ .selector = fourCC("tfmt"), .scope = scope_global, .element = 0 };
        if (AudioObjectGetPropertyData(self.tap_id, &fmt_addr, 0, null, &size, &format) != 0) return error.TapFormatFailed;
        const kAudioFormatFlagIsFloat: u32 = 1;
        if (format.format_flags & kAudioFormatFlagIsFloat == 0 or format.bits_per_channel != 32) return error.UnsupportedTapFormat;
        self.decimator = .init(format.sample_rate, @floatFromInt(rate));

        const tap_uid = desc.msgSend(Object, "UUID", .{}).msgSend(Object, "UUIDString", .{});
        try self.createAggregate(tap_uid);
        errdefer _ = AudioHardwareDestroyAggregateDevice(self.aggregate);

        if (AudioDeviceCreateIOProcID(self.aggregate, &ioProc, self, &self.proc) != 0) return error.IOProcFailed;
        errdefer _ = AudioDeviceDestroyIOProcID(self.aggregate, self.proc.?);
        if (AudioDeviceStart(self.aggregate, self.proc) != 0) return error.DeviceStartFailed;
    }

    /// A private aggregate device around the default output and the tap.
    fn createAggregate(self: *Tap, tap_uid: Object) !void {
        const output_uid = try defaultOutputUid();
        const dict = cocoa.class("NSMutableDictionary").msgSend(Object, "dictionary", .{});
        const agg_uid = cocoa.class("NSUUID").msgSend(Object, "UUID", .{}).msgSend(Object, "UUIDString", .{});
        const yes = cocoa.class("NSNumber").msgSend(Object, "numberWithBool:", .{cocoa.boolean(true)});
        const no = cocoa.class("NSNumber").msgSend(Object, "numberWithBool:", .{cocoa.boolean(false)});
        try put(dict, "uid", agg_uid);
        try put(dict, "name", try str("Oriel system audio"));
        try put(dict, "master", output_uid);
        try put(dict, "private", yes);
        try put(dict, "stacked", no);
        try put(dict, "tapautostart", yes);
        const sub = cocoa.class("NSMutableDictionary").msgSend(Object, "dictionary", .{});
        try put(sub, "uid", output_uid);
        try put(dict, "subdevices", cocoa.class("NSArray").msgSend(Object, "arrayWithObject:", .{sub}));
        const tap = cocoa.class("NSMutableDictionary").msgSend(Object, "dictionary", .{});
        try put(tap, "uid", tap_uid);
        try put(tap, "drift", yes);
        try put(dict, "taps", cocoa.class("NSArray").msgSend(Object, "arrayWithObject:", .{tap}));
        if (AudioHardwareCreateAggregateDevice(dict.value, &self.aggregate) != 0) return error.AggregateDeviceFailed;
    }

    pub fn stop(self: *Tap) void {
        // AudioDeviceStop waits for the IO proc to return.
        _ = AudioDeviceStop(self.aggregate, self.proc);
        _ = AudioDeviceDestroyIOProcID(self.aggregate, self.proc.?);
        _ = AudioHardwareDestroyAggregateDevice(self.aggregate);
        if (AudioHardwareDestroyProcessTap) |destroy_tap| _ = destroy_tap(self.tap_id);
    }
};

/// Core Audio's IO thread: mix to mono, decimate, hand over.
fn ioProc(_: AudioObjectID, _: ?*const anyopaque, input: ?*const AudioBufferList, _: ?*const anyopaque, _: ?*AudioBufferList, _: ?*const anyopaque, user: ?*anyopaque) callconv(.c) OSStatus {
    const self: *Tap = @ptrCast(@alignCast(user.?));
    const list = input orelse return 0;
    const buffers: [*]const AudioBuffer = @ptrCast(&list.first);
    const nbuf = list.count;
    if (nbuf == 0) return 0;
    var n_out: usize = 0;
    if (nbuf == 1) {
        // Interleaved.
        const b = buffers[0];
        const ch: usize = @max(1, b.channels);
        const data: [*]const f32 = @ptrCast(@alignCast(b.data orelse return 0));
        const frames = b.bytes / @sizeOf(f32) / ch;
        for (0..frames) |f| {
            var sum: f32 = 0;
            for (0..ch) |c| sum += data[f * ch + c];
            if (self.decimator.feed(sum / @as(f32, @floatFromInt(ch)))) |y| {
                self.out[n_out] = y;
                n_out += 1;
                if (n_out == self.out.len) {
                    self.sink(self.sink_ctx, &self.out);
                    n_out = 0;
                }
            }
        }
    } else {
        // Planar: one mono buffer per channel.
        const frames = buffers[0].bytes / @sizeOf(f32);
        for (0..frames) |f| {
            var sum: f32 = 0;
            for (0..nbuf) |c| {
                const d: [*]const f32 = @ptrCast(@alignCast(buffers[c].data orelse continue));
                if (f < buffers[c].bytes / @sizeOf(f32)) sum += d[f];
            }
            if (self.decimator.feed(sum / @as(f32, @floatFromInt(nbuf)))) |y| {
                self.out[n_out] = y;
                n_out += 1;
                if (n_out == self.out.len) {
                    self.sink(self.sink_ctx, &self.out);
                    n_out = 0;
                }
            }
        }
    }
    if (n_out > 0) self.sink(self.sink_ctx, self.out[0..n_out]);
    return 0;
}

/// Autoreleased NSString.
fn str(s: []const u8) !Object {
    const ns = cocoa.nsString(s) orelse return error.OutOfMemory;
    return ns.msgSend(Object, "autorelease", .{});
}

fn put(dict: Object, key: []const u8, value: Object) !void {
    if (value.value == null) return error.AggregateDeviceFailed;
    dict.msgSend(void, "setObject:forKey:", .{ value, try str(key) });
}

/// The default output device's UID (autoreleased NSString).
fn defaultOutputUid() !Object {
    var dev: AudioObjectID = 0;
    var size: u32 = @sizeOf(AudioObjectID);
    const addr: AudioObjectPropertyAddress = .{ .selector = fourCC("dOut"), .scope = scope_global, .element = 0 };
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, null, &size, &dev) != 0 or dev == 0) return error.NoOutputDevice;
    var uid: cocoa.id = null;
    size = @sizeOf(cocoa.id);
    const uid_addr: AudioObjectPropertyAddress = .{ .selector = fourCC("uid "), .scope = scope_global, .element = 0 };
    if (AudioObjectGetPropertyData(dev, &uid_addr, 0, null, &size, @ptrCast(&uid)) != 0 or uid == null) return error.NoOutputDevice;
    // The property returns a +1 CFString: hand it to the autorelease pool.
    return (Object{ .value = uid }).msgSend(Object, "autorelease", .{});
}

test Decimator {
    var d = Decimator.init(48000, 16000);
    var outs: [4]f32 = undefined;
    var n: usize = 0;
    for ([_]f32{ 1, 1, 1, 0, 0, 0, 0.5, 0.5, 0.5 }) |x| {
        if (d.feed(x)) |y| {
            outs[n] = y;
            n += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualSlices(f32, &.{ 1, 0, 0.5 }, outs[0..3]);
    // 44.1 kHz -> 16 kHz: fractional step, 44100 inputs -> 16000 outputs
    // (± 1 from floating-point rounding of the phase).
    var d2 = Decimator.init(44100, 16000);
    var count: usize = 0;
    for (0..44100) |_| count += @intFromBool(d2.feed(0.25) != null);
    try std.testing.expect(count >= 15999 and count <= 16000);
}
