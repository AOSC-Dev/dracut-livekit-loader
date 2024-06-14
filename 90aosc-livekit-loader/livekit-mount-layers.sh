#!/bin/bash

set -e
set -x

i() {
	echo "<30>LiveKit: INFO $@" | tee /dev/kmsg >&2
	echo -e "\033[1;37m[\033[1;36mINFO\033[1;37m]: $@\033[0m"
}

w() {
	echo "<28>LiveKit: WARN $@" | tee /dev/kmsg >&2
	echo -e "\033[1;37m[\033[1;33mWARN\033[1;37m]: $@\033[0m"
}

i "Welcome to AOSC OS LiveKit!"

i "Command arguments are:"
i "$@"

if [ ! -e "$1" ] ; then
	w "Looks like $1 does not exist. Refusing to continue."
	exit 1
fi

LIVEKIT_DEV="$1"
LIVEKIT_MNT="/run/initramfs/livekit"
SQUASHFSDIR="$LIVEKIT_MNT/squashfs"
BASESQUASHFS="$SQUASHFSDIR/base.squashfs"
LAYERSDIR="$SQUASHFSDIR/layers"

# The tmpfs backed overlays are in the following layout:
# 0. Mounted Base squashfs as lowerdir (SYSROOTSDIR/base)
# 1. Mounted layer squashfs as lowerdir (LAYERSMNTDIR/$layer)
# 2. tmpfs as upperdir (UPPERDIRS/$layer)
# 3. Merged sysroot ($SYSROOTSDIR/$layer)
#
# Since upperdir must be read-write, we use multilple basedirs.
LAYERSMNTDIR="$(realpath -m $LIVEKIT_MNT/../layers)"
UPPERDIRS="$(realpath -m $LIVEKIT_MNT/../uppers)"
WORKDIRS="$(realpath -m $LIVEKIT_MNT/../workdirs)"
SYSROOTSDIR="$(realpath -m $LIVEKIT_MNT/../sysroots)"
LAYERS=("livekit" "desktop")

i "Creating directory structure ..."
mkdir -p "$LIVEKIT_MNT"
mkdir -p "$SYSROOTSDIR"
mkdir -p "$SYSROOTSDIR"/base
for layer in ${LAYERS[@]} ; do
	mkdir -p "$LAYERSMNTDIR"/"$layer"
	mkdir -p "$UPPERDIRS"/"$layer"
	mkdir -p "$WORKDIRS"/"$layer"
	mkdir -p "$SYSROOTSDIR"/"$layer"
done

i "Mounting LiveKit ..."
mount "$LIVEKIT_DEV" /run/initramfs/livekit

i "Mounting base sysroot ..."
# Setup base squashfs.
mount -t squashfs "$BASESQUASHFS" "$SYSROOTSDIR"/base

i "Setting up layers ..."
for layer in ${LAYERS[@]} ; do
	# Mount the layer first.
	mount -t squashfs -o ro "$LAYERSDIR"/"$layer".squashfs "$LAYERSMNTDIR"/"$layer"
	# Their basedir is always base.
	mount -t overlay overlay:$layer \
		-o lowerdir="$LAYERSMNTDIR"/"$layer":"$SYSROOTSDIR"/base,workdir="$WORKDIRS"/"$layer",upperdir="$UPPERDIRS"/"$layer",redirect_dir=on \
		"$SYSROOTSDIR"/"$layer"
done

if [ -e "$LAYERSDIR"/nvidia.squashfs ] ; then
	i "Setting up desktop+nvidia ..."
	mkdir -p "$LAYERSMNTDIR"/desktop-nvidia
	mkdir -p "$WORKDIRS"/desktop-nvidia
	mkdir -p "$UPPERDIRS"/desktop-nvidia
	mkdir -p "$SYSROOTSDIR"/desktop-nvidia
	mount -t squashfs "$LAYERSDIR"/nvidia.squashfs "$LAYERSMNTDIR"/desktop-nvidia
	mount -t overlay -o ro overlay:desktop-nvidia \
		-o lowerdir="$LAYERSMNTDIR"/desktop-nvidia:"$SYSROOTSDIR"/desktop,upperdir="$UPPERDIRS"/desktop-nvidia,workdir="$WORKDIRS"/desktop-nvidia,redirect_dir=on \
		"$SYSROOTSDIR"/desktop-nvidia

fi

i "That's all for now!"

# For now, we only boot to LiveKit.
# TODO Read command line to know what we want to boot.
# TODO setup users. However this can not be done while in initrd.

# Mount LiveKit to /sysroot.
mount --bind /run/initramfs/sysroots/livekit /sysroot

# Inform dracut that root is set up.
ln -s /dev/null /dev/root
