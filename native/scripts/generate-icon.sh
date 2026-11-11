#!/bin/bash
# 从透明 CV 主图生成 macOS 多尺寸应用图标及去空白的菜单栏模板图。
# author: helele
# since: 2026-10-19
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONSET="$ROOT/.build/AppIcon.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
  sips -z "$SIZE" "$SIZE" "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
  DOUBLE=$((SIZE * 2))
  sips -z "$DOUBLE" "$DOUBLE" "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
# 主图保留应用图标安全留白；菜单栏单独裁到标志周围，避免 18 pt 下主体过小。
sips --cropToHeightWidth 422 798 "$ROOT/Resources/AppIcon.png" \
  --out "$ROOT/Resources/StatusIcon.png" >/dev/null
printf '应用及菜单栏图标已生成：%s\n' "$ROOT/Resources/AppIcon.icns"
