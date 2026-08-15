#!/usr/bin/env python3
from pathlib import Path
import re

p = Path('kernel/bpf/verifier.c')
s = p.read_text()

pat = re.compile(r'<<<<<<< HEAD\n(.*?)=======\n(.*?)>>>>>>> [^\n]+\n', re.S)
blocks = list(pat.finditer(s))
if len(blocks) != 2:
    raise SystemExit(f'expected exactly 2 a2ef conflict blocks, found {len(blocks)}')

# Conflict 1: our earlier verifier merge already carries dst/src immediately
# above this marker; a2ef tries to add the same declaration again.
b1 = blocks[0]
ours1, theirs1 = b1.group(1), b1.group(2)
if ours1.strip():
    raise SystemExit('unexpected non-empty HEAD side in a2ef declaration conflict')
if 'u32 dst = insn->dst_reg, src = insn->src_reg;' not in theirs1:
    raise SystemExit('a2ef declaration conflict no longer has expected donor dst/src declaration')

# Conflict 2: a2ef intentionally converts the old sequence of pointer-type
# checks to a switch and extends it with socket/sock_common pointer types.
# Keep that semantic change. The sanitizer stack around this hunk remains the
# OPPO/A15-compatible version established by the earlier resolver.
b2 = blocks[1]
ours2, theirs2 = b2.group(1), b2.group(2)
for needle in (
    'PTR_TO_MAP_VALUE_OR_NULL',
    'CONST_PTR_TO_MAP',
    'PTR_TO_PACKET_END',
):
    if needle not in ours2:
        raise SystemExit(f'a2ef HEAD conflict missing expected old pointer check: {needle}')
for needle in (
    'switch (ptr_reg->type)',
    'case PTR_TO_SOCKET:',
    'case PTR_TO_SOCKET_OR_NULL:',
    'case PTR_TO_SOCK_COMMON:',
    'case PTR_TO_SOCK_COMMON_OR_NULL:',
):
    if needle not in theirs2:
        raise SystemExit(f'a2ef donor conflict missing expected new pointer policy: {needle}')

# Replace from the end so match offsets stay valid.
s = s[:b2.start()] + theirs2 + s[b2.end():]
# Re-find the declaration block after the first replacement; its original
# offsets are before b2, so the first saved match remains valid.
s = s[:b1.start()] + '' + s[b1.end():]

if any(m in s for m in ('<<<<<<<', '=======', '>>>>>>>')):
    raise SystemExit('conflict markers remain after a2ef resolution')

fn_start = s.index('static int adjust_ptr_min_max_vals(')
fn_end = s.find('\nstatic ', fn_start + 1)
if fn_end < 0:
    raise SystemExit('could not find end of adjust_ptr_min_max_vals()')
fn = s[fn_start:fn_end]
if fn.count('u32 dst = insn->dst_reg, src = insn->src_reg;') != 1:
    raise SystemExit('a2ef resolution did not leave exactly one dst/src declaration in adjust_ptr_min_max_vals()')
for needle in (
    'switch (ptr_reg->type)',
    'case PTR_TO_SOCK_COMMON_OR_NULL:',
    'case PTR_TO_MAP_VALUE:',
    'pointer arithmetic with it prohibited for !root',
):
    if needle not in fn:
        raise SystemExit(f'a2ef resolved function missing required semantic: {needle}')

p.write_text(s)
print('[PASS] a2ef resolver: removed duplicate dst/src declaration and adopted A16 socket pointer policy while retaining surrounding OPPO/A15 sanitizer state')
