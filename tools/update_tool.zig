//! Host CLI tool for Oriel update management:
//! - keygen: Generate an Ed25519 keypair for signing updates (base64 private key seed, base64 public key).
//! - sign-update: Hash an artifact, sign domain-separated bytes, and produce a manifest JSON.

const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;
const manifest_mod = @import("update_manifest");

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const argv = init.minimal.args.vector;

    if (argv.len < 2) {
        printUsage();
        return 1;
    }

    const command = std.mem.span(argv[1]);
    const args = argv[2..];

    if (std.mem.eql(u8, command, "keygen")) {
        return handleKeygen(io, gpa, init.environ_map, args);
    } else if (std.mem.eql(u8, command, "sign-update")) {
        return handleSignUpdate(io, gpa, args);
    } else if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printUsage();
        return 0;
    } else {
        std.debug.print("error: unknown command '{s}'\n\n", .{command});
        printUsage();
        return 1;
    }
}

fn printUsage() void {
    std.debug.print(
        \\Usage: update_tool <command> [options]
        \\
        \\Commands:
        \\  keygen       Generate an Ed25519 keypair for update signing
        \\  sign-update  Sign an update artifact and generate a manifest JSON
        \\
        \\Run 'update_tool <command> --help' for command-specific options.
        \\
    , .{});
}

pub const KeygenOptions = struct {
    name: []const u8 = "oriel",
    key_path: ?[]const u8 = null,
    pub_path: ?[]const u8 = null,
    out_dir: ?[]const u8 = null,
    force: bool = false,
    /// Don't print where the keys went (library/test use).
    quiet: bool = false,
};

