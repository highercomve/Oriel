//! macOS virtual key codes (Carbon `kVK_*`, HIToolbox/Events.h) for the
//! Win32 virtual keys the shared parsers produce (`global_shortcut.vkFor`,
//! input's key names). Codes are key positions on an ANSI keyboard.

const std = @import("std");
const vk = @import("../windows/keys.zig");

/// The macOS key code for a Win32 virtual key, or null if it has none.
pub fn fromVk(key: u16) ?u16 {
    if (key >= 'A' and key <= 'Z') return letters[key - 'A'];
    if (key >= '0' and key <= '9') return digits[key - '0'];
    const f1: u16 = vk.VK_F1;
    if (key >= f1 and key <= f1 + 19) return f_keys[key - f1];
    return switch (key) {
        vk.VK_RETURN => 0x24,
        vk.VK_TAB => 0x30,
        vk.VK_SPACE => 0x31,
        vk.VK_BACK => 0x33, // kVK_Delete (backspace)
        vk.VK_ESCAPE => 0x35,
        vk.VK_DELETE => 0x75, // kVK_ForwardDelete
        vk.VK_INSERT => 0x72, // kVK_Help (Insert on PC keyboards)
        vk.VK_HOME => 0x73,
        vk.VK_END => 0x77,
        vk.VK_PRIOR => 0x74,
        vk.VK_NEXT => 0x79,
        vk.VK_LEFT => 0x7B,
        vk.VK_RIGHT => 0x7C,
        vk.VK_DOWN => 0x7D,
        vk.VK_UP => 0x7E,
        vk.VK_OEM_MINUS => 0x1B,
        vk.VK_OEM_PLUS => 0x18, // kVK_ANSI_Equal
        vk.VK_OEM_COMMA => 0x2B,
        vk.VK_OEM_PERIOD => 0x2F,
        vk.VK_OEM_2 => 0x2C, // slash
        vk.VK_OEM_1 => 0x29, // semicolon
        vk.VK_OEM_7 => 0x27, // quote
        vk.VK_OEM_4 => 0x21, // [
        vk.VK_OEM_6 => 0x1E, // ]
        vk.VK_OEM_5 => 0x2A, // backslash
        vk.VK_OEM_3 => 0x32, // grave
        else => null,
    };
}

const letters = [26]u16{
    0x00, 0x0B, 0x08, 0x02, 0x0E, 0x03, 0x05, 0x04, 0x22, 0x26, 0x28, 0x25, 0x2E, // A..M
    0x2D, 0x1F, 0x23, 0x0C, 0x0F, 0x01, 0x11, 0x20, 0x09, 0x0D, 0x07, 0x10, 0x06, // N..Z
};
const digits = [10]u16{ 0x1D, 0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19 };
const f_keys = [20]u16{ 0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A };

test fromVk {
    try std.testing.expectEqual(@as(?u16, 0x00), fromVk('A'));
    try std.testing.expectEqual(@as(?u16, 0x05), fromVk('G'));
    try std.testing.expectEqual(@as(?u16, 0x06), fromVk('Z'));
    try std.testing.expectEqual(@as(?u16, 0x1D), fromVk('0'));
    try std.testing.expectEqual(@as(?u16, 0x7A), fromVk(vk.VK_F1));
    try std.testing.expectEqual(@as(?u16, 0x6F), fromVk(vk.VK_F1 + 11));
    try std.testing.expectEqual(@as(?u16, 0x31), fromVk(vk.VK_SPACE));
    try std.testing.expectEqual(@as(?u16, null), fromVk(vk.VK_F24));
}
