//! The native DOM's document store (docs/native-dom.md): the nodes of one
//! window's document, their tree, attributes and text, owned by Zig.
//!
//! Memory, by design:
//! - Nodes are records in fixed slabs, reused through a free list: no
//!   allocation per node, and a node's address never moves (slabs are only
//!   added). Nodes are named by index (`Index`, 0 = none) plus a generation,
//!   so a stale handle is detected instead of reaching a reused record.
//! - Strings stay QuickJS strings (`JsVal`): text, attribute values. The store
//!   holds one reference to each it keeps and hands the same value back: no
//!   conversion, no copy. Names (tags, attributes) are QuickJS atoms (`u32`),
//!   compared as integers; the store holds one reference to each.
//! - Attributes: two inline in the node, more in one array per element.
//! - Children are a linked list (O(1) insert and remove); collections are
//!   views computed by the bindings, not arrays kept in sync.
//!
//! Wrappers (the JavaScript object for a node, made by the bindings when the
//! page first sees the node): while a node is connected (in the document),
//! the store holds a reference to its wrapper, so expandos and listeners on it
//! survive the page dropping it. A detached node's wrapper is held only by the
//! page; `wrapped` counts the live wrappers in each subtree, and a detached
//! subtree with none left is freed (nothing can reach it any more).
//!
//! The store is single-threaded (the UI thread). QuickJS reference counting
//! goes through four C functions (nui_js_* in dom_qjs.c), so this file has no
//! QuickJS headers; tests provide fakes.

const std = @import("std");

/// A QuickJS JSValue (16 bytes on 64-bit targets, 8 with NaN-boxing on
/// 32-bit), held opaquely: the store only counts references through C.
pub const JsVal = if (@sizeOf(usize) == 8) extern struct { u: u64, tag: i64 } else extern struct { v: u64 };

/// QuickJS reference counting, implemented in dom_qjs.c (tests: fakes).
pub const Js = struct {
    ctx: *anyopaque,
    dup: *const fn (ctx: *anyopaque, v: *const JsVal) void,
    free: *const fn (ctx: *anyopaque, v: *const JsVal) void,
    dupAtom: *const fn (ctx: *anyopaque, a: u32) void,
    freeAtom: *const fn (ctx: *anyopaque, a: u32) void,
};

pub const Index = u32;
pub const none: Index = 0;

/// DOM nodeType values (the bindings return them as is).
pub const Kind = enum(u8) { free = 0, element = 1, text = 3, comment = 8, document = 9, fragment = 11 };

pub const Attr = struct { name: u32, value: JsVal };

const inline_attrs = 2;
const slab_bits = 10;
const slab_len = 1 << slab_bits;

pub const Node = struct {
    /// Bumped when the record is freed: handles carry it (see `Handle`).
    gen: u32 = 0,
    kind: Kind = .free,
    connected: bool = false,
    has_wrapper: bool = false,
    has_data: bool = false,
    /// Tag name atom (elements).
    name: u32 = 0,
    parent: Index = none,
    first: Index = none,
    last: Index = none,
    prev: Index = none,
    /// Siblings; for a free record, the next free one.
    next: Index = none,
    /// Live wrappers in this subtree, this node's own included.
    wrapped: u32 = 0,
    /// Renderer marks (set by mutations, cleared by the renderer).
    dirty: u8 = 0,
    attr_len: u16 = 0,
    /// The wrapper object (valid when has_wrapper); referenced by the store
    /// while connected.
    wrapper: JsVal = undefined,
    /// Text and comment data (valid when has_data).
    data: JsVal = undefined,
    attrs: [inline_attrs]Attr = undefined,
    /// Attributes beyond the inline ones (attr_len - inline_attrs of them).
    more: []Attr = &.{},
};

/// A node as the bindings hold it: index and generation in one u64.
pub const Handle = u64;

pub fn handle(idx: Index, gen: u32) Handle {
    return (@as(u64, gen) << 32) | idx;
}

/// Marks a mutation leaves on a node for the renderer.
pub const dirty_attrs: u8 = 1; // its attributes changed (restyle)
pub const dirty_children: u8 = 2; // its children or text changed (re-flatten)

pub const Error = error{ OutOfMemory, HierarchyRequest, NotFound, StaleNode };

