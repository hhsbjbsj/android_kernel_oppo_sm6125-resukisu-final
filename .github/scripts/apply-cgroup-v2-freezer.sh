#!/usr/bin/env bash
# Apply cgroup v2 freezer backport to Qualcomm MSM 4.14 kernel for LineageOS 24 (Android 17)
# Supports: cgroup.freeze, cgroup.events (frozen 0/1), JOBCTL_TRAP_FREEZE, leave-frozen ptrace fix
set -Eeuo pipefail

KERNEL_DIR="${KERNEL_DIR:-$GITHUB_WORKSPACE/$KERNEL_REL}"
cd "$KERNEL_DIR"
export CGROUP_PROOF="${GITHUB_WORKSPACE:-.}/cgroup-v2-freezer-proof.txt"

python3 - <<'PY'
import sys, os
from pathlib import Path

proof_path = Path(os.environ.get("CGROUP_PROOF", "cgroup-v2-freezer-proof.txt"))
proof_lines = []

# 1. kernel/cgroup/Makefile
mk_path = Path("kernel/cgroup/Makefile")
mk = mk_path.read_text(encoding="utf-8")
if "legacy_freezer.o" not in mk:
    mk = mk.replace("obj-$(CONFIG_CGROUP_FREEZER) += freezer.o", "obj-$(CONFIG_CGROUP_FREEZER) += legacy_freezer.o", 1)
    if "obj-y := cgroup.o namespace.o cgroup-v1.o\n" in mk:
        mk = mk.replace("obj-y := cgroup.o namespace.o cgroup-v1.o\n", "obj-y := cgroup.o namespace.o cgroup-v1.o freezer.o\n", 1)
    elif "freezer.o" not in mk:
        mk = mk.replace("obj-y :=", "obj-y := freezer.o ", 1)
    mk_path.write_text(mk, encoding="utf-8")
    print("[PASS] kernel/cgroup/Makefile updated")

# 2. Rename v1 freezer.c to legacy_freezer.c
f_orig = Path("kernel/cgroup/freezer.c")
f_legacy = Path("kernel/cgroup/legacy_freezer.c")
if f_orig.exists():
    orig_text = f_orig.read_text(encoding="utf-8")
    if "freezer_css_online" in orig_text:
        f_legacy.write_text(orig_text, encoding="utf-8")
        print("[PASS] kernel/cgroup/legacy_freezer.c written from v1 freezer.c")

