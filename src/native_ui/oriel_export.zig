//! A native tree written as an .oriel view (the native renderer's page →
//! the Oriel renderer): every node's props as the attributes that make
//! them, so the view compiles to the same tree. Only what differs from what
//! the markup would give anyway is written: an element's defaults, the text
//! styles it inherits, a span's text's style.
//!
//! A view can have variants: the same page under a media condition (dark,
//! narrow). Nodes are matched by id (the page's elements), and what a
//! variant changes becomes that node's style and an `@media` block's rule;
//! a node a variant doesn't show is `display=none` there. `props` writes
//! each variant's nodes as JSON, for `zig build check-views`.
const std = @import("std");
const tree = @import("tree.zig");
const markup = @import("oriel_markup.zig");

const Node = tree.Node;
const Props = tree.Props;
const Writer = std.Io.Writer;

/// The page's names for node ids (an element's `id`): a view's ids, and its
/// links' (a run's `k`).
pub const Names = std.AutoHashMapUnmanaged(i64, []const u8);

/// A node as it was when exported: its props deep-copied (the page goes on).
pub const Snap = struct {
    id: i64,
    kind: tree.Kind,
    props: Props,
    kids: []Snap,
};

/// A copy of `n` and what's in it, in `arena`. A `hollow` node is copied
/// without what's in it (a list whose rows are views of their own).
pub fn snapshot(arena: std.mem.Allocator, n: *const Node, hollow: []const i64) !Snap {
    return snap(arena, n, hollow, 0);
}

