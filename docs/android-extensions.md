# Android platform hooks

[Back to Oriel](../README.md) · [Documentation](README.md) · [Android](android.md) · [Platform hooks](platform-hooks.md)

Android platform hooks let app-owned Kotlin or Java code react to, and take
over, the Android app's own events without editing Oriel's generated Kotlin
runtime. Hooks can configure WebViews, react to Activity and WebView
lifecycles, launch native workflows, handle permissions and activity results,
and intercept file selection. The API is independent of any particular app,
camera implementation, or third-party SDK. This is the Android part of
[platform hooks](platform-hooks.md); iOS and macOS have Objective-C/Swift hooks, and Linux,
Windows and macOS have `oriel.hooks` in Zig.

`OrielAndroidHooks` is the public interface your Kotlin class implements
(declared in `.android.hooks`). It is a Kotlin `typealias` of
`OrielAndroidExtension`, the interface's name before Oriel 0.11, which keeps
working and is the name Java classes implement; `OrielAndroidHooksContext`
is likewise `OrielAndroidExtensionContext`. `OrielAppExtensions` is Oriel's
internal, generated registry: it constructs the registered classes and
dispatches their callbacks. Configure registration in `build.zig`; edits to
the generated `OrielAppExtensions.kt` are overwritten on the next Android
build.

To call your own native code from Zig (and, through Zig, from the page) on
every platform, use [app extensions](extensions.md) (`AppOptions.extensions`,
`OrielAppExtension`): Oriel handles the JNI transport, threads,
cancellation and keep rules, with Objective-C/Swift and Zig counterparts on
iOS and the desktop. Keep platform hooks for Activity and WebView events;
one class may implement both interfaces.

## Register a hook class

Keep the implementation outside the generated `android/app/src/main/java/`
directory, for example in `src/android/MyHooks.kt`:

```kotlin
package dev.example

import android.webkit.WebView
import dev.oriel.OrielAndroidHooks

class MyHooks : OrielAndroidHooks {
    override fun onWebViewCreated(view: WebView, windowLabel: String) {
        // Apply an app-specific setting after Oriel installs its clients and
        // bridge, before the page loads. Other windows can use other settings.
        if (windowLabel == "main") view.settings.textZoom = 110
    }
}
```

Register the source and fully qualified class in `build.zig`:

```zig
_ = oriel.addApp(b, dep, .{
    .name = "my-app",
    .root_source_file = b.path("src/main.zig"),
    .android = .{
        .sources = &.{b.path("src/android/MyHooks.kt")},
        .hooks = &.{"dev.example.MyHooks"},
    },
});
```

A registered class must implement `OrielAndroidHooks` (or, in Java,
`OrielAndroidExtension`) and have a public zero-argument constructor.
Register multiple classes in the order they should run. Duplicate
registrations, invalid class names, and more than 64 classes are rejected by
the build.

`.android.extensions` is the deprecated name of `.android.hooks` and still
works: its classes are registered after the `.android.hooks` classes, and a
class named in both lists is registered once, in its `.hooks` position. Kotlin compilation checks the interface and
constructor; registration uses direct constructor calls, not reflection, so
R8 can follow those references.

Every Android build copies the listed sources and regenerates
`dev/oriel/OrielAppExtensions.kt`. Removing a registration removes its wiring;
removing a source removes its generated copy. The original source remains
owned by the developer. Each source needs a `package` declaration, which
selects its destination under `app/src/main/java/`. Listing a source does not
register it as a hook: both `.sources` and `.hooks` are needed for an
app-owned implementation. A class supplied by a Maven SDK can instead come
from `.dependencies`.

Normal builds keep developer manifest entries outside
Oriel's generated regions. Add custom Activities, providers, or services there,
and declare extra permissions with `.android.permissions` or the appropriate
`.permissions` kind. `-Dandroid_force=true` intentionally rewrites developer
project files from the template; it is not needed to update hooks.

## Lifecycle and WebView hooks

Hook instances are created once per process. Callbacks run on the UI
thread, in registration order. Activity creation/start/resume/pause/stop/destroy,
new intents, saved instance state, and configuration changes are available.
WebView creation, attachment, detachment, and destruction callbacks include the
window label. Activity and WebView lifetimes differ: a WebView can survive an
Activity, and a renderer crash creates a new WebView for the same window.

Keep state per Activity or WebView instead of retaining one global host. Release
callbacks, URI grants, listeners, and other resources in the appropriate cleanup
hook. Constructors and `onRegistered` must not assume an Activity exists. Preserve
Oriel's clients, JavaScript bridge, and navigation restrictions; use the provided
hooks to intercept behavior instead of replacing `webViewClient` or
`webChromeClient`. WebView hooks are not called for the native UI renderer.

## Native requests without request-code collisions

`onRegistered` supplies an `OrielAndroidHooksContext` (`OrielAndroidExtensionContext`).
Allocate local codes from 0 through 255; Oriel assigns each hook class a
separate namespace:

