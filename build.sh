#!/bin/bash

# Insomniac Build & Setup Script

# 1. Build the app in release mode
echo "🔨 Building Insomniac..."
swift build -c release

if [ $? -ne 0 ]; then
    echo "❌ Build failed."
    exit 1
fi
echo "✅ Build successful."

echo ""
echo "📦 Creating Insomniac.app bundle..."
mkdir -p Insomniac.app/Contents/MacOS Insomniac.app/Contents/Resources

# Derive version/build from git if available, else fall back to 1.0 / 1
VERSION=$(git describe --tags --abbrev=0 2>/dev/null || echo "1.0")
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
</dict>
</plist>
PLIST

cp .build/release/Insomniac Insomniac.app/Contents/MacOS/Insomniac
echo "✅ Insomniac.app created (version ${VERSION}, build ${BUILD})."

echo ""
echo "🚀 Setup complete! Run the app with:"
echo "   open Insomniac.app"
