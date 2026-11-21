#!/bin/sh
# AppIcon.icon (Icon Composer: system gradient fill + white glass mouse glyph) ->
# compiled/Assets.car + compiled/<name>.icns (fallback for older macOS) + compiled/name.
# The icon name carries a hash of the source: Launchpad/Dock cache icons by bundle and
# icon name and ignore changes otherwise, so a new name forces a redraw.
# Needs Xcode 26+. The output is committed, so CI builds do not depend on the runner's Xcode.
set -eu
cd "$(dirname "$0")"
NAME="AppIcon-$(find AppIcon.icon -type f | sort | xargs cat | shasum | cut -c1-8)"
TMP=$(mktemp -d)
cp -R AppIcon.icon "$TMP/$NAME.icon"
rm -rf compiled && mkdir compiled
xcrun actool "$TMP/$NAME.icon" --compile compiled --app-icon "$NAME" --platform macosx \
    --target-device mac --minimum-deployment-target 12.0 \
    --output-partial-info-plist "$TMP/partial.plist" >/dev/null
rm -rf "$TMP"
echo "$NAME" > compiled/name
ls compiled
