#!/usr/bin/env python3
"""Apply the pinned ReSukiSU 4.14 manual hooks to OPPO's exact SM6125 tree."""

from pathlib import Path
import sys


def fail(message: str) -> None:
    raise SystemExit(f"[错误] {message}")


if len(sys.argv) != 2:
    fail("用法：apply-resukisu-hooks.py /path/to/msm-4.14")

root = Path(sys.argv[1]).resolve()
if not (root / "Makefile").is_file() or not (root / "Kconfig").is_file():
    fail(f"不是内核根目录：{root}")


def replace_once(relative: str, old: str, new: str) -> None:
    path = root / relative
    text = path.read_text()
    count = text.count(old)
    if count != 1:
        fail(f"{relative} 的官方锚点数量应为 1，实际为 {count}；拒绝猜测修改")
    path.write_text(text.replace(old, new, 1))


for relative in ("fs/exec.c", "fs/open.c", "fs/stat.c", "kernel/reboot.c"):
    text = (root / relative).read_text()
    if "ksu_handle_" in text:
        fail(f"{relative} 已含 KSU hook；本脚本只接受 OPPO 官方干净文件")


replace_once(
    "fs/exec.c",
    """int do_execve(struct filename *filename,
	const char __user *const __user *__argv,
	const char __user *const __user *__envp)
{
	struct user_arg_ptr argv = { .ptr.native = __argv };
	struct user_arg_ptr envp = { .ptr.native = __envp };
	return do_execveat_common(AT_FDCWD, filename, argv, envp, 0);
}
""",
    """#ifdef CONFIG_KSU_MANUAL_HOOK
__attribute__((hot))
extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,
				void *argv, void *envp, int *flags);
#endif

int do_execve(struct filename *filename,
	const char __user *const __user *__argv,
	const char __user *const __user *__envp)
{
	struct user_arg_ptr argv = { .ptr.native = __argv };
	struct user_arg_ptr envp = { .ptr.native = __envp };
#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0);
#endif
	return do_execveat_common(AT_FDCWD, filename, argv, envp, 0);
}
""",
)

replace_once(
    "fs/exec.c",
    """static int compat_do_execve(struct filename *filename,
	const compat_uptr_t __user *__argv,
	const compat_uptr_t __user *__envp)
{
	struct user_arg_ptr argv = {
		.is_compat = true,
		.ptr.compat = __argv,
	};
	struct user_arg_ptr envp = {
		.is_compat = true,
		.ptr.compat = __envp,
	};
	return do_execveat_common(AT_FDCWD, filename, argv, envp, 0);
}
""",
    """static int compat_do_execve(struct filename *filename,
	const compat_uptr_t __user *__argv,
	const compat_uptr_t __user *__envp)
{
	struct user_arg_ptr argv = {
		.is_compat = true,
		.ptr.compat = __argv,
	};
	struct user_arg_ptr envp = {
		.is_compat = true,
		.ptr.compat = __envp,
	};
#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0);
#endif
	return do_execveat_common(AT_FDCWD, filename, argv, envp, 0);
}
""",
)

replace_once(
    "fs/open.c",
    """/*
 * access() needs to use the real uid/gid, not the effective uid/gid.
""",
    """#ifdef CONFIG_KSU_MANUAL_HOOK
__attribute__((hot))
extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user,
				int *mode, int *flags);
#endif

/*
 * access() needs to use the real uid/gid, not the effective uid/gid.
""",
)

replace_once(
    "fs/open.c",
    """	int res;
	unsigned int lookup_flags = LOOKUP_FOLLOW;

	if (mode & ~S_IRWXO)	/* where's F_OK, X_OK, W_OK, R_OK? */
""",
    """	int res;
	unsigned int lookup_flags = LOOKUP_FOLLOW;

#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_faccessat(&dfd, &filename, &mode, NULL);
#endif

	if (mode & ~S_IRWXO)	/* where's F_OK, X_OK, W_OK, R_OK? */
""",
)

