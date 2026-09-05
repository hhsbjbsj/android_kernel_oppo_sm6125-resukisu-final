#!/usr/bin/env python3
"""Rewrite SM6125 4.14 SUSFS 2.2 inline hooks to official 2.3 logic.

The PCHM30 overlay does NOT use clean-tree CONFIG_KSU_MANUAL_HOOK.
It uses the same 2.2 inline style as Xiaomi 4.19 / JackA1ltman:
  susfs_is_current_proc_umounted() early-out + user-pointer faccessat/stat.

This file mirrors:
  gitlab.com/simonpunk/susfs4ksu da34bba1 / f3087ec1
  JackA1ltman/NonGKI_Kernel_Build_2nd Patches/susfs_inline_hook_patches.sh
"""
from pathlib import Path
import re


def fail(msg):
    raise SystemExit(msg)


def read(path):
    return Path(path).read_text()


def write(path, text):
    Path(path).write_text(text)
    print('wrote', path, flush=True)


def replace_umounted(text, label):
    n = text.count('susfs_is_current_proc_umounted()')
    if n == 0:
        if 'susfs_is_current_proc_no_su()' in text:
            print(label + ': already no_su', flush=True)
            return text
        fail(label + ': no umounted/no_su early-out')
    text = text.replace('susfs_is_current_proc_umounted()', 'susfs_is_current_proc_no_su()')
    print(label + ': umounted -> no_su x%d' % n, flush=True)
    return text


def unstatic_filename_lookup():
    p = Path('fs/namei.c')
    t = p.read_text()
    old = 'static int filename_lookup(int dfd, struct filename *name, unsigned flags,'
    new = 'int filename_lookup(int dfd, struct filename *name, unsigned flags,'
    if old in t:
        t = t.replace(old, new, 1)
        write('fs/namei.c', t)
        print('unstatic filename_lookup in fs/namei.c', flush=True)
    elif re.search(r'^int filename_lookup\(int dfd, struct filename \*name, unsigned flags,', t, re.M):
        print('filename_lookup already non-static', flush=True)
    else:
        fail('cannot find filename_lookup in fs/namei.c')
    decl = (
        'extern int filename_lookup(int dfd, struct filename *name, unsigned flags,\n'
        '\t\t\tstruct path *path, struct path *root);\n'
    )
    for rel in ('fs/open.c', 'fs/stat.c'):
        text = read(rel)
        if 'extern int filename_lookup(' in text:
            continue
        if '#include <linux/susfs_def.h>' in text:
            text = text.replace(
                '#include <linux/susfs_def.h>',
                '#include <linux/susfs_def.h>\n' + decl,
                1,
            )
        elif '#ifdef CONFIG_KSU_SUSFS' in text:
            text = text.replace(
                '#ifdef CONFIG_KSU_SUSFS',
                '#ifdef CONFIG_KSU_SUSFS\n' + decl,
                1,
            )
        else:
            fail(rel + ': no place to declare filename_lookup')
        write(rel, text)
        print('declared filename_lookup in', rel, flush=True)


# ---- fs/exec.c : TIF_PROC_UMOUNTED -> TIF_PROC_NO_SU ----
exec_t = replace_umounted(read('fs/exec.c'), 'fs/exec.c')
write('fs/exec.c', exec_t)

# ---- fs/open.c ----
open_t = read('fs/open.c')
open_t = open_t.replace(
    'extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,',
    'extern int ksu_handle_faccessat(int *dfd, struct filename **filename, int *mode,',
)
open_t = replace_umounted(open_t, 'fs/open.c proto/early-out')

