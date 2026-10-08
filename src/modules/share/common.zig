//! oriel.share's shared part: what is received and sent, and the receive
//! handler. Each OS backend provides `send`, `capabilities` and `open`, and
//! reports what it receives with `dispatch`.

const std = @import("std");
const App = @import("../../core/App.zig");
const pending_events = @import("../../core/pending_events.zig");
const file_handles = @import("../../core/file_handles.zig");

/// Files received from other apps, opened read-only when they arrived
/// (every backend adds them here): `open`, `read` (the page's
/// oriel.share.file) and `.handle` in `send` go through it.
pub var received: file_handles.FileHandles = .init(@import("../../core/heap.zig").gpa);

/// Up to `len` bytes of received file `handle` from `offset`, appended to
/// `out` (the page reads a file in chunks through the `share:read` command).
pub fn read(handle: u32, offset: u64, len: u64, out: *std.ArrayList(u8)) !void {
    received.read(handle, offset, len, out) catch |err| return switch (err) {
        // The page sees the same name as `open`'s.
        error.BadHandle => error.InvalidHandle,
        else => err,
    };
}

/// How the share reached the app.
pub const Source = enum {
    /// The system share sheet (Android ACTION_SEND, a Windows Share Target).
    share,
    /// "Open with" (desktop file managers, iOS document types).
    open_with,
    /// macOS Services.
    service,
    /// Windows' Send To menu.
    send_to,
    /// A share extension (iOS, macOS).
    extension,
};

/// A received file: its contents through `open(handle)` (Zig) or
/// `oriel.share.file(handle)` (the page). Never a path.
pub const File = struct {
    handle: u32,
    name: []const u8,
    mime: []const u8,
    size: u64,
};

/// One share: text, a URL, files, or several of them.
pub const Received = struct {
    /// Identifies the share for `release`.
    id: u32,
    source: Source,
    text: ?[]const u8 = null,
    subject: ?[]const u8 = null,
    url: ?[]const u8 = null,
    files: []const File = &.{},
};

/// Runs on the main thread; `received` lives until it returns.
pub const ReceiveHandler = *const fn (received: *const Received) void;

/// A file to send.
pub const OutFile = union(enum) {
    /// A file on disk.
    path: []const u8,
    /// A received file (`File.handle`).
    handle: u32,
    /// Bytes, sent as a file with this name.
    bytes: struct { name: []const u8, bytes: []const u8 },
};

pub const Outgoing = struct {
    title: ?[]const u8 = null,
    text: ?[]const u8 = null,
    url: ?[]const u8 = null,
    files: []const OutFile = &.{},
};

/// Where the share sheet points from (iPad popovers; default: the window's
/// center).
pub const Rect = App.Rect;

pub const Result = struct {
    /// The user picked a target (false: dismissed).
    completed: bool,
    /// The target, where the OS reports it.
    target: ?[]const u8 = null,
};

pub const DoneHandler = *const fn (result: Result) void;

pub const SendError = error{
    /// Not on this platform (or this kind of item: `capabilities().send`).
    Unsupported,
    /// A share sheet is already open.
    Busy,
    /// An `OutFile.handle` that names no received file (any more), or a
    /// received file that changed since it arrived.
    InvalidHandle,
};

pub const SendCapabilities = struct {
    supported: bool = false,
    files: bool = false,
    text: bool = false,
    url: bool = false,
    multiple: bool = false,
};

pub const Capabilities = struct {
    /// How this platform delivers shares to the app (null: it doesn't yet).
    receive: ?Source = null,
    send: SendCapabilities = .{},
};

pub const OpenError = error{
    /// No received file has this handle (any more).
    InvalidHandle,
    Unsupported,
};

/// The page's event for a share.
pub const event = "share:received";

var receive_handler: std.atomic.Value(?ReceiveHandler) = .init(null);

/// Set (or clear, with null) the handler for shares. The page also gets
/// the `share:received` event with the `Received`. Shares that came before
/// (the one that launched the app) are handed to the first handler set, and
/// to the page when it listens: up to 8, then the oldest is dropped.
pub fn onReceive(handler: ?ReceiveHandler) void {
    receive_handler.store(handler, .release);
    if (handler != null) shares.handlerSet();
}

fn toHandler(share: *const Received) bool {
    const h = receive_handler.load(.acquire) orelse return false;
    h(share);
    return true;
}

const shares = pending_events.Queue(Received, event, 8, toHandler);

/// Report a share from a backend (main thread). `share` is copied.
pub fn dispatch(share: *const Received) void {
    shares.deliver(share.*);
}

/// A MIME type from a file name's extension (the page's File.type), for
/// backends whose OS gives a path, not a type.
pub fn mimeOf(name: []const u8) []const u8 {
    const ext = std.fs.path.extension(name);
    const table = [_]struct { []const u8, []const u8 }{
        .{ ".txt", "text/plain" },      .{ ".md", "text/markdown" },     .{ ".csv", "text/csv" },
        .{ ".html", "text/html" },      .{ ".htm", "text/html" },        .{ ".json", "application/json" },
        .{ ".xml", "application/xml" }, .{ ".pdf", "application/pdf" },  .{ ".zip", "application/zip" },
        .{ ".png", "image/png" },       .{ ".jpg", "image/jpeg" },       .{ ".jpeg", "image/jpeg" },
        .{ ".gif", "image/gif" },       .{ ".webp", "image/webp" },      .{ ".svg", "image/svg+xml" },
        .{ ".bmp", "image/bmp" },       .{ ".heic", "image/heic" },      .{ ".mp3", "audio/mpeg" },
        .{ ".wav", "audio/wav" },       .{ ".ogg", "audio/ogg" },        .{ ".m4a", "audio/mp4" },
        .{ ".flac", "audio/flac" },     .{ ".mp4", "video/mp4" },        .{ ".mov", "video/quicktime" },
        .{ ".webm", "video/webm" },     .{ ".mkv", "video/x-matroska" }, .{ ".avi", "video/x-msvideo" },
    };
    for (table) |t| if (std.ascii.eqlIgnoreCase(ext, t[0])) return t[1];
    return "application/octet-stream";
}

test "mimeOf" {
    try std.testing.expectEqualStrings("image/png", mimeOf("Photo.PNG"));
    try std.testing.expectEqualStrings("text/plain", mimeOf("notes.txt"));
    try std.testing.expectEqualStrings("application/octet-stream", mimeOf("noext"));
}

/// A canonical file directly inside the app's canonical Inbox, never a
/// traversal or an arbitrary directory containing "Documents/Inbox".
pub fn inboxBasename(inbox: []const u8, path: []const u8) ?[]const u8 {
    const parent = std.fs.path.dirnamePosix(path) orelse return null;
    if (!std.mem.eql(u8, parent, inbox)) return null;
    const name = std.fs.path.basenamePosix(path);
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return null;
    return name;
}

test "Inbox cleanup requires a direct child of the owned canonical directory" {
    const inbox = "/container/Documents/Inbox";
    try std.testing.expectEqualStrings("file.txt", inboxBasename(inbox, inbox ++ "/file.txt").?);
    for ([_][]const u8{
        "/other/Documents/Inbox/file.txt", inbox ++ "/../../Library/file.txt",
        inbox ++ "/nested/file.txt",       inbox ++ "/..",
        inbox ++ "/.",                     inbox ++ "-other/file.txt",
    }) |path| try std.testing.expect(inboxBasename(inbox, path) == null);
}
