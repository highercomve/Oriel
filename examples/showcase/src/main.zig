//! Oriel Showcase: one app for Linux, Windows, macOS, Android and iOS that
//! uses every Oriel feature. Each tab of the page is a feature area:
//! Dictate (oriel.dictation), Chat (oriel.chat), Speak (oriel.tts),
//! Notes (sql, deep links),
//! Files (dialog), System (clipboard, notifications, shortcuts, dictate
//! anywhere) and App (windows, IPC, events, the store, the device).

const std = @import("std");
const builtin = @import("builtin");
const oriel = @import("oriel");
const app = @import("oriel_app");

const dictation = oriel.dictation;
const chat = oriel.chat;
const tts = oriel.tts;
const notes = @import("notes.zig");
const anywhere = @import("anywhere.zig");

const app_id = "dev.oriel.Showcase";
const desktop = !oriel.target.is_android and !oriel.target.is_ios;

pub const Events = struct {
    tick: u32,
    // oriel.dictation's events (emitted by the module).
    @"dictation:download": @FieldType(dictation.Events, "dictation:download"),
    @"dictation:level": @FieldType(dictation.Events, "dictation:level"),
    @"dictation:partial": dictation.Partial,
    @"dictation:final": dictation.Final,
    @"dictation:compare": @FieldType(dictation.Events, "dictation:compare"),
    @"dictation:error": @FieldType(dictation.Events, "dictation:error"),
    @"dictation:ended": @FieldType(dictation.Events, "dictation:ended"),
    // oriel.chat's events.
    @"chat:download": @FieldType(chat.Events, "chat:download"),
    @"chat:token": @FieldType(chat.Events, "chat:token"),
    @"chat:compare": @FieldType(chat.Events, "chat:compare"),
    // oriel.tts's events: download progress, and what the utterance is doing.
    @"tts:download": @FieldType(tts.Events, "tts:download"),
    @"tts:state": @FieldType(tts.Events, "tts:state"),
    /// A keyboard shortcut or a menu item (Android: a hardware keyboard,
    /// the Meta+/ list; desktop: the window menu).
    shortcut: struct { id: []const u8 },
    /// Dictate anywhere: "listening", "transcribing", "inserted", "copied", "nothing", "error".
    anywhere: anywhere.State,
    /// The notes changed outside the page (a deep link).
    notes: []const notes.Note,
    /// A deep link arrived (oriel-showcase://...).
    link: struct { url: []const u8 },
};
const events = oriel.App.events(Events);

