//! Host tool for packaging Oriel applications:
//! - generates and validates .desktop files
//! - resizes icons into hicolor directory layout
//! - generates nfpm.yaml and invokes nfpm for .deb and .rpm
//! - builds AppDir, runs mksquashfs, prepends type-2 runtime for .AppImage
//! - installs dev/prod desktop entries and icons into $XDG_DATA_HOME
//! - assembles macOS .app bundles and .dmg disk images
//! - strips ELF executables and libraries for the packages (`strip-elf`)
//!
//! Every `package-*` command takes the package's contents besides the app's
//! executable: `--extra-exe <path>` and `--extra-file <relpath>=<src>`
//! (repeatable; see contents.zig).

const std = @import("std");
const builtin = @import("builtin");
const zigimg = @import("zigimg");

pub const metadata = @import("metadata.zig");
pub const desktop = @import("desktop.zig");
pub const nfpm = @import("nfpm.zig");
pub const appimage = @import("appimage.zig");
pub const icons = @import("icons.zig");
pub const ico = @import("ico.zig");
pub const nsis = @import("nsis.zig");
pub const icns = @import("icns.zig");
pub const macos = @import("macos.zig");
pub const sign_macos = @import("sign_macos.zig");
pub const contents = @import("contents.zig");
pub const elf_strip = @import("elf_strip.zig");

const Dir = std.Io.Dir;
const Io = std.Io;

var global_environ_map: ?*const std.process.Environ.Map = null;

fn getEnv(key: []const u8) ?[]const u8 {
    if (global_environ_map) |m| {
        return m.get(key);
    }
    return null;
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
    // Portable argv (WTF-16 on Windows, so not `args.vector`).
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    if (argv.len < 2) {
        printUsage();
        return 1;
    }

    const command = argv[1];
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
    } else if (std.mem.eql(u8, command, "package-nsis")) {
        return packageNsisCmd(gpa, io, args);
    } else if (std.mem.eql(u8, command, "package-app")) {
        return packageAppCmd(gpa, io, args);
    } else if (std.mem.eql(u8, command, "package-dmg")) {
        return packageDmgCmd(gpa, io, args);
    } else if (std.mem.eql(u8, command, "sign-app")) {
        return sign_macos.signAppCmd(gpa, io, args);
    } else if (std.mem.eql(u8, command, "install-app")) {
        return installAppCmd(gpa, io, args);
    } else if (std.mem.eql(u8, command, "install-desktop-entry")) {
        return installDesktopEntryCmd(gpa, io, args);
    } else if (std.mem.eql(u8, command, "strip-elf")) {
        return stripElfCmd(gpa, io, args);
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
        \\  package-nsis          Generate installer.nsi and build Windows setup.exe via makensis
        \\  package-app           Assemble a macOS .app bundle (Info.plist, icon.icns, ad-hoc signed)
        \\  package-dmg           Build a macOS .dmg with the .app and an Applications link (hdiutil);
        \\                        --identity signs it, --notarize-profile notarizes and staples it
        \\  sign-app              Copy a .app and sign it for distribution (hardened runtime, timestamp)
        \\  install-app           Replace a directory with a copy of a .app bundle (no stale files)
        \\  install-desktop-entry Install desktop file and icons to $XDG_DATA_HOME
        \\  strip-elf             Copy an ELF file without its symbol table and debug info (--in, --out)
        \\
        \\package-* commands also take --extra-exe <path> and --extra-file <relpath>=<src>
        \\(repeatable): more executables, and files placed relative to the app's executable.
        \\
    , .{});
}

// ---------------------------------------------------------------------------
// package contents (--extra-exe, --extra-file)
// ---------------------------------------------------------------------------

/// `Contents.parseArg` for command `what`, printing the error. Returns
/// null for an invalid argument, else whether it was consumed.
fn parseContentsArg(c: *contents.Contents, gpa: std.mem.Allocator, what: []const u8, args: []const [:0]const u8, i: *usize) ?bool {
    return c.parseArg(gpa, args, i) catch |err| {
        std.debug.print("error: {s}: {s} {s}: {s}\n", .{ what, args[i.*], if (i.* + 1 < args.len) args[i.* + 1] else "", contents.describe(err) });
        return null;
    };
}

/// `Contents.validate`, printing the error: false when invalid. `taken`:
/// destinations the command itself uses next to the app's executable.
fn validateContents(c: *const contents.Contents, what: []const u8, taken: []const []const u8) bool {
    var bad: []const u8 = "";
    c.validate(taken, &bad) catch |err| {
        std.debug.print("error: {s}: invalid package entry '{s}': {s}\n", .{ what, bad, contents.describe(err) });
        return false;
    };
    return true;
}

/// The deployment target a Mach-O file declares (see macos.machoMinOs).
fn machoMinOsOfFile(io: Io, path: []const u8) ?macos.OsVersion {
    var file = Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    var head: [64 * 1024]u8 = undefined;
    const n = file.readPositionalAll(io, &head, 0) catch return null;
    return macos.machoMinOs(head[0..n]);
}

/// Copy the extra executables (mode 0755) and files (0644, parent
/// directories created) into `dest_dir`.
fn copyContents(gpa: std.mem.Allocator, io: Io, c: *const contents.Contents, dest_dir: []const u8) !void {
    for (c.exes.items) |e| {
        const dest = try std.fs.path.join(gpa, &.{ dest_dir, e.name });
        defer gpa.free(dest);
        try Dir.cwd().copyFile(e.src, Dir.cwd(), dest, io, .{ .permissions = filePerms(0o755) });
    }
    for (c.files.items) |f| {
        const dest = try std.fs.path.join(gpa, &.{ dest_dir, f.rel });
        defer gpa.free(dest);
        if (std.fs.path.dirname(dest)) |parent| try Dir.cwd().createDirPath(io, parent);
        try Dir.cwd().copyFile(f.src, Dir.cwd(), dest, io, .{ .permissions = filePerms(0o644) });
    }
}

/// A bundle's `Contents/MacOS` may hold only code (codesign refuses other
/// files there), so for `package-app` the extra executables and Mach-O
/// files go to `Contents/MacOS/<rel>`, and other files to
/// `Contents/Resources/<rel>` with a relative symlink
/// `Contents/MacOS/<first component>` -> `../Resources/<first component>`:
/// paths relative to the executable keep working (codesign seals symlinks).
/// `error.BadLayout` (printed) when a top-level name would need to be both.
fn copyContentsMac(gpa: std.mem.Allocator, io: Io, c: *const contents.Contents, bundle: []const u8) !void {
    const macos_dir = try std.fs.path.join(gpa, &.{ bundle, "Contents", "MacOS" });
    defer gpa.free(macos_dir);
    const res_dir = try std.fs.path.join(gpa, &.{ bundle, "Contents", "Resources" });
    defer gpa.free(res_dir);

    var code_tops: std.ArrayList([]const u8) = .empty;
    defer code_tops.deinit(gpa);
    var res_tops: std.ArrayList([]const u8) = .empty;
    defer res_tops.deinit(gpa);
    const is_code = try gpa.alloc(bool, c.files.items.len);
    defer gpa.free(is_code);
    for (c.files.items, is_code) |f, *code| {
        code.* = isMachOFile(io, f.src);
        const top = f.rel[0 .. std.mem.indexOfScalar(u8, f.rel, '/') orelse f.rel.len];
        try (if (code.*) &code_tops else &res_tops).append(gpa, top);
    }
    for (res_tops.items) |top| {
        const clash = for (code_tops.items) |ct| {
            if (std.ascii.eqlIgnoreCase(ct, top)) break true;
        } else std.ascii.eqlIgnoreCase(top, "icon.icns");
        if (clash) {
            std.debug.print("error: package-app: '{s}' would hold both code (Contents/MacOS) and other files (Contents/Resources); put libraries and data under different top-level names\n", .{top});
            return error.BadLayout;
        }
    }

    for (c.exes.items) |e| {
        const dest = try std.fs.path.join(gpa, &.{ macos_dir, e.name });
        defer gpa.free(dest);
        try Dir.cwd().copyFile(e.src, Dir.cwd(), dest, io, .{ .permissions = filePerms(0o755) });
    }
    for (c.files.items, is_code) |f, code| {
        const dest = try std.fs.path.join(gpa, &.{ if (code) macos_dir else res_dir, f.rel });
        defer gpa.free(dest);
        if (std.fs.path.dirname(dest)) |parent| try Dir.cwd().createDirPath(io, parent);
        try Dir.cwd().copyFile(f.src, Dir.cwd(), dest, io, .{ .permissions = filePerms(0o644) });
    }
    var macos_handle = try Dir.cwd().openDir(io, macos_dir, .{});
    defer macos_handle.close(io);
    for (res_tops.items, 0..) |top, i| {
        const seen = for (res_tops.items[0..i]) |prev| {
            if (std.mem.eql(u8, prev, top)) break true;
        } else false;
        if (seen) continue;
        const target = try std.fmt.allocPrint(gpa, "../Resources/{s}", .{top});
        defer gpa.free(target);
        try macos_handle.symLink(io, target, top, .{});
    }
}

fn isMachOFile(io: Io, path: []const u8) bool {
    var file = Dir.cwd().openFile(io, path, .{}) catch return false;
    defer file.close(io);
    var magic: [4]u8 = undefined;
    const n = file.readPositionalAll(io, &magic, 0) catch return false;
    return n == 4 and sign_macos.isMachO(magic);
}

