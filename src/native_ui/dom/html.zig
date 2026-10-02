//! HTML fragments into the document store (innerHTML, outerHTML,
//! insertAdjacentHTML): a tokenizer and a small tree builder, building nodes
//! straight from the markup. Names become QuickJS atoms and text becomes
//! QuickJS strings through the store's `Js` callbacks; the markup is read in
//! place (entities are decoded into a reused buffer only where present).
//!
//! The tree builder follows what linkedom's parser (htmlparser2) does, which
//! pages built for the native renderer already rely on: void elements, raw
//! text elements (script, style, textarea, title…), the common implied end
//! tags (p, li, dt/dd, option, table parts), end tags closing the nearest
//! open element of that name and stray end tags ignored. Not the full HTML5
//! tree construction (no foster parenting, no adoption agency).

const std = @import("std");
const st = @import("store.zig");

pub const Error = st.Error;

/// What the parser needs from QuickJS (dom_qjs.c): new strings and atoms,
/// each returned with one reference that the caller owns.
pub const Make = struct {
    ctx: *anyopaque,
    string: *const fn (ctx: *anyopaque, bytes: [*]const u8, len: usize, out: *st.JsVal) bool,
    atom: *const fn (ctx: *anyopaque, bytes: [*]const u8, len: usize) u32,
    free: *const fn (ctx: *anyopaque, v: *const st.JsVal) void,
    freeAtom: *const fn (ctx: *anyopaque, a: u32) void,
};

const void_elements = [_][]const u8{ "area", "base", "br", "col", "embed", "hr", "img", "input", "keygen", "link", "meta", "param", "source", "track", "wbr" };
const raw_text = [_][]const u8{ "script", "style", "textarea", "title", "xmp", "noscript", "iframe", "noembed", "noframes", "plaintext" };

fn isIn(comptime list: []const []const u8, name: []const u8) bool {
    inline for (list) |x| if (std.mem.eql(u8, x, name)) return true;
    return false;
}

/// What the implied end tag rules need to know about an open element.
const Class = enum { p, li, dt_dd, option, optgroup, tr, cell, section, other };

fn classOf(name: []const u8) Class {
    const eq = std.mem.eql;
    if (eq(u8, name, "p")) return .p;
    if (eq(u8, name, "li")) return .li;
    if (eq(u8, name, "dt") or eq(u8, name, "dd")) return .dt_dd;
    if (eq(u8, name, "option")) return .option;
    if (eq(u8, name, "optgroup")) return .optgroup;
    if (eq(u8, name, "tr")) return .tr;
    if (eq(u8, name, "td") or eq(u8, name, "th")) return .cell;
    if (eq(u8, name, "thead") or eq(u8, name, "tbody")) return .section;
    return .other;
}

/// An open element of class `open` closed implicitly by a start tag `tag`.
fn impliedEnd(open: Class, tag: []const u8) bool {
    const eq = std.mem.eql;
    return switch (open) {
        .p => isIn(&.{ "address", "article", "aside", "blockquote", "details", "div", "dl", "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hgroup", "hr", "main", "menu", "nav", "ol", "p", "pre", "section", "table", "ul" }, tag),
        .li => eq(u8, tag, "li"),
        .dt_dd => eq(u8, tag, "dt") or eq(u8, tag, "dd"),
        .option => eq(u8, tag, "option") or eq(u8, tag, "optgroup"),
        .optgroup => eq(u8, tag, "optgroup"),
        .tr => eq(u8, tag, "tr") or eq(u8, tag, "tbody") or eq(u8, tag, "thead") or eq(u8, tag, "tfoot"),
        .cell => isIn(&.{ "td", "th", "tr", "tbody", "thead", "tfoot" }, tag),
        .section => eq(u8, tag, "tbody") or eq(u8, tag, "tfoot"),
        .other => false,
    };
}

