TOP = $(CURDIR)

MODULE = 90aosc-livekit-loader

DESTDIR := /

PREFIX := /usr

DRACUT_MODULES = $(PREFIX)/lib/dracut/modules.d

export TOP MODULE DESTDIR PREFIX DRACUT_MODULES

.PHONY: install

install:
	$(MAKE) -C $(MODULE) install
