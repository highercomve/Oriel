//! `oriel setup`: install managed tools into ~/.oriel without administrator rights.
//!
//! Tools supported:
//!   - `nsis`: portable NSIS for Windows (nsis-3.12, pinned SHA-256) into ~/.oriel/nsis/3.12/
//!   - `node`: official Node.js LTS from https://nodejs.org/dist/ into ~/.oriel/node/<version>/
//!   - `webview2`: alias to `oriel webview2` (fetches WebView2Loader.dll from NuGet)
//!   - `zig`: alias to `oriel zig install`
//!   - `all`: install everything this host OS needs (skipping what is already present)

const std = @import("std");
const builtin = @import("builtin");
const Context = @import("Context.zig");
const doctor = @import("doctor.zig");
const webview2 = @import("webview2.zig");
const zig_manager = @import("zig_manager.zig");

const Dir = std.Io.Dir;

pub const Tool = enum {
    all,
    node,
    nsis,
    zig,
    webview2,
};

pub const Command = struct {
    pub const summary = "Install managed tools (~/.oriel/<tool>) without admin rights";
    pub const positionals = .{ "tool", "version" };
    pub const help = .{
        .tool = "all | node | nsis | zig | webview2",
        .version = "Optional tool version (node: LTS; nsis: pinned 3.12; zig: project minimum)",
        .yes = "Skip confirmation prompts",
    };
    pub const details =
        \\all                 Install everything this OS needs (skips what is already present)
        \\node [version]      Download and install official Node.js LTS into ~/.oriel/node/<v>
        \\nsis                On Windows hosts: download portable NSIS 3 into ~/.oriel/nsis/<v>
        \\                    On Linux/macOS: print package manager command to install makensis
        \\webview2            Alias to `oriel webview2` (downloads Microsoft WebView2Loader.dll)
        \\zig [version]       Alias to `oriel zig install`
    ;

    tool: Tool = .all,
    version: ?[]const u8 = null,
    yes: bool = false,
};

/// Pinned portable NSIS release (Windows hosts).
/// Download URL: https://downloads.sourceforge.net/project/nsis/NSIS%203/3.12/nsis-3.12.zip
pub const nsis_pinned_version = "3.12";
pub const nsis_pinned_url = "https://downloads.sourceforge.net/project/nsis/NSIS%203/3.12/nsis-3.12.zip";
pub const nsis_pinned_sha256 = "56581f90db321581c5381193d796fffcf2d24b2f8fed2160a6c6a3baa67f2c4f";

const node_dist_base = "https://nodejs.org/dist";
const max_node_download: usize = 300 << 20;
const max_nsis_download: usize = 50 << 20;
const max_node_extracted: u64 = 1 << 30;
const max_nsis_extracted: u64 = 200 << 20;
const max_small_download: usize = 2 << 20; // 2 MB for index.json / SHASUMS256.txt

// ---------------------------------------------------------------------------
// Path and Symlink Safety Guard
// ---------------------------------------------------------------------------

pub const PathGuard = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(gpa: std.mem.Allocator) PathGuard {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(g: *PathGuard) void {
        g.arena.deinit();
    }

    /// Normalized relative path (no "." parts, no trailing '/').
    pub fn check(g: *PathGuard, name: []const u8) ![]const u8 {
        if (webview2.isBadPath(name) or std.mem.indexOfScalar(u8, name, '\\') != null) return error.UnsafeArchivePath;
        const a = g.arena.allocator();
        var out: std.ArrayList(u8) = .empty;
        var parts = std.mem.tokenizeScalar(u8, name, '/');
        while (parts.next()) |part| {
            if (std.mem.eql(u8, part, ".")) continue;
            if (out.items.len > 0) try out.append(a, '/');
            try out.appendSlice(a, part);
        }
        if (out.items.len == 0) return error.UnsafeArchivePath;
        return out.items;
    }
};

/// Verify that a relative symlink stays inside the staging/destination root.
/// Absolute targets, targets with backslashes, colon, null bytes, or `..` sequences
/// that escape above the extraction root return false.
pub fn isSafeSymlinkTarget(link_path: []const u8, target: []const u8) bool {
    if (target.len == 0) return false;
    if (target[0] == '/' or target[0] == '\\') return false;
    if (std.mem.indexOfScalar(u8, target, 0) != null) return false;
    if (std.mem.indexOfScalar(u8, target, ':') != null) return false;
    if (std.mem.indexOfScalar(u8, target, '\\') != null) return false;

    // Calculate directory depth of link_path.
    // E.g. "node-v24.21.0-linux-x64/bin/npm" -> parent is "node-v24.21.0-linux-x64/bin" -> depth = 2.
    var depth: isize = 0;
    if (std.fs.path.dirname(link_path)) |parent| {
        var it = std.mem.tokenizeScalar(u8, parent, '/');
        while (it.next()) |p| {
            if (std.mem.eql(u8, p, ".")) continue;
            depth += 1;
        }
    }

    var target_it = std.mem.tokenizeScalar(u8, target, '/');
    while (target_it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            depth -= 1;
            if (depth < 0) return false;
        } else {
            depth += 1;
        }
    }
    return true;
}

