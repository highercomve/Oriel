# Oriel Showcase

One app with everything Oriel does, built from the same `src/main.zig` and
`web/` for Linux, Windows, macOS, Android and iOS.

| Tab | What it shows |
|---|---|
| Dictate | Voice to text (`oriel.dictation`): whisper on the CPU or the GPU, or the system recognizer; live text, file transcription, "dictate anywhere" |
| Chat | A local LLM (`oriel.chat`, llama.cpp): streamed replies, Stop, KV-cache reuse, Compare GPU and CPU, a mic that dictates the message |
| Notes | SQLite (`oriel.sql`) and deep links (`oriel-showcase://note/<text>`) |
| Files | Open and save dialogs, transcribing a WAV file |
| System | Clipboard, notifications, keyboard shortcuts; the tray, menus and typing into other apps on desktops; the Quick Settings tile and the keyboard on Android |
| App | Windows, IPC, events from a worker thread, device info |

Models are not in the app: the Dictate and Chat tabs download them on first
use (or copy them into the folder the App tab shows under "Data").

## Screenshots

<p>
  <img src="../../assets/screenshots/showcase-dictate.png" alt="Dictation on Android" width="19%">
  <img src="../../assets/screenshots/showcase-chat.png" alt="Local AI chat on Android" width="19%">
  <img src="../../assets/screenshots/showcase-notes.png" alt="SQLite notes on Android" width="19%">
  <img src="../../assets/screenshots/showcase-system.png" alt="System integrations on Android" width="19%">
  <img src="../../assets/screenshots/showcase-app.png" alt="Windows, IPC, and app information on Android" width="19%">
</p>

## What you need everywhere

