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
pub const Tree = tree.Tree;
pub const Node = tree.Node;
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
                const props = comptime propsOf(n);
                // A push button the platform doesn't host is drawn: a
                // clickable text with its label.
                const drawn_button = comptime blk: {
                    var p = props;
                    p.click = true;
                    break :blk p;
                };
                if (n.kind == .button and !t.controls.button) try t.defineStaticStyle(style_base + @as(i64, i), drawn_button) else try t.defineStaticStyle(style_base + @as(i64, i), props);
            }
        }
        pub fn mount(t: *tree.Tree, base: i64, style_base: i64, bindings: []const Binding) !i64 {
            try validateMount(t, base, style_base, bindings);
            try mountNodes(t, base, style_base, bindings);
            try attachChildren(t, base);
            try mountedBindings(t, base, bindings);
            t.get(base).?.ui_mounted = true;
            return base;
        }

        fn validateMount(t: *tree.Tree, base: i64, style_base: i64, bindings: []const Binding) !void {
            @setEvalBranchQuota(1000000);
            try validateBindings(bindings);
            try validateIds(base, plan.len);
            try validateIds(style_base, plan.len);
            if (t.get(base)) |root| if (root.ui_template) |template| {
                if (template.ptr != source.ptr or template.len != source.len or root.ui_base != base or root.ui_style_base != style_base) return error.IdentityChanged;
            };
            // Call prepare outside a timed construction loop.
            inline for (plan.nodes[0..plan.len], 0..) |n, i| {
                if (n.kind == .text) _ = try resolve(n.text, bindings);
                inline for (n.runs) |r| _ = try resolve(r.t, bindings);
                if (comptime isBinding(n.props.tip)) _ = try resolve(n.props.tip.?, bindings);
                if (comptime isBinding(n.props.al)) _ = try resolve(n.props.al.?, bindings);
                if (t.get(base + @as(i64, i))) |existing| {
                    if (existing.kind != kindOn(t, n.kind) or existing.leaf_style != style_base + @as(i64, i)) return error.IdentityChanged;
                }
            }
        }

        fn mountNodes(t: *tree.Tree, base: i64, style_base: i64, bindings: []const Binding) !void {
            @setEvalBranchQuota(1000000);
            inline for (plan.nodes[0..plan.len], 0..) |n, i| {
                const node_id = base + @as(i64, i);
                const style_id = style_base + @as(i64, i);
                const kind = kindOn(t, n.kind);
                const text = if (n.kind == .text) try resolve(n.text, bindings) else if (n.kind == .button) n.props.val orelse "" else "";
                if (t.get(node_id)) |existing| {
                    if (existing.kind != kind or existing.leaf_style != style_id) return error.IdentityChanged;
                    if (n.kind == .text and n.runs.len == 0 and !try t.updateText(node_id, text)) return error.InvalidTextNode;
                } else if ((kind != .view and kind != .text) or n.runs.len > 0) {
                    try t.createUiNode(node_id, kind, style_id);
                } else if (!try t.createLeaf(node_id, kind, style_id, text)) return error.InvalidTemplate;
                // The template owns its native subtree. Removing a view
                // must destroy its children, rather than leave detached
                // records that a later build could accidentally reuse.
                const current = t.get(node_id).?;
                current.stamp_owned = true;
                current.ui_template = source;
                current.ui_base = base;
                current.ui_style_base = style_base;
                // Scalar edits need no storage. Reserve for dynamic strings,
                // styled spans, focusable controls and responsive variants.
                if (comptime needsStorage(n, i)) try t.reserveUiProps(node_id, tree.default_ui_props_bytes);
            }
        }

        fn attachChildren(t: *tree.Tree, base: i64) !void {
            @setEvalBranchQuota(1000000);
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
        }

        fn mountedBindings(t: *tree.Tree, base: i64, bindings: []const Binding) !void {
            @setEvalBranchQuota(1000000);
            // Text with spans: their bound runs.
            inline for (plan.nodes[0..plan.len], 0..) |n, i| {
                if (comptime hasBoundRun(n.runs)) try setRuns(t, base + @as(i64, i), n.runs, bindings);
            }
            // The media blocks the window matches (a remount keeps the
            // variant it shows).
            if (comptime plan.media_len > 0) {
                var shown: u32 = 0;
                for (t.media_views.items) |v| if (v.base == base) {
                    shown = v.mask;
                };
                shown = try refresh(t, base, shown);
                try t.addMediaView(.{ .base = base, .refresh = refresh, .mask = shown });
            }
            // Bound tooltips and labels.
            inline for (plan.nodes[0..plan.len], 0..) |n, i| {
                if (comptime isBinding(n.props.tip)) try t.setBound(base + @as(i64, i), .tip, try resolve(n.props.tip.?, bindings));
                if (comptime isBinding(n.props.al)) try t.setBound(base + @as(i64, i), .label, try resolve(n.props.al.?, bindings));
            }
            // Accessibility entries last: a name can come from the text
            // the bindings just set.
            inline for (plan.nodes[0..plan.len], 0..) |n, i| {
                if (comptime n.ax) |spec| try setAx(t, base + @as(i64, i), spec);
                if (comptime n.kind == .check or n.kind == .button) if (drawnAx(t, n)) |spec| try setAx(t, base + @as(i64, i), spec);
            }
        }

        fn needsStorage(comptime n: markup.Spec, comptime i: usize) bool {
            return n.kind != .view and n.kind != .text or n.ax != null or hasBoundRun(n.runs) or styledFields(i).len > 0 or runsChange(i);
        }

        /// Update a mounted view's bindings without walking its static
        /// structure. Missing bindings/nodes are checked before any edits.
        pub fn update(t: *tree.Tree, base: i64, bindings: []const Binding) !void {
            @setEvalBranchQuota(1000000);
            try validateBindings(bindings);
            try validateIds(base, plan.len);
            const root = t.get(base) orelse return error.UnknownNode;
            const template = root.ui_template orelse return error.IdentityChanged;
            if (!root.ui_mounted or template.ptr != source.ptr or template.len != source.len or root.ui_base != base or root.kind != kindOn(t, plan.nodes[0].kind)) return error.IdentityChanged;
            try validateIds(root.ui_style_base, plan.len);
            inline for (plan.nodes[0..plan.len], 0..) |n, i| {
                if (comptime boundNode(n)) {
                    const current = t.get(base + @as(i64, i)) orelse return error.UnknownNode;
                    if (current.kind != kindOn(t, n.kind) or current.ui_base != base or current.leaf_style != root.ui_style_base + @as(i64, i)) return error.IdentityChanged;
                    const node_template = current.ui_template orelse return error.IdentityChanged;
                    if (node_template.ptr != source.ptr or node_template.len != source.len) return error.IdentityChanged;
                    if (comptime n.kind == .text) {
                        const runs = current.props.runs orelse return error.InvalidTextNode;
                        const expected = if (n.runs.len > 0) n.runs.len else 1;
                        if (runs.len != expected) return error.InvalidTextNode;
                    }
                    if (comptime isBinding(n.text)) _ = try resolve(n.text, bindings);
                    inline for (n.runs) |r| if (comptime isBinding(r.t)) {
                        _ = try resolve(r.t, bindings);
                    };
                    if (comptime isBinding(n.props.tip)) _ = try resolve(n.props.tip.?, bindings);
                    if (comptime isBinding(n.props.al)) _ = try resolve(n.props.al.?, bindings);
                }
            }
            inline for (plan.nodes[0..plan.len], 0..) |n, i| {
                const node_id = base + @as(i64, i);
                if (comptime n.kind == .text and n.runs.len == 0 and isBinding(n.text)) {
                    if (!try t.updateText(node_id, try resolve(n.text, bindings))) return error.InvalidTextNode;
                }
                if (comptime hasBoundRun(n.runs)) try setRuns(t, node_id, n.runs, bindings);
                if (comptime isBinding(n.props.tip)) try t.setBound(node_id, .tip, try resolve(n.props.tip.?, bindings));
                if (comptime isBinding(n.props.al)) try t.setBound(node_id, .label, try resolve(n.props.al.?, bindings));
            }
            // Names derived from descendant text must see all edited runs.
            inline for (plan.nodes[0..plan.len], 0..) |n, i| {
                if (comptime n.ax) |spec| if (comptime spec.name_from_content or isBinding(n.props.al)) {
                    try setAx(t, base + @as(i64, i), spec);
                };
                if (comptime (n.kind == .check or n.kind == .button) and isBinding(n.props.al)) {
                    if (drawnAx(t, n)) |spec| try setAx(t, base + @as(i64, i), spec);
                }
            }
        }

        // --- Media blocks: each combination is a compiled variant ----------

        const variant_count: u32 = @as(u32, 1) << @intCast(plan.media_len);

        /// Every variant, parsed once (bit i of the index: media block i).
        const variants: [variant_count]markup.Plan = blk: {
            var out: [variant_count]markup.Plan = undefined;
            out[0] = plan;
            for (1..variant_count) |m| out[m] = markup.parseVariant(source, m);
            break :blk out;
        };

        /// The variant the window matches: bit i, media block i.
        fn maskOf(t: *const tree.Tree) u32 {
            var m: u32 = 0;
            inline for (plan.media[0..plan.media_len], 0..) |c, i| {
                if (c.matches(t.width, t.dark)) m |= @as(u32, 1) << i;
            }
            return m;
        }

        /// Switch the view at `base` to the variant the window matches (it
        /// shows `shown`); the variant it shows now.
        fn refresh(t: *tree.Tree, base: i64, shown: u32) anyerror!u32 {
            const m = maskOf(t);
            if (m == shown) return m;
            switch (m) {
                inline 0...variant_count - 1 => |cm| try applyVariant(t, base, cm),
                else => unreachable,
            }
            return m;
        }

        /// The props some variant sets otherwise, from variant `m` (a
        /// text's runs keep their texts).
        fn applyVariant(t: *tree.Tree, base: i64, comptime m: u32) !void {
            @setEvalBranchQuota(4000000);
            inline for (0..plan.len) |i| {
                const fields = comptime styledFields(i);
                const runs_change = comptime runsChange(i);
                if (fields.len > 0 or runs_change) if (t.get(base + @as(i64, @intCast(i)))) |n| {
                    const want = comptime propsOf(variants[m].nodes[i]);
                    var props = n.props;
                    inline for (fields) |f| @field(props, f) = @field(want, f);
                    var runs: [if (want.runs) |r| r.len else 0]tree.Run = undefined;
                    if (runs_change) if (n.props.runs) |current| if (current.len == runs.len) {
                        inline for (want.runs.?, 0..) |r, j| {
                            runs[j] = r;
                            runs[j].t = current[j].t;
                        }
                        props.runs = &runs;
                    };
                    try t.updateUiProps(n.id, props);
                };
            }
        }

        /// The props (but runs) of node `i` that differ in some variant.
        fn styledFields(comptime i: usize) []const []const u8 {
            var out: []const []const u8 = &.{};
            const base_props = propsOf(plan.nodes[i]);
            for (std.meta.fields(tree.Props)) |f| {
                if (std.mem.eql(u8, f.name, "runs")) continue;
                for (1..variant_count) |m| {
                    if (!same(f.type, @field(base_props, f.name), @field(propsOf(variants[m].nodes[i]), f.name))) {
                        out = out ++ &[_][]const u8{f.name};
                        break;
                    }
                }
            }
            return out;
        }

        fn runsChange(comptime i: usize) bool {
            const a = propsOf(plan.nodes[i]).runs orelse return false;
            for (1..variant_count) |m| {
                const b = propsOf(variants[m].nodes[i]).runs orelse continue;
                if (a.len != b.len) return true;
                for (a, b) |x, y| {
                    var y2 = y;
                    y2.t = x.t;
                    if (!same(tree.Run, x, y2)) return true;
                }
            }
            return false;
        }
    };
}