replace_once(
    "fs/stat.c",
    """#if !defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_SYS_NEWFSTATAT)
SYSCALL_DEFINE4(newfstatat, int, dfd, const char __user *, filename,
""",
    """#ifdef CONFIG_KSU_MANUAL_HOOK
__attribute__((hot))
extern int ksu_handle_stat(int *dfd, const char __user **filename_user,
				int *flags);
extern void ksu_handle_newfstat_ret(unsigned int *fd,
				struct stat __user **statbuf_ptr);
#if defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_COMPAT_STAT64)
extern void ksu_handle_fstat64_ret(unsigned long *fd,
				struct stat64 __user **statbuf_ptr);
#endif
#endif

#if !defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_SYS_NEWFSTATAT)
SYSCALL_DEFINE4(newfstatat, int, dfd, const char __user *, filename,
""",
)

replace_once(
    "fs/stat.c",
    """	struct kstat stat;
	int error;

	error = vfs_fstatat(dfd, filename, &stat, flag);
	if (error)
		return error;
	return cp_new_stat(&stat, statbuf);
}
#endif
""",
    """	struct kstat stat;
	int error;

#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_stat(&dfd, &filename, &flag);
#endif
	error = vfs_fstatat(dfd, filename, &stat, flag);
	if (error)
		return error;
	return cp_new_stat(&stat, statbuf);
}
#endif
""",
)

replace_once(
    "fs/stat.c",
    """SYSCALL_DEFINE2(newfstat, unsigned int, fd, struct stat __user *, statbuf)
{
	struct kstat stat;
	int error = vfs_fstat(fd, &stat);

	if (!error)
		error = cp_new_stat(&stat, statbuf);

	return error;
}
""",
    """SYSCALL_DEFINE2(newfstat, unsigned int, fd, struct stat __user *, statbuf)
{
	struct kstat stat;
	int error = vfs_fstat(fd, &stat);

	if (!error)
		error = cp_new_stat(&stat, statbuf);

#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_newfstat_ret(&fd, &statbuf);
#endif
	return error;
}
""",
)

replace_once(
    "fs/stat.c",
    """SYSCALL_DEFINE2(fstat64, unsigned long, fd, struct stat64 __user *, statbuf)
{
	struct kstat stat;
	int error = vfs_fstat(fd, &stat);

	if (!error)
		error = cp_new_stat64(&stat, statbuf);

	return error;
}
""",
    """SYSCALL_DEFINE2(fstat64, unsigned long, fd, struct stat64 __user *, statbuf)
{
	struct kstat stat;
	int error = vfs_fstat(fd, &stat);

	if (!error)
		error = cp_new_stat64(&stat, statbuf);

#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_fstat64_ret(&fd, &statbuf);
#endif
	return error;
}
""",
)

replace_once(
    "fs/stat.c",
    """SYSCALL_DEFINE4(fstatat64, int, dfd, const char __user *, filename,
		struct stat64 __user *, statbuf, int, flag)
{
	struct kstat stat;
	int error;

	error = vfs_fstatat(dfd, filename, &stat, flag);
""",
    """SYSCALL_DEFINE4(fstatat64, int, dfd, const char __user *, filename,
		struct stat64 __user *, statbuf, int, flag)
{
	struct kstat stat;
	int error;

#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_stat(&dfd, &filename, &flag);
#endif
	error = vfs_fstatat(dfd, filename, &stat, flag);
""",
)

replace_once(
    "kernel/reboot.c",
    """SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,
		void __user *, arg)
""",
    """#ifdef CONFIG_KSU_MANUAL_HOOK
extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd,
				void __user **arg);
#endif

SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,
		void __user *, arg)
""",
)

replace_once(
    "kernel/reboot.c",
    """	char buffer[256];
	int ret = 0;

	/* We only trust the superuser with rebooting the system. */
""",
    """	char buffer[256];
	int ret = 0;

#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
#endif

	/* We only trust the superuser with rebooting the system. */
""",
)

expected_counts = {
    "fs/exec.c": {"ksu_handle_execveat": 3},
    "fs/open.c": {"ksu_handle_faccessat": 2},
    "fs/stat.c": {
        "ksu_handle_stat": 3,
        "ksu_handle_newfstat_ret": 2,
        "ksu_handle_fstat64_ret": 2,
    },
    "kernel/reboot.c": {"ksu_handle_sys_reboot": 2},
}
for relative, symbols in expected_counts.items():
    text = (root / relative).read_text()
    for symbol, expected in symbols.items():
        actual = text.count(symbol)
        if actual != expected:
            fail(f"{relative}: {symbol} 应出现 {expected} 次，实际 {actual} 次")

print("[确认] ReSukiSU 4.14 手动 Hook 已按固定锚点应用并通过数量校验。")
