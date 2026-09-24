//! `oriel doctor`: check that the system can build and run Oriel apps, and
//! print the install commands for whatever is missing.

const std = @import("std");
const Context = @import("Context.zig");

pub const Command = struct {
    pub const summary = "Check that this system can build Oriel apps";
    pub const details =
        \\Required: Zig 0.16.x (on PATH, or $ORIEL_ZIG), pkg-config, the GTK 4 and
        \\WebKitGTK 6.0 development packages, Node.js (20.19+ or 22.12+) and npm
        \\for the Vite templates. Optional: packaging tools and the libraries of
        \\the input/clipboard/global_shortcut plugins. The tray host and the
        \\GlobalShortcuts portal are reported for information only.
        \\Exits with 1 when something required is missing.
    ;
};

pub const Distro = enum { pacman, apt, dnf, zypper };

/// Package names per package manager; null where it has no package.
const Packages = struct {
    pacman: ?[]const u8 = null,
    apt: ?[]const u8 = null,
    dnf: ?[]const u8 = null,
    zypper: ?[]const u8 = null,

    fn get(p: Packages, d: Distro) ?[]const u8 {
        return switch (d) {
            inline else => |tag| @field(p, @tagName(tag)),
        };
    }

    /// dnf and zypper install by pkg-config name, which is exact everywhere.
    fn pkgConfig(comptime pacman: []const u8, comptime apt: []const u8, comptime module: []const u8) Packages {
        const cap = "'pkgconfig(" ++ module ++ ")'";
        return .{ .pacman = pacman, .apt = apt, .dnf = cap, .zypper = cap };
    }
};

const Level = enum { required, optional, info };

const Item = struct {
    label: []const u8,
    level: Level,
    ok: bool,
    /// Version, path or reason.
    detail: []const u8,
    packages: Packages = .{},
    /// Shown when there is no distro package (e.g. a download URL).
    hint: ?[]const u8 = null,
};

const zig_hint = "Zig 0.16.x: https://ziglang.org/download/ (put it on PATH or set ORIEL_ZIG=/path/to/zig)";
const nfpm_hint = "nfpm: https://nfpm.goreleaser.com/install/ (or: go install github.com/goreleaser/nfpm/v2/cmd/nfpm@latest)";

pub fn run(ctx: Context) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Collected into the arena, so every string can be arena-owned.
    const c: Context = .{ .gpa = arena, .io = ctx.io, .environ = ctx.environ, .out = ctx.out, .err = ctx.err };

    var items: std.ArrayList(Item) = .empty;
    try items.append(arena, try checkZig(c));
    const pkg_config = try c.findExecutable("pkg-config");
    try items.append(arena, .{
        .label = "pkg-config",
        .level = .required,
        .ok = pkg_config != null,
        .detail = pkg_config orelse "not found",
        .packages = .{ .pacman = "pkgconf", .apt = "pkg-config", .dnf = "pkgconf-pkg-config", .zypper = "pkg-config" },
    });
    try items.append(arena, try checkLibrary(c, pkg_config, "gtk4", .required, Packages.pkgConfig("gtk4", "libgtk-4-dev", "gtk4")));
    try items.append(arena, try checkLibrary(c, pkg_config, "webkitgtk-6.0", .required, Packages.pkgConfig("webkitgtk-6.0", "libwebkitgtk-6.0-dev", "webkitgtk-6.0")));
    try items.append(arena, try checkNode(c));
    try items.append(arena, try checkTool(c, "npm", .required, &.{"--version"}, .{ .pacman = "npm", .apt = "npm", .dnf = "npm", .zypper = "npm-default" }));

    try items.append(arena, try checkNfpm(c));
    try items.append(arena, try checkTool(c, "mksquashfs", .optional, null, .{ .pacman = "squashfs-tools", .apt = "squashfs-tools", .dnf = "squashfs-tools", .zypper = "squashfs" }));
    try items.append(arena, try checkTool(c, "desktop-file-validate", .optional, null, .{ .pacman = "desktop-file-utils", .apt = "desktop-file-utils", .dnf = "desktop-file-utils", .zypper = "desktop-file-utils" }));
    try items.append(arena, try checkLibrary(c, pkg_config, "wayland-client", .optional, Packages.pkgConfig("wayland", "libwayland-dev", "wayland-client")));
    try items.append(arena, try checkLibrary(c, pkg_config, "xkbcommon", .optional, Packages.pkgConfig("libxkbcommon", "libxkbcommon-dev", "xkbcommon")));
    try items.append(arena, try checkLibrary(c, pkg_config, "xtst", .optional, Packages.pkgConfig("libxtst", "libxtst-dev", "xtst")));
    try items.append(arena, try checkLibrary(c, pkg_config, "x11", .optional, Packages.pkgConfig("libx11", "libx11-dev", "x11")));

    try items.append(arena, try checkBusName(c));
    try items.append(arena, try checkPortal(c));

    const os_release = std.Io.Dir.cwd().readFileAlloc(ctx.io, "/etc/os-release", arena, .limited(64 * 1024)) catch "";
    return report(arena, ctx.out, items.items, distroFromOsRelease(os_release));
}

