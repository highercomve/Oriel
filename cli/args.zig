//! A small comptime command-line parser.
//!
//! Subcommands are the fields of a `union(enum)`; each field's payload is a
//! struct whose fields are the command's options and positional arguments.
//! Declarations on the payload struct describe it:
//!
//!     const Init = struct {
//!         pub const summary = "Create a new app";          // required
//!         pub const positionals = .{"name"};                 // fields filled in order
//!         pub const help = .{ .name = "...", .id = "..." };  // per-field help text
//!         pub const values = .{ .id = "app-id" };            // value names in help
//!         name: []const u8,                                  // required: no default
//!         template: Template = .react,                       // --template <react|vue|...>
//!         id: ?[]const u8 = null,                            // --id <id>
//!         no_install: bool = false,                          // --no-install
//!     };
//!
//! A command with `pub const forward = "args"` does no option parsing: every
//! argument after the command name lands in that `[]const []const u8` field
//! (used by the `zig build` wrappers).
//!
//! Option names are field names with `_` replaced by `-`. Values are given as
//! `--opt value` or `--opt=value`; `--` ends option parsing. Supported field
//! types: `bool`, `[]const u8`, `?[]const u8`, enums and optional enums.
//! Parsing never allocates: strings in the result are slices of `argv`.

const std = @import("std");

/// What a successful parse asks the program to do.
pub fn Result(comptime Commands: type) type {
    return union(enum) {
        command: Commands,
        /// Print help: for one command, or the top-level help when null.
        help: ?std.meta.Tag(Commands),
        version,
    };
}

/// Filled with a readable message when `parse` returns `error.Usage`.
pub const Diagnostic = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,
    /// The command the error is about (for "see oriel <cmd> --help").
    command: ?[]const u8 = null,

    pub fn message(d: *const Diagnostic) []const u8 {
        return d.buf[0..d.len];
    }

    fn set(d: *Diagnostic, comptime fmt: []const u8, args: anytype) error{Usage} {
        // On overflow the buffer holds a partial write: replace it whole
        // rather than expose bytes that were never written.
        const fallback = "invalid argument (too long to show)";
        d.len = if (std.fmt.bufPrint(&d.buf, fmt, args)) |written| written.len else |_| blk: {
            @memcpy(d.buf[0..fallback.len], fallback);
            break :blk fallback.len;
        };
        return error.Usage;
    }
};

/// Parse `argv` (without the program name) into a command of `Commands`.
pub fn parse(comptime Commands: type, argv: []const []const u8, diag: *Diagnostic) error{Usage}!Result(Commands) {
    if (argv.len == 0) return .{ .help = null };
    const first = argv[0];
    if (isHelp(first)) return .{ .help = null };
    if (std.mem.eql(u8, first, "--version") or std.mem.eql(u8, first, "-V")) return .version;
    if (std.mem.eql(u8, first, "help")) {
        if (argv.len == 1) return .{ .help = null };
        inline for (@typeInfo(Commands).@"union".fields) |f| {
            if (std.mem.eql(u8, argv[1], comptime optionName(f.name))) return .{ .help = @field(std.meta.Tag(Commands), f.name) };
        }
        return diag.set("unknown command '{s}'", .{argv[1]});
    }
    if (first.len > 0 and first[0] == '-') return diag.set("unknown option '{s}'", .{first});

    inline for (@typeInfo(Commands).@"union".fields) |f| {
        if (std.mem.eql(u8, first, comptime optionName(f.name))) {
            diag.command = comptime optionName(f.name);
            const rest = argv[1..];
            if (@hasDecl(f.type, "forward")) {
                // `oriel package --help` alone: this command's help (it works
                // outside a project and says how to see the project's own
                // options). With other arguments, --help goes on to `zig build`.
                if (rest.len == 1 and isHelp(rest[0])) return .{ .help = @field(std.meta.Tag(Commands), f.name) };
                var cmd: f.type = .{};
                @field(cmd, f.type.forward) = rest;
                return .{ .command = @unionInit(Commands, f.name, cmd) };
            }
            for (rest) |arg| {
                if (std.mem.eql(u8, arg, "--")) break;
                if (isHelp(arg)) return .{ .help = @field(std.meta.Tag(Commands), f.name) };
            }
            return .{ .command = @unionInit(Commands, f.name, try parseCommand(f.type, rest, diag)) };
        }
    }
    return diag.set("unknown command '{s}'", .{first});
}

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