// ---------------------------------------------------------------------------
// Hash Calculation
// ---------------------------------------------------------------------------

/// Stream and compute SHA-256 of a file.
pub fn hashFileSha256(io: std.Io, path: []const u8) ![32]u8 {
    const file = try Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &buf);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try reader.interface.readSliceShort(&chunk);
        if (n == 0) break;
        h.update(chunk[0..n]);
    }
    return h.finalResult();
}

// ---------------------------------------------------------------------------
// Node.js Index and SHASUMS Parsing
// ---------------------------------------------------------------------------

/// Select latest LTS version from nodejs.org index.json.
pub fn selectLatestLtsVersion(json_text: []const u8, gpa: std.mem.Allocator) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, json_text, .{});
    defer parsed.deinit();

    if (parsed.value != .array) return error.InvalidJson;
    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const lts_val = item.object.get("lts") orelse continue;
        const is_lts = switch (lts_val) {
            .bool => |b| b,
            .string => true,
            else => false,
        };
        if (!is_lts) continue;
        const ver_val = item.object.get("version") orelse continue;
        if (ver_val != .string) continue;
        return try gpa.dupe(u8, ver_val.string);
    }
    return error.NoLtsVersionFound;
}

/// Look up `target_filename` in SHASUMS256.txt content and return its 32-byte digest.
pub fn parseShasums256(text: []const u8, target_filename: []const u8) ?[32]u8 {
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len < 66) continue;
        const hash_str = trimmed[0..64];
        const rest = std.mem.trim(u8, trimmed[64..], " \t*");
        if (std.mem.eql(u8, rest, target_filename)) {
            var digest: [32]u8 = undefined;
            _ = std.fmt.hexToBytes(&digest, hash_str) catch return null;
            return digest;
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Locations & Managed Tool Discovery
// ---------------------------------------------------------------------------

pub fn nodeRoot(ctx: Context) ![]u8 {
    const home = try zig_manager.orielHome(ctx.gpa, ctx.environ);
    defer ctx.gpa.free(home);
    return std.fs.path.join(ctx.gpa, &.{ home, "node" });
}

pub fn nsisRoot(ctx: Context) ![]u8 {
    const home = try zig_manager.orielHome(ctx.gpa, ctx.environ);
    defer ctx.gpa.free(home);
    return std.fs.path.join(ctx.gpa, &.{ home, "nsis" });
}

pub const ManagedNode = struct {
    version: []u8,
    bin_dir: []u8,
    node_path: []u8,
    npm_path: []u8,

    pub fn deinit(self: ManagedNode, gpa: std.mem.Allocator) void {
        gpa.free(self.version);
        gpa.free(self.bin_dir);
        gpa.free(self.node_path);
        gpa.free(self.npm_path);
    }
};

/// Find the newest installed Node.js in ~/.oriel/node/.
pub fn findNewestManagedNode(ctx: Context) !?ManagedNode {
    const root = nodeRoot(ctx) catch return null;
    defer ctx.gpa.free(root);

    var dir = Dir.cwd().openDir(ctx.io, root, .{ .iterate = true }) catch return null;
    defer dir.close(ctx.io);

    var it = dir.iterate();
    var best_ver: ?std.SemanticVersion = null;
    var best_name: ?[]u8 = null;
    defer if (best_name) |n| ctx.gpa.free(n);

    const is_windows = builtin.os.tag == .windows;
    const node_exe_name = if (is_windows) "node.exe" else "node";

    while (try it.next(ctx.io)) |e| {
        if (e.kind != .directory) continue;
        const v_str = std.mem.trimStart(u8, e.name, "v");
        const semver = std.SemanticVersion.parse(v_str) catch continue;

        const check_rel = if (is_windows)
            try std.fs.path.join(ctx.gpa, &.{ e.name, node_exe_name })
        else
            try std.fs.path.join(ctx.gpa, &.{ e.name, "bin", node_exe_name });
        defer ctx.gpa.free(check_rel);

        dir.access(ctx.io, check_rel, .{}) catch continue;

        if (best_ver == null or semver.order(best_ver.?) == .gt) {
            // Parse from the copy: `pre`/`build` slice into the name, and
            // the iterator reuses its buffer.
            const copy = try ctx.gpa.dupe(u8, e.name);
            if (best_name) |prev| ctx.gpa.free(prev);
            best_name = copy;
            best_ver = std.SemanticVersion.parse(std.mem.trimStart(u8, copy, "v")) catch unreachable;
        }
    }

    if (best_name) |name| {
        const v_dup = try ctx.gpa.dupe(u8, name);
        errdefer ctx.gpa.free(v_dup);

        const bin_dir = if (is_windows)
            try std.fs.path.join(ctx.gpa, &.{ root, name })
        else
            try std.fs.path.join(ctx.gpa, &.{ root, name, "bin" });
        errdefer ctx.gpa.free(bin_dir);

        const node_path = try std.fs.path.join(ctx.gpa, &.{ bin_dir, if (is_windows) "node.exe" else "node" });
        errdefer ctx.gpa.free(node_path);

        const npm_path = try std.fs.path.join(ctx.gpa, &.{ bin_dir, if (is_windows) "npm.cmd" else "npm" });
        errdefer ctx.gpa.free(npm_path);

        return .{
            .version = v_dup,
            .bin_dir = bin_dir,
            .node_path = node_path,
            .npm_path = npm_path,
        };
    }
    return null;
}

/// Find installed portable makensis in ~/.oriel/nsis/.
pub fn findNewestManagedNsis(ctx: Context) !?[]u8 {
    const root = nsisRoot(ctx) catch return null;
    defer ctx.gpa.free(root);

    var dir = Dir.cwd().openDir(ctx.io, root, .{ .iterate = true }) catch return null;
    defer dir.close(ctx.io);

    var it = dir.iterate();
    while (try it.next(ctx.io)) |e| {
        if (e.kind != .directory) continue;
        const p1 = try std.fs.path.join(ctx.gpa, &.{ root, e.name, "makensis.exe" });
        if (Dir.cwd().access(ctx.io, p1, .{})) |_| {
            return p1;
        } else |_| ctx.gpa.free(p1);

        const p2 = try std.fs.path.join(ctx.gpa, &.{ root, e.name, "Bin", "makensis.exe" });
        if (Dir.cwd().access(ctx.io, p2, .{})) |_| {
            return p2;
        } else |_| ctx.gpa.free(p2);
    }
    return null;
}

pub fn isWindowsHost(ctx: Context) bool {
    if (ctx.environ.get("ORIEL_NSIS_PLATFORM")) |p| {
        if (std.mem.eql(u8, p, "windows") or std.mem.indexOf(u8, p, "windows") != null) return true;
    }
    if (ctx.environ.get("ORIEL_SETUP_PLATFORM")) |p| {
        if (std.mem.indexOf(u8, p, "windows") != null) return true;
    }
    return builtin.os.tag == .windows;
}

// ---------------------------------------------------------------------------
// Node Platform & Archive Naming
// ---------------------------------------------------------------------------

pub const PlatformInfo = struct {
    os: []const u8,
    arch: []const u8,
    ext: []const u8,
};

pub fn nodePlatformInfo(ctx: Context) PlatformInfo {
    if (ctx.environ.get("ORIEL_NODE_PLATFORM")) |p| if (p.len > 0) {
        if (std.mem.endsWith(u8, p, "-windows")) {
            const arch = if (std.mem.startsWith(u8, p, "aarch64") or std.mem.startsWith(u8, p, "arm64")) "arm64" else "x64";
            return .{ .os = "win", .arch = arch, .ext = "zip" };
        }
        if (std.mem.endsWith(u8, p, "-macos") or std.mem.endsWith(u8, p, "-darwin")) {
            const arch = if (std.mem.startsWith(u8, p, "aarch64") or std.mem.startsWith(u8, p, "arm64")) "arm64" else "x64";
            return .{ .os = "darwin", .arch = arch, .ext = "tar.gz" };
        }
        if (std.mem.endsWith(u8, p, "-linux")) {
            const arch = if (std.mem.startsWith(u8, p, "aarch64") or std.mem.startsWith(u8, p, "arm64")) "arm64" else "x64";
            return .{ .os = "linux", .arch = arch, .ext = "tar.xz" };
        }
    };
    if (ctx.environ.get("ORIEL_SETUP_PLATFORM")) |p| if (p.len > 0) {
        if (std.mem.indexOf(u8, p, "windows") != null) {
            const arch = if (std.mem.startsWith(u8, p, "aarch64") or std.mem.startsWith(u8, p, "arm64")) "arm64" else "x64";
            return .{ .os = "win", .arch = arch, .ext = "zip" };
        }
        if (std.mem.indexOf(u8, p, "macos") != null or std.mem.indexOf(u8, p, "darwin") != null) {
            const arch = if (std.mem.startsWith(u8, p, "aarch64") or std.mem.startsWith(u8, p, "arm64")) "arm64" else "x64";
            return .{ .os = "darwin", .arch = arch, .ext = "tar.gz" };
        }
        if (std.mem.indexOf(u8, p, "linux") != null) {
            const arch = if (std.mem.startsWith(u8, p, "aarch64") or std.mem.startsWith(u8, p, "arm64")) "arm64" else "x64";
            return .{ .os = "linux", .arch = arch, .ext = "tar.xz" };
        }
    };

    const os_name = switch (builtin.os.tag) {
        .windows => "win",
        .macos => "darwin",
        else => "linux",
    };
    const arch_name = switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        else => "x64",
    };
    const ext = switch (builtin.os.tag) {
        .windows => "zip",
        .macos => "tar.gz",
        else => "tar.xz",
    };
    return .{ .os = os_name, .arch = arch_name, .ext = ext };
}

