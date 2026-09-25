//! Windows implementation of global shortcuts (RegisterHotKey + WM_HOTKEY).

const std = @import("std");
const win32 = @import("../../platform/windows/win32.zig");
const ShellMod = @import("../../platform/windows/Shell.zig");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");

pub const Modifiers = common.Modifiers;
pub const Shortcut = common.Shortcut;
pub const ParsedTrigger = common.ParsedTrigger;
pub const Callback = common.Callback;
pub const parseTrigger = common.parseTrigger;
pub const vkFor = common.vkFor;

const log = std.log.scoped(.oriel);

pub const Registered = struct {
    id_int: c_int,
    shortcut: Shortcut,
    callback: Callback,
    vk: u16,
    fs_modifiers: win32.UINT,
};

var shortcuts: std.ArrayList(Registered) = .empty;
var next_hotkey_id: std.atomic.Value(c_int) = .init(1);
var shortcuts_mutex: win32.SRWLOCK = win32.SRWLOCK_INIT;

fn onShellHotKey(id_usize: usize) void {
    const id_int: c_int = @truncate(@as(isize, @bitCast(id_usize)));
    var cb: ?Callback = null;
    var target_id: ?[]const u8 = null;

    win32.AcquireSRWLockExclusive(&shortcuts_mutex);
    for (shortcuts.items) |entry| {
        if (entry.id_int == id_int) {
            cb = entry.callback;
            target_id = entry.shortcut.id;
            break;
        }
    }
    win32.ReleaseSRWLockExclusive(&shortcuts_mutex);

    // Call callback outside shortcuts_mutex so callbacks that call register/unregister/trigger do not deadlock
    if (cb) |callback| {
        callback(target_id.?);
    }
}

const RegisterContext = struct {
    gpa: std.mem.Allocator,
    shortcut: Shortcut,
    callback: Callback,
    result: anyerror!void = {},
};

fn registerMain(ctx: *RegisterContext) void {
    ctx.result = registerDirect(ctx.gpa, ctx.shortcut, ctx.callback);
}

pub fn register(gpa: std.mem.Allocator, shortcut: Shortcut, callback: Callback) !void {
    var ctx = RegisterContext{
        .gpa = gpa,
        .shortcut = shortcut,
        .callback = callback,
    };
    try ShellMod.runOnMainThread(RegisterContext, &ctx, registerMain);
    return ctx.result;
}

fn registerDirect(gpa: std.mem.Allocator, shortcut: Shortcut, callback: Callback) !void {
    const host_hwnd = ShellMod.host_hwnd orelse return error.HostWindowNotReady;

    const parsed = try parseTrigger(shortcut.trigger);
    const vk = vkFor(parsed.key) orelse return error.UnknownKey;

    var fs_modifiers: win32.UINT = win32.MOD_NOREPEAT;
    if (parsed.modifiers.alt) fs_modifiers |= win32.MOD_ALT;
    if (parsed.modifiers.ctrl) fs_modifiers |= win32.MOD_CONTROL;
    if (parsed.modifiers.shift) fs_modifiers |= win32.MOD_SHIFT;
    if (parsed.modifiers.super) fs_modifiers |= win32.MOD_WIN;

    const hotkey_id = next_hotkey_id.fetchAdd(1, .monotonic);

    if (win32.RegisterHotKey(host_hwnd, hotkey_id, fs_modifiers, vk) == win32.FALSE) {
        const last_err = win32.GetLastError();
        if (last_err == win32.ERROR_HOTKEY_ALREADY_REGISTERED) {
            return error.HotkeyAlreadyRegistered;
        }
        return error.RegisterHotKeyFailed;
    }
    // UnregisterHotKey return value ignored on errdefer cleanup; nothing can be recovered
    errdefer _ = win32.UnregisterHotKey(host_hwnd, hotkey_id);

    win32.AcquireSRWLockExclusive(&shortcuts_mutex);
    defer win32.ReleaseSRWLockExclusive(&shortcuts_mutex);

    try shortcuts.append(gpa, .{
        .id_int = hotkey_id,
        .shortcut = shortcut,
        .callback = callback,
        .vk = vk,
        .fs_modifiers = fs_modifiers,
    });

    ShellMod.on_hotkey_fn = &onShellHotKey;
}

const UnregisterContext = struct {
    id: []const u8,
    result: bool = false,
};

fn unregisterMain(ctx: *UnregisterContext) void {
    ctx.result = unregisterDirect(ctx.id);
}

