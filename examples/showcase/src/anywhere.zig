//! Dictate anywhere: talk into whatever app has focus, like GhostPen.
//!
//! Desktop: Ctrl+Alt+D (a system-wide hotkey, `oriel.global_shortcut`) or
//! the tray menu starts dictation; pressing it again stops, and the text is
//! typed into the focused app (`oriel.clipboard` + `oriel.input.paste`).
//! Android: the Quick Settings tile, the Oriel keyboard's button, the
//! headset button and the notification's "Stop" do the same; a foreground
//! service keeps listening in the background, and the text goes into the
//! focused field through the Oriel keyboard (or the clipboard, with a
//! notification, under another keyboard). iOS has no such entry points.

const std = @import("std");
const oriel = @import("oriel");
const dictation = oriel.dictation;

const log = std.log.scoped(.anywhere);
const is_android = oriel.target.is_android;

pub const available = oriel.options.global_shortcut and !oriel.target.is_ios or is_android;
pub const hotkey = "ctrl+alt+D";

pub const State = struct { state: []const u8, text: []const u8 = "" };

var io: std.Io = undefined;
var mutex: std.Io.Mutex = .init;
var listening = false;
/// The page's last settings (`configure`): engine, model and language.
var lang_buf: [16]u8 = undefined;
var model_buf: [16]u8 = undefined;
var opts: dictation.Options = .{};

pub fn init(app_io: std.Io) void {
    io = app_io;
}

/// Use the page's choices for dictation outside the app.
pub fn configure(o: dictation.Options) void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    opts = o;
    const l = @min(o.language.len, lang_buf.len);
    @memcpy(lang_buf[0..l], o.language[0..l]);
    opts.language = lang_buf[0..l];
    const m = @min(o.model.len, model_buf.len);
    @memcpy(model_buf[0..m], o.model[0..m]);
    opts.model = model_buf[0..m];
    opts.source = null;
}

fn emit(state: []const u8, text: []const u8) void {
    oriel.App.emit("anywhere", State{ .state = state, .text = text });
}

/// Start or stop (any thread; the work runs on a worker).
pub fn toggle() void {
    oriel.App.spawn(toggleNow, .{}) catch |err| log.err("dictate anywhere: {s}", .{@errorName(err)});
}

fn toggleNow() void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (listening) return stopAndDeliver();
    if (is_android and oriel.permissions.status(.microphone) != .granted) {
        // The prompt needs an Activity: bring the app up and ask there.
        oriel.App.runOnMain(@as(u8, 0), struct {
            fn f(_: u8) void {
                oriel.App.showWindow();
                _ = oriel.permissions.request(.microphone);
            }
        }.f);
        return;
    }
    if (is_android) {
        oriel.android.setForegroundService(true, "Oriel is listening", "Tap Stop, the tile or the headset button to insert the text", &.{
            .{ .id = "stop", .label = "Stop" },
        }) catch |err| log.warn("foreground service: {s}", .{@errorName(err)});
    }
    _ = dictation.start(opts) catch |err| {
        log.err("cannot start: {s}", .{@errorName(err)});
        if (is_android) oriel.android.setForegroundService(false, "", "", &.{}) catch {};
        emit("error", @errorName(err));
        return;
    };
    listening = true;
    if (is_android) {
        oriel.android.setTile(true, "Listening…");
        oriel.android.setKeyboardStatus("Listening… tap to insert", "■");
    }
    emit("listening", "");
}

/// Caller holds `mutex`.
fn stopAndDeliver() void {
    listening = false;
    if (is_android) {
        oriel.android.setKeyboardStatus("Transcribing…", "…");
        oriel.android.setTile(false, "Dictate anywhere");
    }
    defer if (is_android) {
        oriel.android.setForegroundService(false, "", "", &.{}) catch {};
        oriel.android.setKeyboardStatus("Oriel: tap to dictate", "🎤");
    };
    emit("transcribing", "");
    var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena.deinit();
    const r = dictation.stop(arena.allocator()) catch |err| {
        emit("error", @errorName(err));
        return;
    };
    const text = std.mem.trim(u8, r.text, " \t\r\n");
    if (text.len == 0) return emit("nothing", "");
    deliver(text);
}

fn deliver(text: []const u8) void {
    if (is_android) {
        if (oriel.android.commitText(text)) |_| return emit("inserted", text) else |_| {}
    } else if (oriel.options.input) {
        // Into the focused app: the clipboard, then the paste shortcut.
        oriel.clipboard.writeText(text) catch |err| return emit("error", @errorName(err));
        if (oriel.input.paste()) |_| return emit("inserted", text) else |err| log.warn("paste: {s}", .{@errorName(err)});
        return emit("copied", text);
    }
    oriel.clipboard.writeText(text) catch {};
    oriel.notification.notify(.{ .id = "dictation", .title = "Copied to the clipboard", .body = text }) catch {};
    emit("copied", text);
}

/// Android's system entry points (main thread).
pub fn onSystemEvent(name: []const u8, data: []const u8) void {
    const toggles = std.mem.eql(u8, name, "tile") or std.mem.eql(u8, name, "ime-mic") or
        std.mem.eql(u8, name, "media-button") or
        (std.mem.eql(u8, name, "action") and std.mem.eql(u8, data, "stop"));
    if (toggles) toggle();
}

pub fn setupAndroid() void {
    if (!is_android) return;
    oriel.android.setKeyboardStatus("Oriel: tap to dictate", "🎤");
    oriel.android.setTile(false, "Dictate anywhere");
}
