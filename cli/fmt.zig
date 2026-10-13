//! `oriel fmt`: format .oriel views, as `zig fmt` does Zig.
//!
//!     oriel fmt views/               every .oriel file under a directory, in place
//!     oriel fmt views/monitor.oriel  or the files named
//!     oriel fmt --check views/       list the unformatted files, exit 1 if any
//!     oriel fmt --stdin              format standard input to standard output
//!
//! One element per line, indented two spaces; attributes as written, each
//! ` key="value"`. A <text> keeps its content as written (the spaces in it
//! are text), on its open element's line; an <option> its label, trimmed.
//!
//! Apps run it as `zig build fmt-views` (the `fmt_tool` build of this file,
//! the same command over the app's directory).

const std = @import("std");
const Context = @import("Context.zig");

pub const Command = struct {
    pub const summary = "Format .oriel views (--check to only check, --stdin for editors)";
    pub const forward = "args";
    pub const usage =
        \\Usage: oriel fmt [--check] [--stdin] [paths...]
        \\
        \\Formats .oriel views in place: one element per line, indented two
        \\spaces. A directory means every .oriel file under it (hidden
        \\directories, zig-out*, zig-pkg and node_modules skipped). Prints the
        \\files it changed.
        \\
        \\  --check   change nothing: list the unformatted files, exit 1 if any
        \\  --stdin   format standard input to standard output
        \\
    ;
    args: []const []const u8 = &.{},
};

/// A view's largest size.
const max_bytes = 16 * 1024 * 1024;

pub fn run(ctx: Context, cmd: Command) !u8 {
    var check = false;
    var stdin = false;
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(ctx.gpa);
    for (cmd.args) |a| {
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            try ctx.out.writeAll(Command.usage);
            return 0;
        } else if (std.mem.eql(u8, a, "--check")) {
            check = true;
        } else if (std.mem.eql(u8, a, "--stdin")) {
            stdin = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            try ctx.err.print("error: unknown option {s}\nRun 'oriel fmt --help' for usage.\n", .{a});
            return 2;
        } else try paths.append(ctx.gpa, a);
    }
    if (stdin) {
        if (paths.items.len > 0) {
            try ctx.err.writeAll("error: --stdin takes no paths\n");
            return 2;
        }
        return formatStdin(ctx, check);
    }
    if (paths.items.len == 0) {
        try ctx.err.writeAll("error: expected a path (a .oriel file or a directory)\nRun 'oriel fmt --help' for usage.\n");
        return 2;
    }
    var tally: Tally = .{};
    for (paths.items) |path| try formatPath(ctx, path, check, &tally);
    if (tally.failed > 0) return 1;
    return if (check and tally.unformatted > 0) 1 else 0;
}

/// `fmt_tool`: this command on its own (`zig build fmt-views`).
pub fn main(init: std.process.Init) !u8 {
    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(init.io, &out_buf);
    var err_buf: [1024]u8 = undefined;
    var err = std.Io.File.stderr().writerStreaming(init.io, &err_buf);
    const ctx: Context = .{
        .gpa = init.gpa,
        .io = init.io,
        .environ = init.environ_map,
        .out = &out.interface,
        .err = &err.interface,
    };
    defer ctx.flush();
    const arena = init.arena.allocator();
    const all_args = try init.minimal.args.toSlice(arena);
    const argv = try arena.alloc([]const u8, all_args.len -| 1);
    for (argv, 1..) |*a, i| a.* = all_args[i];
    return run(ctx, .{ .args = argv }) catch |e| {
        ctx.err.print("error: {s}\n", .{@errorName(e)}) catch {};
        return 1;
    };
}

const Tally = struct { unformatted: usize = 0, failed: usize = 0 };

fn formatStdin(ctx: Context, check: bool) !u8 {
    var buf: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(ctx.io, &buf);
    const source = try reader.interface.allocRemaining(ctx.gpa, .limited(max_bytes));
    defer ctx.gpa.free(source);
    var diag: Diagnostic = .{};
    const formatted = format(ctx.gpa, source, &diag) catch |e| switch (e) {
        error.Syntax => {
            try report(ctx, "<stdin>", source, diag);
            return 1;
        },
        else => |other| return other,
    };
    defer ctx.gpa.free(formatted);
    if (check) return if (std.mem.eql(u8, source, formatted)) 0 else 1;
    try ctx.out.writeAll(formatted);
    return 0;
}

