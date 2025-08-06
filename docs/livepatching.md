# Kernel Livepatching Guide

Our image supports kernel livepatching via the use of kpatch. 

## General Guidelines on Livepatching

> [!Warning]
> Live-patching is meant to be a stop-gap, not a replacement for a full kernel upgrade. Use it only for urgent, critical fixes when you cannot stop running your CVM right away. Schedule a maintenance window when possible and migrate to a newer disk image that already includes the patched, upgraded kernel.

- The current image uses linux kernel 6.15.2, and was compiled with gcc-12 on Ubuntu 22.04. Please build your patches against this kernel version.

## Creating Keys to use with your Livepatch

> [!Note]
> This step should be run before deploying your VM onto a cloud provider.

Use our CLI to generate keys that will be used at a later step to sign and verify the livepatches.
```bash
./cvm-cli generate-livepatch-keys
```

## Creating a Livepatch

1. Get Linux kernel and required dependencies to build it:

  ```bash
  # Enable deb-src in package list if not enabled yet.
  sudo sed -i 's/^# deb-src/deb-src/' /etc/apt/sources.list
  sudo apt update

  # Get Kernel deps
  sudo apt build-dep linux
  sudo apt install \
    bc gawk flex bison openssl libssl-dev \
    libelf-dev libncurses-dev dkms dwarves \
    libudev-dev libpci-dev libiberty-dev autoconf llvm gcc-12
  
  # Set gcc-12 as the default gcc
  sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-12 120

  # Clone Linux Kernel
  git clone --branch v6.15.2 --depth 1 https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
  ```

> [!Note]
> You should make a copy of this linux kernel source in order to make your patches, as kpatch-build (in the steps below) requires the original un-modified source and the patch diffs.

1. Please check out the detailed [Patch Author Guide](https://github.com/dynup/kpatch/blob/master/doc/patch-author-guide.md) for details on how to format your livepatch. In general:
  - You should only patch code, not data structures.
  - Please make your patches cumulative. For simplicity, our cvm-image only supports full-replacement patches (ie, patches built with `REPLACE=1`, which is the default setting used by kpatch-build), so only one patch can be active at a time. 
  - To give a concrete example: Suppose this is your first patch, `patch1.patch`, built into `patch1.ko` and installed into the CVM:
    ```bash
    diff --git a/fs/proc/meminfo.c b/fs/proc/meminfo.c
    index 83be312159c9..95279525777e 100644
    --- a/fs/proc/meminfo.c
    +++ b/fs/proc/meminfo.c
    @@ -41,6 +41,7 @@ static int meminfo_proc_show(struct seq_file *m, void *v)
            unsigned long sreclaimable, sunreclaim;
            int lru;
    
    +       pr_info("[test] this is a dynamic patch in meminfo_proc_show()!");
            si_meminfo(&i);
            si_swapinfo(&i);
            committed = vm_memory_committed();

    ```

    Later, you need to add another patch. The second patch, `patch2.patch` should look like this:
    ```bash
    diff --git a/fs/proc/meminfo.c b/fs/proc/meminfo.c
    index 83be312159c9..95279525777e 100644
    --- a/fs/proc/meminfo.c
    +++ b/fs/proc/meminfo.c
    @@ -41,6 +41,7 @@ static int meminfo_proc_show(struct seq_file *m, void *v)
            unsigned long sreclaimable, sunreclaim;
            int lru;
    
    +       pr_info("[test] this is a dynamic patch in meminfo_proc_show()!");
            si_meminfo(&i);
            si_swapinfo(&i);
            committed = vm_memory_committed();
    diff --git a/net/netfilter/xt_comment.c b/net/netfilter/xt_comment.c
    index f095557e3ef6..aa95b75d413c 100644
    --- a/net/netfilter/xt_comment.c
    +++ b/net/netfilter/xt_comment.c
    @@ -5,6 +5,7 @@
      * 2003-05-13 Brad Fisher (brad@info-link.net)
      */
    
    +#include <linux/kernel.h>
    #include <linux/module.h>
    #include <linux/skbuff.h>
    #include <linux/netfilter/x_tables.h>
    @@ -20,6 +21,7 @@ static bool
    comment_mt(const struct sk_buff *skb, struct xt_action_param *par)
    {
            /* We always match */
    +       pr_info("[test]: Patched comment_mt called!");
            return true;
    }

    ```

    As you can see in the above example, `patch2.patch` is a superset of `patch1.patch`. This is because when loading `patch2.ko` (generated from `patch2.patch`),
    `patch1.ko` will be unloaded and only `patch2.ko` will be active.
    
    Whenever you need to generate a new patch, the new patch should be a superset of all the applied older patches.


2. Clone and build kpatch:
  ```bash
  git clone https://github.com/dynup/kpatch
  cd kpatch && make all
  sudo make install
  ```


4. Build the livepatch. Our linux kernel config can be found [here](config).
  ```bash
  kpatch-build -s path/to/linux-kernel-src -c path/to/linux-kernel-config -j10 -o patch-output-folder/ your-patch.patch
  ```
  - `-s`: This is the patch to the original **unmodified** linux kernel source code
  - `-c`: This is the path to the linux kernel config, you can use our [config](config).
  - `-o`: The output folder where the built `livepatch-XXXX.ko` will be stored.

  After the build is done, you should see a `livepatch-XXXX.ko` inside the `patch-output-folder/`. kpatch-build will only output one module that contains all the patched functions from across different components in the kernel.

4. Sign the livepatch:

  ```bash
  ./cvm-cli sign-livepatch /path/to/livepatch.ko
  ```

5. Use our CLI tool to deploy the livepatch to your CVM:
  ```bash
  # ./cvm-cli livepatch <cloud-provider> <vm-name> <path-to-livepatch>
  # <cloud-provider> = "aws" or "gcp" or "azure"
  ./cvm-cli livepatch gcp my-cvm-name /path/to/livepatch.ko
  ```