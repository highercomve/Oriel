# Packaging apps

[Back to Oriel](../README.md) · [Documentation](README.md)

## Packaging

Oriel provides integrated packaging for Linux distributions, portable AppImages, Windows installer executables (`setup.exe`) and macOS `.app` bundles and `.dmg` images, with an extensible format architecture. Apps configure packaging metadata in `build.zig` via `.package` inside `oriel.addApp`.

### Packaging metadata

Metadata is configured once in `build.zig` and shared across all target package formats:

```zig
.package = .{
    .id = "dev.oriel.ReactNotes",          // Reverse-DNS application ID (matches desktop entry / registry uninstall key)
    .name = "Oriel React Notes",           // Display name (defaults to executable name)
    .summary = "Desktop notes app",        // Short comment / summary
    .description = "A desktop notes...",   // Multi-line description for package managers
    .publisher = "Acme Corp <dev@acme.com>", // Maintainer / Vendor / Publisher (set this; defaults to display name)
    .license = "MIT",                      // Optional SPDX license identifier (omitted if null)
    .homepage = "https://example.com",     // Optional project URL (omitted if null)
    .categories = "Utility;TextEditor;",   // Semicolon-delimited XDG desktop categories
    .version = "0.1.0",                    // Version string (defaults to "0.1.0")
    .icon = b.path("path/to/icon.png"),    // Optional PNG icon (defaults to Oriel brand icon; converted to .ico for Windows, .icns for macOS)
    .formats = null,                       // Optional override list of formats (defaults to per-OS list)
    .extra_deb_depends = &.{},             // Extra deb runtime dependencies
    .extra_rpm_depends = &.{},             // Extra rpm runtime dependencies
    .replaces = &.{"old-app-name"},       // deb Replaces / rpm Obsoletes: installing this upgrades them
    .conflicts = &.{"old-app-name"},      // deb/rpm Conflicts: never installed side by side
    .webview2_loader = null,               // Optional path to WebView2Loader.dll for Windows (or via -Dwebview2-loader)
    .contents = .{},                       // What else the packages hold (see "Package contents")
},
```

> **Note on publisher**: Always set `.publisher` to your organization or maintainer contact info; if omitted, it defaults to the display name.

### Package contents

Besides the app's executable, `.contents` chooses what every package (deb, rpm, AppImage, NSIS `setup.exe`, `.app`/`.dmg`) holds:

```zig
const cli = b.addExecutable(.{ .name = "notes-cli", .root_module = ... });
_ = oriel.addApp(b, dep, .{
    ...
    .package = .{
        .id = "dev.oriel.Notes",
        .contents = .{
            .executables = &.{cli},       // other executables of the build, next to the app's
            .files = &.{                  // files at a path relative to the app's executable
                .{ .path = "data/model.bin", .source = b.path("data/model.bin") },
            },
            .runtime_libraries = true,    // Oriel's runtime libraries (libggml-cuda.so with -Dggml_cuda); default on
            .strip = true,                // strip ELF executables and libraries in the packages; default on
        },
    },
});
```

- **`executables`**: installed next to the app's executable under their file names (e.g. `notes-cli`, `notes-cli.exe`).
- **`files`**: `path` is relative to the executable's directory, `/`-separated, with no `.` or `..` components (e.g. `data/model.bin`; at most 200 bytes, and no names Windows can't hold: components ending in `.` or a space, `con`, `nul`, `com1`, ...); files are installed as they are (mode 0644, not stripped).
- **`runtime_libraries`**: with `-Dggml_cuda`, `libggml-cuda.so` goes next to the executable, where the app loads it from. A `files` entry with the path `libggml-cuda.so` replaces it.
- **`strip`**: Linux packages get copies of the app, `executables` and the runtime libraries without the symbol table and debug info (like `strip --strip-all`: the dynamic symbol table stays, so a `-Dggml_cuda` app still exports ggml to `libggml-cuda.so`). A ReleaseSafe app drops from about 70 MB to under 20 MB. `zig-out` keeps the unstripped binaries. The app's own executable is stripped too, so a packaged ReleaseSafe app's crash traces show addresses instead of function names: set `.strip = false` to ship the symbols.

