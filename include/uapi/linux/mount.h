/* SPDX-License-Identifier: GPL-2.0 WITH Linux-syscall-note */
#ifndef _UAPI_LINUX_MOUNT_H
#define _UAPI_LINUX_MOUNT_H

/*
 * Linux 4.14 keeps the classic MS_* mount flags in uapi/linux/fs.h.
 * Newer KernelSU sources include uapi/linux/mount.h instead, so provide the
 * modern include path without duplicating or changing the old UAPI values.
 */
#include <uapi/linux/fs.h>

#endif /* _UAPI_LINUX_MOUNT_H */
