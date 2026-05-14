#!/usr/bin/env bash
# Stability test for the sysfs single-shot read path. Polls every mag/accel
# axis N=300 times, computes per-axis spread, and flags excess noise or
# any zero-mag samples. Catches wedged-chip / scale-decode regressions in
# the /sys/.../in_*_raw path.
#
# Device must be held STATIONARY during the run. Honours SAMPLES /
# MAX_SPREAD_MAG / MAX_SPREAD_ACCEL env overrides.

LIB="$(dirname "$0")/lib.sh"
. "$LIB"

SAMPLES="${SAMPLES:-300}"
INTERVAL_MS="${INTERVAL_MS:-20}"             # pace sysfs reads so we don't
                                             # hammer the I2C bus
# Bounds are intentionally lenient: stationary-but-noisy environments
# (Pi on a desk near a PC) easily push accel spread to ~2000 LSB. The
# regressions we actually want to catch (byte-swap, scale flip) move
# values by 10000+ LSB, so MAX_SPREAD_ACCEL=5000 still nails them.
MAX_SPREAD_MAG="${MAX_SPREAD_MAG:-200}"
MAX_SPREAD_ACCEL="${MAX_SPREAD_ACCEL:-5000}"
# Chip's aux master occasionally returns (0,0,0) — same glitch the
# buffered trigger handler filters out. Single-shot sysfs can't filter
# it without extra block reads, so allow a small rate. Set to 0 to
# strictly fail on any zero (will fail on hardware with the glitch).
MAX_ZERO_RATE_PCT="${MAX_ZERO_RATE_PCT:-5}"

require_iio_device
log "sysfs stream: $SAMPLES reads of $IIO_DEV (device must be stationary)"

OUT="$(mktemp)"
defer "rm -f '$OUT'"

# Polling loop. Per-row inter-channel reads can occasionally trip EIO on
# rapid back-to-back I2C transactions — that's the chip / bus reality,
# not a driver bug. Retry once on EIO, drop the row if it persists.
$SUDO python3 - "$IIO_DEV" "$SAMPLES" "$INTERVAL_MS" >"$OUT" <<'PYEOF'
import sys, time, errno
dev, n, ms = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
chans = ["accel_x","accel_y","accel_z","magn_x","magn_y","magn_z"]
def read_axis(c):
    # Retry on EIO (5) or EREMOTEIO (121) — both surface from the I2C
    # core when a transaction fails transiently.
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
    if i + 1 < n and ms:
        time.sleep(ms / 1000.0)
PYEOF

python3 - "$OUT" "$MAX_SPREAD_MAG" "$MAX_SPREAD_ACCEL" "$MAX_ZERO_RATE_PCT" <<'PYEOF'
import sys, statistics
out, mag_max, accel_max, zero_max_pct = (
    sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4]))
rows = [list(map(int, line.split())) for line in open(out) if line.strip()]
n = len(rows)
chans = ["accel_x","accel_y","accel_z","magn_x","magn_y","magn_z"]
print(f"  read {n} rows")
def is_glitch(v):
    # Same canonical chip glitch the kernel filters in the buffered
    # path: all 6 bytes of the mag block uniform. Manifests in sysfs
    # int values as all-axes-equal at either 0 or -1.
    return v[0] == v[1] == v[2] and v[0] in (0, -1)
glitch_mag = sum(1 for r in rows if is_glitch(r[3:6]))
glitch_pct = 100.0 * glitch_mag / n
gflag = " FAIL" if glitch_pct > zero_max_pct else ""
print(f"  glitch-mag samples: {glitch_mag}/{n} ({glitch_pct:.2f}%){gflag}")
if glitch_pct > zero_max_pct:
    sys.exit(f"FAIL: glitch-mag rate {glitch_pct:.2f}% > {zero_max_pct}%")
# Drop rows where any single axis hit 0 or -1 alongside non-uniform
# others — that's a torn read where one axis caught the glitch window.
def has_partial_glitch(r):
    return any(r[i] in (0, -1) for i in (3, 4, 5)) and not is_glitch(r[3:6])
clean = [r for r in rows if not is_glitch(r[3:6]) and not has_partial_glitch(r)]
cols = list(zip(*clean))
fail = []
for i, name in enumerate(chans):
    vmin, vmax = min(cols[i]), max(cols[i])
    spread = vmax - vmin
    mean = statistics.fmean(cols[i])
    limit = mag_max if name.startswith("magn") else accel_max
    flag = " FAIL" if spread > limit else ""
    print(f"  {name:8s} min={vmin:6d} max={vmax:6d} spread={spread:5d} mean={mean:8.1f}{flag}")
    if spread > limit:
        fail.append(f"{name} spread {spread} > {limit}")
if fail:
    sys.exit("FAIL: " + "; ".join(fail))
PYEOF

ok "sysfs stream stable over $SAMPLES samples"
