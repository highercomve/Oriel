<!-- Generated from site/content/docs/*.smd by tools/docs/gen-md.mjs (index: site/docs-index.json). -->

# Oriel documentation

The same pages as the website, https://oriel.foreachdeveloper.com/docs/.

## Start

- [Getting started](getting-started.md): Install the CLI, create an app and run it with hot reload.
- [Tutorial: a notes app](tutorial.md): Build a complete Oriel app step by step: a command, an event, SQLite storage and a tray icon.
- [Wrap a web app](wrap.md): Turn a website into a desktop app with oriel wrap: an editable Oriel project with a tray icon and AppImage packaging.
- [Examples](examples.md): The example apps in the repository and the apps built with Oriel: what each one shows, how to run it, and what it looks like.

## Core

- [Concepts](concepts.md): How an Oriel app is put together: one native process, its windows and web views, the bridge between the page and Zig, modules, the build and the platform layer.
- [Architecture](architecture.md): How Oriel is layered so one app, its modules and its Zig code run under three renderers that share everything below their front end.
- [Commands and events](commands.md): The typed IPC between the page and Zig: commands the page invokes, events Zig emits, their JSON mapping, threads, errors, limits and the generated TypeScript.
- [Windows](windows.md): The main window and any others: every WindowOptions field, labels, placement and overlays, the page's oriel.window API, and how each platform shows them.
- [Security](security.md): What a page may load and call: the navigation policy, IPC tokens and capabilities, the Content-Security-Policy, response headers, external URLs and the isolation pattern.
- [Development](development.md): The dev loop: oriel dev with the frontend's dev server and hot reload, Zig rebuilds and restarts, devtools, logs and type checking.
- [CLI](cli.md): Every oriel command and flag: creating and wrapping apps, the build wrappers, phones, tools, permissions, deep links, signing and updates.

## App and system

- [Lifecycle](lifecycle.md): Background and foreground, memory pressure, sleep and wake, and the end of the app: one set of events on every platform, for Zig and for the page.
- [Deep links](deep-links.md): Open the app from a URL of its own scheme (myapp://...), cold or running, and receive the link in Zig and in the page.
- [Permissions](permissions.md): Declare the OS permissions an app needs once in build.zig, have every package carry them, and query or request them at runtime from Zig or the page.
- [Tray](tray.md): An icon in the system tray or the macOS menu bar, with a menu of items, check items and submenus, driven from Zig.
- [Menu](menu.md): The native menu bar: items, check items, submenus and keyboard shortcuts, in the window on Linux and Windows and at the top of the screen on macOS.
- [Dialogs](dialogs.md): The platform's own open, save and folder pickers, called from Zig, with folders the app can keep writing to across restarts.
- [Notifications](notifications.md): System notifications from Zig, with buttons, and the clicks reported back to Zig and the page.
- [Files](files.md): How the user's files reach an Oriel app and its page: dropped, picked, shared from other apps, or kept in a folder the user chose, and what crosses the bridge for each.
- [Settings store](store.md): A thread-safe JSON key-value file for the app's settings, written atomically, in the app's config directory on every platform.
- [App directories](paths.md): The app's own directories on every platform, from one call each: oriel.paths.appData, appCache, appConfig and appExternal.
- [Logging](logging.md): std.log to stderr (logcat on Android) and to a per-app log file on every platform, plus where the page's console output goes.
- [SQL](sql.md): SQLite compiled into the app, with sqlite-vec for nearest-neighbour vector search, on every platform.
- [File watching](fs-watch.md): Know when files are created, changed or deleted in a directory: inotify on Linux and Android, ReadDirectoryChangesW on Windows, FSEvents on macOS.
- [Clipboard](clipboard.md): Read and write the system clipboard from Zig: text and PNG images, on every platform, from any thread.
- [Global shortcuts](global-shortcuts.md): System-wide hotkeys on Linux, Windows and macOS, and in-app keyboard shortcuts on Android, registered from Zig.
- [Input](input.md): Send keystrokes to the focused app from Zig: key combinations, typed text, copy and paste, on Linux, Windows and macOS.
- [Network](network.md): Local network discovery: announce and find services with mDNS/DNS-SD through the platform's own responder, and hold the multicast lock.
- [Bluetooth](bluetooth.md): Bluetooth LE advertising: a beacon nearby devices can see, from Zig or the page, with what each platform's stack can send.
- [Share](share.md): Send text, links and files to other apps through the system share sheet, and receive what other apps share with yours.
- [Media server](media-server.md): Stream large local video and audio to the page with HTTP range requests, from a loopback server or the app's own scheme, without loading the files into memory.
- [Video](video.md): A native video player over the window, for what the WebView's <video> can't play: camcorder MPEG-TS, WMV, ProRes, or a GPU where the WebView's video is slow.
- [Camera](camera.md): Photos from the camera or the photo library, scaled and encoded, from Zig or the page; and image inputs that open the camera on Android.

## Local AI

- [Local AI](local-ai.md): On-device inference with llama.cpp, whisper.cpp and Kokoro on one shared ggml build, on the CPU or the GPU (CUDA, Vulkan, Metal, OpenCL, Hexagon), on every platform.
- [Chat](chat.md): Chat and completion with a local LLM through oriel.chat: a model catalog with downloads, the model's own chat template, streaming tokens, JSON-schema output and KV-cache reuse, on the CPU or the GPU.
- [Dictation](dictation.md): Voice to text with oriel.dictation: live dictation from the microphone or system audio and transcription of recordings, on whisper.cpp or the platform's own recognizer.
- [Text to speech](tts.md): Read text aloud offline with oriel.tts: Kokoro-82M voices for eight languages, verified downloads, Markdown read as prose, and streaming playback on the CPU or the GPU.
- [Speakers](speakers.md): Who spoke when, offline, with oriel.speakers: speaker embeddings from voice-detect.cpp, clustering into speaker turns, and matching voices the app knows, on the CPU or the GPU.
- [System AI](system-ai.md): The phone's own language model through oriel.system_ai: Gemini Nano on Android, Apple Foundation Models on iOS 26+, with nothing for the app to download or ship.

## Native code

- [Platform hooks](platform-hooks.md): Your code inside the platform's own app, window and web view events: Kotlin on Android, Objective-C or Swift on iOS and macOS, Zig on the desktop.
- [App extensions](extensions.md): Your own Kotlin, Objective-C, Swift or Zig code, declared by name in build.zig and called from Zig with one API on every platform.

## Platforms

- [Desktop: Linux, Windows, macOS](desktop.md): What an Oriel app runs on and needs on Linux (GTK 4 and WebKitGTK), Windows (Win32 and WebView2) and macOS (AppKit and WKWebView), with each platform's options and limits.
- [Android](android.md): Build, run and ship an Oriel app on Android phones, tablets, Chromebooks and Android desktop mode: the toolchain, the oriel android CLI, the Gradle project and every .android option.
- [iOS](ios.md): Build an Oriel app for iPhone and iPad from a Mac or from Linux, run it on the simulator or a device, and package it: the SDK, the oriel ios CLI, the bundle and every .ios option.

## Ship

- [Building](building.md): oriel.addApp and its AppOptions, the build steps, the Oriel dependency's -D options, the generated oriel_app module, and cross-compiling.
- [Packaging](packaging.md): Installers for every platform from one build.zig: deb, rpm and AppImage, setup.exe and MSIX, .app and .dmg, APK and AAB, and the iOS .ipa.
- [Signing](signing.md): Code signing for every platform: Authenticode and MSIX on Windows, Developer ID, notarization and self-signed certificates on macOS, keystores on Android, and the Ed25519 keys that sign your updates.
- [Updater](updater.md): In-app updates for desktop apps: an Ed25519-signed manifest, a verified download, an atomic swap of the executable, AppImage or .app bundle, and a restart.

## Native UI

- [Native renderer](native-renderer.md): Your HTML, CSS and JavaScript drawn with the platform's own views instead of a web view: one process, a fraction of the memory, the same web files.
- [Native UI reference](native-ui-reference.md): Every HTML element, CSS selector, property, unit, event and browser API the native renderer supports, how each platform draws it, and what it doesn't support.
- [Drag and drop](drag-and-drop.md): Files, text and links dragged from other apps into the page, with the browser's DragEvent, DataTransfer and File API, in both renderers.

## Reference

- [Modules](modules.md): What an Oriel module is, how build flags turn modules on, and every module and plugin with its flag, platforms and page.
- [How Oriel compares](comparison.md): Oriel next to Electron and Tauri, and next to Vercel Labs' native (formerly zero-native), measured against what GhostPen needs.

## For contributors

- [internal/](internal/): contributing, testing and porting notes
- [design/](design/): design records of shipped and planned features
