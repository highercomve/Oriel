//! `package_tool android-project`: write an app's Android (Gradle) project
//! from Oriel's template (`android/template`), rendering `@@key@@`
//! placeholders with the app's metadata.
//!
//! Files the developer may edit (Gradle files, the manifest, resources) are
//! written once, or again with `--force`. The Kotlin runtime
//! (`app/src/main/java/dev/oriel/`) is Oriel's and must match the library it
//! talks to over JNI: it is rewritten whenever it changed, and on every build
//! (`--runtime-only`). So are the manifest's generated regions (permissions,
//! features, queries, the main activity's intent filters, components:
//! build/android_manifest.zig): only those, the rest of the manifest stays
//! the developer's.

const std = @import("std");
const android_manifest = @import("android_manifest");
const Io = std.Io;
const Dir = Io.Dir;

pub const runtime_prefix = "app/src/main/java/dev/oriel/";
/// Rewritten by regions (`android_manifest.sync`) when it exists.
pub const manifest_path = "app/src/main/AndroidManifest.xml";

pub const Var = struct { key: []const u8, value: []const u8 };

/// Replace `@@key@@` with each var's value. Unknown placeholders are an
/// error (a template and a build that disagree).
pub fn render(gpa: std.mem.Allocator, text: []const u8, vars: []const Var) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, "@@")) |start| {
        const end = std.mem.indexOfPos(u8, text, start + 2, "@@") orelse break;
        const key = text[start + 2 .. end];
        const value = for (vars) |v| {
            if (std.mem.eql(u8, v.key, key)) break v.value;
        } else return error.UnknownPlaceholder;
        try out.appendSlice(gpa, text[i..start]);
        try out.appendSlice(gpa, value);
        i = end + 2;
    }
    try out.appendSlice(gpa, text[i..]);
    return out.toOwnedSlice(gpa);
}

test render {
    const gpa = std.testing.allocator;
    const out = try render(gpa, "id=@@app_id@@ v@@version@@;", &.{ .{ .key = "app_id", .value = "dev.x" }, .{ .key = "version", .value = "1.2" } });
    defer gpa.free(out);
    try std.testing.expectEqualStrings("id=dev.x v1.2;", out);
    try std.testing.expectError(error.UnknownPlaceholder, render(gpa, "@@nope@@", &.{}));
}

/// Where a template file goes: `gitignore.txt` is the project's `.gitignore`
/// (a dotfile would be left out of the Oriel package).
fn destPath(rel: []const u8) []const u8 {
    if (std.mem.eql(u8, rel, "gitignore.txt")) return ".gitignore";
    return rel;
}

fn isText(rel: []const u8) bool {
    inline for (.{ ".kt", ".kts", ".xml", ".properties", ".txt", ".pro", ".json" }) |ext| {
        if (std.mem.endsWith(u8, rel, ext)) return true;
    }
    return false;
}

fn exists(io: Io, path: []const u8) bool {
    Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Write `data` to `path` unless it already holds exactly that.
fn writeIfChanged(gpa: std.mem.Allocator, io: Io, path: []const u8, data: []const u8) !bool {
    if (Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 << 20))) |old| {
        defer gpa.free(old);
        if (std.mem.eql(u8, old, data)) return false;
    } else |_| {}
    if (std.fs.path.dirname(path)) |dir| try Dir.cwd().createDirPath(io, dir);
    try Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
    return true;
}

/// Rewrite the generated regions of the project's manifest `dest` from the
/// template's: true if it changed, null after an error (printed).
fn syncManifest(gpa: std.mem.Allocator, io: Io, template_dir: Dir, basename: []const u8, dest: []const u8, vars: []const Var) !?bool {
    const raw = try template_dir.readFileAlloc(io, basename, gpa, .limited(16 << 20));
    defer gpa.free(raw);
    const template = render(gpa, raw, vars) catch |err| {
        std.debug.print("error: android-project: {s}: {s} (a template placeholder without a value?)\n", .{ manifest_path, @errorName(err) });
        return null;
    };
    defer gpa.free(template);
    const current = try Dir.cwd().readFileAlloc(io, dest, gpa, .limited(16 << 20));
    defer gpa.free(current);
    const synced = android_manifest.sync(gpa, current, template) catch |err| {
        const why = switch (err) {
            error.MalformedRegion => "an oriel:NAME begin or end comment is missing, repeated or out of order",
            error.NoAnchor => "no place for the generated parts (it needs the OrielMainActivity element and <application>)",
            error.MalformedXml => "an element without its end tag",
            error.TemplateMissingRegion => "Oriel's template lacks a region (a bug in Oriel)",
            error.OutOfMemory => return error.OutOfMemory,
        };
        std.debug.print("error: android-project: {s}: {s}. Fix it, or rewrite it from the template with " ++
            "`zig build android-project -Dandroid_force=true` (that rewrites the other edited files too)\n", .{ dest, why });
        return null;
    };
    defer gpa.free(synced.text);
    if (synced.migrated) std.debug.print("android project: {s}: Oriel's generated parts now sit between oriel:NAME begin/end comments, rewritten on every build\n", .{dest});
    return try writeIfChanged(gpa, io, dest, synced.text);
}

