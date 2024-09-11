#!/bin/bash

if [[ "$root" != aosc-livekit:* ]] ; then
	warn "Root device type is not aosc-livekit."
	warn "Perhps this module should not live in this instance of initrd image!"
fi

aoscroot="${root##aosc-livekit:}"
if [ "x$aoscroot" = "x" ] ; then
	die "Root device is empty. How awkward is that!"
fi

case "$aoscroot" in
	/dev/*)
		{
			printf 'KERNEL=="%s", RUN+="/sbin/initqueue --settled --onetime --unique /sbin/livekit-loader %s"\n' \
				"${aoscroot##/dev/}" "$aoscroot"
			printf 'SYMLINK=="%s", RUN+="/sbin/initqueue --settled --onetime --unique /sbin/livekit-loader %s"\n' \
				"${aoscroot##/dev/}" "$aoscroot"
		} >> /etc/udev/rules.d/99-live-squash.rules
		wait_for_dev -n "$aoscroot"
		;;
	*)
		if [ -f "$aoscroot" ]; then
			/sbin/initqueue --settled --onetime --unique /sbin/livekit-loader "${aoscroot}"
		fi
		;;
esac
