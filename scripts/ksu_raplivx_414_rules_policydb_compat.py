#!/usr/bin/env python3
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
KERNEL_MAKEFILE = ROOT / "Makefile"
RULES = ROOT / "drivers/kernelsu/selinux/rules.c"
APP_PROFILE = ROOT / "drivers/kernelsu/app_profile.c"
KERNEL_UMOUNT = ROOT / "drivers/kernelsu/kernel_umount.c"
RULES_MARKER = "PCHM30_RAPLIVX_RULES_POLICYDB_414_COMPAT"
LINK_MARKER = "PCHM30_RAPLIVX_LINK_API_414_COMPAT"


def die(msg: str) -> None:
    raise SystemExit(f"[KSU RapliVx 4.14 compat] {msg}")


mk = KERNEL_MAKEFILE.read_text(errors="surrogateescape")
version = re.search(r"^VERSION\s*=\s*(\d+)\s*$", mk, re.M)
patchlevel = re.search(r"^PATCHLEVEL\s*=\s*(\d+)\s*$", mk, re.M)
if not version or not patchlevel:
    die("cannot determine kernel VERSION/PATCHLEVEL")
if (int(version.group(1)), int(patchlevel.group(1))) != (4, 14):
    sys.exit(0)

for target in (RULES, APP_PROFILE, KERNEL_UMOUNT):
    if not target.exists():
        die(f"missing transient RapliVx source: {target}")

# 1) SELinux policydb ownership changed between this 4.14 tree and the pinned
# RapliVx source. Keep the modern source pinned and adapt only the transient
# copy used by this build.
text = RULES.read_text(errors="surrogateescape")
if RULES_MARKER not in text:
    if '#include "ss/services.h"' not in text:
        die("rules.c no longer includes ss/services.h")

    old = '''static struct policydb *get_policydb(void)
{
    struct policydb *db;
    struct selinux_policy *policy = selinux_state.policy;
    db = &policy->policydb;
    return db;
}
'''
    new = f'''static struct policydb *get_policydb(void)
{{
    /* {RULES_MARKER}: OPPO Linux 4.14 stores policydb under selinux_state.ss. */
    return &selinux_state.ss->policydb;
}}
'''
    count = text.count(old)
    if count != 1:
        die(f"expected exactly one modern get_policydb block, found {count}")
    text = text.replace(old, new, 1)
    RULES.write_text(text, errors="surrogateescape")

text = RULES.read_text(errors="surrogateescape")
for forbidden in (
    "selinux_state.policy",
    "struct selinux_policy *policy",
):
    if forbidden in text:
        die(f"unsupported newer SELinux policy path remains: {forbidden}")
if "return &selinux_state.ss->policydb;" not in text:
    die("Linux 4.14 policydb path was not installed")

# 2) seccomp_filter_release() is a newer exit-time helper. Linux 4.14 already
# exposes put_seccomp_filter(task), which drops exactly the fake task's copied
# filter-tree reference after current->seccomp.filter has been detached. Do not
# touch the stock kernel/seccomp.c implementation or weaken CONFIG_SECCOMP.
text = APP_PROFILE.read_text(errors="surrogateescape")
seccomp_marker = f"{LINK_MARKER}: use 4.14 put_seccomp_filter"
if seccomp_marker not in text:
    old = "    seccomp_filter_release(fake);\n"
    new = (
        f"    /* {seccomp_marker}; keep stock seccomp refcount semantics. */\n"
        "    put_seccomp_filter(fake);\n"
    )
    count = text.count(old)
    if count != 1:
        die(f"expected exactly one seccomp_filter_release(fake) call, found {count}")
    text = text.replace(old, new, 1)
    APP_PROFILE.write_text(text, errors="surrogateescape")

text = APP_PROFILE.read_text(errors="surrogateescape")
if "seccomp_filter_release(fake);" in text:
    die("newer seccomp_filter_release call remains on Linux 4.14")
if "put_seccomp_filter(fake);" not in text:
    die("Linux 4.14 seccomp filter release path was not installed")

# 3) path_umount() was split out of the VFS after 4.14. This OPPO tree still
# provides the stock sys_umount() path, including may_mount(),
# security_sb_umount(), MNT_LOCKED and do_umount() checks. For 4.14 only, call
# that existing implementation under KERNEL_DS so the kernel-owned pathname is
# accepted by the old user-pointer syscall wrapper. This preserves the vendor
# VFS/security path instead of reimplementing or bypassing it in KernelSU.
text = KERNEL_UMOUNT.read_text(errors="surrogateescape")
umount_marker = f"{LINK_MARKER}: use stock 4.14 sys_umount"
if umount_marker not in text:
    include_anchor = "#include <linux/types.h>\n"
    extra_includes = "#include <linux/syscalls.h>\n#include <linux/uaccess.h>\n"
    if "#include <linux/syscalls.h>\n" not in text:
        if include_anchor not in text:
            die("kernel_umount.c include anchor not found")
        text = text.replace(include_anchor, include_anchor + extra_includes, 1)

    pattern = re.compile(
        r"extern int path_umount\(struct path \*path, int flags\);\n\n"
        r"static void ksu_umount_mnt\(struct path \*path, int flags\)\n"
        r"\{.*?\n\}\n\n"
        r"static void try_umount\(const char \*mnt, int flags\)\n"
        r"\{.*?\n\}\n",
        re.S,
    )
    replacement = f'''static void try_umount(const char *mnt, int flags)
{{
    mm_segment_t old_fs;
    int err;

    /* {umount_marker}; preserves VFS + LSM checks. */
    old_fs = get_fs();
    set_fs(KERNEL_DS);
    err = sys_umount((char __user *)mnt, flags);
    set_fs(old_fs);

    if (err)
        pr_info("umount %s failed: %d\\n", mnt, err);
}}
'''
    text, count = pattern.subn(lambda _m: replacement, text, count=1)
    if count != 1:
        die(f"expected exactly one path_umount compatibility block, found {count}")
    KERNEL_UMOUNT.write_text(text, errors="surrogateescape")

text = KERNEL_UMOUNT.read_text(errors="surrogateescape")
for forbidden in (
    "extern int path_umount(struct path *path, int flags);",
    "path_umount(path, flags)",
):
    if forbidden in text:
        die(f"newer umount API remains on Linux 4.14: {forbidden}")
for required in (
    "#include <linux/syscalls.h>",
    "#include <linux/uaccess.h>",
    "sys_umount((char __user *)mnt, flags);",
    "set_fs(KERNEL_DS);",
):
    if required not in text:
        die(f"Linux 4.14 umount compatibility token missing: {required}")
