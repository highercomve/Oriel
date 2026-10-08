//! `oriel wrap`: package a web page or web application into a desktop
//! application with tray support and AppImage packaging (similar to Pake).

const std = @import("std");
const build_options = @import("build_options");
const Context = @import("Context.zig");
const init_cmd = @import("init.zig");
const template = @import("template.zig");
const zig_manager = @import("zig_manager.zig");

pub const Command = struct {
    pub const summary = "Wrap a web page or web app into a desktop application";
    pub const positionals = .{"url"};
    pub const help = .{
        .url = "Target web URL (e.g. https://web.whatsapp.com)",
        .name = "App name: letters, digits, '-' and '_' (also directory and executable name)",
        .title = "Window title and package display name",
        .id = "Application id in reverse-DNS form (default: com.<domain>.<name>)",
        .icon = "Path to PNG icon file",
        .tray = "Enable system tray icon and minimize-to-tray",
        .no_tray = "Disable system tray icon",
        .user_agent = "Custom User-Agent: 'chrome', 'safari', 'firefox', or a custom string",
        .devtools = "Enable web developer tools and forward console messages to stdout",
        .package = "Build distribution packages (AppImage on Linux) immediately",
        .run = "Run the wrapped application immediately",
        .oriel_ref = "Oriel git tag or commit to depend on (default: " ++ build_options.oriel_ref ++ ")",
        .oriel_path = "Depend on a local Oriel checkout instead (.path dependency)",
    };
    pub const values = .{
        .name = "name",
        .title = "title",
        .id = "app-id",
        .icon = "icon.png",
        .user_agent = "ua",
        .oriel_ref = "ref",
        .oriel_path = "dir",
    };

    url: []const u8,
    name: ?[]const u8 = null,
    title: ?[]const u8 = null,
    id: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    tray: bool = false,
    no_tray: bool = false,
    user_agent: ?[]const u8 = null,
    devtools: bool = false,
    package: bool = false,
    run: bool = false,
    oriel_ref: ?[]const u8 = null,
    oriel_path: ?[]const u8 = null,
};

const chrome_ua = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36";
const firefox_ua = "Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0";
const safari_ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15";

