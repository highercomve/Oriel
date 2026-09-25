//! SQLite, compiled from the amalgamation in build.zig.

const std = @import("std");
const oriel = @import("../oriel.zig");
pub const c = @cImport(@cInclude("sqlite3.h"));

extern fn sqlite3_vec_init(db: ?*c.sqlite3, pzErrMsg: ?*[*c]u8, pApi: ?*const anyopaque) c_int;

pub const Db = struct {
    handle: *c.sqlite3,

    pub fn open(path: [:0]const u8) !Db {
        var handle: ?*c.sqlite3 = null;
        if (c.sqlite3_open(path.ptr, &handle) != c.SQLITE_OK) {
            if (handle) |h| _ = c.sqlite3_close(h);
            return error.SqliteOpen;
        }
        if (oriel.options.sqlite_vec) {
            if (sqlite3_vec_init(handle.?, null, null) != c.SQLITE_OK) {
                _ = c.sqlite3_close(handle.?);
                return error.SqliteVecInit;
            }
        }
        return .{ .handle = handle.? };
    }

    pub fn close(self: Db) void {
        _ = c.sqlite3_close(self.handle);
    }

    pub fn exec(self: Db, sql: [:0]const u8) !void {
        if (c.sqlite3_exec(self.handle, sql.ptr, null, null, null) != c.SQLITE_OK) {
            return error.SqliteExec;
        }
    }

    pub fn prepare(self: Db, sql: [:0]const u8) !Stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.SqlitePrepare;
        return .{ .handle = stmt.? };
    }

    pub fn lastInsertRowId(self: Db) i64 {
        return c.sqlite3_last_insert_rowid(self.handle);
    }

    /// Run a query returning a single integer.
    pub fn scalarInt(self: Db, sql: [:0]const u8) !i64 {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.SqlitePrepare;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.SqliteNoRow;
        return c.sqlite3_column_int64(stmt, 0);
    }
};

/// SQLITE_TRANSIENT: SQLite copies bound data. (The C macro is a cast of -1,
/// which translate-c can't express.) All-ones isn't an aligned function
/// address on arm64, where `@ptrFromInt` refuses it, so the bits go through
/// an extern union instead; SQLite only compares the value, never calls it.
fn sqliteTransient() c.sqlite3_destructor_type {
    const Bits = extern union { int: usize, ptr: c.sqlite3_destructor_type };
    var bits: Bits = .{ .int = std.math.maxInt(usize) };
    return (&bits).ptr;
}

/// A prepared statement. Bind indexes are 1-based, column indexes 0-based.
pub const Stmt = struct {
    handle: *c.sqlite3_stmt,

    pub fn finalize(self: Stmt) void {
        _ = c.sqlite3_finalize(self.handle);
    }

    pub fn bindText(self: Stmt, index: c_int, value: []const u8) !void {
        if (c.sqlite3_bind_text64(self.handle, index, value.ptr, value.len, sqliteTransient(), c.SQLITE_UTF8) != c.SQLITE_OK) return error.SqliteBind;
    }

    pub fn bindInt(self: Stmt, index: c_int, value: i64) !void {
        if (c.sqlite3_bind_int64(self.handle, index, value) != c.SQLITE_OK) return error.SqliteBind;
    }

    pub fn bindBlob(self: Stmt, index: c_int, value: []const u8) !void {
        if (c.sqlite3_bind_blob64(self.handle, index, value.ptr, value.len, sqliteTransient()) != c.SQLITE_OK) return error.SqliteBind;
    }

    /// Advance to the next row; false when done.
    pub fn step(self: Stmt) !bool {
        return switch (c.sqlite3_step(self.handle)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => error.SqliteStep,
        };
    }

    pub fn int(self: Stmt, col: c_int) i64 {
        return c.sqlite3_column_int64(self.handle, col);
    }

    pub fn float(self: Stmt, col: c_int) f64 {
        return c.sqlite3_column_double(self.handle, col);
    }

    /// Column text, copied into `gpa` (SQLite's buffer dies on the next step).
    pub fn text(self: Stmt, gpa: std.mem.Allocator, col: c_int) ![]u8 {
        const ptr = c.sqlite3_column_text(self.handle, col) orelse return gpa.dupe(u8, "");
        const len: usize = @intCast(c.sqlite3_column_bytes(self.handle, col));
        return gpa.dupe(u8, ptr[0..len]);
    }
};

pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    const db = try Db.open(":memory:");
    defer db.close();
    try db.exec("CREATE TABLE clips (id INTEGER PRIMARY KEY, name TEXT);" ++
        "INSERT INTO clips (name) VALUES ('intro'), ('demo'), ('outro');");
    const rows = try db.scalarInt("SELECT count(*) FROM clips");
    return .{
        .module = "sql",
        .ok = rows == 3,
        .detail = try std.fmt.allocPrint(gpa, "SQLite {s} in-memory: {d} rows", .{ c.sqlite3_libversion(), rows }),
    };
}

test "bound text and blobs are copied (SQLITE_TRANSIENT)" {
    const gpa = std.testing.allocator;
    const db = try Db.open(":memory:");
    defer db.close();
    try db.exec("CREATE TABLE t (s TEXT, b BLOB)");

    const insert = try db.prepare("INSERT INTO t (s, b) VALUES (?1, ?2)");
    defer insert.finalize();
    var text_buf = "hello".*;
    var blob_buf = [_]u8{ 1, 2, 3 };
    try insert.bindText(1, &text_buf);
    try insert.bindBlob(2, &blob_buf);
    // SQLite must have its own copies: overwrite ours before the insert runs.
    @memset(&text_buf, 'x');
    @memset(&blob_buf, 0);
    _ = try insert.step();

    const select = try db.prepare("SELECT s, hex(b) FROM t");
    defer select.finalize();
    try std.testing.expect(try select.step());
    const s = try select.text(gpa, 0);
    defer gpa.free(s);
    const b = try select.text(gpa, 1);
    defer gpa.free(b);
    try std.testing.expectEqualStrings("hello", s);
    try std.testing.expectEqualStrings("010203", b);
}
