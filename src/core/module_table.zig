//! Where each module exists, shared by build.zig (resolving the app's flags
//! per target) and src/oriel.zig (`oriel.<module>.available`, and the build
//! error of an unguarded use). No `builtin` here: build.zig imports it for
//! the target being built, not the build machine.

const std = @import("std");

/// The OS family, with Android split out of Linux (`target.os`).
pub const Platform = enum { linux, android, windows, macos, ios, other };

pub fn platformOf(t: *const std.Target) Platform {
    if (t.abi.isAndroid()) return .android;
    return switch (t.os.tag) {
        .linux => .linux,
        .windows => .windows,
        .macos => .macos,
        .ios => .ios,
        else => .other,
    };
}

/// Feature flags with no backend on a platform. An app's `.tray = true`
/// means "where it exists": there it resolves to off, and
/// `oriel.tray.available` is false.
pub fn missingOn(platform: Platform) []const []const u8 {
    return switch (platform) {
        .linux, .other => &.{},
        // global_shortcut (in-app shortcuts), fs_watch (inotify) and updater
        // (checking for a release) have real Android backends.
        .android => &.{ "tray", "menu", "input", "media_server", "layer_shell" },
        .ios => &.{ "tray", "updater", "menu", "global_shortcut", "input", "media_server", "layer_shell", "fs_watch" },
        // gtk4-layer-shell is a Wayland thing.
        .windows, .macos => &.{"layer_shell"},
    };
}

pub fn supported(feature: []const u8, platform: Platform) bool {
    for (missingOn(platform)) |m| {
        if (std.mem.eql(u8, m, feature)) return false;
    }
    return true;
}

/// An `oriel.<name>` namespace: its facade (the shim generator reads its pub
/// decls), the flag whose platforms it follows, and how to turn it on.
pub const Namespace = struct {
    name: []const u8,
    path: []const u8,
    feature: []const u8,
    enable: []const u8,
};

fn ns(comptime name: []const u8, comptime path: []const u8) Namespace {
    return .{ .name = name, .path = path, .feature = name, .enable = "." ++ name ++ " = true" };
}

pub const namespaces = [_]Namespace{
    ns("tray", "src/modules/tray.zig"),
    ns("updater", "src/modules/updater.zig"),
    ns("media_server", "src/modules/media_server.zig"),
    ns("sql", "src/modules/sql.zig"),
    ns("fs_watch", "src/modules/fs_watch.zig"),
    ns("dialog", "src/modules/dialog.zig"),
    ns("notification", "src/modules/notification.zig"),
    ns("store", "src/modules/store.zig"),
    ns("menu", "src/modules/menu.zig"),
    ns("deep_link", "src/modules/deep_link.zig"),
    ns("network", "src/modules/network.zig"),
    ns("share", "src/modules/share.zig"),
    ns("camera", "src/modules/camera.zig"),
    ns("sqlite_vec", "src/modules/sqlite_vec.zig"),
    ns("llama", "src/modules/llama.zig"),
    ns("whisper", "src/modules/whisper.zig"),
    ns("kokoro", "src/modules/kokoro.zig"),
    .{ .name = "audio_play", .path = "src/modules/audio_play.zig", .feature = "kokoro", .enable = ".kokoro = true" },
    .{ .name = "tts", .path = "src/modules/tts.zig", .feature = "kokoro", .enable = ".kokoro = true" },
    ns("audio_capture", "src/modules/audio_capture.zig"),
    .{ .name = "ggml_gpu", .path = "src/modules/ggml_gpu.zig", .feature = "llama", .enable = ".llama = true or .whisper = true" },
    .{ .name = "chat", .path = "src/modules/chat.zig", .feature = "llama", .enable = ".llama = true" },
    .{ .name = "dictation", .path = "src/modules/dictation.zig", .feature = "whisper", .enable = ".whisper = true and .audio_capture = true" },
    ns("global_shortcut", "src/plugins/global_shortcut.zig"),
    ns("input", "src/plugins/input.zig"),
    ns("clipboard", "src/plugins/clipboard.zig"),
    .{ .name = "canvas", .path = "src/native_ui/zig_canvas.zig", .feature = "native_ui", .enable = ".native_ui = true" },
};

pub fn namespace(comptime name: []const u8) Namespace {
    @setEvalBranchQuota(10_000);
    inline for (namespaces) |n| {
        if (comptime std.mem.eql(u8, n.name, name)) return n;
    }
    @compileError("no module namespace " ++ name);
}

/// The rest of the build error for an unavailable `oriel.<name>.<decl>`.
pub fn reason(comptime name: []const u8, comptime platform: Platform) []const u8 {
    const n = comptime namespace(name);
    return comptime if (!supported(n.feature, platform))
        " is not available on " ++ @tagName(platform) ++ ": guard the call with `if (oriel." ++ name ++ ".available)`"
    else
        " is disabled: enable it with " ++ n.enable ++ " in b.dependency(\"oriel\", ...), or guard the call with `if (oriel." ++ name ++ ".available)`";
}

test supported {
    try std.testing.expect(!supported("tray", .ios));
    try std.testing.expect(!supported("tray", .android));
    try std.testing.expect(supported("tray", .linux));
    try std.testing.expect(supported("global_shortcut", .android));
    try std.testing.expect(!supported("layer_shell", .windows));
}

test reason {
    try std.testing.expectEqualStrings(" is not available on ios: guard the call with `if (oriel.tray.available)`", reason("tray", .ios));
    try std.testing.expect(std.mem.startsWith(u8, reason("chat", .linux), " is disabled: enable it with .llama = true"));
}
