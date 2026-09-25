//! macOS-specific operations for the self-updater core.
//!
//! - Plain executables (the `oriel` CLI, unbundled apps; formats `raw`,
//!   `raw.gz`): the file is renamed over the running binary.
//! - `.app` bundles (format `app.tar.gz`: a gzip'd tar of one `<Name>.app`):
//!   unpacked into a staging directory next to the running bundle (same
//!   volume), then swapped with it atomically (`renameatx_np` RENAME_SWAP),
//!   and the old bundle is deleted. `restart` relaunches a bundle with
//!   `open -n` so Launch Services starts the new copy.

const std = @import("std");
const updater = @import("../../updater_core.zig");

pub fn processId() u32 {
    return @intCast(std.c.getpid()); // raw Linux syscalls are SIGSYS here
}

pub fn syncDir(parent_dir: std.Io.Dir) !void {
    switch (std.posix.errno(std.c.fsync(parent_dir.handle))) {
        .SUCCESS => {},
        else => return error.DirSyncFailed,
    }
}

pub fn installFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    parent_dir: std.Io.Dir,
    tmp_name: []const u8,
    target_path: []const u8,
) !void {
    _ = gpa;
    const target_name = std.fs.path.basename(target_path);
    try parent_dir.rename(tmp_name, parent_dir, target_name, io);
}

/// Nothing to clean up: rename(2) replaces the running binary in place.
pub fn cleanupStale(_: std.Io, _: std.mem.Allocator) void {}

/// No AppImages on macOS.
pub fn runningAsAppImage(_: std.Io, _: std.mem.Allocator, _: bool, _: ?[]const u8) !bool {
    return false;
}

// <stdio.h>, macOS 10.12+: rename with flags.
extern "c" fn renameatx_np(fromfd: c_int, from: [*:0]const u8, tofd: c_int, to: [*:0]const u8, flags: c_uint) c_int;
const RENAME_SWAP: c_uint = 0x2;

/// The `.app` bundle directory containing `path` (e.g. an executable in
/// `Foo.app/Contents/MacOS/`), or null. A slice of `path`.
pub fn enclosingBundle(path: []const u8) ?[]const u8 {
    const marker = ".app/Contents/MacOS/";
    const idx = std.mem.lastIndexOf(u8, path, marker) orelse return null;
    return path[0 .. idx + ".app".len];
}

/// Replace the bundle at `bundle_path` with the `.app` inside the gzip'd tar
/// `payload_name` (in `payload_dir`, already hash-verified).
pub fn installBundle(io: std.Io, gpa: std.mem.Allocator, payload_dir: std.Io.Dir, payload_name: []const u8, bundle_path: []const u8) !void {
    const parent_path = std.fs.path.dirname(bundle_path) orelse return error.NotInAppBundle;
    const bundle_name = std.fs.path.basename(bundle_path);
    var parent = try std.Io.Dir.cwd().openDir(io, parent_path, .{ .iterate = true });
    defer parent.close(io);

    var rand_val: u64 = undefined;
    io.random(std.mem.asBytes(&rand_val));
    const staging_name = try std.fmt.allocPrint(gpa, ".{s}.update.{d}.{x}", .{ bundle_name, processId(), rand_val });
    defer gpa.free(staging_name);
    try parent.createDir(io, staging_name, .fromMode(0o755));
    // Holds the new bundle until the swap, then the old one: removed either way.
    defer parent.deleteTree(io, staging_name) catch {};
    var staging = try parent.openDir(io, staging_name, .{ .iterate = true });
    defer staging.close(io);

    // First pass: std.tar.extract writes symlinks as they are and later
    // entries through them, so check the links before extracting.
    {
        const payload = try payload_dir.openFile(io, payload_name, .{});
        defer payload.close(io);
        var read_buf: [65536]u8 = undefined;
        var file_reader = payload.readerStreaming(io, &read_buf);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var gz: std.compress.flate.Decompress = .init(&file_reader.interface, .gzip, &window);
        var file_name_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var link_name_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var tar_it: std.tar.Iterator = .init(&gz.reader, .{
            .file_name_buffer = &file_name_buffer,
            .link_name_buffer = &link_name_buffer,
        });
        var guard: LinkGuard = .init(gpa);
        defer guard.deinit();
        while (try tar_it.next()) |file| try guard.entry(file.kind, file.name, file.link_name);
    }

    {
        const payload = try payload_dir.openFile(io, payload_name, .{});
        defer payload.close(io);
        var read_buf: [65536]u8 = undefined;
        var file_reader = payload.readerStreaming(io, &read_buf);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var gz: std.compress.flate.Decompress = .init(&file_reader.interface, .gzip, &window);
        try std.tar.extract(io, staging, &gz.reader, .{ .mode_mode = .executable_bit_only });
    }

    // Exactly one top-level `<Name>.app` directory.
    var new_app: ?[]u8 = null;
    defer if (new_app) |n| gpa.free(n);
    var it = staging.iterate();
    while (try it.next(io)) |entry| {
        // AppleDouble files (`._Name.app`): macOS tar adds them for extended
        // attributes unless COPYFILE_DISABLE=1 is set.
        if (std.mem.startsWith(u8, entry.name, "._")) continue;
        if (entry.kind != .directory or !std.mem.endsWith(u8, entry.name, ".app")) return error.InvalidAppBundle;
        if (new_app != null) return error.InvalidAppBundle;
        new_app = try gpa.dupe(u8, entry.name);
    }
    const new_name = new_app orelse return error.InvalidAppBundle;
    const exe_dir = try std.fs.path.join(gpa, &.{ new_name, "Contents", "MacOS" });
    defer gpa.free(exe_dir);
    staging.access(io, exe_dir, .{}) catch return error.InvalidAppBundle;

    const from = try gpa.dupeZ(u8, new_name);
    defer gpa.free(from);
    const to = try gpa.dupeZ(u8, bundle_name);
    defer gpa.free(to);
    if (renameatx_np(staging.handle, from.ptr, parent.handle, to.ptr, RENAME_SWAP) != 0) {
        return switch (std.posix.errno(-1)) {
            .NOENT => blk: {
                // No bundle there any more: a plain move is enough.
                if (renameatx_np(staging.handle, from.ptr, parent.handle, to.ptr, 0) != 0) break :blk error.RenameFailed;
                break :blk {};
            },
            else => error.RenameFailed,
        };
    }
    try syncDir(parent);
}

