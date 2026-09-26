//! Packaging step builder for Oriel applications.
//!
//! Provides pluggable package format dispatch per target OS.
//! Supported formats: .deb, .rpm, .AppImage on Linux, NSIS setup.exe on
//! Windows, .app bundle and .dmg on macOS.

const std = @import("std");
const metadata_mod = @import("../tools/package/metadata.zig");

pub const targetToDebArch = metadata_mod.targetToDebArch;
pub const targetToRpmArch = metadata_mod.targetToRpmArch;
pub const targetToAppImageArch = metadata_mod.targetToAppImageArch;

/// Target package formats supported by Oriel.
///
/// Supported formats:
/// - `deb`: Debian package (.deb) generated via nfpm.
/// - `rpm`: Red Hat package (.rpm) generated via nfpm.
/// - `appimage`: AppImage bundle (.AppImage).
/// - `nsis`: Windows installer (`setup.exe`) generated via `makensis` (cross-builds from Linux).
/// - `app`: macOS application bundle (`<Name>.app`: Info.plist, icon.icns; ad-hoc signed on a Mac).
/// - `dmg`: macOS disk image with the .app and an Applications link (`hdiutil`, macOS hosts).
///
/// Future formats:
/// - `msi`: Windows installer MSI generated via WiX toolset.
pub const Format = enum {
    deb,
    rpm,
    appimage,
    nsis,
    app,
    dmg,
};

/// Return default package formats for a given operating system.
pub fn defaultFormats(os_tag: std.Target.Os.Tag) []const Format {
    return switch (os_tag) {
        .linux => &.{ .deb, .rpm, .appimage },
        .windows => &.{.nsis},
        .macos => &.{ .app, .dmg },
        else => &.{},
    };
}

/// App metadata defined once and shared by all package formats.
pub const Metadata = struct {
    id: []const u8,
    name: []const u8,
    exe_name: []const u8,
    version: []const u8,
    summary: []const u8,
    description: []const u8,
    publisher: []const u8,
    license: ?[]const u8,
    homepage: ?[]const u8,
    categories: []const u8,
    icon: std.Build.LazyPath,
    extra_deb_depends: []const []const u8,
    extra_rpm_depends: []const []const u8,
    url_schemes: []const []const u8,
    replaces: []const []const u8 = &.{},
    conflicts: []const []const u8 = &.{},
};

/// Build-time options specified in an app's build.zig via `addApp(..., .{ .package = .{ ... } })`.
pub const PackageOptions = struct {
    /// Reverse-DNS application ID (e.g. "dev.oriel.ReactNotes").
    /// Must match the GTK application ID used at runtime.
    /// Defaults to "dev.oriel.<exe_name>".
    id: ?[]const u8 = null,

    /// Human-friendly display name (e.g. "React Notes").
    /// Defaults to the executable name.
    name: ?[]const u8 = null,

    /// Short one-line summary / comment for desktop entry and package managers.
    /// Defaults to "<name> application".
    summary: ?[]const u8 = null,

    /// Longer multi-line description for package managers (deb/rpm).
    /// Defaults to `summary`.
    description: ?[]const u8 = null,

    /// Publisher / maintainer / vendor name and contact (e.g. "Acme Corp <team@acme.com>").
    /// Used by deb Maintainer, rpm Vendor/Packager, and future NSIS/MSI publisher.
    /// Defaults to the display name.
    publisher: ?[]const u8 = null,

    /// SPDX license identifier (e.g. "MIT", "Apache-2.0").
    /// Optional; omitted from package metadata when null.
    license: ?[]const u8 = null,

    /// Project homepage URL.
    /// Optional; omitted from package metadata when null.
    homepage: ?[]const u8 = null,

    /// Semicolon-delimited desktop categories (e.g. "Utility;TextEditor;").
    /// Defaults to "Utility;".
    categories: ?[]const u8 = null,

    /// Version string (e.g. "0.1.0"). Defaults to "0.1.0".
    version: ?[]const u8 = null,

    /// High-resolution icon (PNG). Deprecated: use `AppOptions.icon` instead. Defaults to Oriel brand icon (1024x1024).
    icon: ?std.Build.LazyPath = null,

    /// Target package formats to build. Overrides defaultFormats(os) if specified.
    formats: ?[]const Format = null,

    /// Custom URL schemes handled by the application (e.g. &.{ "oriel-notes" }).
    url_schemes: []const []const u8 = &.{},

    /// Extra runtime dependencies for Debian packages.
    extra_deb_depends: []const []const u8 = &.{},

    /// Extra runtime dependencies for RPM packages.
    extra_rpm_depends: []const []const u8 = &.{},

    /// Linux packages (deb, rpm) this one takes over: installing it upgrades
    /// them (deb Replaces, rpm Obsoletes). E.g. the app's earlier package name.
    replaces: []const []const u8 = &.{},

    /// Linux packages (deb, rpm) that can't be installed alongside this one.
    conflicts: []const []const u8 = &.{},

    /// Optional path to WebView2Loader.dll for Windows packages.
    /// If null, can also be provided via `-Dwebview2-loader=<path>` build option.
    /// When provided, the DLL is copied next to the Windows executable in the installer.
    /// Available from the Microsoft.Web.WebView2 NuGet package (runtimes/win-x64/native/WebView2Loader.dll).
    webview2_loader: ?std.Build.LazyPath = null,

    /// What the packages contain besides the app's executable (all formats).
    contents: Contents = .{},
};

