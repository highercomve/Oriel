//! Self-updater: Ed25519-signed JSON manifest pointing to an update artifact
//! (raw executable/AppImage or gzip-compressed payload).
//! Includes:
//! - Manifest check over HTTP (std.http.Client) with Ed25519 signature verification
//! - Download with progress streaming, SHA-256 verification, fsync, and atomic replacement
//! - In-place restart via process replacement (re-executing the resolved target path)
//! - Secure comptime-configured IPC Commands for JS integration with throttled progress events

const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;
const oriel = @import("../oriel.zig");

// Pure-std manifest parsing and verification module
pub const update_manifest = @import("update_manifest.zig");
pub const Semver = update_manifest.Semver;
pub const Manifest = update_manifest.Manifest;
pub const verifyManifest = update_manifest.verify;

// ---------------------------------------------------------------------------
// Update Check & Download API
// ---------------------------------------------------------------------------

pub const Update = struct {
    version: []const u8,
    url: []const u8,
    sha256: []const u8,
    signature: []const u8,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Update) void {
        self.arena.deinit();
    }
};

/// Fetch manifest from `manifest_url`, verify Ed25519 signature against `public_key_b64`,
/// and compare `manifest.version` against `current_version`.
/// Returns `?Update` if a newer version is available, or `null` if current is up-to-date.
pub fn checkForUpdate(
    io: std.Io,
    gpa: std.mem.Allocator,
    manifest_url: []const u8,
    current_version: []const u8,
    public_key_b64: []const u8,
) !?Update {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    var body: std.Io.Writer.Allocating = .init(arena);
    defer body.deinit();

    const fetch_res = try client.fetch(.{
        .location = .{ .url = manifest_url },
        .response_writer = &body.writer,
    });
    if (fetch_res.status != .ok) return error.BadHttpStatus;

    const manifest_json = try body.toOwnedSlice();

    const manifest = try verifyManifest(arena, manifest_json, public_key_b64);

    const remote_ver = try Semver.parse(manifest.version);
    const local_ver = try Semver.parse(current_version);

    if (remote_ver.isNewerThan(local_ver)) {
        return Update{
            .version = manifest.version,
            .url = manifest.url,
            .sha256 = manifest.sha256,
            .signature = manifest.signature,
            .arena = arena_state,
        };
    }

    arena_state.deinit();
    return null;
}

pub const ProgressCallback = *const fn (downloaded: u64, total: ?u64) void;

/// Determine the target binary path:
/// 1. `dest_path` if specified
/// 2. `$APPIMAGE` if set and non-empty (running inside an AppImage)
/// 3. `/proc/self/exe` (resolved via `std.process.executablePathAlloc`)
pub fn resolveDestPath(io: std.Io, gpa: std.mem.Allocator, dest_path: ?[]const u8) ![]u8 {
    if (dest_path) |p| {
        if (p.len > 0) return try gpa.dupe(u8, p);
    }
    if (std.c.getenv("APPIMAGE")) |ai| {
        const appimage = std.mem.span(ai);
        if (appimage.len > 0) return try gpa.dupe(u8, appimage);
    }
    return try std.process.executablePathAlloc(io, gpa);
}

