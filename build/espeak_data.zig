//! espeak-ng (GPL-3.0-or-later) for `-Dkokoro`: the library's sources and
//! config (shared by the app build in build/ggml.zig and the host data
//! compiler), and its compiled runtime data, `espeak-ng-data/`.
//!
//! The 1.52.0 source tarball has the data's sources (phsource/, dictsource/,
//! espeak-ng-data/lang/) but none of the compiled files, so a host build of
//! libespeak-ng (tools/espeak_data.zig) compiles them, as espeak-ng's
//! Makefile does: intonations, phoneme tables (phontab, phonindex,
//! phondata) and one `<name>_dict` per dictionary of `-Dtts_languages`.
//! The output depends only on the dependency and that list, so it is cached.
//!
//! `addApp` ships it with `-Dkokoro` apps (`espeak-ng-data/` next to the
//! executable, in the macOS bundle's Resources, at the iOS bundle's root, in
//! the APK's assets); `src/modules/tts/espeak_data.zig` finds it at run time.

const std = @import("std");

/// espeak-ng dictionary names compiled by default: the languages of Oriel's
/// TTS catalog. "en" covers en-us and en-gb, "pt" pt-br, "cmn" Mandarin
/// (espeak's "zh"/"cmn" voices; kokoro.cpp passes "cmn"-family names).
pub const default_languages = "en,es,fr,pt,it,ja,cmn,hi";

/// Prefix of the named lazy paths Oriel's build registers for each compiled
/// file (`espeak-ng-data/phondata`, ...), and the name of the directory's own.
pub const name = "espeak-ng-data";

/// libespeak-ng sources for phonemization (`src/libespeak-ng`); the audio
/// backends (pcaudio, sonic, MBROLA, speechPlayer) stay off.
pub const lib_sources = [_][]const u8{
    "common.c",
    "compiledict.c",
    "espeak_api.c",
    "error.c",
    "ieee80.c",
    "intonation.c",
    "langopts.c",
    "mnemonics.c",
    "numbers.c",
    "phoneme.c",
    "phonemelist.c",
    "readclause.c",
    "setlengths.c",
    "soundicon.c",
    "spect.c",
    "ssml.c",
    "synthdata.c",
    "synthesize.c",
    "speech.c",
    "tr_languages.c",
    "translate.c",
    "translateword.c",
    "voices.c",
    "wavegen.c",
    "klatt.c",
    "dictionary.c",
    "encoding.c",
};

/// ucd-tools (`src/ucd-tools/src`), espeak-ng's Unicode tables.
pub const ucd_sources = [_][]const u8{
    "case.c",
    "categories.c",
    "ctype.c",
    "proplist.c",
    "scripts.c",
    "tostring.c",
};

/// C flags for libespeak-ng. N_PATH_HOME: the data directory path buffer
/// (160 bytes on POSIX by default) holds install paths such as an iOS
/// container's or a Windows profile's.
pub const cflags = [_][]const u8{
    "-std=c11",
    "-D_GNU_SOURCE",
    "-D_XOPEN_SOURCE=600",
    "-fno-sanitize=undefined",
    "-DN_PATH_HOME=1024",
};

/// The generated `config.h` (espeak-ng's CMake writes it from configure)
/// and upstream's `endian.h` shim (macOS has no system endian.h; it handles
/// Apple byte order and forwards to the native header on Linux).
pub fn configDir(b: *std.Build, dep: *std.Build.Dependency) std.Build.LazyPath {
    const files = b.addWriteFiles();
    _ = files.addCopyFile(dep.path("src/include/compat/endian.h"), "endian.h");
    _ = files.add("config.h",
        \\#pragma once
        \\#define LIBESPEAK_NG_EXPORT 1
        \\#define HAVE_MKSTEMP 1
        \\#define USE_ASYNC 0
        \\#define USE_KLATT 1
        \\#define USE_LIBPCAUDIO 0
        \\#define USE_LIBSONIC 0
        \\#define USE_MBROLA 0
        \\#define USE_SPEECHPLAYER 0
        \\#define PACKAGE_VERSION "1.52.0"
        \\#define PATH_ESPEAK_DATA "."
        \\#ifdef _WIN32
        \\#include <string.h>
        \\#define strerror_r(errnum, buf, buflen) strerror_s(buf, buflen, errnum)
        \\#endif
        \\
    );
    return files.getDirectory();
}

/// Add libespeak-ng (and ucd-tools) to `module`, with `extra` flags first
/// (optimization, target defines). `compiler`: also the data compiler
/// (compiledata.c), for the host tool.
pub fn addLibrary(b: *std.Build, module: *std.Build.Module, dep: *std.Build.Dependency, extra: []const []const u8, compiler: bool) void {
    module.addIncludePath(configDir(b, dep));
    module.addIncludePath(dep.path("src/include"));
    module.addIncludePath(dep.path("src/libespeak-ng"));
    module.addIncludePath(dep.path("src/ucd-tools/src/include"));
    const flags = std.mem.concat(b.allocator, []const u8, &.{ extra, &cflags }) catch @panic("OOM");
    module.addCSourceFiles(.{ .root = dep.path("src/libespeak-ng"), .files = &lib_sources, .flags = flags });
    if (compiler) module.addCSourceFiles(.{ .root = dep.path("src/libespeak-ng"), .files = &.{"compiledata.c"}, .flags = flags });
    module.addCSourceFiles(.{ .root = dep.path("src/ucd-tools/src"), .files = &ucd_sources, .flags = flags });
}

