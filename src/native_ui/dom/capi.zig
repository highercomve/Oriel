//! The document store and HTML parser as C functions, for the QuickJS
//! bindings (dom_qjs.c). Indices are store indices (0 = none); errors are
//! negative codes (see `code`).

const std = @import("std");
const st = @import("store.zig");
const html = @import("html.zig");
const sel = @import("selector.zig");

const Store = st.Store;
const Index = st.Index;
const JsVal = st.JsVal;

/// What dom_qjs.c gives the store: reference counting and string/atom making.
pub const Host = extern struct {
    ctx: *anyopaque,
    dup: *const fn (ctx: *anyopaque, v: *const JsVal) callconv(.c) void,
    free: *const fn (ctx: *anyopaque, v: *const JsVal) callconv(.c) void,
    dup_atom: *const fn (ctx: *anyopaque, a: u32) callconv(.c) void,
    free_atom: *const fn (ctx: *anyopaque, a: u32) callconv(.c) void,
    new_string: *const fn (ctx: *anyopaque, bytes: [*]const u8, len: usize, out: *JsVal) callconv(.c) bool,
    new_atom: *const fn (ctx: *anyopaque, bytes: [*]const u8, len: usize) callconv(.c) u32,
    value_atom: *const fn (ctx: *anyopaque, v: *const JsVal) callconv(.c) u32,
    /// The tokens of a string value as atoms, each passed to `add` (which
    /// takes the reference); false on failure.
    tokens: *const fn (ctx: *anyopaque, v: *const JsVal, sink: *anyopaque, add: *const fn (sink: *anyopaque, atom: u32) callconv(.c) bool) callconv(.c) bool,
    /// A string value's 8-bit characters in place, or null.
    latin1: *const fn (ctx: *anyopaque, v: *const JsVal, len: *usize) callconv(.c) ?[*]const u8,
    /// A string value as UTF-8 (free with free_utf8), or null.
    to_utf8: *const fn (ctx: *anyopaque, v: *const JsVal, len: *usize) callconv(.c) ?[*]const u8,
    free_utf8: *const fn (ctx: *anyopaque, p: [*]const u8) callconv(.c) void,
};

/// One window's DOM: the store, its parser, compiled selectors (by text) and
/// the host functions.
pub const Dom = struct {
    store: Store,
    parser: html.Parser,
    host: Host,
    selectors: std.StringHashMapUnmanaged(*sel.Selector) = .empty,

    fn selHost(d: *Dom) sel.Host {
        return .{ .ctx = d, .atom = fwdAtom, .freeAtom = fwdFreeAtom, .latin1 = fwdLatin1, .toUtf8 = fwdToUtf8, .freeUtf8 = fwdFreeUtf8 };
    }

    fn matcher(d: *Dom) sel.Matcher {
        return .{ .store = &d.store, .host = d.selHost() };
    }
};

/// Compiled selectors kept per DOM before the cache starts over.
const max_selectors = 512;

// The store calls Zig-convention function pointers; these forward to the
// host's C ones (the context is the Dom).
fn hostOf(ctx: *anyopaque) *Host {
    return &@as(*Dom, @ptrCast(@alignCast(ctx))).host;
}
fn fwdDup(ctx: *anyopaque, v: *const JsVal) void {
    const h = hostOf(ctx);
    h.dup(h.ctx, v);
}
fn fwdFree(ctx: *anyopaque, v: *const JsVal) void {
    const h = hostOf(ctx);
    h.free(h.ctx, v);
}
fn fwdDupAtom(ctx: *anyopaque, a: u32) void {
    const h = hostOf(ctx);
    h.dup_atom(h.ctx, a);
}
fn fwdFreeAtom(ctx: *anyopaque, a: u32) void {
    const h = hostOf(ctx);
    h.free_atom(h.ctx, a);
}
fn fwdString(ctx: *anyopaque, bytes: [*]const u8, len: usize, out: *JsVal) bool {
    const h = hostOf(ctx);
    return h.new_string(h.ctx, bytes, len, out);
}
fn fwdAtom(ctx: *anyopaque, bytes: [*]const u8, len: usize) u32 {
    const h = hostOf(ctx);
    return h.new_atom(h.ctx, bytes, len);
}
fn fwdLatin1(ctx: *anyopaque, v: *const JsVal, len: *usize) ?[*]const u8 {
    const h = hostOf(ctx);
    return h.latin1(h.ctx, v, len);
}
fn fwdToUtf8(ctx: *anyopaque, v: *const JsVal, len: *usize) ?[*]const u8 {
    const h = hostOf(ctx);
    return h.to_utf8(h.ctx, v, len);
}
fn fwdFreeUtf8(ctx: *anyopaque, p: [*]const u8) void {
    const h = hostOf(ctx);
    h.free_utf8(h.ctx, p);
}
fn fwdValueAtom(ctx: *anyopaque, v: *const JsVal) u32 {
    const h = hostOf(ctx);
    return h.value_atom(h.ctx, v);
}
/// The store's sink callback, behind a C-convention trampoline.
const TokenSink = struct { sink: *anyopaque, add: *const fn (sink: *anyopaque, atom: u32) bool };
fn tokenAdd(p: *anyopaque, atom: u32) callconv(.c) bool {
    const t: *TokenSink = @ptrCast(@alignCast(p));
    return t.add(t.sink, atom);
}
fn fwdTokens(ctx: *anyopaque, v: *const JsVal, sink: *anyopaque, add: *const fn (sink: *anyopaque, atom: u32) bool) bool {
    const h = hostOf(ctx);
    var ts: TokenSink = .{ .sink = sink, .add = add };
    return h.tokens(h.ctx, v, &ts, tokenAdd);
}

