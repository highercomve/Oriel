//! oriel.system_ai's platform-independent half: the types, the limits, the
//! request's wire format to the platform backend, the replies' parsing, the
//! routing of streamed events to callbacks and the page, and the page's
//! commands. The backend is Oriel's own app extension "oriel.system_ai"
//! (Kotlin on Android, Swift on iOS; src/modules/system_ai.zig), reached
//! through a `Backend` so tests run it against a fake.
//!
//! The wire format of `generate`'s input: a little-endian u32 with the
//! JSON header's length, the header (`{"system", "prompt", "images":
//! [{"mime", "size"}], "temperature", "max_tokens", "schema", "stream"}`),
//! then each image's bytes in order. Replies are JSON: status `{"state",
//! "reason"}`, capabilities `{"images", "max_images", "streaming",
//! "structured_output", "max_input_tokens"}`, generate `{"text"}`. Events:
//! "token" (UTF-8 text, the reply's next piece) and "download" (`{"state",
//! "downloaded", "total"}`). Failures carry a code: unavailable, not_ready,
//! busy, cancelled, timeout, too_large, invalid_request (Swift's NSError
//! codes arrive as "<code>:<n>").

const std = @import("std");
const extensions = @import("../../core/extensions.zig");
const ipc = @import("../../core/ipc.zig");

const log = std.log.scoped(.system_ai);

/// The longest prompt, system prompt and schema (UTF-8 bytes each).
pub const max_prompt_bytes = 64 << 10;
pub const max_images = 4;
pub const max_image_bytes = 8 << 20;
/// The longest reply; a streamed reply past it is cancelled.
pub const max_response_bytes = 1 << 20;
/// `Request.max_tokens` at most.
pub const max_output_tokens = 8192;
pub const max_reason_len = 512;
pub const max_mime_len = 64;

pub const download_timeout_ms = 10 * 60 * 1000;
pub const generate_timeout_ms = 3 * 60 * 1000;
pub const status_timeout_ms = 20 * 1000;

comptime {
    // A request with every cap reached fits the extension's max_bytes
    // (build.zig, orielExtensions: 40 MiB).
    std.debug.assert(4 + 4 * max_prompt_bytes + max_images * (max_image_bytes + 256) < 40 << 20);
    std.debug.assert(download_timeout_ms <= extensions.max_timeout_ms);
}

pub const State = enum {
    /// Ready: `generate` works now.
    available,
    /// Supported, but the model must be downloaded first (`download`).
    downloadable,
    /// The system is downloading it (Android), or getting it ready (iOS).
    downloading,
    /// Not on this device, OS version or configuration; `reason` says why.
    unavailable,
};

pub const Status = struct {
    state: State = .unavailable,
    reason_buf: [max_reason_len]u8 = undefined,
    reason_len: usize = 0,

    /// For people: why it's unavailable, or what to do next.
    pub fn reason(s: *const Status) []const u8 {
        return s.reason_buf[0..s.reason_len];
    }

    /// `text` cut to fit (at a UTF-8 boundary).
    pub fn init(state: State, text: []const u8) Status {
        var s: Status = .{ .state = state };
        var n = @min(text.len, max_reason_len);
        while (n > 0 and n < text.len and (text[n] & 0xc0) == 0x80) n -= 1;
        @memcpy(s.reason_buf[0..n], text[0..n]);
        s.reason_len = n;
        return s;
    }
};

pub const Capabilities = struct {
    /// Image input (Android); Foundation Models takes text only for now.
    images: bool = false,
    /// Images per request (Gemini Nano: 1).
    max_images: u8 = 0,
    /// Replies arrive piece by piece (`on_token`, `system_ai:token`).
    streaming: bool = false,
    /// A schema the model is held to. False on both backends so far:
    /// `Request.schema` goes to the model as instructions.
    structured_output: bool = false,
    /// The context window (prompt and reply), 0 when unknown.
    max_input_tokens: u32 = 0,
};

pub const Image = struct {
    bytes: []const u8,
    /// "image/jpeg", "image/png", ...
    mime: []const u8,
};

pub const Request = struct {
    system: []const u8 = "",
    prompt: []const u8,
    images: []const Image = &.{},
    temperature: f32 = 0.2,
    max_tokens: u32 = 1024,
    /// A JSON schema the reply should follow (sent as instructions).
    schema: ?[]const u8 = null,
};

pub const DownloadState = enum { started, progress, completed, failed };

pub const Progress = struct {
    state: DownloadState,
    downloaded: u64 = 0,
    /// 0 when the platform doesn't say.
    total: u64 = 0,
};

