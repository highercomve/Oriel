//! Chat formats `chat` renders itself: the families whose GGUF template is a
//! Jinja program llama.cpp's built-in templates don't cover, or whose
//! reasoning has to be switched off in the prompt (Gemma 4, Qwen3/3.5).
//! Everything else goes through `llama_chat_apply_template`. Ported from
//! GhostPen's `chat_format.zig`, for whole conversations.

const std = @import("std");

pub const Format = enum {
    /// Gemma 4: `<|turn>role … <turn|>`, thinking in `<|channel>thought … <channel|>`.
    gemma4,
    /// ChatML with a `<think>` block (Qwen3, Qwen3.5).
    chatml_think,
    /// Whatever llama.cpp's `llama_chat_apply_template` recognizes.
    builtin,
};

/// The family, from the GGUF's `tokenizer.chat_template`.
pub fn detect(template: ?[]const u8) Format {
    const t = template orelse return .builtin;
    if (std.mem.indexOf(u8, t, "<|turn>") != null) return .gemma4;
    if (std.mem.indexOf(u8, t, "<|im_start|>") != null and std.mem.indexOf(u8, t, "<think>") != null) return .chatml_think;
    return .builtin;
}

pub const Turn = struct { role: []const u8, content: []const u8 };

/// The prompt text (special tokens as text: tokenize with `parse_special`),
/// ending where the assistant's reply starts; null for `.builtin`. BOS is
/// not included (the tokenizer adds it).
///
/// Without thinking, Qwen's earlier replies keep the empty reasoning block
/// the prompt gave them, so the conversation is exactly what the KV cache
/// holds: Qwen3.5 (recurrent layers), like Gemma 4 (sliding-window
/// attention), can only extend its cache, not cut it back to a common
/// prefix.
pub fn render(a: std.mem.Allocator, format: Format, turns: []const Turn, think: bool) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    switch (format) {
        .builtin => return null,
        .gemma4 => {
            var i: usize = 0;
            const has_system = turns.len > 0 and std.mem.eql(u8, turns[0].role, "system");
            if (has_system or think) {
                try out.print(a, "<|turn>system\n{s}{s}<turn|>\n", .{
                    if (think) "<|think|>\n" else "",
                    if (has_system) std.mem.trim(u8, turns[0].content, " \t\r\n") else "",
                });
                if (has_system) i = 1;
            }
            // Thinking off is the model's default: no block in the prompt
            // (an empty one makes it think out loud).
            for (turns[i..]) |t| {
                const role = if (std.mem.eql(u8, t.role, "assistant")) "model" else t.role;
                try out.print(a, "<|turn>{s}\n{s}<turn|>\n", .{ role, std.mem.trim(u8, t.content, " \t\r\n") });
            }
            try out.appendSlice(a, "<|turn>model\n");
        },
        .chatml_think => {
            const empty = "<think>\n\n</think>\n\n";
            for (turns) |t| {
                const reply = std.mem.eql(u8, t.role, "assistant") and !think;
                try out.print(a, "<|im_start|>{s}\n{s}{s}<|im_end|>\n", .{ t.role, if (reply) empty else "", std.mem.trim(u8, t.content, " \t\r\n") });
            }
            try out.print(a, "<|im_start|>assistant\n{s}", .{if (think) "<think>\n" else empty});
        },
    }
    return out.items;
}

/// Where the model's reasoning starts and ends in its output.
const Reasoning = struct {
    open: []const u8,
    close: []const u8,
    /// The prompt already opened the block: the output starts inside it.
    opened_by_prompt: bool,
};

fn reasoning(format: Format) ?Reasoning {
    return switch (format) {
        .gemma4 => .{ .open = "<|channel>thought", .close = "<channel|>", .opened_by_prompt = false },
        .chatml_think => .{ .open = "<think>", .close = "</think>", .opened_by_prompt = true },
        .builtin => null,
    };
}

/// Hides the reasoning block from the reply as it streams: `visible(out)`
/// with the whole output so far is what the user sees, or null while it may
/// still be reasoning.
pub const ReasoningFilter = struct {
    r: ?Reasoning,
    /// Inside the block (its end not seen yet).
    inside: bool,
    /// Decided whether the output opens a block (formats where the model does).
    decided: bool,
    /// The visible text starts here in the output.
    start: usize = 0,

    pub fn init(format: Format, think: bool) ReasoningFilter {
        // Gemma 4 may think unasked: hide that too.
        const r = if (think or format == .gemma4) reasoning(format) else null;
        const by_prompt = if (r) |x| x.opened_by_prompt else false;
        return .{ .r = r, .inside = by_prompt, .decided = r == null or by_prompt };
    }

    pub fn visible(self: *ReasoningFilter, out: []const u8) ?[]const u8 {
        const r = self.r orelse return out;
        if (!self.decided) {
            const head = std.mem.trimStart(u8, out, " \t\r\n");
            if (head.len < r.open.len and std.mem.startsWith(u8, r.open, head)) return null;
            self.decided = true;
            self.inside = std.mem.startsWith(u8, head, r.open);
        }
        if (self.inside) {
            const close = std.mem.indexOf(u8, out, r.close) orelse return null;
            self.inside = false;
            var s = close + r.close.len;
            while (s < out.len and std.ascii.isWhitespace(out[s])) s += 1;
            self.start = s;
        }
        return out[@min(self.start, out.len)..];
    }
};

