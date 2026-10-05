//! MSIX packages (`oriel package`, format `.msix`), written without the
//! Windows SDK (so they build on Linux CI too): a ZIP of the payload plus
//! AppxManifest.xml, AppxBlockMap.xml (a SHA-256 per 64 KiB block of each
//! file) and [Content_Types].xml. Files are stored, not deflated (the block
//! map then needs no per-block compressed sizes). Signing is signtool's
//! (it adds AppxSignature.p7x); an unsigned package carries Windows 11's
//! unsigned-publisher OID and installs only with `Add-AppxPackage
//! -AllowUnsigned` (developer and test use).
//!
//! The manifest: a full-trust desktop app (Windows.FullTrustApplication,
//! rescap:runFullTrust), capabilities from the declared permissions and
//! the app's own (`AppOptions.windows.capabilities`), and
//! for `.share_target` a Share Target plus a FileTypeAssociation whose
//! launches (`--oriel-open-with "%1"`) src/modules/share/windows.zig reads.

const std = @import("std");
const metadata = @import("metadata.zig");

// ------------------------------------------------------------- manifest

pub const Share = struct {
    /// The Share Target's description in the share sheet.
    label: []const u8,
    /// MIME types (`.share_target.types`): `*/*` takes any file and text
    /// and links; `text/plain` text and links.
    types: []const []const u8 = &.{"*/*"},
    /// ".txt" or "txt": files the Share Target takes (unless `*/*`), and
    /// "Open with" (a FileTypeAssociation).
    extensions: []const []const u8 = &.{},
};

pub const Manifest = struct {
    /// Identity Name: [A-Za-z0-9.-], 3-50 characters.
    identity_name: []const u8,
    /// Identity Publisher: the signing certificate's Subject, or
    /// `unsignedPublisher` for an unsigned package.
    publisher: []const u8,
    /// Four parts ("1.2.3.0"): `packageVersion`.
    version: []const u8,
    /// x64, arm64 or x86.
    arch: []const u8,
    display_name: []const u8,
    publisher_display_name: []const u8,
    description: []const u8,
    /// The app's executable, at the package root ("app.exe").
    executable: []const u8,
    min_version: []const u8 = "10.0.17763.0",
    /// Declared permission kinds (src/core/permissions/common.zig Kind
    /// names): `capabilitiesFor` maps them.
    permissions: []const []const u8 = &.{},
    /// The app's own capabilities (`AppOptions.windows.capabilities`),
    /// merged with the permissions' (`capabilities`).
    capabilities: []const Capability = &.{},
    share: ?Share = null,
};

/// Package-relative paths of the logos the manifest names.
pub const logo_store = "Assets\\StoreLogo.png";
pub const logo_44 = "Assets\\Square44x44Logo.png";
pub const logo_150 = "Assets\\Square150x150Logo.png";

/// The OID Windows 11 accepts in an unsigned package's Publisher.
pub const unsigned_oid = "OID.2.25.311729368913984317654407730594956997722=1";

pub const Error = error{
    InvalidIdentityName,
    InvalidVersion,
    InvalidPublisher,
    InvalidExtension,
    InvalidArch,
    InvalidCapability,
    EmptyShareTarget,
    OutOfMemory,
    WriteFailed,
};

/// "CN=<name>, OID...=1": an unsigned package's Publisher.
pub fn unsignedPublisher(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    // A distinguished name's value: no characters that need DN escaping.
    for (name) |c| if (std.mem.indexOfScalar(u8, ",=+<>#;\"\\", c) != null or c < 0x20) return error.InvalidPublisher;
    return std.fmt.allocPrint(gpa, "CN={s}, {s}", .{ name, unsigned_oid });
}

/// The package version from the app's ("1.2.3" -> "1.2.3.0"): one to four
/// numeric parts, each up to 65535. Null for anything else ("1.2.3-beta").
pub fn packageVersion(buf: []u8, v: []const u8) ?[]const u8 {
    var parts: [4]u16 = .{ 0, 0, 0, 0 };
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, v, '.');
    while (it.next()) |p| {
        if (n == 4 or p.len == 0) return null;
        parts[n] = std.fmt.parseInt(u16, p, 10) catch return null;
        n += 1;
    }
    if (n == 0) return null;
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ parts[0], parts[1], parts[2], parts[3] }) catch null;
}

pub fn validIdentityName(s: []const u8) bool {
    if (s.len < 3 or s.len > 50) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '-')) return false;
    return true;
}