pub const Store = struct {
    gpa: std.mem.Allocator,
    js: Js,
    slabs: std.ArrayList(*[slab_len]Node) = .empty,
    /// Records handed out so far (index 0 is never used).
    used: u32 = 1,
    free_head: Index = none,
    document: Index = none,
    /// Wrappers whose reference the store drops once an operation's
    /// structure is consistent (dropping one may run its finalizer, which
    /// calls back into the store).
    releases: std.ArrayList(JsVal) = .empty,
    /// Nodes the renderer must look at (a node is listed once until cleared).
    dirty_list: std.ArrayList(Index) = .empty,
    /// Reused traversal stack.
    stack: std.ArrayList(Index) = .empty,

    pub fn init(gpa: std.mem.Allocator, js: Js) Error!Store {
        var s: Store = .{ .gpa = gpa, .js = js };
        errdefer s.deinit();
        s.document = try s.alloc(.document, 0);
        s.get(s.document).connected = true;
        return s;
    }

    /// Frees every node, string and atom the store holds. Wrappers still
    /// referenced by it are released last.
    pub fn deinit(s: *Store) void {
        var i: Index = 1;
        while (i < s.used) : (i += 1) {
            const n = s.get(i);
            if (n.kind == .free) continue;
            s.releaseContent(n);
            if (n.has_wrapper and n.connected) s.js.free(s.js.ctx, &n.wrapper);
            n.* = .{ .gen = n.gen +% 1 };
        }
        for (s.releases.items) |*v| s.js.free(s.js.ctx, v);
        for (s.slabs.items) |slab| s.gpa.destroy(slab);
        s.slabs.deinit(s.gpa);
        s.releases.deinit(s.gpa);
        s.dirty_list.deinit(s.gpa);
        s.stack.deinit(s.gpa);
        s.* = undefined;
    }

    pub fn get(s: *Store, idx: Index) *Node {
        std.debug.assert(idx != none and idx < s.used);
        return &s.slabs.items[idx >> slab_bits][idx & (slab_len - 1)];
    }

    /// The node a handle names, or null when it was freed since.
    pub fn resolve(s: *Store, h: Handle) ?Index {
        const idx: Index = @truncate(h);
        if (idx == none or idx >= s.used) return null;
        const n = s.get(idx);
        if (n.kind == .free or n.gen != @as(u32, @truncate(h >> 32))) return null;
        return idx;
    }

    pub fn handleOf(s: *Store, idx: Index) Handle {
        return handle(idx, s.get(idx).gen);
    }

    // -----------------------------------------------------------------
    // Records

    fn alloc(s: *Store, kind: Kind, name: u32) Error!Index {
        var idx = s.free_head;
        if (idx != none) {
            s.free_head = s.get(idx).next;
        } else {
            if (s.used == std.math.maxInt(Index)) return error.OutOfMemory;
            if ((s.used >> slab_bits) == s.slabs.items.len) {
                const slab = try s.gpa.create([slab_len]Node);
                errdefer s.gpa.destroy(slab);
                try s.slabs.append(s.gpa, slab);
                for (slab) |*n| n.* = .{};
            }
            idx = s.used;
            s.used += 1;
        }
        const n = s.get(idx);
        n.* = .{ .gen = n.gen, .kind = kind, .name = name };
        if (name != 0) s.js.dupAtom(s.js.ctx, name);
        return idx;
    }

    /// The strings and atoms a node holds (not its wrapper).
    fn releaseContent(s: *Store, n: *Node) void {
        if (n.name != 0) s.js.freeAtom(s.js.ctx, n.name);
        if (n.has_data) s.js.free(s.js.ctx, &n.data);
        // Every attribute: the inline ones, then the spilled ones.
        var i: usize = 0;
        while (i < n.attr_len) : (i += 1) {
            const a = if (i < inline_attrs) &n.attrs[i] else &n.more[i - inline_attrs];
            s.js.freeAtom(s.js.ctx, a.name);
            s.js.free(s.js.ctx, &a.value);
        }
        if (n.more.len != 0) s.gpa.free(n.more);
    }

    fn release(s: *Store, idx: Index) void {
        const n = s.get(idx);
        std.debug.assert(!n.has_wrapper and n.wrapped == 0);
        s.releaseContent(n);
        n.* = .{ .gen = n.gen +% 1, .next = s.free_head };
        s.free_head = idx;
    }

    /// Frees a detached subtree without live wrappers.
    fn freeTree(s: *Store, root: Index) void {
        // The stack may already be in use by a caller up the stack (a
        // finalizer during an operation): walk with links instead.
        var n = root;
        while (true) {
            // Down to a leaf.
            while (s.get(n).first != none) n = s.get(n).first;
            if (n == root) {
                s.release(root);
                return;
            }
            const parent = s.get(n).parent;
            const next = s.get(n).next;
            // Unlink this leaf from its parent, then free it.
            s.get(parent).first = next;
            if (next != none) s.get(next).prev = none else s.get(parent).last = none;
            s.release(n);
            n = if (next != none) next else parent;
        }
    }

    // -----------------------------------------------------------------
    // Creating

    pub fn createElement(s: *Store, name: u32) Error!Index {
        return s.alloc(.element, name);
    }

    /// A text or comment node holding `data` (the store takes a reference).
    pub fn createData(s: *Store, kind: Kind, data: *const JsVal) Error!Index {
        std.debug.assert(kind == .text or kind == .comment);
        const idx = try s.alloc(kind, 0);
        const n = s.get(idx);
        s.js.dup(s.js.ctx, data);
        n.data = data.*;
        n.has_data = true;
        return idx;
    }

    pub fn createFragment(s: *Store) Error!Index {
        return s.alloc(.fragment, 0);
    }

    /// A node made by the store (a parser's) that nothing holds yet: freed
    /// unless it was inserted somewhere.
    pub fn dropIfUnused(s: *Store, idx: Index) void {
        const n = s.get(idx);
        if (n.parent == none and n.wrapped == 0 and idx != s.document) s.freeTree(idx);
    }

    // -----------------------------------------------------------------
    // Wrappers

    /// The bindings made a wrapper for a node (it holds the only reference).
    pub fn setWrapper(s: *Store, idx: Index, w: *const JsVal) void {
        const n = s.get(idx);
        std.debug.assert(!n.has_wrapper);
        n.wrapper = w.*;
        n.has_wrapper = true;
        if (n.connected) s.js.dup(s.js.ctx, w);
        s.addWrapped(idx, 1);
    }

    pub fn wrapperOf(s: *Store, idx: Index) ?*const JsVal {
        const n = s.get(idx);
        return if (n.has_wrapper) &n.wrapper else null;
    }

    /// A wrapper was finalized (its last reference went): the node forgets
    /// it, and a detached subtree left without wrappers is freed.
    pub fn wrapperFinalized(s: *Store, idx: Index) void {
        const n = s.get(idx);
        std.debug.assert(n.has_wrapper and !n.connected);
        n.has_wrapper = false;
        s.addWrapped(idx, -1);
    }

    fn addWrapped(s: *Store, start: Index, delta: i32) void {
        var idx = start;
        var root = start;
        while (idx != none) : (idx = s.get(idx).parent) {
            const n = s.get(idx);
            n.wrapped = @intCast(@as(i64, n.wrapped) + delta);
            root = idx;
        }
        if (delta < 0) {
            const r = s.get(root);
            if (!r.connected and r.wrapped == 0) s.freeTree(root);
        }
    }

    // -----------------------------------------------------------------
    // The tree

    fn isInclusiveAncestor(s: *Store, a: Index, b: Index) bool {
        var idx = b;
        while (idx != none) : (idx = s.get(idx).parent) if (idx == a) return true;
        return false;
    }

    /// Inserts `child` into `parent` before `ref` (none: at the end), moving
    /// it from where it was; a fragment's children are moved instead.
    pub fn insertBefore(s: *Store, parent: Index, child: Index, ref: Index) Error!void {
        const p = s.get(parent);
        if (p.kind != .element and p.kind != .document and p.kind != .fragment) return error.HierarchyRequest;
        if (s.isInclusiveAncestor(child, parent)) return error.HierarchyRequest;
        if (s.get(child).kind == .document) return error.HierarchyRequest;
        if (ref != none and s.get(ref).parent != parent) return error.NotFound;
        if (child == ref) return; // already in place
        if (s.get(child).kind == .fragment) {
            while (s.get(child).first != none) try s.insertBefore(parent, s.get(child).first, ref);
            return;
        }
        if (s.get(child).parent != none) s.unlink(child, false);
        s.link(parent, child, ref);
        s.flush();
    }

    pub fn appendChild(s: *Store, parent: Index, child: Index) Error!void {
        return s.insertBefore(parent, child, none);
    }

    /// Removes a node from its parent (a detached subtree without live
    /// wrappers is freed).
    pub fn remove(s: *Store, child: Index) void {
        if (s.get(child).parent == none) return;
        s.unlink(child, true);
        s.flush();
    }

    /// Removes every child of a node.
    pub fn removeChildren(s: *Store, parent: Index) void {
        while (s.get(parent).first != none) s.unlink(s.get(parent).first, true);
        s.flush();
    }

    fn link(s: *Store, parent: Index, child: Index, ref: Index) void {
        const c = s.get(child);
        const p = s.get(parent);
        c.parent = parent;
        if (ref == none) {
            c.prev = p.last;
            c.next = none;
            if (p.last != none) s.get(p.last).next = child else p.first = child;
            p.last = child;
        } else {
            const r = s.get(ref);
            c.prev = r.prev;
            c.next = ref;
            if (r.prev != none) s.get(r.prev).next = child else p.first = child;
            r.prev = child;
        }
        if (c.wrapped != 0) {
            var idx = parent;
            while (idx != none) : (idx = s.get(idx).parent) s.get(idx).wrapped += c.wrapped;
        }
        if (p.connected and !c.connected) s.setConnected(child, true);
        s.markDirty(parent, dirty_children);
        s.markDirty(child, dirty_attrs);
    }

    /// Takes a node out of its parent. `may_free`: free the subtree when
    /// nothing holds it (not when it's about to be inserted elsewhere).
    fn unlink(s: *Store, child: Index, may_free: bool) void {
        const c = s.get(child);
        const parent = c.parent;
        const p = s.get(parent);
        if (c.prev != none) s.get(c.prev).next = c.next else p.first = c.next;
        if (c.next != none) s.get(c.next).prev = c.prev else p.last = c.prev;
        c.parent = none;
        c.prev = none;
        c.next = none;
        if (c.wrapped != 0) {
            var idx = parent;
            while (idx != none) : (idx = s.get(idx).parent) s.get(idx).wrapped -= c.wrapped;
        }
        s.markDirty(parent, dirty_children);
        if (c.connected) s.setConnected(child, false);
        if (may_free and c.wrapped == 0) s.freeTree(child);
    }

    /// Marks a subtree (dis)connected; the store takes or queues the release
    /// of a reference to each wrapper in it.
    fn setConnected(s: *Store, root: Index, connected: bool) void {
        var idx = root;
        while (true) {
            const n = s.get(idx);
            n.connected = connected;
            if (n.has_wrapper) {
                if (connected) s.js.dup(s.js.ctx, &n.wrapper) else s.releases.append(s.gpa, n.wrapper) catch {
                    // No room to defer: release now (a finalizer may run;
                    // the tree is consistent at this point of the walk
                    // except for flags below, which it doesn't read).
                    s.js.free(s.js.ctx, &n.wrapper);
                };
            }
            // Next node in document order within the subtree.
            if (n.first != none) {
                idx = n.first;
                continue;
            }
            while (idx != root and s.get(idx).next == none) idx = s.get(idx).parent;
            if (idx == root) return;
            idx = s.get(idx).next;
        }
    }

    /// Drops the wrapper references queued by an operation (finalizers may
    /// call wrapperFinalized and free subtrees).
    fn flush(s: *Store) void {
        while (s.releases.pop()) |v| {
            var val = v;
            s.js.free(s.js.ctx, &val);
        }
    }

    // -----------------------------------------------------------------
    // Text

    /// Replaces a text or comment node's data (the store takes a reference).
    pub fn setData(s: *Store, idx: Index, data: *const JsVal) void {
        const n = s.get(idx);
        std.debug.assert(n.kind == .text or n.kind == .comment);
        s.js.dup(s.js.ctx, data);
        if (n.has_data) s.js.free(s.js.ctx, &n.data);
        n.data = data.*;
        n.has_data = true;
        if (n.parent != none) s.markDirty(n.parent, dirty_children);
    }

    pub fn dataOf(s: *Store, idx: Index) ?*const JsVal {
        const n = s.get(idx);
        return if (n.has_data) &n.data else null;
    }

    // -----------------------------------------------------------------
    // Attributes

    /// The i-th attribute (in insertion order).
    pub fn attrAt(s: *Store, idx: Index, i: usize) ?*Attr {
        const n = s.get(idx);
        if (i >= n.attr_len) return null;
        return if (i < inline_attrs) &n.attrs[i] else &n.more[i - inline_attrs];
    }

    pub fn attrCount(s: *Store, idx: Index) usize {
        return s.get(idx).attr_len;
    }

    fn findAttr(s: *Store, idx: Index, name: u32) ?usize {
        const n = s.get(idx);
        var i: usize = 0;
        while (i < n.attr_len) : (i += 1) {
            const a = if (i < inline_attrs) &n.attrs[i] else &n.more[i - inline_attrs];
            if (a.name == name) return i;
        }
        return null;
    }

    pub fn getAttr(s: *Store, idx: Index, name: u32) ?*const JsVal {
        const i = s.findAttr(idx, name) orelse return null;
        return &s.attrAt(idx, i).?.value;
    }

    /// Sets an attribute (the store takes a reference to the value and, for
    /// a new one, to the name).
    pub fn setAttr(s: *Store, idx: Index, name: u32, value: *const JsVal) Error!void {
        const n = s.get(idx);
        if (s.findAttr(idx, name)) |i| {
            const a = s.attrAt(idx, i).?;
            s.js.dup(s.js.ctx, value);
            s.js.free(s.js.ctx, &a.value);
            a.value = value.*;
        } else {
            if (n.attr_len >= inline_attrs) {
                const extra = n.attr_len - inline_attrs;
                if (extra == n.more.len) {
                    const cap = if (n.more.len == 0) 4 else n.more.len * 2;
                    n.more = try s.gpa.realloc(n.more, cap);
                }
            }
            if (n.attr_len == std.math.maxInt(u16)) return error.OutOfMemory;
            n.attr_len += 1;
            const a = s.attrAt(idx, n.attr_len - 1).?;
            s.js.dupAtom(s.js.ctx, name);
            s.js.dup(s.js.ctx, value);
            a.* = .{ .name = name, .value = value.* };
        }
        s.markDirty(idx, dirty_attrs);
    }

    /// Removes an attribute; true if it was there.
    pub fn removeAttr(s: *Store, idx: Index, name: u32) bool {
        const n = s.get(idx);
        const i = s.findAttr(idx, name) orelse return false;
        const a = s.attrAt(idx, i).?;
        s.js.freeAtom(s.js.ctx, a.name);
        s.js.free(s.js.ctx, &a.value);
        // Keep the order: shift the later ones down.
        var j = i;
        while (j + 1 < n.attr_len) : (j += 1) s.attrAt(idx, j).?.* = s.attrAt(idx, j + 1).?.*;
        n.attr_len -= 1;
        s.markDirty(idx, dirty_attrs);
        return true;
    }

    // -----------------------------------------------------------------
    // Renderer marks

    pub fn markDirty(s: *Store, idx: Index, what: u8) void {
        const n = s.get(idx);
        if (!n.connected) return;
        if (n.dirty == 0) s.dirty_list.append(s.gpa, idx) catch {
            // Can't list it: mark the document, which the renderer then
            // treats as "everything".
            s.get(s.document).dirty |= dirty_children | dirty_attrs;
            return;
        };
        n.dirty |= what;
    }
};

