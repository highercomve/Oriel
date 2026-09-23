//! Pure-std data structures and cryptographic verification for Oriel update manifests.
//! Defines:
//! - Semver 2.0.0 parsing and precedence rules ('v' prefix tolerated).
//! - Domain-separated update manifest format: "oriel-update-v1\n{version}\n{url}\n{sha256}\n".
//! - Base64 Ed25519 signing and verification.
//! Pure std: does NOT depend on GTK, WebKit, or any Oriel runtime code.

const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;

// ---------------------------------------------------------------------------
// Semver 2.0.0
// ---------------------------------------------------------------------------

pub const Semver = struct {
    inner: std.SemanticVersion,

    /// Parse a semantic version string. Leading 'v' or 'V' is tolerated.
    pub fn parse(raw: []const u8) !Semver {
        var str = raw;
        if (std.mem.startsWith(u8, str, "v") or std.mem.startsWith(u8, str, "V")) {
            str = str[1..];
        }
        return .{ .inner = try std.SemanticVersion.parse(str) };
    }

    /// Compare two semantic versions following Semver 2.0.0 precedence rules.
    pub fn order(lhs: Semver, rhs: Semver) std.math.Order {
        return lhs.inner.order(rhs.inner);
    }

    /// Returns true if this version is strictly newer than `current`.
    pub fn isNewerThan(self: Semver, current: Semver) bool {
        return self.order(current) == .gt;
    }
};

// ---------------------------------------------------------------------------
// Manifest & Crypto Constants
// ---------------------------------------------------------------------------

pub const DOMAIN_PREFIX = "oriel-update-v1\n";
pub const PUBLIC_KEY_B64_LEN = 44;
pub const SIGNATURE_B64_LEN = 88;
pub const PRIVATE_KEY_SEED_B64_LEN = 44;

pub const Manifest = struct {
    version: []const u8,
    url: []const u8,
    /// Hex-encoded SHA-256 of the payload artifact.
    sha256: []const u8,
    /// Standard base64-encoded Ed25519 signature.
    signature: []const u8,
};

// ---------------------------------------------------------------------------
// Base64 Helpers
// ---------------------------------------------------------------------------

/// Decode a 32-byte Ed25519 public key from standard base64 (44 chars).
pub fn parsePublicKey(b64: []const u8) ![Ed25519.PublicKey.encoded_length]u8 {
    const trimmed = std.mem.trim(u8, b64, " \t\r\n");
    if (trimmed.len != PUBLIC_KEY_B64_LEN) return error.InvalidPublicKeyLength;
    var out: [32]u8 = undefined;
    try std.base64.standard.Decoder.decode(&out, trimmed);
    return out;
}

/// Encode a 32-byte Ed25519 public key into standard base64.
pub fn encodePublicKey(pk_bytes: [Ed25519.PublicKey.encoded_length]u8, out: *[PUBLIC_KEY_B64_LEN]u8) []const u8 {
    return std.base64.standard.Encoder.encode(out, &pk_bytes);
}

/// Decode a 64-byte Ed25519 signature from standard base64 (88 chars).
pub fn parseSignature(b64: []const u8) ![Ed25519.Signature.encoded_length]u8 {
    const trimmed = std.mem.trim(u8, b64, " \t\r\n");
    if (trimmed.len != SIGNATURE_B64_LEN) return error.InvalidSignatureLength;
    var out: [64]u8 = undefined;
    try std.base64.standard.Decoder.decode(&out, trimmed);
    return out;
}

/// Encode a 64-byte Ed25519 signature into standard base64.
pub fn encodeSignature(sig_bytes: [Ed25519.Signature.encoded_length]u8, out: *[SIGNATURE_B64_LEN]u8) []const u8 {
    return std.base64.standard.Encoder.encode(out, &sig_bytes);
}

/// Decode a 32-byte Ed25519 seed from standard base64 (44 chars).
pub fn parsePrivateKeySeed(b64: []const u8) ![Ed25519.KeyPair.seed_length]u8 {
    const trimmed = std.mem.trim(u8, b64, " \t\r\n");
    if (trimmed.len != PRIVATE_KEY_SEED_B64_LEN) return error.InvalidPrivateKeyLength;
    var out: [32]u8 = undefined;
    try std.base64.standard.Decoder.decode(&out, trimmed);
    return out;
}