pub fn runKeygen(
    io: std.Io,
    gpa: std.mem.Allocator,
    env_map: ?*const std.process.Environ.Map,
    opts: KeygenOptions,
) !void {
    // Determine target directory and key paths
    const key_dir = if (opts.out_dir) |dir|
        dir
    else if (opts.key_path) |kp|
        std.fs.path.dirname(kp) orelse "."
    else
        try defaultKeysDir(gpa, env_map);

    const key_name = try std.fmt.allocPrint(gpa, "{s}.key", .{opts.name});
    defer gpa.free(key_name);
    const key_path = if (opts.key_path) |kp|
        try gpa.dupe(u8, kp)
    else
        try std.fs.path.join(gpa, &.{ key_dir, key_name });
    defer gpa.free(key_path);

    const pub_name = try std.fmt.allocPrint(gpa, "{s}.pub", .{opts.name});
    defer gpa.free(pub_name);
    const pub_path = if (opts.pub_path) |pp|
        try gpa.dupe(u8, pp)
    else
        try std.fs.path.join(gpa, &.{ key_dir, pub_name });
    defer gpa.free(pub_path);

    // Refuse to overwrite private key without force
    if (!opts.force and pathExists(io, key_path)) {
        return error.KeyAlreadyExists;
    }

    // Ensure directory exists
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, key_dir);

    // Generate random 32-byte seed for Ed25519
    var seed: [Ed25519.KeyPair.seed_length]u8 = undefined;
    io.random(&seed);
    const key_pair = try Ed25519.KeyPair.generateDeterministic(seed);

    // Encode seed to base64
    var sk_b64: [manifest_mod.PRIVATE_KEY_SEED_B64_LEN]u8 = undefined;
    _ = manifest_mod.encodePrivateKeySeed(seed, &sk_b64);

    // Write private key file (mode 0600). With --force the old file is
    // removed first, so the new one is always created with mode 0600
    // (the mode only applies at creation); `exclusive` closes the race
    // between the existence check above and this create.
    if (opts.force) cwd.deleteFile(io, key_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    const key_file = cwd.createFile(io, key_path, .{
        .permissions = std.Io.File.Permissions.fromMode(0o600),
        .exclusive = true,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => return error.KeyAlreadyExists,
        else => return err,
    };
    defer key_file.close(io);

    var key_writer_buf: [256]u8 = undefined;
    var key_writer = key_file.writerStreaming(io, &key_writer_buf);
    try key_writer.interface.writeAll(&sk_b64);
    try key_writer.interface.writeAll("\n");
    try key_writer.interface.flush();
    try key_file.sync(io);

    // Write public key file (mode 0644)
    var pk_b64: [manifest_mod.PUBLIC_KEY_B64_LEN]u8 = undefined;
    _ = manifest_mod.encodePublicKey(key_pair.public_key.toBytes(), &pk_b64);

    const pub_file = try cwd.createFile(io, pub_path, .{
        .permissions = std.Io.File.Permissions.fromMode(0o644),
    });
    defer pub_file.close(io);

    var pub_writer_buf: [256]u8 = undefined;
    var pub_writer = pub_file.writerStreaming(io, &pub_writer_buf);
    try pub_writer.interface.writeAll(&pk_b64);
    try pub_writer.interface.writeAll("\n");
    try pub_writer.interface.flush();
    try pub_file.sync(io);

    if (!opts.quiet) std.debug.print(
        \\Private key written to: {s} (mode 0600)
        \\Public key written to:  {s}
        \\Public key (base64): {s}
        \\
    , .{ key_path, pub_path, pk_b64 });
}

fn handleKeygen(io: std.Io, gpa: std.mem.Allocator, env_map: *std.process.Environ.Map, args: []const [*:0]const u8) !u8 {
    var opts = KeygenOptions{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = std.mem.span(args[i]);
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print(
                \\Usage: update_tool keygen [options]
                \\
                \\Options:
                \\  --name <name>      Key name (default: oriel)
                \\  --key <path>       Direct path for the private key file
                \\  --pub <path>       Direct path for the public key file
                \\  --out-dir <path>   Directory to write keys to
                \\  --force            Overwrite existing private key if it exists
                \\
            , .{});
            return 0;
        } else if (std.mem.eql(u8, arg, "--name")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --name requires a value\n", .{});
                return 1;
            }
            opts.name = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--key")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --key requires a path\n", .{});
                return 1;
            }
            opts.key_path = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--pub")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --pub requires a path\n", .{});
                return 1;
            }
            opts.pub_path = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--out-dir")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --out-dir requires a path\n", .{});
                return 1;
            }
            opts.out_dir = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--force")) {
            opts.force = true;
        } else {
            std.debug.print("error: unrecognized option '{s}'\n", .{arg});
            return 1;
        }
    }

    runKeygen(io, gpa, env_map, opts) catch |err| switch (err) {
        error.KeyAlreadyExists => {
            std.debug.print("error: private key file already exists. Use --force to overwrite.\n", .{});
            return 1;
        },
        else => |e| {
            std.debug.print("error: keygen failed: {s}\n", .{@errorName(e)});
            return 1;
        },
    };
    return 0;
}

pub const SignOptions = struct {
    artifact_path: []const u8,
    version: []const u8,
    url: []const u8,
    key_path: []const u8,
    out_path: ?[]const u8 = null,
};

pub fn runSignUpdate(
    io: std.Io,
    gpa: std.mem.Allocator,
    opts: SignOptions,
) ![]u8 {
    const cwd = std.Io.Dir.cwd();

    // Read artifact and compute SHA-256
    const art_file = try cwd.openFile(io, opts.artifact_path, .{});
    defer art_file.close(io);

    var sha = Sha256.init(.{});
    var read_buf: [65536]u8 = undefined;
    var art_reader = art_file.readerStreaming(io, &read_buf);
    var chunk: [32768]u8 = undefined;
    while (true) {
        const n = try art_reader.interface.readSliceShort(&chunk);
        if (n == 0) break;
        sha.update(chunk[0..n]);
    }
    var digest: [32]u8 = undefined;
    sha.final(&digest);
    const sha256_hex = std.fmt.bytesToHex(digest, .lower);

    // Read and parse private key (base64-encoded 32-byte seed)
    const key_bytes = try cwd.readFileAlloc(io, opts.key_path, gpa, .limited(4096));
    defer gpa.free(key_bytes);

    const kp = try manifest_mod.keyPairFromSeedB64(key_bytes);

    // Normalize version: strip leading 'v' or 'V' if present
    var clean_ver = opts.version;
    if (std.mem.startsWith(u8, clean_ver, "v") or std.mem.startsWith(u8, clean_ver, "V")) {
        clean_ver = clean_ver[1..];
    }

    // Sign canonical domain-separated data using update_manifest
    const sig_b64 = try manifest_mod.sign(gpa, kp, clean_ver, opts.url, &sha256_hex);
    defer gpa.free(sig_b64);

    const manifest_json = try manifest_mod.formatManifest(gpa, clean_ver, opts.url, &sha256_hex, sig_b64);

    if (opts.out_path) |out| {
        try cwd.writeFile(io, .{ .sub_path = out, .data = manifest_json });
    }

    return manifest_json;
}

