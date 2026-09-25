//! Platform-neutral data models and pure functions for input injection.

const std = @import("std");
const win32 = @import("../../platform/windows/keys.zig"); // constants only: builds on every OS
const gs_common = @import("../global_shortcut/common.zig");

pub const parseTrigger = gs_common.parseTrigger;
pub const vkFor = gs_common.vkFor;

pub fn isExtendedKey(vk: u16) bool {
    return switch (vk) {
        @as(u16, @intCast(win32.VK_UP)),
        @as(u16, @intCast(win32.VK_DOWN)),
        @as(u16, @intCast(win32.VK_LEFT)),
        @as(u16, @intCast(win32.VK_RIGHT)),
        @as(u16, @intCast(win32.VK_HOME)),
        @as(u16, @intCast(win32.VK_END)),
        @as(u16, @intCast(win32.VK_PRIOR)),
        @as(u16, @intCast(win32.VK_NEXT)),
        @as(u16, @intCast(win32.VK_INSERT)),
        @as(u16, @intCast(win32.VK_DELETE)),
        @as(u16, @intCast(win32.VK_RCONTROL)),
        @as(u16, @intCast(win32.VK_RMENU)),
        => true,
        else => false,
    };
}

fn makeUnicodeInput(code_unit: u16, key_up: bool) win32.INPUT {
    var flags: win32.DWORD = win32.KEYEVENTF_UNICODE;
    if (key_up) flags |= win32.KEYEVENTF_KEYUP;
    return .{
        .type = win32.INPUT_KEYBOARD,
        .u = .{
            .ki = .{
                .wVk = 0,
                .wScan = code_unit,
                .dwFlags = flags,
                .time = 0,
                .dwExtraInfo = 0,
            },
        },
    };
}

fn makeKeyInput(vk: u16, key_up: bool, extended: bool) win32.INPUT {
    var flags: win32.DWORD = 0;
    if (key_up) flags |= win32.KEYEVENTF_KEYUP;
    if (extended) flags |= win32.KEYEVENTF_EXTENDEDKEY;
    return .{
        .type = win32.INPUT_KEYBOARD,
        .u = .{
            .ki = .{
                .wVk = vk,
                .wScan = 0,
                .dwFlags = flags,
                .time = 0,
                .dwExtraInfo = 0,
            },
        },
    };
}

/// Pure function: builds an array of Win32 INPUT structures for typing the given UTF-8 text.
/// Each UTF-16 code unit (including surrogate pairs) produces a keydown and keyup pair.
pub fn buildTypeTextInputs(allocator: std.mem.Allocator, text: []const u8) ![]win32.INPUT {
    const u16_slice = try std.unicode.utf8ToUtf16LeAlloc(allocator, text);
    defer allocator.free(u16_slice);

    const inputs = try allocator.alloc(win32.INPUT, u16_slice.len * 2);
    for (u16_slice, 0..) |code_unit, i| {
        inputs[i * 2 + 0] = makeUnicodeInput(code_unit, false);
        inputs[i * 2 + 1] = makeUnicodeInput(code_unit, true);
    }
    return inputs;
}

/// Pure function: builds an array of Win32 INPUT structures for executing a key combination.
/// Modifiers are pressed down in order, the target key is pressed down and released,
/// and modifiers are released in reverse order. Extended keys receive KEYEVENTF_EXTENDEDKEY.
pub fn buildKeyComboInputs(allocator: std.mem.Allocator, combo: []const u8) ![]win32.INPUT {
    const parsed = try parseTrigger(combo);
    const vk = vkFor(parsed.key) orelse return error.UnknownKey;

    var mod_vks: [4]u16 = undefined;
    var mod_count: usize = 0;
    if (parsed.modifiers.ctrl) {
        mod_vks[mod_count] = @intCast(win32.VK_CONTROL);
        mod_count += 1;
    }
    if (parsed.modifiers.alt) {
        mod_vks[mod_count] = @intCast(win32.VK_MENU);
        mod_count += 1;
    }
    if (parsed.modifiers.shift) {
        mod_vks[mod_count] = @intCast(win32.VK_SHIFT);
        mod_count += 1;
    }
    if (parsed.modifiers.super) {
        mod_vks[mod_count] = @intCast(win32.VK_LWIN);
        mod_count += 1;
    }

    const total_inputs = mod_count * 2 + 2;
    const inputs = try allocator.alloc(win32.INPUT, total_inputs);
    var idx: usize = 0;

    // 1. Modifiers down in order
    for (mod_vks[0..mod_count]) |m_vk| {
        inputs[idx] = makeKeyInput(m_vk, false, false);
        idx += 1;
    }

    // 2. Main key down & up
    const is_ext = isExtendedKey(vk);
    inputs[idx] = makeKeyInput(vk, false, is_ext);
    idx += 1;
    inputs[idx] = makeKeyInput(vk, true, is_ext);
    idx += 1;

    // 3. Modifiers up in reverse order
    var i: usize = mod_count;
    while (i > 0) : (i -= 1) {
        inputs[idx] = makeKeyInput(mod_vks[i - 1], true, false);
        idx += 1;
    }

    return inputs;
}

