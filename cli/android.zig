//! `oriel android`: build and run an Oriel app on Android.
//!
//!     oriel android init [--force]
//!         Write android/ (a Gradle project around the Zig library) from
//!         Oriel's template, with the app's id, name, version, permissions
//!         and URL schemes from build.zig. --force rewrites edited files.
//!     oriel android dev [--port 5173] [--abi arm64|x86_64]
//!         Build the dev library for the connected device's ABI, install a
//!         debug APK with adb, forward the dev server (`adb reverse`) and
//!         start the app. Run the frontend's dev server yourself.
//!     oriel android build [--abi arm64|x86_64|all] [--apk] [--aab]
//!         Release libraries for every ABI (default all), then Gradle:
//!         an APK for sideloading and an AAB for Play (both by default),
//!         signed with $ORIEL_ANDROID_KEYSTORE if set.
//!     oriel android devices
//!         The devices adb sees.
//!
//! Needs the Android SDK (adb, a JDK, Gradle 8.9+ or android/gradlew) and
//! the NDK ($ANDROID_NDK_HOME, or $ANDROID_HOME/ndk/<version>). See
//! docs/android.md.

const std = @import("std");
const builtin = @import("builtin");
const Context = @import("Context.zig");
const project = @import("project.zig");
const zig_manager = @import("zig_manager.zig");

pub const Command = struct {
    pub const summary = "Build and run the app on Android (init, dev, build, devices)";
    pub const forward = "args";
    pub const details =
        \\  oriel android init [--force]                   write android/ (the Gradle project)
        \\  oriel android dev [--port N] [--abi arm64|x86_64]
        \\                                                 debug build on the connected device, with the dev server
        \\  oriel android build [--abi arm64|x86_64|all] [--apk] [--aab]
        \\                                                 release APK (sideloading) and AAB (Play)
        \\  oriel android devices                          devices adb sees
        \\
        \\Needs the Android SDK (adb, Gradle 8.9+ or android/gradlew, a JDK) and the NDK
        \\($ANDROID_NDK_HOME or $ANDROID_HOME/ndk/<version>). See docs/android.md.
    ;
    args: []const []const u8 = &.{},
};

pub const Abi = enum {
    arm64,
    x86_64,

    pub fn target(abi: Abi) []const u8 {
        return switch (abi) {
            .arm64 => "aarch64-linux-android",
            .x86_64 => "x86_64-linux-android",
        };
    }

    /// From `adb shell getprop ro.product.cpu.abi`.
    pub fn fromAndroid(name: []const u8) ?Abi {
        const n = std.mem.trim(u8, name, " \t\r\n");
        if (std.mem.eql(u8, n, "arm64-v8a")) return .arm64;
        if (std.mem.eql(u8, n, "x86_64")) return .x86_64;
        return null;
    }
};

test "Abi.fromAndroid" {
    try std.testing.expectEqual(Abi.arm64, Abi.fromAndroid("arm64-v8a\r\n").?);
    try std.testing.expectEqual(Abi.x86_64, Abi.fromAndroid("x86_64").?);
    try std.testing.expect(Abi.fromAndroid("armeabi-v7a") == null);
}

const Env = struct {
    ctx: Context,
    root: []const u8,
    zig: []const u8,
    android_dir: []const u8,

    fn zigBuild(e: Env, extra: []const []const u8) bool {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(e.ctx.gpa);
        argv.appendSlice(e.ctx.gpa, &.{ e.zig, "build" }) catch return false;
        argv.appendSlice(e.ctx.gpa, extra) catch return false;
        return run(e.ctx, argv.items, e.root);
    }

    /// android/gradlew if the project has one, else Gradle from PATH.
    fn gradle(e: Env) ?[]const u8 {
        const wrapper = std.fs.path.join(e.ctx.gpa, &.{ e.android_dir, if (builtin.os.tag == .windows) "gradlew.bat" else "gradlew" }) catch return null;
        if (exists(e.ctx.io, wrapper)) return wrapper;
        if (e.ctx.hasExecutable("gradle") catch false) return "gradle";
        e.ctx.err.print("error: no Gradle: install Gradle 8.9+ (or run `gradle wrapper` in android/)\n", .{}) catch {};
        return null;
    }
};

fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
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

