//! The generated parts of an Android app's `AndroidManifest.xml`.
//!
//! The manifest is the developer's file, but some of it follows build.zig:
//! the permissions and features the app's capabilities need, the queries
//! Oriel's modules make, the main activity's intent filters and the
//! components (services) the app declares. Those parts sit between marker
//! comments,
//!
//!     <!-- oriel:permissions begin -->
//!     ...
//!     <!-- oriel:permissions end -->
//!
//! and `sync` rewrites only them, on every build, from the template rendered
//! with this build's values. Everything outside the markers stays as the
//! developer left it. A manifest written before the markers existed is
//! migrated once: the markers are inserted where the template has them, and
//! the entries Oriel used to write there (the same element, or one declaring
//! the same name) are moved inside.
//!
//! Pure (no files, no build graph): used by build.zig (the XML for the
//! declared permissions) and by `package_tool android-project` (`sync`).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The generated regions, in the order they appear in the template.
pub const regions = [_][]const u8{
    // <uses-permission>: what the declared capabilities need.
    "permissions",
    // <uses-feature>.
    "features",
    // <queries>: packages and intents Oriel's modules look up.
    "queries",
    // Intent filters of OrielMainActivity (URL schemes, later share targets).
    "main-activity",
    // <service>s and other components (the tile, the keyboard, audio capture).
    "components",
};

pub fn beginMarker(comptime name: []const u8) []const u8 {
    return "<!-- oriel:" ++ name ++ " begin -->";
}

pub fn endMarker(comptime name: []const u8) []const u8 {
    return "<!-- oriel:" ++ name ++ " end -->";
}

// ---------------------------------------------------------------------------
// What the declared capabilities need
// ---------------------------------------------------------------------------

pub const Permission = struct {
    name: []const u8,
    /// `android:maxSdkVersion`: only needed up to this API level.
    max_sdk: ?u32 = null,
    /// `android:usesPermissionFlags` (e.g. "neverForLocation").
    flags: ?[]const u8 = null,
};

pub const Feature = struct {
    name: []const u8,
    required: bool = false,
};

/// What each capability (a `permissions/common.zig` `Kind` name) declares
/// in the manifest. Kinds the build's `Declared` doesn't have yet are
/// skipped, so the table can name capabilities before they exist.
pub const Requirement = struct {
    kind: []const u8,
    permissions: []const Permission = &.{},
    features: []const Feature = &.{},
};

pub const requirements = [_]Requirement{
    .{ .kind = "microphone", .permissions = &.{
        .{ .name = "android.permission.RECORD_AUDIO" },
        .{ .name = "android.permission.FOREGROUND_SERVICE" },
        .{ .name = "android.permission.FOREGROUND_SERVICE_MICROPHONE" },
    } },
    .{ .kind = "camera", .permissions = &.{
        .{ .name = "android.permission.CAMERA" },
    } },
    .{ .kind = "location", .permissions = &.{
        .{ .name = "android.permission.ACCESS_COARSE_LOCATION" },
        .{ .name = "android.permission.ACCESS_FINE_LOCATION" },
    } },
    .{ .kind = "notifications", .permissions = &.{
        .{ .name = "android.permission.POST_NOTIFICATIONS" },
    } },
    // All roles: scanning, advertising and connecting share the one
    // "Nearby devices" prompt (API 31+). Up to API 30, the legacy
    // permissions, and location for scanning.
    .{ .kind = "bluetooth", .permissions = &.{
        .{ .name = "android.permission.BLUETOOTH_SCAN", .flags = "neverForLocation" },
        .{ .name = "android.permission.BLUETOOTH_ADVERTISE" },
        .{ .name = "android.permission.BLUETOOTH_CONNECT" },
        .{ .name = "android.permission.BLUETOOTH", .max_sdk = 30 },
        .{ .name = "android.permission.BLUETOOTH_ADMIN", .max_sdk = 30 },
        .{ .name = "android.permission.ACCESS_FINE_LOCATION", .max_sdk = 30 },
    }, .features = &.{
        .{ .name = "android.hardware.bluetooth_le", .required = false },
    } },
    // Normal permissions (no prompt): the network's state and multicast
    // (mDNS). NEARBY_WIFI_DEVICES is for Wi-Fi Direct/Aware, not mDNS.
    .{ .kind = "local_network", .permissions = &.{
        .{ .name = "android.permission.ACCESS_NETWORK_STATE" },
        .{ .name = "android.permission.ACCESS_WIFI_STATE" },
        .{ .name = "android.permission.CHANGE_WIFI_MULTICAST_STATE" },
    } },
};

fn isDeclared(declared: anytype, comptime kind: []const u8) bool {
    const T = @TypeOf(declared);
    if (!@hasField(T, kind)) return false;
    return @field(declared, kind) != null;
}

/// The `<uses-permission>` entries `declared` (a `Declared`: one optional
/// reason per kind) needs, one per name. A name two capabilities need is
/// merged: it is unrestricted (no maxSdkVersion, no flags) if either needs
/// it so.
pub fn permissionsFor(gpa: Allocator, declared: anytype) ![]Permission {
    return permissionsWithExtras(gpa, declared, &.{});
}

/// `permissionsFor` plus the app's own entries (`AppOptions.android.permissions`),
/// after the generated ones. An extra whose name is already there keeps the
/// entry that is (its flags and position), except that an extra without
/// max_sdk lifts the entry's maxSdkVersion: the app needs it on every API
/// level. Names must pass `validName`.
pub fn permissionsWithExtras(gpa: Allocator, declared: anytype, extras: []const Permission) ![]Permission {
    var out: std.ArrayList(Permission) = .empty;
    errdefer out.deinit(gpa);
    inline for (requirements) |req| if (isDeclared(declared, req.kind)) {
        for (req.permissions) |p| try mergePermission(gpa, &out, p);
    };
    for (extras) |p| {
        try checkPermission(p);
        for (out.items) |*have| {
            if (std.mem.eql(u8, have.name, p.name)) {
                if (p.max_sdk == null) have.max_sdk = null;
                break;
            }
        } else try out.append(gpa, p);
    }
    return out.toOwnedSlice(gpa);
}