/// The manifest's capabilities for a declared permission kind.
pub fn capabilitiesFor(kind: []const u8) []const Capability {
    const table = [_]struct { []const u8, []const Capability }{
        .{ "bluetooth", &.{.{ .kind = .device, .name = "bluetooth" }} },
        .{ "local_network", &.{.{ .kind = .general, .name = "privateNetworkClientServer" }} },
        .{ "microphone", &.{.{ .kind = .device, .name = "microphone" }} },
        .{ "camera", &.{.{ .kind = .device, .name = "webcam" }} },
        .{ "location", &.{.{ .kind = .device, .name = "location" }} },
        .{ "screen_capture", &.{ .{ .kind = .restricted, .name = "graphicsCaptureProgrammatic" }, .{ .kind = .restricted, .name = "graphicsCaptureWithoutBorder" } } },
    };
    for (table) |t| if (std.mem.eql(u8, t[0], kind)) return t[1];
    return &.{};
}

pub const Capability = struct {
    kind: Kind,
    name: []const u8,
    /// The element and namespace, in the order the schema wants them:
    /// `<Capability>`, `<uap:Capability>`, `<rescap:Capability>`,
    /// `<DeviceCapability>`.
    pub const Kind = enum {
        general,
        uap,
        restricted,
        device,

        fn element(k: Kind) []const u8 {
            return switch (k) {
                .general => "Capability",
                .uap => "uap:Capability",
                .restricted => "rescap:Capability",
                .device => "DeviceCapability",
            };
        }
    };

    /// `<kind>:<name>` (the `--capability` argument).
    pub fn parse(s: []const u8) ?Capability {
        const colon = std.mem.indexOfScalar(u8, s, ':') orelse return null;
        const kind = std.meta.stringToEnum(Kind, s[0..colon]) orelse return null;
        const c: Capability = .{ .kind = kind, .name = s[colon + 1 ..] };
        return if (validCapabilityName(c.name)) c else null;
    }
};

/// A capability name: `[A-Za-z0-9._-]`, or a device interface's
/// `{GUID}`-style braces.
pub fn validCapabilityName(s: []const u8) bool {
    if (s.len == 0 or s.len > 200) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "._-{}", c) != null)) return false;
    return true;
}

/// Every capability the manifest declares, once each, in schema order:
/// internetClient and runFullTrust (always), the permissions' and then the
/// app's extras within each kind.
pub fn capabilities(gpa: std.mem.Allocator, permissions: []const []const u8, extras: []const Capability) Error![]Capability {
    for (extras) |c| if (!validCapabilityName(c.name)) return error.InvalidCapability;
    var out: std.ArrayList(Capability) = .empty;
    errdefer out.deinit(gpa);
    for (std.enums.values(Capability.Kind)) |kind| {
        if (kind == .general) try appendCapability(gpa, &out, .{ .kind = .general, .name = "internetClient" });
        if (kind == .restricted) try appendCapability(gpa, &out, .{ .kind = .restricted, .name = "runFullTrust" });
        for (permissions) |p| for (capabilitiesFor(p)) |c| if (c.kind == kind) try appendCapability(gpa, &out, c);
        for (extras) |c| if (c.kind == kind) try appendCapability(gpa, &out, c);
    }
    return out.toOwnedSlice(gpa);
}

fn appendCapability(gpa: std.mem.Allocator, list: *std.ArrayList(Capability), c: Capability) error{OutOfMemory}!void {
    for (list.items) |have| if (have.kind == c.kind and std.mem.eql(u8, have.name, c.name)) return;
    try list.append(gpa, c);
}

