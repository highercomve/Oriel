//! Common types and options for file dialogs, and the pure parts of folder
//! access (names, ids) every backend shares.

const std = @import("std");

pub const OpenOptions = struct {
    title: []const u8 = "Open File",
    modal: bool = true,
};

pub const SaveOptions = struct {
    title: []const u8 = "Save File",
    modal: bool = true,
};

pub const FolderOptions = struct {
    title: []const u8 = "Choose a Folder",
    modal: bool = true,
};

/// A folder the user picked, with write access that lasts across restarts.
/// `id` is opaque: store it as is (settings, the store) and hand it back to
/// `folderName`, `saveToFolder` and `forgetFolder`. It is the absolute path
/// on desktops and the SAF tree URI on Android. Both fields are allocated
/// with the allocator given to `openFolder`.
pub const Folder = struct {
    id: []u8,
    /// For display ("Downloads").
    name: []u8,

    pub fn deinit(self: Folder, gpa: std.mem.Allocator) void {
        gpa.free(self.id);
        gpa.free(self.name);
    }
};

pub const FolderError = error{
    /// The access was revoked, the folder was removed (or its volume is
    /// gone), or `id` is not one `openFolder` returned.
    FolderUnavailable,
    /// A name with a path separator, empty, "." or "..".
    InvalidName,
    /// The platform has no folder picker yet.
    Unsupported,
};

/// Whether `name` is a plain file name: no separators (either kind, so a
/// name means the same on every OS), not empty, not "." or "..", no NUL.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 255) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    return std.mem.indexOfAny(u8, name, "/\\\x00") == null;
}

/// `name` with " (n)" before its extension: "photo.jpg" -> "photo (2).jpg",
/// "notes" -> "notes (2)", ".bashrc" -> ".bashrc (2)" (a leading dot starts
/// no extension), as Android's DocumentsProvider and file managers do.
pub fn numberedName(buf: []u8, name: []const u8, n: u32) error{NoSpaceLeft}![]u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.');
    const split = if (dot) |d| (if (d == 0) name.len else d) else name.len;
    return std.fmt.bufPrint(buf, "{s} ({d}){s}", .{ name[0..split], n, name[split..] });
}

/// Folder ids on Android: a SAF tree URI (`content://<authority>/tree/<id>`,
/// from ACTION_OPEN_DOCUMENT_TREE).
pub fn isTreeUri(id: []const u8) bool {
    const scheme = "content://";
    if (!std.mem.startsWith(u8, id, scheme)) return false;
    const rest = id[scheme.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return false;
    if (slash == 0) return false;
    const path = rest[slash..];
    return std.mem.startsWith(u8, path, "/tree/") and path.len > "/tree/".len and
        std.mem.indexOfAny(u8, id, "\n\x00") == null;
}

/// The display name for a desktop folder path: its last component, or the
/// path itself for a root ("/", "C:\").
pub fn pathName(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    return if (base.len == 0) path else base;
}

/// The Android picker's answer, "uri\nname": a URI never holds a raw newline.
pub fn splitPicked(data: []const u8) ?struct { id: []const u8, name: []const u8 } {
    const nl = std.mem.indexOfScalar(u8, data, '\n') orelse return null;
    const id = data[0..nl];
    if (!isTreeUri(id)) return null;
    return .{ .id = id, .name = data[nl + 1 ..] };
}

test {
    std.testing.refAllDecls(@This());
}

test validName {
    try std.testing.expect(validName("photo.jpg"));
    try std.testing.expect(validName(".bashrc"));
    try std.testing.expect(validName("a b (1).txt"));
    try std.testing.expect(!validName(""));
    try std.testing.expect(!validName("."));
    try std.testing.expect(!validName(".."));
    try std.testing.expect(!validName("../x"));
    try std.testing.expect(!validName("dir/x"));
    try std.testing.expect(!validName("dir\\x"));
    try std.testing.expect(!validName("x\x00y"));
}

test numberedName {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("photo (1).jpg", try numberedName(&buf, "photo.jpg", 1));
    try std.testing.expectEqualStrings("notes (12)", try numberedName(&buf, "notes", 12));
    try std.testing.expectEqualStrings(".bashrc (2)", try numberedName(&buf, ".bashrc", 2));
    try std.testing.expectEqualStrings("archive.tar (3).gz", try numberedName(&buf, "archive.tar.gz", 3));
    var tiny: [4]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, numberedName(&tiny, "photo.jpg", 1));
}

test isTreeUri {
    try std.testing.expect(isTreeUri("content://com.android.externalstorage.documents/tree/primary%3ADownload"));
    try std.testing.expect(!isTreeUri("content://com.android.externalstorage.documents/document/primary%3ADownload"));
    try std.testing.expect(!isTreeUri("content://com.android.externalstorage.documents/tree/"));
    try std.testing.expect(!isTreeUri("content:///tree/x"));
    try std.testing.expect(!isTreeUri("/sdcard/Download"));
    try std.testing.expect(!isTreeUri("file:///tree/x"));
    try std.testing.expect(!isTreeUri("content://a/tree/x\ny"));
}

test pathName {
    try std.testing.expectEqualStrings("Downloads", pathName("/home/me/Downloads"));
    try std.testing.expectEqualStrings("Downloads", pathName("/home/me/Downloads/"));
    try std.testing.expectEqualStrings("/", pathName("/"));
}

test splitPicked {
    const p = splitPicked("content://a.b/tree/primary%3ADownload\nDownload").?;
    try std.testing.expectEqualStrings("content://a.b/tree/primary%3ADownload", p.id);
    try std.testing.expectEqualStrings("Download", p.name);
    try std.testing.expect(splitPicked("content://a.b/tree/x") == null);
    try std.testing.expect(splitPicked("/home/x\nx") == null);
}
