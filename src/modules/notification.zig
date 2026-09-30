//! Desktop notifications.
//!
//! Linux backend: GIO GNotification.
//! Windows backend: Win32 Shell_NotifyIconW balloon.
//! macOS backend: UNUserNotificationCenter (bundled apps) or osascript.

const builtin = @import("builtin");
const target = @import("../core/target.zig");
pub const common = @import("notification/common.zig");

pub const NotificationOptions = common.NotificationOptions;
pub const notify = impl.notify;
pub const check = impl.check;

pub const impl = switch (target.os) {
    .linux => @import("notification/linux.zig"),
    .windows => @import("notification/windows.zig"),
    .macos => @import("notification/macos.zig"),
    .android => @import("notification/android.zig"),
    .ios => @import("notification/ios.zig"),
    .other => @compileError("notification is not supported on " ++ target.name),
};

test {
    const std = @import("std");
    std.testing.refAllDecls(common);
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(impl);
}
