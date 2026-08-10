/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _LINUX_PCHM30_SUKISU_4_14_COMPAT_H
#define _LINUX_PCHM30_SUKISU_4_14_COMPAT_H

/*
 * Compatibility shim for the pinned SukiSU builtin tree on the verified
 * PCHM30 Linux 4.14 kernel. Keep this branch-local and minimal.
 */

#ifndef fallthrough
#define fallthrough do { } while (0)
#endif

/* Linux 4.14 has strncpy_from_user(), but not the later nofault spelling. */
#ifndef strncpy_from_user_nofault
#define strncpy_from_user_nofault(dst, src, count) \
	strncpy_from_user((dst), (src), (count))
#endif

/*
 * The pinned builtin tree only builds selinux_hide.c on 5.10+, but ksud.c
 * still calls these helpers unconditionally. They are intentionally no-ops
 * on this 4.14 target.
 */
#ifndef ksu_selinux_hide_handle_post_fs_data
#define ksu_selinux_hide_handle_post_fs_data() do { } while (0)
#endif
#ifndef ksu_selinux_hide_handle_second_stage
#define ksu_selinux_hide_handle_second_stage() do { } while (0)
#endif

#endif /* _LINUX_PCHM30_SUKISU_4_14_COMPAT_H */
