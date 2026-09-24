//! SQLite-vec extension wrapper.
//!
//! Exposes version info and vector serialization helpers, and registers
//! the extension automatically on every SQLite connection.

const std = @import("std");
const oriel = @import("../oriel.zig");

pub const c = @cImport({
    @cInclude("sqlite3.h");
    @cInclude("sqlite-vec.h");
});

/// Return the sqlite-vec version string (e.g. "v0.1.9").
pub fn version() []const u8 {
    return c.SQLITE_VEC_VERSION;
}

/// Convert a slice of f32 to raw bytes suitable for sqlite-vec blob bindings.
pub fn asBytes(vec: []const f32) []const u8 {
    return std.mem.sliceAsBytes(vec);
}

/// Smoke check for oriel checkAll: reports the runtime `vec_version()` and
/// runs a KNN query on an in-memory `vec0` table.
pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    const db = try oriel.sql.Db.open(":memory:");
    defer db.close();

    var ver_stmt = try db.prepare("SELECT vec_version();");
    defer ver_stmt.finalize();
    if (!try ver_stmt.step()) return error.NoVersionRow;
    const ver = try ver_stmt.text(gpa, 0);
    defer gpa.free(ver);

    try db.exec("CREATE VIRTUAL TABLE v USING vec0(embedding float[2]);");
    try db.exec("INSERT INTO v(rowid, embedding) VALUES (1, '[1, 0]'), (2, '[0, 1]');");
    var knn = try db.prepare("SELECT rowid FROM v WHERE embedding MATCH '[0.9, 0.2]' ORDER BY distance LIMIT 1;");
    defer knn.finalize();
    const nearest: i64 = if (try knn.step()) knn.int(0) else 0;

    return .{
        .module = "sqlite_vec",
        .ok = nearest == 1,
        .detail = try std.fmt.allocPrint(gpa, "sqlite-vec {s}: vec0 KNN nearest rowid {d} (want 1)", .{ ver, nearest }),
    };
}

test {
    std.testing.refAllDecls(@This());
}

test "sqlite-vec check" {
    const res = try check(std.testing.allocator, undefined);
    defer std.testing.allocator.free(res.detail);
    try std.testing.expect(res.ok);
    try std.testing.expect(std.mem.indexOf(u8, res.detail, "sqlite-vec") != null);
}

test "sqlite-vec in-memory KNN query" {
    const db = try oriel.sql.Db.open(":memory:");
    defer db.close();

    try db.exec("CREATE VIRTUAL TABLE v USING vec0(embedding float[4]);");

    const row1 = [_]f32{ 1.0, 0.0, 0.0, 0.0 };
    const row2 = [_]f32{ 0.0, 1.0, 0.0, 0.0 };
    const row3 = [_]f32{ 0.7, 0.3, 0.0, 0.0 };

    {
        var ins = try db.prepare("INSERT INTO v(rowid, embedding) VALUES (?, ?);");
        defer ins.finalize();

        try ins.bindInt(1, 1);
        try ins.bindBlob(2, asBytes(&row1));
        _ = try ins.step();
    }
    {
        var ins = try db.prepare("INSERT INTO v(rowid, embedding) VALUES (?, ?);");
        defer ins.finalize();

        try ins.bindInt(1, 2);
        try ins.bindBlob(2, asBytes(&row2));
        _ = try ins.step();
    }
    {
        var ins = try db.prepare("INSERT INTO v(rowid, embedding) VALUES (?, ?);");
        defer ins.finalize();

        try ins.bindInt(1, 3);
        try ins.bindBlob(2, asBytes(&row3));
        _ = try ins.step();
    }

    // KNN query: find the 2 nearest neighbors to [0.9, 0.1, 0.0, 0.0]
    // Distance to row 1 [1.0, 0.0, 0, 0]: (0.1)^2 + (0.1)^2 = 0.02
    // Distance to row 3 [0.7, 0.3, 0, 0]: (0.2)^2 + (-0.2)^2 = 0.08
    // Distance to row 2 [0.0, 1.0, 0, 0]: (0.9)^2 + (-0.9)^2 = 1.62
    // Row 1 is closest (dist ~0.1414), then row 3 (dist ~0.2828). No ties.
    const query_vec = [_]f32{ 0.9, 0.1, 0.0, 0.0 };
    var query_stmt = try db.prepare("SELECT rowid, distance FROM v WHERE embedding MATCH ? ORDER BY distance LIMIT 2;");
    defer query_stmt.finalize();

    try query_stmt.bindBlob(1, asBytes(&query_vec));

    // First result: row 1
    try std.testing.expect(try query_stmt.step());
    const id1 = query_stmt.int(0);
    const dist1 = query_stmt.float(1);

    // Second result: row 3
    try std.testing.expect(try query_stmt.step());
    const id2 = query_stmt.int(0);
    const dist2 = query_stmt.float(1);

    // No further rows
    try std.testing.expect(!try query_stmt.step());

    // Assert exact nearest ids and strictly ascending distances
    try std.testing.expectEqual(@as(i64, 1), id1);
    try std.testing.expectEqual(@as(i64, 3), id2);
    try std.testing.expect(dist1 < dist2);
}
