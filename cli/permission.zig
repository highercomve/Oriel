//! `oriel permission`: declare the OS permissions an app needs, in build.zig.
//!
//!     oriel permission add <kind> ["reason shown to the user"]
//!     oriel permission remove <kind>
//!     oriel permission list
//!
//! Edits `.permissions = .{ .<kind> = "<reason>", ... }` in the `addApp`
//! options. Kinds: microphone, camera, screen_capture, accessibility,
//! location, notifications, system_audio.

const std = @import("std");
const Context = @import("Context.zig");
const project = @import("project.zig");
const findMatchingClose = @import("deep_link.zig").findMatchingClose;

pub const Command = struct {
    pub const summary = "Declare the OS permissions the app needs (microphone, camera, ...)";
    pub const forward = "args";
    args: []const []const u8 = &.{},
};

pub const kinds = [_][]const u8{ "microphone", "camera", "screen_capture", "accessibility", "location", "notifications", "system_audio" };

pub fn isKind(name: []const u8) bool {
    for (kinds) |k| if (std.mem.eql(u8, k, name)) return true;
    return false;
}

pub const EditError = error{ MissingAddApp, MalformedAddAppOptions, MalformedPermissions, OutOfMemory };

const Entry = struct { kind: []const u8, reason: []const u8 };

/// Span of the addApp options `.{ ... }` (indices of the braces).
fn addAppOptions(source: []const u8) EditError!struct { open: usize, close: usize } {
    const idx = std.mem.indexOf(u8, source, "addApp(") orelse return error.MissingAddApp;
    const open = std.mem.indexOfScalarPos(u8, source, idx, '{') orelse return error.MalformedAddAppOptions;
    const close = findMatchingClose(source, open, '{', '}') orelse return error.MalformedAddAppOptions;
    return .{ .open = open, .close = close };
}

/// Span of the `.permissions = .{ ... }` block inside the addApp options:
/// `start` is the `.permissions` token, `open`/`close` its braces.
fn permissionsBlock(source: []const u8, opts_open: usize, opts_close: usize) EditError!?struct { start: usize, open: usize, close: usize } {
    const rel = std.mem.indexOf(u8, source[opts_open..opts_close], ".permissions") orelse return null;
    const start = opts_open + rel;
    const open = std.mem.indexOfScalarPos(u8, source, start, '{') orelse return error.MalformedPermissions;
    if (open > opts_close) return error.MalformedPermissions;
    const close = findMatchingClose(source, open, '{', '}') orelse return error.MalformedPermissions;
    return .{ .start = start, .open = open, .close = close };
}

/// The `.kind = "reason"` entries of a permissions block body. Reasons are
/// returned as written (escapes kept). Caller frees the slice.
fn parseEntries(gpa: std.mem.Allocator, body: []const u8) ![]Entry {
    var list: std.ArrayList(Entry) = .empty;
    errdefer list.deinit(gpa);
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, body, i, '.')) |dot| {
        var j = dot + 1;
        while (j < body.len and (std.ascii.isAlphanumeric(body[j]) or body[j] == '_')) : (j += 1) {}
        const name = body[dot + 1 .. j];
        const q1 = std.mem.indexOfScalarPos(u8, body, j, '"') orelse break;
        var q2 = q1 + 1;
        while (q2 < body.len and body[q2] != '"') : (q2 += 1) {
            if (body[q2] == '\\') q2 += 1;
        }
        if (q2 >= body.len) break;
        if (name.len > 0) try list.append(gpa, .{ .kind = name, .reason = body[q1 + 1 .. q2] });
        i = q2 + 1;
    }
    return list.toOwnedSlice(gpa);
}

/// Zig string literal contents for `s`.
fn escapeInto(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        else => if (c < 0x20 or c == 0x7f) try out.print(gpa, "\\x{x:0>2}", .{c}) else try out.append(gpa, c),
    };
}

/// Rewrite the permissions block with `entries` (in kind order).
fn render(gpa: std.mem.Allocator, out: *std.ArrayList(u8), entries: []const Entry, indent: []const u8, raw_reasons: bool) !void {
    try out.appendSlice(gpa, ".permissions = .{");
    for (kinds) |k| for (entries) |e| {
        if (!std.mem.eql(u8, e.kind, k)) continue;
        try out.print(gpa, "\n{s}    .{s} = \"", .{ indent, k });
        if (raw_reasons) try out.appendSlice(gpa, e.reason) else try escapeInto(gpa, out, e.reason);
        try out.appendSlice(gpa, "\",");
    };
    try out.print(gpa, "\n{s}}}", .{indent});
}

/// Indentation of the line holding `pos`.
fn lineIndent(source: []const u8, pos: usize) []const u8 {
    const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..pos], '\n')) |n| n + 1 else 0;
    var e = line_start;
    while (e < source.len and (source[e] == ' ' or source[e] == '\t')) : (e += 1) {}
    return source[line_start..e];
}

