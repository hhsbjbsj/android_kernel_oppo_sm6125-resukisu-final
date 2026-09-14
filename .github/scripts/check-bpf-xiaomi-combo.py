#!/usr/bin/env python3
"""Assert isolated Xiaomi BPF combo invariants on the 4.14 tree."""

from pathlib import Path
import re
import sys


ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()


def require(cond: bool, msg: str) -> None:
    if not cond:
        raise AssertionError(msg)


uapi = (ROOT / "include/uapi/linux/bpf.h").read_text()
header = (ROOT / "include/linux/bpf.h").read_text()
types = (ROOT / "include/linux/bpf_types.h").read_text()
makefile = (ROOT / "kernel/bpf/Makefile").read_text()
syscall = (ROOT / "kernel/bpf/syscall.c").read_text()
verifier = (ROOT / "kernel/bpf/verifier.c").read_text()
core = (ROOT / "kernel/bpf/core.c").read_text()
qs = (ROOT / "kernel/bpf/queue_stack_maps.c").read_text()

require(re.search(r"\bBPF_MAP_LOOKUP_AND_DELETE_ELEM\s*=\s*21\b", uapi),
        "LOOKUP_AND_DELETE must use upstream command number 21")
require(re.search(r"\bBPF_MAP_FREEZE\s*=\s*22\b", uapi),
        "MAP_FREEZE must keep upstream command number 22")
require(re.search(r"\bBPF_BTF_GET_NEXT_ID\s*=\s*23\b", uapi),
        "BTF_GET_NEXT_ID must use upstream command number 23")
require("#define BPF_JMP32" in uapi, "missing BPF_JMP32 class")
require("BPF_MAP_TYPE_QUEUE" in uapi and "BPF_MAP_TYPE_STACK" in uapi,
        "queue/stack map types missing from UAPI")

require("map_push_elem" in header and "map_pop_elem" in header
        and "map_peek_elem" in header,
        "map_ops lack push/pop/peek")
require("BPF_MAP_TYPE(BPF_MAP_TYPE_QUEUE, queue_map_ops)" in types,
        "queue map type not registered")
require("BPF_MAP_TYPE(BPF_MAP_TYPE_STACK, queue_stack_map_ops)" in types,
        "stack map type not registered")
require("queue_stack_maps.o" in makefile, "Makefile missing queue_stack_maps.o")
require("const struct bpf_map_ops queue_map_ops" in qs, "queue_map_ops missing")
require("const struct bpf_map_ops queue_stack_map_ops" in qs,
        "queue_stack_map_ops missing")
require("const struct bpf_map_ops stack_map_ops" not in qs,
        "do not reuse STACK_TRACE symbol stack_map_ops")

require("static int map_lookup_and_delete_elem" in syscall,
        "missing lookup_and_delete handler")
require("static int bpf_btf_get_next_id" in syscall,
        "missing BTF_GET_NEXT_ID handler")
require(re.search(r"case BPF_MAP_LOOKUP_AND_DELETE_ELEM:\s*\n\s*err = map_lookup_and_delete_elem", syscall),
        "LOOKUP_AND_DELETE not dispatched")
require(re.search(r"case BPF_BTF_GET_NEXT_ID:\s*\n\s*err = bpf_btf_get_next_id", syscall),
        "BTF_GET_NEXT_ID not dispatched")
require(re.search(r"case BPF_MAP_FREEZE:\s*\n\s*err = map_freeze", syscall),
        "MAP_FREEZE dispatch must stay")

require("class == BPF_JMP || class == BPF_JMP32" in verifier,
        "verifier does not accept JMP32")
require("bounded-loop back-edge" in verifier,
        "verifier missing bounded-loop marker")
require(
    'bounded-loop back-edge from insn %d to %d\\n", t, w);' in verifier,
    "bounded-loop verbose() string must stay on one line with C \\n escape",
)
require("return -EINVAL" not in verifier.split("bounded-loop back-edge")[1][:180],
        "bounded-loop path still rejects back-edges")

require("[BPF_JMP32 | BPF_JEQ | BPF_X]" in core, "interpreter missing JMP32 jumptable")
require("JMP32_JEQ_X:" in core and "JMP32_JSET_K:" in core,
        "interpreter missing JMP32 labels")

print("[PASS] Xiaomi BPF combo invariants")
