# Building and contributing to Oriel

[Back to Oriel](../README.md) · [Documentation](README.md)

## Building Oriel itself

This section is for contributors working on the Oriel framework repository.

### Repository layout

The framework and the apps built with it are separate Zig packages:

| Path | What |
|---|---|
| `build.zig` | Framework build: the `oriel` module, `embed_assets`, `dev_runner`, `addApp()` for apps, unit tests |
| `src/core/` | `App.zig` (platform-neutral windowing, IPC, events, asset lookup, dev mode), `ipc.zig` (command dispatch + TypeScript generation), `log.zig` (file + stderr logging) |
| `src/platform/` | Platform abstraction: `platform.zig` (OS selection & comptime check), `platform/linux/` (GTK4 + WebKitGTK 6.0 shell: `Shell.zig`, `window.zig`, `scheme.zig`, `bridge.zig`, `dev_server.zig`) |
| `src/modules/` | Built-in modules: `tray`, `menu`, `store`, `dialog`, `notification`, `updater`, `media_server`, `sql`, `sqlite_vec`, `llama`, `whisper`, `dictation`, `audio_capture`, `fs_watch` |
| `src/plugins/` | App-specific plugins: `global_shortcut`, `input`, `clipboard` |
| `tools/embed_assets.zig` | Embeds a built frontend directory into the binary |
| `tools/dev_runner.zig` | Hot reload orchestrator: keeps dev server running while watching `src/` and restarting the Zig app |
| `cli/` | The `oriel` command-line tool (`init`, `doctor`, build wrappers) and its embedded app templates |
| `install.sh` | Installs the `oriel` CLI from GitHub Releases |
| `examples/showcase/` | **App:** every feature, on Linux, Windows, macOS, Android and iOS (own package) |
| `examples/smoke/` | **App:** checks every module (own package) |
| `examples/breakout/` | **App:** a canvas game in the WebView and the native renderer, JavaScript or Zig (own package) |
| `examples/render-bench/` | **App:** the native renderer against the WebView: rows, animation, canvas, memory (own package) |
| `examples/canvas-demo/` | **App:** the 2d canvas in the native renderer (own package) |

### Framework build and test commands

From the repository root:

```sh
zig build check              # type-check (~1 s)
zig build test               # framework, tools and CLI unit tests
zig build cli                # the oriel CLI: zig-out/bin/oriel (static)
```

To build and install the `oriel` CLI from a local checkout:

```sh
zig build cli && cp zig-out/bin/oriel ~/.local/bin/
# On Windows (PowerShell):
# zig build cli
# Copy-Item zig-out\bin\oriel.exe "$env:LOCALAPPDATA\Programs\oriel\oriel.exe"
```

### Building examples from the repository

The example apps in `examples/` (`examples/showcase`, `examples/smoke`)
are configured with `.path = "../.."` in their `build.zig.zon` so they build against
the framework working tree:

```sh
# Smoke test (checks modules and security inside real webview)
cd examples/smoke
zig build && ./zig-out/bin/oriel-smoke --check          # non-GUI checks
./zig-out/bin/oriel-smoke --auto-quit                  # in-webview checks

# The showcase (desktop; see its build.zig for Android and iOS)
cd ../showcase
zig build run
```

### Headless testing (`scripts/headless.sh`)

Never test on the user's real desktop session: no clicking, typing,
window raising, or screen capture. Use `scripts/headless.sh` (Xvfb + private D-Bus session):

```sh
scripts/headless.sh ./zig-out/bin/oriel-smoke --auto-quit      # Xvfb + private D-Bus
SHOT=shot.png scripts/headless.sh ./zig-out/bin/my-app        # screenshot after 4 s
```

To test tray menus headlessly, the app owns `org.kde.StatusNotifierItem-<pid>-1` on the private bus:

```sh
gdbus call --session --dest org.kde.StatusNotifierItem-$PID-1 --object-path /MenuBar \
  --method com.canonical.dbusmenu.GetLayout 0 -- -1 '[]'
gdbus call --session --dest org.kde.StatusNotifierItem-$PID-1 --object-path /MenuBar \
  --method com.canonical.dbusmenu.Event 2 clicked '<int32 0>' 0
```

### Testing Windows builds under Wine (`scripts/wine.sh`)

Windows builds cross-compile from Linux (`-Dtarget=x86_64-windows`) and run under Wine
or Steam's Proton headlessly using `scripts/wine.sh`:

```sh
scripts/wine.sh setup                    # one-time: .wine-test/ prefix + WebView2 Evergreen
(cd examples/smoke && zig build -Dtarget=x86_64-windows -Dwebview2-loader=$(../../scripts/wine.sh loader) -p ../../.wine-test/smoke)
timeout 180 scripts/wine.sh run .wine-test/smoke/bin/oriel-smoke.exe --auto-quit
```

See [docs/windows-testing.md](../docs/windows-testing.md) for setup details, Proton detection, and known Wine limitations.

