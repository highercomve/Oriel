//! App totals are formed from all readable processes, before either row limit.
const std = @import("std");
const tm = @import("telemetry.zig");
const max_processes = 65536;
const max_ancestry = 64;

pub fn matches(row: tm.ApplicationRow, filter: []const u8) bool {
    return filter.len == 0 or std.ascii.indexOfIgnoreCase(row.name, filter) != null or
        std.ascii.indexOfIgnoreCase(row.user, filter) != null;
}

fn identity(row: tm.ProcessRow) u64 {
    const key = if (row.app_key.len > 0) row.app_key else if (row.executable.len > 0) row.executable else row.name;
    var hash = std.hash.Wyhash.init(0);
    hash.update(row.user);
    hash.update(&.{0});
    hash.update(key);
    // Zero means no application filter in the sample command.
    return @max(1, hash.final());
}

fn owner(rows: []const tm.ProcessRow, by_pid: *const std.AutoHashMapUnmanaged(u32, usize), index: usize) usize {
    std.debug.assert(index < rows.len);
    const row = rows[index];
    var current = index;
    // An ancestor is evidence of launch origin, not application ownership.
    for (0..max_ancestry) |_| {
        const candidate = rows[current];
        if (!std.mem.eql(u8, row.user, candidate.user)) break;
        if (row.start_time > 0 and candidate.start_time > row.start_time) break;
        if (candidate.app_key.len > 0) return if (current == index or bundled_helper(row, candidate)) current else index;
        if (candidate.parent_pid == candidate.pid) break;
        current = by_pid.get(candidate.parent_pid) orelse break;
    }
    return index;
}

fn directory(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0) : (end -= 1) {
        if (path[end - 1] == '/' or path[end - 1] == '\\') return path[0 .. end - 1];
    }
    return "";
}

fn shared_directory(path: []const u8) bool {
    const parent = directory(path);
    const base = if (parent.len < path.len) path[@min(path.len, parent.len + 1)..] else path;
    for ([_][]const u8{ "bin", "sbin", "lib", "lib64", "usr", "opt", "applications", "windows", "system32", "syswow64", "desktop", "downloads", "program files", "program files (x86)" }) |name| {
        if (std.ascii.eqlIgnoreCase(base, name)) return true;
    }
    return path.len <= 3;
}

fn bundled_helper(row: tm.ProcessRow, app: tm.ProcessRow) bool {
    if (row.executable.len == 0 or app.executable.len == 0) return false;
    const windows = app.executable.len > 1 and app.executable[1] == ':';
    if (if (windows) std.ascii.eqlIgnoreCase(row.executable, app.executable) else std.mem.eql(u8, row.executable, app.executable)) return true;
    const root = directory(app.executable);
    if (shared_directory(root) or row.executable.len <= root.len) return false;
    const prefix_matches = if (windows) std.ascii.startsWithIgnoreCase(row.executable, root) else std.mem.startsWith(u8, row.executable, root);
    return prefix_matches and (row.executable[root.len] == '/' or row.executable[root.len] == '\\');
}

pub const Bundle = struct { key: []const u8, name: []const u8 };
/// The outer bundle owns nested Helper.app executables, even after reparenting.
pub fn macos_bundle(path: []const u8) ?Bundle {
    const end = std.mem.indexOf(u8, path, ".app/Contents/") orelse return null;
    const key = path[0 .. end + 4];
    const name = std.fs.path.basename(key);
    if (name.len <= 4) return null;
    return .{ .key = key, .name = name[0 .. name.len - 4] };
}

pub fn collect(arena: std.mem.Allocator, rows: []tm.ProcessRow) ![]tm.ApplicationRow {
    if (rows.len > max_processes) return error.TooManyProcesses;
    var by_pid: std.AutoHashMapUnmanaged(u32, usize) = .empty;
    var by_app: std.AutoHashMapUnmanaged(u64, usize) = .empty;
    var apps: std.ArrayList(tm.ApplicationRow) = .empty;
    try by_pid.ensureTotalCapacity(arena, @intCast(rows.len));
    try by_app.ensureTotalCapacity(arena, @intCast(rows.len));
    try apps.ensureTotalCapacity(arena, rows.len);
    for (rows, 0..) |row, index| try by_pid.put(arena, row.pid, index);
    for (rows, 0..) |*row, index| {
        const root = rows[owner(rows, &by_pid, index)];
        row.application_id = identity(root);
        const entry = try by_app.getOrPut(arena, row.application_id);
        if (!entry.found_existing) {
            entry.value_ptr.* = apps.items.len;
            try apps.append(arena, .{ .id = row.application_id, .name = if (root.app_name.len > 0) root.app_name else root.name, .user = root.user, .is_application = root.app_key.len > 0 });
        }
        const app = &apps.items[entry.value_ptr.*];
        app.process_count += 1;
        app.threads +|= row.threads;
        app.cpu_percent += row.cpu_percent;
        app.mem_rss_bytes +|= row.mem_rss_bytes;
    }
    std.debug.assert(apps.items.len <= rows.len);
    return apps.items;
}

