//! Host tool for packaging Oriel applications:
//! - generates and validates .desktop files
//! - resizes icons into hicolor directory layout
//! - generates nfpm.yaml and invokes nfpm for .deb and .rpm
//! - builds AppDir, runs mksquashfs, prepends type-2 runtime for .AppImage
//! - installs dev/prod desktop entries and icons into $XDG_DATA_HOME

const std = @import("std");
const zigimg = @import("zigimg");

pub const metadata = @import("metadata.zig");
pub const desktop = @import("desktop.zig");
pub const nfpm = @import("nfpm.zig");
pub const appimage = @import("appimage.zig");
pub const icons = @import("icons.zig");

const Dir = std.Io.Dir;
const Io = std.Io;

var global_environ_map: *std.process.Environ.Map = undefined;

fn getEnv(key: []const u8) ?[]const u8 {
    return global_environ_map.get(key);
}

fn pathExists(io: Io, path: []const u8) bool {
    Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn verifyElfFile(io: Io, path: []const u8) !bool {
    var file = Dir.cwd().openFile(io, path, .{}) catch return false;
    defer file.close(io);
    var magic_buf: [4]u8 = undefined;
    var bufs = [_][]u8{&magic_buf};
    const n = file.readStreaming(io, &bufs) catch return false;
    if (n < 4) return false;
    return appimage.isElfBinary(&magic_buf);
}

pub fn main(init: std.process.Init) !u8 {
    global_environ_map = init.environ_map;
    const io = init.io;
    const gpa = init.gpa;
    const argv = init.minimal.args.vector;

    if (argv.len < 2) {
        printUsage();
        return 1;
    }

    const command = std.mem.span(argv[1]);
    const args = argv[2..];

    if (std.mem.eql(u8, command, "generate-desktop")) {
        return generateDesktopCmd(gpa, io, args);
    } else if (std.mem.eql(u8, command, "resize-icons")) {
        return resizeIconsCmd(gpa, io, args);
    } else if (std.mem.eql(u8, command, "package-deb")) {
        return packageNfpmCmd(gpa, io, args, .deb);
    } else if (std.mem.eql(u8, command, "package-rpm")) {
        return packageNfpmCmd(gpa, io, args, .rpm);
    } else if (std.mem.eql(u8, command, "package-appimage")) {
        return packageAppImageCmd(gpa, io, args);
    } else if (std.mem.eql(u8, command, "install-desktop-entry")) {
        return installDesktopEntryCmd(gpa, io, args);
    } else {
        std.debug.print("unknown command: {s}\n", .{command});
        printUsage();
        return 1;
    }
}

fn printUsage() void {
    std.debug.print(
        \\usage: package_tool <command> [options]
        \\commands:
        \\  generate-desktop      Generate and validate .desktop file
        \\  resize-icons          Resize single PNG into 16,32,48,64,128,256,512 PNGs
        \\  package-deb           Generate nfpm.yaml and build Debian (.deb) package
        \\  package-rpm           Generate nfpm.yaml and build RPM (.rpm) package
        \\  package-appimage      Assemble AppDir, run mksquashfs, prepend runtime
        \\  install-desktop-entry Install desktop file and icons to $XDG_DATA_HOME
        \\
    , .{});
}

// ---------------------------------------------------------------------------
// generate-desktop
// ---------------------------------------------------------------------------

fn generateDesktopCmd(gpa: std.mem.Allocator, io: Io, args: []const [*:0]const u8) !u8 {
    var out_path: ?[]const u8 = null;
    var app_id: ?[]const u8 = null;
    var name: ?[]const u8 = null;
    var exec: ?[]const u8 = null;
    var icon: ?[]const u8 = null;
    var comment: ?[]const u8 = null;
    var categories: ?[]const u8 = null;
    var terminal: bool = false;
    var startup_notify: bool = true;
    var startup_wm_class: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = std.mem.span(args[i]);
        if (std.mem.eql(u8, arg, "--out") and i + 1 < args.len) {
            i += 1;
            out_path = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--id") and i + 1 < args.len) {
            i += 1;
            app_id = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--name") and i + 1 < args.len) {
            i += 1;
            name = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--exec") and i + 1 < args.len) {
            i += 1;
            exec = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--icon") and i + 1 < args.len) {
            i += 1;
            icon = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--comment") and i + 1 < args.len) {
            i += 1;
            comment = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--categories") and i + 1 < args.len) {
            i += 1;
            categories = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--terminal") and i + 1 < args.len) {
            i += 1;
            terminal = std.mem.eql(u8, std.mem.span(args[i]), "true");
        } else if (std.mem.eql(u8, arg, "--startup-notify") and i + 1 < args.len) {
            i += 1;
            startup_notify = std.mem.eql(u8, std.mem.span(args[i]), "true");
        } else if (std.mem.eql(u8, arg, "--startup-wm-class") and i + 1 < args.len) {
            i += 1;
            startup_wm_class = std.mem.span(args[i]);
        }
    }

    const target_out = out_path orelse {
        std.debug.print("error: generate-desktop: missing --out\n", .{});
        return 1;
    };
    const target_id = app_id orelse {
        std.debug.print("error: generate-desktop: missing --id\n", .{});
        return 1;
    };
    const target_name = name orelse target_id;
    const target_exec = exec orelse target_id;
    const target_icon = icon orelse target_id;

    const content = try desktop.generateDesktop(gpa, .{
        .app_id = target_id,
        .name = target_name,
        .exec = target_exec,
        .icon = target_icon,
        .comment = comment,
        .categories = categories,
        .terminal = terminal,
        .startup_notify = startup_notify,
        .startup_wm_class = startup_wm_class,
    });
    defer gpa.free(content);

    if (std.fs.path.dirname(target_out)) |dir| {
        try Dir.cwd().createDirPath(io, dir);
    }
    try Dir.cwd().writeFile(io, .{ .sub_path = target_out, .data = content });

    // Validate with desktop-file-validate
    const validate_res = std.process.run(gpa, io, .{
        .argv = &.{ "desktop-file-validate", target_out },
    }) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("error: 'desktop-file-validate' is required but not found in PATH. Please install desktop-file-utils.\n", .{});
        } else {
            std.debug.print("error: failed to execute desktop-file-validate: {s}\n", .{@errorName(err)});
        }
        return 1;
    };
    defer gpa.free(validate_res.stdout);
    defer gpa.free(validate_res.stderr);

    if (validate_res.term != .exited or validate_res.term.exited != 0) {
        std.debug.print("error: desktop-file-validate failed for {s}:\n{s}{s}\n", .{ target_out, validate_res.stdout, validate_res.stderr });
        return 1;
    }

    return 0;
}

