# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Out-of-tree Linux kernel IIO driver for the InvenSense/TDK **ICM-20948** 9-axis IMU (3-axis accel + 3-axis gyro + on-chip AK09916 magnetometer + temperature). Single translation unit (`icm20948.c`) plus a register header (`icm20948_regs.h`). The repo is a fork; the README states *"Currently only polled I2C mode is supported"* and the goal of work in this tree is to extend coverage toward full chip support.

## Build / load / test

```sh
make                # builds icm20948.ko against /lib/modules/$(uname -r)/build
make clean
```

Kernel headers for the running kernel must be installed; the Makefile uses `M=$(PWD) modules` against that build tree. On rpi-update kernels with no packaged headers, point `/lib/modules/$(uname -r)/build` at a matching kernel source tree (and run `make modules_prepare`+`make modules` once there to generate `Module.symvers`, otherwise modpost will fail with undefined-symbol errors).

Manual load + bind cycle on a target with the device wired to I²C-1 at 0x68:

```sh
sudo insmod icm20948.ko
# bind via device tree (compatible = "invensense,icm20948") or manually:
echo icm20948 0x68 | sudo tee /sys/bus/i2c/devices/i2c-1/new_device
# data appears under /sys/bus/iio/devices/iio:deviceN/
sudo rmmod icm20948
```

For a one-shot regression check against a real ICM-20948 (must be held stationary during the run), `tests/smoke.sh` builds, loads, binds, range-checks every `*_raw` channel, exercises the buffered path via `iio-trig-hrtimer`, verifies monotonic timestamps, and unwinds on every exit path. `I2C_BUS`, `I2C_ADDR`, `TRIG_HZ`, `CAPTURE_SAMPLES` are env-overridable.

Channels exposed (sysfs): `in_accel_{x,y,z}_raw`, `in_anglvel_{x,y,z}_raw`, `in_magn_{x,y,z}_raw`, `in_temp_raw`, plus `_scale`, `_calibbias` (accel/gyro only), and `_filter_low_pass_3db_frequency` attributes. There's also `in_magn_overrange` — a sticky 0/1 flag set by the buffered trigger handler whenever the AK09916's ST2 reports HOFL on a sample (any axis saturated ±4912 µT); cleared by `echo 0 > in_magn_overrange`. Buffered capture works through `iio_triggered_buffer`; if the chip's INT1 pin is wired to a GPIO and declared in DT (`interrupts = <...>` on the icm20948 node), the driver registers its own **data-ready trigger** named `icm20948-dev<N>` and auto-attaches it. Without an IRQ in DT, the driver still works but you need an external trigger (e.g. `iio-trig-hrtimer`).

## Architecture cheat sheet

**Register-bank machine.** The chip has 4 banks; addresses are encoded as `(reg & 0xff) | (BANK_N << 8)` in `icm20948_regs.h`. All bus helpers (`icm20948_read_byte`/`_word`, `_write_byte`/`_word`) auto-select the bank via `icm20948_select_bank`, which caches `icm->bank_reg` to skip redundant `REG_BANK_SEL` writes. **Anything you add must go through these helpers** — open-coding `i2c_smbus_*` will desync the cached bank.

**Magnetometer access.** The AK09916 mag is on an internal I2C bus behind the ICM20948 acting as I2C master. Three paths, all coexist after probe:
- *Slave 4* (`icm20948_slave_{read,write}_byte`) — single-shot register R/W used during probe (mag WHO_AM_I check, soft reset). Polls `I2C_MST_STATUS` for `RV_I2C_SLV4_DONE`/`NACK`. **Do not try to write CNTL2 to a continuous mode (0x02/0x04/0x06/0x08) via slave-4** — the AK09916 silently rejects these even though the I2C transaction ACKs, leaving the mag in power-down. Single-measurement (0x01) is the only mode that works through this path, and even that is unreliable as a one-shot.
- *Slave 0* — configured once in probe to **continuously DMA** 8 mag bytes (`ICM20948_MAG_DATA_T`) into `EXT_SLV_SENS_DATA_00..07`, with byte-swap (`RV_I2C_SLV0_BYTE_SW`) so mag little-endian words land in the same big-endian layout as the accel/gyro registers. That's why `icm20948_read` can grab accel+gyro+temp+mag as one packed `ICM20948_SENS_DATA_T` block. The trailing ST2 byte in each burst releases the AK09916's measurement lock so the next single-shot can fire.
- *Slave 1* — used as a re-arm for CNTL2=SINGLE on every aux-master cycle. This is the only way we've found to get the AK09916 to actually measure: drive `MAG_CNTL2 = RV_MAG_MODE_SINGLE` from slave-1, read the result via slave-0 on the next cycle. The aux master is throttled to ~100 Hz (gyro/11) via `I2C_SLV4_CTRL[4:0]` + `I2C_MST_DELAY_CTRL`, slow enough that each ~7.5 ms measurement completes before the next trigger. **Order matters**: write the delay value and `MST_DELAY_CTRL` *before* setting slave-0/1 EN bits, otherwise slaves fire at the full ~1 kHz gyro rate for a few µs and wedge the AK09916.