fn mergePermission(gpa: Allocator, list: *std.ArrayList(Permission), p: Permission) !void {
    for (list.items) |*have| if (std.mem.eql(u8, have.name, p.name)) {
        have.max_sdk = if (have.max_sdk == null or p.max_sdk == null) null else @max(have.max_sdk.?, p.max_sdk.?);
        if (p.flags == null or have.flags == null or !std.mem.eql(u8, have.flags.?, p.flags.?)) have.flags = null;
        return;
    };
    try list.append(gpa, p);
}

/// The `<uses-feature>` entries `declared` needs, one per name (required
/// if any capability requires it).
pub fn featuresFor(gpa: Allocator, declared: anytype) ![]Feature {
    return featuresWithExtras(gpa, declared, &.{});
}

/// `featuresFor` plus the app's own entries (`AppOptions.android.features`),
/// one per name: a name already there stays where it is, required if
/// either declaration requires it. Names must pass `validName`.
pub fn featuresWithExtras(gpa: Allocator, declared: anytype, extras: []const Feature) ![]Feature {
    var out: std.ArrayList(Feature) = .empty;
    errdefer out.deinit(gpa);
    inline for (requirements) |req| if (isDeclared(declared, req.kind)) {
        for (req.features) |f| try mergeFeature(gpa, &out, f);
    };
    for (extras) |f| {
        if (!validName(f.name)) return error.InvalidName;
        try mergeFeature(gpa, &out, f);
    }
    return out.toOwnedSlice(gpa);
}

fn mergeFeature(gpa: Allocator, list: *std.ArrayList(Feature), f: Feature) !void {
    for (list.items) |*have| if (std.mem.eql(u8, have.name, f.name)) {
        have.required = have.required or f.required;
        return;
    };
    try list.append(gpa, f);
}

/// A name (or flags value) that can go in an XML attribute as is: not
/// empty, no quotes, `<`, `>`, `&`, whitespace or control characters.
pub fn validName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |ch| {
        if (ch <= ' ' or ch == 0x7F) return false;
        if (std.mem.indexOfScalar(u8, "\"'<>&", ch) != null) return false;
    }
    return true;
}

fn checkPermission(p: Permission) error{InvalidName}!void {
    if (!validName(p.name)) return error.InvalidName;
    if (p.flags) |f| if (!validName(f)) return error.InvalidName;
}

/// The permissions region's lines for `declared`.
pub fn permissionsXml(gpa: Allocator, declared: anytype) ![]u8 {
    return permissionsXmlWithExtras(gpa, declared, &.{});
}

/// The permissions region's lines for `declared` and the app's extras
/// (`permissionsWithExtras`).
pub fn permissionsXmlWithExtras(gpa: Allocator, declared: anytype, extras: []const Permission) ![]u8 {
    const perms = try permissionsWithExtras(gpa, declared, extras);
    defer gpa.free(perms);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (perms) |p| {
        try out.print(gpa, "    <uses-permission android:name=\"{s}\"", .{p.name});
        if (p.max_sdk) |v| try out.print(gpa, " android:maxSdkVersion=\"{d}\"", .{v});
        if (p.flags) |v| try out.print(gpa, " android:usesPermissionFlags=\"{s}\"", .{v});
        try out.appendSlice(gpa, " />\n");
    }
    return out.toOwnedSlice(gpa);
}

/// The features region's lines for `declared`.
pub fn featuresXml(gpa: Allocator, declared: anytype) ![]u8 {
    return featuresXmlWithExtras(gpa, declared, &.{});
}