/// The package's contents besides the app's executable
/// (`PackageOptions.contents`), for every format:
///
/// - deb/rpm: without extra executables or files the app is `/usr/bin/<exe>`
///   as always; with them, the app, the extra executables and the files go to
///   `/usr/lib/<exe>/` and `/usr/bin` gets symlinks to the executables (so a
///   program finds its companions next to its own, symlink-resolved, path).
/// - AppImage: `usr/bin/` next to the app.
/// - NSIS: `$INSTDIR` (the uninstaller removes them again).
/// - macOS: `<Name>.app/Contents/MacOS/` for executables and Mach-O files,
///   signed inside-out with the bundle; other files in `Contents/Resources/`
///   behind a `Contents/MacOS/<top-level name>` symlink.
///
/// ```zig
/// .contents = .{
///     .executables = &.{cli},
///     .files = &.{.{ .path = "data/model.bin", .source = b.path("model.bin") }},
/// },
/// ```
pub const Contents = struct {
    /// Other executables of the build (e.g. a CLI), installed next to the app's
    /// executable under their file names; on Linux also linked into /usr/bin.
    executables: []const *std.Build.Step.Compile = &.{},
    /// Files placed next to the app's executable: `path` is relative to the
    /// executable's directory (no absolute paths, no `..`), e.g. "data/model.bin".
    /// Installed as-is (not stripped), mode 0644 on Linux and macOS. In a
    /// macOS bundle, files that aren't Mach-O code go to Contents/Resources,
    /// reached from Contents/MacOS through a symlink of their top-level name.
    files: []const File = &.{},
    /// Oriel's runtime libraries the app was built with (libggml-cuda.so with
    /// -Dggml_cuda, libggml-vulkan.so with -Dggml_vulkan). Default on. A `files` entry of the same path replaces it.
    runtime_libraries: bool = true,
    /// Strip debug info and symbols from ELF executables/libraries in packages
    /// (Linux): the app, `executables` and the runtime libraries (the dynamic
    /// symbol table stays, so `-rdynamic` exports still reach plugins).
    /// `zig build`'s zig-out keeps them. Default on. This strips the app's own
    /// executable too, so a packaged ReleaseSafe app's crash traces show
    /// addresses, not function names: set `.strip = false` to ship symbols.
    strip: bool = true,
};

/// A file in `Contents.files`.
pub const File = struct {
    /// Destination relative to the app executable's directory, `/`-separated
    /// (e.g. "data/model.bin"): not absolute, no `.` or `..` components, none
    /// of `\ : * ? " < > | =`.
    path: []const u8,
    source: std.Build.LazyPath,
};

/// What every package format ships, resolved once from `Contents`
/// (stripped copies when asked to).
pub const Payload = struct {
    /// The app's executable.
    exe: std.Build.LazyPath,
    /// Other executables; each file's basename is its installed name.
    executables: []const std.Build.LazyPath = &.{},
    /// Files at a path relative to the app's executable.
    files: []const File = &.{},

    /// `--extra-exe <path>` and `--extra-file <relpath>=<path>` for the
    /// `package-*` commands (file arguments: the cache tracks their content).
    fn addArgs(p: Payload, b: *std.Build, run: *std.Build.Step.Run) void {
        for (p.executables) |e| {
            run.addArg("--extra-exe");
            run.addFileArg(e);
        }
        for (p.files) |f| {
            run.addArg("--extra-file");
            run.addPrefixedFileArg(b.fmt("{s}=", .{f.path}), f.source);
        }
    }
};

/// Resolve `contents` for `exe`: the extra executables, the files, Oriel's
/// runtime libraries, stripped when `contents.strip` and the target is ELF.
fn resolvePayload(
    b: *std.Build,
    oriel_dep: *std.Build.Dependency,
    package_tool: *std.Build.Step.Compile,
    exe: *std.Build.Step.Compile,
    contents: Contents,
) Payload {
    const elf = exe.root_module.resolved_target.?.result.ofmt == .elf;
    const strip = contents.strip and elf;
    var executables: std.ArrayList(std.Build.LazyPath) = .empty;
    var files: std.ArrayList(File) = .empty;
    for (contents.executables) |e| {
        const bin = e.getEmittedBin();
        executables.append(b.allocator, if (strip) strippedElf(b, package_tool, bin, e.out_filename) else bin) catch @panic("OOM");
    }
    files.appendSlice(b.allocator, contents.files) catch @panic("OOM");
    if (contents.runtime_libraries) {
        for ([_][]const u8{ "libggml-cuda", "libggml-vulkan" }) |lib_name| {
            const lib = oriel_dep.builder.named_lazy_paths.get(lib_name) orelse continue;
            const name = b.fmt("{s}.so", .{lib_name});
            // The app ships its own copy: keep that one.
            const own = for (contents.files) |f| {
                if (std.ascii.eqlIgnoreCase(f.path, name)) break true;
            } else false;
            if (own) continue;
            files.append(b.allocator, .{ .path = name, .source = if (strip) strippedElf(b, package_tool, lib, name) else lib }) catch @panic("OOM");
        }
    }
    const bin = exe.getEmittedBin();
    return .{
        .exe = if (strip) strippedElf(b, package_tool, bin, exe.out_filename) else bin,
        .executables = executables.items,
        .files = files.items,
    };
}

