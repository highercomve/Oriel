//! Updates: the version next to Settings, and "Check for updates".
//!
//! Each Oriel release attaches a signed `system-monitor-latest.json`
//! (Ed25519, the release key; oriel.updater checks it against the public key
//! built in). A copy updates from its own entry, so it stays the same kind of
//! build: `<arch>-<os>-<renderer>` for an executable (Linux, Windows, macOS
//! outside a bundle, `-exe` added on macOS), `x86_64-linux-appimage-oriel`
//! for the AppImage and `aarch64-macos-oriel` for the `.app` (the packages
//! use the Oriel renderer, the default). How an update applies depends on
//! how the monitor was installed:
//!
//! - An executable the user can write to (~/.local/bin, the Windows zip or
//!   installer), an AppImage, a macOS `.app`: replaced, then restarted.
//! - A deb/rpm package (/usr, /opt: the package manager owns the files):
//!   the check says a new version exists; the package manager installs it.

const std = @import("std");
const builtin = @import("builtin");
const oriel = @import("oriel");
const app = @import("oriel_app");
const build_info = @import("monitor_build");

const updater = oriel.updater;
const log = std.log.scoped(.updates);
const gpa = std.heap.smp_allocator;

pub const version: []const u8 = build_info.version;
pub const renderer: []const u8 = build_info.renderer;
pub const app_id = "dev.oriel.SystemMonitor";
pub const releases_url = "https://github.com/highercomve/Oriel/releases/latest";
const default_manifest_url = "https://github.com/highercomve/Oriel/releases/latest/download/system-monitor-latest.json";

var io: std.Io = undefined;
/// `ORIEL_MONITOR_UPDATE_MANIFEST` points the check elsewhere (a release's
/// manifest before it's the latest); signatures are still checked against
/// the built-in key.
var manifest_url: []const u8 = default_manifest_url;

/// How this copy was installed (decides how an update applies).
pub const InstallKind = enum {
    /// An executable the user can replace (Linux and macOS outside a bundle,
    /// Windows).
    executable,
    /// A Linux AppImage: the AppImage file is replaced.
    appimage,
    /// A macOS `.app` bundle: swapped for the new one.
    macos_app,
    /// A deb/rpm package: updated by the package manager.
    package,

    pub fn canInstall(self: InstallKind) bool {
        return self != .package;
    }
};

/// Call once from `main`, on the main thread (reads the environment).
pub fn init(actual_io: std.Io, env: *const std.process.Environ.Map) void {
    io = actual_io;
    if (env.get("ORIEL_MONITOR_UPDATE_MANIFEST")) |url| {
        if (gpa.dupe(u8, url)) |owned| {
            manifest_url = owned;
        } else |_| {}
    }
}

pub fn installKind() InstallKind {
    if (builtin.os.tag == .windows) return .executable;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.process.executablePath(io, &buf) catch return .executable;
    const exe = buf[0..n];
    if (builtin.os.tag == .macos and std.mem.indexOf(u8, exe, ".app/Contents/MacOS/") != null) return .macos_app;
    if (builtin.os.tag == .linux) {
        if (updater.runningAsAppImage(io, gpa) catch false) return .appimage;
        if (std.mem.startsWith(u8, exe, "/usr/") or std.mem.startsWith(u8, exe, "/opt/")) return .package;
    }
    return .executable;
}

/// This copy's entry in the manifest.
pub fn updateTarget(kind: InstallKind) []const u8 {
    return switch (kind) {
        .appimage => updater.DEFAULT_TARGET ++ "-appimage-" ++ build_info.renderer,
        .macos_app => updater.DEFAULT_TARGET ++ "-" ++ build_info.renderer,
        .executable, .package => updater.DEFAULT_TARGET ++ "-" ++ build_info.renderer ++ exe_suffix,
    };
}

/// A plain executable on macOS has its own entry: the `.app`'s is a bundle.
const exe_suffix = if (builtin.os.tag == .macos) "-exe" else "";

fn config(kind: InstallKind) updater.Config {
    return .{
        .app_id = app_id,
        .manifest_url = manifest_url,
        .current_version = version,
        .public_key_b64 = app.update_public_key orelse "",
        .target = updateTarget(kind),
    };
}

// ---- state ------------------------------------------------------------------------------

var mutex: std.Io.Mutex = .init;
/// The last verified update found (owned; its arena holds the strings).
var pending: ?updater.Update = null;
/// An update already installed: it runs after a restart.
var installed_version: ?[]u8 = null;
var busy: std.atomic.Value(bool) = .init(false);

// ---- commands ---------------------------------------------------------------------------

pub const Info = struct {
    version: []const u8,
    renderer: []const u8,
    install_kind: []const u8,
    can_install: bool,
    releases_url: []const u8,
    /// Installed and waiting for a restart.
    installed_version: ?[]const u8,
};

pub const CheckResult = struct {
    available: bool,
    version: ?[]const u8 = null,
    can_install: bool,
    /// This version is already installed (restart to run it).
    installed: bool = false,
    releases_url: []const u8 = releases_url,
};

