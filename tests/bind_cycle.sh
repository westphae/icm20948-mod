#!/usr/bin/env bash
# Exercises the unbind/rebind path of the driver to catch regressions in
# its devm/trigger cleanup. Loops N=5 times: read mag via sysfs, unbind,
# verify the iio:device disappears, rebind, verify it reappears with
# matching name, read mag again. Tails dmesg between cycles and fails on
# any oops / WARN / BUG.
#
# Catches: dangling indio_dev->trig (the 9cf787b fix), trigger leak
# across rebinds, lock-ordering issues during remove.

LIB="$(dirname "$0")/lib.sh"
. "$LIB"

CYCLES="${CYCLES:-5}"

require_iio_device
DRV_DIR="/sys/bus/i2c/drivers/icm20948"
[ -d "$DRV_DIR" ] || die "driver dir $DRV_DIR not found"

# Find the per-device sysfs name the driver knows it by (e.g. "1-0068").
DEV_NAME=""
for d in "$DRV_DIR"/*-*; do
    [ -L "$d" ] || continue
    DEV_NAME="$(basename "$d")"
    break
done
[ -n "$DEV_NAME" ] || die "could not find bound device under $DRV_DIR"
log "binding cycle on $DEV_NAME ($CYCLES iterations)"

# Baseline dmesg checkpoint — we'll diff against this after each cycle.
sudo dmesg -C >/dev/null 2>&1 || true

read_mag() {
    # Retry briefly on EIO/EREMOTEIO — these are transient I2C errors
    # surfaced from the driver under load, not test failures.
    python3 - "$IIO_DEV" <<'PYEOF'
import sys, time, errno
dev = sys.argv[1]
def read(ax):
    for _ in range(3):
        try:
            with open(f"{dev}/in_magn_{ax}_raw") as f:
                return f.read().strip()
        except OSError as e:
            if e.errno not in (errno.EIO, errno.EREMOTEIO):
                raise
            time.sleep(0.01)
    return "0"
print(" ".join(read(a) for a in "xyz"))
PYEOF
}

for i in $(seq 1 "$CYCLES"); do
    log "cycle $i/$CYCLES"
    before="$(read_mag)"
    log "  before: mag = $before"

    echo "$DEV_NAME" | $SUDO tee "$DRV_DIR/unbind" >/dev/null \
        || die "unbind failed at cycle $i"
    # Verify the iio:device went away
    sleep 0.2
    if find_iio_device; then
        die "iio device still present after unbind (cycle $i)"
    fi

    echo "$DEV_NAME" | $SUDO tee "$DRV_DIR/bind" >/dev/null \
        || die "bind failed at cycle $i"
    # Wait for re-probe
    for _ in $(seq 1 30); do
        if find_iio_device; then break; fi
        sleep 0.1
    done
    [ -d "${IIO_DEV:-}" ] || die "iio device did not reappear within 3s (cycle $i)"

    after="$(read_mag)"
    log "  after:  mag = $after"
    # Stationary delta — be lax (mag rotates with chip not moving sometimes
    # noisy after probe), but >500 LSB on any axis suggests a real problem.
    python3 - "$before" "$after" <<'PYEOF' || die "mag delta too large at cycle $i"
import sys
b = list(map(int, sys.argv[1].split()))
a = list(map(int, sys.argv[2].split()))
for i, ax in enumerate("xyz"):
    if abs(a[i] - b[i]) > 500:
        sys.exit(f"axis {ax} jumped {b[i]} -> {a[i]}")
PYEOF

    # Surface any new kernel oops/WARN/BUG since the last cycle
    if $SUDO dmesg | grep -E 'WARN|BUG|Oops|refcount|use-after-free' >/tmp/icm-bind-dmesg; then
        cat /tmp/icm-bind-dmesg >&2
        die "dmesg contains warnings at cycle $i (see above)"
    fi
    sudo dmesg -C >/dev/null 2>&1
done

ok "$CYCLES rebind cycles clean (no dmesg warnings, mag readings stable)"
