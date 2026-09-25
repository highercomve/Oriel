//! `oriel`: the Oriel command-line tool.
//!
//!     oriel init <name> [--template react|vue|svelte|vanilla] ...
//!     oriel doctor
//!     oriel dev | build | run | package | types | check [zig build args...]
//!     oriel zig install | uninstall | list | which [version]
//!
//! A standalone static program (no GTK), built with `zig build cli`.

const std = @import("std");
const build_options = @import("build_options");
const args = @import("args.zig");
const Context = @import("Context.zig");
const init_cmd = @import("init.zig");
const doctor = @import("doctor.zig");
const project = @import("project.zig");
const update_cmd = @import("update.zig");
const webview2_cmd = @import("webview2.zig");
const deep_link_cmd = @import("deep_link.zig");
const zig_cmd = @import("zig_manager.zig");
const setup_cmd = @import("setup.zig");

const program = "oriel";

pub const Commands = union(enum) {
    init: init_cmd.Command,
    doctor: doctor.Command,
    setup: setup_cmd.Command,
    update: update_cmd.Command,
    webview2: webview2_cmd.Command,
    deep_link: deep_link_cmd.Command,
    zig: zig_cmd.Command,
    dev: project.Wrapper("dev", "Run the app against the frontend dev server, with hot reload"),
    build: project.Wrapper(null, "Build the app (frontend embedded) into zig-out/bin"),
    run: project.Wrapper("run", "Build and run the app"),
    package: project.Wrapper("package", "Build packages into zig-out/package (deb, rpm, AppImage; setup.exe; .app, .dmg)"),
    types: project.Wrapper("types", "Regenerate the frontend's TypeScript types for the Zig commands"),
    check: project.Wrapper("check", "Type-check the app's Zig code without building"),
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();

    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buf);
    var err_buf: [1024]u8 = undefined;
    var err = std.Io.File.stderr().writerStreaming(io, &err_buf);
    const ctx: Context = .{
        .gpa = init.gpa,
        .io = io,
        .environ = init.environ_map,
        .out = &out.interface,
        .err = &err.interface,
    };
    defer ctx.flush();
    // Windows: an update renames the running oriel.exe to oriel.exe.old;
    // remove it now that it isn't running. (No-op on Linux and macOS.)
    @import("updater_core").backend.cleanupStale(io, init.gpa);

    // Portable argv (WTF-16 on Windows, so not `args.vector`).
    const all_args = try init.minimal.args.toSlice(arena);
    const argv = try arena.alloc([]const u8, all_args.len -| 1);
    for (argv, 1..) |*a, i| a.* = all_args[i];

    return dispatch(ctx, argv) catch |e| {
        ctx.err.print("error: {s}\n", .{@errorName(e)}) catch {};
        return 1;
    };
}

fn dispatch(ctx: Context, argv: []const []const u8) !u8 {
    var diag: args.Diagnostic = .{};
    const parsed = args.parse(Commands, argv, &diag) catch {
        try ctx.err.print("error: {s}\n", .{diag.message()});
        if (diag.command) |c|
            try ctx.err.print("Run '" ++ program ++ " {s} --help' for usage.\n", .{c})
        else
            try ctx.err.writeAll("Run '" ++ program ++ " --help' for usage.\n");
        return 2;
    };
    switch (parsed) {
        .version => {
            try ctx.out.print(program ++ " {s}\nscaffolds Oriel {s}#{s}\n", .{ build_options.version, init_cmd.repo_url, build_options.oriel_ref });
            return 0;
        },
        .help => |tag| {
            if (tag) |t| try args.writeCommandHelp(Commands, program, t, ctx.out) else try args.writeHelp(Commands, program, ctx.out);
            return 0;
        },
        .command => |cmd| switch (cmd) {
            .init => |c| return init_cmd.run(ctx, c),
            .doctor => return doctor.run(ctx),
            .setup => |c| return setup_cmd.run(ctx, c),
            .update => |c| return update_cmd.run(ctx, c),
            .webview2 => |c| return webview2_cmd.run(ctx, c),
            .deep_link => |c| return deep_link_cmd.run(ctx, c),
            .zig => |c| return zig_cmd.run(ctx, c),
            inline else => |c| return project.exec(ctx, @TypeOf(c).zig_step, c.args),
        },
    }
}

test {
    _ = args;
    _ = Context;
    _ = init_cmd;
    _ = doctor;
    _ = setup_cmd;
    _ = update_cmd;
    _ = webview2_cmd;
    _ = deep_link_cmd;
    _ = zig_cmd;
    _ = project;
    _ = @import("template.zig");
}

test "command table" {
    var diag: args.Diagnostic = .{};
    const r = try args.parse(Commands, &.{ "run", "--", "--verbose" }, &diag);
    try std.testing.expectEqual(2, r.command.run.args.len);
    try std.testing.expectEqualStrings("run", @TypeOf(r.command.run).zig_step.?);
    try std.testing.expectEqual(null, @TypeOf(r.command.build).zig_step);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try args.writeHelp(Commands, program, &out.writer);
    for ([_][]const u8{ "init", "doctor", "setup", "update", "webview2", "deep-link", "zig", "dev", "build", "run", "package", "types", "check" }) |name| {
        const line = try std.fmt.allocPrint(std.testing.allocator, "\n  {s} ", .{name});
        defer std.testing.allocator.free(line);
        try std.testing.expect(std.mem.indexOf(u8, out.written(), line) != null);
    }
    out.clearRetainingCapacity();
    try args.writeCommandHelp(Commands, program, .init, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "--template <react|vue|svelte|vanilla>") != null);
}
