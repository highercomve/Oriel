#!/usr/bin/env bash
# Type-check an app (or Oriel itself) for Android without the NDK:
#   scripts/android/check.sh [aarch64|x86_64] [zig build args...]   (run in the app's directory)
# `zig build check -Dtarget=...-linux-android` needs no NDK until C code
# comes in (llama, whisper, sqlite): their headers need a libc. This points
# Zig at its bundled musl headers instead of bionic's, which is enough to
# type-check the Zig code and translate the C headers. It only checks: the
# C++ runtime and real builds need the NDK (docs/android.md). Errors from
# libc++ or the C sources here are expected; look at the .zig ones.
set -euo pipefail
arch=${1:-aarch64}
shift || true
inc=$(zig env | sed -n 's/.*\.lib_dir = "\([^"]*\)".*/\1/p')/libc/include
[ -d "$inc/generic-musl" ] || { echo "error: no musl headers under $inc" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/libc.txt" <<LIBC
include_dir=$inc/$arch-linux-musl
sys_include_dir=$inc/generic-musl
crt_dir=$tmp
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=
LIBC
out=$(zig build check --libc "$tmp/libc.txt" -Dtarget="$arch-linux-android" "$@" 2>&1 || true)
if grep -E '\.zig:[0-9]+:[0-9]+: (error|note)' <<<"$out"; then exit 1; fi
echo "ok: no Zig errors for $arch-linux-android"