pub const Commands = struct {
    // Block (network, model loading, whisper): on the worker pool.
    pub const async_commands = .{
        "dictation_status", "dictation_download", "dictation_start",   "dictation_stop", "dictation_compare",
        "dictation_delete", "dictation_file",     "dictation_sources", "open_file",      "save_file",
        "paste",            "chat_status",        "chat_download",     "chat_delete",    "chat_send",
        "chat_compare",     "tts_status",         "tts_download",      "tts_delete",     "tts_warm_up",
        "tts_speak",
    };

    /// The IPC round trip of the pass criteria.
    pub fn echo(gpa: std.mem.Allocator, args: struct { text: []const u8 }) ![]const u8 {
        return gpa.dupe(u8, args.text);
    }

    pub fn info(gpa: std.mem.Allocator) !struct {
        os: []const u8,
        arch: []const u8,
        android: bool,
        data_dir: []const u8,
        /// What this build has, for the page to show or hide.
        tray: bool,
        menu: bool,
        hotkeys: bool,
        anywhere: bool,
        hotkey: []const u8,
    } {
        return .{
            .os = oriel.target.name,
            .arch = @tagName(builtin.cpu.arch),
            .android = oriel.target.is_android,
            .data_dir = oriel.store.dataDir(gpa, app_id) catch "",
            .tray = oriel.options.tray,
            .menu = oriel.options.menu,
            .hotkeys = oriel.options.global_shortcut,
            .anywhere = anywhere.available,
            .hotkey = anywhere.hotkey,
        };
    }

    /// A second window (pass criteria: several windows).
    pub fn open_window(_: std.mem.Allocator, args: struct { n: u32 }) !void {
        var label_buf: [32]u8 = undefined;
        const label = try std.fmt.bufPrintZ(&label_buf, "second-{d}", .{args.n});
        _ = try oriel.App.openWindow(.{ .label = label, .title = "Second window", .url = "index.html?second=1", .width = 480, .height = 360 });
    }

    /// Counts in the store: survives restarts.
    pub fn launches(_: std.mem.Allocator) !i64 {
        var store = try oriel.store.Store.open(std.heap.smp_allocator, app_id, "hello");
        defer store.deinit();
        const n = (store.getInt("launches", i64) orelse 0) + 1;
        try store.set("launches", n);
        return n;
    }

    pub fn copy(_: std.mem.Allocator, args: struct { text: []const u8 }) !void {
        try oriel.clipboard.writeText(args.text);
    }

    pub fn paste(gpa: std.mem.Allocator) ![]const u8 {
        return oriel.clipboard.readText(gpa);
    }

    pub fn notify(_: std.mem.Allocator, args: struct { title: []const u8 = "Oriel Showcase", text: []const u8 }) !void {
        // Clicks reach the page as `notification:action` events.
        try oriel.notification.notify(.{
            .id = "showcase",
            .title = args.title,
            .body = args.text,
            .actions = &.{ .{ .id = "like", .label = "Like" }, .{ .id = "later", .label = "Later" } },
        });
    }

    // The Chat tab: thin wrappers over oriel.chat.

    pub fn chat_status(_: std.mem.Allocator) chat.Status {
        return chat.status();
    }

    pub fn chat_download(_: std.mem.Allocator, args: struct { model: []const u8 }) !void {
        try chat.download(args.model);
    }

    pub fn chat_delete(_: std.mem.Allocator, args: struct { model: []const u8 }) !void {
        try chat.delete(args.model);
    }

    /// The reply to the conversation; tokens arrive as `chat:token`.
    pub fn chat_send(gpa: std.mem.Allocator, args: struct { messages: []const chat.Message, options: chat.Options = .{} }) !chat.Result {
        return chat.generate(gpa, args.messages, args.options);
    }

    /// Not async: it must run while chat_send is busy on a worker.
    pub fn chat_cancel(_: std.mem.Allocator) void {
        chat.cancel();
    }

    pub fn chat_compare(_: std.mem.Allocator, args: chat.Options) !chat.Comparison {
        return chat.compare(args);
    }

    // The Speak tab and "Read aloud": thin wrappers over oriel.tts.

    pub fn tts_status(_: std.mem.Allocator) tts.Status {
        return tts.status();
    }

    /// A model or a voice id; progress arrives as `tts:download`.
    pub fn tts_download(_: std.mem.Allocator, args: struct { id: []const u8 }) !void {
        try tts.download(args.id);
    }

    pub fn tts_delete(_: std.mem.Allocator, args: struct { id: []const u8 }) !void {
        try tts.delete(args.id);
    }

    /// Reads the text aloud and returns when it has been played (or
    /// stopped); `tts:state` follows it. A new one stops the current one.
    pub fn tts_speak(gpa: std.mem.Allocator, args: struct { text: []const u8, options: tts.Options = .{} }) !tts.Result {
        return tts.speak(gpa, args.text, args.options);
    }

    /// Loads the model and voice `tts_speak` would use, without speaking
    /// (on a GPU it also compiles the pipelines): the Speak tab calls it on
    /// its first visit, so the first sentence starts sooner.
    pub fn tts_warm_up(_: std.mem.Allocator, args: tts.Options) !void {
        try tts.warmUp(args);
    }

    /// Not async: it must run while tts_speak is busy on a worker.
    pub fn tts_stop(_: std.mem.Allocator) void {
        tts.stop();
    }

    /// The language "auto" reads the text in ("en-us", "es"...), for the
    /// page to name the voice Auto picks.
    pub fn tts_guess(_: std.mem.Allocator, args: struct { text: []const u8 }) []const u8 {
        return tts.guessLanguage(args.text);
    }

    // Files: the platform's pickers (GTK, Win32, AppKit, Android's
    // Storage Access Framework, UIDocumentPicker).

    /// The picked file's name, size and the start of its text, or "" for a
    /// binary file (null: cancelled).
    pub fn open_file(gpa: std.mem.Allocator, io: std.Io) !?struct { path: []const u8, size: u64, preview: []const u8, binary: bool } {
        const path = try oriel.dialog.openFile(gpa, .{ .title = "Open a file" }) orelse return null;
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        const stat = try file.stat(io);
        var buf: [600]u8 = undefined;
        const n = try file.readPositionalAll(io, &buf, 0);
        // The preview is text: cut at the last whole UTF-8 sequence.
        var end = n;
        while (end > 0 and !std.unicode.utf8ValidateSlice(buf[0..end])) end -= 1;
        // Binary: not UTF-8 (beyond a character cut at the end), or control
        // characters other than tabs and line breaks.
        var binary = end + 4 <= n;
        for (buf[0..end]) |ch| {
            if ((ch < 0x20 and ch != '\t' and ch != '\n' and ch != '\r') or ch == 0x7f) binary = true;
        }
        return .{ .path = path, .size = stat.size, .preview = if (binary) "" else try gpa.dupe(u8, buf[0..end]), .binary = binary };
    }

    /// Write `text` where the user picks (false: cancelled).
    pub fn save_file(gpa: std.mem.Allocator, io: std.Io, args: struct { text: []const u8 }) !bool {
        const path = try oriel.dialog.saveFile(gpa, .{ .title = "Save the text" }) orelse return false;
        defer gpa.free(path);
        try oriel.dialog.writeFile(io, path, args.text);
        return true;
    }

    // Notes: SQLite, and deep links (oriel-showcase://note/<text>).

    pub fn notes_list(gpa: std.mem.Allocator) ![]notes.Note {
        return notes.list(gpa);
    }

    pub fn notes_add(gpa: std.mem.Allocator, args: struct { text: []const u8 }) ![]notes.Note {
        return notes.add(gpa, args.text);
    }

    pub fn notes_delete(gpa: std.mem.Allocator, args: struct { id: i64 }) ![]notes.Note {
        return notes.delete(gpa, args.id);
    }

    /// Dictate anywhere: the page's settings for it, and a toggle.
    pub fn anywhere_configure(_: std.mem.Allocator, args: dictation.Options) void {
        anywhere.configure(args);
    }

    pub fn anywhere_toggle(_: std.mem.Allocator) void {
        anywhere.toggle();
    }

    // The Dictate tab: thin wrappers over oriel.dictation (the page's
    // options map onto dictation.Options).

    pub fn dictation_status(_: std.mem.Allocator) dictation.Status {
        return dictation.status();
    }

    pub fn dictation_download(_: std.mem.Allocator, args: struct { model: []const u8 }) !void {
        try dictation.download(args.model);
    }

    pub fn dictation_start(_: std.mem.Allocator, args: dictation.Options) !dictation.Started {
        return dictation.start(args);
    }

    /// Microphones, and on the desktop what the computer plays (captions).
    pub fn dictation_sources(gpa: std.mem.Allocator) ![]oriel.audio_capture.Source {
        return dictation.sources(gpa);
    }

    pub fn dictation_stop(gpa: std.mem.Allocator) !dictation.Result {
        return dictation.stop(gpa);
    }

    pub fn dictation_delete(_: std.mem.Allocator, args: struct { model: []const u8 }) !void {
        try dictation.delete(args.model);
    }

    /// The last recording on the GPU and on the CPU; the faster one is
    /// remembered for `.backend = .auto`.
    pub fn dictation_compare(gpa: std.mem.Allocator, args: dictation.Options) !dictation.Comparison {
        return dictation.compare(gpa, args);
    }

    /// Pick a WAV file and transcribe it (null: cancelled).
    pub fn dictation_file(gpa: std.mem.Allocator, args: dictation.Options) !?dictation.Transcript {
        const path = (try oriel.dialog.openFile(gpa, .{ .title = "A recording to transcribe (WAV)" })) orelse return null;
        defer gpa.free(path);
        return try dictation.transcribeFile(gpa, path, args);
    }

    /// `--ui-test <name>` on the command line, or ORIEL_UI_TEST=<name> in
    /// the environment: the page runs that scripted test (uitest.js).
    pub fn ui_test(_: std.mem.Allocator) ?[]const u8 {
        return ui_test_name;
    }

    /// A line of the UI test's progress, to the app's log (stderr), where
    /// the test runner reads it ("screenshot <name>", "done ok", "FAIL ...").
    pub fn ui_log(_: std.mem.Allocator, args: struct { line: []const u8 }) void {
        std.log.info("ui-test: {s}", .{args.line});
    }

    /// Emits `tick` five times from a worker: events from other threads.
    pub fn ticks(_: std.mem.Allocator, io: std.Io) !void {
        for (1..6) |i| {
            events.emit(.tick, @intCast(i));
            try io.sleep(.fromMilliseconds(200), .awake);
        }
    }
};

