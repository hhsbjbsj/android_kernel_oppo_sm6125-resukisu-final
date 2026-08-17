#!/usr/bin/env bash
set -Eeuo pipefail

KERNEL_DIR="$GITHUB_WORKSPACE/$KERNEL_REL"
cd "$KERNEL_DIR"
exec > >(tee "$GITHUB_WORKSPACE/run21-selinux-hide-compat.log") 2>&1

RESUKISU_SELINUX_REPO="https://github.com/ReSukiSU/ReSukiSU.git"
RESUKISU_SELINUX_COMMIT="beaaea0eb895dc41e7b9bf5e3f39e57aa9635bab"
DONOR="$GITHUB_WORKSPACE/run21-resukisu-selinux-donor"

printf '%s\n' '===== RUN21: enable SukiSU SELinux-hide on PCHM30 Linux 4.14 ====='
printf 'donor=%s\ncommit=%s\n' "$RESUKISU_SELINUX_REPO" "$RESUKISU_SELINUX_COMMIT"

test -d KernelSU/kernel
test -f KernelSU/kernel/ksu.c
test -f KernelSU/kernel/feature/selinux_hide.c
test -f KernelSU/kernel/selinux/rules.c
test -f KernelSU/kernel/selinux/sepolicy.c

echo '===== Verify pinned SukiSU intentionally disables SELinux-hide below 5.10 ====='
grep -Fq '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)' KernelSU/kernel/ksu.c
grep -Fq 'ksu_selinux_hide_init();' KernelSU/kernel/ksu.c

echo '===== Fetch exact ReSukiSU SELinux implementation previously proven on PCHM30 ====='
rm -rf "$DONOR"
git clone --filter=blob:none --no-checkout "$RESUKISU_SELINUX_REPO" "$DONOR"
git -C "$DONOR" fetch --no-tags origin "$RESUKISU_SELINUX_COMMIT"
git -C "$DONOR" checkout --detach "$RESUKISU_SELINUX_COMMIT"
test "$(git -C "$DONOR" rev-parse HEAD)" = "$RESUKISU_SELINUX_COMMIT"

test -f "$DONOR/kernel/feature/selinux_hide.c"
test -f "$DONOR/kernel/feature/selinux_hide.h"
test -f "$DONOR/kernel/selinux/sepolicy.c"
test -f "$DONOR/kernel/selinux/sepolicy.h"
test -f "$DONOR/kernel/compat/kernel_compat.h"

# Keep SukiSU's rules.c and all SUSFS behavior. Only import the old-kernel
# SELinux helper implementation and the SELinux-hide implementation.
mkdir -p KernelSU/kernel/compat
cp -f "$DONOR/kernel/feature/selinux_hide.c" KernelSU/kernel/feature/selinux_hide.c
cp -f "$DONOR/kernel/feature/selinux_hide.h" KernelSU/kernel/feature/selinux_hide.h
cp -f "$DONOR/kernel/selinux/sepolicy.c" KernelSU/kernel/selinux/sepolicy.c
cp -f "$DONOR/kernel/selinux/sepolicy.h" KernelSU/kernel/selinux/sepolicy.h
cp -f "$DONOR/kernel/compat/kernel_compat.h" KernelSU/kernel/compat/kernel_compat.h

echo '===== Adapt donor SELinux-hide to fixed builtin SukiSU runtime ====='
python3 - <<'PY'
from pathlib import Path

# PCHM30 uses builtin KernelSU, never late-load. Remove the donor dependency on
# ReSukiSU's late-load global while preserving the same builtin behavior.
p = Path('KernelSU/kernel/feature/selinux_hide.c')
s = p.read_text()
s = s.replace('ksu_late_loaded', 'false')

# SukiSU's unity build includes selinux_hide.c before rules.c. Declare the
# legacy policy backups that are defined in rules.c by the Run21 patch below.
anchor = '#include "compat/kernel_compat.h"\n'
insert = anchor + '''\n#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)\nextern struct policydb *backup_policydb;\nextern struct sidtab *backup_sidtab;\n#endif\n'''
if anchor not in s:
    raise SystemExit('selinux_hide compat include anchor missing')
s = s.replace(anchor, insert, 1)

# Pinned SukiSU does not ship ReSukiSU's symbol-resolver. CONFIG_KALLSYMS_ALL is
# proven enabled in Run20, so exact local symbols can be obtained directly.
s = s.replace('find_kernel_symbol_exact(', 'kallsyms_lookup_name(')
s = s.replace('(struct mutex *)ksu_resolve_symbol_for_functable_hook("selinux_status_lock")',
              '(struct mutex *)kallsyms_lookup_name("selinux_status_lock")')
s = s.replace('*((struct page **)ksu_resolve_symbol_for_functable_hook("selinux_status_page"))',
              '*((struct page **)kallsyms_lookup_name("selinux_status_page"))')
s = s.replace('#include "infra/symbol_resolver.h"\n', '')

# Runtime markers for the real-device test.
s = s.replace('pr_info("selinux_hide: init selinux hide\\n");',
              'pr_info("PCHM30 RUN21 selinux_hide enable ENTER\\n");\n    pr_info("selinux_hide: init selinux hide\\n");', 1)
s = s.replace('void __init ksu_selinux_hide_init()\n{',
              'void __init ksu_selinux_hide_init()\n{\n    pr_info("PCHM30 RUN21 selinux_hide feature register ENTER\\n");', 1)
s = s.replace('if (ksu_register_feature_handler(&selinux_hide_handler)) {',
              'if (ksu_register_feature_handler(&selinux_hide_handler)) {', 1)
s = s.replace('    if (ksu_late_loaded) {', '    if (false) {')
p.write_text(s)
PY

