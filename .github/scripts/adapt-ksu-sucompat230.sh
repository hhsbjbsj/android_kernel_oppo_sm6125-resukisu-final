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
		pr_err("ksu_handle_faccessat: su found but NOT allowed! Because current process is running in chrooted environment\n");
		return 0;
	}
	pr_info("ksu_handle_faccessat: su->sh!\n");
	*filename_user = sh_user_path();
	return 0;
}'''

FA_USER_SU = FA_USER.replace('su_path', 'su')


def pick_names(text):
    if re.search(r'\bsu_path\b', text):
        return 'su_path', FA_USER
    return 'su', FA_USER_SU


def adapt_c(path: Path):
    t = path.read_text()
    changed = []
    su_name, fa_body = pick_names(t)

    # In ReSukiSU, disable the GKI struct filename ** handler so that the 4.14
    # const char __user **filename_user handler with sh_user_path() in the #else branch is compiled.
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

    fa_fn = re.compile(
        r'int ksu_handle_faccessat\s*\(\s*int \*dfd,\s*(?:struct filename \*\*filename|const char __user \*\*filename_user),\s*int \*mode,\s*int \*\w+\s*\)\s*\{.*?\n\}',
        re.S,
    )
    m = fa_fn.search(t)
    if m and 'struct filename **filename' in m.group(0):
        t = t[:m.start()] + fa_body + t[m.end():]
        changed.append('faccessat: installed 4.14 user-pointer handler')

    t2, n = re.subn(
        r'int ksu_handle_stat\s*\(\s*int \*dfd,\s*struct filename \*\*filename,\s*int \*flags\s*\)',
        'int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags)',
        t,
    )
    if n:
        t = t2
        changed.append('stat proto rewritten to user-pointer x%d' % n)
        t = t.replace('(*filename)->name', 'ksu_stat_user_path')
        if 'ksu_stat_user_path' in t and 'filename_user' in t:
            stat_user = '''int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags)
{
	char path[sizeof(%s) + 1] = { 0 };

	if (unlikely(!filename_user || !*filename_user))
		return 0;
	if (ksu_strncpy_from_user_nofault(path, *filename_user, sizeof(path)) < 0)
		return 0;
	if (likely(memcmp(path, %s, sizeof(%s))))
		return 0;
	*filename_user = sh_user_path();
	return 0;
}''' % (su_name, su_name, su_name)
            t = re.sub(
                r'int ksu_handle_stat\s*\(\s*int \*dfd,\s*const char __user \*\*filename_user,\s*int \*flags\s*\)\s*\{.*?\n\}',
                stat_user,
                t,
                count=1,
                flags=re.S,
            )
            changed.append('stat: installed 4.14 user-pointer handler')

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
    h = re.sub(
        r'#ifdef CONFIG_KSU_SUSFS\s*\nint ksu_handle_faccessat\(int \*dfd, struct filename \*\*filename, int \*mode, int \*\w+\);\s*\nint ksu_handle_stat\(int \*dfd, struct filename \*\*filename, int \*flags\);',
        '#if 0 /* 4.14 user_path_at sucompat ABI */\nint ksu_handle_faccessat(int *dfd, struct filename **filename, int *mode, int *__unused_flags);\nint ksu_handle_stat(int *dfd, struct filename **filename, int *flags);\n#else\nint ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *__unused_flags);\nint ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);',
        h
    )
    h = h.replace(
        'int ksu_handle_faccessat(int *dfd, struct filename **filename, int *mode, int *__unused_flags);',
        'int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *__unused_flags);',
    )
    h = h.replace(
        'int ksu_handle_stat(int *dfd, struct filename **filename, int *flags);',
        'int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);',
    )
    path.write_text(h)
    print('updated', path, flush=True)


def enable_allow_shell():
    init_paths = [
        Path('KernelSU/kernel/core/init.c'),
        Path('drivers/kernelsu/core/init.c'),
        Path('KernelSU/kernel/init.c'),
        Path('drivers/kernelsu/init.c'),
    ]
    for p in init_paths:
        if not p.is_file():
            continue
        it = p.read_text()
        it2 = re.sub(
            r'#ifdef CONFIG_KSU_DEBUG\s*\nbool allow_shell = true;\s*\n#else\s*\nbool allow_shell = false;\s*\n#endif',
            'bool allow_shell = true; /* enabled for adb shell su */',
            it
        )
        if it2 != it:
            p.write_text(it2)
            print(f'{p}: set allow_shell = true for adb shell su', flush=True)
        elif 'bool allow_shell = false;' in it:
            it2 = it.replace('bool allow_shell = false;', 'bool allow_shell = true;')
            p.write_text(it2)
            print(f'{p}: replaced allow_shell false -> true', flush=True)


for cpath in uniq:
    adapt_c(cpath)
    adapt_h(cpath.with_suffix('.h'))

enable_allow_shell()

print('[PASS] sucompat kept on 4.14 user-pointer ABI with valid userspace stack paths and allow_shell=true', flush=True)
PY

echo '[PASS] ReSukiSU/SukiSU sucompat aligned to 4.14 user_path_at hooks and adb shell enabled'
