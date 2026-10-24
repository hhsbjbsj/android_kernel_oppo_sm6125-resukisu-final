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
if "int                                     is_statically;" in h:
    h = h.replace(
        "int                                     is_statically;",
        "bool                                    is_statically;",
        1,
    )
    print("updated st_susfs_sus_kstat.is_statically to bool (a0f9c59e)", flush=True)
if "struct st_susfs_priority_uid_filter" not in h:
    anchor = "/* avc log spoofing */"
    block = (
        "/* getpriority uid filter */\n"
        "struct st_susfs_priority_uid_filter {\n"
        "\tchar                                    app_strings[SUSFS_APP_STR_BUF_SIZE];\n"
        "\tint                                     err;\n"
        "};\n\n"
    )
    if anchor not in h:
        raise SystemExit("cannot find avc log spoofing anchor in susfs.h")
    h = h.replace(anchor, block + anchor, 1)
    print("added struct st_susfs_priority_uid_filter to susfs.h (c05208ea)", flush=True)
if "susfs_set_priority_uid_filter" not in h:
    anchor = "void susfs_set_avc_log_spoofing(void __user **user_info);"
    block = (
        "/* getpriority uid filter */\n"
        "void susfs_set_priority_uid_filter(void __user **user_info);\n"
        "void susfs_parse_priority_app_strings(void);\n\n"
    )
    if anchor not in h:
        raise SystemExit("cannot find susfs_set_avc_log_spoofing anchor in susfs.h")
    h = h.replace(anchor, block + anchor, 1)
    print("added priority uid filter declarations to susfs.h (c05208ea)", flush=True)
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
if "#include <linux/bitmap.h>" not in d:
    if "#include <linux/bits.h>" in d:
        d = d.replace("#include <linux/bits.h>", "#include <linux/bits.h>\n#include <linux/bitmap.h>", 1)
    else:
        d = d.replace("#define KSU_SUSFS_DEF_H", "#define KSU_SUSFS_DEF_H\n#include <linux/bitmap.h>", 1)
if "#define CMD_SUSFS_SET_PRIORITY_UID_FILTER" not in d:
    d = d.replace(
        "#define CMD_SUSFS_ADD_SUS_MAP 0x60020",
        "#define CMD_SUSFS_ADD_SUS_MAP 0x60020\n#define CMD_SUSFS_SET_PRIORITY_UID_FILTER 0x60030",
        1,
    )
if "#define SUSFS_PRIORITY_UID_FILTER_MIN_UID" not in d:
    d = ensure_helper(
        d,
        "SUSFS_PRIORITY_UID_FILTER_MIN_UID",
        "\n/*****************************************/\n"
        "/* getpriority uid filter (bitmap)       */\n"
        "/*****************************************/\n"
        "#define SUSFS_PRIORITY_UID_FILTER_MIN_UID 10000\n"
        "#define SUSFS_PRIORITY_UID_FILTER_MAX_UID 19999\n"
        "#define SUSFS_PRIORITY_UID_FILTER_UID_NUM (SUSFS_PRIORITY_UID_FILTER_MAX_UID - SUSFS_PRIORITY_UID_FILTER_MIN_UID + 1)\n"
        "#define SUSFS_PRIORITY_UID_FILTER_BITMAP_LEN BITS_TO_LONGS(SUSFS_PRIORITY_UID_FILTER_UID_NUM)\n"
        "#define SUSFS_APP_STR_BUF_SIZE 65535\n",
    )
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
for inc in [
    "#include <linux/security.h>",
    "#include <linux/bitmap.h>",
    "#include <linux/limits.h>",
    "#include <linux/rcupdate.h>",
    "#include <linux/string.h>",
]:
    if inc not in c:
        c = c.replace("#include <linux/susfs.h>", inc + "\n#include <linux/susfs.h>", 1)