/// Add or replace `kind` (reason as plain text) in build.zig; `kind == null`
/// with `remove_kind` set removes it instead. Returns the new source.
pub fn edit(gpa: std.mem.Allocator, source: []const u8, op: union(enum) { add: Entry, remove: []const u8 }) EditError![]u8 {
    const opts = try addAppOptions(source);
    const block = try permissionsBlock(source, opts.open, opts.close);

    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(gpa);
    // Existing reasons are kept raw (already escaped); the new one is escaped.
    var escaped_new: std.ArrayList(u8) = .empty;
    defer escaped_new.deinit(gpa);
    if (block) |b| {
        const parsed = parseEntries(gpa, source[b.open + 1 .. b.close]) catch return error.OutOfMemory;
        defer gpa.free(parsed);
        try entries.appendSlice(gpa, parsed);
    }
    switch (op) {
        .add => |a| {
            try escapeInto(gpa, &escaped_new, a.reason);
            for (entries.items) |*e| {
                if (std.mem.eql(u8, e.kind, a.kind)) {
                    e.reason = escaped_new.items;
                    break;
                }
            } else try entries.append(gpa, .{ .kind = a.kind, .reason = escaped_new.items });
        },
        .remove => |k| {
            var i: usize = 0;
            while (i < entries.items.len) {
                if (std.mem.eql(u8, entries.items[i].kind, k)) _ = entries.orderedRemove(i) else i += 1;
            }
        },
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (block) |b| {
        const indent = lineIndent(source, b.start);
        if (entries.items.len == 0) {
            // Drop the whole field, with its trailing comma and line.
            var end = b.close + 1;
            if (end < source.len and source[end] == ',') end += 1;
            var start = b.start;
            const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..start], '\n')) |n| n + 1 else 0;
            if (std.mem.trim(u8, source[line_start..start], " \t").len == 0) start = line_start;
            if (start == line_start and end < source.len and source[end] == '\n') end += 1;
            try out.appendSlice(gpa, source[0..start]);
            try out.appendSlice(gpa, source[end..]);
        } else {
            try out.appendSlice(gpa, source[0..b.start]);
            try render(gpa, &out, entries.items, indent, true);
            try out.appendSlice(gpa, source[b.close + 1 ..]);
        }
    } else {
        if (entries.items.len == 0) {
            try out.appendSlice(gpa, source);
            return out.toOwnedSlice(gpa);
        }
        // Insert before the closing brace of the addApp options.
        const close_indent = lineIndent(source, opts.close);
        var field_indent_buf: [64]u8 = undefined;
        const field_indent = std.fmt.bufPrint(&field_indent_buf, "{s}    ", .{close_indent}) catch close_indent;
        var insert_at = opts.close;
        while (insert_at > 0 and (source[insert_at - 1] == ' ' or source[insert_at - 1] == '\t')) insert_at -= 1;
        try out.appendSlice(gpa, source[0..insert_at]);
        if (insert_at > 0 and source[insert_at - 1] != '\n') try out.appendSlice(gpa, "\n");
        try out.appendSlice(gpa, field_indent);
        try render(gpa, &out, entries.items, field_indent, true);
        try out.appendSlice(gpa, ",\n");
        try out.appendSlice(gpa, close_indent);
        try out.appendSlice(gpa, source[opts.close..]);
    }
    return out.toOwnedSlice(gpa);
}

