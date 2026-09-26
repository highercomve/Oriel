//! Developer ID signing and notarization of macOS packages (security 4.2).
//!
//! `zig build` keeps its ad-hoc signed `zig-out/<Name>.app` (fast, offline).
//! The package steps sign for distribution when asked to:
//!
//! - `-Dmacos-sign-identity="Developer ID Application: Name (TEAMID)"` (or a
//!   certificate's SHA-1, or `ORIEL_MACOS_SIGN_IDENTITY`): `sign-app` signs a
//!   copy of the bundle with the hardened runtime, the generated
//!   `<Name>.entitlements` and a secure timestamp, and verifies it
//!   (`codesign --verify --strict`); `package-dmg` signs the disk image too.
//!   `-` signs ad-hoc with the hardened runtime (to try the runtime and the
//!   entitlements locally; not distributable).
//! - `-Dmacos-notarize-profile=<profile>` (or `ORIEL_MACOS_NOTARIZE_PROFILE`):
//!   `package-dmg` submits the signed .dmg with `xcrun notarytool submit
//!   --keychain-profile <profile> --wait`, staples the ticket and checks it
//!   with `spctl`. The profile is the name given to `xcrun notarytool
//!   store-credentials`: the Apple ID / app-specific password or API key stay
//!   in the keychain and never pass through the build.
//! - `-Dmacos-sign-dry-run`: print the signing and notarization commands
//!   instead of running them, and sign ad-hoc with the hardened runtime and
//!   the entitlements (so the bundle runs as it would signed). Works without
//!   an identity or a profile.
//!
//! Identities and profiles are passed as plain arguments (never through a
//! shell); a value starting with `-` (other than the ad-hoc `-` identity) is
//! refused so it can't be read as an option.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Dir = std.Io.Dir;

pub const ad_hoc = "-";
/// Printed in dry runs without an identity or profile.
pub const placeholder_identity = "Developer ID Application: <name> (<team>)";
pub const placeholder_profile = "<notarytool profile>";

/// An identity: `-` (ad-hoc) or a certificate name or SHA-1 hash.
pub fn validIdentity(id: []const u8) bool {
    if (std.mem.eql(u8, id, ad_hoc)) return true;
    return validValue(id);
}

/// A notarytool keychain profile name.
pub fn validProfile(profile: []const u8) bool {
    return validValue(profile);
}