fn positionalNames(comptime T: type) []const []const u8 {
    if (!@hasDecl(T, "positionals")) return &.{};
    comptime var names: []const []const u8 = &.{};
    inline for (T.positionals) |p| names = names ++ .{@as([]const u8, p)};
    return names;
}

fn isPositional(comptime T: type, comptime name: []const u8) bool {
    inline for (comptime positionalNames(T)) |p| {
        if (comptime std.mem.eql(u8, p, name)) return true;
    }
    return false;
}

fn parseCommand(comptime T: type, argv: []const []const u8, diag: *Diagnostic) error{Usage}!T {
    const fields = @typeInfo(T).@"struct".fields;
    const positionals = comptime positionalNames(T);
    comptime for (fields) |f| {
        if (f.defaultValue() == null and !isPositional(T, f.name))
            @compileError(@typeName(T) ++ "." ++ f.name ++ ": options need a default value");
    };

    var result: T = undefined;
    var seen = [_]bool{false} ** fields.len;
    inline for (fields) |f| {
        if (f.defaultValue()) |d| @field(result, f.name) = d;
    }

    var next_positional: usize = 0;
    var only_positionals = false;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (!only_positionals and std.mem.eql(u8, arg, "--")) {
            only_positionals = true;
            continue;
        }
        if (!only_positionals and arg.len > 1 and arg[0] == '-') {
            if (!std.mem.startsWith(u8, arg, "--")) return diag.set("unknown option '{s}'", .{arg});
            const eq = std.mem.indexOfScalar(u8, arg, '=');
            const name = arg[2 .. eq orelse arg.len];
            const inline_value: ?[]const u8 = if (eq) |e| arg[e + 1 ..] else null;
            var matched = false;
            inline for (fields, 0..) |f, fi| {
                if (comptime isPositional(T, f.name)) continue;
                if (std.mem.eql(u8, name, comptime optionName(f.name)[0..])) {
                    matched = true;
                    seen[fi] = true;
                    if (f.type == bool) {
                        if (inline_value != null) return diag.set("option '--{s}' takes no value", .{name});
                        @field(result, f.name) = true;
                    } else {
                        const value = inline_value orelse blk: {
                            i += 1;
                            if (i >= argv.len) return diag.set("option '--{s}' needs a value", .{name});
                            break :blk argv[i];
                        };
                        @field(result, f.name) = try parseValue(f.type, name, value, diag);
                    }
                }
            }
            if (!matched) return diag.set("unknown option '--{s}'", .{name});
            continue;
        }
        if (next_positional >= positionals.len) return diag.set("unexpected argument '{s}'", .{arg});
        inline for (positionals, 0..) |p, pi| {
            if (pi == next_positional) {
                const fi = comptime std.meta.fieldIndex(T, p) orelse @compileError("no field " ++ p);
                seen[fi] = true;
                @field(result, p) = try parseValue(fields[fi].type, p, arg, diag);
            }
        }
        next_positional += 1;
    }

    inline for (fields, 0..) |f, fi| {
        if (f.defaultValue() == null and !seen[fi]) return diag.set("missing argument <{s}>", .{f.name});
    }
    return result;
}

fn parseValue(comptime V: type, name: []const u8, value: []const u8, diag: *Diagnostic) error{Usage}!V {
    switch (@typeInfo(V)) {
        .optional => |o| return try parseValue(o.child, name, value, diag),
        .@"enum" => {
            inline for (@typeInfo(V).@"enum".fields) |ef| {
                if (std.mem.eql(u8, value, ef.name)) return @enumFromInt(ef.value);
            }
            return diag.set("invalid value '{s}' for {s} (expected {s})", .{ value, name, comptime enumChoices(V) });
        },
        else => {
            if (V != []const u8) @compileError("unsupported option type " ++ @typeName(V));
            return value;
        },
    }
}

/// `no_install` → `no-install` (comptime).
fn optionName(comptime field: []const u8) *const [field.len]u8 {
    comptime {
        var out: [field.len]u8 = field[0..field.len].*;
        std.mem.replaceScalar(u8, &out, '_', '-');
        const final = out;
        return &final;
    }
}

fn enumChoices(comptime E: type) []const u8 {
    comptime {
        var s: []const u8 = "";
        for (@typeInfo(E).@"enum".fields, 0..) |ef, i| s = s ++ (if (i == 0) "" else "|") ++ ef.name;
        return s;
    }
}