pub fn nodeArchiveName(gpa: std.mem.Allocator, version: []const u8, info: PlatformInfo) ![]u8 {
    return std.fmt.allocPrint(gpa, "node-{s}-{s}-{s}.{s}", .{ version, info.os, info.arch, info.ext });
}

// ---------------------------------------------------------------------------
// Extraction
// ---------------------------------------------------------------------------

fn extractTar(ctx: Context, it: *std.tar.Iterator, dest: Dir, max_extracted: u64) !void {
    const io = ctx.io;
    var guard: PathGuard = .init(ctx.gpa);
    defer guard.deinit();
    var total: u64 = 0;
    var write_buf: [64 * 1024]u8 = undefined;

    while (try it.next()) |entry| {
        switch (entry.kind) {
            .directory => try dest.createDirPath(io, try guard.check(entry.name)),
            .file => {
                const path = try guard.check(entry.name);
                if (entry.size > max_extracted - total) return error.ArchiveTooLarge;
                total += entry.size;
                if (std.fs.path.dirname(path)) |parent| try dest.createDirPath(io, parent);
                const exec = builtin.os.tag != .windows and ((entry.mode & 0o100) != 0 or std.mem.indexOf(u8, path, "/bin/") != null);
                const out = try dest.createFile(io, path, .{
                    .exclusive = true,
                    .permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(if (exec) 0o755 else 0o644),
                });
                defer out.close(io);
                var w = out.writer(io, &write_buf);
                try it.streamRemaining(entry, &w.interface);
                try w.interface.flush();
            },
            .sym_link => {
                const link_path = try guard.check(entry.name);
                if (!isSafeSymlinkTarget(link_path, entry.link_name)) return error.UnsafeArchivePath;
                if (std.fs.path.dirname(link_path)) |parent| try dest.createDirPath(io, parent);
                if (builtin.os.tag != .windows) {
                    try dest.symLink(io, entry.link_name, link_path, .{});
                }
            },
        }
    }
}