var ui_test_name: ?[]const u8 = null;

/// iOS: in the background (or warned about memory), free the models; the
/// next dictation or reply loads them again. On the main thread, before
/// the handler returns: iOS suspends the app right after (both return at
/// once while a model is in use).
fn onIosEvent(name: []const u8, _: []const u8) void {
    if (std.mem.eql(u8, name, "background") or std.mem.eql(u8, name, "memory-warning")) {
        dictation.unloadIdle();
        chat.unloadIdle();
        tts.unloadIdle();
    }
}

/// Android's system events: memory pressure, and the dictate-anywhere
/// entry points (tile, keyboard, headset, notification).
fn onSystemEvent(name: []const u8, data: []const u8) void {
    if (std.mem.eql(u8, name, "trim-memory")) {
        // TRIM_MEMORY_BACKGROUND and worse: free the whisper models.
        const level = std.fmt.parseInt(i32, data, 10) catch return;
        if (level >= 40) {
            oriel.App.spawn(dictation.unloadIdle, .{}) catch {};
            oriel.App.spawn(chat.unloadIdle, .{}) catch {};
            oriel.App.spawn(tts.unloadIdle, .{}) catch {};
        }
        return;
    }
    anywhere.onSystemEvent(name, data);
}

/// Tabs by shortcut (Android: in-app, listed by Meta+/) and by the window
/// menu (desktop); the page switches on the `shortcut` event.
const tabs = [_]struct { id: []const u8, label: []const u8, key: []const u8 }{
    .{ .id = "tab:dictate", .label = "Dictate", .key = "ctrl+1" },
    .{ .id = "tab:chat", .label = "Chat", .key = "ctrl+2" },
    .{ .id = "tab:speak", .label = "Speak", .key = "ctrl+3" },
    .{ .id = "tab:notes", .label = "Notes", .key = "ctrl+4" },
    .{ .id = "tab:files", .label = "Files", .key = "ctrl+5" },
    .{ .id = "tab:system", .label = "System", .key = "ctrl+6" },
    .{ .id = "tab:app", .label = "App", .key = "ctrl+7" },
};

