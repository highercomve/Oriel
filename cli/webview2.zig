//! `oriel webview2`: download, verify, and cache Microsoft Edge WebView2Loader.dll.
//!
//! Chain of trust:
//! 1. NuGet flatcontainer index (https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/index.json)
//!    lists all published versions. The newest non-prerelease version is resolved (unless --version pins).
//! 2. NuGet registration catalog (https://api.nuget.org/v3/registration5-semver1/microsoft.web.webview2/<ver>.json)
//!    points to the authoritative catalogEntry.
//! 3. The catalogEntry contains the Microsoft package SHA-512 (base64) and algorithm ("SHA512").
//! 4. The package (https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/<ver>/microsoft.web.webview2.<ver>.nupkg)
//!    is downloaded, and its SHA-512 digest is computed and verified against the catalog hash.
//! 5. Upon verification, runtimes/win-x64/native/WebView2Loader.dll and/or
//!    runtimes/win-arm64/native/WebView2Loader.dll are extracted using std.zip (with path traversal checks)
//!    and stored atomically into the local cache.

const std = @import("std");
const builtin = @import("builtin");
const Context = @import("Context.zig");

pub const Arch = enum {
    x64,
    arm64,
    all,
};

pub const Command = struct {
    pub const summary = "Download and cache WebView2Loader.dll for Windows";
    pub const help = .{
        .version = "Specific NuGet package version (default: latest stable)",
        .arch = "Architecture to extract: x64, arm64, or all (default: all)",
        .out = "Optional directory to copy the extracted DLL(s) to",
    };
    pub const values = .{
        .version = "nuget-version",
        .arch = "x64|arm64|all",
        .out = "dir",
    };
    pub const details =
        \\Downloads Microsoft.Web.WebView2 from NuGet, verifies its SHA-512
        \\package hash against the NuGet registration catalog, extracts
        \\WebView2Loader.dll for the requested architecture, and caches it.
    ;

    version: ?[]const u8 = null,
    arch: Arch = .all,
    out: ?[]const u8 = null,
};

pub const default_index_url = "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/index.json";
pub const default_registration_base = "https://api.nuget.org/v3/registration5-semver1/microsoft.web.webview2";
pub const default_flatcontainer_base = "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2";

// ---------------------------------------------------------------------------
// Version parsing & comparison
// ---------------------------------------------------------------------------

pub const Version = struct {
    parts: [4]u32 = [_]u32{ 0, 0, 0, 0 },
    part_count: usize = 0,
    prerelease: ?[]const u8 = null,

    pub fn parse(s: []const u8) ?Version {
        var v = Version{};
        const dash = std.mem.indexOfScalar(u8, s, '-');
        const num_part = if (dash) |d| s[0..d] else s;
        if (dash) |d| v.prerelease = s[d + 1 ..];

        var it = std.mem.splitScalar(u8, num_part, '.');
        while (it.next()) |part| {
            if (v.part_count >= 4) return null;
            if (part.len == 0) return null;
            const n = std.fmt.parseInt(u32, part, 10) catch return null;
            v.parts[v.part_count] = n;
            v.part_count += 1;
        }
        if (v.part_count == 0) return null;
        return v;
    }

    pub fn order(a: Version, b: Version) std.math.Order {
        for (0..4) |idx| {
            if (a.parts[idx] < b.parts[idx]) return .lt;
            if (a.parts[idx] > b.parts[idx]) return .gt;
        }
        // Stable versions rank higher than prerelease with same numeric version
        if (a.prerelease == null and b.prerelease != null) return .gt;
        if (a.prerelease != null and b.prerelease == null) return .lt;
        if (a.prerelease != null and b.prerelease != null) {
            return std.mem.order(u8, a.prerelease.?, b.prerelease.?);
        }
        return .eq;
    }
};