/// `strip-elf --in <file> --out <file>`: `--out` is `--in` without its
/// symbol table and debug sections (elf_strip.zig), same mode. A file that
/// isn't an ELF executable or library, or that can't be stripped, is copied
/// unchanged (with a warning for the latter).
fn stripElfCmd(gpa: std.mem.Allocator, io: Io, args: []const [:0]const u8) !u8 {
    var in_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--in") and i + 1 < args.len) {
            i += 1;
            in_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
            i += 1;
            out_path = args[i];
        } else {
            std.debug.print("error: strip-elf: unknown argument {s}\n", .{args[i]});
            return 1;
        }
    }
    if (in_path == null or out_path == null) {
        std.debug.print("error: strip-elf: needs --in and --out\n", .{});
        return 1;
    }
    const st = Dir.cwd().statFile(io, in_path.?, .{}) catch |err| {
        std.debug.print("error: strip-elf: {s}: {s}\n", .{ in_path.?, @errorName(err) });
        return 1;
    };
    const data = try Dir.cwd().readFileAlloc(io, in_path.?, gpa, .unlimited);
    defer gpa.free(data);
    const stripped: ?[]u8 = if (elf_strip.isElf(data)) elf_strip.strip(gpa, data) catch |err| blk: {
        std.debug.print("warning: strip-elf: {s} is packaged unstripped: {s}\n", .{ in_path.?, @errorName(err) });
        break :blk null;
    } else null;
    defer if (stripped) |s| gpa.free(s);
    if (std.fs.path.dirname(out_path.?)) |parent| try Dir.cwd().createDirPath(io, parent);
    var out = try Dir.cwd().createFile(io, out_path.?, .{ .permissions = st.permissions });
    defer out.close(io);
    try out.writeStreamingAll(io, stripped orelse data);
    return 0;
}

// ---------------------------------------------------------------------------
// generate-desktop
// ---------------------------------------------------------------------------

fn generateDesktopCmd(gpa: std.mem.Allocator, io: Io, args: []const [:0]const u8) !u8 {
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
    var url_schemes: std.ArrayList([]const u8) = .empty;
    defer url_schemes.deinit(gpa);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--out") and i + 1 < args.len) {
            i += 1;
            out_path = args[i];
        } else if (std.mem.eql(u8, arg, "--id") and i + 1 < args.len) {
            i += 1;
            app_id = args[i];
        } else if (std.mem.eql(u8, arg, "--name") and i + 1 < args.len) {
            i += 1;
            name = args[i];
        } else if (std.mem.eql(u8, arg, "--exec") and i + 1 < args.len) {
            i += 1;
            exec = args[i];
        } else if (std.mem.eql(u8, arg, "--icon") and i + 1 < args.len) {
            i += 1;
            icon = args[i];
        } else if (std.mem.eql(u8, arg, "--comment") and i + 1 < args.len) {
            i += 1;
            comment = args[i];
        } else if (std.mem.eql(u8, arg, "--categories") and i + 1 < args.len) {
            i += 1;
            categories = args[i];
        } else if (std.mem.eql(u8, arg, "--terminal") and i + 1 < args.len) {
            i += 1;
            terminal = std.mem.eql(u8, args[i], "true");
        } else if (std.mem.eql(u8, arg, "--startup-notify") and i + 1 < args.len) {
            i += 1;
            startup_notify = std.mem.eql(u8, args[i], "true");
        } else if (std.mem.eql(u8, arg, "--startup-wm-class") and i + 1 < args.len) {
            i += 1;
            startup_wm_class = args[i];
        } else if (std.mem.eql(u8, arg, "--url-scheme") and i + 1 < args.len) {
            i += 1;
            try url_schemes.append(gpa, args[i]);
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
        .url_schemes = url_schemes.items,
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

fn resizeIconsCmd(gpa: std.mem.Allocator, io: Io, args: []const [:0]const u8) !u8 {
    var input_path: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    var brand_dir: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--input") and i + 1 < args.len) {
            i += 1;
            input_path = args[i];
        } else if (std.mem.eql(u8, arg, "--out-dir") and i + 1 < args.len) {
            i += 1;
            out_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--brand-dir") and i + 1 < args.len) {
            i += 1;
            brand_dir = args[i];
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

    resizeIcons(gpa, io, src_png, dest_dir, brand_dir) catch |err| {
        std.debug.print("error: resize-icons failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

pub fn resizeIcons(
    gpa: std.mem.Allocator,
    io: Io,
    src_png: []const u8,
    dest_dir: []const u8,
    brand_dir: ?[]const u8,
) !void {
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
            try writeDestinationIco(gpa, io, dest_dir);
            try writeDestinationIcns(gpa, io, dest_dir, src_png);
            return;
        }
    }

    // Custom PNG: resize using zigimg (pure Zig) with fallback to convert/magick
    const src_data = try Dir.cwd().readFileAlloc(io, src_png, gpa, .limited(50 * 1024 * 1024));
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

                const sz: usize = size;
                const write_buf = try gpa.alloc(u8, sz * sz * 8 + 4096);
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
                return err;
            };
            defer gpa.free(res.stdout);
            defer gpa.free(res.stderr);
            if (res.term != .exited or res.term.exited != 0) {
                std.debug.print("error: resize-icons: resizer failed for size {d}: {s}\n", .{ size, res.stderr });
                return error.ResizeFailed;
            }
        }
    }

    try writeDestinationIco(gpa, io, dest_dir);
    try writeDestinationIcns(gpa, io, dest_dir, src_png);
}

/// Pack the resized PNGs in `dest_dir` into `dest_dir/icon.ico` (used by the
/// NSIS installer and its shortcuts), and generate `dest_dir/app.rc` for
/// embedding the icon resource into Windows binaries.
fn writeDestinationIco(gpa: std.mem.Allocator, io: Io, dest_dir: []const u8) !void {
    var png_entries: std.ArrayList(ico.PngIconEntry) = .empty;
    defer {
        for (png_entries.items) |entry| gpa.free(entry.png_data);
        png_entries.deinit(gpa);
    }

    for (ico.default_ico_sizes) |size| {
        const png_file = try std.fmt.allocPrint(gpa, "{s}/{d}x{d}.png", .{ dest_dir, size, size });
        defer gpa.free(png_file);
        const png_data = try Dir.cwd().readFileAlloc(io, png_file, gpa, .limited(10 * 1024 * 1024));
        errdefer gpa.free(png_data);
        try png_entries.append(gpa, .{ .width = size, .height = size, .png_data = png_data });
    }

    const ico_bytes = try ico.writeIcoFromPngs(gpa, png_entries.items);
    defer gpa.free(ico_bytes);
    const ico_path = try std.fmt.allocPrint(gpa, "{s}/icon.ico", .{dest_dir});
    defer gpa.free(ico_path);
    try Dir.cwd().writeFile(io, .{ .sub_path = ico_path, .data = ico_bytes });

    const rc_path = try std.fmt.allocPrint(gpa, "{s}/app.rc", .{dest_dir});
    defer gpa.free(rc_path);
    try Dir.cwd().writeFile(io, .{ .sub_path = rc_path, .data = "1 ICON \"icon.ico\"\n" });
}