/// Encode a 32-byte Ed25519 seed into standard base64.
pub fn encodePrivateKeySeed(seed: [Ed25519.KeyPair.seed_length]u8, out: *[PRIVATE_KEY_SEED_B64_LEN]u8) []const u8 {
    return std.base64.standard.Encoder.encode(out, &seed);
}

/// Load an Ed25519 KeyPair from a base64-encoded 32-byte seed.
pub fn keyPairFromSeedB64(b64: []const u8) !Ed25519.KeyPair {
    const seed = try parsePrivateKeySeed(b64);
    return Ed25519.KeyPair.generateDeterministic(seed);
}

// ---------------------------------------------------------------------------
// Canonical Signed Data, Signing & Verification
// ---------------------------------------------------------------------------

/// Allocate the domain-separated canonical bytes to be signed/verified:
/// `"oriel-update-v1\n" ++ version ++ "\n" ++ url ++ "\n" ++ sha256 ++ "\n"`
pub fn formatSignedData(
    allocator: std.mem.Allocator,
    version: []const u8,
    url: []const u8,
    sha256: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}\n{s}\n{s}\n", .{
        DOMAIN_PREFIX,
        version,
        url,
        sha256,
    });
}

/// Sign the update artifact parameters and return the base64-encoded signature.
pub fn sign(
    allocator: std.mem.Allocator,
    key_pair: Ed25519.KeyPair,
    version: []const u8,
    url: []const u8,
    sha256: []const u8,
) ![]u8 {
    const signed_data = try formatSignedData(allocator, version, url, sha256);
    defer allocator.free(signed_data);

    const sig = try key_pair.sign(signed_data, null);
    const sig_bytes = sig.toBytes();
    const sig_b64 = try allocator.alloc(u8, SIGNATURE_B64_LEN);
    _ = std.base64.standard.Encoder.encode(sig_b64, &sig_bytes);
    return sig_b64;
}

/// Format the signed manifest JSON:
/// {
///   "version": "...",
///   "url": "...",
///   "sha256": "...",
///   "signature": "..."
/// }
pub fn formatManifest(
    allocator: std.mem.Allocator,
    version: []const u8,
    url: []const u8,
    sha256: []const u8,
    signature_b64: []const u8,
) ![]u8 {
    const manifest = Manifest{
        .version = version,
        .url = url,
        .sha256 = sha256,
        .signature = signature_b64,
    };
    return std.json.Stringify.valueAlloc(allocator, manifest, .{ .whitespace = .indent_2 });
}

/// Verify signature over the manifest JSON using base64-encoded `public_key_b64`.
/// Returns the parsed `Manifest` allocated in `arena`.
pub fn verify(
    arena: std.mem.Allocator,
    manifest_json: []const u8,
    public_key_b64: []const u8,
) !Manifest {
    const pk_bytes = try parsePublicKey(public_key_b64);
    const pk = try Ed25519.PublicKey.fromBytes(pk_bytes);

    const manifest = try std.json.parseFromSliceLeaky(Manifest, arena, manifest_json, .{
        .ignore_unknown_fields = true,
    });

    const sig_bytes = try parseSignature(manifest.signature);
    const sig = Ed25519.Signature.fromBytes(sig_bytes);

    const signed_data = try formatSignedData(arena, manifest.version, manifest.url, manifest.sha256);
    try sig.verify(signed_data, pk);

    return manifest;
}

// ---------------------------------------------------------------------------
// Unit Tests
// ---------------------------------------------------------------------------

