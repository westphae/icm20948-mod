#!/usr/bin/env bash
# Terminal UI for the ICM-20948 buffered IIO interface.
#
# Sets up an iio-trig-hrtimer trigger, opens /dev/iio:deviceN, and decodes
# 32-byte sample frames in real time. Displays the latest sample, the
# running mean over the last second, and the actual frame rate. Hotkeys
# cycle the accel/gyro scale and DLPF cutoffs while the buffer is live —
# changes take effect immediately.
#
# Run after the driver is loaded and bound. Needs root for configfs
# trigger creation and for sysfs writes.

set -euo pipefail

I2C_BUS="${I2C_BUS:-1}"
TRIG_NAME="${TRIG_NAME:-icm20948-example}"
TRIG_HZ="${TRIG_HZ:-100}"

DEV=""
for d in /sys/bus/iio/devices/iio:device*; do
    [ -d "$d" ] || continue
    if [ "$(cat "$d/name" 2>/dev/null)" = "icm20948" ]; then
        DEV="$d"; break
    fi
done
if [ -z "$DEV" ]; then
    echo "icm20948 IIO device not found." >&2
    echo "Load the driver (insmod or DT overlay) and bind it first." >&2
    exit 1
fi

SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"

# Find / mount configfs and create the hrtimer trigger.
CONFIGFS=""
for p in /sys/kernel/config /config; do
    [ -d "$p/iio" ] && CONFIGFS="$p" && break
done
if [ -z "$CONFIGFS" ]; then
    $SUDO mount -t configfs none /sys/kernel/config 2>/dev/null || true
    CONFIGFS=/sys/kernel/config
fi
$SUDO modprobe iio-trig-hrtimer >/dev/null 2>&1 || true
$SUDO mkdir -p "$CONFIGFS/iio/triggers/hrtimer/$TRIG_NAME" 2>/dev/null
CREATED_TRIG=1

cleanup() {
    set +e
    echo 0 | $SUDO tee "$DEV/buffer/enable" >/dev/null 2>&1
    echo '' | $SUDO tee "$DEV/trigger/current_trigger" >/dev/null 2>&1
    for f in "$DEV/scan_elements/"*_en; do
        [ -e "$f" ] || continue
        echo 0 | $SUDO tee "$f" >/dev/null 2>&1
    done
    [ "${CREATED_TRIG:-0}" = 1 ] && $SUDO rmdir "$CONFIGFS/iio/triggers/hrtimer/$TRIG_NAME" 2>/dev/null
}
trap cleanup EXIT INT TERM

# sampling_frequency lives on the matching /sys/bus/iio/devices/triggerN entry
TRIG_PATH=""
for t in /sys/bus/iio/devices/trigger*; do
    [ "$(cat "$t/name" 2>/dev/null)" = "$TRIG_NAME" ] && TRIG_PATH="$t" && break
done
[ -n "$TRIG_PATH" ] || { echo "hrtimer trigger $TRIG_NAME not visible" >&2; exit 1; }
echo "$TRIG_HZ" | $SUDO tee "$TRIG_PATH/sampling_frequency" >/dev/null

# Enable every scan element, attach the trigger, enable the ring.
echo 0 | $SUDO tee "$DEV/buffer/enable" >/dev/null 2>&1
for f in "$DEV/scan_elements/"*_en; do
    [ -e "$f" ] || continue
    echo 1 | $SUDO tee "$f" >/dev/null
done
echo "$TRIG_NAME" | $SUDO tee "$DEV/trigger/current_trigger" >/dev/null
echo 64 | $SUDO tee "$DEV/buffer/length" >/dev/null
echo 1 | $SUDO tee "$DEV/buffer/enable" >/dev/null

# Run (don't exec) so the trap above fires on python exit and tears
# down the buffer / trigger.
$SUDO python3 - "$DEV" "$TRIG_HZ" "$TRIG_PATH" <<'PYEOF'
import curses, errno, fcntl, os, struct, sys, time
from collections import deque

DEV, TRIG_HZ, TRIG_PATH = sys.argv[1], int(sys.argv[2]), sys.argv[3]
DEV_FILE = f"/dev/{os.path.basename(DEV)}"

