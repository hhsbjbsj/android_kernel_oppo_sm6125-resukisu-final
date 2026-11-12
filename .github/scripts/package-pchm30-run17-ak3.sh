#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="${1:-${IMAGE:-}}"
OUT="${2:-${OUT:-$GITHUB_WORKSPACE/PCHM30-Run152-BakaSU-SUSFS240-backport-AK3.zip}}"
AK3_COMMIT="e4b1bb25ca2aabcfd57f694a5998d87130701b71"

if [ -z "$IMAGE" ] || [ ! -s "$IMAGE" ]; then
  echo "ERROR: kernel Image not found: $IMAGE" >&2
  exit 1
fi

WORK="$GITHUB_WORKSPACE/ak3-pchm30-run152"
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
kernel.string=__PCHM30_BUILD_LABEL__
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

python3 - "$WORK" "$IMAGE" "$AK3_COMMIT" <<'PY_METADATA'
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

work = Path(sys.argv[1])
image = Path(sys.argv[2])
ak3_commit = sys.argv[3]
susfs_header = Path("include/linux/susfs.h").read_text(encoding="utf-8")
match = re.search(r'^#define\s+SUSFS_VERSION\s+"([^"]+)"', susfs_header, re.M)
if not match or not re.fullmatch(r"[A-Za-z0-9._+-]+", match.group(1)):
    raise SystemExit("Cannot read a safe SUSFS version from the compiled source")
susfs_version = match.group(1)
bakasu_commit = subprocess.check_output(
    ["git", "-C", "KernelSU", "rev-parse", "HEAD"], text=True
).strip()
if not re.fullmatch(r"[0-9a-f]{40}", bakasu_commit):
    raise SystemExit("Cannot read the BakaSU source revision")
release_path = Path(os.environ.get("OUT_DIR", "out-pchm30-a16-bpf")) / "include/config/kernel.release"
kernel_release = release_path.read_text(encoding="utf-8").strip()
proof_path = Path(os.environ.get("GITHUB_WORKSPACE", ".")) / "kernel-version-proof.txt"
version_proof = {}
if proof_path.is_file():
    version_proof = dict(
        line.split("=", 1) for line in proof_path.read_text(encoding="utf-8").splitlines()
        if "=" in line
    )
release_label_only = version_proof.get("release_label_only") == "yes"
full_stable_backport = version_proof.get("full_4.14.357_backport")
baseline_commit = os.environ.get("RUN152_WORKFLOW_REF")
baseline_label = "Run152 " if baseline_commit else ""
label = f"PCHM30 {baseline_label}BakaSU {bakasu_commit[:8]} SUSFS {susfs_version} boot-only"

digest = hashlib.sha256()
with image.open("rb") as image_file:
    for chunk in iter(lambda: image_file.read(1024 * 1024), b""):
        digest.update(chunk)
image_sha256 = digest.hexdigest()
metadata = {
    "target_device": "OPPO A11x / PCHM30 (sm6125)",
    "baseline_run": 152 if baseline_commit else None,
    "baseline_workflow_commit": baseline_commit,
    "build_source_commit": os.environ.get("GITHUB_SHA"),
    "build_run_id": os.environ.get("GITHUB_RUN_ID"),
    "build_run_number": os.environ.get("GITHUB_RUN_NUMBER"),
    "bakasu_commit": bakasu_commit,
    "susfs_version": susfs_version,
    "susfs_port_scope": "PCHM30 4.14 compatibility implementation with selected upstream backports",
    "kernel_release_label": kernel_release,
    "release_label_only": release_label_only,
    "full_4_14_357_backport": (
        full_stable_backport == "yes" if full_stable_backport in ("yes", "no") else None
    ),
    "anykernel3_commit": ak3_commit,
    "image_sha256": image_sha256,
    "installer": "boot-only; preserve current ramdisk and extracted DTB",
}
ak = work / "anykernel.sh"
ak_text = ak.read_text(encoding="utf-8")
if ak_text.count("__PCHM30_BUILD_LABEL__") != 1:
    raise SystemExit("Cannot locate the unique AnyKernel display label")
ak.write_text(ak_text.replace("__PCHM30_BUILD_LABEL__", label, 1), encoding="utf-8")
(work / "BUILD-INFO.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
(work / "BUILD-INFO.txt").write_text(
    label + "\n"
    + f"Build source: {metadata['build_source_commit']}\n"
    + f"Baseline workflow: {baseline_commit}\n"
    + f"BakaSU source: {bakasu_commit}\n"
    + f"SUSFS: {susfs_version} (selected backports for this 4.14 tree)\n"
    + f"Kernel release label: {kernel_release}\n"
    + f"Release-label-only step: {release_label_only}; full 4.14.357 backport: {metadata['full_4_14_357_backport']}\n"
    + f"AnyKernel3: {ak3_commit}\n"
    + f"Image SHA256: {image_sha256}\n",
    encoding="utf-8",
)
(work / "FLASH-NOTE.txt").write_text(
    "PCHM30 kernel-only installer\n"
    "===========================\n"
    "This package replaces the kernel Image in /boot.\n"
    "It preserves the installed ramdisk and DTB extracted from that boot image.\n"
    "It does not flash dtbo, dtb, vendor_boot, or vbmeta partitions.\n\n"
    "The existing boot image and device-tree layout must match this phone.\n"
    f"Image SHA256: {image_sha256}\n"
    f"AnyKernel3 pinned commit: {ak3_commit}\n",
    encoding="utf-8",
)
print(f"[PASS] Embedded build metadata: {label}")
PY_METADATA

(
  cd "$WORK"
  zip -r9 "$OUT" . -x '*.git*' '*placeholder' >/dev/null
)

test -s "$OUT"
sha256sum "$OUT" | tee "$OUT.sha256"
echo "AK3 package ready: $OUT"
