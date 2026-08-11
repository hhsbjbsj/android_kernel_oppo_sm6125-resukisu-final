#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def replace_once(rel, old, new):
    p = ROOT / rel
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{rel}: expected exactly one match, found {count}")
    p.write_text(text.replace(old, new, 1))
    print(f"[PATCHED] {rel}")


# KernelSU-Next v1.1.1 min/manual syscall hooks, adapted to OPPO PCHM30 4.14.
replace_once(
    "fs/exec.c",
    "SYSCALL_DEFINE3(execve,\n\t\tconst char __user *, filename,\n\t\tconst char __user *const __user *, argv,\n\t\tconst char __user *const __user *, envp)\n{\n\treturn do_execve(getname(filename), argv, envp);\n}\n",
    "#if defined(CONFIG_KSU) && !defined(CONFIG_KSU_KPROBES_HOOK)\n"
    "extern bool ksu_execveat_hook __read_mostly;\n"
    "extern int ksu_handle_execve_sucompat(int *fd, const char __user **filename_user,\n"
    "\t\t\t       void *__never_use_argv, void *__never_use_envp,\n"
    "\t\t\t       int *__never_use_flags);\n"
    "extern int ksu_handle_execve_ksud(const char __user *filename_user,\n"
    "\t\t\tconst char __user *const __user *__argv);\n"
    "#endif\n\n"
    "SYSCALL_DEFINE3(execve,\n\t\tconst char __user *, filename,\n\t\tconst char __user *const __user *, argv,\n\t\tconst char __user *const __user *, envp)\n{\n"
    "#if defined(CONFIG_KSU) && !defined(CONFIG_KSU_KPROBES_HOOK)\n"
    "\tif (unlikely(ksu_execveat_hook))\n"
    "\t\tksu_handle_execve_ksud(filename, argv);\n"
    "\telse\n"
    "\t\tksu_handle_execve_sucompat((int *)AT_FDCWD, &filename, NULL, NULL, NULL);\n"
    "#endif\n"
    "\treturn do_execve(getname(filename), argv, envp);\n}\n",
)

replace_once(
    "fs/exec.c",
    "COMPAT_SYSCALL_DEFINE3(execve, const char __user *, filename,\n\tconst compat_uptr_t __user *, argv,\n\tconst compat_uptr_t __user *, envp)\n{\n\treturn compat_do_execve(getname(filename), argv, envp);\n}\n",
    "COMPAT_SYSCALL_DEFINE3(execve, const char __user *, filename,\n\tconst compat_uptr_t __user *, argv,\n\tconst compat_uptr_t __user *, envp)\n{\n"
    "#if defined(CONFIG_KSU) && !defined(CONFIG_KSU_KPROBES_HOOK)\n"
    "\tif (!ksu_execveat_hook)\n"
    "\t\tksu_handle_execve_sucompat((int *)AT_FDCWD, &filename, NULL, NULL, NULL);\n"
    "#endif\n"
    "\treturn compat_do_execve(getname(filename), argv, envp);\n}\n",
)

replace_once(
    "fs/open.c",
    "SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)\n{\n\tconst struct cred *old_cred;\n",
    "#if defined(CONFIG_KSU) && !defined(CONFIG_KSU_KPROBES_HOOK)\n"
    "extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *flags);\n"
    "#endif\n\n"
    "SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)\n{\n"
    "#if defined(CONFIG_KSU) && !defined(CONFIG_KSU_KPROBES_HOOK)\n"
    "\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n"
    "#endif\n"
    "\tconst struct cred *old_cred;\n",
)

replace_once(
    "fs/stat.c",
    "#if !defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_SYS_NEWFSTATAT)\nSYSCALL_DEFINE4(newfstatat, int, dfd, const char __user *, filename,\n\t\tstruct stat __user *, statbuf, int, flag)\n{\n\tstruct kstat stat;\n\tint error;\n\n\terror = vfs_fstatat(dfd, filename, &stat, flag);\n",
    "#if defined(CONFIG_KSU) && !defined(CONFIG_KSU_KPROBES_HOOK)\n"
    "extern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n"
    "#endif\n\n"
    "#if !defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_SYS_NEWFSTATAT)\nSYSCALL_DEFINE4(newfstatat, int, dfd, const char __user *, filename,\n\t\tstruct stat __user *, statbuf, int, flag)\n{\n\tstruct kstat stat;\n\tint error;\n\n"
    "#if defined(CONFIG_KSU) && !defined(CONFIG_KSU_KPROBES_HOOK)\n"
    "\tksu_handle_stat(&dfd, &filename, &flag);\n"
    "#endif\n"
    "\terror = vfs_fstatat(dfd, filename, &stat, flag);\n",
)