pub fn runCommand(ctx: Context, cmd: Command) !u8 {
    const args = cmd.args;
    if (args.len == 0 or std.mem.eql(u8, args[0], "help") or std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h")) {
        try ctx.out.print("usage:\n{s}\n", .{Command.details});
        return if (args.len == 0) 1 else 0;
    }
    const sub = args[0];
    const rest = args[1..];
    if (std.mem.eql(u8, sub, "devices")) {
        return if (run(ctx, &.{ "adb", "devices", "-l" }, ".")) 0 else 1;
    }

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
    const android_dir = try std.fs.path.join(ctx.gpa, &.{ root, "android" });
    defer ctx.gpa.free(android_dir);
    const e: Env = .{ .ctx = ctx, .root = root, .zig = resolved.path, .android_dir = android_dir };

    if (std.mem.eql(u8, sub, "init")) return init(e, rest);
    if (std.mem.eql(u8, sub, "dev")) return dev(e, rest);
    if (std.mem.eql(u8, sub, "build")) return build(e, rest);
    try ctx.err.print("error: unknown subcommand 'android {s}' (init, dev, build, devices)\n", .{sub});
    return 1;
}

fn init(e: Env, args: []const []const u8) !u8 {
    var force = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--force")) force = true else {
            try e.ctx.err.print("error: unknown option {s}\n", .{a});
            return 1;
        }
    }
    if (!e.zigBuild(&.{ "android-project", "-Dtarget=aarch64-linux-android", if (force) "-Dandroid_force=true" else "-Dandroid_force=false" })) return 1;
    // A Gradle wrapper, so the project builds without a system Gradle.
    const wrapper = try std.fs.path.join(e.ctx.gpa, &.{ e.android_dir, "gradlew" });
    defer e.ctx.gpa.free(wrapper);
    if (!exists(e.ctx.io, wrapper) and (e.ctx.hasExecutable("gradle") catch false)) {
        const code = e.ctx.run(&.{ "gradle", "-q", "wrapper", "--gradle-version", "8.10.2" }, e.android_dir);
        if (code == null or code.? != 0) try e.ctx.out.print("note: `gradle wrapper` failed; the commands use Gradle from PATH instead\n", .{});
    }
    try e.ctx.out.print(
        \\android/ is ready. Next:
        \\  oriel android dev      run on the connected device or emulator (with the dev server)
        \\  oriel android build    release APK and AAB
        \\Open android/ in Android Studio to edit the manifest, icons or signing.
        \\
    , .{});
    return 0;
}

fn needProject(e: Env) bool {
    if (exists(e.ctx.io, e.android_dir)) return true;
    e.ctx.err.print("error: no android/ project yet: run `oriel android init` first\n", .{}) catch {};
    return false;
}

/// The applicationId from android/app/build.gradle.kts.
fn applicationId(e: Env) ?[]u8 {
    const path = std.fs.path.join(e.ctx.gpa, &.{ e.android_dir, "app", "build.gradle.kts" }) catch return null;
    defer e.ctx.gpa.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(e.ctx.io, path, e.ctx.gpa, .limited(1 << 20)) catch return null;
    defer e.ctx.gpa.free(text);
    return parseApplicationId(e.ctx.gpa, text);
}

pub fn parseApplicationId(gpa: std.mem.Allocator, text: []const u8) ?[]u8 {
    const key = std.mem.indexOf(u8, text, "applicationId") orelse return null;
    const q1 = std.mem.indexOfScalarPos(u8, text, key, '"') orelse return null;
    const q2 = std.mem.indexOfScalarPos(u8, text, q1 + 1, '"') orelse return null;
    return gpa.dupe(u8, text[q1 + 1 .. q2]) catch null;
}

test parseApplicationId {
    const gpa = std.testing.allocator;
    const id = parseApplicationId(gpa, "defaultConfig {\n        applicationId = \"dev.oriel.Hello\"\n").?;
    defer gpa.free(id);
    try std.testing.expectEqualStrings("dev.oriel.Hello", id);
}