const named_entities = std.StaticStringMap([]const u8).initComptime(.{
    .{ "amp", "&" },    .{ "lt", "<" },       .{ "gt", ">" },       .{ "quot", "\"" },
    .{ "apos", "'" },   .{ "nbsp", "\u{a0}" }, .{ "copy", "\u{a9}" }, .{ "reg", "\u{ae}" },
    .{ "trade", "\u{2122}" }, .{ "hellip", "\u{2026}" }, .{ "mdash", "\u{2014}" }, .{ "ndash", "\u{2013}" },
    .{ "lsquo", "\u{2018}" }, .{ "rsquo", "\u{2019}" }, .{ "ldquo", "\u{201c}" }, .{ "rdquo", "\u{201d}" },
    .{ "bull", "\u{2022}" }, .{ "middot", "\u{b7}" }, .{ "times", "\u{d7}" }, .{ "divide", "\u{f7}" },
    .{ "laquo", "\u{ab}" }, .{ "raquo", "\u{bb}" }, .{ "euro", "\u{20ac}" }, .{ "deg", "\u{b0}" },
    .{ "larr", "\u{2190}" }, .{ "rarr", "\u{2192}" }, .{ "uarr", "\u{2191}" }, .{ "darr", "\u{2193}" },
    .{ "check", "\u{2713}" }, .{ "hearts", "\u{2665}" }, .{ "star", "\u{2606}" }, .{ "para", "\u{b6}" },
    .{ "sect", "\u{a7}" }, .{ "shy", "\u{ad}" }, .{ "zwj", "\u{200d}" }, .{ "zwnj", "\u{200c}" },
});

/// Decodes entities in `raw` into `buf` (cleared first); returns the text,
/// which is `raw` itself when it has none.
fn decode(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), raw: []const u8) Error![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '&') == null) return raw;
    buf.clearRetainingCapacity();
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (c != '&') {
            try buf.append(gpa, c);
            i += 1;
            continue;
        }
        const rest = raw[i + 1 ..];
        if (rest.len > 0 and rest[0] == '#') {
            var j: usize = 1;
            const hex = j < rest.len and (rest[j] == 'x' or rest[j] == 'X');
            if (hex) j += 1;
            const start = j;
            while (j < rest.len and (if (hex) std.ascii.isHex(rest[j]) else std.ascii.isDigit(rest[j]))) j += 1;
            if (j > start and j - start <= 8) {
                var cp = std.fmt.parseInt(u32, rest[start..j], if (hex) 16 else 10) catch 0xfffd;
                if (cp == 0 or cp > 0x10ffff or (cp >= 0xd800 and cp <= 0xdfff)) cp = 0xfffd;
                var tmp: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(@intCast(cp), &tmp) catch 0;
                try buf.appendSlice(gpa, tmp[0..n]);
                i += 1 + j + @intFromBool(j < rest.len and rest[j] == ';');
                continue;
            }
        } else {
            var j: usize = 0;
            while (j < rest.len and j < 32 and std.ascii.isAlphanumeric(rest[j])) j += 1;
            if (j > 0 and j < rest.len and rest[j] == ';') {
                if (named_entities.get(rest[0..j])) |s| {
                    try buf.appendSlice(gpa, s);
                    i += 2 + j;
                    continue;
                }
            }
        }
        try buf.append(gpa, '&');
        i += 1;
    }
    return buf.items;
}

