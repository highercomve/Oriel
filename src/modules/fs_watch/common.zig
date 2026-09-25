//! Platform-neutral types and pure parsers for file-system watch events.
//!
//! Windows ReadDirectoryChangesW returns a buffer containing one or more
//! FILE_NOTIFY_INFORMATION structures linked by NextEntryOffset.

const std = @import("std");
/// FILE_NOTIFY_INFORMATION actions (winnt.h). Declared here rather than
/// imported from win32.zig: this parser is unit-tested on every OS, and
/// win32.zig doesn't compile for arm64 non-Windows targets.
const win32 = struct {
    const FILE_ACTION_ADDED: u32 = 1;
    const FILE_ACTION_REMOVED: u32 = 2;
    const FILE_ACTION_MODIFIED: u32 = 3;
    const FILE_ACTION_RENAMED_OLD_NAME: u32 = 4;
    const FILE_ACTION_RENAMED_NEW_NAME: u32 = 5;
};

/// Platform-neutral alignment required for the event buffer passed to `poll`.
pub const buffer_align = @alignOf(u32);

pub const Event = struct {
    pub const Kind = enum { created, modified, deleted, other };
    kind: Kind,
    name: []const u8,
};

/// Cursor tracking progress through a completed FILE_NOTIFY_INFORMATION buffer.
/// Allows incremental polling when the caller's output buffers fill up.
pub const Cursor = struct {
    record_offset: usize = 0,
    done: bool = true,
    overflow_pending: bool = false,

    pub fn init() Cursor {
        return .{
            .record_offset = 0,
            .done = true,
            .overflow_pending = false,
        };
    }

    /// Reset cursor for a new completed buffer.
    /// If `bytes_transferred == 0`, indicates kernel buffer overflow; marks an overflow event to be yielded.
    pub fn resetWithBuffer(self: *Cursor, bytes_transferred: usize) void {
        self.record_offset = 0;
        if (bytes_transferred == 0) {
            self.overflow_pending = true;
            self.done = false;
        } else {
            self.overflow_pending = false;
            self.done = false;
        }
    }

    pub fn isDone(self: Cursor) bool {
        return self.done;
    }

    /// Parse records from `raw_buffer` into `out_events` and decoded filenames into `out_name_buf`.
    /// Advances `record_offset`. If all records are consumed, marks `done = true`.
    /// If `out_events` or `out_name_buf` is filled before all records are consumed, leaves `done = false`.
    /// If a single name cannot fit in `out_name_buf` (at offset 0), skips the record and returns error.BufferTooSmall
    /// so the watcher does not wedge forever.
    pub fn read(
        self: *Cursor,
        raw_buffer: []const u8,
        out_name_buf: []u8,
        out_events: []Event,
    ) error{ MalformedRecord, BufferTooSmall }!usize {
        if (self.done or out_events.len == 0) return 0;

        if (self.overflow_pending) {
            out_events[0] = .{
                .kind = .other,
                .name = "",
            };
            self.overflow_pending = false;
            self.done = true;
            return 1;
        }

        var n: usize = 0;
        var name_buf_offset: usize = 0;

        while (n < out_events.len and !self.done) {
            if (self.record_offset + 12 > raw_buffer.len) {
                self.done = true;
                return error.MalformedRecord;
            }

            const next_entry_offset = std.mem.readInt(u32, raw_buffer[self.record_offset..][0..4], .little);
            const action = std.mem.readInt(u32, raw_buffer[self.record_offset + 4 ..][0..4], .little);
            const filename_len_bytes = std.mem.readInt(u32, raw_buffer[self.record_offset + 8 ..][0..4], .little);

            if (filename_len_bytes % 2 != 0) {
                self.done = true;
                return error.MalformedRecord;
            }
            const name_start = self.record_offset + 12;
            const name_end = name_start + filename_len_bytes;
            if (name_end > raw_buffer.len) {
                self.done = true;
                return error.MalformedRecord;
            }

            if (next_entry_offset > 0) {
                if (next_entry_offset < 12 or self.record_offset + next_entry_offset > raw_buffer.len) {
                    self.done = true;
                    return error.MalformedRecord;
                }
            }

            const u16_len = filename_len_bytes / 2;
            const remaining_name_buf = out_name_buf[name_buf_offset..];
            var utf8_written: usize = 0;
            var i: usize = 0;
            var buf_too_small = false;

            while (i < u16_len) {
                const c1 = std.mem.readInt(u16, raw_buffer[name_start + i * 2 ..][0..2], .little);
                i += 1;
                const codepoint: u21 = if (c1 >= 0xD800 and c1 <= 0xDBFF) blk: {
                    if (i < u16_len) {
                        const c2 = std.mem.readInt(u16, raw_buffer[name_start + i * 2 ..][0..2], .little);
                        if (c2 >= 0xDC00 and c2 <= 0xDFFF) {
                            i += 1;
                            break :blk (@as(u21, c1 - 0xD800) << 10) | @as(u21, c2 - 0xDC00) + 0x10000;
                        }
                    }
                    break :blk std.unicode.replacement_character;
                } else if (c1 >= 0xDC00 and c1 <= 0xDFFF)
                    std.unicode.replacement_character
                else
                    @as(u21, c1);

                var enc_buf: [4]u8 = undefined;
                const enc_len = std.unicode.utf8Encode(codepoint, &enc_buf) catch continue;
                if (utf8_written + enc_len > remaining_name_buf.len) {
                    buf_too_small = true;
                    break;
                }
                @memcpy(remaining_name_buf[utf8_written..][0..enc_len], enc_buf[0..enc_len]);
                utf8_written += enc_len;
            }

            if (buf_too_small) {
                // If earlier records in this call succeeded, return them first;
                // do NOT advance record_offset, so the next poll with a fresh name_buf can try it.
                if (n > 0) {
                    return n;
                }
                // If even an empty name buffer (n == 0) cannot fit this name, skip the record
                // and return error.BufferTooSmall so the watcher is not wedged forever.
                if (next_entry_offset == 0) {
                    self.done = true;
                } else {
                    self.record_offset += next_entry_offset;
                }
                return error.BufferTooSmall;
            }

            const utf8_name = remaining_name_buf[0..utf8_written];
            name_buf_offset += utf8_written;

            const kind: Event.Kind = switch (action) {
                win32.FILE_ACTION_ADDED => .created,
                win32.FILE_ACTION_REMOVED => .deleted,
                win32.FILE_ACTION_MODIFIED => .modified,
                win32.FILE_ACTION_RENAMED_OLD_NAME => .deleted,
                win32.FILE_ACTION_RENAMED_NEW_NAME => .created,
                else => .other,
            };

            out_events[n] = .{
                .kind = kind,
                .name = utf8_name,
            };
            n += 1;

            if (next_entry_offset == 0) {
                self.done = true;
                break;
            }
            self.record_offset += next_entry_offset;
        }

        return n;
    }
};

