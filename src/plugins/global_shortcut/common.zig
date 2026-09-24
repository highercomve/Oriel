//! Platform-neutral data models and parsers for global shortcuts.

const std = @import("std");
const win32 = @import("../../platform/windows/win32.zig");

pub const Modifiers = struct {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    super: bool = false,
};

pub const Shortcut = struct {
    id: []const u8,
    description: []const u8 = "",
    trigger: []const u8,
};

pub const ParsedTrigger = struct {
    modifiers: Modifiers,
    key: []const u8,
};

pub const Callback = *const fn (id: []const u8) void;

/// Parse an accelerator trigger string like "CTRL+ALT+G" or "super+shift+Space".
pub fn parseTrigger(trigger_str: []const u8) !ParsedTrigger {
    var it = std.mem.splitScalar(u8, trigger_str, '+');
    var mods = Modifiers{};
    var key: ?[]const u8 = null;

    while (it.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \t\r\n");
        if (part.len == 0) continue;

        if (std.ascii.eqlIgnoreCase(part, "ctrl") or std.ascii.eqlIgnoreCase(part, "control")) {
            mods.ctrl = true;
        } else if (std.ascii.eqlIgnoreCase(part, "alt")) {
            mods.alt = true;
        } else if (std.ascii.eqlIgnoreCase(part, "shift")) {
            mods.shift = true;
        } else if (std.ascii.eqlIgnoreCase(part, "super") or std.ascii.eqlIgnoreCase(part, "meta") or std.ascii.eqlIgnoreCase(part, "win") or std.ascii.eqlIgnoreCase(part, "cmd")) {
            mods.super = true;
        } else {
            if (key != null) return error.MultipleKeysInTrigger;
            key = part;
        }
    }

    const final_key = key orelse return error.NoKeyInTrigger;
    return .{
        .modifiers = mods,
        .key = final_key,
    };
}

