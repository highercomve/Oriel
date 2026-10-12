//! Linux, Windows and macOS: `.library` picks an image with the dialog
//! module's file dialog (filtered to images; it is used whether or not the
//! app turned `dialog` on), then decodes, scales and encodes it with zigimg.
//! `.camera` is error.Unsupported: pages use getUserMedia for live video.
//!
//! zigimg decodes baseline JPEG, PNG, GIF, BMP and more, but not HEIC,
//! AVIF, WebP or progressive JPEG: those come back as they were picked
//! (`mime` from their bytes, the size from their header, else 0 x 0), as
//! long as they fit `max_bytes`. A JPEG's EXIF orientation is applied
//! before scaling (common.jpegOrientation); one passed through keeps its
//! EXIF, and its size is reported upright.

const std = @import("std");
const zigimg = @import("zigimg");
const oriel = @import("../../oriel.zig");
const dialog = @import("../dialog.zig");
const common = @import("common.zig");

const log = std.log.scoped(.camera);

/// One picker at a time, like the phones.
var busy: std.atomic.Value(bool) = .init(false);

pub fn capturePhoto(io: std.Io, arena: std.mem.Allocator, options: common.Options) common.Error!common.Photo {
    if (options.source == .camera) return error.Unsupported;
    if (busy.swap(true, .acq_rel)) return error.Busy;
    defer busy.store(false, .release);

    const path = dialog.openFile(arena, .{
        .title = "Choose a Photo",
        .filter = .{ .name = "Images", .extensions = &common.image_extensions },
    }) catch |err| {
        log.warn("photo picker: {s}", .{@errorName(err)});
        return if (err == error.OutOfMemory) error.OutOfMemory else error.CaptureFailed;
    } orelse return error.Cancelled;

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(common.max_input_bytes)) catch |err| return switch (err) {
        error.StreamTooLong => error.TooLarge,
        error.OutOfMemory => error.OutOfMemory,
        else => error.CaptureFailed,
    };
    return encode(arena, bytes, path, options);
}

/// The picked file's bytes as the photo `options` asks for: decoded, scaled
/// to `max_side` and encoded, or, when zigimg can't decode it, as it is.
pub fn encode(arena: std.mem.Allocator, bytes: []const u8, path: []const u8, options: common.Options) common.Error!common.Photo {
    // zigimg's working memory (pixels, intermediate buffers) is freed here;
    // only the result stays in the arena.
    const gpa = std.heap.smp_allocator;
    var image = zigimg.Image.fromMemory(gpa, bytes) catch return passThrough(arena, bytes, path);
    defer image.deinit(gpa);
    if (image.width == 0 or image.height == 0 or image.width > 1 << 16 or image.height > 1 << 16) return passThrough(arena, bytes, path);
    image.convert(gpa, .rgba32) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else passThrough(arena, bytes, path);

    var sw: u32 = @intCast(image.width);
    var sh: u32 = @intCast(image.height);
    var src = image.pixels.asConstBytes();
    // Upright first: zigimg ignores EXIF, the camera's sideways JPEGs need it.
    const orientation = if (std.mem.eql(u8, common.sniffMime(bytes) orelse "", "image/jpeg")) common.jpegOrientation(bytes) else .normal;
    var upright: []u8 = &.{};
    defer if (upright.len > 0) gpa.free(upright);
    if (orientation != .normal) {
        upright = try gpa.alloc(u8, src.len);
        common.orient(src, sw, sh, upright, orientation);
        src = upright;
        if (orientation.swapsSides()) std.mem.swap(u32, &sw, &sh);
    }
    const size = common.fitSize(sw, sh, options.max_side);
    const channels: u3 = if (options.format == .jpeg) 3 else 4;
    const pixels = try gpa.alloc(u8, @as(usize, size.width) * size.height * channels);
    defer gpa.free(pixels);
    common.downscale(src, sw, sh, pixels, size.width, size.height, channels);

    const scaled = zigimg.Image.fromRawPixelsOwned(size.width, size.height, pixels, if (channels == 3) .rgb24 else .rgba32) catch return error.CaptureFailed;
    // Room for the worst case: raw pixels plus headers (PNG of noise).
    const out = try gpa.alloc(u8, pixels.len + (1 << 16));
    defer gpa.free(out);
    const encoded = scaled.writeToMemory(gpa, out, switch (options.format) {
        .jpeg => .{ .jpeg = .{ .quality = options.quality } },
        .png => .{ .png = .{} },
    }) catch |err| {
        log.warn("encoding the photo: {s}", .{@errorName(err)});
        return if (err == error.OutOfMemory) error.OutOfMemory else error.CaptureFailed;
    };
    if (encoded.len > common.max_bytes) return error.TooLarge;
    return .{
        .bytes = try arena.dupe(u8, encoded),
        .width = size.width,
        .height = size.height,
        .mime = options.format.mime(),
    };
}

