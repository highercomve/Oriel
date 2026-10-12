//! App extensions' names and limits, shared by build.zig (validating
//! `AppOptions.extensions`) and src/core/extensions.zig (`oriel.extensions`).
//! Pure: no `builtin`, no build options.

const std = @import("std");

/// Extensions one app may declare.
pub const max_extensions = 64;
/// The longest extension name ("pantry.vision").
pub const max_name_len = 64;
/// The longest method name a call may carry.
pub const max_method_len = 128;
/// Inputs and replies are capped at this unless the extension sets its own
/// `max_bytes` (at most `max_bytes_limit`).
pub const default_max_bytes = 32 << 20;
pub const max_bytes_limit = 256 << 20;
/// Calls running at once on one extension's workers.
pub const max_concurrency = 8;
/// Calls waiting for a worker, per extension; one more is error.Busy.
pub const queue_capacity = 32;
/// `CallOptions.timeout_ms`: the default and the ceiling.
pub const default_timeout_ms = 30_000;
pub const max_timeout_ms = 10 * 60 * 1000;
/// An event emitted by native code: its name and its data.
pub const max_event_name_len = 64;
pub const max_event_bytes = 1 << 20;
/// The error code and message an implementation fails with.
pub const max_code_len = 64;
pub const max_message_len = 1024;
/// Methods one `expose` may list.
pub const max_exposed_methods = 32;

/// Lowercase dotted words: `[a-z][a-z0-9_]*` joined by single dots, up to
/// `max_name_len` ("pantry.vision", "showcase.echo"). The page's event is
/// `extension:<name>`, and Kotlin and Zig see the same string.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_len) return false;
    var word_start = true;
    for (name) |c| {
        if (c == '.') {
            if (word_start) return false;
            word_start = true;
            continue;
        }
        const ok = if (word_start) (c >= 'a' and c <= 'z') else (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_';
        if (!ok) return false;
        word_start = false;
    }
    return !word_start;
}

/// Names Oriel keeps for its own modules built on extensions
/// ("oriel.system_ai"): an app can't declare or expose them.
pub fn reserved(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "oriel.");
}

/// A fully qualified Java/Kotlin class: dotted identifiers, at least one
/// package ("dev.app.VisionExtension"), up to 256 characters.
pub fn validJavaClass(name: []const u8) bool {
    if (name.len == 0 or name.len > 256) return false;
    var dots: usize = 0;
    var word_start = true;
    for (name) |c| {
        if (c == '.') {
            if (word_start) return false;
            dots += 1;
            word_start = true;
            continue;
        }
        const alpha = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
        if (!(alpha or (!word_start and c >= '0' and c <= '9'))) return false;
        word_start = false;
    }
    return !word_start and dots > 0;
}

/// An Objective-C (or `@objc` Swift) class name: one C identifier, up to 128.
pub fn validObjcClass(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    for (name, 0..) |c, i| {
        const alpha = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
        if (!(alpha or (i > 0 and c >= '0' and c <= '9'))) return false;
    }
    return true;
}

/// A method name: 1..`max_method_len` printable ASCII characters, no
/// quotes or backslashes (it goes into logs and error messages).
pub fn validMethod(method: []const u8) bool {
    if (method.len == 0 or method.len > max_method_len) return false;
    for (method) |c| if (c <= 0x20 or c >= 0x7f or c == '"' or c == '\\') return false;
    return true;
}

/// An event name native code emits: like a method, up to `max_event_name_len`.
pub fn validEventName(name: []const u8) bool {
    return name.len <= max_event_name_len and validMethod(name);
}

test validName {
    try std.testing.expect(validName("pantry.vision"));
    try std.testing.expect(validName("echo"));
    try std.testing.expect(validName("a.b_2.c"));
    try std.testing.expect(!validName(""));
    try std.testing.expect(!validName("Pantry.vision"));
    try std.testing.expect(!validName("pantry..vision"));
    try std.testing.expect(!validName(".vision"));
    try std.testing.expect(!validName("vision."));
    try std.testing.expect(!validName("2d.vision"));
    try std.testing.expect(!validName("pantry.2d"));
    try std.testing.expect(!validName("pantry-vision"));
    try std.testing.expect(!validName("a" ** (max_name_len + 1)));
    try std.testing.expect(validName("a" ** max_name_len));
    try std.testing.expect(validName("oriel.system_ai") and reserved("oriel.system_ai"));
    try std.testing.expect(!reserved("orielx.a") and !reserved("pantry.oriel"));
}

test validJavaClass {
    try std.testing.expect(validJavaClass("dev.ghostpantry.VisionExtension"));
    try std.testing.expect(validJavaClass("a.B$Inner"));
    try std.testing.expect(!validJavaClass("VisionExtension"));
    try std.testing.expect(!validJavaClass("dev..X"));
    try std.testing.expect(!validJavaClass("dev.X."));
    try std.testing.expect(!validJavaClass("dev.1X"));
    try std.testing.expect(!validJavaClass("dev.X()"));
}

test validObjcClass {
    try std.testing.expect(validObjcClass("GPVisionExtension"));
    try std.testing.expect(validObjcClass("_X1"));
    try std.testing.expect(!validObjcClass("1X"));
    try std.testing.expect(!validObjcClass("My.Class"));
    try std.testing.expect(!validObjcClass(""));
}

test validMethod {
    try std.testing.expect(validMethod("detect"));
    try std.testing.expect(validMethod("model/load"));
    try std.testing.expect(!validMethod(""));
    try std.testing.expect(!validMethod("a b"));
    try std.testing.expect(!validMethod("a\"b"));
    try std.testing.expect(!validMethod("x" ** (max_method_len + 1)));
    try std.testing.expect(validEventName("progress"));
    try std.testing.expect(!validEventName("x" ** (max_event_name_len + 1)));
}
