//! `oriel init`: scaffold a new app from an embedded template, add Oriel as a
//! dependency and download everything the first build needs.

const std = @import("std");
const build_options = @import("build_options");
const Context = @import("Context.zig");
const template = @import("template.zig");
const Template = template.Template;

/// Where `oriel init` fetches Oriel from (plus `#<ref>`).
pub const repo_url = "git+https://github.com/highercomve/Oriel";

pub const Command = struct {
    pub const summary = "Create a new Oriel app in ./<name>";
    pub const positionals = .{"name"};
    pub const help = .{
        .name = "App name: letters, digits, '-' and '_' (also the directory and executable name)",
        .template = "Frontend template",
        .id = "Application id in reverse-DNS form (default: com.example.<Name>)",
        .oriel_ref = "Oriel git tag or commit to depend on (default: " ++ build_options.oriel_ref ++ ")",
        .oriel_path = "Depend on a local Oriel checkout instead (.path dependency)",
        .no_install = "Only record the dependency: skip `zig build --fetch` and `npm install`",
    };
    pub const values = .{ .id = "app-id", .oriel_ref = "ref", .oriel_path = "dir" };
    pub const details =
        \\Templates: react, vue and svelte use Vite (Node.js + npm); vanilla is a
        \\static page with no build step. The target directory must not exist or
        \\be empty. Set ORIEL_ZIG to choose the zig binary (default: zig on PATH).
    ;

    name: []const u8,
    template: Template = .react,
    id: ?[]const u8 = null,
    oriel_ref: ?[]const u8 = null,
    oriel_path: ?[]const u8 = null,
    no_install: bool = false,
};

// ---------------------------------------------------------------------------
// Validation and derived names
// ---------------------------------------------------------------------------

/// Zig limits package names to 32 bytes.
pub const max_name_len = 32;

pub const NameError = error{ InvalidName, ReservedName };

/// An app name is used as the directory, the executable and (with `-`
/// turned into `_`) the Zig package name, so it must be a plain identifier.
pub fn validateName(name: []const u8) NameError!void {
    if (name.len == 0 or name.len > max_name_len) return error.InvalidName;
    if (!std.ascii.isAlphabetic(name[0])) return error.InvalidName;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return error.InvalidName;
    }
    var buf: [max_name_len]u8 = undefined;
    const pkg = packageName(&buf, name);
    if (std.zig.Token.getKeyword(pkg) != null or std.zig.primitives.isPrimitive(pkg)) return error.ReservedName;
}

/// `my-app` → `my_app` (the `.name` in build.zig.zon). `buf` must hold `name`.
pub fn packageName(buf: []u8, name: []const u8) []const u8 {
    const out = buf[0..name.len];
    @memcpy(out, name);
    std.mem.replaceScalar(u8, out, '-', '_');
    return out;
}

/// Same rules as `g_application_id_is_valid`: at least two dot-separated
/// elements of `[A-Za-z0-9_-]`, none empty or starting with a digit.
pub fn validAppId(id: []const u8) bool {
    if (id.len == 0 or id.len > 255) return false;
    var elements: usize = 0;
    var it = std.mem.splitScalar(u8, id, '.');
    while (it.next()) |element| {
        if (element.len == 0 or std.ascii.isDigit(element[0])) return false;
        for (element) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
        }
        elements += 1;
    }
    return elements >= 2;
}

/// `my-app` → `My App` (window title, package display name). Caller owns it.
pub fn titleFromName(gpa: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error![]u8 {
    const out = try gpa.dupe(u8, name);
    var start_of_word = true;
    for (out) |*c| {
        if (c.* == '-' or c.* == '_') {
            c.* = ' ';
            start_of_word = true;
        } else {
            if (start_of_word) c.* = std.ascii.toUpper(c.*);
            start_of_word = false;
        }
    }
    return out;
}

/// `my-app` → `com.example.MyApp`. Caller owns it.
pub fn defaultAppId(gpa: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "com.example.");
    var start_of_word = true;
    for (name) |c| {
        if (c == '-' or c == '_') {
            start_of_word = true;
            continue;
        }
        try out.append(gpa, if (start_of_word) std.ascii.toUpper(c) else c);
        start_of_word = false;
    }
    return out.toOwnedSlice(gpa);
}