fn report(gpa: std.mem.Allocator, w: *std.Io.Writer, items: []const Item, distro: ?Distro) !u8 {
    const sections = [_]struct { Level, []const u8 }{
        .{ .required, "Required" },
        .{ .optional, "Optional (packaging, plugins)" },
        .{ .info, "Desktop integration (informative)" },
    };
    var missing_required = false;
    for (sections) |section| {
        try w.print("{s}:\n", .{section[1]});
        for (items) |item| {
            if (item.level != section[0]) continue;
            const mark = if (item.ok) "ok" else if (item.level == .required) "MISSING" else "--";
            try w.print("  {s: <8} {s: <22} {s}\n", .{ mark, item.label, item.detail });
            if (!item.ok and item.level == .required) missing_required = true;
        }
    }

    for ([_]Level{ .required, .optional }) |level| {
        var any = false;
        for (items) |item| any = any or (!item.ok and item.level == level);
        if (!any) continue;
        try w.print("\nTo install the missing {s} tools:\n", .{@tagName(level)});
        const managers: []const Distro = if (distro) |d| &.{d} else std.enums.values(Distro);
        for (managers) |d| {
            var line: std.Io.Writer.Allocating = .init(gpa);
            defer line.deinit();
            for (items) |item| {
                if (item.ok or item.level != level) continue;
                if (item.packages.get(d)) |pkgs| try line.writer.print(" {s}", .{pkgs});
            }
            if (line.written().len > 0) try w.print("  {s}{s}\n", .{ installPrefix(d), line.written() });
        }
        for (items) |item| {
            if (!item.ok and item.level == level) if (item.hint) |h| try w.print("  {s}\n", .{h});
        }
    }
    if (missing_required) {
        try w.writeAll("\nSomething required is missing (see above).\n");
        return 1;
    }
    try w.writeAll("\nAll required tools are present.\n");
    return 0;
}

pub fn installPrefix(d: Distro) []const u8 {
    return switch (d) {
        .pacman => "sudo pacman -S --needed",
        .apt => "sudo apt install",
        .dnf => "sudo dnf install",
        .zypper => "sudo zypper install",
    };
}

/// The package manager of the distro described by /etc/os-release.
pub fn distroFromOsRelease(text: []const u8) ?Distro {
    var ids: [2][]const u8 = .{ "", "" };
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const value = std.mem.trim(u8, line[eq + 1 ..], "\"' \t\r");
        if (std.mem.eql(u8, line[0..eq], "ID")) ids[0] = value;
        if (std.mem.eql(u8, line[0..eq], "ID_LIKE")) ids[1] = value;
    }
    const table = [_]struct { []const u8, Distro }{
        .{ "arch", .pacman },     .{ "manjaro", .pacman }, .{ "endeavouros", .pacman },
        .{ "debian", .apt },      .{ "ubuntu", .apt },     .{ "fedora", .dnf },
        .{ "rhel", .dnf },        .{ "centos", .dnf },     .{ "suse", .zypper },
        .{ "opensuse", .zypper },
    };
    for (ids) |list| {
        var words = std.mem.tokenizeScalar(u8, list, ' ');
        while (words.next()) |word| {
            for (table) |entry| {
                if (std.mem.eql(u8, word, entry[0]) or
                    (std.mem.startsWith(u8, word, entry[0]) and word.len > entry[0].len and word[entry[0].len] == '-'))
                    return entry[1];
            }
        }
    }
    return null;
}

/// Vite 8 needs Node.js 20.19+ or 22.12+ (21.x is not supported).
pub fn nodeVersionOk(version: []const u8) bool {
    const v = std.mem.trimStart(u8, version, "v");
    var parts = std.mem.splitScalar(u8, v, '.');
    const major = std.fmt.parseInt(u32, parts.next() orelse return false, 10) catch return false;
    const minor = std.fmt.parseInt(u32, parts.next() orelse return false, 10) catch return false;
    return switch (major) {
        0...19, 21 => false,
        20 => minor >= 19,
        22 => minor >= 12,
        else => true,
    };
}