- [Zig 0.16](https://ziglang.org/download/).
- Optionally the `oriel` CLI, which wraps the commands below and finds or
  sets up the platform tools: from the repository root, `zig build cli`
  writes `zig-out/bin/oriel`.

Run every command in this directory (`examples/showcase`). Plain
`zig build` works everywhere too; the CLI adds packaging, devices and
signing.

## GPU options

Without options, whisper and llama run on the CPU (on Macs and iPhones, on
Metal). Add these to any `zig build` or `oriel build`/`package` command:

| Option | Where | Needs |
|---|---|---|
| `-Dggml_vulkan` | Linux, Windows, Android | Linux: `glslc` and the Vulkan headers (Debian/Ubuntu: `libvulkan-dev spirv-headers glslc`; Arch: `vulkan-headers spirv-headers vulkan-icd-loader shaderc`). Windows: the [Vulkan SDK](https://vulkan.lunarg.com/). Android: nothing, the NDK has it |
| `-Dggml_cuda` | Linux with an NVIDIA GPU | The CUDA toolkit (`-Dcuda_path`, default `$CUDA_PATH` or `/opt/cuda`); `-Dcuda_arch=86,89` to pick GPUs, `-Dcuda_static` to need only the driver at runtime |
| `-Dggml_opencl` | Android (Adreno GPUs) | Nothing extra |
| `-Dggml_arm=i8mm` | Android | Faster CPU kernels for Armv8.6+ phones (the default, `dotprod`, runs on any recent phone) |

The app picks the GPU or the CPU per model on its own; Compare (in Dictate
and Chat) measures both and remembers the faster one.

## Linux

Build dependencies (Debian/Ubuntu names):

```sh
sudo apt install pkg-config libgtk-4-dev libwebkitgtk-6.0-dev libpulse-dev \
  libwayland-dev libx11-dev libxtst-dev libxkbcommon-dev
```

Fedora: `gtk4-devel webkitgtk6.0-devel pulseaudio-libs-devel wayland-devel
libX11-devel libXtst-devel libxkbcommon-devel`. Arch: `gtk4 webkitgtk-6.0
libpulse wayland libx11 libxtst libxkbcommon`.

```sh
zig build run                         # build and run (Debug)
zig build -Doptimize=ReleaseFast      # release: zig-out/bin/oriel-showcase
oriel package                         # .deb, .rpm and .AppImage in zig-out/package/
./install-local.sh                    # build with CUDA and install the AppImage for this user
```

Packaging needs `nfpm` (deb, rpm), `mksquashfs` (AppImage) and
`desktop-file-validate`. The AppImage uses the system's GTK 4 and
WebKitGTK 6.0, so the target machine needs them installed.

Headless checks, no window:

```sh
zig-out/bin/oriel-showcase --download qwen2.5-0.5b
zig-out/bin/oriel-showcase --chat "Hello"          # a reply and a follow-up, with tokens/s
zig-out/bin/oriel-showcase --compare qwen2.5-0.5b  # GPU against CPU
zig-out/bin/oriel-showcase --transcribe talk.wav   # needs a whisper model downloaded
```

## Windows

Natively on Windows (Windows 10 or 11 with the WebView2 runtime, which
Windows 11 includes):

```powershell
oriel setup webview2                  # caches WebView2Loader.dll
oriel setup nsis                      # NSIS, for the installer
oriel build -Doptimize=ReleaseFast    # zig-out/bin/oriel-showcase.exe
oriel package                         # zig-out/package/oriel-showcase-<version>-setup.exe
```

Or cross-compiled from Linux (needs `makensis`, the `nsis` package):

```sh
oriel package -Dtarget=x86_64-windows
```

The installer installs per user (no administrator), adds Start Menu
shortcuts and checks for the WebView2 runtime. With `-Dggml_vulkan` the
shaders are compiled into the executable (about 55 MB more; the installer
compresses it), and the app falls back to the CPU on machines without a
Vulkan driver.

## macOS

On a Mac with Xcode or the command line tools (`xcode-select --install`):

```sh
zig build run                         # build and run
oriel build                           # zig-out/Oriel Showcase.app
oriel package                         # zig-out/package/Oriel Showcase.app and the .dmg
```

whisper and llama run on Metal. The build targets macOS 13 and later. For
the microphone (Dictate), run the `.app` rather than the bare executable:
macOS grants it per app bundle. Signing and notarization: see the
README's "macOS bundles" section (`-Dmacos-sign-identity`,
`-Dmacos-notarize-profile`).

## Android

Needs a JDK 17, the Android SDK (platform-tools, Gradle 8.9+) and the NDK
(`$ANDROID_NDK_HOME`, or `$ANDROID_HOME/ndk/<version>`). The Gradle project
is already in `android/`.

```sh
oriel android dev --abi arm64         # debug build on the connected phone (x86_64 for the emulator)
oriel android build --abi arm64 --apk # release APK: android/app/build/outputs/apk/release/
adb logcat -s Oriel chromium          # logs
```

`oriel android dev/build` forward Zig `-D` options. Enable the native
renderer or GPU backends directly:

```sh
oriel android dev --abi arm64 -Dnative_ui
oriel android build --abi arm64 --apk -Dnative_ui -Dggml_vulkan -Dggml_opencl
```

Release builds are stripped and minified (R8). The APK is unsigned unless
`$ORIEL_ANDROID_KEYSTORE`, `$ORIEL_ANDROID_KEYSTORE_PASSWORD`,
`$ORIEL_ANDROID_KEY_ALIAS` and `$ORIEL_ANDROID_KEY_PASSWORD` are set; to try
an unsigned one, sign it with your debug key (`apksigner sign --ks
~/.android/debug.keystore`). `oriel android build --aab` makes the bundle
for Google Play.

On the phone, "dictate anywhere" works from the Quick Settings tile ("Dictate
anywhere"), the Oriel keyboard (enable it in the system's keyboard settings)
and the headset button. More in [docs/android.md](../../docs/android.md).

## iOS

Needs Apple's iOS SDK: on a Mac, Xcode; on Linux,
[xtool](https://github.com/xtool-org/xtool), which extracts the SDK from
`Xcode.xip` (download it from Apple's developer site). `oriel ios setup`
sets xtool and the SDK up, asking first.

```sh
oriel ios build --simulator           # zig-out/ios/Oriel Showcase.app for the simulator (on a Mac)
oriel ios install --simulator         # into the booted simulator
oriel ios build --ipa                 # for a device: the .app and zig-out/Oriel Showcase.ipa
oriel ios install                     # signs with your Apple ID and installs over USB or Wi-Fi
```

With Zig alone: `zig build -Dtarget=aarch64-ios -Dapple_sdk=<iPhoneOS.sdk>`
(`aarch64-ios-simulator` for the simulator). Dictation keeps running in the
background (background audio), and the system engine is Apple's speech
recognizer. More in [docs/ios.md](../../docs/ios.md).
