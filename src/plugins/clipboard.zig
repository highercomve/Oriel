//! Background clipboard access on Wayland (without window focus) via the
//! data-control protocols. Focused/X11 clipboard goes through GdkClipboard.

const std = @import("std");
const wayland = @import("wayland");
const gtk = @import("gtk");
const gdk = @import("gdk");
const glib = @import("glib");
const gobject = @import("gobject");
const gio = @import("gio");
const Globals = @import("wayland_globals.zig").Globals;
const ziguri = @import("../ziguri.zig");

var last_written_text: ?[]u8 = null;
var last_written_image: ?[]u8 = null;

const ExtOfferListener = struct {
    mime_types: std.ArrayList([]const u8),
    gpa: std.mem.Allocator,

    fn onOffer(_: *wayland.client.ext.DataControlOfferV1, event: wayland.client.ext.DataControlOfferV1.Event, self: *ExtOfferListener) void {
        const mime = self.gpa.dupe(u8, std.mem.span(event.offer.mime_type)) catch return;
        self.mime_types.append(self.gpa, mime) catch {
            self.gpa.free(mime);
        };
    }
};

const ExtDeviceListener = struct {
    current_offer: ?*wayland.client.ext.DataControlOfferV1 = null,

    fn onEvent(_: *wayland.client.ext.DataControlDeviceV1, event: wayland.client.ext.DataControlDeviceV1.Event, self: *ExtDeviceListener) void {
        switch (event) {
            .data_offer => {},
            .selection => |sel| {
                self.current_offer = sel.id;
            },
            .finished => {},
            .primary_selection => {},
        }
    }
};

fn readWayland(gpa: std.mem.Allocator, target_mime: []const u8) !?[]u8 {
    var globals: Globals = undefined;
    globals.init(gpa) catch return null;
    defer globals.deinit();

    const seat = (globals.bind(wayland.client.wl.Seat, 7) catch null) orelse return null;
    defer seat.destroy();

    if (globals.bind(wayland.client.ext.DataControlManagerV1, 1) catch null) |ext_mgr| {
        defer ext_mgr.destroy();
        const dev = ext_mgr.getDataDevice(seat) catch return null;
        defer dev.destroy();

        var dev_listener: ExtDeviceListener = .{};
        dev.setListener(*ExtDeviceListener, ExtDeviceListener.onEvent, &dev_listener);

        var offer_listener: ExtOfferListener = .{ .mime_types = .empty, .gpa = gpa };
        defer {
            for (offer_listener.mime_types.items) |m| gpa.free(m);
            offer_listener.mime_types.deinit(gpa);
        }

        if (globals.display.roundtrip() != .SUCCESS) return null;
        if (globals.display.roundtrip() != .SUCCESS) return null;

        const offer = dev_listener.current_offer orelse return null;
        offer.setListener(*ExtOfferListener, ExtOfferListener.onOffer, &offer_listener);
        if (globals.display.roundtrip() != .SUCCESS) return null;

        var matching_mime: ?[]const u8 = null;
        for (offer_listener.mime_types.items) |m| {
            if (std.mem.startsWith(u8, m, target_mime) or std.mem.eql(u8, m, target_mime)) {
                matching_mime = m;
                break;
            }
        }
        const match = matching_mime orelse return null;
        const match_z = (try gpa.dupeZ(u8, match));
        defer gpa.free(match_z);

        var pipe_fds: [2]c_int = undefined;
        if (std.c.pipe(&pipe_fds) != 0) return null;
        defer _ = std.c.close(pipe_fds[0]);

        offer.receive(match_z.ptr, pipe_fds[1]);
        _ = std.c.close(pipe_fds[1]);
        if (globals.display.roundtrip() != .SUCCESS) return null;

        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(gpa);
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = std.c.read(pipe_fds[0], &buf, buf.len);
            if (n <= 0) break;
            try list.appendSlice(gpa, buf[0..@intCast(n)]);
        }
        return try list.toOwnedSlice(gpa);
    }
    return null;
}

pub fn readGdkText(gpa: std.mem.Allocator) ![]u8 {
    _ = gtk.initCheck();
    const disp = gdk.Display.getDefault() orelse return error.NoDisplay;
    const cb = disp.getClipboard();

    const State = struct {
        loop: *glib.MainLoop,
        result: ?[]u8 = null,
        gpa: std.mem.Allocator,
    };
    const S = struct {
        fn onTextFinish(_: ?*gobject.Object, res: *gio.AsyncResult, user_data: ?*anyopaque) callconv(.c) void {
            const state: *State = @ptrCast(@alignCast(user_data));
            const d = gdk.Display.getDefault() orelse {
                state.loop.quit();
                return;
            };
            const c = d.getClipboard();
            var err: ?*glib.Error = null;
            const str = gdk.Clipboard.readTextFinish(c, res, &err);
            if (str) |s| {
                state.result = state.gpa.dupe(u8, std.mem.span(s)) catch null;
                glib.free(s);
            }
            state.loop.quit();
        }
    };

    const loop = glib.MainLoop.new(null, 0);
    defer loop.unref();

    var state = State{ .loop = loop, .gpa = gpa };
    gdk.Clipboard.readTextAsync(cb, null, &S.onTextFinish, &state);
    loop.run();

    return state.result orelse try gpa.dupe(u8, "");
}