replace_once(
    "fs/stat.c",
    "SYSCALL_DEFINE4(fstatat64, int, dfd, const char __user *, filename,\n\t\tstruct stat64 __user *, statbuf, int, flag)\n{\n\tstruct kstat stat;\n\tint error;\n\n\terror = vfs_fstatat(dfd, filename, &stat, flag);\n",
    "SYSCALL_DEFINE4(fstatat64, int, dfd, const char __user *, filename,\n\t\tstruct stat64 __user *, statbuf, int, flag)\n{\n\tstruct kstat stat;\n\tint error;\n\n"
    "#if defined(CONFIG_KSU) && defined(CONFIG_COMPAT) && !defined(CONFIG_KSU_KPROBES_HOOK)\n"
    "\tksu_handle_stat(&dfd, &filename, &flag);\n"
    "#endif\n"
    "\terror = vfs_fstatat(dfd, filename, &stat, flag);\n",
)

replace_once(
    "fs/read_write.c",
    "SYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)\n{\n\tstruct fd f = fdget_pos(fd);\n",
    "#if defined(CONFIG_KSU) && !defined(CONFIG_KSU_KPROBES_HOOK)\n"
    "extern bool ksu_vfs_read_hook __read_mostly;\n"
    "extern int ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr, size_t *count_ptr);\n"
    "#endif\n\n"
    "SYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)\n{\n"
    "#if defined(CONFIG_KSU) && !defined(CONFIG_KSU_KPROBES_HOOK)\n"
    "\tif (unlikely(ksu_vfs_read_hook))\n"
    "\t\tksu_handle_sys_read(fd, &buf, &count);\n"
    "#endif\n"
    "\tstruct fd f = fdget_pos(fd);\n",
)

replace_once(
    "drivers/input/input.c",
    "void input_event(struct input_dev *dev,\n\t\t unsigned int type, unsigned int code, int value)\n{\n\tunsigned long flags;\n\n\tif (is_event_supported(type, dev->evbit, EV_MAX)) {\n",
    "#if defined(CONFIG_KSU) && !defined(CONFIG_KSU_KPROBES_HOOK)\n"
    "extern bool ksu_input_hook __read_mostly;\n"
    "extern int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value);\n"
    "#endif\n\n"
    "void input_event(struct input_dev *dev,\n\t\t unsigned int type, unsigned int code, int value)\n{\n\tunsigned long flags;\n\n"
    "#if defined(CONFIG_KSU) && !defined(CONFIG_KSU_KPROBES_HOOK)\n"
    "\tif (unlikely(ksu_input_hook))\n"
    "\t\tksu_handle_input_handle_event(&type, &code, &value);\n"
    "#endif\n\n"
    "\tif (is_event_supported(type, dev->evbit, EV_MAX)) {\n",
)

# PCHM30 must keep its stock Linux 4.14 struct seccomp ABI.  Adapt KSU Next,
# never the device ABI: use the native put_seccomp_filter(task) lifecycle.
replace_once(
    "KernelSU-Next/kernel/core_hook.c",
    "#include <linux/sched.h>\n#include <linux/security.h>\n",
    "#include <linux/sched.h>\n#include <linux/seccomp.h>\n#include <linux/security.h>\n",
)
replace_once(
    "KernelSU-Next/kernel/core_hook.c",
    "\tcurrent->seccomp.mode = 0;\n\tcurrent->seccomp.filter = NULL;\n\tatomic_set(&current->seccomp.filter_count, 0);\n",
    "\tcurrent->seccomp.mode = 0;\n\tput_seccomp_filter(current);\n\tcurrent->seccomp.filter = NULL;\n",
)

# Strong safety checks.
seccomp = (ROOT / "include/linux/seccomp.h").read_text()
if "filter_count" in seccomp:
    raise SystemExit("FATAL: stock PCHM30 seccomp ABI was modified with filter_count")

print("[PASS] PCHM30 KernelSU-Next v1.1.1 min manual hooks installed")
print("[PASS] stock seccomp ABI preserved; no filter_count added")
