//! Windows backend: WASAPI in shared mode. Microphones are the active capture
//! endpoints; system audio is each active render endpoint opened in loopback
//! mode (listed as `loopback:<endpoint id>`, the counterpart of PulseAudio's
//! `.monitor` sources). The stream captures in the device's mix format and
//! converts here: downmix to mono, linear resampling to the requested rate.
//!
//! Loopback delivers no packets while nothing plays; `read` fills that time
//! with silence so a caller never blocks on a quiet system.

const std = @import("std");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");
const win32 = @import("../../platform/windows/win32.zig");

const log = std.log.scoped(.audio_capture);

const GUID = win32.GUID;
const HRESULT = win32.HRESULT;
const DWORD = win32.DWORD;
const UINT = u32;

/// Source name prefix for system audio (a render endpoint in loopback mode).
pub const loopback_prefix = "loopback:";

// --- COM interfaces (only the slots used are typed) ------------------------

fn guid(comptime s: []const u8) GUID {
    return GUID.parse("{" ++ s ++ "}");
}

const CLSID_MMDeviceEnumerator = guid("BCDE0395-E52F-467C-8E3D-C4579291692E");
const IID_IMMDeviceEnumerator = guid("A95664D2-9614-4F35-A746-DE8DB63617E6");
const IID_IAudioClient = guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2");
const IID_IAudioCaptureClient = guid("C8ADBD64-E71E-48A0-A4DE-185C395CD317");

const PROPERTYKEY = extern struct { fmtid: GUID, pid: DWORD };
const PKEY_Device_FriendlyName: PROPERTYKEY = .{ .fmtid = guid("A45C254E-DF1C-4EFD-8020-67D146A850E0"), .pid = 14 };

const PROPVARIANT = extern struct {
    vt: u16 = 0,
    r1: u16 = 0,
    r2: u16 = 0,
    r3: u16 = 0,
    data: [2]usize = .{ 0, 0 },
};
const VT_LPWSTR = 31;
extern "ole32" fn PropVariantClear(pvar: *PROPVARIANT) callconv(.winapi) HRESULT;

const Slot = *const anyopaque;

const IUnknownVtbl = extern struct {
    QueryInterface: Slot,
    AddRef: Slot,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
};

fn release(p: anytype) void {
    const unk: *const *const IUnknownVtbl = @ptrCast(@alignCast(p));
    _ = unk.*.Release(@ptrCast(p));
}

const IMMDeviceEnumerator = extern struct {
    vtbl: *const extern struct {
        base: IUnknownVtbl,
        EnumAudioEndpoints: *const fn (*IMMDeviceEnumerator, c_int, DWORD, *?*IMMDeviceCollection) callconv(.winapi) HRESULT,
        GetDefaultAudioEndpoint: *const fn (*IMMDeviceEnumerator, c_int, c_int, *?*IMMDevice) callconv(.winapi) HRESULT,
        GetDevice: *const fn (*IMMDeviceEnumerator, [*:0]const u16, *?*IMMDevice) callconv(.winapi) HRESULT,
    },
};

const IMMDeviceCollection = extern struct {
    vtbl: *const extern struct {
        base: IUnknownVtbl,
        GetCount: *const fn (*IMMDeviceCollection, *UINT) callconv(.winapi) HRESULT,
        Item: *const fn (*IMMDeviceCollection, UINT, *?*IMMDevice) callconv(.winapi) HRESULT,
    },
};

const IMMDevice = extern struct {
    vtbl: *const extern struct {
        base: IUnknownVtbl,
        Activate: *const fn (*IMMDevice, *const GUID, DWORD, ?*PROPVARIANT, *?*anyopaque) callconv(.winapi) HRESULT,
        OpenPropertyStore: *const fn (*IMMDevice, DWORD, *?*IPropertyStore) callconv(.winapi) HRESULT,
        GetId: *const fn (*IMMDevice, *?[*:0]u16) callconv(.winapi) HRESULT,
    },
};

const IPropertyStore = extern struct {
    vtbl: *const extern struct {
        base: IUnknownVtbl,
        GetCount: Slot,
        GetAt: Slot,
        GetValue: *const fn (*IPropertyStore, *const PROPERTYKEY, *PROPVARIANT) callconv(.winapi) HRESULT,
    },
};

