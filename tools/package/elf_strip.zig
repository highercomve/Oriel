//! Strip an ELF executable or shared library for packaging (`strip-elf`):
//! drop the static symbol table (`.symtab` and its string table), the debug
//! sections, and non-allocated sections tied to them (relocations for them,
//! groups), like `strip --strip-all`. Everything the loader uses is kept byte
//! for byte at the same offsets: the program headers and every segment's
//! contents (so `.dynsym`, `.dynstr` and `.dynamic` too: symbols an
//! `-rdynamic` executable exports to its plugins stay). Loaded bytes are never
//! rewritten: a file whose dynamic symbols would need renumbering (they name
//! a dropped or moved section) is refused with `error.UnsupportedElf`.
//!
//! Dropped sections past the loaded image are cut off; dropped sections
//! inside its file span (Zig's own linker puts debug sections between
//! segments) are zero-filled when they overlap no segment and no kept section.
//!
//! `zig objcopy` can't strip ELF files yet (Zig 0.16: "unimplemented"), and a
//! host `strip` would make packages depend on binutils (and its target
//! support), so this is done here. Handles 32- and 64-bit ELF of either
//! endianness; relocatable objects are refused. Malformed input returns an
//! error, never crashes.

const std = @import("std");

pub const Error = error{ NotElf, UnsupportedElf, InvalidElf, Truncated, OutOfMemory };

const SHT_SYMTAB = 2;
const SHT_STRTAB = 3;
const SHT_RELA = 4;
const SHT_NOBITS = 8;
const SHT_REL = 9;
const SHT_DYNSYM = 11;
const SHF_ALLOC = 0x2;
const SHF_INFO_LINK = 0x40;
const SHN_LORESERVE = 0xff00;
const ET_EXEC = 2;
const ET_DYN = 3;
const PT_LOAD = 1;

/// `off + size`, or `error.InvalidElf` when it overflows.
fn end(off: u64, size: u64) Error!u64 {
    return std.math.add(u64, off, size) catch error.InvalidElf;
}

fn mul(a: u64, b: u64) Error!u64 {
    return std.math.mul(u64, a, b) catch error.InvalidElf;
}

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

    fn shdrSize(l: Layout) u16 {
        return if (l.is64) 64 else 40;
    }

    fn phdrSize(l: Layout) u16 {
        return if (l.is64) 56 else 32;
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

    /// Occupies bytes in the file.
    fn hasData(s: Section) bool {
        return s.type != SHT_NOBITS and s.size > 0;
    }
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
    };
}

pub fn isElf(data: []const u8) bool {
    return data.len >= 4 and std.mem.eql(u8, data[0..4], "\x7fELF");
}

const Range = struct { start: u64, end: u64 };

fn overlaps(a: Range, b: Range) bool {
    return a.start < b.end and b.start < a.end;
}

