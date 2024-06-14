# dracut(8) module for AOSC OS Installer disc

This dracut module loads the AOSC OS Installer image. It loads the base SquashFS image, and assembles the layers together to form a complete sysroot.

## Usage

1. Clone this repo.
2. Run `make install`.

  > [!WARNING]
  > The Makefile prevents you from installing into your live system root. Read the code to know how to override this behaviour.

3. Generate an initramfs image:
  ```sh 
  dracut /boot/live-initramfs.img --add " aosc-livekit-loader " --xz
  ```