pub fn run(ctx: Context, cmd: Command) !u8 {
    const a = cmd.args;
    if (a.len == 0 or std.mem.eql(u8, a[0], "--help") or std.mem.eql(u8, a[0], "-h")) {
        try ctx.out.writeAll(
            \\Usage: oriel permission <command>
            \\
            \\Commands:
            \\  add <kind> ["reason"]  Declare a permission; the reason is what the OS shows
            \\                         the user (default: a generic text)
            \\  remove <kind>          Remove a declared permission
            \\  list                   Show the declared permissions
            \\
            \\Kinds: microphone, camera, screen_capture, accessibility, location,
            \\       notifications, system_audio
            \\
            \\The app requests them at runtime with oriel.permissions.request(kind)
            \\(Zig) or oriel.permissions.request("kind") (JS); undeclared ones are denied.
            \\
        );
        return 0;
    }
    const sub = a[0];
    const is_add = std.mem.eql(u8, sub, "add");
    const is_remove = std.mem.eql(u8, sub, "remove");
    const is_list = std.mem.eql(u8, sub, "list");
    if (!is_add and !is_remove and !is_list) {
        try ctx.err.print("error: unknown permission command '{s}'. Run 'oriel permission --help' for usage.\n", .{sub});
        return 1;
    }
    if (!is_list) {
        if (a.len < 2) {
            try ctx.err.print("error: 'oriel permission {s}' requires a <kind>\n", .{sub});
            return 1;
        }
        if (!isKind(a[1])) {
            try ctx.err.print("error: unknown permission '{s}'; one of: microphone, camera, screen_capture, accessibility, location, notifications, system_audio\n", .{a[1]});
            return 1;
        }
    }

    const cwd = try std.process.currentPathAlloc(ctx.io, ctx.gpa);
    defer ctx.gpa.free(cwd);
    const root = try project.findRoot(ctx.gpa, ctx.io, cwd) orelse {
        try ctx.err.print("error: no build.zig.zon in {s} or any parent directory; run this inside an Oriel app\n", .{cwd});
        return 1;
    };
    defer ctx.gpa.free(root);
    var root_dir = try std.Io.Dir.cwd().openDir(ctx.io, root, .{});
    defer root_dir.close(ctx.io);
    const source = root_dir.readFileAlloc(ctx.io, "build.zig", ctx.gpa, .limited(10 * 1024 * 1024)) catch |err| {
        try ctx.err.print("error: could not read {s}/build.zig: {s}\n", .{ root, @errorName(err) });
        return 1;
    };
    defer ctx.gpa.free(source);

    if (is_list) {
        const opts = addAppOptions(source) catch {
            try ctx.err.writeAll("error: could not find `addApp(...)` in build.zig\n");
            return 1;
        };
        const block = permissionsBlock(source, opts.open, opts.close) catch null;
        const b = block orelse {
            try ctx.out.writeAll("No permissions declared (modules like audio_capture declare their own).\n");
            return 0;
        };
        const entries = try parseEntries(ctx.gpa, source[b.open + 1 .. b.close]);
        defer ctx.gpa.free(entries);
        for (entries) |e| try ctx.out.print("{s}: {s}\n", .{ e.kind, if (e.reason.len == 0) "(default reason)" else e.reason });
        return 0;
    }

    const updated = edit(ctx.gpa, source, if (is_add)
        .{ .add = .{ .kind = a[1], .reason = if (a.len > 2) a[2] else "" } }
    else
        .{ .remove = a[1] }) catch |err| {
        try ctx.err.print("error: could not edit build.zig: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer ctx.gpa.free(updated);
    if (std.mem.eql(u8, updated, source)) {
        try ctx.out.print("build.zig already {s} '{s}'\n", .{ if (is_add) "declares" else "doesn't declare", a[1] });
        return 0;
    }
    try root_dir.writeFile(ctx.io, .{ .sub_path = "build.zig", .data = updated });
    if (is_add) {
        try ctx.out.print("Declared '{s}' in build.zig. Request it at runtime with oriel.permissions.request(\"{s}\").\n", .{ a[1], a[1] });
    } else {
        try ctx.out.print("Removed '{s}' from build.zig.\n", .{a[1]});
    }
    return 0;
}

const test_source =
    \\pub fn build(b: *std.Build) void {
    \\    const dep = b.dependency("oriel", .{ .target = target });
    \\    _ = oriel.addApp(b, dep, .{
    \\        .name = "my-app",
    \\        .frontend = .{ .dir = "frontend" },
    \\    });
    \\}
    \\
;

test "add, replace, list, remove" {
    const gpa = std.testing.allocator;
    const a1 = try edit(gpa, test_source, .{ .add = .{ .kind = "microphone", .reason = "Dictation \"live\"" } });
    defer gpa.free(a1);
    try std.testing.expect(std.mem.indexOf(u8, a1,
        \\        .frontend = .{ .dir = "frontend" },
        \\        .permissions = .{
        \\            .microphone = "Dictation \"live\"",
        \\        },
        \\    });
    ) != null);

    const a2 = try edit(gpa, a1, .{ .add = .{ .kind = "accessibility", .reason = "" } });
    defer gpa.free(a2);
    const a3 = try edit(gpa, a2, .{ .add = .{ .kind = "microphone", .reason = "New reason" } });
    defer gpa.free(a3);
    try std.testing.expect(std.mem.indexOf(u8, a3,
        \\        .permissions = .{
        \\            .microphone = "New reason",
        \\            .accessibility = "",
        \\        },
    ) != null);

    const opts = try addAppOptions(a3);
    const b = (try permissionsBlock(a3, opts.open, opts.close)).?;
    const entries = try parseEntries(gpa, a3[b.open + 1 .. b.close]);
    defer gpa.free(entries);
    try std.testing.expectEqual(@as(usize, 2), entries.len);

    const r1 = try edit(gpa, a3, .{ .remove = "microphone" });
    defer gpa.free(r1);
    const r2 = try edit(gpa, r1, .{ .remove = "accessibility" });
    defer gpa.free(r2);
    try std.testing.expectEqualStrings(test_source, r2);

    // The result must still parse as Zig.
    const z = try gpa.dupeZ(u8, a3);
    defer gpa.free(z);
    var ast = try std.zig.Ast.parse(gpa, z, .zig);
    defer ast.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
}
