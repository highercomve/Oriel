//! oriel.share on Windows.
//!
//! Sending: the system share sheet through DataTransferManager, which
//! desktop (unpackaged) apps reach with IDataTransferManagerInterop on
//! their window. `send` resolves the files to StorageFiles first (async,
//! off the UI thread), then shows the sheet; DataRequested fills the
//! DataPackage at once from what was prepared (title, text, web link,
//! storage items), so it needs no deferral. TargetApplicationChosen is
//! the completion. Windows reports no dismissal: the sheet takes the
//! foreground, so the window being in front again with no target chosen
//! means it was dismissed (`completed: false`).
//!
//! Receiving: Send To and "Open with" (a Share Target needs package
//! identity, MSIX). The installer (tools/package/nsis.zig) creates a Send
//! To shortcut running `<exe> --oriel-send-to` (Explorer appends the
//! files) and "Open with" entries running `<exe> --oriel-open-with "%1"`.
//! Such a launch's arguments reach `receiveArgs`: in this process when
//! it's the first, else through the single-instance WM_COPYDATA path
//! (platform/windows/Shell.zig). Each file is opened read-only into
//! `received` (core/file_handles.zig); the share carries handles, never
//! paths, and goes out through common.dispatch (`share:received`).

const std = @import("std");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");
const win32 = @import("../../platform/windows/win32.zig");
const ShellMod = @import("../../platform/windows/Shell.zig");
const winrt = @import("../../platform/windows/winrt.zig");
const file_handles = @import("../../core/file_handles.zig");

const log = std.log.scoped(.share);
const gpa = std.heap.smp_allocator;
const HRESULT = winrt.HRESULT;
const HSTRING = winrt.HSTRING;
const GUID = winrt.GUID;
const Inspectable = winrt.Inspectable;
const Slot = *const anyopaque;

// ------------------------------------------------------------ interfaces
// IIDs and slot orders from Windows.ApplicationModel.winmd,
// Windows.Storage.winmd and Windows.Foundation.winmd.