const gpa = std.heap.c_allocator;

pub const code_ok: c_int = 0;
pub const code_oom: c_int = -1;
pub const code_hierarchy: c_int = -2;
pub const code_not_found: c_int = -3;

fn code(e: st.Error) c_int {
    return switch (e) {
        error.OutOfMemory => code_oom,
        error.HierarchyRequest => code_hierarchy,
        error.NotFound, error.StaleNode => code_not_found,
    };
}

export fn nui_dom_new(host: *const Host) ?*Dom {
    const d = gpa.create(Dom) catch return null;
    // Every field set (defaults included), then the store and parser.
    d.* = .{ .store = undefined, .parser = undefined, .host = host.* };
    const js: st.Js = .{ .ctx = d, .dup = fwdDup, .free = fwdFree, .dupAtom = fwdDupAtom, .freeAtom = fwdFreeAtom, .valueAtom = fwdValueAtom, .tokens = fwdTokens };
    const class_name = host.new_atom(host.ctx, "class", 5);
    const id_name = host.new_atom(host.ctx, "id", 2);
    defer if (class_name != 0) host.free_atom(host.ctx, class_name);
    defer if (id_name != 0) host.free_atom(host.ctx, id_name);
    if (class_name == 0 or id_name == 0) {
        gpa.destroy(d);
        return null;
    }
    d.store = Store.init(gpa, js, class_name, id_name) catch {
        gpa.destroy(d);
        return null;
    };
    d.parser = .{
        .store = &d.store,
        .gpa = gpa,
        .make = .{ .ctx = d, .string = fwdString, .atom = fwdAtom, .free = fwdFree, .freeAtom = fwdFreeAtom },
    };
    return d;
}

fn clearSelectors(d: *Dom) void {
    var it = d.selectors.iterator();
    while (it.next()) |e| {
        sel.destroy(gpa, e.value_ptr.*);
        gpa.free(e.key_ptr.*);
    }
    d.selectors.clearAndFree(gpa);
}

export fn nui_dom_free(d: *Dom) void {
    clearSelectors(d);
    d.parser.deinit();
    d.store.deinit();
    gpa.destroy(d);
}

export fn nui_dom_document(d: *Dom) Index {
    return d.store.document;
}

// --- Nodes ------------------------------------------------------------

export fn nui_dom_create_element(d: *Dom, name: u32) Index {
    return d.store.createElement(name) catch none;
}
export fn nui_dom_create_data(d: *Dom, kind: u8, data: *const JsVal) Index {
    return d.store.createData(@enumFromInt(kind), data) catch none;
}
export fn nui_dom_create_fragment(d: *Dom) Index {
    return d.store.createFragment() catch none;
}
export fn nui_dom_drop_if_unused(d: *Dom, idx: Index) void {
    d.store.dropIfUnused(idx);
}

export fn nui_dom_kind(d: *Dom, idx: Index) u8 {
    return @intFromEnum(d.store.get(idx).kind);
}
export fn nui_dom_name(d: *Dom, idx: Index) u32 {
    return d.store.get(idx).name;
}
export fn nui_dom_parent(d: *Dom, idx: Index) Index {
    return d.store.get(idx).parent;
}
export fn nui_dom_first(d: *Dom, idx: Index) Index {
    return d.store.get(idx).first;
}
export fn nui_dom_last(d: *Dom, idx: Index) Index {
    return d.store.get(idx).last;
}
export fn nui_dom_next(d: *Dom, idx: Index) Index {
    return d.store.get(idx).next;
}
export fn nui_dom_prev(d: *Dom, idx: Index) Index {
    return d.store.get(idx).prev;
}
export fn nui_dom_connected(d: *Dom, idx: Index) bool {
    return d.store.get(idx).connected;
}

// --- The tree ---------------------------------------------------------

export fn nui_dom_insert(d: *Dom, parent: Index, child: Index, ref: Index) c_int {
    d.store.insertBefore(parent, child, ref) catch |e| return code(e);
    return code_ok;
}
export fn nui_dom_remove(d: *Dom, idx: Index) void {
    d.store.remove(idx);
}
export fn nui_dom_remove_children(d: *Dom, idx: Index) void {
    d.store.removeChildren(idx);
}

// --- Wrappers ---------------------------------------------------------

