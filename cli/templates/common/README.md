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

## Calling Zig from the page

@@calling@@

A command is any `pub fn` in `Commands`; its arguments struct and return type
become the JSON on the JavaScript side. Events declared in `Events` are sent
with `events.emit(.name, payload)` from any thread.
