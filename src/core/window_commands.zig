//! Built-in window IPC commands for Oriel.
//!
//! Provides backend command dispatch for `oriel.window` API from JavaScript:
//!   - open: create and show a new window (App.openWindow)
//!   - close: request window closure (App.postCloseWindow)
//!   - show/hide/focus: manipulate window visibility and focus
//!   - setTitle/setSize/maximize/fullscreen: update window geometry & state
//!   - get/all/current: query window information
//!   - emitTo: send events targeted to a specific window
//!
//! Enforces security policies (validation of labels, URLs, window limits,
//! and per-window modification permissions).

const std = @import("std");
const App = @import("App.zig");
const security = @import("security.zig");

const log = std.log.scoped(.oriel);

pub const OpenArgs = struct {
    label: []const u8,
    url: ?[]const u8 = null,
    title: ?[]const u8 = null,
    width: ?c_int = null,
    height: ?c_int = null,
    min_width: ?c_int = null,
    min_height: ?c_int = null,
    max_width: ?c_int = null,
    max_height: ?c_int = null,
    minWidth: ?c_int = null,
    minHeight: ?c_int = null,
    maxWidth: ?c_int = null,
    maxHeight: ?c_int = null,
    resizable: ?bool = null,
    decorations: ?bool = null,
    fullscreen: ?bool = null,
    maximized: ?bool = null,
};

pub const WindowInfo = struct {
    label: []const u8,
    title: []const u8,
};

pub fn isWindowCommand(cmd: []const u8) bool {
    return std.mem.startsWith(u8, cmd, "oriel:window:");
}

