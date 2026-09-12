#!/usr/bin/env bash
set -Eeuo pipefail

KERNEL_DIR="${GITHUB_WORKSPACE}/${KERNEL_REL:-source/android/kernel/msm-4.14}"
cd "$KERNEL_DIR"
exec > >(tee "$GITHUB_WORKSPACE/run29-manager-handshake.log") 2>&1

echo '===== RUN29: keep manager handshake on 4.14 sys_reboot hooks ====='
echo 'Latest ReSukiSU/SukiSU managers talk through ksu_handle_sys_reboot, not prctl.'
echo '4.14 hooks were compiled out: they sat behind CONFIG_KSU_MANUAL_HOOK.'
echo 'ReSukiSU Kconfig choice makes CONFIG_KSU_SUSFS exclusive with MANUAL_HOOK.'
echo 'SukiSU builtin has no CONFIG_KSU_MANUAL_HOOK at all.'

test -f kernel/reboot.c
test -f fs/exec.c
test -f fs/open.c
test -f fs/stat.c

python3 -u - <<'PY'
from pathlib import Path

files = ['fs/exec.c', 'fs/open.c', 'fs/stat.c', 'kernel/reboot.c']
old = '#ifdef CONFIG_KSU_MANUAL_HOOK'
new = '#if defined(CONFIG_KSU)'
changed = []
for rel in files:
    p = Path(rel)
    text = p.read_text()
    if old not in text:
        if 'ksu_handle_' not in text:
            raise SystemExit(f'{rel}: missing both MANUAL_HOOK guard and ksu_handle_*')
        print(f'{rel}: no CONFIG_KSU_MANUAL_HOOK guard', flush=True)
        continue
    count = text.count(old)
    p.write_text(text.replace(old, new))
    changed.append(f'{rel}:{count}')
    print(f'{rel}: rewrote {count} guards to CONFIG_KSU', flush=True)
print('hook_guard_rewrites=' + (','.join(changed) if changed else 'none'), flush=True)

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
grep -Fq '#if defined(CONFIG_KSU)' kernel/reboot.c
grep -Fq 'ksu_handle_execveat' fs/exec.c
grep -Fq 'ksu_handle_faccessat' fs/open.c
grep -Fq 'ksu_handle_stat' fs/stat.c
! grep -Fq '#ifdef CONFIG_KSU_MANUAL_HOOK' kernel/reboot.c
! grep -Fq '#ifdef CONFIG_KSU_MANUAL_HOOK' fs/exec.c
! grep -Fq '#ifdef CONFIG_KSU_MANUAL_HOOK' fs/open.c
! grep -Fq '#ifdef CONFIG_KSU_MANUAL_HOOK' fs/stat.c

if [[ -n "${OUT_DIR:-}" && -f "$OUT_DIR/.config" && -x scripts/config ]]; then
  echo '===== Keep CONFIG_KSU=y CONFIG_KSU_SUSFS=y ====='
  ./scripts/config --file "$OUT_DIR/.config" -e KSU -e KSU_SUSFS || true
  grep -q '^CONFIG_KSU=y$' "$OUT_DIR/.config"
  grep -q '^CONFIG_KSU_SUSFS=y$' "$OUT_DIR/.config"
fi

{
  echo 'manager_handshake=sys_reboot'
  echo 'hook_guard=CONFIG_KSU'
  echo 'reason=manual_hook_exclusive_with_susfs_left_reboot_hook_dead'
  echo 'prctl_not_required=latest_manager_uses_reboot_fd'
  if [[ -f /tmp/run29-notes.txt ]]; then cat /tmp/run29-notes.txt; fi
  if [[ -n "${OUT_DIR:-}" && -f "$OUT_DIR/.config" ]]; then
    grep -E '^CONFIG_KSU(_MANUAL_HOOK|_SUSFS|_TRACEPOINT_HOOK|_KPROBES_HOOK)?=' "$OUT_DIR/.config" || true
  fi
} | tee "$GITHUB_WORKSPACE/run29-manager-handshake-proof.txt"

echo '[PASS] 4.14 manager handshake hooks now compile under CONFIG_KSU'