/// `src` without its symbol table and debug info (`package_tool strip-elf`),
/// named `basename`. (`zig objcopy` can't strip ELF files yet.)
fn strippedElf(b: *std.Build, package_tool: *std.Build.Step.Compile, src: std.Build.LazyPath, basename: []const u8) std.Build.LazyPath {
    const run = b.addRunArtifact(package_tool);
    run.setName(b.fmt("strip {s}", .{basename}));
    run.addArgs(&.{ "strip-elf", "--in" });
    run.addFileArg(src);
    run.addArg("--out");
    return run.addOutputFileArg(basename);
}

/// A step failing with why `contents` can't be packaged, or null.
fn checkContents(b: *std.Build, contents: Contents) ?*std.Build.Step {
    for (contents.files) |f| {
        metadata_mod.validateRelativePath(f.path) catch {
            return &b.addFail(b.fmt("package contents: invalid file path \"{s}\": {s}", .{ f.path, @import("../tools/package/contents.zig").relative_path_rules })).step;
        };
    }
    for (contents.executables) |e| {
        if (e.kind != .exe) return &b.addFail(b.fmt("package contents: {s} is not an executable (use .files for libraries)", .{e.name})).step;
    }
    return null;
}

/// Format packaging context passed to each format builder function.
pub const Context = struct {
    b: *std.Build,
    oriel_dep: *std.Build.Dependency,
    package_tool: *std.Build.Step.Compile,
    metadata: Metadata,
    target: std.Build.ResolvedTarget,
    /// The app's executable and the package's other contents.
    payload: Payload,
    /// Fails the package steps when `PackageOptions.contents` is invalid.
    contents_error: ?*std.Build.Step = null,
    desktop_file: std.Build.LazyPath,
    icons_dir: std.Build.LazyPath,
    deb_deps: []const []const u8,
    rpm_deps: []const []const u8,
    appimage_runtime_override: ?[]const u8,
    webview2_loader: ?std.Build.LazyPath,
    /// macOS targets: the `.app` bundle of `exe` (a directory) and its name
    /// (for the package steps: signed for distribution when asked to).
    app_bundle: ?AppBundle,
    mac_signing: MacSigning = .{},
};

/// macOS distribution signing (see tools/package/sign_macos.zig).
pub const MacSigning = struct {
    identity: ?[]const u8 = null,
    notarize_profile: ?[]const u8 = null,
    dry_run: bool = false,

    fn active(self: MacSigning) bool {
        return self.identity != null or self.notarize_profile != null or self.dry_run;
    }
};

/// `-Dmacos-sign-identity`, `-Dmacos-notarize-profile` (or the
/// `ORIEL_MACOS_SIGN_IDENTITY` / `ORIEL_MACOS_NOTARIZE_PROFILE` environment
/// variables) and `-Dmacos-sign-dry-run`, declared once.
fn macSigningOptions(b: *std.Build) MacSigning {
    const env = &b.graph.environ_map;
    const nonEmpty = struct {
        fn f(v: ?[]const u8) ?[]const u8 {
            const s = v orelse return null;
            return if (s.len == 0) null else s;
        }
    }.f;
    return .{
        .identity = nonEmpty(getOrDeclareStringOption(b, "macos-sign-identity", "macOS packages: codesign identity (\"Developer ID Application: ...\", a SHA-1, or - for ad-hoc with the hardened runtime); default $ORIEL_MACOS_SIGN_IDENTITY") orelse env.get("ORIEL_MACOS_SIGN_IDENTITY")),
        .notarize_profile = nonEmpty(getOrDeclareStringOption(b, "macos-notarize-profile", "macOS packages: notarize the .dmg with this `xcrun notarytool store-credentials` profile; default $ORIEL_MACOS_NOTARIZE_PROFILE") orelse env.get("ORIEL_MACOS_NOTARIZE_PROFILE")),
        .dry_run = getOrDeclareBoolOption(b, "macos-sign-dry-run", "macOS packages: print the signing/notarization commands; sign ad-hoc with the hardened runtime") orelse false,
    };
}

fn getOrDeclareStringOption(b: *std.Build, comptime name: []const u8, comptime description: []const u8) ?[]const u8 {
    if (b.available_options_map.get(name) != null) {
        const option_ptr = b.user_input_options.getPtr(name) orelse return null;
        option_ptr.used = true;
        return switch (option_ptr.value) {
            .scalar => |s| s,
            else => null,
        };
    }
    return b.option([]const u8, name, description);
}

fn getOrDeclareBoolOption(b: *std.Build, comptime name: []const u8, comptime description: []const u8) ?bool {
    if (b.available_options_map.get(name) != null) {
        const option_ptr = b.user_input_options.getPtr(name) orelse return null;
        option_ptr.used = true;
        return switch (option_ptr.value) {
            .flag => true,
            .scalar => |s| !std.mem.eql(u8, s, "false"),
            else => null,
        };
    }
    return b.option(bool, name, description);
}