fn snap(arena: std.mem.Allocator, n: *const Node, hollow: []const i64, depth: usize) !Snap {
    if (depth > tree.max_walk_depth) return error.TooDeep;
    // Through JSON: every slice copied, as the bridge's props are parsed.
    const json = try std.json.Stringify.valueAlloc(arena, n.props, .{ .emit_null_optional_fields = false });
    const copy = try std.json.parseFromSliceLeaky(Props, arena, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    const leaf = n.kind == .text or n.kind == .select or n.kind == .icon or n.kind == .button or std.mem.indexOfScalar(i64, hollow, n.id) != null;
    const kids = try arena.alloc(Snap, if (leaf) 0 else n.kids.items.len);
    for (kids, 0..) |*k, i| k.* = try snap(arena, n.kids.items[i], hollow, depth + 1);
    return .{ .id = n.id, .kind = n.kind, .props = copy, .kids = kids };
}

/// A variant of an element made again for it (a list's row, rendered anew
/// in each variant) given the default's ids, node by node: they must be
/// the same shape.
pub fn alignIds(default: *const Snap, v: *Snap) !void {
    return alignNode(default, v, 0);
}

fn alignNode(d: *const Snap, v: *Snap, depth: usize) !void {
    if (depth > tree.max_walk_depth) return error.TooDeep;
    if (d.kind != v.kind or d.kids.len != v.kids.len) return error.VariantShapeDiffers;
    v.id = d.id;
    for (d.kids, v.kids) |*a, *b| try alignNode(a, b, depth + 1);
}

/// A view's export under conditions: `media` ("prefers-color-scheme:
/// dark", several joined by " and ") and an app state, `when` (both null:
/// the view as it is by default). Each variant is a block, in order: what
/// it changes over the blocks before it whose conditions it includes.
pub const Variant = struct {
    root: Snap,
    media: ?[]const u8 = null,
    when: ?[]const u8 = null,

    /// Every condition of `a` is one of `b`'s.
    fn within(a: Variant, b: Variant) bool {
        if (a.when) |w| if (b.when == null or !std.mem.eql(u8, w, b.when.?)) return false;
        var it = std.mem.splitSequence(u8, a.media orelse return true, " and ");
        while (it.next()) |cond| {
            var other = std.mem.splitSequence(u8, b.media orelse return false, " and ");
            while (other.next()) |o| {
                if (std.mem.eql(u8, o, cond)) break;
            } else return false;
        }
        return true;
    }

    /// Its block's header: `@media (a) and (b)`, `@when (s) and (a)`.
    fn header(v: Variant, o: *Writer) !void {
        if (v.when) |w| try o.print("@when ({s})", .{w}) else try o.writeAll("@media");
        var it = std.mem.splitSequence(u8, v.media orelse "", " and ");
        var first = v.when == null;
        while (it.next()) |cond| {
            if (cond.len == 0) continue;
            try o.print("{s} ({s})", .{ if (first) "" else " and", cond });
            first = false;
        }
    }
};

const Tag = enum { view, row, column, text, input, textarea, select, checkbox, radio, slider, control, image, icon, canvas };

fn defaults(tag: Tag) markup.Spec {
    return switch (tag) {
        inline else => |t| comptime markup.defaultsOf(@tagName(t)),
    };
}

/// The element for a node; `fd_same`: its direction is the same in every
/// variant (a row or column whose direction changes is a view).
fn tagOf(kind: tree.Kind, p: Props, fd_same: bool) Tag {
    return switch (kind) {
        .view => if (fd_same) if (p.fd) |d| (if (std.mem.eql(u8, d, "row")) .row else if (std.mem.eql(u8, d, "column")) .column else .view) else .view else .view,
        .text => .text,
        .input => if (p.range != null) .slider else .input,
        .textarea => .textarea,
        .select => .select,
        .check => if (p.ctl != null and std.mem.eql(u8, p.ctl.?, "radio")) .radio else .checkbox,
        .button => .control,
        .image => .image,
        .icon => .icon,
        .canvas => .canvas,
    };
}

pub const max_variants = 40;

/// A node of the views merged: where it is in each variant (null: not
/// shown there).
const Merged = struct {
    id: i64,
    kind: tree.Kind,
    in: [max_variants]?*const Snap = @splat(null),
    kids: std.ArrayList(*Merged) = .empty,
};

/// What an element passes on in a variant, as the parser has it: the text
/// styles it set or inherited, and whether it's hidden.
const Passed = struct {
    props: Props = .{},
    bits: u16 = 0,
    hidden: bool = false,
    /// The element around is in this variant.
    shown: bool = true,
};

const Attr = struct { key: []const u8, value: []const u8 };

/// A style for one element: its rule, and each variant's media rule.
const Rule = struct {
    name: []const u8,
    base: std.ArrayList(Attr) = .empty,
    base_unset: std.ArrayList([]const u8) = .empty,
    media: [max_variants]std.ArrayList(Attr) = @splat(.empty),
    media_unset: [max_variants]std.ArrayList([]const u8) = @splat(.empty),
};

const Exporter = struct {
    arena: std.mem.Allocator,
    variants: []const Variant,
    names: *const Names,
    used: std.StringHashMapUnmanaged(void) = .empty,
    rules: std.ArrayList(*Rule) = .empty,
    body: Writer.Allocating,
    nodes: usize = 0,

    fn nameOf(x: *Exporter, id: i64) !?[]const u8 {
        const name = x.names.get(id) orelse return null;
        if (!validName(name)) return null;
        const gop = try x.used.getOrPut(x.arena, name);
        if (gop.found_existing) return null;
        return name;
    }

    fn linkName(x: *Exporter, k: u32) ![]const u8 {
        if (try x.nameOf(k)) |n| return n;
        var i: u32 = 0;
        while (true) : (i += 1) {
            const made = if (i == 0) try std.fmt.allocPrint(x.arena, "link-{d}", .{k}) else try std.fmt.allocPrint(x.arena, "link-{d}-{d}", .{ k, i });
            const gop = try x.used.getOrPut(x.arena, made);
            if (!gop.found_existing) return made;
        }
    }

    fn element(x: *Exporter, m: *const Merged, from: []const Passed, depth: usize) !void {
        if (depth > tree.max_walk_depth) return error.TooDeep;
        x.nodes += 1;
        const nv = x.variants.len;
        const first = for (m.in[0..nv]) |s| {
            if (s) |sn| break sn;
        } else unreachable;
        // A row or column only when it's one in every variant.
        var fd_same = true;
        for (m.in[0..nv]) |s| if (s) |sn| {
            if (!same(?[]const u8, sn.props.fd, first.props.fd)) fd_same = false;
        };
        const tag = tagOf(m.kind, first.props, fd_same);
        const spec = defaults(tag);
        const o = &x.body.writer;

        // What the markup gives this element in each variant if it says
        // nothing: its defaults, the text styles around it, a hidden parent.
        var expect: [max_variants]Props = undefined;
        var mine: [max_variants]Passed = undefined;
        for (0..nv) |i| {
            expect[i] = spec.props;
            mine[i] = .{};
            if (markup.inherits(m.kind)) inline for (markup.inherited_fields, 0..) |f, b| {
                const bit = @as(u16, 1) << b;
                if (from[i].bits & bit != 0) {
                    @field(expect[i], f) = @field(from[i].props, f);
                    mine[i].bits |= bit;
                }
            };
            if (expect[i].vis == null and from[i].hidden) expect[i].vis = false;
        }

        var own: std.ArrayList(Attr) = .empty;
        var own_unset: std.ArrayList([]const u8) = .empty;
        var rule: ?*Rule = null;
        const id_name = try x.nameOf(m.id);

        inline for (std.meta.fields(Props)) |f| {
            if (comptime skipField(f.name)) continue;
            // Each variant's value, and whether it's what it gets anyway.
            var all_expected = true;
            var constant = true;
            var base_value: ?f.type = null;
            for (0..nv) |i| if (m.in[i]) |s| {
                const v = @field(s.props, f.name);
                if (!same(f.type, v, @field(expect[i], f.name))) all_expected = false;
                if (base_value) |b| {
                    if (!same(f.type, v, b)) constant = false;
                } else base_value = v;
            };
            const bit: u16 = comptime if (inheritBit(f.name)) |b| @as(u16, 1) << b else 0;
            if (!all_expected) {
                if (constant) {
                    try x.fieldAttrs(f.name, base_value.?, &own, &own_unset);
                } else {
                    const r = try x.ruleFor(&rule, id_name);
                    const b = m.in[0] orelse return error.VariantOnlyStyle;
                    try x.fieldAttrs(f.name, @field(b.props, f.name), &r.base, &r.base_unset);
                    // Each block: what differs from the view and the blocks
                    // before it that it includes.
                    var written: [max_variants]?f.type = @splat(null);
                    for (1..nv) |i| if (m.in[i]) |s| {
                        var before = @field(b.props, f.name);
                        for (1..i) |j| if (written[j]) |w| if (x.variants[j].within(x.variants[i])) {
                            before = w;
                        };
                        const v = @field(s.props, f.name);
                        if (!same(f.type, v, before)) {
                            try x.fieldAttrs(f.name, v, &r.media[i], &r.media_unset[i]);
                            written[i] = v;
                        }
                    };
                }
                for (0..nv) |i| mine[i].bits |= bit;
            }
        }
        // Shown in some variants only: display=none where it isn't (on
        // the outermost such element: what's in it goes with it).
        var shown_by: [max_variants]?bool = @splat(null);
        for (1..nv) |i| if (from[i].shown) {
            var before = m.in[0] != null;
            for (1..i) |j| if (shown_by[j]) |w| if (x.variants[j].within(x.variants[i])) {
                before = w;
            };
            const here = m.in[i] != null;
            if (here != before) {
                const r = try x.ruleFor(&rule, id_name);
                if (m.in[0] == null and r.base.items.len == 0) try r.base.append(x.arena, .{ .key = "display", .value = "none" });
                try r.media[i].append(x.arena, .{ .key = "display", .value = if (here) "flex" else "none" });
                shown_by[i] = here;
            }
        };
        if (m.in[0] == null and rule == null) return error.VariantOnlyNode;
        for (0..nv) |i| {
            mine[i].shown = m.in[i] != null;
            const s = m.in[i] orelse continue;
            if (markup.inherits(m.kind)) mine[i].props = s.props else mine[i].bits = 0;
            mine[i].hidden = s.props.vis == false;
        }

        try o.splatByteAll(' ', depth * 2);
        try o.print("<{s}", .{@tagName(tag)});
        if (id_name) |name| try o.print(" id=\"{s}\"", .{name});
        if (rule) |r| try o.print(" class=\"{s}\"", .{r.name});
        for (own.items) |a| {
            try o.print(" {s}=\"", .{a.key});
            try escapeAttr(o, a.value);
            try o.writeAll("\"");
        }
        if (own_unset.items.len > 0) {
            try o.writeAll(" unset=\"");
            for (own_unset.items, 0..) |u, i| try o.print("{s}{s}", .{ if (i > 0) " " else "", u });
            try o.writeAll("\"");
        }

        const p = first.props;
        switch (tag) {
            .text => {
                try o.writeAll(">");
                try x.textContent(m, id_name);
                try o.writeAll("</text>\n");
            },
            .select => {
                const options = p.options orelse &.{};
                if (options.len == 0) return o.writeAll(" />\n");
                try o.writeAll(">\n");
                for (options) |opt| {
                    try o.splatByteAll(' ', (depth + 1) * 2);
                    try o.writeAll("<option value=\"");
                    try escapeAttr(o, opt[0]);
                    try o.writeAll("\">");
                    try escapeText(o, opt[1]);
                    try o.writeAll("</option>\n");
                }
                try o.splatByteAll(' ', depth * 2);
                try o.writeAll("</select>\n");
            },
            .icon => {
                const shapes = if (p.icon) |i| i.shapes else &.{};
                if (shapes.len == 0) return o.writeAll(" />\n");
                try o.writeAll(">\n");
                for (shapes) |s| {
                    try o.splatByteAll(' ', (depth + 1) * 2);
                    try shape(o, s);
                }
                try o.splatByteAll(' ', depth * 2);
                try o.writeAll("</icon>\n");
            },
            else => {
                // A push button's label is its value (the markup makes its run).
                if (m.kids.items.len == 0 or tag == .control) return o.writeAll(" />\n");
                try o.writeAll(">\n");
                for (m.kids.items) |k| try x.element(k, mine[0..nv], depth + 1);
                try o.splatByteAll(' ', depth * 2);
                try o.print("</{s}>\n", .{@tagName(tag)});
            },
        }
    }

    fn ruleFor(x: *Exporter, rule: *?*Rule, id_name: ?[]const u8) !*Rule {
        if (rule.*) |r| return r;
        const r = try x.arena.create(Rule);
        var name = id_name orelse try std.fmt.allocPrint(x.arena, "n{d}", .{x.nodes});
        // A style's name is its own (an id can be a style's name too).
        while (for (x.rules.items) |other| {
            if (std.mem.eql(u8, other.name, name)) break true;
        } else false) name = try std.fmt.allocPrint(x.arena, "{s}-{d}", .{ name, x.nodes });
        r.* = .{ .name = name };
        try x.rules.append(x.arena, r);
        rule.* = r;
        return r;
    }

    /// The attributes for one prop's value (a null one: `unset`).
    fn fieldAttrs(x: *Exporter, comptime field: []const u8, v: anytype, attrs: *std.ArrayList(Attr), unset: *std.ArrayList([]const u8)) !void {
        const a = x.arena;
        if (comptime std.mem.eql(u8, field, "ins")) {
            const sides = [_][]const u8{ "top", "right", "bottom", "left" };
            const ins = v orelse {
                for (sides) |s| try unset.append(a, s);
                return;
            };
            for (ins, sides) |side, name| {
                if (side) |d| try attrs.append(a, .{ .key = name, .value = try fmtDim(a, d) }) else try unset.append(a, name);
            }
            return;
        }
        if (comptime std.mem.eql(u8, field, "range")) {
            const r = v orelse return error.RangeRemoved;
            const keys = [_][]const u8{ "min", "max", "step" };
            for (r, keys) |n, key| try attrs.append(a, .{ .key = key, .value = try std.fmt.allocPrint(a, "{d}", .{n}) });
            return;
        }
        if (comptime std.mem.eql(u8, field, "icon")) {
            const icon = v orelse return error.IconRemoved;
            try attrs.append(a, .{ .key = "viewbox", .value = try std.fmt.allocPrint(a, "{d},{d},{d},{d}", .{ icon.vb[0], icon.vb[1], icon.vb[2], icon.vb[3] }) });
            return;
        }
        if (comptime @typeInfo(@TypeOf(v)) == .optional) {
            if (v) |value| return x.valueAttrs(field, value, attrs);
            return unset.append(a, comptime attrName(field));
        }
        return x.valueAttrs(field, v, attrs);
    }

    fn valueAttrs(x: *Exporter, comptime field: []const u8, v: anytype, attrs: *std.ArrayList(Attr)) !void {
        const a = x.arena;
        const T = @TypeOf(v);
        if (comptime std.mem.eql(u8, field, "bg")) {
            if (v.color) |c| try attrs.append(a, .{ .key = "background", .value = try fmtColor(a, c) });
            if (v.gradient) |g| try gradientAttrs(a, g, attrs);
            return;
        }
        if (comptime std.mem.eql(u8, field, "ol")) return outlineAttrs(a, v, attrs);
        var out: Writer.Allocating = .init(a);
        const o = &out.writer;
        if (comptime std.mem.eql(u8, field, "sh")) {
            try o.print("{d},{d},{d},{d},", .{ v.x, v.y, v.blur, v.spread });
            try writeColor(o, v.color);
        } else if (comptime std.mem.eql(u8, field, "sbs")) {
            try o.writeAll(if (v) "always" else "auto");
        } else if (comptime std.mem.eql(u8, field, "dk")) {
            try o.writeAll(if (v) "dark" else "light");
        } else if (comptime std.mem.eql(u8, field, "cb")) {
            try o.writeAll(if (v) "content-box" else "border-box");
        } else if (comptime std.mem.eql(u8, field, "none")) {
            try o.writeAll(if (v) "none" else "flex");
        } else if (comptime std.mem.eql(u8, field, "bs")) {
            try o.writeAll(@tagName(v));
        } else if (comptime std.mem.eql(u8, field, "rel") or std.mem.eql(u8, field, "sticky")) {
            for (v, 0..) |side, i| {
                if (i > 0) try o.writeAll(",");
                if (side) |s| try o.print("{d}", .{s}) else try o.writeAll("auto");
            }
        } else if (comptime std.mem.eql(u8, field, "br")) {
            const all = sameCorner(v[0], v[1]) and sameCorner(v[0], v[2]) and sameCorner(v[0], v[3]);
            for (v[0..if (all) 1 else 4], 0..) |c, i| {
                if (i > 0) try o.writeAll(",");
                try writeDim(o, c.x);
                if (!same(tree.Dim, c.x, c.y)) {
                    try o.writeAll("/");
                    try writeDim(o, c.y);
                }
            }
        } else if (comptime std.mem.eql(u8, field, "col") or std.mem.eql(u8, field, "acc")) {
            // tree.Color is a [4]f32 too: by the field.
            try writeColor(o, v);
        } else if (T == [4]tree.Dim) {
            const all = same(tree.Dim, v[0], v[1]) and same(tree.Dim, v[0], v[2]) and same(tree.Dim, v[0], v[3]);
            for (v[0..if (all) 1 else 4], 0..) |d, i| {
                if (i > 0) try o.writeAll(",");
                try writeDim(o, d);
            }
        } else if (T == [4]f32) {
            const all = v[0] == v[1] and v[0] == v[2] and v[0] == v[3];
            for (v[0..if (all) 1 else 4], 0..) |d, i| try o.print("{s}{d}", .{ if (i > 0) "," else "", d });
        } else if (T == [4]tree.Color) {
            const all = std.mem.eql(f32, &v[0], &v[1]) and std.mem.eql(f32, &v[0], &v[2]) and std.mem.eql(f32, &v[0], &v[3]);
            for (v[0..if (all) 1 else 4], 0..) |c, i| {
                if (i > 0) try o.writeAll(" ");
                try writeColor(o, c);
            }
        } else if (T == [2]tree.Color) {
            try writeColor(o, v[0]);
            try o.writeAll(" ");
            try writeColor(o, v[1]);
        } else if (T == tree.Dim) {
            try writeDim(o, v);
        } else if (T == bool) {
            try o.writeAll(if (v) "true" else "false");
        } else if (T == []const u8) {
            try o.writeAll(v);
        } else if (T == f32 or T == i32 or T == f64) {
            try o.print("{d}", .{v});
        } else @compileError("No .oriel writer for Props." ++ field);
        try attrs.append(a, .{ .key = comptime attrName(field), .value = out.written() });
    }

    /// A <text>'s runs: plain text when one run in the text's own style,
    /// else a span each (what each sets over the text's style). Where a
    /// variant styles a span otherwise, what differs is its style's.
    fn textContent(x: *Exporter, m: *const Merged, id_name: ?[]const u8) !void {
        const o = &x.body.writer;
        const nv = x.variants.len;
        var content: ?[]const u8 = null;
        var differ = false;
        for (m.in[0..nv]) |s| if (s) |sn| {
            var one: Writer.Allocating = .init(x.arena);
            try x.runs(&one.writer, sn.props);
            if (content) |c| {
                if (!std.mem.eql(u8, c, one.written())) differ = true;
            } else content = one.written();
        };
        if (!differ) return o.writeAll(content orelse "");

        // The same runs, the same text, in every variant.
        const first = for (m.in[0..nv]) |s| {
            if (s) |sn| break sn;
        } else unreachable;
        const rs = first.props.runs orelse &.{};
        for (m.in[0..nv]) |s| if (s) |sn| {
            const other = sn.props.runs orelse &.{};
            if (other.len != rs.len) return spansDiffer(m, id_name);
            for (rs, other) |a, b| if (!std.mem.eql(u8, a.t, b.t) or (a.k == null) != (b.k == null) or !same(?tree.InlineBox, a.ib, b.ib)) return spansDiffer(m, id_name);
        };
        const b0 = m.in[0] orelse return error.VariantOnlyStyle;
        var spaced = true;
        for (rs, 0..) |r0, ri| {
            var own: std.ArrayList(Attr) = .empty;
            var own_unset: std.ArrayList([]const u8) = .empty;
            var rule: ?*Rule = null;
            inline for (span_keys) |key| {
                // Each variant's value, and whether it's the text's own.
                var any = false;
                var constant = true;
                var all_set = true;
                var first_value: ?[]const u8 = null;
                var seen = false;
                for (0..nv) |i| if (m.in[i]) |s| {
                    const r = s.props.runs.?[ri];
                    const v = try spanValue(x.arena, key, r);
                    const base = try spanValue(x.arena, key, textRun(s.props));
                    if (!optEql(v, base)) any = true else all_set = false;
                    if (seen) {
                        if (!optEql(v, first_value)) constant = false;
                    } else {
                        first_value = v;
                        seen = true;
                    }
                };
                if (any) {
                    if (constant and all_set) {
                        if (first_value) |v| try own.append(x.arena, .{ .key = key, .value = v }) else try own_unset.append(x.arena, key);
                    } else {
                        if (rule == null) {
                            const r = try x.arena.create(Rule);
                            r.* = .{ .name = try std.fmt.allocPrint(x.arena, "{s}-s{d}", .{ id_name orelse try std.fmt.allocPrint(x.arena, "n{d}", .{x.nodes}), ri }) };
                            try x.rules.append(x.arena, r);
                            rule = r;
                        }
                        const r = rule.?;
                        const bv = try spanValue(x.arena, key, b0.props.runs.?[ri]);
                        if (bv) |v| try r.base.append(x.arena, .{ .key = key, .value = v }) else try r.base_unset.append(x.arena, key);
                        var written: [max_variants]??[]const u8 = @splat(null);
                        for (1..nv) |i| if (m.in[i]) |s| {
                            var before = bv;
                            for (1..i) |j| if (written[j]) |w| if (x.variants[j].within(x.variants[i])) {
                                before = w;
                            };
                            const v = try spanValue(x.arena, key, s.props.runs.?[ri]);
                            if (!optEql(v, before)) {
                                if (v) |value| try r.media[i].append(x.arena, .{ .key = key, .value = value }) else try r.media_unset[i].append(x.arena, key);
                                written[i] = v;
                            }
                        };
                    }
                }
            }
            try o.writeAll("<span");
            if (rule) |r| try o.print(" class=\"{s}\"", .{r.name});
            for (own.items) |a| {
                try o.print(" {s}=\"", .{a.key});
                try escapeAttr(o, a.value);
                try o.writeAll("\"");
            }
            if (r0.ib) |ib| try boxAttrs(o, ib);
            if (r0.k) |k| try o.print(" link=\"{s}\"", .{try x.linkName(k)});
            if (own_unset.items.len > 0) {
                try o.writeAll(" unset=\"");
                for (own_unset.items, 0..) |u, i| try o.print("{s}{s}", .{ if (i > 0) " " else "", u });
                try o.writeAll("\"");
            }
            try o.writeAll(">");
            try escapeSpan(o, r0.t, &spaced, ri == rs.len - 1);
            try o.writeAll("</span>");
        }
    }

    fn runs(x: *Exporter, o: *Writer, p: Props) !void {
        const rs = p.runs orelse return;
        const base = textRun(p);
        if (rs.len == 1 and rs[0].k == null) {
            var r = rs[0];
            r.t = "";
            if (same(tree.Run, r, base) and rs[0].t.len > 0) return escapeText(o, rs[0].t);
        }
        var spaced = true; // the text's start: a space there would go
        for (rs, 0..) |r, i| {
            try o.writeAll("<span");
            try x.spanAttrs(o, r, base);
            try o.writeAll(">");
            try escapeSpan(o, r.t, &spaced, i == rs.len - 1);
            try o.writeAll("</span>");
        }
    }

    fn spanAttrs(x: *Exporter, o: *Writer, r: tree.Run, base: tree.Run) !void {
        if (!std.mem.eql(f32, &r.c, &base.c)) {
            try o.writeAll(" color=\"");
            try writeColor(o, r.c);
            try o.writeAll("\"");
        }
        if (r.sz != base.sz) try o.print(" font-size=\"{d}\"", .{r.sz});
        if (r.w != base.w) try o.print(" font-weight=\"{d}\"", .{r.w});
        if (r.i != base.i) try o.print(" italic=\"{}\"", .{r.i});
        if (r.mono != base.mono) try o.print(" mono=\"{}\"", .{r.mono});
        if (r.u) try o.writeAll(" underline=\"true\"");
        if (r.ff) |ff| if (base.ff == null or !std.mem.eql(u8, ff, base.ff.?)) {
            try o.writeAll(" font-family=\"");
            try escapeAttr(o, ff);
            try o.writeAll("\"");
        };
        if (r.lh) |lh| if (base.lh == null or base.lh.? != lh) try o.print(" line-height=\"{d}\"", .{lh});
        if (r.bg) |bg| {
            try o.writeAll(" background=\"");
            try writeColor(o, bg);
            try o.writeAll("\"");
        }
        if (r.ol) |ol| {
            var attrs: std.ArrayList(Attr) = .empty;
            try outlineAttrs(x.arena, ol, &attrs);
            for (attrs.items) |a| try o.print(" {s}=\"{s}\"", .{ a.key, a.value });
        }
        if (r.ib) |b| try boxAttrs(o, b);
        if (r.k) |k| try o.print(" link=\"{s}\"", .{try x.linkName(k)});
        var unset: [2][]const u8 = undefined;
        var count: usize = 0;
        if (r.ff == null and base.ff != null) {
            unset[count] = "font-family";
            count += 1;
        }
        if (r.lh == null and base.lh != null) {
            unset[count] = "line-height";
            count += 1;
        }
        if (count > 0) {
            try o.writeAll(" unset=\"");
            for (unset[0..count], 0..) |u, i| try o.print("{s}{s}", .{ if (i > 0) " " else "", u });
            try o.writeAll("\"");
        }
    }

    /// The <style>: each element's style, then each variant's block.
    fn sheet(x: *Exporter, o: *Writer) !void {
        if (x.rules.items.len == 0) return;
        try o.writeAll("<style>\n");
        for (x.rules.items) |r| if (r.base.items.len > 0 or r.base_unset.items.len > 0) {
            try o.writeAll("  ");
            try ruleLine(o, r.name, r.base.items, r.base_unset.items);
        };
        for (x.variants, 0..) |v, i| if (i > 0) {
            var any = false;
            for (x.rules.items) |r| {
                if (r.media[i].items.len > 0 or r.media_unset[i].items.len > 0) any = true;
            }
            if (!any) continue;
            try o.writeAll("  ");
            try v.header(o);
            try o.writeAll(" {\n");
            for (x.rules.items) |r| if (r.media[i].items.len > 0 or r.media_unset[i].items.len > 0) {
                try o.writeAll("    ");
                try ruleLine(o, r.name, r.media[i].items, r.media_unset[i].items);
            };
            try o.writeAll("  }\n");
        };
        try o.writeAll("</style>\n");
    }
};

/// A text whose spans (their texts, links or boxes) a variant changes:
/// a block can't say that.
fn spansDiffer(m: *const Merged, id_name: ?[]const u8) error{SpansDifferBetweenVariants} {
    const first = for (m.in) |sn| {
        if (sn) |x| break x;
    } else null;
    const text = if (first) |f| if (f.props.runs) |rs| (if (rs.len > 0) rs[0].t else "") else "" else "";
    std.log.err("oriel export: the spans of text {s} (\"{s}\") differ between variants", .{ id_name orelse "(no id)", text[0..@min(text.len, 40)] });
    return error.SpansDifferBetweenVariants;
}

/// The span attributes a variant can change, as a style's.
const span_keys = .{ "color", "font-size", "font-weight", "italic", "mono", "underline", "font-family", "line-height", "background", "outline" };

/// The run a span with no attributes has in a text with these props.
fn textRun(p: Props) tree.Run {
    return .{ .t = "", .sz = p.fz orelse 14, .w = p.fwt orelse 400, .ff = p.ff, .mono = p.mono, .i = p.it, .lh = p.lh, .c = p.col orelse .{ 230, 232, 236, 1 } };
}

/// A run's value for a span attribute (null: none, `unset`).
fn spanValue(a: std.mem.Allocator, comptime key: []const u8, r: tree.Run) !?[]const u8 {
    const eq = std.mem.eql;
    if (comptime eq(u8, key, "color")) return try fmtColor(a, r.c);
    if (comptime eq(u8, key, "font-size")) return try std.fmt.allocPrint(a, "{d}", .{r.sz});
    if (comptime eq(u8, key, "font-weight")) return try std.fmt.allocPrint(a, "{d}", .{r.w});
    if (comptime eq(u8, key, "italic")) return if (r.i) "true" else "false";
    if (comptime eq(u8, key, "mono")) return if (r.mono) "true" else "false";
    if (comptime eq(u8, key, "underline")) return if (r.u) "true" else "false";
    if (comptime eq(u8, key, "font-family")) return r.ff;
    if (comptime eq(u8, key, "line-height")) return if (r.lh) |lh| try std.fmt.allocPrint(a, "{d}", .{lh}) else null;
    if (comptime eq(u8, key, "background")) return if (r.bg) |bg| try fmtColor(a, bg) else null;
    if (comptime eq(u8, key, "outline")) {
        // Its style, halo and radius go with it (outlineAttrs): one value.
        const ol = r.ol orelse return null;
        var attrs: std.ArrayList(Attr) = .empty;
        try outlineAttrs(a, ol, &attrs);
        if (attrs.items.len > 1) return error.SpanOutlineStyleDiffersBetweenVariants;
        return attrs.items[0].value;
    }
    @compileError("No span attribute " ++ key);
}

fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn boxAttrs(o: *Writer, b: tree.InlineBox) !void {
    try o.print(" box=\"{d}\"", .{b.k});
    if (!std.mem.allEqual(f32, &b.p, 0)) try o.print(" box-padding=\"{d},{d},{d},{d}\"", .{ b.p[0], b.p[1], b.p[2], b.p[3] });
    if (!std.mem.allEqual(f32, &b.m, 0)) try o.print(" box-margin=\"{d},{d},{d},{d}\"", .{ b.m[0], b.m[1], b.m[2], b.m[3] });
    if (b.bw) |w| try o.print(" box-border-width=\"{d},{d},{d},{d}\"", .{ w[0], w[1], w[2], w[3] });
    if (!std.mem.eql(f32, &b.bc, &[4]f32{ 0, 0, 0, 1 })) {
        try o.writeAll(" box-border-color=\"");
        try writeColor(o, b.bc);
        try o.writeAll("\"");
    }
    if (b.br) |br| try o.print(" box-radius=\"{d},{d},{d},{d}\"", .{ br[0], br[1], br[2], br[3] });
    if (b.bg) |bg| {
        try o.writeAll(" box-background=\"");
        try writeColor(o, bg);
        try o.writeAll("\"");
    }
}

fn ruleLine(o: *Writer, name: []const u8, attrs: []const Attr, unset: []const []const u8) !void {
    try o.print("{s}:", .{name});
    for (attrs) |a| {
        try o.print(" {s}=", .{a.key});
        try sheetValue(o, a.value);
    }
    if (unset.len > 0) {
        try o.writeAll(" unset=\"");
        for (unset, 0..) |u, i| try o.print("{s}{s}", .{ if (i > 0) " " else "", u });
        try o.writeAll("\"");
    }
    try o.writeAll("\n");
}

/// A style's value: bare when it's one word, else quoted.
fn sheetValue(o: *Writer, v: []const u8) !void {
    const bare = v.len > 0 and for (v) |c| {
        if (std.ascii.isWhitespace(c) or c == '"' or c == '}' or c == '&' or c == '$' or c == '=') break false;
    } else true;
    if (bare) return o.writeAll(v);
    try o.writeAll("\"");
    try escapeAttr(o, v);
    try o.writeAll("\"");
}

/// Props the elements' content says (a text's spans, a select's options).
fn skipField(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "runs") or std.mem.eql(u8, name, "options");
}