/// `open -n <bundle>`: Launch Services starts a new instance of the
/// (replaced) bundle; this process then exits.
fn relaunchBundle(io: std.Io, bundle: []const u8) !noreturn {
    var child = try std.process.spawn(io, .{ .argv = &.{ "/usr/bin/open", "-n", bundle } });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.RelaunchFailed,
        else => return error.RelaunchFailed,
    }
    std.process.exit(0);
}

// <crt_externs.h>: the process's own argc/argv (no /proc on macOS).
extern "c" fn _NSGetArgc() *c_int;
extern "c" fn _NSGetArgv() *[*][*:0]u8;

pub fn restart(io: std.Io, exe_path: []const u8) !noreturn {
    if (enclosingBundle(exe_path)) |bundle| return relaunchBundle(io, bundle);
    const argc: usize = std.math.cast(usize, _NSGetArgc().*) orelse return error.CannotReadCmdline;
    if (argc == 0) return error.CannotReadCmdline;
    if (argc > updater.MAX_ARGV_COUNT) return error.CmdlineTooLarge;
    const raw = _NSGetArgv().*;

    var argv_storage: [updater.MAX_ARGV_COUNT][]const u8 = undefined;
    // argv[0] becomes the new binary's path, like splitCmdline does on Linux.
    argv_storage[0] = exe_path;
    for (1..argc) |i| argv_storage[i] = std.mem.span(raw[i]);
    return std.process.replace(io, .{ .argv = argv_storage[0..argc] });
}

/// Checks the entries of a bundle archive, in order: every symlink target is
/// relative and stays inside the archive tree (resolved from the link's
/// directory), and no entry is written through a symlink (a path below an
/// earlier link). Links such as `Versions/Current -> A` in frameworks pass.
const LinkGuard = struct {
    arena: std.heap.ArenaAllocator,
    links: std.StringHashMapUnmanaged(void) = .empty,

    fn init(gpa: std.mem.Allocator) LinkGuard {
        return .{ .arena = .init(gpa) };
    }

    fn deinit(g: *LinkGuard) void {
        g.arena.deinit();
    }

    /// `name` without empty and "." components, e.g. "./A.app//x/" -> "A.app/x".
    fn normalize(a: std.mem.Allocator, name: []const u8) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var parts = std.mem.tokenizeScalar(u8, name, '/');
        while (parts.next()) |part| {
            if (std.mem.eql(u8, part, ".")) continue;
            if (std.mem.eql(u8, part, "..")) return error.InvalidAppBundle;
            if (out.items.len > 0) try out.append(a, '/');
            try out.appendSlice(a, part);
        }
        return out.items;
    }

    fn entry(g: *LinkGuard, kind: std.tar.FileKind, name: []const u8, link_name: []const u8) !void {
        const a = g.arena.allocator();
        const path = try normalize(a, name);
        // No earlier link may be a directory component of this path.
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, path, i, '/')) |slash| : (i = slash + 1) {
            if (g.links.contains(path[0..slash])) return error.InvalidAppBundle;
        }
        if (kind != .sym_link) return;
        if (link_name.len == 0 or link_name[0] == '/') return error.InvalidAppBundle;
        var depth: usize = std.mem.count(u8, path, "/"); // components of the link's directory
        var parts = std.mem.tokenizeScalar(u8, link_name, '/');
        while (parts.next()) |part| {
            if (std.mem.eql(u8, part, ".")) continue;
            if (std.mem.eql(u8, part, "..")) {
                if (depth == 0) return error.InvalidAppBundle;
                depth -= 1;
            } else depth += 1;
        }
        try g.links.put(a, path, {});
    }
};

