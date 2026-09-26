//! NFPM configuration generator for building Debian (.deb) and RPM (.rpm) packages.

const std = @import("std");
const icons = @import("icons.zig");
const metadata = @import("metadata.zig");
const contents = @import("contents.zig");

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
    /// Other executables, installed next to the app's (see below).
    extra_exes: []const contents.Exe = &.{},
    /// Files installed at their path relative to the app's executable.
    extra_files: []const contents.File = &.{},
};

/// Where the app's executable goes. Alone it is `/usr/bin/<binary>`; with
/// extra executables or files everything goes into `/usr/lib/<name>/` and
/// `/usr/bin` gets symlinks to the executables: the programs find their
/// companions next to their own (symlink-resolved) path.
pub fn exeDir(allocator: std.mem.Allocator, opts: NfpmOptions) ![]u8 {
    if (opts.extra_exes.len == 0 and opts.extra_files.len == 0) return allocator.dupe(u8, "/usr/bin");
    return std.fmt.allocPrint(allocator, "/usr/lib/{s}", .{opts.name});
}

/// Generate nfpm.yaml content for building deb and rpm packages.
pub fn generateNfpmYaml(allocator: std.mem.Allocator, opts: NfpmOptions) ![]const u8 {
    try metadata.validateExeName(opts.name);
    try metadata.validateExeName(opts.binary_name);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;

    const esc_name = try metadata.escapeYamlScalar(allocator, opts.name);
    defer allocator.free(esc_name);
    try w.print("name: \"{s}\"\n", .{esc_name});

    const esc_arch = try metadata.escapeYamlScalar(allocator, opts.arch);
    defer allocator.free(esc_arch);
    try w.print("arch: \"{s}\"\n", .{esc_arch});

    try w.writeAll("platform: \"linux\"\n");

    const esc_ver = try metadata.escapeYamlScalar(allocator, opts.version);
    defer allocator.free(esc_ver);
    try w.print("version: \"{s}\"\n", .{esc_ver});

    try w.writeAll("section: \"default\"\n");
    try w.writeAll("priority: \"optional\"\n");

    const esc_maint = try metadata.escapeYamlScalar(allocator, opts.maintainer);
    defer allocator.free(esc_maint);
    try w.print("maintainer: \"{s}\"\n", .{esc_maint});

    try w.writeAll("description: |\n");
    // Indent description by 2 spaces
    var line_it = std.mem.splitScalar(u8, opts.description, '\n');
    while (line_it.next()) |line| {
        try metadata.validateNoControlChars(line);
        try w.print("  {s}\n", .{line});
    }

    if (opts.homepage) |hp| {
        const esc_hp = try metadata.escapeYamlScalar(allocator, hp);
        defer allocator.free(esc_hp);
        try w.print("homepage: \"{s}\"\n", .{esc_hp});
    }
    if (opts.license) |lic| {
        const esc_lic = try metadata.escapeYamlScalar(allocator, lic);
        defer allocator.free(esc_lic);
        try w.print("license: \"{s}\"\n", .{esc_lic});
    }

    const esc_bin_src = try metadata.escapeYamlScalar(allocator, opts.binary_src);
    defer allocator.free(esc_bin_src);
    const esc_bin_name = try metadata.escapeYamlScalar(allocator, opts.binary_name);
    defer allocator.free(esc_bin_name);
    const esc_desktop_src = try metadata.escapeYamlScalar(allocator, opts.desktop_src);
    defer allocator.free(esc_desktop_src);
    const esc_app_id = try metadata.escapeYamlScalar(allocator, opts.app_id);
    defer allocator.free(esc_app_id);
    const esc_icons_dir = try metadata.escapeYamlScalar(allocator, opts.icons_dir);
    defer allocator.free(esc_icons_dir);

    // exeDir is built from validated names: nothing to escape.
    const exe_dir = try exeDir(allocator, opts);
    defer allocator.free(exe_dir);
    const split = !std.mem.eql(u8, exe_dir, "/usr/bin");

    try w.writeAll("contents:\n");
    try w.print("  - src: \"{s}\"\n", .{esc_bin_src});
    try w.print("    dst: \"{s}/{s}\"\n", .{ exe_dir, esc_bin_name });
    try w.writeAll("    file_info:\n      mode: 0755\n");
    if (split) try writeBinLink(w, exe_dir, esc_bin_name);

    for (opts.extra_exes) |e| {
        try metadata.validateExeName(e.name);
        const esc_src = try metadata.escapeYamlScalar(allocator, e.src);
        defer allocator.free(esc_src);
        try w.print("  - src: \"{s}\"\n", .{esc_src});
        try w.print("    dst: \"{s}/{s}\"\n", .{ exe_dir, e.name });
        try w.writeAll("    file_info:\n      mode: 0755\n");
        try writeBinLink(w, exe_dir, e.name);
    }
    for (opts.extra_files) |f| {
        try metadata.validateRelativePath(f.rel);
        const esc_src = try metadata.escapeYamlScalar(allocator, f.src);
        defer allocator.free(esc_src);
        const esc_rel = try metadata.escapeYamlScalar(allocator, f.rel);
        defer allocator.free(esc_rel);
        try w.print("  - src: \"{s}\"\n", .{esc_src});
        try w.print("    dst: \"{s}/{s}\"\n", .{ exe_dir, esc_rel });
        try w.writeAll("    file_info:\n      mode: 0644\n");
    }

    try w.print("  - src: \"{s}\"\n", .{esc_desktop_src});
    try w.print("    dst: \"/usr/share/applications/{s}.desktop\"\n", .{esc_app_id});
    try w.writeAll("    file_info:\n      mode: 0644\n");

    inline for (icons.icon_sizes) |size| {
        try w.print("  - src: \"{s}/{d}x{d}.png\"\n", .{ esc_icons_dir, size, size });
        try w.print("    dst: \"/usr/share/icons/hicolor/{d}x{d}/apps/{s}.png\"\n", .{ size, size, esc_app_id });
        try w.writeAll("    file_info:\n      mode: 0644\n");
    }

    try w.writeAll("overrides:\n");
    try w.writeAll("  deb:\n    depends:\n");
    for (opts.deb_depends) |dep| {
        const esc_dep = try metadata.escapeYamlScalar(allocator, dep);
        defer allocator.free(esc_dep);
        try w.print("      - \"{s}\"\n", .{esc_dep});
    }

    try w.writeAll("  rpm:\n    depends:\n");
    for (opts.rpm_depends) |dep| {
        const esc_dep = try metadata.escapeYamlScalar(allocator, dep);
        defer allocator.free(esc_dep);
        try w.print("      - \"{s}\"\n", .{esc_dep});
    }

    return try allocator.dupe(u8, out.written());
}