fn inheritBit(comptime field: []const u8) ?usize {
    @setEvalBranchQuota(10000);
    for (markup.inherited_fields, 0..) |f, i| if (std.mem.eql(u8, f, field)) return i;
    return null;
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 200) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
    return true;
}

/// The attribute that sets a prop (the parser's names).
fn attrName(comptime field: []const u8) []const u8 {
    @setEvalBranchQuota(20000);
    const names = .{
        .{ "root", "root" },          .{ "fd", "direction" },        .{ "fw", "wrap" },             .{ "jc", "justify" },
        .{ "ai", "align" },           .{ "as", "align-self" },       .{ "ac", "align-content" },    .{ "fg", "grow" },
        .{ "fs", "shrink" },          .{ "fb", "basis" },            .{ "w", "width" },             .{ "h", "height" },
        .{ "minw", "min-width" },     .{ "minh", "min-height" },     .{ "maxw", "max-width" },      .{ "maxh", "max-height" },
        .{ "m", "margin" },           .{ "pad", "padding" },         .{ "bw", "border-width" },     .{ "bc", "border-color" },
        .{ "bs", "border-style" },    .{ "rg", "row-gap" },          .{ "cg", "column-gap" },       .{ "pos", "position" },
        .{ "rel", "relative" },       .{ "scroll", "scroll" },       .{ "scrollx", "scroll-x" },    .{ "sbs", "scrollbar" },
        .{ "sbw", "scrollbar-width" }, .{ "dk", "color-scheme" },    .{ "sbc", "scrollbar-color" }, .{ "table", "table" },
        .{ "trow", "table-row" },     .{ "tcell", "table-cell" },    .{ "sticky", "sticky" },       .{ "clip", "clip" },
        .{ "ar", "aspect-ratio" },    .{ "tx", "translate-x" },      .{ "sc", "scale" },            .{ "rot", "rotate" },
        .{ "ty", "translate-y" },     .{ "bg", "background" },       .{ "br", "radius" },           .{ "op", "opacity" },
        .{ "sh", "shadow" },          .{ "ol", "outline" },          .{ "vis", "visible" },         .{ "click", "clickable" },
        .{ "z", "z" },                .{ "col", "color" },           .{ "fz", "font-size" },        .{ "fwt", "font-weight" },
        .{ "it", "italic" },          .{ "mono", "mono" },           .{ "ff", "font-family" },      .{ "lh", "line-height" },
        .{ "ta", "text-align" },      .{ "nowrap", "nowrap" },       .{ "mc", "max-content" },      .{ "fc", "fit-content" },
        .{ "ls", "letter-spacing" },  .{ "val", "value" },           .{ "ph", "placeholder" },      .{ "dis", "disabled" },
        .{ "pw", "password" },        .{ "cb", "box-sizing" },       .{ "cols", "cols" },           .{ "rows", "rows" },
        .{ "src", "src" },            .{ "fit", "fit" },             .{ "cw", "pixel-width" },      .{ "ch", "pixel-height" },
        .{ "ro", "readonly" },        .{ "itype", "type" },          .{ "im", "inputmode" },        .{ "ek", "enterkey" },
        .{ "cap", "autocapitalize" }, .{ "cor", "autocorrect" },     .{ "spellcheck", "spellcheck" }, .{ "al", "label" },
        .{ "ctl", "control" },        .{ "blb", "baseline" },        .{ "on", "checked" },          .{ "mix", "mixed" },
        .{ "acc", "accent" },         .{ "tip", "tooltip" },         .{ "ti", "tabindex" },         .{ "none", "display" },
        .{ "ins", "top" },            .{ "range", "min" },           .{ "icon", "viewbox" },
    };
    for (names) |e| if (std.mem.eql(u8, e[0], field)) return e[1];
    @compileError("No .oriel attribute name for Props." ++ field);
}

