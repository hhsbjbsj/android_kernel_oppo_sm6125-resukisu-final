# PCHM30 reproducible build environment

This directory records the build environment for the real-device-verified OPPO A11x / PCHM30 kernel.

## Toolchain

Use the archived toolchain Release assets rather than arbitrary replacements:

- Snapdragon LLVM ARM Compiler 10.0.7 for Android NDK
- GCC64 4.9 + GNU ld 2.27
- GCC32 4.9
- Python3-compatible patched Qualcomm MPGen working copy
- magiskboot / vmlinux-to-elf helper bundle when needed

Expected Release tag: `pchm30-build-environment-20260810`.

## Setup

Install host dependencies:

```bash
bash tools/pchm30/reproducible-build/bootstrap-host.sh
```

Extract the Release toolchains under `~/pchm30-toolchains`, then:

```bash
source tools/pchm30/reproducible-build/env-pchm30.sh
```

The environment deliberately restores OPPO build identity, `SHIPPING_API_LEVEL=28`, Snapdragon Clang + GNU binutils, and the RTIC MPGen command.

## Important

`nproc` is supplied by GNU coreutils. `nm`, `readelf`, and `objcopy` are supplied by GNU binutils.

For PCHM30, keep the stock Linux 4.14 seccomp ABI. Do not reintroduce synthetic `atomic_t filter_count`.