Where they go:

| Format | App executable | Extra executables and files |
|---|---|---|
| deb / rpm, no extras | `/usr/bin/<exe>` | — |
| deb / rpm, with extras | `/usr/lib/<exe>/<exe>` | `/usr/lib/<exe>/`, plus `/usr/bin/<name>` symlinks for every executable |
| AppImage | `usr/bin/<exe>` | `usr/bin/` |
| NSIS | `$INSTDIR\<exe>.exe` | `$INSTDIR\` (removed again by the uninstaller, and emptied subdirectories with them) |
| macOS `.app` | `Contents/MacOS/<exe>` | executables and Mach-O files in `Contents/MacOS/` (signed inside-out with the bundle); other files in `Contents/Resources/`, with a symlink `Contents/MacOS/<top-level name>` → `../Resources/<top-level name>` so paths relative to the executable still work |

With extras, deb and rpm keep everything in `/usr/lib/<exe>/` so each program finds its companions next to its own path (the `/usr/bin` symlinks resolve there): the app loads `libggml-cuda.so` from its executable's directory, and a CLI can start the app next to it. The package tools refuse destinations that collide (two entries, or an entry and the app's executable) and paths that would leave the install directory.

### Building packages

Running `oriel package` in an application directory builds production packages into `zig-out/package/`. All intermediate build files (`nfpm.yaml`, `AppDir`, SquashFS, `installer.nsi`) are isolated in Zig's cache directory:

```sh
# All formats for the current target OS:
oriel package

