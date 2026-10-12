//! Swift sources of iOS app extensions (`AppOptions.extensions[].ios.swift_sources`)
//! and of iOS and macOS platform hooks (`.ios.hooks`, `.macos.hooks`):
//! compiled by `swiftc` into one object per extension or hook and linked
//! into the app with the Swift runtime from the OS (/usr/lib/swift).
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

/// `arm64-apple-ios15.0`, `arm64-apple-ios15.0-simulator`,
/// `x86_64-apple-ios15.0-simulator`; `arm64-apple-macos15.0`,
/// `x86_64-apple-macos15.0`.
pub fn triple(b: *std.Build, target: std.Target) []const u8 {
    return tripleOf(b.allocator, target) catch @panic("OOM");
}

pub fn tripleOf(gpa: std.mem.Allocator, target: std.Target) ![]u8 {
    const arch = if (target.cpu.arch == .aarch64) "arm64" else "x86_64";
    const min = target.os.version_range.semver.min;
    const os = if (target.os.tag == .macos) "macos" else "ios";
    return std.fmt.allocPrint(gpa, "{s}-apple-{s}{d}.{d}{s}", .{ arch, os, min.major, min.minor, if (target.abi == .simulator) "-simulator" else "" });
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
        fn t(arch: std.Target.Cpu.Arch, os: std.Target.Os.Tag, abi: std.Target.Abi) !std.Target {
            return std.zig.system.resolveTargetQuery(std.testing.io, .{ .cpu_arch = arch, .os_tag = os, .abi = abi, .os_version_min = .{ .semver = .{ .major = 15, .minor = 0, .patch = 0 } } });
        }
    };
    const cases = [_]struct { std.Target.Cpu.Arch, std.Target.Os.Tag, std.Target.Abi, []const u8 }{
        .{ .aarch64, .ios, .none, "arm64-apple-ios15.0" },
        .{ .aarch64, .ios, .simulator, "arm64-apple-ios15.0-simulator" },
        .{ .x86_64, .ios, .simulator, "x86_64-apple-ios15.0-simulator" },
        .{ .aarch64, .macos, .none, "arm64-apple-macos15.0" },
        .{ .x86_64, .macos, .none, "x86_64-apple-macos15.0" },
    };
    for (cases) |c| {
        const s = try tripleOf(gpa, try q.t(c[0], c[1], c[2]));
        defer gpa.free(s);
        try std.testing.expectEqualStrings(c[3], s);
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
    if (b.option([]const u8, "swift_resource_dir", "Swift sources on Linux: the Darwin Swift resource directory (default: from xtool's darwin.artifactbundle)")) |d| return d;
    if (b.graph.environ_map.get("SWIFT_RESOURCE_DIR")) |d| if (d.len > 0) return d;
    if (b.graph.host.result.os.tag == .macos) return null;
    const marker = "darwin.artifactbundle";
    const at = std.mem.indexOf(u8, sdk, marker) orelse return null;
    const bundle = sdk[0 .. at + marker.len];
    const key = sdkJsonKey(b.allocator, target) catch @panic("OOM");
    return fromSwiftSdkJson(b, bundle, key);
}

/// The target triple swift-sdk.json lists for `target`: `arm64-apple-ios`,
/// `arm64-apple-ios-simulator`, `arm64-apple-macosx`.
pub fn sdkJsonKey(gpa: std.mem.Allocator, target: std.Target) ![]u8 {
    const arch = if (target.cpu.arch == .aarch64) "arm64" else "x86_64";
    if (target.os.tag == .macos) return std.fmt.allocPrint(gpa, "{s}-apple-macosx", .{arch});
    return std.fmt.allocPrint(gpa, "{s}-apple-ios{s}", .{ arch, if (target.abi == .simulator) "-simulator" else "" });
}

