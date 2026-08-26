#!/usr/bin/env bash
set -Eeuo pipefail

KERNEL_DIR="$GITHUB_WORKSPACE/$KERNEL_REL"
cd "$KERNEL_DIR"

MODE="${1:-defer}"
RUN17_STAGE="$GITHUB_WORKSPACE/run17-bbg-lz4kd.sh"
RUN17_PROOF="$GITHUB_WORKSPACE/run17-bbg-zram-stage-proof.txt"
RUN24_STAGE="$GITHUB_WORKSPACE/run24-selinux-hide-compat.sh"
LOG="$GITHUB_WORKSPACE/run19-kpm-enable.log"

if [[ "$MODE" != "--apply" ]]; then
  exec > >(tee "$LOG") 2>&1

  echo '===== RUN24: apply Linux 4.14 SELinux-hide compatibility before KPM defer ====='
  git show "$GITHUB_SHA:.github/scripts/run24-selinux-hide-compat.sh" > "$RUN24_STAGE"
  chmod +x "$RUN24_STAGE"
  "$RUN24_STAGE"
  test -s "$GITHUB_WORKSPACE/run24-selinux-hide-proof.txt"
  grep -Fxq 'selinux_hide_4_14=enabled' "$GITHUB_WORKSPACE/run24-selinux-hide-proof.txt"
  grep -Fxq 'patch_memory=vendored' "$GITHUB_WORKSPACE/run24-selinux-hide-proof.txt"

  echo '===== RUN20: defer KPM until proven Run17 BBG/LZ4KD stage completes ====='
  test -f "$RUN17_STAGE"

  if ! grep -Fq 'RUN19_KPM_APPLY_AFTER_BBG' "$RUN17_STAGE"; then
    cat >> "$RUN17_STAGE" <<'EOF'

# RUN19_KPM_APPLY_AFTER_BBG
# Run17 deliberately verifies that KPM is still disabled. Enable KPM only
# after that proven BBG/LZ4K/LZ4KD staging path has completed successfully.
echo '===== RUN20: enable and harden KPM after Run17 BBG/LZ4KD staging ====='
"$GITHUB_WORKSPACE/run19-kpm-enable.sh" --apply
EOF
  fi

  grep -Fq 'RUN19_KPM_APPLY_AFTER_BBG' "$RUN17_STAGE"
  ! grep -q '^CONFIG_KPM=y$' "$OUT_DIR/.config"
  echo '[PASS] Run20 KPM activation deferred until after Run17 BBG/LZ4KD guard'
  exit 0
fi

exec > >(tee -a "$LOG") 2>&1

echo '===== RUN20: enable SukiSU KPM + PCHM30 4.14 runtime fixes ====='
test -s "$RUN17_PROOF"
grep -Fq 'KPM=not-added' "$RUN17_PROOF"

test -d KernelSU/kernel/kpm
test -f KernelSU/kernel/kpm/kpm.c
test -f KernelSU/kernel/Kconfig
grep -q '^config KPM$' KernelSU/kernel/Kconfig
grep -Fq '#include "kpm/kpm.c"' KernelSU/kernel/ksu.c

python3 - <<'PY'
from pathlib import Path

p = Path('KernelSU/kernel/kpm/kpm.c')
s = p.read_text()

# Linux 4.14 arm64 still uses the legacy three-argument access_ok().
# Keep read/write intent explicit: KPM LIST/INFO/VERSION return data to userspace.
if 'pchm30_kpm_access_ok_read' not in s:
    s = s.replace('access_ok(', 'pchm30_kpm_access_ok_read(')
    anchor = '#define KPM_NAME_LEN 32\n'
    helper = r'''/* PCHM30 Linux 4.14 KPM userspace-pointer compatibility. */
static inline bool pchm30_kpm_access_ok_read(unsigned long addr,
                                             unsigned long size)
{
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 0, 0)
    return access_ok(VERIFY_READ, (void __user *)addr, size);
#else
    return access_ok((void __user *)addr, size);
#endif
}

static inline bool pchm30_kpm_access_ok_write(unsigned long addr,
                                              unsigned long size)
{
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 0, 0)
    return access_ok(VERIFY_WRITE, (void __user *)addr, size);
#else
    return access_ok((void __user *)addr, size);
#endif
}

'''
    if s.count(anchor) != 1:
        raise SystemExit(f'KPM helper anchor count={s.count(anchor)}')
    s = s.replace(anchor, helper + anchor, 1)

# Upstream/pinned KPM LIST bug: arg2 is the requested length, while arg1 is the
# destination userspace pointer. Checking arg2 as a pointer breaks module-list
# refresh and can leave Manager waiting after an install.
old = 'if (!pchm30_kpm_access_ok_read(arg2, len)) {'
new = 'if (!pchm30_kpm_access_ok_write(arg1, len)) {'
if s.count(old) != 1:
    raise SystemExit(f'KPM LIST access_ok bug anchor count={s.count(old)}')
s = s.replace(old, new, 1)

# INFO also writes its result to arg2; result_code is written back to userspace.
s = s.replace(
    'if (!pchm30_kpm_access_ok_read(arg2, size)) {',
    'if (!pchm30_kpm_access_ok_write(arg2, size)) {',
    1,
)
s = s.replace(
    'if (!pchm30_kpm_access_ok_read(cmd.result_code, sizeof(int))) {',
    'if (!pchm30_kpm_access_ok_write(cmd.result_code, sizeof(int))) {',
    1,
)

