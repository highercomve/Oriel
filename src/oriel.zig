//! oriel: a Tauri-like desktop framework for Zig.
//!
//! Core (always on): GTK4 window + WebKitGTK 6.0 webview, `app://` asset
//! scheme, JS <-> Zig IPC. Built-in modules and plugins are opt-in via
//! `-D<name>=false|true` build options; disabled ones are not even compiled.

const std = @import("std");
pub const options = @import("build_options");

// -Dnative_ui links the engine's C shim (QuickJS) into every program built
// with this module, and the shim calls the engine's exported oriel_nui_*
// functions: reference the engine here so they exist in programs that never
// reach the platform code (the TypeScript generator of `types_from =
// .root_decls`), not only in the app.
comptime {
    if (options.native_ui) _ = @import("native_ui/engine.zig");
}

// The mDNS C ABI (oriel_mdns_*, network/mdns_c.zig) for native code linked
// into an Android app, which may never call oriel.network from Zig.
comptime {
    if (options.network and target.is_android) _ = @import("modules/network/mdns_c.zig");
}

pub const App = @import("core/App.zig");
pub const ipc = @import("core/ipc.zig");
pub const security = @import("core/security.zig");
pub const isolation = @import("core/isolation.zig");
pub const log = @import("core/log.zig");
pub const platform = @import("platform/platform.zig");
/// The OS family being built for (`target.is_android`, `target.os`).
pub const target = @import("core/target.zig");
/// Android backend internals the generated library root uses
/// (`android.exportStart`, `android.panic`); empty elsewhere.
pub const android = if (target.is_android) @import("platform/android/android.zig") else struct {};
/// iOS backend internals; empty elsewhere. App and scene events are
/// `lifecycle` and platform hooks (docs/platform-hooks.md).
pub const ios = if (target.is_ios) @import("platform/ios/ios.zig") else struct {};
/// OS permissions: declared in build.zig, queried and requested at runtime.
pub const permissions = @import("core/permissions.zig");
/// Facts about the device: its name (what a sharing app announces).
pub const system = @import("core/system.zig");
/// The app's private data and cache directories on every platform
/// (`paths.appData(gpa, .{ .name = "MyApp" })`; Android: the files dir itself).
pub const paths = @import("core/paths.zig");
/// The app's lifecycle on every platform: background/foreground, memory
/// pressure, sleep/wake, terminating (`lifecycle.subscribe`; the page's
/// `oriel.lifecycle.on`).
pub const lifecycle = @import("core/lifecycle.zig");
/// Platform hooks in Zig: each window and web view Oriel creates, with its
/// native handle (GtkWindow/WebKitWebView, NSWindow/WKWebView,
/// HWND/ICoreWebView2), on Linux, macOS and Windows
/// (`hooks.subscribe(.{ .webview_created = f })`; docs/platform-hooks.md).
/// `hooks.available` is false on Android and iOS, which hook natively.
pub const hooks = @import("core/hooks.zig");
/// The app's own native code (`AppOptions.extensions` in build.zig):
/// Kotlin, Objective-C/Swift or Zig per platform, called by name
/// (`extensions.get("name").call(...)`); the page through `expose`.
pub const extensions = @import("core/extensions.zig");
/// -Dnative_ui: the app's Zig code draws into a page's <canvas>
/// (native_ui/zig_canvas.zig; docs/native-renderer.md, "Canvas from Zig").
/// Without it there is no native canvas: check `oriel.canvas.available`.
pub const canvas = if (options.native_ui) @import("native_ui/zig_canvas.zig") else unavailable("canvas");