// ---------------------------------------------------------------------
// Tests: fake reference counting that tracks every reference.

const Fake = struct {
    values: std.AutoHashMap(i64, i64),
    atoms: std.AutoHashMap(u32, i64),
    /// Wrappers finalized (their id), to call back into the store.
    store: ?*Store = null,
    wrapper_nodes: std.AutoHashMap(i64, Index),

    fn new(a: std.mem.Allocator) Fake {
        return .{ .values = .init(a), .atoms = .init(a), .wrapper_nodes = .init(a) };
    }
    fn deinit(f: *Fake) void {
        f.values.deinit();
        f.atoms.deinit();
        f.wrapper_nodes.deinit();
    }
    fn of(c: *anyopaque) *Fake {
        return @ptrCast(@alignCast(c));
    }
    fn key(v: *const JsVal) i64 {
        return if (@sizeOf(usize) == 8) v.tag else @intCast(v.v);
    }
    fn val(k: i64) JsVal {
        return if (@sizeOf(usize) == 8) .{ .u = 0, .tag = k } else .{ .v = @intCast(k) };
    }
    fn dup(c: *anyopaque, v: *const JsVal) void {
        const e = of(c).values.getPtr(key(v)).?;
        e.* += 1;
    }
    fn free(c: *anyopaque, v: *const JsVal) void {
        const f = of(c);
        const e = f.values.getPtr(key(v)).?;
        e.* -= 1;
        if (e.* == 0) {
            // A wrapper's last reference: its finalizer tells the store.
            if (f.wrapper_nodes.fetchRemove(key(v))) |kv| f.store.?.wrapperFinalized(kv.value);
        }
    }
    fn dupAtom(c: *anyopaque, a: u32) void {
        const gop = of(c).atoms.getOrPut(a) catch unreachable;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }
    fn freeAtom(c: *anyopaque, a: u32) void {
        of(c).atoms.getPtr(a).?.* -= 1;
    }
    fn js(f: *Fake) Js {
        return .{ .ctx = f, .dup = dup, .free = free, .dupAtom = dupAtom, .freeAtom = freeAtom };
    }
    /// A new value with one reference (the caller's).
    fn make(f: *Fake, k: i64) JsVal {
        f.values.put(k, 1) catch unreachable;
        return val(k);
    }
    fn refs(f: *Fake, k: i64) i64 {
        return f.values.get(k) orelse 0;
    }
    fn balanced(f: *Fake) bool {
        var it = f.values.valueIterator();
        while (it.next()) |r| if (r.* != 0) return false;
        var at = f.atoms.valueIterator();
        while (at.next()) |r| if (r.* != 0) return false;
        return true;
    }
};

