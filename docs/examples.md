# Apps and examples

[Back to Oriel](../README.md) · [Documentation](README.md)

## Built with Oriel

**[GhostPen](https://github.com/highercomve/GhostPen)** ([website](https://highercomve.github.io/GhostPen/)):
AI text editing anywhere on the desktop. Select text in any app, press a
hotkey, pick an action; the result is pasted back. It runs AI models itself
(llama.cpp compiled in, on the GPU with Vulkan or CUDA on Linux and Metal
on macOS), captions what the computer plays and
takes dictation (whisper.cpp), on Linux, Windows and macOS. Ported from
Tauri; its README [compares the two](https://github.com/highercomve/GhostPen#compared-with-the-rust-tauri-ghostpen)
(build time, binary size, dependencies, memory).

![GhostPen: the Playground and the menu, running a built-in model](../assets/screenshots/ghostpen.png)

## Examples

Each example is its own Zig package in [`examples/`](../examples), built on Oriel
like any app would be.

### Showcase

**[examples/showcase](../examples/showcase)**: every Oriel feature in one app,
from one codebase, for Linux, Windows, macOS, Android and iOS. Live dictation
(`oriel.dictation`: whisper on the CPU or GPU, or the platform's recognizer),
chat with a local LLM (`oriel.chat`: models, the chat template, streamed
tokens, a reused KV cache), notes in SQLite with deep links
(`oriel-showcase://note/…`), file pickers, the clipboard, notifications,
windows, events and the store; per platform, "dictate anywhere" into other
apps (a system-wide hotkey, the tray and the window menu on the desktop; a
Quick Settings tile, a keyboard and in-app shortcuts on Android) and
background audio on iOS.

<p>
  <img src="../assets/screenshots/showcase-dictate.png" alt="The Dictate tab on a Pixel: whisper small on Vulkan, drafted by base on the CPU" width="19%">
  <img src="../assets/screenshots/showcase-chat.png" alt="The Chat tab on a Pixel: Llama 3.2 1B on Vulkan, streamed tokens" width="19%">
  <img src="../assets/screenshots/showcase-notes.png" alt="The Notes tab: notes in SQLite, added by a deep link" width="19%">
  <img src="../assets/screenshots/showcase-system.png" alt="The System tab: dictate anywhere, clipboard, notifications and shortcuts" width="19%">
  <img src="../assets/screenshots/showcase-app.png" alt="The App tab: windows, the IPC echo and events from a worker" width="19%">
</p>

How to build and package it for each platform, with the GPU options:
[examples/showcase/README.md](../examples/showcase/README.md).

### Breakout

**[examples/breakout](../examples/breakout)**: a Breakout game that runs the same
page in the WebView and in the [native renderer](renderers.md#native-renderer-experimental).
The board is a `<canvas>`; the score, overlays and settings are HTML and CSS.
Drag on a phone, mouse or arrow keys on the desktop. Its physics and drawing
run either in JavaScript or in Zig (`BREAKOUT_MODE=zig`, through
`oriel.canvas`), so the same game compares three ways. At 500 balls:

| | Native, Zig | Native, JavaScript | WebView |
|---|---|---|---|
| Windows 11 laptop, 144 Hz | 142–144 fps | 59–75 fps | 103–116 fps |
| Android phone, 120 Hz | 120 fps (0.35 ms of Zig a frame) | 63 fps | 120 fps |

<p>
  <img src="../assets/screenshots/breakout-desktop.png" alt="Breakout in the native renderer on Linux, Zig mode: bricks, balls and the stats overlay" width="62%">
  <img src="../assets/screenshots/breakout-phone.png" alt="Breakout in the native renderer on an Android phone, Zig mode, at 120 fps" width="24%">
</p>

### Smoke test

**[examples/smoke](../examples/smoke)**: every module gets a pass/fail check
inside a real webview — one run tells you Oriel works end to end on your
machine, not just that it compiles. It runs in CI on every platform with each
check listed, so a red one names the module.

![Smoke test: every module and security check passing inside the webview](../assets/screenshots/smoke.png)

### Render bench

The [render bench](../examples/render-bench) measures row construction and
updates, animation, canvas drawing, startup, and memory in both renderers.
See its [build instructions](../examples/render-bench/README.md) and the
[performance guide](native-renderer-performance.md) for recorded comparisons.

![Render bench in the WebView: row timing results and animated boxes](../assets/screenshots/render-bench.png)

This screenshot shows the WebView UI during a private-display run; use the
performance guide for benchmark figures and measurement conditions.

### Canvas demo

The [canvas demo](../examples/canvas-demo) draws shapes, paths, text,
transforms, and animated balls with the 2D canvas API.

![Canvas demo in the WebView: shapes, text, a curved path, and animated balls](../assets/screenshots/canvas-demo.png)