/// A build.zig.zon `.fingerprint`, computed the way Zig does: the low 32
/// bits are a random id (never 0 or 0xffffffff), the high 32 bits the CRC32
/// of the package name. Zig rejects a manifest whose checksum doesn't match.
pub fn fingerprint(pkg_name: []const u8, random_id: u32) u64 {
    const id: u32 = switch (random_id) {
        0, 0xffffffff => 1,
        else => random_id,
    };
    return (@as(u64, std.hash.Crc32.hash(pkg_name)) << 32) | id;
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

pub const Project = struct {
    /// Validated by `validateName`.
    name: []const u8,
    /// Validated by `validAppId`.
    app_id: []const u8,
    template: Template,
    fingerprint_id: u32,
    /// Path from the project to a local Oriel checkout (`.path` dependency),
    /// or null when Oriel is added with `zig fetch --save`.
    oriel_path: ?[]const u8,
};

/// The placeholder values for `project`, allocated in `arena`. The name and
/// id are validated, so they need no escaping in Zig, JSON or HTML.
pub fn vars(arena: std.mem.Allocator, p: Project) ![]const template.Var {
    const buf = try arena.alloc(u8, p.name.len);
    const pkg_name = packageName(buf, p.name);
    const vite = p.template.usesVite();
    const title = try titleFromName(arena, p.name);

    const dependencies = if (p.oriel_path) |path|
        try std.fmt.allocPrint(arena, "        .oriel = .{{ .path = \"{f}\" }},\n", .{std.zig.fmtString(path)})
    else
        "";

    const frontend_desc = switch (p.template) {
        .react => "React + Vite",
        .vue => "Vue + Vite",
        .svelte => "Svelte + Vite",
        .vanilla => "plain HTML + JavaScript (no build step)",
    };

    const commands = if (vite) try std.fmt.allocPrint(arena,
        \\oriel dev        # Vite dev server with hot reload; Zig changes restart the app
        \\oriel build      # production build: zig-out/bin/{s} (frontend embedded)
        \\oriel run        # build and run it
        \\oriel types      # regenerate frontend/src/oriel.ts from the Zig structs
        \\oriel check      # type-check the Zig code (fast)
        \\oriel package    # deb, rpm and AppImage in zig-out/package/
    , .{p.name}) else try std.fmt.allocPrint(arena,
        \\oriel build      # build zig-out/bin/{s} with frontend/ embedded
        \\oriel run        # build and run it (rerun after editing frontend/)
        \\oriel check      # type-check the Zig code (fast)
        \\oriel package    # deb, rpm and AppImage in zig-out/package/
    , .{p.name});

    const calling = if (vite)
        \\```ts
        \\// frontend/src/oriel.ts is generated from the Zig structs, so both are typed.
        \\import { invoke, listen } from "./oriel";
        \\const text = await invoke("greet", { name: "Ada" }); // string
        \\const off = listen("greeted", (e) => console.log(e.count)); // e: { count: number }
        \\```
    else
        \\```js
        \\// window.oriel is injected into the page by Oriel.
        \\const text = await window.oriel.invoke("greet", { name: "Ada" });
        \\const off = window.oriel.listen("greeted", (e) => console.log(e.count));
        \\```
    ;

    const frontend = if (vite)
        \\.{ .dir = "frontend" }
    else
        \\.{
        \\            // A static page: embedded as-is, no npm and no dev server.
        \\            .dir = "frontend",
        \\            .dist = ".",
        \\            .build_command = null,
        \\            .install_command = null,
        \\            .dev = null,
        \\            .types_path = null,
        \\        }
    ;

    const result = [_]template.Var{
        .{ .key = "name", .value = p.name },
        .{ .key = "pkg_name", .value = pkg_name },
        .{ .key = "npm_name", .value = try std.ascii.allocLowerString(arena, p.name) },
        .{ .key = "title", .value = title },
        .{ .key = "app_id", .value = p.app_id },
        .{ .key = "fingerprint", .value = try std.fmt.allocPrint(arena, "0x{x}", .{fingerprint(pkg_name, p.fingerprint_id)}) },
        .{ .key = "dependencies", .value = dependencies },
        .{ .key = "frontend", .value = frontend },
        .{ .key = "frontend_desc", .value = frontend_desc },
        .{ .key = "build_summary", .value = if (vite) "npm install if needed, vite build, embed" else "embeds frontend/ as-is" },
        .{ .key = "dev_steps", .value = if (vite)
            \\    // zig build dev      Vite dev server + hot reload
            \\    // zig build types    regenerate frontend/src/oriel.ts
            \\
        else
            "" },
        .{ .key = "commands", .value = commands },
        .{ .key = "calling", .value = calling },
    };
    return arena.dupe(template.Var, &result);
}

/// Render every template file into `dir` (which should be empty). Existing
/// files are never overwritten.
pub fn writeFiles(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, p: Project) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const values = try vars(arena_state.allocator(), p);
    for (template.files(p.template)) |f| {
        const text = try template.render(gpa, f.text, values);
        defer gpa.free(text);
        if (std.fs.path.dirname(f.path)) |parent| try dir.createDirPath(io, parent);
        try dir.writeFile(io, .{ .sub_path = f.path, .data = text, .flags = .{ .exclusive = true } });
    }
}

