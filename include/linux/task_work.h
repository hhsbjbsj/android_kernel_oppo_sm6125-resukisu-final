/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _LINUX_TASK_WORK_H
#define _LINUX_TASK_WORK_H

#include <linux/list.h>
#include <linux/sched.h>
#include <linux/sched/task.h>

/*
 * Newer kernels pass enum task_work_notify_mode to task_work_add(), while
 * this 4.14 tree still takes a bool notify argument.  TWA_RESUME means the
 * caller wants notify-resume semantics, which maps directly to true here.
 */
#ifndef TWA_RESUME
#define TWA_RESUME true
#endif

/*
 * ksys_close() was introduced after this 4.14 baseline.  RapliVx KernelSU's
 * pre-wrapper supercall path uses it for the old-kernel close fallback; on
 * this tree sys_close() provides the equivalent in-kernel close operation.
 * Keep the compatibility alias local to CONFIG_KSU builds.
 */
#ifdef CONFIG_KSU
#ifndef ksys_close
#define ksys_close sys_close
#endif
#endif

typedef void (*task_work_func_t)(struct callback_head *);

static inline void
init_task_work(struct callback_head *twork, task_work_func_t func)
{
	twork->func = func;
}

int task_work_add(struct task_struct *task, struct callback_head *twork, bool);
struct callback_head *task_work_cancel(struct task_struct *, task_work_func_t);
void task_work_run(void);

static inline void exit_task_work(struct task_struct *task)
{
	task_work_run();
}

#endif	/* _LINUX_TASK_WORK_H__ */
