//! macOS application menu bar (NSMenu).
//!
//! `set` installs a new main menu: the default App menu (Hide, Quit) first,
//! then the app's items, then the default Edit and Window menus unless the
//! app has top-level submenus with those names. Shortcuts use the shared
//! GTK-style syntax (`<Ctrl>N`); on macOS `Ctrl`/`Primary` become ⌘, `Alt`
//! ⌥ and `Shift` ⇧, as Mac users expect. Clicks call `on_action` on the main
//! thread; check items toggle before the callback gets the new state.

const std = @import("std");
const cocoa = @import("../../platform/macos/cocoa.zig");
const ShellMod = @import("../../platform/macos/Shell.zig");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");

const Object = cocoa.Object;

pub const MenuItem = common.MenuItem;
pub const ActionCallback = common.ActionCallback;

// NSEventModifierFlags
const mod_shift: c_ulong = 1 << 17;
const mod_option: c_ulong = 1 << 19;
const mod_command: c_ulong = 1 << 20;
const NSControlStateValueOn: isize = 1;
const NSControlStateValueOff: isize = 0;

/// Key equivalent for an NSMenuItem: the character (lowercase for letters)
/// and the modifier mask.
pub const KeyEquivalent = struct { char: u21, modifiers: c_ulong };

/// Map a parsed shortcut to an AppKit key equivalent.
pub fn keyEquivalent(accel: common.ParsedAccelerator) ?KeyEquivalent {
    var mods: c_ulong = 0;
    if (accel.flags & common.FCONTROL != 0) mods |= mod_command;
    if (accel.flags & common.FSHIFT != 0) mods |= mod_shift;
    if (accel.flags & common.FALT != 0) mods |= mod_option;
    const k = accel.key;
    const char: u21 = switch (k) {
        'A'...'Z' => k + ('a' - 'A'),
        '0'...'9' => k,
        common.VK_F1...common.VK_F1 + 11 => 0xF704 + (k - common.VK_F1), // NSF1FunctionKey
        common.VK_F13...common.VK_F24 => 0xF704 + 12 + (k - common.VK_F13),
        common.VK_RETURN => '\r',
        common.VK_TAB => '\t',
        common.VK_ESCAPE => 0x1b,
        common.VK_SPACE => ' ',
        common.VK_BACK => 0x08,
        common.VK_DELETE => 0xF728, // NSDeleteFunctionKey (forward delete)
        common.VK_INSERT => 0xF727,
        common.VK_HOME => 0xF729,
        common.VK_END => 0xF72B,
        common.VK_PRIOR => 0xF72C,
        common.VK_NEXT => 0xF72D,
        common.VK_UP => 0xF700,
        common.VK_DOWN => 0xF701,
        common.VK_LEFT => 0xF702,
        common.VK_RIGHT => 0xF703,
        else => return null,
    };
    return .{ .char = char, .modifiers = mods };
}

// --- State (main thread only) -------------------------------------------------

/// Item ids by NSMenuItem tag (index), for the menu currently installed.
var ids: std.ArrayList([]const u8) = .empty;
var ids_arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
var callback: ?ActionCallback = null;
/// The shared action target (+1 for the process lifetime).
var target: Object = cocoa.nil;

fn menuAction(_: cocoa.id, _: cocoa.c.SEL, sender_id: cocoa.id) callconv(.c) void {
    const sender: Object = .{ .value = sender_id };
    const tag = sender.msgSend(isize, "tag", .{});
    if (tag < 0 or tag >= ids.items.len) return;
    const id = ids.items[@intCast(tag)];
    const is_check = sender.msgSend(Object, "representedObject", .{}).value != null; // marker set for check items
    var checked: ?bool = null;
    if (is_check) {
        const now_on = sender.msgSend(isize, "state", .{}) != NSControlStateValueOn;
        sender.msgSend(void, "setState:", .{if (now_on) NSControlStateValueOn else NSControlStateValueOff});
        checked = now_on;
    }
    if (callback) |cb| cb(id, checked);
}

fn ensureTarget() void {
    if (target.value != null) return;
    const cls = cocoa.defineClass("OrielMenuTarget", &.{}, .{
        .{ "menuAction:", menuAction },
    });
    target = cocoa.new(cls);
}

// --- Building -------------------------------------------------------------------