/// `/usr/bin/<name>` -> `<exe_dir>/<name>`.
fn writeBinLink(w: *std.Io.Writer, exe_dir: []const u8, name: []const u8) !void {
    try w.print("  - src: \"{s}/{s}\"\n", .{ exe_dir, name });
    try w.print("    dst: \"/usr/bin/{s}\"\n", .{name});
    try w.writeAll("    type: symlink\n");
}

test "generateNfpmYaml with extra executables and files" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const yaml = try generateNfpmYaml(gpa, .{
        .name = "ghostpen",
        .version = "0.1.0",
        .arch = "amd64",
        .maintainer = "GhostPen",
        .description = "Notes",
        .binary_src = "/cache/ghostpen",
        .binary_name = "ghostpen",
        .desktop_src = "/cache/app.desktop",
        .app_id = "dev.ghostpen.App",
        .icons_dir = "/cache/icons",
        .extra_exes = &.{.{ .src = "/cache/s/ghostpen-cli", .name = "ghostpen-cli" }},
        .extra_files = &.{
            .{ .rel = "libggml-cuda.so", .src = "/cache/libggml-cuda.so" },
            .{ .rel = "data/model v2.bin", .src = "/m.bin" },
        },
    });
    defer gpa.free(yaml);

    try testing.expect(std.mem.indexOf(u8, yaml,
        \\  - src: "/cache/ghostpen"
        \\    dst: "/usr/lib/ghostpen/ghostpen"
        \\    file_info:
        \\      mode: 0755
        \\  - src: "/usr/lib/ghostpen/ghostpen"
        \\    dst: "/usr/bin/ghostpen"
        \\    type: symlink
        \\  - src: "/cache/s/ghostpen-cli"
        \\    dst: "/usr/lib/ghostpen/ghostpen-cli"
        \\    file_info:
        \\      mode: 0755
        \\  - src: "/usr/lib/ghostpen/ghostpen-cli"
        \\    dst: "/usr/bin/ghostpen-cli"
        \\    type: symlink
        \\  - src: "/cache/libggml-cuda.so"
        \\    dst: "/usr/lib/ghostpen/libggml-cuda.so"
        \\    file_info:
        \\      mode: 0644
        \\
    ) != null);
    try testing.expect(std.mem.indexOf(u8, yaml, "dst: \"/usr/lib/ghostpen/data/model v2.bin\"\n    file_info:\n      mode: 0644\n") != null);
    try testing.expect(std.mem.indexOf(u8, yaml, "dst: \"/usr/bin/ghostpen\"\n    file_info") == null);

    // Unsafe destinations are refused.
    try testing.expectError(error.InvalidRelativePath, generateNfpmYaml(gpa, .{
        .name = "ghostpen",
        .version = "0.1.0",
        .arch = "amd64",
        .maintainer = "GhostPen",
        .description = "Notes",
        .binary_src = "/b",
        .binary_name = "ghostpen",
        .desktop_src = "/d",
        .app_id = "dev.ghostpen.App",
        .icons_dir = "/i",
        .extra_files = &.{.{ .rel = "../../etc/cron.d/x", .src = "/x" }},
    }));
    try testing.expectError(error.InvalidExeName, generateNfpmYaml(gpa, .{
        .name = "ghostpen",
        .version = "0.1.0",
        .arch = "amd64",
        .maintainer = "GhostPen",
        .description = "Notes",
        .binary_src = "/b",
        .binary_name = "ghostpen",
        .desktop_src = "/d",
        .app_id = "dev.ghostpen.App",
        .icons_dir = "/i",
        .extra_exes = &.{.{ .src = "/x/a b", .name = "a b" }},
    }));
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
    // No extras: the historical layout, no /usr/lib directory or symlinks.
    try testing.expect(std.mem.indexOf(u8, yaml, "/usr/lib/") == null);
    try testing.expect(std.mem.indexOf(u8, yaml, "type: symlink") == null);
    try testing.expect(std.mem.indexOf(u8, yaml, "dst: \"/usr/share/applications/dev.oriel.ReactNotes.desktop\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, yaml, "- \"libgtk-4-1\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, yaml, "- \"gtk4\"\n") != null);
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

test "generateNfpmYaml rejects invalid metadata" {
    const testing = std.testing;
    const gpa = testing.allocator;

    // Invalid exe name
    try testing.expectError(error.InvalidExeName, generateNfpmYaml(gpa, .{
        .name = "-invalid-name",
        .version = "0.1.0",
        .arch = "amd64",
        .maintainer = "Test",
        .description = "Test",
        .binary_src = "/bin",
        .binary_name = "test",
        .desktop_src = "/desk",
        .app_id = "test",
        .icons_dir = "/icons",
    }));

    // Newline in scalar
    try testing.expectError(error.ContainsNewline, generateNfpmYaml(gpa, .{
        .name = "valid-name",
        .version = "0.1.0",
        .arch = "amd64",
        .maintainer = "Test\nInjected",
        .description = "Test",
        .binary_src = "/bin",
        .binary_name = "test",
        .desktop_src = "/desk",
        .app_id = "test",
        .icons_dir = "/icons",
    }));
}
