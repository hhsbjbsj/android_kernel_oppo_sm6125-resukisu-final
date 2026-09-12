#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="${1:-${IMAGE:-}}"
OUT="${2:-${OUT:-$GITHUB_WORKSPACE/PCHM30-A16-RUN17-BUILTIN-RUNTIME-AK3.zip}}"
AK3_COMMIT="e4b1bb25ca2aabcfd57f694a5998d87130701b71"

if [ -z "$IMAGE" ] || [ ! -s "$IMAGE" ]; then
  echo "ERROR: kernel Image not found: $IMAGE" >&2
  exit 1
fi

WORK="$GITHUB_WORKSPACE/ak3-pchm30-run17"
rm -rf "$WORK"
git clone --filter=blob:none --no-checkout https://github.com/osm0sis/AnyKernel3.git "$WORK"
git -C "$WORK" checkout "$AK3_COMMIT" -- .
rm -rf "$WORK/.git" "$WORK/.github" "$WORK/README.md"
rm -rf "$WORK/modules" "$WORK/patch" "$WORK/ramdisk"

# Never ship dtbo/dtb that Recovery/AK3 might flash.
rm -f "$WORK"/dtbo.img "$WORK"/dtb "$WORK"/dtb.img "$WORK"/Image.gz-dtb \
      "$WORK"/Image-dtb "$WORK"/Image.gz "$WORK"/vendor_boot.img 2>/dev/null || true

cat > "$WORK/anykernel.sh" <<'AK'
### AnyKernel3 Ramdisk Mod Script
## PCHM30 / OPPO A11x boot-only installer (no dtbo/dtb/vendor_boot)

properties() { '
kernel.string=PCHM30 A16 ReSukiSU/SukiSU SUSFS 2.3 boot-only
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=PCHM30
device.name2=OP4A54
device.name3=
device.name4=
device.name5=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; }

boot_attributes() {
set_perm_recursive 0 0 755 644 $RAMDISK/*;
set_perm_recursive 0 0 750 750 $RAMDISK/init* $RAMDISK/sbin;
}

# PCHM30 is a legacy non-A/B boot partition device.
# Replace kernel Image only. Never flash dtbo/dtb/vendor_boot.
BLOCK=boot;
IS_SLOT_DEVICE=0;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

. tools/ak3-core.sh;

# Kernel-only replacement: preserve the currently installed ramdisk and
# any separate/appended kernel DTB that magiskboot extracts from boot.
dump_boot;
write_boot;
AK

sed -i \
  -e 's/^flash_generic dtbo;/# flash_generic dtbo;/' \
  -e 's/^flash_generic dtb;/# flash_generic dtb;/' \
  -e 's/^flash_dtbo;/# flash_dtbo;/' \
  -e 's/^flash_dtb;/# flash_dtb;/' \
  "$WORK/anykernel.sh"
if grep -qE '^flash_generic dtbo;|^flash_generic dtb;|^flash_dtbo;|^flash_dtb;' "$WORK/anykernel.sh"; then
  echo "ERROR: AnyKernel still flashes dtbo/dtb" >&2
  exit 1
fi

cp -f "$IMAGE" "$WORK/Image"
cat > "$WORK/FLASH-NOTE.txt" <<EOF
PCHM30 first-splash fix
=======================
This zip flashes ONLY /boot (kernel Image).
It does not write dtbo, dtb, vendor_boot, or vbmeta.

If a previous zip already wrote a bad dtbo, restore stock dtbo first,
then flash this package.

Kernel Image SHA256: $(sha256sum "$IMAGE" | awk '{print $1}')
AnyKernel3 pinned commit: $AK3_COMMIT
EOF

cat > "$WORK/RUN17-INFO.txt" <<EOF
PCHM30 A16 boot-only AnyKernel3
================================
Package type: AnyKernel3 kernel-only installer.
AnyKernel3 pinned commit: $AK3_COMMIT
Kernel Image SHA256: $(sha256sum "$IMAGE" | awk '{print $1}')

The installer preserves the boot ramdisk and existing DTB layout while replacing
only the kernel Image. No dtbo/dtb partition flash.
EOF

(
  cd "$WORK"
  zip -r9 "$OUT" . -x '*.git*' '*placeholder' >/dev/null
)

test -s "$OUT"
sha256sum "$OUT" | tee "$OUT.sha256"
echo "AK3 package ready: $OUT"
