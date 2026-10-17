#!/bin/zsh
# Render assets/AppIcon/AppIcon.png and AppIcon.icns. Commit both after you run it (./scripts/build.sh icon).
# render_icon.swift draws the SVG files on a transparent canvas. sips cannot: it fills the canvas
# with white and ignores the SVG drop-shadow filter.
# The 16 px and 32 px files use AppIcon-small.svg (no shadow, thicker strokes) so the stem stays visible.
# The larger files use AppIcon.png, the 1024 px render of AppIcon.svg with its drop shadow.
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
SRC=assets/AppIcon
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
svg() { # <source> <pixels> <file> [shadow]
  swift scripts/render_icon.swift "$SRC/$1" "$2" "$3" "${@:4}"
}
render() { # <pixels> <file name>
  sips -s format png -z "$1" "$1" "$SRC/AppIcon.png" --out "$ICONSET/$2" >/dev/null
}
svg AppIcon.svg 1024 "$SRC/AppIcon.png" shadow
svg AppIcon-small.svg 16 "$ICONSET/icon_16x16.png"
svg AppIcon-small.svg 32 "$ICONSET/icon_16x16@2x.png"
svg AppIcon-small.svg 32 "$ICONSET/icon_32x32.png"
render 64 icon_32x32@2x.png
for size in 128 256 512; do
  render $size icon_${size}x${size}.png
  render $((size * 2)) icon_${size}x${size}@2x.png
done
iconutil -c icns "$ICONSET" -o "$SRC/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"
echo "$SRC/AppIcon.png $SRC/AppIcon.icns"