/// Pure mapping from a key name to a Win32 Virtual Key code.
/// Supports letters ('A'..'Z'), digits ('0'..'9'), F1-F24, navigation,
/// edit, control keys, and common punctuation.
pub fn vkFor(name: []const u8) ?u16 {
    if (name.len == 0) return null;

    // Single character: letter or digit
    if (name.len == 1) {
        const c = name[0];
        if (c >= 'a' and c <= 'z') return std.ascii.toUpper(c);
        if (c >= 'A' and c <= 'Z') return c;
        if (c >= '0' and c <= '9') return c;

        // Single-character punctuation
        switch (c) {
            ' ' => return @intCast(win32.VK_SPACE),
            '-' => return @intCast(win32.VK_OEM_MINUS),
            '=', '+' => return @intCast(win32.VK_OEM_PLUS),
            ',' => return @intCast(win32.VK_OEM_COMMA),
            '.' => return @intCast(win32.VK_OEM_PERIOD),
            '/' => return @intCast(win32.VK_OEM_2),
            ';' => return @intCast(win32.VK_OEM_1),
            '\'' => return @intCast(win32.VK_OEM_7),
            '[' => return @intCast(win32.VK_OEM_4),
            ']' => return @intCast(win32.VK_OEM_6),
            '\\' => return @intCast(win32.VK_OEM_5),
            '`', '~' => return @intCast(win32.VK_OEM_3),
            else => return null,
        }
    }

    // Function keys: F1 to F24
    if ((name[0] == 'F' or name[0] == 'f') and name.len >= 2 and name.len <= 3) {
        const f_num = std.fmt.parseInt(u8, name[1..], 10) catch 0;
        if (f_num >= 1 and f_num <= 24) {
            return @intCast(win32.VK_F1 + (f_num - 1));
        }
    }

    // Named keys
    if (std.ascii.eqlIgnoreCase(name, "space")) return @intCast(win32.VK_SPACE);
    if (std.ascii.eqlIgnoreCase(name, "enter") or std.ascii.eqlIgnoreCase(name, "return")) return @intCast(win32.VK_RETURN);
    if (std.ascii.eqlIgnoreCase(name, "tab")) return @intCast(win32.VK_TAB);
    if (std.ascii.eqlIgnoreCase(name, "escape") or std.ascii.eqlIgnoreCase(name, "esc")) return @intCast(win32.VK_ESCAPE);
    if (std.ascii.eqlIgnoreCase(name, "backspace")) return @intCast(win32.VK_BACK);

    // Navigation / Arrows
    if (std.ascii.eqlIgnoreCase(name, "up")) return @intCast(win32.VK_UP);
    if (std.ascii.eqlIgnoreCase(name, "down")) return @intCast(win32.VK_DOWN);
    if (std.ascii.eqlIgnoreCase(name, "left")) return @intCast(win32.VK_LEFT);
    if (std.ascii.eqlIgnoreCase(name, "right")) return @intCast(win32.VK_RIGHT);

    // Edit keys
    if (std.ascii.eqlIgnoreCase(name, "home")) return @intCast(win32.VK_HOME);
    if (std.ascii.eqlIgnoreCase(name, "end")) return @intCast(win32.VK_END);
    if (std.ascii.eqlIgnoreCase(name, "pageup") or std.ascii.eqlIgnoreCase(name, "prior")) return @intCast(win32.VK_PRIOR);
    if (std.ascii.eqlIgnoreCase(name, "pagedown") or std.ascii.eqlIgnoreCase(name, "next")) return @intCast(win32.VK_NEXT);
    if (std.ascii.eqlIgnoreCase(name, "insert") or std.ascii.eqlIgnoreCase(name, "ins")) return @intCast(win32.VK_INSERT);
    if (std.ascii.eqlIgnoreCase(name, "delete") or std.ascii.eqlIgnoreCase(name, "del")) return @intCast(win32.VK_DELETE);

    // Named punctuation
    if (std.ascii.eqlIgnoreCase(name, "minus")) return @intCast(win32.VK_OEM_MINUS);
    if (std.ascii.eqlIgnoreCase(name, "plus") or std.ascii.eqlIgnoreCase(name, "equal") or std.ascii.eqlIgnoreCase(name, "equals")) return @intCast(win32.VK_OEM_PLUS);
    if (std.ascii.eqlIgnoreCase(name, "comma")) return @intCast(win32.VK_OEM_COMMA);
    if (std.ascii.eqlIgnoreCase(name, "period") or std.ascii.eqlIgnoreCase(name, "dot")) return @intCast(win32.VK_OEM_PERIOD);
    if (std.ascii.eqlIgnoreCase(name, "slash")) return @intCast(win32.VK_OEM_2);
    if (std.ascii.eqlIgnoreCase(name, "backslash")) return @intCast(win32.VK_OEM_5);
    if (std.ascii.eqlIgnoreCase(name, "semicolon")) return @intCast(win32.VK_OEM_1);
    if (std.ascii.eqlIgnoreCase(name, "quote") or std.ascii.eqlIgnoreCase(name, "apostrophe")) return @intCast(win32.VK_OEM_7);
    if (std.ascii.eqlIgnoreCase(name, "grave") or std.ascii.eqlIgnoreCase(name, "backtick")) return @intCast(win32.VK_OEM_3);
    if (std.ascii.eqlIgnoreCase(name, "bracketleft")) return @intCast(win32.VK_OEM_4);
    if (std.ascii.eqlIgnoreCase(name, "bracketright")) return @intCast(win32.VK_OEM_6);

    return null;
}

test "parseTrigger accelerator parsing" {
    const p1 = try parseTrigger("CTRL+ALT+G");
    try std.testing.expect(p1.modifiers.ctrl);
    try std.testing.expect(p1.modifiers.alt);
    try std.testing.expect(!p1.modifiers.shift);
    try std.testing.expectEqualStrings("G", p1.key);

    const p2 = try parseTrigger("super+shift+Space");
    try std.testing.expect(p2.modifiers.super);
    try std.testing.expect(p2.modifiers.shift);
    try std.testing.expect(!p2.modifiers.ctrl);
    try std.testing.expectEqualStrings("Space", p2.key);

    const p3 = try parseTrigger("ctrl+v");
    try std.testing.expect(p3.modifiers.ctrl);
    try std.testing.expect(!p3.modifiers.alt);
    try std.testing.expectEqualStrings("v", p3.key);

    try std.testing.expectError(error.NoKeyInTrigger, parseTrigger("ctrl+alt"));
    try std.testing.expectError(error.MultipleKeysInTrigger, parseTrigger("ctrl+a+b"));
}

