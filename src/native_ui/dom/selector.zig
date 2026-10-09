//! CSS selectors on the document store (docs/native-dom.md): compiled once,
//! matched right to left. Tag names, ids and class tokens are atoms, so the
//! common tests are integer compares (elements keep their id and class
//! tokens as atoms: store.zig). Attribute values are compared in place when
//! the value is 8-bit (Latin-1) and the selector's text is ASCII, else
//! through one UTF-8 conversion.
//!
//! Supported: type, universal, #id, .class, [attr], [attr=v], ~=, |=, ^=,
//! $=, *= (with the i flag), the four combinators, :not() :is() :where()
//! :matches() :has(), :first-child :last-child :only-child :nth-child()
//! :nth-last-child() and their -of-type forms, :root :empty :checked
//! :disabled :enabled :link :any-link :focus-within, and :hover :focus
//! :focus-visible :active as the attributes the runtime moves
//! (data-nui-hover, data-nui-focus, data-nui-active). Pseudo-elements and
//! other pseudo-classes are a syntax error.

const std = @import("std");
const st = @import("store.zig");

const Store = st.Store;
const Index = st.Index;
const none = st.none;

pub const Error = error{ OutOfMemory, Syntax };

/// What compiling and matching need from QuickJS (dom_qjs.c).
pub const Host = struct {
    ctx: *anyopaque,
    /// An atom for a name (a new reference), 0 on failure.
    atom: *const fn (ctx: *anyopaque, bytes: [*]const u8, len: usize) u32,
    freeAtom: *const fn (ctx: *anyopaque, a: u32) void,
    /// A string value's 8-bit characters in place, or null (wide, rope).
    latin1: *const fn (ctx: *anyopaque, v: *const st.JsVal, len: *usize) ?[*]const u8,
    /// A string value as UTF-8 (to free with freeUtf8), or null on failure.
    toUtf8: *const fn (ctx: *anyopaque, v: *const st.JsVal, len: *usize) ?[*]const u8,
    freeUtf8: *const fn (ctx: *anyopaque, p: [*]const u8) void,
};

pub const AttrOp = enum { exists, equals, includes, dash, prefix, suffix, substring };

pub const AttrTest = struct { name: u32, op: AttrOp, value: []const u8 = "", icase: bool = false, ascii: bool = true };

pub const Nth = struct { a: i32, b: i32, of_type: bool, last: bool };

pub const Pseudo = union(enum) {
    nth: Nth,
    only_child,
    only_of_type,
    root,
    empty,
    enabled: u32, // the disabled attribute's atom
    focus_within: u32, // the focus attribute's atom
    not: []const Complex,
    is: []const Complex,
    has: []const Relative,
};

pub const Compound = struct {
    tag: u32 = 0, // 0: any
    id: u32 = 0,
    classes: []const u32 = &.{},
    attrs: []const AttrTest = &.{},
    pseudos: []const Pseudo = &.{},
};

pub const Comb = enum(u8) { descendant, child, next, subsequent };

/// Compounds left to right; combs[i] joins parts[i] and parts[i + 1].
pub const Complex = struct { parts: []const Compound, combs: []const Comb };

/// A :has() argument: a complex selector relative to the subject.
pub const Relative = struct { lead: Comb, complex: Complex };

pub const Selector = struct {
    arena: std.heap.ArenaAllocator,
    list: []const Complex,
    /// Every atom the compiled form holds (released by deinit).
    atoms: std.ArrayList(u32),
    host: Host,

    pub fn deinit(sel: *Selector) void {
        for (sel.atoms.items) |a| sel.host.freeAtom(sel.host.ctx, a);
        sel.atoms.deinit(sel.arena.child_allocator);
        sel.arena.deinit();
    }
};

// ---------------------------------------------------------------------
// Parsing

/// Limits on a selector's shape: compiling recurses per nested :not/:is/
/// :has, and matching per compound and nesting level (native stack frames
/// the page's JS stack limit doesn't count).
const max_nesting = 16;
const max_compounds = 32;