/// A template element's props as the tree takes them: a text's or a push
/// button's runs from its style.
fn propsOf(comptime n: markup.Spec) tree.Props {
    var p = n.props;
    if (n.kind == .button) p.runs = &.{.{ .t = p.val orelse "", .sz = p.fz orelse 14, .w = p.fwt orelse 400, .ff = p.ff, .mono = p.mono, .lh = p.lh, .c = p.col orelse .{ 230, 232, 236, 1 }, .i = p.it }};
    if (n.kind == .text) p.runs = if (n.runs.len > 0) runsOf(n.runs, p) else &.{.{ .t = "", .sz = p.fz orelse 14, .w = p.fwt orelse 400, .ff = p.ff, .mono = p.mono, .lh = p.lh, .c = p.col orelse .{ 230, 232, 236, 1 }, .i = p.it }};
    return p;
}

/// Two compile-time values alike, deeply (slices by content).
fn same(comptime T: type, comptime a: T, comptime b: T) bool {
    switch (@typeInfo(T)) {
        .optional => |o| {
            if (a == null or b == null) return a == null and b == null;
            return same(o.child, a.?, b.?);
        },
        .pointer => |ptr| {
            if (ptr.size != .slice) return a == b;
            if (a.len != b.len) return false;
            for (a, b) |x, y| if (!same(ptr.child, x, y)) return false;
            return true;
        },
        .array => |arr| {
            for (a, b) |x, y| if (!same(arr.child, x, y)) return false;
            return true;
        },
        .@"struct" => |st| {
            inline for (st.fields) |f| if (!same(f.type, @field(a, f.name), @field(b, f.name))) return false;
            return true;
        },
        .@"union" => {
            if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
            return switch (a) {
                inline else => |x, tag| same(@TypeOf(x), x, @field(b, @tagName(tag))),
            };
        },
        else => return a == b,
    }
}

