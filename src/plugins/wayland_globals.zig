//! Shared helper: connect to the Wayland compositor and list its globals.

const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;

pub const Global = struct {
    name: u32,
    interface: []const u8,
    version: u32,
};

pub const Globals = struct {
    display: *wl.Display,
    registry: *wl.Registry,
    list: std.ArrayList(Global) = .empty,
    gpa: std.mem.Allocator,

    /// Connect and do one roundtrip so every global has been announced.
    pub fn init(self: *Globals, gpa: std.mem.Allocator) !void {
        self.* = .{ .display = try wl.Display.connect(null), .registry = undefined, .gpa = gpa };
        errdefer self.display.disconnect();
        self.registry = try self.display.getRegistry();
        self.registry.setListener(*Globals, listener, self);
        if (self.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
    }

    pub fn deinit(self: *Globals) void {
        for (self.list.items) |g| self.gpa.free(g.interface);
        self.list.deinit(self.gpa);
        self.registry.destroy();
        self.display.disconnect();
    }

    pub fn find(self: *const Globals, interface: []const u8) ?Global {
        for (self.list.items) |g| {
            if (std.mem.eql(u8, g.interface, interface)) return g;
        }
        return null;
    }

    /// Bind the global implementing `T`, if the compositor offers it.
    pub fn bind(self: *const Globals, comptime T: type, version: u32) !?*T {
        const g = self.find(std.mem.span(T.interface.name)) orelse return null;
        return try self.registry.bind(g.name, T, @min(version, g.version));
    }

    fn listener(_: *wl.Registry, event: wl.Registry.Event, self: *Globals) void {
        switch (event) {
            .global => |g| {
                const interface = self.gpa.dupe(u8, std.mem.span(g.interface)) catch return;
                self.list.append(self.gpa, .{ .name = g.name, .interface = interface, .version = g.version }) catch {
                    self.gpa.free(interface);
                };
            },
            .global_remove => {},
        }
    }
};