// ---------------------------------------------------------------------------
// resize-icons
// ---------------------------------------------------------------------------

fn resizeIconsCmd(gpa: std.mem.Allocator, io: Io, args: []const [*:0]const u8) !u8 {
    var input_path: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    var brand_dir: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = std.mem.span(args[i]);
        if (std.mem.eql(u8, arg, "--input") and i + 1 < args.len) {
            i += 1;
            input_path = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--out-dir") and i + 1 < args.len) {
            i += 1;
            out_dir = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--brand-dir") and i + 1 < args.len) {
            i += 1;
            brand_dir = std.mem.span(args[i]);
        }
    }

    const src_png = input_path orelse {
        std.debug.print("error: resize-icons: missing --input\n", .{});
        return 1;
    };
    const dest_dir = out_dir orelse {
        std.debug.print("error: resize-icons: missing --out-dir\n", .{});
        return 1;
    };

    try Dir.cwd().createDirPath(io, dest_dir);

    // Check if input is from the default oriel brand icons
    const is_default_oriel = blk: {
        if (std.mem.endsWith(u8, src_png, "oriel-icon-1024.png") or std.mem.endsWith(u8, src_png, "oriel-icon.png")) {
            break :blk true;
        }
        if (brand_dir) |bdir| {
            if (std.mem.startsWith(u8, src_png, bdir)) break :blk true;
        }
        break :blk false;
    };

    if (is_default_oriel and brand_dir != null) {
        var all_exist = true;
        for (icons.icon_sizes) |size| {
            const pre_path = try std.fmt.allocPrint(gpa, "{s}/oriel-icon-{d}.png", .{ brand_dir.?, size });
            defer gpa.free(pre_path);
            if (Dir.cwd().access(io, pre_path, .{})) |_| {} else |_| {
                all_exist = false;
                break;
            }
        }
        if (all_exist) {
            for (icons.icon_sizes) |size| {
                const pre_path = try std.fmt.allocPrint(gpa, "{s}/oriel-icon-{d}.png", .{ brand_dir.?, size });
                defer gpa.free(pre_path);
                const out_path = try std.fmt.allocPrint(gpa, "{s}/{d}x{d}.png", .{ dest_dir, size, size });
                defer gpa.free(out_path);
                const data = try Dir.cwd().readFileAlloc(io, pre_path, gpa, .limited(10 * 1024 * 1024));
                defer gpa.free(data);
                try Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = data });
            }
            return 0;
        }
    }

    // Custom PNG: resize using zigimg (pure Zig) with fallback to convert/magick
    const src_data = Dir.cwd().readFileAlloc(io, src_png, gpa, .limited(50 * 1024 * 1024)) catch |err| {
        std.debug.print("error: resize-icons: cannot read {s}: {s}\n", .{ src_png, @errorName(err) });
        return 1;
    };
    defer gpa.free(src_data);

    var zigimg_success = false;
    if (zigimg.Image.fromMemory(gpa, src_data)) |parsed_img| {
        var img = parsed_img;
        defer img.deinit(gpa);
        if (img.convert(gpa, .rgba32)) |_| {
            zigimg_success = true;
            for (icons.icon_sizes) |size| {
                const out_path = try std.fmt.allocPrint(gpa, "{s}/{d}x{d}.png", .{ dest_dir, size, size });
                defer gpa.free(out_path);

                var dst_img = try zigimg.Image.create(gpa, size, size, .rgba32);
                defer dst_img.deinit(gpa);

                icons.downsampleRgba32(img.pixels.rgba32, img.width, img.height, dst_img.pixels.rgba32, size, size);

                const write_buf = try gpa.alloc(u8, size * size * 8 + 4096);
                defer gpa.free(write_buf);

                const encoded = dst_img.writeToMemory(gpa, write_buf, .{ .png = .{} }) catch {
                    zigimg_success = false;
                    break;
                };
                try Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = encoded });
            }
        } else |_| {}
    } else |_| {}

    if (!zigimg_success) {
        // Fallback to ImageMagick convert or magick
        for (icons.icon_sizes) |size| {
            const size_str = try std.fmt.allocPrint(gpa, "{d}x{d}", .{ size, size });
            defer gpa.free(size_str);
            const out_path = try std.fmt.allocPrint(gpa, "{s}/{d}x{d}.png", .{ dest_dir, size, size });
            defer gpa.free(out_path);

            const res = std.process.run(gpa, io, .{
                .argv = &.{ "magick", src_png, "-resize", size_str, out_path },
            }) catch std.process.run(gpa, io, .{
                .argv = &.{ "convert", src_png, "-resize", size_str, out_path },
            }) catch |err| {
                std.debug.print("error: resize-icons: failed to run convert/magick: {s}\n", .{@errorName(err)});
                return 1;
            };
            defer gpa.free(res.stdout);
            defer gpa.free(res.stderr);
            if (res.term != .exited or res.term.exited != 0) {
                std.debug.print("error: resize-icons: resizer failed for size {d}: {s}\n", .{ size, res.stderr });
                return 1;
            }
        }
    }

    return 0;
}

