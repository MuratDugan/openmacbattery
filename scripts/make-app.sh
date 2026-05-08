#!/bin/bash
# Builds a self-contained OpenMacBattery.app bundle with both GUI and CLI inside.
# Optional flag: --install copies the bundle to /Applications and offers to start.
#
# Usage:
#   ./scripts/make-app.sh             # build into ./build/OpenMacBattery.app
#   ./scripts/make-app.sh --install   # also copy to /Applications and open
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

INSTALL_TO_APPLICATIONS=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL_TO_APPLICATIONS=1 ;;
    esac
done

echo "Building release..."
swift build -c release --arch arm64 >/dev/null

APP_DIR="$ROOT/build/OpenMacBattery.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp .build/release/openmacbattery-gui "$APP_DIR/Contents/MacOS/OpenMacBattery"
cp .build/release/openmacbattery     "$APP_DIR/Contents/Resources/openmacbattery"

# App icon
if [ -f "$ROOT/assets/AppIcon.icns" ]; then
    cp "$ROOT/assets/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# Localizations — copy each .lproj into Contents/Resources/ at top level.
SPM_BUNDLE=$(find .build/arm64-apple-macosx/release -maxdepth 2 -name "*OpenMacBatteryApp.bundle" -type d | head -1)
if [ -n "$SPM_BUNDLE" ]; then
    for lproj in "$SPM_BUNDLE"/*.lproj; do
        [ -d "$lproj" ] || continue
        name=$(basename "$lproj")
        case "$name" in
            zh-hans.lproj) name="zh-Hans.lproj" ;;
            zh-hant.lproj) name="zh-Hant.lproj" ;;
            pt-br.lproj)   name="pt-BR.lproj" ;;
        esac
        cp -R "$lproj" "$APP_DIR/Contents/Resources/$name"
    done
    echo "Localizations: $(ls "$APP_DIR/Contents/Resources/" | grep -c .lproj)"
fi

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>           <string>OpenMacBattery</string>
    <key>CFBundleDisplayName</key>    <string>OpenMacBattery</string>
    <key>CFBundleIdentifier</key>     <string>com.openmacbattery.gui</string>
    <key>CFBundleVersion</key>        <string>1</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleExecutable</key>     <string>OpenMacBattery</string>
    <key>CFBundleIconFile</key>       <string>AppIcon</string>
    <key>CFBundlePackageType</key>    <string>APPL</string>
    <key>LSMinimumSystemVersion</key> <string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>tr</string>
        <string>zh-Hans</string>
        <string>es</string>
        <string>de</string>
        <string>fr</string>
        <string>ja</string>
        <string>pt-BR</string>
    </array>
</dict>
</plist>
PLIST

codesign --force --sign - --deep "$APP_DIR" 2>/dev/null || true

echo "Bundle: $APP_DIR"

if [[ "$INSTALL_TO_APPLICATIONS" -eq 1 ]]; then
    DEST="/Applications/OpenMacBattery.app"
    echo
    echo "Installing to $DEST ..."
    # Eski sürümleri (BatTracker) söküp temizle
    /bin/launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.murat.battracker.plist" 2>/dev/null || true
    /bin/launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.openmacbattery.plist" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/com.murat.battracker.plist"
    rm -rf /Applications/BatTracker.app
    rm -rf "$DEST"
    cp -R "$APP_DIR" "$DEST"
    codesign --force --sign - --deep "$DEST" 2>/dev/null || true
    echo "Done. Launching..."
    open "$DEST"
else
    echo
    echo "To install to /Applications: ./scripts/make-app.sh --install"
fi
