//! What a package holds besides the app's executable
//! (`PackageOptions.contents` in build/package.zig), as given to every
//! `package-*` command:
//!
//! - `--extra-exe <path>` (repeatable): another executable, installed next to
//!   the app's executable under its own basename.
//! - `--extra-file <relpath>=<src>` (repeatable): the file `src`, installed at
//!   `relpath` relative to the app executable's directory.

const std = @import("std");
const metadata = @import("metadata.zig");

/// An extra executable: `src` installed as `name` (the basename of `src`).
pub const Exe = struct {
    src: []const u8,
    name: []const u8,
};

/// An extra file: `src` installed at `rel` (`/`-separated, relative to the
/// directory of the app's executable).
pub const File = struct {
    rel: []const u8,
    src: []const u8,
};

pub const Contents = struct {
    exes: std.ArrayList(Exe) = .empty,
    files: std.ArrayList(File) = .empty,

    pub fn deinit(self: *Contents, gpa: std.mem.Allocator) void {
        self.exes.deinit(gpa);
        self.files.deinit(gpa);
    }

    pub fn isEmpty(self: *const Contents) bool {
        return self.exes.items.len == 0 and self.files.items.len == 0;
    }

    /// Take `--extra-exe <path>` or `--extra-file <relpath>=<src>` at
    /// `args[i.*]` (advancing `i.*` past the value). False for other
    /// arguments. The slices point into `args`.
    pub fn parseArg(self: *Contents, gpa: std.mem.Allocator, args: []const [:0]const u8, i: *usize) !bool {
        const arg = args[i.*];
        const is_exe = std.mem.eql(u8, arg, "--extra-exe");
        const is_file = std.mem.eql(u8, arg, "--extra-file");
        if (!is_exe and !is_file) return false;
        if (i.* + 1 >= args.len) return error.MissingValue;
        i.* += 1;
        const value: []const u8 = args[i.*];
        if (is_exe) {
            try self.exes.append(gpa, .{ .src = value, .name = std.fs.path.basename(value) });
        } else {
            const eq = std.mem.indexOfScalar(u8, value, '=') orelse return error.InvalidExtraFile;
            try self.files.append(gpa, .{ .rel = value[0..eq], .src = value[eq + 1 ..] });
        }
        return true;
    }

    /// Check every destination: extra executable names must be safe file
    /// names, file paths safe relative paths, and no two entries (nor an entry
    /// and one of `taken`, e.g. the app's executable) may land on the same
    /// path or on a directory another entry needs. Names compare without case
    /// (Windows and macOS file systems). On error `bad.*` is the offending
    /// destination.
    pub fn validate(self: *const Contents, taken: []const []const u8, bad: *[]const u8) !void {
        for (self.exes.items) |e| {
            bad.* = e.name;
            if (e.src.len == 0) return error.InvalidExeName;
            try metadata.validateExeName(e.name);
        }
        for (self.files.items) |f| {
            bad.* = f.rel;
            if (f.src.len == 0) return error.InvalidExtraFile;
            try metadata.validateRelativePath(f.rel);
        }
        var it = self.destinations();
        while (it.next()) |dest| {
            bad.* = dest;
            for (taken) |t| if (clash(dest, t)) return error.DuplicateDestination;
            var rest = it;
            while (rest.next()) |other| if (clash(dest, other)) return error.DuplicateDestination;
        }
    }

    /// Every destination path (exe names, then file paths).
    pub fn destinations(self: *const Contents) DestIterator {
        return .{ .c = self };
    }

    pub const DestIterator = struct {
        c: *const Contents,
        i: usize = 0,

        pub fn next(it: *DestIterator) ?[]const u8 {
            const exes = it.c.exes.items;
            const files = it.c.files.items;
            defer it.i += 1;
            if (it.i < exes.len) return exes[it.i].name;
            if (it.i < exes.len + files.len) return files[it.i - exes.len].rel;
            return null;
        }
    };
};

/// Same path, or one is a directory holding the other (case-insensitive).
fn clash(a: []const u8, b: []const u8) bool {
    if (a.len == b.len) return std.ascii.eqlIgnoreCase(a, b);
    const short, const long = if (a.len < b.len) .{ a, b } else .{ b, a };
    return long[short.len] == '/' and std.ascii.eqlIgnoreCase(short, long[0..short.len]);
}

