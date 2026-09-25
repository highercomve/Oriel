//! `oriel doctor`: check that the system can build and run Oriel apps, and
//! print the install commands for whatever is missing.

const std = @import("std");
const builtin = @import("builtin");
const Context = @import("Context.zig");
const project = @import("project.zig");
const webview2 = @import("webview2.zig");
const zig_manager = @import("zig_manager.zig");
const setup = @import("setup.zig");

pub const Command = struct {
    fix: bool = false,
    yes: bool = false,

    pub const summary = "Check that this system can build Oriel apps";
    pub const help = .{
        .fix = "Install missing non-admin tools and print admin commands",
        .yes = "Skip confirmation prompt for --fix",
    };
    pub const details =
        \\Required everywhere: Zig 0.16.x (on PATH, or $ORIEL_ZIG), Node.js
        \\(20.19+ or 22.12+) and npm for the Vite templates.
        \\Linux: pkg-config and the GTK 4 and WebKitGTK 6.0 development packages;
        \\optional packaging tools and plugin libraries; the tray host and the
        \\GlobalShortcuts portal are reported for information only.
        \\macOS: the Xcode command-line tools (Apple SDK).
        \\Windows: the WebView2 runtime; NSIS (makensis) for installers.
        \\Options:
        \\  --fix     Install missing non-admin tools and print admin commands
        \\  --yes     Skip confirmation prompt for --fix
        \\Exits with 1 when something required is missing.
    ;
};

/// A package manager: the Linux distro's, Homebrew on macOS, winget on Windows.
pub const Distro = enum { pacman, apt, dnf, zypper, brew, winget };

pub const linux_managers = [_]Distro{ .pacman, .apt, .dnf, .zypper };

/// Package names per package manager; null where it has no package.
pub const Packages = struct {
    pacman: ?[]const u8 = null,
    apt: ?[]const u8 = null,
    dnf: ?[]const u8 = null,
    zypper: ?[]const u8 = null,
    brew: ?[]const u8 = null,
    winget: ?[]const u8 = null,

    pub fn get(p: Packages, d: Distro) ?[]const u8 {
        return switch (d) {
            inline else => |tag| @field(p, @tagName(tag)),
        };
    }

    /// dnf and zypper install by pkg-config name, which is exact everywhere.
    pub fn pkgConfig(comptime pacman: []const u8, comptime apt: []const u8, comptime module: []const u8) Packages {
        const cap = "'pkgconfig(" ++ module ++ ")'";
        return .{ .pacman = pacman, .apt = apt, .dnf = cap, .zypper = cap };
    }
};

pub const Level = enum { required, optional, info };

pub const Item = struct {
    label: []const u8,
    level: Level,
    ok: bool,
    /// Version, path or reason.
    detail: []const u8,
    packages: Packages = .{},
    /// Shown when there is no distro package (e.g. a download URL).
    hint: ?[]const u8 = null,
};

const zig_hint = "`oriel zig install` (into ~/.oriel/zig), or Zig from https://ziglang.org/download/ on PATH or in ORIEL_ZIG";
const xcode_hint = "Xcode command-line tools: xcode-select --install (or install Xcode)";
const webview2_hint = "WebView2 runtime: https://developer.microsoft.com/microsoft-edge/webview2/ (preinstalled on Windows 11)";
const node_hint = "`oriel setup node` (into ~/.oriel/node), or Node.js from https://nodejs.org/";
const nsis_hint = "`oriel setup nsis` (into ~/.oriel/nsis), or NSIS from https://nsis.sourceforge.io/";
const node_packages: Packages = .{ .pacman = "nodejs", .apt = "nodejs", .dnf = "nodejs", .zypper = "nodejs-default", .brew = "node", .winget = "OpenJS.NodeJS.LTS" };
const npm_packages: Packages = .{ .pacman = "npm", .apt = "npm", .dnf = "npm", .zypper = "npm-default", .brew = "node", .winget = "OpenJS.NodeJS.LTS" };
const nfpm_hint = "nfpm: https://nfpm.goreleaser.com/install/ (or: go install github.com/goreleaser/nfpm/v2/cmd/nfpm@latest)";

pub const FixPlan = struct {
    install_zig: bool = false,
    install_node: bool = false,
    install_webview2: bool = false,
    install_nsis: bool = false,
    admin_commands: []const []const u8 = &.{},

    pub fn fixableCount(self: FixPlan) usize {
        var count: usize = 0;
        if (self.install_zig) count += 1;
        if (self.install_node) count += 1;
        if (self.install_webview2) count += 1;
        if (self.install_nsis) count += 1;
        return count;
    }

    pub fn isEmpty(self: FixPlan) bool {
        return self.fixableCount() == 0 and self.admin_commands.len == 0;
    }

    pub fn deinit(self: FixPlan, allocator: std.mem.Allocator) void {
        for (self.admin_commands) |cmd| allocator.free(cmd);
        allocator.free(self.admin_commands);
    }
};

