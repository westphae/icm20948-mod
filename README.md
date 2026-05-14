ICM20948-mod
============
Linux kernel IIO driver for the [ICM20948](https://invensense.tdk.com/products/motion-tracking/9-axis/icm-20948/) 9-axis IMU (3-axis accel + 3-axis gyro + on-chip AK09916 magnetometer + temperature). I²C only — no SPI, no FIFO. Optional on-chip data-ready IRQ trigger when the INT1 pin is wired and declared in DT; otherwise use an external trigger such as `iio-trig-hrtimer`. Magnetometer overflow (HOFL) is surfaced as a sticky `in_magn_overrange` sysfs flag.

Tested target: Raspberry Pi running a recent (6.x) kernel, ICM-20948 on `i2c-1` at address `0x68`.

Build
-----
Requires a prepared kernel build tree at `/lib/modules/$(uname -r)/build`. Without it, `make` fails with `No such file or directory`. The Makefile defaults to that path; override `KDIR=...` if your tree is elsewhere.

```sh
make            # produces icm20948.ko
```

### Setting up the build tree

**Distro-packaged kernel** (Raspberry Pi OS, Debian/Ubuntu, etc.):

```sh
sudo apt install raspberrypi-kernel-headers    # Raspberry Pi
# or
sudo apt install linux-headers-$(uname -r)     # generic Debian/Ubuntu
```

The package places headers under `/usr/src/linux-headers-$(uname -r)` and registers the `/lib/modules/$(uname -r)/build` symlink for you. `make` then Just Works.

**Custom or rpi-update kernel** (no headers package available — `dom@buildbot` in `/proc/version` is the giveaway): point at a kernel source tree of the *exact* same version, prepare it, and link it. On Raspberry Pi the typical flow is:

```sh
# Fetch matching source (rpi-source is one of several options)
sudo apt install bc bison flex libssl-dev libncurses-dev
git clone --depth=1 --branch <matching-tag> https://github.com/raspberrypi/linux /root/linux

# Prepare it. The full `make modules` is what produces Module.symvers,
# which the OOT build needs for modpost. ~60–90 min on a Pi 4 first time.
cd /root/linux
cp /proc/config.gz /tmp/config.gz && gunzip -c /tmp/config.gz > .config   # or use the distro's /boot/config-*
make modules_prepare
make -j$(nproc) modules

# Wire it up
sudo make -C /path/to/icm20948-mod setup-kbuild KSRC=/root/linux
```

`setup-kbuild` verifies that `KSRC` is a real kernel source tree, that its `UTS_RELEASE` matches `$(uname -r)`, and that `Module.symvers` exists in it — then creates the `/lib/modules/$(uname -r)/build` symlink. Re-run it after anything (apt updates, depmod sweeps) wipes the symlink:

```sh
sudo make setup-kbuild KSRC=/root/linux
```

Install (persistent)
--------------------
On a Raspberry Pi with the sensor wired to `i2c-1` at `0x68`:

```sh
sudo make install
sudo reboot
```

That target:

1. `modules_install` — copies `icm20948.ko` into a subdirectory of `/lib/modules/$(uname -r)/` (`updates/` or `extra/` depending on your kbuild version) and runs `depmod -a`.
2. `dtbo_install` — builds `dts/icm20948-overlay.dts` and copies the resulting `icm20948.dtbo` into `/boot/firmware/overlays/` (falls back to `/boot/overlays/` on legacy layouts; override with `DTBO_DIR=...`).
3. `config_enable` — appends `dtoverlay=icm20948` to `/boot/firmware/config.txt` (or `/boot/config.txt`; override with `CONFIG_TXT=...`) if not already present.

After reboot the kernel matches the overlay's `compatible = "invensense,icm20948"` against the driver and probes automatically; sensor data appears under `/sys/bus/iio/devices/iio:deviceN/`.

If your sensor is on a different I2C bus or address, edit `dts/icm20948-overlay.dts` (change `target = <&i2c1>`) or pass an address override on the overlay line, e.g. `dtoverlay=icm20948,addr=0x69` (AD0 tied high).

Userspace interface
-------------------

Once the driver is bound, the chip presents as a single IIO device under `/sys/bus/iio/devices/iio:deviceN/` (the exact `N` depends on enumeration order — find it by reading the `name` file in each `iio:device*` entry; the one that reads `icm20948` is yours). All values follow the standard Linux IIO ABI: a `_raw` ADC reading is converted to physical units via the channel's `_scale` (and `_offset`, for temperature). Files are read-only unless noted as **(w)** below.

```
/sys/bus/iio/devices/iio:deviceN/
├── name                                    # "icm20948"
├── in_mount_matrix                         # 3×3 sensor→board orientation (from DT)
├── in_accel_{x,y,z}_raw                    # ADC counts, signed 16-bit
├── in_accel_{x,y,z}_calibbias        (w)   # subtracted from raw before output
├── in_accel_scale                    (w)   # m/s² per LSB; set to one of:
├── in_accel_scale_available                #   the four full-scale ranges
├── in_accel_filter_low_pass_3db_frequency  (w)
├── in_accel_filter_low_pass_3db_frequency_available
├── in_anglvel_{x,y,z}_raw                  # ADC counts, signed 16-bit
├── in_anglvel_{x,y,z}_calibbias      (w)   # subtracted from raw before output
├── in_anglvel_scale                  (w)   # rad/s per LSB; one of four ranges
├── in_anglvel_scale_available
├── in_anglvel_filter_low_pass_3db_frequency  (w)
├── in_anglvel_filter_low_pass_3db_frequency_available
├── in_magn_{x,y,z}_raw                     # ADC counts, signed 16-bit
├── in_magn_scale                           # Gauss per LSB (fixed; AK09916 has no PGA)
├── in_magn_overrange                 (w)   # sticky 0/1 — see below
├── in_temp_raw                             # ADC counts, signed 16-bit
├── in_temp_scale                           # millidegrees-C per LSB
├── in_temp_offset                          # additive offset in output units
├── in_temp_filter_low_pass_3db_frequency  (w)
├── in_temp_filter_low_pass_3db_frequency_available
├── scan_elements/                          # used by triggered buffered capture
├── buffer/                                 #   (length, enable)
└── trigger/                                #   (current_trigger)
```

| Channel | Unit | Default range | Full-scale options (write to `_scale`) |
|---|---|---|---|
| `in_accel_*` | m/s² | ±2 g (~19.6 m/s²) | 2 / 4 / 8 / 16 g |
| `in_anglvel_*` | rad/s | ±250 dps (~4.36 rad/s) | 250 / 500 / 1000 / 2000 dps |
| `in_magn_*` | Gauss | ±4.9 G (fixed) | — |
| `in_temp` | milli-°C | — | — |

To convert a raw reading: **`value = (raw + calibbias) * scale`** for accel/gyro/mag, and **`temp_milliC = raw * scale + offset`** for temperature (chip datasheet formula: `T °C = raw / 333.87 + 21`).

The `scan_elements/in_*_en` files (write-only 0/1) toggle which channels participate in buffered capture. The driver registers a fixed scan mask that enables all data channels plus the timestamp — you don't need to pick a subset. Buffered output is a packed 32-byte frame per sample: `accel.{x,y,z}` (6 B big-endian) · `anglvel.{x,y,z}` (6 B) · `temp` (2 B) · `magn.{x,y,z}` (6 B) · 4 B alignment pad · `timestamp` (8 B little-endian, ns since boot). The endianness/storagebits/shift of every channel is exposed under `scan_elements/in_*_type` for tools that need to decode the frames programmatically (`libiio` and friends do this automatically).

**`in_magn_overrange`** is the chip's `MAG_ST2.HOFL` bit latched across the buffered stream — set whenever any mag axis saturated the ±4912 µT range on any captured sample, cleared by writing `0`. Use it to detect transient saturation events that would otherwise be lost between userspace polls.

**`in_mount_matrix`** is a row-major 3×3 matrix string populated from the DT `mount-matrix` property if present, otherwise the identity. Use it to rotate accel/gyro/mag samples from the chip's body frame into your board's reference frame.

Buffered streaming needs a trigger. If `dts/icm20948-overlay.dts` declares an `interrupts` entry tied to the chip's INT1 pin, the driver registers an `iio_trigger` named `icm20948-devN` and auto-attaches it (no `trigger/current_trigger` write needed). Otherwise create an `iio-trig-hrtimer` and write its name into `trigger/current_trigger` — see the `tests/buffered_stream.sh` helper or upstream IIO documentation.

### rpi-update kernels: also install the in-tree modules

`make install` installs *only* our `icm20948.ko`, not the in-tree kernel modules it depends on (`i2c-bcm2835`, `industrialio`, `industrialio-triggered-buffer`, `iio-trig-hrtimer`, …). On a distro-packaged kernel those modules are shipped by the kernel package and already live under `/lib/modules/$(uname -r)/kernel/`. On an `rpi-update` kernel they are **not** — the firmware deploys only the bootable kernel image, not the bundled module set — so after reboot you see symptoms like:

- `i2cdetect -y 1` → `Error: Could not open file '/dev/i2c-1' ...`
- `dmesg | grep i2c` shows nothing about `bcm2835-i2c`
- `find /lib/modules/$(uname -r) -name 'i2c*bcm*'` returns empty
- our overlay applied (the DT shows `icm20948@68` under `i2c@7e804000`), but no driver bound it

Fix is one-time per rpi-update kernel — install the in-tree modules out of the `KSRC` tree you already built earlier for the OOT compile:

```sh
# modules_install refuses to proceed without these manifest files; empty
# placeholders satisfy the dependency without affecting runtime behaviour
# (built-in modules live inside the kernel image, no install needed).
touch /root/linux/modules.builtin /root/linux/modules.builtin.modinfo

sudo make -C /root/linux modules_install
sudo depmod -a      # modules_install skips depmod when System.map is absent
```

Then either reboot or `sudo modprobe i2c-bcm2835` to bring the bus up. `/dev/i2c-1` should appear immediately, the overlay's `compatible` matches our driver, and `/sys/bus/iio/devices/iio:device0/name` reads `icm20948`.

### Optional: data-ready interrupt

If the chip's INT1 pin is wired to a Pi GPIO, you can have the driver register its own data-ready trigger instead of relying on `iio-trig-hrtimer` for buffered capture. Uncomment the `interrupt-parent` / `interrupts` lines in `dts/icm20948-overlay.dts`, set the GPIO number to whatever you've wired (the example uses GPIO17), rebuild and reinstall the overlay. After reboot a new trigger appears as `icm20948-devN` under `/sys/bus/iio/devices/triggerN/` and is auto-attached to the IIO device. If the IRQ isn't declared in DT, the driver silently skips this and behaves as before.

Dev / one-shot (no reboot)
--------------------------
For an iterative build-test loop without touching `config.txt`:

```sh
sudo ./tests/smoke.sh
```

builds, loads, manually binds the device on `i2c-1:0x68`, range-checks every `*_raw` channel (assumes the board is stationary so accel ≈ 1 g and gyro ≈ 0), exercises buffered capture through an `iio-trig-hrtimer`, then unwinds the module and any state it created. `I2C_BUS`, `I2C_ADDR`, `TRIG_HZ`, `CAPTURE_SAMPLES` are env-overridable.

To do it by hand:

```sh
make
sudo insmod ./icm20948.ko
echo "icm20948 0x68" | sudo tee /sys/bus/i2c/devices/i2c-1/new_device
# ... read /sys/bus/iio/devices/iio:deviceN/in_*_raw, etc.
echo 0x68 | sudo tee /sys/bus/i2c/devices/i2c-1/delete_device
sudo rmmod icm20948
```

### Live terminal viewers

Two interactive examples under `examples/` render the chip's output in real time and let you cycle the scale/DLPF settings from the keyboard. Both need the driver loaded and bound.

```sh
sudo ./examples/imu_view.sh             # single-shot sysfs reads (~5 Hz)
sudo ./examples/imu_view_buffered.sh    # iio-trig-hrtimer + /dev/iio:deviceN buffered capture
```

Hotkeys (same in both): **`a`/`g`** cycle accel/gyro full-scale range, **`A`/`G`** cycle their DLPF cutoffs, **`o`** clears the sticky `in_magn_overrange` flag, **`q`** quits. The buffered viewer also shows the live frame rate, a 1-second running mean per axis, and the latest sample's timestamp; it tears down the hrtimer trigger on exit.

### Regression tests

`tests/all.sh` runs four focused regression scripts against an *already-bound* device (the DT overlay's auto-bind is fine). Hold the sensor stationary during the run (~40 s). Failures point at recent classes of bug we've fixed:

```sh
sudo ./tests/all.sh
```

| Script | What it covers |
|---|---|
| `tests/sysfs_stream.sh` | Polls every channel via `in_*_raw`. Catches sysfs-path regressions (wedged chip, scale flips). |
| `tests/buffered_stream.sh` | Streams 500 buffered samples via `iio-trig-hrtimer`, asserts no `mag = (0,0,0)` / `(-1,-1,-1)` glitches and per-axis 5–95 % spread stays in noise. Direct regression test for the byte-swap fix and aux-master NACK filter. |
| `tests/consistency.sh` | Compares per-channel medians from the sysfs and buffered paths — catches decode/sign divergence between them. |
| `tests/bind_cycle.sh` | Unbind/rebind ×5, watches `dmesg` for refcount/use-after-free. Regression test for the `indio_dev->trig` cleanup. |

Tunable thresholds (sample counts, spread/delta tolerances, trigger rate) are env-overridable — see the heading comments in each script.

Troubleshooting
---------------

**`i2cdetect -y 1` errors with `Could not open file '/dev/i2c-1'`**

The bus device isn't there because `i2c-bcm2835` didn't load. On a distro kernel run `sudo modprobe i2c-bcm2835`; on an rpi-update kernel you also need to install the in-tree modules from your `KSRC` tree — see [rpi-update kernels: also install the in-tree modules](#rpi-update-kernels-also-install-the-in-tree-modules).

**`i2cdetect -y 1` shows `UU` at 0x68 — that's success, not an error**

`UU` means the kernel driver owns the address (so userspace can't probe it). It's the desired end state. Verify by reading `/sys/bus/iio/devices/iio:device0/name` (should print `icm20948`).

**`i2cdetect` shows `UU` at 0x68 but every `*_raw` reads zero**

The chip silently wedged after probe — driver still thinks it owns the bus, but the chip is no longer servicing register reads. Force a fresh probe to recover:

```sh
echo 1-0068 | sudo tee /sys/bus/i2c/drivers/icm20948/unbind >/dev/null
echo 1-0068 | sudo tee /sys/bus/i2c/drivers/icm20948/bind   >/dev/null
cat /sys/bus/iio/devices/iio:device0/in_accel_z_raw            # should now be non-zero
```

(`1-0068` = bus 1, address 0x68; adjust as needed.) If the rebind itself errors out or values stay zero afterward, the chip is hard-wedged and only a hardware power-cycle will recover it.

**`i2cdetect -y 1` shows `--` at every address where you expect a device**

The chip didn't ACK at all. Power-cycle the sensor (unplug+replug 3.3 V if you can; reboot the Pi otherwise). This usually happens after some unlucky aux-bus interaction during mag init that hangs the chip's I²C state machine; the live driver may sometimes provoke it during heavy iteration.

**`dmesg | grep icm20948` shows `Unknown symbol …` at boot**

Our module loaded before its IIO-core dependencies. Happens on rpi-update kernels where the in-tree modules weren't installed in dependency order. Install them (`make modules_install` from `KSRC`, then `depmod -a`); the kernel will then auto-load `industrialio` ahead of `icm20948` on subsequent boots.

Uninstall
---------
```sh
sudo rm /boot/firmware/overlays/icm20948.dtbo                          # or /boot/overlays/
sudo sed -i '/^dtoverlay=icm20948/d' /boot/firmware/config.txt         # or /boot/config.txt
sudo find /lib/modules/$(uname -r) -name 'icm20948.ko*' -delete
sudo depmod -a
sudo reboot
```
