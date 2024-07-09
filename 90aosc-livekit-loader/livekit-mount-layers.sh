#!/bin/bash

set -e

# Prints warning, information and mount calls to kernel log and stdout
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

die() {
	echo "<28>LiveKit: ERROR: $@" > /dev/kmsg
	echo -e "\033[1;37m[\033[1;31mERROR\033[1;37m]: $@\033[0m"
	systemctl start dracut-emergency.service
}

calc_tmpfs_size() {
	# Calculate the size of the tmpfs dedicated for LiveKit.
	# For RAM size > 16GB, it uses 3/4 of available RAM.
	# For RAM between 8 - 16GB, it uses 1/2 of available RAM.
	# Otherwise 4GB is provisioned.
	# NOTE it won't use exactly the allocated amount. The actual usage
	# is how much files in it.
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
	# Read the boot target from kernel command line.
	# The command line is:
	# livekit.boot=target
	# The target is one of the following:
	# - livekit: boots to the LiveKit environment
	# - desktop: boots to the desktop environment, allows users to try
	#   AOSC OS before installing.
	# - desktop-nvidia: same as above, but with NVIDIA graphics support.
	# Base and server are not meant to be booted live. They must be
	# correctly installed.
	# This function can only be called after the sysroots are mounted.
	# The target sysroot must have a /etc/os-release, otherwise it will
	# fail.
	local boot_target
	for arg in $(cat /proc/cmdline) ; do
		if [[ "x$arg" = xlivekit.boot=* ]] ; then
			boot_target=${arg##livekit.boot=}
		fi
	done
	if [ "x$boot_target" = "x" ] ; then
		boot_target="$DEFAULT_BOOT_TARGET"
	fi
	if [ "x$boot_target" = "x" ] ; then
		boot_target="livekit"
	fi
	if ! [ -d "$SYSROOTSDIR/$boot_target" ] || ! [ -e "$SYSROOTSDIR/$boot_target/etc/os-release" ] ; then
		die "Specified boot target $boot_target is either not mounted or not a full sysroot."
	fi
	echo "$boot_target"
}

get_squashfs_opt() {
	# Decides how many decompression threads squashfs will use.
	local opt nr_cpus bc_prgm thrs
	nr_cpus=$(nproc)
	bc_prgm="n=$nr_cpus;(n+1)/2"
	thrs=$(echo "$bc_prgm" | bc)
	opt="ro,threads=$thrs"
	echo $opt
}

# If a path exists in /proc/mounts
# Unfortunately mount points containing white spaces does not work here.
is_mounted() {
	local path has_mount
	path=$1
	has_mount=0
	if [ "x$path" = "x" ] ; then
		return 1
	fi
	# A dirty trick, as using a while loop creates a subshell, which
	# can't modify any variables.
	has_mount=$( \
	cat /proc/mounts | awk '{ print $2 }' | \
	while read l ; do \
		if [ "x$l" = "x$path" ] ; then \
			echo 1 ; \
			break ; \
		fi ; \
	done
	)
	if [ "x$has_mount" = "x1" ] ; then
		return 0
	else
		return 1
	fi
}

gen_mount_opts() {
	# Generate lowerdirs according to layer dependencies
	local tgt opts var arr lowerdirs typ
	tgt=$1
	typ=$2
	opts=""
	# SYSROOT_DEP_desktop=("base" "desktop-common" "desktop")
	# SYSROOT_DEP_desktop_nvidia=("base" "desktop-common" "desktop" "desktop-nvidia")
	# SYSROOT_DEP_livekit=("base" "desktop-common" "livekit")
	# SYSROOT_DEP_server=("base" "server")
	# like that.
	# The layers must be mounted prior calling this function.
	var="SYSROOT_DEP_${tgt/-/_}[@]"
	arr=(${!var})
	if [ "${#arr[@]}" -lt "1" ] ; then
		die "Missing layer configuration!"
	fi
	opts="lowerdir="
	lowerdirs=""
	for layer in ${!var} ; do
		lowerdirs="${LAYERSMNTDIR}/${layer}:${lowerdirs}"
	done
	if [ "x$typ" = "xlive" ] && is_mounted "$TEMPLATEMNTDIR" ; then
		lowerdirs="$TEMPLATEMNTDIR:${lowerdirs}"
	fi
	lowerdirs=${lowerdirs%%:}
	opts="${opts}${lowerdirs}"
	if [ "x$typ" = "xlive" ] ; then
		opts="${opts},upperdir=$SYSROOT_UPPERDIR,workdir=$SYSROOT_WORKDIR"
	fi
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

# Layers configuration
# The name of overlays. It is read from a config file, or a default value
# will be used if no config file is found.
# Base layer is always excluded.
LAYERS=()
# Sysroots to be combined.
SYSROOT_LAYERS=()
# Sysroot dependencies, i.e. which layers will be merged into the sysroot.
# NOTE only dashes are allowed in the name of layers and sysroot layers,
# apart from alphabets and digits - they must be a valid Bash identifier.
# NOTE base layer must be specified.
# NOTE the last layer of the sysroot must be specified.
SYSROOT_DEP_sysroot_name=()
# EXAMPLE
# LAYERS=("desktop" "server")
# SYSROOTS=("desktop" "server")
# SYSROOT_DEP_desktop=("base" "desktop") # desktop needs base and desktop itself
# SYSROOT_DEP_server=("base" "server")

# Mount points and predefined paths
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
	SYSROOT_DEP_desktop=("base" "desktop-common" "desktop")
	SYSROOT_DEP_livekit=("base" "desktop-common" "livekit")
	SYSROOT_DEP_desktop_nvidia=("base" "desktop-common" "desktop" "desktop-nvidia")
	SYSROOT_DEP_server=("base" "server")
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

# Read the target environment to boot into from kernel command line.
# The allowed values are name of mounted sysroots.
target=$(read_boot_target)
# Allow the loader.conf to load custom template file.
var="TEMPLATE_${target/-/_}"
tgt_template=${!var}
templatefile=
if [ -f "$TEMPLATESDIR/$tgt_template" ] ; then
	i "Using supplied template file $tgt_template for boot target $tgt."
	templatefile="$TEMPLATESDIR/$tgt_template"
else
	i "Using default template file for boot target $tgt."
	templatefile="$TEMPLATESDIR/$target.squashfs"
fi
i "Booting into $target ..."
# /sysroot will be the target filesystem dracut switches to.
# If we have a pre-configured template layer, mount it to sysroot.
if [ -e "$templatefile" ] ; then
	i "Setting up live environment template ..."
	# Mount the template layer, and make a overlay filesystem with the
	# template on top of the boot target sysroot, and make it read-write
	# by specifying an read-write upperdir.
	mount -t squashfs -o "$SQUASHFSOPT" "$templatefile" "$TEMPLATEMNTDIR"
	mount -t overlay live-sysroot:$target \
		-o "$(gen_mount_opts $target live)" \
		/sysroot
else
	i "Mounting target sysroot to /sysroot without a template ..."
	# In case of not having a template, we create a read-write overlay of
	# the boot target sysroot (same as above, use a rw upperdir), then
	# mount it to /sysroot.
	mount -t overlay live-sysroot:$target \
		-o "$(gen_mount_opts $target live)" \
		/sysroot
fi

i "Finishing up ..."
# Inform dracut that the target root filesystem is set up.
ln -s /dev/null /dev/root
