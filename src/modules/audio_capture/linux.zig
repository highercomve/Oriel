//! Linux backend: libpulse. PipeWire serves it through pipewire-pulse, and the
//! server converts to the mono float format and rate we ask for.

const std = @import("std");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");

const c = @cImport({
    @cInclude("pulse/pulseaudio.h");
    @cInclude("pulse/simple.h");
});

const log = std.log.scoped(.audio_capture);

/// List the capture sources (microphones first, then system-audio monitors).
/// Free the result with `freeSources`.
pub fn listSources(gpa: std.mem.Allocator) ![]common.Source {
    const ml = c.pa_mainloop_new() orelse return error.OutOfMemory;
    defer c.pa_mainloop_free(ml);
    const ctx = c.pa_context_new(c.pa_mainloop_get_api(ml), "oriel") orelse return error.OutOfMemory;
    defer c.pa_context_unref(ctx);
    if (c.pa_context_connect(ctx, null, c.PA_CONTEXT_NOFLAGS, null) < 0) return error.SoundServerUnavailable;
    defer c.pa_context_disconnect(ctx);

    while (true) {
        switch (c.pa_context_get_state(ctx)) {
            c.PA_CONTEXT_READY => break,
            c.PA_CONTEXT_FAILED, c.PA_CONTEXT_TERMINATED => return error.SoundServerUnavailable,
            else => if (c.pa_mainloop_iterate(ml, 1, null) < 0) return error.SoundServerUnavailable,
        }
    }

    var collect: Collect = .{ .gpa = gpa };
    errdefer {
        for (collect.list.items) |s| {
            gpa.free(s.name);
            gpa.free(s.description);
        }
        collect.list.deinit(gpa);
    }
    const op = c.pa_context_get_source_info_list(ctx, &Collect.onSource, &collect) orelse return error.SoundServerUnavailable;
    defer c.pa_operation_unref(op);
    while (c.pa_operation_get_state(op) == c.PA_OPERATION_RUNNING) {
        if (c.pa_mainloop_iterate(ml, 1, null) < 0) return error.SoundServerUnavailable;
    }
    if (collect.failed) |err| return err;

    const list = try collect.list.toOwnedSlice(gpa);
    std.mem.sort(common.Source, list, {}, struct {
        fn lessThan(_: void, a: common.Source, b: common.Source) bool {
            return !a.monitor and b.monitor;
        }
    }.lessThan);
    return list;
}

const Collect = struct {
    gpa: std.mem.Allocator,
    list: std.ArrayList(common.Source) = .empty,
    failed: ?anyerror = null,

    fn onSource(_: ?*c.pa_context, info: [*c]const c.pa_source_info, eol: c_int, userdata: ?*anyopaque) callconv(.c) void {
        const self: *Collect = @ptrCast(@alignCast(userdata.?));
        if (eol != 0 or info == null or self.failed != null) return;
        self.append(info.*) catch |err| {
            self.failed = err;
        };
    }

    fn append(self: *Collect, info: c.pa_source_info) !void {
        const name = try self.gpa.dupeZ(u8, std.mem.span(info.name orelse return));
        errdefer self.gpa.free(name);
        const desc_c: [*c]const u8 = info.description orelse info.name;
        const description = try self.gpa.dupe(u8, std.mem.span(desc_c));
        errdefer self.gpa.free(description);
        try self.list.append(self.gpa, .{
            .name = name,
            .description = description,
            .monitor = info.monitor_of_sink != c.PA_INVALID_INDEX,
        });
    }
};

/// A capture stream delivering mono f32 samples at the requested rate.
/// `read` blocks until the buffer is full; `read` and `close` must be called
/// from the same thread (libpulse's simple API is not thread-safe).
pub const Stream = struct {
    handle: *c.pa_simple,

    /// Open `source` (a `Source.name`; null = the default input).
    /// `app_name` is shown in the system's sound settings.
    pub fn open(source: ?[:0]const u8, app_name: [:0]const u8, rate: u32) !Stream {
        const spec: c.pa_sample_spec = .{ .format = c.PA_SAMPLE_FLOAT32LE, .rate = rate, .channels = 1 };
        // ~100 ms fragments: low latency without waking up too often.
        const attr: c.pa_buffer_attr = .{
            .maxlength = std.math.maxInt(u32),
            .tlength = std.math.maxInt(u32),
            .prebuf = std.math.maxInt(u32),
            .minreq = std.math.maxInt(u32),
            .fragsize = rate / 10 * @sizeOf(f32),
        };
        var err: c_int = 0;
        const handle = c.pa_simple_new(null, app_name.ptr, c.PA_STREAM_RECORD, if (source) |s| s.ptr else null, "capture", &spec, null, &attr, &err) orelse {
            log.warn("cannot open {s}: {s}", .{ source orelse "default input", std.mem.span(c.pa_strerror(err)) });
            return error.OpenFailed;
        };
        return .{ .handle = handle };
    }

    /// Fill `samples` completely (blocks).
    pub fn read(self: *Stream, samples: []f32) !void {
        var err: c_int = 0;
        if (c.pa_simple_read(self.handle, samples.ptr, samples.len * @sizeOf(f32), &err) < 0) {
            log.warn("read failed: {s}", .{std.mem.span(c.pa_strerror(err))});
            return error.ReadFailed;
        }
    }

    pub fn close(self: *Stream) void {
        c.pa_simple_free(self.handle);
    }
};

pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    const sources = listSources(gpa) catch |err| return .{
        .module = "audio_capture",
        .ok = false,
        .detail = try std.fmt.allocPrint(gpa, "libpulse: {s}", .{@errorName(err)}),
    };
    defer common.freeSources(gpa, sources);
    var monitors: usize = 0;
    for (sources) |s| monitors += @intFromBool(s.monitor);
    return .{
        .module = "audio_capture",
        .ok = true,
        .detail = try std.fmt.allocPrint(gpa, "libpulse: {d} inputs, {d} system-audio monitors", .{ sources.len - monitors, monitors }),
    };
}
