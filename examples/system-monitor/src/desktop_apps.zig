//! Linux desktop names, read once at startup. No commands are executed.
const std = @import("std");
const Entry = struct { key: []const u8, name: []const u8, executable: []const u8, wm_class: []const u8 };
const max_entries = 4096;
pub const Catalog = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Catalog {
        var catalog = Catalog{ .arena = .init(gpa) };
        // User entries override system entries, including Flatpak exports.
        var passwd: [65536]u8 = undefined;
        const bytes = std.Io.Dir.cwd().readFile(io, "/etc/passwd", &passwd) catch "";
        var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            var fields = std.mem.splitScalar(u8, line, ':');
            _ = fields.next();
            _ = fields.next();
            const uid = std.fmt.parseInt(u32, fields.next() orelse continue, 10) catch continue;
            if (uid != std.os.linux.getuid()) continue;
            _ = fields.next();
            _ = fields.next();
            const home = fields.next() orelse break;
            for ([_][]const u8{ "/.local/share/applications", "/.local/share/flatpak/exports/share/applications" }) |suffix| {
                var path: [4096]u8 = undefined;
                catalog.load(io, std.fmt.bufPrint(&path, "{s}{s}", .{ home, suffix }) catch continue);
            }
            break;
        }
        for ([_][]const u8{ "/usr/local/share/applications", "/usr/share/applications", "/var/lib/flatpak/exports/share/applications" }) |path| catalog.load(io, path);
        return catalog;
    }

    pub fn deinit(catalog: *Catalog) void {
        catalog.arena.deinit();
        catalog.entries = .empty;
    }

    fn load(catalog: *Catalog, io: std.Io, path: []const u8) void {
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
        defer dir.close(io);
        var iterator = dir.iterate();
        var scanned: usize = 0;
        while (iterator.next(io) catch null) |file| {
            scanned += 1;
            if (scanned > max_entries or catalog.entries.items.len >= max_entries) break;
            if (!std.mem.endsWith(u8, file.name, ".desktop")) continue;
            var buf: [32768]u8 = undefined;
            const bytes = dir.readFile(io, file.name, &buf) catch continue;
            const entry = parse(file.name, bytes) orelse continue;
            const gpa = catalog.arena.allocator();
            var resolved: [4096]u8 = undefined;
            const path_len = if (std.fs.path.isAbsolute(entry.executable)) std.Io.Dir.cwd().realPathFile(io, entry.executable, &resolved) catch 0 else 0;
            const owned = Entry{
                .key = gpa.dupe(u8, entry.key) catch continue,
                .name = gpa.dupe(u8, entry.name) catch continue,
                .executable = gpa.dupe(u8, if (path_len > 0) resolved[0..path_len] else entry.executable) catch continue,
                .wm_class = gpa.dupe(u8, entry.wm_class) catch continue,
            };
            catalog.entries.append(gpa, owned) catch return;
        }
    }

    pub fn lookup(catalog: *const Catalog, executable: []const u8, command_name: []const u8, comm: []const u8) ?Entry {
        for (catalog.entries.items) |entry| {
            if (sameExecutable(executable, entry.executable) or sameExecutable(command_name, entry.executable)) return entry;
            if (entry.wm_class.len > 0 and std.ascii.eqlIgnoreCase(comm, entry.wm_class)) return entry;
        }
        return null;
    }
};

fn canonical(name: []const u8) []const u8 {
    const base = std.fs.path.basename(name);
    if (std.mem.startsWith(u8, base, "google-chrome")) return "chrome";
    if (std.mem.eql(u8, base, "chromium-browser")) return "chromium";
    return base;
}

fn sameExecutable(process: []const u8, desktop: []const u8) bool {
    if (process.len == 0 or desktop.len == 0) return false;
    const a = canonical(process);
    const b = canonical(desktop);
    // Shells and shared interpreters cannot identify a desktop application.
    for ([_][]const u8{ "env", "sh", "bash", "python", "python3", "node", "electron", "flatpak" }) |generic| {
        if (std.ascii.eqlIgnoreCase(b, generic)) return false;
    }
    if (std.ascii.eqlIgnoreCase(a, b)) return true;
    // Host helpers such as missioncenter-magpie are not always descendants.
    return b.len >= 8 and a.len > b.len and a[b.len] == '-' and std.ascii.eqlIgnoreCase(a[0..b.len], b);
}

fn execName(value: []const u8) []const u8 {
    var tokens = std.mem.tokenizeAny(u8, value, " \t");
    var executable: []const u8 = "";
    while (tokens.next()) |raw| {
        const token = std.mem.trim(u8, raw, "\"'");
        if (std.mem.startsWith(u8, token, "--command=")) return token[10..];
        if (executable.len == 0 and !std.mem.eql(u8, token, "env") and std.mem.indexOfScalar(u8, token, '=') == null) executable = token;
    }
    return executable;
}

fn parse(key: []const u8, bytes: []const u8) ?Entry {
    var entry = Entry{ .key = key, .name = "", .executable = "", .wm_class = "" };
    var in_entry = false;
    var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "[")) {
            in_entry = std.mem.eql(u8, line, "[Desktop Entry]");
            continue;
        }
        if (!in_entry) continue;
        if (std.mem.eql(u8, line, "Hidden=true")) return null;
        if (std.mem.startsWith(u8, line, "Name=")) entry.name = line[5..];
        if (std.mem.startsWith(u8, line, "Exec=")) {
            // Browser web-app shortcuts share the browser executable; assigning
            // their name to the whole browser would mislabel its other tabs.
            if (std.mem.indexOf(u8, line, "--app-id=") != null or std.mem.indexOf(u8, line, "--app=") != null) return null;
            entry.executable = execName(line[5..]);
        }
        if (std.mem.startsWith(u8, line, "StartupWMClass=")) entry.wm_class = line[15..];
    }
    return if (entry.name.len > 0 and entry.executable.len > 0) entry else null;
}

test "desktop names and Flatpak commands ignore localized names and actions" {
    const entry = parse("io.missioncenter.MissionCenter.desktop", "[Desktop Entry]\nName=Mission Center\nName[es]=Otro\nExec=/usr/bin/flatpak run --command=missioncenter io.missioncenter.MissionCenter\n[Desktop Action New]\nName=Wrong\nExec=wrong\n").?;
    try std.testing.expectEqualStrings("Mission Center", entry.name);
    try std.testing.expectEqualStrings("missioncenter", entry.executable);
    try std.testing.expect(sameExecutable("/app/bin/missioncenter-magpie-glibc", entry.executable));
    try std.testing.expect(sameExecutable("/opt/google/chrome/chrome", "google-chrome-stable"));
    try std.testing.expect(!sameExecutable("python3", "/usr/bin/python3"));
    try std.testing.expect(parse("hidden.desktop", "[Desktop Entry]\nName=Hidden\nExec=hidden\nHidden=true") == null);
    try std.testing.expect(parse("pwa.desktop", "[Desktop Entry]\nName=Web Shortcut\nExec=google-chrome --app-id=abcdef") == null);
}
