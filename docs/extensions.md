# App extensions

[Back to Oriel](../README.md) · [Documentation](README.md) · [Platform hooks](platform-hooks.md)

An app extension is the app's own native code, declared by name in build.zig
and implemented per platform: Kotlin on Android, Objective-C or Swift on iOS,
Zig on the desktop. Zig calls it with one API on every platform. The page
reaches it only through Zig: an app command, or the methods Zig exposes.

Oriel does the transport (JNI, the Objective-C runtime, a Zig call), the
threads, cancellation, size limits, lifecycle delivery and the build
plumbing (sources, Gradle dependencies, R8 keep rules, frameworks, assets).

## Declaring

```zig
_ = oriel.addApp(b, dep, .{
    // ...
    .extensions = &.{.{
        .name = "pantry.vision", // lowercase dotted words, unique, up to 64
        .android = .{
            .class = "dev.ghostpantry.VisionExtension",
            .sources = &.{b.path("android/VisionExtension.kt")},
            .dependencies = &.{"com.microsoft.onnxruntime:onnxruntime-android:1.20.0"},
            .assets = &.{.{ .from = b.path("models/detectors"), .to = "detectors" }},
        },
        .ios = .{
            .class = "GPVisionExtension",
            .sources = &.{b.path("ios/VisionExtension.m")}, // zig cc -fobjc-arc
            .frameworks = &.{ "Vision", "CoreML" },
            .weak_frameworks = &.{}, // newer than the minimum: weak, and only when the SDK has them
            .resources = &.{b.path("models/yoloe.mlmodelc")}, // the bundle's root
        },
        .desktop = .{ .zig = b.path("src/vision_desktop.zig") }, // any desktop OS
        // .linux / .macos / .windows override .desktop per OS; .macos can also be
        // Objective-C or Swift: .macos = .{ .objc = .{ .class = ..., .sources = ... } }.
        .max_bytes = 32 << 20, // input and reply cap (default 32 MiB, at most 256 MiB)
        .concurrency = 1, // calls at once on the extension's workers (1..8)
    }},
});
```

A platform without an implementation builds fine: there the extension is
unavailable. Up to 64 extensions per app.

## Calling from Zig

```zig
const vision = oriel.extensions.get("pantry.vision"); // unknown name: build error
if (!vision.available()) return error.Unavailable; // comptime, per target

var diag: oriel.extensions.Diagnostics = .{};
var token: oriel.extensions.CancelToken = .{};
const reply = vision.call(arena, "detect", request_json, .{
    .timeout_ms = 30_000, // default 30 s, at most 10 min
    .cancel = &token, // token.cancel() from any thread
    .diag = &diag,
}) catch |err| switch (err) {
    error.ExtensionFailed => return oriel.ipc.fail("{s}: {s}", .{ diag.code(), diag.message() }),
    else => return err,
};
```

- **Threads.** Calls block on native code, so they are refused on the main
  thread (`error.WrongThread`): call from an async command
  (`async_commands`), `oriel.App.spawn`, or your own thread. Each extension
  has its own workers (`.concurrency`, default 1) behind a queue of 32;
  past that a call fails with `error.Busy`.
- **Errors:** `Unavailable` (no implementation here, or the app isn't
  running), `Timeout`, `Cancelled`, `TooLarge` (input refused before it
  crosses; a reply refused after), `ExtensionFailed` (code and message in
  `Diagnostics`), `WrongThread`, `Busy`, `InvalidMethod`, `OutOfMemory`.
- **Timeout and cancellation.** The native side sees `isCancelled` and the
  caller returns at once; the worker stays busy until the native code
  returns, so long work should poll.
- **Events.** `vision.onEvent(handler)` gets what native code emits, on the
  main thread (events from before the handler come first).
- **Loading.** An extension loads (its `onLoad`, the Kotlin or Objective-C
  instance) on its first call, or with `vision.load()`. Loaded extensions
  get [`oriel.lifecycle`](modules.md) events on the main thread.
