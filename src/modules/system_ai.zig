//! The device's own language model, with nothing for the app to download
//! or ship: Gemini Nano through ML Kit's GenAI Prompt API (AICore) on
//! Android, Apple Foundation Models on iOS 26+ with Apple Intelligence.
//! `-Dsystem_ai`, Android and iOS only (elsewhere `available` is false; use
//! `chat` with llama.cpp, or a server).
//!
//!     if (oriel.system_ai.available) {
//!         const st = oriel.system_ai.status();
//!         if (st.state == .downloadable) try oriel.system_ai.download(io, null);
//!         const reply = try oriel.system_ai.generate(io, arena, .{ .prompt = "Name three herbs" }, onToken);
//!     }
//!
//! - Whether a device has the model is a runtime fact: `status()` (a phone
//!   without Gemini Nano, iOS before 26, Apple Intelligence off).
//! - Every call blocks on the platform: call from a worker (an async
//!   command, `oriel.App.spawn`), never the main thread.
//! - One generate or download at a time (error.Busy); `status` and
//!   `capabilities` answer meanwhile. `cancel()` stops it from any thread.
//! - Caps: prompt, system prompt and schema 64 KiB each, 4 images of 8 MiB,
//!   a 1 MiB reply (a longer stream is cancelled); timeouts of 20 s
//!   (status), 3 min (generate), 10 min (download).
//! - Pieces of the reply go to `on_token` (on the platform's thread) and to
//!   the page as "system_ai:token" `{ text }`; download progress to
//!   `on_progress` and "system_ai:download". The page has the same API as
//!   `oriel.systemAi` (src/modules/system_ai/bridge.zig).
//!
//! The backends are Oriel's own app extension "oriel.system_ai"
//! (docs/extensions.md): src/modules/system_ai/OrielSystemAi.kt and
//! SystemAi.swift, built only with -Dsystem_ai.

/// Built for this target (docs/modules.md, "Availability").
pub const available = true;

const std = @import("std");
const core = @import("system_ai/core.zig");
const extensions = @import("../core/extensions/runtime.zig");
const App = @import("../core/App.zig");

pub const State = core.State;
pub const Status = core.Status;
pub const Capabilities = core.Capabilities;
pub const Image = core.Image;
pub const Request = core.Request;
pub const Progress = core.Progress;
pub const DownloadState = core.DownloadState;
pub const TokenFn = core.TokenFn;
pub const ProgressFn = core.ProgressFn;
pub const Error = core.Error;
pub const max_prompt_bytes = core.max_prompt_bytes;
pub const max_images = core.max_images;
pub const max_image_bytes = core.max_image_bytes;
pub const max_response_bytes = core.max_response_bytes;

const extension = extensions.get("oriel.system_ai");

var session: core.Session = .{
    .backend = .{ .call = callExtension },
    .page = .{ .token = pageToken, .download = pageDownload },
};

fn callExtension(arena: std.mem.Allocator, method: []const u8, input: []const u8, options: extensions.CallOptions) extensions.Error![]u8 {
    // The extension's events (tokens, progress) come to the session first.
    extensions.setSink(extension.extension_name, onEvent);
    return extension.call(arena, method, input, options);
}

fn onEvent(event: []const u8, data: []const u8) void {
    session.onEvent(event, data);
}

fn pageToken(text: []const u8) void {
    App.emit("system_ai:token", .{ .text = text });
}

fn pageDownload(p: Progress) void {
    App.emit("system_ai:download", .{ .state = @tagName(p.state), .downloaded = p.downloaded, .total = p.total });
}

/// The last failure's code and message on this thread ("not_ready:
/// download Gemini Nano first"), for people.
threadlocal var last_error: extensions.Diagnostics = .{};
threadlocal var last_text: [last_text_len]u8 = undefined;
const last_text_len = @typeInfo(@FieldType(extensions.Diagnostics, "code_buf")).array.len + 2 +
    @typeInfo(@FieldType(extensions.Diagnostics, "message_buf")).array.len;

/// Whether the model is ready, downloadable, downloading or unavailable,
/// and why. Any thread but the main one (there it reads as unavailable).
pub fn status() Status {
    return session.status();
}

/// What the platform's model takes (cached by the platform, cheap).
pub fn capabilities() Capabilities {
    return session.capabilities();
}

/// Download the model where the platform does it on demand (Android's
/// AICore); returns when it's ready, error.Unavailable where there's
/// nothing to download. iOS downloads it with Apple Intelligence: this
/// returns at once when it's ready, else error.NotReady.
pub fn download(io: std.Io, on_progress: ?ProgressFn) Error!void {
    _ = io;
    last_error = .{};
    return session.download(on_progress, &last_error);
}

/// The model's reply to `req`, in `arena`. `on_token` sees it piece by
/// piece while it's generated (also when null, the page does).
pub fn generate(io: std.Io, arena: std.mem.Allocator, req: Request, on_token: ?TokenFn) Error![]const u8 {
    _ = io;
    last_error = .{};
    return session.generate(arena, req, on_token, &last_error);
}

/// Stop the running generate or download (any thread): it fails with
/// error.Cancelled.
pub fn cancel() void {
    session.cancel();
}

/// "<code>: <message>" of this thread's last failed `download` or
/// `generate` (the platform's own words), or "".
pub fn lastError() []const u8 {
    if (last_error.code_len == 0) return "";
    return std.fmt.bufPrint(&last_text, "{s}: {s}", .{ last_error.code(), last_error.message() }) catch last_error.message();
}

/// The page's `system_ai:<op>` commands (src/core/ipc.zig).
pub fn pageCall(arena: std.mem.Allocator, cmd: []const u8, args: std.json.Value) anyerror![]u8 {
    return core.pageCall(&session, arena, cmd, args);
}

test {
    std.testing.refAllDecls(core);
}
