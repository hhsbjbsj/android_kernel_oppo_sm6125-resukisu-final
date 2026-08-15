#!/usr/bin/env python3
from pathlib import Path
import subprocess

COMMIT = '4793e2890f82bd363dae8c71a2597e2ce53847c0'
p = Path('kernel/bpf/core.c')
s = p.read_text()

# The OPPO/A15-derived core produces exactly two conflict blocks here:
#   1) bpf_adj_branches() declaration/body prelude
#   2) branch-offset adjustment body
# Keep every clean-applied hunk from 4793 (interpreter + verifier support),
# normalize only this generic branch-adjustment area to donor post-4793, and
# supply the tiny probe-pass pre-state that 4793 assumes in
# bpf_patch_insn_single().
if s.count('<<<<<<< HEAD\n') != 2 or s.count('=======\n') != 2 or s.count('>>>>>>> ') != 2:
    raise SystemExit(
        'unexpected 4793 conflict-marker shape in kernel/bpf/core.c: '
        f"ours={s.count('<<<<<<< HEAD')} sep={s.count('=======')} theirs={s.count('>>>>>>> ')}"
    )
if 'static bool bpf_is_jmp_and_has_target' not in s:
    raise SystemExit('4793 OPPO side no longer has expected old branch helper')
if 'BPF_PSEUDO_CALL' not in s:
    raise SystemExit('4793 donor side missing pseudo-call branch handling')

# The exact donor commit is already present because the workflow fetched the
# A16 endpoint. Pull only the two generic core helpers involved in this
# conflict, rather than replacing kernel/bpf/core.c wholesale.
donor = subprocess.check_output(
    ['git', 'show', f'{COMMIT}:kernel/bpf/core.c'],
    text=True,
)

d_branch_start = donor.index('static int bpf_adj_branches(')
d_patch_start = donor.index('struct bpf_prog *bpf_patch_insn_single', d_branch_start)
d_ifdef = donor.index('#ifdef CONFIG_BPF_JIT', d_patch_start)
donor_branch = donor[d_branch_start:d_patch_start]
donor_patch = donor[d_patch_start:d_ifdef]

for needle in (
    'const bool probe_pass',
    'insn->src_reg == BPF_PSEUDO_CALL',
    'off = pseudo_call ? insn->imm : insn->off;',
):
    if needle not in donor_branch:
        raise SystemExit('unexpected donor 4793 branch helper shape: ' + needle)
for needle in (
    'const u32 cnt_max = S16_MAX;',
    'bpf_adj_branches(prog, off, insn_delta, true)',
    'BUG_ON(bpf_adj_branches(prog_adj, off, insn_delta, false));',
):
    if needle not in donor_patch:
        raise SystemExit('unexpected donor 4793 patch helper shape: ' + needle)

# Both conflict blocks are inside the old branch-helper region. Replace from
# the first marker through the start of bpf_patch_insn_single() with the exact
# donor post-4793 helper. This intentionally removes bpf_is_jmp_and_has_target()
# because 4793 folds pseudo-call handling directly into bpf_adj_branches().
calc = s.index('int bpf_prog_calc_tag(')
c_branch_start = s.index('<<<<<<< HEAD\n', calc)
c_patch_start = s.index('struct bpf_prog *bpf_patch_insn_single', c_branch_start)
s = s[:c_branch_start] + donor_branch + s[c_patch_start:]

# OPPO's 4.14 baseline predates the probe-pass form that the donor already had
# before 4793. The cherry-pick therefore cannot update these call sites because
# they are donor pre-state, not changes introduced by 4793 itself. Replace only
# this generic patching helper with the exact donor post-4793 version.
c_patch_start = s.index('struct bpf_prog *bpf_patch_insn_single', calc)
c_ifdef = s.index('#ifdef CONFIG_BPF_JIT', c_patch_start)
old_patch = s[c_patch_start:c_ifdef]
if 'bpf_adj_branches(prog_adj, off, insn_delta);' not in old_patch:
    raise SystemExit('OPPO bpf_patch_insn_single shape changed unexpectedly')
if 'const u32 cnt_max = S16_MAX;' in old_patch:
    raise SystemExit('OPPO patch helper unexpectedly already has donor probe pre-state')
s = s[:c_patch_start] + donor_patch + s[c_ifdef:]

if any(m in s for m in ('<<<<<<<', '=======', '>>>>>>>')):
    raise SystemExit('conflict markers remain after 4793 resolution')
for needle in (
    'static int bpf_adj_branches(struct bpf_prog *prog, u32 pos, u32 delta,',
    'insn->src_reg == BPF_PSEUDO_CALL',
    'insn->imm = off;',
    'const u32 cnt_max = S16_MAX;',
    'bpf_adj_branches(prog, off, insn_delta, true)',
    'BUG_ON(bpf_adj_branches(prog_adj, off, insn_delta, false));',
):
    if needle not in s:
        raise SystemExit('4793 resolved core missing expected semantic: ' + needle)

p.write_text(s)
print('[PASS] 4793 resolver: resolved two OPPO conflict blocks, added pseudo-call branch adjustment and donor-assumed patch probe pre-state')
