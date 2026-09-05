#!/usr/bin/env bash
set -Eeuo pipefail

KERNEL_DIR="$GITHUB_WORKSPACE/$KERNEL_REL"
cd "$KERNEL_DIR"
exec > >(tee "$GITHUB_WORKSPACE/run18-sukisu-swap.log") 2>&1

: "${SUKISU_REPO:?missing SUKISU_REPO}"
: "${SUKISU_COMMIT:?missing SUKISU_COMMIT}"
: "${SUKISU_COMPAT_SOURCE_COMMIT:?missing SUKISU_COMPAT_SOURCE_COMMIT}"
: "${OUT_DIR:?missing OUT_DIR}"

echo '===== RUN18: keep A16/Run17 hooks, replace only root core with SukiSU ====='
echo "SukiSU repo:   $SUKISU_REPO"
echo "SukiSU commit: $SUKISU_COMMIT"
echo "compat source: $SUKISU_COMPAT_SOURCE_COMMIT"

echo '===== Preserve SUSFS kernel-side hooks ====='
test -f fs/susfs.c
test -f include/linux/susfs.h
test -L drivers/kernelsu
test "$(readlink drivers/kernelsu)" = '../KernelSU/kernel'
grep -Fq 'obj-$(CONFIG_KSU_SUSFS) += susfs.o' fs/Makefile

echo '===== RUN25: lift the proven 4.14 SUSFS 2.2.0 port to 2.3.0 ====='
git show "$GITHUB_SHA:.github/scripts/run25-susfs230-adapt.sh" > "$GITHUB_WORKSPACE/run25-susfs230-adapt.sh"
chmod +x "$GITHUB_WORKSPACE/run25-susfs230-adapt.sh"
"$GITHUB_WORKSPACE/run25-susfs230-adapt.sh"
grep -Fq '#define SUSFS_VERSION "v2.3.0"' include/linux/susfs.h
grep -Fq 'susfs_is_current_proc_no_su()' fs/exec.c
grep -Fq 'filename_lookup(dfd, fname, lookup_flags, &path, NULL)' fs/open.c

echo '===== Fetch PCHM30 SukiSU 4.14 compatibility patch for current builtin pin ====='
PATCH="$GITHUB_WORKSPACE/sukisu-builtin-4.14-compat.patch"
if git fetch --no-tags --depth=1 origin "$GITHUB_SHA" && \
   git show "$GITHUB_SHA:.github/patches/sukisu-builtin-4.14-compat.patch" > "$PATCH" && \
   test -s "$PATCH"; then
  echo "compat_patch_source=$GITHUB_SHA:.github/patches/sukisu-builtin-4.14-compat.patch"
else
  echo '[WARN] run23 local compat patch missing; falling back to proven sukisu-susfs220 patch'
  git fetch --no-tags origin "$SUKISU_COMPAT_SOURCE_COMMIT"
  git show "FETCH_HEAD:tools/pchm30/sukisu-builtin-4.14-compat.patch" > "$PATCH"
  echo "compat_patch_source=$SUKISU_COMPAT_SOURCE_COMMIT:tools/pchm30/sukisu-builtin-4.14-compat.patch"
fi
test -s "$PATCH"
sha256sum "$PATCH"

echo '===== Replace ReSukiSU userspace/root core with pinned SukiSU builtin tree ====='
rm -rf KernelSU
git clone --filter=blob:none --no-checkout "$SUKISU_REPO" KernelSU
git -C KernelSU fetch origin "$SUKISU_COMMIT" --tags
git -C KernelSU checkout --detach "$SUKISU_COMMIT"
test "$(git -C KernelSU rev-parse HEAD)" = "$SUKISU_COMMIT"
test -f KernelSU/kernel/Kconfig
test -f KernelSU/kernel/Makefile
grep -q '^config KSU_SUSFS$' KernelSU/kernel/Kconfig
grep -q 'SUSFS_INLINE_HOOK' KernelSU/kernel/Makefile

git -C KernelSU apply --check "$PATCH"
git -C KernelSU apply "$PATCH"
git -C KernelSU diff --check