fn onShortcut(id: []const u8) void {
    if (std.mem.eql(u8, id, "anywhere")) return anywhere.toggle();
    events.emit(.shortcut, .{ .id = id });
}

fn onMenu(id: []const u8, _: ?bool) void {
    if (std.mem.eql(u8, id, "quit")) return oriel.App.quit(0);
    if (std.mem.eql(u8, id, "show")) return oriel.App.toggleWindow();
    onShortcut(id);
}

var tray: if (oriel.options.tray) ?*oriel.tray.Tray else void = if (oriel.options.tray) null else {};

fn setup() !void {
    const gpa = std.heap.smp_allocator;
    if (oriel.options.deep_link) oriel.deep_link.onOpen(onDeepLink);
    if (oriel.target.is_android) {
        // In-app shortcuts, shown in the system's Meta+/ list.
        try oriel.global_shortcut.register(gpa, .{ .id = "dictate", .description = "Start or stop dictation", .trigger = "ctrl+shift+D" }, onShortcut);
        inline for (tabs) |t| try oriel.global_shortcut.register(gpa, .{ .id = t.id, .description = t.label ++ " tab", .trigger = t.key }, onShortcut);
        anywhere.setupAndroid();
    }
    if (desktop) {
        // System-wide: dictate into any app.
        oriel.global_shortcut.register(gpa, .{ .id = "anywhere", .description = "Dictate into the focused app", .trigger = anywhere.hotkey }, onShortcut) catch |err|
            std.log.warn("hotkey {s}: {s}", .{ anywhere.hotkey, @errorName(err) });
        tray = oriel.tray.Tray.create(gpa, .{
            .id = app_id,
            .title = "Oriel Showcase",
            .tooltip = "Oriel Showcase: dictate anywhere with Ctrl+Alt+D",
            .icon = .{ .png = app.icon_bytes },
            .menu = &.{
                .{ .item = .{ .id = "show", .label = "Show or hide the window" } },
                .{ .item = .{ .id = "anywhere", .label = "Dictate anywhere (Ctrl+Alt+D)" } },
                .separator,
                .{ .item = .{ .id = "quit", .label = "Quit" } },
            },
            .on_menu = onMenu,
        }) catch |err| blk: {
            std.log.warn("tray: {s}", .{@errorName(err)});
            break :blk null;
        };
        oriel.App.setMenu(&.{
            .{ .submenu = .{ .label = "File", .items = &.{
                .{ .item = .{ .id = "tab:files", .label = "Open or save a file", .shortcut = "Ctrl+O" } },
                .separator,
                .{ .item = .{ .id = "quit", .label = "Quit", .shortcut = "Ctrl+Q" } },
            } } },
            .{ .submenu = .{ .label = "Go", .items = &menu_tabs } },
            .{ .submenu = .{ .label = "Dictation", .items = &.{
                .{ .item = .{ .id = "dictate", .label = "Start or stop", .shortcut = "Ctrl+Shift+D" } },
                .{ .item = .{ .id = "anywhere", .label = "Dictate anywhere (Ctrl+Alt+D)" } },
            } } },
        }, onMenu) catch |err| std.log.warn("menu: {s}", .{@errorName(err)});
    }
}