def rd(path):
    # Retry briefly on transient I2C errors so a single bus hiccup
    # doesn't tear the UI down. EINVAL/EIO/EREMOTEIO have all been
    # observed under aggressive sysfs polling with the buffer active.
    last = None
    for _ in range(3):
        try:
            with open(f"{DEV}/{path}") as f:
                return f.read().strip()
        except OSError as e:
            last = e
            time.sleep(0.005)
    # Fall back to "" so the UI keeps refreshing rather than crashing.
    return ""

def wr(path, value):
    with open(f"{DEV}/{path}", "w") as f:
        f.write(str(value))

def cycle(current, options):
    if not options: return current
    try: i = options.index(current)
    except ValueError: return options[0]
    return options[(i + 1) % len(options)]

# 32-byte frame: accel(6 BE) gyro(6 BE) temp(2 BE) mag(6 BE) pad(4) ts(8 LE)
def decode(frame):
    ax,ay,az,gx,gy,gz,t,mx,my,mz = struct.unpack(">hhhhhhhhhh", frame[:20])
    ts = struct.unpack_from("<q", frame, 24)[0]
    return (ax,ay,az,gx,gy,gz,t,mx,my,mz,ts)

def main(stdscr):
    curses.curs_set(0)
    stdscr.nodelay(True)
    stdscr.timeout(50)  # 20 Hz UI refresh

    fd = os.open(DEV_FILE, os.O_RDONLY | os.O_NONBLOCK)
    accel_scales = rd("in_accel_scale_available").split()
    gyro_scales  = rd("in_anglvel_scale_available").split()
    accel_lpfs   = rd("in_accel_filter_low_pass_3db_frequency_available").split()
    gyro_lpfs    = rd("in_anglvel_filter_low_pass_3db_frequency_available").split()

    # Ring of last ~1 s of samples for the running mean + rate display.
    ring = deque(maxlen=TRIG_HZ)
    latest = None
    rate_window = deque(maxlen=64)  # last 64 frame arrival times
    status = ""

    buf = b""
    try:
        while True:
            # Drain whatever frames are available without blocking.
            now = time.monotonic()
            try:
                chunk = os.read(fd, 32 * 64)
                if chunk:
                    buf += chunk
            except BlockingIOError:
                pass
            while len(buf) >= 32:
                frame = buf[:32]
                buf = buf[32:]
                s = decode(frame)
                latest = s
                ring.append(s)
                rate_window.append(now)

            try:
                a_scale = float(rd("in_accel_scale"))
                g_scale = float(rd("in_anglvel_scale"))
                m_scale = float(rd("in_magn_scale"))
                t_scale = float(rd("in_temp_scale"))
                t_off   = float(rd("in_temp_offset"))
                a_lpf   = rd("in_accel_filter_low_pass_3db_frequency")
                g_lpf   = rd("in_anglvel_filter_low_pass_3db_frequency")
                overrange = rd("in_magn_overrange")
            except (OSError, ValueError) as e:
                # Sysfs hiccuped under load. Skip this refresh; the
                # next iteration will pick up valid values.
                status = f"read: {e}"
                continue

            stdscr.erase()
            row = 0
            stdscr.addstr(row, 0, f"ICM-20948  buffered IIO  @ {TRIG_HZ} Hz"); row += 1
            stdscr.addstr(row, 0, f"  {DEV_FILE}"); row += 2

            if latest is None:
                stdscr.addstr(row, 0, "waiting for samples...")
            else:
                ax,ay,az,gx,gy,gz,tt,mx,my,mz,ts = latest
                # Per-sample SI
                accel = (ax*a_scale, ay*a_scale, az*a_scale)
                gyro  = (gx*g_scale, gy*g_scale, gz*g_scale)
                mag   = (mx*m_scale*100, my*m_scale*100, mz*m_scale*100)
                temp  = (tt*t_scale + t_off) / 1000.0
                # Means over the ring
                def mean(idx, scale_=1.0):
                    return sum(s[idx] for s in ring) / len(ring) * scale_
                m_accel = tuple(mean(i, a_scale) for i in range(3))
                m_gyro  = tuple(mean(i, g_scale) for i in range(3, 6))
                m_mag   = tuple(mean(i, m_scale*100) for i in range(7, 10))
                # Frame arrival rate. dt can be zero if two frames arrive in
                # the same monotonic tick on slow clocks.
                dt = rate_window[-1] - rate_window[0] if len(rate_window) >= 2 else 0
                rate = (len(rate_window) - 1) / dt if dt > 0 else 0.0

                stdscr.addstr(row, 0, f"Frame rate: {rate:6.2f} Hz   buffer depth ≤ {len(ring)} samples"); row += 2

                stdscr.addstr(row, 0, "Accelerometer (m/s²)")
                stdscr.addstr(row, 40, f"scale = {a_scale:.9f}  lpf = {a_lpf} Hz"); row += 1
                stdscr.addstr(row, 2, f"now  x = {accel[0]:+9.3f}  y = {accel[1]:+9.3f}  z = {accel[2]:+9.3f}"); row += 1
                stdscr.addstr(row, 2, f"avg  x = {m_accel[0]:+9.3f}  y = {m_accel[1]:+9.3f}  z = {m_accel[2]:+9.3f}"); row += 2

                stdscr.addstr(row, 0, "Gyroscope (rad/s)")
                stdscr.addstr(row, 40, f"scale = {g_scale:.9f}  lpf = {g_lpf} Hz"); row += 1
                stdscr.addstr(row, 2, f"now  x = {gyro[0]:+9.4f}  y = {gyro[1]:+9.4f}  z = {gyro[2]:+9.4f}"); row += 1
                stdscr.addstr(row, 2, f"avg  x = {m_gyro[0]:+9.4f}  y = {m_gyro[1]:+9.4f}  z = {m_gyro[2]:+9.4f}"); row += 2

                flag = "  OVERRANGE!" if overrange == "1" else ""
                stdscr.addstr(row, 0, f"Magnetometer (µT){flag}"); row += 1
                stdscr.addstr(row, 2, f"now  x = {mag[0]:+8.2f}   y = {mag[1]:+8.2f}   z = {mag[2]:+8.2f}"); row += 1
                stdscr.addstr(row, 2, f"avg  x = {m_mag[0]:+8.2f}   y = {m_mag[1]:+8.2f}   z = {m_mag[2]:+8.2f}"); row += 2

                stdscr.addstr(row, 0, f"Temperature: {temp:6.2f} °C    timestamp = {ts} ns"); row += 2

            stdscr.addstr(row, 0, "Hotkeys:"); row += 1
            stdscr.addstr(row, 2, "a/g  cycle accel/gyro full-scale range"); row += 1
            stdscr.addstr(row, 2, "A/G  cycle accel/gyro DLPF cutoff"); row += 1
            stdscr.addstr(row, 2, "o    clear in_magn_overrange flag"); row += 1
            stdscr.addstr(row, 2, "q    quit"); row += 1
            if status:
                stdscr.addstr(row + 1, 0, f"[{status}]"[:curses.COLS-1])

            stdscr.refresh()
            try:
                k = stdscr.getkey()
            except curses.error:
                continue
            try:
                if k == 'q':
                    return
                elif k == 'a':
                    new = cycle(rd("in_accel_scale"), accel_scales)
                    wr("in_accel_scale", new); status = f"accel scale → {new}"
                elif k == 'g':
                    new = cycle(rd("in_anglvel_scale"), gyro_scales)
                    wr("in_anglvel_scale", new); status = f"gyro scale → {new}"
                elif k == 'A':
                    new = cycle(a_lpf, accel_lpfs)
                    wr("in_accel_filter_low_pass_3db_frequency", new); status = f"accel lpf → {new} Hz"
                elif k == 'G':
                    new = cycle(g_lpf, gyro_lpfs)
                    wr("in_anglvel_filter_low_pass_3db_frequency", new); status = f"gyro lpf → {new} Hz"
                elif k == 'o':
                    wr("in_magn_overrange", "0"); status = "overrange flag cleared"
            except OSError as e:
                status = f"write error ({k}): {e}"
    finally:
        os.close(fd)

curses.wrapper(main)
PYEOF
