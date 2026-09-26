//! WinGet manifests for the NSIS installer (`package-winget`).
//!
//! WinGet installs from a public URL (a GitHub release asset) and is described
//! by three YAML files, submitted to microsoft/winget-pkgs under
//! `manifests/<p>/<Publisher>/<App>/<version>/`:
//!
//! - `<Id>.yaml`: the version manifest,
//! - `<Id>.installer.yaml`: the installer (URL, SHA-256, `nullsoft`, per-user,
//!   silent `/S`), with `ProductCode` = the app id, the key Oriel's installer
//!   writes under `HKCU\...\Uninstall`, so WinGet recognizes an installed copy
//!   and upgrades it,
//! - `<Id>.locale.en-US.yaml`: the default locale (name, publisher, license,
//!   descriptions).
//!
//! A `portable` package instead (a standalone exe per architecture, like the
//! `oriel` CLI): WinGet downloads it and puts `Commands` on PATH.
//!
//! `wingetcreate submit <dir>` (or komac) opens the pull request.

const std = @import("std");

pub const manifest_version = "1.10.0";

pub const Manifest = struct {
    /// `Publisher.App`.
    id: []const u8,
    version: []const u8,
    name: []const u8,
    publisher: []const u8,
    license: []const u8,
    summary: []const u8,
    description: []const u8,
    homepage: ?[]const u8 = null,
    license_url: ?[]const u8 = null,
    release_notes_url: ?[]const u8 = null,
    moniker: ?[]const u8 = null,
    tags: []const []const u8 = &.{},
    /// The HKCU Uninstall key the installer writes (the app id).
    product_code: []const u8,
    installer_url: []const u8,
    /// Lowercase hex SHA-256 of the installer.
    installer_sha256: []const u8,
    /// WinGet architecture: x64, arm64, x86.
    architecture: []const u8 = "x64",
    url_schemes: []const []const u8 = &.{},
    /// Non-empty: a `portable` package with these executables instead of
    /// the NSIS installer (installer_url, installer_sha256 and product_code
    /// are unused).
    portable: []const Portable = &.{},
    /// Portable packages: the command names WinGet puts on PATH.
    commands: []const []const u8 = &.{},
};

pub const Portable = struct {
    architecture: []const u8,
    url: []const u8,
    sha256: []const u8,
};

pub const Error = error{ InvalidIdentifier, InvalidUrl, InvalidValue };

/// `Publisher.App` (WinGet's PackageIdentifier): segments of letters,
/// digits and `-_+`, at least two, separated by dots.
pub fn validIdentifier(id: []const u8) bool {
    if (id.len == 0 or id.len > 128) return false;
    var segments: usize = 0;
    var it = std.mem.splitScalar(u8, id, '.');
    while (it.next()) |seg| {
        if (seg.len == 0 or seg.len > 32) return false;
        for (seg) |c| {
            if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '+')) return false;
        }
        segments += 1;
    }
    return segments >= 2 and segments <= 8;
}

/// The directory winget-pkgs keeps the manifests in:
/// `manifests/<first letter>/<segments...>/<version>`.
pub fn repoPath(gpa: std.mem.Allocator, id: []const u8, version: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "manifests/");
    try out.append(gpa, std.ascii.toLower(id[0]));
    var it = std.mem.splitScalar(u8, id, '.');
    while (it.next()) |seg| {
        try out.append(gpa, '/');
        try out.appendSlice(gpa, seg);
    }
    try out.append(gpa, '/');
    try out.appendSlice(gpa, version);
    return out.toOwnedSlice(gpa);
}

fn checkInstaller(url: []const u8, sha256: []const u8) Error!void {
    if (!std.mem.startsWith(u8, url, "https://")) return error.InvalidUrl;
    if (sha256.len != 64) return error.InvalidValue;
    for (sha256) |c| if (!std.ascii.isHex(c)) return error.InvalidValue;
}

fn check(m: Manifest) Error!void {
    if (!validIdentifier(m.id)) return error.InvalidIdentifier;
    if (m.portable.len > 0) {
        for (m.portable) |p| try checkInstaller(p.url, p.sha256);
        if (m.commands.len == 0) return error.InvalidValue;
    } else try checkInstaller(m.installer_url, m.installer_sha256);
    if (m.version.len == 0 or m.name.len == 0 or m.publisher.len == 0 or m.license.len == 0 or m.summary.len == 0) return error.InvalidValue;
}