fn extractTarXz(ctx: Context, archive: []const u8, dest: Dir, max_extracted: u64) !void {
    const io = ctx.io;
    const file = try Dir.cwd().openFile(io, archive, .{});
    defer file.close(io);
    var read_buf: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &read_buf);
    const xz_buf = try ctx.gpa.alloc(u8, 1 << 16);
    var xz = std.compress.xz.Decompress.init(&reader.interface, ctx.gpa, xz_buf) catch |err| {
        ctx.gpa.free(xz_buf);
        return err;
    };
    defer xz.deinit();

    var name_buf: [Dir.max_path_bytes]u8 = undefined;
    var link_buf: [Dir.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&xz.reader, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    try extractTar(ctx, &it, dest, max_extracted);
}

fn extractTarGz(ctx: Context, archive: []const u8, dest: Dir, max_extracted: u64) !void {
    const io = ctx.io;
    const file = try Dir.cwd().openFile(io, archive, .{});
    defer file.close(io);
    var read_buf: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &read_buf);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var d: std.compress.flate.Decompress = .init(&reader.interface, .gzip, &window);

    var name_buf: [Dir.max_path_bytes]u8 = undefined;
    var link_buf: [Dir.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&d.reader, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    try extractTar(ctx, &it, dest, max_extracted);
}

fn extractZip(ctx: Context, archive: []const u8, dest: Dir, max_extracted: u64) !void {
    const io = ctx.io;
    const file = try Dir.cwd().openFile(io, archive, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buf);
    var guard: PathGuard = .init(ctx.gpa);
    defer guard.deinit();
    var total: u64 = 0;
    var name_buf: [Dir.max_path_bytes]u8 = undefined;
    var iter = try std.zip.Iterator.init(&reader);
    while (try iter.next()) |entry| {
        if (entry.filename_len == 0 or entry.filename_len > name_buf.len) return error.UnsafeArchivePath;
        try reader.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        try reader.interface.readSliceAll(name_buf[0..entry.filename_len]);
        _ = try guard.check(name_buf[0..entry.filename_len]);
        if (entry.uncompressed_size > max_extracted - total) return error.ArchiveTooLarge;
        total += entry.uncompressed_size;
        try entry.extract(&reader, .{}, &name_buf, dest);
    }
}

// ---------------------------------------------------------------------------
// Node.js Installer
// ---------------------------------------------------------------------------