/// Select the latest stable version from index.json, skipping prereleases.
pub fn selectLatestStableVersion(json_bytes: []const u8, gpa: std.mem.Allocator) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, json_bytes, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidJson;
    const versions_val = root.object.get("versions") orelse return error.InvalidJson;
    if (versions_val != .array) return error.InvalidJson;

    var best_ver: ?Version = null;
    var best_str: ?[]const u8 = null;

    for (versions_val.array.items) |item| {
        if (item != .string) continue;
        const v_str = item.string;
        // Skip prereleases (containing hyphen)
        if (std.mem.indexOfScalar(u8, v_str, '-') != null) continue;
        const v = Version.parse(v_str) orelse continue;
        if (best_ver == null or Version.order(v, best_ver.?) == .gt) {
            best_ver = v;
            best_str = v_str;
        }
    }

    if (best_str) |s| {
        return try gpa.dupe(u8, s);
    }
    return error.NoStableVersionFound;
}

// ---------------------------------------------------------------------------
// Cache paths & discovery
// ---------------------------------------------------------------------------

pub fn getCacheRoot(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]u8 {
    if (builtin.os.tag == .windows) {
        if (environ.get("LOCALAPPDATA")) |appdata| {
            if (appdata.len > 0) return try std.fs.path.join(gpa, &.{ appdata, "oriel", "cache", "webview2" });
        }
        if (environ.get("USERPROFILE")) |profile| {
            if (profile.len > 0) return try std.fs.path.join(gpa, &.{ profile, "AppData", "Local", "oriel", "cache", "webview2" });
        }
        return try gpa.dupe(u8, "oriel_cache\\webview2");
    } else {
        if (environ.get("XDG_CACHE_HOME")) |xdg| {
            if (xdg.len > 0) return try std.fs.path.join(gpa, &.{ xdg, "oriel", "webview2" });
        }
        if (environ.get("HOME")) |home| {
            if (home.len > 0) return try std.fs.path.join(gpa, &.{ home, ".cache", "oriel", "webview2" });
        }
        return try gpa.dupe(u8, ".cache/oriel/webview2");
    }
}

pub fn getCacheDir(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map, version: []const u8, arch: []const u8) ![]u8 {
    const root = try getCacheRoot(gpa, environ);
    defer gpa.free(root);
    return try std.fs.path.join(gpa, &.{ root, version, arch });
}

pub fn getCacheDllPath(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map, version: []const u8, arch: []const u8) ![]u8 {
    const dir = try getCacheDir(gpa, environ, version, arch);
    defer gpa.free(dir);
    return try std.fs.path.join(gpa, &.{ dir, "WebView2Loader.dll" });
}

pub const CachedLoader = struct {
    version: []u8,
    path: []u8,

    pub fn deinit(self: CachedLoader, gpa: std.mem.Allocator) void {
        gpa.free(self.version);
        gpa.free(self.path);
    }
};

/// Find newest cached WebView2Loader.dll for the given architecture.
pub fn findNewestCached(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    arch: []const u8,
) !?CachedLoader {
    const root = try getCacheRoot(gpa, environ);
    defer gpa.free(root);

    var root_dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return null;
    defer root_dir.close(io);

    var it = root_dir.iterate();
    var best_ver_str: ?[]u8 = null;
    defer if (best_ver_str) |s| gpa.free(s);
    var best_ver: ?Version = null;

    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const v = Version.parse(entry.name) orelse continue;

        const dll_subpath = try std.fs.path.join(gpa, &.{ entry.name, arch, "WebView2Loader.dll" });
        defer gpa.free(dll_subpath);

        root_dir.access(io, dll_subpath, .{}) catch continue;

        if (best_ver == null or Version.order(v, best_ver.?) == .gt) {
            if (best_ver_str) |prev| gpa.free(prev);
            best_ver_str = try gpa.dupe(u8, entry.name);
            best_ver = v;
        }
    }

    if (best_ver_str) |v_str| {
        const full_path = try std.fs.path.join(gpa, &.{ root, v_str, arch, "WebView2Loader.dll" });
        const ver_dup = try gpa.dupe(u8, v_str);
        return .{ .version = ver_dup, .path = full_path };
    }
    return null;
}

pub fn isCached(
    io: std.Io,
    environ: *const std.process.Environ.Map,
    version: []const u8,
    arch: []const u8,
    gpa: std.mem.Allocator,
) bool {
    const dll_path = getCacheDllPath(gpa, environ, version, arch) catch return false;
    defer gpa.free(dll_path);
    std.Io.Dir.cwd().access(io, dll_path, .{}) catch return false;
    return true;
}

// ---------------------------------------------------------------------------
// Atomic installation
// ---------------------------------------------------------------------------

