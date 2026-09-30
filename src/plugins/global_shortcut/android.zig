//! Android backend: keyboard shortcuts for the app's own windows.
//!
//! Android has no system-wide hotkeys: a shortcut works while one of the
//! app's windows has focus, with a hardware keyboard (desktop windowing,
//! ChromeOS, DeX, a tablet's keyboard). OrielActivity.dispatchKeyEvent
//! matches it before the WebView sees the key, so the page doesn't get it,
//! and onProvideKeyboardShortcuts lists the shortcuts, with their
//! descriptions, in the system's keyboard shortcuts helper (Meta+/).
//! The callback runs on the UI thread.

const std = @import("std");
const oriel = @import("../../oriel.zig");
const ShellMod = @import("../../platform/android/Shell.zig");
const runtime = @import("../../platform/android/runtime.zig");
const jni = @import("../../platform/android/jni.zig");
const heap = @import("../../core/heap.zig");
const win32 = @import("../../platform/windows/keys.zig"); // constants only
pub const common = @import("common.zig");

pub const Modifiers = common.Modifiers;
pub const Shortcut = common.Shortcut;
pub const ParsedTrigger = common.ParsedTrigger;
pub const Callback = common.Callback;
pub const parseTrigger = common.parseTrigger;
pub const vkFor = common.vkFor;

const Registered = struct {
    shortcut: Shortcut,
    callback: Callback,
    keycode: u16,
    meta: u32,
};

var shortcuts: std.ArrayList(Registered) = .empty;
var gpa_used: ?std.mem.Allocator = null;
var mutex: ShellMod.Mutex = .{};

// android.view.KeyEvent meta states (also KeyboardShortcutInfo's modifiers).
const META_SHIFT_ON: u32 = 0x1;
const META_ALT_ON: u32 = 0x2;
const META_CTRL_ON: u32 = 0x1000;
const META_META_ON: u32 = 0x10000;

pub fn metaState(m: Modifiers) u32 {
    var meta: u32 = 0;
    if (m.ctrl) meta |= META_CTRL_ON;
    if (m.alt) meta |= META_ALT_ON;
    if (m.shift) meta |= META_SHIFT_ON;
    if (m.super) meta |= META_META_ON;
    return meta;
}

/// android.view.KeyEvent key code for a Win32 virtual key (what `vkFor`
/// returns). Android has F1-F12 only.
pub fn keycodeFor(vk: u16) ?u16 {
    if (vk >= 'A' and vk <= 'Z') return 29 + (vk - 'A'); // KEYCODE_A
    if (vk >= '0' and vk <= '9') return 7 + (vk - '0'); // KEYCODE_0
    if (vk >= win32.VK_F1 and vk <= win32.VK_F12) return 131 + (vk - @as(u16, win32.VK_F1)); // KEYCODE_F1
    return switch (@as(c_int, vk)) {
        win32.VK_SPACE => 62,
        win32.VK_RETURN => 66,
        win32.VK_TAB => 61,
        win32.VK_ESCAPE => 111,
        win32.VK_BACK => 67, // KEYCODE_DEL
        win32.VK_DELETE => 112, // KEYCODE_FORWARD_DEL
        win32.VK_INSERT => 124,
        win32.VK_UP => 19,
        win32.VK_DOWN => 20,
        win32.VK_LEFT => 21,
        win32.VK_RIGHT => 22,
        win32.VK_HOME => 122, // KEYCODE_MOVE_HOME
        win32.VK_END => 123, // KEYCODE_MOVE_END
        win32.VK_PRIOR => 92, // KEYCODE_PAGE_UP
        win32.VK_NEXT => 93, // KEYCODE_PAGE_DOWN
        win32.VK_OEM_MINUS => 69,
        win32.VK_OEM_PLUS => 70, // KEYCODE_EQUALS
        win32.VK_OEM_COMMA => 55,
        win32.VK_OEM_PERIOD => 56,
        win32.VK_OEM_2 => 76, // KEYCODE_SLASH
        win32.VK_OEM_1 => 74, // KEYCODE_SEMICOLON
        win32.VK_OEM_7 => 75, // KEYCODE_APOSTROPHE
        win32.VK_OEM_4 => 71, // KEYCODE_LEFT_BRACKET
        win32.VK_OEM_6 => 72, // KEYCODE_RIGHT_BRACKET
        win32.VK_OEM_5 => 73, // KEYCODE_BACKSLASH
        win32.VK_OEM_3 => 68, // KEYCODE_GRAVE
        else => null,
    };
}

/// Register a shortcut for the app's windows. `shortcut` must outlive the
/// registration (its id is passed to the callback). The description is
/// what the Meta+/ helper shows (the id when empty). Any thread, once the
/// app runs (e.g. in `setup`).
pub fn register(gpa: std.mem.Allocator, shortcut: Shortcut, callback: Callback) !void {
    const parsed = try parseTrigger(shortcut.trigger);
    const vk = vkFor(parsed.key) orelse return error.UnknownKey;
    const keycode = keycodeFor(vk) orelse return error.UnknownKey;
    const meta = metaState(parsed.modifiers);
    {
        mutex.lock();
        defer mutex.unlock();
        for (shortcuts.items) |s| {
            if (s.keycode == keycode and s.meta == meta) return error.HotkeyAlreadyRegistered;
        }
        try shortcuts.append(gpa, .{ .shortcut = shortcut, .callback = callback, .keycode = keycode, .meta = meta });
        gpa_used = gpa;
    }
    push() catch |err| {
        _ = remove(shortcut.id);
        return err;
    };
}