/// The node's wrapper (borrowed), or null.
export fn nui_dom_wrapper(d: *Dom, idx: Index) ?*const JsVal {
    return d.store.wrapperOf(idx);
}
export fn nui_dom_set_wrapper(d: *Dom, idx: Index, w: *const JsVal) void {
    d.store.setWrapper(idx, w);
}
export fn nui_dom_wrapper_finalized(d: *Dom, idx: Index) void {
    d.store.wrapperFinalized(idx);
}

// --- Text and attributes ----------------------------------------------

export fn nui_dom_data(d: *Dom, idx: Index) ?*const JsVal {
    return d.store.dataOf(idx);
}
export fn nui_dom_set_data(d: *Dom, idx: Index, v: *const JsVal) void {
    d.store.setData(idx, v);
}
export fn nui_dom_get_attr(d: *Dom, idx: Index, name: u32) ?*const JsVal {
    return d.store.getAttr(idx, name);
}
export fn nui_dom_set_attr(d: *Dom, idx: Index, name: u32, v: *const JsVal) c_int {
    d.store.setAttr(idx, name, v) catch |e| return code(e);
    return code_ok;
}
export fn nui_dom_remove_attr(d: *Dom, idx: Index, name: u32) bool {
    return d.store.removeAttr(idx, name);
}
export fn nui_dom_attr_count(d: *Dom, idx: Index) usize {
    return d.store.attrCount(idx);
}
/// The i-th attribute: its name atom, and its value (borrowed) in *out.
export fn nui_dom_attr_at(d: *Dom, idx: Index, i: usize, out: *?*const JsVal) u32 {
    const a = d.store.attrAt(idx, i) orelse {
        out.* = null;
        return 0;
    };
    out.* = &a.value;
    return a.name;
}

// --- HTML ---------------------------------------------------------------

/// Parses UTF-8 markup and appends the nodes to `root`.
export fn nui_dom_parse_html(d: *Dom, root: Index, bytes: [*]const u8, len: usize) c_int {
    d.parser.parse(root, bytes[0..len]) catch |e| return code(e);
    return code_ok;
}

const none = st.none;

// --- Selectors ----------------------------------------------------------

pub const code_syntax: c_int = -4;

/// A compiled selector for UTF-8 text (cached by text), or null with *code
/// set (code_syntax, code_oom). Valid until the next nui_dom_selector call.
export fn nui_dom_selector(d: *Dom, bytes: [*]const u8, len: usize, out_code: *c_int) ?*sel.Selector {
    const text = bytes[0..len];
    if (d.selectors.get(text)) |found| return found;
    const compiled = sel.compile(gpa, d.selHost(), text) catch |e| {
        out_code.* = if (e == error.Syntax) code_syntax else code_oom;
        return null;
    };
    if (d.selectors.count() >= max_selectors) clearSelectors(d);
    const key = gpa.dupe(u8, text) catch {
        sel.destroy(gpa, compiled);
        out_code.* = code_oom;
        return null;
    };
    d.selectors.put(gpa, key, compiled) catch {
        gpa.free(key);
        sel.destroy(gpa, compiled);
        out_code.* = code_oom;
        return null;
    };
    return compiled;
}

export fn nui_dom_matches(d: *Dom, idx: Index, s: *const sel.Selector) bool {
    const m = d.matcher();
    return m.matches(idx, s);
}

/// The nearest inclusive ancestor element that matches, or 0.
export fn nui_dom_closest(d: *Dom, idx: Index, s: *const sel.Selector) Index {
    const m = d.matcher();
    var n = idx;
    while (n != none and d.store.get(n).kind == .element) : (n = d.store.get(n).parent) {
        if (m.matches(n, s)) return n;
    }
    return none;
}

/// The elements under `root` that match, in document order, each passed to
/// `found` until it returns false.
export fn nui_dom_query(d: *Dom, root: Index, s: *const sel.Selector, ctx: *anyopaque, found: *const fn (ctx: *anyopaque, idx: Index) callconv(.c) bool) void {
    const Tramp = struct {
        ctx: *anyopaque,
        found: *const fn (ctx: *anyopaque, idx: Index) callconv(.c) bool,
        fn call(p: *anyopaque, idx: Index) bool {
            const t: *@This() = @ptrCast(@alignCast(p));
            return t.found(t.ctx, idx);
        }
    };
    var t: Tramp = .{ .ctx = ctx, .found = found };
    const m = d.matcher();
    m.query(root, s, &t, Tramp.call);
}

/// The first element under `root` (document order) whose id is the atom.
export fn nui_dom_by_id(d: *Dom, root: Index, id: u32) Index {
    const s = &d.store;
    var e = s.get(root).first;
    while (e != none) {
        if (s.get(e).kind == .element and s.get(e).id == id) return e;
        if (s.get(e).first != none) {
            e = s.get(e).first;
            continue;
        }
        while (e != root and s.get(e).next == none) e = s.get(e).parent;
        if (e == root) return none;
        e = s.get(e).next;
    }
    return none;
}
