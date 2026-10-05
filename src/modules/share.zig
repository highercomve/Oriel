//! Receiving what other apps share, and the system share sheet
//! (docs/platform-capabilities-design.md, section 5).
//!
//!     oriel.share.onReceive(onShare); // also the page's "share:received"
//!     try oriel.share.send(.{ .title = "Notes", .text = text }, null, null);
//!
//! Receiving is inert until build.zig declares `.share_target` (which also
//! turns this module on). Received files are handles: `open(handle)`
//! reads one, `release(id)` lets a share's files go.
//!
//! Written so far: Windows, sending (DataTransferManager) and receiving
//! (Send To and "Open with", from the installer's entries); macOS and
//! iOS, receiving "Open With" / "Open in" (CFBundleDocumentTypes from the
//! types) and sending (NSSharingServicePicker, UIActivityViewController).
//! Elsewhere
//! `send` and `open` return `error.Unsupported`, `capabilities()` reports
//! nothing, and nothing is received.

const std = @import("std");
const target = @import("../core/target.zig");
pub const common = @import("share/common.zig");

pub const Source = common.Source;
pub const File = common.File;
pub const Received = common.Received;
pub const ReceiveHandler = common.ReceiveHandler;
pub const OutFile = common.OutFile;
pub const Outgoing = common.Outgoing;
pub const Rect = common.Rect;
pub const Result = common.Result;
pub const DoneHandler = common.DoneHandler;
pub const SendError = common.SendError;
pub const Capabilities = common.Capabilities;
pub const SendCapabilities = common.SendCapabilities;
pub const OpenError = common.OpenError;

/// Set (or clear) the handler for received shares (main thread).
pub const onReceive = common.onReceive;

/// Open the system share sheet with `item`. `anchor`: where it points from
/// (iPad); `done` runs on the main thread when it closes.
pub fn send(item: Outgoing, anchor: ?Rect, done: ?DoneHandler) SendError!void {
    return impl.send(item, anchor, done);
}

/// What this platform can receive and send.
pub fn capabilities() Capabilities {
    return impl.capabilities();
}

/// A received file, read-only (the caller closes it).
pub fn open(handle: u32) OpenError!std.Io.File {
    return impl.open(handle);
}

/// Up to `len` bytes of a received file from `offset` (appended to `out`).
pub const read = common.read;

/// Let go of a share: its files' handles close and cached copies go.
pub fn release(id: u32) void {
    impl.release(id);
}

pub const check = impl.check;

pub const impl = switch (target.os) {
    .linux => @import("share/linux.zig"),
    .windows => @import("share/windows.zig"),
    .macos, .ios => @import("share/apple.zig"),
    .android => @import("share/android.zig"),
    .other => @compileError("share is not supported on " ++ target.name),
};

test {
    std.testing.refAllDecls(common);
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(impl);
}
