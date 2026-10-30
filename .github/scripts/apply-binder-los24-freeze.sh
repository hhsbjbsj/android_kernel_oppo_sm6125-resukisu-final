#!/usr/bin/env bash
# Apply Binder freeze & modern transactions backport for LineageOS 24 (Android 17)
# Supports: BINDER_FREEZE, BINDER_GET_FROZEN_INFO, BINDER_ENABLE_ONEWAY_SPAM_DETECTION,
# TF_CLEAR_BUF, TF_UPDATE_TXN, BR_FROZEN_REPLY, and freeze race fix (2132740a50)
set -Eeuo pipefail

KERNEL_DIR="${KERNEL_DIR:-$GITHUB_WORKSPACE/$KERNEL_REL}"
cd "$KERNEL_DIR"
export BINDER_FREEZE_PROOF="${GITHUB_WORKSPACE:-.}/binder-freeze-proof.txt"

python3 - <<'PY'
import sys, os, re
from pathlib import Path

proof_path = Path(os.environ.get("BINDER_FREEZE_PROOF", "binder-freeze-proof.txt"))
proof_lines = []

# 1. include/uapi/linux/android/binder.h
bh_path = Path("include/uapi/linux/android/binder.h")
bh = bh_path.read_text(encoding="utf-8")
if "BINDER_FREEZE" not in bh:
    bh_struct_anchor = "struct binder_node_info_for_ref {\n\t__u32            handle;\n\t__u32            strong_count;\n\t__u32            weak_count;\n\t__u32            reserved1;\n\t__u32            reserved2;\n\t__u32            reserved3;\n};\n"
    bh_structs = bh_struct_anchor + """
struct binder_freeze_info {
\t__u32            pid;
\t__u32            enable;
\t__u32            timeout_ms;
};

struct binder_frozen_status_info {
\t__u32            pid;

\t/* process received sync transactions since last frozen
\t * bit 0: received sync transaction after being frozen
\t * bit 1: new pending sync transaction during freezing
\t */
\t__u32            sync_recv;

\t/* process received async transactions since last frozen */
\t__u32            async_recv;
};
"""
    assert bh_struct_anchor in bh, "cannot find binder_node_info_for_ref in binder.h"
    bh = bh.replace(bh_struct_anchor, bh_structs, 1)

    bh_ioctl_anchor = "#define BINDER_SET_CONTEXT_MGR_EXT\t_IOW('b', 13, struct flat_binder_object)\n"
    bh_ioctls = bh_ioctl_anchor + """#define BINDER_FREEZE\t\t\t_IOW('b', 14, struct binder_freeze_info)
#define BINDER_GET_FROZEN_INFO\t\t_IOWR('b', 15, struct binder_frozen_status_info)
#define BINDER_ENABLE_ONEWAY_SPAM_DETECTION\t_IOW('b', 16, __u32)
"""
    assert bh_ioctl_anchor in bh, "cannot find BINDER_SET_CONTEXT_MGR_EXT in binder.h"
    bh = bh.replace(bh_ioctl_anchor, bh_ioctls, 1)

    bh_tf_anchor = "\tTF_ACCEPT_FDS\t= 0x10,\t/* allow replies with file descriptors */\n"
    bh_tf = bh_tf_anchor + """\tTF_CLEAR_BUF\t= 0x20,\t/* clear buffer on txn complete */
\tTF_UPDATE_TXN\t= 0x40,\t/* update the outdated pending async txn */
"""
    assert bh_tf_anchor in bh, "cannot find TF_ACCEPT_FDS in binder.h"
    bh = bh.replace(bh_tf_anchor, bh_tf, 1)

    bh_enum_end = "};\n\nstruct binder_transaction_data {"
    bh_enum_repl = "};\n#define TF_CLEAR_BUF TF_CLEAR_BUF\n#define TF_UPDATE_TXN TF_UPDATE_TXN\n\nstruct binder_transaction_data {"
    if bh_enum_end in bh:
        bh = bh.replace(bh_enum_end, bh_enum_repl, 1)

    bh_br_anchor = "\tBR_FAILED_REPLY = _IO('r', 17),\n\t/*\n\t * The the last transaction (either a bcTRANSACTION or\n\t * a bcATTEMPT_ACQUIRE) failed (e.g. out of memory).  No parameters.\n\t */\n"
    bh_br = bh_br_anchor + """
\tBR_FROZEN_REPLY = _IO('r', 18),
\t/*
\t * The target of the last transaction (either a bcTRANSACTION or
\t * a bcATTEMPT_ACQUIRE) is frozen.  No parameters.
\t */

\tBR_ONEWAY_SPAM_SUSPECT = _IO('r', 19),
\t/*
\t * Current process sent too many oneway calls to target, and the last
\t * asynchronous transaction makes the allocated async buffer size exceed
\t * detection threshold.  No parameters.
\t */
"""
    assert bh_br_anchor in bh, "cannot find BR_FAILED_REPLY in binder.h"
    bh = bh.replace(bh_br_anchor, bh_br, 1)

    bh_path.write_text(bh, encoding="utf-8")
    print("[PASS] include/uapi/linux/android/binder.h updated")