const DataTransferManagerInterop = extern struct {
    vtbl: *const extern struct {
        QueryInterface: Slot,
        AddRef: Slot,
        Release: Slot,
        GetForWindow: *const fn (*DataTransferManagerInterop, win32.HWND, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        ShowShareUIForWindow: *const fn (*DataTransferManagerInterop, win32.HWND) callconv(.winapi) HRESULT,
    },
    pub const iid = GUID.parse("{3A3DCD6C-3EAB-43DC-BCDE-45671CE800C8}");
};

const DataTransferManager = extern struct {
    vtbl: *const extern struct {
        base: Inspectable.Vtbl,
        add_DataRequested: *const fn (*DataTransferManager, *anyopaque, *winrt.EventToken) callconv(.winapi) HRESULT,
        remove_DataRequested: *const fn (*DataTransferManager, winrt.EventToken) callconv(.winapi) HRESULT,
        add_TargetApplicationChosen: *const fn (*DataTransferManager, *anyopaque, *winrt.EventToken) callconv(.winapi) HRESULT,
        remove_TargetApplicationChosen: *const fn (*DataTransferManager, winrt.EventToken) callconv(.winapi) HRESULT,
    },
    pub const iid = GUID.parse("{A5CAEE9B-8708-49D1-8D36-67D25A8DA00C}");
    pub const sig = winrt.sig.class("Windows.ApplicationModel.DataTransfer.DataTransferManager", iid);
};

const DataRequestedEventArgs = extern struct {
    vtbl: *const extern struct {
        base: Inspectable.Vtbl,
        get_Request: *const fn (*DataRequestedEventArgs, *?*DataRequest) callconv(.winapi) HRESULT,
    },
    pub const iid = GUID.parse("{CB8BA807-6AC5-43C9-8AC5-9BA232163182}");
    pub const sig = winrt.sig.class("Windows.ApplicationModel.DataTransfer.DataRequestedEventArgs", iid);
};

const DataRequest = extern struct {
    vtbl: *const extern struct {
        base: Inspectable.Vtbl,
        get_Data: *const fn (*DataRequest, *?*DataPackage) callconv(.winapi) HRESULT,
        put_Data: Slot,
        get_Deadline: Slot,
        FailWithDisplayText: *const fn (*DataRequest, HSTRING) callconv(.winapi) HRESULT,
        GetDeferral: Slot,
    },
};

const DataPackage = extern struct {
    vtbl: *const extern struct {
        base: Inspectable.Vtbl,
        GetView: Slot,
        get_Properties: *const fn (*DataPackage, *?*DataPackagePropertySet) callconv(.winapi) HRESULT,
        get_RequestedOperation: Slot,
        put_RequestedOperation: Slot,
        add_OperationCompleted: Slot,
        remove_OperationCompleted: Slot,
        add_Destroyed: Slot,
        remove_Destroyed: Slot,
        SetData: Slot,
        SetDataProvider: Slot,
        SetText: *const fn (*DataPackage, HSTRING) callconv(.winapi) HRESULT,
        SetUri: Slot,
        SetHtmlFormat: Slot,
        get_ResourceMap: Slot,
        SetRtf: Slot,
        SetBitmap: Slot,
        /// SetStorageItems(items): read-only items.
        SetStorageItemsReadOnly: *const fn (*DataPackage, *anyopaque) callconv(.winapi) HRESULT,
        SetStorageItems: Slot,
    },
};

const DataPackage2 = extern struct {
    vtbl: *const extern struct {
        base: Inspectable.Vtbl,
        SetApplicationLink: Slot,
        SetWebLink: *const fn (*DataPackage2, *Inspectable) callconv(.winapi) HRESULT,
    },
    pub const iid = GUID.parse("{041C1FE9-2409-45E1-A538-4C53EEEE04A7}");
};

const DataPackagePropertySet = extern struct {
    vtbl: *const extern struct {
        base: Inspectable.Vtbl,
        get_Title: Slot,
        put_Title: *const fn (*DataPackagePropertySet, HSTRING) callconv(.winapi) HRESULT,
    },
};

const TargetApplicationChosenEventArgs = extern struct {
    vtbl: *const extern struct {
        base: Inspectable.Vtbl,
        get_ApplicationName: *const fn (*TargetApplicationChosenEventArgs, *HSTRING) callconv(.winapi) HRESULT,
    },
    pub const iid = GUID.parse("{CA6FB8AC-2987-4EE3-9C54-D8AFBCB86C1D}");
    pub const sig = winrt.sig.class("Windows.ApplicationModel.DataTransfer.TargetApplicationChosenEventArgs", iid);
};

const UriFactory = extern struct {
    vtbl: *const extern struct {
        base: Inspectable.Vtbl,
        CreateUri: *const fn (*UriFactory, HSTRING, *?*Inspectable) callconv(.winapi) HRESULT,
    },
    pub const iid = GUID.parse("{44A9796F-723E-4FDF-A218-033E75B0C084}");
};

const StorageFileStatics = extern struct {
    vtbl: *const extern struct {
        base: Inspectable.Vtbl,
        GetFileFromPathAsync: *const fn (*StorageFileStatics, HSTRING, *?*FileOp) callconv(.winapi) HRESULT,
    },
    pub const iid = GUID.parse("{5984C710-DAF2-43C8-8BB4-A4D3EACFD03F}");
};

const StorageItem = extern struct {
    vtbl: *const Inspectable.Vtbl,
    pub const iid = GUID.parse("{4207A996-CA2F-42F7-BDE8-8B10457A7F30}");
};

const storage_file_sig = winrt.sig.class("Windows.Storage.StorageFile", GUID.parse("{FA3F6186-4214-428C-A64C-14C9AC7315EA}"));
const FileOp = winrt.AsyncOperation(storage_file_sig);
const StorageItems = winrt.Iterable(winrt.sig.iface(StorageItem.iid));

const DataRequestedHandler = winrt.Delegate(
    winrt.piid(winrt.sig.pinterface(winrt.generic.typed_event_handler, &.{ DataTransferManager.sig, DataRequestedEventArgs.sig })),
    *DataTransferManager,
    *DataRequestedEventArgs,
    State,
);
const TargetChosenHandler = winrt.Delegate(
    winrt.piid(winrt.sig.pinterface(winrt.generic.typed_event_handler, &.{ DataTransferManager.sig, TargetApplicationChosenEventArgs.sig })),
    *DataTransferManager,
    *TargetApplicationChosenEventArgs,
    State,
);

// ----------------------------------------------------------------- state

/// UI thread only (the async file lookups hand back through
/// dispatchToMainThread).
const State = struct {
    interop: ?*DataTransferManagerInterop = null,
    /// The manager of `hwnd`, with our two handlers registered.
    manager: ?*DataTransferManager = null,
    hwnd: ?win32.HWND = null,
    requested_token: winrt.EventToken = .{},
    chosen_token: winrt.EventToken = .{},
    pending: ?*Pending = null,
    /// Files written for `.bytes`, deleted on the next send.
    temp_files: std.ArrayList([:0]u16) = .empty,
    temp_dir: ?[]u8 = null,
    temp_seq: u32 = 0,
};

var state: State = .{};

/// Files received from other apps: common.zig's table, shared with the
/// page's reads (`share:read`).
const received = &common.received;

/// One send, from `send` until `done`.
const Pending = struct {
    title: winrt.String,
    text: winrt.String = .{},
    url: winrt.String = .{},
    done: ?common.DoneHandler,
    /// One per file, filled by the lookups (any thread).
    items: []?*Inspectable,
    lookups: []Lookup,
    waiting: std.atomic.Value(u32),
    shown: bool = false,
    /// The sheet had the foreground (or the window lost it).
    away: bool = false,
    /// Timer ticks since the sheet was shown / since the window came back.
    ticks: u32 = 0,
    back_ticks: u32 = 0,
    timer: usize = 0,

    const Lookup = struct { p: *Pending, i: usize };

    fn destroy(p: *Pending) void {
        for (p.items) |it| if (it) |i| winrt.release(i);
        gpa.free(p.items);
        gpa.free(p.lookups);
        p.title.deinit();
        p.text.deinit();
        p.url.deinit();
        gpa.destroy(p);
    }
};

// ------------------------------------------------------------------ send

pub fn send(item: common.Outgoing, anchor: ?common.Rect, done: ?common.DoneHandler) common.SendError!void {
    _ = anchor; // the sheet places itself
    const Call = struct {
        item: common.Outgoing,
        done: ?common.DoneHandler,
        err: ?common.SendError = null,
        fn run(c: *@This()) void {
            start(c.item, c.done) catch |e| {
                c.err = e;
            };
        }
    };
    var call: Call = .{ .item = item, .done = done };
    ShellMod.runOnMainThread(Call, &call, Call.run) catch return error.Unsupported;
    if (call.err) |e| return e;
}

fn start(item: common.Outgoing, done: ?common.DoneHandler) common.SendError!void {
    if (state.pending != null) return error.Busy;
    const hwnd = ShellMod.main_hwnd orelse return error.Unsupported;
    if (item.text == null and item.url == null and item.files.len == 0) return error.Unsupported;
    managerFor(hwnd) catch return error.Unsupported;
    sweepTemp();

    const p = gpa.create(Pending) catch return error.Unsupported;
    p.* = .{
        .title = .{},
        .done = done,
        .items = gpa.alloc(?*Inspectable, item.files.len) catch {
            gpa.destroy(p);
            return error.Unsupported;
        },
        .lookups = &.{},
        .waiting = .init(@intCast(item.files.len)),
    };
    @memset(p.items, null);
    errdefer p.destroy();
    p.lookups = gpa.alloc(Pending.Lookup, item.files.len) catch return error.Unsupported;
    for (p.lookups, 0..) |*l, i| l.* = .{ .p = p, .i = i };

    p.title = title(item.title) catch return error.Unsupported;
    if (item.text) |t| p.text = winrt.String.fromUtf8(gpa, t) catch return error.Unsupported;
    if (item.url) |u| p.url = winrt.String.fromUtf8(gpa, u) catch return error.Unsupported;

    // Resolve every path before starting a lookup: a bad one fails the
    // send with nothing in flight.
    const paths = gpa.alloc([:0]u16, item.files.len) catch return error.Unsupported;
    var n_paths: usize = 0;
    defer {
        for (paths[0..n_paths]) |w| gpa.free(w);
        gpa.free(paths);
    }
    for (item.files) |f| {
        paths[n_paths] = filePath(f) catch |e| {
            log.warn("share: a file can't be sent: {s}", .{@errorName(e)});
            return switch (e) {
                error.BadHandle, error.NotReadable => error.InvalidHandle,
                else => error.Unsupported,
            };
        };
        n_paths += 1;
    }

    if (item.files.len == 0) {
        state.pending = p;
        errdefer state.pending = null;
        return show(p);
    }

    const statics = winrt.factory(StorageFileStatics, "Windows.Storage.StorageFile") catch return error.Unsupported;
    defer winrt.release(statics);
    state.pending = p;
    for (paths, p.lookups, 0..) |w, *l, k| {
        lookup(statics, w, l) catch {
            // Lookups already started still finish and touch `p`: the
            // send now fails through `done`, as a file that isn't found.
            if (k == 0) {
                state.pending = null;
                return error.Unsupported;
            }
            const left: u32 = @intCast(paths.len - k);
            if (p.waiting.fetchSub(left, .acq_rel) == left) ShellMod.dispatchToMainThread(showTask, p);
            return;
        };
    }
}

fn lookup(statics: *StorageFileStatics, path: [:0]const u16, l: *Pending.Lookup) winrt.Error!void {
    var s = try winrt.String.fromUtf16(path);
    defer s.deinit();
    var op: ?*FileOp = null;
    try winrt.check(statics.vtbl.GetFileFromPathAsync(statics, s.h, &op), "GetFileFromPathAsync");
    defer winrt.release(op.?);
    try op.?.then(Pending.Lookup, l, fileReady);
}

/// A file lookup ended (any thread): keep its IStorageItem; the last one
/// shows the sheet on the UI thread.
fn fileReady(l: *Pending.Lookup, result: ?*Inspectable) void {
    if (result) |r| {
        defer winrt.release(r);
        l.p.items[l.i] = @ptrCast(winrt.query(StorageItem, r) catch null);
    }
    if (l.p.waiting.fetchSub(1, .acq_rel) == 1) ShellMod.dispatchToMainThread(showTask, l.p);
}

fn showTask(ctx: ?*anyopaque) void {
    const p: *Pending = @ptrCast(@alignCast(ctx.?));
    if (state.pending != p) return; // canceled
    for (p.items) |it| if (it == null) {
        log.warn("share: a file could not be opened as a StorageFile", .{});
        return finish(false, null);
    };
    show(p) catch finish(false, null);
}

fn show(p: *Pending) common.SendError!void {
    const hwnd = state.hwnd orelse return error.Unsupported;
    winrt.check(state.interop.?.vtbl.ShowShareUIForWindow(state.interop.?, hwnd), "ShowShareUIForWindow") catch return error.Unsupported;
    p.shown = true;
    p.timer = win32.SetTimer(null, 0, tick_ms, @ptrCast(&onTick));
}

/// DataRequested: fill the package from the pending send (UI thread).
fn onDataRequested(_: *State, _: *DataTransferManager, args: *DataRequestedEventArgs) void {
    const p = state.pending orelse return;
    fill(p, args) catch |e| log.warn("share: DataRequested: {s}", .{@errorName(e)});
}

fn fill(p: *Pending, args: *DataRequestedEventArgs) winrt.Error!void {
    var req: ?*DataRequest = null;
    try winrt.check(args.vtbl.get_Request(args, &req), "get_Request");
    defer winrt.release(req.?);
    var pkg: ?*DataPackage = null;
    try winrt.check(req.?.vtbl.get_Data(req.?, &pkg), "get_Data");
    defer winrt.release(pkg.?);
    var props: ?*DataPackagePropertySet = null;
    try winrt.check(pkg.?.vtbl.get_Properties(pkg.?, &props), "get_Properties");
    defer winrt.release(props.?);
    try winrt.check(props.?.vtbl.put_Title(props.?, p.title.h), "put_Title");

    if (p.text.h != null) try winrt.check(pkg.?.vtbl.SetText(pkg.?, p.text.h), "SetText");
    if (p.url.h != null) {
        const f = try winrt.factory(UriFactory, "Windows.Foundation.Uri");
        defer winrt.release(f);
        var uri: ?*Inspectable = null;
        // Not a URI: shared as text instead.
        if (f.vtbl.CreateUri(f, p.url.h, &uri) < 0 or uri == null) {
            if (p.text.h == null) try winrt.check(pkg.?.vtbl.SetText(pkg.?, p.url.h), "SetText");
        } else {
            defer winrt.release(uri.?);
            const pkg2 = try winrt.query(DataPackage2, pkg.?);
            defer winrt.release(pkg2);
            try winrt.check(pkg2.vtbl.SetWebLink(pkg2, uri.?), "SetWebLink");
        }
    }
    if (p.items.len > 0) {
        const items = try gpa.alloc(*Inspectable, p.items.len);
        defer gpa.free(items);
        for (p.items, 0..) |it, i| items[i] = it.?;
        const list = try StorageItems.create(items);
        defer winrt.release(list);
        try winrt.check(pkg.?.vtbl.SetStorageItemsReadOnly(pkg.?, list), "SetStorageItems");
    }
}

/// TargetApplicationChosen: the send completed.
fn onTargetChosen(_: *State, _: *DataTransferManager, args: *TargetApplicationChosenEventArgs) void {
    if (state.pending == null) return;
    var h: HSTRING = null;
    if (args.vtbl.get_ApplicationName(args, &h) < 0) h = null;
    var name = winrt.String.adopt(h);
    defer name.deinit();
    const utf8 = name.toUtf8(gpa) catch null;
    defer if (utf8) |u| gpa.free(u);
    finish(true, if (utf8) |u| (if (u.len > 0) u else null) else null);
}

const tick_ms = 200;
/// The sheet never took the foreground in this long: it didn't open.
const max_wait_ticks = 15_000 / tick_ms;
/// Back in front this long with no target chosen: dismissed.
const back_ticks = 2;

/// Watches the foreground while the sheet is up: Windows has no
/// dismissal event.
fn onTick(_: ?win32.HWND, _: u32, _: usize, _: u32) callconv(.winapi) void {
    const p = state.pending orelse return;
    p.ticks += 1;
    const front = win32.GetForegroundWindow() == state.hwnd;
    if (!front) {
        p.away = true;
        p.back_ticks = 0;
    } else if (p.away) {
        p.back_ticks += 1;
        if (p.back_ticks >= back_ticks) return finish(false, null);
    } else if (p.ticks >= max_wait_ticks) {
        return finish(false, null);
    }
}

fn finish(completed: bool, target: ?[]const u8) void {
    const p = state.pending orelse return;
    state.pending = null;
    if (p.timer != 0) _ = win32.KillTimer(null, p.timer);
    const done = p.done;
    p.destroy();
    if (done) |d| d(.{ .completed = completed, .target = target });
}

// --------------------------------------------------------------- helpers

/// The manager for `hwnd`, its handlers registered (once per window).
fn managerFor(hwnd: win32.HWND) winrt.Error!void {
    if (state.manager != null and state.hwnd == hwnd) return;
    if (state.interop == null) state.interop = try winrt.factory(DataTransferManagerInterop, "Windows.ApplicationModel.DataTransfer.DataTransferManager");
    if (state.manager) |m| {
        _ = m.vtbl.remove_DataRequested(m, state.requested_token);
        _ = m.vtbl.remove_TargetApplicationChosen(m, state.chosen_token);
        winrt.release(m);
        state.manager = null;
    }
    var out: ?*anyopaque = null;
    try winrt.check(state.interop.?.vtbl.GetForWindow(state.interop.?, hwnd, &DataTransferManager.iid, &out), "GetForWindow");
    const m: *DataTransferManager = @ptrCast(@alignCast(out orelse return error.WinRT));
    errdefer winrt.release(m);
    const req = try DataRequestedHandler.create(&state, onDataRequested);
    defer winrt.release(req);
    try winrt.check(m.vtbl.add_DataRequested(m, req, &state.requested_token), "add_DataRequested");
    const chosen = try TargetChosenHandler.create(&state, onTargetChosen);
    defer winrt.release(chosen);
    try winrt.check(m.vtbl.add_TargetApplicationChosen(m, chosen, &state.chosen_token), "add_TargetApplicationChosen");
    state.manager = m;
    state.hwnd = hwnd;
}

/// The sheet requires a title: the item's, else the window's.
fn title(t: ?[]const u8) winrt.Error!winrt.String {
    if (t) |s| if (s.len > 0) return winrt.String.fromUtf8(gpa, s);
    var buf: [256]u16 = undefined;
    const n = win32.GetWindowTextW(state.hwnd.?, @ptrCast(&buf), buf.len);
    if (n > 0) return winrt.String.fromUtf16(buf[0..@intCast(n)]);
    return winrt.String.fromUtf16(winrt.L("Share"));
}

/// A file to send as a path (UTF-16, owned).
fn filePath(f: common.OutFile) ![:0]u16 {
    switch (f) {
        .path => |p| return std.unicode.utf8ToUtf16LeAllocZ(gpa, p),
        .handle => |h| {
            const p = try received.currentPath(gpa, h);
            defer gpa.free(p);
            return std.unicode.utf8ToUtf16LeAllocZ(gpa, p);
        },
        .bytes => |b| return writeTemp(b.name, b.bytes),
    }
}

/// `bytes` as a file named `name` in this process's share folder under
/// %TEMP% (deleted on the next send).
fn writeTemp(name: []const u8, bytes: []const u8) ![:0]u16 {
    const dir = try tempDir();
    const base = std.fs.path.basenameWindows(name);
    const safe = if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) "file" else base;
    state.temp_seq += 1;
    // A folder per file: two files may share a name.
    const sub = try std.fmt.allocPrint(gpa, "{s}\\{d}", .{ dir, state.temp_seq });
    defer gpa.free(sub);
    const sub_w = try std.unicode.utf8ToUtf16LeAllocZ(gpa, sub);
    defer gpa.free(sub_w);
    _ = win32.CreateDirectoryW(sub_w.ptr, null);
    const full = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ sub, safe });
    defer gpa.free(full);
    const w = try std.unicode.utf8ToUtf16LeAllocZ(gpa, full);
    errdefer gpa.free(w);
    const h = win32.CreateFileW(w.ptr, win32.GENERIC_WRITE, 0, null, win32.CREATE_ALWAYS, 0, null);
    if (h == win32.INVALID_HANDLE_VALUE) return error.OpenFailed;
    defer _ = win32.CloseHandle(h);
    var off: usize = 0;
    while (off < bytes.len) {
        const chunk: u32 = @intCast(@min(bytes.len - off, 1 << 30));
        var wrote: u32 = 0;
        if (win32.WriteFile(h, bytes[off..].ptr, chunk, &wrote, null) == win32.FALSE or wrote == 0) return error.WriteFailed;
        off += wrote;
    }
    const keep = try gpa.dupeZ(u16, w);
    state.temp_files.append(gpa, keep) catch {
        gpa.free(keep);
        return error.OutOfMemory;
    };
    return w;
}