pub fn generateManifest(gpa: std.mem.Allocator, m: Manifest) Error![]u8 {
    if (!validIdentityName(m.identity_name)) return error.InvalidIdentityName;
    var vbuf: [32]u8 = undefined;
    if (packageVersion(&vbuf, m.version) == null or !std.mem.eql(u8, packageVersion(&vbuf, m.version).?, m.version)) return error.InvalidVersion;
    if (m.publisher.len == 0 or m.publisher.len > 8192) return error.InvalidPublisher;
    const arch_ok = for ([_][]const u8{ "x64", "arm64", "x86" }) |a| {
        if (std.mem.eql(u8, a, m.arch)) break true;
    } else false;
    if (!arch_ok) return error.InvalidArch;

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    const X = Xml.init;

    try w.writeAll(
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"
        \\  xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10"
        \\  xmlns:uap3="http://schemas.microsoft.com/appx/manifest/uap/windows10/3"
        \\  xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities"
        \\  IgnorableNamespaces="uap uap3 rescap">
        \\
    );
    try w.print("  <Identity Name=\"{f}\" Publisher=\"{f}\" Version=\"{s}\" ProcessorArchitecture=\"{s}\" />\n", .{ X(m.identity_name), X(m.publisher), m.version, m.arch });
    try w.print(
        \\  <Properties>
        \\    <DisplayName>{f}</DisplayName>
        \\    <PublisherDisplayName>{f}</PublisherDisplayName>
        \\    <Logo>{s}</Logo>
        \\  </Properties>
        \\  <Dependencies>
        \\    <TargetDeviceFamily Name="Windows.Desktop" MinVersion="{f}" MaxVersionTested="10.0.26100.0" />
        \\  </Dependencies>
        \\  <Resources>
        \\    <Resource Language="en-us" />
        \\  </Resources>
        \\  <Applications>
        \\    <Application Id="App" Executable="{f}" EntryPoint="Windows.FullTrustApplication">
        \\      <uap:VisualElements DisplayName="{f}" Description="{f}" BackgroundColor="transparent" Square150x150Logo="{s}" Square44x44Logo="{s}" />
        \\
    , .{ X(m.display_name), X(m.publisher_display_name), logo_store, X(m.min_version), X(m.executable), X(m.display_name), X(m.description), logo_150, logo_44 });

    if (m.share) |s| try writeShare(w, s);

    try w.writeAll(
        \\    </Application>
        \\  </Applications>
        \\  <Capabilities>
        \\
    );
    const caps = try capabilities(gpa, m.permissions, m.capabilities);
    defer gpa.free(caps);
    for (caps) |c| try w.print("    <{s} Name=\"{f}\" />\n", .{ c.kind.element(), X(c.name) });
    try w.writeAll(
        \\  </Capabilities>
        \\</Package>
        \\
    );
    return out.toOwnedSlice() catch error.OutOfMemory;
}

fn writeShare(w: *std.Io.Writer, s: Share) Error!void {
    var any_file = false;
    var text = false;
    for (s.types) |t| {
        if (std.mem.eql(u8, t, "*/*")) {
            any_file = true;
            text = true;
        }
        if (std.mem.eql(u8, t, "text/plain")) text = true;
    }
    var bufs: [64][40]u8 = undefined;
    if (s.extensions.len > bufs.len) return error.InvalidExtension;
    var exts: [64][]const u8 = undefined;
    for (s.extensions, 0..) |e, i| exts[i] = normalizeExtension(&bufs[i], e) orelse return error.InvalidExtension;
    const ext_list = exts[0..s.extensions.len];
    const files = any_file or ext_list.len > 0;
    if (!files and !text) return error.EmptyShareTarget;

    try w.writeAll("      <Extensions>\n");
    try w.print("        <uap:Extension Category=\"windows.shareTarget\">\n          <uap:ShareTarget Description=\"{f}\">\n", .{Xml.init(s.label)});
    if (files) {
        try w.writeAll("            <uap:SupportedFileTypes>\n");
        if (any_file) {
            try w.writeAll("              <uap:SupportsAnyFileType />\n");
        } else for (ext_list) |e| try w.print("              <uap:FileType>{s}</uap:FileType>\n", .{e});
        try w.writeAll("            </uap:SupportedFileTypes>\n");
        try w.writeAll("            <uap:DataFormat>StorageItems</uap:DataFormat>\n");
    }
    if (text) try w.writeAll("            <uap:DataFormat>Text</uap:DataFormat>\n            <uap:DataFormat>URI</uap:DataFormat>\n");
    try w.writeAll("          </uap:ShareTarget>\n        </uap:Extension>\n");
    if (ext_list.len > 0) {
        try w.writeAll(
            \\        <uap3:Extension Category="windows.fileTypeAssociation">
            \\          <uap3:FileTypeAssociation Name="oriel-share" Parameters="--oriel-open-with &quot;%1&quot;">
            \\            <uap:SupportedFileTypes>
            \\
        );
        for (ext_list) |e| try w.print("              <uap:FileType>{s}</uap:FileType>\n", .{e});
        try w.writeAll(
            \\            </uap:SupportedFileTypes>
            \\          </uap3:FileTypeAssociation>
            \\        </uap3:Extension>
            \\
        );
    }
    try w.writeAll("      </Extensions>\n");
}

/// ".txt" from "txt" or ".TXT", or null (letters, digits, `_+-`, up to 32).
pub fn normalizeExtension(buf: *[40]u8, raw: []const u8) ?[]const u8 {
    const bare = if (raw.len > 0 and raw[0] == '.') raw[1..] else raw;
    if (bare.len == 0 or bare.len > 32) return null;
    buf[0] = '.';
    for (bare, 1..) |c, i| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '+' or c == '-')) return null;
        buf[i] = std.ascii.toLower(c);
    }
    return buf[0 .. bare.len + 1];
}