if "susfs_switch_to_ksu_domain(" not in c:
    ksu_domain_helpers = """/*
 * Switches the selinux domain of the current process to the KernelSU one, so
 * that the data paths of the apps can be accessed despite of the selinux
 * restrictions.
 * The original credentials are returned, they have to be restored with
 * susfs_restore_creds() afterwards.
 * Returns the original credentials on success, NULL on failure.
 */
static struct cred *susfs_switch_to_ksu_domain(void) {
	struct cred *orig_cred = NULL;
	struct cred *cred = NULL;

	/* a copy of the current credentials, which is restored later on */
	orig_cred = prepare_creds();
	if (!orig_cred) {
		SUSFS_LOGE("failed to prepare creds!\\n");
		return NULL;
	}

	cred = prepare_creds();
	if (!cred) {
		SUSFS_LOGE("failed to prepare creds!\\n");
		abort_creds(orig_cred);
		return NULL;
	}

	setup_selinux("u:r:ksu:s0", cred);
	commit_creds(cred);

	if (!susfs_is_current_ksu_domain()) {
		SUSFS_LOGE("domain is not ksu, restoring the original creds\\n");
		commit_creds(orig_cred);
		return NULL;
	}

	return orig_cred;
}

/*
 * Restores the original credentials that were saved by
 * susfs_switch_to_ksu_domain().
 */
static void susfs_restore_creds(struct cred *orig_cred) {
	if (!orig_cred)
		return;

	commit_creds(orig_cred);
}

"""
    anchor = "/* sus_path */"
    if anchor not in c:
        raise SystemExit("cannot find /* sus_path */ anchor in fs/susfs.c")
    c = c.replace(anchor, ksu_domain_helpers + anchor, 1)
    print("added susfs_switch_to_ksu_domain / susfs_restore_creds to fs/susfs.c", flush=True)