/// %TEMP%\oriel-share-out\<pid>, created on first use.
fn tempDir() ![]u8 {
    if (state.temp_dir) |d| return d;
    var buf: [win32.MAX_PATH + 1]u16 = undefined;
    const n = win32.GetTempPathW(buf.len, &buf);
    if (n == 0 or n > buf.len) return error.NoTempDir;
    const tmp = try std.unicode.utf16LeToUtf8Alloc(gpa, buf[0..n]);
    defer gpa.free(tmp);
    const root = try std.fmt.allocPrint(gpa, "{s}oriel-share-out", .{tmp});
    defer gpa.free(root);
    const root_w = try std.unicode.utf8ToUtf16LeAllocZ(gpa, root);
    defer gpa.free(root_w);
    _ = win32.CreateDirectoryW(root_w.ptr, null);
    const dir = try std.fmt.allocPrint(gpa, "{s}\\{d}", .{ root, win32.GetCurrentProcessId() });
    defer gpa.free(dir);
    const dir_w = try std.unicode.utf8ToUtf16LeAllocZ(gpa, dir);
    defer gpa.free(dir_w);
    _ = win32.CreateDirectoryW(dir_w.ptr, null);
    const keep = try gpa.dupe(u8, dir);
    state.temp_dir = keep;
    return keep;
}

