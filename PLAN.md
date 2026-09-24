# Oriel — development plan

Written 2026-09-23. For anyone (human or agent) picking up the work: read
**Context** and **Rules** first. The milestones are ordered; the workstreams
inside a milestone are independent and can run in parallel.

## Context

oriel is a Tauri-like desktop framework in **Zig 0.16** (Linux first:
GTK4 + WebKitGTK 6.0). The goal is to port two Tauri apps to it:
**ghostpen** (`~/Code/ghostpen`: global hotkey → rewrite selected text with
an LLM → paste back; tray app) and **ghostreel** (`~/Code/ghostreel`: local
video search with whisper.cpp/llama.cpp, SQLite, a local media server;
Linux + Windows).

Read first: `README.md` (API and features), `LIBRARIES.md` (dependency
decisions), `IDEA.md` (motivation, architecture), then the code:

| Path | What |
|---|---|
| `build.zig` | Framework build + `addApp()` helper used by apps |
| `src/oriel.zig` | Module root, `main()`, `writeTypes()`, module checks |
| `src/core/App.zig` | Window, webview, `app://` assets, IPC, events, dev mode, lifecycle |
| `src/core/ipc.zig` | Command dispatch + TypeScript generation |
| `src/core/security.zig` | Navigation / IPC / CSP policy (unit-tested) |
| `src/modules/` | Built-in: `tray`, `updater`, `media_server`, `sql`, `fs_watch` |
| `src/plugins/` | App-specific: `global_shortcut`, `input`, `clipboard` (checks only so far) |
| `examples/react/` | React + Vite notes app (own package; tray, events, SQLite) |
| `examples/smoke/` | Checks every module + security inside a real webview |
| `cli/` | The `oriel` CLI (`init` + embedded templates, `doctor`, `zig build` wrappers) |

## Rules

1. **Framework and apps stay separate.** Framework code lives in `src/`,
   `tools/`, `build.zig`. Apps are separate packages in `examples/` that
   depend on oriel through `build.zig.zon` (`.path = "../.."`) and
   `oriel.addApp()`. Never add app targets to the framework build.
2. **Zig 0.16.0.** `~/.zvm/0.16.0/zig` (or `zig` after `cd` into the repo;
   a zvm hook switches versions per project). Zig 0.16 moved I/O to
   `std.Io`: check `~/.zvm/0.16.0/lib/std` before assuming an older API.
3. **Never test on the user's real desktop.** No clicking, typing, window
   raising or screenshots of the live session. Use
   `scripts/headless.sh <cmd>` (Xvfb + private D-Bus session);
   `SHOT=out.png` for screenshots. Drive tray menus with `gdbus` on that
   private bus (see "Testing" below).
4. **Every feature ships with a test:** a unit test (`zig build test` in the
   repo root) for pure logic, and/or a check in `examples/smoke` (headless
   `--check` or in-webview `--auto-quit`) for anything touching GTK, D-Bus
   or the webview.
5. **Keep the opt-in model.** New functionality is a built-in module or a
   plugin behind a `-D<name>` build option (see `Features` in `build.zig`);
   disabled ones must not be compiled or linked.
6. **Style:** match the surrounding code: doc comments on public API,
   comments that explain *why*, no dead code, errors surfaced (never
   silently swallowed). Small files per concern.
7. Update `README.md` (feature docs + the "Compared with Tauri" table) and
   `LIBRARIES.md` when adding a dependency.

8. **Zig 0.16 APIs:** read `docs/zig-0.16.md` before searching
   `~/.zvm/0.16.0/lib/std`; it lists the forms that compile in this repo.
9. **Review checklist (memory safety):** every change is reviewed for leaks
   (`defer`/`errdefer` on all paths; tests use `std.testing.allocator`),
   clear ownership of returned memory, structs never copied after something
   holds a pointer to them, no `.?` on values that can really be null
   (C/GObject returns checked against the GIR), GObject/GVariant refcounts,
   no reads of `undefined`, justified pointer casts, thread-safe shared state,
   and nothing touching GTK off the main thread. Tests must stay silent (no
   stderr output).

## Build and test commands

```sh
# (optional) scripts/gen-bindings.sh + --fork=deps/gobject/bindings: bindings from this machine's GIR files
zig build check                          # type-check only, ~1 s: use this while iterating
zig build test                           # framework, tools and CLI unit tests (repo root)
zig build cli                            # zig-out/bin/oriel, static

cd examples/smoke
zig build && ./zig-out/bin/oriel-smoke --check                        # module checks, no GUI
../../scripts/headless.sh ./zig-out/bin/oriel-smoke --auto-quit       # + in-webview checks

cd examples/react
zig build                                # vite build + embed + install
zig build types                          # regenerate frontend/src/oriel.ts
SHOT=/tmp/shot.png ../../scripts/headless.sh ./zig-out/bin/oriel-react-notes
```