/// A reply's next piece (whole UTF-8 characters), on the platform's
/// streaming thread: copy it out, keep it short.
pub const TokenFn = *const fn (text: []const u8) void;
/// On the platform's download thread.
pub const ProgressFn = *const fn (progress: Progress) void;

pub const Error = error{
    /// No model here: this device, OS version or configuration (`status`).
    Unavailable,
    /// Supported but not downloaded yet, or still downloading.
    NotReady,
    /// A generate or download is already running.
    Busy,
    Cancelled,
    Timeout,
    /// Over a cap: prompt, images, or the reply.
    TooLarge,
    InvalidRequest,
    /// Called on the main thread: call from a worker.
    WrongThread,
    /// The platform failed: `lastError()` has its code and message.
    Failed,
    OutOfMemory,
};

/// Check `req` against the caps before anything crosses to the platform.
pub fn validate(req: Request) Error!void {
    if (req.prompt.len == 0) return error.InvalidRequest;
    if (req.prompt.len > max_prompt_bytes or req.system.len > max_prompt_bytes) return error.TooLarge;
    if (!std.unicode.utf8ValidateSlice(req.prompt) or !std.unicode.utf8ValidateSlice(req.system)) return error.InvalidRequest;
    if (req.schema) |schema| {
        if (schema.len > max_prompt_bytes) return error.TooLarge;
        if (!std.unicode.utf8ValidateSlice(schema)) return error.InvalidRequest;
    }
    if (req.images.len > max_images) return error.TooLarge;
    for (req.images) |img| {
        if (img.bytes.len == 0) return error.InvalidRequest;
        if (img.bytes.len > max_image_bytes) return error.TooLarge;
        if (!validMime(img.mime)) return error.InvalidRequest;
    }
    if (!std.math.isFinite(req.temperature) or req.temperature < 0 or req.temperature > 2) return error.InvalidRequest;
    if (req.max_tokens == 0 or req.max_tokens > max_output_tokens) return error.InvalidRequest;
}

/// "image/<subtype>", printable ASCII, no quotes.
fn validMime(mime: []const u8) bool {
    if (mime.len <= "image/".len or mime.len > max_mime_len or !std.mem.startsWith(u8, mime, "image/")) return false;
    for (mime) |c| if (c <= 0x20 or c >= 0x7f or c == '"' or c == '\\') return false;
    return true;
}

/// `req` (validated) in the wire format, in `arena`.
pub fn encodeRequest(arena: std.mem.Allocator, req: Request, stream: bool) error{OutOfMemory}![]u8 {
    const ImageHeader = struct { mime: []const u8, size: usize };
    const headers = try arena.alloc(ImageHeader, req.images.len);
    var image_bytes: usize = 0;
    for (req.images, headers) |img, *h| {
        h.* = .{ .mime = img.mime, .size = img.bytes.len };
        image_bytes += img.bytes.len;
    }
    const header = try std.json.Stringify.valueAlloc(arena, .{
        .system = req.system,
        .prompt = req.prompt,
        .images = headers,
        .temperature = req.temperature,
        .max_tokens = req.max_tokens,
        .schema = req.schema,
        .stream = stream,
    }, .{});
    const out = try arena.alloc(u8, 4 + header.len + image_bytes);
    std.mem.writeInt(u32, out[0..4], @intCast(header.len), .little);
    @memcpy(out[4..][0..header.len], header);
    var at = 4 + header.len;
    for (req.images) |img| {
        @memcpy(out[at..][0..img.bytes.len], img.bytes);
        at += img.bytes.len;
    }
    return out;
}

/// A status reply; anything malformed reads as unavailable.
pub fn parseStatus(json: []const u8) Status {
    var buf: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const Reply = struct { state: []const u8, reason: []const u8 = "" };
    const r = std.json.parseFromSliceLeaky(Reply, fba.allocator(), json, .{ .ignore_unknown_fields = true, .allocate = .alloc_if_needed }) catch
        return .init(.unavailable, "System AI answered with a malformed status");
    const state = std.meta.stringToEnum(State, r.state) orelse return .init(.unavailable, r.reason);
    return .init(state, r.reason);
}

/// A capabilities reply; anything malformed reads as no capabilities.
pub fn parseCapabilities(json: []const u8) Capabilities {
    var buf: [2048]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const c = std.json.parseFromSliceLeaky(Capabilities, fba.allocator(), json, .{ .ignore_unknown_fields = true }) catch return .{};
    return .{
        .images = c.images and c.max_images > 0,
        .max_images = @min(c.max_images, max_images),
        .streaming = c.streaming,
        .structured_output = c.structured_output,
        .max_input_tokens = c.max_input_tokens,
    };
}

