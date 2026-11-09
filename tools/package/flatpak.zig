//! Flatpak bundles (`package-flatpak`): the app's executable, desktop entry,
//! icons and AppStream metainfo in a build directory, finished, exported
//! and bundled with the `flatpak` command alone. No SDK, no
//! flatpak-builder: the executable is already built, so nothing compiles in
//! the sandbox.
//!
//! The build directory is what `flatpak build-init` makes (it would need
//! the SDK installed only to record its name):
//!
//!     metadata                       [Application] name, runtime, sdk, command
//!     files/bin/<exe>                plus `--extra-exe` / `--extra-file`
//!     files/share/applications/<id>.desktop
//!     files/share/icons/hicolor/<n>x<n>/apps/<id>.png
//!     files/share/metainfo/<id>.metainfo.xml
//!
//! then `flatpak build-finish` (sandbox permissions, exports),
//! `flatpak build-export` (a local OSTree repo) and `flatpak build-bundle`
//! (the single-file `.flatpak`, pointing at Flathub for the runtime).

const std = @import("std");

/// The runtime every Oriel app runs on: GTK 4 and WebKitGTK 6.0, the
/// libraries Oriel links.
pub const runtime = "org.gnome.Platform";
pub const sdk = "org.gnome.Sdk";
/// Where `flatpak install` finds the runtime when it isn't installed.
pub const runtime_repo = "https://dl.flathub.org/repo/flathub.flatpakrepo";

/// Sandbox permissions every windowed app needs: a display, shared memory
/// for X11 and GPU access.
pub const base_finish_args = [_][]const u8{
    "--socket=wayland",
    "--socket=fallback-x11",
    "--share=ipc",
    "--device=dri",
};

/// What the app is built with (Oriel features and declared permission
/// kinds) that needs a hole in the sandbox.
pub const Needs = struct {
    network: bool = false,
    tray: bool = false,
    audio: bool = false,
    bluetooth: bool = false,
};

/// The `--finish-arg`s for `needs`, base ones first. File dialogs,
/// notifications and global shortcuts go through portals and need none.
pub fn finishArgs(needs: Needs, out: *std.ArrayList([]const u8), gpa: std.mem.Allocator) !void {
    try out.ensureUnusedCapacity(gpa, base_finish_args.len + 4);
    out.appendSliceAssumeCapacity(&base_finish_args);
    if (needs.network) out.appendAssumeCapacity("--share=network");
    // The tray's StatusNotifierItem registers with the watcher on the session bus.
    if (needs.tray) out.appendAssumeCapacity("--talk-name=org.kde.StatusNotifierWatcher");
    if (needs.audio) out.appendAssumeCapacity("--socket=pulseaudio");
    if (needs.bluetooth) out.appendAssumeCapacity("--system-talk-name=org.bluez");
}

pub const ValidationError = error{
    InvalidRuntimeVersion,
    InvalidFinishArg,
    InvalidText,
};

/// A runtime branch ("50", "49", "master"): what `flatpak` accepts in a ref.
pub fn validateRuntimeVersion(v: []const u8) ValidationError!void {
    if (v.len == 0 or v.len > 64) return error.InvalidRuntimeVersion;
    for (v) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '.' and ch != '_' and ch != '-') return error.InvalidRuntimeVersion;
    }
}

/// A `flatpak build-finish` option: `--name[=value]`, one line, no spaces
/// around it. Passed as its own argv entry, never through a shell.
pub fn validateFinishArg(arg: []const u8) ValidationError!void {
    if (arg.len < 3 or !std.mem.startsWith(u8, arg, "--") or !std.ascii.isAlphabetic(arg[2])) return error.InvalidFinishArg;
    for (arg) |ch| if (ch <= 0x20 or ch == 0x7F) return error.InvalidFinishArg;
}

