# PCHM30 ReSukiSU + SUSFS v2.2.0 experimental baseline

Base branches:
- golden: baseline-pchm30-bootable (3f546c60f7801b9679dc23293a2f04e494b21462)
- proven ReSukiSU: resukisu-dev (514c45a931deda26cec529fc48839628e04afeaa)
- experiment: resukisu-susfs220-dev

ReSukiSU:
- commit: beaaea0eb895dc41e7b9bf5e3f39e57aa9635bab
- full-history count: 4355
- calculated KSU_VERSION: 35055

SUSFS:
- version: v2.2.0
- variant: NON-GKI
- kernel patch: JackA1ltman/NonGKI_Kernel_Build_2nd susfs_patch_to_4.14.patch
- v2.2.0 core/ABI reference: ayin0678-sketch/android_kernel_oppo_msm8937-resukisu-susfs22
- mode: CONFIG_KSU_SUSFS=y
- CONFIG_KSU_MANUAL_HOOK disabled

Enabled features:
- SUS_PATH
- SUS_MOUNT
- SUS_KSTAT
- SPOOF_UNAME
- ENABLE_LOG
- HIDE_KSU_SUSFS_SYMBOLS
- SPOOF_CMDLINE_OR_BOOTCONFIG
- OPEN_REDIRECT
- SUS_MAP

PCHM30 production constraints retained:
- Linux 4.14.180-perf+
- SHIPPING_API_LEVEL=28
- RTIC MPGen pipeline
- OPPO stock public X.509 trust chain
- no Magisk ramdisk in final test boot