fn nsItem(title: []const u8, action: bool, key: ?KeyEquivalent) !Object {
    const title_ns = cocoa.nsString(title) orelse return error.InvalidUtf8;
    defer title_ns.release();
    var key_buf: [4]u8 = undefined;
    const key_len = if (key) |k| std.unicode.utf8Encode(k.char, &key_buf) catch 0 else 0;
    const key_ns = cocoa.nsString(key_buf[0..key_len]) orelse return error.OutOfMemory;
    defer key_ns.release();
    const sel: cocoa.c.SEL = if (action) cocoa.objc.sel("menuAction:").value else null;
    const item = cocoa.class("NSMenuItem").msgSend(Object, "alloc", .{})
        .msgSend(Object, "initWithTitle:action:keyEquivalent:", .{ title_ns, sel, key_ns });
    if (item.value == null) return error.OutOfMemory;
    if (key) |k| item.msgSend(void, "setKeyEquivalentModifierMask:", .{k.modifiers});
    if (action) item.msgSend(void, "setTarget:", .{target});
    return item;
}

fn addId(id: []const u8) !isize {
    const copy = try ids_arena.allocator().dupe(u8, id);
    try ids.append(std.heap.smp_allocator, copy);
    return @intCast(ids.items.len - 1);
}

/// Append `items` to `menu`.
fn fill(menu: Object, items: []const MenuItem) !void {
    for (items) |entry| {
        const item: Object = switch (entry) {
            .separator => {
                menu.msgSend(void, "addItem:", .{cocoa.class("NSMenuItem").msgSend(Object, "separatorItem", .{})});
                continue;
            },
            .item => |it| blk: {
                const key = if (it.shortcut) |sc| (if (common.parseShortcut(sc)) |a| keyEquivalent(a) else |_| null) else null;
                const obj = try nsItem(it.label, true, key);
                errdefer obj.release();
                obj.msgSend(void, "setTag:", .{try addId(it.id)});
                obj.msgSend(void, "setEnabled:", .{cocoa.boolean(it.enabled)});
                break :blk obj;
            },
            .check => |it| blk: {
                const obj = try nsItem(it.label, true, null);
                errdefer obj.release();
                obj.msgSend(void, "setTag:", .{try addId(it.id)});
                obj.msgSend(void, "setEnabled:", .{cocoa.boolean(it.enabled)});
                obj.msgSend(void, "setState:", .{if (it.checked) NSControlStateValueOn else NSControlStateValueOff});
                // Marks a check item for menuAction (any non-nil object).
                obj.msgSend(void, "setRepresentedObject:", .{target});
                break :blk obj;
            },
            .submenu => |sub| blk: {
                const obj = try nsItem(sub.label, false, null);
                errdefer obj.release();
                const title_ns = cocoa.nsString(sub.label) orelse return error.InvalidUtf8;
                defer title_ns.release();
                const submenu = cocoa.class("NSMenu").msgSend(Object, "alloc", .{}).msgSend(Object, "initWithTitle:", .{title_ns});
                defer submenu.release(); // the item keeps it
                // Items are enabled by their `enabled` flag, not by responder validation.
                submenu.msgSend(void, "setAutoenablesItems:", .{cocoa.boolean(false)});
                try fill(submenu, sub.items);
                obj.msgSend(void, "setSubmenu:", .{submenu});
                obj.msgSend(void, "setEnabled:", .{cocoa.boolean(sub.enabled)});
                break :blk obj;
            },
        };
        menu.msgSend(void, "addItem:", .{item});
        item.release();
    }
}

fn hasTopLevel(items: []const MenuItem, label: []const u8) bool {
    for (items) |entry| switch (entry) {
        .submenu => |s| if (std.mem.eql(u8, s.label, label)) return true,
        else => {},
    };
    return false;
}

const SetParams = struct {
    items: []const MenuItem,
    on_action: ActionCallback,
    err: ?anyerror = null,
};

fn setOnMain(params: *SetParams) void {
    setNow(params.items, params.on_action) catch |err| {
        params.err = err;
    };
}