fn gradientAttrs(a: std.mem.Allocator, g: tree.Gradient, attrs: *std.ArrayList(Attr)) !void {
    var stops: Writer.Allocating = .init(a);
    for (g.stops, 0..) |s, i| try stops.writer.print("{s}{d},{d},{d},{d},{d}", .{ if (i > 0) "; " else "", s[0], s[1], s[2], s[3], s[4] });
    try attrs.append(a, .{ .key = "gradient-stops", .value = stops.written() });
    if (g.angle != 180) try attrs.append(a, .{ .key = "gradient-angle", .value = try std.fmt.allocPrint(a, "{d}", .{g.angle}) });
    if (g.radial) |r| {
        var out: Writer.Allocating = .init(a);
        for (r, 0..) |d, i| {
            if (i > 0) try out.writer.writeAll(",");
            try writeDim(&out.writer, d);
        }
        try attrs.append(a, .{ .key = "gradient-radial", .value = out.written() });
    }
    if (g.ext) |e| try attrs.append(a, .{ .key = "gradient-extent", .value = e });
    if (g.circle) try attrs.append(a, .{ .key = "gradient-circle", .value = "true" });
    if (g.rep) try attrs.append(a, .{ .key = "gradient-repeat", .value = "true" });
    if (g.su) |su| try attrs.append(a, .{ .key = "gradient-units", .value = su });
    if (g.sp) |sp| {
        var out: Writer.Allocating = .init(a);
        for (sp, 0..) |v, i| try out.writer.print("{s}{d}", .{ if (i > 0) "," else "", v });
        try attrs.append(a, .{ .key = "gradient-offsets", .value = out.written() });
    }
}