/// `<dest_dir>/icon.icns` from the resized PNGs (for macOS bundles), plus
/// the source PNG itself when it is 1024x1024 (the 512pt@2x slot).
fn writeDestinationIcns(gpa: std.mem.Allocator, io: Io, dest_dir: []const u8, src_png: []const u8) !void {
    var entries: std.ArrayList(icns.PngIconEntry) = .empty;
    defer {
        for (entries.items) |entry| gpa.free(entry.png_data);
        entries.deinit(gpa);
    }
    for (icons.icon_sizes) |size| {
        const png_file = try std.fmt.allocPrint(gpa, "{s}/{d}x{d}.png", .{ dest_dir, size, size });
        defer gpa.free(png_file);
        const png_data = try Dir.cwd().readFileAlloc(io, png_file, gpa, .limited(10 * 1024 * 1024));
        errdefer gpa.free(png_data);
        try entries.append(gpa, .{ .size = size, .png_data = png_data });
    }
    if (Dir.cwd().readFileAlloc(io, src_png, gpa, .limited(50 * 1024 * 1024))) |src_data| {
        const dims = icns.pngSize(src_data) orelse [2]u32{ 0, 0 };
        if (dims[0] == 1024 and dims[1] == 1024) {
            errdefer gpa.free(src_data);
            try entries.append(gpa, .{ .size = 1024, .png_data = src_data }); // freed with the others
        } else gpa.free(src_data);
    } else |_| {}
    const bytes = try icns.writeIcnsFromPngs(gpa, entries.items);
    defer gpa.free(bytes);
    const path = try std.fmt.allocPrint(gpa, "{s}/icon.icns", .{dest_dir});
    defer gpa.free(path);
    try Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
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

fn packageNfpmCmd(gpa: std.mem.Allocator, io: Io, args: []const [:0]const u8, packager: PackagerType) !u8 {
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
    var replaces: std.ArrayList([]const u8) = .empty;
    defer replaces.deinit(gpa);
    var conflicts: std.ArrayList([]const u8) = .empty;
    defer conflicts.deinit(gpa);
    var extras: contents.Contents = .{};
    defer extras.deinit(gpa);
    const what = if (packager == .deb) "package-deb" else "package-rpm";

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (parseContentsArg(&extras, gpa, what, args, &i) orelse return 1) {
            continue;
        } else if (std.mem.eql(u8, arg, "--out-dir") and i + 1 < args.len) {
            i += 1;
            out_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--filename") and i + 1 < args.len) {
            i += 1;
            filename = args[i];
        } else if (std.mem.eql(u8, arg, "--name") and i + 1 < args.len) {
            i += 1;
            name = args[i];
        } else if (std.mem.eql(u8, arg, "--version") and i + 1 < args.len) {
            i += 1;
            version = args[i];
        } else if (std.mem.eql(u8, arg, "--arch") and i + 1 < args.len) {
            i += 1;
            arch = args[i];
        } else if (std.mem.eql(u8, arg, "--maintainer") and i + 1 < args.len) {
            i += 1;
            maintainer = args[i];
        } else if (std.mem.eql(u8, arg, "--description") and i + 1 < args.len) {
            i += 1;
            description = args[i];
        } else if (std.mem.eql(u8, arg, "--homepage") and i + 1 < args.len) {
            i += 1;
            homepage = args[i];
        } else if (std.mem.eql(u8, arg, "--license") and i + 1 < args.len) {
            i += 1;
            license = args[i];
        } else if (std.mem.eql(u8, arg, "--bin") and i + 1 < args.len) {
            i += 1;
            binary_src = args[i];
        } else if (std.mem.eql(u8, arg, "--binary-name") and i + 1 < args.len) {
            i += 1;
            binary_name = args[i];
        } else if (std.mem.eql(u8, arg, "--desktop") and i + 1 < args.len) {
            i += 1;
            desktop_src = args[i];
        } else if (std.mem.eql(u8, arg, "--icons-dir") and i + 1 < args.len) {
            i += 1;
            icons_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--app-id") and i + 1 < args.len) {
            i += 1;
            app_id = args[i];
        } else if (std.mem.eql(u8, arg, "--deb-dep") and i + 1 < args.len) {
            i += 1;
            try deb_deps.append(gpa, args[i]);
        } else if (std.mem.eql(u8, arg, "--rpm-dep") and i + 1 < args.len) {
            i += 1;
            try rpm_deps.append(gpa, args[i]);
        } else if (std.mem.eql(u8, arg, "--replaces") and i + 1 < args.len) {
            i += 1;
            try replaces.append(gpa, args[i]);
        } else if (std.mem.eql(u8, arg, "--conflicts") and i + 1 < args.len) {
            i += 1;
            try conflicts.append(gpa, args[i]);
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
    metadata.validateExeName(target_name) catch |err| {
        std.debug.print("error: package-nfpm: invalid package name '{s}': {s}\n", .{ target_name, @errorName(err) });
        return 1;
    };
    const target_bin_src = binary_src orelse {
        std.debug.print("error: missing --bin\n", .{});
        return 1;
    };
    const target_bin_name = binary_name orelse target_name;
    metadata.validateExeName(target_bin_name) catch |err| {
        std.debug.print("error: package-nfpm: invalid binary name '{s}': {s}\n", .{ target_bin_name, @errorName(err) });
        return 1;
    };
    const target_desktop_src = desktop_src orelse {
        std.debug.print("error: missing --desktop\n", .{});
        return 1;
    };
    const target_icons_dir = icons_dir orelse {
        std.debug.print("error: missing --icons-dir\n", .{});
        return 1;
    };
    if (!validateContents(&extras, what, &.{target_bin_name})) return 1;
    const target_app_id = app_id orelse target_name;
    const target_maintainer = maintainer orelse target_name;
    const target_desc = description orelse target_name;

    try Dir.cwd().createDirPath(io, target_out_dir);

    // 1. Generate nfpm.yaml inside out_dir
    const nfpm_yaml_path = try std.fmt.allocPrint(gpa, "{s}/nfpm.yaml", .{target_out_dir});
    defer gpa.free(nfpm_yaml_path);

    const yaml_content = nfpm.generateNfpmYaml(gpa, .{
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
        .replaces = replaces.items,
        .conflicts = conflicts.items,
        .extra_exes = extras.exes.items,
        .extra_files = extras.files.items,
    }) catch |err| {
        std.debug.print("error: {s}: nfpm.yaml: {s}\n", .{ what, contents.describe(err) });
        return 1;
    };
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

pub fn streamCopyFile(io: Io, src_dir: Dir, src_path: []const u8, dest_file: std.Io.File) !void {
    var src_file = try src_dir.openFile(io, src_path, .{});
    defer src_file.close(io);

    var buf: [64 * 1024]u8 = undefined;
    var bufs = [_][]u8{&buf};
    while (true) {
        const n = src_file.readStreaming(io, &bufs) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        try dest_file.writeStreamingAll(io, buf[0..n]);
    }
}

fn resolveAppImageRuntime(
    gpa: std.mem.Allocator,
    io: Io,
    cache_dir: []const u8,
    arch: []const u8,
    runtime_override: ?[]const u8,
) ![]const u8 {
    // 1. User-supplied override CLI argument:
    // A user-supplied override (--runtime-override / ORIEL_APPIMAGE_RUNTIME) is trusted as given
    // (the user chose it); keep only the ELF check for it and bypass sha256 verification.
    if (runtime_override) |ro| {
        if (ro.len > 0 and pathExists(io, ro)) {
            const rt = try gpa.dupe(u8, ro);
            errdefer gpa.free(rt);
            if (!try verifyElfFile(io, rt)) {
                std.debug.print("error: runtime override file '{s}' is not a valid ELF binary\n", .{rt});
                return error.InvalidElfBinary;
            }
            return rt;
        } else {
            std.debug.print("error: runtime override file not found: {s}\n", .{ro});
            return error.FileNotFound;
        }
    }

    // 2. User-supplied environment override (ORIEL_APPIMAGE_RUNTIME):
    // A user-supplied override is trusted as given; only check ELF.
    if (getEnv("ORIEL_APPIMAGE_RUNTIME")) |env_rt| {
        if (env_rt.len > 0 and pathExists(io, env_rt)) {
            const rt = try gpa.dupe(u8, env_rt);
            errdefer gpa.free(rt);
            if (!try verifyElfFile(io, rt)) {
                std.debug.print("error: ORIEL_APPIMAGE_RUNTIME '{s}' is not a valid ELF binary\n", .{rt});
                return error.InvalidElfBinary;
            }
            return rt;
        } else {
            std.debug.print("error: ORIEL_APPIMAGE_RUNTIME file not found: {s}\n", .{env_rt});
            return error.FileNotFound;
        }
    }

    // 3. Pinned release tag (20251108) and SHA-256 constant per arch
    const expected_hash = appimage.getPinnedRuntimeHash(arch) orelse {
        std.debug.print("error: unknown or unsupported architecture '{s}' for AppImage runtime\n", .{arch});
        return error.UnsupportedArchitecture;
    };

    // Pinned cache filename includes tag: runtime-20251108-<arch>
    const cached_rt = try std.fmt.allocPrint(gpa, "{s}/runtime-{s}-{s}", .{ cache_dir, appimage.APPIMAGE_RUNTIME_TAG, arch });
    errdefer gpa.free(cached_rt);

    // Verify existing cached file every time it is used
    if (pathExists(io, cached_rt)) {
        if (try appimage.verifyFileSha256(io, cached_rt, expected_hash)) {
            if (try verifyElfFile(io, cached_rt)) {
                return cached_rt;
            }
        }
        // Hash mismatch or invalid cached file: delete it and re-download
        _ = Dir.cwd().deleteFile(io, cached_rt) catch {};
    }

    // Download pinned runtime
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
        return err;
    };
    defer gpa.free(dl_res.stdout);
    defer gpa.free(dl_res.stderr);
    if (dl_res.term != .exited or dl_res.term.exited != 0) {
        std.debug.print("error: curl download failed from {s}:\n{s}\n", .{ url, dl_res.stderr });
        return error.DownloadFailed;
    }

    // Verify SHA-256 of downloaded temp file BEFORE renaming into cache
    if (!try appimage.verifyFileSha256(io, temp_rt, expected_hash)) {
        std.debug.print("error: SHA-256 mismatch for downloaded AppImage runtime from {s}\n", .{url});
        return error.HashMismatch;
    }

    if (!try verifyElfFile(io, temp_rt)) {
        std.debug.print("error: downloaded file from {s} is not a valid ELF binary\n", .{url});
        return error.InvalidElfBinary;
    }

    try Dir.cwd().setFilePermissions(io, temp_rt, filePerms(0o755), .{});
    try Dir.cwd().rename(temp_rt, Dir.cwd(), cached_rt, io);

    return cached_rt;
}

fn packageAppImageCmd(gpa: std.mem.Allocator, io: Io, args: []const [:0]const u8) !u8 {
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
    var extras: contents.Contents = .{};
    defer extras.deinit(gpa);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (parseContentsArg(&extras, gpa, "package-appimage", args, &i) orelse return 1) {
            continue;
        } else if (std.mem.eql(u8, arg, "--out-dir") and i + 1 < args.len) {
            i += 1;
            out_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--filename") and i + 1 < args.len) {
            i += 1;
            filename = args[i];
        } else if (std.mem.eql(u8, arg, "--bin") and i + 1 < args.len) {
            i += 1;
            bin_path = args[i];
        } else if (std.mem.eql(u8, arg, "--desktop") and i + 1 < args.len) {
            i += 1;
            desktop_path = args[i];
        } else if (std.mem.eql(u8, arg, "--icons-dir") and i + 1 < args.len) {
            i += 1;
            icons_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--app-id") and i + 1 < args.len) {
            i += 1;
            app_id = args[i];
        } else if (std.mem.eql(u8, arg, "--exe-name") and i + 1 < args.len) {
            i += 1;
            exe_name = args[i];
        } else if (std.mem.eql(u8, arg, "--version") and i + 1 < args.len) {
            i += 1;
            version = args[i];
        } else if (std.mem.eql(u8, arg, "--arch") and i + 1 < args.len) {
            i += 1;
            arch = args[i];
        } else if (std.mem.eql(u8, arg, "--cache-dir") and i + 1 < args.len) {
            i += 1;
            cache_dir = args[i];
        } else if (std.mem.startsWith(u8, arg, "--runtime-override=")) {
            runtime_override = arg["--runtime-override=".len..];
        } else if (std.mem.eql(u8, arg, "--runtime-override") and i + 1 < args.len) {
            i += 1;
            runtime_override = args[i];
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

    metadata.validateExeName(target_exe_name) catch |err| {
        std.debug.print("error: package-appimage: invalid --exe-name '{s}': {s}\n", .{ target_exe_name, @errorName(err) });
        return 1;
    };
    if (!validateContents(&extras, "package-appimage", &.{target_exe_name})) return 1;

    try Dir.cwd().createDirPath(io, dest_dir);

    // 1. Locate or download AppImage type-2 runtime (single owned allocation, freed by defer)
    const runtime_file = resolveAppImageRuntime(gpa, io, cache_dir, arch, runtime_override) catch |err| {
        std.debug.print("error: package-appimage: AppImage runtime: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer gpa.free(runtime_file);

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
        var run_file = try Dir.cwd().createFile(io, app_run_path, .{ .permissions = filePerms(0o755) });
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
    try Dir.cwd().copyFile(target_bin, Dir.cwd(), usr_bin_dest, io, .{
        .permissions = filePerms(0o755),
    });
    // Extra executables and files next to it.
    try copyContents(gpa, io, &extras, usr_bin_dir);

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

    // 4. Prepend runtime to create AppImage (streaming copies)
    const appimage_out = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dest_dir, target_filename });
    defer gpa.free(appimage_out);

    {
        var appimage_file = try Dir.cwd().createFile(io, appimage_out, .{ .permissions = filePerms(0o755) });
        defer appimage_file.close(io);
        try streamCopyFile(io, Dir.cwd(), runtime_file, appimage_file);
        try streamCopyFile(io, Dir.cwd(), squashfs_path, appimage_file);
    }

    // Clean up temporary AppDir and squashfs image
    _ = Dir.cwd().deleteTree(io, app_dir) catch {};
    _ = Dir.cwd().deleteFile(io, squashfs_path) catch {};

    return 0;
}

// ---------------------------------------------------------------------------
// package-nsis
// ---------------------------------------------------------------------------

fn ensureAbsolutePath(gpa: std.mem.Allocator, io: Io, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        return try gpa.dupe(u8, path);
    }
    const cwd_path = try Dir.cwd().realPathFileAlloc(io, ".", gpa);
    defer gpa.free(cwd_path);
    return try std.fs.path.join(gpa, &.{ cwd_path, path });
}

fn findManagedMakensis(gpa: std.mem.Allocator, io: Io) !?[]const u8 {
    const home_dir = if (getEnv("ORIEL_HOME")) |h|
        if (h.len > 0) try gpa.dupe(u8, h) else null
    else blk: {
        const home_var = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
        const home = getEnv(home_var) orelse break :blk null;
        if (home.len == 0) break :blk null;
        break :blk try std.fs.path.join(gpa, &.{ home, ".oriel" });
    };
    const root = home_dir orelse return null;
    defer gpa.free(root);

    const nsis_dir = try std.fs.path.join(gpa, &.{ root, "nsis" });
    defer gpa.free(nsis_dir);

    var dir = Dir.cwd().openDir(io, nsis_dir, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .directory) continue;
        const candidate1 = try std.fs.path.join(gpa, &.{ nsis_dir, e.name, "makensis.exe" });
        if (pathExists(io, candidate1)) return candidate1;
        gpa.free(candidate1);

        const candidate2 = try std.fs.path.join(gpa, &.{ nsis_dir, e.name, "Bin", "makensis.exe" });
        if (pathExists(io, candidate2)) return candidate2;
        gpa.free(candidate2);
    }
    return null;
}

pub fn findMakensis(gpa: std.mem.Allocator, io: Io) ![]const u8 {
    const is_windows = builtin.os.tag == .windows;
    const exe_name = if (is_windows) "makensis.exe" else "makensis";

    // 1. Explicit override via ORIEL_MAKENSIS
    if (getEnv("ORIEL_MAKENSIS")) |env_path| {
        if (env_path.len > 0 and pathExists(io, env_path)) {
            return try gpa.dupe(u8, env_path);
        }
    }

    // 2. Managed NSIS: ~/.oriel/nsis/<version>/makensis.exe (or Bin/makensis.exe)
    if (findManagedMakensis(gpa, io) catch null) |managed| {
        return managed;
    }

    // 3. Search PATH entries from the environment
    if (getEnv("PATH")) |path_var| {
        var it = std.mem.splitScalar(u8, path_var, std.fs.path.delimiter);
        while (it.next()) |dir| {
            if (dir.len == 0) continue;
            const candidate = try std.fs.path.join(gpa, &.{ dir, exe_name });
            if (pathExists(io, candidate)) return candidate;
            gpa.free(candidate);
        }
    }

    // 4. Standard install locations (the NSIS installer does not add itself
    // to PATH on Windows).
    if (is_windows) {
        for ([_][]const u8{ "ProgramFiles(x86)", "ProgramFiles" }) |env| {
            const base = getEnv(env) orelse continue;
            const candidate = try std.fs.path.join(gpa, &.{ base, "NSIS", exe_name });
            if (pathExists(io, candidate)) return candidate;
            gpa.free(candidate);
        }
    } else {
        for ([_][]const u8{ "/usr/bin/makensis", "/usr/local/bin/makensis" }) |loc| {
            if (pathExists(io, loc)) return try gpa.dupe(u8, loc);
        }
    }

    return error.MakensisNotFound;
}

/// `path` made absolute, or null (error printed) when it doesn't exist.
fn absExistingFile(gpa: std.mem.Allocator, io: Io, path: []const u8) !?[]const u8 {
    if (!pathExists(io, path)) {
        std.debug.print("error: package-nsis: file not found: {s}\n", .{path});
        return null;
    }
    return try ensureAbsolutePath(gpa, io, path);
}

fn fileSize(io: Io, path: []const u8) u64 {
    const st = Dir.cwd().statFile(io, path, .{}) catch return 0;
    return st.size;
}

fn packageNsisCmd(gpa: std.mem.Allocator, io: Io, args: []const [:0]const u8) !u8 {
    var out_dir: ?[]const u8 = null;
    var filename: ?[]const u8 = null;
    var bin_path: ?[]const u8 = null;
    var icons_dir: ?[]const u8 = null;
    var icon_path_arg: ?[]const u8 = null;
    var webview2_loader: ?[]const u8 = null;
    var app_id: ?[]const u8 = null;
    var name: ?[]const u8 = null;
    var exe_name: ?[]const u8 = null;
    var version: []const u8 = "0.1.0";
    var publisher: ?[]const u8 = null;
    var homepage: ?[]const u8 = null;
    var url_schemes: std.ArrayList([]const u8) = .empty;
    defer url_schemes.deinit(gpa);
    var extras: contents.Contents = .{};
    defer extras.deinit(gpa);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (parseContentsArg(&extras, gpa, "package-nsis", args, &i) orelse return 1) {
            continue;
        } else if (std.mem.eql(u8, arg, "--out-dir") and i + 1 < args.len) {
            i += 1;
            out_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--filename") and i + 1 < args.len) {
            i += 1;
            filename = args[i];
        } else if (std.mem.eql(u8, arg, "--bin") and i + 1 < args.len) {
            i += 1;
            bin_path = args[i];
        } else if (std.mem.eql(u8, arg, "--icons-dir") and i + 1 < args.len) {
            i += 1;
            icons_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--icon") and i + 1 < args.len) {
            i += 1;
            icon_path_arg = args[i];
        } else if (std.mem.eql(u8, arg, "--webview2-loader") and i + 1 < args.len) {
            i += 1;
            webview2_loader = args[i];
        } else if (std.mem.eql(u8, arg, "--app-id") and i + 1 < args.len) {
            i += 1;
            app_id = args[i];
        } else if (std.mem.eql(u8, arg, "--name") and i + 1 < args.len) {
            i += 1;
            name = args[i];
        } else if (std.mem.eql(u8, arg, "--exe-name") and i + 1 < args.len) {
            i += 1;
            exe_name = args[i];
        } else if (std.mem.eql(u8, arg, "--version") and i + 1 < args.len) {
            i += 1;
            version = args[i];
        } else if (std.mem.eql(u8, arg, "--publisher") and i + 1 < args.len) {
            i += 1;
            publisher = args[i];
        } else if (std.mem.eql(u8, arg, "--homepage") and i + 1 < args.len) {
            i += 1;
            homepage = args[i];
        } else if (std.mem.eql(u8, arg, "--url-scheme") and i + 1 < args.len) {
            i += 1;
            try url_schemes.append(gpa, args[i]);
        }
    }

    const target_out_dir = out_dir orelse {
        std.debug.print("error: package-nsis: missing --out-dir\n", .{});
        return 1;
    };
    const target_filename = filename orelse {
        std.debug.print("error: package-nsis: missing --filename\n", .{});
        return 1;
    };
    const target_bin = bin_path orelse {
        std.debug.print("error: package-nsis: missing --bin\n", .{});
        return 1;
    };
    const target_name = name orelse "app";
    const target_exe_name = exe_name orelse target_name;
    const target_app_id = app_id orelse target_name;
    const target_publisher = publisher orelse metadata.organizationFromAppId(target_app_id);

    const clean_exe_name = if (std.mem.endsWith(u8, target_exe_name, ".exe"))
        target_exe_name[0 .. target_exe_name.len - 4]
    else
        target_exe_name;

    metadata.validateExeName(clean_exe_name) catch |err| {
        std.debug.print("error: package-nsis: invalid --exe-name '{s}': {s}\n", .{ target_exe_name, @errorName(err) });
        return 1;
    };
    {
        // What the installer itself puts in $INSTDIR.
        const app_exe_file = try std.fmt.allocPrint(gpa, "{s}.exe", .{clean_exe_name});
        defer gpa.free(app_exe_file);
        const taken = [_][]const u8{ app_exe_file, "Uninstall.exe", "WebView2Loader.dll" };
        if (!validateContents(&extras, "package-nsis", taken[0..if (webview2_loader != null) taken.len else 2])) return 1;
    }

    if (!pathExists(io, target_bin)) {
        std.debug.print("error: package-nsis: binary file not found: {s}\n", .{target_bin});
        return 1;
    }

    // Locate makensis
    const makensis_bin = findMakensis(gpa, io) catch |err| {
        switch (err) {
            error.MakensisNotFound => {
                std.debug.print("error: package-nsis: 'makensis' not found (run: oriel setup nsis)\n", .{});
                if (builtin.os.tag != .windows) {
                    std.debug.print("Install NSIS 3 to build Windows installers.\n", .{});
                }
            },
            else => std.debug.print("error: package-nsis: looking for makensis: {s}\n", .{@errorName(err)}),
        }
        return 1;
    };
    defer gpa.free(makensis_bin);

    // Ensure target out_dir exists
    try Dir.cwd().createDirPath(io, target_out_dir);

    const abs_out_dir = try ensureAbsolutePath(gpa, io, target_out_dir);
    defer gpa.free(abs_out_dir);

    const abs_bin = try ensureAbsolutePath(gpa, io, target_bin);
    defer gpa.free(abs_bin);

    const abs_out_file = try std.fs.path.join(gpa, &.{ abs_out_dir, target_filename });
    defer gpa.free(abs_out_file);

    // Resolve the .ico: `--icon` wins, else `<icons-dir>/icon.ico` written by resize-icons.
    var final_icon_path: ?[]const u8 = null;
    defer if (final_icon_path) |p| gpa.free(p);
    if (icon_path_arg) |arg_ico| {
        if (!std.mem.endsWith(u8, arg_ico, ".ico")) {
            std.debug.print("error: package-nsis: --icon must be a .ico file: {s}\n", .{arg_ico});
            return 1;
        }
        final_icon_path = try ensureAbsolutePath(gpa, io, arg_ico);
    } else if (icons_dir) |idir| {
        const candidate_ico = try std.fs.path.join(gpa, &.{ idir, "icon.ico" });
        defer gpa.free(candidate_ico);
        if (!pathExists(io, candidate_ico)) {
            std.debug.print("error: package-nsis: {s} not found (run resize-icons first)\n", .{candidate_ico});
            return 1;
        }
        final_icon_path = try ensureAbsolutePath(gpa, io, candidate_ico);
    }

    // Resolve webview2_loader
    var abs_wv2_loader: ?[]const u8 = null;
    defer if (abs_wv2_loader) |wl| gpa.free(wl);
    if (webview2_loader) |wl| {
        if (!pathExists(io, wl)) {
            std.debug.print("error: package-nsis: webview2-loader file not found: {s}\n", .{wl});
            return 1;
        }
        abs_wv2_loader = try ensureAbsolutePath(gpa, io, wl);
    }

    // Calculate estimated installed size in KiB
    var total_size_bytes: u64 = 0;
    if (Dir.cwd().statFile(io, abs_bin, .{})) |st| {
        total_size_bytes += st.size;
    } else |_| {}
    if (abs_wv2_loader) |wl| {
        if (Dir.cwd().statFile(io, wl, .{})) |st| {
            total_size_bytes += st.size;
        } else |_| {}
    }

    // Extra executables and files, with absolute sources (makensis runs with -NOCD).
    var abs_exes: std.ArrayList(contents.Exe) = .empty;
    defer {
        for (abs_exes.items) |e| gpa.free(e.src);
        abs_exes.deinit(gpa);
    }
    var abs_files: std.ArrayList(contents.File) = .empty;
    defer {
        for (abs_files.items) |f| gpa.free(f.src);
        abs_files.deinit(gpa);
    }
    for (extras.exes.items) |e| {
        const src = try absExistingFile(gpa, io, e.src) orelse return 1;
        abs_exes.append(gpa, .{ .src = src, .name = e.name }) catch |err| {
            gpa.free(src);
            return err;
        };
        total_size_bytes += fileSize(io, src);
    }
    for (extras.files.items) |f| {
        const src = try absExistingFile(gpa, io, f.src) orelse return 1;
        abs_files.append(gpa, .{ .src = src, .rel = f.rel }) catch |err| {
            gpa.free(src);
            return err;
        };
        total_size_bytes += fileSize(io, src);
    }
    const estimated_size_kb: u64 = if (total_size_bytes > 0) (total_size_bytes + 1023) / 1024 else 0;

    // Generate installer.nsi
    const nsi_path = try std.fs.path.join(gpa, &.{ abs_out_dir, "installer.nsi" });
    defer gpa.free(nsi_path);

    const script_content = nsis.generateNsisScript(gpa, .{
        .name = target_name,
        .exe_name = clean_exe_name,
        .version = version,
        .publisher = target_publisher,
        .id = target_app_id,
        .binary_src = abs_bin,
        .out_file = abs_out_file,
        .icon_path = final_icon_path,
        .webview2_loader = abs_wv2_loader,
        .homepage = homepage,
        .url_schemes = url_schemes.items,
        .estimated_size_kb = estimated_size_kb,
        .extra_exes = abs_exes.items,
        .extra_files = abs_files.items,
    }) catch |err| {
        std.debug.print("error: package-nsis: installer script: {s}\n", .{contents.describe(err)});
        return 1;
    };
    defer gpa.free(script_content);
    try Dir.cwd().writeFile(io, .{ .sub_path = nsi_path, .data = script_content });

    // Run makensis
    const res = std.process.run(gpa, io, .{
        .argv = &.{ makensis_bin, "-NOCD", "-WX", nsi_path },
    }) catch |err| {
        std.debug.print("error: package-nsis: failed to execute makensis: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);

    if (res.term != .exited or res.term.exited != 0) {
        std.debug.print("error: package-nsis: makensis failed:\n{s}{s}\n", .{ res.stdout, res.stderr });
        return 1;
    }

    if (!pathExists(io, abs_out_file)) {
        std.debug.print("error: package-nsis: output file '{s}' was not generated by makensis\n", .{abs_out_file});
        return 1;
    }

    return 0;
}

// ---------------------------------------------------------------------------
// package-app / package-dmg (macOS)
// ---------------------------------------------------------------------------

/// Run a command; print its output and fail when it doesn't exit 0.
fn runTool(gpa: std.mem.Allocator, io: Io, what: []const u8, argv: []const []const u8) !void {
    const res = std.process.run(gpa, io, .{ .argv = argv }) catch |err| {
        std.debug.print("error: {s}: failed to execute {s}: {s}\n", .{ what, argv[0], @errorName(err) });
        return error.ToolFailed;
    };
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    if (res.term != .exited or res.term.exited != 0) {
        std.debug.print("error: {s}: {s} failed:\n{s}{s}\n", .{ what, argv[0], res.stdout, res.stderr });
        return error.ToolFailed;
    }
}

/// Assemble `<out-dir>/<Name>.app` (see macos.zig for the layout). On a
/// macOS host the bundle is ad-hoc signed (`codesign --sign -`), which binds
/// Info.plist to it: permission prompts and notifications then name the app.
fn packageAppCmd(gpa: std.mem.Allocator, io: Io, args: []const [:0]const u8) !u8 {
    var out_dir: ?[]const u8 = null;
    var bin_path: ?[]const u8 = null;
    var icons_dir: ?[]const u8 = null;
    var app_id: ?[]const u8 = null;
    var name: ?[]const u8 = null;
    var exe_name: ?[]const u8 = null;
    var version: []const u8 = "0.1.0";
    var min_os: []const u8 = "13.0";
    var permissions: std.ArrayList(macos.Permission) = .empty;
    defer permissions.deinit(gpa);
    var sign = true;
    var url_schemes: std.ArrayList([]const u8) = .empty;
    defer url_schemes.deinit(gpa);
    var extras: contents.Contents = .{};
    defer extras.deinit(gpa);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const has_value = i + 1 < args.len;
        if (parseContentsArg(&extras, gpa, "package-app", args, &i) orelse return 1) {
            continue;
        } else if (std.mem.eql(u8, arg, "--out-dir") and has_value) {
            i += 1;
            out_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--bin") and has_value) {
            i += 1;
            bin_path = args[i];
        } else if (std.mem.eql(u8, arg, "--icons-dir") and has_value) {
            i += 1;
            icons_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--app-id") and has_value) {
            i += 1;
            app_id = args[i];
        } else if (std.mem.eql(u8, arg, "--name") and has_value) {
            i += 1;
            name = args[i];
        } else if (std.mem.eql(u8, arg, "--exe-name") and has_value) {
            i += 1;
            exe_name = args[i];
        } else if (std.mem.eql(u8, arg, "--version") and has_value) {
            i += 1;
            version = args[i];
        } else if (std.mem.eql(u8, arg, "--min-os") and has_value) {
            i += 1;
            min_os = args[i];
        } else if (std.mem.eql(u8, arg, "--url-scheme") and has_value) {
            i += 1;
            try url_schemes.append(gpa, args[i]);
        } else if (std.mem.eql(u8, arg, "--permission") and has_value) {
            // `<kind>=<usage text>`
            i += 1;
            const eq = std.mem.indexOfScalar(u8, args[i], '=') orelse {
                std.debug.print("error: package-app: --permission expects <kind>=<reason>, got {s}\n", .{args[i]});
                return 1;
            };
            try permissions.append(gpa, .{ .kind = args[i][0..eq], .reason = args[i][eq + 1 ..] });
        } else if (std.mem.eql(u8, arg, "--no-sign")) {
            sign = false;
        } else {
            std.debug.print("error: package-app: unknown argument {s}\n", .{arg});
            return 1;
        }
    }
    const missing: ?[]const u8 = if (out_dir == null) "--out-dir" else if (bin_path == null) "--bin" else if (app_id == null) "--app-id" else if (name == null) "--name" else if (exe_name == null) "--exe-name" else null;
    if (missing) |m| {
        std.debug.print("error: package-app: missing {s}\n", .{m});
        return 1;
    }
    metadata.validateExeName(exe_name.?) catch {
        std.debug.print("error: package-app: invalid --exe-name '{s}'\n", .{exe_name.?});
        return 1;
    };
    if (!validateContents(&extras, "package-app", &.{exe_name.?})) return 1;

    const bundle_name = macos.bundleDirName(gpa, name.?) catch |err| {
        std.debug.print("error: package-app: the app name \"{s}\" can't be a bundle name ({s}): use no '/', '\\' or ':', no control characters, and don't start with '.'\n", .{ name.?, @errorName(err) });
        return 1;
    };
    defer gpa.free(bundle_name);
    const bundle = try std.fs.path.join(gpa, &.{ out_dir.?, bundle_name });
    defer gpa.free(bundle);
    // A clean bundle every time (the output directory is a cache entry).
    Dir.cwd().deleteTree(io, bundle) catch {};
    const macos_dir = try std.fs.path.join(gpa, &.{ bundle, "Contents", "MacOS" });
    defer gpa.free(macos_dir);
    const res_dir = try std.fs.path.join(gpa, &.{ bundle, "Contents", "Resources" });
    defer gpa.free(res_dir);
    try Dir.cwd().createDirPath(io, macos_dir);
    try Dir.cwd().createDirPath(io, res_dir);

    const exe_dest = try std.fs.path.join(gpa, &.{ macos_dir, exe_name.? });
    defer gpa.free(exe_dest);
    try Dir.cwd().copyFile(bin_path.?, Dir.cwd(), exe_dest, io, .{ .permissions = filePerms(0o755) });
    // LSMinimumSystemVersion is the executable's own deployment target
    // (LC_BUILD_VERSION minos), so the two can't disagree: a bundle built on
    // a newer Mac otherwise claims to run where its code can't.
    var min_os_buf: [32]u8 = undefined;
    if (machoMinOsOfFile(io, bin_path.?)) |v| {
        const from_binary = std.fmt.bufPrint(&min_os_buf, "{f}", .{v}) catch unreachable;
        if (!std.mem.eql(u8, from_binary, min_os)) std.debug.print("note: package-app: LSMinimumSystemVersion {s} (the executable's deployment target; --min-os said {s})\n", .{ from_binary, min_os });
        min_os = from_binary;
        for (extras.exes.items) |e| {
            const ev = machoMinOsOfFile(io, e.src) orelse continue;
            if (ev.order(v) == .gt) std.debug.print("warning: package-app: {s} needs macOS {f}, the app {f}: build it with the app's target (oriel.resolveTarget)\n", .{ e.name, ev, v });
        }
    }
    // Extra executables and code in Contents/MacOS, other files in
    // Contents/Resources (linked from MacOS).
    copyContentsMac(gpa, io, &extras, bundle) catch |err| switch (err) {
        error.BadLayout => return 1,
        else => return err,
    };

    var has_icon = false;
    if (icons_dir) |idir| {
        const src_icns = try std.fs.path.join(gpa, &.{ idir, "icon.icns" });
        defer gpa.free(src_icns);
        const dest_icns = try std.fs.path.join(gpa, &.{ res_dir, "icon.icns" });
        defer gpa.free(dest_icns);
        if (pathExists(io, src_icns)) {
            try Dir.cwd().copyFile(src_icns, Dir.cwd(), dest_icns, io, .{});
            has_icon = true;
        } else {
            std.debug.print("warning: package-app: {s} not found (run resize-icons first); no icon\n", .{src_icns});
        }
    }

    const plist = macos.generateInfoPlist(gpa, .{
        .id = app_id.?,
        .name = name.?,
        .exe_name = exe_name.?,
        .version = version,
        .min_os = min_os,
        .icon_name = if (has_icon) "icon" else null,
        .url_schemes = url_schemes.items,
        .permissions = permissions.items,
    }) catch |err| {
        std.debug.print("error: package-app: Info.plist: {s} (package metadata must be UTF-8 without control characters; URL schemes must match [A-Za-z][A-Za-z0-9+.-]*)\n", .{@errorName(err)});
        return 1;
    };
    defer gpa.free(plist);
    const plist_path = try std.fs.path.join(gpa, &.{ bundle, "Contents", "Info.plist" });
    defer gpa.free(plist_path);
    try Dir.cwd().writeFile(io, .{ .sub_path = plist_path, .data = plist });
    const pkginfo_path = try std.fs.path.join(gpa, &.{ bundle, "Contents", "PkgInfo" });
    defer gpa.free(pkginfo_path);
    try Dir.cwd().writeFile(io, .{ .sub_path = pkginfo_path, .data = "APPL????" });

    // Next to the bundle, for Developer ID signing with the hardened runtime:
    // `codesign --options runtime --entitlements <Name>.entitlements ...`.
    const ent = try macos.generateEntitlements(gpa, permissions.items);
    defer gpa.free(ent);
    const ent_path = try std.fmt.allocPrint(gpa, "{s}.entitlements", .{bundle[0 .. bundle.len - ".app".len]});
    defer gpa.free(ent_path);
    try Dir.cwd().writeFile(io, .{ .sub_path = ent_path, .data = ent });

    if (sign and builtin.os.tag == .macos) {
        // Nested code first (inside-out), then the bundle, which seals it.
        const nested = sign_macos.nestedCode(gpa, io, bundle, exe_name.?) catch |err| {
            std.debug.print("error: package-app: looking for nested code in {s}: {s}\n", .{ bundle, @errorName(err) });
            return 1;
        };
        defer sign_macos.freeNested(gpa, nested);
        for (nested) |n| {
            const path = try std.fs.path.join(gpa, &.{ bundle, n.path });
            defer gpa.free(path);
            runTool(gpa, io, "package-app", &.{ "/usr/bin/codesign", "--force", "--sign", "-", path }) catch return 1;
        }
        runTool(gpa, io, "package-app", &.{ "/usr/bin/codesign", "--force", "--sign", "-", bundle }) catch return 1;
    }
    return 0;
}

/// `install-app --from <bundle> --to <dest>`: delete `dest`, then copy the
/// bundle there (modes and symlinks kept). An install directory step would
/// leave files from older builds behind, which breaks the code signature.
fn installAppCmd(gpa: std.mem.Allocator, io: Io, args: []const [:0]const u8) !u8 {
    var from: ?[]const u8 = null;
    var to: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--from") and i + 1 < args.len) {
            i += 1;
            from = args[i];
        } else if (std.mem.eql(u8, args[i], "--to") and i + 1 < args.len) {
            i += 1;
            to = args[i];
        } else {
            std.debug.print("error: install-app: unknown argument {s}\n", .{args[i]});
            return 1;
        }
    }
    if (from == null or to == null) {
        std.debug.print("error: install-app: needs --from and --to\n", .{});
        return 1;
    }
    if (!std.mem.endsWith(u8, to.?, ".app")) {
        std.debug.print("error: install-app: --to must be a .app path: {s}\n", .{to.?});
        return 1;
    }
    try copyTreeFresh(gpa, io, from.?, to.?);
    return 0;
}

