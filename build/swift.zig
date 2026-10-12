//! Swift sources of iOS app extensions (`AppOptions.extensions[].ios.swift_sources`):
//! compiled by `swiftc` into one object per extension and linked into the
//! app with the Swift runtime from the OS (/usr/lib/swift, iOS 12.2+).
//!
//! `swiftc` is `$SWIFTC`, else `xcrun --find swiftc` on a Mac, else
//! `swiftc` on PATH (the swift.org toolchain on Linux). It compiles against
//! the same SDK as the rest of the app (-Dapple_sdk / $APPLE_SDK; on Linux,
//! the one `xtool setup` extracts). A Linux swiftc doesn't ship Darwin's
//! Swift modules: they come from xtool's darwin.artifactbundle
//! (swift-sdk.json's swiftResourcesPath), or -Dswift_resource_dir /
//! $SWIFT_RESOURCE_DIR.

const std = @import("std");

var swiftc_cache: ?struct { b: *std.Build, path: ?[]const u8 } = null;

/// The Swift compiler, or null.
pub fn findSwiftc(b: *std.Build) ?[]const u8 {
    if (swiftc_cache) |c| if (c.b == b) return c.path;
    const found: ?[]const u8 = blk: {
        if (b.graph.environ_map.get("SWIFTC")) |s| if (s.len > 0) break :blk s;
        if (b.graph.host.result.os.tag == .macos) {
            var code: u8 = undefined;
            if (b.runAllowFail(&.{ "xcrun", "--find", "swiftc" }, &code, .ignore)) |out| {
                const path = std.mem.trim(u8, out, " \r\n");
                if (path.len > 0) break :blk path;
            } else |_| {}
        }
        break :blk onPath(b, "swiftc");
    };
    swiftc_cache = .{ .b = b, .path = found };
    return found;
}

/// `name` in $PATH, as found: not through its symlinks (b.findProgram
/// resolves them), because swiftc is a symlink to swift-driver, which picks
/// its mode by the name it was run as.
fn onPath(b: *std.Build, name: []const u8) ?[]const u8 {
    const path = b.graph.environ_map.get("PATH") orelse return null;
    var it = std.mem.tokenizeScalar(u8, path, std.fs.path.delimiter);
    while (it.next()) |dir| {
        const full = b.pathJoin(&.{ dir, name });
        std.Io.Dir.cwd().access(b.graph.io, full, .{}) catch continue;
        return full;
    }
    return null;
}

/// `arm64-apple-ios15.0`, `arm64-apple-ios15.0-simulator`, `x86_64-apple-ios15.0-simulator`.
pub fn triple(b: *std.Build, target: std.Target) []const u8 {
    return tripleOf(b.allocator, target) catch @panic("OOM");
}

pub fn tripleOf(gpa: std.mem.Allocator, target: std.Target) ![]u8 {
    const arch = if (target.cpu.arch == .aarch64) "arm64" else "x86_64";
    const min = target.os.version_range.semver.min;
    return std.fmt.allocPrint(gpa, "{s}-apple-ios{d}.{d}{s}", .{ arch, min.major, min.minor, if (target.abi == .simulator) "-simulator" else "" });
}

pub const Flags = struct {
    module_name: []const u8,
    triple: []const u8,
    sdk: []const u8,
    resource_dir: ?[]const u8,
    optimize: std.builtin.OptimizeMode,
};

/// swiftc's arguments before the bridging header, the output and the
/// sources (`compile` adds those as build paths).
pub fn flags(gpa: std.mem.Allocator, f: Flags) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, &.{ "-parse-as-library", "-emit-object", "-wmo", "-module-name", f.module_name, "-target", f.triple, "-sdk", f.sdk });
    if (f.resource_dir) |dir| try out.appendSlice(gpa, &.{ "-resource-dir", dir });
    // The OS's Swift runtime only: no back-deployment libraries from the
    // toolchain (Oriel's minimum, iOS 15, has the runtime and Concurrency).
    try out.appendSlice(gpa, &.{ "-runtime-compatibility-version", "none", if (f.optimize == .Debug) "-Onone" else "-O" });
    return out.toOwnedSlice(gpa);
}

test tripleOf {
    const gpa = std.testing.allocator;
    const q = struct {
        fn t(arch: std.Target.Cpu.Arch, abi: std.Target.Abi) !std.Target {
            return std.zig.system.resolveTargetQuery(std.testing.io, .{ .cpu_arch = arch, .os_tag = .ios, .abi = abi, .os_version_min = .{ .semver = .{ .major = 15, .minor = 0, .patch = 0 } } });
        }
    };
    const cases = [_]struct { std.Target.Cpu.Arch, std.Target.Abi, []const u8 }{
        .{ .aarch64, .none, "arm64-apple-ios15.0" },
        .{ .aarch64, .simulator, "arm64-apple-ios15.0-simulator" },
        .{ .x86_64, .simulator, "x86_64-apple-ios15.0-simulator" },
    };
    for (cases) |c| {
        const s = try tripleOf(gpa, try q.t(c[0], c[1]));
        defer gpa.free(s);
        try std.testing.expectEqualStrings(c[2], s);
    }
}

