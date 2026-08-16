/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _KERNEL_BPF_ATOMIC_COND_READ_COMPAT_H
#define _KERNEL_BPF_ATOMIC_COND_READ_COMPAT_H

#include <linux/atomic.h>
#include <linux/compiler.h>
#include <asm/processor.h>

/*
 * Android-16 BPF commit b4eac9a69 uses atomic_cond_read_relaxed() for the
 * generic bpf_spin_lock fallback.  This OPPO 4.14 tree predates that atomic
 * helper.  Keep the compatibility surface local to kernel/bpf/helpers.o and
 * reproduce upstream's relaxed wait semantics: READ_ONCE the atomic counter,
 * expose the loaded value as VAL to the condition expression, and cpu_relax()
 * while the condition is false.
 */
#ifndef atomic_cond_read_relaxed
#define atomic_cond_read_relaxed(v, cond_expr) ({		\
	atomic_t *__v = (v);					\
	int VAL;						\
	for (;;) {						\
		VAL = READ_ONCE(__v->counter);			\
		if (cond_expr)					\
			break;					\
		cpu_relax();					\
	}							\
	VAL;							\
})
#endif

#endif /* _KERNEL_BPF_ATOMIC_COND_READ_COMPAT_H */
