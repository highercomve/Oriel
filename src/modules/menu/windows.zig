//! Windows native application menu bar (Win32 HMENU + ACCEL).

const std = @import("std");
const win32 = @import("../../platform/windows/win32.zig");
const ShellMod = @import("../../platform/windows/Shell.zig");
const App = @import("../../core/App.zig");
const common = @import("common.zig");

pub const MenuItem = common.MenuItem;
pub const ActionCallback = common.ActionCallback;

const Node = struct {
    kind: enum { root, item, check, separator, submenu },
    key: []const u8 = "",
    enabled: bool = true,
    checked: bool = false,
};

var menu_arena: ?std.heap.ArenaAllocator = null;
var nodes: std.ArrayList(Node) = .empty;
var saved_items: []const MenuItem = &.{};
var current_callback: ?ActionCallback = null;

fn cloneMenuItems(allocator: std.mem.Allocator, items: []const MenuItem) ![]const MenuItem {
    const copy = try allocator.alloc(MenuItem, items.len);
    for (items, copy) |item, *dst| {
        dst.* = switch (item) {
            .separator => .separator,
            .item => |it| .{
                .item = .{
                    .id = try allocator.dupe(u8, it.id),
                    .label = try allocator.dupe(u8, it.label),
                    .enabled = it.enabled,
                    .shortcut = if (it.shortcut) |sc| try allocator.dupe(u8, sc) else null,
                },
            },
            .check => |chk| .{
                .check = .{
                    .id = try allocator.dupe(u8, chk.id),
                    .label = try allocator.dupe(u8, chk.label),
                    .checked = chk.checked,
                    .enabled = chk.enabled,
                },
            },
            .submenu => |sub| .{
                .submenu = .{
                    .label = try allocator.dupe(u8, sub.label),
                    .items = try cloneMenuItems(allocator, sub.items),
                    .enabled = sub.enabled,
                },
            },
        };
    }
    return copy;
}

fn buildMenuTree(
    allocator: std.mem.Allocator,
    items: []const MenuItem,
    nodes_out: *std.ArrayList(Node),
    accels_out: ?*std.ArrayList(win32.ACCEL),
    existing_nodes: ?[]const Node,
    is_root: bool,
) !win32.HMENU {
    const hmenu = if (is_root)
        (win32.CreateMenu() orelse return error.CreateMenuFailed)
    else
        (win32.CreatePopupMenu() orelse return error.CreatePopupMenuFailed);
    errdefer _ = win32.DestroyMenu(hmenu);

    for (items) |item| {
        switch (item) {
            .separator => {
                if (win32.AppendMenuW(hmenu, win32.MF_SEPARATOR, 0, null) == win32.FALSE) {
                    return error.AppendMenuFailed;
                }
            },
            .submenu => |sub| {
                const label_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, sub.label);
                defer allocator.free(label_w);

                const sub_hmenu = try buildMenuTree(allocator, sub.items, nodes_out, accels_out, existing_nodes, false);

                var flags: win32.UINT = win32.MF_POPUP;
                if (!sub.enabled) flags |= win32.MF_GRAYED;
                if (win32.AppendMenuW(hmenu, flags, @intFromPtr(sub_hmenu), label_w.ptr) == win32.FALSE) {
                    _ = win32.DestroyMenu(sub_hmenu);
                    return error.AppendMenuFailed;
                }
            },
            .item => |it| {
                const node_id = nodes_out.items.len;
                try nodes_out.append(allocator, .{
                    .kind = .item,
                    .key = try allocator.dupe(u8, it.id),
                    .enabled = it.enabled,
                });

                if (it.shortcut) |sc| {
                    if (accels_out) |acc| {
                        if (common.parseShortcut(sc)) |parsed| {
                            try acc.append(allocator, .{
                                .fVirt = parsed.flags,
                                .key = parsed.key,
                                .cmd = @intCast(node_id),
                            });
                        } else |err| {
                            std.log.warn("failed to parse menu shortcut '{s}': {s}", .{ sc, @errorName(err) });
                        }
                    }
                }

                const formatted_label = try common.formatMenuLabel(allocator, it.label, it.shortcut);
                defer allocator.free(formatted_label);
                const label_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, formatted_label);
                defer allocator.free(label_w);

                var flags: win32.UINT = win32.MF_STRING;
                if (!it.enabled) flags |= win32.MF_GRAYED;
                if (win32.AppendMenuW(hmenu, flags, node_id, label_w.ptr) == win32.FALSE) {
                    return error.AppendMenuFailed;
                }
            },
            .check => |chk| {
                const node_id = nodes_out.items.len;
                const is_checked = if (existing_nodes) |en|
                    (if (node_id < en.len and en[node_id].kind == .check) en[node_id].checked else chk.checked)
                else
                    chk.checked;

                try nodes_out.append(allocator, .{
                    .kind = .check,
                    .key = try allocator.dupe(u8, chk.id),
                    .enabled = chk.enabled,
                    .checked = is_checked,
                });

                const label_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, chk.label);
                defer allocator.free(label_w);

                var flags: win32.UINT = win32.MF_STRING;
                if (!chk.enabled) flags |= win32.MF_GRAYED;
                if (is_checked) flags |= win32.MF_CHECKED;
                if (win32.AppendMenuW(hmenu, flags, node_id, label_w.ptr) == win32.FALSE) {
                    return error.AppendMenuFailed;
                }
            },
        }
    }

    return hmenu;
}

