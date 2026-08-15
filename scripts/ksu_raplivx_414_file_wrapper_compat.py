#!/usr/bin/env python3
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
KERNEL_MAKEFILE = ROOT / "Makefile"
TARGET = ROOT / "drivers/kernelsu/file_wrapper.c"
MARKER = "PCHM30_RAPLIVX_FILE_WRAPPER_414_COMPAT"


def die(msg: str) -> None:
    raise SystemExit(f"[KSU 4.14 compat] {msg}")


def replace_once(text: str, old: str, new: str, desc: str) -> str:
    count = text.count(old)
    if count != 1:
        die(f"expected exactly one {desc} anchor, found {count}")
    return text.replace(old, new, 1)


def regex_once(text: str, pattern: str, replacement: str, desc: str) -> str:
    out, count = re.subn(pattern, replacement, text, count=1, flags=re.S)
    if count != 1:
        die(f"expected exactly one {desc} block, found {count}")
    return out


mk = KERNEL_MAKEFILE.read_text(errors="surrogateescape")
version = re.search(r"^VERSION\s*=\s*(\d+)\s*$", mk, re.M)
patchlevel = re.search(r"^PATCHLEVEL\s*=\s*(\d+)\s*$", mk, re.M)
if not version or not patchlevel:
    die("cannot determine kernel VERSION/PATCHLEVEL")
if (int(version.group(1)), int(patchlevel.group(1))) != (4, 14):
    sys.exit(0)

if not TARGET.exists():
    die(f"missing transient RapliVx source: {TARGET}")

text = TARGET.read_text(errors="surrogateescape")
if MARKER in text:
    sys.exit(0)

# The pinned RapliVx source assumes a post-4.14 file_operations baseline.
# Remove only operations which do not exist in this tree.  Do not fabricate
# struct file_operations members: that would make function-pointer layout
# assumptions unsafe for vendor/module-backed files.
text = regex_once(
    text,
    r"#if LINUX_VERSION_CODE >= KERNEL_VERSION\(6, 1, 0\)\n"
    r"static int ksu_wrapper_iopoll\(.*?\n#endif\n\n"
    r"(?=#if LINUX_VERSION_CODE < KERNEL_VERSION\(6, 6, 0\)\n"
    r"static int ksu_wrapper_iterate)",
    f"/* {MARKER}: Linux 4.14 has no file_operations.iopoll. */\n\n",
    "iopoll compatibility",
)

text = replace_once(
    text,
    "static __poll_t ksu_wrapper_poll(struct file *fp, struct poll_table_struct *pts)",
    "static unsigned int ksu_wrapper_poll(struct file *fp, struct poll_table_struct *pts)",
    "4.14 poll return type",
)

# remap_file_range/fadvise are newer file_operations members. Linux 4.14 has
# clone_file_range/dedupe_file_range instead.  The wrapper intentionally leaves
# those uncommon optional operations unadvertised rather than guessing at a
# cross-version argument mapping.
text = regex_once(
    text,
    r"// no REMAP_FILE_DEDUP: use file_in\n.*?"
    r"static int ksu_wrapper_fadvise\(.*?\n}\n\n"
    r"(?=static void ksu_release_file_wrapper)",
    f"/* {MARKER}: Linux 4.14 has no remap_file_range/fadvise fops. */\n\n",
    "remap/fadvise compatibility",
)

text = replace_once(
    text,
    "    p->ops.iopoll = fp->f_op->iopoll ? ksu_wrapper_iopoll : NULL;\n",
    "",
    "iopoll assignment",
)

text = regex_once(
    text,
    r"#if LINUX_VERSION_CODE >= KERNEL_VERSION\(6, 12, 0\)\n"
    r"    p->ops\.fop_flags = fp->f_op->fop_flags;\n"
    r"#else\n"
    r"    p->ops\.mmap_supported_flags = fp->f_op->mmap_supported_flags;\n"
    r"#endif\n",
    f"    /* {MARKER}: no fop_flags/mmap_supported_flags in 4.14. */\n",
    "mmap/fop flags assignment",
)