test "tree, attributes and text; every reference released" {
    const t = std.testing;
    var f = Fake.new(t.allocator);
    defer f.deinit();
    var s = try Store.init(t.allocator, f.js());
    f.store = &s;
    const div = try s.createElement(100);
    const span = try s.createElement(101);
    var hello = f.make(1);
    const text = try s.createData(.text, &hello);
    Fake.free(&f, &hello); // the caller's reference
    try s.appendChild(span, text);
    try s.appendChild(div, span);
    var cls = f.make(2);
    try s.setAttr(div, 200, &cls);
    Fake.free(&f, &cls);
    var id = f.make(3);
    try s.setAttr(div, 201, &id);
    Fake.free(&f, &id);
    var title = f.make(4);
    try s.setAttr(div, 202, &title); // a third attribute: spills
    Fake.free(&f, &title);
    try t.expectEqual(@as(usize, 3), s.attrCount(div));
    try t.expectEqual(@as(i64, 4), Fake.key(s.getAttr(div, 202).?));
    try t.expect(s.removeAttr(div, 201));
    try t.expectEqual(@as(usize, 2), s.attrCount(div));
    try t.expectEqual(@as(i64, 4), Fake.key(&s.attrAt(div, 1).?.value));
    try t.expectEqual(span, s.get(div).first);
    try t.expectEqual(text, s.get(span).first);
    // Into the document and out again: nothing holds it, so it's freed.
    try s.appendChild(s.document, div);
    try t.expect(s.get(text).connected);
    s.remove(div);
    try t.expectEqual(Kind.free, s.get(div).kind);
    try t.expectEqual(Kind.free, s.get(text).kind);
    s.deinit();
    try t.expect(f.balanced());
}