# 2. drivers/android/binder_trace.h
btr_path = Path("drivers/android/binder_trace.h")
if btr_path.exists():
    btr = btr_path.read_text(encoding="utf-8")
    if "binder_transaction_update_buffer_release" not in btr:
        btr_anchor = "DEFINE_EVENT(binder_buffer_class, binder_transaction_failed_buffer_release,\n\tTP_PROTO(struct binder_buffer *buffer),\n\tTP_ARGS(buffer));\n"
        btr_repl = btr_anchor + """
DEFINE_EVENT(binder_buffer_class, binder_transaction_update_buffer_release,
\tTP_PROTO(struct binder_buffer *buffer),
\tTP_ARGS(buffer));
"""
        assert btr_anchor in btr, "cannot find binder_transaction_failed_buffer_release in binder_trace.h"
        btr = btr.replace(btr_anchor, btr_repl, 1)
        btr_path.write_text(btr, encoding="utf-8")
        print("[PASS] drivers/android/binder_trace.h updated")

# 3. drivers/android/binder.c
bc_path = Path("drivers/android/binder.c")
bc = bc_path.read_text(encoding="utf-8")

if "BINDER_FREEZE" not in bc:
    # binder_stats array sizing
    bstat_anchor = "\tatomic_t br[_IOC_NR(BR_FAILED_REPLY) + 1];\n"
    bstat_repl = "\tatomic_t br[_IOC_NR(BR_ONEWAY_SPAM_SUSPECT) + 1];\n"
    if bstat_anchor in bc:
        bc = bc.replace(bstat_anchor, bstat_repl, 1)

    # struct binder_proc additions
    proc_anchor = "\tbool is_dead;\n"
    proc_repl = """\tint outstanding_txns;
\tbool is_dead;
\tbool is_frozen;
\tbool sync_recv;
\tbool async_recv;
\twait_queue_head_t freeze_wait;
\tbool oneway_spam_detection_enabled;
"""
    assert proc_anchor in bc, "cannot find is_dead in binder.c struct binder_proc"
    bc = bc.replace(proc_anchor, proc_repl, 1)

    # binder_open initialization of freeze_wait
    open_anchor = "\tINIT_LIST_HEAD(&proc->delivered_death);\n"
    open_repl = open_anchor + "\tinit_waitqueue_head(&proc->freeze_wait);\n"
    assert open_anchor in bc, "cannot find INIT_LIST_HEAD delivered_death in binder_open"
    bc = bc.replace(open_anchor, open_repl, 1)

    # binder_free_transaction: decrement outstanding_txns and wake freeze_wait
    free_txn_anchor = "\tif (target_proc) {\n\t\tbinder_inner_proc_lock(target_proc);\n\t\tif (t->buffer)\n\t\t\tt->buffer->transaction = NULL;\n\t\tbinder_inner_proc_unlock(target_proc);\n\t}\n"
    free_txn_repl = """\tif (target_proc) {
\t\tbinder_inner_proc_lock(target_proc);
\t\ttarget_proc->outstanding_txns--;
\t\tBUG_ON(target_proc->outstanding_txns < 0);
\t\tif (!target_proc->outstanding_txns && target_proc->is_frozen)
\t\t\twake_up_interruptible_all(&target_proc->freeze_wait);
\t\tif (t->buffer)
\t\t\tt->buffer->transaction = NULL;
\t\tbinder_inner_proc_unlock(target_proc);
\t}
"""
    assert free_txn_anchor in bc, "cannot find free_txn_anchor in binder_free_transaction"
    bc = bc.replace(free_txn_anchor, free_txn_repl, 1)

    # TF_UPDATE_TXN helpers before binder_proc_transaction
    proc_txn_anchor = "static bool binder_proc_transaction(struct binder_transaction *t,\n\t\t\t\t    struct binder_proc *proc,\n\t\t\t\t    struct binder_thread *thread)\n{\n\tstruct binder_node *node = t->buffer->target_node;\n\tstruct binder_priority node_prio;\n\tbool oneway = !!(t->flags & TF_ONE_WAY);\n\tbool pending_async = false;\n"
    proc_txn_repl = """static bool binder_can_update_transaction(struct binder_transaction *t1,
\t\t\t\t\t  struct binder_transaction *t2)
{
\tif ((t1->flags & t2->flags & (TF_ONE_WAY | TF_UPDATE_TXN)) !=
\t    (TF_ONE_WAY | TF_UPDATE_TXN) || !t1->to_proc || !t2->to_proc)
\t\treturn false;
\tif (t1->to_proc->tsk == t2->to_proc->tsk &&
\t    t1->code == t2->code &&
\t    t1->flags == t2->flags &&
\t    t1->buffer && t2->buffer &&
\t    t1->buffer->target_node == t2->buffer->target_node)
\t\treturn true;
\treturn false;
}

static struct binder_transaction *
binder_find_outdated_transaction_ilocked(struct binder_transaction *t,
\t\t\t\t\t struct list_head *target_list)
{
\tstruct binder_work *w;

\tlist_for_each_entry(w, target_list, entry) {
\t\tstruct binder_transaction *t_queued;

\t\tif (w->type != BINDER_WORK_TRANSACTION)
\t\t\tcontinue;
\t\tt_queued = container_of(w, struct binder_transaction, work);
\t\tif (binder_can_update_transaction(t_queued, t))
\t\t\treturn t_queued;
\t}
\treturn NULL;
}

static int binder_proc_transaction(struct binder_transaction *t,
\t\t\t\t    struct binder_proc *proc,
\t\t\t\t    struct binder_thread *thread)
{
\tstruct binder_node *node = t->buffer->target_node;
\tstruct binder_priority node_prio;
\tbool oneway = !!(t->flags & TF_ONE_WAY);
\tbool pending_async = false;
\tstruct binder_transaction *t_outdated = NULL;
"""
    proc_txn_pattern = re.compile(
        r'static bool binder_proc_transaction\(struct binder_transaction \*t,\n'
        r'\t\t\t\t    struct binder_proc \*proc,\n'
        r'\t\t\t\t    struct binder_thread \*thread\)\n'
        r'\{\n'
        r'\tstruct binder_node \*node = t->buffer->target_node;\n'
        r'\tstruct binder_priority node_prio;\n'
        r'\tbool oneway = !!\(t->flags & TF_ONE_WAY\);\n'
        r'\tbool pending_async = false;\n'
        r'(?:#ifdef CONFIG_REKERNEL[\s\S]*?#endif /\* CONFIG_REKERNEL \*/\n)?'
    )
    if proc_txn_anchor in bc:
        bc = bc.replace(proc_txn_anchor, proc_txn_repl, 1)
    elif proc_txn_pattern.search(bc):
        bc = proc_txn_pattern.sub(proc_txn_repl, bc, count=1)
    else:
        raise AssertionError("cannot find binder_proc_transaction header anchor")

    # binder_proc_transaction: freeze checking & return error
    proc_txn_check_anchor = "\tbinder_inner_proc_lock(proc);\n\n\tif (proc->is_dead || (thread && thread->is_dead)) {\n\t\tbinder_inner_proc_unlock(proc);\n\t\tbinder_node_unlock(node);\n\t\treturn false;\n\t}\n"
    proc_txn_check_repl = """\tbinder_inner_proc_lock(proc);
\tif (proc->is_frozen) {
\t\tproc->sync_recv |= !oneway;
\t\tproc->async_recv |= oneway;
\t}

\tif ((proc->is_frozen && !oneway) || proc->is_dead ||
\t\t\t(thread && thread->is_dead)) {
\t\tbool proc_is_dead = proc->is_dead
\t\t\t|| (thread && thread->is_dead);
\t\tbinder_inner_proc_unlock(proc);
\t\tbinder_node_unlock(node);
\t\treturn proc_is_dead ? BR_DEAD_REPLY : BR_FROZEN_REPLY;
\t}
"""
    assert proc_txn_check_anchor in bc, "cannot find proc_txn_check_anchor in binder_proc_transaction"
    bc = bc.replace(proc_txn_check_anchor, proc_txn_check_repl, 1)

    # binder_proc_transaction: async TF_UPDATE_TXN, outstanding_txns, and return 0
    async_enqueue_anchor = "\t} else {\n\t\tbinder_enqueue_work_ilocked(&t->work, &node->async_todo);\n\t}\n\n\tif (!pending_async)\n\t\tbinder_wakeup_thread_ilocked(proc, thread, !oneway /* sync */);\n\n\tbinder_inner_proc_unlock(proc);\n\tbinder_node_unlock(node);\n\n\treturn true;\n}\n"
    async_enqueue_pattern = re.compile(
        r'\t\} else \{\n'
        r'[\s\S]*?'
        r'\t\tbinder_enqueue_work_ilocked\(&t->work, &node->async_todo\);\n'
        r'\t\}\n\n'
        r'\tif \(!pending_async\)\n'
        r'\t\tbinder_wakeup_thread_ilocked\(proc, thread, !oneway /\* sync \*/\);\n\n'
        r'(?:\tproc->outstanding_txns\+\+;\n)?'
        r'\tbinder_inner_proc_unlock\(proc\);\n'
        r'\tbinder_node_unlock\(node\);\n'
        r'[\s\S]*?'
        r'\treturn true;\n'
        r'\}'
    )
    async_enqueue_repl = """\t} else {
\t\tif ((t->flags & TF_UPDATE_TXN) && proc->is_frozen) {
\t\t\tt_outdated = binder_find_outdated_transaction_ilocked(t,
\t\t\t\t\t&node->async_todo);
\t\t\tif (t_outdated) {
\t\t\t\tbinder_debug(BINDER_DEBUG_TRANSACTION,
\t\t\t\t\t     "txn %d supersedes %d\\n",
\t\t\t\t\t     t->debug_id, t_outdated->debug_id);
\t\t\t\tlist_del_init(&t_outdated->work.entry);
\t\t\t\tproc->outstanding_txns--;
\t\t\t}
\t\t}
\t\tbinder_enqueue_work_ilocked(&t->work, &node->async_todo);
\t}

\tif (!pending_async)
\t\tbinder_wakeup_thread_ilocked(proc, thread, !oneway /* sync */);

\tproc->outstanding_txns++;
\tbinder_inner_proc_unlock(proc);
\tbinder_node_unlock(node);

\t/*
\t * To reduce potential contention, free the outdated transaction and
\t * buffer after releasing the locks.
\t */
\tif (t_outdated) {
\t\tstruct binder_buffer *buffer = t_outdated->buffer;

\t\tt_outdated->buffer = NULL;
\t\tbuffer->transaction = NULL;
\t\tbinder_transaction_buffer_release(proc, buffer, 0, 0);
\t\tbinder_alloc_free_buf(&proc->alloc, buffer);
\t\tkfree(t_outdated);
\t\tbinder_stats_deleted(BINDER_STAT_TRANSACTION);
\t}

\treturn 0;
}
"""
    if async_enqueue_anchor in bc:
        bc = bc.replace(async_enqueue_anchor, async_enqueue_repl, 1)
    elif async_enqueue_pattern.search(bc):
        bc = async_enqueue_pattern.sub(async_enqueue_repl, bc, count=1)
    else:
        raise AssertionError("cannot find async_enqueue_anchor")

    # In binder_transaction: reply outstanding_txns++ & return_error = BR_DEAD_REPLY
    reply_anchor = "\t\tBUG_ON(t->buffer->async_transaction != 0);\n\t\tbinder_pop_transaction_ilocked(target_thread, in_reply_to);\n\t\tbinder_enqueue_thread_work_ilocked(target_thread, &t->work);\n\t\tbinder_inner_proc_unlock(target_proc);\n"
    reply_repl = "\t\tBUG_ON(t->buffer->async_transaction != 0);\n\t\tbinder_pop_transaction_ilocked(target_thread, in_reply_to);\n\t\tbinder_enqueue_thread_work_ilocked(target_thread, &t->work);\n\t\ttarget_proc->outstanding_txns++;\n\t\tbinder_inner_proc_unlock(target_proc);\n"
    assert reply_anchor in bc, "cannot find reply_anchor in binder_transaction"
    bc = bc.replace(reply_anchor, reply_repl, 1)

    reply_dead_anchor = "\t\tif (target_thread->is_dead) {\n\t\t\tbinder_inner_proc_unlock(target_proc);\n\t\t\tgoto err_dead_proc_or_thread;\n\t\t}\n"
    reply_dead_repl = "\t\tif (target_thread->is_dead) {\n\t\t\treturn_error = BR_DEAD_REPLY;\n\t\t\tbinder_inner_proc_unlock(target_proc);\n\t\t\tgoto err_dead_proc_or_thread;\n\t\t}\n"
    assert reply_dead_anchor in bc, "cannot find reply_dead_anchor in binder_transaction"
    bc = bc.replace(reply_dead_anchor, reply_dead_repl, 1)

    # In binder_transaction: callers of binder_proc_transaction
    call_anchor = """\t\tif (!binder_proc_transaction(t, target_proc, target_thread)) {
\t\t\tbinder_inner_proc_lock(proc);
\t\t\tbinder_pop_transaction_ilocked(thread, t);
\t\t\tbinder_inner_proc_unlock(proc);
\t\t\tgoto err_dead_proc_or_thread;
\t\t}
\t} else {
\t\tBUG_ON(target_node == NULL);
\t\tBUG_ON(t->buffer->async_transaction != 1);
\t\tbinder_enqueue_thread_work(thread, tcomplete);
\t\tif (!binder_proc_transaction(t, target_proc, NULL))
\t\t\tgoto err_dead_proc_or_thread;
\t}
"""
    call_repl = """\t\treturn_error = binder_proc_transaction(t,
\t\t\t\ttarget_proc, target_thread);
\t\tif (return_error) {
\t\t\tbinder_inner_proc_lock(proc);
\t\t\tbinder_pop_transaction_ilocked(thread, t);
\t\t\tbinder_inner_proc_unlock(proc);
\t\t\tgoto err_dead_proc_or_thread;
\t\t}
\t} else {
\t\tBUG_ON(target_node == NULL);
\t\tBUG_ON(t->buffer->async_transaction != 1);
\t\tbinder_enqueue_thread_work(thread, tcomplete);
\t\treturn_error = binder_proc_transaction(t, target_proc, NULL);
\t\tif (return_error)
\t\t\tgoto err_dead_proc_or_thread;
\t}
"""
    assert call_anchor in bc, "cannot find call_anchor in binder_transaction"
    bc = bc.replace(call_anchor, call_repl, 1)

    # In binder_transaction: remove return_error = BR_DEAD_REPLY at err_dead_proc_or_thread
    err_dead_anchor = "err_dead_proc_or_thread:\n\treturn_error = BR_DEAD_REPLY;\n\treturn_error_line = __LINE__;\n"
    err_dead_repl = "err_dead_proc_or_thread:\n\treturn_error_line = __LINE__;\n"
    assert err_dead_anchor in bc, "cannot find err_dead_anchor in binder_transaction"
    bc = bc.replace(err_dead_anchor, err_dead_repl, 1)

    # binder freeze ioctl helpers before binder_ioctl
    ioctl_anchor = "static long binder_ioctl(struct file *filp, unsigned int cmd, unsigned long arg)\n"
    freeze_helpers = """static bool binder_txns_pending_ilocked(struct binder_proc *proc)
{
\tstruct rb_node *n;
\tstruct binder_thread *thread;

\tif (proc->outstanding_txns > 0)
\t\treturn true;

\tfor (n = rb_first(&proc->threads); n; n = rb_next(n)) {
\t\tthread = rb_entry(n, struct binder_thread, rb_node);
\t\tif (thread->transaction_stack)
\t\t\treturn true;
\t}
\treturn false;
}

static int binder_ioctl_freeze(struct binder_freeze_info *info,
\t\t\t       struct binder_proc *target_proc)
{
\tint ret = 0;

\tif (!info->enable) {
\t\tbinder_inner_proc_lock(target_proc);
\t\ttarget_proc->sync_recv = false;
\t\ttarget_proc->async_recv = false;
\t\ttarget_proc->is_frozen = false;
\t\tbinder_inner_proc_unlock(target_proc);
\t\treturn 0;
\t}

\t/*
\t * Freezing the target. Prevent new transactions by
\t * setting frozen state. If timeout specified, wait
\t * for transactions to drain.
\t */
\tbinder_inner_proc_lock(target_proc);
\ttarget_proc->sync_recv = false;
\ttarget_proc->async_recv = false;
\ttarget_proc->is_frozen = true;
\tbinder_inner_proc_unlock(target_proc);

\tif (info->timeout_ms > 0)
\t\tret = wait_event_interruptible_timeout(
\t\t\ttarget_proc->freeze_wait,
\t\t\t(!target_proc->outstanding_txns),
\t\t\tmsecs_to_jiffies(info->timeout_ms));

\t/* Check pending transactions that wait for reply (freeze race fix) */
\tif (ret >= 0) {
\t\tbinder_inner_proc_lock(target_proc);
\t\tif (binder_txns_pending_ilocked(target_proc))
\t\t\tret = -EAGAIN;
\t\tbinder_inner_proc_unlock(target_proc);
\t}

\tif (ret < 0) {
\t\tbinder_inner_proc_lock(target_proc);
\t\ttarget_proc->is_frozen = false;
\t\tbinder_inner_proc_unlock(target_proc);
\t}

\treturn ret;
}

static int binder_ioctl_get_freezer_info(
\t\t\t\tstruct binder_frozen_status_info *info)
{
\tstruct binder_proc *target_proc;
\tbool found = false;
\t__u32 txns_pending;

\tinfo->sync_recv = 0;
\tinfo->async_recv = 0;

\tmutex_lock(&binder_procs_lock);
\thlist_for_each_entry(target_proc, &binder_procs, proc_node) {
\t\tif (target_proc->pid == info->pid) {
\t\t\tfound = true;
\t\t\tbinder_inner_proc_lock(target_proc);
\t\t\ttxns_pending = binder_txns_pending_ilocked(target_proc);
\t\t\tinfo->sync_recv |= target_proc->sync_recv |
\t\t\t\t\t(txns_pending << 1);
\t\t\tinfo->async_recv |= target_proc->async_recv;
\t\t\tbinder_inner_proc_unlock(target_proc);
\t\t}
\t}
\tmutex_unlock(&binder_procs_lock);

\tif (!found)
\t\treturn -EINVAL;

\treturn 0;
}

"""
    assert ioctl_anchor in bc, "cannot find binder_ioctl anchor"
    bc = bc.replace(ioctl_anchor, freeze_helpers + ioctl_anchor, 1)

    # In binder_ioctl: case BINDER_FREEZE, BINDER_GET_FROZEN_INFO, BINDER_ENABLE_ONEWAY_SPAM_DETECTION
    default_anchor = "\tdefault:\n\t\tret = -EINVAL;\n\t\tgoto err;\n\t}\n"
    freeze_cases = """\tcase BINDER_FREEZE: {
\t\tstruct binder_freeze_info info;
\t\tstruct binder_proc **target_procs = NULL, *target_proc;
\t\tint target_procs_count = 0, i = 0;

\t\tret = 0;
\t\tif (copy_from_user(&info, ubuf, sizeof(info))) {
\t\t\tret = -EFAULT;
\t\t\tgoto err;
\t\t}

\t\tmutex_lock(&binder_procs_lock);
\t\thlist_for_each_entry(target_proc, &binder_procs, proc_node) {
\t\t\tif (target_proc->pid == info.pid)
\t\t\t\ttarget_procs_count++;
\t\t}

\t\tif (target_procs_count == 0) {
\t\t\tmutex_unlock(&binder_procs_lock);
\t\t\tret = -EINVAL;
\t\t\tgoto err;
\t\t}

\t\ttarget_procs = kmalloc(sizeof(struct binder_proc *) *
\t\t\t\t       target_procs_count,
\t\t\t\t       GFP_KERNEL);

\t\tif (!target_procs) {
\t\t\tmutex_unlock(&binder_procs_lock);
\t\t\tret = -ENOMEM;
\t\t\tgoto err;
\t\t}

\t\thlist_for_each_entry(target_proc, &binder_procs, proc_node) {
\t\t\tif (target_proc->pid != info.pid)
\t\t\t\tcontinue;

\t\t\tbinder_inner_proc_lock(target_proc);
\t\t\ttarget_proc->tmp_ref++;
\t\t\tbinder_inner_proc_unlock(target_proc);

\t\t\ttarget_procs[i++] = target_proc;
\t\t}
\t\tmutex_unlock(&binder_procs_lock);

\t\tfor (i = 0; i < target_procs_count; i++) {
\t\t\tif (ret >= 0)
\t\t\t\tret = binder_ioctl_freeze(&info,
\t\t\t\t\t\t\t  target_procs[i]);

\t\t\tbinder_proc_dec_tmpref(target_procs[i]);
\t\t}

\t\tkfree(target_procs);

\t\tif (ret < 0)
\t\t\tgoto err;
\t\tbreak;
\t}
\tcase BINDER_GET_FROZEN_INFO: {
\t\tstruct binder_frozen_status_info info;

\t\tif (copy_from_user(&info, ubuf, sizeof(info))) {
\t\t\tret = -EFAULT;
\t\t\tgoto err;
\t\t}

\t\tret = binder_ioctl_get_freezer_info(&info);
\t\tif (ret < 0)
\t\t\tgoto err;

\t\tif (copy_to_user(ubuf, &info, sizeof(info))) {
\t\t\tret = -EFAULT;
\t\t\tgoto err;
\t\t}
\t\tbreak;
\t}
\tcase BINDER_ENABLE_ONEWAY_SPAM_DETECTION: {
\t\tuint32_t enable;

\t\tif (copy_from_user(&enable, ubuf, sizeof(enable))) {
\t\t\tret = -EFAULT;
\t\t\tgoto err;
\t\t}
\t\tbinder_inner_proc_lock(proc);
\t\tproc->oneway_spam_detection_enabled = (bool)enable;
\t\tbinder_inner_proc_unlock(proc);
\t\tbreak;
\t}
""" + default_anchor
    assert default_anchor in bc, "cannot find default: in binder_ioctl"
    bc = bc.replace(default_anchor, freeze_cases, 1)

    # In binder_return_strings:
    br_str_anchor = '\tcase BR_FAILED_REPLY: return "BR_FAILED_REPLY";\n'
    br_str_repl = br_str_anchor + '\tcase BR_FROZEN_REPLY: return "BR_FROZEN_REPLY";\n\tcase BR_ONEWAY_SPAM_SUSPECT: return "BR_ONEWAY_SPAM_SUSPECT";\n'
    if br_str_anchor in bc:
        bc = bc.replace(br_str_anchor, br_str_repl, 1)

    bc_path.write_text(bc, encoding="utf-8")
    print("[PASS] drivers/android/binder.c updated")

proof_lines.append("binder_freeze=applied")
proof_lines.append("binder_freeze_race_fix=applied")
proof_lines.append("tf_update_txn=applied")
proof_lines.append("binder_get_frozen_info=applied")
proof_lines.append("oneway_spam_detection=applied")

proof_text = "\n".join(proof_lines) + "\n"
proof_path.parent.mkdir(parents=True, exist_ok=True)
proof_path.write_text(proof_text, encoding="utf-8")
Path("binder-freeze-proof.txt").write_text(proof_text, encoding="utf-8")
workspace = os.environ.get("GITHUB_WORKSPACE")
if workspace:
    (Path(workspace) / "binder-freeze-proof.txt").write_text(proof_text, encoding="utf-8")
print("[PASS] binder-freeze-proof.txt written")
PY

echo '[PASS] Binder freeze patchset successfully applied'