/// The node kind a template element gets on this platform: a checkbox or
/// push button the backend doesn't host is drawn (render.js does the same).
fn kindOn(t: *const tree.Tree, comptime kind: tree.Kind) tree.Kind {
    return switch (kind) {
        .check => if (t.controls.check) .check else .view,
        .button => if (t.controls.button) .button else .text,
        else => kind,
    };
}

/// A drawn checkbox, radio or push button: the role its native widget
/// would have had.
fn drawnAx(t: *const tree.Tree, comptime n: markup.Spec) ?markup.AxSpec {
    if (n.ax != null) return null;
    if (n.kind == .check and !t.controls.check) return .{ .role = if (comptime std.mem.eql(u8, n.tag, "radio")) .radio else .checkbox, .name = n.props.al, .focusable = true };
    if (n.kind == .button and !t.controls.button) return .{ .role = .button, .name = n.props.al orelse n.props.val, .focusable = true };
    return null;
}

/// Set a node's accessibility entry, unless it already says the same: rows
/// are mounted again on every update.
fn setAx(t: *tree.Tree, id: i64, spec: markup.AxSpec) !void {
    const n = t.get(id) orelse return;
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    const name = n.props.al orelse spec.name orelse if (spec.name_from_content) blk: {
        contentText(n, &buf, &len, 0);
        break :blk if (len > 0) buf[0..len] else null;
    } else null;
    var s: u32 = 0;
    if (spec.focusable) s |= tree.Ax.focusable;
    if (n.props.dis) s |= tree.Ax.disabled;
    switch (spec.role) {
        .checkbox, .radio, .@"switch" => {
            if (n.props.on) s |= tree.Ax.checked;
            if (n.props.mix) s |= tree.Ax.mixed;
        },
        else => {},
    }
    if (t.ax.get(id)) |old| {
        if (old.r == spec.role and old.s == s and old.l == spec.level and optEql(old.n, name) and optEql(old.d, spec.description)) return;
    }
    try t.setAxEntry(id, .{ .r = spec.role, .n = name, .d = spec.description, .s = s, .l = spec.level });
}

fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// The text inside a node, words separated by a space, as much as fits.
/// Stops when `buf` is full, at a character's boundary.
fn contentText(n: *const tree.Node, buf: []u8, len: *usize, depth: usize) void {
    if (len.* >= buf.len) return;
    if (depth > tree.max_walk_depth) return tree.warnTooDeep("accessible name");
    if (n.props.runs) |runs| for (runs) |r| {
        const t = std.mem.trim(u8, r.t, " \t\r\n");
        if (t.len == 0) continue;
        if (len.* > 0) {
            if (len.* + 1 >= buf.len) return;
            buf[len.*] = ' ';
            len.* += 1;
        }
        var room = @min(t.len, buf.len - len.*);
        // Not in the middle of a character's UTF-8 bytes.
        while (room < t.len and room > 0 and t[room] & 0xC0 == 0x80) room -= 1;
        @memcpy(buf[len.*..][0..room], t[0..room]);
        len.* += room;
        if (room < t.len) return;
    };
    for (n.kids.items) |k| contentText(k, buf, len, depth + 1);
}

/// Show or hide a view part: the node and what's in it (`visible` is
/// inherited, as in the markup; the platform's widgets in it hide too).
pub fn setVisible(t: *tree.Tree, id: i64, on: bool) !void {
    const n = t.get(id) orelse return error.UnknownNode;
    try setVisibleIn(t, n, on, 0);
}