const Parser = struct {
    s: []const u8,
    i: usize = 0,
    a: std.mem.Allocator,
    gpa: std.mem.Allocator,
    host: Host,
    atoms: *std.ArrayList(u32),
    /// :not/:is/:has levels open.
    nesting: u8 = 0,

    fn peek(p: *Parser) u8 {
        return if (p.i < p.s.len) p.s[p.i] else 0;
    }

    fn ws(p: *Parser) bool {
        const start = p.i;
        while (p.i < p.s.len and std.ascii.isWhitespace(p.s[p.i])) p.i += 1;
        return p.i > start;
    }

    fn atom(p: *Parser, bytes: []const u8) Error!u32 {
        const a = p.host.atom(p.host.ctx, bytes.ptr, bytes.len);
        if (a == 0) return error.OutOfMemory;
        p.atoms.append(p.gpa, a) catch {
            p.host.freeAtom(p.host.ctx, a);
            return error.OutOfMemory;
        };
        return a;
    }

    fn isNameChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c >= 0x80;
    }

    /// An identifier (CSS escapes resolved), into the arena.
    fn ident(p: *Parser) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        while (p.i < p.s.len) {
            const c = p.s[p.i];
            if (c == '\\' and p.i + 1 < p.s.len) {
                p.i += 1;
                // \hex… or an escaped character
                var j = p.i;
                while (j < p.s.len and j - p.i < 6 and std.ascii.isHex(p.s[j])) j += 1;
                if (j > p.i) {
                    const cp = std.fmt.parseInt(u21, p.s[p.i..j], 16) catch 0xfffd;
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &buf) catch 0;
                    try out.appendSlice(p.a, buf[0..n]);
                    p.i = j;
                    if (p.i < p.s.len and std.ascii.isWhitespace(p.s[p.i])) p.i += 1;
                } else {
                    try out.append(p.a, p.s[p.i]);
                    p.i += 1;
                }
                continue;
            }
            if (!isNameChar(c)) break;
            try out.append(p.a, c);
            p.i += 1;
        }
        if (out.items.len == 0) return error.Syntax;
        return out.items;
    }

    fn lowered(p: *Parser, s: []const u8) Error![]const u8 {
        const out = try p.a.alloc(u8, s.len);
        for (s, 0..) |c, k| out[k] = std.ascii.toLower(c);
        return out;
    }

    fn list(p: *Parser, relative: bool) Error![]const Complex {
        var out: std.ArrayList(Complex) = .empty;
        while (true) {
            _ = p.ws();
            try out.append(p.a, try p.complex(relative, null));
            _ = p.ws();
            if (p.peek() != ',') break;
            p.i += 1;
        }
        return out.items;
    }

    fn complex(p: *Parser, relative: bool, lead_out: ?*Comb) Error!Complex {
        _ = relative;
        var parts: std.ArrayList(Compound) = .empty;
        var combs: std.ArrayList(Comb) = .empty;
        _ = p.ws();
        // A relative selector may start with a combinator (:has(> a)).
        if (lead_out) |lo| {
            lo.* = .descendant;
            switch (p.peek()) {
                '>' => {
                    lo.* = .child;
                    p.i += 1;
                },
                '+' => {
                    lo.* = .next;
                    p.i += 1;
                },
                '~' => {
                    lo.* = .subsequent;
                    p.i += 1;
                },
                else => {},
            }
            _ = p.ws();
        }
        try parts.append(p.a, try p.compound());
        while (true) {
            const had_ws = p.ws();
            const c = p.peek();
            const comb: Comb = switch (c) {
                '>' => .child,
                '+' => .next,
                '~' => .subsequent,
                ',', ')', 0 => break,
                else => if (had_ws) .descendant else return error.Syntax,
            };
            if (comb != .descendant) {
                p.i += 1;
                _ = p.ws();
            }
            try combs.append(p.a, comb);
            if (parts.items.len == max_compounds) return error.Syntax;
            try parts.append(p.a, try p.compound());
        }
        return .{ .parts = parts.items, .combs = combs.items };
    }

    fn compound(p: *Parser) Error!Compound {
        var c: Compound = .{};
        var classes: std.ArrayList(u32) = .empty;
        var attrs: std.ArrayList(AttrTest) = .empty;
        var pseudos: std.ArrayList(Pseudo) = .empty;
        var any = false;
        if (p.peek() == '*') {
            p.i += 1;
            any = true;
        } else if (isNameChar(p.peek()) or p.peek() == '\\') {
            c.tag = try p.atom(try p.lowered(try p.ident()));
            any = true;
        }
        while (true) {
            switch (p.peek()) {
                '#' => {
                    p.i += 1;
                    c.id = try p.atom(try p.ident());
                },
                '.' => {
                    p.i += 1;
                    try classes.append(p.a, try p.atom(try p.ident()));
                },
                '[' => {
                    p.i += 1;
                    try attrs.append(p.a, try p.attr());
                },
                ':' => {
                    p.i += 1;
                    if (p.peek() == ':') return error.Syntax; // pseudo-elements
                    try p.pseudo(&pseudos, &attrs);
                },
                else => break,
            }
            any = true;
        }
        if (!any) return error.Syntax;
        c.classes = classes.items;
        c.attrs = attrs.items;
        c.pseudos = pseudos.items;
        return c;
    }

    fn attr(p: *Parser) Error!AttrTest {
        _ = p.ws();
        const name = try p.atom(try p.lowered(try p.ident()));
        _ = p.ws();
        var t: AttrTest = .{ .name = name, .op = .exists };
        const c = p.peek();
        if (c == ']') {
            p.i += 1;
            return t;
        }
        t.op = switch (c) {
            '=' => .equals,
            '~' => .includes,
            '|' => .dash,
            '^' => .prefix,
            '$' => .suffix,
            '*' => .substring,
            else => return error.Syntax,
        };
        p.i += 1;
        if (t.op != .equals) {
            if (p.peek() != '=') return error.Syntax;
            p.i += 1;
        }
        _ = p.ws();
        const q = p.peek();
        if (q == '"' or q == '\'') {
            p.i += 1;
            const end = std.mem.indexOfScalarPos(u8, p.s, p.i, q) orelse return error.Syntax;
            t.value = try p.a.dupe(u8, p.s[p.i..end]);
            p.i = end + 1;
        } else {
            t.value = try p.ident();
        }
        _ = p.ws();
        if (p.peek() == 'i' or p.peek() == 'I') {
            t.icase = true;
            p.i += 1;
            _ = p.ws();
        } else if (p.peek() == 's' or p.peek() == 'S') {
            p.i += 1;
            _ = p.ws();
        }
        if (p.peek() != ']') return error.Syntax;
        p.i += 1;
        for (t.value) |ch| if (ch >= 0x80) {
            t.ascii = false;
        };
        if (t.icase) t.value = try p.lowered(t.value);
        return t;
    }

    fn nth(p: *Parser) Error![2]i32 {
        _ = p.ws();
        const start = p.i;
        while (p.i < p.s.len and p.s[p.i] != ')') p.i += 1;
        var arg = std.mem.trim(u8, p.s[start..p.i], " \t\n");
        // "of S" isn't supported
        if (std.mem.indexOf(u8, arg, " of ") != null) return error.Syntax;
        if (std.ascii.eqlIgnoreCase(arg, "odd")) return .{ 2, 1 };
        if (std.ascii.eqlIgnoreCase(arg, "even")) return .{ 2, 0 };
        var buf: [32]u8 = undefined;
        var n: usize = 0;
        for (arg) |ch| if (!std.ascii.isWhitespace(ch)) {
            if (n == buf.len) return error.Syntax;
            buf[n] = std.ascii.toLower(ch);
            n += 1;
        };
        arg = buf[0..n];
        if (std.mem.indexOfScalar(u8, arg, 'n')) |k| {
            const a_str = arg[0..k];
            const a: i32 = if (a_str.len == 0 or std.mem.eql(u8, a_str, "+")) 1 else if (std.mem.eql(u8, a_str, "-")) -1 else std.fmt.parseInt(i32, a_str, 10) catch return error.Syntax;
            const rest = arg[k + 1 ..];
            const b: i32 = if (rest.len == 0) 0 else std.fmt.parseInt(i32, rest, 10) catch return error.Syntax;
            return .{ a, b };
        }
        return .{ 0, std.fmt.parseInt(i32, arg, 10) catch return error.Syntax };
    }

    fn pseudo(p: *Parser, out: *std.ArrayList(Pseudo), attrs: *std.ArrayList(AttrTest)) Error!void {
        const name = try p.lowered(try p.ident());
        const eq = std.mem.eql;
        const has_args = p.peek() == '(';
        if (has_args) p.i += 1;
        const P = Pseudo;
        if (has_args) {
            if (p.nesting == max_nesting) return error.Syntax;
            p.nesting += 1;
            defer p.nesting -= 1;
            if (eq(u8, name, "not") or eq(u8, name, "is") or eq(u8, name, "where") or eq(u8, name, "matches")) {
                const inner = try p.list(false);
                try out.append(p.a, if (eq(u8, name, "not")) P{ .not = inner } else P{ .is = inner });
            } else if (eq(u8, name, "has")) {
                var rel: std.ArrayList(Relative) = .empty;
                while (true) {
                    var lead: Comb = .descendant;
                    const cx = try p.complex(true, &lead);
                    try rel.append(p.a, .{ .lead = lead, .complex = cx });
                    _ = p.ws();
                    if (p.peek() != ',') break;
                    p.i += 1;
                }
                try out.append(p.a, .{ .has = rel.items });
            } else {
                const ab = try p.nth();
                const nth_kind: ?Nth = if (eq(u8, name, "nth-child")) .{ .a = ab[0], .b = ab[1], .of_type = false, .last = false } else if (eq(u8, name, "nth-last-child")) .{ .a = ab[0], .b = ab[1], .of_type = false, .last = true } else if (eq(u8, name, "nth-of-type")) .{ .a = ab[0], .b = ab[1], .of_type = true, .last = false } else if (eq(u8, name, "nth-last-of-type")) .{ .a = ab[0], .b = ab[1], .of_type = true, .last = true } else null;
                try out.append(p.a, .{ .nth = nth_kind orelse return error.Syntax });
            }
            _ = p.ws();
            if (p.peek() != ')') return error.Syntax;
            p.i += 1;
            return;
        }
        if (eq(u8, name, "first-child")) return out.append(p.a, .{ .nth = .{ .a = 0, .b = 1, .of_type = false, .last = false } });
        if (eq(u8, name, "last-child")) return out.append(p.a, .{ .nth = .{ .a = 0, .b = 1, .of_type = false, .last = true } });
        if (eq(u8, name, "first-of-type")) return out.append(p.a, .{ .nth = .{ .a = 0, .b = 1, .of_type = true, .last = false } });
        if (eq(u8, name, "last-of-type")) return out.append(p.a, .{ .nth = .{ .a = 0, .b = 1, .of_type = true, .last = true } });
        if (eq(u8, name, "only-child")) return out.append(p.a, .only_child);
        if (eq(u8, name, "only-of-type")) return out.append(p.a, .only_of_type);
        if (eq(u8, name, "root")) return out.append(p.a, .root);
        if (eq(u8, name, "empty")) return out.append(p.a, .empty);
        // States the runtime keeps as attributes (main.js).
        const as_attr: ?[]const u8 = if (eq(u8, name, "hover")) "data-nui-hover" else if (eq(u8, name, "focus") or eq(u8, name, "focus-visible")) "data-nui-focus" else if (eq(u8, name, "active")) "data-nui-active" else if (eq(u8, name, "checked")) "checked" else if (eq(u8, name, "disabled")) "disabled" else null;
        if (as_attr) |a| return attrs.append(p.a, .{ .name = try p.atom(a), .op = .exists });
        if (eq(u8, name, "link") or eq(u8, name, "any-link")) return attrs.append(p.a, .{ .name = try p.atom("href"), .op = .exists });
        if (eq(u8, name, "enabled")) return out.append(p.a, .{ .enabled = try p.atom("disabled") });
        if (eq(u8, name, "focus-within")) return out.append(p.a, .{ .focus_within = try p.atom("data-nui-focus") });
        return error.Syntax;
    }
};

