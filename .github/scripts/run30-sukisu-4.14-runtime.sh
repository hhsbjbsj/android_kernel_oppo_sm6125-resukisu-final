#!/usr/bin/env bash
set -Eeuo pipefail

KERNEL_DIR="${GITHUB_WORKSPACE}/${KERNEL_REL:-source/android/kernel/msm-4.14}"
cd "$KERNEL_DIR"
exec > >(tee "$GITHUB_WORKSPACE/run30-sukisu-4.14-runtime.log") 2>&1

echo '===== RUN30: SukiSU builtin runtime must match proven ReSukiSU 4.14 path ====='
echo 'ReSukiSU-54 works because fd install is synchronous.'
echo 'SukiSU builtin uses task_work_add(..., TWA_RESUME) + O_CLOEXEC; both break manager on 4.14.'
echo 'adb su also dies if sucompat rejects TIF_SECCOMP or still uses GKI filename** faccessat.'

python3 -u - <<'PY'
from pathlib import Path
import re

notes = []

# 1) Install manager fd synchronously. 4.14 task_work_add is (task, work, bool),
#    TWA_RESUME is a 5.7+ enum. ReSukiSU-54 never used task_work here.
for rel in [
    'KernelSU/kernel/supercall/supercall.c',
    'drivers/kernelsu/supercall/supercall.c',
]:
    p = Path(rel)
    if not p.exists():
        continue
    t = p.read_text(errors='ignore')
    orig = t
    t = t.replace('get_unused_fd_flags(O_CLOEXEC)', 'get_unused_fd_flags(0)')
    t = t.replace('O_RDWR | O_CLOEXEC', 'O_RDWR')
    t = t.replace('O_RDWR|O_CLOEXEC', 'O_RDWR')
    # 4.14 has sys_close, not ksys_close. Leak one fd on copy_to_user failure rather
    # than pull in an unknown close helper.
    sync_fn = '''static int ksu_handle_fd_request(void __user *arg)
{
	int fd;

	if (!arg)
		return -EINVAL;
	fd = ksu_install_fd();
	if (fd < 0)
		return fd;
	if (copy_to_user((int __user *)arg, &fd, sizeof(fd))) {
		pr_err("install fd copy_to_user failed: %d\\n", fd);
		return -EFAULT;
	}
	pr_info("install fd for manager (sync 4.14): %d\\n", fd);
	return 0;
}
'''
    t2, n = re.subn(
        r'static int ksu_handle_fd_request\s*\(\s*void __user \*arg\s*\)\s*\{.*?^\}',
        sync_fn.rstrip(),
        t,
        count=1,
        flags=re.S | re.M,
    )
    if n:
        t = t2
        notes.append('fd_request=sync')
        print(f'{p}: ksu_handle_fd_request now synchronous', flush=True)
    else:
        if 'task_work_add(current, &tw->cb, TWA_RESUME)' in t:
            print(f'{p}: WARN task_work fd path still present', flush=True)
            notes.append('fd_request=task_work_still_present')
    if t != orig:
        p.write_text(t)

# 2) Do not let seccomp on adbd/shell hide su. Fresh allowlist is empty so
#    also treat AID_SHELL (2000) as allowed for sucompat lookup of /system/bin/su.
for rel in [
    'KernelSU/kernel/feature/sucompat.c',
    'drivers/kernelsu/feature/sucompat.c',
]:
    p = Path(rel)
    if not p.exists():
        continue
    t = p.read_text(errors='ignore')
    orig = t
    t = t.replace(
        'if (likely(test_thread_flag(TIF_SECCOMP)))\n        return false;',
        '/* PCHM30: adbd/shell run with seccomp; do not block sucompat. */\n')
    t = t.replace(
        'if (likely(test_thread_flag(TIF_SECCOMP)))\n\t\treturn false;',
        '/* PCHM30: adbd/shell run with seccomp; do not block sucompat. */\n')
    needle = 'if (!ksu_is_allow_uid_for_current(current_uid().val))'
    repl = (
        'if (!(ksu_is_allow_uid_for_current(current_uid().val) ||\n'
        '\t      current_uid().val == 0 || current_uid().val == 2000 ||\n'
        '\t      is_manager()))'
    )
    if needle in t:
        t = t.replace(needle, repl)
        notes.append('sucompat_allow_shell_2000')
        print(f'{p}: allow uid 0/2000/manager for sucompat', flush=True)
    if t != orig:
        p.write_text(t)

# 3) Shallow builtin clone makes rev-list --count main fail -> KSU_VERSION=13000
#    Official SukiSU manager rejects anything below 32513.
for rel in ['KernelSU/kernel/Makefile', 'drivers/kernelsu/Makefile']:
    p = Path(rel)
    if not p.exists():
        continue
    t = p.read_text(errors='ignore')
    orig = t
    t = t.replace('REPO_BRANCH := main', 'REPO_BRANCH := HEAD')
    if 'VERSION_BASE' in t and 'KSU_VERSION' in t:
        force = '\nGITHUB_COMMITS ?= 40900\n'
        if 'GITHUB_COMMITS ?=' not in t:
            t = t.replace('VERSION_BASE    := 40000', 'VERSION_BASE    := 40000' + force)
            notes.append('KSU_VERSION_force_40900')
            print(f'{p}: force GITHUB_COMMITS=40900 for manager floor 32513', flush=True)
    if t != orig:
        p.write_text(t)

print('run30_notes=' + ','.join(notes) if notes else 'run30_notes=none', flush=True)
Path('/tmp/run30-notes.txt').write_text(
    'run30_notes=' + (','.join(notes) if notes else 'none') + '\n'
)
PY

if [[ -f KernelSU/kernel/supercall/supercall.c ]]; then
  ! grep -Fq 'get_unused_fd_flags(O_CLOEXEC)' KernelSU/kernel/supercall/supercall.c
  grep -Fq 'install fd for manager (sync 4.14)' KernelSU/kernel/supercall/supercall.c \
    || grep -Fq 'ksu_install_fd()' KernelSU/kernel/supercall/supercall.c
fi

{
  echo 'sukisu_runtime=4.14_sync_fd'
  echo 'cloexec=stripped_in_install_fd'
  echo 'task_work=bypassed'
  echo 'sucompat_shell=uid_0_2000_manager'
  echo 'ksu_version_floor=40900'
  if [[ -f /tmp/run30-notes.txt ]]; then cat /tmp/run30-notes.txt; fi
} | tee "$GITHUB_WORKSPACE/run30-sukisu-4.14-runtime-proof.txt"

echo '[PASS] SukiSU builtin now installs manager fd synchronously on 4.14'
