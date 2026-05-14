#!/usr/bin/env bash
# Stability test for the buffered IIO path. Streams N=500 samples through
# an hrtimer trigger and decodes the raw frames, asserting:
#   - No zero-mag glitches (regression test for the aux-master NACK
#     filter; before the fix ~1% of samples came back as (0,0,0))
#   - Per-axis mag spread within sensor noise bounds (regression test
#     for the BE/LE swap bug — byte-swapped output would jump wildly)
#   - Timestamps monotonic at roughly the requested rate
#
# Device must be held STATIONARY during the run. Env overrides:
# SAMPLES / TRIG_HZ / MAX_SPREAD_MAG.

LIB="$(dirname "$0")/lib.sh"
. "$LIB"

SAMPLES="${SAMPLES:-500}"
TRIG_HZ="${TRIG_HZ:-50}"
TRIG_NAME="${TRIG_NAME:-icm20948-buffered-stream}"
MAX_SPREAD_MAG="${MAX_SPREAD_MAG:-60}"   # LSB; ~9 µT

require_iio_device
reset_iio_state
create_hrtimer_trigger "$TRIG_NAME" "$TRIG_HZ"
log "buffered stream: $SAMPLES samples @ ${TRIG_HZ} Hz from $IIO_DEV"

# Enable all scan elements (driver's available_scan_masks requires all-on)
for f in "$IIO_DEV/scan_elements/"*_en; do
    [ -e "$f" ] || continue
    echo 1 | $SUDO tee "$f" >/dev/null
    defer "echo 0 | $SUDO tee '$f' >/dev/null 2>&1"
done

echo "$TRIG_NAME" | $SUDO tee "$IIO_DEV/trigger/current_trigger" >/dev/null \
    || die "could not assign trigger"
defer "echo '' | $SUDO tee '$IIO_DEV/trigger/current_trigger' >/dev/null 2>&1"

echo "$SAMPLES" | $SUDO tee "$IIO_DEV/buffer/length" >/dev/null
echo 1 | $SUDO tee "$IIO_DEV/buffer/enable" >/dev/null \
    || die "could not enable buffer"
defer "echo 0 | $SUDO tee '$IIO_DEV/buffer/enable' >/dev/null 2>&1"

CAP="$(mktemp)"; defer "rm -f '$CAP'"
DEV_FILE="/dev/$(basename "$IIO_DEV")"
# Give the buffer time to fill, plus a couple seconds of slack.
TIMEOUT_S=$(( SAMPLES / TRIG_HZ + 3 ))
$SUDO timeout "$TIMEOUT_S" dd if="$DEV_FILE" of="$CAP" bs=32 count="$SAMPLES" \
    iflag=fullblock status=none 2>/dev/null || true

python3 - "$CAP" "$TRIG_HZ" "$MAX_SPREAD_MAG" "$SAMPLES" <<'PYEOF'
import sys, struct
cap, hz, mag_max, want = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
data = open(cap, "rb").read()
rec = 32
n = len(data) // rec
if n < want // 2:
    sys.exit(f"FAIL: captured {n} samples, expected ~{want}")
# Frame: accel(6) gyro(6) temp(2) mag(6) pad(4) ts(8) — big-endian s16 channels
def s16(b): return struct.unpack(">h", b)[0]
mags = []
ts = []
for i in range(n):
    f = data[i*rec:(i+1)*rec]
    mags.append((s16(f[14:16]), s16(f[16:18]), s16(f[18:20])))
    ts.append(struct.unpack_from("<q", f, 24)[0])
print(f"  decoded {n} frames")
zeros = sum(1 for m in mags if m == (0,0,0))
if zeros:
    sys.exit(f"FAIL: {zeros}/{n} buffered samples have mag=(0,0,0) — aux-master glitch filter regression")
xs, ys, zs = zip(*mags)
def stats(name, vals, limit):
    # 5th-95th percentile spread: ignores transient outliers (chip
    # saturating briefly, glitch flavour the kernel filter didn't
    # cover) while still catching byte-swap regressions, which move
    # the entire distribution.
    s = sorted(vals)
    lo, hi = s[len(s)*5//100], s[len(s)*95//100]
    iqr = hi - lo
    mn, mx = min(vals), max(vals)
    print(f"  mag_{name} min={mn:6d} max={mx:6d} p5..p95={lo:6d}..{hi:6d} (spread={iqr:5d}) mean={sum(vals)/len(vals):8.1f}")
    if iqr > limit:
        # Dump samples falling outside the central band for diagnosis.
        idx = {"x":0,"y":1,"z":2}[name]
        for i, m in enumerate(mags):
            if not (lo <= m[idx] <= hi):
                f = data[i*rec:(i+1)*rec]
                print(f"    outlier i={i} mag={m} bytes={f[14:20].hex()}")
        sys.exit(f"FAIL: mag_{name} p5..p95 spread {iqr} > {limit} — byte-swap regression?")
stats("x", xs, mag_max)
stats("y", ys, mag_max)
stats("z", zs, mag_max)
# Timestamp monotonicity + cadence
for i in range(1, n):
    if ts[i] <= ts[i-1]:
        sys.exit(f"FAIL: timestamps not monotonic at i={i}: {ts[i-1]} -> {ts[i]}")
diffs = [ts[i] - ts[i-1] for i in range(1, n)]
avg = sum(diffs) / len(diffs)
want_ns = 1_000_000_000 // hz
if not (want_ns * 0.5 <= avg <= want_ns * 1.5):
    sys.exit(f"FAIL: avg interval {avg:.0f}ns, expected ~{want_ns}ns (±50%)")
print(f"  cadence avg {avg/1e6:.2f}ms (expect {want_ns/1e6:.2f}ms)")
PYEOF

ok "buffered stream clean: $SAMPLES samples, 0 zero-glitches, mag spread within noise"
