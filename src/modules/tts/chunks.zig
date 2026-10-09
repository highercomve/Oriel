//! Text to synthesis chunks for `tts`'s streaming: a short first chunk so
//! sound starts quickly, then chunks bounded in length (Kokoro's time grows
//! with the text, and the device plays one while the next is made). Breaks
//! at the end of a sentence where there is one, else after a clause, else
//! between words; a hard cut only inside a run without spaces (CJK), and
//! never inside a UTF-8 sequence.

const std = @import("std");

/// The first chunk's limit in bytes (~5 s of speech).
pub const first_max = 80;
/// Every later chunk's limit in bytes (~15 s of speech; Kokoro reads at
/// most 510 phonemes at once).
pub const max = 220;
/// The smallest limit worth a synthesis call.
pub const min = 40;

/// The chunk of `text` from `pos.*` of at most `limit` bytes (`min` to
/// `max`), without surrounding whitespace, advancing `pos`; null at the
/// end. A streaming reader picks each limit as it goes (`tts` sizes them to
/// the audio queued ahead).
pub fn next(text: []const u8, pos: *usize, limit: usize) ?[]const u8 {
    var start = pos.*;
    while (true) {
        while (start < text.len and isSpace(text[start])) start += 1;
        if (start >= text.len) {
            pos.* = text.len;
            return null;
        }
        const end = breakPoint(text, start, std.math.clamp(limit, min, max));
        std.debug.assert(end > start);
        var trimmed = end;
        while (trimmed > start and isSpace(text[trimmed - 1])) trimmed -= 1;
        pos.* = end;
        if (trimmed > start) return text[start..trimmed];
        start = end;
    }
}

/// All the chunks of `text` at the fixed limits (`first_max`, then `max`),
/// in order; the list is allocated with `a`.
pub fn split(a: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(a);
    var pos: usize = 0;
    while (next(text, &pos, if (list.items.len == 0) first_max else max)) |chunk| try list.append(a, chunk);
    return list.toOwnedSlice(a);
}

/// Where the chunk starting at `start` ends (exclusive).
fn breakPoint(text: []const u8, start: usize, limit: usize) usize {
    if (text.len - start <= limit) return text.len;
    var end = start + limit;
    while (end > start + 1 and text[end] & 0xc0 == 0x80) end -= 1; // UTF-8 continuation
    var sentence: usize = 0;
    var clause: usize = 0;
    var word: usize = 0;
    var i = start;
    while (i < end) : (i += 1) {
        const ch = text[i];
        switch (ch) {
            '\n' => sentence = i,
            '.', '!', '?', ',', ';', ':' => {
                // "3.14", "e.g.x" and "a,b" are no breaks; closing quotes
                // and brackets go with the sentence.
                const after = skipClosers(text, i + 1);
                if (after <= end and (after == text.len or isSpace(text[after]))) {
                    if (ch == ',' or ch == ';' or ch == ':') clause = after else sentence = after;
                }
            },
            ' ', '\t', '\r' => word = i,
            0xe3, 0xef => if (i + 3 <= end) {
                // CJK full stop 。 and fullwidth ！ ？ end sentences; 、 ， clauses.
                const seq = text[i..][0..3];
                if (std.mem.eql(u8, seq, "。") or std.mem.eql(u8, seq, "！") or std.mem.eql(u8, seq, "？")) {
                    const after = skipClosers(text, i + 3);
                    if (after <= end) sentence = after;
                } else if (std.mem.eql(u8, seq, "、") or std.mem.eql(u8, seq, "，")) {
                    clause = i + 3;
                }
            },
            else => {},
        }
    }
    if (sentence > start and sentence <= end) return sentence;
    // A clause break late enough to be worth it, else the last word.
    if (clause > start + limit / 2 and clause <= end) return clause;
    if (word > start) return word;
    if (clause > start and clause <= end) return clause;
    return end;
}

/// Past closing quotes and brackets after a punctuation mark.
fn skipClosers(text: []const u8, from: usize) usize {
    var i = from;
    while (i < text.len) {
        if (std.mem.indexOfScalar(u8, "\"')]", text[i]) != null) {
            i += 1;
        } else if (std.mem.startsWith(u8, text[i..], "”") or std.mem.startsWith(u8, text[i..], "’") or
            std.mem.startsWith(u8, text[i..], "」") or std.mem.startsWith(u8, text[i..], "』"))
        {
            i += 3;
        } else if (std.mem.startsWith(u8, text[i..], "»")) {
            i += 2;
        } else break;
    }
    return i;
}

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
}