fn checkZig(c: Context) !Item {
    const name = c.zig();
    const source = if (c.environ.get("ORIEL_ZIG")) |z| (if (z.len > 0) "$ORIEL_ZIG" else "PATH") else "PATH";
    const path = try c.findExecutable(name) orelse
        return .{ .label = "zig 0.16", .level = .required, .ok = false, .detail = try std.fmt.allocPrint(c.gpa, "not found ({s})", .{source}), .hint = zig_hint };
    const out = c.capture(&.{ path, "version" }, 30_000) orelse
        return .{ .label = "zig 0.16", .level = .required, .ok = false, .detail = try std.fmt.allocPrint(c.gpa, "{s} did not run", .{path}), .hint = zig_hint };
    const ok = out.code == 0 and Context.zigVersionOk(out.text());
    return .{
        .label = "zig 0.16",
        .level = .required,
        .ok = ok,
        .detail = try std.fmt.allocPrint(c.gpa, "{s} ({s}){s}", .{ out.text(), path, if (ok) "" else ": need 0.16.x" }),
        .hint = zig_hint,
    };
}

fn checkNode(c: Context) !Item {
    const packages: Packages = .{ .pacman = "nodejs", .apt = "nodejs", .dnf = "nodejs", .zypper = "nodejs-default" };
    const path = try c.findExecutable("node") orelse
        return .{ .label = "node (Vite templates)", .level = .required, .ok = false, .detail = "not found", .packages = packages };
    const out = c.capture(&.{ path, "--version" }, 30_000) orelse
        return .{ .label = "node (Vite templates)", .level = .required, .ok = false, .detail = "did not run", .packages = packages };
    const ok = out.code == 0 and nodeVersionOk(out.text());
    return .{
        .label = "node (Vite templates)",
        .level = .required,
        .ok = ok,
        .detail = try std.fmt.allocPrint(c.gpa, "{s} ({s}){s}", .{ out.text(), path, if (ok) "" else ": need 20.19+ or 22.12+" }),
        .packages = packages,
    };
}

/// A program on PATH, with its version if `version_args` is given.
fn checkTool(c: Context, name: []const u8, level: Level, version_args: ?[]const []const u8, packages: Packages) !Item {
    const path = try c.findExecutable(name) orelse
        return .{ .label = name, .level = level, .ok = false, .detail = "not found", .packages = packages };
    var detail: []const u8 = path;
    if (version_args) |args| {
        const argv = try std.mem.concat(c.gpa, []const u8, &.{ &.{path}, args });
        if (c.capture(argv, 30_000)) |out| {
            if (out.code == 0) detail = try std.fmt.allocPrint(c.gpa, "{s} ({s})", .{ out.text(), path });
        }
    }
    return .{ .label = name, .level = level, .ok = true, .detail = detail, .packages = packages };
}

/// nfpm is also found in ~/go/bin, like the packaging step does.
fn checkNfpm(c: Context) !Item {
    var item = try checkTool(c, "nfpm", .optional, null, .{});
    item.hint = nfpm_hint;
    if (item.ok) return item;
    if (c.environ.get("HOME")) |home| {
        const go_bin = try std.fs.path.join(c.gpa, &.{ home, "go", "bin", "nfpm" });
        if (try c.findExecutable(go_bin)) |p| {
            item.ok = true;
            item.detail = p;
        }
    }
    return item;
}

/// A library's development files, through pkg-config.
fn checkLibrary(c: Context, pkg_config: ?[]const u8, module: []const u8, level: Level, packages: Packages) !Item {
    const tool = pkg_config orelse
        return .{ .label = module, .level = level, .ok = false, .detail = "unknown (needs pkg-config)", .packages = packages };
    if (c.capture(&.{ tool, "--modversion", module }, 30_000)) |out| {
        if (out.code == 0) return .{ .label = module, .level = level, .ok = true, .detail = out.text(), .packages = packages };
    }
    return .{ .label = module, .level = level, .ok = false, .detail = "development files not found", .packages = packages };
}

/// Ask the session bus with gdbus (part of GLib, so present wherever GTK is).
fn busCall(c: Context, args: []const []const u8) !?Context.Captured {
    const gdbus = try c.findExecutable("gdbus") orelse return null;
    const argv = try std.mem.concat(c.gpa, []const u8, &.{ &.{ gdbus, "call", "--session", "--timeout", "5" }, args });
    return c.capture(argv, 10_000);
}

