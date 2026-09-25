//! Host CLI tool for Oriel update management:
//! - keygen: Generate an Ed25519 keypair for signing updates (base64 private key seed, base64 public key).
//! - sign-update: Hash an artifact, sign domain-separated bytes, and produce a manifest JSON.
//! - combine-manifests: Merge per-platform manifests into one `latest.json`.

const std = @import("std");
const builtin = @import("builtin");
const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;
const manifest_mod = @import("update_manifest");

pub const DEFAULT_TARGET = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag);

/// This process's id, to make temp file names unique.
fn processId() u64 {
    return switch (builtin.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        .linux => @intCast(std.os.linux.getpid()),
        else => @intCast(std.c.getpid()), // raw Linux syscalls are SIGSYS on macOS
    };
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    // Portable argv (WTF-16 on Windows, so not `args.vector`).
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    if (argv.len < 2) {
        printUsage();
        return 1;
    }

    const command = argv[1];
    const args = argv[2..];

    if (std.mem.eql(u8, command, "keygen")) {
        return handleKeygen(io, gpa, init.environ_map, args);
    } else if (std.mem.eql(u8, command, "sign-update")) {
        return handleSignUpdate(io, gpa, args);
    } else if (std.mem.eql(u8, command, "combine-manifests")) {
        return handleCombine(io, gpa, args);
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
        \\  combine-manifests  Merge per-platform manifests into one latest.json
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
    const cwd = std.Io.Dir.cwd();

    // Determine target directory and key paths
    const allocated_key_dir: ?[]const u8 = if (opts.out_dir == null and opts.key_path == null)
        try defaultKeysDir(gpa, env_map)
    else
        null;
    defer if (allocated_key_dir) |d| gpa.free(d);

    const key_dir = opts.out_dir orelse (if (opts.key_path) |kp| std.fs.path.dirname(kp) orelse "." else allocated_key_dir.?);

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

    // Detect and report half-written/corrupt existing key vs valid key
    if (pathExists(io, key_path)) {
        var is_corrupt = false;
        if (cwd.readFileAlloc(io, key_path, gpa, .limited(4096))) |bytes| {
            defer {
                std.crypto.secureZero(u8, bytes);
                gpa.free(bytes);
            }
            _ = manifest_mod.keyPairFromSeedB64(bytes) catch {
                is_corrupt = true;
            };
        } else |_| {
            is_corrupt = true;
        }

        if (!opts.force) {
            if (is_corrupt) {
                return error.CorruptExistingKey;
            } else {
                return error.KeyAlreadyExists;
            }
        }
    }

    // Ensure directory exists with mode 0700 (POSIX only: Windows has no modes,
    // the user profile's ACLs protect it, and Zig 0.16 panics on
    // dirSetFilePermissions there).
    try cwd.createDirPath(io, key_dir);
    if (builtin.os.tag != .windows) try cwd.setFilePermissions(io, key_dir, filePerms(0o700), .{});

    // Generate random 32-byte seed for Ed25519
    var seed: [Ed25519.KeyPair.seed_length]u8 = undefined;
    defer std.crypto.secureZero(u8, &seed);
    io.random(&seed);

    var key_pair = try Ed25519.KeyPair.generateDeterministic(seed);
    defer std.crypto.secureZero(u8, &key_pair.secret_key.bytes);

    // Encode seed to base64
    var sk_b64: [manifest_mod.PRIVATE_KEY_SEED_B64_LEN]u8 = undefined;
    defer std.crypto.secureZero(u8, &sk_b64);
    _ = manifest_mod.encodePrivateKeySeed(seed, &sk_b64);

    // Write private key file to temporary file, then rename atomically over destination
    var rand_val: u64 = undefined;
    io.random(std.mem.asBytes(&rand_val));
    const temp_key_path = try std.fmt.allocPrint(gpa, "{s}.tmp.{d}.{x}", .{ key_path, processId(), rand_val });
    defer gpa.free(temp_key_path);

    var temp_key_file = try cwd.createFile(io, temp_key_path, .{
        .permissions = filePerms(0o600),
        .exclusive = true,
    });
    try temp_key_file.setPermissions(io, filePerms(0o600));

    var temp_key_open = true;
    var temp_key_exists = true;
    defer {
        if (temp_key_open) temp_key_file.close(io);
        if (temp_key_exists) cwd.deleteFile(io, temp_key_path) catch {};
    }

    var key_writer_buf: [256]u8 = undefined;
    var key_writer = temp_key_file.writerStreaming(io, &key_writer_buf);
    try key_writer.interface.writeAll(&sk_b64);
    try key_writer.interface.writeAll("\n");
    try key_writer.interface.flush();
    try temp_key_file.sync(io);

    temp_key_file.close(io);
    temp_key_open = false;

    // Atomically rename over target key_path
    try cwd.rename(temp_key_path, cwd, key_path, io);
    temp_key_exists = false;

    // Write public key file (mode 0644) via temp file + rename
    var pk_b64: [manifest_mod.PUBLIC_KEY_B64_LEN]u8 = undefined;
    _ = manifest_mod.encodePublicKey(key_pair.public_key.toBytes(), &pk_b64);

    const temp_pub_path = try std.fmt.allocPrint(gpa, "{s}.tmp.{d}.{x}", .{ pub_path, processId(), rand_val });
    defer gpa.free(temp_pub_path);

    var temp_pub_file = try cwd.createFile(io, temp_pub_path, .{
        .permissions = filePerms(0o644),
        .exclusive = true,
    });
    try temp_pub_file.setPermissions(io, filePerms(0o644));

    var temp_pub_open = true;
    var temp_pub_exists = true;
    defer {
        if (temp_pub_open) temp_pub_file.close(io);
        if (temp_pub_exists) cwd.deleteFile(io, temp_pub_path) catch {};
    }

    var pub_writer_buf: [256]u8 = undefined;
    var pub_writer = temp_pub_file.writerStreaming(io, &pub_writer_buf);
    try pub_writer.interface.writeAll(&pk_b64);
    try pub_writer.interface.writeAll("\n");
    try pub_writer.interface.flush();
    try temp_pub_file.sync(io);

    temp_pub_file.close(io);
    temp_pub_open = false;

    try cwd.rename(temp_pub_path, cwd, pub_path, io);
    temp_pub_exists = false;

    if (!opts.quiet) std.debug.print(
        \\Private key written to: {s} (mode 0600)
        \\Public key written to:  {s}
        \\Public key (base64): {s}
        \\
    , .{ key_path, pub_path, pk_b64 });
}

fn handleKeygen(io: std.Io, gpa: std.mem.Allocator, env_map: *std.process.Environ.Map, args: []const [:0]const u8) !u8 {
    var opts = KeygenOptions{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
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
            opts.name = args[i];
        } else if (std.mem.eql(u8, arg, "--key")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --key requires a path\n", .{});
                return 1;
            }
            opts.key_path = args[i];
        } else if (std.mem.eql(u8, arg, "--pub")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --pub requires a path\n", .{});
                return 1;
            }
            opts.pub_path = args[i];
        } else if (std.mem.eql(u8, arg, "--out-dir")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --out-dir requires a path\n", .{});
                return 1;
            }
            opts.out_dir = args[i];
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
        error.CorruptExistingKey => {
            std.debug.print("error: existing private key file is corrupt or incomplete. Use --force to replace it.\n", .{});
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
    app_id: []const u8,
    version: []const u8,
    url: []const u8,
    key_path: []const u8,
    target: ?[]const u8 = null,
    format: ?[]const u8 = null,
    size: ?u64 = null,
    expires: ?u64 = null,
    out_path: ?[]const u8 = null,
    allow_test_http: bool = false,
};