pub fn run(ctx: Context, cmd: Command) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = ctx.io;
    const err = ctx.err;
    const cwd = std.Io.Dir.cwd();

    const full_url = if (std.mem.startsWith(u8, cmd.url, "http://") or std.mem.startsWith(u8, cmd.url, "https://"))
        cmd.url
    else
        try std.fmt.allocPrint(arena, "https://{s}", .{cmd.url});

    const app_name = if (cmd.name) |n| blk: {
        try init_cmd.validateName(n);
        break :blk n;
    } else try deriveNameFromUrl(arena, full_url);

    try init_cmd.validateName(app_name);

    var pkg_name_buf: [init_cmd.max_name_len]u8 = undefined;
    const pkg_name = init_cmd.packageName(&pkg_name_buf, app_name);

    const app_title = if (cmd.title) |t| t else try init_cmd.titleFromName(arena, app_name);
    const app_id = if (cmd.id) |id| id else try deriveAppId(arena, full_url, app_name);
    if (!init_cmd.validAppId(app_id)) {
        try err.print("error: invalid app id '{s}': use reverse-DNS form (e.g. com.example.App)\n", .{app_id});
        return 2;
    }

    const use_tray = !cmd.no_tray;

    var resolved_ua: ?[]const u8 = null;
    if (cmd.user_agent) |ua| {
        if (std.ascii.eqlIgnoreCase(ua, "chrome")) {
            resolved_ua = chrome_ua;
        } else if (std.ascii.eqlIgnoreCase(ua, "firefox")) {
            resolved_ua = firefox_ua;
        } else if (std.ascii.eqlIgnoreCase(ua, "safari")) {
            resolved_ua = safari_ua;
        } else {
            resolved_ua = ua;
        }
    } else if (std.mem.indexOf(u8, full_url, "whatsapp") != null) {
        resolved_ua = chrome_ua;
    }

    // Resolve local checkout if specified or if running inside Oriel
    const oriel_abs: ?[]const u8 = if (cmd.oriel_path) |path| blk: {
        const abs = cwd.realPathFileAlloc(io, path, arena) catch |e| {
            try err.print("error: --oriel-path {s}: {s}\n", .{ path, @errorName(e) });
            return 1;
        };
        if (!try init_cmd.isOrielCheckout(arena, io, abs)) {
            try err.print("error: --oriel-path {s} is not an Oriel checkout\n", .{path});
            return 1;
        }
        break :blk abs;
    } else blk: {
        if (init_cmd.isOrielCheckout(arena, io, ".") catch false) {
            break :blk cwd.realPathFileAlloc(io, ".", arena) catch null;
        }
        if (build_options.checkout_path) |cp| {
            if (init_cmd.isOrielCheckout(arena, io, cp) catch false) {
                break :blk cwd.realPathFileAlloc(io, cp, arena) catch null;
            }
        }
        break :blk null;
    };

    // Target directory
    _ = createProjectDir(io, cwd, app_name) catch |e| {
        switch (e) {
            error.NotEmpty => try err.print("error: directory '{s}' already exists and is not empty\n", .{app_name}),
            error.NotDir => try err.print("error: '{s}' exists and is not a directory\n", .{app_name}),
            else => try err.print("error: creating directory '{s}': {s}\n", .{ app_name, @errorName(e) }),
        }
        return 1;
    };

    const project_abs = try cwd.realPathFileAlloc(io, app_name, arena);
    var target_dir = try cwd.openDir(io, app_name, .{});
    defer target_dir.close(io);

    var random_bytes: [4]u8 = undefined;
    io.random(&random_bytes);
    const fp_id = std.mem.readInt(u32, &random_bytes, .little);
    const fp = init_cmd.fingerprint(pkg_name, fp_id);

    // Compute relative oriel dependency path if using local checkout
    const oriel_rel = if (oriel_abs) |abs|
        try std.fs.path.relative(arena, project_abs, null, project_abs, abs)
    else
        null;

    const dep_line = if (oriel_rel) |rel|
        try std.fmt.allocPrint(arena, "        .oriel = .{{ .path = \"{f}\" }},\n", .{std.zig.fmtString(rel)})
    else
        "";

    // Write build.zig.zon
    const zon_content = try std.fmt.allocPrint(arena,
        \\.{{
        \\    .name = .{s},
        \\    .fingerprint = 0x{x},
        \\    .version = "0.1.0",
        \\    .dependencies = .{{
        \\{s}    }},
        \\    .paths = .{{
        \\        "build.zig",
        \\        "build.zig.zon",
        \\        "src",
        \\        "assets",
        \\        "frontend",
        \\    }},
        \\}}
        \\
    , .{ pkg_name, fp, dep_line });
    try target_dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = zon_content });

    // Write build.zig
    const build_zig_content = try std.fmt.allocPrint(arena,
        \\const std = @import("std");
        \\const oriel = @import("oriel");
        \\
        \\pub fn build(b: *std.Build) void {{
        \\    const target = b.standardTargetOptions(.{{}});
        \\    const optimize = b.standardOptimizeOption(.{{}});
        \\
        \\    const dep = b.dependency("oriel", .{{
        \\        .target = target,
        \\        .optimize = optimize,
        \\        .tray = {s},
        \\        .notification = true,
        \\    }});
        \\
        \\    _ = oriel.addApp(b, dep, .{{
        \\        .name = "{s}",
        \\        .root_source_file = b.path("src/main.zig"),
        \\        .icon = b.path("assets/icon.png"),
        \\        .permissions = .{{
        \\            .notifications = "Incoming message notifications",
        \\            .microphone = "Voice notes and microphone access",
        \\        }},
        \\        .frontend = .{{
        \\            .dir = "frontend",
        \\            .dist = ".",
        \\            .build_command = null,
        \\            .install_command = null,
        \\            .dev = null,
        \\            .types_path = null,
        \\        }},
        \\        .package = .{{
        \\            .id = "{s}",
        \\            .name = "{s}",
        \\            .summary = "{s} Desktop Client",
        \\            .publisher = "{s}",
        \\            .categories = "Network;InstantMessaging;",
        \\            .version = "0.1.0",
        \\            .formats = &.{{ .appimage }},
        \\        }},
        \\    }});
        \\}}
        \\
    , .{
        if (use_tray) "true" else "false",
        app_name,
        app_id,
        app_title,
        app_title,
        app_title,
    });
    try target_dir.writeFile(io, .{ .sub_path = "build.zig", .data = build_zig_content });

    // Create frontend/index.html
    try target_dir.createDirPath(io, "frontend");
    const html_content = try std.fmt.allocPrint(arena,
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\  <meta charset="utf-8">
        \\  <title>{s}</title>
        \\  <style>
        \\    html, body {{
        \\      margin: 0; padding: 0; width: 100%; height: 100%;
        \\      background: #111b21; display: flex; align-items: center; justify-content: center;
        \\      color: #8696a0; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
        \\    }}
        \\  </style>
        \\</head>
        \\<body>
        \\  <p>Loading {s}...</p>
        \\</body>
        \\</html>
        \\
    , .{ app_title, app_title });
    try target_dir.writeFile(io, .{ .sub_path = "frontend/index.html", .data = html_content });

    // Derive allowed origins and capabilities for remote web app
    const origins = try deriveAllowedOrigins(arena, full_url);
    var origins_buf: std.ArrayList(u8) = .empty;
    defer origins_buf.deinit(arena);
    var cap_buf: std.ArrayList(u8) = .empty;
    defer cap_buf.deinit(arena);
    for (origins) |o| {
        try origins_buf.appendSlice(arena, "                \"");
        try origins_buf.appendSlice(arena, o);
        try origins_buf.appendSlice(arena, "\",\n");

        try cap_buf.appendSlice(arena, "                .{ .origin = \"");
        try cap_buf.appendSlice(arena, o);
        try cap_buf.appendSlice(arena, "\" },\n");
    }

    // Build src/main.zig
    const tray_globals = if (use_tray) "var tray: ?*oriel.tray.Tray = null;\n" else "";
    const tray_funcs = if (use_tray) try std.fmt.allocPrint(arena,
        \\fn onMenu(id: []const u8, _: ?bool) void {{
        \\    if (std.mem.eql(u8, id, "toggle")) return oriel.App.toggleWindow();
        \\    if (std.mem.eql(u8, id, "quit")) return oriel.App.quit(0);
        \\}}
        \\
        \\fn setup() !void {{
        \\    const gpa = std.heap.smp_allocator;
        \\    tray = try oriel.tray.Tray.create(gpa, .{{
        \\        .id = "{s}",
        \\        .title = "{s}",
        \\        .tooltip = "{s}",
        \\        .icon = .{{ .png = app.icon_bytes }},
        \\        .menu = &.{{
        \\            .{{ .item = .{{ .id = "toggle", .label = "Show / Hide" }} }},
        \\            .separator,
        \\            .{{ .item = .{{ .id = "quit", .label = "Quit" }} }},
        \\        }},
        \\        .on_menu = onMenu,
        \\    }});
        \\}}
        \\
    , .{ app_id, app_title, app_title }) else "";

    const user_agent_line = if (resolved_ua) |ua|
        try std.fmt.allocPrint(arena, "        .user_agent = \"{s}\",\n", .{ua})
    else
        "";

    const on_close_line = if (use_tray) "        .on_close = .hide,\n" else "";
    const setup_line = if (use_tray) "        .setup = setup,\n" else "";

    const main_zig_content = try std.fmt.allocPrint(arena,
        \\const std = @import("std");
        \\const oriel = @import("oriel");
        \\const app = @import("oriel_app");
        \\
        \\{s}
        \\{s}
        \\pub fn main(init: std.process.Init) !u8 {{
        \\    return oriel.main(init, .{{ .commands = struct {{}} }}, .{{
        \\        .id = "{s}",
        \\        .title = "{s}",
        \\        .width = 1100,
        \\        .height = 750,
        \\        .icon = app.icon_bytes,
        \\        .permissions = app.permissions,
        \\        .assets = app.assets,
        \\        .url = "{s}",
        \\        .devtools = {s},
        \\{s}{s}{s}        .security = .{{
        \\            .csp = null,
        \\            .allowed_origins = &.{{
        \\{s}            }},
        \\            .capabilities = &.{{
        \\{s}            }},
        \\            .external_links = .open_in_browser,
        \\        }},
        \\    }});
        \\}}
        \\
    , .{
        tray_globals,
        tray_funcs,
        app_id,
        app_title,
        full_url,
        if (cmd.devtools) "true" else "false",
        user_agent_line,
        on_close_line,
        setup_line,
        origins_buf.items,
        cap_buf.items,
    });

    try target_dir.createDirPath(io, "src");
    try target_dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = main_zig_content });

    // Handle icon:
    // 1. If --icon <path> was provided and exists on disk, use it.
    // 2. Otherwise, fetch the application's favicon from the web.
    //    If --icon <path> was provided (e.g. ./whatsapp.png) but didn't exist,
    //    also write the fetched favicon to <path> so the requested file is created.
    // 3. Fall back to default Oriel icon only if fetching fails.
    try target_dir.createDirPath(io, "assets");
    var icon_bytes_to_write: ?[]const u8 = null;

    if (cmd.icon) |icon_path| {
        if (cwd.readFileAlloc(io, icon_path, arena, .limited(10 * 1024 * 1024))) |bytes| {
            icon_bytes_to_write = bytes;
        } else |_| {
            try ctx.out.print("Icon '{s}' not found on disk; fetching favicon for {s}...\n", .{ icon_path, full_url });
            if (fetchFavicon(ctx, arena, full_url)) |fav| {
                icon_bytes_to_write = fav;
                cwd.writeFile(io, .{ .sub_path = icon_path, .data = fav }) catch {};
                try ctx.out.print("Saved favicon to '{s}'\n", .{icon_path});
            }
        }
    } else {
        try ctx.out.print("Fetching application favicon for {s}...\n", .{full_url});
        if (fetchFavicon(ctx, arena, full_url)) |fav| {
            icon_bytes_to_write = fav;
        }
    }

    if (icon_bytes_to_write) |bytes| {
        try target_dir.writeFile(io, .{ .sub_path = "assets/icon.png", .data = bytes });
    } else {
        try ctx.out.print("Using default Oriel application icon\n", .{});
        try target_dir.writeFile(io, .{ .sub_path = "assets/icon.png", .data = template.default_icon_bytes });
    }

    // Write .gitignore
    try target_dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "zig-cache/\n.zig-cache/\nzig-out/\n" });

    try ctx.out.print("Created {s}/ (wrapped {s}, app id {s})\n", .{ app_name, full_url, app_id });

    // Resolve Zig compiler
    const want = try zig_manager.requiredForRoot(ctx, project_abs);
    defer ctx.gpa.free(want);
    const resolved = zig_manager.resolve(ctx, want) catch {
        try err.print("Then run: cd {s} && oriel zig install && zig build --fetch\n", .{app_name});
        return 1;
    };
    defer resolved.deinit(ctx.gpa);
    const zig = resolved.path;

    // Fetch oriel dependency if not using local path
    if (cmd.oriel_path == null and oriel_abs == null) {
        const ref = cmd.oriel_ref orelse build_options.oriel_ref;
        const repo_url = try std.fmt.allocPrint(arena, "{s}#{s}", .{ init_cmd.repo_url, ref });
        try ctx.out.print("Adding Oriel ({s})...\n", .{repo_url});
        if (!step(ctx, &.{ zig, "fetch", "--save=oriel", repo_url }, project_abs)) {
            try err.print("Retry with: cd {s} && zig fetch --save=oriel {s}\n", .{ app_name, repo_url });
            return 1;
        }
    }

    try ctx.out.writeAll("Fetching Zig dependencies (zig build --fetch)...\n");
    if (!step(ctx, &.{ zig, "build", "--fetch" }, project_abs)) {
        try err.print("Retry with: cd {s} && zig build --fetch\n", .{app_name});
        return 1;
    }

    // Immediate package build
    if (cmd.package) {
        try ctx.out.print("Packaging {s} into AppImage...\n", .{app_name});
        if (!step(ctx, &.{ zig, "build", "package-appimage", "-Doptimize=ReleaseSafe" }, project_abs)) {
            try err.writeAll("Packaging failed; try running 'oriel package' inside the project directory.\n");
            return 1;
        }
        try ctx.out.print("\nPackage created successfully in {s}/zig-out/package/\n", .{app_name});
    }

    // Immediate run
    if (cmd.run) {
        try ctx.out.print("Running {s}...\n", .{app_name});
        _ = ctx.run(&.{ zig, "build", "run" }, project_abs);
        return 0;
    }

    try ctx.out.print(
        \\
        \\Done. Next:
        \\  cd {s}
        \\  {s}
        \\
    , .{
        app_name,
        if (cmd.package)
            "oriel run     # or test your AppImage in zig-out/package/"
        else
            "oriel run     # or: oriel package (to build AppImage)",
    });

    return 0;
}