fn handleSignUpdate(io: std.Io, gpa: std.mem.Allocator, args: []const [*:0]const u8) !u8 {
    var artifact: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    var url: ?[]const u8 = null;
    var key_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = std.mem.span(args[i]);
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print(
                \\Usage: update_tool sign-update <artifact> --version <X.Y.Z> --url <url> --key <private-key-file> [options]
                \\
                \\Options:
                \\  --version <ver>    Release semver (e.g. 1.0.0 or v1.0.0)
                \\  --url <url>        Download URL for the artifact
                \\  --key <file>       Path to private key file (.key)
                \\  --artifact <file>  Path to artifact (if not provided positionally)
                \\  --out <file>       Output path for manifest JSON (optional)
                \\
            , .{});
            return 0;
        } else if (std.mem.eql(u8, arg, "--version")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --version requires a value\n", .{});
                return 1;
            }
            version = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--url")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --url requires a value\n", .{});
                return 1;
            }
            url = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--key")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --key requires a path\n", .{});
                return 1;
            }
            key_path = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--artifact")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --artifact requires a path\n", .{});
                return 1;
            }
            artifact = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--out")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --out requires a path\n", .{});
                return 1;
            }
            out_path = std.mem.span(args[i]);
        } else if (!std.mem.startsWith(u8, arg, "--") and artifact == null) {
            artifact = arg;
        } else {
            std.debug.print("error: unrecognized option '{s}'\n", .{arg});
            return 1;
        }
    }

    if (artifact == null or version == null or url == null or key_path == null) {
        std.debug.print("error: missing required arguments\nUsage: update_tool sign-update <artifact> --version <X.Y.Z> --url <url> --key <key-file>\n", .{});
        return 1;
    }

    const manifest_json = runSignUpdate(io, gpa, .{
        .artifact_path = artifact.?,
        .version = version.?,
        .url = url.?,
        .key_path = key_path.?,
        .out_path = out_path,
    }) catch |err| {
        std.debug.print("error: sign-update failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer gpa.free(manifest_json);

    // Output manifest JSON to stdout
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    try stdout.interface.writeAll(manifest_json);
    try stdout.interface.writeAll("\n");
    try stdout.interface.flush();

    return 0;
}

fn defaultKeysDir(gpa: std.mem.Allocator, env_map: ?*const std.process.Environ.Map) ![]const u8 {
    if (env_map) |m| {
        if (m.get("XDG_CONFIG_HOME")) |xdg| {
            if (xdg.len > 0) return std.fs.path.join(gpa, &.{ xdg, "oriel", "keys" });
        }
        if (m.get("HOME")) |home| {
            if (home.len > 0) return std.fs.path.join(gpa, &.{ home, ".config", "oriel", "keys" });
        }
    }
    return std.fs.path.join(gpa, &.{ ".oriel", "keys" });
}

fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

// ---------------------------------------------------------------------------
// Unit Tests for update_tool
// ---------------------------------------------------------------------------

test "keygen writes 0600 key and refuses to overwrite" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    const keys_dir = try std.fs.path.join(allocator, &.{ tmp_path, "keys" });
    defer allocator.free(keys_dir);

    // 1. Initial keygen succeeds
    try runKeygen(io, allocator, null, .{
        .quiet = true,
        .name = "testapp",
        .out_dir = keys_dir,
    });

    const key_path = try std.fs.path.join(allocator, &.{ keys_dir, "testapp.key" });
    defer allocator.free(key_path);
    const pub_path = try std.fs.path.join(allocator, &.{ keys_dir, "testapp.pub" });
    defer allocator.free(pub_path);

    // Check mode is 0600
    {
        const f = try std.Io.Dir.cwd().openFile(io, key_path, .{});
        defer f.close(io);
        const st = try f.stat(io);
        try std.testing.expectEqual(@as(u32, 0o600), st.permissions.toMode() & 0o777);
    }

    // Check private key contents can be parsed as base64 seed
    const key_content = try std.Io.Dir.cwd().readFileAlloc(io, key_path, allocator, .limited(1024));
    defer allocator.free(key_content);
    const seed = try manifest_mod.parsePrivateKeySeed(key_content);
    const kp = try Ed25519.KeyPair.generateDeterministic(seed);

    // Check public key file matches
    const pub_content = try std.Io.Dir.cwd().readFileAlloc(io, pub_path, allocator, .limited(1024));
    defer allocator.free(pub_content);
    const pub_bytes = try manifest_mod.parsePublicKey(pub_content);
    try std.testing.expectEqualSlices(u8, &kp.public_key.toBytes(), &pub_bytes);

    // 2. Running keygen again without force is refused
    const res = runKeygen(io, allocator, null, .{
        .quiet = true,
        .name = "testapp",
        .out_dir = keys_dir,
    });
    try std.testing.expectError(error.KeyAlreadyExists, res);
}

