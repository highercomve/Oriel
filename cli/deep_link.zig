//! `oriel deep-link`: manage deep link URL schemes and registration.
//!
//! Subcommands:
//! - `add <scheme>`: enable deep_link in build.zig and register scheme in package url_schemes
//! - `register`: register local dev build in OS (XDG desktop on Linux, HKCU on Windows)
//! - `unregister`: remove local dev registration

const std = @import("std");
const builtin = @import("builtin");
const Context = @import("Context.zig");
const project = @import("project.zig");

pub const Command = struct {
    pub const summary = "Configure and register deep link URL schemes";
    pub const forward = "args";
    args: []const []const u8 = &.{},
};

pub const EditError = error{
    MissingOrielDependency,
    MissingAddApp,
    MalformedDependencyOptions,
    MalformedAddAppOptions,
    InvalidScheme,
    OutOfMemory,
};

/// Validate that a scheme string is valid per RFC 3986 §3.1:
/// ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )
pub fn validateScheme(scheme: []const u8) bool {
    if (scheme.len == 0) return false;
    const first = scheme[0];
    const is_alpha = (first >= 'a' and first <= 'z') or (first >= 'A' and first <= 'Z');
    if (!is_alpha) return false;
    for (scheme[1..]) |c| {
        const is_alnum = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9');
        const is_allowed = is_alnum or c == '+' or c == '-' or c == '.';
        if (!is_allowed) return false;
    }
    return true;
}