fn checkBusName(c: Context) !Item {
    const label = "tray host";
    const out = try busCall(c, &.{
        "--dest",   "org.freedesktop.DBus",              "--object-path",                 "/org/freedesktop/DBus",
        "--method", "org.freedesktop.DBus.NameHasOwner", "org.kde.StatusNotifierWatcher",
    }) orelse return .{ .label = label, .level = .info, .ok = false, .detail = "unknown (no gdbus or session bus)" };
    const ok = out.code == 0 and std.mem.indexOf(u8, out.stdout, "true") != null;
    return .{
        .label = label,
        .level = .info,
        .ok = ok,
        .detail = if (ok) "a StatusNotifierWatcher is running" else "no StatusNotifierWatcher: tray icons won't show (GNOME: AppIndicator extension)",
    };
}

fn checkPortal(c: Context) !Item {
    const label = "global shortcuts";
    const out = try busCall(c, &.{
        "--dest",   "org.freedesktop.portal.Desktop",      "--object-path",                          "/org/freedesktop/portal/desktop",
        "--method", "org.freedesktop.DBus.Properties.Get", "org.freedesktop.portal.GlobalShortcuts", "version",
    }) orelse return .{ .label = label, .level = .info, .ok = false, .detail = "unknown (no gdbus or session bus)" };
    const ok = out.code == 0 and std.mem.indexOf(u8, out.stdout, "uint32") != null;
    return .{
        .label = label,
        .level = .info,
        .ok = ok,
        .detail = if (ok) "the GlobalShortcuts portal is available" else "no GlobalShortcuts portal: Wayland hotkeys need it (X11 works without)",
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test distroFromOsRelease {
    try testing.expectEqual(.pacman, distroFromOsRelease("NAME=\"EndeavourOS\"\nID=\"endeavouros\"\nID_LIKE=\"arch\"\n").?);
    try testing.expectEqual(.apt, distroFromOsRelease("ID=pop\nID_LIKE=\"ubuntu debian\"\n").?);
    try testing.expectEqual(.dnf, distroFromOsRelease("ID=fedora\n").?);
    try testing.expectEqual(.zypper, distroFromOsRelease("ID=\"opensuse-tumbleweed\"\nID_LIKE=\"opensuse suse\"\n").?);
    try testing.expectEqual(null, distroFromOsRelease("ID=nixos\n"));
    try testing.expectEqual(null, distroFromOsRelease(""));
}

test "version checks" {
    try testing.expect(nodeVersionOk("v24.16.0"));
    try testing.expect(nodeVersionOk("v20.19.0"));
    try testing.expect(nodeVersionOk("v22.12.1"));
    try testing.expect(!nodeVersionOk("v20.18.3"));
    try testing.expect(!nodeVersionOk("v21.7.0"));
    try testing.expect(!nodeVersionOk("v22.11.0"));
    try testing.expect(!nodeVersionOk("garbage"));
}

test "report: exit code and install commands" {
    const items = [_]Item{
        .{ .label = "zig 0.16", .level = .required, .ok = true, .detail = "0.16.0" },
        .{ .label = "gtk4", .level = .required, .ok = false, .detail = "not found", .packages = Packages.pkgConfig("gtk4", "libgtk-4-dev", "gtk4") },
        .{ .label = "webkitgtk-6.0", .level = .required, .ok = false, .detail = "not found", .packages = Packages.pkgConfig("webkitgtk-6.0", "libwebkitgtk-6.0-dev", "webkitgtk-6.0") },
        .{ .label = "nfpm", .level = .optional, .ok = false, .detail = "not found", .hint = nfpm_hint },
        .{ .label = "tray host", .level = .info, .ok = false, .detail = "none" },
    };
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(1, try report(testing.allocator, &out.writer, &items, .apt));
    const text = out.written();
    try testing.expect(std.mem.indexOf(u8, text, "  MISSING  gtk4") != null);
    try testing.expect(std.mem.indexOf(u8, text, "  sudo apt install libgtk-4-dev libwebkitgtk-6.0-dev\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, nfpm_hint) != null);
    try testing.expect(std.mem.indexOf(u8, text, "pacman") == null);

    // Unknown distro: a line for every package manager.
    out.clearRetainingCapacity();
    _ = try report(testing.allocator, &out.writer, &items, null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "sudo dnf install 'pkgconfig(gtk4)' 'pkgconfig(webkitgtk-6.0)'") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "sudo pacman -S --needed gtk4 webkitgtk-6.0") != null);

    // Only optional/informative things missing: success.
    out.clearRetainingCapacity();
    try testing.expectEqual(0, try report(testing.allocator, &out.writer, items[3..], .pacman));
}
