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
//!   Nested code (the package's extra executables and libraries in
//!   Contents/MacOS) is signed first, inside-out, with the same identity and
//!   the hardened runtime, then the bundle. Nested executables get the app's
//!   entitlements (libraries none); with a sandbox entitlement a helper
//!   would also need `com.apple.security.inherit`, which isn't generated.
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

/// A path handed to a tool as a positional argument: never option-like.
pub fn validPath(path: []const u8) bool {
    return path.len > 0 and path[0] != '-';
}

/// The bundle's main executable: CFBundleExecutable in Contents/Info.plist
/// (as package-app writes it). Caller frees.
pub fn mainExecutable(gpa: std.mem.Allocator, io: Io, bundle: []const u8) ![]u8 {
    const plist_path = try std.fs.path.join(gpa, &.{ bundle, "Contents", "Info.plist" });
    defer gpa.free(plist_path);
    const plist = try Dir.cwd().readFileAlloc(io, plist_path, gpa, .limited(1024 * 1024));
    defer gpa.free(plist);
    const key = "<key>CFBundleExecutable</key>";
    const k = std.mem.indexOf(u8, plist, key) orelse return error.NoBundleExecutable;
    const open = std.mem.indexOfPos(u8, plist, k + key.len, "<string>") orelse return error.NoBundleExecutable;
    const start = open + "<string>".len;
    const end = std.mem.indexOfPos(u8, plist, start, "</string>") orelse return error.NoBundleExecutable;
    const name = std.mem.trim(u8, plist[start..end], " \t\r\n");
    if (name.len == 0 or std.mem.indexOfAny(u8, name, "/\\&<") != null or std.mem.eql(u8, name, "..")) return error.NoBundleExecutable;
    return gpa.dupe(u8, name);
}

/// Nested code found in a bundle: a Mach-O file other than the main executable.
pub const Nested = struct {
    /// Relative to the bundle, with the host's separator.
    path: []u8,
    /// An executable (MH_EXECUTE), signed with the app's entitlements; a
    /// library or plugin gets none. (A sandboxed app's helpers would need
    /// `com.apple.security.inherit` instead; Oriel doesn't sandbox.)
    executable: bool,
};

pub fn freeNested(gpa: std.mem.Allocator, list: []Nested) void {
    for (list) |n| gpa.free(n.path);
    gpa.free(list);
}

/// Every Mach-O file in the bundle except `Contents/MacOS/<main_exe>`,
/// deepest paths first (the order to sign in: inside-out). Caller frees
/// with `freeNested`.
pub fn nestedCode(gpa: std.mem.Allocator, io: Io, bundle: []const u8, main_exe: []const u8) ![]Nested {
    var list: std.ArrayList(Nested) = .empty;
    errdefer {
        for (list.items) |n| gpa.free(n.path);
        list.deinit(gpa);
    }
    var dir = try Dir.cwd().openDir(io, bundle, .{ .iterate = true });
    defer dir.close(io);
    const main_path = try std.fs.path.join(gpa, &.{ "Contents", "MacOS", main_exe });
    defer gpa.free(main_path);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.path, main_path)) continue;
        var file = entry.dir.openFile(io, entry.basename, .{}) catch continue;
        defer file.close(io);
        const kind = machOKind(io, file) orelse continue;
        const path = try gpa.dupe(u8, entry.path);
        errdefer gpa.free(path);
        try list.append(gpa, .{ .path = path, .executable = kind == .executable });
    }
    std.mem.sort(Nested, list.items, {}, struct {
        fn deeperFirst(_: void, a: Nested, b: Nested) bool {
            const da = std.mem.count(u8, a.path, std.fs.path.sep_str);
            const db = std.mem.count(u8, b.path, std.fs.path.sep_str);
            return if (da != db) da > db else std.mem.lessThan(u8, a.path, b.path);
        }
    }.deeperFirst);
    return list.toOwnedSlice(gpa);
}

const MachOKind = enum { executable, other };