/// Parse a raw buffer of Win32 FILE_NOTIFY_INFORMATION records.
/// Decodes UTF-16LE filenames into UTF-8 stored in `out_name_buf`, and populates `out_events`.
/// Returns the number of events parsed.
pub fn parseFileNotifyInformation(
    raw_buffer: []const u8,
    out_name_buf: []u8,
    out_events: []Event,
) !usize {
    var cursor = Cursor.init();
    cursor.resetWithBuffer(raw_buffer.len);
    return cursor.read(raw_buffer, out_name_buf, out_events);
}

test "parseFileNotifyInformation single record" {
    // Record for "test.txt", action FILE_ACTION_ADDED (1)
    const name_w = [_]u16{ 't', 'e', 's', 't', '.', 't', 'x', 't' };
    const name_bytes = std.mem.sliceAsBytes(&name_w);

    var raw: [64]u8 = undefined;
    @memset(&raw, 0);
    std.mem.writeInt(u32, raw[0..4], 0, .little); // NextEntryOffset = 0 (last)
    std.mem.writeInt(u32, raw[4..8], win32.FILE_ACTION_ADDED, .little);
    std.mem.writeInt(u32, raw[8..12], @intCast(name_bytes.len), .little);
    @memcpy(raw[12 .. 12 + name_bytes.len], name_bytes);

    var name_buf: [128]u8 = undefined;
    var events: [4]Event = undefined;

    const count = try parseFileNotifyInformation(raw[0 .. 12 + name_bytes.len], &name_buf, &events);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(Event.Kind.created, events[0].kind);
    try std.testing.expectEqualStrings("test.txt", events[0].name);
}