/// Compiles a selector list (UTF-8). Errors: OutOfMemory, Syntax.
pub fn compile(gpa: std.mem.Allocator, host: Host, text: []const u8) Error!*Selector {
    const sel = try gpa.create(Selector);
    sel.* = .{ .arena = .init(gpa), .list = &.{}, .atoms = .empty, .host = host };
    errdefer {
        sel.deinit();
        gpa.destroy(sel);
    }
    var p: Parser = .{ .s = text, .a = sel.arena.allocator(), .gpa = gpa, .host = host, .atoms = &sel.atoms };
    sel.list = p.list(false) catch |e| return e;
    _ = p.ws();
    if (p.i != p.s.len) return error.Syntax;
    return sel;
}

pub fn destroy(gpa: std.mem.Allocator, sel: *Selector) void {
    sel.deinit();
    gpa.destroy(sel);
}

// ---------------------------------------------------------------------
// Matching

fn isElement(s: *Store, idx: Index) bool {
    return idx != none and s.get(idx).kind == .element;
}

fn parentElement(s: *Store, idx: Index) Index {
    const p = s.get(idx).parent;
    return if (isElement(s, p)) p else none;
}

fn prevElement(s: *Store, idx: Index) Index {
    var n = s.get(idx).prev;
    while (n != none and s.get(n).kind != .element) n = s.get(n).prev;
    return n;
}