fn deriveNameFromUrl(arena: std.mem.Allocator, raw_url: []const u8) ![]const u8 {
    const uri = std.Uri.parse(raw_url) catch return "web-app";
    const host_comp = uri.host orelse return "web-app";
    var host_buf: [256]u8 = undefined;
    const host = host_comp.toRaw(&host_buf) catch return "web-app";

    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(arena);
    var it = std.mem.splitScalar(u8, host, '.');
    while (it.next()) |p| {
        if (p.len > 0) try parts.append(arena, p);
    }
    if (parts.items.len == 0) return "web-app";

    var candidate: []const u8 = parts.items[0];
    for (parts.items) |p| {
        if (!std.ascii.eqlIgnoreCase(p, "www") and
            !std.ascii.eqlIgnoreCase(p, "web") and
            !std.ascii.eqlIgnoreCase(p, "app") and
            !std.ascii.eqlIgnoreCase(p, "com") and
            !std.ascii.eqlIgnoreCase(p, "net") and
            !std.ascii.eqlIgnoreCase(p, "org") and
            !std.ascii.eqlIgnoreCase(p, "io") and
            !std.ascii.eqlIgnoreCase(p, "ai"))
        {
            candidate = p;
            break;
        }
    }

    var clean: std.ArrayList(u8) = .empty;
    defer clean.deinit(arena);
    for (candidate) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') {
            try clean.append(arena, std.ascii.toLower(c));
        }
    }
    if (clean.items.len == 0 or !std.ascii.isAlphabetic(clean.items[0])) {
        return "web-app";
    }
    if (clean.items.len > init_cmd.max_name_len) {
        return clean.items[0..init_cmd.max_name_len];
    }
    return try arena.dupe(u8, clean.items);
}

