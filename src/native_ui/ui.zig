//! Experimental typed .oriel templates. Compiled once; stable IDs retain
//! nodes. Dynamic text is owned by Tree, never borrowed from a frame buffer.
const std = @import("std");
const tree = @import("tree.zig");
const engine = @import("engine_zig.zig");
const markup = @import("oriel_markup.zig");
pub const available = true;
pub const Engine = engine.Engine;
pub const Driver = engine.Driver;
pub const Program = @import("zig_canvas.zig").Program;
pub const Props = tree.Props;
pub const Dim = tree.Dim;
pub const Color = tree.Color;
pub const Binding = struct { name: []const u8, value: []const u8 };

pub fn configure(driver: Driver) void {
    engine.configured_driver = driver;
}

pub fn View(comptime source: []const u8) type {
    const plan = comptime markup.parse(source);
    return struct {
        pub const node_count = plan.len;
        pub fn id(comptime name: []const u8, base: i64) i64 {
            inline for (plan.nodes[0..plan.len], 0..) |n, i| {
                if (comptime std.mem.eql(u8, n.name, name)) return base + @as(i64, i);
            }
            @compileError("Unknown .oriel node id: " ++ name);
        }
        pub fn prepare(t: *tree.Tree, style_base: i64) !void {
            @setEvalBranchQuota(1000000);
            inline for (plan.nodes[0..plan.len], 0..) |n, i| {
                const props = comptime blk: {
                    var p = n.props;
                    if (n.kind == .button) p.runs = &.{.{ .t = p.val orelse "", .sz = p.fz orelse 14, .w = p.fwt orelse 400, .ff = p.ff, .mono = p.mono, .lh = p.lh, .c = p.col orelse .{ 230, 232, 236, 1 } }};
                    if (n.kind == .text) p.runs = &.{.{ .t = "", .sz = p.fz orelse 14, .w = p.fwt orelse 400, .ff = p.ff, .mono = p.mono, .lh = p.lh, .c = p.col orelse .{ 230, 232, 236, 1 } }};
                    break :blk p;
                };
                try t.defineStaticStyle(style_base + @as(i64, i), props);
            }
        }
        pub fn mount(t: *tree.Tree, base: i64, style_base: i64, bindings: []const Binding) !i64 {
            @setEvalBranchQuota(1000000);
            // Call prepare outside a timed construction loop.
            inline for (plan.nodes[0..plan.len], 0..) |n, i| {
                if (n.kind == .text) _ = try resolve(n.text, bindings);
                if (t.get(base + @as(i64, i))) |existing| {
                    if (existing.kind != n.kind or existing.leaf_style != style_base + @as(i64, i)) return error.IdentityChanged;
                }
            }
            inline for (plan.nodes[0..plan.len], 0..) |n, i| {
                const node_id = base + @as(i64, i);
                const style_id = style_base + @as(i64, i);
                const text = if (n.kind == .text) try resolve(n.text, bindings) else "";
                if (t.get(node_id)) |existing| {
                    if (existing.kind != n.kind or existing.leaf_style != style_id) return error.IdentityChanged;
                    if (n.kind == .text and !try t.updateText(node_id, text)) return error.InvalidTextNode;
                } else if (n.kind != .view and n.kind != .text) {
                    try t.createUiNode(node_id, n.kind, style_id);
                } else if (!try t.createLeaf(node_id, n.kind, style_id, text)) return error.InvalidTemplate;
                // The template owns its native subtree. Removing a view
                // must destroy its children, rather than leave detached
                // records that a later build could accidentally reuse.
                t.get(node_id).?.stamp_owned = true;
            }
            inline for (plan.nodes[0..plan.len], 0..) |_, i| {
                const children = comptime blk: {
                    var indices: [plan.len]usize = undefined;
                    var count: usize = 0;
                    for (plan.nodes[0..plan.len], 0..) |child, j| {
                        if (child.parent == i) {
                            indices[count] = j;
                            count += 1;
                        }
                    }
                    break :blk indices[0..count].*;
                };
                var ids: [children.len]i64 = undefined;
                inline for (children, 0..) |j, at| ids[at] = base + @as(i64, j);
                if (children.len > 0 and !try t.stampKids(base + @as(i64, i), &ids)) return error.InvalidTemplate;
            }
            return base;
        }
    };
}

/// Uses the existing platform command pool. Arguments are copied by the
/// backend before returning; completion retains request identity and status.
pub fn invoke(e: *Engine, id: u32, command: []const u8, args: anytype) !void {
    const json = try std.json.Stringify.valueAlloc(e.gpa, args, .{});
    defer e.gpa.free(json);
    e.backend.invoke(e.backend.ctx, e, id, command, json);
}

fn resolve(text: []const u8, bindings: []const Binding) ![]const u8 {
    if (text.len < 2 or text[0] != '{' or text[text.len - 1] != '}') return text;
    const name = text[1 .. text.len - 1];
    for (bindings) |b| if (std.mem.eql(u8, b.name, name)) return b.value;
    return error.MissingBinding;
}