fn nextElement(s: *Store, idx: Index) Index {
    var n = s.get(idx).next;
    while (n != none and s.get(n).kind != .element) n = s.get(n).next;
    return n;
}

fn lowerEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (std.ascii.toLower(x) != y) return false;
    return true;
}

fn attrMatches(m: *const Matcher, idx: Index, t: *const AttrTest) bool {
    const v = m.store.getAttr(idx, t.name) orelse return false;
    if (t.op == .exists) return true;
    var len: usize = 0;
    var owned: ?[*]const u8 = null;
    const bytes: []const u8 = blk: {
        if (t.ascii) if (m.host.latin1(m.host.ctx, v, &len)) |p| break :blk p[0..len];
        owned = m.host.toUtf8(m.host.ctx, v, &len) orelse return false;
        break :blk owned.?[0..len];
    };
    defer if (owned) |o| m.host.freeUtf8(m.host.ctx, o);
    const want = t.value;
    const eq: *const fn ([]const u8, []const u8) bool = if (t.icase) &lowerEql else &plainEql;
    return switch (t.op) {
        .exists => true,
        .equals => eq(bytes, want),
        .prefix => want.len > 0 and bytes.len >= want.len and eq(bytes[0..want.len], want),
        .suffix => want.len > 0 and bytes.len >= want.len and eq(bytes[bytes.len - want.len ..], want),
        .substring => want.len > 0 and (if (t.icase) containsLower(bytes, want) else std.mem.indexOf(u8, bytes, want) != null),
        .dash => eq(bytes, want) or (bytes.len > want.len and bytes[want.len] == '-' and eq(bytes[0..want.len], want)),
        .includes => blk: {
            if (want.len == 0 or std.mem.indexOfAny(u8, want, " \t\n\r\x0c") != null) break :blk false;
            var it = std.mem.tokenizeAny(u8, bytes, " \t\n\r\x0c");
            while (it.next()) |tok| if (eq(tok, want)) break :blk true;
            break :blk false;
        },
    };
}

fn plainEql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn containsLower(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) if (lowerEql(hay[i .. i + needle.len], needle)) return true;
    return false;
}

