//! `oriel dev | build | run | package | types | check`: thin wrappers around
//! `zig build <step>` that work from anywhere inside an app.

const std = @import("std");
const builtin = @import("builtin");
const Context = @import("Context.zig");
const webview2 = @import("webview2.zig");
const zig_manager = @import("zig_manager.zig");
const setup = @import("setup.zig");

/// A command that runs `zig build [step] <args...>` in the project root.
/// `step` null is plain `zig build` (the install step).
pub fn Wrapper(comptime step: ?[]const u8, comptime what: []const u8) type {
    return struct {
        pub const summary = what;
        pub const zig_step = step;
        pub const forward = "args";
        pub const details = "Runs `zig build" ++ (if (step) |s| " " ++ s else "") ++ " [args...]` in the project root " ++
            "(the nearest directory above with a build.zig.zon);\nevery argument is passed on, " ++
            "e.g. -Doptimize=ReleaseFast, or `-- <app args>` for run/dev.\n" ++
            "The project's own options and steps: `zig build --help` in the project.";
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
        // Windows: the long form of the path. From an 8.3 short path
        // (C:\Users\JOHNDO~1\..., as %TEMP% is for names with spaces) Vite
        // compares the short and long spellings and answers 403 Restricted.
        if (builtin.os.tag == .windows) {
            if (longPathAlloc(gpa, d)) |long| return long else |_| {}
        }
        return try gpa.dupe(u8, d);
    }
    return null;
}

extern "kernel32" fn GetLongPathNameW(short: [*:0]const u16, long: [*]u16, len: u32) callconv(.winapi) u32;

/// `path` with 8.3 short components expanded (GetLongPathNameW; Zig's
/// realpath keeps them). Caller owns the result.
fn longPathAlloc(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const short_w = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, path);
    defer gpa.free(short_w);
    const buf = try gpa.alloc(u16, std.os.windows.PATH_MAX_WIDE + 1);
    defer gpa.free(buf);
    const n = GetLongPathNameW(short_w.ptr, buf.ptr, @intCast(buf.len));
    if (n == 0 or n >= buf.len) return error.LongPathUnavailable;
    return std.unicode.wtf16LeToWtf8Alloc(gpa, buf[0..n]);
}

