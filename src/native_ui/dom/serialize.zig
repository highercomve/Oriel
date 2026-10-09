//! HTML serialization of the document store (innerHTML, outerHTML): UTF-8
//! into a reused buffer. Names and 8-bit (Latin-1) strings are read in
//! place; wide strings go through one UTF-8 conversion.
//!
//! As browsers: text escapes &, <, > and U+00A0 (except under raw text
//! elements: script, style…), attribute values escape &, " and U+00A0,
//! void elements have no end tag, comments are <!--…-->.

const std = @import("std");
const st = @import("store.zig");
const sel = @import("selector.zig");

const Store = st.Store;
const Index = st.Index;
const none = st.none;

pub const Host = struct {
    ctx: *anyopaque,
    /// An atom's 8-bit characters in place, or null.
    atomLatin1: *const fn (ctx: *anyopaque, atom: u32, len: *usize) ?[*]const u8,
    /// An atom as UTF-8 (to free with freeUtf8), or null.
    atomUtf8: *const fn (ctx: *anyopaque, atom: u32, len: *usize) ?[*]const u8,
    strings: sel.Host,
};

const void_elements = [_][]const u8{ "area", "base", "br", "col", "embed", "hr", "img", "input", "keygen", "link", "meta", "param", "source", "track", "wbr" };
const raw_text = [_][]const u8{ "script", "style", "xmp", "iframe", "noembed", "noframes", "plaintext", "noscript" };

fn isIn(comptime list: []const []const u8, name: []const u8) bool {
    inline for (list) |x| if (std.mem.eql(u8, x, name)) return true;
    return false;
}