/// Replace `dest` with a copy of the directory tree `src`.
pub fn copyTreeFresh(gpa: std.mem.Allocator, io: Io, src: []const u8, dest: []const u8) !void {
    try Dir.cwd().deleteTree(io, dest);
    try Dir.cwd().createDirPath(io, dest);
    var src_dir = try Dir.cwd().openDir(io, src, .{ .iterate = true });
    defer src_dir.close(io);
    var dest_dir = try Dir.cwd().openDir(io, dest, .{});
    defer dest_dir.close(io);
    var walker = try src_dir.walk(gpa);
    defer walker.deinit();
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (try walker.next(io)) |entry| switch (entry.kind) {
        .directory => try dest_dir.createDirPath(io, entry.path),
        .file => try entry.dir.copyFile(entry.basename, dest_dir, entry.path, io, .{}),
        .sym_link => {
            const n = try entry.dir.readLink(io, entry.basename, &link_buf);
            try dest_dir.symLink(io, link_buf[0..n], entry.path, .{});
        },
        else => {},
    };
}

test copyTreeFresh {
    // .app bundles are packaged on macOS; Windows symlinks need Developer Mode and read back with `\`.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src/A.app/Contents/MacOS");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/A.app/Contents/MacOS/a", .data = "new" });
    try tmp.dir.symLink(io, "MacOS/a", "src/A.app/Contents/link", .{});
    try tmp.dir.createDirPath(io, "dest/A.app/Contents/MacOS");
    try tmp.dir.writeFile(io, .{ .sub_path = "dest/A.app/Contents/MacOS/stale", .data = "old" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const src = try std.fs.path.join(gpa, &.{ root, "src", "A.app" });
    defer gpa.free(src);
    const dest = try std.fs.path.join(gpa, &.{ root, "dest", "A.app" });
    defer gpa.free(dest);
    try copyTreeFresh(gpa, io, src, dest);
    const got = try tmp.dir.readFileAlloc(io, "dest/A.app/Contents/MacOS/a", gpa, .limited(16));
    defer gpa.free(got);
    try std.testing.expectEqualStrings("new", got);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "dest/A.app/Contents/MacOS/stale", .{}));
    var buf: [64]u8 = undefined;
    const n = try tmp.dir.readLink(io, "dest/A.app/Contents/link", &buf);
    try std.testing.expectEqualStrings("MacOS/a", buf[0..n]);
}

