#!/bin/bash
# 从 SVG 同时生成 macOS 和 Windows 图标；需要 Python + Pillow。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "${PYTHON:-python3}" "$ROOT/scripts/generate-icons.py"
