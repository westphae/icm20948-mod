obj-m += icm20948.o

KDIR      ?= /lib/modules/$(shell uname -r)/build
DTBO_DIR  ?= $(firstword $(wildcard /boot/firmware/overlays /boot/overlays))
CONFIG_TXT ?= $(firstword $(wildcard /boot/firmware/config.txt /boot/config.txt))
DTC       ?= dtc

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

dtbo: dts/icm20948.dtbo

dts/icm20948.dtbo: dts/icm20948-overlay.dts
	$(DTC) -@ -I dts -O dtb -o $@ $<

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
	rm -f dts/*.dtbo

modules_install:
	$(MAKE) -C $(KDIR) M=$(PWD) modules_install
	depmod -a

dtbo_install: dts/icm20948.dtbo
	@test -n "$(DTBO_DIR)" || { echo "DTBO_DIR not set and neither /boot/firmware/overlays nor /boot/overlays exists; pass DTBO_DIR=..."; exit 1; }
	install -d $(DTBO_DIR)
	install -m 0644 dts/icm20948.dtbo $(DTBO_DIR)/

config_enable:
	@test -n "$(CONFIG_TXT)" || { echo "CONFIG_TXT not set and no Pi config.txt found; pass CONFIG_TXT=..."; exit 1; }
	@if grep -q '^dtoverlay=icm20948' $(CONFIG_TXT); then \
		echo "$(CONFIG_TXT) already enables dtoverlay=icm20948"; \
	else \
		echo 'dtoverlay=icm20948' >> $(CONFIG_TXT); \
		echo "appended dtoverlay=icm20948 to $(CONFIG_TXT) -- reboot to activate"; \
	fi

install: modules_install dtbo_install config_enable

.PHONY: all dtbo clean modules_install dtbo_install config_enable install