pub fn run(ctx: Context, cmd: Command) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Collected into the arena, so every string can be arena-owned.
    const c: Context = .{ .gpa = arena, .io = ctx.io, .environ = ctx.environ, .out = ctx.out, .err = ctx.err };

    var items: std.ArrayList(Item) = .empty;
    const want_zig = try zig_manager.requiredHere(c);
    const zig_check = try checkZig(c, want_zig);
    try items.append(arena, zig_check.item);

    const node_req = detectNodeRequirement(arena, ctx.io, null);

    switch (builtin.os.tag) {
        .macos => {
            try items.append(arena, try checkXcode(c));
            try items.append(arena, try checkNode(c, node_req));
            try items.append(arena, try checkToolNamed(c, node_req.npm_label, "npm", node_req.level, &.{"--version"}, npm_packages));
            try items.append(arena, try checkCachedWebView2Loader(c, false));
        },
        .windows => {
            try items.append(arena, try checkWebView2(c));
            try items.append(arena, try checkNode(c, node_req));
            try items.append(arena, try checkToolNamed(c, node_req.npm_label, "npm", node_req.level, &.{"--version"}, npm_packages));
            try items.append(arena, try checkMakensis(c));
            try items.append(arena, try checkCachedWebView2Loader(c, true));
        },
        else => {
            const pkg_config = try c.findExecutable("pkg-config");
            try items.append(arena, .{
                .label = "pkg-config",
                .level = .required,
                .ok = pkg_config != null,
                .detail = pkg_config orelse "not found",
                .packages = .{ .pacman = "pkgconf", .apt = "pkg-config", .dnf = "pkgconf-pkg-config", .zypper = "pkg-config" },
            });
            try items.append(arena, try checkLibrary(c, pkg_config, "gtk4", .required, .{
                .pacman = "gtk4",
                .apt = "libgtk-4-dev",
                .dnf = "gtk4-devel",
                .zypper = "gtk4-devel",
            }));
            try items.append(arena, try checkLibrary(c, pkg_config, "webkitgtk-6.0", .required, .{
                .pacman = "webkitgtk-6.0",
                .apt = "libwebkitgtk-6.0-dev",
                .dnf = "webkitgtk6.0-devel",
                .zypper = "webkitgtk-6_0-devel",
            }));
            try items.append(arena, try checkNode(c, node_req));
            try items.append(arena, try checkToolNamed(c, node_req.npm_label, "npm", node_req.level, &.{"--version"}, npm_packages));

            try items.append(arena, try checkNfpm(c));
            try items.append(arena, try checkTool(c, "mksquashfs", .optional, null, .{ .pacman = "squashfs-tools", .apt = "squashfs-tools", .dnf = "squashfs-tools", .zypper = "squashfs" }));
            try items.append(arena, try checkTool(c, "desktop-file-validate", .optional, null, .{ .pacman = "desktop-file-utils", .apt = "desktop-file-utils", .dnf = "desktop-file-utils", .zypper = "desktop-file-utils" }));
            try items.append(arena, try checkLibrary(c, pkg_config, "wayland-client", .optional, Packages.pkgConfig("wayland", "libwayland-dev", "wayland-client")));
            try items.append(arena, try checkLibrary(c, pkg_config, "xkbcommon", .optional, Packages.pkgConfig("libxkbcommon", "libxkbcommon-dev", "xkbcommon")));
            try items.append(arena, try checkLibrary(c, pkg_config, "xtst", .optional, Packages.pkgConfig("libxtst", "libxtst-dev", "xtst")));
            try items.append(arena, try checkLibrary(c, pkg_config, "x11", .optional, Packages.pkgConfig("libx11", "libx11-dev", "x11")));

            try items.append(arena, try checkBusName(c));
            try items.append(arena, try checkPortal(c));
            try items.append(arena, try checkCachedWebView2Loader(c, false));
        },
    }

    const os_release = std.Io.Dir.cwd().readFileAlloc(ctx.io, "/etc/os-release", arena, .limited(64 * 1024)) catch "";
    const distro: ?Distro = switch (builtin.os.tag) {
        .macos => .brew,
        .windows => .winget,
        else => distroFromOsRelease(os_release),
    };

    const plan = try calculateFixPlan(arena, items.items, builtin.os.tag, distro, zig_check.needs_install);

    if (cmd.fix) {
        return runFix(ctx, cmd, items.items, plan, want_zig);
    }

    return report(arena, ctx.out, items.items, distro, plan.fixableCount());
}

fn report(gpa: std.mem.Allocator, w: *std.Io.Writer, items: []const Item, distro: ?Distro, fixable_count: usize) !u8 {
    const sections = [_]struct { Level, []const u8 }{
        .{ .required, "Required" },
        .{ .optional, "Optional (packaging, plugins)" },
        .{ .info, "Desktop integration (informative)" },
    };
    var missing_required = false;
    for (sections) |section| {
        for (items) |item| {
            if (item.level == section[0]) break;
        } else continue; // nothing to report in this section here
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
        const managers: []const Distro = if (distro) |d| &.{d} else &linux_managers;
        for (managers) |d| {
            // Each package once (node and npm share one on brew and winget).
            var pkgs: std.ArrayList([]const u8) = .empty;
            defer pkgs.deinit(gpa);
            for (items) |item| {
                if (item.ok or item.level != level) continue;
                const p = item.packages.get(d) orelse continue;
                for (pkgs.items) |seen| {
                    if (std.mem.eql(u8, seen, p)) break;
                } else try pkgs.append(gpa, p);
            }
            if (pkgs.items.len == 0) continue;
            if (d == .winget) {
                // winget installs one id per command.
                for (pkgs.items) |p| try w.print("  {s} {s}\n", .{ installPrefix(d), p });
                try w.writeAll("  Open a new terminal so PATH updates\n");
            } else {
                try w.print("  {s}", .{installPrefix(d)});
                for (pkgs.items) |p| try w.print(" {s}", .{p});
                try w.writeByte('\n');
            }
        }
        for (items) |item| {
            if (!item.ok and item.level == level) if (item.hint) |h| try w.print("  {s}\n", .{h});
        }
        var has_managed_hint = false;
        for (items) |item| {
            if (!item.ok and item.level == level) {
                if (item.hint) |h| {
                    if (std.mem.indexOf(u8, h, "~/.oriel") != null or std.mem.indexOf(u8, h, "oriel setup") != null) {
                        has_managed_hint = true;
                    }
                }
            }
        }
        if (has_managed_hint) {
            try w.writeAll("  (managed tools under ~/.oriel are used automatically by oriel; no PATH change needed)\n");
        }
    }
    if (missing_required) {
        try w.writeAll("\nSomething required is missing (see above).\n");
        if (fixable_count > 0) {
            try w.print("Run `oriel doctor --fix` to install {d} missing tool{s}.\n", .{ fixable_count, if (fixable_count == 1) "" else "s" });
        }
        return 1;
    }
    try w.writeAll("\nAll required tools are present.\n");
    if (fixable_count > 0) {
        try w.print("Run `oriel doctor --fix` to install {d} missing tool{s}.\n", .{ fixable_count, if (fixable_count == 1) "" else "s" });
    }
    return 0;
}

