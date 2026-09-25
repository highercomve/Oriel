//! `oriel zig`: the Zig version manager.
//!
//! The commands that run Zig (`oriel dev/build/run/package/types/check`,
//! `oriel init`) resolve the binary in this order:
//!
//!   1. `$ORIEL_ZIG`: explicit; a version other than the project's is an error.
//!   2. `zig` on PATH, when its version matches the project's
//!      `build.zig.zon` `.minimum_zig_version` (same major.minor, not older).
//!   3. A managed install: `~/.oriel/zig/<version>/zig` (Windows:
//!      `%USERPROFILE%\.oriel\zig\<version>\zig.exe`; `$ORIEL_HOME`
//!      replaces `~/.oriel`).
//!   4. Otherwise that version is downloaded and installed there, unless
//!      `ORIEL_NO_ZIG_INSTALL=1`.
//!
//! Downloads follow https://ziglang.org/download/community-mirrors/: the
//! tarball and its `.minisig` come from a randomly ordered community mirror,
//! with ziglang.org as the last fallback. A tarball is used only when its
//! minisign signature verifies against the Zig Software Foundation's public
//! key, the trusted comment's global signature verifies, and the signed
//! `file:` name is the requested tarball (no downgrade by substitution).
//! Extraction rejects absolute paths, `..`, drive letters, backslashes and
//! symlinks (Zig releases have none); the result is renamed into place
//! under a lock file.

const std = @import("std");
const builtin = @import("builtin");
const Context = @import("Context.zig");
const project = @import("project.zig");
const webview2 = @import("webview2.zig");

const Dir = std.Io.Dir;

pub const Action = enum { install, uninstall, list, which };

pub const Command = struct {
    pub const summary = "Install and manage the Zig versions Oriel uses (~/.oriel/zig)";
    pub const positionals = .{ "action", "version" };
    pub const help = .{
        .action = "install | uninstall | list | which",
        .version = "Zig version, e.g. 0.16.0 (default: the project's minimum_zig_version)",
    };
    pub const details =
        \\install [version]   Download (from a community mirror, minisign-verified)
        \\                    and install Zig into ~/.oriel/zig/<version>
        \\uninstall <version> Remove ~/.oriel/zig/<version>
        \\list                Installed versions, and the zig on PATH
        \\which               The zig this project uses, and where it comes from
        \\
        \\Other commands install the project's Zig on first use when neither
        \\$ORIEL_ZIG nor the zig on PATH matches it (ORIEL_NO_ZIG_INSTALL=1 to
        \\disable). ORIEL_HOME moves ~/.oriel; ORIEL_ZIG_MIRRORS replaces the
        \\community mirror list (e.g. a company mirror; ziglang.org stays the
        \\fallback, and every download is minisign-verified).
    ;

    action: Action,
    version: ?[]const u8 = null,
};

/// The Zig version when not inside a project (the templates' minimum).
pub const default_version = "0.16.0";

/// The Zig Software Foundation's minisign public key, copied from
/// https://ziglang.org/download/ ("minisign public key") on 2026-09-25.
pub const zsf_public_key = "RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U";

const mirrors_url = "https://ziglang.org/download/community-mirrors.txt";
const origin_base = "https://ziglang.org/download";
const source_param = "oriel-cli";
/// Largest tarball accepted (0.16.0 is 50-100 MB).
const max_download: usize = 400 << 20;
/// Largest total size extracted from one archive.
const max_extracted: u64 = 2 << 30;
const max_small_download: usize = 64 << 10;
/// A mirror slower than this on average (after 20 s) is skipped.
const min_mirror_rate: u64 = 64 << 10;

// ---------------------------------------------------------------------------
// Versions
// ---------------------------------------------------------------------------

/// `have` can build a project whose minimum is `want`: same major.minor and
/// not older (Zig changes incompatibly between minor versions).
pub fn versionMatches(have: []const u8, want: []const u8) bool {
    const h = std.SemanticVersion.parse(have) catch return false;
    const w = std.SemanticVersion.parse(want) catch return false;
    return h.major == w.major and h.minor == w.minor and h.order(w) != .lt;
}

/// A version string that is safe as a directory and file name part.
pub fn isValidVersion(v: []const u8) bool {
    _ = std.SemanticVersion.parse(v) catch return false;
    for (v) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '.' and ch != '-' and ch != '+') return false;
    }
    return true;
}

/// `.minimum_zig_version = "x.y.z"` from build.zig.zon text, or null.
pub fn requiredFromZon(zon: []const u8) ?[]const u8 {
    const key = ".minimum_zig_version";
    const at = std.mem.indexOf(u8, zon, key) orelse return null;
    const rest = zon[at + key.len ..];
    const open = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    if (std.mem.indexOfScalar(u8, rest[0..open], ';') != null) return null;
    const close = std.mem.indexOfScalarPos(u8, rest, open + 1, '"') orelse return null;
    const v = rest[open + 1 .. close];
    return if (isValidVersion(v)) v else null;
}

/// The project's required Zig (`root/build.zig.zon`), else `default_version`.
/// The result is allocated with `gpa`.
pub fn requiredForRoot(ctx: Context, root: []const u8) ![]u8 {
    const zon_path = try std.fs.path.join(ctx.gpa, &.{ root, "build.zig.zon" });
    defer ctx.gpa.free(zon_path);
    const zon = Dir.cwd().readFileAlloc(ctx.io, zon_path, ctx.gpa, .limited(1 << 20)) catch
        return ctx.gpa.dupe(u8, default_version);
    defer ctx.gpa.free(zon);
    return ctx.gpa.dupe(u8, requiredFromZon(zon) orelse default_version);
}

/// The required Zig for the current directory's project (or the default).
pub fn requiredHere(ctx: Context) ![]u8 {
    const cwd = try std.process.currentPathAlloc(ctx.io, ctx.gpa);
    defer ctx.gpa.free(cwd);
    const root = try project.findRoot(ctx.gpa, ctx.io, cwd) orelse return ctx.gpa.dupe(u8, default_version);
    defer ctx.gpa.free(root);
    return requiredForRoot(ctx, root);
}

// ---------------------------------------------------------------------------
// Resolution
// ---------------------------------------------------------------------------

pub const Source = enum {
    /// `$ORIEL_ZIG`
    env,
    /// `zig` on PATH
    path,
    /// `~/.oriel/zig/<version>`
    managed,
    /// not available yet: `resolve` installs it
    install,

    pub fn label(s: Source) []const u8 {
        return switch (s) {
            .env => "ORIEL_ZIG",
            .path => "PATH",
            .managed => "managed",
            .install => "would install",
        };
    }
};

pub const Choice = struct {
    source: Source,
    /// For `.managed`: the installed version to use (an element of `installed`).
    managed_version: ?[]const u8 = null,
};