if "susfs_set_priority_uid_filter(" not in c:
    prio_impl = """/* priority uid filter */
struct susfs_priority_uid_filter_bitmap {
	struct rcu_head			rcu;
	unsigned long			bits[SUSFS_PRIORITY_UID_FILTER_BITMAP_LEN];
};

static struct susfs_priority_uid_filter_bitmap __rcu *priority_uid_filter_bitmap;
static DEFINE_MUTEX(susfs_mutex_lock_priority_uid_filter);
static char *susfs_priority_app_strings = NULL;
static atomic_t susfs_priority_app_strings_running = ATOMIC_INIT(0);

static bool susfs_is_valid_app_name(const char *app_name) {
	const char *p = app_name;
	size_t len = strlen(app_name);

	if (len == 0 || len > 255)
		return false;

	if (!strcmp(app_name, ".") || !strcmp(app_name, ".."))
		return false;

	for (; *p != '\\0'; p++) {
		if ((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') ||
			(*p >= '0' && *p <= '9') || *p == '.' || *p == '_')
			continue;
		return false;
	}

	return true;
}

static int susfs_resolve_priority_app_uid(const char *app_name, uid_t *uid) {
	char app_path[512];
	struct path path;
	struct kstat st;
	int len;
	int ret;

	len = scnprintf(app_path, sizeof(app_path), "/data/data/%s", app_name);
	if (len < 0 || len >= sizeof(app_path)) {
		SUSFS_LOGE("the app name '%s' is too long\\n", app_name);
		return -EINVAL;
	}

	ret = kern_path(app_path, LOOKUP_FOLLOW, &path);
	if (ret) {
		SUSFS_LOGE("failed to look up '%s': %d\\n", app_path, ret);
		return ret;
	}

	ret = vfs_getattr(&path, &st, STATX_BASIC_STATS, 0);
	path_put(&path);
	if (ret) {
		SUSFS_LOGE("failed to get the attributes of '%s': %d\\n", app_path, ret);
		return ret;
	}

	*uid = from_kuid(&init_user_ns, st.uid);
	if (*uid < SUSFS_PRIORITY_UID_FILTER_MIN_UID ||
		*uid > SUSFS_PRIORITY_UID_FILTER_MAX_UID)
		return -EINVAL;

	return 0;
}

static int susfs_parse_priority_app_names(char *app_str, unsigned long *bits, bool skip_failed) {
	char *token = NULL;
	char *saveptr = app_str;
	uid_t uid = 0;
	int ret;

	while ((token = strsep(&saveptr, ",")) != NULL) {
		token = strim(token);
		if (*token == '\\0') {
			continue;
		}

		if (!susfs_is_valid_app_name(token)) {
			SUSFS_LOGE("invalid app name '%s'\\n", token);
			return -EINVAL;
		}

		ret = susfs_resolve_priority_app_uid(token, &uid);
		if (ret) {
			if (skip_failed)
				continue;
			return ret;
		}

		if (uid < SUSFS_PRIORITY_UID_FILTER_MIN_UID || uid > SUSFS_PRIORITY_UID_FILTER_MAX_UID) {
			SUSFS_LOGE("the uid %u of the app '%s' is out of the allowed range [%d, %d]\\n",
					uid, token, SUSFS_PRIORITY_UID_FILTER_MIN_UID,
					SUSFS_PRIORITY_UID_FILTER_MAX_UID);
			if (!skip_failed)
				return -EINVAL;
			continue;
		}

		set_bit(uid - SUSFS_PRIORITY_UID_FILTER_MIN_UID, bits);
		SUSFS_LOGI("app_name '%s', uid '%u' is now added to priority_uid_filter_bitmap\\n", token, uid);
	}

	return 0;
}

void susfs_set_priority_uid_filter(void __user **user_info) {
	struct st_susfs_priority_uid_filter *info = NULL;
	struct susfs_priority_uid_filter_bitmap *new_bitmap = NULL;
	struct susfs_priority_uid_filter_bitmap *old_bitmap = NULL;
	char *new_app_strings = NULL;
	struct cred *orig_cred = NULL;
	size_t app_str_len = 0;
	int err = 0;
	static bool is_uid_filter_set_before = false;

	info = kvmalloc(sizeof(*info), GFP_KERNEL | __GFP_ZERO);
	if (!info) {
		err = -ENOMEM;
		goto out_copy_to_user;
	}

	if (copy_from_user(info, (struct st_susfs_priority_uid_filter __user*)*user_info, sizeof(*info))) {
		err = -EFAULT;
		goto out_copy_to_user;
	}

	if (!memchr(info->app_strings, '\\0', sizeof(info->app_strings))) {
		SUSFS_LOGE("the app names string is not null terminated\\n");
		err = -EINVAL;
		goto out_copy_to_user;
	}

	if (*info->app_strings == '\\0') {
		SUSFS_LOGE("the app names string cannot be empty\\n");
		err = -EINVAL;
		goto out_copy_to_user;
	}

	app_str_len = strlen(info->app_strings);

	new_app_strings = kvmalloc(app_str_len + 1, GFP_KERNEL | __GFP_ZERO);
	if (!new_app_strings) {
		err = -ENOMEM;
		goto out_copy_to_user;
	}
	memcpy(new_app_strings, info->app_strings, app_str_len + 1);

	new_bitmap = (struct susfs_priority_uid_filter_bitmap *)kzalloc(sizeof(*new_bitmap), GFP_KERNEL);
	if (!new_bitmap) {
		err = -ENOMEM;
		goto out_free_new_app_strings;
	}

	orig_cred = susfs_switch_to_ksu_domain();
	if (!orig_cred) {
		err = -EINVAL;
		goto out_free_new_bitmap;
	}

	if (is_uid_filter_set_before)
		SUSFS_LOGI("renewing the priority uid filter\\n");
	err = susfs_parse_priority_app_names(info->app_strings, new_bitmap->bits, false);

	susfs_restore_creds(orig_cred);
	orig_cred = NULL;

	if (err)
		goto out_free_new_bitmap;

	mutex_lock(&susfs_mutex_lock_priority_uid_filter);
	old_bitmap = rcu_dereference_protected(priority_uid_filter_bitmap, lockdep_is_held(&susfs_mutex_lock_priority_uid_filter));
	rcu_assign_pointer(priority_uid_filter_bitmap, new_bitmap);
	new_bitmap = NULL;
	kvfree(susfs_priority_app_strings);
	susfs_priority_app_strings = new_app_strings;
	new_app_strings = NULL;
	if (!is_uid_filter_set_before)
		is_uid_filter_set_before = true;
	mutex_unlock(&susfs_mutex_lock_priority_uid_filter);

	kfree_rcu(old_bitmap, rcu);

	SUSFS_LOGI("the priority uid filter is set\\n");
	err = 0;

out_free_new_bitmap:
	if (new_bitmap)
		kfree(new_bitmap);
out_free_new_app_strings:
	if (new_app_strings)
		kvfree(new_app_strings);
out_copy_to_user:
	if (copy_to_user(&((struct st_susfs_priority_uid_filter __user*)*user_info)->err, &err, sizeof(err))) {
		err = -EFAULT;
	}
	SUSFS_LOGI("CMD_SUSFS_SET_PRIORITY_UID_FILTER -> ret: %d\\n", err);
	if (info)
		kvfree(info);
}

static int susfs_priority_app_strings_worker(void *data) {
	struct susfs_priority_uid_filter_bitmap *new_bitmap = NULL;
	struct susfs_priority_uid_filter_bitmap *old_bitmap = NULL;
	struct cred *orig_cred = NULL;
	char *app_strings = NULL;
	size_t app_str_len = 0;
	int ret = 0;

	orig_cred = susfs_switch_to_ksu_domain();
	if (!orig_cred)
		goto out;

	mutex_lock(&susfs_mutex_lock_priority_uid_filter);
	if (susfs_priority_app_strings) {
		app_str_len = strlen(susfs_priority_app_strings);
		app_strings = kvmalloc(app_str_len + 1, GFP_KERNEL | __GFP_ZERO);
		if (app_strings)
			memcpy(app_strings, susfs_priority_app_strings, app_str_len + 1);
	}
	mutex_unlock(&susfs_mutex_lock_priority_uid_filter);

	if (!app_strings)
		goto out_restore_creds;

	new_bitmap = (struct susfs_priority_uid_filter_bitmap *)kzalloc(sizeof(*new_bitmap), GFP_KERNEL);
	if (!new_bitmap)
		goto out_restore_creds;

	ret = susfs_parse_priority_app_names(app_strings, new_bitmap->bits, true);
	if (ret)
		goto out_restore_creds;

	mutex_lock(&susfs_mutex_lock_priority_uid_filter);
	old_bitmap = rcu_dereference_protected(priority_uid_filter_bitmap, lockdep_is_held(&susfs_mutex_lock_priority_uid_filter));
	rcu_assign_pointer(priority_uid_filter_bitmap, new_bitmap);
	new_bitmap = NULL;
	mutex_unlock(&susfs_mutex_lock_priority_uid_filter);

	kfree_rcu(old_bitmap, rcu);

	SUSFS_LOGI("the uids of the priority uid filter are resolved again\\n");

out_restore_creds:
	susfs_restore_creds(orig_cred);
	orig_cred = NULL;
out:
	if (new_bitmap)
		kfree(new_bitmap);
	if (app_strings)
		kvfree(app_strings);
	atomic_set(&susfs_priority_app_strings_running, 0);

	return ret;
}

void susfs_parse_priority_app_strings(void) {
	if (atomic_cmpxchg(&susfs_priority_app_strings_running, 0, 1))
		return;

	if (IS_ERR(kthread_run(susfs_priority_app_strings_worker, NULL, "susfs_gpsp_appstr"))) {
		atomic_set(&susfs_priority_app_strings_running, 0);
		SUSFS_LOGE("failed to create the thread susfs_priority_app_strings\\n");
	}
}

bool susfs_is_priority_uid_filtered(uid_t uid) {
	struct susfs_priority_uid_filter_bitmap *bitmap;

	uid_t app_id = uid % 100000;

	if (app_id < SUSFS_PRIORITY_UID_FILTER_MIN_UID ||
		app_id > SUSFS_PRIORITY_UID_FILTER_MAX_UID)
		return false;

	bitmap = rcu_dereference(priority_uid_filter_bitmap);
	if (likely(bitmap)) {
		if (test_bit(app_id - SUSFS_PRIORITY_UID_FILTER_MIN_UID, bitmap->bits)) {
			return true;
		}
	}

	return false;
}

"""
    anchor = "/* susfs avc log spoofing */"
    if anchor not in c:
        raise SystemExit("cannot find /* susfs avc log spoofing */ anchor in fs/susfs.c")
    c = c.replace(anchor, prio_impl + anchor, 1)
    print("added priority uid filter implementation to fs/susfs.c (c05208ea)", flush=True)

