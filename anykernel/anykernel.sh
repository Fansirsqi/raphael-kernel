### AnyKernel3 Ramdisk Mod Script
## KernelSU-Next kernel for Xiaomi Redmi K20 Pro / Mi 9T Pro (raphael / raphaelin)
## This file is copied into an upstream AnyKernel3 checkout by the CI workflow.

### AnyKernel setup
# global properties
properties() { '
kernel.string=KernelSU-Next Kernel for raphael
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=1
device.name1=raphael
device.name2=raphaelin
device.name3=Redmi K20 Pro
device.name4=Mi 9T Pro
device.name5=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties


## boot shell variables
BLOCK=/dev/block/bootdevice/by-name/boot;
IS_SLOT_DEVICE=0;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh;

## AnyKernel install
##
## raphael is a system-as-root device: the stock boot.img has ramdisk_size == 0,
## i.e. there is NO ramdisk inside boot.img (the ramdisk lives in the system
## partition). Therefore we must use split_boot + flash_boot, which only replace
## the kernel. Using dump_boot / write_boot would call unpack_ramdisk and abort
## with "No ramdisk found to unpack. Aborting...".
##
## dtbo is intentionally NOT flashed: this package's dtbo payload is byte-identical
## to the PE13 release, while the real dtbo partition carries AVB metadata
## (AVB0/AVBf) that AK3's flash_generic would overwrite with zero padding.
##
split_boot;
flash_boot;
## end install
