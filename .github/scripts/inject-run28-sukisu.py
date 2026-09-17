#!/usr/bin/env python3
# Patch materialized run19-source.yml for the Xiaomi full-deps SukiSU line.
# 1) Make the SukiSU/KPM insertion depend on the unique root-config anchor,
#    not on the old adjacent root-config + stream-parser layout.
# 2) Keep Run28 inserted after BBG.
# Fail closed if either expected source pattern is no longer unique/present.
from pathlib import Path
import os

p = Path(os.environ['GITHUB_WORKSPACE']) / 'run19-source.yml'
if not p.is_file():
    raise SystemExit('run19-source.yml is missing')

s = p.read_text()

old_root_rewriter = r'''          old_root = (
              "run_step 'Prepare proven A16 root config'\n"
              "run_step 'Enable BPF stream parser for sockmap sockhash'\n"
          )
          new_root = (
              "run_step 'Prepare proven A16 root config'\n"
              '"$GITHUB_WORKSPACE/run18-sukisu-swap.sh"\n'
              '"$GITHUB_WORKSPACE/run19-kpm-enable.sh"\n'
              "run_step 'Enable BPF stream parser for sockmap sockhash'\n"
          )
          if s.count(old_root) != 1:
              raise SystemExit(f'cannot locate root-config insertion point: {s.count(old_root)}')
          s = s.replace(old_root, new_root, 1)
'''
new_root_rewriter = r'''          root_anchor = "run_step 'Prepare proven A16 root config'\n"
          root_insert = (
              root_anchor
              + '"$GITHUB_WORKSPACE/run18-sukisu-swap.sh"\n'
              + '"$GITHUB_WORKSPACE/run19-kpm-enable.sh"\n'
          )
          if s.count(root_anchor) != 1:
              raise SystemExit(f'cannot locate unique root-config anchor: {s.count(root_anchor)}')
          if 'run18-sukisu-swap.sh' in s or 'run19-kpm-enable.sh' in s:
              raise SystemExit('SukiSU/KPM staging already present before root-config injection')
          s = s.replace(root_anchor, root_insert, 1)
'''

if s.count(old_root_rewriter) != 1:
    raise SystemExit(
        'cannot locate unique legacy root-config rewriter in run19-source.yml: '
        f'{s.count(old_root_rewriter)}'
    )
s = s.replace(old_root_rewriter, new_root_rewriter, 1)
print('patched run19 root injection to use unique root-config anchor')

if 'run28-extra-features.sh' in s:
    print('run19-source.yml already contains run28')
else:
    old = (
        "'\"$GITHUB_WORKSPACE/run17-bbg-lz4kd.sh\"\\n\\n'\n"
        '              "run_step \'Instrument exact BTF rejection path\'"'
    )
    new = (
        "'\"$GITHUB_WORKSPACE/run17-bbg-lz4kd.sh\"\\n'\n"
        "              '\"$GITHUB_WORKSPACE/run28-extra-features.sh\"\\n\\n'\n"
        '              "run_step \'Instrument exact BTF rejection path\'"'
    )
    if s.count(old) != 1:
        raise SystemExit(
            'cannot locate unique new_runtime bbg insert in run19-source.yml: '
            f'{s.count(old)}'
        )
    s = s.replace(old, new, 1)
    print('patched run19 new_runtime to call run28 after bbg')

p.write_text(s)
final = p.read_text()
if 'old_root = (' in final:
    raise SystemExit('legacy adjacent-line root rewriter survived patch')
if "root_anchor = \"run_step 'Prepare proven A16 root config'\\n\"" not in final:
    raise SystemExit('unique root-config anchor rewriter missing after patch')
if 'run28-extra-features.sh' not in final:
    raise SystemExit('run28 missing from run19-source.yml after patch')
print('[PASS] SukiSU materialized runner rewrites are fail-closed and full-deps compatible')
