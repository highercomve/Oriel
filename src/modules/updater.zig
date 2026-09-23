//! Self-updater: Ed25519-signed JSON manifest pointing to an update artifact
//! (raw executable/AppImage or gzip-compressed payload).
//! Includes:
//! - Manifest check over HTTP (std.http.Client) with Ed25519 signature verification
//! - Fixed 64 KiB buffer for manifest reading (error if exceeded)
//! - Download with progress streaming, payload size enforcement, SHA-256 verification, fsync, and atomic replacement
//! - Decompression decided strictly by signed format field (no content sniffing)
//! - Safe path resolution capturing APPIMAGE/APPDIR from main thread with boundary checking
//! - HTTP timeout deadlines via std.Io.Select racing against timeout
//! - State machine (idle, checking, installing, restarting) preventing concurrent operations
//! - In-place restart via process replacement (re-executing the resolved target path) with exact NUL-splitting
//! - Secure comptime-configured IPC Commands for JS integration with per-install throttled progress events

const std = @import("std");
const builtin = @import("builtin");
const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;
const oriel = @import("../oriel.zig");

// Pure-std manifest parsing and verification module
pub const update_manifest = @import("update_manifest.zig");
pub const Semver = update_manifest.Semver;
pub const Manifest = update_manifest.Manifest;
pub const verifyManifest = update_manifest.verify;
pub const verifyManifestWithOptions = update_manifest.verifyWithOptions;

pub const DEFAULT_TARGET = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag);
pub const DEFAULT_TIMEOUT_MS: u32 = 15_000;
/// Overall deadline for the artifact download (an AppImage can be 100+ MiB).
pub const DEFAULT_DOWNLOAD_TIMEOUT_MS: u32 = 10 * 60_000;
pub const MAX_CMDLINE_LEN = 16 * 1024;
pub const MAX_ARGV_COUNT = 256;

// ---------------------------------------------------------------------------
// Module Lifecycle & Environment Capture
// ---------------------------------------------------------------------------

var state_mutex: std.Io.Mutex = .init;
var current_state: State = .idle;
var verified_update: ?Update = null;
var verified_target_path: ?[]const u8 = null;
var captured_appimage: ?[]const u8 = null;
var captured_appdir: ?[]const u8 = null;
var module_allocator: ?std.mem.Allocator = null;
/// Test hook: download target used instead of the running executable (ignored outside tests).
var test_dest_override: ?[]const u8 = null;

pub const State = enum {
    idle,
    checking,
    installing,
    restarting,
};

/// Capture APPIMAGE and APPDIR on the main thread during app startup
/// (`oriel.main` calls this; worker threads never read the environment).
pub fn init(io: std.Io, allocator: std.mem.Allocator, env_map: ?*const std.process.Environ.Map) !void {
    state_mutex.lockUncancelable(io);
    defer state_mutex.unlock(io);

    module_allocator = allocator;

    if (captured_appimage) |prev| {
        allocator.free(prev);
        captured_appimage = null;
    }
    if (captured_appdir) |prev| {
        allocator.free(prev);
        captured_appdir = null;
    }

    if (env_map) |m| {
        if (m.get("APPIMAGE")) |ai| {
            if (ai.len > 0) {
                captured_appimage = try allocator.dupe(u8, ai);
            }
        }
        if (m.get("APPDIR")) |ad| {
            if (ad.len > 0) {
                captured_appdir = try allocator.dupe(u8, ad);
            }
        }
    }
}

pub fn deinit(io: std.Io) void {
    state_mutex.lockUncancelable(io);
    defer state_mutex.unlock(io);

    const alloc = module_allocator orelse std.heap.smp_allocator;

    if (captured_appimage) |ai| {
        alloc.free(ai);
        captured_appimage = null;
    }
    if (captured_appdir) |ad| {
        alloc.free(ad);
        captured_appdir = null;
    }
    if (verified_update) |*u| {
        u.deinit();
        verified_update = null;
    }
    if (verified_target_path) |tp| {
        alloc.free(tp);
        verified_target_path = null;
    }
    test_dest_override = null;
    current_state = .idle;
    module_allocator = null;
}

fn getAllocator(config_allocator: ?std.mem.Allocator) std.mem.Allocator {
    if (config_allocator) |a| return a;
    return module_allocator orelse std.heap.smp_allocator;
}

// ---------------------------------------------------------------------------
// Path Decision & Destination Resolution
// ---------------------------------------------------------------------------

/// Check if `path` is within `dir` on a path separator boundary.
pub fn isUnderDir(path: []const u8, dir: []const u8) bool {
    if (dir.len == 0 or path.len < dir.len) return false;
    if (!std.mem.startsWith(u8, path, dir)) return false;
    if (dir.len == path.len) return true;
    if (dir[dir.len - 1] == '/') return true;
    if (path[dir.len] == '/') return true;
    return false;
}

/// Pure decision function determining destination path.
/// Only uses `appimage` if `exe_path` resolves under `appdir` on a `/` boundary.
pub fn decideDestPath(
    dest_path: ?[]const u8,
    appimage: ?[]const u8,
    appdir: ?[]const u8,
    exe_path: []const u8,
) []const u8 {
    if (dest_path) |p| {
        if (p.len > 0) return p;
    }
    if (appimage) |ai| {
        if (ai.len > 0) {
            if (appdir) |ad| {
                if (ad.len > 0 and isUnderDir(exe_path, ad)) {
                    return ai;
                }
            }
        }
    }
    return exe_path;
}

/// True when this process runs from a mounted AppImage: `$APPIMAGE` is set
/// and `/proc/self/exe` resolves under `$APPDIR` (both captured by `init`).
pub fn runningAsAppImage(io: std.Io, gpa: std.mem.Allocator) !bool {
    state_mutex.lockUncancelable(io);
    const has_ai = captured_appimage != null;
    const ad = captured_appdir;
    state_mutex.unlock(io);
    const dir = ad orelse return false;
    if (!has_ai) return false;

    const exe_path = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(exe_path);
    return isUnderDir(exe_path, dir);
}

/// Determine the target binary path without calling getenv off the main thread.
pub fn resolveDestPath(io: std.Io, gpa: std.mem.Allocator, dest_path: ?[]const u8) ![]u8 {
    if (dest_path) |p| {
        if (!std.fs.path.isAbsolute(p)) return error.DestinationPathNotAbsolute;
        if (p.len > 0) return try gpa.dupe(u8, p);
    }
    state_mutex.lockUncancelable(io);
    const override = if (builtin.is_test) test_dest_override else null;
    const ai = captured_appimage;
    const ad = captured_appdir;
    state_mutex.unlock(io);

    if (override) |ov| {
        return try gpa.dupe(u8, ov);
    }

    const exe_path = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(exe_path);

    const chosen = decideDestPath(dest_path, ai, ad, exe_path);
    return try gpa.dupe(u8, chosen);
}

