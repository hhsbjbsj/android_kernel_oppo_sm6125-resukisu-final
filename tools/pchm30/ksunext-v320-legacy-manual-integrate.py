#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
KSU = ROOT / "KernelSU-Next" / "kernel"


def replace_once(path: Path, old: str, new: str):
    text = path.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path.relative_to(ROOT)}: expected exactly one match, found {count}")
    path.write_text(text.replace(old, new, 1))
    print(f"[PATCHED] {path.relative_to(ROOT)}")


# ---------------------------------------------------------------------------
# KernelSU-Next v3.2.0-legacy compatibility: PCHM30 must retain the exact
# stock Linux 4.14 seccomp ABI.  KSU Next already has a native <5.9 path in
# policy/app_profile.c which uses put_seccomp_filter(current), so do NOT let
# Kbuild mutate include/linux/seccomp.h by adding filter_count.
# ---------------------------------------------------------------------------
kbuild = KSU / "Kbuild"
seccomp_autopatch = '''ifneq ($(shell grep -q "atomic_t filter_count;" $(srctree)/include/linux/seccomp.h; echo $$?),0)
$(info -- KSU_NEXT: patching struct seccomp for filter_count)
$(shell sed -i '/int mode;/a\\\tatomic_t filter_count;' $(srctree)/include/linux/seccomp.h)
$(shell sed -i '/#include <linux\\/thread_info.h>/a\\#include <linux/atomic.h>' $(srctree)/include/linux/seccomp.h)
endif
'''
replace_once(
    kbuild,
    seccomp_autopatch,
    '''# PCHM30 Linux 4.14 ABI guard: never add filter_count to struct seccomp.
# policy/app_profile.c uses put_seccomp_filter(current) on native <5.9 kernels.
$(info -- KSU_NEXT: PCHM30 stock seccomp ABI preserved; filter_count autopatch disabled)
''',
)

# ---------------------------------------------------------------------------
# Official KernelSU Next non-GKI manual integration points, adapted to the
# actual v3.2.0-legacy function signatures.  Keep the hook surface exactly to
# exec/open/read/stat/reboot.  No input_event hook, no SUSFS hooks.
# ---------------------------------------------------------------------------

# fs/exec.c: native execve wrapper.
exec_c = ROOT / "fs/exec.c"
old = '''int do_execve(struct filename *filename,
	const char __user *const __user *__argv,
	const char __user *const __user *__envp)
{
	struct user_arg_ptr argv = { .ptr.native = __argv };
	struct user_arg_ptr envp = { .ptr.native = __envp };
	return do_execveat_common(AT_FDCWD, filename, argv, envp, 0);
}
'''
new = '''#if defined(CONFIG_KSU) && defined(CONFIG_KSU_MANUAL_HOOK)
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
#if defined(CONFIG_KSU) && defined(CONFIG_KSU_MANUAL_HOOK)
	ksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0);
#endif
	return do_execveat_common(AT_FDCWD, filename, argv, envp, 0);
}
'''
replace_once(exec_c, old, new)

# fs/exec.c: 32-bit compat execve path (Android 32-on-64 support).
old = '''static int compat_do_execve(struct filename *filename,
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
'''
new = '''static int compat_do_execve(struct filename *filename,
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
#if defined(CONFIG_KSU) && defined(CONFIG_KSU_MANUAL_HOOK)
	ksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0);
#endif
	return do_execveat_common(AT_FDCWD, filename, argv, envp, 0);
}
'''
replace_once(exec_c, old, new)

# fs/open.c: faccessat / sucompat.
open_c = ROOT / "fs/open.c"
old = '''/*
 * access() needs to use the real uid/gid, not the effective uid/gid.
 * We do this by temporarily clearing all FS-related capabilities and
 * switching the fsuid/fsgid around to the real ones.
 */
SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)
{
	const struct cred *old_cred;
'''
new = '''#if defined(CONFIG_KSU) && defined(CONFIG_KSU_MANUAL_HOOK)
__attribute__((hot))
extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user,
			       int *mode, int *flags);
#endif

/*
 * access() needs to use the real uid/gid, not the effective uid/gid.
 * We do this by temporarily clearing all FS-related capabilities and
 * switching the fsuid/fsgid around to the real ones.
 */
SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)
{
#if defined(CONFIG_KSU) && defined(CONFIG_KSU_MANUAL_HOOK)
	ksu_handle_faccessat(&dfd, &filename, &mode, NULL);
#endif
	const struct cred *old_cred;
'''
replace_once(open_c, old, new)

