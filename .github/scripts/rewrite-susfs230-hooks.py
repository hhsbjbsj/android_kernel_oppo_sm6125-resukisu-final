#!/usr/bin/env python3
"""Rewrite SM6125 4.14 manual hooks to official SUSFS 2.3 logic.

Runs AFTER apply-resukisu-hooks.py. Mirrors simonpunk da34bba1 / f3087ec1
and JackA1ltman NonGKI susfs_inline_hook_patches.sh.

4.14 filename_lookup is static and already 5-arg:
  filename_lookup(dfd, name, flags, path, root)
"""
from pathlib import Path


def must_replace(text, old, new, label):
    if old not in text:
        raise SystemExit(f'{label}: expected block not found')
    return text.replace(old, new, 1)


def ensure_include(text, needle, include_line):
    if include_line in text:
        return text
    if needle in text:
        return text.replace(needle, needle + '\n' + include_line, 1)
    return include_line + '\n' + text


def unstatic_filename_lookup():
    p = Path('fs/namei.c')
    t = p.read_text()
    old = ('static int filename_lookup(int dfd, struct filename *name, unsigned flags,\n'
           '\t\t\t   struct path *path, struct path *root)')
    new = ('int filename_lookup(int dfd, struct filename *name, unsigned flags,\n'
           '\t\t\t   struct path *path, struct path *root)')
    if old in t:
        t = t.replace(old, new, 1)
        p.write_text(t)
        print('unstatic filename_lookup in fs/namei.c', flush=True)
    elif 'int filename_lookup(int dfd, struct filename *name, unsigned flags,' in t:
        print('filename_lookup already non-static', flush=True)
    else:
        raise SystemExit('cannot find 4.14 filename_lookup prototype in fs/namei.c')

    decl = ('extern int filename_lookup(int dfd, struct filename *name, unsigned flags,\n'
            '\t\t\t    struct path *path, struct path *root);\n')
    for rel in ('fs/open.c', 'fs/stat.c'):
        q = Path(rel)
        s = q.read_text()
        if 'extern int filename_lookup(' in s:
            continue
        if '#include "internal.h"' in s:
            s = s.replace('#include "internal.h"', '#include "internal.h"\n' + decl, 1)
        else:
            s = decl + s
        q.write_text(s)
        print('declared filename_lookup in', rel, flush=True)


# ---- fs/namei.c : make filename_lookup usable from open/stat ----
unstatic_filename_lookup()


# ---- fs/exec.c : TIF_PROC_NO_SU early-out around execve hooks ----
p = Path('fs/exec.c')
t = p.read_text()
t = ensure_include(t, '#include <linux/fs.h>', '#include <linux/susfs.h>')

old = """#ifdef CONFIG_KSU_MANUAL_HOOK
\tksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0);
#endif
\treturn do_execveat_common(AT_FDCWD, filename, argv, envp, 0);
"""
new = """#ifdef CONFIG_KSU_MANUAL_HOOK
#ifdef CONFIG_KSU_SUSFS
\tif (likely(susfs_is_current_proc_no_su()))
\t\tgoto orig_execve;
#endif
\tksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0);
orig_execve:
#endif
\treturn do_execveat_common(AT_FDCWD, filename, argv, envp, 0);
"""
count = t.count(old)
if count < 1:
    if 'susfs_is_current_proc_no_su()' in t:
        print('fs/exec.c already has no_su early-out', flush=True)
    else:
        raise SystemExit('fs/exec.c: expected manual execve hook not found')
else:
    t = t.replace(old, new)
    p.write_text(t)
    print(f'rewrote fs/exec.c sucompat early-out on {count} sites', flush=True)


# ---- fs/open.c : getname_flags + filename_lookup + filename** ----
p = Path('fs/open.c')
t = p.read_text()
t = ensure_include(t, '#include <linux/fs.h>', '#include <linux/susfs.h>')

old = """extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user,
\t\t\t\tint *mode, int *flags);
"""
new = """extern int ksu_handle_faccessat(int *dfd, struct filename **filename,
\t\t\t\tint *mode, int *flags);
"""
if old in t:
    t = t.replace(old, new, 1)
elif 'extern int ksu_handle_faccessat(int *dfd, struct filename **filename' in t:
    print('fs/open.c proto already filename**', flush=True)
else:
    raise SystemExit('fs/open.c: faccessat prototype not found')

old = """\tint res;\n\tunsigned int lookup_flags = LOOKUP_FOLLOW;\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n#endif\n"""
new = """\tint res;\n\tunsigned int lookup_flags = LOOKUP_FOLLOW;\n#ifdef CONFIG_KSU_SUSFS\n\tstruct filename *fname = NULL;\n#endif\n"""
if old in t:
    t = t.replace(old, new, 1)
elif 'struct filename *fname = NULL;' in t and 'do_faccessat' in t:
    print('fs/open.c already dropped user-pointer faccessat hook', flush=True)
else:
    raise SystemExit('fs/open.c: expected manual faccessat hook not found')