test "parseFileNotifyInformation chained records" {
    // Record 1: "file1", action FILE_ACTION_MODIFIED, NextEntryOffset = 24
    // Record 2: "file2", action FILE_ACTION_REMOVED, NextEntryOffset = 0
    const name1_w = [_]u16{ 'f', 'i', 'l', 'e', '1' };
    const name1_bytes = std.mem.sliceAsBytes(&name1_w); // 10 bytes
    // Header 12 + 10 = 22 bytes, padded to 24 bytes for NextEntryOffset
    const rec1_size = 24;

    const name2_w = [_]u16{ 'f', 'i', 'l', 'e', '2' };
    const name2_bytes = std.mem.sliceAsBytes(&name2_w); // 10 bytes
    const rec2_size = 12 + name2_bytes.len; // 22 bytes

    var raw: [128]u8 = undefined;
    @memset(&raw, 0);

    // Record 1
    std.mem.writeInt(u32, raw[0..4], rec1_size, .little);
    std.mem.writeInt(u32, raw[4..8], win32.FILE_ACTION_MODIFIED, .little);
    std.mem.writeInt(u32, raw[8..12], @intCast(name1_bytes.len), .little);
    @memcpy(raw[12 .. 12 + name1_bytes.len], name1_bytes);

    // Record 2
    const off2 = rec1_size;
    std.mem.writeInt(u32, raw[off2..][0..4], 0, .little); // Last record
    std.mem.writeInt(u32, raw[off2 + 4 ..][0..4], win32.FILE_ACTION_REMOVED, .little);
    std.mem.writeInt(u32, raw[off2 + 8 ..][0..4], @intCast(name2_bytes.len), .little);
    @memcpy(raw[off2 + 12 .. off2 + 12 + name2_bytes.len], name2_bytes);

    var name_buf: [128]u8 = undefined;
    var events: [4]Event = undefined;

    const count = try parseFileNotifyInformation(raw[0 .. rec1_size + rec2_size], &name_buf, &events);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(Event.Kind.modified, events[0].kind);
    try std.testing.expectEqualStrings("file1", events[0].name);
    try std.testing.expectEqual(Event.Kind.deleted, events[1].kind);
    try std.testing.expectEqualStrings("file2", events[1].name);
}

test "parseFileNotifyInformation action mapping" {
    // Actions RENAMED_OLD -> deleted and RENAMED_NEW -> created
    const name_w = [_]u16{'a'};
    const name_bytes = std.mem.sliceAsBytes(&name_w);

    var raw: [16]u8 = undefined;
    @memset(&raw, 0);
    std.mem.writeInt(u32, raw[8..12], @intCast(name_bytes.len), .little);
    @memcpy(raw[12..14], name_bytes);

    var name_buf: [32]u8 = undefined;
    var events: [1]Event = undefined;

    // Action RENAMED_OLD_NAME
    std.mem.writeInt(u32, raw[4..8], win32.FILE_ACTION_RENAMED_OLD_NAME, .little);
    _ = try parseFileNotifyInformation(&raw, &name_buf, &events);
    try std.testing.expectEqual(Event.Kind.deleted, events[0].kind);

    // Action RENAMED_NEW_NAME
    std.mem.writeInt(u32, raw[4..8], win32.FILE_ACTION_RENAMED_NEW_NAME, .little);
    _ = try parseFileNotifyInformation(&raw, &name_buf, &events);
    try std.testing.expectEqual(Event.Kind.created, events[0].kind);

    // Unknown action (e.g. 99)
    std.mem.writeInt(u32, raw[4..8], 99, .little);
    _ = try parseFileNotifyInformation(&raw, &name_buf, &events);
    try std.testing.expectEqual(Event.Kind.other, events[0].kind);
}

test "parseFileNotifyInformation rejects malformed offsets and lengths" {
    var raw: [32]u8 = undefined;
    @memset(&raw, 0);
    var name_buf: [32]u8 = undefined;
    var events: [2]Event = undefined;

    // 1. Odd FileNameLength
    std.mem.writeInt(u32, raw[8..12], 5, .little);
    try std.testing.expectError(error.MalformedRecord, parseFileNotifyInformation(&raw, &name_buf, &events));

    // 2. FileNameLength extending past buffer
    std.mem.writeInt(u32, raw[8..12], 40, .little);
    try std.testing.expectError(error.MalformedRecord, parseFileNotifyInformation(&raw, &name_buf, &events));

    // 3. NextEntryOffset extending past buffer
    std.mem.writeInt(u32, raw[8..12], 4, .little); // valid name length (4 bytes)
    std.mem.writeInt(u32, raw[0..4], 100, .little); // next entry at 100 > buffer.len (32)
    try std.testing.expectError(error.MalformedRecord, parseFileNotifyInformation(&raw, &name_buf, &events));

    // 4. NextEntryOffset < 12 (backward / zero loop)
    std.mem.writeInt(u32, raw[0..4], 8, .little);
    try std.testing.expectError(error.MalformedRecord, parseFileNotifyInformation(&raw, &name_buf, &events));
}