test longPathAlloc {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "Long Name Dir");
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const long_dir = try std.fs.path.join(gpa, &.{ root, "Long Name Dir" });
    defer gpa.free(long_dir);
    // An already-long path comes back unchanged (8.3 names may be disabled
    // on the test volume, so this is what's always checkable).
    const same = try longPathAlloc(gpa, long_dir);
    defer gpa.free(same);
    try std.testing.expectEqualStrings(long_dir, same);
    try std.testing.expectError(error.LongPathUnavailable, longPathAlloc(gpa, "C:\\no\\such\\dir\\x"));
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

    // The project's Zig ($ORIEL_ZIG, PATH, ~/.oriel/zig, or installed now):
    // a wrong Zig would fail deep inside the build with confusing errors.
    const want = try zig_manager.requiredForRoot(ctx, root);
    defer ctx.gpa.free(want);
    const resolved = zig_manager.resolve(ctx, want) catch return 1;
    defer resolved.deinit(ctx.gpa);
    const zig = resolved.path;

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

    // Check if we need to auto-inject arguments
    var effective_args = args;
    var injected_strings: std.ArrayList([]const u8) = .empty;
    defer {
        for (injected_strings.items) |s| ctx.gpa.free(s);
        injected_strings.deinit(ctx.gpa);
    }
    var allocated_slices: std.ArrayList([]const []const u8) = .empty;
    defer {
        for (allocated_slices.items) |sl| ctx.gpa.free(sl);
        allocated_slices.deinit(ctx.gpa);
    }

    const is_build_like_step = if (step) |s|
        (std.mem.eql(u8, s, "run") or std.mem.eql(u8, s, "package") or std.mem.eql(u8, s, "dev") or std.mem.eql(u8, s, "check"))
    else
        true;

    if (is_build_like_step) {
        if (needsLoaderInjection(args, builtin.os.tag, builtin.cpu.arch)) |target_info| {
            const arch_name = if (target_info.arch == .arm64) "arm64" else "x64";
            const maybe_cached = try webview2.findNewestCached(ctx.gpa, ctx.io, ctx.environ, arch_name);
            if (maybe_cached) |cached| {
                defer cached.deinit(ctx.gpa);
                const arg_str = try std.fmt.allocPrint(ctx.gpa, "-Dwebview2-loader={s}", .{cached.path});
                try injected_strings.append(ctx.gpa, arg_str);
                const new_args = try injectBuildArg(ctx.gpa, effective_args, arg_str);
                try allocated_slices.append(ctx.gpa, new_args);
                effective_args = new_args;
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
                        const arg_str = try std.fmt.allocPrint(ctx.gpa, "-Dwebview2-loader={s}", .{newly_cached.path});
                        try injected_strings.append(ctx.gpa, arg_str);
                        const new_args = try injectBuildArg(ctx.gpa, effective_args, arg_str);
                        try allocated_slices.append(ctx.gpa, new_args);
                        effective_args = new_args;
                    }
                }
            }
        }
    }

    // Default production builds (build, package, run) to -Doptimize=ReleaseSafe if not specified,
    // so build and package share the same optimize option and do not rebuild.
    const is_prod_step = if (step) |s|
        (std.mem.eql(u8, s, "run") or std.mem.eql(u8, s, "package"))
    else
        true;

    if (is_prod_step and !hasOptimizeArg(effective_args)) {
        const opt_arg = try ctx.gpa.dupe(u8, "-Doptimize=ReleaseSafe");
        try injected_strings.append(ctx.gpa, opt_arg);
        const new_args = try injectBuildArg(ctx.gpa, effective_args, opt_arg);
        try allocated_slices.append(ctx.gpa, new_args);
        effective_args = new_args;
    }

    // Production builds run on other people's machines: without -Dtarget or
    // -Dcpu, `zig build` targets this machine's CPU, and a binary built on a
    // newer CPU (a CI runner) dies with "illegal instruction" on older ones.
    if (is_prod_step and !hasTargetOrCpuArg(effective_args)) {
        if (defaultCpu(builtin.cpu.arch, builtin.os.tag)) |cpu| {
            const cpu_arg = try std.fmt.allocPrint(ctx.gpa, "-Dcpu={s}", .{cpu});
            try injected_strings.append(ctx.gpa, cpu_arg);
            const new_args = try injectBuildArg(ctx.gpa, effective_args, cpu_arg);
            try allocated_slices.append(ctx.gpa, new_args);
            effective_args = new_args;
        }
    }

    // Child environment with managed tools configured
    var child_env = try ctx.environ.clone(ctx.gpa);
    defer child_env.deinit();

    // Check Node.js & npm
    const needs_node = projectNeedsNode(ctx.io, root);
    const system_node = try ctx.findExecutable("node");
    defer if (system_node) |p| ctx.gpa.free(p);
    const system_npm = try ctx.findExecutable("npm");
    defer if (system_npm) |p| ctx.gpa.free(p);

    const has_system_node_and_npm = system_node != null and system_npm != null;
    var maybe_managed_node = try setup.findNewestManagedNode(ctx);
    defer if (maybe_managed_node) |*mn| mn.deinit(ctx.gpa);

    if (!has_system_node_and_npm) {
        if (maybe_managed_node) |mn| {
            const old_path = child_env.get("PATH");
            const new_path = try prependPath(ctx.gpa, old_path, mn.bin_dir);
            defer ctx.gpa.free(new_path);
            try child_env.put("PATH", new_path);
        } else if (needs_node) {
            try ctx.err.writeAll("error: this project requires Node.js and npm (run: oriel setup node)\n");
            return 1;
        }
    }

    // Check NSIS for Windows packaging
    if (step != null and std.mem.eql(u8, step.?, "package") and isPackagingForWindows(effective_args, builtin.os.tag)) {
        var has_nsis = child_env.get("ORIEL_MAKENSIS") != null;
        if (!has_nsis) {
            const managed_nsis = try setup.findNewestManagedNsis(ctx);
            if (managed_nsis) |mn_path| {
                defer ctx.gpa.free(mn_path);
                try child_env.put("ORIEL_MAKENSIS", mn_path);
                has_nsis = true;
            }
        }
        if (!has_nsis) {
            if (try ctx.findExecutable("makensis")) |p| {
                ctx.gpa.free(p);
                has_nsis = true;
            }
        }
        if (!has_nsis and builtin.os.tag == .windows) {
            for ([_][]const u8{ "ProgramFiles(x86)", "ProgramFiles" }) |env| {
                const base = child_env.get(env) orelse continue;
                const candidate = try std.fs.path.join(ctx.gpa, &.{ base, "NSIS", "makensis.exe" });
                defer ctx.gpa.free(candidate);
                if (std.Io.Dir.cwd().access(ctx.io, candidate, .{})) |_| {
                    has_nsis = true;
                    break;
                } else |_| {}
            }
        }
        if (!has_nsis) {
            try ctx.err.writeAll("error: packaging for Windows requires NSIS (run: oriel setup nsis)\n");
            return 1;
        }
    }

    if (is_build_like_step) {
        if (isColdBuild(ctx.io, root)) {
            try ctx.err.print("Building with Zig {s}... (the first build compiles dependencies and can take a few minutes)\n", .{want});
        } else {
            try ctx.err.print("Building with Zig {s}...\n", .{want});
        }
        ctx.flush();
    }

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(ctx.gpa);
    try argv.appendSlice(ctx.gpa, &.{ zig, "build" });
    if (step) |s| try argv.append(ctx.gpa, s);
    try argv.appendSlice(ctx.gpa, effective_args);

    const is_package_step = step != null and std.mem.eql(u8, step.?, "package");
    const is_build_step = step == null;
    const should_print_outputs = is_build_step or is_package_step;

    if (should_print_outputs or !std.process.can_replace) {
        const code = ctx.runWithEnv(argv.items, root, &child_env) orelse {
            if (try ctx.findExecutable(zig)) |found| ctx.gpa.free(found) else try ctx.err.writeAll("Install Zig 0.16 or set ORIEL_ZIG; `oriel doctor` checks the setup.\n");
            return 1;
        };
        if (code == 0 and should_print_outputs) {
            try printBuildOutputs(ctx, root, is_package_step);
        }
        return code;
    }

    std.process.setCurrentPath(ctx.io, root) catch |e| {
        try ctx.err.print("error: cannot enter {s}: {s}\n", .{ root, @errorName(e) });
        return 1;
    };
    ctx.flush();
    const e = std.process.replace(ctx.io, .{ .argv = argv.items, .environ_map = &child_env });
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
fn findDashDash(args: []const []const u8) usize {
    for (args, 0..) |arg, idx| {
        if (std.mem.eql(u8, arg, "--")) return idx;
    }
    return args.len;
}

