# Shared helpers for the icm20948 test scripts. Sourced, not executed.
#
# Provides: log / ok / die for output; configfs lookup + hrtimer trigger
# create/teardown; find_iio_device / require_module_loaded for setup; a
# cleanup_stack trap helper so each test can register tear-down actions
# inline next to their setup. Mirrors smoke.sh's style but reusable.

set -euo pipefail

I2C_BUS="${I2C_BUS:-1}"
I2C_ADDR="${I2C_ADDR:-0x68}"
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"

log()  { printf '\033[36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[32m[ OK ]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

# Cleanup stack: tests register tear-down commands via `defer "..."` next
# to the corresponding setup. trap fires the stack in LIFO order so the
# most recently set up resource is released first.
_DEFERRED=()
defer() { _DEFERRED+=("$*"); }
_run_deferred() {
    local rc=$? i
    set +e
    for ((i=${#_DEFERRED[@]}-1; i>=0; i--)); do
        eval "${_DEFERRED[i]}" 2>/dev/null
    done
    exit $rc
}
trap _run_deferred EXIT INT TERM

find_configfs() {
    for p in /sys/kernel/config /config; do
        if [ -d "$p/iio" ]; then CONFIGFS="$p"; return 0; fi
    done
    if $SUDO mount -t configfs none /sys/kernel/config 2>/dev/null; then
        CONFIGFS=/sys/kernel/config
        return 0
    fi
    return 1
}

# create_hrtimer_trigger NAME HZ — sets TRIG_IDX (the trigger's iio index)
create_hrtimer_trigger() {
    local name="$1" hz="$2"
    $SUDO modprobe iio-trig-hrtimer >/dev/null 2>&1 || true
    find_configfs || die "configfs not available; can't create hrtimer trigger"
    if [ ! -d "$CONFIGFS/iio/triggers/hrtimer/$name" ]; then
        $SUDO mkdir -p "$CONFIGFS/iio/triggers/hrtimer/$name" \
            || die "could not create hrtimer trigger $name"
        defer "$SUDO rmdir '$CONFIGFS/iio/triggers/hrtimer/$name'"
    fi
    local t
    for t in /sys/bus/iio/devices/trigger*; do
        if [ "$(cat "$t/name" 2>/dev/null)" = "$name" ]; then
            TRIG_IDX="$(basename "$t" | sed 's/trigger//')"
            break
        fi
    done
    [ -n "${TRIG_IDX:-}" ] || die "hrtimer trigger $name not exposed under /sys/bus/iio/devices"
    echo "$hz" | $SUDO tee "/sys/bus/iio/devices/trigger${TRIG_IDX}/sampling_frequency" >/dev/null \
        || die "could not set trigger sampling_frequency"
}

# Sets IIO_DEV to the /sys/bus/iio/devices/iio:deviceN path whose `name`
# attribute is "icm20948". Returns non-zero if not found.
find_iio_device() {
    local d
    for d in /sys/bus/iio/devices/iio:device*; do
        [ -d "$d" ] || continue
        if [ "$(cat "$d/name" 2>/dev/null)" = "icm20948" ]; then
            IIO_DEV="$d"
            return 0
        fi
    done
    return 1
}

# Force the IIO device into a clean baseline (no buffer, no trigger,
# no scan elements enabled). Tests that don't use buffered capture
# leave it that way; tests that do enable what they need and rely on
# defer to roll back. Idempotent.
reset_iio_state() {
    [ -n "${IIO_DEV:-}" ] || return 0
    echo 0 | $SUDO tee "$IIO_DEV/buffer/enable" >/dev/null 2>&1 || true
    sleep 0.1
    echo '' | $SUDO tee "$IIO_DEV/trigger/current_trigger" >/dev/null 2>&1 || true
    local f
    for f in "$IIO_DEV/scan_elements/"*_en; do
        [ -e "$f" ] || continue
        echo 0 | $SUDO tee "$f" >/dev/null 2>&1 || true
    done
}

# Ensures an icm20948 IIO device is present. If not, builds and binds
# the driver. Idempotent. Sets IIO_DEV.
require_iio_device() {
    if find_iio_device; then return 0; fi
    log "no icm20948 IIO device found; building + binding"
    ( cd "$REPO_DIR" && make -s ) >/tmp/icm20948-build.log 2>&1 \
        || { cat /tmp/icm20948-build.log; die "make failed"; }
    if ! lsmod | grep -q '^icm20948 '; then
        $SUDO modprobe industrialio-triggered-buffer 2>/dev/null || true
        $SUDO insmod "$REPO_DIR/icm20948.ko" || die "insmod failed"
        defer "$SUDO rmmod icm20948 2>/dev/null"
    fi
    if [ ! -d "/sys/bus/i2c/devices/i2c-$I2C_BUS/$I2C_BUS-00$(printf '%02x' "$I2C_ADDR")" ]; then
        echo "icm20948 $I2C_ADDR" | $SUDO tee "/sys/bus/i2c/devices/i2c-$I2C_BUS/new_device" >/dev/null \
            || die "i2c new_device failed"
        defer "echo $I2C_ADDR | $SUDO tee /sys/bus/i2c/devices/i2c-$I2C_BUS/delete_device >/dev/null 2>&1"
    fi
    local i
    for i in $(seq 1 30); do
        if find_iio_device; then return 0; fi
        sleep 0.1
    done
    die "icm20948 iio device did not appear within 3s"
}
