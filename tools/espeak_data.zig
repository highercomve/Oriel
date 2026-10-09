//! Host build tool: compile espeak-ng's runtime data (`espeak-ng-data/`) from
//! the espeak-ng source tree, as espeak-ng's Makefile does with
//! `espeak-ng --compile-intonations`, `--compile-phonemes` and
//! `--compile=<lang>` (build/espeak_data.zig runs it for `-Dkokoro` apps).
//!
//!   espeak_data <espeak-ng source root> <out dir> <dictionary,...>
//!
//! `<out dir>` receives phontab, phonindex, phondata, intonations, one
//! `<name>_dict` per dictionary and the `lang/` voice definitions. The
//! compiler writes next to its sources (phsource/compile_prog_log), and its
//! path buffers are short, so the sources it needs are staged in
//! `<out dir>/.build` and compiled with the output directory as the working
//! directory (short relative paths); the staging directory is removed after.

const std = @import("std");
const Dir = std.Io.Dir;

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("espeak-ng/espeak_ng.h");
});

const stage = ".build";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    if (argv.len != 4) {
        std.debug.print("usage: espeak_data <espeak-ng source root> <out dir> <dictionary,...>\n", .{});
        std.process.exit(2);
    }

    var root = try Dir.cwd().openDir(io, argv[1], .{});
    defer root.close(io);
    var out = try Dir.cwd().createDirPathOpen(io, argv[2], .{});
    defer out.close(io);

    var langs: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, argv[3], ", ");
    while (it.next()) |name| try langs.append(arena, name);
    if (langs.items.len == 0) fail("no dictionaries given", .{});

    out.deleteTree(io, stage) catch {};
    try copyTree(io, arena, root, "espeak-ng-data/lang", out, "lang");
    try copyTree(io, arena, root, "phsource", out, stage ++ "/phsource");
    for (langs.items) |name| try stageDictionary(io, arena, root, out, name);

    // Short relative paths from here on (espeak-ng's buffers are 160 bytes).
    try std.process.setCurrentDir(io, out);
    var context: c.espeak_ng_ERROR_CONTEXT = null;
    c.espeak_ng_InitializePath(".");
    // The phoneme compiler closes the log it's given; the intonation one
    // only on errors, and an open log keeps Windows from removing the
    // staging directory. The intonation source is
    // "<source_path>/../phsource/intonation".
    const intonations_log = openLog("intonations");
    check("intonations", c.espeak_ng_CompileIntonationPath(stage ++ "/phsource", ".", intonations_log, &context), context);
    _ = fclose(intonations_log);
    check("phonemes", c.espeak_ng_CompilePhonemeDataPath(22050, stage ++ "/phsource", ".", openLog("phonemes"), &context), context);

    // Dictionaries need the compiled phoneme tables and the language's
    // voice (its phoneme table and options), as `espeak-ng --compile=<name>`.
    check("initialize", c.espeak_ng_Initialize(&context), context);
    check("output", c.espeak_ng_InitializeOutput(c.ENOUTPUT_MODE_SYNCHRONOUS, 0, null), null);
    const log = openLog("dictionaries");
    for (langs.items) |name| {
        const name_z = try arena.dupeZ(u8, name);
        // Selecting the voice reports its (not yet compiled) dictionary as
        // missing on stderr, the Makefile's "spurious error message": into
        // the log instead.
        const saved = redirectStderr(log);
        const voice_ok = c.espeak_ng_SetVoiceByName(name_z.ptr) == c.ENS_OK or blk: {
            var sel = std.mem.zeroes(c.espeak_VOICE);
            sel.languages = name_z.ptr;
            break :blk c.espeak_ng_SetVoiceByProperties(&sel) == c.ENS_OK;
        };
        restoreStderr(saved);
        if (!voice_ok) fail("no espeak-ng voice for dictionary '{s}'", .{name});
        check(name, c.espeak_ng_CompileDictionary(stage ++ "/dictsource/", name_z.ptr, log, 0, &context), context);
        _ = fflush(log);
        const dict = try std.fmt.allocPrint(arena, "{s}_dict", .{name});
        Dir.cwd().access(io, dict, .{}) catch fail("compiling '{s}' wrote no {s}", .{ name, dict });
    }
    _ = fclose(log);

    Dir.cwd().deleteFile(io, "phondata-manifest") catch {};
    try Dir.cwd().deleteTree(io, stage);
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("espeak_data: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

const crt = if (@import("builtin").os.tag == .windows) struct {
    extern "c" fn _dup(fd: c_int) c_int;
    extern "c" fn _dup2(fd: c_int, fd2: c_int) c_int;
    extern "c" fn _fileno(f: *c.FILE) c_int;
    extern "c" fn _fdopen(fd: c_int, mode: [*:0]const u8) ?*c.FILE;
    const dup = _dup;
    const dup2 = _dup2;
    const fileno = _fileno;
    const fdopen = _fdopen;
} else struct {
    extern "c" fn dup(fd: c_int) c_int;
    extern "c" fn dup2(fd: c_int, fd2: c_int) c_int;
    extern "c" fn fileno(f: *c.FILE) c_int;
    extern "c" fn fdopen(fd: c_int, mode: [*:0]const u8) ?*c.FILE;
};

// stdio by its plain symbols: Apple's SDK defines `stderr`, `fopen` and
// friends through macros and aliases that translate-c turns into inline
// functions, which didn't compile there. fd 2 is unbuffered, so pointing it
// at a log with dup2 needs no flush of C's stderr.
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*c.FILE;
extern "c" fn fflush(f: ?*c.FILE) c_int;
extern "c" fn fclose(f: *c.FILE) c_int;

/// Point the C library's stderr (fd 2) at `log`; returns the saved fd.
fn redirectStderr(log: *c.FILE) c_int {
    _ = fflush(log);
    const saved = crt.dup(2);
    if (saved >= 0) _ = crt.dup2(crt.fileno(log), 2);
    return saved;
}

fn restoreStderr(saved: c_int) void {
    if (saved < 0) return;
    _ = crt.dup2(saved, 2);
}

/// `<stage>/<what>.log`, for one compiler's messages.
fn openLog(comptime what: []const u8) *c.FILE {
    return fopen(stage ++ "/" ++ what ++ ".log", "w") orelse fail("cannot write {s}/{s}.log", .{ stage, what });
}

/// Exit with espeak-ng's message unless `status` is OK (the logs stay in
/// `<out dir>/.build`).
fn check(what: []const u8, status: c.espeak_ng_STATUS, context: c.espeak_ng_ERROR_CONTEXT) void {
    if (status == c.ENS_OK) return;
    std.debug.print("espeak_data: compiling {s} failed (logs: {s}/*.log in the output directory):\n", .{ what, stage });
    c.espeak_ng_PrintStatusCodeMessage(status, crt.fdopen(2, "w"), context);
    std.process.exit(1);
}

/// Copy every file under `src_root/src_path` to `dst_root/dst_path`.
fn copyTree(io: std.Io, gpa: std.mem.Allocator, src_root: Dir, src_path: []const u8, dst_root: Dir, dst_path: []const u8) !void {
    var src = try src_root.openDir(io, src_path, .{ .iterate = true });
    defer src.close(io);
    var dst = try dst_root.createDirPathOpen(io, dst_path, .{});
    defer dst.close(io);
    var walker = try src.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        try src.copyFile(entry.path, dst, entry.path, io, .{ .make_path = true });
    }
}