// ---------------------------------------------------------------------------
// Update Check & Download API
// ---------------------------------------------------------------------------

pub const Update = struct {
    app_id: []const u8,
    version: []const u8,
    target: []const u8,
    format: []const u8,
    size: u64,
    sha256: []const u8,
    url: []const u8,
    expires: ?u64 = null,
    signature: []const u8,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Update) void {
        self.arena.deinit();
    }
};

pub const Config = struct {
    app_id: []const u8,
    manifest_url: []const u8,
    current_version: []const u8,
    public_key_b64: []const u8,
    target: []const u8 = DEFAULT_TARGET,
    timeout_ms: u32 = DEFAULT_TIMEOUT_MS,
    download_timeout_ms: u32 = DEFAULT_DOWNLOAD_TIMEOUT_MS,
    allow_http_for_test: bool = false,
    allocator: ?std.mem.Allocator = null,
};

/// Fetch manifest from `config.manifest_url`, verify Ed25519 signature against `config.public_key_b64`,
/// enforce size limit (64 KiB), timeout deadline, and check compatibility with `config`.
pub fn checkForUpdate(
    io: std.Io,
    gpa: std.mem.Allocator,
    config: Config,
) !?Update {
    var manifest_buf: [64 * 1024]u8 = undefined;

    const FetchResult = struct {
        bytes: usize,
        status: std.http.Status,
    };

    const Fetcher = struct {
        fn fetchBody(
            i: std.Io,
            alloc: std.mem.Allocator,
            url: []const u8,
            buf: []u8,
        ) anyerror!FetchResult {
            var client: std.http.Client = .{ .allocator = alloc, .io = i };
            defer client.deinit();

            var fixed_writer = std.Io.Writer.fixed(buf);
            const fetch_res = client.fetch(.{
                .location = .{ .url = url },
                .headers = .{
                    .accept_encoding = .{ .override = "identity" },
                },
                .response_writer = &fixed_writer,
            }) catch |err| switch (err) {
                error.WriteFailed => return error.ManifestTooLarge,
                else => |e| return e,
            };

            return FetchResult{
                .bytes = fixed_writer.end,
                .status = fetch_res.status,
            };
        }

        fn sleepTimeout(i: std.Io, ms: u32) void {
            i.sleep(.fromMilliseconds(ms), .awake) catch {};
        }
    };

    // Run manifest fetch with timeout deadline via std.Io.Select
    const ResultUnion = union(enum) {
        fetched: anyerror!FetchResult,
        timeout: void,
    };
    var select_buf: [2]ResultUnion = undefined;
    var sel = std.Io.Select(ResultUnion).init(io, &select_buf);

    try sel.concurrent(.fetched, Fetcher.fetchBody, .{ io, gpa, config.manifest_url, &manifest_buf });
    try sel.concurrent(.timeout, Fetcher.sleepTimeout, .{ io, config.timeout_ms });

    const awaited = try sel.await();
    sel.cancelDiscard();

    const fetch_info = switch (awaited) {
        .fetched => |res| try res,
        .timeout => return error.Timeout,
    };

    if (fetch_info.status != .ok) return error.BadHttpStatus;
    const manifest_json = manifest_buf[0..fetch_info.bytes];

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    const manifest = try verifyManifestWithOptions(arena, manifest_json, config.public_key_b64, .{
        .allow_test_http = config.allow_http_for_test,
    });

    // Validate app_id and target match config
    if (!std.mem.eql(u8, manifest.app_id, config.app_id)) {
        return error.AppIdMismatch;
    }
    if (!std.mem.eql(u8, manifest.target, config.target)) {
        return error.TargetMismatch;
    }

    // Validate manifest expiration if specified
    if (manifest.expires) |exp| {
        const now_ts = std.Io.Timestamp.now(io, .real).toSeconds();
        if (now_ts > 0 and @as(u64, @intCast(now_ts)) > exp) {
            return error.ManifestExpired;
        }
    }

    const remote_ver = try Semver.parse(manifest.version);
    const local_ver = try Semver.parse(config.current_version);

    if (remote_ver.isNewerThan(local_ver)) {
        return Update{
            .app_id = manifest.app_id,
            .version = manifest.version,
            .target = manifest.target,
            .format = manifest.format,
            .size = manifest.size,
            .sha256 = manifest.sha256,
            .url = manifest.url,
            .expires = manifest.expires,
            .signature = manifest.signature,
            .arena = arena_state,
        };
    }

    arena_state.deinit();
    return null;
}

pub const ProgressCallback = struct {
    context: ?*anyopaque = null,
    callback: *const fn (context: ?*anyopaque, downloaded: u64, total: ?u64) void,

    pub fn call(self: ProgressCallback, downloaded: u64, total: ?u64) void {
        self.callback(self.context, downloaded, total);
    }
};

/// Download an update artifact to a temporary file next to the destination,
/// stream and compute SHA-256 on the fly, enforce size bounds, verify the hash,
/// fsync to disk, and atomically rename over destination.
pub fn download(
    io: std.Io,
    gpa: std.mem.Allocator,
    update: Update,
    dest_path: ?[]const u8,
    progress_callback: ?ProgressCallback,
) ![]u8 {
    return downloadWithOptions(io, gpa, update, dest_path, progress_callback, DEFAULT_DOWNLOAD_TIMEOUT_MS);
}

pub fn downloadWithOptions(
    io: std.Io,
    gpa: std.mem.Allocator,
    update: Update,
    dest_path: ?[]const u8,
    progress_callback: ?ProgressCallback,
    timeout_ms: u32,
) ![]u8 {
    const Runner = struct {
        fn run(
            i: std.Io,
            alloc: std.mem.Allocator,
            u: Update,
            dp: ?[]const u8,
            pc: ?ProgressCallback,
        ) ![]u8 {
            return downloadInternal(i, alloc, u, dp, pc);
        }

        fn sleepTimeout(i: std.Io, ms: u32) void {
            i.sleep(.fromMilliseconds(ms), .awake) catch {};
        }
    };

    const ResultUnion = union(enum) {
        downloaded: anyerror![]u8,
        timeout: void,
    };
    var select_buf: [2]ResultUnion = undefined;
    var sel = std.Io.Select(ResultUnion).init(io, &select_buf);

    try sel.concurrent(.downloaded, Runner.run, .{ io, gpa, update, dest_path, progress_callback });
    try sel.concurrent(.timeout, Runner.sleepTimeout, .{ io, timeout_ms });

    const awaited = try sel.await();
    sel.cancelDiscard();

    switch (awaited) {
        .downloaded => |res| return res,
        .timeout => return error.Timeout,
    }
}

