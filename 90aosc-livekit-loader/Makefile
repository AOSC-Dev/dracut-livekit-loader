EXEC_FILES = livekit-mount-layers.sh \
	module-setup.sh \
	parse-aosc-cmdline.sh \
	aosc-livekit-gen-rules.sh

OTHER_FILES =

.PHONY: check install $(EXEC_FILES) $(OTHER_FILES)

check:
	@if [ "x$(DESTDIR)" == "x/" ] && [ "x$(INSTALL_TO_SYSROOT)" != "xyes" ] ; then \
		echo "You can not install this module directly to your system root." >&1 ; \
		echo "Refused to continue." >&1 ; \
		exit 1 ; \
	fi

install: check $(EXEC_FILES) $(OTHER_FILES)

$(EXEC_FILES):
	install -Dvm755 $(CURDIR)/$@ $(DESTDIR)/$(DRACUT_MODULES)/$(MODULE)/$@