pub fn atomicInstall(
    io: std.Io,
    gpa: std.mem.Allocator,
    target_dir_path: []const u8,
    filename: []const u8,
    data: []const u8,
) ![]u8 {
    try std.Io.Dir.cwd().createDirPath(io, target_dir_path);
    var dir = try std.Io.Dir.cwd().openDir(io, target_dir_path, .{});
    defer dir.close(io);

    var rand_val: u64 = undefined;
    io.random(std.mem.asBytes(&rand_val));
    const temp_name = try std.fmt.allocPrint(gpa, "{s}.tmp.{x}", .{ filename, rand_val });
    defer gpa.free(temp_name);

    const temp_file = try dir.createFile(io, temp_name, .{
        .permissions = if (builtin.os.tag == .windows) .default_file else std.Io.File.Permissions.fromMode(0o755),
        .exclusive = true,
    });

    var temp_open = true;
    var temp_exists = true;
    defer {
        if (temp_open) temp_file.close(io);
        if (temp_exists) dir.deleteFile(io, temp_name) catch {};
    }

    var write_buf: [16 * 1024]u8 = undefined;
    var writer = temp_file.writerStreaming(io, &write_buf);
    try writer.interface.writeAll(data);
    try writer.end();
    try temp_file.sync(io);

    temp_file.close(io);
    temp_open = false;

    try dir.rename(temp_name, dir, filename, io);
    temp_exists = false;

    return try std.fs.path.join(gpa, &.{ target_dir_path, filename });
}

// ---------------------------------------------------------------------------
// Catalog parsing & Hash Verification
// ---------------------------------------------------------------------------

pub const CatalogResult = union(enum) {
    catalog_url: []const u8,
    package_hash: []const u8,
};

pub fn parseRegistrationJson(json_bytes: []const u8, gpa: std.mem.Allocator) !CatalogResult {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, json_bytes, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidJson;
    const entry_val = parsed.value.object.get("catalogEntry") orelse return error.MissingCatalogEntry;

    switch (entry_val) {
        .string => |url| return .{ .catalog_url = try gpa.dupe(u8, url) },
        .object => |obj| {
            if (obj.get("packageHash")) |h| {
                if (h == .string) return .{ .package_hash = try gpa.dupe(u8, h.string) };
            }
            if (obj.get("@id")) |id| {
                if (id == .string) return .{ .catalog_url = try gpa.dupe(u8, id.string) };
            }
            return error.InvalidCatalogEntry;
        },
        else => return error.InvalidCatalogEntry,
    }
}

pub fn parseCatalogItemJson(json_bytes: []const u8, gpa: std.mem.Allocator) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, json_bytes, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidJson;
    const hash_val = parsed.value.object.get("packageHash") orelse return error.MissingPackageHash;
    if (hash_val != .string) return error.InvalidPackageHash;

    if (parsed.value.object.get("packageHashAlgorithm")) |algo_val| {
        if (algo_val == .string and !std.mem.eql(u8, algo_val.string, "SHA512")) {
            return error.UnsupportedHashAlgorithm;
        }
    }

    return try gpa.dupe(u8, hash_val.string);
}

pub fn verifyHash(nupkg_bytes: []const u8, expected_b64: []const u8) !void {
    var digest: [64]u8 = undefined;
    std.crypto.hash.sha2.Sha512.hash(nupkg_bytes, &digest, .{});

    var b64_buf: [std.base64.standard.Encoder.calcSize(64)]u8 = undefined;
    const computed_b64 = std.base64.standard.Encoder.encode(&b64_buf, &digest);

    const trimmed_expected = std.mem.trim(u8, expected_b64, " \t\r\n");
    if (!std.mem.eql(u8, computed_b64, trimmed_expected)) {
        return error.PackageHashMismatch;
    }
}

// ---------------------------------------------------------------------------
// Zip Extraction
// ---------------------------------------------------------------------------

pub const ExtractedResult = struct {
    x64: bool = false,
    arm64: bool = false,
};

pub fn isBadPath(path: []const u8) bool {
    if (path.len == 0) return true;
    if (path[0] == '/' or path[0] == '\\') return true;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return true;
    if (std.mem.indexOfScalar(u8, path, ':') != null) return true;

    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return true;
    }
    return false;
}

