/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _LINUX_KSU_COMPAT_414_H
#define _LINUX_KSU_COMPAT_414_H

/* PCHM30 Linux 4.14 compatibility used only when CONFIG_KSU is enabled. */
#ifdef CONFIG_KSU

#include <linux/dcache.h>
#include <linux/err.h>
#include <linux/errno.h>
#include <linux/fs.h>
#include <linux/limits.h>
#include <linux/module.h>
#include <linux/slab.h>
#include <linux/syscalls.h>
#include <linux/uaccess.h>
#include <linux/version.h>
#include <asm/ptrace.h>

#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 0, 0)

/* ksys_unshare() is newer than this 4.14 syscall ABI. */
#ifndef ksys_unshare
#define ksys_unshare sys_unshare
#endif

/*
 * copy_{from,to}_user_nofault() were added after this Android 4.14 tree.
 * Preserve the modern no-fault contract instead of falling back to the
 * sleeping copy_{from,to}_user() helpers: validate the user range, disable
 * page faults, use the in-atomic copy primitive, and return 0/-EFAULT.
 */
static inline long copy_from_user_nofault(void *dst,
					  const void __user *src,
					  size_t size)
{
	long ret = -EFAULT;

	if (!access_ok(VERIFY_READ, src, size))
		return ret;

	pagefault_disable();
	ret = __copy_from_user_inatomic(dst, src, size);
	pagefault_enable();

	return ret ? -EFAULT : 0;
}

static inline long copy_to_user_nofault(void __user *dst,
					const void *src,
					size_t size)
{
	long ret = -EFAULT;

	if (!access_ok(VERIFY_WRITE, dst, size))
		return ret;

	pagefault_disable();
	ret = __copy_to_user_inatomic(dst, src, size);
	pagefault_enable();

	return ret ? -EFAULT : 0;
}

/*
 * RapliVx's pre-wrapper source calls the modern arm64 pt_regs syscall entry.
 * On this 4.14 tree sys_setns(fd, nstype) is the native in-kernel entry.
 */
#if defined(CONFIG_ARM64)
#define __arm64_sys_setns ksu_compat_arm64_sys_setns
static inline long ksu_compat_arm64_sys_setns(const struct pt_regs *regs)
{
	return sys_setns((int)regs->regs[0], (int)regs->regs[1]);
}
#endif

/*
 * path_mount() is newer than this tree.  Recreate its required behaviour for
 * the KernelSU mount-namespace path using the old sys_mount() entry.  d_path()
 * preserves the path selected by the caller; set_fs(KERNEL_DS) is the native
 * 4.14 mechanism that lets the old syscall consume these kernel buffers.
 */
static inline int path_mount(const char *dev_name, struct path *path,
			     const char *type_page, unsigned long flags,
			     void *data_page)
{
	mm_segment_t old_fs;
	char *buf;
	char *dir_name;
	long ret;

	buf = kmalloc(PATH_MAX, GFP_KERNEL);
	if (!buf)
		return -ENOMEM;

	dir_name = d_path(path, buf, PATH_MAX);
	if (IS_ERR(dir_name)) {
		ret = PTR_ERR(dir_name);
		goto out;
	}

	old_fs = get_fs();
	set_fs(KERNEL_DS);
	ret = sys_mount((char __user *)dev_name,
			(char __user *)dir_name,
			(char __user *)type_page,
			flags, (void __user *)data_page);
	set_fs(old_fs);

out:
	kfree(buf);
	return (int)ret;
}

#endif /* < 5.0 */
#endif /* CONFIG_KSU */

#endif /* _LINUX_KSU_COMPAT_414_H */