fn nthMatches(s: *Store, idx: Index, n: Nth) bool {
    // Position among siblings (1-based), counting elements (of the type).
    var pos: i64 = 1;
    const name = s.get(idx).name;
    var sib = if (n.last) nextElement(s, idx) else prevElement(s, idx);
    while (sib != none) : (sib = if (n.last) nextElement(s, sib) else prevElement(s, sib)) {
        if (!n.of_type or s.get(sib).name == name) pos += 1;
    }
    if (n.a == 0) return pos == n.b;
    // In i64: a and b are any i32 (`n-2147483648`, `-n+…`).
    const diff = pos - n.b;
    return @rem(diff, n.a) == 0 and @divTrunc(diff, n.a) >= 0;
}

pub const Matcher = struct {
    store: *Store,
    host: Host,

    fn compoundMatches(m: *const Matcher, idx: Index, c: *const Compound) bool {
        const s = m.store;
        const n = s.get(idx);
        if (n.kind != .element) return false;
        if (c.tag != 0 and n.name != c.tag) return false;
        if (c.id != 0 and n.id != c.id) return false;
        for (c.classes) |want| {
            var it = n.classList();
            const found = while (it.next()) |a| {
                if (a == want) break true;
            } else false;
            if (!found) return false;
        }
        for (c.attrs) |*t| if (!attrMatches(m, idx, t)) return false;
        for (c.pseudos) |ps| switch (ps) {
            .nth => |x| if (!nthMatches(s, idx, x)) return false,
            .only_child => if (prevElement(s, idx) != none or nextElement(s, idx) != none) return false,
            .only_of_type => if (!nthMatches(s, idx, .{ .a = 0, .b = 1, .of_type = true, .last = false }) or !nthMatches(s, idx, .{ .a = 0, .b = 1, .of_type = true, .last = true })) return false,
            .root => if (n.parent == none or s.get(n.parent).kind != .document) return false,
            .empty => {
                var ch = n.first;
                while (ch != none) : (ch = s.get(ch).next) {
                    const k = s.get(ch).kind;
                    if (k == .element) return false;
                    if (k == .text) {
                        var len: usize = 0;
                        const d = s.dataOf(ch) orelse continue;
                        if (m.host.latin1(m.host.ctx, d, &len) == null or len != 0) return false;
                    }
                }
            },
            .enabled => |dis| if (s.getAttr(idx, dis) != null) return false,
            .focus_within => |focus| {
                var found = false;
                var e = idx;
                // self or a descendant
                while (true) {
                    if (s.get(e).kind == .element and s.getAttr(e, focus) != null) {
                        found = true;
                        break;
                    }
                    if (s.get(e).first != none) {
                        e = s.get(e).first;
                        continue;
                    }
                    while (e != idx and s.get(e).next == none) e = s.get(e).parent;
                    if (e == idx) break;
                    e = s.get(e).next;
                }
                if (!found) return false;
            },
            .not => |list| for (list) |*cx| if (m.complexMatches(idx, cx)) return false,
            .is => |list| {
                const any = for (list) |*cx| {
                    if (m.complexMatches(idx, cx)) break true;
                } else false;
                if (!any) return false;
            },
            .has => |rels| {
                const any = for (rels) |*r| {
                    if (m.hasMatches(idx, r)) break true;
                } else false;
                if (!any) return false;
            },
        };
        return true;
    }

    /// parts[0..=i] matched with parts[i] at `idx`, the leftmost one
    /// related to `anchor` by `lead` (relative selectors), if any.
    fn from(m: *const Matcher, idx: Index, cx: *const Complex, i: usize, anchor: Index, lead: Comb) bool {
        const s = m.store;
        if (!m.compoundMatches(idx, &cx.parts[i])) return false;
        if (i == 0) {
            if (anchor == none) return true;
            return switch (lead) {
                .child => s.get(idx).parent == anchor,
                .descendant => blk: {
                    var p = s.get(idx).parent;
                    while (p != none) : (p = s.get(p).parent) if (p == anchor) break :blk true;
                    break :blk false;
                },
                .next => prevElement(s, idx) == anchor,
                .subsequent => blk: {
                    var p = prevElement(s, idx);
                    while (p != none) : (p = prevElement(s, p)) if (p == anchor) break :blk true;
                    break :blk false;
                },
            };
        }
        switch (cx.combs[i - 1]) {
            .child => {
                const p = parentElement(s, idx);
                return p != none and p != anchor and m.from(p, cx, i - 1, anchor, lead);
            },
            .descendant => {
                var p = parentElement(s, idx);
                while (p != none and p != anchor) : (p = parentElement(s, p)) if (m.from(p, cx, i - 1, anchor, lead)) return true;
                return false;
            },
            .next => {
                const p = prevElement(s, idx);
                return p != none and m.from(p, cx, i - 1, anchor, lead);
            },
            .subsequent => {
                var p = prevElement(s, idx);
                while (p != none) : (p = prevElement(s, p)) if (m.from(p, cx, i - 1, anchor, lead)) return true;
                return false;
            },
        }
    }

    pub fn complexMatches(m: *const Matcher, idx: Index, cx: *const Complex) bool {
        return m.from(idx, cx, cx.parts.len - 1, none, .descendant);
    }

    fn hasMatches(m: *const Matcher, subject: Index, r: *const Relative) bool {
        const s = m.store;
        switch (r.lead) {
            .descendant, .child => {
                // Elements in the subject's subtree.
                var e = s.get(subject).first;
                while (e != none) {
                    if (s.get(e).kind == .element and m.from(e, &r.complex, r.complex.parts.len - 1, subject, r.lead)) return true;
                    if (s.get(e).first != none and (r.lead == .descendant or r.complex.parts.len > 1)) {
                        e = s.get(e).first;
                        continue;
                    }
                    while (e != subject and s.get(e).next == none) e = s.get(e).parent;
                    if (e == subject) return false;
                    e = s.get(e).next;
                }
                return false;
            },
            .next, .subsequent => {
                // Following siblings (and their subtrees, for longer selectors).
                var e = nextElement(s, subject);
                while (e != none) : (e = nextElement(s, e)) {
                    if (m.from(e, &r.complex, r.complex.parts.len - 1, subject, r.lead)) return true;
                    if (r.lead == .next and r.complex.parts.len == 1) return false;
                }
                return false;
            },
        }
    }

    /// Whether the element matches the selector list.
    pub fn matches(m: *const Matcher, idx: Index, sel: *const Selector) bool {
        if (!isElement(m.store, idx)) return false;
        for (sel.list) |*cx| if (m.complexMatches(idx, cx)) return true;
        return false;
    }

    /// The elements under `root` (not root itself) in document order that
    /// match, each passed to `found` until it returns false.
    pub fn query(m: *const Matcher, root: Index, sel: *const Selector, ctx: *anyopaque, found: *const fn (ctx: *anyopaque, idx: Index) bool) void {
        const s = m.store;
        var e = s.get(root).first;
        while (e != none) {
            if (s.get(e).kind == .element and m.matches(e, sel)) {
                if (!found(ctx, e)) return;
            }
            if (s.get(e).first != none) {
                e = s.get(e).first;
                continue;
            }
            while (e != root and s.get(e).next == none) e = s.get(e).parent;
            if (e == root) return;
            e = s.get(e).next;
        }
    }
};

