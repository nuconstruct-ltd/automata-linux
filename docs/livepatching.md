# Kernel Livepatching Guide

Our image supports kernel livepatching via the use of kpatch. 

## General Guidelines on Livepatching

> [!Warning]
> Live-patching is meant to be a stop-gap, not a replacement for a full kernel upgrade. Use it only for urgent, critical fixes when you cannot reboot right away. Schedule a maintenance window when possible and migrate to a newer disk image that already includes the patched, upgraded kernel.

- The current image uses linux kernel 6.15.2, and was compiled with gcc-12 on Ubuntu 22.04. Please build your patches against this kernel version.

## Creating Keys to use with your Livepatch

> [!Note]
> This step should be run before deploying your VM onto a cloud provider.

Use our CLI to generate keys that will be used at a later step to sign and verify the livepatches.
```bash
./cvm-cli generate-livepatch-keys
```

## Creating a Livepatch

1. Please check out the detailed [Patch Author Guide](https://github.com/dynup/kpatch/blob/master/doc/patch-author-guide.md) for details on how to format your livepatch. In general:
  - You should only patch code, not data structures.
  - Please make your patches cumulative. For simplicity, our cvm-image only supports full-replacement patches (ie, patches built with `REPLACE=1`, which is the default setting used by kpatch-build), so only one patch can be active at a time. To give a concrete example: Suppose you create a patch A.ko and applied it to the kernel last month, but now you need to add an additional patch. In this case, when compiling the new patch B.ko, you should also include all the changes that you compiled in A.ko.

2. Clone and build kpatch:
  ```bash
  git clone https://github.com/dynup/kpatch
  cd kpatch && make all
  sudo make install
  ```

3. Build the patch. Our linux kernel config can be found [here](config).
  ```bash
  kpatch-build -s path/to/linux-kernel-src -c path/to/linux-kernel-config -j10 -o patch-output-folder/ your-patch.patch
  ```

  After the build is done, you should see a `livepatch-XXXX.ko` inside the `patch-output-folder/`.

4. Use our CLI tool to sign your livepatch and upload it to your CVM:
  ```bash
  ./cvm-cli livepatch gcp my-cvm-name /path/to/livepatch.ko
  ```