//! `oriel dev | build | run | package | types | check`: thin wrappers around
//! `zig build <step>` that work from anywhere inside an app.

const std = @import("std");
const builtin = @import("builtin");
const Context = @import("Context.zig");
const webview2 = @import("webview2.zig");

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

    // Apps without a frontend dev server (the vanilla template) have no
    // `dev` step: say what to use instead of zig's "no step named 'dev'".
    if (step != null and std.mem.eql(u8, step.?, "dev")) {
        if (ctx.capture(&.{ zig, "build", "-l" }, 300_000)) |l| {
            defer l.deinit(ctx.gpa);
            if (l.code == 0 and !hasStep(l.text(), "dev")) {
                try ctx.err.print("error: this app has no frontend dev server (frontend.dev is null, e.g. the vanilla template), so there is no `dev` step.\nUse `oriel run` to build and run it, and rerun after editing.\n", .{});
                return 1;
            }
        }
    }

    // Check if we need to auto-inject -Dwebview2-loader
    var effective_args = args;
    var injected_args_buf: ?[]const []const u8 = null;
    defer if (injected_args_buf) |ia| {
        if (ia.len > 0) ctx.gpa.free(ia[ia.len - 1]);
        ctx.gpa.free(ia);
    };

    const is_build_like_step = if (step) |s|
        (std.mem.eql(u8, s, "run") or std.mem.eql(u8, s, "package") or std.mem.eql(u8, s, "dev"))
    else
        true;

    if (is_build_like_step) {
        if (needsLoaderInjection(args, builtin.os.tag, builtin.cpu.arch)) |target_info| {
            const arch_name = if (target_info.arch == .arm64) "arm64" else "x64";
            const maybe_cached = try webview2.findNewestCached(ctx.gpa, ctx.io, ctx.environ, arch_name);
            if (maybe_cached) |cached| {
                defer cached.deinit(ctx.gpa);
                const injected = try injectLoaderArg(ctx.gpa, args, cached.path);
                injected_args_buf = injected;
                effective_args = injected;
            } else {
                const no_fetch = if (ctx.environ.get("ORIEL_NO_WEBVIEW2_FETCH")) |v|
                    std.mem.eql(u8, v, "1")
                else
                    false;

                if (no_fetch) {
                    try ctx.err.print("info: no cached WebView2Loader.dll and ORIEL_NO_WEBVIEW2_FETCH=1; pass -Dwebview2-loader=<path>\n", .{});
                } else {
                    try ctx.out.print("Fetching WebView2Loader.dll ({s}) from NuGet...\n", .{arch_name});
                    ctx.flush();
                    webview2.fetch(ctx, if (target_info.arch == .arm64) .arm64 else .x64, null, null) catch |err| {
                        try ctx.err.print("warning: failed to fetch WebView2Loader.dll: {s}\nManual download: get Microsoft.Web.WebView2 from https://www.nuget.org/packages/Microsoft.Web.WebView2/, extract runtimes/win-{s}/native/WebView2Loader.dll, and pass -Dwebview2-loader=<path>\n", .{ @errorName(err), arch_name });
                    };
                    if (try webview2.findNewestCached(ctx.gpa, ctx.io, ctx.environ, arch_name)) |newly_cached| {
                        defer newly_cached.deinit(ctx.gpa);
                        const injected = try injectLoaderArg(ctx.gpa, args, newly_cached.path);
                        injected_args_buf = injected;
                        effective_args = injected;
                    }
                }
            }
        }
    }

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(ctx.gpa);
    try argv.appendSlice(ctx.gpa, &.{ zig, "build" });
    if (step) |s| try argv.append(ctx.gpa, s);
    try argv.appendSlice(ctx.gpa, effective_args);

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

pub const WindowsTarget = struct {
    arch: enum { x64, arm64 },
};

/// Pure function to detect if the build command targets Windows and needs WebView2Loader injection.
/// Returns the target architecture (.x64 or .arm64) if:
/// - Resulting target is Windows (native host Windows with no -Dtarget, or -Dtarget=*-windows*), AND
/// - User did not pass -Dwebview2-loader (or -Dwebview2-loader=...).
/// Otherwise returns null.
pub fn needsLoaderInjection(
    args: []const []const u8,
    host_os: std.Target.Os.Tag,
    host_arch: std.Target.Cpu.Arch,
) ?WindowsTarget {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.startsWith(u8, arg, "-Dwebview2-loader=") or std.mem.eql(u8, arg, "-Dwebview2-loader")) {
            return null;
        }
    }

    var target_opt: ?[]const u8 = null;
    i = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.startsWith(u8, arg, "-Dtarget=")) {
            target_opt = arg["-Dtarget=".len..];
        } else if (std.mem.eql(u8, arg, "-Dtarget")) {
            if (i + 1 < args.len) {
                i += 1;
                target_opt = args[i];
            }
        }
    }

    if (target_opt) |target_str| {
        if (std.mem.indexOf(u8, target_str, "windows") == null) return null;
        if (std.mem.indexOf(u8, target_str, "aarch64") != null or std.mem.indexOf(u8, target_str, "arm64") != null) {
            return .{ .arch = .arm64 };
        }
        return .{ .arch = .x64 };
    } else {
        if (host_os != .windows) return null;
        if (host_arch == .aarch64) {
            return .{ .arch = .arm64 };
        }
        return .{ .arch = .x64 };
    }
}