text = replace_once(
    text,
    "    p->ops.remap_file_range =\n        fp->f_op->remap_file_range ? ksu_wrapper_remap_file_range : NULL;\n"
    "    p->ops.fadvise = fp->f_op->fadvise ? ksu_wrapper_fadvise : NULL;\n",
    f"    /* {MARKER}: no remap_file_range/fadvise in 4.14. */\n",
    "remap/fadvise assignments",
)

# Before security_inode_init_security_anon() existed, alloc_anon_inode() still
# allocates the inode security blob through the normal inode allocation path.
# KernelSU replaces the resulting SELinux SID with ksu_file_sid before publish,
# so the newer anonymous-inode labeling helper is not required here.
text = regex_once(
    text,
    r"static struct inode \*\n"
    r"ksu_anon_inode_make_secure_inode\(const char \*name,\n"
    r"                                 const struct inode \*context_inode\)\n"
    r"\{.*?\n}\n\n"
    r"(?=static struct file \*ksu_anon_inode_create_getfile_compat)",
    f'''static struct inode *\nksu_anon_inode_make_secure_inode(const char *name,\n                                 const struct inode *context_inode)\n{{\n    struct inode *inode;\n\n    (void)name;\n    (void)context_inode;\n    if (unlikely(!anon_inode_mnt))\n        return ERR_PTR(-ENODEV);\n\n    inode = alloc_anon_inode(anon_inode_mnt->mnt_sb);\n    if (IS_ERR(inode))\n        return inode;\n    inode->i_flags &= ~S_PRIVATE;\n    return inode;\n}}\n\n/* {MARKER}: backport Linux alloc_file_pseudo() using 4.14 alloc_file(). */\nstatic struct file *ksu_alloc_file_pseudo_414(\n    struct inode *inode, struct vfsmount *mnt, const char *name, int flags,\n    const struct file_operations *fops)\n{{\n    static const struct dentry_operations anon_ops = {{\n        .d_dname = simple_dname,\n    }};\n    struct qstr this = QSTR_INIT(name, strlen(name));\n    struct path path;\n    struct file *file;\n\n    path.dentry = d_alloc_pseudo(mnt->mnt_sb, &this);\n    if (!path.dentry)\n        return ERR_PTR(-ENOMEM);\n    if (!mnt->mnt_sb->s_d_op)\n        d_set_d_op(path.dentry, &anon_ops);\n    path.mnt = mntget(mnt);\n    d_instantiate(path.dentry, inode);\n    file = alloc_file(&path, OPEN_FMODE(flags), fops);\n    if (IS_ERR(file)) {{\n        /* Preserve the caller's inode reference across path_put(), matching\n         * upstream alloc_file_pseudo() error semantics. */\n        ihold(inode);\n        path_put(&path);\n    }}\n    return file;\n}}\n\n''',
    "anonymous inode compatibility",
)

text = replace_once(
    text,
    "    file = alloc_file_pseudo(inode, anon_inode_mnt, name,\n"
    "                             flags & (O_ACCMODE | O_NONBLOCK), fops);",
    "    file = ksu_alloc_file_pseudo_414(\n"
    "        inode, anon_inode_mnt, name,\n"
    "        flags & (O_ACCMODE | O_NONBLOCK), fops);",
    "alloc_file_pseudo call",
)

# Ignore comments when checking for real member/function uses; comments retain
# upstream API names intentionally to document why each compatibility edit is
# necessary.
code_only = re.sub(r"/\*.*?\*/|//[^\n]*", "", text, flags=re.S)
for forbidden in (
    "->iopoll", ".iopoll",
    "->mmap_supported_flags", ".mmap_supported_flags",
    "->remap_file_range", ".remap_file_range",
    "->fadvise", ".fadvise",
    "security_inode_init_security_anon(",
    "alloc_file_pseudo(",
    "REMAP_FILE_DEDUP",
    "static __poll_t ksu_wrapper_poll",
):
    if forbidden in code_only:
        die(f"unsupported 4.14 token remains after patch: {forbidden}")

TARGET.write_text(text, errors="surrogateescape")