grep -Fq 'ksu_strncpy_from_user_nofault(arg' KernelSU/kernel/sulog/event.c
grep -Fq '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)' KernelSU/kernel/runtime/ksud.c
! grep -q '^[[:space:]]*fallthrough;' KernelSU/kernel/policy/allowlist.c
grep -Fq 'DEFINE_STATIC_KEY_TRUE(ksu_su_compat_enabled);' KernelSU/kernel/feature/sucompat.c
grep -Fq 'manager spawn zygote SID mismatch' KernelSU/kernel/hook/lsm_hook.c

echo '===== Re-align SukiSU sucompat after swap overwrote ReSukiSU handlers ====='
git show "$GITHUB_SHA:.github/scripts/adapt-ksu-sucompat230.sh" > "$GITHUB_WORKSPACE/adapt-ksu-sucompat230.sh"
chmod +x "$GITHUB_WORKSPACE/adapt-ksu-sucompat230.sh"
"$GITHUB_WORKSPACE/adapt-ksu-sucompat230.sh"

echo '===== Install PCHM30 Linux 4.14 compatibility marker used by the proven SukiSU branch ====='
cat > include/linux/pchm30_sukisu_4_14_compat.h <<'EOF'
/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _LINUX_PCHM30_SUKISU_4_14_COMPAT_H
#define _LINUX_PCHM30_SUKISU_4_14_COMPAT_H

/*
 * PCHM30 / SukiSU Linux 4.14 compatibility marker.
 * Keep this header intentionally free of global compatibility macros.
 * The pinned SukiSU builtin tree is adapted only by the validated patch.
 */

#endif /* _LINUX_PCHM30_SUKISU_4_14_COMPAT_H */
EOF

python3 - <<'PY'
from pathlib import Path
p = Path('include/uapi/asm-generic/errno.h')
s = p.read_text()
needle = '#include <asm-generic/errno-base.h>\n'
insert = needle + '#ifdef CONFIG_KSU\n#include <linux/pchm30_sukisu_4_14_compat.h>\n#endif\n'
if '#include <linux/pchm30_sukisu_4_14_compat.h>' not in s:
    if s.count(needle) != 1:
        raise SystemExit(f'errno include anchor count={s.count(needle)}')
    s = s.replace(needle, insert, 1)
p.write_text(s)
PY

grep -Fq '#include <linux/pchm30_sukisu_4_14_compat.h>' include/uapi/asm-generic/errno.h

echo '===== Re-resolve config against SukiSU Kconfig; SUSFS stays enabled ====='
./scripts/config --file "$OUT_DIR/.config" -e KSU -e KSU_SUSFS
./scripts/config --file "$OUT_DIR/.config" -d KPM || true
unset LLVM LLVM_IAS KBUILD_COMPILER_STRING
make O="$OUT_DIR" ARCH=arm64 LOCALVERSION=+ \
  CC="$CC" REAL_CC="$REAL_CC" LD="$LD" \
  CROSS_COMPILE="$CROSS_COMPILE" \
  CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
  CLANG_TRIPLE="$CLANG_TRIPLE" olddefconfig

grep -q '^CONFIG_KSU=y$' "$OUT_DIR/.config"
grep -q '^CONFIG_KSU_SUSFS=y$' "$OUT_DIR/.config"
! grep -q '^CONFIG_KPM=y$' "$OUT_DIR/.config"
grep -Fq '#define SUSFS_VERSION "v2.3.0"' include/linux/susfs.h

echo '===== RUN18 SukiSU proof ====='
{
  echo "kernel_base=$(git rev-parse HEAD)"
  echo "sukisu_commit=$(git -C KernelSU rev-parse HEAD)"
  echo "sukisu_origin=$(git -C KernelSU remote get-url origin)"
  echo 'susfs_version=v2.3.0'
  echo 'hooks=exec_no_su+open_filename_lookup+stat_filename'
  echo 'sucompat=realigned_after_swap'
  echo 'kpm=disabled'
  echo 'run17_bpf_builtin_stack=preserved'
} | tee "$GITHUB_WORKSPACE/run18-sukisu-proof.txt"

echo '[PASS] Run18 replaced only the KSU core with pinned SukiSU; SUSFS 2.3.0 hooks and sucompat remain intact'
