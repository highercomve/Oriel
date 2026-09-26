//! Strip an ELF executable or shared library for packaging (`strip-elf`):
//! drop the static symbol table (`.symtab` and its string table) and the
//! debug sections, like `strip --strip-all`. Everything the loader uses is
//! kept byte for byte at the same offsets: the program headers and every
//! segment's contents (so `.dynsym`, `.dynstr` and `.dynamic` too: symbols an
//! `-rdynamic` executable exports to its plugins stay).
//!
//! `zig objcopy` can't strip ELF files yet (Zig 0.16: "unimplemented"), and a
//! host `strip` would make packages depend on binutils (and its target
//! support), so this is done here. Handles 32- and 64-bit ELF of either
//! endianness; relocatable objects are refused.

const std = @import("std");

pub const Error = error{ NotElf, UnsupportedElf, Truncated, OutOfMemory };

const SHT_SYMTAB = 2;
const SHT_STRTAB = 3;
const SHT_RELA = 4;
const SHT_NOBITS = 8;
const SHT_REL = 9;
const SHT_DYNSYM = 11;
const SHT_SYMTAB_SHNDX = 18;
const SHF_ALLOC = 0x2;
const SHF_INFO_LINK = 0x40;
const SHN_LORESERVE = 0xff00;
const ET_EXEC = 2;
const ET_DYN = 3;

const Layout = struct {
    is64: bool,
    endian: std.builtin.Endian,

    fn int(l: Layout, comptime T: type, data: []const u8, off: u64) Error!T {
        const size = @sizeOf(T);
        if (off > data.len or data.len - off < size) return error.Truncated;
        const o: usize = @intCast(off);
        return std.mem.readInt(T, data[o..][0..size], l.endian);
    }

    /// An address-sized field (u32 or u64).
    fn addr(l: Layout, data: []const u8, off: u64) Error!u64 {
        return if (l.is64) try l.int(u64, data, off) else try l.int(u32, data, off);
    }

    fn put(l: Layout, comptime T: type, data: []u8, off: u64, v: T) void {
        const o: usize = @intCast(off);
        std.mem.writeInt(T, data[o..][0..@sizeOf(T)], v, l.endian);
    }

    fn putAddr(l: Layout, data: []u8, off: u64, v: u64) void {
        if (l.is64) l.put(u64, data, off, v) else l.put(u32, data, off, @intCast(v));
    }
};

const Section = struct {
    name: u32,
    type: u32,
    flags: u64,
    offset: u64,
    size: u64,
    link: u32,
    info: u32,
    addralign: u64,
    entsize: u64,
};

fn readSection(l: Layout, data: []const u8, off: u64) Error!Section {
    if (l.is64) return .{
        .name = try l.int(u32, data, off),
        .type = try l.int(u32, data, off + 4),
        .flags = try l.int(u64, data, off + 8),
        .offset = try l.int(u64, data, off + 24),
        .size = try l.int(u64, data, off + 32),
        .link = try l.int(u32, data, off + 40),
        .info = try l.int(u32, data, off + 44),
        .addralign = try l.int(u64, data, off + 48),
        .entsize = try l.int(u64, data, off + 56),
    };
    return .{
        .name = try l.int(u32, data, off),
        .type = try l.int(u32, data, off + 4),
        .flags = try l.int(u32, data, off + 8),
        .offset = try l.int(u32, data, off + 16),
        .size = try l.int(u32, data, off + 20),
        .link = try l.int(u32, data, off + 24),
        .info = try l.int(u32, data, off + 28),
        .addralign = try l.int(u32, data, off + 32),
        .entsize = try l.int(u32, data, off + 36),
    };
}

pub fn isElf(data: []const u8) bool {
    return data.len >= 4 and std.mem.eql(u8, data[0..4], "\x7fELF");
}

