#!/usr/bin/env python3
from pathlib import Path
import subprocess

p = Path('net/core/filter.c')
s = p.read_text()

# b4eac9 introduces root-only bpf_spin_lock()/bpf_spin_unlock() helpers.
# Its donor parent already had BPF_FUNC_ktime_get_boot_ns in
# bpf_base_func_proto(), while the OPPO 4.14/A15 baseline does not.  That
# donor-only pre-state is context, not a semantic part of b4eac9.  Preserve
# OPPO's helper list, but reproduce b4eac9's privilege boundary and spin-lock
# helper dispatch.
if s.count('<<<<<<< HEAD\n') != 1 or s.count('=======\n') != 1 or s.count('>>>>>>> ') != 1:
    raise SystemExit('unexpected b4eac9 conflict-marker shape in net/core/filter.c')

func = s.index('bpf_base_func_proto(enum bpf_func_id func_id)')
a = s.index('<<<<<<< HEAD\n', func)
b = s.index('=======\n', a)
c = s.index('>>>>>>> ', b)
e = s.index('\n', c) + 1
ours = s[a + len('<<<<<<< HEAD\n'):b]
theirs = s[b + len('=======\n'):c]

if ours != '':
    raise SystemExit('unexpected OPPO side of b4eac9 conflict: ' + repr(ours))
for needle in (
    'case BPF_FUNC_ktime_get_boot_ns:',
    'if (!capable(CAP_SYS_ADMIN))',
    'case BPF_FUNC_spin_lock:',
    'return &bpf_spin_lock_proto;',
    'case BPF_FUNC_spin_unlock:',
    'return &bpf_spin_unlock_proto;',
):
    if needle not in theirs:
        raise SystemExit('unexpected donor b4eac9 conflict shape; missing ' + needle)

# The trace_printk hunk applied cleanly outside the conflict.  Ensure it has
# donor post-commit form before rebuilding the privilege-gated two-switch
# structure.  This avoids accidentally leaving trace_printk unrestricted.
tail = s[e:]
trace = '\tcase BPF_FUNC_trace_printk:\n\t\treturn bpf_get_trace_printk_proto();\n\tdefault:\n\t\treturn NULL;\n\t}\n'
if trace not in tail:
    raise SystemExit('b4eac9 trace_printk clean-applied tail no longer matches expected shape')

replacement = (
    '\tdefault:\n'
    '\t\tbreak;\n'
    '\t}\n'
    '\tif (!capable(CAP_SYS_ADMIN))\n'
    '\t\treturn NULL;\n'
    '\tswitch (func_id) {\n'
    '\tcase BPF_FUNC_spin_lock:\n'
    '\t\treturn &bpf_spin_lock_proto;\n'
    '\tcase BPF_FUNC_spin_unlock:\n'
    '\t\treturn &bpf_spin_unlock_proto;\n'
)
s = s[:a] + replacement + s[e:]

if any(m in s for m in ('<<<<<<<', '=======', '>>>>>>>')):
    raise SystemExit('conflict markers remain after b4eac9 resolution')

# Do not pull in the unrelated helper that only existed in the donor parent.
start = s.index('bpf_base_func_proto(enum bpf_func_id func_id)')
end = s.index('\n}\n', start) + 3
resolved = s[start:end]
if 'BPF_FUNC_ktime_get_boot_ns' in resolved:
    raise SystemExit('donor-only ktime_get_boot_ns leaked into OPPO bpf_base_func_proto')
for needle in (
    'case BPF_FUNC_ktime_get_ns:',
    'if (!capable(CAP_SYS_ADMIN))',
    'case BPF_FUNC_spin_lock:',
    'return &bpf_spin_lock_proto;',
    'case BPF_FUNC_spin_unlock:',
    'return &bpf_spin_unlock_proto;',
    'case BPF_FUNC_trace_printk:',
    'return bpf_get_trace_printk_proto();',
):
    if needle not in resolved:
        raise SystemExit('b4eac9 resolved function missing expected semantic: ' + needle)
if resolved.count('if (!capable(CAP_SYS_ADMIN))') != 1:
    raise SystemExit('unexpected CAP_SYS_ADMIN gate count in resolved bpf_base_func_proto')
if resolved.index('if (!capable(CAP_SYS_ADMIN))') > resolved.index('case BPF_FUNC_spin_lock:'):
    raise SystemExit('spin-lock helper dispatch is not behind CAP_SYS_ADMIN gate')
if resolved.index('if (!capable(CAP_SYS_ADMIN))') > resolved.index('case BPF_FUNC_trace_printk:'):
    raise SystemExit('trace_printk is not behind CAP_SYS_ADMIN gate')

