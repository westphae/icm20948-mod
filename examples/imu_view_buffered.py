#!/usr/bin/env python3
"""Terminal UI for the ICM-20948 buffered IIO interface.

Sets up an iio-trig-hrtimer trigger, opens /dev/iio:deviceN, and decodes
32-byte sample frames in real time. Displays the latest sample, a 1-second
running mean per axis, and the actual frame arrival rate. Hotkeys cycle the
accel / gyro full-scale range and DLPF cutoffs by briefly pausing the buffer
(the driver's iio_device_claim_direct check rejects those writes while
streaming).

Run after the driver is loaded and bound. Needs root: configfs trigger
creation, sysfs writes, and /dev/iio:deviceN open all want it.

Env overrides:  TRIG_NAME (default "icm20948-example"), TRIG_HZ (default 100).
"""

import atexit
import curses
import errno
import os
import struct
import subprocess
import sys
import time
from collections import deque
from pathlib import Path

IIO_ROOT = Path("/sys/bus/iio/devices")
CONFIGFS_HRTIMER = Path("/sys/kernel/config/iio/triggers/hrtimer")
TRIG_NAME = os.environ.get("TRIG_NAME", "icm20948-example")
TRIG_HZ = int(os.environ.get("TRIG_HZ", "100"))

# Per-sample layout in the IIO ring (matches the driver's scan_index order):
#  accel.{x,y,z}  6 bytes BE s16
#  anglvel.{x,y,z} 6 bytes BE s16
#  temp           2 bytes BE s16
#  magn.{x,y,z}   6 bytes BE s16
#  pad            4 bytes (align timestamp to 8)
#  timestamp      8 bytes LE s64 (nanoseconds, monotonic by default)
FRAME_SIZE = 32


def find_device(name="icm20948"):
    for d in sorted(IIO_ROOT.glob("iio:device*")):
        try:
            if (d / "name").read_text().strip() == name:
                return d
        except OSError:
            continue
    return None


def rd(path):
    """Read a sysfs attr; retry on transient I2C errors so the UI
    survives bus hiccups under the buffered load."""
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
    if not options:
        return current
    try:
        i = options.index(current)
    except ValueError:
        return options[0]
    return options[(i + 1) % len(options)]


def decode(frame):
    """Unpack one 32-byte IIO buffer frame into native ints."""
    ax, ay, az, gx, gy, gz, t, mx, my, mz = struct.unpack(">hhhhhhhhhh", frame[:20])
    ts = struct.unpack_from("<q", frame, 24)[0]
    return (ax, ay, az, gx, gy, gz, t, mx, my, mz, ts)