test "wrappers: held while connected, the detached subtree freed with the last one" {
    const t = std.testing;
    var f = Fake.new(t.allocator);
    defer f.deinit();
    var s = try Store.init(t.allocator, f.js());
    f.store = &s;
    const list = try s.createElement(100);
    var w_list = f.make(10); // the page's wrapper for `list`
    try f.wrapper_nodes.put(10, list);
    s.setWrapper(list, &w_list);
    const row = try s.createElement(101);
    try s.appendChild(list, row); // no wrapper: parsed markup, say
    try s.appendChild(s.document, list);
    try t.expectEqual(@as(i64, 2), f.refs(10)); // the page's and the store's
    // The page drops its reference: the store's keeps it (and its expandos).
    Fake.free(&f, &w_list);
    try t.expectEqual(@as(i64, 1), f.refs(10));
    try t.expectEqual(Kind.element, s.get(list).kind);
    // Removed: the store drops its reference, the wrapper is finalized and
    // the subtree freed.
    s.remove(list);
    try t.expectEqual(@as(i64, 0), f.refs(10));
    try t.expectEqual(Kind.free, s.get(list).kind);
    try t.expectEqual(Kind.free, s.get(row).kind);
    s.deinit();
    try t.expect(f.balanced());
}

test "a detached subtree lives while any wrapper in it does" {
    const t = std.testing;
    var f = Fake.new(t.allocator);
    defer f.deinit();
    var s = try Store.init(t.allocator, f.js());
    f.store = &s;
    const a = try s.createElement(100);
    const b = try s.createElement(101);
    try s.appendChild(a, b);
    var wb = f.make(20); // the page holds only the child
    try f.wrapper_nodes.put(20, b);
    s.setWrapper(b, &wb);
    try t.expectEqual(@as(u32, 1), s.get(a).wrapped);
    // b.parentNode must still be a.
    try t.expectEqual(a, s.get(b).parent);
    Fake.free(&f, &wb); // the last wrapper: the whole subtree goes
    try t.expectEqual(Kind.free, s.get(a).kind);
    try t.expectEqual(Kind.free, s.get(b).kind);
    s.deinit();
    try t.expect(f.balanced());
}

