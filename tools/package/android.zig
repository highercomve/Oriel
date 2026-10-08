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
//! the developer's. The app's own sources (`AppOptions.android.sources`) are
//! copied to `app/src/main/java/<package>/` and its R8 rules
//! (`.proguard_rules`) set between the oriel:proguard markers of
//! `app/proguard-rules.pro`, on every run too.

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

// ---------------------------------------------------------------------------
// The app's own sources and R8 rules (`AppOptions.android.sources`,
// `.proguard_rules`), copied in on every build
// ---------------------------------------------------------------------------

pub const java_prefix = "app/src/main/java/";
/// The sources the last run copied (project-relative, one per line), so a
/// source the build no longer lists is removed.
pub const sources_list_path = "app/.oriel-sources";
pub const proguard_path = "app/proguard-rules.pro";
pub const proguard_begin = "# oriel:proguard begin (AppOptions.android.proguard_rules; rewritten on every build)";
pub const proguard_end = "# oriel:proguard end";

/// The package a Kotlin or Java file declares (its `package` line, after
/// comments and file annotations), null when it has none or it isn't a
/// dotted identifier.
pub fn sourcePackage(text: []const u8) ?[]const u8 {
    var in_comment = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        if (in_comment) {
            const end = std.mem.indexOf(u8, line, "*/") orelse continue;
            in_comment = false;
            line = std.mem.trim(u8, line[end + 2 ..], " \t\r");
        }
        if (std.mem.startsWith(u8, line, "/*")) {
            const end = std.mem.indexOfPos(u8, line, 2, "*/") orelse {
                in_comment = true;
                continue;
            };
            line = std.mem.trim(u8, line[end + 2 ..], " \t\r");
        }
        if (line.len == 0 or std.mem.startsWith(u8, line, "//") or std.mem.startsWith(u8, line, "@file:")) continue;
        if (!std.mem.startsWith(u8, line, "package ")) return null;
        var name = std.mem.trim(u8, line["package ".len..], " \t");
        if (std.mem.indexOfAny(u8, name, "; \t/")) |end| name = name[0..end];
        return if (validPackage(name)) name else null;
    }
    return null;
}

fn validPackage(name: []const u8) bool {
    var parts = std.mem.splitScalar(u8, name, '.');
    while (parts.next()) |p| {
        if (p.len == 0 or std.ascii.isDigit(p[0])) return false;
        for (p) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return name.len > 0;
}

/// Where a source goes in the project: `app/src/main/java/<package as
/// path>/<file name>`.
pub fn sourceDest(gpa: std.mem.Allocator, package: []const u8, basename: []const u8) ![]u8 {
    const dir = try gpa.dupe(u8, package);
    defer gpa.free(dir);
    std.mem.replaceScalar(u8, dir, '.', '/');
    return std.fmt.allocPrint(gpa, java_prefix ++ "{s}/{s}", .{ dir, basename });
}

/// `current` (the project's proguard-rules.pro) with the block between the
/// oriel:proguard markers set to `rules`: added at the end when there is
/// none, removed when `rules` is empty.
pub fn withProguardRules(gpa: std.mem.Allocator, current: []const u8, rules: []const u8) ![]u8 {
    return withGeneratedBlock(gpa, current, rules, proguard_begin, proguard_end);
}

fn withGeneratedBlock(gpa: std.mem.Allocator, current: []const u8, rules: []const u8, comptime begin: []const u8, comptime end: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var head = current;
    var tail: []const u8 = "";
    if (std.mem.indexOf(u8, current, begin)) |b| {
        const e = std.mem.indexOfPos(u8, current, b, end) orelse return error.MalformedRegion;
        if (std.mem.indexOfPos(u8, current, b + begin.len, begin) != null or
            std.mem.indexOf(u8, current, end) != e or
            std.mem.indexOfPos(u8, current, e + end.len, end) != null) return error.MalformedRegion;
        var after = e + end.len;
        if (after < current.len and current[after] == '\n') after += 1;
        head = current[0..b];
        tail = current[after..];
    } else if (std.mem.indexOf(u8, current, end) != null) return error.MalformedRegion;
    try out.appendSlice(gpa, head);
    if (rules.len > 0) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(gpa, '\n');
        try out.appendSlice(gpa, begin ++ "\n");
        try out.appendSlice(gpa, rules);
        if (rules[rules.len - 1] != '\n') try out.append(gpa, '\n');
        try out.appendSlice(gpa, end ++ "\n");
    }
    try out.appendSlice(gpa, tail);
    return out.toOwnedSlice(gpa);
}