fn setVisibleIn(t: *tree.Tree, n: *tree.Node, on: bool, depth: usize) !void {
    if (depth > tree.max_walk_depth) return tree.warnTooDeep("setVisible");
    if ((n.props.vis orelse true) != on) {
        var props = n.props;
        props.vis = on;
        try t.updateUiProps(n.id, props);
    }
    for (n.kids.items) |k| try setVisibleIn(t, k, on, depth + 1);
}

/// Uses the existing platform command pool. Arguments are copied by the
/// backend before returning; completion retains request identity and status.
pub fn invoke(e: *Engine, id: u32, command: []const u8, args: anytype) !void {
    const json = try std.json.Stringify.valueAlloc(e.gpa, args, .{});
    defer e.gpa.free(json);
    e.backend.invoke(e.backend.ctx, e, id, command, json);
}

/// A <text>'s runs as the tree draws them: each span's style over the
/// text's own (a bound run's text comes at mount: setRuns).
fn runsOf(comptime runs: []const markup.RunSpec, comptime p: tree.Props) []const tree.Run {
    var out: [runs.len]tree.Run = undefined;
    for (runs, 0..) |r, i| out[i] = .{
        .t = if (isBinding(r.t)) "" else r.t,
        .sz = if (r.fz) |v| v else p.fz orelse 14,
        .w = if (r.fwt) |v| v else p.fwt orelse 400,
        .ff = r.ff orelse p.ff,
        .mono = r.mono orelse p.mono,
        .i = r.it orelse p.it,
        .lh = p.lh,
        .c = if (r.col) |c| c else p.col orelse .{ 230, 232, 236, 1 },
    };
    const final = out;
    return &final;
}

fn hasBoundRun(comptime runs: []const markup.RunSpec) bool {
    for (runs) |r| if (isBinding(r.t)) return true;
    return false;
}

/// A text's runs with its bindings' values, sent only when one changed.
fn setRuns(t: *tree.Tree, id: i64, comptime specs: []const markup.RunSpec, bindings: []const Binding) !void {
    const n = t.get(id) orelse return error.UnknownNode;
    const current = n.props.runs orelse return error.InvalidTextNode;
    if (current.len != specs.len) return error.InvalidTextNode;
    var runs: [specs.len]tree.Run = undefined;
    var changed = false;
    inline for (specs, 0..) |spec, i| {
        runs[i] = current[i];
        if (comptime isBinding(spec.t)) {
            const value = try resolve(spec.t, bindings);
            if (!std.mem.eql(u8, value, current[i].t)) changed = true;
            runs[i].t = value;
        }
    }
    if (!changed) return;
    var props = n.props;
    props.runs = &runs;
    try t.updateUiProps(id, props);
}

const max_bindings = 512;

fn validateIds(base: i64, count: usize) !void {
    if (count == 0 or base > std.math.maxInt(i64) - @as(i64, @intCast(count - 1))) return error.InvalidTemplate;
}

