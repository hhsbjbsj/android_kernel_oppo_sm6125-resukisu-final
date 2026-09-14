#!/usr/bin/env python3
"""Check the observable source invariants of the Linux 4.14.236 BPF hardening."""

from pathlib import Path
import re
import sys


ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()


def read(relative: str) -> str:
    return (ROOT / relative).read_text()


def function_body(source: str, name: str) -> str:
    match = re.search(rf"\b{name}\s*\([^;]*?\)\s*\{{", source, re.S)
    if not match:
        raise AssertionError(f"missing function: {name}")
    start = match.end() - 1
    depth = 0
    for index in range(start, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start : index + 1]
    raise AssertionError(f"unterminated function: {name}")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


header = read("include/linux/bpf_verifier.h")
verifier = read("kernel/bpf/verifier.c")
hashtab = read("kernel/bpf/hashtab.c")

require("BPF_ALU_IMMEDIATE" in header, "missing immediate-offset sanitizer state")
require("struct bpf_sanitize_info" in verifier, "missing two-phase sanitizer state")
require("sanitize_check_bounds" in verifier, "missing common speculative bounds check")

sanitize = function_body(verifier, "sanitize_ptr_alu")
for token in ("off_reg", "commit_window", "info->mask_to_left"):
    require(token in sanitize, f"sanitize_ptr_alu is missing {token}")

adjust = function_body(verifier, "adjust_ptr_min_max_vals")
require(
    "off_reg == dst_reg ? dst : src" not in adjust,
    "legacy mixed-bounds check uses removed src variable",
)
require(
    re.search(r"sanitize_ptr_alu\s*\([^;]*\bfalse\s*\)", adjust, re.S) is not None,
    "missing pre-arithmetic sanitizer observation",
)
require(
    re.search(r"sanitize_ptr_alu\s*\([^;]*\btrue\s*\)", adjust, re.S) is not None,
    "missing post-arithmetic sanitizer commit",
)

free_rcu = function_body(hashtab, "htab_elem_free_rcu")
if "preempt_disable" in free_rcu:
    require("__this_cpu_dec(bpf_prog_active)" in free_rcu, "bpf_prog_active is unbalanced")
    require("preempt_enable" in free_rcu, "preemption is left disabled")
    require(
        free_rcu.index("preempt_disable")
        < free_rcu.index("__this_cpu_inc(bpf_prog_active)")
        < free_rcu.index("__this_cpu_dec(bpf_prog_active)")
        < free_rcu.index("preempt_enable"),
        "RCU free safety operations are out of order",
    )

for marker in ("<-- 添加此行", "新增下面这一行"):
    require(marker not in verifier, f"temporary LF edit marker remains: {marker}")

print("[PASS] Linux 4.14.236 BPF speculative-pointer hardening invariants")
