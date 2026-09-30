//! `oriel ios`: build an Oriel app for iOS and put it on a device.
//!
//!     oriel ios build [--simulator] [--ipa]
//!         The release app: zig-out/ios/<Name>.app (and zig-out/<Name>.ipa
//!         with --ipa), for a device (arm64) or the simulator.
//!     oriel ios dev [--simulator] [--url http://<LAN address>:5173/]
//!         The dev build (loading the dev server) installed and started:
//!         on the simulator with `xcrun simctl` (a Mac), on a device with
//!         `xtool install` (Linux or a Mac). Run the frontend's dev server
//!         yourself, listening on the LAN (`vite --host`).
//!     oriel ios install [--simulator] [--dev]
//!         Install the last build (release, or the dev build).
//!     oriel ios setup
//!         Set up what the others need: the iOS SDK and, for devices, xtool.
//!
//! Linking needs the iOS SDK: $APPLE_SDK, Xcode's on a Mac, or the one
//! `xtool setup` extracts from Xcode.xip on Linux. When the SDK or xtool is
//! missing, the commands offer to set it up, asking first (`--yes` accepts;
//! see ios_tools.zig). See docs/ios.md.

const std = @import("std");
const Context = @import("Context.zig");
const project = @import("project.zig");
const zig_manager = @import("zig_manager.zig");
const tools = @import("ios_tools.zig");

pub const Command = struct {
    pub const summary = "Build the app for iOS and install it (build, dev, install, setup)";
    pub const forward = "args";
    pub const details =
        \\  oriel ios build [--simulator] [--ipa]          zig-out/ios/<Name>.app (and .ipa)
        \\  oriel ios dev [--simulator] [--url URL]        dev build, installed and started
        \\  oriel ios install [--simulator] [--dev]        install the last build
        \\  oriel ios setup                                set up the iOS SDK and xtool
        \\
        \\Needs the iOS SDK ($APPLE_SDK, Xcode's on a Mac, `xtool setup` on Linux), and
        \\xtool (a device) or Xcode's simctl (the simulator). What's missing is offered
        \\for download or setup, asking first; --yes accepts. See docs/ios.md.
    ;
    args: []const []const u8 = &.{},
};

const Options = struct {
    simulator: bool = false,
    ipa: bool = false,
    dev: bool = false,
    url: ?[]const u8 = null,
    /// Accept the offers to download xtool or run `xtool setup`.
    yes: bool = false,
};

fn parse(ctx: Context, args: []const []const u8, allowed: []const []const u8) ?Options {
    var o: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const ok = std.mem.eql(u8, a, "--yes") or std.mem.eql(u8, a, "-y") or for (allowed) |name| {
            if (std.mem.eql(u8, a, name)) break true;
        } else false;
        if (!ok) {
            ctx.err.print("error: unknown option {s}\n", .{a}) catch {};
            return null;
        }
        if (std.mem.eql(u8, a, "--simulator")) o.simulator = true;
        if (std.mem.eql(u8, a, "--ipa")) o.ipa = true;
        if (std.mem.eql(u8, a, "--dev")) o.dev = true;
        if (std.mem.eql(u8, a, "--yes") or std.mem.eql(u8, a, "-y")) o.yes = true;
        if (std.mem.eql(u8, a, "--url")) {
            if (i + 1 >= args.len) {
                ctx.err.print("error: --url needs a value\n", .{}) catch {};
                return null;
            }
            i += 1;
            o.url = args[i];
        }
    }
    return o;
}

/// The simulator's architecture is the Mac's.
fn targetArg(simulator: bool) []const u8 {
    if (!simulator) return "-Dtarget=aarch64-ios";
    return if (@import("builtin").cpu.arch == .x86_64) "-Dtarget=x86_64-ios-simulator" else "-Dtarget=aarch64-ios-simulator";
}

