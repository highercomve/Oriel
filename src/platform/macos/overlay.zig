//! Overlay-window operations (Milestone 10). Not implemented on this
//! platform yet: the calls are accepted and ignored.

const std = @import("std");
const App = @import("../../core/App.zig");
const WindowHandle = @import("window.zig").WindowHandle;

const log = std.log.scoped(.oriel);

pub fn setWindowPlacement(_: WindowHandle, _: App.Placement) void {
    log.debug("window placement is not implemented on this platform yet", .{});
}

pub fn setWindowClickThrough(_: WindowHandle, _: bool) void {
    log.debug("click-through is not implemented on this platform yet", .{});
}

pub fn setWindowAlwaysOnTop(_: WindowHandle, _: bool) void {
    log.debug("always-on-top is not implemented on this platform yet", .{});
}

pub fn getWindowWorkArea(_: WindowHandle) ?App.Rect {
    return null;
}