// ---------------------------------------------------------------------------
// package-deb / package-rpm
// ---------------------------------------------------------------------------

fn findNfpm(gpa: std.mem.Allocator, io: Io) ![]const u8 {
    // 1. Search PATH entries from the environment
    if (getEnv("PATH")) |path_var| {
        var it = std.mem.splitScalar(u8, path_var, ':');
        while (it.next()) |dir| {
            if (dir.len == 0) continue;
            const candidate = try std.fs.path.join(gpa, &.{ dir, "nfpm" });
            errdefer gpa.free(candidate);
            if (Dir.cwd().access(io, candidate, .{})) |_| {
                return candidate;
            } else |_| {
                gpa.free(candidate);
            }
        }
    }

    // 2. Search $HOME/go/bin/nfpm
    if (getEnv("HOME")) |home| {
        const go_candidate = try std.fs.path.join(gpa, &.{ home, "go", "bin", "nfpm" });
        errdefer gpa.free(go_candidate);
        if (Dir.cwd().access(io, go_candidate, .{})) |_| {
            return go_candidate;
        } else |_| {
            gpa.free(go_candidate);
        }
    }

    std.debug.print("error: 'nfpm' is required but not found in PATH or $HOME/go/bin/nfpm\n", .{});
    return error.NfpmNotFound;
}

