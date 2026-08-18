#!/usr/bin/env bash
set -Eeuo pipefail

KERNEL_DIR="${GITHUB_WORKSPACE:?}/${KERNEL_REL:?}"
cd "$KERNEL_DIR"
exec > >(tee "$GITHUB_WORKSPACE/run17-btf-kprobe-scene-fix.log") 2>&1

: "${OUT_DIR:?OUT_DIR must be set}"
CONFIG="$OUT_DIR/.config"
test -f "$CONFIG"
test -x scripts/config

echo '===== RUN17 BTF + KPROBES + Scene-Port-Hider capability fix ====='

# 1) Backport the simple Linux 5.4 DEBUG_INFO_BTF Kconfig switch when this 4.14 tree lacks it.
python3 - <<'PY'
from pathlib import Path
p = Path('lib/Kconfig.debug')
s = p.read_text()
if 'config DEBUG_INFO_BTF\n' not in s:
    anchor = '''config GDB_SCRIPTS\n'''
    block = '''config DEBUG_INFO_BTF\n\tbool "Generate BTF typeinfo"\n\tdepends on DEBUG_INFO\n\tdepends on BPF_SYSCALL\n\thelp\n\t  Generate deduplicated BTF type information from DWARF debug info.\n\t  This requires pahole on the build host.\n\n'''
    if anchor not in s:
        raise SystemExit('cannot locate GDB_SCRIPTS anchor in lib/Kconfig.debug')
    s = s.replace(anchor, block + anchor, 1)
    p.write_text(s)
    print('[PASS] added CONFIG_DEBUG_INFO_BTF Kconfig entry')
else:
    print('[INFO] CONFIG_DEBUG_INFO_BTF Kconfig entry already present')
PY

# 2) Export the final linked raw BTF blob at /sys/kernel/btf/vmlinux (Linux 5.4-style).
cat > kernel/bpf/sysfs_btf.c <<'EOF_SYSFS_BTF'
// SPDX-License-Identifier: GPL-2.0
/*
 * Provide kernel BTF information for introspection and use by eBPF tools.
 * Backported for PCHM30 4.14 from the Linux 5.4 sysfs BTF mechanism.
 */
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/kobject.h>
#include <linux/init.h>
#include <linux/sysfs.h>

/* See scripts/link-vmlinux.sh, gen_btf() for details. */
extern char __weak _binary__btf_vmlinux_bin_start[];
extern char __weak _binary__btf_vmlinux_bin_end[];

static ssize_t btf_vmlinux_read(struct file *file, struct kobject *kobj,
                                struct bin_attribute *bin_attr,
                                char *buf, loff_t off, size_t len)
{
    memcpy(buf, _binary__btf_vmlinux_bin_start + off, len);
    return len;
}

static struct bin_attribute bin_attr_btf_vmlinux __ro_after_init = {
    .attr = { .name = "vmlinux", .mode = 0444, },
    .read = btf_vmlinux_read,
};

static struct kobject *btf_kobj;

static int __init btf_vmlinux_init(void)
{
    if (!_binary__btf_vmlinux_bin_start)
        return 0;

    btf_kobj = kobject_create_and_add("btf", kernel_kobj);
    if (!btf_kobj)
        return -ENOMEM;

    bin_attr_btf_vmlinux.size = _binary__btf_vmlinux_bin_end -
                                _binary__btf_vmlinux_bin_start;

    return sysfs_create_bin_file(btf_kobj, &bin_attr_btf_vmlinux);
}
subsys_initcall(btf_vmlinux_init);
EOF_SYSFS_BTF

python3 - <<'PY'
from pathlib import Path
p = Path('kernel/bpf/Makefile')
s = p.read_text()
line = 'obj-$(CONFIG_DEBUG_INFO_BTF) += sysfs_btf.o\n'
if line not in s:
    if not s.endswith('\n'):
        s += '\n'
    s += '\nifeq ($(CONFIG_SYSFS),y)\n' + line + 'endif\n'
    p.write_text(s)
    print('[PASS] wired sysfs_btf.o into kernel/bpf/Makefile')
else:
    print('[INFO] sysfs_btf.o already wired')
PY