pub fn runSignUpdate(
    io: std.Io,
    gpa: std.mem.Allocator,
    opts: SignOptions,
) ![]u8 {
    const cwd = std.Io.Dir.cwd();

    // Read artifact, count size, and compute SHA-256
    const art_file = try cwd.openFile(io, opts.artifact_path, .{});
    defer art_file.close(io);

    var sha = Sha256.init(.{});
    var read_buf: [65536]u8 = undefined;
    var art_reader = art_file.readerStreaming(io, &read_buf);
    var chunk: [32768]u8 = undefined;
    var computed_size: u64 = 0;
    while (true) {
        const n = try art_reader.interface.readSliceShort(&chunk);
        if (n == 0) break;
        sha.update(chunk[0..n]);
        computed_size += n;
    }
    var digest: [32]u8 = undefined;
    sha.final(&digest);
    const sha256_hex = std.fmt.bytesToHex(digest, .lower);

    // The signed size must be the artifact's real size, or no client could verify it.
    if (opts.size) |s| if (s != computed_size) return error.SizeMismatch;
    const final_size = computed_size;
    const final_target = opts.target orelse DEFAULT_TARGET;
    const final_format = opts.format orelse blk: {
        if (std.mem.endsWith(u8, opts.artifact_path, ".AppImage") or std.mem.endsWith(u8, opts.artifact_path, ".appimage")) {
            break :blk "appimage";
        }
        if (std.mem.endsWith(u8, opts.artifact_path, ".gz")) {
            break :blk "raw.gz";
        }
        break :blk "raw";
    };

    // Read and parse private key (base64-encoded 32-byte seed) with secure wipe
    const key_bytes = try cwd.readFileAlloc(io, opts.key_path, gpa, .limited(4096));
    defer {
        std.crypto.secureZero(u8, key_bytes);
        gpa.free(key_bytes);
    }

    var kp = try manifest_mod.keyPairFromSeedB64(key_bytes);
    defer std.crypto.secureZero(u8, &kp.secret_key.bytes);

    // Normalize version: strip leading 'v' or 'V' if present
    var clean_ver = opts.version;
    if (std.mem.startsWith(u8, clean_ver, "v") or std.mem.startsWith(u8, clean_ver, "V")) {
        clean_ver = clean_ver[1..];
    }

    const sign_params = manifest_mod.SignParameters{
        .app_id = opts.app_id,
        .version = clean_ver,
        .target = final_target,
        .format = final_format,
        .size = final_size,
        .sha256 = &sha256_hex,
        .url = opts.url,
        .expires = opts.expires,
        .allow_test_http = opts.allow_test_http,
    };

    const sig_b64 = try manifest_mod.sign(gpa, kp, sign_params);
    defer gpa.free(sig_b64);

    const manifest_json = try manifest_mod.formatManifest(gpa, sign_params, sig_b64);
    errdefer gpa.free(manifest_json);

    if (opts.out_path) |out| {
        try cwd.writeFile(io, .{ .sub_path = out, .data = manifest_json });
    }

    return manifest_json;
}

