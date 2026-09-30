//! Native file dialogs.
//!
//! Linux backend: GTK4 GtkFileDialog.
//! Windows backend: Win32 COM IFileOpenDialog / IFileSaveDialog.
//! macOS backend: NSOpenPanel / NSSavePanel.

const std = @import("std");
const builtin = @import("builtin");
const target = @import("../core/target.zig");
pub const common = @import("dialog/common.zig");

pub const OpenOptions = common.OpenOptions;
pub const SaveOptions = common.SaveOptions;
pub const openFile = impl.openFile;
pub const saveFile = impl.saveFile;
pub const check = impl.check;

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
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(impl);
}