test "moves, fragments, hierarchy errors and stale handles" {
    const t = std.testing;
    var f = Fake.new(t.allocator);
    defer f.deinit();
    var s = try Store.init(t.allocator, f.js());
    f.store = &s;
    const root = try s.createElement(1);
    try s.appendChild(s.document, root);
    const frag = try s.createFragment();
    const x = try s.createElement(2);
    const y = try s.createElement(3);
    try s.appendChild(frag, x);
    try s.appendChild(frag, y);
    try s.appendChild(root, frag);
    try t.expectEqual(x, s.get(root).first);
    try t.expectEqual(y, s.get(root).last);
    try t.expectEqual(none, s.get(frag).first);
    // Move y before x.
    try s.insertBefore(root, y, x);
    try t.expectEqual(y, s.get(root).first);
    try t.expectEqual(x, s.get(y).next);
    try t.expectError(error.HierarchyRequest, s.appendChild(x, root));
    try t.expectError(error.NotFound, s.insertBefore(x, y, root));
    const h = s.handleOf(x);
    s.remove(x); // freed: nothing holds it
    try t.expectEqual(@as(?Index, null), s.resolve(h));
    const z = try s.createElement(4); // reuses x's record
    try t.expectEqual(x, z);
    try t.expectEqual(@as(?Index, null), s.resolve(h));
    s.dropIfUnused(z);
    s.dropIfUnused(frag);
    s.deinit();
    try t.expect(f.balanced());
}

