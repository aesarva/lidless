#!/bin/bash
set -euo pipefail

DIR=$(cd "$(dirname "$0")/.." && pwd)
WD="$DIR/watchdog.sh"
M=$(mktemp)
trap 'rm -f "$M"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

out=$(WAKEUP_MARKER="$M" WAKEUP_PROCESS_NAME="wakeup-no-such-proc-$$" bash "$WD" --dry-run)
[ "$out" = "reset" ] || fail "expected reset, got '$out'"
[ ! -e "$M" ] || fail "marker should be removed"

# A live process we own (launchd is not visible to pgrep in sandboxes).
sleep 30 &
SLEEPER=$!
trap 'kill "$SLEEPER" 2>/dev/null; wait "$SLEEPER" 2>/dev/null || true; rm -f "$M"' EXIT
touch "$M"
out=$(WAKEUP_MARKER="$M" WAKEUP_PROCESS_NAME="sleep" bash "$WD" --dry-run)
[ "$out" = "noop" ] || fail "expected noop (process alive), got '$out'"
[ -e "$M" ] || fail "marker should remain"

rm -f "$M"
out=$(WAKEUP_MARKER="$M" WAKEUP_PROCESS_NAME="wakeup-no-such-proc-$$" bash "$WD" --dry-run)
[ "$out" = "noop" ] || fail "expected noop (no marker), got '$out'"

# install.sh must reject bad user names (exit 4) before any privileged step.
long=$(printf 'a%.0s' {1..40})
for bad in 'ALL' 'a b' 'x;rm' '' '-x' '1abc' "$long"; do
    rc=0
    bash "$DIR/install.sh" "rule" "$bad" /nonexistent >/dev/null 2>&1 || rc=$?
    [ "$rc" = 4 ] || fail "user '$bad' expected exit 4, got $rc"
done

echo PASS