test sdkJsonKey {
    const gpa = std.testing.allocator;
    const mac = try std.zig.system.resolveTargetQuery(std.testing.io, .{ .cpu_arch = .aarch64, .os_tag = .macos });
    const key = try sdkJsonKey(gpa, mac);
    defer gpa.free(key);
    try std.testing.expectEqualStrings("arm64-apple-macosx", key);
    const sim = try std.zig.system.resolveTargetQuery(std.testing.io, .{ .cpu_arch = .aarch64, .os_tag = .ios, .abi = .simulator });
    const key2 = try sdkJsonKey(gpa, sim);
    defer gpa.free(key2);
    try std.testing.expectEqualStrings("arm64-apple-ios-simulator", key2);
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
/// bridging header (include/oriel_swift.h), the headers it imports found in
/// `include_dirs`; `extra` goes before the sources (frameworks it must not
/// autolink, for weak links).
pub fn compile(
    b: *std.Build,
    swiftc: []const u8,
    sources: []const std.Build.LazyPath,
    module_name: []const u8,
    target: std.Target,
    sdk: []const u8,
    header: std.Build.LazyPath,
    include_dirs: []const std.Build.LazyPath,
    optimize: std.builtin.OptimizeMode,
    extra: []const []const u8,
) std.Build.LazyPath {
    const run = b.addSystemCommand(&.{swiftc});
    run.addArgs(flags(b.allocator, .{
        .module_name = module_name,
        .triple = triple(b, target),
        .sdk = sdk,
        .resource_dir = resourceDir(b, sdk, target),
        .optimize = optimize,
    }) catch @panic("OOM"));
    run.addArgs(extra);
    for (include_dirs) |dir| {
        run.addArg("-Xcc");
        run.addPrefixedDirectoryArg("-I", dir);
    }
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

/// The lowest macOS an app with Swift sources can target, for the same
/// reason: Swift 6 split the Darwin overlay on macOS 15 too (with iOS 18),
/// with the same `$ld$previous` stubs, and macOS 13 and 14 lack the new
/// libraries.
pub const min_macos: std.SemanticVersion = .{ .major = 15, .minor = 0, .patch = 0 };

/// `min_ios` or `min_macos`, for `os`.
pub fn minFor(os: std.Target.Os.Tag) std.SemanticVersion {
    return if (os == .macos) min_macos else min_ios;
}

/// The Swift libraries every Swift object links (strong, always loaded):
/// the runtime, Foundation's and Darwin's overlays, Concurrency (in the OS
/// from iOS 15 and macOS 12).
pub const baseline = [_][]const u8{ "swiftCore", "swiftFoundation", "swiftObjectiveC", "swiftDarwin", "swiftDispatch", "swiftCoreFoundation", "swiftXPC", "swift_Concurrency" };

/// Link the Swift runtime and overlay libraries the app's Swift objects
/// need: the SDK's stubs, the OS's libraries (/usr/lib/swift) at run time.
///
/// swiftc records each library a module imports (`import CoreML` →
/// libswiftCoreML, -framework CoreML, transitively) as LC_LINKER_OPTION
/// autolink entries, and Zig's linker ignores them; the link inputs are
/// fixed before swiftc runs. So: `baseline`, then every other
/// `libswift*.tbd` the SDK has, with `dead_strip_dylibs` on: the linker
/// keeps only the dylibs something references (swiftc's
/// `__swift_FORCE_LOAD_$_swiftX` symbols reference each overlay used), and
/// every framework and library already in the link (Oriel's, the app's,
/// those the Swift sources import: `linkImportedFrameworks`; classes are
/// looked up by name, with no symbol reference) is marked `needed` so it
/// stays.
pub fn linkRuntime(exe: *std.Build.Step.Compile, sdk: []const u8) void {
    const module = exe.root_module;
    const b = module.owner;
    keepLinkedLibraries(module);
    const dir_path = b.pathJoin(&.{ sdk, "usr/lib/swift" });
    module.addLibraryPath(.{ .cwd_relative = dir_path });
    for (baseline) |lib| module.linkSystemLibrary(lib, .{ .needed = true, .use_pkg_config = .no });
    // The SDK's other overlays, in a stable order.
    var names: std.ArrayList([]const u8) = .empty;
    if (std.Io.Dir.cwd().openDir(b.graph.io, dir_path, .{ .iterate = true })) |dir_const| {
        var dir = dir_const;
        defer dir.close(b.graph.io);
        var it = dir.iterate();
        // An SDK has around a hundred: bounded.
        var seen: usize = 0;
        while (it.next(b.graph.io) catch null) |entry| : (seen += 1) {
            if (seen > 10_000) break;
            const lib = overlayLibrary(entry.name) orelse continue;
            if (contains(&baseline, lib)) continue;
            names.append(b.allocator, b.dupe(lib)) catch @panic("OOM");
        }
    } else |_| {}
    std.mem.sortUnstable([]const u8, names.items, {}, lessThan);
    for (names.items) |lib| module.linkSystemLibrary(lib, .{ .use_pkg_config = .no });
    exe.dead_strip_dylibs = true;
    module.addRPathSpecial("/usr/lib/swift");
}

fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// "swiftCoreML" for "libswiftCoreML.tbd"; null for anything else (the
/// remote-mirror and demangling libraries aren't overlays).
pub fn overlayLibrary(file: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, file, "libswift") or !std.mem.endsWith(u8, file, ".tbd")) return null;
    const lib = file["lib".len .. file.len - ".tbd".len];
    for ([_][]const u8{ "swiftRemoteMirror", "swiftDemangle" }) |p| if (std.mem.startsWith(u8, lib, p)) return null;
    return lib;
}

test overlayLibrary {
    try std.testing.expectEqualStrings("swiftCoreML", overlayLibrary("libswiftCoreML.tbd").?);
    try std.testing.expectEqualStrings("swift_Concurrency", overlayLibrary("libswift_Concurrency.tbd").?);
    try std.testing.expect(overlayLibrary("libswiftRemoteMirror42.tbd") == null);
    try std.testing.expect(overlayLibrary("libswiftDemangle.tbd") == null);
    try std.testing.expect(overlayLibrary("libobjc.tbd") == null);
    try std.testing.expect(overlayLibrary("CoreML.swiftmodule") == null);
}

