//! Native file dialogs.
//!
//! Linux backend: GTK4 GtkFileDialog.
//! Windows backend: Win32 COM IFileOpenDialog / IFileSaveDialog.
//! macOS backend: NSOpenPanel / NSSavePanel.
//! Android: the Storage Access Framework. iOS: UIDocumentPickerViewController.
//!
//! Folders with lasting write access (an app that saves received files where
//! the user chose):
//!
//!     const folder = try oriel.dialog.openFolder(gpa, .{}) orelse return; // cancelled
//!     defer folder.deinit(gpa);
//!     try settings.put("save_dir", folder.id); // opaque; keeps working after restarts
//!     const saved_as = try oriel.dialog.saveToFolder(gpa, io, folder.id, tmp_path, "photo.jpg", null);
//!
//! The id is the folder's path on desktops, the SAF tree URI (with a
//! persisted grant) on Android, and will be a security-scoped bookmark on
//! iOS (not written yet: error.Unsupported).

const std = @import("std");
const builtin = @import("builtin");
const target = @import("../core/target.zig");
pub const common = @import("dialog/common.zig");

pub const OpenOptions = common.OpenOptions;
pub const SaveOptions = common.SaveOptions;
pub const FolderOptions = common.FolderOptions;
pub const Folder = common.Folder;
pub const FolderError = common.FolderError;
pub const openFile = impl.openFile;
pub const saveFile = impl.saveFile;
pub const check = impl.check;

/// Ask the user for a folder the app may write to, across restarts. Null
/// if cancelled. Free the result with `Folder.deinit`. Blocks until the
/// user answers: call it from an async command (on Android and iOS it
/// returns error.MainThread on the UI thread).
pub fn openFolder(gpa: std.mem.Allocator, options: FolderOptions) !?Folder {
    return impl.openFolder(gpa, options);
}

/// The display name of folder `id` (caller frees). error.FolderUnavailable
/// when access was revoked or the folder is gone: ask again with
/// `openFolder`.
pub fn folderName(gpa: std.mem.Allocator, io: std.Io, id: []const u8) ![]u8 {
    return impl.folderName(gpa, io, id);
}

/// Copy the file at `src_path` into folder `id` as `name`, never replacing
/// a file: a taken name becomes "name (1).ext", "name (2).ext"... Returns
/// the name the file got (caller frees). `mime`: the type to create it with
/// on Android (null: from the extension); ignored elsewhere. Errors:
/// error.InvalidName (a separator, "." or ".."), error.FolderUnavailable,
/// error.FileNotFound (the source), or an I/O error.
pub fn saveToFolder(gpa: std.mem.Allocator, io: std.Io, id: []const u8, src_path: []const u8, name: []const u8, mime: ?[]const u8) ![]u8 {
    return impl.saveToFolder(gpa, io, id, src_path, name, mime);
}

/// Give up the lasting access to folder `id` (Android releases the
/// persisted grant, which counts against a per-app limit; elsewhere
/// nothing to do). The id stops working.
pub fn forgetFolder(id: []const u8) void {
    impl.forgetFolder(id);
}

/// Write `data` to a path `saveFile` returned, replacing what was there.
/// Use it instead of creating the file yourself: on Android the path is
/// `/proc/self/fd/<n>`, the picked document's open descriptor, which can't
/// be reopened (the document's storage isn't the app's), so this writes
/// through the descriptor; elsewhere it creates the file.
pub fn writeFile(io: std.Io, path: []const u8, data: []const u8) !void {
    const fd_prefix = "/proc/self/fd/";
    if (target.is_android and std.mem.startsWith(u8, path, fd_prefix)) {
        const fd = try std.fmt.parseInt(std.posix.fd_t, path[fd_prefix.len..], 10);
        const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
        // Opened "rwt" (truncated) by the picker; also truncate for a second write.
        if (std.c.ftruncate(fd, 0) != 0) return error.AccessDenied;
        return file.writePositionalAll(io, data, 0);
    }
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, data);
}

pub const impl = switch (target.os) {
    .linux => @import("dialog/linux.zig"),
    .windows => @import("dialog/windows.zig"),
    .macos => @import("dialog/macos.zig"),
    .android => @import("dialog/android.zig"),
    .ios => @import("dialog/ios.zig"),
    .other => @compileError("dialog is not supported on " ++ target.name),
};

test {
    std.testing.refAllDecls(common);
    if (target.os == .linux or target.os == .windows or target.os == .macos)
        _ = @import("dialog/path_folder.zig");
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(impl);
}