def setup_trigger():
    """Create the hrtimer trigger via configfs, set its frequency, and
    return its /sys/bus/iio/devices/triggerN path. Registers cleanup
    (rmdir of the configfs entry) iff we created it."""
    subprocess.run(["modprobe", "iio-trig-hrtimer"], check=False,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if not CONFIGFS_HRTIMER.exists():
        sys.exit("configfs not mounted at /sys/kernel/config — "
                 "`sudo mount -t configfs none /sys/kernel/config` and retry.")

    trig_dir = CONFIGFS_HRTIMER / TRIG_NAME
    if not trig_dir.exists():
        trig_dir.mkdir()
        atexit.register(lambda: trig_dir.rmdir() if trig_dir.exists() else None)

    for t in IIO_ROOT.glob("trigger*"):
        try:
            if (t / "name").read_text().strip() == TRIG_NAME:
                wr(t / "sampling_frequency", TRIG_HZ)
                return t
        except OSError:
            continue
    sys.exit(f"hrtimer trigger {TRIG_NAME} not visible under {IIO_ROOT}")


def setup_buffer(dev):
    """Enable all scan elements, attach the trigger, and turn the
    ring on. Registers cleanup that unwinds in the reverse order."""
    # idempotent: if a prior run left the buffer enabled, disable first
    try:
        wr(dev / "buffer/enable", 0)
    except OSError:
        pass

    enabled = []
    for f in (dev / "scan_elements").glob("*_en"):
        wr(f, 1)
        enabled.append(f)
    wr(dev / "trigger/current_trigger", TRIG_NAME)
    wr(dev / "buffer/length", 64)
    wr(dev / "buffer/enable", 1)

    def teardown():
        # A zero-byte write to current_trigger is a no-op in sysfs; the
        # kernel needs at least a newline to interpret "unbind".
        for fn, val in [(dev / "buffer/enable", 0),
                        (dev / "trigger/current_trigger", "\n")] + [(f, 0) for f in enabled]:
            try:
                wr(fn, val)
            except OSError:
                pass
    atexit.register(teardown)


def wr_paused(dev, attr, value):
    """Briefly pause the buffer, write a config attribute, resume.

    The driver wraps write_raw() in iio_device_claim_direct, which
    is the standard IIO contract: scale / DLPF changes are not
    allowed while the buffer is live (all samples in a stream must
    share one set of decode constants). Pause for the write so the
    cycle hotkeys still work; ~one trigger period of samples drops.
    """
    wr(dev / "buffer/enable", 0)
    try:
        wr(dev / attr, value)
    finally:
        wr(dev / "buffer/enable", 1)


def main(stdscr, dev):
    curses.curs_set(0)
    stdscr.timeout(50)  # ms; 20 Hz UI refresh

    dev_file = Path("/dev") / dev.name
    fd = os.open(dev_file, os.O_RDONLY | os.O_NONBLOCK)

    accel_scales = rd(dev / "in_accel_scale_available").split()
    gyro_scales  = rd(dev / "in_anglvel_scale_available").split()
    accel_lpfs   = rd(dev / "in_accel_filter_low_pass_3db_frequency_available").split()
    gyro_lpfs    = rd(dev / "in_anglvel_filter_low_pass_3db_frequency_available").split()

    ring = deque(maxlen=TRIG_HZ)   # ~1 s of samples
    rate_window = deque(maxlen=64) # last 64 frame arrival times
    latest = None
    status = ""
    buf = b""

    try:
        while True:
            # Drain frames from the kernel buffer without blocking.
            now = time.monotonic()
            try:
                chunk = os.read(fd, FRAME_SIZE * 64)
                if chunk:
                    buf += chunk
            except BlockingIOError:
                pass
            while len(buf) >= FRAME_SIZE:
                frame = buf[:FRAME_SIZE]
                buf = buf[FRAME_SIZE:]
                latest = decode(frame)
                ring.append(latest)
                rate_window.append(now)

            try:
                a_scale = float(rd(dev / "in_accel_scale"))
                g_scale = float(rd(dev / "in_anglvel_scale"))
                m_scale = float(rd(dev / "in_magn_scale"))
                t_scale = float(rd(dev / "in_temp_scale"))
                t_off   = float(rd(dev / "in_temp_offset"))
                a_lpf   = rd(dev / "in_accel_filter_low_pass_3db_frequency")
                g_lpf   = rd(dev / "in_anglvel_filter_low_pass_3db_frequency")
                overrange = rd(dev / "in_magn_overrange")
            except (OSError, ValueError) as e:
                # Sysfs hiccuped under load; skip this refresh.
                status = f"read: {e}"
                continue

            stdscr.erase()
            row = 0
            stdscr.addstr(row, 0, f"ICM-20948  buffered IIO  @ {TRIG_HZ} Hz"); row += 1
            stdscr.addstr(row, 0, f"  {dev_file}"); row += 2

            if latest is None:
                stdscr.addstr(row, 0, "waiting for samples...")
            else:
                ax, ay, az, gx, gy, gz, tt, mx, my, mz, ts = latest
                accel = (ax * a_scale, ay * a_scale, az * a_scale)
                gyro  = (gx * g_scale, gy * g_scale, gz * g_scale)
                mag   = (mx * m_scale * 100, my * m_scale * 100, mz * m_scale * 100)
                temp  = (tt * t_scale + t_off) / 1000.0

                def mean(idx, scale_=1.0):
                    return sum(s[idx] for s in ring) / len(ring) * scale_
                m_accel = tuple(mean(i, a_scale) for i in range(3))
                m_gyro  = tuple(mean(i, g_scale) for i in range(3, 6))
                m_mag   = tuple(mean(i, m_scale * 100) for i in range(7, 10))

                # Frame arrival rate; dt is 0 if two frames share a tick.
                dt = (rate_window[-1] - rate_window[0]
                      if len(rate_window) >= 2 else 0)
                rate = (len(rate_window) - 1) / dt if dt > 0 else 0.0

                stdscr.addstr(row, 0, f"Frame rate: {rate:6.2f} Hz   ring depth = {len(ring)} samples"); row += 2

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
                stdscr.addstr(row + 1, 0, f"[{status}]"[:curses.COLS - 1])

            stdscr.refresh()
            try:
                k = stdscr.getkey()
            except curses.error:
                continue
            try:
                if k == 'q':
                    return
                elif k == 'a':
                    new = cycle(rd(dev / "in_accel_scale"), accel_scales)
                    wr_paused(dev, "in_accel_scale", new); status = f"accel scale → {new}"
                elif k == 'g':
                    new = cycle(rd(dev / "in_anglvel_scale"), gyro_scales)
                    wr_paused(dev, "in_anglvel_scale", new); status = f"gyro scale → {new}"
                elif k == 'A':
                    new = cycle(a_lpf, accel_lpfs)
                    wr_paused(dev, "in_accel_filter_low_pass_3db_frequency", new); status = f"accel lpf → {new} Hz"
                elif k == 'G':
                    new = cycle(g_lpf, gyro_lpfs)
                    wr_paused(dev, "in_anglvel_filter_low_pass_3db_frequency", new); status = f"gyro lpf → {new} Hz"
                elif k == 'o':
                    wr(dev / "in_magn_overrange", "0"); status = "overrange flag cleared"
            except OSError as e:
                status = f"write error ({k}): {e}"
    finally:
        os.close(fd)


if __name__ == "__main__":
    dev = find_device()
    if dev is None:
        sys.exit("icm20948 IIO device not found. Load the driver "
                 "(insmod or DT overlay) and bind it first.")
    setup_trigger()
    setup_buffer(dev)
    curses.wrapper(main, dev)
