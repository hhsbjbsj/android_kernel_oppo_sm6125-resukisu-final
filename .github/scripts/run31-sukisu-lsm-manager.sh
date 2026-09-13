#!/usr/bin/env bash
set -Eeuo pipefail

KERNEL_DIR="${GITHUB_WORKSPACE}/${KERNEL_REL:-source/android/kernel/msm-4.14}"
cd "$KERNEL_DIR"
exec > >(tee "$GITHUB_WORKSPACE/run31-sukisu-lsm-manager.log") 2>&1

echo '===== RUN31: SukiSU 4.2.0 lsm_hook manager UID before zygote SID ====='
echo 'Official manager fd is installed in ksu_handle_setresuid via ksu_install_fd().'
echo '4.2.0 splits that into handle_zygote_setresuid AFTER a zygote SID gate.'
echo 'OPPO 4.14 often misses cached zygote SID, so the manager never gets the fd.'
echo 'Reboot handshake is optional; do not treat it as the manager detection path.'

python3 -u - <<'PY'
from pathlib import Path
import re

paths = [
    Path('KernelSU/kernel/hook/lsm_hook.c'),
    Path('drivers/kernelsu/hook/lsm_hook.c'),
]
seen = set()
files = []
for p in paths:
    if p.exists():
        key = p.resolve()
        if key not in seen:
            seen.add(key)
            files.append(p)
if not files:
    raise SystemExit('lsm_hook.c not found')

INSERT = (
    '    /* PCHM30: manager UID before zygote SID. Cached SID misses on 4.14. */\n'
    '    if (likely(ksu_is_manager_appid_valid()) && unlikely(is_uid_manager(ruid))) {\n'
    '        disable_seccomp();\n'
    '        pr_info("install fd for manager: %d\\n", ruid);\n'
    '        ksu_install_fd();\n'
    '        return 0;\n'
    '    }\n\n'
)

def extract_fn(text, name):
    m = re.search(r'\n(?:static\s+)?int\s+' + re.escape(name) + r'\s*\(', text)
    if not m:
        return None, None, None
    brace = text.find('{', m.end())
    if brace < 0:
        return None, None, None
    depth = 0
    i = brace
    while i < len(text):
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                return m.start() + 1, i + 1, text[m.start() + 1:i + 1]
        i += 1
    return None, None, None

def rewrite(text, path):
    start, end, body = extract_fn(text, 'ksu_handle_setresuid')
    if body is None:
        raise SystemExit('%s: ksu_handle_setresuid not found' % path)
    if 'install fd for manager' in body and 'ksu_install_fd()' in body:
        uid_pos = body.find('is_uid_manager')
        sid_pos = body.find('susfs_is_sid_equal')
        if uid_pos >= 0 and (sid_pos < 0 or uid_pos < sid_pos) and body.find('ksu_install_fd()') < (sid_pos if sid_pos >= 0 else len(body)):
            print('%s: manager install_fd already before SID gate' % path, flush=True)
            return text, 'already'
    if 'handle_zygote_setresuid' not in body and 'susfs_is_sid_equal' not in body:
        raise SystemExit('%s: unexpected ksu_handle_setresuid shape:\n%s' % (path, body[:500]))
    body = re.sub(
        r'\n\s*/\* PCHM30: manager UID before zygote SID[^*]*\*/\n'
        r'\s*if \(likely\(ksu_is_manager_appid_valid\(\)\) && unlikely\(is_uid_manager\(ruid\)\)\) \{\n'
        r'(?:.*?\n){1,8}\s*\}\n',
        '\n',
        body,
        count=1,
        flags=re.S,
    )
    m = re.search(
        r'(if\s*\(\s*cur_uid\s*!=\s*0\s*\)\s*\n\s*return 0;\s*\n)',
        body,
    )
    if m:
        body = body[:m.end()] + '\n' + INSERT + body[m.end():]
    else:
        brace = body.find('{')
        body = body[:brace + 1] + '\n' + INSERT + body[brace + 1:]
    text = text[:start] + body + text[end:]
    print('%s: inserted manager UID install_fd before zygote SID' % path, flush=True)
    return text, 'rewritten'

notes = []
for p in files:
    orig = p.read_text(errors='ignore')
    new, note = rewrite(orig, p)
    notes.append('%s=%s' % (p, note))
    if new != orig:
        p.write_text(new)
    start, end, body = extract_fn(new, 'ksu_handle_setresuid')
    if not body:
        raise SystemExit('%s: lost ksu_handle_setresuid after rewrite' % p)
    if 'ksu_install_fd()' not in body:
        raise SystemExit('%s: ksu_install_fd() missing from ksu_handle_setresuid body' % p)
    uid_pos = body.find('is_uid_manager')
    inst_pos = body.find('ksu_install_fd()')
    sid_pos = body.find('susfs_is_sid_equal')
    if uid_pos < 0:
        raise SystemExit('%s: is_uid_manager missing from ksu_handle_setresuid' % p)
    if sid_pos >= 0 and not (uid_pos < sid_pos and inst_pos < sid_pos):
        raise SystemExit('%s: manager check/install_fd must precede zygote SID gate' % p)
    print('%s: verify uid@%d install_fd@%d sid@%d' % (p, uid_pos, inst_pos, sid_pos), flush=True)

Path('/tmp/run31-notes.txt').write_text('run31_notes=' + ','.join(notes) + '\n')
print('run31_notes=' + ','.join(notes), flush=True)
PY

rej=$(find KernelSU -name '*.rej' -print 2>/dev/null || true)
if [[ -n "$rej" ]]; then
  echo '[FAIL] KernelSU reject files present:'
  printf '%s\n' "$rej"
  exit 1
fi

lh=""
if [[ -f KernelSU/kernel/hook/lsm_hook.c ]]; then
  lh=KernelSU/kernel/hook/lsm_hook.c
elif [[ -f drivers/kernelsu/hook/lsm_hook.c ]]; then
  lh=drivers/kernelsu/hook/lsm_hook.c
fi
test -n "$lh"
python3 -u - <<PY
from pathlib import Path
import re
p = Path("$lh")
t = p.read_text(errors="ignore")
m = re.search(r'int\s+ksu_handle_setresuid\s*\(.*?\n\}', t, re.S)
if not m:
    raise SystemExit("cannot isolate ksu_handle_setresuid")
body = m.group(0)
assert "ksu_install_fd()" in body, "ksu_install_fd not in setresuid"
assert "is_uid_manager" in body
uid = body.find("is_uid_manager")
fd = body.find("ksu_install_fd()")
sid = body.find("susfs_is_sid_equal")
assert sid < 0 or (uid < sid and fd < sid), (uid, fd, sid)
print("isolated_setresuid_ok uid=%d fd=%d sid=%d" % (uid, fd, sid), flush=True)
PY

{
  echo 'manager_path=setresuid_ksu_install_fd'
  echo 'manager_uid_before_zygote_sid=y'
  echo 'reboot_handshake=optional_not_required'
  echo 'rej_files=none'
  if [[ -f /tmp/run31-notes.txt ]]; then cat /tmp/run31-notes.txt; fi
} | tee "$GITHUB_WORKSPACE/run31-sukisu-lsm-manager-proof.txt"

echo '[PASS] manager fd is installed on setresuid before zygote SID gate'
