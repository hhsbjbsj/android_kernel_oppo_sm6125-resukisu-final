#!/usr/bin/env python3
"""Check the isolated Xiaomi-derived BPF_MAP_FREEZE backport."""

from pathlib import Path
import re
import sys


ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
uapi = (ROOT / "include/uapi/linux/bpf.h").read_text()
header = (ROOT / "include/linux/bpf.h").read_text()
syscall = (ROOT / "kernel/bpf/syscall.c").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


require(re.search(r"\bBPF_MAP_FREEZE\s*=\s*22\b", uapi) is not None,
        "BPF_MAP_FREEZE must preserve the upstream command number 22")
require(re.search(r"struct bpf_map\s*\{.*?\bbool frozen;", header, re.S) is not None,
        "struct bpf_map lacks frozen state")
require("static fmode_t map_get_sys_perms" in syscall,
        "syscall-side map permissions are not centralized")
for function in ("map_update_elem", "map_delete_elem"):
    match = re.search(rf"static int {function}\b.*?\n\}}", syscall, re.S)
    require(match is not None and "map_get_sys_perms(map, f)" in match.group(0),
            f"{function} does not enforce frozen map permissions")
require("static int map_freeze" in syscall, "missing map_freeze syscall handler")
require("WRITE_ONCE(map->frozen, true)" in syscall, "map_freeze does not lock the map")
require(re.search(r"case BPF_MAP_FREEZE:\s*\n\s*err = map_freeze\(&attr\);", syscall) is not None,
        "BPF_MAP_FREEZE is not dispatched")

print("[PASS] Xiaomi-derived BPF_MAP_FREEZE EXP1 invariants")