extern "kernel32" fn RemoveDirectoryW(path: [*:0]const u16) callconv(.winapi) win32.BOOL;

/// Delete the files the last send wrote (the target has its copy by now,
/// or the user dismissed the sheet), and their folders.
fn sweepTemp() void {
    for (state.temp_files.items) |w| {
        _ = win32.DeleteFileW(w.ptr);
        if (std.mem.lastIndexOfScalar(u16, w, '\\')) |i| {
            w[i] = 0;
            _ = RemoveDirectoryW(w[0..i :0].ptr);
        }
        gpa.free(w);
    }
    state.temp_files.clearRetainingCapacity();
}

// --------------------------------------------------------------- the rest

pub fn capabilities() common.Capabilities {
    return .{ .receive = .send_to, .send = .{ .supported = true, .files = true, .text = true, .url = true, .multiple = true } };
}

// --------------------------------------------------------------- receive

/// The Send To shortcut's argument: the files follow it.
pub const send_to_flag = "--oriel-send-to";
/// The "Open with" command's argument: the file follows it.
pub const open_with_flag = "--oriel-open-with";

/// Shares received and not released: id -> its files' handles. UI thread.
var shares: std.AutoHashMapUnmanaged(u32, []u32) = .empty;
var next_share: u32 = 1;

