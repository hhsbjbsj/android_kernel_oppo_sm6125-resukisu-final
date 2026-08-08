#!/usr/bin/env bash
set -Eeuo pipefail

export OPPO_STOCK_SIGNING_X509=/root/oppo_a11x_kernel/dist/stock-cert/oppo-stock-signing-key.x509
export RTIC_MPGEN=/root/oppo_a11x_kernel/mpgen-2.7-py3/run-mpgen.sh
ROOT=/root/oppo_a11x_kernel
KSRC="$ROOT/kernel/android_kernel_modules_and_devicetree_oppo_sm6125/source/android/kernel/msm-4.14"
OUT="$ROOT/build-stockcfg-rtic-stockcert"
STOCK="$ROOT/dist/STOCK-IMAGE-extracted.config"

LLVM="$ROOT/toolchain/Snapdragon-LLVM-ARM-Compiler-10.0.7-for-Android-NDK"
GCC="$ROOT/toolchain/aarch64-linux-android-4.9"

CLANG="$LLVM/bin/clang"
CROSS="$GCC/bin/aarch64-linux-androidkernel-"
SHIM="$ROOT/.clang-binutils"

rm -rf "$OUT"
mkdir -p "$OUT"

cp "$STOCK" "$OUT/.config"

echo "===== ORIGINAL STOCK CONFIG ====="
sha256sum "$STOCK" "$OUT/.config"

export PATH="$LLVM/bin:$GCC/bin:$PATH"

export ARCH=arm64
export SUBARCH=arm64
export TARGET_PRODUCT=trinket

export KBUILD_BUILD_USER=root
export KBUILD_BUILD_HOST=ubuntu-8-196
export KBUILD_BUILD_TIMESTAMP="Mon May 16 17:39:41 CST 2022"
export KBUILD_BUILD_VERSION=2

MAKE_ARGS=(
    O="$OUT"
    ARCH=arm64
    CC="$CLANG -B$SHIM/"
    REAL_CC="$CLANG"
    LD="${CROSS}ld"
    CROSS_COMPILE="$CROSS"
    CLANG_TRIPLE=aarch64-linux-gnu-
    LOCALVERSION=+
    TARGET_PRODUCT=trinket
    SHIPPING_API_LEVEL=28
    PYTHON=/usr/bin/python3
)

echo
echo "===== OLDDEFCONFIG ====="

make -C "$KSRC" \
    "${MAKE_ARGS[@]}" \
    olddefconfig

echo
echo "===== CONFIG AFTER OLDDEFCONFIG ====="

sha256sum "$STOCK" "$OUT/.config"

echo
echo "===== CONFIG DIFF ====="

"$KSRC/scripts/diffconfig" \
    "$STOCK" "$OUT/.config" || true

echo
echo "===== MODULE SIGNING ====="

grep -E '^CONFIG_MODULE_SIG|^# CONFIG_MODULE_SIG' \
    "$OUT/.config"

echo
echo "===== BUILD ====="

make -C "$KSRC" \
    "${MAKE_ARGS[@]}" \
    -j"$(nproc)" \
    Image.gz modules 2>&1 | tee "$ROOT/dist/build-stockcfg-rtic-stockcert.log"

echo
echo "===== KERNEL RELEASE ====="

make -s -C "$KSRC" \
    "${MAKE_ARGS[@]}" \
    kernelrelease

gzip -dc \
    "$OUT/arch/arm64/boot/Image.gz" \
    > "$ROOT/dist/STOCKCFG-RTIC-STOCKCERT-Image.raw"

echo
echo "===== RAW IMAGE SIZE ====="

stat -c '%n : %s bytes' \
    /tmp/a11x-magisk-check/kernel \
    "$ROOT/dist/STOCKCFG-RTIC-STOCKCERT-Image.raw" \
    "$ROOT/dist/NEW-Image.raw"

echo
echo "===== RAW IMAGE SHA256 ====="

sha256sum \
    /tmp/a11x-magisk-check/kernel \
    "$ROOT/dist/STOCKCFG-RTIC-STOCKCERT-Image.raw" \
    "$ROOT/dist/NEW-Image.raw"

echo
echo "===== LINUX VERSION ====="

strings "$ROOT/dist/STOCKCFG-RTIC-STOCKCERT-Image.raw" \
    | grep -m1 '^Linux version '

echo
echo "===== DONE ====="
