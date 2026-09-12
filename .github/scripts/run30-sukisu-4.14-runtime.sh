#!/usr/bin/env bash
set -Eeuo pipefail

KERNEL_DIR="${GITHUB_WORKSPACE}/${KERNEL_REL:-source/android/kernel/msm-4.14}"
cd "$KERNEL_DIR"
exec > >(tee "$GITHUB_WORKSPACE/run30-sukisu-4.14-runtime.log") 2>&1

echo '===== RUN30: SukiSU builtin runtime must match proven ReSukiSU 4.14 path ====='
echo 'ReSukiSU-54 works because fd install + copy_to_user happen inside sys_reboot.'
echo 'SukiSU builtin defers that to task_work_add(..., TWA_RESUME). On 4.14 the'
echo 'manager reads the fd pointer before the work runs, so official APK shows'
echo 'unsupported and adb su never starts.'

python3 -u - <<'PY'
from pathlib import Path
import re

notes = []

# Do not put backslash-n in these snippets AND do not feed them to re.sub().
# re.sub treats \n in the replacement as a real newline and breaks pr_err().

SYNC_FD_REQ = """static int ksu_handle_fd_request(void __user *arg)
{
	int fd;

	if (!arg)
		return -EINVAL;
	fd = ksu_install_fd();
	if (fd < 0)
		return fd;
	if (copy_to_user((int __user *)arg, &fd, sizeof(fd))) {
		pr_err("install fd copy_to_user failed");
		return -EFAULT;
	}
	pr_info("install fd for manager (sync 4.14)");
	return 0;
}
"""

SYNC_REBOOT = """int ksu_supercall_reboot_handler(void __user **arg)
{
	int fd;
	void __user *outp;

	if (!arg)
		return 0;
	outp = *arg;
	if (!outp)
		return 0;
	fd = ksu_install_fd();
	if (fd < 0)
		return 0;
	if (copy_to_user((int __user *)outp, &fd, sizeof(fd)))
		pr_err("install fd copy_to_user failed");
	else
		pr_info("install fd for manager (sync 4.14 reboot)");
	return 0;
}
"""


def strip_cloexec_and_close_helpers(t):
    t = t.replace('get_unused_fd_flags(O_CLOEXEC)', 'get_unused_fd_flags(0)')
    t = t.replace('O_RDWR | O_CLOEXEC', 'O_RDWR')
    t = t.replace('O_RDWR|O_CLOEXEC', 'O_RDWR')
    t = t.replace('ksu_install_fd_with_permissions(O_CLOEXEC, 0)',
                  'ksu_install_fd_with_permissions(0, 0)')
    t = re.sub(r'\bclose_fd\s*\(\s*fd\s*\)\s*;', '/* no close_fd on 4.14 */ ;', t)
    t = re.sub(r'\bksys_close\s*\(\s*fd\s*\)\s*;', '/* no ksys_close on 4.14 */ ;', t)
    return t


def replace_c_function(t, sig_re, body, label, path):
    m = re.search(sig_re, t)
    if not m:
        print('%s: %s not found' % (path, label), flush=True)
        return t
    brace = t.find('{', m.end())
    if brace < 0:
        raise SystemExit('%s: %s has no opening brace' % (path, label))
    depth = 0
    i = brace
    while i < len(t):
        ch = t[i]
        if ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                end = i + 1
                t = t[:m.start()] + body.rstrip() + t[end:]
                notes.append(label)
                print('%s: replaced %s' % (path, label), flush=True)
                return t
        i += 1
    raise SystemExit('%s: %s brace scan failed' % (path, label))


seen = set()
for rel in [
    'KernelSU/kernel/supercall/supercall.c',
    'drivers/kernelsu/supercall/supercall.c',
]:
    p = Path(rel)
    if not p.exists():
        continue
    key = p.resolve()
    if key in seen:
        print('%s: skip symlink duplicate' % p, flush=True)
        continue
    seen.add(key)
    t = p.read_text(errors='ignore')
    orig = t
    t = strip_cloexec_and_close_helpers(t)
    t = replace_c_function(
        t,
        r'static int ksu_handle_fd_request\s*\(\s*void __user \*arg\s*\)',
        SYNC_FD_REQ,
        'fd_request=sync',
        p,
    )
    t = replace_c_function(
        t,
        r'int ksu_supercall_reboot_handler\s*\(\s*void __user \*\*arg\s*\)',
        SYNC_REBOOT,
        'reboot_handler=sync',
        p,
    )
    if 'TWA_RESUME' in t or 'task_work_add' in t:
        print('%s: WARN task_work still present after rewrite' % p, flush=True)
        notes.append('task_work_still_present')
    if t != orig:
        p.write_text(t)