test LinkGuard {
    var g: LinkGuard = .init(std.testing.allocator);
    defer g.deinit();
    try g.entry(.directory, "./A.app/", "");
    try g.entry(.directory, "A.app/Contents/Frameworks/F.framework/Versions/A", "");
    try g.entry(.sym_link, "A.app/Contents/Frameworks/F.framework/Versions/Current", "A");
    try g.entry(.sym_link, "A.app/Contents/Frameworks/F.framework/F", "Versions/Current/F");
    try g.entry(.sym_link, "A.app/up", "../A.app/Contents");
    try g.entry(.file, "A.app/Contents/Frameworks/F.framework/Versions/A/F", "");
    // Out of the tree, absolute, or written through a link.
    try std.testing.expectError(error.InvalidAppBundle, g.entry(.sym_link, "A.app/x", "../.."));
    try std.testing.expectError(error.InvalidAppBundle, g.entry(.sym_link, "A.app/x", "/Users"));
    try std.testing.expectError(error.InvalidAppBundle, g.entry(.file, "A.app/up/evil", ""));
    try std.testing.expectError(error.InvalidAppBundle, g.entry(.directory, "A.app/Contents/Frameworks/F.framework/Versions/Current/x", ""));
}

test enclosingBundle {
    try std.testing.expectEqualStrings("/Applications/Notes.app", enclosingBundle("/Applications/Notes.app/Contents/MacOS/notes").?);
    try std.testing.expectEqual(@as(?[]const u8, null), enclosingBundle("/usr/local/bin/oriel"));
}

test "installBundle swaps a bundle for the one in a tar.gz" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // The installed bundle, version 1.
    try tmp.dir.createDirPath(io, "apps/Notes.app/Contents/MacOS");
    try tmp.dir.writeFile(io, .{ .sub_path = "apps/Notes.app/Contents/MacOS/notes", .data = "v1" });
    try tmp.dir.writeFile(io, .{ .sub_path = "apps/Notes.app/Contents/old-only.txt", .data = "x" });

    // The update: Notes.app with version 2, as tar.gz (made with the system tar).
    try tmp.dir.createDirPath(io, "src/Notes.app/Contents/MacOS");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/Notes.app/Contents/MacOS/notes", .data = "v2" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const src = try std.fs.path.join(gpa, &.{ root, "src" });
    defer gpa.free(src);
    const payload_path = try std.fs.path.join(gpa, &.{ root, "update.tar.gz" });
    defer gpa.free(payload_path);
    var tar = try std.process.spawn(io, .{ .argv = &.{ "/usr/bin/tar", "-czf", payload_path, "-C", src, "Notes.app" } });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try tar.wait(io));

    const bundle = try std.fs.path.join(gpa, &.{ root, "apps", "Notes.app" });
    defer gpa.free(bundle);
    try installBundle(io, gpa, tmp.dir, "update.tar.gz", bundle);

    const exe = try tmp.dir.readFileAlloc(io, "apps/Notes.app/Contents/MacOS/notes", gpa, .limited(64));
    defer gpa.free(exe);
    try std.testing.expectEqualStrings("v2", exe);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "apps/Notes.app/Contents/old-only.txt", .{}));
    // Nothing left but the bundle: the staging directory (old bundle) is gone.
    var apps = try tmp.dir.openDir(io, "apps", .{ .iterate = true });
    defer apps.close(io);
    var it = apps.iterate();
    var count: usize = 0;
    while (try it.next(io)) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 1), count);
}

test {
    std.testing.refAllDecls(@This());
}