/// Find matching closing bracket/parenthesis/brace taking nested pairs into account.
fn findMatchingClose(source: []const u8, open_idx: usize, open_char: u8, close_char: u8) ?usize {
    if (open_idx >= source.len or source[open_idx] != open_char) return null;
    var depth: usize = 0;
    var i: usize = open_idx;
    var in_string = false;
    var escape = false;

    while (i < source.len) : (i += 1) {
        const c = source[i];
        if (in_string) {
            if (escape) {
                escape = false;
            } else if (c == '\\') {
                escape = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }

        if (c == '"') {
            in_string = true;
            continue;
        }

        if (c == open_char) {
            depth += 1;
        } else if (c == close_char) {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

/// Edit build.zig content to:
/// 1. Set `.deep_link = true` in `b.dependency("oriel", .{ ... })`.
/// 2. Add `scheme` to `.package = .{ .url_schemes = &.{ ... } }` in `addApp`.
/// Idempotent.
pub fn editBuildZig(allocator: std.mem.Allocator, source: []const u8, scheme: []const u8) EditError![]u8 {
    if (!validateScheme(scheme)) return error.InvalidScheme;

    // 1. Locate b.dependency("oriel", ...
    const dep_anchor = "dependency(\"oriel\"";
    const dep_idx = std.mem.indexOf(u8, source, dep_anchor) orelse return error.MissingOrielDependency;

    // Find the opening `.{` for options in b.dependency("oriel", .{ ... })
    const dep_open_brace = blk: {
        var idx = dep_idx + dep_anchor.len;
        while (idx < source.len and source[idx] != '{') : (idx += 1) {}
        if (idx >= source.len) return error.MalformedDependencyOptions;
        break :blk idx;
    };
    const dep_close_brace = findMatchingClose(source, dep_open_brace, '{', '}') orelse
        return error.MalformedDependencyOptions;

    const dep_opts_text = source[dep_open_brace .. dep_close_brace + 1];

    var intermediate: std.ArrayList(u8) = .empty;
    defer intermediate.deinit(allocator);

    // Check if .deep_link is already in dep_opts_text
    if (std.mem.indexOf(u8, dep_opts_text, ".deep_link = true") != null) {
        // Already enabled, keep dep options as-is
        try intermediate.appendSlice(allocator, source);
    } else if (std.mem.indexOf(u8, dep_opts_text, ".deep_link = false")) |false_pos| {
        // Replace .deep_link = false with .deep_link = true
        const abs_false_pos = dep_open_brace + false_pos;
        try intermediate.appendSlice(allocator, source[0..abs_false_pos]);
        try intermediate.appendSlice(allocator, ".deep_link = true");
        try intermediate.appendSlice(allocator, source[abs_false_pos + ".deep_link = false".len ..]);
    } else {
        // Insert .deep_link = true, right after dep_open_brace
        try intermediate.appendSlice(allocator, source[0 .. dep_open_brace + 1]);
        // Detect indentation
        var newline_idx = dep_open_brace;
        var indent = "\n        ";
        while (newline_idx > 0 and source[newline_idx] != '\n') : (newline_idx -= 1) {}
        if (newline_idx < dep_open_brace) {
            // Check if opening brace is followed by newline
            if (dep_open_brace + 1 < source.len and source[dep_open_brace + 1] == '\n') {
                indent = "\n        ";
            }
        }
        try intermediate.appendSlice(allocator, indent);
        try intermediate.appendSlice(allocator, ".deep_link = true,");
        try intermediate.appendSlice(allocator, source[dep_open_brace + 1 ..]);
    }

    const stage1 = intermediate.items;

    // 2. Locate addApp(...)
    const add_app_anchor = "addApp(";
    const add_app_idx = std.mem.indexOf(u8, stage1, add_app_anchor) orelse return error.MissingAddApp;

    // Find the opening `.{` of the 3rd argument to addApp(b, dep, .{ ... })
    // Count two commas outside of brackets/strings
    var comma_count: usize = 0;
    var i = add_app_idx + add_app_anchor.len;
    var app_opts_open: ?usize = null;
    while (i < stage1.len) : (i += 1) {
        const c = stage1[i];
        if (c == '(' or c == '{' or c == '[') {
            const close_c: u8 = if (c == '(') ')' else if (c == '{') '}' else ']';
            const close_idx = findMatchingClose(stage1, i, c, close_c) orelse return error.MalformedAddAppOptions;
            i = close_idx;
            continue;
        }
        if (c == ',') {
            comma_count += 1;
            if (comma_count == 2) {
                // Next opening brace is options
                var j = i + 1;
                while (j < stage1.len and stage1[j] != '{') : (j += 1) {}
                if (j < stage1.len) {
                    app_opts_open = j;
                    break;
                }
            }
        }
    }

    const opts_open = app_opts_open orelse return error.MalformedAddAppOptions;
    const opts_close = findMatchingClose(stage1, opts_open, '{', '}') orelse return error.MalformedAddAppOptions;
    const app_opts_text = stage1[opts_open .. opts_close + 1];

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    // Look for `.package = ` inside app_opts_text
    if (std.mem.indexOf(u8, app_opts_text, ".package =")) |pkg_rel_idx| {
        const pkg_abs_start = opts_open + pkg_rel_idx;
        var pkg_brace_open = pkg_abs_start;
        while (pkg_brace_open < opts_close and stage1[pkg_brace_open] != '{') : (pkg_brace_open += 1) {}
        if (pkg_brace_open >= opts_close) return error.MalformedAddAppOptions;

        const pkg_brace_close = findMatchingClose(stage1, pkg_brace_open, '{', '}') orelse return error.MalformedAddAppOptions;
        const pkg_text = stage1[pkg_brace_open .. pkg_brace_close + 1];

        // Inside package, check for .url_schemes
        if (std.mem.indexOf(u8, pkg_text, ".url_schemes =")) |schemes_rel_idx| {
            const schemes_abs_start = pkg_brace_open + schemes_rel_idx;
            var array_brace_open = schemes_abs_start;
            while (array_brace_open < pkg_brace_close and stage1[array_brace_open] != '{') : (array_brace_open += 1) {}
            if (array_brace_open >= pkg_brace_close) return error.MalformedAddAppOptions;

            const array_brace_close = findMatchingClose(stage1, array_brace_open, '{', '}') orelse return error.MalformedAddAppOptions;
            const schemes_text = stage1[array_brace_open .. array_brace_close + 1];

            // Check if scheme is already in schemes_text
            var target_buf: [128]u8 = undefined;
            const target_str = std.fmt.bufPrint(&target_buf, "\"{s}\"", .{scheme}) catch return error.OutOfMemory;
            if (std.mem.indexOf(u8, schemes_text, target_str) != null) {
                // Already present!
                return try allocator.dupe(u8, stage1);
            }

            // Insert into .url_schemes = &.{ ... }
            try result.appendSlice(allocator, stage1[0 .. array_brace_close]);
            if (array_brace_close > array_brace_open + 1 and stage1[array_brace_close - 1] != '{' and stage1[array_brace_close - 1] != ' ' and stage1[array_brace_close - 1] != '\n') {
                try result.appendSlice(allocator, ", ");
            } else if (array_brace_close > array_brace_open + 1 and stage1[array_brace_close - 1] == ' ') {
                // leave spacing
            }
            try result.append(allocator, '"');
            try result.appendSlice(allocator, scheme);
            try result.append(allocator, '"');
            try result.appendSlice(allocator, stage1[array_brace_close..]);
        } else {
            // package exists, but url_schemes does not
            try result.appendSlice(allocator, stage1[0 .. pkg_brace_open + 1]);
            try result.appendSlice(allocator, "\n            .url_schemes = &.{\"");
            try result.appendSlice(allocator, scheme);
            try result.appendSlice(allocator, "\"},");
            try result.appendSlice(allocator, stage1[pkg_brace_open + 1 ..]);
        }
    } else {
        // No .package in addApp options, insert .package = .{ .url_schemes = &.{"<scheme>"} },
        try result.appendSlice(allocator, stage1[0 .. opts_open + 1]);
        try result.appendSlice(allocator, "\n        .package = .{\n            .url_schemes = &.{\"");
        try result.appendSlice(allocator, scheme);
        try result.appendSlice(allocator, "\"},\n        },");
        try result.appendSlice(allocator, stage1[opts_open + 1 ..]);
    }

    return result.toOwnedSlice(allocator);
}

/// Parse declared schemes from build.zig
pub fn parseSchemesFromBuildZig(allocator: std.mem.Allocator, build_zig_text: []const u8) ![][]const u8 {
    var schemes: std.ArrayList([]const u8) = .empty;
    defer schemes.deinit(allocator);

    const anchor = ".url_schemes =";
    if (std.mem.indexOf(u8, build_zig_text, anchor)) |pos| {
        var i = pos + anchor.len;
        while (i < build_zig_text.len and build_zig_text[i] != '{') : (i += 1) {}
        if (i < build_zig_text.len) {
            const close_idx = findMatchingClose(build_zig_text, i, '{', '}') orelse return schemes.toOwnedSlice(allocator);
            const inside = build_zig_text[i + 1 .. close_idx];
            var it = std.mem.tokenizeAny(u8, inside, " \t\r\n,\"\';");
            while (it.next()) |token| {
                if (validateScheme(token)) {
                    try schemes.append(allocator, try allocator.dupe(u8, token));
                }
            }
        }
    }
    return schemes.toOwnedSlice(allocator);
}

/// Parse app id from build.zig
pub fn parseAppIdFromBuildZig(allocator: std.mem.Allocator, build_zig_text: []const u8) ?[]const u8 {
    const anchor = ".id =";
    if (std.mem.indexOf(u8, build_zig_text, anchor)) |pos| {
        const rest = build_zig_text[pos + anchor.len ..];
        var it = std.mem.tokenizeAny(u8, rest, " \t\r\n,\";");
        if (it.next()) |token| {
            return allocator.dupe(u8, token) catch null;
        }
    }
    return null;
}

/// Parse executable name from build.zig
pub fn parseExeNameFromBuildZig(allocator: std.mem.Allocator, build_zig_text: []const u8) ?[]const u8 {
    const anchor = ".name =";
    if (std.mem.indexOf(u8, build_zig_text, anchor)) |pos| {
        const rest = build_zig_text[pos + anchor.len ..];
        var it = std.mem.tokenizeAny(u8, rest, " \t\r\n,\";");
        if (it.next()) |token| {
            return allocator.dupe(u8, token) catch null;
        }
    }
    return null;
}

pub fn run(ctx: Context, cmd: Command) !u8 {
    if (cmd.args.len == 0 or std.mem.eql(u8, cmd.args[0], "--help") or std.mem.eql(u8, cmd.args[0], "-h")) {
        try ctx.out.writeAll(
            \\Usage: oriel deep-link <command> [args...]
            \\
            \\Commands:
            \\  add <scheme>    Enable deep_link in build.zig and register scheme in package url_schemes
            \\  register        Register the built dev app locally for deep link handling
            \\  unregister      Remove local dev registration for deep link handling
            \\
        );
        return 0;
    }

    const sub = cmd.args[0];
    if (std.mem.eql(u8, sub, "add")) {
        return runAdd(ctx, cmd.args[1..]);
    } else if (std.mem.eql(u8, sub, "register")) {
        return runRegister(ctx);
    } else if (std.mem.eql(u8, sub, "unregister")) {
        return runUnregister(ctx);
    } else {
        try ctx.err.print("error: unknown deep-link command '{s}'. Run 'oriel deep-link --help' for usage.\n", .{sub});
        return 1;
    }
}

fn runAdd(ctx: Context, args: []const []const u8) !u8 {
    if (args.len == 0) {
        try ctx.err.writeAll("error: 'oriel deep-link add' requires a <scheme> argument\n");
        return 1;
    }
    const scheme = args[0];
    if (!validateScheme(scheme)) {
        try ctx.err.print("error: invalid URL scheme '{s}': schemes must start with a letter and contain only ASCII alphanumeric, '+', '-', or '.'\n", .{scheme});
        return 1;
    }

    const cwd = try std.process.currentPathAlloc(ctx.io, ctx.gpa);
    defer ctx.gpa.free(cwd);

    const root = try project.findRoot(ctx.gpa, ctx.io, cwd) orelse {
        try ctx.err.print("error: no build.zig.zon in {s} or any parent directory; run this inside an Oriel app\n", .{cwd});
        return 1;
    };
    defer ctx.gpa.free(root);

    const build_zig_path = try std.fs.path.join(ctx.gpa, &.{ root, "build.zig" });
    defer ctx.gpa.free(build_zig_path);

    const build_zig_content = std.Io.Dir.cwd().readFileAlloc(ctx.io, build_zig_path, ctx.gpa, .limited(10 * 1024 * 1024)) catch |err| {
        try ctx.err.print("error: could not read {s}: {s}\n", .{ build_zig_path, @errorName(err) });
        return 1;
    };
    defer ctx.gpa.free(build_zig_content);

    const updated = editBuildZig(ctx.gpa, build_zig_content, scheme) catch |err| switch (err) {
        error.MissingOrielDependency => {
            try ctx.err.writeAll("error: could not find `b.dependency(\"oriel\", ...)` in build.zig\n");
            return 1;
        },
        error.MissingAddApp => {
            try ctx.err.writeAll("error: could not find `addApp(...)` call in build.zig\n");
            return 1;
        },
        error.MalformedDependencyOptions => {
            try ctx.err.writeAll("error: malformed options in `b.dependency(\"oriel\", ...)`\n");
            return 1;
        },
        error.MalformedAddAppOptions => {
            try ctx.err.writeAll("error: malformed options in `addApp(...)`\n");
            return 1;
        },
        error.InvalidScheme => {
            try ctx.err.print("error: invalid scheme format: '{s}'\n", .{scheme});
            return 1;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer ctx.gpa.free(updated);

    if (std.mem.eql(u8, updated, build_zig_content)) {
        try ctx.out.print("Scheme '{s}' is already configured in build.zig\n", .{scheme});
        return 0;
    }

    try std.Io.Dir.cwd().writeFile(ctx.io, .{
        .sub_path = build_zig_path,
        .data = updated,
    });

    try ctx.out.print("Added scheme '{s}' and enabled deep_link in build.zig\n", .{scheme});
    return 0;
}

fn runRegister(ctx: Context) !u8 {
    if (builtin.os.tag == .macos) {
        try ctx.out.writeAll("needs an .app bundle\n");
        return 0;
    }

    const cwd = try std.process.currentPathAlloc(ctx.io, ctx.gpa);
    defer ctx.gpa.free(cwd);

    const root = try project.findRoot(ctx.gpa, ctx.io, cwd) orelse {
        try ctx.err.print("error: no build.zig.zon in {s} or any parent directory\n", .{cwd});
        return 1;
    };
    defer ctx.gpa.free(root);

    const build_zig_path = try std.fs.path.join(ctx.gpa, &.{ root, "build.zig" });
    defer ctx.gpa.free(build_zig_path);

    const build_zig_content = std.Io.Dir.cwd().readFileAlloc(ctx.io, build_zig_path, ctx.gpa, .limited(10 * 1024 * 1024)) catch |err| {
        try ctx.err.print("error: could not read {s}: {s}\n", .{ build_zig_path, @errorName(err) });
        return 1;
    };
    defer ctx.gpa.free(build_zig_content);

    const schemes = try parseSchemesFromBuildZig(ctx.gpa, build_zig_content);
    defer {
        for (schemes) |s| ctx.gpa.free(s);
        ctx.gpa.free(schemes);
    }

    if (schemes.len == 0) {
        try ctx.err.writeAll("error: no URL schemes configured in build.zig. Use `oriel deep-link add <scheme>` first.\n");
        return 1;
    }

    const app_id = parseAppIdFromBuildZig(ctx.gpa, build_zig_content) orelse "dev.oriel.App";
    defer ctx.gpa.free(app_id);

    const exe_name = parseExeNameFromBuildZig(ctx.gpa, build_zig_content) orelse "app";
    defer ctx.gpa.free(exe_name);

    if (builtin.os.tag == .linux) {
        const bin_path = try builtExe(ctx, root, exe_name) orelse {
            try ctx.err.writeAll("error: no built executable in zig-out/bin; run `oriel dev` or `oriel build` first\n");
            return 1;
        };
        defer ctx.gpa.free(bin_path);

        // Resolve data home
        const data_home = blk: {
            if (ctx.environ.get("XDG_DATA_HOME")) |xdg| {
                if (xdg.len > 0 and std.fs.path.isAbsolute(xdg)) break :blk try ctx.gpa.dupe(u8, xdg);
            }
            if (ctx.environ.get("HOME")) |home| {
                if (home.len > 0 and std.fs.path.isAbsolute(home)) break :blk try std.fmt.allocPrint(ctx.gpa, "{s}/.local/share", .{home});
            }
            try ctx.err.writeAll("error: neither XDG_DATA_HOME nor HOME is set\n");
            return 1;
        };
        defer ctx.gpa.free(data_home);

        const apps_dir = try std.fmt.allocPrint(ctx.gpa, "{s}/applications", .{data_home});
        defer ctx.gpa.free(apps_dir);
        try std.Io.Dir.cwd().createDirPath(ctx.io, apps_dir);

        const desktop_file_path = try std.fmt.allocPrint(ctx.gpa, "{s}/{s}.desktop", .{ apps_dir, app_id });
        defer ctx.gpa.free(desktop_file_path);

        var mimetypes: std.ArrayList(u8) = .empty;
        defer mimetypes.deinit(ctx.gpa);
        for (schemes) |s| {
            try mimetypes.appendSlice(ctx.gpa, "x-scheme-handler/");
            try mimetypes.appendSlice(ctx.gpa, s);
            try mimetypes.append(ctx.gpa, ';');
        }

        const desktop_content = try std.fmt.allocPrint(ctx.gpa,
            \\[Desktop Entry]
            \\Type=Application
            \\Name={s}
            \\Exec={s} %u
            \\Terminal=false
            \\StartupNotify=true
            \\StartupWMClass={s}
            \\MimeType={s}
            \\
        , .{ exe_name, bin_path, app_id, mimetypes.items });
        defer ctx.gpa.free(desktop_content);

        try std.Io.Dir.cwd().writeFile(ctx.io, .{
            .sub_path = desktop_file_path,
            .data = desktop_content,
        });

        const desktop_filename = try std.fmt.allocPrint(ctx.gpa, "{s}.desktop", .{app_id});
        defer ctx.gpa.free(desktop_filename);

        for (schemes) |s| {
            const mime = try std.fmt.allocPrint(ctx.gpa, "x-scheme-handler/{s}", .{s});
            defer ctx.gpa.free(mime);
            _ = ctx.run(&.{ "xdg-mime", "default", desktop_filename, mime }, null);
        }

        try ctx.out.print("Registered dev desktop handler: {s}\n", .{desktop_file_path});
        return 0;
    } else if (builtin.os.tag == .windows) {
        const bin_path = try builtExe(ctx, root, exe_name) orelse {
            try ctx.err.writeAll("error: no built executable in zig-out/bin; run `oriel dev` or `oriel build` first\n");
            return 1;
        };
        defer ctx.gpa.free(bin_path);

        for (schemes) |s| {
            const root_key = try std.fmt.allocPrint(ctx.gpa, "HKCU\\Software\\Classes\\{s}", .{s});
            defer ctx.gpa.free(root_key);
            const cmd_key = try std.fmt.allocPrint(ctx.gpa, "HKCU\\Software\\Classes\\{s}\\shell\\open\\command", .{s});
            defer ctx.gpa.free(cmd_key);

            const url_desc = try std.fmt.allocPrint(ctx.gpa, "URL:{s}", .{exe_name});
            defer ctx.gpa.free(url_desc);
            const cmd_val = try std.fmt.allocPrint(ctx.gpa, "\"{s}\" \"%1\"", .{bin_path});
            defer ctx.gpa.free(cmd_val);

            if (ctx.capture(&.{ "reg", "add", root_key, "/ve", "/d", url_desc, "/f" }, 30_000)) |r| r.deinit(ctx.gpa);
            if (ctx.capture(&.{ "reg", "add", root_key, "/v", "URL Protocol", "/d", "", "/f" }, 30_000)) |r| r.deinit(ctx.gpa);
            if (ctx.capture(&.{ "reg", "add", cmd_key, "/ve", "/d", cmd_val, "/f" }, 30_000)) |r| r.deinit(ctx.gpa);
        }

        try ctx.out.print("Registered Windows HKCU classes for schemes\n", .{});
        return 0;
    }

    return 0;
}

fn runUnregister(ctx: Context) !u8 {
    if (builtin.os.tag == .macos) {
        try ctx.out.writeAll("needs an .app bundle\n");
        return 0;
    }

    const cwd = try std.process.currentPathAlloc(ctx.io, ctx.gpa);
    defer ctx.gpa.free(cwd);

    const root = try project.findRoot(ctx.gpa, ctx.io, cwd) orelse {
        try ctx.err.print("error: no build.zig.zon in {s} or any parent directory\n", .{cwd});
        return 1;
    };
    defer ctx.gpa.free(root);

    const build_zig_path = try std.fs.path.join(ctx.gpa, &.{ root, "build.zig" });
    defer ctx.gpa.free(build_zig_path);

    const build_zig_content = std.Io.Dir.cwd().readFileAlloc(ctx.io, build_zig_path, ctx.gpa, .limited(10 * 1024 * 1024)) catch |err| {
        try ctx.err.print("error: could not read {s}: {s}\n", .{ build_zig_path, @errorName(err) });
        return 1;
    };
    defer ctx.gpa.free(build_zig_content);

    const app_id = parseAppIdFromBuildZig(ctx.gpa, build_zig_content) orelse "dev.oriel.App";
    defer ctx.gpa.free(app_id);

    const schemes = try parseSchemesFromBuildZig(ctx.gpa, build_zig_content);
    defer {
        for (schemes) |s| ctx.gpa.free(s);
        ctx.gpa.free(schemes);
    }

    if (builtin.os.tag == .linux) {
        const data_home = blk: {
            if (ctx.environ.get("XDG_DATA_HOME")) |xdg| {
                if (xdg.len > 0 and std.fs.path.isAbsolute(xdg)) break :blk try ctx.gpa.dupe(u8, xdg);
            }
            if (ctx.environ.get("HOME")) |home| {
                if (home.len > 0 and std.fs.path.isAbsolute(home)) break :blk try std.fmt.allocPrint(ctx.gpa, "{s}/.local/share", .{home});
            }
            try ctx.err.writeAll("error: neither XDG_DATA_HOME nor HOME is set\n");
            return 1;
        };
        defer ctx.gpa.free(data_home);

        const desktop_file_path = try std.fmt.allocPrint(ctx.gpa, "{s}/applications/{s}.desktop", .{ data_home, app_id });
        defer ctx.gpa.free(desktop_file_path);

        std.Io.Dir.cwd().deleteFile(ctx.io, desktop_file_path) catch |err| {
            if (err != error.FileNotFound) {
                try ctx.err.print("warning: failed to delete {s}: {s}\n", .{ desktop_file_path, @errorName(err) });
            }
        };

        try ctx.out.print("Unregistered dev desktop handler: {s}\n", .{desktop_file_path});
        return 0;
    } else if (builtin.os.tag == .windows) {
        for (schemes) |s| {
            const root_key = try std.fmt.allocPrint(ctx.gpa, "HKCU\\Software\\Classes\\{s}", .{s});
            defer ctx.gpa.free(root_key);
            if (ctx.capture(&.{ "reg", "delete", root_key, "/f" }, 30_000)) |r| r.deinit(ctx.gpa);
        }
        try ctx.out.print("Unregistered Windows HKCU classes for schemes\n", .{});
        return 0;
    }

    return 0;
}

test "editBuildZig adds scheme and enables deep_link on clean fixture" {
    const fixture =
        \\const std = @import("std");
        \\const oriel = @import("oriel");
        \\
        \\pub fn build(b: *std.Build) void {
        \\    const dep = b.dependency("oriel", .{
        \\        .target = target,
        \\        .optimize = optimize,
        \\    });
        \\    _ = oriel.addApp(b, dep, .{
        \\        .name = "my-app",
        \\        .root_source_file = b.path("src/main.zig"),
        \\        .frontend = .{ .dir = "frontend" },
        \\    });
        \\}
    ;

    const res = try editBuildZig(std.testing.allocator, fixture, "myapp");
    defer std.testing.allocator.free(res);

    try std.testing.expect(std.mem.indexOf(u8, res, ".deep_link = true") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, ".url_schemes = &.{\"myapp\"}") != null);

    // Idempotent: running again produces identical output
    const res2 = try editBuildZig(std.testing.allocator, res, "myapp");
    defer std.testing.allocator.free(res2);
    try std.testing.expectEqualStrings(res, res2);
}

test "editBuildZig modifies existing package and flips false deep_link" {
    const fixture =
        \\const std = @import("std");
        \\const oriel = @import("oriel");
        \\
        \\pub fn build(b: *std.Build) void {
        \\    const dep = b.dependency("oriel", .{
        \\        .target = target,
        \\        .optimize = optimize,
        \\        .deep_link = false,
        \\    });
        \\    _ = oriel.addApp(b, dep, .{
        \\        .name = "notes",
        \\        .root_source_file = b.path("src/main.zig"),
        \\        .package = .{
        \\            .id = "dev.oriel.Notes",
        \\            .url_schemes = &.{"existing"},
        \\        },
        \\    });
        \\}
    ;

    const res = try editBuildZig(std.testing.allocator, fixture, "new-scheme");
    defer std.testing.allocator.free(res);

    try std.testing.expect(std.mem.indexOf(u8, res, ".deep_link = true") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, ".deep_link = false") == null);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"existing\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"new-scheme\"") != null);

    // Idempotent
    const res2 = try editBuildZig(std.testing.allocator, res, "new-scheme");
    defer std.testing.allocator.free(res2);
    try std.testing.expectEqualStrings(res, res2);
}

test "editBuildZig error when anchors missing" {
    const bad_fixture1 = "pub fn build(b: *std.Build) void {}";
    try std.testing.expectError(error.MissingOrielDependency, editBuildZig(std.testing.allocator, bad_fixture1, "test"));

    const bad_fixture2 = "pub fn build(b: *std.Build) void { const dep = b.dependency(\"oriel\", .{}); }";
    try std.testing.expectError(error.MissingAddApp, editBuildZig(std.testing.allocator, bad_fixture2, "test"));

    // Invalid scheme
    const fixture_ok = "pub fn build(b: *std.Build) void { const dep = b.dependency(\"oriel\", .{}); _ = oriel.addApp(b, dep, .{}); }";
    try std.testing.expectError(error.InvalidScheme, editBuildZig(std.testing.allocator, fixture_ok, "123invalid"));
}

/// The built executable to register: the dev build (`<name>-dev`, from
/// `oriel dev` / `zig build build-dev`) when it exists, else the production
/// one. Returns null when neither has been built yet.
fn builtExe(ctx: Context, root: []const u8, exe_name: []const u8) !?[]u8 {
    const ext = if (builtin.os.tag == .windows) ".exe" else "";
    for ([_][]const u8{ "-dev", "" }) |suffix| {
        const file = try std.fmt.allocPrint(ctx.gpa, "{s}{s}{s}", .{ exe_name, suffix, ext });
        defer ctx.gpa.free(file);
        const path = try std.fs.path.join(ctx.gpa, &.{ root, "zig-out", "bin", file });
        if (std.Io.Dir.cwd().access(ctx.io, path, .{})) |_| return path else |_| ctx.gpa.free(path);
    }
    return null;
}
