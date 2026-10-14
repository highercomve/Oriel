//! `zig build check-views -Dviews=<dir>`: the views an export wrote
//! (ORIEL_NUI_EXPORT), compiled and mounted as an app would, node by node
//! against the props the native renderer had computed from the page. Any
//! difference is reported and fails the step: a view that passes draws as
//! the page did on the same renderer.
const std = @import("std");
const ui = @import("oriel").ui;
const views = @import("views");

fn measure(_: *anyopaque, _: *ui.Node, _: f32, out: *[2]f32) void {
    out.* = .{ 40, 18 };
}

const Header = struct {
    controls: struct { check: bool = true, button: bool = true } = .{},
    width: f32 = 800,
    dark: bool = false,
    /// The app's states the variant was exported in (its @when block's).
    states: []const []const u8 = &.{},
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &out_buf);
    const out = &stdout.interface;
    var failed: usize = 0;
    inline for (views.list) |v| {
        failed += try check(gpa, out, v[0], v[1], v[2]);
    }
    try out.flush();
    if (failed > 0) {
        try out.print("{d} node(s) differ\n", .{failed});
        try out.flush();
        std.process.exit(1);
    }
}

fn check(gpa: std.mem.Allocator, out: *std.Io.Writer, comptime name: []const u8, comptime source: []const u8, expected: []const u8) !usize {
    @setEvalBranchQuota(100000000);
    const View = ui.View(source);
    var ctx: u8 = 0;
    var t = ui.Tree.init(gpa, &ctx, measure);
    defer t.deinit();
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, expected, "\n"), '\n');
    const header = try std.json.parseFromSlice(Header, gpa, lines.next() orelse return error.EmptyExport, .{ .ignore_unknown_fields = true });
    defer header.deinit();
    t.controls = .{ .check = header.value.controls.check, .button = header.value.controls.button };
    t.width = header.value.width;
    t.dark = header.value.dark;
    try View.prepare(&t, 1_000_000);
    // A view edited by hand: its {bindings} show their own names, as the
    // page they were written over did.
    var bindings: [View.binding_names.len]ui.Binding = undefined;
    inline for (View.binding_names, 0..) |b, i| bindings[i] = .{ .name = b, .value = "{" ++ b ++ "}" };
    _ = try View.mount(&t, 1, 1_000_000, &bindings);
    // A state that changed nothing has no block: nothing to turn on. The
    // focus and hover variants are every node at once (as exported).
    for (header.value.states) |state| {
        if (std.mem.eql(u8, state, "focus") or std.mem.eql(u8, state, "hover")) {
            var all: std.ArrayList(*ui.Node) = .empty;
            defer all.deinit(gpa);
            try preorder(gpa, &all, t.get(1).?, 0);
            if (std.mem.eql(u8, state, "hover")) {
                // Every node under the pointer at once, as exported.
                var ids: std.ArrayList(i64) = .empty;
                defer ids.deinit(gpa);
                for (all.items) |n| try ids.append(gpa, n.id);
                try t.setHovered(ids.items);
            } else for (all.items) |n| {
                _ = try t.focusLook(n.id, true);
            }
            continue;
        }
        View.setStateNamed(&t, 1, state, true) catch |err| switch (err) {
            error.UnknownState, error.UnknownNode => {},
            else => return err,
        };
    }
    t.root = t.get(1);
    t.height = 800;
    t.layout();

    var nodes: std.ArrayList(*ui.Node) = .empty;
    defer nodes.deinit(gpa);
    try preorder(gpa, &nodes, t.get(1).?, 0);
    var failed: usize = 0;
    var i: usize = 0;
    while (lines.next()) |want| : (i += 1) {
        if (i >= nodes.items.len) {
            try out.print("{s}: the view has {d} nodes, the page {d}+\n", .{ name, nodes.items.len, i + 1 });
            return failed + 1;
        }
        var got: std.Io.Writer.Allocating = .init(gpa);
        defer got.deinit();
        try ui.exporter.nodeJson(gpa, nodes.items[i], &got.writer);
        if (std.mem.eql(u8, got.written(), want)) continue;
        failed += 1;
        try out.print("{s}: node {d} ({s}) differs:\n", .{ name, i, @tagName(nodes.items[i].kind) });
        try diff(gpa, out, want, got.written());
    }
    if (i != nodes.items.len) {
        try out.print("{s}: the view has {d} nodes, the page {d}\n", .{ name, nodes.items.len, i });
        failed += 1;
    }
    if (failed == 0) try out.print("{s}: {d} nodes, same props\n", .{ name, i });
    return failed;
}

/// The nodes in the view's order, as the page had them: one this variant
/// doesn't show (display=none) isn't in the page's tree.
fn preorder(gpa: std.mem.Allocator, list: *std.ArrayList(*ui.Node), n: *ui.Node, depth: usize) !void {
    if (depth > 512) return error.TooDeep;
    if (n.props.none) return;
    try list.append(gpa, n);
    if (n.kind == .text or n.kind == .select or n.kind == .icon or n.kind == .button) return;
    for (n.kids.items) |k| try preorder(gpa, list, k, depth + 1);
}

/// The fields that differ, page's value then view's.
fn diff(gpa: std.mem.Allocator, out: *std.Io.Writer, want: []const u8, got: []const u8) !void {
    const a = try std.json.parseFromSlice(std.json.Value, gpa, want, .{});
    defer a.deinit();
    const b = try std.json.parseFromSlice(std.json.Value, gpa, got, .{});
    defer b.deinit();
    if (!std.mem.eql(u8, a.value.object.get("kind").?.string, b.value.object.get("kind").?.string)) {
        try out.print("  kind: page {s}, view {s}\n", .{ a.value.object.get("kind").?.string, b.value.object.get("kind").?.string });
    }
    const pa = a.value.object.get("props").?.object;
    const pb = b.value.object.get("props").?.object;
    var keys = pa.iterator();
    while (keys.next()) |e| {
        const other = pb.get(e.key_ptr.*);
        const sa = try std.json.Stringify.valueAlloc(gpa, e.value_ptr.*, .{});
        defer gpa.free(sa);
        const sb = if (other) |o| try std.json.Stringify.valueAlloc(gpa, o, .{}) else try gpa.dupe(u8, "(none)");
        defer gpa.free(sb);
        if (!std.mem.eql(u8, sa, sb)) try out.print("  {s}: page {s}\n  {s}  view {s}\n", .{ e.key_ptr.*, sa, " " ** 0, sb });
    }
    var extra = pb.iterator();
    while (extra.next()) |e| if (pa.get(e.key_ptr.*) == null) {
        const sb = try std.json.Stringify.valueAlloc(gpa, e.value_ptr.*, .{});
        defer gpa.free(sb);
        try out.print("  {s}: page (none)\n    view {s}\n", .{ e.key_ptr.*, sb });
    };
}