/// Text for the metainfo: valid UTF-8 without control characters (newlines
/// allowed when `multiline`; blank lines separate paragraphs).
pub fn validateText(v: []const u8, multiline: bool) ValidationError!void {
    if (!std.unicode.utf8ValidateSlice(v)) return error.InvalidText;
    for (v) |ch| {
        if (ch == '\n' and multiline) continue;
        if (ch < 0x20 or ch == 0x7F) return error.InvalidText;
    }
}

pub const MetadataOptions = struct {
    app_id: []const u8,
    exe_name: []const u8,
    arch: []const u8,
    runtime_version: []const u8,
};

/// The build directory's `metadata` (the `[Application]` group; build-finish
/// adds `[Context]`). Inputs are validated by the caller (app id, exe name,
/// `validateRuntimeVersion`).
pub fn writeMetadata(w: *std.Io.Writer, o: MetadataOptions) std.Io.Writer.Error!void {
    try w.print(
        \\[Application]
        \\name={s}
        \\runtime={s}/{s}/{s}
        \\sdk={s}/{s}/{s}
        \\command={s}
        \\
    , .{ o.app_id, runtime, o.arch, o.runtime_version, sdk, o.arch, o.runtime_version, o.exe_name });
}

pub const MetainfoOptions = struct {
    app_id: []const u8,
    name: []const u8,
    summary: []const u8,
    description: []const u8,
    version: []const u8,
    publisher: []const u8,
    homepage: ?[]const u8 = null,
    license: ?[]const u8 = null,
};

/// AppStream metainfo, so software centers (GNOME Software, Discover) show
/// the app's name, summary and description when the bundle is opened.
pub fn writeMetainfo(w: *std.Io.Writer, o: MetainfoOptions) std.Io.Writer.Error!void {
    try w.writeAll(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<component type="desktop-application">
        \\  <id>
    );
    try escape(w, o.app_id);
    try w.writeAll("</id>\n  <metadata_license>CC0-1.0</metadata_license>\n");
    if (o.license) |l| try element(w, "project_license", l);
    try element(w, "name", o.name);
    try element(w, "summary", o.summary);
    try w.writeAll("  <developer id=\"");
    try escape(w, o.app_id);
    try w.writeAll("\">\n  ");
    try element(w, "name", o.publisher);
    try w.writeAll("  </developer>\n  <description>\n");
    var paragraphs = std.mem.splitSequence(u8, o.description, "\n\n");
    while (paragraphs.next()) |p| {
        const text = std.mem.trim(u8, p, " \n");
        if (text.len == 0) continue;
        try w.writeAll("    <p>");
        for (text) |ch| {
            if (ch == '\n') try w.writeByte(' ') else try escape(w, &.{ch});
        }
        try w.writeAll("</p>\n");
    }
    try w.writeAll("  </description>\n  <launchable type=\"desktop-id\">");
    try escape(w, o.app_id);
    try w.writeAll(".desktop</launchable>\n");
    if (o.homepage) |h| {
        try w.writeAll("  <url type=\"homepage\">");
        try escape(w, h);
        try w.writeAll("</url>\n");
    }
    try w.writeAll("  <content_rating type=\"oars-1.1\"/>\n  <releases>\n    <release version=\"");
    try escape(w, o.version);
    try w.writeAll("\"/>\n  </releases>\n</component>\n");
}

fn element(w: *std.Io.Writer, tag: []const u8, text: []const u8) std.Io.Writer.Error!void {
    try w.print("  <{s}>", .{tag});
    try escape(w, text);
    try w.print("</{s}>\n", .{tag});
}

fn escape(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    for (s) |ch| switch (ch) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(ch),
    };
}

const testing = std.testing;

test "finishArgs: base permissions, then what the features need" {
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(testing.allocator);
    try finishArgs(.{}, &list, testing.allocator);
    try testing.expectEqual(base_finish_args.len, list.items.len);

    list.clearRetainingCapacity();
    try finishArgs(.{ .network = true, .tray = true, .audio = true, .bluetooth = true }, &list, testing.allocator);
    try testing.expectEqualStrings("--socket=wayland", list.items[0]);
    try testing.expectEqualStrings("--share=network", list.items[4]);
    try testing.expectEqualStrings("--talk-name=org.kde.StatusNotifierWatcher", list.items[5]);
    try testing.expectEqualStrings("--socket=pulseaudio", list.items[6]);
    try testing.expectEqualStrings("--system-talk-name=org.bluez", list.items[7]);
}