test "vkFor key mapping" {
    // Letters
    try std.testing.expectEqual(@as(?u16, 'A'), vkFor("a"));
    try std.testing.expectEqual(@as(?u16, 'Z'), vkFor("z"));
    try std.testing.expectEqual(@as(?u16, 'G'), vkFor("G"));

    // Digits
    try std.testing.expectEqual(@as(?u16, '0'), vkFor("0"));
    try std.testing.expectEqual(@as(?u16, '9'), vkFor("9"));

    // Function keys F1-F24
    try std.testing.expectEqual(@as(?u16, @intCast(win32.VK_F1)), vkFor("F1"));
    try std.testing.expectEqual(@as(?u16, @intCast(win32.VK_F12)), vkFor("f12"));
    try std.testing.expectEqual(@as(?u16, @intCast(win32.VK_F24)), vkFor("F24"));

    // Standard controls
    try std.testing.expectEqual(@as(?u16, @intCast(win32.VK_SPACE)), vkFor("space"));
    try std.testing.expectEqual(@as(?u16, @intCast(win32.VK_RETURN)), vkFor("enter"));
    try std.testing.expectEqual(@as(?u16, @intCast(win32.VK_RETURN)), vkFor("Return"));
    try std.testing.expectEqual(@as(?u16, @intCast(win32.VK_TAB)), vkFor("tab"));
    try std.testing.expectEqual(@as(?u16, @intCast(win32.VK_ESCAPE)), vkFor("esc"));
    try std.testing.expectEqual(@as(?u16, @intCast(win32.VK_ESCAPE)), vkFor("Escape"));
    try std.testing.expectEqual(@as(?u16, @intCast(win32.VK_BACK)), vkFor("backspace"));

    // Navigation and edit
    try std.testing.expectEqual(@as(?u16, @intCast(win32.VK_UP)), vkFor("up"));
    try std.testing.expectEqual(@as(?u16, @intCast(win32.VK_DOWN)), vkFor("down"));
    try std.testing.expectEqual(@as(?u16, @intCast(win32.VK_LEFT)), vkFor("left"));
    try std.testing.expectEqual(@as(?u16, @intCast(win32.VK_RIGHT)), vkFor("right"));
    try std.testing.expectEqual(@as(?u16, @intCast(win32.VK_HOME)), vkFor("home"));
    try std.testing.expectEqual(@as(?u16, @intCast(win32.VK_END)), vkFor("end"));
    try std.testing.expectEqual(@as(?u16, @intCast(win32.VK_PRIOR)), vkFor("pageup"));
    try std.testing.expectEqual(@as(?u16, @intCast(win32.VK_NEXT)), vkFor("pagedown"));
    try std.testing.expectEqual(@as(?u16, @intCast(win32.VK_INSERT)), vkFor("insert"));
    try std.testing.expectEqual(@as(?u16, @intCast(win32.VK_DELETE)), vkFor("delete"));
    try std.testing.expectEqual(@as(?u16, @intCast(win32.VK_DELETE)), vkFor("del"));

    // Punctuation
    try std.testing.expectEqual(@as(?u16, @intCast(win32.VK_OEM_MINUS)), vkFor("-"));
    try std.testing.expectEqual(@as(?u16, @intCast(win32.VK_OEM_MINUS)), vkFor("minus"));
    try std.testing.expectEqual(@as(?u16, @intCast(win32.VK_OEM_PLUS)), vkFor("="));
    try std.testing.expectEqual(@as(?u16, @intCast(win32.VK_OEM_PLUS)), vkFor("plus"));
    try std.testing.expectEqual(@as(?u16, @intCast(win32.VK_OEM_COMMA)), vkFor(","));
    try std.testing.expectEqual(@as(?u16, @intCast(win32.VK_OEM_PERIOD)), vkFor("."));
    try std.testing.expectEqual(@as(?u16, @intCast(win32.VK_OEM_2)), vkFor("/"));
    try std.testing.expectEqual(@as(?u16, @intCast(win32.VK_OEM_1)), vkFor(";"));

    // Unknown key
    try std.testing.expectEqual(@as(?u16, null), vkFor("unknown_invalid_key"));
}

test {
    std.testing.refAllDecls(@This());
}
