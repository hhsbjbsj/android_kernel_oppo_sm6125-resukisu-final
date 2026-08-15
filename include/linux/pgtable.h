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

/*
 * mmap_read_trylock()/mmap_read_unlock() are the post-4.14 names for the
 * read-side mmap lock.  PCHM30 4.14 still exposes the same lock as
 * mm->mmap_sem.  Keep RapliVx's non-blocking locking semantics exactly: do
 * not replace the trylock with a blocking down_read(), and always pair it with
 * up_read() on the same mmap_sem.
 */
#ifdef CONFIG_KSU
#ifndef mmap_read_trylock
#define mmap_read_trylock(mm) down_read_trylock(&(mm)->mmap_sem)
#endif
#ifndef mmap_read_unlock
#define mmap_read_unlock(mm) up_read(&(mm)->mmap_sem)
#endif
#endif

#endif /* _LINUX_PGTABLE_H */
