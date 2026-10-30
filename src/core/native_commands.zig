//! A native-renderer page's command (-Dnative_ui, docs/native-renderer.md),
//! answered the same way on every platform: the window commands, the
//! command policy, the renderer's own commands (`drop:path`), Oriel's
//! built-ins, then the app's sync commands. Each platform's bridge finds
//! the window, calls `dispatch`, and adds only its async path and its reply.

const std = @import("std");
const App = @import("App.zig");
const ipc = @import("ipc.zig");
const security = @import("security.zig");
const window_commands = @import("window_commands.zig");

const log = std.log.scoped(.oriel);

/// The command's answer (JSON), or null when it is one of the app's async
/// commands: the bridge runs it on the worker pool. `engine` is the page's
/// `*native_ui.Engine` (its drop table answers `drop:path`).
pub fn dispatch(
    comptime api: App.Api,
    comptime config: App.Config,
    comptime local: security.Local,
    engine: anytype,
    arena: std.mem.Allocator,
    page_url: []const u8,
    label: []const u8,
    request: ipc.Request,
    args_json: []const u8,
    io: ?std.Io,
) ?anyerror![]const u8 {
    const cmd = request.cmd;
    if (window_commands.isWindowCommand(cmd))
        return window_commands.dispatch(config.security, local, arena, page_url, label, cmd, request.args);
    if (!security.commandAllowedForWindow(config.security, local, page_url, cmd, label)) {
        log.warn("native page: blocked command \"{f}\" (window: {s})", .{ std.zig.fmtString(cmd[0..@min(cmd.len, 64)]), label });
        return error.Forbidden;
    }
    // A dropped file's handle back to a path: only native pages hold drop
    // handles (a WebView's oriel.drop.path answers null without asking).
    if (std.mem.eql(u8, cmd, "drop:path")) return engine.dropPathCommand(arena, args_json);
    // A file the user picked for an <input type=file> (nui:pick_file's token).
    if (std.mem.eql(u8, cmd, "nui:picked_file")) return engine.pickedFileCommand(arena, args_json);
    if (ipc.isBuiltinCommand(cmd)) return ipc.dispatchBuiltin(config.security, arena, request);
    if (!ipc.isAsync(api.commands, cmd)) return ipc.dispatchRequest(api.commands, arena, request, io);
    return null;
}