test "finishArgs: every allocation failure leaves the list consistent" {
    const Check = struct {
        fn run(gpa: std.mem.Allocator) !void {
            var list: std.ArrayList([]const u8) = .empty;
            defer list.deinit(gpa);
            try finishArgs(.{ .network = true, .tray = true }, &list, gpa);
            try testing.expectEqual(base_finish_args.len + 2, list.items.len);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Check.run, .{});
}

test "validateRuntimeVersion" {
    try validateRuntimeVersion("50");
    try validateRuntimeVersion("master");
    try validateRuntimeVersion("24.08");
    try testing.expectError(error.InvalidRuntimeVersion, validateRuntimeVersion(""));
    try testing.expectError(error.InvalidRuntimeVersion, validateRuntimeVersion("50/x86_64"));
    try testing.expectError(error.InvalidRuntimeVersion, validateRuntimeVersion("5 0"));
}

test "validateFinishArg" {
    try validateFinishArg("--filesystem=xdg-data/locket:create");
    try validateFinishArg("--device=all");
    try testing.expectError(error.InvalidFinishArg, validateFinishArg("filesystem=home"));
    try testing.expectError(error.InvalidFinishArg, validateFinishArg("--"));
    try testing.expectError(error.InvalidFinishArg, validateFinishArg("--a b"));
    try testing.expectError(error.InvalidFinishArg, validateFinishArg("--a\n--b"));
    try testing.expectError(error.InvalidFinishArg, validateFinishArg("---x"));
}

test "validateText" {
    try validateText("A vault", false);
    try validateText("One.\n\nTwo.", true);
    try testing.expectError(error.InvalidText, validateText("One.\nTwo.", false));
    try testing.expectError(error.InvalidText, validateText("tab\there", true));
    try testing.expectError(error.InvalidText, validateText("\xff", false));
}

test "writeMetadata" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeMetadata(&w, .{ .app_id = "com.example.App", .exe_name = "app", .arch = "x86_64", .runtime_version = "50" });
    try testing.expectEqualStrings(
        \\[Application]
        \\name=com.example.App
        \\runtime=org.gnome.Platform/x86_64/50
        \\sdk=org.gnome.Sdk/x86_64/50
        \\command=app
        \\
    , w.buffered());
}

test "writeMetainfo escapes text and splits paragraphs" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeMetainfo(&out.writer, .{
        .app_id = "com.example.App",
        .name = "A & B",
        .summary = "Keeps <secrets>",
        .description = "First line\ncontinued.\n\nSecond \"para\".",
        .version = "1.2.3",
        .publisher = "Example",
        .homepage = "https://example.com/?a=1&b=2",
        .license = "MIT",
    });
    const xml = out.written();
    try testing.expect(std.mem.indexOf(u8, xml, "<id>com.example.App</id>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<name>A &amp; B</name>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<summary>Keeps &lt;secrets&gt;</summary>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<p>First line continued.</p>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<p>Second &quot;para&quot;.</p>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<project_license>MIT</project_license>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "https://example.com/?a=1&amp;b=2") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<launchable type=\"desktop-id\">com.example.App.desktop</launchable>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<release version=\"1.2.3\"/>") != null);
}

test "writeMetainfo: every allocation failure propagates" {
    const Check = struct {
        fn run(gpa: std.mem.Allocator) !void {
            var out: std.Io.Writer.Allocating = .init(gpa);
            defer out.deinit();
            writeMetainfo(&out.writer, .{
                .app_id = "com.example.App",
                .name = "App",
                .summary = "Summary",
                .description = "Description",
                .version = "1.0.0",
                .publisher = "Example",
            }) catch return error.OutOfMemory;
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Check.run, .{});
}
