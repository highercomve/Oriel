//! Folder access on desktops (Linux, Windows, macOS): the id is the
//! folder's absolute path, and access is the user's own (Oriel doesn't
//! sandbox desktop apps, so nothing needs persisting or releasing).

const std = @import("std");
const builtin = @import("builtin");
const common = @import("common.zig");

/// Whether Windows programs can use a file called `name`. Zig creates
/// files through the NT API, which takes names Win32 (Explorer, most apps)
/// can then neither open nor delete: device names (CON, NUL, COM1, LPT9,
/// CONIN$..., also with an extension: "con.txt"), a trailing dot or space
/// ("x." would be another file than "x" for them), and `<>:"|?*` or control
/// characters (`:` names an NTFS alternate stream). Checked on Windows only:
/// these are ordinary names elsewhere.
pub fn windowsValidName(name: []const u8) bool {
    if (name.len == 0) return false;
    const last = name[name.len - 1];
    if (last == '.' or last == ' ') return false;
    for (name) |c| {
        if (c < 0x20 or std.mem.indexOfScalar(u8, "<>:\"|?*", c) != null) return false;
    }
    // The part before the first dot, without trailing spaces ("CON .txt").
    const stem = std.mem.trimEnd(u8, name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len], " ");
    for ([_][]const u8{ "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$" }) |d| {
        if (std.ascii.eqlIgnoreCase(stem, d)) return false;
    }
    if (stem.len >= 4 and (std.ascii.startsWithIgnoreCase(stem, "COM") or std.ascii.startsWithIgnoreCase(stem, "LPT"))) {
        const n = stem[3..];
        // A digit, or superscript 1-3 (U+00B9, U+00B2, U+00B3), which Windows reserves too.
        if (n.len == 1 and std.ascii.isDigit(n[0])) return false;
        if (n.len == 2 and n[0] == 0xC2 and (n[1] == 0xB9 or n[1] == 0xB2 or n[1] == 0xB3)) return false;
    }
    return true;
}

/// The most " (n)" names tried before giving up.
const max_numbered = 9999;

fn openFolderDir(io: std.Io, id: []const u8) !std.Io.Dir {
    if (id.len == 0 or !std.fs.path.isAbsolute(id)) return error.FolderUnavailable;
    return std.Io.Dir.openDirAbsolute(io, id, .{}) catch error.FolderUnavailable;
}

/// The folder's last path component (caller frees); error.FolderUnavailable
/// when it is gone or not a folder.
pub fn folderName(gpa: std.mem.Allocator, io: std.Io, id: []const u8) ![]u8 {
    const dir = try openFolderDir(io, id);
    dir.close(io);
    return gpa.dupe(u8, common.pathName(id));
}

/// Copy `src_path` into folder `id` as `name`, or "name (1)", "name (2)"...
/// when taken (never replacing a file). Returns the name used (caller
/// frees). A failed copy leaves nothing behind.
pub fn saveToFolder(gpa: std.mem.Allocator, io: std.Io, id: []const u8, src_path: []const u8, name: []const u8) ![]u8 {
    if (!common.validName(name)) return error.InvalidName;
    if (builtin.os.tag == .windows and !windowsValidName(name)) return error.InvalidName;
    const dir = try openFolderDir(io, id);
    defer dir.close(io);

    const src = try std.Io.Dir.cwd().openFile(io, src_path, .{});
    defer src.close(io);

    var buf: [std.Io.Dir.max_name_bytes + 16]u8 = undefined;
    var n: u32 = 0;
    const final, const dest = while (n <= max_numbered) : (n += 1) {
        const candidate = if (n == 0) name else try common.numberedName(&buf, name, n);
        const file = dir.createFile(io, candidate, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        break .{ candidate, file };
    } else return error.PathAlreadyExists;

    copy(io, src, dest) catch |err| {
        dest.close(io);
        dir.deleteFile(io, final) catch {};
        return err;
    };
    dest.close(io);
    return gpa.dupe(u8, final);
}

fn copy(io: std.Io, src: std.Io.File, dest: std.Io.File) !void {
    var reader: std.Io.File.Reader = .init(src, io, &.{});
    var buffer: [64 * 1024]u8 = undefined;
    var writer = dest.writer(io, &buffer);
    _ = writer.interface.sendFileAll(&reader, .unlimited) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.WriteFailed => return writer.err.?,
    };
    try writer.interface.flush();
}