/// `<react|vue>` for enums; else from `T.values` (`.oriel_path = "dir"`)
/// or the option name.
fn valueName(comptime T: type, comptime V: type, comptime field: []const u8) []const u8 {
    return switch (@typeInfo(V)) {
        .optional => |o| valueName(T, o.child, field),
        .@"enum" => "<" ++ enumChoices(V) ++ ">",
        else => if (@hasDecl(T, "values") and @hasField(@TypeOf(T.values), field))
            "<" ++ @field(T.values, field) ++ ">"
        else
            "<" ++ optionName(field) ++ ">",
    };
}

fn fieldHelp(comptime T: type, comptime name: []const u8) []const u8 {
    if (@hasDecl(T, "help") and @hasField(@TypeOf(T.help), name)) return @field(T.help, name);
    return "";
}

/// Default shown in help, if the option has a meaningful one.
fn defaultText(comptime f: std.builtin.Type.StructField) ?[]const u8 {
    const d = f.defaultValue() orelse return null;
    return switch (@typeInfo(f.type)) {
        .@"enum" => @tagName(d),
        else => null,
    };
}

/// Usage and option lines of a command, e.g. `--template <react|vue>`.
fn commandLeft(comptime T: type, comptime f: std.builtin.Type.StructField) []const u8 {
    if (isPositional(T, f.name)) return "<" ++ f.name ++ ">";
    if (f.type == bool) return "--" ++ optionName(f.name);
    return "--" ++ optionName(f.name) ++ " " ++ valueName(T, f.type, f.name);
}

fn pad(comptime width: usize, comptime s: []const u8) []const u8 {
    return s ++ (" " ** (width - s.len));
}

/// Top-level help: every command with its summary.
pub fn writeHelp(comptime Commands: type, comptime program: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const fields = @typeInfo(Commands).@"union".fields;
    const width = comptime blk: {
        var n: usize = 0;
        for (fields) |f| n = @max(n, f.name.len);
        break :blk n + 3;
    };
    try w.writeAll("Usage: " ++ program ++ " <command> [options]\n\nCommands:\n");
    inline for (fields) |f| {
        try w.writeAll(comptime "  " ++ pad(width, optionName(f.name)) ++ f.type.summary ++ "\n");
    }
    try w.writeAll("\nOptions:\n" ++
        "  -h, --help     Show help (also: " ++ program ++ " <command> --help)\n" ++
        "  -V, --version  Show the version\n");
}