/// Text escaped for XML attributes and content (`{f}`).
const Xml = struct {
    s: []const u8,
    fn init(s: []const u8) Xml {
        return .{ .s = s };
    }
    pub fn format(x: Xml, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (x.s) |c| switch (c) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '"' => try w.writeAll("&quot;"),
            '\'' => try w.writeAll("&apos;"),
            // Control characters aren't allowed in XML 1.0 (tab, CR, LF are).
            0...8, 11, 12, 14...31 => try w.writeByte(' '),
            else => try w.writeByte(c),
        };
    }
};

// -------------------------------------------------------------- package

/// A file in the package: `path` relative to its root, with `/` or `\`.
pub const Entry = struct {
    path: []const u8,
    data: []const u8,
};

pub const block_size = 64 * 1024;

/// Write the package: `payload` (the files, the logos and the manifest
/// as "AppxManifest.xml"), then the block map and content types.
pub fn writePackage(gpa: std.mem.Allocator, w: *std.Io.Writer, payload: []const Entry) !void {
    var zip: Zip = .{ .gpa = gpa };
    defer zip.deinit();

    var map: std.Io.Writer.Allocating = .init(gpa);
    defer map.deinit();
    try map.writer.writeAll(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<BlockMap xmlns="http://schemas.microsoft.com/appx/2010/blockmap" HashMethod="http://www.w3.org/2001/04/xmlenc#sha256">
        \\
    );
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        seen.deinit(gpa);
    }
    for (payload) |e| {
        try validatePath(e.path);
        const part = try partName(gpa, e.path);
        defer gpa.free(part);
        const lower = try std.ascii.allocLowerString(gpa, part);
        const gop = try seen.getOrPut(gpa, lower);
        if (gop.found_existing) {
            gpa.free(lower);
            return error.DuplicatePath;
        }
        const lfh = try zip.add(w, part, e.data);
        // The block map names files as Windows paths, not part names.
        const win_name = try gpa.dupe(u8, e.path);
        defer gpa.free(win_name);
        std.mem.replaceScalar(u8, win_name, '/', '\\');
        try map.writer.print("  <File Name=\"{f}\" Size=\"{d}\" LfhSize=\"{d}\">", .{ Xml.init(win_name), e.data.len, lfh });
        var off: usize = 0;
        while (off < e.data.len) : (off += block_size) {
            const block = e.data[off..@min(off + block_size, e.data.len)];
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(block, &digest, .{});
            var b64: [44]u8 = undefined;
            try map.writer.print("<Block Hash=\"{s}\" />", .{std.base64.standard.Encoder.encode(&b64, &digest)});
        }
        try map.writer.writeAll("</File>\n");
    }
    try map.writer.writeAll("</BlockMap>\n");
    _ = try zip.add(w, "AppxBlockMap.xml", map.written());

    const types = try contentTypes(gpa, payload);
    defer gpa.free(types);
    _ = try zip.add(w, "[Content_Types].xml", types);
    try zip.finish(w);
}

/// No absolute paths, `..`, empty segments, or the package's own files.
fn validatePath(p: []const u8) !void {
    if (p.len == 0 or p[0] == '/' or p[0] == '\\' or std.mem.indexOfScalar(u8, p, ':') != null) return error.InvalidPath;
    var it = std.mem.tokenizeAny(u8, p, "/\\");
    var n: usize = 0;
    while (it.next()) |seg| : (n += 1) {
        if (std.mem.eql(u8, seg, "..") or std.mem.eql(u8, seg, ".")) return error.InvalidPath;
    }
    if (n == 0 or std.mem.indexOf(u8, p, "//") != null or std.mem.indexOf(u8, p, "\\\\") != null) return error.InvalidPath;
    for ([_][]const u8{ "AppxBlockMap.xml", "[Content_Types].xml", "AppxSignature.p7x", "AppxMetadata" }) |r| {
        if (std.ascii.startsWithIgnoreCase(p, r)) return error.InvalidPath;
    }
}

/// The ZIP item name for a package path: `/` separators, and bytes
/// outside RFC 3986's pchar percent-encoded (OPC part names).
fn partName(gpa: std.mem.Allocator, p: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (p) |c| {
        if (c == '\\' or c == '/') {
            try out.append(gpa, '/');
        } else if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-._~!$&'()*+,;=:@", c) != null) {
            try out.append(gpa, c);
        } else {
            try out.print(gpa, "%{X:0>2}", .{c});
        }
    }
    return out.toOwnedSlice(gpa);
}

