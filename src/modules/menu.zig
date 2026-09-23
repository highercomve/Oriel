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

pub const MenuItem = union(enum) {
    item: struct {
        id: []const u8,
        label: []const u8,
        enabled: bool = true,
        shortcut: ?[]const u8 = null,
    },
    check: struct {
        id: []const u8,
        label: []const u8,
        checked: bool = false,
        enabled: bool = true,
    },
    separator,
    submenu: struct {
        label: []const u8,
        items: []const MenuItem,
        enabled: bool = true,
    },
};

pub const ActionCallback = *const fn (id: []const u8, checked: ?bool) void;

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

pub fn buildMenu(gpa: std.mem.Allocator, app: *gtk.Application, items: []const MenuItem, on_action: ActionCallback) !*gio.Menu {
    const menu = gio.Menu.new();
    for (items) |item| {
        switch (item) {
            .item => |it| {
                const action_name = try std.fmt.allocPrintSentinel(gpa, "act_{s}", .{it.id}, 0);
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
                    const sc_z = try gpa.dupeZ(u8, sc);
                    const accels = [_]?[*:0]const u8{ sc_z.ptr, null };
                    gtk.Application.setAccelsForAction(app, detailed_action, @ptrCast(&accels));
                }

                menu.append(label_z, detailed_action);
            },
            .check => |chk| {
                const action_name = try std.fmt.allocPrintSentinel(gpa, "act_{s}", .{chk.id}, 0);
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

pub fn check(_: std.mem.Allocator, _: anytype) !@import("../oriel.zig").Check {
    return .{
        .module = "menu",
        .ok = true,
        .detail = "GMenuModel + GtkApplication actions available",
    };
}
