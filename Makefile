obj-m += icm20948.o

KDIR      ?= /lib/modules/$(shell uname -r)/build
DTBO_DIR  ?= $(firstword $(wildcard /boot/firmware/overlays /boot/overlays))
CONFIG_TXT ?= $(firstword $(wildcard /boot/firmware/config.txt /boot/config.txt))
DTC       ?= dtc

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

dtbo: dts/icm20948.dtbo

dts/icm20948.dtbo: dts/icm20948-overlay.dts
	$(DTC) -@ -I dts -O dtb -o $@ $<

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
	rm -f dts/*.dtbo

modules_install:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules_install
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

# Create the /lib/modules/$(uname -r)/build symlink that kbuild needs for
# out-of-tree module builds. Use this when the running kernel has no
# distro-packaged headers (e.g. rpi-update kernels) and you have a matching
# kernel source tree elsewhere. KSRC must point at a tree that:
#   - matches the running kernel exactly (UTS_RELEASE == $(uname -r))
#   - has had `make modules_prepare` run in it
#   - has Module.symvers (i.e. a prior `make modules` completed there)
# Needs root because /lib/modules/... is not user-writable.
setup-kbuild:
	@set -e; \
	LINK=/lib/modules/`uname -r`/build; \
	if [ -e "$$LINK" ]; then \
		echo "$$LINK already exists; nothing to do."; \
		exit 0; \
	fi; \
	if [ -z "$(KSRC)" ]; then \
		echo "Usage: sudo make setup-kbuild KSRC=/path/to/matching/kernel/source"; \
		echo ""; \
		echo "Prepare the source tree first if you haven't:"; \
		echo "  cd \$$KSRC && make modules_prepare && make -j\$$(nproc) modules"; \
		exit 1; \
	fi; \
	test -d "$(KSRC)" || { echo "KSRC=$(KSRC): not a directory"; exit 1; }; \
	test -f "$(KSRC)/Module.symvers" || { \
		echo "$(KSRC)/Module.symvers missing; run there:"; \
		echo "  make modules_prepare && make -j\$$(nproc) modules"; \
		exit 1; }; \
	KREL=`sed -n 's/.*UTS_RELEASE "\(.*\)".*/\1/p' "$(KSRC)/include/generated/utsrelease.h" 2>/dev/null`; \
	RUN=`uname -r`; \
	if [ "$$KREL" != "$$RUN" ]; then \
		echo "version mismatch: KSRC builds [$$KREL], running [$$RUN]"; \
		exit 1; \
	fi; \
	ln -sT "$(KSRC)" "$$LINK"; \
	echo "linked $$LINK -> $(KSRC)"

.PHONY: all dtbo clean modules_install dtbo_install config_enable install setup-kbuild
