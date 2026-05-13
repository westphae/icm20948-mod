#!/usr/bin/env bash
# Smoke test for the icm20948 driver. Builds, loads, binds to I2C, reads
# sysfs raw values, exercises buffered capture via iio-trig-hrtimer, cleans up.
#
# Assumes:
#  - kernel build tree available at /lib/modules/$(uname -r)/build
#  - I2C bus 1 with ICM-20948 at 0x68 (override via I2C_BUS / I2C_ADDR)
#  - device is held STATIONARY during the test (gyro near zero, accel near 1g)
#
# Exit 0 on success, non-zero on any failure. Cleans up on every exit path.

set -euo pipefail

I2C_BUS="${I2C_BUS:-1}"
I2C_ADDR="${I2C_ADDR:-0x68}"
TRIG_NAME="${TRIG_NAME:-icm20948-smoke}"
TRIG_HZ="${TRIG_HZ:-100}"
CAPTURE_SAMPLES="${CAPTURE_SAMPLES:-50}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"

MOD_LOADED=0
DEV_BOUND=0
TRIG_CREATED=0
BUFFER_ENABLED=0
IIO_DEV=""
TRIG_IDX=""
CAPTURE_FILE="$(mktemp)"

log()  { printf '\033[36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[32m[ OK ]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
    local rc=$?
    set +e
    log "cleanup (rc=$rc)"

    if [ "$BUFFER_ENABLED" = 1 ] && [ -n "$IIO_DEV" ]; then
        echo 0 | $SUDO tee "$IIO_DEV/buffer/enable" >/dev/null
    fi
    if [ -n "$IIO_DEV" ] && [ -e "$IIO_DEV/trigger/current_trigger" ]; then
        echo '' | $SUDO tee "$IIO_DEV/trigger/current_trigger" >/dev/null 2>&1
    fi
    if [ "$TRIG_CREATED" = 1 ] && [ -n "${CONFIGFS:-}" ]; then
        $SUDO rmdir "$CONFIGFS/iio/triggers/hrtimer/$TRIG_NAME" 2>/dev/null
    fi
    if [ "$DEV_BOUND" = 1 ]; then
        echo "$I2C_ADDR" | $SUDO tee "/sys/bus/i2c/devices/i2c-$I2C_BUS/delete_device" >/dev/null 2>&1
    fi
    if [ "$MOD_LOADED" = 1 ]; then
        $SUDO rmmod icm20948 2>/dev/null
    fi
    rm -f "$CAPTURE_FILE"
    exit $rc
}
trap cleanup EXIT INT TERM

# Pre-flight: clean stale state from a previous aborted run
preflight() {
    log "pre-flight cleanup"
    # If the module is already loaded from a prior run, take ownership
    if lsmod | grep -q '^icm20948 '; then
        # Try to unbind first (best effort), then unload
        local bus_path="/sys/bus/i2c/devices/i2c-$I2C_BUS"
        if [ -d "$bus_path/$I2C_BUS-00$(printf '%02x' "$I2C_ADDR")" ]; then
            echo "$I2C_ADDR" | $SUDO tee "$bus_path/delete_device" >/dev/null 2>&1
        fi
        $SUDO rmmod icm20948 2>/dev/null || true
    fi
    # Stale trigger
    if [ -n "${CONFIGFS:-}" ] && [ -d "$CONFIGFS/iio/triggers/hrtimer/$TRIG_NAME" ]; then
        $SUDO rmdir "$CONFIGFS/iio/triggers/hrtimer/$TRIG_NAME" 2>/dev/null || true
    fi
}

find_configfs() {
    for p in /sys/kernel/config /config; do
        if [ -d "$p/iio" ]; then CONFIGFS="$p"; return 0; fi
    done
    # Not mounted yet — try to mount it
    if $SUDO mount -t configfs none /sys/kernel/config 2>/dev/null; then
        CONFIGFS=/sys/kernel/config
        return 0
    fi
    return 1
}

build() {
    log "make"
    ( cd "$REPO_DIR" && make -s ) >/tmp/icm20948-build.log 2>&1 \
        || { cat /tmp/icm20948-build.log; die "make failed (log: /tmp/icm20948-build.log)"; }
    [ -f "$REPO_DIR/icm20948.ko" ] || die "icm20948.ko not produced"
    ok "icm20948.ko built"
}

