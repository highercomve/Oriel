//! Notes: a small oriel app with a React + Vite frontend.
//!
//! The Zig side owns the data (SQLite via oriel's `sql` module); the React
//! side calls these commands through the generated, typed `invoke()` and
//! gets live updates through `listen()`. A tray icon keeps the app running
//! when the window is closed.

const std = @import("std");
const builtin = @import("builtin");
const oriel = @import("oriel");
const app = @import("oriel_app");
const sql = oriel.sql;
const Tray = oriel.tray.Tray;

pub const Note = struct {
    id: i64,
    text: []const u8,
    created_at: []const u8,
};

/// Events pushed from Zig to the page (typed on both sides).
pub const Events = struct {
    notes_changed: []const Note,
    do_not_disturb: bool,
};
const events = oriel.App.events(Events);

var db: ?sql.Db = null;
var tray: ?*Tray = null;

fn database() !sql.Db {
    if (db) |d| return d;
    const d = try sql.Db.open(":memory:");
    try d.exec(
        \\CREATE TABLE notes (
        \\  id INTEGER PRIMARY KEY,
        \\  text TEXT NOT NULL,
        \\  created_at TEXT NOT NULL DEFAULT (datetime('now', 'localtime'))
        \\);
    );
    db = d;
    return d;
}

pub const Commands = struct {
    pub fn greet(gpa: std.mem.Allocator, args: struct { name: []const u8 }) ![]const u8 {
        return std.fmt.allocPrint(gpa, "Hello, {s}! Greetings from Zig.", .{args.name});
    }

    pub fn app_info(_: std.mem.Allocator) struct { zig: []const u8, mode: []const u8, dev: bool, os: []const u8 } {
        return .{
            .zig = builtin.zig_version_string,
            .mode = @tagName(builtin.mode),
            .dev = app.dev != null,
            .os = @tagName(builtin.os.tag),
        };
    }

    pub fn list_notes(gpa: std.mem.Allocator) ![]Note {
        const stmt = try (try database()).prepare("SELECT id, text, created_at FROM notes ORDER BY id DESC");
        defer stmt.finalize();
        var notes: std.ArrayList(Note) = .empty;
        while (try stmt.step()) {
            try notes.append(gpa, .{ .id = stmt.int(0), .text = try stmt.text(gpa, 1), .created_at = try stmt.text(gpa, 2) });
        }
        return notes.toOwnedSlice(gpa);
    }

    pub fn add_note(gpa: std.mem.Allocator, args: struct { text: []const u8 }) ![]Note {
        const text = std.mem.trim(u8, args.text, " \t\r\n");
        if (text.len == 0) return error.EmptyNote;
        const stmt = try (try database()).prepare("INSERT INTO notes (text) VALUES (?1)");
        defer stmt.finalize();
        try stmt.bindText(1, text);
        _ = try stmt.step();
        return list_notes(gpa);
    }

    pub fn do_not_disturb(_: std.mem.Allocator) bool {
        return if (tray) |t| t.isChecked("dnd") orelse false else false;
    }

    pub const async_commands = .{ "export_notes" };

    pub fn export_notes(gpa: std.mem.Allocator, local_io: std.Io) ![]const u8 {
        // Simulate a slow async export off the main thread.
        const timeout: std.Io.Timeout = .{
            .duration = .{
                .raw = .{ .nanoseconds = 300 * std.time.ns_per_ms },
                .clock = .awake,
            },
        };
        try timeout.sleep(local_io);

        const notes = try list_notes(gpa);
        var out: std.ArrayList(u8) = .empty;
        for (notes) |note| {
            const line = try std.fmt.allocPrint(gpa, "- [{s}] {s}\n", .{ note.created_at, note.text });
            try out.appendSlice(gpa, line);
        }
        return out.toOwnedSlice(gpa);
    }

    pub fn delete_note(gpa: std.mem.Allocator, args: struct { id: i64 }) ![]Note {
        const stmt = try (try database()).prepare("DELETE FROM notes WHERE id = ?1");
        defer stmt.finalize();
        try stmt.bindInt(1, args.id);
        _ = try stmt.step();
        return list_notes(gpa);
    }
};