/// A stripped copy of the ELF image `data` (caller frees). A file without
/// section headers, or with nothing to strip, is returned as is.
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
    if (ehsize > data.len) return error.Truncated;

    // The tables must lie inside the file, with whole entries.
    const ph_end = try end(phoff, try mul(phnum, phentsize));
    if (phnum > 0 and (phentsize < l.phdrSize() or ph_end > data.len)) return error.InvalidElf;

    if (shoff == 0 or shnum == 0) {
        // No section headers, or extended numbering (e_shnum == 0 with a
        // section table): nothing to strip / not handled.
        if (shoff != 0) return error.UnsupportedElf;
        return gpa.dupe(u8, data);
    }
    if (shstrndx >= shnum) return error.UnsupportedElf; // includes SHN_XINDEX
    if (shentsize < l.shdrSize()) return error.InvalidElf;
    const sh_end = try end(shoff, try mul(shnum, shentsize));
    if (sh_end > data.len) return error.InvalidElf;

    const sections = try gpa.alloc(Section, shnum);
    defer gpa.free(sections);
    for (sections, 0..) |*s, i| {
        s.* = try readSection(l, data, shoff + @as(u64, i) * shentsize);
        if (s.addralign != 0 and !std.math.isPowerOfTwo(s.addralign)) return error.InvalidElf;
        if (s.type != SHT_NOBITS and try end(s.offset, s.size) > data.len) return error.InvalidElf;
    }
    const names = sections[shstrndx];

    // 1. What goes: the static symbol table and its string table, debug
    // sections, then (until nothing changes) non-allocated sections linked to
    // a dropped one (relocations against the symbol table, groups, ...) and
    // relocations applying to a dropped section.
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
    var changed = true;
    while (changed) {
        changed = false;
        for (sections, 0..) |s, i| {
            if (i == 0 or i == shstrndx or s.flags & SHF_ALLOC != 0 or drop[i]) continue;
            const link_dropped = s.link != 0 and s.link < shnum and drop[s.link];
            const is_rel = s.type == SHT_REL or s.type == SHT_RELA;
            const target_dropped = is_rel and s.info != 0 and s.info < shnum and drop[s.info];
            if (link_dropped or target_dropped) {
                drop[i] = true;
                changed = true;
            }
        }
    }

    const new_index = try gpa.alloc(u32, shnum);
    defer gpa.free(new_index);
    var kept: u32 = 0;
    for (drop, 0..) |d, i| {
        new_index[i] = if (d) 0 else kept;
        if (!d) kept += 1;
    }
    if (kept == shnum) return gpa.dupe(u8, data); // nothing to strip

    // Dynamic symbols name their section by index, in loaded memory that is
    // never rewritten: refuse when an index would change.
    for (sections, 0..) |s, i| {
        if (drop[i] or s.type != SHT_DYNSYM) continue;
        const entsize: u64 = if (l.is64) 24 else 16;
        const shndx_at: u64 = if (l.is64) 6 else 14;
        const count = s.size / entsize;
        for (0..count) |k| {
            const shndx = try l.int(u16, data, s.offset + k * entsize + shndx_at);
            if (shndx != 0 and shndx < SHN_LORESERVE and shndx < shnum and (drop[shndx] or new_index[shndx] != shndx)) return error.UnsupportedElf;
        }
    }

    // 2. The loaded image: everything up to the end of the last segment (and
    // of the headers), copied unchanged. Protected: the headers, segments and
    // kept sections; dropped bytes inside it are zero-filled.
    var protected: std.ArrayList(Range) = .empty;
    defer protected.deinit(gpa);
    try protected.append(gpa, .{ .start = 0, .end = ehsize });
    var keep_end: u64 = ehsize;
    if (phnum > 0) {
        try protected.append(gpa, .{ .start = phoff, .end = ph_end });
        keep_end = @max(keep_end, ph_end);
    }
    for (0..phnum) |i| {
        const ph = phoff + @as(u64, i) * phentsize;
        const p_type = try l.int(u32, data, ph);
        const off = try l.addr(data, ph + (if (l.is64) @as(u64, 8) else 4));
        const filesz = try l.addr(data, ph + (if (l.is64) @as(u64, 32) else 16));
        const seg_end = try end(off, filesz);
        if (seg_end > data.len) return error.InvalidElf;
        keep_end = @max(keep_end, seg_end);
        // Every segment type (PT_LOAD and what they point into, e.g. notes).
        if (filesz > 0 or p_type == PT_LOAD) try protected.append(gpa, .{ .start = off, .end = seg_end });
    }
    for (sections, 0..) |s, i| {
        if (i == 0 or drop[i] or !s.hasData()) continue;
        const r: Range = .{ .start = s.offset, .end = s.offset + s.size };
        try protected.append(gpa, r);
        if (s.flags & SHF_ALLOC != 0) keep_end = @max(keep_end, r.end);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, data[0..@intCast(keep_end)]);

    // Zero-fill dropped sections (and the old section header table) inside
    // the image when they touch nothing protected.
    var zero_ranges: std.ArrayList(Range) = .empty;
    defer zero_ranges.deinit(gpa);
    try zero_ranges.append(gpa, .{ .start = shoff, .end = sh_end });
    for (sections, 0..) |s, i| {
        if (drop[i] and s.hasData()) try zero_ranges.append(gpa, .{ .start = s.offset, .end = s.offset + s.size });
    }
    for (zero_ranges.items) |z| {
        if (z.start >= keep_end) continue;
        for (protected.items) |p| {
            if (overlaps(z, p)) break;
        } else @memset(out.items[@intCast(z.start)..@intCast(@min(z.end, keep_end))], 0);
    }

    // 3. Kept non-loaded sections past the image move up behind it.
    const new_offset = try gpa.alloc(u64, shnum);
    defer gpa.free(new_offset);
    for (sections, 0..) |s, i| {
        new_offset[i] = s.offset;
        if (i == 0 or drop[i] or !s.hasData()) continue;
        if (s.offset + s.size <= keep_end) continue;
        try alignOut(gpa, &out, @max(s.addralign, 1));
        new_offset[i] = out.items.len;
        try out.appendSlice(gpa, data[@intCast(s.offset)..][0..@intCast(s.size)]);
    }
    // Non-allocated NOBITS sections can't point past the end of the file.
    const data_end = out.items.len;
    for (sections, 0..) |s, i| {
        if (i != 0 and !drop[i] and s.type == SHT_NOBITS and s.flags & SHF_ALLOC == 0 and s.offset > data_end) new_offset[i] = data_end;
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
            l.put(u32, out.items, at + 16, std.math.cast(u32, new_offset[i]) orelse return error.InvalidElf);
            l.put(u32, out.items, at + 24, link);
            l.put(u32, out.items, at + 28, info);
        }
    }
    if (!l.is64 and new_shoff > std.math.maxInt(u32)) return error.InvalidElf;
    l.putAddr(out.items, if (l.is64) 40 else 32, new_shoff);
    l.put(u16, out.items, hdr + 8, @intCast(kept));
    l.put(u16, out.items, hdr + 10, @intCast(new_index[shstrndx]));
    return out.toOwnedSlice(gpa);
}