fn setNow(items: []const MenuItem, on_action: ActionCallback) !void {
    const pool = cocoa.objc.AutoreleasePool.init();
    defer pool.deinit();
    ensureTarget();
    const app = ShellMod.sharedApplication();
    const old_bar = app.msgSend(Object, "mainMenu", .{});

    // New ids replace the old ones only once the new bar is complete.
    const old_ids = ids;
    const old_arena = ids_arena;
    ids = .empty;
    ids_arena = .init(std.heap.smp_allocator);
    var installed = false;
    defer {
        var discard_ids = if (installed) old_ids else ids;
        var discard_arena = if (installed) old_arena else ids_arena;
        if (!installed) {
            ids = old_ids;
            ids_arena = old_arena;
        }
        discard_ids.deinit(std.heap.smp_allocator);
        discard_arena.deinit();
    }

    const bar = cocoa.new(cocoa.class("NSMenu"));
    defer bar.release(); // NSApp keeps it
    const keep = struct {
        fn take(from: Object, into: Object, tag: isize) void {
            if (from.value == null) return;
            const item = from.msgSend(Object, "itemWithTag:", .{tag});
            if (item.value == null) return;
            _ = item.retain();
            defer item.release();
            from.msgSend(void, "removeItem:", .{item}); // an item can be in one menu only
            into.msgSend(void, "addItem:", .{item});
        }
    };
    // Build the app's part first: a failure leaves the old bar untouched.
    const middle = cocoa.new(cocoa.class("NSMenu"));
    defer middle.release();
    try fill(middle, items);

    keep.take(old_bar, bar, ShellMod.app_menu_tag);
    while (middle.msgSend(isize, "numberOfItems", .{}) > 0) {
        const item = middle.msgSend(Object, "itemAtIndex:", .{@as(isize, 0)});
        _ = item.retain();
        defer item.release();
        middle.msgSend(void, "removeItemAtIndex:", .{@as(isize, 0)});
        bar.msgSend(void, "addItem:", .{item});
    }
    if (!hasTopLevel(items, "Edit")) keep.take(old_bar, bar, ShellMod.edit_menu_tag);
    if (!hasTopLevel(items, "Window")) keep.take(old_bar, bar, ShellMod.window_menu_tag);

    app.msgSend(void, "setMainMenu:", .{bar});
    callback = on_action;
    installed = true;
}

/// Install `items` as the app's menu bar (main thread, or marshalled there).
pub fn set(items: []const MenuItem, on_action: ActionCallback) !void {
    var params: SetParams = .{ .items = items, .on_action = on_action };
    try ShellMod.runOnMainThread(SetParams, &params, setOnMain);
    if (params.err) |err| return err;
}

pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    const pool = cocoa.objc.AutoreleasePool.init();
    defer pool.deinit();
    ensureTarget();
    // Build (not install) a menu with a shortcut and a check item.
    const menu = cocoa.new(cocoa.class("NSMenu"));
    defer menu.release();
    const saved_len = ids.items.len;
    defer ids.shrinkRetainingCapacity(saved_len);
    try fill(menu, &.{
        .{ .item = .{ .id = "new", .label = "New", .shortcut = "<Ctrl><Shift>n" } },
        .separator,
        .{ .check = .{ .id = "dnd", .label = "Do not disturb", .checked = true } },
    });
    const first = menu.msgSend(Object, "itemAtIndex:", .{@as(isize, 0)});
    const key = cocoa.utf8(first.msgSend(Object, "keyEquivalent", .{})) orelse "";
    const mods = first.msgSend(c_ulong, "keyEquivalentModifierMask", .{});
    const third = menu.msgSend(Object, "itemAtIndex:", .{@as(isize, 2)});
    const ok = menu.msgSend(isize, "numberOfItems", .{}) == 3 and std.mem.eql(u8, key, "n") and
        mods == mod_command | mod_shift and third.msgSend(isize, "state", .{}) == NSControlStateValueOn;
    return .{
        .module = "menu",
        .ok = ok,
        .detail = try std.fmt.allocPrint(gpa, "NSMenu built: 3 items, New = ⌘⇧{s}, check item on: {}", .{ key, ok }),
    };
}

test keyEquivalent {
    const k = keyEquivalent(try common.parseShortcut("<Ctrl>N")).?;
    try std.testing.expectEqual(@as(u21, 'n'), k.char);
    try std.testing.expectEqual(mod_command, k.modifiers);
    const f5 = keyEquivalent(try common.parseShortcut("<Alt><Shift>F5")).?;
    try std.testing.expectEqual(@as(u21, 0xF708), f5.char);
    try std.testing.expectEqual(mod_option | mod_shift, f5.modifiers);
    try std.testing.expectEqual(@as(u21, 0xF703), keyEquivalent(try common.parseShortcut("Right")).?.char);
    try std.testing.expectEqual(@as(u21, 0xF704 + 12), keyEquivalent(try common.parseShortcut("F13")).?.char);
}

test {
    std.testing.refAllDecls(@This());
}
