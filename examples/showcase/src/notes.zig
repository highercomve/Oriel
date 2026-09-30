//! The Notes tab: SQLite (`oriel.sql`) in the app's data directory, and
//! deep links: `oriel-showcase://note/<text>` adds a note, from a browser,
//! another app or a terminal (`xdg-open`, `open`, `adb shell am start -d`).

const std = @import("std");
const oriel = @import("oriel");
const sql = oriel.sql;

const log = std.log.scoped(.notes);

pub const Note = struct {
    id: i64,
    text: []const u8,
    created_at: []const u8,
};

var io: std.Io = undefined;
var app_id: []const u8 = "";
var db: ?sql.Db = null;
var mutex: std.Io.Mutex = .init;

pub fn init(app_io: std.Io, id: []const u8) void {
    io = app_io;
    app_id = id;
}

/// `notes.db` in the app's data directory, so notes survive restarts; in
/// memory if that directory can't be used.
fn database() !sql.Db {
    if (db) |d| return d;
    const gpa = std.heap.smp_allocator;
    const d = open: {
        const dir = oriel.store.dataDir(gpa, app_id) catch |err| {
            log.warn("no data dir ({s}): notes are kept in memory", .{@errorName(err)});
            break :open try sql.Db.open(":memory:");
        };
        defer gpa.free(dir);
        std.Io.Dir.cwd().createDirPath(io, dir) catch {};
        const path = try std.fs.path.joinZ(gpa, &.{ dir, "notes.db" });
        defer gpa.free(path);
        break :open try sql.Db.open(path);
    };
    errdefer d.close();
    try d.exec(
        \\CREATE TABLE IF NOT EXISTS notes (
        \\  id INTEGER PRIMARY KEY,
        \\  text TEXT NOT NULL,
        \\  created_at TEXT NOT NULL DEFAULT (datetime('now', 'localtime'))
        \\);
    );
    db = d;
    return d;
}

fn lock() void {
    mutex.lockUncancelable(io);
}

pub fn list(gpa: std.mem.Allocator) ![]Note {
    lock();
    defer mutex.unlock(io);
    return listLocked(gpa);
}

fn listLocked(gpa: std.mem.Allocator) ![]Note {
    const stmt = try (try database()).prepare("SELECT id, text, created_at FROM notes ORDER BY id DESC");
    defer stmt.finalize();
    var notes: std.ArrayList(Note) = .empty;
    while (try stmt.step()) {
        try notes.append(gpa, .{ .id = stmt.int(0), .text = try stmt.text(gpa, 1), .created_at = try stmt.text(gpa, 2) });
    }
    return notes.toOwnedSlice(gpa);
}

pub fn add(gpa: std.mem.Allocator, text_in: []const u8) ![]Note {
    const text = std.mem.trim(u8, text_in, " \t\r\n");
    if (text.len == 0) return error.EmptyNote;
    lock();
    defer mutex.unlock(io);
    const stmt = try (try database()).prepare("INSERT INTO notes (text) VALUES (?1)");
    defer stmt.finalize();
    try stmt.bindText(1, text);
    _ = try stmt.step();
    return listLocked(gpa);
}

pub fn delete(gpa: std.mem.Allocator, id: i64) ![]Note {
    lock();
    defer mutex.unlock(io);
    const stmt = try (try database()).prepare("DELETE FROM notes WHERE id = ?1");
    defer stmt.finalize();
    try stmt.bindInt(1, id);
    _ = try stmt.step();
    return listLocked(gpa);
}

/// The note's text in `oriel-showcase://note/<text>` (percent-decoded in
/// `buf`), or null for other links.
pub fn textFromLink(url: []const u8, buf: []u8) ?[]const u8 {
    const prefix = "oriel-showcase://note/";
    if (!std.ascii.startsWithIgnoreCase(url, prefix)) return null;
    const raw = url[prefix.len..];
    if (raw.len > buf.len) return null;
    @memcpy(buf[0..raw.len], raw);
    // "+" is a space in query-style encodings too.
    for (buf[0..raw.len]) |*ch| if (ch.* == '+') {
        ch.* = ' ';
    };
    const text = std.Uri.percentDecodeInPlace(buf[0..raw.len]);
    const trimmed = std.mem.trim(u8, text, " \t\r\n/");
    return if (trimmed.len == 0) null else trimmed;
}

test textFromLink {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("Hello world", textFromLink("oriel-showcase://note/Hello%20world", &buf).?);
    try std.testing.expectEqualStrings("a b", textFromLink("oriel-showcase://note/a+b/", &buf).?);
    try std.testing.expect(textFromLink("oriel-showcase://other/x", &buf) == null);
    try std.testing.expect(textFromLink("oriel-showcase://note/", &buf) == null);
}
