#!/usr/bin/env bash
set -Eeuo pipefail
echo '===== Align ReSukiSU/SukiSU sucompat handlers with SUSFS 2.3 ====='
CANDIDATES=(
  KernelSU/kernel/feature/sucompat.c
  drivers/kernelsu/feature/sucompat.c
  KernelSU/kernel/sucompat.c
  drivers/kernelsu/sucompat.c
)

python3 -u - <<'PY'
from pathlib import Path
import os
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

# unique inodes so a symlink is adapted once
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

FA_NEW = '''int ksu_handle_faccessat(int *dfd, struct filename **filename, int *mode, int *__unused_flags)
{
	if (unlikely(!filename || IS_ERR(*filename) || (*filename)->name == NULL))
		return 0;
	if (likely(memcmp((*filename)->name, su_path, sizeof(su_path))))
		return 0;
	if (current_chrooted()) {
		pr_err("ksu_handle_faccessat: su found but NOT allowed! Because current process is running in chrooted environment\\n");
		return 0;
	}
	pr_info("ksu_handle_faccessat: su->sh!\\n");
	memcpy((void *)((*filename)->name), sh_path, sizeof(sh_path));
	return 0;
}'''

# Some trees use su[]/sh[] instead of su_path/sh_path.
FA_NEW_SU = FA_NEW.replace('su_path', 'su').replace('sh_path', 'sh')

def pick_fa_body(text):
    if re.search(r'\bsu_path\b', text) and re.search(r'\bsh_path\b', text):
        return FA_NEW
    if re.search(r'\bconst char su\[\]', text) or re.search(r'\bsu\[\] = SU_PATH', text):
        return FA_NEW_SU
    return FA_NEW

def adapt_c(path: Path):
    t = path.read_text()
    changed = []

    for old, new, label in (
        ("""#ifdef CONFIG_KSU_SUSFS
            if (!susfs_is_current_proc_umounted())
                susfs_set_current_proc_umounted();
#endif""",
         """#ifdef CONFIG_KSU_SUSFS
            if (!susfs_is_current_proc_no_su())
                susfs_set_current_proc_no_su();
#endif""",
         'exec init: umounted -> no_su'),
        ('susfs_is_current_proc_umounted()', 'susfs_is_current_proc_no_su()', 'umounted helper -> no_su'),
        ('susfs_set_current_proc_umounted()', 'susfs_set_current_proc_no_su()', 'umounted setter -> no_su'),
    ):
        if old in t and old != new:
            t = t.replace(old, new)
            changed.append(label)

    stat_pair = re.compile(
        r'#if LINUX_VERSION_CODE >= KERNEL_VERSION\(6,\s*1,\s*0\)(?:\s*&&\s*defined\(CONFIG_KSU_SUSFS\))?\s*'
        r'(int ksu_handle_stat\s*\(\s*int \*dfd,\s*struct filename \*\*filename,\s*int \*flags\s*\)\s*\{.*?\n\})\s*'
        r'#else\s*'
        r'int ksu_handle_stat\s*\(\s*int \*dfd,\s*const char __user \*\*filename_user,\s*int \*flags\s*\)\s*\{.*?\n\}\s*'
        r'#endif[^\n]*',
        re.S,
    )
    t2, n = stat_pair.subn(r'\1', t, count=1)
    if n:
        t = t2
        changed.append('stat: keep filename** handler, drop 4.14 user-pointer twin')
    else:
        t2, n = re.subn(
            r'int ksu_handle_stat\s*\(\s*int \*dfd,\s*const char __user \*\*filename_user,\s*int \*flags\s*\)',
            'int ksu_handle_stat(int *dfd, struct filename **filename, int *flags)',
            t,
            count=1,
        )
        if n:
            t = t2
            changed.append('stat proto rewritten to filename**')

    fa_user = re.compile(
        r'int ksu_handle_faccessat\s*\(\s*int \*dfd,\s*const char __user \*\*filename_user,\s*int \*mode,\s*int \*\w+\s*\)\s*\{.*?\n\}',
        re.S,
    )
    if re.search(r'int ksu_handle_faccessat\s*\(\s*int \*dfd,\s*struct filename \*\*filename', t):
        changed.append('faccessat already filename**')
    else:
        m = fa_user.search(t)
        if not m:
            raise SystemExit('%s: no faccessat user-pointer impl to rewrite' % path)
        t = t[:m.start()] + pick_fa_body(t) + t[m.end():]
        changed.append('faccessat: installed filename** handler')

    unguarded = '''    if (!static_branch_unlikely(&ksu_su_compat_enabled)) {
        return 0;
    }'''
    guarded = '''#ifdef KSU_COMPAT_USE_STATIC_KEY
    if (!static_branch_unlikely(&ksu_su_compat_enabled)) {
        return 0;
    }
#else
    if (!ksu_su_compat_enabled) {
        return 0;
    }
#endif'''
    if unguarded in t:
        t = t.replace(unguarded, guarded)
        changed.append('wrapped unguarded static_branch_unlikely')

    if '#include <linux/fs.h>' not in t:
        needle = '#include <linux/susfs_def.h>'
        if needle in t:
            t = t.replace(needle, needle + '\n#include <linux/fs.h>\n#include <linux/err.h>', 1)
        else:
            t = '#include <linux/fs.h>\n#include <linux/err.h>\n' + t
        changed.append('added fs.h/err.h')

    for i, line in enumerate(t.splitlines(), 1):
        if 'pr_info(' in line and line.count('"') % 2 == 1:
            raise SystemExit('%s: unterminated pr_info on line %d: %r' % (path, i, line))

    if not re.search(r'int ksu_handle_faccessat\s*\(\s*int \*dfd,\s*struct filename \*\*filename', t):
        raise SystemExit('%s: faccessat still not filename**' % path)
    if not re.search(r'int ksu_handle_stat\s*\(\s*int \*dfd,\s*struct filename \*\*filename', t):
        raise SystemExit('%s: stat still not filename**' % path)
    susfs_span = re.search(r'#ifdef CONFIG_KSU_SUSFS\n(.*)\n#else', t, re.S)
    if susfs_span and re.search(r'int ksu_handle_(?:faccessat|stat)\s*\([^)]*filename_user', susfs_span.group(1)):
        raise SystemExit('%s: SUSFS block still has user-pointer faccessat/stat' % path)

    path.write_text(t)
    print('%s: %s' % (path, '; '.join(changed) or 'unchanged'), flush=True)
    return path