test "buildTypeTextInputs creates unicode down/up pairs" {
    const gpa = std.testing.allocator;

    // ASCII text
    const inputs_ascii = try buildTypeTextInputs(gpa, "Hi");
    defer gpa.free(inputs_ascii);
    try std.testing.expectEqual(@as(usize, 4), inputs_ascii.len);

    // 'H' = 0x48 down/up
    try std.testing.expectEqual(win32.INPUT_KEYBOARD, inputs_ascii[0].type);
    try std.testing.expectEqual(@as(u16, 'H'), inputs_ascii[0].u.ki.wScan);
    try std.testing.expectEqual(win32.KEYEVENTF_UNICODE, inputs_ascii[0].u.ki.dwFlags);
    try std.testing.expectEqual(win32.KEYEVENTF_UNICODE | win32.KEYEVENTF_KEYUP, inputs_ascii[1].u.ki.dwFlags);

    // 'i' = 0x69 down/up
    try std.testing.expectEqual(@as(u16, 'i'), inputs_ascii[2].u.ki.wScan);
    try std.testing.expectEqual(win32.KEYEVENTF_UNICODE, inputs_ascii[2].u.ki.dwFlags);
    try std.testing.expectEqual(win32.KEYEVENTF_UNICODE | win32.KEYEVENTF_KEYUP, inputs_ascii[3].u.ki.dwFlags);

    // Surrogate pair emoji: 😀 (U+1F600, UTF-16: 0xD83D, 0xDE00)
    const inputs_emoji = try buildTypeTextInputs(gpa, "😀");
    defer gpa.free(inputs_emoji);
    try std.testing.expectEqual(@as(usize, 4), inputs_emoji.len);
    try std.testing.expectEqual(@as(u16, 0xD83D), inputs_emoji[0].u.ki.wScan);
    try std.testing.expectEqual(@as(u16, 0xDE00), inputs_emoji[2].u.ki.wScan);
}

test "buildKeyComboInputs modifiers down in order, key down/up, modifiers up in reverse" {
    const gpa = std.testing.allocator;

    // "ctrl+v"
    const inputs_cv = try buildKeyComboInputs(gpa, "ctrl+v");
    defer gpa.free(inputs_cv);
    try std.testing.expectEqual(@as(usize, 4), inputs_cv.len);

    // 1. ctrl down
    try std.testing.expectEqual(@as(u16, @intCast(win32.VK_CONTROL)), inputs_cv[0].u.ki.wVk);
    try std.testing.expectEqual(@as(win32.DWORD, 0), inputs_cv[0].u.ki.dwFlags);

    // 2. 'V' down
    try std.testing.expectEqual(@as(u16, 'V'), inputs_cv[1].u.ki.wVk);
    try std.testing.expectEqual(@as(win32.DWORD, 0), inputs_cv[1].u.ki.dwFlags);

    // 3. 'V' up
    try std.testing.expectEqual(@as(u16, 'V'), inputs_cv[2].u.ki.wVk);
    try std.testing.expectEqual(win32.KEYEVENTF_KEYUP, inputs_cv[2].u.ki.dwFlags);

    // 4. ctrl up
    try std.testing.expectEqual(@as(u16, @intCast(win32.VK_CONTROL)), inputs_cv[3].u.ki.wVk);
    try std.testing.expectEqual(win32.KEYEVENTF_KEYUP, inputs_cv[3].u.ki.dwFlags);

    // Multiple modifiers and extended key: "ctrl+alt+delete"
    const inputs_cad = try buildKeyComboInputs(gpa, "ctrl+alt+delete");
    defer gpa.free(inputs_cad);
    try std.testing.expectEqual(@as(usize, 6), inputs_cad.len);

    // 1. ctrl down, 2. alt down
    try std.testing.expectEqual(@as(u16, @intCast(win32.VK_CONTROL)), inputs_cad[0].u.ki.wVk);
    try std.testing.expectEqual(@as(u16, @intCast(win32.VK_MENU)), inputs_cad[1].u.ki.wVk);

    // 3. DELETE down with KEYEVENTF_EXTENDEDKEY
    try std.testing.expectEqual(@as(u16, @intCast(win32.VK_DELETE)), inputs_cad[2].u.ki.wVk);
    try std.testing.expectEqual(win32.KEYEVENTF_EXTENDEDKEY, inputs_cad[2].u.ki.dwFlags);

    // 4. DELETE up with KEYEVENTF_EXTENDEDKEY | KEYEVENTF_KEYUP
    try std.testing.expectEqual(@as(u16, @intCast(win32.VK_DELETE)), inputs_cad[3].u.ki.wVk);
    try std.testing.expectEqual(win32.KEYEVENTF_EXTENDEDKEY | win32.KEYEVENTF_KEYUP, inputs_cad[3].u.ki.dwFlags);

    // 5. alt up, 6. ctrl up (REVERSE ORDER!)
    try std.testing.expectEqual(@as(u16, @intCast(win32.VK_MENU)), inputs_cad[4].u.ki.wVk);
    try std.testing.expectEqual(win32.KEYEVENTF_KEYUP, inputs_cad[4].u.ki.dwFlags);
    try std.testing.expectEqual(@as(u16, @intCast(win32.VK_CONTROL)), inputs_cad[5].u.ki.wVk);
    try std.testing.expectEqual(win32.KEYEVENTF_KEYUP, inputs_cad[5].u.ki.dwFlags);
}

test {
    std.testing.refAllDecls(@This());
}