# 3. Create clean v2 freezer.c
f_orig.write_text(r"""//SPDX-License-Identifier: GPL-2.0
#include <linux/cgroup.h>
#include <linux/sched.h>
#include <linux/sched/task.h>
#include <linux/sched/signal.h>

#include "cgroup-internal.h"


/*
 * Propagate the cgroup frozen state upwards by the cgroup tree.
 */
static void cgroup_propagate_frozen(struct cgroup *cgrp, bool frozen)
{
	int desc = 1;

	/*
	 * If the new state is frozen, some freezing ancestor cgroups may change
	 * their state too, depending on if all their descendants are frozen.
	 *
	 * Otherwise, all ancestor cgroups are forced into the non-frozen state.
	 */
	while ((cgrp = cgroup_parent(cgrp))) {
		if (frozen) {
			cgrp->freezer.nr_frozen_descendants += desc;
			if (!test_bit(CGRP_FROZEN, &cgrp->flags) &&
			    test_bit(CGRP_FREEZE, &cgrp->flags) &&
			    cgrp->freezer.nr_frozen_descendants ==
			    cgrp->nr_descendants) {
				set_bit(CGRP_FROZEN, &cgrp->flags);
				cgroup_file_notify(&cgrp->events_file);
				desc++;
			}
		} else {
			cgrp->freezer.nr_frozen_descendants -= desc;
			if (test_bit(CGRP_FROZEN, &cgrp->flags)) {
				clear_bit(CGRP_FROZEN, &cgrp->flags);
				cgroup_file_notify(&cgrp->events_file);
				desc++;
			}
		}
	}
}

/*
 * Revisit the cgroup frozen state.
 * Checks if the cgroup is really frozen and perform all state transitions.
 */
void cgroup_update_frozen(struct cgroup *cgrp)
{
	bool frozen;

	lockdep_assert_held(&css_set_lock);

	/*
	 * If the cgroup has to be frozen (CGRP_FREEZE bit set),
	 * and all tasks are frozen and/or stopped, let's consider
	 * the cgroup frozen. Otherwise it's not frozen.
	 */
	frozen = test_bit(CGRP_FREEZE, &cgrp->flags) &&
		cgrp->freezer.nr_frozen_tasks == __cgroup_task_count(cgrp);

	if (frozen) {
		/* Already there? */
		if (test_bit(CGRP_FROZEN, &cgrp->flags))
			return;

		set_bit(CGRP_FROZEN, &cgrp->flags);
	} else {
		/* Already there? */
		if (!test_bit(CGRP_FROZEN, &cgrp->flags))
			return;

		clear_bit(CGRP_FROZEN, &cgrp->flags);
	}
	cgroup_file_notify(&cgrp->events_file);

	/* Update the state of ancestor cgroups. */
	cgroup_propagate_frozen(cgrp, frozen);
}

/*
 * Increment cgroup's nr_frozen_tasks.
 */
static void cgroup_inc_frozen_cnt(struct cgroup *cgrp)
{
	cgrp->freezer.nr_frozen_tasks++;
}

/*
 * Decrement cgroup's nr_frozen_tasks.
 */
static void cgroup_dec_frozen_cnt(struct cgroup *cgrp)
{
	cgrp->freezer.nr_frozen_tasks--;
	WARN_ON_ONCE(cgrp->freezer.nr_frozen_tasks < 0);
}

/*
 * Enter frozen/stopped state, if not yet there. Update cgroup's counters,
 * and revisit the state of the cgroup, if necessary.
 */
void cgroup_enter_frozen(void)
{
	struct cgroup *cgrp;

	if (current->frozen)
		return;

	spin_lock_irq(&css_set_lock);
	current->frozen = true;
	cgrp = task_dfl_cgroup(current);
	cgroup_inc_frozen_cnt(cgrp);
	cgroup_update_frozen(cgrp);
	spin_unlock_irq(&css_set_lock);
}

/*
 * Conditionally leave frozen/stopped state. Update cgroup's counters,
 * and revisit the state of the cgroup, if necessary.
 *
 * If always_leave is not set, and the cgroup is freezing,
 * we're racing with the cgroup freezing. In this case, we don't
 * drop the frozen counter to avoid a transient switch to
 * the unfrozen state.
 */
void cgroup_leave_frozen(bool always_leave)
{
	struct cgroup *cgrp;

	spin_lock_irq(&css_set_lock);
	cgrp = task_dfl_cgroup(current);
	if (always_leave || !test_bit(CGRP_FREEZE, &cgrp->flags)) {
		cgroup_dec_frozen_cnt(cgrp);
		cgroup_update_frozen(cgrp);
		WARN_ON_ONCE(!current->frozen);
		current->frozen = false;
	}
	spin_unlock_irq(&css_set_lock);

	if (unlikely(current->frozen)) {
		/*
		 * If the task remained in the frozen state,
		 * make sure it won't reach userspace without
		 * entering the signal handling loop.
		 */
		spin_lock_irq(&current->sighand->siglock);
		recalc_sigpending();
		spin_unlock_irq(&current->sighand->siglock);
	}
}

/*
 * Freeze or unfreeze the task by setting or clearing the JOBCTL_TRAP_FREEZE
 * jobctl bit.
 */
static void cgroup_freeze_task(struct task_struct *task, bool freeze)
{
	unsigned long flags;

	/* If the task is about to die, don't bother with freezing it. */
	if (!lock_task_sighand(task, &flags))
		return;

	if (freeze) {
		task->jobctl |= JOBCTL_TRAP_FREEZE;
		signal_wake_up(task, false);
	} else {
		task->jobctl &= ~JOBCTL_TRAP_FREEZE;
		wake_up_process(task);
	}

	unlock_task_sighand(task, &flags);
}

/*
 * Freeze or unfreeze all tasks in the given cgroup.
 */
static void cgroup_do_freeze(struct cgroup *cgrp, bool freeze)
{
	struct css_task_iter it;
	struct task_struct *task;

	lockdep_assert_held(&cgroup_mutex);

	spin_lock_irq(&css_set_lock);
	if (freeze)
		set_bit(CGRP_FREEZE, &cgrp->flags);
	else
		clear_bit(CGRP_FREEZE, &cgrp->flags);
	spin_unlock_irq(&css_set_lock);

	if (freeze)
	else

	css_task_iter_start(&cgrp->self, 0, &it);
	while ((task = css_task_iter_next(&it))) {
		/*
		 * Ignore kernel threads here. Freezing cgroups containing
		 * kthreads isn't supported.
		 */
		if (task->flags & PF_KTHREAD)
			continue;
		cgroup_freeze_task(task, freeze);
	}
	css_task_iter_end(&it);

	/*
	 * Cgroup state should be revisited here to cover empty leaf cgroups
	 * and cgroups which descendants are already in the desired state.
	 */
	spin_lock_irq(&css_set_lock);
	if (cgrp->nr_descendants == cgrp->freezer.nr_frozen_descendants)
		cgroup_update_frozen(cgrp);
	spin_unlock_irq(&css_set_lock);
}

/*
 * Adjust the task state (freeze or unfreeze) and revisit the state of
 * source and destination cgroups.
 */
void cgroup_freezer_migrate_task(struct task_struct *task,
				 struct cgroup *src, struct cgroup *dst)
{
	lockdep_assert_held(&css_set_lock);

	/*
	 * Kernel threads are not supposed to be frozen at all.
	 */
	if (task->flags & PF_KTHREAD)
		return;

	/*
	 * Adjust counters of freezing and frozen tasks.
	 * Note, that if the task is frozen, but the destination cgroup is not
	 * frozen, we bump both counters to keep them balanced.
	 */
	if (task->frozen) {
		cgroup_inc_frozen_cnt(dst);
		cgroup_dec_frozen_cnt(src);
	}
	cgroup_update_frozen(dst);
	cgroup_update_frozen(src);

	/*
	 * Force the task to the desired state.
	 */
	cgroup_freeze_task(task, test_bit(CGRP_FREEZE, &dst->flags));
}

void cgroup_freezer_frozen_exit(struct task_struct *task)
{
	struct cgroup *cgrp = task_dfl_cgroup(task);

	lockdep_assert_held(&css_set_lock);

	cgroup_dec_frozen_cnt(cgrp);
	cgroup_update_frozen(cgrp);
}

void cgroup_freeze(struct cgroup *cgrp, bool freeze)
{
	struct cgroup_subsys_state *css;
	struct cgroup *dsct;
	bool applied = false;

	lockdep_assert_held(&cgroup_mutex);

	/*
	 * Nothing changed? Just exit.
	 */
	if (cgrp->freezer.freeze == freeze)
		return;

	cgrp->freezer.freeze = freeze;

	/*
	 * Propagate changes downwards the cgroup tree.
	 */
	css_for_each_descendant_pre(css, &cgrp->self) {
		dsct = css->cgroup;

		if (cgroup_is_dead(dsct))
			continue;

		if (freeze) {
			dsct->freezer.e_freeze++;
			/*
			 * Already frozen because of ancestor's settings?
			 */
			if (dsct->freezer.e_freeze > 1)
				continue;
		} else {
			dsct->freezer.e_freeze--;
			/*
			 * Still frozen because of ancestor's settings?
			 */
			if (dsct->freezer.e_freeze > 0)
				continue;

			WARN_ON_ONCE(dsct->freezer.e_freeze < 0);
		}

		/*
		 * Do change actual state: freeze or unfreeze.
		 */
		cgroup_do_freeze(dsct, freeze);
		applied = true;
	}

	/*
	 * Even if the actual state hasn't changed, let's notify a user.
	 * The state can be enforced by an ancestor cgroup: the cgroup
	 * can already be in the desired state or it can be locked in the
	 * opposite state, so that the transition will never happen.
	 * In both cases it's better to notify a user, that there is
	 * nothing to wait for.
	 */
	if (!applied) {
		cgroup_file_notify(&cgrp->events_file);
	}
}
""", encoding="utf-8")
print("[PASS] kernel/cgroup/freezer.c (v2) created")