// Built-in modules. Each has `available`: a comptime fact for this build.
// Off, or missing on the target, the namespace holds only `available =
// false`, and every other decl is a build error naming the module and the
// guard (`if (oriel.tray.available)`): code under the guard is never
// analyzed (docs/modules.md, "Availability").
pub const tray = if (options.tray) @import("modules/tray.zig") else unavailable("tray");
pub const updater = if (options.updater) @import("modules/updater.zig") else unavailable("updater");
pub const media_server = if (options.media_server) @import("modules/media_server.zig") else unavailable("media_server");
pub const sql = if (options.sql) @import("modules/sql.zig") else unavailable("sql");
pub const fs_watch = if (options.fs_watch) @import("modules/fs_watch.zig") else unavailable("fs_watch");
pub const dialog = if (options.dialog) @import("modules/dialog.zig") else unavailable("dialog");
pub const notification = if (options.notification) @import("modules/notification.zig") else unavailable("notification");
pub const store = if (options.store) @import("modules/store.zig") else unavailable("store");
pub const menu = if (options.menu) @import("modules/menu.zig") else unavailable("menu");
pub const deep_link = if (options.deep_link) @import("modules/deep_link.zig") else unavailable("deep_link");
/// The multicast lock (mDNS on Android) and LAN information.
pub const network = if (options.network) @import("modules/network.zig") else unavailable("network");
/// Receiving what other apps share, and the system share sheet.
pub const share = if (options.share) @import("modules/share.zig") else unavailable("share");
/// Photos from the camera or the photo library (`capturePhoto`); on when
/// the app declares `.permissions.camera`.
pub const camera = if (options.camera) @import("modules/camera.zig") else unavailable("camera");
pub const sqlite_vec = if (options.sqlite_vec) @import("modules/sqlite_vec.zig") else unavailable("sqlite_vec");
pub const llama = if (options.llama) @import("modules/llama.zig") else unavailable("llama");
pub const whisper = if (options.whisper) @import("modules/whisper.zig") else unavailable("whisper");
/// Text to speech with the built-in Kokoro voice (src/modules/kokoro.zig): `-Dkokoro`.
pub const kokoro = if (options.kokoro) @import("modules/kokoro.zig") else unavailable("kokoro");
/// Playback of the built-in voice (miniaudio; see modules/audio_play.zig).
pub const audio_play = if (options.kokoro) @import("modules/audio_play.zig") else unavailable("audio_play");
/// Text to speech out of the box: voices, downloads, streaming playback (Kokoro): `-Dkokoro`.
pub const tts = if (options.kokoro) @import("modules/tts.zig") else unavailable("tts");
pub const audio_capture = if (options.audio_capture) @import("modules/audio_capture.zig") else unavailable("audio_capture");
/// GPU backends (libggml-cuda.so, libggml-vulkan.so) for llama and whisper: `ggml_gpu.load(io)` before loading a model.
pub const ggml_gpu = if (options.llama or options.whisper) @import("modules/ggml_gpu.zig") else unavailable("ggml_gpu");
/// Chat with a local LLM out of the box: models, templates, streaming, KV reuse, CPU or GPU (llama.cpp).
pub const chat = if (options.llama) @import("modules/chat.zig") else unavailable("chat");
/// Voice to text out of the box: live dictation and transcription, on whisper or the platform's recognizer.
pub const dictation = if (options.whisper and options.audio_capture) @import("modules/dictation.zig") else unavailable("dictation");
/// The device's own model: Gemini Nano (Android), Foundation Models (iOS 26+): `-Dsystem_ai`.
pub const system_ai = if (options.system_ai) @import("modules/system_ai.zig") else unavailable("system_ai");

// App-specific plugins.
pub const global_shortcut = if (options.global_shortcut) @import("plugins/global_shortcut.zig") else unavailable("global_shortcut");
pub const input = if (options.input) @import("plugins/input.zig") else unavailable("input");
pub const clipboard = if (options.clipboard) @import("plugins/clipboard.zig") else unavailable("clipboard");

fn unavailable(comptime name: []const u8) type {
    return @field(module_shims, name)(module_table.reason(name, target.os));
}
const module_shims = @import("module_shims");
const module_table = @import("core/module_table.zig");

/// Every feature flag as this build resolved it, camelCase (`oriel.features`
/// in the page: `{ tray: false, fsWatch: true, ... }`).
pub const features = @import("core/features.zig");

pub const ThreadPool = @import("core/ThreadPool.zig").ThreadPool;

const internal = @import("core/internal.zig");

/// The entry point of every Oriel app:
///
///     pub fn main(init: std.process.Init) !u8 {
///         return oriel.main(init, .{ .commands = Commands, .events = Events }, .{
///             .app = app.build, // `@import("oriel_app")`: what build.zig declares
///             .window = .{ .title = "App", .width = 800, .height = 600 },
///         });
///     }
///
/// It starts the updater (with -Dupdater), handles `--emit-types <path>`
/// (the build writes the frontend's TypeScript bindings with it), hands the
/// process arguments to the platform shell (deep links, second launches),
/// then runs the app on the calling (main) thread until it quits. An app
/// that parses its own arguments does so before calling it; any config
/// chosen at runtime is a `comptime` choice between two calls.
pub fn main(init: std.process.Init, comptime api: App.Api, comptime config: App.Config) !u8 {
    if (options.updater) {
        try updater.init(init.io, init.gpa, init.environ_map);
    }
    defer if (options.updater) updater.deinit(init.io);

    var it = try init.minimal.args.iterateAllocator(init.gpa);
    defer it.deinit();
    _ = it.next();
    if (it.next()) |arg1| {
        if (std.mem.eql(u8, arg1, "--emit-types")) {
            if (it.next()) |arg2| {
                try writeTypes(init.io, init.gpa, api, arg2);
                return 0;
            }
        }
    }

    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(init.gpa);
    defer {
        for (args_list.items) |arg| init.gpa.free(arg);
    }
    var it2 = try init.minimal.args.iterateAllocator(init.gpa);
    defer it2.deinit();
    while (it2.next()) |arg| {
        const dup = try init.gpa.dupe(u8, arg);
        errdefer init.gpa.free(dup);
        try args_list.append(init.gpa, dup);
    }
    internal.process_args = args_list.items;

    return internal.run(init.io, api, config);
}