/// Background programs remain in All processes, keeping Applications concise.
pub fn visible(rows: []tm.ApplicationRow) []tm.ApplicationRow {
    var len: usize = 0;
    for (rows) |row| {
        if (!row.is_application) continue;
        rows[len] = row;
        len += 1;
    }
    return rows[0..len];
}

pub fn prioritize(rows: []tm.ProcessRow, filter: []const u8, application_id: u64) u32 {
    var count: u32 = 0;
    for (rows) |row| if (row.application_id == application_id) {
        count += 1;
    };
    const Context = struct { filter: []const u8, application_id: u64 };
    std.mem.sort(tm.ProcessRow, rows, Context{ .filter = filter, .application_id = application_id }, struct {
        fn less(ctx: Context, a: tm.ProcessRow, b: tm.ProcessRow) bool {
            const am = ctx.application_id != 0 and a.application_id == ctx.application_id;
            const bm = ctx.application_id != 0 and b.application_id == ctx.application_id;
            if (am != bm) return am;
            const af = tm.matches(a, ctx.filter);
            if (af != tm.matches(b, ctx.filter)) return af;
            if (a.cpu_percent != b.cpu_percent) return a.cpu_percent > b.cpu_percent;
            if (a.mem_rss_bytes != b.mem_rss_bytes) return a.mem_rss_bytes > b.mem_rss_bytes;
            return a.pid < b.pid;
        }
    }.less);
    return count;
}

pub fn order(rows: []tm.ApplicationRow, filter: []const u8) void {
    std.mem.sort(tm.ApplicationRow, rows, filter, struct {
        fn less(f: []const u8, a: tm.ApplicationRow, b: tm.ApplicationRow) bool {
            const am = matches(a, f);
            if (am != matches(b, f)) return am;
            if (a.cpu_percent != b.cpu_percent) return a.cpu_percent > b.cpu_percent;
            if (a.mem_rss_bytes != b.mem_rss_bytes) return a.mem_rss_bytes > b.mem_rss_bytes;
            return a.id < b.id;
        }
    }.less);
}

fn process(pid: u32, parent: u32, name: []const u8, user: []const u8) tm.ProcessRow {
    return .{ .pid = pid, .parent_pid = parent, .name = name, .command = "", .user = user, .state = "S", .threads = 2, .cpu_percent = 1.5, .mem_rss_bytes = 100 };
}

test "apps include helpers, preserve nested apps and separate users" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rows = [_]tm.ProcessRow{ process(1, 0, "terminal", "alice"), process(2, 1, "chrome", "alice"), process(3, 2, "renderer", "alice"), process(4, 3, "utility", "alice"), process(5, 0, "chrome", "bob") };
    rows[0].app_key = "terminal.desktop";
    rows[1].app_key = "chrome.desktop";
    rows[1].app_name = "Google Chrome";
    rows[4].app_key = "chrome.desktop";
    rows[0].executable = "/usr/bin/terminal";
    rows[1].executable = "/opt/chrome/chrome";
    rows[2].executable = "/opt/chrome/helpers/renderer";
    rows[3].executable = "/opt/chrome/utility";
    rows[4].executable = "/opt/chrome/chrome";
    const apps = try collect(arena.allocator(), &rows);
    try std.testing.expectEqual(@as(usize, 3), apps.len);
    try std.testing.expectEqualStrings("Google Chrome", apps[1].name);
    try std.testing.expectEqual(@as(u32, 3), apps[1].process_count);
    try std.testing.expectEqual(@as(f64, 4.5), apps[1].cpu_percent);
    try std.testing.expectEqual(@as(u64, 300), apps[1].mem_rss_bytes);
    try std.testing.expectEqual(rows[1].application_id, rows[3].application_id);
    try std.testing.expect(rows[1].application_id != rows[4].application_id);
}

test "all helpers count before the 256-row cut and drilldown prioritizes idle members" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rows: [300]tm.ProcessRow = undefined;
    for (&rows, 0..) |*row, i| row.* = process(@intCast(i + 10), 0, "worker", "alice");
    rows[0].name = "quiet app";
    rows[0].cpu_percent = 0;
    rows[0].app_key = "quiet.desktop";
    rows[1].app_key = "worker.desktop";
    for (&rows) |*row| row.executable = "/opt/worker/worker";
    rows[0].executable = "/opt/quiet/app";
    for (rows[2..]) |*row| row.parent_pid = rows[1].pid;
    const apps = try collect(arena.allocator(), &rows);
    try std.testing.expectEqual(@as(usize, 2), apps.len);
    try std.testing.expectEqual(@as(u32, 299), apps[1].process_count);
    try std.testing.expectEqual(@as(u64, 29900), apps[1].mem_rss_bytes);
    const quiet_id = rows[0].application_id;
    try std.testing.expectEqual(@as(u32, 1), prioritize(&rows, "", quiet_id));
    try std.testing.expectEqual(quiet_id, rows[0].application_id);
}