fn outlineAttrs(a: std.mem.Allocator, ol: tree.Outline, attrs: *std.ArrayList(Attr)) !void {
    var main: Writer.Allocating = .init(a);
    try main.writer.print("{d},{d},", .{ ol.w, ol.o });
    try writeColor(&main.writer, ol.c);
    try attrs.append(a, .{ .key = "outline", .value = main.written() });
    if (ol.s) |s| try attrs.append(a, .{ .key = "outline-style", .value = @tagName(s) });
    if (ol.h) |h| try attrs.append(a, .{ .key = "outline-halo", .value = try fmtColor(a, h) });
    if (ol.r != 0) try attrs.append(a, .{ .key = "outline-radius", .value = try std.fmt.allocPrint(a, "{d}", .{ol.r}) });
}

fn shape(o: *Writer, s: tree.Shape) !void {
    try o.writeAll("<path d=\"");
    try escapeAttr(o, s.d);
    try o.writeAll("\" fill=\"");
    if (s.fill) |c| try writeColor(o, c) else try o.writeAll("none");
    try o.writeAll("\"");
    if (s.stroke) |c| {
        try o.writeAll(" stroke=\"");
        try writeColor(o, c);
        try o.writeAll("\"");
    }
    if (s.sw != 1) try o.print(" stroke-width=\"{d}\"", .{s.sw});
    if (!std.mem.eql(u8, s.cap, "butt")) try o.print(" linecap=\"{s}\"", .{s.cap});
    if (!std.mem.eql(u8, s.join, "miter")) try o.print(" linejoin=\"{s}\"", .{s.join});
    if (s.evenodd) try o.writeAll(" evenodd=\"true\"");
    try o.writeAll(" />\n");
}