fn alignOut(gpa: std.mem.Allocator, out: *std.ArrayList(u8), alignment: u64) !void {
    const target = std.mem.alignForward(u64, out.items.len, alignment);
    try out.appendNTimes(gpa, 0, @intCast(target - out.items.len));
}

/// The name at `name` in the section name table, "" when out of range.
fn sectionName(data: []const u8, names: Section, name: u32) []const u8 {
    const table_end = end(names.offset, names.size) catch return "";
    if (names.type == SHT_NOBITS or table_end > data.len or name >= names.size) return "";
    const table = data[@intCast(names.offset)..@intCast(table_end)];
    return std.mem.sliceTo(table[name..], 0);
}

/// Debug sections. `.gnu_debuglink` / `.gnu_debugaltlink` stay (as with GNU
/// strip): they point at separate debug files.
fn isDebugName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, ".debug") or std.mem.startsWith(u8, name, ".zdebug") or
        std.mem.startsWith(u8, name, ".stab");
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
    errdefer gpa.free(list);
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

// ---------------------------------------------------------------------------
// Synthetic files: ELF32 little-endian and ELF64 big-endian, with one PT_LOAD
// segment holding .text and .dynsym, and non-allocated sections to drop.
// ---------------------------------------------------------------------------

/// `hole`: a second PT_LOAD over .comment, so .debug_info lies between two
/// segments; the rest are corruptions.
const Corruption = enum { none, hole, phoff, filesz, sec_offset, align3, shstr_size, shentsize, shoff, dynsym_dropped };

/// Section indices of the synthetic file.
const S = struct {
    const text = 1;
    const dynsym = 2;
    const debug = 3;
    const symtab = 4;
    const strtab = 5;
    const rela_debug = 6; // non-allocated, relocates .debug_info (link: .symtab)
    const rela_text = 7; // non-allocated (--emit-relocs), link: .symtab
    const comment = 8;
    const shstrtab = 9;
    const count = 10;
};