/// The features region's lines for `declared` and the app's extras
/// (`featuresWithExtras`).
pub fn featuresXmlWithExtras(gpa: Allocator, declared: anytype, extras: []const Feature) ![]u8 {
    const features = try featuresWithExtras(gpa, declared, extras);
    defer gpa.free(features);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (features) |f| try out.print(gpa, "    <uses-feature android:name=\"{s}\" android:required=\"{s}\" />\n", .{
        f.name, if (f.required) "true" else "false",
    });
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Rewriting the regions
// ---------------------------------------------------------------------------

pub const Error = error{
    OutOfMemory,
    /// A begin marker without its end (or the other way round), a marker
    /// twice, or an end before its begin.
    MalformedRegion,
    /// The template lacks one of `regions` (an Oriel bug).
    TemplateMissingRegion,
    /// Migrating: no place for a region (no OrielMainActivity element with
    /// children, no <application> element).
    NoAnchor,
    /// An element without its end tag.
    MalformedXml,
};

pub const Synced = struct {
    text: []u8,
    /// Markers were inserted (the manifest predates them).
    migrated: bool,
};

/// The manifest `current` with every region's content replaced by the same
/// region's in `template` (the template rendered for this build).
///
/// - Content of a region is the whole lines between its marker lines.
/// - A generated element is left out when the manifest declares one with the
///   same tag and android:name outside the regions (the developer's own wins).
/// - Regions missing from `current` are inserted (see the file comment);
///   `migrated` reports it.
pub fn sync(gpa: Allocator, current: []const u8, template: []const u8) Error!Synced {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    try text.appendSlice(gpa, current);

    var contents: [regions.len][]const u8 = undefined;
    var spans: [regions.len]Span = undefined;
    var missing = [_]bool{false} ** regions.len;
    var any_missing = false;
    inline for (regions, 0..) |name, i| {
        spans[i] = (findRegion(template, name) catch return error.TemplateMissingRegion) orelse return error.TemplateMissingRegion;
        contents[i] = template[spans[i].content_start..spans[i].content_end];
        if (try findRegion(current, name) == null) {
            missing[i] = true;
            any_missing = true;
        }
    }

    if (any_missing) {
        // The entries Oriel wrote before the markers existed: the same items
        // as the regions' generated content (or the same named elements).
        var generated: std.ArrayList(Item) = .empty;
        defer generated.deinit(gpa);
        for (contents, missing) |content, m| if (m) try collectItems(gpa, content, &generated);
        try removeMatching(gpa, &text, generated.items);

        // Empty regions at their anchors, filled below.
        inline for (regions, 0..) |name, i| if (missing[i]) {
            const at = try anchor(text.items, name);
            const block = template[spans[i].begin_line..spans[i].content_start];
            const end_line = template[spans[i].content_end..spans[i].end_line_end];
            var insert: std.ArrayList(u8) = .empty;
            defer insert.deinit(gpa);
            try insert.appendSlice(gpa, block);
            try insert.appendSlice(gpa, end_line);
            if (end_line.len == 0 or end_line[end_line.len - 1] != '\n') try insert.append(gpa, '\n');
            try text.insertSlice(gpa, at, insert.items);
        };
        collapseBlankLines(&text);
    }

    // The developer's own declarations, outside the regions.
    var outside: std.ArrayList(Key) = .empty;
    defer outside.deinit(gpa);
    try collectOutsideKeys(gpa, text.items, &outside);

    inline for (regions, 0..) |name, i| {
        const span = (try findRegion(text.items, name)).?;
        const filtered = try dropDeclared(gpa, contents[i], outside.items);
        defer gpa.free(filtered);
        try text.replaceRange(gpa, span.content_start, span.content_end - span.content_start, filtered);
    }
    return .{ .text = try text.toOwnedSlice(gpa), .migrated = any_missing };
}

const Span = struct {
    /// Start of the begin marker's line.
    begin_line: usize,
    /// Start of the line after the begin marker.
    content_start: usize,
    /// Start of the end marker's line.
    content_end: usize,
    /// After the end marker's line (its newline included).
    end_line_end: usize,
};

/// The region `name` in `text`, null if it has neither marker.
fn findRegion(text: []const u8, comptime name: []const u8) Error!?Span {
    const begin = beginMarker(name);
    const end = endMarker(name);
    const b = std.mem.indexOf(u8, text, begin);
    const e = std.mem.indexOf(u8, text, end);
    if (b == null and e == null) return null;
    if (b == null or e == null) return error.MalformedRegion;
    if (std.mem.indexOfPos(u8, text, b.? + begin.len, begin) != null) return error.MalformedRegion;
    if (std.mem.indexOfPos(u8, text, e.? + end.len, end) != null) return error.MalformedRegion;
    const content_start = lineAfter(text, b.? + begin.len);
    const content_end = lineStart(text, e.?);
    if (e.? < b.? or content_end < content_start) return error.MalformedRegion;
    return .{
        .begin_line = lineStart(text, b.?),
        .content_start = content_start,
        .content_end = content_end,
        .end_line_end = lineAfter(text, e.? + end.len),
    };
}

fn lineStart(text: []const u8, pos: usize) usize {
    return if (std.mem.lastIndexOfScalar(u8, text[0..pos], '\n')) |nl| nl + 1 else 0;
}

fn lineAfter(text: []const u8, pos: usize) usize {
    return if (std.mem.indexOfScalarPos(u8, text, pos, '\n')) |nl| nl + 1 else text.len;
}

/// Where a missing region goes in `text`: the template's place for it.
fn anchor(text: []const u8, comptime name: []const u8) Error!usize {
    if (comptime std.mem.eql(u8, name, "permissions")) {
        // After the manifest's last <uses-permission>, else after <manifest>.
        var it: Scanner = .{ .text = text };
        var last: ?usize = null;
        var manifest_end: ?usize = null;
        while (try it.next()) |node| switch (node.kind) {
            .start => {
                if (node.depth == 0 and std.mem.eql(u8, node.name, "manifest")) manifest_end = node.end;
                if (node.depth == 1 and (std.mem.eql(u8, node.name, "uses-permission") or std.mem.eql(u8, node.name, "uses-permission-sdk-23")))
                    last = (try elementEnd(text, node));
            },
            else => {},
        };
        return lineAfter(text, last orelse manifest_end orelse return error.NoAnchor);
    }
    if (comptime std.mem.eql(u8, name, "features")) {
        const span = (try findRegion(text, "permissions")) orelse return error.NoAnchor;
        return span.end_line_end;
    }
    if (comptime std.mem.eql(u8, name, "queries")) {
        const span = (try findRegion(text, "features")) orelse return error.NoAnchor;
        return span.end_line_end;
    }
    if (comptime std.mem.eql(u8, name, "main-activity")) {
        // Before </activity> of OrielMainActivity.
        var it: Scanner = .{ .text = text };
        while (try it.next()) |node| {
            if (node.kind != .start or !std.mem.eql(u8, node.name, "activity")) continue;
            const n = attribute(text[node.start..node.end], "android:name") orelse continue;
            if (!std.mem.eql(u8, n, "dev.oriel.OrielMainActivity")) continue;
            if (node.self_closing) return error.NoAnchor;
            const end = try elementEnd(text, node);
            const close = std.mem.lastIndexOf(u8, text[0..end], "</") orelse return error.MalformedXml;
            return lineStart(text, close);
        }
        return error.NoAnchor;
    }
    if (comptime std.mem.eql(u8, name, "components")) {
        // Before </application>.
        const close = std.mem.lastIndexOf(u8, text, "</application>") orelse return error.NoAnchor;
        return lineStart(text, close);
    }
    @compileError("no anchor for region " ++ name);
}

/// Runs of blank lines (left where migrated entries were) become one.
fn collapseBlankLines(text: *std.ArrayList(u8)) void {
    const t = text.items;
    var w: usize = 0;
    var r: usize = 0;
    while (r < t.len) {
        if (t[r] == '\n') {
            // The newlines that follow with only blanks between them.
            var j = r + 1;
            var last_nl = r;
            var count: usize = 1;
            while (j < t.len and (t[j] == ' ' or t[j] == '\t' or t[j] == '\r' or t[j] == '\n')) : (j += 1) {
                if (t[j] == '\n') {
                    count += 1;
                    last_nl = j;
                }
            }
            if (count >= 3) {
                t[w] = '\n';
                t[w + 1] = '\n';
                w += 2;
                r = last_nl + 1;
                continue;
            }
        }
        t[w] = t[r];
        w += 1;
        r += 1;
    }
    text.shrinkRetainingCapacity(w);
}

// ---------------------------------------------------------------------------
// A minimal XML scanner (manifests: tags, attributes, comments)
// ---------------------------------------------------------------------------

const Node = struct {
    kind: enum { comment, start, end, other },
    /// The '<'.
    start: usize,
    /// After the '>'.
    end: usize,
    /// The tag's name (start and end tags).
    name: []const u8 = "",
    self_closing: bool = false,
    /// The elements open around this node.
    depth: usize = 0,
};

const Scanner = struct {
    text: []const u8,
    pos: usize = 0,
    /// Open elements.
    depth: usize = 0,

    fn next(s: *Scanner) Error!?Node {
        const t = s.text;
        const lt = std.mem.indexOfScalarPos(u8, t, s.pos, '<') orelse return null;
        if (std.mem.startsWith(u8, t[lt..], "<!--")) {
            const close = std.mem.indexOfPos(u8, t, lt + 4, "-->") orelse return error.MalformedXml;
            s.pos = close + 3;
            return .{ .kind = .comment, .start = lt, .end = s.pos };
        }
        if (std.mem.startsWith(u8, t[lt..], "<?") or std.mem.startsWith(u8, t[lt..], "<!")) {
            const gt = std.mem.indexOfScalarPos(u8, t, lt, '>') orelse return error.MalformedXml;
            s.pos = gt + 1;
            return .{ .kind = .other, .start = lt, .end = s.pos };
        }
        const closing = lt + 1 < t.len and t[lt + 1] == '/';
        const name_start = lt + 1 + @intFromBool(closing);
        var i = name_start;
        while (i < t.len and !isSpace(t[i]) and t[i] != '/' and t[i] != '>') : (i += 1) {}
        const name = t[name_start..i];
        // To the '>', past quoted attribute values.
        var quote: ?u8 = null;
        while (i < t.len) : (i += 1) {
            const c = t[i];
            if (quote) |q| {
                if (c == q) quote = null;
            } else if (c == '"' or c == '\'') {
                quote = c;
            } else if (c == '>') break;
        }
        if (i >= t.len) return error.MalformedXml;
        s.pos = i + 1;
        if (closing) {
            s.depth -|= 1;
            return .{ .kind = .end, .start = lt, .end = s.pos, .name = name, .depth = s.depth };
        }
        const self_closing = t[i - 1] == '/';
        const depth = s.depth;
        if (!self_closing) s.depth += 1;
        return .{ .kind = .start, .start = lt, .end = s.pos, .name = name, .self_closing = self_closing, .depth = depth };
    }
};

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

/// After the end tag of the element `start` opens (or after `start` itself
/// when it is self-closing).
fn elementEnd(text: []const u8, start: Node) Error!usize {
    if (start.self_closing) return start.end;
    var it: Scanner = .{ .text = text, .pos = start.end };
    var depth: usize = 1;
    while (try it.next()) |node| switch (node.kind) {
        .start => if (!node.self_closing) {
            depth += 1;
        },
        .end => {
            depth -= 1;
            if (depth == 0) return node.end;
        },
        else => {},
    };
    return error.MalformedXml;
}

/// The value of `name="..."` in a start tag.
fn attribute(tag: []const u8, name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, tag, pos, name)) |at| {
        pos = at + name.len;
        if (at == 0 or !isSpace(tag[at - 1])) continue;
        var i = at + name.len;
        while (i < tag.len and isSpace(tag[i])) : (i += 1) {}
        if (i >= tag.len or tag[i] != '=') continue;
        i += 1;
        while (i < tag.len and isSpace(tag[i])) : (i += 1) {}
        if (i >= tag.len or (tag[i] != '"' and tag[i] != '\'')) continue;
        const q = tag[i];
        const end = std.mem.indexOfScalarPos(u8, tag, i + 1, q) orelse return null;
        return tag[i + 1 .. end];
    }
    return null;
}

