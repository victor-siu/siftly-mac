#!/bin/bash
set -e

# SiftlyHelper Installer
# Installs the privileged helper daemon so dnsproxy can bind port 53
# without requiring a password prompt every time.
#
# Usage: sudo ./scripts/install_helper.sh

HELPER_NAME="com.siftly.helper"
INSTALL_PATH="/Library/PrivilegedHelperTools/$HELPER_NAME"
PLIST_PATH="/Library/LaunchDaemons/$HELPER_NAME.plist"

# Ensure we run from repo root
cd "$(dirname "$0")/.."

HELPER_BINARY=".build/release/SiftlyHelper"

# Check for root
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run with sudo:"
    echo "  sudo $0"
    exit 1
fi

# Build the helper if needed
if [ ! -f "$HELPER_BINARY" ]; then
    echo "Building SiftlyHelper..."
    swift build -c release --product SiftlyHelper
fi

if [ ! -f "$HELPER_BINARY" ]; then
    echo "Error: Failed to build SiftlyHelper"
    exit 1
fi

# Stop existing daemon if running
if launchctl list "$HELPER_NAME" &>/dev/null; then
    echo "Stopping existing helper daemon..."
    launchctl bootout system/"$HELPER_NAME" 2>/dev/null || true
fi

# Install binary
echo "Installing helper binary to $INSTALL_PATH..."
mkdir -p /Library/PrivilegedHelperTools
cp "$HELPER_BINARY" "$INSTALL_PATH"
chown root:wheel "$INSTALL_PATH"
chmod 755 "$INSTALL_PATH"

# Create LaunchDaemon plist
echo "Installing LaunchDaemon plist..."
cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"\>
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$HELPER_NAME</string>
    <key>Program</key>
    <string>$INSTALL_PATH</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>/var/log/siftly-helper.log</string>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
EOF

chown root:wheel "$PLIST_PATH"
chmod 644 "$PLIST_PATH"

# Load the daemon
echo "Loading helper daemon..."
launchctl bootstrap system "$PLIST_PATH"

# Verify
sleep 1
if launchctl list "$HELPER_NAME" &>/dev/null; then
    echo ""
    echo "✅ SiftlyHelper installed and running!"
    echo ""
    echo "   Helper binary: $INSTALL_PATH"
    echo "   Plist:         $PLIST_PATH"
    echo "   Socket:        /var/run/siftly-helper.sock"
    echo "   Log:           /var/log/siftly-helper.log"
    echo ""
    echo "   The Siftly app will now start dnsproxy on port 53"
    echo "   without asking for your password."
    echo ""
    echo "   To uninstall: sudo ./scripts/uninstall_helper.sh"
else
    echo ""
    echo "❌ Failed to start helper daemon. Check /var/log/siftly-helper.log"
    exit 1
fi
