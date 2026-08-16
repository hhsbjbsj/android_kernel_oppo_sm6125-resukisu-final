// SPDX-License-Identifier: GPL-2.0
/*
 * Minimal backport of the VFS vfs_mkobj() primitive required by
 * Android-16 BPF commit 1344db23d.  OPPO's 4.14 VFS predates that helper.
 *
 * This is intentionally scoped to bpffs: kernel/bpf/inode.o maps the donor
 * vfs_mkobj() call to bpf_vfs_mkobj(), so no unrelated OPPO VFS code changes.
 */
#include <linux/audit.h>
#include <linux/fs.h>
#include <linux/fsnotify.h>
#include <linux/security.h>
#include <linux/user_namespace.h>

static int bpf_may_create(struct inode *dir, struct dentry *child)
{
	struct user_namespace *s_user_ns;

	audit_inode_child(dir, child, AUDIT_TYPE_CHILD_CREATE);
	if (child->d_inode)
		return -EEXIST;
	if (IS_DEADDIR(dir))
		return -ENOENT;

	s_user_ns = dir->i_sb->s_user_ns;
	if (!kuid_has_mapping(s_user_ns, current_fsuid()) ||
	    !kgid_has_mapping(s_user_ns, current_fsgid()))
		return -EOVERFLOW;

	/* Match this OPPO tree's VFS creation path: a NULL mount selects the
	 * legacy inode permission operation, as vfs_mknod() already does here.
	 */
	return inode_permission2(NULL, dir, MAY_WRITE | MAY_EXEC);
}

int bpf_vfs_mkobj(struct dentry *dentry, umode_t mode,
		  int (*f)(struct dentry *, umode_t, void *),
		  void *arg)
{
	struct inode *dir = dentry->d_parent->d_inode;
	int error;

	error = bpf_may_create(dir, dentry);
	if (error)
		return error;

	mode &= S_IALLUGO;
	mode |= S_IFREG;
	error = security_inode_create(dir, dentry, mode);
	if (error)
		return error;

	error = f(dentry, mode, arg);
	if (!error)
		fsnotify_create(dir, dentry);
	return error;
}
