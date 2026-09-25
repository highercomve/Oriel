//! Native file dialogs.
//!
//! Linux backend: GTK4 GtkFileDialog.
//! Windows backend: Win32 COM IFileOpenDialog / IFileSaveDialog.
//! macOS backend: NSOpenPanel / NSSavePanel.

const builtin = @import("builtin");
pub const common = @import("dialog/common.zig");

pub const OpenOptions = common.OpenOptions;
pub const SaveOptions = common.SaveOptions;
pub const openFile = impl.openFile;
pub const saveFile = impl.saveFile;
pub const check = impl.check;

pub const impl = switch (builtin.os.tag) {
    .linux => @import("dialog/linux.zig"),
    .windows => @import("dialog/windows.zig"),
    .macos => @import("dialog/macos.zig"),
    else => @compileError("dialog is not supported on " ++ @tagName(builtin.os.tag)),
};

test {
    const std = @import("std");
    std.testing.refAllDecls(common);
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(impl);
}
