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
