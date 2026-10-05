# Oriel on Android: port plan and tracker

Started 2026-09-29 on this branch. Source plan: the "Oriel on Android"
investigation (2026-09-28). This file is the working checklist; tick items
as they land and add notes under each milestone.

Goal: run Oriel apps natively on Android, desktop form factors first
(Googlebooks, Android desktop windowing, Chromebooks). Phones come along
with the same SDK and NDK. GhostPen is the first real app.

## Decisions

| Area | Decision |
|---|---|
| Shell | Thin Kotlin `OrielActivity` hosting `android.webkit.WebView`, talking to a Zig `liboriel.so` over JNI (Tauri v2 shape). NativeActivity rejected: no WebView without JNI, poor text input. |
| Windows | One Activity per window: resizable, multi-instance, freeform desktop mode. |
| ABIs | `arm64-v8a` (Snapdragon X Elite Googlebooks, phones, ARM Chromebooks; only ABI with Hexagon) and `x86_64` (Intel Panther Lake Googlebooks, emulator). One APK/AAB carries both. |
| Local models | ggml Vulkan, OpenCL and Hexagon backends (already vendored), each a separate `.so`, probed with a self-test; CPU always linked in as fallback. |
| Packaging | Generated Gradle project driven by `oriel android init / dev / build`. APK for sideloading, AAB for Play. |
| minSdk | ≥ 29 (avoids emulated TLS; MediaProjection audio capture). |
| Chromebooks today | Linux build in Crostini stays the fallback until the Android app replaces it. |

## Architecture

```
Web      app UI over app:// (dev server via adb reverse)
Kotlin   OrielActivity + WebView: app:// via shouldInterceptRequest,
         IPC token injected at document start, JS→Zig via WebMessageListener
JNI      Java_…_NativeLib_* exports from Zig; worker threads AttachCurrentThread
Zig      liboriel.so = Oriel core + src/platform/android/
         (30-declaration contract in platform.zig), ggml CPU linked in;
         libggml-vulkan.so / libggml-opencl.so / libggml-hexagon.so (+HTP v73–v81)
```

Platform contract mapping:

| Contract area | On Android |
|---|---|
| Event loop | Kotlin main thread drives the Activity; Zig processes queued lifecycle, IPC and input events. `quit()` posts a quit marker and calls `finish()`. |
| Dispatch to UI thread | `Handler(Looper.getMainLooper()).post` |
| createWindow | New Activity with `FLAG_ACTIVITY_NEW_TASK \| MULTIPLE_TASK` (or `singleInstancePerTask`, API 31+). Cross-window `emitTo` is in-process. |
| Size & placement | `ActivityOptions.setLaunchBounds`, manifest `<layout>` min size, resize from WindowMetrics. |
| Drag, click-through, always-on-top | No-ops; caption bar handles dragging. |
| IPC bridge | Mirrors `linux/bridge.zig`; token and isolation checks (`ipc.zig`) must behave identically. |
| Dialogs | AlertDialog + Storage Access Framework picker. Folders: `ACTION_OPEN_DOCUMENT_TREE` with a persisted read/write grant (`oriel.dialog.openFolder`, `saveToFolder` through `DocumentsContract.createDocument`). |
| Clipboard, paths | ClipboardManager; `getFilesDir` / `getExternalFilesDir` over JNI. |
| Single instance | Launcher Activity `singleTask`, `onNewIntent` → `on_second_instance`. |
| Permissions | New `permissions/android.zig` → runtime permissions (mic, camera, notifications). |
| Global shortcuts | In-app only (Android has no system-wide hotkeys): `global_shortcut.register` works while one of the app's windows has focus, with a hardware keyboard. `OrielActivity.dispatchKeyEvent` matches the key before the WebView, and `onProvideKeyboardShortcuts` lists each shortcut's description in the system's Meta+/ helper. |
| Menus, tray | Unavailable: documented no-ops or compile errors. |

## Step zero: the silent-GTK trap

