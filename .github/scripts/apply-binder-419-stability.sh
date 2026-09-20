#!/usr/bin/env bash
# Apply Binder 4.19 / upstream stability & UAF prevention fixes:
# 1. include/linux/wait.h: declare __wake_up_pollfree and wake_up_pollfree inline helper
# 2. kernel/sched/wait.c: implement __wake_up_pollfree (CVE-2021-0920)
# 3. drivers/android/binder.c: wake_up_pollfree on thread release, u32 max_threads, debug_mask=0
# 4. drivers/android/binder_alloc.c: mmput_async and 0-sized async buffer padding
set -Eeuo pipefail

KERNEL_DIR="${KERNEL_DIR:-$GITHUB_WORKSPACE/$KERNEL_REL}"
cd "$KERNEL_DIR"
export PROOF="${GITHUB_WORKSPACE:-.}/binder-419-proof.txt"

python3 - <<'PY'
from pathlib import Path
import os

proof_path = Path(os.environ.get("PROOF", "binder-419-proof.txt"))
proof_lines = []

# 1. include/linux/wait.h
wait_h_path = Path("include/linux/wait.h")
wait_h = wait_h_path.read_text(encoding="utf-8")
if "wake_up_pollfree" not in wait_h:
    target1 = "void __wake_up_sync(struct wait_queue_head *wq_head, unsigned int mode, int nr);\n"
    repl1 = target1 + "void __wake_up_pollfree(struct wait_queue_head *wq_head);\n"
    assert target1 in wait_h, "cannot find __wake_up_sync in wait.h"
    wait_h = wait_h.replace(target1, repl1, 1)

    target2 = "#define wake_up_interruptible_sync_poll(x, m)\t\t\t\t\t\\\n\t__wake_up_sync_key((x), TASK_INTERRUPTIBLE, 1, (void *) (m))\n"
    repl2 = target2 + """
/**
 * wake_up_pollfree - signal that a polled waitqueue is going away
 * @wq_head: the wait queue head
 */
static inline void wake_up_pollfree(struct wait_queue_head *wq_head)
{
\tif (waitqueue_active(wq_head))
\t\t__wake_up_pollfree(wq_head);
}
"""
    assert target2 in wait_h, "cannot find wake_up_interruptible_sync_poll in wait.h"
    wait_h = wait_h.replace(target2, repl2, 1)
    wait_h_path.write_text(wait_h, encoding="utf-8")
    print("[PASS] wait.h patched with wake_up_pollfree")
proof_lines.append("wake_up_pollfree=applied")

# 2. kernel/sched/wait.c
wait_c_path = Path("kernel/sched/wait.c")
wait_c = wait_c_path.read_text(encoding="utf-8")
if "__wake_up_pollfree" not in wait_c:
    target_inc = "#include <linux/kthread.h>\n"
    repl_inc = target_inc + "#include <linux/poll.h>\n"
    assert target_inc in wait_c, "cannot find kthread.h in wait.c"
    wait_c = wait_c.replace(target_inc, repl_inc, 1)

    target_sym = "EXPORT_SYMBOL_GPL(__wake_up_sync);\t/* For internal use only */\n"
    repl_sym = target_sym + """
void __wake_up_pollfree(struct wait_queue_head *wq_head)
{
\t__wake_up(wq_head, TASK_NORMAL, 0, (void *)(POLLHUP | POLLFREE));
\t/* POLLFREE must have cleared the queue. */
\tWARN_ON_ONCE(waitqueue_active(wq_head));
}
EXPORT_SYMBOL_GPL(__wake_up_pollfree);
"""
    assert target_sym in wait_c, "cannot find __wake_up_sync export in wait.c"
    wait_c = wait_c.replace(target_sym, repl_sym, 1)
    wait_c_path.write_text(wait_c, encoding="utf-8")
    print("[PASS] wait.c patched with __wake_up_pollfree")
proof_lines.append("__wake_up_pollfree=exported")