/// Elements one per android:name: the developer's declaration of one makes
/// a generated one redundant.
const named_tags = [_][]const u8{ "uses-permission", "uses-permission-sdk-23", "uses-feature", "activity", "activity-alias", "service", "receiver", "provider" };

fn isNamedTag(tag: []const u8) bool {
    for (named_tags) |n| if (std.mem.eql(u8, n, tag)) return true;
    return false;
}

const Key = struct { tag: []const u8, name: []const u8 };

fn keyOf(text: []const u8, node: Node) ?Key {
    if (node.kind != .start or !isNamedTag(node.name)) return null;
    const name = attribute(text[node.start..node.end], "android:name") orelse return null;
    return .{ .tag = node.name, .name = name };
}

fn keyIn(keys: []const Key, k: Key) bool {
    for (keys) |have| if (std.mem.eql(u8, have.tag, k.tag) and std.mem.eql(u8, have.name, k.name)) return true;
    return false;
}

/// A generated entry: a comment or an element, as text, and its key.
const Item = struct { text: []const u8, key: ?Key };

/// The top-level comments and elements of a region's content.
fn collectItems(gpa: Allocator, content: []const u8, out: *std.ArrayList(Item)) Error!void {
    var it: Scanner = .{ .text = content };
    while (try it.next()) |node| switch (node.kind) {
        .comment => try out.append(gpa, .{ .text = content[node.start..node.end], .key = null }),
        .start => {
            const end = try elementEnd(content, node);
            try out.append(gpa, .{ .text = content[node.start..end], .key = keyOf(content, node) });
            it.pos = end;
            it.depth = 0;
        },
        else => {},
    };
}

/// Equal but for whitespace (between attributes, around `<`, `>`, `/`, `=`).
fn sameXml(a: []const u8, b: []const u8) bool {
    var x: Normalized = .{ .text = a };
    var y: Normalized = .{ .text = b };
    while (true) {
        const cx = x.next();
        const cy = y.next();
        if (cx != cy) return false;
        if (cx == null) return true;
    }
}

