#!/usr/bin/env python3
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
KERNEL_MAKEFILE = ROOT / "Makefile"
RULES = ROOT / "drivers/kernelsu/selinux/rules.c"
MARKER = "PCHM30_RAPLIVX_RULES_POLICYDB_414_COMPAT"


def die(msg: str) -> None:
    raise SystemExit(f"[KSU rules policydb 4.14 compat] {msg}")


mk = KERNEL_MAKEFILE.read_text(errors="surrogateescape")
version = re.search(r"^VERSION\s*=\s*(\d+)\s*$", mk, re.M)
patchlevel = re.search(r"^PATCHLEVEL\s*=\s*(\d+)\s*$", mk, re.M)
if not version or not patchlevel:
    die("cannot determine kernel VERSION/PATCHLEVEL")
if (int(version.group(1)), int(patchlevel.group(1))) != (4, 14):
    sys.exit(0)

if not RULES.exists():
    die(f"missing transient RapliVx source: {RULES}")

text = RULES.read_text(errors="surrogateescape")
if MARKER in text:
    sys.exit(0)

# RapliVx's pinned rules.c targets newer SELinux internals where the active
# policy is reached through selinux_state.policy->policydb.  This OPPO 4.14
# tree instead defines selinux_state.ss, and struct selinux_ss owns policydb.
# rules.c already includes ss/services.h, so the old struct is complete here.
if '#include "ss/services.h"' not in text:
    die("rules.c no longer includes ss/services.h")

old = '''static struct policydb *get_policydb(void)
{
    struct policydb *db;
    struct selinux_policy *policy = selinux_state.policy;
    db = &policy->policydb;
    return db;
}
'''
new = f'''static struct policydb *get_policydb(void)
{{
    /* {MARKER}: OPPO Linux 4.14 stores policydb under selinux_state.ss. */
    return &selinux_state.ss->policydb;
}}
'''

count = text.count(old)
if count != 1:
    die(f"expected exactly one modern get_policydb block, found {count}")
text = text.replace(old, new, 1)

for forbidden in (
    "selinux_state.policy",
    "struct selinux_policy *policy",
):
    if forbidden in text:
        die(f"unsupported newer SELinux policy path remains: {forbidden}")
if "return &selinux_state.ss->policydb;" not in text:
    die("Linux 4.14 policydb path was not installed")

RULES.write_text(text, errors="surrogateescape")