const menu_tabs = blk: {
    var items: [tabs.len]oriel.menu.MenuItem = undefined;
    for (tabs, &items) |t, *m| m.* = .{ .item = .{ .id = t.id, .label = t.label, .shortcut = "Ctrl+" ++ t.key[5..] } };
    break :blk items;
};

/// oriel-showcase://note/<text> adds a note; the page shows every link.
fn onDeepLink(url: []const u8) void {
    events.emit(.link, .{ .url = url });
    var buf: [2048]u8 = undefined;
    const text = notes.textFromLink(url, &buf) orelse return;
    var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena.deinit();
    const list = notes.add(arena.allocator(), text) catch |err| return std.log.err("deep link note: {s}", .{@errorName(err)});
    std.log.info("deep link added note: '{s}'", .{text});
    events.emit(.notes, list);
    oriel.App.showWindow();
}

fn headlessChat(gpa: std.mem.Allocator, message: []const u8) !u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var messages: std.ArrayList(chat.Message) = .empty;
    try messages.append(a, .{ .role = "system", .content = "You are a helpful assistant. Answer briefly." });
    for ([_][]const u8{ message, "Say that again in one short sentence." }) |turn| {
        try messages.append(a, .{ .role = "user", .content = turn });
        const r = try chat.generate(a, messages.items, .{ .max_tokens = 128 });
        std.debug.print("> {s}\n{s}\n[{s} on {s}: {d} tokens, {d:.1} tok/s; prompt {d} tokens ({d} reused) in {d} ms; load {d} ms; stop: {s}]\n\n", .{
            turn,            r.text,          r.model,     r.backend, r.tokens, r.tokens_per_s,
            r.prompt_tokens, r.reused_tokens, r.prompt_ms, r.load_ms, r.stop,
        });
        try messages.append(a, .{ .role = "assistant", .content = r.text });
    }
    return 0;
}