/// Copy `sources` into the project `out`, remove the ones a previous run
/// copied that are no longer listed, and set the R8 rules block. Returns
/// the files written or removed, null after an error (printed).
fn syncAppFiles(gpa: std.mem.Allocator, io: Io, template: []const u8, out: []const u8, sources: []const []const u8, proguard: ?[]const u8) !?usize {
    var changed: usize = 0;
    var dests: std.ArrayList([]u8) = .empty;
    defer {
        for (dests.items) |d| gpa.free(d);
        dests.deinit(gpa);
    }
    for (sources) |src| {
        const base = std.fs.path.basename(src);
        if (!std.mem.endsWith(u8, base, ".kt") and !std.mem.endsWith(u8, base, ".java")) {
            std.debug.print("error: android-project: {s}: AppOptions.android.sources takes .kt and .java files\n", .{src});
            return null;
        }
        const text = Dir.cwd().readFileAlloc(io, src, gpa, .limited(16 << 20)) catch |err| {
            std.debug.print("error: android-project: {s}: {s}\n", .{ src, @errorName(err) });
            return null;
        };
        defer gpa.free(text);
        const package = sourcePackage(text) orelse {
            std.debug.print("error: android-project: {s}: no `package` line (it decides where the file goes in app/src/main/java/)\n", .{src});
            return null;
        };
        try dests.ensureUnusedCapacity(gpa, 1);
        const rel = try sourceDest(gpa, package, base);
        dests.appendAssumeCapacity(rel);
        // Oriel's runtime files are the template's.
        const in_template = try std.fs.path.join(gpa, &.{ template, rel });
        defer gpa.free(in_template);
        if (exists(io, in_template)) {
            std.debug.print("error: android-project: {s}: {s} is Oriel's runtime file; rename the source\n", .{ src, rel });
            return null;
        }
        for (dests.items[0 .. dests.items.len - 1]) |d| if (std.mem.eql(u8, d, rel)) {
            std.debug.print("error: android-project: {s}: two sources go to {s}\n", .{ src, rel });
            return null;
        };
        const dest = try std.fs.path.join(gpa, &.{ out, rel });
        defer gpa.free(dest);
        if (try writeIfChanged(gpa, io, dest, text)) changed += 1;
    }

    // The previous run's sources that aren't listed any more.
    const list_path = try std.fs.path.join(gpa, &.{ out, sources_list_path });
    defer gpa.free(list_path);
    if (Dir.cwd().readFileAlloc(io, list_path, gpa, .limited(1 << 20))) |old| {
        defer gpa.free(old);
        var it = std.mem.tokenizeAny(u8, old, "\r\n");
        while (it.next()) |rel| {
            if (!std.mem.startsWith(u8, rel, java_prefix) or std.mem.indexOf(u8, rel, "..") != null) continue;
            const still = for (dests.items) |d| {
                if (std.mem.eql(u8, d, rel)) break true;
            } else false;
            if (still) continue;
            const stale = try std.fs.path.join(gpa, &.{ out, rel });
            defer gpa.free(stale);
            Dir.cwd().deleteFile(io, stale) catch continue;
            changed += 1;
            // Its package directories, while empty (not java/ itself).
            var dir = std.fs.path.dirname(rel);
            while (dir) |d| : (dir = std.fs.path.dirname(d)) {
                if (d.len <= java_prefix.len - 1) break;
                const abs = try std.fs.path.join(gpa, &.{ out, d });
                defer gpa.free(abs);
                Dir.cwd().deleteDir(io, abs) catch break;
            }
        }
    } else |_| {}
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    for (dests.items) |d| {
        try list.appendSlice(gpa, d);
        try list.append(gpa, '\n');
    }
    if (dests.items.len > 0) {
        _ = try writeIfChanged(gpa, io, list_path, list.items);
    } else Dir.cwd().deleteFile(io, list_path) catch {};

    // R8 rules: the block in proguard-rules.pro.
    const pro_path = try std.fs.path.join(gpa, &.{ out, proguard_path });
    defer gpa.free(pro_path);
    const rules: []u8 = if (proguard) |p| Dir.cwd().readFileAlloc(io, p, gpa, .limited(1 << 20)) catch |err| {
        std.debug.print("error: android-project: {s}: {s}\n", .{ p, @errorName(err) });
        return null;
    } else try gpa.alloc(u8, 0);
    defer gpa.free(rules);
    const current: []u8 = Dir.cwd().readFileAlloc(io, pro_path, gpa, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => if (rules.len == 0) return changed else try gpa.alloc(u8, 0),
        else => return err,
    };
    defer gpa.free(current);
    const updated = withProguardRules(gpa, current, rules) catch |err| switch (err) {
        error.MalformedRegion => {
            std.debug.print("error: android-project: {s}: \"{s}\" without \"{s}\"\n", .{ pro_path, proguard_begin, proguard_end });
            return null;
        },
        else => return err,
    };
    defer gpa.free(updated);
    if (!std.mem.eql(u8, updated, current) and try writeIfChanged(gpa, io, pro_path, updated)) changed += 1;
    return changed;
}