pub fn installNode(ctx: Context, requested_version: ?[]const u8) ![]u8 {
    const io = ctx.io;
    const gpa = ctx.gpa;
    const root = try nodeRoot(ctx);
    defer gpa.free(root);
    try Dir.cwd().createDirPath(io, root);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();

    // 1. Resolve version
    const version = if (requested_version) |v|
        if (std.mem.startsWith(u8, v, "v")) try arena.dupe(u8, v) else try std.fmt.allocPrint(arena, "v{s}", .{v})
    else blk: {
        try ctx.err.print("Resolving latest Node.js LTS from {s}/index.json...\n", .{node_dist_base});
        ctx.flush();
        const index_url = try std.fmt.allocPrint(arena, "{s}/index.json", .{node_dist_base});
        const index_bytes = try zig_manager.downloadMemory(ctx, &client, index_url, 4 * 1024 * 1024);
        defer gpa.free(index_bytes);
        const lts_ver = try selectLatestLtsVersion(index_bytes, arena);
        break :blk lts_ver;
    };

    const final_dir = try std.fs.path.join(arena, &.{ root, version });
    const info = nodePlatformInfo(ctx);
    const archive_name = try nodeArchiveName(arena, version, info);

    const is_windows = std.mem.eql(u8, info.os, "win");
    const node_exe_name = if (is_windows) "node.exe" else "node";
    const installed_exe_rel = if (is_windows)
        try std.fs.path.join(arena, &.{ version, node_exe_name })
    else
        try std.fs.path.join(arena, &.{ version, "bin", node_exe_name });
    const installed_exe_path = try std.fs.path.join(gpa, &.{ root, installed_exe_rel });
    errdefer gpa.free(installed_exe_path);

    if (Dir.cwd().access(io, installed_exe_path, .{})) |_| {
        try ctx.err.print("Node.js {s} already installed in {s}\n", .{ version, final_dir });
        return installed_exe_path;
    } else |_| {}

    // 2. Fetch SHASUMS256.txt
    const shasums_url = try std.fmt.allocPrint(arena, "{s}/{s}/SHASUMS256.txt", .{ node_dist_base, version });
    try ctx.err.print("Fetching checksums: {s}\n", .{shasums_url});
    ctx.flush();
    const shasums_bytes = try zig_manager.downloadMemory(ctx, &client, shasums_url, 512 * 1024);
    defer gpa.free(shasums_bytes);

    const expected_digest = parseShasums256(shasums_bytes, archive_name) orelse {
        try ctx.err.print("error: {s} not found in {s}\n", .{ archive_name, shasums_url });
        return error.ChecksumNotFound;
    };

    // 3. Download archive to staging
    var rand: u64 = undefined;
    io.random(std.mem.asBytes(&rand));
    const staging = try std.fs.path.join(arena, &.{ root, try std.fmt.allocPrint(arena, ".staging-{x}", .{rand}) });
    try Dir.cwd().createDirPath(io, staging);
    defer Dir.cwd().deleteTree(io, staging) catch {};

    const archive_path = try std.fs.path.join(arena, &.{ staging, archive_name });
    const download_url = try std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ node_dist_base, version, archive_name });

    try ctx.err.print("Installing Node.js {s} ({s}) into {s}\n", .{ version, archive_name, final_dir });
    try ctx.err.print("  downloading {s}\n", .{download_url});
    ctx.flush();

    try zig_manager.downloadToFile(ctx, &client, download_url, archive_path, max_node_download, null);

    // 4. Verify SHA-256
    const computed_digest = try hashFileSha256(io, archive_path);
    if (!std.mem.eql(u8, &computed_digest, &expected_digest)) {
        try ctx.err.print("error: SHA-256 checksum mismatch for {s}\n", .{archive_name});
        return error.HashMismatch;
    }
    try ctx.err.print("  SHA-256 verified against SHASUMS256.txt\n", .{});
    ctx.flush();

    // 5. Extract archive
    const extract_dir = try std.fs.path.join(arena, &.{ staging, "x" });
    try Dir.cwd().createDirPath(io, extract_dir);
    {
        var dest = try Dir.cwd().openDir(io, extract_dir, .{});
        defer dest.close(io);
        if (std.mem.endsWith(u8, archive_name, ".zip")) {
            try extractZip(ctx, archive_path, dest, max_node_extracted);
        } else if (std.mem.endsWith(u8, archive_name, ".tar.xz")) {
            try extractTarXz(ctx, archive_path, dest, max_node_extracted);
        } else if (std.mem.endsWith(u8, archive_name, ".tar.gz")) {
            try extractTarGz(ctx, archive_path, dest, max_node_extracted);
        } else return error.UnsupportedArchiveFormat;
    }

    // 6. Find top-level extracted directory
    var top: ?[]const u8 = null;
    {
        var dir = try Dir.cwd().openDir(io, extract_dir, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |e| {
            if (e.kind != .directory or top != null) return error.UnexpectedArchiveLayout;
            top = try arena.dupe(u8, e.name);
        }
    }
    const top_dir = try std.fs.path.join(arena, &.{ extract_dir, top orelse return error.UnexpectedArchiveLayout });
    const top_exe = if (is_windows)
        try std.fs.path.join(arena, &.{ top_dir, "node.exe" })
    else
        try std.fs.path.join(arena, &.{ top_dir, "bin", "node" });
    Dir.cwd().access(io, top_exe, .{}) catch return error.UnexpectedArchiveLayout;

    // 7. Atomic rename under lock
    const lock_path = try std.fs.path.join(arena, &.{ root, ".install.lock" });
    const lock = try Dir.cwd().createFile(io, lock_path, .{ .truncate = false, .lock = .exclusive });
    defer lock.close(io);

    if (Dir.cwd().access(io, installed_exe_path, .{})) |_| return installed_exe_path else |_| {}
    Dir.cwd().deleteTree(io, final_dir) catch {};

    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        Dir.cwd().rename(top_dir, Dir.cwd(), final_dir, io) catch |err| {
            if (builtin.os.tag != .windows or attempt >= 5) return err;
            io.sleep(.fromMilliseconds(200), .awake) catch {};
            continue;
        };
        break;
    }

    try ctx.err.print("Installed Node.js {s}: {s}\n", .{ version, installed_exe_path });
    try ctx.err.writeAll("Managed tools under ~/.oriel are used automatically by oriel (no PATH change needed).\n");
    ctx.flush();
    return installed_exe_path;
}

