#!/bin/bash
# Real AX regression: launches an isolated AppKit target and verifies focus restoration across processes.
# Requires a logged-in macOS session and Accessibility permission for the test host.
# author: helele
# since: 2026-11-04
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

case "${1:-}" in
  --help|-h)
    printf 'Usage: %s\n' "$0"
    printf 'Builds and runs the real AX focus-restoration regression.\n'
    printf 'Requires Accessibility permission for the terminal / test host.\n'
    exit 0 ;;
  "") ;;
  *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
esac

TEMP_BASE="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
WORK="$(mktemp -d "$TEMP_BASE/cvmaster-ax-checks.XXXXXXXX")"
readonly WORK
cleanup() {
  if [ -n "$WORK" ] && [ -d "$WORK" ] && [ ! -L "$WORK" ] && [ -f "$WORK/.owned" ]; then
    rm -rf -- "$WORK"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf '%s\n' 'cvmaster-ax-checks' > "$WORK/.owned"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"
TARGET="$WORK/AXTargetApp"
CHECKS="$WORK/ax-checks"

printf 'Building real AX target (%s, SDK %s)\n' "$ARCH" "$(xcrun --sdk macosx --show-sdk-version)"
xcrun swiftc -O -swift-version 6 -parse-as-library -target "$ARCH-apple-macosx26.5" -sdk "$SDK" \
  "$ROOT/Validation/AXTargetApp.swift" \
  -framework AppKit -o "$TARGET"

xcrun swiftc -O -swift-version 6 -parse-as-library -target "$ARCH-apple-macosx26.5" -sdk "$SDK" \
  "$ROOT/CVMaster/PasteTarget.swift" \
  "$ROOT/CVMaster/PasteFocusRestoration.swift" \
  "$ROOT/Validation/AXChecks.swift" \
  -framework AppKit -framework ApplicationServices -o "$CHECKS"

"$CHECKS" --target-app "$TARGET"