fn deriveAppId(arena: std.mem.Allocator, raw_url: []const u8, app_name: []const u8) ![]const u8 {
    const uri = std.Uri.parse(raw_url) catch return try init_cmd.defaultAppId(arena, app_name);
    const host_comp = uri.host orelse return try init_cmd.defaultAppId(arena, app_name);
    var host_buf: [256]u8 = undefined;
    const host = host_comp.toRaw(&host_buf) catch return try init_cmd.defaultAppId(arena, app_name);

    if (std.mem.indexOf(u8, host, "whatsapp") != null) {
        return "com.whatsapp.desktop";
    }
    return try init_cmd.defaultAppId(arena, app_name);
}

fn deriveAllowedOrigins(arena: std.mem.Allocator, raw_url: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(arena);

    const uri = std.Uri.parse(raw_url) catch {
        try list.append(arena, raw_url);
        return list.toOwnedSlice(arena);
    };
    const host_comp = uri.host orelse {
        try list.append(arena, raw_url);
        return list.toOwnedSlice(arena);
    };
    var host_buf: [256]u8 = undefined;
    const host = host_comp.toRaw(&host_buf) catch raw_url;

    const origin = try std.fmt.allocPrint(arena, "https://{s}", .{host});
    try list.append(arena, origin);

    if (std.mem.indexOf(u8, host, "whatsapp") != null) {
        try list.append(arena, "https://*.whatsapp.net");
        try list.append(arena, "https://*.whatsapp.com");
    } else {
        var it = std.mem.splitBackwardsScalar(u8, host, '.');
        const tld = it.next();
        const sld = it.next();
        if (tld != null and sld != null) {
            const wildcard = try std.fmt.allocPrint(arena, "https://*.{s}.{s}", .{ sld.?, tld.? });
            try list.append(arena, wildcard);
        }
    }
    return list.toOwnedSlice(arena);
}