/// Null when `file` isn't Mach-O. A universal binary is judged by its
/// first architecture.
fn machOKind(io: Io, file: std.Io.File) ?MachOKind {
    var head: [32]u8 = undefined;
    const n = file.readPositionalAll(io, &head, 0) catch return null;
    if (n < 16) return null;
    const magic = head[0..4].*;
    if (!isMachO(magic)) return null;
    const m = std.mem.readInt(u32, &magic, .little);
    if (m == 0xbebafeca or m == 0xcafebabe or m == 0xbfbafeca or m == 0xcafebabf) {
        // fat_header (big-endian): nfat_arch, then fat_arch { cputype,
        // cpusubtype, offset, size, align } with a u32 offset, or fat_arch_64
        // with a u64 one (FAT_MAGIC_64). 0xcafebabe is also Java's class-file
        // magic: require a plausible architecture count.
        const nfat = std.mem.readInt(u32, head[4..8], .big);
        const fat64 = head[3] == 0xbf;
        if (nfat == 0 or nfat > 32 or n < (if (fat64) @as(usize, 24) else 20)) return null;
        const off: u64 = if (fat64) std.mem.readInt(u64, head[16..24], .big) else std.mem.readInt(u32, head[16..20], .big);
        var slice: [16]u8 = undefined;
        const got = file.readPositionalAll(io, &slice, off) catch return null;
        if (got < 16 or !isMachO(slice[0..4].*)) return null;
        return thinKind(slice);
    }
    return thinKind(head[0..16].*);
}

fn thinKind(h: [16]u8) MachOKind {
    // mach_header: magic, cputype, cpusubtype, filetype (MH_EXECUTE = 2),
    // in the byte order the magic shows.
    const m = std.mem.readInt(u32, h[0..4], .little);
    const endian: std.builtin.Endian = if (m == 0xfeedface or m == 0xfeedfacf) .little else .big;
    return if (std.mem.readInt(u32, h[12..16], endian) == 2) .executable else .other;
}

/// Mach-O or universal (fat, 32- or 64-bit offsets) file magic.
pub fn isMachO(magic: [4]u8) bool {
    const m = std.mem.readInt(u32, &magic, .little);
    return switch (m) {
        0xfeedface, 0xfeedfacf, 0xcefaedfe, 0xcffaedfe, 0xcafebabe, 0xbebafeca, 0xcafebabf, 0xbfbafeca => true,
        else => false,
    };
}

