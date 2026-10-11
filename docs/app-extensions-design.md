# Oriel app extensions, lifecycle, camera and system AI: design

Status: proposal (2026-10-11), for review before any code.

Oriel's apps exist to find what the framework is missing. Porting GhostPantry to iOS
found four gaps. In each, the app had to write platform code that belongs in Oriel:

| Gap | What GhostPantry does today | Where |
|---|---|---|
| Lifecycle | Registers `oriel.android.onSystemEvent` and parses `"trim-memory"` levels. iOS would need `oriel.ios.onSystemEvent` and `"memory-warning"`: a second API with other names. Its Kotlin extensions get no memory hook, so the YOLOE detector closes its ONNX sessions after every pass. | `src/main.zig:405`, `src/local.zig:982`, `YoloePackageDetector.kt:73` |
| Module flags | `.tray = !is_android, .dialog = !is_android`. On iOS a desktop-only flag is a build *error*. On Android the same flag builds a stub. | `build.zig:9-18`; Oriel `build.zig:101` |
| Calling native code | Its own JNI transport: a `bind` export per Kotlin class, a global class ref, attach/detach, and a static `request([B)[B` called by name. Error names say "SystemAi" for every caller. iOS has no mechanism at all. | `src/android_ai_bridge.zig`, `system_ai.zig:27`, `embedding.zig:8` |
| Camera and System AI | A Kotlin extension intercepts `<input capture>`, launches the camera app through a ContentProvider declared by hand in the tracked manifest, and transcodes HEIC. Gemini Nano goes through ML Kit in another app extension. | `PantryAndroidExtension.kt`, `PantryCameraProvider.kt`, `AndroidManifest.xml:72`, `SystemAiExtension.kt` |

The fixes below are general. GhostPantry is the first user, but each part is meant for any
app: a podcast app that frees caches on memory pressure, a notes app calling a vendor SDK
through Kotlin or Objective-C, a receipts app capturing photos, or any app using the phone's
on-device model.

Decisions this builds on (docs/platform-capabilities-design.md): ADR-0.2 (typed per-platform
escape hatches), ADR-0.4 (one JS API source), ADR-0.5 (queued events), ADR-0.6 and decision 4
("modules follow the app's configuration"), and decision 2 (no paid Apple team for now).

---

## 1. Lifecycle: `oriel.lifecycle` (core, every platform)

### API
```zig
pub const Event = union(enum) {
    /// Every window left the screen (Android: the last Activity stopped; iOS:
    /// didEnterBackground; desktop: never, see below). Free what is cheap to rebuild.
    background,
    foreground,
    /// The system wants memory back. `critical`: the process may be ended next.
    memory_pressure: enum { moderate, critical },
    /// The machine is about to sleep / just woke (desktop and Android doze, best effort).
    suspend_, resume_,
    /// The app is ending (session end, terminate, quit): flush state, no new work.
    terminating,
};
pub const Handler = *const fn (event: Event) void;
/// Up to 16 subscribers (fixed table), each called on the main thread in
/// registration order. Modules subscribe too (below).
pub fn subscribe(handler: Handler) error{TooManySubscribers}!void;
```
- **JS:** the page gets the same events, `oriel.lifecycle.on((e) => …)`, as `lifecycle` events. They are queued until the page listens (ADR-0.5).
- **Native extensions** (section 3) get them too, so Kotlin and Objective-C code can free models.

