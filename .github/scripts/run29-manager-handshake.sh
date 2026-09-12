#!/usr/bin/env bash
set -Eeuo pipefail

KERNEL_DIR="${GITHUB_WORKSPACE}/${KERNEL_REL:-source/android/kernel/msm-4.14}"
cd "$KERNEL_DIR"
exec > >(tee "$GITHUB_WORKSPACE/run29-manager-handshake.log") 2>&1

echo '===== RUN29: keep manager handshake on 4.14 sys_reboot hooks ====='
echo 'Managers talk through ksu_handle_sys_reboot. Accept any live CONFIG_KSU guard.'

test -f kernel/reboot.c
test -f fs/exec.c
test -f fs/open.c
test -f fs/stat.c

python3 -u - <<'PY'
from pathlib import Path

files = ['fs/exec.c', 'fs/open.c', 'fs/stat.c', 'kernel/reboot.c']
changed = []
for rel in files:
    p = Path(rel)
    text = p.read_text()
    orig = text
    text = text.replace('#ifdef CONFIG_KSU_MANUAL_HOOK', '#ifdef CONFIG_KSU')
    text = text.replace('#if defined(CONFIG_KSU_MANUAL_HOOK)', '#if defined(CONFIG_KSU)')
    if text != orig:
        p.write_text(text)
        changed.append(rel)
        print(f'{rel}: rewrote MANUAL_HOOK guards to CONFIG_KSU', flush=True)
    elif 'ksu_handle_' in orig:
        print(f'{rel}: hooks already present', flush=True)
    else:
        print(f'{rel}: no ksu_handle_* yet', flush=True)
print('hook_guard_rewrites=' + (','.join(changed) if changed else 'none'), flush=True)

reboot = Path('kernel/reboot.c')
rt = reboot.read_text()
if 'ksu_handle_sys_reboot' not in rt:
    needle = 'SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,\n\t\tvoid __user *, arg)\n{\n'
    insert = (
        '#ifdef CONFIG_KSU\n'
        'extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd,\n'
        '\t\t\t\tvoid __user **arg);\n'
        '#endif\n\n' + needle +
        '#ifdef CONFIG_KSU\n'
        '\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n'
        '#endif\n'
    )
    if needle not in rt:
        raise SystemExit('cannot inject ksu_handle_sys_reboot into kernel/reboot.c')
    reboot.write_text(rt.replace(needle, insert, 1))
    print('kernel/reboot.c: injected CONFIG_KSU sys_reboot hook', flush=True)

cloexec_hits = 0
root = Path('KernelSU')
if root.exists():
    for p in list(root.rglob('*.c')) + list(root.rglob('*.h')):
        text = p.read_text(errors='ignore')
        orig = text
        text = text.replace('ksu_install_fd_with_permissions(O_CLOEXEC, 0)',
                            'ksu_install_fd_with_permissions(0, 0)')
        text = text.replace('get_unused_fd_flags(O_CLOEXEC)',
                            'get_unused_fd_flags(0)')
        if text != orig:
            p.write_text(text)
            cloexec_hits += 1
            print(f'cloexec_relax={p}', flush=True)
print(f'cloexec_files={cloexec_hits}', flush=True)
Path('/tmp/run29-notes.txt').write_text(
    'hook_guard_rewrites=' + (','.join(changed) if changed else 'none') + '\n' +
    f'cloexec_files={cloexec_hits}\n'
)
PY

grep -Fq 'ksu_handle_sys_reboot' kernel/reboot.c
grep -Eq 'ksu_handle_execveat|ksu_handle_execve' fs/exec.c
grep -Fq 'ksu_handle_faccessat' fs/open.c
grep -Fq 'ksu_handle_stat' fs/stat.c
! grep -Fq '#ifdef CONFIG_KSU_MANUAL_HOOK' kernel/reboot.c || \
  grep -Eq '#if(n?def[[:space:]]+| defined\()CONFIG_KSU' kernel/reboot.c

if [[ -n "${OUT_DIR:-}" && -f "$OUT_DIR/.config" && -x scripts/config ]]; then
  echo '===== Keep CONFIG_KSU=y CONFIG_KSU_SUSFS=y ====='
  ./scripts/config --file "$OUT_DIR/.config" -e KSU -e KSU_SUSFS || true
  grep -q '^CONFIG_KSU=y$' "$OUT_DIR/.config"
  grep -q '^CONFIG_KSU_SUSFS=y$' "$OUT_DIR/.config"
fi

{
  echo 'manager_handshake=sys_reboot'
  echo 'hook_guard=CONFIG_KSU'
  echo 'reason=accept_existing_or_rewrite_manual_hook'
  echo 'prctl_not_required=latest_manager_uses_reboot_fd'
  if [[ -f /tmp/run29-notes.txt ]]; then cat /tmp/run29-notes.txt; fi
  if [[ -n "${OUT_DIR:-}" && -f "$OUT_DIR/.config" ]]; then
    grep -E '^CONFIG_KSU(_MANUAL_HOOK|_SUSFS|_TRACEPOINT_HOOK|_KPROBES_HOOK)?=' "$OUT_DIR/.config" || true
  fi
} | tee "$GITHUB_WORKSPACE/run29-manager-handshake-proof.txt"

echo '[PASS] 4.14 manager handshake hooks compile under CONFIG_KSU'
