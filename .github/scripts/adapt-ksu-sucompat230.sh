#!/usr/bin/env bash
set -Eeuo pipefail
echo '===== Keep ReSukiSU/SukiSU sucompat on 4.14 user-pointer ABI + allow_shell ====='

python3 -u - <<'PY'
from pathlib import Path
import re

files = []
for rel in (
    'KernelSU/kernel/feature/sucompat.c',
    'drivers/kernelsu/feature/sucompat.c',
    'KernelSU/kernel/sucompat.c',
    'drivers/kernelsu/sucompat.c',
):
    p = Path(rel)
    if p.is_file():
        files.append(p.resolve())

seen = set()
uniq = []
for p in files:
    key = (p.stat().st_ino, p.stat().st_dev)
    if key in seen:
        continue
    seen.add(key)
    uniq.append(p)
if not uniq:
    found = list(Path('.').rglob('sucompat.c'))
    raise SystemExit('sucompat.c not found: %s' % found[:8])

FA_USER = '''int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *__unused_flags)
{
	char path[sizeof(su_path) + 1] = { 0 };

	if (unlikely(!filename_user || !*filename_user))
		return 0;
	if (ksu_strncpy_from_user_nofault(path, *filename_user, sizeof(path)) < 0)
		return 0;
	if (likely(memcmp(path, su_path, sizeof(su_path))))
		return 0;
	if (current_chrooted()) {
		pr_err("ksu_handle_faccessat: su found but NOT allowed! Because current process is running in chrooted environment\\n");
		return 0;
	}
	pr_info("ksu_handle_faccessat: su->sh!\\n");
	*filename_user = sh_user_path();
	return 0;
}'''

STAT_USER = '''int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags)
{
	char path[sizeof(su_path) + 1] = { 0 };

	if (unlikely(!filename_user || !*filename_user))
		return 0;
	if (ksu_strncpy_from_user_nofault(path, *filename_user, sizeof(path)) < 0)
		return 0;
	if (likely(memcmp(path, su_path, sizeof(su_path))))
		return 0;
	if (current_chrooted()) {
		pr_err("ksu_handle_stat: su found but NOT allowed! Because current process is running in chrooted environment\\n");
		return 0;
	}
	pr_info("ksu_handle_stat: su->sh!\\n");
	*filename_user = sh_user_path();
	return 0;
}'''

FA_USER_SU = FA_USER.replace('su_path', 'su')
STAT_USER_SU = STAT_USER.replace('su_path', 'su')


def pick_templates(text):
    if re.search(r'\bsu_path\b', text):
        return FA_USER, STAT_USER
    return FA_USER_SU, STAT_USER_SU


def adapt_c(path: Path):
    t = path.read_text()
    changed = []
    fa_body, stat_body = pick_templates(t)

    # 1. In ReSukiSU, disable the GKI struct filename ** handler if standalone
    if re.search(r'#ifdef CONFIG_KSU_SUSFS\s*\nint ksu_handle_faccessat\(int \*dfd, struct filename \*\*filename,', t):
        t = re.sub(
            r'#ifdef CONFIG_KSU_SUSFS\s*\nint ksu_handle_faccessat\(int \*dfd, struct filename \*\*filename,',
            '#if 0 /* SM6125 4.14: uses user-pointer faccessat */\nint ksu_handle_faccessat(int *dfd, struct filename **filename,',
            t,
            count=1,
        )
        changed.append('disabled GKI faccessat in favor of 4.14 user-pointer handler')

    if re.search(r'#ifdef CONFIG_KSU_SUSFS\s*\nint ksu_handle_stat\(int \*dfd, struct filename \*\*filename,', t):
        t = re.sub(
            r'#ifdef CONFIG_KSU_SUSFS\s*\nint ksu_handle_stat\(int \*dfd, struct filename \*\*filename,',
            '#if 0 /* SM6125 4.14: uses user-pointer stat */\nint ksu_handle_stat(int *dfd, struct filename **filename,',
            t,
            count=1,
        )
        changed.append('disabled GKI stat in favor of 4.14 user-pointer handler')

    # 2. In SukiSU and any other layout, replace ksu_handle_faccessat with 4.14 user-pointer handler using sh_user_path()
    fa_pat = re.compile(
        r'int ksu_handle_faccessat\s*\(\s*int \*dfd,\s*(?:struct filename \*\*filename|const char __user \*\*filename_user),\s*int \*mode,\s*int \*\w+\s*\)\s*\{.*?\n\}',
        re.S,
    )
    m = fa_pat.search(t)
    if m:
        if 'const char __user **filename_user' not in m.group(0) or 'sh_user_path' not in m.group(0):
            t = t[:m.start()] + fa_body + t[m.end():]
            changed.append('faccessat: installed 4.14 user-pointer handler')

    # 3. In SukiSU and any other layout, replace ksu_handle_stat with 4.14 user-pointer handler using sh_user_path()
    stat_pat = re.compile(
        r'int ksu_handle_stat\s*\(\s*int \*dfd,\s*(?:struct filename \*\*filename|const char __user \*\*filename_user),\s*int \*flags\s*\)\s*\{.*?\n\}',
        re.S,
    )
    m = stat_pat.search(t)
    if m:
        if 'const char __user **filename_user' not in m.group(0) or 'sh_user_path' not in m.group(0):
            t = t[:m.start()] + stat_body + t[m.end():]
            changed.append('stat: installed 4.14 user-pointer handler')

    # 4. Never take GKI filename** sucompat
    t = re.sub(
        r'#if LINUX_VERSION_CODE >= KERNEL_VERSION\(\s*6\s*,\s*1\s*,\s*0\s*\)(?:\s*&&\s*defined\(\s*CONFIG_KSU_SUSFS\s*\))?\s*',
        '#if 0 /* SM6125 4.14: never take GKI filename** sucompat */\n',
        t,
    )

    if not re.search(r'int ksu_handle_faccessat\s*\(\s*int \*dfd,\s*const char __user \*\*filename_user', t):
        raise SystemExit('%s: faccessat still not user-pointer' % path)

    path.write_text(t)
    print('%s: %s' % (path, '; '.join(changed) or 'unchanged'), flush=True)