test sourcePackage {
    try std.testing.expectEqualStrings("com.example.ghost", sourcePackage(
        \\/*
        \\ * License.
        \\ */
        \\// A helper.
        \\@file:JvmName("Helper")
        \\
        \\package com.example.ghost
        \\
        \\import android.content.Context
    ).?);
    try std.testing.expectEqualStrings("com.example", sourcePackage("/* x */ package com.example;\nclass A {}").?);
    try std.testing.expectEqualStrings("a.b_c.d1", sourcePackage("package a.b_c.d1 // trailing").?);
    try std.testing.expect(sourcePackage("import x.y\nclass A") == null);
    try std.testing.expect(sourcePackage("package ../evil") == null);
    try std.testing.expect(sourcePackage("package a..b") == null);
    try std.testing.expect(sourcePackage("") == null);

    const gpa = std.testing.allocator;
    const dest = try sourceDest(gpa, "com.example.ghost", "Helper.kt");
    defer gpa.free(dest);
    try std.testing.expectEqualStrings("app/src/main/java/com/example/ghost/Helper.kt", dest);
}

test withProguardRules {
    const gpa = std.testing.allocator;
    const base = "-keep class dev.oriel.** { *; }\n\n# Mine\n-keep class x.Y\n";
    const added = try withProguardRules(gpa, base, "-keep class com.example.** { *; }");
    defer gpa.free(added);
    try std.testing.expectEqualStrings(base ++ proguard_begin ++ "\n-keep class com.example.** { *; }\n" ++ proguard_end ++ "\n", added);
    // Rewritten in place, not appended again; the developer's lines after it stay.
    const edited = try std.mem.concat(gpa, u8, &.{ added, "-keep class z.Z\n" });
    defer gpa.free(edited);
    const again = try withProguardRules(gpa, edited, "-dontwarn com.example.**\n");
    defer gpa.free(again);
    try std.testing.expectEqualStrings(base ++ proguard_begin ++ "\n-dontwarn com.example.**\n" ++ proguard_end ++ "\n-keep class z.Z\n", again);
    // No rules: the block goes.
    const removed = try withProguardRules(gpa, again, "");
    defer gpa.free(removed);
    try std.testing.expectEqualStrings(base ++ "-keep class z.Z\n", removed);
    const unchanged = try withProguardRules(gpa, base, "");
    defer gpa.free(unchanged);
    try std.testing.expectEqualStrings(base, unchanged);
    try std.testing.expectError(error.MalformedRegion, withProguardRules(gpa, proguard_begin ++ "\nx\n", "y"));
}