fn headlessDownload(model: []const u8) !u8 {
    if (!chat.present(try chat.find(model))) try chat.download(model);
    std.debug.print("{s}: present\n", .{model});
    return 0;
}

/// Compare's measurement, as the Chat tab runs it: the GPU (if any) and the
/// CPU on the same prompt, and which one `.auto` uses from then on.
fn headlessCompare(model: []const u8) !u8 {
    const r = try chat.compare(.{ .model = model });
    if (r.gpu) |g| std.debug.print("GPU: {d:.1} tok/s ({d} tokens, prompt {d} ms)\n", .{ g.tokens_per_s, g.tokens, g.prompt_ms }) else std.debug.print("GPU: none\n", .{});
    std.debug.print("CPU: {d:.1} tok/s ({d} tokens, prompt {d} ms)\nauto uses: {s}\n", .{ r.cpu.tokens_per_s, r.cpu.tokens, r.cpu.prompt_ms, r.faster });
    return 0;
}

fn headlessTranscribe(gpa: std.mem.Allocator, path: []const u8) !u8 {
    const t = try dictation.transcribeFile(gpa, path, .{});
    defer gpa.free(t.text);
    std.debug.print("{s}\n[{s} on {s}: {d:.1} s of audio in {d} ms]\n", .{ std.mem.trim(u8, t.text, " \n"), t.model, t.backend, t.audio_s, t.transcribe_ms });
    return 0;
}

/// The Speak tab's defaults on `text`: the voice and language guessed, the
/// model and voice must be on the device (`--tts-download`).
fn headlessSay(gpa: std.mem.Allocator, text: []const u8) !u8 {
    const r = tts.speak(gpa, text, .{}) catch |err| {
        switch (err) {
            error.NoModel => std.debug.print("No Kokoro model in {s}: --tts-download {s}\n", .{ tts.status().models_dir, tts.models[0].id }),
            error.NoVoice => std.debug.print("No voice for {s} in {s}: --tts-download <voice> (e.g. af_heart, ef_dora)\n", .{ tts.guessLanguage(text), tts.status().models_dir }),
            error.EspeakDataMissing => std.debug.print("No espeak-ng data: espeak-ng-data/ next to the executable, in the models directory, or $KOKORO_ESPEAK_DATA_PATH\n", .{}),
            else => std.debug.print("error: {s}\n", .{@errorName(err)}),
        }
        return 1;
    };
    std.debug.print("[{s} ({s}) on {s}: first audio in {d} ms (load {d} ms); {d} chunks, {d:.1} s of audio in {d} ms, {d:.2}x real time (RTF {d:.3}); gaps {d} ms{s}]\n", .{
        r.voice,                                                         r.lang,                                                              r.backend, r.first_audio_ms,                   r.load_ms, r.chunks, r.audio_s, r.synth_ms,
        r.audio_s * 1000 / @as(f32, @floatFromInt(@max(r.synth_ms, 1))), @as(f32, @floatFromInt(r.synth_ms)) / 1000 / @max(r.audio_s, 0.001), r.gap_ms,  if (r.stopped) "; stopped" else "",
    });
    return 0;
}

fn headlessTtsDownload(id: []const u8) !u8 {
    try tts.download(id);
    std.debug.print("{s}: present\n", .{id});
    return 0;
}

fn printUsage() void {
    std.debug.print(
        \\Oriel Showcase: with no arguments, opens the app.
        \\
        \\  --chat "<message>"    answer it and a follow-up (the second turn reuses the KV cache)
        \\  --download <model>    download a chat model (e.g. qwen2.5-0.5b)
        \\  --compare <model>     the Chat tab's GPU vs CPU comparison
        \\  --transcribe <wav>    transcribe a file (the whisper model must be downloaded)
        \\  --say "<text>"        read it aloud with the Speak tab's defaults (model and voice must be downloaded)
        \\  --tts-download <id>   download a voice model or a voice (kokoro-82m-q8_0, af_heart, ef_dora...)
        \\  --ui-test <name>      the page drives its own controls (web/uitest.js)
        \\  -h, --help            this help
        \\
    , .{});
}