test "Semver parsing, ordering, and prefix handling" {
    const v100 = try Semver.parse("1.0.0");
    const v101 = try Semver.parse("1.0.1");
    const v110 = try Semver.parse("1.1.0");
    const v200 = try Semver.parse("2.0.0");

    try std.testing.expect(v101.isNewerThan(v100));
    try std.testing.expect(v110.isNewerThan(v101));
    try std.testing.expect(v200.isNewerThan(v110));
    try std.testing.expect(!v100.isNewerThan(v100));
    try std.testing.expect(!v100.isNewerThan(v101));

    // Leading 'v' and 'V' prefix
    const with_v = try Semver.parse("v1.2.3");
    const with_big_v = try Semver.parse("V1.2.3");
    const no_v = try Semver.parse("1.2.3");
    try std.testing.expectEqual(std.math.Order.eq, with_v.order(no_v));
    try std.testing.expectEqual(std.math.Order.eq, with_big_v.order(no_v));

    // Prerelease precedence
    const p1 = try Semver.parse("1.0.0-alpha");
    const p2 = try Semver.parse("1.0.0-alpha.1");
    const p3 = try Semver.parse("1.0.0-alpha.beta");
    const p4 = try Semver.parse("1.0.0-beta");
    const p5 = try Semver.parse("1.0.0-beta.2");
    const p6 = try Semver.parse("1.0.0-beta.11");
    const p7 = try Semver.parse("1.0.0-rc.1");
    const rel = try Semver.parse("1.0.0");

    try std.testing.expect(p2.isNewerThan(p1));
    try std.testing.expect(p3.isNewerThan(p2));
    try std.testing.expect(p4.isNewerThan(p3));
    try std.testing.expect(p5.isNewerThan(p4));
    try std.testing.expect(p6.isNewerThan(p5));
    try std.testing.expect(p7.isNewerThan(p6));
    try std.testing.expect(rel.isNewerThan(p7));
}

test "Manifest sign and verify" {
    const allocator = std.testing.allocator;

    const seed: [32]u8 = [_]u8{42} ** 32;
    const kp = try Ed25519.KeyPair.generateDeterministic(seed);
    const other_kp = try Ed25519.KeyPair.generateDeterministic([_]u8{99} ** 32);

    var pk_b64: [PUBLIC_KEY_B64_LEN]u8 = undefined;
    _ = encodePublicKey(kp.public_key.toBytes(), &pk_b64);

    var other_pk_b64: [PUBLIC_KEY_B64_LEN]u8 = undefined;
    _ = encodePublicKey(other_kp.public_key.toBytes(), &other_pk_b64);

    const version = "1.2.3";
    const url = "https://example.com/app";
    const sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

    const sig_b64 = try sign(allocator, kp, version, url, sha256);
    defer allocator.free(sig_b64);

    const manifest_json = try formatManifest(allocator, version, url, sha256, sig_b64);
    defer allocator.free(manifest_json);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // 1. Valid manifest
    const m = try verify(arena.allocator(), manifest_json, &pk_b64);
    try std.testing.expectEqualStrings(version, m.version);
    try std.testing.expectEqualStrings(url, m.url);
    try std.testing.expectEqualStrings(sha256, m.sha256);
    try std.testing.expectEqualStrings(sig_b64, m.signature);

    // 2. Tampered version rejected
    const tampered_ver = try std.fmt.allocPrint(allocator, "{{\"version\":\"9.9.9\",\"url\":\"{s}\",\"sha256\":\"{s}\",\"signature\":\"{s}\"}}", .{ url, sha256, sig_b64 });
    defer allocator.free(tampered_ver);
    try std.testing.expectError(error.SignatureVerificationFailed, verify(arena.allocator(), tampered_ver, &pk_b64));

    // 3. Tampered url rejected
    const tampered_url = try std.fmt.allocPrint(allocator, "{{\"version\":\"{s}\",\"url\":\"https://evil.com/app\",\"sha256\":\"{s}\",\"signature\":\"{s}\"}}", .{ version, sha256, sig_b64 });
    defer allocator.free(tampered_url);
    try std.testing.expectError(error.SignatureVerificationFailed, verify(arena.allocator(), tampered_url, &pk_b64));

    // 4. Tampered sha256 rejected
    const tampered_hash = try std.fmt.allocPrint(allocator, "{{\"version\":\"{s}\",\"url\":\"{s}\",\"sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"signature\":\"{s}\"}}", .{ version, url, sig_b64 });
    defer allocator.free(tampered_hash);
    try std.testing.expectError(error.SignatureVerificationFailed, verify(arena.allocator(), tampered_hash, &pk_b64));

    // 5. Wrong public key rejected
    try std.testing.expectError(error.SignatureVerificationFailed, verify(arena.allocator(), manifest_json, &other_pk_b64));

    // 6. Bad base64 rejected
    try std.testing.expectError(error.InvalidPublicKeyLength, verify(arena.allocator(), manifest_json, "invalid"));
}
