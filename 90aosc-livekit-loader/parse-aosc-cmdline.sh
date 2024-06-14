#!/bin/bash
# AOSC LiveKit image loader - command line parser
# The root= kernel argument should be one of the following:
# root=aosc-livekit:LABEL=filesystemlabel, for searching images inside a specific filesystem.
# root=aosc-livekit:UUID=fsuuid, same as above.
# root=aosc-livekit:PARTUUID=partuuid, same as above.
# root=aosc-livekit:/dev/someblkdev, same as above.
# root=aosc-livekit:CDLABEL=cdlabel, for searching images inside a Live CD.
# The root device type must be aosc-livekit.
# NFS images are currently not supported.
# If no root= is specified, a default one is taken:
# root=aosc-livekit:CDLABEL=LiveKit

# Default root= parameter
DEFAULT_ROOTPARAM="aosc-livekit:CDLABEL=AOSC OS Installer"

# Get root= argument from kernel command line, if is not set.
[ -z "$root" ] && root=$(getarg root=)

# If root= is still empty, fallback to the default one.
if [ -z "$root" ] ; then
	warn "Root device is not specified in the kernel command line."
	warn "Using the default one."
	root="$DEFAULT_BOOTPARAM"
fi

liveroot=
if [ "x${root%%:*}" = "xaosc-livekit" ] ; then
	liveroot=${root##aosc-livekit:}
else
	warn "Root device type is not aosc-livekit."
	warn "Perhaps this module should not present in this instance of initramfs image!"
	return 1
fi
if [ "x$liveroot" = "x" ] ; then
	warn "Could not extract root device information from kernel arguments."
	warn "Kernel comamnd line: "
	info "$CMDLINE"
	die "Errors encountered, refusing to continue."
fi

info "LiveKit: Parsing root parameter ..."
case "$liveroot" in
	LABEL=* | UUID=* | PARTUUID=*)
		root="aosc-livekit:$(label_uuid_to_dev "$liveroot")"
		rootok=1
		;;
	/dev/*)
		root="aosc-livekit:${liveroot}"
		rootok=1
		;;
	CDLABEL=*)
		cdlabel="$(echo "$liveroot" | sed 's,/,\\x2f,g;s, ,\\x20,g')"
		root="aosc-livekit:/dev/disk/by-label/$cdlabel"
		rootok=1
		;;
esac

if [ "x$rootok" != "x1" ] ; then
	warn "Root device is not recognized or supported."
	die "Try use a different one. Refusing to continue."
fi

info "LiveKit: Parsed root device: $root"
wait_for_dev -n /dev/root
return 0