p.write_text(s)

# 15a328ec6 converts sockmap to the generic sk_msg interface.  Its only
# conflict on the OPPO tree is an additive Makefile overlap: OPPO carries
# sockev_nlmcast.o at the same insertion point where the donor adds sock_map.o.
# Neither replaces the other, so preserve both lines.  Arm a transparent,
# one-shot merge driver now; it passes clean merges through unchanged and
# removes its attribute after consuming the exact expected conflict.
gitdir = Path(subprocess.check_output(['git', 'rev-parse', '--git-dir'], text=True).strip()).resolve()
make_driver = gitdir / 'resolve-makefile-15a328.py'
make_driver.write_text(r'''#!/usr/bin/env python3
from pathlib import Path
import re
import subprocess
import sys

if len(sys.argv) != 4:
    raise SystemExit('usage: resolve-makefile-15a328.py <base> <ours> <theirs>')
base, ours, theirs = map(Path, sys.argv[1:4])
proc = subprocess.run(
    ['git', 'merge-file', '-p', '-L', 'HEAD', '-L', 'BASE', '-L', 'DONOR',
     str(ours), str(base), str(theirs)],
    text=True, capture_output=True,
)
if proc.returncode not in (0, 1):
    sys.stderr.write(proc.stderr)
    raise SystemExit(f'git merge-file failed with {proc.returncode}')
merged = proc.stdout
consumed = False

if proc.returncode == 1:
    pat = re.compile(r'<<<<<<< HEAD\n(.*?)=======\n(.*?)>>>>>>> DONOR\n', re.S)
    blocks = list(pat.finditer(merged))
    if len(blocks) != 1:
        raise SystemExit(f'expected exactly one 15a328 Makefile conflict, found {len(blocks)}')
    b = blocks[0]
    head, donor = b.group(1), b.group(2)
    oppo = 'obj-$(CONFIG_SOCKEV_NLMCAST) += sockev_nlmcast.o\n'
    skmsg = 'obj-$(CONFIG_BPF_STREAM_PARSER) += sock_map.o\n'
    if head != oppo:
        raise SystemExit('15a328 HEAD side no longer matches expected OPPO sockev_nlmcast line: ' + repr(head))
    if donor != skmsg:
        raise SystemExit('15a328 donor side no longer matches expected BPF_STREAM_PARSER sock_map line: ' + repr(donor))
    merged = merged[:b.start()] + oppo + skmsg + merged[b.end():]
    consumed = True

if any(m in merged for m in ('<<<<<<<', '=======', '>>>>>>>')):
    raise SystemExit('conflict markers remain after 15a328 Makefile merge')
if consumed:
    if merged.count('obj-$(CONFIG_SOCKEV_NLMCAST) += sockev_nlmcast.o') != 1:
        raise SystemExit('15a328 merge did not preserve exactly one OPPO sockev_nlmcast object')
    if merged.count('obj-$(CONFIG_BPF_STREAM_PARSER) += sock_map.o') != 1:
        raise SystemExit('15a328 merge did not add exactly one generic sock_map object')

ours.write_text(merged)

if consumed:
    gitdir = Path(subprocess.check_output(['git', 'rev-parse', '--git-dir'], text=True).strip()).resolve()
    attrs = gitdir / 'info' / 'attributes'
    if attrs.exists():
        lines = attrs.read_text().splitlines()
        lines = [line for line in lines if line.strip() != 'net/core/Makefile merge=make15a328']
        attrs.write_text(('\n'.join(lines) + '\n') if lines else '')
    print('[PASS] 15a328 merge driver: preserved OPPO sockev_nlmcast.o and added BPF_STREAM_PARSER sock_map.o')
''')

attrs = gitdir / 'info' / 'attributes'
attrs.parent.mkdir(parents=True, exist_ok=True)
lines = attrs.read_text().splitlines() if attrs.exists() else []
rule = 'net/core/Makefile merge=make15a328'
lines = [line for line in lines if line.strip() != rule]
lines.append(rule)
attrs.write_text('\n'.join(lines) + '\n')
subprocess.run(['git', 'config', 'merge.make15a328.name', 'PCHM30 15a328 sk_msg Makefile semantic merge'], check=True)
subprocess.run(['git', 'config', 'merge.make15a328.driver', f'python3 {make_driver} %O %A %B'], check=True)

print('[PASS] b4eac9 resolver: kept OPPO helper baseline, omitted donor-only ktime_get_boot_ns, gated spin_lock/unlock + trace_printk behind CAP_SYS_ADMIN, and armed 15a328 Makefile merge')
