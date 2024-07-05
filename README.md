# dracut(8) module for AOSC OS Installer disc

This dracut module loads the AOSC OS Installer image. It mounts the base SquashFS image and all of the layers, and assembles the layers together to form a complete sysroot.

This dracut module provides a way to create an offline installation media with multiple variants, and optionally a live environment for each variant, while maintaining minimal disk usage by reusing system components (e.g. packages each variant uses in common).

Requirements
------------

- overlayfs (either compiled in or as a kernel module)
- squashfs (either compiled in or as a kernel module, with compression support - depends on the images being mounted)
- bash (yes it is written in Bash, not a standard shell)
- Filesystem and device drivers that is available during initrd

Installation
------------

1. Clone this repo.
2. Run `make install`.

  > [!WARNING]
  > The Makefile prevents you from installing into your live system root. Read the code to know how to override this behaviour.

3. Generate an initramfs image:
  ```sh 
  dracut /boot/live-initramfs.img --add " aosc-livekit-loader " --xz
  ```

Usage
-----

### Kernel command line options

To know what device or partition is going to be mounted as the live media, the `root=` option must be passed to kernel. The `root=` option must be one of the following:

- `root=aosc-livekit:CDLABEL=SomeLabel`: loader tries to find a device/partition with the filesystem label `SomeLabel` as the live media.
- `root=aosc-livekit:UUID=someuuid`: loader tries to find a partition with the UUID `someuuid` as the live media.
  - ISO9660 also supports UUID with the format `yyyy-mm-dd-hh-mm-ss-cs`, e.g. `2024-07-01-14-02-28-00`.
- `root=aosc-livekit:PARTUUID=some-partuuid`: loader tries to find a partition with UUID `some-partuuid` as the live media.
  - This does apply to both GPT, which PARTUUID is a GUID, and MBR, which PARTUUID is a 32-bit partition table ID concatenated with a partition number, e.g. `3bf1d0cf-01`.
- `root=aosc-livekit:/dev/blockdev`: loader tries to treat the device `/dev/blockdev` as the live media.
  - This is highly discouraged, as the device names are totally unpredicatable. Thus this is preserved for testing purposes.

Users can boot into a temporary live environment that is based on various sysroots you provide. The boot target is specified in the `livekit.boot=` option.

> [!NOTE]
> The boot target must be one of the sysroots you provided.

For example, an ISO contains a collection of sysroots, `desktop`, `desktop-nvidia`, `gnome`, `gnome-nvidia`. Users can select the “GNOME Desktop with NVIDIA Driver” boot option, which passes `livekit.boot=gnome-nvidia` option to the kernel.

> [!NOTE]
> You can specify a default one if nothing is specified.

### Layers and sysroots

A layer is a squashfs image of the upper directory of an overlay. Base layer is not a overlay. The squashfs image of the base layer is directly packed from bootstrapped or prebuilt sysroot.

A sysroot is a fully functional root filesystem that is merged from the base layer and other layers. Apart from the base sysroot, which can be a standalone sysroot itself, every other sysroots are the combination of at least two layers, including the base layer, in order to make the overlayfs work.

In short, a sysroot is made up in at least two layers, the first one must be the base layer.

### Layer names and file names

Base layer (or sysroot) must be `base`.

Each layer must have a unique name (you can not store two different files with the same name anyway). The name should only contain alphabets, digits and underscores, and should not start with a digit. Hyphens are allowed, they are converted to underscores internally.

The file name of base sysroot/layer squashfs image must be `base.squashfs`. Without it the module will fail. This is not configurable (yet).

The file name of the overlay squashfs image must be `layer_name.squashfs`. Additional restriction applies: the name must consist of characters that is valid for Bash variable identifiers, i.e. alphabets, digits and underscores. Hyphens are allowed however, to provide convinence. Hyphens are converted into underscores during dependency lookup. The name is case sensitive.

Sysroots can have the same name of the layers, except base. The base layer is bind mounted as a sysroot.

### Mounting layers and sysroots

A sysroot is mounted as one of the following:

- `mount -o lowerdir=/layer1:/layer2:/base`: The resulting sysroot is merged from the base layer, and then layer2, and then layer1. **The merging order is the reverse of the specified order.** The resuting sysroot is read only, as there is no upperdir. This is sutible for OS installers to install an OS variant to the destination, as the sysroot can not be contaminated.
- `mount -o lowerdir=/merged1,upperdir=/upper,workdir=/work`: The resulting sysroot is merged from the *existing* merged sysroot, and an empty *read-write* upper directory, thus creating an read-write sysroot. The upperdir may reside in a tmpfs, which is suitable for the Live CD environment; Or reside in an existing read-write filesystem, to provide persistance.

Suppose there's a three sysroots live image:

- The base layer is an either prebuilt or bootstrapped, fully functional sysroot, that contains only a base system. This base sysroot is the foundation of every other sysroots and, optionally an usable sysroot itself.
- Sysroot 1 is mounted as a merged overlayfs, with the base sysroot as lowerdir, and an empty directory `upper1` as upperdir. Changes are going to be made, i.e. installing/removing packages, installing additional files, etc., to make up the desired sysroot.
- Sysroot 2 is mounted as a merged overlayfs, with the base sysroot as lowerdir, and an empty directory `upper2` as upperdir. This sysroot may totally differ from sysroot 1, but still use the base sysroot as the foundation.
- Sysroot 3 is mounted as a merged overlayfs, but uses existing sysroot 1 or 2 as lowerdir instead pf starting from the base layer, and an empty directory `upper3` as upperdir. This adds an additional layer on top of Sysroot 1 or 2. AOSC OS uses this kind of layer to provide desktop version of AOSC OS with NVIDIA driver pre-installed.

To generate a layer:

```bash
mount -t overlay \
    -o lowerdir=/base,upperdir=/layers/sysroot1,workdir=/work,redirect_dir=on \
    sysroot:sysroot1 /merged/sysroot1
systemd-nspawn -D /merged/sysroot1
# Make changes to build sysroot1 on top of the base layer, e.g. install packages.
exit
umount /merged/sysroot1
# Pack the upperdir into squashfs image
pushd /layers/sysroot1
mksquashfs . /layers/sysroot1.squashfs -comp xz -noappend
popd
```

> [!NOTE]
> You can also create a layer on top of another sysroot, as long as the sysroot is currently mounted, by specifying an mounted sysroot as lowerdir.

### Templates

Templates enables a way to provide a live environment for defined sysroots, tuned for Live CD specific needs, without contaminating the sysroots. This allows clean installation of the booted sysroots.

For example, an ISO has `kde`, `gnome`, and possibly other defined sysroots. These sysroots may not contain a user, and a basic tuned out-of-box live experience. To avoid modifying the sysroot itself, a template can place on top of it, thus having a sysroot tuned for Live CD specific needs, and without modifying the underlying sysroot.

To generate a template, mount another layer on top of the merged sysroot, and make your change in the merged template sysroot:

```bash
mount \
    -o lowerdir=/merged/sysroot1,upperdir=/templates/sysroot1-template,workdir=/templates/work,redirect_dir=on \
    sysroot-template:sysroot1 /templates/merged-sysroot1

systemd-nspawn -D /templates/merged-sysroot1
# install packages, add users, place files, etc.
useradd -m live
...
exit
umount /templates/merged-sysroot1
pushd /templates/sysroot1-template
mksquashfs . /templates/sysroot1.squashfs -noappend -xz
popd
```

The resulting template image must have the same name as the designated sysroot, otherwise manual configuration is required.

### Filesystem layout

A live image compatible to this loader must have the following filesystem layout:

```
/ (root of the live media)
└── squashfs/
    ├── base.squashfs
    ├── layers/
    │   ├── layer1.squashfs
    │   └── layer2.squashfs
    ├── templates/
    │   ├── sysroot1.squashfs
    │   └── sysroot2.squashfs
    └── layers.conf
```

- `/squashfs` is the base directory where everything lives.
- `/squashfs/base.squashfs` is the hard-coded location of the base layer (or sysroot).
- `/squashfs/layers/` is the directory where layers is stored.
- `/squashfs/templates/` is the directory where templates is stored.
- `/squashfs/layers.conf` is the layers configuration file.

### Configuration file

The configuration file stores information of the layers, i.e. how many layers, how many sysroots these layers merge into, and the dependencies of each sysroot.

The configuration file is written in Bash, uses Bash arrays, and is sourced into the loader script during boot.

Here is an example of the config file `/squashfs/layers.conf`:

```bash
# All available layers, except the base layer.
LAYERS=("desktop-common" "gnome" "kde" "mate" "cinnamon" "nvidia")
# All sysroots these layers combine into, again except the base sysroot.
SYSROOTS=("gnome" "gnome-nvidia" "kde" "kde-nvidia" "mate" "mate-nvidia" "cinnamon" "cinnamon-nvidia")
# Their dependencies, or what layers merge into a sysroot.
# GNOME is made up of base, desktop-common and gnome.
SYSROOT_DEP_gnome=("base" "desktop-common" "gnome")
SYSROOT_DEP_gnome_nvidia=("base" "desktop-common" "gnome" "nvidia")
# ... and so on.
# gnome and gnome-nvidia possibly uses the same template for live environment.
# You can specify a custom template name for each sysroot. Otherwise it is the same name of the sysroot.
TEMPLATE_gnome_nvidia="gnome.squashfs" # /squashfs/templates/gnome.squashfs
```

### Booting

An initramfs image with this module installed must be generated beforehand (see [§ Installation](#Installation)). To boot, use the generated initramfs image, and provide necessary kernel command line arguments upon booting:

```
menuentry "Try someOS KDE" {
    linux /boot/kernel root=aosc-livekit:CDLABEL=someOS_Live livekit.boot=kde
    initrd /boot/live-initramfs.img
}

menuentry "Try someOS KDE (With NVIDIA Graphics)" {
    linux /boot/kernel root=aosc-livekit:CDLABEL=someOS_Live livekit.boot=kde-nvidia
    initrd /boot/live-initramfs.img
}
```
