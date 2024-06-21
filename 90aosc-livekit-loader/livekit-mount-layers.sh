#!/bin/bash

set -e

mount() {
	echo -e "\033[1;35mMOUNT\033[0m $@"
	/usr/bin/mount "$@"
}

i() {
	echo "<30>LiveKit: INFO: $@" > /dev/kmsg
	echo -e "\033[1;37m[\033[1;36mINFO\033[1;37m]: $@\033[0m"
}

w() {
	echo "<28>LiveKit: WARN: $@" > /dev/kmsg
	echo -e "\033[1;37m[\033[1;33mWARN\033[1;37m]: $@\033[0m"
}

calc_tmpfs_size() {
	local finalsize ramsize raminmib
	if [ -e /proc/meminfo ] ; then
		ramsize=$(cat /proc/meminfo | head -n 1 | awk '{ print $2 }')
		raminmib=$(echo "$ramsize / 1024" | bc)
	else
		# Do not clobber the result.
		w "Unable to calculate the size of tmpfs since /proc/meminfo is not available." >&2
		# Return 8GB. The filesystem will be RO or will throw out errors if OOM.
		echo "8192"
		return
	fi
	# The size of tmpfs depends on how much RAM the system has, obviously.
	# For >16GiB systems, the size of tmpfs will be 3/4 of them.
	if [ $raminmib -gt 16384 ] ; then
		finalsize=$(echo "$raminmib * 0.75 / 1" | bc)
	# meminfo does not report the actual size of RAM.
	elif [ $raminmib -gt 8000 ] ; then
		finalsize=$(echo "$raminmib * 0.5 / 1" | bc)
	else
		finalsize=4096
	fi
	echo $finalsize
}

read_boot_target() {
	local boot_target
	for arg in $(cat /proc/cmdline) ; do
		if [[ "x$arg" = xlivekit.boot=* ]] ; then
			boot_target=${arg##livekit.boot=}
		fi
	done
	case $boot_target in
		desktop|desktop-nvidia|livekit)
			echo $boot_target
			return
			;;
		*)
			echo "livekit"
			return
			;;
	esac
}

get_squashfs_opt() {
	local opt nr_cpus bc_prgm thrs
	nr_cpus=$(nproc)
	bc_prgm="n=$nr_cpus;(n+1)/2"
	thrs=$(echo "$bc_prgm" | bc)
	opt="ro,threads=$thrs"
	echo $opt
}

gen_mount_opts() {
	local tgt opts var arr lowerdirs
	tgt=$1
	opts=""
	needsupper=0
	# LAYER_DEP_desktop=("base" "desktop-common")
	# LAYER_DEP_desktop_nvidia=("base" "desktop-common" "desktop")
	# LAYER_DEP_livekit=("base" "desktop-common" "livekit")
	# LAYER_DEP_server=("base" "server")
	# like that.
	# The layers must be mounted prior calling this function.
	var="LAYER_DEP_${tgt/-/_}[@]"
	arr=(${!var})
	if [ "${#arr[@]}" -lt "1" ] ; then
		die "Missing layer configuration!"
	fi
	opts="lowerdir="
	lowerdirs=""
	for layer in ${!var} ; do
		lowerdirs="${LAYERSMNTDIR}/${layer}:${lowerdirs}"
	done
	lowerdirs="${LAYERSMNTDIR}/${tgt}:${lowerdirs}"
	lowerdirs=${lowerdirs%%:}
	opts="${opts}${lowerdirs}"
	opts="${opts},redirect_dir=on"
	echo "$opts"
}

i "Welcome to AOSC OS LiveKit!"

i "Command arguments are:"
i "$@"

if [ ! -e "$1" ] ; then
	w "Looks like $1 does not exist. Refusing to continue."
	exit 1
fi

# Device containing LiveKit.
LIVEKIT_DEV="$1"
# Prefix path of everything related to LiveKit.
PREFIX="/run/livekit"
# Where LiveKit should be mounted.
LIVEKIT_MNT="$PREFIX/livemnt"
# Base layer mount path.
BASE_MNT="$PREFIX/base"
# Path containing layered squashfses.
SQUASHFSDIR="$LIVEKIT_MNT/squashfs"
# Path to the base layer.
BASESQUASHFS="$SQUASHFSDIR/base.squashfs"
# Where to contain the mountpoints of various layers.
LAYERSDIR="$SQUASHFSDIR/layers"
# Path containing template squashfses, also acted as layers.
TEMPLATESDIR="$SQUASHFSDIR/templates"
# Where to mount the templte. Only one template can be mounted, since we
# only boot into one target.
TEMPLATEMNTDIR="$PREFIX/template"
SYSROOT_WORKDIR="$PREFIX/work"
SYSROOT_UPPERDIR="$PREFIX/upper"
# The tmpfs backed overlays are in the following layout:
# 0. Mounted Base squashfs as lowerdir (SYSROOTSDIR/base), read-only.
# 1. Mounted layer squashfs as lowerdir (LAYERSMNTDIR/$layer), read-only.
# 2. Merged sysroot ($SYSROOTSDIR/$layer), read-only.
# 3. Template of the boot target as lowerdir (PREFIX/template), read-only.
# 4. Merged sysroot of the boot target (/sysroot), read-write.
# Path containing mountpoints of various layers.
LAYERSMNTDIR="$PREFIX/layers"
# Path containing merged sysroots.
SYSROOTSDIR="$PREFIX/sysroots"
# Mount options for squashfs, mainly decompression threads.
SQUASHFSOPT="$(get_squashfs_opt)"