const IAudioClient = extern struct {
    vtbl: *const extern struct {
        base: IUnknownVtbl,
        Initialize: *const fn (*IAudioClient, c_int, DWORD, i64, i64, *const anyopaque, ?*const GUID) callconv(.winapi) HRESULT,
        GetBufferSize: Slot,
        GetStreamLatency: Slot,
        GetCurrentPadding: Slot,
        IsFormatSupported: Slot,
        GetMixFormat: *const fn (*IAudioClient, *?*anyopaque) callconv(.winapi) HRESULT,
        GetDevicePeriod: Slot,
        Start: *const fn (*IAudioClient) callconv(.winapi) HRESULT,
        Stop: *const fn (*IAudioClient) callconv(.winapi) HRESULT,
        Reset: Slot,
        SetEventHandle: Slot,
        GetService: *const fn (*IAudioClient, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    },
};

const IAudioCaptureClient = extern struct {
    vtbl: *const extern struct {
        base: IUnknownVtbl,
        GetBuffer: *const fn (*IAudioCaptureClient, *?[*]const u8, *UINT, *DWORD, ?*u64, ?*u64) callconv(.winapi) HRESULT,
        ReleaseBuffer: *const fn (*IAudioCaptureClient, UINT) callconv(.winapi) HRESULT,
        GetNextPacketSize: *const fn (*IAudioCaptureClient, *UINT) callconv(.winapi) HRESULT,
    },
};

const eRender = 0;
const eCapture = 1;
const eConsole = 0;
const DEVICE_STATE_ACTIVE: DWORD = 1;
const CLSCTX_ALL: DWORD = 0x17;
const STGM_READ: DWORD = 0;
const AUDCLNT_SHAREMODE_SHARED = 0;
const AUDCLNT_STREAMFLAGS_LOOPBACK: DWORD = 0x00020000;
const AUDCLNT_BUFFERFLAGS_SILENT: DWORD = 0x2;

fn failed(hr: HRESULT) bool {
    return hr < 0;
}

// --- Pure helpers (unit-tested) --------------------------------------------

pub const SampleType = enum { f32, i16, i32 };

pub const MixFormat = struct {
    sample: SampleType,
    channels: u16,
    rate: u32,
    /// Bytes per frame (all channels).
    block_align: u16,
};

/// Parse a WAVEFORMATEX / WAVEFORMATEXTENSIBLE from its raw bytes (read field
/// by field: the struct is byte-packed in the SDK).
pub fn parseMixFormat(bytes: []const u8) !MixFormat {
    if (bytes.len < 18) return error.UnsupportedFormat;
    const tag = std.mem.readInt(u16, bytes[0..2], .little);
    const channels = std.mem.readInt(u16, bytes[2..4], .little);
    const rate = std.mem.readInt(u32, bytes[4..8], .little);
    const block_align = std.mem.readInt(u16, bytes[12..14], .little);
    const bits = std.mem.readInt(u16, bytes[14..16], .little);
    const WAVE_FORMAT_PCM = 1;
    const WAVE_FORMAT_IEEE_FLOAT = 3;
    const WAVE_FORMAT_EXTENSIBLE = 0xFFFE;
    const kind: u32 = switch (tag) {
        WAVE_FORMAT_PCM, WAVE_FORMAT_IEEE_FLOAT => tag,
        WAVE_FORMAT_EXTENSIBLE => blk: {
            // Format (18) + Samples (2) + dwChannelMask (4), then SubFormat;
            // its first DWORD is the WAVE_FORMAT tag.
            if (bytes.len < 18 + 22) return error.UnsupportedFormat;
            break :blk std.mem.readInt(u32, bytes[24..28], .little);
        },
        else => return error.UnsupportedFormat,
    };
    const sample: SampleType = switch (kind) {
        WAVE_FORMAT_IEEE_FLOAT => if (bits == 32) .f32 else return error.UnsupportedFormat,
        WAVE_FORMAT_PCM => switch (bits) {
            16 => .i16,
            32 => .i32,
            else => return error.UnsupportedFormat,
        },
        else => return error.UnsupportedFormat,
    };
    if (channels == 0 or rate == 0 or block_align == 0) return error.UnsupportedFormat;
    return .{ .sample = sample, .channels = channels, .rate = rate, .block_align = block_align };
}

/// Frame `i` of interleaved `data`, averaged over its channels.
fn monoFrame(fmt: MixFormat, data: []const u8, i: usize) f32 {
    const base = i * fmt.block_align;
    var sum: f32 = 0;
    for (0..fmt.channels) |ch| {
        sum += switch (fmt.sample) {
            .f32 => @bitCast(std.mem.readInt(u32, data[base + ch * 4 ..][0..4], .little)),
            .i16 => @as(f32, @floatFromInt(std.mem.readInt(i16, data[base + ch * 2 ..][0..2], .little))) / 32768.0,
            .i32 => @as(f32, @floatFromInt(std.mem.readInt(i32, data[base + ch * 4 ..][0..4], .little))) / 2147483648.0,
        };
    }
    return sum / @as(f32, @floatFromInt(fmt.channels));
}

/// Streaming linear resampler for mono samples (chunk boundaries are seamless).
pub const Resampler = struct {
    /// Input frames per output sample.
    step: f64,
    /// Position of the next output, in input frames of the current chunk
    /// (-1 is the last sample of the previous chunk).
    pos: f64 = 0,
    prev: f32 = 0,

    pub fn init(in_rate: u32, out_rate: u32) Resampler {
        return .{ .step = @as(f64, @floatFromInt(in_rate)) / @as(f64, @floatFromInt(out_rate)) };
    }

    /// Resample the `n` mono samples `sample(0..n)` into `out`.
    pub fn push(self: *Resampler, gpa: std.mem.Allocator, n: usize, ctx: anytype, comptime sample: fn (@TypeOf(ctx), usize) f32, out: *std.ArrayList(f32)) !void {
        if (n == 0) return;
        const last: f64 = @floatFromInt(n - 1);
        while (self.pos < last) : (self.pos += self.step) {
            const fi = @floor(self.pos);
            const frac: f32 = @floatCast(self.pos - fi);
            const a = if (fi < 0) self.prev else sample(ctx, @intFromFloat(fi));
            const b = sample(ctx, @intFromFloat(fi + 1));
            try out.append(gpa, a + (b - a) * frac);
        }
        self.pos -= @floatFromInt(n);
        self.prev = sample(ctx, n - 1);
    }
};

fn sliceSample(s: []const f32, i: usize) f32 {
    return s[i];
}

test parseMixFormat {
    // WAVEFORMATEXTENSIBLE, 2 ch, 48 kHz, 32-bit float (the usual mix format).
    var ext: [40]u8 = @splat(0);
    std.mem.writeInt(u16, ext[0..2], 0xFFFE, .little);
    std.mem.writeInt(u16, ext[2..4], 2, .little);
    std.mem.writeInt(u32, ext[4..8], 48000, .little);
    std.mem.writeInt(u16, ext[12..14], 8, .little);
    std.mem.writeInt(u16, ext[14..16], 32, .little);
    std.mem.writeInt(u16, ext[16..18], 22, .little);
    std.mem.writeInt(u32, ext[24..28], 3, .little); // KSDATAFORMAT_SUBTYPE_IEEE_FLOAT
    const f = try parseMixFormat(&ext);
    try std.testing.expectEqual(SampleType.f32, f.sample);
    try std.testing.expectEqual(@as(u16, 2), f.channels);
    try std.testing.expectEqual(@as(u32, 48000), f.rate);

    // Plain PCM 16-bit mono.
    var pcm: [18]u8 = @splat(0);
    std.mem.writeInt(u16, pcm[0..2], 1, .little);
    std.mem.writeInt(u16, pcm[2..4], 1, .little);
    std.mem.writeInt(u32, pcm[4..8], 44100, .little);
    std.mem.writeInt(u16, pcm[12..14], 2, .little);
    std.mem.writeInt(u16, pcm[14..16], 16, .little);
    try std.testing.expectEqual(SampleType.i16, (try parseMixFormat(&pcm)).sample);

    std.mem.writeInt(u16, pcm[14..16], 24, .little);
    try std.testing.expectError(error.UnsupportedFormat, parseMixFormat(&pcm));
}

test "downmix averages channels" {
    const fmt: MixFormat = .{ .sample = .f32, .channels = 2, .rate = 48000, .block_align = 8 };
    var data: [16]u8 = undefined;
    for ([_]f32{ 1.0, 0.0, -0.5, -0.5 }, 0..) |v, i| std.mem.writeInt(u32, data[i * 4 ..][0..4], @bitCast(v), .little);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), monoFrame(fmt, &data, 0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), monoFrame(fmt, &data, 1), 1e-6);

    const fmt16: MixFormat = .{ .sample = .i16, .channels = 1, .rate = 16000, .block_align = 2 };
    var d16: [2]u8 = undefined;
    std.mem.writeInt(i16, &d16, -16384, .little);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), monoFrame(fmt16, &d16, 0), 1e-6);
}

