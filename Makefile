TOP = $(CURDIR)

MODULE = 90aosc-livekit-loader

DESTDIR := /

PREFIX := /usr

DRACUT_MODULES = $(PREFIX)/lib/dracut/modules.d

export TOP MODULE DESTDIR PREFIX DRACUT_MODULES

.PHONY: install initrd-image

install:
	$(MAKE) -C $(MODULE) install

initrd-image: install
	sudo dracut --force $(INITRD) --add="aosc-livekit-loader"