fn runFix(ctx: Context, cmd: Command, items: []const Item, plan: FixPlan, want_zig: []const u8) !u8 {
    if (plan.isEmpty()) {
        try ctx.out.writeAll("All required tools are already installed.\n");
        return 0;
    }

    if (plan.fixableCount() > 0) {
        try ctx.out.writeAll("The following tools can be installed automatically without admin rights:\n");
        if (plan.install_zig) try ctx.out.print("  - zig {s} (into ~/.oriel/zig)\n", .{want_zig});
        if (plan.install_node) try ctx.out.writeAll("  - node (into ~/.oriel/node)\n");
        if (plan.install_webview2) try ctx.out.writeAll("  - WebView2 loader (into cache)\n");
        if (plan.install_nsis) try ctx.out.writeAll("  - nsis (into ~/.oriel/nsis)\n");

        const stdin_file = std.Io.File.stdin();
        const is_tty = stdin_file.isTty(ctx.io) catch false;

        if (!cmd.yes) {
            if (!is_tty) {
                try ctx.err.writeAll("error: non-interactive terminal requires --yes to install tools\n");
                return 1;
            }

            try ctx.out.print("Install {d} missing tool{s}? [y/N] ", .{
                plan.fixableCount(),
                if (plan.fixableCount() == 1) "" else "s",
            });
            ctx.flush();

            var line_buf: [64]u8 = undefined;
            var line_reader = stdin_file.readerStreaming(ctx.io, &line_buf);
            var ans_buf: [16]u8 = undefined;
            const n = line_reader.interface.readSliceShort(&ans_buf) catch 0;
            const trimmed = std.mem.trim(u8, ans_buf[0..n], " \t\r\n");
            if (!std.ascii.eqlIgnoreCase(trimmed, "y") and !std.ascii.eqlIgnoreCase(trimmed, "yes")) {
                try ctx.out.writeAll("Installation cancelled.\n");
                return 0;
            }
        }

        var installed_any_managed = false;
        if (plan.install_zig) {
            try ctx.out.writeAll("Installing zig...\n");
            ctx.flush();
            _ = try zig_manager.run(ctx, .{ .action = .install, .version = null });
            installed_any_managed = true;
        }
        if (plan.install_node) {
            try ctx.out.writeAll("Installing node...\n");
            ctx.flush();
            const node_path = try setup.installNode(ctx, null);
            ctx.gpa.free(node_path);
            installed_any_managed = true;
        }
        if (plan.install_webview2) {
            try ctx.out.writeAll("Downloading WebView2 loader...\n");
            ctx.flush();
            _ = try webview2.run(ctx, .{});
            installed_any_managed = true;
        }
        if (plan.install_nsis) {
            try ctx.out.writeAll("Installing nsis...\n");
            ctx.flush();
            const res = try setup.installNsis(ctx);
            switch (res) {
                .installed => |p| {
                    ctx.gpa.free(p);
                    installed_any_managed = true;
                },
                .printed_package_command => {},
            }
        }
        if (installed_any_managed) {
            try ctx.out.writeAll("Managed tools under ~/.oriel are used automatically by oriel (no PATH change needed).\n");
        }
    }

    if (plan.admin_commands.len > 0) {
        try ctx.out.writeAll("\nThe following dependencies require administrator / root rights to install:\n");
        for (plan.admin_commands) |admin_cmd| {
            try ctx.out.print("  {s}\n", .{admin_cmd});
        }
        return 1;
    }

    for (items) |item| {
        if (!item.ok and item.level == .required) {
            if (std.mem.startsWith(u8, item.label, "node") and plan.install_node) continue;
            if (std.mem.startsWith(u8, item.label, "npm") and plan.install_node) continue;
            if (std.mem.startsWith(u8, item.label, "zig") and plan.install_zig) continue;
            if (std.mem.eql(u8, item.label, "WebView2 loader") and plan.install_webview2) continue;
            return 1;
        }
    }

    try ctx.out.writeAll("\nAll required tools are installed and ready.\n");
    return 0;
}