fn dev(e: Env, args: []const []const u8) !u8 {
    var port: []const u8 = "5173";
    var abi: ?Abi = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            i += 1;
            port = args[i];
        } else if (std.mem.eql(u8, args[i], "--abi") and i + 1 < args.len) {
            i += 1;
            abi = std.meta.stringToEnum(Abi, args[i]) orelse {
                try e.ctx.err.print("error: --abi is arm64 or x86_64\n", .{});
                return 1;
            };
        } else {
            try e.ctx.err.print("error: unknown option {s}\n", .{args[i]});
            return 1;
        }
    }
    if (!needProject(e)) return 1;
    const device_abi = abi orelse blk: {
        const got = e.ctx.capture(&.{ "adb", "shell", "getprop", "ro.product.cpu.abi" }, 30_000) orelse {
            try e.ctx.err.print("error: adb is not available (install the Android SDK platform-tools)\n", .{});
            return 1;
        };
        defer got.deinit(e.ctx.gpa);
        break :blk Abi.fromAndroid(got.text()) orelse {
            try e.ctx.err.print("error: no device, or an unsupported ABI ({s}); connect one (`oriel android devices`) or pass --abi\n", .{std.mem.trim(u8, got.text(), " \r\n")});
            return 1;
        };
    };
    const target_arg = try std.fmt.allocPrint(e.ctx.gpa, "-Dtarget={s}", .{device_abi.target()});
    defer e.ctx.gpa.free(target_arg);
    if (!e.zigBuild(&.{ "android-dev", target_arg })) return 1;
    const gradle = e.gradle() orelse return 1;
    if (!run(e.ctx, &.{ gradle, "installDebug" }, e.android_dir)) return 1;
    const tcp = try std.fmt.allocPrint(e.ctx.gpa, "tcp:{s}", .{port});
    defer e.ctx.gpa.free(tcp);
    if (!run(e.ctx, &.{ "adb", "reverse", tcp, tcp }, e.root)) return 1;
    const id = applicationId(e) orelse {
        try e.ctx.err.print("error: no applicationId in android/app/build.gradle.kts\n", .{});
        return 1;
    };
    defer e.ctx.gpa.free(id);
    const component = try std.fmt.allocPrint(e.ctx.gpa, "{s}/dev.oriel.OrielMainActivity", .{id});
    defer e.ctx.gpa.free(component);
    if (!run(e.ctx, &.{ "adb", "shell", "am", "start", "-n", component }, e.root)) return 1;
    try e.ctx.out.print("started {s}; logs: adb logcat -s Oriel chromium\n", .{id});
    return 0;
}

fn build(e: Env, args: []const []const u8) !u8 {
    var abis: []const Abi = &.{ .arm64, .x86_64 };
    var apk = false;
    var aab = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--abi") and i + 1 < args.len) {
            i += 1;
            if (std.mem.eql(u8, args[i], "all")) continue;
            abis = if (std.mem.eql(u8, args[i], "arm64")) &.{.arm64} else if (std.mem.eql(u8, args[i], "x86_64")) &.{.x86_64} else {
                try e.ctx.err.print("error: --abi is arm64, x86_64 or all\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, args[i], "--apk")) {
            apk = true;
        } else if (std.mem.eql(u8, args[i], "--aab")) {
            aab = true;
        } else {
            try e.ctx.err.print("error: unknown option {s}\n", .{args[i]});
            return 1;
        }
    }
    if (!apk and !aab) {
        apk = true;
        aab = true;
    }
    if (!needProject(e)) return 1;
    for (abis) |abi| {
        const target_arg = try std.fmt.allocPrint(e.ctx.gpa, "-Dtarget={s}", .{abi.target()});
        defer e.ctx.gpa.free(target_arg);
        if (!e.zigBuild(&.{ target_arg, "-Doptimize=ReleaseSafe" })) return 1;
    }
    const gradle = e.gradle() orelse return 1;
    var tasks: std.ArrayList([]const u8) = .empty;
    defer tasks.deinit(e.ctx.gpa);
    try tasks.append(e.ctx.gpa, gradle);
    if (apk) try tasks.append(e.ctx.gpa, "assembleRelease");
    if (aab) try tasks.append(e.ctx.gpa, "bundleRelease");
    if (!run(e.ctx, tasks.items, e.android_dir)) return 1;
    if (e.ctx.environ.get("ORIEL_ANDROID_KEYSTORE") == null)
        try e.ctx.out.print("note: $ORIEL_ANDROID_KEYSTORE is not set, so the release APK is unsigned (see docs/android.md)\n", .{});
    try e.ctx.out.print(
        \\outputs:
        \\  android/app/build/outputs/apk/release/   (sideloading)
        \\  android/app/build/outputs/bundle/release/ (Play)
        \\
    , .{});
    return 0;
}