# fs/read_write.c: v3.2.0-legacy changed this handler to fd-only and proxies
# init.rc file_operations internally.  Do not use the obsolete 3-argument hook.
read_c = ROOT / "fs/read_write.c"
old = '''SYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)
{
	struct fd f = fdget_pos(fd);
	ssize_t ret = -EBADF;
'''
new = '''#if defined(CONFIG_KSU) && defined(CONFIG_KSU_MANUAL_HOOK)
extern bool ksu_vfs_read_hook __read_mostly;
extern __attribute__((cold)) void ksu_handle_sys_read(unsigned int fd);
#endif

SYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)
{
	struct fd f = fdget_pos(fd);
	ssize_t ret = -EBADF;
#if defined(CONFIG_KSU) && defined(CONFIG_KSU_MANUAL_HOOK)
	if (unlikely(ksu_vfs_read_hook))
		ksu_handle_sys_read(fd);
#endif
'''
replace_once(read_c, old, new)

# fs/stat.c: newfstatat / sucompat.
stat_c = ROOT / "fs/stat.c"
old = '''#if !defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_SYS_NEWFSTATAT)
SYSCALL_DEFINE4(newfstatat, int, dfd, const char __user *, filename,
		struct stat __user *, statbuf, int, flag)
{
	struct kstat stat;
	int error;

	error = vfs_fstatat(dfd, filename, &stat, flag);
'''
new = '''#if defined(CONFIG_KSU) && defined(CONFIG_KSU_MANUAL_HOOK)
__attribute__((hot))
extern int ksu_handle_stat(int *dfd, const char __user **filename_user,
			   int *flags);
#endif

#if !defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_SYS_NEWFSTATAT)
SYSCALL_DEFINE4(newfstatat, int, dfd, const char __user *, filename,
		struct stat __user *, statbuf, int, flag)
{
	struct kstat stat;
	int error;

#if defined(CONFIG_KSU) && defined(CONFIG_KSU_MANUAL_HOOK)
	ksu_handle_stat(&dfd, &filename, &flag);
#endif
	error = vfs_fstatat(dfd, filename, &stat, flag);
'''
replace_once(stat_c, old, new)

# kernel/reboot.c: supercall transport used by manager/driver handshake.
reboot_c = ROOT / "kernel/reboot.c"
old = '''/*
 * Reboot system call: for obvious reasons only root may call it,
 * and even root needs to set up some magic numbers in the registers
 * so that some mistake won't make this reboot the whole machine.
 *
 * reboot doesn't sync: do that yourself before calling this.
 */
SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,
		void __user *, arg)
{
	struct pid_namespace *pid_ns = task_active_pid_ns(current);
	char buffer[256];
	int ret = 0;

	/* We only trust the superuser with rebooting the system. */
'''
new = '''/*
 * Reboot system call: for obvious reasons only root may call it,
 * and even root needs to set up some magic numbers in the registers
 * so that some mistake won't make this reboot the whole machine.
 *
 * reboot doesn't sync: do that yourself before calling this.
 */
#if defined(CONFIG_KSU) && defined(CONFIG_KSU_MANUAL_HOOK)
extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd,
				 void __user **arg);
#endif

SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,
		void __user *, arg)
{
	struct pid_namespace *pid_ns = task_active_pid_ns(current);
	char buffer[256];
	int ret = 0;

#if defined(CONFIG_KSU) && defined(CONFIG_KSU_MANUAL_HOOK)
	ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
#endif
	/* We only trust the superuser with rebooting the system. */
'''
replace_once(reboot_c, old, new)

# Hard safety checks: this experiment is deliberately no-SUSFS and keeps the
# device ABI untouched.
seccomp_h = (ROOT / "include/linux/seccomp.h").read_text()
if "filter_count" in seccomp_h:
    raise SystemExit("FATAL: PCHM30 stock seccomp ABI contains filter_count")

for rel, needle in [
    ("fs/exec.c", "ksu_handle_execveat"),
    ("fs/open.c", "ksu_handle_faccessat"),
    ("fs/read_write.c", "ksu_handle_sys_read(fd);"),
    ("fs/stat.c", "ksu_handle_stat"),
    ("kernel/reboot.c", "ksu_handle_sys_reboot"),
]:
    if needle not in (ROOT / rel).read_text():
        raise SystemExit(f"FATAL: missing required manual hook: {rel}: {needle}")

if "ksu_handle_input_handle_event" in (ROOT / "drivers/input/input.c").read_text():
    raise SystemExit("FATAL: old experimental KSU input_event hook leaked into clean baseline")

print("[PASS] KernelSU-Next v3.2.0-legacy official five-point manual hooks installed")
print("[PASS] no input_event experimental hook")
print("[PASS] no SUSFS integration")
print("[PASS] stock PCHM30 seccomp ABI preserved; KSU filter_count autopatch disabled")
