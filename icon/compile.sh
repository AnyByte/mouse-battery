#!/bin/sh
# AppIcon.icon (Icon Composer: gradient background + mouse layer; macOS adds the shape and
# Liquid Glass) -> compiled/Assets.car + compiled/AppIcon.icns (fallback for older macOS).
# Needs Xcode 26+. The output is committed, so CI builds do not depend on the runner's Xcode.
set -eu
cd "$(dirname "$0")"
rm -rf compiled && mkdir compiled
xcrun actool AppIcon.icon --compile compiled --app-icon AppIcon --platform macosx \
    --target-device mac --minimum-deployment-target 12.0 \
    --output-partial-info-plist /tmp/AppIcon-partial.plist >/dev/null
ls compiled
