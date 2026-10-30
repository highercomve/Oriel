//! Files dropped into a native-renderer page (docs/design/drag-and-drop-design.md,
//! section 3): one table per engine (`Engine.drops`).
//!
//! The table is core/file_handles.zig, shared with oriel.share's received
//! files: read-only descriptors behind u32 handles, with snapshot checks.

const std = @import("std");
const file_handles = @import("../core/file_handles.zig");

pub const DropFiles = file_handles.FileHandles;
pub const Entry = file_handles.Entry;
pub const Error = file_handles.Error;
pub const max_read = file_handles.max_read;

pub fn sendDragLeave(engine: anytype, session: u32) void {
    var buf: [32]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "[\"leave\",{d}]", .{session}) catch return;
    const e = switch (@typeInfo(@TypeOf(engine))) {
        .pointer => |p| switch (@typeInfo(p.child)) {
            .pointer => engine.*,
            else => engine,
        },
        else => engine,
    };
    _ = e.dragEvent(0, json);
}

pub const DragKinds = struct {
    files: bool = false,
    plain: bool = false,
    uri_list: bool = false,
    html: bool = false,

    /// The strings the page sees: none with files, as in Chrome.
    pub fn strings(self: DragKinds) [3]?[]const u8 {
        if (self.files) return .{ null, null, null };
        return .{
            if (self.plain) "text/plain" else null,
            if (self.uri_list) "text/uri-list" else null,
            if (self.html) "text/html" else null,
        };
    }

    /// enter's items: [[kind, type], ...].
    pub fn writeItems(self: DragKinds, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try out.append(gpa, '[');
        var first = true;
        if (self.files) {
            try out.appendSlice(gpa, "[\"file\",\"\"]");
            first = false;
        }
        for (self.strings()) |mime| if (mime) |m| {
            if (!first) try out.append(gpa, ',');
            first = false;
            try out.print(gpa, "[\"string\",\"{s}\"]", .{m});
        };
        try out.append(gpa, ']');
    }
};
