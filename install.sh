#!/bin/sh
# Builds the app, copies it to ~/Applications and (re)loads a LaunchAgent that starts it
# at login and restarts it if it crashes.
set -eu
cd "$(dirname "$0")"
./build.sh
LABEL=org.anybyte.xlite-battery
APP="$HOME/Applications/XliteBattery.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
# One-time move from the old name MouseBattery (v1.0.x): stop and remove it, keep its settings.
OLD=org.anybyte.mouse-battery
if [ -e "$HOME/Library/LaunchAgents/$OLD.plist" ] || [ -e "$HOME/Applications/MouseBattery.app" ]; then
    launchctl bootout "gui/$(id -u)/$OLD" 2>/dev/null || true
    pkill -x MouseBattery 2>/dev/null || true
    rm -rf "$HOME/Library/LaunchAgents/$OLD.plist" "$HOME/Applications/MouseBattery.app"
    defaults read "$LABEL" >/dev/null 2>&1 || defaults export "$OLD" - 2>/dev/null | defaults import "$LABEL" - 2>/dev/null || true
fi
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -rf "$APP"
ditto build.noindex/XliteBattery.app "$APP"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/XliteBattery</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
EOF
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed $APP and started $LABEL"
