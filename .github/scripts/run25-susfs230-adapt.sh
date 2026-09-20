#!/usr/bin/env bash
set -Eeuo pipefail

KERNEL_DIR="$GITHUB_WORKSPACE/$KERNEL_REL"
cd "$KERNEL_DIR"
exec > >(tee "$GITHUB_WORKSPACE/run25-susfs230-adapt.log") 2>&1

echo '===== SM6125 4.14 SUSFS: keep in-tree susfs.c and 4.14 VFS ABI ====='
echo 'Do not apply GKI/SM8250 getname_flags+filename_lookup. That hangs first splash.'
echo 'DO add header-only TIF_PROC_NO_SU helpers so latest ReSukiSU/SukiSU can link.'
test -f include/linux/susfs.h
test -f include/linux/susfs_def.h
test -f fs/susfs.c
test -f fs/exec.c
test -f fs/open.c
test -f fs/stat.c

python3 -u - <<'PY'
from pathlib import Path

h = Path('include/linux/susfs.h').read_text()
h = h.replace('#define SUSFS_VERSION "v2.2.0"', '#define SUSFS_VERSION "v2.3.0"')
if 'SUSFS_VERSION "v2.3.0"' not in h:
    raise SystemExit('failed to bump susfs.h to v2.3.0')
if "#define KSTAT_SPOOF_CTIME_TV_SEC (1 < 8)" in h:
    h = h.replace("#define KSTAT_SPOOF_CTIME_TV_SEC (1 < 8)", "#define KSTAT_SPOOF_CTIME_TV_SEC (1 << 8)")
    print("fixed KSTAT_SPOOF_CTIME_TV_SEC bitmask typo (1 < 8) -> (1 << 8)", flush=True)
Path('include/linux/susfs.h').write_text(h)

d = Path('include/linux/susfs_def.h').read_text()

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
    guard2 = '#endif /* KSU_SUSFS_DEF_H */'
    if guard2 in text:
        return text.replace(guard2, body + '\n' + guard2, 1)
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

if '#include <linux/version.h>' not in d:
    if '#include <linux/bits.h>' in d:
        d = d.replace('#include <linux/bits.h>', '#include <linux/bits.h>\n#include <linux/version.h>\n#include <linux/cred.h>', 1)
    else:
        d = d.replace('#define KSU_SUSFS_DEF_H', '#define KSU_SUSFS_DEF_H\n\n#include <linux/version.h>\n#include <linux/cred.h>', 1)

d = ensure_helper(d, "susfs_clear_current_proc_umounted", "\nstatic inline void susfs_clear_current_proc_umounted(void) {\n\tclear_thread_flag(TIF_PROC_UMOUNTED);\n}\n")
d = ensure_helper(d, "susfs_is_current_app_uid", "\nstatic inline bool susfs_is_current_app_uid(void) {\n\treturn ((current_uid().val % 100000) >= 10000);\n}\n")
if "#define DEFAULT_KSU_MNT_MINOR_DEV" not in d:
    d = d.replace("#define DEFAULT_KSU_MNT_GROUP_ID 200000 /* used by mount->mnt_group_id */", "#define DEFAULT_KSU_MNT_GROUP_ID 200000 /* used by mount->mnt_group_id */\n#define DEFAULT_KSU_MNT_MINOR_DEV (1 << 12)")
if "#define STATX_SUS_KSTAT" not in d:
    d = ensure_helper(d, "STATX_SUS_KSTAT", "\n#define STATX_SUS_KSTAT 0x10000000U\n#define STATX_SUS_KSTAT_FUSE 0x20000000U\n")
Path('include/linux/susfs_def.h').write_text(d)
print('lifted TIF_PROC_NO_SU helpers; VFS ABI stays 4.14 user_path_at', flush=True)
# 3. Adapt fs/susfs.c with canonical upstream 2.3.0 bugfixes
c = Path("fs/susfs.c").read_text()
old_features = """	if (!info) {
		info->err = -ENOMEM;
		goto out_copy_to_user;
	}"""
new_features = """	if (!info) {
		int err = -ENOMEM;
		if (copy_to_user(&((struct st_susfs_enabled_features __user*)*user_info)->err, &err, sizeof(err)))
			err = -EFAULT;
		SUSFS_LOGI("CMD_SUSFS_SHOW_ENABLED_FEATURES -> ret: %d\\n", err);
		return;
	}"""