/// The directories `rel` needs (`a`, `a/b` for `a/b/c`), as slices of `rel`.
pub fn parentDirs(rel: []const u8) ParentDirIterator {
    return .{ .rel = rel };
}

pub const ParentDirIterator = struct {
    rel: []const u8,
    pos: usize = 0,

    pub fn next(it: *ParentDirIterator) ?[]const u8 {
        const slash = std.mem.indexOfScalarPos(u8, it.rel, it.pos, '/') orelse return null;
        it.pos = slash + 1;
        return it.rel[0..slash];
    }
};

/// A message for a `validate` or `parseArg` error.
pub fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingValue => "--extra-exe and --extra-file need a value",
        error.InvalidExtraFile => "--extra-file expects <relpath>=<source>",
        error.InvalidExeName => "an extra executable's file name must match [A-Za-z0-9._+-]+ and not start with '-' or '.'",
        error.InvalidRelativePath => "a file path must be relative to the executable's directory, '/'-separated, without '.' or '..' components, control characters or any of \\ : * ? \" < > | =",
        error.DuplicateDestination => "two package entries (or an entry and the app's executable) have the same destination",
        else => @errorName(err),
    };
}

test "Contents.parseArg and validate" {
    const gpa = std.testing.allocator;
    var c: Contents = .{};
    defer c.deinit(gpa);
    const args = [_][:0]const u8{ "--extra-exe", "/out/bin/tool-cli", "--extra-file", "data/model.bin=/src/m.bin", "--other" };
    var i: usize = 0;
    try std.testing.expect(try c.parseArg(gpa, &args, &i));
    try std.testing.expectEqual(@as(usize, 1), i);
    i += 1;
    try std.testing.expect(try c.parseArg(gpa, &args, &i));
    i += 1;
    try std.testing.expect(!try c.parseArg(gpa, &args, &i));
    try std.testing.expectEqualStrings("tool-cli", c.exes.items[0].name);
    try std.testing.expectEqualStrings("data/model.bin", c.files.items[0].rel);
    try std.testing.expectEqualStrings("/src/m.bin", c.files.items[0].src);

    var bad: []const u8 = "";
    try c.validate(&.{"app"}, &bad);
    try std.testing.expectError(error.DuplicateDestination, c.validate(&.{"Tool-CLI"}, &bad));
    try std.testing.expectEqualStrings("tool-cli", bad);
    // A file where another entry needs a directory.
    try std.testing.expectError(error.DuplicateDestination, c.validate(&.{"data"}, &bad));

    try c.files.append(gpa, .{ .rel = "tool-cli", .src = "/x" });
    try std.testing.expectError(error.DuplicateDestination, c.validate(&.{}, &bad));
    c.files.items[1].rel = "../etc/x";
    try std.testing.expectError(error.InvalidRelativePath, c.validate(&.{}, &bad));
    try std.testing.expectEqualStrings("../etc/x", bad);
    _ = c.files.pop();
    try c.exes.append(gpa, .{ .src = "/x/-rf", .name = "-rf" });
    try std.testing.expectError(error.InvalidExeName, c.validate(&.{}, &bad));
}

test "Contents.parseArg rejects malformed values" {
    const gpa = std.testing.allocator;
    var c: Contents = .{};
    defer c.deinit(gpa);
    var i: usize = 0;
    try std.testing.expectError(error.InvalidExtraFile, c.parseArg(gpa, &.{ "--extra-file", "no-equals" }, &i));
    i = 0;
    try std.testing.expectError(error.MissingValue, c.parseArg(gpa, &.{"--extra-exe"}, &i));
}

test parentDirs {
    var it = parentDirs("a/b/c.bin");
    try std.testing.expectEqualStrings("a", it.next().?);
    try std.testing.expectEqualStrings("a/b", it.next().?);
    try std.testing.expect(it.next() == null);
    var flat = parentDirs("c.bin");
    try std.testing.expect(flat.next() == null);
}
