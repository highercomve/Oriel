//! Windows implementation of synthetic input injection using SendInput.

const std = @import("std");
const win32 = @import("../../platform/windows/win32.zig");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");

pub const isExtendedKey = common.isExtendedKey;
pub const buildTypeTextInputs = common.buildTypeTextInputs;
pub const buildKeyComboInputs = common.buildKeyComboInputs;

comptime {
    // Assert struct layouts against winuser.h (authoritative mingw-w64 header)
    if (@import("builtin").cpu.arch == .x86_64) {
        std.debug.assert(@sizeOf(win32.INPUT) == 40);
        std.debug.assert(@sizeOf(win32.KEYBDINPUT) == 24);
        std.debug.assert(@sizeOf(win32.MOUSEINPUT) == 32);
        std.debug.assert(@offsetOf(win32.INPUT, "u") == 8);
        std.debug.assert(@offsetOf(win32.KEYBDINPUT, "dwFlags") == 4);
        std.debug.assert(@offsetOf(win32.KEYBDINPUT, "dwExtraInfo") == 16);
    }
}

/// Inject a key combo into the active application.
pub fn keyCombo(combo: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const inputs = try buildKeyComboInputs(gpa, combo);
    if (inputs.len == 0) return;

    const count = win32.SendInput(@intCast(inputs.len), inputs.ptr, @sizeOf(win32.INPUT));
    if (count != inputs.len) {
        return error.SendInputFailed;
    }
}

/// Type plain text into the currently focused window using SendInput UNICODE events.
pub fn typeText(text: []const u8) !void {
    if (text.len == 0) return;

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const inputs = try buildTypeTextInputs(gpa, text);
    if (inputs.len == 0) return;

    const count = win32.SendInput(@intCast(inputs.len), inputs.ptr, @sizeOf(win32.INPUT));
    if (count != inputs.len) {
        return error.SendInputFailed;
    }
}

/// Synthesize a copy command (Ctrl+C).
pub fn copy() !void {
    try keyCombo("ctrl+c");
    win32.Sleep(80);
}

/// Synthesize a paste command (Ctrl+V).
pub fn paste() !void {
    try keyCombo("ctrl+v");
}

pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    // Verify key mapping works
    const vk_c = common.vkFor("c") orelse return error.VkMappingFailed;
    const vk_v = common.vkFor("v") orelse return error.VkMappingFailed;
    if (vk_c != 'C' or vk_v != 'V') return error.VkMappingFailed;

    // Verify SendInput symbol is resolvable
    const hUser32 = win32.GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("user32.dll")) orelse
        win32.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("user32.dll"));
    var send_input_available = false;
    if (hUser32) |h| {
        if (win32.GetProcAddress(h, "SendInput") != null) {
            send_input_available = true;
        }
    }

    return .{
        .module = "input",
        .ok = send_input_available,
        .detail = try std.fmt.allocPrint(gpa, "Win32 SendInput {s}; key mapping ok (VK_C=0x{X:0>2}, VK_V=0x{X:0>2})", .{
            if (send_input_available) "available" else "unavailable",
            vk_c,
            vk_v,
        }),
    };
}

test {
    std.testing.refAllDecls(@This());
}
