//! Self-updater: a JSON manifest signed with Ed25519 points at a gzip'd
//! payload (same trust model as Tauri's updater). Everything here is `std`:
//! `std.json`, `std.crypto.sign.Ed25519`, `std.compress.flate`, and
//! `std.http.Client` for downloading.

const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
const oriel = @import("../oriel.zig");

pub const Manifest = struct {
    version: []const u8,
    url: []const u8,
    /// Hex-encoded SHA-256 of the compressed payload.
    sha256: []const u8,
};

/// Verify `signature` over the raw manifest bytes, then parse them.
pub fn verifyManifest(
    arena: std.mem.Allocator,
    manifest_json: []const u8,
    signature: [Ed25519.Signature.encoded_length]u8,
    public_key: [Ed25519.PublicKey.encoded_length]u8,
) !Manifest {
    const sig = Ed25519.Signature.fromBytes(signature);
    const pk = try Ed25519.PublicKey.fromBytes(public_key);
    try sig.verify(manifest_json, pk);
    return std.json.parseFromSliceLeaky(Manifest, arena, manifest_json, .{});
}

/// Check the payload hash against the manifest and gunzip it.
pub fn unpack(gpa: std.mem.Allocator, manifest: Manifest, payload_gz: []const u8) ![]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload_gz, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, manifest.sha256)) return error.PayloadHashMismatch;

    var in: std.Io.Reader = .fixed(payload_gz);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&in, .gzip, &window);
    return decompress.reader.allocRemaining(gpa, .unlimited);
}

/// 'oriel update payload v0.0.1\n' x 8, gzip'd.
const test_payload_gz = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xff, 0xcb, 0x2f, 0xca, 0x4c, 0xcd, 0x51,
    0x28, 0x2d, 0x48, 0x49, 0x2c, 0x49, 0x55, 0x28, 0x48, 0xac, 0xcc, 0xc9, 0x4f, 0x4c, 0x51, 0x28,
    0x33, 0xd0, 0x33, 0xd0, 0x33, 0xe4, 0xca, 0x1f, 0x06, 0x72, 0x00, 0x2d, 0x20, 0xe4, 0xcb, 0xe0,
    0x00, 0x00, 0x00,
};

pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    // Release side: hash the payload, write and sign the manifest.
    const key_pair = try Ed25519.KeyPair.generateDeterministic([_]u8{42} ** Ed25519.KeyPair.seed_length);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&test_payload_gz, &digest, .{});
    const manifest_json = try std.fmt.allocPrint(gpa, "{{\"version\":\"0.0.1\",\"url\":\"https://example.invalid/app.gz\",\"sha256\":\"{s}\"}}", .{std.fmt.bytesToHex(digest, .lower)});
    defer gpa.free(manifest_json);
    const signature = try key_pair.sign(manifest_json, null);

    // App side: verify, check the hash, unpack.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const manifest = try verifyManifest(arena_state.allocator(), manifest_json, signature.toBytes(), key_pair.public_key.toBytes());
    const payload = try unpack(gpa, manifest, &test_payload_gz);
    defer gpa.free(payload);

    // A tampered manifest must be rejected.
    const tampered = try gpa.dupe(u8, manifest_json);
    defer gpa.free(tampered);
    tampered[13] = '9';
    const rejected = if (verifyManifest(arena_state.allocator(), tampered, signature.toBytes(), key_pair.public_key.toBytes())) |_| false else |_| true;

    return .{
        .module = "updater",
        .ok = rejected and std.mem.startsWith(u8, payload, "oriel update payload"),
        .detail = try std.fmt.allocPrint(gpa, "manifest v{s} Ed25519-verified, tampered copy {s}; payload {d} B gz -> {d} B", .{
            manifest.version,
            if (rejected) "rejected" else "ACCEPTED (bug)",
            test_payload_gz.len,
            payload.len,
        }),
    };
}