```kotlin
private lateinit var context: OrielAndroidHooksContext

override fun onRegistered(context: OrielAndroidHooksContext) {
    this.context = context
}

// When handling an app action:
// activity.startActivityForResult(intent, context.requestCode(1))
// activity.requestPermissions(arrayOf(permission), context.requestCode(2))
```

Oriel routes results for those codes directly to the owning hook class. The
callback receives the full allocated code, not the local `0..255` value.
Compare it with the same `context.requestCode(...)` used to launch the request:

```kotlin
override fun onActivityResult(
    activity: android.app.Activity,
    requestCode: Int,
    resultCode: Int,
    data: android.content.Intent?,
): Boolean {
    if (requestCode != context.requestCode(1)) return false
    // Complete the workflow, including cancellation, using resultCode/data.
    return true
}
```

Return `true` from `onActivityResult` or `onRequestPermissionsResult` when
handled.
Keep `0x4E00..0x4FFF` for Oriel: permission requests use `0x4E00` plus the
permission kind and `0x4E80`; Activity workflows use `0x4Fxx`. Return `false`
for Oriel's permission results so its permission handler receives them.
For third-party SDKs with fixed codes, use codes outside those ranges and the
hook-managed range (`0x8000..0xBFFF`). Results outside the managed range
visit hook classes in declaration order until one returns `true`; unhandled
activity results reach the Activity superclass. Unhandled permission results
reach Oriel's permission handler, which ignores codes outside its own range.

## Intercept file selection

Override `onShowFileChooser(activity, view, callback, params)` to provide a
custom picker, capture workflow, or document SDK. Return `false` without touching
the callback to let the next hook class, then Oriel's built-in picker, handle it.
Return `true` to take ownership and complete the callback exactly once with the
selected URI array, or `null` for cancellation/failure. Clean up an outstanding
callback when its Activity or WebView is destroyed. Honour the supplied accept
types, capture flag and selection mode; do not request unrelated permissions.

Apps don't need their own camera hook: since Oriel 0.10, with the camera
module on (`.permissions.camera` in `build.zig`, see [the camera module](modules.md#camera-orielcamera)),
`oriel.camera` handles `<input type="file" accept="image/*">` itself. With
`capture` it asks for `CAMERA` and opens the camera app writing into Oriel's
own capture provider (`<app id>.oriel.capture`); without it, the system photo
picker. Pictures the WebView can't decode (HEIC, AVIF) are transcoded to JPEG.
A hook that returns `true` from `onShowFileChooser` still sees every chooser
first, so the route below is only for apps that need their own capture flow
(a document scanner, a vendor SDK).

Files picked for an input arrive as `content://` URIs; the WebView uploads them
with `allowContentAccess` left off (Oriel's default), which only governs pages
loading `content://` URLs. A custom capture flow can use an app-owned content
provider with a scoped URI write grant and `MediaStore.EXTRA_OUTPUT`; the
activity-result hook can return that URI even when Android returns a null
result Intent.

## Third-party SDK dependencies

Declare pinned Maven coordinates in the same build configuration as the hooks:

```zig
.android = .{
    .sources = &.{b.path("src/android/MyHooks.kt")},
    .hooks = &.{"dev.example.MyHooks"},
    .dependencies = &.{"com.example:example-sdk:1.2.3"},
    .proguard_rules = b.path("src/android/proguard-rules.pro"),
},
```

Every build writes `app/oriel-dependencies.gradle` and maintains its
`apply(from = ...)` line between `// oriel:dependencies` markers in
`app/build.gradle.kts`. Manual Gradle dependencies and settings outside the
markers are preserved. Removing a coordinate removes it from the generated
script. Full project regeneration installs the same dependencies automatically.
Coordinates accept exactly `group:artifact:version`, with letters, digits,
dots, underscores, and hyphens; other syntax, including `+` and bracketed
version ranges, is rejected. Choose a fixed release version: validation does
not reject dynamic names such as `latest.release` or changing `-SNAPSHOT`
versions.
The project must still configure repositories and a Kotlin/AGP toolchain
compatible with the SDK. New projects use Kotlin 2.3.21 and AGP 8.13.2; existing
projects keep their developer-owned Gradle files and may need an explicit
upgrade. Native methods called through JNI need app-owned R8 keep rules,
because shrinking cannot infer those calls from Zig. `.proguard_rules` updates
only the region between `# oriel:proguard` markers in
`android/app/proguard-rules.pro`; manual rules outside it are preserved.

## Vendor native libraries

Some Android SDKs load optional device/vendor libraries, such as a GPU driver.
Declare these in `build.zig` alongside their SDK dependencies:

```zig
.android = .{
    .native_libraries = &.{
        .{ .name = "libOpenCL.so" },
        .{ .name = "libvndksupport.so" },
    },
},
```

Oriel regenerates `<uses-native-library>` entries in the manifest's managed
application components on every build. `required` defaults to `false`, so a
missing vendor library does not prevent installation; the SDK should check
backend support at runtime. Set `required = true` only when installation must
require the library. Repeated names merge their requirements. Names are checked
for XML safety and at most 64 declarations are accepted. Developer declarations
outside the managed region are preserved and take precedence by library name.
Removing a declaration removes its generated entry on the next build.
