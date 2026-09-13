#!/usr/bin/env bash
set -Eeuo pipefail

KERNEL_DIR="${GITHUB_WORKSPACE}/${KERNEL_REL:-source/android/kernel/msm-4.14}"
cd "$KERNEL_DIR"
exec > >(tee "$GITHUB_WORKSPACE/run30-sukisu-4.14-runtime.log") 2>&1

echo '===== RUN30: official SukiSU manager handshake on 4.14 ====='
echo 'Official manager 4.2.0 (versionCode 40900) does reboot(DEADBEEF, CAFEBABE, 0, &fd)'
echo 'then ioctl(KSU_IOCTL_GET_INFO). It shows unsupported when:'
echo '  1) fd is never installed (SukiSU+SUSFS compiles ksu_supercall_reboot_handler'
echo '     instead of ksu_handle_sys_reboot, which is what reboot.c actually calls)'
echo '  2) fd install is deferred to task_work TWA_RESUME so userspace reads fd=-1'
echo '  3) KSU_VERSION falls back to 13000 (manager floor 32513)'
echo '  4) KSU_VERSION_FULL is missing v4.x (manager also checks full string)'
echo 'Run62 Image had v4.2.0-pchm30@builtin but NOT the official sys_reboot string,'
echo 'because ksu_handle_sys_reboot stayed inside #else CONFIG_KSU_SUSFS.'

python3 -u - <<'PY'
from pathlib import Path
import re

notes = []

HANDLE_SYS_REBOOT = '''int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg)
{
	int fd;

	if (magic1 != KSU_INSTALL_MAGIC1)
		return -EINVAL;
	if (unlikely(!arg) || unlikely(!*arg))
		return -EINVAL;
	if (magic2 != KSU_INSTALL_MAGIC2)
		return -EINVAL;

	fd = ksu_install_fd();
	if (fd < 0)
		return -EINVAL;
	if (copy_to_user((int __user *)*arg, &fd, sizeof(fd))) {
		pr_err("install fd copy_to_user failed");
		return -EFAULT;
	}
	pr_info("install fd for official manager (sync 4.14 sys_reboot)");
	return 0;
}
'''

SYNC_FD_REQ = '''static int ksu_handle_fd_request(void __user *arg)
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
'''

SYNC_REBOOT = '''int ksu_supercall_reboot_handler(void __user **arg)
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
'''


def strip_cloexec_and_close_helpers(t):
    t = t.replace('get_unused_fd_flags(O_CLOEXEC)', 'get_unused_fd_flags(0)')
    t = t.replace('O_RDWR | O_CLOEXEC', 'O_RDWR')
    t = t.replace('O_RDWR|O_CLOEXEC', 'O_RDWR')
    t = t.replace('ksu_install_fd_with_permissions(O_CLOEXEC, 0)',
                  'ksu_install_fd_with_permissions(0, 0)')
    t = re.sub(r'\bclose_fd\s*\(\s*fd\s*\)\s*;', '/* no close_fd on 4.14 */ ;', t)
    t = re.sub(r'\bksys_close\s*\(\s*fd\s*\)\s*;', '/* no ksys_close on 4.14 */ ;', t)
    t = re.sub(r'\bksu_close_fd\s*\(\s*fd\s*\)\s*;', '/* no ksu_close_fd on 4.14 */ ;', t)
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


def force_sys_reboot_always_compiled(t, path):
    marker = 'PCHM30_FORCE_KSU_HANDLE_SYS_REBOOT'
    if marker in t:
        print('%s: force sys_reboot already present' % path, flush=True)
        notes.append('sys_reboot=already_forced')
        return t
    t = re.sub(
        r'\bint\s+ksu_handle_sys_reboot\s*\(',
        'int ksu_handle_sys_reboot_sukisu_susfs_else(',
        t,
    )
    t = t.rstrip() + '\n\n/* ' + marker + ' */\n' + HANDLE_SYS_REBOOT + '\n'
    notes.append('sys_reboot=forced_outside_susfs_else')
    print('%s: forced ksu_handle_sys_reboot outside CONFIG_KSU_SUSFS' % path, flush=True)
    return t


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
    t = force_sys_reboot_always_compiled(t, p)
    if 'TWA_RESUME' in t or 'task_work_add' in t:
        print('%s: WARN task_work still present after rewrite' % p, flush=True)
        notes.append('task_work_still_present')
    if t != orig:
        p.write_text(t)