test "resampler 48k -> 16k keeps rate and shape across chunks" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(f32) = .empty;
    defer out.deinit(gpa);
    var r = Resampler.init(48000, 16000);
    // A 1 s ramp in 10 ms chunks (480 frames): 16000 outputs, still a ramp.
    var input: [480]f32 = undefined;
    var t: usize = 0;
    for (0..100) |_| {
        for (&input) |*s| {
            s.* = @as(f32, @floatFromInt(t)) / 48000.0;
            t += 1;
        }
        try r.push(gpa, input.len, @as([]const f32, &input), sliceSample, &out);
    }
    try std.testing.expect(out.items.len >= 15999 and out.items.len <= 16001);
    for (out.items, 0..) |v, i| {
        const want = @as(f32, @floatFromInt(i)) * 3.0 / 48000.0;
        try std.testing.expectApproxEqAbs(want, v, 1e-4);
    }
}

test "resampler upsamples 8k -> 16k" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(f32) = .empty;
    defer out.deinit(gpa);
    var r = Resampler.init(8000, 16000);
    const input = [_]f32{ 0, 1, 0, -1, 0 };
    try r.push(gpa, input.len, @as([]const f32, &input), sliceSample, &out);
    try std.testing.expectEqualSlices(f32, &.{ 0, 0.5, 1, 0.5, 0, -0.5, -1, -0.5 }, out.items);
}