/// A launch's arguments (without argv[0]), on the UI thread: when they
/// carry a share (Send To, "Open with"), deliver it. Returns whether they
/// did. Files that can't be opened (gone, a folder) are left out.
pub fn receiveArgs(args: []const []const u8) bool {
    const at = parseLaunch(args) orelse return false;
    var files: std.ArrayList(common.File) = .empty;
    defer files.deinit(gpa);
    var handles: std.ArrayList(u32) = .empty;
    defer handles.deinit(gpa);
    for (args[at.first..]) |path| {
        const f = keepFile(path) catch |e| {
            log.warn("share: a received file can't be opened: {s}", .{@errorName(e)});
            continue;
        } orelse continue;
        handles.append(gpa, f.handle) catch {
            received.release(f.handle);
            continue;
        };
        files.append(gpa, f) catch {
            _ = handles.pop();
            received.release(f.handle);
        };
    }
    if (files.items.len == 0) return true;
    const id = next_share;
    next_share +%= 1;
    if (next_share == 0) next_share = 1;
    // Out of memory: the share is dropped, its files closed.
    shares.ensureUnusedCapacity(gpa, 1) catch {
        for (files.items) |f| received.release(f.handle);
        return true;
    };
    const owned = handles.toOwnedSlice(gpa) catch {
        for (files.items) |f| received.release(f.handle);
        return true;
    };
    shares.putAssumeCapacity(id, owned);
    const r: common.Received = .{ .id = id, .source = at.source, .files = files.items };
    common.dispatch(&r);
    return true;
}