test "template bindings are explicit" {
    try std.testing.expectEqualStrings("hello", try resolve("{title}", &.{.{ .name = "title", .value = "hello" }}));
    try std.testing.expectError(error.MissingBinding, resolve("{missing}", &.{}));
}

test ".oriel mounts own text, retain identity and preserve keyed rows when reordered" {
    const measure = struct {
        fn f(_: *anyopaque, _: *tree.Node, _: f32, out: *[2]f32) void {
            out.* = .{ 40, 18 };
        }
    }.f;
    var ctx: u8 = 0;
    var t = tree.Tree.init(std.testing.allocator, &ctx, measure);
    defer t.deinit();
    const V = View("<row id=\"row\"><text id=\"title\">{title}</text></row>");
    const Root = View("<column />");
    try V.prepare(&t, 10);
    try Root.prepare(&t, 20);
    _ = try Root.mount(&t, 1, 20, &.{});
    _ = try V.mount(&t, 100, 10, &.{.{ .name = "title", .value = "first" }});
    _ = try V.mount(&t, 200, 10, &.{.{ .name = "title", .value = "second" }});
    try std.testing.expect(try t.stampKids(1, &.{ 100, 200 }));
    const row = t.get(100).?;
    const text = t.get(V.id("title", 100)).?;
    row.scroll_y = 17;
    var bytes = [_]u8{ 'n', 'e', 'w' };
    _ = try V.mount(&t, 100, 10, &.{.{ .name = "title", .value = &bytes }});
    @memset(&bytes, 'x');
    try std.testing.expectEqualStrings("new", text.props.runs.?[0].t);
    try std.testing.expect(row == t.get(100).?);
    try std.testing.expectEqual(@as(f32, 17), row.scroll_y);
    try std.testing.expect(try t.stampKids(1, &.{ 200, 100 }));
    try std.testing.expect(t.get(1).?.kids.items[1] == row);
    try std.testing.expectError(error.MissingBinding, V.mount(&t, 300, 10, &.{}));
    try std.testing.expect(t.get(300) == null);
    t.destroy(1);
    try std.testing.expectEqual(@as(usize, 0), t.nodes.count());
}

test "typed controls own dynamic values and retain template identity" {
    const measure = struct {
        fn f(_: *anyopaque, _: *tree.Node, _: f32, out: *[2]f32) void {
            out.* = .{ 40, 18 };
        }
    }.f;
    var ctx: u8 = 0;
    var t = tree.Tree.init(std.testing.allocator, &ctx, measure);
    defer t.deinit();
    const V = View("<column scroll=\"true\"><input id=\"search\" value=\"initial\" placeholder=\"Search\" /><control id=\"pause\" value=\"Pause\" /></column>");
    try V.prepare(&t, 10);
    _ = try V.mount(&t, 100, 10, &.{});
    const input = t.get(V.id("search", 100)).?;
    try std.testing.expectEqualStrings("initial", input.pending_value.?);
    var props = input.props;
    var value = [_]u8{ 'n', 'e', 'w' };
    props.val = &value;
    try t.updateUiProps(input.id, props);
    @memset(&value, 'x');
    try std.testing.expectEqualStrings("new", input.props.val.?);
    try t.acceptUiValue(input.id, "typed");
    try std.testing.expectEqualStrings("typed", input.props.val.?);
    try std.testing.expect(input.pending_value == null);
    _ = try V.mount(&t, 100, 10, &.{});
    try std.testing.expect(input == t.get(V.id("search", 100)).?);
    try std.testing.expectEqualStrings("typed", input.props.val.?);
    try std.testing.expectEqualStrings("Pause", t.get(V.id("pause", 100)).?.props.runs.?[0].t);
    t.root = t.get(100);
    t.width = 500;
    t.height = 300;
    t.layout();
    const Parent = View("<column />");
    try Parent.prepare(&t, 20);
    _ = try Parent.mount(&t, 200, 20, &.{});
    t.get(100).?.stamp_owned = false;
    try std.testing.expect(try t.stampKids(200, &.{100}));
    t.root = t.get(200);
    t.layout();
    try std.testing.expect(input.frame.w > 0);
    try std.testing.expect(try t.stampKids(200, &.{}));
    try std.testing.expect(t.needsLayout());
    t.layout();
    try std.testing.expect(try t.stampKids(200, &.{}));
    try std.testing.expect(!t.needsLayout());
    try std.testing.expectEqual(@as(f32, 0), input.frame.w);
    try std.testing.expectEqual(@as(f32, 0), input.clip.w);
    props = input.props;
    props.val = "";
    try t.updateUiProps(input.id, props);
    try std.testing.expectEqualStrings("", input.props.val.?);
    try std.testing.expect(input.ui_value == null);
}