fn validValue(v: []const u8) bool {
    if (v.len == 0 or v.len > 512 or v[0] == '-') return false;
    for (v) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

/// `codesign` arguments signing `app`: the hardened runtime and
/// `entitlements`, plus a secure timestamp for a real identity.
pub fn codesignAppArgv(buf: *[11][]const u8, identity: []const u8, entitlements: []const u8, app: []const u8) []const []const u8 {
    buf.* = .{ "/usr/bin/codesign", "--force", "--options", "runtime", "--entitlements", entitlements, "--timestamp", "--sign", identity, app, "" };
    if (std.mem.eql(u8, identity, ad_hoc)) {
        buf[6] = "--timestamp=none";
    }
    return buf[0..10];
}

/// `xcrun notarytool submit` for `dmg`, waiting for the verdict (JSON).
pub fn notarizeArgv(buf: *[10][]const u8, profile: []const u8, dmg: []const u8) []const []const u8 {
    buf.* = .{ "/usr/bin/xcrun", "notarytool", "submit", dmg, "--keychain-profile", profile, "--wait", "--output-format", "json", "" };
    return buf[0..9];
}

pub const Verdict = struct {
    id: []const u8 = "",
    status: []const u8 = "",
    message: []const u8 = "",
};

/// The submission id and status from notarytool's JSON output.
pub fn parseVerdict(arena: std.mem.Allocator, json: []const u8) !Verdict {
    return std.json.parseFromSliceLeaky(Verdict, arena, json, .{ .ignore_unknown_fields = true });
}

fn printArgv(what: []const u8, argv: []const []const u8) void {
    std.debug.print("{s}: dry run, would run:", .{what});
    for (argv) |a| {
        if (std.mem.indexOfAny(u8, a, " '\"") != null) std.debug.print(" '{s}'", .{a}) else std.debug.print(" {s}", .{a});
    }
    std.debug.print("\n", .{});
}

/// Run a command; print its output and fail when it doesn't exit 0.
/// Returns stdout (caller frees).
fn run(gpa: std.mem.Allocator, io: Io, what: []const u8, argv: []const []const u8) ![]u8 {
    const res = std.process.run(gpa, io, .{ .argv = argv }) catch |err| {
        std.debug.print("error: {s}: failed to execute {s}: {s}\n", .{ what, argv[0], @errorName(err) });
        return error.ToolFailed;
    };
    defer gpa.free(res.stderr);
    if (res.term != .exited or res.term.exited != 0) {
        defer gpa.free(res.stdout);
        std.debug.print("error: {s}: {s} failed:\n{s}{s}\n", .{ what, argv[0], res.stdout, res.stderr });
        return error.ToolFailed;
    }
    return res.stdout;
}

fn runQuiet(gpa: std.mem.Allocator, io: Io, what: []const u8, argv: []const []const u8) !void {
    gpa.free(try run(gpa, io, what, argv));
}

/// `sign-app --app <bundle> --entitlements <file> --out-dir <dir>
/// [--identity <id>] [--dry-run]`: copy the bundle into `out-dir` and sign
/// the copy (see the file comment).
pub fn signAppCmd(gpa: std.mem.Allocator, io: Io, args: []const [:0]const u8) !u8 {
    var app: ?[]const u8 = null;
    var entitlements: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    var identity: ?[]const u8 = null;
    var dry_run = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const has_value = i + 1 < args.len;
        if (std.mem.eql(u8, arg, "--app") and has_value) {
            i += 1;
            app = args[i];
        } else if (std.mem.eql(u8, arg, "--entitlements") and has_value) {
            i += 1;
            entitlements = args[i];
        } else if (std.mem.eql(u8, arg, "--out-dir") and has_value) {
            i += 1;
            out_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--identity") and has_value) {
            i += 1;
            identity = args[i];
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else {
            std.debug.print("error: sign-app: unknown argument {s}\n", .{arg});
            return 1;
        }
    }
    if (app == null or entitlements == null or out_dir == null) {
        std.debug.print("error: sign-app: needs --app, --entitlements and --out-dir\n", .{});
        return 1;
    }
    if (identity == null and !dry_run) {
        std.debug.print("error: sign-app: needs --identity (or --dry-run)\n", .{});
        return 1;
    }
    if (identity) |id| {
        if (!validIdentity(id)) {
            std.debug.print("error: sign-app: invalid signing identity\n", .{});
            return 1;
        }
    }
    if (builtin.os.tag != .macos) {
        std.debug.print("error: sign-app: signing needs codesign, on a macOS host\n", .{});
        return 1;
    }

    try Dir.cwd().createDirPath(io, out_dir.?);
    const signed = try std.fs.path.join(gpa, &.{ out_dir.?, std.fs.path.basename(app.?) });
    defer gpa.free(signed);
    Dir.cwd().deleteTree(io, signed) catch {};
    // ditto keeps the bundle's symlinks and modes.
    runQuiet(gpa, io, "sign-app", &.{ "/usr/bin/ditto", app.?, signed }) catch return 1;

    var buf: [11][]const u8 = undefined;
    const id = identity orelse placeholder_identity;
    if (dry_run and !std.mem.eql(u8, id, ad_hoc)) {
        printArgv("sign-app", codesignAppArgv(&buf, id, entitlements.?, signed));
        // Sign the copy the same way, ad-hoc: it runs under the hardened
        // runtime with these entitlements, as the signed app would.
        runQuiet(gpa, io, "sign-app", codesignAppArgv(&buf, ad_hoc, entitlements.?, signed)) catch return 1;
    } else {
        runQuiet(gpa, io, "sign-app", codesignAppArgv(&buf, id, entitlements.?, signed)) catch {
            if (!std.mem.eql(u8, id, ad_hoc)) std.debug.print("  the keychain's signing identities: security find-identity -v -p codesigning\n", .{});
            return 1;
        };
    }
    runQuiet(gpa, io, "sign-app", &.{ "/usr/bin/codesign", "--verify", "--strict", "--verbose=2", signed }) catch return 1;
    return 0;
}

/// After `package-dmg` created `dmg`: sign it with `identity` (not ad-hoc)
/// and notarize it with `profile`, or print what would run (`dry_run`).
pub fn finishDmg(gpa: std.mem.Allocator, io: Io, dmg: []const u8, identity: ?[]const u8, profile: ?[]const u8, dry_run: bool) !void {
    const id: ?[]const u8 = identity orelse (if (dry_run) placeholder_identity else null);
    if (id) |sign_id| {
        if (!std.mem.eql(u8, sign_id, ad_hoc)) {
            const argv = [_][]const u8{ "/usr/bin/codesign", "--force", "--timestamp", "--sign", sign_id, dmg };
            if (dry_run) printArgv("package-dmg", &argv) else try runQuiet(gpa, io, "package-dmg", &argv);
        }
    }
    const p: []const u8 = profile orelse (if (dry_run) placeholder_profile else return);
    var buf: [10][]const u8 = undefined;
    const submit = notarizeArgv(&buf, p, dmg);
    const staple = [_][]const u8{ "/usr/bin/xcrun", "stapler", "staple", dmg };
    const assess = [_][]const u8{ "/usr/sbin/spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=2", dmg };
    if (dry_run) {
        printArgv("package-dmg", submit);
        printArgv("package-dmg", &staple);
        printArgv("package-dmg", &assess);
        return;
    }
    std.debug.print("package-dmg: notarizing {s} (this waits for Apple's verdict)...\n", .{std.fs.path.basename(dmg)});
    const out = try run(gpa, io, "package-dmg", submit);
    defer gpa.free(out);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const verdict = parseVerdict(arena_state.allocator(), out) catch {
        std.debug.print("error: package-dmg: unexpected notarytool output:\n{s}\n", .{out});
        return error.ToolFailed;
    };
    if (!std.mem.eql(u8, verdict.status, "Accepted")) {
        std.debug.print("error: package-dmg: notarization {s}: {s}\n  details: xcrun notarytool log {s} --keychain-profile '{s}'\n", .{
            if (verdict.status.len > 0) verdict.status else "failed", verdict.message, verdict.id, p,
        });
        return error.ToolFailed;
    }
    try runQuiet(gpa, io, "package-dmg", &staple);
    try runQuiet(gpa, io, "package-dmg", &assess);
    std.debug.print("package-dmg: notarized and stapled ({s})\n", .{verdict.id});
}

test validIdentity {
    try std.testing.expect(validIdentity("-"));
    try std.testing.expect(validIdentity("Developer ID Application: Jane Doe (AB12CD34EF)"));
    try std.testing.expect(validIdentity("0123456789ABCDEF0123456789ABCDEF01234567"));
    try std.testing.expect(!validIdentity(""));
    try std.testing.expect(!validIdentity("--deep"));
    try std.testing.expect(!validIdentity("name\nx"));
    try std.testing.expect(validProfile("oriel-notary"));
    try std.testing.expect(!validProfile("-p"));
}

test codesignAppArgv {
    var buf: [11][]const u8 = undefined;
    const real = codesignAppArgv(&buf, "Developer ID Application: X", "A.entitlements", "A.app");
    try std.testing.expectEqualStrings("--timestamp", real[6]);
    try std.testing.expectEqualStrings("Developer ID Application: X", real[8]);
    try std.testing.expectEqualStrings("A.app", real[real.len - 1]);
    try std.testing.expectEqualStrings("runtime", real[3]);
    const adhoc = codesignAppArgv(&buf, "-", "A.entitlements", "A.app");
    try std.testing.expectEqualStrings("--timestamp=none", adhoc[6]);
    try std.testing.expectEqual(@as(usize, 10), adhoc.len);
}

test parseVerdict {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const v = try parseVerdict(arena_state.allocator(),
        \\{"id":"2efe2717-52ef-43a5-96dc-0797e4ca1041","status":"Invalid","message":"Processing complete","other":1}
    );
    try std.testing.expectEqualStrings("Invalid", v.status);
    try std.testing.expectEqualStrings("2efe2717-52ef-43a5-96dc-0797e4ca1041", v.id);
}