// ---------------------------------------------------------------------
// Tests: a store with real strings (interned atoms and string values).

const TestJs = struct {
    gpa: std.mem.Allocator,
    names: std.ArrayList([]const u8) = .empty, // atom - 1 → text
    strings: std.ArrayList([]const u8) = .empty, // value key - 1 → text

    fn of(c: *anyopaque) *TestJs {
        return @ptrCast(@alignCast(c));
    }
    fn deinit(t: *TestJs) void {
        for (t.names.items) |n| t.gpa.free(n);
        for (t.strings.items) |n| t.gpa.free(n);
        t.names.deinit(t.gpa);
        t.strings.deinit(t.gpa);
    }
    fn atomOf(t: *TestJs, bytes: []const u8) u32 {
        for (t.names.items, 0..) |n, i| if (std.mem.eql(u8, n, bytes)) return @intCast(i + 1);
        t.names.append(t.gpa, t.gpa.dupe(u8, bytes) catch unreachable) catch unreachable;
        return @intCast(t.names.items.len);
    }
    fn str(t: *TestJs, bytes: []const u8) st.JsVal {
        t.strings.append(t.gpa, t.gpa.dupe(u8, bytes) catch unreachable) catch unreachable;
        const k: i64 = @intCast(t.strings.items.len);
        return if (@sizeOf(usize) == 8) .{ .u = 0, .tag = k } else .{ .v = @intCast(k) };
    }
    fn keyOf(v: *const st.JsVal) usize {
        return @intCast(if (@sizeOf(usize) == 8) v.tag else @as(i64, @intCast(v.v)));
    }
    fn text(c: *anyopaque, v: *const st.JsVal) []const u8 {
        return of(c).strings.items[keyOf(v) - 1];
    }
    // Reference counting isn't checked here (store.zig's tests do).
    fn nop(_: *anyopaque, _: *const st.JsVal) void {}
    fn nopAtom(_: *anyopaque, _: u32) void {}
    fn valueAtom(c: *anyopaque, v: *const st.JsVal) u32 {
        return of(c).atomOf(text(c, v));
    }
    fn tokens(c: *anyopaque, v: *const st.JsVal, sink: *anyopaque, add: *const fn (*anyopaque, u32) bool) bool {
        var it = std.mem.tokenizeAny(u8, text(c, v), " ");
        while (it.next()) |tok| if (!add(sink, of(c).atomOf(tok))) return false;
        return true;
    }
    fn atomFn(c: *anyopaque, b: [*]const u8, len: usize) u32 {
        return of(c).atomOf(b[0..len]);
    }
    fn latin1(c: *anyopaque, v: *const st.JsVal, len: *usize) ?[*]const u8 {
        const tx = text(c, v);
        len.* = tx.len;
        return tx.ptr;
    }
    fn freeUtf8(_: *anyopaque, _: [*]const u8) void {}
    fn js(t: *TestJs) st.Js {
        return .{ .ctx = t, .dup = nop, .free = nop, .dupAtom = nopAtom, .freeAtom = nopAtom, .valueAtom = valueAtom, .tokens = tokens };
    }
    fn host(t: *TestJs) Host {
        return .{ .ctx = t, .atom = atomFn, .freeAtom = nopAtom, .latin1 = latin1, .toUtf8 = latin1, .freeUtf8 = freeUtf8 };
    }
};