fn downloadInternal(
    io: std.Io,
    gpa: std.mem.Allocator,
    update: Update,
    dest_path: ?[]const u8,
    progress_callback: ?ProgressCallback,
) ![]u8 {
    const target_path = try resolveDestPath(io, gpa, dest_path);
    defer gpa.free(target_path);

    if (!std.fs.path.isAbsolute(target_path)) {
        return error.DestinationPathNotAbsolute;
    }

    const cwd = std.Io.Dir.cwd();

    // Resolve destination symlinks first so we replace the real target
    const real_dest_path: [:0]u8 = if (cwd.realPathFileAlloc(io, target_path, gpa)) |rd|
        rd
    else |_|
        try gpa.dupeZ(u8, target_path);
    defer gpa.free(real_dest_path);

    const parent_dir_path = std.fs.path.dirname(real_dest_path) orelse "/";
    const target_file_name = std.fs.path.basename(real_dest_path);

    // `.iterate` opens a real (non-O_PATH) descriptor, which fsync needs below.
    var parent_dir = try cwd.openDir(io, parent_dir_path, .{ .iterate = true });
    defer parent_dir.close(io);

    // Connect and fetch update artifact over HTTP
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(update.url);
    var req = try client.request(.GET, uri, .{
        .headers = .{
            .accept_encoding = .{ .override = "identity" },
        },
        .redirect_behavior = std.http.Client.Request.RedirectBehavior.init(3),
    });
    defer req.deinit();
    try req.sendBodiless();

    var redirect_buf: [8192]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);
    if (response.head.status != .ok) return error.BadHttpStatus;

    const content_length = response.head.content_length;
    var downloaded_bytes: u64 = 0;

    // Create temporary download file inside parent dir with exclusive create
    var rand_val: u64 = undefined;
    io.random(std.mem.asBytes(&rand_val));
    const temp_dl_name = try std.fmt.allocPrint(gpa, "{s}.tmp_dl.{d}.{x}", .{ target_file_name, std.os.linux.getpid(), rand_val });
    defer gpa.free(temp_dl_name);

    const temp_file = try parent_dir.createFile(io, temp_dl_name, .{
        .permissions = std.Io.File.Permissions.fromMode(0o755),
        .exclusive = true,
    });
    // Explicit mode, independent of the umask.
    try temp_file.setPermissions(io, .fromMode(0o755));

    var temp_open: bool = true;
    var temp_exists: bool = true;
    defer {
        if (temp_open) temp_file.close(io);
        if (temp_exists) parent_dir.deleteFile(io, temp_dl_name) catch {};
    }

    var file_writer_buf: [32768]u8 = undefined;
    var temp_writer = temp_file.writerStreaming(io, &file_writer_buf);

    var transfer_buf: [65536]u8 = undefined;
    const reader = response.reader(&transfer_buf);

    var sha = Sha256.init(.{});
    var chunk_buf: [32768]u8 = undefined;

    while (true) {
        const n = try reader.readSliceShort(&chunk_buf);
        if (n == 0) break;
        const chunk = chunk_buf[0..n];
        sha.update(chunk);
        try temp_writer.interface.writeAll(chunk);
        downloaded_bytes += n;

        if (downloaded_bytes > update.size) {
            return error.PayloadSizeExceeded;
        }
        if (content_length) |cl| {
            if (downloaded_bytes > cl) {
                return error.PayloadSizeExceeded;
            }
        }

        if (progress_callback) |cb| cb.call(downloaded_bytes, update.size);
    }

    if (downloaded_bytes != update.size) {
        return error.PayloadSizeMismatch;
    }

    try temp_writer.interface.flush();
    try temp_file.sync(io);

    // Verify SHA-256 of downloaded payload
    var digest: [32]u8 = undefined;
    sha.final(&digest);
    const computed_hex = std.fmt.bytesToHex(digest, .lower);
    if (!update_manifest.eqlSha256Hex(&computed_hex, update.sha256)) {
        return error.PayloadHashMismatch;
    }

    // Close download file
    temp_file.close(io);
    temp_open = false;

    // Decompression decided strictly by signed format field
    const is_gzip = update_manifest.isGzipFormat(update.format);
    if (is_gzip) {
        const temp_decomp_name = try std.fmt.allocPrint(gpa, "{s}.tmp_decomp.{d}.{x}", .{ target_file_name, std.os.linux.getpid(), rand_val });
        defer gpa.free(temp_decomp_name);

        const gz_file = try parent_dir.openFile(io, temp_dl_name, .{});
        defer gz_file.close(io);

        const decomp_file = try parent_dir.createFile(io, temp_decomp_name, .{
            .permissions = std.Io.File.Permissions.fromMode(0o755),
            .exclusive = true,
        });
        try decomp_file.setPermissions(io, .fromMode(0o755));

        var decomp_open: bool = true;
        var decomp_exists: bool = true;
        defer {
            if (decomp_open) decomp_file.close(io);
            if (decomp_exists) parent_dir.deleteFile(io, temp_decomp_name) catch {};
        }

        var gz_read_buf: [65536]u8 = undefined;
        var gz_reader = gz_file.readerStreaming(io, &gz_read_buf);

        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var decompress = std.compress.flate.Decompress.init(&gz_reader.interface, .gzip, &window);

        var out_buf: [32768]u8 = undefined;
        var out_writer_buf: [32768]u8 = undefined;
        var out_writer = decomp_file.writerStreaming(io, &out_writer_buf);

        while (true) {
            const n = try decompress.reader.readSliceShort(&out_buf);
            if (n == 0) break;
            try out_writer.interface.writeAll(out_buf[0..n]);
        }
        try out_writer.interface.flush();
        try decomp_file.sync(io);

        decomp_file.close(io);
        decomp_open = false;

        // Clean up compressed download file
        parent_dir.deleteFile(io, temp_dl_name) catch {};
        temp_exists = false;

        // Atomically rename decompressed binary over target
        try parent_dir.rename(temp_decomp_name, parent_dir, target_file_name, io);
        decomp_exists = false;
    } else {
        // Atomically rename download file over target
        try parent_dir.rename(temp_dl_name, parent_dir, target_file_name, io);
        temp_exists = false;
    }

    // Fsync the parent directory so the rename itself is durable.
    switch (std.posix.errno(std.posix.system.fsync(parent_dir.handle))) {
        .SUCCESS => {},
        else => return error.DirSyncFailed,
    }

    return try gpa.dupe(u8, real_dest_path);
}

// ---------------------------------------------------------------------------
// Process Restart & Cmdline Splitting
// ---------------------------------------------------------------------------

