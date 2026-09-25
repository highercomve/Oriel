//! Pure-std data structures and cryptographic verification for Oriel update manifests.
//! Defines:
//! - Semver 2.0.0 parsing and precedence rules ('v' prefix tolerated).
//! - Domain-separated update manifest format: "oriel-update-v2\n{app_id}\n{version}\n{target}\n{format}\n{size}\n{sha256}\n{url}\n{expires}\n".
//! - Base64 Ed25519 signing and verification.
//! Pure std: does NOT depend on GTK, WebKit, or any Oriel runtime code.

const std = @import("std");
const builtin = @import("builtin");
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

pub const DOMAIN_PREFIX = "oriel-update-v2\n";
pub const PUBLIC_KEY_B64_LEN = 44;
pub const SIGNATURE_B64_LEN = 88;
pub const PRIVATE_KEY_SEED_B64_LEN = 44;

pub const Manifest = struct {
    app_id: []const u8,
    version: []const u8,
    target: []const u8,
    format: []const u8,
    size: u64,
    /// Hex-encoded SHA-256 of the payload artifact.
    sha256: []const u8,
    url: []const u8,
    expires: ?u64 = null,
    /// Standard base64-encoded Ed25519 signature.
    signature: []const u8,
};

pub const SignParameters = struct {
    app_id: []const u8,
    version: []const u8,
    target: []const u8,
    format: []const u8,
    size: u64,
    sha256: []const u8,
    url: []const u8,
    expires: ?u64 = null,
    allow_test_http: bool = false,
};

pub const VerifyOptions = struct {
    allow_test_http: bool = false,
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
// Format & Validation Helpers
// ---------------------------------------------------------------------------

/// Consistent case-insensitive SHA-256 hex comparison helper.
pub fn eqlSha256Hex(a: []const u8, b: []const u8) bool {
    if (a.len != 64 or b.len != 64) return false;
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Recognized update formats.
pub fn isValidFormat(format: []const u8) bool {
    const valid = [_][]const u8{
        "raw",
        "raw.gz",
        "appimage",
        "appimage.gz",
        "gzip",
        "app.tar.gz",
    };
    for (valid) |v| {
        if (std.mem.eql(u8, format, v)) return true;
    }
    return false;
}

/// Returns true if the signed format is an AppImage (`appimage`, `appimage.gz`).
pub fn isAppImageFormat(format: []const u8) bool {
    return std.mem.startsWith(u8, format, "appimage");
}

/// Returns true if the signed format is a macOS `.app` bundle: a gzip'd tar
/// holding one `<Name>.app` directory (`app.tar.gz`), which replaces the
/// running bundle as a whole.
pub fn isAppBundleFormat(format: []const u8) bool {
    return std.mem.eql(u8, format, "app.tar.gz");
}

/// Returns true if the signed format specifies gzip decompression of a
/// single file (`app.tar.gz` is unpacked as a bundle instead).
pub fn isGzipFormat(format: []const u8) bool {
    return std.mem.endsWith(u8, format, ".gz") or std.mem.eql(u8, format, "gzip");
}

pub fn validateNoControlChars(val: []const u8) !void {
    if (val.len == 0) return error.EmptyField;
    for (val) |c| {
        if (c < 32 or c == 127) return error.ControlCharactersInField;
    }
}

pub fn validateSha256(hex: []const u8) !void {
    if (hex.len != 64) return error.InvalidSha256Length;
    for (hex) |c| {
        if (!std.ascii.isHex(c)) return error.InvalidSha256Hex;
    }
}

/// Require an `https://` URL. `allow_test_http` (loopback `http://`) only takes
/// effect in test builds, so production code can never opt out of TLS.
pub fn validateUrl(url: []const u8, allow_test_http: bool) !void {
    try validateNoControlChars(url);
    if (std.mem.startsWith(u8, url, "https://")) return;
    if (allow_test_http) {
        if (std.mem.startsWith(u8, url, "http://127.0.0.1:") or
            std.mem.startsWith(u8, url, "http://127.0.0.1/") or
            std.mem.startsWith(u8, url, "http://localhost:") or
            std.mem.startsWith(u8, url, "http://localhost/"))
        {
            return;
        }
    }
    return error.InsecureUrl;
}

pub fn validateManifestFields(
    app_id: []const u8,
    version: []const u8,
    target: []const u8,
    format: []const u8,
    size: u64,
    sha256: []const u8,
    url: []const u8,
    expires: ?u64,
    allow_test_http: bool,
) !void {
    try validateNoControlChars(app_id);
    _ = Semver.parse(version) catch return error.InvalidSemver;
    try validateNoControlChars(version);
    try validateNoControlChars(target);
    try validateNoControlChars(format);
    if (!isValidFormat(format)) return error.InvalidFormat;
    if (size == 0) return error.InvalidSize;
    try validateSha256(sha256);
    try validateUrl(url, allow_test_http);
    if (expires) |exp| {
        if (exp == 0) return error.InvalidExpiration;
    }
}

// ---------------------------------------------------------------------------
// Canonical Signed Data, Signing & Verification
// ---------------------------------------------------------------------------

/// Allocate the domain-separated canonical bytes to be signed/verified:
/// `"oriel-update-v2\n" ++ app_id ++ "\n" ++ version ++ "\n" ++ target ++ "\n" ++ format ++ "\n" ++ size ++ "\n" ++ sha256 ++ "\n" ++ url ++ "\n" ++ expires ++ "\n"`
pub fn formatSignedData(
    allocator: std.mem.Allocator,
    app_id: []const u8,
    version: []const u8,
    target: []const u8,
    format: []const u8,
    size: u64,
    sha256: []const u8,
    url: []const u8,
    expires: ?u64,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}\n{s}\n{s}\n{s}\n{d}\n{s}\n{s}\n{d}\n", .{
        DOMAIN_PREFIX,
        app_id,
        version,
        target,
        format,
        size,
        sha256,
        url,
        expires orelse 0,
    });
}

