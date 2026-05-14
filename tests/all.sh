#!/usr/bin/env bash
# Runs every regression test in tests/, reports a pass/fail summary,
# and exits non-zero if any failed. Each test sets up and tears down
# its own state, so they're safe to run in sequence.
#
# Device must be held STATIONARY for the whole run (~40 s).

set -uo pipefail
cd "$(dirname "$0")"

TESTS=(sysfs_stream.sh buffered_stream.sh consistency.sh bind_cycle.sh)

PASSED=0
FAILED=()
LOG_DIR="$(mktemp -d)"

for t in "${TESTS[@]}"; do
    printf "── %-22s " "$t"
    if sudo ./"$t" >"$LOG_DIR/$t.log" 2>&1; then
        PASSED=$((PASSED + 1))
        printf '\033[32m[ OK ]\033[0m\n'
    else
        FAILED+=("$t")
        printf '\033[31m[FAIL]\033[0m\n'
        sed 's/^/    /' "$LOG_DIR/$t.log" | tail -15
    fi
done

echo "────────────────────────────────────"
printf "passed: %d   failed: %d\n" "$PASSED" "${#FAILED[@]}"
if [ ${#FAILED[@]} -ne 0 ]; then
    printf "logs:   %s\n" "$LOG_DIR"
    exit 1
fi
rm -rf "$LOG_DIR"