/// Pure function to split /proc/self/cmdline on exact NUL delimiters,
/// replacing argv[0] with exe_path, keeping empty arguments, and enforcing bounds.
pub fn splitCmdline(
    cmdline_bytes: []const u8,
    exe_path: []const u8,
    out_argv: [][]const u8,
) ![]const []const u8 {
    if (cmdline_bytes.len == 0) return error.CannotReadCmdline;
    if (cmdline_bytes.len > MAX_CMDLINE_LEN) return error.CmdlineTooLarge;

    // Trailing NUL terminates the last argument
    const data = if (cmdline_bytes[cmdline_bytes.len - 1] == 0)
        cmdline_bytes[0 .. cmdline_bytes.len - 1]
    else
        cmdline_bytes;

    var it = std.mem.splitScalar(u8, data, 0);
    const first = it.next() orelse return error.CannotReadCmdline;
    _ = first; // Replaced by exe_path

    const out_slice = out_argv;
    if (out_slice.len == 0) return error.TooManyArguments;
    out_slice[0] = exe_path;
    var argc: usize = 1;

    while (it.next()) |arg| {
        if (argc >= out_slice.len) return error.TooManyArguments;
        out_slice[argc] = arg;
        argc += 1;
    }

    return out_slice[0..argc];
}

/// Test hook replacing the exec in `restart` (ignored outside tests).
var mock_exec_fn: ?*const fn (io: std.Io, exe_path: []const u8) anyerror!noreturn = null;

/// Re-exec the updated binary using std.process.replace with original arguments.
pub fn restart(io: std.Io, exe_path: []const u8) !noreturn {
    if (builtin.is_test) {
        if (mock_exec_fn) |f| return f(io, exe_path);
    }

    const cwd = std.Io.Dir.cwd();
    const cmdline_file = cwd.openFile(io, "/proc/self/cmdline", .{}) catch return error.CannotReadCmdline;
    defer cmdline_file.close(io);

    // Read up to MAX_CMDLINE_LEN + 1 bytes to detect truncation
    var cmdline_buf: [MAX_CMDLINE_LEN + 1]u8 = undefined;
    var reader_buf: [2048]u8 = undefined;
    var stream_reader = cmdline_file.readerStreaming(io, &reader_buf);
    const bytes_read = stream_reader.interface.readSliceShort(&cmdline_buf) catch return error.CannotReadCmdline;
    if (bytes_read == 0) return error.CannotReadCmdline;
    if (bytes_read > MAX_CMDLINE_LEN) return error.CmdlineTooLarge;

    var argv_storage: [MAX_ARGV_COUNT][]const u8 = undefined;
    const argv = try splitCmdline(cmdline_buf[0..bytes_read], exe_path, &argv_storage);

    return std.process.replace(io, .{ .argv = argv });
}

/// Helper progress callback that emits an `updater://progress` event to JS via `oriel.App.emit`.
pub fn emitProgress(downloaded: u64, total: ?u64) void {
    oriel.App.emit("updater://progress", .{ .downloaded = downloaded, .total = total });
}

/// Unpack gzip payload and verify sha256 (backward compatibility).
pub fn unpack(gpa: std.mem.Allocator, manifest: Manifest, payload_gz: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    Sha256.hash(payload_gz, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!update_manifest.eqlSha256Hex(&hex, manifest.sha256)) return error.PayloadHashMismatch;

    var in: std.Io.Reader = .fixed(payload_gz);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&in, .gzip, &window);
    return decompress.reader.allocRemaining(gpa, .unlimited);
}

// ---------------------------------------------------------------------------
// Comptime-Configured Commands for JS IPC
// ---------------------------------------------------------------------------

/// Generate secure IPC Commands bound to `config`.
pub fn Commands(comptime config: Config) type {
    comptime {
        if (config.allow_http_for_test) {
            if (!@import("builtin").is_test) {
                @compileError("allow_http_for_test is only permitted in test builds");
            }
            if (!std.mem.startsWith(u8, config.manifest_url, "https://") and
                !std.mem.startsWith(u8, config.manifest_url, "http://127.0.0.1:") and
                !std.mem.startsWith(u8, config.manifest_url, "http://localhost:") and
                !std.mem.startsWith(u8, config.manifest_url, "http://127.0.0.1/") and
                !std.mem.startsWith(u8, config.manifest_url, "http://localhost/"))
            {
                @compileError("manifest_url must start with https:// (or http://127.0.0.1 / http://localhost in test mode)");
            }
        } else {
            if (!std.mem.startsWith(u8, config.manifest_url, "https://")) {
                @compileError("manifest_url must start with https://");
            }
        }

        _ = update_manifest.parsePublicKey(config.public_key_b64) catch |err| {
            @compileError("invalid public_key_b64 in updater Config: " ++ @errorName(err));
        };

        if (config.app_id.len == 0) {
            @compileError("config.app_id must not be empty");
        }
    }

    return struct {
        pub const async_commands = .{ "updater_check", "updater_install", "updater_restart" };

        pub const CheckResult = struct {
            available: bool,
            version: ?[]const u8 = null,
        };

        /// Check for update: verifies the manifest and saves the verified Update
        /// in module state. Returns { available: bool, version: ?string }.
        pub fn updater_check(arena: std.mem.Allocator, io: std.Io) !CheckResult {
            const alloc = getAllocator(config.allocator);

            state_mutex.lockUncancelable(io);
            if (current_state != .idle) {
                state_mutex.unlock(io);
                return error.UpdaterBusy;
            }
            current_state = .checking;
            state_mutex.unlock(io);

            errdefer {
                state_mutex.lockUncancelable(io);
                current_state = .idle;
                state_mutex.unlock(io);
            }

            const maybe_update = try checkForUpdate(io, alloc, config);

            state_mutex.lockUncancelable(io);
            defer state_mutex.unlock(io);
            current_state = .idle;

            if (verified_update) |*u| {
                u.deinit();
                verified_update = null;
            }

            if (maybe_update) |up| {
                verified_update = up;
                return .{
                    .available = true,
                    .version = try arena.dupe(u8, up.version),
                };
            } else {
                return .{
                    .available = false,
                    .version = null,
                };
            }
        }

        /// Download the verified update stored by `updater_check` to the
        /// resolved target (`$APPIMAGE` or the running executable), emitting
        /// throttled `updater://progress` events ({ downloaded, total }).
        pub fn updater_install(_: std.mem.Allocator, io: std.Io) !bool {
            const alloc = getAllocator(config.allocator);

            state_mutex.lockUncancelable(io);
            if (current_state != .idle) {
                state_mutex.unlock(io);
                return error.UpdaterBusy;
            }
            var update = verified_update orelse {
                state_mutex.unlock(io);
                return error.NoUpdatePending;
            };
            verified_update = null;
            current_state = .installing;
            state_mutex.unlock(io);

            defer update.deinit();

            errdefer {
                state_mutex.lockUncancelable(io);
                current_state = .idle;
                state_mutex.unlock(io);
            }

            // The signed format must match how this copy is installed: an
            // AppImage is only replaced by an AppImage, a raw binary by a raw one.
            const as_appimage = try runningAsAppImage(io, alloc);
            if (update_manifest.isAppImageFormat(update.format) != as_appimage) return error.FormatMismatch;

            const Throttler = struct {
                clock_io: std.Io,
                last_emit_ms: i64 = 0,
                last_downloaded: u64 = 0,
                last_total: ?u64 = null,

                fn onProgress(ctx: ?*anyopaque, downloaded: u64, total: ?u64) void {
                    const self: *@This() = @ptrCast(@alignCast(ctx.?));
                    self.last_downloaded = downloaded;
                    self.last_total = total;
                    const now = std.Io.Timestamp.now(self.clock_io, .awake).toMilliseconds();
                    if (now - self.last_emit_ms >= 100) {
                        self.last_emit_ms = now;
                        emitProgress(downloaded, total);
                    }
                }
            };

            var throttler = Throttler{
                .clock_io = io,
            };

            const cb = ProgressCallback{
                .context = &throttler,
                .callback = &Throttler.onProgress,
            };

            const target_path = try downloadWithOptions(io, alloc, update, null, cb, config.download_timeout_ms);
            emitProgress(throttler.last_downloaded, throttler.last_total);

            state_mutex.lockUncancelable(io);
            defer state_mutex.unlock(io);

            if (verified_target_path) |prev| alloc.free(prev);
            verified_target_path = target_path;
            current_state = .idle;

            return true;
        }

        /// Restart the application using the downloaded updated binary.
        pub fn updater_restart(arena: std.mem.Allocator, io: std.Io) !void {
            const alloc = getAllocator(config.allocator);

            state_mutex.lockUncancelable(io);
            if (current_state != .idle) {
                state_mutex.unlock(io);
                return error.UpdaterBusy;
            }
            current_state = .restarting;

            // Dupe target path under lock to eliminate use-after-free race
            const maybe_target_copy = if (verified_target_path) |tp|
                alloc.dupe(u8, tp) catch |err| {
                    current_state = .idle;
                    state_mutex.unlock(io);
                    return err;
                }
            else
                null;
            state_mutex.unlock(io);

            errdefer {
                state_mutex.lockUncancelable(io);
                current_state = .idle;
                state_mutex.unlock(io);
            }

            const final_path = if (maybe_target_copy) |tp|
                tp
            else
                try resolveDestPath(io, alloc, null);
            defer alloc.free(final_path);

            _ = arena;
            try restart(io, final_path);
        }
    };
}

