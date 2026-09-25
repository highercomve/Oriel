//! macOS file dialogs: NSOpenPanel / NSSavePanel.
//!
//! Panels run app-modally (`runModal`) on the main thread; calls from other
//! threads are marshalled with `Shell.runOnMainThread`, like on Windows.
//! Returns null when the user cancels. (`modal` has no separate meaning
//! here: a running panel always blocks the app's other windows.)

const std = @import("std");
const cocoa = @import("../../platform/macos/cocoa.zig");
const ShellMod = @import("../../platform/macos/Shell.zig");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");

const Object = cocoa.Object;

pub const OpenOptions = common.OpenOptions;
pub const SaveOptions = common.SaveOptions;

const NSModalResponseOK: isize = 1;

const Params = struct {
    gpa: std.mem.Allocator,
    is_save: bool,
    title: []const u8,
    result: ?[]u8 = null,
    err: ?anyerror = null,
};

fn runPanel(params: *Params) void {
    const pool = cocoa.objc.AutoreleasePool.init();
    defer pool.deinit();

    const panel = if (params.is_save)
        cocoa.class("NSSavePanel").msgSend(Object, "savePanel", .{})
    else
        cocoa.class("NSOpenPanel").msgSend(Object, "openPanel", .{});
    if (panel.value == null) {
        params.err = error.DialogCreateFailed;
        return;
    }
    if (!params.is_save) {
        panel.msgSend(void, "setCanChooseFiles:", .{cocoa.boolean(true)});
        panel.msgSend(void, "setCanChooseDirectories:", .{cocoa.boolean(false)});
        panel.msgSend(void, "setAllowsMultipleSelection:", .{cocoa.boolean(false)});
    }
    if (cocoa.nsString(params.title)) |title| {
        defer title.release();
        // Panels have no title bar since macOS 11: the message shows it.
        panel.msgSend(void, "setTitle:", .{title});
        panel.msgSend(void, "setMessage:", .{title});
    }

    // Bring the app forward so the panel isn't hidden behind other apps.
    ShellMod.sharedApplication().msgSend(void, "activateIgnoringOtherApps:", .{cocoa.boolean(true)});
    if (panel.msgSend(isize, "runModal", .{}) != NSModalResponseOK) return; // cancelled

    const path = cocoa.utf8(panel.msgSend(Object, "URL", .{}).msgSend(Object, "path", .{})) orelse {
        params.err = error.DialogGetResultFailed;
        return;
    };
    params.result = params.gpa.dupe(u8, path) catch {
        params.err = error.OutOfMemory;
        return;
    };
}

fn run(gpa: std.mem.Allocator, is_save: bool, title: []const u8) !?[]u8 {
    var params: Params = .{ .gpa = gpa, .is_save = is_save, .title = title };
    try ShellMod.runOnMainThread(Params, &params, runPanel);
    if (params.err) |err| return err;
    return params.result;
}

/// Ask for an existing file. Caller frees the path; null if cancelled.
pub fn openFile(gpa: std.mem.Allocator, options: OpenOptions) !?[]u8 {
    return run(gpa, false, options.title);
}

/// Ask for a file to save to (the panel confirms overwrites). Caller frees
/// the path; null if cancelled.
pub fn saveFile(gpa: std.mem.Allocator, options: SaveOptions) !?[]u8 {
    return run(gpa, true, options.title);
}

/// Inside a running app: show an open panel and abort it from a timer
/// (`abortModal` works inside the modal loop), proving it opens without a
/// click. `--check` has no running app: check the classes instead.
pub fn check(gpa: std.mem.Allocator, ctx: oriel.CheckContext) !oriel.Check {
    if (ShellMod.isRunning()) return checkLive(gpa, ctx);
    return checkClasses();
}

fn checkLive(_: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    const Probe = struct {
        response: isize = 0,
        fn run(self: *@This()) void {
            const pool = cocoa.objc.AutoreleasePool.init();
            defer pool.deinit();
            const panel = cocoa.class("NSOpenPanel").msgSend(Object, "openPanel", .{});
            if (panel.value == null) return;
            const app = ShellMod.sharedApplication();
            const sel = cocoa.objc.sel("abortModal");
            // A timer in the modal run loop mode: performSelector's default
            // mode wouldn't fire while the panel runs.
            const mode = cocoa.nsString("NSModalPanelRunLoopMode") orelse return;
            defer mode.release();
            const modes = cocoa.class("NSArray").msgSend(Object, "arrayWithObject:", .{mode});
            app.msgSend(void, "performSelector:withObject:afterDelay:inModes:", .{ sel.value, cocoa.nil, @as(f64, 0.5), modes });
            self.response = panel.msgSend(isize, "runModal", .{});
        }
    };
    var probe: Probe = .{};
    try ShellMod.runOnMainThread(Probe, &probe, Probe.run);
    const NSModalResponseAbort: isize = -1001;
    const ok = probe.response == NSModalResponseAbort;
    return .{
        .module = "dialog",
        .ok = ok,
        .detail = if (ok) "NSOpenPanel shown modally and dismissed by abortModal after 0.5 s" else "open panel did not run",
    };
}

fn checkClasses() !oriel.Check {
    const open_panel = cocoa.objc.getClass("NSOpenPanel") orelse return .{ .module = "dialog", .ok = false, .detail = "NSOpenPanel missing" };
    const save_panel = cocoa.objc.getClass("NSSavePanel") orelse return .{ .module = "dialog", .ok = false, .detail = "NSSavePanel missing" };
    const ok = open_panel.respondsToSelector(cocoa.objc.sel("runModal")) and
        save_panel.respondsToSelector(cocoa.objc.sel("runModal")) and
        open_panel.respondsToSelector(cocoa.objc.sel("setAllowsMultipleSelection:"));
    return .{
        .module = "dialog",
        .ok = ok,
        .detail = if (ok) "NSOpenPanel / NSSavePanel available (runModal on the main thread)" else "panel API missing",
    };
}

test {
    std.testing.refAllDecls(@This());
}
