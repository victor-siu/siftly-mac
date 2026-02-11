#!/bin/bash
set -e

APP_NAME="Siftly"
BUILD_DIR=".build/release"
APP_BUNDLE="$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

# Ensure we run from repo root
cd "$(dirname "$0")/.."

echo "Building $APP_NAME..."
swift build -c release

echo "Creating App Bundle Structure..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

echo "Copying Executable..."
cp "$BUILD_DIR/$APP_NAME" "$MACOS_DIR/"

echo "Copying SiftlyHelper..."
cp "$BUILD_DIR/SiftlyHelper" "$MACOS_DIR/"

echo "Bundling dnsproxy..."
# Look for dnsproxy binary in common locations
DNSPROXY=""
for candidate in \
    "./dnsproxy" \
    "/usr/local/bin/dnsproxy" \
    "/opt/homebrew/bin/dnsproxy" \
    "$HOME/go/bin/dnsproxy"; do
    if [ -f "$candidate" ]; then
        DNSPROXY="$candidate"
        break
    fi
done

if [ -n "$DNSPROXY" ]; then
    cp "$DNSPROXY" "$MACOS_DIR/"
    echo "  Bundled dnsproxy from $DNSPROXY"
else
    echo ""
    echo "⚠️  dnsproxy binary not found. The app will look for it at runtime."
    echo "   To bundle it, place the binary in the repo root and re-run this script."
    echo "   Download from: https://github.com/AdguardTeam/dnsproxy/releases"
    echo ""
fi

echo "Creating Info.plist..."
cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"\>
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.siftly.app</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "Signing App Bundle..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo ""
echo "✅ $APP_BUNDLE created!"
echo "   Move to /Applications:  mv $APP_BUNDLE /Applications/"