/// [Content_Types].xml: a Default per extension, an Override for files
/// without one and for the manifest and block map.
fn contentTypes(gpa: std.mem.Allocator, payload: []const Entry) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        \\
    );
    var exts: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = exts.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        exts.deinit(gpa);
    }
    for (payload) |e| {
        const base = std.fs.path.basenameWindows(e.path);
        if (std.ascii.eqlIgnoreCase(e.path, "AppxManifest.xml")) continue;
        const ext = std.fs.path.extension(base);
        if (ext.len <= 1) {
            const part = try partName(gpa, e.path);
            defer gpa.free(part);
            try w.print("  <Override PartName=\"/{f}\" ContentType=\"application/octet-stream\" />\n", .{Xml.init(part)});
            continue;
        }
        const lower = try std.ascii.allocLowerString(gpa, ext[1..]);
        const gop = try exts.getOrPut(gpa, lower);
        if (gop.found_existing) {
            gpa.free(lower);
            continue;
        }
        try w.print("  <Default Extension=\"{f}\" ContentType=\"{s}\" />\n", .{ Xml.init(lower), contentTypeOf(lower) });
    }
    try w.writeAll(
        \\  <Override PartName="/AppxManifest.xml" ContentType="application/vnd.ms-appx.manifest+xml" />
        \\  <Override PartName="/AppxBlockMap.xml" ContentType="application/vnd.ms-appx.blockmap+xml" />
        \\</Types>
        \\
    );
    return out.toOwnedSlice();
}

fn contentTypeOf(ext: []const u8) []const u8 {
    const table = [_]struct { []const u8, []const u8 }{
        .{ "exe", "application/x-msdownload" }, .{ "dll", "application/x-msdownload" },
        .{ "png", "image/png" },                .{ "jpg", "image/jpeg" },
        .{ "jpeg", "image/jpeg" },              .{ "ico", "image/vnd.microsoft.icon" },
        .{ "xml", "application/xml" },          .{ "json", "application/json" },
        .{ "txt", "text/plain" },               .{ "html", "text/html" },
        .{ "js", "application/javascript" },    .{ "css", "text/css" },
        .{ "pdb", "application/octet-stream" }, .{ "bin", "application/octet-stream" },
    };
    for (table) |t| if (std.mem.eql(u8, t[0], ext)) return t[1];
    return "application/octet-stream";
}

