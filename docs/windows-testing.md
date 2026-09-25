# Testing Windows builds on Linux (Wine / Proton)

Windows builds cross-compile from Linux (`-Dtarget=x86_64-windows`) and run
under Wine well enough to test most of Oriel: Win32 windows and menus,
WebView2 (the real Edge runtime), IPC, the embedded assets, SQLite, the store,
the tray icon, fs_watch, clipboard, the NSIS installer. `scripts/wine.sh` does
it headlessly, in a private prefix, using Steam's Proton if it is installed
(or `wine` from `PATH`).

Wine is not Windows. A pass here means "the Win32/COM/WebView2 code works";
it doesn't cover GPU/compositor behaviour, DPI scaling, SmartScreen,
Defender, code signing, real Explorer shell integration (tray overflow, toast
notifications, Start Menu search) or timing differences. Test those on a real
Windows machine before a release.

## One-time setup

```sh
scripts/wine.sh setup
```

Creates `.wine-test/` in the repo (git-ignored, ~2 GB): a Wine prefix, the
WebView2 Evergreen runtime installed into it (standalone installer, cached),
and `WebView2Loader.dll` from the `Microsoft.Web.WebView2` NuGet package.
Safe to re-run; it only does what is missing. Delete `.wine-test/` to start
over.

Never point it at a Steam game's prefix (`steamapps/compatdata/*`): the prefix
is always `.wine-test/prefix` unless `ORIEL_WINE_DIR` says otherwise.

## Build, run, screenshot

```sh
cd examples/smoke
zig build -Dtarget=x86_64-windows -Dwebview2-loader=$(../../scripts/wine.sh loader) -p ../../.wine-test/smoke
cd ../..

# The in-webview checks (the Windows equivalent of headless.sh --auto-quit):
timeout 180 scripts/wine.sh run .wine-test/smoke/bin/oriel-smoke.exe --auto-quit 2>&1 | grep -E '^\[(ok|FAIL)\]'

# Any app, with a screenshot after SHOT_AFTER seconds (default 20):
SHOT=.wine-test/react.png scripts/wine.sh run .wine-test/react/bin/oriel-react-notes.exe
```

Build into `.wine-test/<app>` (`-p`), not the example's `zig-out/`, so the
Linux build there is left alone. `WebView2Loader.dll` must end up next to the
exe; `-Dwebview2-loader` does that.

Output goes to stdout/stderr (the app's `std.log` and Zig panics with stack
traces). `WINEDEBUG=err+all,fixme-all` adds Wine's own errors when something
fails inside Wine.

## Installer

```sh
cd examples/react
zig build package -Dtarget=x86_64-windows -Dwebview2-loader=$(../../scripts/wine.sh loader) -p ../../.wine-test/react-pkg
cd ../..
scripts/wine.sh wine .wine-test/react-pkg/package/*-setup.exe /S; echo rc=$?
ls ".wine-test/prefix/drive_c/users/steamuser/AppData/Local/Programs/"        # installed app
ls ".wine-test/prefix/drive_c/users/steamuser/AppData/Roaming/Microsoft/Windows/Start Menu/Programs/"
```

(`steamuser` with Proton; your login name with a system wine.) Run
`Uninstall.exe /S` the same way to test uninstalling.

## Driving the UI

Run a script through `scripts/headless.sh`; inside it, `scripts/wine.sh`
uses that same private display instead of starting another one, so
`xdotool` and `import` see the app:

```sh
cat > .wine-test/drive.sh <<'SH'
#!/bin/bash
scripts/wine.sh wine .wine-test/react/bin/oriel-react-notes.exe &
sleep 20
win=$(xdotool search --name "React notes" | head -1)
eval "$(xdotool getwindowgeometry --shell "$win")"      # X Y WIDTH HEIGHT
xdotool mousemove $((X+300)) $((Y+112)) click 1
xdotool type --delay 30 "hello from wine"; xdotool key Return; sleep 1
import -window root .wine-test/drive.png
scripts/wine.sh kill
SH
chmod +x .wine-test/drive.sh && scripts/headless.sh .wine-test/drive.sh
```

Click positions are relative to the window; find them from a screenshot
first. Prefer checks in `examples/smoke` (they run the same on Linux and
Windows) over pixel-driven scripts.

## What to expect

Known Wine gaps, not Oriel bugs:

- `Application could not be started…` / `ShellExecuteEx failed: File not
  found`: Wine trying to start `winemenubuilder`, which `wine.sh` disables so
  installers can't add entries to your real desktop menu. Harmless.
- `X connection to :N broken` at exit: Xvfb going away. Harmless.
- Opening external URLs does nothing: the prefix has no browser.
- Balloon notifications and tray menus exist but nothing shows them (no
  Explorer shell).
- The first start after `setup` is slow (~20 s) while Wine and WebView2
  initialise; later starts are faster.
- Wine has no `ProcessPrng`, Zig's secure random source on Windows; Oriel
  falls back to `RtlGenRandom` for the IPC token (without any secure source it
  would disable IPC).
- Smoke baseline (2026-09-25): 47/50. The known failures are `media_server`,
  `nav iframe` and `ipc frame`: the last two load pages from local HTTP
  servers, which Wine's networking doesn't serve here. All three pass on real
  Windows.

Results the first time this ran (2026-09-24, Proton 11.0, WebView2
153.0.4234.48, smoke `--auto-quit` from main):

- ok: tray, updater, sql, fs_watch, dialog, notification, store, menu,
  global_shortcut, input, clipboard, webview→media (app:// page), media audio
  seek, ipc greet.
- FAIL: `media_server` (Unexpected), `media range tcp` / `media range app://`
  (Failed to fetch), one `ipc` check (UnknownField); httpz then panicked in
  `windows.recv` (`reached unreachable code`, `Failed to accept socket:
  error.Unexpected`). Real Windows bugs to fix, not Wine gaps.
