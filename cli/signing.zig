//! `oriel signing`: a self-signed code-signing certificate for macOS apps.
//!
//!     oriel signing create [--name "My App"] [--out <dir>] [--days 3650] [--force]
//!     oriel signing import <file.p12> [--password-env VAR] [--keychain <name>]
//!     oriel signing show [<file.p12>]
//!
//! Without an Apple Developer ID, macOS apps are signed ad-hoc: macOS then
//! identifies an app by the hash of that exact build, so every update looks
//! like a new app and the user's grants (Accessibility, microphone, screen
//! recording) stop applying. Signed with the same certificate every time,
//! even a self-signed one, the app keeps its identity (its designated
//! requirement names the certificate) and the grants survive updates.
//! Gatekeeper still asks once on first launch; only a Developer ID with
//! notarization removes that.
//!
//! `create` (any OS; needs `openssl`) writes `<dir>/<name>-codesign.p12` and
//! its password (`.p12.password`), both 0600, in `~/.config/oriel/keys` by
//! default, and prints the SHA-1 to sign with. The private key is never
//! printed. `import` (macOS) puts the certificate into a keychain codesign
//! can use without prompts: a new unlocked keychain added to the search list
//! (for CI), or `--keychain login`. Then:
//!
//!     oriel package -Dmacos-sign-identity=<SHA-1>

const std = @import("std");
const builtin = @import("builtin");
const Context = @import("Context.zig");

pub const Action = enum { create, import, show };

pub const Command = struct {
    pub const summary = "Self-signed code-signing certificate for macOS apps (keeps permissions across updates)";
    pub const positionals = .{ "action", "file" };
    pub const help = .{
        .action = "create | import | show",
        .file = "The .p12 (import, show)",
        .name = "Certificate name (create; default: the app name from build.zig)",
        .out = "Directory for the .p12 (create; default ~/.config/oriel/keys)",
        .days = "Validity in days (create; default 3650)",
        .force = "Overwrite an existing certificate (create)",
        .password_env = "Environment variable with the .p12 password (import; default: <file>.password)",
        .keychain = "Keychain to import into (import; default: a new oriel-signing keychain for CI; 'login' for yours)",
    };
    pub const values = .{ .name = "name", .out = "dir", .days = "n", .password_env = "VAR", .keychain = "name" };
    pub const details =
        \\create     Make a self-signed code-signing certificate (.p12 and its password, 0600)
        \\import     macOS: import a .p12 so codesign can use it (CI: a new unlocked keychain)
        \\show       Print a certificate's name, SHA-1 and expiry
        \\
        \\Then sign with: oriel package -Dmacos-sign-identity=<SHA-1>
    ;

    action: Action = .show,
    file: ?[]const u8 = null,
    name: ?[]const u8 = null,
    out: ?[]const u8 = null,
    days: ?[]const u8 = null,
    force: bool = false,
    password_env: ?[]const u8 = null,
    keychain: ?[]const u8 = null,
};

pub fn run(ctx: Context, cmd: Command) !u8 {
    return switch (cmd.action) {
        .create => create(ctx, cmd),
        .import => import(ctx, cmd),
        .show => show(ctx, cmd),
    };
}

// ---- create -----------------------------------------------------------------------------

