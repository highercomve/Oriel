# ziguri — a Tauri-like framework in Zig

Status: **scaffolded** (2026-09-23): core + all modules build and pass smoke checks on Linux. See README.md.
See [LIBRARIES.md](./LIBRARIES.md) for the dependency investigation.

## Motivation

- Existing Tauri apps: **ghostpen** (AI text editing anywhere on the desktop) and
  **ghostreel** (local video search + AI-assisted editing).
- Rust build footprint is painful: ghostreel's `target/` reached **157 GB**
  (69 GB was stale incremental data). Mitigated for now with `~/.cargo/config.toml`
  (`debug = "line-tables-only"`, no debuginfo for deps) + `cargo sweep`, bringing
  it down to ~3 GB — but the itch remains.
- Zig 0.16: trivial C interop, `comptime` reflection, small binaries, tiny build cache.

## Architecture inspiration: libghostty

Ghostty keeps all real logic in a Zig core exposed via a **C ABI**, with thin
**native shells per OS** (Swift/AppKit on macOS, GTK on Linux). ziguri would follow
the same split:

- **Core (Zig, C ABI):** IPC/command dispatch, asset serving, security policy,
  app state, plugin APIs.
- **Shells (per platform):** window, event loop, webview, tray, menus, global
  hotkeys, dialogs, clipboard, input injection.

## What Tauri is, and the Zig equivalent

| Layer | Tauri (Rust) | ziguri |
|---|---|---|
| Windowing / event loop | `tao` | GTK4 / Cocoa / Win32 |
| Webview | `wry` | WebKitGTK 6.0 / WKWebView / WebView2 (COM) |
| JS ↔ native IPC | `invoke()` + serde | JSON over webview message handler, `comptime`-generated dispatch |
| Asset serving | `tauri://` custom scheme | custom URI scheme + `@embedFile` |
| Plugins | tauri-plugin-* | hand-written per platform |
| CLI / bundling / signing | tauri-cli | `build.zig` steps + external tools |

## Killer feature idea

Declare commands as a plain Zig struct; `comptime` reflection generates the JSON
dispatch **and** TypeScript type declarations. No macros, no serde.

```zig
pub const commands = struct {
    pub fn greet(name: []const u8) []const u8 { ... }
};
```

## Difficulty estimate

1. **Linux MVP** (1–2 weeks): GTK4 + WebKitGTK 6.0 window, custom scheme with
   embedded assets, bidirectional IPC. Local machine already has `webkitgtk-6.0`
   2.52.6 and `gtk4` 4.22.5.
2. **Cross-platform desktop** (2–4 months): macOS via objc runtime (see
   `zig-objc`), Windows WebView2 via hand-declared COM vtables. Cross-compiling
   gets harder once system SDKs (WebKitGTK, macOS SDK) must be available.
3. **Tauri parity** (team-years): tray, menus, dialogs, updater, installers
   (AppImage/deb/dmg/msi), signing, mobile.

## Risks

- **Zig 0.16 churn:** new `std.Io` interface; ecosystem breaks each release.
  (0.16.0 is installed via zvm. Set `minimum_zig_version = "0.16.0"` in
  `build.zig.zon` and the zvm cd hook switches this shell to 0.16.0 inside the
  project, leaving the global default alone.)
- **Main-thread affinity:** webviews live on the UI thread; async commands must
  marshal results back (`g_idle_add` / `dispatch_async` / `PostMessage`). Key
  design problem: integrating this cleanly with `std.Io`.
- **Security model:** per-window command permissions and a content security
  policy (CSP) must be designed in early, not bolted on.
- **Linux desktop fragmentation:** X11 vs Wayland; global hotkeys on Wayland go
  through the XDG GlobalShortcuts portal; tray via StatusNotifierItem/D-Bus.

## Prior art (checked 2026-09-23)

- **Native SDK** — https://github.com/vercel-labs/native (formerly
  `zero-native`). Requires Zig 0.16. ~7.7k stars, Apache-2.0, "Labs experiment".
  Pivoted to its own native renderer (`.native` markup + TS/Zig); webview mode
  still exists (`.frontend` in `app.zon`, React/Vue/Svelte/Next examples, but
  the React example only targets macOS and Linux). macOS is primary.
  **Gaps relevant to our apps:** no tray on Linux, no global hotkeys, no input
  injection, no single-instance, weaker Windows webview story.
- **Verve** — solo pure-Zig Tauri/Wails alternative, young.
  https://dev.to/sirhco/why-i-built-verve-crafting-a-pure-zig-full-stack-alternative-to-tauri-and-wails-4e3c
- **Electrobun 2.0** — TS-first, but the native side can be Zig. https://electrobun.dev/
- **Bindings:** `happystraw/zig-webview`, `thechampagne/webview-zig`
  (webview/webview), `webui-dev/zig-webui`.

## Could it host our apps?

- **ghostpen** needs: tray, global hotkey, input injection (enigo), clipboard
  incl. images, single-instance, HTTP to OpenAI-compatible endpoints. Tray,
  hotkey, input injection and single-instance on Linux are exactly what Native
  SDK lacks — ziguri's differentiator.
- **ghostreel** needs: Windows + Linux, dialogs, updater, local HTTP server with
  video range requests, and a large Rust backend (whisper.cpp, llama.cpp,
  SQLite + sqlite-vec — all C, easy from Zig; reqwest/tokio/axum/notify/blake3/
  toml/quick-xml — need Zig replacements). Porting it is a multi-month effort.

## Suggested first step (when resumed)

A **ghostpen-core spike on Linux**: GTK4 + WebKitGTK 6.0 window, tray icon,
global hotkey (portal on Wayland), clipboard read, text replace/paste, with the
existing React frontend. Keep the platform code behind a small interface
(`Window`, `WebView`, `dispatchToMain`, `registerScheme`, `Tray`, `Hotkey`) so
macOS/Windows shells can be added libghostty-style later.
