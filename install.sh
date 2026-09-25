#!/bin/sh
# Install the oriel CLI from GitHub Releases.
#
#   curl -fsSL https://raw.githubusercontent.com/highercomve/Oriel/main/install.sh | sh
#
# Downloads the binary for this machine (x86_64 or aarch64; Linux or macOS;
# on Windows use install.ps1),
# verifies it against the release's SHA256SUMS and installs it as `oriel`.
# Never uses sudo.
#
# Environment:
#   ORIEL_VERSION       release tag to install, e.g. v0.1.0 (default: latest)
#   ORIEL_INSTALL_DIR   where to put the binary (default: ~/.local/bin)
#   ORIEL_MODIFY_PATH   set to 1 to append the PATH export to your shell rc
#   ORIEL_RELEASES_URL  releases base URL (default: the GitHub releases of
#                       highercomve/Oriel); files are fetched from
#                       <url>/latest/download/<file> or <url>/download/<tag>/<file>
set -eu

github_releases="https://github.com/highercomve/Oriel/releases"
releases_url="${ORIEL_RELEASES_URL:-$github_releases}"
version="${ORIEL_VERSION:-latest}"
install_dir="${ORIEL_INSTALL_DIR:-${HOME:?HOME is not set}/.local/bin}"

say() { printf '%s\n' "$*"; }
fail() {
    printf 'install.sh: error: %s\n' "$*" >&2
    exit 1
}

case "$(uname -s)" in
    Linux) os=linux ;;
    Darwin) os=macos ;;
    MINGW* | MSYS* | CYGWIN*) fail "on Windows, use install.ps1 (PowerShell)" ;;
    *) fail "unsupported OS '$(uname -s)' (Linux and macOS; install.ps1 for Windows)" ;;
esac
case "$(uname -m)" in
    x86_64 | amd64) arch=x86_64 ;;
    aarch64 | arm64) arch=aarch64 ;;
    *) fail "unsupported architecture '$(uname -m)' (x86_64 and aarch64 are available)" ;;
esac
asset="oriel-${arch}-${os}"

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

if [ "$version" = latest ] && [ "$releases_url" = "$github_releases" ]; then
    # GitHub's releases/latest skips pre-releases (every 0.x release is one),
    # so ask the API for the newest release of any kind.
    download "https://api.github.com/repos/highercomve/Oriel/releases?per_page=1" "$tmp/releases.json" ||
        fail "could not look up the latest release"
    version="$(sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' "$tmp/releases.json" | head -n 1)"
    [ -n "$version" ] || fail "no releases found at $github_releases"
fi

if [ "$version" = latest ]; then
    base="${releases_url%/}/latest/download"
else
    base="${releases_url%/}/download/${version}"
fi

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
    *)
        shell_name="$(basename "${SHELL:-sh}")"
        case "$shell_name" in
            fish)
                rc_file="${HOME}/.config/fish/config.fish"
                add_line="fish_add_path \"${install_dir}\""
                ;;
            zsh)
                rc_file="${HOME}/.zshrc"
                add_line="export PATH=\"${install_dir}:\$PATH\""
                ;;
            bash)
                rc_file="${HOME}/.bashrc"
                add_line="export PATH=\"${install_dir}:\$PATH\""
                ;;
            *)
                rc_file="${HOME}/.profile"
                add_line="export PATH=\"${install_dir}:\$PATH\""
                ;;
        esac

        if [ "${ORIEL_MODIFY_PATH:-0}" = "1" ]; then
            mkdir -p "$(dirname "$rc_file")"
            if [ -f "$rc_file" ] && grep -qF "$add_line" "$rc_file"; then
                say "${install_dir} is already added to PATH in ${rc_file} (open a new terminal)."
            else
                printf '\n# Oriel CLI\n%s\n' "$add_line" >> "$rc_file"
                say "Added ${install_dir} to PATH in ${rc_file}."
            fi
        else
            say "Note: ${install_dir} is not on your PATH."
            say "To add it to ${rc_file}, run:"
            say "  ${add_line}"
        fi
        ;;
esac
say "Next: oriel doctor, then oriel init my-app"
