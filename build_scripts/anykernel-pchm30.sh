### AnyKernel3 Ramdisk Mod Script
## PCHM30 / OPPO A11x boot-only installer (Clean Experimental)

properties() { '
kernel.string=PCHM30 Clean Experimental Kernel
do.devicecheck=0
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=PCHM30
device.name2=OP4A54
device.name3=trinket
device.name4=ginkgo
device.name5=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; }

boot_attributes() {
set_perm_recursive 0 0 755 644 /*;
set_perm_recursive 0 0 750 750 /init* /sbin;
}

# PCHM30 is a legacy non-A/B boot partition device.
BLOCK=boot;
IS_SLOT_DEVICE=0;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

. tools/ak3-core.sh;

dump_boot;
write_boot;
