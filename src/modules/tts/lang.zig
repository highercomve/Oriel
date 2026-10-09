//! A cheap guess at a text's language for `tts` (`lang = "auto"`), as the
//! espeak-ng language the voices read: scripts first (CJK, kana, Cyrillic,
//! Devanagari), then letters only one language uses (ñ ¿ ¡, ã õ), then
//! common function words for English, Spanish, French, Italian and
//! Portuguese. Nothing clever: it covers the catalog's languages, and
//! falls back to US English.

const std = @import("std");

const Lang = enum { en, es, fr, it, pt };
const espeak = std.enums.EnumArray(Lang, []const u8).init(.{ .en = "en-us", .es = "es", .fr = "fr", .it = "it", .pt = "pt-br" });

const words = std.enums.EnumArray(Lang, []const []const u8).init(.{
    .en = &.{ "the", "a", "an", "of", "and", "or", "to", "in", "is", "are", "it", "that", "with", "for", "on", "as", "this", "be", "was" },
    .es = &.{ "el", "la", "los", "las", "un", "una", "de", "del", "que", "con", "para", "por", "es", "son", "esta", "están", "más", "sí", "en", "su", "año", "sobre", "pero", "como", "muy" },
    .fr = &.{ "le", "les", "des", "du", "et", "est", "une", "dans", "pour", "pas", "qui", "sur", "avec", "ce", "cette", "sont", "je", "vous", "nous", "il", "elle", "au", "aux", "mais", "très", "où" },
    .it = &.{ "il", "lo", "gli", "della", "delle", "di", "che", "è", "sono", "non", "per", "nel", "nella", "alla", "anche", "questo", "questa", "ma", "io", "ed", "molto", "perché" },
    .pt = &.{ "o", "os", "do", "da", "dos", "das", "não", "em", "um", "uma", "para", "com", "que", "é", "são", "mais", "ao", "você", "muito", "isso", "mas", "também", "está" },
});

/// The espeak-ng language of `text`: "en-us", "es", "fr", "it", "pt-br",
/// "ja", "zh", "hi" or "ru" (a static string).
pub fn guess(text: []const u8) []const u8 {
    var cjk: usize = 0;
    var kana: usize = 0;
    var latin: usize = 0;
    var accented: usize = 0;
    var strong_es: usize = 0;
    var strong_pt: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            continue;
        };
        if (i + len > text.len) break;
        const cp = std.unicode.utf8Decode(text[i .. i + len]) catch {
            i += len;
            continue;
        };
        i += len;
        switch (cp) {
            0x0400...0x04FF => return "ru",
            0x0900...0x097F => return "hi",
            0x4E00...0x9FFF, 0x3400...0x4DBF => cjk += 1,
            0x3040...0x30FF => kana += 1,
            // ñ ¿ ¡: Spanish; ã õ: Portuguese (no other catalog language has them).
            0x00F1, 0x00D1, 0x00BF, 0x00A1 => {
                latin += 1;
                accented += 1;
                strong_es += 1;
            },
            0x00E3, 0x00F5, 0x00C3, 0x00D5 => {
                latin += 1;
                accented += 1;
                strong_pt += 1;
            },
            0x00C0...0x00C2, 0x00C4...0x00D0, 0x00D2...0x00D4, 0x00D6...0x00E2, 0x00E4...0x00F0, 0x00F2...0x00F4, 0x00F6...0x00FF, 0x0100...0x024F => {
                latin += 1;
                accented += 1;
            },
            'A'...'Z', 'a'...'z' => latin += 1,
            else => {},
        }
    }
    if (strong_es > 0 and strong_es >= strong_pt) return "es";
    if (strong_pt > 0) return "pt-br";
    if (kana > cjk / 4) return "ja";
    if (cjk > 0 and kana == 0) return "zh";
    if (latin == 0) return "en-us";

    var hits = std.enums.EnumArray(Lang, usize).initFill(0);
    var it = std.mem.tokenizeAny(u8, text, " ,;:.!?()[]{}\"/\t\r\n");
    while (it.next()) |w| {
        for (std.enums.values(Lang)) |l| {
            for (words.get(l)) |fw| if (std.ascii.eqlIgnoreCase(w, fw)) {
                hits.getPtr(l).* += 1;
                break;
            };
        }
    }
    var best: Lang = .en;
    var second: usize = 0;
    for (std.enums.values(Lang)) |l| {
        if (hits.get(l) > hits.get(best)) {
            second = hits.get(best);
            best = l;
        } else if (l != best and hits.get(l) > second) second = hits.get(l);
    }
    // A clear winner: at least two of its words, half again the runner-up's.
    if (hits.get(best) > 1 and hits.get(best) * 2 >= second * 3) return espeak.get(best);
    // Accent density says Spanish over plain English; otherwise the default
    // voice stays (the English voices read most Latin text passably).
    if (accented * 100 / (1 + latin) > 12) return "es";
    return "en-us";
}

test "guess: the obvious cases" {
    try std.testing.expectEqualStrings("es", guess("El coche rojo avanza por la ciudad, y las campanas suenan a lejos."));
    try std.testing.expectEqualStrings("en-us", guess("The committee reviews the design every quarter."));
    try std.testing.expectEqualStrings("es", guess("¿Cómo está la señal?"));
    try std.testing.expectEqualStrings("zh", guess("今天天气很好。"));
    try std.testing.expectEqualStrings("ja", guess("今日はとても良い天気です"));
}

test "guess: French, Italian, Portuguese, Hindi, Russian" {
    try std.testing.expectEqualStrings("fr", guess("Le chat est sur la table et il dort dans le salon."));
    try std.testing.expectEqualStrings("it", guess("Il gatto è sulla tavola e dorme nel salotto, perché non ha voglia di giocare."));
    try std.testing.expectEqualStrings("pt-br", guess("O gato está em cima da mesa e não quer brincar com os meninos."));
    try std.testing.expectEqualStrings("pt-br", guess("A informação chegou."));
    try std.testing.expectEqualStrings("hi", guess("नमस्ते दुनिया"));
    try std.testing.expectEqualStrings("ru", guess("Привет, мир"));
}

test "guess: short, empty and symbol-only text stays English" {
    try std.testing.expectEqualStrings("en-us", guess(""));
    try std.testing.expectEqualStrings("en-us", guess("12:30 — 42%"));
    try std.testing.expectEqualStrings("en-us", guess("OK"));
}
