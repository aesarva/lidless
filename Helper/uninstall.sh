#!/bin/bash
# Usage: uninstall.sh <marker_path>   (runs as root)
set -euo pipefail

MARKER=${1:?usage: uninstall.sh <marker_path>}

if [ -e "$MARKER" ]; then
    /usr/bin/pmset -a disablesleep 0
    rm -f "$MARKER"
fi
launchctl bootout system/app.wakeup.watchdog 2>/dev/null || true
rm -f /Library/LaunchDaemons/app.wakeup.watchdog.plist \
      /Library/PrivilegedHelperTools/app.wakeup.watchdog.sh \
      /etc/sudoers.d/wakeup
