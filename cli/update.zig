//! `oriel update`: in-place update of the Oriel CLI using Oriel's self-updater.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Context = @import("Context.zig");
const core = @import("updater_core");
const webview2 = @import("webview2.zig");

pub const default_releases_url = "https://github.com/highercomve/Oriel/releases";

/// Upper bound for the GitHub releases API response.
const max_release_json_bytes = 4 * 1024 * 1024;

pub const Command = struct {
    pub const summary = "Update the oriel CLI in place";
    pub const help = .{
        .check = "Check if an update is available without installing it",
        .version = "Update to a specific version or tag (default: latest release)",
        .yes = "Do not ask for confirmation before installing",
    };
    pub const values = .{ .version = "tag" };
    pub const details =
        \\Downloads the signed release manifest for this architecture, verifies
        \\the Ed25519 signature against the embedded Oriel release key, and
        \\atomically replaces the running CLI binary.
    ;

    check: bool = false,
    version: ?[]const u8 = null,
    yes: bool = false,
};

pub fn run(ctx: Context, cmd: Command) !u8 {
    return runWithKey(ctx, cmd, build_options.update_public_key);
}

pub fn runWithKey(ctx: Context, cmd: Command, public_key_opt: ?[]const u8) !u8 {
    const public_key = public_key_opt orelse {
        try ctx.err.writeAll("error: this oriel build has no update key; reinstall with install.sh\n");
        return 1;
    };
    if (public_key.len == 0) {
        try ctx.err.writeAll("error: this oriel build has no update key; reinstall with install.sh\n");
        return 1;
    }

    if (cmd.version) |v| if (!isReleaseTag(v)) {
        try ctx.err.print("error: --version wants a release tag like v1.2.3 or 1.2.3-rc.1, not '{s}'\n", .{v});
        return 1;
    };

    const releases_url = ctx.environ.get("ORIEL_RELEASES_URL") orelse default_releases_url;
    const trimmed_releases = std.mem.trimEnd(u8, releases_url, "/");

    var resolved_tag: ?[]const u8 = null;
    defer if (resolved_tag) |t| ctx.gpa.free(t);

    const release_base = if (cmd.version) |v|
        try std.fmt.allocPrint(ctx.gpa, "{s}/download/{s}", .{ trimmed_releases, v })
    else if (std.mem.eql(u8, releases_url, default_releases_url)) blk: {
        const latest_tag = fetchLatestReleaseTag(ctx) catch return 1;
        resolved_tag = latest_tag;
        break :blk try std.fmt.allocPrint(ctx.gpa, "{s}/download/{s}", .{ trimmed_releases, latest_tag });
    } else try std.fmt.allocPrint(ctx.gpa, "{s}/latest/download", .{trimmed_releases});
    defer ctx.gpa.free(release_base);

    // An explicit version is installed even when older or the same; the
    // manifest must then name exactly that version (checked below).
    const is_forced = cmd.version != null;
    var update_cfg = core.Config{
        .app_id = "dev.oriel.cli",
        .manifest_url = undefined,
        .current_version = build_options.version,
        .public_key_b64 = public_key,
        .target = core.DEFAULT_TARGET,
        .force = is_forced,
        .allow_downgrade = is_forced,
    };

    // One combined manifest for every platform.
    const manifest_url = try std.fmt.allocPrint(ctx.gpa, "{s}/latest.json", .{release_base});
    defer ctx.gpa.free(manifest_url);
    update_cfg.manifest_url = manifest_url;
    var maybe_update: ?core.Update = core.checkForUpdate(ctx.io, ctx.gpa, update_cfg) catch |err| {
        try ctx.err.print("error: update check failed: {s}\n", .{@errorName(err)});
        return 1;
    };

    // A signed manifest for another version (e.g. an old one replayed under
    // this tag) must not install it.
    if (cmd.version) |v| if (maybe_update) |*up| {
        if (!sameVersion(up.version, v)) {
            try ctx.err.print("error: the release manifest for {s} names version {s}\n", .{ v, up.version });
            up.deinit();
            return 1;
        }
    };

    if (cmd.check) {
        if (maybe_update) |*up| {
            defer up.deinit();
            try ctx.out.print("oriel {s} is available (current: {s})\n", .{ up.version, build_options.version });
            return 0;
        } else {
            try ctx.out.print("oriel is up to date ({s})\n", .{build_options.version});
            return 0;
        }
    }

    if (maybe_update == null) {
        try ctx.out.print("oriel is already up to date ({s})\n", .{build_options.version});
        return 0;
    }
    var update = maybe_update.?;
    defer update.deinit();

    const stdin_file = std.Io.File.stdin();
    const is_tty = stdin_file.isTty(ctx.io) catch false;

    if (!cmd.yes) {
        if (!is_tty) {
            try ctx.err.writeAll("error: non-interactive terminal requires --yes to confirm update\n");
            return 1;
        }

        try ctx.out.print("Install update {s} -> {s}? [y/N] ", .{ build_options.version, update.version });
        ctx.flush();

        var line_buf: [64]u8 = undefined;
        var line_reader = stdin_file.readerStreaming(ctx.io, &line_buf);
        const answer = (line_reader.interface.takeDelimiter('\n') catch null) orelse "";
        const trimmed = std.mem.trim(u8, answer, " \t\r\n");
        if (!std.ascii.eqlIgnoreCase(trimmed, "y") and !std.ascii.eqlIgnoreCase(trimmed, "yes")) {
            try ctx.out.writeAll("Update cancelled.\n");
            return 0;
        }
    }

    const dest_override = ctx.environ.get("ORIEL_UPDATE_TARGET");

    const installed_path = core.download(ctx.io, ctx.gpa, update, .{ .dest_path = dest_override }) catch |err| {
        try ctx.err.print("error: failed to install update: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer ctx.gpa.free(installed_path);

    try ctx.out.print("Updated oriel {s} -> {s} at {s}\n", .{ build_options.version, update.version, installed_path });
    return 0;
}

/// A release tag: `v?MAJOR.MINOR.PATCH(-prerelease)?` (it goes into the URL).
pub fn isReleaseTag(tag: []const u8) bool {
    const t = if (std.mem.startsWith(u8, tag, "v")) tag[1..] else tag;
    const dash = std.mem.indexOfScalar(u8, t, '-');
    const core_part = t[0 .. dash orelse t.len];
    var parts = std.mem.splitScalar(u8, core_part, '.');
    var n: usize = 0;
    while (parts.next()) |p| : (n += 1) {
        if (n == 3 or p.len == 0) return false;
        for (p) |c| if (!std.ascii.isDigit(c)) return false;
    }
    if (n != 3) return false;
    if (dash) |d| {
        const pre = t[d + 1 ..];
        if (pre.len == 0) return false;
        var ids = std.mem.splitScalar(u8, pre, '.');
        while (ids.next()) |id| {
            if (id.len == 0) return false;
            for (id) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
        }
    }
    return true;
}

test isReleaseTag {
    try std.testing.expect(isReleaseTag("v1.2.3"));
    try std.testing.expect(isReleaseTag("0.9.15"));
    try std.testing.expect(isReleaseTag("v1.0.0-rc.1"));
    try std.testing.expect(!isReleaseTag("v1.2"));
    try std.testing.expect(!isReleaseTag("1.2.3.4"));
    try std.testing.expect(!isReleaseTag("1.2.3-"));
    try std.testing.expect(!isReleaseTag("1.2.3+build"));
    try std.testing.expect(!isReleaseTag("../v1.2.3"));
    try std.testing.expect(!isReleaseTag("v1.2.3/../../x"));
    try std.testing.expect(!isReleaseTag("v1.2.3-a/b"));
    try std.testing.expect(!isReleaseTag(""));
}

/// Whether the manifest's version is the requested tag (a `v` aside).
fn sameVersion(manifest_version: []const u8, tag: []const u8) bool {
    const a = core.Semver.parse(manifest_version) catch return false;
    const b = core.Semver.parse(tag) catch return false;
    return a.order(b) == .eq;
}

test sameVersion {
    try std.testing.expect(sameVersion("1.2.3", "v1.2.3"));
    try std.testing.expect(!sameVersion("1.2.2", "v1.2.3"));
    try std.testing.expect(!sameVersion("1.2.3-rc.1", "1.2.3"));
}

fn fetchLatestReleaseTag(ctx: Context) ![]const u8 {
    var client: std.http.Client = .{ .allocator = ctx.gpa, .io = ctx.io };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer body.deinit();

    const req_url = "https://api.github.com/repos/highercomve/Oriel/releases?per_page=1";
    const res = webview2.fetchBounded(&client, .{
        .location = .{ .url = req_url },
        .headers = .{
            .user_agent = .{ .override = "oriel-cli" },
        },
        .extra_headers = &.{
            .{ .name = "accept", .value = "application/vnd.github+json" },
        },
    }, &body, max_release_json_bytes) catch |err| {
        try ctx.err.print("error: could not look up latest release: {s}\n", .{@errorName(err)});
        return error.FetchFailed;
    };

    if (res.status != .ok) {
        try ctx.err.print("error: GitHub API returned status {d}\n", .{@intFromEnum(res.status)});
        return error.FetchFailed;
    }

    var arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena.deinit();

    const Release = struct {
        tag_name: []const u8,
    };
    const parsed = std.json.parseFromSliceLeaky([]Release, arena.allocator(), body.written(), .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        try ctx.err.print("error: failed to parse release metadata: {s}\n", .{@errorName(err)});
        return error.ParseFailed;
    };
    if (parsed.len == 0 or parsed[0].tag_name.len == 0) {
        try ctx.err.writeAll("error: no releases found at highercomve/Oriel\n");
        return error.NoReleasesFound;
    }
    return try ctx.gpa.dupe(u8, parsed[0].tag_name);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "oriel update without update_public_key prints error" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var out_buf: std.Io.Writer.Allocating = .init(allocator);
    defer out_buf.deinit();
    var err_buf: std.Io.Writer.Allocating = .init(allocator);
    defer err_buf.deinit();

    const ctx: Context = .{
        .gpa = allocator,
        .io = io,
        .environ = &env_map,
        .out = &out_buf.writer,
        .err = &err_buf.writer,
    };

    const code = try runWithKey(ctx, .{ .check = true }, null);
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, err_buf.written(), "this oriel build has no update key; reinstall with install.sh") != null);
}