# Drop the 2.2 early-out that still calls handle(&filename) before lookup.
# Official 2.3 does getname_flags + handle(&fname) + filename_lookup.
old_early = re.compile(
    r'#ifdef CONFIG_KSU_SUSFS\s*' 
    r'if \(likely\(susfs_is_current_proc_no_su\(\)\)\)\s*'
    r'goto orig_flow;\s*'
    r'if \(static_branch_likely\(&ksu_su_compat_enabled\)\)\s*'
    r'if \(unlikely\(__ksu_is_allow_uid_for_current\(current_uid\(\)\.val\)\)\) \{\s*'
    r'ksu_handle_faccessat\(&dfd, &filename, &mode, NULL\);\s*'
    r'\}\s*'
    r'orig_flow:\s*'
    r'#endif\s*',
    re.M,
)
if old_early.search(open_t):
    open_t = old_early.sub('', open_t, count=1)
    print('fs/open.c: removed 2.2 user-pointer early-out', flush=True)
elif 'ksu_handle_faccessat(&dfd, &fname, &mode, NULL)' in open_t:
    print('fs/open.c: handle already uses fname', flush=True)
else:
    print('WARN: fs/open.c 2.2 early-out block not exact; continue', flush=True)

if 'struct filename *fname = NULL;' not in open_t:
    needle = '\tunsigned int lookup_flags = LOOKUP_FOLLOW;\n'
    if needle not in open_t:
        fail('fs/open.c: no lookup_flags anchor')
    open_t = open_t.replace(
        needle,
        needle + '#ifdef CONFIG_KSU_SUSFS\n\tstruct filename *fname = NULL;\n#endif\n',
        1,
    )

old_upa = '\tres = user_path_at(dfd, filename, lookup_flags, &path);'
new_upa = '''#ifdef CONFIG_KSU_SUSFS
	fname = getname_flags(filename, lookup_flags, NULL);
	if (likely(susfs_is_current_proc_no_su()))
		goto orig_faccessat;
	if (static_branch_likely(&ksu_su_compat_enabled)) {
		if (unlikely(__ksu_is_allow_uid_for_current(current_uid().val)))
			ksu_handle_faccessat(&dfd, &fname, &mode, NULL);
	}
orig_faccessat:
	res = filename_lookup(dfd, fname, lookup_flags, &path, NULL);
#else
	res = user_path_at(dfd, filename, lookup_flags, &path);
#endif'''
if 'filename_lookup(dfd, fname, lookup_flags, &path, NULL)' in open_t:
    print('fs/open.c: filename_lookup already present', flush=True)
elif old_upa not in open_t:
    fail('fs/open.c: user_path_at site not found')
else:
    open_t = open_t.replace(old_upa, new_upa, 1)
    print('fs/open.c: user_path_at -> getname_flags + filename_lookup', flush=True)
write('fs/open.c', open_t)

# ---- fs/stat.c ----
stat_t = read('fs/stat.c')
if '#include "internal.h"' not in stat_t:
    if '#include <linux/syscalls.h>' in stat_t:
        stat_t = stat_t.replace(
            '#include <linux/syscalls.h>',
            '#include <linux/syscalls.h>\n#include "internal.h"',
            1,
        )
    elif '#include <linux/susfs_def.h>' in stat_t:
        stat_t = stat_t.replace(
            '#include <linux/susfs_def.h>',
            '#include <linux/susfs_def.h>\n#include "internal.h"',
            1,
        )

stat_t = stat_t.replace(
    'extern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);',
    'extern int ksu_handle_stat(int *dfd, struct filename **filename, int *flags);',
)
stat_t = stat_t.replace(
    'extern int ksu_handle_stat(int *dfd, const char __user **filename_user,\n\t\t\t\tint *flags);',
    'extern int ksu_handle_stat(int *dfd, struct filename **filename,\n\t\t\t\tint *flags);',
)
if 'susfs_is_current_proc_umounted()' in stat_t or 'susfs_is_current_proc_no_su()' in stat_t:
    stat_t = replace_umounted(stat_t, 'fs/stat.c proto/early-out')