fn fmtDim(a: std.mem.Allocator, d: tree.Dim) ![]const u8 {
    var out: Writer.Allocating = .init(a);
    try writeDim(&out.writer, d);
    return out.written();
}

fn fmtColor(a: std.mem.Allocator, c: tree.Color) ![]const u8 {
    var out: Writer.Allocating = .init(a);
    try writeColor(&out.writer, c);
    return out.written();
}

fn writeDim(o: *Writer, d: tree.Dim) !void {
    switch (d) {
        .px => |v| try o.print("{d}", .{v}),
        .pct => |v| try o.print("{d}%", .{v}),
        .calc => |c| try o.print("{d}%{s}{d}px", .{ @as(f32, c.pct), if (c.px >= 0) "+" else "", @as(f32, c.px) }),
        .auto => try o.writeAll("auto"),
        .none => try o.writeAll("none"),
    }
}

/// #RRGGBB, #RRGGBBAA when the markup's /255 gives the alpha back exactly,
/// else rgba().
fn writeColor(o: *Writer, c: tree.Color) !void {
    const whole = for (c[0..3]) |v| {
        if (v != @round(v) or v < 0 or v > 255) break false;
    } else true;
    if (whole) {
        const r: u8 = @intFromFloat(c[0]);
        const g: u8 = @intFromFloat(c[1]);
        const b: u8 = @intFromFloat(c[2]);
        if (c[3] == 1) return o.print("#{x:0>2}{x:0>2}{x:0>2}", .{ r, g, b });
        const a255 = @round(c[3] * 255);
        if (a255 >= 0 and a255 <= 255 and a255 / 255 == c[3]) return o.print("#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ r, g, b, @as(u8, @intFromFloat(a255)) });
    }
    try o.print("rgba({d}, {d}, {d}, {d})", .{ c[0], c[1], c[2], c[3] });
}

fn escapeAttr(o: *Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try o.writeAll("&amp;"),
        '"' => try o.writeAll("&quot;"),
        '<' => try o.writeAll("&lt;"),
        '$' => try o.writeAll("&#36;"),
        '\n' => try o.writeAll("&#10;"),
        else => try o.writeByte(c),
    };
}

