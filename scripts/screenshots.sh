#!/usr/bin/env bash
# Regenerate the README screenshots in assets/screenshots/ from the example
# apps, headlessly (private Xvfb + D-Bus via scripts/headless.sh; never the
# real desktop). Build the examples first (`zig build` in each).
# Needs: xdotool, ImageMagick (import, magick), gdbus.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -z "${ORIEL_HEADLESS_INNER:-}" ]; then
    exec "$root/scripts/headless.sh" "$0" "$@"
fi

out="$root/assets/screenshots"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$out"
# Keep app data (notes, logs, WebKit storage) out of the real home.
export XDG_DATA_HOME="$tmp/data" XDG_CONFIG_HOME="$tmp/config" XDG_CACHE_HOME="$tmp/cache"

shot() { import -window root "$tmp/raw.png"; magick "$tmp/raw.png" -trim +repage "$out/$1.png"; }
stop() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# React notes: type a few notes, then toggle "Do not disturb" from the tray.
cd "$root/examples/react"
./zig-out/bin/oriel-react-notes & pid=$!
sleep 4
xdotool windowactivate --sync "$(xdotool search --sync --name 'React notes' | head -1)" 2>/dev/null || true
for note in "Ship Oriel 0.1 with the React example" \
            "Try the tray menu: quick notes and do-not-disturb" \
            "Package as deb, rpm and AppImage"; do
    xdotool type --delay 15 "$note"; xdotool key Return; sleep 0.4
done
gdbus call --session --dest "org.kde.StatusNotifierItem-$pid-1" --object-path /MenuBar \
    --method com.canonical.dbusmenu.Event 3 clicked '<int32 0>' 0 >/dev/null
sleep 1; shot react-notes; stop "$pid"

# Smoke test: every module check plus the in-webview security checks.
cd "$root/examples/smoke"
./zig-out/bin/oriel-smoke & pid=$!
sleep 9; shot smoke; stop "$pid"

# GhostPen Lite.
cd "$root/examples/ghostpen-lite"
./zig-out/bin/ghostpen-lite & pid=$!
sleep 4; shot ghostpen-lite; stop "$pid"

echo "screenshots written to $out"
