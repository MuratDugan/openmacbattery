#!/bin/bash
# Builds OpenMacBattery.app and packages it into a drag-to-install DMG with
# a custom background, fixed window size, and icons positioned where the
# background's arrow points.
#
# Output: build/OpenMacBattery-<version>.dmg
#
# Usage:
#   ./scripts/make-dmg.sh           # uses version from Info.plist
#   ./scripts/make-dmg.sh 0.2.1     # override version
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 1. Build the .app bundle
bash scripts/make-app.sh

APP="$ROOT/build/OpenMacBattery.app"
[ -d "$APP" ] || { echo "Error: $APP not found"; exit 1; }

BG="$ROOT/assets/dmg-background.png"
[ -f "$BG" ] || { echo "Error: $BG not found (run scripts/make-dmg-background.swift first)"; exit 1; }

# 2. Resolve version
if [ "${1:-}" != "" ]; then
    VERSION="$1"
else
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || echo "0.1")
fi
DMG="$ROOT/build/OpenMacBattery-${VERSION}.dmg"
TMP_DMG="$ROOT/build/OpenMacBattery-${VERSION}-rw.dmg"
VOLNAME="OpenMacBattery ${VERSION}"

# 3. Stage folder with .app, /Applications shortcut, hidden .background folder
STAGE="$ROOT/build/dmg-stage"
rm -rf "$STAGE" "$DMG" "$TMP_DMG"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/OpenMacBattery.app"
ln -s /Applications "$STAGE/Applications"
cp "$BG" "$STAGE/.background/background.png"

# 4. Create writable DMG so we can apply Finder window settings
echo "Creating writable DMG..."
hdiutil create \
    -volname "$VOLNAME" \
    -srcfolder "$STAGE" \
    -ov \
    -fs HFS+ \
    -format UDRW \
    "$TMP_DMG" >/dev/null

# 5. Mount and apply layout via AppleScript
echo "Mounting and applying layout..."
MOUNT_OUT=$(hdiutil attach -readwrite -noverify -noautoopen "$TMP_DMG")
DEVICE=$(echo "$MOUNT_OUT" | egrep '^/dev/' | sed 1q | awk '{print $1}')
MOUNT_POINT="/Volumes/$VOLNAME"

# Wait for mount to settle
sleep 2

osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 100, 1000, 600}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.png"
        set position of item "OpenMacBattery.app" of container window to {200, 230}
        set position of item "Applications" of container window to {600, 230}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

# Sync and unmount
sync
hdiutil detach "$DEVICE" -force >/dev/null
sleep 1

# 6. Convert writable DMG to compressed read-only
echo "Compressing..."
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$TMP_DMG"
rm -rf "$STAGE"

SIZE=$(du -h "$DMG" | cut -f1)
echo
echo "✓ Built: $DMG ($SIZE)"
echo "  Open it to see the drag-to-install window."