echo '===== Add legacy policydb/sidtab backup without replacing SukiSU rules.c ====='
python3 - <<'PY'
from pathlib import Path
p = Path('KernelSU/kernel/selinux/rules.c')
s = p.read_text()

old_top = '''#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n#define SELINUX_POLICY_INSTEAD_SELINUX_SS\nstruct selinux_policy *backup_sepolicy;\n#endif\n'''
new_top = '''#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n#define SELINUX_POLICY_INSTEAD_SELINUX_SS\nstruct selinux_policy *backup_sepolicy;\n#else\nstruct policydb *backup_policydb;\nstruct sidtab *backup_sidtab;\n\nstatic void pchm30_run21_backup_policydb(struct policydb *db)\n{\n    int len, ret;\n\n    if (backup_policydb || backup_sidtab)\n        return;\n\n    backup_policydb = kzalloc(sizeof(*backup_policydb), GFP_KERNEL);\n    if (!backup_policydb) {\n        pr_err("PCHM30 RUN21 selinux_hide: backup policydb alloc failed\\n");\n        return;\n    }\n\n    len = ksu_dup_policydb(db, backup_policydb);\n    if (len < 0) {\n        pr_err("PCHM30 RUN21 selinux_hide: backup policydb copy failed: %d\\n", len);\n        kfree(backup_policydb);\n        backup_policydb = NULL;\n        return;\n    }\n\n    backup_sidtab = kzalloc(sizeof(*backup_sidtab), GFP_KERNEL);\n    if (!backup_sidtab) {\n        ksu_destroy_policydb(backup_policydb);\n        kfree(backup_policydb);\n        backup_policydb = NULL;\n        pr_err("PCHM30 RUN21 selinux_hide: backup sidtab alloc failed\\n");\n        return;\n    }\n\n    ret = policydb_load_isids(backup_policydb, backup_sidtab);\n    if (ret) {\n        kfree(backup_sidtab);\n        backup_sidtab = NULL;\n        ksu_destroy_policydb(backup_policydb);\n        kfree(backup_policydb);\n        backup_policydb = NULL;\n        pr_err("PCHM30 RUN21 selinux_hide: backup sidtab load failed: %d\\n", ret);\n        return;\n    }\n\n    pr_info("PCHM30 RUN21 selinux_hide legacy policy backup READY\\n");\n}\n#endif\n'''
if s.count(old_top) != 1:
    raise SystemExit(f'rules top anchor count={s.count(old_top)}')
s = s.replace(old_top, new_top, 1)

anchor = '''    cpumask_t old_mask;\n    db = get_policydb();\n'''
replacement = '''    cpumask_t old_mask;\n    db = get_policydb();\n    pchm30_run21_backup_policydb(db);\n'''
if s.count(anchor) != 1:
    raise SystemExit(f'legacy apply anchor count={s.count(anchor)}')
s = s.replace(anchor, replacement, 1)
p.write_text(s)
PY

echo '===== Re-enable SELinux-hide unity build and feature registration on 4.14 ====='
python3 - <<'PY'
from pathlib import Path
p = Path('KernelSU/kernel/ksu.c')
s = p.read_text()

pairs = [
('''#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n#include "feature/selinux_hide.h"\n#endif\n''',
 '''#include "feature/selinux_hide.h"\n'''),
('''#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n#include "feature/selinux_hide.c"\n#endif\n''',
 '''#include "feature/selinux_hide.c"\n'''),
('''#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n    ksu_selinux_hide_init();\n#endif\n''',
 '''    ksu_selinux_hide_init();\n'''),
]
for old, new in pairs:
    if s.count(old) != 1:
        raise SystemExit(f'ksu.c guard anchor count={s.count(old)} for {old!r}')
    s = s.replace(old, new, 1)
p.write_text(s)

p = Path('KernelSU/kernel/runtime/ksud.c')
s = p.read_text()
for call in ['ksu_selinux_hide_handle_post_fs_data();', 'ksu_selinux_hide_handle_second_stage();']:
    old = '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n    ' + call + '\n#endif'
    if old not in s:
        raise SystemExit(f'ksud guard not found for {call}')
    s = s.replace(old, '    ' + call, 1)
p.write_text(s)
PY

echo '===== Static proof: Run21 SELinux-hide legacy path is present ====='
grep -Fq '#include "feature/selinux_hide.c"' KernelSU/kernel/ksu.c
grep -Fq 'ksu_selinux_hide_init();' KernelSU/kernel/ksu.c
grep -Fq 'ksu_selinux_hide_handle_post_fs_data();' KernelSU/kernel/runtime/ksud.c
grep -Fq 'ksu_selinux_hide_handle_second_stage();' KernelSU/kernel/runtime/ksud.c
grep -Fq 'PCHM30 RUN21 selinux_hide feature register ENTER' KernelSU/kernel/feature/selinux_hide.c
grep -Fq 'PCHM30 RUN21 selinux_hide enable ENTER' KernelSU/kernel/feature/selinux_hide.c
grep -Fq 'PCHM30 RUN21 selinux_hide legacy policy backup READY' KernelSU/kernel/selinux/rules.c
grep -Fq 'ksu_dup_policydb' KernelSU/kernel/selinux/sepolicy.c

git -C KernelSU diff --check

{
  echo "run20_base=$GITHUB_SHA"
  echo "resukisu_selinux_donor=$RESUKISU_SELINUX_COMMIT"
  echo 'selinux_hide_4_14=enabled'
  echo 'legacy_policy_backup=enabled'
  echo 'run20_kpm_stack=preserved'
} | tee "$GITHUB_WORKSPACE/run21-selinux-hide-proof.txt"

echo '[PASS] Run21 SELinux-hide compatibility stage applied; ready for compile'