/// Download an update artifact to a temporary file next to the destination,
/// stream and compute SHA-256 on the fly, call `progress_callback`, verify the hash,
/// fsync to disk, and atomically rename over `dest_path`.
/// If the artifact is gzip-compressed (URL ends in .gz or payload starts with gzip header),
/// it is uncompressed before atomic replacement.
/// Returns the allocated target path (caller owns the slice and frees it with `gpa`).
pub fn download(
    io: std.Io,
    gpa: std.mem.Allocator,
    update: Update,
    dest_path: ?[]const u8,
    progress_callback: ?ProgressCallback,
) ![]u8 {
    const target_path = try resolveDestPath(io, gpa, dest_path);
    errdefer gpa.free(target_path);

    // Get existing destination permissions (default 0o755)
    var mode: std.posix.mode_t = 0o755;
    if (std.Io.Dir.cwd().openFile(io, target_path, .{})) |target_file| {
        defer target_file.close(io);
        if (target_file.stat(io)) |st| {
            mode = st.permissions.toMode();
        } else |_| {}
    } else |_| {}
    mode |= 0o700; // Ensure executable

    // Connect and fetch update artifact over HTTP
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(update.url);
    var req = try client.request(.GET, uri, .{
        .redirect_behavior = std.http.Client.Request.RedirectBehavior.init(3),
    });
    defer req.deinit();
    try req.sendBodiless();

    var redirect_buf: [8192]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);
    if (response.head.status != .ok) return error.BadHttpStatus;

    const total_bytes = response.head.content_length;
    var downloaded_bytes: u64 = 0;

    var transfer_buf: [65536]u8 = undefined;
    const reader = response.reader(&transfer_buf);

    var sha = Sha256.init(.{});
    var chunk_buf: [32768]u8 = undefined;

    // Check if the URL indicates gzip
    var is_gzip = std.mem.endsWith(u8, update.url, ".gz");

    // Create temporary download file next to target path
    var rand_val: u64 = undefined;
    io.random(std.mem.asBytes(&rand_val));
    const temp_dl_path = try std.fmt.allocPrint(gpa, "{s}.tmp_dl.{d}.{x}", .{ target_path, std.c.getpid(), rand_val });
    defer gpa.free(temp_dl_path);

    const cwd = std.Io.Dir.cwd();
    const temp_file = try cwd.createFile(io, temp_dl_path, .{
        .permissions = std.Io.File.Permissions.fromMode(mode),
    });

    // Guard against double close / double delete: tracking flags ensure each resource
    // is closed and unlinked at most once across all error paths.
    var temp_open: bool = true;
    var temp_exists: bool = true;
    defer {
        if (temp_open) temp_file.close(io);
        if (temp_exists) cwd.deleteFile(io, temp_dl_path) catch {}; // best-effort cleanup on error paths
    }

    var file_writer_buf: [32768]u8 = undefined;
    var temp_writer = temp_file.writerStreaming(io, &file_writer_buf);

    var first_chunk: bool = true;
    while (true) {
        const n = try reader.readSliceShort(&chunk_buf);
        if (n == 0) break;
        const chunk = chunk_buf[0..n];
        if (first_chunk) {
            first_chunk = false;
            if (chunk.len >= 2 and chunk[0] == 0x1f and chunk[1] == 0x8b) {
                is_gzip = true;
            }
        }
        sha.update(chunk);
        try temp_writer.interface.writeAll(chunk);
        downloaded_bytes += n;
        if (progress_callback) |cb| cb(downloaded_bytes, total_bytes);
    }
    try temp_writer.interface.flush();
    try temp_file.sync(io);

    // Verify SHA-256 of downloaded payload
    var digest: [32]u8 = undefined;
    sha.final(&digest);
    const computed_hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.ascii.eqlIgnoreCase(&computed_hex, update.sha256)) {
        return error.PayloadHashMismatch;
    }

    // Close download file
    temp_file.close(io);
    temp_open = false;

    if (is_gzip) {
        // Open the verified downloaded archive for decompression
        const gz_file = try cwd.openFile(io, temp_dl_path, .{});
        defer gz_file.close(io);

        // Atomically replace target using std.Io.Dir createFileAtomic
        var target_atomic = try cwd.createFileAtomic(io, target_path, .{
            .permissions = std.Io.File.Permissions.fromMode(mode),
            .replace = true,
        });
        defer target_atomic.deinit(io);

        var gz_read_buf: [65536]u8 = undefined;
        var gz_reader = gz_file.readerStreaming(io, &gz_read_buf);

        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var decompress = std.compress.flate.Decompress.init(&gz_reader.interface, .gzip, &window);

        var out_buf: [32768]u8 = undefined;
        var out_writer_buf: [32768]u8 = undefined;
        var out_writer = target_atomic.file.writerStreaming(io, &out_writer_buf);

        while (true) {
            const n = try decompress.reader.readSliceShort(&out_buf);
            if (n == 0) break;
            try out_writer.interface.writeAll(out_buf[0..n]);
        }
        try out_writer.interface.flush();
        try target_atomic.file.sync(io);

        // Atomic replace into target path
        try target_atomic.replace(io);

        // Clean up temporary compressed download file
        cwd.deleteFile(io, temp_dl_path) catch {}; // best effort: the update is already in place
        temp_exists = false;
    } else {
        // The temp file was created with the target's mode; rename it over the target.
        try std.Io.Dir.renameAbsolute(temp_dl_path, target_path, io);
        temp_exists = false;
    }

    return target_path;
}

