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

#endif	/* _LINUX_TASK_WORK_H */
