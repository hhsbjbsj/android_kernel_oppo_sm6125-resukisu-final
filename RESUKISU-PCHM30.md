# PCHM30 ReSukiSU development baseline

Golden source branch: baseline-pchm30-bootable
Golden tree: 5eafd520838bf62732727a5974b1e09c0cb4125e

ReSukiSU:
- repository: https://github.com/ReSukiSU/ReSukiSU.git
- pinned commit: beaaea0eb895dc41e7b9bf5e3f39e57aa9635bab
- CONFIG_KSU=y
- CONFIG_KSU_MANUAL_HOOK=y
- CONFIG_KSU_MANUAL_HOOK_AUTO_SETUID_HOOK=y
- CONFIG_KSU_MANUAL_HOOK_AUTO_INITRC_HOOK=y
- CONFIG_KSU_MANUAL_HOOK_AUTO_INPUT_HOOK=y
- CONFIG_KALLSYMS=y
- CONFIG_KALLSYMS_ALL=y
- SUSFS intentionally DISABLED for first real-device boot test

PCHM30 production constraints retained:
- SHIPPING_API_LEVEL=28
- proven Snapdragon LLVM 10.0.7 / GCC 4.9 production toolchain
- proven RTIC MPGen path
- OPPO stock public X.509 trust chain