pub fn installPrefix(d: Distro) []const u8 {
    return switch (d) {
        .pacman => "sudo pacman -S --needed",
        .apt => "sudo apt install",
        .dnf => "sudo dnf install",
        .zypper => "sudo zypper install",
        .brew => "brew install",
        .winget => "winget install --id",
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

/// Generate distro package install command for missing required packages (excluding managed tools).
pub fn generateDistroAdminCommand(allocator: std.mem.Allocator, distro: Distro, items: []const Item) !?[]const u8 {
    var pkgs: std.ArrayList([]const u8) = .empty;
    defer pkgs.deinit(allocator);

    for (items) |item| {
        if (item.ok or item.level != .required) continue;
        if (std.mem.startsWith(u8, item.label, "node") or
            std.mem.startsWith(u8, item.label, "npm") or
            std.mem.startsWith(u8, item.label, "zig")) continue;

        const p = item.packages.get(distro) orelse continue;
        for (pkgs.items) |seen| {
            if (std.mem.eql(u8, seen, p)) break;
        } else try pkgs.append(allocator, p);
    }

    if (pkgs.items.len == 0) return null;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, installPrefix(distro));
    for (pkgs.items) |p| {
        try out.append(allocator, ' ');
        try out.appendSlice(allocator, p);
    }
    return try out.toOwnedSlice(allocator);
}

/// Pure function to calculate the doctor fix plan.
pub fn calculateFixPlan(
    allocator: std.mem.Allocator,
    items: []const Item,
    host_os: std.Target.Os.Tag,
    distro: ?Distro,
    zig_needs_install: bool,
) !FixPlan {
    var plan = FixPlan{};

    if (zig_needs_install) {
        plan.install_zig = true;
    } else {
        for (items) |item| {
            if (!item.ok and std.mem.startsWith(u8, item.label, "zig")) {
                plan.install_zig = true;
                break;
            }
        }
    }

    for (items) |item| {
        if (!item.ok and (std.mem.startsWith(u8, item.label, "node") or std.mem.startsWith(u8, item.label, "npm"))) {
            plan.install_node = true;
        }
        // Only a Windows host needs the loader; elsewhere it is info (cross-builds fetch it).
        if (!item.ok and item.level == .required and std.mem.eql(u8, item.label, "WebView2 loader")) {
            plan.install_webview2 = true;
        }
        if (host_os == .windows and !item.ok and std.mem.eql(u8, item.label, "makensis")) {
            plan.install_nsis = true;
        }
    }

    var admin_cmds: std.ArrayList([]const u8) = .empty;
    defer admin_cmds.deinit(allocator);

    switch (host_os) {
        .macos => {
            for (items) |item| {
                if (!item.ok and std.mem.eql(u8, item.label, "Xcode CLI tools")) {
                    try admin_cmds.append(allocator, try allocator.dupe(u8, "xcode-select --install"));
                }
            }
        },
        .windows => {
            for (items) |item| {
                if (!item.ok and std.mem.eql(u8, item.label, "WebView2 runtime")) {
                    try admin_cmds.append(allocator, try allocator.dupe(u8, "Install WebView2 runtime: https://developer.microsoft.com/microsoft-edge/webview2/"));
                }
            }
        },
        else => {
            if (distro) |d| {
                if (try generateDistroAdminCommand(allocator, d, items)) |cmd_str| {
                    try admin_cmds.append(allocator, cmd_str);
                }
            } else {
                for (linux_managers) |d| {
                    if (try generateDistroAdminCommand(allocator, d, items)) |cmd_str| {
                        try admin_cmds.append(allocator, cmd_str);
                    }
                }
            }
        },
    }

    plan.admin_commands = try admin_cmds.toOwnedSlice(allocator);
    return plan;
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

const ZigCheck = struct {
    item: Item,
    needs_install: bool,
};

/// The Zig the current project (or a new one) uses: where it comes from
/// (ORIEL_ZIG, PATH, managed in ~/.oriel/zig) or that it would be installed.
fn checkZig(c: Context, want: []const u8) !ZigCheck {
    const label = try std.fmt.allocPrint(c.gpa, "zig {s}", .{want});
    const p = zig_manager.plan(c, want) catch |err| switch (err) {
        error.OrielZigMismatch => return .{
            .item = .{ .label = label, .level = .required, .ok = false, .detail = try std.fmt.allocPrint(c.gpa, "ORIEL_ZIG={s} is not Zig {s}", .{ c.environ.get("ORIEL_ZIG") orelse "", want }), .hint = zig_hint },
            .needs_install = true,
        },
        else => return err,
    };
    const source = p.choice.source.label();
    return switch (p.choice.source) {
        .env => .{
            .item = .{ .label = label, .level = .required, .ok = true, .detail = try std.fmt.allocPrint(c.gpa, "{s} ({s}, {s})", .{ p.env_version.?, p.env_zig.?, source }) },
            .needs_install = false,
        },
        .path => .{
            .item = .{ .label = label, .level = .required, .ok = true, .detail = try std.fmt.allocPrint(c.gpa, "{s} ({s}, {s})", .{ p.path_version.?, p.path_zig.?, source }) },
            .needs_install = false,
        },
        .managed => .{
            .item = .{ .label = label, .level = .required, .ok = true, .detail = try std.fmt.allocPrint(c.gpa, "{s} ({s}, {s})", .{ p.choice.managed_version.?, try zig_manager.managedZigPath(c, p.choice.managed_version.?), source }) },
            .needs_install = false,
        },
        // Not a failure: the first build installs it (unless disabled).
        .install => .{
            .item = .{
                .label = label,
                .level = .required,
                .ok = !zigInstallDisabled(c),
                .detail = try std.fmt.allocPrint(c.gpa, "{s}: {s} on first build{s}", .{
                    source,
                    try zig_manager.managedZigPath(c, want),
                    if (p.path_version) |v| try std.fmt.allocPrint(c.gpa, " (zig on PATH is {s})", .{v}) else "",
                }),
                .hint = zig_hint,
            },
            .needs_install = true,
        },
    };
}

fn zigInstallDisabled(c: Context) bool {
    const v = c.environ.get("ORIEL_NO_ZIG_INSTALL") orelse return false;
    return v.len > 0 and !std.mem.eql(u8, v, "0");
}

pub const NodeRequirement = struct {
    level: Level,
    node_label: []const u8,
    npm_label: []const u8,
};

pub fn detectNodeRequirement(gpa: std.mem.Allocator, io: std.Io, cwd: ?[]const u8) NodeRequirement {
    const cwd_path = cwd orelse (std.process.currentPathAlloc(io, gpa) catch return .{
        .level = .optional,
        .node_label = "node (needed for React/Vue/Svelte templates)",
        .npm_label = "npm (needed for React/Vue/Svelte templates)",
    });
    defer if (cwd == null) gpa.free(cwd_path);

    const root = (project.findRoot(gpa, io, cwd_path) catch null) orelse return .{
        .level = .optional,
        .node_label = "node (needed for React/Vue/Svelte templates)",
        .npm_label = "npm (needed for React/Vue/Svelte templates)",
    };
    defer gpa.free(root);

    // Check build.zig to see if frontend.build_command or frontend.dev is explicitly disabled (.build_command = null)
    var build_zig_buf: [std.fs.max_path_bytes]u8 = undefined;
    const bz_path = std.fmt.bufPrint(&build_zig_buf, "{s}/build.zig", .{root}) catch null;
    if (bz_path) |p| {
        if (std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(256 * 1024))) |bz_content| {
            defer gpa.free(bz_content);
            if (std.mem.indexOf(u8, bz_content, ".build_command = null") != null) {
                return .{
                    .level = .optional,
                    .node_label = "node (needed for React/Vue/Svelte templates)",
                    .npm_label = "npm (needed for React/Vue/Svelte templates)",
                };
            }
        } else |_| {}
    }

    if (project.projectNeedsNode(io, root)) {
        return .{
            .level = .required,
            .node_label = "node (Vite templates)",
            .npm_label = "npm",
        };
    }

    return .{
        .level = .optional,
        .node_label = "node (needed for React/Vue/Svelte templates)",
        .npm_label = "npm (needed for React/Vue/Svelte templates)",
    };
}

fn checkNode(c: Context, req: NodeRequirement) !Item {
    const packages = node_packages;
    var node_path: ?[]const u8 = try c.findExecutable("node");
    var is_managed = false;
    const maybe_managed = try setup.findNewestManagedNode(c);
    defer if (maybe_managed) |m| m.deinit(c.gpa);

    if (node_path == null and maybe_managed != null) {
        node_path = maybe_managed.?.node_path;
        is_managed = true;
    }

    const path = node_path orelse
        return .{
            .label = req.node_label,
            .level = req.level,
            .ok = false,
            .detail = "not found",
            .packages = packages,
            .hint = node_hint,
        };

    const out = c.capture(&.{ path, "--version" }, 30_000) orelse
        return .{
            .label = req.node_label,
            .level = req.level,
            .ok = false,
            .detail = "did not run",
            .packages = packages,
            .hint = node_hint,
        };

    const ok = out.code == 0 and nodeVersionOk(out.text());
    return .{
        .label = req.node_label,
        .level = req.level,
        .ok = ok,
        .detail = try std.fmt.allocPrint(c.gpa, "{s} ({s}{s}){s}", .{
            out.text(),
            path,
            if (is_managed) ", managed" else "",
            if (ok) "" else ": need 20.19+ or 22.12+",
        }),
        .packages = packages,
        .hint = if (!ok) node_hint else null,
    };
}

pub fn checkToolNamed(c: Context, label: []const u8, exe_name: []const u8, level: Level, version_args: ?[]const []const u8, packages: Packages) !Item {
    var path = try c.findExecutable(exe_name);
    var is_managed = false;
    var maybe_managed: ?setup.ManagedNode = null;
    defer if (maybe_managed) |m| m.deinit(c.gpa);

    if (path == null and std.mem.eql(u8, exe_name, "npm")) {
        maybe_managed = try setup.findNewestManagedNode(c);
        if (maybe_managed) |m| {
            path = m.npm_path;
            is_managed = true;
        }
    }

    if (path == null)
        return .{ .label = label, .level = level, .ok = false, .detail = "not found", .packages = packages };

    var detail: []const u8 = if (is_managed)
        try std.fmt.allocPrint(c.gpa, "{s} (managed)", .{path.?})
    else
        path.?;

    if (version_args) |args| {
        const argv = try std.mem.concat(c.gpa, []const u8, &.{ &.{path.?}, args });
        if (c.capture(argv, 30_000)) |out| {
            if (out.code == 0) detail = try std.fmt.allocPrint(c.gpa, "{s} ({s}{s})", .{
                out.text(),
                path.?,
                if (is_managed) ", managed" else "",
            });
        }
    }
    return .{ .label = label, .level = level, .ok = true, .detail = detail, .packages = packages };
}

/// A program on PATH, with its version if `version_args` is given.
fn checkTool(c: Context, name: []const u8, level: Level, version_args: ?[]const []const u8, packages: Packages) !Item {
    return checkToolNamed(c, name, name, level, version_args, packages);
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

/// macOS: the Apple SDK that zig-objc and the AppKit/WebKit frameworks
/// are found through (`xcrun`, from Xcode or its command-line tools).
fn checkXcode(c: Context) !Item {
    const label = "Xcode CLI tools";
    const xcrun = try c.findExecutable("xcrun") orelse
        return .{ .label = label, .level = .required, .ok = false, .detail = "xcrun not found", .hint = xcode_hint };
    const out = c.capture(&.{ xcrun, "--sdk", "macosx", "--show-sdk-path" }, 30_000) orelse
        return .{ .label = label, .level = .required, .ok = false, .detail = "xcrun did not run", .hint = xcode_hint };
    const ok = out.code == 0 and out.text().len > 0;
    return .{
        .label = label,
        .level = .required,
        .ok = ok,
        .detail = if (ok) try c.gpa.dupe(u8, out.text()) else "no macOS SDK",
        .hint = xcode_hint,
    };
}

pub const DottedVersion = struct {
    parts: [4]u32 = .{ 0, 0, 0, 0 },
    raw: []const u8,

    pub fn parse(s: []const u8) ?DottedVersion {
        const trimmed = std.mem.trim(u8, s, " \t\r\n\"");
        if (trimmed.len == 0) return null;
        var parts: [4]u32 = .{ 0, 0, 0, 0 };
        var it = std.mem.splitScalar(u8, trimmed, '.');
        var count: usize = 0;
        while (it.next()) |part| {
            if (count >= 4) return null;
            if (part.len == 0) return null;
            const num = std.fmt.parseInt(u32, part, 10) catch return null;
            parts[count] = num;
            count += 1;
        }
        if (count == 0) return null;
        return .{ .parts = parts, .raw = trimmed };
    }

    pub fn order(a: DottedVersion, b: DottedVersion) std.math.Order {
        for (a.parts, b.parts) |p_a, p_b| {
            if (p_a < p_b) return .lt;
            if (p_a > p_b) return .gt;
        }
        return .eq;
    }
};

pub fn parseRegPv(output: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.indexOf(u8, trimmed, "pv") != null and std.mem.indexOf(u8, trimmed, "REG_SZ") != null) {
            const reg_sz_idx = std.mem.indexOf(u8, trimmed, "REG_SZ") orelse continue;
            const val = std.mem.trim(u8, trimmed[reg_sz_idx + "REG_SZ".len ..], " \t\r");
            if (DottedVersion.parse(val) != null) return val;
        }
    }
    return null;
}