/// A generate reply's text, in `arena`.
pub fn parseReply(arena: std.mem.Allocator, json: []const u8) Error![]const u8 {
    const Reply = struct { text: []const u8 };
    const r = std.json.parseFromSliceLeaky(Reply, arena, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Failed,
    };
    if (r.text.len > max_response_bytes) return error.TooLarge;
    return r.text;
}

/// A backend's failure as this module's error: the code says which
/// (`Diagnostics`), up to its first ':' (Swift's "<domain>:<code>").
pub fn mapError(err: extensions.Error, diag: *const extensions.Diagnostics) Error {
    return switch (err) {
        error.Unavailable => error.Unavailable,
        error.Timeout => error.Timeout,
        error.Cancelled => error.Cancelled,
        error.TooLarge => error.TooLarge,
        error.WrongThread => error.WrongThread,
        error.Busy => error.Busy,
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidMethod => error.Failed,
        error.ExtensionFailed => {
            const code = diag.code();
            const kind = code[0 .. std.mem.indexOfScalar(u8, code, ':') orelse code.len];
            const Kind = enum { unavailable, not_ready, busy, cancelled, timeout, too_large, invalid_request, wrong_thread };
            const k = std.meta.stringToEnum(Kind, kind) orelse return error.Failed;
            return switch (k) {
                .unavailable => error.Unavailable,
                .not_ready => error.NotReady,
                .busy => error.Busy,
                .cancelled => error.Cancelled,
                .timeout => error.Timeout,
                .too_large => error.TooLarge,
                .invalid_request => error.InvalidRequest,
                .wrong_thread => error.WrongThread,
            };
        },
    };
}

/// How a session reaches the platform: `oriel.extensions` in the app, a
/// fake in tests. The reply goes in `arena`.
pub const Backend = struct {
    call: *const fn (arena: std.mem.Allocator, method: []const u8, input: []const u8, options: extensions.CallOptions) extensions.Error![]u8,
};

/// Where streamed events go besides the callbacks (`system_ai:token`,
/// `system_ai:download` in the app).
pub const PageHooks = struct {
    token: *const fn (text: []const u8) void,
    download: *const fn (progress: Progress) void,
};

/// The module's state: one generate or download at a time (status and
/// capabilities answer meanwhile), its callbacks, and its cancel token.
pub const Session = struct {
    backend: Backend,
    page: ?PageHooks = null,
    busy: std.atomic.Value(bool) = .init(false),
    cancel_token: extensions.CancelToken = .{},
    on_token: std.atomic.Value(?TokenFn) = .init(null),
    on_progress: std.atomic.Value(?ProgressFn) = .init(null),
    /// Bytes streamed by the running generate.
    streamed: std.atomic.Value(usize) = .init(0),

    pub fn status(s: *Session) Status {
        var buf: [16 << 10]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        var diag: extensions.Diagnostics = .{};
        const reply = s.backend.call(fba.allocator(), "status", "", .{ .timeout_ms = status_timeout_ms, .diag = &diag }) catch |err| return switch (err) {
            error.WrongThread => .init(.unavailable, "oriel.system_ai.status: call it from a worker thread, not the main one"),
            error.Unavailable => .init(.unavailable, "System AI isn't running (no app, or no backend in this build)"),
            error.Timeout => .init(.unavailable, "System AI didn't answer in time"),
            else => .init(.unavailable, if (diag.message().len > 0) diag.message() else @errorName(err)),
        };
        return parseStatus(reply);
    }

    pub fn capabilities(s: *Session) Capabilities {
        var buf: [8 << 10]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        const reply = s.backend.call(fba.allocator(), "capabilities", "", .{ .timeout_ms = status_timeout_ms }) catch return .{};
        return parseCapabilities(reply);
    }

    /// Download the model where the platform does it on demand; returns
    /// when it's ready. Progress goes to `on_progress` and the page.
    pub fn download(s: *Session, on_progress: ?ProgressFn, diag: *extensions.Diagnostics) Error!void {
        try s.begin();
        defer s.end();
        s.on_progress.store(on_progress, .release);
        var buf: [16 << 10]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        _ = s.backend.call(fba.allocator(), "download", "", .{ .timeout_ms = download_timeout_ms, .cancel = &s.cancel_token, .diag = diag }) catch |err| return mapError(err, diag);
    }

    /// The model's reply to `req`, in `arena`; pieces stream to `on_token`
    /// and the page as they come.
    pub fn generate(s: *Session, arena: std.mem.Allocator, req: Request, on_token: ?TokenFn, diag: *extensions.Diagnostics) Error![]const u8 {
        validate(req) catch |err| {
            diag.set(if (err == error.TooLarge) "too_large" else "invalid_request", requestProblem(req));
            return err;
        };
        try s.begin();
        defer s.end();
        s.on_token.store(on_token, .release);
        const input = try encodeRequest(arena, req, true);
        const reply = s.backend.call(arena, "generate", input, .{ .timeout_ms = generate_timeout_ms, .cancel = &s.cancel_token, .diag = diag }) catch |err| return mapError(err, diag);
        return parseReply(arena, reply);
    }

    /// Stop the running generate or download (any thread): it fails with
    /// error.Cancelled.
    pub fn cancel(s: *Session) void {
        if (s.busy.load(.acquire)) s.cancel_token.cancel();
    }

    fn begin(s: *Session) Error!void {
        if (s.busy.swap(true, .acq_rel)) return error.Busy;
        s.cancel_token.flag.store(false, .release);
        s.streamed.store(0, .release);
    }

    fn end(s: *Session) void {
        s.on_token.store(null, .release);
        s.on_progress.store(null, .release);
        s.busy.store(false, .release);
    }

    /// The extension's events (`extensions.setSink`), on the emitting thread.
    pub fn onEvent(s: *Session, event: []const u8, data: []const u8) void {
        if (std.mem.eql(u8, event, "token")) {
            const total = s.streamed.fetchAdd(data.len, .acq_rel) + data.len;
            if (total > max_response_bytes) {
                if (total - data.len <= max_response_bytes) log.warn("the reply passed {d} bytes: cancelled", .{max_response_bytes});
                s.cancel_token.cancel();
                return;
            }
            if (!std.unicode.utf8ValidateSlice(data)) return log.warn("dropped a token that isn't UTF-8", .{});
            if (s.on_token.load(.acquire)) |f| f(data);
            if (s.page) |p| p.token(data);
        } else if (std.mem.eql(u8, event, "download")) {
            const progress = parseProgress(data) orelse return log.warn("dropped a malformed download event", .{});
            if (s.on_progress.load(.acquire)) |f| f(progress);
            if (s.page) |p| p.download(progress);
        } else {
            log.warn("dropped unknown event \"{f}\"", .{std.zig.fmtString(event[0..@min(event.len, 64)])});
        }
    }
};

