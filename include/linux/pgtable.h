/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _LINUX_PGTABLE_H
#define _LINUX_PGTABLE_H

/*
 * Compatibility shim for newer out-of-tree code on the OPPO/QCOM 4.14 tree.
 * This vendor kernel has the ARM64 page-table definitions in asm/pgtable.h
 * but does not provide the newer generic linux/pgtable.h wrapper expected by
 * RapliVx KernelSU.
 */
#include <asm/pgtable.h>

#endif /* _LINUX_PGTABLE_H */
