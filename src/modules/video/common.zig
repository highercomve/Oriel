//! What every video backend shares: the options, which URLs a player takes
//! (`classify`), the URL now playing, and the page's events
//! (`video:closed`, `video:ended`, `video:error`).

const std = @import("std");
const heap = @import("../../core/heap.zig");
const internal = @import("../../core/internal.zig");

pub const Options = struct {
    /// What to play: `http(s)://` (the media server's URLs) or `file://`;
    /// on Android also `content://` and the app's media URLs
    /// (`https://app.localhost/media/<path>`).
    url: []const u8,
    /// Shown at the top of the player ("" for none; an embedded player
    /// shows none: the page around it has the title).
    title: []const u8 = "",
    /// Embedded: the player sits over this rectangle of the page, in CSS
    /// pixels of the window's viewport, under the page's own bar and
    /// buttons; `setRect` follows the page's layout. Null covers the window.
    rect: ?Rect = null,
};

/// A rectangle of the page, in CSS pixels from the viewport's top left.
pub const Rect = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,

    /// Finite, inside a sane range, and not empty.
    pub fn valid(r: Rect) bool {
        const limit = 1_000_000.0;
        inline for (.{ r.x, r.y, r.width, r.height }) |v| if (!std.math.isFinite(v) or @abs(v) > limit) return false;
        return r.width >= 1 and r.height >= 1;
    }
};

pub const Error = error{
    /// Not on this platform or in this build.
    Unsupported,
    /// A scheme the player can't open, an empty or too long URL, or
    /// control characters in it.
    InvalidUrl,
    /// No window to show the player over (Android: no Activity yet).
    NoWindow,
    /// The app isn't running (before `oriel.run`, or quitting).
    AppNotRunning,
    /// The platform refused (Android: the media file isn't there).
    Failed,
    /// An embedded player's rectangle isn't finite, or is empty.
    InvalidRect,
    OutOfMemory,
};

/// The longest URL a player takes.
pub const max_url_len = 8192;
/// The longest title shown.
pub const max_title_len = 1024;

/// How a backend opens a URL (Android's OrielVideo takes it as an int).
pub const UrlKind = enum(i32) {
    /// http:// or https://, fetched by the platform's player.
    remote = 0,
    file = 1,
    /// Android's content:// (a document from the system's picker).
    content = 2,
    /// The app's own media URL on Android (`media_scheme.base_url`): the
    /// player reads the media source or the root's file itself, as
    /// OrielMedia serves them to the WebView.
    app_media = 3,
};

/// The URLs a platform's player takes, besides http(s) and file.
pub const Rules = struct {
    /// The app's media URLs (`<app_media><path>`), read in-process.
    app_media: ?[]const u8 = null,
    content: bool = false,
};

/// The rules on desktop Linux: GStreamer fetches http(s) and reads files;
/// `app://` exists only inside the WebView.
pub const linux_rules: Rules = .{};
/// Android: MediaPlayer, plus the app's media URLs and content://.
pub const android_rules: Rules = .{ .app_media = "https://app.localhost/media/", .content = true };

/// `url`'s kind under `rules`, or error.InvalidUrl.
pub fn classify(url: []const u8, rules: Rules) error{InvalidUrl}!UrlKind {
    if (url.len == 0 or url.len > max_url_len) return error.InvalidUrl;
    for (url) |c| if (c < 0x20 or c == 0x7f) return error.InvalidUrl;
    if (rules.app_media) |base| {
        // The scheme and host in any case (as the WebView compares them),
        // the path as OrielMedia matches it.
        const origin_len = std.mem.indexOfScalarPos(u8, base, "https://".len, '/') orelse base.len;
        if (url.len >= origin_len and std.ascii.eqlIgnoreCase(url[0..origin_len], base[0..origin_len]) and
            (url.len == origin_len or url[origin_len] == '/' or url[origin_len] == '?' or url[origin_len] == '#'))
        {
            // The app's own origin: only its media are files a player can read.
            if (!std.mem.startsWith(u8, url[origin_len..], base[origin_len..])) return error.InvalidUrl;
            const rest = url[base.len..];
            const end = std.mem.indexOfAny(u8, rest, "?#") orelse rest.len;
            if (end == 0) return error.InvalidUrl;
            return .app_media;
        }
    }
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return error.InvalidUrl;
    const scheme = url[0..colon];
    const rest = url[colon + 1 ..];
    if (std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "https")) {
        if (!std.mem.startsWith(u8, rest, "//") or rest.len == 2) return error.InvalidUrl;
        return .remote;
    }
    if (std.ascii.eqlIgnoreCase(scheme, "file")) {
        if (!std.mem.startsWith(u8, rest, "//") or rest.len == 2) return error.InvalidUrl;
        return .file;
    }
    if (rules.content and std.ascii.eqlIgnoreCase(scheme, "content")) {
        if (!std.mem.startsWith(u8, rest, "//") or rest.len == 2) return error.InvalidUrl;
        return .content;
    }
    return error.InvalidUrl;
}

