#!/usr/bin/env bash
set -Eeuo pipefail

KERNEL_DIR="$GITHUB_WORKSPACE/$KERNEL_REL"
cd "$KERNEL_DIR"
exec > >(tee "$GITHUB_WORKSPACE/run24-selinux-hide-compat.log") 2>&1

RESUKISU_SELINUX_REPO="${RESUKISU_SELINUX_REPO:-https://github.com/ReSukiSU/ReSukiSU.git}"
RESUKISU_SELINUX_COMMIT="${RESUKISU_COMMIT:-beaaea0eb895dc41e7b9bf5e3f39e57aa9635bab}"
DONOR="$GITHUB_WORKSPACE/run24-resukisu-selinux-donor"

printf '%s\n' '===== RUN24: enable SukiSU SELinux-hide (silence hide) on PCHM30 Linux 4.14 ====='
printf 'donor=%s\ncommit=%s\n' "$RESUKISU_SELINUX_REPO" "$RESUKISU_SELINUX_COMMIT"

test -d KernelSU/kernel
test -f KernelSU/kernel/ksu.c
test -f KernelSU/kernel/feature/selinux_hide.c
test -f KernelSU/kernel/selinux/rules.c
test -f KernelSU/kernel/selinux/sepolicy.c
test -f KernelSU/kernel/selinux/sepolicy.h
test -f KernelSU/kernel/runtime/ksud.c

echo '===== Verify pinned SukiSU still gates hide behind 5.10 before adaptation ====='
grep -Fq '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)' KernelSU/kernel/ksu.c
grep -Fq 'ksu_selinux_hide_init();' KernelSU/kernel/ksu.c

echo '===== Fetch ReSukiSU donor that already implements 4.14 silence hide ====='
rm -rf "$DONOR"
git clone --filter=blob:none --no-checkout "$RESUKISU_SELINUX_REPO" "$DONOR"
git -C "$DONOR" fetch --no-tags origin "$RESUKISU_SELINUX_COMMIT"
git -C "$DONOR" checkout --detach "$RESUKISU_SELINUX_COMMIT"
test "$(git -C "$DONOR" rev-parse HEAD)" = "$RESUKISU_SELINUX_COMMIT"

test -f "$DONOR/kernel/feature/selinux_hide.c"
test -f "$DONOR/kernel/feature/selinux_hide.h"
test -f "$DONOR/kernel/hook/patch_memory.h"
test -f "$DONOR/kernel/hook/arm64/patch_memory.c"

echo '===== Vendor hide + patch_memory only; keep SukiSU rules.c / sepolicy.c ====='
mkdir -p KernelSU/kernel/hook/arm64 KernelSU/kernel/compat KernelSU/kernel/infra
cp -f "$DONOR/kernel/feature/selinux_hide.c" KernelSU/kernel/feature/selinux_hide.c
cp -f "$DONOR/kernel/feature/selinux_hide.h" KernelSU/kernel/feature/selinux_hide.h
cp -f "$DONOR/kernel/hook/patch_memory.h" KernelSU/kernel/hook/patch_memory.h
cp -f "$DONOR/kernel/hook/arm64/patch_memory.c" KernelSU/kernel/hook/arm64/patch_memory.c

cat > KernelSU/kernel/compat/kernel_compat.h <<'EOF'
#ifndef __KSU_H_KERNEL_COMPAT_RUN24
#define __KSU_H_KERNEL_COMPAT_RUN24

#include "infra/kernel_compat.h"
#include <linux/uidgid.h>

#ifndef ksu_get_uid_t
#if LINUX_VERSION_CODE < KERNEL_VERSION(3, 14, 0)
#define ksu_get_uid_t(x) *(unsigned int *)&(x)
#else
#define ksu_get_uid_t(x) ((x).val)
#endif
#endif

#ifndef KSU_COMPAT_USE_STATIC_KEY
#define KSU_COMPAT_USE_STATIC_KEY
#endif

#endif
EOF

cat > KernelSU/kernel/infra/symbol_resolver.h <<'EOF'
#ifndef __KSU_H_SYMBOL_RESOLVER_RUN24
#define __KSU_H_SYMBOL_RESOLVER_RUN24

#include <linux/kallsyms.h>

static inline void *find_kernel_symbol_exact(const char *name)
{
	return (void *)kallsyms_lookup_name(name);
}

static inline void *ksu_resolve_symbol_for_functable_hook(const char *name)
{
	return find_kernel_symbol_exact(name);
}

#endif
EOF

echo '===== PCHM30 sidtab is a pointer inside selinux_ss; force reference semantics ====='
if grep -Eq 'struct[[:space:]]+sidtab[[:space:]]+\*sidtab' security/selinux/ss/services.h; then
  if ! grep -Fq 'KSU_COMPAT_SIDTAB_AS_REFERENCE' KernelSU/kernel/Makefile; then
    printf '\n# RUN24: PCHM30 4.14 selinux_ss.sidtab is a pointer\nccflags-y += -DKSU_COMPAT_SIDTAB_AS_REFERENCE\n' >> KernelSU/kernel/Makefile
  fi
