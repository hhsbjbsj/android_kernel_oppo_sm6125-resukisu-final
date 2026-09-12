#!/usr/bin/env bash
set -Eeuo pipefail
echo '===== Keep ReSukiSU/SukiSU sucompat on 4.14 user-pointer ABI ====='

python3 -u - <<'PY'
from pathlib import Path
import re

files = []
for rel in (
    'KernelSU/kernel/feature/sucompat.c',
    'drivers/kernelsu/feature/sucompat.c',
    'KernelSU/kernel/sucompat.c',
    'drivers/kernelsu/sucompat.c',
):
    p = Path(rel)
    if p.is_file():
        files.append(p.resolve())

seen = set()
uniq = []
for p in files:
    key = (p.stat().st_ino, p.stat().st_dev)
    if key in seen:
        continue
    seen.add(key)
    uniq.append(p)
if not uniq:
    found = list(Path('.').rglob('sucompat.c'))
    raise SystemExit('sucompat.c not found: %s' % found[:8])

FA_USER = '''int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *__unused_flags)
{
	char path[sizeof(su_path) + 1] = { 0 };

	if (unlikely(!filename_user || !*filename_user))
		return 0;
	if (ksu_strncpy_from_user_nofault(path, *filename_user, sizeof(path)) < 0)
		return 0;
	if (likely(memcmp(path, su_path, sizeof(su_path))))
		return 0;
	if (current_chrooted()) {
		pr_err("ksu_handle_faccessat: su found but NOT allowed! Because current process is running in chrooted environment\\n");
		return 0;
	}
	pr_info("ksu_handle_faccessat: su->sh!\\n");
	*filename_user = sh_path;
	return 0;
}'''

FA_USER_SU = FA_USER.replace('su_path', 'su').replace('sh_path', 'sh')


def pick_names(text):
    if re.search(r'\bsu_path\b', text) and re.search(r'\bsh_path\b', text):
        return 'su_path', 'sh_path', FA_USER
    return 'su', 'sh', FA_USER_SU


def adapt_c(path: Path):
    t = path.read_text()
    changed = []
    su_name, sh_name, fa_body = pick_names(t)

    for old, new, label in (
        (
            """#ifdef CONFIG_KSU_SUSFS
            if (!susfs_is_current_proc_no_su())
                susfs_set_current_proc_no_su();
#endif""",
            """#ifdef CONFIG_KSU_SUSFS
            if (!susfs_is_current_proc_umounted())
                susfs_set_current_proc_umounted();
#endif""",
            'exec init: no_su -> umounted',
        ),
        ('susfs_is_current_proc_no_su()', 'susfs_is_current_proc_umounted()', 'no_su helper -> umounted'),
        ('susfs_set_current_proc_no_su()', 'susfs_set_current_proc_umounted()', 'no_su setter -> umounted'),
    ):
        if old in t and old != new:
            t = t.replace(old, new)
            changed.append(label)

    fa_fn = re.compile(
        r'int ksu_handle_faccessat\s*\(\s*int \*dfd,\s*(?:struct filename \*\*filename|const char __user \*\*filename_user),\s*int \*mode,\s*int \*\w+\s*\)\s*\{.*?\n\}',
        re.S,
    )
    m = fa_fn.search(t)
    if not m:
        raise SystemExit('%s: no faccessat impl to rewrite' % path)
    if 'const char __user **filename_user' in m.group(0) and 'strncpy_from_user' in m.group(0):
        changed.append('faccessat already user-pointer')
    else:
        t = t[:m.start()] + fa_body + t[m.end():]
        changed.append('faccessat: installed 4.14 user-pointer handler')

    t2, n = re.subn(
        r'int ksu_handle_stat\s*\(\s*int \*dfd,\s*struct filename \*\*filename,\s*int \*flags\s*\)',
        'int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags)',
        t,
    )
    if n:
        t = t2
        changed.append('stat proto rewritten to user-pointer x%d' % n)
        t = t.replace('(*filename)->name', 'ksu_stat_user_path')
        if 'ksu_stat_user_path' in t and 'filename_user' in t:
            stat_user = '''int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags)
{
	char path[sizeof(%s) + 1] = { 0 };

	if (unlikely(!filename_user || !*filename_user))
		return 0;
	if (ksu_strncpy_from_user_nofault(path, *filename_user, sizeof(path)) < 0)
		return 0;
	if (likely(memcmp(path, %s, sizeof(%s))))
		return 0;
	*filename_user = %s;
	return 0;
}''' % (su_name, su_name, su_name, sh_name)
            t = re.sub(
                r'int ksu_handle_stat\s*\(\s*int \*dfd,\s*const char __user \*\*filename_user,\s*int \*flags\s*\)\s*\{.*?\n\}',
                stat_user,
                t,
                count=1,
                flags=re.S,
            )
            changed.append('stat: installed 4.14 user-pointer handler')

    t = re.sub(
        r'#if LINUX_VERSION_CODE >= KERNEL_VERSION\(\s*6\s*,\s*1\s*,\s*0\s*\)(?:\s*&&\s*defined\(\s*CONFIG_KSU_SUSFS\s*\))?\s*',
        '#if 0 /* SM6125 4.14: never take GKI filename** sucompat */\n',
        t,
    )

    if not re.search(r'int ksu_handle_faccessat\s*\(\s*int \*dfd,\s*const char __user \*\*filename_user', t):
        raise SystemExit('%s: faccessat still not user-pointer' % path)
    if re.search(r'int ksu_handle_faccessat\s*\(\s*int \*dfd,\s*struct filename \*\*filename', t):
        raise SystemExit('%s: faccessat still filename**' % path)

    path.write_text(t)
    print('%s: %s' % (path, '; '.join(changed) or 'unchanged'), flush=True)


def adapt_h(path: Path):
    if not path.exists():
        return
    h = path.read_text()
    h = re.sub(
        r'int ksu_handle_faccessat\s*\(\s*int \*dfd,\s*struct filename \*\*filename,\s*int \*mode,\s*int \*\w+\s*\)\s*;',
        'int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *__unused_flags);',
        h,
    )
    h = re.sub(
        r'int ksu_handle_stat\s*\(\s*int \*dfd,\s*struct filename \*\*filename,\s*int \*flags\s*\)\s*;',
        'int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);',
        h,
    )
    h = h.replace(
        'int ksu_handle_faccessat(int *dfd, struct filename **filename, int *mode, int *__unused_flags);',
        'int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *__unused_flags);',
    )
    h = h.replace(
        'int ksu_handle_stat(int *dfd, struct filename **filename, int *flags);',
        'int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);',
    )
    path.write_text(h)
    print('updated', path, flush=True)


for cpath in uniq:
    adapt_c(cpath)
    adapt_h(cpath.with_suffix('.h'))

print('[PASS] sucompat kept on 4.14 user-pointer ABI', flush=True)
PY

echo '[PASS] ReSukiSU/SukiSU sucompat aligned to 4.14 user_path_at hooks'