/// Check `options` for `rules`: the URL's kind.
pub fn validate(options: Options, rules: Rules) Error!UrlKind {
    if (options.title.len > max_title_len) return error.InvalidUrl;
    if (options.rect) |r| if (!r.valid()) return error.InvalidRect;
    return classify(options.url, rules);
}

// --- The URL playing, and the page's events (main thread) ----------------

/// The URL the player shows (owned, `heap.gpa`), for the events' payloads.
var playing: ?[:0]u8 = null;
/// Whether the player shows fullscreen (`video:fullscreen` on a change).
var is_fullscreen = false;

/// `url` as the URL playing (the player was just shown), replacing any.
/// Takes ownership of `url`.
pub fn adopt(url: [:0]u8) void {
    if (playing) |old| heap.gpa.free(old);
    playing = url;
    is_fullscreen = false;
}

/// The player went fullscreen or came back (its button, Esc, Back,
/// `setFullscreen`): `video:fullscreen` when that changed.
pub fn fullscreenChanged(on: bool) void {
    const url = playing orelse return;
    if (on == is_fullscreen) return;
    is_fullscreen = on;
    internal.emit("video:fullscreen", Event{ .url = url, .fullscreen = on });
}

/// The player was closed: `video:closed`, and nothing plays any more.
pub fn closed() void {
    const url = playing orelse return;
    playing = null;
    is_fullscreen = false;
    defer heap.gpa.free(url);
    internal.emit("video:closed", Event{ .url = url });
}

/// The video played to its end: `video:ended` (the player stays open).
pub fn ended() void {
    const url = playing orelse return;
    internal.emit("video:ended", Event{ .url = url });
}

/// The video plays but its sound can't be decoded on this device (AC3 or
/// DTS on most phones): `video:audio-unsupported`. The player says so
/// itself and stays open.
pub fn audioUnsupported() void {
    const url = playing orelse return;
    internal.emit("video:audio-unsupported", Event{ .url = url });
}

/// Playback failed: `video:error` with the platform's message (the player
/// stays open until it is closed).
pub fn failed(message: []const u8) void {
    const url = playing orelse return;
    internal.emit("video:error", Event{ .url = url, .message = message });
}

/// The events' payload: `{ url }`, `message` on `video:error`,
/// `fullscreen` on `video:fullscreen`.
pub const Event = struct {
    url: []const u8,
    message: ?[]const u8 = null,
    fullscreen: ?bool = null,

    pub fn jsonStringify(self: Event, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("url");
        try jw.write(self.url);
        if (self.message) |m| {
            try jw.objectField("message");
            try jw.write(m);
        }
        if (self.fullscreen) |f| {
            try jw.objectField("fullscreen");
            try jw.write(f);
        }
        try jw.endObject();
    }
};

/// Whether a player is showing (main thread).
pub fn isPlaying() bool {
    return playing != null;
}

