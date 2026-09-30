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
    return run(gpa, .open, options.title, options.modal);
}

pub fn saveFile(gpa: std.mem.Allocator, options: SaveOptions) !?[]u8 {
    return run(gpa, .save, options.title, options.modal);
}

const Kind = enum { open, save };

/// One dialog, from show to answer. GTK must only be touched on the thread
/// that runs the GLib main loop: from there it runs a nested loop until the
/// answer; from any other thread (a command on the worker pool) it is
/// started there with `idleAdd` and this thread waits for the answer.
const Call = struct {
    gpa: std.mem.Allocator,
    kind: Kind,
    title: [:0]const u8,
    modal: bool,
    result: ?[]u8 = null,
    /// Main thread: the nested loop to quit.
    loop: ?*glib.MainLoop = null,
    /// Worker: signalled when `done`.
    mutex: glib.Mutex = undefined,
    cond: glib.Cond = undefined,
    done: bool = false,

    fn start(self: *Call) void {
        _ = gtk.initCheck();
        const dialog = gtk.FileDialog.new();
        defer dialog.unref(); // the pending operation holds its own reference
        dialog.setTitle(self.title.ptr);
        dialog.setModal(@intFromBool(self.modal));
        const parent = if (oriel.App.main_window) |w| @as(?*gtk.Window, @ptrCast(w)) else null;
        switch (self.kind) {
            .open => dialog.open(parent, null, &finish, self),
            .save => dialog.save(parent, null, &finish, self),
        }
    }

    fn startIdle(p: ?*anyopaque) callconv(.c) c_int {
        const self: *Call = @ptrCast(@alignCast(p));
        self.start();
        return 0; // G_SOURCE_REMOVE
    }

    fn finish(source_object: ?*gobject.Object, res: *gio.AsyncResult, user_data: ?*anyopaque) callconv(.c) void {
        const self: *Call = @ptrCast(@alignCast(user_data));
        const d: *gtk.FileDialog = @ptrCast(@alignCast(source_object));
        var err: ?*glib.Error = null;
        const file = switch (self.kind) {
            .open => gtk.FileDialog.openFinish(d, res, &err),
            .save => gtk.FileDialog.saveFinish(d, res, &err),
        };
        var result: ?[]u8 = null;
        if (file) |f| {
            defer f.unref();
            if (f.getPath()) |path_z| {
                result = self.gpa.dupe(u8, std.mem.span(path_z)) catch null;
                glib.free(path_z);
            }
        } else if (err) |e| e.free();

        if (self.loop) |loop| {
            self.result = result;
            loop.quit();
            return;
        }
        self.mutex.lock();
        self.result = result;
        self.done = true;
        self.cond.signal();
        self.mutex.unlock();
    }
};

fn run(gpa: std.mem.Allocator, kind: Kind, title: []const u8, modal: bool) !?[]u8 {
    var title_buf: [256]u8 = undefined;
    const title_z = try std.fmt.bufPrintSentinel(&title_buf, "{s}", .{title}, 0);
    var call: Call = .{ .gpa = gpa, .kind = kind, .title = title_z, .modal = modal };

    const context = glib.MainContext.default();
    const owner = context.isOwner() != 0;
    // Not the main thread, but no loop running yet (a script, a test): take
    // the context here.
    const acquired = !owner and oriel.App.main_window == null and context.acquire() != 0;
    if (owner or acquired) {
        defer if (acquired) context.release();
        const loop = glib.MainLoop.new(null, 0);
        defer loop.unref();
        call.loop = loop;
        call.start();
        loop.run();
        return call.result;
    }

    call.mutex.init();
    defer call.mutex.clear();
    call.cond.init();
    defer call.cond.clear();
    _ = glib.idleAdd(&Call.startIdle, &call);
    call.mutex.lock();
    defer call.mutex.unlock();
    while (!call.done) call.cond.wait(&call.mutex);
    return call.result;
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
