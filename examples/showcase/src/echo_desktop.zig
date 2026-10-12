//! The "showcase.echo" app extension on the desktop (build.zig,
//! `.extensions`): the contract android/EchoExtension.kt and
//! ios/EchoExtension.m implement too. `reverse` takes `{"text": "..."}`,
//! answers `{"text": <reversed>, "platform", "device"}` and emits it as the
//! `reversed` event.

const std = @import("std");
const builtin = @import("builtin");
const oriel = @import("oriel");

pub fn call(ctx: *oriel.extensions.Context, method: []const u8, input: []const u8) ![]u8 {
    if (!std.mem.eql(u8, method, "reverse")) return ctx.fail("unknown_method", "showcase.echo has no method {s}", .{method});
    const args = std.json.parseFromSliceLeaky(struct { text: []const u8 }, ctx.arena, input, .{ .ignore_unknown_fields = true }) catch
        return ctx.fail("bad_input", "expected {{\"text\": \"...\"}}", .{});
    const reversed = try reverseCodepoints(ctx.arena, args.text);
    const device = oriel.system.deviceName(ctx.arena) catch "this computer";
    const reply = try std.json.Stringify.valueAlloc(ctx.arena, .{
        .text = reversed,
        .platform = "Zig on " ++ @tagName(builtin.os.tag),
        .device = device,
    }, .{});
    ctx.emit("reversed", reply);
    return reply;
}

pub fn onLifecycle(event: oriel.lifecycle.Event) void {
    std.log.info("showcase.echo: lifecycle {s}", .{event.name()});
}

/// `text` reversed by code point (invalid UTF-8 is reversed by byte).
fn reverseCodepoints(arena: std.mem.Allocator, text: []const u8) ![]u8 {
    const out = try arena.alloc(u8, text.len);
    const view = std.unicode.Utf8View.init(text) catch {
        for (text, 0..) |c, i| out[text.len - 1 - i] = c;
        return out;
    };
    var it = view.iterator();
    var end = out.len;
    while (it.nextCodepointSlice()) |cp| {
        end -= cp.len;
        @memcpy(out[end..][0..cp.len], cp);
    }
    return out;
}

test reverseCodepoints {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("cba", try reverseCodepoints(arena.allocator(), "abc"));
    try std.testing.expectEqualStrings("ñé", try reverseCodepoints(arena.allocator(), "éñ"));
}
