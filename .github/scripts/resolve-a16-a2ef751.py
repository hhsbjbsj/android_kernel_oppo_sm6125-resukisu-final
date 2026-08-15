#!/usr/bin/env python3
from pathlib import Path
import re
import subprocess

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

# The next donor commit that touches an OPPO-modified networking hotspot is
# 31005659a (skb extension infrastructure). In our tree its only conflict is
# inside skb_init(): OPPO initializes skbuff_cb_store_cache while the donor adds
# skb_extensions_init(). These operations are independent and both are needed.
# Install a one-shot custom merge driver now, before that cherry-pick occurs.
gitdir = Path(subprocess.check_output(['git', 'rev-parse', '--git-dir'], text=True).strip()).resolve()
driver = gitdir / 'resolve-skb310.py'
driver.write_text(r'''#!/usr/bin/env python3
from pathlib import Path
import re
import subprocess
import sys

if len(sys.argv) != 4:
    raise SystemExit('usage: resolve-skb310.py <base> <ours> <theirs>')
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

if proc.returncode == 1:
    pat = re.compile(r'<<<<<<< HEAD\n(.*?)=======\n(.*?)>>>>>>> DONOR\n', re.S)
    blocks = list(pat.finditer(merged))
    if len(blocks) != 1:
        raise SystemExit(f'expected exactly one 31005659 skbuff conflict, found {len(blocks)}')
    b = blocks[0]
    head, donor = b.group(1), b.group(2)
    if 'OPLUS_FEATURE_WIFI_LIMMITBGSPEED' not in head or 'skbuff_cb_store_cache' not in head:
        raise SystemExit('31005659 HEAD side no longer matches expected OPPO skb_init block')
    if 'skb_extensions_init();' not in donor:
        raise SystemExit('31005659 donor side missing skb_extensions_init()')
    replacement = head
    if replacement and not replacement.endswith('\n'):
        replacement += '\n'
    replacement += '\tskb_extensions_init();\n'
    merged = merged[:b.start()] + replacement + merged[b.end():]

if any(m in merged for m in ('<<<<<<<', '=======', '>>>>>>>')):
    raise SystemExit('conflict markers remain after 31005659 merge')
if merged.count('skb_extensions_init();') != 1:
    raise SystemExit('31005659 merge must leave exactly one skb_extensions_init() call')
if 'OPLUS_FEATURE_WIFI_LIMMITBGSPEED' not in merged or 'skbuff_cb_store_cache' not in merged:
    raise SystemExit('31005659 merge lost OPPO skb cb cache initialization')

ours.write_text(merged)

# One-shot: do not silently auto-resolve later skbuff.c conflicts with this rule.
gitdir = Path(subprocess.check_output(['git', 'rev-parse', '--git-dir'], text=True).strip()).resolve()
attrs = gitdir / 'info' / 'attributes'
if attrs.exists():
    lines = attrs.read_text().splitlines()
    lines = [line for line in lines if line.strip() != 'net/core/skbuff.c merge=skb310']
    attrs.write_text(('\n'.join(lines) + '\n') if lines else '')
print('[PASS] 31005659 merge driver: preserved OPPO skb cache init and added skb_extensions_init()')
''')

attrs = gitdir / 'info' / 'attributes'
attrs.parent.mkdir(parents=True, exist_ok=True)
existing = attrs.read_text().splitlines() if attrs.exists() else []
rule = 'net/core/skbuff.c merge=skb310'
existing = [line for line in existing if line.strip() != rule]
existing.append(rule)
attrs.write_text('\n'.join(existing) + '\n')
subprocess.run(['git', 'config', 'merge.skb310.name', 'PCHM30 31005659 semantic merge'], check=True)
subprocess.run(['git', 'config', 'merge.skb310.driver', f'python3 {driver} %O %A %B'], check=True)

print('[PASS] a2ef resolver: removed duplicate dst/src declaration, kept A16 socket pointer policy, and armed one-shot 31005659 skb merge')
