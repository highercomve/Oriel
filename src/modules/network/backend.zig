//! This OS's network backend (internal: oriel.network and network/mdns.zig
//! reach it here, apps don't).

const target = @import("../../core/target.zig");
const mdns = @import("mdns.zig");
const Service = mdns.Service;
const Registration = mdns.Registration;
const Browser = mdns.Browser;
const Handler = mdns.Handler;
const Error = mdns.Error;

pub const os = switch (target.os) {
    .linux => @import("linux.zig"),
    .windows => @import("windows.zig"),
    .macos, .ios => @import("apple.zig"),
    .android => @import("android.zig"),
    .other => @compileError("network is not supported on " ++ target.name),
};

/// The backend for platforms without one yet.
pub const MdnsUnsupported = struct {
    pub const supported = false;
    pub fn register(_: Service) Error!Registration {
        return error.Unsupported;
    }
    pub fn unregister(_: u32) void {}
    pub fn browse(_: []const u8, _: Handler, _: ?*anyopaque) Error!Browser {
        return error.Unsupported;
    }
    pub fn stopBrowse(_: u32) void {}
};