/// Re-exec the updated binary using std.process.replace with original arguments.
/// Execs the resolved `exe_path` instead of `/proc/self/exe` to avoid executing
/// the deleted file inode after atomic rename.
pub fn restart(io: std.Io, exe_path: []const u8) !noreturn {
    const cwd = std.Io.Dir.cwd();
    const cmdline_file = cwd.openFile(io, "/proc/self/cmdline", .{}) catch return error.CannotReadCmdline;
    defer cmdline_file.close(io);

    var cmdline_buf: [16384]u8 = undefined;
    var reader_buf: [2048]u8 = undefined;
    var stream_reader = cmdline_file.readerStreaming(io, &reader_buf);
    const bytes_read = stream_reader.interface.readSliceShort(&cmdline_buf) catch return error.CannotReadCmdline;
    if (bytes_read == 0) return error.CannotReadCmdline;

    var argv_storage: [256][]const u8 = undefined;
    var argc: usize = 0;
    var idx: usize = 0;
    const len = bytes_read;

    // First argument is replaced with the resolved target path
    argv_storage[0] = exe_path;
    argc = 1;

    // Skip the old argv[0] in cmdline_buf
    while (idx < len and cmdline_buf[idx] != 0) : (idx += 1) {}
    if (idx < len and cmdline_buf[idx] == 0) idx += 1;

    // Collect remaining arguments (argv[1..])
    while (idx < len and argc < 255) {
        if (cmdline_buf[idx] == 0) {
            idx += 1;
            continue;
        }
        const start = idx;
        while (idx < len and cmdline_buf[idx] != 0) : (idx += 1) {}
        argv_storage[argc] = cmdline_buf[start..idx];
        argc += 1;
        if (idx < len and cmdline_buf[idx] == 0) idx += 1;
    }

    const argv = argv_storage[0..argc];
    const err = std.process.replace(io, .{ .argv = argv });
    return err;
}

/// Helper progress callback that emits an `updater://progress` event to JS via `oriel.App.emit`.
pub fn emitProgress(downloaded: u64, total: ?u64) void {
    oriel.App.emit("updater://progress", .{ .downloaded = downloaded, .total = total });
}

/// Unpack gzip payload and verify sha256 (kept for backwards compatibility).
pub fn unpack(gpa: std.mem.Allocator, manifest: Manifest, payload_gz: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    Sha256.hash(payload_gz, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, manifest.sha256)) return error.PayloadHashMismatch;

    var in: std.Io.Reader = .fixed(payload_gz);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&in, .gzip, &window);
    return decompress.reader.allocRemaining(gpa, .unlimited);
}

// ---------------------------------------------------------------------------
// Comptime-Configured Commands for JS IPC
// ---------------------------------------------------------------------------

pub const Config = struct {
    manifest_url: []const u8,
    current_version: []const u8,
    public_key_b64: []const u8,
};

/// Module-level state storing verified update and target path between IPC calls.
var state_mutex: std.Io.Mutex = .init;
var verified_update: ?Update = null;
var verified_target_path: ?[]const u8 = null;