// ---------------------------------------------------------------------------
// Module Smoke Check
// ---------------------------------------------------------------------------

const test_payload_gz = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xff, 0xcb, 0x2f, 0xca, 0x4c, 0xcd, 0x51,
    0x28, 0x2d, 0x48, 0x49, 0x2c, 0x49, 0x55, 0x28, 0x48, 0xac, 0xcc, 0xc9, 0x4f, 0x4c, 0x51, 0x28,
    0x33, 0xd0, 0x33, 0xd0, 0x33, 0xe4, 0xca, 0x1f, 0x06, 0x72, 0x00, 0x2d, 0x20, 0xe4, 0xcb, 0xe0,
    0x00, 0x00, 0x00,
};

pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    const key_pair = try Ed25519.KeyPair.generateDeterministic([_]u8{42} ** Ed25519.KeyPair.seed_length);
    var pk_b64: [update_manifest.PUBLIC_KEY_B64_LEN]u8 = undefined;
    _ = update_manifest.encodePublicKey(key_pair.public_key.toBytes(), &pk_b64);

    var digest: [32]u8 = undefined;
    Sha256.hash(&test_payload_gz, &digest, .{});
    const sha256_hex = std.fmt.bytesToHex(digest, .lower);

    const sign_params = update_manifest.SignParameters{
        .app_id = "dev.oriel.smoke",
        .version = "0.0.1",
        .target = DEFAULT_TARGET,
        .format = "raw.gz",
        .size = test_payload_gz.len,
        .sha256 = &sha256_hex,
        .url = "https://example.invalid/app.gz",
    };

    const sig_b64 = try update_manifest.sign(gpa, key_pair, sign_params);
    defer gpa.free(sig_b64);

    const manifest_json = try update_manifest.formatManifest(gpa, sign_params, sig_b64);
    defer gpa.free(manifest_json);

    // App side: verify, check the hash, unpack
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const manifest = try verifyManifest(arena_state.allocator(), manifest_json, &pk_b64);
    const payload = try unpack(gpa, manifest, &test_payload_gz);
    defer gpa.free(payload);

    // A tampered manifest must be rejected
    const tampered = try gpa.dupe(u8, manifest_json);
    defer gpa.free(tampered);
    if (std.mem.indexOf(u8, tampered, "0.0.1")) |idx| {
        tampered[idx] = '9';
    }
    const rejected = if (verifyManifest(arena_state.allocator(), tampered, &pk_b64)) |_| false else |_| true;

    return .{
        .module = "updater",
        .ok = rejected and std.mem.startsWith(u8, payload, "oriel update payload"),
        .detail = try std.fmt.allocPrint(gpa, "manifest v{s} Ed25519-verified, tampered copy {s}; payload {d} B gz -> {d} B", .{
            manifest.version,
            if (rejected) "rejected" else "ACCEPTED (bug)",
            test_payload_gz.len,
            payload.len,
        }),
    };
}

// ---------------------------------------------------------------------------
// Unit & End-to-End Tests
// ---------------------------------------------------------------------------

test "pure decideDestPath logic" {
    // 1. Explicit dest_path always wins
    const custom = decideDestPath("/opt/app/my_bin", "/tmp/app.AppImage", "/tmp/mount", "/tmp/mount/usr/bin/app");
    try std.testing.expectEqualStrings("/opt/app/my_bin", custom);

    // 2. AppImage matches when exe_path is under appdir
    const ai1 = decideDestPath(null, "/home/user/app.AppImage", "/tmp/.mount_123", "/tmp/.mount_123/usr/bin/app");
    try std.testing.expectEqualStrings("/home/user/app.AppImage", ai1);

    // Boundary with trailing slash in appdir
    const ai2 = decideDestPath(null, "/home/user/app.AppImage", "/tmp/.mount_123/", "/tmp/.mount_123/usr/bin/app");
    try std.testing.expectEqualStrings("/home/user/app.AppImage", ai2);

    // Exe exactly matches appdir
    const ai3 = decideDestPath(null, "/home/user/app.AppImage", "/tmp/mount", "/tmp/mount");
    try std.testing.expectEqualStrings("/home/user/app.AppImage", ai3);

    // 3. Prefix matches string but NOT slash boundary: rejected!
    const outside1 = decideDestPath(null, "/home/user/app.AppImage", "/tmp/mount", "/tmp/mountain/app");
    try std.testing.expectEqualStrings("/tmp/mountain/app", outside1);

    // 4. Exe completely outside appdir
    const outside2 = decideDestPath(null, "/home/user/app.AppImage", "/tmp/.mount_123", "/usr/bin/malicious");
    try std.testing.expectEqualStrings("/usr/bin/malicious", outside2);

    // 5. AppImage or AppDir missing/empty
    const no_ai = decideDestPath(null, null, "/tmp/mount", "/usr/bin/app");
    try std.testing.expectEqualStrings("/usr/bin/app", no_ai);

    const no_dir = decideDestPath(null, "/home/user/app.AppImage", null, "/usr/bin/app");
    try std.testing.expectEqualStrings("/usr/bin/app", no_dir);
}