pub fn writeGdkText(text: []const u8) !void {
    _ = gtk.initCheck();
    const disp = gdk.Display.getDefault() orelse return error.NoDisplay;
    const cb = disp.getClipboard();

    const text_z = try std.heap.c_allocator.dupeZ(u8, text);
    defer std.heap.c_allocator.free(text_z);

    gdk.Clipboard.setText(cb, text_z.ptr);
}

pub fn readGdkImage(gpa: std.mem.Allocator) !?[]u8 {
    _ = gtk.initCheck();
    const disp = gdk.Display.getDefault() orelse return error.NoDisplay;
    const cb = disp.getClipboard();

    const State = struct {
        loop: *glib.MainLoop,
        result: ?[]u8 = null,
        gpa: std.mem.Allocator,
    };
    const S = struct {
        fn onImageFinish(_: ?*gobject.Object, res: *gio.AsyncResult, user_data: ?*anyopaque) callconv(.c) void {
            const state: *State = @ptrCast(@alignCast(user_data));
            const d = gdk.Display.getDefault() orelse {
                state.loop.quit();
                return;
            };
            const c = d.getClipboard();
            var err: ?*glib.Error = null;
            const texture = gdk.Clipboard.readTextureFinish(c, res, &err);
            if (texture) |tex| {
                defer tex.unref();
                const png_bytes = tex.saveToPngBytes();
                defer png_bytes.unref();
                var size: usize = 0;
                if (png_bytes.getData(&size)) |ptr| {
                    state.result = state.gpa.dupe(u8, ptr[0..size]) catch null;
                }
            }
            state.loop.quit();
        }
    };

    const loop = glib.MainLoop.new(null, 0);
    defer loop.unref();

    var state = State{ .loop = loop, .gpa = gpa };
    gdk.Clipboard.readTextureAsync(cb, null, &S.onImageFinish, &state);
    loop.run();

    return state.result;
}

pub fn writeGdkImage(png_bytes: []const u8) !void {
    _ = gtk.initCheck();
    const disp = gdk.Display.getDefault() orelse return error.NoDisplay;
    const cb = disp.getClipboard();

    const bytes = glib.Bytes.new(png_bytes.ptr, png_bytes.len);
    defer bytes.unref();

    var err: ?*glib.Error = null;
    const texture = gdk.Texture.newFromBytes(bytes, &err) orelse {
        if (err) |e| e.free();
        return error.TextureNew;
    };
    defer texture.unref();

    gdk.Clipboard.setTexture(cb, texture);
}

/// Read text from the system clipboard.
pub fn readText(gpa: std.mem.Allocator) ![]u8 {
    const is_wayland = std.c.getenv("WAYLAND_DISPLAY") != null;
    if (is_wayland) {
        if (try readWayland(gpa, "text/plain")) |wl_text| {
            return wl_text;
        }
    }
    return readGdkText(gpa);
}

/// Write text to the system clipboard.
pub fn writeText(text: []const u8) !void {
    try writeGdkText(text);
}

/// Read a PNG image from the system clipboard, or null if none available.
pub fn readImage(gpa: std.mem.Allocator) !?[]u8 {
    const is_wayland = std.c.getenv("WAYLAND_DISPLAY") != null;
    if (is_wayland) {
        if (try readWayland(gpa, "image/png")) |wl_img| {
            return wl_img;
        }
    }
    return readGdkImage(gpa);
}

/// Write a PNG image to the system clipboard.
pub fn writeImage(png_bytes: []const u8) !void {
    try writeGdkImage(png_bytes);
}

pub fn check(gpa: std.mem.Allocator, _: ziguri.CheckContext) !ziguri.Check {
    var globals: Globals = undefined;
    const wayland_ok = if (globals.init(gpa)) |_| true else |_| false;
    defer if (wayland_ok) globals.deinit();

    var protocol: []const u8 = "none";
    if (wayland_ok) {
        if (try globals.bind(wayland.client.ext.DataControlManagerV1, 1)) |m| {
            protocol = "ext_data_control_manager_v1";
            m.destroy();
        } else if (try globals.bind(wayland.client.zwlr.DataControlManagerV1, 2)) |m| {
            protocol = "zwlr_data_control_manager_v1";
            m.destroy();
        }
    }

    const gdk_ok = gtk.initCheck() != 0;

    return .{
        .module = "clipboard",
        .ok = !std.mem.eql(u8, protocol, "none") or gdk_ok,
        .detail = if (!std.mem.eql(u8, protocol, "none"))
            try std.fmt.allocPrint(gpa, "background clipboard via {s}", .{protocol})
        else if (gdk_ok)
            try std.fmt.allocPrint(gpa, "focused clipboard via GdkClipboard (X11)", .{})
        else
            try std.fmt.allocPrint(gpa, "no clipboard backend available", .{}),
    };
}

test "clipboard roundtrip x11 under xvfb" {
    if (std.c.getenv("ZIGURI_HEADLESS_INNER") == null) return;
    if (gtk.initCheck() == 0) return;

    const test_str = "ziguri clipboard test 12345";
    try writeGdkText(test_str);

    const result = try readGdkText(std.testing.allocator);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings(test_str, result);
}
