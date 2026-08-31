#!/bin/bash
set -e

# Insomniac Build & Packaging Script
# Usage:
#   ./build.sh        Build Insomniac.app
#   ./build.sh dmg    Build Insomniac.app and package it as Insomniac.dmg

echo "🔨 Building Insomniac..."
swift build -c release
echo "✅ Build successful."

echo ""
echo "📦 Creating Insomniac.app bundle..."
rm -rf Insomniac.app
mkdir -p Insomniac.app/Contents/MacOS Insomniac.app/Contents/Resources

# Derive version/build from git if available, else fall back to 1.0 / 1.
#
# Only version-shaped tags count. `git describe --tags` returns whatever tag is
# most recent, so a non-release tag would land in CFBundleShortVersionString —
# and UpdateChecker parses that string, so a non-numeric version reads as 0 and
# every release then looks like an available update, forever.
VERSION=$(git tag --list 'v[0-9]*' --sort=-version:refname 2>/dev/null | head -1 | sed 's/^v//')
if [ -z "$VERSION" ]; then
    VERSION=$(git tag --list '[0-9]*' --sort=-version:refname 2>/dev/null | head -1)
fi
VERSION=${VERSION:-1.0}
if ! printf '%s' "$VERSION" | grep -Eq '^[0-9]+(\.[0-9]+)*$'; then
    echo "⚠️  Ignoring non-numeric version tag '$VERSION'; using 1.0"
    VERSION=1.0
fi
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo "1")
YEAR=$(date +%Y)

cat > Insomniac.app/Contents/Info.plist << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Insomniac</string>
    <key>CFBundleIdentifier</key>
    <string>com.vatsal.Insomniac</string>
    <key>CFBundleName</key>
    <string>Insomniac</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD}</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © ${YEAR} Vatsal. All rights reserved.</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>com.vatsal.Insomniac.url</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>insomniac</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

cp .build/release/Insomniac Insomniac.app/Contents/MacOS/Insomniac
cp icons/AppIcon.icns Insomniac.app/Contents/Resources/AppIcon.icns
# SPM resource bundles (e.g. KeyboardShortcuts) — Bundle.module fatalErrors
# at runtime if these are missing from Contents/Resources.
cp -R .build/release/*.bundle Insomniac.app/Contents/Resources/

# Ad-hoc sign so Gatekeeper doesn't report the app as damaged on Apple Silicon
echo "🔏 Codesigning (ad-hoc)..."
codesign --force --deep --sign - Insomniac.app

echo "✅ Insomniac.app created (version ${VERSION}, build ${BUILD})."

if [ "$1" = "dmg" ]; then
    echo ""
    echo "💿 Creating Insomniac.dmg..."
    STAGING=$(mktemp -d)
    cp -R Insomniac.app "$STAGING/"
    ln -s /Applications "$STAGING/Applications"
    rm -f Insomniac.dmg
    hdiutil create -volname "Insomniac" -srcfolder "$STAGING" -ov -format UDZO Insomniac.dmg
    rm -rf "$STAGING"
    echo "✅ Insomniac.dmg created."
else
    echo ""
    echo "🚀 Run the app with:  open Insomniac.app"
    echo "   Or package a DMG:  ./build.sh dmg"
fi