pub fn runCommand(ctx: Context, cmd: Command) !u8 {
    const args = cmd.args;
    if (args.len == 0 or std.mem.eql(u8, args[0], "help") or std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h")) {
        try ctx.out.print("usage:\n{s}\n", .{Command.details});
        return if (args.len == 0) 1 else 0;
    }
    const sub = args[0];
    const rest = args[1..];

    const cwd = try std.process.currentPathAlloc(ctx.io, ctx.gpa);
    defer ctx.gpa.free(cwd);
    const root = try project.findRoot(ctx.gpa, ctx.io, cwd) orelse {
        try ctx.err.print("error: no build.zig.zon in {s} or any parent directory; run this inside an Oriel app\n", .{cwd});
        return 1;
    };
    defer ctx.gpa.free(root);
    const want = try zig_manager.requiredForRoot(ctx, root);
    defer ctx.gpa.free(want);
    const resolved = zig_manager.resolve(ctx, want) catch return 1;
    defer resolved.deinit(ctx.gpa);
    const zig = resolved.path;

    if (std.mem.eql(u8, sub, "setup")) {
        const o = parse(ctx, rest, &.{}) orelse return 1;
        const sdk = try tools.ensureSdk(ctx, .device, o.yes) orelse return 1;
        defer ctx.gpa.free(sdk);
        try ctx.out.print("iOS SDK: {s}\n", .{sdk});
        if (@import("builtin").os.tag == .linux) {
            const xtool = try tools.ensureXtool(ctx, o.yes) orelse return 1;
            defer ctx.gpa.free(xtool);
            try ctx.out.print("xtool: {s}\n", .{xtool});
            if (try tools.ensureUsbmuxd(ctx, o.yes)) try ctx.out.print("usbmuxd: installed\n", .{});
        }
        return 0;
    }
    if (std.mem.eql(u8, sub, "build")) {
        const o = parse(ctx, rest, &.{ "--simulator", "--ipa" }) orelse return 1;
        const sdk_arg = try sdkArg(ctx, o) orelse return 1;
        defer ctx.gpa.free(sdk_arg);
        if (!run(ctx, &.{ zig, "build", targetArg(o.simulator), sdk_arg, "-Doptimize=ReleaseSafe" }, root)) return 1;
        if (o.ipa and !run(ctx, &.{ zig, "build", "ios-ipa", targetArg(o.simulator), sdk_arg, "-Doptimize=ReleaseSafe" }, root)) return 1;
        try ctx.out.print("built zig-out/ios/{s}\n", .{if (o.ipa) "<Name>.app and zig-out/<Name>.ipa" else "<Name>.app"});
        return 0;
    }
    if (std.mem.eql(u8, sub, "dev")) {
        const o = parse(ctx, rest, &.{ "--simulator", "--url" }) orelse return 1;
        const sdk_arg = try sdkArg(ctx, o) orelse return 1;
        defer ctx.gpa.free(sdk_arg);
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(ctx.gpa);
        try argv.appendSlice(ctx.gpa, &.{ zig, "build", "ios-dev", targetArg(o.simulator), sdk_arg });
        const url_arg = if (o.url) |u| try std.fmt.allocPrint(ctx.gpa, "-Dios_dev_url={s}", .{u}) else null;
        defer if (url_arg) |a| ctx.gpa.free(a);
        if (url_arg) |a| try argv.append(ctx.gpa, a);
        if (!run(ctx, argv.items, root)) return 1;
        if (!o.simulator and o.url == null)
            try ctx.out.print("note: a device can't reach the dev machine's localhost: pass --url http://<LAN address>:<port>/\n", .{});
        return install(ctx, root, o.simulator, true, true, o.yes);
    }
    if (std.mem.eql(u8, sub, "install")) {
        const o = parse(ctx, rest, &.{ "--simulator", "--dev" }) orelse return 1;
        return install(ctx, root, o.simulator, o.dev, false, o.yes);
    }
    try ctx.err.print("error: unknown subcommand 'ios {s}' (build, dev, install, setup)\n", .{sub});
    return 1;
}

/// `-Dapple_sdk=<the SDK>` (caller frees), set up after asking if missing.
fn sdkArg(ctx: Context, o: Options) !?[]u8 {
    const sdk = try tools.ensureSdk(ctx, if (o.simulator) .simulator else .device, o.yes) orelse return null;
    defer ctx.gpa.free(sdk);
    return try std.fmt.allocPrint(ctx.gpa, "-Dapple_sdk={s}", .{sdk});
}

