#!/bin/bash
# Usage: uninstall.sh <marker_path>   (runs as root)
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

MARKER=${1:?usage: uninstall.sh <marker_path>}

if [ -e "$MARKER" ]; then
    /usr/bin/pmset -a disablesleep 0
    rm -f "$MARKER"
fi
launchctl bootout system/app.lidless.watchdog 2>/dev/null || true
rm -f /Library/LaunchDaemons/app.lidless.watchdog.plist \
      /Library/PrivilegedHelperTools/app.lidless.watchdog.sh \
      /etc/sudoers.d/lidless
