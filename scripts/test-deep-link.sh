#!/usr/bin/env bash
# Deep links on Linux with examples/showcase (oriel-showcase://note/<text>
# adds a note): the CLI's register/unregister, delivery to a running
# instance, and a cold start. Build the CLI and the showcase first.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_XDG="$(mktemp -d /tmp/oriel-xdg-XXXXXX)"
cleanup() {
    rm -rf "$TEMP_XDG"
}
trap cleanup EXIT

export XDG_DATA_HOME="$TEMP_XDG/data"
export XDG_CONFIG_HOME="$TEMP_XDG/config"
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME"

echo "=== 1. Testing CLI deep-link register/unregister in temporary XDG directory ==="
cd "$REPO_ROOT/examples/showcase"

# Register
"$REPO_ROOT/zig-out/bin/oriel" deep-link register
DESKTOP_FILE="$XDG_DATA_HOME/applications/dev.oriel.Showcase.desktop"
if [ ! -f "$DESKTOP_FILE" ]; then
    echo "ERROR: Desktop file $DESKTOP_FILE was not created!"
    exit 1
fi
echo "Desktop file created: $DESKTOP_FILE"
grep -q "Exec=.* %u" "$DESKTOP_FILE" || { echo "ERROR: Exec line missing %u"; exit 1; }
grep -q "MimeType=.*x-scheme-handler/oriel-showcase" "$DESKTOP_FILE" || { echo "ERROR: MimeType line missing oriel-showcase"; exit 1; }
echo "Desktop file contents verified."

# Unregister
"$REPO_ROOT/zig-out/bin/oriel" deep-link unregister
if [ -f "$DESKTOP_FILE" ]; then
    echo "ERROR: Desktop file $DESKTOP_FILE still exists after unregister!"
    exit 1
fi
echo "Unregister removed desktop file successfully."

# Re-register for testing
"$REPO_ROOT/zig-out/bin/oriel" deep-link register
echo "Re-registered."

echo "=== 2. Testing Secondary Instance Deep Link Delivery to Running App ==="
LOG_FILE="/tmp/showcase-primary.log"
rm -f "$LOG_FILE"

"$REPO_ROOT/examples/showcase/zig-out/bin/oriel-showcase" > "$LOG_FILE" 2>&1 &
PRIMARY_PID=$!
echo "Primary instance launched with PID $PRIMARY_PID"

sleep 3

# Send deep link via secondary instance
echo "Launching secondary instance with deep link URL..."
"$REPO_ROOT/examples/showcase/zig-out/bin/oriel-showcase" "oriel-showcase://note/Hello%20From%20Deep%20Link"
SECOND_EXIT=$?
echo "Secondary instance exited with code $SECOND_EXIT"

sleep 2

# Take screenshot to verify UI rendering
import -window root /tmp/showcase-deep-link.png
echo "Screenshot saved to /tmp/showcase-deep-link.png"

# Kill primary instance
kill -TERM "$PRIMARY_PID" 2>/dev/null || kill -KILL "$PRIMARY_PID" 2>/dev/null || true
wait "$PRIMARY_PID" 2>/dev/null || true

echo "=== Primary Instance Log ==="
cat "$LOG_FILE"

# Verify log has deep link added note
if grep -q "deep link added note: 'Hello From Deep Link'" "$LOG_FILE"; then
    echo "SUCCESS: Note 'Hello From Deep Link' was added to primary instance via deep link!"
else
    echo "ERROR: Note was not added!"
    exit 1
fi


echo "=== 3. Testing Cold Start Deep Link Delivery ==="
COLD_LOG="/tmp/showcase-cold.log"
rm -f "$COLD_LOG"

"$REPO_ROOT/examples/showcase/zig-out/bin/oriel-showcase" "oriel-showcase://note/Cold%20Start%20Note" > "$COLD_LOG" 2>&1 &
COLD_PID=$!
echo "Cold start launched with PID $COLD_PID"

sleep 3
import -window root /tmp/showcase-cold.png
echo "Cold start screenshot saved to /tmp/showcase-cold.png"

kill -TERM "$COLD_PID" 2>/dev/null || kill -KILL "$COLD_PID" 2>/dev/null || true
wait "$COLD_PID" 2>/dev/null || true

echo "=== Cold Start Log ==="
cat "$COLD_LOG"

if grep -q "deep link added note: 'Cold Start Note'" "$COLD_LOG"; then
    echo "SUCCESS: Cold start note 'Cold Start Note' was added via deep link!"
else
    echo "ERROR: Cold start note was not added!"
    exit 1
fi


echo "ALL LINUX DEEP LINK TESTS PASSED!"