fn validateBindings(bindings: []const Binding) !void {
    if (bindings.len > max_bindings) return error.UiPropsTooLarge;
    var bytes: usize = 0;
    for (bindings) |binding| {
        if (binding.name.len > 256 or binding.value.len > tree.max_ui_string_bytes) return error.UiPropsTooLarge;
        const size = binding.name.len + binding.value.len;
        if (size > tree.max_ui_props_bytes - bytes) return error.UiPropsTooLarge;
        bytes += size;
    }
}

fn boundNode(comptime n: markup.Spec) bool {
    return isBinding(n.text) or hasBoundRun(n.runs) or isBinding(n.props.tip) or isBinding(n.props.al);
}

fn isBinding(comptime v: ?[]const u8) bool {
    const s = v orelse return false;
    return s.len >= 2 and s[0] == '{' and s[s.len - 1] == '}';
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
    try V.update(&t, 100, &.{.{ .name = "title", .value = &bytes }});
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

test "bound tooltips and labels are owned and follow the bindings" {
    const measure = struct {
        fn f(_: *anyopaque, _: *tree.Node, _: f32, out: *[2]f32) void {
            out.* = .{ 40, 18 };
        }
    }.f;
    var ctx: u8 = 0;
    var t = tree.Tree.init(std.testing.allocator, &ctx, measure);
    defer t.deinit();
    const V = View("<button id=\"kill\" tooltip=\"{why}\" label=\"{name}\"><text>X</text></button>");
    try V.prepare(&t, 10);
    var why = [_]u8{ 'e', 'n', 'd' };
    _ = try V.mount(&t, 100, 10, &.{ .{ .name = "why", .value = &why }, .{ .name = "name", .value = "Terminate firefox" } });
    @memset(&why, 'x');
    const n = t.get(100).?;
    try std.testing.expectEqualStrings("end", n.props.tip.?);
    try std.testing.expectEqualStrings("Terminate firefox", t.ax.get(100).?.n.?);
    try V.update(&t, 100, &.{ .{ .name = "why", .value = "stop" }, .{ .name = "name", .value = "Terminate bash" } });
    try std.testing.expectEqualStrings("stop", n.props.tip.?);
    try std.testing.expectEqualStrings("Terminate bash", t.ax.get(100).?.n.?);
    try std.testing.expectError(error.MissingBinding, V.mount(&t, 100, 10, &.{}));
}

test "text with spans: styled runs, bound ones updated only when they change" {
    const measure = struct {
        fn f(_: *anyopaque, _: *tree.Node, _: f32, out: *[2]f32) void {
            out.* = .{ 40, 18 };
        }
    }.f;
    var ctx: u8 = 0;
    var t = tree.Tree.init(std.testing.allocator, &ctx, measure);
    defer t.deinit();
    const V = View("<text id=\"score\" color=\"#8f97a8\">Score <span color=\"#e8eaee\" font-weight=\"700\">{score}</span></text>");
    try V.prepare(&t, 10);
    var value = [_]u8{'7'};
    _ = try V.mount(&t, 100, 10, &.{.{ .name = "score", .value = &value }});
    value[0] = 'x';
    const n = t.get(100).?;
    const runs = n.props.runs.?;
    try std.testing.expectEqual(@as(usize, 2), runs.len);
    try std.testing.expectEqualStrings("Score ", runs[0].t);
    try std.testing.expectEqual(tree.Color{ 143, 151, 168, 1 }, runs[0].c);
    try std.testing.expectEqualStrings("7", runs[1].t);
    try std.testing.expectEqual(@as(f32, 700), runs[1].w);
    try V.update(&t, 100, &.{.{ .name = "score", .value = "42" }});
    try std.testing.expectEqualStrings("42", t.get(100).?.props.runs.?[1].t);
}

test "media blocks switch a mounted view's styles with the window's width" {
    const measure = struct {
        fn f(_: *anyopaque, _: *tree.Node, _: f32, out: *[2]f32) void {
            out.* = .{ 40, 18 };
        }
    }.f;
    var ctx: u8 = 0;
    var t = tree.Tree.init(std.testing.allocator, &ctx, measure);
    defer t.deinit();
    const V = View(
        \\<style>
        \\  top: padding=10 column-gap=14
        \\  title: font-size=16
        \\  @media (max-width: 520) { top: padding=8 column-gap=10  title: display=none font-size=12 }
        \\</style>
        \\<row id="top" class="top"><text id="title" class="title">Breakout</text><text id="score">{score}</text></row>
    );
    t.width = 600;
    try V.prepare(&t, 10);
    _ = try V.mount(&t, 100, 10, &.{.{ .name = "score", .value = "7" }});
    const top = t.get(V.id("top", 100)).?;
    const title = t.get(V.id("title", 100)).?;
    try std.testing.expectEqual(@as(?f32, 14), top.props.cg);
    try std.testing.expect(!title.props.none);
    t.width = 400;
    try t.refreshMedia();
    try std.testing.expectEqual(@as(?f32, 10), t.get(top.id).?.props.cg);
    try std.testing.expectEqual(@as(f32, 8), t.get(top.id).?.props.pad.?[0].px);
    try std.testing.expect(t.get(title.id).?.props.none);
    // A text's runs follow, keeping their text.
    try std.testing.expectEqual(@as(f32, 12), t.get(title.id).?.props.runs.?[0].sz);
    try std.testing.expectEqualStrings("Breakout", t.get(title.id).?.props.runs.?[0].t);
    // A remount keeps the variant (and a bound text keeps its value).
    _ = try V.mount(&t, 100, 10, &.{.{ .name = "score", .value = "8" }});
    try std.testing.expect(t.get(title.id).?.props.none);
    t.width = 900;
    try t.refreshMedia();
    try std.testing.expectEqual(@as(?f32, 14), t.get(top.id).?.props.cg);
    try std.testing.expect(!t.get(title.id).?.props.none);
    try std.testing.expectEqual(@as(f32, 16), t.get(title.id).?.props.runs.?[0].sz);
    try std.testing.expectEqualStrings("8", t.get(V.id("score", 100)).?.props.runs.?[0].t);
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

test "binding updates preserve structure, media styles and content accessibility" {
    const Host = struct {
        fn measure(_: *anyopaque, _: *tree.Node, _: f32, out: *[2]f32) void {
            out.* = .{ 40, 18 };
        }
    };
    var ctx: u8 = 0;
    var t = tree.Tree.init(std.testing.allocator, &ctx, Host.measure);
    defer t.deinit();
    const V = View(
        \\<style>
        \\title: font-size=16
        \\@media (max-width: 520) { title: font-size=12 }
        \\</style>
        \\<button id="root"><text id="title" class="title">{title}</text><text>{detail}</text></button>
    );
    t.width = 600;
    try V.prepare(&t, 10);
    _ = try V.mount(&t, 100, 10, &.{ .{ .name = "title", .value = "Old" }, .{ .name = "detail", .value = "detail" } });
    const root = t.get(100).?;
    const title = t.get(V.id("title", 100)).?;
    const children = root.kids.items.ptr;
    root.scroll_y = 19;
    t.width = 400;
    try t.refreshMedia();
    try std.testing.expectError(error.MissingBinding, V.update(&t, 100, &.{.{ .name = "title", .value = "Bad" }}));
    try std.testing.expectEqualStrings("Old", title.props.runs.?[0].t);
    try V.update(&t, 100, &.{ .{ .name = "title", .value = "New" }, .{ .name = "detail", .value = "detail" } });
    try std.testing.expectEqualStrings("New detail", t.ax.get(100).?.n.?);
    try std.testing.expectEqual(@as(?f32, 12), title.props.fz);
    try std.testing.expect(root == t.get(100).? and children == root.kids.items.ptr);
    try std.testing.expectEqual(@as(f32, 19), root.scroll_y);
    t.dirty = false;
    t.paint_dirty = false;
    try V.update(&t, 100, &.{ .{ .name = "title", .value = "New" }, .{ .name = "detail", .value = "detail" } });
    try std.testing.expect(!t.dirty and !t.paint_dirty);
    t.destroy(100);
    try std.testing.expectError(error.UnknownNode, V.update(&t, 100, &.{ .{ .name = "title", .value = "New" }, .{ .name = "detail", .value = "detail" } }));
}

test "binding updates reject wrong templates, styles and invalid runs before edits" {
    const Host = struct {
        fn measure(_: *anyopaque, _: *tree.Node, _: f32, out: *[2]f32) void {
            out.* = .{ 40, 18 };
        }
    };
    var ctx: u8 = 0;
    var t = tree.Tree.init(std.testing.allocator, &ctx, Host.measure);
    defer t.deinit();
    const A = View("<column><text id=\"first\">{first}</text><text id=\"second\"><span>{second}</span></text></column>");
    const B = View("<row><text id=\"first\">{first}</text><text id=\"second\"><span>{second}</span></text></row>");
    const Static = View("<column />");
    const bindings = [_]Binding{ .{ .name = "first", .value = "old" }, .{ .name = "second", .value = "second" } };
    try std.testing.expectError(error.UnknownNode, Static.update(&t, 100, &.{}));
    try A.prepare(&t, 10);
    _ = try A.mount(&t, 100, 10, &bindings);
    try std.testing.expectError(error.IdentityChanged, B.update(&t, 100, &bindings));
    const first = t.get(A.id("first", 100)).?;
    const second = t.get(A.id("second", 100)).?;
    const changed = [_]Binding{ .{ .name = "first", .value = "new" }, .{ .name = "second", .value = "changed" } };
    const style = second.leaf_style;
    second.leaf_style = 999;
    try std.testing.expectError(error.IdentityChanged, A.update(&t, 100, &changed));
    second.leaf_style = style;
    const runs = second.props.runs;
    second.props.runs = null;
    try std.testing.expectError(error.InvalidTextNode, A.update(&t, 100, &changed));
    try std.testing.expectEqualStrings("old", first.props.runs.?[0].t);
    second.props.runs = runs;
    var excessive: [tree.max_ui_string_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(error.UiPropsTooLarge, A.update(&t, 100, &.{ .{ .name = "first", .value = "new" }, .{ .name = "second", .value = &excessive } }));
    try std.testing.expectEqualStrings("old", first.props.runs.?[0].t);
    var too_many: [max_bindings + 1]Binding = @splat(.{ .name = "first", .value = "old" });
    try std.testing.expectError(error.UiPropsTooLarge, A.update(&t, 100, &too_many));
    var chunk: [tree.max_ui_string_bytes]u8 = @splat('x');
    var aggregate: [9]Binding = @splat(.{ .name = "first", .value = &chunk });
    try std.testing.expectError(error.UiPropsTooLarge, A.update(&t, 100, &aggregate));
    try std.testing.expectEqualStrings("old", first.props.runs.?[0].t);
    try std.testing.expectError(error.InvalidTemplate, A.mount(&t, std.math.maxInt(i64), 10, &bindings));
    try A.update(&t, 100, &changed);
    try std.testing.expectEqualStrings("new", first.props.runs.?[0].t);
    try std.testing.expectEqualStrings("changed", second.props.runs.?[0].t);
}

test "mount reserves enough storage for large permitted initial values" {
    const Host = struct {
        fn measure(_: *anyopaque, _: *tree.Node, _: f32, out: *[2]f32) void {
            out.* = .{ 40, 18 };
        }
    };
    var ctx: u8 = 0;
    var t = tree.Tree.init(std.testing.allocator, &ctx, Host.measure);
    defer t.deinit();
    const initial = "a" ** (tree.default_ui_props_bytes + 1);
    const V = View("<input value=\"" ++ initial ++ "\" />");
    try V.prepare(&t, 10);
    _ = try V.mount(&t, 100, 10, &.{});
    const n = t.get(100).?;
    try std.testing.expect(n.ui_props_storage.?.capacity >= initial.len);
    try std.testing.expectEqualStrings(initial, n.pending_value.?);
    var props = n.props;
    props.val = "changed";
    try t.updateUiProps(100, props);
    try std.testing.expectEqualStrings("changed", n.props.val.?);
}