test "selectors" {
    const ta = std.testing;
    var tj: TestJs = .{ .gpa = ta.allocator };
    defer tj.deinit();
    var s = try Store.init(ta.allocator, tj.js(), tj.atomOf("class"), tj.atomOf("id"));
    defer s.deinit();
    // <main id=app><ul class="list big"><li class=a>1</li><li class="a b" data-x="hello world">2</li><li>3</li></ul><p></p><p>x</p></main>
    const el = struct {
        fn mk(st_: *Store, t: *TestJs, parent: Index, tag: []const u8, attrs: []const [2][]const u8) !Index {
            const e = try st_.createElement(t.atomOf(tag));
            for (attrs) |a| {
                var v = t.str(a[1]);
                try st_.setAttr(e, t.atomOf(a[0]), &v);
            }
            try st_.appendChild(parent, e);
            return e;
        }
    }.mk;
    const main = try el(&s, &tj, s.document, "main", &.{.{ "id", "app" }});
    const ul = try el(&s, &tj, main, "ul", &.{.{ "class", "list big" }});
    const li1 = try el(&s, &tj, ul, "li", &.{.{ "class", "a" }});
    const li2 = try el(&s, &tj, ul, "li", &.{ .{ "class", "a b" }, .{ "data-x", "hello world" } });
    const li3 = try el(&s, &tj, ul, "li", &.{});
    const p1 = try el(&s, &tj, main, "p", &.{});
    const p2 = try el(&s, &tj, main, "p", &.{});
    var x = tj.str("x");
    const tx = try s.createData(.text, &x);
    try s.appendChild(p2, tx);

    const m: Matcher = .{ .store = &s, .host = tj.host() };
    const Case = struct { sel: []const u8, idx: Index, want: bool };
    const cases = [_]Case{
        .{ .sel = "li", .idx = li1, .want = true },
        .{ .sel = "LI", .idx = li1, .want = true },
        .{ .sel = "#app", .idx = main, .want = true },
        .{ .sel = ".a.b", .idx = li2, .want = true },
        .{ .sel = ".a.b", .idx = li1, .want = false },
        .{ .sel = "ul.list > li.a", .idx = li1, .want = true },
        .{ .sel = "main li", .idx = li3, .want = true },
        .{ .sel = "main > li", .idx = li3, .want = false },
        .{ .sel = "li + li", .idx = li1, .want = false },
        .{ .sel = "li + li", .idx = li2, .want = true },
        .{ .sel = ".a ~ li", .idx = li3, .want = true },
        .{ .sel = "[data-x]", .idx = li2, .want = true },
        .{ .sel = "[data-x=\"hello world\"]", .idx = li2, .want = true },
        .{ .sel = "[data-x^=hel]", .idx = li2, .want = true },
        .{ .sel = "[data-x$=orld]", .idx = li2, .want = true },
        .{ .sel = "[data-x*=\"o w\"]", .idx = li2, .want = true },
        .{ .sel = "[data-x~=world]", .idx = li2, .want = true },
        .{ .sel = "[data-x=HELLO\\ WORLD i]", .idx = li2, .want = true },
        .{ .sel = "[class|=list]", .idx = ul, .want = false },
        .{ .sel = "li:first-child", .idx = li1, .want = true },
        .{ .sel = "li:last-child", .idx = li3, .want = true },
        .{ .sel = "li:nth-child(2)", .idx = li2, .want = true },
        .{ .sel = "li:nth-child(odd)", .idx = li3, .want = true },
        .{ .sel = "li:nth-child(2n)", .idx = li3, .want = false },
        .{ .sel = "li:nth-last-child(1)", .idx = li3, .want = true },
        .{ .sel = "li:nth-child(n-2147483648)", .idx = li1, .want = true },
        .{ .sel = "li:nth-child(-n-2147483648)", .idx = li1, .want = false },
        .{ .sel = "li:nth-child(-n+2147483647)", .idx = li3, .want = true },
        .{ .sel = "p:first-of-type", .idx = p1, .want = true },
        .{ .sel = "p:last-of-type", .idx = p2, .want = true },
        .{ .sel = "p:empty", .idx = p1, .want = true },
        .{ .sel = "p:empty", .idx = p2, .want = false },
        .{ .sel = "main:root", .idx = main, .want = true },
        .{ .sel = "li:not(.a)", .idx = li3, .want = true },
        .{ .sel = "li:not(.a)", .idx = li1, .want = false },
        .{ .sel = ":is(ul, ol) > :where(.b)", .idx = li2, .want = true },
        .{ .sel = "ul:has(> .b)", .idx = ul, .want = true },
        .{ .sel = "main:has(li.b)", .idx = main, .want = true },
        .{ .sel = "main:has(> li)", .idx = main, .want = false },
        .{ .sel = "li.a:has(+ li.b)", .idx = li1, .want = true },
        .{ .sel = "ul:has(.zzz)", .idx = ul, .want = false },
        .{ .sel = "div, li", .idx = li3, .want = true },
        .{ .sel = "*", .idx = p1, .want = true },
    };
    for (cases) |c| {
        const sel = compile(ta.allocator, tj.host(), c.sel) catch |e| {
            std.debug.print("compile failed: {s}: {s}\n", .{ c.sel, @errorName(e) });
            return e;
        };
        defer destroy(ta.allocator, sel);
        if (m.matches(c.idx, sel) != c.want) {
            std.debug.print("selector {s}: expected {}\n", .{ c.sel, c.want });
            return error.TestUnexpectedResult;
        }
    }
    for ([_][]const u8{ "", "[data-x*=o w]", "li::before", "li:hoverx", "a >", "[x=", ":nth-child(x)", "li,", "a b c ) d" }) |bad| {
        try ta.expectError(error.Syntax, compile(ta.allocator, tj.host(), bad));
    }
    // querySelectorAll
    const Found = struct {
        list: std.ArrayList(Index) = .empty,
        fn add(c: *anyopaque, i: Index) bool {
            const f: *@This() = @ptrCast(@alignCast(c));
            f.list.append(ta.allocator, i) catch return false;
            return true;
        }
    };
    var found: Found = .{};
    defer found.list.deinit(ta.allocator);
    const all = try compile(ta.allocator, tj.host(), "li, p");
    defer destroy(ta.allocator, all);
    m.query(main, all, &found, Found.add);
    try ta.expectEqualSlices(Index, &.{ li1, li2, li3, p1, p2 }, found.list.items);
}

