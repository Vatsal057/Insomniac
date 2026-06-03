#!/bin/bash

# Insomniac Build & Setup Script

# 1. Build the app in release mode
echo "🔨 Building Insomniac..."
swift build -c release

if [ $? -eq 0 ]; then
    echo "✅ Build successful."
else
    echo "❌ Build failed."
    exit 1
fi

echo ""
echo "📦 Creating Insomniac.app bundle..."
mkdir -p Insomniac.app/Contents/MacOS Insomniac.app/Contents/Resources

cat <<EOF > Insomniac.app/Contents/Info.plist
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
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

cp .build/release/Insomniac Insomniac.app/Contents/MacOS/Insomniac
echo "✅ Insomniac.app created."

echo ""
echo "🚀 Setup complete! You can now run the app with:"
echo "open Insomniac.app"