/// A copy of `bundle` signed for distribution (`package_tool sign-app`).
fn addSignedBundle(b: *std.Build, package_tool: *std.Build.Step.Compile, bundle: AppBundle, signing: MacSigning) AppBundle {
    const run = b.addRunArtifact(package_tool);
    run.addArg("sign-app");
    run.addArg("--app");
    run.addDirectoryArg(bundle.dir);
    run.addArg("--entitlements");
    run.addFileArg(bundle.entitlements);
    run.addArg("--out-dir");
    const out_dir = run.addOutputDirectoryArg("signed");
    if (signing.identity) |id| run.addArgs(&.{ "--identity", id });
    if (signing.dry_run) run.addArg("--dry-run");
    // The keychain isn't an input the cache can see: sign on every package build.
    run.has_side_effects = true;
    const real_identity = signing.identity != null and !std.mem.eql(u8, signing.identity.?, "-");
    if (signing.notarize_profile != null and !real_identity and !signing.dry_run) {
        run.step.dependOn(&b.addFail("-Dmacos-notarize-profile needs -Dmacos-sign-identity=\"Developer ID Application: ...\" (notarization takes a Developer ID signature; add -Dmacos-sign-dry-run to see the commands)").step);
    }
    return .{ .dir = out_dir.path(b, bundle.name), .name = bundle.name, .entitlements = bundle.entitlements };
}

pub const AppBundle = struct {
    dir: std.Build.LazyPath,
    name: []const u8,
    /// `<Name>.entitlements` (hardened-runtime entitlements for the declared permissions).
    entitlements: std.Build.LazyPath,
};

/// Assemble the macOS `.app` bundle of `exe` with `package_tool package-app`.
fn addAppBundle(
    b: *std.Build,
    package_tool: *std.Build.Step.Compile,
    metadata: Metadata,
    target: std.Build.ResolvedTarget,
    exe: *std.Build.Step.Compile,
    payload: Payload,
    icons_dir: std.Build.LazyPath,
    permissions: anytype,
) AppBundle {
    const min = target.result.os.version_range.semver.min;
    const run = b.addRunArtifact(package_tool);
    run.addArg("package-app");
    run.addArg("--out-dir");
    const out_dir = run.addOutputDirectoryArg("app");
    run.addArgs(&.{ "--app-id", metadata.id });
    run.addArgs(&.{ "--name", metadata.name });
    run.addArgs(&.{ "--exe-name", exe.name });
    run.addArgs(&.{ "--version", metadata.version });
    run.addArgs(&.{ "--min-os", b.fmt("{d}.{d}", .{ min.major, min.minor }) });
    for (metadata.url_schemes) |s| run.addArgs(&.{ "--url-scheme", s });
    // Usage texts for Info.plist (`--permission <kind>=<reason>`).
    inline for (@typeInfo(@TypeOf(permissions)).@"struct".fields) |f| {
        if (@field(permissions, f.name)) |reason| {
            const text = if (reason.len > 0) reason else b.fmt("{s} {s}", .{ metadata.name, @TypeOf(permissions).defaultReasonFor(f.name) });
            run.addArgs(&.{ "--permission", b.fmt("{s}={s}", .{ f.name, text }) });
        }
    }
    run.addArg("--bin");
    run.addFileArg(payload.exe);
    payload.addArgs(b, run);
    run.addArg("--icons-dir");
    run.addDirectoryArg(icons_dir);
    const name = b.fmt("{s}.app", .{metadata.name});
    return .{
        .dir = out_dir.path(b, name),
        .name = name,
        .entitlements = out_dir.path(b, b.fmt("{s}.entitlements", .{metadata.name})),
    };
}