const Synth = struct {
    l: Layout,
    buf: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,

    fn int(w: *Synth, comptime T: type, v: T) !void {
        var b: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &b, v, w.l.endian);
        try w.buf.appendSlice(w.gpa, &b);
    }
    fn addr(w: *Synth, v: u64) !void {
        if (w.l.is64) try w.int(u64, v) else try w.int(u32, @intCast(v));
    }
    fn pad(w: *Synth, alignment: usize) !void {
        while (w.buf.items.len % alignment != 0) try w.buf.append(w.gpa, 0);
    }
};

fn synth(gpa: std.mem.Allocator, is64: bool, endian: std.builtin.Endian, c: Corruption) ![]u8 {
    const l: Layout = .{ .is64 = is64, .endian = endian };
    var w: Synth = .{ .l = l, .gpa = gpa };
    errdefer w.buf.deinit(gpa);
    const ehsize: u16 = if (is64) 64 else 52;
    try w.buf.appendNTimes(gpa, 0, ehsize + 2 * @as(usize, l.phdrSize())); // header and phdrs, written below
    // Loaded: .text and .dynsym (one null and one defined symbol).
    try w.pad(16);
    const text_off = w.buf.items.len;
    try w.buf.appendSlice(gpa, "\xc3" ** 16);
    try w.pad(8);
    const dynsym_off = w.buf.items.len;
    const entsize: u64 = if (is64) 24 else 16;
    try w.buf.appendNTimes(gpa, 0, @intCast(entsize)); // null symbol
    const shndx: u16 = if (c == .dynsym_dropped) S.debug else S.text;
    if (is64) {
        try w.int(u32, 0);
        try w.buf.appendSlice(gpa, &.{ 0x12, 0 });
        try w.int(u16, shndx);
        try w.int(u64, text_off);
        try w.int(u64, 16);
    } else {
        try w.int(u32, 0);
        try w.int(u32, @intCast(text_off));
        try w.int(u32, 16);
        try w.buf.appendSlice(gpa, &.{ 0x12, 0 });
        try w.int(u16, shndx);
    }
    const load_end = w.buf.items.len;
    // Not loaded.
    const debug_off = w.buf.items.len;
    try w.buf.appendSlice(gpa, "DEBUGDEBUG");
    try w.pad(8);
    const symtab_off = w.buf.items.len;
    try w.buf.appendNTimes(gpa, 0, @intCast(entsize));
    const strtab_off = w.buf.items.len;
    try w.buf.append(gpa, 0);
    try w.pad(8);
    const rela_size: u64 = if (is64) 24 else 12;
    const rela_debug_off = w.buf.items.len;
    try w.buf.appendNTimes(gpa, 0, @intCast(rela_size));
    const rela_text_off = w.buf.items.len;
    try w.buf.appendNTimes(gpa, 0, @intCast(rela_size));
    const comment_off = w.buf.items.len;
    try w.buf.appendSlice(gpa, "zig\x00");
    const shstr = "\x00.text\x00.dynsym\x00.debug_info\x00.symtab\x00.strtab\x00.rela.debug_info\x00.rela.text\x00.comment\x00.shstrtab\x00";
    const shstr_off = w.buf.items.len;
    try w.buf.appendSlice(gpa, shstr);
    try w.pad(8);
    const shoff = w.buf.items.len;

    const Sh = struct { name: []const u8, type: u32, flags: u64, off: u64, size: u64, link: u32 = 0, info: u32 = 0, al: u64 = 1, es: u64 = 0 };
    const secs = [S.count]Sh{
        .{ .name = "", .type = 0, .flags = 0, .off = 0, .size = 0, .al = 0 },
        .{ .name = ".text", .type = 1, .flags = SHF_ALLOC | 0x4, .off = text_off, .size = 16, .al = 16 },
        .{ .name = ".dynsym", .type = SHT_DYNSYM, .flags = SHF_ALLOC, .off = dynsym_off, .size = 2 * entsize, .link = 0, .info = 1, .al = 8, .es = entsize },
        .{ .name = ".debug_info", .type = 1, .flags = 0, .off = debug_off, .size = 10, .al = if (c == .align3) 3 else 1 },
        .{ .name = ".symtab", .type = SHT_SYMTAB, .flags = 0, .off = symtab_off, .size = entsize, .link = S.strtab, .info = 1, .al = 8, .es = entsize },
        .{ .name = ".strtab", .type = SHT_STRTAB, .flags = 0, .off = if (c == .sec_offset) std.math.maxInt(u32) - 4 else strtab_off, .size = 1 },
        .{ .name = ".rela.debug_info", .type = SHT_RELA, .flags = SHF_INFO_LINK, .off = rela_debug_off, .size = rela_size, .link = S.symtab, .info = S.debug, .al = 8, .es = rela_size },
        .{ .name = ".rela.text", .type = SHT_RELA, .flags = SHF_INFO_LINK, .off = rela_text_off, .size = rela_size, .link = S.symtab, .info = S.text, .al = 8, .es = rela_size },
        .{ .name = ".comment", .type = 1, .flags = 0x30, .off = comment_off, .size = 4, .es = 1 },
        .{ .name = ".shstrtab", .type = SHT_STRTAB, .flags = 0, .off = shstr_off, .size = if (c == .shstr_size) std.math.maxInt(u32) - 8 else shstr.len },
    };
    for (secs) |s| {
        const name: u32 = if (s.name.len == 0) 0 else @intCast(std.mem.indexOf(u8, shstr, s.name).?);
        try w.int(u32, name);
        try w.int(u32, s.type);
        try w.addr(s.flags);
        try w.addr(0);
        try w.addr(s.off);
        try w.addr(s.size);
        try w.int(u32, s.link);
        try w.int(u32, s.info);
        try w.addr(s.al);
        try w.addr(s.es);
    }

    // The ELF header and the program header.
    const data = w.buf.items;
    data[0..4].* = "\x7fELF".*;
    data[4] = if (is64) 2 else 1;
    data[5] = if (endian == .little) 1 else 2;
    data[6] = 1;
    var h: usize = 16;
    const put = struct {
        fn f(buf: []u8, lay: Layout, at: *usize, comptime T: type, v: u64) void {
            std.mem.writeInt(T, buf[at.*..][0..@sizeOf(T)], @intCast(v), lay.endian);
            at.* += @sizeOf(T);
        }
        fn a(buf: []u8, lay: Layout, at: *usize, v: u64) void {
            if (lay.is64) f(buf, lay, at, u64, v) else f(buf, lay, at, u32, v);
        }
    };
    put.f(data, l, &h, u16, ET_DYN);
    put.f(data, l, &h, u16, 62);
    put.f(data, l, &h, u32, 1);
    put.a(data, l, &h, 0); // entry
    put.a(data, l, &h, if (c == .phoff) (if (is64) std.math.maxInt(u64) - 8 else std.math.maxInt(u32) - 8) else ehsize);
    put.a(data, l, &h, if (c == .shoff) (if (is64) std.math.maxInt(u64) - 8 else std.math.maxInt(u32) - 8) else shoff);
    put.f(data, l, &h, u32, 0);
    put.f(data, l, &h, u16, ehsize);
    put.f(data, l, &h, u16, l.phdrSize());
    put.f(data, l, &h, u16, if (c == .hole) 2 else 1);
    put.f(data, l, &h, u16, if (c == .shentsize) l.shdrSize() + 32 else l.shdrSize());
    put.f(data, l, &h, u16, S.count);
    put.f(data, l, &h, u16, S.shstrtab);
    var p: usize = ehsize;
    const filesz: u64 = if (c == .filesz) (if (is64) std.math.maxInt(u64) - 8 else std.math.maxInt(u32) - 8) else load_end;
    writePhdr(data, l, &p, 0, filesz);
    if (c == .hole) writePhdr(data, l, &p, comment_off, 4);
    return w.buf.toOwnedSlice(gpa);
}

