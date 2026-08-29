#!/usr/bin/env bash
# Builds the my-brain executable for the current platform.
#
# Dart cannot cross-compile: `dart compile exe` always targets the host OS and
# architecture. Binaries for the other platforms come from the release workflow
# in .github/workflows/release.yml, which runs this same script on each runner.
set -euo pipefail

cd "$(dirname "$0")/.."

case "$(uname -s)" in
  Darwin) EXT="" ;;
  Linux)  EXT="" ;;
  *)      EXT=".exe" ;;
esac

OUT="build/my-brain${EXT}"

mkdir -p build
dart pub get
dart run tool/gen_templates.dart
dart analyze
dart compile exe bin/my_brain.dart -o "$OUT"

echo "built $OUT"
"$OUT" version