/// A stripped copy of the ELF image `data` (caller frees). A file without
/// section headers is returned as is.
pub fn strip(gpa: std.mem.Allocator, data: []const u8) Error![]u8 {
    if (!isElf(data) or data.len < 52) return error.NotElf;
    const l: Layout = .{
        .is64 = switch (data[4]) {
            1 => false,
            2 => true,
            else => return error.NotElf,
        },
        .endian = switch (data[5]) {
            1 => .little,
            2 => .big,
            else => return error.NotElf,
        },
    };
    const e_type = try l.int(u16, data, 16);
    if (e_type != ET_EXEC and e_type != ET_DYN) return error.UnsupportedElf;
    const phoff = try l.addr(data, if (l.is64) 32 else 28);
    const shoff = try l.addr(data, if (l.is64) 40 else 32);
    const hdr: u64 = if (l.is64) 52 else 40; // e_ehsize and what follows
    const ehsize = try l.int(u16, data, hdr);
    const phentsize = try l.int(u16, data, hdr + 2);
    const phnum = try l.int(u16, data, hdr + 4);
    const shentsize = try l.int(u16, data, hdr + 6);
    const shnum = try l.int(u16, data, hdr + 8);
    const shstrndx = try l.int(u16, data, hdr + 10);

    if (shoff == 0 or shnum == 0) {
        // No section headers, or extended numbering (e_shnum == 0 with a
        // section table): nothing to strip / not handled.
        if (shoff != 0) return error.UnsupportedElf;
        return gpa.dupe(u8, data);
    }
    if (shstrndx >= shnum) return error.UnsupportedElf; // includes SHN_XINDEX
    if (shentsize < (if (l.is64) @as(u16, 64) else 40)) return error.UnsupportedElf;

    const sections = try gpa.alloc(Section, shnum);
    defer gpa.free(sections);
    for (sections, 0..) |*s, i| s.* = try readSection(l, data, shoff + @as(u64, i) * shentsize);
    const names = sections[shstrndx];

    // 1. What goes: the static symbol table, its string and index tables,
    // debug sections and relocations against dropped sections.
    const drop = try gpa.alloc(bool, shnum);
    defer gpa.free(drop);
    @memset(drop, false);
    for (sections, 0..) |s, i| {
        if (i == 0 or i == shstrndx or s.flags & SHF_ALLOC != 0) continue;
        if (s.type == SHT_SYMTAB) {
            drop[i] = true;
            if (s.link != 0 and s.link < shnum and s.link != shstrndx and
                sections[s.link].type == SHT_STRTAB and sections[s.link].flags & SHF_ALLOC == 0) drop[s.link] = true;
        } else if (isDebugName(sectionName(data, names, s.name))) {
            drop[i] = true;
        }
    }
    for (sections, 0..) |s, i| {
        if (i == 0 or s.flags & SHF_ALLOC != 0 or drop[i]) continue;
        const target_dropped = s.info != 0 and s.info < shnum and drop[s.info];
        if ((s.type == SHT_REL or s.type == SHT_RELA) and target_dropped) drop[i] = true;
        if (s.type == SHT_SYMTAB_SHNDX and s.link < shnum and drop[s.link]) drop[i] = true;
    }

    // 2. The loaded image: everything up to the end of the last segment (and
    // of the headers), copied unchanged.
    var keep_end: u64 = @max(ehsize, phoff + @as(u64, phnum) * phentsize);
    for (0..phnum) |i| {
        const ph = phoff + @as(u64, i) * phentsize;
        const off = try l.addr(data, ph + (if (l.is64) @as(u64, 8) else 4));
        const filesz = try l.addr(data, ph + (if (l.is64) @as(u64, 32) else 16));
        keep_end = @max(keep_end, off + filesz);
    }
    for (sections, 0..) |s, i| {
        if (i == 0 or drop[i] or s.type == SHT_NOBITS or s.flags & SHF_ALLOC == 0) continue;
        keep_end = @max(keep_end, s.offset + s.size);
    }
    if (keep_end > data.len) return error.Truncated;

    const new_index = try gpa.alloc(u32, shnum);
    defer gpa.free(new_index);
    var kept: u32 = 0;
    for (drop, 0..) |d, i| {
        new_index[i] = if (d) 0 else kept;
        if (!d) kept += 1;
    }
    if (kept == shnum) return gpa.dupe(u8, data); // nothing to strip

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, data[0..@intCast(keep_end)]);

    // 3. Kept non-loaded sections past the image move up behind it.
    const new_offset = try gpa.alloc(u64, shnum);
    defer gpa.free(new_offset);
    for (sections, 0..) |s, i| {
        new_offset[i] = s.offset;
        if (i == 0 or drop[i] or s.type == SHT_NOBITS) continue;
        if (s.offset + s.size <= keep_end) continue;
        if (s.offset > data.len or data.len - s.offset < s.size) return error.Truncated;
        try alignOut(gpa, &out, @max(s.addralign, 1));
        new_offset[i] = out.items.len;
        try out.appendSlice(gpa, data[@intCast(s.offset)..][0..@intCast(s.size)]);
    }

    // Dynamic symbols name their section by index: renumber them.
    for (sections, 0..) |s, i| {
        if (drop[i] or s.type != SHT_DYNSYM or s.entsize < 16) continue;
        const count = s.size / s.entsize;
        for (0..count) |k| {
            const at = s.offset + k * s.entsize + 14; // st_shndx, same offset for ELF32 and ELF64
            if (at + 2 > keep_end) return error.Truncated;
            const shndx = try l.int(u16, out.items, at);
            if (shndx != 0 and shndx < SHN_LORESERVE and shndx < shnum) {
                l.put(u16, out.items, at, @intCast(new_index[shndx]));
            }
        }
    }

    // 4. The new section header table.
    try alignOut(gpa, &out, if (l.is64) 8 else 4);
    const new_shoff = out.items.len;
    for (sections, 0..) |s, i| {
        if (drop[i]) continue;
        const at = out.items.len;
        try out.appendSlice(gpa, data[@intCast(shoff + @as(u64, i) * shentsize)..][0..shentsize]);
        const link: u32 = if (s.link != 0 and s.link < shnum) new_index[s.link] else s.link;
        const info_is_index = s.flags & SHF_INFO_LINK != 0 or s.type == SHT_REL or s.type == SHT_RELA;
        const info: u32 = if (info_is_index and s.info != 0 and s.info < shnum) new_index[s.info] else s.info;
        if (l.is64) {
            l.put(u64, out.items, at + 24, new_offset[i]);
            l.put(u32, out.items, at + 40, link);
            l.put(u32, out.items, at + 44, info);
        } else {
            l.put(u32, out.items, at + 16, @intCast(new_offset[i]));
            l.put(u32, out.items, at + 24, link);
            l.put(u32, out.items, at + 28, info);
        }
    }
    l.putAddr(out.items, if (l.is64) 40 else 32, new_shoff);
    l.put(u16, out.items, hdr + 8, @intCast(kept));
    l.put(u16, out.items, hdr + 10, @intCast(new_index[shstrndx]));
    return out.toOwnedSlice(gpa);
}