pub fn main(init: std.process.Init) !u8 {
    // Whisper models: large, so on Android in the external files directory
    // (/sdcard/Android/data/<id>/files/...), which adb can write to.
    const data_dir = if (oriel.target.is_android)
        try oriel.store.impl.externalDataDir(init.gpa, app_id)
    else
        try oriel.store.dataDir(init.gpa, app_id);
    defer init.gpa.free(data_dir);
    const models_dir = try std.fs.path.join(init.gpa, &.{ data_dir, "models" });
    defer init.gpa.free(models_dir);
    dictation.init(init.io, init.gpa, models_dir);
    chat.init(init.io, init.gpa, models_dir);
    tts.init(init.io, init.gpa, models_dir);
    notes.init(init.io, app_id);
    anywhere.init(init.io);
    if (oriel.target.is_android) oriel.android.onSystemEvent(onSystemEvent);
    if (oriel.target.is_ios) oriel.ios.onSystemEvent(onIosEvent);

    // Headless checks (desktop): `--chat "<message>"` answers it and a
    // follow-up (the second turn reuses the KV cache), `--transcribe <wav>`
    // prints the text (the models must be in the models directory);
    // `--download <model>` fetches a chat model, `--compare <model>` runs
    // the Chat tab's GPU/CPU comparison; `--say "<text>"` reads it aloud
    // (`--tts-download <id>` fetches a voice model or a voice).
    if (!oriel.target.is_android and !oriel.target.is_ios) {
        var it = try init.minimal.args.iterateAllocator(init.gpa);
        defer it.deinit();
        _ = it.next();
        if (it.next()) |flag| {
            if (std.mem.eql(u8, flag, "--help") or std.mem.eql(u8, flag, "-h")) {
                printUsage();
                return 0;
            }
            if (it.next()) |arg| {
                if (std.mem.eql(u8, flag, "--chat")) return headlessChat(init.gpa, arg);
                if (std.mem.eql(u8, flag, "--download")) return headlessDownload(arg);
                if (std.mem.eql(u8, flag, "--compare")) return headlessCompare(arg);
                if (std.mem.eql(u8, flag, "--transcribe")) return headlessTranscribe(init.gpa, arg);
                if (std.mem.eql(u8, flag, "--say")) return headlessSay(init.gpa, arg);
                if (std.mem.eql(u8, flag, "--tts-download")) return headlessTtsDownload(arg);
            }
        }
    }
    // `--ui-test <name>` or ORIEL_UI_TEST=<name> (on iOS, `SIMCTL_CHILD_`
    // variables reach the app): the page drives its own controls
    // (web/uitest.js).
    if (!oriel.target.is_android) {
        var it = try init.minimal.args.iterateAllocator(init.gpa);
        defer it.deinit();
        while (it.next()) |arg| if (std.mem.eql(u8, arg, "--ui-test")) {
            if (it.next()) |n| ui_test_name = try init.arena.allocator().dupe(u8, n);
        };
        if (ui_test_name == null) if (init.environ_map.get("ORIEL_UI_TEST")) |n| {
            if (n.len > 0) ui_test_name = try init.arena.allocator().dupe(u8, n);
        };
    }

    return oriel.main(init, .{ .commands = Commands, .events = Events }, .{
        .id = app_id,
        .title = "Oriel Showcase",
        .width = 1120,
        .height = 780,
        .min_width = 360,
        .min_height = 320,
        .assets = app.assets,
        .dev = app.dev,
        .icon = app.icon_bytes,
        .permissions = app.permissions,
        .deep_link_schemes = app.url_schemes,
        // The demo and its UI tests coordinate the app's own windows.
        .security = .{ .window_api = .{ .allow_modify_other_windows = true } },
        .setup = setup,
    });
}
