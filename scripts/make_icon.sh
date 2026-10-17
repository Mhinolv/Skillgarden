#!/bin/zsh
# Render assets/AppIcon/AppIcon.icns. Commit the .icns after you run it (./scripts/build.sh icon).
# The 16 px and 32 px files use AppIcon-small.svg (no shadow, thicker strokes) so the stem stays visible.
# The larger files use AppIcon.png, the 1024 px render of AppIcon.svg, because sips (CoreSVG)
# ignores the SVG drop-shadow filter. If you change AppIcon.svg, render AppIcon.png again.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=assets/AppIcon
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
render() { # <source> <pixels> <file name>
  sips -s format png -z "$2" "$2" "$SRC/$1" --out "$ICONSET/$3" >/dev/null
}
render AppIcon-small.svg 16 icon_16x16.png
render AppIcon-small.svg 32 icon_16x16@2x.png
render AppIcon-small.svg 32 icon_32x32.png
render AppIcon.png 64 icon_32x32@2x.png
for size in 128 256 512; do
  render AppIcon.png $size icon_${size}x${size}.png
  render AppIcon.png $((size * 2)) icon_${size}x${size}@2x.png
done
iconutil -c icns "$ICONSET" -o "$SRC/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"
echo "$SRC/AppIcon.icns"