pub fn unregister(id: []const u8) bool {
    var ctx = UnregisterContext{
        .id = id,
    };
    ShellMod.runOnMainThread(UnregisterContext, &ctx, unregisterMain) catch return false;
    return ctx.result;
}

fn unregisterDirect(id: []const u8) bool {
    win32.AcquireSRWLockExclusive(&shortcuts_mutex);
    defer win32.ReleaseSRWLockExclusive(&shortcuts_mutex);

    for (shortcuts.items, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.shortcut.id, id)) {
            if (ShellMod.host_hwnd) |hwnd| {
                // UnregisterHotKey return value ignored on unregister; hotkey is removed from table regardless
                _ = win32.UnregisterHotKey(hwnd, entry.id_int);
            }
            _ = shortcuts.swapRemove(i);
            return true;
        }
    }
    return false;
}

pub fn trigger(id: []const u8) bool {
    var cb: ?Callback = null;

    win32.AcquireSRWLockExclusive(&shortcuts_mutex);
    for (shortcuts.items) |entry| {
        if (std.mem.eql(u8, entry.shortcut.id, id)) {
            cb = entry.callback;
            break;
        }
    }
    win32.ReleaseSRWLockExclusive(&shortcuts_mutex);

    // Call callback outside shortcuts_mutex so callbacks that call register/unregister/trigger do not deadlock
    if (cb) |callback| {
        callback(id);
        return true;
    }
    return false;
}

pub fn deinit(gpa: std.mem.Allocator) void {
    win32.AcquireSRWLockExclusive(&shortcuts_mutex);
    defer win32.ReleaseSRWLockExclusive(&shortcuts_mutex);

    if (ShellMod.host_hwnd) |hwnd| {
        for (shortcuts.items) |entry| {
            // UnregisterHotKey return value ignored on teardown; nothing can be recovered
            _ = win32.UnregisterHotKey(hwnd, entry.id_int);
        }
    }
    ShellMod.on_hotkey_fn = null;
    shortcuts.deinit(gpa);
    shortcuts = .empty;
}

pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    const test_vk = vkFor("G") orelse return error.VkMappingFailed;
    if (test_vk != 'G') return error.VkMappingFailed;

    const host_ready = ShellMod.host_hwnd != null;
    return .{
        .module = "global_shortcut",
        .ok = true,
        .detail = try std.fmt.allocPrint(gpa, "Win32 RegisterHotKey available (host window: {s})", .{
            if (host_ready) "active" else "ready on run",
        }),
    };
}

test "trigger registered shortcut windows" {
    const H = struct {
        var triggered: bool = false;
        fn cb(_: []const u8) void {
            triggered = true;
        }
    };
    try shortcuts.append(std.testing.allocator, .{
        .id_int = 12345,
        .shortcut = .{ .id = "win_test_hotkey", .trigger = "ctrl+alt+w" },
        .callback = &H.cb,
        .vk = 'W',
        .fs_modifiers = 0,
    });
    defer {
        _ = shortcuts.pop();
        // The list is global: free its buffer so the testing allocator sees no leak.
        if (shortcuts.items.len == 0) shortcuts.clearAndFree(std.testing.allocator);
    }

    try std.testing.expect(trigger("win_test_hotkey"));
    try std.testing.expect(H.triggered);
    try std.testing.expect(!trigger("non_existent"));
}

test "trigger re-entrant callback does not deadlock" {
    const H = struct {
        var reentered: bool = false;
        fn cb(id: []const u8) void {
            // Re-entrant call to trigger another shortcut while executing
            if (std.mem.eql(u8, id, "first_hotkey")) {
                _ = trigger("second_hotkey");
            } else if (std.mem.eql(u8, id, "second_hotkey")) {
                reentered = true;
            }
        }
    };

    try shortcuts.append(std.testing.allocator, .{
        .id_int = 1001,
        .shortcut = .{ .id = "first_hotkey", .trigger = "ctrl+alt+1" },
        .callback = &H.cb,
        .vk = '1',
        .fs_modifiers = 0,
    });
    defer {
        _ = shortcuts.pop();
        if (shortcuts.items.len == 0) shortcuts.clearAndFree(std.testing.allocator);
    }

    try shortcuts.append(std.testing.allocator, .{
        .id_int = 1002,
        .shortcut = .{ .id = "second_hotkey", .trigger = "ctrl+alt+2" },
        .callback = &H.cb,
        .vk = '2',
        .fs_modifiers = 0,
    });
    defer _ = shortcuts.pop();

    try std.testing.expect(trigger("first_hotkey"));
    try std.testing.expect(H.reentered);
}

test {
    std.testing.refAllDecls(@This());
}