Path("fs/susfs.c").write_text(c)
print("applied upstream SUSFS 2.3.0 bugfixes + priority uid filter to fs/susfs.c", flush=True)

# 4. Patch kernel/sys.c for setpriority / getpriority priority uid filter
sys_p = Path("kernel/sys.c")
if sys_p.exists():
    sys_s = sys_p.read_text()
    if "susfs_is_priority_uid_filtered" not in sys_s:
        decl_anchor = "SYSCALL_DEFINE3(setpriority, int, which, int, who, int, niceval)\n"
        if decl_anchor not in sys_s:
            raise SystemExit("cannot find setpriority signature in kernel/sys.c")
        sys_s = sys_s.replace(
            decl_anchor,
            "#ifdef CONFIG_KSU_SUSFS\n"
            "extern bool susfs_is_priority_uid_filtered(uid_t uid);\n"
            "#endif // #ifdef CONFIG_KSU_SUSFS\n\n" + decl_anchor,
            1,
        )
        old_prio_block = (
            "\t\tif (!who)\n"
            "\t\t\tuid = cred->uid;\n"
            "\t\telse if (!uid_eq(uid, cred->uid)) {\n"
            "\t\t\tuser = find_user(uid);\n"
        )
        new_prio_block = (
            "\t\tif (!who)\n"
            "\t\t\tuid = cred->uid;\n"
            "\t\telse if (!uid_eq(uid, cred->uid)) {\n"
            "#ifdef CONFIG_KSU_SUSFS\n"
            "\t\t\tif (cred->uid.val >= 10000 && susfs_is_priority_uid_filtered(uid.val))\n"
            "\t\t\t\tgoto out_unlock;\n"
            "#endif // #ifdef CONFIG_KSU_SUSFS\n"
            "\t\t\tuser = find_user(uid);\n"
        )
        cnt = sys_s.count(old_prio_block)
        if cnt != 2:
            raise SystemExit(f"expected 2 PRIO_USER blocks in kernel/sys.c, found {cnt}")
        sys_s = sys_s.replace(old_prio_block, new_prio_block, 2)
        sys_p.write_text(sys_s)
        print("hooked setpriority/getpriority in kernel/sys.c for priority uid filter (c05208ea)", flush=True)