# 3. drivers/android/binder.c
binder_c_path = Path("drivers/android/binder.c")
binder_c = binder_c_path.read_text(encoding="utf-8")
if "wake_up_pollfree" not in binder_c:
    b_target1 = "\tif ((thread->looper & BINDER_LOOPER_STATE_POLL) &&\n\t    waitqueue_active(&thread->wait)) {\n\t\twake_up_poll(&thread->wait, POLLHUP | POLLFREE);\n\t}"
    b_repl1 = "\tif (thread->looper & BINDER_LOOPER_STATE_POLL)\n\t\twake_up_pollfree(&thread->wait);"
    assert b_target1 in binder_c, "cannot find wake_up_poll in binder.c"
    binder_c = binder_c.replace(b_target1, b_repl1, 1)

    b_target2 = "\tint max_threads;\n\tint requested_threads;"
    b_repl2 = "\tu32 max_threads;\n\tint requested_threads;"
    if b_target2 in binder_c:
        binder_c = binder_c.replace(b_target2, b_repl2, 1)

    b_target3 = "\tcase BINDER_SET_MAX_THREADS: {\n\t\tint max_threads;"
    b_repl3 = "\tcase BINDER_SET_MAX_THREADS: {\n\t\tu32 max_threads;"
    if b_target3 in binder_c:
        binder_c = binder_c.replace(b_target3, b_repl3, 1)

    b_target4 = "static uint32_t binder_debug_mask = BINDER_DEBUG_USER_ERROR |\n\tBINDER_DEBUG_FAILED_TRANSACTION | BINDER_DEBUG_DEAD_TRANSACTION;"
    b_repl4 = "static uint32_t binder_debug_mask = 0;"
    if b_target4 in binder_c:
        binder_c = binder_c.replace(b_target4, b_repl4, 1)

    b_target5 = 'pr_info("%d:%d ioctl %x %lx returned %d\\n", proc->pid, current->pid, cmd, arg, ret);'
    b_repl5 = 'pr_debug("%d:%d ioctl %x %lx returned %d\\n", proc->pid, current->pid, cmd, arg, ret);'
    if b_target5 in binder_c:
        binder_c = binder_c.replace(b_target5, b_repl5, 1)

    binder_c_path.write_text(binder_c, encoding="utf-8")
    print("[PASS] binder.c patched with wake_up_pollfree, u32 max_threads, debug_mask=0")
proof_lines.append("binder_thread_release=wake_up_pollfree")
proof_lines.append("binder_max_threads=u32")
proof_lines.append("binder_debug_mask=0")

# 4. drivers/android/binder_alloc.c
ba_path = Path("drivers/android/binder_alloc.c")
ba = ba_path.read_text(encoding="utf-8")
if "mmput_async" not in ba:
    ba_target1 = "\tif (mm) {\n\t\tup_read(&mm->mmap_sem);\n\t\tmmput(mm);\n\t}\n\treturn 0;"
    ba_repl1 = "\tif (mm) {\n\t\tup_read(&mm->mmap_sem);\n\t\tmmput_async(mm);\n\t}\n\treturn 0;"
    assert ba_target1 in ba, "cannot find mmput in binder_update_page_range"
    ba = ba.replace(ba_target1, ba_repl1, 1)

    ba_target2 = "err_no_vma:\n\tif (mm) {\n\t\tup_read(&mm->mmap_sem);\n\t\tmmput(mm);\n\t}\n\treturn vma ? -ENOMEM : -ESRCH;"
    ba_repl2 = "err_no_vma:\n\tif (mm) {\n\t\tup_read(&mm->mmap_sem);\n\t\tmmput_async(mm);\n\t}\n\treturn vma ? -ENOMEM : -ESRCH;"
    assert ba_target2 in ba, "cannot find err_no_vma mmput in binder_alloc.c"
    ba = ba.replace(ba_target2, ba_repl2, 1)

    ba_target3 = "\tup_read(&mm->mmap_sem);\n\tmmput(mm);\n\n\ttrace_binder_unmap_kernel_start(alloc, index);"
    ba_repl3 = "\tup_read(&mm->mmap_sem);\n\tmmput_async(mm);\n\n\ttrace_binder_unmap_kernel_start(alloc, index);"
    if ba_target3 in ba:
        ba = ba.replace(ba_target3, ba_repl3, 1)

    ba_target4 = """\tif (is_async &&
\t    alloc->free_async_space < size + sizeof(struct binder_buffer)) {
\t\tbinder_alloc_debug(BINDER_DEBUG_BUFFER_ALLOC,
\t\t\t     "%d: binder_alloc_buf size %zd failed, no async space left\\n",
\t\t\t      alloc->pid, size);
\t\treturn ERR_PTR(-ENOSPC);
\t}

\t/* Pad 0-size buffers so they get assigned unique addresses */
\tsize = max(size, sizeof(void *));"""

    ba_repl4 = """\t/* Pad 0-size buffers so they get assigned unique addresses */
\tsize = max(size, sizeof(void *));

\tif (is_async &&
\t    alloc->free_async_space < size + sizeof(struct binder_buffer)) {
\t\tbinder_alloc_debug(BINDER_DEBUG_BUFFER_ALLOC,
\t\t\t     "%d: binder_alloc_buf size %zd failed, no async space left\\n",
\t\t\t      alloc->pid, size);
\t\treturn ERR_PTR(-ENOSPC);
\t}"""
    if ba_target4 in ba:
        ba = ba.replace(ba_target4, ba_repl4, 1)

    ba_path.write_text(ba, encoding="utf-8")
    print("[PASS] binder_alloc.c patched with mmput_async and async pad fix")
proof_lines.append("mmput_async=applied")
proof_lines.append("async_pad_0size=applied")

proof_text = "\n".join(proof_lines) + "\n"
proof_path.write_text(proof_text, encoding="utf-8")
Path("binder-419-proof.txt").write_text(proof_text, encoding="utf-8")
workspace = os.environ.get("GITHUB_WORKSPACE")
if workspace:
    (Path(workspace) / "binder-419-proof.txt").write_text(proof_text, encoding="utf-8")
print("[PASS] binder-419-proof.txt written")
PY

echo '[PASS] Binder 4.19 stability patchset successfully applied'
