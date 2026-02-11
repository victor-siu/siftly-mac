#!/bin/bash
set -e

# SiftlyHelper Uninstaller
# Removes the privileged helper daemon and all related files.
#
# Usage: sudo ./scripts/uninstall_helper.sh

HELPER_NAME="com.siftly.helper"
INSTALL_PATH="/Library/PrivilegedHelperTools/$HELPER_NAME"
PLIST_PATH="/Library/LaunchDaemons/$HELPER_NAME.plist"
SOCKET_PATH="/var/run/siftly-helper.sock"
LOG_PATH="/var/log/siftly-helper.log"

# Check for root
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run with sudo:"
    echo "  sudo $0"
    exit 1
fi

echo "Uninstalling SiftlyHelper..."

# Stop and unload daemon
if launchctl list "$HELPER_NAME" &>/dev/null; then
    echo "Stopping helper daemon..."
    launchctl bootout system/"$HELPER_NAME" 2>/dev/null || true
fi

# Remove files
for f in "$INSTALL_PATH" "$PLIST_PATH" "$SOCKET_PATH" "$LOG_PATH"; do
    if [ -e "$f" ]; then
        echo "Removing $f"
        rm -f "$f"
    fi
done

echo ""
echo "✅ SiftlyHelper uninstalled."
echo "   The Siftly app will fall back to asking for your password"
echo "   when binding privileged ports."