pub fn addPackageSteps(
    b: *std.Build,
    oriel_dep: *std.Build.Dependency,
    options: anytype,
    exe: *std.Build.Step.Compile,
    dev_exe: ?*std.Build.Step.Compile,
    icons_dir: std.Build.LazyPath,
    app_icon: std.Build.LazyPath,
    permissions: anytype,
) void {
    const pkg_opts = options.package orelse PackageOptions{};
    const target = exe.root_module.resolved_target.?;
    const os_tag = target.result.os.tag;

    const exe_name = options.name;
    const display_name = pkg_opts.name orelse exe_name;
    const app_id = pkg_opts.id orelse b.fmt("dev.oriel.{s}", .{exe_name});
    const summary = pkg_opts.summary orelse b.fmt("{s} application", .{display_name});
    const description = pkg_opts.description orelse summary;
    const publisher = pkg_opts.publisher orelse metadata_mod.organizationFromAppId(app_id);
    const version = pkg_opts.version orelse "0.1.0";
    const categories = pkg_opts.categories orelse "Utility;";

    const metadata = Metadata{
        .id = app_id,
        .name = display_name,
        .exe_name = exe_name,
        .version = version,
        .summary = summary,
        .description = description,
        .publisher = publisher,
        .license = pkg_opts.license,
        .homepage = pkg_opts.homepage,
        .categories = categories,
        .icon = app_icon,
        .extra_deb_depends = pkg_opts.extra_deb_depends,
        .extra_rpm_depends = pkg_opts.extra_rpm_depends,
        .url_schemes = pkg_opts.url_schemes,
        .replaces = pkg_opts.replaces,
        .conflicts = pkg_opts.conflicts,
    };

    // Derive dependencies from features
    var deb_deps: std.ArrayList([]const u8) = .empty;
    var rpm_deps: std.ArrayList([]const u8) = .empty;

    // Base GTK4 + WebKitGTK 6.0 dependencies
    deb_deps.append(b.allocator, "libgtk-4-1") catch unreachable;
    deb_deps.append(b.allocator, "libwebkitgtk-6.0-4") catch unreachable;
    rpm_deps.append(b.allocator, "gtk4") catch unreachable;
    rpm_deps.append(b.allocator, "webkitgtk6.0") catch unreachable;

    const has_global_shortcut = isFeatureEnabled(oriel_dep, "global_shortcut");
    const has_input = isFeatureEnabled(oriel_dep, "input");
    const has_clipboard = isFeatureEnabled(oriel_dep, "clipboard");

    if (has_global_shortcut or has_input) {
        deb_deps.append(b.allocator, "libx11-6") catch unreachable;
        rpm_deps.append(b.allocator, "libX11") catch unreachable;
    }
    if (has_input) {
        deb_deps.append(b.allocator, "libxkbcommon0") catch unreachable;
        deb_deps.append(b.allocator, "libxtst6") catch unreachable;
        rpm_deps.append(b.allocator, "libxkbcommon") catch unreachable;
        rpm_deps.append(b.allocator, "libXtst") catch unreachable;
    }
    if (has_input or has_clipboard) {
        deb_deps.append(b.allocator, "libwayland-client0") catch unreachable;
        rpm_deps.append(b.allocator, "libwayland-client") catch unreachable;
    }

    for (metadata.extra_deb_depends) |d| {
        deb_deps.append(b.allocator, d) catch unreachable;
    }
    for (metadata.extra_rpm_depends) |d| {
        rpm_deps.append(b.allocator, d) catch unreachable;
    }

    const package_tool = oriel_dep.artifact("package_tool");

    // Production desktop file in cache
    const run_desktop = b.addRunArtifact(package_tool);
    run_desktop.addArg("generate-desktop");
    run_desktop.addArg("--out");
    const desktop_file = run_desktop.addOutputFileArg(b.fmt("{s}.desktop", .{metadata.id}));
    run_desktop.addArgs(&.{
        "--id",               metadata.id,
        "--name",             metadata.name,
        "--exec",             metadata.exe_name,
        "--icon",             metadata.id,
        "--comment",          metadata.summary,
        "--categories",       metadata.categories,
        "--terminal",         "false",
        "--startup-notify",   "true",
        "--startup-wm-class", metadata.id,
    });
    for (metadata.url_schemes) |s| {
        run_desktop.addArgs(&.{ "--url-scheme", s });
    }

    const appimage_runtime_override = getOrDeclareAppImageRuntimeOption(b);

    var webview2_loader = pkg_opts.webview2_loader;
    if (webview2_loader == null) {
        if (getOrDeclareWebView2LoaderOption(b)) |wl| {
            webview2_loader = if (std.fs.path.isAbsolute(wl))
                .{ .cwd_relative = wl }
            else
                b.path(wl);
        }
    }

    if (os_tag == .windows and webview2_loader != null) {
        const install_loader = b.addInstallFileWithDir(webview2_loader.?, .bin, "WebView2Loader.dll");
        b.getInstallStep().dependOn(&install_loader.step);
        // `zig build dev` / `build-dev` install only the dev executable, not
        // the install step, so the loader must come along with it too.
        if (dev_exe) |d| d.step.dependOn(&install_loader.step);
    }

    // macOS: `zig build` also installs `zig-out/<Name>.app`: Launch Services
    // (deep links), notifications and permission prompts need a bundle.
    // The package contents, resolved once for every format.
    const payload = resolvePayload(b, oriel_dep, package_tool, exe, pkg_opts.contents);
    const contents_error = checkContents(b, pkg_opts.contents);

    var app_bundle: ?AppBundle = null;
    // Declared for every target (a CI script may pass them to all), used on macOS.
    const mac_signing_opts = macSigningOptions(b);
    const mac_signing: MacSigning = if (os_tag == .macos) mac_signing_opts else .{};
    if (os_tag == .macos) {
        const bundle = addAppBundle(b, package_tool, metadata, target, exe, payload, icons_dir, permissions);
        b.getInstallStep().dependOn(installAppBundle(b, package_tool, bundle, bundle.name));
        app_bundle = bundle;
    }

    const ctx = Context{
        .b = b,
        .oriel_dep = oriel_dep,
        .package_tool = package_tool,
        .metadata = metadata,
        .target = target,
        .payload = payload,
        .contents_error = contents_error,
        .desktop_file = desktop_file,
        .icons_dir = icons_dir,
        .deb_deps = deb_deps.items,
        .rpm_deps = rpm_deps.items,
        .appimage_runtime_override = appimage_runtime_override,
        .webview2_loader = webview2_loader,
        .app_bundle = if (app_bundle) |bundle| (if (mac_signing.active()) addSignedBundle(b, package_tool, bundle, mac_signing) else bundle) else null,
        .mac_signing = mac_signing,
    };

    // Determine target formats
    const target_formats = pkg_opts.formats orelse defaultFormats(os_tag);

    // Aggregate `package` step plus one `package-<format>` step per selected
    // format; each format's build graph is created once and shared by both.
    const package_step = getOrCreateStep(b, "package", "Build distribution packages");
    if (target_formats.len == 0) {
        const fail = b.addFail(b.fmt("no package formats for {s} yet", .{@tagName(os_tag)}));
        package_step.dependOn(&fail.step);
    }
    for (target_formats) |fmt| {
        const step = addFormat(&ctx, fmt);
        if (contents_error) |fail| step.dependOn(fail);
        package_step.dependOn(step);
        getOrCreateStep(b, b.fmt("package-{s}", .{@tagName(fmt)}), b.fmt("Build only the {s} package", .{@tagName(fmt)})).dependOn(step);
    }

    // Desktop entries for local runs (Linux): the GlobalShortcuts portal (and
    // the desktop's app list) only know apps with an installed .desktop file.
    // `desktop-entry`: the dev build (`<id>.Dev`, `oriel dev`) when there is
    // one, else the production build; `desktop-entry-release`: the production
    // build (`<id>`, `oriel build` / `oriel run`).
    const has_dev = dev_exe != null;
    addDesktopEntryStep(b, package_tool, metadata, icons_dir, "desktop-entry", "Install the desktop entry and icons of the dev build (or the production build) into $XDG_DATA_HOME", if (has_dev) .{
        .id = b.fmt("{s}.Dev", .{metadata.id}),
        .name = b.fmt("{s} (Dev)", .{metadata.name}),
        .bin_name = b.fmt("{s}-dev", .{metadata.exe_name}),
        .compile = dev_exe.?,
    } else .{ .id = metadata.id, .name = metadata.name, .bin_name = metadata.exe_name, .compile = exe });
    addDesktopEntryStep(b, package_tool, metadata, icons_dir, "desktop-entry-release", "Install the desktop entry and icons of the production build into $XDG_DATA_HOME", .{
        .id = metadata.id,
        .name = metadata.name,
        .bin_name = metadata.exe_name,
        .compile = exe,
    });
}

