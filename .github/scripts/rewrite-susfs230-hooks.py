#!/usr/bin/env python3
"""Rewrite SM6125 4.14 SUSFS 2.2 inline hooks to official 2.3 logic.

Official 2.3 VFS path:
  getname_flags + ksu_handle_*(&fname) + filename_lookup + putname
  TIF_PROC_NO_SU early-out instead of TIF_PROC_UMOUNTED.

vfs_fstatat on this 4.14 tree uses 'int flags', not 'int flag'.
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


def strip_22_early_out(text, handle_line, label):
    pat = re.compile(
        r'#ifdef CONFIG_KSU_SUSFS\s*'
        r'if \(likely\(susfs_is_current_proc_no_su\(\)\)\)\s*'
        r'goto orig_flow;\s*'
        r'if \(static_branch_likely\(&ksu_su_compat_enabled\)\)\s*\{?\s*'
        r'if \(unlikely\(__ksu_is_allow_uid_for_current\(current_uid\(\)\.val\)\)\)\s*\{?\s*'
        + re.escape(handle_line) + r';\s*'
        r'\}?\s*'
        r'\}?\s*'
        r'orig_flow:\s*'
        r'#endif\s*',
        re.M,
    )
    new, n = pat.subn('', text, count=1)
    if n:
        print(label + ': removed 2.2 user-pointer early-out', flush=True)
        return new
    print(label + ': no 2.2 early-out block (ok if already rewritten)', flush=True)
    return text


def detect_stat_flag_name(text, site):
    """OPPO 4.14 vfs_fstatat uses 'int flags'; mainline uses 'int flag'."""
    m = re.search(r'int\s+vfs_fstatat\s*\((.*?)\)', text, re.S)
    if m:
        args = m.group(1)
        if re.search(r'\bint\s+flags\b', args):
            print('fs/stat.c: vfs_fstatat param is flags', flush=True)
            return 'flags'
        if re.search(r'\bint\s+flag\b', args):
            print('fs/stat.c: vfs_fstatat param is flag', flush=True)
            return 'flag'
    pre = text[:text.find(site)] if site in text else text
    window = pre[-800:]
    if re.search(r'\bint flags\b', window):
        print('fs/stat.c: nearby signature uses flags', flush=True)
        return 'flags'
    if re.search(r'\bint flag\b', window):
        print('fs/stat.c: nearby signature uses flag', flush=True)
        return 'flag'
    print('fs/stat.c: defaulting stat handle arg to flags', flush=True)
    return 'flags'


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


exec_t = replace_umounted(read('fs/exec.c'), 'fs/exec.c')
write('fs/exec.c', exec_t)

open_t = read('fs/open.c')
open_t = open_t.replace(
    'extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,',
    'extern int ksu_handle_faccessat(int *dfd, struct filename **filename, int *mode,',
)
open_t = replace_umounted(open_t, 'fs/open.c proto/early-out')
open_t = strip_22_early_out(
    open_t,
    'ksu_handle_faccessat(&dfd, &filename, &mode, NULL)',
    'fs/open.c',
)

old_upa = '\tres = user_path_at(dfd, filename, lookup_flags, &path);'
new_upa = '''#ifdef CONFIG_KSU_SUSFS
	{
		struct filename *fname;

		fname = getname_flags(filename, lookup_flags, NULL);
		if (IS_ERR(fname))
			return PTR_ERR(fname);
		if (likely(susfs_is_current_proc_no_su()))
			goto orig_faccessat;
		if (static_branch_likely(&ksu_su_compat_enabled)) {
			if (unlikely(__ksu_is_allow_uid_for_current(current_uid().val)))
				ksu_handle_faccessat(&dfd, &fname, &mode, NULL);
		}
orig_faccessat:
		res = filename_lookup(dfd, fname, lookup_flags, &path, NULL);
		putname(fname);
	}
#else
	res = user_path_at(dfd, filename, lookup_flags, &path);
#endif'''
if 'filename_lookup(dfd, fname, lookup_flags, &path, NULL)' in open_t:
    print('fs/open.c: filename_lookup already present', flush=True)
elif old_upa not in open_t:
    fail('fs/open.c: faccessat user_path_at site not found')
else:
    open_t = open_t.replace(old_upa, new_upa, 1)
    print('fs/open.c: user_path_at -> getname_flags + filename_lookup + putname', flush=True)
write('fs/open.c', open_t)

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

stat_t = strip_22_early_out(stat_t, 'ksu_handle_stat(&dfd, &filename, &flag)', 'fs/stat.c flag')
stat_t = strip_22_early_out(stat_t, 'ksu_handle_stat(&dfd, &filename, &flags)', 'fs/stat.c flags')

old_err = '\terror = user_path_at(dfd, filename, lookup_flags, &path);'
flag_name = detect_stat_flag_name(stat_t, old_err)
new_err = '''#ifdef CONFIG_KSU_SUSFS
	{
		struct filename *fname;

		fname = getname_flags(filename, lookup_flags, NULL);
		if (IS_ERR(fname))
			return PTR_ERR(fname);
		if (likely(susfs_is_current_proc_no_su()))
			goto orig_statx;
		if (static_branch_likely(&ksu_su_compat_enabled)) {
			if (unlikely(__ksu_is_allow_uid_for_current(current_uid().val)))
				ksu_handle_stat(&dfd, &fname, &%s);
		}
orig_statx:
		error = filename_lookup(dfd, fname, lookup_flags, &path, NULL);
		putname(fname);
	}
#else
	error = user_path_at(dfd, filename, lookup_flags, &path);
#endif''' % flag_name
if re.search(r'ksu_handle_stat\(&dfd, &fname, &flags?\)', stat_t) and \
   'filename_lookup(dfd, fname, lookup_flags, &path, NULL)' in stat_t:
    print('fs/stat.c: filename** lookup already present', flush=True)
elif old_err in stat_t:
    stat_t = stat_t.replace(old_err, new_err, 1)
    print('fs/stat.c: vfs_fstatat user_path_at -> getname_flags + filename_lookup + putname using &%s' % flag_name, flush=True)
else:
    old_call = 'ksu_handle_stat(&dfd, &filename, &%s);' % flag_name
    alt_call = 'ksu_handle_stat(&dfd, &filename, &flag);' if flag_name != 'flag' else 'ksu_handle_stat(&dfd, &filename, &flags);'
    new_call = '''{
			struct filename *fname = getname_flags(filename, LOOKUP_FOLLOW, NULL);
			if (!IS_ERR(fname)) {
				ksu_handle_stat(&dfd, &fname, &%s);
				putname(fname);
			}
		}''' % flag_name
    if old_call in stat_t:
        stat_t = stat_t.replace(old_call, new_call, 1)
        print('fs/stat.c: syscall handle rewritten to filename**', flush=True)
    elif alt_call in stat_t:
        stat_t = stat_t.replace(alt_call, new_call, 1)
        print('fs/stat.c: syscall handle rewritten to filename** (alt name)', flush=True)
    else:
        print('WARN: fs/stat.c has no vfs_fstatat user_path_at and no syscall handle', flush=True)
write('fs/stat.c', stat_t)

unstatic_filename_lookup()

exec_t = read('fs/exec.c')
open_t = read('fs/open.c')
stat_t = read('fs/stat.c')
if 'susfs_is_current_proc_no_su()' not in exec_t:
    fail('fs/exec.c missing no_su')
if 'getname_flags(filename, lookup_flags, NULL)' not in open_t:
    fail('fs/open.c missing getname_flags')
if 'filename_lookup(dfd, fname, lookup_flags, &path, NULL)' not in open_t:
    fail('fs/open.c missing filename_lookup')
if 'ksu_handle_faccessat(&dfd, &fname, &mode, NULL)' not in open_t:
    fail('fs/open.c missing filename** faccessat call')
if 'putname(fname)' not in open_t:
    fail('fs/open.c missing putname')
if 'struct filename *fname' not in open_t:
    fail('fs/open.c missing in-block fname declaration')
if 'ksu_handle_faccessat(&dfd, &filename' in open_t:
    fail('fs/open.c still has 2.2 user-pointer faccessat call')
if 'susfs_is_current_proc_umounted()' in exec_t:
    fail('fs/exec.c still has umounted early-out')
if not re.search(r'ksu_handle_stat\(&dfd, &fname, &flags?\)', stat_t):
    fail('fs/stat.c missing ksu_handle_stat(&dfd, &fname, &flag/flags)')
print('hook rewrite verified', flush=True)