/// The resolution order (pure, so it can be tested without Zig or network).
/// `env_version`: the version `$ORIEL_ZIG` reported (null when unset);
/// `env_set`: whether `$ORIEL_ZIG` is set; `path_version`: the version of
/// `zig` on PATH (null when there is none); `installed`: managed versions.
pub fn choose(want: []const u8, env_set: bool, env_version: ?[]const u8, path_version: ?[]const u8, installed: []const []const u8) error{OrielZigMismatch}!Choice {
    if (env_set) {
        const v = env_version orelse return error.OrielZigMismatch;
        if (!versionMatches(v, want)) return error.OrielZigMismatch;
        return .{ .source = .env };
    }
    if (path_version) |v| if (versionMatches(v, want)) return .{ .source = .path };
    // Prefer the exact version, else the newest compatible one.
    var best: ?[]const u8 = null;
    for (installed) |v| {
        if (!versionMatches(v, want)) continue;
        if (std.mem.eql(u8, v, want)) return .{ .source = .managed, .managed_version = v };
        if (best == null or (std.SemanticVersion.parse(v) catch unreachable).order(std.SemanticVersion.parse(best.?) catch unreachable) == .gt) best = v;
    }
    if (best) |v| return .{ .source = .managed, .managed_version = v };
    return .{ .source = .install };
}

/// A resolved Zig binary. `path`/`version` are allocated with the gpa.
pub const Resolved = struct {
    path: []u8,
    version: []u8,
    source: Source,

    pub fn deinit(r: Resolved, gpa: std.mem.Allocator) void {
        gpa.free(r.path);
        gpa.free(r.version);
    }
};

/// `zig version` of `zig_path`, or null if it doesn't run. Caller frees.
fn zigVersion(ctx: Context, zig_path: []const u8) ?[]u8 {
    const out = ctx.capture(&.{ zig_path, "version" }, 30_000) orelse return null;
    defer out.deinit(ctx.gpa);
    if (out.code != 0) return null;
    return ctx.gpa.dupe(u8, out.text()) catch null;
}

/// Where each candidate stands, without installing anything.
pub const Plan = struct {
    choice: Choice,
    want: []const u8,
    env_zig: ?[]const u8 = null,
    env_version: ?[]u8 = null,
    path_zig: ?[]u8 = null,
    path_version: ?[]u8 = null,
    installed: [][]u8 = &.{},

    pub fn deinit(p: Plan, gpa: std.mem.Allocator) void {
        if (p.env_version) |v| gpa.free(v);
        if (p.path_zig) |v| gpa.free(v);
        if (p.path_version) |v| gpa.free(v);
        freeList(gpa, p.installed);
    }
};

/// Probe `$ORIEL_ZIG`, PATH and the managed installs for `want`.
pub fn plan(ctx: Context, want: []const u8) !Plan {
    var p: Plan = .{ .choice = undefined, .want = want };
    errdefer p.deinit(ctx.gpa);
    if (ctx.environ.get("ORIEL_ZIG")) |z| if (z.len > 0) {
        p.env_zig = z;
        p.env_version = zigVersion(ctx, z);
    };
    if (p.env_zig == null) {
        if (try ctx.findExecutable("zig")) |found| {
            p.path_zig = found;
            p.path_version = zigVersion(ctx, found);
        }
    }
    p.installed = try listInstalled(ctx);
    p.choice = try choose(want, p.env_zig != null, p.env_version, p.path_version, p.installed);
    return p;
}

/// The Zig binary to run for a project needing `want`, installing it when
/// needed (see the file comment). Prints why when a PATH zig is skipped or
/// an install happens.
pub fn resolve(ctx: Context, want: []const u8) !Resolved {
    const p = plan(ctx, want) catch |err| switch (err) {
        error.OrielZigMismatch => {
            const z = ctx.environ.get("ORIEL_ZIG") orelse "";
            try ctx.err.print("error: ORIEL_ZIG={s} is not Zig {s} (this project's minimum_zig_version); unset it to let oriel use or install {s}\n", .{ z, want, want });
            return err;
        },
        else => {
            try ctx.err.print("error: finding Zig {s}: {s}\n", .{ want, @errorName(err) });
            return err;
        },
    };
    defer p.deinit(ctx.gpa);
    switch (p.choice.source) {
        .env => return owned(ctx, try ctx.gpa.dupe(u8, p.env_zig.?), p.env_version.?, .env),
        .path => return owned(ctx, try ctx.gpa.dupe(u8, p.path_zig.?), p.path_version.?, .path),
        .managed => {
            const v = p.choice.managed_version.?;
            return owned(ctx, try managedZigPath(ctx, v), v, .managed);
        },
        .install => {
            if (p.path_version) |pv| try ctx.err.print("info: zig on PATH is {s}; this project needs Zig {s}\n", .{ pv, want });
            if (envFlag(ctx, "ORIEL_NO_ZIG_INSTALL")) {
                try ctx.err.print("error: Zig {s} is not installed and ORIEL_NO_ZIG_INSTALL=1; run `oriel zig install {s}` or set ORIEL_ZIG\n", .{ want, want });
                return error.ZigNotInstalled;
            }
            return owned(ctx, try install(ctx, want), want, .managed);
        },
    }
}

/// A Resolved taking ownership of `path` (freed if copying `version` fails).
fn owned(ctx: Context, path: []u8, version: []const u8, source: Source) !Resolved {
    errdefer ctx.gpa.free(path);
    return .{ .path = path, .version = try ctx.gpa.dupe(u8, version), .source = source };
}

fn envFlag(ctx: Context, name: []const u8) bool {
    const v = ctx.environ.get(name) orelse return false;
    return v.len > 0 and !std.mem.eql(u8, v, "0");
}

// ---------------------------------------------------------------------------
// Locations
// ---------------------------------------------------------------------------

/// `$ORIEL_HOME`, else `~/.oriel` (`%USERPROFILE%\.oriel` on Windows).
pub fn orielHome(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]u8 {
    if (environ.get("ORIEL_HOME")) |h| if (h.len > 0) return gpa.dupe(u8, h);
    const home_var = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    const home = environ.get(home_var) orelse return error.NoHomeDirectory;
    if (home.len == 0) return error.NoHomeDirectory;
    return std.fs.path.join(gpa, &.{ home, ".oriel" });
}

/// `<oriel home>/zig`.
pub fn zigRoot(ctx: Context) ![]u8 {
    const home = try orielHome(ctx.gpa, ctx.environ);
    defer ctx.gpa.free(home);
    return std.fs.path.join(ctx.gpa, &.{ home, "zig" });
}

const exe_name = if (builtin.os.tag == .windows) "zig.exe" else "zig";