// ---------------------------------------------------------------------------
// NSIS Installer
// ---------------------------------------------------------------------------

pub const NsisInstallResult = union(enum) {
    installed: []u8,
    printed_package_command,
};

pub fn installNsis(ctx: Context) !NsisInstallResult {
    const io = ctx.io;
    const gpa = ctx.gpa;

    // Non-Windows host (unless platform override) prints package command
    if (!isWindowsHost(ctx)) {
        if (builtin.os.tag == .macos) {
            try ctx.out.writeAll(
                \\NSIS is not downloaded on macOS. Install it with Homebrew:
                \\  brew install makensis
                \\
            );
        } else {
            const os_release = Dir.cwd().readFileAlloc(io, "/etc/os-release", gpa, .limited(64 * 1024)) catch "";
            defer if (os_release.len > 0) gpa.free(os_release);
            const distro = doctor.distroFromOsRelease(os_release);
            try ctx.out.writeAll("NSIS is not downloaded on Linux. Install it with your package manager:\n");
            switch (distro orelse .apt) {
                .pacman => try ctx.out.writeAll("  sudo pacman -S --needed nsis\n"),
                .apt => try ctx.out.writeAll("  sudo apt install nsis\n"),
                .dnf => try ctx.out.writeAll("  sudo dnf install mingw32-nsis\n"),
                .zypper => try ctx.out.writeAll("  sudo zypper install nsis\n"),
                else => try ctx.out.writeAll("  sudo apt install nsis  # or pacman/dnf/zypper\n"),
            }
        }
        ctx.flush();
        return .printed_package_command;
    }

    const root = try nsisRoot(ctx);
    defer gpa.free(root);
    try Dir.cwd().createDirPath(io, root);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();

    const final_dir = try std.fs.path.join(arena, &.{ root, nsis_pinned_version });
    const makensis_path = try std.fs.path.join(gpa, &.{ final_dir, "makensis.exe" });
    errdefer gpa.free(makensis_path);

    if (Dir.cwd().access(io, makensis_path, .{})) |_| {
        try ctx.err.print("NSIS {s} already installed in {s}\n", .{ nsis_pinned_version, final_dir });
        return .{ .installed = makensis_path };
    } else |_| {}

    var rand: u64 = undefined;
    io.random(std.mem.asBytes(&rand));
    const staging = try std.fs.path.join(arena, &.{ root, try std.fmt.allocPrint(arena, ".staging-{x}", .{rand}) });
    try Dir.cwd().createDirPath(io, staging);
    defer Dir.cwd().deleteTree(io, staging) catch {};

    const zip_name = "nsis-" ++ nsis_pinned_version ++ ".zip";
    const archive_path = try std.fs.path.join(arena, &.{ staging, zip_name });

    try ctx.err.print("Installing NSIS {s} into {s}\n", .{ nsis_pinned_version, final_dir });
    try ctx.err.print("  downloading {s}\n", .{nsis_pinned_url});
    ctx.flush();

    try zig_manager.downloadToFile(ctx, &client, nsis_pinned_url, archive_path, max_nsis_download, null);

    // Verify pinned SHA-256
    const digest = try hashFileSha256(io, archive_path);
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, nsis_pinned_sha256)) {
        try ctx.err.print("error: SHA-256 checksum mismatch for NSIS {s}\n", .{nsis_pinned_version});
        return error.HashMismatch;
    }
    try ctx.err.print("  SHA-256 verified ({s})\n", .{nsis_pinned_sha256});
    ctx.flush();

    // Extract zip
    const extract_dir = try std.fs.path.join(arena, &.{ staging, "x" });
    try Dir.cwd().createDirPath(io, extract_dir);
    {
        var dest = try Dir.cwd().openDir(io, extract_dir, .{});
        defer dest.close(io);
        try extractZip(ctx, archive_path, dest, max_nsis_extracted);
    }

    // Locate top-level directory
    var top: ?[]const u8 = null;
    {
        var dir = try Dir.cwd().openDir(io, extract_dir, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |e| {
            if (e.kind != .directory or top != null) return error.UnexpectedArchiveLayout;
            top = try arena.dupe(u8, e.name);
        }
    }
    const top_dir = try std.fs.path.join(arena, &.{ extract_dir, top orelse return error.UnexpectedArchiveLayout });
    const top_exe = try std.fs.path.join(arena, &.{ top_dir, "makensis.exe" });
    Dir.cwd().access(io, top_exe, .{}) catch return error.UnexpectedArchiveLayout;

    // Atomic rename under lock
    const lock_path = try std.fs.path.join(arena, &.{ root, ".install.lock" });
    const lock = try Dir.cwd().createFile(io, lock_path, .{ .truncate = false, .lock = .exclusive });
    defer lock.close(io);

    if (Dir.cwd().access(io, makensis_path, .{})) |_| return .{ .installed = makensis_path } else |_| {}
    Dir.cwd().deleteTree(io, final_dir) catch {};

    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        Dir.cwd().rename(top_dir, Dir.cwd(), final_dir, io) catch |err| {
            if (builtin.os.tag != .windows or attempt >= 5) return err;
            io.sleep(.fromMilliseconds(200), .awake) catch {};
            continue;
        };
        break;
    }

    try ctx.err.print("Installed NSIS {s}: {s}\n", .{ nsis_pinned_version, makensis_path });
    try ctx.err.writeAll("Managed tools under ~/.oriel are used automatically by oriel (no PATH change needed).\n");
    ctx.flush();
    return .{ .installed = makensis_path };
}