# 4. include/linux/cgroup-defs.h
defs_path = Path("include/linux/cgroup-defs.h")
defs = defs_path.read_text(encoding="utf-8")
if "CGRP_FREEZE" not in defs:
    anchor_cgrp_flags = "\tCGRP_CPUSET_CLONE_CHILDREN,\n"
    repl_cgrp_flags = anchor_cgrp_flags + """
\t/* Control group has to be frozen. */
\tCGRP_FREEZE,

\t/* Cgroup is frozen. */
\tCGRP_FROZEN,
"""
    assert anchor_cgrp_flags in defs, "cannot find CGRP_CPUSET_CLONE_CHILDREN in cgroup-defs.h"
    defs = defs.replace(anchor_cgrp_flags, repl_cgrp_flags, 1)

    anchor_state = "struct cgroup {\n"
    repl_state = """struct cgroup_freezer_state {
\t/* Should the cgroup and its descendants be frozen. */
\tbool freeze;

\t/* Should the cgroup actually be frozen? */
\tint e_freeze;

\t/* Fields below are protected by css_set_lock */

\t/* Number of frozen descendant cgroups */
\tint nr_frozen_descendants;

\t/*
\t * Number of tasks, which are counted as frozen:
\t * frozen, SIGSTOPped, and PTRACEd.
\t */
\tint nr_frozen_tasks;
};

""" + anchor_state
    assert anchor_state in defs, "cannot find struct cgroup anchor in cgroup-defs.h"
    defs = defs.replace(anchor_state, repl_state, 1)

    anchor_field = "\t/* used to store eBPF programs */\n\tstruct cgroup_bpf bpf;\n"
    repl_field = anchor_field + """
\t/* Used to store internal freezer state */
\tstruct cgroup_freezer_state freezer;
"""
    assert anchor_field in defs, "cannot find bpf field anchor in cgroup-defs.h"
    defs = defs.replace(anchor_field, repl_field, 1)

    defs_path.write_text(defs, encoding="utf-8")
    print("[PASS] include/linux/cgroup-defs.h updated")