// ---------------------------------------------------------------------------
// The command
// ---------------------------------------------------------------------------

pub fn run(ctx: Context, cmd: Command) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = ctx.io;
    const err = ctx.err;
    const cwd = std.Io.Dir.cwd();

    validateName(cmd.name) catch |e| {
        switch (e) {
            error.InvalidName => try err.print("error: invalid app name '{s}': use letters, digits, '-' and '_', " ++
                "starting with a letter, at most {d} characters\n", .{ cmd.name, max_name_len }),
            error.ReservedName => try err.print("error: '{s}' is reserved in Zig (keyword or primitive type); pick another name\n", .{cmd.name}),
        }
        return 2;
    };
    const app_id = cmd.id orelse try defaultAppId(arena, cmd.name);
    if (!validAppId(app_id)) {
        try err.print("error: invalid app id '{s}': use reverse-DNS form such as com.example.App " ++
            "(letters, digits, '_' and '-'; at least two parts, none starting with a digit)\n", .{app_id});
        return 2;
    }
    if (cmd.oriel_path != null and cmd.oriel_ref != null) {
        try err.writeAll("error: --oriel-ref and --oriel-path are mutually exclusive\n");
        return 2;
    }

    // Resolve the local checkout before creating anything.
    const oriel_abs: ?[]const u8 = if (cmd.oriel_path) |path| blk: {
        const abs = cwd.realPathFileAlloc(io, path, arena) catch |e| {
            try err.print("error: --oriel-path {s}: {s}\n", .{ path, @errorName(e) });
            return 1;
        };
        if (!try isOrielCheckout(arena, io, abs)) {
            try err.print("error: --oriel-path {s} is not an Oriel checkout (no build.zig.zon with .name = .oriel)\n", .{path});
            return 1;
        }
        break :blk abs;
    } else null;

    // The target directory: new, or existing and empty.
    const created = createProjectDir(io, cwd, cmd.name) catch |e| {
        switch (e) {
            error.NotEmpty => try err.print("error: '{s}' already exists and is not empty; refusing to overwrite it\n", .{cmd.name}),
            error.NotDir => try err.print("error: '{s}' exists and is not a directory\n", .{cmd.name}),
            else => try err.print("error: creating '{s}': {s}\n", .{ cmd.name, @errorName(e) }),
        }
        return 1;
    };
    const project_abs = scaffold(ctx, arena, cmd, app_id, oriel_abs) catch |e| {
        // Leave nothing half-written behind in a directory we created.
        if (created) cwd.deleteTree(io, cmd.name) catch {};
        try err.print("error: writing the project files: {s}\n", .{@errorName(e)});
        return 1;
    };
    try ctx.out.print("Created {s}/ ({t} template, app id {s})\n", .{ cmd.name, cmd.template, app_id });

    const zig = ctx.zig();
    if (cmd.oriel_path == null) {
        const ref = cmd.oriel_ref orelse build_options.oriel_ref;
        const url = try std.fmt.allocPrint(arena, "{s}#{s}", .{ repo_url, ref });
        try ctx.out.print("Adding Oriel ({s})...\n", .{url});
        if (!step(ctx, &.{ zig, "fetch", "--save=oriel", url }, project_abs)) {
            try err.print("Add it later with: cd {s} && zig fetch --save=oriel {s}\n", .{ cmd.name, url });
            return 1;
        }
    }
    if (!cmd.no_install) {
        try ctx.out.writeAll("Fetching Zig dependencies (zig build --fetch)...\n");
        if (!step(ctx, &.{ zig, "build", "--fetch" }, project_abs)) {
            try err.print("Retry with: cd {s} && zig build --fetch\n", .{cmd.name});
            return 1;
        }
        if (cmd.template.usesVite()) {
            try ctx.out.writeAll("Installing frontend packages (npm install)...\n");
            const frontend = try std.fs.path.join(arena, &.{ project_abs, "frontend" });
            if (!step(ctx, &.{ "npm", "install", "--no-fund", "--no-audit" }, frontend)) {
                try err.print("Retry with: cd {s}/frontend && npm install (see `oriel doctor`)\n", .{cmd.name});
                return 1;
            }
        }
    }

    try ctx.out.print(
        \\
        \\Done. Next:
        \\  cd {s}
        \\  {s}
        \\
    , .{ cmd.name, if (cmd.template.usesVite()) "oriel dev      # or: oriel build && oriel run" else "oriel run" });
    return 0;
}

