//! Native file dialogs via GtkFileDialog.

const std = @import("std");
const gtk = @import("gtk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");

pub const OpenOptions = common.OpenOptions;
pub const SaveOptions = common.SaveOptions;

pub fn openFile(gpa: std.mem.Allocator, options: OpenOptions) !?[]u8 {
    _ = gtk.initCheck();
    const dialog = gtk.FileDialog.new();
    defer dialog.unref();

    var title_buf: [256]u8 = undefined;
    const title_z = try std.fmt.bufPrintSentinel(&title_buf, "{s}", .{options.title}, 0);
    dialog.setTitle(title_z.ptr);
    dialog.setModal(@intFromBool(options.modal));

    const parent = if (oriel.App.main_window) |w| @as(?*gtk.Window, @ptrCast(w)) else null;

    const State = struct {
        loop: *glib.MainLoop,
        result: ?[]u8 = null,
        gpa: std.mem.Allocator,
    };
    const S = struct {
        fn onOpenFinish(source_object: ?*gobject.Object, res: *gio.AsyncResult, user_data: ?*anyopaque) callconv(.c) void {
            const state: *State = @ptrCast(@alignCast(user_data));
            const d: *gtk.FileDialog = @ptrCast(@alignCast(source_object));
            var err: ?*glib.Error = null;
            const file = gtk.FileDialog.openFinish(d, res, &err);
            if (file) |f| {
                defer f.unref();
                if (f.getPath()) |path_z| {
                    state.result = state.gpa.dupe(u8, std.mem.span(path_z)) catch null;
                    glib.free(path_z);
                }
            } else {
                if (err) |e| e.free();
            }
            state.loop.quit();
        }
    };

    const loop = glib.MainLoop.new(null, 0);
    defer loop.unref();

    var state = State{ .loop = loop, .gpa = gpa };
    dialog.open(parent, null, &S.onOpenFinish, &state);
    loop.run();

    return state.result;
}

pub fn saveFile(gpa: std.mem.Allocator, options: SaveOptions) !?[]u8 {
    _ = gtk.initCheck();
    const dialog = gtk.FileDialog.new();
    defer dialog.unref();

    var title_buf: [256]u8 = undefined;
    const title_z = try std.fmt.bufPrintSentinel(&title_buf, "{s}", .{options.title}, 0);
    dialog.setTitle(title_z.ptr);
    dialog.setModal(@intFromBool(options.modal));

    const parent = if (oriel.App.main_window) |w| @as(?*gtk.Window, @ptrCast(w)) else null;

    const State = struct {
        loop: *glib.MainLoop,
        result: ?[]u8 = null,
        gpa: std.mem.Allocator,
    };
    const S = struct {
        fn onSaveFinish(source_object: ?*gobject.Object, res: *gio.AsyncResult, user_data: ?*anyopaque) callconv(.c) void {
            const state: *State = @ptrCast(@alignCast(user_data));
            const d: *gtk.FileDialog = @ptrCast(@alignCast(source_object));
            var err: ?*glib.Error = null;
            const file = gtk.FileDialog.saveFinish(d, res, &err);
            if (file) |f| {
                defer f.unref();
                if (f.getPath()) |path_z| {
                    state.result = state.gpa.dupe(u8, std.mem.span(path_z)) catch null;
                    glib.free(path_z);
                }
            } else {
                if (err) |e| e.free();
            }
            state.loop.quit();
        }
    };

    const loop = glib.MainLoop.new(null, 0);
    defer loop.unref();

    var state = State{ .loop = loop, .gpa = gpa };
    dialog.save(parent, null, &S.onSaveFinish, &state);
    loop.run();

    return state.result;
}

pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    const dialog = gtk.FileDialog.new();
    defer dialog.unref();
    dialog.setTitle("oriel check");
    return .{
        .module = "dialog",
        .ok = true,
        .detail = try std.fmt.allocPrint(gpa, "GtkFileDialog available", .{}),
    };
}

test "dialog creation" {
    const dialog = gtk.FileDialog.new();
    defer dialog.unref();
    dialog.setTitle("test title");
}
