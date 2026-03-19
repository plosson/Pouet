#!/bin/bash
# Pouet Uninstaller
# Removes the driver, app, and restarts coreaudiod.

HAL_DIR="/Library/Audio/Plug-Ins/HAL"
DRIVER="$HAL_DIR/Pouet.driver"
APP="/Applications/Pouet.app"
UNINSTALLER="/Applications/Uninstall Pouet.app"

# Check if driver is installed
if [ ! -d "$DRIVER" ] && [ ! -d "$APP" ]; then
    osascript -e 'display dialog "Pouet is not installed." buttons {"OK"} default button "OK" with icon caution with title "Pouet Uninstaller"'
    exit 0
fi

# Confirm with user
RESPONSE=$(osascript -e 'display dialog "This will remove the Pouet driver and app.\n\nYour audio output selection will be preserved." buttons {"Cancel", "Uninstall"} default button "Cancel" cancel button "Cancel" with icon caution with title "Pouet Uninstaller"' 2>&1) || exit 0

# Quit Pouet app if running
killall Pouet 2>/dev/null || true
sleep 0.5

# Build the privileged commands
CMDS=""
[ -d "$DRIVER" ] && CMDS="$CMDS rm -rf '$DRIVER';"
[ -d "$APP" ] && CMDS="$CMDS rm -rf '$APP';"
[ -d "$UNINSTALLER" ] && CMDS="$CMDS rm -rf '$UNINSTALLER';"

# Restart coreaudiod
CMDS="$CMDS launchctl kickstart -kp system/com.apple.audio.coreaudiod 2>/dev/null || killall coreaudiod 2>/dev/null || true;"

# Run with admin privileges
osascript -e "do shell script \"$CMDS\" with administrator privileges" 2>/dev/null

if [ $? -eq 0 ]; then
    osascript -e 'display dialog "Pouet has been uninstalled successfully." buttons {"OK"} default button "OK" with title "Pouet Uninstaller"'
else
    osascript -e 'display dialog "Uninstall failed. Please try again." buttons {"OK"} default button "OK" with icon stop with title "Pouet Uninstaller"'
fi