fi
if ! grep -Fq 'KSU_COMPAT_USE_STATIC_KEY' KernelSU/kernel/Makefile; then
  printf '\n# RUN24: enable static-key fake_status path used by donor hide\nccflags-y += -DKSU_COMPAT_USE_STATIC_KEY\n' >> KernelSU/kernel/Makefile
fi

echo '===== Adapt donor hide to builtin SukiSU + 4.14 kallsyms ====='
python3 - <<'PY'
from pathlib import Path

p = Path('KernelSU/kernel/feature/selinux_hide.c')
s = p.read_text()
s = s.replace('ksu_late_loaded', 'false')

anchor = '#include "compat/kernel_compat.h"\n'
insert = anchor + '''
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)
extern struct policydb *backup_policydb;
extern struct sidtab *backup_sidtab;
#endif
'''
if anchor not in s:
    raise SystemExit('selinux_hide compat include anchor missing')
if 'extern struct policydb *backup_policydb' not in s:
    s = s.replace(anchor, insert, 1)

s = s.replace(
    'pr_info("selinux_hide: init selinux hide\\n");',
    'pr_info("PCHM30 RUN24 selinux_hide enable ENTER\\n");\n    pr_info("selinux_hide: init selinux hide\\n");',
    1,
)
s = s.replace(
    'void __init ksu_selinux_hide_init()\n{',
    'void __init ksu_selinux_hide_init()\n{\n    pr_info("PCHM30 RUN24 selinux_hide feature register ENTER\\n");',
    1,
)
p.write_text(s)
PY

echo '===== Add ksu_dup_policydb to existing SukiSU sepolicy without replacing it ====='
python3 - <<'PY'
from pathlib import Path

h = Path('KernelSU/kernel/selinux/sepolicy.h')
hs = h.read_text()
decl = '''
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)
int ksu_dup_policydb(struct policydb *old_db, struct policydb *new_db);
void ksu_destroy_policydb(struct policydb *db);
#endif
'''
if 'ksu_dup_policydb' not in hs:
    needle = '#include "ss/policydb.h"\n'
    if hs.count(needle) != 1:
        raise SystemExit(f'sepolicy.h include anchor count={hs.count(needle)}')
    hs = hs.replace(needle, needle + decl, 1)
    h.write_text(hs)

c = Path('KernelSU/kernel/selinux/sepolicy.c')
cs = c.read_text()
if 'ksu_dup_policydb' not in cs:
    cs += r'''

#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)
static inline void pchm30_run24_lock_sepolicy(void)
{
#if defined(KSU_COMPAT_USE_SELINUX_STATE)
    read_lock(&selinux_state.ss->policy_rwlock);
#endif
}

static inline void pchm30_run24_unlock_sepolicy(void)
{
#if defined(KSU_COMPAT_USE_SELINUX_STATE)
    read_unlock(&selinux_state.ss->policy_rwlock);
#endif
}

int ksu_dup_policydb(struct policydb *old_db, struct policydb *new_db)
{
    struct policy_file fp = { 0 };
    void *data;
    int ret = 0;
    int len = 0;

    pchm30_run24_lock_sepolicy();
    len = old_db->len;
    pchm30_run24_unlock_sepolicy();

    if (len <= 0)
        return -EINVAL;

    data = vmalloc(len);
    if (!data) {
        pr_err("PCHM30 RUN24 selinux_hide: alloc policy len %d failed\n", len);
        return -ENOMEM;
    }

    fp.data = data;
    fp.len = len;

    pchm30_run24_lock_sepolicy();
    ret = policydb_write(old_db, &fp);
    pchm30_run24_unlock_sepolicy();
    if (ret) {
        pr_err("PCHM30 RUN24 selinux_hide: policydb_write: %d\n", ret);
        vfree(data);
        return ret;
    }

    fp.data = data;
    fp.len = len;
    ret = policydb_read(new_db, &fp);
    if (ret) {
        pr_err("PCHM30 RUN24 selinux_hide: policydb_read: %d\n", ret);
        vfree(data);
        return ret;
    }

    new_db->len = old_db->len;
    vfree(data);
    return len;
}

void ksu_destroy_policydb(struct policydb *db)
{
    if (db)
        policydb_destroy(db);
}
#endif
'''
    c.write_text(cs)
PY

echo '===== Add legacy policydb/sidtab backup in SukiSU rules.c ====='
python3 - <<'PY'
from pathlib import Path
p = Path('KernelSU/kernel/selinux/rules.c')
s = p.read_text()