fn step(ctx: Context, argv: []const []const u8, dir: []const u8) bool {
    const code = ctx.run(argv, dir) orelse return false;
    if (code != 0) {
        ctx.err.print("error: '{s} {s}' failed (exit code {d})\n", .{ argv[0], argv[1], code }) catch {};
        return false;
    }
    return true;
}

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

fn isPng(data: []const u8) bool {
    const png_magic = "\x89PNG\r\n\x1a\n";
    return data.len >= png_magic.len and std.mem.startsWith(u8, data, png_magic);
}

fn fetchFavicon(ctx: Context, arena: std.mem.Allocator, target_url: []const u8) ?[]const u8 {
    const google_url = std.fmt.allocPrint(arena, "https://t3.gstatic.com/faviconV2?client=SOCIAL&type=FAVICON&fallback_opts=TYPE,SIZE,URL&url={s}&size=256", .{target_url}) catch return null;

    // 1. Try Google Favicon service via curl (returns up to 256px RGBA PNG)
    if (ctx.capture(&.{ "curl", "-sL", "--max-time", "8", google_url }, 10_000)) |cap| {
        defer cap.deinit(ctx.gpa);
        if (cap.code == 0 and isPng(cap.stdout)) {
            return arena.dupe(u8, cap.stdout) catch null;
        }
    }

    // 2. Try Google Favicon service via wget
    if (ctx.capture(&.{ "wget", "-q", "-O", "-", "--timeout=8", google_url }, 10_000)) |cap| {
        defer cap.deinit(ctx.gpa);
        if (cap.code == 0 and isPng(cap.stdout)) {
            return arena.dupe(u8, cap.stdout) catch null;
        }
    }

    // 3. Fallback: DuckDuckGo favicon service
    const uri = std.Uri.parse(target_url) catch return null;
    const host_comp = uri.host orelse return null;
    var host_buf: [256]u8 = undefined;
    const host = host_comp.toRaw(&host_buf) catch return null;
    const ddg_url = std.fmt.allocPrint(arena, "https://icons.duckduckgo.com/ip3/{s}.ico", .{host}) catch return null;

    if (ctx.capture(&.{ "curl", "-sL", "--max-time", "8", ddg_url }, 10_000)) |cap| {
        defer cap.deinit(ctx.gpa);
        if (cap.code == 0 and isPng(cap.stdout)) {
            return arena.dupe(u8, cap.stdout) catch null;
        }
    }

    return null;
}
