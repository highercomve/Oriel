//! oriel: a Tauri-like desktop framework for Zig.
//!
//! Core (always on): GTK4 window + WebKitGTK 6.0 webview, `app://` asset
//! scheme, JS <-> Zig IPC. Built-in modules and plugins are opt-in via
//! `-D<name>=false|true` build options; disabled ones are not even compiled.

const std = @import("std");
pub const options = @import("build_options");

pub const App = @import("core/App.zig");
pub const ipc = @import("core/ipc.zig");
pub const security = @import("core/security.zig");
pub const log = @import("core/log.zig");
pub const platform = @import("platform/platform.zig");

// Built-in modules.
pub const tray = if (options.tray) @import("modules/tray.zig") else struct {};
pub const updater = if (options.updater) @import("modules/updater.zig") else struct {};
pub const media_server = if (options.media_server) @import("modules/media_server.zig") else struct {};
pub const sql = if (options.sql) @import("modules/sql.zig") else struct {};
pub const fs_watch = if (options.fs_watch) @import("modules/fs_watch.zig") else struct {};
pub const dialog = if (options.dialog) @import("modules/dialog.zig") else struct {};
pub const notification = if (options.notification) @import("modules/notification.zig") else struct {};
pub const store = if (options.store) @import("modules/store.zig") else struct {};
pub const menu = if (options.menu) @import("modules/menu.zig") else struct {};

// App-specific plugins.
pub const global_shortcut = if (options.global_shortcut) @import("plugins/global_shortcut.zig") else struct {};
pub const input = if (options.input) @import("plugins/input.zig") else struct {};
pub const clipboard = if (options.clipboard) @import("plugins/clipboard.zig") else struct {};

pub const ThreadPool = @import("core/ThreadPool.zig").ThreadPool;

/// Standard entry point for a oriel app:
///
///     pub fn main(init: std.process.Init) !u8 {
///         return oriel.main(init, .{ .commands = Commands, .events = Events }, .{
///             .id = "com.example.App", .title = "App", .assets = app.assets, .dev = app.dev,
///         });
///     }
///
/// Besides running the app, it handles `--emit-types <path>`, used by the
/// build to write the frontend's TypeScript bindings for the API.
pub fn main(init: std.process.Init, comptime api: App.Api, comptime config: App.Config) !u8 {
    if (options.updater) {
        try updater.init(init.io, init.gpa, init.environ_map);
    }
    defer if (options.updater) updater.deinit(init.io);

    const argv = init.minimal.args.vector;
    if (argv.len == 3 and std.mem.eql(u8, std.mem.span(argv[1]), "--emit-types")) {
        try writeTypes(init.io, init.gpa, api, std.mem.span(argv[2]));
        return 0;
    }
    return App.run(init.io, api, config);
}

/// Write the TypeScript bindings for `api` to `path`, leaving the file
/// untouched when nothing changed (so dev servers don't reload needlessly).
pub fn writeTypes(write_io: std.Io, gpa: std.mem.Allocator, comptime api: App.Api, path: []const u8) !void {
    const source = comptime ipc.typescript(api.commands, api.events);
    const cwd = std.Io.Dir.cwd();
    if (cwd.readFileAlloc(write_io, path, gpa, .limited(1 << 20))) |existing| {
        defer gpa.free(existing);
        if (std.mem.eql(u8, existing, source)) return;
    } else |_| {}
    if (std.fs.path.dirname(path)) |dir| try cwd.createDirPath(write_io, dir);
    try cwd.writeFile(write_io, .{ .sub_path = path, .data = source });
}

/// Result of a module smoke check, serialized to the frontend as JSON.
pub const Check = struct {
    module: []const u8,
    ok: bool,
    detail: []const u8,
};

pub const CheckContext = struct {
    io: std.Io,
    /// PNG used for the tray icon check.
    icon_png: []const u8,
    /// Port of a running media server, if one was started.
    media_port: ?u16 = null,
    /// App id for checks that talk to xdg-desktop-portal (it must have an
    /// installed `<app_id>.desktop`); defaults to the running GApplication's
    /// id or the program name.
    app_id: ?[:0]const u8 = null,
};

/// Run the smoke check of every enabled module and plugin.
pub fn checkAll(gpa: std.mem.Allocator, ctx: CheckContext) ![]Check {
    var checks: std.ArrayList(Check) = .empty;
    const Entry = struct { name: []const u8, enabled: bool };
    const entries = [_]Entry{
        .{ .name = "tray", .enabled = options.tray },
        .{ .name = "updater", .enabled = options.updater },
        .{ .name = "media_server", .enabled = options.media_server },
        .{ .name = "sql", .enabled = options.sql },
        .{ .name = "fs_watch", .enabled = options.fs_watch },
        .{ .name = "dialog", .enabled = options.dialog },
        .{ .name = "notification", .enabled = options.notification },
        .{ .name = "store", .enabled = options.store },
        .{ .name = "menu", .enabled = options.menu },
        .{ .name = "global_shortcut", .enabled = options.global_shortcut },
        .{ .name = "input", .enabled = options.input },
        .{ .name = "clipboard", .enabled = options.clipboard },
    };
    inline for (entries) |e| {
        if (e.enabled) {
            const module = @field(@This(), e.name);
            const check: Check = module.check(gpa, ctx) catch |err| .{
                .module = e.name,
                .ok = false,
                .detail = @errorName(err),
            };
            try checks.append(gpa, check);
        }
    }
    return checks.toOwnedSlice(gpa);
}

test {
    std.testing.refAllDecls(ipc);
    std.testing.refAllDecls(security);
    std.testing.refAllDecls(log);
    std.testing.refAllDecls(platform);
    std.testing.refAllDecls(@import("core/ThreadPool.zig"));
    if (options.tray) _ = tray;
    if (options.media_server) {
        std.testing.refAllDecls(media_server);
        std.testing.refAllDecls(@import("modules/media/range.zig"));
        std.testing.refAllDecls(@import("modules/media/open.zig"));
        std.testing.refAllDecls(@import("modules/media_scheme.zig"));
    }
    if (options.updater) {
        std.testing.refAllDecls(updater);
        std.testing.refAllDecls(@import("modules/update_manifest.zig"));
    }
    if (options.dialog) std.testing.refAllDecls(dialog);
    if (options.notification) std.testing.refAllDecls(notification);
    if (options.store) std.testing.refAllDecls(store);
    if (options.menu) std.testing.refAllDecls(menu);
    if (options.global_shortcut) std.testing.refAllDecls(global_shortcut);
    if (options.input) std.testing.refAllDecls(input);
    if (options.clipboard) std.testing.refAllDecls(clipboard);
}