/// Sign the update artifact parameters and return the base64-encoded signature.
pub fn sign(
    allocator: std.mem.Allocator,
    key_pair: Ed25519.KeyPair,
    params: SignParameters,
) ![]u8 {
    try validateManifestFields(
        params.app_id,
        params.version,
        params.target,
        params.format,
        params.size,
        params.sha256,
        params.url,
        params.expires,
        params.allow_test_http,
    );

    const signed_data = try formatSignedData(
        allocator,
        params.app_id,
        params.version,
        params.target,
        params.format,
        params.size,
        params.sha256,
        params.url,
        params.expires,
    );
    defer allocator.free(signed_data);

    const sig = try key_pair.sign(signed_data, null);
    const sig_bytes = sig.toBytes();
    const sig_b64 = try allocator.alloc(u8, SIGNATURE_B64_LEN);
    _ = std.base64.standard.Encoder.encode(sig_b64, &sig_bytes);
    return sig_b64;
}

/// Format the signed manifest JSON:
pub fn formatManifest(
    allocator: std.mem.Allocator,
    params: SignParameters,
    signature_b64: []const u8,
) ![]u8 {
    const manifest = Manifest{
        .app_id = params.app_id,
        .version = params.version,
        .target = params.target,
        .format = params.format,
        .size = params.size,
        .sha256 = params.sha256,
        .url = params.url,
        .expires = params.expires,
        .signature = signature_b64,
    };
    return std.json.Stringify.valueAlloc(allocator, manifest, .{ .whitespace = .indent_2 });
}

/// Verify signature over the manifest JSON using base64-encoded `public_key_b64`.
/// Strictly requires https:// URLs.
pub fn verify(
    arena: std.mem.Allocator,
    manifest_json: []const u8,
    public_key_b64: []const u8,
) !Manifest {
    return verifyWithOptions(arena, manifest_json, public_key_b64, .{});
}

/// Verify signature over manifest JSON with explicit options (e.g. allow_test_http).
pub fn verifyWithOptions(
    arena: std.mem.Allocator,
    manifest_json: []const u8,
    public_key_b64: []const u8,
    options: VerifyOptions,
) !Manifest {
    const pk_bytes = try parsePublicKey(public_key_b64);
    const pk = try Ed25519.PublicKey.fromBytes(pk_bytes);

    const manifest = try std.json.parseFromSliceLeaky(Manifest, arena, manifest_json, .{
        .ignore_unknown_fields = true,
    });

    try validateManifestFields(
        manifest.app_id,
        manifest.version,
        manifest.target,
        manifest.format,
        manifest.size,
        manifest.sha256,
        manifest.url,
        manifest.expires,
        options.allow_test_http,
    );

    const sig_bytes = try parseSignature(manifest.signature);
    const sig = Ed25519.Signature.fromBytes(sig_bytes);

    const signed_data = try formatSignedData(
        arena,
        manifest.app_id,
        manifest.version,
        manifest.target,
        manifest.format,
        manifest.size,
        manifest.sha256,
        manifest.url,
        manifest.expires,
    );
    try sig.verify(signed_data, pk);

    return manifest;
}