/// A YAML double-quoted scalar.
fn quoted(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => {},
        '\t' => try w.writeAll("\\t"),
        else => if (c < 0x20) try w.print("\\x{x:0>2}", .{c}) else try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn header(w: *std.Io.Writer, kind: []const u8) !void {
    try w.print("# yaml-language-server: $schema=https://aka.ms/winget-manifest.{s}.{s}.schema.json\n", .{ kind, manifest_version });
    try w.writeAll("# Created by oriel package\n\n");
}

pub fn writeVersion(w: *std.Io.Writer, m: Manifest) !void {
    try check(m);
    try header(w, "version");
    try w.print("PackageIdentifier: {s}\nPackageVersion: ", .{m.id});
    try quoted(w, m.version);
    try w.print("\nDefaultLocale: en-US\nManifestType: version\nManifestVersion: {s}\n", .{manifest_version});
}

pub fn writeInstaller(w: *std.Io.Writer, m: Manifest) !void {
    try check(m);
    try header(w, "installer");
    try w.print("PackageIdentifier: {s}\nPackageVersion: ", .{m.id});
    try quoted(w, m.version);
    if (m.portable.len > 0) {
        try w.writeAll("\nInstallerType: portable\nCommands:");
        for (m.commands) |c| {
            try w.writeAll("\n- ");
            try quoted(w, c);
        }
        try w.writeAll("\nInstallers:");
        for (m.portable) |p| {
            try w.print("\n- Architecture: {s}\n  InstallerUrl: ", .{p.architecture});
            try quoted(w, p.url);
            try w.print("\n  InstallerSha256: {s}", .{upperHex(p.sha256)});
        }
        try w.print("\nManifestType: installer\nManifestVersion: {s}\n", .{manifest_version});
        return;
    }
    try w.writeAll(
        \\
        \\InstallerType: nullsoft
        \\Scope: user
        \\InstallModes:
        \\- interactive
        \\- silent
        \\UpgradeBehavior: install
        \\
    );
    if (m.url_schemes.len > 0) {
        try w.writeAll("Protocols:\n");
        for (m.url_schemes) |s| {
            try w.writeAll("- ");
            try quoted(w, s);
            try w.writeByte('\n');
        }
    }
    try w.writeAll("ProductCode: ");
    try quoted(w, m.product_code);
    try w.writeAll("\nAppsAndFeaturesEntries:\n- DisplayName: ");
    try quoted(w, m.name);
    try w.writeAll("\n  Publisher: ");
    try quoted(w, m.publisher);
    try w.writeAll("\n  ProductCode: ");
    try quoted(w, m.product_code);
    try w.print("\nInstallers:\n- Architecture: {s}\n  InstallerUrl: ", .{m.architecture});
    try quoted(w, m.installer_url);
    try w.print("\n  InstallerSha256: {s}\nManifestType: installer\nManifestVersion: {s}\n", .{ upperHex(m.installer_sha256), manifest_version });
}

pub fn writeLocale(w: *std.Io.Writer, m: Manifest) !void {
    try check(m);
    try header(w, "defaultLocale");
    try w.print("PackageIdentifier: {s}\nPackageVersion: ", .{m.id});
    try quoted(w, m.version);
    try w.writeAll("\nPackageLocale: en-US\nPublisher: ");
    try quoted(w, m.publisher);
    if (m.homepage) |h| {
        try w.writeAll("\nPublisherUrl: ");
        try quoted(w, h);
        try w.writeAll("\nPackageUrl: ");
        try quoted(w, h);
    }
    try w.writeAll("\nPackageName: ");
    try quoted(w, m.name);
    try w.writeAll("\nLicense: ");
    try quoted(w, m.license);
    if (m.license_url) |u| {
        try w.writeAll("\nLicenseUrl: ");
        try quoted(w, u);
    }
    try w.writeAll("\nShortDescription: ");
    // WinGet caps ShortDescription at 256 characters.
    try quoted(w, m.summary[0..@min(m.summary.len, 256)]);
    if (!std.mem.eql(u8, m.description, m.summary)) {
        try w.writeAll("\nDescription: ");
        try quoted(w, m.description);
    }
    if (m.moniker) |mo| {
        try w.writeAll("\nMoniker: ");
        try quoted(w, mo);
    }
    if (m.tags.len > 0) {
        try w.writeAll("\nTags:");
        for (m.tags) |t| {
            try w.writeAll("\n- ");
            try quoted(w, t);
        }
    }
    if (m.release_notes_url) |u| {
        try w.writeAll("\nReleaseNotesUrl: ");
        try quoted(w, u);
    }
    try w.print("\nManifestType: defaultLocale\nManifestVersion: {s}\n", .{manifest_version});
}

fn upperHex(s: []const u8) [64]u8 {
    var out: [64]u8 = undefined;
    for (s[0..64], 0..) |c, i| out[i] = std.ascii.toUpper(c);
    return out;
}

test validIdentifier {
    try std.testing.expect(validIdentifier("Highercomve.GhostPen"));
    try std.testing.expect(validIdentifier("Acme.Tools.My-App"));
    try std.testing.expect(!validIdentifier("GhostPen"));
    try std.testing.expect(!validIdentifier("Acme..App"));
    try std.testing.expect(!validIdentifier("Acme.My App"));
}

test repoPath {
    const p = try repoPath(std.testing.allocator, "Highercomve.GhostPen", "0.2.6");
    defer std.testing.allocator.free(p);
    try std.testing.expectEqualStrings("manifests/h/Highercomve/GhostPen/0.2.6", p);
}

test "manifests" {
    const m: Manifest = .{
        .id = "Highercomve.GhostPen",
        .version = "0.2.6",
        .name = "GhostPen",
        .publisher = "Sergio \"S\" Marin",
        .license = "Apache-2.0",
        .summary = "AI text editing anywhere on your desktop",
        .description = "Line one.\nLine two.",
        .homepage = "https://highercomve.github.io/GhostPen/",
        .tags = &.{ "ai", "writing" },
        .product_code = "dev.ghostpen.Oriel",
        .installer_url = "https://github.com/highercomve/GhostPen/releases/download/v0.2.6/ghostpen-0.2.6-setup.exe",
        .installer_sha256 = "d8fcb56b80f6b305bb89f53fa952379a2a29b73c2a0a641e9100d5e88d71428f",
    };
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try writeInstaller(&buf.writer, m);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "InstallerType: nullsoft\nScope: user\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "InstallerSha256: D8FCB56B80F6B305") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "ProductCode: \"dev.ghostpen.Oriel\"") != null);
    buf.clearRetainingCapacity();
    try writeLocale(&buf.writer, m);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "Publisher: \"Sergio \\\"S\\\" Marin\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "Description: \"Line one.\\nLine two.\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "Tags:\n- \"ai\"\n- \"writing\"") != null);
    buf.clearRetainingCapacity();
    try writeVersion(&buf.writer, m);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "DefaultLocale: en-US\nManifestType: version") != null);

    // A portable package (the oriel CLI).
    var cli = m;
    cli.id = "Highercomve.Oriel";
    cli.commands = &.{"oriel"};
    cli.portable = &.{
        .{ .architecture = "x64", .url = "https://example.com/oriel-x86_64-windows.exe", .sha256 = m.installer_sha256 },
        .{ .architecture = "arm64", .url = "https://example.com/oriel-aarch64-windows.exe", .sha256 = m.installer_sha256 },
    };
    buf.clearRetainingCapacity();
    try writeInstaller(&buf.writer, cli);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "InstallerType: portable\nCommands:\n- \"oriel\"\nInstallers:\n- Architecture: x64") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "- Architecture: arm64\n  InstallerUrl: \"https://example.com/oriel-aarch64-windows.exe\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "ProductCode") == null);

    var bad = m;
    bad.installer_url = "http://example.com/x.exe";
    try std.testing.expectError(error.InvalidUrl, writeInstaller(&buf.writer, bad));
    bad = m;
    bad.id = "GhostPen";
    try std.testing.expectError(error.InvalidIdentifier, writeVersion(&buf.writer, bad));
}