- `oriel.extensions.declared("name")` is a comptime check for code shared
  by builds that declare different sets.

## The page

The page never calls an extension directly. Write a command that does, or
expose chosen methods in setup:

```zig
fn checkVision(req: *oriel.extensions.PageRequest) !void {
    // Validate, rate-limit, rewrite req.input (allocate in req.arena), or refuse.
    if (req.input.len > 1 << 20) return oriel.ipc.fail("image too large", .{});
}

oriel.extensions.expose("pantry.vision", .{
    .methods = &.{ "detect", "status" }, // up to 32
    .filter = checkVision, // optional
    .timeout_ms = 30_000,
});
```

```js
const r = await oriel.extensions.call("pantry.vision", "detect", { image, threshold: 0.25 });
// Unexposed methods reject with "pantry.vision.<method> is not exposed".
// An implementation's failure rejects with "<code>: <message>".
const off = oriel.extensions.on("pantry.vision", (e) => console.log(e.name, e.data));
```

The payload goes to the extension as JSON; a JSON reply comes back parsed
(anything else as a string). Events reach the page as `extension:<name>`
with `{ name, data }` (`data` parsed when it is JSON), queued until the page
listens. The call runs on an IPC worker (the built-in `extensions:call`
command); a page under a capability needs `extensions:call` in its
`commands`. TypeScript: `ExtensionsApi`, `ExtensionEvent` and
`export const extensions` in the generated bindings.

## Desktop (Zig)

```zig
// src/vision_desktop.zig (.desktop = .{ .zig = b.path(...) })
const std = @import("std");
const oriel = @import("oriel");

pub fn call(ctx: *oriel.extensions.Context, method: []const u8, input: []const u8) ![]u8 {
    if (!std.mem.eql(u8, method, "detect")) return ctx.fail("unknown_method", "no method {s}", .{method});
    while (working) {
        if (ctx.isCancelled()) return error.Cancelled;
        ctx.emit("progress", "{\"done\":0.5}");
    }
    return ctx.arena.dupe(u8, "{\"boxes\":[]}"); // ctx.arena: freed after the call
}

pub fn onLoad(ctx: *oriel.extensions.Context) !void {} // optional, on the worker
pub fn onLifecycle(event: oriel.lifecycle.Event) void {} // optional, main thread
```

The module can import `oriel` and the app's `imports`. C libraries go
through it the usual way.

## Android (Kotlin)

```kotlin
package dev.ghostpantry

import dev.oriel.*

class VisionExtension : OrielAppExtension {
    override fun onLoad(ctx: OrielExtensionContext) { /* open sessions */ }

    override fun call(method: String, input: ByteArray, call: OrielCall): ByteArray {
        if (method != "detect") throw OrielExtensionError("unknown_method", "no method $method")
        while (working) {
            if (call.isCancelled) throw OrielExtensionError("cancelled", "")
            call.emit("progress", """{"done":0.5}""".toByteArray())
        }
        return """{"boxes":[]}""".toByteArray()
    }

    override fun onLifecycle(event: String, level: String?) {
        if (event == "memory_pressure" && level == "critical") closeSessions()
    }
}
```

- `call` runs on the extension's worker thread, attached to the VM.
  `OrielExtensionError(code, message)` is a structured failure; any other
  exception becomes `ExtensionFailed` with its class name and message.
- `OrielCall` and `OrielExtensionContext` carry `isCancelled` (calls only),
  `emit(name, bytes)`, `activity` (the one in front, or null), `context`,
  `filesDir`, `cacheDir` and `runOnUi { }`.
- The class needs a public zero-argument constructor. The generated
  `OrielExtensions` registry constructs it directly (no reflection) and
  build.zig adds a `-keep` rule for it. A class may also implement
  `OrielAndroidHooks` for Activity and WebView events
  ([platform hooks](platform-hooks.md), [Android](android-extensions.md)).
