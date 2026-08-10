/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _LINUX_PCHM30_SUKISU_4_14_COMPAT_H
#define _LINUX_PCHM30_SUKISU_4_14_COMPAT_H

/*
 * PCHM30 / SukiSU Linux 4.14 compatibility marker.
 *
 * Keep this header intentionally free of global compatibility macros.
 * The pinned SukiSU builtin tree is adapted only by
 * tools/pchm30/sukisu-builtin-4.14-compat.patch.
 *
 * In particular, never define a global `fallthrough` macro here: Linux 4.14
 * contains legitimate labels named `fallthrough` (for example SCTP), and a
 * macro with that name corrupts unrelated kernel sources during preprocessing.
 */

#endif /* _LINUX_PCHM30_SUKISU_4_14_COMPAT_H */