pub fn androidProjectCmd(gpa: std.mem.Allocator, io: Io, args: []const [:0]const u8) !u8 {
    var template_dir: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    var icons_dir: ?[]const u8 = null;
    var force = false;
    var runtime_only = false;
    var vars: std.ArrayList(Var) = .empty;
    defer vars.deinit(gpa);
    var sources: std.ArrayList([]const u8) = .empty;
    defer sources.deinit(gpa);
    var proguard: ?[]const u8 = null;

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
        } else if (std.mem.eql(u8, arg, "--source") and i + 1 < args.len) {
            i += 1;
            try sources.append(gpa, args[i]);
        } else if (std.mem.eql(u8, arg, "--proguard") and i + 1 < args.len) {
            i += 1;
            proguard = args[i];
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

    // App dependencies survive both runtime sync and full project regeneration.
    for (vars.items) |v| if (std.mem.eql(u8, v.key, "android_dependencies")) {
        const gradle_path = try std.fs.path.join(gpa, &.{ out, "app/build.gradle.kts" });
        defer gpa.free(gradle_path);
        if (!exists(io, gradle_path)) break;
        const current = try Dir.cwd().readFileAlloc(io, gradle_path, gpa, .limited(1 << 20));
        defer gpa.free(current);
        const synced = try withGeneratedBlock(gpa, current, "apply(from = \"oriel-dependencies.gradle\")\n", "// oriel:dependencies begin", "// oriel:dependencies end");
        defer gpa.free(synced);
        if (try writeIfChanged(gpa, io, gradle_path, synced)) written += 1;
        const deps_path = try std.fs.path.join(gpa, &.{ out, "app/oriel-dependencies.gradle" });
        defer gpa.free(deps_path);
        const deps = try std.fmt.allocPrint(gpa, "// Generated by Oriel from AppOptions.android.dependencies.\ndependencies {{\n{s}}}\n", .{v.value});
        defer gpa.free(deps);
        if (try writeIfChanged(gpa, io, deps_path, deps)) written += 1;
        // Applied Kotlin scripts crash AGP 8.x lint's FIR analysis. Keep this
        // generated dependency-only script in Groovy and remove the old script.
        const legacy_deps_path = try std.fs.path.join(gpa, &.{ out, "app/oriel-dependencies.gradle.kts" });
        defer gpa.free(legacy_deps_path);
        Dir.cwd().deleteFile(io, legacy_deps_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        break;
    };

    // The app's own Kotlin/Java sources and R8 rules, on every run.
    written += (try syncAppFiles(gpa, io, template, out, sources.items, proguard)) orelse return 1;

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
        std.debug.print("android project: updated the Oriel runtime, the manifest's generated parts or the app's sources and R8 rules in {s} ({d} files)\n", .{ out, written });
    }
    return 0;
}