fn create(ctx: Context, cmd: Command) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(ctx.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const openssl = try requireOpenssl(ctx, arena) orelse return 1;
    const name = cmd.name orelse appNameFromBuildZig(ctx, arena) orelse {
        try ctx.err.writeAll("error: no --name, and no .name found in ./build.zig\n");
        return 2;
    };
    if (!validName(name)) {
        try ctx.err.print("error: invalid name \"{s}\": use letters, digits, spaces, '.', '-' or '_'\n", .{name});
        return 2;
    }
    const days = cmd.days orelse "3650";
    if (days.len == 0 or days.len > 5 or !allDigits(days)) {
        try ctx.err.print("error: --days must be a number of days, got \"{s}\"\n", .{days});
        return 2;
    }

    const dir = cmd.out orelse try defaultKeysDir(arena, ctx.environ);
    const slug = try slugify(arena, name);
    const p12_path = try std.fs.path.join(arena, &.{ dir, try std.fmt.allocPrint(arena, "{s}-codesign.p12", .{slug}) });
    const pw_path = try std.fmt.allocPrint(arena, "{s}.password", .{p12_path});
    const cwd = std.Io.Dir.cwd();
    if (!cmd.force and exists(ctx.io, p12_path)) {
        try ctx.err.print("error: {s} exists; keep using it (a new certificate is a new identity to macOS), or pass --force\n", .{p12_path});
        return 1;
    }
    try cwd.createDirPath(ctx.io, dir);
    if (builtin.os.tag != .windows) cwd.setFilePermissions(ctx.io, dir, .fromMode(0o700), .{}) catch {};

    // Work in a private temporary directory next to the output: the key
    // never lands anywhere world-readable.
    var rnd: [8]u8 = undefined;
    ctx.io.random(&rnd);
    const tmp = try std.fs.path.join(arena, &.{ dir, try std.fmt.allocPrint(arena, ".signing-{x}", .{rnd}) });
    try cwd.createDirPath(ctx.io, tmp);
    defer cwd.deleteTree(ctx.io, tmp) catch {};
    if (builtin.os.tag != .windows) cwd.setFilePermissions(ctx.io, tmp, .fromMode(0o700), .{}) catch {};

    const config = try std.fs.path.join(arena, &.{ tmp, "req.cnf" });
    try cwd.writeFile(ctx.io, .{ .sub_path = config, .data = try std.fmt.allocPrint(arena,
        \\[req]
        \\distinguished_name = dn
        \\x509_extensions = ext
        \\prompt = no
        \\[dn]
        \\CN = {s}
        \\[ext]
        \\basicConstraints = critical, CA:false
        \\keyUsage = critical, digitalSignature
        \\extendedKeyUsage = critical, codeSigning
        \\subjectKeyIdentifier = hash
        \\
    , .{name}) });
    const key = try std.fs.path.join(arena, &.{ tmp, "key.pem" });
    const cert = try std.fs.path.join(arena, &.{ tmp, "cert.pem" });
    if (!try quiet(ctx, &.{ openssl, "req", "-x509", "-newkey", "rsa:3072", "-nodes", "-sha256", "-days", days, "-config", config, "-keyout", key, "-out", cert })) return 1;

    // The password: 32 random hex characters, passed to openssl in a file.
    var pw_bytes: [16]u8 = undefined;
    ctx.io.random(&pw_bytes);
    const password = try std.fmt.allocPrint(arena, "{x}", .{pw_bytes});
    const pass_file = try std.fs.path.join(arena, &.{ tmp, "pass" });
    try writePrivate(ctx.io, pass_file, password);
    const tmp_p12 = try std.fs.path.join(arena, &.{ tmp, "out.p12" });
    // SHA1-3DES and a SHA-1 MAC: what macOS `security import` reads
    // (OpenSSL 3's default AES/PBKDF2 PKCS#12 files are refused).
    if (!try quiet(ctx, &.{ openssl, "pkcs12", "-export", "-inkey", key, "-in", cert, "-name", name, "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1", "-passout", try std.fmt.allocPrint(arena, "file:{s}", .{pass_file}), "-out", tmp_p12 })) return 1;

    const p12 = try cwd.readFileAlloc(ctx.io, tmp_p12, arena, .limited(1 << 20));
    try writePrivate(ctx.io, p12_path, p12);
    try writePrivate(ctx.io, pw_path, password);

    const info = try certInfo(ctx, arena, openssl, cert) orelse return 1;
    try ctx.out.print(
        \\Created a self-signed code-signing certificate "{s}" (valid {s} days):
        \\  {s}
        \\  {s}   (its password)
        \\SHA-1: {s}
        \\
        \\Keep both files private and reuse them for every release: a new certificate
        \\is a new identity to macOS. Sign with:
        \\  oriel package -Dmacos-sign-identity={s}
        \\after `oriel signing import` on the Mac. For CI, store the .p12 (base64) and
        \\its password as secrets, e.g.
        \\  base64 < {s} | gh secret set MACOS_CERT_P12
        \\  gh secret set MACOS_CERT_PASSWORD < {s}
        \\
    , .{ name, days, p12_path, pw_path, info.sha1, info.sha1, p12_path, pw_path });
    return 0;
}

// ---- import -----------------------------------------------------------------------------

const ci_keychain = "oriel-signing.keychain-db";