# Cross-compile Windows installer from Linux (WebView2 loader injected automatically):
oriel package -Dtarget=x86_64-windows
```

- **All formats for target OS**: `oriel package` (defaults to `.deb`, `.rpm`, `.AppImage` on Linux; NSIS `setup.exe` on Windows; `.app` and `.dmg` on macOS).
- **macOS (`.app`, `.dmg`)**: `oriel package` on a Mac → `zig-out/package/<Name>.app` and `zig-out/package/<exe>-<version>.dmg` (the `.app` plus an `Applications` link to drag it to). `oriel build` also installs `zig-out/<Name>.app`. See [macOS bundles](#macos-bundles-app-dmg).
- **Windows Installer (`setup.exe`)**: `oriel package` on Windows, or cross-compiled with `-Dtarget=x86_64-windows` → `zig-out/package/<name>-<version>-setup.exe` (WebView2Loader.dll is resolved from cache automatically, or pass `-Dwebview2-loader=...` manually).
- **Windows MSIX (`.msix`, opt-in)**: add `.msix` to `package.formats` (e.g. `.formats = &.{ .nsis, .msix }`) → `zig-out/package/<name>-<version>.msix`, built by Oriel itself (no Windows SDK; works from Linux). The manifest declares a full-trust desktop app, capabilities from `.permissions` (bluetooth, `privateNetworkClientServer` for local_network, microphone, webcam, location, graphics capture), and for `.share_target` a Share Target plus "Open with" for its `windows_extensions`. `package.msix` sets `publisher` (the signing certificate's Subject, exactly), `publisher_display_name`, `identity_name` and `min_version`. Signing is never in `build.zig`: `-Dmsix-pfx=<file>` with the password in `$ORIEL_MSIX_PFX_PASSWORD`, or `-Dmsix-cert-sha1=<thumbprint>` for a certificate in your store (or `$ORIEL_MSIX_PFX` / `$ORIEL_MSIX_CERT_SHA1`), plus `-Dmsix-timestamp=<url>`; it runs `signtool` (`$ORIEL_SIGNTOOL`, `PATH`, or the newest Windows Kits 10). Without them the package is unsigned (its publisher carries Windows 11's unsigned OID) and installs with `Add-AppxPackage -AllowUnsigned`, for development and testing.
- **Individual formats**: inside the app project, `oriel.addApp` also registers granular app build steps if you need to build only a single format: `zig build package-deb`, `zig build package-rpm`, `zig build package-appimage`, `zig build package-nsis`, `zig build package-msix`, `zig build package-app`, `zig build package-dmg`.

> [!TIP]
> **Packaging existing websites and web apps**: To package an existing web application (like WhatsApp Web, Slack, or Linear) into a standalone AppImage with system tray and close-to-tray support, use [`oriel wrap <url> --package`](cli.md#wrapping-web-apps-oriel-wrap-oriel-pake).

#### Requirements and tools

- **`makensis` (NSIS v3+)**: Used to compile the Windows installer executable (`setup.exe`). Looked up in `$PATH`, `/usr/bin/makensis`, and `/usr/local/bin/makensis` (the `nsis` package on Arch, Debian and Ubuntu). Cross-builds Windows installers directly from Linux hosts.
- **`nfpm`**: Used to generate `.deb` and `.rpm` packages. Looked up in `$PATH`, then `$HOME/go/bin/nfpm`.
- **`mksquashfs`**: Used to assemble AppImage SquashFS images.
- **`desktop-file-validate`**: Used to validate desktop entry files before packaging and installation.
- **`codesign`, `ditto`, `hdiutil`** (macOS, part of the OS; `xcrun notarytool`/`stapler` from the Xcode command line tools for notarization): signing the `.app` and building the `.dmg`. The `.app` itself can be assembled on any host (unsigned when not built on a Mac); the `.dmg` needs a Mac.
- **AppImage Runtime**: Uses standard type-2 AppImage runtime (`runtime-<arch>`), automatically downloaded and cached in the local cache dir (overridable via `-Dappimage-runtime=<path>` or env `ORIEL_APPIMAGE_RUNTIME`). Verified for ELF header magic before use.

#### Windows NSIS installer details

The generated NSIS installer provides:
- **Per-user installation**: Installed to `$LOCALAPPDATA\Programs\<name>` without requiring administrator elevation (`RequestExecutionLevel user`).
- **Start Menu integration**: Shortcuts for launching the application and the uninstaller under `$SMPROGRAMS\<name>`.
- **Uninstaller**: Full uninstaller at `$INSTDIR\Uninstall.exe` registered in Windows Add/Remove Programs (`Software\Microsoft\Windows\CurrentVersion\Uninstall\<id>` under `HKCU`).
- **Multi-resolution ICO**: Automatically converts your PNG application icon into a multi-resolution Windows `.ico` (16, 32, 48, 64, 128, 256 px).
- **WebView2 Runtime Detection**: Checks the Windows Registry (HKCU and HKLM in both 64-bit and 32-bit views) for the Evergreen WebView2 Runtime (`{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}`). If missing, prompts the user to download and run the Microsoft Evergreen Bootstrapper (`https://go.microsoft.com/fwlink/p/?LinkId=2124703`) or opens the download page.
- **`WebView2Loader.dll`**: Required next to the executable on Windows. Specify it via `.webview2_loader` in `build.zig` or via CLI option `-Dwebview2-loader=<path>` (e.g. from the `Microsoft.Web.WebView2` NuGet package runtimes). Oriel loads it exclusively from the application's executable directory to prevent DLL search-order hijacking. User data is isolated per application in `%LOCALAPPDATA%\<app_id>\WebView2`.
- *Note*: Packaging a Windows application requires the target app executable to be compiled for Windows (which requires the Windows shell in `src/platform/windows`).

#### WinGet (`winget install`)

WinGet installs from a public URL (a GitHub release asset) described by three
YAML manifests in microsoft/winget-pkgs. Give the app an identifier and a
license, and `oriel package` writes the manifests next to the `setup.exe`:

