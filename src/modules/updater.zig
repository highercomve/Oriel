//! Self-updater: Ed25519-signed JSON manifest pointing to an update artifact
//! (raw executable/AppImage or gzip-compressed payload).
//! Re-exports the GTK-free core updater engine and provides:
//! - Webview IPC Commands for JS integration (updater_check, updater_install, updater_restart)
//! - Throttled updater://progress events sent via oriel.App.emit
//! - Module smoke check for examples/smoke and `oriel doctor`

const std = @import("std");
const builtin = @import("builtin");
const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;
const oriel = @import("../oriel.zig");

pub const core = @import("../updater_core.zig");

// Re-export core items so apps have the exact same API
pub const backend = core.backend;
pub const update_manifest = core.update_manifest;
pub const Semver = core.Semver;
pub const Manifest = core.Manifest;
pub const verifyManifest = core.verifyManifest;
pub const verifyManifestWithOptions = core.verifyManifestWithOptions;

pub const DEFAULT_TARGET = core.DEFAULT_TARGET;
pub const DEFAULT_TIMEOUT_MS = core.DEFAULT_TIMEOUT_MS;
pub const DEFAULT_DOWNLOAD_TIMEOUT_MS = core.DEFAULT_DOWNLOAD_TIMEOUT_MS;
pub const MAX_CMDLINE_LEN = core.MAX_CMDLINE_LEN;
pub const MAX_ARGV_COUNT = core.MAX_ARGV_COUNT;

pub const isUnderDir = core.isUnderDir;
pub const decideDestPath = core.decideDestPath;
pub const runningAsAppImage = core.runningAsAppImage;
pub const resolveDestPath = core.resolveDestPath;

pub const Update = core.Update;
pub const Config = core.Config;
pub const checkForUpdate = core.checkForUpdate;
pub const ProgressCallback = core.ProgressCallback;
pub const download = core.download;
pub const downloadWithOptions = core.downloadWithOptions;
pub const splitCmdline = core.splitCmdline;
pub const restart = core.restart;
pub const unpack = core.unpack;

pub const setTestDestOverride = core.setTestDestOverride;
pub const setMockExecFn = core.setMockExecFn;

// ---------------------------------------------------------------------------
// Module Lifecycle & Environment Capture
// ---------------------------------------------------------------------------

var state_mutex: std.Io.Mutex = .init;
var current_state: State = .idle;
var verified_update: ?Update = null;
var verified_target_path: ?[]const u8 = null;
var module_allocator: ?std.mem.Allocator = null;

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
    try core.init(io, allocator, env_map);
}

pub fn deinit(io: std.Io) void {
    state_mutex.lockUncancelable(io);
    defer state_mutex.unlock(io);

    const alloc = module_allocator orelse std.heap.smp_allocator;

    if (verified_update) |*u| {
        u.deinit();
        verified_update = null;
    }
    if (verified_target_path) |tp| {
        alloc.free(tp);
        verified_target_path = null;
    }
    current_state = .idle;
    module_allocator = null;

    core.deinit(io);
}

fn getAllocator(config_allocator: ?std.mem.Allocator) std.mem.Allocator {
    if (config_allocator) |a| return a;
    return module_allocator orelse std.heap.smp_allocator;
}

/// Helper progress callback that emits an `updater://progress` event to JS via `oriel.App.emit`.
pub fn emitProgress(downloaded: u64, total: ?u64) void {
    oriel.App.emit("updater://progress", .{ .downloaded = downloaded, .total = total });
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

pub const test_payload_gz = core.test_payload_gz;

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

pub const MockServer = core.MockServer;

test "Commands check -> install -> restart state transitions against MockServer with std.testing.allocator" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
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

    setTestDestOverride(dummy_app_path);
    defer {
        setTestDestOverride(null);
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
    setMockExecFn(&MockState.mockExec);
    defer {
        setMockExecFn(null);
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

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(core);
}