fn import(ctx: Context, cmd: Command) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(ctx.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (builtin.os.tag != .macos) {
        try ctx.err.writeAll("error: `oriel signing import` runs on macOS (codesign's keychains)\n");
        return 1;
    }
    const file = cmd.file orelse {
        try ctx.err.writeAll("error: which .p12? oriel signing import <file.p12>\n");
        return 2;
    };
    const password = try readPassword(ctx, arena, cmd, file) orelse return 1;

    const login = if (cmd.keychain) |k| std.mem.eql(u8, k, "login") else false;
    const keychain = if (cmd.keychain) |k| (if (login) "login.keychain-db" else k) else ci_keychain;
    if (!login) {
        // A keychain of its own, unlocked with a random password that is
        // thrown away: nothing prompts, and nothing else lives in it.
        var rnd: [16]u8 = undefined;
        ctx.io.random(&rnd);
        const kc_pass = try std.fmt.allocPrint(arena, "{x}", .{rnd});
        _ = try quietStatus(ctx, &.{ "/usr/bin/security", "delete-keychain", keychain });
        if (!try quiet(ctx, &.{ "/usr/bin/security", "create-keychain", "-p", kc_pass, keychain })) return 1;
        if (!try quiet(ctx, &.{ "/usr/bin/security", "unlock-keychain", "-p", kc_pass, keychain })) return 1;
        // No auto-lock timeout.
        if (!try quiet(ctx, &.{ "/usr/bin/security", "set-keychain-settings", keychain })) return 1;
        if (!try quiet(ctx, &.{ "/usr/bin/security", "import", file, "-k", keychain, "-P", password, "-T", "/usr/bin/codesign" })) return 1;
        // Let codesign use the key without a GUI prompt.
        if (!try quiet(ctx, &.{ "/usr/bin/security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", kc_pass, keychain })) return 1;
        try addToSearchList(ctx, arena, keychain);
    } else {
        if (!try quiet(ctx, &.{ "/usr/bin/security", "import", file, "-k", keychain, "-P", password, "-T", "/usr/bin/codesign" })) return 1;
    }

    const openssl = try requireOpenssl(ctx, arena) orelse return 1;
    const info = try p12Info(ctx, arena, openssl, file, password) orelse return 1;
    try ctx.out.print(
        \\Imported "{s}" into {s}.
        \\Sign with: oriel package -Dmacos-sign-identity={s}
        \\
    , .{ info.name, keychain, info.sha1 });
    return 0;
}

/// Put `keychain` first in the user's keychain search list, keeping the rest.
fn addToSearchList(ctx: Context, arena: std.mem.Allocator, keychain: []const u8) !void {
    const got = ctx.capture(&.{ "/usr/bin/security", "list-keychains", "-d", "user" }, 10_000) orelse return error.SecurityFailed;
    defer got.deinit(ctx.gpa);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "/usr/bin/security", "list-keychains", "-d", "user", "-s", keychain });
    var lines = std.mem.tokenizeAny(u8, got.stdout, "\n");
    while (lines.next()) |line| {
        const path = std.mem.trim(u8, line, " \t\"");
        if (path.len == 0 or std.mem.endsWith(u8, path, ci_keychain)) continue;
        try argv.append(arena, try arena.dupe(u8, path));
    }
    if (!try quiet(ctx, argv.items)) return error.SecurityFailed;
}

// ---- show -------------------------------------------------------------------------------

fn show(ctx: Context, cmd: Command) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(ctx.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const openssl = try requireOpenssl(ctx, arena) orelse return 1;
    const file = cmd.file orelse {
        // List the certificates in the keys directory.
        const dir = try defaultKeysDir(arena, ctx.environ);
        var d = std.Io.Dir.cwd().openDir(ctx.io, dir, .{ .iterate = true }) catch {
            try ctx.out.print("No certificates in {s} (oriel signing create).\n", .{dir});
            return 0;
        };
        defer d.close(ctx.io);
        var it = d.iterate();
        var any = false;
        while (try it.next(ctx.io)) |entry| {
            if (!std.mem.endsWith(u8, entry.name, "-codesign.p12")) continue;
            any = true;
            const path = try std.fs.path.join(arena, &.{ dir, entry.name });
            try showOne(ctx, arena, openssl, cmd, path);
        }
        if (!any) try ctx.out.print("No certificates in {s} (oriel signing create).\n", .{dir});
        return 0;
    };
    try showOne(ctx, arena, openssl, cmd, file);
    return 0;
}