fn handleSignUpdate(io: std.Io, gpa: std.mem.Allocator, args: []const [:0]const u8) !u8 {
    var artifact: ?[]const u8 = null;
    var app_id: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    var url: ?[]const u8 = null;
    var key_path: ?[]const u8 = null;
    var target: ?[]const u8 = null;
    var format: ?[]const u8 = null;
    var size: ?u64 = null;
    var expires: ?u64 = null;
    var out_path: ?[]const u8 = null;
    var allow_test_http: bool = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print(
                \\Usage: update_tool sign-update <artifact> --app-id <id> --version <X.Y.Z> --url <url> --key <key-file> [options]
                \\
                \\Required:
                \\  --app-id <id>      Application identifier (e.g. com.example.app)
                \\  --version <ver>    Release semver (e.g. 1.0.0 or v1.0.0)
                \\  --url <url>        Download URL (must start with https://)
                \\  --key <file>       Path to private key file (.key)
                \\
                \\Options:
                \\  --target <target>  Target architecture + OS (default: host target)
                \\  --format <fmt>     Update payload format (raw, raw.gz, appimage, appimage.gz, app.tar.gz)
                \\  --size <bytes>     Payload size in bytes (default: computed from artifact)
                \\  --expires <sec>    Expiration timestamp in unix seconds
                \\  --artifact <file>  Path to artifact (if not provided positionally)
                \\  --out <file>       Output path for manifest JSON (optional)
                \\
            , .{});
            return 0;
        } else if (std.mem.eql(u8, arg, "--app-id")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --app-id requires a value\n", .{});
                return 1;
            }
            app_id = args[i];
        } else if (std.mem.eql(u8, arg, "--version")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --version requires a value\n", .{});
                return 1;
            }
            version = args[i];
        } else if (std.mem.eql(u8, arg, "--url")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --url requires a value\n", .{});
                return 1;
            }
            url = args[i];
        } else if (std.mem.eql(u8, arg, "--key")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --key requires a path\n", .{});
                return 1;
            }
            key_path = args[i];
        } else if (std.mem.eql(u8, arg, "--target")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --target requires a value\n", .{});
                return 1;
            }
            target = args[i];
        } else if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --format requires a value\n", .{});
                return 1;
            }
            format = args[i];
        } else if (std.mem.eql(u8, arg, "--size")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --size requires a value\n", .{});
                return 1;
            }
            size = std.fmt.parseInt(u64, args[i], 10) catch {
                std.debug.print("error: invalid integer for --size\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--expires")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --expires requires a value\n", .{});
                return 1;
            }
            expires = std.fmt.parseInt(u64, args[i], 10) catch {
                std.debug.print("error: invalid integer for --expires\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--artifact")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --artifact requires a path\n", .{});
                return 1;
            }
            artifact = args[i];
        } else if (std.mem.eql(u8, arg, "--allow-test-http")) {
            allow_test_http = true;
        } else if (std.mem.eql(u8, arg, "--out")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --out requires a path\n", .{});
                return 1;
            }
            out_path = args[i];
        } else if (!std.mem.startsWith(u8, arg, "--") and artifact == null) {
            artifact = arg;
        } else {
            std.debug.print("error: unrecognized option '{s}'\n", .{arg});
            return 1;
        }
    }

    if (artifact == null or app_id == null or version == null or url == null or key_path == null) {
        std.debug.print("error: missing required arguments\nUsage: update_tool sign-update <artifact> --app-id <id> --version <X.Y.Z> --url <url> --key <key-file>\n", .{});
        return 1;
    }

    const manifest_json = runSignUpdate(io, gpa, .{
        .artifact_path = artifact.?,
        .app_id = app_id.?,
        .version = version.?,
        .url = url.?,
        .key_path = key_path.?,
        .target = target,
        .format = format,
        .size = size,
        .expires = expires,
        .out_path = out_path,
        .allow_test_http = allow_test_http,
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

pub const CombineFilesOptions = struct {
    inputs: []const []const u8,
    out_path: []const u8,
    pub_date: ?[]const u8 = null,
    notes: ?[]const u8 = null,
    allow_test_http: bool = false,
};

/// Read the per-platform manifests and write the combined one to `out_path`.
pub fn runCombine(io: std.Io, gpa: std.mem.Allocator, opts: CombineFilesOptions) !void {
    const cwd = std.Io.Dir.cwd();
    const contents = try gpa.alloc([]const u8, opts.inputs.len);
    var read: usize = 0;
    defer {
        for (contents[0..read]) |c| gpa.free(c);
        gpa.free(contents);
    }
    for (opts.inputs) |path| {
        contents[read] = try cwd.readFileAlloc(io, path, gpa, .limited(64 * 1024));
        read += 1;
    }
    const combined = try manifest_mod.combine(gpa, contents, .{
        .pub_date = opts.pub_date,
        .notes = opts.notes,
        .allow_test_http = opts.allow_test_http,
    });
    defer gpa.free(combined);
    try cwd.writeFile(io, .{ .sub_path = opts.out_path, .data = combined });
}

fn handleCombine(io: std.Io, gpa: std.mem.Allocator, args: []const [:0]const u8) !u8 {
    var inputs: std.ArrayList([]const u8) = .empty;
    defer inputs.deinit(gpa);
    var out_path: ?[]const u8 = null;
    var pub_date: ?[]const u8 = null;
    var notes: ?[]const u8 = null;
    var allow_test_http = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print(
                \\Usage: update_tool combine-manifests <manifest.json>... --out <latest.json> [options]
                \\
                \\Merges manifests made by sign-update (same app id and version, one per
                \\target) into one file clients on every platform can fetch.
                \\
                \\Options:
                \\  --out <file>       Output path (required)
                \\  --pub-date <date>  Publication date (RFC 3339), informational
                \\  --notes <text>     Release notes, informational
                \\
            , .{});
            return 0;
        } else if (std.mem.eql(u8, arg, "--out") or std.mem.eql(u8, arg, "--pub-date") or std.mem.eql(u8, arg, "--notes")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: {s} requires a value\n", .{arg});
                return 1;
            }
            if (std.mem.eql(u8, arg, "--out")) out_path = args[i] else if (std.mem.eql(u8, arg, "--pub-date")) pub_date = args[i] else notes = args[i];
        } else if (std.mem.eql(u8, arg, "--allow-test-http")) {
            allow_test_http = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            std.debug.print("error: unrecognized option '{s}'\n", .{arg});
            return 1;
        } else {
            try inputs.append(gpa, arg);
        }
    }
    if (out_path == null or inputs.items.len == 0) {
        std.debug.print("error: missing arguments\nUsage: update_tool combine-manifests <manifest.json>... --out <latest.json>\n", .{});
        return 1;
    }
    runCombine(io, gpa, .{
        .inputs = inputs.items,
        .out_path = out_path.?,
        .pub_date = pub_date,
        .notes = notes,
        .allow_test_http = allow_test_http,
    }) catch |err| {
        std.debug.print("error: combine-manifests failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    std.debug.print("Wrote {s} ({d} platforms)\n", .{ out_path.?, inputs.items.len });
    return 0;
}

fn defaultKeysDir(gpa: std.mem.Allocator, env_map: ?*const std.process.Environ.Map) ![]const u8 {
    if (env_map) |m| {
        if (m.get("XDG_CONFIG_HOME")) |xdg| {
            // XDG spec: empty or relative values are ignored.
            if (std.fs.path.isAbsolute(xdg)) return std.fs.path.join(gpa, &.{ xdg, "oriel", "keys" });
        }
        if (m.get("HOME")) |home| {
            if (std.fs.path.isAbsolute(home)) return std.fs.path.join(gpa, &.{ home, ".config", "oriel", "keys" });
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

test "keygen writes 0600 key, 0700 dir, and refuses to overwrite" {
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

    // Check key mode is 0600 (POSIX only: Windows has attributes, not modes)
    if (builtin.os.tag != .windows) {
        const f = try std.Io.Dir.cwd().openFile(io, key_path, .{});
        defer f.close(io);
        const st = try f.stat(io);
        try std.testing.expectEqual(@as(u32, 0o600), st.permissions.toMode() & 0o777);
    }

    // Check directory mode is 0700
    if (builtin.os.tag != .windows) {
        const d = try std.Io.Dir.cwd().openDir(io, keys_dir, .{});
        defer d.close(io);
        const st = try d.stat(io);
        try std.testing.expectEqual(@as(u32, 0o700), st.permissions.toMode() & 0o777);
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

    // 3. Running keygen with --force overwrites without deleting first
    try runKeygen(io, allocator, null, .{
        .quiet = true,
        .name = "testapp",
        .out_dir = keys_dir,
        .force = true,
    });
}

test "keygen detects corrupt existing key and requires --force" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    const keys_dir = try std.fs.path.join(allocator, &.{ tmp_path, "corrupt_keys" });
    defer allocator.free(keys_dir);
    try std.Io.Dir.cwd().createDirPath(io, keys_dir);

    const corrupt_key_path = try std.fs.path.join(allocator, &.{ keys_dir, "bad.key" });
    defer allocator.free(corrupt_key_path);

    // Write a half-written / corrupt key file
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = corrupt_key_path, .data = "half-written-bad-seed\n" });

    // Refuses without force, detecting corruption
    const err = runKeygen(io, allocator, null, .{
        .quiet = true,
        .name = "bad",
        .out_dir = keys_dir,
    });
    try std.testing.expectError(error.CorruptExistingKey, err);

    // With --force, succeeds and replaces it
    try runKeygen(io, allocator, null, .{
        .quiet = true,
        .name = "bad",
        .out_dir = keys_dir,
        .force = true,
    });
}

test "keygen with fake env map HOME frees defaultKeysDir with std.testing.allocator" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", tmp_path);

    // Run keygen without explicit out_dir or key_path to exercise defaultKeysDir
    try runKeygen(io, allocator, &env_map, .{
        .quiet = true,
        .name = "envtest",
    });

    const expected_key = try std.fs.path.join(allocator, &.{ tmp_path, ".config", "oriel", "keys", "envtest.key" });
    defer allocator.free(expected_key);
    try std.testing.expect(pathExists(io, expected_key));
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
        .app_id = "dev.oriel.signtest",
        .version = "v1.2.3",
        .url = "https://example.com/downloads/app.bin",
        .key_path = key_path,
        .format = "raw",
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
    try std.testing.expectEqualStrings("dev.oriel.signtest", verified.app_id);
    try std.testing.expectEqualStrings("1.2.3", verified.version); // stripped 'v'
    try std.testing.expectEqualStrings("https://example.com/downloads/app.bin", verified.url);
    try std.testing.expectEqualStrings("raw", verified.format);
    try std.testing.expectEqual(@as(u64, artifact_content.len), verified.size);

    // Verify sha256 matches actual hash of artifact
    var sha = Sha256.init(.{});
    sha.update(artifact_content);
    var digest: [32]u8 = undefined;
    sha.final(&digest);
    const expected_sha256 = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expect(manifest_mod.eqlSha256Hex(&expected_sha256, verified.sha256));

    // Verify the file written to disk matches returned JSON
    const written_manifest = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(4096));
    defer allocator.free(written_manifest);
    try std.testing.expectEqualStrings(manifest_json, written_manifest);
}