/// `<zig root>/<version>/zig[.exe]`.
pub fn managedZigPath(ctx: Context, version: []const u8) ![]u8 {
    const root = try zigRoot(ctx);
    defer ctx.gpa.free(root);
    return std.fs.path.join(ctx.gpa, &.{ root, version, exe_name });
}

/// Installed versions (directories holding a zig binary), gpa-owned.
pub fn listInstalled(ctx: Context) ![][]u8 {
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |v| ctx.gpa.free(v);
        list.deinit(ctx.gpa);
    }
    const root = zigRoot(ctx) catch return list.toOwnedSlice(ctx.gpa);
    defer ctx.gpa.free(root);
    var dir = Dir.cwd().openDir(ctx.io, root, .{ .iterate = true }) catch return list.toOwnedSlice(ctx.gpa);
    defer dir.close(ctx.io);
    var it = dir.iterate();
    while (try it.next(ctx.io)) |e| {
        if (e.kind != .directory or !isValidVersion(e.name)) continue;
        const exe = try std.fs.path.join(ctx.gpa, &.{ e.name, exe_name });
        defer ctx.gpa.free(exe);
        dir.access(ctx.io, exe, .{}) catch continue;
        try list.append(ctx.gpa, try ctx.gpa.dupe(u8, e.name));
    }
    return list.toOwnedSlice(ctx.gpa);
}

fn freeList(gpa: std.mem.Allocator, list: []const []u8) void {
    for (list) |v| gpa.free(v);
    gpa.free(list);
}

/// `zig-<arch>-<os>-<version>.tar.xz` (`.zip` on Windows): the tarball name
/// on ziglang.org and the mirrors, for `platform` (`<arch>-<os>`).
pub fn tarballName(gpa: std.mem.Allocator, platform: []const u8, version: []const u8) ![]u8 {
    const ext = if (std.mem.endsWith(u8, platform, "-windows")) "zip" else "tar.xz";
    return std.fmt.allocPrint(gpa, "zig-{s}-{s}.{s}", .{ platform, version, ext });
}

/// This machine's `<arch>-<os>`, the key ziglang.org uses (`aarch64-macos`,
/// `x86_64-windows`, ...). `ORIEL_ZIG_PLATFORM` overrides it (for tests).
fn platformKey(ctx: Context) []const u8 {
    if (ctx.environ.get("ORIEL_ZIG_PLATFORM")) |p| if (p.len > 0) return p;
    return @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag);
}

// ---------------------------------------------------------------------------
// Minisign
// ---------------------------------------------------------------------------

pub const MinisignError = error{
    MalformedSignature,
    MalformedPublicKey,
    UnsupportedSignatureAlgorithm,
    KeyIdMismatch,
    SignatureVerificationFailed,
    SignedFileMismatch,
};

fn decodeB64(out: []u8, text: []const u8) ![]u8 {
    const t = std.mem.trim(u8, text, " \t\r");
    const n = std.base64.standard.Decoder.calcSizeForSlice(t) catch return error.MalformedSignature;
    if (n > out.len) return error.MalformedSignature;
    std.base64.standard.Decoder.decode(out[0..n], t) catch return error.MalformedSignature;
    return out[0..n];
}

/// Verify a minisign signature file (`sig_text`) for data whose BLAKE2b-512
/// digest is `digest` (minisign's prehashed "ED" algorithm, which Zig
/// uses), against `public_key_b64`, including the global signature over
/// the trusted comment, whose `file:` field must be `file_name`.
pub fn verifyMinisign(digest: *const [64]u8, sig_text: []const u8, public_key_b64: []const u8, file_name: []const u8) MinisignError!void {
    const Ed25519 = std.crypto.sign.Ed25519;
    var pk_buf: [64]u8 = undefined;
    const pk = decodeB64(&pk_buf, public_key_b64) catch return error.MalformedPublicKey;
    if (pk.len != 42 or !std.mem.eql(u8, pk[0..2], "Ed")) return error.MalformedPublicKey;
    const public_key = Ed25519.PublicKey.fromBytes(pk[10..42].*) catch return error.MalformedPublicKey;

    var lines = std.mem.splitScalar(u8, sig_text, '\n');
    const untrusted = lines.next() orelse return error.MalformedSignature;
    if (!std.mem.startsWith(u8, untrusted, "untrusted comment:")) return error.MalformedSignature;
    var sig_buf: [96]u8 = undefined;
    const sig = try decodeB64(&sig_buf, lines.next() orelse return error.MalformedSignature);
    if (sig.len != 74) return error.MalformedSignature;
    const trusted_line = std.mem.trimEnd(u8, lines.next() orelse return error.MalformedSignature, "\r");
    const trusted_prefix = "trusted comment: ";
    if (!std.mem.startsWith(u8, trusted_line, trusted_prefix)) return error.MalformedSignature;
    const trusted = trusted_line[trusted_prefix.len..];
    var global_buf: [96]u8 = undefined;
    const global = try decodeB64(&global_buf, lines.next() orelse return error.MalformedSignature);
    if (global.len != 64) return error.MalformedSignature;

    if (!std.mem.eql(u8, sig[0..2], "ED")) return error.UnsupportedSignatureAlgorithm;
    if (!std.mem.eql(u8, sig[2..10], pk[2..10])) return error.KeyIdMismatch;

    Ed25519.Signature.fromBytes(sig[10..74].*).verify(digest, public_key) catch return error.SignatureVerificationFailed;

    // The global signature covers the signature and the trusted comment.
    var global_msg: [64 + 1024]u8 = undefined;
    if (trusted.len > 1024) return error.MalformedSignature;
    @memcpy(global_msg[0..64], sig[10..74]);
    @memcpy(global_msg[64..][0..trusted.len], trusted);
    Ed25519.Signature.fromBytes(global[0..64].*).verify(global_msg[0 .. 64 + trusted.len], public_key) catch return error.SignatureVerificationFailed;

    // Downgrade protection: the signed file name must be the one requested.
    var fields = std.mem.tokenizeAny(u8, trusted, "\t ");
    while (fields.next()) |f| {
        if (std.mem.startsWith(u8, f, "file:")) {
            if (std.mem.eql(u8, f["file:".len..], file_name)) return;
            return error.SignedFileMismatch;
        }
    }
    return error.SignedFileMismatch;
}

/// BLAKE2b-512 of a file (streamed).
fn hashFile(io: std.Io, path: []const u8) ![64]u8 {
    const file = try Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &buf);
    var h = std.crypto.hash.blake2.Blake2b512.init(.{});
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try reader.interface.readSliceShort(&chunk);
        if (n == 0) break;
        h.update(chunk[0..n]);
    }
    var out: [64]u8 = undefined;
    h.final(&out);
    return out;
}

// ---------------------------------------------------------------------------
// Archive extraction
// ---------------------------------------------------------------------------

