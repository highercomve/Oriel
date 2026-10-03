//! Fixed-size items in slabs that go back to the allocator when they empty.
//!
//! The tree's nodes and text overrides come from here: packed side by side
//! (a general allocator rounds a 1.3 KB node up to its size class, which on
//! a first build is page faults), and a freed one is the next one made. A
//! slab whose items are all freed is released (beyond one kept for the next
//! list), so a window that showed a long list and cleared it gives that
//! memory back; std.heap.MemoryPool kept it until the tree went.
//!
//! Empty slabs are kept (a list cleared and built again reuses them, without
//! page faults) until trim() releases them: the backend calls Tree.trimPools
//! a while after a big removal, if they're still empty then.
//!
//! A slab is `slab_bytes` long and aligned to its length: an item's slab is
//! its address rounded down. Its items are handed out in order the first
//! time (memory a slab never used isn't touched), then from its free list.
//! Slabs are mapped from the system (page_allocator), not the caller's
//! allocator: an aligned block from malloc wastes its alignment and stays
//! in malloc's heap when freed; an unmapped slab is gone.

const std = @import("std");

pub const slab_bytes = 128 * 1024;

const builtin = @import("builtin");

/// A slab from the system, aligned to its length.
fn mapSlab() error{OutOfMemory}![]align(slab_bytes) u8 {
    if (builtin.os.tag == .windows) return win.map();
    return std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(slab_bytes), slab_bytes);
}

fn unmapSlab(mem: [*]align(slab_bytes) u8) void {
    if (builtin.os.tag == .windows) return win.unmap(mem);
    std.heap.page_allocator.free(@as([]align(slab_bytes) u8, mem[0..slab_bytes]));
}

/// Windows: page_allocator's path for an alignment above the 64 KB
/// allocation granularity (Zig 0.16: a placeholder reservation, then a
/// commit that fails on it) gave OutOfMemory whenever VirtualAlloc's
/// first address wasn't 128 KB-aligned, about every other slab. Twice the
/// length is reserved instead, the aligned slab inside it committed, and
/// the whole reservation released with it (address space, not memory).
const win = struct {
    const MEM_COMMIT = 0x1000;
    const MEM_RESERVE = 0x2000;
    const MEM_RELEASE = 0x8000;
    const PAGE_NOACCESS = 0x01;
    const PAGE_READWRITE = 0x04;
    const MemoryBasicInformation = extern struct {
        base_address: ?*anyopaque,
        allocation_base: ?*anyopaque,
        allocation_protect: u32,
        partition_id: u16,
        region_size: usize,
        state: u32,
        protect: u32,
        type: u32,
    };
    extern "kernel32" fn VirtualAlloc(addr: ?*anyopaque, size: usize, kind: u32, protect: u32) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn VirtualFree(addr: ?*anyopaque, size: usize, kind: u32) callconv(.winapi) c_int;
    extern "kernel32" fn VirtualQuery(addr: ?*const anyopaque, info: *MemoryBasicInformation, len: usize) callconv(.winapi) usize;

    fn map() error{OutOfMemory}![]align(slab_bytes) u8 {
        const base = VirtualAlloc(null, 2 * slab_bytes, MEM_RESERVE, PAGE_NOACCESS) orelse return error.OutOfMemory;
        const aligned = std.mem.alignForward(usize, @intFromPtr(base), slab_bytes);
        const mem = VirtualAlloc(@ptrFromInt(aligned), slab_bytes, MEM_COMMIT, PAGE_READWRITE) orelse {
            _ = VirtualFree(base, 0, MEM_RELEASE);
            return error.OutOfMemory;
        };
        const p: [*]align(slab_bytes) u8 = @ptrCast(@alignCast(mem));
        return p[0..slab_bytes];
    }

    fn unmap(mem: [*]align(slab_bytes) u8) void {
        var info: MemoryBasicInformation = undefined;
        if (VirtualQuery(mem, &info, @sizeOf(MemoryBasicInformation)) == 0) return;
        _ = VirtualFree(info.allocation_base, 0, MEM_RELEASE);
    }
};