pub fn dispatch(
    sec: security.Security,
    local: security.Local,
    arena: std.mem.Allocator,
    page_url: []const u8,
    caller_win_label: ?[]const u8,
    cmd: []const u8,
    args_val: std.json.Value,
) ![]u8 {
    if (!isWindowCommand(cmd)) return error.UnknownCommand;

    if (!security.isWindowApiAllowed(sec, local, page_url, caller_win_label)) {
        log.debug("blocked window command '{s}' from {s} (window: {?s})", .{ cmd, page_url, caller_win_label });
        return error.Forbidden;
    }

    const action = cmd["oriel:window:".len..];

    if (std.mem.eql(u8, action, "open")) {
        const args = try std.json.parseFromValueLeaky(OpenArgs, arena, args_val, .{
            .ignore_unknown_fields = true,
        });
        try security.validateLabel(args.label);
        try security.validateWindowUrl(sec, local, args.url);
        try security.validateWindowCount(sec, App.getWindowCount());

        const label_z = try arena.dupeZ(u8, args.label);
        const title_z = if (args.title) |t| try arena.dupeZ(u8, t) else try arena.dupeZ(u8, "");
        const url_z = if (args.url) |u| try arena.dupeZ(u8, u) else null;

        const win = try App.openWindow(.{
            .label = label_z,
            .title = title_z,
            .url = url_z,
            .width = args.width orelse 800,
            .height = args.height orelse 600,
            .min_width = args.min_width orelse args.minWidth,
            .min_height = args.min_height orelse args.minHeight,
            .max_width = args.max_width orelse args.maxWidth,
            .max_height = args.max_height orelse args.maxHeight,
            .resizable = args.resizable orelse true,
            .decorations = args.decorations orelse true,
            .fullscreen = args.fullscreen orelse false,
            .maximized = args.maximized orelse false,
        });

        return std.json.Stringify.valueAlloc(arena, struct { label: []const u8 }{ .label = win.label }, .{});
    } else if (std.mem.eql(u8, action, "close")) {
        const args = try std.json.parseFromValueLeaky(struct { label: []const u8 }, arena, args_val, .{
            .ignore_unknown_fields = true,
        });
        try security.validateLabel(args.label);
        try security.validateWindowModification(sec, caller_win_label, args.label);
        try App.postCloseWindow(args.label);
        return arena.dupe(u8, "null");
    } else if (std.mem.eql(u8, action, "show")) {
        const args = try std.json.parseFromValueLeaky(struct { label: []const u8 }, arena, args_val, .{
            .ignore_unknown_fields = true,
        });
        try security.validateLabel(args.label);
        try security.validateWindowModification(sec, caller_win_label, args.label);
        const win = App.getWindow(args.label) orelse return error.WindowNotFound;
        win.show();
        return arena.dupe(u8, "null");
    } else if (std.mem.eql(u8, action, "hide")) {
        const args = try std.json.parseFromValueLeaky(struct { label: []const u8 }, arena, args_val, .{
            .ignore_unknown_fields = true,
        });
        try security.validateLabel(args.label);
        try security.validateWindowModification(sec, caller_win_label, args.label);
        const win = App.getWindow(args.label) orelse return error.WindowNotFound;
        win.hide();
        return arena.dupe(u8, "null");
    } else if (std.mem.eql(u8, action, "focus")) {
        const args = try std.json.parseFromValueLeaky(struct { label: []const u8 }, arena, args_val, .{
            .ignore_unknown_fields = true,
        });
        try security.validateLabel(args.label);
        try security.validateWindowModification(sec, caller_win_label, args.label);
        const win = App.getWindow(args.label) orelse return error.WindowNotFound;
        win.focus();
        return arena.dupe(u8, "null");
    } else if (std.mem.eql(u8, action, "setTitle")) {
        const args = try std.json.parseFromValueLeaky(struct { label: []const u8, title: []const u8 }, arena, args_val, .{
            .ignore_unknown_fields = true,
        });
        try security.validateLabel(args.label);
        try security.validateWindowModification(sec, caller_win_label, args.label);
        const win = App.getWindow(args.label) orelse return error.WindowNotFound;
        const title_z = try arena.dupeZ(u8, args.title);
        win.setTitle(title_z);
        return arena.dupe(u8, "null");
    } else if (std.mem.eql(u8, action, "setSize")) {
        const args = try std.json.parseFromValueLeaky(struct { label: []const u8, width: c_int, height: c_int }, arena, args_val, .{
            .ignore_unknown_fields = true,
        });
        try security.validateLabel(args.label);
        try security.validateWindowModification(sec, caller_win_label, args.label);
        const win = App.getWindow(args.label) orelse return error.WindowNotFound;
        win.setSize(args.width, args.height);
        return arena.dupe(u8, "null");
    } else if (std.mem.eql(u8, action, "maximize")) {
        const args = try std.json.parseFromValueLeaky(struct { label: []const u8, maximized: ?bool = null }, arena, args_val, .{
            .ignore_unknown_fields = true,
        });
        try security.validateLabel(args.label);
        try security.validateWindowModification(sec, caller_win_label, args.label);
        const win = App.getWindow(args.label) orelse return error.WindowNotFound;
        win.setMaximized(args.maximized orelse true);
        return arena.dupe(u8, "null");
    } else if (std.mem.eql(u8, action, "fullscreen")) {
        const args = try std.json.parseFromValueLeaky(struct { label: []const u8, fullscreen: ?bool = null }, arena, args_val, .{
            .ignore_unknown_fields = true,
        });
        try security.validateLabel(args.label);
        try security.validateWindowModification(sec, caller_win_label, args.label);
        const win = App.getWindow(args.label) orelse return error.WindowNotFound;
        win.setFullscreen(args.fullscreen orelse true);
        return arena.dupe(u8, "null");
    } else if (std.mem.eql(u8, action, "get")) {
        const args = try std.json.parseFromValueLeaky(struct { label: []const u8 }, arena, args_val, .{
            .ignore_unknown_fields = true,
        });
        try security.validateLabel(args.label);
        App.ensureWindowsMutex();
        App.windows_mutex.lock();
        defer App.windows_mutex.unlock();
        for (App.windows_list.items) |w| {
            if (std.mem.eql(u8, w.label, args.label)) {
                return std.json.Stringify.valueAlloc(arena, WindowInfo{ .label = w.label, .title = w.options.title }, .{});
            }
        }
        return arena.dupe(u8, "null");
    } else if (std.mem.eql(u8, action, "all")) {
        App.ensureWindowsMutex();
        App.windows_mutex.lock();
        defer App.windows_mutex.unlock();
        var list: std.ArrayList(WindowInfo) = .empty;
        for (App.windows_list.items) |w| {
            try list.append(arena, .{ .label = w.label, .title = w.options.title });
        }
        return std.json.Stringify.valueAlloc(arena, list.items, .{});
    } else if (std.mem.eql(u8, action, "current")) {
        const label = caller_win_label orelse "main";
        App.ensureWindowsMutex();
        App.windows_mutex.lock();
        defer App.windows_mutex.unlock();
        for (App.windows_list.items) |w| {
            if (std.mem.eql(u8, w.label, label)) {
                return std.json.Stringify.valueAlloc(arena, WindowInfo{ .label = w.label, .title = w.options.title }, .{});
            }
        }
        return std.json.Stringify.valueAlloc(arena, WindowInfo{ .label = label, .title = "" }, .{});
    } else if (std.mem.eql(u8, action, "emitTo")) {
        const args = try std.json.parseFromValueLeaky(struct { label: []const u8, event: []const u8, payload: std.json.Value = .null }, arena, args_val, .{
            .ignore_unknown_fields = true,
        });
        try security.validateLabel(args.label);
        try App.emitTo(args.label, args.event, args.payload);
        return arena.dupe(u8, "null");
    }

    return error.UnknownCommand;
}

test "isWindowCommand recognises window commands" {
    try std.testing.expect(isWindowCommand("oriel:window:open"));
    try std.testing.expect(isWindowCommand("oriel:window:close"));
    try std.testing.expect(isWindowCommand("oriel:window:emitTo"));
    try std.testing.expect(!isWindowCommand("greet"));
    try std.testing.expect(!isWindowCommand("window:open"));
}

test "dispatch rejects forbidden origins and invalid commands" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sec: security.Security = .{};
    const local: security.Local = .{};

    // Remote origin without window capability is Forbidden
    try std.testing.expectError(error.Forbidden, dispatch(sec, local, arena, "https://unknown.com", null, "oriel:window:open", .null));

    // Unknown action
    try std.testing.expectError(error.UnknownCommand, dispatch(sec, local, arena, security.app_origin, null, "oriel:window:nonexistent", .null));
}