pub fn extractLoadersFromZip(
    io: std.Io,
    zip_file: std.Io.File,
    extract_x64: bool,
    extract_arm64: bool,
    dest_dir: std.Io.Dir,
) !ExtractedResult {
    var result = ExtractedResult{};
    var buf: [16 * 1024]u8 = undefined;
    var file_reader = zip_file.reader(io, &buf);

    var iter = try std.zip.Iterator.init(&file_reader);
    while (try iter.next()) |entry| {
        if (entry.filename_len == 0 or entry.filename_len > 1024) continue;
        var name_buf: [1024]u8 = undefined;
        try file_reader.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        try file_reader.interface.readSliceAll(name_buf[0..entry.filename_len]);
        const filename = name_buf[0..entry.filename_len];

        if (isBadPath(filename)) {
            return error.ZipPathTraversal;
        }

        const is_x64_dll = std.mem.eql(u8, filename, "runtimes/win-x64/native/WebView2Loader.dll");
        const is_arm64_dll = std.mem.eql(u8, filename, "runtimes/win-arm64/native/WebView2Loader.dll");

        if (is_x64_dll and extract_x64) {
            try entry.extract(&file_reader, .{}, &name_buf, dest_dir);
            result.x64 = true;
        } else if (is_arm64_dll and extract_arm64) {
            try entry.extract(&file_reader, .{}, &name_buf, dest_dir);
            result.arm64 = true;
        }
    }

    if (extract_x64 and !result.x64) return error.EntryNotFound;
    if (extract_arm64 and !result.arm64) return error.EntryNotFound;

    return result;
}

// ---------------------------------------------------------------------------
// High-level fetch & run
// ---------------------------------------------------------------------------

