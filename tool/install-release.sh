#!/usr/bin/env bash
# Installs or updates my-brain from a published GitHub release.
#
# This is the path for people who just want the command; tool/install.sh is the
# path for people working on the source. Re-running it is the update: it always
# replaces the binary already in INSTALL_DIR.
#
#   curl -fsSL https://raw.githubusercontent.com/timovandeput/my-brain/main/tool/install-release.sh | bash
#
#   INSTALL_DIR=/usr/local/bin   where to put the binary (default ~/.local/bin)
#   MY_BRAIN_VERSION=v0.1.0      pin a release (default: latest)
set -euo pipefail

REPO="timovandeput/my-brain"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
VERSION="${MY_BRAIN_VERSION:-latest}"

case "$(uname -s)" in
  Darwin) os="macos" ;;
  Linux)  os="linux" ;;
  *) echo "my-brain: no prebuilt binary for $(uname -s); build from source with tool/build.sh" >&2; exit 1 ;;
esac

case "$(uname -m)" in
  arm64|aarch64) arch="arm64" ;;
  x86_64|amd64)  arch="x64" ;;
  *) echo "my-brain: no prebuilt binary for $(uname -m)" >&2; exit 1 ;;
esac

target="$os-$arch"

# The release matrix builds macos-arm64 and linux-x64. An Intel Mac is not in
# it, so say that here rather than letting the download 404.
case "$target" in
  macos-arm64 | linux-x64) ;;
  *)
    echo "my-brain: no prebuilt binary for $target; build from source with tool/build.sh" >&2
    exit 1
    ;;
esac
asset="my-brain-$target.tar.gz"

if [ "$VERSION" = "latest" ]; then
  base="https://github.com/$REPO/releases/latest/download"
else
  base="https://github.com/$REPO/releases/download/$VERSION"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "downloading $asset ($VERSION)"
curl -fsSL "$base/$asset" -o "$tmp/$asset"
curl -fsSL "$base/SHA256SUMS.txt" -o "$tmp/SHA256SUMS.txt"

# Checking the download is the only thing standing between a corrupted or
# swapped tarball and a binary on the PATH, so it is not optional.
if command -v sha256sum >/dev/null 2>&1; then
  sha_check() { sha256sum -c --status "$1"; }
else
  sha_check() { shasum -a 256 -c --status "$1"; }
fi
# awk on the exact filename field, not grep on a pattern: the asset name is
# full of dots, which grep reads as wildcards, so the line it pulls is not
# guaranteed to be the line for this file.
awk -v asset="$asset" '$2 == asset' "$tmp/SHA256SUMS.txt" > "$tmp/expected.txt"

# This emptiness check is load-bearing, not defensive noise: GNU sha256sum
# exits 0 on a checksum file containing no lines, so an asset missing from
# SHA256SUMS.txt would otherwise verify as a pass.
if [ ! -s "$tmp/expected.txt" ]; then
  echo "my-brain: $asset is not listed in SHA256SUMS.txt; refusing to install" >&2
  exit 1
fi

if ! (cd "$tmp" && sha_check expected.txt); then
  echo "my-brain: checksum mismatch for $asset; refusing to install" >&2
  exit 1
fi

tar -xzf "$tmp/$asset" -C "$tmp"
mkdir -p "$INSTALL_DIR"
# Move rather than copy over the live file: replacing a running binary in place
# is what produces "Killed: 9" on macOS.
mv -f "$tmp/my-brain" "$INSTALL_DIR/my-brain"
chmod +x "$INSTALL_DIR/my-brain"

echo "installed $("$INSTALL_DIR/my-brain" version) to $INSTALL_DIR/my-brain"

if ! command -v my-brain >/dev/null 2>&1; then
  cat <<EOF

$INSTALL_DIR is not on your PATH. Add this to your shell profile:

  export PATH="\$PATH:$INSTALL_DIR"

Until then, \`my-brain init\` still works when run by its full path — it records
the absolute path of the binary in the vault's AGENTS.md, so the agent can call
it either way.
EOF
fi