/// Write the project into the (empty) directory `cmd.name`; returns its
/// absolute path.
fn scaffold(ctx: Context, arena: std.mem.Allocator, cmd: Command, app_id: []const u8, oriel_abs: ?[]const u8) ![]const u8 {
    const io = ctx.io;
    const cwd = std.Io.Dir.cwd();
    const project_abs = try cwd.realPathFileAlloc(io, cmd.name, arena);
    var random_bytes: [4]u8 = undefined;
    io.random(&random_bytes);
    const project: Project = .{
        .name = cmd.name,
        .app_id = app_id,
        .template = cmd.template,
        .fingerprint_id = std.mem.readInt(u32, &random_bytes, .little),
        // Relative, so the project can move together with the checkout.
        .oriel_path = if (oriel_abs) |abs| try std.fs.path.relative(arena, project_abs, null, project_abs, abs) else null,
    };
    var dir = try cwd.openDir(io, cmd.name, .{});
    defer dir.close(io);
    try writeFiles(ctx.gpa, io, dir, project);
    return project_abs;
}

/// Run one setup step; false (with the reason printed) if it failed.
fn step(ctx: Context, argv: []const []const u8, cwd: []const u8) bool {
    const code = ctx.run(argv, cwd) orelse return false;
    if (code != 0) {
        ctx.err.print("error: '{s} {s}' failed (exit code {d})\n", .{ argv[0], argv[1], code }) catch {};
        return false;
    }
    return true;
}

/// Create `name` in `parent`, or accept it if it is an empty directory.
/// Returns whether it was created.
fn createProjectDir(io: std.Io, parent: std.Io.Dir, name: []const u8) !bool {
    parent.createDir(io, name, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {
            var dir = parent.openDir(io, name, .{ .iterate = true }) catch |oe| switch (oe) {
                error.NotDir => return error.NotDir,
                else => return oe,
            };
            defer dir.close(io);
            var it = dir.iterate();
            if (try it.next(io) != null) return error.NotEmpty;
            return false;
        },
        else => return e,
    };
    return true;
}