**Lookup tables for scale/filter.** `ICM20948_LOOKUP_HEAD_T` entries (`icm20948_accel_filter_lookup`, `_anglvel_filter_lookup`, `_temp_filter_lookup`, `_accel_scale_lookup`, `_anglvel_scale_lookup`) map between user-visible `(val, val2)` pairs and the bit patterns to OR into a config register. `icm20948_read_raw` / `_write_raw` first sweep this table to handle scale and DLPF, then fall through to a per-channel-type switch for `RAW`, `CALIBBIAS`, `SCALE`, `OFFSET`. To add a new tunable (e.g. mag mode, sample rate), the cleanest path is usually a new lookup table plus an `IIO_DEVICE_ATTR(..._available, …)` line for sysfs discoverability.

**Axis & sign conventions.** Magnetometer Y and Z are inverted (vs. accel/gyro) in two places that must stay in sync: `icm20948_trigger_handler` (buffered path) and the `IIO_MAGN` case in `icm20948_read_raw` (sysfs raw path). The `c3ea032` and `e5b5291` commits in `git log` are where this was introduced — touch with care.

**Locking.** A single `icm->lock` mutex serialises all bus access (which implicitly serialises bank selection). Helpers do **not** take the lock; callers must. The slave-4 helpers `icm20948_slave_{read,write}_byte` are exceptions — they take it themselves and call multi-step sequences while holding it.

## Coverage map — what the chip supports vs. what this driver wires up

Useful when planning improvements toward full ICM-20948 support. The register header already defines many symbols the driver never references.

| Feature | Chip | Driver |
|---|---|---|
| I2C bus | ✓ | ✓ |
| SPI bus | ✓ | ✗ (no SPI probe; `RV_I2C_IF_DIS` defined but unused) |
| Accel/gyro raw + scale + DLPF | ✓ | ✓ (lookups in `icm20948.c`) |
| Calibration bias (XA/XG offset regs) | ✓ | ✓ accel + gyro |
| Magnetometer raw | ✓ | ✓ (via slave-0 burst) |
| Magnetometer scale | ✓ | ✓ (hardcoded 4912/32752; AK09916 has fixed sensitivity, no ASA registers like AK8963 had) |
| Magnetometer mode (single/10/20/50/100 Hz) | ✓ (`RV_MAG_MODE_*` in regs.h) | ✗ hardcoded to single-measurement, re-armed each aux cycle (~100 Hz). Continuous-mode CNTL2 writes silently fail on AK09916 via slave-4 — see the slave-1 retrigger pattern in probe before changing this. |
| Magnetometer overflow flag (`RV_MAG_HOFL`/`MAG_ST2`) | ✓ | ✓ sticky sysfs `in_magn_overrange`, latched from each buffered sample |
| Hardware FIFO (`FIFO_*` regs) | ✓ | ✗ regs defined, never enabled |
| Data-ready interrupt (`INT_PIN_CFG`, `INT_ENABLE_1.RAW_DATA_0_RDY_EN`) | ✓ | ✓ optional `iio_trigger` registered when DT supplies an IRQ on the i2c_client |
| Motion interrupt (Wake-on-Motion, FSYNC, etc.) | ✓ | ✗ |
| Sample rate divider (`GYRO_SMPLRT_DIV`, `ACCEL_SMPLRT_DIV_*`) | ✓ | ✗ |
| Wake-on-Motion (`ACCEL_INTEL_CTRL`, `ACCEL_WOM_THR`) | ✓ | ✗ |
| Low-power / cycle modes (`LP_CONFIG`, `RV_LP_EN`, `PWR_MGMT_2`) | ✓ | ✗ (only full power, `RV_CLKSEL_0`) |
| Temperature disable (`RV_DEVICE_TEMP_DIS`) | ✓ | ✗ |
| Accel/gyro self-test (`SELF_TEST_*_GYRO/ACCEL`) | ✓ | ✗ |
| DMP (Digital Motion Processor) | ✓ | ✗ (firmware blob required) |
| Mount matrix (DT `mount-matrix`) | — | ✓ |

When adding any of the missing features, follow the established patterns: extend the lookup tables for enumerated configs, add a slave-4 helper call sequence for mag-side state, and keep all register access funnelled through the bank-aware helpers.