/// How many leading bytes of `s` don't end inside a UTF-8 sequence (so a
/// streamed piece never splits a character).
pub fn completeUtf8(s: []const u8) usize {
    var i = s.len;
    var back: usize = 0;
    while (i > 0 and back < 4) {
        i -= 1;
        back += 1;
        const b = s[i];
        if (b & 0x80 == 0) return s.len; // ASCII: complete
        if (b & 0xC0 == 0xC0) { // lead byte: complete if its sequence fits
            const need: usize = if (b & 0xE0 == 0xC0) 2 else if (b & 0xF0 == 0xE0) 3 else 4;
            return if (back >= need) s.len else i;
        }
    }
    return s.len;
}

/// `s` as valid UTF-8: each invalid sequence becomes U+FFFD (byte-level
/// tokens can garble a character). `s` itself when it is already valid.
pub fn validUtf8(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(s)) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 0;
        if (n > 0 and i + n <= s.len and std.unicode.utf8ValidateSlice(s[i..][0..n])) {
            try out.appendSlice(a, s[i..][0..n]);
            i += n;
        } else {
            try out.appendSlice(a, "\u{FFFD}");
            i += 1;
        }
    }
    return out.items;
}

test detect {
    try std.testing.expectEqual(Format.gemma4, detect("{{- '<|turn>model\\n' -}}"));
    try std.testing.expectEqual(Format.chatml_think, detect("<|im_start|>assistant\n<think>"));
    try std.testing.expectEqual(Format.builtin, detect("<|im_start|>assistant"));
    try std.testing.expectEqual(Format.builtin, detect(null));
}

test render {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const turns = [_]Turn{
        .{ .role = "system", .content = "S" },
        .{ .role = "user", .content = " U\n" },
        .{ .role = "assistant", .content = "A" },
        .{ .role = "user", .content = "V" },
    };
    try std.testing.expectEqualStrings(
        "<|turn>system\nS<turn|>\n<|turn>user\nU<turn|>\n<|turn>model\nA<turn|>\n<|turn>user\nV<turn|>\n<|turn>model\n",
        (try render(a, .gemma4, &turns, false)).?,
    );
    try std.testing.expectEqualStrings(
        "<|im_start|>user\nU<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n",
        (try render(a, .chatml_think, turns[1..2], false)).?,
    );
    try std.testing.expectEqualStrings(
        "<|im_start|>assistant\n<think>\n\n</think>\n\nA<|im_end|>\n<|im_start|>user\nV<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n",
        (try render(a, .chatml_think, turns[2..], false)).?,
    );
    try std.testing.expectEqualStrings("<|turn>system\n<|think|>\n<turn|>\n<|turn>user\nV<turn|>\n<|turn>model\n", (try render(a, .gemma4, turns[3..], true)).?);
    try std.testing.expect((try render(a, .builtin, &turns, true)) == null);
}

test ReasoningFilter {
    var f: ReasoningFilter = .init(.chatml_think, true);
    try std.testing.expect(f.visible("Let me think") == null);
    try std.testing.expectEqualStrings("Hi", f.visible("Let me think</think>\n\nHi").?);
    var g: ReasoningFilter = .init(.gemma4, true);
    try std.testing.expect(g.visible("<|chan") == null);
    try std.testing.expect(g.visible("<|channel>thought\nhmm") == null);
    try std.testing.expectEqualStrings("Ok", g.visible("<|channel>thought\nhmm<channel|>Ok").?);
    var h: ReasoningFilter = .init(.gemma4, true);
    try std.testing.expectEqualStrings("Plain", h.visible("Plain").?);
    var unasked: ReasoningFilter = .init(.gemma4, false);
    try std.testing.expectEqualStrings("Ok", unasked.visible("<|channel>thought\nhmm<channel|>Ok").?);
    var off: ReasoningFilter = .init(.chatml_think, false);
    try std.testing.expectEqualStrings("x", off.visible("x").?);
}

test completeUtf8 {
    try std.testing.expectEqual(@as(usize, 3), completeUtf8("abc"));
    try std.testing.expectEqual(@as(usize, 1), completeUtf8("a\xc3"));
    try std.testing.expectEqual(@as(usize, 3), completeUtf8("a\xc3\xa9"));
    try std.testing.expectEqual(@as(usize, 1), completeUtf8("a\xe2\x82"));
    try std.testing.expectEqual(@as(usize, 5), completeUtf8("a\xf0\x9f\x98\x80"));
}

test validUtf8 {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("héllo", try validUtf8(a, "héllo"));
    try std.testing.expectEqualStrings("a\u{FFFD}b", try validUtf8(a, "a\xe2b"));
}