### Process cleanup verification (`test-dev-cleanup`)

`zig build test-dev-cleanup` verifies process tree cleanup for `dev_runner`: when the build runner
process is terminated (SIGTERM or SIGKILL), `dev_runner` uses a pidfd watcher and `PR_SET_PDEATHSIG`
to terminate both Vite and the application process groups cleanly.

### Generating GIR bindings (`scripts/gen-bindings.sh`)

Dependencies, including prebuilt GTK/WebKit bindings (zig-gobject, GNOME 50),
come from the Zig package manager. To use bindings generated from your own
system's GIR files instead (newer GTK/WebKit APIs), run:

```sh
scripts/gen-bindings.sh                  # requires xsltproc
zig build --fork=deps/gobject/bindings
```

### Memory-safety review checklist

Every change must follow the read-only memory-safety review procedure detailed in
[docs/memory-safety-review.md](../docs/memory-safety-review.md):
1. **Leaks and double frees:** verify `defer`/`errdefer` on all allocation paths; ensure tests run with `std.testing.allocator`.
2. **Ownership and lifetimes:** explicit slice ownership; no dangling pointers into stack memory or reset arenas; structs never copied after a pointer to them is retained.
3. **Null and optionals:** check real contracts in GIR definitions and Win32 headers rather than trusting binding signatures.
4. **Reference counting:** balanced `ref`/`unref` and `AddRef`/`Release`; handle floating references on GVariants.
5. **Memory hygiene:** no reads of `undefined`; justified pointer casts; thread-safe shared state; never call GTK or GUI functions off the main thread. Tests must stay silent (zero stderr output).

### Cross-platform development rules

Linux, Windows, and macOS, always. Every feature, the `oriel` CLI
(including `oriel dev` and `oriel update`), and the package installers must work on all three.
OS-specific code goes behind compile-time switches (`builtin.os.tag`) with a dedicated backend
or a clear compile-time error. When developing on an OS where a target cannot run natively,
type-check non-host targets:

```sh
zig build check -Dtarget=x86_64-windows
zig test -target x86_64-linux-musl <file> -fno-emit-bin  # host tools on macOS
```

Always document what has and has not been verified on real hardware.

### Release process and maintainer keys

Releases are triggered by pushing a `v*` tag. The GitHub Actions release workflow
(`.github/workflows/release.yml`) runs tests on Linux, macOS, and Windows, cross-builds
the CLI for 6 targets (`x86_64-linux-musl`, `aarch64-linux-musl`, `x86_64-macos`,
`aarch64-macos`, `x86_64-windows`, `aarch64-windows`), signs an update manifest per target
using `zig build sign-update`, and attaches the binaries, manifests, and `SHA256SUMS` to
the release for consumption by `install.sh`, `install.ps1`, and `oriel update`.

Maintainer key setup:
1. Generate an Ed25519 keypair:
   ```sh
   zig build keygen -- --name oriel-release
   ```
2. In GitHub repository settings:
   - Add the private key seed (`oriel-release.key`) as secret `ORIEL_UPDATE_KEY`.
   - Add the public key (`oriel-release.pub`) as variable `ORIEL_UPDATE_PUBLIC_KEY`.
3. The release workflow passes `-Dupdate-public-key` to `zig build cli` and runs `zig build sign-update` for each platform and `zig build combine-manifests` to attach `latest.json` (which `oriel update` fetches) plus the per-platform `oriel-update-<arch>-<os>.json` files older CLIs use.

## Notes

- Linux and Windows executables link with LLVM + LLD: Zig 0.16's own
  linker rejects the `.sframe` sections in GCC 16 / recent glibc `crt1.o`.
  macOS uses Zig's own Mach-O linker (LLD has no Mach-O support in Zig).
- Dev builds use the app ID plus `.Dev`, so they can run next to the
  production app.

## Documentation site and search

The site uses Zine 0.14.0. [Pagefind](https://pagefind.app/) indexes the rendered
docs after each build; the resulting search bundle is served with the site.
Install Zine and Node.js (24 in CI). Run the commands below from the repository root.

The search button, `/`, or Ctrl/Cmd+K opens the dialog. Search assets and
result links use the configured Zine site prefix, including `/Oriel/` on GitHub
Pages. Preview the checked-in deployment configuration locally with:

```sh
bash scripts/build-site.sh /tmp/oriel-site-preview/Oriel
python3 -m http.server 8000 --directory /tmp/oriel-site-preview
# Open http://localhost:8000/Oriel/docs/
```

Use the prefixed preview for the checked-in `zine.ziggy`. An unprefixed preview
requires clearing `url_path_prefix` in your local configuration. `zine release`
on its own renders the pages but does not generate the search index. The build
script pins Pagefind; its first run downloads the npm package. Only documentation
articles marked with `data-pagefind-body` are indexed, so navigation and the
home page do not appear as results. CI runs the same script before deployment.