const DesktopTarget = struct {
    id: []const u8,
    name: []const u8,
    bin_name: []const u8,
    compile: *std.Build.Step.Compile,
};

fn addDesktopEntryStep(
    b: *std.Build,
    package_tool: *std.Build.Step.Compile,
    metadata: Metadata,
    icons_dir: std.Build.LazyPath,
    step_name: []const u8,
    description: []const u8,
    t: DesktopTarget,
) void {
    const run_dev_desktop = b.addRunArtifact(package_tool);
    run_dev_desktop.addArg("generate-desktop");
    run_dev_desktop.addArg("--out");
    const dev_desktop_file = run_dev_desktop.addOutputFileArg(b.fmt("{s}.desktop", .{t.id}));
    const abs_bin = b.pathFromRoot(b.getInstallPath(.bin, t.bin_name));
    run_dev_desktop.addArgs(&.{
        "--id",               t.id,
        "--name",             t.name,
        "--exec",             abs_bin,
        "--icon",             t.id,
        "--comment",          metadata.summary,
        "--categories",       metadata.categories,
        "--terminal",         "false",
        "--startup-notify",   "true",
        "--startup-wm-class", t.id,
    });
    for (metadata.url_schemes) |s| {
        run_dev_desktop.addArgs(&.{ "--url-scheme", s });
    }

    const run_install_desktop = b.addRunArtifact(package_tool);
    run_install_desktop.addArg("install-desktop-entry");
    run_install_desktop.addArg("--desktop");
    run_install_desktop.addFileArg(dev_desktop_file);
    run_install_desktop.addArg("--icons-dir");
    run_install_desktop.addDirectoryArg(icons_dir);
    run_install_desktop.addArg("--app-id");
    run_install_desktop.addArg(t.id);
    run_install_desktop.has_side_effects = true;

    const step = getOrCreateStep(b, step_name, description);
    step.dependOn(&b.addInstallArtifact(t.compile, .{}).step);
    step.dependOn(&run_install_desktop.step);
}

/// Dispatch format builder based on Format enum.
fn addFormat(ctx: *const Context, format: Format) *std.Build.Step {
    return switch (format) {
        .deb => addDeb(ctx),
        .rpm => addRpm(ctx),
        .appimage => addAppImage(ctx),
        .nsis => addNsis(ctx),
        .app => addApp(ctx),
        .dmg => addDmg(ctx),
    };
}

/// Build Debian (.deb) package.
fn addDeb(ctx: *const Context) *std.Build.Step {
    const deb_arch = targetToDebArch(ctx.target.result.cpu.arch);
    const deb_filename = ctx.b.fmt("{s}_{s}_{s}.deb", .{ ctx.metadata.exe_name, ctx.metadata.version, deb_arch });

    const run = ctx.b.addRunArtifact(ctx.package_tool);
    run.addArg("package-deb");
    run.addArg("--out-dir");
    const out_dir = run.addOutputDirectoryArg("deb");
    run.addArgs(&.{ "--filename", deb_filename });
    run.addArgs(&.{ "--name", ctx.metadata.exe_name });
    run.addArgs(&.{ "--version", ctx.metadata.version });
    run.addArgs(&.{ "--arch", deb_arch });
    run.addArgs(&.{ "--maintainer", ctx.metadata.publisher });
    run.addArgs(&.{ "--description", ctx.metadata.description });
    if (ctx.metadata.homepage) |hp| {
        run.addArgs(&.{ "--homepage", hp });
    }
    if (ctx.metadata.license) |lic| {
        run.addArgs(&.{ "--license", lic });
    }
    run.addArgs(&.{ "--binary-name", ctx.metadata.exe_name });
    run.addArgs(&.{ "--app-id", ctx.metadata.id });
    run.addArg("--bin");
    run.addFileArg(ctx.payload.exe);
    ctx.payload.addArgs(ctx.b, run);
    run.addArg("--desktop");
    run.addFileArg(ctx.desktop_file);
    run.addArg("--icons-dir");
    run.addDirectoryArg(ctx.icons_dir);
    for (ctx.deb_deps) |dep| {
        run.addArgs(&.{ "--deb-dep", dep });
    }
    for (ctx.metadata.replaces) |r| run.addArgs(&.{ "--replaces", r });
    for (ctx.metadata.conflicts) |c| run.addArgs(&.{ "--conflicts", c });

    const install = ctx.b.addInstallFileWithDir(
        out_dir.path(ctx.b, deb_filename),
        .prefix,
        ctx.b.fmt("package/{s}", .{deb_filename}),
    );
    return &install.step;
}