/// What zigimg can't decode, as picked: its type from its bytes (else the
/// extension), its size from its header (else 0 x 0).
fn passThrough(arena: std.mem.Allocator, bytes: []const u8, path: []const u8) common.Error!common.Photo {
    if (bytes.len > common.max_bytes) return error.TooLarge;
    const mime = common.sniffMime(bytes) orelse common.mimeFromExtension(path) orelse return error.CaptureFailed;
    var size = common.imageSize(bytes) orelse common.Size{ .width = 0, .height = 0 };
    // Shown upright (the page's <img> applies EXIF): report it so.
    if (std.mem.eql(u8, mime, "image/jpeg") and common.jpegOrientation(bytes).swapsSides()) std.mem.swap(u32, &size.width, &size.height);
    return .{ .bytes = try arena.dupe(u8, bytes), .width = size.width, .height = size.height, .mime = mime };
}

pub fn check(_: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    return .{
        .module = "camera",
        .ok = true,
        .detail = "library: the file dialog filtered to images, decoded and scaled with zigimg; camera: unsupported (use getUserMedia)",
    };
}

test "a PNG is decoded, scaled and encoded as JPEG" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    // A 64 x 32 PNG made with zigimg.
    var src = try zigimg.Image.create(gpa, 64, 32, .rgba32);
    defer src.deinit(gpa);
    for (src.pixels.rgba32, 0..) |*p, i| p.* = .{ .r = @intCast(i % 256), .g = 128, .b = 0, .a = 255 };
    var buf: [64 << 10]u8 = undefined;
    const png = try src.writeToMemory(gpa, &buf, .{ .png = .{} });

    const photo = try encode(arena.allocator(), png, "x.png", .{ .max_side = 16, .quality = 80 });
    try std.testing.expectEqual(@as(u32, 16), photo.width);
    try std.testing.expectEqual(@as(u32, 8), photo.height);
    try std.testing.expectEqualStrings("image/jpeg", photo.mime);
    try std.testing.expectEqualStrings("image/jpeg", common.sniffMime(photo.bytes).?);
    try std.testing.expectEqual(common.Size{ .width = 16, .height = 8 }, common.imageSize(photo.bytes).?);

    const kept = try encode(arena.allocator(), png, "x.png", .{ .max_side = 1600, .format = .png });
    try std.testing.expectEqual(common.Size{ .width = 64, .height = 32 }, common.imageSize(kept.bytes).?);
    try std.testing.expectEqualStrings("image/png", kept.mime);
}

test "a JPEG's EXIF orientation is applied before scaling" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    // 64 x 32: the left half black, the right half white.
    var src = try zigimg.Image.create(gpa, 64, 32, .rgb24);
    defer src.deinit(gpa);
    for (src.pixels.rgb24, 0..) |*p, i| {
        const v: u8 = if (i % 64 < 32) 0 else 255;
        p.* = .{ .r = v, .g = v, .b = v };
    }
    var buf: [64 << 10]u8 = undefined;
    const plain = try src.writeToMemory(gpa, &buf, .{ .jpeg = .{ .quality = 95 } });
    // Splice in an APP1 with orientation 6 (rotate 90 clockwise) after SOI.
    const app1 = "\xFF\xE1\x00\x22Exif\x00\x00" ++ "MM\x00\x2A\x00\x00\x00\x08" ++ "\x00\x01" ++
        "\x01\x12\x00\x03\x00\x00\x00\x01\x00\x06\x00\x00" ++ "\x00\x00\x00\x00";
    const jpeg = try std.mem.concat(arena.allocator(), u8, &.{ plain[0..2], app1, plain[2..] });
    try std.testing.expectEqual(common.Orientation.rotate_90, common.jpegOrientation(jpeg));

    const photo = try encode(arena.allocator(), jpeg, "x.jpg", .{ .max_side = 1600, .format = .png });
    try std.testing.expectEqual(common.Size{ .width = 32, .height = 64 }, common.imageSize(photo.bytes).?);
    // Rotated clockwise: the left half (black) is now the top.
    var out = try zigimg.Image.fromMemory(gpa, photo.bytes);
    defer out.deinit(gpa);
    try out.convert(gpa, .rgba32);
    const px = out.pixels.rgba32;
    try std.testing.expect(px[2 * 32 + 16].r < 64); // top
    try std.testing.expect(px[60 * 32 + 16].r > 192); // bottom
}

test "what zigimg can't decode comes back as it was" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const heic = "\x00\x00\x00\x18ftypheic\x00\x00\x00\x00mif1heic";
    const photo = try encode(arena.allocator(), heic, "IMG_1.HEIC", .{});
    try std.testing.expectEqualStrings("image/heic", photo.mime);
    try std.testing.expectEqual(@as(u32, 0), photo.width);
    try std.testing.expectEqualSlices(u8, heic, photo.bytes);
    try std.testing.expectError(error.CaptureFailed, encode(arena.allocator(), "not an image", "notes.txt", .{}));
}
