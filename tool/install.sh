#!/usr/bin/env bash
# Builds my-brain and links it onto your PATH.
#
# Installs to ~/.local/bin by default; override with INSTALL_DIR. The link
# points at build/my-brain, so a later `tool/build.sh` updates the installed
# command without reinstalling.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$(pwd)"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"

./tool/build.sh

mkdir -p "$INSTALL_DIR"
ln -sf "$REPO/build/my-brain" "$INSTALL_DIR/my-brain"
echo "linked $INSTALL_DIR/my-brain -> $REPO/build/my-brain"

if ! command -v my-brain >/dev/null 2>&1; then
  cat <<EOF

$INSTALL_DIR is not on your PATH. Add this to your shell profile:

  export PATH="\$PATH:$INSTALL_DIR"

Until then, \`my-brain init\` still works when run by its full path — it records
the absolute path of the binary in the vault's AGENTS.md, so the agent can call
it either way.
EOF
fi