load_and_bind() {
    log "insmod + bind $I2C_ADDR on i2c-$I2C_BUS"
    # insmod doesn't resolve deps; pre-load the IIO core via modprobe so
    # icm20948 finds its exports (industrialio, *-buffer, *-triggered-buffer).
    $SUDO modprobe industrialio-triggered-buffer 2>/dev/null || true
    $SUDO insmod "$REPO_DIR/icm20948.ko" || die "insmod failed (dmesg | tail)"
    MOD_LOADED=1

    echo "icm20948 $I2C_ADDR" | $SUDO tee "/sys/bus/i2c/devices/i2c-$I2C_BUS/new_device" >/dev/null \
        || die "i2c new_device failed"
    DEV_BOUND=1

    # Wait for iio device to appear (probe may take a moment for mag init)
    local d
    for _ in $(seq 1 30); do
        for d in /sys/bus/iio/devices/iio:device*; do
            [ -d "$d" ] || continue
            if [ "$(cat "$d/name" 2>/dev/null)" = "icm20948" ]; then
                IIO_DEV="$d"; break 2
            fi
        done
        sleep 0.1
    done
    [ -n "$IIO_DEV" ] || die "icm20948 iio device did not appear within 3s (check dmesg)"
    ok "found $IIO_DEV"
}

read_raw() { cat "$IIO_DEV/in_${1}_raw"; }
abs()      { local v="$1"; echo $(( v < 0 ? -v : v )); }

check_sysfs() {
    log "sysfs raw reads (device must be stationary)"
    local ax ay az gx gy gz mx my mz tt
    ax=$(read_raw accel_x); ay=$(read_raw accel_y); az=$(read_raw accel_z)
    gx=$(read_raw anglvel_x); gy=$(read_raw anglvel_y); gz=$(read_raw anglvel_z)
    mx=$(read_raw magn_x); my=$(read_raw magn_y); mz=$(read_raw magn_z)
    tt=$(read_raw temp)
    log "  accel = $ax $ay $az"
    log "  gyro  = $gx $gy $gz"
    log "  mag   = $mx $my $mz"
    log "  temp  = $tt (raw)"

    # Accel: default ±2g → 16384 LSB/g, expect magnitude ≈ 1g (±30%)
    local amag
    amag=$(awk -v x="$ax" -v y="$ay" -v z="$az" 'BEGIN { print int(sqrt(x*x+y*y+z*z)) }')
    [ "$amag" -ge 11000 ] && [ "$amag" -le 21300 ] \
        || die "accel magnitude $amag LSB outside [11000,21300]; sensor not stationary in 1g?"
    ok "accel magnitude ≈ ${amag} LSB (expect ~16384 = 1g)"

    # Gyro: default ±250 dps → 131 LSB/dps. Stationary expectation: <1000 LSB (~7.6 dps)
    local ag
    for g in "$gx" "$gy" "$gz"; do
        ag=$(abs "$g")
        [ "$ag" -lt 1000 ] || die "gyro axis = $g LSB exceeds 1000; not stationary"
    done
    ok "gyro axes within ±1000 LSB ($gx, $gy, $gz)"

    # Mag: 0.15 µT/LSB, Earth field ~20–65 µT → ~130–430 LSB textbook.
    # In practice nearby gear (WiFi modules, motors, ferrous mounts) easily
    # pushes magnitude up to ~600 LSB. Lower bound at 100 catches the
    # pre-fix `mag = 0,0,0` regression with margin; upper bound at 2000
    # tolerates a noisy environment while still flagging gross calibration
    # or scale-decode regressions.
    local mmag
    mmag=$(awk -v x="$mx" -v y="$my" -v z="$mz" 'BEGIN { print int(sqrt(x*x+y*y+z*z)) }')
    [ "$mmag" -ge 100 ] && [ "$mmag" -le 2000 ] \
        || die "mag magnitude $mmag LSB outside [100,2000]; check mag init (was the AK09916 left in power-down?)"
    ok "mag magnitude ≈ ${mmag} LSB (expect ~130–430 LSB textbook, often higher with nearby gear)"

    # Temp: T_C = raw / 333.87 + 21. Expect 10..60 °C.
    local tc
    tc=$(awk -v r="$tt" 'BEGIN { printf("%d", r/333.87 + 21) }')
    [ "$tc" -ge 10 ] && [ "$tc" -le 60 ] || die "temp ${tc}°C outside [10,60]"
    ok "temp ≈ ${tc}°C"
}