```zig
.package = .{
    .license = "MIT", // required by WinGet
    .homepage = "https://example.com/my-app",
    .winget = .{ .id = "Acme.MyApp", .moniker = "myapp", .tags = &.{ "notes" } },
},
```

```sh
oriel package -Dwinget-url=https://github.com/acme/my-app/releases/download/v1.2.0   # or $ORIEL_WINGET_URL
# zig-out/package/winget/Acme.MyApp.yaml, .installer.yaml, .locale.en-US.yaml
```

- The installer manifest is `nullsoft`, per-user (`Scope: user`), silent with
  `/S`, and its `ProductCode` is the app id: the key the installer writes under
  `HKCU\...\Uninstall`, so `winget upgrade` recognizes an installed copy. The
  SHA-256 is that of the `setup.exe` just built: publish that exact file.
- Submit them once the release is public: `wingetcreate submit --token <PAT>
  zig-out/package/winget` opens the pull request (a GitHub token with
  `public_repo`). Microsoft's bots install it in a sandbox and merge it, and
  then `winget install Acme.MyApp` works. The same command submits each new
  version.
- Without `-Dwinget-url` (local builds) no manifests are written.
- A standalone exe (no installer), like the `oriel` CLI itself, is a WinGet
  `portable` package: `zig build winget -- --id Acme.Tool --version 1.2.0
  --name Tool --publisher Acme --license MIT --summary "..." --command tool
  --portable x64=<file>=<url> --portable arm64=<file>=<url> --out-dir <dir>`
  (one `--portable` per architecture; WinGet puts `tool` on PATH). Oriel's own
  release workflow does this for `Highercomve.Oriel`.

#### macOS bundles (.app, .dmg)