test "pure splitCmdline logic" {
    var storage: [16][]const u8 = undefined;

    // Normal command line with trailing NUL
    const res1 = try splitCmdline("old_exe\x00arg1\x00arg2\x00", "/new/target", &storage);
    try std.testing.expectEqual(@as(usize, 3), res1.len);
    try std.testing.expectEqualStrings("/new/target", res1[0]);
    try std.testing.expectEqualStrings("arg1", res1[1]);
    try std.testing.expectEqualStrings("arg2", res1[2]);

    // Keeps empty arguments
    const res2 = try splitCmdline("old_exe\x00\x00arg2\x00", "/new/target", &storage);
    try std.testing.expectEqual(@as(usize, 3), res2.len);
    try std.testing.expectEqualStrings("/new/target", res2[0]);
    try std.testing.expectEqualStrings("", res2[1]);
    try std.testing.expectEqualStrings("arg2", res2[2]);

    // Empty argument at end
    const res3 = try splitCmdline("old_exe\x00arg1\x00\x00", "/new/target", &storage);
    try std.testing.expectEqual(@as(usize, 3), res3.len);
    try std.testing.expectEqualStrings("/new/target", res3[0]);
    try std.testing.expectEqualStrings("arg1", res3[1]);
    try std.testing.expectEqualStrings("", res3[2]);

    // Empty cmdline returns error
    try std.testing.expectError(error.CannotReadCmdline, splitCmdline("", "/new/target", &storage));

    // Exceeding storage limit returns error
    var small_storage: [2][]const u8 = undefined;
    try std.testing.expectError(error.TooManyArguments, splitCmdline("a\x00b\x00c\x00", "/new/target", &small_storage));
}

test "app merges updater Commands pattern" {
    const TestCommands = struct {
        const Updater = Commands(.{
            .app_id = "dev.oriel.demo",
            .manifest_url = "https://example.com/manifest.json",
            .current_version = "1.0.0",
            .public_key_b64 = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        });

        pub fn ping(_: std.mem.Allocator) []const u8 {
            return "pong";
        }

        pub const updater_check = Updater.updater_check;
        pub const updater_install = Updater.updater_install;
        pub const updater_restart = Updater.updater_restart;

        pub const async_commands = .{ "updater_check", "updater_install", "updater_restart" };
    };

    try std.testing.expect(oriel.ipc.isAsync(TestCommands, "updater_check"));
    try std.testing.expect(oriel.ipc.isAsync(TestCommands, "updater_install"));
    try std.testing.expect(oriel.ipc.isAsync(TestCommands, "updater_restart"));
    try std.testing.expect(!oriel.ipc.isAsync(TestCommands, "ping"));

    std.testing.refAllDecls(TestCommands.Updater);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const reply = try oriel.ipc.dispatch(TestCommands, arena_state.allocator(), "{\"cmd\":\"ping\",\"args\":{}}", std.testing.io);
    try std.testing.expectEqualStrings("\"pong\"", reply);
    const ts = comptime oriel.ipc.typescript(TestCommands, struct {});
    try std.testing.expect(std.mem.indexOf(u8, ts, "updater_install") != null);
}

/// Local mock HTTP server for end-to-end update test
const MockServer = struct {
    server: std.Io.net.Server,
    thread: std.Thread,
    port: u16,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    manifest_json: []const u8,
    payload: []const u8,
    gzip_payload: ?[]const u8 = null,
    running: std.atomic.Value(bool) = .init(true),

    fn start(io: std.Io, port: u16, manifest_json: []const u8, payload: []const u8, gzip_payload: ?[]const u8) !*MockServer {
        const allocator = std.testing.allocator;
        const self = try allocator.create(MockServer);
        errdefer allocator.destroy(self);

        const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
        self.server = try addr.listen(io, .{ .reuse_address = true });
        errdefer self.server.deinit(io);
        self.port = self.server.socket.address.ip4.port;
        self.io = io;
        self.manifest_json = manifest_json;
        self.payload = payload;
        self.gzip_payload = gzip_payload;
        self.mutex = .init;
        self.running = .init(true);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    fn setManifest(self: *MockServer, io: std.Io, json: []const u8) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.manifest_json = json;
    }

    fn run(self: *MockServer) void {
        while (self.running.load(.acquire)) {
            var stream = self.server.accept(self.io) catch break;
            defer stream.close(self.io);

            if (!self.running.load(.acquire)) break;

            // Set receive timeout so socket read never hangs
            const tv = std.posix.timeval{ .sec = 2, .usec = 0 };
            _ = std.posix.system.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, &tv, @sizeOf(@TypeOf(tv)));

            var read_buf: [2048]u8 = undefined;
            var reader = stream.reader(self.io, &read_buf);

            var req_buf: [2048]u8 = undefined;
            var req_len: usize = 0;
            while (req_len < req_buf.len) {
                var single_byte: [1]u8 = undefined;
                const n = reader.interface.readSliceShort(&single_byte) catch break;
                if (n == 0) break;
                req_buf[req_len] = single_byte[0];
                req_len += 1;
                if (req_len >= 4 and std.mem.eql(u8, req_buf[req_len - 4 .. req_len], "\r\n\r\n")) {
                    break;
                }
            }
            if (req_len == 0) continue;
            const req = req_buf[0..req_len];

            if (std.mem.indexOf(u8, req, "GET /manifest.json") != null) {
                self.mutex.lockUncancelable(self.io);
                const cur_manifest = self.manifest_json;
                self.mutex.unlock(self.io);

                var w_buf: [4096]u8 = undefined;
                var writer = stream.writer(self.io, &w_buf);
                writer.interface.print("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{s}", .{ cur_manifest.len, cur_manifest }) catch {};
                writer.interface.flush() catch {};
            } else if (std.mem.indexOf(u8, req, "GET /payload.gz") != null) {
                if (self.gzip_payload) |gz_data| {
                    var w_buf: [4096]u8 = undefined;
                    var writer = stream.writer(self.io, &w_buf);
                    writer.interface.print("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nContent-Type: application/gzip\r\nConnection: close\r\n\r\n{s}", .{ gz_data.len, gz_data }) catch {};
                    writer.interface.flush() catch {};
                }
            } else if (std.mem.indexOf(u8, req, "GET /payload") != null) {
                var w_buf: [4096]u8 = undefined;
                var writer = stream.writer(self.io, &w_buf);
                writer.interface.print("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n{s}", .{ self.payload.len, self.payload }) catch {};
                writer.interface.flush() catch {};
            } else if (std.mem.indexOf(u8, req, "GET /quit") != null) {
                break;
            }
        }
    }

    fn stop(self: *MockServer) void {
        self.running.store(false, .release);
        _ = std.posix.system.shutdown(self.server.socket.handle, std.posix.SHUT.RDWR);
        const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(self.port) };
        if (addr.connect(self.io, .{ .mode = .stream })) |stream| {
            var w_buf: [64]u8 = undefined;
            var writer = stream.writer(self.io, &w_buf);
            _ = writer.interface.writeAll("GET /quit HTTP/1.1\r\n\r\n") catch {};
            _ = writer.interface.flush() catch {};
            stream.close(self.io);
        } else |_| {}
        self.thread.join();
        self.server.deinit(self.io);
        std.testing.allocator.destroy(self);
    }
};