test "sign-update output verifies with update_manifest.verify" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    // Generate keys
    const keys_dir = try std.fs.path.join(allocator, &.{ tmp_path, "keys" });
    defer allocator.free(keys_dir);

    try runKeygen(io, allocator, null, .{
        .quiet = true,
        .name = "sign_test",
        .out_dir = keys_dir,
    });

    const key_path = try std.fs.path.join(allocator, &.{ keys_dir, "sign_test.key" });
    defer allocator.free(key_path);
    const pub_path = try std.fs.path.join(allocator, &.{ keys_dir, "sign_test.pub" });
    defer allocator.free(pub_path);

    // Create a dummy artifact file
    const artifact_path = try std.fs.path.join(allocator, &.{ tmp_path, "app.bin" });
    defer allocator.free(artifact_path);

    const artifact_content = "binary payload content for update signing";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = artifact_path, .data = artifact_content });

    const manifest_path = try std.fs.path.join(allocator, &.{ tmp_path, "manifest.json" });
    defer allocator.free(manifest_path);

    // Run sign-update
    const manifest_json = try runSignUpdate(io, allocator, .{
        .artifact_path = artifact_path,
        .version = "v1.2.3",
        .url = "https://example.com/downloads/app.bin",
        .key_path = key_path,
        .out_path = manifest_path,
    });
    defer allocator.free(manifest_json);

    // Read public key base64
    const pub_content = try std.Io.Dir.cwd().readFileAlloc(io, pub_path, allocator, .limited(1024));
    defer allocator.free(pub_content);

    // Verify with update_manifest.verify
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const verified = try manifest_mod.verify(arena.allocator(), manifest_json, pub_content);
    try std.testing.expectEqualStrings("1.2.3", verified.version); // stripped 'v'
    try std.testing.expectEqualStrings("https://example.com/downloads/app.bin", verified.url);

    // Verify sha256 matches actual hash of artifact
    var sha = Sha256.init(.{});
    sha.update(artifact_content);
    var digest: [32]u8 = undefined;
    sha.final(&digest);
    const expected_sha256 = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings(&expected_sha256, verified.sha256);

    // Verify the file written to disk matches returned JSON
    const written_manifest = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(4096));
    defer allocator.free(written_manifest);
    try std.testing.expectEqualStrings(manifest_json, written_manifest);
}
