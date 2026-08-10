#!/usr/bin/env bash
set -Eeuo pipefail

PCHM30_TOOLCHAINS_ROOT="${PCHM30_TOOLCHAINS_ROOT:-$HOME/pchm30-toolchains}"

export SDCLANG_DIR="${SDCLANG_DIR:-$PCHM30_TOOLCHAINS_ROOT/Snapdragon-LLVM-ARM-Compiler-10.0.7-for-Android-NDK}"
export GCC64_DIR="${GCC64_DIR:-$PCHM30_TOOLCHAINS_ROOT/aarch64-linux-android-4.9}"
export GCC32_DIR="${GCC32_DIR:-$PCHM30_TOOLCHAINS_ROOT/arm-linux-androideabi-4.9}"
export MPGEN_DIR="${MPGEN_DIR:-$PCHM30_TOOLCHAINS_ROOT/mpgen-2.7-py3}"

export PATH="$SDCLANG_DIR/bin:$GCC64_DIR/bin:$GCC32_DIR/bin:$PATH"
export PYTHONPATH="$MPGEN_DIR${PYTHONPATH:+:$PYTHONPATH}"

export ARCH=arm64
export TARGET_PRODUCT=trinket
export KCONFIG_NOTIMESTAMP=true
export KBUILD_BUILD_USER=root
export KBUILD_BUILD_HOST=ubuntu-8-196
export KBUILD_BUILD_VERSION=2
export KBUILD_BUILD_TIMESTAMP='Mon May 16 17:39:41 CST 2022'

unset LLVM LLVM_IAS KBUILD_COMPILER_STRING

export CROSS_COMPILE="$GCC64_DIR/bin/aarch64-linux-android-"
export CROSS_COMPILE_ARM32="$GCC32_DIR/bin/arm-linux-androideabi-"
export CC="$SDCLANG_DIR/bin/clang"
export REAL_CC="$SDCLANG_DIR/bin/clang"
export LD="${CROSS_COMPILE}ld"
export CLANG_TRIPLE=aarch64-linux-gnu-
export SHIPPING_API_LEVEL=28
export LOCALVERSION=+
export RTIC_MPGEN="python3 $MPGEN_DIR/mpgen.py"

_n="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 8)"
if [ "$_n" -gt 8 ]; then _n=8; fi
export JOBS="${JOBS:-$_n}"
unset _n