/// Rejects entry paths a Zig release never has: absolute, `..`, drive
/// letters, backslashes. (Symlink entries are rejected by the extractors:
/// Zig releases have none, and a lexical check can't follow link chains.)
const PathGuard = struct {
    arena: std.heap.ArenaAllocator,

    fn init(gpa: std.mem.Allocator) PathGuard {
        return .{ .arena = .init(gpa) };
    }

    fn deinit(g: *PathGuard) void {
        g.arena.deinit();
    }

    /// The entry's path, normalized (no "." parts, no trailing '/').
    fn check(g: *PathGuard, name: []const u8) ![]const u8 {
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

/// Extract a `.tar.xz` into `dest` (with the checks of `PathGuard`).
fn extractTarXz(ctx: Context, archive: []const u8, dest: Dir) !void {
    const io = ctx.io;
    const file = try Dir.cwd().openFile(io, archive, .{});
    defer file.close(io);
    var read_buf: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &read_buf);
    const xz_buf = try ctx.gpa.alloc(u8, 1 << 16);
    // Owned by the decompressor once init succeeds (freed by deinit).
    var xz = std.compress.xz.Decompress.init(&reader.interface, ctx.gpa, xz_buf) catch |err| {
        ctx.gpa.free(xz_buf);
        return err;
    };
    defer xz.deinit();

    var name_buf: [Dir.max_path_bytes]u8 = undefined;
    var link_buf: [Dir.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&xz.reader, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
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
                const exec = builtin.os.tag != .windows and entry.mode & 0o100 != 0;
                const out = try dest.createFile(io, path, .{
                    .exclusive = true,
                    .permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(if (exec) 0o755 else 0o644),
                });
                defer out.close(io);
                var w = out.writer(io, &write_buf);
                try it.streamRemaining(entry, &w.interface);
                try w.interface.flush();
            },
            .sym_link => return error.UnsafeArchivePath,
        }
    }
}