fn alignOut(gpa: std.mem.Allocator, out: *std.ArrayList(u8), alignment: u64) !void {
    const target = std.mem.alignForward(u64, out.items.len, alignment);
    try out.appendNTimes(gpa, 0, @intCast(target - out.items.len));
}

fn sectionName(data: []const u8, names: Section, name: u32) []const u8 {
    if (names.offset > data.len or name >= names.size) return "";
    const table = data[@intCast(names.offset)..@intCast(@min(data.len, names.offset + names.size))];
    if (name >= table.len) return "";
    return std.mem.sliceTo(table[name..], 0);
}

fn isDebugName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, ".debug") or std.mem.startsWith(u8, name, ".zdebug") or
        std.mem.startsWith(u8, name, ".gnu.debuglink") or std.mem.startsWith(u8, name, ".stab");
}

/// The section names in `data` (for tests). Caller frees the list.
fn sectionNames(gpa: std.mem.Allocator, data: []const u8) ![]const []const u8 {
    const l: Layout = .{ .is64 = data[4] == 2, .endian = if (data[5] == 1) .little else .big };
    const shoff = try l.addr(data, if (l.is64) 40 else 32);
    const hdr: u64 = if (l.is64) 52 else 40;
    const shentsize = try l.int(u16, data, hdr + 6);
    const shnum = try l.int(u16, data, hdr + 8);
    const names = try readSection(l, data, shoff + @as(u64, try l.int(u16, data, hdr + 10)) * shentsize);
    const list = try gpa.alloc([]const u8, shnum);
    for (list, 0..) |*n, i| n.* = sectionName(data, names, (try readSection(l, data, shoff + @as(u64, i) * shentsize)).name);
    return list;
}

fn hasName(list: []const []const u8, name: []const u8) bool {
    for (list) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

test "strip the test executable itself" {
    const builtin = @import("builtin");
    if (builtin.object_format != .elf or @sizeOf(usize) != 8) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const data = std.Io.Dir.cwd().readFileAlloc(io, "/proc/self/exe", gpa, .limited(1 << 30)) catch return error.SkipZigTest;
    defer gpa.free(data);
    const before = try sectionNames(gpa, data);
    defer gpa.free(before);
    if (!hasName(before, ".symtab")) return error.SkipZigTest; // already stripped

    const out = try strip(gpa, data);
    defer gpa.free(out);
    try std.testing.expect(out.len < data.len);
    const after = try sectionNames(gpa, out);
    defer gpa.free(after);
    try std.testing.expect(!hasName(after, ".symtab"));
    try std.testing.expect(!hasName(after, ".strtab"));
    for (after) |n| try std.testing.expect(!isDebugName(n));
    try std.testing.expect(hasName(after, ".text"));
    try std.testing.expect(hasName(after, ".shstrtab"));
    // The loaded image (headers and segments) is unchanged.
    try std.testing.expectEqualSlices(u8, data[0..32], out[0..32]);
    const phoff = std.mem.readInt(u64, data[32..40], builtin.cpu.arch.endian());
    const phend = phoff + @as(u64, std.mem.readInt(u16, data[54..56], builtin.cpu.arch.endian())) * std.mem.readInt(u16, data[56..58], builtin.cpu.arch.endian());
    try std.testing.expectEqualSlices(u8, data[@intCast(phoff)..@intCast(phend)], out[@intCast(phoff)..@intCast(phend)]);

    // Stripping again changes nothing.
    const again = try strip(gpa, out);
    defer gpa.free(again);
    try std.testing.expectEqualSlices(u8, out, again);
}

test "strip refuses non-ELF input" {
    try std.testing.expectError(error.NotElf, strip(std.testing.allocator, "MZ\x90\x00" ** 20));
    try std.testing.expectError(error.NotElf, strip(std.testing.allocator, "\x7fELF"));
}