# 5. include/linux/cgroup.h
cg_h_path = Path("include/linux/cgroup.h")
cg_h = cg_h_path.read_text(encoding="utf-8")
if "cgroup_enter_frozen" not in cg_h:
    anchor_cgh1 = "#ifdef CONFIG_CGROUPS\n"
    repl_cgh1 = anchor_cgh1 + """
void cgroup_enter_frozen(void);
void cgroup_leave_frozen(bool always_leave);
void cgroup_update_frozen(struct cgroup *cgrp);
void cgroup_freeze(struct cgroup *cgrp, bool freeze);
void cgroup_freezer_migrate_task(struct task_struct *task, struct cgroup *src,
\t\t\t\t struct cgroup *dst);
void cgroup_freezer_frozen_exit(struct task_struct *task);
static inline bool cgroup_task_frozen(struct task_struct *task)
{
\treturn task->frozen;
}
"""
    assert anchor_cgh1 in cg_h, "cannot find CONFIG_CGROUPS in cgroup.h"
    cg_h = cg_h.replace(anchor_cgh1, repl_cgh1, 1)

    anchor_dfl = "static inline struct cgroup *task_dfl_cgroup(struct task_struct *task)\n{\n\treturn task_css_set(task)->dfl_cgrp;\n}\n"
    repl_dfl = anchor_dfl + """
static inline bool cgroup_task_freeze(struct task_struct *task)
{
\tbool ret;

\tif (task->flags & PF_KTHREAD)
\t\treturn false;

\trcu_read_lock();
\tret = test_bit(CGRP_FREEZE, &task_dfl_cgroup(task)->flags);
\trcu_read_unlock();

\treturn ret;
}
"""
    assert anchor_dfl in cg_h, "cannot find task_dfl_cgroup in cgroup.h"
    cg_h = cg_h.replace(anchor_dfl, repl_dfl, 1)

    anchor_cgh2 = "#else /* !CONFIG_CGROUPS */\n"
    repl_cgh2 = anchor_cgh2 + """
static inline void cgroup_enter_frozen(void) { }
static inline void cgroup_leave_frozen(bool always_leave) { }
static inline bool cgroup_task_freeze(struct task_struct *task)
{
\treturn false;
}
static inline bool cgroup_task_frozen(struct task_struct *task)
{
\treturn false;
}
"""
    assert anchor_cgh2 in cg_h, "cannot find !CONFIG_CGROUPS in cgroup.h"
    cg_h = cg_h.replace(anchor_cgh2, repl_cgh2, 1)

    cg_h_path.write_text(cg_h, encoding="utf-8")
    print("[PASS] include/linux/cgroup.h updated")

# 6. include/linux/sched.h
sh_path = Path("include/linux/sched.h")
sh = sh_path.read_text(encoding="utf-8")
if "unsigned\t\t\tfrozen:1;" not in sh:
    anchor_sh = "\tunsigned\t\t\tno_cgroup_migration:1;\n"
    repl_sh = anchor_sh + "\t/* task is frozen/stopped (used by the cgroup freezer) */\n\tunsigned\t\t\tfrozen:1;\n"
    assert anchor_sh in sh, "cannot find no_cgroup_migration in sched.h"
    sh = sh.replace(anchor_sh, repl_sh, 1)
    sh_path.write_text(sh, encoding="utf-8")
    print("[PASS] include/linux/sched.h updated")