setup_trigger() {
    log "set up hrtimer trigger @ ${TRIG_HZ} Hz"
    # Capture stderr so a stale `modules.dep` reference (files that show up
    # in dep but aren't on disk — common when /root/linux hasn't been
    # `modules_install`'d) doesn't poison the test output. Surface stderr
    # only if modprobe actually fails.
    local mp_out
    mp_out=$($SUDO modprobe iio-trig-hrtimer 2>&1) \
        || die "modprobe iio-trig-hrtimer failed: ${mp_out:-no output}"
    find_configfs || die "configfs not available; can't create hrtimer trigger"

    $SUDO mkdir -p "$CONFIGFS/iio/triggers/hrtimer/$TRIG_NAME" \
        || die "could not create hrtimer trigger $TRIG_NAME"
    TRIG_CREATED=1

    local t
    for t in /sys/bus/iio/devices/trigger*; do
        if [ "$(cat "$t/name" 2>/dev/null)" = "$TRIG_NAME" ]; then
            TRIG_IDX="$(basename "$t" | sed 's/trigger//')"
            break
        fi
    done
    [ -n "$TRIG_IDX" ] || die "hrtimer trigger not exposed under /sys/bus/iio/devices"

    echo "$TRIG_HZ" | $SUDO tee "/sys/bus/iio/devices/trigger${TRIG_IDX}/sampling_frequency" >/dev/null \
        || die "could not set trigger sampling_frequency"
    ok "trigger ${TRIG_NAME} ready at /sys/bus/iio/devices/trigger${TRIG_IDX}"
}

capture_buffer() {
    log "capture $CAPTURE_SAMPLES samples via buffered IIO"

    echo "$TRIG_NAME" | $SUDO tee "$IIO_DEV/trigger/current_trigger" >/dev/null \
        || die "failed to assign trigger"

    # available_scan_masks in the driver forces all data channels + timestamp on
    local f
    for f in "$IIO_DEV/scan_elements/"*_en; do
        [ -e "$f" ] || continue
        echo 1 | $SUDO tee "$f" >/dev/null
    done

    echo "$CAPTURE_SAMPLES" | $SUDO tee "$IIO_DEV/buffer/length" >/dev/null
    echo 1 | $SUDO tee "$IIO_DEV/buffer/enable" >/dev/null \
        || die "failed to enable buffer"
    BUFFER_ENABLED=1

    local dev_file="/dev/$(basename "$IIO_DEV")"
    # 32 bytes per record: 6+6+2+6 = 20 sensor, 4 pad, 8 timestamp
    $SUDO timeout 3 dd if="$dev_file" of="$CAPTURE_FILE" bs=32 count="$CAPTURE_SAMPLES" \
        iflag=fullblock status=none 2>/dev/null || true

    echo 0 | $SUDO tee "$IIO_DEV/buffer/enable" >/dev/null
    BUFFER_ENABLED=0

    local fsz recs
    fsz=$(stat -c%s "$CAPTURE_FILE")
    recs=$((fsz / 32))
    [ "$recs" -ge $((CAPTURE_SAMPLES / 2)) ] \
        || die "captured $recs records (${fsz}B), expected ≥ $((CAPTURE_SAMPLES/2))"
    ok "captured $recs records ($fsz bytes)"

    python3 - "$CAPTURE_FILE" "$TRIG_HZ" <<'PYEOF'
import sys, struct
path, hz = sys.argv[1], int(sys.argv[2])
data = open(path, "rb").read()
rec = 32
n = len(data) // rec
ts = [struct.unpack_from("<q", data, i*rec + 24)[0] for i in range(n)]
for i in range(1, n):
    if ts[i] <= ts[i-1]:
        sys.exit(f"timestamps not monotonic at i={i}: {ts[i-1]} -> {ts[i]}")
expected_ns = 1_000_000_000 // hz
diffs = [ts[i] - ts[i-1] for i in range(1, n)]
avg = sum(diffs) / len(diffs)
if not (expected_ns * 0.5 <= avg <= expected_ns * 1.5):
    sys.exit(f"avg interval {avg:.0f}ns, expected ~{expected_ns}ns (±50%)")
print(f"  timestamps monotonic over {n} samples")
print(f"  avg interval {avg/1e6:.2f}ms (expected {expected_ns/1e6:.2f}ms)")
PYEOF
    ok "buffered capture timestamps healthy"
}

main() {
    find_configfs || true   # ok if not yet mounted; setup_trigger will mount
    preflight
    build
    load_and_bind
    check_sysfs
    setup_trigger
    capture_buffer
    log "all smoke tests passed"
}

main "$@"