/// A ZIP writer for stored (uncompressed) entries, always with Zip64 end
/// records, as AppxPackaging writes them. Entries must be under 4 GiB.
const Zip = struct {
    gpa: std.mem.Allocator,
    central: std.ArrayList(u8) = .empty,
    count: u64 = 0,
    offset: u64 = 0,

    // 1980-01-01 00:00: reproducible packages.
    const dos_time: u16 = 0;
    const dos_date: u16 = (0 << 9) | (1 << 5) | 1;

    fn deinit(z: *Zip) void {
        z.central.deinit(z.gpa);
    }

    /// Writes the entry; returns its local file header's size (LfhSize).
    fn add(z: *Zip, w: *std.Io.Writer, name: []const u8, data: []const u8) !usize {
        if (data.len >= 0xFFFFFFFF or z.offset >= 0xFFFFFFFF) return error.TooLarge;
        const crc = std.hash.Crc32.hash(data);
        const size: u32 = @intCast(data.len);
        const flags: u16 = 0;
        var h: [30]u8 = undefined;
        std.mem.writeInt(u32, h[0..4], 0x04034b50, .little);
        std.mem.writeInt(u16, h[4..6], 20, .little);
        std.mem.writeInt(u16, h[6..8], flags, .little);
        std.mem.writeInt(u16, h[8..10], 0, .little); // stored
        std.mem.writeInt(u16, h[10..12], dos_time, .little);
        std.mem.writeInt(u16, h[12..14], dos_date, .little);
        std.mem.writeInt(u32, h[14..18], crc, .little);
        std.mem.writeInt(u32, h[18..22], size, .little);
        std.mem.writeInt(u32, h[22..26], size, .little);
        std.mem.writeInt(u16, h[26..28], @intCast(name.len), .little);
        std.mem.writeInt(u16, h[28..30], 0, .little);
        try w.writeAll(&h);
        try w.writeAll(name);
        try w.writeAll(data);

        var c: [46]u8 = undefined;
        std.mem.writeInt(u32, c[0..4], 0x02014b50, .little);
        std.mem.writeInt(u16, c[4..6], 45, .little);
        std.mem.writeInt(u16, c[6..8], 20, .little);
        std.mem.writeInt(u16, c[8..10], flags, .little);
        std.mem.writeInt(u16, c[10..12], 0, .little);
        std.mem.writeInt(u16, c[12..14], dos_time, .little);
        std.mem.writeInt(u16, c[14..16], dos_date, .little);
        std.mem.writeInt(u32, c[16..20], crc, .little);
        std.mem.writeInt(u32, c[20..24], size, .little);
        std.mem.writeInt(u32, c[24..28], size, .little);
        std.mem.writeInt(u16, c[28..30], @intCast(name.len), .little);
        std.mem.writeInt(u16, c[30..32], 0, .little); // extra
        std.mem.writeInt(u16, c[32..34], 0, .little); // comment
        std.mem.writeInt(u16, c[34..36], 0, .little); // disk
        std.mem.writeInt(u16, c[36..38], 0, .little); // internal attributes
        std.mem.writeInt(u32, c[38..42], 0, .little); // external attributes
        std.mem.writeInt(u32, c[42..46], @intCast(z.offset), .little);
        try z.central.appendSlice(z.gpa, &c);
        try z.central.appendSlice(z.gpa, name);

        const lfh = h.len + name.len;
        z.offset += lfh + data.len;
        z.count += 1;
        return lfh;
    }

    fn finish(z: *Zip, w: *std.Io.Writer) !void {
        const cd_offset = z.offset;
        try w.writeAll(z.central.items);
        const cd_size: u64 = z.central.items.len;
        const eocd64_offset = cd_offset + cd_size;

        var r: [56]u8 = undefined;
        std.mem.writeInt(u32, r[0..4], 0x06064b50, .little);
        std.mem.writeInt(u64, r[4..12], 44, .little);
        std.mem.writeInt(u16, r[12..14], 45, .little);
        std.mem.writeInt(u16, r[14..16], 45, .little);
        std.mem.writeInt(u32, r[16..20], 0, .little);
        std.mem.writeInt(u32, r[20..24], 0, .little);
        std.mem.writeInt(u64, r[24..32], z.count, .little);
        std.mem.writeInt(u64, r[32..40], z.count, .little);
        std.mem.writeInt(u64, r[40..48], cd_size, .little);
        std.mem.writeInt(u64, r[48..56], cd_offset, .little);
        try w.writeAll(&r);

        var l: [20]u8 = undefined;
        std.mem.writeInt(u32, l[0..4], 0x07064b50, .little);
        std.mem.writeInt(u32, l[4..8], 0, .little);
        std.mem.writeInt(u64, l[8..16], eocd64_offset, .little);
        std.mem.writeInt(u32, l[16..20], 1, .little);
        try w.writeAll(&l);

        var e: [22]u8 = undefined;
        std.mem.writeInt(u32, e[0..4], 0x06054b50, .little);
        std.mem.writeInt(u16, e[4..6], 0, .little);
        std.mem.writeInt(u16, e[6..8], 0, .little);
        std.mem.writeInt(u16, e[8..10], @intCast(@min(z.count, 0xFFFF)), .little);
        std.mem.writeInt(u16, e[10..12], @intCast(@min(z.count, 0xFFFF)), .little);
        std.mem.writeInt(u32, e[12..16], @intCast(@min(cd_size, 0xFFFFFFFF)), .little);
        std.mem.writeInt(u32, e[16..20], @intCast(@min(cd_offset, 0xFFFFFFFF)), .little);
        std.mem.writeInt(u16, e[20..22], 0, .little);
        try w.writeAll(&e);
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn testManifest() Manifest {
    return .{
        .identity_name = "com.example.GhostShare",
        .publisher = "CN=Example & Co",
        .version = "1.2.3.0",
        .arch = "x64",
        .display_name = "Ghost <Share>",
        .publisher_display_name = "Example",
        .description = "Shares things",
        .executable = "ghostshare.exe",
        .permissions = &.{ "notifications", "bluetooth", "local_network", "screen_capture" },
        .share = .{ .label = "Send with Ghost Share", .types = &.{ "image/*", "text/plain" }, .extensions = &.{ "png", ".JPG" } },
    };
}

test "packageVersion" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("1.2.3.0", packageVersion(&buf, "1.2.3").?);
    try testing.expectEqualStrings("2.0.0.0", packageVersion(&buf, "2").?);
    try testing.expectEqualStrings("1.2.3.4", packageVersion(&buf, "1.2.3.4").?);
    try testing.expect(packageVersion(&buf, "1.2.3-beta") == null);
    try testing.expect(packageVersion(&buf, "1.2.3.4.5") == null);
    try testing.expect(packageVersion(&buf, "1..2") == null);
    try testing.expect(packageVersion(&buf, "70000") == null);
}

test "generateManifest" {
    const xml = try generateManifest(testing.allocator, testManifest());
    defer testing.allocator.free(xml);
    const has = struct {
        fn f(hay: []const u8, needle: []const u8) !void {
            if (std.mem.indexOf(u8, hay, needle) == null) {
                std.debug.print("missing: {s}\n", .{needle});
                return error.TestExpectedEqual;
            }
        }
    }.f;
    try has(xml, "<Identity Name=\"com.example.GhostShare\" Publisher=\"CN=Example &amp; Co\" Version=\"1.2.3.0\" ProcessorArchitecture=\"x64\" />");
    try has(xml, "<DisplayName>Ghost &lt;Share&gt;</DisplayName>");
    try has(xml, "Executable=\"ghostshare.exe\" EntryPoint=\"Windows.FullTrustApplication\"");
    try has(xml, "<uap:ShareTarget Description=\"Send with Ghost Share\">");
    try has(xml, "<uap:FileType>.png</uap:FileType>");
    try has(xml, "<uap:FileType>.jpg</uap:FileType>");
    try has(xml, "<uap:DataFormat>StorageItems</uap:DataFormat>");
    try has(xml, "<uap:DataFormat>Text</uap:DataFormat>");
    try has(xml, "Parameters=\"--oriel-open-with &quot;%1&quot;\"");
    // Capabilities in schema order: general, restricted, device.
    const general = std.mem.indexOf(u8, xml, "<Capability Name=\"privateNetworkClientServer\" />").?;
    const full_trust = std.mem.indexOf(u8, xml, "<rescap:Capability Name=\"runFullTrust\" />").?;
    const capture = std.mem.indexOf(u8, xml, "<rescap:Capability Name=\"graphicsCaptureProgrammatic\" />").?;
    const bt = std.mem.indexOf(u8, xml, "<DeviceCapability Name=\"bluetooth\" />").?;
    try testing.expect(general < full_trust and full_trust < capture and capture < bt);
    try testing.expect(std.mem.indexOf(u8, xml, "SupportsAnyFileType") == null);
}

test "generateManifest: the app's capabilities, merged in schema order" {
    var m = testManifest();
    m.permissions = &.{ "bluetooth", "local_network" };
    m.capabilities = &.{
        .{ .kind = .device, .name = "proximity" },
        .{ .kind = .restricted, .name = "broadFileSystemAccess" },
        .{ .kind = .uap, .name = "picturesLibrary" },
        .{ .kind = .general, .name = "internetClientServer" },
        // Already there: once.
        .{ .kind = .device, .name = "bluetooth" },
        .{ .kind = .general, .name = "internetClient" },
        .{ .kind = .restricted, .name = "runFullTrust" },
        .{ .kind = .uap, .name = "picturesLibrary" },
    };
    const xml = try generateManifest(testing.allocator, m);
    defer testing.allocator.free(xml);
    const start = std.mem.indexOf(u8, xml, "  <Capabilities>\n").?;
    const end = std.mem.indexOf(u8, xml, "  </Capabilities>\n").?;
    try testing.expectEqualStrings(
        \\  <Capabilities>
        \\    <Capability Name="internetClient" />
        \\    <Capability Name="privateNetworkClientServer" />
        \\    <Capability Name="internetClientServer" />
        \\    <uap:Capability Name="picturesLibrary" />
        \\    <rescap:Capability Name="runFullTrust" />
        \\    <rescap:Capability Name="broadFileSystemAccess" />
        \\    <DeviceCapability Name="bluetooth" />
        \\    <DeviceCapability Name="proximity" />
        \\
    , xml[start..end]);

    m.capabilities = &.{.{ .kind = .general, .name = "bad\"name" }};
    try testing.expectError(error.InvalidCapability, generateManifest(testing.allocator, m));
    try testing.expectEqual(Capability.Kind.uap, Capability.parse("uap:picturesLibrary").?.kind);
    try testing.expectEqualStrings("{6bdd1fc6-810f-11d0-bec7-08002be2092f}", Capability.parse("device:{6bdd1fc6-810f-11d0-bec7-08002be2092f}").?.name);
    try testing.expect(Capability.parse("picturesLibrary") == null);
    try testing.expect(Capability.parse("other:x") == null);
    try testing.expect(Capability.parse("general:a<b") == null);
}

test "generateManifest: any file, no share, bad input" {
    var m = testManifest();
    m.share = .{ .label = "Send", .types = &.{"*/*"} };
    const any = try generateManifest(testing.allocator, m);
    defer testing.allocator.free(any);
    try testing.expect(std.mem.indexOf(u8, any, "<uap:SupportsAnyFileType />") != null);
    try testing.expect(std.mem.indexOf(u8, any, "fileTypeAssociation") == null);

    m.share = null;
    const plain = try generateManifest(testing.allocator, m);
    defer testing.allocator.free(plain);
    try testing.expect(std.mem.indexOf(u8, plain, "<Extensions>") == null);

    m = testManifest();
    m.identity_name = "a b";
    try testing.expectError(error.InvalidIdentityName, generateManifest(testing.allocator, m));
    m = testManifest();
    m.version = "1.2.3";
    try testing.expectError(error.InvalidVersion, generateManifest(testing.allocator, m));
    m = testManifest();
    m.share = .{ .label = "x", .types = &.{"image/*"} };
    try testing.expectError(error.EmptyShareTarget, generateManifest(testing.allocator, m));
    m.share = .{ .label = "x", .extensions = &.{"a b"} };
    try testing.expectError(error.InvalidExtension, generateManifest(testing.allocator, m));
}

test "unsignedPublisher" {
    const p = try unsignedPublisher(testing.allocator, "Example Co");
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("CN=Example Co, " ++ unsigned_oid, p);
    try testing.expectError(error.InvalidPublisher, unsignedPublisher(testing.allocator, "a,b"));
}

test "partName" {
    const p = try partName(testing.allocator, "Assets\\a b+[1].png");
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("Assets/a%20b+%5B1%5D.png", p);
}

test "writePackage: a readable ZIP with a block map and content types" {
    const gpa = testing.allocator;
    var big: [block_size + 10]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @truncate(i);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try writePackage(gpa, &out.writer, &.{
        .{ .path = "app.exe", .data = &big },
        .{ .path = "Assets\\a b.png", .data = "png" },
        .{ .path = "LICENSE", .data = "" },
        .{ .path = "AppxManifest.xml", .data = "<Package/>" },
    });
    const zip = out.written();

    // The central directory lists every entry, block map and types last.
    const names = [_][]const u8{ "app.exe", "Assets/a%20b.png", "LICENSE", "AppxManifest.xml", "AppxBlockMap.xml", "[Content_Types].xml" };
    const eocd = zip[zip.len - 22 ..];
    try testing.expectEqual(@as(u32, 0x06054b50), std.mem.readInt(u32, eocd[0..4], .little));
    try testing.expectEqual(@as(u16, names.len), std.mem.readInt(u16, eocd[10..12], .little));
    var cd = std.mem.readInt(u32, eocd[16..20], .little);
    for (names) |n| {
        try testing.expectEqual(@as(u32, 0x02014b50), std.mem.readInt(u32, zip[cd..][0..4], .little));
        const nlen = std.mem.readInt(u16, zip[cd + 28 ..][0..2], .little);
        try testing.expectEqualStrings(n, zip[cd + 46 ..][0..nlen]);
        // Its local header and stored data, CRC checked.
        const lho = std.mem.readInt(u32, zip[cd + 42 ..][0..4], .little);
        const size = std.mem.readInt(u32, zip[cd + 24 ..][0..4], .little);
        const data = zip[lho + 30 + nlen ..][0..size];
        try testing.expectEqual(std.mem.readInt(u32, zip[cd + 16 ..][0..4], .little), std.hash.Crc32.hash(data));
        if (std.mem.eql(u8, n, "AppxBlockMap.xml")) {
            try testing.expect(std.mem.indexOf(u8, data, "<File Name=\"Assets\\a b.png\" Size=\"3\" LfhSize=\"46\">") != null);
            try testing.expect(std.mem.indexOf(u8, data, "<File Name=\"LICENSE\" Size=\"0\" LfhSize=\"37\"></File>") != null);
            // Two blocks for the big file.
            const f = std.mem.indexOf(u8, data, "<File Name=\"app.exe\"").?;
            const end = std.mem.indexOfPos(u8, data, f, "</File>").?;
            try testing.expectEqual(@as(usize, 2), std.mem.count(u8, data[f..end], "<Block "));
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(big[0..block_size], &digest, .{});
            var b64: [44]u8 = undefined;
            try testing.expect(std.mem.indexOf(u8, data[f..end], std.base64.standard.Encoder.encode(&b64, &digest)) != null);
        }
        if (std.mem.eql(u8, n, "[Content_Types].xml")) {
            try testing.expect(std.mem.indexOf(u8, data, "<Default Extension=\"exe\" ContentType=\"application/x-msdownload\" />") != null);
            try testing.expect(std.mem.indexOf(u8, data, "<Override PartName=\"/LICENSE\" ContentType=\"application/octet-stream\" />") != null);
        }
        cd += 46 + nlen;
    }
}

test "writePackage rejects bad paths" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    for ([_][]const u8{ "..\\x", "/abs", "C:\\x", "AppxBlockMap.xml", "a//b" }) |p| {
        try testing.expectError(error.InvalidPath, writePackage(testing.allocator, &out.writer, &.{.{ .path = p, .data = "" }}));
    }
    try testing.expectError(error.DuplicatePath, writePackage(testing.allocator, &out.writer, &.{ .{ .path = "a.txt", .data = "" }, .{ .path = "A.TXT", .data = "" } }));
}
