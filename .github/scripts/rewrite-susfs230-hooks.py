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
    elif re.search(r'^int filename_lookup\\(int dfd, struct filename \\*name, unsigned flags,', t, re.M):
        print('filename_lookup already non-static', flush=True)
    else:
        fail('cannot find filename_lookup in fs/namei.c')
    decl = (
        'extern int filename_lookup(int dfd, struct filename *name, unsigned flags,\\n'
        '\\t\\t\\tstruct path *path, struct path *root);\\n'
    )
    for rel in ('fs/open.c', 'fs/stat.c'):
        text = read(rel)
        if 'extern int filename_lookup(' in text:
            continue
        if '#include <linux/susfs_def.h>' in text:
            text = text.replace(
                '#include <linux/susfs_def.h>',
                '#include <linux/susfs_def.h>\\n' + decl,
                1,
            )
        elif '#ifdef CONFIG_KSU_SUSFS' in text:
            text = text.replace(
                '#ifdef CONFIG_KSU_SUSFS',
                '#ifdef CONFIG_KSU_SUSFS\\n' + decl,
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

old_early = re.compile(
    r'#ifdef CONFIG_KSU_SUSFS\\s*'
    r'if \\\(likely\\(susfs_is_current_proc_no_su\\(\\)\\)\\)\\s*'
    r'goto orig_flow;\\s*'
    r'if \\\(static_branch_likely\\(&ksu_su_compat_enabled\\)\\)\\s*'
    r'if \\\(unlikely\\(__ksu_is_allow_uid_for_current\\(current_uid\\(\\)\\.val\\)\\)\\) \\\{\\s*'
    r'ksu_handle_faccessat\\(&dfd, &filename, &mode, NULL\\);\\s*'
    r'\\}\\s*'
    r'orig_flow:\\s*'
    r'#endif\\s*',
    re.M,
)