/// `<out-dir>/<filename>`: a compressed disk image holding the .app and a
/// link to /Applications (drag to install). Needs `hdiutil` (macOS hosts).
fn packageDmgCmd(gpa: std.mem.Allocator, io: Io, args: []const [:0]const u8) !u8 {
    var out_dir: ?[]const u8 = null;
    var filename: ?[]const u8 = null;
    var volname: ?[]const u8 = null;
    var app_path: ?[]const u8 = null;
    var identity: ?[]const u8 = null;
    var profile: ?[]const u8 = null;
    var dry_run = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const has_value = i + 1 < args.len;
        if (std.mem.eql(u8, arg, "--out-dir") and has_value) {
            i += 1;
            out_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--filename") and has_value) {
            i += 1;
            filename = args[i];
        } else if (std.mem.eql(u8, arg, "--volname") and has_value) {
            i += 1;
            volname = args[i];
        } else if (std.mem.eql(u8, arg, "--app") and has_value) {
            i += 1;
            app_path = args[i];
        } else if (std.mem.eql(u8, arg, "--identity") and has_value) {
            i += 1;
            identity = args[i];
        } else if (std.mem.eql(u8, arg, "--notarize-profile") and has_value) {
            i += 1;
            profile = args[i];
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else {
            std.debug.print("error: package-dmg: unknown argument {s}\n", .{arg});
            return 1;
        }
    }
    if (out_dir == null or filename == null or volname == null or app_path == null) {
        std.debug.print("error: package-dmg: needs --out-dir, --filename, --volname and --app\n", .{});
        return 1;
    }
    for ([_][]const u8{ out_dir.?, filename.?, app_path.? }) |path| {
        if (!sign_macos.validPath(path)) {
            std.debug.print("error: package-dmg: invalid path {s}\n", .{path});
            return 1;
        }
    }
    if (identity) |id| if (!sign_macos.validIdentity(id)) {
        std.debug.print("error: package-dmg: invalid signing identity\n", .{});
        return 1;
    };
    if (profile) |p| if (!sign_macos.validProfile(p)) {
        std.debug.print("error: package-dmg: invalid notarytool profile name\n", .{});
        return 1;
    };
    if (profile != null and !dry_run and (identity == null or std.mem.eql(u8, identity.?, sign_macos.ad_hoc))) {
        std.debug.print("error: package-dmg: notarization needs a Developer ID identity (-Dmacos-sign-identity)\n", .{});
        return 1;
    }
    if (builtin.os.tag != .macos) {
        std.debug.print("error: package-dmg: .dmg images are built with hdiutil, on a macOS host (the .app bundle itself builds anywhere: `zig build package-app`)\n", .{});
        return 1;
    }

    const stage = try std.fs.path.join(gpa, &.{ out_dir.?, "dmg-root" });
    defer gpa.free(stage);
    Dir.cwd().deleteTree(io, stage) catch {};
    try Dir.cwd().createDirPath(io, stage);
    defer Dir.cwd().deleteTree(io, stage) catch {};
    const staged_app = try std.fs.path.join(gpa, &.{ stage, std.fs.path.basename(app_path.?) });
    defer gpa.free(staged_app);
    // ditto keeps the bundle's symlinks, modes and code signature.
    runTool(gpa, io, "package-dmg", &.{ "/usr/bin/ditto", app_path.?, staged_app }) catch return 1;
    var stage_dir = try Dir.cwd().openDir(io, stage, .{});
    defer stage_dir.close(io);
    try stage_dir.symLink(io, "/Applications", "Applications", .{});

    const dmg = try std.fs.path.join(gpa, &.{ out_dir.?, filename.? });
    defer gpa.free(dmg);
    runTool(gpa, io, "package-dmg", &.{ "/usr/bin/hdiutil", "create", "-quiet", "-volname", volname.?, "-srcfolder", stage, "-ov", "-format", "UDZO", dmg }) catch return 1;
    sign_macos.finishDmg(gpa, io, dmg, identity, profile, dry_run) catch return 1;
    return 0;
}