/// A file (whatever its extension), or every .oriel file under a directory.
fn formatPath(ctx: Context, path: []const u8, check: bool, tally: *Tally) !void {
    const cwd = std.Io.Dir.cwd();
    const st = cwd.statFile(ctx.io, path, .{}) catch |e| {
        try ctx.err.print("error: {s}: {s}\n", .{ path, @errorName(e) });
        tally.failed += 1;
        return;
    };
    if (st.kind != .directory) return formatFile(ctx, path, check, tally);
    var dir = try cwd.openDir(ctx.io, path, .{ .iterate = true });
    defer dir.close(ctx.io);
    var walker = try dir.walkSelectively(ctx.gpa);
    defer walker.deinit();
    while (try walker.next(ctx.io)) |entry| {
        if (entry.kind == .directory) {
            if (!skipped(entry.basename)) try walker.enter(ctx.io, entry);
            continue;
        }
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".oriel")) continue;
        const file = try std.fs.path.join(ctx.gpa, &.{ path, entry.path });
        defer ctx.gpa.free(file);
        try formatFile(ctx, file, check, tally);
    }
}

/// Directories no view lives in: hidden ones, build output, packages.
fn skipped(name: []const u8) bool {
    return name[0] == '.' or std.mem.startsWith(u8, name, "zig-out") or
        std.mem.eql(u8, name, "zig-pkg") or std.mem.eql(u8, name, "node_modules");
}

fn formatFile(ctx: Context, path: []const u8, check: bool, tally: *Tally) !void {
    const cwd = std.Io.Dir.cwd();
    const source = cwd.readFileAlloc(ctx.io, path, ctx.gpa, .limited(max_bytes)) catch |e| {
        try ctx.err.print("error: {s}: {s}\n", .{ path, @errorName(e) });
        tally.failed += 1;
        return;
    };
    defer ctx.gpa.free(source);
    var diag: Diagnostic = .{};
    const formatted = format(ctx.gpa, source, &diag) catch |e| switch (e) {
        error.Syntax => {
            try report(ctx, path, source, diag);
            tally.failed += 1;
            return;
        },
        else => |other| return other,
    };
    defer ctx.gpa.free(formatted);
    if (std.mem.eql(u8, source, formatted)) return;
    tally.unformatted += 1;
    if (!check) try cwd.writeFile(ctx.io, .{ .sub_path = path, .data = formatted });
    try ctx.out.print("{s}\n", .{path});
}

/// `path:line:column: error: message`.
fn report(ctx: Context, path: []const u8, source: []const u8, diag: Diagnostic) !void {
    var line: usize = 1;
    var column: usize = 1;
    for (source[0..@min(diag.at, source.len)]) |c| {
        if (c == '\n') {
            line += 1;
            column = 1;
        } else column += 1;
    }
    try ctx.err.print("{s}:{d}:{d}: error: {s}\n", .{ path, line, column, diag.message });
}

/// Where and why a view didn't parse.
pub const Diagnostic = struct { at: usize = 0, message: []const u8 = "" };

const Error = error{ Syntax, OutOfMemory, WriteFailed };

fn fail(diag: *Diagnostic, at: usize, message: []const u8) error{Syntax} {
    diag.* = .{ .at = at, .message = message };
    return error.Syntax;
}

/// The formatted view (caller frees). Reads the syntax oriel_markup.parse
/// does; what an element or attribute means is the compiler's to check.
pub fn format(gpa: std.mem.Allocator, source: []const u8, diag: *Diagnostic) Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    var stack: [32][]const u8 = undefined;
    var depth: usize = 0;
    var roots: usize = 0;
    var at: usize = 0;
    while (true) {
        skip(source, &at);
        if (at == source.len) break;
        if (source[at] != '<') return fail(diag, at, "text outside a <text> element");
        const start = at;
        at += 1;
        if (at < source.len and source[at] == '/') {
            at += 1;
            const name = word(source, &at) orelse return fail(diag, at, "expected an element name");
            try closeTag(source, &at, diag);
            if (depth == 0 or !std.mem.eql(u8, stack[depth - 1], name)) return fail(diag, start, "mismatched closing element");
            depth -= 1;
            try indent(w, depth);
            try w.print("</{s}>\n", .{name});
            continue;
        }
        const name = word(source, &at) orelse return fail(diag, at, "expected an element name");
        if (depth == 0) {
            if (roots > 0) return fail(diag, start, "more than one root element");
            roots += 1;
        }
        try indent(w, depth);
        try w.print("<{s}", .{name});
        try attributes(w, source, &at, diag);
        if (source[at] == '/') {
            at += 1;
            if (at == source.len or source[at] != '>') return fail(diag, at, "expected > after /");
            at += 1;
            try w.writeAll(" />\n");
            continue;
        }
        at += 1;
        try w.writeByte('>');
        // A <text>'s content is text, spaces and all; an <option>'s, its label.
        const verbatim = std.mem.eql(u8, name, "text") or std.mem.eql(u8, name, "option");
        if (verbatim) {
            const end = closing(source, at, name) orelse return fail(diag, start, "element is never closed");
            const content = source[at..end];
            try w.writeAll(if (name[0] == 'o') std.mem.trim(u8, content, " \t\r\n") else content);
            at = end + 2 + name.len;
            try closeTag(source, &at, diag);
            try w.print("</{s}>\n", .{name});
            continue;
        }
        // Closed right away: one line.
        var next = at;
        skip(source, &next);
        if (closing(source, next, name) == next) {
            at = next + 2 + name.len;
            try closeTag(source, &at, diag);
            try w.print("</{s}>\n", .{name});
            continue;
        }
        if (depth == stack.len) return fail(diag, start, "elements nested too deep");
        stack[depth] = name;
        depth += 1;
        try w.writeByte('\n');
    }
    if (depth > 0) return fail(diag, source.len, "element is never closed");
    return out.toOwnedSlice();
}

