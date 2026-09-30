//! Application menu bar (GTK4 GMenuModel + GActionMap).
//!
//! Provides native application menu bars attached to `GtkApplication` and windows,
//! supporting the same `MenuItem` shape as the system tray.
//!
//! Example:
//!     try oriel.menu.set(app, &.{
//!         .{ .submenu = .{
//!             .label = "File",
//!             .items = &.{
//!                 .{ .item = .{ .id = "new", .label = "New", .shortcut = "<Ctrl>N" } },
//!                 .separator,
//!                 .{ .item = .{ .id = "quit", .label = "Quit", .shortcut = "<Ctrl>Q" } },
//!             },
//!         }},
//!     }, onMenuAction);

const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");
const gio = @import("gio");
const gtk = @import("gtk");
const common = @import("common.zig");

pub const MenuItem = common.MenuItem;
pub const ActionCallback = common.ActionCallback;

const ActionData = struct {
    id: [:0]const u8,
    is_check: bool,
    on_action: ActionCallback,
};

fn onActionActivate(_: *gio.SimpleAction, _: ?*glib.Variant, data: ?*anyopaque) callconv(.c) void {
    const act: *ActionData = @ptrCast(@alignCast(data));
    act.on_action(act.id, null);
}

fn onActionChangeState(action: *gio.SimpleAction, value: ?*glib.Variant, data: ?*anyopaque) callconv(.c) void {
    const act: *ActionData = @ptrCast(@alignCast(data));
    if (value) |v| {
        action.setState(v);
        const checked = v.getBoolean() != 0;
        act.on_action(act.id, checked);
    }
}

/// A GAction name for a menu id: GLib allows only letters, digits, '-' and
/// '.', so anything else (e.g. the ':' in "tab:files", which made GTK
/// abort) is written as "_XX" (hex); '_' is escaped too, so names stay
/// unique. The callback still gets the original id.
fn actionName(gpa: std.mem.Allocator, id: []const u8) ![:0]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "act_");
    for (id) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '.') {
            try out.append(gpa, ch);
        } else {
            try out.print(gpa, "_{X:0>2}", .{ch});
        }
    }
    return out.toOwnedSliceSentinel(gpa, 0);
}

/// "Ctrl+Shift+D" (the syntax the other backends take) as GTK's
/// "<Control><Shift>d"; a GTK accelerator ("<Control>q") passes as is.
fn gtkAccelerator(gpa: std.mem.Allocator, shortcut: []const u8) ![:0]u8 {
    if (std.mem.startsWith(u8, shortcut, "<")) return gpa.dupeZ(u8, shortcut);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var parts = std.mem.splitScalar(u8, shortcut, '+');
    var key: []const u8 = "";
    while (parts.next()) |raw| {
        const part = std.mem.trim(u8, raw, " ");
        if (part.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(part, "ctrl") or std.ascii.eqlIgnoreCase(part, "control") or std.ascii.eqlIgnoreCase(part, "cmdorctrl")) {
            try out.appendSlice(gpa, "<Control>");
        } else if (std.ascii.eqlIgnoreCase(part, "shift")) {
            try out.appendSlice(gpa, "<Shift>");
        } else if (std.ascii.eqlIgnoreCase(part, "alt") or std.ascii.eqlIgnoreCase(part, "option")) {
            try out.appendSlice(gpa, "<Alt>");
        } else if (std.ascii.eqlIgnoreCase(part, "super") or std.ascii.eqlIgnoreCase(part, "meta") or std.ascii.eqlIgnoreCase(part, "cmd") or std.ascii.eqlIgnoreCase(part, "win")) {
            try out.appendSlice(gpa, "<Super>");
        } else key = part;
    }
    // Letters are lowercase key names in GTK (Shift is its own modifier).
    if (key.len == 1) try out.append(gpa, std.ascii.toLower(key[0])) else try out.appendSlice(gpa, key);
    return out.toOwnedSliceSentinel(gpa, 0);
}

