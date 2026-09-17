#!/usr/bin/env python3
from pathlib import Path
import difflib
import re
import subprocess
import sys
import tempfile

if len(sys.argv) != 3:
    raise SystemExit('usage: normalize-btf-var-datasec-patch.py <input.patch> <output.patch>')

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
current_path = Path('kernel/bpf/btf.c')
patch_text = src.read_text()

if not current_path.is_file():
    raise SystemExit(f'cannot locate current BTF source: {current_path}')

# The fetched upstream diff carries the exact old/new blob IDs.  Using the
# complete files as BASE/THEIRS is more reliable than trying to make a large
# 2019 BTF patch line-number-compatible with the Xiaomi-modified 4.14 tree.
m = re.search(r'^index\s+([0-9a-f]{7,40})\.\.([0-9a-f]{7,40})(?:\s|$)', patch_text, re.M)
if not m:
    raise SystemExit('cannot locate upstream old/new blob IDs in VAR/DATASEC patch')
old_blob, new_blob = m.groups()

def cat_blob(blob: str) -> str:
    cp = subprocess.run(
        ['git', 'cat-file', '-p', blob],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return cp.stdout

base = cat_blob(old_blob)
upstream = cat_blob(new_blob)
current = current_path.read_text()

# Xiaomi's BTF next-id backport intentionally exposes these objects to
# syscall.c.  The VAR/DATASEC change does not semantically require reverting
# that visibility; normalize BASE/THEIRS so the explicit three-way merge sees
# the Xiaomi spelling as the already-selected branch state.
visibility = (
    ('static DEFINE_IDR(btf_idr);', 'DEFINE_IDR(btf_idr);'),
    ('static DEFINE_SPINLOCK(btf_idr_lock);', 'DEFINE_SPINLOCK(btf_idr_lock);'),
)
for old, new in visibility:
    for name, text in (('base', base), ('upstream', upstream)):
        if text.count(old) != 1:
            raise SystemExit(f'expected exactly one {old!r} in upstream {name} blob')
    base = base.replace(old, new, 1)
    upstream = upstream.replace(old, new, 1)

with tempfile.TemporaryDirectory(prefix='btf-var-merge-') as td:
    td = Path(td)
    ours_f = td / 'current.c'
    base_f = td / 'base.c'
    theirs_f = td / 'upstream.c'
    ours_f.write_text(current)
    base_f.write_text(base)
    theirs_f.write_text(upstream)

    cp = subprocess.run(
        [
            'git', 'merge-file', '-p',
            '-L', 'CURRENT-XIAOMI',
            '-L', 'UPSTREAM-BASE',
            '-L', 'UPSTREAM-VAR-DATASEC',
            str(ours_f), str(base_f), str(theirs_f),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )

merged = cp.stdout
if cp.returncode != 0 or any(x in merged for x in ('<<<<<<< ', '=======\n', '>>>>>>> ')):
    sys.stderr.write(cp.stderr)
    conflict = Path('/tmp/btf-var-datasec.merge-conflict.c')
    conflict.write_text(merged)
    # Print only the conflict neighborhoods to Actions logs; never silently
    # choose ours/theirs for verifier code.
    lines = merged.splitlines()
    for i, line in enumerate(lines):
        if line.startswith('<<<<<<< '):
            lo, hi = max(0, i - 8), min(len(lines), i + 80)
            sys.stderr.write('\n'.join(lines[lo:hi]) + '\n')
    raise SystemExit('explicit BTF VAR/DATASEC three-way merge still has semantic conflicts')

required = (
    '#define for_each_vsi(',
    'static bool btf_type_is_var(',
    'static bool btf_type_is_datasec(',
    'static int btf_var_resolve(',
    'static int btf_datasec_resolve(',
    'static const struct btf_kind_operations var_ops',
    'static const struct btf_kind_operations datasec_ops',
    '[BTF_KIND_VAR]',
    '[BTF_KIND_DATASEC]',
)
missing = [needle for needle in required if needle not in merged]
if missing:
    raise SystemExit('three-way merge lost upstream VAR/DATASEC semantics: ' + ', '.join(missing))

if 'static DEFINE_IDR(btf_idr);' in merged or 'static DEFINE_SPINLOCK(btf_idr_lock);' in merged:
    raise SystemExit('three-way merge regressed Xiaomi BTF idr visibility')
if merged.count('DEFINE_IDR(btf_idr);') != 1 or merged.count('DEFINE_SPINLOCK(btf_idr_lock);') != 1:
    raise SystemExit('unexpected Xiaomi BTF idr declaration count after merge')

body = ''.join(difflib.unified_diff(
    current.splitlines(keepends=True),
    merged.splitlines(keepends=True),
    fromfile='a/kernel/bpf/btf.c',
    tofile='b/kernel/bpf/btf.c',
    n=3,
))
if not body:
    raise SystemExit('explicit merge produced no VAR/DATASEC delta')

out = 'diff --git a/kernel/bpf/btf.c b/kernel/bpf/btf.c\n' + body
dst.write_text(out)
print('[PASS] rebuilt upstream BTF VAR/DATASEC delta with explicit full-file three-way merge; Xiaomi BTF next-id visibility preserved')
