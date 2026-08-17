#!/usr/bin/env bash
set -Eeuo pipefail

KERNEL_DIR="$GITHUB_WORKSPACE/$KERNEL_REL"
cd "$KERNEL_DIR"
exec > >(tee "$GITHUB_WORKSPACE/run19-kpm-enable.log") 2>&1

echo '===== RUN19 EXP1: enable SukiSU KPM on proven Run18 stack ====='
test -d KernelSU/kernel/kpm
test -f KernelSU/kernel/kpm/kpm.c
test -f KernelSU/kernel/Kconfig
grep -q '^config KPM$' KernelSU/kernel/Kconfig
grep -Fq '#include "kpm/kpm.c"' KernelSU/kernel/ksu.c

python3 - <<'PY'
from pathlib import Path
p = Path('KernelSU/kernel/kpm/kpm.c')
s = p.read_text()
if 'pchm30_kpm_access_ok' not in s:
    s = s.replace('access_ok(', 'pchm30_kpm_access_ok(')
    anchor = '#define KPM_NAME_LEN 32\n'
    helper = '''/* PCHM30 Linux 4.14 keeps the legacy 3-argument access_ok(). */\nstatic inline bool pchm30_kpm_access_ok(unsigned long addr, unsigned long size)\n{\n#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 0, 0)\n    return access_ok(VERIFY_READ, (void __user *)addr, size);\n#else\n    return access_ok((void __user *)addr, size);\n#endif\n}\n\n'''
    if s.count(anchor) != 1:
        raise SystemExit(f'KPM helper anchor count={s.count(anchor)}')
    s = s.replace(anchor, helper + anchor, 1)
p.write_text(s)
PY

grep -Fq 'pchm30_kpm_access_ok' KernelSU/kernel/kpm/kpm.c

./scripts/config --file "$OUT_DIR/.config" -e KSU -e KSU_SUSFS -e KPM -e KALLSYMS -e KALLSYMS_ALL
unset LLVM LLVM_IAS KBUILD_COMPILER_STRING
make O="$OUT_DIR" ARCH=arm64 LOCALVERSION=+ \
  CC="$CC" REAL_CC="$REAL_CC" LD="$LD" \
  CROSS_COMPILE="$CROSS_COMPILE" \
  CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
  CLANG_TRIPLE="$CLANG_TRIPLE" olddefconfig

grep -q '^CONFIG_KSU=y$' "$OUT_DIR/.config"
grep -q '^CONFIG_KSU_SUSFS=y$' "$OUT_DIR/.config"
grep -q '^CONFIG_KPM=y$' "$OUT_DIR/.config"
grep -q '^CONFIG_KALLSYMS=y$' "$OUT_DIR/.config"
grep -q '^CONFIG_KALLSYMS_ALL=y$' "$OUT_DIR/.config"
grep -Fq '#define SUSFS_VERSION "v2.2.0"' include/linux/susfs.h

{
  echo "kernel_base=$(git rev-parse HEAD)"
  echo "sukisu_commit=$(git -C KernelSU rev-parse HEAD)"
  echo 'susfs_version=v2.2.0'
  echo 'kpm=config-enabled'
  echo 'kallsyms=enabled'
  echo 'kallsyms_all=enabled'
  echo 'run18_stack=preserved'
} | tee "$GITHUB_WORKSPACE/run19-kpm-config-proof.txt"

echo '[PASS] Run19 staged CONFIG_KPM on top of the proven Run18 stack'
