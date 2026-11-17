#!/bin/sh
# icon/AppIcon.png (1024x1024, transparent margin) -> icon/AppIcon.icns
set -eu
cd "$(dirname "$0")"
rm -rf AppIcon.iconset && mkdir AppIcon.iconset
for s in 16 32 128 256 512; do
    sips -z $s $s AppIcon.png --out AppIcon.iconset/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) AppIcon.png --out AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns AppIcon.iconset -o AppIcon.icns
rm -rf AppIcon.iconset