// ---------------------------------------------------------------------------
// install-desktop-entry
// ---------------------------------------------------------------------------

fn installDesktopEntryCmd(gpa: std.mem.Allocator, io: Io, args: []const [:0]const u8) !u8 {
    var desktop_src: ?[]const u8 = null;
    var icons_dir: ?[]const u8 = null;
    var app_id: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--desktop") and i + 1 < args.len) {
            i += 1;
            desktop_src = args[i];
        } else if (std.mem.eql(u8, arg, "--icons-dir") and i + 1 < args.len) {
            i += 1;
            icons_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--app-id") and i + 1 < args.len) {
            i += 1;
            app_id = args[i];
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

    // Determine target data home per XDG Base Directory specification:
    // Relative paths and empty values are invalid and treated as unset -> fall back to $HOME/.local/share
    const env_map = global_environ_map orelse {
        std.debug.print("error: install-desktop-entry: environment not available\n", .{});
        return 1;
    };
    const data_home = resolveDataHome(gpa, env_map) catch {
        std.debug.print("error: install-desktop-entry: neither XDG_DATA_HOME nor HOME is set to a valid absolute path\n", .{});
        return 1;
    };
    defer gpa.free(data_home);

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

pub fn resolveDataHome(gpa: std.mem.Allocator, env_map: *const std.process.Environ.Map) ![]const u8 {
    if (env_map.get("XDG_DATA_HOME")) |xdg| {
        if (xdg.len > 0 and std.fs.path.isAbsolute(xdg)) {
            return try gpa.dupe(u8, xdg);
        }
    }
    if (env_map.get("HOME")) |home| {
        if (home.len > 0 and std.fs.path.isAbsolute(home)) {
            return try std.fmt.allocPrint(gpa, "{s}/.local/share", .{home});
        }
    }
    return error.NoValidDataHome;
}

test {
    std.testing.refAllDecls(metadata);
    std.testing.refAllDecls(desktop);
    std.testing.refAllDecls(nfpm);
    std.testing.refAllDecls(appimage);
    std.testing.refAllDecls(icons);
    std.testing.refAllDecls(ico);
    std.testing.refAllDecls(nsis);
    std.testing.refAllDecls(icns);
    std.testing.refAllDecls(sign_macos);
    std.testing.refAllDecls(macos);
    std.testing.refAllDecls(contents);
    std.testing.refAllDecls(elf_strip);
}

test "resizeIcons custom png no overflow on large sizes" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    // Create a 300x300 solid color PNG image
    const src_png_path = try std.fs.path.join(allocator, &.{ tmp_path, "custom-icon.png" });
    defer allocator.free(src_png_path);

    var img = try zigimg.Image.create(allocator, 300, 300, .rgba32);
    defer img.deinit(allocator);
    @memset(img.pixels.rgba32, .{ .r = 42, .g = 84, .b = 168, .a = 255 });

    const png_buf = try allocator.alloc(u8, 300 * 300 * 8 + 4096);
    defer allocator.free(png_buf);
    const encoded = try img.writeToMemory(allocator, png_buf, .{ .png = .{} });
    try Dir.cwd().writeFile(io, .{ .sub_path = src_png_path, .data = encoded });

    // Output dir for resized icons
    const out_dir = try std.fs.path.join(allocator, &.{ tmp_path, "icons" });
    defer allocator.free(out_dir);

    try resizeIcons(allocator, io, src_png_path, out_dir, null);

    // Verify all icon sizes were generated, especially 128, 256, 512
    for (icons.icon_sizes) |size| {
        const out_icon = try std.fmt.allocPrint(allocator, "{s}/{d}x{d}.png", .{ out_dir, size, size });
        defer allocator.free(out_icon);
        const data = try Dir.cwd().readFileAlloc(io, out_icon, allocator, .limited(10 * 1024 * 1024));
        defer allocator.free(data);
        try std.testing.expect(data.len > 0);

        var read_img = try zigimg.Image.fromMemory(allocator, data);
        defer read_img.deinit(allocator);
        try std.testing.expectEqual(@as(usize, size), read_img.width);
        try std.testing.expectEqual(@as(usize, size), read_img.height);
    }

    // Verify icon.ico was generated
    const out_ico = try std.fs.path.join(allocator, &.{ out_dir, "icon.ico" });
    defer allocator.free(out_ico);
    const ico_data = try Dir.cwd().readFileAlloc(io, out_ico, allocator, .limited(10 * 1024 * 1024));
    defer allocator.free(ico_data);
    try std.testing.expect(ico_data.len > 6);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, ico_data[2..4], .little));

    // Verify app.rc was generated
    const out_rc = try std.fs.path.join(allocator, &.{ out_dir, "app.rc" });
    defer allocator.free(out_rc);
    const rc_data = try Dir.cwd().readFileAlloc(io, out_rc, allocator, .limited(1024));
    defer allocator.free(rc_data);
    try std.testing.expectEqualStrings("1 ICON \"icon.ico\"\n", rc_data);
}

