//! Platform-neutral data models for system tray menus and icons.

const std = @import("std");

pub const MenuItem = union(enum) {
    item: struct { id: []const u8, label: []const u8, enabled: bool = true },
    check: struct { id: []const u8, label: []const u8, checked: bool = false, enabled: bool = true },
    separator,
    submenu: struct { label: []const u8, items: []const MenuItem, enabled: bool = true },
};

pub const Icon = union(enum) {
    /// PNG (or any format zigimg reads), sent as pixels. Works everywhere.
    png: []const u8,
    /// Icon theme name, e.g. "mail-unread".
    name: []const u8,
};

pub const Options = struct {
    /// Stable identifier, usually the app ID.
    id: []const u8,
    title: []const u8,
    tooltip: []const u8 = "",
    icon: Icon,
    menu: []const MenuItem = &.{},
    /// Menu item clicked; `checked` is the new state for check items.
    on_menu: ?*const fn (id: []const u8, checked: ?bool) void = null,
    /// Icon left-clicked. Null toggles the main window.
    on_activate: ?*const fn () void = null,
};

// ---------------------------------------------------------------------------
// Menu model (independent of platform, unit-tested)
// ---------------------------------------------------------------------------

pub const Menu = struct {
    arena: std.heap.ArenaAllocator,
    /// Index = item ID; 0 is the root.
    nodes: std.ArrayList(Node) = .empty,
    revision: u32 = 1,

    pub const Node = struct {
        kind: enum { root, item, check, separator, submenu },
        key: [:0]const u8 = "",
        label: [:0]const u8 = "",
        enabled: bool = true,
        checked: bool = false,
        children: []const i32 = &.{},
    };

    pub fn init(gpa: std.mem.Allocator) Menu {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *Menu) void {
        self.arena.deinit();
    }

    pub fn set(self: *Menu, items: []const MenuItem) !void {
        _ = self.arena.reset(.retain_capacity);
        self.nodes = .empty;
        const a = self.arena.allocator();
        try self.nodes.append(a, .{ .kind = .root });
        const children = try self.add(a, items);
        self.nodes.items[0].children = children;
        self.revision +%= 1;
    }

    fn add(self: *Menu, a: std.mem.Allocator, items: []const MenuItem) ![]const i32 {
        const ids = try a.alloc(i32, items.len);
        for (items, ids) |item, *id| {
            id.* = @intCast(self.nodes.items.len);
            try self.nodes.append(a, switch (item) {
                .item => |it| .{ .kind = .item, .key = try a.dupeZ(u8, it.id), .label = try a.dupeZ(u8, it.label), .enabled = it.enabled },
                .check => |it| .{ .kind = .check, .key = try a.dupeZ(u8, it.id), .label = try a.dupeZ(u8, it.label), .enabled = it.enabled, .checked = it.checked },
                .separator => .{ .kind = .separator },
                .submenu => |it| .{ .kind = .submenu, .label = try a.dupeZ(u8, it.label), .enabled = it.enabled },
            });
            if (item == .submenu) {
                const children = try self.add(a, item.submenu.items);
                self.nodes.items[@intCast(id.*)].children = children;
            }
        }
        return ids;
    }

    pub fn node(self: *Menu, id: i32) ?*Node {
        if (id < 0 or id >= self.nodes.items.len) return null;
        return &self.nodes.items[@intCast(id)];
    }

    pub fn find(self: *Menu, key: []const u8) ?*Node {
        for (self.nodes.items) |*n| {
            if (n.key.len > 0 and std.mem.eql(u8, n.key, key)) return n;
        }
        return null;
    }
};

pub const DecodedTrayLParam = struct {
    event: u16,
    icon_id: u16,
};

pub const DecodedTrayWParam = struct {
    x: i16,
    y: i16,
};

/// Decodes the LPARAM from a NOTIFYICON_VERSION_4 callback:
/// LOWORD is the event (e.g. WM_LBUTTONUP, WM_CONTEXTMENU, NIN_SELECT).
/// HIWORD is the icon ID.
pub fn decodeTrayLParam(lParam: isize) DecodedTrayLParam {
    const raw: usize = @bitCast(lParam);
    return .{
        .event = @truncate(raw),
        .icon_id = @truncate(raw >> 16),
    };
}

/// Decodes the WPARAM from a NOTIFYICON_VERSION_4 callback:
/// LOWORD is the anchor X coordinate (in screen coords, signed).
/// HIWORD is the anchor Y coordinate (in screen coords, signed).
pub fn decodeTrayWParam(wParam: usize) DecodedTrayWParam {
    return .{
        .x = @bitCast(@as(u16, @truncate(wParam))),
        .y = @bitCast(@as(u16, @truncate(wParam >> 16))),
    };
}

test "decodeTrayLParam" {
    // Normal event and icon_id
    // event = 0x0202 (WM_LBUTTONUP), icon_id = 1001 (0x03E9)
    // combined 32-bit = 0x03E90202
    const lp1: isize = 0x03E90202;
    const d1 = decodeTrayLParam(lp1);
    try std.testing.expectEqual(@as(u16, 0x0202), d1.event);
    try std.testing.expectEqual(@as(u16, 1001), d1.icon_id);

    // Negative isize (e.g. sign extended high bit in 32-bit value)
    const lp2: isize = @bitCast(@as(usize, 0xFFFF_FFFF_8001_0400));
    const d2 = decodeTrayLParam(lp2);
    try std.testing.expectEqual(@as(u16, 0x0400), d2.event);
    try std.testing.expectEqual(@as(u16, 0x8001), d2.icon_id);
}

test "decodeTrayWParam" {
    // Positive coordinates: x = 150, y = 300
    // (300 << 16) | 150 = 0x012C0096
    const wp1: usize = (300 << 16) | 150;
    const d1 = decodeTrayWParam(wp1);
    try std.testing.expectEqual(@as(i16, 150), d1.x);
    try std.testing.expectEqual(@as(i16, 300), d1.y);

    // Negative coordinates (multi-monitor): x = -20, y = -10
    const raw_x = @as(u16, @bitCast(@as(i16, -20)));
    const raw_y = @as(u16, @bitCast(@as(i16, -10)));
    const wp2: usize = (@as(usize, raw_y) << 16) | @as(usize, raw_x);
    const d2 = decodeTrayWParam(wp2);
    try std.testing.expectEqual(@as(i16, -20), d2.x);
    try std.testing.expectEqual(@as(i16, -10), d2.y);
}

test {
    std.testing.refAllDecls(@This());
}
