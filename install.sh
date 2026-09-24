#!/bin/sh
# Install the oriel CLI from GitHub Releases.
#
#   curl -fsSL https://raw.githubusercontent.com/highercomve/Oriel/main/install.sh | sh
#
# Downloads the static binary for this machine (x86_64 or aarch64 Linux),
# verifies it against the release's SHA256SUMS and installs it as `oriel`.
# Never uses sudo.
#
# Environment:
#   ORIEL_VERSION       release tag to install, e.g. v0.1.0 (default: latest)
#   ORIEL_INSTALL_DIR   where to put the binary (default: ~/.local/bin)
#   ORIEL_RELEASES_URL  releases base URL (default: the GitHub releases of
#                       highercomve/Oriel); files are fetched from
#                       <url>/latest/download/<file> or <url>/download/<tag>/<file>
set -eu

releases_url="${ORIEL_RELEASES_URL:-https://github.com/highercomve/Oriel/releases}"
version="${ORIEL_VERSION:-latest}"
install_dir="${ORIEL_INSTALL_DIR:-${HOME:?HOME is not set}/.local/bin}"

say() { printf '%s\n' "$*"; }
fail() {
    printf 'install.sh: error: %s\n' "$*" >&2
    exit 1
}

os="$(uname -s)"
[ "$os" = Linux ] || fail "unsupported OS '$os': oriel releases are Linux-only for now"
case "$(uname -m)" in
    x86_64 | amd64) arch=x86_64 ;;
    aarch64 | arm64) arch=aarch64 ;;
    *) fail "unsupported architecture '$(uname -m)' (x86_64 and aarch64 are available)" ;;
esac
asset="oriel-${arch}-linux"

if [ "$version" = latest ]; then
    base="${releases_url%/}/latest/download"
else
    base="${releases_url%/}/download/${version}"
fi

if command -v curl >/dev/null 2>&1; then
    download() { curl -fsSL --retry 2 -o "$2" "$1"; }
elif command -v wget >/dev/null 2>&1; then
    download() { wget -q -O "$2" "$1"; }
else
    fail "curl or wget is required"
fi

if command -v sha256sum >/dev/null 2>&1; then
    sha256() { sha256sum "$1" | cut -d ' ' -f 1; }
elif command -v shasum >/dev/null 2>&1; then
    sha256() { shasum -a 256 "$1" | cut -d ' ' -f 1; }
else
    fail "sha256sum or shasum is required to verify the download"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

say "Downloading ${asset} (${version})..."
download "${base}/${asset}" "$tmp/$asset" || fail "download failed: ${base}/${asset}"
download "${base}/SHA256SUMS" "$tmp/SHA256SUMS" || fail "download failed: ${base}/SHA256SUMS"

# The line for our file: "<sha256>  <name>" (sha256sum format, '*' for binary mode).
expected="$(awk -v f="$asset" '$2 == f || $2 == "*" f { print $1; exit }' "$tmp/SHA256SUMS")"
[ -n "$expected" ] || fail "SHA256SUMS has no entry for ${asset}"
actual="$(sha256 "$tmp/$asset")"
[ "$actual" = "$expected" ] || fail "checksum mismatch for ${asset}: expected ${expected}, got ${actual}"

mkdir -p "$install_dir" || fail "cannot create ${install_dir} (set ORIEL_INSTALL_DIR to a writable directory)"
chmod 755 "$tmp/$asset"
# Copy next to the target first, then rename: replacing a running binary
# is safe and a failed copy leaves the old one in place.
cp "$tmp/$asset" "$install_dir/.oriel.new" || fail "cannot write to ${install_dir} (set ORIEL_INSTALL_DIR)"
mv -f "$install_dir/.oriel.new" "$install_dir/oriel"

say "Installed $("$install_dir/oriel" --version | head -n 1) to ${install_dir}/oriel"
case ":${PATH}:" in
    *":${install_dir}:"*) ;;
    *) say "Note: ${install_dir} is not on your PATH; add it, e.g.: export PATH=\"${install_dir}:\$PATH\"" ;;
esac
say "Next: oriel doctor, then oriel init my-app"