fn parseProgress(json: []const u8) ?Progress {
    var buf: [1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const P = struct { state: []const u8, downloaded: u64 = 0, total: u64 = 0 };
    const p = std.json.parseFromSliceLeaky(P, fba.allocator(), json, .{ .ignore_unknown_fields = true }) catch return null;
    return .{ .state = std.meta.stringToEnum(DownloadState, p.state) orelse return null, .downloaded = p.downloaded, .total = p.total };
}

/// What `validate` refused, for people.
fn requestProblem(req: Request) []const u8 {
    if (req.prompt.len == 0) return "the prompt is empty";
    if (req.prompt.len > max_prompt_bytes or req.system.len > max_prompt_bytes) return "the prompt or system prompt is over 64 KiB";
    if (req.schema) |schema| if (schema.len > max_prompt_bytes) return "the schema is over 64 KiB";
    if (req.images.len > max_images) return "more than 4 images";
    for (req.images) |img| {
        if (img.bytes.len > max_image_bytes) return "an image is over 8 MiB";
        if (img.bytes.len == 0 or !validMime(img.mime)) return "an image is empty or its MIME type isn't image/*";
    }
    if (req.max_tokens == 0 or req.max_tokens > max_output_tokens) return "max_tokens must be 1..8192";
    if (!std.math.isFinite(req.temperature) or req.temperature < 0 or req.temperature > 2) return "temperature must be 0..2";
    return "the prompt, system prompt or schema isn't UTF-8";
}

// ---------------------------------------------------------------------------
// The page (`oriel.systemAi`): Oriel's commands, run on an IPC worker
// ---------------------------------------------------------------------------

/// What the page's `system_ai:status` returns.
const PageStatus = struct { state: []const u8, reason: []const u8 };

/// `system_ai:<op>` from the page (src/core/ipc.zig): JSON in, JSON out.
pub fn pageCall(s: *Session, arena: std.mem.Allocator, cmd: []const u8, args: std.json.Value) anyerror![]u8 {
    const prefix = "system_ai:";
    const op = if (std.mem.startsWith(u8, cmd, prefix)) cmd[prefix.len..] else return error.UnknownCommand;
    const Op = enum { status, capabilities, download, generate, cancel };
    switch (std.meta.stringToEnum(Op, op) orelse return error.UnknownCommand) {
        .status => return pageStatus(arena, s.status()),
        .capabilities => {
            const c = s.capabilities();
            return std.json.Stringify.valueAlloc(arena, .{
                .images = c.images,
                .maxImages = c.max_images,
                .streaming = c.streaming,
                .structuredOutput = c.structured_output,
                .maxInputTokens = c.max_input_tokens,
            }, .{});
        },
        .download => {
            var diag: extensions.Diagnostics = .{};
            s.download(null, &diag) catch |err| return pageFail(err, &diag);
            return pageStatus(arena, s.status());
        },
        .generate => {
            var diag: extensions.Diagnostics = .{};
            const req = try pageRequest(arena, args, &diag);
            const text = s.generate(arena, req, null, &diag) catch |err| return pageFail(err, &diag);
            return std.json.Stringify.valueAlloc(arena, text, .{});
        },
        .cancel => {
            s.cancel();
            return arena.dupe(u8, "null");
        },
    }
}

fn pageStatus(arena: std.mem.Allocator, st: Status) ![]u8 {
    return std.json.Stringify.valueAlloc(arena, PageStatus{ .state = @tagName(st.state), .reason = st.reason() }, .{});
}

/// The page's error text: the platform's message when there is one.
fn pageFail(err: Error, diag: *const extensions.Diagnostics) anyerror {
    if (diag.message().len > 0) return ipc.fail("{s}: {s}", .{ @errorName(err), diag.message() });
    return err;
}

/// `oriel.systemAi.generate`'s arguments: images as base64 (the bridge
/// encodes Blobs and byte arrays), the schema as a string.
fn pageRequest(arena: std.mem.Allocator, args: std.json.Value, diag: *extensions.Diagnostics) anyerror!Request {
    const PageImage = struct { data: []const u8, mime: []const u8 = "image/jpeg" };
    const Args = struct {
        system: []const u8 = "",
        prompt: []const u8 = "",
        images: []const PageImage = &.{},
        temperature: f32 = 0.2,
        maxTokens: u32 = 1024,
        schema: ?[]const u8 = null,
    };
    const a = std.json.parseFromValueLeaky(Args, arena, args, .{ .ignore_unknown_fields = true }) catch
        return ipc.fail("system_ai.generate: expected {{ prompt, system?, images?: [{{ data, mime }}], temperature?, maxTokens?, schema? }}", .{});
    if (a.images.len > max_images) {
        diag.set("too_large", "more than 4 images");
        return pageFail(error.TooLarge, diag);
    }
    const images = try arena.alloc(Image, a.images.len);
    const dec = std.base64.standard.Decoder;
    for (a.images, images) |pi, *img| {
        const len = dec.calcSizeForSlice(pi.data) catch return ipc.fail("system_ai.generate: an image isn't base64", .{});
        if (len > max_image_bytes) {
            diag.set("too_large", "an image is over 8 MiB");
            return pageFail(error.TooLarge, diag);
        }
        const bytes = try arena.alloc(u8, len);
        dec.decode(bytes, pi.data) catch return ipc.fail("system_ai.generate: an image isn't base64", .{});
        img.* = .{ .bytes = bytes, .mime = pi.mime };
    }
    return .{
        .system = a.system,
        .prompt = a.prompt,
        .images = images,
        .temperature = a.temperature,
        .max_tokens = a.maxTokens,
        .schema = a.schema,
    };
}

// ---------------------------------------------------------------------------
// Tests (a fake backend)
// ---------------------------------------------------------------------------

const testing = std.testing;

test validate {
    try validate(.{ .prompt = "hi" });
    try testing.expectError(error.InvalidRequest, validate(.{ .prompt = "" }));
    try testing.expectError(error.TooLarge, validate(.{ .prompt = &(@as([max_prompt_bytes + 1]u8, @splat('a'))) }));
    try testing.expectError(error.TooLarge, validate(.{ .prompt = "x", .system = &(@as([max_prompt_bytes + 1]u8, @splat('a'))) }));
    try testing.expectError(error.TooLarge, validate(.{ .prompt = "x", .schema = &(@as([max_prompt_bytes + 1]u8, @splat('a'))) }));
    try testing.expectError(error.InvalidRequest, validate(.{ .prompt = "\xff" }));
    const img: Image = .{ .bytes = "jpeg", .mime = "image/jpeg" };
    try validate(.{ .prompt = "x", .images = &.{ img, img, img, img } });
    try testing.expectError(error.TooLarge, validate(.{ .prompt = "x", .images = &.{ img, img, img, img, img } }));
    try testing.expectError(error.InvalidRequest, validate(.{ .prompt = "x", .images = &.{.{ .bytes = "", .mime = "image/png" }} }));
    try testing.expectError(error.InvalidRequest, validate(.{ .prompt = "x", .images = &.{.{ .bytes = "a", .mime = "text/plain" }} }));
    try testing.expectError(error.InvalidRequest, validate(.{ .prompt = "x", .images = &.{.{ .bytes = "a", .mime = "image/" }} }));
    try testing.expectError(error.InvalidRequest, validate(.{ .prompt = "x", .temperature = -0.1 }));
    try testing.expectError(error.InvalidRequest, validate(.{ .prompt = "x", .temperature = std.math.nan(f32) }));
    try testing.expectError(error.InvalidRequest, validate(.{ .prompt = "x", .max_tokens = 0 }));
    try testing.expectError(error.InvalidRequest, validate(.{ .prompt = "x", .max_tokens = max_output_tokens + 1 }));
}

test "an image over 8 MiB is refused" {
    const big = try testing.allocator.alloc(u8, max_image_bytes + 1);
    defer testing.allocator.free(big);
    try testing.expectError(error.TooLarge, validate(.{ .prompt = "x", .images = &.{.{ .bytes = big, .mime = "image/png" }} }));
}

test encodeRequest {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const out = try encodeRequest(arena, .{ .system = "be brief", .prompt = "what's this?", .images = &.{ .{ .bytes = "AB", .mime = "image/png" }, .{ .bytes = "CDE", .mime = "image/jpeg" } }, .schema = "{}" }, true);
    const n = std.mem.readInt(u32, out[0..4], .little);
    const header = out[4..][0..n];
    try testing.expectEqualStrings("ABCDE", out[4 + n ..]);
    const H = struct {
        system: []const u8,
        prompt: []const u8,
        images: []const struct { mime: []const u8, size: usize },
        temperature: f32,
        max_tokens: u32,
        schema: ?[]const u8,
        stream: bool,
    };
    const h = try std.json.parseFromSliceLeaky(H, arena, header, .{});
    try testing.expectEqualStrings("be brief", h.system);
    try testing.expectEqualStrings("what's this?", h.prompt);
    try testing.expectEqual(@as(usize, 2), h.images.len);
    try testing.expectEqualStrings("image/jpeg", h.images[1].mime);
    try testing.expectEqual(@as(usize, 3), h.images[1].size);
    try testing.expectEqual(@as(u32, 1024), h.max_tokens);
    try testing.expectEqualStrings("{}", h.schema.?);
    try testing.expect(h.stream);
}

test parseStatus {
    const a = parseStatus("{\"state\":\"downloadable\",\"reason\":\"download it first\"}");
    try testing.expectEqual(State.downloadable, a.state);
    try testing.expectEqualStrings("download it first", a.reason());
    const b = parseStatus("{\"state\":\"available\"}");
    try testing.expectEqual(State.available, b.state);
    try testing.expectEqualStrings("", b.reason());
    const c = parseStatus("{\"state\":\"sleeping\",\"reason\":\"why\"}");
    try testing.expectEqual(State.unavailable, c.state);
    try testing.expectEqualStrings("why", c.reason());
    const d = parseStatus("not json");
    try testing.expectEqual(State.unavailable, d.state);
    try testing.expect(d.reason().len > 0);
    // Long reasons are cut at a character boundary.
    const long = "é" ** 400;
    const e = Status.init(.unavailable, long);
    try testing.expect(e.reason().len <= max_reason_len);
    try testing.expect(std.unicode.utf8ValidateSlice(e.reason()));
}

test parseCapabilities {
    const c = parseCapabilities("{\"images\":true,\"max_images\":9,\"streaming\":true,\"structured_output\":false,\"max_input_tokens\":4000,\"extra\":1}");
    try testing.expect(c.images and c.streaming and !c.structured_output);
    try testing.expectEqual(@as(u8, max_images), c.max_images);
    try testing.expectEqual(@as(u32, 4000), c.max_input_tokens);
    const none = parseCapabilities("{\"images\":true,\"max_images\":0}");
    try testing.expect(!none.images);
    try testing.expectEqual(Capabilities{}, parseCapabilities("[]"));
}

test mapError {
    var d: extensions.Diagnostics = .{};
    d.set("not_ready", "download first");
    try testing.expectEqual(error.NotReady, mapError(error.ExtensionFailed, &d));
    d.set("unavailable:1", "needs iOS 26");
    try testing.expectEqual(error.Unavailable, mapError(error.ExtensionFailed, &d));
    d.set("GenAiException", "x");
    try testing.expectEqual(error.Failed, mapError(error.ExtensionFailed, &d));
    try testing.expectEqual(error.WrongThread, mapError(error.WrongThread, &d));
    try testing.expectEqual(error.Timeout, mapError(error.Timeout, &d));
}

/// A backend that answers like the Kotlin one and emits through the
/// session, as the extension's sink would.
const FakeBackend = struct {
    var session: *Session = undefined;
    var last_input: [256]u8 = undefined;
    var last_input_len: usize = 0;
    var state: []const u8 = "available";
    var fail_code: ?[]const u8 = null;
    var flood = false;

    fn call(arena: std.mem.Allocator, method: []const u8, input: []const u8, options: extensions.CallOptions) extensions.Error![]u8 {
        if (fail_code) |code| {
            if (options.diag) |d| d.set(code, "the fake says no");
            return error.ExtensionFailed;
        }
        if (std.mem.eql(u8, method, "status"))
            return std.fmt.allocPrint(arena, "{{\"state\":\"{s}\",\"reason\":\"fake\"}}", .{state}) catch error.OutOfMemory;
        if (std.mem.eql(u8, method, "capabilities"))
            return arena.dupe(u8, "{\"images\":true,\"max_images\":1,\"streaming\":true,\"structured_output\":false,\"max_input_tokens\":4096}") catch error.OutOfMemory;
        if (std.mem.eql(u8, method, "download")) {
            session.onEvent("download", "{\"state\":\"started\",\"downloaded\":0,\"total\":100}");
            session.onEvent("download", "{\"state\":\"progress\",\"downloaded\":50,\"total\":100}");
            session.onEvent("download", "{\"state\":\"completed\",\"downloaded\":100,\"total\":100}");
            return arena.dupe(u8, "{}") catch error.OutOfMemory;
        }
        if (std.mem.eql(u8, method, "generate")) {
            last_input_len = @min(input.len, last_input.len);
            @memcpy(last_input[0..last_input_len], input[0..last_input_len]);
            if (flood) {
                // Past the reply cap: the session cancels; a real backend
                // then sees isCancelled.
                const chunk: [64 << 10]u8 = @splat('x');
                for (0..(max_response_bytes / chunk.len) + 2) |_| session.onEvent("token", &chunk);
                if (options.cancel) |t| if (t.isCancelled()) return error.Cancelled;
                return error.Timeout;
            }
            session.onEvent("token", "Hel");
            session.onEvent("token", "lo");
            session.onEvent("nonsense", "x");
            return arena.dupe(u8, "{\"text\":\"Hello\"}") catch error.OutOfMemory;
        }
        return error.InvalidMethod;
    }
};

const Seen = struct {
    var tokens: [64]u8 = undefined;
    var tokens_len: usize = 0;
    var page_tokens: usize = 0;
    var progress: [8]Progress = undefined;
    var progress_len: usize = 0;
    var page_progress: usize = 0;

    fn reset() void {
        tokens_len = 0;
        page_tokens = 0;
        progress_len = 0;
        page_progress = 0;
    }
    fn token(text: []const u8) void {
        const n = @min(text.len, tokens.len - tokens_len);
        @memcpy(tokens[tokens_len..][0..n], text[0..n]);
        tokens_len += n;
    }
    fn pageToken(_: []const u8) void {
        page_tokens += 1;
    }
    fn onProgress(p: Progress) void {
        if (progress_len < progress.len) {
            progress[progress_len] = p;
            progress_len += 1;
        }
    }
    fn pageDownload(_: Progress) void {
        page_progress += 1;
    }
};

fn fakeSession() Session {
    return .{ .backend = .{ .call = FakeBackend.call }, .page = .{ .token = Seen.pageToken, .download = Seen.pageDownload } };
}

test "generate: tokens reach the callback and the page, the reply comes back" {
    Seen.reset();
    FakeBackend.fail_code = null;
    FakeBackend.flood = false;
    var s = fakeSession();
    FakeBackend.session = &s;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var diag: extensions.Diagnostics = .{};
    const text = try s.generate(arena_state.allocator(), .{ .prompt = "hi", .system = "sys" }, Seen.token, &diag);
    try testing.expectEqualStrings("Hello", text);
    try testing.expectEqualStrings("Hello", Seen.tokens[0..Seen.tokens_len]);
    try testing.expectEqual(@as(usize, 2), Seen.page_tokens);
    // The callbacks are dropped once the call returns.
    try testing.expect(s.on_token.load(.acquire) == null);
    try testing.expect(!s.busy.load(.acquire));
    // The request crossed in the wire format.
    const n = std.mem.readInt(u32, FakeBackend.last_input[0..4], .little);
    try testing.expect(std.mem.indexOf(u8, FakeBackend.last_input[4..][0..n], "\"prompt\":\"hi\"") != null);
    // Refused before it crosses, with a reason.
    try testing.expectError(error.InvalidRequest, s.generate(arena_state.allocator(), .{ .prompt = "" }, null, &diag));
    try testing.expectEqualStrings("invalid_request", diag.code());
    try testing.expectEqualStrings("the prompt is empty", diag.message());
}

test "download: progress events reach the callback and the page" {
    Seen.reset();
    FakeBackend.fail_code = null;
    var s = fakeSession();
    FakeBackend.session = &s;
    var diag: extensions.Diagnostics = .{};
    try s.download(Seen.onProgress, &diag);
    try testing.expectEqual(@as(usize, 3), Seen.progress_len);
    try testing.expectEqual(DownloadState.progress, Seen.progress[1].state);
    try testing.expectEqual(@as(u64, 50), Seen.progress[1].downloaded);
    try testing.expectEqual(@as(u64, 100), Seen.progress[2].total);
    try testing.expectEqual(@as(usize, 3), Seen.page_progress);
    // Events outside an operation reach only the page.
    s.onEvent("download", "{\"state\":\"progress\",\"downloaded\":1}");
    try testing.expectEqual(@as(usize, 3), Seen.progress_len);
    try testing.expectEqual(@as(usize, 4), Seen.page_progress);
    s.onEvent("download", "{\"state\":\"bogus\"}");
    try testing.expectEqual(@as(usize, 4), Seen.page_progress);
}

test "single flight, status mapping, failures" {
    Seen.reset();
    var s = fakeSession();
    FakeBackend.session = &s;
    FakeBackend.fail_code = null;
    FakeBackend.state = "downloading";
    try testing.expectEqual(State.downloading, s.status().state);
    FakeBackend.state = "available";
    try testing.expectEqual(State.available, s.status().state);
    try testing.expectEqual(@as(u32, 4096), s.capabilities().max_input_tokens);

    var diag: extensions.Diagnostics = .{};
    s.busy.store(true, .release);
    try testing.expectError(error.Busy, s.download(null, &diag));
    s.busy.store(false, .release);

    FakeBackend.fail_code = "not_ready";
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.NotReady, s.generate(arena_state.allocator(), .{ .prompt = "hi" }, null, &diag));
    try testing.expectEqualStrings("the fake says no", diag.message());
    try testing.expectEqual(State.unavailable, s.status().state);
    try testing.expectEqualStrings("the fake says no", s.status().reason());
    FakeBackend.fail_code = null;
}