pub fn fetch(ctx: Context, arch: Arch, version_opt: ?[]const u8, out_dir: ?[]const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = ctx.io;

    const want_x64 = (arch == .x64 or arch == .all);
    const want_arm64 = (arch == .arm64 or arch == .all);

    // 1. Resolve version
    const version = if (version_opt) |v|
        try arena.dupe(u8, std.mem.trim(u8, v, " \t\r\n"))
    else blk: {
        var client: std.http.Client = .{ .allocator = arena, .io = io };
        defer client.deinit();

        var body: std.Io.Writer.Allocating = .init(arena);
        defer body.deinit();

        const index_url = ctx.environ.get("ORIEL_WEBVIEW2_INDEX_URL") orelse default_index_url;
        const res = client.fetch(.{
            .location = .{ .url = index_url },
            .headers = .{ .user_agent = .{ .override = "oriel-cli" } },
            .response_writer = &body.writer,
        }) catch |err| {
            try ctx.err.print("error: failed to fetch NuGet package versions: {s}\n", .{@errorName(err)});
            return err;
        };
        if (res.status != .ok) {
            try ctx.err.print("error: NuGet index returned HTTP {d}\n", .{@intFromEnum(res.status)});
            return error.BadHttpStatus;
        }
        break :blk try selectLatestStableVersion(body.written(), arena);
    };

    // 2. Check if already cached
    var all_cached = true;
    if (want_x64 and !isCached(io, ctx.environ, version, "x64", arena)) all_cached = false;
    if (want_arm64 and !isCached(io, ctx.environ, version, "arm64", arena)) all_cached = false;

    if (all_cached) {
        if (want_x64) {
            const p = try getCacheDllPath(arena, ctx.environ, version, "x64");
            try ctx.out.print("WebView2Loader.dll (x64) {s} is already cached at {s}\n", .{ version, p });
            if (out_dir) |od| {
                const data = try std.Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(10 * 1024 * 1024));
                const out_x64_dir = if (arch == .all) try std.fs.path.join(arena, &.{ od, "x64" }) else od;
                const copied_x64 = try atomicInstall(io, arena, out_x64_dir, "WebView2Loader.dll", data);
                try ctx.out.print("  copied to {s}\n", .{copied_x64});
                if (arch == .all) {
                    const copied_root = try atomicInstall(io, arena, od, "WebView2Loader.dll", data);
                    try ctx.out.print("  copied to {s}\n", .{copied_root});
                }
            }
        }
        if (want_arm64) {
            const p = try getCacheDllPath(arena, ctx.environ, version, "arm64");
            try ctx.out.print("WebView2Loader.dll (arm64) {s} is already cached at {s}\n", .{ version, p });
            if (out_dir) |od| {
                const data = try std.Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(10 * 1024 * 1024));
                const out_arm64_dir = if (arch == .all) try std.fs.path.join(arena, &.{ od, "arm64" }) else od;
                const copied_arm64 = try atomicInstall(io, arena, out_arm64_dir, "WebView2Loader.dll", data);
                try ctx.out.print("  copied to {s}\n", .{copied_arm64});
            }
        }
        return;
    }

    // 3. Fetch NuGet registration catalog entry to get authoritative package SHA-512
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();

    const reg_base = ctx.environ.get("ORIEL_WEBVIEW2_REGISTRATION_URL") orelse default_registration_base;
    const reg_url = try std.fmt.allocPrint(arena, "{s}/{s}.json", .{ reg_base, version });

    var reg_body: std.Io.Writer.Allocating = .init(arena);
    defer reg_body.deinit();

    const reg_res = client.fetch(.{
        .location = .{ .url = reg_url },
        .headers = .{ .user_agent = .{ .override = "oriel-cli" } },
        .response_writer = &reg_body.writer,
    }) catch |err| {
        try ctx.err.print("error: failed to fetch registration catalog for version {s}: {s}\n", .{ version, @errorName(err) });
        return err;
    };
    if (reg_res.status != .ok) {
        try ctx.err.print("error: registration catalog returned HTTP {d}\n", .{@intFromEnum(reg_res.status)});
        return error.BadHttpStatus;
    }

    const cat_result = try parseRegistrationJson(reg_body.written(), arena);
    const expected_hash = switch (cat_result) {
        .package_hash => |h| h,
        .catalog_url => |item_url| blk: {
            var item_body: std.Io.Writer.Allocating = .init(arena);
            defer item_body.deinit();
            const item_res = client.fetch(.{
                .location = .{ .url = item_url },
                .headers = .{ .user_agent = .{ .override = "oriel-cli" } },
                .response_writer = &item_body.writer,
            }) catch |err| {
                try ctx.err.print("error: failed to fetch catalog item at {s}: {s}\n", .{ item_url, @errorName(err) });
                return err;
            };
            if (item_res.status != .ok) {
                try ctx.err.print("error: catalog item returned HTTP {d}\n", .{@intFromEnum(item_res.status)});
                return error.BadHttpStatus;
            }
            break :blk try parseCatalogItemJson(item_body.written(), arena);
        },
    };

    // 4. Create temporary working directory inside cache root
    const cache_root = try getCacheRoot(arena, ctx.environ);
    try std.Io.Dir.cwd().createDirPath(io, cache_root);

    var rand_id: u64 = undefined;
    io.random(std.mem.asBytes(&rand_id));
    const tmp_working_dir_name = try std.fmt.allocPrint(arena, "tmp.{x}", .{rand_id});
    const tmp_working_path = try std.fs.path.join(arena, &.{ cache_root, tmp_working_dir_name });
    try std.Io.Dir.cwd().createDirPath(io, tmp_working_path);
    defer std.Io.Dir.cwd().deleteTree(io, tmp_working_path) catch {};

    var tmp_working_dir = try std.Io.Dir.cwd().openDir(io, tmp_working_path, .{});
    defer tmp_working_dir.close(io);

    // 5. Download .nupkg file
    const nupkg_file = try tmp_working_dir.createFile(io, "package.nupkg", .{ .read = true, .exclusive = true });
    defer nupkg_file.close(io);

    var nupkg_write_buf: [32 * 1024]u8 = undefined;
    var nupkg_writer = nupkg_file.writerStreaming(io, &nupkg_write_buf);

    const flat_base = ctx.environ.get("ORIEL_WEBVIEW2_NUPKG_URL") orelse default_flatcontainer_base;
    const nupkg_url = try std.fmt.allocPrint(arena, "{s}/{s}/microsoft.web.webview2.{s}.nupkg", .{ flat_base, version, version });

    const dl_res = client.fetch(.{
        .location = .{ .url = nupkg_url },
        .headers = .{ .user_agent = .{ .override = "oriel-cli" } },
        .response_writer = &nupkg_writer.interface,
    }) catch |err| {
        try ctx.err.print("error: failed to download NuGet package: {s}\n", .{@errorName(err)});
        return err;
    };
    if (dl_res.status != .ok) {
        try ctx.err.print("error: NuGet package download returned HTTP {d}\n", .{@intFromEnum(dl_res.status)});
        return error.BadHttpStatus;
    }
    try nupkg_writer.end();
    try nupkg_file.sync(io);

    // 6. Verify integrity (SHA-512 against catalog packageHash)
    const nupkg_size = try nupkg_file.length(io);
    if (nupkg_size > 50 * 1024 * 1024) return error.PayloadSizeExceeded;

    const nupkg_bytes = try tmp_working_dir.readFileAlloc(io, "package.nupkg", arena, .limited(50 * 1024 * 1024));
    verifyHash(nupkg_bytes, expected_hash) catch |err| {
        try ctx.err.print("error: WebView2 package integrity verification failed: {s}\n", .{@errorName(err)});
        return err;
    };

    // 7. Extract requested entries into temp directory
    try tmp_working_dir.createDirPath(io, "extracted");
    var extracted_dir = try tmp_working_dir.openDir(io, "extracted", .{});
    defer extracted_dir.close(io);

    _ = try extractLoadersFromZip(io, nupkg_file, want_x64, want_arm64, extracted_dir);

    // 8. Store extracted DLL(s) into cache and out_dir
    if (want_x64) {
        const dll_data = try extracted_dir.readFileAlloc(io, "runtimes/win-x64/native/WebView2Loader.dll", arena, .limited(10 * 1024 * 1024));
        const target_cache_dir = try getCacheDir(arena, ctx.environ, version, "x64");
        const cache_path = try atomicInstall(io, arena, target_cache_dir, "WebView2Loader.dll", dll_data);
        try ctx.out.print("WebView2Loader.dll (x64) {s}: {s}\n", .{ version, cache_path });

        if (out_dir) |od| {
            const out_x64_dir = if (arch == .all) try std.fs.path.join(arena, &.{ od, "x64" }) else od;
            const copied_x64 = try atomicInstall(io, arena, out_x64_dir, "WebView2Loader.dll", dll_data);
            try ctx.out.print("  copied to {s}\n", .{copied_x64});
            if (arch == .all) {
                const copied_root = try atomicInstall(io, arena, od, "WebView2Loader.dll", dll_data);
                try ctx.out.print("  copied to {s}\n", .{copied_root});
            }
        }
    }

    if (want_arm64) {
        const dll_data = try extracted_dir.readFileAlloc(io, "runtimes/win-arm64/native/WebView2Loader.dll", arena, .limited(10 * 1024 * 1024));
        const target_cache_dir = try getCacheDir(arena, ctx.environ, version, "arm64");
        const cache_path = try atomicInstall(io, arena, target_cache_dir, "WebView2Loader.dll", dll_data);
        try ctx.out.print("WebView2Loader.dll (arm64) {s}: {s}\n", .{ version, cache_path });

        if (out_dir) |od| {
            const out_arm64_dir = if (arch == .all) try std.fs.path.join(arena, &.{ od, "arm64" }) else od;
            const copied_arm64 = try atomicInstall(io, arena, out_arm64_dir, "WebView2Loader.dll", dll_data);
            try ctx.out.print("  copied to {s}\n", .{copied_arm64});
        }
    }
}