/// Extract a `.zip` into `dest`, after checking every entry's path.
fn extractZip(ctx: Context, archive: []const u8, dest: Dir) !void {
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
// Download and install
// ---------------------------------------------------------------------------

/// Writer for a download: forwards to `out`, stops after `limit` bytes,
/// and counts bytes for the watchdog (another thread).
const DownloadWriter = struct {
    out: *std.Io.Writer,
    limit: usize,
    received: std.atomic.Value(u64) = .init(0),
    too_large: bool = false,
    writer: std.Io.Writer,

    fn init(out: *std.Io.Writer, limit: usize, buffer: []u8) DownloadWriter {
        return .{ .out = out, .limit = limit, .writer = .{ .buffer = buffer, .vtable = &.{ .drain = drain } } };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *DownloadWriter = @alignCast(@fieldParentPtr("writer", w));
        const incoming = w.end + std.Io.Writer.countSplat(data, splat);
        const so_far = self.received.load(.monotonic);
        if (so_far + incoming > self.limit) {
            self.too_large = true;
            return error.WriteFailed;
        }
        const n = try self.out.writeSplatHeader(w.buffered(), data, splat);
        _ = self.received.fetchAdd(n, .monotonic);
        if (n < w.end) {
            const rest = w.buffer[n..w.end];
            @memmove(w.buffer[0..rest.len], rest);
            w.end = rest.len;
            return 0;
        }
        const consumed = n - w.end;
        w.end = 0;
        return consumed;
    }
};

/// Aborts a download (shuts its socket down, which ends a blocked read on
/// every OS) when no data arrives for `stall_s` seconds or, with
/// `min_rate`, when the average rate stays below it after `rate_after_s`.
const Watchdog = struct {
    io: std.Io,
    stream: std.Io.net.Stream,
    counter: *const std.atomic.Value(u64),
    min_rate: ?u64,
    stop: std.atomic.Value(bool) = .init(false),
    aborted: std.atomic.Value(bool) = .init(false),

    const stall_s = 30;
    const rate_after_s = 20;
    const tick_ms = 250;

    fn run(w: *Watchdog) void {
        var ticks: u64 = 0;
        var idle_ticks: u64 = 0;
        var last: u64 = 0;
        while (!w.stop.load(.acquire)) {
            w.io.sleep(.fromMilliseconds(tick_ms), .awake) catch {};
            ticks += 1;
            const now = w.counter.load(.monotonic);
            idle_ticks = if (now == last) idle_ticks + 1 else 0;
            last = now;
            const seconds = ticks * tick_ms / 1000;
            const too_slow = if (w.min_rate) |r| seconds >= rate_after_s and now / @max(seconds, 1) < r else false;
            if (idle_ticks * tick_ms >= stall_s * 1000 or too_slow) {
                w.aborted.store(true, .release);
                w.stream.shutdown(w.io, .both) catch {};
                return;
            }
        }
    }
};

/// Where a redirect from `current` to `next` (absolute or relative) goes,
/// written to `out`, which must not overlap the memory `current` points into.
/// Only https targets are allowed.
fn redirectTarget(current: std.Uri, next: []const u8, out: *[2048]u8) ![]const u8 {
    if (next.len > out.len) return error.BadHttpStatus;
    const target = if (std.mem.startsWith(u8, next, "https://")) blk: {
        @memcpy(out[0..next.len], next);
        break :blk out[0..next.len];
    } else blk: {
        var aux: [2048]u8 = undefined;
        @memcpy(aux[0..next.len], next);
        var aux_slice: []u8 = &aux;
        const r = current.resolveInPlace(next.len, &aux_slice) catch return error.BadHttpStatus;
        // `r` points into `current`'s buffer and `aux`, never into `out`.
        break :blk std.fmt.bufPrint(out, "{f}", .{r}) catch return error.BadHttpStatus;
    };
    if (!std.mem.startsWith(u8, target, "https://")) return error.InsecureRedirect;
    return target;
}

/// `client.request` (DNS, TCP connect, TLS handshake) has no timeout and
/// can't be interrupted: when it takes longer than `limit_s`, report the
/// host and exit, rather than hang (no lock is held while downloading, so
/// other oriel processes are unaffected; a rerun tries other mirrors).
const ConnectDeadline = struct {
    io: std.Io,
    err: *std.Io.Writer,
    host: []const u8,
    done: std.atomic.Value(bool) = .init(false),

    const limit_s = 60;

    fn run(d: *ConnectDeadline) void {
        var ms: u64 = 0;
        while (!d.done.load(.acquire)) : (ms += 250) {
            if (ms >= limit_s * 1000) {
                d.err.print("\nerror: no response from {s} within {d} s; run the command again to try another mirror\n", .{ d.host, limit_s }) catch {};
                d.err.flush() catch {};
                std.process.exit(1);
            }
            d.io.sleep(.fromMilliseconds(250), .awake) catch {};
        }
    }
};

/// GET `url` into `out` (at most `limit` bytes), following up to 5
/// redirects, under a watchdog (see `Watchdog`; `min_rate` null: only
/// stalls abort).
fn download(ctx: Context, client: *std.http.Client, url: []const u8, out: *std.Io.Writer, limit: usize, min_rate: ?u64) !void {
    // `location_buf` holds the next URL; `current_buf` the one being
    // requested (the parsed Uri points into it, so resolving a relative
    // redirect never writes over its own input).
    var location_buf: [2048]u8 = undefined;
    var current_buf: [2048]u8 = undefined;
    if (url.len > location_buf.len) return error.UrlTooLong;
    @memcpy(location_buf[0..url.len], url);
    var location_len = url.len;
    var redirects: usize = 0;
    while (true) : (redirects += 1) {
        if (redirects > 5) return error.TooManyRedirects;
        @memcpy(current_buf[0..location_len], location_buf[0..location_len]);
        const uri = try std.Uri.parse(current_buf[0..location_len]);
        var req = blk: {
            // DNS, connect and the TLS handshake can't be interrupted.
            var deadline: ConnectDeadline = .{ .io = ctx.io, .err = ctx.err, .host = current_buf[0..location_len] };
            const deadline_thread = try std.Thread.spawn(.{}, ConnectDeadline.run, .{&deadline});
            defer {
                deadline.done.store(true, .release);
                deadline_thread.join();
            }
            break :blk try client.request(.GET, uri, .{
                .redirect_behavior = .unhandled,
                // Plain bodies only: tarballs are compressed already, and the
                // signature and mirror list are small.
                .headers = .{ .user_agent = .{ .override = "oriel-cli" }, .accept_encoding = .{ .override = "identity" } },
            });
        };
        defer req.deinit();

        var dw_buf: [16 * 1024]u8 = undefined;
        var dw: DownloadWriter = .init(out, limit, &dw_buf);
        var wd: Watchdog = .{ .io = ctx.io, .stream = req.connection.?.stream_reader.stream, .counter = &dw.received, .min_rate = min_rate };
        const thread = try std.Thread.spawn(.{}, Watchdog.run, .{&wd});
        defer {
            wd.stop.store(true, .release);
            thread.join();
            // A socket the watchdog shut down must not go back to the pool.
            if (wd.aborted.load(.acquire)) if (req.connection) |conn| {
                conn.closing = true;
            };
        }

        req.sendBodiless() catch |err| return if (wd.aborted.load(.acquire)) error.MirrorTooSlow else err;
        var response = req.receiveHead(&.{}) catch |err| return if (wd.aborted.load(.acquire)) error.MirrorTooSlow else err;
        const status = response.head.status;
        if (status.class() == .redirect) {
            const next = response.head.location orelse return error.BadHttpStatus;
            // Relative locations resolve against the current URL.
            location_len = (try redirectTarget(uri, next, &location_buf)).len;
            continue;
        }
        if (status != .ok) return error.BadHttpStatus;
        if (response.head.content_encoding != .identity) return error.UnsupportedContentEncoding;
        var transfer_buf: [64]u8 = undefined;
        const body = response.reader(&transfer_buf);
        _ = body.streamRemaining(&dw.writer) catch |err| {
            if (wd.aborted.load(.acquire)) return error.MirrorTooSlow;
            if (dw.too_large) return error.DownloadTooLarge;
            return switch (err) {
                error.ReadFailed => response.bodyErr() orelse error.ReadFailed,
                else => err,
            };
        };
        dw.writer.flush() catch return if (dw.too_large) error.DownloadTooLarge else error.WriteFailed;
        return;
    }
}

/// GET `url` into the file `dest_path`.
pub fn downloadToFile(ctx: Context, client: *std.http.Client, url: []const u8, dest_path: []const u8, limit: usize, min_rate: ?u64) !void {
    const io = ctx.io;
    const file = try Dir.cwd().createFile(io, dest_path, .{ .truncate = true });
    defer file.close(io);
    var file_buf: [64 * 1024]u8 = undefined;
    var fw = file.writerStreaming(io, &file_buf);
    try download(ctx, client, url, &fw.interface, limit, min_rate);
    try fw.end();
}

/// GET `url` into memory (at most `limit` bytes). Caller frees.
pub fn downloadMemory(ctx: Context, client: *std.http.Client, url: []const u8, limit: usize) ![]u8 {
    var body: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer body.deinit();
    try download(ctx, client, url, &body.writer, limit, null);
    return body.toOwnedSlice();
}

/// GET `url` into memory (at most `max_small_download` bytes). Caller frees.
pub fn downloadSmall(ctx: Context, client: *std.http.Client, url: []const u8) ![]u8 {
    return downloadMemory(ctx, client, url, max_small_download);
}

/// Mirror base URLs from community-mirrors.txt text (https only).
pub fn parseMirrors(gpa: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        const l = std.mem.trim(u8, line, " \t");
        if (!std.mem.startsWith(u8, l, "https://") or std.mem.indexOfAny(u8, l, " ?#") != null) continue;
        try list.append(gpa, std.mem.trimEnd(u8, l, "/"));
    }
    return list.toOwnedSlice(gpa);
}

/// The community mirror list: fetched from ziglang.org and cached in
/// `<zig root>/community-mirrors.txt`; the cached copy is used when
/// ziglang.org can't be reached. Caller frees.
fn mirrorList(ctx: Context, client: *std.http.Client, root: []const u8) ![]u8 {
    // An explicit list (e.g. a company mirror), whitespace or comma separated.
    if (ctx.environ.get("ORIEL_ZIG_MIRRORS")) |list| if (list.len > 0) {
        const text = try ctx.gpa.dupe(u8, list);
        for (text) |*ch| if (ch.* == ',' or ch.* == ' ' or ch.* == '\t') {
            ch.* = '\n';
        };
        return text;
    };
    const cache = try std.fs.path.join(ctx.gpa, &.{ root, "community-mirrors.txt" });
    defer ctx.gpa.free(cache);
    if (downloadSmall(ctx, client, mirrors_url)) |text| {
        Dir.cwd().writeFile(ctx.io, .{ .sub_path = cache, .data = text }) catch {};
        return text;
    } else |err| {
        try ctx.err.print("warning: could not fetch the mirror list ({s}); using the cached one\n", .{@errorName(err)});
        return Dir.cwd().readFileAlloc(ctx.io, cache, ctx.gpa, .limited(max_small_download)) catch ctx.gpa.dupe(u8, "");
    }
}