test "oriel update end-to-end against local HTTP server" {
    // POSIX-only: stages the fake update binary with Permissions.fromMode (exec bits).
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // The local server answers over http://.
    core.testing.allow_loopback_http = true;
    defer core.testing.allow_loopback_http = false;

    // 1. Generate throwaway Ed25519 keypair
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{42} ** 32);
    var pk_b64: [core.update_manifest.PUBLIC_KEY_B64_LEN]u8 = undefined;
    _ = core.update_manifest.encodePublicKey(kp.public_key.toBytes(), &pk_b64);

    // 2. Prepare payload and temp target file
    const new_cli_payload = "#!/bin/sh\necho 'updated oriel cli'\n";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(new_cli_payload, &digest, .{});
    const sha256_hex = std.fmt.bytesToHex(digest, .lower);

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(dir_path);
    const dummy_cli_path = try std.fs.path.join(allocator, &.{ dir_path, "oriel_temp_bin" });
    defer allocator.free(dummy_cli_path);

    {
        const f = try std.Io.Dir.cwd().createFile(io, dummy_cli_path, .{
            .permissions = std.Io.File.Permissions.fromMode(0o755),
        });
        defer f.close(io);
        try f.writeStreamingAll(io, "initial cli binary content");
    }

    // 3. Start local mock HTTP server
    var server = try core.testing.MockServer.start(io, 0, "", new_cli_payload, null);
    defer server.stop();

    const payload_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/payload", .{server.port});
    defer allocator.free(payload_url);

    // Sign manifest for version 99.0.0 (newer than any current version)
    const sign_params = core.update_manifest.SignParameters{
        .app_id = "dev.oriel.cli",
        .version = "99.0.0",
        .target = core.DEFAULT_TARGET,
        .format = "raw",
        .size = new_cli_payload.len,
        .sha256 = &sha256_hex,
        .url = payload_url,
        .allow_test_http = true,
    };
    const sig_b64 = try core.update_manifest.sign(allocator, kp, sign_params);
    defer allocator.free(sig_b64);
    const manifest_json = try core.update_manifest.formatManifest(allocator, sign_params, sig_b64);
    defer allocator.free(manifest_json);
    server.setManifest(io, manifest_json);
    // The release's latest.json (the primary path; the legacy file is the fallback).
    const combined_json = try core.update_manifest.combine(allocator, &.{manifest_json}, .{ .allow_test_http = true });
    defer allocator.free(combined_json);
    server.setCombined(io, combined_json);

    // 4. Test environment setup
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    const releases_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/releases", .{server.port});
    defer allocator.free(releases_url);
    try env_map.put("ORIEL_RELEASES_URL", releases_url);
    try env_map.put("ORIEL_UPDATE_TARGET", dummy_cli_path);

    var out_buf: std.Io.Writer.Allocating = .init(allocator);
    defer out_buf.deinit();
    var err_buf: std.Io.Writer.Allocating = .init(allocator);
    defer err_buf.deinit();

    const ctx: Context = .{
        .gpa = allocator,
        .io = io,
        .environ = &env_map,
        .out = &out_buf.writer,
        .err = &err_buf.writer,
    };

    // 5. Test --check reports available update
    const check_res = try runWithKey(ctx, .{ .check = true }, &pk_b64);
    try std.testing.expectEqual(@as(u8, 0), check_res);
    try std.testing.expect(std.mem.indexOf(u8, out_buf.written(), "99.0.0 is available") != null);

    // 5b. --version: the manifest must name that version; the tag is validated
    out_buf.clearRetainingCapacity();
    err_buf.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 1), try runWithKey(ctx, .{ .check = true, .version = "v1.0.0" }, &pk_b64));
    try std.testing.expect(std.mem.indexOf(u8, err_buf.written(), "names version 99.0.0") != null);
    try std.testing.expectEqual(@as(u8, 1), try runWithKey(ctx, .{ .check = true, .version = "../v99.0.0" }, &pk_b64));
    out_buf.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 0), try runWithKey(ctx, .{ .check = true, .version = "v99.0.0" }, &pk_b64));
    try std.testing.expect(std.mem.indexOf(u8, out_buf.written(), "99.0.0 is available") != null);

    // 6. Test non-TTY without --yes fails with error
    out_buf.clearRetainingCapacity();
    err_buf.clearRetainingCapacity();
    const no_yes_res = try runWithKey(ctx, .{}, &pk_b64);
    try std.testing.expectEqual(@as(u8, 1), no_yes_res);
    try std.testing.expect(std.mem.indexOf(u8, err_buf.written(), "requires --yes") != null);

    // 7. Test --yes installs update atomically
    out_buf.clearRetainingCapacity();
    err_buf.clearRetainingCapacity();
    const install_res = try runWithKey(ctx, .{ .yes = true }, &pk_b64);
    try std.testing.expectEqual(@as(u8, 0), install_res);
    try std.testing.expect(std.mem.indexOf(u8, out_buf.written(), "Updated oriel") != null);

    // Verify temp binary content on disk was replaced
    const content = try std.Io.Dir.cwd().readFileAlloc(io, dummy_cli_path, allocator, .limited(1024));
    defer allocator.free(content);
    try std.testing.expectEqualStrings(new_cli_payload, content);
}

