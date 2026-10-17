#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

MARKER=${LIDLESS_MARKER:-/Users/Shared/Lidless/lid-mode.marker}
PROC=${LIDLESS_PROCESS_NAME:-Lidless}
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

# Only the marker owner's own Lidless counts: another user's copy (or any process that
# happens to share the name) must not keep sleep disabled after this user's app is gone.
OWNER=$(stat -f %u "$MARKER" 2>/dev/null || true)

if [ -n "$OWNER" ] && ! pgrep -x -U "$OWNER" "$PROC" >/dev/null; then
    if [ "$DRY_RUN" = 1 ]; then
        echo "reset"
    else
        /usr/bin/pmset -a disablesleep 0
    fi
    rm -f "$MARKER"
elif [ "$DRY_RUN" = 1 ]; then
    echo "noop"
fi