/// Install Zig `version` into `<zig root>/<version>` and return the path of
/// its binary (gpa-owned). Safe to run concurrently: each installer
/// downloads into its own staging directory, and the final check and rename
/// happen under a lock file (not held during the network phase, so a hung
/// mirror never blocks other oriel processes); an existing install wins.
/// Errors are reported on stderr.
pub fn install(ctx: Context, version: []const u8) ![]u8 {
    return installInner(ctx, version) catch |err| {
        switch (err) {
            // Already explained where they happen.
            error.InvalidVersion, error.DownloadFailed => {},
            else => ctx.err.print("error: installing Zig {s}: {s}\n", .{ version, @errorName(err) }) catch {},
        }
        return err;
    };
}

fn installInner(ctx: Context, version: []const u8) ![]u8 {
    const io = ctx.io;
    const gpa = ctx.gpa;
    if (!isValidVersion(version)) {
        try ctx.err.print("error: '{s}' is not a Zig release version (e.g. 0.16.0)\n", .{version});
        return error.InvalidVersion;
    }
    const root = try zigRoot(ctx);
    defer gpa.free(root);
    try Dir.cwd().createDirPath(io, root);
    const zig_path = try managedZigPath(ctx, version);
    errdefer gpa.free(zig_path);

    if (Dir.cwd().access(io, zig_path, .{})) |_| return zig_path else |_| {}

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const platform = platformKey(ctx);
    const name = try tarballName(arena, platform, version);
    const final_dir = try std.fs.path.join(arena, &.{ root, version });

    var rand: u64 = undefined;
    io.random(std.mem.asBytes(&rand));
    const staging = try std.fs.path.join(arena, &.{ root, try std.fmt.allocPrint(arena, ".staging-{x}", .{rand}) });
    try Dir.cwd().createDirPath(io, staging);
    defer Dir.cwd().deleteTree(io, staging) catch {};
    const archive = try std.fs.path.join(arena, &.{ staging, name });

    try ctx.err.print("Installing Zig {s} ({s}) into {s}\n", .{ version, name, final_dir });
    ctx.flush();

    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();

    // Randomly ordered community mirrors, then ziglang.org.
    const mirror_text = try mirrorList(ctx, &client, root);
    defer gpa.free(mirror_text);
    const mirrors = try parseMirrors(arena, mirror_text);
    var seed: u64 = undefined;
    io.random(std.mem.asBytes(&seed));
    var prng = std.Random.DefaultPrng.init(seed);
    prng.random().shuffle([]const u8, mirrors);
    var bases: std.ArrayList([]const u8) = .empty;
    try bases.appendSlice(arena, mirrors);
    try bases.append(arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ origin_base, version }));

    var verified = false;
    for (bases.items) |base| {
        const url = try std.fmt.allocPrint(arena, "{s}/{s}?source={s}", .{ base, name, source_param });
        const sig_url = try std.fmt.allocPrint(arena, "{s}/{s}.minisig?source={s}", .{ base, name, source_param });
        try ctx.err.print("  downloading {s}\n", .{url});
        ctx.flush();
        // A slow mirror is skipped (the next one is usually fast); the last
        // source, ziglang.org, is only abandoned when it stalls.
        const is_last = base.ptr == bases.items[bases.items.len - 1].ptr;
        downloadToFile(ctx, &client, url, archive, max_download, if (is_last) null else min_mirror_rate) catch |err| {
            try ctx.err.print("  {s}: {s}, trying the next source\n", .{ base, @errorName(err) });
            continue;
        };
        const sig = downloadSmall(ctx, &client, sig_url) catch |err| {
            try ctx.err.print("  {s}: signature {s}, trying the next source\n", .{ base, @errorName(err) });
            continue;
        };
        defer gpa.free(sig);
        const digest = hashFile(io, archive) catch |err| {
            try ctx.err.print("  {s}: reading the download: {s}, trying the next source\n", .{ base, @errorName(err) });
            continue;
        };
        // Never skipped: a tarball is only trusted once this passes.
        verifyMinisign(&digest, sig, zsf_public_key, name) catch |err| {
            try ctx.err.print("  {s}: minisign verification failed ({s}), trying the next source\n", .{ base, @errorName(err) });
            continue;
        };
        try ctx.err.print("  minisign signature verified (Zig Software Foundation key)\n", .{});
        ctx.flush();
        verified = true;
        break;
    }
    if (!verified) {
        try ctx.err.print("error: could not download a verified {s} from any mirror or ziglang.org\n", .{name});
        return error.DownloadFailed;
    }

    const extract_dir = try std.fs.path.join(arena, &.{ staging, "x" });
    try Dir.cwd().createDirPath(io, extract_dir);
    {
        var dest = try Dir.cwd().openDir(io, extract_dir, .{});
        defer dest.close(io);
        if (std.mem.endsWith(u8, name, ".zip")) try extractZip(ctx, archive, dest) else try extractTarXz(ctx, archive, dest);
    }

    // The archive holds one top-level directory with the zig binary.
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
    const platform_exe = if (std.mem.endsWith(u8, platform, "-windows")) "zig.exe" else "zig";
    const top_exe = try std.fs.path.join(arena, &.{ top_dir, platform_exe });
    Dir.cwd().access(io, top_exe, .{}) catch return error.UnexpectedArchiveLayout;

    // The final step, one installer at a time: another one may have
    // finished meanwhile (then its install is used), and a directory left
    // without a zig binary (an interrupted install) is replaced.
    const lock_path = try std.fs.path.join(arena, &.{ root, ".install.lock" });
    const lock = try Dir.cwd().createFile(io, lock_path, .{ .truncate = false, .lock = .exclusive });
    defer lock.close(io);
    if (Dir.cwd().access(io, zig_path, .{})) |_| return zig_path else |_| {}
    Dir.cwd().deleteTree(io, final_dir) catch {};
    // Windows: a scanner may still hold the new files open for a moment.
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        Dir.cwd().rename(top_dir, Dir.cwd(), final_dir, io) catch |err| {
            if (builtin.os.tag != .windows or attempt >= 5) return err;
            io.sleep(.fromMilliseconds(200), .awake) catch {};
            continue;
        };
        break;
    }
    try ctx.err.print("Installed Zig {s}: {s}\n", .{ version, zig_path });
    ctx.flush();
    return zig_path;
}

/// Remove `<zig root>/<version>` (under the install lock).
pub fn uninstall(ctx: Context, version: []const u8) !bool {
    if (!isValidVersion(version)) return error.InvalidVersion;
    const root = try zigRoot(ctx);
    defer ctx.gpa.free(root);
    const dir = try std.fs.path.join(ctx.gpa, &.{ root, version });
    defer ctx.gpa.free(dir);
    Dir.cwd().access(ctx.io, dir, .{}) catch return false;
    const lock_path = try std.fs.path.join(ctx.gpa, &.{ root, ".install.lock" });
    defer ctx.gpa.free(lock_path);
    const lock = try Dir.cwd().createFile(ctx.io, lock_path, .{ .truncate = false, .lock = .exclusive });
    defer lock.close(ctx.io);
    try Dir.cwd().deleteTree(ctx.io, dir);
    return true;
}

