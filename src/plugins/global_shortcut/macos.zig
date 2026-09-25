//! macOS global shortcuts: Carbon RegisterEventHotKey.
//!
//! Needs no permission (unlike event taps). Hot key events arrive through
//! the application event target, which NSApplication's run loop services;
//! callbacks run on the main thread. Modifiers map literally: `ctrl` ->
//! Control, `alt` -> Option, `shift` -> Shift, `super`/`meta`/`cmd`/`win` ->
//! Command. Registration fails with error.HotkeyAlreadyRegistered when
//! another app holds the combination.

const std = @import("std");
const ShellMod = @import("../../platform/macos/Shell.zig");
const keycodes = @import("../../platform/macos/keycodes.zig");
const oriel = @import("../../oriel.zig");
pub const common = @import("common.zig");

pub const Modifiers = common.Modifiers;
pub const Shortcut = common.Shortcut;
pub const ParsedTrigger = common.ParsedTrigger;
pub const Callback = common.Callback;
pub const parseTrigger = common.parseTrigger;
pub const vkFor = common.vkFor;

const c = std.c;

// --- Carbon (HIToolbox) -------------------------------------------------------------

const OSStatus = i32;
const EventTargetRef = *opaque {};
const EventHandlerRef = *opaque {};
const EventHotKeyRef = *opaque {};
const EventRef = *opaque {};
const EventHandlerCallRef = *opaque {};
const EventHotKeyID = extern struct { signature: u32, id: u32 };
const EventTypeSpec = extern struct { eventClass: u32, eventKind: u32 };
const EventHandlerProc = *const fn (call: EventHandlerCallRef, event: EventRef, user: ?*anyopaque) callconv(.c) OSStatus;

extern "c" fn GetApplicationEventTarget() EventTargetRef;
extern "c" fn InstallEventHandler(target: EventTargetRef, handler: EventHandlerProc, num_types: c_ulong, types: [*]const EventTypeSpec, user: ?*anyopaque, out_ref: *?EventHandlerRef) OSStatus;
extern "c" fn RemoveEventHandler(ref: EventHandlerRef) OSStatus;
extern "c" fn RegisterEventHotKey(key_code: u32, modifiers: u32, id: EventHotKeyID, target: EventTargetRef, options: u32, out_ref: *?EventHotKeyRef) OSStatus;
extern "c" fn UnregisterEventHotKey(ref: EventHotKeyRef) OSStatus;
extern "c" fn GetEventParameter(event: EventRef, name: u32, desired_type: u32, actual_type: ?*u32, size: c_ulong, actual_size: ?*c_ulong, data: *anyopaque) OSStatus;

fn fourCC(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .big);
}

const kEventClassKeyboard = fourCC("keyb");
const kEventHotKeyPressed: u32 = 5;
const kEventParamDirectObject = fourCC("----");
const typeEventHotKeyID = fourCC("hkid");
const signature = fourCC("oriL");
const cmdKey: u32 = 0x0100;
const shiftKey: u32 = 0x0200;
const optionKey: u32 = 0x0800;
const controlKey: u32 = 0x1000;
const eventHotKeyExistsErr: OSStatus = -9878;
const noErr: OSStatus = 0;

// --- State --------------------------------------------------------------------------

pub const Registered = struct {
    num: u32,
    shortcut: Shortcut,
    callback: Callback,
    ref: ?EventHotKeyRef,
};

var shortcuts: std.ArrayList(Registered) = .empty;
var mutex: c.pthread_mutex_t = .{};
var next_num: u32 = 1;
var handler_ref: ?EventHandlerRef = null; // main thread only

fn lock() void {
    _ = c.pthread_mutex_lock(&mutex);
}

fn unlock() void {
    _ = c.pthread_mutex_unlock(&mutex);
}

/// Carbon event handler (main thread).
fn onHotKey(_: EventHandlerCallRef, event: EventRef, _: ?*anyopaque) callconv(.c) OSStatus {
    var hk: EventHotKeyID = undefined;
    if (GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, null, @sizeOf(EventHotKeyID), null, &hk) != noErr) return noErr;
    if (hk.signature != signature) return noErr;
    var cb: ?Callback = null;
    var id: []const u8 = "";
    lock();
    for (shortcuts.items) |entry| {
        if (entry.num == hk.id) {
            cb = entry.callback;
            id = entry.shortcut.id;
            break;
        }
    }
    unlock();
    // Outside the lock: a callback may register or unregister shortcuts.
    if (cb) |callback| callback(id);
    return noErr;
}

/// Carbon modifier mask for a parsed trigger.
pub fn carbonModifiers(m: Modifiers) u32 {
    var mods: u32 = 0;
    if (m.ctrl) mods |= controlKey;
    if (m.alt) mods |= optionKey;
    if (m.shift) mods |= shiftKey;
    if (m.super) mods |= cmdKey;
    return mods;
}

const RegisterCtx = struct {
    gpa: std.mem.Allocator,
    shortcut: Shortcut,
    callback: Callback,
    result: anyerror!void = {},
};

fn registerMain(ctx: *RegisterCtx) void {
    ctx.result = registerDirect(ctx.gpa, ctx.shortcut, ctx.callback);
}