pub fn needsLoaderInjection(
    args: []const []const u8,
    host_os: std.Target.Os.Tag,
    host_arch: std.Target.Cpu.Arch,
) ?WindowsTarget {
    const dash_dash_idx = findDashDash(args);
    const build_args = args[0..dash_dash_idx];

    var i: usize = 0;
    while (i < build_args.len) : (i += 1) {
        const arg = build_args[i];
        if (std.mem.startsWith(u8, arg, "-Dwebview2-loader=") or std.mem.eql(u8, arg, "-Dwebview2-loader")) {
            return null;
        }
    }

    var target_opt: ?[]const u8 = null;
    i = 0;
    while (i < build_args.len) : (i += 1) {
        const arg = build_args[i];
        if (std.mem.startsWith(u8, arg, "-Dtarget=")) {
            target_opt = arg["-Dtarget=".len..];
        } else if (std.mem.eql(u8, arg, "-Dtarget")) {
            if (i + 1 < build_args.len) {
                i += 1;
                target_opt = build_args[i];
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

/// Pure function to insert an argument before "--" (or at end if no "--").
pub fn injectBuildArg(gpa: std.mem.Allocator, args: []const []const u8, arg: []const u8) ![]const []const u8 {
    const new_args = try gpa.alloc([]const u8, args.len + 1);
    const dash_dash_idx = findDashDash(args);
    for (args[0..dash_dash_idx], 0..) |a, idx| {
        new_args[idx] = a;
    }
    new_args[dash_dash_idx] = arg;
    for (args[dash_dash_idx..], 0..) |a, idx| {
        new_args[dash_dash_idx + 1 + idx] = a;
    }
    return new_args;
}

/// Pure function to insert -Dwebview2-loader=<loader_path> before "--" (or at end if no "--").
pub fn injectLoaderArg(gpa: std.mem.Allocator, args: []const []const u8, loader_path: []const u8) ![]const []const u8 {
    const loader_arg = try std.fmt.allocPrint(gpa, "-Dwebview2-loader={s}", .{loader_path});
    errdefer gpa.free(loader_arg);
    return injectBuildArg(gpa, args, loader_arg);
}

/// The CPU a production build targets by default, for a host of this arch
/// and OS: x86-64 with AVX2/FMA (Intel Haswell 2013+, AMD 2015+; keeps
/// ggml's vector code fast), any Apple Silicon, generic ARM64. `-Dcpu=...`
/// overrides it (e.g. `x86_64_v2` for pre-AVX2 CPUs).
pub fn defaultCpu(arch: std.Target.Cpu.Arch, os: std.Target.Os.Tag) ?[]const u8 {
    return switch (arch) {
        .x86_64 => "x86_64_v3",
        .aarch64 => if (os == .macos) "apple_m1" else "baseline",
        else => null,
    };
}

/// `-Dtarget` or `-Dcpu` given (before `--`).
pub fn hasTargetOrCpuArg(args: []const []const u8) bool {
    const dash_dash_idx = findDashDash(args);
    for (args[0..dash_dash_idx]) |arg| {
        for ([_][]const u8{ "-Dtarget", "-Dcpu" }) |opt| {
            if (std.mem.eql(u8, arg, opt)) return true;
            if (std.mem.startsWith(u8, arg, opt) and arg.len > opt.len and arg[opt.len] == '=') return true;
        }
    }
    return false;
}

test defaultCpu {
    try std.testing.expectEqualStrings("x86_64_v3", defaultCpu(.x86_64, .windows).?);
    try std.testing.expectEqualStrings("apple_m1", defaultCpu(.aarch64, .macos).?);
    try std.testing.expectEqualStrings("baseline", defaultCpu(.aarch64, .linux).?);
    try std.testing.expect(hasTargetOrCpuArg(&.{"-Dcpu=baseline"}));
    try std.testing.expect(hasTargetOrCpuArg(&.{ "-Dtarget", "x86_64-windows" }));
    try std.testing.expect(!hasTargetOrCpuArg(&.{ "-Doptimize=ReleaseFast", "--", "-Dcpu=x" }));
    try std.testing.expect(!hasTargetOrCpuArg(&.{"-Dcpux=1"}));
}

pub fn hasOptimizeArg(args: []const []const u8) bool {
    const dash_dash_idx = findDashDash(args);
    for (args[0..dash_dash_idx]) |arg| {
        if (std.mem.startsWith(u8, arg, "-Doptimize=") or std.mem.eql(u8, arg, "-Doptimize")) {
            return true;
        }
    }
    return false;
}

pub fn isColdBuild(io: std.Io, root: []const u8) bool {
    var root_dir = std.Io.Dir.cwd().openDir(io, root, .{}) catch return true;
    defer root_dir.close(io);
    var cache_dir = root_dir.openDir(io, ".zig-cache", .{ .iterate = true }) catch return true;
    defer cache_dir.close(io);
    var it = cache_dir.iterate();
    if (it.next(io) catch null) |entry| {
        _ = entry;
        return false;
    }
    return true;
}

pub fn findBuiltArtifacts(gpa: std.mem.Allocator, io: std.Io, root: []const u8) ![][]const u8 {
    var root_dir = std.Io.Dir.cwd().openDir(io, root, .{}) catch return try gpa.alloc([]const u8, 0);
    defer root_dir.close(io);

    var bin_dir = root_dir.openDir(io, "zig-out/bin", .{ .iterate = true }) catch return try gpa.alloc([]const u8, 0);
    defer bin_dir.close(io);

    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(gpa);
    errdefer {
        for (list.items) |item| gpa.free(item);
    }

    var it = bin_dir.iterate();
    var has_non_dev = false;
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) continue;
        const name = entry.name;
        if (builtin.os.tag == .windows) {
            if (!std.ascii.endsWithIgnoreCase(name, ".exe")) continue;
        } else {
            if (std.mem.endsWith(u8, name, ".dll") or
                std.mem.endsWith(u8, name, ".so") or
                std.mem.endsWith(u8, name, ".dylib") or
                std.mem.endsWith(u8, name, ".a") or
                std.mem.endsWith(u8, name, ".pdb") or
                std.mem.endsWith(u8, name, ".dbg")) continue;
        }
        const stem = if (builtin.os.tag == .windows and std.ascii.endsWithIgnoreCase(name, ".exe"))
            name[0 .. name.len - 4]
        else
            name;
        if (!std.mem.endsWith(u8, stem, "-dev")) {
            has_non_dev = true;
        }
        const rel_path = try std.fs.path.join(gpa, &.{ "zig-out", "bin", name });
        try list.append(gpa, rel_path);
    }

    // Drop the -dev builds when a production build exists (in place, so
    // `list` keeps owning every remaining path).
    var kept: usize = 0;
    for (list.items) |p| {
        const base = std.fs.path.basename(p);
        const stem = if (builtin.os.tag == .windows and std.ascii.endsWithIgnoreCase(base, ".exe"))
            base[0 .. base.len - 4]
        else
            base;
        if (has_non_dev and std.mem.endsWith(u8, stem, "-dev")) {
            gpa.free(p);
        } else {
            list.items[kept] = p;
            kept += 1;
        }
    }
    list.shrinkRetainingCapacity(kept);

    const items = try list.toOwnedSlice(gpa);
    std.mem.sort([]const u8, items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return items;
}

pub fn findPackageArtifacts(gpa: std.mem.Allocator, io: std.Io, root: []const u8) ![][]const u8 {
    var root_dir = std.Io.Dir.cwd().openDir(io, root, .{}) catch return try gpa.alloc([]const u8, 0);
    defer root_dir.close(io);

    var pkg_dir = root_dir.openDir(io, "zig-out/package", .{ .iterate = true }) catch return try gpa.alloc([]const u8, 0);
    defer pkg_dir.close(io);

    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(gpa);
    errdefer {
        for (list.items) |item| gpa.free(item);
    }

    var it = pkg_dir.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, ".")) continue;
        const rel_path = try std.fs.path.join(gpa, &.{ "zig-out", "package", entry.name });
        try list.append(gpa, rel_path);
    }

    const items = try list.toOwnedSlice(gpa);
    std.mem.sort([]const u8, items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return items;
}

pub fn printBuildOutputs(ctx: Context, root: []const u8, is_package_step: bool) !void {
    const built = try findBuiltArtifacts(ctx.gpa, ctx.io, root);
    defer {
        for (built) |b| ctx.gpa.free(b);
        ctx.gpa.free(built);
    }
    for (built) |exe_path| {
        try ctx.out.print("Built: {s}\n", .{exe_path});
    }

    if (is_package_step) {
        const pkgs = try findPackageArtifacts(ctx.gpa, ctx.io, root);
        defer {
            for (pkgs) |p| ctx.gpa.free(p);
            ctx.gpa.free(pkgs);
        }
        if (pkgs.len > 0) {
            const formatted = try std.mem.join(ctx.gpa, ", ", pkgs);
            defer ctx.gpa.free(formatted);
            try ctx.out.print("Packages: {s}\n", .{formatted});
        }
    }
    ctx.flush();
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

    // 9. Arguments after -- are ignored for loader inspection
    const with_app_args = needsLoaderInjection(&.{ "-Dtarget=x86_64-windows", "--", "-Dwebview2-loader=ignored" }, .linux, .x86_64).?;
    try std.testing.expectEqual(.x64, with_app_args.arch);
    try std.testing.expectEqual(null, needsLoaderInjection(&.{ "run", "--", "-Dtarget=x86_64-windows" }, .linux, .x86_64));
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

    // With -- separator: loader argument is inserted before --
    const with_sep = [_][]const u8{ "run", "-Doptimize=ReleaseFast", "--", "app_arg1", "app_arg2" };
    const injected_sep = try injectLoaderArg(std.testing.allocator, &with_sep, "/cache/WebView2Loader.dll");
    defer {
        // What exec's cleanup frees: the loader arg sits at the `--` index of the original args.
        std.testing.allocator.free(injected_sep[findDashDash(&with_sep)]);
        std.testing.allocator.free(injected_sep);
    }
    try std.testing.expectEqual(6, injected_sep.len);
    try std.testing.expectEqualStrings("run", injected_sep[0]);
    try std.testing.expectEqualStrings("-Doptimize=ReleaseFast", injected_sep[1]);
    try std.testing.expectEqualStrings("-Dwebview2-loader=/cache/WebView2Loader.dll", injected_sep[2]);
    try std.testing.expectEqualStrings("--", injected_sep[3]);
    try std.testing.expectEqualStrings("app_arg1", injected_sep[4]);
    try std.testing.expectEqualStrings("app_arg2", injected_sep[5]);
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

pub fn prependPath(gpa: std.mem.Allocator, existing_path: ?[]const u8, new_entry: []const u8) ![]u8 {
    if (existing_path) |p| {
        if (p.len > 0) {
            return std.fmt.allocPrint(gpa, "{s}{c}{s}", .{ new_entry, std.fs.path.delimiter, p });
        }
    }
    return gpa.dupe(u8, new_entry);
}

pub fn projectNeedsNode(io: std.Io, root: []const u8) bool {
    var p1_buf: [std.fs.max_path_bytes]u8 = undefined;
    const p1 = std.fmt.bufPrint(&p1_buf, "{s}/frontend/package.json", .{root}) catch return false;
    if (std.Io.Dir.cwd().access(io, p1, .{})) |_| return true else |_| {}

    var p2_buf: [std.fs.max_path_bytes]u8 = undefined;
    const p2 = std.fmt.bufPrint(&p2_buf, "{s}/package.json", .{root}) catch return false;
    if (std.Io.Dir.cwd().access(io, p2, .{})) |_| return true else |_| {}

    return false;
}

pub fn isPackagingForWindows(args: []const []const u8, host_os: std.Target.Os.Tag) bool {
    var target_is_windows = host_os == .windows;
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "-Dtarget=")) {
            const val = arg["-Dtarget=".len..];
            target_is_windows = std.mem.indexOf(u8, val, "windows") != null;
        }
    }
    return target_is_windows;
}

