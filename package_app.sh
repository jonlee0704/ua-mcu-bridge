#!/usr/bin/env bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
APP_NAME="UA-MCU Bridge.app"
APP_DIR="$DIR/$APP_NAME"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "==> Building UA-MCU Bridge Native Menu Bar App..."

# Compile Swift code
swiftc -O -framework Cocoa "$DIR/app_build/main.swift" -o "$DIR/app_build/UAMCUBridge"

# Create App bundle structure
rm -rf "$APP_DIR"
mkdir -p "$MACOS"
mkdir -p "$RESOURCES"

# Copy binary
cp "$DIR/app_build/UAMCUBridge" "$MACOS/UAMCUBridge"
chmod +x "$MACOS/UAMCUBridge"

# Copy Python bridge scripts and AppIcon into Resources
cp "$DIR/bridge.py" "$RESOURCES/"
cp "$DIR/coremidi_adapter.py" "$RESOURCES/"
cp "$DIR/mcu_engine.py" "$RESOURCES/"
cp "$DIR/uad_client.py" "$RESOURCES/"
cp "$DIR/uad_curve.py" "$RESOURCES/"
if [ -f "$DIR/app_build/AppIcon.icns" ]; then
    cp "$DIR/app_build/AppIcon.icns" "$RESOURCES/"
fi

# Create PkgInfo
echo -n "APPL????" > "$CONTENTS/PkgInfo"

# Create Info.plist with LSUIElement=true (Menu Bar app, no Dock clutter)
cat << 'EOF' > "$CONTENTS/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>UAMCUBridge</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.echonav.uamcubridge</string>
    <key>CFBundleName</key>
    <string>UA-MCU Bridge</string>
    <key>CFBundleDisplayName</key>
    <string>UA-MCU Bridge</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

echo "==> Successfully created $APP_NAME at $APP_DIR"
rm -rf "/Applications/$APP_NAME"
cp -R "$APP_DIR" "/Applications/$APP_NAME"
echo "==> Installed $APP_NAME into /Applications"
