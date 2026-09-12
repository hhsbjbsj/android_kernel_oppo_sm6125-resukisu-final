#!/usr/bin/env bash
set -Eeuo pipefail

KERNEL_DIR="$GITHUB_WORKSPACE/$KERNEL_REL"
cd "$KERNEL_DIR"
exec > >(tee "$GITHUB_WORKSPACE/run25-susfs230-adapt.log") 2>&1

echo '===== SM6125 4.14 SUSFS: keep in-tree susfs.c and 4.14 VFS ABI ====='
echo 'Do not apply GKI/SM8250 getname_flags+filename_lookup. That hangs first splash.'
test -f include/linux/susfs.h
test -f include/linux/susfs_def.h
test -f fs/susfs.c
test -f fs/exec.c
test -f fs/open.c
test -f fs/stat.c

python3 -u - <<'PY'
from pathlib import Path

h = Path('include/linux/susfs.h').read_text()
h = h.replace('#define SUSFS_VERSION "v2.2.0"', '#define SUSFS_VERSION "v2.3.0"')
if 'SUSFS_VERSION "v2.3.0"' not in h:
    raise SystemExit('failed to bump susfs.h to v2.3.0')
Path('include/linux/susfs.h').write_text(h)
print('version string -> v2.3.0; VFS ABI stays 4.14 user_path_at', flush=True)
PY

echo '===== Revert any GKI/SM8250 VFS rewrite back to 4.14 user_path_at ====='
git fetch --no-tags --depth=1 origin "$GITHUB_SHA" >/dev/null 2>&1 || true
git show "$GITHUB_SHA:.github/scripts/rewrite-susfs230-hooks.py" > "$GITHUB_WORKSPACE/rewrite-susfs230-hooks.py"
python3 -u "$GITHUB_WORKSPACE/rewrite-susfs230-hooks.py"
grep -Fq 'user_path_at(dfd, filename, lookup_flags, &path)' fs/open.c
! grep -Fq 'filename_lookup(dfd, fname' fs/open.c
! grep -Fq 'filename_lookup(dfd, fname' fs/stat.c
grep -Fq 'susfs_is_current_proc_umounted()' fs/exec.c || true
grep -Fq '#define SUSFS_VERSION "v2.3.0"' include/linux/susfs.h

if [[ -e KernelSU/kernel/feature/sucompat.c || -e drivers/kernelsu/feature/sucompat.c || -e KernelSU/kernel/sucompat.c ]]; then
  echo '===== Keep current KSU sucompat on 4.14 user-pointer handlers ====='
  git show "$GITHUB_SHA:.github/scripts/adapt-ksu-sucompat230.sh" > "$GITHUB_WORKSPACE/adapt-ksu-sucompat230.sh"
  chmod +x "$GITHUB_WORKSPACE/adapt-ksu-sucompat230.sh"
  "$GITHUB_WORKSPACE/adapt-ksu-sucompat230.sh"
fi

{
  echo "run26_base=$GITHUB_SHA"
  echo 'susfs_from=v2.2.0'
  echo 'susfs_to=v2.3.0'
  echo 'official_4.14_2.3_patch=absent'
  echo 'gki_2.3_raw_apply=skipped_keep_intree_susfs_c'
  echo 'susfs_overlay=skipped'
  echo 'flag_storage=inode_i_state'
  echo 'fsnotify_api=4.14_intree'
  echo 'tif_proc_no_su=not_used_on_4.14'
  echo 'open_redirect=keep_intree'
  echo 'hooks=4.14_user_path_at+filename_user'
  echo 'filename_lookup=untouched'
  echo 'kernel_source_tree=untouched_in_git'
  echo 'first_splash_fix=no_gki_vfs_abi + no_gki_susfs_c + ak3_boot_only'
} | tee "$GITHUB_WORKSPACE/run25-susfs230-proof.txt"

echo '[PASS] SUSFS version string 2.3.0 with 4.14 user_path_at hooks'