pub fn androidProjectCmd(gpa: std.mem.Allocator, io: Io, args: []const [:0]const u8) !u8 {
    var template_dir: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    var icons_dir: ?[]const u8 = null;
    var force = false;
    var runtime_only = false;
    var vars: std.ArrayList(Var) = .empty;
    defer vars.deinit(gpa);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--template") and i + 1 < args.len) {
            i += 1;
            template_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--out") and i + 1 < args.len) {
            i += 1;
            out_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--icons") and i + 1 < args.len) {
            i += 1;
            icons_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--var") and i + 1 < args.len) {
            i += 1;
            const eq = std.mem.indexOfScalar(u8, args[i], '=') orelse {
                std.debug.print("error: android-project: --var needs key=value\n", .{});
                return 1;
            };
            try vars.append(gpa, .{ .key = args[i][0..eq], .value = args[i][eq + 1 ..] });
        } else if (std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "--runtime-only")) {
            runtime_only = true;
        } else {
            std.debug.print("error: android-project: unknown argument {s}\n", .{arg});
            return 1;
        }
    }
    const template = template_dir orelse {
        std.debug.print("error: android-project: missing --template\n", .{});
        return 1;
    };
    const out = out_dir orelse {
        std.debug.print("error: android-project: missing --out\n", .{});
        return 1;
    };
    // --runtime-only (every build): only a project `oriel android init` made.
    if (runtime_only and !exists(io, out)) return 0;

    var dir = try Dir.cwd().openDir(io, template, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    var written: usize = 0;
    var kept: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const rel = try gpa.dupe(u8, entry.path);
        defer gpa.free(rel);
        std.mem.replaceScalar(u8, rel, '\\', '/');
        const is_runtime = std.mem.startsWith(u8, rel, runtime_prefix);
        const is_manifest = std.mem.eql(u8, rel, manifest_path);
        if (runtime_only and !is_runtime and !is_manifest) continue;
        const dest = try std.fs.path.join(gpa, &.{ out, destPath(rel) });
        defer gpa.free(dest);
        if (is_manifest and !force and exists(io, dest)) {
            if (try syncManifest(gpa, io, entry.dir, entry.basename, dest, vars.items)) |changed| {
                if (changed) written += 1;
            } else return 1;
            continue;
        }
        if (runtime_only and !is_runtime) continue;
        if (!is_runtime and !force and exists(io, dest)) {
            kept += 1;
            continue;
        }
        const raw = try entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(16 << 20));
        defer gpa.free(raw);
        const data = if (isText(rel)) render(gpa, raw, vars.items) catch |err| {
            std.debug.print("error: android-project: {s}: {s} (a template placeholder without a value?)\n", .{ rel, @errorName(err) });
            return 1;
        } else try gpa.dupe(u8, raw);
        defer gpa.free(data);
        if (try writeIfChanged(gpa, io, dest, data)) written += 1;
    }

    // Launcher icons from the app's icon (the sizes resize-icons makes).
    if (!runtime_only) if (icons_dir) |icons| {
        const densities = [_]struct { []const u8, u32 }{ .{ "mdpi", 48 }, .{ "xhdpi", 128 }, .{ "xxxhdpi", 256 } };
        for (densities) |d| {
            const dest = try std.fmt.allocPrint(gpa, "{s}/app/src/main/res/mipmap-{s}/ic_launcher.png", .{ out, d[0] });
            defer gpa.free(dest);
            if (!force and exists(io, dest)) continue;
            const src = try std.fmt.allocPrint(gpa, "{s}/{d}x{d}.png", .{ icons, d[1], d[1] });
            defer gpa.free(src);
            const png = Dir.cwd().readFileAlloc(io, src, gpa, .limited(16 << 20)) catch continue;
            defer gpa.free(png);
            if (try writeIfChanged(gpa, io, dest, png)) written += 1;
        }
    };

    if (!runtime_only) {
        std.debug.print("android project: {s} ({d} files written, {d} kept; --force rewrites them)\n", .{ out, written, kept });
    } else if (written > 0) {
        std.debug.print("android project: updated the Oriel runtime or the manifest's generated parts in {s} ({d} files)\n", .{ out, written });
    }
    return 0;
}
