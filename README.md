ICM20948-mod
============
Linux kernel IIO driver for the [ICM20948](https://invensense.tdk.com/products/motion-tracking/9-axis/icm-20948/) 9-axis IMU (3-axis accel + 3-axis gyro + on-chip AK09916 magnetometer + temperature). Polled I2C only — no SPI, no FIFO, no data-ready IRQ trigger (use an external one such as `iio-trig-hrtimer`).

Tested target: Raspberry Pi running a recent (6.x) kernel, ICM-20948 on `i2c-1` at address `0x68`.

Build
-----
Requires kernel headers for the running kernel.

```sh
make
```

produces `icm20948.ko`. The Makefile defaults to `KDIR=/lib/modules/$(uname -r)/build`; override `KDIR=...` if your build tree is elsewhere.

On a Raspberry Pi running an `rpi-update` kernel (no packaged headers), point `/lib/modules/$(uname -r)/build` at a matching kernel source tree and run `make modules_prepare && make modules` inside it once to generate `Module.symvers`; otherwise modpost will fail with "undefined" symbol errors for every external reference.

Install (persistent)
--------------------
On a Raspberry Pi with the sensor wired to `i2c-1` at `0x68`:

```sh
sudo make install
sudo reboot
```

That target:

1. `modules_install` — copies `icm20948.ko` into `/lib/modules/$(uname -r)/extra/` and runs `depmod -a`.
2. `dtbo_install` — builds `dts/icm20948-overlay.dts` and copies the resulting `icm20948.dtbo` into `/boot/firmware/overlays/` (falls back to `/boot/overlays/` on legacy layouts; override with `DTBO_DIR=...`).
3. `config_enable` — appends `dtoverlay=icm20948` to `/boot/firmware/config.txt` (or `/boot/config.txt`; override with `CONFIG_TXT=...`) if not already present.

After reboot the kernel matches the overlay's `compatible = "invensense,icm20948"` against the driver and probes automatically; sensor data appears under `/sys/bus/iio/devices/iio:deviceN/`.

If your sensor is on a different I2C bus or address, edit `dts/icm20948-overlay.dts` (change `target = <&i2c1>`) or pass an address override on the overlay line, e.g. `dtoverlay=icm20948,addr=0x69` (AD0 tied high).

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

Uninstall
---------
```sh
sudo rm /boot/firmware/overlays/icm20948.dtbo                # or /boot/overlays/
sudo sed -i '/^dtoverlay=icm20948/d' /boot/firmware/config.txt
sudo rm /lib/modules/$(uname -r)/extra/icm20948.ko
sudo depmod -a
sudo reboot
```