// --- COM helpers -----------------------------------------------------------

/// COM for this thread; `uninit` is true when this call must be balanced.
const ComScope = struct {
    uninit: bool,

    fn enter() !ComScope {
        const hr = win32.CoInitializeEx(null, win32.COINIT_MULTITHREADED);
        if (hr == win32.RPC_E_CHANGED_MODE) return .{ .uninit = false }; // already an STA (e.g. the UI thread)
        if (failed(hr)) return error.ComInitFailed;
        return .{ .uninit = true };
    }

    fn leave(self: ComScope) void {
        if (self.uninit) win32.CoUninitialize();
    }
};

fn enumerator() !*IMMDeviceEnumerator {
    var p: ?*anyopaque = null;
    if (failed(win32.CoCreateInstance(&CLSID_MMDeviceEnumerator, null, CLSCTX_ALL, &IID_IMMDeviceEnumerator, &p)) or p == null)
        return error.NoAudioDevices;
    return @ptrCast(@alignCast(p.?));
}

fn deviceId(gpa: std.mem.Allocator, dev: *IMMDevice) ![]u8 {
    var id_w: ?[*:0]u16 = null;
    if (failed(dev.vtbl.GetId(dev, &id_w)) or id_w == null) return error.DeviceIdUnavailable;
    defer win32.CoTaskMemFree(@ptrCast(id_w));
    return std.unicode.utf16LeToUtf8Alloc(gpa, std.mem.span(id_w.?));
}

