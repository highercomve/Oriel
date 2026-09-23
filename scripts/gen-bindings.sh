#!/usr/bin/env bash
# Generate zig-gobject bindings from this machine's GIR files
# (/usr/share/gir-1.0), so the bindings match the installed GTK/WebKitGTK.
# Output: deps/gobject/bindings — referenced as a path dependency in build.zig.zon.
set -euo pipefail

ZIG_GOBJECT_REF="${ZIG_GOBJECT_REF:-v0.3.2}"
MODULES=(Gtk-4.0 WebKit-6.0 Xdp-1.0 XdpGtk4-1.0)

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="$root/deps/.zig-gobject-src"
out="$root/deps/gobject"
zig="${ZIG:-zig}"

command -v xsltproc >/dev/null || { echo "xsltproc is required (libxslt)" >&2; exit 1; }

if [ ! -d "$src/.git" ]; then
    git clone --quiet https://github.com/ianprime0509/zig-gobject "$src"
fi
git -C "$src" fetch --quiet --tags
git -C "$src" checkout --quiet "$ZIG_GOBJECT_REF"

args=()
for m in "${MODULES[@]}"; do args+=("-Dmodules=$m"); done

rm -rf "$out"
(cd "$src" && "$zig" build codegen "${args[@]}" -p "$out")
echo "Bindings generated in $out/bindings (zig-gobject $ZIG_GOBJECT_REF)"
