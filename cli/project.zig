//! `oriel dev | build | run | package | types | check`: thin wrappers around
//! `zig build <step>` that work from anywhere inside an app.

const std = @import("std");
const Context = @import("Context.zig");

/// A command that runs `zig build [step] <args...>` in the project root.
/// `step` null is plain `zig build` (the install step).
pub fn Wrapper(comptime step: ?[]const u8, comptime what: []const u8) type {
    return struct {
        pub const summary = what;
        pub const zig_step = step;
        pub const forward = "args";
        pub const details = "Runs `zig build" ++ (if (step) |s| " " ++ s else "") ++ " [args...]` in the project root " ++
            "(the nearest directory above with a build.zig.zon);\nevery argument is passed on, " ++
            "e.g. -Doptimize=ReleaseFast, or `-- <app args>` for run/dev.";
        args: []const []const u8 = &.{},
    };
}

/// The nearest directory at or above `start` (absolute) that contains a
/// build.zig.zon. Caller owns the result.
pub fn findRoot(gpa: std.mem.Allocator, io: std.Io, start: []const u8) !?[]u8 {
    var dir: ?[]const u8 = start;
    while (dir) |d| : (dir = std.fs.path.dirname(d)) {
        const zon = try std.fs.path.join(gpa, &.{ d, "build.zig.zon" });
        defer gpa.free(zon);
        std.Io.Dir.cwd().access(io, zon, .{}) catch continue;
        return try gpa.dupe(u8, d);
    }
    return null;
}

/// Replace this process with `zig build [step] args...` in the project
/// root, so signals (Ctrl-C in `oriel dev`) and the exit code are zig's.
/// Only returns on failure (on Windows: runs zig and returns its exit code).
pub fn exec(ctx: Context, step: ?[]const u8, args: []const []const u8) !u8 {
    const cwd = try std.process.currentPathAlloc(ctx.io, ctx.gpa);
    defer ctx.gpa.free(cwd);
    const root = try findRoot(ctx.gpa, ctx.io, cwd) orelse {
        try ctx.err.print("error: no build.zig.zon in {s} or any parent directory; run this inside an Oriel app (see `oriel init`)\n", .{cwd});
        return 1;
    };
    defer ctx.gpa.free(root);

    // A wrong Zig fails deep inside the build with confusing errors: say so
    // up front. (If it can't run at all, `replace` below reports that.)
    const zig = ctx.zig();
    if (ctx.capture(&.{ zig, "version" }, 30_000)) |v| {
        defer v.deinit(ctx.gpa);
        if (v.code == 0 and !Context.zigVersionOk(v.text())) {
            try ctx.err.print("error: '{s}' is Zig {s}, Oriel needs 0.16.x; set ORIEL_ZIG=/path/to/zig-0.16\n", .{ zig, v.text() });
            return 1;
        }
    }

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(ctx.gpa);
    try argv.appendSlice(ctx.gpa, &.{ zig, "build" });
    if (step) |s| try argv.append(ctx.gpa, s);
    try argv.appendSlice(ctx.gpa, args);

    // Windows can't replace a process: run zig as a child instead (Ctrl-C
    // reaches both, as they share the console) and pass its exit code on.
    if (!std.process.can_replace) {
        return ctx.run(argv.items, root) orelse {
            if (try ctx.findExecutable(zig)) |found| ctx.gpa.free(found) else try ctx.err.writeAll("Install Zig 0.16 or set ORIEL_ZIG; `oriel doctor` checks the setup.\n");
            return 1;
        };
    }

    std.process.setCurrentPath(ctx.io, root) catch |e| {
        try ctx.err.print("error: cannot enter {s}: {s}\n", .{ root, @errorName(e) });
        return 1;
    };
    ctx.flush();
    const e = std.process.replace(ctx.io, .{ .argv = argv.items });
    try ctx.err.print("error: could not run '{s}': {s}\n", .{ argv.items[0], Context.spawnErrorText(e) });
    if (e == error.FileNotFound) try ctx.err.writeAll("Install Zig 0.16 or set ORIEL_ZIG; `oriel doctor` checks the setup.\n");
    return 1;
}

test findRoot {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "app/frontend/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "app/build.zig.zon", .data = ".{}" });
    const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base);

    const deep = try std.fs.path.join(gpa, &.{ base, "app", "frontend", "src" });
    defer gpa.free(deep);
    const root = (try findRoot(gpa, io, deep)).?;
    defer gpa.free(root);
    const expected = try std.fs.path.join(gpa, &.{ base, "app" });
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, root);

    // Above the app there is no build.zig.zon (unless the tmp dir sits in a
    // Zig project, which is where tests run: skip past it).
    const outside = try findRoot(gpa, io, base);
    defer if (outside) |o| gpa.free(o);
    if (outside) |o| try std.testing.expect(!std.mem.startsWith(u8, o, expected));
}
