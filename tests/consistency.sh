#!/usr/bin/env bash
# Cross-checks that the sysfs single-shot path and the buffered IIO path
# agree on what the chip is reading. The two paths use different code in
# the driver (sysfs goes through icm20948_read_word + be16_to_cpu;
# buffered goes through icm20948_read + scan_type endianness), so a
# byte-order or sign-inversion bug in either would show up here even if
# each path independently looks "stable" on its own.
#
# Device must be held STATIONARY during the run. The two paths sample
# at slightly different times, so we compare MEANS rather than instant
# values, and tolerate ~30 LSB of disagreement (sensor jitter).

LIB="$(dirname "$0")/lib.sh"
. "$LIB"

SAMPLES_BUF="${SAMPLES_BUF:-500}"
SAMPLES_SYSFS="${SAMPLES_SYSFS:-100}"
TRIG_HZ="${TRIG_HZ:-50}"
TRIG_NAME="${TRIG_NAME:-icm20948-consistency}"
# Per-channel tolerance. Mag values are stable (sample-to-sample spread
# ~30 LSB) so means converge fast — tight bound. Accel jitters with
# environmental vibration; the means of two short windows easily
# differ by 100+ LSB. The point is to catch byte-swap / sign-flip
# regressions, which move means by 10000+ LSB.
MAX_DELTA_MAG="${MAX_DELTA_MAG:-30}"
MAX_DELTA_ACCEL="${MAX_DELTA_ACCEL:-500}"

require_iio_device
reset_iio_state

# Sysfs path first (cheap; chip can hold still longer)
log "collecting $SAMPLES_SYSFS sysfs samples..."
SYSFS_OUT="$(mktemp)"; defer "rm -f '$SYSFS_OUT'"
$SUDO python3 - "$IIO_DEV" "$SAMPLES_SYSFS" >"$SYSFS_OUT" <<'PYEOF'
import sys, time, errno
dev, n = sys.argv[1], int(sys.argv[2])
chans = ["accel_x","accel_y","accel_z","magn_x","magn_y","magn_z"]
def read_axis(c):
    for _ in range(3):
        try:
            with open(f"{dev}/in_{c}_raw") as f:
                return f.read().strip()
        except OSError as e:
            if e.errno not in (errno.EIO, errno.EREMOTEIO):
                raise
            time.sleep(0.005)
    return None
for i in range(n):
    row = [read_axis(c) for c in chans]
    if None in row:
        continue
    sys.stdout.write(" ".join(row) + "\n")
    time.sleep(0.02)
PYEOF

create_hrtimer_trigger "$TRIG_NAME" "$TRIG_HZ"
log "collecting $SAMPLES_BUF buffered samples..."
for f in "$IIO_DEV/scan_elements/"*_en; do
    [ -e "$f" ] || continue
    echo 1 | $SUDO tee "$f" >/dev/null
    defer "echo 0 | $SUDO tee '$f' >/dev/null 2>&1"
done
echo "$TRIG_NAME" | $SUDO tee "$IIO_DEV/trigger/current_trigger" >/dev/null
defer "echo '' | $SUDO tee '$IIO_DEV/trigger/current_trigger' >/dev/null 2>&1"
echo "$SAMPLES_BUF" | $SUDO tee "$IIO_DEV/buffer/length" >/dev/null
echo 1 | $SUDO tee "$IIO_DEV/buffer/enable" >/dev/null
defer "echo 0 | $SUDO tee '$IIO_DEV/buffer/enable' >/dev/null 2>&1"

BUF_CAP="$(mktemp)"; defer "rm -f '$BUF_CAP'"
TIMEOUT_S=$(( SAMPLES_BUF / TRIG_HZ + 3 ))
$SUDO timeout "$TIMEOUT_S" dd if="/dev/$(basename "$IIO_DEV")" of="$BUF_CAP" \
    bs=32 count="$SAMPLES_BUF" iflag=fullblock status=none 2>/dev/null || true
fsz=$(stat -c%s "$BUF_CAP")
[ "$fsz" -ge 32 ] || die "no buffered samples captured (check trigger / buffer setup)"

python3 - "$SYSFS_OUT" "$BUF_CAP" "$MAX_DELTA_MAG" "$MAX_DELTA_ACCEL" <<'PYEOF'
import sys, struct, statistics
sysfs_out, buf_cap, mag_max, accel_max = (
    sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]))
sysfs_rows = [list(map(int, l.split())) for l in open(sysfs_out) if l.strip()]
chans = ["accel_x","accel_y","accel_z","magn_x","magn_y","magn_z"]
# Drop glitch rows from sysfs means (same chip-level glitch as in the
# buffered path's kernel filter).
def is_glitch(row): return row[3]==row[4]==row[5] and row[3] in (0,-1)
clean_rows = [r for r in sysfs_rows if not is_glitch(r)]
sysfs_means = {c: statistics.fmean(row[i] for row in clean_rows)
               for i, c in enumerate(chans)}
data = open(buf_cap, "rb").read()
rec = 32
n = len(data) // rec
def s16(b): return struct.unpack(">h", b)[0]
def mean_at(off):
    return statistics.fmean(s16(data[i*rec+off:i*rec+off+2]) for i in range(n))
buf_means = {
    "accel_x": mean_at(0), "accel_y": mean_at(2), "accel_z": mean_at(4),
    "magn_x":  mean_at(14),"magn_y":  mean_at(16),"magn_z":  mean_at(18),
}
print(f"  channel     sysfs    buffered    delta   limit")
fail = []
for c in chans:
    s, b = sysfs_means[c], buf_means[c]
    d = b - s
    limit = mag_max if c.startswith("magn") else accel_max
    flag = " FAIL" if abs(d) > limit else ""
    print(f"  {c:8s} {s:9.1f} {b:9.1f} {d:+8.1f}  ±{limit}{flag}")
    if abs(d) > limit:
        fail.append(f"{c} delta {d:+.1f} exceeds ±{limit}")
if fail:
    sys.exit("FAIL: " + "; ".join(fail))
PYEOF

ok "sysfs and buffered paths agree within tolerance per axis"