test "only desktop applications appear in Applications; services remain process-only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rows = [_]tm.ProcessRow{ process(1, 0, "service", "root"), process(2, 0, "Editor.exe", "alice"), process(3, 2, "helper.exe", "alice") };
    rows[1].app_key = "c:\\program files\\editor\\editor.exe";
    rows[1].app_name = "Editor";
    rows[1].executable = "c:\\program files\\editor\\editor.exe";
    rows[2].executable = "C:\\Program Files\\Editor\\helpers\\helper.exe";
    const apps = visible(try collect(arena.allocator(), &rows));
    try std.testing.expectEqual(@as(usize, 1), apps.len);
    try std.testing.expectEqual(@as(u32, 2), apps[0].process_count);
    try std.testing.expect(rows[0].application_id != apps[0].id);
}

test "an editor owns its packaged workers, not external commands or launched apps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rows = [_]tm.ProcessRow{
        process(1, 0, "t3code", "alice"),               process(2, 1, "renderer", "alice"),
        process(3, 1, "t3-resource-monitor", "alice"),  process(4, 1, "bash", "alice"),
        process(5, 4, "oriel-system-monitor", "alice"), process(6, 4, "zig", "alice"),
        process(7, 1, "python3", "alice"),              process(8, 1, "other app", "alice"),
    };
    rows[0].app_key = "t3.desktop";
    rows[0].executable = "/opt/t3code-bin/t3code";
    rows[1].executable = "/opt/t3code-bin/t3code";
    rows[2].executable = "/opt/t3code-bin/t3-resource-monitor";
    rows[3].executable = "/usr/bin/bash";
    rows[4].executable = "/tmp/build/oriel-system-monitor";
    rows[5].executable = "/home/alice/.zvm/zig";
    rows[6].executable = "/usr/bin/python3";
    rows[7].app_key = "other.desktop";
    rows[7].executable = "/opt/other/app";
    const apps = visible(try collect(arena.allocator(), &rows));
    try std.testing.expectEqual(@as(usize, 2), apps.len);
    try std.testing.expectEqual(@as(u32, 3), apps[0].process_count);
    for (rows[3..]) |row| try std.testing.expect(row.application_id != rows[0].application_id);
    try std.testing.expectEqual(@as(u32, 3), prioritize(&rows, "", apps[0].id));
}

test "shared executable directories do not make unrelated children app helpers" {
    try std.testing.expect(!bundled_helper(.{ .executable = "/usr/bin/compiler", .pid = 2, .name = "compiler", .user = "a", .command = "", .state = "", .threads = 1, .cpu_percent = 0, .mem_rss_bytes = 0 }, .{ .executable = "/usr/bin/editor", .pid = 1, .name = "editor", .user = "a", .command = "", .state = "", .threads = 1, .cpu_percent = 0, .mem_rss_bytes = 0 }));
    var parent = process(1, 0, "taskmgr", "a");
    parent.executable = "C:\\Windows\\System32\\taskmgr.exe";
    var child = process(2, 1, "notepad", "a");
    child.executable = "C:\\Windows\\System32\\notepad.exe";
    try std.testing.expect(!bundled_helper(child, parent));
    child.executable = "C:\\WINDOWS\\system32\\TASKMGR.EXE";
    try std.testing.expect(bundled_helper(child, parent));
}

test "cycles, missing parents and exited app roots remain bounded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rows = [_]tm.ProcessRow{ process(1, 2, "a", "alice"), process(2, 1, "b", "alice"), process(3, 99, "orphan", "alice") };
    try std.testing.expectEqual(@as(usize, 3), (try collect(arena.allocator(), &rows)).len);
}

test "macOS nested bundles group together and PID reuse cannot acquire new parents" {
    const main = macos_bundle("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome").?;
    const helper = macos_bundle("/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Helper").?;
    try std.testing.expectEqualStrings(main.key, helper.key);
    try std.testing.expectEqualStrings("Google Chrome", helper.name);
    try std.testing.expect(macos_bundle("/usr/bin/worker") == null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rows = [_]tm.ProcessRow{ process(1, 0, "new app", "alice"), process(2, 1, "old orphan", "alice") };
    rows[0].app_key = "new.app";
    rows[0].start_time = 100;
    rows[1].start_time = 50;
    _ = try collect(arena.allocator(), &rows);
    try std.testing.expect(rows[0].application_id != rows[1].application_id);
}