old_stat_early = re.compile(
    r'#ifdef CONFIG_KSU_SUSFS\s*'
    r'if \(likely\(susfs_is_current_proc_no_su\(\)\)\)\s*'
    r'goto orig_flow;\s*'
    r'if \(static_branch_likely\(&ksu_su_compat_enabled\)\) \{\s*'
    r'if \(unlikely\(__ksu_is_allow_uid_for_current\(current_uid\(\)\.val\)\)\)\s*'
    r'ksu_handle_stat\(&dfd, &filename, &flags\);\s*'
    r'\}\s*'
    r'orig_flow:\s*'
    r'#endif\s*',
    re.M,
)
if old_stat_early.search(stat_t):
    stat_t = old_stat_early.sub('', stat_t, count=1)
    print('fs/stat.c: removed 2.2 user-pointer early-out', flush=True)

if 'user_path_at(dfd, filename, lookup_flags, &path)' in stat_t:
    if 'struct filename *fname = NULL;' not in stat_t:
        for anchor in (
            '\tunsigned int lookup_flags = LOOKUP_FOLLOW | LOOKUP_AUTOMOUNT;\n',
            '\tunsigned int lookup_flags = LOOKUP_FOLLOW;\n',
        ):
            if anchor in stat_t:
                stat_t = stat_t.replace(
                    anchor,
                    anchor + '#ifdef CONFIG_KSU_SUSFS\n\tstruct filename *fname = NULL;\n#endif\n',
                    1,
                )
                break
    old_err = '\terror = user_path_at(dfd, filename, lookup_flags, &path);'
    new_err = '''#ifdef CONFIG_KSU_SUSFS
	fname = getname_flags(filename, lookup_flags, NULL);
	if (likely(susfs_is_current_proc_no_su()))
		goto orig_statx;
	if (static_branch_likely(&ksu_su_compat_enabled)) {
		if (unlikely(__ksu_is_allow_uid_for_current(current_uid().val)))
			ksu_handle_stat(&dfd, &fname, &flags);
	}
orig_statx:
	error = filename_lookup(dfd, fname, lookup_flags, &path, NULL);
#else
	error = user_path_at(dfd, filename, lookup_flags, &path);
#endif'''
    if 'filename_lookup(dfd, fname, lookup_flags, &path, NULL)' in stat_t:
        print('fs/stat.c: filename_lookup already present', flush=True)
    elif old_err not in stat_t:
        fail('fs/stat.c: user_path_at site not found')
    else:
        stat_t = stat_t.replace(old_err, new_err, 1)
        print('fs/stat.c: user_path_at -> getname_flags + filename_lookup', flush=True)
else:
    print('fs/stat.c: no vfs_statx user_path_at; keeping syscall-level handle + no_su', flush=True)
    # 4.14 manual newfstatat still uses vfs_fstatat(user pointer).
    # Keep handle(&filename) after proto change only if filename** handler
    # accepts the user pointer through getname inside sucompat.
    if 'ksu_handle_stat(&dfd, &filename, &flag)' in stat_t:
        print('fs/stat.c: newfstatat still passes user filename into handle', flush=True)
write('fs/stat.c', stat_t)

unstatic_filename_lookup()

# sanity
exec_t = read('fs/exec.c')
open_t = read('fs/open.c')
if 'susfs_is_current_proc_no_su()' not in exec_t:
    fail('fs/exec.c missing no_su')
if 'getname_flags(filename, lookup_flags, NULL)' not in open_t:
    fail('fs/open.c missing getname_flags')
if 'filename_lookup(dfd, fname, lookup_flags, &path, NULL)' not in open_t:
    fail('fs/open.c missing filename_lookup')
if 'ksu_handle_faccessat(&dfd, &fname, &mode, NULL)' not in open_t:
    fail('fs/open.c missing filename** faccessat call')
if 'ksu_handle_faccessat(&dfd, &filename' in open_t:
    fail('fs/open.c still has 2.2 user-pointer faccessat call')
if 'susfs_is_current_proc_umounted()' in exec_t:
    fail('fs/exec.c still has umounted early-out')

print('hook rewrite verified', flush=True)