// ---------------------------------------------------------------------------
// `oriel setup`
// ---------------------------------------------------------------------------

pub fn run(ctx: Context, cmd: Command) !u8 {
    switch (cmd.tool) {
        .all => {
            try ctx.out.writeAll("Setting up tools needed for this environment...\n");
            ctx.flush();

            // 1. Zig
            const want_zig = try zig_manager.requiredHere(ctx);
            defer ctx.gpa.free(want_zig);
            const p = zig_manager.plan(ctx, want_zig) catch null;
            if (p) |plan| {
                defer plan.deinit(ctx.gpa);
                if (plan.choice.source == .install) {
                    try ctx.out.print("Installing Zig {s}...\n", .{want_zig});
                    ctx.flush();
                    const z = zig_manager.install(ctx, want_zig) catch return 1;
                    ctx.gpa.free(z);
                } else {
                    try ctx.out.print("Zig {s} present ({s})\n", .{ want_zig, plan.choice.source.label() });
                }
            }

            // 2. Node.js
            const has_system_node = (try ctx.findExecutable("node")) != null;
            var managed_node = try findNewestManagedNode(ctx);
            defer if (managed_node) |*mn| mn.deinit(ctx.gpa);

            if (!has_system_node and managed_node == null) {
                try ctx.out.writeAll("Installing Node.js LTS...\n");
                ctx.flush();
                const node_exe = installNode(ctx, cmd.version) catch return 1;
                ctx.gpa.free(node_exe);
            } else {
                try ctx.out.writeAll("Node.js is present\n");
            }

            // 3. Windows tools
            if (isWindowsHost(ctx)) {
                // WebView2 loader
                const maybe_x64 = try webview2.findNewestCached(ctx.gpa, ctx.io, ctx.environ, "x64");
                defer if (maybe_x64) |x| x.deinit(ctx.gpa);
                if (maybe_x64 == null) {
                    try ctx.out.writeAll("Fetching WebView2Loader.dll...\n");
                    ctx.flush();
                    webview2.fetch(ctx, .all, null, null) catch |e| {
                        try ctx.err.print("warning: failed to fetch WebView2Loader.dll: {s}\n", .{@errorName(e)});
                    };
                } else {
                    try ctx.out.writeAll("WebView2Loader.dll is present\n");
                }

                // NSIS
                const has_makensis = (try ctx.findExecutable("makensis")) != null;
                const managed_nsis = try findNewestManagedNsis(ctx);
                defer if (managed_nsis) |m| ctx.gpa.free(m);
                if (!has_makensis and managed_nsis == null) {
                    try ctx.out.writeAll("Installing NSIS 3...\n");
                    ctx.flush();
                    const res = installNsis(ctx) catch return 1;
                    switch (res) {
                        .installed => |path| ctx.gpa.free(path),
                        .printed_package_command => {},
                    }
                } else {
                    try ctx.out.writeAll("NSIS is present\n");
                }
            }

            try ctx.out.writeAll("Setup complete.\n");
            try ctx.out.writeAll("Managed tools under ~/.oriel are used automatically by oriel (no PATH change needed).\n");
            return 0;
        },
        .node => {
            const path = installNode(ctx, cmd.version) catch return 1;
            defer ctx.gpa.free(path);
            try ctx.out.print("{s}\n", .{path});
            return 0;
        },
        .nsis => {
            const res = installNsis(ctx) catch return 1;
            switch (res) {
                .installed => |path| {
                    defer ctx.gpa.free(path);
                    try ctx.out.print("{s}\n", .{path});
                    try ctx.out.writeAll("Managed tools under ~/.oriel are used automatically by oriel (no PATH change needed).\n");
                },
                .printed_package_command => {},
            }
            return 0;
        },
        .webview2 => {
            return webview2.run(ctx, .{ .arch = .all, .version = cmd.version });
        },
        .zig => {
            return zig_manager.run(ctx, .{ .action = .install, .version = cmd.version });
        },
    }
}

