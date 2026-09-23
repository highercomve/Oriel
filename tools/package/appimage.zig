//! AppImage runtime and AppRun script utilities.

const std = @import("std");
const metadata = @import("metadata.zig");

/// Pinned release tag of AppImage type-2 runtime (release 20251108).
pub const APPIMAGE_RUNTIME_TAG = "20251108";

/// URL template for pinned AppImage type-2 runtime release 20251108.
pub const APPIMAGE_RUNTIME_URL_TEMPLATE = "https://github.com/AppImage/type2-runtime/releases/download/20251108/runtime-{s}";

pub const ArchHash = struct {
    arch: []const u8,
    sha256: []const u8,
};

/// Pinned SHA-256 digests for release 20251108 runtimes.
pub const PINNED_RUNTIME_HASHES = [_]ArchHash{
    .{ .arch = "x86_64", .sha256 = "2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d" },
    .{ .arch = "aarch64", .sha256 = "00cbdfcf917cc6c0ff6d3347d59e0ca1f7f45a6df1a428a0d6d8a78664d87444" },
    .{ .arch = "i686", .sha256 = "e72ea0b140a0a16e680713238a6f30aad278b62c4ca17919c554864124515498" },
    .{ .arch = "armhf", .sha256 = "e9060d37577b8a29914ec12d8740add24e19ff29012fb1fa0f60daf62db0688d" },
};

/// Lookup pinned SHA-256 hash for a given architecture.
pub fn getPinnedRuntimeHash(arch: []const u8) ?[]const u8 {
    for (PINNED_RUNTIME_HASHES) |entry| {
        if (std.mem.eql(u8, entry.arch, arch)) return entry.sha256;
    }
    return null;
}

/// Case-insensitive hash comparison.
pub fn verifyHash(expected_hex: []const u8, actual_hex: []const u8) bool {
    if (expected_hex.len != actual_hex.len) return false;
    return std.ascii.eqlIgnoreCase(expected_hex, actual_hex);
}

/// Compute SHA-256 hash of a file by streaming in chunks (does not read whole file into memory).
pub fn computeFileSha256(io: std.Io, path: []const u8, out_hex: *[64]u8) !void {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    var bufs = [_][]u8{&buf};
    while (true) {
        const n = file.readStreaming(io, &bufs) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    _ = std.fmt.bufPrint(out_hex, "{s}", .{std.fmt.bytesToHex(digest, .lower)}) catch unreachable;
}

/// Verify that a file's SHA-256 matches the expected hex string, streaming the file.
pub fn verifyFileSha256(io: std.Io, path: []const u8, expected_hex: []const u8) !bool {
    var actual_hex: [64]u8 = undefined;
    try computeFileSha256(io, path, &actual_hex);
    return verifyHash(expected_hex, &actual_hex);
}

/// Generate AppRun shell script for AppImage.
pub fn generateAppRun(allocator: std.mem.Allocator, exe_name: []const u8) ![]const u8 {
    try metadata.validateExeName(exe_name);
    return try std.fmt.allocPrint(allocator,
        \\#!/bin/sh
        \\HERE="$(dirname "$(readlink -f "${{0}}")")"
        \\export PATH="${{HERE}}/usr/bin:${{PATH}}"
        \\export LD_LIBRARY_PATH="${{HERE}}/usr/lib:${{LD_LIBRARY_PATH:-}}"
        \\export XDG_DATA_DIRS="${{HERE}}/usr/share:${{XDG_DATA_DIRS:-/usr/local/share:/usr/share}}"
        \\exec "${{HERE}}/usr/bin/{s}" "$@"
        \\
    , .{exe_name});
}

/// Verify if buffer begins with ELF header magic "\x7fELF".
pub fn isElfBinary(bytes: []const u8) bool {
    if (bytes.len < 4) return false;
    return std.mem.eql(u8, bytes[0..4], "\x7fELF");
}

test "generateAppRun" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const script = try generateAppRun(gpa, "oriel-react-notes");
    defer gpa.free(script);

    try testing.expect(std.mem.indexOf(u8, script, "exec \"${HERE}/usr/bin/oriel-react-notes\" \"$@\"") != null);

    // Invalid exe_name rejected
    try testing.expectError(error.InvalidExeName, generateAppRun(gpa, "app; injection"));
    try testing.expectError(error.InvalidExeName, generateAppRun(gpa, "-app"));
}

test "isElfBinary" {
    const testing = std.testing;

    try testing.expect(isElfBinary("\x7fELF\x02\x01\x01\x00"));
    try testing.expect(!isElfBinary("MZ\x90\x00"));
    try testing.expect(!isElfBinary("#!/bin/sh"));
    try testing.expect(!isElfBinary(""));
}

test "pinned runtime hashes lookup and compare" {
    const testing = std.testing;

    try testing.expectEqualStrings("2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d", getPinnedRuntimeHash("x86_64").?);
    try testing.expectEqualStrings("00cbdfcf917cc6c0ff6d3347d59e0ca1f7f45a6df1a428a0d6d8a78664d87444", getPinnedRuntimeHash("aarch64").?);
    try testing.expectEqualStrings("e72ea0b140a0a16e680713238a6f30aad278b62c4ca17919c554864124515498", getPinnedRuntimeHash("i686").?);
    try testing.expectEqualStrings("e9060d37577b8a29914ec12d8740add24e19ff29012fb1fa0f60daf62db0688d", getPinnedRuntimeHash("armhf").?);

    // Unknown architecture returns null
    try testing.expect(getPinnedRuntimeHash("unknown_arch") == null);
    try testing.expect(getPinnedRuntimeHash("mips") == null);

    // verifyHash compare
    try testing.expect(verifyHash("2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d", "2FCA8B443C92510F1483A883F60061AD09B46B978B2631C807CD873A47EC260D"));
    try testing.expect(!verifyHash("2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d", "0000000000000000000000000000000000000000000000000000000000000000"));
}

test "computeFileSha256 and verifyFileSha256 streaming" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    const test_file = try std.fs.path.join(allocator, &.{ tmp_path, "test.data" });
    defer allocator.free(test_file);

    const payload = "hello world\n";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = test_file, .data = payload });

    // Known sha256 of "hello world\n": a948904f2f0f479b8f8197694b30184b0d2ed1c1cd2a1ec0fb85d299a192a447
    const expected_sha256 = "a948904f2f0f479b8f8197694b30184b0d2ed1c1cd2a1ec0fb85d299a192a447";

    var computed_hex: [64]u8 = undefined;
    try computeFileSha256(io, test_file, &computed_hex);
    try testing.expectEqualStrings(expected_sha256, &computed_hex);

    try testing.expect(try verifyFileSha256(io, test_file, expected_sha256));
    try testing.expect(!try verifyFileSha256(io, test_file, "0000000000000000000000000000000000000000000000000000000000000000"));
}