/// Build RPM (.rpm) package.
fn addRpm(ctx: *const Context) *std.Build.Step {
    const rpm_arch = targetToRpmArch(ctx.target.result.cpu.arch);
    const rpm_filename = ctx.b.fmt("{s}-{s}-1.{s}.rpm", .{ ctx.metadata.exe_name, ctx.metadata.version, rpm_arch });

    const run = ctx.b.addRunArtifact(ctx.package_tool);
    run.addArg("package-rpm");
    run.addArg("--out-dir");
    const out_dir = run.addOutputDirectoryArg("rpm");
    run.addArgs(&.{ "--filename", rpm_filename });
    run.addArgs(&.{ "--name", ctx.metadata.exe_name });
    run.addArgs(&.{ "--version", ctx.metadata.version });
    run.addArgs(&.{ "--arch", rpm_arch });
    run.addArgs(&.{ "--maintainer", ctx.metadata.publisher });
    run.addArgs(&.{ "--description", ctx.metadata.description });
    if (ctx.metadata.homepage) |hp| {
        run.addArgs(&.{ "--homepage", hp });
    }
    if (ctx.metadata.license) |lic| {
        run.addArgs(&.{ "--license", lic });
    }
    run.addArgs(&.{ "--binary-name", ctx.metadata.exe_name });
    run.addArgs(&.{ "--app-id", ctx.metadata.id });
    run.addArg("--bin");
    run.addFileArg(ctx.payload.exe);
    ctx.payload.addArgs(ctx.b, run);
    run.addArg("--desktop");
    run.addFileArg(ctx.desktop_file);
    run.addArg("--icons-dir");
    run.addDirectoryArg(ctx.icons_dir);
    for (ctx.rpm_deps) |dep| {
        run.addArgs(&.{ "--rpm-dep", dep });
    }
    for (ctx.metadata.replaces) |r| run.addArgs(&.{ "--replaces", r });
    for (ctx.metadata.conflicts) |c| run.addArgs(&.{ "--conflicts", c });

    const install = ctx.b.addInstallFileWithDir(
        out_dir.path(ctx.b, rpm_filename),
        .prefix,
        ctx.b.fmt("package/{s}", .{rpm_filename}),
    );
    return &install.step;
}

/// Build AppImage package.
fn addAppImage(ctx: *const Context) *std.Build.Step {
    const appimage_arch = targetToAppImageArch(ctx.target.result.cpu.arch);
    const appimage_filename = ctx.b.fmt("{s}-{s}-{s}.AppImage", .{ ctx.metadata.exe_name, ctx.metadata.version, appimage_arch });

    const run = ctx.b.addRunArtifact(ctx.package_tool);
    run.addArg("package-appimage");
    run.addArg("--out-dir");
    const out_dir = run.addOutputDirectoryArg("appimage");
    run.addArgs(&.{ "--filename", appimage_filename });
    run.addArg("--bin");
    run.addFileArg(ctx.payload.exe);
    ctx.payload.addArgs(ctx.b, run);
    run.addArg("--desktop");
    run.addFileArg(ctx.desktop_file);
    run.addArg("--icons-dir");
    run.addDirectoryArg(ctx.icons_dir);
    run.addArgs(&.{ "--app-id", ctx.metadata.id });
    run.addArgs(&.{ "--exe-name", ctx.metadata.exe_name });
    run.addArgs(&.{ "--version", ctx.metadata.version });
    run.addArgs(&.{ "--arch", appimage_arch });
    run.addArg("--cache-dir");
    run.addArg(ctx.b.cache_root.path orelse ".zig-cache");
    if (ctx.appimage_runtime_override) |ro| {
        const lazy_ro: std.Build.LazyPath = if (std.fs.path.isAbsolute(ro))
            .{ .cwd_relative = ro }
        else
            ctx.b.path(ro);
        run.addArg("--runtime-override");
        run.addFileArg(lazy_ro);
    }

    const install = ctx.b.addInstallFileWithDir(
        out_dir.path(ctx.b, appimage_filename),
        .prefix,
        ctx.b.fmt("package/{s}", .{appimage_filename}),
    );
    return &install.step;
}

/// Build Windows NSIS installer (`<name>-<version>-setup.exe`).
fn addNsis(ctx: *const Context) *std.Build.Step {
    const setup_filename = ctx.b.fmt("{s}-{s}-setup.exe", .{ ctx.metadata.exe_name, ctx.metadata.version });

    const run = ctx.b.addRunArtifact(ctx.package_tool);
    run.addArg("package-nsis");
    run.addArg("--out-dir");
    const out_dir = run.addOutputDirectoryArg("nsis");
    run.addArgs(&.{ "--filename", setup_filename });
    run.addArgs(&.{ "--name", ctx.metadata.name });
    run.addArgs(&.{ "--exe-name", ctx.metadata.exe_name });
    run.addArgs(&.{ "--version", ctx.metadata.version });
    run.addArgs(&.{ "--publisher", ctx.metadata.publisher });
    run.addArgs(&.{ "--app-id", ctx.metadata.id });
    if (ctx.metadata.homepage) |hp| {
        run.addArgs(&.{ "--homepage", hp });
    }
    for (ctx.metadata.url_schemes) |s| {
        run.addArgs(&.{ "--url-scheme", s });
    }
    run.addArg("--bin");
    run.addFileArg(ctx.payload.exe);
    ctx.payload.addArgs(ctx.b, run);
    run.addArg("--icons-dir");
    run.addDirectoryArg(ctx.icons_dir);
    if (ctx.webview2_loader) |loader| {
        run.addArg("--webview2-loader");
        run.addFileArg(loader);
    }

    const install = ctx.b.addInstallFileWithDir(
        out_dir.path(ctx.b, setup_filename),
        .prefix,
        ctx.b.fmt("package/{s}", .{setup_filename}),
    );
    return &install.step;
}