test "a tree of any depth serializes and clones without recursion; selectors are bounded" {
    const ta = std.testing;
    const serialize = @import("serialize.zig");
    var tj: TestJs = .{ .gpa = ta.allocator };
    defer tj.deinit();
    var s = try Store.init(ta.allocator, tj.js(), tj.atomOf("class"), tj.atomOf("id"));
    defer s.deinit();
    const Names = struct {
        fn latin1(c: *anyopaque, atom: u32, len: *usize) ?[*]const u8 {
            const n = TestJs.of(c).names.items[atom - 1];
            len.* = n.len;
            return n.ptr;
        }
        fn utf8(_: *anyopaque, _: u32, _: *usize) ?[*]const u8 {
            return null;
        }
    };
    var z: serialize.Serializer = .{ .store = &s, .gpa = ta.allocator, .host = .{ .ctx = &tj, .atomLatin1 = Names.latin1, .atomUtf8 = Names.utf8, .strings = tj.host() } };
    defer z.deinit();
    // <div><div>…<script>a<b</script>…</div>&lt;br&gt;</div>, 20000 levels deep (the
    // recursive walks took a native frame or more per level).
    const depth = 20_000;
    const top = try s.createElement(tj.atomOf("div"));
    var leaf = top;
    for (1..depth) |_| {
        const e = try s.createElement(tj.atomOf("div"));
        try s.appendChild(leaf, e);
        leaf = e;
    }
    const script = try s.createElement(tj.atomOf("script"));
    try s.appendChild(leaf, script);
    var code = tj.str("a<b");
    try s.appendChild(script, try s.createData(.text, &code));
    var br = tj.str("<br>");
    try s.appendChild(top, try s.createData(.text, &br));
    const copy = try s.clone(top, true);
    for ([_]Index{ top, copy }) |root| {
        const out = try z.serialize(root, true);
        try ta.expectEqual(depth * "<div></div>".len + "<script>a<b</script>&lt;br&gt;".len, out.len);
        try ta.expect(std.mem.startsWith(u8, out, "<div><div>"));
        try ta.expect(std.mem.indexOf(u8, out, "<script>a<b</script></div>") != null);
        try ta.expect(std.mem.endsWith(u8, out, "</div>&lt;br&gt;</div>"));
    }
    try ta.expectEqualStrings("a<b", try z.serialize(script, false));
    s.dropIfUnused(copy);
    s.dropIfUnused(top);
    // Nesting and length past the limits don't compile.
    var deep: std.ArrayList(u8) = .empty;
    defer deep.deinit(ta.allocator);
    for (0..max_nesting + 1) |_| try deep.appendSlice(ta.allocator, ":not(");
    try deep.append(ta.allocator, 'a');
    for (0..max_nesting + 1) |_| try deep.append(ta.allocator, ')');
    try ta.expectError(error.Syntax, compile(ta.allocator, tj.host(), deep.items));
    deep.clearRetainingCapacity();
    for (0..max_compounds + 1) |_| try deep.appendSlice(ta.allocator, "a ");
    try ta.expectError(error.Syntax, compile(ta.allocator, tj.host(), deep.items));
    destroy(ta.allocator, try compile(ta.allocator, tj.host(), deep.items[0 .. 2 * max_compounds - 1]));
}
