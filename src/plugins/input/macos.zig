//! macOS synthetic keyboard input: CGEvent.
//!
//! macOS drops posted events unless the app has the Accessibility
//! permission (System Settings > Privacy & Security > Accessibility; for an
//! unbundled executable, the terminal that started it). Every call checks
//! `AXIsProcessTrusted()` first and fails with error.AccessibilityNotGranted
//! instead of silently doing nothing.
//!
//! `typeText` sends the text as Unicode strings (layout independent);
//! `keyCombo` maps modifiers literally (ctrl/alt/shift/cmd); `copy` and
//! `paste` send ⌘C / ⌘V, the Mac equivalents of Ctrl+C / Ctrl+V.

const std = @import("std");
const keycodes = @import("../../platform/macos/keycodes.zig");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");

const CGEventRef = *opaque {};
const CGEventSourceRef = *opaque {};
extern "c" fn AXIsProcessTrusted() u8;
extern "c" fn CGEventSourceCreate(state: i32) ?CGEventSourceRef;
extern "c" fn CGEventCreateKeyboardEvent(source: ?CGEventSourceRef, key: u16, down: bool) ?CGEventRef;
extern "c" fn CGEventSetFlags(event: CGEventRef, flags: u64) void;
extern "c" fn CGEventKeyboardSetUnicodeString(event: CGEventRef, len: c_ulong, chars: [*]const u16) void;
extern "c" fn CGEventPost(tap: u32, event: CGEventRef) void;
extern "c" fn CFRelease(obj: *anyopaque) void;

const kCGEventSourceStateHIDSystemState: i32 = 1;
const kCGHIDEventTap: u32 = 0;
const flag_shift: u64 = 0x00020000;
const flag_control: u64 = 0x00040000;
const flag_option: u64 = 0x00080000;
const flag_command: u64 = 0x00100000;
/// CGEventKeyboardSetUnicodeString handles at most 20 UTF-16 units per event.
const max_units_per_event = 20;

pub fn accessibilityGranted() bool {
    return AXIsProcessTrusted() != 0;
}

pub fn eventFlags(m: @import("../global_shortcut/common.zig").Modifiers) u64 {
    var flags: u64 = 0;
    if (m.ctrl) flags |= flag_control;
    if (m.alt) flags |= flag_option;
    if (m.shift) flags |= flag_shift;
    if (m.super) flags |= flag_command;
    return flags;
}

fn post(source: ?CGEventSourceRef, key: u16, down: bool, flags: u64, text: ?[]const u16) !void {
    const ev = CGEventCreateKeyboardEvent(source, key, down) orelse return error.CGEventCreateFailed;
    defer CFRelease(ev);
    CGEventSetFlags(ev, flags);
    if (text) |t| CGEventKeyboardSetUnicodeString(ev, t.len, t.ptr);
    CGEventPost(kCGHIDEventTap, ev);
}

/// Press and release a combination like "cmd+shift+t" in the active app.
pub fn keyCombo(combo: []const u8) !void {
    if (!accessibilityGranted()) return error.AccessibilityNotGranted;
    const parsed = try common.parseTrigger(combo);
    const vk = common.vkFor(parsed.key) orelse return error.UnknownKey;
    const code = keycodes.fromVk(vk) orelse return error.UnknownKey;
    const source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    defer if (source) |s| CFRelease(s);
    const flags = eventFlags(parsed.modifiers);
    try post(source, code, true, flags, null);
    try post(source, code, false, flags, null);
}

/// Type `text` into the focused app.
pub fn typeText(text: []const u8) !void {
    if (text.len == 0) return;
    if (!accessibilityGranted()) return error.AccessibilityNotGranted;
    var buf: [4096]u16 = undefined;
    const source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    defer if (source) |s| CFRelease(s);
    var rest = text;
    while (rest.len > 0) {
        // Convert in slices that end on a code point boundary.
        var end = @min(rest.len, 2048);
        while (end < rest.len and end > 0 and (rest[end] & 0xC0) == 0x80) end -= 1;
        if (end == 0) return error.InvalidUtf8; // no code point starts in this slice
        const n = std.unicode.utf8ToUtf16Le(&buf, rest[0..end]) catch return error.InvalidUtf8;
        rest = rest[end..];
        var i: usize = 0;
        while (i < n) {
            var take = @min(n - i, max_units_per_event);
            // Don't split a surrogate pair across events.
            if (i + take < n and buf[i + take - 1] >= 0xD800 and buf[i + take - 1] <= 0xDBFF) take -= 1;
            const units = buf[i..][0..take];
            try post(source, 0, true, 0, units);
            try post(source, 0, false, 0, units);
            i += take;
        }
    }
}

/// ⌘C, then a short wait so the target app has updated the clipboard.
pub fn copy() !void {
    try keyCombo("cmd+c");
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 80 * std.time.ns_per_ms };
    _ = std.c.nanosleep(&ts, &ts);
}

/// ⌘V.
pub fn paste() !void {
    try keyCombo("cmd+v");
}

/// Without the Accessibility permission the check is an explicit skip
/// (it can't be granted programmatically); with it, event creation is checked.
pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    const code = keycodes.fromVk(common.vkFor("v").?).?;
    if (!accessibilityGranted()) {
        return .{
            .module = "input",
            .ok = true,
            .detail = try std.fmt.allocPrint(gpa, "SKIP (permission): Accessibility not granted to this process, so CGEvent input would be dropped; calls return error.AccessibilityNotGranted. Key mapping ok (v = kVK 0x{X:0>2})", .{code}),
        };
    }
    const ev = CGEventCreateKeyboardEvent(null, code, true) orelse return .{ .module = "input", .ok = false, .detail = "CGEventCreateKeyboardEvent failed" };
    CFRelease(ev); // created, not posted: the check types nothing
    return .{
        .module = "input",
        .ok = true,
        .detail = try std.fmt.allocPrint(gpa, "Accessibility granted; CGEvent keyboard events available (v = kVK 0x{X:0>2})", .{code}),
    };
}

test eventFlags {
    try std.testing.expectEqual(flag_command | flag_shift, eventFlags((try common.parseTrigger("cmd+shift+t")).modifiers));
    try std.testing.expectEqual(flag_control, eventFlags((try common.parseTrigger("ctrl+v")).modifiers));
}

test {
    std.testing.refAllDecls(@This());
}