- `.sources` and `.dependencies` join `android.sources` and
  `android.dependencies`; `.assets` go under the APK's assets
  (`context.assets.open("detectors/...")`).

## iOS (Objective-C)

```objc
#import "oriel_extension.h" // src/platform/ios/include, on the include path

@interface GPVisionExtension : NSObject <OrielAppExtension>
@end

@implementation GPVisionExtension
- (nullable NSData *)callMethod:(NSString *)method input:(NSData *)input
                           call:(OrielCall *)call error:(NSError **)error {
    if (call.cancelled) { *error = [NSError errorWithDomain:@"cancelled" code:1 userInfo:nil]; return nil; }
    [call emit:@"progress" data:[@"{\"done\":0.5}" dataUsingEncoding:NSUTF8StringEncoding]];
    return [@"{\"boxes\":[]}" dataUsingEncoding:NSUTF8StringEncoding];
}
// Optional: - (void)load:(OrielExtensionContext *)context;
//           - (void)lifecycle:(NSString *)event level:(nullable NSString *)level;
@end
```

- Sources are compiled by `zig cc -fobjc-arc`; no Xcode project. Oriel
  finds the class with `objc_getClass` and makes one instance at load.
- Calls run on the worker inside an autorelease pool. Fail with an
  `NSError`: the caller gets `ExtensionFailed`, code `<domain>:<code>`,
  message `localizedDescription`. Don't throw Objective-C exceptions; use
  `dispatch_async`/`dispatch_sync` on the main queue for UIKit.
- `OrielExtensionContext` and `OrielCall` are defined by Oriel at run time:
  send them messages, but don't subclass them or use their class objects.

### Swift

`.ios.swift_sources` (opt-in) are compiled by `swiftc` into one object per
extension, with `oriel_swift.h` as the bridging header (it imports
`oriel_extension.h` and `oriel_hooks.h`), and linked with
the Swift runtime of the OS (/usr/lib/swift):

```swift
import Foundation

@objc(GPVisionExtension) // keeps the class name unmangled for objc_getClass
final class GPVisionExtension: NSObject, OrielAppExtension {
    func callMethod(_ method: String, input: Data, call: OrielCall) throws -> Data {
        call.emit("progress", data: Data("{\"done\":0.5}".utf8))
        return Data("{\"boxes\":[]}".utf8)
    }
}
```

`swiftc` is `$SWIFTC`, else `xcrun --find swiftc` on a Mac, else `swiftc`
on `PATH`. It compiles for `arm64-apple-ios15.0` (or the
`-simulator` triples) against the app's SDK:

