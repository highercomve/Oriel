# Oriel on iOS

Oriel apps run on iPhone and iPad: UIKit with a WKWebView per window,
driven from Zig through the Objective-C runtime, like the macOS backend.
The app is an ordinary executable in an `.app` bundle; no Xcode project,
Swift or Objective-C source is involved.

Status: the backend, the modules below and the bundle build are complete
and type-check for devices and the simulator (`zig build check
-Dtarget=aarch64-ios`, `x86_64-ios-simulator`). They have not yet run on a
device or simulator: linking needs Apple's SDK, which CI or a Mac provides.

## Building

| Step | What it does |
|---|---|
| `zig build check -Dtarget=aarch64-ios` | Type-check. No SDK needed: Oriel declares the Objective-C runtime in Zig (`src/platform/apple/objc.zig`) instead of translating SDK headers. Apps with C dependencies (`sql`, `llama`, `whisper`) need the SDK's libc headers even for this. |
| `zig build -Dtarget=aarch64-ios -Dapple_sdk=<iPhoneOS.sdk>` | The frontend built and embedded, the executable linked, and `zig-out/ios/<Name>.app` written (unsigned). |
| `zig build ios-dev -Dtarget=… [-Dios_dev_url=http://<LAN address>:5173/]` | The same app loading the dev server: `zig-out/ios-dev/<Name>.app`. A device can't reach the machine's `localhost`, so pass its LAN address (and run the dev server with `--host`). The dev bundle allows plain HTTP (App Transport Security). |
| `zig build ios-ipa -Dtarget=aarch64-ios …` | `zig-out/<Name>.ipa` (`Payload/<Name>.app`, zipped with `zip`). |

Targets: `aarch64-ios` (devices), `aarch64-ios-simulator` (Apple-silicon
Macs), `x86_64-ios-simulator` (Intel Macs). The minimum is iOS 15
(`build/ios.zig`); `-Dtarget=aarch64-ios.17.0` raises it.

The SDK comes from `-Dapple_sdk` or `$APPLE_SDK`:

- on a Mac: `$(xcrun --sdk iphoneos --show-sdk-path)` (or `iphonesimulator`);
- on Linux: [xtool](https://github.com/xtool-org/xtool)'s `xtool setup`
  extracts the SDK from `Xcode.xip`; point `APPLE_SDK` at its
  `iPhoneOS.sdk`.

The CLI wraps these, and finds the SDK itself (`$APPLE_SDK`, Xcode's on a
Mac, or xtool's in `~/.swiftpm/swift-sdks/darwin.artifactbundle` on Linux):

```sh
oriel ios setup                   # set up the SDK and xtool (below)
oriel ios build [--simulator] [--ipa]
oriel ios dev [--simulator] [--url http://192.168.1.20:5173/]
oriel ios install [--simulator] [--dev]
```

When something is missing, the commands offer to set it up and ask first
(Enter accepts, `--yes` accepts without asking; without a terminal nothing
is downloaded):

- **xtool** (Linux): downloads the latest `xtool-<arch>.AppImage` from
  xtool's GitHub releases into `~/.oriel/xtool/xtool` (an `xtool` on PATH
  wins).
- **usbmuxd** (Linux), through which xtool reaches the device: a system
  service, so it is installed with the distro's package manager (`sudo apt
  install usbmuxd`, or dnf, pacman, zypper), in a terminal since sudo asks
  for your password.
- **The SDK** (Linux): Xcode.xip can't be downloaded for you (Apple's page
  needs your Apple ID in a browser). With it downloaded, `oriel ios setup`
  runs `xtool setup`, which logs in to your Apple ID (for signing) and
  extracts the SDK; it only runs in a terminal, since it asks for your
  credentials. On a Mac, install Xcode.

`install` uses `xtool install` for a device (it signs the bundle with your
Apple ID's development certificate and a provisioning profile, then installs
it over USB or Wi-Fi; works from Linux) and `xcrun simctl` for the booted
simulator (a Mac). For the App Store, sign the `.app` with a distribution
certificate (`codesign`, or xtool) and upload the `.ipa` with Transporter
or `xcrun altool`.

### The bundle

`package_tool ios-app` writes the flat layout iOS expects: the executable,
`Info.plist`, `PkgInfo` and the icons as loose PNGs named in
`CFBundleIcons` (no asset catalog, so no `actool`). From `addApp`'s
options:

| Info.plist | From |
|---|---|
| `CFBundleIdentifier`, `CFBundleDisplayName`, versions | `.package` (`id`, `name`, `version`) |
| `NSMicrophoneUsageDescription`, `NSCameraUsageDescription`, `NSLocationWhenInUseUsageDescription` | `.permissions` (iOS terminates an app that uses one of them without its key) |
| `CFBundleURLTypes` | `.url_schemes` (deep links) |
| `UIBackgroundModes: audio` | `.ios = .{ .background_audio = true }` |
| `UIApplicationSceneManifest` (multiple scenes), `NSUserActivityTypes` | always: windows are scenes on iPad |
| `UILaunchScreen`, orientations, `UIDeviceFamily` (iPhone and iPad) | always |

## How it works

| Contract area | On iOS |
|---|---|
| Event loop | `App.run` calls `UIApplicationMain`, which never returns. App and scene delegates are defined at run time (`Shell.zig`). Launching opens the main window and runs `setup`; the first scene the system connects shows it. |
| Dispatch to the main thread | A task queue drained from the GCD main queue, as on macOS. |
| Windows | A view controller + WKWebView per window. On iPad (Stage Manager, Split View) extra windows get a scene of their own (`requestSceneSessionActivation`); on iPhone they are presented full screen over the window in front. Closing one dismisses it; the main window can't be closed. |
| Size, placement, always on top, click-through, drag | The system decides: no-ops. |
| Safe area | The webview is laid out in the safe area (below the status bar and the Dynamic Island, above the home indicator), as Android pads the page by the system bars; pages need no `env(safe-area-inset-*)`. `fullscreen` gives it the whole screen and hides the status bar and home indicator. |
| Assets | A `WKURLSchemeHandler` for `app://`, as on macOS. |
| IPC bridge | `WKScriptMessageHandlerWithReply`, the same token and isolation checks as every platform. |
| JS `alert` / `confirm` / `prompt` | `UIAlertController`. |
| Deep links | `scene:willConnectToSession:options:` (cold start) and `scene:openURLContexts:`; also a link among the launch arguments (`xcrun simctl launch <device> <id> myapp://...`), since `simctl openurl` makes iOS ask before opening the app. |
| Quitting | `quit` cleans up and calls `exit` (Apple discourages quitting outside fatal errors). |
| Lifecycle | `oriel.ios.onSystemEvent(handler)`: "background" (every window left the screen), "foreground" and "memory-warning", on the main thread. The showcase frees its whisper and llama models on the first and the last (`dictation.unloadIdle`, `chat.unloadIdle`), as it does on Android's trim-memory. |
| Logs | stderr (Xcode's console, `xcrun simctl launch --console-pty`) and, as on macOS, `Library/Logs/<id>/` in the app's sandbox. |

## Modules

| Module | On iOS |
|---|---|
| permissions | AVCaptureDevice (microphone, camera), CLLocationManager (location, when in use), UNUserNotificationCenter. Screen capture, system audio and accessibility don't exist for iOS apps: `denied`. `openSettings` opens the app's page in Settings. |
| clipboard | `UIPasteboard` text and PNG (other image types are converted). Reading shows iOS's paste banner. |
| notification | `UNUserNotificationCenter`; also shown while the app is in front. |
| dialog | `UIDocumentPickerViewController`. `openFile` returns a copy in the app's temporary directory. `saveFile` asks for a folder and returns `<folder>/<name>` (the title when it looks like a file name, else "Untitled"). Call them from async commands: they wait for the user. |
| audio_capture | `AVAudioSession` (play and record, mixing with other apps) + AudioQueue, mono f32 at the requested rate; sources are "default" and the session's inputs (built-in mic, headset, Bluetooth). |
| store | As on macOS, under the app's sandbox. |
| deep_link | See above. |
| llama, whisper | ggml with Metal (on by default for devices, `-Dggml_metal=false` to leave it out; off for the simulator, whose Metal can't run ggml's kernels: there both use the CPU). `chat` and `dictation` use the CPU on phones until their Compare measures the GPU (Metal must be 1.3× faster to be picked). |
| dictation (system engine) | Apple's Speech framework (`dictation/apple.zig`, iOS and macOS): `SFSpeechRecognizer` on an `AVAudioEngine` input tap, on the device when `supportsOnDeviceRecognition`, with punctuation. Each phrase is its own recognition task (ended after a pause or 50 s, since Apple stops a task after about a minute), so events match Android's. `.auto` picks it on iOS when it runs on the device. Needs the microphone and speech recognition permissions: the Info.plist gets `NSSpeechRecognitionUsageDescription` with the microphone's text, and authorization is asked on the first start. |
| tray, menu, global_shortcut, input, updater, media_server, fs_watch | Not available on iOS: off by default for iOS targets, and a build error when enabled. |

## Example

`examples/showcase` runs on iOS with the rest: dictation (whisper on Metal,
background audio), notes in SQLite and deep links (`oriel-showcase://`),
the file pickers, a second window (a scene of its own on iPad), IPC, events
from a worker, the store, the clipboard and notifications:

```sh
cd examples/showcase
zig build check -Dtarget=aarch64-ios
APPLE_SDK=… zig build -Dtarget=aarch64-ios
oriel ios install
```

## Next

- Run on a simulator and a device in CI (macOS runner): the first run will
  shake out selector and signature typos the type checker can't see.
- Keyboard avoidance: WKWebView scrolls the focused field into view; check
  fixed-position layouts (bottom tab bars) with the keyboard up.
- Share sheet, haptics, and background tasks as optional modules.