fn friendlyName(gpa: std.mem.Allocator, dev: *IMMDevice) ![]u8 {
    var store: ?*IPropertyStore = null;
    if (failed(dev.vtbl.OpenPropertyStore(dev, STGM_READ, &store)) or store == null) return gpa.dupe(u8, "Audio device");
    defer release(store.?);
    var pv: PROPVARIANT = .{};
    defer _ = PropVariantClear(&pv);
    if (failed(store.?.vtbl.GetValue(store.?, &PKEY_Device_FriendlyName, &pv)) or pv.vt != VT_LPWSTR or pv.data[0] == 0)
        return gpa.dupe(u8, "Audio device");
    const name_w: [*:0]const u16 = @ptrFromInt(pv.data[0]);
    return std.unicode.utf16LeToUtf8Alloc(gpa, std.mem.span(name_w));
}

// --- Public API ------------------------------------------------------------

/// List the capture sources: microphones first, then system audio (one
/// loopback source per active output device). Free with `freeSources`.
pub fn listSources(gpa: std.mem.Allocator) ![]common.Source {
    const com = try ComScope.enter();
    defer com.leave();
    const en = try enumerator();
    defer release(en);

    var list: std.ArrayList(common.Source) = .empty;
    errdefer {
        for (list.items) |s| {
            gpa.free(s.name);
            gpa.free(s.description);
        }
        list.deinit(gpa);
    }
    for ([_]c_int{ eCapture, eRender }) |flow| {
        var coll: ?*IMMDeviceCollection = null;
        if (failed(en.vtbl.EnumAudioEndpoints(en, flow, DEVICE_STATE_ACTIVE, &coll)) or coll == null) continue;
        defer release(coll.?);
        var count: UINT = 0;
        _ = coll.?.vtbl.GetCount(coll.?, &count);
        for (0..count) |i| {
            var dev: ?*IMMDevice = null;
            if (failed(coll.?.vtbl.Item(coll.?, @intCast(i), &dev)) or dev == null) continue;
            defer release(dev.?);
            const id = try deviceId(gpa, dev.?);
            defer gpa.free(id);
            const friendly = try friendlyName(gpa, dev.?);
            defer gpa.free(friendly);
            const monitor = flow == eRender;
            const name = try std.fmt.allocPrintSentinel(gpa, "{s}{s}", .{ if (monitor) loopback_prefix else "", id }, 0);
            errdefer gpa.free(name);
            const description = if (monitor) try std.fmt.allocPrint(gpa, "System audio: {s}", .{friendly}) else try gpa.dupe(u8, friendly);
            errdefer gpa.free(description);
            try list.append(gpa, .{ .name = name, .description = description, .monitor = monitor });
        }
    }
    return list.toOwnedSlice(gpa);
}