/// `zig-out/package/<Name>.app`.
fn addApp(ctx: *const Context) *std.Build.Step {
    const bundle = ctx.app_bundle orelse return &ctx.b.addFail(".app bundles are built for macOS targets only").step;
    return installAppBundle(ctx.b, ctx.package_tool, bundle, ctx.b.fmt("package/{s}", .{bundle.name}));
}

/// Install `bundle` at `<prefix>/<sub_path>`, replacing what was there (an
/// install directory step would keep stale files, breaking the signature).
fn installAppBundle(b: *std.Build, package_tool: *std.Build.Step.Compile, bundle: AppBundle, sub_path: []const u8) *std.Build.Step {
    const run = b.addRunArtifact(package_tool);
    run.addArg("install-app");
    run.addArg("--from");
    run.addDirectoryArg(bundle.dir);
    run.addArgs(&.{ "--to", b.getInstallPath(.prefix, sub_path) });
    run.has_side_effects = true;
    // The entitlements go next to the bundle: `<Name>.app` -> `<Name>.entitlements`.
    const ent_sub = b.fmt("{s}.entitlements", .{sub_path[0 .. sub_path.len - ".app".len]});
    run.step.dependOn(&b.addInstallFileWithDir(bundle.entitlements, .prefix, ent_sub).step);
    return &run.step;
}

/// `zig-out/package/<exe>-<version>.dmg`.
fn addDmg(ctx: *const Context) *std.Build.Step {
    const bundle = ctx.app_bundle orelse return &ctx.b.addFail(".dmg images are built for macOS targets only").step;
    const dmg_filename = ctx.b.fmt("{s}-{s}.dmg", .{ ctx.metadata.exe_name, ctx.metadata.version });
    const run = ctx.b.addRunArtifact(ctx.package_tool);
    run.addArg("package-dmg");
    run.addArg("--out-dir");
    const out_dir = run.addOutputDirectoryArg("dmg");
    run.addArgs(&.{ "--filename", dmg_filename });
    run.addArgs(&.{ "--volname", ctx.metadata.name });
    run.addArg("--app");
    run.addDirectoryArg(bundle.dir);
    const signing = ctx.mac_signing;
    if (signing.identity) |id| run.addArgs(&.{ "--identity", id });
    if (signing.notarize_profile) |p| run.addArgs(&.{ "--notarize-profile", p });
    if (signing.dry_run) run.addArg("--dry-run");
    if (signing.active()) run.has_side_effects = true;
    const install = ctx.b.addInstallFileWithDir(
        out_dir.path(ctx.b, dmg_filename),
        .prefix,
        ctx.b.fmt("package/{s}", .{dmg_filename}),
    );
    return &install.step;
}

/// Like `isFeatureEnabled`, for features whose default is not "on".
pub fn isFeatureEnabledDefault(dep: *std.Build.Dependency, comptime name: []const u8, default: bool) bool {
    if (dep.builder.user_input_options.get(name) == null) return default;
    return isFeatureEnabled(dep, name);
}

fn isFeatureEnabled(dep: *std.Build.Dependency, comptime name: []const u8) bool {
    if (dep.builder.user_input_options.get(name)) |opt| {
        switch (opt.value) {
            .flag => return true,
            .scalar => |s| return !std.mem.eql(u8, s, "false"),
            else => return true,
        }
    }
    return true; // default enabled
}

/// Return the top-level step `name`, creating it on first use, so the
/// build helpers can run more than once per `b` without `b.step` panicking.
pub fn getOrCreateStep(b: *std.Build, name: []const u8, description: []const u8) *std.Build.Step {
    if (b.top_level_steps.get(name)) |tls| {
        return &tls.step;
    }
    return b.step(name, description);
}

/// `-Dappimage-runtime`, declared once: `b.option` panics on a second
/// declaration, so later calls read the already-declared value.
fn getOrDeclareAppImageRuntimeOption(b: *std.Build) ?[]const u8 {
    if (b.available_options_map.get("appimage-runtime") != null) {
        const option_ptr = b.user_input_options.getPtr("appimage-runtime") orelse return null;
        option_ptr.used = true;
        return switch (option_ptr.value) {
            .scalar => |s| s,
            else => null,
        };
    }
    return b.option([]const u8, "appimage-runtime", "Override path to AppImage type-2 runtime");
}

/// `-Dwebview2-loader`, declared once: `b.option` panics on a second
/// declaration, so later calls read the already-declared value.
fn getOrDeclareWebView2LoaderOption(b: *std.Build) ?[]const u8 {
    if (b.available_options_map.get("webview2-loader") != null) {
        const option_ptr = b.user_input_options.getPtr("webview2-loader") orelse return null;
        option_ptr.used = true;
        return switch (option_ptr.value) {
            .scalar => |s| s,
            else => null,
        };
    }
    return b.option([]const u8, "webview2-loader", "Path to WebView2Loader.dll for Windows packaging");
}
