//! The camera module's options and results, and the pure parts every
//! backend shares: option checks, the size a photo is scaled to, what a
//! file's bytes are (MIME type, pixel size), the downscaler the desktop
//! uses, and the names the Android capture provider serves.

const std = @import("std");

pub const Source = enum {
    /// Take a new photo with the camera app (phones; error.Unsupported on
    /// the desktop and the iOS simulator).
    camera,
    /// Pick one from the photo library (the system photo picker on phones,
    /// a file dialog filtered to images on the desktop).
    library,
};

pub const Format = enum {
    jpeg,
    png,

    pub fn mime(self: Format) []const u8 {
        return switch (self) {
            .jpeg => "image/jpeg",
            .png => "image/png",
        };
    }
};

pub const Options = struct {
    source: Source = .library,
    /// The longest side of the result, in pixels (1..`max_side_limit`).
    /// Larger photos are scaled down to it; smaller ones keep their size.
    max_side: u32 = 1600,
    format: Format = .jpeg,
    /// JPEG quality (1..100); ignored for PNG.
    quality: u8 = 85,
};

/// A photo, encoded. `bytes` and `mime` are allocated in the arena given to
/// `capturePhoto`. `width` and `height` are 0 when the desktop couldn't
/// decode the file (HEIC, progressive JPEG) and returned it as it was.
pub const Photo = struct {
    bytes: []u8,
    width: u32,
    height: u32,
    mime: []const u8,
};

pub const Error = error{
    /// The user backed out (closed the camera or the picker).
    Cancelled,
    /// No camera here (the desktop, the iOS simulator, a phone without a
    /// camera app), or no photo picker.
    Unsupported,
    /// The camera permission was refused (or, on iOS, the app declares no
    /// `.permissions.camera` text).
    PermissionDenied,
    /// The photo is over `max_bytes` encoded (or over `max_input_bytes`
    /// as picked).
    TooLarge,
    /// `max_side` or `quality` out of range.
    InvalidOptions,
    /// Called on the UI thread (phones): call it from an async command.
    MainThread,
    /// Another capture is in progress (one at a time).
    Busy,
    /// The camera app or the picker failed, or the photo couldn't be read.
    CaptureFailed,
    OutOfMemory,
};

/// The largest `max_side`: 8192 px (a 64 MP photo's long side is ~9000).
pub const max_side_limit: u32 = 8192;
/// The largest encoded photo `capturePhoto` returns.
pub const max_bytes: usize = 32 << 20;
/// The largest file the desktop reads from the picker.
pub const max_input_bytes: usize = 64 << 20;
/// The largest photo the page gets (`oriel.camera.capturePhoto`), before
/// base64: more belongs in a Zig command.
pub const max_page_bytes: usize = 16 << 20;

pub fn validate(options: Options) error{InvalidOptions}!void {
    if (options.max_side == 0 or options.max_side > max_side_limit) return error.InvalidOptions;
    if (options.quality == 0 or options.quality > 100) return error.InvalidOptions;
}

pub const Size = struct { width: u32, height: u32 };

/// `width` x `height` scaled to fit `max_side` on its longest side, keeping
/// the aspect ratio (rounded, at least 1 px). Never scales up.
pub fn fitSize(width: u32, height: u32, max_side: u32) Size {
    const longest = @max(width, height);
    if (longest <= max_side or max_side == 0) return .{ .width = width, .height = height };
    const scale = struct {
        fn f(v: u32, num: u32, den: u32) u32 {
            const r = (@as(u64, v) * num + den / 2) / den;
            return @intCast(@max(r, 1));
        }
    }.f;
    return .{ .width = scale(width, max_side, longest), .height = scale(height, max_side, longest) };
}

/// The largest power of two (at most 64) to subsample a decode by while
/// keeping the long side at least `max_side`: a 4000 px photo decodes at
/// 2000 for 1600, not 1000. (Android's BitmapFactory.inSampleSize; the
/// Kotlin side computes the same.)
pub fn sampleSize(width: u32, height: u32, max_side: u32) u32 {
    var sample: u32 = 1;
    var longest = @max(width, height);
    while (longest / 2 >= max_side and sample < 64) {
        sample *= 2;
        longest /= 2;
    }
    return sample;
}