test prependPath {
    const a = std.testing.allocator;
    const sep = std.fs.path.delimiter;

    const p1 = try prependPath(a, null, "/extra/bin");
    defer a.free(p1);
    try std.testing.expectEqualStrings("/extra/bin", p1);

    const p2 = try prependPath(a, "", "/extra/bin");
    defer a.free(p2);
    try std.testing.expectEqualStrings("/extra/bin", p2);

    const p3 = try prependPath(a, "/usr/bin", "/extra/bin");
    defer a.free(p3);
    const expected = try std.fmt.allocPrint(a, "/extra/bin{c}/usr/bin", .{sep});
    defer a.free(expected);
    try std.testing.expectEqualStrings(expected, p3);
}

test isPackagingForWindows {
    try std.testing.expect(isPackagingForWindows(&.{}, .windows));
    try std.testing.expect(!isPackagingForWindows(&.{}, .linux));
    try std.testing.expect(isPackagingForWindows(&.{"-Dtarget=x86_64-windows"}, .linux));
    try std.testing.expect(isPackagingForWindows(&.{"-Dtarget=aarch64-windows"}, .macos));
    try std.testing.expect(!isPackagingForWindows(&.{"-Dtarget=x86_64-linux"}, .windows));
}

test "output-path listing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    try tmp.dir.createDirPath(io, "zig-out/bin");
    try tmp.dir.createDirPath(io, "zig-out/package");

    // Empty outputs
    const empty_built = try findBuiltArtifacts(gpa, io, root);
    defer {
        for (empty_built) |b| gpa.free(b);
        gpa.free(empty_built);
    }
    try std.testing.expectEqual(@as(usize, 0), empty_built.len);

    const empty_pkg = try findPackageArtifacts(gpa, io, root);
    defer {
        for (empty_pkg) |p| gpa.free(p);
        gpa.free(empty_pkg);
    }
    try std.testing.expectEqual(@as(usize, 0), empty_pkg.len);

    // Populate bin files
    if (builtin.os.tag == .windows) {
        try tmp.dir.writeFile(io, .{ .sub_path = "zig-out/bin/my-app.exe", .data = "exe" });
        try tmp.dir.writeFile(io, .{ .sub_path = "zig-out/bin/my-app-dev.exe", .data = "dev" });
        try tmp.dir.writeFile(io, .{ .sub_path = "zig-out/bin/WebView2Loader.dll", .data = "dll" });
        try tmp.dir.writeFile(io, .{ .sub_path = "zig-out/bin/my-app.pdb", .data = "pdb" });
    } else {
        try tmp.dir.writeFile(io, .{ .sub_path = "zig-out/bin/my-app", .data = "exe" });
        try tmp.dir.writeFile(io, .{ .sub_path = "zig-out/bin/my-app-dev", .data = "dev" });
        try tmp.dir.writeFile(io, .{ .sub_path = "zig-out/bin/libmy-app.so", .data = "so" });
        try tmp.dir.writeFile(io, .{ .sub_path = "zig-out/bin/my-app.pdb", .data = "pdb" });
    }

    const built = try findBuiltArtifacts(gpa, io, root);
    defer {
        for (built) |b| gpa.free(b);
        gpa.free(built);
    }
    try std.testing.expectEqual(@as(usize, 1), built.len);
    const sep = std.fs.path.sep_str;
    const expected_exe = if (builtin.os.tag == .windows) "zig-out" ++ sep ++ "bin" ++ sep ++ "my-app.exe" else "zig-out/bin/my-app";
    try std.testing.expectEqualStrings(expected_exe, built[0]);

    // Populate package files
    try tmp.dir.writeFile(io, .{ .sub_path = "zig-out/package/my-app.deb", .data = "deb" });
    try tmp.dir.writeFile(io, .{ .sub_path = "zig-out/package/my-app.rpm", .data = "rpm" });
    try tmp.dir.writeFile(io, .{ .sub_path = "zig-out/package/.hidden", .data = "hidden" });

    const pkgs = try findPackageArtifacts(gpa, io, root);
    defer {
        for (pkgs) |p| gpa.free(p);
        gpa.free(pkgs);
    }
    try std.testing.expectEqual(@as(usize, 2), pkgs.len);
    try std.testing.expectEqualStrings("zig-out" ++ sep ++ "package" ++ sep ++ "my-app.deb", pkgs[0]);
    try std.testing.expectEqualStrings("zig-out" ++ sep ++ "package" ++ sep ++ "my-app.rpm", pkgs[1]);
}

