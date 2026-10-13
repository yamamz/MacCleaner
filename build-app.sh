#!/bin/zsh
# Builds MacSweep.app (release, ad-hoc signed) into ./build
set -euo pipefail
cd "$(dirname "$0")"

APP="build/MacSweep.app"
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/MacSweep" "$APP/Contents/MacOS/MacSweep"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns" # regenerate with: swift scripts/make-icon.swift

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MacSweep</string>
    <key>CFBundleDisplayName</key><string>MacSweep</string>
    <key>CFBundleIdentifier</key><string>com.macsweep.app</string>
    <key>CFBundleExecutable</key><string>MacSweep</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>MacSweep asks Finder to empty the Trash.</string>
</dict>
</plist>
PLIST

# Sign with a stable identity when one exists, so macOS privacy grants (Full Disk Access)
# survive rebuilds. Ad-hoc signatures change on every build and invalidate those grants.
IDENTITY="${MACSWEEP_SIGN_IDENTITY:-MacSweep Local}"
HASH=$(security find-identity -p codesigning | awk -v id="\"$IDENTITY\"" 'index($0, id) { print $2; exit }')
if [[ -n "$HASH" ]]; then
    codesign --force --deep --sign "$HASH" "$APP"
else
    echo "No \"$IDENTITY\" signing identity found; signing ad-hoc (Full Disk Access must be re-granted after each build)."
    codesign --force --deep --sign - "$APP"
fi
echo "Built $PWD/$APP"
