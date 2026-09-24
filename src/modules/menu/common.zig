//! Common data models and accelerator parsing for application menu bar.

const std = @import("std");

pub const MenuItem = union(enum) {
    item: struct {
        id: []const u8,
        label: []const u8,
        enabled: bool = true,
        shortcut: ?[]const u8 = null,
    },
    check: struct {
        id: []const u8,
        label: []const u8,
        checked: bool = false,
        enabled: bool = true,
    },
    separator,
    submenu: struct {
        label: []const u8,
        items: []const MenuItem,
        enabled: bool = true,
    },
};

pub const ActionCallback = *const fn (id: []const u8, checked: ?bool) void;

// Win32 accelerator flags
pub const FVIRTKEY: u8 = 0x01;
pub const FNOINVERT: u8 = 0x02;
pub const FSHIFT: u8 = 0x04;
pub const FCONTROL: u8 = 0x08;
pub const FALT: u8 = 0x10;

// Win32 Virtual-Key codes
pub const VK_BACK: u16 = 0x08;
pub const VK_TAB: u16 = 0x09;
pub const VK_RETURN: u16 = 0x0D;
pub const VK_ESCAPE: u16 = 0x1B;
pub const VK_SPACE: u16 = 0x20;
pub const VK_PRIOR: u16 = 0x21; // Page Up
pub const VK_NEXT: u16 = 0x22; // Page Down
pub const VK_END: u16 = 0x23;
pub const VK_HOME: u16 = 0x24;
pub const VK_LEFT: u16 = 0x25;
pub const VK_UP: u16 = 0x26;
pub const VK_RIGHT: u16 = 0x27;
pub const VK_DOWN: u16 = 0x28;
pub const VK_INSERT: u16 = 0x2D;
pub const VK_DELETE: u16 = 0x2E;
pub const VK_F1: u16 = 0x70;
pub const VK_F12: u16 = 0x7B;
pub const VK_F13: u16 = 0x7C;
pub const VK_F24: u16 = 0x87;

pub const ParsedAccelerator = struct {
    flags: u8,
    key: u16,
};

pub const ParseError = error{
    EmptyShortcut,
    InvalidShortcut,
    UnknownModifier,
    UnknownKey,
    NoKey,
};