old = """retry:\n\tres = user_path_at(dfd, filename, lookup_flags, &path);\n\tif (res)\n\t\tgoto out;\n"""
new = """retry:\n#ifdef CONFIG_KSU_SUSFS\n\tfname = getname_flags(filename, lookup_flags, NULL);\n\tif (IS_ERR(fname)) {\n\t\tres = PTR_ERR(fname);\n\t\tfname = NULL;\n\t\tgoto out;\n\t}\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tif (likely(susfs_is_current_proc_no_su()))\n\t\tgoto orig_faccessat;\n\tksu_handle_faccessat(&dfd, &fname, &mode, NULL);\norig_faccessat:\n#endif\n\tres = filename_lookup(dfd, fname, lookup_flags, &path, NULL);\n\tputname(fname);\n\tfname = NULL;\n#else\n\tres = user_path_at(dfd, filename, lookup_flags, &path);\n#endif\n\tif (res)\n\t\tgoto out;\n"""
if old in t:
    t = t.replace(old, new, 1)
elif 'filename_lookup(dfd, fname, lookup_flags, &path, NULL)' in t:
    print('fs/open.c already uses filename_lookup', flush=True)
else:
    raise SystemExit('fs/open.c: user_path_at retry block not found')

p.write_text(t)
print('rewrote fs/open.c do_faccessat to getname_flags + filename_lookup', flush=True)


# ---- fs/stat.c : same split on newfstatat / fstatat64 ----
p = Path('fs/stat.c')
t = p.read_text()
t = ensure_include(t, '#include <linux/syscalls.h>', '#include <linux/susfs.h>')

old = """extern int ksu_handle_stat(int *dfd, const char __user **filename_user,
\t\t\t\tint *flags);\n"""
new = """extern int ksu_handle_stat(int *dfd, struct filename **filename,
\t\t\t\tint *flags);\n"""
if old in t:
    t = t.replace(old, new, 1)
elif 'extern int ksu_handle_stat(int *dfd, struct filename **filename' in t:
    print('fs/stat.c proto already filename**', flush=True)
else:
    raise SystemExit('fs/stat.c: stat prototype not found')

# newfstatat and fstatat64 both call vfs_fstatat(dfd, filename, ...)
old = """#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_stat(&dfd, &filename, &flag);\n#endif\n\terror = vfs_fstatat(dfd, filename, &stat, flag);\n"""
new = """#ifdef CONFIG_KSU_SUSFS\n\t{\n\t\tstruct filename *fname;\n\t\tunsigned int lookup_flags = LOOKUP_FOLLOW | LOOKUP_AUTOMOUNT;\n\n\t\tif (flag & AT_SYMLINK_NOFOLLOW)\n\t\t\tlookup_flags &= ~LOOKUP_FOLLOW;\n\t\tfname = getname_flags(filename, lookup_flags, NULL);\n\t\tif (IS_ERR(fname))\n\t\t\treturn PTR_ERR(fname);\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\t\tif (!susfs_is_current_proc_no_su())\n\t\t\tksu_handle_stat(&dfd, &fname, &flag);\n#endif\n\t\tputname(fname);\n\t}\n#endif\n\terror = vfs_fstatat(dfd, filename, &stat, flag);\n"""
count = t.count(old)
if count < 1:
    if 'ksu_handle_stat(&dfd, &fname, &flag)' in t:
        print('fs/stat.c already uses filename** handler', flush=True)
    else:
        raise SystemExit('fs/stat.c: expected manual stat hook not found')
else:
    t = t.replace(old, new)
    print(f'rewrote fs/stat.c vfs_fstatat sites ({count}) to getname_flags + filename**', flush=True)

p.write_text(t)

# sanity
for f, needles, forbidden in (
    ('fs/exec.c', ['susfs_is_current_proc_no_su()'], []),
    ('fs/open.c', ['getname_flags(filename, lookup_flags, NULL)',
                   'filename_lookup(dfd, fname, lookup_flags, &path, NULL)',
                   'ksu_handle_faccessat(&dfd, &fname, &mode, NULL)',
                   'susfs_is_current_proc_no_su()'],
     ['ksu_handle_faccessat(&dfd, &filename']),
    ('fs/stat.c', ['getname_flags(filename, lookup_flags, NULL)',
                   'ksu_handle_stat(&dfd, &fname, &flag)',
                   'susfs_is_current_proc_no_su()'],
     ['ksu_handle_stat(&dfd, &filename']),
    ('fs/namei.c', ['int filename_lookup(int dfd, struct filename *name, unsigned flags,'],
     ['static int filename_lookup(int dfd, struct filename *name, unsigned flags,']),
):
    text = Path(f).read_text()
    for n in needles:
        if n not in text:
            raise SystemExit(f'{f} missing {n!r}')
    for n in forbidden:
        if n in text:
            raise SystemExit(f'{f} still has 2.2 call {n!r}')

print('hook rewrite verified', flush=True)