pub const Progress = struct { downloaded: u64, total: ?u64 };

pub const Events = struct {
    @"monitor://update-progress": Progress,
};

pub const Commands = struct {
    pub const async_commands = .{ "update_check", "update_install", "update_restart" };

    pub fn app_version(arena: std.mem.Allocator) !Info {
        const kind = installKind();
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        return .{
            .version = version,
            .renderer = renderer,
            .install_kind = @tagName(kind),
            .can_install = kind.canInstall(),
            .releases_url = releases_url,
            .installed_version = if (installed_version) |v| try arena.dupe(u8, v) else null,
        };
    }

    pub fn update_check(arena: std.mem.Allocator) !CheckResult {
        const kind = installKind();
        const found = check(arena, kind) catch |err| return oriel.ipc.fail("Couldn't check for updates: {s}.", .{errorText(err)});
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        const already = if (installed_version) |v| (if (found) |f| std.mem.eql(u8, v, f) else false) else false;
        return .{ .available = found != null, .version = found, .can_install = kind.canInstall(), .installed = already };
    }

    /// Download and install the update the last check found; progress as
    /// `monitor://update-progress`.
    pub fn update_install(_: std.mem.Allocator) !void {
        if (!installKind().canInstall()) return oriel.ipc.fail("This copy is installed by a package manager: update it there.", .{});
        const v = install() catch |err| return oriel.ipc.fail("The update failed: {s}.", .{errorText(err)});
        gpa.free(v);
    }

    /// Start the installed version (after `update_install`).
    pub fn update_restart(_: std.mem.Allocator) !void {
        const dest = updater.resolveDestPath(io, gpa, null) catch |err| return oriel.ipc.fail("Can't restart: {s}", .{@errorName(err)});
        defer gpa.free(dest);
        updater.restart(io, dest) catch |err| return oriel.ipc.fail("Can't restart: {s}", .{@errorName(err)});
    }
};

// ---- check / install --------------------------------------------------------------------

/// Check the manifest; the newer version found (allocated with `out`), or
/// null when this is the newest.
fn check(out: std.mem.Allocator, kind: InstallKind) !?[]u8 {
    var found = try updater.checkForUpdate(io, gpa, config(kind));
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (pending) |*p| p.deinit();
    pending = null;
    if (found) |*f| {
        const v = out.dupe(u8, f.version) catch |err| {
            f.deinit();
            return err;
        };
        pending = f.*;
        return v;
    }
    return null;
}

/// Download and install the checked update; the version installed (gpa,
/// caller frees). A failed download keeps it, so Update can be retried.
fn install() ![]u8 {
    if (busy.swap(true, .acq_rel)) return error.UpdateInProgress;
    defer busy.store(false, .release);
    mutex.lockUncancelable(io);
    const update = pending orelse {
        mutex.unlock(io);
        return error.NoUpdateChecked;
    };
    pending = null; // ours now: a check meanwhile won't free it
    mutex.unlock(io);
    var u = update;
    var given_back = false;
    defer if (!given_back) u.deinit();

    const OnProgress = struct {
        fn cb(_: ?*anyopaque, downloaded: u64, total: ?u64) void {
            oriel.App.events(Events).emit(.@"monitor://update-progress", Progress{ .downloaded = downloaded, .total = total });
        }
    };
    const dest = updater.download(io, gpa, u, .{ .progress = .{ .callback = OnProgress.cb } }) catch |err| {
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        if (pending == null) {
            pending = u;
            given_back = true;
        }
        return err;
    };
    gpa.free(dest);
    const new_version = try gpa.dupe(u8, u.version);
    errdefer gpa.free(new_version);

    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (installed_version) |v| gpa.free(v);
    installed_version = gpa.dupe(u8, new_version) catch null;
    log.info("installed {s}; it runs after a restart", .{new_version});
    return new_version;
}

/// A short reason for the UI and the log.
fn errorText(err: anyerror) []const u8 {
    return switch (err) {
        error.ConnectionRefused, error.UnknownHostName, error.NetworkUnreachable, error.ConnectionTimedOut, error.TemporaryNameServerFailure => "no connection to GitHub",
        error.Timeout => "the server took too long",
        error.BadHttpStatus => "the latest release has no update information for the system monitor",
        error.TargetNotInManifest => "no updates are published for this build (" ++ build_info.renderer ++ " renderer)",
        error.InvalidSignature, error.SignatureVerificationFailed => "the release's signature doesn't match (not installed)",
        error.HashMismatch, error.Sha256Mismatch => "the download was damaged (not installed)",
        error.AccessDenied, error.PermissionDenied => "this user can't replace the monitor's files",
        error.FormatMismatch => "the release doesn't fit how this copy is installed",
        error.NoUpdateChecked => "check for updates first",
        error.UpdateInProgress => "an update is already downloading",
        else => @errorName(err),
    };
}

test InstallKind {
    try std.testing.expect(InstallKind.executable.canInstall());
    try std.testing.expect(InstallKind.appimage.canInstall());
    try std.testing.expect(!InstallKind.package.canInstall());
}