fn writePhdr(data: []u8, l: Layout, at: *usize, off: u64, filesz: u64) void {
    const fields64 = [_]struct { u64, u8 }{ .{ PT_LOAD, 4 }, .{ 5, 4 }, .{ off, 8 }, .{ off, 8 }, .{ off, 8 }, .{ filesz, 8 }, .{ filesz, 8 }, .{ 0x1000, 8 } };
    const fields32 = [_]struct { u64, u8 }{ .{ PT_LOAD, 4 }, .{ off, 4 }, .{ off, 4 }, .{ off, 4 }, .{ filesz, 4 }, .{ filesz, 4 }, .{ 5, 4 }, .{ 0x1000, 4 } };
    for (if (l.is64) &fields64 else &fields32) |fld| {
        if (fld[1] == 8) {
            std.mem.writeInt(u64, data[at.*..][0..8], fld[0], l.endian);
        } else {
            std.mem.writeInt(u32, data[at.*..][0..4], @truncate(fld[0]), l.endian);
        }
        at.* += fld[1];
    }
}

const synth_formats = [_]struct { is64: bool, endian: std.builtin.Endian }{
    .{ .is64 = false, .endian = .little },
    .{ .is64 = true, .endian = .big },
};

test "strip synthetic ELF32-LE and ELF64-BE files" {
    const gpa = std.testing.allocator;
    for (synth_formats) |f| {
        const data = try synth(gpa, f.is64, f.endian, .none);
        defer gpa.free(data);
        const out = try strip(gpa, data);
        defer gpa.free(out);
        const after = try sectionNames(gpa, out);
        defer gpa.free(after);
        // Dropped: .symtab, .strtab, .debug_info, and the relocations linked
        // to the symbol table (even the one for the kept .text).
        try std.testing.expectEqual(@as(usize, 5), after.len);
        for ([_][]const u8{ "", ".text", ".dynsym", ".comment", ".shstrtab" }, after) |want, got| try std.testing.expectEqualStrings(want, got);
        // The loaded bytes are unchanged; nothing of the dropped data remains.
        const l: Layout = .{ .is64 = f.is64, .endian = f.endian };
        const load_end = try l.addr(data, (try l.addr(data, if (f.is64) 32 else 28)) + (if (f.is64) @as(u64, 32) else 16));
        // (The ELF header's section table fields change.)
        const ehsize: usize = if (f.is64) 64 else 52;
        try std.testing.expectEqualSlices(u8, data[ehsize..@intCast(load_end)], out[ehsize..@intCast(load_end)]);
        try std.testing.expect(std.mem.indexOf(u8, out, "DEBUG") == null);
        // Idempotent.
        const again = try strip(gpa, out);
        defer gpa.free(again);
        try std.testing.expectEqualSlices(u8, out, again);
    }
}