test "sign-update writeFile failure frees manifest_json without leak" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    const keys_dir = try std.fs.path.join(allocator, &.{ tmp_path, "keys" });
    defer allocator.free(keys_dir);

    try runKeygen(io, allocator, null, .{
        .quiet = true,
        .name = "sign_fail",
        .out_dir = keys_dir,
    });

    const key_path = try std.fs.path.join(allocator, &.{ keys_dir, "sign_fail.key" });
    defer allocator.free(key_path);

    const artifact_path = try std.fs.path.join(allocator, &.{ tmp_path, "app.bin" });
    defer allocator.free(artifact_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = artifact_path, .data = "payload" });

    // Try to write to a non-existent directory path which causes writeFile to fail
    const impossible_out = try std.fs.path.join(allocator, &.{ tmp_path, "no_such_dir", "manifest.json" });
    defer allocator.free(impossible_out);

    const err = runSignUpdate(io, allocator, .{
        .artifact_path = artifact_path,
        .app_id = "dev.oriel.fail",
        .version = "1.0.0",
        .url = "https://example.com/app",
        .key_path = key_path,
        .out_path = impossible_out,
    });
    try std.testing.expectError(error.FileNotFound, err);
}

/// POSIX mode on Linux/macOS; Windows has attributes instead of modes (and
/// `@enumFromInt(0o755)` there would set read-only/system/... attribute bits).
fn filePerms(mode: u32) std.Io.File.Permissions {
    return if (builtin.os.tag == .windows) .default_file else .fromMode(@intCast(mode));
}

