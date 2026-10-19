#!/bin/bash
# 将 SwiftUI 客户端打包为本机可打开的 arm64 .app，不使用 Maven 或第三方依赖。
# author: helele
# since: 2026-10-19
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
OUTPUT="$ROOT/.build"
APP="$OUTPUT/cvMaster.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUTPUT/module-cache"
xcrun swiftc -O -swift-version 6 -target arm64-apple-macosx26.5 -sdk "$SDK" \
  -module-cache-path "$OUTPUT/module-cache" -parse-as-library \
  "$ROOT"/CVMaster/*.swift -lsqlite3 -o "$APP/Contents/MacOS/cvMaster"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# 仅清除新生成构建包的扩展属性，避免同步目录附加 Finder 元数据导致签名失败。
xattr -cr "$APP"
# 优先使用稳定开发身份：ad-hoc 的 designated requirement 绑定 cdhash，重新构建可能丢失辅助功能授权。
# 可用 CVMASTER_SIGNING_IDENTITY 明确指定证书 SHA-1；不创建证书、不修改系统权限数据库。
IDENTITY="${CVMASTER_SIGNING_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning | awk '/"Apple Development:|"Mac Development:/ {print $2; exit}')"
fi
if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" "$APP"
else
  # 无开发证书时仅供本机预览；不可伪造稳定授权身份，升级后可能需要重新授权。
  printf '\n警告：没有可用开发证书，使用临时签名；重新构建后可能需要移除旧辅助功能条目并重新授权。\n' >&2
  codesign --force --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
printf '\n原生客户端已生成：%s\n' "$APP"
