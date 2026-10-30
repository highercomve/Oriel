//! Persistent settings store: small JSON files of key/value settings in
//! the app's config directory (`oriel.paths.appConfig`; on Android its
//! `<app id>` folder). Directories for the app's other files are
//! `oriel.paths`.
//!
//! Linux backend: GLib file I/O.
//! Windows backend: Win32 file I/O.
//! macOS, iOS and Android backend: libc file I/O.

/// Built for this target (docs/modules.md, "Availability").
pub const available = true;

const std = @import("std");
const target = @import("../core/target.zig");
const App = @import("../core/App.zig");
const heap = @import("../core/heap.zig");
const log = std.log.scoped(.oriel);

pub const Store = impl.Store;
pub const check = impl.check;

const impl = switch (target.os) {
    .linux => @import("store/linux.zig"),
    .windows => @import("store/windows.zig"),
    .macos => @import("store/macos.zig"),
    .android => @import("store/android.zig"),
    .ios => @import("store/macos.zig"),
    .other => @compileError("store is not supported on " ++ target.name),
};

pub fn saveWindowGeometry(window: *App.Window) void {
    const size = window.getSize();
    var store = Store.open(heap.gpa, window.app_id, "window_geometry") catch return;
    defer store.deinit();

    var key_w_buf: [128]u8 = undefined;
    const key_w = std.fmt.bufPrint(&key_w_buf, "{s}_width", .{window.label}) catch return;
    store.set(key_w, size.width) catch |err| log.warn("saving {s}: {s}", .{ key_w, @errorName(err) });

    var key_h_buf: [128]u8 = undefined;
    const key_h = std.fmt.bufPrint(&key_h_buf, "{s}_height", .{window.label}) catch return;
    store.set(key_h, size.height) catch |err| log.warn("saving {s}: {s}", .{ key_h, @errorName(err) });

    var key_m_buf: [128]u8 = undefined;
    const key_m = std.fmt.bufPrint(&key_m_buf, "{s}_maximized", .{window.label}) catch return;
    store.set(key_m, window.isMaximized()) catch |err| log.warn("saving {s}: {s}", .{ key_m, @errorName(err) });
}

pub fn restoreWindowGeometry(window: *App.Window) void {
    var store = Store.open(heap.gpa, window.app_id, "window_geometry") catch return;
    defer store.deinit();

    var key_w_buf: [128]u8 = undefined;
    const key_w = std.fmt.bufPrint(&key_w_buf, "{s}_width", .{window.label}) catch return;
    const saved_w = store.getInt(key_w, c_int);

    var key_h_buf: [128]u8 = undefined;
    const key_h = std.fmt.bufPrint(&key_h_buf, "{s}_height", .{window.label}) catch return;
    const saved_h = store.getInt(key_h, c_int);

    if (saved_w != null and saved_h != null and saved_w.? > 0 and saved_h.? > 0) {
        window.setSize(saved_w.?, saved_h.?);
    }

    var key_m_buf: [128]u8 = undefined;
    const key_m = std.fmt.bufPrint(&key_m_buf, "{s}_maximized", .{window.label}) catch return;
    if (store.getBool(key_m)) |maximized| {
        if (maximized) window.setMaximized(true);
    }
}

test {
    std.testing.refAllDecls(@import("store/common.zig"));
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(impl);
}