/// The dictionary sources of `name` (dictsource/<name>_rules, _list, ...)
/// into the staging dictsource/. Like espeak-ng's default configure
/// (--with-extdict-<name>), the extended word list in dictsource/extra/
/// (cmn, ru, yue) is used when there is one.
fn stageDictionary(io: std.Io, gpa: std.mem.Allocator, root: Dir, out: Dir, name: []const u8) !void {
    var src = try root.openDir(io, "dictsource", .{});
    defer src.close(io);
    var dst = try out.createDirPathOpen(io, stage ++ "/dictsource", .{});
    defer dst.close(io);
    var found_rules = false;
    for ([_][]const u8{ "rules", "roots", "list", "listx", "emoji", "extra" }) |part| {
        for ([_][]const u8{ "", ".txt" }) |ext| {
            const file = try std.fmt.allocPrint(gpa, "{s}_{s}{s}", .{ name, part, ext });
            defer gpa.free(file);
            const copied = if (src.copyFile(file, dst, file, io, .{})) true else |err| switch (err) {
                error.FileNotFound => false,
                else => return err,
            };
            if (copied and std.mem.eql(u8, part, "rules")) found_rules = true;
            if (!copied and std.mem.eql(u8, part, "listx") and ext.len == 0) {
                const extra = try std.fmt.allocPrint(gpa, "extra/{s}", .{file});
                defer gpa.free(extra);
                src.copyFile(extra, dst, file, io, .{}) catch |e| switch (e) {
                    error.FileNotFound => {},
                    else => return e,
                };
            }
        }
    }
    if (!found_rules) fail("no espeak-ng dictionary '{s}' (dictsource/{s}_rules is missing)", .{ name, name });
}