/// A capture stream delivering mono f32 samples at the requested rate.
/// `read` blocks until the buffer is full; `open`, `read` and `close` must
/// be called from the same thread.
pub const Stream = struct {
    com: ComScope,
    device: *IMMDevice,
    client: *IAudioClient,
    capture: *IAudioCaptureClient,
    format: MixFormat,
    loopback: bool,
    rate: u32,
    resampler: Resampler,
    /// Converted samples not handed out yet (from `head`).
    pending: std.ArrayList(f32) = .empty,
    head: usize = 0,
    last_data_ms: u64,
    /// Frames the device flagged as silent (muted, or blocked by the privacy
    /// settings) and frames it delivered in total.
    silent_frames: u64 = 0,
    total_frames: u64 = 0,

    const gpa = std.heap.smp_allocator;

    /// Open `source`: a `Source.name`, null for the default microphone, or
    /// "loopback" for what the default output device plays. `app_name` is
    /// not used by WASAPI (the session is named after the process).
    pub fn open(source: ?[:0]const u8, app_name: [:0]const u8, rate: u32) !Stream {
        _ = app_name;
        if (rate == 0) return error.OpenFailed;
        const com = try ComScope.enter();
        errdefer com.leave();
        const en = try enumerator();
        defer release(en);

        var loopback = false;
        var dev: ?*IMMDevice = null;
        const hr = blk: {
            const s = source orelse break :blk en.vtbl.GetDefaultAudioEndpoint(en, eCapture, eConsole, &dev);
            if (std.mem.eql(u8, s, "loopback")) {
                loopback = true;
                break :blk en.vtbl.GetDefaultAudioEndpoint(en, eRender, eConsole, &dev);
            }
            const id = if (std.mem.startsWith(u8, s, loopback_prefix)) id: {
                loopback = true;
                break :id s[loopback_prefix.len..];
            } else s;
            const id_w = std.unicode.utf8ToUtf16LeAllocZ(gpa, id) catch return error.OutOfMemory;
            defer gpa.free(id_w);
            break :blk en.vtbl.GetDevice(en, id_w.ptr, &dev);
        };
        if (failed(hr) or dev == null) {
            log.warn("cannot open {s}: no such device (0x{X})", .{ source orelse "default input", @as(u32, @bitCast(hr)) });
            return error.OpenFailed;
        }
        errdefer release(dev.?);

        var client_p: ?*anyopaque = null;
        if (failed(dev.?.vtbl.Activate(dev.?, &IID_IAudioClient, CLSCTX_ALL, null, &client_p)) or client_p == null) return error.OpenFailed;
        const client: *IAudioClient = @ptrCast(@alignCast(client_p.?));
        errdefer release(client);

        var mix: ?*anyopaque = null;
        if (failed(client.vtbl.GetMixFormat(client, &mix)) or mix == null) return error.OpenFailed;
        defer win32.CoTaskMemFree(mix);
        const mix_bytes: [*]const u8 = @ptrCast(mix.?);
        const cb_size = std.mem.readInt(u16, mix_bytes[16..18], .little);
        const format = parseMixFormat(mix_bytes[0 .. 18 + @as(usize, cb_size)]) catch |err| {
            log.warn("unsupported mix format for {s}", .{source orelse "default input"});
            return err;
        };

        // 1 s of buffer in shared mode, in the mix format.
        const init_hr = client.vtbl.Initialize(client, AUDCLNT_SHAREMODE_SHARED, if (loopback) AUDCLNT_STREAMFLAGS_LOOPBACK else 0, 10_000_000, 0, mix.?, null);
        if (failed(init_hr)) {
            log.warn("cannot open {s}: Initialize failed (0x{X})", .{ source orelse "default input", @as(u32, @bitCast(init_hr)) });
            return error.OpenFailed;
        }
        var cap_p: ?*anyopaque = null;
        if (failed(client.vtbl.GetService(client, &IID_IAudioCaptureClient, &cap_p)) or cap_p == null) return error.OpenFailed;
        const capture: *IAudioCaptureClient = @ptrCast(@alignCast(cap_p.?));
        errdefer release(capture);
        if (failed(client.vtbl.Start(client))) return error.OpenFailed;

        return .{
            .com = com,
            .device = dev.?,
            .client = client,
            .capture = capture,
            .format = format,
            .loopback = loopback,
            .rate = rate,
            .resampler = .init(format.rate, rate),
            .last_data_ms = win32.GetTickCount64(),
        };
    }

    const FrameCtx = struct { fmt: MixFormat, data: []const u8 };
    fn frameSample(ctx: FrameCtx, i: usize) f32 {
        return monoFrame(ctx.fmt, ctx.data, i);
    }
    fn zeroSample(_: void, _: usize) f32 {
        return 0;
    }

    /// Convert every packet available now; true if there was any.
    fn drain(self: *Stream) !bool {
        var any = false;
        while (true) {
            var next: UINT = 0;
            if (failed(self.capture.vtbl.GetNextPacketSize(self.capture, &next))) return error.ReadFailed;
            if (next == 0) return any;
            var data: ?[*]const u8 = null;
            var frames: UINT = 0;
            var flags: DWORD = 0;
            if (failed(self.capture.vtbl.GetBuffer(self.capture, &data, &frames, &flags, null, null))) return error.ReadFailed;
            defer _ = self.capture.vtbl.ReleaseBuffer(self.capture, frames);
            if (frames == 0) continue;
            any = true;
            self.total_frames += frames;
            if (flags & AUDCLNT_BUFFERFLAGS_SILENT != 0 or data == null) {
                self.silent_frames += frames;
                try self.resampler.push(gpa, frames, {}, zeroSample, &self.pending);
            } else {
                const bytes = data.?[0 .. @as(usize, frames) * self.format.block_align];
                try self.resampler.push(gpa, frames, FrameCtx{ .fmt = self.format, .data = bytes }, frameSample, &self.pending);
            }
        }
    }

    /// Fill `samples` completely (blocks).
    pub fn read(self: *Stream, samples: []f32) !void {
        var filled: usize = 0;
        while (filled < samples.len) {
            const avail = self.pending.items[self.head..];
            if (avail.len > 0) {
                const n = @min(avail.len, samples.len - filled);
                @memcpy(samples[filled..][0..n], avail[0..n]);
                filled += n;
                self.head += n;
                if (self.head == self.pending.items.len) {
                    self.pending.clearRetainingCapacity();
                    self.head = 0;
                }
                continue;
            }
            const now = win32.GetTickCount64();
            if (try self.drain()) {
                self.last_data_ms = now;
                continue;
            }
            // Loopback is silent (no packets) while nothing plays: after a
            // short gap, hand out that time as silence.
            const gap = now -| self.last_data_ms;
            if (self.loopback and gap >= 100) {
                try self.pending.appendNTimes(gpa, 0, @intCast(gap * self.rate / 1000));
                self.resampler.prev = 0;
                self.last_data_ms = now;
                continue;
            }
            win32.Sleep(10);
        }
    }

    pub fn close(self: *Stream) void {
        _ = self.client.vtbl.Stop(self.client);
        release(self.capture);
        release(self.client);
        release(self.device);
        self.pending.deinit(gpa);
        self.com.leave();
    }
};

pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    const sources = listSources(gpa) catch |err| return .{
        .module = "audio_capture",
        .ok = false,
        .detail = try std.fmt.allocPrint(gpa, "WASAPI: {s}", .{@errorName(err)}),
    };
    defer common.freeSources(gpa, sources);
    var monitors: usize = 0;
    for (sources) |s| monitors += @intFromBool(s.monitor);
    return .{
        .module = "audio_capture",
        .ok = true,
        .detail = try std.fmt.allocPrint(gpa, "WASAPI: {d} inputs, {d} system-audio (loopback)", .{ sources.len - monitors, monitors }),
    };
}

// Live capture (manual): `ORIEL_AUDIO_LIVE=1 zig build test -Daudio_capture`.
// Captures ~2 s from the default microphone and from system audio and prints
// the RMS of each (play something for a non-zero loopback RMS).
test "live capture (ORIEL_AUDIO_LIVE=1)" {
    const live = std.testing.environ.getAlloc(std.testing.allocator, "ORIEL_AUDIO_LIVE") catch return error.SkipZigTest;
    defer std.testing.allocator.free(live);
    const sources = try listSources(std.testing.allocator);
    defer common.freeSources(std.testing.allocator, sources);
    for (sources) |s| std.debug.print("source: {s} [{s}] {s}\n", .{ s.description, if (s.monitor) "system audio" else "input", s.name });

    var buf: [16000 * 2]f32 = undefined;
    var names: [16]?[:0]const u8 = @splat(null);
    var labels: [16][]const u8 = @splat("");
    names[0] = null;
    labels[0] = "default microphone";
    names[1] = "loopback";
    labels[1] = "default system audio";
    var n: usize = 2;
    for (sources) |s| {
        if (n == names.len) break;
        names[n] = s.name;
        labels[n] = s.description;
        n += 1;
    }
    for (names[0..n], labels[0..n]) |src, label| {
        var stream = Stream.open(src, "oriel test", 16000) catch |err| {
            std.debug.print("{s}: open failed ({s})\n", .{ label, @errorName(err) });
            continue;
        };
        defer stream.close();
        const t0 = win32.GetTickCount64();
        try stream.read(&buf);
        const took = win32.GetTickCount64() - t0;
        var sum: f64 = 0;
        for (buf) |v| sum += @as(f64, v) * v;
        std.debug.print("{s}: {d} samples @16 kHz in {d} ms, mix {d} Hz x{d} {s}, device frames {d} (silent-flagged {d}), RMS {d:.5}\n", .{
            label,
            buf.len,
            took,
            stream.format.rate,
            stream.format.channels,
            @tagName(stream.format.sample),
            stream.total_frames,
            stream.silent_frames,
            @sqrt(sum / buf.len),
        });
    }
}