pub fn run(ctx: Context, cmd: Command) !u8 {
    fetch(ctx, cmd.arch, cmd.version, cmd.out) catch return 1;
    return 0;
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "Version parsing and comparison" {
    const v1 = Version.parse("1.0.4191.47").?;
    try std.testing.expectEqual(@as(usize, 4), v1.part_count);
    try std.testing.expectEqual(@as(u32, 1), v1.parts[0]);
    try std.testing.expectEqual(@as(u32, 0), v1.parts[1]);
    try std.testing.expectEqual(@as(u32, 4191), v1.parts[2]);
    try std.testing.expectEqual(@as(u32, 47), v1.parts[3]);
    try std.testing.expectEqual(null, v1.prerelease);

    const v2 = Version.parse("1.0.2903.40").?;
    try std.testing.expectEqual(std.math.Order.gt, Version.order(v1, v2));
    try std.testing.expectEqual(std.math.Order.lt, Version.order(v2, v1));
    try std.testing.expectEqual(std.math.Order.eq, Version.order(v1, v1));

    const v3 = Version.parse("1.0.4255-prerelease").?;
    try std.testing.expect(v3.prerelease != null);
    try std.testing.expectEqualStrings("prerelease", v3.prerelease.?);

    const v4 = Version.parse("1.0.4255").?;
    try std.testing.expectEqual(std.math.Order.gt, Version.order(v4, v3));
    try std.testing.expectEqual(std.math.Order.lt, Version.order(v3, v4));

    try std.testing.expect(Version.parse("invalid") == null);
    try std.testing.expect(Version.parse("") == null);
}

test "selectLatestStableVersion skips prereleases" {
    const json =
        \\{
        \\  "versions": [
        \\    "1.0.3415-prerelease",
        \\    "1.0.3485.44",
        \\    "1.0.3530-prerelease",
        \\    "1.0.4191.47",
        \\    "1.0.4255-prerelease"
        \\  ]
        \\}
    ;
    const selected = try selectLatestStableVersion(json, std.testing.allocator);
    defer std.testing.allocator.free(selected);
    try std.testing.expectEqualStrings("1.0.4191.47", selected);
}

test "Hash verification: good and bad SHA-512 base64" {
    const data = "hello world webview2 test payload";
    var digest: [64]u8 = undefined;
    std.crypto.hash.sha2.Sha512.hash(data, &digest, .{});

    var b64_buf: [std.base64.standard.Encoder.calcSize(64)]u8 = undefined;
    const good_b64 = std.base64.standard.Encoder.encode(&b64_buf, &digest);

    // Good hash passes
    try verifyHash(data, good_b64);

    // Bad hash fails
    try std.testing.expectError(error.PackageHashMismatch, verifyHash(data, "d3JvbmcgaGFzaA=="));
    try std.testing.expectError(error.PackageHashMismatch, verifyHash("different data", good_b64));
}

test "isBadPath rejects path traversal" {
    try std.testing.expect(isBadPath(""));
    try std.testing.expect(isBadPath("/absolute/path"));
    try std.testing.expect(isBadPath("\\windows\\path"));
    try std.testing.expect(isBadPath("../evil.dll"));
    try std.testing.expect(isBadPath("foo/../evil.dll"));
    try std.testing.expect(isBadPath("foo\\..\\evil.dll"));
    try std.testing.expect(isBadPath("C:\\autoexec.bat"));
    try std.testing.expect(isBadPath("foo\x00bar"));

    try std.testing.expect(!isBadPath("runtimes/win-x64/native/WebView2Loader.dll"));
    try std.testing.expect(!isBadPath("runtimes/win-arm64/native/WebView2Loader.dll"));
}

/// Helper to write an in-test zip with uncompressed entries.
pub fn createTestZip(io: std.Io, file: std.Io.File, entries: []const struct { name: []const u8, data: []const u8 }) !void {
    var offsets: [16]u32 = undefined;
    if (entries.len > offsets.len) return error.TooManyEntries;

    var cur_offset: u32 = 0;
    var w_buf: [1024]u8 = undefined;
    var w = file.writerStreaming(io, &w_buf);

    for (entries, 0..) |entry, idx| {
        offsets[idx] = cur_offset;
        const crc = std.hash.Crc32.hash(entry.data);

        try w.interface.writeAll(&std.zip.local_file_header_sig);
        try w.interface.writeInt(u16, 20, .little);
        try w.interface.writeInt(u16, 0, .little);
        try w.interface.writeInt(u16, 0, .little);
        try w.interface.writeInt(u16, 0, .little);
        try w.interface.writeInt(u16, 0, .little);
        try w.interface.writeInt(u32, crc, .little);
        try w.interface.writeInt(u32, @truncate(entry.data.len), .little);
        try w.interface.writeInt(u32, @truncate(entry.data.len), .little);
        try w.interface.writeInt(u16, @truncate(entry.name.len), .little);
        try w.interface.writeInt(u16, 0, .little);
        try w.interface.writeAll(entry.name);
        try w.interface.writeAll(entry.data);

        cur_offset += @sizeOf(std.zip.LocalFileHeader) + @as(u32, @truncate(entry.name.len)) + @as(u32, @truncate(entry.data.len));
    }

    const cd_start = cur_offset;
    for (entries, 0..) |entry, idx| {
        const crc = std.hash.Crc32.hash(entry.data);

        try w.interface.writeAll(&std.zip.central_file_header_sig);
        try w.interface.writeInt(u16, 20, .little);
        try w.interface.writeInt(u16, 20, .little);
        try w.interface.writeInt(u16, 0, .little);
        try w.interface.writeInt(u16, 0, .little);
        try w.interface.writeInt(u16, 0, .little);
        try w.interface.writeInt(u16, 0, .little);
        try w.interface.writeInt(u32, crc, .little);
        try w.interface.writeInt(u32, @truncate(entry.data.len), .little);
        try w.interface.writeInt(u32, @truncate(entry.data.len), .little);
        try w.interface.writeInt(u16, @truncate(entry.name.len), .little);
        try w.interface.writeInt(u16, 0, .little);
        try w.interface.writeInt(u16, 0, .little);
        try w.interface.writeInt(u16, 0, .little);
        try w.interface.writeInt(u16, 0, .little);
        try w.interface.writeInt(u32, 0, .little);
        try w.interface.writeInt(u32, offsets[idx], .little);
        try w.interface.writeAll(entry.name);

        cur_offset += @sizeOf(std.zip.CentralDirectoryFileHeader) + @as(u32, @truncate(entry.name.len));
    }

    const cd_size = cur_offset - cd_start;

    try w.interface.writeAll(&std.zip.end_record_sig);
    try w.interface.writeInt(u16, 0, .little);
    try w.interface.writeInt(u16, 0, .little);
    try w.interface.writeInt(u16, @truncate(entries.len), .little);
    try w.interface.writeInt(u16, @truncate(entries.len), .little);
    try w.interface.writeInt(u32, cd_size, .little);
    try w.interface.writeInt(u32, cd_start, .little);
    try w.interface.writeInt(u16, 0, .little);

    try w.end();
}

test "Zip extraction of right entries and traversal rejection" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const zip_file = try tmp.dir.createFile(io, "valid.zip", .{ .read = true });
    defer zip_file.close(io);

    const x64_content = "MZ x64 dll binary content";
    const arm64_content = "MZ arm64 dll binary content";
    const other_content = "unrelated file";

    try createTestZip(io, zip_file, &.{
        .{ .name = "runtimes/win-x64/native/WebView2Loader.dll", .data = x64_content },
        .{ .name = "runtimes/win-arm64/native/WebView2Loader.dll", .data = arm64_content },
        .{ .name = "unrelated/file.txt", .data = other_content },
    });

    try tmp.dir.createDirPath(io, "out");
    var out_dir = try tmp.dir.openDir(io, "out", .{});
    defer out_dir.close(io);

    const res = try extractLoadersFromZip(io, zip_file, true, true, out_dir);
    try std.testing.expect(res.x64);
    try std.testing.expect(res.arm64);

    const extracted_x64 = try out_dir.readFileAlloc(io, "runtimes/win-x64/native/WebView2Loader.dll", gpa, .limited(1024));
    defer gpa.free(extracted_x64);
    try std.testing.expectEqualStrings(x64_content, extracted_x64);

    const extracted_arm64 = try out_dir.readFileAlloc(io, "runtimes/win-arm64/native/WebView2Loader.dll", gpa, .limited(1024));
    defer gpa.free(extracted_arm64);
    try std.testing.expectEqualStrings(arm64_content, extracted_arm64);

    // Unrelated file was NOT extracted
    try std.testing.expectError(error.FileNotFound, out_dir.access(io, "unrelated/file.txt", .{}));

    // Test traversal rejection
    const bad_zip_file = try tmp.dir.createFile(io, "bad.zip", .{ .read = true });
    defer bad_zip_file.close(io);

    try createTestZip(io, bad_zip_file, &.{
        .{ .name = "../evil.dll", .data = "evil" },
    });

    try std.testing.expectError(error.ZipPathTraversal, extractLoadersFromZip(io, bad_zip_file, true, true, out_dir));
}