test "a reply past the cap is cancelled" {
    Seen.reset();
    FakeBackend.fail_code = null;
    FakeBackend.flood = true;
    defer FakeBackend.flood = false;
    var s = fakeSession();
    FakeBackend.session = &s;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var diag: extensions.Diagnostics = .{};
    try testing.expectError(error.Cancelled, s.generate(arena_state.allocator(), .{ .prompt = "hi" }, null, &diag));
    try testing.expect(Seen.page_tokens <= max_response_bytes / (64 << 10));
}

test "the page's commands" {
    Seen.reset();
    FakeBackend.fail_code = null;
    var s = fakeSession();
    FakeBackend.session = &s;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = struct {
        fn of(a: std.mem.Allocator, json: []const u8) !std.json.Value {
            return std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
        }
    };
    try testing.expectEqualStrings("{\"state\":\"available\",\"reason\":\"fake\"}", try pageCall(&s, arena, "system_ai:status", .null));
    try testing.expect(std.mem.indexOf(u8, try pageCall(&s, arena, "system_ai:capabilities", .null), "\"maxInputTokens\":4096") != null);
    try testing.expectEqualStrings("\"Hello\"", try pageCall(&s, arena, "system_ai:generate", try args.of(arena, "{\"prompt\":\"hi\",\"images\":[{\"data\":\"QUJD\",\"mime\":\"image/png\"}],\"maxTokens\":64}")));
    const n = std.mem.readInt(u32, FakeBackend.last_input[0..4], .little);
    try testing.expectEqualStrings("ABC", FakeBackend.last_input[4 + n .. FakeBackend.last_input_len]);
    try testing.expectEqualStrings("null", try pageCall(&s, arena, "system_ai:cancel", .null));
    try testing.expectError(error.CommandFailed, pageCall(&s, arena, "system_ai:generate", try args.of(arena, "{\"prompt\":\"hi\",\"images\":[{\"data\":\"***\"}]}")));
    try testing.expectError(error.UnknownCommand, pageCall(&s, arena, "system_ai:nope", .null));
    FakeBackend.fail_code = "unavailable";
    try testing.expectError(error.CommandFailed, pageCall(&s, arena, "system_ai:generate", try args.of(arena, "{\"prompt\":\"hi\"}")));
    try testing.expectEqualStrings("Unavailable: the fake says no", ipc.errorText(error.CommandFailed));
    FakeBackend.fail_code = null;
}