/// Pure function to append -Dwebview2-loader=<loader_path> to args.
pub fn injectLoaderArg(gpa: std.mem.Allocator, args: []const []const u8, loader_path: []const u8) ![]const []const u8 {
    const loader_arg = try std.fmt.allocPrint(gpa, "-Dwebview2-loader={s}", .{loader_path});
    const new_args = try gpa.alloc([]const u8, args.len + 1);
    for (args, 0..) |a, idx| new_args[idx] = a;
    new_args[args.len] = loader_arg;
    return new_args;
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

test "needsLoaderInjection logic" {
    // 1. Linux host, no -Dtarget -> null
    try std.testing.expectEqual(null, needsLoaderInjection(&.{}, .linux, .x86_64));

    // 2. Windows host, no -Dtarget -> x64
    const win_native = needsLoaderInjection(&.{}, .windows, .x86_64).?;
    try std.testing.expectEqual(.x64, win_native.arch);

    // 3. Windows host arm64, no -Dtarget -> arm64
    const win_arm_native = needsLoaderInjection(&.{}, .windows, .aarch64).?;
    try std.testing.expectEqual(.arm64, win_arm_native.arch);

    // 4. Linux host, -Dtarget=x86_64-windows -> x64
    const cross_x64 = needsLoaderInjection(&.{"-Dtarget=x86_64-windows"}, .linux, .x86_64).?;
    try std.testing.expectEqual(.x64, cross_x64.arch);

    // 5. Linux host, -Dtarget=aarch64-windows-gnu -> arm64
    const cross_arm64 = needsLoaderInjection(&.{"-Dtarget=aarch64-windows-gnu"}, .linux, .x86_64).?;
    try std.testing.expectEqual(.arm64, cross_arm64.arch);

    // 6. Linux host, -Dtarget aarch64-windows -> arm64
    const cross_arm64_split = needsLoaderInjection(&.{ "-Dtarget", "aarch64-windows" }, .linux, .x86_64).?;
    try std.testing.expectEqual(.arm64, cross_arm64_split.arch);

    // 7. User already specified -Dwebview2-loader -> null
    try std.testing.expectEqual(null, needsLoaderInjection(&.{ "-Dtarget=x86_64-windows", "-Dwebview2-loader=/path/to/dll" }, .linux, .x86_64));
    try std.testing.expectEqual(null, needsLoaderInjection(&.{ "-Dtarget=x86_64-windows", "-Dwebview2-loader", "/path/to/dll" }, .linux, .x86_64));

    // 8. Non-Windows target -> null
    try std.testing.expectEqual(null, needsLoaderInjection(&.{"-Dtarget=x86_64-linux"}, .windows, .x86_64));
}

test "injectLoaderArg" {
    const orig = [_][]const u8{ "-Doptimize=ReleaseFast", "extra" };
    const injected = try injectLoaderArg(std.testing.allocator, &orig, "/cache/WebView2Loader.dll");
    defer {
        std.testing.allocator.free(injected[injected.len - 1]);
        std.testing.allocator.free(injected);
    }
    try std.testing.expectEqual(3, injected.len);
    try std.testing.expectEqualStrings("-Doptimize=ReleaseFast", injected[0]);
    try std.testing.expectEqualStrings("extra", injected[1]);
    try std.testing.expectEqualStrings("-Dwebview2-loader=/cache/WebView2Loader.dll", injected[2]);
}


/// Whether `zig build -l` output lists a step named `name`.
fn hasStep(list: []const u8, name: []const u8) bool {
    var lines = std.mem.splitScalar(u8, list, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, t, name) and (t.len == name.len or t[name.len] == ' ')) return true;
    }
    return false;
}

test hasStep {
    const out =
        \\  install (default)            Copy build artifacts to prefix path
        \\  dev                          Run with the frontend dev server
        \\  devtools                     Something else
    ;
    try std.testing.expect(hasStep(out, "dev"));
    try std.testing.expect(hasStep(out, "install"));
    try std.testing.expect(!hasStep(out, "run"));
    try std.testing.expect(!hasStep("  devtools  x", "dev"));
}