/// The one `.app` in zig-out/ios (or ios-dev).
fn findBundle(ctx: Context, root: []const u8, dev: bool) !?[]u8 {
    const dir_path = try std.fs.path.join(ctx.gpa, &.{ root, "zig-out", if (dev) "ios-dev" else "ios" });
    defer ctx.gpa.free(dir_path);
    var dir = std.Io.Dir.cwd().openDir(ctx.io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(ctx.io);
    var it = dir.iterate();
    while (it.next(ctx.io) catch null) |entry| {
        if (entry.kind == .directory and std.mem.endsWith(u8, entry.name, ".app"))
            return try std.fs.path.join(ctx.gpa, &.{ dir_path, entry.name });
    }
    return null;
}

/// CFBundleIdentifier from the bundle's Info.plist (Oriel writes it as
/// XML, the key followed by its string).
pub fn bundleId(gpa: std.mem.Allocator, plist: []const u8) ?[]u8 {
    const key = std.mem.indexOf(u8, plist, "<key>CFBundleIdentifier</key>") orelse return null;
    const open_tag = "<string>";
    const start = (std.mem.indexOfPos(u8, plist, key, open_tag) orelse return null) + open_tag.len;
    const end = std.mem.indexOfPos(u8, plist, start, "</string>") orelse return null;
    return gpa.dupe(u8, plist[start..end]) catch null;
}

test bundleId {
    const gpa = std.testing.allocator;
    const id = bundleId(gpa, "<dict>\n\t<key>CFBundleIdentifier</key>\n\t<string>dev.oriel.Hello</string>\n").?;
    defer gpa.free(id);
    try std.testing.expectEqualStrings("dev.oriel.Hello", id);
}

fn install(ctx: Context, root: []const u8, simulator: bool, dev: bool, launch: bool, yes: bool) !u8 {
    const bundle = try findBundle(ctx, root, dev) orelse {
        try ctx.err.print("error: no .app in zig-out/{s}: run `oriel ios {s}` first\n", .{ if (dev) "ios-dev" else "ios", if (dev) "dev" else "build" });
        return 1;
    };
    defer ctx.gpa.free(bundle);
    if (simulator) {
        if (!(ctx.hasExecutable("xcrun") catch false)) {
            try ctx.err.print("error: the simulator needs Xcode (xcrun simctl); on Linux, install on a device with xtool instead\n", .{});
            return 1;
        }
        if (!run(ctx, &.{ "xcrun", "simctl", "install", "booted", bundle }, root)) return 1;
        if (!launch) return 0;
        const plist_path = try std.fs.path.join(ctx.gpa, &.{ bundle, "Info.plist" });
        defer ctx.gpa.free(plist_path);
        const plist = try std.Io.Dir.cwd().readFileAlloc(ctx.io, plist_path, ctx.gpa, .limited(1 << 20));
        defer ctx.gpa.free(plist);
        const id = bundleId(ctx.gpa, plist) orelse {
            try ctx.err.print("error: no CFBundleIdentifier in {s}\n", .{plist_path});
            return 1;
        };
        defer ctx.gpa.free(id);
        return if (run(ctx, &.{ "xcrun", "simctl", "launch", "--console-pty", "booted", id }, root)) 0 else 1;
    }
    const xtool = try tools.ensureXtool(ctx, yes) orelse return 1;
    defer ctx.gpa.free(xtool);
    _ = try tools.ensureUsbmuxd(ctx, yes);
    if (!run(ctx, &.{ xtool, "install", bundle }, root)) return 1;
    if (launch) try ctx.out.print("installed {s}; start it from the home screen\n", .{std.fs.path.basename(bundle)});
    return 0;
}

fn run(ctx: Context, argv: []const []const u8, cwd: []const u8) bool {
    const code = ctx.run(argv, cwd) orelse {
        ctx.err.print("error: could not run {s}\n", .{argv[0]}) catch {};
        return false;
    };
    if (code != 0) {
        ctx.err.print("error: '{s}{s}{s}' failed (exit code {d})\n", .{ argv[0], if (argv.len > 1) " " else "", if (argv.len > 1) argv[1] else "", code }) catch {};
        return false;
    }
    return true;
}