test actionName {
    const gpa = std.testing.allocator;
    const a = try actionName(gpa, "tab:files");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("act_tab_3Afiles", a);
    const b = try actionName(gpa, "quit");
    defer gpa.free(b);
    try std.testing.expectEqualStrings("act_quit", b);
}

test gtkAccelerator {
    const gpa = std.testing.allocator;
    const a = try gtkAccelerator(gpa, "Ctrl+Shift+D");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("<Control><Shift>d", a);
    const b = try gtkAccelerator(gpa, "Ctrl+1");
    defer gpa.free(b);
    try std.testing.expectEqualStrings("<Control>1", b);
    const c = try gtkAccelerator(gpa, "<Control>q");
    defer gpa.free(c);
    try std.testing.expectEqualStrings("<Control>q", c);
}

pub fn buildMenu(gpa: std.mem.Allocator, app: *gtk.Application, items: []const MenuItem, on_action: ActionCallback) !*gio.Menu {
    const menu = gio.Menu.new();
    for (items) |item| {
        switch (item) {
            .item => |it| {
                const action_name = try actionName(gpa, it.id);
                const detailed_action = try std.fmt.allocPrintSentinel(gpa, "app.{s}", .{action_name}, 0);
                const label_z = try gpa.dupeZ(u8, it.label);

                const action = gio.SimpleAction.new(action_name, null);
                action.setEnabled(@intFromBool(it.enabled));

                const act_data = try gpa.create(ActionData);
                act_data.* = .{
                    .id = try gpa.dupeZ(u8, it.id),
                    .is_check = false,
                    .on_action = on_action,
                };
                _ = gio.SimpleAction.signals.activate.connect(action, ?*anyopaque, &onActionActivate, act_data, .{});

                gio.ActionMap.addAction(app.as(gio.ActionMap), action.as(gio.Action));

                if (it.shortcut) |sc| {
                    const sc_z = try gtkAccelerator(gpa, sc);
                    const accels = [_]?[*:0]const u8{ sc_z.ptr, null };
                    gtk.Application.setAccelsForAction(app, detailed_action, @ptrCast(&accels));
                }

                menu.append(label_z, detailed_action);
            },
            .check => |chk| {
                const action_name = try actionName(gpa, chk.id);
                const detailed_action = try std.fmt.allocPrintSentinel(gpa, "app.{s}", .{action_name}, 0);
                const label_z = try gpa.dupeZ(u8, chk.label);

                const init_state = glib.Variant.newBoolean(@intFromBool(chk.checked));
                const action = gio.SimpleAction.newStateful(action_name, null, init_state);
                action.setEnabled(@intFromBool(chk.enabled));

                const act_data = try gpa.create(ActionData);
                act_data.* = .{
                    .id = try gpa.dupeZ(u8, chk.id),
                    .is_check = true,
                    .on_action = on_action,
                };
                _ = gio.SimpleAction.signals.change_state.connect(action, ?*anyopaque, &onActionChangeState, act_data, .{});

                gio.ActionMap.addAction(app.as(gio.ActionMap), action.as(gio.Action));

                menu.append(label_z, detailed_action);
            },
            .separator => {
                const section = gio.Menu.new();
                menu.appendSection(null, section.as(gio.MenuModel));
            },
            .submenu => |sub| {
                const sub_menu = try buildMenu(gpa, app, sub.items, on_action);
                const label_z = try gpa.dupeZ(u8, sub.label);
                menu.appendSubmenu(label_z, sub_menu.as(gio.MenuModel));
            },
        }
    }
    return menu;
}

/// Set the application menubar.
pub fn set(app: *gtk.Application, items: []const MenuItem, on_action: ActionCallback) !void {
    const root_menu = try buildMenu(std.heap.smp_allocator, app, items, on_action);
    gtk.Application.setMenubar(app, root_menu.as(gio.MenuModel));
}

pub fn check(_: std.mem.Allocator, _: anytype) !@import("../../oriel.zig").Check {
    return .{
        .module = "menu",
        .ok = true,
        .detail = "GMenuModel + GtkApplication actions available",
    };
}