/// What an image file is, from its first bytes: "image/jpeg", "image/png",
/// "image/gif", "image/webp", "image/bmp", "image/heic", "image/heif",
/// "image/avif"; null for anything else.
pub fn sniffMime(bytes: []const u8) ?[]const u8 {
    if (bytes.len >= 3 and bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF) return "image/jpeg";
    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return "image/png";
    if (std.mem.startsWith(u8, bytes, "GIF87a") or std.mem.startsWith(u8, bytes, "GIF89a")) return "image/gif";
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return "image/webp";
    if (bytes.len >= 26 and std.mem.eql(u8, bytes[0..2], "BM")) return "image/bmp";
    // ISO base media: [size]["ftyp"][major brand].
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[4..8], "ftyp")) {
        const brand = bytes[8..12];
        const heic = [_][]const u8{ "heic", "heix", "hevc", "hevx", "heim", "heis" };
        for (heic) |b| if (std.mem.eql(u8, brand, b)) return "image/heic";
        if (std.mem.eql(u8, brand, "avif") or std.mem.eql(u8, brand, "avis")) return "image/avif";
        if (std.mem.eql(u8, brand, "mif1") or std.mem.eql(u8, brand, "msf1")) return "image/heif";
    }
    return null;
}

/// The MIME type an image file name's extension says (lowercase or not),
/// for files `sniffMime` doesn't know; null for other extensions.
pub fn mimeFromExtension(path: []const u8) ?[]const u8 {
    const ext = std.fs.path.extension(path);
    if (ext.len < 2 or ext.len > 6) return null;
    var buf: [6]u8 = undefined;
    const lower = std.ascii.lowerString(&buf, ext[1..]);
    const table = [_]struct { []const u8, []const u8 }{
        .{ "jpg", "image/jpeg" },  .{ "jpeg", "image/jpeg" }, .{ "png", "image/png" },
        .{ "gif", "image/gif" },   .{ "webp", "image/webp" }, .{ "bmp", "image/bmp" },
        .{ "heic", "image/heic" }, .{ "heif", "image/heif" }, .{ "avif", "image/avif" },
    };
    for (table) |e| if (std.mem.eql(u8, lower, e[0])) return e[1];
    return null;
}