# 5. Patch block/ioprio.c for ioprio_set / ioprio_get priority uid filter
iop_p = Path("block/ioprio.c")
if iop_p.exists():
    iop_s = iop_p.read_text()
    if "susfs_is_priority_uid_filtered" not in iop_s:
        decl_anchor = "SYSCALL_DEFINE3(ioprio_set, int, which, int, who, int, ioprio)\n"
        if decl_anchor not in iop_s:
            raise SystemExit("cannot find ioprio_set signature in block/ioprio.c")
        iop_s = iop_s.replace(
            decl_anchor,
            "#ifdef CONFIG_KSU_SUSFS\n"
            "extern bool susfs_is_priority_uid_filtered(uid_t uid);\n"
            "#endif // #ifdef CONFIG_KSU_SUSFS\n\n" + decl_anchor,
            1,
        )
        old_iop_block = (
            "\t\t\tif (!who)\n"
            "\t\t\t\tuser = current_user();\n"
            "\t\t\telse\n"
            "\t\t\t\tuser = find_user(uid);\n"
        )
        new_iop_block = (
            "\t\t\tif (!who)\n"
            "\t\t\t\tuser = current_user();\n"
            "\t\t\telse\n"
            "#ifdef CONFIG_KSU_SUSFS\n"
            "\t\t\t{\n"
            "\t\t\t\tif (current_uid().val >= 10000 && susfs_is_priority_uid_filtered(uid.val))\n"
            "\t\t\t\t\tbreak;\n"
            "\t\t\t\tuser = find_user(uid);\n"
            "\t\t\t}\n"
            "#else\n"
            "\t\t\t\tuser = find_user(uid);\n"
            "#endif // #ifdef CONFIG_KSU_SUSFS\n"
        )
        cnt = iop_s.count(old_iop_block)
        if cnt != 2:
            raise SystemExit(f"expected 2 IOPRIO_WHO_USER blocks in block/ioprio.c, found {cnt}")
        iop_s = iop_s.replace(old_iop_block, new_iop_block, 2)
        iop_p.write_text(iop_s)
        print("hooked ioprio_set/ioprio_get in block/ioprio.c for priority uid filter (c05208ea)", flush=True)