test "oriel update rejects tampered manifest and payload" {
    // POSIX-only: stages the fake update binary with Permissions.fromMode (exec bits).
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{42} ** 32);
    var pk_b64: [core.update_manifest.PUBLIC_KEY_B64_LEN]u8 = undefined;
    _ = core.update_manifest.encodePublicKey(kp.public_key.toBytes(), &pk_b64);

    const wrong_kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{99} ** 32);

    // The local server answers over http://.
    core.testing.allow_loopback_http = true;
    defer core.testing.allow_loopback_http = false;

    const payload = "unaltered payload";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
    const sha256_hex = std.fmt.bytesToHex(digest, .lower);

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(dir_path);
    const dummy_cli_path = try std.fs.path.join(allocator, &.{ dir_path, "oriel_tampered_test" });
    defer allocator.free(dummy_cli_path);

    const original_content = "original cli content";
    {
        const f = try std.Io.Dir.cwd().createFile(io, dummy_cli_path, .{
            .permissions = std.Io.File.Permissions.fromMode(0o755),
        });
        defer f.close(io);
        try f.writeStreamingAll(io, original_content);
    }

    var server = try core.testing.MockServer.start(io, 0, "", payload, null);
    defer server.stop();

    const payload_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/payload", .{server.port});
    defer allocator.free(payload_url);

    // Sign manifest with wrong key -> tampered signature
    const sign_params = core.update_manifest.SignParameters{
        .app_id = "dev.oriel.cli",
        .version = "99.0.0",
        .target = core.DEFAULT_TARGET,
        .format = "raw",
        .size = payload.len,
        .sha256 = &sha256_hex,
        .url = payload_url,
        .allow_test_http = true,
    };
    const bad_sig = try core.update_manifest.sign(allocator, wrong_kp, sign_params);
    defer allocator.free(bad_sig);
    const bad_manifest_json = try core.update_manifest.formatManifest(allocator, sign_params, bad_sig);
    defer allocator.free(bad_manifest_json);
    server.setManifest(io, bad_manifest_json);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    const releases_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/releases", .{server.port});
    defer allocator.free(releases_url);
    try env_map.put("ORIEL_RELEASES_URL", releases_url);
    try env_map.put("ORIEL_UPDATE_TARGET", dummy_cli_path);

    var out_buf: std.Io.Writer.Allocating = .init(allocator);
    defer out_buf.deinit();
    var err_buf: std.Io.Writer.Allocating = .init(allocator);
    defer err_buf.deinit();

    const ctx: Context = .{
        .gpa = allocator,
        .io = io,
        .environ = &env_map,
        .out = &out_buf.writer,
        .err = &err_buf.writer,
    };

    // Update with tampered signature must fail
    const code = try runWithKey(ctx, .{ .yes = true }, &pk_b64);
    try std.testing.expectEqual(@as(u8, 1), code);

    // Verify dummy binary was NOT replaced
    const intact = try std.Io.Dir.cwd().readFileAlloc(io, dummy_cli_path, allocator, .limited(1024));
    defer allocator.free(intact);
    try std.testing.expectEqualStrings(original_content, intact);
}