pub fn attachMenuToWindow(hwnd: win32.HWND) void {
    if (saved_items.len == 0) return;

    var temp_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer temp_arena.deinit();
    const a = temp_arena.allocator();

    var dummy_nodes: std.ArrayList(Node) = .empty;
    dummy_nodes.append(a, .{ .kind = .root }) catch return;

    const new_hmenu = buildMenuTree(a, saved_items, &dummy_nodes, null, nodes.items, true) catch return;

    const old_menu = win32.GetMenu(hwnd);
    _ = win32.SetMenu(hwnd, new_hmenu);
    _ = win32.DrawMenuBar(hwnd);
    if (old_menu) |m| {
        _ = win32.DestroyMenu(m);
    }
}

fn handleMenuCommand(cmd_id: usize) void {
    if (cmd_id == 0 or cmd_id >= nodes.items.len) return;
    const node = &nodes.items[cmd_id];
    if (!node.enabled) return;

    if (node.kind == .check) {
        node.checked = !node.checked;
        App.ensureWindowsMutex();
        App.windows_mutex.lock();
        defer App.windows_mutex.unlock();
        for (App.windows_list.items) |win| {
            if (win32.GetMenu(win.handle.hwnd)) |hm| {
                _ = win32.CheckMenuItem(hm, @intCast(cmd_id), if (node.checked) win32.MF_CHECKED else win32.MF_UNCHECKED);
            }
        }
    }

    if (current_callback) |cb| {
        var key_buf: [256]u8 = undefined;
        const copy_len = @min(node.key.len, key_buf.len);
        @memcpy(key_buf[0..copy_len], node.key[0..copy_len]);
        cb(key_buf[0..copy_len], if (node.kind == .check) node.checked else null);
    }
}

const SetMenuParams = struct {
    items: []const MenuItem,
    on_action: ActionCallback,
    err: ?anyerror = null,
};

fn runSetMenuAction(params: *SetMenuParams) void {
    setMenuDirect(params.items, params.on_action) catch |err| {
        params.err = err;
    };
}

fn setMenuDirect(items: []const MenuItem, on_action: ActionCallback) !void {
    var new_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    errdefer new_arena.deinit();
    const a = new_arena.allocator();

    var new_nodes: std.ArrayList(Node) = .empty;
    try new_nodes.append(a, .{ .kind = .root }); // node 0 is dummy root

    var new_accels: std.ArrayList(win32.ACCEL) = .empty;

    const new_saved_items = try cloneMenuItems(a, items);

    // Build the nodes tree and accelerators with existing_nodes = null
    const dummy_hmenu = try buildMenuTree(a, new_saved_items, &new_nodes, &new_accels, null, true);
    _ = win32.DestroyMenu(dummy_hmenu);

    var new_haccel: ?win32.HACCEL = null;
    if (new_accels.items.len > 0) {
        new_haccel = win32.CreateAcceleratorTableW(new_accels.items.ptr, @intCast(new_accels.items.len));
        if (new_haccel == null) return error.CreateAcceleratorTableFailed;
    }
    errdefer if (new_haccel) |h| {
        _ = win32.DestroyAcceleratorTable(h);
    };

    // All allocations succeeded, now swap in the new state and free old state
    const old_haccel = ShellMod.current_haccel;
    const old_arena = menu_arena;

    ShellMod.current_haccel = new_haccel;
    ShellMod.on_menu_command_fn = &handleMenuCommand;
    ShellMod.on_window_created_fn = &attachMenuToWindow;

    menu_arena = new_arena;
    nodes = new_nodes;
    saved_items = new_saved_items;
    current_callback = on_action;

    if (old_haccel) |h| {
        _ = win32.DestroyAcceleratorTable(h);
    }
    if (old_arena) |mut_arena| {
        var arena_copy = mut_arena;
        arena_copy.deinit();
    }

    // Attach menu to all currently open windows
    App.ensureWindowsMutex();
    App.windows_mutex.lock();
    defer App.windows_mutex.unlock();
    for (App.windows_list.items) |win| {
        attachMenuToWindow(win.handle.hwnd);
    }
}

pub fn setMenu(items: []const MenuItem, on_action: ActionCallback) !void {
    var params = SetMenuParams{
        .items = items,
        .on_action = on_action,
    };
    try ShellMod.runOnMainThread(SetMenuParams, &params, runSetMenuAction);
    if (params.err) |err| return err;
}

pub fn set(items: []const MenuItem, on_action: ActionCallback) !void {
    return setMenu(items, on_action);
}

pub fn check(_: std.mem.Allocator, _: anytype) !@import("../../oriel.zig").Check {
    const hmenu = win32.CreateMenu() orelse return error.CreateMenuFailed;
    defer _ = win32.DestroyMenu(hmenu);
    const hsub = win32.CreatePopupMenu() orelse return error.CreatePopupMenuFailed;
    _ = win32.AppendMenuW(hmenu, win32.MF_POPUP, @intFromPtr(hsub), std.unicode.utf8ToUtf16LeStringLiteral("Test"));
    var accels = [_]win32.ACCEL{
        .{ .fVirt = win32.FVIRTKEY | win32.FCONTROL, .key = 'N', .cmd = 1 },
    };
    const haccel = win32.CreateAcceleratorTableW(&accels, accels.len) orelse return error.CreateAcceleratorTableFailed;
    _ = win32.DestroyAcceleratorTable(haccel);
    return .{
        .module = "menu",
        .ok = true,
        .detail = "Win32 HMENU + HACCEL available",
    };
}

test {
    std.testing.refAllDecls(@This());
}
