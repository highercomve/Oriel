#!/usr/bin/env bash
# Test Windows builds under Wine (Steam's Proton or a system wine), headless,
# in a private prefix under .wine-test/ (git-ignored). Never uses a Steam
# game prefix. See docs/windows-testing.md.
#
#   scripts/wine.sh setup                      # prefix + WebView2 runtime + WebView2Loader.dll (once)
#   scripts/wine.sh loader                     # print the path of WebView2Loader.dll
#   scripts/wine.sh run <app.exe> [args...]    # run headless (Xvfb); SHOT=out.png SHOT_AFTER=20
#   scripts/wine.sh wine <args...>             # wine in the test prefix, headless (e.g. setup.exe /S)
#   scripts/wine.sh kill                       # stop every process in the test prefix
#
# Environment:
#   ORIEL_WINE        wine binary to use (default: newest numbered Proton in a
#                     Steam library, else Experimental/GE, else `wine` from PATH)
#   ORIEL_WINE_DIR    workspace (default: <repo>/.wine-test)
#   WINEDEBUG         default -all; use err+all,fixme-all when debugging
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dir="${ORIEL_WINE_DIR:-$repo/.wine-test}"
export WINEPREFIX="$dir/prefix" WINEARCH=win64 WINEDEBUG="${WINEDEBUG:--all}"
# Keep Wine from adding menu entries / file associations to the real desktop.
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-winemenubuilder.exe=d}"

die() { printf 'wine.sh: %s\n' "$*" >&2; exit 1; }

find_proton() {
    local roots=() vdf lib p
    for vdf in ~/.steam/steam/steamapps/libraryfolders.vdf ~/.local/share/Steam/steamapps/libraryfolders.vdf; do
        [ -f "$vdf" ] || continue
        while IFS= read -r lib; do roots+=("$lib"); done < <(sed -n 's/.*"path"[[:space:]]*"\(.*\)".*/\1/p' "$vdf")
    done
    roots+=(~/.steam/steam ~/.local/share/Steam)
    for lib in "${roots[@]}"; do
        for p in "$lib"/steamapps/common/Proton* "$lib"/compatibilitytools.d/*; do
            if [ -x "$p/files/bin/wine" ]; then printf '%s\n' "$p/files"; fi
        done
    done | sort -uV | awk '/\/Proton [0-9][^/]*\/files$/ { n = $0 } { a = $0 } END { print (n != "" ? n : a) }'
}

# Point PATH/LD_LIBRARY_PATH/WINEDLLPATH at Proton's own libraries.
setup_env() {
    if [ -n "${ORIEL_WINE:-}" ]; then
        wine_bin="$ORIEL_WINE"
    elif p="$(find_proton)" && [ -n "$p" ]; then
        wine_bin="$p/bin/wine"
        export PATH="$p/bin:$PATH"
        export LD_LIBRARY_PATH="$p/lib:$p/lib64:${LD_LIBRARY_PATH:-}"
        export WINEDLLPATH="$p/lib/vkd3d:$p/lib/wine:$p/lib64/wine"
    elif command -v wine >/dev/null; then
        wine_bin="$(command -v wine)"
    else
        die "no Proton in the Steam libraries and no wine on PATH (set ORIEL_WINE)"
    fi
}

# Run a command on a private X display and D-Bus session (headless.sh), or on
# the current one when we are already inside headless.sh (UI-driving scripts).
headless() {
    if [ -n "${ORIEL_HEADLESS_INNER:-}" ]; then
        "$@"
    else
        "$repo/scripts/headless.sh" "$@"
    fi
}

cmd="${1:-}"
[ -n "$cmd" ] || { sed -n '2,17p' "$0"; exit 2; }
shift
setup_env

case "$cmd" in
setup)
    mkdir -p "$dir"
    # WebView2Loader.dll comes from the Microsoft.Web.WebView2 NuGet package.
    if [ ! -f "$dir/webview2/WebView2Loader.dll" ]; then
        mkdir -p "$dir/webview2"
        [ -f "$dir/webview2/wv2.nupkg" ] ||
            curl -fsSL -o "$dir/webview2/wv2.nupkg" https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2
        unzip -o -q "$dir/webview2/wv2.nupkg" 'runtimes/win-x64/native/WebView2Loader.dll' -d "$dir/webview2/pkg"
        cp "$dir/webview2/pkg/runtimes/win-x64/native/WebView2Loader.dll" "$dir/webview2/"
    fi
    [ -d "$WINEPREFIX/drive_c" ] || headless "$wine_bin" wineboot -i
    if ! compgen -G "$WINEPREFIX/drive_c/Program Files (x86)/Microsoft/EdgeWebView/Application/*/msedgewebview2.exe" >/dev/null; then
        # The standalone (offline) x64 Evergreen installer, ~200 MB, cached.
        [ -f "$dir/wv2-installer.exe" ] ||
            curl -fsSL -o "$dir/wv2-installer.exe" 'https://go.microsoft.com/fwlink/?linkid=2124701'
        headless timeout 900 "$wine_bin" "$dir/wv2-installer.exe" /silent /install || die "WebView2 installer failed ($?)"
        "$wine_bin" wineserver -w || true
    fi
    echo "wine:    $wine_bin"
    echo "prefix:  $WINEPREFIX"
    echo "loader:  $dir/webview2/WebView2Loader.dll"
    ls -d "$WINEPREFIX/drive_c/Program Files (x86)/Microsoft/EdgeWebView/Application/"*/ 2>/dev/null | grep '/[0-9][0-9.]*/$' | sed 's#.*/Application/#webview2: #'
    ;;
loader)
    [ -f "$dir/webview2/WebView2Loader.dll" ] || die "run 'scripts/wine.sh setup' first"
    echo "$dir/webview2/WebView2Loader.dll"
    ;;
run)
    [ $# -ge 1 ] || die "usage: scripts/wine.sh run <app.exe> [args...]"
    [ -d "$WINEPREFIX/drive_c" ] || die "run 'scripts/wine.sh setup' first"
    exe="$(realpath "$1")"; shift
    # Run from the exe's directory: WebView2Loader.dll must sit next to it.
    cd "$(dirname "$exe")"
    SHOT_AFTER="${SHOT_AFTER:-20}" headless "$wine_bin" "$exe" "$@" || rc=$?
    "$wine_bin" wineserver -k 2>/dev/null || true
    exit "${rc:-0}"
    ;;
wine)
    # Headless too: installers and uninstallers open (hidden) windows.
    headless "$wine_bin" "$@" || rc=$?
    "$wine_bin" wineserver -w 2>/dev/null || true
    exit "${rc:-0}"
    ;;
kill)
    "$wine_bin" wineserver -k 2>/dev/null || true
    ;;
*)
    die "unknown command '$cmd' (setup, loader, run, wine, kill)"
    ;;
esac