- **Mac:** Xcode. The SDK comes from `-Dapple_sdk` / `$APPLE_SDK` (the
  `oriel` CLI passes Xcode's).
- **Linux:** the Swift toolchain from swift.org, plus xtool's Darwin SDK
  (`oriel ios setup` with Xcode.xip extracts it into
  `~/.swiftpm/swift-sdks/darwin.artifactbundle`). A Linux `swiftc` has no
  Darwin standard library: Oriel reads it from the bundle's
  `swift-sdk.json` (`swiftResourcesPath`) when the SDK lives in the bundle,
  or from `-Dswift_resource_dir` / `$SWIFT_RESOURCE_DIR`.

A missing `swiftc`, SDK or Darwin standard library is a build error naming
what to install. Apps without Swift sources never need `swiftc`.

**Minimum iOS 18 with Swift.** iOS 18 split the Swift Darwin overlay into
separate libraries (`libswift_errno`, `_math`, …). Apple's linker records the
old `libswiftDarwin` for older deployment targets; Zig's linker records the
new names, which iOS 15–17 don't have. So an app with `.ios.swift_sources`
targets iOS 18 or later: its minimum is raised to 18.0 when the target names
no version, and an explicit lower one (`-Dtarget=aarch64-ios.16.0`) is a
build error. Apps without Swift keep Oriel's iOS 15 minimum.

Swift imports link by themselves: `import CoreML`, `Metal`, `Accelerate`
and the like need no declaration (Oriel links the imported frameworks and
the SDK's Swift overlays, and drops the unused ones with
`dead_strip_dylibs`; [Platform hooks](platform-hooks.md#ios-and-macos)).

## macOS (Objective-C or Swift)

An extension's `.macos` is either a Zig module, as `.desktop`, or native
code that uses the iOS protocol and runtime above (`OrielAppExtension`,
`oriel_extension.h`, one instance per class, calls on the extension's
workers):

```zig
.macos = .{ .objc = .{
    .class = "GPVisionExtension", // or an @objc(GPVisionExtension) Swift class
    .sources = &.{b.path("macos/VisionExtension.m")}, // zig cc -fobjc-arc
    .swift_sources = &.{}, // or Swift instead
    .frameworks = &.{ "Vision", "CoreML" },
    .weak_frameworks = &.{}, // newer than the minimum macOS
} },
// .macos = .{ .zig = b.path("src/vision_desktop.zig") }, // Zig, as .desktop
```

`.macos` overrides `.desktop` on macOS either way. The sources build
against the macOS SDK: `-Dmacos_sdk=<MacOSX.sdk>`, else `$SDKROOT` when it
is a MacOSX SDK, else Xcode's or the Command Line Tools' (`xcrun`), so on a
Mac; without one the build fails naming what to install. Swift compiles for
`arm64-apple-macos15.0` / `x86_64-apple-macos15.0` with the same bridging
header, and raises the app's minimum to macOS 15 (an explicit lower
`-Dtarget=aarch64-macos.14.0` is a build error), for the reason given for
iOS 18 above. `zig build check` compiles no native sources. The class can
also be a platform hook (`.macos.hooks`): one object serves both. The
showcase's `-Dobjc_echo` builds `showcase.echo` this way
(`examples/showcase/extensions/macos/EchoExtension.m`).

## Limits

| | |
|---|---|
| Extensions per app | 64 |
| Name | 64 characters, `[a-z][a-z0-9_]*` joined by dots; `oriel.*` is Oriel's |
| Method | 128 printable ASCII characters |
| Input and reply | `max_bytes` (32 MiB default, 256 MiB at most) |
| Concurrency | 1..8 workers per extension |
| Waiting calls | 32 per extension (`error.Busy` past that) |
| Timeout | 30 s default, 10 min at most |
| Event | name 64 characters, data 1 MiB; 8 queued per extension until listened |
| Error | code 64 bytes, message 1024 bytes |
| Exposed methods | 32 per extension |

Apps that share one Oriel dependency in a build.zig must declare the same
extensions (they share its `oriel` module).

## Oriel's own extensions

Oriel builds some of its modules on the same primitive: `oriel.system_ai`
(`-Dsystem_ai`) is the extension `oriel.system_ai`, with a Kotlin class
(`src/modules/system_ai/OrielSystemAi.kt`, plus its ML Kit dependency) and
a Swift one (`SystemAi.swift`, FoundationModels weak-linked) shipped in
Oriel and added to the app's project only when the module is on. They are
merged before the app's extensions; names starting with `oriel.` are
reserved (declaring or exposing one is a build error), and their events go
to their module (which turns them into callbacks and page events) instead
of `onEvent` and `extension:<name>`. Oriel's Swift counts for the iOS 18
minimum like an app's.

## Example

The showcase's `showcase.echo` (examples/showcase: `src/echo_desktop.zig`,
`extensions/android/EchoExtension.kt`, `extensions/ios/EchoExtension.m`, and
`extensions/ios/SwiftExtension.swift` behind `-Dswift_example`) reverses
text, emits an event, and is exposed to the App tab. `--ui-test extension`
drives it on the desktop.
