//! Desktop notifications.
//!
//! Linux backend: GIO GNotification.
//! Windows backend: Win32 Shell_NotifyIconW balloon.

const builtin = @import("builtin");
pub const common = @import("notification/common.zig");

pub const NotificationOptions = common.NotificationOptions;
pub const notify = impl.notify;
pub const check = impl.check;

pub const impl = switch (builtin.os.tag) {
    .linux => @import("notification/linux.zig"),
    .windows => @import("notification/windows.zig"),
    else => @compileError("notification is not supported on " ++ @tagName(builtin.os.tag)),
};

test {
    const std = @import("std");
    std.testing.refAllDecls(common);
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(impl);
}