test "resolveDataHome pure path resolution" {
    const allocator = std.testing.allocator;

    // 1. Valid absolute XDG_DATA_HOME
    {
        var env = std.process.Environ.Map.init(allocator);
        defer env.deinit();
        try env.put("XDG_DATA_HOME", "/custom/data/home");
        try env.put("HOME", "/home/user");

        const res = try resolveDataHome(allocator, &env);
        defer allocator.free(res);
        try std.testing.expectEqualStrings("/custom/data/home", res);
    }

    // 2. Empty XDG_DATA_HOME -> fallback to $HOME/.local/share
    {
        var env = std.process.Environ.Map.init(allocator);
        defer env.deinit();
        try env.put("XDG_DATA_HOME", "");
        try env.put("HOME", "/home/user");

        const res = try resolveDataHome(allocator, &env);
        defer allocator.free(res);
        try std.testing.expectEqualStrings("/home/user/.local/share", res);
    }

    // 3. Relative XDG_DATA_HOME -> invalid and ignored per XDG spec -> fallback to $HOME/.local/share
    {
        var env = std.process.Environ.Map.init(allocator);
        defer env.deinit();
        try env.put("XDG_DATA_HOME", "relative/path");
        try env.put("HOME", "/home/user");

        const res = try resolveDataHome(allocator, &env);
        defer allocator.free(res);
        try std.testing.expectEqualStrings("/home/user/.local/share", res);
    }

    // 4. Dot XDG_DATA_HOME -> invalid and ignored
    {
        var env = std.process.Environ.Map.init(allocator);
        defer env.deinit();
        try env.put("XDG_DATA_HOME", ".");
        try env.put("HOME", "/home/user");

        const res = try resolveDataHome(allocator, &env);
        defer allocator.free(res);
        try std.testing.expectEqualStrings("/home/user/.local/share", res);
    }

    // 5. Unset XDG_DATA_HOME -> fallback to $HOME/.local/share
    {
        var env = std.process.Environ.Map.init(allocator);
        defer env.deinit();
        try env.put("HOME", "/home/alice");

        const res = try resolveDataHome(allocator, &env);
        defer allocator.free(res);
        try std.testing.expectEqualStrings("/home/alice/.local/share", res);
    }

    // 6. Both unset -> error
    {
        var env = std.process.Environ.Map.init(allocator);
        defer env.deinit();

        try std.testing.expectError(error.NoValidDataHome, resolveDataHome(allocator, &env));
    }
}

test "streamCopyFile creates exact byte copy" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    const src_path = try std.fs.path.join(allocator, &.{ tmp_path, "src.bin" });
    defer allocator.free(src_path);
    const dest_path = try std.fs.path.join(allocator, &.{ tmp_path, "dest.bin" });
    defer allocator.free(dest_path);

    // Create 128 KiB of test data
    const test_data = try allocator.alloc(u8, 128 * 1024);
    defer allocator.free(test_data);
    for (test_data, 0..) |*b, idx| {
        b.* = @truncate(idx * 31 + 7);
    }
    try Dir.cwd().writeFile(io, .{ .sub_path = src_path, .data = test_data });

    var dest_file = try Dir.cwd().createFile(io, dest_path, .{ .permissions = filePerms(0o644) });
    defer dest_file.close(io);
    try streamCopyFile(io, Dir.cwd(), src_path, dest_file);

    const copied_data = try Dir.cwd().readFileAlloc(io, dest_path, allocator, .limited(1024 * 1024));
    defer allocator.free(copied_data);
    try std.testing.expectEqualSlices(u8, test_data, copied_data);
}

/// The environment the makensis tests give findMakensis: the usual POSIX
/// PATH, plus on Windows the real Program Files dirs, where the NSIS
/// installer puts makensis without adding it to PATH.
fn putMakensisTestEnv(allocator: std.mem.Allocator, env: *std.process.Environ.Map) !void {
    try env.put("PATH", "/usr/bin:/usr/local/bin");
    if (builtin.os.tag != .windows) return;
    for ([_][]const u8{ "ProgramFiles(x86)", "ProgramFiles" }) |key| {
        const value = std.testing.environ.getAlloc(allocator, key) catch continue;
        defer allocator.free(value);
        try env.put(key, value);
    }
}

test "findMakensis locates makensis binary" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try putMakensisTestEnv(allocator, &env);
    global_environ_map = &env;
    defer global_environ_map = null;

    // NSIS is optional on build hosts.
    const bin = findMakensis(allocator, io) catch |err| switch (err) {
        error.MakensisNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(bin);

    try std.testing.expect(std.mem.endsWith(u8, bin, if (builtin.os.tag == .windows) "makensis.exe" else "makensis"));
}