/// Write the TypeScript bindings for `api` to `path`, leaving the file
/// untouched when nothing changed (so dev servers don't reload needlessly).
pub fn writeTypes(write_io: std.Io, gpa: std.mem.Allocator, comptime api: App.Api, path: []const u8) !void {
    const source = comptime ipc.typescript(api.commands, api.events);
    const cwd = std.Io.Dir.cwd();
    if (cwd.readFileAlloc(write_io, path, gpa, .limited(1 << 20))) |existing| {
        defer gpa.free(existing);
        if (std.mem.eql(u8, existing, source)) return;
    } else |_| {}
    if (std.fs.path.dirname(path)) |dir| try cwd.createDirPath(write_io, dir);
    try cwd.writeFile(write_io, .{ .sub_path = path, .data = source });
}

/// Result of a module smoke check, serialized to the frontend as JSON.
pub const Check = struct {
    module: []const u8,
    ok: bool,
    detail: []const u8,
};

pub const CheckContext = struct {
    io: std.Io,
    /// PNG used for the tray icon check.
    icon_png: []const u8,
    /// Port of a running media server, if one was started.
    media_port: ?u16 = null,
    /// App id for checks that talk to xdg-desktop-portal (it must have an
    /// installed `<app_id>.desktop`); defaults to the running GApplication's
    /// id or the program name.
    app_id: ?[:0]const u8 = null,
};

/// Run the smoke check of every enabled module and plugin.
pub fn checkAll(gpa: std.mem.Allocator, ctx: CheckContext) ![]Check {
    var checks: std.ArrayList(Check) = .empty;
    const Entry = struct { name: []const u8, enabled: bool };
    const entries = [_]Entry{
        .{ .name = "tray", .enabled = options.tray },
        .{ .name = "updater", .enabled = options.updater },
        .{ .name = "media_server", .enabled = options.media_server },
        .{ .name = "sql", .enabled = options.sql },
        .{ .name = "fs_watch", .enabled = options.fs_watch },
        .{ .name = "dialog", .enabled = options.dialog },
        .{ .name = "notification", .enabled = options.notification },
        .{ .name = "store", .enabled = options.store },
        .{ .name = "menu", .enabled = options.menu },
        .{ .name = "deep_link", .enabled = options.deep_link },
        .{ .name = "network", .enabled = options.network },
        .{ .name = "share", .enabled = options.share },
        .{ .name = "camera", .enabled = options.camera },
        .{ .name = "global_shortcut", .enabled = options.global_shortcut },
        .{ .name = "input", .enabled = options.input },
        .{ .name = "clipboard", .enabled = options.clipboard },
        .{ .name = "sqlite_vec", .enabled = options.sqlite_vec },
        .{ .name = "llama", .enabled = options.llama },
        .{ .name = "whisper", .enabled = options.whisper },
        .{ .name = "audio_capture", .enabled = options.audio_capture },
    };
    try checks.append(gpa, permissions.check(gpa) catch |err| .{ .module = "permissions", .ok = false, .detail = @errorName(err) });
    inline for (entries) |e| {
        if (e.enabled) {
            const module = @field(@This(), e.name);
            const check_res: Check = module.check(gpa, ctx) catch |err| .{
                .module = e.name,
                .ok = false,
                .detail = @errorName(err),
            };
            try checks.append(gpa, check_res);
        }
    }
    return checks.toOwnedSlice(gpa);
}

test "an unavailable module's stand-in has exactly the module's pub decls" {
    // The modules this build has: importing the others would analyze their
    // tests (C headers and libraries this build doesn't have).
    inline for (module_table.namespaces) |n| {
        const Real = @field(@This(), n.name);
        const Shim = unavailable(n.name);
        try std.testing.expect(!Shim.available);
        if (Real.available) {
            inline for (@typeInfo(Real).@"struct".decls) |d| {
                if (!@hasDecl(Shim, d.name)) {
                    std.debug.print("module_shims: oriel.{s}.{s} has no stand-in\n", .{ n.name, d.name });
                    return error.TestUnexpectedResult;
                }
            }
            try std.testing.expectEqual(@typeInfo(Real).@"struct".decls.len, @typeInfo(Shim).@"struct".decls.len);
        }
    }
}

