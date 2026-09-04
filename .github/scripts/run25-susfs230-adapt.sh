#!/usr/bin/env bash
set -Eeuo pipefail

KERNEL_DIR="$GITHUB_WORKSPACE/$KERNEL_REL"
cd "$KERNEL_DIR"
exec > >(tee "$GITHUB_WORKSPACE/run25-susfs230-adapt.log") 2>&1

echo '===== Backport official GKI SUSFS v2.3.0 onto Linux 4.14 i_state + fsnotify_add_mark ====='
test -f include/linux/susfs.h
test -f include/linux/susfs_def.h
test -f fs/susfs.c

GKI_BASE='https://gitlab.com/simonpunk/susfs4ksu/-/raw/gki-android12-5.10/kernel_patches'
mkdir -p "$GITHUB_WORKSPACE/.susfs23-upstream"
curl -fLSs "$GKI_BASE/fs/susfs.c" -o "$GITHUB_WORKSPACE/.susfs23-upstream/susfs.c"
curl -fLSs "$GKI_BASE/include/linux/susfs.h" -o "$GITHUB_WORKSPACE/.susfs23-upstream/susfs.h"
curl -fLSs "$GKI_BASE/include/linux/susfs_def.h" -o "$GITHUB_WORKSPACE/.susfs23-upstream/susfs_def.h"
grep -Fq '#define SUSFS_VERSION "v2.3.0"' "$GITHUB_WORKSPACE/.susfs23-upstream/susfs.h"
grep -Fq '#define TIF_PROC_NO_SU 34' "$GITHUB_WORKSPACE/.susfs23-upstream/susfs_def.h"
grep -Fq 'i_mapping->flags' "$GITHUB_WORKSPACE/.susfs23-upstream/susfs.c"

python3 -u - <<'PY'
from pathlib import Path
import os

ws = Path(os.environ['GITHUB_WORKSPACE'])
up = ws / '.susfs23-upstream'
gki_c = (up / 'susfs.c').read_text()
gki_h = (up / 'susfs.h').read_text()
gki_d = (up / 'susfs_def.h').read_text()
old_c = Path('fs/susfs.c').read_text()
if '#define SUSFS_VERSION "v2.3.0"' not in gki_h:
    raise SystemExit('upstream susfs.h is not v2.3.0')

old_start = old_c.find('static SUSFS_DECL_FSNOTIFY_OPS(susfs_handle_sdcard_inode_event)')
old_end = old_c.find('static int susfs_sdcard_monitor_fn')
if old_start < 0 or old_end < 0:
    raise SystemExit('cannot extract 4.14 fsnotify compatibility block')

c = gki_c.replace('i_mapping->flags', 'i_state')
d = gki_d.replace('inode->i_mapping->flags', 'inode->i_state')
d = d.replace('i_mapping->flags', 'i_state')
d = d.replace(
    "inode->i_mapping->flags => A 'unsigned long' type storing flag 'AS_FLAGS_",
    "inode->i_state => A 'unsigned long' type storing flag 'AS_FLAGS_",
)

if '#include <linux/version.h>' not in d:
    if '#include <linux/bits.h>' in d:
        d = d.replace(
            '#include <linux/bits.h>',
            '#include <linux/bits.h>\n#include <linux/version.h>\n#include <linux/cred.h>',
            1,
        )
    else:
        d = d.replace(
            '#define KSU_SUSFS_DEF_H',
            '#define KSU_SUSFS_DEF_H\n\n#include <linux/version.h>\n#include <linux/cred.h>',
            1,
        )

if 'SUSFS_DECL_FSNOTIFY_OPS' not in d:
    helper = r'''
/* 4.14 / non-GKI fsnotify compatibility */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 2, 0)
typedef const struct qstr *susfs_fname_t;
#define susfs_fname_len(f) ((f)->len)
#define susfs_fname_arg(f) ((f)->name)
#else
typedef const unsigned char *susfs_fname_t;
#define susfs_fname_len(f) (strlen(f))
#define susfs_fname_arg(f) (f)
#endif

#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)
#define SUSFS_DECL_FSNOTIFY_OPS(name)                                            \
int name(struct fsnotify_mark *mark, u32 mask, struct inode *inode,    \
struct inode *dir, const struct qstr *file_name, u32 cookie)
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(4, 18, 0)
#define SUSFS_DECL_FSNOTIFY_OPS(name)                                            \
int name(struct fsnotify_group *group, struct inode *inode, u32 mask,  \
const void *data, int data_type, susfs_fname_t file_name,       \
u32 cookie, struct fsnotify_iter_info *iter_info)
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(4, 12, 0)
#define SUSFS_DECL_FSNOTIFY_OPS(name)                                            \
int name(struct fsnotify_group *group, struct inode *inode,            \
struct fsnotify_mark *inode_mark,                             \
struct fsnotify_mark *vfsmount_mark, u32 mask,                \
const void *data, int data_type, susfs_fname_t file_name,       \
u32 cookie, struct fsnotify_iter_info *iter_info)
#else
#define SUSFS_DECL_FSNOTIFY_OPS(name)                                            \
int name(struct fsnotify_group *group, struct inode *inode,            \
struct fsnotify_mark *inode_mark,                             \
struct fsnotify_mark *vfsmount_mark, u32 mask, void *data,    \
int data_type, susfs_fname_t file_name, u32 cookie)
#endif
'''
    d = d.replace('#endif // #ifndef KSU_SUSFS_DEF_H', helper + '\n#endif // #ifndef KSU_SUSFS_DEF_H')

