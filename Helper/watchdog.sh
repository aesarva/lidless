#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

MARKER=${WAKEUP_MARKER:-/Users/Shared/WakeUp/lid-mode.marker}
PROC=${WAKEUP_PROCESS_NAME:-WakeUp}
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

if [ -e "$MARKER" ] && ! pgrep -x "$PROC" >/dev/null; then
    if [ "$DRY_RUN" = 1 ]; then
        echo "reset"
    else
        /usr/bin/pmset -a disablesleep 0
    fi
    rm -f "$MARKER"
elif [ "$DRY_RUN" = 1 ]; then
    echo "noop"
fi