def adapt_h(path: Path):
    if not path.exists():
        return
    h = path.read_text()
    h2, n = re.subn(
        r'int ksu_handle_faccessat\s*\(\s*int \*dfd,\s*const char __user \*\*filename_user,\s*int \*mode,\s*int \*\w+\s*\)\s*;',
        'int ksu_handle_faccessat(int *dfd, struct filename **filename, int *mode, int *__unused_flags);',
        h,
    )
    if n:
        h = h2
    h2, n = re.subn(
        r'#if LINUX_VERSION_CODE >= KERNEL_VERSION\(6,\s*1,\s*0\)\s*&&\s*defined\(CONFIG_KSU_SUSFS\)\s*'
        r'int ksu_handle_stat\s*\(\s*int \*dfd,\s*struct filename \*\*filename,\s*int \*flags\s*\)\s*;\s*'
        r'#else\s*'
        r'int ksu_handle_stat\s*\(\s*int \*dfd,\s*const char __user \*\*filename_user,\s*int \*flags\s*\)\s*;\s*'
        r'#endif[^\n]*\n',
        'int ksu_handle_stat(int *dfd, struct filename **filename, int *flags);\n',
        h,
    )
    if n:
        h = h2
    else:
        h = h.replace(
            'int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);',
            'int ksu_handle_stat(int *dfd, struct filename **filename, int *flags);',
        )
    if 'int ksu_handle_faccessat(int *dfd, struct filename **filename' not in h:
        raise SystemExit('%s: header faccessat not filename**' % path)
    if 'int ksu_handle_stat(int *dfd, struct filename **filename' not in h:
        raise SystemExit('%s: header stat not filename**' % path)
    path.write_text(h)
    print('updated', path, flush=True)

for cpath in uniq:
    adapt_c(cpath)
    adapt_h(cpath.with_suffix('.h'))

print('[PASS] sucompat text rewritten', flush=True)
PY

echo '[PASS] ReSukiSU/SukiSU sucompat aligned to SUSFS 2.3 filename** handlers'