# 6. Sync latest BakaSU KernelSU with SUSFS c05208ea and unblock susfs_compat.mk
sus_mk = Path("KernelSU/kernel/tools/susfs_compat.mk")
if sus_mk.exists():
    mk_s = sus_mk.read_text()
    if "Please wait susfs update" in mk_s:
        mk_lines = [
            ln for ln in mk_s.splitlines(True)
            if "susfs has NOT update" not in ln
            and "Please wait simonpunk update" not in ln
            and "Please wait susfs update" not in ln
        ]
        sus_mk.write_text("".join(mk_lines))
        print("unblocked KernelSU/kernel/tools/susfs_compat.mk (sync-susfs)", flush=True)

disp_p = Path("KernelSU/kernel/supercall/dispatch.c")
if disp_p.exists():
    ds = disp_p.read_text()
    if "CMD_SUSFS_SET_PRIORITY_UID_FILTER" not in ds:
        anchor = "    case CMD_SUSFS_ENABLE_AVC_LOG_SPOOFING:"
        block = (
            "    case CMD_SUSFS_SET_PRIORITY_UID_FILTER: {\n"
            "        susfs_set_priority_uid_filter(arg);\n"
            "        return 0;\n"
            "    }\n"
        )
        if anchor not in ds:
            raise SystemExit("cannot find CMD_SUSFS_ENABLE_AVC_LOG_SPOOFING in KernelSU/kernel/supercall/dispatch.c")
        ds = ds.replace(anchor, block + anchor, 1)
        disp_p.write_text(ds)
        print("added CMD_SUSFS_SET_PRIORITY_UID_FILTER to KernelSU/kernel/supercall/dispatch.c", flush=True)

pkg_p = Path("KernelSU/kernel/manager/pkg_observer.c")
if pkg_p.exists():
    ps = pkg_p.read_text()
    if "susfs_parse_priority_app_strings" not in ps:
        if "#include <linux/susfs.h>" not in ps:
            ps = ps.replace(
                "#include <linux/version.h>",
                "#include <linux/version.h>\n#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs.h>\n#endif",
                1,
            )
        anchor = "static void ksu_defer_track_throne(void)\n{\n    struct callback_head *cb;\n"
        if anchor in ps:
            ps = ps.replace(
                anchor,
                anchor + "\n#ifdef CONFIG_KSU_SUSFS\n    susfs_parse_priority_app_strings();\n#endif\n",
                1,
            )
            pkg_p.write_text(ps)
            print("added susfs_parse_priority_app_strings to KernelSU/kernel/manager/pkg_observer.c", flush=True)