const Launch = struct { source: common.Source, first: usize };

/// Whether a launch's arguments carry a share (Shell: forward it to the
/// running instance).
pub fn isShareLaunch(args: []const []const u8) bool {
    return parseLaunch(args) != null;
}

/// Where a share launch's files start, and how it came.
fn parseLaunch(args: []const []const u8) ?Launch {
    for (args, 0..) |a, i| {
        if (std.mem.eql(u8, a, send_to_flag)) return .{ .source = .send_to, .first = i + 1 };
        if (std.mem.eql(u8, a, open_with_flag)) return .{ .source = .open_with, .first = i + 1 };
    }
    return null;
}

/// Open `path` into `received`: its File (name and type for the page, no
/// path), or null when it isn't a regular file. Absolute paths only.
fn keepFile(path: []const u8) !?common.File {
    if (!std.fs.path.isAbsoluteWindows(path)) return error.NotAbsolute;
    const z = try gpa.dupeZ(u8, path);
    defer gpa.free(z);
    const handle = try received.addPath(z) orelse return null;
    const e = received.info(handle).?;
    const name = std.fs.path.basenameWindows(path);
    return .{ .handle = handle, .name = name, .mime = mimeOf(name), .size = e.size };
}

/// A MIME type from the file name's extension (the page's File.type).
fn mimeOf(name: []const u8) []const u8 {
    const ext = std.fs.path.extension(name);
    const table = [_]struct { []const u8, []const u8 }{
        .{ ".txt", "text/plain" },        .{ ".md", "text/markdown" },     .{ ".csv", "text/csv" },
        .{ ".html", "text/html" },        .{ ".htm", "text/html" },        .{ ".json", "application/json" },
        .{ ".xml", "application/xml" },   .{ ".pdf", "application/pdf" },  .{ ".zip", "application/zip" },
        .{ ".png", "image/png" },         .{ ".jpg", "image/jpeg" },       .{ ".jpeg", "image/jpeg" },
        .{ ".gif", "image/gif" },         .{ ".webp", "image/webp" },      .{ ".svg", "image/svg+xml" },
        .{ ".bmp", "image/bmp" },         .{ ".heic", "image/heic" },      .{ ".mp3", "audio/mpeg" },
        .{ ".wav", "audio/wav" },         .{ ".ogg", "audio/ogg" },        .{ ".m4a", "audio/mp4" },
        .{ ".flac", "audio/flac" },       .{ ".mp4", "video/mp4" },        .{ ".mov", "video/quicktime" },
        .{ ".webm", "video/webm" },       .{ ".mkv", "video/x-matroska" }, .{ ".avi", "video/x-msvideo" },
    };
    for (table) |t| if (std.ascii.eqlIgnoreCase(ext, t[0])) return t[1];
    return "application/octet-stream";
}