test "Cursor: a buffer with 3 records polled with out.len = 1 yields all 3 over 3 calls" {
    const name1_w = [_]u16{ 'f', '1' };
    const name2_w = [_]u16{ 'f', '2' };
    const name3_w = [_]u16{ 'f', '3' };
    const n1_bytes = std.mem.sliceAsBytes(&name1_w);
    const n2_bytes = std.mem.sliceAsBytes(&name2_w);
    const n3_bytes = std.mem.sliceAsBytes(&name3_w);

    var raw: [128]u8 = undefined;
    @memset(&raw, 0);

    // Record 1: next = 24
    std.mem.writeInt(u32, raw[0..4], 24, .little);
    std.mem.writeInt(u32, raw[4..8], win32.FILE_ACTION_ADDED, .little);
    std.mem.writeInt(u32, raw[8..12], @intCast(n1_bytes.len), .little);
    @memcpy(raw[12 .. 12 + n1_bytes.len], n1_bytes);

    // Record 2: next = 24
    std.mem.writeInt(u32, raw[24..28], 24, .little);
    std.mem.writeInt(u32, raw[28..32], win32.FILE_ACTION_MODIFIED, .little);
    std.mem.writeInt(u32, raw[32..36], @intCast(n2_bytes.len), .little);
    @memcpy(raw[36 .. 36 + n2_bytes.len], n2_bytes);

    // Record 3: next = 0
    std.mem.writeInt(u32, raw[48..52], 0, .little);
    std.mem.writeInt(u32, raw[52..56], win32.FILE_ACTION_REMOVED, .little);
    std.mem.writeInt(u32, raw[56..60], @intCast(n3_bytes.len), .little);
    @memcpy(raw[60 .. 60 + n3_bytes.len], n3_bytes);

    const total_len = 48 + 12 + n3_bytes.len;

    var cursor = Cursor.init();
    cursor.resetWithBuffer(total_len);
    try std.testing.expect(!cursor.isDone());

    var name_buf: [64]u8 = undefined;
    var out: [1]Event = undefined;

    // Call 1
    const c1 = try cursor.read(raw[0..total_len], &name_buf, &out);
    try std.testing.expectEqual(@as(usize, 1), c1);
    try std.testing.expectEqual(Event.Kind.created, out[0].kind);
    try std.testing.expectEqualStrings("f1", out[0].name);
    try std.testing.expect(!cursor.isDone());

    // Call 2
    const c2 = try cursor.read(raw[0..total_len], &name_buf, &out);
    try std.testing.expectEqual(@as(usize, 1), c2);
    try std.testing.expectEqual(Event.Kind.modified, out[0].kind);
    try std.testing.expectEqualStrings("f2", out[0].name);
    try std.testing.expect(!cursor.isDone());

    // Call 3
    const c3 = try cursor.read(raw[0..total_len], &name_buf, &out);
    try std.testing.expectEqual(@as(usize, 1), c3);
    try std.testing.expectEqual(Event.Kind.deleted, out[0].kind);
    try std.testing.expectEqualStrings("f3", out[0].name);
    try std.testing.expect(cursor.isDone());

    // Call 4: already done
    const c4 = try cursor.read(raw[0..total_len], &name_buf, &out);
    try std.testing.expectEqual(@as(usize, 0), c4);
    try std.testing.expect(cursor.isDone());
}

