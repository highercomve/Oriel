//! oriel.share's shared part: what is received and sent, and the receive
//! handler. Each OS backend provides `send`, `capabilities` and `open`, and
//! reports what it receives with `dispatch`.

const std = @import("std");
const App = @import("../../core/App.zig");
const pending_events = @import("../../core/pending_events.zig");

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

fn toHandler(received: *const Received) bool {
    const h = receive_handler.load(.acquire) orelse return false;
    h(received);
    return true;
}

const shares = pending_events.Queue(Received, event, 8, toHandler);

/// Report a share from a backend (main thread). `received` is copied.
pub fn dispatch(received: *const Received) void {
    shares.deliver(received.*);
}
