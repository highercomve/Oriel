//! The document store and HTML parser as C functions, for the QuickJS
//! bindings (dom_qjs.c). Indices are store indices (0 = none); errors are
//! negative codes (see `code`).

const std = @import("std");
const st = @import("store.zig");
const html = @import("html.zig");

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
};

/// One window's DOM: the store, its parser and the host functions.
pub const Dom = struct {
    store: Store,
    parser: html.Parser,
    host: Host,
};

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
    d.host = host.*;
    const js: st.Js = .{ .ctx = d, .dup = fwdDup, .free = fwdFree, .dupAtom = fwdDupAtom, .freeAtom = fwdFreeAtom };
    d.store = Store.init(gpa, js) catch {
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

export fn nui_dom_free(d: *Dom) void {
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