Zig treats Android as Linux (`os.tag == .linux`, `abi == .android`). Every
`switch (builtin.os.tag)` backend selector would silently pick GTK /
PulseAudio / X11. Fix before any Android code compiles: add `is_android` to
`src/oriel.zig`, give every selector an explicit Android branch (real
backend or `@compileError`), and use `is_desktop_linux` in `build.zig` and
`core/log.zig`.

Selectors (paths under `src/`):

- `platform/platform.zig`
- `core/permissions.zig`
- `plugins/global_shortcut.zig`, `plugins/clipboard.zig`, `plugins/input.zig`
- `updater_core.zig`
- `modules/notification.zig`, `store.zig`, `menu.zig`, `tray.zig`,
  `media_scheme.zig`, `fs_watch.zig`, `deep_link.zig`, `dialog.zig`,
  `media/open.zig`, `audio_capture.zig`
- Also: `core/log.zig` (glib), `build.zig` GTK/Wayland/Pulse/X11 gating,
  and the musl ABI reset in `build.zig` that must not apply to Android.

## Running it on a device

Needs a JDK 17, the Android SDK (platform-tools, Gradle 8.9+ or Android
Studio) and the NDK (`$ANDROID_NDK_HOME`, or `$ANDROID_HOME/ndk/<version>`).

```sh
cd examples/showcase               # or your app
oriel android init                 # android/ already exists in the examples
oriel android dev --abi x86_64     # emulator; arm64 for a Chromebook or phone
adb logcat -s Oriel chromium       # logs
```

`oriel android dev/build` forward Zig `-D` options, for example
`oriel android dev --abi arm64 -Dnative_ui` or
`oriel android build --abi arm64 --apk -Dnative_ui -Doptimize=ReleaseFast`.
The native UI APK uses the same app sources, rendered by QuickJS and Oriel's
native view layer. It remains experimental and implements a subset of browser
HTML and CSS; see [Native renderer](native-renderer.md).
Explicit options such as `-Doptimize=ReleaseFast` replace the defaults.

`oriel android dev` builds `zig-out/jniLibs/<abi>/liboriel.so`, installs a
debug APK and starts it. `oriel android build` makes the release APK and AAB
for both ABIs (signed with `$ORIEL_ANDROID_KEYSTORE`,
`$ORIEL_ANDROID_KEYSTORE_PASSWORD`, `$ORIEL_ANDROID_KEY_ALIAS`,
`$ORIEL_ANDROID_KEY_PASSWORD`). Without the CLI: `zig build
-Dtarget=aarch64-linux-android` then `gradle installDebug` in `android/`.

Release builds are small: Zig strips the library (Debug builds keep their
symbols) and R8 shrinks the Kotlin side; a hello world's APK is 0.8 MB.
R8 can't see what native code calls by name over JNI, so
`android/app/proguard-rules.pro` keeps Oriel's runtime (`dev.oriel.**`). If
your Zig code calls classes of your own through JNI, add a `-keep` rule for
them there, or put the rules in a file and name it in
`.android = .{ .proguard_rules = b.path("src/android/rules.pro") }`: every
build writes them into `proguard-rules.pro` between `# oriel:proguard`
markers. Your own Kotlin or Java files go in
`.android = .{ .sources = &.{b.path("src/android/Helper.kt")} }`:
every build copies each to `app/src/main/java/<its package as a path>/`
(and removes the ones you drop from the list). Projects generated before
this change keep their old `build.gradle.kts`; `oriel android init --force`
regenerates it.

The manifest (`android/app/src/main/AndroidManifest.xml`) is yours, except
for the parts between `<!-- oriel:NAME begin -->` and `<!-- oriel:NAME end -->`
comments: `permissions`, `features`, `queries`, `main-activity` (its intent
filters: URL schemes) and `components` (the tile, the keyboard, the audio
service). Every build rewrites those from build.zig
(`build/android_manifest.zig`), so a permission declared after the first
build reaches the APK. An entry you declare yourself outside them (the same
element and `android:name`) isn't generated a second time. Permissions and
features no `.permissions` kind covers go in `.android = .{ .permissions = &.{.{
.name = "android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE" }}, .features =
&.{...} }`: the build merges them into those regions, one entry per name
(the kind's entry stays, but an extra without `max_sdk` lifts its
`maxSdkVersion`). A manifest
written before the markers existed gets them on its next build, with
Oriel's old entries moved inside.