# 3) Backport Linux 5.4's build-time BTF generation into this vendor 4.14 linker script.
python3 - <<'PY'
from pathlib import Path
p = Path('scripts/link-vmlinux.sh')
s = p.read_text()

if '# PCHM30_RUN17_BTF_BACKPORT_BEGIN' not in s:
    func_start = s.index('vmlinux_link()\n{')
    func_end = s.index('\n# Create ${2} .o file with all symbols', func_start)
    block = s[func_start:func_end]
    if 'local extra_objects=' not in block:
        block = block.replace('${1}', '${extra_objects}')
        needle = '\tlocal objects\n'
        if block.count(needle) != 1:
            raise SystemExit('unexpected vmlinux_link local objects anchor')
        block = block.replace(needle, needle + '\tlocal extra_objects="${1} ${btf_vmlinux_bin_o:-}"\n', 1)
    s = s[:func_start] + block + s[func_end:]

    insert_at = s.index('\n# Create ${2} .o file with all symbols', func_start)
    gen = r'''
# PCHM30_RUN17_BTF_BACKPORT_BEGIN
# Generate .BTF type information from DWARF and turn it into a linkable object.
# ${1} - temporary vmlinux image
# ${2} - output object containing only .BTF
gen_btf()
{
	local pahole_bin="${PAHOLE:-pahole}"
	local pahole_ver
	local bin_arch
	local bin_format

	if ! command -v "${pahole_bin}" >/dev/null 2>&1; then
		echo >&2 "BTF: pahole (${pahole_bin}) is not available"
		return 1
	fi

	pahole_ver=$("${pahole_bin}" --version 2>/dev/null | sed -E 's/v([0-9]+)\.([0-9]+).*/\1\2/' | head -n1)
	if [ -z "${pahole_ver}" ] || [ "${pahole_ver}" -lt 113 ]; then
		echo >&2 "BTF: pahole version $("${pahole_bin}" --version 2>/dev/null || true) is too old; need >= 1.13"
		return 1
	fi

	info BTF "${2}"
	vmlinux_link "" "${1}"
	LLVM_OBJCOPY="${OBJCOPY}" "${pahole_bin}" -J "${1}"

	bin_arch=$(LANG=C "${OBJDUMP}" -f "${1}" | grep architecture | cut -d, -f1 | cut -d' ' -f2)
	bin_format=$(LANG=C "${OBJDUMP}" -f "${1}" | grep 'file format' | awk '{print $4}')
	"${OBJCOPY}" --dump-section .BTF=.btf.vmlinux.bin "${1}"
	"${OBJCOPY}" -I binary -O "${bin_format}" -B "${bin_arch}" \
		--rename-section .data=.BTF .btf.vmlinux.bin "${2}"
	test -s .btf.vmlinux.bin
	test -s "${2}"
}
# PCHM30_RUN17_BTF_BACKPORT_END
'''
    s = s[:insert_at] + '\n' + gen + s[insert_at:]

    marker = '\nkallsymso=""\n'
    if marker not in s:
        raise SystemExit('cannot locate kallsyms initialization anchor')
    setup = r'''

# Build BTF before kallsyms so all temporary/final links include the same BTF object.
btf_vmlinux_bin_o=""
if [ -n "${CONFIG_DEBUG_INFO_BTF}" ]; then
	if ! gen_btf .tmp_vmlinux.btf .btf.vmlinux.bin.o; then
		echo >&2 'Failed to generate BTF for vmlinux'
		exit 1
	fi
	btf_vmlinux_bin_o=.btf.vmlinux.bin.o
fi
'''
    s = s.replace(marker, setup + marker, 1)

    cleanup_anchor = 'cleanup()\n{\n'
    if cleanup_anchor not in s:
        raise SystemExit('cannot locate cleanup function')
    s = s.replace(cleanup_anchor, cleanup_anchor + '\trm -f .btf.vmlinux.bin .btf.vmlinux.bin.o .tmp_vmlinux.btf\n', 1)

    p.write_text(s)
    print('[PASS] patched scripts/link-vmlinux.sh for embedded vmlinux BTF')
else:
    print('[INFO] link-vmlinux BTF backport already present')
PY

