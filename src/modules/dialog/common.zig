//! Common types and options for file dialogs.

pub const OpenOptions = struct {
    title: []const u8 = "Open File",
    modal: bool = true,
};

pub const SaveOptions = struct {
    title: []const u8 = "Save File",
    modal: bool = true,
};

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
