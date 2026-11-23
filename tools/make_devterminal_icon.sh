#!/bin/bash
# Builds AppIcon-DevTerminal.icns with the "</>" glyph.
# Usage: tools/make_devterminal_icon.sh [output.icns]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/../tmp/AppIcon-DevTerminal.icns}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$(dirname "$OUT")"
swift "$HERE/make_devterminal_icon.swift" "$WORK/AppIcon.iconset"
iconutil --convert icns --output "$OUT" "$WORK/AppIcon.iconset"
echo "$OUT"