/// A received file, read-only: a new handle to the file `handle` names
/// (the caller closes it). InvalidHandle once released or changed.
pub fn open(handle: u32) common.OpenError!std.Io.File {
    const e = received.info(handle) orelse return error.InvalidHandle;
    var dup: win32.HANDLE = undefined;
    const self = win32.GetCurrentProcess();
    if (win32.DuplicateHandle(self, e.fd, self, &dup, 0, win32.FALSE, win32.DUPLICATE_SAME_ACCESS) == win32.FALSE)
        return error.InvalidHandle;
    return .{ .handle = dup, .flags = .{ .nonblocking = false } };
}

/// Let a share's files go: their handles close.
pub fn release(id: u32) void {
    const kv = shares.fetchRemove(id) orelse return;
    for (kv.value) |h| received.release(h);
    gpa.free(kv.value);
}

pub fn check(alloc: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    return .{ .module = "share", .ok = true, .detail = try alloc.dupe(u8, "send: DataTransferManager; receive: Send To, Open with") };
}

test "parseLaunch" {
    const t = std.testing;
    try t.expectEqual(@as(?Launch, null), parseLaunch(&.{ "a", "b" }));
    const s = parseLaunch(&.{ send_to_flag, "C:\\a.txt", "C:\\b.png" }).?;
    try t.expectEqual(common.Source.send_to, s.source);
    try t.expectEqual(@as(usize, 1), s.first);
    const o = parseLaunch(&.{ "--x", open_with_flag, "C:\\a.txt" }).?;
    try t.expectEqual(common.Source.open_with, o.source);
    try t.expectEqual(@as(usize, 2), o.first);
}

test "mimeOf" {
    try std.testing.expectEqualStrings("image/png", mimeOf("Photo.PNG"));
    try std.testing.expectEqualStrings("text/plain", mimeOf("notes.txt"));
    try std.testing.expectEqualStrings("application/octet-stream", mimeOf("noext"));
}

test {
    std.testing.refAllDecls(winrt);
}
