#!/usr/bin/env bash
set -Eeuo pipefail

KERNEL_DIR="$GITHUB_WORKSPACE/$KERNEL_REL"
cd "$KERNEL_DIR"
exec > >(tee "$GITHUB_WORKSPACE/run25-susfs230-adapt.log") 2>&1

echo '===== Keep in-tree 4.14 susfs.c; lift only 2.3 TIF helpers + VFS hook ABI ====='
echo 'GKI 5.10 susfs.c overlay on 4.14 is what hangs first splash (same as SM8250).'
test -f include/linux/susfs.h
test -f include/linux/susfs_def.h
test -f fs/susfs.c
test -f fs/exec.c
test -f fs/open.c
test -f fs/stat.c

GKI_BASE='https://gitlab.com/simonpunk/susfs4ksu/-/raw/gki-android12-5.10/kernel_patches'
mkdir -p "$GITHUB_WORKSPACE/.susfs23-upstream"
curl -fLSs "$GKI_BASE/include/linux/susfs_def.h" -o "$GITHUB_WORKSPACE/.susfs23-upstream/susfs_def.h"
curl -fLSs "$GKI_BASE/include/linux/susfs.h" -o "$GITHUB_WORKSPACE/.susfs23-upstream/susfs.h"
grep -Fq '#define TIF_PROC_NO_SU 34' "$GITHUB_WORKSPACE/.susfs23-upstream/susfs_def.h"
grep -Fq '#define SUSFS_VERSION "v2.3.0"' "$GITHUB_WORKSPACE/.susfs23-upstream/susfs.h"

python3 -u - <<'PY'
from pathlib import Path
import os

d = Path('include/linux/susfs_def.h').read_text()
h = Path('include/linux/susfs.h').read_text()

if 'TIF_PROC_NO_SU' not in d:
    insert = (
        '#define TIF_PROC_UMOUNTED 33\n'
        '#define TIF_PROC_NO_SU 34\n'
        '#define TIF_PROC_UMOUNTED_FOR_ZYGOTE_NEXT 35\n'
    )
    lines = []
    skipped = False
    for line in d.splitlines(True):
        if (not skipped) and line.startswith('#define TIF_PROC_UMOUNTED') and 'ZYGOTE' not in line:
            lines.append(insert)
            skipped = True
            continue
        lines.append(line)
    d = ''.join(lines)
    if not skipped:
        d = d.replace('#define KSU_SUSFS_DEF_H', '#define KSU_SUSFS_DEF_H\n' + insert, 1)

def ensure_helper(text, name, body):
    if name in text:
        return text
    guard = '#endif // #ifndef KSU_SUSFS_DEF_H'
    if guard in text:
        return text.replace(guard, body + '\n' + guard, 1)
    return text + '\n' + body + '\n'

d = ensure_helper(d, 'susfs_is_current_proc_no_su', '''
static inline bool susfs_is_current_proc_no_su(void) {
	return (likely(test_thread_flag(TIF_PROC_NO_SU)));
}
static inline void susfs_set_current_proc_no_su(void) {
	set_thread_flag(TIF_PROC_NO_SU);
}
static inline void susfs_clear_current_proc_no_su(void) {
	clear_thread_flag(TIF_PROC_NO_SU);
}
''')

d = ensure_helper(d, 'susfs_is_current_proc_umounted_for_zygote_next', '''
static inline bool susfs_is_current_proc_umounted_for_zygote_next(void) {
	return (likely(test_thread_flag(TIF_PROC_UMOUNTED_FOR_ZYGOTE_NEXT)));
}
static inline void susfs_set_current_proc_umounted_for_zygote_next(void) {
	set_thread_flag(TIF_PROC_UMOUNTED_FOR_ZYGOTE_NEXT);
}
static inline void susfs_clear_current_proc_umounted_for_zygote_next(void) {
	clear_thread_flag(TIF_PROC_UMOUNTED_FOR_ZYGOTE_NEXT);
}
''')

h = h.replace('#define SUSFS_VERSION "v2.2.0"', '#define SUSFS_VERSION "v2.3.0"')
if 'SUSFS_VERSION "v2.3.0"' not in h:
    raise SystemExit('failed to bump susfs.h to v2.3.0')