/// A <text>'s or <option>'s plain text: trimmed by the markup, so
/// whitespace at either end is written as characters.
fn escapeText(o: *Writer, s: []const u8) !void {
    const start = std.mem.indexOfNone(u8, s, " \t\r\n") orelse s.len;
    const end = if (std.mem.lastIndexOfNone(u8, s, " \t\r\n")) |e| e + 1 else start;
    for (s, 0..) |c, i| {
        if ((i < start or i >= end) and isSpace(c)) {
            try o.print("&#{d};", .{c});
            continue;
        }
        try plainChar(o, c);
    }
}

/// A span's text: the markup collapses runs of spaces (one stays, none at
/// the text's ends), so a space that wouldn't survive, and any other
/// whitespace, is written as a character.
fn escapeSpan(o: *Writer, s: []const u8, spaced: *bool, last: bool) !void {
    for (s, 0..) |c, i| {
        if (isSpace(c)) {
            const final = last and i == s.len - 1;
            if (c == ' ' and !spaced.* and !final) {
                try o.writeByte(' ');
                spaced.* = true;
            } else {
                try o.print("&#{d};", .{c});
                spaced.* = false;
            }
            continue;
        }
        try plainChar(o, c);
        spaced.* = false;
    }
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

fn plainChar(o: *Writer, c: u8) !void {
    switch (c) {
        '&' => try o.writeAll("&amp;"),
        '<' => try o.writeAll("&lt;"),
        else => try o.writeByte(c),
    }
}

fn sameCorner(a: tree.Corner, b: tree.Corner) bool {
    return same(tree.Dim, a.x, b.x) and same(tree.Dim, a.y, b.y);
}

/// Two values alike, deeply (slices by content).
fn same(comptime T: type, a: T, b: T) bool {
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
        .float => return a == b or (std.math.isNan(a) and std.math.isNan(b)),
        else => return a == b,
    }
}

/// The markup's limits on a view (oriel_markup.Plan).
pub const max_view_nodes = 512;

/// The view of the variants (the first: the default), merged by node id.
/// Its links are named from `names` (made up where the page has none).
/// Returns how many elements it has.
pub fn view(gpa: std.mem.Allocator, variants: []const Variant, names: *const Names, out: *Writer) !usize {
    if (variants.len == 0 or variants.len > max_variants or variants[0].media != null or variants[0].when != null) return error.NoDefaultVariant;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var by_id: std.AutoHashMapUnmanaged(i64, *Merged) = .empty;
    const root = try merge(arena, &by_id, &variants[0].root, 0, 0);
    // By pointer: the merged nodes point into the variants.
    for (variants[1..], 1..) |*v, i| {
        if (v.root.id != variants[0].root.id) return error.VariantOfAnotherElement;
        _ = try merge(arena, &by_id, &v.root, i, 0);
    }
    var x: Exporter = .{ .arena = arena, .variants = variants, .names = names, .body = .init(arena) };
    var start: [max_variants]Passed = @splat(.{});
    try x.element(root, start[0..variants.len], 0);
    if (x.nodes > max_view_nodes) return error.ViewTooLarge;
    try x.sheet(out);
    try out.writeAll(x.body.written());
    return x.nodes;
}