// ---------------------------------------------------------------------------
// Combined manifests: one file (`latest.json`) for every platform
// ---------------------------------------------------------------------------
//
//   {"app_id": ..., "version": ..., "pub_date": ..., "notes": ...,
//    "platforms": {"x86_64-linux": {<signed v2 manifest>}, ...}}
//
// Each platform entry is a complete, individually signed v2 manifest. The
// top-level fields are informational only: clients act on the verified entry.

pub const max_platforms = 32;

/// Verify the manifest for `target`. `json` is either a combined manifest
/// (the entry under `platforms.<target>` is verified) or a single-platform one.
pub fn verifyForTarget(
    arena: std.mem.Allocator,
    json: []const u8,
    public_key_b64: []const u8,
    target: []const u8,
    options: VerifyOptions,
) !Manifest {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch return error.InvalidManifest;
    if (root != .object) return error.InvalidManifest;
    const entry_json: []const u8 = if (root.object.get("platforms")) |platforms| blk: {
        if (platforms != .object) return error.InvalidManifest;
        const entry = platforms.object.get(target) orelse return error.TargetNotInManifest;
        break :blk try std.json.Stringify.valueAlloc(arena, entry, .{});
    } else json;
    const m = try verifyWithOptions(arena, entry_json, public_key_b64, options);
    // The signature covers `target`: an entry filed under another key is refused.
    if (!std.mem.eql(u8, m.target, target)) return error.TargetMismatch;
    return m;
}

pub const CombineOptions = struct {
    /// RFC 3339 date, informational.
    pub_date: ?[]const u8 = null,
    /// Release notes, informational.
    notes: ?[]const u8 = null,
    allow_test_http: bool = false,
};