Expected today: 98/98 unit tests; smoke `--check` all ok on the real session
except `global_shortcut` until `dev.oriel.Smoke.desktop` is installed (see
pitfalls); smoke `--auto-quit` under headless.sh 27/27 ok (X11 paths:
XGrabKey, XTest, GdkClipboard incl. the in-process `clipboard r/w` check).

### Testing a tray headlessly

Inside `scripts/headless.sh` the app owns
`org.kde.StatusNotifierItem-<pid>-1` on the private bus:

```sh
gdbus call --session --dest org.kde.StatusNotifierItem-$PID-1 --object-path /MenuBar \
  --method com.canonical.dbusmenu.GetLayout 0 -- -1 '[]'
gdbus call --session --dest org.kde.StatusNotifierItem-$PID-1 --object-path /MenuBar \
  --method com.canonical.dbusmenu.Event 2 clicked '<int32 0>' 0
```

## Known pitfalls (learned the hard way)

- **Link with LLD.** Executables/tests need `.use_llvm = true, .use_lld = true`:
  Zig's own linker rejects `.sframe` in GCC 16 `crt1.o`. `addApp` does this.
- **Generated bindings lie about nullability.** zig-gobject marks some C
  returns non-null that can be NULL (`webkit_web_view_get_uri`,
  `g_variant_lookup_value`). Declare a local `extern fn` returning `?*T`
  (see `App.zig`, `tray.zig`).
- **Check GIR ownership** (`/usr/share/gir-1.0/*.gir`, `transfer-ownership`)
  before unref'ing: `webkit_uri_scheme_response_set_http_headers` takes the
  headers (a double free crashed the app).
- **Custom response headers replace defaults:** include `Content-Type`
  in them, or `nosniff` rejects CSS.
- **WebKit user-script URL patterns can't contain ports**
  (`security.bridgePatterns` strips them; `commandAllowed` checks exact origins).
- **GTK apps are single-instance per app ID**; dev builds append `.Dev`.
- **GVariant floating refs:** `g_variant_new_*` results are floating and
  consumed by containers / `g_dbus_method_invocation_return_value`; only
  unref what you `ref_sink`ed or got from `get_child_value`.
- **GlobalShortcuts portal needs a registered app id** for host apps
  (xdg-desktop-portal ≥ 1.19): `org.freedesktop.host.portal.Registry.Register`
  before the first portal call on the connection, and `<app_id>.desktop`
  must be installed or it is refused ("App info not found"). So the smoke
  `--check` global_shortcut line fails on a real Wayland session until
  `dev.oriel.Smoke.desktop` is installed (`zig build desktop-entry` in the
  app installs it; only run it on purpose, it writes to `~/.local/share`).
- **Hyprland here uses a Lua config**: `hyprctl dispatch` needs
  `hl.dsp.*` syntax (only relevant for manual checks).

---

## Milestone 1 — Async commands (do first)

**Why:** every command runs on the GTK main thread; a slow command (LLM
request, DB scan) freezes the UI. Everything below builds on this.

**Design:**
- A command marked async runs on a worker thread pool; its reply is sent
  back on the main thread (`g_idle_add`, like `App.emitJson` does).
  WebKit supports this: `ref` the `WebKitScriptMessageReply`, return TRUE
  from the signal handler, call `return_value` later.
- Opt in per command, e.g. `pub const async_commands = .{ "summarize" };`
  in `Commands`, or a wrapper type. Pick the simplest design that keeps the
  TypeScript generation unchanged (JS already gets a Promise).
- Each async command gets its own arena, freed after the reply.
- Provide the command an `std.Io` (store `init.io` in `oriel.main`) so it
  can use `std.http.Client` etc.
- Cancellation: out of scope; document it.

**Tasks:**
1. Worker pool (`std.Thread.Pool` or a small custom one) owned by `App.run`,
   joined on shutdown.
2. Async path in `App.zig` `onMessage` + `ipc.zig` dispatch.
3. Pass `std.Io` to commands (keep `(Allocator)` / `(Allocator, Args)`
   signatures working; add an optional context parameter if needed).