const app_id = "dev.oriel.ReactNotes";

fn setup() !void {
    tray = try Tray.create(std.heap.smp_allocator, .{
        .id = app_id,
        .title = "oriel notes",
        .tooltip = "Notes are kept while the window is closed",
        .icon = .{ .png = @embedFile("icon.png") },
        .menu = &.{
            .{ .item = .{ .id = "show", .label = "Show notes" } },
            .{ .item = .{ .id = "quick_note", .label = "Add quick note" } },
            .{ .check = .{ .id = "dnd", .label = "Do not disturb" } },
            .separator,
            .{ .submenu = .{ .label = "Help", .items = &.{
                .{ .item = .{ .id = "website", .label = "Open ziglang.org" } },
            } } },
            .{ .item = .{ .id = "quit", .label = "Quit" } },
        },
        .on_menu = onTrayMenu,
    });

    if (oriel.options.deep_link) {
        oriel.deep_link.onOpen(onDeepLink);
    }
}

fn onDeepLink(url: []const u8) void {
    handleDeepLinkUrl(url) catch |err| std.log.err("deep link error: {s}", .{@errorName(err)});
}

fn handleDeepLinkUrl(url: []const u8) !void {
    const uri = std.Uri.parse(url) catch return error.InvalidUri;
    if (!std.mem.eql(u8, uri.scheme, "oriel-notes")) return error.DisallowedScheme;

    var path_buf: [2048]u8 = undefined;
    const raw_path = uri.path.toRaw(&path_buf) catch return error.PathTooLong;

    var raw_host_buf: [256]u8 = undefined;
    const raw_host = if (uri.host) |h| h.toRaw(&raw_host_buf) catch return error.HostTooLong else null;

    var text: []const u8 = "";
    if (raw_host) |h| {
        if (std.mem.eql(u8, h, "note")) {
            text = std.mem.trimStart(u8, raw_path, "/");
        }
    } else if (std.mem.startsWith(u8, raw_path, "/note/")) {
        text = raw_path[6..];
    } else if (std.mem.startsWith(u8, raw_path, "note/")) {
        text = raw_path[5..];
    } else {
        return error.InvalidPath;
    }

    text = std.mem.trim(u8, text, " \t\r\n");
    if (text.len == 0) return;

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const notes = try Commands.add_note(arena.allocator(), .{ .text = text });
    events.emit(.notes_changed, notes);
    std.log.info("deep link added note: '{s}'", .{text});
    oriel.App.showWindow();
}

fn onTrayMenu(id: []const u8, checked: ?bool) void {
    const eql = std.mem.eql;
    if (eql(u8, id, "show")) {
        oriel.App.showWindow();
    } else if (eql(u8, id, "quick_note")) {
        addQuickNote() catch |err| std.log.err("quick note: {s}", .{@errorName(err)});
    } else if (eql(u8, id, "dnd")) {
        events.emit(.do_not_disturb, checked.?);
    } else if (eql(u8, id, "website")) {
        oriel.App.openExternal("https://ziglang.org");
    } else if (eql(u8, id, "quit")) {
        oriel.App.quit(0);
    }
}

fn addQuickNote() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const notes = try Commands.add_note(arena.allocator(), .{ .text = "Quick note from the tray" });
    events.emit(.notes_changed, notes);
}

pub fn main(init: std.process.Init) !u8 {
    defer if (db) |d| d.close();
    defer if (tray) |t| t.deinit();
    return oriel.main(init, .{ .commands = Commands, .events = Events }, .{
        .id = app_id,
        .title = "oriel · React notes",
        .width = 820,
        .height = 640,
        .assets = app.assets,
        .dev = app.dev,
        .setup = setup,
        // Closing the window keeps the app in the tray.
        .on_close = .hide,
        .deep_link_schemes = app.url_schemes,
    });
}
