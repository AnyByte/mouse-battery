#!/bin/sh
# Builds build.noindex/MouseBattery.app: a universal (arm64 + x86_64) binary, Info.plist, icon,
# ad-hoc signature. Used by install.sh locally and by the release workflow in CI.
#   VERSION=1.2.0 ./build.sh   (default: the latest git tag without "v", else 0.0.0)
set -eu
cd "$(dirname "$0")"
LABEL=org.anybyte.mouse-battery
MIN_MACOS=12.0
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.0.0}"
APP=build.noindex/MouseBattery.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build.noindex/obj
for arch in arm64 x86_64; do
    swiftc -O -target "$arch-apple-macos$MIN_MACOS" -o "build.noindex/obj/MouseBattery-$arch" main.swift
done
lipo -create -output "$APP/Contents/MacOS/MouseBattery" build.noindex/obj/MouseBattery-arm64 build.noindex/obj/MouseBattery-x86_64
ICON=$(cat icon/compiled/name)
cp "icon/compiled/$ICON.icns" icon/compiled/Assets.car "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>MouseBattery</string>
  <key>CFBundleExecutable</key><string>MouseBattery</string>
  <key>CFBundleIconFile</key><string>$ICON</string>
  <key>CFBundleIconName</key><string>$ICON</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ru</string></array>
</dict></plist>
EOF
# Designated requirement by identifier, not cdhash: the Input Monitoring grant survives rebuilds.
codesign --force --sign - --identifier "$LABEL" -r="designated => identifier \"$LABEL\"" "$APP"
echo "built $APP ($VERSION)"
