# CLI reference

[Back to Oriel](../README.md) · [Documentation](README.md)

## The `oriel` CLI

A single binary for Linux (static), macOS and Windows (x86_64 and aarch64;
no GTK needed to run it) that scaffolds apps and wraps their build steps,
like `create-tauri-app` and `tauri dev/build`.

```sh
# Linux and macOS: install to ~/.local/bin (or $ORIEL_INSTALL_DIR); pin with ORIEL_VERSION=v0.9.0.
curl -fsSL https://raw.githubusercontent.com/highercomve/Oriel/main/install.sh | sh
```

```powershell
# Windows (PowerShell): installs to %LOCALAPPDATA%\Programs\oriel (or $env:ORIEL_INSTALL_DIR), no admin rights.
irm https://raw.githubusercontent.com/highercomve/Oriel/main/install.ps1 | iex
```

The CLI brings its own Zig when needed: it uses the project's Zig version
(`build.zig.zon` `.minimum_zig_version`) from `$ORIEL_ZIG`, else `zig` on PATH
when that is the right version, else `~/.oriel/zig/<version>`, which it
downloads (minisign-verified) on first use. See [Zig versions](#zig-versions-oriel-zig).

| Command | What it does |
|---|---|
| `oriel init <name>` | New app in `./<name>`: `build.zig`, `build.zig.zon`, `src/main.zig` with sample `Commands`/`Events`, the frontend, and README. Adds Oriel, fetches dependencies and runs `npm install`, so the first build works offline |
| `oriel doctor` | Checks requirements for building and running Oriel apps (`--fix` installs non-admin tools and prints exact system commands) |
| `oriel setup [tool]` | Installs managed tools into `~/.oriel/<tool>` without admin rights (`node`, `nsis`, `webview2`, `zig`, `all`) |
| `oriel dev` | Runs the frontend dev server (Vite) and rebuilds + restarts the app when a `.zig` file changes (hot reload; inotify on Linux, polling on macOS and Windows) |
| `oriel build` | Builds the production app (frontend embedded) into `zig-out/bin/` (`ReleaseSafe` by default) |
| `oriel run` | Builds and runs the production app |
| `oriel package` | Builds distribution packages into `zig-out/package/` (deb, rpm, AppImage on Linux; NSIS `setup.exe` on Windows; `.app` and `.dmg` on macOS) |
| `oriel types` | Regenerates the frontend's TypeScript types (`frontend/src/oriel.ts`) from the Zig `Commands` |
| `oriel check` | Type-check the app's Zig code without building binaries (~1 s) |
| `oriel webview2` | Downloads, verifies (SHA-512 against NuGet registration catalog), and caches Microsoft Edge `WebView2Loader.dll` for Windows (`--version <ver>`, `--arch x64|arm64|all`, `--out <dir>`) |
| `oriel deep-link` | Configure and register custom URL schemes (`add <scheme>`, `register`, `unregister`) |
| `oriel desktop-entry` | Linux: installs the app's `.desktop` file and icons for the build in `zig-out` (global hotkeys need it on Wayland); `--release`, `--remove` |
| `oriel zig` | Manages the Zig versions the CLI uses in `~/.oriel/zig` (`install [version]`, `uninstall <version>`, `list`, `which`) |
| `oriel update` | Updates the CLI binary in place using Oriel's self-updater (`--check`, `--version <tag>`, `--yes`) |
| `oriel --version` | CLI version and the Oriel ref `init` pins |

Every command that acts on an app (`dev`, `build`, `run`, `package`, `types`, `check`)
works from anywhere inside the project, found by walking up to `build.zig.zon`.
Extra arguments are passed through to the underlying build step, e.g.
`oriel build -Doptimize=ReleaseFast`, `oriel package -Dtarget=x86_64-windows` (which automatically supplies the cached `WebView2Loader.dll`),
`oriel run -- --flag`.

### Managed tools and setup (`oriel setup`, `oriel doctor --fix`)

Oriel can download and install developer dependencies without requiring administrator or root rights:

```sh
oriel doctor --fix          # install missing non-admin tools, print exact system commands for the rest
oriel setup all             # install all managed tools required for this OS
oriel setup node [version]  # download and install official Node.js LTS into ~/.oriel/node/<version>
oriel setup nsis            # Windows hosts: download official portable NSIS into ~/.oriel/nsis/3.12
oriel setup webview2        # download and cache Microsoft WebView2Loader.dll
oriel setup zig [version]   # alias to `oriel zig install`
```

When building, developing, or packaging (`oriel build`, `oriel dev`, `oriel run`, `oriel package`), the CLI automatically detects and uses tools installed in `~/.oriel/` (or `$ORIEL_HOME`) if they are missing from system `PATH`:
- If `node` / `npm` are missing from `PATH`, `~/.oriel/node/<v>/bin` (or directory on Windows) is prepended to `PATH` for build subprocesses.
- If `makensis` is missing from `PATH` when packaging for Windows, `~/.oriel/nsis/<v>/makensis.exe` is located and passed automatically.

| Variable | Effect |
|---|---|
| `ORIEL_HOME` | Where Oriel keeps its data instead of `~/.oriel` (tools go in `$ORIEL_HOME/<tool>`) |
| `ORIEL_MAKENSIS` | Override path to `makensis` executable |
| `ORIEL_NSIS_PLATFORM` | Override host OS check for NSIS (e.g. `windows` for testing) |
| `ORIEL_NODE_PLATFORM` | Override host OS check for Node.js download |

### Zig versions (`oriel zig`)

Every command that runs Zig (`dev`, `build`, `run`, `package`, `types`,
`check`, `init`) picks the project's Zig, the `.minimum_zig_version` in
`build.zig.zon` (a matching Zig has the same major.minor and is not older):

1. `$ORIEL_ZIG`, if set (it must be a matching version).
2. `zig` on PATH, if it matches (a different version is skipped).
3. `~/.oriel/zig/<version>/zig` (Windows: `%USERPROFILE%\.oriel\zig\<version>\zig.exe`).
4. Otherwise that version is installed there on first use.

```sh
oriel zig which              # the zig this project uses, and where it comes from
oriel zig install            # the project's version (or: oriel zig install 0.16.0)
oriel zig list               # installed versions, and the zig on PATH
oriel zig uninstall 0.16.0
```

Downloads follow Zig's [community mirror guidance](https://ziglang.org/download/community-mirrors/): the
tarball and its `.minisig` come from the mirrors in random order, with
ziglang.org as the last fallback, and a slow or stalled mirror is skipped. A
tarball is used only if its minisign signature verifies against the Zig
Software Foundation's key (from ziglang.org/download), including the trusted
comment, whose `file:` name must be the requested tarball. It is extracted
with path checks (no absolute paths, `..`, drive letters or symlinks) and moved
into place atomically under a lock file, so concurrent installs don't clash.

| Variable | Effect |
|---|---|
| `ORIEL_ZIG` | Use this Zig binary (must be the project's version) |
| `ORIEL_NO_ZIG_INSTALL=1` | Never download Zig: fail with a hint instead |
| `ORIEL_ZIG_MIRRORS` | Use these mirrors (whitespace- or comma-separated https URLs) instead of the community list, e.g. a company mirror; still verified, ziglang.org stays the fallback |

### `oriel init` options

- `--template react|vue|svelte|vanilla`: React (default), Vue and Svelte are
  Vite projects with typed `invoke`/`listen`; vanilla is a static page with
  no build step and no Node.js.
- `--id com.example.App`: the application id (default `com.example.<Name>`).
- `--oriel-ref <tag|commit>`: the Oriel version to depend on (default: the
  one the CLI was built for).
- `--oriel-path <dir>`: depend on a local Oriel checkout (`.path`), for
  developing against a local copy of Oriel.
- `--no-install`: only record the dependency; skip fetching dependencies and
  `npm install`.
- `--no-webview2`: skip downloading `WebView2Loader.dll` for Windows builds.
- `--yes`: skip confirmation prompt when installing missing Node.js for Vite templates.

### Updating the CLI

`oriel update` updates the running binary in place using Oriel's built-in self-updater engine:

```sh
oriel update --check          # Check whether a newer version is available without installing
oriel update                  # Update to the latest release (prompts for confirmation on a TTY)
oriel update --yes            # Update without prompting (required in non-interactive/CI environments)
oriel update --version v0.9.0 # Update or downgrade to a specific release tag
```

The CLI checks GitHub Releases (`highercomve/Oriel`), downloads the release's `latest.json` (one signed entry per platform; releases before v0.3.1 only have `oriel-update-<arch>-<os>.json`, used as a fallback), verifies the Ed25519 signature of the entry for its own platform against the embedded release key, verifies the payload SHA-256 hash, and atomically replaces the running binary (on Windows, where a running exe can't be overwritten, it is renamed to `oriel.exe.old` first and removed on the next run). The manifest endpoint can be overridden for testing via `ORIEL_RELEASES_URL`.

### Permission commands

`oriel permission add <kind> ["reason"]`, `remove <kind>` and `list` edit
`.permissions` in the app's `build.zig` (see [OS permissions](app-development.md#os-permissions-orielpermissions)).

### Signing commands

`oriel signing create`, `import <file.p12>` and `show` make and install a
self-signed macOS code-signing certificate, so an app without a Developer ID
keeps its permission grants across updates (see
[macOS packaging](packaging.md#without-a-developer-id-a-self-signed-certificate)).

### Deep link commands

`oriel deep-link` configures and registers custom URL schemes for local development:

```sh
oriel deep-link add <scheme>   # Enables .deep_link = true and adds scheme to package url_schemes in build.zig
oriel deep-link register       # Registers the built binary with the OS for development testing
oriel deep-link unregister     # Removes the development registration
```

- **Linux:** `register` creates `$XDG_DATA_HOME/applications/<app_id>.desktop` pointing to the built binary with `%u` and associates it via `xdg-mime default`.
- **Windows:** `register` writes `HKCU\Software\Classes\<scheme>` pointing to the built binary.
- **macOS:** `register` registers the `zig-out/<Name>.app` bundle that `oriel build` writes (its Info.plist declares the schemes) with Launch Services (`lsregister -f`); `unregister` runs `lsregister -u`.