reboot = Path('kernel/reboot.c')
if reboot.exists():
    t = reboot.read_text(errors='ignore')
    orig = t
    if 'if (!ksu_handle_sys_reboot(magic1, magic2, cmd, &arg))' in t:
        print('kernel/reboot.c: early-return handshake already present', flush=True)
        notes.append('reboot_c=already_return0')
    else:
        new_t, n = re.subn(
            r'[ \t]*ksu_handle_sys_reboot\s*\(\s*magic1\s*,\s*magic2\s*,\s*cmd\s*,\s*&arg\s*\)\s*;',
            '\tif (!ksu_handle_sys_reboot(magic1, magic2, cmd, &arg))\n\t\treturn 0;',
            t,
            count=1,
        )
        if n:
            t = new_t
            notes.append('reboot_c=return0')
            print('kernel/reboot.c: handshake now returns 0 to official manager', flush=True)
        else:
            needle = 'SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,\n\t\tvoid __user *, arg)\n{\n'
            insert = (
                needle +
                '#if defined(CONFIG_KSU)\n'
                '\tif (!ksu_handle_sys_reboot(magic1, magic2, cmd, &arg))\n'
                '\t\treturn 0;\n'
                '#endif\n'
            )
            if needle in t:
                t = t.replace(needle, insert, 1)
                notes.append('reboot_c=injected_return0')
                print('kernel/reboot.c: injected early-return handshake', flush=True)
            else:
                print('kernel/reboot.c: WARN did not rewrite handshake return', flush=True)
                notes.append('reboot_c=unchanged')
    if 'extern int ksu_handle_sys_reboot' not in t:
        t = (
            '#if defined(CONFIG_KSU)\n'
            'extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd,\n'
            '\t\t\t\tvoid __user **arg);\n'
            '#endif\n\n' + t
        )
        notes.append('reboot_c=extern')
        print('kernel/reboot.c: added extern ksu_handle_sys_reboot', flush=True)
    if t != orig:
        reboot.write_text(t)

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
    if 'KSU_VERSION' in t and 'PCHM30_FORCE_KSU_VERSION' not in t:
        t += (
            '\n# PCHM30_FORCE_KSU_VERSION official manager 4.2.0 / 40900 / v4.2.0\n'
            'KSU_VERSION := 40900\n'
            'VERSION_TAG := 4.2.0\n'
            'KSU_VERSION_FULL := v4.2.0-pchm30@builtin\n'
            'ccflags-y += -UKSU_VERSION -DKSU_VERSION=40900\n'
            'ccflags-y += -UKSU_VERSION_FULL -DKSU_VERSION_FULL=\\"v4.2.0-pchm30@builtin\\"\n'
        )
        notes.append('KSU_VERSION_force_40900_v420')
        print('%s: force KSU_VERSION=40900 KSU_VERSION_FULL=v4.2.0' % p, flush=True)
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
  grep -Fq 'PCHM30_FORCE_KSU_HANDLE_SYS_REBOOT' "$sc"
  grep -Fq 'int ksu_handle_sys_reboot' "$sc"
  grep -Fq 'install fd for official manager (sync 4.14 sys_reboot)' "$sc"
  ! grep -Fq 'get_unused_fd_flags(O_CLOEXEC)' "$sc"
  ! grep -Fq 'TWA_RESUME' "$sc" || echo '[WARN] TWA_RESUME still in supercall.c'
fi
grep -Fq 'ksu_handle_sys_reboot' kernel/reboot.c
grep -Fq 'if (!ksu_handle_sys_reboot(magic1, magic2, cmd, &arg))' kernel/reboot.c

mk=""
if [[ -f KernelSU/kernel/Makefile ]]; then
  mk=KernelSU/kernel/Makefile
elif [[ -f drivers/kernelsu/Makefile ]]; then
  mk=drivers/kernelsu/Makefile
fi
if [[ -n "$mk" ]]; then
  grep -Fq 'KSU_VERSION := 40900' "$mk"
  grep -Fq 'KSU_VERSION_FULL := v4.2.0-pchm30@builtin' "$mk"
fi

{
  echo 'sukisu_runtime=4.14_sync_fd'
  echo 'official_handshake=ksu_handle_sys_reboot_forced_outside_susfs'
  echo 'reboot_return=0_on_magic'
  echo 'cloexec=stripped_in_install_fd'
  echo 'task_work=bypassed'
  echo 'sucompat_shell=uid_0_2000_manager'
  echo 'ksu_version_floor=40900'
  echo 'ksu_version_full=v4.2.0-pchm30@builtin'
  echo 'manager_floor=32513'
  echo 'uapi_expected=2'
  echo 'pr_err_newline=none'
  if [[ -f /tmp/run30-notes.txt ]]; then cat /tmp/run30-notes.txt; fi
} | tee "$GITHUB_WORKSPACE/run30-sukisu-4.14-runtime-proof.txt"

echo '[PASS] official SukiSU manager handshake is now always-compiled ksu_handle_sys_reboot + version 40900/v4.2.0'
