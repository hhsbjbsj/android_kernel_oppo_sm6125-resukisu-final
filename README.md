# OPPO A11x / PCHM30 SM6125 ReSukiSU V8 archive

This is the final archived source snapshot from the OPPO A11x Android 11
ReSukiSU porting attempt.

## Status

**The source compiles and produces a structurally valid boot image, but the
device did not boot the resulting kernel. It remained in or returned to
Fastboot. This repository is not a working release and must not be presented
as boot-tested.**

The repository is preserved for later research and comparison with a complete
vendor source release.

## Device and fixed sources

- Device: OPPO A11x / PCHM30 / 19021
- SoC: Qualcomm SM6125 / Snapdragon 665
- Kernel: Linux 4.14
- OPPO kernel commit: `47e5e4fb39f820a2648c998959b9def509bdb8a3`
- OPPO modules/devicetree commit: `5e7bee452c72c948427b9131bec8cd5d92934f83`
- ReSukiSU commit: `930f61a654f35b98577e5da781fb30f9a1bc678b`

## V8 design

- Clean source tree created from the fixed OPPO kernel commit.
- Qualcomm audio and data remain external vendor DLKMs.
- ReSukiSU uses the Linux 4.14 manual-hook path.
- SUSFS and KernelSU tracepoint hooks are disabled.
- Module signature enforcement is disabled while `CONFIG_MODVERSIONS=y` is retained.
- Only `Image.gz` is built; the stock DTB/RTIC tail is preserved during boot repacking.
- Snapdragon LLVM 10.0.7 and GNU ld 2.27 are required.

The original stock boot image and the failed generated boot image are not
included in this source repository.
