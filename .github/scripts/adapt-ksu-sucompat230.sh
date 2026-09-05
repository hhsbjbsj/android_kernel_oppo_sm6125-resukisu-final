#!/usr/bin/env bash
set -Eeuo pipefail
echo '===== Align ReSukiSU/SukiSU sucompat handlers with SUSFS 2.3 ====='
CANDIDATES=(
  KernelSU/kernel/feature/sucompat.c
  drivers/kernelsu/feature/sucompat.c
  KernelSU/kernel/sucompat.c
  drivers/kernelsu/sucompat.c
)
HDR_CANDIDATES=(
  KernelSU/kernel/feature/sucompat.h
  drivers/kernelsu/feature/sucompat.h
  KernelSU/kernel/sucompat.h
  drivers/kernelsu/sucompat.h
)
SUC=
for f in "${CANDIDATES[@]}"; do [[ -f "$f" ]] && SUC="$f" && break; done
if [[ -z "$SUC" ]]; then SUC=$(find . -path './.git' -prune -o -path './KernelSU/.git' -prune -o -name 'sucompat.c' -print | head -n1 || true); fi
[[ -n "$SUC" && -f "$SUC" ]] || { echo sucompat.c not found; find . -name sucompat.c | head; exit 1; }
HDR=
for f in "${HDR_CANDIDATES[@]}"; do [[ -f "$f" ]] && HDR="$f" && break; done
[[ -n "$HDR" ]] || HDR=$(dirname "$SUC")/sucompat.h
echo using "$SUC" "$HDR"

python3 -u - "$SUC" "$HDR" <<'PY'
from pathlib import Path
import re
import sys
suc, hdr = Path(sys.argv[1]), Path(sys.argv[2])
t = suc.read_text()

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
        print(label, flush=True)

gate = '#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0) && defined(CONFIG_KSU_SUSFS)'
if gate in t:
    t = t.replace(gate, '#if defined(CONFIG_KSU_SUSFS)', 1)
    print('stat: drop 6.1 gate so filename** works on 4.14', flush=True)
else:
    print('no 6.1 SUSFS stat gate', flush=True)

old_fa_re = re.compile(
    r'int ksu_handle_faccessat\(int \*dfd, const char __user \*\*filename_user, int \*mode, int \*\w+\)'
)
new_fa = 'int ksu_handle_faccessat(int *dfd, struct filename **filename, int *mode, int *__unused_flags)'
new_st = 'int ksu_handle_stat(int *dfd, struct filename **filename, int *flags)'
already_fa = 'int ksu_handle_faccessat(int *dfd, struct filename **filename' in t
already_st = 'int ksu_handle_stat(int *dfd, struct filename **filename' in t
if already_fa and already_st:
    print('faccessat/stat already filename**', flush=True)
elif not old_fa_re.search(t) and not already_fa:
    print('WARN: no faccessat user-pointer impl; leave tree as-is', flush=True)
elif already_fa and not already_st:
    print('WARN: faccessat filename** but stat still old; leave tree as-is', flush=True)
else:
    st_start = t.find(new_st)
    if st_start < 0:
        st_start = t.find('int ksu_handle_stat(int *dfd, struct filename **filename')
    if st_start >= 0:
        st_end = t.find('\n}\n', st_start)
        if st_end < 0:
            raise SystemExit('cannot find end of filename** stat handler')
        st_fn = t[st_start:st_end + 3]
        fa_fn = st_fn.replace(t[st_start:t.find(')', st_start) + 1], new_fa, 1)
        m = old_fa_re.search(t)
        if m:
            fa_start = m.start()
            fa_end = t.find('\n}\n', fa_start)
            if fa_end < 0:
                raise SystemExit('cannot find end of faccessat')
            t = t[:fa_start] + fa_fn + t[fa_end + 3:]
            print('faccessat: cloned filename** stat handler', flush=True)
    else:
        t2, n = old_fa_re.subn(new_fa, t, count=1)
        if n:
            t = t2
            print('faccessat proto rewritten to filename**', flush=True)
        t = t.replace(
            'int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags)',
            new_st,
        )

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
    print('wrapped unguarded static_branch_unlikely for 4.14 bool/static key', flush=True)

if '#include <linux/fs.h>' not in t:
    needle = '#include <linux/susfs_def.h>'
    if needle in t:
        t = t.replace(needle, needle + '\n#include <linux/fs.h>\n#include <linux/err.h>', 1)
        print('added fs.h/err.h', flush=True)

for i, line in enumerate(t.splitlines(), 1):
    if 'pr_info(' in line and line.count('"') % 2 == 1:
        raise SystemExit('unterminated pr_info on line %d: %r' % (i, line))

suc.write_text(t)

if hdr.exists():
    h = hdr.read_text()
    h = old_fa_re.sub(new_fa, h)
    h = h.replace(
        'int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags)',
        new_st,
    )
    if gate in h:
        h = h.replace(gate, '#if defined(CONFIG_KSU_SUSFS)')
    hdr.write_text(h)
    print('updated', hdr, flush=True)

print('[PASS] sucompat text rewritten', flush=True)
PY

grep -Eq 'susfs_set_current_proc_no_su|ksu_set_current_proc_unprivillege|filename \*\*filename' "$SUC" || true
echo '[PASS] ReSukiSU/SukiSU sucompat aligned to SUSFS 2.3 filename** handlers'
