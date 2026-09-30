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

# The showcase: add a few notes on the Notes tab.
cd "$root/examples/showcase"
./zig-out/bin/oriel-showcase & pid=$!
sleep 5
xdotool windowactivate --sync "$(xdotool search --sync --name 'Oriel Showcase' | head -1)" 2>/dev/null || true
xdotool key ctrl+2; sleep 0.6
for note in "Ship the showcase on five platforms" \
            "Dictate anywhere with Ctrl+Alt+D" \
            "Package as deb, rpm and AppImage"; do
    xdotool type --delay 15 "$note"; xdotool key Return; sleep 0.4
done
sleep 1; shot showcase; stop "$pid"

# Smoke test: every module check plus the in-webview security checks.
cd "$root/examples/smoke"
./zig-out/bin/oriel-smoke & pid=$!
sleep 9; shot smoke; stop "$pid"

echo "screenshots written to $out"
