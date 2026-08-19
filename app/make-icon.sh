#!/bin/bash
# Build Sanele's .icns and the menu-bar template image from vector source.
#
# Every size is re-rasterised from the SVG rather than downsampled from one
# bitmap — that's what keeps 16px crisp instead of blurry. Sizes 16-64 use
# icon-small.svg (solid capsule); 128+ use icon.svg (waveform cut in), because
# the waveform collapses into noise below ~128px.
#
# Deps: resvg (brew) + iconutil (Apple). No Python, no Pillow.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$HOME/.config/sanele"
ICONSET="$CFG/appicon.iconset"

RESVG="${RESVG:-/opt/homebrew/bin/resvg}"
if [ ! -x "$RESVG" ]; then
  command -v resvg >/dev/null 2>&1 && RESVG="$(command -v resvg)" || {
    echo "  warning: resvg not found — skipping icon build (brew install resvg)" >&2; exit 0; }
fi

rm -rf "$ICONSET"; mkdir -p "$ICONSET"

# px:iconset-name:source   (Apple's required 10 entries for a complete .icns)
for spec in \
  "16:icon_16x16:small"      "32:icon_16x16@2x:small" \
  "32:icon_32x32:small"      "64:icon_32x32@2x:small" \
  "128:icon_128x128:main"    "256:icon_128x128@2x:main" \
  "256:icon_256x256:main"    "512:icon_256x256@2x:main" \
  "512:icon_512x512:main"    "1024:icon_512x512@2x:main"
do
  px="${spec%%:*}"; rest="${spec#*:}"; name="${rest%%:*}"; which="${rest##*:}"
  src="$HERE/assets/icon.svg"
  [ "$which" = "small" ] && src="$HERE/assets/icon-small.svg"
  "$RESVG" --width "$px" --height "$px" "$src" "$ICONSET/${name}.png" 2>/dev/null \
    || echo "  warning: resvg failed for $name" >&2
done

if /usr/bin/iconutil -c icns "$ICONSET" -o "$CFG/appicon.icns" 2>/dev/null; then
  echo "  ✓ appicon.icns built ($(/bin/ls -1 "$ICONSET" | wc -l | tr -d ' ') sizes)"
else
  echo "  warning: iconutil failed" >&2
fi

# Menu-bar template image (1x + 2x). macOS uses only the alpha channel and
# tints it per light/dark/active — see sanele.lua's wf.bar:setIcon.
mkdir -p "$CFG/menubar"
"$RESVG" --width 22 --height 22 "$HERE/assets/icon-menubar.svg" "$CFG/menubar/mic.png"    2>/dev/null
"$RESVG" --width 44 --height 44 "$HERE/assets/icon-menubar.svg" "$CFG/menubar/mic@2x.png" 2>/dev/null
[ -f "$CFG/menubar/mic.png" ] && echo "  ✓ menu-bar template built"

# The trailing test above must not decide the script's exit status — a failed
# menu-bar render should warn, not abort install.sh (which runs under set -e).
exit 0