test flags {
    const gpa = std.testing.allocator;
    const device = try flags(gpa, .{ .module_name = "OrielExtension_a_b", .triple = "arm64-apple-ios15.0", .sdk = "/sdk/iPhoneOS.sdk", .resource_dir = null, .optimize = .ReleaseSafe });
    defer gpa.free(device);
    const want = [_][]const u8{ "-parse-as-library", "-emit-object", "-wmo", "-module-name", "OrielExtension_a_b", "-target", "arm64-apple-ios15.0", "-sdk", "/sdk/iPhoneOS.sdk", "-runtime-compatibility-version", "none", "-O" };
    try std.testing.expectEqual(want.len, device.len);
    for (want, device) |w, d| try std.testing.expectEqualStrings(w, d);
    const sim = try flags(gpa, .{ .module_name = "M", .triple = "arm64-apple-ios15.0-simulator", .sdk = "/sdk/iPhoneSimulator.sdk", .resource_dir = "/bundle/usr/lib/swift", .optimize = .Debug });
    defer gpa.free(sim);
    try std.testing.expectEqualStrings("-resource-dir", sim[9]);
    try std.testing.expectEqualStrings("/bundle/usr/lib/swift", sim[10]);
    try std.testing.expectEqualStrings("-Onone", sim[sim.len - 1]);
}

/// The Darwin Swift resource directory for a non-Apple swiftc, or null
/// (Xcode's swiftc finds its own).
pub fn resourceDir(b: *std.Build, sdk: []const u8, target: std.Target) ?[]const u8 {
    if (resource_dir_cache) |c| if (c.b == b) return c.path;
    const path = findResourceDir(b, sdk, target);
    resource_dir_cache = .{ .b = b, .path = path };
    return path;
}

var resource_dir_cache: ?struct { b: *std.Build, path: ?[]const u8 } = null;

fn findResourceDir(b: *std.Build, sdk: []const u8, target: std.Target) ?[]const u8 {
    if (b.option([]const u8, "swift_resource_dir", "iOS Swift sources on Linux: the Darwin Swift resource directory (default: from xtool's darwin.artifactbundle)")) |d| return d;
    if (b.graph.environ_map.get("SWIFT_RESOURCE_DIR")) |d| if (d.len > 0) return d;
    if (b.graph.host.result.os.tag == .macos) return null;
    const marker = "darwin.artifactbundle";
    const at = std.mem.indexOf(u8, sdk, marker) orelse return null;
    const bundle = sdk[0 .. at + marker.len];
    const key = b.fmt("{s}-apple-ios{s}", .{ if (target.cpu.arch == .aarch64) "arm64" else "x86_64", if (target.abi == .simulator) "-simulator" else "" });
    return fromSwiftSdkJson(b, bundle, key);
}

/// swift-sdk.json (SwiftPM's Swift SDK schema) in `bundle`:
/// targetTriples[key].swiftResourcesPath, relative to the file.
fn fromSwiftSdkJson(b: *std.Build, bundle: []const u8, key: []const u8) ?[]const u8 {
    const io = b.graph.io;
    var dir = std.Io.Dir.cwd().openDir(io, bundle, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var walker = dir.walk(b.allocator) catch return null;
    defer walker.deinit();
    // A bundle holds a few hundred thousand files at most: bounded.
    var seen: usize = 0;
    while (walker.next(io) catch null) |entry| : (seen += 1) {
        if (seen > 1_000_000) break;
        if (entry.kind != .file or !std.mem.eql(u8, entry.basename, "swift-sdk.json")) continue;
        const path = b.pathJoin(&.{ bundle, entry.path });
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, b.allocator, .limited(1 << 20)) catch continue;
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, b.allocator, text, .{}) catch continue;
        if (parsed != .object) continue;
        const triples = parsed.object.get("targetTriples") orelse continue;
        if (triples != .object) continue;
        const t = triples.object.get(key) orelse continue;
        if (t != .object) continue;
        const res = t.object.get("swiftResourcesPath") orelse continue;
        if (res != .string) continue;
        if (std.fs.path.isAbsolute(res.string)) return res.string;
        return b.pathJoin(&.{ std.fs.path.dirname(path) orelse bundle, res.string });
    }
    return null;
}

/// One object from `sources` (module `module_name`), with `header` as the
/// bridging header (oriel_extension.h).
pub fn compile(
    b: *std.Build,
    swiftc: []const u8,
    sources: []const std.Build.LazyPath,
    module_name: []const u8,
    target: std.Target,
    sdk: []const u8,
    header: std.Build.LazyPath,
    optimize: std.builtin.OptimizeMode,
) std.Build.LazyPath {
    const run = b.addSystemCommand(&.{swiftc});
    run.addArgs(flags(b.allocator, .{
        .module_name = module_name,
        .triple = triple(b, target),
        .sdk = sdk,
        .resource_dir = resourceDir(b, sdk, target),
        .optimize = optimize,
    }) catch @panic("OOM"));
    run.addArg("-import-objc-header");
    run.addFileArg(header);
    run.addArg("-o");
    const obj = run.addOutputFileArg(b.fmt("{s}.o", .{module_name}));
    for (sources) |s| run.addFileArg(s);
    return obj;
}

/// The lowest iOS an app with Swift sources can target. iOS 18 split the
/// Darwin overlay into libswift_errno, _math, … whose SDK stubs tell Apple's
/// ld (`$ld$previous`) to record libswiftDarwin below 18.0; Zig's linker
/// records the new names, which iOS 15–17 don't have.
pub const min_ios: std.SemanticVersion = .{ .major = 18, .minor = 0, .patch = 0 };

/// Link the Swift runtime libraries an extension's object needs: the SDK's
/// stubs, the OS's libraries at run time.
pub fn linkRuntime(module: *std.Build.Module, sdk: []const u8) void {
    const b = module.owner;
    module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib/swift" }) });
    for ([_][]const u8{ "swiftCore", "swiftFoundation", "swiftObjectiveC", "swiftDarwin", "swiftDispatch", "swiftCoreFoundation", "swiftXPC" }) |lib|
        module.linkSystemLibrary(lib, .{});
    module.addRPathSpecial("/usr/lib/swift");
}
