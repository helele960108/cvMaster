#!/bin/bash
# Compile only storage/model/thumbnail code and pure policies; never start the application or touch its history.
# author: helele
# since: 2026-10-20
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AX=0
ARGS=()
for argument in "$@"; do
  case "$argument" in
    --ax) AX=1 ;;
    --benchmark|--benchmark-large) ARGS+=("$argument") ;;
    --help|-h)
      printf 'Usage: %s [--ax] [--benchmark] [--benchmark-large]\n' "$0"
      printf 'Runs isolated synthetic regressions; optional benchmarks use 1k/5k/10k rows.\n'
      printf '%s\n' '--benchmark-large additionally measures 32,768-character search text (higher disk/time use).'
      printf '%s\n' '--ax additionally runs the real AX focus-restoration regression; requires Accessibility permission.'
      exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$argument" >&2; exit 2 ;;
  esac
done

# Only this exact mktemp result is ever removed; callers cannot supply a cleanup path.
# Resolve macOS /var -> /private/var before opening SQLite with SQLITE_OPEN_NOFOLLOW.
TEMP_BASE="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
WORK="$(mktemp -d "$TEMP_BASE/cvmaster-regressions.XXXXXXXX")"
readonly WORK
cleanup() {
  if [ -n "$WORK" ] && [ -d "$WORK" ] && [ ! -L "$WORK" ] && [ -f "$WORK/.owned" ]; then
    rm -rf -- "$WORK"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf '%s\n' 'cvmaster-isolated-regressions' > "$WORK/.owned"
mkdir -m 700 "$WORK/data" "$WORK/module-cache"
printf '%s\n' 'cvmaster-isolated-regressions' > "$WORK/data/.owned"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"
printf 'Isolated Swift 6 optimized validation (%s, SDK %s)\n' "$ARCH" "$(xcrun --sdk macosx --show-sdk-version)"
xcrun swiftc -O -swift-version 6 -target "$ARCH-apple-macosx26.5" -sdk "$SDK" \
  -module-cache-path "$WORK/module-cache" -parse-as-library \
  "$ROOT/CVMaster/Models.swift" \
  "$ROOT/CVMaster/GlobalShortcut.swift" \
  "$ROOT/CVMaster/SingleInstanceLock.swift" \
  "$ROOT/CVMaster/HistoryStore.swift" \
  "$ROOT/CVMaster/ThumbnailPipeline.swift" \
  "$ROOT/CVMaster/ClipboardCapturePolicy.swift" \
  "$ROOT/CVMaster/PasteHandoffPolicy.swift" \
  "$ROOT/CVMaster/PasteFocusRestoration.swift" \
  "$ROOT/Validation/SingleInstanceChecks.swift" \
  "$ROOT/Validation/RegressionChecks.swift" \
  -lsqlite3 -o "$WORK/regression-checks"
if [ "${#ARGS[@]}" -gt 0 ]; then
  "$WORK/regression-checks" --workspace "$WORK/data" "${ARGS[@]}"
else
  "$WORK/regression-checks" --workspace "$WORK/data"
fi
if [ "$AX" -eq 1 ]; then
  "$ROOT/scripts/check-ax.sh"
fi
