#!/usr/bin/env bash
# Terminal UI for the ICM-20948 sysfs (single-shot) interface.
#
# Reads every channel via /sys/.../in_*_raw, applies the chip's _scale
# and _offset to render SI units, and refreshes ~5x/s. Hotkeys cycle the
# accel/gyro full-scale range and the DLPF cutoffs.
#
# Run after the driver is loaded and bound (DT overlay or smoke.sh).
# Needs root if you don't already have write access to the sysfs files
# (the scale/LPF cycle keys require it).

set -euo pipefail

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

# Stash the Python in a temp file rather than piping it on stdin —
# `python3 - "$DEV"` consumes stdin as the script source, leaving
# curses with no TTY to read keypresses from.
PY=$(mktemp --suffix=.py)
trap 'rm -f "$PY"' EXIT INT TERM
cat > "$PY" <<'PYEOF'
import curses, errno, sys, time

DEV = sys.argv[1]

def rd(path):
    """Read a sysfs attr; retry once on transient I2C error."""
    for _ in range(3):
        try:
            with open(f"{DEV}/{path}") as f:
                return f.read().strip()
        except OSError as e:
            if e.errno not in (errno.EIO, errno.EREMOTEIO):
                raise
            time.sleep(0.005)
    return ""

def wr(path, value):
    with open(f"{DEV}/{path}", "w") as f:
        f.write(str(value))

def cycle(current, options):
    if not options:
        return current
    try:
        i = options.index(current)
    except ValueError:
        return options[0]
    return options[(i + 1) % len(options)]

def main(stdscr):
    curses.curs_set(0)
    stdscr.nodelay(True)
    stdscr.timeout(200)  # 5 Hz refresh

    accel_scales = rd("in_accel_scale_available").split()
    gyro_scales  = rd("in_anglvel_scale_available").split()
    accel_lpfs   = rd("in_accel_filter_low_pass_3db_frequency_available").split()
    gyro_lpfs    = rd("in_anglvel_filter_low_pass_3db_frequency_available").split()
    temp_lpfs    = rd("in_temp_filter_low_pass_3db_frequency_available").split()
    status = ""

    while True:
        try:
            ax,ay,az = (int(rd(f"in_accel_{a}_raw"))   for a in "xyz")
            gx,gy,gz = (int(rd(f"in_anglvel_{a}_raw")) for a in "xyz")
            mx,my,mz = (int(rd(f"in_magn_{a}_raw"))    for a in "xyz")
            tt = int(rd("in_temp_raw"))
            a_scale = float(rd("in_accel_scale"))
            g_scale = float(rd("in_anglvel_scale"))
            m_scale = float(rd("in_magn_scale"))
            t_scale = float(rd("in_temp_scale"))
            t_off   = float(rd("in_temp_offset"))
            a_lpf   = rd("in_accel_filter_low_pass_3db_frequency")
            g_lpf   = rd("in_anglvel_filter_low_pass_3db_frequency")
            t_lpf   = rd("in_temp_filter_low_pass_3db_frequency")
            overrange = rd("in_magn_overrange")
        except OSError as e:
            status = f"read error: {e}"

        # SI conversions (kernel IIO ABI: m/s², rad/s, Gauss, millidegree-C)
        ax_si, ay_si, az_si = ax*a_scale, ay*a_scale, az*a_scale
        gx_si, gy_si, gz_si = gx*g_scale, gy*g_scale, gz*g_scale
        mx_si, my_si, mz_si = mx*m_scale*100, my*m_scale*100, mz*m_scale*100  # Gauss → µT
        t_si = (tt*t_scale + t_off) / 1000.0  # millidegC → °C

        stdscr.erase()
        row = 0
        stdscr.addstr(row, 0, "ICM-20948  sysfs single-shot view"); row += 1
        stdscr.addstr(row, 0, f"  {DEV}"); row += 2

        stdscr.addstr(row, 0, "Accelerometer (m/s²)")
        stdscr.addstr(row, 40, f"scale = {a_scale:.9f}  lpf = {a_lpf} Hz"); row += 1
        stdscr.addstr(row, 2, f"x = {ax_si:+9.3f}    y = {ay_si:+9.3f}    z = {az_si:+9.3f}"); row += 1
        amag = (ax_si**2 + ay_si**2 + az_si**2) ** 0.5
        stdscr.addstr(row, 2, f"|a| = {amag:.3f}  (1 g ≈ 9.807)"); row += 2

        stdscr.addstr(row, 0, "Gyroscope (rad/s)")
        stdscr.addstr(row, 40, f"scale = {g_scale:.9f}  lpf = {g_lpf} Hz"); row += 1
        stdscr.addstr(row, 2, f"x = {gx_si:+9.4f}    y = {gy_si:+9.4f}    z = {gz_si:+9.4f}"); row += 2

        stdscr.addstr(row, 0, "Magnetometer (µT)")
        flag = "  OVERRANGE!" if overrange == "1" else ""
        stdscr.addstr(row, 40, f"scale = {m_scale:.9f} G/LSB{flag}"); row += 1
        stdscr.addstr(row, 2, f"x = {mx_si:+8.2f}     y = {my_si:+8.2f}     z = {mz_si:+8.2f}"); row += 1
        mmag = (mx_si**2 + my_si**2 + mz_si**2) ** 0.5
        stdscr.addstr(row, 2, f"|m| = {mmag:.2f}  (Earth field 25–65 µT typical)"); row += 2

        stdscr.addstr(row, 0, f"Temperature: {t_si:6.2f} °C    lpf = {t_lpf} Hz"); row += 2

        stdscr.addstr(row, 0, "Hotkeys:"); row += 1
        stdscr.addstr(row, 2, "a/g  cycle accel/gyro full-scale range"); row += 1
        stdscr.addstr(row, 2, "A/G  cycle accel/gyro DLPF cutoff"); row += 1
        stdscr.addstr(row, 2, "T    cycle temperature DLPF cutoff"); row += 1
        stdscr.addstr(row, 2, "o    clear in_magn_overrange flag"); row += 1
        stdscr.addstr(row, 2, "q    quit"); row += 1
        if status:
            stdscr.addstr(row + 1, 0, f"[{status}]"[:curses.COLS-1])

        stdscr.refresh()
        try:
            k = stdscr.getkey()
        except curses.error:
            continue   # no key, just refresh
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
            elif k == 'T':
                new = cycle(t_lpf, temp_lpfs)
                wr("in_temp_filter_low_pass_3db_frequency", new); status = f"temp lpf → {new} Hz"
            elif k == 'o':
                wr("in_magn_overrange", "0"); status = "overrange flag cleared"
        except OSError as e:
            status = f"write error ({k}): {e}"

curses.wrapper(main)
PYEOF
exec python3 "$PY" "$DEV"
