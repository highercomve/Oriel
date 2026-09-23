//! NFPM configuration generator for building Debian (.deb) and RPM (.rpm) packages.

const std = @import("std");
const icons = @import("icons.zig");

pub const NfpmOptions = struct {
    name: []const u8,
    version: []const u8,
    arch: []const u8,
    maintainer: []const u8,
    description: []const u8,
    homepage: ?[]const u8 = null,
    license: ?[]const u8 = null,
    binary_src: []const u8,
    binary_name: []const u8,
    desktop_src: []const u8,
    app_id: []const u8,
    icons_dir: []const u8,
    deb_depends: []const []const u8 = &.{},
    rpm_depends: []const []const u8 = &.{},
};

/// Generate nfpm.yaml content for building deb and rpm packages.
pub fn generateNfpmYaml(allocator: std.mem.Allocator, opts: NfpmOptions) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;

    try w.print("name: \"{s}\"\n", .{opts.name});
    try w.print("arch: \"{s}\"\n", .{opts.arch});
    try w.writeAll("platform: \"linux\"\n");
    try w.print("version: \"{s}\"\n", .{opts.version});
    try w.writeAll("section: \"default\"\n");
    try w.writeAll("priority: \"optional\"\n");
    try w.print("maintainer: \"{s}\"\n", .{opts.maintainer});
    try w.writeAll("description: |\n");
    // Indent description by 2 spaces
    var line_it = std.mem.splitScalar(u8, opts.description, '\n');
    while (line_it.next()) |line| {
        try w.print("  {s}\n", .{line});
    }
    if (opts.homepage) |hp| {
        try w.print("homepage: \"{s}\"\n", .{hp});
    }
    if (opts.license) |lic| {
        try w.print("license: \"{s}\"\n", .{lic});
    }

    try w.writeAll("contents:\n");
    try w.print("  - src: \"{s}\"\n", .{opts.binary_src});
    try w.print("    dst: \"/usr/bin/{s}\"\n", .{opts.binary_name});
    try w.writeAll("    file_info:\n      mode: 0755\n");

    try w.print("  - src: \"{s}\"\n", .{opts.desktop_src});
    try w.print("    dst: \"/usr/share/applications/{s}.desktop\"\n", .{opts.app_id});
    try w.writeAll("    file_info:\n      mode: 0644\n");

    inline for (icons.icon_sizes) |size| {
        try w.print("  - src: \"{s}/{d}x{d}.png\"\n", .{ opts.icons_dir, size, size });
        try w.print("    dst: \"/usr/share/icons/hicolor/{d}x{d}/apps/{s}.png\"\n", .{ size, size, opts.app_id });
        try w.writeAll("    file_info:\n      mode: 0644\n");
    }

    try w.writeAll("overrides:\n");
    try w.writeAll("  deb:\n    depends:\n");
    for (opts.deb_depends) |dep| {
        try w.print("      - {s}\n", .{dep});
    }

    try w.writeAll("  rpm:\n    depends:\n");
    for (opts.rpm_depends) |dep| {
        try w.print("      - {s}\n", .{dep});
    }

    return try allocator.dupe(u8, out.written());
}

test "generateNfpmYaml with optional metadata" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const deb_deps = [_][]const u8{ "libgtk-4-1", "libwebkitgtk-6.0-4" };
    const rpm_deps = [_][]const u8{ "gtk4", "webkitgtk6.0" };

    const yaml = try generateNfpmYaml(gpa, .{
        .name = "oriel-react-notes",
        .version = "0.1.0",
        .arch = "amd64",
        .maintainer = "Oriel Team <team@oriel.dev>",
        .description = "A great notes app\nwith multiple lines",
        .homepage = "https://example.com",
        .license = "MIT",
        .binary_src = "/path/to/bin",
        .binary_name = "oriel-react-notes",
        .desktop_src = "/path/to/desktop",
        .app_id = "dev.oriel.ReactNotes",
        .icons_dir = "/path/to/icons",
        .deb_depends = &deb_deps,
        .rpm_depends = &rpm_deps,
    });
    defer gpa.free(yaml);

    try testing.expect(std.mem.indexOf(u8, yaml, "name: \"oriel-react-notes\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, yaml, "arch: \"amd64\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, yaml, "homepage: \"https://example.com\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, yaml, "license: \"MIT\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, yaml, "dst: \"/usr/bin/oriel-react-notes\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, yaml, "dst: \"/usr/share/applications/dev.oriel.ReactNotes.desktop\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, yaml, "- libgtk-4-1\n") != null);
    try testing.expect(std.mem.indexOf(u8, yaml, "- gtk4\n") != null);
}

test "generateNfpmYaml without optional metadata" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const yaml = try generateNfpmYaml(gpa, .{
        .name = "oriel-react-notes",
        .version = "0.1.0",
        .arch = "amd64",
        .maintainer = "Oriel React Notes",
        .description = "A great notes app",
        .homepage = null,
        .license = null,
        .binary_src = "/path/to/bin",
        .binary_name = "oriel-react-notes",
        .desktop_src = "/path/to/desktop",
        .app_id = "dev.oriel.ReactNotes",
        .icons_dir = "/path/to/icons",
    });
    defer gpa.free(yaml);

    try testing.expect(std.mem.indexOf(u8, yaml, "homepage:") == null);
    try testing.expect(std.mem.indexOf(u8, yaml, "license:") == null);
    try testing.expect(std.mem.indexOf(u8, yaml, "maintainer: \"Oriel React Notes\"\n") != null);
}