test "Cursor: kernel buffer overflow reports one other event with empty name" {
    var cursor = Cursor.init();
    cursor.resetWithBuffer(0); // 0 bytes transferred = overflow
    try std.testing.expect(!cursor.isDone());

    var name_buf: [16]u8 = undefined;
    var out: [2]Event = undefined;

    const n = try cursor.read(&[_]u8{}, &name_buf, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(Event.Kind.other, out[0].kind);
    try std.testing.expectEqualStrings("", out[0].name);
    try std.testing.expect(cursor.isDone());
}

test "Cursor: BufferTooSmall on oversized name skips record and does not wedge" {
    // Record 1: "long_name_test", next = 48
    // Record 2: "ok", next = 0
    const long_w = [_]u16{ 'l', 'o', 'n', 'g', '_', 'n', 'a', 'm', 'e', '_', 't', 'e', 's', 't' };
    const short_w = [_]u16{ 'o', 'k' };
    const long_bytes = std.mem.sliceAsBytes(&long_w);
    const short_bytes = std.mem.sliceAsBytes(&short_w);

    var raw: [128]u8 = undefined;
    @memset(&raw, 0);

    const rec1_size = 48;
    std.mem.writeInt(u32, raw[0..4], rec1_size, .little);
    std.mem.writeInt(u32, raw[4..8], win32.FILE_ACTION_ADDED, .little);
    std.mem.writeInt(u32, raw[8..12], @intCast(long_bytes.len), .little);
    @memcpy(raw[12 .. 12 + long_bytes.len], long_bytes);

    std.mem.writeInt(u32, raw[rec1_size..][0..4], 0, .little);
    std.mem.writeInt(u32, raw[rec1_size + 4 ..][0..4], win32.FILE_ACTION_MODIFIED, .little);
    std.mem.writeInt(u32, raw[rec1_size + 8 ..][0..4], @intCast(short_bytes.len), .little);
    @memcpy(raw[rec1_size + 12 .. rec1_size + 12 + short_bytes.len], short_bytes);

    const total_len = rec1_size + 12 + short_bytes.len;

    var cursor = Cursor.init();
    cursor.resetWithBuffer(total_len);

    var tiny_buf: [4]u8 = undefined; // Too small for 14-char long_name_test, but fits 2-char "ok"
    var out: [1]Event = undefined;

    // Call 1: record 1 fails with BufferTooSmall and is skipped
    try std.testing.expectError(error.BufferTooSmall, cursor.read(raw[0..total_len], &tiny_buf, &out));
    try std.testing.expect(!cursor.isDone());

    // Call 2: record 2 ("ok") succeeds!
    const n = try cursor.read(raw[0..total_len], &tiny_buf, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("ok", out[0].name);
    try std.testing.expectEqual(Event.Kind.modified, out[0].kind);
    try std.testing.expect(cursor.isDone());
}

test "Cursor: buffer full from earlier records returns earlier records first" {
    // Record 1: "first", next = 24
    // Record 2: "second", next = 0
    const name1_w = [_]u16{ 'f', 'i', 'r', 's', 't' };
    const name2_w = [_]u16{ 's', 'e', 'c', 'o', 'n', 'd' };
    const n1_bytes = std.mem.sliceAsBytes(&name1_w);
    const n2_bytes = std.mem.sliceAsBytes(&name2_w);

    var raw: [64]u8 = undefined;
    @memset(&raw, 0);

    const rec1_size = 24;
    std.mem.writeInt(u32, raw[0..4], rec1_size, .little);
    std.mem.writeInt(u32, raw[4..8], win32.FILE_ACTION_ADDED, .little);
    std.mem.writeInt(u32, raw[8..12], @intCast(n1_bytes.len), .little);
    @memcpy(raw[12 .. 12 + n1_bytes.len], n1_bytes);

    std.mem.writeInt(u32, raw[rec1_size..][0..4], 0, .little);
    std.mem.writeInt(u32, raw[rec1_size + 4 ..][0..4], win32.FILE_ACTION_MODIFIED, .little);
    std.mem.writeInt(u32, raw[rec1_size + 8 ..][0..4], @intCast(n2_bytes.len), .little);
    @memcpy(raw[rec1_size + 12 .. rec1_size + 12 + n2_bytes.len], n2_bytes);

    const total_len = rec1_size + 12 + n2_bytes.len;

    var cursor = Cursor.init();
    cursor.resetWithBuffer(total_len);

    var small_buf: [8]u8 = undefined; // Fits "first" (5 bytes), but cannot fit both "first" and "second" (11 bytes)
    var out: [2]Event = undefined;

    // Call 1: returns record 1 ("first")
    const n1 = try cursor.read(raw[0..total_len], &small_buf, &out);
    try std.testing.expectEqual(@as(usize, 1), n1);
    try std.testing.expectEqualStrings("first", out[0].name);
    try std.testing.expect(!cursor.isDone());

    // Call 2 with clean buffer: returns record 2 ("second")
    const n2 = try cursor.read(raw[0..total_len], &small_buf, &out);
    try std.testing.expectEqual(@as(usize, 1), n2);
    try std.testing.expectEqualStrings("second", out[0].name);
    try std.testing.expect(cursor.isDone());
}