test classify {
    const t = std.testing;
    try t.expectEqual(UrlKind.remote, try classify("http://127.0.0.1:8123/tok/a.mts", linux_rules));
    try t.expectEqual(UrlKind.remote, try classify("HTTPS://example.com/v.mp4", linux_rules));
    try t.expectEqual(UrlKind.file, try classify("file:///tmp/vbench/pixel.mp4", linux_rules));
    try t.expectError(error.InvalidUrl, classify("", linux_rules));
    try t.expectError(error.InvalidUrl, classify("http://", linux_rules));
    try t.expectError(error.InvalidUrl, classify("/tmp/a.mp4", linux_rules));
    try t.expectError(error.InvalidUrl, classify("javascript:alert(1)", linux_rules));
    try t.expectError(error.InvalidUrl, classify("app://app/media/a.mp4", linux_rules));
    try t.expectError(error.InvalidUrl, classify("content://media/external/video/1", linux_rules));
    try t.expectError(error.InvalidUrl, classify("http://a/b\nc", linux_rules));
    try t.expectError(error.InvalidUrl, classify("file:///a\x00", linux_rules));
    // On the desktop, app.localhost is just a host (nothing serves it).
    try t.expectEqual(UrlKind.remote, try classify("https://app.localhost/media/a.mp4", linux_rules));
    const long = [_]u8{'a'} ** (max_url_len + 1);
    try t.expectError(error.InvalidUrl, classify("http://" ++ long, linux_rules));
}

test "classify: Android's app media URLs" {
    const t = std.testing;
    const r = android_rules;
    try t.expectEqual(UrlKind.app_media, try classify("https://app.localhost/media/clips/a%20b.mts", r));
    try t.expectEqual(UrlKind.app_media, try classify("HTTPS://App.Localhost/media/a.mp4?t=3", r));
    try t.expectEqual(UrlKind.content, try classify("content://com.android.providers.media.documents/document/video%3A12", r));
    try t.expectEqual(UrlKind.remote, try classify("http://192.168.1.4:8000/a.mp4", r));
    try t.expectEqual(UrlKind.remote, try classify("https://app.localhost.example.com/media/a.mp4", r));
    try t.expectEqual(UrlKind.file, try classify("file:///sdcard/Movies/a.mp4", r));
    // The app's origin but not its media: the WebView serves those, a player can't.
    try t.expectError(error.InvalidUrl, classify("https://app.localhost/index.html", r));
    try t.expectError(error.InvalidUrl, classify("https://app.localhost", r));
    try t.expectError(error.InvalidUrl, classify("https://app.localhost/media/", r));
    try t.expectError(error.InvalidUrl, classify("https://app.localhost/media/?x", r));
    try t.expectError(error.InvalidUrl, classify("https://app.localhost/Media/a.mp4", r));
}

test Rect {
    try std.testing.expect((Rect{ .x = 0, .y = 64, .width = 412, .height = 700 }).valid());
    try std.testing.expect(!(Rect{ .x = 0, .y = 0, .width = 0, .height = 10 }).valid());
    try std.testing.expect(!(Rect{ .x = std.math.nan(f64), .y = 0, .width = 1, .height = 1 }).valid());
    try std.testing.expect(!(Rect{ .x = 0, .y = 0, .width = std.math.inf(f64), .height = 1 }).valid());
    try std.testing.expectError(error.InvalidRect, validate(.{ .url = "file:///a.mp4", .rect = .{ .x = 0, .y = 0, .width = -5, .height = 1 } }, linux_rules));
}

test validate {
    try std.testing.expectEqual(UrlKind.file, try validate(.{ .url = "file:///a.mp4", .title = "A" }, linux_rules));
    const long = [_]u8{'t'} ** (max_title_len + 1);
    try std.testing.expectError(error.InvalidUrl, validate(.{ .url = "file:///a.mp4", .title = &long }, linux_rules));
}

test Event {
    const t = std.testing;
    const a = try std.json.Stringify.valueAlloc(t.allocator, Event{ .url = "file:///a.mp4" }, .{});
    defer t.allocator.free(a);
    try t.expectEqualStrings("{\"url\":\"file:///a.mp4\"}", a);
    const b = try std.json.Stringify.valueAlloc(t.allocator, Event{ .url = "u", .message = "no \"decoder\"" }, .{});
    defer t.allocator.free(b);
    try t.expectEqualStrings("{\"url\":\"u\",\"message\":\"no \\\"decoder\\\"\"}", b);
    const c = try std.json.Stringify.valueAlloc(t.allocator, Event{ .url = "u", .fullscreen = true }, .{});
    defer t.allocator.free(c);
    try t.expectEqualStrings("{\"url\":\"u\",\"fullscreen\":true}", c);
}
