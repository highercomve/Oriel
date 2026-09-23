#!/usr/bin/env bash
# Run a GUI command on a private X display (Xvfb) and a private D-Bus session,
# so GUI tests never touch the real desktop: no windows, no tray icons, no
# single-instance handoff to a running copy of the app.
#
#   scripts/headless.sh ./zig-out/bin/ziguri-smoke --auto-quit
#   SHOT=out.png SHOT_AFTER=4 scripts/headless.sh ./zig-out/bin/my-app
#
# With SHOT set, the command runs for SHOT_AFTER seconds (default 4), the
# screen is saved to SHOT (needs ImageMagick's `import`), then it is stopped.
# Requires: Xvfb (xvfb-run), dbus-run-session.
set -euo pipefail

if [ -z "${ZIGURI_HEADLESS_INNER:-}" ]; then
    exec env -u WAYLAND_DISPLAY -u DISPLAY GDK_BACKEND=x11 NO_AT_BRIDGE=1 GTK_A11Y=none \
        ZIGURI_HEADLESS_INNER=1 \
        dbus-run-session -- xvfb-run -a -s "-screen 0 1024x768x24" "$0" "$@"
fi

if [ -z "${SHOT:-}" ]; then
    exec "$@"
fi

"$@" &
pid=$!
sleep "${SHOT_AFTER:-4}"
import -window root "$SHOT"
kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