/// The characters of XML text with each run of whitespace as one space,
/// none at the ends or next to punctuation.
const Normalized = struct {
    text: []const u8,
    pos: usize = 0,
    prev: u8 = '<',

    fn next(n: *Normalized) ?u8 {
        const t = n.text;
        if (n.pos < t.len and isSpace(t[n.pos])) {
            while (n.pos < t.len and isSpace(t[n.pos])) n.pos += 1;
            if (n.pos < t.len and !isPunct(t[n.pos]) and !isPunct(n.prev)) {
                n.prev = ' ';
                return ' ';
            }
        }
        if (n.pos >= t.len) return null;
        n.prev = t[n.pos];
        n.pos += 1;
        return n.prev;
    }
};

fn isPunct(c: u8) bool {
    return c == '<' or c == '>' or c == '/' or c == '=';
}

/// Remove the comments and elements outside the regions that are one of
/// `items` (or declare the same named element), with their lines when they
/// stand alone on them.
fn removeMatching(gpa: Allocator, text: *std.ArrayList(u8), items: []const Item) Error!void {
    var it: Scanner = .{ .text = text.items };
    while (try it.next()) |node| {
        if (node.kind != .comment and node.kind != .start) continue;
        if (node.kind == .comment and isMarker(text.items[node.start..node.end])) {
            // Skip a present region's content.
            const inner = text.items[node.start..node.end];
            if (std.mem.endsWith(u8, inner, " begin -->")) {
                const end_marker = try std.fmt.allocPrint(gpa, "{s} end -->", .{inner[0 .. inner.len - " begin -->".len]});
                defer gpa.free(end_marker);
                const e = std.mem.indexOfPos(u8, text.items, node.end, end_marker) orelse return error.MalformedRegion;
                it.pos = e;
            }
            continue;
        }
        const end = if (node.kind == .comment) node.end else try elementEnd(text.items, node);
        const candidate = text.items[node.start..end];
        const key = keyOf(text.items, node);
        const match = for (items) |item| {
            if (sameXml(item.text, candidate)) break true;
            if (key != null and item.key != null and std.mem.eql(u8, key.?.tag, item.key.?.tag) and std.mem.eql(u8, key.?.name, item.key.?.name)) break true;
        } else false;
        if (!match) continue;
        const span = wholeLines(text.items, node.start, end);
        text.replaceRangeAssumeCapacity(span[0], span[1] - span[0], "");
        it = .{ .text = text.items, .pos = span[0], .depth = it.depth -| @intFromBool(node.kind == .start and !node.self_closing) };
    }
}

fn isMarker(comment: []const u8) bool {
    return std.mem.startsWith(u8, comment, "<!-- oriel:") and
        (std.mem.endsWith(u8, comment, " begin -->") or std.mem.endsWith(u8, comment, " end -->"));
}

/// [a, b) widened to its lines when nothing else is on them.
fn wholeLines(text: []const u8, a: usize, b: usize) [2]usize {
    const ls = lineStart(text, a);
    for (text[ls..a]) |c| if (!isSpace(c)) return .{ a, b };
    var e = b;
    while (e < text.len and text[e] != '\n') : (e += 1) if (!isSpace(text[e])) return .{ a, b };
    return .{ ls, if (e < text.len) e + 1 else e };
}

/// The named elements declared outside the regions.
fn collectOutsideKeys(gpa: Allocator, text: []const u8, out: *std.ArrayList(Key)) Error!void {
    var it: Scanner = .{ .text = text };
    while (try it.next()) |node| {
        if (node.kind == .comment and isMarker(text[node.start..node.end])) {
            const inner = text[node.start..node.end];
            if (std.mem.endsWith(u8, inner, " begin -->")) {
                const end_marker = try std.fmt.allocPrint(gpa, "{s} end -->", .{inner[0 .. inner.len - " begin -->".len]});
                defer gpa.free(end_marker);
                it.pos = std.mem.indexOfPos(u8, text, node.end, end_marker) orelse return error.MalformedRegion;
            }
            continue;
        }
        if (keyOf(text, node)) |k| try out.append(gpa, k);
    }
}

/// `content` without the top-level elements whose key is in `declared`.
fn dropDeclared(gpa: Allocator, content: []const u8, declared: []const Key) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, content);
    var it: Scanner = .{ .text = out.items };
    while (try it.next()) |node| {
        if (node.kind != .start) continue;
        const end = try elementEnd(out.items, node);
        if (keyOf(out.items, node)) |k| if (keyIn(declared, k)) {
            const span = wholeLines(out.items, node.start, end);
            out.replaceRangeAssumeCapacity(span[0], span[1] - span[0], "");
            it = .{ .text = out.items, .pos = span[0] };
            continue;
        };
        it.pos = end;
        it.depth = 0;
    }
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const TestDeclared = struct {
    microphone: ?[]const u8 = null,
    camera: ?[]const u8 = null,
    location: ?[]const u8 = null,
    notifications: ?[]const u8 = null,
    bluetooth: ?[]const u8 = null,
    local_network: ?[]const u8 = null,
};

test "permissionsXml: one line per permission, in table order" {
    const gpa = testing.allocator;
    const xml = try permissionsXml(gpa, TestDeclared{ .microphone = "", .notifications = "why" });
    defer gpa.free(xml);
    try testing.expectEqualStrings(
        \\    <uses-permission android:name="android.permission.RECORD_AUDIO" />
        \\    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
        \\    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MICROPHONE" />
        \\    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
        \\
    , xml);
    const none = try permissionsXml(gpa, TestDeclared{});
    defer gpa.free(none);
    try testing.expectEqualStrings("", none);
}