/// ` key="value"` for each attribute, up to the element's `>` or `/`.
fn attributes(w: *std.Io.Writer, s: []const u8, at: *usize, diag: *Diagnostic) Error!void {
    while (true) {
        skip(s, at);
        if (at.* == s.len) return fail(diag, at.*, "unterminated element");
        if (s[at.*] == '>' or s[at.*] == '/') return;
        const key = word(s, at) orelse return fail(diag, at.*, "expected an attribute name");
        skip(s, at);
        if (at.* == s.len or s[at.*] != '=') return fail(diag, at.*, "attribute needs =");
        at.* += 1;
        skip(s, at);
        if (at.* == s.len or s[at.*] != '"') return fail(diag, at.*, "attribute needs a quoted value");
        at.* += 1;
        const begin = at.*;
        const end = std.mem.indexOfScalarPos(u8, s, begin, '"') orelse return fail(diag, begin, "unterminated attribute value");
        try w.print(" {s}=\"{s}\"", .{ key, s[begin..end] });
        at.* = end + 1;
    }
}

/// Where `</name` starts, from `from` on (the first one: a <text>'s spans
/// are <span>s, never another <text>).
fn closing(s: []const u8, from: usize, name: []const u8) ?usize {
    var at = from;
    while (std.mem.indexOfPos(u8, s, at, "</")) |i| {
        var after = i + 2;
        const found = word(s, &after) orelse "";
        if (std.mem.eql(u8, found, name)) return i;
        at = i + 2;
    }
    return null;
}

/// The rest of a closing element after its name: spaces, then `>`.
fn closeTag(s: []const u8, at: *usize, diag: *Diagnostic) error{Syntax}!void {
    skip(s, at);
    if (at.* == s.len or s[at.*] != '>') return fail(diag, at.*, "expected >");
    at.* += 1;
}

fn indent(w: *std.Io.Writer, depth: usize) error{WriteFailed}!void {
    try w.splatByteAll(' ', depth * 2);
}

fn skip(s: []const u8, at: *usize) void {
    while (at.* < s.len and std.ascii.isWhitespace(s[at.*])) : (at.* += 1) {}
}

/// A name as oriel_markup reads one: letters, digits, `-` and `_`.
fn word(s: []const u8, at: *usize) ?[]const u8 {
    const start = at.*;
    while (at.* < s.len and (std.ascii.isAlphanumeric(s[at.*]) or s[at.*] == '-' or s[at.*] == '_')) : (at.* += 1) {}
    return if (at.* == start) null else s[start..at.*];
}

fn expectFormat(source: []const u8, expected: []const u8) !void {
    var diag: Diagnostic = .{};
    const got = try format(std.testing.allocator, source, &diag);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(expected, got);
    // Formatting is idempotent.
    const again = try format(std.testing.allocator, got, &diag);
    defer std.testing.allocator.free(again);
    try std.testing.expectEqualStrings(got, again);
}

test "one element per line, two-space indent" {
    try expectFormat(
        \\<column id="a"  gap = "4"><row><canvas id="c"/><view></view></row>
        \\<select id="s"><option value="1">  One </option></select></column>
    ,
        \\<column id="a" gap="4">
        \\  <row>
        \\    <canvas id="c" />
        \\    <view></view>
        \\  </row>
        \\  <select id="s">
        \\    <option value="1">One</option>
        \\  </select>
        \\</column>
        \\
    );
}

test "a <text> keeps its content as written" {
    try expectFormat(
        \\<row><text id="t" color="#fff"> {a} <span color="#f00">b</span> c </text></row>
    ,
        \\<row>
        \\  <text id="t" color="#fff"> {a} <span color="#f00">b</span> c </text>
        \\</row>
        \\
    );
}

test "syntax errors say where" {
    const cases = .{
        .{ "<row>hello</row>", "text outside a <text> element", 5 },
        .{ "<row></column>", "mismatched closing element", 5 },
        .{ "<row id=x></row>", "attribute needs a quoted value", 8 },
        .{ "<row><view>", "element is never closed", 11 },
        .{ "<row /><row />", "more than one root element", 7 },
        .{ "<text>never", "element is never closed", 0 },
    };
    inline for (cases) |c| {
        var diag: Diagnostic = .{};
        try std.testing.expectError(error.Syntax, format(std.testing.allocator, c[0], &diag));
        try std.testing.expectEqualStrings(c[1], diag.message);
        try std.testing.expectEqual(c[2], diag.at);
    }
}