// ---------------------------------------------------------------------------
// Tests (silent, no network)
// ---------------------------------------------------------------------------

const testing = std.testing;

test selectLatestLtsVersion {
    const json =
        \\[
        \\  {"version": "v26.10.0", "lts": false},
        \\  {"version": "v24.21.0", "lts": "Krypton"},
        \\  {"version": "v24.20.0", "lts": "Krypton"},
        \\  {"version": "v22.14.0", "lts": "Jod"}
        \\]
    ;
    const v = try selectLatestLtsVersion(json, testing.allocator);
    defer testing.allocator.free(v);
    try testing.expectEqualStrings("v24.21.0", v);

    const no_lts =
        \\[
        \\  {"version": "v26.10.0", "lts": false}
        \\]
    ;
    try testing.expectError(error.NoLtsVersionFound, selectLatestLtsVersion(no_lts, testing.allocator));
    try testing.expectError(error.InvalidJson, selectLatestLtsVersion("{}", testing.allocator));
}

test parseShasums256 {
    const text =
        \\158f7685b44de51f6c0df1d153526cbcd3e1bc739a8dfc607721cef75de9e541  node-v24.21.0-win-x64.zip
        \\6ad1325edbdb5649c379b75a237147a666c95d4f9ae8d340fef2d1575d289ad2  node-v24.21.0-linux-arm64.tar.xz
        \\bed7eea5325e1108f32ce5228ddd6a5f0f08a499ee42aa7442aea583702f6057 *node-v24.21.0-darwin-arm64.tar.gz
    ;
    const d1 = parseShasums256(text, "node-v24.21.0-win-x64.zip").?;
    const hex1 = std.fmt.bytesToHex(d1, .lower);
    try testing.expectEqualStrings("158f7685b44de51f6c0df1d153526cbcd3e1bc739a8dfc607721cef75de9e541", &hex1);

    const d2 = parseShasums256(text, "node-v24.21.0-darwin-arm64.tar.gz").?;
    const hex2 = std.fmt.bytesToHex(d2, .lower);
    try testing.expectEqualStrings("bed7eea5325e1108f32ce5228ddd6a5f0f08a499ee42aa7442aea583702f6057", &hex2);

    try testing.expectEqual(null, parseShasums256(text, "missing.tar.xz"));
}

test "isSafeSymlinkTarget allows relative links inside root and rejects escaping ones" {
    // Relative link staying inside root: allowed (Node.js style npm/npx symlinks)
    try testing.expect(isSafeSymlinkTarget("node-v24/bin/npm", "../lib/node_modules/npm/bin/npm-cli.js"));
    try testing.expect(isSafeSymlinkTarget("node-v24/bin/npx", "../lib/node_modules/npm/bin/npx-cli.js"));
    try testing.expect(isSafeSymlinkTarget("a/b/c/link", "../../x"));
    try testing.expect(isSafeSymlinkTarget("a/b/link", "../x"));

    // Links that escape above extraction root: rejected
    try testing.expect(!isSafeSymlinkTarget("link", "../outside"));
    try testing.expect(!isSafeSymlinkTarget("a/link", "../../outside"));
    try testing.expect(!isSafeSymlinkTarget("node-v24/bin/npm", "../../../etc/passwd"));
    try testing.expect(!isSafeSymlinkTarget("node-v24/bin/npm", "../../../../outside"));

    // Absolute links: rejected
    try testing.expect(!isSafeSymlinkTarget("bin/npm", "/etc/passwd"));
    try testing.expect(!isSafeSymlinkTarget("bin/npm", "\\Windows\\System32"));
    try testing.expect(!isSafeSymlinkTarget("bin/npm", "C:/Windows"));

    // Bad characters: rejected
    try testing.expect(!isSafeSymlinkTarget("bin/npm", "foo\\bar"));
    try testing.expect(!isSafeSymlinkTarget("bin/npm", ""));
}

test "PathGuard rejects path traversal and malformed paths" {
    var g = PathGuard.init(testing.allocator);
    defer g.deinit();

    try testing.expectEqualStrings("node-v24/bin/node", try g.check("./node-v24/bin/node"));
    try testing.expectError(error.UnsafeArchivePath, g.check("/etc/passwd"));
    try testing.expectError(error.UnsafeArchivePath, g.check("../escaped"));
    try testing.expectError(error.UnsafeArchivePath, g.check("a/../../escaped"));
    try testing.expectError(error.UnsafeArchivePath, g.check("C:/Windows"));
    try testing.expectError(error.UnsafeArchivePath, g.check("a\\b"));
}

test "pinned nsis release values" {
    try testing.expectEqualStrings("3.12", nsis_pinned_version);
    try testing.expectEqualStrings("https://downloads.sourceforge.net/project/nsis/NSIS%203/3.12/nsis-3.12.zip", nsis_pinned_url);
    try testing.expectEqual(64, nsis_pinned_sha256.len);
}
