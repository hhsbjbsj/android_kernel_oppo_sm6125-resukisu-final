#!/usr/bin/env python3
"""Audit the Xiaomi six-feature BPF backport and its required dependencies."""

from pathlib import Path
import re
import sys

root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()


def read(path: str) -> str:
    return (root / path).read_text()


def need(text: str, token: str, label: str) -> None:
    if token not in text:
        raise AssertionError(f"missing {label}: {token}")


uapi = read("include/uapi/linux/bpf.h")
syscall = read("kernel/bpf/syscall.c")
btf = read("kernel/bpf/btf.c")
queue = read("kernel/bpf/queue_stack_maps.c")
header = read("include/linux/bpf_verifier.h")
verifier = read("kernel/bpf/verifier.c")
core = read("kernel/bpf/core.c")
disasm = read("kernel/bpf/disasm.c")
filter_h = read("include/linux/filter.h")

for token in (
    "BPF_MAP_LOOKUP_AND_DELETE_ELEM = 21",
    "BPF_MAP_FREEZE = 22",
    "BPF_BTF_GET_NEXT_ID = 23",
    "BPF_MAP_TYPE_QUEUE = 22",
    "BPF_MAP_TYPE_STACK = 23",
    "BPF_JMP32",
):
    need(uapi, token, "stable UAPI assignment")

for token in (
    "case BPF_MAP_LOOKUP_AND_DELETE_ELEM:",
    "case BPF_MAP_FREEZE:",
    "case BPF_BTF_GET_NEXT_ID:",
    "map_lookup_and_delete_elem",
    "bpf_obj_get_next_id",
):
    need(syscall, token, "syscall implementation")

for token in ("DEFINE_IDR(btf_idr)", "DEFINE_SPINLOCK(btf_idr_lock)"):
    need(btf, token, "BTF ID registry")

# Xiaomi BTF next-id accesses this registry from syscall.c, so the objects must
# remain externally visible. A later upstream BTF backport must not silently
# restore the older `static` spelling just because it appears as patch context.
for pattern, label in (
    (r"^\s*static\s+DEFINE_IDR\(btf_idr\);", "btf_idr became static"),
    (r"^\s*static\s+DEFINE_SPINLOCK\(btf_idr_lock\);", "btf_idr_lock became static"),
):
    if re.search(pattern, btf, re.M):
        raise AssertionError(label)

for token in (
    "queue_map_ops",
    "stack_map_ops",
    "map_push_elem",
    "map_pop_elem",
    "map_peek_elem",
    "raw_spin_trylock_irqsave",
    "-EBUSY",
):
    need(queue, token, "queue/stack map support")

for token in ("u32 branches", "u32 insn_idx", "miss_cnt, hit_cnt", "free_list"):
    need(header, token, "bounded-loop verifier state")

for token in (
    "update_branch_counts",
    "states_maybe_looping",
    "loop_ok && env->allow_ptr_leaks",
    "BPF_CLASS(insn->code) == BPF_JMP32",
    "env->jmps_processed++",
    "BPF_JMP32) |",
    "set_upper_bound",
    "gen_hi_max",
):
    need(verifier, token, "JMP32/bounded-loop verifier logic")

for token in ("INSN_3(JMP32, JEQ", "JMP32_##OPCODE##_X", "ST_NOSPEC"):
    need(core, token, "JMP32 interpreter support")

need(disasm, "BPF_JMP32", "JMP32 disassembler support")
need(filter_h, "BPF_JMP32_REG", "JMP32 instruction helpers")

for path in (
    "include/uapi/linux/bpf.h",
    "include/linux/bpf_verifier.h",
    "kernel/bpf/core.c",
    "kernel/bpf/syscall.c",
    "kernel/bpf/verifier.c",
):
    data = read(path)
    if re.search(r"^(<<<<<<<|=======|>>>>>>>)", data, re.M):
        raise AssertionError(f"conflict marker remains in {path}")

print("[PASS] Xiaomi BPF six-feature full dependency chain invariants")