pub fn SlabPool(comptime T: type) type {
    return struct {
        const Pool = @This();

        /// A freed item's first bytes: the next free item in its slab.
        const Free = struct { next: ?*Free };
        const item_size = std.mem.alignForward(usize, @max(@sizeOf(T), @sizeOf(Free)), @max(@alignOf(T), @alignOf(Free)));
        const item_align = @max(@alignOf(T), @alignOf(Free));

        const Slab = struct {
            /// Every slab, and the ones with a free item (partial).
            prev: ?*Slab = null,
            next: ?*Slab = null,
            prev_partial: ?*Slab = null,
            next_partial: ?*Slab = null,
            in_partial: bool = false,
            free: ?*Free = null,
            /// Items handed out the first time (from the start), live ones.
            used: u32 = 0,
            live: u32 = 0,
        };
        const first_item = std.mem.alignForward(usize, @sizeOf(Slab), item_align);
        pub const per_slab: u32 = @intCast((slab_bytes - first_item) / item_size);
        comptime {
            std.debug.assert(per_slab >= 4);
        }

        slabs: ?*Slab = null,
        partial: ?*Slab = null,
        /// Slabs with no live item (one is kept).
        empty: u32 = 0,
        live: usize = 0,
        slab_count: usize = 0,

        pub fn create(pool: *Pool) error{OutOfMemory}!*T {
            const slab = pool.partial orelse try pool.newSlab();
            const item: *align(item_align) [item_size]u8 = if (slab.free) |f| blk: {
                slab.free = f.next;
                break :blk @ptrCast(@alignCast(f));
            } else blk: {
                const at = @intFromPtr(slab) + first_item + @as(usize, slab.used) * item_size;
                slab.used += 1;
                break :blk @ptrFromInt(at);
            };
            if (slab.live == 0) pool.empty -= 1;
            slab.live += 1;
            pool.live += 1;
            if (slab.free == null and slab.used == per_slab) pool.unlinkPartial(slab);
            return @ptrCast(item);
        }

        pub fn destroy(pool: *Pool, ptr: *T) void {
            const slab: *Slab = @ptrFromInt(@intFromPtr(ptr) & ~@as(usize, slab_bytes - 1));
            const f: *Free = @ptrCast(@alignCast(ptr));
            f.next = slab.free;
            slab.free = f;
            if (!slab.in_partial) pool.linkPartial(slab);
            slab.live -= 1;
            pool.live -= 1;
            if (slab.live == 0) pool.empty += 1;
        }

        /// Release the empty slabs beyond `keep`: how many went.
        pub fn trim(pool: *Pool, keep: usize) usize {
            var released: usize = 0;
            var it = pool.slabs;
            while (it) |slab| {
                it = slab.next;
                if (pool.empty <= keep) break;
                if (slab.live != 0) continue;
                pool.release(slab);
                released += 1;
            }
            return released;
        }

        pub fn deinit(pool: *Pool) void {
            while (pool.slabs) |slab| pool.release(slab);
            pool.* = .{};
        }

        fn newSlab(pool: *Pool) error{OutOfMemory}!*Slab {
            const mem = try mapSlab();
            const slab: *Slab = @ptrCast(@alignCast(mem.ptr));
            slab.* = .{ .next = pool.slabs };
            if (pool.slabs) |s| s.prev = slab;
            pool.slabs = slab;
            pool.linkPartial(slab);
            pool.empty += 1;
            pool.slab_count += 1;
            return slab;
        }

        fn release(pool: *Pool, slab: *Slab) void {
            if (slab.in_partial) pool.unlinkPartial(slab);
            if (slab.prev) |p| p.next = slab.next else pool.slabs = slab.next;
            if (slab.next) |n| n.prev = slab.prev;
            if (slab.live == 0) pool.empty -|= 1;
            pool.slab_count -= 1;
            const mem: [*]align(slab_bytes) u8 = @ptrCast(@alignCast(slab));
            unmapSlab(mem);
        }

        fn linkPartial(pool: *Pool, slab: *Slab) void {
            slab.in_partial = true;
            slab.prev_partial = null;
            slab.next_partial = pool.partial;
            if (pool.partial) |p| p.prev_partial = slab;
            pool.partial = slab;
        }

        fn unlinkPartial(pool: *Pool, slab: *Slab) void {
            slab.in_partial = false;
            if (slab.prev_partial) |p| p.next_partial = slab.next_partial else pool.partial = slab.next_partial;
            if (slab.next_partial) |n| n.prev_partial = slab.prev_partial;
            slab.prev_partial = null;
            slab.next_partial = null;
        }
    };
}

test "slabs fill, empty slabs go back (one kept), and everything goes at deinit" {
    const Item = struct { a: [1300]u8, id: usize };
    const P = SlabPool(Item);
    const gpa = std.testing.allocator;
    var pool: P = .{};
    defer pool.deinit();
    var items: std.ArrayList(*Item) = .empty;
    defer items.deinit(gpa);
    const n = P.per_slab * 10 + 3;
    for (0..n) |i| {
        const it = try pool.create();
        it.id = i;
        try items.append(gpa, it);
    }
    try std.testing.expectEqual(@as(usize, 11), pool.slab_count);
    for (items.items, 0..) |it, i| try std.testing.expectEqual(i, it.id);
    // Every other one freed: no slab empties, freed items are reused.
    var i: usize = 0;
    while (i < items.items.len) : (i += 2) pool.destroy(items.items[i]);
    try std.testing.expectEqual(@as(usize, 11), pool.slab_count);
    const again = try pool.create();
    try std.testing.expectEqual(@as(usize, 11), pool.slab_count);
    pool.destroy(again);
    // The rest freed: the empty slabs stay until a trim (one kept).
    i = 1;
    while (i < items.items.len) : (i += 2) pool.destroy(items.items[i]);
    try std.testing.expectEqual(@as(usize, 0), pool.live);
    try std.testing.expectEqual(@as(usize, 11), pool.slab_count);
    try std.testing.expectEqual(@as(usize, 10), pool.trim(1));
    try std.testing.expectEqual(@as(usize, 1), pool.slab_count);
    // Reused, then grown again.
    items.clearRetainingCapacity();
    for (0..P.per_slab + 1) |_| try items.append(gpa, try pool.create());
    try std.testing.expectEqual(@as(usize, 2), pool.slab_count);
    for (items.items[0..5]) |it| pool.destroy(it);
}
