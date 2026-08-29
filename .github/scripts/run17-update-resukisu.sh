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

echo '===== Keep SUSFS 2.2.0 / 4.14 ABI on cloned ReSukiSU (no kernel-tree edits) ====='
python3 - <<'PY'
from pathlib import Path

compat_if = '#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0) && defined(CONFIG_KSU_SUSFS)\n'

header = Path('KernelSU/kernel/feature/sucompat.h')
h = header.read_text()
old_h_sig = '''// Handler functions exported for hook_manager
#ifdef CONFIG_KSU_SUSFS
int ksu_handle_faccessat(int *dfd, struct filename **filename, int *mode, int *__unused_flags);
int ksu_handle_stat(int *dfd, struct filename **filename, int *flags);
#else
int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *__unused_flags);
int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);
#endif // #ifdef CONFIG_KSU_SUSFS
'''
new_h_sig = '''// Handler functions exported for hook_manager
// 4.14 + SUSFS 2.2.0 overlay still uses user-pointer signatures.
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0) && defined(CONFIG_KSU_SUSFS)
int ksu_handle_faccessat(int *dfd, struct filename **filename, int *mode, int *__unused_flags);
int ksu_handle_stat(int *dfd, struct filename **filename, int *flags);
#else
int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *__unused_flags);
int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);
#endif
'''
if old_h_sig not in h:
    raise SystemExit('sucompat.h signature block not found')
h = h.replace(old_h_sig, new_h_sig, 1)

old_h_susfs = '''#elif defined(CONFIG_KSU_SUSFS) // susfs
#include <linux/susfs_def.h>

#define ksu_is_current_proc_unprivillege susfs_is_current_proc_no_su
#define ksu_set_current_proc_unprivillege susfs_set_current_proc_no_su
#define ksu_clear_current_proc_unprivillege susfs_clear_current_proc_no_su
#else // manual hook
'''
new_h_susfs = '''#elif defined(CONFIG_KSU_SUSFS) // susfs
#include <linux/susfs_def.h>
#include <linux/thread_info.h>

/* SUSFS 2.2.0 does not export no_su / zygote_next helpers. */
#ifndef susfs_is_current_proc_no_su
#ifdef CONFIG_64BIT
#define TIF_PROC_NON_PRIVILEGE 62
#else
#define TIF_PROC_NON_PRIVILEGE 30
#endif
static inline bool susfs_is_current_proc_no_su(void)
{
    return likely(test_thread_flag(TIF_PROC_NON_PRIVILEGE));
}
static inline void susfs_set_current_proc_no_su(void)
{
    set_thread_flag(TIF_PROC_NON_PRIVILEGE);
}
static inline void susfs_clear_current_proc_no_su(void)
{
    clear_thread_flag(TIF_PROC_NON_PRIVILEGE);
}
static inline void susfs_set_current_proc_umounted_for_zygote_next(void)
{
}
#endif

#define ksu_is_current_proc_unprivillege susfs_is_current_proc_no_su
#define ksu_set_current_proc_unprivillege susfs_set_current_proc_no_su
#define ksu_clear_current_proc_unprivillege susfs_clear_current_proc_no_su
#else // manual hook
'''
if old_h_susfs not in h:
    raise SystemExit('sucompat.h susfs no_su block not found')
h = h.replace(old_h_susfs, new_h_susfs, 1)
header.write_text(h)

src = Path('KernelSU/kernel/feature/sucompat.c')
c = src.read_text()
for sig in (
    'int ksu_handle_faccessat(int *dfd, struct filename **filename, int *mode, int *__unused_flags)\n',
    'int ksu_handle_stat(int *dfd, struct filename **filename, int *flags)\n',
):
    old = '#ifdef CONFIG_KSU_SUSFS\n' + sig
    new = compat_if + sig
    if old not in c:
        raise SystemExit(f'sucompat.c missing {sig!r}')
    c = c.replace(old, new, 1)
src.write_text(c)
print('[PASS] cloned ReSukiSU kept SUSFS 2.2.0 / 4.14 ABI')
PY

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
  echo "previous-pin=b2ac2fc8703ce9f5226e2a38a59f8b72f8a3005c"
  echo "susfs220-4.14-abi=kept"
} | tee "$GITHUB_WORKSPACE/run17-resukisu-pin.txt"

echo "[PASS] ReSukiSU KernelSU is ${KSU_SHORT} (version code ${KSU_VERSION})"
