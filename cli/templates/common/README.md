# @@title@@

A desktop app built with [Oriel](https://github.com/highercomve/Oriel): Zig
and the system webview (WebKitGTK on Linux, WebView2 on Windows, WKWebView on macOS), with a @@frontend_desc@@
frontend.

## Develop

```sh
@@commands@@
```

Each command is a thin wrapper around `zig build <step>` (run from anywhere
inside the project; extra arguments are passed on), so plain `zig build ...`
works as well. `oriel doctor` checks that the system has everything needed.

## Layout

| Path | What |
|---|---|
| `src/main.zig` | The Zig side: `Commands` the page can call and `Events` pushed to it |
| `frontend/` | The page: @@frontend_desc@@ |
| `build.zig` | Which Oriel modules are compiled in, packaging metadata |
| `build.zig.zon` | Package manifest; Oriel is a dependency |
| `src/android/` (optional) | App-owned Kotlin/Java helpers and `OrielAndroidExtension` implementations |
| `android/` (generated for Android builds) | Gradle project and Oriel runtime |

## Calling Zig from the page

@@calling@@

A command is any `pub fn` in `Commands`; its arguments struct and return type
become the JSON on the JavaScript side. Events declared in `Events` are sent
with `events.emit(.name, payload)` from any thread.

## Android extensions

For native Android behavior, keep Kotlin or Java implementations in your own
sources and register them in `build.zig`:

```zig
.android = .{
    .sources = &.{b.path("src/android/MyExtension.kt")},
    .extensions = &.{"dev.example.MyExtension"},
},
```

The class implements `dev.oriel.OrielAndroidExtension` and needs a public
zero-argument constructor. Oriel generates `OrielAppExtensions.kt` on each
Android build to dispatch lifecycle, WebView, native-result, permission, and
file-picker hooks. Edit your source and build configuration to change behavior.
`.android.dependencies` adds pinned Maven SDKs, and `.android.proguard_rules`
adds R8 rules for JNI calls.

See the [Android extensions guide](https://highercomve.github.io/Oriel/docs/android-extensions/)
for a complete implementation and request-code allocation.