test "permissionsXml: bluetooth's roles, legacy permissions and location up to API 30" {
    const gpa = testing.allocator;
    const xml = try permissionsXml(gpa, TestDeclared{ .bluetooth = "" });
    defer gpa.free(xml);
    try testing.expectEqualStrings(
        \\    <uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation" />
        \\    <uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE" />
        \\    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
        \\    <uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
        \\    <uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />
        \\    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="30" />
        \\
    , xml);
    const features = try featuresXml(gpa, TestDeclared{ .bluetooth = "" });
    defer gpa.free(features);
    try testing.expectEqualStrings("    <uses-feature android:name=\"android.hardware.bluetooth_le\" android:required=\"false\" />\n", features);
}

test "permissionsFor: location and bluetooth merge into an unrestricted ACCESS_FINE_LOCATION" {
    const gpa = testing.allocator;
    const perms = try permissionsFor(gpa, TestDeclared{ .location = "", .bluetooth = "" });
    defer gpa.free(perms);
    var fine: usize = 0;
    for (perms) |p| if (std.mem.eql(u8, p.name, "android.permission.ACCESS_FINE_LOCATION")) {
        fine += 1;
        try testing.expectEqual(@as(?u32, null), p.max_sdk);
    };
    try testing.expectEqual(@as(usize, 1), fine);
}

test "permissionsFor: local_network's normal permissions; kinds the struct lacks are skipped" {
    const gpa = testing.allocator;
    const perms = try permissionsFor(gpa, TestDeclared{ .local_network = "" });
    defer gpa.free(perms);
    try testing.expectEqual(@as(usize, 3), perms.len);
    try testing.expectEqualStrings("android.permission.CHANGE_WIFI_MULTICAST_STATE", perms[2].name);
    const Old = struct { microphone: ?[]const u8 = null };
    const old = try permissionsFor(gpa, Old{ .microphone = "" });
    defer gpa.free(old);
    try testing.expectEqual(@as(usize, 3), old.len);
}

test "permissionsXmlWithExtras: extras after the generated entries, one per name" {
    const gpa = testing.allocator;
    const xml = try permissionsXmlWithExtras(gpa, TestDeclared{ .bluetooth = "" }, &.{
        .{ .name = "android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE" },
        // Already there with maxSdkVersion 30: the extra lifts it.
        .{ .name = "android.permission.BLUETOOTH" },
        // Already there: the generated entry stays (its flags too).
        .{ .name = "android.permission.BLUETOOTH_SCAN", .max_sdk = 32 },
        // Already there with the same max_sdk: unchanged.
        .{ .name = "android.permission.BLUETOOTH_ADMIN", .max_sdk = 30 },
        // Twice among the extras: once.
        .{ .name = "android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE", .max_sdk = 33 },
        .{ .name = "android.permission.WAKE_LOCK", .max_sdk = 28, .flags = "x" },
    });
    defer gpa.free(xml);
    try testing.expectEqualStrings(
        \\    <uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation" />
        \\    <uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE" />
        \\    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
        \\    <uses-permission android:name="android.permission.BLUETOOTH" />
        \\    <uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />
        \\    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="30" />
        \\    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE" />
        \\    <uses-permission android:name="android.permission.WAKE_LOCK" android:maxSdkVersion="28" android:usesPermissionFlags="x" />
        \\
    , xml);

    // Nothing declared: only the extras.
    const only = try permissionsXmlWithExtras(gpa, TestDeclared{}, &.{.{ .name = "android.permission.VIBRATE" }});
    defer gpa.free(only);
    try testing.expectEqualStrings("    <uses-permission android:name=\"android.permission.VIBRATE\" />\n", only);
}

test "featuresXmlWithExtras: merged by name, required if either requires it" {
    const gpa = testing.allocator;
    const xml = try featuresXmlWithExtras(gpa, TestDeclared{ .bluetooth = "" }, &.{
        .{ .name = "android.hardware.bluetooth_le", .required = true },
        .{ .name = "android.hardware.camera.any" },
        .{ .name = "android.hardware.camera.any", .required = false },
    });
    defer gpa.free(xml);
    try testing.expectEqualStrings(
        \\    <uses-feature android:name="android.hardware.bluetooth_le" android:required="true" />
        \\    <uses-feature android:name="android.hardware.camera.any" android:required="false" />
        \\
    , xml);
}

test "extras: names that would break the XML are rejected" {
    const gpa = testing.allocator;
    for ([_][]const u8{ "", "a\"b", "a<b", "a>b", "a&b", "a'b", "a b", "a\nb" }) |bad| {
        try testing.expect(!validName(bad));
        try testing.expectError(error.InvalidName, permissionsXmlWithExtras(gpa, TestDeclared{}, &.{.{ .name = bad }}));
        try testing.expectError(error.InvalidName, featuresXmlWithExtras(gpa, TestDeclared{}, &.{.{ .name = bad }}));
    }
    try testing.expectError(error.InvalidName, permissionsXmlWithExtras(gpa, TestDeclared{}, &.{.{ .name = "a.b", .flags = "x\"" }}));
    try testing.expect(validName("android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE"));
    try testing.expect(validName("com.example.permission.C2D_MESSAGE"));
}

/// A template like android/template's, rendered.
const test_template =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    \\
    \\    <uses-permission android:name="android.permission.INTERNET" />
    \\    <!-- oriel:permissions begin -->
    \\    <uses-permission android:name="android.permission.CAMERA" />
    \\    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
    \\    <!-- oriel:permissions end -->
    \\    <!-- oriel:features begin -->
    \\    <!-- oriel:features end -->
    \\    <!-- oriel:queries begin -->
    \\    <!-- Speech services. -->
    \\    <queries>
    \\        <intent>
    \\            <action android:name="android.speech.RecognitionService" />
    \\        </intent>
    \\    </queries>
    \\    <!-- oriel:queries end -->
    \\
    \\    <application android:label="x">
    \\        <activity
    \\            android:name="dev.oriel.OrielMainActivity"
    \\            android:exported="true">
    \\            <layout android:minWidth="360dp" />
    \\            <!-- oriel:main-activity begin -->
    \\            <intent-filter>
    \\                <action android:name="android.intent.action.VIEW" />
    \\                <data android:scheme="demo" />
    \\            </intent-filter>
    \\            <!-- oriel:main-activity end -->
    \\        </activity>
    \\
    \\        <!-- oriel:components begin -->
    \\        <service
    \\            android:name="dev.oriel.OrielTileService"
    \\            android:label="New label" />
    \\        <!-- oriel:components end -->
    \\        <provider android:name="dev.oriel.OrielFileProvider" />
    \\    </application>
    \\</manifest>
    \\
