/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _KERNEL_BPF_VFS_MKOBJ_COMPAT_H
#define _KERNEL_BPF_VFS_MKOBJ_COMPAT_H

#include <linux/fs.h>

int bpf_vfs_mkobj(struct dentry *dentry, umode_t mode,
		  int (*f)(struct dentry *, umode_t, void *),
		  void *arg);

/* Android-16 BPF commit 1344db23d expects upstream vfs_mkobj().
 * Keep that commit intact while providing the missing 4.14 VFS primitive
 * locally for bpffs only.
 */
#define vfs_mkobj bpf_vfs_mkobj

#endif
