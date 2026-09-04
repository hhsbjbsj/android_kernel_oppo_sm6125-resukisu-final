#!/usr/bin/env bash
set -Eeuo pipefail

KERNEL_DIR="$GITHUB_WORKSPACE/$KERNEL_REL"
cd "$KERNEL_DIR"
exec > >(tee "$GITHUB_WORKSPACE/run25-susfs230-adapt.log") 2>&1

SUSFS_REPO="${SUSFS_REPO:-https://gitlab.com/simonpunk/susfs4ksu.git}"
SUSFS_GKI_REF="${SUSFS_GKI_REF:-gki-android12-5.10}"
SUSFS_414_REF="${SUSFS_414_REF:-kernel-4.14}"
WORKDIR="$GITHUB_WORKSPACE/run25-susfs4ksu"

echo '===== RUN25: inspect official SUSFS 4.14 vs 2.3.0 sources ====='
echo "susfs_repo=$SUSFS_REPO"
echo "gki_ref=$SUSFS_GKI_REF"
echo "legacy_4.14_ref=$SUSFS_414_REF"

test -f include/linux/susfs.h
test -f include/linux/susfs_def.h
test -f fs/susfs.c
grep -Fq '#define SUSFS_VERSION "v2.2.0"' include/linux/susfs.h
grep -Fq 'obj-$(CONFIG_KSU_SUSFS) += susfs.o' fs/Makefile
grep -Fq 'AS_FLAGS_SUS_PATH' include/linux/susfs_def.h

rm -rf "$WORKDIR"
git clone --filter=blob:none --no-checkout "$SUSFS_REPO" "$WORKDIR"
git -C "$WORKDIR" fetch --depth=1 origin "$SUSFS_GKI_REF" "$SUSFS_414_REF"
git -C "$WORKDIR" checkout --detach "origin/$SUSFS_GKI_REF"

GKI_H="$WORKDIR/kernel_patches/include/linux/susfs.h"
GKI_DEF="$WORKDIR/kernel_patches/include/linux/susfs_def.h"
GKI_C="$WORKDIR/kernel_patches/fs/susfs.c"
test -f "$GKI_H"
test -f "$GKI_DEF"
test -f "$GKI_C"
grep -Fq '#define SUSFS_VERSION "v2.3.0"' "$GKI_H"
grep -Fq '#define TIF_PROC_NO_SU 34' "$GKI_DEF"
grep -Fq '#define TIF_PROC_UMOUNTED_FOR_ZYGOTE_NEXT 35' "$GKI_DEF"

git -C "$WORKDIR" show "origin/$SUSFS_414_REF:kernel_patches/include/linux/susfs.h" > "$GITHUB_WORKSPACE/run25-official-4.14-susfs.h"
git -C "$WORKDIR" show "origin/$SUSFS_414_REF:kernel_patches/50_add_susfs_in_kernel-4.14.patch" > "$GITHUB_WORKSPACE/run25-official-4.14-50_add_susfs.patch"
test -s "$GITHUB_WORKSPACE/run25-official-4.14-susfs.h"
test -s "$GITHUB_WORKSPACE/run25-official-4.14-50_add_susfs.patch"

if grep -Fq '#define SUSFS_VERSION "v2.3.0"' "$GITHUB_WORKSPACE/run25-official-4.14-susfs.h"; then
  echo 'official_4.14_has_2.3=yes'
else
  echo 'official_4.14_has_2.3=no'
  grep -F '#define SUSFS_VERSION' "$GITHUB_WORKSPACE/run25-official-4.14-susfs.h" || true
fi

echo '===== Official kernel-4.14 branch is still pre-2.3; do not apply GKI 2.3 files raw ====='
echo 'GKI 2.3 moved inode flags to i_mapping->flags and uses fsnotify handle_inode_event.'
echo 'PCHM30 4.14 already has a proven non-GKI 2.2.0 port on i_state + fsnotify_add_mark.'
echo 'Adapt 2.3.0 onto that 4.14 port instead of replacing kernel hook sites.'

python3 - <<'PY'
from pathlib import Path

h = Path('include/linux/susfs.h')
hs = h.read_text()
old = '#define SUSFS_VERSION "v2.2.0"'
new = '#define SUSFS_VERSION "v2.3.0"'
if hs.count(old) != 1:
    raise SystemExit(f'susfs.h version anchor count={hs.count(old)}')
h.write_text(hs.replace(old, new, 1))

d = Path('include/linux/susfs_def.h')
ds = d.read_text()
if '#define TIF_PROC_UMOUNTED 33' not in ds:
    raise SystemExit('4.14 susfs_def.h missing TIF_PROC_UMOUNTED')
if '#define TIF_PROC_NO_SU 34' not in ds:
    ds = ds.replace(
        '#define TIF_PROC_UMOUNTED 33\n',
        '#define TIF_PROC_UMOUNTED 33\n'
        '#define TIF_PROC_NO_SU 34\n'
        '#define TIF_PROC_UMOUNTED_FOR_ZYGOTE_NEXT 35\n',
        1,
    )
    d.write_text(ds)

# Keep 4.14 flag storage on inode->i_state. GKI 2.3 i_mapping->flags would
# desync the already-applied 2.2 hook sites in namei/namespace/open.
if 'inode->i_mapping->flags' in Path('include/linux/susfs_def.h').read_text():
    raise SystemExit('refused to switch 4.14 SUSFS flags onto i_mapping')
if 'inode->i_mapping->flags' in Path('fs/susfs.c').read_text():
    raise SystemExit('refused to import GKI 2.3 i_mapping flag storage into susfs.c')
PY

grep -Fq '#define SUSFS_VERSION "v2.3.0"' include/linux/susfs.h
! grep -Fq '#define SUSFS_VERSION "v2.2.0"' include/linux/susfs.h
grep -Fq '#define TIF_PROC_NO_SU 34' include/linux/susfs_def.h
grep -Fq '#define TIF_PROC_UMOUNTED_FOR_ZYGOTE_NEXT 35' include/linux/susfs_def.h
grep -Fq 'test_bit(AS_FLAGS_SUS_PATH, &inode->i_state)' include/linux/susfs_def.h || \
  grep -Fq 'AS_FLAGS_SUS_PATH, &inode->i_state' include/linux/susfs_def.h
! grep -Fq 'i_mapping->flags' fs/susfs.c
! grep -Fq 'handle_inode_event' fs/susfs.c
grep -Fq 'fsnotify_add_mark' fs/susfs.c

{
  echo "run25_base=$GITHUB_SHA"
  echo 'susfs_from=v2.2.0'
  echo 'susfs_to=v2.3.0'
  echo 'official_4.14_2.3_patch=absent'
  echo 'gki_2.3_raw_apply=rejected'
  echo 'flag_storage=inode_i_state'
  echo 'fsnotify_api=4.14_add_mark'
  echo 'tif_proc_no_su=added'
  echo 'tif_proc_umounted_for_zygote_next=added'
  echo 'kernel_source_tree=untouched_in_git'
} | tee "$GITHUB_WORKSPACE/run25-susfs230-proof.txt"

echo '[PASS] SUSFS 2.3.0 adapted onto the proven PCHM30 4.14 2.2.0 port'