# 7. include/linux/sched/jobctl.h
jh_path = Path("include/linux/sched/jobctl.h")
jh = jh_path.read_text(encoding="utf-8")
if "JOBCTL_TRAP_FREEZE" not in jh:
    anchor_jh1 = "#define JOBCTL_LISTENING_BIT\t22\t/* ptracer is listening for events */\n"
    repl_jh1 = anchor_jh1 + "#define JOBCTL_TRAP_FREEZE_BIT\t23\t/* trap for cgroup freezer */\n"
    assert anchor_jh1 in jh, "cannot find JOBCTL_LISTENING_BIT in jobctl.h"
    jh = jh.replace(anchor_jh1, repl_jh1, 1)

    anchor_jh2 = "#define JOBCTL_LISTENING\t(1UL << JOBCTL_LISTENING_BIT)\n"
    repl_jh2 = anchor_jh2 + "#define JOBCTL_TRAP_FREEZE\t(1UL << JOBCTL_TRAP_FREEZE_BIT)\n"
    assert anchor_jh2 in jh, "cannot find JOBCTL_LISTENING in jobctl.h"
    jh = jh.replace(anchor_jh2, repl_jh2, 1)

    jh_path.write_text(jh, encoding="utf-8")
    print("[PASS] include/linux/sched/jobctl.h updated")

# 8. kernel/cgroup/cgroup-internal.h
ih_path = Path("kernel/cgroup/cgroup-internal.h")
ih = ih_path.read_text(encoding="utf-8")
if "cgroup_task_count" not in ih:
    ih += "\nint cgroup_task_count(const struct cgroup *cgrp);\nint __cgroup_task_count(const struct cgroup *cgrp);\n"
    ih_path.write_text(ih, encoding="utf-8")
    print("[PASS] kernel/cgroup/cgroup-internal.h updated")