test "oriel.<module>.available follows the resolved flags" {
    inline for (module_table.namespaces) |n| {
        if (comptime std.mem.eql(u8, n.name, n.feature)) {
            try std.testing.expectEqual(@field(options, n.feature), @field(@This(), n.name).available);
        }
    }
    try std.testing.expectEqual(options.kokoro, tts.available);
    try std.testing.expectEqual(options.whisper and options.audio_capture, dictation.available);
}

test {
    std.testing.refAllDecls(module_table);
    std.testing.refAllDecls(features);
    std.testing.refAllDecls(ipc);
    std.testing.refAllDecls(security);
    std.testing.refAllDecls(@import("core/isolation.zig"));
    std.testing.refAllDecls(@import("core/csp.zig"));
    std.testing.refAllDecls(@import("core/bridge_js.zig"));
    std.testing.refAllDecls(permissions);
    std.testing.refAllDecls(system);
    std.testing.refAllDecls(paths);
    std.testing.refAllDecls(paths);
    std.testing.refAllDecls(lifecycle);
    std.testing.refAllDecls(hooks);
    std.testing.refAllDecls(extensions);
    std.testing.refAllDecls(@import("core/extension_spec.zig"));
    std.testing.refAllDecls(@import("core/pending_events.zig"));
    std.testing.refAllDecls(@import("core/file_handles.zig"));
    std.testing.refAllDecls(@import("core/window_commands.zig"));
    _ = @import("core/internal.zig");
    _ = App;
    std.testing.refAllDecls(log);
    std.testing.refAllDecls(platform);
    std.testing.refAllDecls(@import("core/ThreadPool.zig"));
    if (options.tray) _ = tray;
    if (options.media_server) {
        std.testing.refAllDecls(media_server);
        std.testing.refAllDecls(@import("modules/media/range.zig"));
        std.testing.refAllDecls(@import("modules/media/open.zig"));
        std.testing.refAllDecls(@import("modules/media_scheme.zig"));
    }
    if (options.updater) {
        std.testing.refAllDecls(updater);
        std.testing.refAllDecls(@import("modules/update_manifest.zig"));
    }
    if (options.dialog) std.testing.refAllDecls(dialog);
    if (options.notification) std.testing.refAllDecls(notification);
    if (options.store) std.testing.refAllDecls(store);
    if (options.menu) std.testing.refAllDecls(menu);
    if (options.deep_link) std.testing.refAllDecls(deep_link);
    if (options.network) std.testing.refAllDecls(network);
    if (options.share) std.testing.refAllDecls(share);
    if (options.camera) std.testing.refAllDecls(camera);
    if (options.global_shortcut) std.testing.refAllDecls(global_shortcut);
    if (options.input) std.testing.refAllDecls(input);
    // The native renderer's own tests: its tree everywhere, the GTK backend
    // on desktop Linux.
    if (options.native_ui) {
        _ = @import("native_ui/tree.zig");
        _ = @import("native_ui/drop.zig");
        if (@import("builtin").os.tag == .linux and !@import("builtin").abi.isAndroid()) _ = @import("native_ui/gtk.zig");
    }
    if (options.clipboard) std.testing.refAllDecls(clipboard);
    if (options.fs_watch) std.testing.refAllDecls(fs_watch);
    if (options.sql) std.testing.refAllDecls(sql);
    if (options.sqlite_vec) std.testing.refAllDecls(sqlite_vec);
    if (options.llama) std.testing.refAllDecls(llama);
    if (options.whisper) std.testing.refAllDecls(whisper);
    if (options.llama or options.whisper) std.testing.refAllDecls(ggml_gpu);
    if (options.audio_capture) std.testing.refAllDecls(audio_capture);
    if (options.whisper and options.audio_capture) std.testing.refAllDecls(dictation);
    if (options.llama) std.testing.refAllDecls(chat);
    if (options.kokoro) {
        std.testing.refAllDecls(kokoro);
        std.testing.refAllDecls(audio_play);
        std.testing.refAllDecls(tts);
        std.testing.refAllDecls(@import("modules/tts/espeak_data.zig"));
    }
    // dictation's Apple engine needs no whisper: checked on every Apple
    // target (whisper's C sources need the SDK even to type-check).
    if (target.is_ios or target.os == .macos) std.testing.refAllDecls(@import("modules/dictation/apple.zig"));
    std.testing.refAllDecls(@import("modules/model_download.zig"));
    // system_ai's platform-independent half runs everywhere (a fake backend).
    std.testing.refAllDecls(@import("modules/system_ai/core.zig"));
    std.testing.refAllDecls(@import("modules/system_ai/bridge.zig"));
    if (options.system_ai) std.testing.refAllDecls(system_ai);
    if (target.is_ios) std.testing.refAllDecls(@import("modules/model_download/ios.zig"));
}
