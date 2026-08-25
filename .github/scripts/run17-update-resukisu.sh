#!/usr/bin/env bash
set -Eeuo pipefail

# Re-pin KernelSU to the Run17 workflow's ReSukiSU commit after the reused
# overlay clones it. Kernel tree source in git is not modified.

KERNEL_DIR="${KERNEL_DIR:-$GITHUB_WORKSPACE/$KERNEL_REL}"
cd "$KERNEL_DIR"

test -n "${RESUKISU_COMMIT:-}"
echo "===== Run17 update ReSukiSU/KernelSU to ${RESUKISU_COMMIT} ====="

rm -rf KernelSU
git clone -q https://github.com/ReSukiSU/ReSukiSU.git KernelSU
git -C KernelSU checkout -q --detach "$RESUKISU_COMMIT"
test "$(git -C KernelSU rev-parse HEAD)" = "$RESUKISU_COMMIT"

test -L drivers/kernelsu
test "$(readlink drivers/kernelsu)" = '../KernelSU/kernel'
test -f KernelSU/kernel/Kconfig
test -f KernelSU/kernel/Makefile
test -f KernelSU/kernel/Kbuild

KSU_COUNT="$(git -C KernelSU rev-list --count HEAD)"
KSU_VERSION="$((30000 + KSU_COUNT + 700))"
KSU_SHORT="$(git -C KernelSU rev-parse --short=8 HEAD)"
KSU_SUBJECT="$(git -C KernelSU log -1 --format='%s')"
KSU_DATE="$(git -C KernelSU log -1 --format='%ci')"

{
  echo "RESUKISU_COMMIT=${RESUKISU_COMMIT}"
  echo "short=${KSU_SHORT}"
  echo "date=${KSU_DATE}"
  echo "subject=${KSU_SUBJECT}"
  echo "rev-list-count=${KSU_COUNT}"
  echo "ksu-version-code=${KSU_VERSION}"
  echo "previous-pin=beaaea0eb895dc41e7b9bf5e3f39e57aa9635bab"
} | tee "$GITHUB_WORKSPACE/run17-resukisu-pin.txt"

echo "[PASS] ReSukiSU KernelSU is ${KSU_SHORT} (version code ${KSU_VERSION})"