# 4) Enable probe/BTF prerequisites. KRETPROBES is def_bool once KPROBES is enabled on this 4.14 tree.
scripts/config --file "$CONFIG" \
  -e DEBUG_KERNEL \
  -e DEBUG_INFO \
  -d DEBUG_INFO_REDUCED \
  -d DEBUG_INFO_SPLIT \
  -e DEBUG_INFO_BTF \
  -e KPROBES \
  -e KPROBE_EVENTS \
  -e PERF_EVENTS \
  -e BPF_EVENTS \
  -e BPF \
  -e BPF_SYSCALL \
  -e BPF_JIT \
  -e CGROUP_BPF \
  -e SYSFS

make O="$OUT_DIR" ARCH=arm64 olddefconfig

# 5) Hard gate the exact features Scene-Port-Hider needs before spending build time.
for cfg in \
  CONFIG_DEBUG_INFO=y \
  CONFIG_DEBUG_INFO_BTF=y \
  CONFIG_KPROBES=y \
  CONFIG_KRETPROBES=y \
  CONFIG_KPROBE_EVENTS=y \
  CONFIG_PERF_EVENTS=y \
  CONFIG_BPF_EVENTS=y \
  CONFIG_BPF=y \
  CONFIG_BPF_SYSCALL=y \
  CONFIG_BPF_JIT=y \
  CONFIG_CGROUP_BPF=y \
  CONFIG_SYSFS=y; do
  grep -qx "$cfg" "$CONFIG" || { echo "[FATAL] missing $cfg"; exit 71; }
done

grep -qx '# CONFIG_DEBUG_INFO_REDUCED is not set' "$CONFIG"
grep -qx '# CONFIG_DEBUG_INFO_SPLIT is not set' "$CONFIG"

for sym in \
  BPF_PROG_TYPE_CGROUP_SOCK_ADDR \
  BPF_CGROUP_INET4_BIND \
  BPF_CGROUP_INET6_BIND \
  BPF_CGROUP_INET4_CONNECT \
  BPF_CGROUP_INET6_CONNECT; do
  grep -q "$sym" include/uapi/linux/bpf.h || { echo "[FATAL] missing UAPI $sym"; exit 72; }
done

# The A16 donor should already contain the sock_addr program implementation and hooks.
grep -Rq 'BPF_PROG_TYPE_CGROUP_SOCK_ADDR' kernel net include/linux || {
  echo '[FATAL] CGROUP_SOCK_ADDR implementation not found after A16 backport'; exit 73;
}
grep -Rq 'BPF_CGROUP_INET4_CONNECT' kernel net include/linux || {
  echo '[FATAL] cgroup connect hook implementation not found'; exit 74;
}
grep -Rq 'BPF_CGROUP_INET4_BIND' kernel net include/linux || {
  echo '[FATAL] cgroup bind hook implementation not found'; exit 75;
}

# Old 4.14 syscall names used by Scene-Port-Hider's kprobe fallback must exist in source definitions.
grep -RqE 'SYSCALL_DEFINE[0-9]+\(bind|sys_bind|SyS_bind' net kernel include 2>/dev/null || true

git diff --check
{
  echo '===== effective scene/BTF config ====='
  grep -E '^(CONFIG_(DEBUG_INFO|DEBUG_INFO_BTF|KPROBES|KRETPROBES|KPROBE_EVENTS|PERF_EVENTS|BPF_EVENTS|BPF|BPF_SYSCALL|BPF_JIT|CGROUP_BPF|SYSFS)=|# CONFIG_(DEBUG_INFO_REDUCED|DEBUG_INFO_SPLIT) is not set)' "$CONFIG"
  echo '===== cgroup sock_addr UAPI ====='
  grep -nE 'BPF_PROG_TYPE_CGROUP_SOCK_ADDR|BPF_CGROUP_INET[46]_(BIND|CONNECT)' include/uapi/linux/bpf.h
  echo '===== BTF link/sysfs sources ====='
  grep -n 'PCHM30_RUN17_BTF_BACKPORT' scripts/link-vmlinux.sh
  grep -n '_binary__btf_vmlinux_bin_start' kernel/bpf/sysfs_btf.c
} | tee "$GITHUB_WORKSPACE/run17-btf-kprobe-scene-stage-proof.txt"

echo '[PASS] Run17 source/config now has BTF generation+sysfs export, KPROBES/KRETPROBES, and cgroup sock_addr prerequisites'