/// Help for one command: usage line, arguments and options.
pub fn writeCommandHelp(comptime Commands: type, comptime program: []const u8, tag: std.meta.Tag(Commands), w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (tag) {
        inline else => |t| {
            const T = @FieldType(Commands, @tagName(t));
            const name = comptime optionName(@tagName(t));
            const fields = @typeInfo(T).@"struct".fields;
            if (@hasDecl(T, "forward")) {
                try w.writeAll(comptime "Usage: " ++ program ++ " " ++ name ++ " [args...]\n\n" ++ T.summary ++ "\n" ++
                    (if (@hasDecl(T, "details")) "\n" ++ T.details ++ "\n" else ""));
                return;
            }
            const usage = comptime blk: {
                var s: []const u8 = "Usage: " ++ program ++ " " ++ name;
                for (positionalNames(T)) |p| s = s ++ " <" ++ p ++ ">";
                if (fields.len > positionalNames(T).len) s = s ++ " [options]";
                break :blk s;
            };
            const width = comptime blk: {
                var n: usize = "-h, --help".len;
                for (fields) |f| n = @max(n, commandLeft(T, f).len);
                break :blk n + 3;
            };
            const body = comptime blk: {
                var args: []const u8 = "";
                var opts: []const u8 = "";
                for (fields) |f| {
                    var text: []const u8 = fieldHelp(T, f.name);
                    if (defaultText(f)) |d| text = text ++ (if (text.len > 0) " " else "") ++ "(default: " ++ d ++ ")";
                    const line = "  " ++ (if (text.len > 0) pad(width, commandLeft(T, f)) ++ text else commandLeft(T, f));
                    if (isPositional(T, f.name)) args = args ++ line ++ "\n" else opts = opts ++ line ++ "\n";
                }
                opts = opts ++ "  " ++ pad(width, "-h, --help") ++ "Show this help\n";
                break :blk (if (args.len > 0) "\nArguments:\n" ++ args else "") ++ "\nOptions:\n" ++ opts;
            };
            try w.writeAll(usage ++ "\n\n" ++ T.summary ++ "\n" ++ body ++
                (if (@hasDecl(T, "details")) "\n" ++ T.details ++ "\n" else ""));
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestCommands = union(enum) {
    init: struct {
        pub const summary = "Create an app";
        pub const positionals = .{"name"};
        pub const help = .{ .name = "App name", .template = "Frontend", .no_install = "Skip npm" };
        pub const values = .{ .id = "app-id" };
        name: []const u8,
        template: enum { react, vanilla } = .react,
        id: ?[]const u8 = null,
        no_install: bool = false,
    },
    doctor: struct {
        pub const summary = "Check the system";
    },
    build: struct {
        pub const summary = "Run zig build";
        pub const forward = "args";
        args: []const []const u8 = &.{},
    },
};

fn testParse(argv: []const []const u8) !Result(TestCommands) {
    var diag: Diagnostic = .{};
    return parse(TestCommands, argv, &diag);
}

fn testError(argv: []const []const u8, expected: []const u8) !void {
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.Usage, parse(TestCommands, argv, &diag));
    try std.testing.expectEqualStrings(expected, diag.message());
}

test "parse: options, positionals and defaults" {
    const r = try testParse(&.{ "init", "--template", "vanilla", "demo", "--id=com.example.Demo", "--no-install" });
    const init = r.command.init;
    try std.testing.expectEqualStrings("demo", init.name);
    try std.testing.expectEqual(.vanilla, init.template);
    try std.testing.expectEqualStrings("com.example.Demo", init.id.?);
    try std.testing.expect(init.no_install);

    const d = (try testParse(&.{ "init", "app" })).command.init;
    try std.testing.expectEqual(.react, d.template);
    try std.testing.expectEqual(null, d.id);
    try std.testing.expect(!d.no_install);

    // After `--`, dashes are positional.
    const dash = (try testParse(&.{ "init", "--", "-odd" })).command.init;
    try std.testing.expectEqualStrings("-odd", dash.name);
}

test "parse: help, version, forwarding" {
    try std.testing.expectEqual(null, (try testParse(&.{})).help);
    try std.testing.expectEqual(null, (try testParse(&.{"--help"})).help);
    try std.testing.expectEqual(.init, (try testParse(&.{ "init", "x", "-h" })).help.?);
    try std.testing.expectEqual(.doctor, (try testParse(&.{ "help", "doctor" })).help.?);
    try std.testing.expectEqual(.package, (try testParse(&.{ "package", "--help" })).help.?);
    try std.testing.expectEqual(.version, try testParse(&.{"--version"}));

    const b = (try testParse(&.{ "build", "-Doptimize=ReleaseFast", "--help", "--", "x" })).command.build;
    try std.testing.expectEqual(4, b.args.len);
    try std.testing.expectEqualStrings("--help", b.args[1]);
    try std.testing.expectEqual(0, (try testParse(&.{"build"})).command.build.args.len);
}

test "parse: errors" {
    try testError(&.{"frob"}, "unknown command 'frob'");
    try testError(&.{"--frob"}, "unknown option '--frob'");
    try testError(&.{"init"}, "missing argument <name>");
    try testError(&.{ "init", "a", "b" }, "unexpected argument 'b'");
    try testError(&.{ "init", "a", "--bogus" }, "unknown option '--bogus'");
    try testError(&.{ "init", "a", "-x" }, "unknown option '-x'");
    try testError(&.{ "init", "a", "--id" }, "option '--id' needs a value");
    try testError(&.{ "init", "a", "--no-install=yes" }, "option '--no-install' takes no value");
    try testError(&.{ "init", "a", "--template", "angular" }, "invalid value 'angular' for template (expected react|vanilla)");
    try testError(&.{ "help", "frob" }, "unknown command 'frob'");
    try testError(&.{"x" ** 300}, "invalid argument (too long to show)");
}

test "generated help" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeHelp(TestCommands, "oriel", &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "  init     Create an app\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "  doctor   Check the system\n") != null);

    out.clearRetainingCapacity();
    try writeCommandHelp(TestCommands, "oriel", .init, &out.writer);
    try std.testing.expectEqualStrings(
        \\Usage: oriel init <name> [options]
        \\
        \\Create an app
        \\
        \\Arguments:
        \\  <name>                       App name
        \\
        \\Options:
        \\  --template <react|vanilla>   Frontend (default: react)
        \\  --id <app-id>
        \\  --no-install                 Skip npm
        \\  -h, --help                   Show this help
        \\
    , out.written());

    out.clearRetainingCapacity();
    try writeCommandHelp(TestCommands, "oriel", .build, &out.writer);
    try std.testing.expectEqualStrings("Usage: oriel build [args...]\n\nRun zig build\n", out.written());
}
