#!/usr/bin/env python3
# Patch materialized run19-source.yml so the inner orchestrator rewriter
# inserts Run28 after BBG. Do not touch run-run19-step.py launch lines;
# those also contain run19-orchestrate.sh as a git-show redirect.
from pathlib import Path
import os

p = Path(os.environ['GITHUB_WORKSPACE']) / 'run19-source.yml'
if not p.is_file():
    raise SystemExit('run19-source.yml is missing')

s = p.read_text()
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
    if old not in s:
        raise SystemExit(
            'cannot locate unique new_runtime bbg insert in run19-source.yml'
        )
    p.write_text(s.replace(old, new, 1))
    print('patched run19-source.yml new_runtime to call run28 after bbg')

if 'run28-extra-features.sh' not in p.read_text():
    raise SystemExit('run28 missing from run19-source.yml after patch')