# Never pass uninitialized stack bytes to the patched KernelPatch handlers.
s = s.replace('char kernel_load_path[256];', 'char kernel_load_path[256] = { 0 };')
s = s.replace('char kernel_args_buffer[256];', 'char kernel_args_buffer[256] = { 0 };')
s = s.replace('char kernel_name_buffer[256];', 'char kernel_name_buffer[256] = { 0 };')
s = s.replace('char buf[256];', 'char buf[256] = { 0 };')
s = s.replace('char buf[1024];', 'char buf[1024] = { 0 };')
s = s.replace('int size;\n', 'int size = 0;\n', 1)

# Add markers around the functions that KernelPatch replaces/hooks. If a KPM
# module init hangs, ENTER appears without EXIT. If load returns but refresh is
# broken, both LOAD lines appear and LIST markers expose the next failing leg.
load_call = '''        sukisu_kpm_load_module_path((const char *)&kernel_load_path,
                                    (const char *)&kernel_args_buffer, NULL,
                                    &res);'''
load_repl = '''        pr_info("PCHM30 RUN20 KPM load ENTER path=%s\\n", kernel_load_path);
        sukisu_kpm_load_module_path((const char *)&kernel_load_path,
                                    (const char *)&kernel_args_buffer, NULL,
                                    &res);
        pr_info("PCHM30 RUN20 KPM load EXIT res=%d\\n", res);'''
if s.count(load_call) != 1:
    raise SystemExit(f'KPM load call anchor count={s.count(load_call)}')
s = s.replace(load_call, load_repl, 1)

list_call = '        sukisu_kpm_list((char *)&buf, sizeof(buf), &res);'
list_repl = '''        pr_info("PCHM30 RUN20 KPM list ENTER requested=%d\\n", len);
        sukisu_kpm_list((char *)&buf, sizeof(buf), &res);
        pr_info("PCHM30 RUN20 KPM list EXIT res=%d\\n", res);'''
if s.count(list_call) != 1:
    raise SystemExit(f'KPM list call anchor count={s.count(list_call)}')
s = s.replace(list_call, list_repl, 1)

# VERSION copies to arg1; reject a zero-length or invalid destination instead
# of underflowing len = outlen - 1.
version_anchor = '''        unsigned int outlen = (unsigned int)arg2;
        int len = strlen(buffer);'''
version_repl = '''        unsigned int outlen = (unsigned int)arg2;
        if (outlen == 0 || !pchm30_kpm_access_ok_write(arg1, outlen)) {
            goto invalid_arg;
        }
        int len = strlen(buffer);'''
if s.count(version_anchor) != 1:
    raise SystemExit(f'KPM version anchor count={s.count(version_anchor)}')
s = s.replace(version_anchor, version_repl, 1)

p.write_text(s)
PY

grep -Fq 'pchm30_kpm_access_ok_read' KernelSU/kernel/kpm/kpm.c
grep -Fq 'pchm30_kpm_access_ok_write' KernelSU/kernel/kpm/kpm.c
grep -Fq 'PCHM30 RUN20 KPM load ENTER' KernelSU/kernel/kpm/kpm.c
grep -Fq 'PCHM30 RUN20 KPM load EXIT' KernelSU/kernel/kpm/kpm.c
grep -Fq 'PCHM30 RUN20 KPM list ENTER' KernelSU/kernel/kpm/kpm.c
grep -Fq 'PCHM30 RUN20 KPM list EXIT' KernelSU/kernel/kpm/kpm.c
grep -Fq 'pchm30_kpm_access_ok_write(arg1, len)' KernelSU/kernel/kpm/kpm.c
! grep -Fq 'pchm30_kpm_access_ok_read(arg2, len)' KernelSU/kernel/kpm/kpm.c

# PCHM30 already carries the arm64 pageattr implementation required by KPM.
grep -Fq 'select ARCH_HAS_SET_MEMORY' arch/arm64/Kconfig
grep -Fq 'int set_memory_x(unsigned long addr, int numpages)' arch/arm64/mm/pageattr.c
grep -Fq 'int set_memory_rw(unsigned long addr, int numpages)' arch/arm64/mm/pageattr.c

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
grep -q '^CONFIG_BBG=y$' "$OUT_DIR/.config"
grep -q '^CONFIG_CRYPTO_LZ4K=y$' "$OUT_DIR/.config"
grep -q '^CONFIG_CRYPTO_LZ4KD=y$' "$OUT_DIR/.config"
grep -Fq '#define SUSFS_VERSION "v2.2.0"' include/linux/susfs.h

{
  echo "kernel_base=$(git rev-parse HEAD)"
  echo "sukisu_commit=$(git -C KernelSU rev-parse HEAD)"
  echo 'susfs_version=v2.2.0'
  echo 'kpm=config-enabled'
  echo 'kpm_list_pointer_fix=enabled'
  echo 'kpm_rw_access_ok_4_14=enabled'
  echo 'kpm_zero_init_buffers=enabled'
  echo 'kpm_runtime_markers=enabled'
  echo 'arm64_set_memory=present'
  echo 'kallsyms=enabled'
  echo 'kallsyms_all=enabled'
  echo 'bbg=preserved'
  echo 'lz4k_lz4kd=preserved'
  echo 'run18_stack=preserved'
  echo 'run24_selinux_hide=staged'
} | tee "$GITHUB_WORKSPACE/run19-kpm-config-proof.txt"

echo '[PASS] Run24 kept Run20 KPM hardening and staged SELinux-hide compatibility'