test "saveToFolder numbers clashes and folderName" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "in");
    try tmp.dir.createDirPath(io, "Received");
    try tmp.dir.writeFile(io, .{ .sub_path = "in/photo.jpg", .data = "jpeg bytes" });
    const src = try tmp.dir.realPathFileAlloc(io, "in/photo.jpg", gpa);
    defer gpa.free(src);
    const folder = try tmp.dir.realPathFileAlloc(io, "Received", gpa);
    defer gpa.free(folder);

    const name = try folderName(gpa, io, folder);
    defer gpa.free(name);
    try std.testing.expectEqualStrings("Received", name);

    const first = try saveToFolder(gpa, io, folder, src, "photo.jpg");
    defer gpa.free(first);
    const second = try saveToFolder(gpa, io, folder, src, "photo.jpg");
    defer gpa.free(second);
    const third = try saveToFolder(gpa, io, folder, src, "photo.jpg");
    defer gpa.free(third);
    try std.testing.expectEqualStrings("photo.jpg", first);
    try std.testing.expectEqualStrings("photo (1).jpg", second);
    try std.testing.expectEqualStrings("photo (2).jpg", third);

    var out: [32]u8 = undefined;
    const data = try tmp.dir.readFile(io, "Received/photo (2).jpg", &out);
    try std.testing.expectEqualStrings("jpeg bytes", data);

    try std.testing.expectError(error.InvalidName, saveToFolder(gpa, io, folder, src, "../x"));
    try std.testing.expectError(error.FolderUnavailable, saveToFolder(gpa, io, "relative/dir", src, "x"));
    const gone = try std.fs.path.join(gpa, &.{ folder, "missing" });
    defer gpa.free(gone);
    try std.testing.expectError(error.FolderUnavailable, folderName(gpa, io, gone));
    try std.testing.expectError(error.FileNotFound, saveToFolder(gpa, io, folder, gone, "x"));

    if (builtin.os.tag == .windows) {
        // Names Win32 couldn't open afterwards: refused, nothing created.
        for ([_][]const u8{ "CON", "nul.txt", "x.", "x ", "a:b", "q?.txt" }) |bad| {
            try std.testing.expectError(error.InvalidName, saveToFolder(gpa, io, folder, src, bad));
        }
        // Case-insensitive names: "PHOTO.JPG" is taken by "photo.jpg".
        const upper = try saveToFolder(gpa, io, folder, src, "PHOTO.JPG");
        defer gpa.free(upper);
        try std.testing.expectEqualStrings("PHOTO (3).JPG", upper);
    }
}

test "windowsValidName" {
    for ([_][]const u8{ "photo.jpg", "con-notes.txt", "COM10", "LPT", "console.log", "a b.txt", ".bashrc", "x.y.z", "\xc3\xa9t\xc3\xa9.txt" }) |ok| {
        if (!windowsValidName(ok)) {
            std.debug.print("rejected: {s}\n", .{ok});
            return error.TestUnexpectedResult;
        }
    }
    for ([_][]const u8{ "CON", "con", "Con.txt", "CON .txt", "PRN", "aux.tar.gz", "NUL", "COM1", "com9.log", "LPT0", "COM\xc2\xb9", "CONIN$", "conout$.x", "x.", "x ", "x..", "a:b", "a<b", "a>b", "a\"b", "a|b", "a?b", "a*b", "tab\tname", "" }) |bad| {
        if (windowsValidName(bad)) {
            std.debug.print("accepted: {s}\n", .{bad});
            return error.TestUnexpectedResult;
        }
    }
}

test "saveToFolder into a folder deeper than MAX_PATH" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(gpa);
    for (0..10) |i| {
        if (i > 0) try path.append(gpa, '/');
        try path.appendSlice(gpa, "a-rather-long-folder-name-for-the-test");
    }
    try tmp.dir.createDirPath(io, path.items);
    try tmp.dir.writeFile(io, .{ .sub_path = "src.txt", .data = "deep" });
    const src = try tmp.dir.realPathFileAlloc(io, "src.txt", gpa);
    defer gpa.free(src);
    const folder = try tmp.dir.realPathFileAlloc(io, path.items, gpa);
    defer gpa.free(folder);
    try std.testing.expect(folder.len > 260);

    const saved = try saveToFolder(gpa, io, folder, src, "deep.txt");
    defer gpa.free(saved);
    try std.testing.expectEqualStrings("deep.txt", saved);
    const name = try folderName(gpa, io, folder);
    defer gpa.free(name);
    try std.testing.expectEqualStrings("a-rather-long-folder-name-for-the-test", name);
}