Checks that need no NDK: `zig build check -Dtarget=aarch64-linux-android`,
`scripts/android/check.sh` (apps with llama/whisper) and
`scripts/android/check-runtime.sh` (compiles the Kotlin runtime and checks
the JNI contract between Zig and Kotlin).

Link check without the NDK (where dl.google.com is unreachable):
`scripts/android/bionic-sysroot.py <dir>` builds a stand-in NDK from AOSP's
bionic sources: headers, versioned stub libc/libm/libdl, liblog,
libandroid and libaaudio stubs, crtbegin_so/crtend_so. `ANDROID_NDK_HOME=<dir>
zig build -Dtarget=...` then links for real, and `readelf --dyn-syms` shows
any import the device wouldn't resolve. Never ship what it builds.

GPU/NPU: `-Dggml_vulkan` (any GPU), `-Dggml_opencl` (Adreno),
`-Dggml_hexagon_prebuilt=<dir>` (Snapdragon NPU: `libggml-hexagon.so` and
`libggml-htp-v*.so` from llama.cpp's Snapdragon build at the vendored commit,
made in `ghcr.io/snapdragon-toolchain/arm64-android`). `ORIEL_GGML_CPU=1`
forces the CPU; `ORIEL_GGML_BLOCKLIST=Mali-G57,...` skips devices.

## Status

(`examples/android-hello`, below, is now `examples/showcase`: the same app
with every Oriel feature, for all five platforms.)

Runs on Android. On 2026-09-30 (second session) `examples/android-hello`
was built with the real NDK, packaged with Gradle and the Android Gradle
Plugin, and passed every prototype check on an Android 15 emulator
(below). GhostPen Lite builds, installs and starts there too. Still
unverified: GPU/NPU backends and desktop windowing, which need real
hardware.

Real toolchain, 2026-09-30 (second session): NDK r28c (28.2.13676358),
platforms;android-35, build-tools 35.0.0, AGP 8.7.3 with Gradle 8.14.3,
JDK 21, Zig 0.16.0.

- `liboriel.so` builds for x86_64 and arm64-v8a against the real NDK:
  16 KiB-aligned LOAD segments, `.note.android.ident`, TLS 0x82d bytes,
  NEEDED only liblog, libandroid, libc, libdl (plus libaaudio and libm for
  GhostPen Lite). Every libc import is versioned; the unversioned ones are
  `ALooper_*`, `__android_log_write` and (GhostPen) `AAudio*`, because the
  NDK's liblog/libandroid/libaaudio stubs carry no version nodes. All
  exist by API 28.
- `gradle assembleDebug` works as generated (no template change needed):
  both ABIs stored uncompressed, `zipalign -c -P 16` passes, no Kotlin
  warnings. `zig build android-project -Dandroid_force=true` rewrites
  nothing (the committed projects match the template), and
  `scripts/android/check-runtime.sh` passes.