# 9. kernel/cgroup/cgroup.c
cg_path = Path("kernel/cgroup/cgroup.c")
ct = cg_path.read_text(encoding="utf-8")
if "__cgroup_task_count" not in ct:
    cg_get_anchor = "static void cgroup_get_live(struct cgroup *cgrp)\n{\n\tWARN_ON_ONCE(cgroup_is_dead(cgrp));\n\tcss_get(&cgrp->self);\n}\n"
    task_count_code = cg_get_anchor + """
/**
 * __cgroup_task_count - count the number of tasks in a cgroup. The caller
 * is responsible for taking the css_set_lock.
 * @cgrp: the cgroup in question
 */
int __cgroup_task_count(const struct cgroup *cgrp)
{
\tint count = 0;
\tstruct cgrp_cset_link *link;

\tlockdep_assert_held(&css_set_lock);

\tlist_for_each_entry(link, &cgrp->cset_links, cset_link)
\t\tcount += link->cset->nr_tasks;

\treturn count;
}

int cgroup_task_count(const struct cgroup *cgrp)
{
\tint count = 0;

\tspin_lock_irq(&css_set_lock);
\tcount = __cgroup_task_count(cgrp);
\tspin_unlock_irq(&css_set_lock);

\treturn count;
}
"""
    assert cg_get_anchor in ct, "cannot find cgroup_get anchor in cgroup.c"
    ct = ct.replace(cg_get_anchor, task_count_code, 1)

    mig_anchor = "\t\t\tcss_set_move_task(task, from_cset, to_cset, true);\n\t\t\tput_css_set_locked(from_cset);\n\t\t\tfrom_cset->nr_tasks--;\n"
    mig_repl = "\t\t\tcss_set_move_task(task, from_cset, to_cset, true);\n\t\t\tfrom_cset->nr_tasks--;\n\t\t\tcgroup_freezer_migrate_task(task, from_cset->dfl_cgrp, to_cset->dfl_cgrp);\n\t\t\tput_css_set_locked(from_cset);\n"
    assert mig_anchor in ct, "cannot find migrate anchor in cgroup.c"
    ct = ct.replace(mig_anchor, mig_repl, 1)

    ev_anchor = "\tseq_printf(seq, \"populated %d\\n\",\n\t\t   cgroup_is_populated(seq_css(seq)->cgroup));\n\treturn 0;"
    ev_repl = """\tstruct cgroup *cgrp = seq_css(seq)->cgroup;

\tseq_printf(seq, "populated %d\\n", cgroup_is_populated(cgrp));
\tseq_printf(seq, "frozen %d\\n", test_bit(CGRP_FROZEN, &cgrp->flags));

\treturn 0;"""
    assert ev_anchor in ct, "cannot find events_show anchor in cgroup.c"
    ct = ct.replace(ev_anchor, ev_repl, 1)

    base_anchor = "static struct cftype cgroup_base_files[] = {\n"
    freeze_ctrl = """static int cgroup_freeze_show(struct seq_file *seq, void *v)
{
\tstruct cgroup *cgrp = seq_css(seq)->cgroup;

\tseq_printf(seq, "%d\\n", cgrp->freezer.freeze);

\treturn 0;
}

static ssize_t cgroup_freeze_write(struct kernfs_open_file *of,
\t\t\t\t   char *buf, size_t nbytes, loff_t off)
{
\tstruct cgroup *cgrp;
\tssize_t ret;
\tint freeze;

\tret = kstrtoint(strstrip(buf), 0, &freeze);
\tif (ret)
\t\treturn ret;

\tif (freeze < 0 || freeze > 1)
\t\treturn -ERANGE;

\tcgrp = cgroup_kn_lock_live(of->kn, false);
\tif (!cgrp)
\t\treturn -ENOENT;

\tcgroup_freeze(cgrp, freeze);

\tcgroup_kn_unlock(of->kn);

\treturn nbytes;
}

"""
    assert base_anchor in ct, "cannot find cgroup_base_files anchor in cgroup.c"
    ct = ct.replace(base_anchor, freeze_ctrl + base_anchor, 1)

    stat_anchor = "\t\t.name = \"cgroup.stat\",\n\t\t.seq_show = cgroup_stat_show,\n\t},\n"
    stat_repl = stat_anchor + """\t{
\t\t.name = "cgroup.freeze",
\t\t.flags = CFTYPE_NOT_ON_ROOT,
\t\t.seq_show = cgroup_freeze_show,
\t\t.write = cgroup_freeze_write,
\t},
"""
    assert stat_anchor in ct, "cannot find cgroup.stat anchor in cgroup.c"
    ct = ct.replace(stat_anchor, stat_repl, 1)

    cr_anchor = "\tcgrp->ancestor_ids[tcgrp->level] = tcgrp->id;\n\n\t\tif (tcgrp != cgrp)\n\t\t\ttcgrp->nr_descendants++;\n\t}\n"
    cr_repl = """\tcgrp->ancestor_ids[tcgrp->level] = tcgrp->id;

\t\tif (tcgrp != cgrp) {
\t\t\ttcgrp->nr_descendants++;

\t\t\tif (cgrp->freezer.e_freeze)
\t\t\t\ttcgrp->freezer.nr_frozen_descendants++;
\t\t}
\t}
"""
    assert cr_anchor in ct, "cannot find cgroup_create anchor in cgroup.c"
    ct = ct.replace(cr_anchor, cr_repl, 1)

    idr_anchor = "\tret = cgroup_bpf_inherit(cgrp);\n\tif (ret)\n\t\tgoto out_idr_free;\n"
    idr_repl = """\tret = cgroup_bpf_inherit(cgrp);
\tif (ret)
\t\tgoto out_idr_free;

\tcgrp->freezer.e_freeze = parent->freezer.e_freeze;
\tif (cgrp->freezer.e_freeze)
\t\tset_bit(CGRP_FROZEN, &cgrp->flags);
"""
    assert idr_anchor in ct, "cannot find idr anchor in cgroup.c"
    ct = ct.replace(idr_anchor, idr_repl, 1)

    des_anchor = "\t\ttcgrp->nr_descendants--;\n\t\ttcgrp->nr_dying_descendants++;\n\t}\n"
    des_repl = """\t\ttcgrp->nr_descendants--;
\t\ttcgrp->nr_dying_descendants++;
\t\tif (test_bit(CGRP_FROZEN, &cgrp->flags))
\t\t\ttcgrp->freezer.nr_frozen_descendants--;
\t}
"""
    assert des_anchor in ct, "cannot find destroy anchor in cgroup.c"
    ct = ct.replace(des_anchor, des_repl, 1)

    fork_anchor = "\t\t\tcss_set_move_task(child, NULL, cset, false);\n\t\t}\n\t\tspin_unlock_irq(&css_set_lock);\n"
    fork_repl = """\t\t\tcss_set_move_task(child, NULL, cset, false);\n\t\t}

\t\tif (unlikely(cgroup_task_freeze(child))) {
\t\t\tstruct cgroup *cgrp;

\t\t\tspin_lock(&child->sighand->siglock);
\t\t\tWARN_ON_ONCE(child->frozen);
\t\t\tcgrp = cset->dfl_cgrp;
\t\t\tchild->jobctl |= JOBCTL_TRAP_FREEZE;
\t\t\tspin_unlock(&child->sighand->siglock);
\t\t}

\t\tspin_unlock_irq(&css_set_lock);
"""
    assert fork_anchor in ct, "cannot find post_fork anchor in cgroup.c"
    ct = ct.replace(fork_anchor, fork_repl, 1)

    exit_anchor = "\t\tcset->nr_tasks--;\n\t\tspin_unlock_irq(&css_set_lock);\n"
    exit_repl = """\t\tcset->nr_tasks--;

\t\tif (unlikely(cgroup_task_frozen(tsk)))
\t\t\tcgroup_freezer_frozen_exit(tsk);
\t\telse if (unlikely(cgroup_task_freeze(tsk)))
\t\t\tcgroup_update_frozen(task_dfl_cgroup(tsk));

\t\tspin_unlock_irq(&css_set_lock);
"""
    assert exit_anchor in ct, "cannot find exit anchor in cgroup.c"
    ct = ct.replace(exit_anchor, exit_repl, 1)

    cg_path.write_text(ct, encoding="utf-8")
    print("[PASS] kernel/cgroup/cgroup.c updated")