test "end-to-end update flow" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    try init(io, allocator, null);
    defer deinit(io);

    // Generate test Ed25519 keypair
    const kp = try Ed25519.KeyPair.generateDeterministic([_]u8{77} ** 32);
    var pk_b64: [update_manifest.PUBLIC_KEY_B64_LEN]u8 = undefined;
    _ = update_manifest.encodePublicKey(kp.public_key.toBytes(), &pk_b64);

    const wrong_kp = try Ed25519.KeyPair.generateDeterministic([_]u8{88} ** 32);
    var wrong_pk_b64: [update_manifest.PUBLIC_KEY_B64_LEN]u8 = undefined;
    _ = update_manifest.encodePublicKey(wrong_kp.public_key.toBytes(), &wrong_pk_b64);

    // Raw payload content
    const new_payload = "oriel updated executable binary content v2.0.0!";
    var digest: [32]u8 = undefined;
    Sha256.hash(new_payload, &digest, .{});
    const payload_sha256 = std.fmt.bytesToHex(digest, .lower);

    // Gzip payload content
    var gz_digest: [32]u8 = undefined;
    Sha256.hash(&test_payload_gz, &gz_digest, .{});
    const gz_payload_sha256 = std.fmt.bytesToHex(gz_digest, .lower);

    // Start mock server first to obtain ephemeral port
    var server = try MockServer.start(io, 0, "", new_payload, &test_payload_gz);
    defer server.stop();

    const payload_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/payload", .{server.port});
    defer allocator.free(payload_url);

    const sign_params = update_manifest.SignParameters{
        .app_id = "dev.oriel.test",
        .version = "2.0.0",
        .target = DEFAULT_TARGET,
        .format = "raw",
        .size = new_payload.len,
        .sha256 = &payload_sha256,
        .url = payload_url,
        .allow_test_http = true,
    };

    const sig_b64 = try update_manifest.sign(allocator, kp, sign_params);
    defer allocator.free(sig_b64);

    const manifest_json = try update_manifest.formatManifest(allocator, sign_params, sig_b64);
    defer allocator.free(manifest_json);
    server.setManifest(io, manifest_json);

    const manifest_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/manifest.json", .{server.port});
    defer allocator.free(manifest_url);

    const base_cfg = Config{
        .app_id = "dev.oriel.test",
        .manifest_url = manifest_url,
        .current_version = "2.0.0",
        .public_key_b64 = &pk_b64,
        .target = DEFAULT_TARGET,
        .allow_http_for_test = true,
    };

    // 1. Version checks:
    // Same version returns null
    const no_update_same = try checkForUpdate(io, allocator, base_cfg);
    try std.testing.expect(no_update_same == null);

    // Older remote version returns null
    var older_cfg = base_cfg;
    older_cfg.current_version = "3.0.0";
    const no_update_older = try checkForUpdate(io, allocator, older_cfg);
    try std.testing.expect(no_update_older == null);

    // Manifest signed with another key is rejected
    var wrong_key_cfg = base_cfg;
    wrong_key_cfg.current_version = "1.0.0";
    wrong_key_cfg.public_key_b64 = &wrong_pk_b64;
    try std.testing.expectError(error.SignatureVerificationFailed, checkForUpdate(io, allocator, wrong_key_cfg));

    // Mismatched app_id rejected
    var wrong_app_cfg = base_cfg;
    wrong_app_cfg.current_version = "1.0.0";
    wrong_app_cfg.app_id = "other.app";
    try std.testing.expectError(error.AppIdMismatch, checkForUpdate(io, allocator, wrong_app_cfg));

    // Valid check: 1.0.0 -> 2.0.0 available
    var valid_cfg = base_cfg;
    valid_cfg.current_version = "1.0.0";
    const update_opt = try checkForUpdate(io, allocator, valid_cfg);
    try std.testing.expect(update_opt != null);
    var update = update_opt.?;
    defer update.deinit();

    try std.testing.expectEqualStrings("2.0.0", update.version);
    try std.testing.expect(update_manifest.eqlSha256Hex(&payload_sha256, update.sha256));

    // Setup test temporary directory for target binary
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(dir_path);

    const dummy_app_path = try std.fs.path.join(allocator, &.{ dir_path, "dummy_app" });
    defer allocator.free(dummy_app_path);

    // Create initial dummy binary with executable mode
    const initial_content = "original binary v1.0.0";
    {
        const f = try std.Io.Dir.cwd().createFile(io, dummy_app_path, .{
            .permissions = std.Io.File.Permissions.fromMode(0o755),
        });
        defer f.close(io);
        try f.writeStreamingAll(io, initial_content);
    }

    // 2. Download and verify replacement
    const ProgressContext = struct {
        called: bool = false,
        fn onProgress(ctx: ?*anyopaque, downloaded: u64, total: ?u64) void {
            _ = downloaded;
            _ = total;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.called = true;
        }
    };
    var progress_ctx = ProgressContext{};
    const progress_cb = ProgressCallback{
        .context = &progress_ctx,
        .callback = &ProgressContext.onProgress,
    };

    const returned_path = try download(io, allocator, update, dummy_app_path, progress_cb);
    defer allocator.free(returned_path);
    try std.testing.expectEqualStrings(dummy_app_path, returned_path);
    try std.testing.expect(progress_ctx.called);

    // Verify file content was replaced
    const updated_content = try std.Io.Dir.cwd().readFileAlloc(io, dummy_app_path, allocator, .limited(1024));
    defer allocator.free(updated_content);
    try std.testing.expectEqualStrings(new_payload, updated_content);

    // Verify mode is still executable
    {
        const f = try std.Io.Dir.cwd().openFile(io, dummy_app_path, .{});
        defer f.close(io);
        const st = try f.stat(io);
        try std.testing.expect(st.permissions.toMode() & 0o111 != 0);
    }

    // 3. Test bad SHA-256 leaves original binary intact and leaves no temp files
    var bad_update = update;
    bad_update.sha256 = "0000000000000000000000000000000000000000000000000000000000000000";

    const err = download(io, allocator, bad_update, dummy_app_path, null);
    try std.testing.expectError(error.PayloadHashMismatch, err);

    const intact_content = try std.Io.Dir.cwd().readFileAlloc(io, dummy_app_path, allocator, .limited(1024));
    defer allocator.free(intact_content);
    try std.testing.expectEqualStrings(new_payload, intact_content);

    // 4. Test gzip-compressed payload variant (format = raw.gz)
    const gz_payload_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/payload.gz", .{server.port});
    defer allocator.free(gz_payload_url);

    const gz_sign_params = update_manifest.SignParameters{
        .app_id = "dev.oriel.test",
        .version = "2.1.0",
        .target = DEFAULT_TARGET,
        .format = "raw.gz",
        .size = test_payload_gz.len,
        .sha256 = &gz_payload_sha256,
        .url = gz_payload_url,
        .allow_test_http = true,
    };

    const gz_sig_b64 = try update_manifest.sign(allocator, kp, gz_sign_params);
    defer allocator.free(gz_sig_b64);

    const gz_manifest_json = try update_manifest.formatManifest(allocator, gz_sign_params, gz_sig_b64);
    defer allocator.free(gz_manifest_json);
    server.setManifest(io, gz_manifest_json);

    var gz_cfg = base_cfg;
    gz_cfg.current_version = "2.0.0";
    const gz_update_opt = try checkForUpdate(io, allocator, gz_cfg);
    try std.testing.expect(gz_update_opt != null);
    var gz_update = gz_update_opt.?;
    defer gz_update.deinit();

    const gz_returned_path = try download(io, allocator, gz_update, dummy_app_path, null);
    defer allocator.free(gz_returned_path);

    const gz_decompressed_content = try std.Io.Dir.cwd().readFileAlloc(io, dummy_app_path, allocator, .limited(2048));
    defer allocator.free(gz_decompressed_content);
    try std.testing.expect(std.mem.startsWith(u8, gz_decompressed_content, "oriel update payload"));
}