- GhostPen Lite with `-Dggml_vulkan` (x86_64): links, packages (APK),
  installs and starts; the ggml probe finds no usable GPU on the emulator
  and falls back to the CPU ("whisper backend: CPU"), AAudio lists the
  microphones. Sent to the background it got TRIM_MEMORY_UI_HIDDEN from
  the system ("trim-memory 20: purged the malloc caches"), then
  `am send-trim-memory com.ghostpen.lite BACKGROUND` gave "trim-memory 40"
  and ran its unload (no model was loaded yet: no "unloaded the whisper
  model" line; dictation with a downloaded model wasn't tried).

On the emulator (android-35 google_apis x86_64, android-hello):

- the page loads from `https://app.localhost/index.html`;
- the info line reads "android x86_64 · launch #N · main" (IPC and the
  store; N went up across a process restart);
- the IPC echo round-trips "héllo 👋" (also a NUL byte and "✓");
- "Five ticks from a worker": the page's `listen("tick")` got ticks 1–5
  from the worker thread;
- resizing the display (`wm size 1280x800`) fires `resize` without a
  reload and the size line updates (533 × 853 → 853 × 533 CSS px);
- "Open a second window" opens `OrielWindowActivity` in its own task,
  with its own page ("second-1");
- "Notify" asks for POST_NOTIFICATIONS, then posts "Oriel Hello / Hello
  from Zig" on the `oriel` channel;
- the page's long-press menu opens; "Copy the echo text" succeeds;
- `am send-trim-memory dev.oriel.AndroidHello RUNNING_LOW` logs
  "trim-memory 10: purged the malloc caches", and the page gets
  `android:event` `{name: "trim-memory", data: "15"}` for RUNNING_CRITICAL.

Fixed by these runs: every `OrielRuntime` call shared one cached method
ID (a type declared in a generic function is deduplicated by what it
captures), so showing the main window called `showWindow` with
`createWindow`'s ID and CheckJNI aborted the app; the trim-memory purge
logged at debug (compiled out in release builds); the GNOME bindings were
an eager dependency, so Android builds failed where that release asset
couldn't be fetched.

The emulator had no KVM (no vmx/svm in the CPU), so it ran under TCG,
about 50 times slower. Two workarounds were needed, neither Oriel's
problem: system_server's watchdog killed it in a loop during boot
(`adb root; adb shell setprop ro.hw_timeout_multiplier 10; adb shell stop;
adb shell start` right after adb comes up fixes it), and the image's
WebView 124 renderer died with a SIGTRAP about three minutes in, with a
plain WebView app just the same. Chromium's own SystemWebView 157
(`chromium-browser-snapshots/AndroidDesktop_x64`, installed and selected
with `cmd webviewupdate set-webview-implementation com.android.webview`)
works. With KVM neither step should be needed.

What the first 2026-09-30 session verified, against a stand-in NDK built from
bionic `android-15.0.0_r1` (`scripts/android/bionic-sysroot.py`, API 29)
and the real android-34/35 `android.jar`:

- `examples/android-hello`: `liboriel.so` builds and links for x86_64 and
  arm64-v8a: 16 KiB-aligned LOAD segments, `.note.android.ident` (API
  29), the 13 JNI exports, and every import versioned against bionic
  (LIBC..LIBC_Q, LIBLOG, LIBANDROID), so none needs a newer Android.
- `examples/ghostpen-lite` (whisper, ggml CPU, AAudio) with and without
  `-Dggml_vulkan`, both ABIs. Vulkan is compiled in with no `libvulkan.so`
  dependency (loaded at runtime).
- The generated manifest and resources link with aapt against the Android
  14 framework (aapt 1 can't read android-35's resources.arsc). The
  Kotlin runtime compiles warning-free against the android-35 jar.

Fixed by these builds: the manifest's header comment ("--" isn't allowed in
an XML comment, so every generated manifest was malformed); the Vulkan
shader list (hard-coded to llama.cpp's ggml, so whisper-only builds failed);
SPIR-V headers for Vulkan on Android (not in the NDK); a clear error when
the NDK is missing.

Memory: Oriel's internal allocations on Android go to bionic's malloc
(`src/core/heap.zig`), the heap the app's `gpa`, ART and WebView already
use, instead of a second heap (`smp_allocator`) that keeps its own slabs
and per-thread caches. The app's arena sits on it too (not one mmap per
chunk). Zig's 256 KiB per-thread signal stack is off (the generated root
sets `signal_stack_size = null` unless the app sets it): it only serves
std's segfault handler, which a JNI library never installs, and bionic
allocated it in every thread touching the library's TLS. TLS went from 264
KiB to about 2 KiB. On memory pressure (`onTrimMemory`, running low or
worse) the runtime purges malloc's caches (`mallopt(M_PURGE)`) and passes
the level on as the "trim-memory" system event, so apps can unload models.
GhostPen Lite does: at TRIM_MEMORY_BACKGROUND, unless dictation or
captions are running, it frees the whisper model (ggml-small: ~465 MB) and
its recording buffer, and the next dictation loads the model again.