/// Combine single-platform manifests (same app_id and version, one per
/// target) into a combined manifest. The caller owns the result. Signatures
/// are only checked for form here; clients verify each entry.
pub fn combine(allocator: std.mem.Allocator, manifests_json: []const []const u8, opts: CombineOptions) ![]u8 {
    if (manifests_json.len == 0) return error.NoManifests;
    if (manifests_json.len > max_platforms) return error.TooManyPlatforms;
    if (opts.pub_date) |d| try validateNoControlChars(d);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entries = try arena.alloc(Manifest, manifests_json.len);
    for (manifests_json, 0..) |j, i| {
        const m = std.json.parseFromSliceLeaky(Manifest, arena, j, .{ .ignore_unknown_fields = true }) catch return error.InvalidManifest;
        try validateManifestFields(m.app_id, m.version, m.target, m.format, m.size, m.sha256, m.url, m.expires, opts.allow_test_http);
        _ = try parseSignature(m.signature);
        if (i > 0) {
            if (!std.mem.eql(u8, m.app_id, entries[0].app_id)) return error.AppIdMismatch;
            if (!std.mem.eql(u8, m.version, entries[0].version)) return error.VersionMismatch;
        }
        for (entries[0..i]) |prev| if (std.mem.eql(u8, prev.target, m.target)) return error.DuplicateTarget;
        entries[i] = m;
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    try jw.beginObject();
    try jw.objectField("app_id");
    try jw.write(entries[0].app_id);
    try jw.objectField("version");
    try jw.write(entries[0].version);
    if (opts.pub_date) |d| {
        try jw.objectField("pub_date");
        try jw.write(d);
    }
    if (opts.notes) |n| {
        try jw.objectField("notes");
        try jw.write(n);
    }
    try jw.objectField("platforms");
    try jw.beginObject();
    for (entries) |m| {
        try jw.objectField(m.target);
        try jw.write(m);
    }
    try jw.endObject();
    try jw.endObject();
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
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

test "Manifest v2 sign, format, and verify with all fields" {
    const allocator = std.testing.allocator;

    const seed: [32]u8 = [_]u8{42} ** 32;
    const kp = try Ed25519.KeyPair.generateDeterministic(seed);
    const other_kp = try Ed25519.KeyPair.generateDeterministic([_]u8{99} ** 32);

    var pk_b64: [PUBLIC_KEY_B64_LEN]u8 = undefined;
    _ = encodePublicKey(kp.public_key.toBytes(), &pk_b64);

    var other_pk_b64: [PUBLIC_KEY_B64_LEN]u8 = undefined;
    _ = encodePublicKey(other_kp.public_key.toBytes(), &other_pk_b64);

    const params = SignParameters{
        .app_id = "dev.oriel.demo",
        .version = "1.2.3",
        .target = "x86_64-linux",
        .format = "appimage",
        .size = 1048576,
        .sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        .url = "https://example.com/app",
        .expires = 1900000000,
    };

    const sig_b64 = try sign(allocator, kp, params);
    defer allocator.free(sig_b64);

    const manifest_json = try formatManifest(allocator, params, sig_b64);
    defer allocator.free(manifest_json);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // 1. Valid manifest
    const m = try verify(arena.allocator(), manifest_json, &pk_b64);
    try std.testing.expectEqualStrings(params.app_id, m.app_id);
    try std.testing.expectEqualStrings(params.version, m.version);
    try std.testing.expectEqualStrings(params.target, m.target);
    try std.testing.expectEqualStrings(params.format, m.format);
    try std.testing.expectEqual(params.size, m.size);
    try std.testing.expectEqualStrings(params.sha256, m.sha256);
    try std.testing.expectEqualStrings(params.url, m.url);
    try std.testing.expectEqual(params.expires, m.expires);
    try std.testing.expectEqualStrings(sig_b64, m.signature);

    // 2. Tampered version rejected
    const tampered_ver = try std.fmt.allocPrint(allocator,
        \\{{"app_id":"{s}","version":"9.9.9","target":"{s}","format":"{s}","size":{d},"sha256":"{s}","url":"{s}","expires":{d},"signature":"{s}"}}
    , .{ params.app_id, params.target, params.format, params.size, params.sha256, params.url, params.expires.?, sig_b64 });
    defer allocator.free(tampered_ver);
    try std.testing.expectError(error.SignatureVerificationFailed, verify(arena.allocator(), tampered_ver, &pk_b64));

    // 3. Tampered app_id rejected
    const tampered_app = try std.fmt.allocPrint(allocator,
        \\{{"app_id":"evil.app","version":"{s}","target":"{s}","format":"{s}","size":{d},"sha256":"{s}","url":"{s}","expires":{d},"signature":"{s}"}}
    , .{ params.version, params.target, params.format, params.size, params.sha256, params.url, params.expires.?, sig_b64 });
    defer allocator.free(tampered_app);
    try std.testing.expectError(error.SignatureVerificationFailed, verify(arena.allocator(), tampered_app, &pk_b64));

    // 4. Tampered target rejected
    const tampered_target = try std.fmt.allocPrint(allocator,
        \\{{"app_id":"{s}","version":"{s}","target":"aarch64-linux","format":"{s}","size":{d},"sha256":"{s}","url":"{s}","expires":{d},"signature":"{s}"}}
    , .{ params.app_id, params.version, params.format, params.size, params.sha256, params.url, params.expires.?, sig_b64 });
    defer allocator.free(tampered_target);
    try std.testing.expectError(error.SignatureVerificationFailed, verify(arena.allocator(), tampered_target, &pk_b64));

    // 5. Tampered format rejected
    const tampered_format = try std.fmt.allocPrint(allocator,
        \\{{"app_id":"{s}","version":"{s}","target":"{s}","format":"raw","size":{d},"sha256":"{s}","url":"{s}","expires":{d},"signature":"{s}"}}
    , .{ params.app_id, params.version, params.target, params.size, params.sha256, params.url, params.expires.?, sig_b64 });
    defer allocator.free(tampered_format);
    try std.testing.expectError(error.SignatureVerificationFailed, verify(arena.allocator(), tampered_format, &pk_b64));

    // 6. Tampered size rejected
    const tampered_size = try std.fmt.allocPrint(allocator,
        \\{{"app_id":"{s}","version":"{s}","target":"{s}","format":"{s}","size":9999,"sha256":"{s}","url":"{s}","expires":{d},"signature":"{s}"}}
    , .{ params.app_id, params.version, params.target, params.format, params.sha256, params.url, params.expires.?, sig_b64 });
    defer allocator.free(tampered_size);
    try std.testing.expectError(error.SignatureVerificationFailed, verify(arena.allocator(), tampered_size, &pk_b64));

    // 7. Tampered url rejected
    const tampered_url = try std.fmt.allocPrint(allocator,
        \\{{"app_id":"{s}","version":"{s}","target":"{s}","format":"{s}","size":{d},"sha256":"{s}","url":"https://evil.com/app","expires":{d},"signature":"{s}"}}
    , .{ params.app_id, params.version, params.target, params.format, params.size, params.sha256, params.expires.?, sig_b64 });
    defer allocator.free(tampered_url);
    try std.testing.expectError(error.SignatureVerificationFailed, verify(arena.allocator(), tampered_url, &pk_b64));

    // 8. Tampered sha256 rejected
    const tampered_hash = try std.fmt.allocPrint(allocator,
        \\{{"app_id":"{s}","version":"{s}","target":"{s}","format":"{s}","size":{d},"sha256":"0000000000000000000000000000000000000000000000000000000000000000","url":"{s}","expires":{d},"signature":"{s}"}}
    , .{ params.app_id, params.version, params.target, params.format, params.size, params.url, params.expires.?, sig_b64 });
    defer allocator.free(tampered_hash);
    try std.testing.expectError(error.SignatureVerificationFailed, verify(arena.allocator(), tampered_hash, &pk_b64));

    // 9. Tampered expires rejected
    const tampered_exp = try std.fmt.allocPrint(allocator,
        \\{{"app_id":"{s}","version":"{s}","target":"{s}","format":"{s}","size":{d},"sha256":"{s}","url":"{s}","expires":2000000000,"signature":"{s}"}}
    , .{ params.app_id, params.version, params.target, params.format, params.size, params.sha256, params.url, sig_b64 });
    defer allocator.free(tampered_exp);
    try std.testing.expectError(error.SignatureVerificationFailed, verify(arena.allocator(), tampered_exp, &pk_b64));

    // 10. Wrong public key rejected
    try std.testing.expectError(error.SignatureVerificationFailed, verify(arena.allocator(), manifest_json, &other_pk_b64));

    // 11. Bad public key base64 rejected
    try std.testing.expectError(error.InvalidPublicKeyLength, verify(arena.allocator(), manifest_json, "invalid"));
}

test "Field validation: control chars, sha256, urls, format" {
    const allocator = std.testing.allocator;
    const kp = try Ed25519.KeyPair.generateDeterministic([_]u8{11} ** 32);

    // Control characters in fields rejected
    var bad_params = SignParameters{
        .app_id = "app\nid",
        .version = "1.0.0",
        .target = "x86_64-linux",
        .format = "raw",
        .size = 100,
        .sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        .url = "https://example.com/app",
    };
    try std.testing.expectError(error.ControlCharactersInField, sign(allocator, kp, bad_params));

    bad_params.app_id = "good_app";
    bad_params.target = "x86_64\rlinux";
    try std.testing.expectError(error.ControlCharactersInField, sign(allocator, kp, bad_params));

    // Invalid SHA-256 (length != 64)
    bad_params.target = "x86_64-linux";
    bad_params.sha256 = "abc";
    try std.testing.expectError(error.InvalidSha256Length, sign(allocator, kp, bad_params));

    // Invalid SHA-256 (non-hex chars)
    bad_params.sha256 = "g3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    try std.testing.expectError(error.InvalidSha256Hex, sign(allocator, kp, bad_params));

    // Insecure URL (http:// without allow_test_http)
    bad_params.sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    bad_params.url = "http://example.com/app";
    try std.testing.expectError(error.InsecureUrl, sign(allocator, kp, bad_params));

    // Insecure test URL rejected when allow_test_http = false
    bad_params.url = "http://127.0.0.1:8080/app";
    bad_params.allow_test_http = false;
    try std.testing.expectError(error.InsecureUrl, sign(allocator, kp, bad_params));

    // Insecure test URL accepted when allow_test_http = true
    bad_params.allow_test_http = true;
    const test_sig = try sign(allocator, kp, bad_params);
    allocator.free(test_sig);

    // Invalid format
    bad_params.format = "unknown_format";
    try std.testing.expectError(error.InvalidFormat, sign(allocator, kp, bad_params));

    // Zero size rejected
    bad_params.format = "raw";
    bad_params.size = 0;
    try std.testing.expectError(error.InvalidSize, sign(allocator, kp, bad_params));

    // Case-insensitive sha256 compare helper
    const hash_lower = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    const hash_upper = "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855";
    try std.testing.expect(eqlSha256Hex(hash_lower, hash_upper));
    try std.testing.expect(!eqlSha256Hex(hash_lower, "0000c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"));
    try std.testing.expect(!eqlSha256Hex(hash_lower, "short"));
}

test "manifest target accepts x86_64-windows" {
    const allocator = std.testing.allocator;
    const kp = try Ed25519.KeyPair.generateDeterministic([_]u8{99} ** 32);

    const win_params = SignParameters{
        .app_id = "com.example.winapp",
        .version = "1.2.3",
        .target = "x86_64-windows",
        .format = "raw",
        .size = 1048576,
        .sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        .url = "https://example.com/downloads/app.exe",
    };

    const sig = try sign(allocator, kp, win_params);
    defer allocator.free(sig);

    const manifest_json = try formatManifest(allocator, win_params, sig);
    defer allocator.free(manifest_json);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var pk_b64: [PUBLIC_KEY_B64_LEN]u8 = undefined;
    _ = encodePublicKey(kp.public_key.toBytes(), &pk_b64);

    const verified = try verify(arena.allocator(), manifest_json, &pk_b64);
    try std.testing.expectEqualStrings("com.example.winapp", verified.app_id);
    try std.testing.expectEqualStrings("1.2.3", verified.version);
    try std.testing.expectEqualStrings("x86_64-windows", verified.target);
    try std.testing.expectEqualStrings("raw", verified.format);
    try std.testing.expectEqual(1048576, verified.size);
}

test "combined manifest: per-target verify, tampering, mixing" {
    const allocator = std.testing.allocator;
    const kp = try Ed25519.KeyPair.generateDeterministic([_]u8{7} ** 32);
    var pk_b64: [PUBLIC_KEY_B64_LEN]u8 = undefined;
    _ = encodePublicKey(kp.public_key.toBytes(), &pk_b64);

    const base = SignParameters{
        .app_id = "dev.oriel.demo",
        .version = "1.2.3",
        .target = "x86_64-linux",
        .format = "raw",
        .size = 10,
        .sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        .url = "https://example.com/app-linux",
    };
    var win = base;
    win.target = "x86_64-windows";
    win.url = "https://example.com/app.exe";

    var jsons: [2][]u8 = undefined;
    for ([_]SignParameters{ base, win }, 0..) |p, i| {
        const sig = try sign(allocator, kp, p);
        defer allocator.free(sig);
        jsons[i] = try formatManifest(allocator, p, sig);
    }
    defer for (jsons) |j| allocator.free(j);

    const combined = try combine(allocator, &.{ jsons[0], jsons[1] }, .{ .pub_date = "2026-09-25T00:00:00Z", .notes = "notes" });
    defer allocator.free(combined);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const lin = try verifyForTarget(a, combined, &pk_b64, "x86_64-linux", .{});
    try std.testing.expectEqualStrings("https://example.com/app-linux", lin.url);
    const w = try verifyForTarget(a, combined, &pk_b64, "x86_64-windows", .{});
    try std.testing.expectEqualStrings("https://example.com/app.exe", w.url);
    try std.testing.expectError(error.TargetNotInManifest, verifyForTarget(a, combined, &pk_b64, "aarch64-macos", .{}));

    // A single-platform manifest still verifies, but only for its own target.
    _ = try verifyForTarget(a, jsons[0], &pk_b64, "x86_64-linux", .{});
    try std.testing.expectError(error.TargetMismatch, verifyForTarget(a, jsons[0], &pk_b64, "x86_64-windows", .{}));

    // The Linux entry filed under the Windows key: signature ok, target refused.
    const swapped = try std.fmt.allocPrint(allocator, "{{\"platforms\":{{\"x86_64-windows\":{s}}}}}", .{jsons[0]});
    defer allocator.free(swapped);
    try std.testing.expectError(error.TargetMismatch, verifyForTarget(a, swapped, &pk_b64, "x86_64-windows", .{}));

    // A tampered entry fails its signature.
    const tampered = try std.mem.replaceOwned(u8, allocator, combined, "https://example.com/app.exe", "https://example.com/evil.exe");
    defer allocator.free(tampered);
    try std.testing.expectError(error.SignatureVerificationFailed, verifyForTarget(a, tampered, &pk_b64, "x86_64-windows", .{}));

    // combine refuses duplicates and mixed versions.
    try std.testing.expectError(error.DuplicateTarget, combine(allocator, &.{ jsons[0], jsons[0] }, .{}));
    var other = win;
    other.version = "1.2.4";
    const osig = try sign(allocator, kp, other);
    defer allocator.free(osig);
    const ojson = try formatManifest(allocator, other, osig);
    defer allocator.free(ojson);
    try std.testing.expectError(error.VersionMismatch, combine(allocator, &.{ jsons[0], ojson }, .{}));
    try std.testing.expectError(error.NoManifests, combine(allocator, &.{}, .{}));
}
