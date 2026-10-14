//! Mutation-only diagnostic: no platform windows, layout or paint.
const std = @import("std");
const ui = @import("oriel").ui;
const Row = ui.View("<row><text>{name}</text><text>CPU <span>{cpu}</span></text><button tooltip=\"{tip}\"><text>Kill</text></button></row>");
const row_count = 1000;
const rounds = 10;
const trials = 7;
const Mode = enum { remount, bindings, json_props, typed_props };

fn measure(_: *anyopaque, _: *ui.Node, _: f32, out: *[2]f32) void {
    out.* = .{ 40, 18 };
}

fn run(io: std.Io, mode: Mode, changed: bool) !f64 {
    var ctx: u8 = 0;
    var tree = ui.Tree.init(std.heap.smp_allocator, &ctx, measure);
    defer tree.deinit();
    try Row.prepare(&tree, 10);
    const initial = [_]ui.Binding{ .{ .name = "name", .value = "process" }, .{ .name = "cpu", .value = "10" }, .{ .name = "tip", .value = "stop process" } };
    for (0..row_count) |i| _ = try Row.mount(&tree, 100 + @as(i64, @intCast(i)) * 10, 10, &initial);
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..rounds) |round| {
        const alternate = changed and round % 2 == 0;
        const bindings = [_]ui.Binding{ .{ .name = "name", .value = if (alternate) "changed" else "process" }, .{ .name = "cpu", .value = if (alternate) "20" else "10" }, .{ .name = "tip", .value = if (alternate) "stop changed" else "stop process" } };
        for (0..row_count) |i| {
            const id = 100 + @as(i64, @intCast(i)) * 10;
            switch (mode) {
                .remount => _ = try Row.mount(&tree, id, 10, &bindings),
                .bindings => try Row.update(&tree, id, &bindings),
                .json_props, .typed_props => {
                    var props = tree.get(id).?.props;
                    props.w = .{ .px = if (alternate) 200 else 100 };
                    if (mode == .typed_props) {
                        try tree.updateUiProps(id, props);
                    } else {
                        const bytes = try std.json.Stringify.valueAlloc(tree.gpa, .{.{ "p", id, props }}, .{ .emit_null_optional_fields = false });
                        defer tree.gpa.free(bytes);
                        try tree.apply(bytes);
                    }
                },
            }
        }
    }
    const elapsed = start.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.toNanoseconds();
    return @as(f64, @floatFromInt(elapsed)) / 1000000;
}

pub fn main(init: std.process.Init) !void {
    std.debug.print("Mutation only; {d} rows x {d} passes, median of {d}; no layout/paint\n", .{ row_count, rounds, trials });
    inline for (.{ false, true }) |changed| {
        var samples: [4][trials]f64 = undefined;
        for (0..trials) |trial| {
            // Rotate execution order to avoid always warming the same path.
            for (0..4) |at| {
                const index = (at + trial) % 4;
                samples[index][trial] = try run(init.io, @enumFromInt(index), changed);
            }
        }
        for (&samples, 0..) |*values, index| {
            std.mem.sort(f64, values, {}, std.sort.asc(f64));
            std.debug.print("{s} {s}: {d:.3} ms\n", .{ if (changed) "changed" else "unchanged", @tagName(@as(Mode, @enumFromInt(index))), values[trials / 2] });
        }
    }
}
