//! The feature flags as this build resolved them for its target, for the
//! page: `window.oriel.features` (`{ tray: false, fsWatch: true, ... }`), so
//! a UI hides what this build can't do. A module missing on the target is
//! false here, like `oriel.<module>.available` (docs/modules.md,
//! "Availability").

const std = @import("std");
const options = @import("build_options");

/// `Object.freeze({ tray: true, mediaServer: false, ... })`, for the bridges.
pub const js = blk: {
    var out: []const u8 = "Object.freeze({";
    for (options.feature_names, 0..) |name, i| {
        out = out ++ (if (i == 0) " " else ", ") ++ camel(name) ++ ": " ++ (if (@field(options, name)) "true" else "false");
    }
    break :blk out ++ " })";
};

/// The same as a JSON object, for the native renderer.
pub const json = blk: {
    var out: []const u8 = "{";
    for (options.feature_names, 0..) |name, i| {
        out = out ++ (if (i == 0) "" else ",") ++ "\"" ++ camel(name) ++ "\":" ++ (if (@field(options, name)) "true" else "false");
    }
    break :blk out ++ "}";
};

/// The TypeScript interface (src/core/ipc.zig's generated bindings).
pub const typescript = blk: {
    var out: []const u8 = "export interface Features {\n";
    for (options.feature_names) |name| out = out ++ "  " ++ camel(name) ++ ": boolean;\n";
    break :blk out ++ "}\n";
};

/// `media_server` -> `mediaServer`.
fn camel(comptime name: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        var upper = false;
        for (name) |c| {
            if (c == '_') {
                upper = true;
            } else {
                out = out ++ &[_]u8{if (upper) std.ascii.toUpper(c) else c};
                upper = false;
            }
        }
        return out;
    }
}

/// `target.platform_json` with `features` added, for the native renderer
/// (src/native_ui/js/src/main.js takes it out again).
pub const platform_json: [:0]const u8 = withPlatform(@import("target.zig").platform_json);

fn withPlatform(comptime platform: []const u8) [:0]const u8 {
    std.debug.assert(platform[platform.len - 1] == '}');
    return std.fmt.comptimePrint("{s},\"features\":{s}}}", .{ platform[0 .. platform.len - 1], json });
}

test camel {
    try std.testing.expectEqualStrings("mediaServer", comptime camel("media_server"));
    try std.testing.expectEqualStrings("tray", comptime camel("tray"));
    try std.testing.expectEqualStrings("llamaMtmd", comptime camel("llama_mtmd"));
}

test "the page's table follows the build's flags" {
    try std.testing.expect(std.mem.indexOf(u8, js, "tray: " ++ (if (options.tray) "true" else "false")) != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "fsWatch: " ++ (if (options.fs_watch) "true" else "false")) != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"mediaServer\":" ++ (if (options.media_server) "true" else "false")) != null);
    try std.testing.expect(std.mem.indexOf(u8, typescript, "  nativeUi: boolean;\n") != null);
    const p = comptime withPlatform("{\"os\":\"linux\"}");
    try std.testing.expect(std.mem.startsWith(u8, p, "{\"os\":\"linux\",\"features\":{"));
    try std.testing.expect(std.mem.endsWith(u8, platform_json, "}}"));
}