/// Windows: the Evergreen WebView2 runtime installs a versioned
/// `msedgewebview2.exe` under `EdgeWebView\Application` (per machine or
/// per user). Reports the highest version found across directory candidates
/// and the EdgeUpdate registry `pv`.
fn checkWebView2(c: Context) !Item {
    return checkWebView2In(c, true);
}

/// `query_registry` false: the filesystem scan only (hermetic tests).
fn checkWebView2In(c: Context, query_registry: bool) !Item {
    const label = "WebView2 runtime";
    var best_version: ?DottedVersion = null;
    var best_detail: ?[]const u8 = null;

    // 1. Filesystem scan across all roots
    const roots = [_][]const u8{ "ProgramFiles(x86)", "ProgramFiles", "LOCALAPPDATA" };
    for (roots) |root_var| {
        const root = c.environ.get(root_var) orelse continue;
        const app_dir = std.fs.path.join(c.gpa, &.{ root, "Microsoft", "EdgeWebView", "Application" }) catch continue;
        defer c.gpa.free(app_dir);
        var dir = std.Io.Dir.cwd().openDir(c.io, app_dir, .{ .iterate = true }) catch continue;
        defer dir.close(c.io);
        var it = dir.iterate();
        while (it.next(c.io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            const ver = DottedVersion.parse(entry.name) orelse continue;
            const exe = std.fs.path.join(c.gpa, &.{ app_dir, entry.name, "msedgewebview2.exe" }) catch continue;
            defer c.gpa.free(exe);
            std.Io.Dir.cwd().access(c.io, exe, .{}) catch continue;

            if (best_version == null or ver.order(best_version.?) == .gt) {
                if (best_detail) |d| c.gpa.free(d);
                best_version = ver;
                best_detail = try std.fmt.allocPrint(c.gpa, "{s} ({s})", .{ entry.name, app_dir });
            }
        }
    }

    // 2. Registry query (EdgeUpdate pv key in HKLM and HKCU)
    const reg_keys = [_][]const u8{
        "HKLM\\SOFTWARE\\WOW6432Node\\Microsoft\\EdgeUpdate\\Clients\\{F3017226-4D2A-4265-8C0E-95AC9ACFC007}",
        "HKCU\\Software\\Microsoft\\EdgeUpdate\\Clients\\{F3017226-4D2A-4265-8C0E-95AC9ACFC007}",
        "HKLM\\SOFTWARE\\Microsoft\\EdgeUpdate\\Clients\\{F3017226-4D2A-4265-8C0E-95AC9ACFC007}",
    };
    for (reg_keys) |key| {
        if (!query_registry) break;
        if (c.capture(&.{ "reg", "query", key, "/v", "pv" }, 5_000)) |out| {
            defer out.deinit(c.gpa);
            if (out.code == 0) {
                if (parseRegPv(out.stdout)) |reg_ver_str| {
                    if (DottedVersion.parse(reg_ver_str)) |reg_ver| {
                        if (best_version == null or reg_ver.order(best_version.?) == .gt) {
                            if (best_detail) |d| c.gpa.free(d);
                            best_version = reg_ver;
                            best_detail = try std.fmt.allocPrint(c.gpa, "{s} (registry)", .{reg_ver_str});
                        }
                    }
                }
            }
        }
    }

    if (best_detail) |detail| {
        return .{
            .label = label,
            .level = .required,
            .ok = true,
            .detail = detail,
        };
    }

    return .{ .label = label, .level = .required, .ok = false, .detail = "not found", .packages = .{ .winget = "Microsoft.EdgeWebView2Runtime" }, .hint = webview2_hint };
}

/// Windows: makensis for `oriel package` (setup.exe), on PATH or where the
/// NSIS installer puts it (the packaging step looks there too).
fn checkMakensis(c: Context) !Item {
    if (c.environ.get("ORIEL_MAKENSIS")) |env_path| {
        if (std.Io.Dir.cwd().access(c.io, env_path, .{})) |_| {
            return .{
                .label = "makensis",
                .level = .optional,
                .ok = true,
                .detail = try std.fmt.allocPrint(c.gpa, "{s} (ORIEL_MAKENSIS)", .{env_path}),
                .packages = .{ .winget = "NSIS.NSIS" },
                .hint = nsis_hint,
            };
        } else |_| {}
    }
    if (try setup.findNewestManagedNsis(c)) |managed_path| {
        defer c.gpa.free(managed_path);
        return .{
            .label = "makensis",
            .level = .optional,
            .ok = true,
            .detail = try std.fmt.allocPrint(c.gpa, "{s} (managed)", .{managed_path}),
            .packages = .{ .winget = "NSIS.NSIS" },
            .hint = nsis_hint,
        };
    }
    var item = try checkTool(c, "makensis", .optional, null, .{ .winget = "NSIS.NSIS" });
    item.hint = nsis_hint;
    if (item.ok) return item;
    for ([_][]const u8{ "ProgramFiles(x86)", "ProgramFiles" }) |root_var| {
        const root = c.environ.get(root_var) orelse continue;
        const exe = try std.fs.path.join(c.gpa, &.{ root, "NSIS", "makensis.exe" });
        std.Io.Dir.cwd().access(c.io, exe, .{}) catch continue;
        item.ok = true;
        item.detail = exe;
        break;
    }
    return item;
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

pub fn checkCachedWebView2Loader(c: Context, is_windows: bool) !Item {
    const label = "WebView2 loader";
    const maybe_x64 = try webview2.findNewestCached(c.gpa, c.io, c.environ, "x64");
    defer if (maybe_x64) |x| x.deinit(c.gpa);
    const maybe_arm64 = try webview2.findNewestCached(c.gpa, c.io, c.environ, "arm64");
    defer if (maybe_arm64) |a| a.deinit(c.gpa);

    const level: Level = if (is_windows) .required else .info;
    const fix_hint = "oriel webview2";

    if (maybe_x64 != null and maybe_arm64 != null) {
        return .{
            .label = label,
            .level = level,
            .ok = true,
            .detail = try std.fmt.allocPrint(c.gpa, "{s} (x64: {s})", .{ maybe_x64.?.version, maybe_x64.?.path }),
            .hint = fix_hint,
        };
    } else if (maybe_x64) |x64| {
        return .{
            .label = label,
            .level = level,
            .ok = true,
            .detail = try std.fmt.allocPrint(c.gpa, "{s} ({s})", .{ x64.version, x64.path }),
            .hint = fix_hint,
        };
    } else if (maybe_arm64) |arm64| {
        return .{
            .label = label,
            .level = level,
            .ok = true,
            .detail = try std.fmt.allocPrint(c.gpa, "{s} ({s})", .{ arm64.version, arm64.path }),
            .hint = fix_hint,
        };
    }
    return .{
        .label = label,
        .level = level,
        .ok = false,
        .detail = if (is_windows) "none cached" else "none cached (run: oriel webview2)",
        .hint = fix_hint,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test distroFromOsRelease {
    try testing.expectEqual(.pacman, distroFromOsRelease("NAME=\"EndeavourOS\"\nID=\"endeavouros\"\nID_LIKE=\"arch\"\n").?);
    try testing.expectEqual(.pacman, distroFromOsRelease("ID=arch\n").?);
    try testing.expectEqual(.pacman, distroFromOsRelease("ID=manjaro\n").?);
    try testing.expectEqual(.apt, distroFromOsRelease("ID=pop\nID_LIKE=\"ubuntu debian\"\n").?);
    try testing.expectEqual(.apt, distroFromOsRelease("ID=ubuntu\n").?);
    try testing.expectEqual(.apt, distroFromOsRelease("ID=debian\n").?);
    try testing.expectEqual(.dnf, distroFromOsRelease("ID=fedora\n").?);
    try testing.expectEqual(.dnf, distroFromOsRelease("ID=rhel\n").?);
    try testing.expectEqual(.dnf, distroFromOsRelease("ID=centos\n").?);
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

test "generateDistroAdminCommand" {
    const items = [_]Item{
        .{ .label = "pkg-config", .level = .required, .ok = false, .detail = "not found", .packages = .{ .pacman = "pkgconf", .apt = "pkg-config", .dnf = "pkgconf-pkg-config", .zypper = "pkg-config" } },
        .{ .label = "gtk4", .level = .required, .ok = false, .detail = "not found", .packages = .{ .pacman = "gtk4", .apt = "libgtk-4-dev", .dnf = "gtk4-devel", .zypper = "gtk4-devel" } },
        .{ .label = "webkitgtk-6.0", .level = .required, .ok = false, .detail = "not found", .packages = .{ .pacman = "webkitgtk-6.0", .apt = "libwebkitgtk-6.0-dev", .dnf = "webkitgtk6.0-devel", .zypper = "webkitgtk-6_0-devel" } },
        .{ .label = "node (Vite templates)", .level = .required, .ok = false, .detail = "not found", .packages = node_packages },
    };

    const cmd_arch = try generateDistroAdminCommand(testing.allocator, .pacman, &items);
    defer if (cmd_arch) |c| testing.allocator.free(c);
    try testing.expectEqualStrings("sudo pacman -S --needed pkgconf gtk4 webkitgtk-6.0", cmd_arch.?);

    const cmd_deb = try generateDistroAdminCommand(testing.allocator, .apt, &items);
    defer if (cmd_deb) |c| testing.allocator.free(c);
    try testing.expectEqualStrings("sudo apt install pkg-config libgtk-4-dev libwebkitgtk-6.0-dev", cmd_deb.?);

    const cmd_fedora = try generateDistroAdminCommand(testing.allocator, .dnf, &items);
    defer if (cmd_fedora) |c| testing.allocator.free(c);
    try testing.expectEqualStrings("sudo dnf install pkgconf-pkg-config gtk4-devel webkitgtk6.0-devel", cmd_fedora.?);

    const cmd_suse = try generateDistroAdminCommand(testing.allocator, .zypper, &items);
    defer if (cmd_suse) |c| testing.allocator.free(c);
    try testing.expectEqualStrings("sudo zypper install pkg-config gtk4-devel webkitgtk-6_0-devel", cmd_suse.?);
}

test "calculateFixPlan pure function" {
    // 1. Clean system: nothing to install or fix
    const clean_items = [_]Item{
        .{ .label = "zig 0.16.0", .level = .required, .ok = true, .detail = "0.16.0" },
        .{ .label = "gtk4", .level = .required, .ok = true, .detail = "4.14.0" },
        .{ .label = "webkitgtk-6.0", .level = .required, .ok = true, .detail = "2.44.0" },
        .{ .label = "node (Vite templates)", .level = .required, .ok = true, .detail = "v22.12.0" },
        .{ .label = "npm", .level = .required, .ok = true, .detail = "10.9.0" },
        .{ .label = "WebView2 loader", .level = .info, .ok = true, .detail = "cached" },
    };
    const clean_plan = try calculateFixPlan(testing.allocator, &clean_items, .linux, .pacman, false);
    defer clean_plan.deinit(testing.allocator);
    try testing.expect(clean_plan.isEmpty());
    try testing.expectEqual(0, clean_plan.fixableCount());

    // 2. Linux with missing required tools
    const missing_linux = [_]Item{
        .{ .label = "zig 0.16.0", .level = .required, .ok = true, .detail = "install: ~/.oriel/zig" },
        .{ .label = "gtk4", .level = .required, .ok = false, .detail = "not found", .packages = .{ .pacman = "gtk4", .apt = "libgtk-4-dev", .dnf = "gtk4-devel", .zypper = "gtk4-devel" } },
        .{ .label = "node (Vite templates)", .level = .required, .ok = false, .detail = "not found", .packages = node_packages },
        .{ .label = "WebView2 loader", .level = .info, .ok = false, .detail = "none cached" },
    };
    // zig + node = 2 fixable tools (the WebView2 loader is only fetched on Windows)
    const linux_plan = try calculateFixPlan(testing.allocator, &missing_linux, .linux, .apt, true);
    defer linux_plan.deinit(testing.allocator);
    try testing.expect(linux_plan.install_zig);
    try testing.expect(linux_plan.install_node);
    try testing.expect(!linux_plan.install_webview2); // info only off Windows
    try testing.expect(!linux_plan.install_nsis);
    try testing.expectEqual(2, linux_plan.fixableCount());
    try testing.expectEqual(1, linux_plan.admin_commands.len);
    try testing.expectEqualStrings("sudo apt install libgtk-4-dev", linux_plan.admin_commands[0]);

    // 3. Unknown Linux distro -> generates commands for all 4 managers
    const unknown_linux = try calculateFixPlan(testing.allocator, &missing_linux, .linux, null, false);
    defer unknown_linux.deinit(testing.allocator);
    try testing.expectEqual(4, unknown_linux.admin_commands.len);

    // 4. Windows with missing makensis and webview2 runtime
    const win_items = [_]Item{
        .{ .label = "WebView2 runtime", .level = .required, .ok = false, .detail = "not found" },
        .{ .label = "makensis", .level = .optional, .ok = false, .detail = "not found" },
    };
    const win_plan = try calculateFixPlan(testing.allocator, &win_items, .windows, .winget, false);
    defer win_plan.deinit(testing.allocator);
    try testing.expect(win_plan.install_nsis);
    try testing.expectEqual(1, win_plan.fixableCount());
    try testing.expectEqual(1, win_plan.admin_commands.len);
    try testing.expect(std.mem.indexOf(u8, win_plan.admin_commands[0], "WebView2 runtime") != null);

    // 5. macOS with missing Xcode CLI tools
    const mac_items = [_]Item{
        .{ .label = "Xcode CLI tools", .level = .required, .ok = false, .detail = "not found" },
    };
    const mac_plan = try calculateFixPlan(testing.allocator, &mac_items, .macos, .brew, false);
    defer mac_plan.deinit(testing.allocator);
    try testing.expectEqual(0, mac_plan.fixableCount());
    try testing.expectEqual(1, mac_plan.admin_commands.len);
    try testing.expectEqualStrings("xcode-select --install", mac_plan.admin_commands[0]);
}

test "report: exit code and install commands" {
    const items = [_]Item{
        .{ .label = "zig 0.16", .level = .required, .ok = true, .detail = "0.16.0" },
        .{ .label = "gtk4", .level = .required, .ok = false, .detail = "not found", .packages = .{ .pacman = "gtk4", .apt = "libgtk-4-dev", .dnf = "gtk4-devel", .zypper = "gtk4-devel" } },
        .{ .label = "webkitgtk-6.0", .level = .required, .ok = false, .detail = "not found", .packages = .{ .pacman = "webkitgtk-6.0", .apt = "libwebkitgtk-6.0-dev", .dnf = "webkitgtk6.0-devel", .zypper = "webkitgtk-6_0-devel" } },
        .{ .label = "nfpm", .level = .optional, .ok = false, .detail = "not found", .hint = nfpm_hint },
        .{ .label = "tray host", .level = .info, .ok = false, .detail = "none" },
    };
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(1, try report(testing.allocator, &out.writer, &items, .apt, 0));
    const text = out.written();
    try testing.expect(std.mem.indexOf(u8, text, "  MISSING  gtk4") != null);
    try testing.expect(std.mem.indexOf(u8, text, "  sudo apt install libgtk-4-dev libwebkitgtk-6.0-dev\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, nfpm_hint) != null);
    try testing.expect(std.mem.indexOf(u8, text, "pacman") == null);

    // Unknown distro: a line for every package manager.
    out.clearRetainingCapacity();
    _ = try report(testing.allocator, &out.writer, &items, null, 0);
    try testing.expect(std.mem.indexOf(u8, out.written(), "sudo dnf install gtk4-devel webkitgtk6.0-devel") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "sudo pacman -S --needed gtk4 webkitgtk-6.0") != null);

    // An unknown Linux distro gets no brew/winget lines.
    try testing.expect(std.mem.indexOf(u8, out.written(), "brew install") == null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "winget install") == null);

    // macOS and Windows print their package manager's command.
    const node_missing = [_]Item{
        .{ .label = "node", .level = .required, .ok = false, .detail = "not found", .packages = node_packages },
        .{ .label = "npm", .level = .required, .ok = false, .detail = "not found", .packages = npm_packages },
        .{ .label = "WebView2 runtime", .level = .required, .ok = false, .detail = "not found", .packages = .{ .winget = "Microsoft.EdgeWebView2Runtime" } },
    };
    out.clearRetainingCapacity();
    try testing.expectEqual(1, try report(testing.allocator, &out.writer, &node_missing, .brew, 1));
    try testing.expect(std.mem.indexOf(u8, out.written(), "  brew install node\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "Run `oriel doctor --fix` to install 1 missing tool.\n") != null);

    out.clearRetainingCapacity();
    _ = try report(testing.allocator, &out.writer, &node_missing, .winget, 1);
    try testing.expect(std.mem.indexOf(u8, out.written(), "  winget install --id OpenJS.NodeJS.LTS\n  winget install --id Microsoft.EdgeWebView2Runtime\n") != null);

    // Only optional/informative things missing: success.
    out.clearRetainingCapacity();
    try testing.expectEqual(0, try report(testing.allocator, &out.writer, items[3..], .pacman, 0));
}

test "checkCachedWebView2Loader empty and populated" {
    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    try env_map.put("XDG_CACHE_HOME", tmp_path);
    try env_map.put("LOCALAPPDATA", tmp_path);

    var dummy_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer dummy_out.deinit();
    var dummy_err: std.Io.Writer.Allocating = .init(testing.allocator);
    defer dummy_err.deinit();

    const c: Context = .{
        .gpa = testing.allocator,
        .io = std.testing.io,
        .environ = &env_map,
        .out = &dummy_out.writer,
        .err = &dummy_err.writer,
    };

    // 1. Empty cache - non-windows (.info)
    const item_empty_nonwin = try checkCachedWebView2Loader(c, false);
    try testing.expectEqual(.info, item_empty_nonwin.level);
    try testing.expect(!item_empty_nonwin.ok);
    try testing.expectEqualStrings("none cached (run: oriel webview2)", item_empty_nonwin.detail);

    // 1b. Empty cache - windows (.required)
    const item_empty_win = try checkCachedWebView2Loader(c, true);
    try testing.expectEqual(.required, item_empty_win.level);
    try testing.expect(!item_empty_win.ok);
    try testing.expectEqualStrings("none cached", item_empty_win.detail);
    try testing.expectEqualStrings("oriel webview2", item_empty_win.hint.?);

    // 2. Populated cache
    const dll_dir = if (builtin.os.tag == .windows)
        try std.fs.path.join(testing.allocator, &.{ tmp_path, "oriel", "cache", "webview2", "1.0.3856.46", "x64" })
    else
        try std.fs.path.join(testing.allocator, &.{ tmp_path, "oriel", "webview2", "1.0.3856.46", "x64" });
    defer testing.allocator.free(dll_dir);

    try std.Io.Dir.cwd().createDirPath(std.testing.io, dll_dir);
    var target_d = try std.Io.Dir.cwd().openDir(std.testing.io, dll_dir, .{});
    defer target_d.close(std.testing.io);

    const f = try target_d.createFile(std.testing.io, "WebView2Loader.dll", .{});
    f.close(std.testing.io);

    const item_cached = try checkCachedWebView2Loader(c, true);
    defer testing.allocator.free(item_cached.detail);
    try testing.expectEqual(.required, item_cached.level);
    try testing.expect(item_cached.ok);
    try testing.expect(std.mem.indexOf(u8, item_cached.detail, "1.0.3856.46") != null);
}

test "DottedVersion parsing and ordering" {
    const v1 = DottedVersion.parse("120.0.2210.144").?;
    const v2 = DottedVersion.parse("134.0.3124.51").?;
    const v3 = DottedVersion.parse("134.0.3124.51").?;
    const v4 = DottedVersion.parse("134.0.3124.52").?;
    const v5 = DottedVersion.parse("1.2").?;

    try testing.expectEqual(.lt, v1.order(v2));
    try testing.expectEqual(.gt, v2.order(v1));
    try testing.expectEqual(.eq, v2.order(v3));
    try testing.expectEqual(.lt, v3.order(v4));
    try testing.expectEqual(.gt, v4.order(v5));

    try testing.expect(DottedVersion.parse("") == null);
    try testing.expect(DottedVersion.parse("invalid") == null);
    try testing.expect(DottedVersion.parse("1.2.3.4.5") == null);
}

test "parseRegPv output parsing" {
    const sample =
        \\HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-4D2A-4265-8C0E-95AC9ACFC007}
        \\    pv    REG_SZ    134.0.3124.51
        \\
    ;
    const pv = parseRegPv(sample);
    try testing.expect(pv != null);
    try testing.expectEqualStrings("134.0.3124.51", pv.?);

    try testing.expect(parseRegPv("nothing here") == null);
}

test "checkWebView2 selects highest installed version" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const app_dir = try std.fs.path.join(testing.allocator, &.{ tmp_path, "Microsoft", "EdgeWebView", "Application" });
    defer testing.allocator.free(app_dir);

    const v1_dir = try std.fs.path.join(testing.allocator, &.{ app_dir, "120.0.2210.144" });
    defer testing.allocator.free(v1_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, v1_dir);
    const exe1_path = try std.fs.path.join(testing.allocator, &.{ v1_dir, "msedgewebview2.exe" });
    defer testing.allocator.free(exe1_path);
    const f1 = try std.Io.Dir.cwd().createFile(std.testing.io, exe1_path, .{});
    f1.close(std.testing.io);

    const v2_dir = try std.fs.path.join(testing.allocator, &.{ app_dir, "134.0.3124.51" });
    defer testing.allocator.free(v2_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, v2_dir);
    const exe2_path = try std.fs.path.join(testing.allocator, &.{ v2_dir, "msedgewebview2.exe" });
    defer testing.allocator.free(exe2_path);
    const f2 = try std.Io.Dir.cwd().createFile(std.testing.io, exe2_path, .{});
    f2.close(std.testing.io);

    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();
    try env_map.put("ProgramFiles", tmp_path);

    var dummy_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer dummy_out.deinit();
    var dummy_err: std.Io.Writer.Allocating = .init(testing.allocator);
    defer dummy_err.deinit();

    const c: Context = .{
        .gpa = testing.allocator,
        .io = std.testing.io,
        .environ = &env_map,
        .out = &dummy_out.writer,
        .err = &dummy_err.writer,
    };

    const item = try checkWebView2In(c, false);
    defer testing.allocator.free(item.detail);

    try testing.expect(item.ok);
    try testing.expectEqual(.required, item.level);
    try testing.expect(std.mem.indexOf(u8, item.detail, "134.0.3124.51") != null);
    try testing.expect(std.mem.indexOf(u8, item.detail, "120.0.2210.144") == null);
}

test "detectNodeRequirement: outside, vanilla, and vite projects" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    // 1. Outside any project
    const outside_req = detectNodeRequirement(testing.allocator, std.testing.io, tmp_path);
    try testing.expectEqual(.optional, outside_req.level);
    try testing.expectEqualStrings("node (needed for React/Vue/Svelte templates)", outside_req.node_label);

    // 2. Vanilla project: has build.zig.zon and build.zig with .build_command = null
    const vanilla_dir = try std.fs.path.join(testing.allocator, &.{ tmp_path, "vanilla" });
    defer testing.allocator.free(vanilla_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, vanilla_dir);
    const zon_path = try std.fs.path.join(testing.allocator, &.{ vanilla_dir, "build.zig.zon" });
    defer testing.allocator.free(zon_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = zon_path, .data = ".{ .name = .vanilla, .version = \"0.1.0\", .fingerprint = 0x123 }" });

    const bz_path = try std.fs.path.join(testing.allocator, &.{ vanilla_dir, "build.zig" });
    defer testing.allocator.free(bz_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = bz_path, .data = "const std = @import(\"std\");\npub fn build(b: *std.Build) void { _ = b; // .build_command = null\n }" });

    const vanilla_req = detectNodeRequirement(testing.allocator, std.testing.io, vanilla_dir);
    try testing.expectEqual(.optional, vanilla_req.level);
    try testing.expectEqualStrings("node (needed for React/Vue/Svelte templates)", vanilla_req.node_label);

    // 3. Vite project: has frontend/package.json
    const vite_dir = try std.fs.path.join(testing.allocator, &.{ tmp_path, "vite" });
    defer testing.allocator.free(vite_dir);
    const vite_fe = try std.fs.path.join(testing.allocator, &.{ vite_dir, "frontend" });
    defer testing.allocator.free(vite_fe);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, vite_fe);

    const vite_zon = try std.fs.path.join(testing.allocator, &.{ vite_dir, "build.zig.zon" });
    defer testing.allocator.free(vite_zon);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = vite_zon, .data = ".{ .name = .vite, .version = \"0.1.0\", .fingerprint = 0x456 }" });

    const pkg_json = try std.fs.path.join(testing.allocator, &.{ vite_fe, "package.json" });
    defer testing.allocator.free(pkg_json);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = pkg_json, .data = "{\"name\": \"vite-app\"}" });

    const vite_req = detectNodeRequirement(testing.allocator, std.testing.io, vite_dir);
    try testing.expectEqual(.required, vite_req.level);
    try testing.expectEqualStrings("node (Vite templates)", vite_req.node_label);
    try testing.expectEqualStrings("npm", vite_req.npm_label);
}
