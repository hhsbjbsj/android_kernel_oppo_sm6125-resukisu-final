#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit('usage: normalize-btf-var-datasec-patch.py <input.patch> <output.patch>')

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
text = src.read_text()

# Xiaomi's BTF next-id backport intentionally exposes these two objects to
# syscall.c. The older upstream VAR/DATASEC commit only carries their `static`
# spelling as patch context; it does not semantically require making them
# private again. Rewrite context lines only, never added/removed patch lines.
replacements = (
    (' static DEFINE_IDR(btf_idr);\n', ' DEFINE_IDR(btf_idr);\n'),
    (' static DEFINE_SPINLOCK(btf_idr_lock);\n', ' DEFINE_SPINLOCK(btf_idr_lock);\n'),
)

for old, new in replacements:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'expected exactly one upstream context line {old.rstrip()!r}, got {count}')
    text = text.replace(old, new, 1)

if ' static DEFINE_IDR(btf_idr);\n' in text or ' static DEFINE_SPINLOCK(btf_idr_lock);\n' in text:
    raise SystemExit('BTF idr static context survived normalization')

dst.write_text(text)
print('[PASS] normalized upstream BTF VAR/DATASEC patch context for Xiaomi BTF next-id visibility')