;

test "sync: the template itself is left as it is" {
    const gpa = testing.allocator;
    const out = try sync(gpa, test_template, test_template);
    defer gpa.free(out.text);
    try testing.expect(!out.migrated);
    try testing.expectEqualStrings(test_template, out.text);
}

test "sync: rewrites only the regions; the developer's edits outside stay" {
    const gpa = testing.allocator;
    const current =
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<!-- My app. -->
        \\<manifest xmlns:android="http://schemas.android.com/apk/res/android">
        \\
        \\    <uses-permission android:name="android.permission.INTERNET" />
        \\    <uses-permission android:name="android.permission.VIBRATE" />
        \\    <!-- oriel:permissions begin -->
        \\    <uses-permission android:name="android.permission.RECORD_AUDIO" />
        \\    <!-- oriel:permissions end -->
        \\    <!-- oriel:features begin -->
        \\    <!-- oriel:features end -->
        \\    <!-- oriel:queries begin -->
        \\    <!-- oriel:queries end -->
        \\
        \\    <application android:label="mine">
        \\        <activity
        \\            android:name="dev.oriel.OrielMainActivity"
        \\            android:exported="true">
        \\            <!-- oriel:main-activity begin -->
        \\            <!-- oriel:main-activity end -->
        \\            <intent-filter android:label="my own" />
        \\        </activity>
        \\        <!-- oriel:components begin -->
        \\        <service android:name="dev.oriel.OrielTileService" android:label="Old label" />
        \\        <!-- oriel:components end -->
        \\        <service android:name="com.example.Mine" />
        \\    </application>
        \\</manifest>
        \\
    ;
    const out = try sync(gpa, current, test_template);
    defer gpa.free(out.text);
    try testing.expect(!out.migrated);
    try testing.expectEqualStrings(
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<!-- My app. -->
        \\<manifest xmlns:android="http://schemas.android.com/apk/res/android">
        \\
        \\    <uses-permission android:name="android.permission.INTERNET" />
        \\    <uses-permission android:name="android.permission.VIBRATE" />
        \\    <!-- oriel:permissions begin -->
        \\    <uses-permission android:name="android.permission.CAMERA" />
        \\    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
        \\    <!-- oriel:permissions end -->
        \\    <!-- oriel:features begin -->
        \\    <!-- oriel:features end -->
        \\    <!-- oriel:queries begin -->
        \\    <!-- Speech services. -->
        \\    <queries>
        \\        <intent>
        \\            <action android:name="android.speech.RecognitionService" />
        \\        </intent>
        \\    </queries>
        \\    <!-- oriel:queries end -->
        \\
        \\    <application android:label="mine">
        \\        <activity
        \\            android:name="dev.oriel.OrielMainActivity"
        \\            android:exported="true">
        \\            <!-- oriel:main-activity begin -->
        \\            <intent-filter>
        \\                <action android:name="android.intent.action.VIEW" />
        \\                <data android:scheme="demo" />
        \\            </intent-filter>
        \\            <!-- oriel:main-activity end -->
        \\            <intent-filter android:label="my own" />
        \\        </activity>
        \\        <!-- oriel:components begin -->
        \\        <service
        \\            android:name="dev.oriel.OrielTileService"
        \\            android:label="New label" />
        \\        <!-- oriel:components end -->
        \\        <service android:name="com.example.Mine" />
        \\    </application>
        \\</manifest>
        \\
    , out.text);
    // Idempotent.
    const again = try sync(gpa, out.text, test_template);
    defer gpa.free(again.text);
    try testing.expectEqualStrings(out.text, again.text);
}

test "sync: a permission the developer declares outside the regions isn't generated again" {
    const gpa = testing.allocator;
    const current = try std.mem.replaceOwned(u8, gpa, test_template,
        \\    <uses-permission android:name="android.permission.INTERNET" />
        \\
    ,
        \\    <uses-permission android:name="android.permission.INTERNET" />
        \\    <uses-permission android:name="android.permission.CAMERA" android:required="false" />
        \\
    );
    defer gpa.free(current);
    const out = try sync(gpa, current, test_template);
    defer gpa.free(out.text);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.text, "android.permission.CAMERA"));
    try testing.expect(std.mem.indexOf(u8, out.text, "android:required=\"false\"") != null);
}

test "sync: broken markers are an error" {
    const gpa = testing.allocator;
    const no_end = try std.mem.replaceOwned(u8, gpa, test_template, "    <!-- oriel:features end -->\n", "");
    defer gpa.free(no_end);
    try testing.expectError(error.MalformedRegion, sync(gpa, no_end, test_template));
    const twice = try std.mem.replaceOwned(u8, gpa, test_template, "    <!-- oriel:features end -->\n", "    <!-- oriel:features end -->\n    <!-- oriel:features end -->\n");
    defer gpa.free(twice);
    try testing.expectError(error.MalformedRegion, sync(gpa, twice, test_template));
    try testing.expectError(error.TemplateMissingRegion, sync(gpa, test_template, no_end));
}