fn isOrielCheckout(arena: std.mem.Allocator, io: std.Io, dir: []const u8) !bool {
    const zon_path = try std.fs.path.join(arena, &.{ dir, "build.zig.zon" });
    const zon = std.Io.Dir.cwd().readFileAlloc(io, zon_path, arena, .limited(1 << 20)) catch return false;
    return std.mem.indexOf(u8, zon, ".name = .oriel,") != null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "validateName" {
    for ([_][]const u8{ "demo", "my-app", "my_app", "App2", "a" ** 32 }) |ok| try validateName(ok);
    for ([_][]const u8{ "", "2app", "-app", "_app", "my app", "my.app", "app/x", "../x", "ü", "a" ** 33 }) |bad|
        try testing.expectError(error.InvalidName, validateName(bad));
    for ([_][]const u8{ "fn", "error", "u8", "i32", "void", "type" }) |reserved|
        try testing.expectError(error.ReservedName, validateName(reserved));
    var buf: [max_name_len]u8 = undefined;
    try testing.expectEqualStrings("my_app_x", packageName(&buf, "my-app_x"));
}

test "validAppId" {
    for ([_][]const u8{ "com.example.App", "dev.oriel.ReactNotes", "org.my-org.app_2", "a.b" }) |ok|
        try testing.expect(validAppId(ok));
    for ([_][]const u8{ "", "App", "com..App", ".com.App", "com.App.", "com.2App", "com.ex ample.App", "com.example.Äpp" }) |bad|
        try testing.expect(!validAppId(bad));
    try testing.expect(!validAppId("a." ++ "b" ** 254));
}

test "derived names" {
    const gpa = testing.allocator;
    const title = try titleFromName(gpa, "my-cool_app");
    defer gpa.free(title);
    try testing.expectEqualStrings("My Cool App", title);
    const id = try defaultAppId(gpa, "my-cool_app");
    defer gpa.free(id);
    try testing.expectEqualStrings("com.example.MyCoolApp", id);
    try testing.expect(validAppId(id));
}

test "fingerprint matches Zig's" {
    // Values Zig generated for the example apps in this repository.
    try testing.expectEqual(0x64e01f3edc645c4b, fingerprint("oriel_react_notes", 0xdc645c4b));
    try testing.expectEqual(0x0c769d43aaa61741, fingerprint("oriel_smoke", 0xaaa61741));
    try testing.expectEqual(0x0c769d4300000001, fingerprint("oriel_smoke", 0));
    try testing.expectEqual(0x0c769d4300000001, fingerprint("oriel_smoke", 0xffffffff));
}

fn expectValidZig(gpa: std.mem.Allocator, source: []const u8, mode: std.zig.Ast.Mode) !void {
    const z = try gpa.dupeZ(u8, source);
    defer gpa.free(z);
    var ast = try std.zig.Ast.parse(gpa, z, mode);
    defer ast.deinit(gpa);
    try testing.expectEqual(0, ast.errors.len);
}

test "every template renders to a valid project" {
    const gpa = testing.allocator;
    const io = testing.io;
    for (std.enums.values(Template)) |t| {
        for ([_]?[]const u8{ null, "../../oriel \"dev\"" }) |oriel_path| {
            var tmp = testing.tmpDir(.{});
            defer tmp.cleanup();
            const project: Project = .{
                .name = "my-app",
                .app_id = "com.example.MyApp",
                .template = t,
                .fingerprint_id = 0x12345678,
                .oriel_path = oriel_path,
            };
            try writeFiles(gpa, io, tmp.dir, project);

            for (template.files(t)) |f| {
                const text = try tmp.dir.readFileAlloc(io, f.path, gpa, .limited(1 << 20));
                defer gpa.free(text);
                try testing.expect(std.mem.indexOf(u8, text, "@@") == null);
                if (std.mem.endsWith(u8, f.path, ".zig")) try expectValidZig(gpa, text, .zig);
                if (std.mem.endsWith(u8, f.path, ".json")) {
                    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
                    parsed.deinit();
                }
            }

            const zon = try tmp.dir.readFileAlloc(io, "build.zig.zon", gpa, .limited(1 << 20));
            defer gpa.free(zon);
            try expectValidZig(gpa, zon, .zon);
            try testing.expect(std.mem.indexOf(u8, zon, ".name = .my_app,") != null);
            const expected_fp = try std.fmt.allocPrint(gpa, ".fingerprint = 0x{x},", .{fingerprint("my_app", 0x12345678)});
            defer gpa.free(expected_fp);
            try testing.expect(std.mem.indexOf(u8, zon, expected_fp) != null);
            const has_path = std.mem.indexOf(u8, zon, ".oriel = .{ .path = \"../../oriel \\\"dev\\\"\" },") != null;
            try testing.expectEqual(oriel_path != null, has_path);

            const main_zig = try tmp.dir.readFileAlloc(io, "src/main.zig", gpa, .limited(1 << 20));
            defer gpa.free(main_zig);
            try testing.expect(std.mem.indexOf(u8, main_zig, ".id = \"com.example.MyApp\"") != null);
            try testing.expect(std.mem.indexOf(u8, main_zig, ".title = \"My App\"") != null);

            // Nothing is overwritten.
            try testing.expectError(error.PathAlreadyExists, writeFiles(gpa, io, tmp.dir, project));
        }
    }
}

test "createProjectDir refuses non-empty directories" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expect(try createProjectDir(io, tmp.dir, "new"));
    try testing.expect(!try createProjectDir(io, tmp.dir, "new")); // exists, empty
    try tmp.dir.writeFile(io, .{ .sub_path = "new/file", .data = "x" });
    try testing.expectError(error.NotEmpty, createProjectDir(io, tmp.dir, "new"));
    try testing.expectError(error.NotDir, createProjectDir(io, tmp.dir, "new/file"));
}