pub const Parser = struct {
    store: *st.Store,
    make: Make,
    gpa: std.mem.Allocator,
    /// Reused across parses: the decode buffer, the lowercase name buffer
    /// and the open elements (each held by the tree while it's open).
    text_buf: std.ArrayList(u8) = .empty,
    name_buf: std.ArrayList(u8) = .empty,
    open: std.ArrayList(Open) = .empty,

    const Open = struct { node: st.Index, atom: u32, class: Class, foreign: bool };

    fn inForeign(p: *Parser) bool {
        return p.open.items.len > 0 and p.open.items[p.open.items.len - 1].foreign;
    }

    pub fn deinit(p: *Parser) void {
        p.text_buf.deinit(p.gpa);
        p.name_buf.deinit(p.gpa);
        p.open.deinit(p.gpa);
    }

    /// `s` lowercased: itself, or a copy in name_buf (valid until the
    /// next call).
    fn lower(p: *Parser, s: []const u8) Error![]const u8 {
        for (s) |c| if (std.ascii.isUpper(c)) {
            p.name_buf.clearRetainingCapacity();
            try p.name_buf.ensureTotalCapacity(p.gpa, s.len);
            for (s) |d| p.name_buf.appendAssumeCapacity(std.ascii.toLower(d));
            return p.name_buf.items;
        };
        return s;
    }

    fn newString(p: *Parser, bytes: []const u8) Error!st.JsVal {
        var v: st.JsVal = undefined;
        if (!p.make.string(p.make.ctx, bytes.ptr, bytes.len, &v)) return error.OutOfMemory;
        return v;
    }

    fn newAtom(p: *Parser, bytes: []const u8) Error!u32 {
        const a = p.make.atom(p.make.ctx, bytes.ptr, bytes.len);
        if (a == 0) return error.OutOfMemory;
        return a;
    }

    fn parentNow(p: *Parser, root: st.Index) st.Index {
        return if (p.open.items.len > 0) p.open.items[p.open.items.len - 1].node else root;
    }

    /// A text or comment node under the current parent.
    fn addData(p: *Parser, parent: st.Index, kind: st.Kind, raw: []const u8, do_decode: bool) Error!void {
        if (raw.len == 0) return;
        const bytes = if (do_decode) try decode(p.gpa, &p.text_buf, raw) else raw;
        var v = try p.newString(bytes);
        defer p.make.free(p.make.ctx, &v);
        const node = try p.store.createData(kind, &v);
        p.store.appendChild(parent, node) catch |e| {
            p.store.dropIfUnused(node);
            return e;
        };
    }

    /// Parses `markup` and appends what it makes to `root` (an element or
    /// a fragment). On an error what was appended so far stays.
    pub fn parse(p: *Parser, root: st.Index, markup: []const u8) Error!void {
        p.open.clearRetainingCapacity();
        defer p.open.clearRetainingCapacity();
        const s = markup;
        var i: usize = 0;
        while (i < s.len) {
            const lt = std.mem.indexOfScalarPos(u8, s, i, '<') orelse s.len;
            if (lt > i) try p.addData(p.parentNow(root), .text, s[i..lt], true);
            if (lt >= s.len) break;
            i = lt;
            const rest = s[i..];
            if (std.mem.startsWith(u8, rest, "<!--")) {
                const end = std.mem.indexOfPos(u8, s, i + 4, "-->") orelse s.len;
                try p.addData(p.parentNow(root), .comment, s[i + 4 .. end], false);
                i = if (end == s.len) s.len else end + 3;
                continue;
            }
            if (rest.len > 1 and (rest[1] == '!' or rest[1] == '?')) {
                // <!doctype …>, <?xml …?>: skipped
                i = if (std.mem.indexOfScalarPos(u8, s, i, '>')) |gt| gt + 1 else s.len;
                continue;
            }
            const closing = rest.len > 1 and rest[1] == '/';
            var j = i + 1 + @intFromBool(closing);
            const name_start = j;
            while (j < s.len and (std.ascii.isAlphanumeric(s[j]) or s[j] == '-' or s[j] == ':' or s[j] == '_' or s[j] == '.')) j += 1;
            if (j == name_start or !std.ascii.isAlphabetic(s[name_start])) {
                // Not a tag: "<" is text.
                try p.addData(p.parentNow(root), .text, "<", false);
                i += 1;
                continue;
            }
            if (closing) {
                const name = if (p.inForeign()) s[name_start..j] else try p.lower(s[name_start..j]);
                i = if (std.mem.indexOfScalarPos(u8, s, j, '>')) |gt| gt + 1 else s.len;
                const atom = try p.newAtom(name);
                defer p.make.freeAtom(p.make.ctx, atom);
                // Closes the nearest open element of that name (and those
                // above it); a stray end tag is ignored, except </p> and
                // </br>, which make the element (as browsers do).
                var k = p.open.items.len;
                const found = while (k > 0) {
                    k -= 1;
                    if (p.open.items[k].atom == atom) {
                        p.open.shrinkRetainingCapacity(k);
                        break true;
                    }
                } else false;
                if (!found and (std.mem.eql(u8, name, "p") or std.mem.eql(u8, name, "br"))) {
                    const el = try p.store.createElement(atom);
                    p.store.appendChild(p.parentNow(root), el) catch |e| {
                        p.store.dropIfUnused(el);
                        return e;
                    };
                }
                continue;
            }
            j = try p.startTag(root, s, name_start, j);
            i = j;
        }
    }

    /// A start tag whose name is s[name_start..name_end]: the element, its
    /// attributes and, for raw text elements, their text. Returns where the
    /// markup goes on.
    fn startTag(p: *Parser, root: st.Index, s: []const u8, name_start: usize, name_end: usize) Error!usize {
        // The lowercase name, kept in a small local buffer for the rules
        // below (name_buf is reused for the attributes).
        var name_local: [32]u8 = undefined;
        // Foreign content (SVG, MathML) keeps its names' case: viewBox,
        // linearGradient.
        const foreign = p.inForeign() or std.ascii.eqlIgnoreCase(s[name_start..name_end], "svg") or std.ascii.eqlIgnoreCase(s[name_start..name_end], "math");
        const lname = if (foreign and !std.ascii.eqlIgnoreCase(s[name_start..name_end], "svg") and !std.ascii.eqlIgnoreCase(s[name_start..name_end], "math")) s[name_start..name_end] else try p.lower(s[name_start..name_end]);
        const name: []const u8 = if (lname.len <= name_local.len) blk: {
            @memcpy(name_local[0..lname.len], lname);
            break :blk name_local[0..lname.len];
        } else lname; // a long (custom) tag: none of the rules below
        // Everything the rules need from the name, before the attributes
        // reuse name_buf (a long name may point into it).
        const is_void = !foreign and isIn(&void_elements, name);
        const is_raw = !foreign and name.len <= name_local.len and isIn(&raw_text, name);
        const class = if (foreign) Class.other else classOf(name);
        if (!foreign) while (p.open.items.len > 0 and impliedEnd(p.open.items[p.open.items.len - 1].class, name)) {
            _ = p.open.pop();
        };
        const atom = try p.newAtom(name);
        const el = blk: {
            defer p.make.freeAtom(p.make.ctx, atom);
            break :blk try p.store.createElement(atom);
        };
        p.store.appendChild(p.parentNow(root), el) catch |e| {
            p.store.dropIfUnused(el);
            return e;
        };
        p.store.get(el).foreign = foreign;
        var self_closing = false;
        var j = name_end;
        while (j < s.len) {
            while (j < s.len and std.ascii.isWhitespace(s[j])) j += 1;
            if (j >= s.len) break;
            if (s[j] == '>') {
                j += 1;
                break;
            }
            if (s[j] == '/') {
                self_closing = j + 1 < s.len and s[j + 1] == '>';
                j += 1;
                continue;
            }
            const an_start = j;
            while (j < s.len and !std.ascii.isWhitespace(s[j]) and s[j] != '=' and s[j] != '>' and !(s[j] == '/' and j + 1 < s.len and s[j + 1] == '>')) j += 1;
            const attr_name = if (foreign) s[an_start..j] else try p.lower(s[an_start..j]);
            const an = try p.newAtom(attr_name);
            defer p.make.freeAtom(p.make.ctx, an);
            while (j < s.len and std.ascii.isWhitespace(s[j])) j += 1;
            var value: []const u8 = "";
            if (j < s.len and s[j] == '=') {
                j += 1;
                while (j < s.len and std.ascii.isWhitespace(s[j])) j += 1;
                if (j < s.len and (s[j] == '"' or s[j] == '\'')) {
                    const q = s[j];
                    const ve = std.mem.indexOfScalarPos(u8, s, j + 1, q) orelse s.len;
                    value = s[j + 1 .. ve];
                    j = @min(s.len, ve + 1);
                } else {
                    const vs = j;
                    while (j < s.len and !std.ascii.isWhitespace(s[j]) and s[j] != '>') j += 1;
                    value = s[vs..j];
                }
            }
            // The first of a repeated attribute wins (HTML).
            if (p.store.getAttr(el, an) != null) continue;
            var v = try p.newString(try decode(p.gpa, &p.text_buf, value));
            defer p.make.free(p.make.ctx, &v);
            try p.store.setAttr(el, an, &v);
        }
        // "/>" closes foreign elements; HTML ignores it on others.
        if (is_void or (foreign and self_closing)) return j;
        if (is_raw) {
            // Everything up to its end tag is text (with entities in
            // textarea and title).
            var e = j;
            const end = while (true) {
                const at = std.mem.indexOfPos(u8, s, e, "</") orelse break s.len;
                if (at + 2 + name.len <= s.len and std.ascii.eqlIgnoreCase(s[at + 2 .. at + 2 + name.len], name)) break at;
                e = at + 2;
            };
            const escapable = std.mem.eql(u8, name, "textarea") or std.mem.eql(u8, name, "title");
            try p.addData(el, .text, s[j..end], escapable);
            return if (end >= s.len) s.len else if (std.mem.indexOfScalarPos(u8, s, end, '>')) |gt| gt + 1 else s.len;
        }
        try p.open.append(p.gpa, .{ .node = el, .atom = p.store.get(el).name, .class = class, .foreign = foreign });
        return j;
    }
};