const PackagerType = enum { deb, rpm };

fn packageNfpmCmd(gpa: std.mem.Allocator, io: Io, args: []const [*:0]const u8, packager: PackagerType) !u8 {
    var out_dir: ?[]const u8 = null;
    var filename: ?[]const u8 = null;
    var name: ?[]const u8 = null;
    var version: []const u8 = "0.1.0";
    var arch: []const u8 = "amd64";
    var maintainer: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var homepage: ?[]const u8 = null;
    var license: ?[]const u8 = null;
    var binary_src: ?[]const u8 = null;
    var binary_name: ?[]const u8 = null;
    var desktop_src: ?[]const u8 = null;
    var icons_dir: ?[]const u8 = null;
    var app_id: ?[]const u8 = null;

    var deb_deps: std.ArrayList([]const u8) = .empty;
    defer deb_deps.deinit(gpa);
    var rpm_deps: std.ArrayList([]const u8) = .empty;
    defer rpm_deps.deinit(gpa);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = std.mem.span(args[i]);
        if (std.mem.eql(u8, arg, "--out-dir") and i + 1 < args.len) {
            i += 1;
            out_dir = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--filename") and i + 1 < args.len) {
            i += 1;
            filename = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--name") and i + 1 < args.len) {
            i += 1;
            name = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--version") and i + 1 < args.len) {
            i += 1;
            version = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--arch") and i + 1 < args.len) {
            i += 1;
            arch = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--maintainer") and i + 1 < args.len) {
            i += 1;
            maintainer = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--description") and i + 1 < args.len) {
            i += 1;
            description = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--homepage") and i + 1 < args.len) {
            i += 1;
            homepage = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--license") and i + 1 < args.len) {
            i += 1;
            license = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--bin") and i + 1 < args.len) {
            i += 1;
            binary_src = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--binary-name") and i + 1 < args.len) {
            i += 1;
            binary_name = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--desktop") and i + 1 < args.len) {
            i += 1;
            desktop_src = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--icons-dir") and i + 1 < args.len) {
            i += 1;
            icons_dir = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--app-id") and i + 1 < args.len) {
            i += 1;
            app_id = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--deb-dep") and i + 1 < args.len) {
            i += 1;
            try deb_deps.append(gpa, std.mem.span(args[i]));
        } else if (std.mem.eql(u8, arg, "--rpm-dep") and i + 1 < args.len) {
            i += 1;
            try rpm_deps.append(gpa, std.mem.span(args[i]));
        }
    }

    const target_out_dir = out_dir orelse {
        std.debug.print("error: missing --out-dir\n", .{});
        return 1;
    };
    const target_filename = filename orelse {
        std.debug.print("error: missing --filename\n", .{});
        return 1;
    };
    const target_name = name orelse "app";
    const target_bin_src = binary_src orelse {
        std.debug.print("error: missing --bin\n", .{});
        return 1;
    };
    const target_bin_name = binary_name orelse target_name;
    const target_desktop_src = desktop_src orelse {
        std.debug.print("error: missing --desktop\n", .{});
        return 1;
    };
    const target_icons_dir = icons_dir orelse {
        std.debug.print("error: missing --icons-dir\n", .{});
        return 1;
    };
    const target_app_id = app_id orelse target_name;
    const target_maintainer = maintainer orelse target_name;
    const target_desc = description orelse target_name;

    try Dir.cwd().createDirPath(io, target_out_dir);

    // 1. Generate nfpm.yaml inside out_dir
    const nfpm_yaml_path = try std.fmt.allocPrint(gpa, "{s}/nfpm.yaml", .{target_out_dir});
    defer gpa.free(nfpm_yaml_path);

    const yaml_content = try nfpm.generateNfpmYaml(gpa, .{
        .name = target_name,
        .version = version,
        .arch = arch,
        .maintainer = target_maintainer,
        .description = target_desc,
        .homepage = homepage,
        .license = license,
        .binary_src = target_bin_src,
        .binary_name = target_bin_name,
        .desktop_src = target_desktop_src,
        .app_id = target_app_id,
        .icons_dir = target_icons_dir,
        .deb_depends = deb_deps.items,
        .rpm_depends = rpm_deps.items,
    });
    defer gpa.free(yaml_content);
    try Dir.cwd().writeFile(io, .{ .sub_path = nfpm_yaml_path, .data = yaml_content });

    // 2. Locate nfpm
    const nfpm_bin = findNfpm(gpa, io) catch return 1;
    defer gpa.free(nfpm_bin);

    // 3. Run nfpm package
    const packager_str = switch (packager) {
        .deb => "deb",
        .rpm => "rpm",
    };
    const target_pkg_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ target_out_dir, target_filename });
    defer gpa.free(target_pkg_path);

    const res = std.process.run(gpa, io, .{
        .argv = &.{ nfpm_bin, "package", "-f", nfpm_yaml_path, "-p", packager_str, "-t", target_pkg_path },
    }) catch |err| {
        std.debug.print("error: failed to run nfpm: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);

    if (res.term != .exited or res.term.exited != 0) {
        std.debug.print("error: nfpm {s} packaging failed:\n{s}{s}\n", .{ packager_str, res.stdout, res.stderr });
        return 1;
    }

    return 0;
}

// ---------------------------------------------------------------------------
// package-appimage
// ---------------------------------------------------------------------------

fn packageAppImageCmd(gpa: std.mem.Allocator, io: Io, args: []const [*:0]const u8) !u8 {
    var out_dir: ?[]const u8 = null;
    var filename: ?[]const u8 = null;
    var bin_path: ?[]const u8 = null;
    var desktop_path: ?[]const u8 = null;
    var icons_dir: ?[]const u8 = null;
    var app_id: ?[]const u8 = null;
    var exe_name: ?[]const u8 = null;
    var version: []const u8 = "0.1.0";
    var arch: []const u8 = "x86_64";
    var cache_dir: []const u8 = ".zig-cache";
    var runtime_override: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = std.mem.span(args[i]);
        if (std.mem.eql(u8, arg, "--out-dir") and i + 1 < args.len) {
            i += 1;
            out_dir = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--filename") and i + 1 < args.len) {
            i += 1;
            filename = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--bin") and i + 1 < args.len) {
            i += 1;
            bin_path = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--desktop") and i + 1 < args.len) {
            i += 1;
            desktop_path = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--icons-dir") and i + 1 < args.len) {
            i += 1;
            icons_dir = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--app-id") and i + 1 < args.len) {
            i += 1;
            app_id = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--exe-name") and i + 1 < args.len) {
            i += 1;
            exe_name = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--version") and i + 1 < args.len) {
            i += 1;
            version = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--arch") and i + 1 < args.len) {
            i += 1;
            arch = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--cache-dir") and i + 1 < args.len) {
            i += 1;
            cache_dir = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--runtime-override") and i + 1 < args.len) {
            i += 1;
            runtime_override = std.mem.span(args[i]);
        }
    }

    const dest_dir = out_dir orelse {
        std.debug.print("error: package-appimage: missing --out-dir\n", .{});
        return 1;
    };
    const target_filename = filename orelse {
        std.debug.print("error: package-appimage: missing --filename\n", .{});
        return 1;
    };
    const target_bin = bin_path orelse {
        std.debug.print("error: package-appimage: missing --bin\n", .{});
        return 1;
    };
    const target_desktop = desktop_path orelse {
        std.debug.print("error: package-appimage: missing --desktop\n", .{});
        return 1;
    };
    const target_icons_dir = icons_dir orelse {
        std.debug.print("error: package-appimage: missing --icons-dir\n", .{});
        return 1;
    };
    const target_app_id = app_id orelse "app";
    const target_exe_name = exe_name orelse target_app_id;

    try Dir.cwd().createDirPath(io, dest_dir);

    // 1. Locate or download AppImage type-2 runtime
    var runtime_file: ?[]const u8 = null;
    defer if (runtime_file) |rf| gpa.free(rf);

    if (runtime_override) |ro| {
        if (ro.len > 0 and pathExists(io, ro)) {
            runtime_file = try gpa.dupe(u8, ro);
        } else {
            std.debug.print("error: runtime override file not found: {s}\n", .{ro});
            return 1;
        }
    }
    if (runtime_file == null) {
        if (getEnv("ORIEL_APPIMAGE_RUNTIME")) |env_rt| {
            if (env_rt.len > 0 and pathExists(io, env_rt)) {
                runtime_file = try gpa.dupe(u8, env_rt);
            } else {
                std.debug.print("error: ORIEL_APPIMAGE_RUNTIME file not found: {s}\n", .{env_rt});
                return 1;
            }
        }
    }
    if (runtime_file == null) {
        const cached_rt = try std.fmt.allocPrint(gpa, "{s}/runtime-{s}", .{ cache_dir, arch });
        if (!pathExists(io, cached_rt)) {
            try Dir.cwd().createDirPath(io, cache_dir);
            const url = try std.fmt.allocPrint(gpa, appimage.APPIMAGE_RUNTIME_URL_TEMPLATE, .{arch});
            defer gpa.free(url);

            const temp_rt = try std.fmt.allocPrint(gpa, "{s}.tmp.{d}", .{ cached_rt, Io.Timestamp.now(io, .real).nanoseconds });
            defer {
                _ = Dir.cwd().deleteFile(io, temp_rt) catch {};
                gpa.free(temp_rt);
            }

            const dl_res = std.process.run(gpa, io, .{
                .argv = &.{ "curl", "-fsSL", "-o", temp_rt, url },
            }) catch |err| {
                if (err == error.FileNotFound) {
                    std.debug.print("error: 'curl' is required to download AppImage runtime but was not found in PATH\n", .{});
                } else {
                    std.debug.print("error: failed to execute curl: {s}\n", .{@errorName(err)});
                }
                return 1;
            };
            defer gpa.free(dl_res.stdout);
            defer gpa.free(dl_res.stderr);
            if (dl_res.term != .exited or dl_res.term.exited != 0) {
                std.debug.print("error: curl download failed from {s}:\n{s}\n", .{ url, dl_res.stderr });
                return 1;
            }

            if (!try verifyElfFile(io, temp_rt)) {
                std.debug.print("error: downloaded file from {s} is not a valid ELF binary\n", .{url});
                return 1;
            }

            try Dir.cwd().setFilePermissions(io, temp_rt, @enumFromInt(0o755), .{});
            try Dir.cwd().rename(temp_rt, Dir.cwd(), cached_rt, io);
        }
        runtime_file = cached_rt;
    }

    // Verify ELF magic before use
    if (!try verifyElfFile(io, runtime_file.?)) {
        std.debug.print("error: runtime file '{s}' is not a valid ELF binary\n", .{runtime_file.?});
        return 1;
    }

    // 2. Assemble AppDir inside dest_dir
    const app_dir = try std.fmt.allocPrint(gpa, "{s}/AppDir", .{dest_dir});
    defer gpa.free(app_dir);
    _ = Dir.cwd().deleteTree(io, app_dir) catch {};
    try Dir.cwd().createDirPath(io, app_dir);

    // AppRun (mode 0755)
    const app_run_path = try std.fmt.allocPrint(gpa, "{s}/AppRun", .{app_dir});
    defer gpa.free(app_run_path);
    const app_run_content = try appimage.generateAppRun(gpa, target_exe_name);
    defer gpa.free(app_run_content);
    {
        var run_file = try Dir.cwd().createFile(io, app_run_path, .{ .permissions = @enumFromInt(0o755) });
        defer run_file.close(io);
        try run_file.writeStreamingAll(io, app_run_content);
    }

    // <app_id>.desktop at root
    const root_desktop_path = try std.fmt.allocPrint(gpa, "{s}/{s}.desktop", .{ app_dir, target_app_id });
    defer gpa.free(root_desktop_path);
    const desktop_data = try Dir.cwd().readFileAlloc(io, target_desktop, gpa, .limited(1024 * 1024));
    defer gpa.free(desktop_data);
    try Dir.cwd().writeFile(io, .{ .sub_path = root_desktop_path, .data = desktop_data });

    // usr/share/applications/<app_id>.desktop
    const usr_share_apps = try std.fmt.allocPrint(gpa, "{s}/usr/share/applications", .{app_dir});
    defer gpa.free(usr_share_apps);
    try Dir.cwd().createDirPath(io, usr_share_apps);
    const usr_desktop_path = try std.fmt.allocPrint(gpa, "{s}/{s}.desktop", .{ usr_share_apps, target_app_id });
    defer gpa.free(usr_desktop_path);
    try Dir.cwd().writeFile(io, .{ .sub_path = usr_desktop_path, .data = desktop_data });

    // Icons
    for (icons.icon_sizes) |size| {
        const icon_src = try std.fmt.allocPrint(gpa, "{s}/{d}x{d}.png", .{ target_icons_dir, size, size });
        defer gpa.free(icon_src);
        const icon_data = try Dir.cwd().readFileAlloc(io, icon_src, gpa, .limited(10 * 1024 * 1024));
        defer gpa.free(icon_data);

        // AppDir icons
        const icon_dir = try std.fmt.allocPrint(gpa, "{s}/usr/share/icons/hicolor/{d}x{d}/apps", .{ app_dir, size, size });
        defer gpa.free(icon_dir);
        try Dir.cwd().createDirPath(io, icon_dir);

        const icon_dest = try std.fmt.allocPrint(gpa, "{s}/{s}.png", .{ icon_dir, target_app_id });
        defer gpa.free(icon_dest);
        try Dir.cwd().writeFile(io, .{ .sub_path = icon_dest, .data = icon_data });

        // Root icon (use 256x256)
        if (size == 256) {
            const root_icon_path = try std.fmt.allocPrint(gpa, "{s}/{s}.png", .{ app_dir, target_app_id });
            defer gpa.free(root_icon_path);
            try Dir.cwd().writeFile(io, .{ .sub_path = root_icon_path, .data = icon_data });

            const dir_icon_path = try std.fmt.allocPrint(gpa, "{s}/.DirIcon", .{app_dir});
            defer gpa.free(dir_icon_path);
            try Dir.cwd().writeFile(io, .{ .sub_path = dir_icon_path, .data = icon_data });
        }
    }

    // usr/bin/<exe_name> (mode 0755)
    const usr_bin_dir = try std.fmt.allocPrint(gpa, "{s}/usr/bin", .{app_dir});
    defer gpa.free(usr_bin_dir);
    try Dir.cwd().createDirPath(io, usr_bin_dir);

    const usr_bin_dest = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ usr_bin_dir, target_exe_name });
    defer gpa.free(usr_bin_dest);
    const bin_data = try Dir.cwd().readFileAlloc(io, target_bin, gpa, .limited(100 * 1024 * 1024));
    defer gpa.free(bin_data);
    {
        var bin_file = try Dir.cwd().createFile(io, usr_bin_dest, .{ .permissions = @enumFromInt(0o755) });
        defer bin_file.close(io);
        try bin_file.writeStreamingAll(io, bin_data);
    }

    // 3. Create squashfs image with mksquashfs
    const squashfs_path = try std.fmt.allocPrint(gpa, "{s}/app.squashfs", .{dest_dir});
    defer gpa.free(squashfs_path);
    _ = Dir.cwd().deleteFile(io, squashfs_path) catch {};

    const mksq_res = std.process.run(gpa, io, .{
        .argv = &.{ "mksquashfs", app_dir, squashfs_path, "-root-owned", "-noappend" },
    }) catch |err| {
        std.debug.print("error: failed to run mksquashfs: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer gpa.free(mksq_res.stdout);
    defer gpa.free(mksq_res.stderr);
    if (mksq_res.term != .exited or mksq_res.term.exited != 0) {
        std.debug.print("error: mksquashfs failed:\n{s}{s}\n", .{ mksq_res.stdout, mksq_res.stderr });
        return 1;
    }

    // 4. Prepend runtime to create AppImage
    const appimage_out = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dest_dir, target_filename });
    defer gpa.free(appimage_out);

    const rt_data = try Dir.cwd().readFileAlloc(io, runtime_file.?, gpa, .limited(10 * 1024 * 1024));
    defer gpa.free(rt_data);
    const sq_data = try Dir.cwd().readFileAlloc(io, squashfs_path, gpa, .limited(100 * 1024 * 1024));
    defer gpa.free(sq_data);

    {
        var appimage_file = try Dir.cwd().createFile(io, appimage_out, .{ .permissions = @enumFromInt(0o755) });
        defer appimage_file.close(io);
        try appimage_file.writeStreamingAll(io, rt_data);
        try appimage_file.writeStreamingAll(io, sq_data);
    }

    // Clean up temporary AppDir and squashfs image
    _ = Dir.cwd().deleteTree(io, app_dir) catch {};
    _ = Dir.cwd().deleteFile(io, squashfs_path) catch {};


    return 0;
}

