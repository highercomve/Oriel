<!-- Generated from site/content/docs/wrap.smd by tools/docs/gen-md.mjs: edit that file. -->

# Wrap a web app

Turn a website into a desktop app with oriel wrap: an editable Oriel project with a tray icon and AppImage packaging.

`oriel wrap <url>` creates an editable Oriel project that opens a website
in a desktop window, in the spirit of [Pake](https://github.com/tw93/Pake).
The app uses the system web view (WebKitGTK on Linux, WebView2 on Windows,
WKWebView on macOS) instead of bundling a browser, so a release AppImage is
a few megabytes. It loads the live website: it needs the same network
access and account as the browser version.

Use `wrap` for a site you don't control or don't want to rebuild. For an app
with its own frontend, use [`oriel init`](getting-started.md#create-an-app).

## Create and run

First [install the CLI](getting-started.md#install-the-cli)
and run `oriel doctor --fix`. Wrapped apps need no Node.js or npm: their
frontend is a static loading page.

```sh
oriel wrap https://web.whatsapp.com --name whatsapp --title "WhatsApp"
cd whatsapp
oriel run
```

The command creates `./whatsapp`, adds Oriel as a dependency and fetches
the Zig dependencies. Without `--name` it derives a name from the URL's
host (skipping parts like `www`, `web`, `app` and the top-level domain);
without `https://` it adds it. The directory must be new or empty.

To launch right after creating the project:

```sh
oriel wrap https://example.com --name example --run
```

## Tray and window behavior

The [tray](tray.md) is on by default. Its menu has
**Show / Hide** and **Quit**; closing the window hides it while the app
keeps running (the main window's `hide_on_close`). Choose Quit to exit.

`--no-tray` makes an app that exits when its window closes:

```sh
oriel wrap https://example.com --name example --no-tray
```

On Linux the desktop needs a tray host to show the icon; `oriel doctor`
says whether there is one.

## Which sites the app may use

The app may navigate to, and give the page's [capabilities](security.md)
to, the URL's exact origin (`https://<host>`) only. Links to other sites
open in the default browser. `--allow-subdomains` also allows
`https://*.<host>` (a leading `www.` dropped), for sites that log in or
serve from subdomains:

```sh
oriel wrap https://www.example.com --allow-subdomains   # allows https://*.example.com
```

A WhatsApp URL also gets `https://*.whatsapp.com` and
`https://*.whatsapp.net`. No wildcard is ever derived from the last two
labels of a host, which would turn `foo.co.uk` into `*.co.uk`. For other
login or service domains, add them to `allowed_origins` and `capabilities`
in `src/main.zig`.

The generated app declares the notification and microphone
[permissions](permissions.md), so the allowed origins can
ask for them; the operating system and the web view still decide whether to
grant access.

## Icon and browser identity

`--icon ./icon.png` uses a local PNG. Otherwise Oriel fetches the site's
favicon (Google's favicon service at 256×256, then DuckDuckGo) and falls
back to its own icon. If the `--icon` path doesn't exist, the fetched
favicon is also saved there. The project keeps its icon in
`assets/icon.png`, used for the window, the tray, the `.desktop` entry and
the packages.

Some sites need a particular browser identity. `--user-agent chrome`,
`safari`, `firefox` or a quoted custom string sets the web view's user
agent. It takes effect on **Linux** only; Windows and macOS keep the web
view's own. A WhatsApp URL selects `chrome` when the option is omitted.
Changing the user agent doesn't change the web view's engine or features.

## Package on Linux

One command creates the project and a ReleaseSafe AppImage:

```sh
oriel wrap https://web.whatsapp.com \
  --name whatsapp \
  --title "WhatsApp" \
  --id com.whatsapp.desktop \
  --user-agent chrome \
  --package
```

The output is in `whatsapp/zig-out/package/`. `--package` runs the
`package-appimage` build step. The AppImage uses the host's GTK 4 and
WebKitGTK 6.0 libraries; it doesn't bundle them.

For an existing project:

```sh
cd whatsapp
oriel package
```

The generated `build.zig` packages `.appimage` only. For Windows or macOS,
change `.package.formats` and follow [Packaging](packaging.md)
and [Signing](signing.md).

## Options

| Option | Meaning |
|---|---|
| `<url>` | Website to open; `https://` is added if omitted |
| `--name <name>` | Project directory and executable name: starts with a letter; letters, digits, `-` and `_`; at most 32 characters |
| `--title <title>` | Window title and package display name (default: from the name) |
| `--id <app-id>` | Application id in reverse-DNS form (default: `com.example.<Name>`; `com.whatsapp.desktop` for WhatsApp) |
| `--icon <path>` | Local PNG, or where to save the fetched favicon if the file is missing |
| `--tray` / `--no-tray` | Tray icon and close-to-tray (default: on) / none |
| `--user-agent <ua>` | `chrome`, `safari`, `firefox` or a custom string (Linux) |
| `--allow-subdomains` | Also allow `https://*.<host>` |
| `--devtools` | Enable the web developer tools and forward console messages to stdout |
| `--package` | Build a ReleaseSafe Linux AppImage after creating the project |
| `--run` | Build and run after creating the project |
| `--oriel-ref <ref>` | Oriel tag or commit to depend on (default: the one the CLI was built for) |
| `--oriel-path <dir>` | Depend on a local Oriel checkout |

`oriel wrap --help` lists the installed CLI's options.

## The generated project

The project is ordinary Oriel source to edit and rebuild:

| File | What to change |
|---|---|
| `src/main.zig` | URL, window size, tray menu, user agent, allowed origins and capabilities |
| `build.zig` | Enabled modules, permissions, package metadata and formats |
| `build.zig.zon` | The Oriel dependency |
| `assets/icon.png` | App icon |
| `frontend/index.html` | The loading page embedded in the app |

`src/main.zig` passes the build's declarations (`oriel_app.build`) and opens
the site in the main window:

```zig
pub fn main(init: std.process.Init) !u8 {
    return oriel.main(init, .{ .commands = struct {} }, .{
        .app = app.build, // id, icon, permissions, the loading page
        .window = .{
            .title = "WhatsApp",
            .width = 1100,
            .height = 750,
            .url = "https://web.whatsapp.com",
            .hide_on_close = true, // with the tray
        },
        .user_agent = "Mozilla/5.0 (X11; Linux x86_64) ...",
        .devtools = false,
        .setup = setup, // creates the tray icon
        .security = .{
            .csp = null,
            .allowed_origins = &.{"https://web.whatsapp.com", "https://*.whatsapp.net", "https://*.whatsapp.com"},
            .capabilities = &.{ .{ .origin = "https://web.whatsapp.com" }, ... },
            .external_links = .open_in_browser,
        },
    });
}
```

From here it is a normal Oriel app: add [commands](commands.md),
turn on [modules](modules.md), or build it for
[Android](android.md) (the tray block is guarded with
`oriel.tray.available` and drops out on phones).

## Troubleshooting

- **The site shows a "browser not supported" page.** Try
  `--user-agent chrome` (Linux), or set `.user_agent` in `src/main.zig`.
- **Logging in opens the browser.** The login page is on another origin:
  add it to `allowed_origins`, or rebuild with `--allow-subdomains` if it is
  a subdomain.
- **High CPU on Linux with NVIDIA's driver.** Every Oriel app sets
  `WEBKIT_DISABLE_DMABUF_RENDERER=1` when `/proc/driver/nvidia` exists, which
  avoids WebKitGTK's DMABUF busy loop; set it yourself if the driver lives
  elsewhere.
- **No tray icon on Linux.** The desktop has no StatusNotifierItem host;
  `oriel doctor` reports it.

## Related

- [Getting started](getting-started.md): the CLI and an app with its own frontend.
- [Security](security.md): allowed origins, capabilities and external links.
- [CLI](cli.md): every command.
