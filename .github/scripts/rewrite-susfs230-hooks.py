#!/usr/bin/env python3
"""Keep SM6125 4.14 VFS hooks on user_path_at + user-pointer sucompat.

Do NOT apply the GKI / SM8250 SUSFS 2.3 ABI:
  getname_flags + ksu_handle_*(&fname) + filename_lookup(..., root) + putname
  TIF_PROC_NO_SU early-out instead of TIF_PROC_UMOUNTED

OPPO 4.14 faccessat/vfs_fstatat feed AT_* flags into user_path_at(), which
converts them to LOOKUP_*. GKI 2.3 copies assume lookup_flags are already
LOOKUP_* and that filename_lookup takes a 5th root argument. On this tree
that rewrite is what hangs the first splash.
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


GKI_OPEN = re.compile(
    r'#ifdef CONFIG_KSU_SUSFS\s*'
    r'\{[\s\S]*?getname_flags\s*\([\s\S]*?'
    r'filename_lookup\s*\(\s*dfd,\s*fname[\s\S]*?'
    r'putname\s*\(\s*fname\s*\)\s*;\s*'
    r'\}[\s\S]*?'
    r'#else\s*'
    r'res = user_path_at\(dfd, filename, lookup_flags, &path\);\s*'
    r'#endif',
    re.M,
)

GKI_STAT = re.compile(
    r'#ifdef CONFIG_KSU_SUSFS\s*'
    r'\{[\s\S]*?getname_flags\s*\([\s\S]*?'
    r'filename_lookup\s*\(\s*dfd,\s*fname[\s\S]*?'
    r'putname\s*\(\s*fname\s*\)\s*;\s*'
    r'\}[\s\S]*?'
    r'#else\s*'
    r'error = user_path_at\(dfd, filename, lookup_flags, &path\);\s*'
    r'#endif',
    re.M,
)


def restore_user_pointer_proto(text, kind):
    if kind == 'faccessat':
        text = text.replace(
            'extern int ksu_handle_faccessat(int *dfd, struct filename **filename, int *mode,',
            'extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,',
        )
    elif kind == 'stat':
        text = text.replace(
            'extern int ksu_handle_stat(int *dfd, struct filename **filename, int *flags);',
            'extern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);',
        )
        text = text.replace(
            'extern int ksu_handle_stat(int *dfd, struct filename **filename,\n\t\t\t\tint *flags);',
            'extern int ksu_handle_stat(int *dfd, const char __user **filename_user,\n\t\t\t\tint *flags);',
        )
    return text


def restore_umounted(text, label):
    n = text.count('susfs_is_current_proc_no_su()')
    if n:
        text = text.replace('susfs_is_current_proc_no_su()', 'susfs_is_current_proc_umounted()')
        print(label + ': no_su -> umounted x%d' % n, flush=True)
    return text


open_t = read('fs/open.c')
open_t = restore_user_pointer_proto(open_t, 'faccessat')
open_t = restore_umounted(open_t, 'fs/open.c')
new_open, n = GKI_OPEN.subn('res = user_path_at(dfd, filename, lookup_flags, &path);', open_t, count=1)
if n:
    open_t = new_open
    print('fs/open.c: reverted GKI filename_lookup block to user_path_at', flush=True)
elif 'user_path_at(dfd, filename, lookup_flags, &path)' in open_t:
    print('fs/open.c: already 4.14 user_path_at', flush=True)
else:
    fail('fs/open.c: neither GKI block nor user_path_at found')
if 'filename_lookup(dfd, fname' in open_t:
    fail('fs/open.c still has GKI filename_lookup')
write('fs/open.c', open_t)

stat_t = read('fs/stat.c')
stat_t = restore_user_pointer_proto(stat_t, 'stat')
stat_t = restore_umounted(stat_t, 'fs/stat.c')
new_stat, n = GKI_STAT.subn('error = user_path_at(dfd, filename, lookup_flags, &path);', stat_t, count=1)
if n:
    stat_t = new_stat
    print('fs/stat.c: reverted GKI filename_lookup block to user_path_at', flush=True)
elif 'user_path_at(dfd, filename, lookup_flags, &path)' in stat_t:
    print('fs/stat.c: already 4.14 user_path_at', flush=True)
else:
    print('WARN: fs/stat.c has no vfs_fstatat user_path_at; leaving as-is', flush=True)
if 'filename_lookup(dfd, fname' in stat_t:
    fail('fs/stat.c still has GKI filename_lookup')
write('fs/stat.c', stat_t)

exec_t = restore_umounted(read('fs/exec.c'), 'fs/exec.c')
write('fs/exec.c', exec_t)

open_t = read('fs/open.c')
stat_t = read('fs/stat.c')
exec_t = read('fs/exec.c')
if 'user_path_at(dfd, filename, lookup_flags, &path)' not in open_t:
    fail('fs/open.c missing 4.14 user_path_at')
if 'filename_lookup(dfd, fname' in open_t or 'filename_lookup(dfd, fname' in stat_t:
    fail('GKI filename_lookup still present')
if 'susfs_is_current_proc_umounted()' not in exec_t:
    print('WARN: fs/exec.c has no umounted early-out (may be a different hook layout)', flush=True)
print('hook rewrite verified: 4.14 user_path_at ABI', flush=True)
