#!/bin/bash
check() {
	# host-only images are meant to be generic.
	[[ $hostonly ]] && return 1
	return 255
}

depends() {
	echo dm rootfs-block img-lib overlayfs
	return 0
}

install() {
	inst_multiple dmsetup umount mount dd losetup find mkdir rmdir tee less realpath
	inst_hook cmdline 30 "$moddir"/parse-aosc-cmdline.sh
	inst_hook pre-udev 30 "$moddir"/aosc-livekit-gen-rules.sh
	inst_script "$moddir"/livekit-mount-layers.sh /sbin/livekit-mount-layers
	# Do we need initqueue?
}

installkernel() {
	instmods squashfs loop iso9660 overlayfs
}