old_top = '''#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)
#define SELINUX_POLICY_INSTEAD_SELINUX_SS
struct selinux_policy *backup_sepolicy;
#endif
'''
new_top = '''#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)
#define SELINUX_POLICY_INSTEAD_SELINUX_SS
struct selinux_policy *backup_sepolicy;
#else
struct policydb *backup_policydb;
struct sidtab *backup_sidtab;

static void pchm30_run24_backup_policydb(struct policydb *db)
{
    int len, ret;

    if (backup_policydb || backup_sidtab)
        return;

    backup_policydb = kzalloc(sizeof(*backup_policydb), GFP_KERNEL);
    if (!backup_policydb) {
        pr_err("PCHM30 RUN24 selinux_hide: backup policydb alloc failed\\n");
        return;
    }

    len = ksu_dup_policydb(db, backup_policydb);
    if (len < 0) {
        pr_err("PCHM30 RUN24 selinux_hide: backup policydb copy failed: %d\\n", len);
        kfree(backup_policydb);
        backup_policydb = NULL;
        return;
    }

    backup_sidtab = kzalloc(sizeof(*backup_sidtab), GFP_KERNEL);
    if (!backup_sidtab) {
        ksu_destroy_policydb(backup_policydb);
        kfree(backup_policydb);
        backup_policydb = NULL;
        pr_err("PCHM30 RUN24 selinux_hide: backup sidtab alloc failed\\n");
        return;
    }

    ret = policydb_load_isids(backup_policydb, backup_sidtab);
    if (ret) {
        kfree(backup_sidtab);
        backup_sidtab = NULL;
        ksu_destroy_policydb(backup_policydb);
        kfree(backup_policydb);
        backup_policydb = NULL;
        pr_err("PCHM30 RUN24 selinux_hide: backup sidtab load failed: %d\\n", ret);
        return;
    }

    pr_info("PCHM30 RUN24 selinux_hide legacy policy backup READY\\n");
}
#endif
'''
if s.count(old_top) != 1:
    raise SystemExit(f'rules top anchor count={s.count(old_top)}')
s = s.replace(old_top, new_top, 1)

anchor = '''    cpumask_t old_mask;
    db = get_policydb();
'''
replacement = '''    cpumask_t old_mask;
    db = get_policydb();
    pchm30_run24_backup_policydb(db);
'''
if s.count(anchor) != 1:
    raise SystemExit(f'legacy apply anchor count={s.count(anchor)}')
s = s.replace(anchor, replacement, 1)
p.write_text(s)
PY

echo '===== Unguard SELinux-hide unity build / init / ksud calls on 4.14 ====='
python3 - <<'PY'
from pathlib import Path

p = Path('KernelSU/kernel/ksu.c')
s = p.read_text()
pairs = [
('''#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)
#include "feature/selinux_hide.h"
#endif
''',
 '''#include "feature/selinux_hide.h"
'''),
('''#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)
#include "feature/selinux_hide.c"
#endif
''',
 '''#include "hook/arm64/patch_memory.c"
#include "feature/selinux_hide.c"
'''),
('''#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)
    ksu_selinux_hide_init();
#endif
''',
 '''    ksu_selinux_hide_init();
'''),
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
    if old in s:
        s = s.replace(old, '    ' + call, 1)
        print(f'[PASS] removed ksud 5.10 guard: {call}')
    elif call in s:
        print(f'[PASS] ksud call already unguarded: {call}')
    else:
        raise SystemExit(f'ksud SELinux-hide call missing: {call}')
p.write_text(s)
PY

echo '===== Static proof: Run24 SELinux-hide 4.14 path is present ====='
grep -Fq '#include "feature/selinux_hide.c"' KernelSU/kernel/ksu.c
grep -Fq '#include "hook/arm64/patch_memory.c"' KernelSU/kernel/ksu.c
grep -Fq 'ksu_selinux_hide_init();' KernelSU/kernel/ksu.c
grep -Fq 'ksu_selinux_hide_handle_post_fs_data();' KernelSU/kernel/runtime/ksud.c
grep -Fq 'ksu_selinux_hide_handle_second_stage();' KernelSU/kernel/runtime/ksud.c
grep -Fq 'PCHM30 RUN24 selinux_hide feature register ENTER' KernelSU/kernel/feature/selinux_hide.c
grep -Fq 'PCHM30 RUN24 selinux_hide enable ENTER' KernelSU/kernel/feature/selinux_hide.c
grep -Fq 'PCHM30 RUN24 selinux_hide legacy policy backup READY' KernelSU/kernel/selinux/rules.c
grep -Fq 'ksu_dup_policydb' KernelSU/kernel/selinux/sepolicy.c
grep -Fq 'ksu_patch_text' KernelSU/kernel/hook/patch_memory.h
test -f KernelSU/kernel/hook/arm64/patch_memory.c
grep -Fq 'KSU_COMPAT_SIDTAB_AS_REFERENCE' KernelSU/kernel/Makefile
! grep -Fq 'ksu_late_loaded' KernelSU/kernel/feature/selinux_hide.c

{
  echo "run24_base=$GITHUB_SHA"
  echo "sukisu_commit=${SUKISU_COMMIT:-unknown}"
  echo "resukisu_selinux_donor=$RESUKISU_SELINUX_COMMIT"
  echo 'selinux_hide_4_14=enabled'
  echo 'legacy_policy_backup=enabled'
  echo 'patch_memory=vendored'
  echo 'sidtab_as_reference=enabled'
  echo 'run23_kpm_stack=preserved'
} | tee "$GITHUB_WORKSPACE/run24-selinux-hide-proof.txt"

echo '[PASS] Run24 SELinux-hide compatibility stage applied; ready for compile'
