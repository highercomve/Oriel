# Oriel — a Tauri-like framework in Zig

Status: **working framework** (release-0.9.1 line). Oriel builds desktop and mobile
applications with a WebView shell or its experimental native renderer. The core,
platform shells, modules, plugins, CLI, packaging paths, and native renderer are
implemented in this repository; see `README.md` for the current verification matrix.
`LIBRARIES.md` records the dependency choices and platform constraints.

## Motivation

Oriel started from two application needs:

- **ghostpen** — AI text editing anywhere on the desktop: tray, global shortcuts,
  input injection, clipboard, single-instance behavior, and network calls.
- **ghostreel** — local video search and AI-assisted editing: media streaming,
  dialogs, SQLite/vector search, whisper.cpp, llama.cpp, and packaging.

Rust build size and iteration cost were the original motivation. Zig 0.16 gives Oriel
small binaries, direct C interop, `comptime` reflection, and a single build system
for desktop and mobile targets.

## Two rendering modes

Oriel has one page/runtime contract with two implementations:

- **WebView mode (default):** the platform WebView renders the frontend. Linux uses
  WebKitGTK, macOS uses WKWebView, Windows uses WebView2, and Android uses Android
  WebView. This is the compatibility path for normal web applications.
- **Native UI (`-Dnative_ui`):** QuickJS executes the page JavaScript, Oriel's native
  DOM stores the document, Yoga performs flexbox layout, and platform backends draw
  the result with GTK, Direct2D/DirectWrite, AppKit, UIKit, or Android views. There
  is no browser process. `-Dnative_dom=false` keeps the native renderer but uses the
  LinkeDOM compatibility path instead of Oriel's native DOM.

The native renderer is more than a prototype: it includes CSS/layout, text and SVG
rendering, canvas, pointer and keyboard events, fields and selection, native buttons,
checkboxes and radios, forced-colors handling, drag and drop, and platform-specific
window backends. It remains experimental because browser compatibility is narrower
than WebView mode and the API surface is still growing. See `docs/native-renderer.md`,
`docs/native-dom.md`, and `docs/native-controls-a11y-design.md`.

The important product idea is **web layout with native platform rendering**: existing
HTML/CSS/JS can be reused, while apps that need a browser can stay on the WebView
path and apps that need lower overhead can opt into native UI.

## Architecture

The split is inspired by libghostty:

- **Core (Zig):** command and event dispatch, asset serving, security policy,
  application state, window management, generated TypeScript bindings, and module
  interfaces.
- **Page runtimes:** WebView bridge in compatibility mode; QuickJS, native DOM, and
  Yoga in native UI mode.
- **Native shells (per platform):** window/event loop, renderer, WebView where
  applicable, tray/menu, dialogs, notifications, clipboard, global shortcuts, input,
  and filesystem integration.
- **Modules and plugins:** shared APIs with platform backends for tray, menu, dialog,
  store, notification, updater, media server, SQL, vector search, AI inference,
  dictation/audio capture, filesystem watch, global shortcuts, input, and clipboard.

Commands are declared as Zig functions. `comptime` reflection generates JSON dispatch
and TypeScript declarations without a proc-macro or serde layer:

```zig
pub const commands = struct {
    pub fn greet(name: []const u8) []const u8 { ... }
};
```

## What Tauri is, and the Zig equivalent

| Layer | Tauri | Oriel |
|---|---|---|
| Window/event loop | `tao` | GTK4 / AppKit / UIKit / Win32 / Android |
| Web UI | `wry` | WebKitGTK / WKWebView / WebView2 / Android WebView, or native UI |
| JS ↔ native IPC | `invoke` + serde | JSON bridge + `comptime`-generated dispatch |
| Native rendering | platform WebView | optional QuickJS + native DOM + Yoga renderer |
| Asset serving | `tauri://` | custom `app://` scheme + embedded assets |
| Plugins | `tauri-plugin-*` | built-in modules and hand-written platform plugins |
| CLI/bundling | `tauri-cli` | `oriel` CLI + `build.zig` + platform tools |

## Current strengths

- One API across Linux, Windows, macOS, Android, and iOS targets.
- WebView compatibility mode plus a native renderer for controlled deployments and
  lower process/memory overhead.
- Typed command/event bindings, per-origin and per-window capabilities, CSP and
  navigation policy, embedded assets, and a media scheme with range support.
- Desktop integrations that motivated the project: Wayland/X11 shortcuts and input,
  background clipboard, tray/menu, dialogs, notifications, single instance, and
  updater support.
- Optional C/C++ modules for SQLite, sqlite-vec, llama.cpp, and whisper.cpp without
  making those dependencies mandatory for every app.

## Risks and boundaries

- Native UI intentionally does not promise full browser compatibility. Unsupported
  CSS, DOM, accessibility, and JavaScript behavior belongs on the WebView path until
  implemented and tested.
- Native renderers must preserve UI-thread affinity while commands and model work run
  asynchronously; results are marshalled back to the platform main loop.
- Linux still spans GTK/Wayland/X11 and portal implementations. macOS, Windows, and
  mobile require their own SDKs and runtime verification.
- Zig 0.16 and several ecosystem packages are moving targets; dependency versions
  should remain pinned and tested in CI.
- Security policy is part of the framework contract: capabilities, asset origins,
  navigation, and IPC validation must evolve together with new modules.

## Prior art

- **Vercel Native** — a Zig native renderer and web frontend experiment. Oriel differs
  by keeping a complete WebView compatibility path and focusing on desktop integrations
  such as tray, global shortcuts, input injection, clipboard, and single instance.
- **Verve**, **Ziew**, **Electrobun**, and Zig WebView bindings — useful references for
  pure-Zig or system-WebView approaches, but none covers Oriel's combined renderer,
  module, and cross-platform scope.
- **libghostty/Ghostty** — the model for a Zig core with thin native platform shells.

## Next work

Priorities are no longer a first Linux WebView spike; that path is in place. The next
steps are to expand native-DOM and native-control coverage, accessibility semantics,
renderer conformance tests, and performance/regression tests across all backends,
while keeping WebView mode stable. In parallel, continue runtime verification and
packaging on Windows, macOS, Android, and iOS, and keep the optional AI/media modules
isolated from the minimal core.