// ---------------------------------------------------------------------------
// `oriel zig`
// ---------------------------------------------------------------------------

pub fn run(ctx: Context, cmd: Command) !u8 {
    switch (cmd.action) {
        .install => {
            const version = if (cmd.version) |v| try ctx.gpa.dupe(u8, v) else try requiredHere(ctx);
            defer ctx.gpa.free(version);
            const path = install(ctx, version) catch return 1;
            defer ctx.gpa.free(path);
            try ctx.out.print("{s}\n", .{path});
            return 0;
        },
        .uninstall => {
            const version = cmd.version orelse {
                try ctx.err.writeAll("error: `oriel zig uninstall` needs a version (see `oriel zig list`)\n");
                return 2;
            };
            if (try uninstall(ctx, version)) {
                try ctx.out.print("Removed Zig {s}\n", .{version});
                return 0;
            }
            const root = try zigRoot(ctx);
            defer ctx.gpa.free(root);
            try ctx.err.print("error: Zig {s} is not installed in {s}\n", .{ version, root });
            return 1;
        },
        .list => {
            const installed = try listInstalled(ctx);
            defer freeList(ctx.gpa, installed);
            const root = try zigRoot(ctx);
            defer ctx.gpa.free(root);
            try ctx.out.print("Managed ({s}):\n", .{root});
            if (installed.len == 0) try ctx.out.writeAll("  (none)\n");
            for (installed) |v| try ctx.out.print("  {s}\n", .{v});
            if (try ctx.findExecutable("zig")) |p| {
                defer ctx.gpa.free(p);
                const v = zigVersion(ctx, p);
                defer if (v) |x| ctx.gpa.free(x);
                try ctx.out.print("PATH: {s} ({s})\n", .{ p, v orelse "does not run" });
            } else try ctx.out.writeAll("PATH: no zig\n");
            return 0;
        },
        .which => {
            const want = if (cmd.version) |v| try ctx.gpa.dupe(u8, v) else try requiredHere(ctx);
            defer ctx.gpa.free(want);
            const p = plan(ctx, want) catch |err| {
                switch (err) {
                    error.OrielZigMismatch => try ctx.err.print("error: ORIEL_ZIG={s} is not Zig {s}\n", .{ ctx.environ.get("ORIEL_ZIG") orelse "", want }),
                    else => try ctx.err.print("error: {s}\n", .{@errorName(err)}),
                }
                return 1;
            };
            defer p.deinit(ctx.gpa);
            switch (p.choice.source) {
                .env => try ctx.out.print("{s}\t(Zig {s}, from ORIEL_ZIG)\n", .{ p.env_zig.?, p.env_version.? }),
                .path => try ctx.out.print("{s}\t(Zig {s}, from PATH)\n", .{ p.path_zig.?, p.path_version.? }),
                .managed => {
                    const path = try managedZigPath(ctx, p.choice.managed_version.?);
                    defer ctx.gpa.free(path);
                    try ctx.out.print("{s}\t(Zig {s}, managed)\n", .{ path, p.choice.managed_version.? });
                },
                .install => {
                    const path = try managedZigPath(ctx, want);
                    defer ctx.gpa.free(path);
                    try ctx.out.print("{s}\t(Zig {s}, not installed yet: installed on first use, or `oriel zig install`)\n", .{ path, want });
                    return 1;
                },
            }
            return 0;
        },
    }
}

// ---------------------------------------------------------------------------
// Tests (no network)
// ---------------------------------------------------------------------------

test versionMatches {
    try std.testing.expect(versionMatches("0.16.0", "0.16.0"));
    try std.testing.expect(versionMatches("0.16.2", "0.16.0"));
    try std.testing.expect(versionMatches("0.16.1-dev.12+abc", "0.16.0"));
    try std.testing.expect(!versionMatches("0.16.0-dev.99+abc", "0.16.0")); // before the release
    try std.testing.expect(!versionMatches("0.15.2", "0.16.0"));
    try std.testing.expect(!versionMatches("0.17.0", "0.16.0"));
    try std.testing.expect(!versionMatches("0.16.0", "0.16.1"));
    try std.testing.expect(!versionMatches("garbage", "0.16.0"));
}

test requiredFromZon {
    const zon =
        \\.{
        \\    .name = .app,
        \\    .minimum_zig_version = "0.16.0",
        \\}
    ;
    try std.testing.expectEqualStrings("0.16.0", requiredFromZon(zon).?);
    try std.testing.expectEqual(@as(?[]const u8, null), requiredFromZon(".{ .name = .app }"));
    try std.testing.expectEqual(@as(?[]const u8, null), requiredFromZon(".{ .minimum_zig_version = \"../x\" }"));
}

test "the templates' minimum Zig is default_version" {
    const zon = @embedFile("templates/common/build.zig.zon");
    try std.testing.expectEqualStrings(default_version, requiredFromZon(zon).?);
}

test "choose: resolution order" {
    const t = std.testing;
    const none: []const []const u8 = &.{};
    // 1. ORIEL_ZIG wins, and must match.
    try t.expectEqual(Source.env, (try choose("0.16.0", true, "0.16.0", "0.16.0", none)).source);
    try t.expectError(error.OrielZigMismatch, choose("0.16.0", true, "0.15.2", "0.16.0", none));
    try t.expectError(error.OrielZigMismatch, choose("0.16.0", true, null, null, none));
    // 2. A matching PATH zig.
    try t.expectEqual(Source.path, (try choose("0.16.0", false, null, "0.16.0", &.{"0.16.0"})).source);
    // 3. A wrong PATH zig is skipped silently for a managed one.
    const m = try choose("0.16.0", false, null, "0.15.2", &.{ "0.15.2", "0.16.0" });
    try t.expectEqual(Source.managed, m.source);
    try t.expectEqualStrings("0.16.0", m.managed_version.?);
    // ... the newest compatible one when the exact one isn't there.
    try t.expectEqualStrings("0.16.3", (try choose("0.16.0", false, null, null, &.{ "0.16.1", "0.16.3", "0.17.0" })).managed_version.?);
    // 4. Nothing matching: install.
    try t.expectEqual(Source.install, (try choose("0.16.0", false, null, "0.15.2", &.{"0.15.2"})).source);
    try t.expectEqual(Source.install, (try choose("0.16.0", false, null, null, none)).source);
}

test tarballName {
    const a = std.testing.allocator;
    const n1 = try tarballName(a, "aarch64-macos", "0.16.0");
    defer a.free(n1);
    try std.testing.expectEqualStrings("zig-aarch64-macos-0.16.0.tar.xz", n1);
    const n2 = try tarballName(a, "x86_64-windows", "0.16.0");
    defer a.free(n2);
    try std.testing.expectEqualStrings("zig-x86_64-windows-0.16.0.zip", n2);
}

