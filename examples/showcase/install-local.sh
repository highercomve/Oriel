#!/usr/bin/env bash
# Local user install of Oriel Showcase on Linux:
#   - builds the packages with CUDA support (-Dggml_cuda)
#   - installs the AppImage to ~/.local/bin/oriel-showcase
#   - installs the .desktop entry + icons (extracted from the AppImage)
#
#   ./install-local.sh              build + install
#   ./install-local.sh --skip-build reuse the last zig-out/package artifacts
#   ./install-local.sh -Dggml_vulkan  extra flags (-D<...>) are forwarded to the build
set -euo pipefail
cd "$(dirname "$0")"

app_id=dev.oriel.Showcase
scheme=oriel-showcase
exe_name=oriel-showcase
name="Oriel Showcase"
summary="Everything Oriel does, on every platform"
install_bin="$HOME/.local/bin/$exe_name"
data_home="${XDG_DATA_HOME:-$HOME/.local/share}"

extra_flags=()
skip_build=false
for a in "$@"; do
    case "$a" in
        -D*) extra_flags+=("$a") ;;
        --skip-build) skip_build=true ;;
        *) echo "usage: $0 [--skip-build] [-D<zig build flag>...]"; exit 1 ;;
    esac
done

if ! $skip_build; then
    oriel package -Dggml_cuda "${extra_flags[@]}"
fi

appimage=$(realpath "$(ls -t "zig-out/package/${exe_name}-"*-x86_64.AppImage 2>/dev/null | head -n 1)") || true
if [[ -z "$appimage" ]]; then
    echo "error: no zig-out/package/${exe_name}-*x86_64.AppImage; run without --skip-build" >&2
    exit 1
fi

mkdir -p "$HOME/.local/bin"
cp -f "$appimage" "$install_bin"
echo "Installed $install_bin ($appimage)"

# Icons: extract them from the AppImage itself (no rebuild needed).
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
(cd "$tmpdir" && "$appimage" --appimage-extract >/dev/null)
icon_root="squashfs-root/usr/share/icons/hicolor"
if [[ -d "$tmpdir/$icon_root" ]]; then
    mkdir -p "$data_home/icons"
    cp -a "$tmpdir/$icon_root/." "$data_home/icons/"
    echo "Installed icons into $data_home/icons/hicolor"
else
    echo "warning: no icons found in the AppImage" >&2
fi

# Desktop entry.
desktop_dir="$data_home/applications"
desktop="$desktop_dir/$app_id.desktop"
mkdir -p "$desktop_dir"
cat > "$desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$name
GenericName=$summary
Exec=$install_bin %u
Icon=$app_id
Terminal=false
StartupNotify=true
StartupWMClass=$app_id
MimeType=x-scheme-handler/$scheme;
Categories=Utility;
EOF

if command -v desktop-file-validate >/dev/null; then
    desktop-file-validate "$desktop"
fi
if command -v update-desktop-database >/dev/null; then
    update-desktop-database "$desktop_dir"
fi
echo "Installed $desktop (Exec=$install_bin %u)"
