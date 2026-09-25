//! Packaging step builder for Oriel applications.
//!
//! Provides pluggable package format dispatch per target OS.
//! Supported formats: .deb, .rpm, .AppImage on Linux, NSIS setup.exe on Windows.

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
///
/// Future formats:
/// - `msi`: Windows installer MSI generated via WiX toolset.
pub const Format = enum {
    deb,
    rpm,
    appimage,
    nsis,
};

/// Return default package formats for a given operating system.
pub fn defaultFormats(os_tag: std.Target.Os.Tag) []const Format {
    return switch (os_tag) {
        .linux => &.{ .deb, .rpm, .appimage },
        .windows => &.{ .nsis },
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

    /// High-resolution icon (PNG). Defaults to Oriel brand icon (1024x1024).
    icon: ?std.Build.LazyPath = null,

    /// Target package formats to build. Overrides defaultFormats(os) if specified.
    formats: ?[]const Format = null,

    /// Extra runtime dependencies for Debian packages.
    extra_deb_depends: []const []const u8 = &.{},

    /// Extra runtime dependencies for RPM packages.
    extra_rpm_depends: []const []const u8 = &.{},

    /// Optional path to WebView2Loader.dll for Windows packages.
    /// If null, can also be provided via `-Dwebview2-loader=<path>` build option.
    /// When provided, the DLL is copied next to the Windows executable in the installer.
    /// Available from the Microsoft.Web.WebView2 NuGet package (runtimes/win-x64/native/WebView2Loader.dll).
    webview2_loader: ?std.Build.LazyPath = null,
};

/// Format packaging context passed to each format builder function.
pub const Context = struct {
    b: *std.Build,
    oriel_dep: *std.Build.Dependency,
    package_tool: *std.Build.Step.Compile,
    metadata: Metadata,
    target: std.Build.ResolvedTarget,
    exe: std.Build.LazyPath,
    desktop_file: std.Build.LazyPath,
    icons_dir: std.Build.LazyPath,
    deb_deps: []const []const u8,
    rpm_deps: []const []const u8,
    appimage_runtime_override: ?[]const u8,
    webview2_loader: ?std.Build.LazyPath,
};

pub fn addPackageSteps(
    b: *std.Build,
    oriel_dep: *std.Build.Dependency,
    options: anytype,
    exe: *std.Build.Step.Compile,
    dev_exe: ?*std.Build.Step.Compile,
) void {
    const pkg_opts = options.package orelse PackageOptions{};
    const target = exe.root_module.resolved_target.?;
    const os_tag = target.result.os.tag;

    const exe_name = options.name;
    const display_name = pkg_opts.name orelse exe_name;
    const app_id = pkg_opts.id orelse b.fmt("dev.oriel.{s}", .{exe_name});
    const summary = pkg_opts.summary orelse b.fmt("{s} application", .{display_name});
    const description = pkg_opts.description orelse summary;
    const publisher = pkg_opts.publisher orelse display_name;
    const version = pkg_opts.version orelse "0.1.0";
    const categories = pkg_opts.categories orelse "Utility;";
    const icon = pkg_opts.icon orelse oriel_dep.path("assets/brand/oriel-icon-1024.png");

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
        .icon = icon,
        .extra_deb_depends = pkg_opts.extra_deb_depends,
        .extra_rpm_depends = pkg_opts.extra_rpm_depends,
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
    const brand_dir = oriel_dep.path("assets/brand");

    // 1. Shared icon resizing into cache
    const run_icons = b.addRunArtifact(package_tool);
    run_icons.addArg("resize-icons");
    run_icons.addArg("--input");
    run_icons.addFileArg(metadata.icon);
    run_icons.addArg("--out-dir");
    const icons_dir = run_icons.addOutputDirectoryArg("icons");
    run_icons.addArg("--brand-dir");
    run_icons.addDirectoryArg(brand_dir);

    // 2. Shared production desktop file in cache
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

    const ctx = Context{
        .b = b,
        .oriel_dep = oriel_dep,
        .package_tool = package_tool,
        .metadata = metadata,
        .target = target,
        .exe = exe.getEmittedBin(),
        .desktop_file = desktop_file,
        .icons_dir = icons_dir,
        .deb_deps = deb_deps.items,
        .rpm_deps = rpm_deps.items,
        .appimage_runtime_override = appimage_runtime_override,
        .webview2_loader = webview2_loader,
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
        package_step.dependOn(step);
        getOrCreateStep(b, b.fmt("package-{s}", .{@tagName(fmt)}), b.fmt("Build only the {s} package", .{@tagName(fmt)})).dependOn(step);
    }

    // Desktop-entry step (for local development)
    const has_dev = dev_exe != null;
    const effective_app_id = if (has_dev) b.fmt("{s}.Dev", .{metadata.id}) else metadata.id;
    const effective_name = if (has_dev) b.fmt("{s} (Dev)", .{metadata.name}) else metadata.name;
    const target_bin_name = if (has_dev) b.fmt("{s}-dev", .{metadata.exe_name}) else metadata.exe_name;
    const target_compile = if (has_dev) dev_exe.? else exe;

    const run_dev_desktop = b.addRunArtifact(package_tool);
    run_dev_desktop.addArg("generate-desktop");
    run_dev_desktop.addArg("--out");
    const dev_desktop_file = run_dev_desktop.addOutputFileArg(b.fmt("{s}.desktop", .{effective_app_id}));
    const abs_bin = b.pathFromRoot(b.getInstallPath(.bin, target_bin_name));
    run_dev_desktop.addArgs(&.{
        "--id",               effective_app_id,
        "--name",             effective_name,
        "--exec",             abs_bin,
        "--icon",             effective_app_id,
        "--comment",          metadata.summary,
        "--categories",       metadata.categories,
        "--terminal",         "false",
        "--startup-notify",   "true",
        "--startup-wm-class", effective_app_id,
    });

    const run_install_desktop = b.addRunArtifact(package_tool);
    run_install_desktop.addArg("install-desktop-entry");
    run_install_desktop.addArg("--desktop");
    run_install_desktop.addFileArg(dev_desktop_file);
    run_install_desktop.addArg("--icons-dir");
    run_install_desktop.addDirectoryArg(icons_dir);
    run_install_desktop.addArg("--app-id");
    run_install_desktop.addArg(effective_app_id);
    run_install_desktop.has_side_effects = true;

    const desktop_entry_step = getOrCreateStep(b, "desktop-entry", "Install desktop entry and icons for development to $XDG_DATA_HOME");
    desktop_entry_step.dependOn(&b.addInstallArtifact(target_compile, .{}).step);
    desktop_entry_step.dependOn(&run_install_desktop.step);
}

/// Dispatch format builder based on Format enum.
fn addFormat(ctx: *const Context, format: Format) *std.Build.Step {
    return switch (format) {
        .deb => addDeb(ctx),
        .rpm => addRpm(ctx),
        .appimage => addAppImage(ctx),
        .nsis => addNsis(ctx),
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
    run.addFileArg(ctx.exe);
    run.addArg("--desktop");
    run.addFileArg(ctx.desktop_file);
    run.addArg("--icons-dir");
    run.addDirectoryArg(ctx.icons_dir);
    for (ctx.deb_deps) |dep| {
        run.addArgs(&.{ "--deb-dep", dep });
    }

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
    run.addFileArg(ctx.exe);
    run.addArg("--desktop");
    run.addFileArg(ctx.desktop_file);
    run.addArg("--icons-dir");
    run.addDirectoryArg(ctx.icons_dir);
    for (ctx.rpm_deps) |dep| {
        run.addArgs(&.{ "--rpm-dep", dep });
    }

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
    run.addFileArg(ctx.exe);
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
    run.addArg("--bin");
    run.addFileArg(ctx.exe);
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