if old_features in c:
    c = c.replace(old_features, new_features, 1)
    print("fixed NULL deref in susfs_get_enabled_features", flush=True)
old_cmdline = """void susfs_spoof_cmdline_or_bootconfig(struct seq_file *m) {
	unsigned seq;

	do {
		seq = read_seqbegin(&susfs_fake_cmdline_or_bootconfig_seqlock);
		seq_puts(m, fake_cmdline_or_bootconfig);
	} while (read_seqretry(&susfs_fake_cmdline_or_bootconfig_seqlock, seq));
}"""
new_cmdline = """void susfs_spoof_cmdline_or_bootconfig(struct seq_file *m) {
	unsigned seq;
	char *buf = (char *)kmalloc(SUSFS_FAKE_CMDLINE_OR_BOOTCONFIG_SIZE, GFP_KERNEL);
	if (!buf) return;
	do {
		seq = read_seqbegin(&susfs_fake_cmdline_or_bootconfig_seqlock);
		strscpy(buf, fake_cmdline_or_bootconfig, SUSFS_FAKE_CMDLINE_OR_BOOTCONFIG_SIZE);
	} while (read_seqretry(&susfs_fake_cmdline_or_bootconfig_seqlock, seq));
	seq_puts(m, buf);
	kfree(buf);
}"""
if old_cmdline in c:
    c = c.replace(old_cmdline, new_cmdline, 1)
    print("fixed duplicate /proc/cmdline output in susfs_spoof_cmdline_or_bootconfig", flush=True)
old_kstat = """	mutex_unlock(&susfs_mutex_lock_sus_kstat);
	info.err = -ENOENT;"""
new_kstat = """	mutex_unlock(&susfs_mutex_lock_sus_kstat);
	kfree(new_entry);
	info.err = -ENOENT;"""
if old_kstat in c:
    c = c.replace(old_kstat, new_kstat, 1)
    print("fixed memory leak in susfs_update_sus_kstat", flush=True)
if "#include <linux/security.h>" not in c:
    c = c.replace("#include <linux/susfs.h>", "#include <linux/security.h>\n#include <linux/susfs.h>", 1)
Path("fs/susfs.c").write_text(c)
print("applied upstream SUSFS 2.3.0 bugfixes to fs/susfs.c", flush=True)
PY

echo '===== Revert any GKI/SM8250 VFS rewrite back to 4.14 user_path_at ====='
git fetch --no-tags --depth=1 origin "$GITHUB_SHA" >/dev/null 2>&1 || true
git show "$GITHUB_SHA:.github/scripts/rewrite-susfs230-hooks.py" > "$GITHUB_WORKSPACE/rewrite-susfs230-hooks.py"
python3 -u "$GITHUB_WORKSPACE/rewrite-susfs230-hooks.py"
grep -Fq 'user_path_at(dfd, filename, lookup_flags, &path)' fs/open.c
! grep -Fq 'filename_lookup(dfd, fname' fs/open.c
! grep -Fq 'filename_lookup(dfd, fname' fs/stat.c
grep -Fq '#define SUSFS_VERSION "v2.3.0"' include/linux/susfs.h
grep -Fq '#define TIF_PROC_NO_SU 34' include/linux/susfs_def.h
grep -Fq 'susfs_is_current_proc_no_su' include/linux/susfs_def.h
grep -Fq 'susfs_set_current_proc_umounted_for_zygote_next' include/linux/susfs_def.h

if [[ -e KernelSU/kernel/feature/sucompat.c || -e drivers/kernelsu/feature/sucompat.c || -e KernelSU/kernel/sucompat.c ]]; then
  echo '===== Keep current KSU sucompat on 4.14 user-pointer handlers ====='
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
  echo 'tif_proc_no_su=header_helpers_only'
  echo 'tif_proc_umounted_for_zygote_next=header_helpers_only'
  echo 'open_redirect=keep_intree'
  echo 'hooks=4.14_user_path_at+filename_user'
  echo 'filename_lookup=untouched'
  echo 'kernel_source_tree=untouched_in_git'
  echo 'first_splash_fix=no_gki_vfs_abi + no_gki_susfs_c + ak3_boot_only'
} | tee "$GITHUB_WORKSPACE/run25-susfs230-proof.txt"

echo '[PASS] SUSFS 2.3.0 headers + 4.14 user_path_at hooks'