/// The extensions the desktop's photo picker offers.
pub const image_extensions = [_][]const u8{ "jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "heif", "avif" };

/// The pixel size in an image's header (JPEG, PNG, GIF, WebP, BMP), without
/// decoding it; null when unknown or malformed.
pub fn imageSize(bytes: []const u8) ?Size {
    const mime = sniffMime(bytes) orelse return null;
    if (std.mem.eql(u8, mime, "image/png")) {
        if (bytes.len < 24 or !std.mem.eql(u8, bytes[12..16], "IHDR")) return null;
        return nonZero(std.mem.readInt(u32, bytes[16..20], .big), std.mem.readInt(u32, bytes[20..24], .big));
    }
    if (std.mem.eql(u8, mime, "image/gif")) {
        if (bytes.len < 10) return null;
        return nonZero(std.mem.readInt(u16, bytes[6..8], .little), std.mem.readInt(u16, bytes[8..10], .little));
    }
    if (std.mem.eql(u8, mime, "image/bmp")) {
        const w = std.mem.readInt(i32, bytes[18..22], .little);
        const h = std.mem.readInt(i32, bytes[22..26], .little);
        return nonZero(@abs(w), @abs(h)); // a negative height is top-down
    }
    if (std.mem.eql(u8, mime, "image/webp")) return webpSize(bytes);
    if (std.mem.eql(u8, mime, "image/jpeg")) return jpegSize(bytes);
    return null;
}

fn nonZero(width: u32, height: u32) ?Size {
    if (width == 0 or height == 0) return null;
    return .{ .width = width, .height = height };
}

fn webpSize(bytes: []const u8) ?Size {
    if (bytes.len < 30) return null;
    const chunk = bytes[12..16];
    if (std.mem.eql(u8, chunk, "VP8 ")) {
        // Lossy: the frame header's 14-bit sizes after the start code.
        return nonZero(std.mem.readInt(u16, bytes[26..28], .little) & 0x3FFF, std.mem.readInt(u16, bytes[28..30], .little) & 0x3FFF);
    }
    if (std.mem.eql(u8, chunk, "VP8L")) {
        // Lossless: 0x2F, then 14 bits of width - 1 and 14 of height - 1.
        if (bytes[20] != 0x2F) return null;
        const b = bytes[21..25];
        const w = 1 + ((@as(u32, b[1] & 0x3F) << 8) | b[0]);
        const h = 1 + ((@as(u32, b[3] & 0x0F) << 10) | (@as(u32, b[2]) << 2) | (b[1] >> 6));
        return nonZero(w, h);
    }
    if (std.mem.eql(u8, chunk, "VP8X")) {
        // Extended: 24-bit canvas width - 1 and height - 1.
        const w = 1 + std.mem.readInt(u24, bytes[24..27], .little);
        const h = 1 + std.mem.readInt(u24, bytes[27..30], .little);
        return nonZero(w, h);
    }
    return null;
}

/// Walks the JPEG's markers up to the frame header (SOFn). Each step moves
/// forward at least two bytes, so the loop is bounded by the length.
fn jpegSize(bytes: []const u8) ?Size {
    var i: usize = 2;
    while (i + 4 <= bytes.len) {
        if (bytes[i] != 0xFF) return null;
        const marker = bytes[i + 1];
        if (marker == 0xFF) { // fill byte
            i += 1;
            continue;
        }
        // Markers without a length: TEM, RSTn, SOI, EOI.
        if (marker == 0x01 or (marker >= 0xD0 and marker <= 0xD9)) {
            i += 2;
            continue;
        }
        const len = std.mem.readInt(u16, bytes[i + 2 ..][0..2], .big);
        if (len < 2) return null;
        const sof = marker >= 0xC0 and marker <= 0xCF and marker != 0xC4 and marker != 0xC8 and marker != 0xCC;
        if (sof) {
            if (i + 9 > bytes.len) return null;
            const h = std.mem.readInt(u16, bytes[i + 5 ..][0..2], .big);
            const w = std.mem.readInt(u16, bytes[i + 7 ..][0..2], .big);
            return nonZero(w, h);
        }
        if (marker == 0xDA) return null; // scan data before a frame header
        i += 2 + @as(usize, len);
    }
    return null;
}

/// EXIF orientation (TIFF tag 0x0112): how the stored pixels turn to
/// display upright. 1 is as stored; 5 to 8 swap width and height.
pub const Orientation = enum(u4) {
    normal = 1,
    flip_horizontal = 2,
    rotate_180 = 3,
    flip_vertical = 4,
    transpose = 5,
    rotate_90 = 6,
    transverse = 7,
    rotate_270 = 8,

    /// Whether the upright image is `height` x `width`.
    pub fn swapsSides(o: Orientation) bool {
        return @intFromEnum(o) >= 5;
    }
};

/// The longest marker walk and IFD0 read: real files have a handful of
/// segments before the frame and a few dozen IFD0 entries.
const max_jpeg_segments = 64;
const max_ifd_entries = 512;

/// A JPEG's EXIF orientation (the APP1 "Exif" segment's IFD0), `.normal`
/// when there is none or it's malformed. Bounded: at most
/// `max_jpeg_segments` markers before the first scan and
/// `max_ifd_entries` IFD0 entries, every offset checked against the
/// segment.
pub fn jpegOrientation(bytes: []const u8) Orientation {
    if (bytes.len < 4 or bytes[0] != 0xFF or bytes[1] != 0xD8) return .normal;
    var i: usize = 2;
    var segments: usize = 0;
    while (segments < max_jpeg_segments and i + 4 <= bytes.len) : (segments += 1) {
        if (bytes[i] != 0xFF) return .normal;
        const marker = bytes[i + 1];
        if (marker == 0xFF) { // fill byte
            i += 1;
            continue;
        }
        if (marker == 0x01 or (marker >= 0xD0 and marker <= 0xD9)) {
            i += 2;
            continue;
        }
        // The scan's data follows: no EXIF after it.
        if (marker == 0xDA) return .normal;
        const len = std.mem.readInt(u16, bytes[i + 2 ..][0..2], .big);
        if (len < 2 or i + 2 + @as(usize, len) > bytes.len) return .normal;
        const body = bytes[i + 4 .. i + 2 + @as(usize, len)];
        if (marker == 0xE1 and body.len >= 6 and std.mem.eql(u8, body[0..6], "Exif\x00\x00"))
            return exifOrientation(body[6..]) orelse .normal;
        i += 2 + @as(usize, len);
    }
    return .normal;
}

/// The orientation in a TIFF structure (EXIF's payload): IFD0's tag 0x0112,
/// a SHORT; null when absent or malformed.
fn exifOrientation(tiff: []const u8) ?Orientation {
    if (tiff.len < 8) return null;
    const endian: std.builtin.Endian = if (std.mem.eql(u8, tiff[0..2], "II")) .little else if (std.mem.eql(u8, tiff[0..2], "MM")) .big else return null;
    if (std.mem.readInt(u16, tiff[2..4], endian) != 42) return null;
    const ifd = std.mem.readInt(u32, tiff[4..8], endian);
    if (ifd < 8 or @as(u64, ifd) + 2 > tiff.len) return null;
    const count = std.mem.readInt(u16, tiff[ifd..][0..2], endian);
    const n = @min(count, max_ifd_entries);
    var e: usize = 0;
    while (e < n) : (e += 1) {
        const at = @as(usize, ifd) + 2 + e * 12;
        if (at + 12 > tiff.len) return null;
        const entry = tiff[at..][0..12];
        if (std.mem.readInt(u16, entry[0..2], endian) != 0x0112) continue;
        // SHORT (3), one value, stored in the entry's first two value bytes.
        if (std.mem.readInt(u16, entry[2..4], endian) != 3) return null;
        if (std.mem.readInt(u32, entry[4..8], endian) != 1) return null;
        const v = std.mem.readInt(u16, entry[8..10], endian);
        if (v < 1 or v > 8) return null;
        return @enumFromInt(v);
    }
    return null;
}

/// Turn RGBA pixels (`src`, `sw` x `sh`) upright into `dst`: `sw` x `sh`,
/// or `sh` x `sw` when `o.swapsSides()`.
pub fn orient(src: []const u8, sw: u32, sh: u32, dst: []u8, o: Orientation) void {
    const n = @as(usize, sw) * sh * 4;
    std.debug.assert(src.len >= n and dst.len >= n);
    std.debug.assert(sw > 0 and sh > 0);
    const dw: u32 = if (o.swapsSides()) sh else sw;
    const dh: u32 = if (o.swapsSides()) sw else sh;
    var y: u32 = 0;
    while (y < dh) : (y += 1) {
        var x: u32 = 0;
        while (x < dw) : (x += 1) {
            // The stored pixel shown at (x, y).
            const s: [2]u32 = switch (o) {
                .normal => .{ x, y },
                .flip_horizontal => .{ sw - 1 - x, y },
                .rotate_180 => .{ sw - 1 - x, sh - 1 - y },
                .flip_vertical => .{ x, sh - 1 - y },
                .transpose => .{ y, x },
                .rotate_90 => .{ y, sh - 1 - x },
                .transverse => .{ sw - 1 - y, sh - 1 - x },
                .rotate_270 => .{ sw - 1 - y, x },
            };
            const from = (@as(usize, s[1]) * sw + s[0]) * 4;
            const to = (@as(usize, y) * dw + x) * 4;
            @memcpy(dst[to..][0..4], src[from..][0..4]);
        }
    }
}

/// Scale RGBA pixels (`src`, `sw` x `sh`) to `dw` x `dh` by averaging each
/// destination pixel's source area (a box filter: good for scaling down,
/// nearest for scaling up). `dst` gets RGB when `dst_channels` is 3, the
/// alpha composited over white (JPEG has no alpha), or RGBA when 4.
/// Every source pixel is read once per destination row band: O(sw * sh).
pub fn downscale(src: []const u8, sw: u32, sh: u32, dst: []u8, dw: u32, dh: u32, dst_channels: u3) void {
    std.debug.assert(dst_channels == 3 or dst_channels == 4);
    std.debug.assert(src.len >= @as(usize, sw) * sh * 4);
    std.debug.assert(dst.len >= @as(usize, dw) * dh * dst_channels);
    std.debug.assert(sw > 0 and sh > 0 and dw > 0 and dh > 0);
    var dy: u32 = 0;
    while (dy < dh) : (dy += 1) {
        const y0: u32 = @intCast(@as(u64, dy) * sh / dh);
        const y1: u32 = @max(y0 + 1, @as(u32, @intCast(@as(u64, dy + 1) * sh / dh)));
        var dx: u32 = 0;
        while (dx < dw) : (dx += 1) {
            const x0: u32 = @intCast(@as(u64, dx) * sw / dw);
            const x1: u32 = @max(x0 + 1, @as(u32, @intCast(@as(u64, dx + 1) * sw / dw)));
            var sum = [4]u64{ 0, 0, 0, 0 };
            var y = y0;
            while (y < y1) : (y += 1) {
                var x = x0;
                while (x < x1) : (x += 1) {
                    const p = (@as(usize, y) * sw + x) * 4;
                    for (0..4) |c| sum[c] += src[p + c];
                }
            }
            const n: u64 = @as(u64, y1 - y0) * (x1 - x0);
            const out = (@as(usize, dy) * dw + dx) * dst_channels;
            const a = (sum[3] + n / 2) / n;
            for (0..3) |c| {
                const v = (sum[c] + n / 2) / n;
                // Over white: v * a + 255 * (255 - a), over 255.
                dst[out + c] = if (dst_channels == 3) @intCast((v * a + 255 * (255 - a) + 127) / 255) else @intCast(v);
            }
            if (dst_channels == 4) dst[out + 3] = @intCast(a);
        }
    }
}

/// The names the Android capture provider (`<app id>.oriel.capture`)
/// serves: "capture-<digits>.jpg", the files Oriel creates in
/// `<cacheDir>/oriel-captures/` (OrielCaptureProvider.kt checks the same).
/// Nothing with a separator, "..", or another extension.
pub fn validCaptureName(name: []const u8) bool {
    const prefix = "capture-";
    const suffix = ".jpg";
    if (name.len <= prefix.len + suffix.len or name.len > prefix.len + 20 + suffix.len) return false;
    if (!std.mem.startsWith(u8, name, prefix) or !std.mem.endsWith(u8, name, suffix)) return false;
    for (name[prefix.len .. name.len - suffix.len]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// `data:<mime>;base64,<bytes>` for the page (allocated in `arena`).
pub fn dataUrl(arena: std.mem.Allocator, mime: []const u8, bytes: []const u8) ![]u8 {
    const enc = std.base64.standard.Encoder;
    const head = try std.fmt.allocPrint(arena, "data:{s};base64,", .{mime});
    const out = try arena.alloc(u8, head.len + enc.calcSize(bytes.len));
    @memcpy(out[0..head.len], head);
    _ = enc.encode(out[head.len..], bytes);
    return out;
}

test {
    std.testing.refAllDecls(@This());
}

test validate {
    try validate(.{});
    try validate(.{ .max_side = 1, .quality = 1 });
    try validate(.{ .max_side = max_side_limit, .quality = 100, .format = .png });
    try std.testing.expectError(error.InvalidOptions, validate(.{ .max_side = 0 }));
    try std.testing.expectError(error.InvalidOptions, validate(.{ .max_side = max_side_limit + 1 }));
    try std.testing.expectError(error.InvalidOptions, validate(.{ .quality = 0 }));
    try std.testing.expectError(error.InvalidOptions, validate(.{ .quality = 101 }));
}

test fitSize {
    try std.testing.expectEqual(Size{ .width = 1600, .height = 1200 }, fitSize(4000, 3000, 1600));
    try std.testing.expectEqual(Size{ .width = 1200, .height = 1600 }, fitSize(3000, 4000, 1600));
    try std.testing.expectEqual(Size{ .width = 800, .height = 600 }, fitSize(800, 600, 1600)); // never up
    try std.testing.expectEqual(Size{ .width = 1600, .height = 1 }, fitSize(10000, 2, 1600)); // at least 1 px
    try std.testing.expectEqual(Size{ .width = 1600, .height = 900 }, fitSize(1920, 1080, 1600));
    try std.testing.expectEqual(Size{ .width = 100, .height = 100 }, fitSize(100, 100, 100));
}

test sampleSize {
    try std.testing.expectEqual(@as(u32, 2), sampleSize(4000, 3000, 1600));
    try std.testing.expectEqual(@as(u32, 1), sampleSize(3000, 2000, 1600));
    try std.testing.expectEqual(@as(u32, 4), sampleSize(8000, 6000, 1600));
    try std.testing.expectEqual(@as(u32, 1), sampleSize(800, 600, 1600));
    try std.testing.expectEqual(@as(u32, 64), sampleSize(1 << 30, 1, 1));
}

test sniffMime {
    try std.testing.expectEqualStrings("image/jpeg", sniffMime("\xFF\xD8\xFF\xE0").?);
    try std.testing.expectEqualStrings("image/png", sniffMime("\x89PNG\r\n\x1a\n....").?);
    try std.testing.expectEqualStrings("image/gif", sniffMime("GIF89a").?);
    try std.testing.expectEqualStrings("image/webp", sniffMime("RIFF\x00\x00\x00\x00WEBPVP8 ").?);
    try std.testing.expectEqualStrings("image/heic", sniffMime("\x00\x00\x00\x18ftypheic\x00\x00\x00\x00").?);
    try std.testing.expectEqualStrings("image/heif", sniffMime("\x00\x00\x00\x18ftypmif1").?);
    try std.testing.expectEqualStrings("image/avif", sniffMime("\x00\x00\x00\x1cftypavif").?);
    try std.testing.expect(sniffMime("%PDF-1.7") == null);
    try std.testing.expect(sniffMime("") == null);
    try std.testing.expect(sniffMime("\xFF\xD8") == null);
}

test mimeFromExtension {
    try std.testing.expectEqualStrings("image/jpeg", mimeFromExtension("/photos/IMG_1.JPG").?);
    try std.testing.expectEqualStrings("image/heic", mimeFromExtension("a.heic").?);
    try std.testing.expect(mimeFromExtension("notes.txt") == null);
    try std.testing.expect(mimeFromExtension("noext") == null);
    try std.testing.expect(mimeFromExtension("x.verylongext") == null);
}

test imageSize {
    // PNG: signature, IHDR length and type, 640 x 480.
    const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x02\x80\x00\x00\x01\xe0\x08\x06\x00\x00\x00";
    try std.testing.expectEqual(Size{ .width = 640, .height = 480 }, imageSize(png).?);
    // GIF: 3 x 2.
    try std.testing.expectEqual(Size{ .width = 3, .height = 2 }, imageSize("GIF89a\x03\x00\x02\x00").?);
    // JPEG: SOI, an APP0 of 4 bytes, SOF0 of 1200 x 1600 (height first).
    const jpeg = "\xFF\xD8" ++ "\xFF\xE0\x00\x04\x00\x00" ++ "\xFF\xC0\x00\x11\x08\x06\x40\x04\xB0\x03";
    try std.testing.expectEqual(Size{ .width = 1200, .height = 1600 }, imageSize(jpeg).?);
    // A DHT (C4) isn't a frame header; fill bytes are skipped.
    const jpeg2 = "\xFF\xD8" ++ "\xFF\xC4\x00\x02" ++ "\xFF\xFF\xC2\x00\x11\x08\x00\x10\x00\x20\x03";
    try std.testing.expectEqual(Size{ .width = 32, .height = 16 }, imageSize(jpeg2).?);
    // Truncated or malformed: null, never a read past the end.
    try std.testing.expect(imageSize("\xFF\xD8\xFF\xE0\x00\x40") == null);
    try std.testing.expect(imageSize("\xFF\xD8\xFF\xE0\x00\x00\x00\x00") == null);
    try std.testing.expect(imageSize("\xFF\xD8\xFF\xDA\x00\x04\x00\x00") == null);
    // WebP VP8X: 4000 x 3000.
    var webp = [_]u8{0} ** 30;
    @memcpy(webp[0..4], "RIFF");
    @memcpy(webp[8..16], "WEBPVP8X");
    std.mem.writeInt(u24, webp[24..27], 3999, .little);
    std.mem.writeInt(u24, webp[27..30], 2999, .little);
    try std.testing.expectEqual(Size{ .width = 4000, .height = 3000 }, imageSize(&webp).?);
    // WebP VP8L: 100 x 50 (width - 1 = 99, height - 1 = 49).
    var lossless = [_]u8{0} ** 30;
    @memcpy(lossless[0..4], "RIFF");
    @memcpy(lossless[8..16], "WEBPVP8L");
    lossless[20] = 0x2F;
    const bits: u32 = 99 | (49 << 14);
    std.mem.writeInt(u32, lossless[21..25], bits, .little);
    try std.testing.expectEqual(Size{ .width = 100, .height = 50 }, imageSize(&lossless).?);
    // HEIC: known type, unknown size here.
    try std.testing.expect(imageSize("\x00\x00\x00\x18ftypheic\x00\x00\x00\x00") == null);
}

/// A JPEG head with an EXIF APP1 whose IFD0 holds one entry (`tag`, SHORT
/// `value`) after a dummy one, in `endian` byte order.
fn testExifJpeg(comptime endian: std.builtin.Endian, tag: u16, value: u16) [2 + 4 + 6 + 8 + 2 + 24 + 4]u8 {
    var out: [2 + 4 + 6 + 8 + 2 + 24 + 4]u8 = undefined;
    @memcpy(out[0..4], "\xFF\xD8\xFF\xE1");
    std.mem.writeInt(u16, out[4..6], out.len - 4, .big); // APP1 length (with itself)
    @memcpy(out[6..12], "Exif\x00\x00");
    const t = out[12..];
    @memcpy(t[0..2], if (endian == .little) "II" else "MM");
    std.mem.writeInt(u16, t[2..4], 42, endian);
    std.mem.writeInt(u32, t[4..8], 8, endian);
    std.mem.writeInt(u16, t[8..10], 2, endian);
    // ImageWidth (0x0100), LONG, 1: skipped.
    std.mem.writeInt(u16, t[10..12], 0x0100, endian);
    std.mem.writeInt(u16, t[12..14], 4, endian);
    std.mem.writeInt(u32, t[14..18], 1, endian);
    std.mem.writeInt(u32, t[18..22], 640, endian);
    std.mem.writeInt(u16, t[22..24], tag, endian);
    std.mem.writeInt(u16, t[24..26], 3, endian);
    std.mem.writeInt(u32, t[26..30], 1, endian);
    std.mem.writeInt(u16, t[30..32], value, endian);
    @memset(t[32..34], 0);
    @memset(t[34..38], 0); // next IFD
    return out;
}

test jpegOrientation {
    try std.testing.expectEqual(Orientation.rotate_90, jpegOrientation(&testExifJpeg(.little, 0x0112, 6)));
    try std.testing.expectEqual(Orientation.rotate_270, jpegOrientation(&testExifJpeg(.big, 0x0112, 8)));
    try std.testing.expectEqual(Orientation.flip_horizontal, jpegOrientation(&testExifJpeg(.big, 0x0112, 2)));
    // No orientation tag, an out-of-range value: as stored.
    try std.testing.expectEqual(Orientation.normal, jpegOrientation(&testExifJpeg(.little, 0x0110, 6)));
    try std.testing.expectEqual(Orientation.normal, jpegOrientation(&testExifJpeg(.little, 0x0112, 9)));
    try std.testing.expectEqual(Orientation.normal, jpegOrientation(&testExifJpeg(.little, 0x0112, 0)));
    // After an APP0; not a JPEG; no EXIF before the scan.
    const app0 = "\xFF\xD8\xFF\xE0\x00\x04\x00\x00";
    try std.testing.expectEqual(Orientation.rotate_180, jpegOrientation(app0 ++ comptime testExifJpeg(.little, 0x0112, 3)[2..]));
    try std.testing.expectEqual(Orientation.normal, jpegOrientation("\x89PNG\r\n\x1a\n"));
    try std.testing.expectEqual(Orientation.normal, jpegOrientation("\xFF\xD8\xFF\xDA\x00\x04\x00\x00"));
    // Truncated anywhere: as stored, never a read past the end.
    const full = testExifJpeg(.little, 0x0112, 6);
    for (0..full.len) |n| {
        const o = jpegOrientation(full[0..n]);
        try std.testing.expectEqual(Orientation.normal, o);
    }
    // An IFD offset past the segment, a count past it.
    var bad = full;
    std.mem.writeInt(u32, bad[16..20], 0xFFFF_FFF0, .little);
    try std.testing.expectEqual(Orientation.normal, jpegOrientation(&bad));
    bad = full;
    std.mem.writeInt(u16, bad[20..22], 0xFFFF, .little);
    try std.testing.expectEqual(Orientation.rotate_90, jpegOrientation(&bad)); // found before the end
    bad = full;
    std.mem.writeInt(u16, bad[20..22], 0xFFFF, .little);
    std.mem.writeInt(u16, bad[34..36], 0x0110, .little); // no orientation: runs off the segment
    try std.testing.expectEqual(Orientation.normal, jpegOrientation(&bad));
}

test orient {
    // 3 x 2, each pixel's red is its index:
    //   0 1 2
    //   3 4 5
    var src: [6 * 4]u8 = undefined;
    for (0..6) |i| src[i * 4 ..][0..4].* = .{ @intCast(i), 0, 0, 255 };
    const cases = [_]struct { o: Orientation, want: [6]u8 }{
        .{ .o = .normal, .want = .{ 0, 1, 2, 3, 4, 5 } },
        .{ .o = .flip_horizontal, .want = .{ 2, 1, 0, 5, 4, 3 } },
        .{ .o = .rotate_180, .want = .{ 5, 4, 3, 2, 1, 0 } },
        .{ .o = .flip_vertical, .want = .{ 3, 4, 5, 0, 1, 2 } },
        // 2 x 3 from here on.
        .{ .o = .transpose, .want = .{ 0, 3, 1, 4, 2, 5 } },
        .{ .o = .rotate_90, .want = .{ 3, 0, 4, 1, 5, 2 } },
        .{ .o = .transverse, .want = .{ 5, 2, 4, 1, 3, 0 } },
        .{ .o = .rotate_270, .want = .{ 2, 5, 1, 4, 0, 3 } },
    };
    for (cases) |c| {
        var dst: [6 * 4]u8 = undefined;
        orient(&src, 3, 2, &dst, c.o);
        var got: [6]u8 = undefined;
        for (0..6) |i| got[i] = dst[i * 4];
        std.testing.expectEqualSlices(u8, &c.want, &got) catch |err| {
            std.debug.print("orientation {s}\n", .{@tagName(c.o)});
            return err;
        };
    }
}

test downscale {
    // 2x2 -> 1x1: the average; opaque.
    const src = [_]u8{ 0, 0, 0, 255, 255, 255, 255, 255, 0, 0, 0, 255, 255, 255, 255, 255 };
    var rgb: [3]u8 = undefined;
    downscale(&src, 2, 2, &rgb, 1, 1, 3);
    try std.testing.expectEqualSlices(u8, &.{ 128, 128, 128 }, &rgb);
    // Transparent over white.
    const clear = [_]u8{ 0, 0, 0, 0 };
    downscale(&clear, 1, 1, &rgb, 1, 1, 3);
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255 }, &rgb);
    // RGBA kept, 4x2 -> 2x1.
    const row = [_]u8{ 10, 20, 30, 255, 30, 40, 50, 255, 100, 100, 100, 0, 100, 100, 100, 0 } ** 2;
    var rgba: [8]u8 = undefined;
    downscale(&row, 4, 2, &rgba, 2, 1, 4);
    try std.testing.expectEqualSlices(u8, &.{ 20, 30, 40, 255, 100, 100, 100, 0 }, &rgba);
}

test validCaptureName {
    try std.testing.expect(validCaptureName("capture-1234567890.jpg"));
    try std.testing.expect(validCaptureName("capture-18446744073709551615.jpg"));
    try std.testing.expect(!validCaptureName("capture-.jpg"));
    try std.testing.expect(!validCaptureName("capture-12a.jpg"));
    try std.testing.expect(!validCaptureName("capture-12.png"));
    try std.testing.expect(!validCaptureName("../capture-12.jpg"));
    try std.testing.expect(!validCaptureName("capture-12.jpg/../../x"));
    try std.testing.expect(!validCaptureName("shelf-12.jpg"));
    try std.testing.expect(!validCaptureName("capture-123456789012345678901.jpg"));
}

test dataUrl {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("data:image/png;base64,AQID", try dataUrl(arena.allocator(), "image/png", &.{ 1, 2, 3 }));
}
