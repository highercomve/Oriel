//! Windows file dialog implementation via COM IFileOpenDialog / IFileSaveDialog.
//!
//! Features:
//! - IFileOpenDialog / IFileSaveDialog with FOS_FORCEFILESYSTEM, path validation, and overwrite prompt
//! - Folders: IFileOpenDialog with FOS_PICKFOLDERS (`openFolder`; the id is the path)
//! - Returns null on user cancellation (HRESULT_FROM_WIN32(ERROR_CANCELLED) = 0x800704C7)
//! - Main-thread marshalling: marshals via `Shell.runOnMainThread`.
//! - Clean resource management: Release called on all COM objects, CoTaskMemFree on display name.

const std = @import("std");
const win32 = @import("../../platform/windows/win32.zig");
const ShellMod = @import("../../platform/windows/Shell.zig");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");
const path_folder = @import("path_folder.zig");

pub const OpenOptions = common.OpenOptions;
pub const SaveOptions = common.SaveOptions;
pub const FolderOptions = common.FolderOptions;
pub const Folder = common.Folder;

pub const folderName = path_folder.folderName;

const Kind = enum { open, save, folder };

const DialogParams = struct {
    gpa: std.mem.Allocator,
    kind: Kind,
    title: []const u8,
    modal: bool,
    result: ?[]u8 = null,
    err: ?anyerror = null,
};

fn runDialogDirect(params: *DialogParams) void {
    const is_save = params.kind == .save;
    const clsid = if (is_save) &win32.CLSID_FileSaveDialog else &win32.CLSID_FileOpenDialog;
    const iid = if (is_save) &win32.IID_IFileSaveDialog else &win32.IID_IFileOpenDialog;

    var dialog_opt: ?*anyopaque = null;
    const hr = win32.CoCreateInstance(clsid, null, win32.CLSCTX_INPROC_SERVER, iid, &dialog_opt);
    if (hr != win32.S_OK or dialog_opt == null) {
        params.err = error.DialogCreateFailed;
        return;
    }
    const dialog: *win32.IFileDialog = @ptrCast(@alignCast(dialog_opt.?));
    defer _ = dialog.lpVtbl.Release(dialog);

    // Set Title
    const title_w = std.unicode.utf8ToUtf16LeAllocZ(params.gpa, params.title) catch {
        params.err = error.OutOfMemory;
        return;
    };
    defer params.gpa.free(title_w);
    if (dialog.lpVtbl.SetTitle(dialog, title_w.ptr) < 0) {
        params.err = error.DialogSetTitleFailed;
        return;
    }

    // Set Options: OR into GetOptions as Microsoft documents, check both results
    var current_opts: win32.DWORD = 0;
    if (dialog.lpVtbl.GetOptions(dialog, &current_opts) < 0) {
        params.err = error.DialogGetOptionsFailed;
        return;
    }
    const extra_opts: win32.DWORD = switch (params.kind) {
        .save => win32.FOS_FORCEFILESYSTEM | win32.FOS_PATHMUSTEXIST | win32.FOS_OVERWRITEPROMPT,
        .open => win32.FOS_FORCEFILESYSTEM | win32.FOS_FILEMUSTEXIST | win32.FOS_PATHMUSTEXIST,
        .folder => win32.FOS_FORCEFILESYSTEM | win32.FOS_PICKFOLDERS | win32.FOS_PATHMUSTEXIST,
    };
    if (dialog.lpVtbl.SetOptions(dialog, current_opts | extra_opts) < 0) {
        params.err = error.DialogSetOptionsFailed;
        return;
    }

    // Parent window
    const parent_hwnd: ?win32.HWND = if (params.modal) ShellMod.main_hwnd else null;

    // Show dialog
    const show_hr = dialog.lpVtbl.Show(dialog, parent_hwnd);
    if (show_hr == win32.HRESULT_ERROR_CANCELLED) {
        params.result = null;
        return;
    }
    if (show_hr < 0) {
        params.err = error.DialogShowFailed;
        return;
    }

    // Retrieve result
    var psi_opt: ?*win32.IShellItem = null;
    if (dialog.lpVtbl.GetResult(dialog, &psi_opt) < 0 or psi_opt == null) {
        params.err = error.DialogGetResultFailed;
        return;
    }
    const psi = psi_opt.?;
    defer _ = psi.lpVtbl.Release(psi);

    var name_w: ?win32.LPWSTR = null;
    if (psi.lpVtbl.GetDisplayName(psi, win32.SIGDN_FILESYSPATH, &name_w) < 0 or name_w == null) {
        params.err = error.DialogGetDisplayNameFailed;
        return;
    }
    defer win32.CoTaskMemFree(name_w);

    const span = std.mem.span(name_w.?);
    params.result = std.unicode.utf16LeToUtf8Alloc(params.gpa, span) catch {
        params.err = error.OutOfMemory;
        return;
    };
}

fn runDialog(gpa: std.mem.Allocator, kind: Kind, title: []const u8, modal: bool) !?[]u8 {
    var params = DialogParams{
        .gpa = gpa,
        .kind = kind,
        .title = title,
        .modal = modal,
    };

    try ShellMod.runOnMainThread(DialogParams, &params, runDialogDirect);

    if (params.err) |err| return err;
    return params.result;
}

pub fn openFile(gpa: std.mem.Allocator, options: OpenOptions) !?[]u8 {
    return runDialog(gpa, .open, options.title, options.modal);
}

pub fn saveFile(gpa: std.mem.Allocator, options: SaveOptions) !?[]u8 {
    return runDialog(gpa, .save, options.title, options.modal);
}

/// Ask for a folder: its path is the id. Null if cancelled.
pub fn openFolder(gpa: std.mem.Allocator, options: FolderOptions) !?Folder {
    const path = try runDialog(gpa, .folder, options.title, options.modal) orelse return null;
    errdefer gpa.free(path);
    return .{ .id = path, .name = try gpa.dupe(u8, common.pathName(path)) };
}

pub fn saveToFolder(gpa: std.mem.Allocator, io: std.Io, id: []const u8, src_path: []const u8, name: []const u8, mime: ?[]const u8) ![]u8 {
    _ = mime;
    return path_folder.saveToFolder(gpa, io, id, src_path, name);
}

/// Nothing to release: a path grants nothing by itself.
pub fn forgetFolder(id: []const u8) void {
    _ = id;
}

pub fn check(_: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    const hr_co = win32.CoInitializeEx(null, win32.COINIT_APARTMENTTHREADED);
    const co_inited = (hr_co == win32.S_OK or hr_co == win32.S_FALSE);
    defer if (co_inited) win32.CoUninitialize();
    if (hr_co < 0 and hr_co != win32.RPC_E_CHANGED_MODE) {
        return error.CoInitializeFailed;
    }

    var dialog_opt: ?*anyopaque = null;
    const hr = win32.CoCreateInstance(
        &win32.CLSID_FileOpenDialog,
        null,
        win32.CLSCTX_INPROC_SERVER,
        &win32.IID_IFileOpenDialog,
        &dialog_opt,
    );
    if (hr != win32.S_OK or dialog_opt == null) {
        return error.CoCreateInstanceFailed;
    }
    const dialog: *win32.IFileDialog = @ptrCast(@alignCast(dialog_opt.?));
    _ = dialog.lpVtbl.Release(dialog);

    return .{
        .module = "dialog",
        .ok = true,
        .detail = "IFileOpenDialog COM class created and released ok",
    };
}

test {
    std.testing.refAllDecls(@This());
}
