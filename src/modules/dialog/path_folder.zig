//! Folder access on desktops (Linux, Windows, macOS): the id is the
//! folder's absolute path, and access is the user's own (Oriel doesn't
//! sandbox desktop apps, so nothing needs persisting or releasing).

const std = @import("std");
const common = @import("common.zig");

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
}