pub fn unregister(id: []const u8) bool {
    if (!remove(id)) return false;
    push() catch {};
    return true;
}

fn remove(id: []const u8) bool {
    mutex.lock();
    defer mutex.unlock();
    for (shortcuts.items, 0..) |s, i| {
        if (std.mem.eql(u8, s.shortcut.id, id)) {
            _ = shortcuts.orderedRemove(i);
            return true;
        }
    }
    return false;
}

/// Run the callback of shortcut `id` as if it had been pressed.
pub fn trigger(id: []const u8) bool {
    var cb: ?Callback = null;
    mutex.lock();
    for (shortcuts.items) |s| {
        if (std.mem.eql(u8, s.shortcut.id, id)) {
            cb = s.callback;
            break;
        }
    }
    mutex.unlock();
    // Outside the lock: a callback may register or unregister shortcuts.
    if (cb) |callback| {
        callback(id);
        return true;
    }
    return false;
}

pub fn deinit(gpa: std.mem.Allocator) void {
    {
        mutex.lock();
        defer mutex.unlock();
        shortcuts.deinit(gpa);
        shortcuts = .empty;
    }
    push() catch {};
}

/// The table as OrielRuntime.setShortcuts reads it: one
/// "id\tkeycode\tmeta\tdescription\n" line per shortcut.
fn serialize(gpa: std.mem.Allocator) ![]u8 {
    mutex.lock();
    defer mutex.unlock();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (shortcuts.items) |s| {
        const label = if (s.shortcut.description.len > 0) s.shortcut.description else s.shortcut.id;
        try out.print(gpa, "{s}\t{d}\t{d}\t{s}\n", .{ clean(s.shortcut.id), s.keycode, s.meta, clean(label) });
    }
    return out.toOwnedSlice(gpa);
}

/// Tabs and newlines would break the table: only the part before them.
fn clean(s: []const u8) []const u8 {
    return s[0 .. std.mem.indexOfAny(u8, s, "\t\n") orelse s.len];
}

/// Hand the whole table to Kotlin (UI thread).
fn push() !void {
    const table = try serialize(heap.gpa);
    defer heap.gpa.free(table);
    const Ctx = struct {
        table: []const u8,
        fn run(self: *@This()) void {
            _ = runtime.call(.void, "setShortcuts", "([B)V", .{self.table});
        }
    };
    var ctx: Ctx = .{ .table = table };
    try ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run);
}

/// NativeLib.onShortcut: OrielActivity matched a key press (UI thread).
fn nativeShortcut(env: *jni.Env, _: jni.jclass, id_arr: jni.jobject) callconv(.c) void {
    const id = (env.bytesAlloc(heap.gpa, id_arr) catch return) orelse return;
    defer heap.gpa.free(id);
    _ = trigger(id);
}

comptime {
    @export(&nativeShortcut, .{ .name = "Java_dev_oriel_NativeLib_onShortcut" });
}

pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    const parsed = try parseTrigger("ctrl+shift+F12");
    const ok = keycodeFor(vkFor(parsed.key).?) != null;
    return .{
        .module = "global_shortcut",
        .ok = ok,
        .detail = try gpa.dupe(u8, "in-app shortcuts (focused window, hardware keyboard), listed in the Meta+/ helper"),
    };
}

test keycodeFor {
    try std.testing.expectEqual(@as(?u16, 29), keycodeFor(vkFor("a").?));
    try std.testing.expectEqual(@as(?u16, 54), keycodeFor(vkFor("Z").?));
    try std.testing.expectEqual(@as(?u16, 7), keycodeFor(vkFor("0").?));
    try std.testing.expectEqual(@as(?u16, 131), keycodeFor(vkFor("F1").?));
    try std.testing.expectEqual(@as(?u16, 142), keycodeFor(vkFor("F12").?));
    try std.testing.expectEqual(@as(?u16, null), keycodeFor(vkFor("F13").?));
    try std.testing.expectEqual(@as(?u16, 62), keycodeFor(vkFor("space").?));
    try std.testing.expectEqual(@as(?u16, 76), keycodeFor(vkFor("/").?));
    const p = try parseTrigger("ctrl+shift+D");
    try std.testing.expectEqual(META_CTRL_ON | META_SHIFT_ON, metaState(p.modifiers));
}

test serialize {
    defer {
        shortcuts.deinit(std.testing.allocator);
        shortcuts = .empty;
    }
    try shortcuts.append(std.testing.allocator, .{ .shortcut = .{ .id = "rec", .description = "Start\tdictation", .trigger = "ctrl+d" }, .callback = undefined, .keycode = 32, .meta = META_CTRL_ON });
    try shortcuts.append(std.testing.allocator, .{ .shortcut = .{ .id = "tab1", .trigger = "ctrl+1" }, .callback = undefined, .keycode = 8, .meta = META_CTRL_ON });
    const t = try serialize(std.testing.allocator);
    defer std.testing.allocator.free(t);
    try std.testing.expectEqualStrings("rec\t32\t4096\tStart\ntab1\t8\t4096\ttab1\n", t);
}