test parseMirrors {
    const a = std.testing.allocator;
    const m = try parseMirrors(a, "https://a.example/zig\nhttp://insecure.example\nhttps://b.example/\n\nhttps://c.example/x?y=1\n");
    defer a.free(m);
    try std.testing.expectEqual(@as(usize, 2), m.len);
    try std.testing.expectEqualStrings("https://a.example/zig", m[0]);
    try std.testing.expectEqualStrings("https://b.example", m[1]);
}

/// A minisign public key and signature file made with a test key pair, in
/// the format `minisign -S -H` writes.
fn testSignature(a: std.mem.Allocator, data: []const u8, trusted_comment: []const u8, out_pk: *[56]u8) ![]u8 {
    const Ed25519 = std.crypto.sign.Ed25519;
    const kp = Ed25519.KeyPair.generateDeterministic([_]u8{7} ** 32) catch unreachable;
    const key_id = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var pk_raw: [42]u8 = undefined;
    @memcpy(pk_raw[0..2], "Ed");
    @memcpy(pk_raw[2..10], &key_id);
    @memcpy(pk_raw[10..42], &kp.public_key.toBytes());
    _ = std.base64.standard.Encoder.encode(out_pk, &pk_raw);

    var digest: [64]u8 = undefined;
    std.crypto.hash.blake2.Blake2b512.hash(data, &digest, .{});
    const sig = try kp.sign(&digest, null);
    var sig_raw: [74]u8 = undefined;
    @memcpy(sig_raw[0..2], "ED");
    @memcpy(sig_raw[2..10], &key_id);
    @memcpy(sig_raw[10..74], &sig.toBytes());
    var global_msg: std.ArrayList(u8) = .empty;
    defer global_msg.deinit(a);
    try global_msg.appendSlice(a, &sig.toBytes());
    try global_msg.appendSlice(a, trusted_comment);
    const global = try kp.sign(global_msg.items, null);

    var sig_b64: [std.base64.standard.Encoder.calcSize(74)]u8 = undefined;
    var global_b64: [std.base64.standard.Encoder.calcSize(64)]u8 = undefined;
    return std.fmt.allocPrint(a, "untrusted comment: signature from minisign secret key\n{s}\ntrusted comment: {s}\n{s}\n", .{
        std.base64.standard.Encoder.encode(&sig_b64, &sig_raw),
        trusted_comment,
        std.base64.standard.Encoder.encode(&global_b64, &global.toBytes()),
    });
}

test verifyMinisign {
    const a = std.testing.allocator;
    const data = "zig tarball bytes";
    const name = "zig-aarch64-macos-0.16.0.tar.xz";
    var pk: [56]u8 = undefined;
    const sig = try testSignature(a, data, "timestamp:1776173999\tfile:" ++ name ++ "\thashed", &pk);
    defer a.free(sig);
    var digest: [64]u8 = undefined;
    std.crypto.hash.blake2.Blake2b512.hash(data, &digest, .{});

    try verifyMinisign(&digest, sig, &pk, name);
    // Another file's signature (a downgrade by substitution).
    try std.testing.expectError(error.SignedFileMismatch, verifyMinisign(&digest, sig, &pk, "zig-aarch64-macos-0.15.2.tar.xz"));
    // Tampered data.
    var bad = digest;
    bad[0] ^= 1;
    try std.testing.expectError(error.SignatureVerificationFailed, verifyMinisign(&bad, sig, &pk, name));
    // The real ZSF key doesn't verify a test signature (key id differs).
    try std.testing.expectError(error.KeyIdMismatch, verifyMinisign(&digest, sig, zsf_public_key, name));
    // A tampered trusted comment breaks the global signature.
    const edited = try std.mem.replaceOwned(u8, a, sig, "timestamp:1776173999", "timestamp:1776173998");
    defer a.free(edited);
    try std.testing.expectError(error.SignatureVerificationFailed, verifyMinisign(&digest, edited, &pk, name));
    // A trusted comment without a file field.
    const no_file = try testSignature(a, data, "timestamp:1", &pk);
    defer a.free(no_file);
    try std.testing.expectError(error.SignedFileMismatch, verifyMinisign(&digest, no_file, &pk, name));
    try std.testing.expectError(error.MalformedSignature, verifyMinisign(&digest, "garbage", &pk, name));
}

test redirectTarget {
    // The reviewer's case: an absolute redirect, then a relative one.
    var current_buf: [2048]u8 = undefined;
    var out: [2048]u8 = undefined;
    const first = try redirectTarget(try std.Uri.parse("https://mirror.example/zig/zig-a.tar.xz"), "https://cdn.example/a/b.tar.xz", &out);
    @memcpy(current_buf[0..first.len], first);
    const second = try redirectTarget(try std.Uri.parse(current_buf[0..first.len]), "c.tar.xz", &out);
    try std.testing.expectEqualStrings("https://cdn.example/a/c.tar.xz", second);
    @memcpy(current_buf[0..second.len], second);
    try std.testing.expectEqualStrings("https://cdn.example/x/y", try redirectTarget(try std.Uri.parse(current_buf[0..second.len]), "/x/y", &out));
    try std.testing.expectError(error.InsecureRedirect, redirectTarget(try std.Uri.parse("https://a.example/x"), "http://b.example/y", &out));
    // Scheme-relative: stays https.
    try std.testing.expectEqualStrings("https://b.example/y", try redirectTarget(try std.Uri.parse("https://a.example/x"), "//b.example/y", &out));
}

test "PathGuard rejects unsafe archive entries" {
    var g: PathGuard = .init(std.testing.allocator);
    defer g.deinit();
    try std.testing.expectEqualStrings("zig-x/lib/std", try g.check("./zig-x/lib/std/"));
    try std.testing.expectError(error.UnsafeArchivePath, g.check("/etc/passwd"));
    try std.testing.expectError(error.UnsafeArchivePath, g.check("zig-x/../../x"));
    try std.testing.expectError(error.UnsafeArchivePath, g.check("zig-x\\..\\x"));
    try std.testing.expectError(error.UnsafeArchivePath, g.check("C:/x"));
    try std.testing.expectError(error.UnsafeArchivePath, g.check("\\\\server\\share\\x"));
    try std.testing.expectError(error.UnsafeArchivePath, g.check("./"));
}

test "orielHome honors ORIEL_HOME" {
    const a = std.testing.allocator;
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    try env.put("ORIEL_HOME", "/tmp/oh");
    const h = try orielHome(a, &env);
    defer a.free(h);
    try std.testing.expectEqualStrings("/tmp/oh", h);
}