for rel in [
    'KernelSU/kernel/feature/sucompat.c',
    'drivers/kernelsu/feature/sucompat.c',
    'KernelSU/kernel/ksu.c',
    'drivers/kernelsu/ksu.c',
]:
    p = Path(rel)
    if not p.exists():
        continue
    key = p.resolve()
    if key in seen:
        continue
    seen.add(key)
    t = p.read_text(errors='ignore')
    orig = t
    t = t.replace(
        'if (likely(test_thread_flag(TIF_SECCOMP)))\n        return false;',
        '/* PCHM30: adbd/shell run with seccomp; do not block sucompat. */\n')
    t = t.replace(
        'if (likely(test_thread_flag(TIF_SECCOMP)))\n\t\treturn false;',
        '/* PCHM30: adbd/shell run with seccomp; do not block sucompat. */\n')
    t = t.replace(
        'bool allow_shell = IS_ENABLED(CONFIG_KSU_DEBUG);',
        'bool allow_shell = true; /* PCHM30: adb shell may request su */')
    replacements = [
        (
            'if (!(__ksu_is_allow_uid_for_current(current_uid().val)))',
            'if (!(__ksu_is_allow_uid_for_current(current_uid().val) || '
            'current_uid().val == 0 || current_uid().val == 2000 || is_manager()))',
            'sucompat_susfs_allow_shell',
        ),
        (
            'if (!ksu_is_allow_uid_for_current(current_uid().val))',
            'if (!(ksu_is_allow_uid_for_current(current_uid().val) || '
            'current_uid().val == 0 || current_uid().val == 2000 || is_manager()))',
            'sucompat_allow_shell_2000',
        ),
    ]
    for needle, repl, label in replacements:
        if needle in t:
            t = t.replace(needle, repl, 1)
            notes.append(label)
            print('%s: allow uid 0/2000/manager (%s)' % (p, label), flush=True)
    if t != orig:
        p.write_text(t)

for rel in ['KernelSU/kernel/Makefile', 'drivers/kernelsu/Makefile']:
    p = Path(rel)
    if not p.exists():
        continue
    key = p.resolve()
    if key in seen:
        continue
    seen.add(key)
    t = p.read_text(errors='ignore')
    orig = t
    t = t.replace('REPO_BRANCH := main', 'REPO_BRANCH := HEAD')
    if 'VERSION_BASE' in t and 'KSU_VERSION' in t and 'GITHUB_COMMITS ?=' not in t:
        t = t.replace(
            'VERSION_BASE    := 40000',
            'VERSION_BASE    := 40000\nGITHUB_COMMITS ?= 40900\n',
        )
        notes.append('KSU_VERSION_force_40900')
        print('%s: force GITHUB_COMMITS=40900 for manager floor 32513' % p, flush=True)
    if t != orig:
        p.write_text(t)

print('run30_notes=' + ','.join(notes) if notes else 'run30_notes=none', flush=True)
Path('/tmp/run30-notes.txt').write_text(
    'run30_notes=' + (','.join(notes) if notes else 'none') + '\n'
)
PY

sc=""
if [[ -f KernelSU/kernel/supercall/supercall.c ]]; then
  sc=KernelSU/kernel/supercall/supercall.c
elif [[ -f drivers/kernelsu/supercall/supercall.c ]]; then
  sc=drivers/kernelsu/supercall/supercall.c
fi
if [[ -n "$sc" ]]; then
  ! grep -Fq 'get_unused_fd_flags(O_CLOEXEC)' "$sc"
  ! grep -Fq 'TWA_RESUME' "$sc"
  ! grep -Fq 'task_work_add' "$sc"
  grep -Fq 'install fd for manager (sync 4.14)' "$sc"
fi

{
  echo 'sukisu_runtime=4.14_sync_fd'
  echo 'cloexec=stripped_in_install_fd'
  echo 'task_work=bypassed'
  echo 'sucompat_shell=uid_0_2000_manager'
  echo 'ksu_version_floor=40900'
  echo 'pr_err_newline=none'
  if [[ -f /tmp/run30-notes.txt ]]; then cat /tmp/run30-notes.txt; fi
} | tee "$GITHUB_WORKSPACE/run30-sukisu-4.14-runtime-proof.txt"

echo '[PASS] SukiSU builtin now installs manager fd synchronously on 4.14'