test "Commands check -> install -> restart state transitions against MockServer with std.testing.allocator" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    try init(io, allocator, null);
    defer deinit(io);

    const kp = try Ed25519.KeyPair.generateDeterministic([_]u8{55} ** 32);
    const pk_b64 = "LISK2GZO5lHkiWwTqEqJopZKyl63eouIHmDe1cgbTp0=";

    const new_payload = "commands e2e payload content 2.0.0";
    var digest: [32]u8 = undefined;
    Sha256.hash(new_payload, &digest, .{});
    const payload_sha256 = std.fmt.bytesToHex(digest, .lower);

    const TEST_PORT: u16 = 19423;
    const manifest_url = std.fmt.comptimePrint("http://127.0.0.1:{d}/manifest.json", .{TEST_PORT});
    const payload_url = std.fmt.comptimePrint("http://127.0.0.1:{d}/payload", .{TEST_PORT});

    var server = try MockServer.start(io, TEST_PORT, "", new_payload, null);
    defer server.stop();

    const sign_params = update_manifest.SignParameters{
        .app_id = "dev.oriel.state",
        .version = "2.0.0",
        .target = DEFAULT_TARGET,
        .format = "raw",
        .size = new_payload.len,
        .sha256 = &payload_sha256,
        .url = payload_url,
        .allow_test_http = true,
    };

    const sig_b64 = try update_manifest.sign(allocator, kp, sign_params);
    defer allocator.free(sig_b64);

    const manifest_json = try update_manifest.formatManifest(allocator, sign_params, sig_b64);
    defer allocator.free(manifest_json);
    server.setManifest(io, manifest_json);

    const TestUpdater = Commands(.{
        .app_id = "dev.oriel.state",
        .manifest_url = manifest_url,
        .current_version = "1.0.0",
        .public_key_b64 = pk_b64,
        .target = DEFAULT_TARGET,
        .allow_http_for_test = true,
        .allocator = allocator,
    });

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(dir_path);

    const dummy_app_path = try std.fs.path.join(allocator, &.{ dir_path, "dummy_target_app" });
    defer allocator.free(dummy_app_path);

    {
        const f = try std.Io.Dir.cwd().createFile(io, dummy_app_path, .{
            .permissions = std.Io.File.Permissions.fromMode(0o755),
        });
        defer f.close(io);
        try f.writeStreamingAll(io, "initial app binary");
    }

    test_dest_override = dummy_app_path;
    defer {
        test_dest_override = null;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // 1. Check for update
    const check_res = try TestUpdater.updater_check(arena.allocator(), io);
    try std.testing.expect(check_res.available);
    try std.testing.expectEqualStrings("2.0.0", check_res.version.?);

    // 2. Set mock exec to verify restart doesn't actually exec
    const MockState = struct {
        var called_target_buf: [512]u8 = undefined;
        var called_target_len: usize = 0;
        fn mockExec(_: std.Io, exe_path: []const u8) anyerror!noreturn {
            @memcpy(called_target_buf[0..exe_path.len], exe_path);
            called_target_len = exe_path.len;
            return error.MockRestartExecuted;
        }
    };
    mock_exec_fn = &MockState.mockExec;
    defer {
        mock_exec_fn = null;
    }

    // 3. Test state machine rejects operations when busy
    state_mutex.lockUncancelable(io);
    current_state = .installing;
    state_mutex.unlock(io);

    try std.testing.expectError(error.UpdaterBusy, TestUpdater.updater_check(arena.allocator(), io));
    try std.testing.expectError(error.UpdaterBusy, TestUpdater.updater_install(arena.allocator(), io));
    try std.testing.expectError(error.UpdaterBusy, TestUpdater.updater_restart(arena.allocator(), io));

    state_mutex.lockUncancelable(io);
    current_state = .idle;
    state_mutex.unlock(io);

    // 4. Install the update
    const installed = try TestUpdater.updater_install(arena.allocator(), io);
    try std.testing.expect(installed);

    // Verify downloaded binary content replaced dummy app
    const installed_content = try std.Io.Dir.cwd().readFileAlloc(io, dummy_app_path, allocator, .limited(1024));
    defer allocator.free(installed_content);
    try std.testing.expectEqualStrings(new_payload, installed_content);

    // 5. Restart uses the downloaded target and catches mock exec error
    const restart_err = TestUpdater.updater_restart(arena.allocator(), io);
    try std.testing.expectError(error.MockRestartExecuted, restart_err);
    try std.testing.expectEqualStrings(dummy_app_path, MockState.called_target_buf[0..MockState.called_target_len]);
}