/// Generate secure IPC Commands bound to `config`.
/// JavaScript callers cannot supply or alter the manifest URL, public key, or destination path.
///
/// Usage in an application's `main.zig`:
/// ```zig
/// const Updater = oriel.updater.Commands(.{
///     .manifest_url = "https://releases.example.com/manifest.json",
///     .current_version = "1.0.0",
///     .public_key_b64 = @import("oriel_app").update_public_key orelse "...",
/// });
///
/// pub const Commands = struct {
///     // Re-export updater commands:
///     pub const updater_check = Updater.updater_check;
///     pub const updater_install = Updater.updater_install;
///     pub const updater_restart = Updater.updater_restart;
///
///     pub const async_commands = .{ "updater_check", "updater_install", "updater_restart" };
/// };
/// ```
pub fn Commands(comptime config: Config) type {
    return struct {
        pub const async_commands = .{ "updater_check", "updater_install", "updater_restart" };

        pub const CheckResult = struct {
            available: bool,
            version: ?[]const u8 = null,
        };

        /// Check for update: verifies the manifest and saves the verified Update
        /// in module state. Returns { available: bool, version: ?string }.
        pub fn updater_check(arena: std.mem.Allocator, io: std.Io) !CheckResult {
            const smp = std.heap.smp_allocator;
            const maybe_update = try checkForUpdate(io, smp, config.manifest_url, config.current_version, config.public_key_b64);

            state_mutex.lockUncancelable(io);
            defer state_mutex.unlock(io);

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
        /// The pending update is taken out of the shared state first, so a
        /// concurrent `updater_check` cannot free it mid-download.
        pub fn updater_install(_: std.mem.Allocator, io: std.Io) !bool {
            const smp = std.heap.smp_allocator;

            state_mutex.lockUncancelable(io);
            var update = verified_update orelse {
                state_mutex.unlock(io);
                return error.NoUpdatePending;
            };
            verified_update = null;
            state_mutex.unlock(io);
            defer update.deinit();

            // At most ~10 events per second plus a final one. Only one
            // install runs at a time in practice; the statics are reset here.
            const Throttler = struct {
                var clock_io: std.Io = undefined;
                var last_emit_ms: i64 = 0;
                var last_downloaded: u64 = 0;
                var last_total: ?u64 = null;

                fn onProgress(downloaded: u64, total: ?u64) void {
                    last_downloaded = downloaded;
                    last_total = total;
                    const now = std.Io.Timestamp.now(clock_io, .awake).toMilliseconds();
                    if (now - last_emit_ms >= 100) {
                        last_emit_ms = now;
                        emitProgress(downloaded, total);
                    }
                }
            };
            Throttler.clock_io = io;
            Throttler.last_emit_ms = 0;
            Throttler.last_downloaded = 0;
            Throttler.last_total = null;

            const target_path = try download(io, smp, update, null, &Throttler.onProgress);
            emitProgress(Throttler.last_downloaded, Throttler.last_total);

            state_mutex.lockUncancelable(io);
            if (verified_target_path) |prev| smp.free(prev);
            verified_target_path = target_path;
            state_mutex.unlock(io);

            return true;
        }

        /// Restart the application using the downloaded updated binary.
        pub fn updater_restart(_: std.mem.Allocator, io: std.Io) !void {
            state_mutex.lockUncancelable(io);
            const target = verified_target_path;
            state_mutex.unlock(io);

            const final_path = if (target) |tp| tp else blk: {
                const smp = std.heap.smp_allocator;
                break :blk try resolveDestPath(io, smp, null);
            };

            try restart(io, final_path);
        }
    };
}

// ---------------------------------------------------------------------------
// Module Smoke Check
// ---------------------------------------------------------------------------

/// 'oriel update payload v0.0.1\n' x 8, gzip'd.
const test_payload_gz = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xff, 0xcb, 0x2f, 0xca, 0x4c, 0xcd, 0x51,
    0x28, 0x2d, 0x48, 0x49, 0x2c, 0x49, 0x55, 0x28, 0x48, 0xac, 0xcc, 0xc9, 0x4f, 0x4c, 0x51, 0x28,
    0x33, 0xd0, 0x33, 0xd0, 0x33, 0xe4, 0xca, 0x1f, 0x06, 0x72, 0x00, 0x2d, 0x20, 0xe4, 0xcb, 0xe0,
    0x00, 0x00, 0x00,
};

pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    // Release side: hash the payload, write and sign the manifest using update_manifest
    const key_pair = try Ed25519.KeyPair.generateDeterministic([_]u8{42} ** Ed25519.KeyPair.seed_length);
    var pk_b64: [update_manifest.PUBLIC_KEY_B64_LEN]u8 = undefined;
    _ = update_manifest.encodePublicKey(key_pair.public_key.toBytes(), &pk_b64);

    var digest: [32]u8 = undefined;
    Sha256.hash(&test_payload_gz, &digest, .{});
    const sha256_hex = std.fmt.bytesToHex(digest, .lower);

    const sig_b64 = try update_manifest.sign(gpa, key_pair, "0.0.1", "https://example.invalid/app.gz", &sha256_hex);
    defer gpa.free(sig_b64);

    const manifest_json = try update_manifest.formatManifest(gpa, "0.0.1", "https://example.invalid/app.gz", &sha256_hex, sig_b64);
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

test "app merges updater Commands pattern" {
    const TestCommands = struct {
        const Updater = Commands(.{
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
    // Force semantic analysis of every generated command body.
    std.testing.refAllDecls(TestCommands.Updater);

    // The merged set dispatches through ipc and generates TypeScript; the
    // updater commands take no JS arguments (URL, key and path are fixed).
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
    manifest_json: []const u8,
    payload: []const u8,
    gzip_payload: ?[]const u8 = null,

    fn start(io: std.Io, manifest_json: []const u8, payload: []const u8, gzip_payload: ?[]const u8) !*MockServer {
        const allocator = std.testing.allocator;
        const self = try allocator.create(MockServer);
        errdefer allocator.destroy(self);

        const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        self.server = try addr.listen(io, .{ .reuse_address = true });
        self.port = self.server.socket.address.ip4.port;
        self.io = io;
        self.manifest_json = manifest_json;
        self.payload = payload;
        self.gzip_payload = gzip_payload;
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    fn run(self: *MockServer) void {
        while (true) {
            var stream = self.server.accept(self.io) catch break;
            defer stream.close(self.io);

            var read_buf: [2048]u8 = undefined;
            var reader = stream.reader(self.io, &read_buf);

            // Read the request head until \r\n\r\n to prevent blocking/deadlock
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
                var w_buf: [4096]u8 = undefined;
                var writer = stream.writer(self.io, &w_buf);
                writer.interface.print("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{s}", .{ self.manifest_json.len, self.manifest_json }) catch {};
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

    // Start mock server first to obtain ephemeral port (no port reuse race)
    var server = try MockServer.start(io, "", new_payload, &test_payload_gz);
    defer server.stop();

    const payload_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/payload", .{server.port});
    defer allocator.free(payload_url);

    // Sign manifest: "2.0.0"
    const sig_b64 = try update_manifest.sign(allocator, kp, "2.0.0", payload_url, &payload_sha256);
    defer allocator.free(sig_b64);

    const manifest_json = try update_manifest.formatManifest(allocator, "2.0.0", payload_url, &payload_sha256, sig_b64);
    defer allocator.free(manifest_json);
    server.manifest_json = manifest_json;

    const manifest_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/manifest.json", .{server.port});
    defer allocator.free(manifest_url);

    // 1. Version checks:
    // Same-or-older version returns null
    const no_update_same = try checkForUpdate(io, allocator, manifest_url, "2.0.0", &pk_b64);
    try std.testing.expect(no_update_same == null);

    const no_update_older = try checkForUpdate(io, allocator, manifest_url, "3.0.0", &pk_b64);
    try std.testing.expect(no_update_older == null);

    // Manifest signed with another key is rejected by checkForUpdate
    const wrong_key_result = checkForUpdate(io, allocator, manifest_url, "1.0.0", &wrong_pk_b64);
    try std.testing.expectError(error.SignatureVerificationFailed, wrong_key_result);

    // Valid check: 1.0.0 -> 2.0.0 available
    const update_opt = try checkForUpdate(io, allocator, manifest_url, "1.0.0", &pk_b64);
    try std.testing.expect(update_opt != null);
    var update = update_opt.?;
    defer update.deinit();

    try std.testing.expectEqualStrings("2.0.0", update.version);
    try std.testing.expectEqualStrings(&payload_sha256, update.sha256);

    // Setup test temporary directory for target dummy binary
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
    const ProgressState = struct {
        var called: bool = false;
        fn onProgress(downloaded: u64, total: ?u64) void {
            _ = downloaded;
            _ = total;
            called = true;
        }
    };
    ProgressState.called = false;

    const returned_path = try download(io, allocator, update, dummy_app_path, ProgressState.onProgress);
    defer allocator.free(returned_path);
    try std.testing.expectEqualStrings(dummy_app_path, returned_path);
    try std.testing.expect(ProgressState.called);

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

    // Verify no leftover temp files exist in tmpDir
    {
        var it = tmp.dir.iterate();
        var count: usize = 0;
        while (try it.next(io)) |entry| {
            count += 1;
            try std.testing.expectEqualStrings("dummy_app", entry.name);
        }
        try std.testing.expectEqual(@as(usize, 1), count);
    }

    // 3. Test bad SHA-256 leaves original binary intact and leaves no temp files
    var bad_update = update;
    bad_update.sha256 = "0000000000000000000000000000000000000000000000000000000000000000";

    const err = download(io, allocator, bad_update, dummy_app_path, null);
    try std.testing.expectError(error.PayloadHashMismatch, err);

    // Content still matches previous valid update
    const intact_content = try std.Io.Dir.cwd().readFileAlloc(io, dummy_app_path, allocator, .limited(1024));
    defer allocator.free(intact_content);
    try std.testing.expectEqualStrings(new_payload, intact_content);

    // No temp files left behind
    {
        var it = tmp.dir.iterate();
        var count: usize = 0;
        while (try it.next(io)) |entry| {
            count += 1;
            try std.testing.expectEqualStrings("dummy_app", entry.name);
        }
        try std.testing.expectEqual(@as(usize, 1), count);
    }

    // 4. Test gzip-compressed payload variant
    const gz_payload_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/payload.gz", .{server.port});
    defer allocator.free(gz_payload_url);

    const gz_sig_b64 = try update_manifest.sign(allocator, kp, "2.1.0", gz_payload_url, &gz_payload_sha256);
    defer allocator.free(gz_sig_b64);

    const gz_manifest_json = try update_manifest.formatManifest(allocator, "2.1.0", gz_payload_url, &gz_payload_sha256, gz_sig_b64);
    defer allocator.free(gz_manifest_json);
    server.manifest_json = gz_manifest_json;

    const gz_update_opt = try checkForUpdate(io, allocator, manifest_url, "2.0.0", &pk_b64);
    try std.testing.expect(gz_update_opt != null);
    var gz_update = gz_update_opt.?;
    defer gz_update.deinit();

    const gz_returned_path = try download(io, allocator, gz_update, dummy_app_path, null);
    defer allocator.free(gz_returned_path);

    // Verify decompressed content starts with expected prefix
    const gz_decompressed_content = try std.Io.Dir.cwd().readFileAlloc(io, dummy_app_path, allocator, .limited(2048));
    defer allocator.free(gz_decompressed_content);
    try std.testing.expect(std.mem.startsWith(u8, gz_decompressed_content, "oriel update payload"));

    // Verify mode is still executable
    {
        const f = try std.Io.Dir.cwd().openFile(io, dummy_app_path, .{});
        defer f.close(io);
        const st = try f.stat(io);
        try std.testing.expect(st.permissions.toMode() & 0o111 != 0);
    }

    // No leftover temp files
    {
        var it = tmp.dir.iterate();
        var count: usize = 0;
        while (try it.next(io)) |entry| {
            count += 1;
            try std.testing.expectEqualStrings("dummy_app", entry.name);
        }
        try std.testing.expectEqual(@as(usize, 1), count);
    }
}