fn registerDirect(gpa: std.mem.Allocator, shortcut: Shortcut, callback: Callback) !void {
    const parsed = try parseTrigger(shortcut.trigger);
    const key = vkFor(parsed.key) orelse return error.UnknownKey;
    const code = keycodes.fromVk(key) orelse return error.UnknownKey;

    if (handler_ref == null) {
        const types = [_]EventTypeSpec{.{ .eventClass = kEventClassKeyboard, .eventKind = kEventHotKeyPressed }};
        if (InstallEventHandler(GetApplicationEventTarget(), &onHotKey, types.len, &types, null, &handler_ref) != noErr) return error.InstallEventHandlerFailed;
    }

    lock();
    const num = next_num;
    next_num += 1;
    unlock();

    var ref: ?EventHotKeyRef = null;
    switch (RegisterEventHotKey(code, carbonModifiers(parsed.modifiers), .{ .signature = signature, .id = num }, GetApplicationEventTarget(), 0, &ref)) {
        noErr => {},
        eventHotKeyExistsErr => return error.HotkeyAlreadyRegistered,
        else => return error.RegisterHotKeyFailed,
    }
    errdefer _ = UnregisterEventHotKey(ref.?);

    lock();
    defer unlock();
    try shortcuts.append(gpa, .{ .num = num, .shortcut = shortcut, .callback = callback, .ref = ref });
}

/// Register a system-wide shortcut. `shortcut` must outlive the
/// registration (its id is passed to the callback).
pub fn register(gpa: std.mem.Allocator, shortcut: Shortcut, callback: Callback) !void {
    var ctx: RegisterCtx = .{ .gpa = gpa, .shortcut = shortcut, .callback = callback };
    try ShellMod.runOnMainThread(RegisterCtx, &ctx, registerMain);
    return ctx.result;
}

const UnregisterCtx = struct { id: []const u8, result: bool = false };

fn unregisterMain(ctx: *UnregisterCtx) void {
    lock();
    defer unlock();
    for (shortcuts.items, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.shortcut.id, ctx.id)) {
            if (entry.ref) |r| _ = UnregisterEventHotKey(r); // removed from the table either way
            _ = shortcuts.swapRemove(i);
            ctx.result = true;
            return;
        }
    }
}

pub fn unregister(id: []const u8) bool {
    var ctx: UnregisterCtx = .{ .id = id };
    ShellMod.runOnMainThread(UnregisterCtx, &ctx, unregisterMain) catch return false;
    return ctx.result;
}

/// Run the callback of shortcut `id` as if it had been pressed.
pub fn trigger(id: []const u8) bool {
    var cb: ?Callback = null;
    lock();
    for (shortcuts.items) |entry| {
        if (std.mem.eql(u8, entry.shortcut.id, id)) {
            cb = entry.callback;
            break;
        }
    }
    unlock();
    // Outside the lock, so callbacks can call register/unregister/trigger.
    if (cb) |callback| {
        callback(id);
        return true;
    }
    return false;
}

/// Carbon calls go to the main thread while the app runs, like
/// register/unregister; before it starts or after it stopped they run here.
pub fn deinit(gpa: std.mem.Allocator) void {
    var ctx: DeinitCtx = .{ .gpa = gpa };
    ShellMod.runOnMainThread(DeinitCtx, &ctx, deinitMain) catch deinitMain(&ctx);
}

const DeinitCtx = struct { gpa: std.mem.Allocator };

fn deinitMain(ctx: *DeinitCtx) void {
    const gpa = ctx.gpa;
    lock();
    defer unlock();
    for (shortcuts.items) |entry| if (entry.ref) |r| {
        _ = UnregisterEventHotKey(r); // teardown: nothing to recover
    };
    shortcuts.deinit(gpa);
    shortcuts = .empty;
    if (handler_ref) |h| _ = RemoveEventHandler(h);
    handler_ref = null;
}

/// Registers (then removes) an unusual combination: proves Carbon accepts
/// hot keys from this process, with no permission prompt.
pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    const parsed = try parseTrigger("ctrl+alt+shift+cmd+F19");
    const code = keycodes.fromVk(vkFor(parsed.key).?).?;
    var ref: ?EventHotKeyRef = null;
    const status = RegisterEventHotKey(code, carbonModifiers(parsed.modifiers), .{ .signature = signature, .id = 0xFFFF_0000 }, GetApplicationEventTarget(), 0, &ref);
    if (status == noErr) _ = UnregisterEventHotKey(ref.?);
    return .{
        .module = "global_shortcut",
        .ok = status == noErr,
        .detail = try std.fmt.allocPrint(gpa, "Carbon RegisterEventHotKey(⌃⌥⇧⌘F19): {s}", .{if (status == noErr) "registered and removed" else "failed"}),
    };
}

test carbonModifiers {
    const p = try parseTrigger("CTRL+ALT+G");
    try std.testing.expectEqual(controlKey | optionKey, carbonModifiers(p.modifiers));
    try std.testing.expectEqual(cmdKey | shiftKey, carbonModifiers((try parseTrigger("cmd+shift+space")).modifiers));
    try std.testing.expectEqual(@as(?u16, 0x05), keycodes.fromVk(vkFor(p.key).?));
}

test "trigger runs the callback outside the lock" {
    const H = struct {
        var hits: u32 = 0;
        fn cb(id: []const u8) void {
            hits += 1;
            if (std.mem.eql(u8, id, "first")) _ = trigger("second"); // re-entrant
        }
    };
    try shortcuts.append(std.testing.allocator, .{ .num = 1001, .shortcut = .{ .id = "first", .trigger = "ctrl+1" }, .callback = &H.cb, .ref = null });
    try shortcuts.append(std.testing.allocator, .{ .num = 1002, .shortcut = .{ .id = "second", .trigger = "ctrl+2" }, .callback = &H.cb, .ref = null });
    defer {
        shortcuts.deinit(std.testing.allocator);
        shortcuts = .empty;
    }
    try std.testing.expect(trigger("first"));
    try std.testing.expectEqual(@as(u32, 2), H.hits);
    try std.testing.expect(!trigger("missing"));
}

test {
    std.testing.refAllDecls(@This());
}