### Mapping
| Event | Android | iOS | macOS | Windows | Linux |
|---|---|---|---|---|---|
| background / foreground | Process lifecycle: the started-Activity count reaches 0 / leaves 0 (OrielActivity onStart/onStop) | didEnterBackground / willEnterForeground (already wired, Shell.zig:547) | not sent (a desktop app is never "in the background" in this sense) | not sent | not sent |
| memory_pressure | onTrimMemory: RUNNING_LOW (10) is moderate; RUNNING_CRITICAL (15), BACKGROUND (40) and COMPLETE (80) are critical | didReceiveMemoryWarning is critical | `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` warn/critical | `CreateMemoryResourceNotification(LowMemory…)` on a waiter thread, critical | GLib `GMemoryMonitor` low-memory-warning (it reads PSI): LOW is moderate, CRITICAL is critical |
| suspend / resume | not sent (Android has no reliable hook) | not sent | `NSWorkspaceWillSleep` / `DidWake` | `WM_POWERBROADCAST` PBT_APMSUSPEND / RESUMEAUTOMATIC | logind `PrepareForSleep` (D-Bus) |
| terminating | not sent (Android kills processes without warning) | applicationWillTerminate | applicationWillTerminate | WM_ENDSESSION (today's `on_session_end`) | SIGTERM, session end |

Compatibility:
- `oriel.android.onSystemEvent` stays, for Android-only events (tile, notification action, ime-*, media-button). `trim-memory` is also delivered there, as now.
- `oriel.ios.onSystemEvent` and `App.Config.on_session_end` become thin wrappers, deprecated in the changelog.
- Oriel's own `mallopt(M_PURGE)` on trim-memory moves to a built-in subscriber.

### Built-in modules use it
`chat`, `dictation` and `tts` gain an option:
```zig
.unload_on = .{ .background = false, .memory_pressure = .critical }
```
It defaults to unloading on critical pressure. Each module subscribes itself, so apps stop
writing `unloadIdle` glue (as the showcase does today, and GhostPantry's `local.zig` would).

---

## 2. Module flags on phones: requested means "where available"

Today:
- Android builds a stub for a desktop-only module (same API, `error.Unsupported`).
- iOS fails the build.

Apps must branch per target, and the same `build.zig` can't target both. Decision 4 already
says modules follow the app's configuration.

**Change:**
- iOS behaves like Android. A desktop-only module the app enables (`tray`, `menu`, `global_shortcut`, `input`, `updater`, `media_server`, `fs_watch`, `layer_shell`) builds as a stub on iOS too.
- The build prints one note per module ("tray: not available on iOS, built as a stub"). Missing stubs (iOS backends for `fs_watch`, `layer_shell`) are added.
- Every module gets `pub const available: bool` (comptime), so apps can branch in Zig without `@hasDecl` or `builtin.abi` checks.
- The page gets `oriel.features` (`{ tray: false, camera: true, systemAi: true, … }`), so UIs hide what isn't there. GhostPantry shows "System AI" and "Fast local" on desktop, where they always fail.

**Kept:** `-Dtray=true` on the command line for an iOS target is still an error. That is a
person asking explicitly; only the app's dependency defaults become "where available".

---

## 3. App extensions: calling an app's own native code, on every platform

### The primitive
An app declares named extensions. Each platform supplies an implementation, or none. Zig and
the page call them with one API. Oriel does the transport (JNI, the Objective-C runtime, or a
Zig function), the threads, cancellation, lifecycle delivery, and the build plumbing (sources,
dependencies, frameworks, keep rules).

```zig
// build.zig
_ = oriel.addApp(b, dep, .{
    .extensions = &.{.{
        .name = "pantry.vision",                       // what Zig and JS call
        .android = .{
            .class = "dev.ghostpantry.VisionExtension",
            .sources = &.{b.path("android/VisionExtension.kt"), …},
            .dependencies = &.{"com.microsoft.onnxruntime:onnxruntime-android:1.30.0"},
            .assets = &.{.{ .from = b.path("models/detectors"), .to = "detectors" }},
        },
        .ios = .{
            .class = "GPVisionExtension",
            .sources = &.{b.path("ios/VisionExtension.m")},   // compiled by zig cc, -fobjc-arc
            .frameworks = &.{ "Vision", "CoreML" },
            .resources = &.{b.path("models/yoloe.mlmodelc")},
        },
        .desktop = .{ .zig = b.path("src/vision_desktop.zig") }, // optional, any desktop OS
    }},
});
```

```zig
// Zig: any thread except the main one (calls may block on the native side).
const vision = oriel.extensions.get("pantry.vision");        // comptime-checked name
if (!vision.available()) return error.Unavailable;           // no implementation on this platform
const reply = try vision.call(arena, "detect", request_json, .{ .timeout_ms = 30_000, .cancel = &token });
// Native code can emit progress: delivered to `vision.onEvent(handler)` and to the page.
```
```js
// JS: the same, without a Zig command written per method.
// Opt-in per extension: `.page = true` in build.zig.
const r = await oriel.extensions.call("pantry.vision", "detect", { image, threshold: 0.25 });
```

### The contract (every platform)
- **Message:** `(method: string, input: bytes) -> bytes`. Oriel adds no schema; JSON is the convention, and the JS side uses JSON.
- **Size limits:** inputs and replies are capped (default 32 MiB, settable per extension). Oversized input is refused before it crosses.
- **Errors:** an implementation fails with a code and a message (Kotlin `OrielExtensionError(code, msg)`, Objective-C `NSError`, Zig error). Callers get `error.ExtensionFailed` plus the message, or `Unavailable`, `Timeout`, `Cancelled`, `TooLarge`.
- **Threading:** calls run on the extension's own worker, one at a time by default (`.concurrency = 1`, configurable). The UI thread never blocks on a call. Native code that needs the UI thread asks for it: `ctx.runOnUi { }` / `dispatch_async(main)`.
- **Cancellation:** `ctx.isCancelled` / `call.cancelled` is polled by long work. The timeout cancels, then reports.
- **Lifecycle:** each extension receives the section 1 events (`onLifecycle(event)`), plus `onLoad` and `onUnload`.
- **Events out:** `ctx.emit(name, bytes)` reaches Zig handlers and the page (queued until listened).

### Android
- An interface in the template, next to `OrielAndroidExtension`, which keeps its Activity and WebView hooks:
```kotlin
interface OrielAppExtension {
    fun call(method: String, input: ByteArray, call: OrielCall): ByteArray
    fun onLifecycle(event: OrielLifecycle) {}
    fun onLoad(ctx: OrielExtensionContext) {}
}
```
- A class may implement both interfaces (GhostPantry's camera hooks plus calls).
- The generated registry gains `call(name, method, input, callId)`, reached from Zig through the existing static `OrielRuntime` channel (`runtime.call`). Apps write no JNI, `bind` exports or `FindClass`.
- Declared classes get `-keep` rules generated (they're constructed directly; R8 still needs to keep their methods).
- `OrielCall` carries `isCancelled`, `emit`, the Activity (or null), `filesDir`/`cacheDir`, and a per-extension executor.

### iOS
- An Objective-C protocol in Oriel's runtime (declared with `objc.zig`, no SDK headers):
```objc
@protocol OrielAppExtension <NSObject>
- (NSData *)callMethod:(NSString *)method input:(NSData *)input call:(OrielCall *)call error:(NSError **)error;
@optional
- (void)lifecycle:(NSString *)event;
- (void)load:(OrielExtensionContext *)context;
@end
```
- App sources are compiled by `zig cc -fobjc-arc` (as ggml's Metal `.m` already is). Frameworks are added to the link line, resources are copied into the bundle, and the class is found with `objc_getClass` at startup.
- No Xcode project.
- **Swift (`.ios.swift_sources`, phase 4):** an `@objc` class conforming to the protocol, compiled with `swiftc` from the SDK (`xcrun swiftc` on a Mac; xtool's toolchain on Linux) into an object file linked into the executable. It's needed only for Swift-only Apple frameworks (FoundationModels). It's opt-in, so Oriel's "no Swift" stays true for apps that don't ask.

### Desktop
- `.desktop = .{ .zig = path }`: a Zig module exporting `pub fn call(ctx, method, input) ![]u8` (plus the optional lifecycle hooks), linked in at comptime. It runs on the same worker, with the same limits.
- `.linux` / `.macos` / `.windows` can override per OS.
- C libraries go through the Zig module, the usual way.

### Also covered by this primitive
- **Manifest components:** extensions can declare Android components (`providers`, `services`, `receivers`) as typed entries, rendered into the generated `oriel:components` region. That's ADR-0.2's escape hatch, for a vendor SDK that needs a provider. GhostPantry won't need it, because section 4a owns its camera provider.
- **App-owned assets:** `.android.assets` / `.ios.resources` place model files without editing the generated project.

---

## 4. Higher-level modules

### 4a. Photo capture: `oriel.camera` (`-Dcamera`, on when `.permissions.camera` is declared)
Two ways in, the same backends.

**`<input type="file" accept="image/*" [capture]>` just works:**

| | Camera (`capture`) | Library |
|---|---|---|
| Android | Oriel requests CAMERA if the manifest declares it, then `ACTION_IMAGE_CAPTURE` into an Oriel-owned FileProvider (`<app id>.oriel.capture`, generated in the components region, temp files swept daily) | The system photo picker (`ACTION_PICK_IMAGES` on 33+, `GET_CONTENT` below) |
| iOS | WKWebView already shows Take Photo / Photo Library for capture inputs once `NSCameraUsageDescription` exists (`.permissions.camera`); verified, not reimplemented | same |
| Desktop | the browser engine's file chooser; `getUserMedia` for live video | same |

On Android, images the page can't decode (HEIC, AVIF on older WebViews) are transcoded to JPEG
when `.camera = .{ .transcode = true }`. The default is true.

**Zig and JS API** (for native UI apps and for flows that want bytes, not a File):
```zig
const photo = try oriel.camera.capturePhoto(io, arena, .{
    .source = .camera, // or .library
    .max_side = 1600,
    .format = .jpeg,
    .quality = 85,
});
// photo.bytes, photo.width, photo.height; error.Cancelled when the user backs out,
// error.Unsupported where there is no camera (desktop .camera, the simulator).
```
- iOS: `UIImagePickerController` (camera) / `PHPickerViewController` (library).
- Android: the same intents.
- Desktop: `.library` opens the dialog module's image picker; `.camera` is Unsupported (pages use getUserMedia).

### 4b. On-device system model: `oriel.system_ai` (`-Dsystem_ai`, off by default)
The phone's own model, with no download by the app.

```zig
pub fn status() Status;                   // available | downloadable | downloading | unavailable, plus a reason
pub fn capabilities() Capabilities;       // images, streaming, structured_output, max_input_tokens
pub fn download(io, on_progress) !void;   // where the platform downloads on demand (ML Kit)
pub fn generate(io, arena, req: Request, on_token: ?TokenFn) ![]const u8;
pub const Request = struct {
    system: []const u8 = "",
    prompt: []const u8,
    images: []const Image = &.{},
    temperature: f32 = 0.2,
    max_tokens: u32 = 1024,
    schema: ?[]const u8 = null,
};
pub fn cancel() void;
```

| Platform | Backend | Notes |
|---|---|---|
| Android | ML Kit GenAI Prompt API (Gemini Nano via AICore) in Oriel's template; the Maven dependency is added only with `-Dsystem_ai` | Text and image input; streaming; download states with progress; supported devices only (Pixel 9+, recent Galaxy S…) |
| iOS 26+, macOS 26+ | Apple Foundation Models (`LanguageModelSession`) | Swift-only: needs section 3's Swift support. Apple Intelligence devices only. Image input isn't in the first release (`capabilities().images = false`); structured output maps to `@Generable` only partly (JSON schema as instructions) |
| Windows | Windows AI APIs (Phi Silica) on Copilot+ PCs | later |
| Linux, older OS versions | `unavailable` | apps fall back to `chat` (llama.cpp) or a server |

A JS mirror (`oriel.systemAi.status/generate`) streams tokens as events.

### What stays app code (on the new primitive)
GhostPantry's YOLOE detector and EmbeddingGemma matching are app-specific models. They become
**app extensions** (section 3):
- **Android:** today's Kotlin, minus the JNI bridge, plus `onLifecycle` to keep sessions open between passes.
- **iOS:** possible later with Vision/Core ML (YOLOE exported to Core ML; EmbeddingGemma needs a Core ML or LiteRT-on-iOS build: to research).
- Until then the iOS build reports `available() == false`, and the UI hides "Fast local".

---

## 5. Phases

| Phase | Oriel work | Verified on |
|---|---|---|
| 1 (0.9.17) | `oriel.lifecycle` (Android, iOS; desktop backends as available), module flags as "where available" + `available`/`oriel.features`, app extensions (Android Kotlin, iOS Objective-C, desktop Zig), JS `oriel.extensions`, docs, a showcase extension implemented on all three, unit tests | Linux; Android (Poco X3, adb); iOS simulator (osx); macOS (osx) |
| 2 (0.9.18) | `oriel.camera` (input handling + `capturePhoto`), `oriel.system_ai` Android backend, chat/dictation/tts `unload_on` | Android device for camera and system AI (a Gemini Nano device is needed: the Poco X3 reports unavailable); iOS simulator for library picks |
| 3 | GhostPantry on Oriel 0.9.18: drop `android_ai_bridge.zig`, `PantryAndroidExtension`, the provider and its manifest edit; move System AI to `oriel.system_ai`; vision/matching as app extensions; hide unavailable providers; build and run on the iOS simulator; Android regression pass, then release | Android device, osx simulator |
| 4 | Swift sources for iOS extensions; `system_ai` on iOS/macOS 26 (Foundation Models); desktop lifecycle backends not done in 1; iOS Vision/Core ML ports of GhostPantry's detector; Windows AI | needs macOS 26 + Xcode 26 on the Mac, an Apple Intelligence device |

---

## 6. Constraints found

- **The Mac (osx):** macOS 15.2, Xcode 16.3, iOS 18.4 SDK and simulator, Swift 6.1.
  - Vision, CoreML, AVFoundation and PhotosUI are there.
  - FoundationModels is not: it needs Xcode 26 and macOS 26 to build and test (phase 4).
  - The simulator has no camera, so only library picks can be tested.
  - No iPhone is paired.
  - The only signing identity is Developer ID, so installing on a device needs an Apple Development certificate (and decision 2 says there's no paid team).
- **Android System AI** needs a supported device. The Poco X3 test device will report `unavailable`, which tests that path. The Galaxy S25 Ultra tester can check the available path.
- **GhostPantry's Android build must keep working identically through phase 3.** Each step is checked on the device before release.

## 7. Questions for review

1. **Names:** `oriel.extensions` / `OrielAppExtension` (next to the existing `OrielAndroidExtension`), `oriel.lifecycle`, `oriel.camera`, `oriel.system_ai`. Any preferences?
2. **Swift:** allow opt-in `.ios.swift_sources` (phase 4), or keep Oriel strictly Objective-C and leave Foundation Models out?
3. **Module flags:** OK to drop the iOS build error for app-enabled desktop modules (keeping it for an explicit `-D` on the command line)?
4. **Page access to extensions:** opt-in per extension (`.page = true`) as proposed, or Zig-only, so every page-facing method goes through a reviewed Zig command?
5. **Phase 4 Mac upgrade:** System AI on iOS can't be built until the Mac runs macOS 26 / Xcode 26. Upgrade it then, or treat iOS System AI as out of scope for now?
