#!/usr/bin/env bash
# The native renderer's tree for a test page, built with the runtime as it is
# now and as it was at a git ref (default HEAD), compared after each step of
# page.py: a flattener change must make the same tree. Headless (Xvfb).
#
#   tools/flatten_diff/run.sh [ref]
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
ref="${1:-HEAD}"
zig="${ZIG:-$HOME/.zvm/0.16.0/zig}"
rt="$root/src/native_ui/runtime-native.js"
work="$(mktemp -d)"
cp "$rt" "$work/rt-new.js"
git -C "$root" show "$ref:src/native_ui/runtime-native.js" > "$work/rt-base.js"
# Whatever happens, the runtime goes back as it was.
trap 'cp "$work/rt-new.js" "$rt"; rm -rf "$work"' EXIT

steps=$(python3 "$here/page.py" --steps)
status=0
for n in $(seq 1 "$steps"); do
  python3 "$here/page.py" "$n" > "$here/app/web/index.html"
  for v in new base; do
    cp "$work/rt-$v.js" "$rt"
    (cd "$here/app" && "$zig" build -Dnative_ui -Doptimize=ReleaseFast --prefix "$work/out-$v" >/dev/null)
    ORIEL_NUI_DUMP=1 timeout 15 env -u WAYLAND_DISPLAY xvfb-run -a dbus-run-session -- \
      "$work/out-$v/bin/oriel-flatten-diff" > "$work/$v.raw" 2>&1 || true
    # Ids differ between runtimes; the tree's shape, frames and text don't.
    grep -E '^ *(view|text|icon|image|input|canvas)#' "$work/$v.raw" | sed -E 's/#-?[0-9]+/#/' > "$work/$v.txt" || true
  done
  if [ ! -s "$work/new.txt" ]; then
    echo "step $n: no tree (see the app's output)"; status=1
  elif diff -q "$work/new.txt" "$work/base.txt" >/dev/null; then
    echo "step $n: same ($(wc -l < "$work/new.txt") nodes)"
  else
    echo "step $n: DIFFERENT"; diff "$work/new.txt" "$work/base.txt" | head -20; status=1
  fi
done
exit "$status"