test "optimize argument injection" {
    const gpa = std.testing.allocator;

    try std.testing.expect(!hasOptimizeArg(&.{}));
    try std.testing.expect(!hasOptimizeArg(&.{ "run", "--", "-Doptimize=ReleaseFast" }));
    try std.testing.expect(hasOptimizeArg(&.{"-Doptimize=ReleaseSafe"}));
    try std.testing.expect(hasOptimizeArg(&.{"-Doptimize=Debug"}));
    try std.testing.expect(hasOptimizeArg(&.{"-Doptimize"}));

    const args = [_][]const u8{ "run", "--", "app_arg" };
    const injected = try injectBuildArg(gpa, &args, "-Doptimize=ReleaseSafe");
    defer gpa.free(injected);
    try std.testing.expectEqual(@as(usize, 4), injected.len);
    try std.testing.expectEqualStrings("run", injected[0]);
    try std.testing.expectEqualStrings("-Doptimize=ReleaseSafe", injected[1]);
    try std.testing.expectEqualStrings("--", injected[2]);
    try std.testing.expectEqualStrings("app_arg", injected[3]);
}

test "isColdBuild detection" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    // No .zig-cache dir -> cold
    try std.testing.expect(isColdBuild(io, root));

    // Empty .zig-cache dir -> cold
    try tmp.dir.createDirPath(io, ".zig-cache");
    try std.testing.expect(isColdBuild(io, root));

    // .zig-cache with entry -> not cold
    try tmp.dir.writeFile(io, .{ .sub_path = ".zig-cache/cache-entry", .data = "cache" });
    try std.testing.expect(!isColdBuild(io, root));
}