def adapt_h(path: Path):
    if not path.exists():
        return
    h = path.read_text()
    if '#ifdef CONFIG_KSU_SUSFS\nint ksu_handle_faccessat(int *dfd, struct filename **filename' in h:
        h = h.replace(
            '#ifdef CONFIG_KSU_SUSFS\nint ksu_handle_faccessat(int *dfd, struct filename **filename',
            '#if 0 /* 4.14 user-pointer sucompat */\nint ksu_handle_faccessat(int *dfd, struct filename **filename',
        )
    h = re.sub(
        r'int ksu_handle_faccessat\s*\(\s*int \*dfd,\s*struct filename \*\*filename,\s*int \*mode,\s*int \*\w+\s*\)\s*;',
        'int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *__unused_flags);',
        h,
        flags=re.S,
    )
    h = re.sub(
        r'int ksu_handle_stat\s*\(\s*int \*dfd,\s*struct filename \*\*filename,\s*int \*flags\s*\)\s*;',
        'int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);',
        h,
        flags=re.S,
    )
    path.write_text(h)
    print('updated', path, flush=True)


def enable_allow_shell():
    targets = [
        Path('KernelSU/kernel/core/init.c'),
        Path('drivers/kernelsu/core/init.c'),
        Path('KernelSU/kernel/init.c'),
        Path('drivers/kernelsu/init.c'),
        Path('KernelSU/kernel/ksu.c'),
        Path('drivers/kernelsu/ksu.c'),
    ]
    for p in targets:
        if not p.is_file():
            continue
        it = p.read_text()
        it2 = re.sub(
            r'#ifdef CONFIG_KSU_DEBUG\s*\nbool allow_shell = true;\s*\n#else\s*\nbool allow_shell = false;\s*\n#endif',
            'bool allow_shell = true; /* enabled for adb shell su */',
            it,
        )
        it2 = re.sub(
            r'bool allow_shell = IS_ENABLED\(CONFIG_KSU_DEBUG\);',
            'bool allow_shell = true; /* enabled for adb shell su */',
            it2,
        )
        if 'bool allow_shell = false;' in it2:
            it2 = it2.replace('bool allow_shell = false;', 'bool allow_shell = true;')
        if it2 != it:
            p.write_text(it2)
            print(f'{p}: set allow_shell = true for adb shell su', flush=True)


for cpath in uniq:
    adapt_c(cpath)
    adapt_h(cpath.with_suffix('.h'))

enable_allow_shell()

print('[PASS] sucompat kept on 4.14 user-pointer ABI with valid userspace stack paths and allow_shell=true', flush=True)
PY

echo '[PASS] ReSukiSU/SukiSU sucompat aligned to 4.14 user_path_at hooks and adb shell enabled'