thr_p = Path("KernelSU/kernel/manager/throne_tracker.c")
if thr_p.exists():
    ts = thr_p.read_text()
    if "susfs_parse_priority_app_strings" not in ts:
        if "#include <linux/susfs.h>" not in ts:
            ts = ts.replace(
                "#include <linux/version.h>",
                "#include <linux/version.h>\n#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs.h>\n#endif",
                1,
            )
        anchor = "void track_throne(unsigned int flags)\n{\n"
        if anchor in ts:
            ts = ts.replace(
                anchor,
                anchor + "#ifdef CONFIG_KSU_SUSFS\n    susfs_parse_priority_app_strings();\n#endif\n",
                1,
            )
            thr_p.write_text(ts)
            print("added susfs_parse_priority_app_strings to KernelSU/kernel/manager/throne_tracker.c", flush=True)

sysno_mk = Path("KernelSU/kernel/tools/code_generation/syscall_no/syscall_no.mk")
if sysno_mk.exists():
    smk = sysno_mk.read_text()
    if "always += compat/syscall_no.h" not in smk and "always-y += compat/syscall_no.h" in smk:
        smk = smk.replace(
            "always-y += compat/syscall_no.h",
            "always += compat/syscall_no.h\nalways-y += compat/syscall_no.h",
            1,
        )
        sysno_mk.write_text(smk)
        print("added 4.14 Kbuild always += compat/syscall_no.h to syscall_no.mk", flush=True)
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

if [[ -f KernelSU/kernel/tools/code_generation/syscall_no/syscall_no.c ]]; then
  echo '===== Pre-generate KernelSU/kernel/compat/syscall_no.h for 4.14 arm64+compat ====='
  mkdir -p KernelSU/kernel/compat
  gcc -O2 KernelSU/kernel/tools/code_generation/syscall_no/syscall_no.c -o /tmp/ksu_syscall_no
  if [[ -f arch/arm64/include/asm/unistd32.h ]]; then
    /tmp/ksu_syscall_no KernelSU/kernel/compat/syscall_no.h --arm64-compat arch/arm64/include/asm/unistd32.h
  else
    /tmp/ksu_syscall_no KernelSU/kernel/compat/syscall_no.h --arm64
  fi
  test -s KernelSU/kernel/compat/syscall_no.h
  echo '[PASS] Pre-generated KernelSU/kernel/compat/syscall_no.h'
fi

if [[ -e KernelSU/kernel/feature/sucompat.c || -e drivers/kernelsu/feature/sucompat.c || -e KernelSU/kernel/sucompat.c ]]; then
  echo '===== Keep current KSU sucompat on 4.14 user-pointer handlers ====='
  git show "$GITHUB_SHA:.github/scripts/adapt-ksu-sucompat230.sh" > "$GITHUB_WORKSPACE/adapt-ksu-sucompat230.sh"
  chmod +x "$GITHUB_WORKSPACE/adapt-ksu-sucompat230.sh"
  "$GITHUB_WORKSPACE/adapt-ksu-sucompat230.sh"
fi

grep -Fq 'CMD_SUSFS_SET_PRIORITY_UID_FILTER' include/linux/susfs_def.h
grep -Fq 'susfs_set_priority_uid_filter' include/linux/susfs.h
grep -Fq 'susfs_is_priority_uid_filtered' fs/susfs.c
grep -Fq 'susfs_is_priority_uid_filtered' kernel/sys.c
grep -Fq 'susfs_is_priority_uid_filtered' block/ioprio.c

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
  echo 'susfs_upstream_commit=c05208ea'
  echo 'priority_uid_filter=enabled'
  echo 'is_statically=bool'
  echo 'bakasu_susfs_compat_unblocked=yes'
} | tee "$GITHUB_WORKSPACE/run25-susfs230-proof.txt"

echo '[PASS] SUSFS 2.3.0 headers + 4.14 user_path_at hooks'