# This tmpfs holds everything.
i "Creating temporary filesystem ..."
mkdir -p "$PREFIX"
mount -t tmpfs -o "rw,size=$(calc_tmpfs_size)M,relatime" livekit $PREFIX || { w "Can not mount the tmpfs filesystem!" ; exit 1 ; }

i "Creating directory structure ..."
mkdir -p "$LIVEKIT_MNT"
mkdir -p "$LAYERSMNTDIR"
mkdir -p "$LAYERSMNTDIR"/base
mkdir -p "$SYSROOTSDIR"
mkdir -p "$SYSROOTSDIR"/base
mkdir -p "$TEMPLATEMNTDIR"
# For an read-write live root filesystem.
mkdir -p "$PREFIX"/work
mkdir -p "$PREFIX"/upper

i "Mounting LiveKit ..."
mount -o ro "$LIVEKIT_DEV" "$LIVEKIT_MNT"

i "Reading config files (if any) ..."
if [ -e "$SQUASHFSDIR"/layers.conf ] ; then
	source "$SQUASHFSDIR"/layers.conf
else
	w "No layers.conf detected. Using default configuration."
	LAYERS=("desktop-common" "desktop" "desktop-nvidia" "livekit" "server")
	SYSROOT_LAYERS=("desktop" "desktop-nvidia" "livekit" "server")
	LAYER_DEP_desktop=("base" "desktop-common")
	LAYER_DEP_livekit=("base" "desktop-common")
	LAYER_DEP_desktop_nvidia=("base" "desktop-common" "desktop")
	LAYER_DEP_server=("base")
fi

i "Mounting base sysroot ..."
# Setup base squashfs.
mount -t squashfs -o "$SQUASHFSOPT" "$BASESQUASHFS" "$LAYERSMNTDIR"/base
# Bind mount as a sysroot.
mount --bind "$LAYERSMNTDIR"/base "$SYSROOTSDIR"/base

i "Mounting layers ..."
for layer in ${LAYERS[@]} ; do
	mkdir -p "$LAYERSMNTDIR"/"$layer"
	# Mount the layer first.
	mount -t squashfs -o "$SQUASHFSOPT" "$LAYERSDIR"/"$layer".squashfs "$LAYERSMNTDIR"/"$layer"
done

i "Mounting sysroots ..."
for layer in ${SYSROOT_LAYERS[@]} ; do
	mkdir -p "$SYSROOTSDIR"/"$layer"
	overlay_opt=$(gen_mount_opts $layer)
	mount -t overlay sysroot:$layer \
		-o "$overlay_opt" \
		"$SYSROOTSDIR"/"$layer"
done

i "Sysroots are set up successfully."

# Read the target environment to boot into from kernel command line:
# livekit.boot=(desktop|desktop-nvidia|livekit)
# Anything else or empty value will default to livekit.
target=$(read_boot_target)

i "Booting into $target ..."
# If we have a pre-configured template layer, mount it to sysroot.
if [ -e "$TEMPLATESDIR"/"$target".squashfs ] || true ; then
	i "Setting up live environment templates ..."
	# This template is read-write in order to make the system function
	# normally.
	mount -t squashfs -o "$SQUASHFSOPT" "$TEMPLATESDIR"/"$target".squashfs "$TEMPLATEMNTDIR"
	mount -t overlay live-sysroot:$target \
		-o lowerdir="$TEMPLATEMNTDIR":"$SYSROOTSDIR"/$target,upperdir="$SYSROOT_UPPERDIR",workdir="$SYSROOT_WORKDIR",redirect_dir=on \
		/sysroot
else
	i "Bind mounting target sysroot to /sysroot ..."
	mount -t overlay live-sysroot:$target \
		-o lowerdir="$SYSROOTSDIR"/$target,upperdir="$SYSROOT_UPPERDIR",workdir="$SYSROOT_WORKDIR",redirect_dir=on \
		/sysroot
	# Or, bind mount the target to /sysroot.
	mount --bind "$SYSROOTSDIR"/$target /sysroot
fi

i "Finishing up ..."
# Inform dracut that root is set up.
ln -s /dev/null /dev/root