test "Android runtime regeneration refreshes extension registration and preserves app sources" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const template = try std.fmt.allocPrintSentinel(gpa, "{s}/template", .{root}, 0);
    defer gpa.free(template);
    const out = try std.fmt.allocPrintSentinel(gpa, "{s}/project", .{root}, 0);
    defer gpa.free(out);
    const source = try std.fmt.allocPrintSentinel(gpa, "{s}/Feature.kt", .{root}, 0);
    defer gpa.free(source);
    const registry_rel = runtime_prefix ++ "OrielAppExtensions.kt";
    try tmp.dir.createDirPath(io, "template/" ++ runtime_prefix);
    try tmp.dir.createDirPath(io, "project/app");
    try tmp.dir.writeFile(io, .{ .sub_path = "project/app/build.gradle.kts", .data = "// developer-owned settings\ndependencies { implementation(\"manual:library:1.0\") }\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "template/" ++ registry_rel, .data = "val extensions = listOf(@@android_extensions@@)\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "Feature.kt", .data = "package dev.example\nclass Feature // app-owned\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "project/app/oriel-dependencies.gradle.kts", .data = "// legacy generated script\n" });
    const base_args = [_][:0]const u8{ "--template", template, "--out", out, "--runtime-only", "--source", source, "--var", "android_dependencies=    add(\"implementation\", \"example:feature:1.0\")\n", "--var" };
    try std.testing.expectEqual(@as(u8, 0), try androidProjectCmd(gpa, io, &(base_args ++ .{"android_extensions=dev.example.Feature(),"})));
    var legacy_path_buf: [4096]u8 = undefined;
    try std.testing.expect(!exists(io, try std.fmt.bufPrint(&legacy_path_buf, "{s}/app/oriel-dependencies.gradle.kts", .{out})));
    // A second build changes registration and copies updated app code, rather
    // than requiring edits to the generated runtime or leaving stale wiring.
    try tmp.dir.writeFile(io, .{ .sub_path = "Feature.kt", .data = "package dev.example\nclass Feature // developer's next edit\n" });
    try std.testing.expectEqual(@as(u8, 0), try androidProjectCmd(gpa, io, &(base_args ++ .{"android_extensions="})));
    const registry = try tmp.dir.readFileAlloc(io, "project/" ++ registry_rel, gpa, .limited(4096));
    defer gpa.free(registry);
    try std.testing.expectEqualStrings("val extensions = listOf()\n", registry);
    const app_source = try tmp.dir.readFileAlloc(io, "project/app/src/main/java/dev/example/Feature.kt", gpa, .limited(4096));
    defer gpa.free(app_source);
    try std.testing.expectEqualStrings("package dev.example\nclass Feature // developer's next edit\n", app_source);
    const original = try tmp.dir.readFileAlloc(io, "Feature.kt", gpa, .limited(4096));
    defer gpa.free(original);
    try std.testing.expectEqualStrings(app_source, original);
    const deps = try tmp.dir.readFileAlloc(io, "project/app/oriel-dependencies.gradle", gpa, .limited(4096));
    defer gpa.free(deps);
    try std.testing.expect(std.mem.indexOf(u8, deps, "example:feature:1.0") != null);
    try std.testing.expectEqual(@as(u8, 0), try androidProjectCmd(gpa, io, &.{ "--template", template, "--out", out, "--runtime-only", "--var", "android_extensions=", "--var", "android_dependencies=" }));
    const removed = try tmp.dir.readFileAlloc(io, "project/app/oriel-dependencies.gradle", gpa, .limited(4096));
    defer gpa.free(removed);
    try std.testing.expect(std.mem.indexOf(u8, removed, "example:feature") == null);
    const gradle = try tmp.dir.readFileAlloc(io, "project/app/build.gradle.kts", gpa, .limited(4096));
    defer gpa.free(gradle);
    try std.testing.expect(std.mem.startsWith(u8, gradle, "// developer-owned settings\ndependencies { implementation(\"manual:library:1.0\") }\n"));
    try std.testing.expect(std.mem.indexOf(u8, gradle, "apply(from = \"oriel-dependencies.gradle\")") != null);
    try tmp.dir.writeFile(io, .{ .sub_path = "template/app/build.gradle.kts", .data = "// fresh project\n" });
    try std.testing.expectEqual(@as(u8, 0), try androidProjectCmd(gpa, io, &.{ "--template", template, "--out", out, "--force", "--var", "android_extensions=", "--var", "android_dependencies=    add(\"implementation\", \"example:feature:2.0\")\n" }));
    const regenerated = try tmp.dir.readFileAlloc(io, "project/app/oriel-dependencies.gradle", gpa, .limited(4096));
    defer gpa.free(regenerated);
    try std.testing.expect(std.mem.indexOf(u8, regenerated, "example:feature:2.0") != null);
    const fresh_gradle = try tmp.dir.readFileAlloc(io, "project/app/build.gradle.kts", gpa, .limited(4096));
    defer gpa.free(fresh_gradle);
    try std.testing.expect(std.mem.startsWith(u8, fresh_gradle, "// fresh project\n"));
    try std.testing.expect(std.mem.indexOf(u8, fresh_gradle, "apply(from = \"oriel-dependencies.gradle\")") != null);
}
