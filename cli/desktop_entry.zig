//! `oriel desktop-entry`: install (or remove) the app's desktop entry and
//! icons in `$XDG_DATA_HOME` for local runs on Linux.
//!
//! Installed packages ship a .desktop file; a build run from `zig-out` has
//! none, and some desktop features need one: the GlobalShortcuts portal
//! (global hotkeys on Wayland) only registers apps it can find, and the app
//! menu, notifications and deep links use it too.
//!
//!     oriel desktop-entry            the dev build (`<id>.Dev`), or the production build
//!     oriel desktop-entry --release  the production build (`<id>`, `oriel build`)
//!     oriel desktop-entry --remove   remove both

const std = @import("std");
const builtin = @import("builtin");
const Context = @import("Context.zig");
const project = @import("project.zig");
const deep_link = @import("deep_link.zig");

pub const Command = struct {
    pub const summary = "Install the app's desktop entry for local runs (Linux: global hotkeys, app menu)";
    pub const forward = "args";
    args: []const []const u8 = &.{},
};

const usage =
    \\Usage: oriel desktop-entry [--release | --remove] [zig build args...]
    \\
    \\Installs $XDG_DATA_HOME/applications/<id>.desktop and the app's icons for
    \\the build in zig-out, so the desktop knows the app when it runs from there:
    \\global hotkeys (the GlobalShortcuts portal needs it on Wayland), the app
    \\menu, notifications. Installed packages ship their own.
    \\
    \\  (no flag)   the dev build (<id>.Dev, used by `oriel dev`), or the
    \\              production build when the app has no dev mode
    \\  --release   the production build (<id>, used by `oriel build` / `oriel run`)
    \\  --remove    remove both entries and their icons
    \\
;

pub fn run(ctx: Context, cmd: Command) !u8 {
    var release = false;
    var remove = false;
    var rest: std.ArrayList([]const u8) = .empty;
    defer rest.deinit(ctx.gpa);
    for (cmd.args) |a| {
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            try ctx.out.writeAll(usage);
            return 0;
        } else if (std.mem.eql(u8, a, "--release")) {
            release = true;
        } else if (std.mem.eql(u8, a, "--remove")) {
            remove = true;
        } else try rest.append(ctx.gpa, a);
    }
    if (builtin.os.tag != .linux) {
        try ctx.out.print("Not needed on {s}: the app registers itself (hotkeys work without a desktop entry).\n", .{@tagName(builtin.os.tag)});
        return 0;
    }
    if (remove) return removeEntries(ctx);
    return project.exec(ctx, if (release) "desktop-entry-release" else "desktop-entry", rest.items);
}

fn removeEntries(ctx: Context) !u8 {
    const cwd = try std.process.currentPathAlloc(ctx.io, ctx.gpa);
    defer ctx.gpa.free(cwd);
    const root = try project.findRoot(ctx.gpa, ctx.io, cwd) orelse {
        try ctx.err.print("error: no build.zig.zon in {s} or any parent directory; run this inside an Oriel app\n", .{cwd});
        return 1;
    };
    defer ctx.gpa.free(root);
    const build_zig = try std.fs.path.join(ctx.gpa, &.{ root, "build.zig" });
    defer ctx.gpa.free(build_zig);
    const text = std.Io.Dir.cwd().readFileAlloc(ctx.io, build_zig, ctx.gpa, .limited(10 * 1024 * 1024)) catch |err| {
        try ctx.err.print("error: could not read {s}: {s}\n", .{ build_zig, @errorName(err) });
        return 1;
    };
    defer ctx.gpa.free(text);
    const app_id = deep_link.parseAppIdFromBuildZig(ctx.gpa, text) orelse {
        try ctx.err.writeAll("error: could not find the app id (`.id = \"...\"`) in build.zig\n");
        return 1;
    };
    defer ctx.gpa.free(app_id);

    const data_home = if (ctx.environ.get("XDG_DATA_HOME")) |x| (if (x.len > 0 and std.fs.path.isAbsolute(x)) try ctx.gpa.dupe(u8, x) else null) else null;
    const home_data = data_home orelse if (ctx.environ.get("HOME")) |h| try std.fmt.allocPrint(ctx.gpa, "{s}/.local/share", .{h}) else {
        try ctx.err.writeAll("error: neither XDG_DATA_HOME nor HOME is set\n");
        return 1;
    };
    defer ctx.gpa.free(home_data);

    var removed: usize = 0;
    const dev_id = try std.fmt.allocPrint(ctx.gpa, "{s}.Dev", .{app_id});
    defer ctx.gpa.free(dev_id);
    const sizes = [_][]const u8{ "16x16", "32x32", "48x48", "64x64", "128x128", "256x256", "512x512" };
    for ([_][]const u8{ app_id, dev_id }) |id| {
        const desktop = try std.fmt.allocPrint(ctx.gpa, "{s}/applications/{s}.desktop", .{ home_data, id });
        defer ctx.gpa.free(desktop);
        if (std.Io.Dir.cwd().deleteFile(ctx.io, desktop)) |_| {
            removed += 1;
            try ctx.out.print("Removed {s}\n", .{desktop});
        } else |_| {}
        for (sizes) |sz| {
            const icon = try std.fmt.allocPrint(ctx.gpa, "{s}/icons/hicolor/{s}/apps/{s}.png", .{ home_data, sz, id });
            defer ctx.gpa.free(icon);
            std.Io.Dir.cwd().deleteFile(ctx.io, icon) catch {};
        }
    }
    if (removed == 0) try ctx.out.print("No desktop entry for {s} in {s}/applications\n", .{ app_id, home_data });
    return 0;
}