test "sync: migrates a manifest written before the markers" {
    const gpa = testing.allocator;
    // What the template without markers rendered: Oriel's entries inline
    // (the tile's label since changed in build.zig).
    const old =
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<manifest xmlns:android="http://schemas.android.com/apk/res/android">
        \\
        \\    <uses-permission android:name="android.permission.INTERNET" />
        \\    <uses-permission android:name="android.permission.CAMERA" />
        \\    <uses-permission android:name="android.permission.RECORD_AUDIO" />
        \\
        \\    <!-- Speech services. -->
        \\    <queries>
        \\        <intent>
        \\            <action android:name="android.speech.RecognitionService" />
        \\        </intent>
        \\    </queries>
        \\
        \\    <application android:label="x">
        \\        <activity
        \\            android:name="dev.oriel.OrielMainActivity"
        \\            android:exported="true">
        \\            <layout android:minWidth="360dp" />
        \\            <intent-filter>
        \\                <action android:name="android.intent.action.VIEW" />
        \\                <data android:scheme="demo" />
        \\            </intent-filter>
        \\        </activity>
        \\
        \\        <service
        \\            android:name="dev.oriel.OrielTileService"
        \\            android:label="Old label" />
        \\
        \\        <provider android:name="dev.oriel.OrielFileProvider" />
        \\    </application>
        \\</manifest>
        \\
    ;
    const out = try sync(gpa, old, test_template);
    defer gpa.free(out.text);
    try testing.expect(out.migrated);
    // RECORD_AUDIO isn't generated by this build, so it is the developer's
    // now; the rest moved into the regions.
    try testing.expectEqualStrings(
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<manifest xmlns:android="http://schemas.android.com/apk/res/android">
        \\
        \\    <uses-permission android:name="android.permission.INTERNET" />
        \\    <uses-permission android:name="android.permission.RECORD_AUDIO" />
        \\    <!-- oriel:permissions begin -->
        \\    <uses-permission android:name="android.permission.CAMERA" />
        \\    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
        \\    <!-- oriel:permissions end -->
        \\    <!-- oriel:features begin -->
        \\    <!-- oriel:features end -->
        \\    <!-- oriel:queries begin -->
        \\    <!-- Speech services. -->
        \\    <queries>
        \\        <intent>
        \\            <action android:name="android.speech.RecognitionService" />
        \\        </intent>
        \\    </queries>
        \\    <!-- oriel:queries end -->
        \\
        \\    <application android:label="x">
        \\        <activity
        \\            android:name="dev.oriel.OrielMainActivity"
        \\            android:exported="true">
        \\            <layout android:minWidth="360dp" />
        \\            <!-- oriel:main-activity begin -->
        \\            <intent-filter>
        \\                <action android:name="android.intent.action.VIEW" />
        \\                <data android:scheme="demo" />
        \\            </intent-filter>
        \\            <!-- oriel:main-activity end -->
        \\        </activity>
        \\
        \\        <provider android:name="dev.oriel.OrielFileProvider" />
        \\        <!-- oriel:components begin -->
        \\        <service
        \\            android:name="dev.oriel.OrielTileService"
        \\            android:label="New label" />
        \\        <!-- oriel:components end -->
        \\    </application>
        \\</manifest>
        \\
    , out.text);
    const again = try sync(gpa, out.text, test_template);
    defer gpa.free(again.text);
    try testing.expect(!again.migrated);
    try testing.expectEqualStrings(out.text, again.text);
}

test "sync: migrating without OrielMainActivity is an error" {
    const gpa = testing.allocator;
    const current =
        \\<manifest xmlns:android="http://schemas.android.com/apk/res/android">
        \\    <application>
        \\    </application>
        \\</manifest>
        \\
    ;
    try testing.expectError(error.NoAnchor, sync(gpa, current, test_template));
}

test attribute {
    try testing.expectEqualStrings("a.B", attribute("<service\n  android:name = 'a.B' />", "android:name").?);
    try testing.expectEqual(@as(?[]const u8, null), attribute("<service xandroid:name=\"a\" />", "android:name"));
}

test sameXml {
    try testing.expect(sameXml("<a  x=\"1\"/>", "<a x=\"1\" />"));
    try testing.expect(sameXml("<a>\n  <b/>\n</a>", "<a><b/></a>"));
    try testing.expect(!sameXml("<a x=\"1\"/>", "<a x=\"2\"/>"));
    try testing.expect(!sameXml("<a b c/>", "<a bc/>"));
}

/// Safe qualified class references for generated Kotlin extension registration.
/// Constructors are invoked directly, so R8 sees the references without rules.
pub fn extensionClassValid(name: []const u8) bool {
    if (name.len == 0 or name.len > 512) return false;
    var parts = std.mem.splitScalar(u8, name, '.');
    var count: usize = 0;
    while (parts.next()) |part| {
        if (part.len == 0 or part.len > 128) return false;
        if (!std.ascii.isAlphabetic(part[0]) and part[0] != '_') return false;
        for (part[1..]) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
        count += 1;
    }
    return count >= 2;
}

test "Android extension class references cannot inject Kotlin" {
    try std.testing.expect(extensionClassValid("dev.example.CameraExtension"));
    try std.testing.expect(extensionClassValid("dev.example.Outer.NestedExtension"));
    inline for (.{ "", "Extension", ".dev.Extension", "dev..Extension", "dev.Extension.", "dev.123", "dev.Extension()", "dev.Extension);evil()", "dev.Extension\n", "dev.foo/bar" }) |name| {
        try std.testing.expect(!extensionClassValid(name));
    }
}

/// Bounded Maven coordinates safe to embed in a generated Kotlin string.
pub fn mavenCoordinateValid(value: []const u8) bool {
    if (value.len == 0 or value.len > 256) return false;
    var parts: usize = 1;
    var length: usize = 0;
    for (value) |ch| {
        if (ch == ':') {
            if (length == 0) return false;
            parts += 1;
            length = 0;
        } else {
            if (!std.ascii.isAlphanumeric(ch) and ch != '.' and ch != '_' and ch != '-') return false;
            length += 1;
        }
    }
    return parts == 3 and length > 0;
}

test "Maven coordinates exclude Gradle code and floating versions" {
    try std.testing.expect(mavenCoordinateValid("com.google.mlkit:genai-prompt:1.0.0-beta4"));
    for ([_][]const u8{ "a:b", "a::c", "a:b:c:d", "a:b:1.+", "a:b:1\"", "a:b:1\n" }) |value|
        try std.testing.expect(!mavenCoordinateValid(value));
}