/// Parses a Linux/GTK shortcut string (e.g. "<Ctrl>N", "<Ctrl><Shift>S", "<Alt>F4", "F5", "<Primary>q")
/// into an accelerator with Win32 flags (FVIRTKEY | FCONTROL/FSHIFT/FALT) and virtual key code.
pub fn parseShortcut(shortcut: []const u8) ParseError!ParsedAccelerator {
    const trimmed = std.mem.trim(u8, shortcut, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyShortcut;

    var flags: u8 = FVIRTKEY;
    var remaining = trimmed;

    // Parse <Modifier> tokens
    while (remaining.len > 0 and remaining[0] == '<') {
        const close_idx = std.mem.indexOfScalar(u8, remaining, '>') orelse return error.InvalidShortcut;
        const mod = remaining[1..close_idx];
        if (std.ascii.eqlIgnoreCase(mod, "ctrl") or std.ascii.eqlIgnoreCase(mod, "control") or std.ascii.eqlIgnoreCase(mod, "primary")) {
            flags |= FCONTROL;
        } else if (std.ascii.eqlIgnoreCase(mod, "shift")) {
            flags |= FSHIFT;
        } else if (std.ascii.eqlIgnoreCase(mod, "alt") or std.ascii.eqlIgnoreCase(mod, "meta")) {
            flags |= FALT;
        } else {
            return error.UnknownModifier;
        }
        remaining = remaining[close_idx + 1 ..];
        while (remaining.len > 0 and (remaining[0] == '+' or remaining[0] == ' ' or remaining[0] == '\t')) {
            remaining = remaining[1..];
        }
    }

    // Also support '+' separated modifiers if no '<' was used (e.g. "Ctrl+Shift+S")
    if (flags == FVIRTKEY and std.mem.indexOfScalar(u8, remaining, '+') != null) {
        var it = std.mem.splitScalar(u8, remaining, '+');
        var key_part: ?[]const u8 = null;
        while (it.next()) |raw_part| {
            const part = std.mem.trim(u8, raw_part, " \t\r\n");
            if (part.len == 0) continue;
            if (std.ascii.eqlIgnoreCase(part, "ctrl") or std.ascii.eqlIgnoreCase(part, "control") or std.ascii.eqlIgnoreCase(part, "primary")) {
                flags |= FCONTROL;
            } else if (std.ascii.eqlIgnoreCase(part, "shift")) {
                flags |= FSHIFT;
            } else if (std.ascii.eqlIgnoreCase(part, "alt") or std.ascii.eqlIgnoreCase(part, "meta")) {
                flags |= FALT;
            } else {
                key_part = part;
            }
        }
        remaining = key_part orelse return error.NoKey;
    }

    const key_str = std.mem.trim(u8, remaining, " \t\r\n");
    if (key_str.len == 0) return error.NoKey;

    const key_code = try parseKeyName(key_str);
    return .{
        .flags = flags,
        .key = key_code,
    };
}

fn parseKeyName(name: []const u8) ParseError!u16 {
    if (name.len == 1) {
        const c = name[0];
        if (c >= 'a' and c <= 'z') {
            return std.ascii.toUpper(c);
        } else if (c >= 'A' and c <= 'Z') {
            return c;
        } else if (c >= '0' and c <= '9') {
            return c;
        } else {
            return error.UnknownKey;
        }
    }

    // Function keys: F1..F24
    if ((name[0] == 'F' or name[0] == 'f') and name.len >= 2 and name.len <= 3) {
        const num = std.fmt.parseInt(u8, name[1..], 10) catch return error.UnknownKey;
        if (num >= 1 and num <= 12) {
            return VK_F1 + (num - 1);
        } else if (num >= 13 and num <= 24) {
            return VK_F13 + (num - 13);
        }
        return error.UnknownKey;
    }

    // Named keys
    const named_keys = [_]struct { []const u8, u16 }{
        .{ "escape", VK_ESCAPE },
        .{ "esc", VK_ESCAPE },
        .{ "tab", VK_TAB },
        .{ "return", VK_RETURN },
        .{ "enter", VK_RETURN },
        .{ "space", VK_SPACE },
        .{ "backspace", VK_BACK },
        .{ "back", VK_BACK },
        .{ "delete", VK_DELETE },
        .{ "del", VK_DELETE },
        .{ "insert", VK_INSERT },
        .{ "ins", VK_INSERT },
        .{ "home", VK_HOME },
        .{ "end", VK_END },
        .{ "pageup", VK_PRIOR },
        .{ "page_up", VK_PRIOR },
        .{ "prior", VK_PRIOR },
        .{ "pagedown", VK_NEXT },
        .{ "page_down", VK_NEXT },
        .{ "next", VK_NEXT },
        .{ "left", VK_LEFT },
        .{ "up", VK_UP },
        .{ "right", VK_RIGHT },
        .{ "down", VK_DOWN },
    };

    for (named_keys) |entry| {
        if (std.ascii.eqlIgnoreCase(name, entry[0])) {
            return entry[1];
        }
    }

    return error.UnknownKey;
}

/// Formats a shortcut key for Windows menu display (e.g. "Ctrl+N", "Ctrl+Shift+S", "Alt+F4").
pub fn formatShortcutDisplay(allocator: std.mem.Allocator, accel: ParsedAccelerator) ![]u8 {
    var buf: [64]u8 = undefined;
    var len: usize = 0;

    if ((accel.flags & FCONTROL) != 0) {
        const s = "Ctrl+";
        @memcpy(buf[len..][0..s.len], s);
        len += s.len;
    }
    if ((accel.flags & FSHIFT) != 0) {
        const s = "Shift+";
        @memcpy(buf[len..][0..s.len], s);
        len += s.len;
    }
    if ((accel.flags & FALT) != 0) {
        const s = "Alt+";
        @memcpy(buf[len..][0..s.len], s);
        len += s.len;
    }

    const key = accel.key;
    if (key >= 'A' and key <= 'Z') {
        buf[len] = @intCast(key);
        len += 1;
    } else if (key >= '0' and key <= '9') {
        buf[len] = @intCast(key);
        len += 1;
    } else if (key >= VK_F1 and key <= VK_F12) {
        const printed = try std.fmt.bufPrint(buf[len..], "F{d}", .{key - VK_F1 + 1});
        len += printed.len;
    } else if (key >= VK_F13 and key <= VK_F24) {
        const printed = try std.fmt.bufPrint(buf[len..], "F{d}", .{key - VK_F13 + 13});
        len += printed.len;
    } else {
        const name: []const u8 = switch (key) {
            VK_ESCAPE => "Esc",
            VK_TAB => "Tab",
            VK_RETURN => "Enter",
            VK_SPACE => "Space",
            VK_BACK => "Backspace",
            VK_DELETE => "Delete",
            VK_INSERT => "Insert",
            VK_HOME => "Home",
            VK_END => "End",
            VK_PRIOR => "Page Up",
            VK_NEXT => "Page Down",
            VK_LEFT => "Left",
            VK_UP => "Up",
            VK_RIGHT => "Right",
            VK_DOWN => "Down",
            else => return error.UnknownKey,
        };
        @memcpy(buf[len..][0..name.len], name);
        len += name.len;
    }

    return allocator.dupe(u8, buf[0..len]);
}

/// Formats a menu item label, appending the shortcut after a TAB character (e.g. "New\tCtrl+N").
/// If no shortcut is specified, returns a duplicate of label.
pub fn formatMenuLabel(allocator: std.mem.Allocator, label: []const u8, shortcut: ?[]const u8) ![]u8 {
    if (shortcut) |sc| {
        if (sc.len > 0) {
            if (parseShortcut(sc)) |accel| {
                const sc_display = try formatShortcutDisplay(allocator, accel);
                defer allocator.free(sc_display);
                return std.fmt.allocPrint(allocator, "{s}\t{s}", .{ label, sc_display });
            } else |_| {}
        }
    }
    return allocator.dupe(u8, label);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseShortcut valid GTK formats" {
    const a1 = try parseShortcut("<Ctrl>N");
    try std.testing.expectEqual(FVIRTKEY | FCONTROL, a1.flags);
    try std.testing.expectEqual(@as(u16, 'N'), a1.key);

    const a2 = try parseShortcut("<Ctrl><Shift>S");
    try std.testing.expectEqual(FVIRTKEY | FCONTROL | FSHIFT, a2.flags);
    try std.testing.expectEqual(@as(u16, 'S'), a2.key);

    const a3 = try parseShortcut("<Alt>F4");
    try std.testing.expectEqual(FVIRTKEY | FALT, a3.flags);
    try std.testing.expectEqual(VK_F1 + 3, a3.key);

    const a4 = try parseShortcut("F5");
    try std.testing.expectEqual(FVIRTKEY, a4.flags);
    try std.testing.expectEqual(VK_F1 + 4, a4.key);

    const a5 = try parseShortcut("<Primary>q");
    try std.testing.expectEqual(FVIRTKEY | FCONTROL, a5.flags);
    try std.testing.expectEqual(@as(u16, 'Q'), a5.key);

    const a6 = try parseShortcut("<Control>a");
    try std.testing.expectEqual(FVIRTKEY | FCONTROL, a6.flags);
    try std.testing.expectEqual(@as(u16, 'A'), a6.key);

    const a7 = try parseShortcut("<Ctrl>0");
    try std.testing.expectEqual(FVIRTKEY | FCONTROL, a7.flags);
    try std.testing.expectEqual(@as(u16, '0'), a7.key);

    const a8 = try parseShortcut("<Shift>Delete");
    try std.testing.expectEqual(FVIRTKEY | FSHIFT, a8.flags);
    try std.testing.expectEqual(VK_DELETE, a8.key);
}

test "parseShortcut case insensitivity" {
    const a1 = try parseShortcut("<ctrl>n");
    try std.testing.expectEqual(FVIRTKEY | FCONTROL, a1.flags);
    try std.testing.expectEqual(@as(u16, 'N'), a1.key);

    const a2 = try parseShortcut("<CTRL>N");
    try std.testing.expectEqual(FVIRTKEY | FCONTROL, a2.flags);
    try std.testing.expectEqual(@as(u16, 'N'), a2.key);

    const a3 = try parseShortcut("f5");
    try std.testing.expectEqual(FVIRTKEY, a3.flags);
    try std.testing.expectEqual(VK_F1 + 4, a3.key);

    const a4 = try parseShortcut("<alt><shift>f12");
    try std.testing.expectEqual(FVIRTKEY | FALT | FSHIFT, a4.flags);
    try std.testing.expectEqual(VK_F12, a4.key);
}

test "parseShortcut function keys F1 to F24" {
    const f1 = try parseShortcut("F1");
    try std.testing.expectEqual(VK_F1, f1.key);

    const f12 = try parseShortcut("F12");
    try std.testing.expectEqual(VK_F12, f12.key);

    const f13 = try parseShortcut("F13");
    try std.testing.expectEqual(VK_F13, f13.key);

    const f24 = try parseShortcut("F24");
    try std.testing.expectEqual(VK_F24, f24.key);
}

test "parseShortcut letters and digits" {
    var c: u8 = 'a';
    while (c <= 'z') : (c += 1) {
        var buf = [_]u8{ '<', 'C', 't', 'r', 'l', '>', c };
        const res = try parseShortcut(&buf);
        try std.testing.expectEqual(std.ascii.toUpper(c), res.key);
    }

    var d: u8 = '0';
    while (d <= '9') : (d += 1) {
        var buf = [_]u8{ '<', 'A', 'l', 't', '>', d };
        const res = try parseShortcut(&buf);
        try std.testing.expectEqual(d, res.key);
    }
}

test "parseShortcut invalid shortcuts" {
    try std.testing.expectError(error.EmptyShortcut, parseShortcut(""));
    try std.testing.expectError(error.EmptyShortcut, parseShortcut("   "));
    try std.testing.expectError(error.NoKey, parseShortcut("<Ctrl>"));
    try std.testing.expectError(error.UnknownModifier, parseShortcut("<Unknown>A"));
    try std.testing.expectError(error.InvalidShortcut, parseShortcut("<Ctrl"));
    try std.testing.expectError(error.UnknownKey, parseShortcut("<Ctrl>FooBar"));
}

test "formatMenuLabel with and without shortcut" {
    const alloc = std.testing.allocator;

    const l1 = try formatMenuLabel(alloc, "New", "<Ctrl>N");
    defer alloc.free(l1);
    try std.testing.expectEqualStrings("New\tCtrl+N", l1);

    const l2 = try formatMenuLabel(alloc, "Save As...", "<Ctrl><Shift>S");
    defer alloc.free(l2);
    try std.testing.expectEqualStrings("Save As...\tCtrl+Shift+S", l2);

    const l3 = try formatMenuLabel(alloc, "Quit", "<Primary>q");
    defer alloc.free(l3);
    try std.testing.expectEqualStrings("Quit\tCtrl+Q", l3);

    const l4 = try formatMenuLabel(alloc, "Reload", "F5");
    defer alloc.free(l4);
    try std.testing.expectEqualStrings("Reload\tF5", l4);

    const l5 = try formatMenuLabel(alloc, "About", null);
    defer alloc.free(l5);
    try std.testing.expectEqualStrings("About", l5);
}