/// `s` (variant `vi`) and what's in it into the merged nodes: matched by
/// id, a node only this variant has after its previous sibling.
fn merge(arena: std.mem.Allocator, by_id: *std.AutoHashMapUnmanaged(i64, *Merged), s: *const Snap, vi: usize, depth: usize) !*Merged {
    if (depth > tree.max_walk_depth) return error.TooDeep;
    const gop = try by_id.getOrPut(arena, s.id);
    if (!gop.found_existing) {
        const m = try arena.create(Merged);
        m.* = .{ .id = s.id, .kind = s.kind };
        gop.value_ptr.* = m;
    } else if (gop.value_ptr.*.kind != s.kind) return error.KindDiffersBetweenVariants;
    const m = gop.value_ptr.*;
    m.in[vi] = s;
    var prev: ?*Merged = null;
    for (s.kids) |*k| {
        const known = by_id.contains(k.id);
        const km = try merge(arena, by_id, k, vi, depth + 1);
        if (!known) {
            // New: after its previous sibling here (first, without one).
            const at = if (prev) |p| (std.mem.indexOfScalar(*Merged, m.kids.items, p) orelse m.kids.items.len - 1) + 1 else 0;
            try m.kids.insert(arena, at, km);
        }
        prev = km;
    }
    return m;
}

/// Each node's kind and props as JSON, a line each, in the view's order
/// (what the view must compile to: `zig build check-views`). Link ids (a
/// run's `k`) are left out: a view numbers its own.
pub fn props(gpa: std.mem.Allocator, root: *const Snap, out: *Writer) !void {
    try propsOf(gpa, root, out, 0);
}

fn propsOf(gpa: std.mem.Allocator, s: *const Snap, out: *Writer, depth: usize) !void {
    if (depth > tree.max_walk_depth) return error.TooDeep;
    try snapJson(gpa, s.kind, s.props, out);
    try out.writeAll("\n");
    for (s.kids) |*k| try propsOf(gpa, k, out, depth + 1);
}

/// A node's kind and props as one JSON object, link ids left out.
pub fn nodeJson(gpa: std.mem.Allocator, n: *const Node, out: *Writer) !void {
    try snapJson(gpa, n.kind, n.props, out);
}

fn snapJson(gpa: std.mem.Allocator, kind: tree.Kind, props_in: Props, out: *Writer) !void {
    var p = props_in;
    var runs_copy: std.ArrayList(tree.Run) = .empty;
    defer runs_copy.deinit(gpa);
    if (p.runs) |rs| {
        try runs_copy.appendSlice(gpa, rs);
        for (runs_copy.items) |*r| r.k = if (r.k != null) 0 else null;
        p.runs = runs_copy.items;
    }
    try std.json.Stringify.value(.{ .kind = @tagName(kind), .props = p }, .{ .emit_null_optional_fields = false }, out);
}

fn testTree(t: *tree.Tree, comptime source: []const u8) !*Node {
    const ui = @import("ui.zig");
    const V = ui.View(source);
    try V.prepare(t, 10);
    _ = try V.mount(t, 100, 10, &.{});
    return t.get(100).?;
}

fn testMeasure(_: *anyopaque, _: *Node, _: f32, out: *[2]f32) void {
    out.* = .{ 40, 18 };
}

test "a tree is written as the view it came from" {
    var ctx: u8 = 0;
    var t = tree.Tree.init(std.testing.allocator, &ctx, testMeasure);
    defer t.deinit();
    const root = try testTree(&t,
        \\<column id="main" padding="8,12,8,12" font-family="system-ui" color="#e8eaee" background="#10141a">
        \\  <row gap="6" border-width="0,0,1,0" border-color="#30363d" radius="4,4,0,0">
        \\    <text font-weight="700">A &lt;b&gt; &amp; "c"</text>
        \\    <text>Read <span underline="true" link="docs" color="#58a6ff">the docs</span>,&#32;&#32;now</text>
        \\  </row>
        \\  <icon viewbox="0,0,16,16" width="16" height="16"><path d="M0 0L16 16" stroke="#ff0000" fill="none" /></icon>
        \\  <input id="name" value="x" placeholder="Name" unset="font-size color" />
        \\  <view gradient-stops="255,0,0,1,0; 0,0,255,0.5,1" gradient-angle="90" visible="false"><text unset="font-family">hidden</text></view>
        \\</column>
    );
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var names: Names = .empty;
    try names.put(arena.allocator(), 100, "main");
    try names.put(arena.allocator(), 105, "name");
    var buf: Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const variants = [_]Variant{.{ .root = try snapshot(arena.allocator(), root, &.{}) }};
    const count = try view(std.testing.allocator, &variants, &names, &buf.writer);
    try std.testing.expectEqual(@as(usize, 8), count);
    try std.testing.expectEqualStrings(
        \\<column id="main" padding="8,12,8,12" background="#10141a" color="#e8eaee" font-family="system-ui">
        \\  <row border-width="0,0,1,0" border-color="#30363d" row-gap="6" column-gap="6" radius="4,4,0,0">
        \\    <text font-weight="700">A &lt;b> &amp; "c"</text>
        \\    <text><span>Read </span><span color="#58a6ff" underline="true" link="link-108">the docs</span><span>, &#32;now</span></text>
        \\  </row>
        \\  <icon width="16" height="16" viewbox="0,0,16,16">
        \\    <path d="M0 0L16 16" fill="none" stroke="#ff0000" />
        \\  </icon>
        \\  <input id="name" value="x" placeholder="Name" unset="color font-size" />
        \\  <view gradient-stops="255,0,0,1,0; 0,0,255,0.5,1" gradient-angle="90" visible="false">
        \\    <text unset="font-family">hidden</text>
        \\  </view>
        \\</column>
        \\
    , buf.written());
}

test "variants become the elements' styles and media blocks" {
    var ctx: u8 = 0;
    var light_tree = tree.Tree.init(std.testing.allocator, &ctx, testMeasure);
    defer light_tree.deinit();
    var dark_tree = tree.Tree.init(std.testing.allocator, &ctx, testMeasure);
    defer dark_tree.deinit();
    const light = try testTree(&light_tree,
        \\<column background="#ffffff"><text color="#111111">Hi</text><text id="caption" color="#666666">Caption</text></column>
    );
    const dark = try testTree(&dark_tree,
        \\<column background="#101010"><text color="#eeeeee">Hi</text></column>
    );
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var names: Names = .empty;
    try names.put(arena.allocator(), 102, "caption");
    const variants = [_]Variant{
        .{ .root = try snapshot(arena.allocator(), light, &.{}) },
        .{ .root = try snapshot(arena.allocator(), dark, &.{}), .media = "prefers-color-scheme: dark" },
    };
    var buf: Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    _ = try view(std.testing.allocator, &variants, &names, &buf.writer);
    try std.testing.expectEqualStrings(
        \\<style>
        \\  n1: background=#ffffff
        \\  n2: color=#111111
        \\  @media (prefers-color-scheme: dark) {
        \\    n1: background=#101010
        \\    n2: color=#eeeeee
        \\    caption: display=none
        \\  }
        \\</style>
        \\<column class="n1">
        \\  <text class="n2">Hi</text>
        \\  <text id="caption" class="caption" color="#666666">Caption</text>
        \\</column>
        \\
    , buf.written());
}