/// The compiled data directory for `languages` (comma-separated espeak-ng
/// dictionary names), and the paths of its files relative to it.
pub const Data = struct {
    dir: std.Build.LazyPath,
    files: []const []const u8,
};

/// Compile the data (a cached host-tool run) and register it on `b` as named
/// lazy paths: `espeak-ng-data` (the directory) and `espeak-ng-data/<file>`
/// for every file, which `addApp` installs and packages.
pub fn addData(b: *std.Build, dep: *std.Build.Dependency, languages: []const u8) Data {
    var names: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, languages, ", ");
    while (it.next()) |lang| {
        if (!validName(lang)) fatal("-Dtts_languages: \"{s}\" is not an espeak-ng dictionary name (e.g. en, cmn, pt)", .{lang});
        const rules = dep.builder.pathFromRoot(b.fmt("dictsource/{s}_rules", .{lang}));
        std.Io.Dir.cwd().access(b.graph.io, rules, .{}) catch fatal("-Dtts_languages: espeak-ng 1.52.0 has no dictionary \"{s}\" (no dictsource/{s}_rules)", .{ lang, lang });
        for (names.items) |n| {
            if (std.mem.eql(u8, n, lang)) break;
        } else names.append(b.allocator, lang) catch @panic("OOM");
    }
    if (names.items.len == 0) fatal("-Dtts_languages: no dictionary given", .{});
    const list = std.mem.join(b.allocator, ",", names.items) catch @panic("OOM");

    const tool = b.addExecutable(.{
        .name = "espeak_data",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/espeak_data.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
            .link_libc = true,
        }),
    });
    addLibrary(b, tool.root_module, dep, &.{ "-O2", "-w" }, true);

    const run = b.addRunArtifact(tool);
    run.setName("compile espeak-ng-data");
    run.addDirectoryArg(dep.path("."));
    const dir = run.addOutputDirectoryArg(name);
    run.addArg(list);
    run.expectExitCode(0);

    var files: std.ArrayList([]const u8) = .empty;
    files.appendSlice(b.allocator, &.{ "intonations", "phondata", "phonindex", "phontab" }) catch @panic("OOM");
    for (names.items) |n| files.append(b.allocator, b.fmt("{s}_dict", .{n})) catch @panic("OOM");
    // lang/: every voice definition (15 KB), listed from the dependency.
    {
        const lang_dir = dep.builder.pathFromRoot("espeak-ng-data/lang");
        var d = std.Io.Dir.cwd().openDir(b.graph.io, lang_dir, .{ .iterate = true }) catch fatal("espeak-ng: cannot open {s}", .{lang_dir});
        defer d.close(b.graph.io);
        var walker = d.walk(b.allocator) catch @panic("OOM");
        defer walker.deinit();
        var lang_files: std.ArrayList([]const u8) = .empty;
        while (walker.next(b.graph.io) catch |err| fatal("espeak-ng: reading {s}: {s}", .{ lang_dir, @errorName(err) })) |entry| {
            if (entry.kind != .file) continue;
            const rel = b.dupe(entry.path);
            std.mem.replaceScalar(u8, rel, '\\', '/');
            lang_files.append(b.allocator, b.fmt("lang/{s}", .{rel})) catch @panic("OOM");
        }
        std.mem.sort([]const u8, lang_files.items, {}, lessThan);
        files.appendSlice(b.allocator, lang_files.items) catch @panic("OOM");
    }

    b.addNamedLazyPath(name, dir);
    for (files.items) |f| b.addNamedLazyPath(b.fmt("{s}/{s}", .{ name, f }), dir.path(b, f));
    return .{ .dir = dir, .files = files.items };
}

/// The data `addData` registered on the Oriel dependency's builder (`-Dkokoro`),
/// or null. Files are sorted, relative to the directory.
pub fn fromDependency(b: *std.Build, oriel_builder: *std.Build) ?Data {
    const dir = oriel_builder.named_lazy_paths.get(name) orelse return null;
    var files: std.ArrayList([]const u8) = .empty;
    var it = oriel_builder.named_lazy_paths.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (key.len > name.len + 1 and std.mem.startsWith(u8, key, name) and key[name.len] == '/')
            files.append(b.allocator, key[name.len + 1 ..]) catch @panic("OOM");
    }
    std.mem.sort([]const u8, files.items, {}, lessThan);
    return .{ .dir = dir, .files = files.items };
}

/// Lazy path of one file of `data` (from `fromDependency`).
pub fn filePath(oriel_builder: *std.Build, rel: []const u8) std.Build.LazyPath {
    return oriel_builder.named_lazy_paths.get(oriel_builder.fmt("{s}/{s}", .{ name, rel })).?;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn validName(s: []const u8) bool {
    if (s.len == 0 or s.len > 16) return false;
    for (s) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_')) return false;
    return true;
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}
