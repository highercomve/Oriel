//! Desktop entry generation according to XDG Desktop Entry Specification.

const std = @import("std");
const metadata = @import("metadata.zig");

pub const DesktopOptions = struct {
    app_id: []const u8,
    name: []const u8,
    exec: []const u8,
    icon: []const u8,
    comment: ?[]const u8 = null,
    categories: ?[]const u8 = null,
    terminal: bool = false,
    startup_notify: bool = true,
    startup_wm_class: ?[]const u8 = null,
    url_schemes: []const []const u8 = &.{},
};

/// Format desktop categories ensuring a trailing semicolon.
pub fn formatCategories(allocator: std.mem.Allocator, raw: ?[]const u8) ![]const u8 {
    const s = raw orelse "Utility;";
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    if (trimmed.len == 0) return try allocator.dupe(u8, "Utility;");
    if (trimmed[trimmed.len - 1] == ';') {
        return try allocator.dupe(u8, trimmed);
    } else {
        return try std.fmt.allocPrint(allocator, "{s};", .{trimmed});
    }
}

/// Generate a valid .desktop file content according to XDG Desktop Entry Specification.
pub fn generateDesktop(allocator: std.mem.Allocator, opts: DesktopOptions) ![]const u8 {
    try metadata.validateNoControlOrNewline(opts.app_id);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;

    try w.writeAll("[Desktop Entry]\n");
    try w.writeAll("Type=Application\n");

    const escaped_name = try metadata.escapeDesktopString(allocator, opts.name);
    defer allocator.free(escaped_name);
    try w.print("Name={s}\n", .{escaped_name});

    if (opts.comment) |c| {
        const trimmed = std.mem.trim(u8, c, " \t\r\n");
        if (trimmed.len > 0) {
            const escaped_comment = try metadata.escapeDesktopString(allocator, trimmed);
            defer allocator.free(escaped_comment);
            try w.print("Comment={s}\n", .{escaped_comment});
        }
    }

    const escaped_exec = try metadata.escapeDesktopExec(allocator, opts.exec);
    defer allocator.free(escaped_exec);
    if (opts.url_schemes.len > 0 and std.mem.indexOf(u8, opts.exec, "%u") == null and std.mem.indexOf(u8, opts.exec, "%U") == null) {
        try w.print("Exec={s} %u\n", .{escaped_exec});
    } else {
        try w.print("Exec={s}\n", .{escaped_exec});
    }

    const escaped_icon = try metadata.escapeDesktopString(allocator, opts.icon);
    defer allocator.free(escaped_icon);
    try w.print("Icon={s}\n", .{escaped_icon});

    const cat = try formatCategories(allocator, opts.categories);
    defer allocator.free(cat);
    const escaped_cat = try metadata.escapeDesktopString(allocator, cat);
    defer allocator.free(escaped_cat);
    try w.print("Categories={s}\n", .{escaped_cat});

    try w.print("Terminal={s}\n", .{if (opts.terminal) "true" else "false"});
    try w.print("StartupNotify={s}\n", .{if (opts.startup_notify) "true" else "false"});

    const wm_class = opts.startup_wm_class orelse opts.app_id;
    const escaped_wm_class = try metadata.escapeDesktopString(allocator, wm_class);
    defer allocator.free(escaped_wm_class);
    try w.print("StartupWMClass={s}\n", .{escaped_wm_class});

    if (opts.url_schemes.len > 0) {
        try w.writeAll("MimeType=");
        for (opts.url_schemes) |s| {
            try w.print("x-scheme-handler/{s};", .{s});
        }
        try w.writeAll("\n");
    }

    return try allocator.dupe(u8, out.written());
}

test "generateDesktop standard" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const desktop = try generateDesktop(gpa, .{
        .app_id = "dev.oriel.ReactNotes",
        .name = "React Notes",
        .exec = "oriel-react-notes",
        .icon = "dev.oriel.ReactNotes",
        .comment = "Notes application",
        .categories = "Utility;TextEditor",
    });
    defer gpa.free(desktop);

    try testing.expect(std.mem.indexOf(u8, desktop, "[Desktop Entry]\n") != null);
    try testing.expect(std.mem.indexOf(u8, desktop, "Type=Application\n") != null);
    try testing.expect(std.mem.indexOf(u8, desktop, "Name=React Notes\n") != null);
    try testing.expect(std.mem.indexOf(u8, desktop, "Comment=Notes application\n") != null);
    try testing.expect(std.mem.indexOf(u8, desktop, "Exec=oriel-react-notes\n") != null);
    try testing.expect(std.mem.indexOf(u8, desktop, "Icon=dev.oriel.ReactNotes\n") != null);
    try testing.expect(std.mem.indexOf(u8, desktop, "Categories=Utility;TextEditor;\n") != null);
    try testing.expect(std.mem.indexOf(u8, desktop, "Terminal=false\n") != null);
    try testing.expect(std.mem.indexOf(u8, desktop, "StartupNotify=true\n") != null);
    try testing.expect(std.mem.indexOf(u8, desktop, "StartupWMClass=dev.oriel.ReactNotes\n") != null);
}

test "formatCategories" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const cat1 = try formatCategories(gpa, "Utility;Development");
    defer gpa.free(cat1);
    try testing.expectEqualStrings("Utility;Development;", cat1);

    const cat2 = try formatCategories(gpa, "Office;");
    defer gpa.free(cat2);
    try testing.expectEqualStrings("Office;", cat2);

    const cat3 = try formatCategories(gpa, null);
    defer gpa.free(cat3);
    try testing.expectEqualStrings("Utility;", cat3);
}

test "generateDesktop escaping and validation" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const desktop = try generateDesktop(gpa, .{
        .app_id = "dev.oriel.SpecialApp",
        .name = "Special \\ Name with \"Quotes\"",
        .exec = "/usr/local/bin/my special app$1",
        .icon = "dev.oriel.SpecialApp",
        .comment = "Multi-line\ncomment with\ttabs",
    });
    defer gpa.free(desktop);

    try testing.expect(std.mem.indexOf(u8, desktop, "Name=Special \\\\ Name with \"Quotes\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, desktop, "Comment=Multi-line\\ncomment with\\ttabs\n") != null);
    try testing.expect(std.mem.indexOf(u8, desktop, "Exec=\"/usr/local/bin/my special app\\\\$1\"\n") != null);
}

test "generateDesktop with url_schemes" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const desktop = try generateDesktop(gpa, .{
        .app_id = "dev.oriel.ReactNotes",
        .name = "React Notes",
        .exec = "oriel-react-notes",
        .icon = "dev.oriel.ReactNotes",
        .url_schemes = &.{ "oriel-notes", "notes" },
    });
    defer gpa.free(desktop);

    try testing.expect(std.mem.indexOf(u8, desktop, "Exec=oriel-react-notes %u\n") != null);
    try testing.expect(std.mem.indexOf(u8, desktop, "MimeType=x-scheme-handler/oriel-notes;x-scheme-handler/notes;\n") != null);
}
