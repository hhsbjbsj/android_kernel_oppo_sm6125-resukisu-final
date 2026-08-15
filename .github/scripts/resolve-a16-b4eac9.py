#!/usr/bin/env python3
from pathlib import Path

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
print('[PASS] b4eac9 resolver: kept OPPO helper baseline, omitted donor-only ktime_get_boot_ns, and gated spin_lock/unlock + trace_printk behind CAP_SYS_ADMIN')