fn validValue(v: []const u8) bool {
    if (v.len == 0 or v.len > 512 or v[0] == '-') return false;
    for (v) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

/// `codesign` arguments signing `app`: the hardened runtime and
/// `entitlements`, plus a secure timestamp for a real identity.
pub fn codesignAppArgv(buf: *[11][]const u8, identity: []const u8, entitlements: []const u8, app: []const u8) []const []const u8 {
    return codesignArgv(buf, identity, entitlements, app);
}

/// `codesign` arguments signing `path` (a bundle or a nested Mach-O file)
/// with the hardened runtime, `entitlements` when given, and a secure
/// timestamp for a real identity.
pub fn codesignArgv(buf: *[11][]const u8, identity: []const u8, entitlements: ?[]const u8, path: []const u8) []const []const u8 {
    const timestamp = if (std.mem.eql(u8, identity, ad_hoc)) "--timestamp=none" else "--timestamp";
    if (entitlements) |ent| {
        buf.* = .{ "/usr/bin/codesign", "--force", "--options", "runtime", "--entitlements", ent, timestamp, "--sign", identity, path, "" };
        return buf[0..10];
    }
    buf.* = .{ "/usr/bin/codesign", "--force", "--options", "runtime", timestamp, "--sign", identity, path, "", "", "" };
    return buf[0..8];
}

/// `xcrun notarytool submit` for `dmg`, waiting for the verdict (JSON).
pub fn notarizeArgv(buf: *[11][]const u8, profile: []const u8, dmg: []const u8) []const []const u8 {
    buf.* = .{ "/usr/bin/xcrun", "notarytool", "submit", dmg, "--keychain-profile", profile, "--wait", "--timeout", "2h", "--output-format", "json" };
    return buf[0..11];
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
    var prefix_buf: [64]u8 = undefined;
    printCommand(std.fmt.bufPrint(&prefix_buf, "{s}: dry run, would run:", .{what}) catch what, argv);
}

/// `argv` as a line that can be pasted into a POSIX shell.
fn printCommand(prefix: []const u8, argv: []const []const u8) void {
    std.debug.print("{s}", .{prefix});
    for (argv) |a| {
        if (a.len > 0 and std.mem.indexOfNone(u8, a, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:,+@%") == null) {
            std.debug.print(" {s}", .{a});
            continue;
        }
        std.debug.print(" '", .{});
        var it = std.mem.splitScalar(u8, a, '\'');
        var first = true;
        while (it.next()) |part| {
            if (!first) std.debug.print("'\\''", .{});
            first = false;
            std.debug.print("{s}", .{part});
        }
        std.debug.print("'", .{});
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
    for ([_][]const u8{ app.?, entitlements.?, out_dir.? }) |path| {
        if (!validPath(path)) {
            std.debug.print("error: sign-app: invalid path {s}\n", .{path});
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
    // ditto keeps the bundle's symlinks and modes; extended attributes and
    // resource forks would fail codesign ("detritus not allowed").
    runQuiet(gpa, io, "sign-app", &.{ "/usr/bin/ditto", "--norsrc", "--noextattr", "--noqtn", app.?, signed }) catch return 1;
    // Inside-out, no --deep: every nested Mach-O file (extra executables,
    // libraries) with the same identity and the hardened runtime, then the
    // bundle (which seals them). Executables get the app's entitlements.
    const main_exe = mainExecutable(gpa, io, signed) catch |err| {
        std.debug.print("error: sign-app: {s}: no CFBundleExecutable in Contents/Info.plist ({s})\n", .{ signed, @errorName(err) });
        return 1;
    };
    defer gpa.free(main_exe);
    const nested = nestedCode(gpa, io, signed, main_exe) catch |err| {
        std.debug.print("error: sign-app: looking for nested code in {s}: {s}\n", .{ signed, @errorName(err) });
        return 1;
    };
    defer freeNested(gpa, nested);

    const id = identity orelse placeholder_identity;
    // A dry run with a real (or placeholder) identity prints the commands and
    // signs ad-hoc the same way: the copy runs under the hardened runtime
    // with these entitlements, as the signed app would.
    const print_only = dry_run and !std.mem.eql(u8, id, ad_hoc);
    const run_id = if (print_only) ad_hoc else id;
    for (nested) |n| {
        const path = try std.fs.path.join(gpa, &.{ signed, n.path });
        defer gpa.free(path);
        const ent: ?[]const u8 = if (n.executable) entitlements.? else null;
        var buf: [11][]const u8 = undefined;
        if (print_only) printArgv("sign-app", codesignArgv(&buf, id, ent, path));
        runQuiet(gpa, io, "sign-app", codesignArgv(&buf, run_id, ent, path)) catch {
            if (!print_only and !std.mem.eql(u8, id, ad_hoc)) std.debug.print("  the keychain's signing identities: security find-identity -v -p codesigning\n", .{});
            return 1;
        };
    }
    var buf: [11][]const u8 = undefined;
    if (print_only) printArgv("sign-app", codesignArgv(&buf, id, entitlements.?, signed));
    runQuiet(gpa, io, "sign-app", codesignArgv(&buf, run_id, entitlements.?, signed)) catch {
        if (!print_only and !std.mem.eql(u8, id, ad_hoc)) std.debug.print("  the keychain's signing identities: security find-identity -v -p codesigning\n", .{});
        return 1;
    };
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
    var buf: [11][]const u8 = undefined;
    const submit = notarizeArgv(&buf, p, dmg);
    const staple = [_][]const u8{ "/usr/bin/xcrun", "stapler", "staple", dmg };
    const assess = [_][]const u8{ "/usr/sbin/spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=2", dmg };
    if (dry_run) {
        printArgv("package-dmg", submit);
        printArgv("package-dmg", &staple);
        printArgv("package-dmg", &assess);
        return;
    }
    std.debug.print("package-dmg: notarizing {s} (this waits for Apple's verdict, at most 2 hours)...\n", .{std.fs.path.basename(dmg)});
    // notarytool may exit non-zero on a rejection: read its verdict anyway.
    const res = std.process.run(gpa, io, .{ .argv = submit }) catch |err| {
        std.debug.print("error: package-dmg: failed to execute xcrun notarytool: {s}\n", .{@errorName(err)});
        return error.ToolFailed;
    };
    defer gpa.free(res.stderr);
    const out = res.stdout;
    defer gpa.free(out);
    const exited_ok = res.term == .exited and res.term.exited == 0;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const verdict = parseVerdict(arena_state.allocator(), out) catch {
        std.debug.print("error: package-dmg: notarytool failed:\n{s}{s}\n", .{ out, res.stderr });
        return error.ToolFailed;
    };
    if (!exited_ok or !std.mem.eql(u8, verdict.status, "Accepted")) {
        std.debug.print("error: package-dmg: notarization {s}: {s}\n{s}", .{
            if (verdict.status.len > 0) verdict.status else "failed", verdict.message, res.stderr,
        });
        if (verdict.id.len > 0) {
            var logbuf: [6][]const u8 = .{ "xcrun", "notarytool", "log", verdict.id, "--keychain-profile", p };
            printCommand("  details:", &logbuf);
        }
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

test nestedCode {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "A.app/Contents/MacOS/lib");
    try tmp.dir.createDirPath(io, "A.app/Contents/Resources");
    const exe = [_]u8{ 0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 0x01, 0, 0, 0, 0, 2, 0, 0, 0 };
    const dylib = [_]u8{ 0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 0x01, 0, 0, 0, 0, 6, 0, 0, 0 };
    try tmp.dir.writeFile(io, .{ .sub_path = "A.app/Contents/MacOS/a", .data = &exe });
    try tmp.dir.writeFile(io, .{ .sub_path = "A.app/Contents/Info.plist", .data = "<plist><dict>\n\t<key>CFBundleExecutable</key>\n\t<string>a</string>\n</dict></plist>" });
    try tmp.dir.writeFile(io, .{ .sub_path = "A.app/Contents/MacOS/data.bin", .data = "not code, 16 bytes or more" });
    const bundle = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/A.app", .{tmp.sub_path});
    defer gpa.free(bundle);

    const main_exe = try mainExecutable(gpa, io, bundle);
    defer gpa.free(main_exe);
    try std.testing.expectEqualStrings("a", main_exe);
    const none = try nestedCode(gpa, io, bundle, main_exe);
    defer freeNested(gpa, none);
    try std.testing.expectEqual(@as(usize, 0), none.len);

    try tmp.dir.writeFile(io, .{ .sub_path = "A.app/Contents/MacOS/a-cli", .data = &exe });
    try tmp.dir.writeFile(io, .{ .sub_path = "A.app/Contents/MacOS/lib/libx.dylib", .data = &dylib });
    const found = try nestedCode(gpa, io, bundle, main_exe);
    defer freeNested(gpa, found);
    try std.testing.expectEqual(@as(usize, 2), found.len);
    const sep = std.fs.path.sep_str;
    // Deepest first: the library inside lib/ before the helper executable.
    try std.testing.expectEqualStrings("Contents" ++ sep ++ "MacOS" ++ sep ++ "lib" ++ sep ++ "libx.dylib", found[0].path);
    try std.testing.expect(!found[0].executable);
    try std.testing.expectEqualStrings("Contents" ++ sep ++ "MacOS" ++ sep ++ "a-cli", found[1].path);
    try std.testing.expect(found[1].executable);
    try std.testing.expect(validPath("/abs/A.app") and validPath(".zig-cache/x") and !validPath("-x.app") and !validPath(""));
}

test "nestedCode reads universal binaries with 64-bit offsets" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "B.app/Contents/MacOS");
    // FAT_MAGIC_64, one arch whose slice (an executable) starts at 64.
    var fat = [_]u8{0} ** 80;
    fat[0..8].* = .{ 0xca, 0xfe, 0xba, 0xbf, 0, 0, 0, 1 };
    std.mem.writeInt(u64, fat[16..24], 64, .big);
    fat[64..80].* = .{ 0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 0x01, 0, 0, 0, 0, 2, 0, 0, 0 };
    try tmp.dir.writeFile(io, .{ .sub_path = "B.app/Contents/MacOS/b", .data = "main" });
    try tmp.dir.writeFile(io, .{ .sub_path = "B.app/Contents/MacOS/helper", .data = &fat });
    const bundle = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/B.app", .{tmp.sub_path});
    defer gpa.free(bundle);
    const found = try nestedCode(gpa, io, bundle, "b");
    defer freeNested(gpa, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expect(found[0].executable);
}

test codesignArgv {
    var buf: [11][]const u8 = undefined;
    const lib = codesignArgv(&buf, "Developer ID Application: X", null, "A.app/Contents/MacOS/libx.dylib");
    try std.testing.expectEqual(@as(usize, 8), lib.len);
    try std.testing.expectEqualStrings("runtime", lib[3]);
    try std.testing.expectEqualStrings("--timestamp", lib[4]);
    for (lib) |a| try std.testing.expect(!std.mem.eql(u8, a, "--entitlements"));
    const helper = codesignArgv(&buf, "-", "A.entitlements", "A.app/Contents/MacOS/a-cli");
    try std.testing.expectEqualStrings("A.entitlements", helper[5]);
    try std.testing.expectEqualStrings("--timestamp=none", helper[6]);
}

test notarizeArgv {
    var buf: [11][]const u8 = undefined;
    const argv = notarizeArgv(&buf, "prof", "a.dmg");
    try std.testing.expectEqualStrings("2h", argv[8]);
    try std.testing.expectEqualStrings("json", argv[argv.len - 1]);
}