fn showOne(ctx: Context, arena: std.mem.Allocator, openssl: []const u8, cmd: Command, file: []const u8) !void {
    const password = try readPassword(ctx, arena, cmd, file) orelse return;
    const info = try p12Info(ctx, arena, openssl, file, password) orelse return;
    try ctx.out.print("{s}\n  name: {s}\n  SHA-1: {s}\n  expires: {s}\n", .{ file, info.name, info.sha1, info.expires });
}

// ---- helpers ----------------------------------------------------------------------------

const Info = struct { name: []const u8, sha1: []const u8, expires: []const u8 };

/// Name, SHA-1 and expiry of a PEM certificate file.
fn certInfo(ctx: Context, arena: std.mem.Allocator, openssl: []const u8, cert_pem: []const u8) !?Info {
    const got = ctx.capture(&.{ openssl, "x509", "-in", cert_pem, "-noout", "-subject", "-fingerprint", "-sha1", "-enddate", "-nameopt", "multiline" }, 20_000) orelse {
        try ctx.err.writeAll("error: openssl x509 failed\n");
        return null;
    };
    defer got.deinit(ctx.gpa);
    if (got.code != 0) {
        try ctx.err.print("error: openssl x509: {s}\n", .{std.mem.trim(u8, got.stderr, " \n")});
        return null;
    }
    return try parseInfo(arena, got.stdout);
}

/// Name, SHA-1 and expiry of the certificate in a .p12.
fn p12Info(ctx: Context, arena: std.mem.Allocator, openssl: []const u8, p12: []const u8, password: []const u8) !?Info {
    // The password goes through the environment, not argv (visible in ps).
    var env = try ctx.environ.clone(arena);
    try env.put("ORIEL_P12_PASSWORD", password);
    const pem = try std.fmt.allocPrint(arena, "{s}.pem-{d}", .{ p12, std.Io.Clock.real.now(ctx.io).toNanoseconds() });
    const cwd = std.Io.Dir.cwd();
    defer cwd.deleteFile(ctx.io, pem) catch {};
    var child = try std.process.spawn(ctx.io, .{
        .argv = &.{ openssl, "pkcs12", "-in", p12, "-nokeys", "-clcerts", "-passin", "env:ORIEL_P12_PASSWORD", "-out", pem },
        .environ_map = &env,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(ctx.io);
    if (Context.exitCode(term) != 0) {
        // OpenSSL 3 reads SHA1-3DES files only with the legacy provider in
        // some builds; retry with it.
        var retry = try std.process.spawn(ctx.io, .{
            .argv = &.{ openssl, "pkcs12", "-legacy", "-in", p12, "-nokeys", "-clcerts", "-passin", "env:ORIEL_P12_PASSWORD", "-out", pem },
            .environ_map = &env,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        if (Context.exitCode(try retry.wait(ctx.io)) != 0) {
            try ctx.err.print("error: can't read {s} (wrong password?)\n", .{p12});
            return null;
        }
    }
    return certInfo(ctx, arena, openssl, pem);
}

fn parseInfo(arena: std.mem.Allocator, text: []const u8) !Info {
    var info: Info = .{ .name = "", .sha1 = "", .expires = "" };
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "commonName")) {
            if (std.mem.indexOfScalar(u8, line, '=')) |eq| info.name = try arena.dupe(u8, std.mem.trim(u8, line[eq + 1 ..], " "));
        } else if (std.ascii.startsWithIgnoreCase(line, "sha1 fingerprint=")) {
            const hex = line["sha1 fingerprint=".len..];
            var out: std.ArrayList(u8) = .empty;
            for (hex) |c| if (c != ':') try out.append(arena, std.ascii.toUpper(c));
            info.sha1 = out.items;
        } else if (std.mem.startsWith(u8, line, "notAfter=")) {
            info.expires = try arena.dupe(u8, line["notAfter=".len..]);
        }
    }
    return info;
}

fn readPassword(ctx: Context, arena: std.mem.Allocator, cmd: Command, file: []const u8) !?[]const u8 {
    if (cmd.password_env) |name| {
        const v = ctx.environ.get(name) orelse {
            try ctx.err.print("error: ${s} is not set\n", .{name});
            return null;
        };
        return try arena.dupe(u8, std.mem.trim(u8, v, " \r\n"));
    }
    const pw_path = try std.fmt.allocPrint(arena, "{s}.password", .{file});
    const data = std.Io.Dir.cwd().readFileAlloc(ctx.io, pw_path, arena, .limited(4096)) catch {
        try ctx.err.print("error: no password: {s} not found (or pass --password-env VAR)\n", .{pw_path});
        return null;
    };
    return std.mem.trim(u8, data, " \r\n");
}

/// The openssl on PATH (in `arena`).
fn requireOpenssl(ctx: Context, arena: std.mem.Allocator) !?[]const u8 {
    if (try ctx.findExecutable("openssl")) |p| {
        defer ctx.gpa.free(p);
        return try arena.dupe(u8, p);
    }
    try ctx.err.writeAll("error: openssl not found on PATH (Linux: your package manager; macOS: preinstalled; Windows: Git for Windows ships it)\n");
    return null;
}

/// Run quietly; on failure print its stderr. False when it failed.
fn quiet(ctx: Context, argv: []const []const u8) !bool {
    const got = ctx.capture(argv, 120_000) orelse {
        try ctx.err.print("error: could not run {s}\n", .{argv[0]});
        return false;
    };
    defer got.deinit(ctx.gpa);
    if (got.code == 0) return true;
    try ctx.err.print("error: {s} {s} failed:\n{s}\n", .{ std.fs.path.basename(argv[0]), argv[1], std.mem.trim(u8, got.stderr, " \n") });
    return false;
}

/// Run quietly and ignore failure (best-effort cleanup).
fn quietStatus(ctx: Context, argv: []const []const u8) !u8 {
    const got = ctx.capture(argv, 30_000) orelse return 1;
    defer got.deinit(ctx.gpa);
    return got.code;
}

fn writePrivate(io: std.Io, path: []const u8, data: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    var f = try cwd.createFile(io, path, .{ .truncate = true, .permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600) });
    defer f.close(io);
    try f.writeStreamingAll(io, data);
}

fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn defaultKeysDir(gpa: std.mem.Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    if (env.get("XDG_CONFIG_HOME")) |xdg| {
        if (std.fs.path.isAbsolute(xdg)) return std.fs.path.join(gpa, &.{ xdg, "oriel", "keys" });
    }
    if (env.get("HOME") orelse env.get("USERPROFILE")) |home| {
        if (std.fs.path.isAbsolute(home)) return std.fs.path.join(gpa, &.{ home, ".config", "oriel", "keys" });
    }
    return std.fs.path.join(gpa, &.{ ".oriel", "keys" });
}

/// `.name = "..."` of the addApp options in ./build.zig, if any.
fn appNameFromBuildZig(ctx: Context, arena: std.mem.Allocator) ?[]const u8 {
    const src = std.Io.Dir.cwd().readFileAlloc(ctx.io, "build.zig", arena, .limited(1 << 20)) catch return null;
    const at = std.mem.indexOf(u8, src, "addApp(") orelse return null;
    const key = std.mem.indexOfPos(u8, src, at, ".name = \"") orelse return null;
    const start = key + ".name = \"".len;
    const end = std.mem.indexOfScalarPos(u8, src, start, '"') orelse return null;
    return src[start..end];
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == ' ' or c == '.' or c == '-' or c == '_')) return false;
    }
    return true;
}

fn allDigits(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn slugify(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (name) |c| try out.append(arena, if (std.ascii.isAlphanumeric(c)) std.ascii.toLower(c) else '-');
    return out.items;
}

test parseInfo {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const info = try parseInfo(arena_state.allocator(),
        \\subject=
        \\    commonName                = GhostPen
        \\sha1 Fingerprint=AB:cd:01:23
        \\notAfter=Sep 24 12:00:00 2036 GMT
        \\
    );
    try std.testing.expectEqualStrings("GhostPen", info.name);
    try std.testing.expectEqualStrings("ABCD0123", info.sha1);
    try std.testing.expectEqualStrings("Sep 24 12:00:00 2036 GMT", info.expires);
}

test validName {
    try std.testing.expect(validName("GhostPen"));
    try std.testing.expect(validName("My App 2.0"));
    try std.testing.expect(!validName("a\"b"));
    try std.testing.expect(!validName("/CN=x"));
    try std.testing.expect(!validName(""));
}