**Acceptance:**
- Unit test: async dispatch runs off-thread and replies once.
- Smoke `--auto-quit` check: an async command that sleeps 500 ms while a
  sync command answers immediately in parallel (the UI thread isn't blocked).
- React example: one command uses it (e.g. a slow "export notes").

## Milestone 2 — ghostpen plugins (parallel workstreams)

Each workstream is a plugin file in `src/plugins/` with a real API (not just
a `check`), a smoke check, and README docs. Reference behavior:
`~/Code/ghostpen/src-tauri/src/pal/` and its README "Platform support".

### 2a. Global shortcuts (`plugins/global_shortcut.zig`)
- Wayland: `org.freedesktop.portal.GlobalShortcuts` via GDBus
  (CreateSession → BindShortcuts → `Activated` signal). The portal is
  available on this machine (v1, Hyprland backend).
- X11: `XGrabKey` + watch the X connection fd in the GLib main loop.
- API: `register(.{ .id, .description, .trigger = "CTRL+ALT+G" }, callback)`,
  callbacks on the main thread; emits can go to JS via events.
- Test: unit-test accelerator parsing; smoke check that a session is created
  (real session) and X11 grab works under Xvfb.

### 2b. Input injection (`plugins/input.zig`)
- wlroots/Hyprland: `zwp_virtual_keyboard_v1` (keymap from libxkbcommon is
  already built; send it via a memfd, then key events).
- X11: XTest (`XTestFakeKeyEvent`).
- GNOME/KDE: libei through the RemoteDesktop portal (can come later).
- API: `typeText(text)`, `keyCombo("ctrl+v")`.
- Test: headless X11 (XTest into an Xvfb window, read back); Wayland path:
  only a connection check (never type into the real session).

### 2c. Background clipboard (`plugins/clipboard.zig`)
- Wayland: `ext_data_control_v1` (fallback `zwlr_data_control_v1`): read and
  write text and PNG images without window focus.
- X11 / focused: `GdkClipboard`.
- API: `readText`, `writeText`, `readImage`, `writeImage` (PNG bytes).
- Test: X11 round-trip under Xvfb; Wayland protocol unit pieces.

### 2d. Notifications and dialogs (built into the core or a small module)
- `GNotification` (GIO) for notifications; `GtkFileDialog` for open/save
  (async → reply to JS via the Milestone 1 path).
- Expose as commands callable from JS (like Tauri's plugins), gated by
  capabilities.

**Milestone acceptance:** a `examples/ghostpen-lite` app (own package):
hotkey → read selection/clipboard → call a command → write clipboard →
paste. Test the pipeline headlessly on X11.

## Milestone 3 — Framework basics

- **Multiple windows:** `App.openWindow(.{ .label, .url, .width, ... })`,
  per-window security scope (capabilities gain a `windows` field), events
  targeted to a window or broadcast.
- **Window options:** min/max size, resizable, decorations, fullscreen,
  remember size/position (see next item).
- **App menu bar:** GTK4 `GMenuModel` + `GtkApplication` actions; same
  `MenuItem` shape as the tray.
- **App data paths + settings store:** XDG config/data/cache dirs for the
  app ID; a small JSON settings store (Tauri `plugin-store` equivalent).
- **Logging:** `std.log` routed to a log file in the app data dir plus
  stderr; JS `console.*` forwarded in Debug builds.
- **Dev mode Zig reload:** `zig build dev` watches `src/` and rebuilds +
  restarts the app (`zig build --watch` or a small runner); Vite keeps running.
- **Release defaults:** production `zig build` should default to
  `ReleaseSafe` (keep Debug for `dev`).

## Milestone 4 — Shipping

- **Packaging:** `zig build package` → AppImage (linuxdeploy +
  appimagetool, bundling GTK/WebKit is the hard part) and deb/rpm (nfpm);
  generate the `.desktop` file and install icons from one PNG.
- **Updater:** complete the flow in `modules/updater.zig`: fetch manifest
  (`std.http.Client`), verify Ed25519 (done), download with progress events,
  replace the binary/AppImage atomically, restart. Keys: `zig build keygen`.
- **Signing** of packages (later).

## Milestone 4.5 — `oriel` CLI (Tauri-style tooling)

**Status (2026-09-23): done**, except `npm create oriel` (below, "Later").
`cli/` (args, init + templates, doctor, wrappers), `install.sh`,
`.github/workflows/release.yml`, and a `check` step in `addApp` for
`oriel check`. The release workflow has not run yet (no tag pushed); it was
replayed locally (both static builds + SHA256SUMS). A CLI built from an
unpushed commit pins that commit by default: use `--oriel-ref` or
`--oriel-path` until it is pushed.

**Why:** starting an app today means hand-writing build.zig/.zon, finding the
fingerprint, `zig fetch`, a frontend and main.zig. Tauri has
`create-tauri-app` and `tauri dev/build`; Oriel should have the same.

**Shape:** a standalone Zig program in `cli/` (no GTK; builds fully static,
e.g. `x86_64-linux-musl`), built by the framework's build.zig as `oriel`
(`zig build cli`). Argument parsing uses the comptime CLI pattern from
LIBRARIES.md (subcommands = `union`, options = `struct` fields, generated help).

**Commands:**
- `oriel init <name> [--template react|vue|svelte|vanilla] [--id com.example.App] [--oriel-ref <tag|commit>] [--oriel-path <dir>] [--no-install]`
  - Templates are embedded in the binary (`@embedFile`), so scaffolding works
    offline: build.zig, build.zig.zon (valid `.fingerprint` computed the same way
    Zig does, or obtained by running zig), src/main.zig with sample `Commands` and
    `Events`, the frontend (Vite for react/vue/svelte, static for vanilla),
    .gitignore, a short README.
  - Adds Oriel with `zig fetch --save git+https://github.com/highercomve/Oriel#<ref>`
    (ref defaults to the version the CLI was built for; `--oriel-path` writes a
    `.path` dependency instead, for developing Oriel itself).
  - Downloads everything up front: `zig build --fetch` (all Zig deps into the
    global cache) and `npm install` (unless `--no-install` or vanilla), so the
    project then builds offline.
  - Validates the name/id (Zig identifier for the package name, reverse-DNS app
    id) and refuses to overwrite a non-empty directory.
- `oriel doctor`: checks and reports, with a non-zero exit when something
  required is missing: Zig 0.16.x on PATH (or `$ORIEL_ZIG`), pkg-config +
  `gtk4` and `webkitgtk-6.0` dev packages, Node.js/npm (for Vite templates),
  packaging tools (`nfpm`, `mksquashfs`, `desktop-file-validate`; optional),
  a StatusNotifierWatcher and the GlobalShortcuts portal (optional, informative).
  Prints the exact install command for the detected distro (pacman / apt / dnf
  / zypper) for anything missing.
- `oriel dev | build | run | package | types | check` (in an app directory):
  thin wrappers around the matching `zig build <step>`, forwarding extra args;
  they find the project root by walking up to build.zig.zon.
- `oriel --version`: CLI version and the Oriel ref it scaffolds.

**Distribution:**
- `install.sh` at the repo root: detects arch, downloads the matching release
  binary from GitHub Releases, verifies its sha256, installs to `~/.local/bin`
  (or `$ORIEL_INSTALL_DIR`); never uses sudo.
- A GitHub Actions workflow that, on a `v*` tag, builds the static CLI for
  x86_64 and aarch64 Linux, runs `zig build test` and the headless smoke checks
  where possible, and attaches the binaries + `SHA256SUMS` to the release.
- Later: `npm create oriel@latest` wrapping the same binary.

**Acceptance:**
- Unit tests: argument parsing, name/id validation, template rendering,
  fingerprint generation.
- Integration (headless, temp dirs, `--oriel-path` pointing at this checkout so
  no network is needed for Oriel itself): `oriel init` with each template, then
  `oriel build` succeeds; the vanilla and react apps start under
  `scripts/headless.sh` (SHOT screenshot shows the page calling a Zig command).
- `oriel doctor` passes on this machine and reports missing tools correctly when
  PATH is restricted.
- `install.sh` tested against a local file:// or temp HTTP server, not the
  real release.

## Milestone 5 — ghostreel enablers

- ✅ **Media server:** files from a root directory with HTTP range requests
  (`modules/media_server.zig`, `modules/media/`), `openat2(RESOLVE_BENEATH)`,
  plus `app://app/media/` for fetch. `<video src="app://...">` can't work:
  WebKitGTK's GStreamer player only accepts http(s)/blob/data/file.
- **Windows shell** (large): Win32 window + WebView2 (COM vtables from
  `WebView2.h`), tray (`Shell_NotifyIconW`), `RegisterHotKey`, `SendInput`,
  clipboard. Keep the shell interface in `App.zig` platform-neutral first
  (split Linux code into `src/platform/linux/`), then add
  `src/platform/windows/`.
- **Native deps:** whisper.cpp / llama.cpp / sqlite-vec built from
  `build.zig` (CPU first; CUDA/Vulkan as options).

## Later

- macOS shell (AppKit + WKWebView via zig-objc).
- Tauri's isolation pattern.
- CI: run `zig build test` and the headless smoke checks on every push.