/// Mark every framework and system library in `root`'s module graph as
/// needed (weak ones stay droppable), so `dead_strip_dylibs` keeps them.
fn keepLinkedLibraries(root: *std.Build.Module) void {
    var stack: [64]*std.Build.Module = undefined;
    var visited: [256]*std.Build.Module = undefined;
    var stack_len: usize = 1;
    var visited_len: usize = 0;
    stack[0] = root;
    // Bounded: each module once, at most `visited.len`.
    while (stack_len > 0) {
        stack_len -= 1;
        const m = stack[stack_len];
        if (std.mem.indexOfScalar(*std.Build.Module, visited[0..visited_len], m) != null) continue;
        if (visited_len == visited.len) @panic("swift: more than 256 modules in the app's graph");
        visited[visited_len] = m;
        visited_len += 1;
        for (m.frameworks.values()) |*opts| if (!opts.weak) {
            opts.needed = true;
        };
        for (m.link_objects.items) |*obj| switch (obj.*) {
            .system_lib => |*lib| if (!lib.weak) {
                lib.needed = true;
            },
            else => {},
        };
        for (m.import_table.values()) |dep| {
            if (stack_len == stack.len) @panic("swift: module graph too deep");
            stack[stack_len] = dep;
            stack_len += 1;
        }
    }
}

/// The modules `text` (Swift source) imports: `import X`, `import X.Sub`,
/// `import struct X.Y`, `@testable`/`@_implementationOnly`/`@preconcurrency
/// import X`, one per line. Up to `out.len`; returns how many.
pub fn importedModules(text: []const u8, out: [][]const u8) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (n == out.len) break;
        var line = std.mem.trim(u8, raw, " \t\r");
        // Attributes and access modifiers before `import`.
        while (line.len > 0 and line[0] == '@') {
            const sp = std.mem.indexOfAny(u8, line, " \t") orelse break;
            line = std.mem.trimStart(u8, line[sp..], " \t");
        }
        for ([_][]const u8{ "public ", "internal ", "package ", "private ", "fileprivate " }) |m| {
            if (std.mem.startsWith(u8, line, m)) line = std.mem.trimStart(u8, line[m.len..], " \t");
        }
        if (!std.mem.startsWith(u8, line, "import ")) continue;
        var rest = std.mem.trimStart(u8, line["import ".len..], " \t");
        for ([_][]const u8{ "struct ", "class ", "enum ", "protocol ", "typealias ", "func ", "var ", "let ", "actor " }) |k| {
            if (std.mem.startsWith(u8, rest, k)) rest = std.mem.trimStart(u8, rest[k.len..], " \t");
        }
        var end: usize = 0;
        while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_')) end += 1;
        if (end == 0) continue;
        out[n] = rest[0..end];
        n += 1;
    }
    return n;
}

test importedModules {
    const src =
        \\import Foundation
        \\import CoreML
        \\@preconcurrency import Vision
        \\  import struct CoreGraphics.CGRect
        \\@_implementationOnly import Metal.MTLDevice
        \\// import NotThis
        \\let importer = 1
    ;
    var out: [8][]const u8 = undefined;
    const n = importedModules(src, &out);
    const want = [_][]const u8{ "Foundation", "CoreML", "Vision", "CoreGraphics", "Metal" };
    try std.testing.expectEqual(want.len, n);
    for (want, out[0..n]) |w, got| try std.testing.expectEqualStrings(w, got);
}

/// Link the SDK frameworks `sources` import (Zig ignores swiftc's
/// autolinking): those with a `<Name>.framework` in the SDK and not in
/// `weak` (linked weakly by the caller). Call it before `linkRuntime`,
/// which keeps them (as every framework already linked). Sources must be files in the
/// source tree or absolute paths (read while configuring); others are
/// skipped.
pub fn linkImportedFrameworks(module: *std.Build.Module, sdk: []const u8, sources: []const std.Build.LazyPath, weak: []const []const u8) void {
    const b = module.owner;
    for (sources) |src| {
        const path = switch (src) {
            .src_path => |s| s.owner.pathFromRoot(s.sub_path),
            .cwd_relative => |p| p,
            else => continue,
        };
        const text = std.Io.Dir.cwd().readFileAlloc(b.graph.io, path, b.allocator, .limited(4 << 20)) catch continue;
        var found: [128][]const u8 = undefined;
        const n = importedModules(text, &found);
        for (found[0..n]) |name| {
            if (std.mem.eql(u8, name, "Swift") or std.mem.startsWith(u8, name, "_")) continue;
            if (contains(weak, name)) continue;
            const dir = b.pathJoin(&.{ sdk, "System/Library/Frameworks", b.fmt("{s}.framework", .{name}) });
            std.Io.Dir.cwd().access(b.graph.io, dir, .{}) catch continue;
            module.linkFramework(b.dupe(name), .{});
        }
    }
}