test "combine-manifests writes a latest.json every target verifies" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    const keys_dir = try std.fs.path.join(allocator, &.{ tmp_path, "keys" });
    defer allocator.free(keys_dir);
    try runKeygen(io, allocator, null, .{ .quiet = true, .name = "combine_test", .out_dir = keys_dir });
    const key_path = try std.fs.path.join(allocator, &.{ keys_dir, "combine_test.key" });
    defer allocator.free(key_path);
    const pub_path = try std.fs.path.join(allocator, &.{ keys_dir, "combine_test.pub" });
    defer allocator.free(pub_path);

    const artifact_path = try std.fs.path.join(allocator, &.{ tmp_path, "app.bin" });
    defer allocator.free(artifact_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = artifact_path, .data = "payload" });

    const targets = [_][]const u8{ "x86_64-linux", "aarch64-macos", "x86_64-windows" };
    var paths: [targets.len][]const u8 = undefined;
    var made: usize = 0;
    defer for (paths[0..made]) |p| allocator.free(p);
    for (targets) |t| {
        const name = try std.fmt.allocPrint(allocator, "m-{s}.json", .{t});
        defer allocator.free(name);
        paths[made] = try std.fs.path.join(allocator, &.{ tmp_path, name });
        made += 1;
        const url = try std.fmt.allocPrint(allocator, "https://example.com/{s}", .{t});
        defer allocator.free(url);
        const json = try runSignUpdate(io, allocator, .{
            .artifact_path = artifact_path,
            .app_id = "dev.oriel.combinetest",
            .version = "2.0.0",
            .url = url,
            .key_path = key_path,
            .target = t,
            .format = "raw",
            .out_path = paths[made - 1],
        });
        allocator.free(json);
    }

    const latest_path = try std.fs.path.join(allocator, &.{ tmp_path, "latest.json" });
    defer allocator.free(latest_path);
    try runCombine(io, allocator, .{ .inputs = &paths, .out_path = latest_path, .notes = "hello" });

    const latest = try std.Io.Dir.cwd().readFileAlloc(io, latest_path, allocator, .limited(64 * 1024));
    defer allocator.free(latest);
    const pub_content = try std.Io.Dir.cwd().readFileAlloc(io, pub_path, allocator, .limited(1024));
    defer allocator.free(pub_content);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for (targets) |t| {
        const m = try manifest_mod.verifyForTarget(arena.allocator(), latest, pub_content, t, .{});
        try std.testing.expectEqualStrings(t, m.target);
        try std.testing.expect(std.mem.endsWith(u8, m.url, t));
    }
}
