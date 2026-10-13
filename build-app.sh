#!/bin/zsh
# Builds MacSweep.app (release, ad-hoc signed) into ./build
set -euo pipefail
cd "$(dirname "$0")"

APP="build/MacSweep.app"
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/MacSweep" "$APP/Contents/MacOS/MacSweep"

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
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>MacSweep asks Finder to empty the Trash.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Built $PWD/$APP"