test "strip returns an error for corrupt files" {
    const gpa = std.testing.allocator;
    for (synth_formats) |f| {
        for ([_]Corruption{ .phoff, .filesz, .sec_offset, .align3, .shstr_size, .shentsize, .shoff, .dynsym_dropped }) |c| {
            const data = try synth(gpa, f.is64, f.endian, c);
            defer gpa.free(data);
            if (strip(gpa, data)) |out| {
                gpa.free(out);
                std.debug.print("no error for {s} (64-bit: {})\n", .{ @tagName(c), f.is64 });
                return error.TestUnexpectedResult;
            } else |_| {}
        }
    }
}

test "strip zero-fills dropped sections between segments" {
    const gpa = std.testing.allocator;
    for (synth_formats) |f| {
        const data = try synth(gpa, f.is64, f.endian, .hole);
        defer gpa.free(data);
        const out = try strip(gpa, data);
        defer gpa.free(out);
        // .debug_info sat between the segments: zeroed, the segments intact.
        try std.testing.expect(std.mem.indexOf(u8, data, "DEBUGDEBUG") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "DEBUG") == null);
        const comment = std.mem.indexOf(u8, data, "zig\x00").?;
        try std.testing.expectEqualStrings("zig\x00", out[comment..][0..4]);
        const l: Layout = .{ .is64 = f.is64, .endian = f.endian };
        const load_end = try l.addr(data, (try l.addr(data, if (f.is64) 32 else 28)) + (if (f.is64) @as(u64, 32) else 16));
        // (The ELF header's section table fields change.)
        const ehsize: usize = if (f.is64) 64 else 52;
        try std.testing.expectEqualSlices(u8, data[ehsize..@intCast(load_end)], out[ehsize..@intCast(load_end)]);
    }
}