/// The chunks are `text` in order, minus only whitespace between them.
fn expectCovers(text: []const u8, chunks: []const []const u8) !void {
    var offset: usize = 0;
    for (chunks) |chunk| {
        while (offset < text.len and isSpace(text[offset])) offset += 1;
        try std.testing.expectEqualStrings(text[offset .. offset + chunk.len], chunk);
        offset += chunk.len;
    }
    while (offset < text.len and isSpace(text[offset])) offset += 1;
    try std.testing.expectEqual(text.len, offset);
}

test "chunks: the first is short, the rest bounded, even without punctuation" {
    const a = std.testing.allocator;
    const text = "a" ** 600;
    const chunks = try split(a, text);
    defer a.free(chunks);
    try std.testing.expectEqual(@as(usize, first_max), chunks[0].len);
    for (chunks[1..]) |chunk| try std.testing.expect(chunk.len <= max);
    try expectCovers(text, chunks);
}

test "chunks: never split a UTF-8 sequence" {
    const a = std.testing.allocator;
    const text = "日本語" ** 70 ++ "ñandú" ** 60;
    const chunks = try split(a, text);
    defer a.free(chunks);
    for (chunks, 0..) |chunk, i| {
        try std.testing.expect(std.unicode.utf8ValidateSlice(chunk));
        try std.testing.expect(chunk.len <= @as(usize, if (i == 0) first_max else max));
    }
    try expectCovers(text, chunks);
}

test "chunks: sentence boundaries first, then words; no text lost" {
    const a = std.testing.allocator;
    const text = "First short sentence. " ++ "The next sentence has many words and should be split at a word boundary without losing any of the selected text. " ** 5;
    const chunks = try split(a, text);
    defer a.free(chunks);
    try std.testing.expectEqualStrings("First short sentence.", chunks[0]);
    for (chunks[1..]) |chunk| {
        try std.testing.expect(chunk.len <= max);
        // Every chunk ends at a sentence or a word: never mid-word.
        const last = chunk[chunk.len - 1];
        try std.testing.expect(last == '.' or std.ascii.isAlphabetic(last));
    }
    try expectCovers(text, chunks);
    // The 110-byte sentences pack two per chunk.
    try std.testing.expect(std.mem.endsWith(u8, chunks[1], "text."));
}

test "chunks: decimals and abbreviations inside words are no sentence ends; quotes close sentences" {
    const a = std.testing.allocator;
    const text = "Pi is 3.14159 and e is 2.71828, roughly. \"Is that so?\" she asked, and wrote it down on the back of the envelope again.";
    const chunks = try split(a, text);
    defer a.free(chunks);
    try std.testing.expectEqualStrings("Pi is 3.14159 and e is 2.71828, roughly. \"Is that so?\"", chunks[0]);
    try expectCovers(text, chunks);
}

test "chunks: CJK sentences break at 。" {
    const a = std.testing.allocator;
    const text = "今日はとても良い天気です。" ** 8;
    const chunks = try split(a, text);
    defer a.free(chunks);
    for (chunks) |chunk| try std.testing.expect(std.mem.endsWith(u8, chunk, "。"));
    try expectCovers(text, chunks);
}

test "chunks: next takes a limit per chunk, clamped to min..max" {
    const text = "word " ** 100;
    var pos: usize = 0;
    try std.testing.expect(next(text, &pos, 1).?.len <= min);
    const big = next(text, &pos, 10_000).?;
    try std.testing.expect(big.len <= max and big.len > max - 6);
    var rest: usize = 0;
    while (next(text, &pos, 100)) |c| rest += c.len + 1;
    try std.testing.expect(next(text, &pos, 100) == null);
    try std.testing.expectEqual(text.len, pos);
}

test "chunks: blank and empty text give none" {
    const chunks = try split(std.testing.allocator, " \n\t ");
    defer std.testing.allocator.free(chunks);
    try std.testing.expectEqual(@as(usize, 0), chunks.len);
}
