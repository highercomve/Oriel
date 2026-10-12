#!/usr/bin/env bash
# Module availability per target (docs/modules.md, "Availability"):
# - an app's flags are intent: scripts/availability asks for desktop-only
#   modules and type-checks for phones too, with `oriel.<m>.available` false;
# - a use outside `if (oriel.tray.available)` is a build error naming it;
# - on Oriel's own command line, -Dtray=true for iOS is a build error.
#
#   scripts/test-availability.sh
set -euo pipefail
cd "$(dirname "$0")/.."
log=$(mktemp)
trap 'rm -f "$log"' EXIT

fail() { echo "FAIL: $*"; cat "$log"; exit 1; }
expect_error() { # <message> <dir> <zig build args...>
    local msg=$1 dir=$2
    shift 2
    if (cd "$dir" && zig build "$@") >"$log" 2>&1; then fail "expected an error: zig build $*"; fi
    grep -qF -- "$msg" "$log" || fail "expected \"$msg\": zig build $*"
    echo "ok (fails as expected): $dir: zig build $*"
}

expect_error "-Dtray is not available on ios" . check -Dtarget=aarch64-ios -Dsql=false -Dtray=true
expect_error "-Dsystem_ai is not available on windows" . check -Dtarget=x86_64-windows -Dsystem_ai=true
for t in native aarch64-ios aarch64-ios-simulator aarch64-linux-android x86_64-windows; do
    (cd scripts/availability && zig build check "-Dtarget=$t") >"$log" 2>&1 || fail "scripts/availability: zig build check -Dtarget=$t"
    echo "ok: scripts/availability: zig build check -Dtarget=$t"
done
expect_error "oriel.tray.Tray is not available on ios: guard the call with" scripts/availability check -Dtarget=aarch64-ios -Dunguarded=true
expect_error "oriel.tray.Tray is not available on android" scripts/availability check -Dtarget=aarch64-linux-android -Dunguarded=true