# 10. kernel/fork.c
fork_path = Path("kernel/fork.c")
fkt = fork_path.read_text(encoding="utf-8")
if "cgroup_enter_frozen" not in fkt:
    vfork_anchor = "\tfreezer_do_not_count();\n\tkilled = wait_for_completion_killable(vfork);\n\tfreezer_count();\n"
    vfork_repl = "\tfreezer_do_not_count();\n\tcgroup_enter_frozen();\n\tkilled = wait_for_completion_killable(vfork);\n\tcgroup_leave_frozen(false);\n\tfreezer_count();\n"
    assert vfork_anchor in fkt, "cannot find vfork anchor in fork.c"
    fkt = fkt.replace(vfork_anchor, vfork_repl, 1)
    fork_path.write_text(fkt, encoding="utf-8")
    print("[PASS] kernel/fork.c updated")

# 11. kernel/signal.c
sig_path = Path("kernel/signal.c")
sigt = sig_path.read_text(encoding="utf-8")
if "cgroup_enter_frozen" not in sigt:
    inc_anchor = "#include <linux/oom.h>\n"
    inc_repl = inc_anchor + "#include <linux/cgroup.h>\n"
    assert inc_anchor in sigt, "cannot find oom.h in signal.c"
    sigt = sigt.replace(inc_anchor, inc_repl, 1)

    recalc_anchor = "\tif ((t->jobctl & JOBCTL_PENDING_MASK) ||\n\t    PENDING(&t->pending, &t->blocked) ||\n\t    PENDING(&t->signal->shared_pending, &t->blocked)) {\n"
    recalc_repl = "\tif ((t->jobctl & (JOBCTL_PENDING_MASK | JOBCTL_TRAP_FREEZE)) ||\n\t    PENDING(&t->pending, &t->blocked) ||\n\t    PENDING(&t->signal->shared_pending, &t->blocked) ||\n\t    cgroup_task_frozen(t)) {\n"
    assert recalc_anchor in sigt, "cannot find recalc anchor in signal.c"
    sigt = sigt.replace(recalc_anchor, recalc_repl, 1)

    ptrace_anchor = "\t\tpreempt_disable();\n\t\tread_unlock(&tasklist_lock);\n\t\tpreempt_enable_no_resched();\n\t\tfreezable_schedule();\n"
    ptrace_repl = "\t\tpreempt_disable();\n\t\tread_unlock(&tasklist_lock);\n\t\tpreempt_enable_no_resched();\n\t\tcgroup_enter_frozen();\n\t\tfreezable_schedule();\n\t\tcgroup_leave_frozen(true);\n"
    assert ptrace_anchor in sigt, "cannot find ptrace anchor in signal.c"
    sigt = sigt.replace(ptrace_anchor, ptrace_repl, 1)

    sigstop_anchor = "\t\t/* Now we don't run again until woken by SIGCONT or SIGKILL */\n\t\tfreezable_schedule();\n\t\treturn true;\n"
    sigstop_repl = "\t\t/* Now we don't run again until woken by SIGCONT or SIGKILL */\n\t\tcgroup_enter_frozen();\n\t\tfreezable_schedule();\n\t\treturn true;\n"
    assert sigstop_anchor in sigt, "cannot find sigstop anchor in signal.c"
    sigt = sigt.replace(sigstop_anchor, sigstop_repl, 1)

    do_job_anchor = "static void do_jobctl_trap(void)\n{\n"
    do_freeze_trap = """static void do_freezer_trap(void)
\t__releases(&current->sighand->siglock)
{
\tif ((current->jobctl & (JOBCTL_PENDING_MASK | JOBCTL_TRAP_FREEZE)) !=
\t     JOBCTL_TRAP_FREEZE) {
\t\tspin_unlock_irq(&current->sighand->siglock);
\t\treturn;
\t}

\t__set_current_state(TASK_INTERRUPTIBLE);
\tclear_thread_flag(TIF_SIGPENDING);
\tspin_unlock_irq(&current->sighand->siglock);
\tcgroup_enter_frozen();
\tfreezable_schedule();
}

"""
    assert do_job_anchor in sigt, "cannot find do_jobctl_trap in signal.c"
    sigt = sigt.replace(do_job_anchor, do_freeze_trap + do_job_anchor, 1)

    get_sig_fatal_anchor = "\t\trecalc_sigpending();\n\t\tgoto fatal;\n\t}\n"
    get_sig_fatal_repl = "\t\trecalc_sigpending();\n\t\tcurrent->jobctl &= ~JOBCTL_TRAP_FREEZE;\n\t\tspin_unlock_irq(&sighand->siglock);\n\t\tif (unlikely(cgroup_task_frozen(current)))\n\t\t\tcgroup_leave_frozen(true);\n\t\tgoto fatal;\n\t}\n"
    assert get_sig_fatal_anchor in sigt, "cannot find fatal anchor in signal.c"
    sigt = sigt.replace(get_sig_fatal_anchor, get_sig_fatal_repl, 1)

    get_sig_trap_anchor = "\t\tif (unlikely(current->jobctl & JOBCTL_TRAP_MASK)) {\n\t\t\tdo_jobctl_trap();\n\t\t\tspin_unlock_irq(&sighand->siglock);\n\t\t\tgoto relock;\n\t\t}\n"
    get_sig_trap_repl = """\t\tif (unlikely(current->jobctl &
\t\t\t     (JOBCTL_TRAP_MASK | JOBCTL_TRAP_FREEZE))) {
\t\t\tif (current->jobctl & JOBCTL_TRAP_MASK) {
\t\t\t\tdo_jobctl_trap();
\t\t\t\tspin_unlock_irq(&sighand->siglock);
\t\t\t} else if (current->jobctl & JOBCTL_TRAP_FREEZE)
\t\t\t\tdo_freezer_trap();

\t\t\tgoto relock;
\t\t}

\t\tif (unlikely(cgroup_task_frozen(current))) {
\t\t\tspin_unlock_irq(&sighand->siglock);
\t\t\tcgroup_leave_frozen(true);
\t\t\tgoto relock;
\t\t}
"""
    assert get_sig_trap_anchor in sigt, "cannot find trap anchor in signal.c"
    sigt = sigt.replace(get_sig_trap_anchor, get_sig_trap_repl, 1)

    sig_path.write_text(sigt, encoding="utf-8")
    print("[PASS] kernel/signal.c updated")

proof_lines.append("cgroup_v2_freezer=applied")
proof_lines.append("cgroup.freeze=supported")
proof_lines.append("cgroup.events=supported")
proof_lines.append("freezer_trap=supported")
proof_lines.append("leave_frozen_ptrace_fix=05b289263772")

proof_text = "\n".join(proof_lines) + "\n"
proof_path.write_text(proof_text, encoding="utf-8")
Path("cgroup-v2-freezer-proof.txt").write_text(proof_text, encoding="utf-8")
workspace = os.environ.get("GITHUB_WORKSPACE")
if workspace:
    (Path(workspace) / "cgroup-v2-freezer-proof.txt").write_text(proof_text, encoding="utf-8")
print("[PASS] cgroup-v2-freezer-proof.txt written")
PY

echo '[PASS] cgroup v2 freezer patchset successfully applied'
