#!/bin/bash
# Usage: install.sh <sudoers_rule_text> <user> <helper_dir>   (runs as root)
# $1 is the rule TEXT itself, never a path: nothing user-writable is read.
# Exit codes: 2 visudo rejected rule, 3 sudoers lacks includedir, 4 bad user, 5 unsafe marker dir, 64 usage.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

if [ "$#" -ne 3 ]; then
    echo "usage: install.sh <sudoers_rule_text> <user> <helper_dir>" >&2
    exit 64
fi
RULE=$1
USER_NAME=$2
HELPER_DIR=$3

# Validate the user name before any privileged step.
if [ "$USER_NAME" = "ALL" ] || ! [[ "$USER_NAME" =~ ^[A-Za-z_][A-Za-z0-9_.-]{0,31}$ ]]; then
    echo "invalid user name" >&2
    exit 4
fi

# /Users/Shared is world-writable: refuse a pre-planted symlink or foreign-owned
# directory before root chowns anything (exit 5).
SHARED_DIR=/Users/Shared/WakeUp
if [ -L "$SHARED_DIR" ]; then
    echo "$SHARED_DIR is a symlink" >&2
    exit 5
fi
if [ -e "$SHARED_DIR" ]; then
    if [ ! -d "$SHARED_DIR" ]; then
        echo "$SHARED_DIR is not a directory" >&2
        exit 5
    fi
    owner=$(stat -f %u "$SHARED_DIR")
    if [ "$owner" != 0 ] && [ "$owner" != "$(id -u "$USER_NAME")" ]; then
        echo "$SHARED_DIR has unexpected owner" >&2
        exit 5
    fi
fi

umask 077
tmp=$(mktemp /private/tmp/wakeup.XXXXXX)
trap 'rm -f "$tmp"' EXIT
printf '%s' "$RULE" > "$tmp"

if ! grep -Eq '^[#@]includedir /private/etc/sudoers.d' /etc/sudoers; then
    echo "/etc/sudoers does not include /private/etc/sudoers.d" >&2
    exit 3
fi

if ! visudo -cf "$tmp" >/dev/null; then
    echo "sudoers rule failed validation" >&2
    exit 2
fi

install -d -m 0755 -o root -g wheel /Library/PrivilegedHelperTools /Library/LaunchDaemons
install -m 0755 -o root -g wheel "$HELPER_DIR/watchdog.sh" /Library/PrivilegedHelperTools/app.wakeup.watchdog.sh
install -m 0644 -o root -g wheel "$HELPER_DIR/app.wakeup.watchdog.plist" /Library/LaunchDaemons/app.wakeup.watchdog.plist

launchctl bootout system/app.wakeup.watchdog 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/app.wakeup.watchdog.plist

mkdir -p "$SHARED_DIR"
chown -h "$USER_NAME" "$SHARED_DIR"

# Sudoers rule goes in LAST: it must never exist without the watchdog safety net.
install -m 0440 -o root -g wheel "$tmp" /etc/sudoers.d/wakeup
