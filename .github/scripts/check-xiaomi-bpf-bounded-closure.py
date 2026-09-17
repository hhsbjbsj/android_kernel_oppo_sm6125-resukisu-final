#!/usr/bin/env python3
from pathlib import Path
import re
import sys

root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
h = (root / "include/linux/bpf_verifier.h").read_text()
v = (root / "kernel/bpf/verifier.c").read_text()

checks = [
    ("REG_LIVE_DONE = 4", h, "REG_LIVE_DONE liveness state"),
    ("struct bpf_reg_state *parent;", h, "per-register parent pointer"),
    ("const struct bpf_line_info *prev_linfo;", h, "line-info log cursor"),
    ("#define BPF_COMPLEXITY_LIMIT_STATES\t64", v, "per-insn state limit"),
    ("static void verbose_linfo", v, "verbose_linfo definition"),
    ("regs[i].parent = NULL;", v, "register parent initialization"),
    ("frame->stack[i].spilled_ptr.parent =", v, "stack parent checkpoint"),
    ("offsetof(struct bpf_reg_state, parent)", v, "bounded-loop parent comparison"),
]
for needle, text, label in checks:
    if needle not in text:
        raise SystemExit(f"missing closure invariant: {label}")

if re.search(r"struct bpf_func_state\s*\{[^}]*struct bpf_verifier_state \*parent;", h, re.S):
    raise SystemExit("obsolete state-level bpf_func_state parent still present")
for forbidden, label in [
    ("skip_callee(", "old skip_callee liveness path"),
    ("mark_stack_slot_read(", "old stack state-level liveness path"),
    ("env->ops->gen_ld_abs", "dangling native LD_ABS callback"),
]:
    if forbidden in v:
        raise SystemExit(f"obsolete/incomplete dependency still present: {label}")

# State-level parent is intentionally retained by bounded loops for the branch tree.
if "struct bpf_verifier_state *parent;" not in h:
    raise SystemExit("bounded-loop branch-tree state parent was removed")

# Calls to verbose_linfo must have exactly one real definition.
if len(re.findall(r"static void verbose_linfo\s*\(", v)) != 1:
    raise SystemExit("verbose_linfo definition count is not exactly one")
if v.count("REG_LIVE_DONE") < 4:
    raise SystemExit("REG_LIVE_DONE is not wired through clean/visited liveness paths")

print("[PASS] Xiaomi bounded-loop verifier prerequisite closure is internally consistent")
