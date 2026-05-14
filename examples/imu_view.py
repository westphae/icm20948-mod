#!/usr/bin/env python3
"""Terminal UI for the ICM-20948 sysfs (single-shot) interface.

Polls every channel via /sys/.../in_*_raw, applies the chip's _scale
and _offset to render SI units, and refreshes ~5x/s. Hotkeys cycle
the accel/gyro full-scale range and the DLPF cutoffs.

Run after the driver is loaded and bound (DT overlay or manual
new_device). Needs root if you don't already have write access to
the sysfs config attributes — the cycle hotkeys require it.
"""

import curses
import errno
import sys
import time
from pathlib import Path

IIO_ROOT = Path("/sys/bus/iio/devices")


def find_device(name="icm20948"):
    for d in sorted(IIO_ROOT.glob("iio:device*")):
        try:
            if (d / "name").read_text().strip() == name:
                return d
        except OSError:
            continue
    return None


def rd(path):
    """Read a sysfs attr; retry briefly on transient I2C errors.

    EIO and EREMOTEIO have both been seen from the I2C core under
    rapid back-to-back reads of the ICM-20948 — retrying is enough.
    """
    for _ in range(3):
        try:
            return Path(path).read_text().strip()
        except OSError as e:
            if e.errno not in (errno.EIO, errno.EREMOTEIO):
                raise
            time.sleep(0.005)
    return ""


def wr(path, value):
    Path(path).write_text(str(value))


def cycle(current, options):
    """Return the next option after `current` in `options`, wrapping."""
    if not options:
        return current
    try:
        i = options.index(current)
    except ValueError:
        return options[0]
    return options[(i + 1) % len(options)]


def main(stdscr, dev):
    curses.curs_set(0)
    stdscr.timeout(200)  # ms; 5 Hz refresh

    accel_scales = rd(dev / "in_accel_scale_available").split()
    gyro_scales  = rd(dev / "in_anglvel_scale_available").split()
    accel_lpfs   = rd(dev / "in_accel_filter_low_pass_3db_frequency_available").split()
    gyro_lpfs    = rd(dev / "in_anglvel_filter_low_pass_3db_frequency_available").split()
    temp_lpfs    = rd(dev / "in_temp_filter_low_pass_3db_frequency_available").split()
    status = ""

    while True:
        try:
            ax, ay, az = (int(rd(dev / f"in_accel_{a}_raw"))   for a in "xyz")
            gx, gy, gz = (int(rd(dev / f"in_anglvel_{a}_raw")) for a in "xyz")
            mx, my, mz = (int(rd(dev / f"in_magn_{a}_raw"))    for a in "xyz")
            tt = int(rd(dev / "in_temp_raw"))
            a_scale = float(rd(dev / "in_accel_scale"))
            g_scale = float(rd(dev / "in_anglvel_scale"))
            m_scale = float(rd(dev / "in_magn_scale"))
            t_scale = float(rd(dev / "in_temp_scale"))
            t_off   = float(rd(dev / "in_temp_offset"))
            a_lpf   = rd(dev / "in_accel_filter_low_pass_3db_frequency")
            g_lpf   = rd(dev / "in_anglvel_filter_low_pass_3db_frequency")
            t_lpf   = rd(dev / "in_temp_filter_low_pass_3db_frequency")
            overrange = rd(dev / "in_magn_overrange")
        except (OSError, ValueError) as e:
            status = f"read: {e}"
            continue

        # Apply IIO scale/offset to get SI units.
        ax_si, ay_si, az_si = ax * a_scale, ay * a_scale, az * a_scale
        gx_si, gy_si, gz_si = gx * g_scale, gy * g_scale, gz * g_scale
        # _magn_scale is in Gauss/LSB per IIO ABI; ×100 → µT.
        mx_si = mx * m_scale * 100
        my_si = my * m_scale * 100
        mz_si = mz * m_scale * 100
        # in_temp_input formula: (raw * scale + offset) in m°C; /1000 → °C.
        t_si = (tt * t_scale + t_off) / 1000.0

        stdscr.erase()
        row = 0
        stdscr.addstr(row, 0, "ICM-20948  sysfs single-shot view"); row += 1
        stdscr.addstr(row, 0, f"  {dev}"); row += 2

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
            stdscr.addstr(row + 1, 0, f"[{status}]"[:curses.COLS - 1])

        stdscr.refresh()
        try:
            k = stdscr.getkey()
        except curses.error:
            continue  # no key, just refresh
        try:
            if k == 'q':
                return
            elif k == 'a':
                new = cycle(rd(dev / "in_accel_scale"), accel_scales)
                wr(dev / "in_accel_scale", new); status = f"accel scale → {new}"
            elif k == 'g':
                new = cycle(rd(dev / "in_anglvel_scale"), gyro_scales)
                wr(dev / "in_anglvel_scale", new); status = f"gyro scale → {new}"
            elif k == 'A':
                new = cycle(a_lpf, accel_lpfs)
                wr(dev / "in_accel_filter_low_pass_3db_frequency", new); status = f"accel lpf → {new} Hz"
            elif k == 'G':
                new = cycle(g_lpf, gyro_lpfs)
                wr(dev / "in_anglvel_filter_low_pass_3db_frequency", new); status = f"gyro lpf → {new} Hz"
            elif k == 'T':
                new = cycle(t_lpf, temp_lpfs)
                wr(dev / "in_temp_filter_low_pass_3db_frequency", new); status = f"temp lpf → {new} Hz"
            elif k == 'o':
                wr(dev / "in_magn_overrange", "0"); status = "overrange flag cleared"
        except OSError as e:
            status = f"write error ({k}): {e}"


if __name__ == "__main__":
    dev = find_device()
    if dev is None:
        sys.exit("icm20948 IIO device not found. Load the driver "
                 "(insmod or DT overlay) and bind it first.")
    curses.wrapper(main, dev)