if '#include <linux/version.h>' not in d:
    if '#include <linux/bits.h>' in d:
        d = d.replace('#include <linux/bits.h>', '#include <linux/bits.h>\n#include <linux/version.h>\n#include <linux/cred.h>', 1)
    else:
        d = d.replace('#define KSU_SUSFS_DEF_H', '#define KSU_SUSFS_DEF_H\n\n#include <linux/version.h>\n#include <linux/cred.h>', 1)

Path('include/linux/susfs_def.h').write_text(d)
Path('include/linux/susfs.h').write_text(h)
print('lifted TIF_PROC_NO_SU helpers; kept in-tree fs/susfs.c', flush=True)
PY

echo '===== Rewrite 4.14 2.2 inline hooks to official SUSFS 2.3 ====='
git fetch --no-tags --depth=1 origin "$GITHUB_SHA" >/dev/null 2>&1 || true
git show "$GITHUB_SHA:.github/scripts/rewrite-susfs230-hooks.py" > "$GITHUB_WORKSPACE/rewrite-susfs230-hooks.py"
python3 -u "$GITHUB_WORKSPACE/rewrite-susfs230-hooks.py"
grep -Fq 'susfs_is_current_proc_no_su()' fs/exec.c
grep -Fq 'filename_lookup(dfd, fname, lookup_flags, &path, NULL)' fs/open.c
grep -Fq 'ksu_handle_faccessat(&dfd, &fname, &mode, NULL)' fs/open.c
grep -Eq 'ksu_handle_stat\\(&dfd, &fname, &flags?\\)' fs/stat.c || grep -Fq 'filename_lookup(dfd, fname, lookup_flags, &path, NULL)' fs/stat.c
! grep -Fq 'ksu_handle_faccessat(&dfd, &filename' fs/open.c
! grep -Fq 'susfs_is_current_proc_umounted()' fs/exec.c
! grep -Fq 'susfs_is_current_proc_umounted()' fs/open.c
grep -Fq '#define SUSFS_VERSION "v2.3.0"' include/linux/susfs.h
grep -Fq '#define TIF_PROC_NO_SU 34' include/linux/susfs_def.h
grep -Fq '#define TIF_PROC_UMOUNTED_FOR_ZYGOTE_NEXT 35' include/linux/susfs_def.h

if [[ -e KernelSU/kernel/feature/sucompat.c || -e drivers/kernelsu/feature/sucompat.c || -e KernelSU/kernel/sucompat.c ]]; then
  echo '===== Align current KSU sucompat to filename** / no_su ====='
  git show "$GITHUB_SHA:.github/scripts/adapt-ksu-sucompat230.sh" > "$GITHUB_WORKSPACE/adapt-ksu-sucompat230.sh"
  chmod +x "$GITHUB_WORKSPACE/adapt-ksu-sucompat230.sh"
  "$GITHUB_WORKSPACE/adapt-ksu-sucompat230.sh"
fi

{
  echo "run26_base=$GITHUB_SHA"
  echo 'susfs_from=v2.2.0'
  echo 'susfs_to=v2.3.0'
  echo 'official_4.14_2.3_patch=absent'
  echo 'gki_2.3_raw_apply=skipped_keep_intree_susfs_c'
  echo 'susfs_overlay=skipped'
  echo 'flag_storage=inode_i_state'
  echo 'fsnotify_api=4.14_intree'
  echo 'tif_proc_no_su=added'
  echo 'tif_proc_umounted_for_zygote_next=added'
  echo 'open_redirect=keep_intree'
  echo 'hooks=exec.c no_su; open.c getname_flags+filename_lookup+filename**; stat.c getname_flags+filename**'
  echo 'filename_lookup=unstatic_5arg'
  echo 'kernel_source_tree=untouched_in_git'
  echo 'first_splash_fix=no_gki_susfs_c_overlay + ak3_boot_only'
} | tee "$GITHUB_WORKSPACE/run25-susfs230-proof.txt"

echo '[PASS] SUSFS 2.3 hook ABI without replacing 4.14 fs/susfs.c'