// ---------------------------------------------------------------------------
// install-desktop-entry
// ---------------------------------------------------------------------------

fn installDesktopEntryCmd(gpa: std.mem.Allocator, io: Io, args: []const [*:0]const u8) !u8 {
    var desktop_src: ?[]const u8 = null;
    var icons_dir: ?[]const u8 = null;
    var app_id: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = std.mem.span(args[i]);
        if (std.mem.eql(u8, arg, "--desktop") and i + 1 < args.len) {
            i += 1;
            desktop_src = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--icons-dir") and i + 1 < args.len) {
            i += 1;
            icons_dir = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--app-id") and i + 1 < args.len) {
            i += 1;
            app_id = std.mem.span(args[i]);
        }
    }

    const src_desktop = desktop_src orelse {
        std.debug.print("error: install-desktop-entry: missing --desktop\n", .{});
        return 1;
    };
    const src_icons_dir = icons_dir orelse {
        std.debug.print("error: install-desktop-entry: missing --icons-dir\n", .{});
        return 1;
    };
    const target_id = app_id orelse "app";

    // Determine target data home
    var data_home_allocated: ?[]const u8 = null;
    defer if (data_home_allocated) |dh| gpa.free(dh);

    const data_home = if (getEnv("XDG_DATA_HOME")) |xdg|
        xdg
    else if (getEnv("HOME")) |home| blk: {
        const allocated = try std.fmt.allocPrint(gpa, "{s}/.local/share", .{home});
        data_home_allocated = allocated;
        break :blk allocated;
    } else {
        std.debug.print("error: install-desktop-entry: neither XDG_DATA_HOME nor HOME is set\n", .{});
        return 1;
    };

    // Install .desktop file
    const apps_dir = try std.fmt.allocPrint(gpa, "{s}/applications", .{data_home});
    defer gpa.free(apps_dir);
    try Dir.cwd().createDirPath(io, apps_dir);

    const dest_desktop = try std.fmt.allocPrint(gpa, "{s}/{s}.desktop", .{ apps_dir, target_id });
    defer gpa.free(dest_desktop);

    const desktop_data = try Dir.cwd().readFileAlloc(io, src_desktop, gpa, .limited(1024 * 1024));
    defer gpa.free(desktop_data);
    try Dir.cwd().writeFile(io, .{ .sub_path = dest_desktop, .data = desktop_data });

    // Validate installed desktop file
    const val_res = std.process.run(gpa, io, .{
        .argv = &.{ "desktop-file-validate", dest_desktop },
    }) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("error: 'desktop-file-validate' is required but not found in PATH. Please install desktop-file-utils.\n", .{});
        } else {
            std.debug.print("error: failed to execute desktop-file-validate: {s}\n", .{@errorName(err)});
        }
        return 1;
    };
    defer gpa.free(val_res.stdout);
    defer gpa.free(val_res.stderr);
    if (val_res.term != .exited or val_res.term.exited != 0) {
        std.debug.print("error: desktop-file-validate failed on {s}:\n{s}{s}\n", .{ dest_desktop, val_res.stdout, val_res.stderr });
        return 1;
    }

    std.debug.print("Installed desktop entry: {s}\n", .{dest_desktop});

    // Install icons for all sizes
    for (icons.icon_sizes) |size| {
        const icon_src = try std.fmt.allocPrint(gpa, "{s}/{d}x{d}.png", .{ src_icons_dir, size, size });
        defer gpa.free(icon_src);
        const icon_data = try Dir.cwd().readFileAlloc(io, icon_src, gpa, .limited(10 * 1024 * 1024));
        defer gpa.free(icon_data);

        const target_icon_dir = try std.fmt.allocPrint(gpa, "{s}/icons/hicolor/{d}x{d}/apps", .{ data_home, size, size });
        defer gpa.free(target_icon_dir);
        try Dir.cwd().createDirPath(io, target_icon_dir);

        const dest_icon = try std.fmt.allocPrint(gpa, "{s}/{s}.png", .{ target_icon_dir, target_id });
        defer gpa.free(dest_icon);
        try Dir.cwd().writeFile(io, .{ .sub_path = dest_icon, .data = icon_data });
        std.debug.print("Installed icon: {s}\n", .{dest_icon});
    }

    return 0;
}

test {
    std.testing.refAllDecls(metadata);
    std.testing.refAllDecls(desktop);
    std.testing.refAllDecls(nfpm);
    std.testing.refAllDecls(appimage);
    std.testing.refAllDecls(icons);
}