test "packageNsisCmd builds Windows installer with makensis" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try putMakensisTestEnv(allocator, &env);
    global_environ_map = &env;
    defer global_environ_map = null;

    // NSIS is optional on build hosts.
    const makensis = findMakensis(allocator, io) catch |err| switch (err) {
        error.MakensisNotFound => return error.SkipZigTest,
        else => return err,
    };
    allocator.free(makensis);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    // Create a dummy binary
    const bin_path = try std.fs.path.join(allocator, &.{ tmp_path, "sample-app.exe" });
    defer allocator.free(bin_path);
    try tmp.dir.writeFile(io, .{ .sub_path = "sample-app.exe", .data = "MZdummy-binary-content" });

    // Create a dummy icon
    const ico_path = try std.fs.path.join(allocator, &.{ tmp_path, "sample.ico" });
    defer allocator.free(ico_path);
    const dummy_entry = [_]ico.PngIconEntry{.{ .width = 16, .height = 16, .png_data = &[_]u8{ 0x89, 'P', 'N', 'G', 0, 0, 0, 0 } }};
    const ico_bytes = try ico.writeIcoFromPngs(allocator, &dummy_entry);
    defer allocator.free(ico_bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = "sample.ico", .data = ico_bytes });

    const out_dir = try std.fs.path.join(allocator, &.{ tmp_path, "out" });
    defer allocator.free(out_dir);

    const out_dir_z = try allocator.dupeZ(u8, out_dir);
    defer allocator.free(out_dir_z);
    const bin_path_z = try allocator.dupeZ(u8, bin_path);
    defer allocator.free(bin_path_z);
    const ico_path_z = try allocator.dupeZ(u8, ico_path);
    defer allocator.free(ico_path_z);

    // Extras: a CLI next to the app and a data file in a subdirectory.
    try tmp.dir.writeFile(io, .{ .sub_path = "sample-cli.exe", .data = "MZdummy-cli" });
    try tmp.dir.writeFile(io, .{ .sub_path = "model.bin", .data = "weights" });
    const cli_z = try std.fs.path.joinZ(allocator, &.{ tmp_path, "sample-cli.exe" });
    defer allocator.free(cli_z);
    // A native path, as the build system passes: makensis on Windows finds no file at "C:\...\tmp/model.bin".
    const model_src = try std.fs.path.join(allocator, &.{ tmp_path, "model.bin" });
    defer allocator.free(model_src);
    const model_arg = try std.fmt.allocPrintSentinel(allocator, "data/models/model.bin={s}", .{model_src}, 0);
    defer allocator.free(model_arg);

    const args = [_][:0]const u8{
        "--out-dir",
        out_dir_z,
        "--filename",
        "sample-1.0.0-setup.exe",
        "--name",
        "Sample App $1",
        "--exe-name",
        "sample-app",
        "--version",
        "1.0.0",
        "--publisher",
        "Sample \"Publisher\"",
        "--app-id",
        "dev.oriel.SampleApp",
        "--bin",
        bin_path_z,
        "--icon",
        ico_path_z,
        "--url-scheme",
        "sample-scheme",
        "--extra-exe",
        cli_z,
        "--extra-file",
        model_arg,
    };

    const status = try packageNsisCmd(allocator, io, &args);
    try std.testing.expectEqual(@as(u8, 0), status);

    const nsi_path = try std.fs.path.join(allocator, &.{ out_dir, "installer.nsi" });
    defer allocator.free(nsi_path);
    const nsi = try Dir.cwd().readFileAlloc(io, nsi_path, allocator, .limited(1024 * 1024));
    defer allocator.free(nsi);
    try std.testing.expect(std.mem.indexOf(u8, nsi, "File \"/oname=$INSTDIR\\sample-cli.exe\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, nsi, "File \"/oname=$INSTDIR\\data\\models\\model.bin\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, nsi, "RMDir \"$INSTDIR\\data\\models\"\n  RMDir \"$INSTDIR\\data\"") != null);

    // Verify output installer exists
    const setup_exe_path = try std.fs.path.join(allocator, &.{ out_dir, "sample-1.0.0-setup.exe" });
    defer allocator.free(setup_exe_path);

    const setup_data = try Dir.cwd().readFileAlloc(io, setup_exe_path, allocator, .limited(10 * 1024 * 1024));
    defer allocator.free(setup_data);
    try std.testing.expect(setup_data.len > 1000);
}

test "packageAppCmd puts extra executables and files in Contents/MacOS" {
    // Unsigned here (codesign is macOS-only); POSIX modes checked below.
    if (builtin.os.tag == .windows or builtin.os.tag == .macos) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "notes", .data = "app" });
    try tmp.dir.writeFile(io, .{ .sub_path = "notes-cli", .data = "cli" });
    try tmp.dir.writeFile(io, .{ .sub_path = "m.bin", .data = "model" });
    try tmp.dir.writeFile(io, .{ .sub_path = "libx.dylib", .data = &[_]u8{ 0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 0x01, 0, 0, 0, 0, 6, 0, 0, 0 } });
    const lib_arg = try std.fmt.allocPrintSentinel(gpa, "lib/libx.dylib={s}/libx.dylib", .{root}, 0);
    defer gpa.free(lib_arg);
    const out_z = try std.fs.path.joinZ(gpa, &.{ root, "out" });
    defer gpa.free(out_z);
    const bin_z = try std.fs.path.joinZ(gpa, &.{ root, "notes" });
    defer gpa.free(bin_z);
    const cli_z = try std.fs.path.joinZ(gpa, &.{ root, "notes-cli" });
    defer gpa.free(cli_z);
    const file_arg = try std.fmt.allocPrintSentinel(gpa, "data/m.bin={s}/m.bin", .{root}, 0);
    defer gpa.free(file_arg);
    const args = [_][:0]const u8{ "--out-dir", out_z, "--app-id", "dev.oriel.Notes", "--name", "Notes", "--exe-name", "notes", "--bin", bin_z, "--extra-exe", cli_z, "--extra-file", file_arg, "--extra-file", lib_arg };
    try std.testing.expectEqual(@as(u8, 0), try packageAppCmd(gpa, io, &args));

    const cli = try tmp.dir.readFileAlloc(io, "out/Notes.app/Contents/MacOS/notes-cli", gpa, .limited(16));
    defer gpa.free(cli);
    try std.testing.expectEqualStrings("cli", cli);
    // Data goes to Resources, reachable through Contents/MacOS/data.
    const model = try tmp.dir.readFileAlloc(io, "out/Notes.app/Contents/Resources/data/m.bin", gpa, .limited(16));
    defer gpa.free(model);
    try std.testing.expectEqualStrings("model", model);
    var link_buf: [64]u8 = undefined;
    const link_len = try tmp.dir.readLink(io, "out/Notes.app/Contents/MacOS/data", &link_buf);
    try std.testing.expectEqualStrings("../Resources/data", link_buf[0..link_len]);
    const via_link = try tmp.dir.readFileAlloc(io, "out/Notes.app/Contents/MacOS/data/m.bin", gpa, .limited(16));
    defer gpa.free(via_link);
    try std.testing.expectEqualStrings("model", via_link);
    // A Mach-O library stays in MacOS.
    const dylib = try tmp.dir.readFileAlloc(io, "out/Notes.app/Contents/MacOS/lib/libx.dylib", gpa, .limited(64));
    defer gpa.free(dylib);
    try std.testing.expectEqual(@as(u8, 0xcf), dylib[0]);
    const st = try tmp.dir.statFile(io, "out/Notes.app/Contents/MacOS/notes-cli", .{});
    try std.testing.expectEqual(@as(u32, 0o755), @as(u32, @intCast(st.permissions.toMode())) & 0o777);
}

test "stripElfCmd strips an ELF file and copies anything else" {
    if (builtin.object_format != .elf or @sizeOf(usize) != 8) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const out_z = try std.fs.path.joinZ(gpa, &.{ root, "stripped" });
    defer gpa.free(out_z);
    const self_st = Dir.cwd().statFile(io, "/proc/self/exe", .{}) catch return error.SkipZigTest;
    try std.testing.expectEqual(@as(u8, 0), try stripElfCmd(gpa, io, &.{ "--in", "/proc/self/exe", "--out", out_z }));
    const st = try Dir.cwd().statFile(io, out_z, .{});
    try std.testing.expect(st.size <= self_st.size);
    try std.testing.expect(st.permissions.toMode() & 0o100 != 0); // still executable

    try tmp.dir.writeFile(io, .{ .sub_path = "text", .data = "not elf" });
    const text_z = try std.fs.path.joinZ(gpa, &.{ root, "text" });
    defer gpa.free(text_z);
    try std.testing.expectEqual(@as(u8, 0), try stripElfCmd(gpa, io, &.{ "--in", text_z, "--out", out_z }));
    const copy = try Dir.cwd().readFileAlloc(io, out_z, gpa, .limited(64));
    defer gpa.free(copy);
    try std.testing.expectEqualStrings("not elf", copy);
}

test "generateDesktopCmd with --url-scheme" {
    // .desktop files are validated with desktop-file-validate (Linux).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    const out_file = try std.fs.path.join(allocator, &.{ tmp_path, "test.desktop" });
    defer allocator.free(out_file);
    const out_file_z = try allocator.dupeZ(u8, out_file);
    defer allocator.free(out_file_z);

    const args = [_][:0]const u8{
        "--out",
        out_file_z,
        "--id",
        "dev.oriel.TestApp",
        "--name",
        "Test App",
        "--exec",
        "test-app",
        "--icon",
        "test-icon",
        "--url-scheme",
        "test-scheme",
        "--url-scheme",
        "oriel-custom",
    };

    const status = try generateDesktopCmd(allocator, io, &args);
    try std.testing.expectEqual(@as(u8, 0), status);

    const content = try Dir.cwd().readFileAlloc(io, out_file, allocator, .limited(64 * 1024));
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "Exec=test-app %u\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "MimeType=x-scheme-handler/test-scheme;x-scheme-handler/oriel-custom;\n") != null);
}

/// POSIX mode on Linux/macOS; Windows has attributes instead of modes (and
/// `@enumFromInt(0o755)` there would set read-only/system/... attribute bits).
fn filePerms(mode: u32) std.Io.File.Permissions {
    return if (builtin.os.tag == .windows) .default_file else .fromMode(@intCast(mode));
}