d = d.replace(
    '''static inline bool susfs_is_current_proc_umounted_app(void) {
	return (likely(test_thread_flag(TIF_PROC_UMOUNTED)) &&
			current_uid().val >= 10000);
}''',
    '''static inline bool susfs_is_current_proc_umounted_app(void) {
	return (likely(test_thread_flag(TIF_PROC_UMOUNTED)) &&
#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 12, 0)
			__kuid_val(current_uid()) >= 10000);
#else
			current_uid().val >= 10000);
#endif
}'''
)

g_start = c.find('static int susfs_handle_sdcard_inode_event')
g_end = c.find('static int susfs_sdcard_monitor_fn')
if g_start < 0 or g_end < 0:
    raise SystemExit('cannot find GKI fsnotify block to replace')
c = c[:g_start] + old_c[old_start:old_end] + c[g_end:]

if 'int susfs_open_redirect_spoof_show_map_vma(' not in c:
    wrap = '''
#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
int susfs_open_redirect_spoof_show_map_vma(struct inode *inode, unsigned long *out_ino, dev_t *out_dev, char *spoofed_name)
{
	char *name = NULL;
	int ret;

	if (!spoofed_name)
		return 0;
	ret = susfs_open_redirect_spoof_show_map_vma_srcu(inode, out_ino, out_dev, &name);
	if (ret && name)
		strscpy(spoofed_name, name, SUSFS_MAX_LEN_PATHNAME);
	return ret;
}
#endif
'''
    needle = 'void susfs_start_sdcard_monitor_fn(void)'
    if needle not in c:
        raise SystemExit('cannot insert 4.14 OPEN_REDIRECT wrapper')
    c = c.replace(needle, wrap + '\n' + needle, 1)

if 'i_mapping->flags' in c or 'i_mapping->flags' in d:
    raise SystemExit('i_mapping->flags still present after rewrite')
if '#include <linux/version.h>' not in d:
    raise SystemExit('susfs_def.h missing linux/version.h')
if 'SUSFS_DECL_FSNOTIFY_OPS' not in d or 'SUSFS_DECL_FSNOTIFY_OPS' not in c:
    raise SystemExit('4.14 fsnotify decl missing')
if 'fsnotify_add_mark' not in c and 'fsnotify_add_inode_mark' not in c:
    raise SystemExit('fsnotify mark API missing')
if 'TIF_PROC_NO_SU' not in d or 'TIF_PROC_UMOUNTED_FOR_ZYGOTE_NEXT' not in d:
    raise SystemExit('2.3 TIF helpers missing')
if 'susfs_open_redirect_spoof_show_map_vma_srcu' not in c:
    raise SystemExit('2.3 OPEN_REDIRECT srcu helper missing')

Path('include/linux/susfs.h').write_text(gki_h)
Path('include/linux/susfs_def.h').write_text(d)
Path('fs/susfs.c').write_text(c)
print('overlaid GKI v2.3.0 susfs.c/h/def.h with 4.14 i_state + fsnotify_add_mark', flush=True)

mmu = Path('fs/proc/task_mmu.c')
if mmu.exists():
    mt = mmu.read_text()
    if 'susfs_open_redirect_spoof_show_map_vma' not in mt:
        print('WARNING: task_mmu.c has no OPEN_REDIRECT hook; left unchanged', flush=True)
    else:
        print('kept existing 4.14 task_mmu OPEN_REDIRECT hook via compatibility wrapper', flush=True)
PY

grep -Fq '#define SUSFS_VERSION "v2.3.0"' include/linux/susfs.h
grep -Fq '#include <linux/version.h>' include/linux/susfs_def.h
grep -Fq '#define TIF_PROC_NO_SU 34' include/linux/susfs_def.h
grep -Fq 'susfs_is_current_proc_no_su' include/linux/susfs_def.h
grep -Fq 'susfs_is_current_proc_umounted_for_zygote_next' include/linux/susfs_def.h
grep -Fq 'SUSFS_DECL_FSNOTIFY_OPS' include/linux/susfs_def.h
grep -Fq 'SUSFS_DECL_FSNOTIFY_OPS' fs/susfs.c
grep -Eq 'fsnotify_add_mark|fsnotify_add_inode_mark' fs/susfs.c
grep -Fq 'susfs_open_redirect_spoof_show_map_vma_srcu' fs/susfs.c
! grep -Fq 'i_mapping->flags' include/linux/susfs_def.h
! grep -Fq 'i_mapping->flags' fs/susfs.c
grep -Fq '&inode->i_state' fs/susfs.c

{
  echo "run26_base=$GITHUB_SHA"
  echo 'susfs_from=v2.2.0'
  echo 'susfs_to=v2.3.0'
  echo 'official_4.14_2.3_patch=absent'
  echo 'gki_2.3_raw_apply=rewritten_to_i_state'
  echo 'flag_storage=inode_i_state'
  echo 'fsnotify_api=4.14_add_mark'
  echo 'tif_proc_no_su=added'
  echo 'tif_proc_umounted_for_zygote_next=added'
  echo 'open_redirect=2.3 srcu helpers + 4.14 wrapper'
  echo 'kernel_source_tree=untouched_in_git'
} | tee "$GITHUB_WORKSPACE/run25-susfs230-proof.txt"

echo '[PASS] official GKI SUSFS 2.3.0 backported onto 4.14 i_state + fsnotify_add_mark'