test "many nodes across slabs, and allocation failures" {
    const t = std.testing;
    var f = Fake.new(t.allocator);
    defer f.deinit();
    var s = try Store.init(t.allocator, f.js());
    f.store = &s;
    const root = try s.createElement(1);
    try s.appendChild(s.document, root);
    var i: usize = 0;
    while (i < 3000) : (i += 1) try s.appendChild(root, try s.createElement(2));
    try t.expect(s.slabs.items.len >= 3);
    s.removeChildren(root);
    try t.expectEqual(none, s.get(root).first);
    s.deinit();
    try t.expect(f.balanced());

    // Every allocation in a short life failing in turn: no leak (the
    // testing allocator checks), references balanced.
    var fail_index: usize = 0;
    while (fail_index < 8) : (fail_index += 1) {
        var fa = std.testing.FailingAllocator.init(t.allocator, .{ .fail_index = fail_index });
        var f2 = Fake.new(t.allocator);
        defer f2.deinit();
        var s2 = Store.init(fa.allocator(), f2.js()) catch continue;
        f2.store = &s2;
        build: {
            const e = s2.createElement(1) catch break :build;
            s2.appendChild(s2.document, e) catch {
                s2.dropIfUnused(e);
                break :build;
            };
            var v = f2.make(5);
            defer Fake.free(&f2, &v);
            for (0..4) |k| s2.setAttr(e, @intCast(10 + k), &v) catch break :build;
        }
        s2.deinit();
        if (!f2.balanced()) {
            var it = f2.values.iterator();
            while (it.next()) |e| std.debug.print("fail_index {d}: value {d} refs {d}\n", .{ fail_index, e.key_ptr.*, e.value_ptr.* });
            var at = f2.atoms.iterator();
            while (at.next()) |e| std.debug.print("fail_index {d}: atom {d} refs {d}\n", .{ fail_index, e.key_ptr.*, e.value_ptr.* });
        }
        try t.expect(f2.balanced());
    }
}
