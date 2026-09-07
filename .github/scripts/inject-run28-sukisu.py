#!/usr/bin/env python3
# Patch the materialized Run19 step runner so Run28 is inserted into
# run19-orchestrate.sh after that file is rewritten, before it is executed.
# Avoids YAML/Python/bash quoting in the SukiSU workflow.
from pathlib import Path
import os

ws = Path(os.environ['GITHUB_WORKSPACE'])
runner = ws / 'run-run19-step.py'
if not runner.is_file():
    raise SystemExit('run-run19-step.py is missing')

s = runner.read_text()
old = (
    "subprocess.run(['bash', '-c', 'set -Eeuo pipefail\\n' + ''.join(script_lines)], "
    "cwd=cwd, check=True, env=os.environ.copy())"
)
if old not in s:
    raise SystemExit('cannot locate run-run19-step.py subprocess.run call')

new = '''
joined_script = ''.join(script_lines)
launch = '"$GITHUB_WORKSPACE/run19-orchestrate.sh"\\n'
if launch not in joined_script:
    raise SystemExit('cannot locate run19-orchestrate.sh launch in extracted step')
hook = (
    "python3 - <<'R28'\\n"
    "from pathlib import Path\\n"
    "import os\\n"
    "p = Path(os.environ['GITHUB_WORKSPACE']) / 'run19-orchestrate.sh'\\n"
    "s = p.read_text()\\n"
    "call = '\\"$GITHUB_WORKSPACE/run28-extra-features.sh\\"\\n'\\n"
    "key = '\\"$GITHUB_WORKSPACE/run17-bbg-lz4kd.sh\\"\\n'\\n"
    "if call not in s:\\n"
    "    if key not in s:\\n"
    "        raise SystemExit('cannot find bbg call in run19-orchestrate.sh')\\n"
    "    p.write_text(s.replace(key, key + call, 1))\\n"
    "print('injected run28 into run19-orchestrate.sh')\\n"
    "R28\\n"
)
joined_script = joined_script.replace(launch, hook + launch, 1)
subprocess.run(['bash', '-c', 'set -Eeuo pipefail\\n' + joined_script], cwd=cwd, check=True, env=os.environ.copy())
'''.lstrip('\n')

runner.write_text(s.replace(old, new, 1))
if 'run28-extra-features.sh' not in runner.read_text():
    raise SystemExit('failed to patch run-run19-step.py with Run28 hook')
print('patched run-run19-step.py to inject Run28 before orchestrate launch')