| | Done | Verified here | Needs a device |
|---|---|---|---|
| M0 build | `target.zig`, every selector, NDK libc file, 16 KiB pages | real NDK r28c build for x86_64 and arm64: page size, API note, TLS, imports; stand-in NDK link check; Android type-check; Linux, Windows checks; unit tests | — |
| M1/M2 backend | JNI entry, ALooper dispatch, windows as Activities, WebMessageListener IPC with token and isolation, `https://app.localhost` assets | `gradle assembleDebug` (AGP 8.7.3); on the Android 15 emulator: page load, IPC echo, store, resize, worker events, second window (Activity), page context menu | freeform resize from the caption bar, launch bounds (desktop windowing) |
| M3 modules | permissions, store, clipboard, notifications, SAF dialogs, deep links, fs_watch | emulator: notification permission prompt and notification, store across restarts, clipboard write, trim-memory | SAF dialogs, deep links, fs_watch at runtime |
| M4 models | AAudio capture, Vulkan and OpenCL compiled in behind runtime loaders, Hexagon prebuilt + stub, self-test and CPU fallback | GhostPen Lite with `-Dggml_vulkan` (real NDK) starts on the emulator and falls back to the CPU; AAudio lists devices | GPU (Vulkan, Adreno OpenCL) and NPU (Hexagon) on real hardware; numbers |
| M5 CLI | `oriel android init/dev/build/devices`, template in the Oriel package | project generation for both examples; the generated projects build with Gradle and install with adb | `oriel android dev` end to end |
| M6 GhostPen | tile, keyboard (`commitText`), notification actions, headset button; GhostPen Lite dictation | GhostPen Lite builds, installs and starts | the whole flow |

Needs real hardware whatever the emulator shows: GPU and NPU backends
(Vulkan drivers, Adreno OpenCL, Hexagon HTP; the emulator's ggml probe
found no usable GPU), desktop windowing on a Chromebook/Googlebook
(freeform resize from the caption bar, multi-window side by side, launch
bounds), AAudio capture latency, arm64 at runtime (only x86_64 ran), and
16 KiB-page devices (the libraries are aligned; not run on one).

Host names and helper processes (2026-10-01, GhostPen with built-in
models on a Chromebook): the app's `Io` (`src/platform/android/io.zig`)
resolves names with bionic's getaddrinfo, since `Io.Threaded` reads
/etc/resolv.conf, which Android doesn't have (every lookup failed with
NameServerFailure). Its executable path is `liboriel_exec.so`
(`launcher.zig`), a 9 KB launcher installed next to `liboriel.so` that
loads it and runs the app's `main` (`oriel_exec_main`), so an app that
starts itself as a helper (`--llm-helper`) gets a process of its own
instead of starting app_process64. The Gradle project extracts the
native libraries (`useLegacyPackaging = true`) so the launcher is a file
Android lets the app run.

Not done: the updater (sideloaded APK updates), the media server
(`openat2` may be blocked by Android's seccomp filter), draw-over-apps
overlays, other apps' audio (MediaProjection), per-device benchmarks.

## Risks

- **NDK libc** gates M0: smoke build first.
- **WebView ≠ WebKitGTK**: security-critical IPC token/isolation port; reply path via WebMessageListener ports.
- **Accelerators need real hardware**: emulator has no NPU; Hexagon is experimental upstream; Mali/Adreno drivers vary → self-test, blocklist, CPU fallback.
- **Desktop windowing differs** across Pixel, DeX, ChromeOS, Googlebook OS.
- **Play policy**: keyboards OK, draw-over-apps scrutinized, self-update forbidden, mic services need declarations.
- **Memory / multi-window**: model-size guidance; one main-thread funnel and a shared window registry.

## First prototype pass criteria

Build (`zig build -Dtarget=aarch64-linux-android` or `x86_64-linux-android`),
`gradle installDebug`, `adb shell am start -n com.example.oriel/.OrielActivity`,
enable freeform windows. Pass when: the window resizes from its caption bar
and the page receives `resize`; an IPC echo round-trips; right-click opens
the web UI's menu; a second instance opens a second window.

Test loops: x86_64 emulator with KVM on the Linux machine
(`emulator -avd test -no-window -no-audio -gpu swiftshader_indirect`),
arm64 emulator on the Mac mini, MediaTek Chromebook over `adb connect`.