`<Name>.app/Contents` holds `MacOS/<exe>`, `Resources/icon.icns` (made from the PNG icon, no `iconutil` needed), `PkgInfo` and an `Info.plist` with:
- `CFBundleIdentifier` = `.package.id`, `CFBundleName`/`CFBundleDisplayName` = `.name`, `CFBundleShortVersionString`/`CFBundleVersion` = `.version`.
- `LSMinimumSystemVersion` = the executable's deployment target (read from its Mach-O `LC_BUILD_VERSION`, so the two always agree). `addApp` builds for macOS 13.0 when the target names no macOS version (a native build, or `-Dtarget=aarch64-macos`), not for the Mac doing the build, so a release built on a newer Mac or CI runner still runs on older ones; `-Dtarget=aarch64-macos.14.0` picks another minimum. A native CPU becomes the architecture's baseline (Apple M1, x86-64) for the same reason (`-Dcpu` overrides it). Other executables an app puts in the bundle (`.package.contents`) should use `oriel.resolveTarget(b, target)` too; `package-app` warns when one needs a newer macOS than the app. (An executable that links Apple frameworks without importing `oriel` must add the SDK's framework path itself: Zig adds it only for native targets.)
- `CFBundleURLTypes` for `.url_schemes` (deep links).
- `NSMicrophoneUsageDescription` and `NSAudioCaptureUsageDescription` when `audio_capture` is enabled (macOS refuses the permission without them).

The bundle is **ad-hoc signed** (`codesign --sign -`), which is enough to run it on the Mac that built it and for macOS to attribute notifications and permission prompts to the app.

**Unnotarized downloads and Gatekeeper.** An ad-hoc signed `.app` downloaded from the web (a GitHub release, say) is quarantined, and Gatekeeper refuses it: "Apple could not verify “<Name>” is free of malware…". Since macOS 15 the old right-click → Open shortcut no longer opens it. Users can allow it once in **System Settings → Privacy & Security → Open Anyway** (after the first attempt, with their password), or clear the quarantine flag from a terminal: `xattr -dr com.apple.quarantine /Applications/<Name>.app`. Notarizing the release (below) removes the prompt.

##### Without a Developer ID: a self-signed certificate

Ad-hoc signed, macOS identifies the app by the hash of that exact build, so every update looks like a new app: the user's grants (Accessibility, Microphone, Screen Recording) stop applying and are asked again. Signed with the same certificate every release, even a self-signed one, the app's designated requirement names the certificate (`identifier "<id>" and certificate leaf = H"<sha1>"`) and the grants survive updates. Gatekeeper still asks once on first launch (only notarization removes that). `oriel signing` makes and installs such a certificate:

```sh
oriel signing create --name "My App"     # ~/.config/oriel/keys/my-app-codesign.p12 + .password (0600); prints the SHA-1
oriel signing import ~/.config/oriel/keys/my-app-codesign.p12   # macOS: into a new unlocked keychain (CI); --keychain login for yours
oriel package -Dmacos-sign-identity=<SHA-1>
```

- `create` needs `openssl`; the `.p12` uses SHA1-3DES encryption and a SHA-1 MAC, which `security import` reads (OpenSSL 3's default AES `.p12` fails with "MAC verification failed"). The private key is never printed. Keep the files and reuse them: a new certificate is a new identity.
- `import` creates `oriel-signing.keychain-db` with a random throwaway password, unlocks it without a timeout, lets `codesign` use the key without prompts (`set-key-partition-list`) and puts it first in the user's keychain search list (codesign only finds identities there). `security delete-keychain oriel-signing.keychain-db` removes it. The password comes from `<file>.password` or `--password-env VAR`.
- The certificate is untrusted: `security find-identity -v` doesn't list it (without `-v` it shows `CSSMERR_TP_NOT_TRUSTED`), but `codesign` signs with it, by SHA-1 or name, and Apple's timestamp server accepts it. `oriel signing show` prints the SHA-1.
- In CI: store the `.p12` (base64) and its password as secrets, write the file, `oriel signing import <file> --password-env MACOS_CERT_PASSWORD`, then `oriel package -Dmacos-sign-identity=<SHA-1>`.

**Distribution (Developer ID + notarization).** Other Macs need a Developer ID signature and notarization (an Apple developer account). `oriel package` does both when told which keychain identity and notarytool profile to use; `oriel build`'s `zig-out/<Name>.app` stays ad-hoc (fast, offline):

```sh
# once: store notarization credentials in the keychain (Apple ID + app-specific password, or an API key)
xcrun notarytool store-credentials oriel-notary --apple-id you@example.com --team-id AB12CD34EF

oriel package -Dmacos-sign-identity="Developer ID Application: Your Name (AB12CD34EF)" \
              -Dmacos-notarize-profile=oriel-notary
```

- `-Dmacos-sign-identity` (or `ORIEL_MACOS_SIGN_IDENTITY`): the `.app` in `zig-out/package` is signed with the hardened runtime, the generated `<Name>.entitlements` (usage entitlements for the declared permissions, e.g. `com.apple.security.device.audio-input`) and a secure timestamp, then checked with `codesign --verify --strict`. The `.dmg` is signed only when it is also notarized: macOS 15 refuses to open a signed disk image whose signature it can't verify (self-signed, or not notarized), which would mean a second Gatekeeper prompt; unsigned, only the app inside is assessed. `security find-identity -v -p codesigning` lists the identities. `-` signs ad-hoc with the hardened runtime, to try the runtime and entitlements locally.
- `-Dmacos-notarize-profile` (or `ORIEL_MACOS_NOTARIZE_PROFILE`): the signed `.dmg` goes to `xcrun notarytool submit --wait`; when Apple accepts it, the ticket is stapled (`xcrun stapler staple`) and `spctl` checks it. A rejection prints the `xcrun notarytool log` command with the submission id. Credentials stay in the keychain: the build only passes the profile name.
- The two bundles have different code signatures, so macOS keeps separate permission grants (Accessibility, Microphone, …) for `zig-out/<Name>.app` and the signed package.
- Nested code (`.contents` executables and libraries in `Contents/MacOS`) is signed first, inside-out, with the same identity, the hardened runtime and a secure timestamp (executables with the app's entitlements, libraries without), then the bundle; no `--deep`. Data files live in `Contents/Resources` (codesign refuses non-code files in `Contents/MacOS`); the symlinks to them are sealed with the bundle. A sandboxed app's helper executables would need `com.apple.security.inherit` instead of the app's entitlements; Oriel doesn't generate a sandbox entitlement.
- `-Dmacos-sign-dry-run`: print the `codesign`/`notarytool`/`stapler`/`spctl` commands without running them (no identity or profile needed), and sign the package ad-hoc with the hardened runtime and the entitlements, so it runs as the signed app would.

#### The AppImage caveat (system GTK4 & WebKitGTK 6.0)

The AppImage does not bundle GTK4 or WebKitGTK: it relies on the host's GTK4 and WebKitGTK 6.0 (install `gtk4` / `webkitgtk-6.0` or your distro's equivalent). WebKitGTK spawns helper processes (`WebKitWebProcess`, `WebKitNetworkProcess`) from fixed install paths and loads GPU, GStreamer and font stacks that must match the host, so relocating it into an AppImage needs patched paths and a much larger bundle; that is not done yet. The AppImage is therefore small (a few MB) and portable across distros that ship WebKitGTK 6.0, but not to systems without it.

#### Automatic dependency derivation

Runtime package dependencies for Debian and RPM packages are automatically derived from the Oriel features enabled in `build.zig`:
- Base: `libgtk-4-1` / `gtk4`, `libwebkitgtk-6.0-4` / `webkitgtk6.0`
- `global_shortcut`: `libx11-6` / `libX11`
- `input`: `libxkbcommon0` / `libxkbcommon`, `libxtst6` / `libXtst`
- `input` or `clipboard`: `libwayland-client0` / `libwayland-client`

### Adding formats

The packaging system is built around a pluggable `Format` enum and per-format dispatch in `build/package.zig`. To support additional packaging formats (such as Windows `msi` via WiX):
1. Add the enum value to `Format` (e.g. `msi`).
2. Add a corresponding `fn addMsi(ctx: *const Context) *std.Build.Step` function.
3. Add a branch to the `switch (format)` dispatcher in `addFormat`.
4. Include the format in `defaultFormats(os_tag)`.

When an unsupported OS target is packaged (or no formats are configured), `oriel package` fails gracefully at build time with a clear message (`"no package formats for <os> yet"`) via `b.addFail`.

### Desktop entry for local runs (`oriel desktop-entry`)

Installed packages ship a `.desktop` file; a build running from `zig-out` has none. On Linux, `oriel desktop-entry` installs one for the local build into `$XDG_DATA_HOME` (`~/.local/share` fallback), so global hotkeys (the GlobalShortcuts portal), the app menu and notifications know the app:

```sh
oriel desktop-entry            # the dev build (<id>.Dev, `oriel dev`), or the production build without a dev mode
oriel desktop-entry --release  # the production build (<id>, `oriel build` / `oriel run`)
oriel desktop-entry --remove   # remove both
```

(`zig build desktop-entry` / `desktop-entry-release` are the underlying steps.) It installs:

- **Desktop Entry**: `$XDG_DATA_HOME/applications/<id>.desktop` (validated with `desktop-file-validate`)
- **Icons**: `$XDG_DATA_HOME/icons/hicolor/<size>x<size>/apps/<id>.png` (sizes: 16, 32, 48, 64, 128, 256, 512)

#### Why install a development desktop entry?

1. **Wayland Global Shortcuts**: The `org.freedesktop.portal.GlobalShortcuts` portal requires an installed desktop entry matching the application ID to register system-wide hotkeys.
2. **Dev vs. Prod Isolation**: When a dev executable exists, the entry ID is suffixed with `.Dev` (e.g. `dev.oriel.ReactNotes.Dev`), `Name` is suffixed with `(Dev)`, and `Exec` points to the absolute path of the local dev binary in `zig-out/bin/`, preventing collisions with installed production applications.