pub const Serializer = struct {
    store: *Store,
    host: Host,
    gpa: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,
    /// A name's UTF-8, valid until the next call.
    name_buf: std.ArrayList(u8) = .empty,

    pub fn deinit(z: *Serializer) void {
        z.out.deinit(z.gpa);
        z.name_buf.deinit(z.gpa);
    }

    /// Latin-1 bytes as UTF-8, escaped for text or attribute values.
    fn putLatin1(z: *Serializer, bytes: []const u8, mode: Mode) !void {
        for (bytes) |c| try z.putChar(c, mode);
    }

    const Mode = enum { raw, text, attr };

    fn putChar(z: *Serializer, c: u21, mode: Mode) !void {
        if (mode != .raw) switch (c) {
            '&' => return z.out.appendSlice(z.gpa, "&amp;"),
            '<' => if (mode == .text) return z.out.appendSlice(z.gpa, "&lt;"),
            '>' => if (mode == .text) return z.out.appendSlice(z.gpa, "&gt;"),
            '"' => if (mode == .attr) return z.out.appendSlice(z.gpa, "&quot;"),
            0xa0 => return z.out.appendSlice(z.gpa, "&nbsp;"),
            else => {},
        };
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(c, &buf) catch return z.out.appendSlice(z.gpa, "\u{fffd}");
        try z.out.appendSlice(z.gpa, buf[0..n]);
    }

    fn putValue(z: *Serializer, v: *const st.JsVal, mode: Mode) !void {
        const h = z.host.strings;
        var len: usize = 0;
        if (h.latin1(h.ctx, v, &len)) |p| return z.putLatin1(p[0..len], mode);
        const u = h.toUtf8(h.ctx, v, &len) orelse return error.OutOfMemory;
        defer h.freeUtf8(h.ctx, u);
        const bytes = u[0..len];
        if (mode == .raw) return z.out.appendSlice(z.gpa, bytes);
        var it = std.unicode.Utf8View.initUnchecked(bytes).iterator();
        while (it.nextCodepoint()) |c| try z.putChar(c, mode);
    }

    /// An atom's name as UTF-8 (lowercase already for HTML names).
    fn name(z: *Serializer, atom: u32) ![]const u8 {
        var len: usize = 0;
        if (z.host.atomLatin1(z.host.ctx, atom, &len)) |p| {
            z.name_buf.clearRetainingCapacity();
            for (p[0..len]) |c| {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c, &buf) catch unreachable;
                try z.name_buf.appendSlice(z.gpa, buf[0..n]);
            }
            return z.name_buf.items;
        }
        const u = z.host.atomUtf8(z.host.ctx, atom, &len) orelse return error.OutOfMemory;
        defer z.host.strings.freeUtf8(z.host.strings.ctx, u);
        z.name_buf.clearRetainingCapacity();
        try z.name_buf.appendSlice(z.gpa, u[0..len]);
        return z.name_buf.items;
    }

    /// Writes a node's start: an element's start tag, a text's or a
    /// comment's whole markup. True when its children and end tag follow.
    fn open(z: *Serializer, idx: Index, raw_parent: bool) !bool {
        const s = z.store;
        const n = s.get(idx);
        switch (n.kind) {
            .text => if (n.has_data) try z.putValue(&n.data, if (raw_parent) .raw else .text),
            .comment => {
                try z.out.appendSlice(z.gpa, "<!--");
                if (n.has_data) try z.putValue(&n.data, .raw);
                try z.out.appendSlice(z.gpa, "-->");
            },
            .element => {
                const tag = try z.gpa.dupe(u8, try z.name(n.name));
                defer z.gpa.free(tag);
                try z.out.append(z.gpa, '<');
                try z.out.appendSlice(z.gpa, tag);
                var i: usize = 0;
                while (s.attrAt(idx, i)) |a| : (i += 1) {
                    try z.out.append(z.gpa, ' ');
                    try z.out.appendSlice(z.gpa, try z.name(a.name));
                    try z.out.appendSlice(z.gpa, "=\"");
                    try z.putValue(&a.value, .attr);
                    try z.out.append(z.gpa, '"');
                }
                try z.out.append(z.gpa, '>');
                return !isIn(&void_elements, tag);
            },
            .document, .fragment => return true,
            .free => {},
        }
        return false;
    }

    /// An element's end tag (others have none).
    fn close(z: *Serializer, idx: Index) !void {
        const n = z.store.get(idx);
        if (n.kind != .element) return;
        try z.out.appendSlice(z.gpa, "</");
        try z.out.appendSlice(z.gpa, try z.name(n.name));
        try z.out.append(z.gpa, '>');
    }

    /// Whether a text node's parent is a raw text element (script, style…).
    fn rawParent(z: *Serializer, idx: Index) !bool {
        const p = z.store.get(idx).parent;
        if (p == none) return false;
        const n = z.store.get(p);
        return n.kind == .element and isIn(&raw_text, try z.name(n.name));
    }

    /// `root` (outer) or its children, in document order without recursion
    /// (the page can make a tree of any depth).
    fn walk(z: *Serializer, root: Index, outer: bool) !void {
        const s = z.store;
        var idx = if (outer) root else s.get(root).first;
        if (idx == none) return;
        while (true) {
            // The outer node is written as if it had no parent.
            const raw = s.get(idx).kind == .text and !(outer and idx == root) and try z.rawParent(idx);
            if (try z.open(idx, raw)) {
                const first = s.get(idx).first;
                if (first != none) {
                    idx = first;
                    continue;
                }
                try z.close(idx);
            }
            // Done with idx: its next sibling, else the parents it ends.
            while (true) {
                if (outer and idx == root) return;
                const next = s.get(idx).next;
                if (next != none) {
                    idx = next;
                    break;
                }
                idx = s.get(idx).parent;
                if (!outer and idx == root) return;
                try z.close(idx);
            }
        }
    }

    /// The markup of a node (outer) or of its children (inner), in `out`.
    pub fn serialize(z: *Serializer, idx: Index, outer: bool) ![]const u8 {
        z.out.clearRetainingCapacity();
        try z.walk(idx, outer);
        return z.out.items;
    }
};
